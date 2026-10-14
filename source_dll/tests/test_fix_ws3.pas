program test_fix_ws3;

{ The fixes of the audit of 2026-10-06 in the commands (ZSC-*): what the caller typed is said back
  within LINE_W, and the other fixes of the commands and views. The commands run as the engine
  thread runs them (with the state lock), on the server console or as a player on the server. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_engine, zs_commands;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  { the console lines of the last command }
  Lines: TStringList;

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

procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := Hwid;
  Ev.S4 := IP;
  Ev.I[0] := TEAM_NONE;
  Ev.I[1] := 1;
  Ev.I[2] := 0;
  Push(Ev);
end;

{ a command from Slot (0 = the server console) as the engine thread runs it; Lines gets what it
  wrote to that slot }
procedure RunFrom(Slot: LongInt; const Text: AnsiString; Source: LongInt; Admin: Boolean);
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    ;
  EnterCriticalSection(Engine.StateLock);
  try
    ExecuteCommand(Engine, Slot, SplitWords(Text), Source, Admin);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Lines.Clear;
  while Engine.PopAction(A) do
    if (A.Kind in [ACT_CONSOLE, ACT_WRITELN]) and (A.Slot = Slot) then
      Lines.Add(A.Text);
end;

procedure Run(const Text: AnsiString);
begin
  RunFrom(0, Text, SRC_CONSOLE, True);
end;

{ a player (no admin) typing a / command }
procedure RunAs(Slot: LongInt; const Text: AnsiString);
begin
  RunFrom(Slot, Text, SRC_COMMAND, False);
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

function LineOf(const Part: AnsiString): AnsiString;
var
  k: LongInt;
begin
  for k := 0 to Lines.Count - 1 do
    if Pos(Part, Lines[k]) > 0 then
      Exit(Lines[k]);
  Result := '';
end;

{ every line of the last command fits LINE_W }
function Fits: Boolean;
var
  k: LongInt;
begin
  Result := Lines.Count > 0;
  for k := 0 to Lines.Count - 1 do
    if Length(Lines[k]) > LINE_W then
    begin
      WriteLn('       too wide (', Length(Lines[k]), '): ', Lines[k]);
      Result := False;
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

{ Count words of junk, as long as a chat line (100 characters) holds or longer }
function Junk(Count: LongInt): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := 1 to Count do
    Result := Result + Format('zq%d ', [k]);
  Result := Trim(Result);
end;

{ ---------------- ZSC-08: what the caller typed, said back within LINE_W ---------------- }

procedure TestEchoes;
var
  Long: AnsiString;
begin
  Long := StringOfChar('q', 150);
  Run('/topby kills ' + Junk(40));
  Check('ZSC-08 !topby: the ignored metrics cut to the line', Fits and (Pos('...', LineOf('[Note] Ignored unknown metric(s): ')) > 0));
  Run('/topby ' + Junk(40));
  Check('ZSC-08 !topby without a metric: the unknown words cut to the line',
    Has('No valid metric given.') and Fits and (Pos('...', LineOf('[Note] Unknown: ')) > 0));
  Run('/topmapsby kills ' + Junk(40));
  Check('ZSC-08 !topmapsby: the ignored metrics cut to the line', Fits and (Pos('...', LineOf('[Note] Ignored unknown')) > 0));
  Run('/topmapsby ' + Junk(40));
  Check('ZSC-08 !topmapsby without a metric: cut to the line', Fits and Has('[Note] Unknown: '));
  Run('/topweaponsby kills ' + Junk(40));
  Check('ZSC-08 !topweaponsby: the ignored metrics cut to the line', Fits and Has('[Note] Ignored unknown metric(s): '));
  Run('/topweaponsby ' + Junk(40));
  Check('ZSC-08 !topweaponsby without a metric: cut to the line', Fits and Has('[Note] Unknown: '));
  Run('/serverweaponsby kills ' + Junk(40));
  Check('ZSC-08 !serverweaponsby: the ignored metrics cut to the line', Fits and Has('[Note] Ignored unknown metric(s): '));
  Run('/allweaponsby kills;' + StringReplace(Junk(1), 'zq1', 'picks;picks;picks;picks;picks;picks;picks;picks;picks;picks', []) +
    ' alice');
  Check('ZSC-08 !allweaponsby: the metrics of the whole server only cut to the line', Fits and
    (Pos('...', LineOf('[Note] Counted for the whole server only')) > 0));
  Run('/zs_search ' + Long);
  Check('ZSC-08 !zs_search: the text found nowhere cut to the line', Fits and Has('No players found matching: qqq'));
  Run('/topmaps ' + Long);
  Check('ZSC-08 !topmaps: the map not found cut to the line', Fits and Has('Map not found: qqq'));
  Run('/wep ' + Long);
  Check('ZSC-08 !wep: the unknown weapon cut to the line', Fits and Has('Unknown weapon: qqq'));
  Run('/serverwep ' + Long);
  Check('ZSC-08 !serverwep: the unknown weapon cut to the line', Fits and Has('Unknown weapon: qqq'));
  Run('/topweapons ' + Long);
  Check('ZSC-08 !topweapons: the unknown weapon cut to the line', Fits and Has('Unknown weapon: qqq'));
end;

{ the list limits as after a quiet while: the server's second and every player's waits over }
procedure ResetLimits;
var
  S: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.HeavyWindowMs := 0;
    Engine.HeavyInWindow := 0;
    for S := 1 to MAX_PLAYERS do
    begin
      Engine.Extra[S].HeavyUntilMs := 0;
      Engine.Extra[S].SearchUntilMs := 0;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ the next second of the server-wide list limit; the waits of the players stay }
