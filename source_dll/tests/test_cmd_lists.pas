program test_cmd_lists;

{ The tables of the rankings, maps, weapons and team balance (zs_cmd_lists, zs_cmd_maps,
  zs_cmd_weapons, zs_cmd_balance): every line fits LINE_W, the cells of a row stand under their
  headers, big counters are shortened, nothing is divided by zero, and the rows of teams, flags
  and rounds show only in the modes that have them. The commands run on the server console of an
  engine that got a few players and a match through its events. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_engine, zs_commands, zs_weapons;

const
  { the kill distance ranges of !wep, in the order of the table }
  DIST_NAMES: array[0..4] of AnsiString = ('<10m', '10-25m', '25-50m', '50-100m', '100m+');

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  { the console lines of the last command, and of every command }
  Lines, All: TStringList;

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
    Sleep(5);
  end;
  Sleep(150);
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

procedure MapAfter(const Name: AnsiString; Style, Limit, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := Limit;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Team: LongInt);
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
  Ev.I[1] := 1;
  Ev.I[2] := 0;
  Push(Ev);
end;

procedure Spawn(Slot, Weapon: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSpawn);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := WEP_SOCOM;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure Kill(K, V, Weapon, VictimWeapon: LongInt; KX, KY, VX, VY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := EF_A_ALIVE or EF_A_ONGROUND;
  Ev.I[3] := VictimWeapon;
  Ev.F[0] := KX;
  Ev.F[1] := KY;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Push(Ev);
end;

{ a command on the server console, run as the engine thread runs it (with the state lock); Lines
  gets what it wrote }
procedure Run(const Text: AnsiString);
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    ;
  EnterCriticalSection(Engine.StateLock);
  try
    ExecuteCommand(Engine, 0, SplitWords(Text), SRC_CONSOLE, True);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Lines.Clear;
  while Engine.PopAction(A) do
    if (A.Kind = ACT_WRITELN) and (A.Slot = 0) then
      Lines.Add(A.Text);
  All.Add('>>> ' + Text);
  All.AddStrings(Lines);
end;

{ the same as a player on the server (no admin): Lines gets what went to the player's console }
procedure RunAs(Slot: LongInt; const Text: AnsiString);
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    ;
  EnterCriticalSection(Engine.StateLock);
  try
    ExecuteCommand(Engine, Slot, SplitWords(Text), SRC_COMMAND, False);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Lines.Clear;
  while Engine.PopAction(A) do
    if (A.Kind = ACT_CONSOLE) and (A.Slot = Slot) then
      Lines.Add(A.Text);
  All.Add(Format('>>> %s (slot %d)', [Text, Slot]));
  All.AddStrings(Lines);
end;

procedure RunBalanceInfo;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    ;
  EnterCriticalSection(Engine.StateLock);
  try
    CmdBalanceInfo(Engine, 0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Lines.Clear;
  while Engine.PopAction(A) do
    if (A.Kind = ACT_WRITELN) and (A.Slot = 0) then
      Lines.Add(A.Text);
  All.Add('>>> /balinfo');
  All.AddStrings(Lines);
end;

function Has(const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  for k := 0 to Lines.Count - 1 do
    if Pos(Part, Lines[k]) > 0 then
      Exit(True);
  Result := False;
end;

{ the first line of the last command that contains Part, '' when none }
function LineOf(const Part: AnsiString): AnsiString;
var
  k: LongInt;
begin
  for k := 0 to Lines.Count - 1 do
    if Pos(Part, Lines[k]) > 0 then
      Exit(Lines[k]);
  Result := '';
end;

{ the first line of the last command that starts with Start (a header row), -1 when none }
function HeaderLine(const Start: AnsiString): LongInt;
var
  k: LongInt;
begin
  for k := 0 to Lines.Count - 1 do
    if Pos(Start, Lines[k]) = 1 then
      Exit(k);
  Result := -1;
end;

function IndexOfLine(const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  for k := 0 to Lines.Count - 1 do
    if Pos(Part, Lines[k]) > 0 then
      Exit(k);
  Result := -1;
end;

{ every line of the last command fits LINE_W, and every frame (a line of = around a title, or of
  = alone) is exactly LINE_W wide }
function Fits: Boolean;
var
  k: LongInt;
  T: AnsiString;
begin
  Result := Lines.Count > 0;
  for k := 0 to Lines.Count - 1 do
  begin
    T := Lines[k];
    if Length(T) > LINE_W then
    begin
      WriteLn('       too wide (', Length(T), '): ', T);
      Result := False;
    end;
    if (T <> '') and (T[1] = '=') and (Length(T) <> LINE_W) then
    begin
      WriteLn('       frame of ', Length(T), ': ', T);
      Result := False;
    end;
  end;
end;

{ the text at a column (1-based) of a line }
function At(const Line: AnsiString; Col: LongInt; const Text: AnsiString): Boolean;
begin
  Result := Copy(Line, Col, Length(Text)) = Text;
end;

{ A table whose headers are single words: in every row from the line after the header to the
  end of the table (a frame, a page hint, a note or a line with Stop; rules and sections are
  skipped), the character before the start of each header is a space - a cell longer than its
  column would shift the ones after it. }
function RowsUnderHeader(HeaderIdx: LongInt; const Stop: AnsiString = ''): Boolean;
var
  H, R: AnsiString;
  k, p: LongInt;
begin
  Result := HeaderIdx >= 0;
  if not Result then
    Exit;
  H := Lines[HeaderIdx];
  for k := HeaderIdx + 1 to Lines.Count - 1 do
  begin
    R := Lines[k];
    if (Stop <> '') and (Pos(Stop, R) > 0) then
      Break;
    if (R <> '') and (R[1] = '-') then
      Continue;
    if (R = '') or (R[1] = '=') or (Pos('Page ', R) = 1) or (Pos('[Note]', R) = 1) then
      Break;
    for p := 2 to Length(H) do
      if (H[p] <> ' ') and (H[p - 1] = ' ') and (p - 1 <= Length(R)) and (R[p - 1] <> ' ') then
      begin
        WriteLn('       cell out of its column at ', p, ':');
        WriteLn('       ', H);
        WriteLn('       ', R);
        Exit(False);
      end;
  end;
end;

{ the parts of a text between the separators }
function SplitAt(const S: AnsiString; Sep: AnsiChar): TStringArray;
var
  k, n: LongInt;
  Cur: AnsiString;
begin
  Result := nil;
  Cur := '';
  for k := 1 to Length(S) + 1 do
    if (k > Length(S)) or (S[k] = Sep) then
    begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := Cur;
      Cur := '';
    end
    else
      Cur := Cur + S[k];
end;

{ the metric names a help lists: [Group] and (notes) left out, "a = b" is a, "x: y" is y }
procedure HelpNames(First, Last: LongInt; Names: TStringList);
var
  k, i, p: LongInt;
  T, Item: AnsiString;
  Items, Words: TStringArray;
begin
  for k := First to Last do
  begin
    T := Lines[k];
    repeat
      p := Pos('[', T);
      if p = 0 then
        Break;
      Delete(T, p, Pos(']', T) - p + 1);
    until False;
    repeat
      p := Pos('(', T);
      if p = 0 then
        Break;
      Delete(T, p, Pos(')', T) - p + 1);
    until False;
    T := StringReplace(T, ';', ',', [rfReplaceAll]);
    Items := SplitAt(T, ',');
    for i := 0 to High(Items) do
    begin
      Item := Items[i];
      if Pos('=', Item) > 0 then
        Item := Copy(Item, 1, Pos('=', Item) - 1);
      if Pos(':', Item) > 0 then
        Item := Copy(Item, Pos(':', Item) + 1, MaxInt);
      Words := SplitWords(Trim(Item));
      for p := 0 to High(Words) do
        if Words[p] <> '' then
          Names.Add(Words[p]);
    end;
  end;
end;

{ every name of a help (from the rule under its title to its footer) is a metric of the command }
function HelpNamesWork(const Cmd, Refused: AnsiString): Boolean;
var
  Names: TStringList;
  k, First, Last: LongInt;
begin
  Result := True;
  Run(Cmd + ' help');
  First := -1;
  Last := -1;
  for k := 0 to Lines.Count - 1 do
    if (Lines[k] <> '') and (Lines[k][1] = '-') and (First < 0) then
      First := k + 1
    else if (Lines[k] <> '') and (Lines[k][1] = '=') and (k > 0) then
      Last := k - 1;
  if (First < 0) or (Last < First) then
    Exit(False);
  Names := TStringList.Create;
  try
    HelpNames(First, Last, Names);
    if Names.Count < 20 then
    begin
      WriteLn('       only ', Names.Count, ' names in the help of ', Cmd);
      Exit(False);
    end;
    for k := 0 to Names.Count - 1 do
    begin
      Run(Cmd + ' ' + Names[k]);
      if Has(Refused) or Has('[Note] Ignored') then
      begin
        WriteLn('       ', Cmd, ' help names "', Names[k], '", which is no metric');
        Result := False;
      end;
    end;
  finally
    Names.Free;
  end;
end;

{ a word nan, inf or infinity in a line: a division by zero that reached the text }
function NotANumber(const Line: AnsiString): Boolean;
var
  k: LongInt;
  W: AnsiString;
begin
  Result := False;
  W := '';
  for k := 1 to Length(Line) + 1 do
    if (k <= Length(Line)) and (Line[k] in ['a'..'z', 'A'..'Z']) then
      W := W + LowerCase(Line[k])
    else
    begin
      if (W = 'nan') or (W = 'inf') or (W = 'infinity') then
        Exit(True);
      W := '';
    end;
end;

function Prof(const Steam: AnsiString): PPlayerProfile;
var
  Idx: LongInt;
begin
  Idx := Engine.DB.IndexOfSteam(Steam);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx]
  else
    Result := nil;
end;

procedure SetAk(P: PPlayerProfile);
var
  W: PWeaponStats;
begin
  P^.Kills := 15135;
  P^.Deaths := 3000;
  P^.Points := 12345;
  P^.Shots := 165600;
  P^.ShotsHits := 42000;
  P^.ShotsHitsHead := 5000;
  P^.DamageDealt := 2500000;
  P^.DamageReceived := 400000;
  W := @P^.Weapons[WEP_AK74];
  W^.Kills := 15135;
  W^.Deaths := 2000;
  W^.Shots := 165600;
  W^.Hits := 42000;
  W^.Headshots := 5000;
  W^.HitsBody := 30000;
  W^.HitsLegs := 7000;
  W^.HSKills := 1500;
  W^.Damage := 2500000;
  W^.DamageReceived := 400000;
  W^.TimeUsedSeconds := 400000;
  W^.LongestKill := 87.5;
  { the reported row: 2.78 s against the 2.63 s of weapons.ini }
  W^.Reloads := 9000;
  W^.ReloadsManual := 3000;
  W^.RoundsDropped := 21000;
  W^.ReloadsDone := 8000;
  W^.ReloadsCut := 700;
  W^.ReloadDeaths := 300;
  W^.ReloadTimed := 1000;
  W^.ReloadTicks := 166800;
  W^.ReloadNormTicks := 157800;
  W^.ReloadEnds := 9000;
  W^.ReloadDoneMille := 8100000;
  W^.ReloadDeathMille := 135000;
  W^.ReloadTicksAll := 1350000;
  { melee and thrown: hits without shots of their own }
  P^.Weapons[WEP_CHAINSAW].Kills := 12;
  P^.Weapons[WEP_CHAINSAW].Hits := 57;
  P^.Weapons[WEP_CHAINSAW].Damage := 5000;
  P^.Weapons[WEP_CHAINSAW].TimeUsedSeconds := 300;
  P^.Weapons[WEP_KNIFE].Kills := 3;
  P^.Weapons[WEP_KNIFE].Shots := 10;
  P^.Weapons[WEP_KNIFE].Hits := 4;
  P^.Weapons[WSLOT_FISTS].Kills := 2;
  P^.Weapons[WSLOT_FISTS].Hits := 5;
end;

var
  Root, L, H: AnsiString;
  A, B, C: PPlayerProfile;
  M, k, Idx, Col: LongInt;
  Ok: Boolean;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'cmd_lists_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Lines := TStringList.Create;
  All := TStringList.Create;

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);

  { the owner's server: realistic survival deathmatch on an RSCS map }
  CurTick := 0;
  MapAfter('RSCS_Arena', GS_DM, 30, MF_SURVIVAL or MF_REALISTIC);
  Join(1, 'Alice', 'S1001', 'HWA', '1.1.1.1', 0);
  Join(2, 'Bob', 'S1002', 'HWB', '2.2.2.2', 0);
  Join(3, 'Carl', 'S1003', 'HWC', '3.3.3.3', 0);
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_BARRETT, 1500, 100);
  Spawn(3, WEP_MP5, 120, 100);
  CurTick := 100;
  Kill(1, 2, WEP_AK74, WEP_BARRETT, 100, 100, 1500, 100);
  Check('events processed', WaitProcessed);

  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    C := Prof('S1003');
    Check('accounts made by the joins', (A <> nil) and (B <> nil) and (C <> nil));
    if (A = nil) or (B = nil) or (C = nil) then
      Halt(1);
    SetAk(A);
    B^.Kills := 40;
    B^.Deaths := 50;
    B^.Points := 900;
    C^.Kills := 2;
    C^.Deaths := 7;
    Engine.DB.RebuildRanks;
    { the server: the kill distances of the AK, its duels (with itself most), no picks counted }
    with Engine.DB.Server.WeaponGlobal[WEP_AK74] do
    begin
      DistBucket[0] := 120;
      DistBucket[1] := 3400;
      DistBucket[2] := 5000;
      DistBucket[3] := 1200;
      DistBucket[4] := 3;
      KillDistSum := 9723 * 31.5;
      KillDistCount := 9723;
      TTKSumTicks := 9723 * 40;
      TTKCount := 9723;
      VestKills := 0;
      Picks := 0;
    end;
    Engine.DB.Server.Matchups[WEP_AK74, WEP_AK74] := 500;
    Engine.DB.Server.Matchups[WEP_AK74, WEP_BARRETT] := 120;
    Engine.DB.Server.Matchups[WEP_BARRETT, WEP_AK74] := 80;
    { the map: counters of an earlier team match (or of a server that shares the map) }
    M := Engine.Match.MapIndex;
    Check('the match runs on the map', (M >= 0) and (M < Engine.DB.MapCount));
    with Engine.DB.Maps[M] do
    begin
      Kills := 15135;
      Selfkills := 44;
      ActiveMapPlays := 20;
      ActiveTimePlays := 36000;
      AlphaWins := 10;
      BravoWins := 8;
      Draws := 3;
      CloseMatches := 4;
      ComebackMatches := 2;
      AlphaRoundWins := 40;
      BravoRoundWins := 35;
      HealRegen := 12345.6;
      SetLength(Heat, 3);
      Heat[0].Cell := (2048 + 1) * 4096 + 2048 + 1;
      Heat[0].Kills := 12;
      Heat[0].Deaths := 3;
      Heat[1].Cell := (2048 + 3) * 4096 + 2048 + 20;
      Heat[1].Kills := 2;
      Heat[1].Deaths := 9;
      Heat[2].Cell := (2048 + 6) * 4096 + 2048 + 40;
      Heat[2].Kills := 1;
      Heat[2].Deaths := 1;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- rankings ---- }
  Run('/top');
  Check('!top: title, 100 columns', Has('Top Ranking [Page 1/1]') and Fits);
  Check('!top: points and kills shortened (12.3k, 15.1k)', Has('12.3k') and Has('15.1k') and not Has('12345') and not Has('15135'));
  Check('!top: every cell under its header', RowsUnderHeader(HeaderLine('#    Nick')));
  Run('/topby kills');
  Check('!topby kills: the metric shortened too', Has('15.1k') and not Has('15135') and Fits);
  Check('!topby kills: every cell under its header', RowsUnderHeader(HeaderLine('#    Nick')));
  Run('/topby dmg;kills;acc;hs;healed');
  Check('!topby with five metrics fits', Has('Top by Damage > Kills > Acc% > HS > Healed') and Fits and
    RowsUnderHeader(HeaderLine('#    Nick')));
  Run('/topby tier');
  Check('!topby tier fits', Fits);
  Run('/topby akacc');
  Check('!topby akacc: the accuracy of a gun', Has('25.4%') and Fits);
  Run('/topby sawacc');
  Check('!topby sawacc: no accuracy for a chainsaw', not Has('100.0%') and Fits);
  Run('/topby help');
  Check('!topby help: 100 columns', Has('!topby Help') and Fits);
  Check('!topby help: every name in it is a metric', HelpNamesWork('/topby', 'No valid metric given.'));
  Check('!topweaponsby help: every name in it is a metric', HelpNamesWork('/topweaponsby', 'No valid weapon metric given.'));
  Check('!topmapsby help: every name in it is a metric', HelpNamesWork('/topmapsby', 'No valid map metric given.'));
  Run('/topo');
  Check('!topo fits', Has('Online Ranking (3 Players)') and Fits and RowsUnderHeader(HeaderLine('#    Nick'), 'Sorted by'));
  Run('/topskill');
  Check('!topskill fits', Fits);
  Run('/topday');
  Check('!topday fits', Fits);
  Run('/topseason');
  Check('!topseason fits', Has('Season 1') and Fits);
  Run('/topseason 7');
  Check('!topseason of a season that is not archived', Has('No archived season'));
  Run('/seasons');
  Check('!seasons fits', Has('1st place') and Fits and At(LineOf('1st place'), 31, '1st place'));
  Run('/zs_search ali');
  Check('!zs_search: points shortened, fits', Has('Search: "ali" (1 matches)') and Has('12.3k') and Fits);
  Run('/searcha a');
  Check('admin search fits', Has('Admin Search') and Fits);

  { ---- maps ---- }
  Run('/mapstats');
  Check('!mapstats: title, 100 columns', Has('[ Map Statistics: RSCS_Arena ]') and Fits);
  Check('!mapstats: kills shortened, healing shown', Has('Kills: 15.1k') and Has('Healing: 12.3k HP'));
  Check('!mapstats on DM: no team balance, no win bias, no base gap', not Has('Survival Round Balance') and
    not Has('Match Win Bias') and not Has('Alpha') and not Has('Base Gap'));
  Check('!mapstats on DM: no draws, close games or comebacks (team matches only)', not Has('Draws:') and
    not Has('Close:') and not Has('Comebacks:'));
  Check('!mapstats on DM: no objective rows', not Has('Objective Telemetry'));
  Check('!mapstats on DM survival: leaders without team rounds', Has('[Kills]') and Has('[Points]') and not Has('[Rounds]'));
  L := LineOf('Time: ');
  Check('!mapstats: four columns of 25', At(L, 26, 'Matches: ') and At(L, 51, 'Kills: ') and At(L, 76, 'Selfkills: '));
  Run('/topmaps');
  Check('!topmaps on DM: selfkills, not flags', Has('Top Maps [Page 1/1]') and Has('Selfs') and not Has('Caps') and Fits);
  Run('/topmapsby pace');
  Check('!topmapsby fits', Has('Top Maps by Kills/min') and Fits);
  Run('/topmapsby kills;time;joins;leaves;quitrate');
  Check('!topmapsby with five metrics and the <actual> mark fits', Has('<actual>') and Fits);
  Run('/heatmap');
  Check('!heatmap: 100 columns, the picture in the middle', Has('Where people die: RSCS_Arena') and Fits and
    At(LineOf('+-----'), 20, '+-') and (Length(LineOf('+-----')) = 19 + 62));
  Check('!heatmap without flags: the legend has no bases', Has('few . : + * # @ many') and not Has('flag bases'));

  { ---- weapons ---- }
  Run('/wep ak alice');
  Check('!wep ak: title, 100 columns', Has('Weapon: AK-74 - Alice') and Fits);
  Check('!wep ak: counters shortened', Has('Kills: 15.1k') and Has('Shots: 166k') and Has('Hits: 42.0k (25.4%)') and
    not Has('15135'));
  L := LineOf('Avg reload: ');
  Check('!wep ak: the reported reload row, the second cell at column 51', (Pos('Avg reload: 2.78s (standard 2.63s)', L) = 1) and
    At(L, 51, 'Avg progress of a reload: 90%'));
  Check('!wep ak: the other reload rows in the same columns', At(LineOf('Reloads: '), 51, 'Finished: 88.9%, broken off: 700') and
    At(LineOf('Killed reloading: '), 51, 'At death: 45% of the reload done') and At(LineOf('Rounds thrown away: '), 51, 'Time reloading: '));
  L := LineOf('Kills: 15.1k');
  Check('!wep ak: three columns of 36, 34 and 30', At(L, 37, 'Deaths: ') and At(L, 71, 'K/D: '));
  Idx := IndexOfLine('Kill distance');
  Ok := Idx >= 0;
  if Ok then
  begin
    H := Lines[Idx];
    for k := 0 to 4 do
    begin
      Col := Pos(DIST_NAMES[k], H);
      Ok := Ok and (Col > 0) and (Lines[Idx + 1][Col] <> ' ') and (Lines[Idx + 1][Col - 1] = ' ') and
        (Lines[Idx + 2][Col] = '#') and (Lines[Idx + 2][Col - 1] = ' ');
    end;
  end;
  Check('!wep ak: kill distance names, shares and bars in the same columns', Ok);
  Check('!wep ak: a range with a kill has a bar', Pos('#', Copy(Lines[Idx + 2], Pos('100m+', H), 20)) > 0);
  Check('!wep ak: nemesis and top victim without the AK itself', Has('Nemesis: Barrett (80)') and Has('Top Victim: Barrett (120)'));
  Check('!wep ak: no vest kills row without vest kills, no share without picks', not Has('Vest kills') and
    Has('Of primaries: -'));
  Check('!wep ak on DM: no team picks', not Has('Alpha picks'));
  Run('/wep saw alice');
  Check('!wep saw: hits without an accuracy, no shots, no kills per shot', Has('Hits: 57') and not Has('Hits: 57 (') and
    Has('Shots: -') and Has('Kills/Shot: -') and Fits);
  Run('/wep knife alice');
  Check('!wep knife: its throws are its shots, but no kills per shot and no zones', Has('Shots: 10') and Has('Kills/Shot: -') and
    not Has('Head: ') and Fits);
  Run('/wep minigun alice');
  Check('!wep minigun with nothing: dashes instead of zero ratios', Has('Dmg/Kill: -') and Has('Dmg Ratio: -') and
    Has('Avg Dmg/Hit: -') and Has('HS Lethality: -') and Has('Longest Kill: -') and Has('Dmg/min: -') and
    Has('Hits/Kill: -') and Has('No reloads counted yet.') and Fits);
  Run('/allweapons alice');
  Check('!allweapons: 100 columns, cells under their headers', Has('All Weapons Breakdown: Alice') and Fits and
    RowsUnderHeader(HeaderLine('Weapon '), 'Damage & Combat'));
  L := LineOf('Chainsaw');
  Check('!allweapons: no accuracy or shots for the chainsaw', (L <> '') and (Pos('100.0%', L) = 0));
  Run('/serverweapons');
  Check('!serverweapons: 100 columns, cells under their headers, pick shares without picks are -',
    Has('All Weapons Breakdown: the whole server') and Fits and RowsUnderHeader(HeaderLine('Weapon '), 'Server totals') and
    (Pos(' - ', LineOf('AK-74')) > 0));
  Check('!serverweapons: gun accuracy as in !stats, no repeated damage-in cells', Has('Hits: 42.0k (25.4%)') and
    not Has('Dmg/Death') and not Has('K-D Dmg'));
  Check('!serverweapons on DM: no teamkill cells without teamkills', not Has('TK Kills'));
  Run('/serverwep ak');
  Check('!serverwep ak fits, no damage-in rows', Has('Weapon: AK-74 - the whole server') and Fits and not Has('Dmg In') and
    Has('Dmg/Hit: '));
  Run('/serverwep saw');
  Check('!serverwep saw: no accuracy', Has('Hits: 57') and not Has('Hits: 57 (') and not Has('Best accuracy') and Fits);
  Run('/topweapons');
  Check('!topweapons fits', Has('Top Weapons by Kills') and Fits and RowsUnderHeader(HeaderLine('#    Weapon')));
  Run('/topweaponsby acc');
  Check('!topweaponsby acc: the AK first, the chainsaw with - after it', Pos('AK-74', Lines[HeaderLine('#    Weapon') + 2]) > 0);
  L := LineOf('Chainsaw');
  Check('!topweaponsby acc: - for the chainsaw', (L <> '') and (Pos('Chainsaw          -', L) > 0));
  Run('/topweaponsby killeq;deatheq;dmgperkill;dmgperdeath;kdmgratio');
  Check('!topweaponsby with the damage metrics fits', Fits and RowsUnderHeader(HeaderLine('#    Weapon')));
  Run('/topweaponsby reloadtime;finished;progress;rdeath%;pick%');
  Check('!topweaponsby reload metrics fit, - where a weapon has none', Fits and Has('Knife') and
    RowsUnderHeader(HeaderLine('#    Weapon')));
  Run('/matchup');
  Check('!matchup fits', Has('Top Rivalries') and Fits);
  Run('/matchup ak');
  Check('!matchup ak fits', Has('Matchups: AK-74 [Page 1/1]') and Fits);
  { the chainsaw comes after every weapon with shots, on the second page }
  Run('/topweaponsby shots 2');
  Check('!topweaponsby shots: - for the chainsaw, which has no shots of its own, after the weapons with shots',
    Has('Top Weapons by Shots [Page 2/2]') and (Pos('Chainsaw          -', LineOf('Chainsaw')) > 0));

  { ---- the weapon tables by metrics: !allweaponsby, !allweaponsbyi, !serverweaponsby ---- }
  Run('/allweaponsby acc alice');
  Idx := HeaderLine('Weapon ');
  Check('!allweaponsby acc: title, 100 columns, cells under their headers',
    Has('All Weapons by Acc%: Alice') and Fits and RowsUnderHeader(Idx, 'Best first'));
  Ok := Idx >= 0;
  if Ok then
  begin
    H := Lines[Idx];
    Ok := (Pos('Acc%', H) > 0) and (Pos('Acc%', H) < Pos('Kills', H)) and (Pos('Acc%', Copy(H, Pos('Acc%', H) + 4, MaxInt)) = 0) and
      (Pos('AK-74', Lines[Idx + 2]) = 1) and (Pos('Chainsaw', Lines[Idx + 3]) = 1) and At(Lines[Idx + 3], Pos('Acc%', H), '- ') and
      (Pos('Combat Knife', Lines[Idx + 4]) = 1) and (Pos('Fists', Lines[Idx + 5]) = 1);
  end;
  Check('!allweaponsby acc: the sort column once, right after the weapon; the AK first, then the weapons without an ' +
    'accuracy by their kills', Ok);
  Check('!allweaponsby acc: every weapon of !allweapons', (Idx >= 0) and Has('USSOCOM') and Has('M72 LAW') and
    Has('Best first, "-" (no such value for the weapon) last.'));
  Run('/allweaponsby reloads alice');
  Idx := HeaderLine('Weapon ');
  Ok := Idx >= 0;
  if Ok then
    Ok := (Pos('AK-74', Lines[Idx + 2]) = 1) and At(Lines[Idx + 2], Pos('Reloads', Lines[Idx]), '9000') and
      At(LineOf('Combat Knife'), Pos('Reloads', Lines[Idx]), '- ');
  Check('!allweaponsby reloads: a metric that is no column of !allweapons gets one; no reloads for a knife',
    Has('All Weapons by Reloads: Alice') and Ok and Fits and RowsUnderHeader(Idx, 'Best first'));
  Run('/allweaponsby kd; acc alice');
  Check('!allweaponsby: metrics joined by ";" with a space after it, then the player', Has('All Weapons by K/D > Acc%: Alice'));
  Run('/allweaponsby reloads;finished;progress;rdeath%;manual alice');
  Check('!allweaponsby with five metrics fits, cells under their headers',
    Has('All Weapons by Reloads > Finished% > Progress% > DiedRel% > Manual%: Alice') and Fits and
    RowsUnderHeader(HeaderLine('Weapon '), 'Best first'));
  Run('/allweaponsby picks alice');
  Check('!allweaponsby: a metric of the whole server only is refused and named', Has('No valid weapon metric given.') and
    Has('[Note] Counted for the whole server only (!serverweaponsby): picks') and Has('!allweaponsby Help'));
  Run('/allweaponsby kills;zzz alice');
  Check('!allweaponsby: an unknown metric is named, the others sort', Has('All Weapons by Kills: Alice') and
    Has('[Note] Ignored unknown metric(s): zzz'));
  Run('/allweaponsby kills');
  Check('!allweaponsby on the console without a player: name one', Has('The console has no statistics of its own'));
  Run('/allweaponsbyi kills 1');
  Check('!allweaponsbyi: the first place of the ranking', Has('All Weapons by Kills: Alice'));
  Run('/allweaponsby kills 1');
  Check('!allweaponsby with a number: a player of that name, and the "i" command for the place', Has('Player not found.') and
    Has('For ranking position 1: !allweaponsbyi kills 1'));
  Run('/weaponsby dmg alice');
  Check('!weaponsby is !allweaponsby', Has('All Weapons by Damage: Alice'));
  Check('!allweaponsby help: every name in it is a metric', HelpNamesWork('/allweaponsby', 'No valid weapon metric given.'));
  Check('!serverweaponsby help: every name in it is a metric', HelpNamesWork('/serverweaponsby', 'No valid weapon metric given.'));
  Run('/serverweaponsby kills');
  Idx := HeaderLine('Weapon ');
  Ok := Idx >= 0;
  if Ok then
    Ok := (Pos('Share', Lines[Idx]) > 0) and (Pos('Pick%', Lines[Idx]) > 0) and (Pos('Deaths', Lines[Idx]) = 0) and
      (Pos('AK-74', Lines[Idx + 2]) = 1);
  Check('!serverweaponsby kills: the table of !serverweapons sorted, 100 columns, cells under their headers',
    Has('All Weapons by Kills: the whole server') and Ok and Fits and RowsUnderHeader(Idx, 'Best first'));
  Run('/serverweaponsby shots');
  Idx := HeaderLine('Weapon ');
  Check('!serverweaponsby shots: the chainsaw has no shots of its own',
    (Idx >= 0) and At(LineOf('Chainsaw'), Pos('Shots', Lines[Idx]), '- '));
  Run('/serverweaponsby avgdist;picks;zzz');
  Check('!serverweaponsby takes the metrics of the server record', Has('All Weapons by AvgDist > Picks: the whole server') and
    Has('[Note] Ignored unknown metric(s): zzz') and Fits);

  { ---- the kits picked up: !topby ---- }
  EnterCriticalSection(Engine.StateLock);
  try
    A^.KitPickups[0] := 12340;
    A^.KitPickups[6] := 5;
    A^.HealKitCount := 40;
    B^.KitPickups[1] := 7;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/topby kits');
  Idx := HeaderLine('#    Nick');
  Check('!topby kits: every kit picked up, shortened, the most first', Has('Top by Kits [Page 1/1]') and (Idx >= 0) and
    (Pos('1    Alice', LineOf('Alice')) = 1) and At(LineOf('Alice'), Pos('Kits', Lines[Idx]), '12.3k') and
    (Pos('2    Bob', LineOf('Bob')) = 1) and Fits);
  Run('/topby healkits');
  Check('!topby healkits: the kits that healed', Has('Top by HealKits [Page 1/1]') and At(LineOf('Alice'),
    Pos('HealKits', Lines[HeaderLine('#    Nick')]), '40'));
  Run('/topby medkits;nadekits;clusterkits;vestkits;berserkkits');
  Check('!topby with five kinds of kit fits', Has('Top by MedKits > NadeKits > ClusterKits > VestKits > BerserkKits') and
    Fits and RowsUnderHeader(HeaderLine('#    Nick')));
  Run('/topby predatorkits;flamerkits');
  Check('!topby predatorkits;flamerkits', Has('Top by PredatorKits > FlamerKits [Page 1/1]') and Fits);

  { ---- the players by one weapon: !topweapons <weapon> [page] ---- }
  EnterCriticalSection(Engine.StateLock);
  try
    with B^.Weapons[WEP_AK74] do
    begin
      Kills := 20;
      Shots := 300;
      Hits := 90;
      Headshots := 9;
      Damage := 2500;
      TimeUsedSeconds := 600;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/topweapons ak');
  Check('!topweapons ak: the players with the AK, 100 columns, every cell under its header',
    Has('Top Players with AK-74 [Page 1/1] (2 players)') and Fits and RowsUnderHeader(HeaderLine('#    Nick')));
  Idx := HeaderLine('#    Nick');
  L := LineOf('Alice');
  Check('!topweapons ak: the most kills first, with the kills, deaths, K/D, Acc%, HS%, damage, time and longest kill',
    (Idx >= 0) and (Pos('1    Alice', L) = 1) and At(L, Pos('Kills', Lines[Idx]), '15.1k') and
    At(L, Pos('Deaths', Lines[Idx]), '2000') and At(L, Pos('K/D', Lines[Idx]), '7.57') and
    At(L, Pos('Acc%', Lines[Idx]), '25.4%') and At(L, Pos('HS%', Lines[Idx]), '11.9%') and
    At(L, Pos('Damage', Lines[Idx]), '2.5M') and At(L, Pos('Time', Lines[Idx]), '4d 15h') and
    At(L, Pos('Longest', Lines[Idx]), '87.5m') and (Pos('2    Bob', LineOf('Bob')) = 1));
  Check('!topweapons ak: - for a kill distance that was never measured', At(LineOf('Bob'), Pos('Longest', Lines[Idx]), '-'));
  Run('/topweapons knife');
  Idx := HeaderLine('#    Nick');
  L := LineOf('Alice');
  Check('!topweapons knife: no accuracy, no head share, no time and no distance for a knife', (Idx >= 0) and
    At(L, Pos('Acc%', Lines[Idx]), '- ') and At(L, Pos('HS%', Lines[Idx]), '- ') and At(L, Pos('Time', Lines[Idx]), '- ') and
    At(L, Pos('Longest', Lines[Idx]), '-') and At(L, Pos('K/D', Lines[Idx]), '3.00') and Fits);
  Run('/topweps ak');
  Check('!topweps is !topweapons', Has('Top Players with AK-74'));
  Run('/topweapons ruger 77');
  Check('!topweapons ruger 77: a name that ends in a number is no page', Has('Nobody has used the Ruger 77 yet.'));
  Run('/topweapons 2');
  Check('!topweapons 2: a number alone is a page of the weapons', Has('Top Weapons by Kills [Page 2/2]'));
  Run('/topweapons kd');
  Check('!topweapons kd: a metric sorts the weapons as !topweaponsby', Has('Top Weapons by K/D'));
  Run('/topweapons zzzz');
  Check('!topweapons with no weapon says so and how it is used', Has('Unknown weapon: zzzz') and
    Has('Usage: !topweapons [page]'));
  { the caller's own row is marked }
  RunAs(1, '/topweapons ak');
  Check('!topweapons ak: the caller''s row says <YOU>', (Pos('<YOU>', LineOf('Alice')) > 0) and
    (Pos('<YOU>', LineOf('Bob')) = 0) and Fits);
  { twenty more players with the AK: two pages, and /zs_next, /zs_prev and a page number reach them }
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 1 to 20 do
    begin
      M := Engine.DB.CreateProfile(Format('Gunner%.2d', [k]), '', Format('HWG%d', [k]), '9.9.9.9', 1000);
      Engine.DB.Profiles[M]^.Weapons[WEP_AK74].Kills := k;
      Engine.DB.Profiles[M]^.Weapons[WEP_AK74].Shots := 10 * k;
      Engine.DB.Profiles[M]^.Weapons[WEP_AK74].Hits := k;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/topweapons ak');
  Check('!topweapons ak: fifteen to a page with a page hint, a tie of kills goes to more damage',
    Has('Top Players with AK-74 [Page 1/2] (22 players)') and Has('Page 1/2 - /zs_next') and
    (Pos('2    Bob', LineOf('Bob')) = 1) and (Pos('3    Gunner20', LineOf('Gunner20')) = 1) and
    (Pos('15   Gunner08', LineOf('Gunner08')) = 1) and Fits);
  Run('/zs_next');
  Check('/zs_next after !topweapons ak: the second page of the players', Has('Top Players with AK-74 [Page 2/2]') and
    (Pos('16   Gunner07', LineOf('Gunner07')) = 1) and (Pos('22   Gunner01', LineOf('Gunner01')) = 1));
  Run('/zs_prev');
  Check('/zs_prev goes back to the first page', Has('Top Players with AK-74 [Page 1/2]'));
  Run('/topweapons ak 2');
  Check('!topweapons ak 2: the page after the weapon', Has('Top Players with AK-74 [Page 2/2]'));

  { ---- balance on DM ---- }
  Run('/bal');
  Check('!bal on DM: no teams to balance', Has('no teams'));

  { ---- CTF on the same server ---- }
  MapAfter('ctf_Test', GS_CTF, 10, 0);
  Check('map change processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.Match.MapIndex;
    with Engine.DB.Maps[M] do
    begin
      Kills := 500;
      ActiveMapPlays := 12;
      AlphaWins := 7;
      BravoWins := 5;
      Draws := 1;
      FlagsScore := 30;
      FlagsReturns := 12;
      FlagsGrabs := 60;
      AlphaFlagX := 100;
      AlphaFlagY := 200;
      BravoFlagX := 1500;
      BravoFlagY := 200;
      FastestCapSeconds := 9.5;
      FastestCapHolder := 'Alice';
    end;
    { years of predicted matches: the counts of a tenth no longer fit "wins/matches" in 7 }
    Engine.DB.Server.BalPredCount := 16000;
    Engine.DB.Server.BalBrierSum := 16000 * 0.21;
    for k := 0 to 9 do
    begin
      Engine.DB.Server.BalBinCount[k] := 1500 + k;
      Engine.DB.Server.BalBinWins[k] := 700 + k * 90;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/mapstats');
  Check('!mapstats on CTF: win bias, base gap, draws and objectives', Has('Match Win Bias') and Has('Base Gap: 100 m') and
    Has('Draws: 1') and Has('Objective Telemetry') and Has('[Caps]') and Fits);
  Run('/topmaps');
  Check('!topmaps on CTF: captures', Has('Caps') and not Has('Selfs') and Fits);
  Run('/heatmap RSCS');
  Check('!heatmap of another map by a part of its name', Has('Where people die: RSCS_Arena'));
  { /balinfo is an admin command of the engine (AdminCommand), which calls this }
  RunBalanceInfo;
  Check('/balinfo fits', Has('Team Balance - details') and Has('Last decisions') and Has('Alpha won') and Fits);
  Run('/bal');
  Check('!bal on CTF fits', Has('Team Balance') and Fits);

  { ---- the whole run ---- }
  Ok := True;
  for k := 0 to All.Count - 1 do
    if NotANumber(All[k]) then
    begin
      WriteLn('       ', All[k]);
      Ok := False;
    end;
  Check('no NaN or Inf anywhere', Ok);
  Check('every metric name belongs to one metric only: ' + DuplicateAlias, DuplicateAlias = '');
  All.SaveToFile(Root + PathDelim + 'console_dump.txt');

  Engine.Free;
  Lines.Free;
  All.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  if Failures > 0 then
    Halt(1);
end.
