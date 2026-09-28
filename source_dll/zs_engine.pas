unit zs_engine;

{ The statistics engine.

  The game thread never does stats work: the ZS_Ev_* exports copy an event into a queue and
  return, ZS_Poll_Action hands back console lines, HUD texts and other output, and the
  ZS_API_* readers take the state lock for a moment. Everything else runs here:

    engine thread   applies events under the state lock, runs timers (identity, daily
                    balance, seasons, HUD, journal flushes, snapshots, backups)
    IO thread       all file writes (zs_store)
    service thread  password hashing, e-mail, HTTP (zs_service)

  Event payloads (TZSEvent) are documented next to the exports in zs_main.pas. }

{$mode objfpc}{$H+}

interface

uses
  zs_fight,
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_fields, zs_fileio, zs_store, zs_legacy,
  zs_db, zs_rank, zs_rating, zs_weapons, zs_live, zs_rules, zs_service, zs_identity, zs_balance, zs_maps;

const
  MF_SURVIVAL = 1;
  MF_REALISTIC = 2;
  MF_ADVANCE = 4;
  MF_FRIENDLYFIRE = 8;

  EVENT_LIMIT = 100000;
  ACTION_LIMIT = 20000;
  { the event array the game thread fills is handed back empty; one that grew past this during a
    backlog goes back to the memory manager instead }
  EVENT_SPARE_MAX = 16384;
  { What the game thread sends in one tick (ZS_Action_Begin). Soldat sends every console line as
    a reliable packet, and a burst to one player in one tick can hold the whole server up; a
    team move rebuilds the player on every client. The rest waits for the next tick, each
    player's output in its own order. }
  PACE_PLAYER_LINES = 4;     { console lines and big texts of one player }
  PACE_LINES = 24;           { of all players together }
  PACE_MOVES = 2;            { team moves and kicks }
  PACE_BROADCASTS = 2;       { lines to every player }
  PACE_WRITES = 4;           { lines to the server console }
  PACE_RAYS = 8;             { Map.RayCast questions }
  { After a stall Soldat runs the ticks it missed one right after the other; a tick that comes
    sooner than this after the last one sends nothing, so the output keeps to real time. }
  PACE_TICK_US = 8000;
  PACE_SERVER_TEXT = MAX_PLAYERS + 1;
  PACE_RAY_STREAM = MAX_PLAYERS + 2;
  PACE_STREAMS = MAX_PLAYERS + 3;
  HUD_EVENTS_MAX = 4;
  { lines /zs_suspects keeps: the daily scan (NoteSuspect) and the kill series (LogSuspicious) }
  SUSPECTS_MAX = 200;
  SNAPSHOT_BUDGET = 400;
  SNAPSHOT_IO_HIGH_WATER = 8 * 1024 * 1024;

  { a map change this soon after a map vote started is the vote's result }
  VOTE_PASS_TICKS = 60 * TICKS_PER_SECOND;
  { who is still on the server this long into the next map stayed after the map }
  STAY_CHECK_TICKS = 120 * TICKS_PER_SECOND;

  SNAP_ROUTINE = 1;
  SNAP_BACKUP = 2;
  SNAP_PREOP = 3;
  SNAP_RESTORED = 4;
  SNAP_MANUAL = 5;

  OP_NONE = 0;
  OP_RESET_ALL_PLAYERS = 1;
  OP_RESET_ALL_MAPS = 2;
  OP_RESET_PLAYER = 3;
  OP_RESET_MAP = 4;
  OP_RESET_SERVER = 5;
  OP_REMOVE_OLDER = 6;
  OP_RESTORE = 7;
  OP_MERGE = 8;
  OP_UNREGISTER = 9;
  OP_SETPASS = 10;

type
  TZSEngine = class;

  TEngineThread = class(TThread)
  private
    FEngine: TZSEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(Engine: TZSEngine);
  end;

  TSlotExtra = record
    HudEvents: array of AnsiString;
    HudUntil: array of LongInt;   { per note: 0 = not on the HUD yet, else the tick it goes ([HUD] EventSeconds) }
    HudText: AnsiString;
    HudSentTick: LongInt;
    Welcomed: Boolean;
    CmdWindowMs: Int64;
    CmdCount: LongInt;
    HeavyUntilMs: Int64;
    PlaySeconds: LongInt;
    SpecSeconds: LongInt;
    Kicked: Boolean;
    LastQuery: AnsiString;
    LastQueryKind: LongInt;
    Page: LongInt;
    Pages: LongInt;
    YesLockUntil: Double;
    JetTicks: LongInt;
    { !lastfight: the recent fight events and the last deaths (zs_fight, zs_engine_fight.inc) }
    Fight: TLfSlot;
    { the weapon + 1 picked in this life as primary (0) and secondary (1), 0 = none yet }
    Picked: array[0..1] of LongInt;
    { the reload of the weapon in hand (zs_engine_reload.inc) }
    RlOpen: Boolean;
    RlWeapon: LongInt;
    RlStart: LongInt;           { tick }
    RlExpected: LongInt;        { ticks a whole reload takes }
    RlEarly: Boolean;           { refilled before its time: the late "empty" may still come }
    RlEarlyUntil: LongInt;
    RlResumed: Boolean;         { went on after a weapon change: its length says nothing }
    RlSpas: Boolean;
    RlShellsNeeded: LongInt;
    RlShellsDone: LongInt;
    RlDeathTick: LongInt;       { the change that follows a death is the gun that falls }
    RlSaved: array[0..WSLOT_COUNT - 1] of LongInt;   { per mille + 1 of a reload left by a change }
    RlSavedTicks: array[0..WSLOT_COUNT - 1] of LongInt;   { the ticks it had run by then }
  end;

  TPendingOp = record
    Kind: LongInt;
    AdminSlot: LongInt;
    AdminName: AnsiString;
    Arg: AnsiString;
    IntArg: LongInt;
    IntArg2: LongInt;
    Expires: Double;
    WaitingBackup: Boolean;
  end;

  TTeamTicks = array[TEAM_ALPHA..TEAM_DELTA] of LongInt;

  { an account that left the running match: every stay it left adds its time on each team here }
  TLeaver = record
    ProfileId: LongInt;
    TeamTicks: TTeamTicks;
  end;

  { a kill waiting for main.pas to say whether the line of the lethal shot was clear }
  TRayRequest = record
    Id: LongInt;           { 0 = free }
    ProfileId: LongInt;    { the killer }
    MapSerial: LongInt;    { an answer from another map describes other walls }
    X1, Y1, X2, Y2: LongInt;
  end;

  TMatchState = record
    Active: Boolean;
    MapIndex: LongInt;
    MapName: AnsiString;
    GameStyle: LongInt;
    ScoreLimit: LongInt;
    TimeLimit: LongInt;
    Survival: Boolean;
    Realistic: Boolean;
    Advance: Boolean;
    FriendlyFire: Boolean;
    StartTick: LongInt;
    StartTime: Double;
    TeamScore: array[1..4] of LongInt;
    ScoreTick: LongInt;         { tick of the last look at the team scores (EvTick): a point seen now came after it }
    MaxDeficit: array[1..4] of LongInt;
    TimeLeft: LongInt;
    FirstBlood: Boolean;
    RoundFirstBlood: Boolean;   { survival: the first kill of the running round was made }
    FirstDamage: Boolean;
    LastStandGiven: array[0..4] of Boolean;
    ClutchSlot: LongInt;
    ClutchProfile: LongInt;   { account of ClutchSlot: a new player in that slot gets nothing }
    RoundOver: Boolean;
    { free-for-all survival: the humans who spawned in the running round (RoundCheck); a round
      decided in RoundTick is settled with the first event of a later tick (RoundSettle) }
    RoundIn: array[1..MAX_PLAYERS] of Boolean;
    RoundPending: Boolean;
    RoundTick: LongInt;
    { how survival rounds end (zs_engine_matrix.inc): the tick of the last capture, and whether a
      team round runs (two teams were seen standing since the last round ended) }
    CaptureTick: LongInt;
    RoundLive: Boolean;
    Leavers: array of TLeaver;
    HumansMax: LongInt;
    LastVoteMap: AnsiString;    { the last map vote started during this match }
    LastVoteTick: LongInt;
    TotalSeconds: LongInt;      { length of the match: time left plus time played, 0 without a time limit }
  end;

  TBalTeamNos = array[0..BAL_MAX_TEAMS - 1] of LongInt;

  { team balance: what the balance knows about a player slot }
  TBalSlot = record
    Form: Double;              { how the player does on this map, on the MMR scale }
    FormSince: LongInt;        { tick the player started on this map }
    TeamSince: LongInt;        { tick of the last team change }
    LastTeam: LongInt;         { the last team (1-4) the player played for }
    ImmuneUntil: LongInt;      { not chosen again before this tick }
    LockTeam: LongInt;         { team the player may not go back to before LockUntil }
    LockUntil: LongInt;
    Excluded: Boolean;         { /balexclude }
    ReviewUntil: LongInt;      { the join is looked at again once the account is known }
    Reviewed: Boolean;
    Recalled: Boolean;         { what the rejoin memory keeps of the account is back }
    ReturnTeam: LongInt;       { the team the account played for before it left, 0 = none }
    MoveKind: LongInt;         { BK_* of the move main.pas is carrying out, 0 = none }
    MoveTeam: LongInt;
    MoveFrom: LongInt;
    MoveSent: LongInt;
    MoveFav: LongInt;          { the stronger team before the move }
    MoveBefore: Double;        { its chance before }
    MoveAfter: Double;         { imbalance expected after }
    MoveBy: LongInt;           { admin slot of /move, /swap, /mix; 0 = console }
    MoveHelped: Boolean;       { a !switch that evened the match }
    WaitTeam: LongInt;         { survival: an admin's move that waits for this player's death, 0 = none }
    WaitBy: LongInt;
    JoinNote: AnsiString;
  end;

  { players who leave are remembered, so leaving and rejoining changes nothing }
  TBalMemory = record
    ProfileId: LongInt;
    Expires: Double;
    Team: LongInt;
    LockTeam: LongInt;
    LockUntil: Double;
    ImmuneUntil: Double;
    Form: Double;
    FormSince: LongInt;
    MapSerial: LongInt;
  end;

  { a move or swap the balance decided and carries out at the players' next deaths }
  TBalPending = record
    Active: Boolean;
    Count: LongInt;
    Slot: array[0..1] of LongInt;
    JoinTick: array[0..1] of LongInt;
    Team: array[0..1] of LongInt;
    Done: array[0..1] of Boolean;
    Created: LongInt;
    Deadline: LongInt;
    FavTeam: LongInt;
    Before: Double;
    After: Double;
    CountFix: Boolean;
  end;

  { a join placed by the game thread that the engine has not seen happen yet }
  TBalExpected = record
    Id: LongInt;
    Slot: LongInt;
    Team: LongInt;
    Power: Double;
    Tick: LongInt;
    Requested: LongInt;
    Note: Boolean;
  end;
  TBalExpectedArray = array of TBalExpected;

  TBalSnapPlayer = record
    Active: Boolean;
    Team: LongInt;
    Power: Double;
    Counts: Boolean;
    LockTeam: LongInt;
    Locked: Boolean;
  end;

  { what the game thread reads to place a joining player without waiting for the engine }
  TBalSnapshot = record
    Valid: Boolean;
    Assign: Boolean;
    TeamCount: LongInt;
    TeamNo: TBalTeamNos;
    Params: TBalParams;
    Tolerance: Double;
    MaxSpread: LongInt;
    Players: array[1..MAX_PLAYERS] of TBalSnapPlayer;
    Expected: TBalExpectedArray;
    SeenId: LongInt;
  end;

  TBalState = record
    Paused: Boolean;
    Slots: array[1..MAX_PLAYERS] of TBalSlot;
    Memory: array of TBalMemory;
    Pending: TBalPending;
    Expected: TBalExpectedArray;
    SeenId: LongInt;
    ChanceSince: LongInt;      { a team above the threshold since this tick, 0 = no }
    CountSince: LongInt;       { numbers too far apart since this tick, 0 = no }
    LastMoveTick: LongInt;
    LastCheckTick: LongInt;
    MovesThisMap: LongInt;
    RequestUntil: LongInt;     { a volunteer is asked for until this tick }
    RequestFrom: LongInt;
    RequestTo: LongInt;
    RequestDone: Boolean;
    MapStartTick: LongInt;
    Median: Double;
    BotStrength: Double;
    RefPoints: array of Double;
    RefTick: LongInt;
    RefDone: Boolean;
    PredSum: Double;
    PredCount: LongInt;
    PredTick: LongInt;
    Log: array[0..9] of AnsiString;
    LogNext: LongInt;
    History: TBalRecordArray;
    HistoryCount: LongInt;
    HistoryNext: LongInt;
    FitSize, FitDouble, FitBrier: Double;
    FitCount: LongInt;
    SinceFit: LongInt;          { matches recorded since the last fit }
    NoChangeNoted: Boolean;
    Dirty: Boolean;
  end;

  { the players on the teams when a map ended, looked at again a while into the next map }
  TStayCheck = record
    MapIndex: LongInt;          { -1 = nothing to check }
    EndTick: LongInt;
    Humans: LongInt;
    Present: array[1..MAX_PLAYERS] of Boolean;
  end;

  TZSEngine = class(TIdentityHost)
  private
    FThread: TEngineThread;
    FEventLock: TRTLCriticalSection;
    FEventWake: PRTLEvent;
    FEvents: TZSEventArray;
    FEventCount: LongInt;
    FEventsDropped: LongInt;
    FActionLock: TRTLCriticalSection;
    FActions: TZSActionArray;
    FActionCount: LongInt;
    FActionRead: LongInt;
    FEventSpare: TZSEventArray;
    { what PopAction may still hand out in this tick; BeginActions opens the tick }
    FPaceOn: Boolean;
    FPaceScan: LongInt;
    FPaceLines: LongInt;
    FPaceMoves: LongInt;
    FPaceBroadcasts: LongInt;
    FPaceWrites: LongInt;
    FPaceRays: LongInt;
    FPaceLastUs: Int64;
    FPaceSlotLines: array[0..PACE_STREAMS] of LongInt;
    FPaceHeld: array[0..PACE_STREAMS] of Boolean;
    FLibraryPath: AnsiString;
    FStopping: Boolean;
    FReady: Boolean;
    FReadOnly: Boolean;
    FLastFlushMs: Int64;
    FLastSharedFlushMs: Int64;
    FLastSnapshotMs: Int64;
    FLastSecondMs: Int64;
    FLastInfoMs: Int64;
    FSnapTag: LongInt;
    FSnapBackupPath: AnsiString;
    FSnapRetryMs: Int64;
    FErrorWindowMs: Int64;
    FErrorCount: LongInt;
    FPeakSince: Double;
    FYesLockUntil: Double;
    FProcessed: LongInt;
    FBackupInFlight: Boolean;
    FLoadFailed: Boolean;           { the stored database could not be read }
    FLibraryNoted: Boolean;
    FMaxGen: LongWord;
    FToken: LongInt;
    FTokenClaimed: Boolean;
    FRays: array[0..63] of TRayRequest;
    FRayNext: LongInt;
    FRayId: LongInt;
    FMapSerial: LongInt;
    FStay: TStayCheck;
    FIntegritySent: Boolean;
    FBalLock: TRTLCriticalSection;
    FBalSnap: TBalSnapshot;
    FJoinReqs: TBalExpectedArray;
    FJoinReqId: LongInt;
    FLoadMs: Int64;                 { how long loading the data took (the notice of a /recompile) }
    FScriptKept: Boolean;           { main.pas was loaded again while the library kept running }
    procedure Run;
    procedure LoadData;
    procedure ArchiveDamagedFiles;
    function AutoRestoreBackup: Boolean;
    function ApiTryLock: Boolean;
    function MigrateLegacy(var St: TStoreState): Boolean;
    procedure ApplyConfig;
    procedure ProcessEvent(var E: TZSEvent);
    procedure Timers;
    procedure WallSecond;
    procedure PersistenceTimers(NowMs: Int64);
    procedure PollResults;
    procedure FinishShutdown;
    procedure EmitAction(const A: TZSAction);
    function PaceStream(const A: TZSAction): LongInt;
    function PaceAllows(const A: TZSAction; Stream: LongInt): Boolean;
    procedure ReportError(const Where: AnsiString; E: Exception);
    function CheckDuplicate(S: LongInt; const What, Mode: AnsiString; Kind: LongInt; const Value: AnsiString): Boolean;
    procedure NoteSuspect(const Text: AnsiString; Notify: Boolean = True);
    procedure ScanForSuspects;
    procedure LoadSuspects;

    { events: zs_engine_events.inc }
    procedure EvJoin(var E: TZSEvent);
    procedure EvLeave(var E: TZSEvent);
    procedure EvTeam(var E: TZSEvent);
    procedure EvSteamAuth(var E: TZSEvent);
    procedure EvSpawn(var E: TZSEvent);
    procedure EvShot(var E: TZSEvent);
    procedure EvGrenade(var E: TZSEvent);
    procedure EvKnifeThrow(var E: TZSEvent);
    procedure EvWeapon(var E: TZSEvent);
    procedure EvKit(var E: TZSEvent);
    procedure EvHeal(var E: TZSEvent);
    procedure EvSample(var E: TZSEvent);
    procedure EvVote(var E: TZSEvent);
    procedure CountShots(Slot, Weapon, Count: LongInt);
    procedure NotePick(S, Which, Weapon: LongInt);

    { reloads: zs_engine_reload.inc }
    function ReloadMille(S, Tick: LongInt): LongInt;
    function ReloadStats(S, Weapon: LongInt; out Idx: LongInt): PWeaponStats;
    procedure ReloadOpen(S, Weapon, Tick: LongInt; Manual: Boolean; RoundsLeft: LongInt);
    procedure ReloadOpenSpas(S, Tick, Shells: LongInt);
    procedure ReloadClose(S, How, Tick: LongInt);
    procedure ReloadDropSaved(S, WS: LongInt);
    procedure ReloadForget(S: LongInt);
    procedure ReloadForgetAll;
    procedure ReloadDeadlines(Tick: LongInt);
    procedure EvAmmo(var E: TZSEvent);
    procedure ReloadOnWeapon(S, OldW, NewW, NewAmmo, Tick: LongInt);
    procedure ReloadOnDeath(S, Tick: LongInt; Blame: Boolean);
    procedure LoadWeaponsForMode;
    procedure EvRealistic(var E: TZSEvent);
    procedure NoteLoadWeapons(const W: TStringArray);

    { combat: zs_engine_combat.inc }
    procedure EvKill(var E: TZSEvent);
    procedure EvDamage(var E: TZSEvent);
    procedure EvFlag(var E: TZSEvent);
    procedure KillSelf(Slot: LongInt);
    procedure KillTeammate(K, V: LongInt; Flags: LongInt);
    procedure KillEnemy(var E: TZSEvent);
    procedure CountHurt(S, V, Weapon: LongInt; IsSelf, Friendly: Boolean; SIdx, VIdx: LongInt);
    procedure UpdateNemesis(var List: TNemesisArray; TargetId: LongInt);
    procedure HeatAdd(MapIndex: LongInt; X, Y: Single; IsKill: Boolean);
    procedure CheckLastStand(Victim: LongInt);
    procedure LogSuspicious(K, V: LongInt);
    procedure AfterProfileChange(Index: LongInt);
    procedure AskRay(ProfileId: LongInt; X1, Y1, X2, Y2: Single);
    procedure EvRay(var E: TZSEvent);

    { match flow: zs_engine_match.inc }
    procedure EvTick(var E: TZSEvent);
    procedure EvMapBefore(var E: TZSEvent);
    procedure EvMapAfter(var E: TZSEvent);
    procedure EvPlayerScore(var E: TZSEvent);
    procedure BeginMatch(const MapName: AnsiString; GameStyle, ScoreLimit, TimeLimit, Flags: LongInt);
    procedure EndMatch(Completed: Boolean);
    procedure RoundEnd(WinTeam: LongInt);
    procedure RoundReset;
    procedure RoundEndFfa(WinSlot: LongInt);
    procedure RoundJoin(S: LongInt);
    procedure RoundCheck(ServerWinner: LongInt);
    procedure RoundSettle;
    procedure SecondAccounting;
    procedure UpdatePeakOnline;
    function DailyEntry: LongInt;
    function MatchTeamOf(Slot: LongInt): LongInt;
    procedure MatchTicks(Slot: LongInt; out Ticks: TTeamTicks);
    function LeaverIndex(ProfileId: LongInt): LongInt;
    procedure NoteLeaver(S, ProfileId: LongInt);
    function HtfCarrier(Team, Since: LongInt): LongInt;
    procedure StartStayCheck;
    procedure FinishStayCheck;

    { team balance: zs_engine_balance.inc }
    procedure BalResetSlot(S: LongInt);
    procedure BalInit;
    function BalParamsFor(TeamCount: LongInt): TBalParams;
    function BalSkill(const P: TPlayerProfile; Family: LongInt; out Games: LongInt): Double;
    procedure BalRefreshReference;
    function BalExcludedAccount(S: LongInt): Boolean;
    function BalInPending(S: LongInt): Boolean;
    function BalCost(S: LongInt): Double;
    function BalHumans(const Cands: TBalCandArray): LongInt;
    procedure BalSend(S, Team, Kind: LongInt; DeadOnly: Boolean; FavTeam: LongInt; Before, After: Double; By: LongInt);
    procedure BalCancelPending(const Why: AnsiString);
    function BalTeamChance(Team: LongInt): Double;
    procedure BalRemember(S: LongInt);
    procedure BalFinishMove(S, Kind: LongInt);
    procedure EvMoveResult(var E: TZSEvent);
    { the score guard of main.pas }
    function IntegrityFlags: LongInt;
    procedure SendIntegrityConfig;
    procedure EvIntegrity(var E: TZSEvent);
    function BalPendingHelps: Boolean;
    procedure BalPendingSend(k: LongInt; DeadOnly: Boolean);
    procedure BalSchedule(const Move: TBalMove; const Cands: TBalCandArray; const TeamNo: TBalTeamNos;
      TeamCount: LongInt; const Ch: TBalTeamValues; CountFix: Boolean);
    procedure BalPendingTimers;
    procedure BalOnKill(K, V, Tick: LongInt);
    procedure BalOnFlag(S, Kind: LongInt);
    procedure BalOnJoin(S: LongInt);
    procedure BalOnLeave(S: LongInt);
    procedure BalOnTeam(S, NewTeam: LongInt);
    procedure BalTellRedirect(S, Asked, Given: LongInt);
    procedure EvTeamRequest(var E: TZSEvent);
    procedure BalExpire;
    procedure BalReviewJoins;
    function BalSwitchHelps(D0, D1: Double; Spread0, Spread1: LongInt): Boolean;
    function BalVolunteerCanHelp(var Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
      const TeamNo: TBalTeamNos; From, Into: LongInt; D0: Double; Spread0: LongInt): Boolean;
    procedure BalAskVolunteers(const Ch: TBalTeamValues; const Cnt: TBalTeamCounts; const TeamNo: TBalTeamNos;
      TeamCount: LongInt; CountFix: Boolean);
    procedure BalCheck;
    procedure BalPredictionSample;
    procedure BalanceSecond;
    procedure BalMapStart;
    function BalApplyTeams(const Cands: TBalCandArray; const NewTeams: array of LongInt; const TeamNo: TBalTeamNos;
      TeamCount: LongInt; const ChBefore: TBalTeamValues; Kind, By: LongInt): LongInt;
    procedure BalMapStartFix;
    procedure BalRefreshSnapshot;
    procedure BalAddHistory(const R: TBalRecord; Save: Boolean);
    procedure BalLoadHistory;
    procedure BalanceMatchEnd(Completed: Boolean);
    procedure BalCheckOthers;

    { commands and output: zs_engine_admin.inc }
    procedure EvCommand(var E: TZSEvent);
    procedure EvReloadConfig(var E: TZSEvent);
    function AdminCommand(Slot: LongInt; const W: TStringArray; Source: LongInt): Boolean;
    procedure Confirm(Slot: LongInt; const W: TStringArray; Source: LongInt);
    procedure AskConfirmation(Slot, Kind: LongInt; const Arg: AnsiString; IntArg, IntArg2: LongInt; const What: AnsiString);
    procedure RunPendingOp;
    procedure ClearPending;
    procedure RestoreBackup(const FileName: AnsiString; AdminSlot: LongInt);
    procedure RefreshHud(Slot: LongInt; Force: Boolean);
    procedure WelcomePlayer(Slot: LongInt);

    { map vote: zs_engine_mapvote.inc }
    function MvEligible(S: LongInt): Boolean;
    procedure MvCount(out Yes, Voters: LongInt);
    function MvPasses(Yes, Voters: LongInt): Boolean;
    function MvCountText(Yes, Voters: LongInt): AnsiString;
    function MvCmdOn(Bit: LongInt): Boolean;
    function MvVoteKeys: AnsiString;
    procedure MvAction(Kind, P1: LongInt; const Text: AnsiString);
    procedure MvFinish(const Outcome, Line: AnsiString; Color: LongInt);
    procedure MvPass(const Line: AnsiString);
    procedure MvStart(Slot: LongInt; const Target: AnsiString; Key: LongInt);
    procedure MvSayNoVote(Slot: LongInt);
    function MvStarterKey(Slot: LongInt): LongInt;
    function MvCooldownLeft(Key: LongInt): LongInt;
    procedure MvNoteStarter(Key: LongInt);
    procedure MvScan(const Folder: AnsiString; NowMs: Int64);
    procedure EvMapList(var E: TZSEvent);
    procedure SendMapVoteConfig;
    procedure MapVoteTimers(NowMs: Int64);
    procedure MapVoteSecond;
    procedure MapVoteOnMapBefore;
    procedure MapVoteOnMapAfter(const NewMap: AnsiString);
    procedure MapVoteSoldat(Slot, Kind: LongInt; const Map: AnsiString);
  public
    Cfg: TZSConfig;
    DB: TStatsDB;
    Identity: TIdentityManager;
    Live: TLiveTable;
    Extra: array[1..MAX_PLAYERS] of TSlotExtra;
    WeaponsIniOverride: AnsiString;   { /loadwep <name>: that file until the game starts again }
    Match: TMatchState;
    Pending: TPendingOp;
    IO: TStoreIO;
    Writer: TStoreWriter;
    Service: TServiceThread;
    ScriptDir: AnsiString;
    DataDir: AnsiString;
    LogDir: AnsiString;
    BackupDir: AnsiString;
    GameTick: LongInt;
    StateLock: TRTLCriticalSection;
    Warnings: TStringList;
    LoadMessage: AnsiString;
    Suspects: TStringList;          { newest suspicious kill series, shown by /zs_suspects }
    ExportRequested: Boolean;       { /zs_export: write the JSON export on the next timer run }
    { who asked for /zs_backup, /zs_export and /zs_save and hears how it ended; -1 = nobody,
      0 = the server console }
    BackupAsker: LongInt;
    ExportAsker: LongInt;
    SaveAsker: LongInt;
    SaveFailed: Boolean;            { a journal write failed since /zs_save was asked }
    HeavyWindowMs: Int64;           { server-wide limit of lists that go through every account }
    HeavyInWindow: LongInt;
    { engine thread timing, shown by /zs_perf }
    PerfSince: TDateTime;
    PerfEvents: Int64;
    PerfEventMicros: Int64;
    PerfEventMaxMicros: Int64;
    PerfTimerRuns: Int64;
    PerfTimerMicros: Int64;
    PerfTimerMaxMicros: Int64;
    PerfBatchMax: LongInt;
    Bal: TBalState;                 { team balance state (zs_engine_balance.inc) }
    SqlState: TObject;              { [MySQL] Engine = mysql: the exchange with the shared database (zs_sqldb) }
    { the map vote (zs_engine_mapvote.inc): the maps list, the maps folder and the vote }
    MV: TMapVoteData;
    MapCat: TMapCatalog;            { reads the maps folder on a thread of its own, made at the first scan }
    MapVoteSlash: LongInt;          { 1 while /votemap belongs to the map vote; read by the game thread }

    constructor Create(const AScriptDir: AnsiString);
    destructor Destroy; override;
    procedure Start;
    procedure Shutdown;
    function IsReady: Boolean;
    function IsReadOnly: Boolean;
    { admin token for main.pas: ClaimToken returns it once, 0 afterwards }
    function ClaimToken: LongInt;
    procedure NoteScriptReloaded;
    function TokenValid(Value: LongInt): Boolean;
    property Processed: LongInt read FProcessed;
    property EventsDropped: LongInt read FEventsDropped;
    property EventsQueued: LongInt read FEventCount;
    procedure PushEvent(const E: TZSEvent);
    function BeginActions: LongInt;
    function PopAction(out A: TZSAction): Boolean;
    { set before Start: the engine thread reads and hashes the file }
    property LibraryPath: AnsiString read FLibraryPath write FLibraryPath;

    procedure Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt); override;
    procedure Audit(const Text: AnsiString); override;
    procedure ForceSpectator(Slot: LongInt); override;
    procedure ReturnToGame(Slot: LongInt); override;
    procedure KickPlayer(Slot: LongInt; const Reason: AnsiString); override;
    function SubmitJob(const Job: TServiceJob): Boolean; override;
    procedure SessionProfileChanged(Slot, OldProfileId, NewProfileId: LongInt); override;

    procedure Say(Slot: LongInt; const Text: AnsiString; Color: LongInt);
    procedure Broadcast(const Text: AnsiString; Color: LongInt);
    procedure WriteServer(const Text: AnsiString);
    procedure NotifyAdmins(const Text: AnsiString; Color: LongInt);
    procedure HudEvent(Slot: LongInt; const Text: AnsiString);
    procedure AppendLog(const FileName, Line: AnsiString);
    procedure NoteLibrary(const Path: AnsiString);
    procedure StartSnapshot(Tag: LongInt; const BackupPath: AnsiString);
    function SnapshotBusy: Boolean;
    function BackupFileName(const Reason: AnsiString): AnsiString;
    function StatsOn: Boolean;
    function SurvivalOn: Boolean;
    function TeamGame: Boolean;
    function TeamsFilled: Boolean;
    function HumansPlaying: LongInt;
    function HumansOnline: LongInt;
    function EffectiveMaxHealth: LongInt;
    function SlotValid(Slot: LongInt): Boolean;
    function PlayerRank(Index: LongInt): LongInt;
    function TierName(Index: LongInt): AnsiString;
    function PlainTierName(Index: LongInt): AnsiString;
    function LeagueName(Index: LongInt): AnsiString;
    function LeagueLabel(Index: LongInt): AnsiString;
    function TierColor(Index: LongInt): LongInt;
    function RatingSystem: LongInt;
    function CurrentFamily: LongInt;

    { developer API, called from the game thread }
    function ApiPlayerStat(Slot, StatId: LongInt): Double;
    function ApiProfileStat(ProfileId, StatId: LongInt): Double;
    function ApiPlayerRank(Slot: LongInt): LongInt;
    function ApiPlayerName(Slot: LongInt): AnsiString;
    function ApiTopPlayer(Rank: LongInt): AnsiString;
    function ApiTopPlayerWait(Rank: LongInt): AnsiString;
    function ApiProfileCount: LongInt;
    function ApiServerPeak: LongInt;
    function ApiPlayerHud(Slot: LongInt): Boolean;

    { team balance, for the commands and main.pas }
    function BalanceActive: Boolean;
    function BalTeams(out TeamNo: TBalTeamNos): LongInt;
    function BalSizeImpact: Double;
    function BalSkillPerDouble: Double;
    function BalAlphaBias: Double;
    function BalBase(S: LongInt; out Skill: Double; out Games: LongInt): Double;
    function BalFormWeight(S: LongInt): Double;
    function BalStrength(S: LongInt): Double;
    function BalAfk(S: LongInt): Boolean;
    function BalPowerOf(S: LongInt): Double;
    function BalIsTop(S: LongInt): Boolean;
    function BalBlocker(S: LongInt): AnsiString;
    function BalGather(out Cands: TBalCandArray; out TeamNo: TBalTeamNos; out TeamCount: LongInt;
      out Params: TBalParams; out Chances: TBalTeamValues): Double;
    function BalChanceText(const Ch: TBalTeamValues; const TeamNo: TBalTeamNos; TeamCount: LongInt): AnsiString;
    function BalMatchDecided: Boolean;
    function BalMayMove(CountFix: Boolean; out Why: AnsiString): Boolean;
    function BalHumansOnTeams: LongInt;
    function MapDecided: LongInt;
    procedure BalNote(const Text: AnsiString);
    procedure BalSwitch(S: LongInt);
    procedure BalJoinTeam(S: LongInt);
    procedure BalAdminCheck(AdminSlot: LongInt);
    procedure BalMix(AdminSlot: LongInt);
    procedure BalMoveTo(AdminSlot, S, Team: LongInt);
    procedure BalSwap(AdminSlot, A, B: LongInt);
    procedure BalToggleExclude(AdminSlot, S: LongInt);
    procedure BalSetPaused(AdminSlot: LongInt; Paused: Boolean);
    { game thread: the team a joining player should enter, -1 = stay }
    function TeamJoinAdvice(Slot, Team, OldTeam, Tick: LongInt): LongInt;

    { the map vote, for the commands (zs_cmd_mapvote.inc) }
    function MapVoteRequest(Slot: LongInt; const Target: AnsiString): LongInt;
    procedure MapVoteYes(Slot: LongInt);
    function MapVoteCancel: Boolean;
    function MapVoteLate(Slot: LongInt; const Text: AnsiString): Boolean;
    function MapVoteFind(const Text: AnsiString; out Target, Why, Others: AnsiString): Boolean;
    function MapVoteNextMap: AnsiString;
    function MapVoteLastMap: AnsiString;
    function MapVoteRandomMap(out Why: AnsiString): AnsiString;
    function MapVoteCurrentMap: AnsiString;
    function MapVoteFolder: AnsiString;
    function MapVoteStartHint: AnsiString;
    function MapVoteSecondsLeft: LongInt;
    function MapVoteYesCount(out Voters: LongInt): LongInt;
    procedure MapVoteRescan(Asker: LongInt);
  end;

function NewEvent(Kind: TZSEventKind): TZSEvent;
function NewAction(Kind, Slot, Color: LongInt; const Text: AnsiString): TZSAction;

implementation

uses
  zs_commands, zs_export, zs_crash, zs_mysql, zs_sqldb, zs_matrix;

function NewEvent(Kind: TZSEventKind): TZSEvent;
begin
  Result.Kind := Kind;
  Result.Tick := 0;
  Result.Slot := 0;
  Result.Slot2 := 0;
  Result.Serial := 0;
  Result.Serial2 := 0;
  FillChar(Result.I, SizeOf(Result.I), 0);
  FillChar(Result.F, SizeOf(Result.F), 0);
  Result.S1 := '';
  Result.S2 := '';
  Result.S3 := '';
  Result.S4 := '';
end;

function NewAction(Kind, Slot, Color: LongInt; const Text: AnsiString): TZSAction;
begin
  Result.Kind := Kind;
  Result.Slot := Slot;
  Result.Color := Color;
  Result.P1 := 0;
  Result.P2 := 0;
  Result.P3 := 0;
  Result.P4 := 0;
  Result.P5 := 0;
  Result.F1 := 0;
  Result.F2 := 0;
  Result.F3 := 0;
  Result.Text := Text;
end;

function TeamTitle(Team: LongInt): AnsiString;
begin
  case Team of
    TEAM_ALPHA: Result := 'Alpha';
    TEAM_BRAVO: Result := 'Bravo';
    TEAM_CHARLIE: Result := 'Charlie';
    TEAM_DELTA: Result := 'Delta';
    else Result := 'team ' + IntToStr(Team);
  end;
end;

{$I zs_engine_fight.inc}

{ ---------------- thread ---------------- }

constructor TEngineThread.Create(Engine: TZSEngine);
begin
  FEngine := Engine;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TEngineThread.Execute;
begin
  GuardWorkerThread;
  CrashThread(CT_ENGINE);
  FEngine.Run;
end;

{ ---------------- lifetime ---------------- }

constructor TZSEngine.Create(const AScriptDir: AnsiString);
var
  i: LongInt;
  Tok: AnsiString;
begin
  inherited Create;
  ScriptDir := IncludeTrailingPathDelimiter(AScriptDir);
  BackupAsker := -1;
  ExportAsker := -1;
  SaveAsker := -1;
  MV.ScanAsker := -1;
  InitCriticalSection(FEventLock);
  InitCriticalSection(FActionLock);
  InitCriticalSection(StateLock);
  FEventWake := RTLEventCreate;
  SetLength(FEvents, 1024);
  SetLength(FEventSpare, 1024);
  Warnings := TStringList.Create;
  Suspects := TStringList.Create;
  PerfSince := Now;
  SetConfigDefaults(Cfg);
  Cfg.ScriptDir := ScriptDir;
  DB := TStatsDB.Create;
  Identity := TIdentityManager.Create(DB, @Cfg, Self);
  for i := 1 to MAX_PLAYERS do
    LiveResetSlot(Live, i);
  Pending.Kind := OP_NONE;
  Match.MapIndex := -1;
  FStay.MapIndex := -1;
  BalInit;
  repeat
    Tok := SecureRandomBytes(SizeOf(FToken));
    Move(Tok[1], FToken, SizeOf(FToken));
  until FToken <> 0;
end;

destructor TZSEngine.Destroy;
begin
  Shutdown;
  { stops the thread that reads the maps folder }
  FreeAndNil(MapCat);
  Identity.Free;
  DB.Free;
  Suspects.Free;
  Warnings.Free;
  RTLEventDestroy(FEventWake);
  DoneCriticalSection(FBalLock);
  DoneCriticalSection(StateLock);
  DoneCriticalSection(FActionLock);
  DoneCriticalSection(FEventLock);
  inherited Destroy;
end;

procedure TZSEngine.Start;
var
  k: LongInt;
begin
  if FThread <> nil then
    Exit;
  Warnings.Clear;
  LoadConfigFile(ScriptDir + 'settings.ini', Cfg, Warnings);
  { everything written in the game takes its colour from here on out of the file }
  ApplyPalette(Cfg);
  Cfg.ScriptDir := ScriptDir;
  ApplyConfig;
  for k := 0 to Warnings.Count - 1 do
    WriteServer('[ZitroStats] settings.ini: ' + Warnings[k]);
  BalCheckOthers;
  FThread := TEngineThread.Create(Self);
end;

procedure TZSEngine.Shutdown;
begin
  if FThread = nil then
    Exit;
  FStopping := True;
  RTLEventSetEvent(FEventWake);
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

function TZSEngine.IsReady: Boolean;
begin
  Result := FReady;
end;

function TZSEngine.IsReadOnly: Boolean;
begin
  Result := FReadOnly;
end;

function TZSEngine.ClaimToken: LongInt;
begin
  Result := 0;
  if FTokenClaimed then
    Exit;
  FTokenClaimed := True;
  Result := FToken;
end;

{ The script was loaded again (a recompile or a change of the game mode) while the library kept
  running. The new main.pas has to be able to claim the admin token, or admin commands would stay
  dead until the server restarts, and it needs the settings of the score guard again. }
procedure TZSEngine.NoteScriptReloaded;
begin
  FTokenClaimed := False;
  FIntegritySent := False;
  FScriptKept := True;
end;

function TZSEngine.TokenValid(Value: LongInt): Boolean;
begin
  Result := (Value <> 0) and (Value = FToken);
end;

procedure TZSEngine.ApplyConfig;
var
  Dir: AnsiString;
begin
  { ZS_Init reads DataDir and LogDir on the game thread when main.pas is loaded again, while a
    settings reload runs here: a path that did not change is not assigned again, so the string
    that thread may be reading is never freed under it }
  Dir := ResolvePath(Cfg.DataPath);
  if Dir = '' then
    Dir := '.';
  if Dir <> DataDir then
    DataDir := Dir;
  Dir := ResolvePath(Cfg.LogPath);
  if Dir <> LogDir then
    LogDir := Dir;
  { the achievements named after kill streak levels follow the levels of [Sprees] }
  SetStreakAchievements(Cfg);
  BackupDir := ResolvePath(Cfg.BackupPath);
  DB.RatingSystem := RatingSystemOf(Cfg);
  DB.GlickoK := Cfg.GlickoConservative;
  DB.GlickoR := Cfg.GlickoRating;
  DB.GlickoRD := Cfg.GlickoRD;
  DB.GlickoVol := Cfg.GlickoVolatility;
  DB.MmrStart := Cfg.MmrStart;
  DB.MmrK := Cfg.MmrK;
  DB.MmrPlacement := Cfg.MmrPlacementGames;
  DB.SkillMu := Cfg.OSMu;
  DB.SkillSigma := Cfg.OSSigma;
  if SameText(Trim(Cfg.InactivityMode), 'decay') then
    DB.HideAfterDays := Cfg.DecayHideAfterDays
  else
    DB.HideAfterDays := 0;
  { ZS_Command reads this on the game thread: whether /votemap is the map vote's }
  MapVoteSlash := Ord(Cfg.MapVoteEnabled and (Cfg.MapVoteCommands and MVC_SLASHVOTEMAP <> 0));
  { [Matrix] MaxRivals: a smaller limit shortens a rival list when it takes a new rival }
  DB.PM.MaxRivals := Cfg.MatrixMaxRivals;
end;

function MailSettingsOf(const Cfg: TZSConfig): TMailSettings;
begin
  Result.Method := Cfg.MailMethod;
  Result.CurlPath := Cfg.MailCurlPath;
  Result.SmtpUrl := Cfg.MailSmtpUrl;
  Result.SmtpUser := Cfg.MailSmtpUser;
  Result.SmtpPassword := Cfg.MailSmtpPassword;
  Result.FromAddress := Cfg.MailFrom;
  Result.FromName := Cfg.MailFromName;
  Result.SendmailPath := Cfg.MailSendmailPath;
  Result.CommandTemplate := Cfg.MailCommand;
  Result.TimeoutSeconds := Cfg.MailTimeoutSeconds;
end;

procedure TZSEngine.Run;
var
  Batch: TZSEventArray;
  Count, i: LongInt;
  T0: Int64;
begin
  try
    Service := TServiceThread.Create;
    Service.SetMailSettings(MailSettingsOf(Cfg));
    EnterCriticalSection(StateLock);
    FLoadMs := MonoMs;
    try
      DB.SetNow(Now);
      LoadData;
    finally
      FLoadMs := MonoMs - FLoadMs;
      LeaveCriticalSection(StateLock);
    end;
  except
    on E: Exception do
    begin
      FReadOnly := True;
      LoadMessage := 'loading failed: ' + E.Message;
      WriteServer('[ZitroStats] ERROR: ' + LoadMessage + ' - statistics are NOT saved');
    end;
  end;
  { the library file is read and hashed here, not on the game thread }
  try
    NoteLibrary(FLibraryPath);
  except
  end;
  FReady := True;
  FLastFlushMs := MonoMs;
  FLastSharedFlushMs := FLastFlushMs;
  FLastSnapshotMs := FLastFlushMs;
  FLastInfoMs := FLastFlushMs;

  while True do
  begin
    RTLEventWaitFor(FEventWake, 50);
    { the game thread gets an empty array with room at once, so it never allocates }
    EnterCriticalSection(FEventLock);
    Batch := FEvents;
    Count := FEventCount;
    FEvents := FEventSpare;
    FEventSpare := nil;
    FEventCount := 0;
    LeaveCriticalSection(FEventLock);

    if Count > PerfBatchMax then
      PerfBatchMax := Count;
    for i := 0 to Count - 1 do
    begin
      EnterCriticalSection(StateLock);
      try
        T0 := MicroNow;
        try
          ProcessEvent(Batch[i]);
        except
          on Ex: Exception do
            ReportError('event ' + IntToStr(Ord(Batch[i].Kind)), Ex);
        end;
        T0 := MicroNow - T0;
        Inc(PerfEvents);
        Inc(PerfEventMicros, T0);
        if T0 > PerfEventMaxMicros then
          PerfEventMaxMicros := T0;
      finally
        LeaveCriticalSection(StateLock);
      end;
      Inc(FProcessed);
      { command texts may carry passwords }
      if Batch[i].Kind = zeCommand then
        WipeString(Batch[i].S1);
      Batch[i].S1 := '';
      Batch[i].S2 := '';
      Batch[i].S3 := '';
      Batch[i].S4 := '';
    end;
    { the emptied array is the next one the game thread fills }
    if Length(Batch) <= EVENT_SPARE_MAX then
      FEventSpare := Batch;
    Batch := nil;

    EnterCriticalSection(StateLock);
    try
      T0 := MicroNow;
      try
        { the game thread places joins from this picture; it follows every change of the teams }
        if Bal.Dirty and FReady then
          BalRefreshSnapshot;
        if FReady and not FIntegritySent then
        begin
          FIntegritySent := True;
          SendIntegrityConfig;
        end;
        Timers;
      except
        on Ex: Exception do
          ReportError('timers', Ex);
      end;
      T0 := MicroNow - T0;
      Inc(PerfTimerRuns);
      Inc(PerfTimerMicros, T0);
      if T0 > PerfTimerMaxMicros then
        PerfTimerMaxMicros := T0;
    finally
      LeaveCriticalSection(StateLock);
    end;
    if FStopping then
      Break;
  end;
  FinishShutdown;
end;

procedure TZSEngine.FinishShutdown;
begin
  EnterCriticalSection(StateLock);
  try
    try
      { the last changes into the shared database (Engine = mysql), a few seconds at most }
      if SqlState <> nil then
        SqlShutdown(Self);
      if (Writer <> nil) and not FReadOnly then
      begin
        { The game thread waits for this (the script is unloaded), so only what is not on disk
          yet is written: the journal. A snapshot that is still being written is dropped; the
          next start reads the last complete one and replays the journal after it, on the
          engine thread. }
        if DB.SnapshotActive then
        begin
          if FSnapTag = SNAP_BACKUP then
            FBackupInFlight := False;
          DB.AbortSnapshot(Writer);
        end;
        DB.FlushJournal(Writer, True);
      end;
    except
      on Ex: Exception do
        ReportError('shutdown', Ex);
    end;
  finally
    LeaveCriticalSection(StateLock);
  end;
  MirrorShutdown(Self);
  if IO <> nil then
    IO.StopAndWait;
  FreeAndNil(Writer);
  FreeAndNil(IO);
  if Service <> nil then
    Service.StopAndWait;
  FreeAndNil(Service);
end;

{ ---------------- loading ---------------- }

procedure TZSEngine.LoadData;
var
  St: TStoreState;
  Info: TStoreLoadInfo;
  Res: TStoreLoadResult;
  L: TStringList;
  k: LongInt;
  Migrated: Boolean;
begin
  EnsureDir(DataDir);
  if LogDir <> '' then
    EnsureDir(LogDir);
  IO := TStoreIO.Create(DataDir, Cfg.SnapshotFile, Cfg.JournalFile);
  if IO.LockError <> '' then
  begin
    FReadOnly := True;
    LoadMessage := IO.LockError;
    WriteServer('[ZitroStats] ERROR: ' + IO.LockError + ' - statistics are NOT saved');
  end;

  Migrated := False;
  Res := StoreLoad(DataDir, Cfg.SnapshotFile, Cfg.JournalFile, St, Info);
  FMaxGen := Info.MaxGen;
  L := TStringList.Create;
  try
    L.Text := Info.Messages;
    for k := 0 to L.Count - 1 do
      if Trim(L[k]) <> '' then
        WriteServer('[ZitroStats] storage: ' + L[k]);
  finally
    L.Free;
  end;

  case Res of
    slLoaded:
      begin
        DB.TakeState(St);
        WriteServer(Format('[ZitroStats] %d accounts, %d maps loaded (snapshot %d + %d journal records)',
          [DB.LiveProfiles, DB.MapCount, Int64(Info.SnapshotGen), Info.JournalRecords]));
      end;
    slEmpty:
      if not Info.NewerFormat then
        Migrated := MigrateLegacy(St);
    slFailed:
      begin
        FReadOnly := True;
        FLoadFailed := True;
        LoadMessage := 'the database could not be read';
        WriteServer('[ZitroStats] ERROR: the database in ' + DataDir +
          ' could not be read. Statistics are NOT saved until it is repaired or restored.');
        if Cfg.RestoreOnDamage and (IO.LockError = '') and not Info.NewerFormat and AutoRestoreBackup then
        begin
          FReadOnly := False;
          FLoadFailed := False;
        end
        else if not Info.NewerFormat then
          WriteServer('[ZitroStats] an admin can load a backup with /zs_backups and /zs_restore <file>.');
      end;
  end;
  { a database of a newer ZitroStats is never overwritten or replaced by a backup of this older
    library, whatever else could be read: the statistics stay off until the newer one runs }
  if Info.NewerFormat then
  begin
    FReadOnly := True;
    LoadMessage := 'the database was written by a newer ZitroStats';
    WriteServer('[ZitroStats] ERROR: the database in ' + DataDir + ' was written by a newer ZitroStats. ' +
      'Statistics are NOT saved: use main.pas and zitrostats_dll of that release.');
  end;

  if not FReadOnly and (Writer = nil) then
  begin
    Writer := TStoreWriter.Create(IO, Info.MaxGen);
    if Migrated or (Res = slEmpty) then
    begin
      { store the imported or fresh database before the first change }
      DB.BeginSnapshot(Writer);
      while not DB.ContinueSnapshot(Writer, MaxInt) do ;
      Writer.CommitSnapshot(SNAP_ROUTINE, '');
    end;
  end;

  { Engine = mysql: the shared database replaces what the files hold, and the files keep a copy }
  if (Cfg.MySQLEngine = MYSQL_SHARED) and not FReadOnly and (Writer <> nil) then
    if SqlStart(Self) then
      StartSnapshot(SNAP_ROUTINE, '');
  LoadSuspects;
  BalLoadHistory;
  UpdateLeagues(DB, Cfg);
  if SeasonDue(DB, Cfg) and (DB.Server.SeasonId <= 0) and (SqlState = nil) then
    StartSeason(DB, Cfg);
end;

{ Files that could not be read are renamed, never deleted, so they can still be repaired or
  examined after the server has continued from a backup. }
procedure TZSEngine.ArchiveDamagedFiles;
var
  L: TStringList;
  k, c: LongInt;
  Stamp, Path, Base, Ext, Name, Gen, Failed: AnsiString;
  Journal: Boolean;
begin
  Stamp := '.damaged-' + FormatDateTime('yyyymmdd-hhnnss', Now);
  { a file another program holds open cannot be renamed: it is named in the console, and the
    store never empties or replays such a journal }
  Failed := '';
  Path := StorePath(DataDir, Cfg.SnapshotFile);
  if FileExists(Path) and not RenameFile(Path, Path + Stamp) then
    Failed := Failed + ' ' + ExtractFileName(Path);
  if FileExists(Path + '.prev') and not RenameFile(Path + '.prev', Path + '.prev' + Stamp) then
    Failed := Failed + ' ' + ExtractFileName(Path + '.prev');
  if FileExists(Path + '.tmp') and not RenameFile(Path + '.tmp', Path + '.tmp' + Stamp) then
    Failed := Failed + ' ' + ExtractFileName(Path + '.tmp');
  { Engine = mysql: what waited for the shared database belonged to those files }
  Path := StorePath(DataDir, ChangeFileExt(Cfg.SnapshotFile, '.shared'));
  if FileExists(Path) and not RenameFile(Path, Path + Stamp) then
    Failed := Failed + ' ' + ExtractFileName(Path);
  { Journals are named <base>.<generation><extension> (JournalFileName in zs_store), and only they
    are renamed: <base>.* alone also takes the lock file this server holds (zitrostats.lock -
    renamed on Linux, it lets a second server lock the same folder) and the files renamed above. }
  Ext := ExtractFileExt(Cfg.JournalFile);
  if Ext = '' then
    Ext := '.journal';
  Base := ChangeFileExt(ExtractFileName(Cfg.JournalFile), '');
  L := ListFiles(DataDir, Base + '.*' + Ext);
  try
    for k := 0 to L.Count - 1 do
    begin
      Name := L[k];
      Gen := Copy(Name, Length(Base) + 2, Length(Name) - Length(Base) - 1 - Length(Ext));
      Journal := (Gen <> '') and SameText(Copy(Name, 1, Length(Base) + 1), Base + '.') and
        SameText(Copy(Name, Length(Name) - Length(Ext) + 1, Length(Ext)), Ext);
      for c := 1 to Length(Gen) do
        if not (Gen[c] in ['0'..'9']) then
          Journal := False;
      if Journal then
        if not RenameFile(StorePath(DataDir, Name), StorePath(DataDir, Name) + Stamp) then
          Failed := Failed + ' ' + Name;
    end;
  finally
    L.Free;
  end;
  WriteServer('[ZitroStats] the unreadable files were renamed to *' + Stamp);
  if Failed <> '' then
    WriteServer('[ZitroStats] WARNING: could not rename (held open by another program?):' + Failed);
end;

{ Newest backup first: the first one that reads completely becomes the live database. }
function TZSEngine.AutoRestoreBackup: Boolean;
var
  L: TStringList;
  St: TStoreState;
  Info: TStoreLoadInfo;
  k: LongInt;
begin
  Result := False;
  L := ListBackups(BackupDir);
  try
    for k := L.Count - 1 downto 0 do
    begin
      if not StoreLoadFile(StorePath(BackupDir, L[k]), St, Info) then
      begin
        WriteServer('[ZitroStats] backup ' + L[k] + ' cannot be read either, trying an older one.');
        Continue;
      end;
      ArchiveDamagedFiles;
      DB.TakeState(St);
      Writer := TStoreWriter.Create(IO, FMaxGen);
      DB.BeginSnapshot(Writer);
      while not DB.ContinueSnapshot(Writer, MaxInt) do ;
      Writer.CommitSnapshot(SNAP_ROUTINE, '');
      LoadMessage := 'the damaged database was replaced by backup ' + L[k];
      WriteServer(Format('[ZitroStats] %d accounts restored from backup %s, statistics are saved again.',
        [DB.LiveProfiles, L[k]]));
      Exit(True);
    end;
  finally
    L.Free;
  end;
end;

function TZSEngine.MigrateLegacy(var St: TStoreState): Boolean;
var
  Path, Err: AnsiString;
  Profiles: TProfilePtrArray;
  Maps: TMapProfileArray;
  Count, Version, NextId, Reassigned, NextMap, k: LongInt;
  Phantoms: Int64;
begin
  Result := False;
  ClearStoreState(St);

  Path := ResolvePath(Cfg.LegacyAccountsBin);
  if FileExists(Path) then
  begin
    if not LegacyLoadAccountsBin(Path, Profiles, Count, Version, Err) then
    begin
      FReadOnly := True;
      LoadMessage := Err;
      WriteServer('[ZitroStats] ERROR: import of ' + Path + ' failed: ' + Err +
        '. Nothing was written; fix or remove the file and restart.');
      DB.TakeState(St);
      Exit;
    end;
    if Err <> '' then
      WriteServer('[ZitroStats] import: ' + Err);
    WriteServer(Format('[ZitroStats] imported %d accounts from %s (format v%d)', [Count, Path, Version]));
  end
  else
  begin
    Path := ResolvePath(Cfg.LegacyAccountsDb);
    if FileExists(Path) then
    begin
      if not LegacyImportAccountsDb(Path, Profiles, Count, Err) then
      begin
        FReadOnly := True;
        LoadMessage := Err;
        WriteServer('[ZitroStats] ERROR: import of ' + Path + ' failed: ' + Err);
        DB.TakeState(St);
        Exit;
      end;
      { an import that worked may still say what it left out ("trailing lines ignored") }
      if Err <> '' then
        WriteServer('[ZitroStats] import: ' + Err);
      WriteServer(Format('[ZitroStats] imported %d accounts from %s', [Count, Path]));
    end
    else
      Count := 0;
  end;
  if Count > 0 then
  begin
    LegacyAssignProfileIds(Profiles, Count, NextId, Reassigned);
    if Reassigned > 0 then
      WriteServer(Format('[ZitroStats] import: %d duplicate or invalid account ids replaced', [Reassigned]));
    St.Profiles := Profiles;
    St.ProfileCount := Count;
    St.Server.NextProfileID := NextId;
    Result := True;
  end;

  Path := ResolvePath(Cfg.LegacyMapsBin);
  Count := 0;
  if FileExists(Path) then
  begin
    if LegacyLoadMapsBin(Path, Maps, Count, Version, Err) then
    begin
      if Err <> '' then
        WriteServer('[ZitroStats] import: ' + Err);
      WriteServer(Format('[ZitroStats] imported %d maps from %s', [Count, Path]));
    end
    else
      WriteServer('[ZitroStats] import of ' + Path + ' failed: ' + Err + ' (maps start empty)');
  end
  else
  begin
    Path := ResolvePath(Cfg.LegacyMapsDb);
    if FileExists(Path) and LegacyImportMapsDb(Path, Maps, Count, Err) then
      WriteServer(Format('[ZitroStats] imported %d maps from %s', [Count, Path]));
  end;
  if Count > 0 then
  begin
    LegacyAssignMapIds(Maps, Count, NextMap, Reassigned);
    St.Maps := Maps;
    St.MapCount := Count;
    St.Server.NextMapID := NextMap;
    for k := 0 to Count - 1 do
      St.Maps[k].LoadCount := St.Maps[k].ActiveMapPlays;
    Result := True;
  end;

  Path := ResolvePath(Cfg.LegacyServerRecords);
  if LegacyImportServerRecords(Path, St.Server, Phantoms) then
  begin
    WriteServer(Format('[ZitroStats] imported server records from %s (%d double-counted matchups removed)',
      [Path, Phantoms]));
    Result := True;
  end;
  DB.TakeState(St);
end;

{ ---------------- queues ---------------- }

procedure TZSEngine.PushEvent(const E: TZSEvent);
var
  Wake: Boolean;
begin
  Wake := False;
  EnterCriticalSection(FEventLock);
  try
    if (FEventCount >= EVENT_LIMIT) and not (E.Kind in [zeJoin, zeLeave, zeMapBefore, zeMapAfter, zeShutdown, zeMapList]) then
    begin
      Inc(FEventsDropped);
      Exit;
    end;
    if FEventCount >= Length(FEvents) then
      SetLength(FEvents, Length(FEvents) * 2 + 256);
    FEvents[FEventCount] := E;
    Inc(FEventCount);
    { the engine takes everything that is queued at once: one wake-up for the first event is
      enough, and the engine thread is not woken for every event of a busy tick }
    Wake := FEventCount = 1;
  finally
    LeaveCriticalSection(FEventLock);
  end;
  if Wake then
    RTLEventSetEvent(FEventWake);
end;

procedure TZSEngine.EmitAction(const A: TZSAction);
var
  n, i: LongInt;
begin
  CrashTrail('emit', A.Kind, A.Slot);
  EnterCriticalSection(FActionLock);
  try
    if FActionCount - FActionRead >= ACTION_LIMIT then
      Exit;
    if FActionCount >= Length(FActions) then
    begin
      { move what is still waiting to the front; the places the paced output already took
        (Kind 0) go }
      n := 0;
      for i := FActionRead to FActionCount - 1 do
        if FActions[i].Kind <> ACT_NONE then
        begin
          if i <> n then
            FActions[n] := FActions[i];
          Inc(n);
        end;
      for i := n to FActionCount - 1 do
      begin
        FActions[i].Kind := ACT_NONE;
        FActions[i].Text := '';
      end;
      FActionCount := n;
      FActionRead := 0;
      FPaceScan := 0;
      if FActionCount >= Length(FActions) then
        SetLength(FActions, Length(FActions) * 2 + 256);
    end;
    FActions[FActionCount] := A;
    Inc(FActionCount);
  finally
    LeaveCriticalSection(FActionLock);
  end;
end;

{ which queue an action waits in: every player has one, so the output of one player keeps its
  order; lines to everybody and to the console share one, ray casts have one, and the settings
  of the score guard are never held back }
function TZSEngine.PaceStream(const A: TZSAction): LongInt;
begin
  case A.Kind of
    ACT_CONSOLE, ACT_BIGTEXT, ACT_KICK, ACT_SETTEAM, ACT_MOVE:
      if (A.Slot >= 1) and (A.Slot <= MAX_PLAYERS) then
        Result := A.Slot
      else
        Result := 0;
    ACT_BROADCAST, ACT_WRITELN:
      Result := PACE_SERVER_TEXT;
    ACT_RAYCAST:
      Result := PACE_RAY_STREAM;
  else
    Result := PACE_STREAMS;
  end;
end;

{ may this action still go out in this tick; if so, it is counted }
function TZSEngine.PaceAllows(const A: TZSAction; Stream: LongInt): Boolean;
begin
  Result := False;
  case A.Kind of
    ACT_CONSOLE, ACT_BIGTEXT:
      begin
        if (FPaceLines >= PACE_LINES) or (FPaceSlotLines[Stream] >= PACE_PLAYER_LINES) then
          Exit;
        Inc(FPaceLines);
        Inc(FPaceSlotLines[Stream]);
      end;
    { a kick rewrites the ban lists and runs every script's OnLeave: counted like a move }
    ACT_MOVE, ACT_SETTEAM, ACT_KICK:
      begin
        if FPaceMoves >= PACE_MOVES then
          Exit;
        Inc(FPaceMoves);
      end;
    ACT_BROADCAST:
      begin
        if FPaceBroadcasts >= PACE_BROADCASTS then
          Exit;
        Inc(FPaceBroadcasts);
      end;
    ACT_WRITELN:
      begin
        if FPaceWrites >= PACE_WRITES then
          Exit;
        Inc(FPaceWrites);
      end;
    ACT_RAYCAST:
      begin
        if FPaceRays >= PACE_RAYS then
          Exit;
        Inc(FPaceRays);
      end;
  end;
  Result := True;
end;

{ The script opens every tick with this (ZS_Action_Begin); from then on PopAction keeps to the
  limits of a tick. Returns how many actions wait, so an empty tick costs one call - and 0 for a
  tick that comes right after the last one (Soldat catching up after a stall). A script that
  never calls it gets every action in order, without limits. }
function TZSEngine.BeginActions: LongInt;
var
  T: Int64;
begin
  Result := 0;
  EnterCriticalSection(FActionLock);
  try
    T := MicroNow;
    if FPaceOn and (T - FPaceLastUs < PACE_TICK_US) then
      Exit;
    FPaceLastUs := T;
    FPaceOn := True;
    FPaceScan := FActionRead;
    FPaceLines := 0;
    FPaceMoves := 0;
    FPaceBroadcasts := 0;
    FPaceWrites := 0;
    FPaceRays := 0;
    FillChar(FPaceSlotLines, SizeOf(FPaceSlotLines), 0);
    FillChar(FPaceHeld, SizeOf(FPaceHeld), 0);
    Result := FActionCount - FActionRead;
  finally
    LeaveCriticalSection(FActionLock);
  end;
end;

function TZSEngine.PopAction(out A: TZSAction): Boolean;
var
  i, S: LongInt;
begin
  Result := False;
  EnterCriticalSection(FActionLock);
  try
    { Every place before FPaceScan was either taken or belongs to a queue that is held for the
      rest of the tick, so the search goes on from there: each action is looked at once a tick. }
    if FPaceOn then
      i := Max(FPaceScan, FActionRead)
    else
      i := FActionRead;
    while i < FActionCount do
    begin
      if FActions[i].Kind <> ACT_NONE then
      begin
        if not FPaceOn then
          Result := True
        else
        begin
          S := PaceStream(FActions[i]);
          if not FPaceHeld[S] then
          begin
            Result := PaceAllows(FActions[i], S);
            { a queue that could not send holds everything behind it until the next tick }
            if not Result then
              FPaceHeld[S] := True;
          end;
        end;
        if Result then
        begin
          A := FActions[i];
          FActions[i].Kind := ACT_NONE;
          FActions[i].Text := '';
          FPaceScan := i + 1;
          while (FActionRead < FActionCount) and (FActions[FActionRead].Kind = ACT_NONE) do
            Inc(FActionRead);
          if FActionRead >= FActionCount then
          begin
            FActionRead := 0;
            FActionCount := 0;
            FPaceScan := 0;
          end;
          Exit;
        end;
      end;
      Inc(i);
    end;
    FPaceScan := i;
  finally
    LeaveCriticalSection(FActionLock);
  end;
end;

procedure TZSEngine.ProcessEvent(var E: TZSEvent);
begin
  if E.Tick > GameTick then
    GameTick := E.Tick;
  DB.SetNow(Now);
  { every death of the tick that decided a survival round is in }
  if Match.RoundPending and (GameTick <> Match.RoundTick) then
    RoundSettle;
  if not (E.Kind in [zeSample, zeTick, zeShot, zeDamage, zeWeapon, zeGrenade, zeKnifeThrow, zeAmmo, zeHeal]) then
    CrashTrail('event', Ord(E.Kind), E.Slot);
  case E.Kind of
    zeJoin: EvJoin(E);
    zeLeave: EvLeave(E);
    zeTeam: EvTeam(E);
    zeSteamAuth: EvSteamAuth(E);
    zeSpawn: EvSpawn(E);
    zeKill: EvKill(E);
    zeDamage: EvDamage(E);
    zeShot: EvShot(E);
    zeAmmo: EvAmmo(E);
    zeRealistic: EvRealistic(E);
    zeHeal: EvHeal(E);
    zeGrenade: EvGrenade(E);
    zeKnifeThrow: EvKnifeThrow(E);
    zeWeapon: EvWeapon(E);
    zeKit: EvKit(E);
    zeFlag: EvFlag(E);
    zeSample: EvSample(E);
    zeTick: EvTick(E);
    zeMapBefore: EvMapBefore(E);
    zeMapAfter: EvMapAfter(E);
    zePlayerScore: EvPlayerScore(E);
    zeVote: EvVote(E);
    zeRay: EvRay(E);
    zeTeamRequest: EvTeamRequest(E);
    zeMoveResult: EvMoveResult(E);
    zeIntegrity: EvIntegrity(E);
    zeMapList: EvMapList(E);
    zeCommand: EvCommand(E);
    zeReloadConfig: EvReloadConfig(E);
    zeShutdown: FStopping := True;
  end;
end;

{ ---------------- timers and persistence ---------------- }

procedure TZSEngine.Timers;
var
  NowMs: Int64;
begin
  NowMs := MonoMs;
  DB.SetNow(Now);
  if NowMs - FLastSecondMs >= 1000 then
  begin
    FLastSecondMs := NowMs;
    Identity.Tick;
    WallSecond;
  end;
  PollResults;
  MapVoteTimers(NowMs);
  if not FReadOnly and (Writer <> nil) then
    PersistenceTimers(NowMs);
  { a read-only engine holds data it may not save; exporting it could overwrite the files of the
    server that owns the data }
  if not FReadOnly then
  begin
    ExportTick(Self, NowMs);
    MirrorTick(Self, NowMs);
    if SqlState <> nil then
      SqlTick(Self, NowMs);
  end;
end;

procedure TZSEngine.WallSecond;
var
  Rep: TBalanceReport;
  H, M, S, MS: Word;
  Today, Idx, k: LongInt;
  NowMs: Int64;
  Line: AnsiString;

  { a big line above the HUD for the admin who has to answer /yes or /no; it fades by itself }
  procedure ConfirmCountdown(const Text: AnsiString);
  var
    A: TZSAction;
  begin
    if not SlotValid(Pending.AdminSlot) or not Live[Pending.AdminSlot].Human then
      Exit;
    A := NewAction(ACT_BIGTEXT, Pending.AdminSlot, CLR_WARN, Text);
    A.P1 := Cfg.HudLayer + 1;
    A.P2 := Cfg.HudX;
    A.P3 := Max(0, Cfg.HudY - 26);
    A.F1 := Cfg.HudScale;
    A.F2 := TICKS_PER_SECOND + TICKS_PER_SECOND div 3;
    EmitAction(A);
  end;

begin
  NowMs := MonoMs;
  DecodeTime(Now, H, M, S, MS);
  Today := DayKey(Now);
  if (Pending.Kind <> OP_NONE) and not Pending.WaitingBackup then
    if Now > Pending.Expires then
    begin
      { a confirmation nobody answered must not keep a new password in memory }
      Say(Pending.AdminSlot, 'The time to confirm is over, nothing was changed.', CLR_WARN);
      ClearPending;
    end
    else
      ConfirmCountdown(Format('Confirm: /yes <password> or /no  (%d s)', [Max(1, Ceil((Pending.Expires - Now) * 86400))]));
  { with one database for several servers only one of them does it (zs_sqldb) }
  if (DB.Server.LastBalanceDay <> Today) and (H >= Cfg.BalanceHour) and FReady and not FReadOnly and
     ((SqlState = nil) or SqlJob(Self, 'balance', Today)) then
  begin
    DB.Server.LastBalanceDay := Today;
    DB.TouchServer;
    DailyMaintenance(DB, Cfg, Rep);
    { kept up to date even while the tiers are shown instead of the leagues }
    UpdateLeagues(DB, Cfg);
    ScanForSuspects;
    Line := Format('daily balance (%s): %d accounts, %d active, %d inactive, protection used %d, collected %d, paid %d to %d; check points +%d -%d',
      [Cfg.InactivityMode, Rep.Accounts, Rep.Active, Rep.Inactive, Rep.ProtectionUsed, Rep.Collected, Rep.Paid,
       Rep.Recipients, Rep.CheckPaid, Rep.CheckTaken]);
    if Rep.CheckForced > 0 then
      Line := Line + Format(', %d of it from the least active accounts after the surplus waited %d days ' +
        '(CheckPointsMaxWaitDays)', [Rep.CheckForced, Rep.CheckWaitDays]);
    if Rep.CheckWaiting > 0 then
    begin
      Line := Line + Format(' (%d more is left over, waiting %d day(s): it is taken from inactive accounts without ' +
        'protection days, a little every day', [Rep.CheckWaiting, Rep.CheckWaitDays]);
      if Cfg.CheckPointsMaxWaitDays > 0 then
        Line := Line + Format(', and after %d days from the least active accounts', [Cfg.CheckPointsMaxWaitDays]);
      Line := Line + ')';
    end;
    if Rep.MatrixPruned > 0 then
      Line := Line + Format('; %d player-on-map records of accounts not seen for %d days removed ([Matrix] MatrixPruneDays)',
        [Rep.MatrixPruned, Cfg.MatrixPruneDays]);
    WriteServer('[ZitroStats] ' + Line);
    AppendLog('balance.log', Line);
    if DB.HideAfterDays > 0 then
      DB.RebuildRanks;
  end;

  if SeasonDue(DB, Cfg) and ((SqlState = nil) or SqlJob(Self, 'season', DB.Server.SeasonId)) then
  begin
    if DB.Server.SeasonId > 0 then
    begin
      Idx := ArchiveSeason(DB, Cfg);
      if (Idx >= 0) and not FReadOnly then
        WebhookSeason(Self, Idx);
      if (Idx >= 0) and Cfg.SeasonBroadcast then
      begin
        Broadcast(Format('Season %d is over!', [DB.Seasons[Idx].Id]), CLR_HEADER);
        for k := 0 to Min(2, High(DB.Seasons[Idx].Entries)) do
          Broadcast(Format('  %d. %s  %+d pts', [k + 1, DB.Seasons[Idx].Entries[k].Name,
            DB.Seasons[Idx].Entries[k].SeasonPoints]), CLR_TOP1);
      end;
    end;
    StartSeason(DB, Cfg);
    if Cfg.SeasonBroadcast then
      Broadcast(Format('Season %d has started. Standings: !topseason', [DB.Server.SeasonId]), CLR_SUBHEADER);
  end;

  if (Cfg.InfoBroadcastSeconds > 0) and (Trim(Cfg.InfoBroadcastText) <> '') and
     (NowMs - FLastInfoMs >= Int64(Cfg.InfoBroadcastSeconds) * 1000) then
  begin
    FLastInfoMs := NowMs;
    if HumansOnline > 0 then
      Broadcast(Cfg.InfoBroadcastText, CLR_HINT);
  end;
end;

function TZSEngine.SnapshotBusy: Boolean;
begin
  Result := (Writer = nil) or DB.SnapshotActive or (Pending.WaitingBackup);
end;

procedure TZSEngine.StartSnapshot(Tag: LongInt; const BackupPath: AnsiString);
begin
  if (Writer = nil) or FReadOnly or DB.SnapshotActive then
    Exit;
  FSnapTag := Tag;
  FSnapBackupPath := BackupPath;
  DB.BeginSnapshot(Writer);
  FLastSnapshotMs := MonoMs;
end;

function TZSEngine.BackupFileName(const Reason: AnsiString): AnsiString;
begin
  Result := StorePath(BackupDir, 'zitrostats-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + Reason + '.zsdb');
end;

procedure TZSEngine.PersistenceTimers(NowMs: Int64);
var
  Shared: Boolean;
begin
  if DB.SnapshotActive then
  begin
    if IO.PendingBytes < SNAPSHOT_IO_HIGH_WATER then
      if DB.ContinueSnapshot(Writer, SNAPSHOT_BUDGET) then
        Writer.CommitSnapshot(FSnapTag, FSnapBackupPath);
  end;

  if NowMs - FLastFlushMs >= Int64(Max(1, Cfg.JournalFlushSeconds)) * 1000 then
  begin
    Shared := NowMs - FLastSharedFlushMs >= 60000;
    DB.FlushJournal(Writer, Shared);
    FLastFlushMs := NowMs;
    if Shared then
      FLastSharedFlushMs := NowMs;
  end;

  if DB.SnapshotActive or (NowMs < FSnapRetryMs) then
    Exit;
  if (Cfg.AutoBackupDays > 0) and not FBackupInFlight and (Now - DB.Server.LastAutoBackup >= Cfg.AutoBackupDays) then
  begin
    { the date is stored once the IO thread confirms the file; until then no second backup }
    FBackupInFlight := True;
    StartSnapshot(SNAP_BACKUP, BackupFileName('auto'));
  end
  else if (Writer.JournalBytes >= Int64(Max(1, Cfg.CompactJournalMB)) * 1024 * 1024) or
          ((Writer.JournalBytes > 0) and (NowMs - FLastSnapshotMs >= Int64(Max(5, Cfg.CompactIntervalMinutes)) * 60000)) then
    StartSnapshot(SNAP_ROUTINE, '');
end;

procedure TZSEngine.PollResults;
var
  R: TStoreResult;
  SR: TServiceResult;
  Job: TStoreJob;
  Idx: LongInt;
begin
  if IO <> nil then
    while IO.PollResult(R) do
    begin
      if R.Kind = sjSnapshotCommit then
      begin
        if R.Tag = SNAP_BACKUP then
          FBackupInFlight := False;
        if R.Ok then
        begin
          case R.Tag of
            SNAP_BACKUP, SNAP_MANUAL, SNAP_PREOP:
              begin
                WriteServer('[ZitroStats] backup saved: ' + R.Message);
                if (R.Tag = SNAP_MANUAL) and (BackupAsker > 0) then
                  Say(BackupAsker, Format('[ZitroStats] Backup saved: %s (%d KB, %d accounts).',
                    [ExtractFileName(R.Message), R.Bytes div 1024, DB.LiveProfiles]), CLR_GOOD);
                if R.Tag = SNAP_MANUAL then
                  BackupAsker := -1;
                if R.Tag = SNAP_BACKUP then
                begin
                  DB.Server.LastAutoBackup := Now;
                  DB.TouchServer;
                  { only automatic backups rotate; manual and pre-operation backups stay }
                  Job := NewJob(sjPruneBackups);
                  Job.Path := BackupDir;
                  Job.Keep := Max(1, Cfg.BackupKeep);
                  IO.Enqueue(Job);
                end;
                if (R.Tag = SNAP_PREOP) and Pending.WaitingBackup then
                  RunPendingOp;
              end;
            SNAP_RESTORED:
              NotifyAdmins('[ZitroStats] restored database saved.', CLR_GOOD);
          end;
        end
        else
        begin
          WriteServer('[ZitroStats] ERROR: snapshot failed: ' + R.Message);
          FSnapRetryMs := MonoMs + 60000;
          if (R.Tag = SNAP_MANUAL) and (BackupAsker >= 0) then
          begin
            if BackupAsker > 0 then
              Say(BackupAsker, '[ZitroStats] The backup failed: ' + R.Message, CLR_BAD);
            BackupAsker := -1;
          end;
          if (R.Tag = SNAP_PREOP) and Pending.WaitingBackup then
          begin
            NotifyAdmins('[ZitroStats] The backup failed, the operation was cancelled.', CLR_BAD);
            ClearPending;
          end;
        end;
      end
      else if (R.Kind = sjWriteFile) and (R.Tag = TAG_EXPORT) then
      begin
        { /zs_export: every file that was asked for is written, or says why not }
        if R.Ok then
        begin
          if ExportAsker >= 0 then
            Say(ExportAsker, Format('[ZitroStats] Export written: %s (%d KB).', [R.Message, R.Bytes div 1024]),
              CLR_GOOD);
        end
        else
        begin
          WriteServer('[ZitroStats] storage: ' + R.Message);
          if ExportAsker > 0 then
            Say(ExportAsker, '[ZitroStats] The export failed: ' + R.Message, CLR_BAD);
        end;
      end
      else if (R.Kind = sjNotify) and (R.Tag = TAG_EXPORT_DONE) then
        ExportAsker := -1
      else if (R.Kind = sjNotify) and (R.Tag = TAG_SAVE) then
      begin
        { /zs_save: everything before this mark has been written }
        if SaveAsker >= 0 then
        begin
          if SaveFailed then
            Say(SaveAsker, '[ZitroStats] The changes could not be written; the next snapshot writes them (see the console).',
              CLR_BAD)
          else
            Say(SaveAsker, '[ZitroStats] All changes are written.', CLR_GOOD);
        end;
        SaveAsker := -1;
        SaveFailed := False;
      end
      else if not R.Ok then
      begin
        if (R.Kind = sjAppend) and (SaveAsker >= 0) then
          SaveFailed := True;
        WriteServer('[ZitroStats] storage: ' + R.Message);
        { a journal that cannot be written holds no change until the next snapshot, so write one
          now, at most one attempt per minute }
        if (R.Kind = sjAppend) and not FReadOnly and (Writer <> nil) and not DB.SnapshotActive and
           (MonoMs >= FSnapRetryMs) then
        begin
          FSnapRetryMs := MonoMs + 60000;
          WriteServer('[ZitroStats] the journal failed, writing a full snapshot instead.');
          StartSnapshot(SNAP_ROUTINE, '');
        end;
      end;
    end;
  if Service <> nil then
    while Service.PollResult(SR) do
    begin
      Identity.HandleServiceResult(SR);
      { /zs_setpass: the new password counts from here, once its hash is made and stored }
      if (SR.Kind = svHash) and (SR.Op = AUTH_ADMINSET) then
      begin
        Idx := DB.IndexOfId(SR.ProfileId);
        if SR.Ok and DB.Valid(Idx) and (SR.Hash <> '') and (DB.Profiles[Idx]^.PassHash = SR.Hash) then
          NotifyAdmins(Format('[ZitroStats] password of #%d %s was changed.', [SR.ProfileId,
            DB.Profiles[Idx]^.ActiveName]), CLR_GOOD)
        else
        begin
          Audit(Format('account #%d: the password set by an admin could not be stored', [SR.ProfileId]));
          NotifyAdmins(Format('[ZitroStats] password of #%d was not changed: the account is gone or its hash ' +
            'failed.', [SR.ProfileId]), CLR_BAD);
        end;
      end;
    end;
end;

{ ---------------- output ---------------- }

procedure TZSEngine.Say(Slot: LongInt; const Text: AnsiString; Color: LongInt);
begin
  if Slot <= 0 then
    WriteServer(Text)
  else if SlotValid(Slot) and Live[Slot].Human then
    EmitAction(NewAction(ACT_CONSOLE, Slot, Color, Text));
end;

procedure TZSEngine.Broadcast(const Text: AnsiString; Color: LongInt);
begin
  EmitAction(NewAction(ACT_BROADCAST, 0, Color, Text));
end;

procedure TZSEngine.WriteServer(const Text: AnsiString);
begin
  EmitAction(NewAction(ACT_WRITELN, 0, 0, Text));
end;

procedure TZSEngine.NotifyAdmins(const Text: AnsiString; Color: LongInt);
var
  S: LongInt;
begin
  WriteServer(Text);
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human and Live[S].Admin then
      EmitAction(NewAction(ACT_CONSOLE, S, Color, Text));
end;

{ a HUD entry that only says how many points changed hands ("+22 pts", "-18 pts") }
function PlainPointsEntry(const T: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := (Length(T) >= 6) and (T[1] in ['+', '-']) and (Copy(T, Length(T) - 3, 4) = ' pts');
  if Result then
    for k := 2 to Length(T) - 4 do
      if not (T[k] in ['0'..'9']) then
        Exit(False);
end;

{ HudUntil keeps one entry per note of HudEvents; when HudEvents was set on its own, the missing
  entries are notes not shown yet }
procedure FitHudUntil(var X: TSlotExtra);
var
  k, n: LongInt;
begin
  n := Length(X.HudEvents);
  k := Length(X.HudUntil);
  if k = n then
    Exit;
  SetLength(X.HudUntil, n);
  while k < n do
  begin
    X.HudUntil[k] := 0;
    Inc(k);
  end;
end;

{ The notes on the HUD line: what happened since it was drawn last, and what it shows for
  [HUD] EventSeconds (RefreshHud draws it once a second). At most HUD_EVENTS_MAX: when they are
  full, a new note pushes out the oldest one that had its time on the HUD already (a plain points
  entry first - the points are on the same line anyway), else the oldest plain points entry, so a
  burst of kills still shows its "Triple kill!" or "RAMPAGE!" instead of the points of the first
  kill. }
procedure TZSEngine.HudEvent(Slot: LongInt; const Text: AnsiString);
var
  n, k, Pass, Drop: LongInt;
begin
  { !lastfight keeps what the HUD told the player: points, assists, feats }
  LastFightNote(Self, Slot, Text);
  if not SlotValid(Slot) or not Live[Slot].Human then
    Exit;
  FitHudUntil(Extra[Slot]);
  n := Length(Extra[Slot].HudEvents);
  if n >= HUD_EVENTS_MAX then
  begin
    Drop := -1;
    for Pass := 0 to 2 do
    begin
      for k := 0 to n - 1 do
        if ((Pass = 0) and (Extra[Slot].HudUntil[k] <> 0) and PlainPointsEntry(Extra[Slot].HudEvents[k])) or
           ((Pass = 1) and (Extra[Slot].HudUntil[k] <> 0)) or
           ((Pass = 2) and PlainPointsEntry(Extra[Slot].HudEvents[k])) then
        begin
          Drop := k;
          Break;
        end;
      if Drop >= 0 then
        Break;
    end;
    if Drop < 0 then
      Exit;
    k := Drop;
    while k < n - 1 do
    begin
      Extra[Slot].HudEvents[k] := Extra[Slot].HudEvents[k + 1];
      Extra[Slot].HudUntil[k] := Extra[Slot].HudUntil[k + 1];
      Inc(k);
    end;
    Extra[Slot].HudEvents[n - 1] := Text;
    Extra[Slot].HudUntil[n - 1] := 0;
    Exit;
  end;
  SetLength(Extra[Slot].HudEvents, n + 1);
  SetLength(Extra[Slot].HudUntil, n + 1);
  Extra[Slot].HudEvents[n] := Text;
  Extra[Slot].HudUntil[n] := 0;
end;

procedure TZSEngine.AppendLog(const FileName, Line: AnsiString);
var
  Job: TStoreJob;
begin
  if (IO = nil) or (LogDir = '') then
    Exit;
  Job := NewJob(sjAppendText);
  Job.Path := StorePath(LogDir, FileName);
  Job.Data := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Line + LineEnding;
  IO.Enqueue(Job);
end;

{ One line saying exactly which library file the server runs, plus a note about copies left over
  from older versions. }
procedure TZSEngine.NoteLibrary(const Path: AnsiString);
var
  F: TFileStream;
  Ctx: TSha256Ctx;
  D: TSha256Digest;
  Buf: array[0..32767] of Byte;
  n: LongInt;
  Hash, Root, Own, Dir: AnsiString;

  procedure NoteOldCopy(const P: AnsiString);
  begin
    if FileExists(P) and (CompareText(ExpandFileName(P), Own) <> 0) then
      WriteServer('[ZitroStats] note: ' + P + ' is an unused copy of the library and can be deleted.');
  end;

begin
  if FLibraryNoted or (Path = '') then
    Exit;
  FLibraryNoted := True;
  Own := ExpandFileName(Path);
  Hash := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Sha256Init(Ctx);
      repeat
        n := F.Read(Buf, SizeOf(Buf));
        if n > 0 then
          Sha256Update(Ctx, @Buf[0], n);
      until n <= 0;
      Sha256Final(Ctx, D);
      Hash := BytesToHex(DigestToStr(D));
    finally
      F.Free;
    end;
  except
    Hash := '';
  end;
  if Hash <> '' then
    WriteServer(Format('[ZitroStats] library %s (%d bytes, sha256 %s)', [Own, FileSizeOf(Path), Hash]))
  else
    WriteServer('[ZitroStats] library ' + Own);

  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(ScriptDir));
  Root := ExtractFileDir(ExtractFileDir(Dir));
  if Root <> '' then
  begin
    NoteOldCopy(StorePath(Root, 'zitrostats_dll.dll'));
    NoteOldCopy(StorePath(Root, 'zitrostats_dll.so'));
  end;
  if CompareText(ExcludeTrailingPathDelimiter(ExtractFileDir(Own)), Dir) <> 0 then
    WriteServer('[ZitroStats] WARNING: the library runs from ' + ExtractFileDir(Own) +
      ' instead of the script folder ' + Dir + '.');
end;

{ A second player on the same computer (Kind 1), address (2) or Steam account (3). Mode allow does
  nothing, warn tells the admins, kick removes the player who joined later. False = kicked. }
function TZSEngine.CheckDuplicate(S: LongInt; const What, Mode: AnsiString; Kind: LongInt; const Value: AnsiString): Boolean;
var
  k: LongInt;
  V, Other: AnsiString;
begin
  Result := True;
  V := Copy(Trim(Value), 1, MAX_STRING_LEN - 1);
  if Kind = 3 then
  begin
    V := NormalizeSteam(V);
    if not IsRealSteam(V) then
      Exit;
  end;
  if (V = '') or SameText(Mode, 'allow') then
    Exit;
  for k := 1 to MAX_PLAYERS do
  begin
    if (k = S) or not Live[k].Active or not Live[k].Human or not Identity.Slots[k].InUse then
      Continue;
    case Kind of
      1: Other := Identity.Slots[k].Hwid;
      2: Other := Identity.Slots[k].IP;
      else Other := NormalizeSteam(Identity.Slots[k].Steam);
    end;
    if (Other = '') or not SameText(Other, V) then
      Continue;
    if SameText(Mode, 'kick') then
    begin
      Audit(Format('identity: %s kicked, same %s as %s', [Live[S].Name, What, Live[k].Name]));
      KickPlayer(S, 'A player with the same ' + What + ' is already on this server.');
      Exit(False);
    end;
    NotifyAdmins(Format('[ZitroStats] %s uses the same %s as %s.', [Live[S].Name, What, Live[k].Name]), CLR_WARN);
    Exit;
  end;
end;

{ one line for /zs_suspects and suspicious.log }
procedure TZSEngine.NoteSuspect(const Text: AnsiString; Notify: Boolean);
begin
  Suspects.Add(FormatDateTime('yyyy-mm-dd hh:nn', Now) + '  ' + Text);
  while Suspects.Count > SUSPECTS_MAX do
    Suspects.Delete(0);
  AppendLog('suspicious.log', Text);
  if Notify and Cfg.SuspiciousNotifyAdmins then
    NotifyAdmins('[ZitroStats] ' + Text, CLR_WARN);
end;

{ the newest lines of suspicious.log, so /zs_suspects is not empty after a restart }
procedure TZSEngine.LoadSuspects;
var
  F: TFileStream;
  L: TStringList;
  Data: AnsiString;
  Path: AnsiString;
  k: LongInt;
begin
  if LogDir = '' then
    Exit;
  Path := StorePath(LogDir, 'suspicious.log');
  if not FileExists(Path) then
    Exit;
  Data := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > 64 * 1024 then
        F.Position := F.Size - 64 * 1024;
      SetLength(Data, F.Size - F.Position);
      if Length(Data) > 0 then
        F.ReadBuffer(Data[1], Length(Data));
    finally
      F.Free;
    end;
  except
    Exit;
  end;
  L := TStringList.Create;
  try
    L.Text := Data;
    for k := Max(0, L.Count - 30) to L.Count - 1 do
      if Trim(L[k]) <> '' then
        Suspects.Add(L[k]);
  finally
    L.Free;
  end;
end;

{ Once a day: accounts that share a computer or an address, and accounts whose headshot share or
  accuracy stands far above the server. Both are hints for an admin, never an automatic penalty;
  the share is judged by the lower end of its confidence interval, so a short lucky series of a
  new account does not land here. }
procedure TZSEngine.ScanForSuspects;
const
  MIN_HITS = 200;
  MIN_SHOTS = 500;
  GROUP_REPORT_MAX = 12;

  function LowestOf(const A: TIntArray): LongInt;
  var
    k: LongInt;
  begin
    Result := A[0];
    for k := 1 to High(A) do
      if A[k] < Result then
        Result := A[k];
  end;

  function NamesOf(const A: TIntArray): AnsiString;
  var
    k: LongInt;
  begin
    Result := '';
    for k := 0 to High(A) do
    begin
      if k = 4 then
        Exit(Result + Format(' and %d more', [Length(A) - 4]));
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + Format('#%d %s', [DB.Profiles[A[k]]^.ID, DB.Profiles[A[k]]^.ActiveName]);
    end;
  end;

var
  ByHwid, ByIp: TStrIndex;
  Group: TIntArray;
  i, Reported: LongInt;
  P: PPlayerProfile;
  Hits, Head, Shots, SumHits, SumHead, SumShots: Int64;
  HsAvg, AccAvg, Bound: Double;
begin
  if not Cfg.SuspiciousEnabled then
    Exit;
  Reported := 0;
  if Cfg.SuspiciousSharedDevices then
  begin
    ByHwid := TStrIndex.Create(4096);
    ByIp := TStrIndex.Create(4096);
    try
      for i := 0 to DB.ProfileCount - 1 do
      begin
        P := DB.Profiles[i];
        if P = nil then
          Continue;
        if P^.ActiveHWID <> '' then
          ByHwid.Add(LowerCase(P^.ActiveHWID), i);
        if P^.ActiveIP <> '' then
          ByIp.Add(P^.ActiveIP, i);
      end;
      for i := 0 to DB.ProfileCount - 1 do
      begin
        P := DB.Profiles[i];
        if (P = nil) or (Reported >= GROUP_REPORT_MAX) then
          Continue;
        if P^.ActiveHWID <> '' then
        begin
          Group := ByHwid.Find(LowerCase(P^.ActiveHWID));
          if (Length(Group) > 1) and (LowestOf(Group) = i) then
          begin
            NoteSuspect(Format('%d accounts last used the same computer: %s', [Length(Group), NamesOf(Group)]), Reported < 3);
            Inc(Reported);
          end;
        end;
        if P^.ActiveIP <> '' then
        begin
          Group := ByIp.Find(P^.ActiveIP);
          if (Length(Group) > 1) and (LowestOf(Group) = i) then
          begin
            NoteSuspect(Format('%d accounts last came from the same address: %s', [Length(Group), NamesOf(Group)]), Reported < 3);
            Inc(Reported);
          end;
        end;
      end;
    finally
      ByHwid.Free;
      ByIp.Free;
    end;
  end;

  if not Cfg.SuspiciousOutliers then
    Exit;
  SumHits := 0;
  SumHead := 0;
  SumShots := 0;
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if P = nil then
      Continue;
    Inc(SumHits, P^.ShotsHits);
    Inc(SumHead, P^.ShotsHitsHead);
    Inc(SumShots, Max(P^.Shots, P^.ShotsHits));
  end;
  if (SumHits < MIN_HITS * 10) or (SumShots < MIN_SHOTS * 10) then
    Exit;
  HsAvg := SumHead / SumHits;
  AccAvg := SumHits / SumShots;
  Reported := 0;
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if (P = nil) or (Reported >= GROUP_REPORT_MAX) then
      Continue;
    Hits := P^.ShotsHits;
    Head := P^.ShotsHitsHead;
    Shots := Max(P^.Shots, P^.ShotsHits);
    if Hits >= MIN_HITS then
    begin
      Bound := WilsonLower(Head, Hits);
      if (HsAvg > 0) and (Bound > HsAvg * 2.0) and (Bound > 0.35) then
      begin
        NoteSuspect(Format('#%d %s: headshots at least %.0f%% of %d hits (server %.0f%%)',
          [P^.ID, P^.ActiveName, Bound * 100, Hits, HsAvg * 100]), Reported < 3);
        Inc(Reported);
        Continue;
      end;
    end;
    if Shots >= MIN_SHOTS then
    begin
      Bound := WilsonLower(Hits, Shots);
      if (AccAvg > 0) and (Bound > AccAvg * 1.8) and (Bound > 0.6) then
      begin
        NoteSuspect(Format('#%d %s: accuracy at least %.0f%% of %d shots (server %.0f%%)',
          [P^.ID, P^.ActiveName, Bound * 100, Shots, AccAvg * 100]), Reported < 3);
        Inc(Reported);
      end;
    end;
  end;
end;

procedure TZSEngine.ReportError(const Where: AnsiString; E: Exception);
var
  NowMs: Int64;
begin
  NowMs := MonoMs;
  if NowMs - FErrorWindowMs > 60000 then
  begin
    FErrorWindowMs := NowMs;
    FErrorCount := 0;
  end;
  Inc(FErrorCount);
  if FErrorCount <= 10 then
    WriteServer('[ZitroStats] internal error in ' + Where + ': ' + E.ClassName + ': ' + E.Message);
  AppendLog('errors.log', Where + ': ' + E.ClassName + ': ' + E.Message);
end;

{ ---------------- identity host ---------------- }

procedure TZSEngine.Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt);
begin
  Say(Slot, Text, Color);
end;

procedure TZSEngine.Audit(const Text: AnsiString);
begin
  if Cfg.AdminAuditLog then
    AppendLog('audit.log', Text);
end;

procedure TZSEngine.ForceSpectator(Slot: LongInt);
var
  A: TZSAction;
begin
  { the script moved this player: it is not their own switch to the spectators }
  if SlotValid(Slot) then
    Live[Slot].ScriptTeamTick := GameTick;
  A := NewAction(ACT_SETTEAM, Slot, 0, '');
  A.P1 := TEAM_SPEC;
  EmitAction(A);
end;

{ a player who logged in after being parked on the spectators: the balance picks the team,
  and without the balance the smaller team gets them }
procedure TZSEngine.ReturnToGame(Slot: LongInt);
var
  A: TZSAction;
  T, Best, BestCount, Cnt: LongInt;
  S: LongInt;
begin
  if not SlotValid(Slot) or not Live[Slot].Active or (Live[Slot].Team <> TEAM_SPEC) then
    Exit;
  if TeamGame then
  begin
    if Cfg.BalanceEnabled and not Bal.Paused then
    begin
      BalJoinTeam(Slot);
      Exit;
    end;
    Best := TEAM_ALPHA;
    BestCount := MaxInt;
    for T := TEAM_ALPHA to TEAM_BRAVO do
    begin
      Cnt := 0;
      for S := 1 to MAX_PLAYERS do
        if Live[S].Active and (Live[S].Team = T) then
          Inc(Cnt);
      if Cnt < BestCount then
      begin
        BestCount := Cnt;
        Best := T;
      end;
    end;
  end
  else
    Best := TEAM_NONE;
  Live[Slot].ScriptTeamTick := GameTick;
  A := NewAction(ACT_MOVE, Slot, 0, '');
  A.P1 := Best;
  EmitAction(A);
end;

procedure TZSEngine.KickPlayer(Slot: LongInt; const Reason: AnsiString);
begin
  { the server needs a moment to drop the player: until then the slot counts for nothing }
  if SlotValid(Slot) then
    Live[Slot].PendingKick := True;
  EmitAction(NewAction(ACT_KICK, Slot, 0, Reason));
end;

function TZSEngine.SubmitJob(const Job: TServiceJob): Boolean;
begin
  Result := (Service <> nil) and Service.Enqueue(Job);
end;

procedure TZSEngine.SessionProfileChanged(Slot, OldProfileId, NewProfileId: LongInt);
var
  Idx: LongInt;
begin
  if not SlotValid(Slot) then
    Exit;
  Idx := DB.IndexOfId(NewProfileId);
  if DB.Valid(Idx) then
  begin
    Live[Slot].SessionStartPoints := DB.Profiles[Idx]^.Points;
    Live[Slot].MatchStartPoints := DB.Profiles[Idx]^.Points;
  end;
  Extra[Slot].HudText := '';
end;

{ ---------------- helpers ---------------- }

function TZSEngine.SlotValid(Slot: LongInt): Boolean;
begin
  Result := (Slot >= 1) and (Slot <= MAX_PLAYERS) and Live[Slot].Active;
end;

function TZSEngine.HumansPlaying: LongInt;
begin
  Result := LiveHumansPlaying(Live);
end;

function TZSEngine.HumansOnline: LongInt;
var
  S: LongInt;
begin
  Result := 0;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human and not Live[S].PendingKick then
      Inc(Result);
end;

{ Farming protection: statistics may also require a real line-up, for example two players per
  side in a team game or three in a free-for-all. Both limits are off by default. }
function TZSEngine.TeamsFilled: Boolean;
var
  S, T, Best, Second: LongInt;
  PerTeam: array[TEAM_ALPHA..TEAM_DELTA] of LongInt;
begin
  Result := True;
  if not TeamGame then
  begin
    if Cfg.MinFFAHumans > 0 then
      Result := HumansPlaying >= Cfg.MinFFAHumans;
    Exit;
  end;
  if Cfg.MinTeamPerSide <= 0 then
    Exit;
  for T := TEAM_ALPHA to TEAM_DELTA do
    PerTeam[T] := 0;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human and (Live[S].Team >= TEAM_ALPHA) and (Live[S].Team <= TEAM_DELTA) then
      Inc(PerTeam[Live[S].Team]);
  Best := 0;
  Second := 0;
  for T := TEAM_ALPHA to TEAM_DELTA do
    if PerTeam[T] > Best then
    begin
      Second := Best;
      Best := PerTeam[T];
    end
    else if PerTeam[T] > Second then
      Second := PerTeam[T];
  { the two strongest teams must both be filled }
  Result := Second >= Cfg.MinTeamPerSide;
end;

function TZSEngine.StatsOn: Boolean;
begin
  Result := FReady and (HumansPlaying >= Max(1, Cfg.MinHumansForStats)) and TeamsFilled;
end;

{ time alive and the longest life may ask for more players than the other statistics }
function TZSEngine.SurvivalOn: Boolean;
begin
  Result := StatsOn and (HumansPlaying >= Max(1, Cfg.MinHumansForSurvival));
end;

function TZSEngine.TeamGame: Boolean;
begin
  Result := IsTeamStyle(Match.GameStyle);
end;

function TZSEngine.RatingSystem: LongInt;
begin
  Result := DB.RatingSystem;
end;

function TZSEngine.CurrentFamily: LongInt;
begin
  Result := FamilyFor(Cfg, Match.GameStyle);
end;

{ realistic mode gives a player much less health, so an assist needs less damage there }
function TZSEngine.EffectiveMaxHealth: LongInt;
begin
  if Match.Realistic and (Cfg.MaxHealthRealistic > 0) then
    Result := Cfg.MaxHealthRealistic
  else
    Result := Cfg.MaxHealth;
end;

function TZSEngine.PlayerRank(Index: LongInt): LongInt;
begin
  Result := DB.Ranks[RANK_POINTS].RankOf(Index);
end;

{ the league of an account, '' when leagues are off; during placement it says how many matches
  are still missing }
function TZSEngine.LeagueName(Index: LongInt): AnsiString;
begin
  if Cfg.LeaguesEnabled then
    Result := LeagueLabel(Index)
  else
    Result := '';
end;

{ the league whether or not it replaces the tier; during placement how many matches are missing }
function TZSEngine.LeagueLabel(Index: LongInt): AnsiString;
var
  P: PPlayerProfile;
begin
  Result := '';
  if not DB.Valid(Index) or (Cfg.RankTierCount <= 0) then
    Exit;
  P := DB.Profiles[Index];
  if (P^.LeagueTier <= 0) or (P^.LeagueTier > Cfg.RankTierCount) then
  begin
    if Cfg.LeaguePlacementMatches > 0 then
      Result := Format('Placement %d/%d', [Min(LeagueGames(Cfg, P^), Cfg.LeaguePlacementMatches),
        Cfg.LeaguePlacementMatches]);
    Exit;
  end;
  Result := Cfg.RankTiers[P^.LeagueTier - 1].Name;
  if Cfg.LeagueDivisions > 1 then
    Result := Result + ' ' + IntToStr(P^.LeagueDivision);
end;

function TZSEngine.TierName(Index: LongInt): AnsiString;
begin
  Result := LeagueName(Index);
  if Result = '' then
    Result := PlainTierName(Index);
end;

{ the tier of [Ranks] alone, also when leagues are on }
function TZSEngine.PlainTierName(Index: LongInt): AnsiString;
var
  T: LongInt;
begin
  Result := '';
  if not DB.Valid(Index) or (Cfg.RankTierCount <= 0) then
    Exit;
  T := TierIndex(Cfg, DB.Profiles[Index]^, PerformanceRating(DB.Profiles[Index]^, Match.GameStyle, Match.Survival,
    Match.FriendlyFire, Cfg.RatingMode), CurrentFamily, RatingSystem);
  if (T >= 0) and (T < Cfg.RankTierCount) then
    Result := Cfg.RankTiers[T].Name;
end;

function TZSEngine.TierColor(Index: LongInt): LongInt;
var
  T: LongInt;
begin
  Result := WHITE;
  if not DB.Valid(Index) or (Cfg.RankTierCount <= 0) then
    Exit;
  if Cfg.LeaguesEnabled and (DB.Profiles[Index]^.LeagueTier > 0) and
     (DB.Profiles[Index]^.LeagueTier <= Cfg.RankTierCount) then
    Exit(Cfg.RankTiers[DB.Profiles[Index]^.LeagueTier - 1].Color);
  T := TierIndex(Cfg, DB.Profiles[Index]^, PerformanceRating(DB.Profiles[Index]^, Match.GameStyle, Match.Survival,
    Match.FriendlyFire, Cfg.RatingMode), CurrentFamily, RatingSystem);
  if (T >= 0) and (T < Cfg.RankTierCount) then
    Result := Cfg.RankTiers[T].Color;
end;

{$I zs_engine_matrix.inc}
{$I zs_engine_events.inc}
{$I zs_engine_reload.inc}
{$I zs_engine_combat.inc}
{$I zs_engine_match.inc}
{$I zs_engine_admin.inc}
{$I zs_engine_balance.inc}
{$I zs_engine_mapvote.inc}

end.