procedure NextSecond;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.HeavyWindowMs := 0;
    Engine.HeavyInWindow := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function HeavyUsed: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.HeavyInWindow;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ---------------- ZSC-01: names nobody has cannot keep the lists of the server busy ---------------- }

function Busy: Boolean;
begin
  Result := Has('The server is busy with other lists');
end;

procedure TestListBudget;
var
  M: LongInt;
begin
  ResetLimits;
  RunAs(1, '/stats zzqq1');
  Check('ZSC-01 a name nobody has: not found, one turn of the server''s lists', Has('Player not found.') and (HeavyUsed = 1));
  RunAs(1, '/rank zzqq2');
  Check('ZSC-01 the next name of the same player within SearchCooldownSeconds waits, and takes no turn',
    Has('Please wait') and Has('before the next search or page') and not Has('Player not found.') and (HeavyUsed = 1));

  { three players in step, a name each second: in the second after, they wait and the others get
    their lists }
  ResetLimits;
  RunAs(1, '/stats zzqq3');
  RunAs(2, '/stats zzqq4');
  RunAs(3, '/wep ak zzqq5');
  RunAs(5, '/topby kills');
  Check('ZSC-01 three names in one second take the three turns of it', Busy and (HeavyUsed = 3));
  NextSecond;
  RunAs(1, '/stats zzqq6');
  RunAs(2, '/stats zzqq7');
  RunAs(3, '/wep ak zzqq8');
  Check('ZSC-01 a second later the same players wait for their search', Has('Please wait') and (HeavyUsed = 0));
  RunAs(5, '/topby kills');
  Check('ZSC-01 ... and another player gets his list', Has('Top by Kills') and not Busy);

  { the admins on the server have a turn the players cannot take, and no wait for a name }
  ResetLimits;
  RunAs(1, '/stats zzqq9');
  RunAs(2, '/stats zzqq10');
  RunAs(3, '/stats zzqq11');
  RunFrom(4, '/topby deaths', SRC_COMMAND, True);
  Check('ZSC-01 an admin on the server gets a list when the players took every turn', Has('Top by Deaths') and not Busy);
  RunAs(5, '/topby deaths');
  Check('ZSC-01 ... a player does not', Busy);
  ResetLimits;
  RunFrom(4, '/stats zzqq12', SRC_COMMAND, True);
  RunFrom(4, '/stats zzqq13', SRC_COMMAND, True);
  Check('ZSC-01 an admin does not wait between names', Has('Player not found.') and not Has('Please wait'));

  { a name nobody had a moment ago is answered without going through every account again, until an
    account is made }
  ResetLimits;
  RunAs(1, '/stats zzmem');
  ResetLimits;
  RunAs(2, '/rank zzmem');
  Check('ZSC-01 a name nobody had a moment ago: not found at once, no turn of the lists',
    Has('Player not found.') and (HeavyUsed = 0));
  ResetLimits;
  RunAs(1, '/stats zzmem3');
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.CreateProfile('Zzmem3 Offline', '', 'HWZZ3', '9.9.9.3', 1000);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  ResetLimits;
  RunAs(2, '/stats zzmem3');
  Check('ZSC-01 ... and found once an account has it', (M >= 0) and Has('Stats: Zzmem3 Offline'));

  { two names in one command (!versus): one wait }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.DB.CreateProfile('Offline One', '', 'HWOF1', '9.9.9.4', 1000);
    Engine.DB.CreateProfile('Offline Two', '', 'HWOF2', '9.9.9.5', 1000);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  ResetLimits;
  RunAs(1, '/versus one two');
  Check('ZSC-01 !versus of two accounts not on the server: no wait between the two names',
    not Has('Please wait') and not Has('Player not found.') and (HeavyUsed = 2));

  { the pages of a list that goes through every account wait like the names }
  ResetLimits;
  RunAs(1, '/topby kills');
  RunAs(1, '/zs_next');
  Check('ZSC-01 a page of a heavy list right after it', not Has('Please wait') and Has('Top by Kills'));
  RunAs(1, '/zs_next');
  Check('ZSC-01 the next page within SearchCooldownSeconds waits', Has('Please wait') and Has('search or page') and
    not Has('Top by Kills'));

  { a text without a metric gets the help without a turn of the limits }
  ResetLimits;
  RunAs(1, '/stats zzqq20');
  RunAs(2, '/stats zzqq21');
  RunAs(3, '/stats zzqq22');
  RunAs(5, '/topby zzz');
  Check('ZSC-01 !topby without a metric: the help even when the lists are busy', Has('No valid metric given.') and not Busy);
  RunAs(5, '/topmapsby zzz');
  Check('ZSC-01 !topmapsby without a metric: the help', Has('No valid map metric given.') and not Busy);
  RunAs(5, '/topweaponsby zzz');
  Check('ZSC-01 !topweaponsby without a metric: the help', Has('No valid weapon metric given.') and not Busy);
  NextSecond;
  RunAs(5, '/topby kills');
  Check('ZSC-01 ... and none of them started the player''s wait for a list', Has('Top by Kills') and not Has('Please wait'));
