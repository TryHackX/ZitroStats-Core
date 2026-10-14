unit zs_config;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util;

const
  { [MySQL] Engine }
  MYSQL_LOCAL = 0;
  MYSQL_MIRROR = 1;
  MYSQL_SHARED = 2;

  MAX_TIERS = 16;

  { [MapVote] command switches (TZSConfig.MapVoteCommands) }
  MVC_VOTE = 1;            { !v, !vote }
  MVC_NEXTMAP = 2;         { !nextmap }
  MVC_LASTMAP = 4;         { !lastmap, !votelast, !votelastmap }
  MVC_RANDOMMAP = 8;       { !randommap }
  MVC_MAP = 16;            { !map, !map <part> }
  MVC_VOTEMAP = 32;        { !votemap <part> }
  MVC_SLASHVOTEMAP = 64;   { /votemap <part> (and the vote menu and F12 of the clients) }
  MVC_MAPS = 128;          { !maps }
  MVC_ALLMAPS = 256;       { !allmaps }
  MVC_SEARCHMAP = 512;     { !searchmap }
  MVC_ALL = 1023;
  { [Sprees]: the levels of a kill streak, and where the message of each goes }
  MAX_SPREE_LEVELS = 12;
  SPREE_OFF = 0;
  SPREE_CHAT = 1;
  SPREE_BIGTEXT = 2;
  SPREE_BOTH = 3;

