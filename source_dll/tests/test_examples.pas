program test_examples;

{ Every file of Example-configs is a complete settings.ini: the library reads each one without a
  single warning, each has the values its kind of server needs, and everything no example changes
  stays what settings.ini says. Run from source_dll/build/test like the other tests (the script
  folder is three levels up), or give the folder that holds settings.ini and Example-configs:
    test_examples [<script folder>] }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, zs_config;

const
  FAST: array[0..7] of LongInt = (5, 10, 15, 20, 25, 30, 40, 50);
  BUILT_IN: array[0..9] of LongInt = (3, 5, 7, 10, 12, 15, 17, 20, 25, 30);
  NAMES: array[0..10] of AnsiString = ('deathmatch.ini', 'deathmatch-survival-realistic.ini', 'ctf.ini',
    'ctf-survival-realistic.ini', 'teammatch.ini', 'infiltration.ini', 'hold-the-flag.ini', 'pointmatch.ini',
    'rambomatch.ini', 'several-servers-mysql.ini', 'website-mirror.ini');

var
  Failures: Integer = 0;
  Root, Dir: AnsiString;
  Base, C: TZSConfig;
  SR: TSearchRec;
  n, i: LongInt;

procedure Check(const Name: string; Ok: Boolean);
begin
  if Ok then
    WriteLn('[ OK ] ', Name)
  else
  begin
    WriteLn('[FAIL] ', Name);
    Inc(Failures);
  end;
end;

{ the file on top of the built-in values; every warning is printed, True when there was none }
function LoadClean(const Path: AnsiString; var Cfg: TZSConfig): Boolean;
var
  W: TStringList;
  k: LongInt;
begin
  W := TStringList.Create;
  try
    Cfg := Default(TZSConfig);
    SetConfigDefaults(Cfg);
    Result := LoadConfigFile(Path, Cfg, W) and (W.Count = 0);
    for k := 0 to W.Count - 1 do
      WriteLn('       ', W[k]);
  finally
    W.Free;
  end;
end;

function LevelsAre(const Cfg: TZSConfig; const Kills: array of LongInt): Boolean;
var
  k: LongInt;
begin
  Result := Cfg.SpreeLevelCount = Length(Kills);
  if Result then
    for k := 0 to High(Kills) do
      if Cfg.SpreeLevels[k].Kills <> Kills[k] then
        Exit(False);
end;

{ what no example changes is what settings.ini says; nothing an admin has to fill in is filled }
function SameRest(const A, B: TZSConfig): Boolean;
begin
  Result := (A.StartingPoints = B.StartingPoints) and (A.MaxPointGive = B.MaxPointGive) and
    (A.RankingSystem = B.RankingSystem) and (A.TierBy = B.TierBy) and (A.RankTierCount = B.RankTierCount) and
    (A.InactivityMode = B.InactivityMode) and (A.InactivityDays = B.InactivityDays) and
    (A.SeasonsEnabled = B.SeasonsEnabled) and (A.SeasonLength = B.SeasonLength) and
    (A.SeasonPointsReset = B.SeasonPointsReset) and (A.MaxHealth = B.MaxHealth) and
    (A.MaxHealthRealistic = B.MaxHealthRealistic) and (A.MinHumansForStats = B.MinHumansForStats) and
    (A.MapVoteEnabled = B.MapVoteEnabled) and (A.MapVotePercent = B.MapVotePercent) and
    (A.MapVoteAllowAnyMap = B.MapVoteAllowAnyMap) and (A.MapVoteCommands = B.MapVoteCommands) and
    (A.BalanceMethod = B.BalanceMethod) and (A.BalanceMapStart = B.BalanceMapStart) and
    (A.IntegrityEnabled = B.IntegrityEnabled) and (A.IntegrityFixJoinScore = B.IntegrityFixJoinScore) and
    (A.IntegrityVoidDoubleCaptures = B.IntegrityVoidDoubleCaptures) and
    (A.IntegrityMinOpponents = B.IntegrityMinOpponents) and
    (A.IntegrityRespawnAfterMapChange = B.IntegrityRespawnAfterMapChange) and
    (A.IntegrityProtectMapChange = B.IntegrityProtectMapChange) and (A.SpreesEnabled = B.SpreesEnabled) and
    (A.SpreeShutText = B.SpreeShutText) and (A.HudEnabled = B.HudEnabled) and (A.ColHeader = B.ColHeader) and
    (A.DataPath = B.DataPath) and (A.MySQLHost = B.MySQLHost) and (A.MySQLUser = B.MySQLUser) and
    (A.MySQLDatabase = B.MySQLDatabase) and (A.MySQLServerID = B.MySQLServerID) and
    (A.AdminConfirmPassword = '') and not A.MailEnabled and not A.WebhookEnabled;
end;