end;

{ ---------------- ZSC-06: !searcha in the chat ---------------- }

procedure TestSearchaChat;
begin
  ResetLimits;
  RunFrom(4, '!searcha 1.1.', SRC_CHAT, True);
  Check('ZSC-06 !searcha in the chat: no admin search, the admin hears to use /searcha',
    Has('Use /searcha <text>, never in chat') and not Has('Admin Search') and not Has('1.1.1.1') and Fits);
  RunFrom(4, '/searcha 1.1.', SRC_COMMAND, True);
  Check('ZSC-06 /searcha as a command: the admin search by the IP', Has('Admin Search: "1.1."') and Has('last IP'));
  RunFrom(4, '!zs_search ali', SRC_CHAT, True);
  Check('ZSC-06 !zs_search of an admin in the chat: the public search, names only',
    Has('Search: "ali"') and not Has('Admin Search') and not Has('Found by'));
  RunFrom(2, '!searcha 1.1.', SRC_CHAT, False);
  Check('ZSC-06 !searcha of a player: for admins', Has('This command is for admins.') and not Has('Admin Search'));
end;

{ ---------------- ZSC-03: !top <player> before a metric named only roughly ---------------- }

{ the place of a player in the ranking, or that he is not in it yet: no list by a metric }
function PlayerAnswer(const Name: AnsiString): Boolean;
begin
  Result := (Has('Top Ranking') or Has(Name + ' is not in the ranking yet.')) and not Has('Top by ');
