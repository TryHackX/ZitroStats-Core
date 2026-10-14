program test_cmd_lists;

{ The tables of the rankings, maps, weapons and team balance (zs_cmd_lists, zs_cmd_maps,
  zs_cmd_weapons, zs_cmd_balance): every line fits LINE_W, the cells of a row stand under their
  headers, big counters are shortened, nothing is divided by zero, and the rows of teams, flags
  and rounds show only in the modes that have them. The commands run on the server console of an
  engine that got a few players and a match through its events. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_engine, zs_commands, zs_weapons, zs_fields, zs_matrix;

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

{ A table whose headers may have more words: in every row from the line after the header to the
  end of the table (as RowsUnderHeader), a cell starts at the column of each of Heads and nothing of
  the cell before reaches it. }
function CellsAt(HeaderIdx: LongInt; const Heads: array of AnsiString; const Stop: AnsiString = ''): Boolean;
var
  k, h, p: LongInt;
  R: AnsiString;
begin
  Result := HeaderIdx >= 0;
  if not Result then
    Exit;
  for k := HeaderIdx + 1 to Lines.Count - 1 do
  begin
    R := Lines[k];
    if (Stop <> '') and (Pos(Stop, R) > 0) then
      Break;
    if (R <> '') and (R[1] = '-') then
      Continue;
    if (R = '') or (R[1] = '=') or (Pos('Page ', R) = 1) or (Pos('[Note]', R) = 1) then
      Break;
    for h := 0 to High(Heads) do
    begin
      p := Pos(Heads[h], Lines[HeaderIdx]);
      if (p <= 1) or (p > Length(R)) or (R[p - 1] <> ' ') or (R[p] = ' ') then
      begin
        WriteLn('       no cell at the column of ', Heads[h], ':');
        WriteLn('       ', Lines[HeaderIdx]);
        WriteLn('       ', R);
        Exit(False);
      end;
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

{ <Cmd> help of a list of the per-map data names its sort flags (from the rule under its title to its
  footer) in the order of Heads, then asc; each of them orders the list of "<Cmd> <flag><Args>", whose
  title (or section) says it: Mark + head + After, asc as "<first head> (asc)" }
function FlagHelpWorks(const Cmd, Args: AnsiString; const Heads: array of AnsiString; const Mark, After: AnsiString): Boolean;
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
  if (First < 0) or (Last < First) or not Fits then
    Exit(False);
  Names := TStringList.Create;
  try
    HelpNames(First, Last, Names);
    if (Names.Count <> Length(Heads) + 1) or (Names[Names.Count - 1] <> 'asc') then
    begin
      WriteLn('       ', Cmd, ' help names ', Names.CommaText);
      Exit(False);
    end;
    for k := 0 to High(Heads) do
    begin
      Run(Cmd + ' ' + Names[k] + Args);
      if not Has(Mark + Heads[k] + After) or not Fits then
      begin
        WriteLn('       ', Cmd, ' ', Names[k], Args, ': no "', Mark, Heads[k], After, '"');
        Result := False;
      end;
    end;
    Run(Cmd + ' asc' + Args);
    if not Has(Mark + Heads[0] + ' (asc)' + After) then
    begin
      WriteLn('       ', Cmd, ' asc', Args, ': no "', Mark, Heads[0], ' (asc)', After, '"');
      Result := False;
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
  { the account's own kill distances and times to kill (the server's are in WeaponGlobal) }
  W^.DistBucket[0] := 10;
  W^.DistBucket[1] := 200;
  W^.DistBucket[2] := 300;
  W^.DistBucket[3] := 50;
  W^.DistBucket[4] := 2;
  W^.KillDistSum := 562 * 30.0;
  W^.KillDistCount := 562;
  W^.TTKSumTicks := 562 * 45;
  W^.TTKCount := 562;
  W^.VestKills := 3;
  { [Bridges] (5.6): the hits measured from where and when their bullets were made }
  W^.HitDistSum := 4000 * 12.5;
  W^.HitDistCount := 4000;
  W^.LongestHit := 61.5;
  W^.HitAirTicks := 4000 * 6;
  W^.HitAirCount := 4000;
  W^.KillAirTicks := 500 * 9;
  W^.KillAirCount := 500;
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
  RA, RB, RL, RC: PPlayerMapStats;
  PW: PPMWeapon;
  PR: PPMRival;
  PX: PPMMatchup;
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
      { how the survival rounds ended: free-for-all ones, and team ones from an earlier team match }
      RoundsLastStanding := 40;
      RoundsNoSurvivor := 5;
      RoundsMapChange := 2;
      RoundsElimination[1] := 6;
      HealRegen := 12345.6;
      { [Bridges] (5.6): the hits and kills measured here }
      HitDistSum := 2000 * 18.5;
      HitDistCount := 2000;
      LongestHit := 95.5;
      HitAirTicks := 2000 * 12;
      HitAirCount := 2000;
      KillAirTicks := 300 * 15;
      KillAirCount := 300;
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
  Check('!mapstats: the time played with the statistics on, the last game and the last load',
    (Pos('Played Time: 10h 0m', L) = 1) and Has('Last Played: ') and Has('Last Loaded: ' + FormatDateTime('dd.mm.yy', Now)));
  L := LineOf('Last one standing: ');
  Check('!mapstats on DM survival: how the rounds ended, without teams, the team rounds of before as one count',
    Has('How the Survival Rounds Ended') and (Pos('Last one standing: 40', L) = 1) and At(L, 37, 'Team rounds: 6') and
    At(L, 71, 'No survivor: 5') and Has('Cut by map change: 2') and not Has('elimination') and not Has('Kill Balance'));
  Check('!mapstats: the range of the hits here', Has('Range on this Map') and Has('Longest Hit: 95.5m') and
    Has('Avg Hit Dist: 18.5m') and Has('Avg Hit Air: 0.20s') and Has('Avg Kill Air: 0.25s') and
    Has('From 2000 hits and 300 kills measured here since 5.6.'));
  Run('/topmaps');
  Check('!topmaps on DM: selfkills, not flags', Has('Top Maps [Page 1/1]') and Has('Selfs') and not Has('Caps') and Fits);
  Run('/topmapsby hitdist;longesthit;hitair;killair');
  Check('!topmapsby by the range metrics', Has('Top Maps by HitDist > LongHit > HitAir > KillAir') and
    (Pos('18.5m', LineOf('RSCS_Arena')) > 0) and (Pos('95.5m', LineOf('RSCS_Arena')) > 0) and Fits);
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
  { the player's own kill distances, times to kill and vest kills, not the server's }
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
    Ok := Ok and At(Lines[Idx + 1], Pos('<10m', H), '1.8%') and At(Lines[Idx + 1], Pos('100m+', H), '0.4%');
  end;
  Check('!wep ak: the player''s own kill distances, shares and bars in the columns of the names', Ok);
  Check('!wep ak: the player''s own distance, time to kill and vest kills', Has('Distances and times to kill') and
    Has('Avg Kill Dist: 30.0m') and Has('Avg TTK: 0.75s') and Has('Vest kills: 3'));
  Check('!wep ak: the hits'' distance and air time and the kills'' air time of the player',
    Has('Longest Hit: 61.5m') and Has('Avg Hit Dist: 12.5m') and Has('Avg Hit Air: 0.10s') and
    Has('Avg Kill Air: 0.15s') and not Has('counted since 5.6'));
  Check('!wep ak: nothing of the whole server, which !serverwep shows', not Has('Server-wide') and not Has('Nemesis') and
    not Has('Of primaries') and Has('The whole server: !serverwep ak   against the other weapons: !playermatchup ak [p]'));
  Run('/serverwep ak');
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
    Ok := Ok and At(Lines[Idx + 1], Pos('25-50m', H), '51.4%');
  end;
  Check('!serverwep ak: the kill distances of the server, names, shares and bars in the same columns', Ok);
  Check('!serverwep ak: a range with a kill has a bar', Ok and (Pos('#', Copy(Lines[Idx + 2], Pos('100m+', H), 20)) > 0));
  Check('!serverwep ak: nemesis and top victim without the AK itself', Has('Nemesis: Barrett (80)') and
    Has('Top Victim: Barrett (120)'));
  Check('!serverwep ak: no vest kills row without vest kills, no share without picks', not Has('Vest kills') and
    Has('Of primaries: -'));
  Check('!serverwep ak on DM: no team picks', not Has('Alpha picks'));
  Check('!serverwep ak: the hits'' distance and air time of every account', Has('Longest Hit: 61.5m') and
    Has('Avg Hit Dist: 12.5m') and Has('Avg Hit Air: 0.10s') and Has('Avg Kill Air: 0.15s'));
  Run('/wep knife alice');
  Check('!wep knife: kills from before the distances were counted say so', Has('Avg Kill Dist: -') and
    Has('Counted for every account since 5.5: the kills before have no distance or time here.'));
  Check('!wep knife: hits from before the hits were measured say so, no empty cells',
    Has('The hits'' distance and air time: counted since 5.6, while [Bridges] reads the server.') and
    not Has('Avg Hit Dist') and not Has('Avg Hit Air'));
  Run('/wep minigun alice');
  Check('!wep minigun without kills: no distances and no note', (IndexOfLine('<10m') < 0) and Has('Avg Kill Dist: -') and
    not Has('Counted for every account since 5.5'));
  Run('/wep saw alice');
  Check('!wep saw: hits without an accuracy, no shots, no kills per shot', Has('Hits: 57') and not Has('Hits: 57 (') and
    Has('Shots: -') and Has('Kills/Shot: -') and Fits);
  Check('!wep saw: a blade''s hits have no distance: no cells, no note', not Has('Avg Hit Dist') and
    not Has('counted since 5.6'));
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
  Run('/allweaponsby hitdist;longesthit;hitair;killair alice');
  Idx := HeaderLine('Weapon ');
  Ok := Idx >= 0;
  if Ok then
  begin
    H := Lines[Idx];
    Ok := (Pos('AK-74', Lines[Idx + 2]) = 1) and At(Lines[Idx + 2], Pos('HitDist', H), '12.5m') and
      At(Lines[Idx + 2], Pos('LongHit', H), '61.5m') and At(Lines[Idx + 2], Pos('HitAir', H), '0.10s') and
      At(Lines[Idx + 2], Pos('KillAir', H), '0.15s') and At(LineOf('Chainsaw'), Pos('HitDist', H), '- ') and
      At(LineOf('Chainsaw'), Pos('HitAir', H), '- ');
  end;
  Check('!allweaponsby hitdist;longesthit;hitair;killair: the account''s own, - for a blade',
    Has('All Weapons by HitDist > LongHit > HitAir > KillAir: Alice') and Ok and Fits and RowsUnderHeader(Idx, 'Best first'));
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

  { ---- what the players did on the maps ([Matrix]): a player on one map, over all maps, one map ---- }
  EnterCriticalSection(Engine.StateLock);
  try
    RA := Engine.DB.PM.Find(A^.ID, 'rscs_arena');
    RB := Engine.DB.PM.Find(B^.ID, 'RSCS_ARENA');
    Check('the kill of the setup made a record of both players on the map (its name in any case)',
      (RA <> nil) and (RB <> nil) and (RA^.Kills = 1) and (RB^.Deaths = 1) and PMRivalPos(RA^.Rivals, B^.ID, k));
    if (RA = nil) or (RB = nil) then
      Halt(1);
    RA^.Kills := 15135;
    RA^.Deaths := 3000;
    RA^.Points := 1234;
    RA^.TimePlayed := 36000;
    RA^.Wins := 5;
    RA^.Losses := 3;
    RA^.RoundsWon := 40;
    RA^.RoundsLost := 30;
    RA^.Shots := 165600;
    RA^.Hits := 42000;
    RA^.HitsHead := 5000;
    RA^.HitsBody := 30000;
    RA^.HitsLegs := 7000;
    RA^.DamageDealt := 2500000;
    RA^.DamageReceived := 400000;
    RA^.BestStreak := 12;
    RA^.FirstBloods := 2;
    RA^.RoundFirstBloods := 7;
    RA^.LastStands := 3;
    RA^.LongestKill := 87.5;
    RA^.HealRegen := 1234;
    { what else the account counts, on the map (5.5 round 3) }
    RA^.TimeAlive := 30000;
    RA^.LongestLife := 185;
    RA^.Traveled := 123456;
    RA^.BestLifeDistance := 812;
    RA^.JetTime := 4000;
    RA^.HitsUnknown := 5000;
    RA^.HealKits := 800;
    RA^.HealKitCount := 16;
    RA^.KitPickups[0] := 16;
    RA^.KitPickups[1] := 12500;
    RA^.FirstDamages := 8;
    RA^.PosthumousKills := 44;
    RA^.Dominations := 21;
    RA^.DominationsEnded := 3;
    RA^.ShutDowns := 9;
    RA^.Finishers := 12;
    RA^.GrenadeKills := 30;
    RA^.ExplosionMultiKills := 2;
    RA^.WallKills := 7;
    RA^.CoverShotKills := 5;
    RA^.BinkRecoveryKills := 17;
    RA^.ProneKills := 250;
    RA^.AirKills := 900;
    RA^.HeightKills := 1200;
    RA^.CampKills := 60;
    RA^.VestKills := 4;
    RA^.LongKills100 := 11;
    RA^.KillDistSum := 15000 * 23.5;
    RA^.KillDistCount := 15000;
    RA^.TTKSumTicks := 15000 * 42;
    RA^.TTKCount := 15000;
    RA^.BestTTKTicks := 3;
    RA^.KnifeStreak := 4;
    RA^.ForcedSelfkills := 6;
    RA^.Selfkills := 20;
    RA^.SelfkillsUnderFire := 5;
    RA^.DoubleKills := 1500;
    RA^.TripleKills := 300;
    RA^.MultiKills := 40;
    RA^.MultiKillsX2 := 5;
    RA^.SerialKills := 1;
    RA^.KnifeThrows := 10;
    RA^.KnifeThrowHits := 5;
    RA^.KnifeStabs := 130;
    RA^.NadeSelfHits := 3;
    PW := PMWeaponOf(RA^, WEP_AK74);
    PW^.Kills := 15000;
    PW^.Deaths := 2000;
    PW^.Shots := 165600;
    PW^.Hits := 42000;
    PW^.Headshots := 5000;
    PW^.Damage := 2500000;
    PW^.TimeUsed := 30000;
    { [Bridges] (5.6): the AK's hits and kills measured here, and the record's own }
    PW^.HitDistSum := 1000 * 22.5;
    PW^.HitDistCount := 1000;
    PW^.LongestHit := 80.5;
    PW^.HitAirTicks := 1000 * 9;
    PW^.HitAirCount := 1000;
    PW^.KillAirTicks := 200 * 6;
    PW^.KillAirCount := 200;
    RA^.HitDistSum := 1000 * 22.5;
    RA^.HitDistCount := 1000;
    RA^.LongestHit := 80.5;
    RA^.HitAirTicks := 1000 * 9;
    RA^.HitAirCount := 1000;
    RA^.KillAirTicks := 200 * 6;
    RA^.KillAirCount := 200;
    PW := PMWeaponOf(RA^, WEP_KNIFE);
    PW^.Kills := 135;
    PW^.Hits := 140;
    PW^.Shots := 10;
    PR := PMRivalOf(RA^, B^.ID, 200);
    PR^.Kills := 120;
    PR^.Deaths := 80;
    PR^.DamageDealt := 12345;
    PR^.DamageTaken := 9000;
    PR^.LastFight := Now - 1;
    PR^.PointsWon := 2410;
    PR^.PointsLost := 1500;
    PR := PMRivalOf(RA^, C^.ID, 200);
    PR^.Kills := 3;
    PR^.Deaths := 1;
    PR^.LastFight := Now - 2;
    PR^.PointsWon := 60;
    PR^.PointsLost := 70;
    { an account this server does not have (deleted, or of another server) }
    PR := PMRivalOf(RA^, 99999, 200);
    PR^.Kills := 2;
    PR^.LastFight := Now - 3;
    PR^.PointsWon := 44;
    PX := PMMatchupOf(RA^, WEP_AK74, WEP_BARRETT);
    PX^.Wins := 30;
    PX^.Losses := 10;
    PX := PMMatchupOf(RA^, WEP_AK74, WEP_AK74);
    PX^.Wins := 5;
    PX^.Losses := 5;
    for k := 0 to 11 do
      PMHeatAdd(RA^, 100 + (k mod 4) * 300, 100 + (k div 4) * 200, k mod 3 <> 0);
    PR := PMRivalOf(RB^, A^.ID, 200);
    PR^.Kills := 80;
    PR^.Deaths := 120;
    PR^.DamageDealt := 9000;
    PR^.DamageTaken := 12345;
    PR^.LastFight := Now - 1;
    PR^.PointsWon := 1450;
    PR^.PointsLost := 2300;
    { a second map of Alice, with flags and one rival }
    Engine.DB.FindMap('ctf_Laos', True);
    RL := Engine.DB.PM.Items[Engine.DB.PM.Obtain(A^.ID, Engine.DB.PM.MapNumber('ctf_Laos', True), Now - 5)];
    RL^.Kills := 10;
    RL^.Deaths := 5;
    RL^.Caps := 4;
    RL^.Returns := 2;
    RL^.Grabs := 9;
    RL^.TimePlayed := 3600;
    RL^.Wins := 2;
    RL^.Losses := 1;
    RL^.Points := -12;
    PR := PMRivalOf(RL^, B^.ID, 200);
    PR^.Kills := 10;
    PR^.Deaths := 5;
    PR^.LastFight := Now - 5;
    PR^.PointsWon := 130;
    PR^.PointsLost := 12270;
    { a map whose name holds the name of a player on the server }
    Engine.DB.FindMap('dm_Alice_Hills', True);
    { the duels of the map: the AK against the Barrett, and back }
    M := Engine.Match.MapIndex;
    for k := 1 to 11 do
      MapMatchupAdd(Engine.DB.Maps[M], WEP_AK74, WEP_BARRETT);
    for k := 1 to 4 do
      MapMatchupAdd(Engine.DB.Maps[M], WEP_BARRETT, WEP_AK74);
    { the weapons of the map: its own kills and picks (all time), and Bob's Barrett in his record }
    Engine.DB.Maps[M].WeaponKills[WEP_AK74] := 15135;
    Engine.DB.Maps[M].WeaponKills[WEP_BARRETT] := 400;
    Engine.DB.Maps[M].WeaponKills[WEP_KNIFE] := 135;
    Engine.DB.Maps[M].WeaponPicks[WEP_AK74] := 300;
    Engine.DB.Maps[M].WeaponPicks[WEP_BARRETT] := 100;
    Engine.DB.Maps[M].WeaponPicks[WEP_SOCOM] := 400;
    { Carl's spawn with the MP5 is no pick of this test }
    Engine.DB.Maps[M].WeaponPicks[WEP_MP5] := 0;
    PW := PMWeaponOf(RB^, WEP_BARRETT);
    PW^.Kills := 400;
    PW^.Deaths := 30;
    PW^.Shots := 900;
    PW^.Hits := 600;
    PW^.Headshots := 300;
    PW^.Damage := 90000;
    PW^.TimeUsed := 7200;
    PW^.HitDistSum := 500 * 40.0;
    PW^.HitDistCount := 500;
    PW^.LongestHit := 120.5;
    PW^.HitAirTicks := 500 * 3;
    PW^.HitAirCount := 500;
    PW^.KillAirTicks := 300 * 3;
    PW^.KillAirCount := 300;
    { an account that has not played since the per-map data is counted }
    Engine.DB.CreateProfile('Zed Old', '', 'HWZED', '8.8.8.8', 1000);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  Run('/mapplayerstats alice');
  Check('!mapplayerstats: the record of the map played now, 100 columns', Has('[ Map Stats: Alice on RSCS_Arena ]') and Fits);
  L := LineOf('Kills: ');
  Check('!mapplayerstats: counters shortened, three columns of 36, 34 and 30', (Pos('Kills: 15.1k', L) = 1) and
    At(L, 37, 'Deaths: 3000') and At(L, 71, 'K/D Ratio: 5.05'));
  Check('!mapplayerstats on DM survival: rounds, round first bloods and last stands; no flags, draws or teamkills',
    Has('Rounds: 40W / 30L') and Has('Round First Bloods: 7') and Has('Last Stands: 3') and not Has('Flag') and
    not Has('Draws') and not Has('Teamkills'));
  Check('!mapplayerstats: the points of the map, the damage as kills, the healing fields, the accuracy',
    Has('Map Points: +1234') and Has('Dealt: 2.5M (~') and Has('Regen: 1234 HP') and Has('Accuracy: 25.4%') and
    Has('Headshots: 5000 (11.9%)') and Has('Longest: 87.5m'));
  { the rows of !stats in their places, with the counters of the record }
  L := LineOf('Best Streak: ');
  Check('!mapplayerstats: the life and the damage ratio where !stats has them',
    (Pos('Best Streak: 12', L) = 1) and At(L, 37, 'Avg Life: 9s') and At(L, 71, 'Dmg Ratio: 6.25'));
  L := LineOf('Dealt: ');
  Check('!mapplayerstats on a free-for-all: the assists after the damage, as !stats', At(L, 71, 'Assists: 0'));
  L := LineOf('Healed: ');
  Check('!mapplayerstats: the healing of the fields and of the kits picked up here',
    (Pos('Healed: 2034 HP', L) = 1) and At(L, 37, 'Regen: 1234 HP') and At(L, 71, 'Heal Kits: 16 (800 HP)'));
  L := LineOf('Dmg/min alive: ');
  Check('!mapplayerstats: the rates of the time alive and the longest life',
    (Pos('Dmg/min alive: 5000.0', L) = 1) and At(L, 37, 'Kills/min alive: 30.27') and At(L, 71, 'Longest Life: 3m 5s'));
  L := LineOf('Longest: ');
  Check('!mapplayerstats: the longest kill, the longest Barrett kill and the average distance',
    (Pos('Longest: 87.5m', L) = 1) and At(L, 37, 'Barrett: 0.0m') and At(L, 71, 'Avg Dist: 23.5m'));
  Check('!mapplayerstats: the headshots are an estimate when many bullets had no clear zone',
    Pos('Headshots: 5000 (11.9%) est.', LineOf('Accuracy: ')) > 0);
  L := LineOf('Knife Throws: ');
  Check('!mapplayerstats: the knives of the record', (Pos('Knife Throws: 10', L) = 1) and At(L, 37, 'Knife Hits: 5') and
    At(L, 71, 'Knife Stabs: 130'));
  Check('!mapplayerstats on a free-for-all: no team row, no friendly fire, no Rambo row; the selfkills of the map',
    not Has('First Blood: ') and not Has('TK Dmg') and not Has('TK Deaths') and not Has('Bow Kills') and
    not Has('Clutches') and Has('Selfkills: 20') and Has('First Bloods: 2') and Fits);
  Run('/mapplayerstats rscs alice');
  Check('!mapplayerstats <part of a map> <player>', Has('[ Map Stats: Alice on RSCS_Arena ]'));
  Run('/mapplayerstats laos alice');
  Check('!mapplayerstats of another map: its flags from the counters, also on a DM server',
    Has('[ Map Stats: Alice on ctf_Laos ]') and Has('Flag Caps: 4') and Has('Map Points: -12') and Fits);
  RunAs(1, '/mapplayerstats');
  Check('!mapplayerstats alone: yourself on the map played now', Has('[ Map Stats: Alice on RSCS_Arena ]'));
  RunAs(1, '/mapplayerstats laos');
  Check('!mapplayerstats <map>: yourself on that map', Has('[ Map Stats: Alice on ctf_Laos ]'));
  RunAs(2, '/mapplayerstats alice');
  Check('!mapplayerstats <player on the server>: the player, though a map holds the name (dm_Alice_Hills)',
    Has('[ Map Stats: Alice on RSCS_Arena ]'));
  RunAs(1, '/mapplayerstats hills');
  Check('!mapplayerstats <part of that map>: the map', Has('No per-map data yet for Alice on dm_Alice_Hills.'));
  Run('/mapplayerstats laos bob');
  Check('!mapplayerstats of a player without a record on the map', Has('No per-map data yet for Bob on ctf_Laos.'));
  Run('/mapplayerstats zed');
  Check('!mapplayerstats of an account without records: says so and how long the data goes back',
    Has('No per-map data yet for Zed Old on RSCS_Arena.') and
    Has('Per-map data: counted since 5.5 while the statistics count; deleted after 90 days without play.'));
  Run('/mapplayerstats');
  Check('!mapplayerstats on the console without a player: name one', Has('The console has no statistics of its own'));
  Run('/mapplayerstats nosuchthing');
  Check('!mapplayerstats of a word that is no map and no player: says both', Has('Player not found.') and
    Has('"nosuchthing" is no map of the statistics either (!topmaps lists them).'));
  Run('/mapplayerstats Bot Boogie');
  Check('!mapplayerstats of a bot: bots have no statistics', Has('Player not found.'));

  Run('/mapplayerotherstats alice');
  Check('!mapplayerotherstats: the telemetry of the map, 100 columns', Has('[ Map Telemetry: Alice on RSCS_Arena ]') and
    Fits);
  Check('!mapplayerotherstats: the rivals of the map by kills and by deaths, a gone account by its number',
    (Pos('Fav Victims: Bob (120), Carl (3), #99999 (2)', LineOf('Fav Victims')) = 1) and
    (Pos('Top Nemeses: Bob (80), Carl (1)', LineOf('Top Nemeses')) = 1) and Has('Players fought here: 3'));
  Check('!mapplayerotherstats: on whom the player gains the most points, and who takes the most from him',
    (LineOf('Pts Won From') = 'Pts Won From: Bob (2410), Carl (60), #99999 (44)') and
    (LineOf('Pts Lost To') = 'Pts Lost To: Bob (1500), Carl (70)'));
  Check('!mapplayerotherstats: hit zones, the rounds of survival, no flags on DM', Has('Head: 5000 (11.9%)') and
    Has('Round WR: 57.1%') and Has('Matches & Rounds') and not Has('Flag'));
  Check('!mapplayerotherstats: the weapons of the map', Has('Most Kills: AK (15.0k)') and Has('Weapons Used: 2'));
  { the sections of !otherstats in their order, with the counters of the record }
  Check('!mapplayerotherstats: the sections of !otherstats in their order, then the time and the weapons of the map',
    (IndexOfLine('Damage & Healing') < IndexOfLine('Rivals on this Map')) and
    (IndexOfLine('Rivals on this Map') < IndexOfLine('Hitzones, Aim & Distance')) and
    (IndexOfLine('Hitzones, Aim & Distance') < IndexOfLine('Timing, Movement & Positioning')) and
    (IndexOfLine('Timing, Movement & Positioning') < IndexOfLine('Feats & Streaks')) and
    (IndexOfLine('Feats & Streaks') < IndexOfLine('Matches & Rounds')) and
    (IndexOfLine('Matches & Rounds') < IndexOfLine('Multi-Kill Medals')) and
    (IndexOfLine('Multi-Kill Medals') < IndexOfLine('Melee, Explosives & Heavy Arsenal')) and
    (IndexOfLine('Melee, Explosives & Heavy Arsenal') < IndexOfLine('Time on this Map')) and
    (IndexOfLine('Time on this Map') < IndexOfLine('Weapons on this Map')));
  L := LineOf('Healed: ');
  Check('!mapplayerotherstats: the healing and every kit picked up here, by kind',
    (Pos('Healed: 2034 HP', L) = 1) and At(L, 71, 'Heal Kits: 16 (800 HP)') and (HeaderLine('Kits: ') >= 0) and
    (Lines[Max(0, HeaderLine('Kits: '))] = 'Kits: Med 16, Nade 12.5k, Cluster 0, Vest 0, Berserk 0, Predator 0, Flamer 0') and
    not Has('TK Dmg Out'));
  Check('!mapplayerotherstats: the distances and the unclear zones',
    (Pos('Longest Kill: 87.5m', LineOf('Longest Kill: ')) = 1) and At(LineOf('Longest Kill: '), 71, 'Avg Kill Dist: 23.5m') and
    (Pos('100m+ Kills: 11', LineOf('100m+ Kills: ')) = 1) and At(LineOf('100m+ Kills: '), 71, 'Unclear Zone: 5000'));
  L := LineOf('Avg TTK: ');
  Check('!mapplayerotherstats: the times to kill, the longest life, the way covered, the flight',
    (Pos('Avg TTK: 0.70s', L) = 1) and At(L, 37, 'Best TTK: 0.05s') and At(L, 71, 'Longest Life: 3m 5s') and
    (Pos('Traveled: 123.5 km', LineOf('Traveled: ')) = 1) and At(LineOf('Traveled: '), 37, 'Dist/Life: 41 m') and
    At(LineOf('Traveled: '), 71, 'Best Life: 812 m') and (Pos('Fly Time: 1h 6m', LineOf('Fly Time: ')) = 1) and
    At(LineOf('Fly Time: '), 37, 'Air Kills: 900') and (Pos('Prone Kills: 250', LineOf('Prone Kills: ')) = 1));
  Check('!mapplayerotherstats on survival: no spawn kills, as !otherstats', not Has('Spawn Kills'));
  Check('!mapplayerotherstats on realistic free-for-all survival: the feats of !otherstats, bink recovery, no team feats',
    Has('First Damage: 8') and Has('Dominations: 21') and Has('Dominations Ended: 3') and Has('Posthumous: 44') and
    Has('Finishers: 12') and Has('Shut Downs: 9') and Has('Nade Kills: 30') and Has('Bink Recovery: 17') and
    Has('Explosive Multi: 2') and Has('Knife Streak: 4') and Has('Cover (live): 7') and Has('Cover (shot): 5') and
    Has('Forced Selfkills: 6') and Has('Selfkills: 20 (0.7%)') and Has('Under Fire: 5 (25.0%)') and
    not Has('Saviors') and not Has('Avenger') and not Has('Comeback') and not Has('Clutches'));
  Check('!mapplayerotherstats: the multi-kill medals, the third row only with such kills',
    (Pos('Double Kills: 1500', LineOf('Double Kills: ')) = 1) and At(LineOf('Multi x2: '), 37, 'Serial Kills: 1') and
    not Has('Gimme More'));
  L := LineOf('Nades Thrown: ');
  Check('!mapplayerotherstats: the special weapons; the own nades without cluster throws',
    (Pos('Knife Throws: 10', LineOf('Knife Throws: ')) = 1) and At(LineOf('Knife Throws: '), 37, 'Knife Hits: 5 (50.0%)') and
    (Pos('Nades Thrown: 0', L) = 1) and At(L, 71, 'Self Nades: 3') and not Has('Saw: '));
  Check('!mapplayerotherstats on a free-for-all: no teamplay section, no team results', not Has('Teamplay') and
    not Has('Alpha: ') and not Has('Left Lost') and not Has('Adv Won') and Fits);

  Run('/mapplayerweapstats alice');
  Idx := HeaderLine('Weapon ');
  Check('!mapplayerweapstats: the weapons of the record, 100 columns, every cell under its header',
    Has('Map Weapons: Alice on RSCS_Arena') and Fits and RowsUnderHeader(Idx, 'Damage on this Map'));
  L := LineOf('AK-74');
  Check('!mapplayerweapstats: the AK with its share of the kills here', (Idx >= 0) and (L <> '') and
    At(L, Pos('Kills', Lines[Idx]), '15.0k') and At(L, Pos('Share', Lines[Idx]), '99.1%') and
    At(L, Pos('Acc%', Lines[Idx]), '25.4%'));
  L := LineOf('Combat Knife');
  Check('!mapplayerweapstats: no accuracy for a knife', (Idx >= 0) and (L <> '') and At(L, Pos('Acc%', Lines[Idx]), '- '));
  Check('!mapplayerweapstats: only the weapons of the record', not Has('USSOCOM') and not Has('M72 LAW'));
  Idx := IndexOfLine('LongHit   HitDist   HitAir    KillAir   Measured');
  Ok := Idx >= 0;
  if Ok then
  begin
    L := Lines[Idx + 1];
    Ok := RowsUnderHeader(Idx, 'Share = of the kills here') and (Pos('AK-74', L) = 1) and
      At(L, Pos('LongHit', Lines[Idx]), '80.5m') and At(L, Pos('HitDist', Lines[Idx]), '22.5m') and
      At(L, Pos('HitAir', Lines[Idx]), '0.15s') and At(L, Pos('KillAir', Lines[Idx]), '0.10s') and
      At(L, Pos('Measured', Lines[Idx]), '1000') and (Pos('Combat Knife', Lines[Idx + 2]) = 0);
  end;
  Check('!mapplayerweapstats: the range of the AK here (the knife has none), every cell under its header',
    Has('Range: hits measured from where the bullet was made (since 5.6)') and Ok);

  RunAs(1, '/playermaps');
  Idx := HeaderLine('#    Map');
  Check('!playermaps: every map of the player, the longest played first, the map played now marked',
    Has('Maps of Alice, by time [Page 1/1] (2 maps)') and Fits and
    CellsAt(Idx, ['Time', 'Kills', 'Deaths', 'K/D', 'Won/Lost', 'Points'], 'Per-map data') and
    (Idx >= 0) and
    (Pos('1    RSCS_Arena', Lines[Idx + 2]) = 1) and (Pos('<actual>', Lines[Idx + 2]) > 0) and
    (Pos('2    ctf_Laos', Lines[Idx + 3]) = 1));
  L := LineOf('All 2 maps');
  Check('!playermaps: every map together in the last row', (Pos('All 2 maps', L) = 6) and (Pos('15.1k', L) > 0));
  Check('!playermaps: how long the data goes back', Has('Per-map data: counted since 5.5'));
  RunAs(1, '/playermaps asc');
  Idx := HeaderLine('#    Map');
  Check('!playermaps asc: the order turned round, the title says it', Has('Maps of Alice, by time (asc) [Page 1/1]') and
    (Idx >= 0) and (Pos('1    ctf_Laos', Lines[Idx + 2]) = 1));
  Run('/playermaps points alice');
  Idx := HeaderLine('#    Map');
  Check('!playermaps <flag> <p>: by the points of each map', Has('Maps of Alice, by points [Page 1/1]') and (Idx >= 0) and
    (Pos('1    RSCS_Arena', Lines[Idx + 2]) = 1) and (Pos('2    ctf_Laos', Lines[Idx + 3]) = 1));
  Run('/playermapsi last asc 1');
  Idx := HeaderLine('#    Map');
  Check('!playermapsi <flags> <n>: the maps of a ranking position, the oldest game first',
    Has('Maps of Alice, by last game (asc) [Page 1/1]') and (Idx >= 0) and (Pos('1    ctf_Laos', Lines[Idx + 2]) = 1));

  Run('/rivals alice');
  Idx := HeaderLine('#    Rival');
  Check('!rivals: the rivals of every map added up, the most fights first, 100 columns, every cell under its header',
    Has('Rivals of Alice, all maps, by fights [Page 1/1] (3)') and Fits and
    CellsAt(Idx, ['Kills', 'Deaths', 'K/D', 'Pts Won', 'Pts Lost', 'Pts Delta', 'Dmg Out', 'Dmg In', 'Last Fight'],
      'Kills, Pts Won') and (Idx >= 0) and
    (Pos('1    Bob', Lines[Idx + 2]) = 1) and At(Lines[Idx + 2], Pos('Kills', Lines[Idx]), '130') and
    At(Lines[Idx + 2], Pos('Deaths', Lines[Idx]), '85'));
  Check('!rivals: the points won from a rival and lost to him over every map, their difference signed, shortened',
    (Idx >= 0) and At(Lines[Idx + 2], Pos('Pts Won', Lines[Idx]), '2540 ') and
    At(Lines[Idx + 2], Pos('Pts Lost', Lines[Idx]), '13.8k ') and At(Lines[Idx + 2], Pos('Pts Delta', Lines[Idx]), '-11.2k ') and
    Has('Kills, Pts Won, Dmg Out: by Alice   Deaths, Pts Lost, Dmg In: by him'));
  Check('!rivals: an account this server does not have any more by its number', Has('#99999 (gone)'));
  Run('/rivals delta alice');
  Idx := HeaderLine('#    Rival');
  Check('!rivals delta <p>: the best points delta first', Has('Rivals of Alice, all maps, by points delta [Page 1/1] (3)') and
    (Idx >= 0) and (Pos('1    #99999', Lines[Idx + 2]) = 1) and (Pos('2    Carl', Lines[Idx + 3]) = 1) and
    (Pos('3    Bob', Lines[Idx + 4]) = 1) and At(Lines[Idx + 3], Pos('Pts Delta', Lines[Idx]), '-10 '));
  Run('/rivals lost alice');
  Idx := HeaderLine('#    Rival');
  Check('!rivals lost <p>: who takes the most points first', Has('by points lost [Page') and (Idx >= 0) and
    (Pos('1    Bob', Lines[Idx + 2]) = 1) and (Pos('2    Carl', Lines[Idx + 3]) = 1));
  Run('/rivals won asc alice');
  Idx := HeaderLine('#    Rival');
  Check('!rivals won asc <p>: the order turned round', Has('by points won (asc) [Page') and (Idx >= 0) and
    (Pos('1    #99999', Lines[Idx + 2]) = 1) and (Pos('3    Bob', Lines[Idx + 4]) = 1));
  RunAs(2, '/rivals');
  Check('!rivals alone: yours; a bot is nobody''s rival', Has('Rivals of Bob, all maps, by fights [Page 1/1] (1)') and
    (Pos('1    Alice', LineOf('Alice')) = 1) and not Has('Boogie'));
  L := LineOf('1    Alice');
  Idx := HeaderLine('#    Rival');
  Check('!rivals: each side keeps the points it won and lost itself', (Idx >= 0) and
    At(L, Pos('Pts Won', Lines[Idx]), '1450 ') and At(L, Pos('Pts Lost', Lines[Idx]), '2300 ') and
    At(L, Pos('Pts Delta', Lines[Idx]), '-850 '));
  Run('/mapplayerrivals laos alice');
  Check('!mapplayerrivals: the rivals of one map', Has('Rivals of Alice on ctf_Laos, by fights [Page 1/1] (1)') and
    (Pos('1    Bob', LineOf('Bob')) = 1));
  Run('/rivals zed');
  Check('!rivals of an account without records', Has('No rivals of Zed Old recorded yet.'));
  Run('/rivals Bot Boogie');
  Check('!rivals of a bot: bots have no statistics', Has('Player not found.'));
  Run('/rivals');
  Check('!rivals on the console without a player: name one', Has('The console has no statistics of its own'));

  Run('/maprivals');
  L := LineOf('Alice vs Bob');
  Idx := HeaderLine('#    Players');
  Check('!maprivals: the pairs of the map played now, the most fights first, both sides once',
    Has('Rivalries on RSCS_Arena, by fights [Page 1/1] (3 pairs)') and Fits and (Pos('1    Alice vs Bob', L) = 1) and
    (Pos('120 - 80', L) > 0) and Has('Alice vs #99999') and
    CellsAt(Idx, ['Players', 'Kills', 'Points', 'Pts Delta', 'Damage', 'Last Fight'], 'Kills, Damage:'));
  Check('!maprivals: the points won - lost of the first player and their difference; a side without an entry of the ' +
    'other from the other side', (Idx >= 0) and At(L, Pos('Points', Lines[Idx]), '2410 - 1500 ') and
    At(L, Pos('Pts Delta', Lines[Idx]), '+910 ') and At(LineOf('Alice vs Carl'), Pos('Points', Lines[Idx]), '60 - 70 ') and
    At(LineOf('Alice vs Carl'), Pos('Pts Delta', Lines[Idx]), '-10 '));
  Run('/maprivals delta');
  Idx := HeaderLine('#    Players');
  Check('!maprivals delta: the most one-sided in points first', Has('Rivalries on RSCS_Arena, by points delta') and
    (Idx >= 0) and (Pos('2    Alice vs #99999', Lines[Idx + 3]) = 1) and (Pos('3    Alice vs Carl', Lines[Idx + 4]) = 1));
  Run('/maprivals last asc rscs 1');
  Idx := HeaderLine('#    Players');
  Check('!maprivals <flags> <map> <pg>: the parts in any order after the map, the oldest fight first',
    Has('Rivalries on RSCS_Arena, by last fight (asc) [Page 1/1]') and (Idx >= 0) and
    (Pos('1    Alice vs #99999', Lines[Idx + 2]) = 1));
  Run('/maprivals zzz');
  Check('!maprivals of no map', Has('Map not found: zzz'));
  RunAs(2, '/maprivals zzz');
  RunAs(2, '/maprivals');
  Check('!maprivals of no map costs a player no list: the next one is shown', Has('Rivalries on RSCS_Arena') and
    not Has('Please wait'));
  RunAs(2, '/maprivals');
  Check('!maprivals is a list with the player''s limit', Has('Please wait') and not Has('Rivalries on'));

  Run('/versus alice bob');
  Check('!versus: two players head to head, all maps and a line per map, the most fights first',
    Has('[ Alice vs Bob - head to head ]') and Fits and Has('Alice: 130 kills') and Has('Bob: 85 kills') and
    Has('Maps: 2') and Has('Ahead: Alice by 45') and (Pos('1    RSCS_Arena', LineOf('RSCS_Arena')) = 1) and
    (Pos('2    ctf_Laos', LineOf('ctf_Laos')) = 1) and Has('Per map by fights - the numbers of Alice first') and
    CellsAt(HeaderLine('#    Map'), ['Kills', 'Deaths', 'K/D', 'Pts Won', 'Pts Lost', 'Pts Delta', 'Dmg Out', 'Dmg In',
      'Last Fight']));
  Idx := HeaderLine('#    Map');
  Check('!versus: the points of the first player won from the second and lost to him, all maps and each map',
    Has('Pts won by Alice: 2540') and Has('Pts lost by Alice: 13.8k') and Has('Pts Delta: -11.2k') and (Idx >= 0) and
    At(LineOf('1    RSCS_Arena'), Pos('Pts Delta', Lines[Idx]), '+910 ') and
    At(LineOf('2    ctf_Laos'), Pos('Pts Lost', Lines[Idx]), '12.3k ') and
    At(LineOf('2    ctf_Laos'), Pos('Pts Delta', Lines[Idx]), '-12.1k '));
  Run('/versus lost alice bob');
  Check('!versus <flag>: the maps in that order', Has('Per map by points lost - the numbers of Alice first') and
    (Pos('1    ctf_Laos', LineOf('ctf_Laos')) = 1));
  RunAs(2, '/versus alice');
  Check('!versus <p>: against yourself', Has('[ Alice vs Bob - head to head ]'));
  RunAs(2, '/versusi 1');
  Check('!versusi <n>: the ranking position against yourself', Has('[ Alice vs Bob - head to head ]'));
  RunAs(2, '/versusi 1 1');
  Check('!versusi of a position against itself', Has('Two different players, please'));
  Run('/versusi 1');
  Check('!versusi on the console with one position: name the second', Has('The console has no statistics of its own'));
  Run('/versus alice');
  Check('!versus on the console with one player: name the second', Has('The console has no statistics of its own'));
  Run('/versus');
  Check('!versus without a player: how it is used', Has('Usage: !versus [flag] [pg] <player> [player2]'));
  Run('/versusi alice');
  Check('!versusi of a name: how it is used', Has('Usage: !versus [flag] [pg] <player> [player2]   !versusi'));
  Run('/versus alice alice');
  Check('!versus of a player against himself', Has('Two different players, please'));
  Run('/versus bob carl');
  Check('!versus of two players who never fought', Has('Bob and Carl have not fought each other yet.'));

  Run('/playermatchup alice');
  Idx := HeaderLine('#    Own Weapon');
  Check('!playermatchup: the weapon pairs of the player, the most duels first, 100 columns',
    Has('Weapon Matchups of Alice, all maps, by duels [Page 1/1] (2)') and Fits and
    CellsAt(Idx, ['Own Weapon', 'Duels', 'Won', 'Lost', 'Edge'], 'Won: ') and (Idx >= 0) and
    (Pos('1    AK vs Barrett', Lines[Idx + 2]) = 1) and (Pos('30 (75.0%)', Lines[Idx + 2]) > 0) and
    (Pos('FAVORED', Lines[Idx + 2]) > 0) and (Pos('2    AK vs AK', Lines[Idx + 3]) = 1));
  Run('/playermatchup alice ak');
  Check('!playermatchup <p> <weapon>: the weapon against every one it met, also against itself',
    Has('Matchups of Alice: AK-74, all maps, by duels [Page 1/1]') and Has('Barrett M82A1') and (HeaderLine('AK-74 ') >= 0) and
    Fits);
  Run('/playermatchup ak rate alice');
  Check('!playermatchup <weapon> <flag> <p>: the weapon first, then the flag and the player',
    Has('Matchups of Alice: AK-74, all maps, by win rate [Page 1/1]') and (HeaderLine('Barrett M82A1') >= 0));
  RunAs(1, '/playermatchup ak');
  Check('!playermatchup <weapon>: your own weapon', Has('Matchups of Alice: AK-74, all maps'));
  RunAs(1, '/playermatchup bob');
  Check('!playermatchup <player>: a name is the player', Has('Weapon Matchups of Bob, all maps'));
  RunAs(1, '/playermatchup asc');
  Idx := HeaderLine('#    Own Weapon');
  Check('!playermatchup asc: the fewest duels first', Has('by duels (asc)') and (Idx >= 0) and
    (Pos('1    AK vs AK', Lines[Idx + 2]) = 1));
  Run('/playermatrix alice');
  Check('!playermatrix = !playermatchup', Has('Weapon Matchups of Alice, all maps, by duels [Page 1/1] (2)'));
  Run('/playermatchupi ak 1');
  Check('!playermatchupi <weapon> <n>: a ranking position', Has('Matchups of Alice: AK-74, all maps, by duels'));
  Run('/playermatrixi wins 1');
  Check('!playermatrixi <flag> <n>', Has('Weapon Matchups of Alice, all maps, by wins [Page 1/1] (2)'));
  Run('/mapplayermatchup rscs alice');
  Check('!mapplayermatchup: the weapon pairs of the player on one map',
    Has('Weapon Matchups of Alice on RSCS_Arena, by duels [Page 1/1] (2)') and Fits);
  Run('/mapplayermatrixi rscs losses 1');
  Check('!mapplayermatrixi <map> <flag> <n>', Has('Weapon Matchups of Alice on RSCS_Arena, by losses [Page 1/1] (2)'));
  Run('/mapplayermatchup laos alice');
  Check('!mapplayermatchup of a map without duels', Has('No weapon duels of Alice on ctf_Laos recorded yet.'));

  Run('/mapmatchup');
  Check('!mapmatchup: the weapon pairs of the map played now',
    Has('Weapon Matchups on RSCS_Arena: Top Rivalries, by duels [Page 1/1] (1)') and Fits and Has('AK vs Barrett'));
  Run('/mapmatchup rscs ak');
  Check('!mapmatchup <map> <weapon>: one weapon on that map', Has('Matchups: AK-74 on RSCS_Arena, by duels [Page 1/1]') and
    Has('Barrett M82A1'));
  Run('/mapmatchup barrett');
  Check('!mapmatchup <weapon>: a weapon on the map played now', Has('Matchups: Barrett M82A1 on RSCS_Arena'));
  Run('/mapmatrix ak rscs rate');
  Check('!mapmatrix <weapon> <map> <flag>: a weapon before the map', Has('Matchups: AK-74 on RSCS_Arena, by win rate'));
  Run('/mapmatchup barr');
  Check('!mapmatchup <part of a weapon>: the weapon', Has('Matchups: Barrett M82A1 on RSCS_Arena'));
  Run('/mapmatchup laos');
  Check('!mapmatchup of a map without duels', Has('No weapon duels recorded on ctf_Laos yet.'));

  Run('/playerheatmap alice');
  Check('!playerheatmap: where the player killed and died, 100 columns, the picture in the middle',
    Has('[ Where Alice kills and dies: RSCS_Arena ]') and Fits and At(LineOf('+-----'), 20, '+-') and
    (Length(LineOf('+-----')) = 19 + 62) and Has('Hot spot 1:') and Has('at 4 spots'));
  Run('/playerheatmap laos alice');
  Check('!playerheatmap of a map without kills or deaths', Has('No kills or deaths of Alice on ctf_Laos yet.'));

  { the "i" forms: the position in the points ranking (Alice is first) in place of the player }
  Run('/mapplayerstatsi 1');
  Ok := Has('[ Map Stats: Alice on RSCS_Arena ]') and Has('Avg Life: 9s') and Has('Kills/min alive: 30.27');
  Run('/mapplayerstatsi laos 1');
  Ok := Ok and Has('[ Map Stats: Alice on ctf_Laos ]');
  Run('/mapplayerotherstatsi 1');
  Ok := Ok and Has('[ Map Telemetry: Alice on RSCS_Arena ]') and Has('Timing, Movement & Positioning') and
    Has('Double Kills: 1500');
  Run('/mapplayerweapstatsi rscs 1');
  Ok := Ok and Has('Map Weapons: Alice on RSCS_Arena');
  Run('/playerheatmapi 1');
  Ok := Ok and Has('[ Where Alice kills and dies: RSCS_Arena ]');
  Run('/mapplayerrivalsi laos 1');
  Ok := Ok and Has('Rivals of Alice on ctf_Laos, by fights [Page 1/1] (1)');
  Run('/rivalsi lost 1');
  Ok := Ok and Has('Rivals of Alice, all maps, by points lost [Page 1/1] (3)');
  Run('/mapplayermatchupi rscs 1');
  Ok := Ok and Has('Weapon Matchups of Alice on RSCS_Arena, by duels');
  Check('the "i" forms show the account at that position of the ranking', Ok);
  Run('/rivalsi alice');
  Check('an "i" form with a name says how it is used', Has('Usage: !rivalsi [flag] [pg] <n>'));
  Run('/mapplayerstatsi rscs alice');
  Check('... also with a map', Has('Usage: !mapplayerstatsi [map] <n>'));
  Run('/mapplayerstatsi 99999');
  Check('an "i" form past the end of the ranking says how many places it has', Has('The ranking has'));

  { the weapons of a map: the map's own kills and picks, the records' shots, hits, damage and time }
  Run('/mapweapstats');
  Idx := HeaderLine('Weapon ');
  L := LineOf('AK-74');
  Check('!mapweapstats: every weapon used on the map, the most kills first, 100 columns, every cell under its header',
    Has('Weapons on RSCS_Arena, by kills [Page 1/1] (4)') and Fits and (Idx >= 0) and RowsUnderHeader(Idx, 'Map totals') and
    (Pos('AK-74', Lines[Idx + 2]) = 1) and (Pos('Barrett M82A1', Lines[Idx + 3]) = 1) and
    (Pos('Combat Knife', Lines[Idx + 4]) = 1) and (Pos('USSOCOM', Lines[Idx + 5]) = 1));
  Check('!mapweapstats: the map''s kills and their share, the share of the picks of its group, the records'' numbers',
    (Idx >= 0) and At(L, Pos('Kills', Lines[Idx]), '15.1k ') and At(L, Pos('Share', Lines[Idx]), '96.6% ') and
    At(L, Pos('Pick%', Lines[Idx]), '75.0% ') and At(L, Pos('Shots', Lines[Idx]), '166k ') and
    At(L, Pos('Acc%', Lines[Idx]), '25.4% ') and At(L, Pos('DmgOut', Lines[Idx]), '2.5M ') and
    At(L, Pos('Players', Lines[Idx]), '1 ') and At(LineOf('USSOCOM'), Pos('Pick%', Lines[Idx]), '100.0% ') and
    At(LineOf('Combat Knife'), Pos('Acc%', Lines[Idx]), '- '));
  Check('!mapweapstats: the totals and where each column comes from', Has('Map totals') and Has('Deadliest: AK') and
    Has('Kills, Share, Pick%: the map''s own counters, all time.') and Has('Per-map data: counted since 5.5'));
  Idx := IndexOfLine('LongHit   HitDist   HitAir    KillAir   Measured');
  Ok := Idx >= 0;
  if Ok then
    Ok := RowsUnderHeader(Idx) and (Pos('AK-74', Lines[Idx + 1]) = 1) and
      At(Lines[Idx + 1], Pos('HitDist', Lines[Idx]), '22.5m') and (Pos('Barrett M82A1', Lines[Idx + 2]) = 1) and
      At(Lines[Idx + 2], Pos('LongHit', Lines[Idx]), '120.5m') and At(Lines[Idx + 2], Pos('KillAir', Lines[Idx]), '0.05s') and
      At(Lines[Idx + 2], Pos('Measured', Lines[Idx]), '500') and (Pos('=', Lines[Idx + 3]) = 1);
  Check('!mapweapstats: the map''s average and the range of the weapons of the page in their order, every cell under ' +
    'its header', Has('Avg Hit Dist: 18.5m') and Ok);
  Run('/mapweapstats hitdist');
  Idx := HeaderLine('Weapon ');
  Check('!mapweapstats hitdist: the longest average first, a weapon without measured hits last',
    Has('by hit distance [Page') and (Idx >= 0) and (Pos('Barrett M82A1', Lines[Idx + 2]) = 1) and
    (Pos('AK-74', Lines[Idx + 3]) = 1));
  Run('/mapweapstats acc');
  Idx := HeaderLine('Weapon ');
  Check('!mapweapstats acc: the best accuracy first, a weapon without one last', Has('by accuracy [Page') and (Idx >= 0) and
    (Pos('Barrett M82A1', Lines[Idx + 2]) = 1) and (Pos('AK-74', Lines[Idx + 3]) = 1));
  Run('/mapweapsstats rscs picks');
  Idx := HeaderLine('Weapon ');
  Check('!mapweapsstats <map> <flag>: the same command, the most picked first', Has('Weapons on RSCS_Arena, by picks') and
    (Idx >= 0) and (Pos('USSOCOM', Lines[Idx + 2]) = 1));
  Run('/mapweapstats laos');
  Check('!mapweapstats of a map without weapons', Has('No weapon counted on ctf_Laos yet.'));
  Run('/mapweapstats zzz');
  Check('!mapweapstats of no map', Has('Map not found: zzz'));
  RunAs(2, '/mapweapstats');
  RunAs(2, '/mapweapstats');
  Check('!mapweapstats is a list with the player''s limit', Has('Please wait') and not Has('Weapons on'));

  Run('/mapwep ak');
  Check('!mapwep <weapon>: one weapon on the map played now, 100 columns', Has('Weapon: AK-74 on RSCS_Arena') and Fits and
    Has('Kills: 15.1k') and Has('Share: 96.6% of kills') and Has('Of primaries: 75.0%') and Has('Nemesis: Barrett (4)') and
    Has('Top Victim: Barrett (12)') and Has('Deaths by it: 2001') and Has('Hits: 42.0k (25.4%)'));
  Check('!mapwep: the range of its hits and kills here', Has('Longest Hit: 80.5m') and Has('Avg Hit Dist: 22.5m') and
    Has('Avg Hit Air: 0.15s') and Has('Avg Kill Air: 0.10s'));
  Idx := HeaderLine('#    Nick');
  Check('!mapwep: the players with the most kills with it there', Has('Best players with the AK-74 here') and (Idx >= 0) and
    (Pos('1    Alice', Lines[Idx + 2]) = 1) and CellsAt(Idx, ['Kills', 'Deaths', 'K/D', 'Acc%', 'HS%', 'Damage', 'Time']));
  Run('/mapweapon barrett rscs');
  Check('!mapweapon <weapon> <map>: the same command', Has('Weapon: Barrett M82A1 on RSCS_Arena') and
    (Pos('1    Bob', LineOf('1    Bob')) = 1));
  Run('/mapwep ak laos');
  Check('!mapwep of a weapon not used on the map', Has('Nothing of the AK-74 counted on ctf_Laos yet.'));
  Run('/mapwep zzz');
  Check('!mapwep of no weapon', Has('Unknown weapon: zzz.'));
  Run('/mapwep help');
  Check('!mapwep help: the weapon names', Has('Map Weapon Lookup') and Has('Usage: !mapwep <weapon> [map]') and Fits);

  { every flag a help names orders its lists, and the title says it }
  Check('!rivals help: the flags of the rivals, each of them works', FlagHelpWorks('/rivals', ' alice', ['fights', 'kills',
    'deaths', 'K/D', 'points delta', 'points won', 'points lost', 'damage out', 'damage in', 'last fight'], ', by ', ' ['));
  Check('!versus help: the same flags order the maps', FlagHelpWorks('/versus', ' alice bob', ['fights', 'kills', 'deaths',
    'K/D', 'points delta', 'points won', 'points lost', 'damage out', 'damage in', 'last fight'], 'Per map by ', ' - '));
  Check('!maprivals help: the flags of the pairs, each of them works', FlagHelpWorks('/maprivals', '', ['fights', 'damage',
    'points', 'points delta', 'last fight'], ', by ', ' ['));
  Check('!playermatchup help: the flags of the weapon duels, each of them works', FlagHelpWorks('/playermatchup', ' alice',
    ['duels', 'wins', 'losses', 'win rate'], ', by ', ' ['));
  Check('!mapmatchup help: the same flags', FlagHelpWorks('/mapmatchup', ' rscs', ['duels', 'wins', 'losses', 'win rate'],
    ', by ', ' ['));
  Check('!playermaps help: the flags of the maps of a player, each of them works', FlagHelpWorks('/playermaps', ' alice',
    ['time', 'kills', 'deaths', 'K/D', 'points', 'wins', 'last game'], ', by ', ' ['));
  Check('!mapweapstats help: the flags of the weapons of a map, each of them works', FlagHelpWorks('/mapweapstats', '',
    ['kills', 'picks', 'shots', 'hits', 'accuracy', 'headshot share', 'damage', 'time', 'players', 'hit distance',
    'longest hit', 'hit air time', 'kill air time'], ', by ', ' ['));
  Run('/rivals help');
  Check('!rivals help: what counts as points won and lost', Has('Pts Won: what killing the rival paid') and
    Has('Penalties of teamkills and selfkills and the capture pool move no points between two players.'));

  { twenty more rivals on ctf_Laos: two pages, and the page commands reach them }
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 1 to 20 do
    begin
      M := Engine.DB.CreateProfile(Format('Rival%.2d', [k]), '', Format('HWR%d', [k]), '7.7.7.7', 1000);
      PR := PMRivalOf(RL^, Engine.DB.Profiles[M]^.ID, 200);
      PR^.Kills := k;
      PR^.LastFight := Now - 10;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/mapplayerrivals laos alice');
  Check('!mapplayerrivals: fifteen to a page with a page hint', Has('Rivals of Alice on ctf_Laos, by fights [Page 1/2] (21)') and
    Has('Page 1/2 - /zs_next') and (Pos('1    Rival20', LineOf('Rival20')) = 1));
  Run('/zs_next');
  Check('/zs_next after !mapplayerrivals: the second page', Has('Rivals of Alice on ctf_Laos, by fights [Page 2/2] (21)') and
    (Pos('21   Rival01', LineOf('Rival01')) = 1));
  Run('/mapplayerrivals laos 2 alice');
  Check('!mapplayerrivals <map> <pg> <p>: the page before the player',
    Has('Rivals of Alice on ctf_Laos, by fights [Page 2/2] (21)'));
  Run('/mapplayerrivals laos kills asc 1 alice');
  Check('!mapplayerrivals <map> <flags> <pg> <p>: the fewest kills first',
    Has('Rivals of Alice on ctf_Laos, by kills (asc) [Page 1/2] (21)') and (Pos('1    Rival01', LineOf('Rival01')) = 1));
  Run('/zs_next');
  Check('/zs_next keeps the order of the list', Has('Rivals of Alice on ctf_Laos, by kills (asc) [Page 2/2] (21)') and
    (Pos('21   Rival20', LineOf('Rival20')) = 1));
  Run('/mapplayerrivalsi laos 2 1');
  Check('!mapplayerrivalsi <map> <pg> <n>', Has('Rivals of Alice on ctf_Laos, by fights [Page 2/2] (21)'));
  Run('/rivals alice 2');
  Check('!rivals <p> <page>: the page of the list', Has('Rivals of Alice, all maps, by fights [Page 2/2] (23)'));
  Run('/zs_prev');
  Check('/zs_prev after !rivals: the first page', Has('Rivals of Alice, all maps, by fights [Page 1/2] (23)'));
  Run('/rivals 2 alice');
  Check('!rivals <pg> <p>: the page before the player', Has('Rivals of Alice, all maps, by fights [Page 2/2] (23)'));
  Run('/rivalsi delta 2 1');
  Check('!rivalsi <flag> <pg> <n>', Has('Rivals of Alice, all maps, by points delta [Page 2/2] (23)'));
  { every list of the per-map data is shown again by the page commands, from what it kept }
  RunAs(1, '/playermaps kills');
  RunAs(1, '/zs_first');
  Ok := Has('Maps of Alice, by kills [Page 1/1] (2 maps)');
  Run('/versus delta alice bob');
  Run('/zs_end');
  Ok := Ok and Has('[ Alice vs Bob - head to head ]') and Has('Per map by points delta');
  Run('/playermatchup alice ak');
  Run('/zs_page 1');
  Ok := Ok and Has('Matchups of Alice: AK-74, all maps, by duels [Page 1/1]');
  Run('/mapplayermatchup rscs rate alice');
  Run('/zs_first');
  Ok := Ok and Has('Weapon Matchups of Alice on RSCS_Arena, by win rate [Page 1/1] (2)');
  Run('/mapmatchup rscs ak losses');
  Run('/zs_first');
  Ok := Ok and Has('Matchups: AK-74 on RSCS_Arena, by losses [Page 1/1]');
  Run('/maprivals rscs points');
  Run('/zs_first');
  Ok := Ok and Has('Rivalries on RSCS_Arena, by points [Page 1/1] (3 pairs)');
  Run('/mapweapstats hs');
  Run('/zs_first');
  Ok := Ok and Has('Weapons on RSCS_Arena, by headshot share [Page 1/1] (4)');
  Check('the page commands show every list of the per-map data again, in its order', Ok);

  { [Matrix] PlayerHeatmap = 0 and Enabled = 0: the views say so }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.MatrixPlayerHeatmap := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/playerheatmap alice');
  Check('!playerheatmap with PlayerHeatmap = 0: what was recorded before, and that nothing is added',
    Has('Not recorded any more ([Matrix] PlayerHeatmap = 0)') and Has('[ Where Alice kills and dies: RSCS_Arena ]'));
  Run('/playerheatmap laos alice');
  Check('!playerheatmap with PlayerHeatmap = 0 and nothing recorded',
    Has('Where each player kills and dies is not recorded on this server ([Matrix] PlayerHeatmap = 0).'));
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.MatrixPlayerHeatmap := True;
    Engine.Cfg.MatrixEnabled := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/mapplayerstats zed');
  Check('[Matrix] Enabled = 0: an account without records hears that nothing is recorded',
    Has('Per-map player data is not recorded on this server ([Matrix] Enabled = 0).') and not Has('No per-map data yet'));
  Run('/mapplayerstats alice');
  Check('[Matrix] Enabled = 0: a record from before is shown with a note',
    Has('Not recorded any more ([Matrix] Enabled = 0): this was recorded before.') and Has('[ Map Stats: Alice on RSCS_Arena ]'));
  Run('/rivalsi 1');
  Check('[Matrix] Enabled = 0: the "i" forms as well',
    Has('Not recorded any more ([Matrix] Enabled = 0): this was recorded before.') and Has('Rivals of Alice, all maps'));
  Run('/mapmatchup laos');
  Check('[Matrix] Enabled = 0: the duels of a map', Has('The weapon matchups of the maps are not recorded on this server'));
  Run('/mapweapstats');
  Check('[Matrix] Enabled = 0: the weapons of a map from before, and the map''s own counters',
    Has('Not recorded any more ([Matrix] Enabled = 0): this was recorded before.') and Has('Weapons on RSCS_Arena'));
  Run('/mapwep ak laos');
  Check('[Matrix] Enabled = 0: a weapon of a map without records says what is not recorded',
    Has('Per-map player data is not recorded on this server ([Matrix] Enabled = 0).'));
  Run('/help');
  Check('[Matrix] Enabled = 0: !zitro leaves the per-map commands out', Has('Maps and server') and
    not Has('A player on one map') and not Has('!mapplayerstats') and not Has('!mapweapstats'));
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.MatrixEnabled := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/help');
  Check('!zitro: the per-map commands in three sections, 100 columns', Has('A player over all maps') and
    Has('A player on one map') and Has('One map, all its players') and Has('!playerheatmap[i] [map] [p]') and
    Has('!mapweapstats [map] [flag] [pg]') and Has('!mapwep w* [map]') and Has('!rivals[i] [flag] [pg] [p]') and Fits);

  { ---- the maps by their last game and their last load ---- }
  Run('/topmapsby lastloaded');
  Idx := HeaderLine('#    Map Name');
  Check('!topmapsby lastloaded: the date with its hour, newest first, never last', Has('Top Maps by LastLoaded') and Fits and
    (Idx >= 0) and (Pos('RSCS_Arena', Lines[Idx + 2]) > 0) and
    At(Lines[Idx + 2], Pos('LastLoaded', Lines[Idx]), FormatDateTime('dd.mm.yy ', Now)) and Has('never'));
  Run('/topmapsby lastplayed;lastloaded;kills');
  Check('!topmapsby with dates among other metrics fits', Has('Top Maps by LastPlayed > LastLoaded > Kills') and Fits);

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
      { the kills of each team and how the rounds of an earlier survival match ended }
      KillsByTeam[1] := 300;
      KillsByTeam[2] := 200;
      RoundsElimination[1] := 6;
      RoundsElimination[2] := 4;
      RoundsCapture := 3;
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
  L := LineOf('Alpha by elimination: ');
  Check('!mapstats on CTF: the kill balance of the teams and how the survival rounds of before ended',
    Has('Kill Balance: Alpha [#] vs Bravo [=]') and Has('Alpha   300 kills ( 60.0%)') and
    (Pos('Alpha by elimination: 6', L) = 1) and At(L, 37, 'Bravo by elimination: 4') and At(L, 71, 'By capture: 3') and
    not Has('Last one standing') and not Has('Team rounds'));
  Run('/mapplayerstats rscs alice');
  Check('!mapplayerstats on CTF: the flags row and the draws of the mode, the rounds from the counters',
    Has('Flag Caps: 0') and Has('Draws: 0') and Has('Rounds: 40W / 30L') and Has('Round First Bloods: 7') and Fits);
  Run('/mapplayerstats laos bob');
  Check('!mapplayerstats on CTF of a player without a record there', Has('No per-map data yet for Bob on ctf_Laos.'));
  { Carl on the Capture the Flag map played now: the flags, the teams, friendly fire and the special
    weapons of !otherstats, from his record }
  EnterCriticalSection(Engine.StateLock);
  try
    RC := Engine.DB.PM.Items[Engine.DB.PM.Obtain(C^.ID, Engine.DB.PM.MapNumber('ctf_Test', True), Now - 1)];
    RC^.Kills := 40;
    RC^.Deaths := 30;
    RC^.TimePlayed := 7200;
    RC^.TimeAlive := 5000;
    RC^.DamageDealt := 9000;
    RC^.DamageReceived := 7000;
    RC^.Caps := 3;
    RC^.Returns := 5;
    RC^.Grabs := 9;
    RC^.FlagHoldTime := 400;
    RC^.FlagDrops := 4;
    RC^.FlagThrows := 1;
    RC^.FlaggerKills := 7;
    RC^.FlaggerAssists := 2;
    RC^.FlagDefenses := 1;
    RC^.KillsWithFlag := 3;
    RC^.FastestCap := 7.5;
    RC^.CapsUnder10s := 1;
    RC^.EscortKills := 6;
    RC^.FlagJuggles := 2;
    RC^.ContestedHolds := 1;
    RC^.BaseDefenseKills := 4;
    RC^.BaseAttackKills := 8;
    RC^.Teamkills := 2;
    RC^.TeamkillDeaths := 1;
    RC^.FriendlyHits := 9;
    RC^.FriendlyHitsBody := 5;
    RC^.HitsByFriendly := 4;
    RC^.SelfHits := 2;
    RC^.DamageFriendly := 300;
    RC^.DamageFriendlyReceived := 120;
    RC^.SaviorKills := 5;
    RC^.AvengerKills := 2;
    RC^.ComebackWins := 1;
    RC^.Wins := 4;
    RC^.Losses := 3;
    RC^.AlphaWins := 3;
    RC^.AlphaLosses := 1;
    RC^.BravoWins := 1;
    RC^.BravoLosses := 2;
    RC^.LeaveLosses := 1;
    PW := PMWeaponOf(RC^, WSLOT_FRAG);
    PW^.Shots := 40;
    PW^.Hits := 12;
    PW := PMWeaponOf(RC^, WSLOT_CLUSTER);
    PW^.Shots := 5;
    PW^.Hits := 4;
    PW := PMWeaponOf(RC^, WEP_M79);
    PW^.Shots := 20;
    PW^.Hits := 10;
    PW := PMWeaponOf(RC^, WEP_LAW);
    PW^.Shots := 8;
    PW^.Hits := 2;
    PW := PMWeaponOf(RC^, WSLOT_FISTS);
    PW^.Hits := 6;
    PW := PMWeaponOf(RC^, WEP_CHAINSAW);
    PW^.Hits := 3;
    PW^.TimeUsed := 90;
    PW := PMWeaponOf(RC^, WEP_FLAMER);
    PW^.Shots := 50;
    PW^.Hits := 25;
    PW := PMWeaponOf(RC^, WSLOT_M2);
    PW^.Hits := 7;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/mapplayerstats carl');
  L := LineOf('Flag Caps: ');
  Check('!mapplayerstats on CTF: the flags with the time held, and the teamkills of friendly fire as !stats has them',
    Has('[ Map Stats: Carl on ctf_Test ]') and (Pos('Flag Caps: 3', L) = 1) and At(L, 71, 'Held: 6m 40s (Grabs: 9)') and
    At(LineOf('Dealt: '), 71, 'TK Dmg: 300') and (Pos('Teamkills: 2', LineOf('Teamkills: ')) = 1) and
    At(LineOf('Teamkills: '), 37, 'TK Deaths: 1') and At(LineOf('Teamkills: '), 71, 'Assists: 0') and
    not Has('Bow Kills') and not Has('Knife Throws') and Fits);
  Run('/mapplayerotherstats carl');
  Check('!mapplayerotherstats on CTF: the flags of !otherstats row by row, from the record',
    Has('Flags on this Map') and Has('Flag Drops: 4 (1 thrown)') and Has('Flagger Kills: 7') and
    Has('Flagger Assists: 2') and Has('Flag Defense: 1') and Has('Kills w/ Flag: 3') and Has('Flag Hold: 6m 40s') and
    Has('Fastest Cap: 7.5s') and Has('Caps under 10s: 1') and Has('Escort Kills: 6') and Has('Flag Juggles: 2') and
    Has('Contested Holds: 1') and not Has('TK flagger') and Has('Base Attack: 8') and Has('Base Radius: 30 m') and
    not Has('HTF Points') and Fits);
  Check('!mapplayerotherstats on CTF: the team feats, the results of each team and the loss for leaving',
    Has('Saviors: 5') and Has('Avenger Kills: 2') and Has('Comeback Wins: 1') and not Has('Clutches') and
    (Pos('Alpha: 3W / 1L', LineOf('Alpha: ')) = 1) and At(LineOf('Alpha: '), 37, 'Bravo: 1W / 2L') and
    At(LineOf('Alpha: '), 71, 'Left Lost Matches: 1'));
  Check('!mapplayerotherstats: friendly fire - the damage both ways, the teamkills, the friendly hits by zone',
    Has('TK Dmg Out: 300') and Has('TK Dmg In: 120') and Has('TK Kills/Deaths: 2/1') and
    Has('Teamplay & Friendly Incidents') and Has('Deaths by Team: 1') and Has('TK Ratio: 2.00') and
    Has('Friendly Hits: 9') and Has('Hit by Team: 4') and Has('Self Hits: 2') and Has('TK Body: 5'));
  Check('!mapplayerotherstats: the special weapons from the weapons of the record',
    Has('Nades Thrown: 40') and Has('Nade Hits: 12 (30.0%)') and Has('Cluster hits: 4/5') and
    Has('M79 hits: 10/20 (50.0%)') and Has('LAW hits: 2/8 (25.0%)') and Has('Fist Hurts: 6') and
    Has('Saw: 1m 30s, 3 hits') and Has('Flamer hits: 25/50') and Has('M2 MG Hits: 7') and Has('Spawn Kills: 0'));
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