type
  TRankTier = record
    Name: AnsiString;
    MinPoints: LongInt;
    MinRating: Single;
    MinGlicko: Single;
    MinOpenSkill: Single;
    MinMmr: Single;
    Color: LongInt;
  end;

  { a level of [Sprees]: a streak that reaches Kills kills (1 to SPREE_MAX_KILLS) }
  TSpreeLevel = record
    Kills: LongInt;
    Name: AnsiString;
    Style: LongInt;           { SPREE_* }
    Text: AnsiString;         { %s = the player, %d = the kills }
  end;

  TZSConfig = record
    { paths }
    ScriptDir: AnsiString;
    DataPath: AnsiString;
    LogPath: AnsiString;
    SnapshotFile: AnsiString;
    JournalFile: AnsiString;
    BackupPath: AnsiString;
    LegacyAccountsBin: AnsiString;
    LegacyMapsBin: AnsiString;
    LegacyAccountsDb: AnsiString;
    LegacyMapsDb: AnsiString;
    LegacyServerRecords: AnsiString;
    SourceCodepage: LongInt;

    { persistence }
    JournalFlushSeconds: LongInt;
    CompactIntervalMinutes: LongInt;
    CompactJournalMB: LongInt;
    AutoBackupDays: LongInt;
    BackupKeep: LongInt;
    RestoreOnDamage: Boolean;

    { [MySQL] Engine: local (files only), mirror (files, and a copy in MySQL for websites and for
      the Shared switches) or mysql (one database for every server, zs_sqldb). MySQLEnabled is
      the mirror. }
    MySQLEngine: LongInt;
    MySQLEngineGiven: Boolean;
    MySQLSyncSeconds: LongInt;
    MySQLEnabled: Boolean;
    MySQLHost: AnsiString;
    MySQLPort: LongInt;
    MySQLDatabase: AnsiString;
    MySQLUser: AnsiString;
    MySQLPassword: AnsiString;
    MySQLServerID: LongInt;
    MySQLMirrorSeconds: LongInt;
    MySQLFullJson: Boolean;
    { what the servers of one database add up ([MySQL] Shared...) }
    MySQLShareProfiles: Boolean;
    MySQLShareRankings: Boolean;
    MySQLShareMaps: Boolean;
    MySQLShareWeapons: Boolean;
    MySQLShareServer: Boolean;

    { ranking }
    StartingPoints: LongInt;
    MaxPointGive: LongInt;
    MinimumPointDivider: LongInt;
    Divider: LongInt;
    PowerDivider: LongInt;
    MinPointGive: LongInt;
    MinimumPoints: LongInt;
    TopDisplayLinesCount: LongInt;
    RankingSystem: AnsiString;   { elo | mmr | glicko2 | openskill }
    MmrStart: Double;
    MmrK: Double;
    MmrPlacementGames: LongInt;
    RankingFamily: AnsiString;   { auto | ffa | team | ctf }
    RatingMode: AnsiString;      { skill | gamemode | unified (legacy performance index) }
    TierBy: AnsiString;          { points | rating | mmr | glicko2 | openskill | both | all: what decides the tier }
    SelfkillMode: AnsiString;    { penalty | zerosum }
    SelfkillPenalty: LongInt;
    SelfkillAssistShare: LongInt; { zerosum: % of the kill points the enemy who hit the player gets }
    TeamkillPenalty: LongInt;
    MinHumansForStats: LongInt;
    { the colours of everything written in the game, as 0xRRGGBB }
    ColHeader: LongInt;
    ColSubHeader: LongInt;
    ColCombat: LongInt;
    ColShooting: LongInt;
    ColFeats: LongInt;
    ColObjective: LongInt;
    ColTeamplay: LongInt;
    ColMatches: LongInt;
    ColActivity: LongInt;
    ColHint: LongInt;
    ColTop1: LongInt;
    ColTop2: LongInt;
    ColTop3: LongInt;
    ColYou: LongInt;
    ColOtherRow: LongInt;
    ColBad: LongInt;
    ColGood: LongInt;
    ColWarn: LongInt;
    ColRankLine: LongInt;
    TeamSwitchCountSeconds: LongInt;   { a switch to the spectators counts once per this window }
    SelfkillPercentBase: AnsiString;   { all = every ended life, enemy = only deaths by opponents }
    MinHumansForSurvival: LongInt;  { time alive and the longest life }
    MinTeamPerSide: LongInt;   { 0 = off }
    MinFFAHumans: LongInt;     { 0 = off }

    { inactivity }
    InactivityMode: AnsiString;  { protection | decay | none }
    InactivityDays: LongInt;
    BalanceHour: LongInt;
    BalanceMinAccounts: LongInt;
    BalanceMinRecipients: LongInt;
    BalanceFloorPoints: LongInt;
    BalanceRecipientMaxPoints: LongInt;
    BalanceMaxPayout: LongInt;
    CheckPointsEnabled: Boolean;
    CheckPointsActiveDays: LongInt;
    CheckPointsMaxWaitDays: LongInt;   { a surplus nobody may give is taken anyway after this many days; 0 = never }
    ProtectSessionSeconds: LongInt;
    ProtectEventsPerDay: LongInt;
    ProtectMaxDays: LongInt;
    DecayHideAfterDays: LongInt;

    { glicko-2 / openskill }
    GlickoTau: Double;
    GlickoRating: Double;
    GlickoRD: Double;
    GlickoVolatility: Double;
    GlickoConservative: Double;
    OSMu: Double;
    OSSigma: Double;
    OSBeta: Double;
    OSKappa: Double;

    { anti-farm }
    InactiveVictimSeconds: LongInt;
    InactiveVictimMultipliers: array of LongInt;
    SuspiciousEnabled: Boolean;
    SuspiciousMaxHumans: LongInt;
    SuspiciousKills: LongInt;
    SuspiciousWindowMinutes: LongInt;
    SuspiciousVictimMaxKills: LongInt;
    SuspiciousNotifyAdmins: Boolean;
    SuspiciousSharedDevices: Boolean;
    SuspiciousOutliers: Boolean;

    { matches }
    CountAbortedMatches: Boolean;
    MinParticipationPercent: LongInt;
    MinParticipationSeconds: LongInt;
    LeaverCountsAsLoss: Boolean;
    LeaverMinProgressPercent: LongInt;

    { ctf }
    CapPoolPoints: LongInt;
    CapWinnerSharePct: LongInt;
    FlagScoreFallbackPoints: LongInt;

    { mechanics }
    VisitCooldownMinutes: LongInt;
    SaviorSeconds: Double;
    AvengerSeconds: Double;
    AssistSeconds: Double;
    AssistMinDamagePercent: Double;
    MultiKillWindowSeconds: Double;
    SpawnKillSeconds: Double;
    CampSeconds: LongInt;
    CampRadius: LongInt;
    BinkDamage: Double;
    BinkSeconds: Double;
    FinisherSeconds: Double;
    EscortRadius: LongInt;
    JuggleSeconds: Double;
    ContestedHoldSeconds: Double;
    HeightAdvantagePixels: LongInt;
    MaxHealth: LongInt;
    MaxHealthRealistic: LongInt;
    BaseRadiusMeters: LongInt;
    LastStandMinPlayers: LongInt;   { humans in a survival round for a last stand: 1 against 1 is none }

    { identity & accounts }
    SteamAuthWaitSeconds: LongInt;
    NameHistoryLimit: LongInt;
    DuplicateHWID: AnsiString;   { allow | warn | kick }
    DuplicateIP: AnsiString;
    DuplicateSteam: AnsiString;
    MinPasswordLength: LongInt;
    MaxPasswordLength: LongInt;
    PasswordIterations: LongInt;
    TrustedDeviceDays: LongInt;
    TrustDeviceSameIP: Boolean;
    LoginMaxAttempts: LongInt;
    LoginLockMinutes: LongInt;
    LoginMaxAttemptsAccount: LongInt; { wrong passwords from every source together that lock the account }
    UnauthenticatedAction: AnsiString; { none | spectator | kick }
    LoginGraceSeconds: LongInt;
    LoginReturnToGame: Boolean;      { after a login put a player we sent to the spectators back }
    TrustedDevicesEnabled: Boolean;  { trusted computers at all }
    AllowTrustChoice: Boolean;       { players may switch trusting off for their own account }
    AllowPasswordRemoval: Boolean;   { /removemypass takes the password off an account }
    LoginReminderSeconds: LongInt;

    { mail }
    MailEnabled: Boolean;
    MailMethod: AnsiString;      { curl | sendmail | command }
    MailCurlPath: AnsiString;
    MailSmtpUrl: AnsiString;
    MailSmtpUser: AnsiString;
    MailSmtpPassword: AnsiString;
    MailFrom: AnsiString;
    MailFromName: AnsiString;
    MailSendmailPath: AnsiString;
    MailCommand: AnsiString;
    MailCodeMinutes: LongInt;
    MailMinIntervalMinutes: LongInt;
    MailMaxPerDay: LongInt;
    MailMaxPerDayServer: LongInt;   { e-mails the server sends a day, all accounts together }
    MailMaxPerDaySource: LongInt;   { e-mails asked for a day from one computer or one network }
    MailTimeoutSeconds: LongInt;
    MailServerName: AnsiString;

    { admin }
    AdminConfirmPassword: AnsiString;
    AdminConfirmSeconds: LongInt;
    AdminConfirmLockMinutes: LongInt;
    AdminAuditLog: Boolean;

    { messages & hud }
    WelcomeEnabled: Boolean;
    WelcomeBroadcast: Boolean;
    InfoBroadcastSeconds: LongInt;
    InfoBroadcastText: AnsiString;
    ContactText: AnsiString;
    AchievementBroadcast: Boolean;
    RoundWinBroadcast: Boolean;
    SeasonBroadcast: Boolean;
    HudLayer: LongInt;
    HudX: LongInt;
    HudY: LongInt;
    HudScale: Single;
    HudColor: LongInt;
    HudRefreshSeconds: LongInt;
    HudEventSeconds: LongInt;    { how long a note (points, first blood, a multi-kill ...) stays on the line }
    HudEnabled: Boolean;         { 0 = no HUD on this server }
    HudDefaultOn: Boolean;       { new accounts start with the HUD on }

    { [Sprees]: the levels by their kills, the message when a spree ends, and how they look; the
      streaks are counted whatever these say }
    SpreesEnabled: Boolean;
    SpreeLevels: array[0..MAX_SPREE_LEVELS - 1] of TSpreeLevel;
    SpreeLevelCount: LongInt;
    SpreeShutStyle: LongInt;
    SpreeShutText: AnsiString;   { %s = the killer, then the victim, %d = the kills of the streak }
    SpreeColor: LongInt;
    SpreeBigSeconds: LongInt;
    SpreeBigScale: Single;
    SpreeBigY: LongInt;

    { commands }
    HeavyCooldownSeconds: LongInt;
    SearchCooldownSeconds: LongInt;   { a name searched in every account, a page of a heavy list }
    CommandsPerSecond: LongInt;
    MinSamplePercent: LongInt;        { the least count a share or an average needs in the lists, in % of the built-in }

    { [LastFight]: !lastfight and the lines after a death (zs_fight, zs_engine_fight.inc) }
    LastFightEnabled: Boolean;
    LastFightSummary: Boolean;         { DeathSummary }
    LastFightBeforeSeconds: LongInt;   { what a record holds before the death }
    LastFightAfterSeconds: LongInt;    { and after it: bullets still flying, the points of the death }

    { seasons & achievements }
    SeasonsEnabled: Boolean;
    SeasonLength: AnsiString;    { monthly | days }
    SeasonDays: LongInt;
    SeasonArchiveTop: LongInt;
    SeasonMinMinutes: LongInt;
    SeasonPointsReset: AnsiString; { none | soft | hard }
    SeasonSoftFactor: Double;
    AchievementsEnabled: Boolean;

    { export & webhook }
    JSONExportEnabled: Boolean;
    JSONExportPath: AnsiString;
    JSONExportTopCount: LongInt;
    FullExportEnabled: Boolean;
    FullExportPath: AnsiString;
    ExportIntervalMinutes: LongInt;
    WebhookEnabled: Boolean;
    WebhookUrl: AnsiString;
    WebhookEvents: AnsiString;
    WebhookFormat: AnsiString;   { json | discord }

    { leagues }
    LeaguesEnabled: Boolean;
    LeagueDivisions: LongInt;
    LeaguePlacementMatches: LongInt;
    LeaguePercents: AnsiString;
    LeagueSource: AnsiString;    { mmr | rating }

    { team balance }
    BalanceEnabled: Boolean;
    BalanceMethod: AnsiString;         { blend | global | map }
    BalanceSkill: AnsiString;          { mmr | glicko2 | openskill | points }
    BalanceMinPlayers: LongInt;
    BalanceAssignJoins: Boolean;
    BalanceJoinTolerance: Double;      { chance points }
    BalanceJoinReviewSeconds: LongInt;
    BalanceThreshold: Double;          { chance of the stronger team, percent }
    BalanceTarget: Double;
    BalanceMinGain: Double;
    BalanceSustainSeconds: LongInt;
    BalanceCheckSeconds: LongInt;
    BalanceCooldownSeconds: LongInt;
    BalanceMaxMovesPerMap: LongInt;
    BalanceMaxCountDiff: LongInt;
    BalanceLeaveGraceSeconds: LongInt;
    BalanceMinTimeLeftSeconds: LongInt;
    BalanceMoveOnDeath: Boolean;
    BalancePendingMaxSeconds: LongInt;
    BalanceProtectTop: Boolean;
    BalanceLockMinutes: Double;
    BalanceImmunityMinutes: Double;
    BalanceRejoinMemoryMinutes: Double;
    BalanceSizeImpact: Double;
    BalanceSkillPerDouble: Double;
    BalanceUncertaintyGames: LongInt;
    BalanceFormWeight: Double;
    BalanceFormFullMinutes: Double;
    BalanceFormStep: Double;
    BalanceMapWarmupMinutes: Double;
    BalanceUseMapBias: Boolean;
    BalanceMapStart: AnsiString;       { keep | fix | shuffle | mix }
    BalanceMapStartSeconds: LongInt;
    BalanceVolunteers: Boolean;
    BalanceVolunteerSeconds: LongInt;
    BalanceAfkSeconds: LongInt;
    BalanceAfkFactor: Double;
    BalanceBotSkill: LongInt;          { percentile of the server }
    BalanceCountBots: Boolean;
    BalanceTeammatchTeams: LongInt;    { 0 = the teams in use }
    BalanceExclude: AnsiString;        { #id, #id }
    BalanceAutoTune: Boolean;
    BalanceAnnounce: Boolean;

    { score guard: the Soldat scoring bugs main.pas takes care of }
    IntegrityEnabled: Boolean;
    IntegrityFixJoinScore: Boolean;
    IntegrityVoidDoubleCaptures: Boolean;
    IntegrityMinOpponents: LongInt;
    IntegrityRespawnAfterMapChange: Boolean;
    IntegrityProtectMapChange: Boolean;
    IntegrityAnnounce: Boolean;

    { [Matrix]: the player-on-map records (zs_matrix) and the weapon matchups of the maps }
    MatrixEnabled: Boolean;            { off: none of it is recorded }
    MatrixPruneDays: LongInt;          { the records of accounts not seen for this many days go; 0 = never }
    MatrixMapPruneDays: LongInt;       { also a map not played / a rival not met for this many days; 0 = never }
    MatrixPlayerHeatmap: Boolean;      { the heat cells of every player on every map }
    MatrixMaxRivals: LongInt;          { rivals one record keeps at most }

    { map vote ([MapVote], zs_engine_mapvote.inc) }
    MapVoteEnabled: Boolean;
    MapVotePercent: LongInt;           { of the players who may vote (MvEligible) }
    MapVoteSeconds: LongInt;
    MapVoteStarterCooldown: LongInt;   { seconds before the starter of a vote may start another }
    MapVoteGapSeconds: LongInt;        { seconds after a vote before the next one, whoever starts it }
    MapVoteMinTimeLeft: LongInt;       { seconds of the map a new vote needs }
    MapVoteBlockAfterChange: LongInt;  { seconds after a map change without new votes }
    MapVoteMinPlayers: LongInt;
    MapVoteCountSpectators: Boolean;   { 0 = only the spectators who start the vote or vote for it count }
    MapVoteAllowAnyMap: Boolean;       { maps of the folder that are not in the maps list may be voted }
    MapVoteFilterByStyle: Boolean;     { ctf_/inf_/htf_ restrict !randommap and !allmaps to the style played }
    MapVoteMapsFolder: AnsiString;     { '' = the maps folder of the server }
    MapVoteRescanMinutes: LongInt;     { 0 = only at the start and on /zs_maps rescan }
    MapVoteRestorePercent: LongInt;    { the vote percent put back when the old one is not known; 0 = leave it }
    MapVoteCommands: LongInt;          { MVC_* bits: the commands that answer }

    { debug }
    DebugRayCast: Boolean;

    { [Bridges]: the library reads the running server (5.6) }
    BridgeHook: Boolean;               { a hook in the server's CreateBullet reports every bullet }
    BridgeMemory: Boolean;             { the soldiers and bullets are read from the server's memory }
    BridgeGeometry: Boolean;           { the map file in the library: the rays of Cover (live) / (shot) }

    { tiers }
    RankTiers: array[0..MAX_TIERS - 1] of TRankTier;
    RankTierCount: LongInt;
  end;
  PZSConfig = ^TZSConfig;

procedure SetConfigDefaults(var C: TZSConfig);
{ The palette in use. Every colour is a setting ([Colors] in settings.ini); these read
  what was loaded, so the whole of the output follows the file without a single number
  being written down twice. }
function CLR_HEADER: LongInt;
function CLR_SUBHEADER: LongInt;
function CLR_COMBAT: LongInt;
function CLR_SHOOTING: LongInt;
function CLR_FEATS: LongInt;
function CLR_OBJECTIVE: LongInt;
function CLR_TEAMPLAY: LongInt;
function CLR_MATCHES: LongInt;
function CLR_ACTIVITY: LongInt;
function CLR_HINT: LongInt;
function CLR_TOP1: LongInt;
function CLR_TOP2: LongInt;
function CLR_TOP3: LongInt;
function CLR_YOU: LongInt;
function CLR_OTHER_ROW: LongInt;
function CLR_BAD: LongInt;
function CLR_GOOD: LongInt;
function CLR_WARN: LongInt;
function CLR_RANK_LINE: LongInt;

procedure ApplyPalette(const C: TZSConfig);

function LoadConfigFile(const Path: AnsiString; var C: TZSConfig; Warnings: TStrings): Boolean;
function ResolvePath(const ServerRelative: AnsiString): AnsiString;
function ParseColor(const S: AnsiString; Default: LongInt): LongInt;
{ the MVC_* bit of a command switch of [MapVote] (a key in lower case), 0 = no such switch }
function MapVoteCommandSwitch(const Key: AnsiString): LongInt;
{ a message of [Sprees] as the players read it: each %s takes the next of Names (one that is left
  over stays empty), %d the kills and %% a %; any other % stays as it is written }
function SpreeText(const Template: AnsiString; const Names: array of AnsiString; Kills: LongInt): AnsiString;
{ the level of C a streak of Kills kills reaches, -1 = none }
function SpreeLevelOf(const C: TZSConfig; Kills: LongInt): LongInt;

implementation

function ResolvePath(const ServerRelative: AnsiString): AnsiString;
begin
  Result := Trim(ServerRelative);
  {$IFDEF WINDOWS}
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
  {$ELSE}
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  {$ENDIF}
end;

function ParseColor(const S: AnsiString; Default: LongInt): LongInt;
var
  T: AnsiString;
begin
  T := Trim(S);
  if T = '' then Exit(Default);
  if T[1] = '#' then T := '$' + Copy(T, 2, MaxInt);
  if (Length(T) > 2) and (LowerCase(Copy(T, 1, 2)) = '0x') then T := '$' + Copy(T, 3, MaxInt);
  Result := StrToIntDef(T, Default) and $FFFFFF;
end;

function MapVoteCommandSwitch(const Key: AnsiString): LongInt;
begin
  if Key = 'votecommand' then Result := MVC_VOTE
  else if Key = 'nextmapcommand' then Result := MVC_NEXTMAP
  else if Key = 'lastmapcommand' then Result := MVC_LASTMAP
  else if Key = 'randommapcommand' then Result := MVC_RANDOMMAP
  else if Key = 'mapcommand' then Result := MVC_MAP
  else if Key = 'votemapcommand' then Result := MVC_VOTEMAP
  else if Key = 'slashvotemap' then Result := MVC_SLASHVOTEMAP
  else if Key = 'mapscommand' then Result := MVC_MAPS
  else if Key = 'allmapscommand' then Result := MVC_ALLMAPS
  else if Key = 'searchmapcommand' then Result := MVC_SEARCHMAP
  else Result := 0;
end;

procedure AddTier(var C: TZSConfig; const Name: AnsiString; Pts: LongInt; Rating, Glicko, OS, Mmr: Single; Color: LongInt);
begin
  if C.RankTierCount >= MAX_TIERS then Exit;
  C.RankTiers[C.RankTierCount].Name := Name;
  C.RankTiers[C.RankTierCount].MinPoints := Pts;
  C.RankTiers[C.RankTierCount].MinRating := Rating;
  C.RankTiers[C.RankTierCount].MinGlicko := Glicko;
  C.RankTiers[C.RankTierCount].MinOpenSkill := OS;
  C.RankTiers[C.RankTierCount].MinMmr := Mmr;
  C.RankTiers[C.RankTierCount].Color := Color;
  Inc(C.RankTierCount);
end;

procedure AddSpreeLevel(var C: TZSConfig; Kills: LongInt; const Name: AnsiString; Style: LongInt; const Text: AnsiString);
begin
  if C.SpreeLevelCount >= MAX_SPREE_LEVELS then Exit;
  C.SpreeLevels[C.SpreeLevelCount].Kills := Kills;
  C.SpreeLevels[C.SpreeLevelCount].Name := Name;
  C.SpreeLevels[C.SpreeLevelCount].Style := Style;
  C.SpreeLevels[C.SpreeLevelCount].Text := Text;
  Inc(C.SpreeLevelCount);
end;

{ the built-in levels, with the names of Unreal Tournament, Quake and DotA; the first one comes
  early, as a life of survival deathmatch holds few kills }
procedure DefaultSpreeLevels(var C: TZSConfig);
begin
  C.SpreeLevelCount := 0;
  AddSpreeLevel(C, 3, 'Killing Spree', SPREE_CHAT, '%s is on a KILLING SPREE!');
  AddSpreeLevel(C, 5, 'Rampage', SPREE_BOTH, '%s is on a RAMPAGE!');
  AddSpreeLevel(C, 7, 'Dominating', SPREE_BOTH, '%s is DOMINATING!');
  AddSpreeLevel(C, 10, 'Unstoppable', SPREE_BOTH, '%s is UNSTOPPABLE!');
  AddSpreeLevel(C, 12, 'Mega Kill', SPREE_BOTH, '%s: MEGA KILL!');
  AddSpreeLevel(C, 15, 'Ultra Kill', SPREE_BOTH, '%s: ULTRA KILL!');
  AddSpreeLevel(C, 17, 'Wicked Sick', SPREE_BOTH, '%s is WICKED SICK!');
  AddSpreeLevel(C, 20, 'Monster Kill', SPREE_BOTH, '%s: MONSTER KILL!');
  AddSpreeLevel(C, 25, 'Godlike', SPREE_BOTH, '%s is GODLIKE!');
  AddSpreeLevel(C, 30, 'Holy Shit', SPREE_BOTH, '%s: HOLY SHIT! %d kills in a row!');
end;

{ the levels by their kills, the lowest first }
procedure SortSpreeLevels(var C: TZSConfig);
var
  i, j: LongInt;
  T: TSpreeLevel;
begin
  for i := 1 to C.SpreeLevelCount - 1 do
  begin
    T := C.SpreeLevels[i];
    j := i - 1;
    while (j >= 0) and (C.SpreeLevels[j].Kills > T.Kills) do
    begin
      C.SpreeLevels[j + 1] := C.SpreeLevels[j];
      Dec(j);
    end;
    C.SpreeLevels[j + 1] := T;
  end;
end;

{ off, chat, bigtext or both; -1 = none of them }
function SpreeStyleOf(const S: AnsiString): LongInt;
var
  L: AnsiString;
begin
  L := LowerCase(Trim(S));
  if L = 'off' then Result := SPREE_OFF
  else if L = 'chat' then Result := SPREE_CHAT
  else if L = 'bigtext' then Result := SPREE_BIGTEXT
  else if L = 'both' then Result := SPREE_BOTH
  else Result := -1;
end;

procedure SetConfigDefaults(var C: TZSConfig);
begin
  C.DataPath := 'nickreg/';
  C.LogPath := 'logs/zitrostats/';
  C.SnapshotFile := 'zitrostats.zsdb';
  C.JournalFile := 'zitrostats.journal';
  C.BackupPath := 'nickreg/backup/';
  C.LegacyAccountsBin := 'nickreg/accounts.bin';
  C.LegacyMapsBin := 'nickreg/maps.bin';
  C.LegacyAccountsDb := 'nickreg/accounts.db';
  C.LegacyMapsDb := 'nickreg/maps.db';
  C.LegacyServerRecords := 'nickreg/server_records.ini';
  C.SourceCodepage := 1250;

  C.JournalFlushSeconds := 10;
  C.CompactIntervalMinutes := 360;
  C.CompactJournalMB := 32;
  C.AutoBackupDays := 14;
  C.BackupKeep := 12;
  C.RestoreOnDamage := True;

  C.MySQLEnabled := False;
  C.MySQLEngine := MYSQL_LOCAL;
  C.MySQLEngineGiven := False;
  C.MySQLSyncSeconds := 3;
  C.MySQLHost := '127.0.0.1';
  C.MySQLPort := 3306;
  C.MySQLDatabase := 'soldat_stats';
  C.MySQLUser := 'zitrostats';
  C.MySQLPassword := '';
  C.MySQLServerID := 1;
  C.MySQLMirrorSeconds := 60;
  C.MySQLFullJson := False;
  C.MySQLShareProfiles := False;
  C.MySQLShareRankings := False;
  C.MySQLShareMaps := False;
  C.MySQLShareWeapons := False;
  C.MySQLShareServer := False;

  C.StartingPoints := 1000;
  C.MaxPointGive := 45;
  C.MinimumPointDivider := 1;
  C.Divider := 10;
  C.PowerDivider := 1000;
  C.MinPointGive := 1;
  C.MinimumPoints := 0;
  C.TopDisplayLinesCount := 15;
  C.RankingSystem := 'elo';
  C.TierBy := 'points';
  C.RankingFamily := 'auto';
  C.RatingMode := 'skill';
  C.SelfkillMode := 'zerosum';
  C.SelfkillPenalty := 2;
  C.SelfkillAssistShare := 50;
  C.TeamkillPenalty := 0;
  C.MinHumansForStats := 2;
  C.ColHeader := DEF_CLR_HEADER;
  C.ColSubHeader := DEF_CLR_SUBHEADER;
  C.ColCombat := DEF_CLR_COMBAT;
  C.ColShooting := DEF_CLR_SHOOTING;
  C.ColFeats := DEF_CLR_FEATS;
  C.ColObjective := DEF_CLR_OBJECTIVE;
  C.ColTeamplay := DEF_CLR_TEAMPLAY;
  C.ColMatches := DEF_CLR_MATCHES;
  C.ColActivity := DEF_CLR_ACTIVITY;
  C.ColHint := DEF_CLR_HINT;
  C.ColTop1 := DEF_CLR_TOP1;
  C.ColTop2 := DEF_CLR_TOP2;
  C.ColTop3 := DEF_CLR_TOP3;
  C.ColYou := DEF_CLR_YOU;
  C.ColOtherRow := DEF_CLR_OTHER_ROW;
  C.ColBad := DEF_CLR_BAD;
  C.ColGood := DEF_CLR_GOOD;
  C.ColWarn := DEF_CLR_WARN;
  C.ColRankLine := DEF_CLR_RANK_LINE;
  C.TeamSwitchCountSeconds := 5;
  C.SelfkillPercentBase := 'all';
  C.MinHumansForSurvival := 2;
  C.MinTeamPerSide := 0;
  C.MinFFAHumans := 0;

  C.InactivityMode := 'protection';
  C.InactivityDays := 14;
  C.BalanceHour := 4;
  C.BalanceMinAccounts := 100;
  C.BalanceMinRecipients := 15;
  C.BalanceFloorPoints := 1000;
  C.BalanceRecipientMaxPoints := 2500;
  C.BalanceMaxPayout := 225;
  C.CheckPointsEnabled := True;
  C.CheckPointsActiveDays := 90;
  C.CheckPointsMaxWaitDays := 14;
  C.ProtectSessionSeconds := 90;
  C.ProtectEventsPerDay := 10;
  C.ProtectMaxDays := 60;
  C.DecayHideAfterDays := 60;

  C.MmrStart := 1500;
  C.MmrK := 24;
  C.MmrPlacementGames := 10;
  C.GlickoTau := 0.5;
  C.GlickoRating := 1500;
  C.GlickoRD := 350;
  C.GlickoVolatility := 0.06;
  C.GlickoConservative := 2.0;
  C.OSMu := 25.0;
  C.OSSigma := 25.0 / 3.0;
  C.OSBeta := 25.0 / 6.0;
  C.OSKappa := 0.0001;

  C.InactiveVictimSeconds := 20;
  SetLength(C.InactiveVictimMultipliers, 4);
  C.InactiveVictimMultipliers[0] := 100;
  C.InactiveVictimMultipliers[1] := 50;
  C.InactiveVictimMultipliers[2] := 25;
  C.InactiveVictimMultipliers[3] := 0;
  C.SuspiciousEnabled := True;
  C.SuspiciousMaxHumans := 4;
  C.SuspiciousKills := 10;
  C.SuspiciousWindowMinutes := 10;
  C.SuspiciousVictimMaxKills := 1;
  C.SuspiciousNotifyAdmins := True;
  C.SuspiciousSharedDevices := True;
  C.SuspiciousOutliers := True;

  C.CountAbortedMatches := False;
  C.MinParticipationPercent := 40;
  C.MinParticipationSeconds := 60;
  C.LeaverCountsAsLoss := True;
  C.LeaverMinProgressPercent := 50;

  C.CapPoolPoints := 13;
  C.CapWinnerSharePct := 60;
  C.FlagScoreFallbackPoints := 25;

  C.VisitCooldownMinutes := 15;
  C.SaviorSeconds := 3;
  C.AvengerSeconds := 2;
  C.AssistSeconds := 7;
  C.AssistMinDamagePercent := 65;
  C.MultiKillWindowSeconds := 3.5;
  C.SpawnKillSeconds := 3;
  C.CampSeconds := 12;
  C.CampRadius := 80;
  C.BinkDamage := 35;
  C.BinkSeconds := 1.0;
  C.FinisherSeconds := 3;
  C.EscortRadius := 350;
  C.JuggleSeconds := 1.5;
  C.ContestedHoldSeconds := 5;
  C.HeightAdvantagePixels := 60;
  C.MaxHealth := 150;
  C.MaxHealthRealistic := 65;
  C.BaseRadiusMeters := 30;
  C.LastStandMinPlayers := 3;

  C.SteamAuthWaitSeconds := 8;
  C.NameHistoryLimit := 30;
  C.DuplicateHWID := 'allow';
  C.DuplicateIP := 'allow';
  C.DuplicateSteam := 'allow';
  C.MinPasswordLength := 6;
  C.MaxPasswordLength := 20;
  C.PasswordIterations := 100000;
  C.TrustedDeviceDays := 30;
  C.TrustDeviceSameIP := True;
  C.LoginMaxAttempts := 5;
  C.LoginLockMinutes := 15;
  C.LoginMaxAttemptsAccount := 20;
  C.UnauthenticatedAction := 'none';
  C.LoginGraceSeconds := 60;
  C.LoginReturnToGame := True;
  C.TrustedDevicesEnabled := True;
  C.AllowTrustChoice := True;
  C.AllowPasswordRemoval := False;
  C.LoginReminderSeconds := 30;

  C.MailEnabled := False;
  C.MailMethod := 'curl';
  C.MailCurlPath := 'curl';
  C.MailSmtpUrl := 'smtps://smtp.example.com:465';
  C.MailSmtpUser := '';
  C.MailSmtpPassword := '';
  C.MailFrom := '';
  C.MailFromName := 'ZitroStats';
  C.MailSendmailPath := '/usr/sbin/sendmail';
  C.MailCommand := '';
  C.MailCodeMinutes := 15;
  C.MailMinIntervalMinutes := 10;
  C.MailMaxPerDay := 3;
  C.MailMaxPerDayServer := 50;
  C.MailMaxPerDaySource := 5;
  C.MailTimeoutSeconds := 30;
  C.MailServerName := 'Soldat server';

  C.AdminConfirmPassword := '';
  C.AdminConfirmSeconds := 30;
  C.AdminConfirmLockMinutes := 30;
  C.AdminAuditLog := True;

  C.WelcomeEnabled := True;
  C.WelcomeBroadcast := False;
  C.InfoBroadcastSeconds := 450;
  C.InfoBroadcastText := 'Enter !zitro to see statistics commands. Information: !contact';
  C.ContactText := 'Contact the server administrator on the community forum.';
  C.AchievementBroadcast := True;
  C.RoundWinBroadcast := True;
  C.SeasonBroadcast := True;
  C.HudLayer := 12;
  C.HudX := 20;
  C.HudY := 436;
  C.HudScale := 0.02;
  C.HudColor := $F15D70;
  C.HudRefreshSeconds := 3;
  C.HudEventSeconds := 2;
  C.HudEnabled := True;
  C.HudDefaultOn := False;

  C.SpreesEnabled := True;
  DefaultSpreeLevels(C);
  C.SpreeShutStyle := SPREE_CHAT;
  C.SpreeShutText := '%s ended the killing spree of %s (%d kills)';
  C.SpreeColor := $FF4500;
  C.SpreeBigSeconds := 3;
  C.SpreeBigScale := 0.1;
  C.SpreeBigY := 130;

  C.HeavyCooldownSeconds := 5;
  C.SearchCooldownSeconds := 2;
  C.CommandsPerSecond := 2;
  C.MinSamplePercent := 100;

  C.LastFightEnabled := True;
  C.LastFightSummary := True;
  C.LastFightBeforeSeconds := 10;
  C.LastFightAfterSeconds := 4;

  C.SeasonsEnabled := True;
  C.SeasonLength := 'monthly';
  C.SeasonDays := 30;
  C.SeasonArchiveTop := 50;
  C.SeasonMinMinutes := 30;
  C.SeasonPointsReset := 'none';
  C.SeasonSoftFactor := 0.5;
  C.AchievementsEnabled := True;

  C.JSONExportEnabled := True;
  C.JSONExportPath := 'nickreg/stats.json';
  C.JSONExportTopCount := 50;
  C.FullExportEnabled := False;
  C.FullExportPath := 'nickreg/players.json';
  C.ExportIntervalMinutes := 5;
  C.WebhookEnabled := False;
  C.WebhookUrl := '';
  C.WebhookEvents := 'season,record';
  C.WebhookFormat := 'json';

  C.BalanceEnabled := False;
  C.BalanceMethod := 'blend';
  C.BalanceSkill := 'mmr';
  C.BalanceMinPlayers := 4;
  C.BalanceAssignJoins := True;
  C.BalanceJoinTolerance := 3;
  C.BalanceJoinReviewSeconds := 15;
  C.BalanceThreshold := 60;
  C.BalanceTarget := 55;
  C.BalanceMinGain := 4;
  C.BalanceSustainSeconds := 45;
  C.BalanceCheckSeconds := 5;
  C.BalanceCooldownSeconds := 90;
  C.BalanceMaxMovesPerMap := 6;
  C.BalanceMaxCountDiff := 1;
  C.BalanceLeaveGraceSeconds := 20;
  C.BalanceMinTimeLeftSeconds := 90;
  C.BalanceMoveOnDeath := True;
  C.BalancePendingMaxSeconds := 20;
  C.BalanceProtectTop := True;
  C.BalanceLockMinutes := 3;
  C.BalanceImmunityMinutes := 15;
  C.BalanceRejoinMemoryMinutes := 10;
  C.BalanceSizeImpact := 1.5;
  C.BalanceSkillPerDouble := 400;
  C.BalanceUncertaintyGames := 5;
  C.BalanceFormWeight := 1;
  C.BalanceFormFullMinutes := 10;
  C.BalanceFormStep := 24;
  C.BalanceMapWarmupMinutes := 3;
  C.BalanceUseMapBias := True;
  C.BalanceMapStart := 'fix';
  C.BalanceMapStartSeconds := 2;
  C.BalanceVolunteers := True;
  C.BalanceVolunteerSeconds := 15;
  C.BalanceAfkSeconds := 60;
  C.BalanceAfkFactor := 0.3;
  C.BalanceBotSkill := 30;
  C.BalanceCountBots := True;
  C.BalanceTeammatchTeams := 0;
  C.BalanceExclude := '';
  C.BalanceAutoTune := False;
  C.BalanceAnnounce := True;

  C.IntegrityEnabled := True;
  C.IntegrityFixJoinScore := True;
  C.IntegrityVoidDoubleCaptures := True;
  C.IntegrityMinOpponents := 1;
  C.IntegrityRespawnAfterMapChange := True;
  C.IntegrityProtectMapChange := True;
  C.IntegrityAnnounce := True;

  C.MatrixEnabled := True;
  C.MatrixPruneDays := 90;
  C.MatrixMapPruneDays := 0;
  C.MatrixPlayerHeatmap := True;
  C.MatrixMaxRivals := 200;

  C.MapVoteEnabled := True;
  C.MapVotePercent := 60;
  C.MapVoteSeconds := 20;
  C.MapVoteStarterCooldown := 45;
  C.MapVoteGapSeconds := 60;
  C.MapVoteMinTimeLeft := 26;
  C.MapVoteBlockAfterChange := 20;
  C.MapVoteMinPlayers := 1;
  C.MapVoteCountSpectators := True;
  C.MapVoteAllowAnyMap := True;
  C.MapVoteFilterByStyle := False;
  C.MapVoteMapsFolder := '';
  C.MapVoteRescanMinutes := 5;
  C.MapVoteRestorePercent := 60;
  C.MapVoteCommands := MVC_ALL;

  C.LeaguesEnabled := False;
  C.LeagueSource := 'mmr';
  C.DebugRayCast := False;
  C.BridgeHook := True;
  C.BridgeMemory := True;
  C.BridgeGeometry := True;
  C.LeagueDivisions := 5;
  C.LeaguePlacementMatches := 10;
  C.LeaguePercents := '2,8,20,40,65,85';

  C.RankTierCount := 0;
  AddTier(C, 'Grand Master', 2200, 75.0, 2100, 35, 2100, $FFD700);
  AddTier(C, 'Master', 1800, 60.0, 1900, 30, 1900, $E040FB);
  AddTier(C, 'Diamond', 1500, 48.0, 1750, 25, 1750, $00E5FF);
  AddTier(C, 'Platinum', 1300, 38.0, 1600, 20, 1600, $00E676);
  AddTier(C, 'Gold', 1150, 28.0, 1500, 15, 1500, $FFEA00);
  AddTier(C, 'Silver', 1000, 18.0, 1350, 8, 1350, $CFD8DC);
  AddTier(C, 'Bronze', 0, 0.0, -100000, -100000, -100000, $CD7F32);
end;

function IsTrue(const V: AnsiString): Boolean;
var
  L: AnsiString;
begin
  L := LowerCase(Trim(V));
  Result := (L = '1') or (L = 'true') or (L = 'yes') or (L = 'on');
end;

function IsFalse(const V: AnsiString): Boolean;
var
  L: AnsiString;
begin
  L := LowerCase(Trim(V));
  Result := (L = '0') or (L = 'false') or (L = 'no') or (L = 'off');
end;

function FloatDef(const V: AnsiString; Def: Double): Double;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(StringReplace(V, ',', '.', [])), Def, FS);
end;

var
  Pal: array[0..18] of LongInt;

function CLR_HEADER: LongInt;
begin
  Result := Pal[0];
end;

function CLR_SUBHEADER: LongInt;
begin
  Result := Pal[1];
end;

function CLR_COMBAT: LongInt;
begin
  Result := Pal[2];
end;

function CLR_SHOOTING: LongInt;
begin
  Result := Pal[3];
end;

function CLR_FEATS: LongInt;
begin
  Result := Pal[4];
end;

function CLR_OBJECTIVE: LongInt;
begin
  Result := Pal[5];
end;

function CLR_TEAMPLAY: LongInt;
begin
  Result := Pal[6];
end;

function CLR_MATCHES: LongInt;
begin
  Result := Pal[7];
end;

function CLR_ACTIVITY: LongInt;
begin
  Result := Pal[8];
end;

function CLR_HINT: LongInt;
begin
  Result := Pal[9];
end;

function CLR_TOP1: LongInt;
begin
  Result := Pal[10];
end;

function CLR_TOP2: LongInt;
begin
  Result := Pal[11];
end;

function CLR_TOP3: LongInt;
begin
  Result := Pal[12];
end;

function CLR_YOU: LongInt;
begin
  Result := Pal[13];
end;

function CLR_OTHER_ROW: LongInt;
begin
  Result := Pal[14];
end;

function CLR_BAD: LongInt;
begin
  Result := Pal[15];
end;

function CLR_GOOD: LongInt;
begin
  Result := Pal[16];
end;

function CLR_WARN: LongInt;
begin
  Result := Pal[17];
end;

function CLR_RANK_LINE: LongInt;
begin
  Result := Pal[18];
end;

procedure ApplyPalette(const C: TZSConfig);
begin
  Pal[0] := C.ColHeader;
  Pal[1] := C.ColSubHeader;
  Pal[2] := C.ColCombat;
  Pal[3] := C.ColShooting;
  Pal[4] := C.ColFeats;
  Pal[5] := C.ColObjective;
  Pal[6] := C.ColTeamplay;
  Pal[7] := C.ColMatches;
  Pal[8] := C.ColActivity;
  Pal[9] := C.ColHint;
  Pal[10] := C.ColTop1;
  Pal[11] := C.ColTop2;
  Pal[12] := C.ColTop3;
  Pal[13] := C.ColYou;
  Pal[14] := C.ColOtherRow;
  Pal[15] := C.ColBad;
  Pal[16] := C.ColGood;
  Pal[17] := C.ColWarn;
  Pal[18] := C.ColRankLine;
end;

function LoadConfigFile(const Path: AnsiString; var C: TZSConfig; Warnings: TStrings): Boolean;
var
  L: TStringList;
  i, Eq, n, TierIdx: LongInt;
  Line, Section, Key, Val: AnsiString;
  Parts: TStringArray;
  FirstTier, SectionWarned: Boolean;
  DotFS: TFormatSettings;
  FirstSpree: Boolean;
  SpreeSeen: array[1..MAX_SPREE_LEVELS] of Boolean;
  SpreeNo: LongInt;

  procedure Warn(const Msg: AnsiString);
  begin
    if Warnings <> nil then Warnings.Add(Msg);
  end;

  function IntVal(Def, Lo, Hi: LongInt): LongInt;
  begin
    if not TryStrToInt(Trim(Val), Result) then
    begin
      Warn(Format('[%s] %s=%s is not a whole number, using %d', [Section, Key, Val, Def]));
      Result := Def;
    end;
    if (Result < Lo) or (Result > Hi) then
    begin
      Warn(Format('[%s] %s=%s is out of range %d..%d, using %d', [Section, Key, Val, Lo, Hi, EnsureRange(Result, Lo, Hi)]));
      Result := EnsureRange(Result, Lo, Hi);
    end;
  end;

  { a colour written as RRGGBB, with or without a #, a $ or a 0x in front }
  function ColVal(Def: LongInt): LongInt;
  var
    T: AnsiString;
    N: Int64;
  begin
    Result := Def;
    T := Trim(Val);
    if T = '' then
      Exit;
    if Copy(T, 1, 1) = '#' then
      Delete(T, 1, 1)
    else if LowerCase(Copy(T, 1, 2)) = '0x' then
      Delete(T, 1, 2)
    else if Copy(T, 1, 1) = '$' then
      Delete(T, 1, 1);
    if (not TryStrToInt64('$' + T, N)) or (N < 0) or (N > $FFFFFF) then
    begin
      Warn(Format('[%s] %s=%s is not a colour like RRGGBB, using the built-in one', [Section, Key, Val]));
      Exit;
    end;
    Result := LongInt(N);
  end;

  function FltVal(Def, Lo, Hi: Double): Double;
  begin
    Result := FloatDef(Val, NaN);
    if IsNan(Result) then
    begin
      Warn(Format('[%s] %s=%s is not a number, using %s', [Section, Key, Val, FloatToStr(Def, DotFS)]));
      Result := Def;
    end;
    if (Result < Lo) or (Result > Hi) then
    begin
      Warn(Format('[%s] %s=%s is out of range, using %s', [Section, Key, Val, FloatToStr(EnsureRange(Result, Lo, Hi), DotFS)]));
      Result := EnsureRange(Result, Lo, Hi);
    end;
  end;

  function BoolVal: Boolean;
  begin
    Result := IsTrue(Val);
    if not Result and not IsFalse(Val) then
      Warn(Format('[%s] %s=%s is not 1/0, true/false, yes/no or on/off, using 0', [Section, Key, Val]));
  end;

  { the code pages CpToUtf8 knows; any other number reads the names as Latin-1 }
  function CodepageVal: LongInt;
  begin
    Result := IntVal(1250, 0, 65535);
    if (Result <> 1250) and (Result <> 1252) and (Result <> 28591) and (Result <> 65001) then
      Warn(Format('[%s] %s=%d is not 1250, 1252, 28591 (Latin-1) or 65001 (UTF-8): names are read as Latin-1',
        [Section, Key, Result]));
  end;

  function OneOf(const Def: AnsiString; const Allowed: array of AnsiString): AnsiString;
  var
    k: Integer;
    V: AnsiString;
  begin
    V := LowerCase(Trim(Val));
    for k := 0 to High(Allowed) do
      if V = Allowed[k] then Exit(V);
    Warn(Format('[%s] %s=%s is not supported, using %s', [Section, Key, Val, Def]));
    Result := Def;
  end;

  { a misspelt key would otherwise leave its default active without any hint }
  procedure Unknown;
  begin
    if Section = '' then
      Warn(Format('%s is outside any section and is ignored', [Key]))
    else
      Warn(Format('[%s] %s is not a known setting and is ignored', [Section, Key]));
  end;

  { [Sprees] LevelN = <kills>, <name>, <style>, <message>: the message is the rest of the line, commas
    and all; the style and the message may be left out (both, and "<player>: <NAME>!"). The first
    level of the file replaces the built-in levels. }
  procedure SpreeLevelLine(No: LongInt);
  var
    Part: array[0..3] of AnsiString;
    L: TSpreeLevel;
    Rest: AnsiString;
    n, p, k: LongInt;
  begin
    if (No < 1) or (No > MAX_SPREE_LEVELS) then
    begin
      Warn(Format('[%s] %s: the levels are Level1 to Level%d, the line is ignored', [Section, Key, MAX_SPREE_LEVELS]));
      Exit;
    end;
    if FirstSpree then
    begin
      C.SpreeLevelCount := 0;
      FirstSpree := False;
    end;
    if SpreeSeen[No] then
    begin
      Warn(Format('[%s] %s is given twice, the first one is used', [Section, Key]));
      Exit;
    end;
    SpreeSeen[No] := True;
    Rest := Val;
    n := 0;
    while n < 3 do
    begin
      p := Pos(',', Rest);
      if p = 0 then
        Break;
      Part[n] := Trim(Copy(Rest, 1, p - 1));
      Rest := Copy(Rest, p + 1, MaxInt);
      Inc(n);
    end;
    Part[n] := Trim(Rest);
    Inc(n);
    L.Kills := StrToIntDef(Part[0], 0);
    if (L.Kills < 1) or (L.Kills > SPREE_MAX_KILLS) then
    begin
      Warn(Format('[%s] %s=%s: the kills are a number from 1 to %d, the level is left out',
        [Section, Key, Val, SPREE_MAX_KILLS]));
      Exit;
    end;
    L.Name := '';
    if n > 1 then
      L.Name := Trim(SanitizeText(Part[1], 20));
    if L.Name = '' then
    begin
      Warn(Format('[%s] %s=%s: the level has no name and is left out', [Section, Key, Val]));
      Exit;
    end;
    L.Style := SPREE_BOTH;
    if (n > 2) and (Part[2] <> '') then
    begin
      L.Style := SpreeStyleOf(Part[2]);
      if L.Style < 0 then
      begin
        Warn(Format('[%s] %s: "%s" is not off, chat, bigtext or both, using both', [Section, Key, Part[2]]));
        L.Style := SPREE_BOTH;
      end;
    end;
    if (n > 3) and (Part[3] <> '') then
      L.Text := SanitizeText(Part[3], 100)
    else
      L.Text := '%s: ' + UpperCase(L.Name) + '!';
    for k := 0 to C.SpreeLevelCount - 1 do
      if C.SpreeLevels[k].Kills = L.Kills then
      begin
        Warn(Format('[%s] %s: %s has %d kills already, the line is ignored', [Section, Key, C.SpreeLevels[k].Name,
          L.Kills]));
        Exit;
      end;
    C.SpreeLevels[C.SpreeLevelCount] := L;
    Inc(C.SpreeLevelCount);
  end;

  { [Sprees] ShutDown = <style>, <message> }
  procedure SpreeShutDownLine;
  var
    p, Style: LongInt;
    S, M: AnsiString;
  begin
    p := Pos(',', Val);
    if p > 0 then
    begin
      S := Trim(Copy(Val, 1, p - 1));
      M := Trim(Copy(Val, p + 1, MaxInt));
    end
    else
    begin
      S := Trim(Val);
      M := '';
    end;
    Style := SpreeStyleOf(S);
    if Style < 0 then
    begin
      Warn(Format('[%s] %s: "%s" is not off, chat, bigtext or both, using chat', [Section, Key, S]));
      Style := SPREE_CHAT;
    end;
    C.SpreeShutStyle := Style;
    if M <> '' then
      C.SpreeShutText := SanitizeText(M, 100);
  end;

begin
  Result := False;
  DotFS := DefaultFormatSettings;
  DotFS.DecimalSeparator := '.';
  if not FileExists(Path) then
  begin
    Warn('Configuration file not found: ' + Path + ' (defaults are used)');
    Exit;
  end;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        Warn('Cannot read ' + Path + ': ' + E.Message);
        Exit;
      end;
    end;
    Section := '';
    SectionWarned := False;
    FirstTier := True;
    FirstSpree := True;
    FillChar(SpreeSeen, SizeOf(SpreeSeen), 0);
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if (Line = '') or (Line[1] in [';', '#']) then Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        Section := LowerCase(Trim(Copy(Line, 2, Length(Line) - 2)));
        SectionWarned := False;
        Continue;
      end;
      Eq := Pos('=', Line);
      if Eq <= 0 then Continue;
      Key := LowerCase(Trim(Copy(Line, 1, Eq - 1)));
      Val := Trim(Copy(Line, Eq + 1, MaxInt));

      if Section = 'general' then
      begin
        if Key = 'datapath' then C.DataPath := Val
        else if Key = 'logpath' then C.LogPath := Val
        else if Key = 'sourcecodepage' then C.SourceCodepage := CodepageVal
        else Unknown;
      end
      else if Section = 'database' then
      begin
        if Key = 'snapshotfile' then C.SnapshotFile := Val
        else if Key = 'journalfile' then C.JournalFile := Val
        else if Key = 'backuppath' then C.BackupPath := Val
        else if (Key = 'legacyaccountsfile') or (Key = 'legacyaccountsdb') then C.LegacyAccountsDb := Val
        else if (Key = 'legacymapsfile') or (Key = 'legacymapsdb') then C.LegacyMapsDb := Val
        else if (Key = 'accountsfile') or (Key = 'legacyaccountsbin') then C.LegacyAccountsBin := Val
        else if (Key = 'mapsfile') or (Key = 'legacymapsbin') then C.LegacyMapsBin := Val
        else if Key = 'legacyserverrecords' then C.LegacyServerRecords := Val
        else if Key = 'journalflushseconds' then C.JournalFlushSeconds := IntVal(10, 1, 60)
        else if Key = 'compactintervalminutes' then C.CompactIntervalMinutes := IntVal(360, 10, 10080)
        else if Key = 'compactjournalmb' then C.CompactJournalMB := IntVal(32, 1, 1024)
        else if Key = 'autobackupdays' then C.AutoBackupDays := IntVal(14, 0, 365)
        else if Key = 'backupkeep' then C.BackupKeep := IntVal(12, 1, 1000)
        else if Key = 'restoreondamage' then C.RestoreOnDamage := BoolVal
        else if Key = 'type' then
        begin
          { the switch of 4.x: file or mysql }
          if (LowerCase(Val) = 'mysql') and not C.MySQLEngineGiven then
            C.MySQLEngine := MYSQL_MIRROR
          else if (LowerCase(Val) <> 'mysql') and (LowerCase(Val) <> 'file') then
            Warn(Format('[%s] %s=%s is not file or mysql and is ignored', [Section, Key, Val]));
        end
        else if Key = 'saveintervalseconds' then { legacy key, journal replaces periodic saves }
        else Unknown;
      end
      else if Section = 'mysql' then
      begin
        if Key = 'enabled' then
        begin
          { the older switch: on is the mirror, unless Engine says otherwise }
          if not C.MySQLEngineGiven then
            if BoolVal then C.MySQLEngine := MYSQL_MIRROR else C.MySQLEngine := MYSQL_LOCAL;
        end
        else if Key = 'engine' then
        begin
          { a value that is none of them leaves the older Enabled switch in charge }
          if (LowerCase(Val) = 'mirror') then C.MySQLEngine := MYSQL_MIRROR
          else if (LowerCase(Val) = 'mysql') or (LowerCase(Val) = 'shared') then C.MySQLEngine := MYSQL_SHARED
          else if (LowerCase(Val) = 'local') or (LowerCase(Val) = 'bin') or (LowerCase(Val) = 'files') then
            C.MySQLEngine := MYSQL_LOCAL
          else
          begin
            Warn(Format('[%s] %s=%s is not local, mirror or mysql and is ignored', [Section, Key, Val]));
            Continue;
          end;
          C.MySQLEngineGiven := True;
        end
        else if Key = 'syncseconds' then C.MySQLSyncSeconds := IntVal(3, 1, 60)
        else if Key = 'host' then C.MySQLHost := Val
        else if Key = 'port' then C.MySQLPort := IntVal(3306, 1, 65535)
        else if Key = 'database' then C.MySQLDatabase := Val
        else if Key = 'user' then C.MySQLUser := Val
        else if Key = 'password' then C.MySQLPassword := Val
        else if Key = 'serverid' then C.MySQLServerID := IntVal(1, 1, 65535)
        else if Key = 'mirrorintervalseconds' then C.MySQLMirrorSeconds := IntVal(60, 5, 3600)
        else if Key = 'fulljson' then C.MySQLFullJson := BoolVal
        else if (Key = 'sharedprofiles') or (Key = 'sharedstats') then C.MySQLShareProfiles := BoolVal
        else if Key = 'sharedrankings' then C.MySQLShareRankings := BoolVal
        else if Key = 'sharedmaps' then C.MySQLShareMaps := BoolVal
        else if Key = 'sharedweapons' then C.MySQLShareWeapons := BoolVal
        else if Key = 'sharedserver' then C.MySQLShareServer := BoolVal
        else Unknown;
      end
      else if Section = 'colors' then
      begin
        if Key = 'colorheader' then C.ColHeader := ColVal(DEF_CLR_HEADER)
        else if Key = 'colorsubheader' then C.ColSubHeader := ColVal(DEF_CLR_SUBHEADER)
        else if Key = 'colorcombat' then C.ColCombat := ColVal(DEF_CLR_COMBAT)
        else if Key = 'colorshooting' then C.ColShooting := ColVal(DEF_CLR_SHOOTING)
        else if Key = 'colorfeats' then C.ColFeats := ColVal(DEF_CLR_FEATS)
        else if Key = 'colorobjective' then C.ColObjective := ColVal(DEF_CLR_OBJECTIVE)
        else if Key = 'colorteamplay' then C.ColTeamplay := ColVal(DEF_CLR_TEAMPLAY)
        else if Key = 'colormatches' then C.ColMatches := ColVal(DEF_CLR_MATCHES)
        else if Key = 'coloractivity' then C.ColActivity := ColVal(DEF_CLR_ACTIVITY)
        else if Key = 'colorhint' then C.ColHint := ColVal(DEF_CLR_HINT)
        else if Key = 'colortop1' then C.ColTop1 := ColVal(DEF_CLR_TOP1)
        else if Key = 'colortop2' then C.ColTop2 := ColVal(DEF_CLR_TOP2)
        else if Key = 'colortop3' then C.ColTop3 := ColVal(DEF_CLR_TOP3)
        else if Key = 'coloryou' then C.ColYou := ColVal(DEF_CLR_YOU)
        else if Key = 'colorotherrow' then C.ColOtherRow := ColVal(DEF_CLR_OTHER_ROW)
        else if Key = 'colorbad' then C.ColBad := ColVal(DEF_CLR_BAD)
        else if Key = 'colorgood' then C.ColGood := ColVal(DEF_CLR_GOOD)
        else if Key = 'colorwarn' then C.ColWarn := ColVal(DEF_CLR_WARN)
        else if Key = 'colorrankline' then C.ColRankLine := ColVal(DEF_CLR_RANK_LINE)
        else Unknown;
      end
      else if Section = 'debug' then
      begin
        if Key = 'raycastlog' then C.DebugRayCast := BoolVal
        else Unknown;
      end
      else if Section = 'bridges' then
      begin
        if Key = 'serverhook' then C.BridgeHook := BoolVal
        else if Key = 'memoryreads' then C.BridgeMemory := BoolVal
        else if Key = 'mapgeometry' then C.BridgeGeometry := BoolVal
        else Unknown;
      end
      else if Section = 'mmr' then
      begin
        if Key = 'start' then C.MmrStart := FltVal(1500, 100, 10000)
        else if Key = 'step' then C.MmrK := FltVal(24, 1, 200)
        else if Key = 'placementmatches' then C.MmrPlacementGames := IntVal(10, 0, 100)
        else Unknown;
      end
      else if Section = 'balance' then
      begin
        if Key = 'enabled' then C.BalanceEnabled := BoolVal
        else if Key = 'method' then C.BalanceMethod := OneOf('blend', ['blend', 'global', 'map'])
        else if Key = 'skill' then C.BalanceSkill := OneOf('mmr', ['mmr', 'glicko2', 'openskill', 'points'])
        else if Key = 'minplayers' then C.BalanceMinPlayers := IntVal(4, 2, 32)
        else if Key = 'assignjoins' then C.BalanceAssignJoins := BoolVal
        else if Key = 'jointolerance' then C.BalanceJoinTolerance := FltVal(3, 0, 50)
        else if Key = 'joinreviewseconds' then C.BalanceJoinReviewSeconds := IntVal(15, 0, 120)
        else if Key = 'threshold' then C.BalanceThreshold := FltVal(60, 51, 95)
        else if Key = 'target' then C.BalanceTarget := FltVal(55, 50, 90)
        else if Key = 'mingain' then C.BalanceMinGain := FltVal(4, 0, 50)
        else if Key = 'sustainseconds' then C.BalanceSustainSeconds := IntVal(45, 0, 3600)
        else if Key = 'checkseconds' then C.BalanceCheckSeconds := IntVal(5, 1, 600)
        else if Key = 'cooldownseconds' then C.BalanceCooldownSeconds := IntVal(90, 0, 3600)
        else if Key = 'maxmovespermap' then C.BalanceMaxMovesPerMap := IntVal(6, 0, 100)
        else if Key = 'maxcountdiff' then C.BalanceMaxCountDiff := IntVal(1, 1, 8)
        else if Key = 'leavegraceseconds' then C.BalanceLeaveGraceSeconds := IntVal(20, 0, 600)
        else if Key = 'mintimeleftseconds' then C.BalanceMinTimeLeftSeconds := IntVal(90, 0, 3600)
        else if Key = 'moveondeath' then C.BalanceMoveOnDeath := BoolVal
        else if Key = 'pendingmaxseconds' then C.BalancePendingMaxSeconds := IntVal(20, 0, 600)
        else if Key = 'protecttop' then C.BalanceProtectTop := BoolVal
        else if Key = 'lockminutes' then C.BalanceLockMinutes := FltVal(3, 0, 120)
        else if Key = 'immunityminutes' then C.BalanceImmunityMinutes := FltVal(15, 0, 600)
        else if Key = 'rejoinmemoryminutes' then C.BalanceRejoinMemoryMinutes := FltVal(10, 0, 600)
        else if Key = 'sizeimpact' then C.BalanceSizeImpact := FltVal(1.5, 0.5, 4)
        else if Key = 'skillperdouble' then C.BalanceSkillPerDouble := FltVal(400, 50, 5000)
        else if Key = 'uncertaintygames' then C.BalanceUncertaintyGames := IntVal(5, 0, 1000)
        else if Key = 'formweight' then C.BalanceFormWeight := FltVal(1, 0, 5)
        else if Key = 'formfullminutes' then C.BalanceFormFullMinutes := FltVal(10, 0, 120)
        else if Key = 'formstep' then C.BalanceFormStep := FltVal(24, 1, 200)
        else if Key = 'mapwarmupminutes' then C.BalanceMapWarmupMinutes := FltVal(3, 0, 60)
        else if Key = 'usemapbias' then C.BalanceUseMapBias := BoolVal
        else if Key = 'mapstart' then C.BalanceMapStart := OneOf('fix', ['keep', 'fix', 'shuffle', 'mix'])
        else if Key = 'mapstartseconds' then C.BalanceMapStartSeconds := IntVal(2, 0, 60)
        else if Key = 'volunteers' then C.BalanceVolunteers := BoolVal
        else if Key = 'volunteerseconds' then C.BalanceVolunteerSeconds := IntVal(15, 1, 120)
        else if Key = 'afkseconds' then C.BalanceAfkSeconds := IntVal(60, 10, 3600)
        else if Key = 'afkfactor' then C.BalanceAfkFactor := FltVal(0.3, 0, 1)
        else if Key = 'botskill' then C.BalanceBotSkill := IntVal(30, 0, 100)
        else if Key = 'countbots' then C.BalanceCountBots := BoolVal
        else if Key = 'teammatchteams' then
        begin
          if SameText(Trim(Val), 'auto') then
            C.BalanceTeammatchTeams := 0
          else
            C.BalanceTeammatchTeams := IntVal(0, 0, 4);
        end
        else if Key = 'exclude' then C.BalanceExclude := Val
        else if Key = 'autotune' then C.BalanceAutoTune := BoolVal
        else if Key = 'announce' then C.BalanceAnnounce := BoolVal
        else Unknown;
      end
      else if Section = 'integrity' then
      begin
        if Key = 'enabled' then C.IntegrityEnabled := BoolVal
        else if Key = 'fixjoinscore' then C.IntegrityFixJoinScore := BoolVal
        else if Key = 'voiddoublecaptures' then C.IntegrityVoidDoubleCaptures := BoolVal
        else if Key = 'minopponents' then C.IntegrityMinOpponents := IntVal(1, 0, 16)
        else if Key = 'respawnaftermapchange' then C.IntegrityRespawnAfterMapChange := BoolVal
        else if Key = 'protectmapchange' then C.IntegrityProtectMapChange := BoolVal
        else if Key = 'announce' then C.IntegrityAnnounce := BoolVal
        else Unknown;
      end
      else if Section = 'matrix' then
      begin
        if Key = 'enabled' then C.MatrixEnabled := BoolVal
        else if Key = 'matrixprunedays' then C.MatrixPruneDays := IntVal(90, 0, 3650)
        else if Key = 'matrixmapprunedays' then C.MatrixMapPruneDays := IntVal(0, 0, 3650)
        else if Key = 'playerheatmap' then C.MatrixPlayerHeatmap := BoolVal
        else if Key = 'maxrivals' then C.MatrixMaxRivals := IntVal(200, 1, 10000)
        else Unknown;
      end
      else if Section = 'mapvote' then
      begin
        if Key = 'enabled' then C.MapVoteEnabled := BoolVal
        else if Key = 'votepercent' then C.MapVotePercent := IntVal(60, 1, 100)
        else if Key = 'voteseconds' then C.MapVoteSeconds := IntVal(20, 5, 120)
        else if Key = 'startercooldownseconds' then C.MapVoteStarterCooldown := IntVal(45, 0, 3600)
        else if Key = 'gapseconds' then C.MapVoteGapSeconds := IntVal(60, 0, 3600)
        else if Key = 'mintimeleftseconds' then C.MapVoteMinTimeLeft := IntVal(26, 0, 3600)
        else if Key = 'blockafterchangeseconds' then C.MapVoteBlockAfterChange := IntVal(20, 0, 600)
        else if Key = 'minplayers' then C.MapVoteMinPlayers := IntVal(1, 1, 32)
        else if Key = 'countspectators' then C.MapVoteCountSpectators := BoolVal
        else if Key = 'allowanymap' then C.MapVoteAllowAnyMap := BoolVal
        else if Key = 'filterbygamestyle' then C.MapVoteFilterByStyle := BoolVal
        else if Key = 'mapsfolder' then C.MapVoteMapsFolder := Val
        else if Key = 'rescanminutes' then C.MapVoteRescanMinutes := IntVal(5, 0, 1440)
        else if Key = 'restorevotepercent' then C.MapVoteRestorePercent := IntVal(60, 0, 100)
        else
        begin
          { VoteCommand = 1 ... SearchMapCommand = 1: one switch per command }
          n := MapVoteCommandSwitch(Key);
          if n = 0 then
            Unknown
          else if BoolVal then
            C.MapVoteCommands := C.MapVoteCommands or n
          else
            C.MapVoteCommands := C.MapVoteCommands and not n;
        end;
      end
      else if Section = 'leagues' then
      begin
        if Key = 'enabled' then C.LeaguesEnabled := BoolVal
        else if Key = 'divisions' then C.LeagueDivisions := IntVal(5, 1, 20)
        else if Key = 'placementmatches' then C.LeaguePlacementMatches := IntVal(10, 0, 1000)
        else if Key = 'percents' then C.LeaguePercents := Val
        else if Key = 'source' then C.LeagueSource := OneOf('mmr', ['mmr', 'rating'])
        else Unknown;
      end
      else if Section = 'ranking' then
      begin
        if Key = 'startingpoints' then C.StartingPoints := IntVal(1000, 0, 1000000)
        else if Key = 'maxpointgive' then C.MaxPointGive := IntVal(45, 1, 10000)
        else if Key = 'minimumpointdivider' then C.MinimumPointDivider := IntVal(1, 0, 1000)
        else if Key = 'divider' then C.Divider := IntVal(10, 2, 1000)
        else if Key = 'powerdivider' then C.PowerDivider := IntVal(1000, 1, 1000000)
        else if Key = 'minpointgive' then C.MinPointGive := IntVal(1, 0, 1000)
        else if Key = 'minimumpoints' then C.MinimumPoints := IntVal(0, 0, 1000000)
        else if Key = 'topdisplaylinescount' then C.TopDisplayLinesCount := IntVal(15, 5, 30)
        else if Key = 'rankingsystem' then C.RankingSystem := OneOf('elo', ['elo', 'mmr', 'glicko2', 'openskill'])
        else if Key = 'rankingfamily' then C.RankingFamily := OneOf('auto', ['auto', 'ffa', 'team', 'ctf'])
        else if Key = 'ratingmode' then C.RatingMode := OneOf('skill', ['skill', 'gamemode', 'unified'])
        else if Key = 'tierby' then
          C.TierBy := OneOf('points', ['points', 'rating', 'mmr', 'glicko2', 'openskill', 'both', 'all'])
        else if Key = 'selfkillmode' then C.SelfkillMode := OneOf('zerosum', ['penalty', 'zerosum'])
        else if Key = 'selfkillpenalty' then C.SelfkillPenalty := IntVal(2, 0, 1000)
        else if Key = 'selfkillassistshare' then C.SelfkillAssistShare := IntVal(50, 0, 100)
        else if Key = 'teamkillpenalty' then C.TeamkillPenalty := IntVal(0, 0, 1000)
        else if Key = 'minhumansforstats' then C.MinHumansForStats := IntVal(2, 1, 32)
        else if Key = 'teamswitchcountseconds' then C.TeamSwitchCountSeconds := IntVal(5, 0, 600)
        else if Key = 'selfkillpercentbase' then C.SelfkillPercentBase := OneOf('all', ['all', 'enemy'])
        else if Key = 'minhumansforsurvival' then C.MinHumansForSurvival := IntVal(2, 1, 32)
        else if Key = 'minteamperside' then C.MinTeamPerSide := IntVal(0, 0, 16)
        else if Key = 'minffahumans' then C.MinFFAHumans := IntVal(0, 0, 32)
        else if Key = 'inactivitydays' then C.InactivityDays := IntVal(14, 1, 3650)
        else if Key = 'balancepointsactive' then begin if not BoolVal then C.InactivityMode := 'none'; end
        else if Key = 'balancepointswhencount' then C.BalanceMinAccounts := IntVal(100, 0, 10000000)
        else Unknown;
      end
      else if Section = 'inactivity' then
      begin
        if Key = 'mode' then C.InactivityMode := OneOf('protection', ['protection', 'decay', 'none'])
        else if Key = 'inactivitydays' then C.InactivityDays := IntVal(14, 1, 3650)
        else if Key = 'balancehour' then C.BalanceHour := IntVal(4, 0, 23)
        else if Key = 'balanceminaccounts' then C.BalanceMinAccounts := IntVal(100, 0, 10000000)
        else if Key = 'balanceminrecipients' then C.BalanceMinRecipients := IntVal(15, 1, 1000000)
        else if Key = 'balancefloorpoints' then C.BalanceFloorPoints := IntVal(1000, 0, 1000000)
        else if Key = 'balancerecipientmaxpoints' then C.BalanceRecipientMaxPoints := IntVal(2500, 0, 10000000)
        else if Key = 'balancemaxpayout' then C.BalanceMaxPayout := IntVal(225, 1, 100000)
        else if Key = 'checkpointsenabled' then C.CheckPointsEnabled := BoolVal
        else if Key = 'checkpointsactivedays' then C.CheckPointsActiveDays := IntVal(90, 1, 3650)
        else if Key = 'checkpointsmaxwaitdays' then C.CheckPointsMaxWaitDays := IntVal(14, 0, 3650)
        else if Key = 'protectsessionseconds' then C.ProtectSessionSeconds := IntVal(90, 0, 86400)
        else if Key = 'protecteventsperday' then C.ProtectEventsPerDay := IntVal(10, 1, 1000)
        else if Key = 'protectmaxdays' then C.ProtectMaxDays := IntVal(60, 1, 3650)
        else if Key = 'decayhideafterdays' then C.DecayHideAfterDays := IntVal(60, 0, 3650)
        else Unknown;
      end
      else if Section = 'glicko2' then
      begin
        if Key = 'tau' then C.GlickoTau := FltVal(0.5, 0.2, 1.2)
        else if Key = 'initialrating' then C.GlickoRating := FltVal(1500, 0, 10000)
        else if Key = 'initialrd' then C.GlickoRD := FltVal(350, 30, 500)
        else if Key = 'initialvolatility' then C.GlickoVolatility := FltVal(0.06, 0.001, 0.5)
        else if Key = 'conservativefactor' then C.GlickoConservative := FltVal(2, 0, 3)
        else Unknown;
      end
      else if Section = 'openskill' then
      begin
        if Key = 'mu' then C.OSMu := FltVal(25, 1, 1000)
        else if Key = 'sigma' then C.OSSigma := FltVal(25 / 3, 0.1, 500)
        else if Key = 'beta' then C.OSBeta := FltVal(25 / 6, 0.1, 500)
        else if Key = 'kappa' then C.OSKappa := FltVal(0.0001, 0.0000001, 0.1)
        else Unknown;
      end
      else if Section = 'antifarm' then
      begin
        if Key = 'inactivevictimseconds' then C.InactiveVictimSeconds := IntVal(20, 0, 3600)
        else if Key = 'inactivevictimmultipliers' then
        begin
          Parts := SplitWords(StringReplace(Val, ',', ' ', [rfReplaceAll]));
          if Length(Parts) > 0 then
          begin
            SetLength(C.InactiveVictimMultipliers, Length(Parts));
            for n := 0 to High(Parts) do
              C.InactiveVictimMultipliers[n] := EnsureRange(StrToIntDef(Parts[n], 100), 0, 100);
          end;
        end
        else if Key = 'suspiciousenabled' then C.SuspiciousEnabled := BoolVal
        else if Key = 'suspiciousmaxhumans' then C.SuspiciousMaxHumans := IntVal(4, 2, 32)
        else if Key = 'suspiciouskills' then C.SuspiciousKills := IntVal(10, 2, 1000)
        else if Key = 'suspiciouswindowminutes' then C.SuspiciousWindowMinutes := IntVal(10, 1, 1440)
        else if Key = 'suspiciousvictimmaxkills' then C.SuspiciousVictimMaxKills := IntVal(1, 0, 1000)
        else if Key = 'notifyadmins' then C.SuspiciousNotifyAdmins := BoolVal
        else if Key = 'shareddevices' then C.SuspiciousSharedDevices := BoolVal
        else if Key = 'outliers' then C.SuspiciousOutliers := BoolVal
        else Unknown;
      end
      else if Section = 'matches' then
      begin
        if Key = 'countabortedmatches' then C.CountAbortedMatches := BoolVal
        else if Key = 'minparticipationpercent' then C.MinParticipationPercent := IntVal(40, 0, 100)
        else if Key = 'minparticipationseconds' then C.MinParticipationSeconds := IntVal(60, 0, 36000)
        else if Key = 'leavercountsasloss' then C.LeaverCountsAsLoss := BoolVal
        else if Key = 'leaverminprogresspercent' then C.LeaverMinProgressPercent := IntVal(50, 0, 100)
        else Unknown;
      end
      else if Section = 'capturetheflag' then
      begin
        if Key = 'cappoolpoints' then C.CapPoolPoints := IntVal(13, 0, 10000)
        else if Key = 'baseradius' then C.BaseRadiusMeters := IntVal(30, 1, 500)
        else if Key = 'capwinnersharepercent' then C.CapWinnerSharePct := IntVal(60, 0, 100)
        else if Key = 'flagscorefallbackpoints' then C.FlagScoreFallbackPoints := IntVal(25, 0, 10000)
        else if Key = 'capteamsharepercent' then { legacy key: the team gets what the capper does not }
        else Unknown;
      end
      else if (Section = 'mechanics') or (Section = 'options') then
      begin
        if Key = 'visitcooldownminutes' then C.VisitCooldownMinutes := IntVal(15, 0, 1440)
        else if (Key = 'saviortime') or (Key = 'saviorseconds') then C.SaviorSeconds := FltVal(3, 0, 60)
        else if (Key = 'avengertime') or (Key = 'avengerseconds') then C.AvengerSeconds := FltVal(2, 0, 60)
        else if (Key = 'assisttime') or (Key = 'assistseconds') then C.AssistSeconds := FltVal(7, 0, 60)
        else if (Key = 'assistminimumdamagepercent') or (Key = 'assistmindamagepercent') then C.AssistMinDamagePercent := FltVal(65, 1, 100)
        else if Key = 'multikillwindowseconds' then C.MultiKillWindowSeconds := FltVal(3.5, 0.5, 30)
        else if Key = 'spawnkillseconds' then C.SpawnKillSeconds := FltVal(3, 0, 30)
        else if Key = 'campseconds' then C.CampSeconds := IntVal(12, 1, 600)
        else if Key = 'campradius' then C.CampRadius := IntVal(80, 5, 2000)
        else if Key = 'binkdamage' then C.BinkDamage := FltVal(35, 1, 1000)
        else if Key = 'binkseconds' then C.BinkSeconds := FltVal(1, 0.1, 10)
        else if Key = 'finisherseconds' then C.FinisherSeconds := FltVal(3, 0.1, 30)
        else if Key = 'escortradius' then C.EscortRadius := IntVal(350, 10, 5000)
        else if Key = 'juggleseconds' then C.JuggleSeconds := FltVal(1.5, 0.1, 30)
        else if Key = 'contestedholdseconds' then C.ContestedHoldSeconds := FltVal(5, 1, 120)
        else if Key = 'heightadvantagepixels' then C.HeightAdvantagePixels := IntVal(60, 0, 5000)
        else if Key = 'steamauthwaitseconds' then C.SteamAuthWaitSeconds := IntVal(8, 0, 60) { [Identity] since 5.1 }
        else if Key = 'maxhealth' then C.MaxHealth := IntVal(150, 1, 10000)
        else if Key = 'maxhealthrealistic' then C.MaxHealthRealistic := IntVal(65, 0, 10000)
        else if Key = 'laststandminplayers' then C.LastStandMinPlayers := IntVal(3, 2, 32)
        else Unknown;
      end
      else if Section = 'identity' then
      begin
        if Key = 'steamauthwaitseconds' then C.SteamAuthWaitSeconds := IntVal(8, 0, 60)
        else if Key = 'namehistorylimit' then C.NameHistoryLimit := IntVal(30, 1, 1000)
        else if Key = 'duplicatehwid' then C.DuplicateHWID := OneOf('allow', ['allow', 'warn', 'kick'])
        else if Key = 'duplicateip' then C.DuplicateIP := OneOf('allow', ['allow', 'warn', 'kick'])
        else if Key = 'duplicatesteam' then C.DuplicateSteam := OneOf('allow', ['allow', 'warn', 'kick'])
        else if Key = 'kickduplicatehwid' then begin if BoolVal then C.DuplicateHWID := 'kick'; end { 5.1 key }
        else if Key = 'kickduplicateip' then begin if BoolVal then C.DuplicateIP := 'kick'; end { 5.1 key }
        else if (Key = 'automergehwidintosteam') or (Key = 'matchbynameforunregistered') or
          (Key = 'aliaslimitperkind') or (Key = 'aliasexpiredays') then { legacy keys: since 5.1 accounts follow only the SteamID or the HWID }
        else Unknown;
      end
      else if Section = 'accounts' then
      begin
        if Key = 'minpasswordlength' then C.MinPasswordLength := IntVal(6, 4, 20)
        else if Key = 'maxpasswordlength' then C.MaxPasswordLength := IntVal(20, 4, 20)
        else if Key = 'passworditerations' then C.PasswordIterations := IntVal(100000, 10000, 2000000)
        else if Key = 'trusteddevicedays' then C.TrustedDeviceDays := IntVal(30, 0, 3650)
        else if Key = 'trustdevicesameip' then C.TrustDeviceSameIP := BoolVal
        else if Key = 'loginmaxattempts' then C.LoginMaxAttempts := IntVal(5, 1, 100)
        else if Key = 'loginlockminutes' then C.LoginLockMinutes := IntVal(15, 1, 10080)
        else if Key = 'loginmaxattemptsaccount' then C.LoginMaxAttemptsAccount := IntVal(20, 1, 1000)
        else if Key = 'unauthenticatedaction' then C.UnauthenticatedAction := OneOf('none', ['none', 'spectator', 'kick'])
        else if Key = 'logingraceseconds' then C.LoginGraceSeconds := IntVal(60, 0, 3600)
        else if Key = 'loginreturntogame' then C.LoginReturnToGame := BoolVal
        else if Key = 'trusteddevices' then C.TrustedDevicesEnabled := BoolVal
        else if Key = 'allowtrustchoice' then C.AllowTrustChoice := BoolVal
        else if Key = 'allowpasswordremoval' then C.AllowPasswordRemoval := BoolVal
        else if Key = 'loginreminderseconds' then C.LoginReminderSeconds := IntVal(30, 5, 3600)
        else if Key = 'clearhwidsadminonly' then { legacy key: /clearhwids was removed in 5.1 }
        else Unknown;
      end
      else if Section = 'mail' then
      begin
        if Key = 'enabled' then C.MailEnabled := BoolVal
        else if Key = 'method' then C.MailMethod := OneOf('curl', ['curl', 'sendmail', 'command'])
        else if Key = 'curlpath' then C.MailCurlPath := Val
        else if Key = 'smtpurl' then C.MailSmtpUrl := Val
        else if Key = 'smtpuser' then C.MailSmtpUser := Val
        else if Key = 'smtppassword' then C.MailSmtpPassword := Val
        else if Key = 'fromaddress' then C.MailFrom := Val
        else if Key = 'fromname' then C.MailFromName := SanitizeText(Val, 60)
        else if Key = 'sendmailpath' then C.MailSendmailPath := Val
        else if Key = 'commandtemplate' then C.MailCommand := Val
        else if Key = 'codelifetimeminutes' then C.MailCodeMinutes := IntVal(15, 1, 1440)
        else if Key = 'minintervalminutes' then C.MailMinIntervalMinutes := IntVal(10, 0, 1440)
        else if Key = 'maxperday' then C.MailMaxPerDay := IntVal(3, 1, 100)
        else if Key = 'maxperdayserver' then C.MailMaxPerDayServer := IntVal(50, 1, 100000)
        else if Key = 'maxperdaysource' then C.MailMaxPerDaySource := IntVal(5, 1, 1000)
        else if Key = 'timeoutseconds' then C.MailTimeoutSeconds := IntVal(30, 5, 300)
        else if Key = 'servername' then C.MailServerName := SanitizeText(Val, 60)
        else Unknown;
      end
      else if Section = 'admin' then
      begin
        if Key = 'confirmpassword' then C.AdminConfirmPassword := Val
        else if Key = 'confirmseconds' then C.AdminConfirmSeconds := IntVal(30, 5, 600)
        else if Key = 'confirmlockminutes' then C.AdminConfirmLockMinutes := IntVal(30, 1, 10080)
        else if Key = 'auditlog' then C.AdminAuditLog := BoolVal
        else Unknown;
      end
      else if Section = 'messages' then
      begin
        if Key = 'welcomeenabled' then C.WelcomeEnabled := BoolVal
        else if Key = 'welcomebroadcast' then C.WelcomeBroadcast := BoolVal
        else if Key = 'infobroadcastminutes' then C.InfoBroadcastSeconds := Round(FltVal(7.5, 0, 1440) * 60)
        else if Key = 'infobroadcasttext' then C.InfoBroadcastText := SanitizeText(Val, 120)
        else if Key = 'contacttext' then C.ContactText := SanitizeText(Val, 200)
        else if Key = 'achievementbroadcast' then C.AchievementBroadcast := BoolVal
        else if Key = 'roundwinbroadcast' then C.RoundWinBroadcast := BoolVal
        else if Key = 'seasonbroadcast' then C.SeasonBroadcast := BoolVal
        else Unknown;
      end
      else if Section = 'hud' then
      begin
        if Key = 'layer' then C.HudLayer := IntVal(12, 0, 255)
        else if Key = 'x' then C.HudX := IntVal(20, 0, 4000)
        else if Key = 'y' then C.HudY := IntVal(436, 0, 4000)
        else if Key = 'scale' then C.HudScale := FltVal(0.02, 0.001, 1)
        else if Key = 'color' then C.HudColor := ParseColor(Val, $F15D70)
        else if Key = 'refreshseconds' then C.HudRefreshSeconds := IntVal(3, 1, 60)
        else if Key = 'eventseconds' then C.HudEventSeconds := IntVal(2, 1, 10)
        else if Key = 'enabled' then C.HudEnabled := BoolVal
        else if Key = 'defaulton' then C.HudDefaultOn := BoolVal
        else Unknown;
      end
      else if Section = 'sprees' then
      begin
        if Key = 'enabled' then C.SpreesEnabled := BoolVal
        else if (Copy(Key, 1, 5) = 'level') and (Length(Key) > 5) and (Length(Key) <= 8) and
          TryStrToInt(Copy(Key, 6, 3), SpreeNo) then SpreeLevelLine(SpreeNo)
        else if Key = 'shutdown' then SpreeShutDownLine
        else if Key = 'color' then C.SpreeColor := ColVal($FF4500)
        else if Key = 'bigtextseconds' then C.SpreeBigSeconds := IntVal(3, 1, 30)
        else if Key = 'bigtextscale' then C.SpreeBigScale := FltVal(0.1, 0.02, 1)
        else if Key = 'bigtexty' then C.SpreeBigY := IntVal(130, 0, 480)
        else Unknown;
      end
      else if Section = 'commands' then
      begin
        if Key = 'heavycooldownseconds' then C.HeavyCooldownSeconds := IntVal(5, 0, 600)
        else if Key = 'searchcooldownseconds' then C.SearchCooldownSeconds := IntVal(2, 0, 60)
        else if Key = 'commandspersecond' then C.CommandsPerSecond := IntVal(2, 1, 50)
        else if Key = 'minsamplepercent' then C.MinSamplePercent := IntVal(100, 0, 1000)
        else Unknown;
      end
      else if Section = 'lastfight' then
      begin
        if Key = 'enabled' then C.LastFightEnabled := BoolVal
        else if Key = 'deathsummary' then C.LastFightSummary := BoolVal
        else if Key = 'beforeseconds' then C.LastFightBeforeSeconds := IntVal(10, 3, 20)
        else if Key = 'afterseconds' then C.LastFightAfterSeconds := IntVal(4, 1, 8)
        else Unknown;
      end
      else if Section = 'seasons' then
      begin
        if Key = 'enabled' then C.SeasonsEnabled := BoolVal
        else if Key = 'length' then C.SeasonLength := OneOf('monthly', ['monthly', 'days'])
        else if Key = 'days' then C.SeasonDays := IntVal(30, 1, 3650)
        else if Key = 'archivetop' then C.SeasonArchiveTop := IntVal(50, 3, 500)
        else if Key = 'minseasonminutes' then C.SeasonMinMinutes := IntVal(30, 0, 100000)
        else if Key = 'pointsreset' then C.SeasonPointsReset := OneOf('none', ['none', 'soft', 'hard'])
        else if Key = 'softresetfactor' then C.SeasonSoftFactor := FltVal(0.5, 0, 1)
        else Unknown;
      end
      else if Section = 'achievements' then
      begin
        if Key = 'enabled' then C.AchievementsEnabled := BoolVal
        else Unknown;
      end
      else if Section = 'export' then
      begin
        if Key = 'jsonexportenabled' then C.JSONExportEnabled := BoolVal
        else if Key = 'jsonexportpath' then C.JSONExportPath := Val
        else if Key = 'jsonexporttopcount' then C.JSONExportTopCount := IntVal(50, 1, 100000)
        else if Key = 'fullexportenabled' then C.FullExportEnabled := BoolVal
        else if Key = 'fullexportpath' then C.FullExportPath := Val
        else if Key = 'exportintervalminutes' then C.ExportIntervalMinutes := IntVal(5, 1, 1440)
        else if Key = 'sourcecodepage' then C.SourceCodepage := CodepageVal
        else Unknown;
      end
      else if Section = 'webhook' then
      begin
        if Key = 'enabled' then C.WebhookEnabled := BoolVal
        else if Key = 'url' then C.WebhookUrl := Val
        else if Key = 'events' then C.WebhookEvents := LowerCase(Val)
        else if Key = 'format' then C.WebhookFormat := OneOf('json', ['json', 'discord'])
        else Unknown;
      end
      else if Section = 'protection' then
      begin
        { legacy section of v4.x }
        if Key = 'maxprotectiondays' then C.ProtectMaxDays := IntVal(60, 1, 3650)
        else if (Key = 'requiredactiveplaytimeseconds') or (Key = 'requiredactivekillsdeaths') then
          { 4.x thresholds, replaced by the lower [Inactivity] ProtectSessionSeconds and ProtectEventsPerDay }
        else Unknown;
      end
      else if Section = 'ranks' then
      begin
        if Copy(Key, 1, 4) <> 'tier' then
        begin
          Unknown;
          Continue;
        end;
        if FirstTier then
        begin
          C.RankTierCount := 0;
          FirstTier := False;
        end;
        if C.RankTierCount >= MAX_TIERS then Continue;
        Parts := Val.Split([',']);
        TierIdx := C.RankTierCount;
        C.RankTiers[TierIdx].Name := SanitizeText(Trim(Parts[0]), 24);
        if C.RankTiers[TierIdx].Name = '' then Continue;
        C.RankTiers[TierIdx].MinPoints := 0;
        { a limit the line does not give stays unset (-100000): TierBy skips such a line }
        C.RankTiers[TierIdx].MinRating := -100000;
        C.RankTiers[TierIdx].MinGlicko := -100000;
        C.RankTiers[TierIdx].MinOpenSkill := -100000;
        C.RankTiers[TierIdx].MinMmr := -100000;
        C.RankTiers[TierIdx].Color := $FFFFFF;
        if Length(Parts) > 1 then C.RankTiers[TierIdx].MinPoints := StrToIntDef(Trim(Parts[1]), 0);
        if Length(Parts) > 2 then C.RankTiers[TierIdx].MinRating := FloatDef(Parts[2], -100000);
        if Length(Parts) > 3 then C.RankTiers[TierIdx].Color := ParseColor(Parts[3], $FFFFFF);
        if Length(Parts) > 4 then C.RankTiers[TierIdx].MinGlicko := FloatDef(Parts[4], -100000);
        if Length(Parts) > 5 then C.RankTiers[TierIdx].MinOpenSkill := FloatDef(Parts[5], -100000);
        if Length(Parts) > 6 then C.RankTiers[TierIdx].MinMmr := FloatDef(Parts[6], -100000);
        Inc(C.RankTierCount);
      end
      else if Section = '' then
        Unknown
      else if not SectionWarned then
      begin
        { a misspelt section is reported once, not once for every line in it }
        Warn(Format('[%s] is not a known section, its settings are ignored', [Section]));
        SectionWarned := True;
      end;
    end;

    if C.MinPasswordLength > C.MaxPasswordLength then
    begin
      Warn('[Accounts] MinPasswordLength is larger than MaxPasswordLength, both set to the maximum');
      C.MinPasswordLength := C.MaxPasswordLength;
    end;
    { level lines that were all refused leave no level: the built-in ones come back }
    if C.SpreeLevelCount = 0 then
    begin
      Warn('[Sprees] no valid level, the built-in levels are used');
      DefaultSpreeLevels(C);
    end;
    SortSpreeLevels(C);
    if C.RankTierCount = 0 then
    begin
      Warn('[Ranks] no valid tiers, defaults restored');
      AddTier(C, 'Unranked', 0, 0, -100000, -100000, -100000, $FFFFFF);
    end;
    { a measure no tier line gives a limit for would put everybody in the last tier }
    if (C.TierBy = 'mmr') or (C.TierBy = 'glicko2') or (C.TierBy = 'openskill') then
    begin
      FirstTier := False;
      for TierIdx := 0 to C.RankTierCount - 1 do
        if ((C.TierBy = 'mmr') and (C.RankTiers[TierIdx].MinMmr > -99999)) or
           ((C.TierBy = 'glicko2') and (C.RankTiers[TierIdx].MinGlicko > -99999)) or
           ((C.TierBy = 'openskill') and (C.RankTiers[TierIdx].MinOpenSkill > -99999)) then
          FirstTier := True;
      if not FirstTier then
        Warn(Format('[Ranking] TierBy = %s, but no line of [Ranks] gives that limit: everybody gets the last tier', [C.TierBy]));
    end;
    if C.MailEnabled and not IsValidEmail(C.MailFrom) then
    begin
      Warn('[Mail] FromAddress is not a valid address, e-mail sending is disabled');
      C.MailEnabled := False;
    end;
    if (C.MySQLEngine <> MYSQL_LOCAL) and (Trim(C.MySQLHost) = '') then
    begin
      Warn('[MySQL] Engine needs a Host: the statistics stay in the files only (Engine = local)');
      C.MySQLEngine := MYSQL_LOCAL;
    end;
    C.MySQLEnabled := C.MySQLEngine = MYSQL_MIRROR;
    Result := True;
  finally
    L.Free;
  end;
end;

{ The text of settings.ini goes through here, never through Format: a % the admin wrote that is no
  %s or %d stays a %, and a name of a player may hold any character. }
function SpreeText(const Template: AnsiString; const Names: array of AnsiString; Kills: LongInt): AnsiString;
var
  i, n: LongInt;
  c: AnsiChar;
begin
  Result := '';
  n := 0;
  i := 1;
  while i <= Length(Template) do
  begin
    c := Template[i];
    if (c = '%') and (i < Length(Template)) then
    begin
      case Template[i + 1] of
        's', 'S':
          begin
            if n <= High(Names) then
              Result := Result + Names[n];
            Inc(n);
            Inc(i, 2);
            Continue;
          end;
        'd', 'D':
          begin
            Result := Result + IntToStr(Kills);
            Inc(i, 2);
            Continue;
          end;
        '%':
          begin
            Result := Result + '%';
            Inc(i, 2);
            Continue;
          end;
      end;
    end;
    Result := Result + c;
    Inc(i);
  end;
end;

function SpreeLevelOf(const C: TZSConfig; Kills: LongInt): LongInt;
var
  k: LongInt;
begin
  for k := 0 to C.SpreeLevelCount - 1 do
    if C.SpreeLevels[k].Kills = Kills then
      Exit(k);
  Result := -1;
end;

end.