end;

procedure TestTopPlayer;
begin
  Run('/top Frog');
  Check('ZSC-03 !top Frog (a player on the server, one letter from "frag"): his place, no grenade kills',
    PlayerAnswer('Frog') and not Has('!topby'));
  Run('/top Pika');
  Check('ZSC-03 !top Pika (one letter from "pila"): his place, no chainsaw kills', PlayerAnswer('Pika'));
  Run('/top 0');
  Check('ZSC-03 !top 0: what !top takes, no USSOCOM kills', Has('Usage: !top [page]') and not Has('Top by ') and Fits);
  Run('/top -3');
  Check('ZSC-03 !top -3: what !top takes', Has('Usage: !top [page]') and not Has('Top by '));
  Run('/top 99999999999');
  Check('ZSC-03 !top with a number too big for a page: what !top takes', Has('Usage: !top [page]'));
  Run('/top kills');
  Check('ZSC-03 !top kills: the list by the metric', Has('Top by Kills'));
  Run('/top frag');
  Check('ZSC-03 !top frag: a weapon by a whole name of it is the list of its kills', Has('Top by ') and not Has('Top Ranking'));
  Run('/top ak deaths');
  Check('ZSC-03 !top ak deaths: metrics after a weapon by its whole name', Has('Top by ') and Has('Deaths'));
  Run('/top k');
  Check('ZSC-03 !top k with a player called K on the server: his place, and where the list by kills is',
    PlayerAnswer('K') and Has('The list by that metric: !topby k'));
  Run('/top kal');
  Check('ZSC-03 !top kal (nobody of that name, a beginning of a weapon word): not found, and where the list is',
    Has('Player not found.') and Has('The list by that metric: !topby kal') and not Has('Top by '));
  Run('/topby kal');
  Check('ZSC-03 !topby keeps the weapons by a beginning of their names', Has('Top by '));
end;

{ ---------------- ZSC-04: no share or average of a few on top of a list ---------------- }