begin
  if ParamCount >= 1 then
    Root := IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)))
  else
    Root := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim + '..' + PathDelim);
  Dir := Root + 'Example-configs' + PathDelim;

  Check('settings.ini loads without warnings', LoadClean(Root + 'settings.ini', Base));

  { every file of the folder, also one this program does not know }
  n := 0;
  if FindFirst(Dir + '*.ini', faAnyFile, SR) = 0 then
  try
    repeat
      Inc(n);
      Check(SR.Name + ' loads without warnings', LoadClean(Dir + SR.Name, C));
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Check(Format('Example-configs holds the %d examples (%d .ini files)', [Length(NAMES), n]), n >= Length(NAMES));
  for i := 0 to High(NAMES) do
    Check(NAMES[i] + ' is there', FileExists(Dir + NAMES[i]));

  { what each one is for }
  LoadClean(Dir + 'deathmatch.ini', C);
  Check('deathmatch.ini: no team balance, the style filter, the levels 5-50', not C.BalanceEnabled and
    C.MapVoteFilterByStyle and LevelsAre(C, FAST) and (C.SpreeLevels[0].Style = SPREE_CHAT) and
    (C.SpreeLevels[1].Name = 'Rampage') and (C.SpreeLevels[4].Name = 'Godlike') and not C.CountAbortedMatches and
    (C.BinkDamage = 35) and (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'deathmatch-survival-realistic.ini', C);
  Check('deathmatch-survival-realistic.ini: no team balance, no filter, aborted matches count, ' +
    'BinkDamage 15, the built-in levels', not C.BalanceEnabled and not C.MapVoteFilterByStyle and
    C.CountAbortedMatches and (C.BinkDamage = 15) and (C.MaxHealthRealistic = 65) and LevelsAre(C, BUILT_IN) and
    (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'ctf.ini', C);
  Check('ctf.ini: the team balance, the style filter, the built-in levels', C.BalanceEnabled and
    C.MapVoteFilterByStyle and LevelsAre(C, BUILT_IN) and not C.CountAbortedMatches and (C.BinkDamage = 35) and
    (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'ctf-survival-realistic.ini', C);
  Check('ctf-survival-realistic.ini: the team balance, no filter, aborted matches count, BinkDamage 15, ' +
    'the whole score guard', C.BalanceEnabled and not C.MapVoteFilterByStyle and C.CountAbortedMatches and
    (C.BinkDamage = 15) and LevelsAre(C, BUILT_IN) and C.IntegrityEnabled and C.IntegrityFixJoinScore and
    C.IntegrityVoidDoubleCaptures and C.IntegrityRespawnAfterMapChange and (C.MySQLEngine = MYSQL_LOCAL) and
    SameRest(C, Base));

  LoadClean(Dir + 'teammatch.ini', C);
  Check('teammatch.ini: the team balance for the teams in use, the style filter, the levels 5-50',
    C.BalanceEnabled and (C.BalanceTeammatchTeams = 0) and C.MapVoteFilterByStyle and LevelsAre(C, FAST) and
    not C.CountAbortedMatches and (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'infiltration.ini', C);
  Check('infiltration.ini: the team balance, the style filter, the built-in levels', C.BalanceEnabled and
    C.MapVoteFilterByStyle and LevelsAre(C, BUILT_IN) and (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'hold-the-flag.ini', C);
  Check('hold-the-flag.ini: the team balance, the style filter, the built-in levels', C.BalanceEnabled and
    C.MapVoteFilterByStyle and LevelsAre(C, BUILT_IN) and (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'pointmatch.ini', C);
  Check('pointmatch.ini: no team balance, the style filter, the levels 5-50', not C.BalanceEnabled and
    C.MapVoteFilterByStyle and LevelsAre(C, FAST) and (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'rambomatch.ini', C);
  Check('rambomatch.ini: no team balance, the style filter, the levels 5-50', not C.BalanceEnabled and
    C.MapVoteFilterByStyle and LevelsAre(C, FAST) and (C.MySQLEngine = MYSQL_LOCAL) and SameRest(C, Base));

  LoadClean(Dir + 'several-servers-mysql.ini', C);
  Check('several-servers-mysql.ini: Engine = mysql with a placeholder password, the game as settings.ini',
    (C.MySQLEngine = MYSQL_SHARED) and not C.MySQLEnabled and (C.MySQLPassword = 'CHANGE_ME') and
    (C.MySQLHost = '127.0.0.1') and (C.MySQLServerID = 1) and not C.MySQLShareProfiles and
    not C.MySQLShareRankings and (C.BalanceEnabled = Base.BalanceEnabled) and
    (C.MapVoteFilterByStyle = Base.MapVoteFilterByStyle) and LevelsAre(C, BUILT_IN) and SameRest(C, Base));

  LoadClean(Dir + 'website-mirror.ini', C);
  Check('website-mirror.ini: Engine = mirror with a placeholder password, the game as settings.ini',
    (C.MySQLEngine = MYSQL_MIRROR) and C.MySQLEnabled and (C.MySQLPassword = 'CHANGE_ME') and
    not C.MySQLFullJson and not C.MySQLShareProfiles and (C.MySQLMirrorSeconds = Base.MySQLMirrorSeconds) and
    (C.BalanceEnabled = Base.BalanceEnabled) and (C.MapVoteFilterByStyle = Base.MapVoteFilterByStyle) and
    LevelsAre(C, BUILT_IN) and SameRest(C, Base));

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
