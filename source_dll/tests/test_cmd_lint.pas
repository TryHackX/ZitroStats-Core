program test_cmd_lint;

{ The output lint: every command of the help runs in every game mode, as the console admin and as
  a player, on accounts with small and with big counters, and every line it prints is checked by
  rules (width, touching cells, unshortened counters, broken values, rows of another mode, empty
  answers, commands that do not exist, identities of others shown to a player). }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, StrUtils, zs_types, zs_util, zs_db, zs_engine, zs_commands;

const
  LONG_NAME = 'LongNameLongNameLongName';

type
  TMode = record
    Name, Map: AnsiString;
    Style, Flags: LongInt;
  end;

const
  MODES: array[0..8] of TMode = (
    (Name: 'DM survival realistic'; Map: 'rscs_lint'; Style: GS_DM; Flags: 1 or 2 or 8),
    (Name: 'CTF'; Map: 'ctf_lint'; Style: GS_CTF; Flags: 0),
    (Name: 'DM'; Map: 'dm_lint'; Style: GS_DM; Flags: 0),
    (Name: 'PM'; Map: 'pm_lint'; Style: GS_PM; Flags: 0),
    (Name: 'RM'; Map: 'rm_lint'; Style: GS_RM; Flags: 0),
    (Name: 'TM'; Map: 'tm_lint'; Style: GS_TM; Flags: 0),
    (Name: 'INF'; Map: 'inf_lint'; Style: GS_INF; Flags: 0),
    (Name: 'HTF'; Map: 'htf_lint'; Style: GS_HTF; Flags: 0),
    (Name: 'CTF survival'; Map: 'ctf_lint2'; Style: GS_CTF; Flags: 1 or 2));

  { every command of the help, the aliases, the arguments of each form }
  PLAYER_CMDS: array[0..109] of AnsiString = (
    '!zitro', '!help', '!contact', '!hud',
    '!stats', '!stats alice', '!stats eve', '!stats bob', '!stats nobodyhere', '!stats ' + LONG_NAME, '!stats #1',
    '!statsi 1', '!statsi 999', '!statsi abc',
    '!otherstats alice', '!otherstats eve', '!otherstats bob', '!otherstatsi 1',
    '!status alice', '!status eve', '!statusi 2', '!rank alice', '!rank bob', '!ranki 1',
    '!session', '!session alice', '!session eve', '!sessioni 1',
    '!top', '!top 2', '!top alice', '!top kills', '!topp', '!topi 1', '!topid 1', '!topid', '!topme', '!topo',
    '!topby', '!topby help', '!topby kills', '!topby kills 2', '!topby dmgperkill', '!topskill', '!zs_search ali',
    '!zs_search zzzz', '!seasons', '!topday', '!topweek', '!topmonth', '!topseason', '!topseason 1',
    '!allweapons alice', '!allweapons eve', '!allweaponsi 1', '!wep', '!wep help', '!wep ak alice', '!wep ak eve',
    '!wepi ak 1', '!weap ak', '!matchup', '!matchup ak', '!matchup ak 2', '!serverweapons', '!serverwep ak',
    '!topweapons', '!topwepsby help', '!topwepsby kills', '!spree alice', '!spreei 1', '!achievements alice',
    '!achievementsi 1', '!achlist alice', '!achlisti 1', '!pm alice', '!rambo alice', '!ramboi 1',
    '!mapstats', '!mapstats rscs', '!heatmap', '!heatmap ctf', '!topmaps', '!topmaps rscs', '!topmapsp',
    '!topmapsi 1', '!topmapsby help', '!topmapsby kills', '!server', '!activity', '!bal', '!switch',
    '/zs_next', '/zs_prev', '!topweapons ak', '!topweapons ak 2', '!topweps knife', '!topweapons 2', '!topweapons kd',
    '!topweapons zzzz', '!spree eve', '!allweaponsby kills alice', '!allweaponsby acc;kd eve', '!allweaponsby help',
    '!allweaponsbyi reloads 1', '!serverweaponsby kills', '!serverweaponsby help', '!weaponsby dmg bob', '!topby kits',
    '!topby healkits;medkits;nadekits');
  PAGE_CMDS: array[0..5] of AnsiString = ('!top', '/zs_next', '/zs_prev', '/zs_page 3', '/zs_end', '/zs_first');
  ADMIN_CMDS: array[0..30] of AnsiString = (
    '/zs_status alice', '/zs_status eve', '/zs_status', '/zs_statusid 1', '/zs_statusi 1', '/searcha ali',
    '/searcha 11.22', '/zs_suspects', '/zs_perf', '/zs_backups', '/zs_restore', '/no', '/yes', '/zs_merge',
    '/zs_merge 1 2', '/no', '/zs_unregister', '/zs_setpass', '/removeolderthan', '/resetplayerstats',
    '/resetmapstats', '/balinfo', '/bal', '/mix', '/swap', '/move', '/balexclude', '/zs_status nobodyhere',
    '/zs_statusid 99999', '/move alice', '/swap alice');
  { the map vote: every command of it, with the maps folder and the maps list of the setup }
  MAPVOTE_CMDS: array[0..29] of AnsiString = ('!map', '!maps', '!maps 2', '!maps ash', '!maps zzz', '!maps longname',
    '!allmaps', '!allmaps ctf', '!allmaps zzz', '!allmaps 3', '!allmaps longname', '!v', '!vote', '!nextmap',
    '!lastmap', '!votelast', '!randommap', '!map ash', '!map zzz', '!votemap', '!votemap run', '/votemap ash',
    '/zs_mapvote', '/zs_maps', '/zs_mapvote cancel', '!searchmap', '!searchmap ctf', '!searchmap zzz',
    '!searchmap ctf 2', '!searchmap longname');
  LINT_MAPS: array[0..5] of AnsiString = ('ctf_Ash.pms', 'ctf_Run.pms', 'rscs_lint.pms', 'inf_Moon.PMS', 'htf_Tower.Pms',
    LONG_NAME + '_Map.pms');

