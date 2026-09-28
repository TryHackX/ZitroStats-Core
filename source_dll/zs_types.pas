unit zs_types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  ZS_VERSION_STR = '5.5';
  ZS_API_VERSION = 15;
  ZS_DB_FORMAT = 9;

  MAX_PLAYERS = 32;
  MAX_STRING_LEN = 64;
  TICKS_PER_SECOND = 60;
  PIXELS_PER_METER = 14.0; { Soldat shows kill distance as Vec2Length(hit - bullet origin) / 14 }

  { Soldat weapon numbers (WType / GetOwnerWeaponId) }
  WEP_SOCOM = 0;
  WEP_DEAGLES = 1;
  WEP_MP5 = 2;
  WEP_AK74 = 3;
  WEP_AUG = 4;
  WEP_SPAS = 5;
  WEP_RUGER = 6;
  WEP_M79 = 7;
  WEP_BARRETT = 8;
  WEP_MINIMI = 9;
  WEP_MINIGUN = 10;
  WEP_KNIFE = 11;
  WEP_CHAINSAW = 12;
  WEP_LAW = 13;
  WEP_FLAMER = 14;
  WEP_BOW = 15;
  WEP_BOW2 = 16;
  WEP_M2 = 30;
  WEP_FRAG = 50;
  WEP_CLUSTERNADE = 51;
  WEP_CLUSTER = 52;
  WEP_THROWNKNIFE = 53;
  WEP_NONE = 255;
  WEP_WORLD = -1;

  { Weapon statistic slots (compact storage) }
  WSLOT_COUNT = 21;
  WSLOT_M2 = 17;
  WSLOT_FISTS = 18;
  WSLOT_FRAG = 19;
  WSLOT_CLUSTER = 20;

  { Soldat bullet styles }
  BS_PLAIN = 1;
  BS_FRAGNADE = 2;
  BS_SHOTGUN = 3;
  BS_M79 = 4;
  BS_FLAME = 5;
  BS_PUNCH = 6;
  BS_ARROW = 7;
  BS_FLAMEARROW = 8;
  BS_CLUSTERNADE = 9;
  BS_CLUSTER = 10;
  BS_KNIFE = 11;
  BS_LAW = 12;
  BS_THROWNKNIFE = 13;
  BS_M2 = 14;

  TEAM_NONE = 0;
  TEAM_ALPHA = 1;
  TEAM_BRAVO = 2;
  TEAM_CHARLIE = 3;
  TEAM_DELTA = 4;
  TEAM_SPEC = 5;

  GS_DM = 0;
  GS_PM = 1;
  GS_TM = 2;
  GS_CTF = 3;
  GS_RM = 4;
  GS_INF = 5;
  GS_HTF = 6;

  RF_FFA = 0;
  RF_TEAM = 1;
  RF_CTF = 2;
  RF_COUNT = 3;

  HZ_HEAD = 0;
  HZ_BODY = 1;
  HZ_LEGS = 2;
  HZ_UNKNOWN = 3;

  POSTURE_STAND = 0;
  POSTURE_CROUCH = 1;
  POSTURE_PRONE = 2;
  POSTURE_AIR = 3;

  FLAG_SCORE = 0;
  FLAG_RETURN = 1;
  FLAG_GRAB = 2;
  FLAG_DROP = 3;
  FLAG_THROWN = 4;
  FLAG_BASE = 5;          { no player: where a flag stands in its base (main.pas, every few seconds) }

  KIT_MEDICAL = 16;
  KIT_GRENADE = 17;
  KIT_FLAMER = 18;
  KIT_PREDATOR = 19;
  KIT_VEST = 20;
  KIT_BERSERK = 21;
  KIT_CLUSTER = 22;

  { the kinds of kit counted when a player picks one up (TPlayerProfile.KitPickups), in this order;
    KitKind gives the place of a kit style }
  KIT_KINDS = 7;
  KIT_KIND_STYLES: array[0..KIT_KINDS - 1] of LongInt = (KIT_MEDICAL, KIT_GRENADE, KIT_CLUSTER, KIT_VEST,
    KIT_BERSERK, KIT_PREDATOR, KIT_FLAMER);
  { their keys in players.json }
  KIT_KIND_NAMES: array[0..KIT_KINDS - 1] of AnsiString = ('medical', 'grenade', 'cluster', 'vest', 'berserker',
    'predator', 'flamer');

  BERSERK_TICKS = 900;

  { kill streaks are counted by their length up to this many kills (TPlayerProfile.SpreeLives) }
  SPREE_MAX_KILLS = 50;

  SRC_CHAT = 0;
  SRC_COMMAND = 1;
  SRC_CONSOLE = 2;

  ACT_NONE = 0;
  ACT_CONSOLE = 1;
  ACT_BROADCAST = 2;
  ACT_BIGTEXT = 3;
  ACT_WRITELN = 4;
  ACT_SETTEAM = 5;
  ACT_KICK = 6;
  { main.pas answers with ZS_Ev_Ray: is the line P2,P3 -> P4,P5 clear? P1 = request id }
  ACT_RAYCAST = 7;
  { the team balance moves the player to team P1; P2 = MOVE_* flags; main.pas answers with
    ZS_Ev_Move_Result }
  ACT_MOVE = 8;
  { the settings of the score guard for main.pas: P1 = IG_* flags, P2 = MinOpponents }
  ACT_INTEGRITY = 9;
  { the map vote (zs_engine_mapvote.inc): Soldat's own vote shows the vote Text to the clients, with a
    vote percent of 200 it never reaches (main.pas keeps the percent it had) }
  ACT_VOTE_START = 10;
  { the vote is over: the percent goes back once Soldat's own vote has run out; P1 = the percent to
    put back when main.pas does not know the old one (0 = leave it) }
  ACT_VOTE_END = 11;
  { a vote passed: the map changes to Text; P1 = 1 when it is the next map of the maps list
    (Map.NextMap, so the list goes on after it) }
  ACT_MAP_CHANGE = 12;
  { the settings of the map vote for main.pas: P1 = MV_* flags, P2 = [MapVote] RestoreVotePercent }
  ACT_MAPVOTE = 13;

  { P1 of ACT_MAPVOTE }
  MV_ENABLED = 1;         { the map vote runs: OnVoteMapStart cancels Soldat's own vote }

  { why main.pas sends the maps list (ZS_Ev_Map_List) }
  MAPLIST_START = 1;      { the script started }
  MAPLIST_MAPCHANGE = 2;  { after a map change }
  MAPLIST_ADMIN = 3;      { an admin typed /addmap, /delmap or /loadlist }
  MAPLIST_CHANGED = 4;    { the check once a second saw another list (another script) }

  { P1 of ACT_INTEGRITY: what main.pas watches }
  IG_ENABLED = 1;         { the guard works at all }
  IG_JOINSCORE = 2;       { take back the survival round point a join or team change caused }
  IG_DOUBLECAP = 4;       { a capture after the round or the match is decided counts for nobody }
  IG_SOLO = 8;            { points without an opposing team count for nobody }
  IG_RESPAWN = 16;        { put players a map change left dead back on their feet }
  IG_MAPCHANGE = 32;      { refuse /pause while the map is changing and repeat a lost map change }
  IG_ANNOUNCE = 64;       { tell the players what was taken back }

  { kinds of ZS_Ev_Integrity }
  IGE_JOINSCORE = 1;      { a point after a join or team change was taken back }
  IGE_DOUBLECAP = 2;      { a capture after the round or match was decided was taken back }
  IGE_SOLO = 3;           { a point without an opposing team was taken back }
  IGE_RESPAWN = 4;        { players were put back on their feet after a map change }
  IGE_PAUSE = 5;          { /pause was refused because the map was changing }
  IGE_MAPCHANGE = 6;      { a map change lost by a pause was repeated }

  { flags of ACT_MOVE }
  MOVE_DEAD_ONLY = 1;   { only while the player is dead }

  { answers of ZS_Ev_Move_Result }
  MOVE_DONE = 1;        { the player is in the team now }
  MOVE_ALIVE = 2;       { not moved: the player is alive and the move waits for a death }
  MOVE_FLAGGER = 3;     { not moved: the player carries a flag }
  MOVE_REFUSED = 4;     { not moved: the server or another script refused the change }
  MOVE_ALREADY = 5;     { nothing to do: the player was in the team already }

  { answers of ZS_Ev_Ray }
  RAY_BLOCKED = 0;
  RAY_CLEAR = 1;
  RAY_UNKNOWN = -1;

  { Bit flags sent with kill / damage / sample events }
  EF_A_FLAGGER = 1;       { killer / shooter / sampled player holds a flag }
  EF_B_FLAGGER = 2;       { victim holds a flag }
  EF_A_PRONE = 4;
  EF_A_ONGROUND = 8;
  EF_A_ALIVE = 16;
  EF_BULLET = 32;         { bullet id belongs to the attacker and position/velocity are valid }
  EF_B_PRONE = 64;
  EF_B_ONGROUND = 128;
  EF_A_CROUCH = 256;
  EF_B_CROUCH = 512;
  EF_HUMAN = 1024;
  EF_ADMIN = 2048;
  EF_LOS = 4096;          { clear line from the killer to the victim, checked with Map.RayCast }
  EF_RAY_RAW = 8192;      { what Map.RayCast answered, before the calibration (debug) }
  EF_RAY_CAL = 16384;     { main.pas has settled which answer means a clear line (debug) }
  EF_SERVER_KILL = 32768; { the server killed the player itself (survival round end or a team change) }

  { The palette. Every one of these is a setting ([Colors] in settings.ini); the numbers
    here are what a server gets without a file. They are read through the functions in
    zs_util, so a colour in the file is used the moment the settings are read. }
  DEF_CLR_HEADER = $FFD700;
  DEF_CLR_SUBHEADER = $00E5FF;
  DEF_CLR_COMBAT = $55FF55;
  DEF_CLR_SHOOTING = $FFFFFF;
  DEF_CLR_FEATS = $FFB703;
  DEF_CLR_OBJECTIVE = $FFA500;
  DEF_CLR_TEAMPLAY = $FF6B6B;
  DEF_CLR_MATCHES = $A8E6CF;
  DEF_CLR_ACTIVITY = $B0C4DE;
  DEF_CLR_HINT = $80D0FF;
  DEF_CLR_TOP1 = $FFD700;
  DEF_CLR_TOP2 = $E0E0E0;
  DEF_CLR_TOP3 = $CD7F32;
  DEF_CLR_YOU = $00FF66;
  DEF_CLR_OTHER_ROW = $9BD0E8;
  DEF_CLR_BAD = $CC3300;
  DEF_CLR_GOOD = $66CC66;
  DEF_CLR_WARN = $FF8C00;
  DEF_CLR_RANK_LINE = $00E5FF;
  WHITE = $FFFFFF;

type
  TOtherData = packed record
    DataString: array[0..MAX_STRING_LEN - 1] of AnsiChar;
    IsActive: Boolean;
    FirstUsed: Boolean;
    LastUsed: Boolean;
    LoginCount: Int64;
    TimeOnSpectator: Int64;
    TimePlayed: Int64;
    FirstUsedDate: Double;
    LastUsedDate: Double;
  end;
  TOtherDataArray = array of TOtherData;

  TWeaponStats = record
    Kills: LongInt;
    Deaths: LongInt;
    Shots: LongInt;
    Hits: LongInt;
    Headshots: LongInt;
    HitsBody: LongInt;
    HitsLegs: LongInt;
    HitsUnknown: LongInt;
    HSKills: LongInt;
    Damage: Double;
    DamageReceived: Double;
    TimeUsedSeconds: Int64;
    LongestKill: Single;
    { reloading (zs_engine_reload.inc) }
    Reloads: LongInt;            { reloads started }
    ReloadsManual: LongInt;      { of them started with rounds still in the magazine }
    RoundsDropped: LongInt;      { the rounds those threw away }
    ReloadsDone: LongInt;        { finished }
    ReloadsCut: LongInt;         { broken off by a weapon change or a thrown gun }
    ReloadDeaths: LongInt;       { killed in the middle of one }
    ReloadTimed: LongInt;        { finished reloads whose length is known }
    ReloadTicks: Int64;          { their length, in ticks }
    ReloadNormTicks: Int64;      { what the weapons file says they take }
    ReloadEnds: LongInt;         { reloads that ended one way or the other }
    ReloadDoneMille: Int64;      { how far each of those got, per mille (finished = 1000) }
    ReloadDeathMille: Int64;     { how far the ones cut short by death got }
    ReloadTicksAll: Int64;       { all the time spent reloading }
    { the kills of this account with the weapon as TWeaponGlobal keeps them for the server: by
      distance (under 10, 25, 50, 100 m and more), the distances added up, the time from the first
      hit to the kill (ticks) and the kills of a victim wearing a vest }
    DistBucket: array[0..4] of LongInt;
    KillDistSum: Double;
    KillDistCount: LongInt;
    TTKSumTicks: Int64;
    TTKCount: LongInt;
    VestKills: LongInt;
  end;
  TWeaponsArray = array[0..WSLOT_COUNT - 1] of TWeaponStats;
  PWeaponStats = ^TWeaponStats;

  TNemesisEntry = record
    TargetPlayerID: LongInt;
    KillCount: LongInt;
  end;
  TNemesisArray = array[0..2] of TNemesisEntry;

  TRamboStats = record
    KillRamboCount: LongInt;
    KillsByBow: LongInt;
    GetsBow: LongInt;
    DropBow: LongInt;
    KillsWhenNoRambo: LongInt;
    DeathsWhenNoRambo: LongInt;
    TimeWithBow: Int64;
    TimeWithoutBow: Int64;
  end;

  THTFStats = record
    PointsScored: LongInt;
    TeamPointsScored: LongInt;
    AlphaPointsScored: LongInt;
    BravoPointsScored: LongInt;
    AlphaTeamPointsScored: LongInt;
    BravoTeamPointsScored: LongInt;
    TimeWhenHaveFlag: Int64;
    TimeWhenTeamHaveFlag: Int64;
    TimeWhenNotHaveFlag: Int64;
    TimeWhenTeamNotHaveFlag: Int64;
  end;

  TPointmatchMulti = record
    DOUBLE_KILL: LongInt;
    TRIPLE_KILL: LongInt;
    MULTI_KILL: LongInt;
    MULTI_KILL_X2: LongInt;
    SERIAL_KILL: LongInt;
    INSANE_KILLS: LongInt;
    GIMME_MORE: LongInt;
    MASTA_KILLA: LongInt;
    STOP_IT: LongInt;
    MERCY: LongInt;
    CHEATER: LongInt;
  end;

  TPointmatchStats = record
    ExtraPoints: LongInt;
    Multi: TPointmatchMulti;
  end;

  TGlickoState = record
    R: Double;
    RD: Double;
    Vol: Double;
    LastUpdate: Double;
    Games: LongInt;
  end;

  TOpenSkillState = record
    Mu: Double;
    Sigma: Double;
    Games: LongInt;
  end;

  { Heroes-of-the-Storm style match rating: one number per mode family, moved by the strength of
    the whole team that was beaten, not by the single opponent. }
  TMmrState = record
    R: Double;
    Games: LongInt;
  end;

  TModeStats = record
    Kills: LongInt;
    Deaths: LongInt;
    Wins: LongInt;
    Loses: LongInt;
    Draws: LongInt;
    Caps: LongInt;
    TimePlayed: Int64;
  end;

  TPeriodStats = record
    Key: LongInt;
    Kills: LongInt;
    Deaths: LongInt;
    PointsDelta: LongInt;
    Caps: LongInt;
    Wins: LongInt;
    Headshots: LongInt;
    TimePlayed: Int64;
  end;

  TTrustedDevice = record
    HWID: AnsiString;
    IPPrefix: AnsiString;
    Expire: Double;
    LastUsed: Double;
  end;
  TTrustedDeviceArray = array of TTrustedDevice;

  TSeasonBadge = record
    SeasonId: LongInt;
    Place: LongInt;
  end;
  TSeasonBadgeArray = array of TSeasonBadge;

  TAchievementUnlock = record
    Id: LongInt;
    Date: Double;
  end;
  TAchievementArray = array of TAchievementUnlock;

  TPlayerProfile = record
    { identity }
    ID: LongInt;
    ActiveName: AnsiString;
    ActiveSteam: AnsiString;
    ActiveHWID: AnsiString;
    ActiveIP: AnsiString;
    DisplayHUD: Boolean;
    RegisterTime: Double;
    LastPlayedTime: Double;
    MergedInto: LongInt;
    OtherNames: TOtherDataArray;    { names used on the account, with play time and joins }

    { account security (optional registration) }
    PassHash: AnsiString;
    PassSalt: AnsiString;
    PassIter: LongInt;
    PassSetTime: Double;
    Email: AnsiString;
    EmailVerified: Boolean;
    EmailPending: AnsiString;
    EmailCodeHash: AnsiString;
    EmailCodeExpire: Double;
    ResetCodeHash: AnsiString;
    ResetCodeExpire: Double;
    MailLastSent: Double;
    MailDayKey: LongInt;
    MailSentToday: LongInt;
    LoginFailCount: LongInt;
    LoginLockUntil: Double;
    TrustedDevices: TTrustedDeviceArray;
    NoTrustedDevices: Boolean;   { the owner asked for a password on every computer }

    { protection / activity }
    ProtectionDays: LongInt;
    ActivityForProtectDays: LongInt;
    TimePlayed: Int64;
    TimeAlive: Int64;
    TimeDeath: Int64;
    TimeOnSpectator: Int64;
    DaysPlayed: LongInt;
    LastDayKey: LongInt;

    { core combat }
    Points: LongInt;
    Kills: LongInt;
    Deaths: LongInt;
    Selfkills: LongInt;
    Assist: LongInt;
    Teamkills: LongInt;
    DeathsByFriendly: LongInt;
    PosthumousKills: LongInt;
    RevengeKills: LongInt;
    AvengerKills: LongInt;
    SaviorKills: LongInt;

    { objectives }
    FlagsScore: LongInt;
    AlphaScore: LongInt;
    AlphaTeamScore: LongInt;
    BravoScore: LongInt;
    BravoTeamScore: LongInt;
    FlagsReturn: LongInt;
    FlagsGrab: LongInt;
    FlagsDrop: LongInt;
    FlagsThrown: LongInt;
    FlaggerKills: LongInt;
    FlaggerKillsAssist: LongInt;
    SaviorFlaggerKills: LongInt;
    FlaggerTeamkills: LongInt;
    KillsWhenHaveFlag: LongInt;
    TeamkillsWhenHaveFlag: LongInt;
    TimeHoldingFlags: LongInt;

    { matches & rounds }
    Wins: LongInt;
    Loses: LongInt;
    Draws: LongInt;
    LeaveLosses: LongInt;
    AlphaWins: LongInt;
    AlphaLoses: LongInt;
    BravoWins: LongInt;
    BravoLoses: LongInt;
    CharlieWins: LongInt;
    CharlieLoses: LongInt;
    DeltaWins: LongInt;
    DeltaLoses: LongInt;
    RoundsWins: LongInt;
    RoundsLose: LongInt;
    RoundsAlphaWins: LongInt;
    RoundsAlphaLoses: LongInt;
    RoundsBravoWins: LongInt;
    RoundsBravoLoses: LongInt;
    RoundsCharlieWins: LongInt;
    RoundsCharlieLoses: LongInt;
    RoundsDeltaWins: LongInt;
    RoundsDeltaLoses: LongInt;

    { shooting & hit zones }
    Shots: LongInt;
    ShotsHits: LongInt;
    ShotsHitsFriendly: LongInt;
    ShotsHitsByFriendly: LongInt;
    ShotsHitsSelf: LongInt;
    ShotsHitsHead: LongInt;
    ShotsHitsBody: LongInt;
    ShotsHitsLeg: LongInt;
    ShotsHitsUnknown: LongInt;
    ShotsHitsFriendlyHead: LongInt;
    ShotsHitsFriendlyBody: LongInt;
    ShotsHitsFriendlyLeg: LongInt;
    ShotsHitsByFriendlyHead: LongInt;
    ShotsHitsByFriendlyBody: LongInt;
    ShotsHitsByFriendlyLeg: LongInt;
    ShotsHitsSelfHead: LongInt;
    ShotsHitsSelfBody: LongInt;
    ShotsHitsSelfLeg: LongInt;

    { special weapons }
    KnivesThrows: LongInt;
    KnivesThrowsHitsEnemy: LongInt;
    KnivesThrowsHitsSelf: LongInt;
    KnivesThrowsHitsFriends: LongInt;
    KnivesThrowsHitsByFriends: LongInt;
    KnivesStabsEnemy: LongInt;
    KnivesStabsFriendly: LongInt;
    KnivesStabsByFriendly: LongInt;
    ChainsawTimeUsedSeconds: LongInt;
    ChainsawHurtsEnemy: LongInt;
    ChainsawHurtsFriendly: LongInt;
    ChainsawHurtsByFriendly: LongInt;
    FlamethrowerShots: LongInt;
    FlamethrowerHitsEnemy: LongInt;
    FlamethrowerHitsFriendly: LongInt;
    FlamethrowerHitsSelf: LongInt;
    FlamethrowerHitsByFriendly: LongInt;
    HandsHurtsEnemy: LongInt;
    HandsHurtsFriendly: LongInt;
    HandsHurtsByFriendly: LongInt;
    NadesThrows: LongInt;
    NadeHurtsEnemy: LongInt;
    NadeHurtsFriendly: LongInt;
    NadeHurtsSelf: LongInt;
    NadeHurtsByFriendly: LongInt;
    ClusterNadesThrows: LongInt;
    ClusterNadesHurtsEnemy: LongInt;
    ClusterNadesHurtsFriendly: LongInt;
    ClusterNadesHurtsSelf: LongInt;
    ClusterNadesHurtsByFriendly: LongInt;
    M79Shots: LongInt;
    M79HurtsEnemy: LongInt;
    M79HurtsFriendly: LongInt;
    M79HurtsSelf: LongInt;
    M79HurtsByFriendly: LongInt;
    M72LAWShots: LongInt;
    M72LAWHurtsEnemy: LongInt;
    M72LAWHurtsFriendly: LongInt;
    M72LAWHurtsSelf: LongInt;
    M72LAWHurtsByFriendly: LongInt;
    BowFlamedArrowsShots: LongInt;
    BowFlamedArrowsHurtsEnemy: LongInt;
    BowFlamedArrowsHurtsFriendly: LongInt;
    BowFlamedArrowsHurtsSelf: LongInt;
    BowFlamedArrowsHurtsByFriendly: LongInt;
    M2MGHitsEnemy: LongInt;
    M2MGHitsFriendly: LongInt;
    M2MGHitsByFriendly: LongInt;

    RamboMode: TRamboStats;
    HTFMode: THTFStats;
    PointmatchMode: TPointmatchStats;

    { feats }
    LastStand: LongInt;
    ClutchesWon: LongInt;
    DominatingCount: LongInt;
    RevengeFeats: LongInt;
    AdvanceRoundsWon: LongInt;
    AdvanceRoundsPlayed: LongInt;
    Weapons: TWeaponsArray;
    MaxKillStreak: LongInt;
    LongestKillDistance: Single;
    LongestBarrettDistance: Single;
    TotalKillDistance: Double;
    KillDistanceCount: Int64;
    FirstBloodCount: LongInt;
    FirstDamageCount: LongInt;
    RoundFirstBloodCount: LongInt; { the first kill of a survival round; FirstBloodCount: of a match }
    DamageDealt: Double;
    DamageReceived: Double;
    DamageFriendly: Double;
    DamageFriendlyReceived: Double;
    TopVictims: TNemesisArray;
    TopNemeses: TNemesisArray;
    ProneKills: LongInt;
    JetFlyTimeSeconds: Int64;
    CampKills: LongInt;
    BinkRecoveryKills: LongInt;
    SpreeKills: LongInt;
    RampageKills: LongInt;
    DominatingSpreeKills: LongInt;
    UnstoppableKills: LongInt;
    GodlikeKills: LongInt;
    ShutDownKills: LongInt;
    FinisherKills: LongInt;
    FastestCapSeconds: Single;
    CarrierEscortKills: LongInt;
    FlagJuggles: LongInt;
    ContestedHolds: LongInt;

    { v9 telemetry }
    LongestLifeSec: LongInt;
    TTKSumTicks: Int64;
    TTKCount: LongInt;
    BestTTKTicks: LongInt;
    SpawnKills: LongInt;
    SpawnDeaths: LongInt;
    AirKills: LongInt;
    HeightKills: LongInt;
    VestKills: LongInt;
    GrenadeKills: LongInt;
    ExplosionMultiKills: LongInt;
    KnifeKillsLifeBest: LongInt;
    DistanceTraveledM: Double;
    BarrettLongKills: LongInt;
    LongKills100: LongInt;
    CapsUnder10s: LongInt;
    ComebackWins: LongInt;
    WallKills: LongInt;        { no clear line from the killer to the victim when the victim died }
    CoverShotKills: LongInt;   { no clear line from where the lethal shot was fired to where it hit }
    BaseDefenseKills: LongInt; { the victim was close to the killer's own flag base }
    BaseAttackKills: LongInt;  { the killer was close to the enemy flag base }
    BestLifeDistanceM: Single; { the longest way covered in one life }
    ForcedSelfkills: LongInt;  { enemies who killed themselves right after this player hit them }
    SelfkillsUnderFire: LongInt; { own selfkills within AssistSeconds of an enemy hit }
    BalanceMoves: LongInt;     { moved to the other team by the team balance }
    BalanceVolunteers: LongInt; { switched to the weaker team with !switch when it helped }
    { health got back: from regenerating polygons (the healing fields of RSCS maps) and from
      medical, berserker and predator kits, and how many kits that was }
    HealRegen: Double;
    HealKits: Double;
    HealKitCount: LongInt;
    { the kits picked up, by kind (KIT_KIND_STYLES) }
    KitPickups: array[0..KIT_KINDS - 1] of LongInt;
    { the kill streaks by their length: SpreeLives[N] = the streaks that reached N kills (the last
      one: that many or more). The levels of [Sprees] read these, so a level whose kills change
      keeps the right count; SpreeLivesAt (zs_fields) adds what the five counters above held
      before this array existed. }
    SpreeLives: array[1..SPREE_MAX_KILLS] of LongInt;

    { league: 0 = not placed, else tier number (1 = best) and division inside it (1 = best) }
    LeagueTier: LongInt;
    LeagueDivision: LongInt;
    LeaguePromille: LongInt;   { position from the top of the placed accounts, in 0.1 % }

    { rating systems }
    Glicko: array[0..RF_COUNT - 1] of TGlickoState;
    OpenSkill: array[0..RF_COUNT - 1] of TOpenSkillState;
    Mmr: array[0..RF_COUNT - 1] of TMmrState;
    ModeStats: array[0..6] of TModeStats;
    Period: array[0..2] of TPeriodStats;

    { seasons & achievements }
    SeasonId: LongInt;
    SeasonPoints: LongInt;
    SeasonKills: LongInt;
    SeasonDeaths: LongInt;
    SeasonCaps: LongInt;
    SeasonWins: LongInt;
    SeasonTime: Int64;
    Badges: TSeasonBadgeArray;
    Achievements: TAchievementArray;

    { runtime only }
    Dirty: Boolean;
    { Engine = mysql (zs_sqldb): the record as the shared database last had it, its version
      there, and whether it waits for the next exchange with it }
    SyncBase: AnsiString;
    SyncVersion: Int64;
    SyncDirty: Boolean;

    { saved (field 38), added after the runtime fields: when the running count of failed logins
      (LoginFailCount) began; older failures than [Accounts] LoginLockMinutes do not count }
    LoginFailSince: Double;
  end;
  PPlayerProfile = ^TPlayerProfile;
  TPlayerProfileArray = array of TPlayerProfile;
  TProfilePtrArray = array of PPlayerProfile;

  THeatCell = record
    Cell: LongInt;
    Kills: LongInt;
    Deaths: LongInt;
  end;
  THeatCellArray = array of THeatCell;

  { a weapon against a weapon on one map: the kills made with the weapon slot Killer against a
    player who held the weapon slot Victim (TMapProfile.Matchups, sorted by Killer, then Victim) }
  TMatchupCell = record
    Killer: LongInt;
    Victim: LongInt;
    Kills: LongInt;
  end;
  TMatchupCellArray = array of TMatchupCell;

  TMapProfile = record
    ID: LongInt;
    MapName: AnsiString;
    FirstPlayedTime: Double;
    LastPlayedTime: Double;
    Kills: LongInt;
    Selfkills: LongInt;
    ActiveMapPlays: LongInt;   { completed matches }
    ActiveTimePlays: LongInt;  { seconds played with the statistics on }
    AlphaWins: LongInt;
    BravoWins: LongInt;
    CharlieWins: LongInt;
    DeltaWins: LongInt;
    Draws: LongInt;
    AlphaRoundWins: LongInt;
    BravoRoundWins: LongInt;
    CharlieRoundWins: LongInt;
    DeltaRoundWins: LongInt;
    FlagsGrabs: LongInt;
    FlagsReturns: LongInt;
    FlagsDrop: LongInt;
    FlagsThrown: LongInt;
    FlagsScore: LongInt;
    JoinGameCount: LongInt;
    LeaveGameCount: LongInt;
    KickedCount: LongInt;
    JoinToSpectator: LongInt;
    FastestCapSeconds: Single;
    FastestCapHolder: AnsiString;
    ComebackMatches: LongInt;
    CloseMatches: LongInt;
    MatchesAborted: LongInt;
    LoadCount: LongInt;
    CapTimeSum: Double;
    CapTimeCount: LongInt;
    MatchDurationSum: Int64;
    MatchDurationCount: LongInt; { matches summed in MatchDurationSum since MatchDurationBase was set }
    MatchDurationBase: Int64;    { the part of MatchDurationSum saved before 5.1, whose match count is unknown }
    ScoreSum: Int64;           { winning score of every finished match }
    ScoreCount: LongInt;       { the matches summed in ScoreSum since ScoreBase was set }
    ScoreBase: Int64;          { the part of ScoreSum saved before its matches were counted }
    HumansSampleSum: Int64;
    HumansSampleCount: LongInt;
    VoteStarts: LongInt;
    VotesPassed: LongInt;      { map votes started on this map that changed the map }
    VotedIn: LongInt;          { times a vote picked this map }
    EndHumansSum: Int64;       { players on the teams when a match on this map ended }
    StayedHumansSum: Int64;    { of them, still on the server two minutes into the next map }
    RetentionCount: LongInt;   { map ends measured that way }
    HealRegen: Double;         { health the regenerating polygons of the map gave back }
    CurveSum: array[0..9] of Int64;     { player-seconds per tenth of the match time }
    CurveSecs: array[0..9] of LongInt;  { seconds counted per tenth }
    AlphaFlagX, AlphaFlagY: Single;   { bases, from where main.pas reports the flags standing }
    BravoFlagX, BravoFlagY: Single;
    WeaponKills: array[0..WSLOT_COUNT - 1] of LongInt;
    WeaponPicks: array[0..WSLOT_COUNT - 1] of LongInt;
    WeaponPicksTeam: array[1..2, 0..WSLOT_COUNT - 1] of LongInt;  { picks of Alpha and Bravo players }
    MinX, MinY, MaxX, MaxY: Single;
    Heat: THeatCellArray;
    { the last time the map ran at all, with any players (LastPlayedTime: the last second played
      with the statistics on) }
    LastLoadedTime: Double;
    { how the survival rounds of the map ended, counted like the round wins: won by wiping out the
      other teams (by the team that won), won by the last one standing (free-for-all), won by a
      capture (Capture the Flag, Infiltration), nobody left standing, cut short by the map change }
    RoundsElimination: array[1..4] of LongInt;
    RoundsLastStanding: LongInt;
    RoundsCapture: LongInt;
    RoundsNoSurvivor: LongInt;
    RoundsMapChange: LongInt;
    { team games: the kills made by the players of each team, the kill balance of the map }
    KillsByTeam: array[1..4] of LongInt;
    { the weapon matchups of the map ([Matrix]): kills made with one weapon against another }
    Matchups: TMatchupCellArray;
    Dirty: Boolean;
    { Engine = mysql (zs_sqldb): the record as the shared database last had it, its version
      there, and whether it waits for the next exchange with it }
    SyncBase: AnsiString;
    SyncVersion: Int64;
    SyncDirty: Boolean;
  end;
  PMapProfile = ^TMapProfile;
  TMapProfileArray = array of TMapProfile;

  { The player-on-map records ([Matrix], zs_matrix): what one account did on one map, keyed by the
    account id and the map NAME. A record is made at the first event counted for the account on
    the map; its lists hold only what happened (sparse), each sorted by its key. }

  { one weapon of the account on the map }
  TPMWeapon = record
    Slot: LongInt;            { weapon slot, 0 .. WSLOT_COUNT - 1 }
    Kills: LongInt;
    Deaths: LongInt;          { deaths by this weapon }
    Shots: LongInt;
    Hits: LongInt;            { hits on enemies }
    Headshots: LongInt;
    Damage: Double;           { dealt to enemies }
    TimeUsed: LongInt;        { seconds alive with it in hand }
  end;
  PPMWeapon = ^TPMWeapon;
  TPMWeaponArray = array of TPMWeapon;

  { an opponent of the account on the map }
  TPMRival = record
    Id: LongInt;              { the opponent's account id }
    Kills: LongInt;           { the account killed him }
    Deaths: LongInt;          { he killed the account }
    DamageDealt: Single;      { to him }
    DamageTaken: Single;      { from him }
    LastFight: Double;        { the last kill or hit between the two }
    { the points the account won from him (its kills of him as they paid it, and with [Ranking]
      SelfkillMode = zerosum his selfkills under its fire) and the points it lost to him (the same
      the other way round) }
    PointsWon: LongInt;
    PointsLost: LongInt;
  end;
  PPMRival = ^TPMRival;
  TPMRivalArray = array of TPMRival;

  { the account's weapon against the opponent's weapon }
  TPMMatchup = record
    Mine: LongInt;            { weapon slot of the account }
    Theirs: LongInt;          { weapon slot the opponent held }
    Wins: LongInt;            { the account killed him }
    Losses: LongInt;          { he killed the account }
  end;
  PPMMatchup = ^TPMMatchup;
  TPMMatchupArray = array of TPMMatchup;

  TPlayerMapStats = record
    AccountId: LongInt;
    MapName: AnsiString;
    FirstPlayed: Double;
    LastPlayed: Double;
    TimePlayed: Int64;        { seconds played with the statistics on, not as a spectator }
    Matches: LongInt;         { matches of the map the account played in }
    Wins: LongInt;
    Losses: LongInt;
    Draws: LongInt;
    RoundsWon: LongInt;
    RoundsLost: LongInt;
    Kills: LongInt;
    Deaths: LongInt;
    Selfkills: LongInt;
    Teamkills: LongInt;
    Assists: LongInt;
    Points: LongInt;          { points won minus points lost on the map }
    Caps: LongInt;
    Returns: LongInt;
    Grabs: LongInt;
    Shots: LongInt;
    Hits: LongInt;
    HitsHead: LongInt;
    HitsBody: LongInt;
    HitsLegs: LongInt;
    DamageDealt: Double;
    DamageReceived: Double;
    HealRegen: Double;
    BestStreak: LongInt;
    FirstBloods: LongInt;     { the first kill of a match }
    RoundFirstBloods: LongInt; { the first kill of a survival round }
    LastStands: LongInt;
    LongestKill: Single;      { metres }
    { what else the account's own statistics count, counted the same way on the map: the sums add
      what an event added to the account's counter (zs_engine_matrix.inc), a best is the best of
      the map. The field ids are in zs_fields (RegisterMatrixFields). }
    { lives, time and movement }
    TimeAlive: Int64;         { seconds alive while the survival statistics counted }
    LongestLife: LongInt;     { seconds, the longest life }
    TeamkillDeaths: LongInt;  { killed by a teammate }
    Traveled: Double;         { metres }
    BestLifeDistance: Single; { metres covered in one life, the most }
    JetTime: Int64;           { seconds of flight }
    { damage, hits and healing }
    DamageFriendly: Double;
    DamageFriendlyReceived: Double;
    HitsUnknown: LongInt;     { bullets whose zone was not clear }
    FriendlyHits, FriendlyHitsHead, FriendlyHitsBody, FriendlyHitsLegs: LongInt;
    HitsByFriendly: LongInt;
    SelfHits: LongInt;
    FirstDamages: LongInt;    { the first hit of a match or a survival round }
    HealKits: Double;         { health from medical, berserker and predator kits }
    HealKitCount: LongInt;
    KitPickups: array[0..KIT_KINDS - 1] of LongInt;   { by kind (KIT_KIND_STYLES) }
    { kills }
    PosthumousKills, RevengeKills, AvengerKills, SaviorKills: LongInt;
    Dominations, DominationsEnded, ShutDowns, Finishers: LongInt;
    GrenadeKills, ExplosionMultiKills, WallKills, CoverShotKills: LongInt;
    BinkRecoveryKills, ProneKills, AirKills, HeightKills, CampKills, VestKills: LongInt;
    SpawnKills, SpawnDeaths, LongKills100, BarrettLongKills: LongInt;
    LongestBarrett: Single;   { metres }
    KillDistSum: Double;      { metres, the kills whose distance is known (KillDistCount) }
    KillDistCount: Int64;
    TTKSumTicks: Int64;       { from the first hit to the kill }
    TTKCount: LongInt;
    BestTTKTicks: LongInt;    { the fastest, 0 = none }
    KnifeStreak: LongInt;     { knife kills in one life, the most }
    ForcedSelfkills: LongInt; { enemies who killed themselves under this player's fire }
    SelfkillsUnderFire: LongInt;
    BaseDefenseKills, BaseAttackKills: LongInt;
    { the multi-kill medals }
    DoubleKills, TripleKills, MultiKills, MultiKillsX2, SerialKills, InsaneKills, GimmeMore, MastaKilla,
      StopIt: LongInt;
    { flags }
    FlagDrops, FlagThrows, FlaggerKills, FlaggerAssists, FlagDefenses, KillsWithFlag: LongInt;
    FlaggerTeamkills, TeamkillsWithFlag: LongInt;
    FlagHoldTime: LongInt;    { seconds }
    FastestCap: Single;       { seconds, 0 = none }
    CapsUnder10s, EscortKills, FlagJuggles, ContestedHolds: LongInt;
    HtfPoints: LongInt;
    HtfHoldTime, HtfTeamHoldTime: Int64;   { seconds with the flag, and with it in the team }
    { matches and rounds }
    LeaveLosses, AlphaWins, AlphaLosses, BravoWins, BravoLosses, ComebackWins: LongInt;
    ClutchesWon, AdvanceRoundsWon, AdvanceRoundsPlayed: LongInt;
    { the special weapons (their shots and hits on enemies are in Weapons) }
    KnifeThrows, KnifeThrowHits, KnifeStabs, NadeSelfHits: LongInt;
    BowKills, RamboKills: LongInt;
    BowTime: Int64;           { seconds }
    Weapons: TPMWeaponArray;      { by Slot }
    Rivals: TPMRivalArray;        { by Id }
    Matchups: TPMMatchupArray;    { by Mine, then Theirs }
    Heat: THeatCellArray;         { by Cell: the cells of the map heatmap, kills and deaths }
    { runtime only }
    Dirty: Boolean;
    MapNo: LongInt;           { the number of the map in the table (TPlayerMapTable) }
    MapPos, AccPos: LongInt;  { where the table lists the record under its map and its account }
    MatchKey: Double;         { the start of the last match counted in Matches }
    { Engine = mysql (zs_sqldb): the record as the shared database last had it ('' = not there
      yet), its version there, and whether it waits for the next exchange with it }
    SyncBase: AnsiString;
    SyncVersion: Int64;
    SyncDirty: Boolean;
  end;
  PPlayerMapStats = ^TPlayerMapStats;
  TPlayerMapPtrArray = array of PPlayerMapStats;

  TWeaponGlobal = record
    DistBucket: array[0..4] of Int64;
    KillDistSum: Double;
    KillDistCount: Int64;
    TTKSumTicks: Int64;
    TTKCount: Int64;
    VestKills: Int64;
    Picks: Int64;
    PicksTeam: array[1..4] of Int64;
  end;

  THitModelCell = record
    N: Int64;
    SumX, SumY, SumXX, SumYY, SumXY: Double;
  end;

  TDailyStat = record
    Day: LongInt;
    Uniques: LongInt;
    NewPlayers: LongInt;
    Sessions: LongInt;
    PlaySeconds: Int64;
    PeakOnline: LongInt;
    Kills: LongInt;
  end;
  TDailyStatArray = array of TDailyStat;

  TServerRecords = record
    PeakOnlineCount: LongInt;
    PeakOnlineDurationSec: Int64;
    PeakOnlineDate: Double;
    HourlyActivity: array[0..23] of Int64;
    WeekdayHour: array[0..6, 0..23] of Int64;
    Matchups: array[0..WSLOT_COUNT - 1, 0..WSLOT_COUNT - 1] of LongInt;
    WeaponGlobal: array[0..WSLOT_COUNT - 1] of TWeaponGlobal;
    HitModel: array[0..3, 0..2] of THitModelCell;
    Daily: TDailyStatArray;
    NextProfileID: LongInt;
    NextMapID: LongInt;
    NextSeasonId: LongInt;
    SeasonId: LongInt;
    SeasonStart: Double;
    SeasonEnd: Double;
    LastBalanceDay: LongInt;
    LastCheckpointsDay: LongInt;
    { the day a surplus of points started to wait for an inactive account that may give (0 = none) }
    CheckWaitSince: Double;
    LastAutoBackup: Double;
    TotalMatches: Int64;
    MatchupsFixed: Boolean;
    MatchLengthsSplit: Boolean;  { MatchDurationBase of every map was set when the data was first loaded by 5.1 }
    ScoresSplit: Boolean;        { ScoreBase of every map was set when the data was first loaded by 5.2 }
    { what the score guard took back (see [Integrity]) }
    ScoreFixes: Int64;
    VoidedCaptures: Int64;
    { how well the team balance predicted the winner of two-team matches }
    BalPredCount: Int64;
    BalBrierSum: Double;
    BalBinCount: array[0..9] of Int64;   { matches by the predicted chance of Alpha, in tenths }
    BalBinWins: array[0..9] of Int64;    { of them, the matches Alpha won }
    Dirty: Boolean;
    { Engine = mysql (zs_sqldb): the record as the shared database last had it, its version
      there, and whether it waits for the next exchange with it }
    SyncBase: AnsiString;
    SyncVersion: Int64;
    SyncDirty: Boolean;
  end;
  PServerRecords = ^TServerRecords;

  TSeasonEntry = record
    Place: LongInt;
    ProfileId: LongInt;
    Name: AnsiString;
    Points: LongInt;
    SeasonPoints: LongInt;
    Kills: LongInt;
    Deaths: LongInt;
    Caps: LongInt;
    Wins: LongInt;
    TimePlayed: Int64;
    Rating: Single;
  end;
  TSeasonEntryArray = array of TSeasonEntry;

  TSeasonArchive = record
    Id: LongInt;
    StartDate: Double;
    EndDate: Double;
    Entries: TSeasonEntryArray;
  end;
  TSeasonArchiveArray = array of TSeasonArchive;

  TZSEventKind = (zeNone, zeJoin, zeLeave, zeTeam, zeSteamAuth, zeSpawn, zeKill, zeDamage,
    zeShot, zeGrenade, zeKnifeThrow, zeWeapon, zeKit, zeFlag, zeSample, zeTick,
    zeMapBefore, zeMapAfter, zePlayerScore, zeVote, zeCommand, zeAuthResult, zeMailResult,
    zeReloadConfig, zeShutdown, zeRay, zeTeamRequest, zeMoveResult, zeIntegrity, zeAmmo, zeRealistic, zeHeal,
    zeMapList);

const
  { the tags of IO jobs somebody waits for }
  TAG_EXPORT = 7001;
  TAG_SAVE = 7002;
  TAG_EXPORT_DONE = 7003;

type
  TZSEvent = record
    Kind: TZSEventKind;
    Tick: LongInt;
    Slot: LongInt;
    Slot2: LongInt;
    Serial: LongWord;
    Serial2: LongWord;
    I: array[0..7] of LongInt;
    F: array[0..15] of Single;
    S1, S2, S3, S4: AnsiString;
  end;
  TZSEventArray = array of TZSEvent;

  TZSAction = record
    Kind: LongInt;
    Slot: LongInt;
    Color: LongInt;
    P1, P2, P3, P4, P5: LongInt;
    F1, F2, F3: Single;
    Text: AnsiString;
  end;
  TZSActionArray = array of TZSAction;

  TCommandLine = record
    Text: AnsiString;
    Color: LongInt;
  end;

  TCommandResult = record
    Lines: array of TCommandLine;
    TotalPages: LongInt;
    CurrentPage: LongInt;
  end;

function OtherDataToString(const OD: TOtherData): AnsiString;
procedure SetOtherDataString(var OD: TOtherData; const S: AnsiString);
function RatingFamilyOf(GameStyle: LongInt): LongInt;
function IsTeamStyle(GameStyle: LongInt): Boolean;
{ the place of a kit style in KIT_KIND_STYLES, -1 for anything else }
function KitKind(Style: LongInt): LongInt;
{ every kit an account picked up, all kinds together }
function KitsPickedUp(const P: TPlayerProfile): Int64;

implementation

function OtherDataToString(const OD: TOtherData): AnsiString;
var
  Len: Integer;
begin
  Len := 0;
  while (Len < MAX_STRING_LEN) and (OD.DataString[Len] <> #0) do Inc(Len);
  SetString(Result, @OD.DataString[0], Len);
end;

procedure SetOtherDataString(var OD: TOtherData; const S: AnsiString);
var
  Len: Integer;
begin
  FillChar(OD.DataString, SizeOf(OD.DataString), 0);
  Len := Length(S);
  if Len > MAX_STRING_LEN - 1 then Len := MAX_STRING_LEN - 1;
  if Len > 0 then Move(S[1], OD.DataString[0], Len);
end;

function RatingFamilyOf(GameStyle: LongInt): LongInt;
begin
  case GameStyle of
    GS_DM, GS_PM, GS_RM: Result := RF_FFA;
    GS_CTF: Result := RF_CTF;
    else Result := RF_TEAM;
  end;
end;

function IsTeamStyle(GameStyle: LongInt): Boolean;
begin
  Result := GameStyle in [GS_TM, GS_CTF, GS_INF, GS_HTF];
end;

function KitKind(Style: LongInt): LongInt;
var
  k: LongInt;
begin
  for k := 0 to KIT_KINDS - 1 do
    if KIT_KIND_STYLES[k] = Style then
      Exit(k);
  Result := -1;
end;

function KitsPickedUp(const P: TPlayerProfile): Int64;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to KIT_KINDS - 1 do
    Inc(Result, P.KitPickups[k]);
end;

end.