function IndexOfLine(const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  for k := 0 to Lines.Count - 1 do
    if Pos(Part, Lines[k]) > 0 then
      Exit(k);
  Result := -1;
end;

{ the cell of a row at the column of a header (the line that starts with Head) }
function CellAt(const RowPart, Head, Column: AnsiString): AnsiString;
var
  H, R: AnsiString;
  p: LongInt;
begin
  Result := '';
  if IndexOfLine(Head) < 0 then
    Exit;
  H := Lines[IndexOfLine(Head)];
  R := LineOf(RowPart);
  p := Pos(Column, H);
  if (p > 0) and (R <> '') then
    Result := Trim(Copy(R, p, Pos(' ', Copy(R, p, MaxInt) + ' ') - 1));
end;

procedure SetSamplePercent(V: LongInt);
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.MinSamplePercent := V;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure TestMinSample;
var
  A, B, C, D: PPlayerProfile;
  M, M2: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    B := Prof(2);
    C := Prof(3);
    D := Prof(4);
    { Alice: many shots, hits, measured hits and matches; Bob one shot that hit; Carl one hit from
      180 m; Dave one match won }
    A^.Shots := 165600;
    A^.ShotsHits := 42000;
    A^.HitDistSum := 4000 * 20.0;
    A^.HitDistCount := 4000;
    A^.Wins := 60;
    A^.Loses := 40;
    A^.Weapons[WEP_AK74].Shots := 5000;
    A^.Weapons[WEP_AK74].Hits := 1000;
    A^.Weapons[WEP_AK74].Kills := 300;
    A^.Weapons[WEP_AK74].HitDistSum := 4000 * 20.0;
    A^.Weapons[WEP_AK74].HitDistCount := 4000;
    B^.Shots := 1;
    B^.ShotsHits := 1;
    B^.Weapons[WEP_AK74].Shots := 1;
    B^.Weapons[WEP_AK74].Hits := 1;
    B^.Weapons[WEP_MP5].Shots := 500;
    B^.Weapons[WEP_MP5].Hits := 100;
    B^.Weapons[WEP_MP5].Kills := 10;
    C^.HitDistSum := 180;
    C^.HitDistCount := 1;
    C^.Weapons[WEP_MP5].HitDistSum := 180;
    C^.Weapons[WEP_MP5].HitDistCount := 1;
    D^.Wins := 1;
    { the map of the match measured well, another one once from far }
    M := Engine.DB.FindMap('rscs_ws3', False);
    M2 := Engine.DB.FindMap('ws3_far', True);
    if (M >= 0) and (M2 >= 0) then
    begin
      Engine.DB.Maps[M].HitDistSum := 2000 * 18.5;
      Engine.DB.Maps[M].HitDistCount := 2000;
      Engine.DB.Maps[M].ActiveTimePlays := 3600;
      Engine.DB.Maps[M2].HitDistSum := 300;
      Engine.DB.Maps[M2].HitDistCount := 1;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSC-04 the maps of the test', (M >= 0) and (M2 >= 0));

  Run('/topby acc');
  Check('ZSC-04 !topby acc: 25.4% of 165 600 shots before 100% of one shot', (IndexOfLine('Alice') >= 0) and
    (IndexOfLine('Alice') < IndexOfLine('Bob')) and (CellAt('Alice', '#    Nick', 'Acc%') = '25.4%') and
    (CellAt('Bob', '#    Nick', 'Acc%') = '-') and Fits);
  Check('ZSC-04 !topby acc: the note says what the "-" needs',
    Has('[Note] "-" = too few yet, listed last. Needed: Acc% 100 shots'));
  Run('/topby hitdist');
  Check('ZSC-04 !topby hitdist (5.6): 20 m of 4000 hits before 180 m of one', (IndexOfLine('Alice') >= 0) and
    (IndexOfLine('Alice') < IndexOfLine('Carl')) and (CellAt('Carl', '#    Nick', 'HitDist') = '-') and
    Has('HitDist 20 measured hits'));
  Run('/topby winrate;kills');
  Check('ZSC-04 !topby winrate;kills: 60% of 100 matches before 100% of one', (IndexOfLine('Alice') >= 0) and
    (IndexOfLine('Alice') < IndexOfLine('Dave')) and (CellAt('Dave', '#    Nick', 'Win%') = '-') and Has('Win% 10 matches') and
    Fits);
  Run('/topby kills');
  Check('ZSC-04 a count has no need: no note', Has('Top by Kills') and not Has('too few yet'));
  Run('/topby help');
  Check('ZSC-04 !topby help says it', Has('A share or an average of too few (acc: 100 shots, winrate: 10 matches) is "-"') and
    Fits);
  Run('/allweaponsby acc bob');
  Check('ZSC-04 !allweaponsby acc: the MP5 of 500 shots before the AK of one', (IndexOfLine('MP5') >= 0) and
    (IndexOfLine('MP5') < IndexOfLine('AK-74')) and (CellAt('AK-74', 'Weapon ', 'Acc%') = '-') and Has('Acc% 100 shots') and Fits);
  Run('/topweaponsby hitdist');
  Check('ZSC-04 !topweaponsby hitdist: the AK of 4000 hits before the MP5 of one from 180 m',
    (IndexOfLine('AK-74') >= 0) and (IndexOfLine('AK-74') < IndexOfLine('MP5')) and (CellAt('MP5', '#    Weapon', 'HitDist') = '-') and
    Has('HitDist 20 measured hits') and Fits);
  Run('/topmapsby hitdist');
  Check('ZSC-04 !topmapsby hitdist: the map of 2000 hits before the one of one hit from 300 m',
    (IndexOfLine('rscs_ws3') >= 0) and (IndexOfLine('rscs_ws3') < IndexOfLine('ws3_far')) and
    (CellAt('ws3_far', '#    Map Name', 'HitDist') = '-') and Has('HitDist 20 measured hits') and Fits);

  { MinSamplePercent: 0 = the lists of before, 1 = a hundredth of the need }
  SetSamplePercent(0);
  Run('/topby acc');
  Check('ZSC-04 MinSamplePercent = 0: one shot ranks again, no note', (IndexOfLine('Bob') >= 0) and
    (IndexOfLine('Bob') < IndexOfLine('Alice')) and (CellAt('Bob', '#    Nick', 'Acc%') = '100.0%') and not Has('too few yet'));
  Run('/topby help');
  Check('ZSC-04 MinSamplePercent = 0: the help says nothing of it', not Has('too few'));
  SetSamplePercent(50);
  Run('/topby winrate');
  Check('ZSC-04 MinSamplePercent = 50: half the need (5 matches)', (CellAt('Dave', '#    Nick', 'Win%') = '-') and
    Has('Win% 5 matches'));
  SetSamplePercent(1);
  Run('/topby acc');
  Check('ZSC-04 MinSamplePercent = 1: one shot is enough for a need of 100', CellAt('Bob', '#    Nick', 'Acc%') = '100.0%');
  SetSamplePercent(100);
end;

{ ---------------- ZSC-05: the sums of every account are not made again for every player ---------------- }

procedure SetAkKills(Kills: LongInt);
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Prof(1)^.Weapons[WEP_AK74].Kills := Kills;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure TestServerSums;
var
  T0: Int64;
  k, n: LongInt;
  Slow, Fast: Int64;
begin
  SetAkKills(300);
  { the console adds every account up anew, and keeps the sums for the players }
  Run('/serverweapons');
  Check('ZSC-05 /serverweapons on the console: the AK kills of every account', CellAt('AK-74', 'Weapon ', 'Kills') = '300');
  SetAkKills(1300);
  ResetLimits;
  RunAs(1, '/serverweapons');
  Check('ZSC-05 !serverweapons of a player a moment later: the sums kept (300, not yet 1300)',
    CellAt('AK-74', 'Weapon ', 'Kills') = '300');
  RunAs(2, '/serverwep ak');
  Check('ZSC-05 !serverwep of a player: the same sums', Has('Kills: 300'));
  RunAs(3, '/server');
  Check('ZSC-05 !server of a player: the same sums', Has('Top Gun (Kills): AK-74 (300)'));
  { three lists a second on the whole server }
  NextSecond;
  RunAs(4, '/topweaponsby kills');
  Check('ZSC-05 !topweaponsby of a player: the same sums', CellAt('AK-74', '#    Weapon', 'Kills') = '300');
  RunAs(5, '/serverweaponsby kills');
  Check('ZSC-05 !serverweaponsby of a player: the same sums', CellAt('AK-74', 'Weapon ', 'Kills') = '300');
  Run('/serverweapons');
  Check('ZSC-05 the console sees the change at once', CellAt('AK-74', 'Weapon ', 'Kills') = '1300');
  SetAkKills(2300);
  ResetLimits;
  RunAs(1, '/serverweapons');
  Check('ZSC-05 ... and keeps it for the players', CellAt('AK-74', 'Weapon ', 'Kills') = '1300');
  { a new account: added up anew }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.DB.CreateProfile('Sums New', '', 'HWSN', '9.9.9.9', 1000);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  ResetLimits;
  RunAs(2, '/serverweapons');
  Check('ZSC-05 a new account: the sums are made again', CellAt('AK-74', 'Weapon ', 'Kills') = '2300');
  RunAs(3, '/serverwep ak');
  Check('ZSC-05 a new account: !serverwep made again', Has('Kills: 2300'));

  { many accounts: a player's view after the first is no new sum over all of them }
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 1 to 20000 do
      Engine.DB.CreateProfile(Format('Bulk%d', [k]), '', Format('HWB%d', [k]), '8.8.8.8', 1000);
    n := Engine.DB.LiveProfiles;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  ResetLimits;
  T0 := MicroNow;
  RunAs(1, '/serverweapons');
  Slow := MicroNow - T0;
  ResetLimits;
  T0 := MicroNow;
  RunAs(2, '/serverweapons');
  Fast := MicroNow - T0;
  WriteLn(Format('       !serverweapons with %d accounts: %d us, then %d us', [n, Slow, Fast]));
  Check('ZSC-05 !serverweapons with 20 000 accounts: the second player''s view takes a fraction of the first',
    (CellAt('AK-74', 'Weapon ', 'Kills') = '2300') and (Fast * 4 < Slow));
  { !server and !serverwep: the weapon sums kept; !server still counts the visitors of every account }
  T0 := MicroNow;
  Run('/server');
  Slow := MicroNow - T0;
  ResetLimits;
  T0 := MicroNow;
  RunAs(3, '/server');
  Fast := MicroNow - T0;
  WriteLn(Format('       !server: %d us on the console, %d us for a player', [Slow, Fast]));
  Check('ZSC-05 !server of a player with 20 000 accounts: faster than adding everything up', Has('Top Gun (Kills): AK-74 (2300)') and
    (Fast < Slow));
  T0 := MicroNow;
  Run('/serverwep ak');
  Slow := MicroNow - T0;
  ResetLimits;
  T0 := MicroNow;
  RunAs(4, '/serverwep ak');
  Fast := MicroNow - T0;
  WriteLn(Format('       !serverwep ak: %d us on the console, %d us for a player', [Slow, Fast]));
  Check('ZSC-05 !serverwep of a player with 20 000 accounts: a fraction of adding everything up', Has('Kills: 2300') and
    (Fast * 4 < Slow));
end;

{ ---------------- ZSC-09 (the documentation): !achievements shows five names a line ---------------- }

procedure TestAchievementRows;
var
  P: PPlayerProfile;
  k, c, First, Rows, Names: LongInt;
  Ok: Boolean;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(5);
    SetLength(P^.Achievements, 50);
    for k := 0 to 49 do
    begin
      P^.Achievements[k].Id := k + 1;
      P^.Achievements[k].Date := Now;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/achievements frog');
  First := IndexOfLine('Achievements of Frog: 50/50');
  Rows := 0;
  Ok := First >= 0;
  if Ok then
    for k := First + 1 to Lines.Count - 1 do
    begin
      if (Lines[k] = '') or (Lines[k][1] = '=') or (Pos('Season badges', Lines[k]) = 1) then
        Break;
      Inc(Rows);
      { a name starts at each of the five columns }
      Names := 0;
      for c := 0 to 4 do
        if (c * (LINE_W div 5) < Length(Lines[k])) and (Lines[k][c * (LINE_W div 5) + 1] <> ' ') then
          Inc(Names);
      if Names <> 5 then
        Ok := False;
    end;
  Check('ZSC-09 !achievements: the 50 names five to a line, in ten lines',
    Ok and (Rows = 10) and Fits);
end;

var
  Root: AnsiString;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'fix_ws3_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Lines := TStringList.Create;

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);

  CurTick := 0;
  MapAfter('rscs_ws3', GS_DM, MF_SURVIVAL or MF_REALISTIC);
  Join(1, 'Alice', 'S3001', 'HWA', '1.1.1.1');
  Join(2, 'Bob', 'S3002', 'HWB', '2.2.2.2');
  Join(3, 'Carl', 'S3003', 'HWC', '3.3.3.3');
  Join(4, 'Dave', 'S3004', 'HWD', '4.4.4.4');
  { players called like a weapon or a metric }
  Join(5, 'Frog', 'S3005', 'HWF', '5.5.5.5');
  Join(6, 'Pika', 'S3006', 'HWP', '6.6.6.6');
  Join(7, 'K', 'S3007', 'HWK', '7.7.7.7');
  Check('joins processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('the accounts of the players on the server', (Prof(1) <> nil) and (Prof(2) <> nil) and (Prof(3) <> nil) and
      (Prof(4) <> nil));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  TestEchoes;
  TestSearchaChat;
  TestTopPlayer;
  TestListBudget;
  TestMinSample;
  TestServerSums;
  TestAchievementRows;

  Engine.Free;
  Lines.Free;
  SetCurrentDir(ExtractFileDir(Root));
  DeleteTree(Root);
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