var
  Failures: Integer = 0;
  Violations: LongInt = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Lines, Report, Known: TStringList;
  ModeName: AnsiString;
  CurStyle, CurFlags: LongInt;

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

procedure DeleteTree(const Dir: AnsiString);
var
  SR: TSearchRec;
  P: AnsiString;
begin
  if not DirectoryExists(Dir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure Push(Ev: TZSEvent);
begin
  Ev.Tick := CurTick;
  Engine.PushEvent(Ev);
  Inc(Pushed);
end;

function WaitProcessed: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while Engine.Processed < Pushed do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(1);
  end;
  Result := True;
end;

function WaitReady: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not Engine.IsReady do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Result := True;
end;

procedure MapAfter(const Name: AnsiString; Style, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := 10;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Team, Human: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := Hwid;
  Ev.S4 := IP;
  Ev.I[0] := Team;
  Ev.I[1] := Human;
  Ev.I[2] := 0;
  Push(Ev);
end;

{ the maps list as main.pas sends it (ZS_Ev_Map_List): the names, each ended by a line break }
procedure MapList(const Names: AnsiString; Current: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapList);
  Ev.I[1] := Current;
  Ev.I[2] := MAPLIST_CHANGED;
  Ev.S1 := Names;
  Push(Ev);
end;

procedure MakeFile(const Path, Text: AnsiString);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := Text;
    L.SaveToFile(Path);
  finally
    L.Free;
  end;
end;

{ a command through the engine as the script sends it; Lines gets what it wrote to Slot }
procedure Run(Slot: LongInt; const Text: AnsiString; Admin: Boolean);
var
  Ev: TZSEvent;
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    ;
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  if Slot = 0 then
    Ev.I[0] := SRC_CONSOLE
  else
    Ev.I[0] := SRC_COMMAND;
  Ev.I[1] := Ord(Admin);
  Push(Ev);
  WaitProcessed;
  Lines.Clear;
  while Engine.PopAction(A) do
    if (A.Kind in [ACT_CONSOLE, ACT_WRITELN]) and (A.Slot = Slot) then
      Lines.Add(A.Text);
end;

procedure Violation(const Cmd, What, Line: AnsiString);
var
  K: AnsiString;
begin
  K := What + ' | ' + Cmd + ' | ' + Line;
  { the same line in another mode is the same finding }
  if Report.IndexOf(K) >= 0 then
    Exit;
  Report.Add(K);
  Inc(Violations);
  WriteLn('[VIOL] ', ModeName, ' | ', Cmd, ' | ', What, ' | "', Line, '"');
end;

function IsDigit(C: Char): Boolean;
begin
  Result := C in ['0'..'9'];
end;

function HasWord(const T, W: AnsiString): Boolean;
var
  p, e: LongInt;
begin
  Result := False;
  p := Pos(W, T);
  while p > 0 do
  begin
    e := p + Length(W);
    if ((p = 1) or not (T[p - 1] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '-', '+', '_'])) and
       ((e > Length(T)) or not (T[e] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_'])) then
      Exit(True);
    p := PosEx(W, T, p + 1);
  end;
end;

{ a counter of 5 digits or more that is not part of a date, time, id, IP or version }
procedure CheckNumbers(const Cmd, T: AnsiString);
var
  i, j: LongInt;
  Before, After: Char;
begin
  i := 1;
  while i <= Length(T) do
  begin
    if IsDigit(T[i]) then
    begin
      j := i;
      while (j <= Length(T)) and IsDigit(T[j]) do
        Inc(j);
      if j - i >= 5 then
      begin
        if i > 1 then Before := T[i - 1] else Before := ' ';
        if j <= Length(T) then After := T[j] else After := ' ';
        if not (Before in ['#', '.', ':', '-', '/', 'S', 'D', '_', 'x']) and not (After in ['.', ':', '-', '/', '_']) then
          Violation(Cmd, 'counter in full', T);
      end;
      i := j;
    end
    else
      Inc(i);
  end;
end;

{ a value followed at once by the next label: "12Deaths: " }
procedure CheckTouching(const Cmd, T: AnsiString);
var
  i, k: LongInt;
begin
  for i := 2 to Length(T) - 2 do
    if (T[i] in ['A'..'Z']) and (T[i - 1] in ['0'..'9', '%', ')', ']']) then
    begin
      k := i;
      while (k < Length(T)) and (T[k] in ['A'..'Z', 'a'..'z', '/', ' ', '&', '-']) and (k - i < 22) do
      begin
        if (T[k + 1] = ':') and ((k + 2 > Length(T)) or (T[k + 2] = ' ')) then
        begin
          Violation(Cmd, 'cells touch', T);
          Exit;
        end;
        if (T[k] = ' ') and (k > i) and (T[k - 1] = ' ') then
          Break;
        Inc(k);
      end;
    end;
  { the command grid: items two spaces apart }
  for i := 2 to Length(T) - 1 do
    if (T[i] = ' ') and (T[i + 1] in ['!', '/']) and (T[i - 1] <> ' ') and (i + 2 <= Length(T)) and
       (T[i + 2] in ['a'..'z']) and (Pos('  ', T) > 0) and (T[1] in ['!', '/']) and (Pos(' = ', T) = 0) then
    begin
      Violation(Cmd, 'grid items touch', T);
      Exit;
    end;
end;

{ commands named in an answer that the dispatcher does not know }
procedure CheckNames(const Cmd, T: AnsiString);
var
  i, j: LongInt;
  N: AnsiString;
begin
  i := 1;
  while i < Length(T) do
  begin
    if (T[i] in ['!', '/']) and ((i = 1) or (T[i - 1] in [' ', '(', '"', ''''])) and (T[i + 1] in ['a'..'z']) then
    begin
      j := i + 1;
      while (j <= Length(T)) and (T[j] in ['a'..'z', '0'..'9', '_']) do
        Inc(j);
      N := Copy(T, i + 1, j - i - 1);
      if Known.IndexOf(N) < 0 then
        Violation(Cmd, 'unknown command ' + T[i] + N, T);
      i := j;
    end
    else
      Inc(i);
  end;
end;

function Objective: Boolean;
begin
  Result := CurStyle in [GS_CTF, GS_INF, GS_HTF];
end;

function TeamMode: Boolean;
begin
  Result := CurStyle in [GS_TM, GS_CTF, GS_INF, GS_HTF];
end;

{ the rows of another mode, for an account without such counters (Eve, Bob) }
procedure CheckModeRows(const Cmd, T: AnsiString);
begin
  if not Objective and ((Pos('Flag', T) > 0) or (Pos('Caps', T) > 0) or (Pos('Returns', T) > 0) or
     (Pos('Base Gap', T) > 0) or (Pos('Captures', T) > 0)) then
    Violation(Cmd, 'flag row outside CTF/INF/HTF', T);
  { "Pts Delta" is the change of points, not the team }
  if not TeamMode and ((Pos('Alpha', T) > 0) or (Pos('Bravo', T) > 0) or (Pos('Charlie', T) > 0) or
     (Pos('Delta', StringReplace(T, 'Pts Delta', '', [])) > 0)) then
    Violation(Cmd, 'team row outside team modes', T);
  if not (TeamMode and (CurFlags and 8 <> 0)) and ((Pos('Teamkill', T) > 0) or (Pos('TK ', T) > 0)) then
    Violation(Cmd, 'teamkill row without friendly fire', T);
  if (CurFlags and 1 = 0) and (Pos('Round', T) > 0) then
    Violation(Cmd, 'round row outside survival', T);
  if (CurStyle <> GS_RM) and (Pos('Rambo', T) > 0) then
    Violation(Cmd, 'rambo row outside rambo', T);
  if (CurStyle <> GS_PM) and ((Pos('Pointmatch', T) > 0) or (Pos('Point Match', T) > 0)) then
    Violation(Cmd, 'pointmatch row outside pointmatch', T);
end;

procedure Lint(const Cmd: AnsiString; Viewer: LongInt; ModeRows: Boolean);
var
  k: LongInt;
  T, L: AnsiString;
begin
  if Lines.Count = 0 then
    Violation(Cmd, 'no answer', '');
  for k := 0 to Lines.Count - 1 do
  begin
    T := Lines[k];
    L := LowerCase(T);
    if Length(T) > LINE_W then
      Violation(Cmd, Format('%d wide', [Length(T)]), T);
    if (T <> '') and (Trim(T) = '') then
      Violation(Cmd, 'only spaces', T);
    if (T <> '') and (T[Length(T)] = ' ') then
      Violation(Cmd, 'trailing space', T);
    if HasWord(L, 'nan') or HasWord(L, 'inf') or HasWord(L, '-0') or HasWord(L, '-0.0') or HasWord(T, '0B') or
       HasWord(L, '1000k') or HasWord(L, '-nan') then
      Violation(Cmd, 'broken number', T);
    if (Pos('%%', T) > 0) or (Pos('%d', T) > 0) or (Pos('%s', T) > 0) or (Pos('%.', T) > 0) then
      Violation(Cmd, 'format left over', T);
    if (Length(T) >= 2) and ((Copy(T, Length(T) - 1, 2) = '()') or (Copy(T, Length(T) - 1, 2) = ': ')) then
      Violation(Cmd, 'value missing at the end', T);
    if Pos('()', T) > 0 then
      Violation(Cmd, 'empty brackets', T);
    { the goal of an achievement in !achlist is a threshold of its definition, not a counter }
    if (Copy(T, 1, 3) <> '[ ]') and (Copy(T, 1, 3) <> '[x]') and (Copy(T, 1, 3) <> '[X]') then
      CheckNumbers(Cmd, T);
    CheckTouching(Cmd, T);
    CheckNames(Cmd, T);
    if ModeRows then
      CheckModeRows(Cmd, T);
    { a player who is no admin sees nobody else's identity }
    if Viewer > 0 then
      if (Pos('11.22.33.44', T) > 0) or (Pos('HWIDALICE', T) > 0) or (Pos('S7001', T) > 0) or
         (Pos('55.66.77.88', T) > 0) or (Pos('HWIDEVE', T) > 0) or (Pos('S7004', T) > 0) then
        Violation(Cmd, 'identity of another player', T);
  end;
end;

function Prof(Slot: LongInt): PPlayerProfile;
var
  Idx: LongInt;
begin
  Idx := Engine.Identity.ProfileIndex(Slot);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx]
  else
    Result := nil;
end;

procedure AddKnown(const Names: array of AnsiString);
var
  k: LongInt;
begin
  for k := 0 to High(Names) do
    Known.Add(Names[k]);
end;

procedure RunAll;
var
  k: LongInt;
  C: AnsiString;
begin
  for k := 0 to High(PLAYER_CMDS) do
  begin
    C := PLAYER_CMDS[k];
    Run(0, C, True);
    Lint('console ' + C, 0, (Pos('eve', C) > 0) or (Pos('bob', C) > 0));
    Run(2, C, False);
    Lint('player ' + C, 2, (Pos('eve', C) > 0) or (Pos('bob', C) > 0) or (C = '!stats') or (C = '!session'));
  end;
  for k := 0 to High(PAGE_CMDS) do
  begin
    Run(2, PAGE_CMDS[k], False);
    Lint('player ' + PAGE_CMDS[k], 2, False);
  end;
  for k := 0 to High(ADMIN_CMDS) do
  begin
    Run(0, ADMIN_CMDS[k], True);
    Lint('console ' + ADMIN_CMDS[k], 0, Pos('eve', ADMIN_CMDS[k]) > 0);
    Run(2, ADMIN_CMDS[k], False);
    Lint('player ' + ADMIN_CMDS[k], 2, False);
  end;
  for k := 0 to High(MAPVOTE_CMDS) do
  begin
    Run(0, MAPVOTE_CMDS[k], True);
    Lint('console ' + MAPVOTE_CMDS[k], 0, False);
    Run(2, MAPVOTE_CMDS[k], False);
    Lint('player ' + MAPVOTE_CMDS[k], 2, False);
  end;
  { the password commands of a player without Steam }
  Run(3, '!zitro', False);
  Lint('nosteam !zitro', 3, False);
  Run(3, '/account', False);
  Lint('nosteam /account', 3, False);
  Run(3, '/register', False);
  Lint('nosteam /register', 3, False);
  Run(3, '/login', False);
  Lint('nosteam /login', 3, False);
end;

var
  Root: AnsiString;
  A, B, E, D: PPlayerProfile;
  M, w: LongInt;
begin
  Root := 'C:\Users\Dominik\AppData\Local\Temp\zlint';
  if GetEnvironmentVariable('ZLINT_DIR') <> '' then
    Root := GetEnvironmentVariable('ZLINT_DIR');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Lines := TStringList.Create;
  Report := TStringList.Create;
  Known := TStringList.Create;
  Known.Sorted := True;
  Known.Duplicates := dupIgnore;
  AddKnown(['zitro', 'help', 'commands', 'cmds', 'contact', 'bal', 'teams', 'switch', 'join', 'hud', 'stats', 'statsi',
    'otherstats', 'otherstatsi', 'status', 'statusi', 'rank', 'ranki', 'session', 'sessioni', 'top', 'topp', 'topi',
    'topid', 'topme', 'topo', 'topby', 'topskill', 'zs_search', 'zssearch', 'seasons', 'topday', 'topweek',
    'topmonth', 'topseason', 'allweapons', 'allweaponsi', 'wep', 'wepi', 'weap', 'weapi', 'matchup', 'serverweapons',
    'serverwep', 'topweapons', 'topwepsby', 'topweaponsby', 'spree', 'spreei', 'achievements', 'achievementsi',
    'achlist', 'achlisti', 'ach', 'achi', 'pm', 'rambo', 'ramboi', 'mapstats', 'heatmap', 'topmaps', 'topmapsp',
    'topmapsi', 'topmapsby', 'server', 'activity', 'zs_next', 'zs_prev', 'zs_page', 'zs_first', 'zs_end', 'zsnext',
    'zsprev', 'zspage', 'zsfirst', 'zsend', 'register', 'login', 'changepass', 'setemail', 'verifyemail', 'account',
    'forgotpass', 'resetpass', 'removemypass', 'zs_status', 'zs_statusid', 'zs_statusi', 'searcha', 'zs_suspects',
    'zs_perf', 'zs_save', 'zs_reload', 'zs_export', 'zs_backup', 'zs_backups', 'zs_restore', 'yes', 'no', 'zs_merge',
    'zs_unregister', 'zs_setpass', 'removeolderthan', 'resetplayerstats', 'resetallplayersstats', 'resetserverstats',
    'resetallmapsstats', 'resetmapstats', 'balinfo', 'mix', 'swap', 'move', 'balexclude', 'badges', 'badgesi',
    'topweps', 'toprating', 'toponline', 'serverstats', 'weapons', 'weaponsi', 'weapon', 'weaponi', 'srvwep',
    'srvweps', 'srvweapons', 'serverweps', 'serverweapon', 'matchups', 'heat', 'ranknum', 'today', 'adminlog',
    'achievementslist', 'achievementslisti', 'pointmatch', 'kills', 'enemy', 'matrix', 'password', 'unrated',
    'antifake', 'af_search', 'zsstatus', 'zsstatusi', 'zsstatusid', 'info', 'credits', 'reginfo']);
  { the map vote (zs_cmd_mapvote.inc) }
  AddKnown(['v', 'vote', 'nextmap', 'lastmap', 'votelast', 'votelastmap', 'randommap', 'map', 'votemap', 'maps',
    'allmaps', 'searchmap', 'zs_mapvote', 'zs_maps']);
  { the weapon tables by metrics }
  AddKnown(['allweaponsby', 'allweaponsbyi', 'weaponsby', 'weaponsbyi', 'serverweaponsby', 'serverwepsby', 'srvweaponsby',
    'srvwepsby']);
  { a maps folder of its own, one file with ".PMS" and one with ".Pms" among the maps }
  ForceDirectories(Root + PathDelim + 'maps');
  for M := 0 to High(LINT_MAPS) do
    MakeFile(Root + PathDelim + 'maps' + PathDelim + LINT_MAPS[M], 'map');
  MakeFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini', '[MapVote]' + LineEnding + 'MapsFolder = ' +
    Root + PathDelim + 'maps');

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);

  CurTick := 0;
  MapAfter('rscs_lint', GS_DM, 1 or 2 or 8);
  Join(1, 'Alice', 'S7001', 'HWIDALICE1', '11.22.33.44', TEAM_NONE, 1);
  Join(2, 'Bob', 'S7002', 'HWIDBOB1', '2.2.2.2', TEAM_NONE, 1);
  Join(3, 'Carl', '', 'HWIDCARL1', '3.3.3.3', TEAM_NONE, 1);
  Join(4, 'Eve', 'S7004', 'HWIDEVE1', '55.66.77.88', TEAM_NONE, 1);
  Join(5, LONG_NAME, 'S7005', 'HWIDLONG1', '5.5.5.5', TEAM_NONE, 1);
  Join(6, 'Dave', 'S7006', 'HWIDDAVE1', '6.6.6.6', TEAM_SPEC, 1);
  Join(7, 'Bot Boogie', '', '', '', TEAM_NONE, 0);
  MapList('rscs_lint' + #10 + 'ctf_Ash' + #10 + 'ctf_Run' + #10 + 'ctf_Missing' + #10, 0);
  Check('joins processed', WaitProcessed);
  { the accounts are made on the engine's next ticks }
  for M := 1 to 100 do
  begin
    EnterCriticalSection(Engine.StateLock);
    try
      w := Ord(Prof(1) <> nil) + Ord(Prof(2) <> nil) + Ord(Prof(4) <> nil) + Ord(Prof(5) <> nil);
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    if w = 4 then
      Break;
    Sleep(50);
  end;

  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
    A := Prof(1);
    B := Prof(2);
    E := Prof(4);
    D := Prof(5);
    Check(Format('accounts %d %d %d %d', [Ord(A <> nil), Ord(B <> nil), Ord(E <> nil), Ord(D <> nil)]),
      (A <> nil) and (B <> nil) and (E <> nil) and (D <> nil));
    if (A <> nil) and (B <> nil) and (E <> nil) and (D <> nil) then
    begin
      { Alice: big counters of every kind, of every mode }
      A^.Kills := 1234567;
      A^.Deaths := 987654;
      A^.Selfkills := 45678;
      A^.Assist := 234567;
      A^.Shots := 98765432;
      A^.ShotsHits := 23456789;
      A^.ShotsHitsHead := 3456789;
      A^.ShotsHitsBody := 12345678;
      A^.ShotsHitsLeg := 456789;
      A^.Wins := 23456;
      A^.Loses := 12345;
      A^.RoundsWins := 34567;
      A^.RoundsLose := 23456;
      A^.RoundsAlphaWins := 12345;
      A^.RoundsBravoWins := 11111;
      A^.TimeAlive := 3600000;
      A^.TimePlayed := 4000000;
      A^.DamageDealt := 987654321;
      A^.DamageReceived := 876543210;
      A^.Points := 7654321;
      A^.Teamkills := 12345;
      A^.FlagsScore := 45678;
      A^.FlagsReturn := 23456;
      A^.FlagsGrab := 56789;
      A^.FlaggerKills := 34567;
      A^.TopVictims[0].TargetPlayerID := B^.ID;
      A^.TopVictims[0].KillCount := 123456;
      { every kind of kit picked up, five characters each once shortened }
      for w := 0 to KIT_KINDS - 1 do
        A^.KitPickups[w] := 12345;
      A^.HealKitCount := 23456;
      for w := WEP_SOCOM to WEP_MINIGUN do
      begin
        A^.Weapons[w].Damage := 12345678 + w;
        A^.Weapons[w].Hits := 234567 + w;
        A^.Weapons[w].Kills := 123456 + w;
        A^.Weapons[w].Shots := 987654 + w;
        A^.Weapons[w].Deaths := 54321 + w;
      end;
      { Eve: big counters of a deathmatch player only }
      E^.Kills := 654321;
      E^.Deaths := 543210;
      E^.Shots := 9876543;
      E^.ShotsHits := 2345678;
      E^.ShotsHitsHead := 345678;
      E^.ShotsHitsBody := 1234567;
      E^.ShotsHitsLeg := 45678;
      E^.TimePlayed := 2000000;
      E^.TimeAlive := 1500000;
      E^.DamageDealt := 98765432;
      E^.DamageReceived := 87654321;
      for w := WEP_DEAGLES to WEP_AK74 do
      begin
        E^.Weapons[w].Damage := 2345678;
        E^.Weapons[w].Hits := 34567;
        E^.Weapons[w].Kills := 23456;
        E^.Weapons[w].Shots := 98765;
        E^.Weapons[w].Deaths := 12345;
      end;
      { the long name: a fresh player with a few kills }
      D^.Kills := 3;
      D^.Deaths := 7;
      D^.Shots := 40;
      D^.ShotsHits := 9;
      { maps of both kinds }
      M := Engine.DB.FindMap('rscs_lint', True);
      if M >= 0 then
      begin
        Engine.DB.Maps[M].Kills := 1234567;
        Engine.DB.Maps[M].ActiveMapPlays := 23456;
      end;
      M := Engine.DB.FindMap('ctf_lint', True);
      if M >= 0 then
      begin
        Engine.DB.Maps[M].Kills := 234567;
        Engine.DB.Maps[M].ActiveMapPlays := 3456;
      end;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  for M := 0 to High(MODES) do
  begin
    ModeName := MODES[M].Name;
    CurStyle := MODES[M].Style;
    CurFlags := MODES[M].Flags;
    MapAfter(MODES[M].Map, CurStyle, CurFlags);
    WaitProcessed;
    RunAll;
    Check('no violations in ' + ModeName + ' (' + IntToStr(Violations) + ' so far)', True);
  end;

  Check(Format('no violations (%d found)', [Violations]), Violations = 0);
  Engine.Free;
  Lines.Free;
  Report.Free;
  Known.Free;
  DeleteTree(Root);
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  if Failures <> 0 then
    Halt(1);
end.
