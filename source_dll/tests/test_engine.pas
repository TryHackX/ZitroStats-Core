program test_engine;

{ End-to-end run of the engine thread: events in, output and database state out, restart. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_fileio, zs_db, zs_rank, zs_engine, zs_commands, zs_weapons,
  zs_config, zs_export;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console: TStringList;
  { the last line-of-sight question the library asked, see DrainActions }
  LastRay: TZSAction;
  LastIntegrity: TZSAction;
  RayQuestions: LongInt;

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

procedure DrainActions;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
  begin
    if A.Kind = ACT_RAYCAST then
    begin
      LastRay := A;
      Inc(RayQuestions);
    end;
    if A.Kind = ACT_INTEGRITY then
      LastIntegrity := A;
    Console.Add(Format('%d|%d|%s', [A.Kind, A.Slot, A.Text]));
  end;
end;

procedure Integrity(Slot, Kind, Team, Value, Extra: LongInt; const Text: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeIntegrity);
  Ev.Slot := Slot;
  Ev.I[0] := Kind;
  Ev.I[1] := Team;
  Ev.I[2] := Value;
  Ev.I[3] := Extra;
  Ev.S1 := Text;
  Push(Ev);
end;

procedure RayAnswer(Id, Answer: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeRay);
  Ev.I[0] := Id;
  Ev.I[1] := Answer;
  Push(Ev);
end;

function FileText(const Path: AnsiString): AnsiString;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
      Result := L.Text;
    except
      Result := '';
    end;
  finally
    L.Free;
  end;
end;

procedure WriteFileText(const Path, Text: AnsiString);
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

function CountFiles(const Mask: AnsiString): LongInt;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(Mask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then
        Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function SeenCount(const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to Console.Count - 1 do
    if Pos(Part, Console[k]) > 0 then
      Inc(Result);
end;

function Seen(const Part: AnsiString): Boolean;
begin
  Result := SeenCount(Part) > 0;
end;

{ the text of a console entry "kind|slot|text" }
function TextOf(const Entry: AnsiString): AnsiString;
var
  p: LongInt;
begin
  Result := Entry;
  p := Pos('|', Result);
  Delete(Result, 1, p);
  p := Pos('|', Result);
  Delete(Result, 1, p);
end;

{ the text of the first line starting with Prefix after the last line that contains Marker }
function LineAfter(const Marker, Prefix: AnsiString): AnsiString;
var
  k, From: LongInt;
begin
  Result := '';
  From := -1;
  for k := Console.Count - 1 downto 0 do
    if Pos(Marker, Console[k]) > 0 then
    begin
      From := k;
      Break;
    end;
  if From < 0 then
    Exit;
  for k := From + 1 to Console.Count - 1 do
    if Copy(TextOf(Console[k]), 1, Length(Prefix)) = Prefix then
      Exit(TextOf(Console[k]));
end;

{ the text of the last line that contains Part }
function LineWith(const Part: AnsiString): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := Console.Count - 1 downto 0 do
    if Pos(Part, Console[k]) > 0 then
      Exit(TextOf(Console[k]));
end;

{ The script opens every tick with BeginActions: a few lines per player, a few console lines and
  broadcasts, two team moves; each queue keeps its order and nothing is lost. }
procedure CheckPacedOutput;
var
  A: TZSAction;
  Tick, i, s, Total, Writes, Broad, Moves, WNext, BNext, MovesSeen: LongInt;
  PerSlot: array[0..MAX_PLAYERS] of LongInt;
  Next: array[1..3] of LongInt;
  Ok, InOrder, MoveLast: Boolean;
begin
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to 40 do
      for s := 1 to 3 do
        Engine.Say(s, Format('P%d-%.3d', [s, i]), 0);
    for s := 1 to 3 do
      Engine.ForceSpectator(s);
    for i := 1 to 10 do
      Engine.WriteServer(Format('W-%.3d', [i]));
    for i := 1 to 5 do
      Engine.Broadcast(Format('B-%.3d', [i]), 0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Ok := True;
  InOrder := True;
  MoveLast := True;
  for s := 1 to 3 do
    Next[s] := 1;
  WNext := 1;
  BNext := 1;
  MovesSeen := 0;
  Tick := 0;
  while Tick < 200 do
  begin
    { a tick every 10 ms: ticks that come back to back (Soldat catching up) send nothing }
    Sleep(10);
    if Engine.BeginActions = 0 then
      Break;
    Inc(Tick);
    FillChar(PerSlot, SizeOf(PerSlot), 0);
    Total := 0;
    Writes := 0;
    Broad := 0;
    Moves := 0;
    while Engine.PopAction(A) do
      case A.Kind of
        ACT_CONSOLE:
          if (A.Slot >= 1) and (A.Slot <= 3) then
          begin
            Inc(PerSlot[A.Slot]);
            Inc(Total);
            if A.Text <> Format('P%d-%.3d', [A.Slot, Next[A.Slot]]) then
              InOrder := False;
            Inc(Next[A.Slot]);
          end;
        ACT_SETTEAM:
          begin
            Inc(Moves);
            Inc(MovesSeen);
            { a player's move stays behind the lines that were queued for them first }
            if (A.Slot >= 1) and (A.Slot <= 3) then
              if Next[A.Slot] <> 41 then
                MoveLast := False;
          end;
        ACT_WRITELN:
          if Copy(A.Text, 1, 2) = 'W-' then
          begin
            Inc(Writes);
            if A.Text <> Format('W-%.3d', [WNext]) then
              InOrder := False;
            Inc(WNext);
          end;
        ACT_BROADCAST:
          if Copy(A.Text, 1, 2) = 'B-' then
          begin
            Inc(Broad);
            if A.Text <> Format('B-%.3d', [BNext]) then
              InOrder := False;
            Inc(BNext);
          end;
      end;
    for s := 1 to 3 do
      if PerSlot[s] > PACE_PLAYER_LINES then
        Ok := False;
    if (Total > PACE_LINES) or (Writes > PACE_WRITES) or (Broad > PACE_BROADCASTS) or (Moves > PACE_MOVES) then
      Ok := False;
  end;
  WriteLn(Format('       paced output: 120 lines, 3 moves, 10 console lines, 5 broadcasts in %d ticks', [Tick]));
  { two ticks right after each other: the second one is a catch-up tick and sends nothing }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Say(1, 'catch-up', 0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Sleep(10);
  i := Engine.BeginActions;
  Check('a tick right after the last one sends nothing', (i > 0) and (Engine.BeginActions = 0));
  DrainActions;
  Check('output is paced: 4 lines a player, 2 moves, 4 console lines and 2 broadcasts a tick', Ok);
  Check('every queue keeps its order, a move stays behind the lines before it', InOrder and MoveLast);
  Check('and everything arrives', (Next[1] = 41) and (Next[2] = 41) and (Next[3] = 41) and (WNext = 11) and
    (BNext = 6) and (MovesSeen = 3));
end;

{ Every line of the command overview, from its header to its closing frame (" by TryHackX "), fits
  the LINE_W columns of its frame. The overview is one command's output, so its lines also share
  the kind and slot of the header ("kind|slot|"): a line without them ends it as well. }
function HelpLinesFit: Boolean;
var
  k, Bar, First: LongInt;
  T, Prefix: AnsiString;
  Closed: Boolean;
begin
  Result := False;
  First := -1;
  for k := 0 to Console.Count - 1 do
    if Pos(' - commands ', Console[k]) > 0 then
    begin
      First := k;
      Break;
    end;
  if First < 0 then
    Exit;
  T := Console[First];
  Bar := Pos('|', T);
  Bar := Bar + Pos('|', Copy(T, Bar + 1, MaxInt));
  Prefix := Copy(T, 1, Bar);
  Closed := False;
  k := First;
  Result := True;
  while not Closed and (k < Console.Count) and (Copy(Console[k], 1, Length(Prefix)) = Prefix) do
  begin
    T := Copy(Console[k], Length(Prefix) + 1, MaxInt);
    if Length(T) > LINE_W then
    begin
      WriteLn('  too wide (', Length(T), '): ', T);
      Result := False;
    end;
    Closed := Pos(' by TryHackX ', T) > 0;
    Inc(k);
  end;
  Result := Result and Closed;
end;

procedure MapAfter(const Name: AnsiString; Style, Limit: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := Limit;
  Push(Ev);
end;

{ a map with the MF_* flags of the mode (survival, realistic, advance) }
procedure MapAfterFlags(const Name: AnsiString; Style, Limit, Flags: LongInt);
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

procedure MapBefore(A, B, TimeLeft, Limit: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapBefore);
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Ev.I[5] := Limit;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Team, Admin: LongInt);
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
  Ev.I[2] := Admin;
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

{ a spawn with both weapons; WEP_NONE when the weapon menu is still open }
procedure SpawnWith(Slot, Primary, Secondary: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSpawn);
  Ev.Slot := Slot;
  Ev.I[0] := Primary;
  Ev.I[1] := Secondary;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure JoinBot(Slot: LongInt; const Name: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.I[0] := Team;
  Push(Ev);
end;

procedure LeaveEv(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(Ev);
end;

{ OnKitPickup as main.pas sends it (ZS_Ev_Kit): the slot and the style of the kit }
procedure KitEv(Slot, Style: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKit);
  Ev.Slot := Slot;
  Ev.I[0] := Style;
  Push(Ev);
end;

procedure TeamSwitch(Slot, Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTeam);
  Ev.Slot := Slot;
  Ev.I[0] := Team;
  Push(Ev);
end;

procedure Shot(Slot, Weapon: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeShot);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := 1;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ the ammunition of the weapon in hand changed, as main.pas reports it }
procedure Ammo(Slot, Weapon, OldAmmo, NewAmmo, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeAmmo);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := OldAmmo;
  Ev.I[2] := NewAmmo;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure WeaponChange(Slot, Primary, Secondary, PrimaryAmmo, SecondaryAmmo: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeWeapon);
  Ev.Slot := Slot;
  Ev.I[0] := Primary;
  Ev.I[1] := Secondary;
  Ev.I[2] := PrimaryAmmo;
  Ev.I[3] := SecondaryAmmo;
  Ev.I[4] := 1;
  Push(Ev);
end;

procedure Damage(S, V, Weapon: LongInt; Dmg, BX, BY, BVX, BVY, VX, VY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeDamage);
  Ev.Slot := S;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := EF_BULLET or EF_B_ONGROUND;
  Ev.F[0] := Dmg;
  Ev.F[2] := BX;
  Ev.F[3] := BY;
  Ev.F[4] := BVX;
  Ev.F[5] := BVY;
  Ev.F[6] := VX;
  Ev.F[7] := VY;
  Push(Ev);
end;

procedure Kill(K, V, Weapon, VictimWeapon: LongInt; KX, KY, VX, VY, BX, BY: Single; Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags;
  Ev.I[3] := VictimWeapon;
  Ev.F[0] := KX;
  Ev.F[1] := KY;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Ev.F[4] := BX;
  Ev.F[5] := BY;
  Push(Ev);
end;

procedure Flag(Slot, Kind: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeFlag);
  Ev.Slot := Slot;
  Ev.I[0] := Kind;
  Push(Ev);
end;

{ a position sample of main.pas; Flags say alive, flag carrier, pose }
procedure Sample(Slot, Flags: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSample);
  Ev.Slot := Slot;
  Ev.I[0] := Flags;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := 30;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ the HUD notes of a slot waiting for the next refresh, as one line }
function HudNotes(Slot: LongInt): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := 0 to High(Engine.Extra[Slot].HudEvents) do
    Result := Result + '|' + Engine.Extra[Slot].HudEvents[k];
end;

{ the text of the last HUD line sent to Slot that holds Part (any line for ''), '' for none }
function HudLineWith(Slot: LongInt; const Part: AnsiString): AnsiString;
var
  k: LongInt;
  Prefix: AnsiString;
begin
  Result := '';
  Prefix := Format('%d|%d|Rank: ', [ACT_BIGTEXT, Slot]);
  for k := Console.Count - 1 downto 0 do
    if (Copy(Console[k], 1, Length(Prefix)) = Prefix) and ((Part = '') or (Pos(Part, Console[k]) > 0)) then
      Exit(TextOf(Console[k]));
end;

procedure TickEv(A, B, TimeLeft: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTick);
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Push(Ev);
end;

procedure Cmd(Slot: LongInt; const Text: AnsiString; Source, Admin: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  Ev.I[0] := Source;
  Ev.I[1] := Admin;
  Push(Ev);
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

{ the accounts of the survival tests by the slot they play in }
function PS(Slot: LongInt): PPlayerProfile;
begin
  case Slot of
    2: Result := Prof('S1002');
    3: Result := Prof('S1003');
    4: Result := Prof('S1005');
    5: Result := Prof('S1004');
    6: Result := Prof('S1006');
    else Result := nil;
  end;
end;

var
  Root, ExportText: AnsiString;
  A, B, C: PPlayerProfile;
  i, SavedPoints, BobPoints, M, HeadLines, Kills: LongInt;
  T0: Int64;
  Done, Ok: Boolean;
  { the survival tests: the accounts before, by slot, and the weapon picks of the server before }
  Snap: array[1..8] of TPlayerProfile;
  Picks0: array[0..WSLOT_COUNT - 1] of Int64;
  VoteEv: TZSEvent;
  VoteStarts0, VotesWon0: LongInt;
  { the spree messages: an action of each kind the test looks at, and the settings before }
  Act, OpenAct, StopAct: TZSAction;
  SavedCfg: TZSConfig;
  Opens, Stops, W: LongInt;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'engine_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Console := TStringList.Create;

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);

  CurTick := 0;
  MapAfter('ctf_Ash', GS_CTF, 10);
  Join(1, 'Alice', 'S1001', 'HWA', '1.1.1.1', TEAM_ALPHA, 0);
  Join(2, 'Bob', 'S1002', 'HWB', '2.2.2.2', TEAM_BRAVO, 1);
  Join(3, 'Carl', 'S1003', 'HWC', '3.3.3.3', TEAM_ALPHA, 0);
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_BARRETT, 1500, 100);
  Spawn(3, WEP_MP5, 120, 100);
  CurTick := 20;
  Shot(1, WEP_AK74, 100, 100);
  CurTick := 102;
  Damage(1, 2, WEP_AK74, 30, 1480, 90, 40, 0, 1500, 100);
  Kill(1, 2, WEP_AK74, WEP_BARRETT, 100, 100, 1500, 100, 1480, 90, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND or EF_RAY_CAL);
  CurTick := 150;
  Kill(1, 3, WEP_AK74, WEP_MP5, 100, 100, 120, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 200;
  Spawn(2, WEP_BARRETT, 1500, 100);
  Spawn(3, WEP_MP5, 120, 100);
  Flag(1, FLAG_GRAB);
  CurTick := 800;
  Flag(1, FLAG_SCORE);
  for i := 1 to 3 do
  begin
    CurTick := 800 + i * 60;
    TickEv(1, 0, 300);
  end;
  Cmd(2, '/stats', SRC_COMMAND, 1);
  Cmd(0, '/zs_status', SRC_CONSOLE, 1);
  { the server console has no per-second command limit, so the command tour runs there }
  Cmd(0, '/otherstats alice', SRC_CONSOLE, 1);
  Cmd(0, '/top', SRC_CONSOLE, 1);
  Cmd(0, '/topby kd;acc', SRC_CONSOLE, 1);
  Cmd(0, '/next', SRC_CONSOLE, 1);
  Cmd(0, '/zsnext', SRC_CONSOLE, 1);
  Cmd(0, '/topmaps', SRC_CONSOLE, 1);
  Cmd(0, '/mapstats', SRC_CONSOLE, 1);
  Cmd(0, '/allweapons alice', SRC_CONSOLE, 1);
  Cmd(0, '/wep ak alice', SRC_CONSOLE, 1);
  Cmd(0, '/matchup ak', SRC_CONSOLE, 1);
  Cmd(0, '/matchup', SRC_CONSOLE, 1);
  Cmd(0, '/server', SRC_CONSOLE, 1);
  Cmd(0, '/zs_search ali', SRC_CONSOLE, 1);
  Cmd(0, '/topday', SRC_CONSOLE, 1);
  Cmd(0, '/topseason', SRC_CONSOLE, 1);
  Cmd(0, '/topskill', SRC_CONSOLE, 1);
  Cmd(0, '/topweapons', SRC_CONSOLE, 1);
  Cmd(0, '/topweaponsby ttk;avgdist', SRC_CONSOLE, 1);
  Cmd(0, '/topmapsby pace', SRC_CONSOLE, 1);
  Cmd(0, '/status alice', SRC_CONSOLE, 1);
  Cmd(0, '/session', SRC_CONSOLE, 1);
  Cmd(0, '/rank alice', SRC_CONSOLE, 1);
  Cmd(0, '/spree alice', SRC_CONSOLE, 1);
  Cmd(0, '/rambo alice', SRC_CONSOLE, 1);
  Cmd(0, '/achievements alice', SRC_CONSOLE, 1);
  Cmd(0, '/achlist alice', SRC_CONSOLE, 1);
  Cmd(0, '/seasons', SRC_CONSOLE, 1);
  Cmd(0, '/zs-status alice', SRC_CONSOLE, 1);
  Cmd(0, '/zs_perf', SRC_CONSOLE, 1);
  Cmd(0, '/zs_suspects', SRC_CONSOLE, 1);
  Cmd(0, '/help', SRC_CONSOLE, 1);
  Cmd(1, '!zssearch ali', SRC_CHAT, 0);
  Cmd(1, '/server', SRC_COMMAND, 0);
  Cmd(3, '/zs_perf', SRC_COMMAND, 0);
  Cmd(0, '/zs_export', SRC_CONSOLE, 1);
  Cmd(0, '/activity', SRC_CONSOLE, 1);
  Cmd(2, '/zs_backups', SRC_COMMAND, 1);
  { Bob already used his 2 commands of this second, the limit would drop a third one }
  Cmd(3, '/yes hunter2', SRC_COMMAND, 1);
  Check('events processed', WaitProcessed);
  DrainActions;

  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    C := Prof('S1003');
    Check('accounts created from SteamIDs', (A <> nil) and (B <> nil) and (C <> nil));
    if (A <> nil) and (B <> nil) and (C <> nil) then
    begin
      Check('kill counted', (A^.Kills = 1) and (B^.Deaths = 1) and (A^.FirstBloodCount = 1));
      WriteLn(Format('       points: Alice %d, Bob %d, Carl %d; distance %s m', [A^.Points, B^.Points, C^.Points,
        FloatStr(A^.LongestKillDistance, 2)]));
      Check('points: kill 22, capture pool 13 split 7/6', (A^.Points = 1029) and (B^.Points = 965) and (C^.Points = 1006));
      Check('distance measured from the shot', Abs(A^.LongestKillDistance - Hypot(1380, 10) / 14) < 0.1);
      Check('teamkill without points', (A^.Teamkills = 1) and (C^.DeathsByFriendly = 1) and (C^.Deaths = 0));
      Check('capture and cap time', (A^.FlagsScore = 1) and (Abs(A^.FastestCapSeconds - 10) < 0.01));
      Check('seconds counted', A^.TimePlayed >= 3);
      Check('weapon kills and matchup', (A^.Weapons[WEP_AK74].Kills = 1) and
        (Engine.DB.Server.Matchups[WEP_AK74, WEP_BARRETT] = 1));
      Check('ranking is current', Engine.PlayerRank(Engine.DB.IndexOfSteam('S1001')) = 1);
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('!stats answered in the player console', Seen('[ Stats: Bob ]'));
  Check('/zs_status answered on the server console', Seen('[ZitroStats ' + ZS_VERSION_STR + ']'));
  Check('otherstats', Seen('[ Detailed Telemetry: Alice ]'));
  Check('top list', Seen('Top Ranking [Page 1/1]'));
  Check('topby with two metrics', Seen('Top by K/D > Acc%'));
  Check('/zsnext repeats the last list, the plain /next is left to other scripts',
    SeenCount('Top by K/D > Acc%') = 2);
  Check('map stats and top maps', Seen('[ Map Statistics: ctf_Ash ]') and Seen('Top Maps [Page 1/1]'));
  Check('all weapons and weapon deep dive', Seen('All Weapons Breakdown: Alice') and Seen('Weapon: AK-74 - Alice'));
  Check('matchups with the Wilson range', Seen('Matchups: AK-74 [Page 1/1]') and Seen('Top Rivalries [Page 1/1]') and
    Seen('95% Range') and Seen('few duels'));
  Check('server stats', Seen('Server Statistics & Activity Analytics'));
  Check('week by hour', Seen('Server Activity: Week by Hour') and Seen('Most players: '));
  Check('admin and public search', Seen('Admin Search: "ali"') and Seen('Search: "ali" (1 matches)'));
  Check('period, season and skill lists', Seen('Top Today') and Seen('Season ') and Seen('RankingSystem = elo'));
  Check('weapon and map rankings', Seen('Top Weapons by Kills') and Seen('Top Weapons by AvgTTK > AvgDist') and
    Seen('Top Maps by Kills/min'));
  Check('status, rank, spree, rambo, achievements', Seen('[ Status: Alice ]') and Seen('[Rank] Alice') and
    Seen('Records: Alice') and Seen('Rambomatch Stats: Alice') and Seen('Achievements of Alice: 1/50'));
  Check('achievement list two per line, unlocked first', Seen('[x] First Blood') and Seen('[ ] Soldier'));
  Check('seasons with the podium', Seen('1st place') or Seen('No seasons yet'));
  Check('help shows the arguments and the legend', Seen('!statsi n*') and Seen('!stats [p]') and
    Seen('* required  [ ] optional'));
  Check('session needs a player slot', Seen('Session statistics are for players in the game.'));
  Check('account audit with the old spelling', Seen('[ Admin Audit: Alice ]'));
  Check('perf, suspects, admin help', Seen('engine timing since') and Seen('No suspicious kill series') and Seen('Admin commands'));
  Check('every line of the command overview fits its LINE_W columns', HelpLinesFit);
  Check('heavy lists have a cooldown for players', Seen('Please wait'));
  Check('admin commands are refused for players', Seen('This command is for admins.'));
  Check('no engine errors', not Seen('ERROR'));
  { a knife hits at arm's length and has no hit zones, so its deep dive has no zone row }
  HeadLines := SeenCount('Head: ');
  Cmd(0, '/wep knife alice', SRC_CONSOLE, 1);
  Done := WaitProcessed;
  DrainActions;
  Check('knife deep dive without a zone row', Done and Seen('Weapon: Combat Knife - Alice') and
    (SeenCount('Head: ') = HeadLines) and (HeadLines > 0));

  { the kits picked up, by kind: every kit style, humans only; a style that is no kit counts nothing }
  KitEv(1, KIT_MEDICAL);
  KitEv(1, KIT_MEDICAL);
  KitEv(1, KIT_CLUSTER);
  KitEv(1, KIT_VEST);
  KitEv(1, 5);
  KitEv(2, KIT_FLAMER);
  KitEv(2, KIT_BERSERK);
  KitEv(2, KIT_PREDATOR);
  KitEv(3, KIT_GRENADE);
  Cmd(0, '/otherstats alice', SRC_CONSOLE, 1);
  Cmd(0, '/topby kits;medkits', SRC_CONSOLE, 1);
  Done := WaitProcessed;
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    C := Prof('S1003');
    Check('kits picked up counted by kind', Done and (A <> nil) and (B <> nil) and (C <> nil) and
      (A^.KitPickups[0] = 2) and (A^.KitPickups[2] = 1) and (A^.KitPickups[3] = 1) and (KitsPickedUp(A^) = 4) and
      (B^.KitPickups[4] = 1) and (B^.KitPickups[5] = 1) and (B^.KitPickups[6] = 1) and (KitsPickedUp(B^) = 3) and
      (C^.KitPickups[1] = 1) and (KitsPickedUp(C^) = 1));
    Check('a cluster kit still tells the grenades apart', Engine.Live[1].ClusterNades and not Engine.Live[3].ClusterNades);
    { [Bridges] (5.6): what the server's memory tells, set here for the export and taken back after it }
    if A <> nil then
    begin
      A^.CollateralKills := 3;
      A^.BackKills := 2;
      A^.BackDeaths := 1;
      A^.LongestHeadshotM := 87.5;
      A^.LongestFlightKill := 1.5;
      A^.LongestHitM := 80.5;
      A^.HitDistSum := 100;
      A^.HitDistCount := 4;
      A^.HitAirTicks := 90;
      A^.HitAirCount := 3;
      A^.KillAirTicks := 60;
      A^.KillAirCount := 2;
      A^.StanceShots[0] := 10;
      A^.StanceShots[1] := 20;
      A^.StanceShots[3] := 5;
      A^.StanceHits[0] := 4;
      A^.StanceHits[1] := 5;
      A^.StanceHits[3] := 1;
    end;
    ExportText := PlayerJson(Engine, Engine.DB.IndexOfSteam('S1001'));
    if A <> nil then
    begin
      A^.CollateralKills := 0;
      A^.BackKills := 0;
      A^.BackDeaths := 0;
      A^.LongestHeadshotM := 0;
      A^.LongestFlightKill := 0;
      A^.LongestHitM := 0;
      A^.HitDistSum := 0;
      A^.HitDistCount := 0;
      A^.HitAirTicks := 0;
      A^.HitAirCount := 0;
      A^.KillAirTicks := 0;
      A^.KillAirCount := 0;
      FillChar(A^.StanceShots, SizeOf(A^.StanceShots), 0);
      FillChar(A^.StanceHits, SizeOf(A^.StanceHits), 0);
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('players.json: the kits that healed, every kit picked up and each kind',
    (Pos('"heal_kits": 0, "kits": 4, ', ExportText) > 0) and
    (Pos('"kit_pickups": {"medical": 2, "grenade": 0, "cluster": 1, "vest": 1, "berserker": 0, ' +
      '"predator": 0, "flamer": 0}, "achievements": [', ExportText) > 0));
  Check('players.json: what the server''s memory and its bullets tell (5.6)',
    Pos('"collateral_kills": 3, "back_kills": 2, "back_deaths": 1, "longest_headshot_m": 87.5, ' +
      '"longest_bullet_flight_sec": 1.50, "longest_hit_m": 80.5, "avg_hit_dist_m": 25.0, "avg_hit_flight_sec": 0.50, ' +
      '"avg_kill_flight_sec": 0.50, "stance_shots": [10, 20, 0, 5], "stance_hits": [4, 5, 0, 1], ' +
      '"kit_pickups": {', ExportText) > 0);
  Check('!otherstats shows the kits picked up',
    Seen('Kits: Med 2, Nade 0, Cluster 1, Vest 1, Berserk 0, Predator 0, Flamer 0'));
  Check('!topby kits and medkits', Seen('Top by Kits > MedKits'));
  { every answer of the commands above, to look at the layout of the tables }
  Console.SaveToFile(Root + PathDelim + 'console_dump.txt');
  T0 := MonoMs;
  ExportText := '';
  while (MonoMs - T0 < 3000) and (Pos('"format": 2', ExportText) = 0) do
  begin
    Sleep(50);
    ExportText := FileText(Root + PathDelim + 'nickreg' + PathDelim + 'stats.json');
  end;
  Check('JSON export written with the 4.x keys', (Pos('"format": 2', ExportText) > 0) and (Pos('"name": "Alice"', ExportText) > 0) and
    (Pos('"longest_kill_px"', ExportText) > 0) and (Pos('"weapons"', ExportText) > 0));
  Check('stats.json: the maps with the hits'' distance and air time (5.6)',
    Pos('"avg_hit_flight_sec": 0.00, "avg_kill_flight_sec": 0.00, "last_played": ', ExportText) > 0);
  T0 := MonoMs;
  ExportText := '';
  while (MonoMs - T0 < 3000) and (Pos('/yes', ExportText) = 0) do
  begin
    Sleep(50);
    ExportText := FileText(Root + PathDelim + 'logs' + PathDelim + 'zitrostats' + PathDelim + 'audit.log');
  end;
  Check('admin commands in audit.log with the address', (Pos('admin command via console by console: /zs_status', ExportText) > 0) and
    (Pos('admin command via command by Bob (IP 2.2.2.2, account #', ExportText) > 0) and (Pos('/zs_backups', ExportText) > 0));
  Check('audit.log never holds the confirm password', (Pos('/yes ***', ExportText) > 0) and (Pos('hunter2', ExportText) = 0));
  Check('player commands stay out of audit.log', Pos('/activity', ExportText) = 0);

  { the AK kill asked main.pas about the line from where the shot was fired to where it hit }
  Check('line of the lethal shot asked', (RayQuestions = 1) and (LastRay.P1 > 0) and (LastRay.P2 = 100) and
    (LastRay.P3 = 100) and (LastRay.P4 = 1480) and (LastRay.P5 = 90));
  RayAnswer(LastRay.P1 + 1000, RAY_BLOCKED);
  RayAnswer(LastRay.P1, RAY_BLOCKED);
  RayAnswer(LastRay.P1, RAY_BLOCKED);
  Check('ray answers processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    { the test kill says RayCast is calibrated (EF_RAY_CAL) and carries no EF_LOS, so it also counts
      as Cover (live) }
    Check('Cover (shot) counted once, unknown answers ignored', (A <> nil) and (A^.CoverShotKills = 1) and
      (A^.WallKills = 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { what used to be only "started" now also says when it is done }
  Cmd(0, '/zs_save', SRC_CONSOLE, 1);
  Cmd(0, '/zs_backup', SRC_CONSOLE, 1);
  T0 := MonoMs;
  repeat
    Sleep(50);
    WaitProcessed;
    DrainActions;
  until (MonoMs - T0 > 5000) or (Seen('All changes are written.') and Seen('backup saved:') and Seen('Export written:'));
  Check('/zs_save says when the changes are on the disk', Seen('All changes are written.'));
  Check('/zs_backup says when the backup is written', Seen('backup saved:') and Seen('-manual.zsdb'));
  Check('/zs_export says when the files are written', Seen('Export written:') and Seen('stats.json'));
  Cmd(0, '/zs_raytest', SRC_CONSOLE, 1);
  Check('the test command is gone', WaitProcessed and (RayQuestions = 1));

  { /swap says what is wrong }
  Cmd(0, '/swap 0 1', SRC_CONSOLE, 1);
  Cmd(0, '/swap 1 50', SRC_CONSOLE, 1);
  Cmd(0, '/swap 1 5', SRC_CONSOLE, 1);
  Cmd(0, '/swap 1 3', SRC_CONSOLE, 1);
  Cmd(0, '/swap zzz 3', SRC_CONSOLE, 1);
  Cmd(0, '/swap 1 1', SRC_CONSOLE, 1);
  Cmd(0, '/swap alice bob', SRC_CONSOLE, 1);
  Cmd(0, '/move alice purple', SRC_CONSOLE, 1);
  Check('swap commands processed', WaitProcessed);
  DrainActions;
  Check('/swap: no slot 0', Seen('There is no slot 0: the slots are 1-32.'));
  Check('/swap: no slot 50', Seen('There is no slot 50: the slots are 1-32.'));
  Check('/swap: an empty slot', Seen('Slot 5 is empty.'));
  Check('/swap: the same team', Seen('Alice and Carl both play for Alpha'));
  Check('/swap: nobody by that name', Seen('Nobody on the server has "zzz" in the name.'));
  Check('/swap: the same player twice', Seen('Both names are Alice (slot 1)'));
  Check('/swap: two teams are swapped', Seen('Swapping Alice (Alpha) and Bob (Bravo)...'));
  Check('/move: an unknown team', Seen('"purple" is no team'));

  { !wepi takes a ranking position, !wep a player; a part of a weapon name is enough }
  Cmd(0, '/wepi ak 1', SRC_CONSOLE, 1);
  Cmd(0, '/wep barr alice', SRC_CONSOLE, 1);
  Cmd(0, '/wep m alice', SRC_CONSOLE, 1);
  Cmd(0, '/wepi ak', SRC_CONSOLE, 1);
  Cmd(0, '/wep sniperr alice', SRC_CONSOLE, 1);
  Cmd(0, '/achi 1', SRC_CONSOLE, 1);
  Cmd(0, '/achlisti 1', SRC_CONSOLE, 1);
  Cmd(0, '/status bob', SRC_CONSOLE, 1);
  Check('weapon commands processed', WaitProcessed);
  DrainActions;
  Check('!wepi ak 1 is the first of the ranking', SeenCount('Weapon: AK-74 - Alice') >= 2);
  Check('!wep barr finds the Barrett', Seen('Weapon: Barrett M82A1 - Alice'));
  Check('!wep m lists what it can mean', Seen('"m" can be more than one weapon: ') and Seen('M79 (m79)') and
    Seen('HK MP5 (mp5)'));
  Check('!wepi without a position explains itself', Seen('Usage: !wepi <weapon> <ranking position>'));
  Check('a small typo is forgiven', SeenCount('Weapon: Barrett M82A1 - Alice') >= 2);
  Check('!achi and !achlisti take a position', SeenCount('Achievements of Alice') >= 4);
  Check('!status of another player on the server shows the session', SeenCount('Current Session (since joining)') >= 2);

  { the words after a weapon stay the player's; a weapon number is digits only; a number at the
    end of !matchup is the page unless the whole text is a weapon name }
  M := SeenCount('Weapon: Desert Eagles - Alice');
  HeadLines := SeenCount('Matchups: AK-74 [Page 1/');
  Kills := SeenCount('Top Rivalries [Page 1/');
  Cmd(0, '/wep 1 2', SRC_CONSOLE, 1);
  Cmd(0, '/wepi 1 1', SRC_CONSOLE, 1);
  Cmd(0, '/wep xd alice', SRC_CONSOLE, 1);
  Cmd(0, '/wep desert eagles alice', SRC_CONSOLE, 1);
  Cmd(0, '/matchup ak 47', SRC_CONSOLE, 1);
  Cmd(0, '/matchup 0', SRC_CONSOLE, 1);
  Check('weapon words processed', WaitProcessed);
  DrainActions;
  Check('!wep 1 2 is the Deagles of a player called 2, with a hint to !wepi', not Seen('Weapon: Chainsaw') and
    Seen('For ranking position 2: !wepi Deagle 2'));
  Check('!wepi 1 1 and !wep desert eagles alice are the Deagles of Alice', SeenCount('Weapon: Desert Eagles - Alice') = M + 2);
  Check('!wep xd is no weapon (no hexadecimal numbers)', Seen('Unknown weapon: xd.') and not Seen('Weapon: M72 LAW'));
  Check('!matchup ak 47 is the AK-74, not its page 47', SeenCount('Matchups: AK-74 [Page 1/') = HeadLines + 1);
  Check('!matchup 0 is the first page of the rivalries', SeenCount('Top Rivalries [Page 1/') = Kills + 1);

  { names: one letter is enough and the closest name comes first; the session of another player;
    the page and weapon aliases; the server's weapons without deaths; the admin columns }
  Join(4, 'hardkorowy koksu', 'S1005', 'HWE', '5.5.5.5', TEAM_BRAVO, 0);
  Join(5, 'up', 'S1004', 'HWD', '4.4.4.4', TEAM_ALPHA, 0);
  Join(6, 'a', 'S1006', 'HWF', '6.6.6.6', TEAM_ALPHA, 0);
  M := SeenCount('Top Ranking [Page 1/');
  HeadLines := SeenCount('Weapon: AK-74 - Alice');
  Cmd(0, '/rank u', SRC_CONSOLE, 1);
  Cmd(0, '/zs_search a', SRC_CONSOLE, 1);
  Cmd(0, '/session nobodyhere', SRC_CONSOLE, 1);
  Cmd(0, '/session up', SRC_CONSOLE, 1);
  Cmd(0, '/sessioni 1', SRC_CONSOLE, 1);
  Cmd(0, '/top', SRC_CONSOLE, 1);
  Cmd(0, '/zs_next', SRC_CONSOLE, 1);
  Cmd(0, '/weap ak alice', SRC_CONSOLE, 1);
  Cmd(0, '/serverweapons', SRC_CONSOLE, 1);
  Cmd(0, '/serverwep ak', SRC_CONSOLE, 1);
  Check('name commands processed', WaitProcessed);
  DrainActions;
  Check('!rank u finds "up" before a longer name with a u in it', Seen('[Rank] up') and not Seen('[Rank] hardkorowy'));
  WriteLn('       first match of "a": ', LineAfter('Admin Search: "a"', '1 '));
  Check('one letter searches, and the whole name comes first',
    Trim(Copy(LineAfter('Admin Search: "a"', '1 '), 13, 22)) = 'a');
  Check('!session of nobody on the server says so', Seen('No player on the server matches that'));
  Check('!session up and !sessioni 1 show those players', Seen('Session Stats: up') and Seen('Session Stats: Alice'));
  Check('/zs_next pages the ranking', SeenCount('Top Ranking [Page 1/') >= M + 2);
  Check('!weap is !wep', SeenCount('Weapon: AK-74 - Alice') = HeadLines + 1);
  Check('the server weapons show the share of kills, not deaths',
    Seen('Share  Pick%') and Seen('of kills') and (Pos('Deaths', LineWith('Share  Pick%')) = 0) and
    (Pos('Deaths', LineWith('of kills')) = 0));
  { one grid of equal columns for every section, whatever its width }
  ExportText := LineWith('/zs_unregister id*');
  WriteLn('       admin row: ', ExportText);
  i := Pos('!statsi', LineWith('!stats [p]'));
  { a command too long for its column takes two, so the one after it starts two columns on }
  Check('the admin commands start their columns where the other sections do', (i > 1) and
    (Pos('/zs_setpass', ExportText) = i) and (Pos('/removeolderthan', ExportText) = 3 * i - 2) and
    (Pos('/zs_merge', LineWith('/zs_restore f*')) = 4 * i - 3));

  { Bob hits Alice, Alice kills herself a moment later: no kill and no death, Bob earns half of the
    kill points from Alice }
  EnterCriticalSection(Engine.StateLock);
  try
    SavedPoints := Prof('S1001')^.Points;
    BobPoints := Prof('S1002')^.Points;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 1000;
  Damage(2, 1, WEP_BARRETT, 30, 100, 100, -40, 0, 100, 100);
  CurTick := 1010;
  Kill(1, 1, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('selfkill processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    WriteLn(Format('       selfkill under fire: Alice %d -> %d, Bob %d -> %d', [SavedPoints, A^.Points, BobPoints, B^.Points]));
    Check('selfkill under fire: a selfkill, no kill and no death', (A^.Selfkills = 1) and (A^.SelfkillsUnderFire = 1) and
      (A^.Deaths = 0) and (B^.Kills = 0) and (B^.ForcedSelfkills = 1));
    Check('selfkill under fire: half of the kill points move to Bob', (SavedPoints - A^.Points > 0) and
      (SavedPoints - A^.Points < 22) and (B^.Points - BobPoints = SavedPoints - A^.Points));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { without an enemy hit the fixed penalty applies and nobody gets anything }
  EnterCriticalSection(Engine.StateLock);
  try
    SavedPoints := Prof('S1001')^.Points;
    BobPoints := Prof('S1002')^.Points;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Spawn(1, WEP_AK74, 100, 100);
  CurTick := 2000;
  Kill(1, 1, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('plain selfkill processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    Check('plain selfkill: SelfkillPenalty only', (A^.Selfkills = 2) and (A^.SelfkillsUnderFire = 1) and
      (SavedPoints - A^.Points = 2) and (B^.Points = BobPoints) and (B^.ForcedSelfkills = 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { a hit on the last life is no reason for a selfkill in the next one: Bob hits Alice, the server
    ends her life (as at the end of a survival round), and she kills herself right after the new
    spawn, well within AssistSeconds of that hit }
  EnterCriticalSection(Engine.StateLock);
  try
    SavedPoints := Prof('S1001')^.Points;
    BobPoints := Prof('S1002')^.Points;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Spawn(1, WEP_AK74, 100, 100);
  CurTick := 2010;
  Damage(2, 1, WEP_BARRETT, 30, 100, 100, -40, 0, 100, 100);
  CurTick := 2020;
  Kill(1, 1, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND or EF_SERVER_KILL);
  CurTick := 2030;
  Spawn(1, WEP_AK74, 100, 100);
  CurTick := 2040;
  Kill(1, 1, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('selfkill in the next life processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    Check('a selfkill after a new spawn owes nothing to a hit on the life before',
      (A^.Selfkills = 3) and (A^.SelfkillsUnderFire = 1) and (SavedPoints - A^.Points = 2) and
      (B^.Points = BobPoints) and (B^.ForcedSelfkills = 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- the score guard: what main.pas takes back is not counted ---- }
  DrainActions;
  Check('the score guard settings reach main.pas',
    (LastIntegrity.Kind = ACT_INTEGRITY) and (LastIntegrity.P1 and IG_ENABLED <> 0) and
    (LastIntegrity.P1 and IG_JOINSCORE <> 0) and (LastIntegrity.P1 and IG_DOUBLECAP <> 0) and
    (LastIntegrity.P2 = 1));
  EnterCriticalSection(Engine.StateLock);
  try
    SavedPoints := Prof('S1001')^.Points;
    Kills := Prof('S1001')^.Selfkills;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Spawn(1, WEP_AK74, 100, 100);
  CurTick := 2100;
  Kill(1, 1, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND or EF_SERVER_KILL);
  Check('server kill processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    Check('a kill the server made itself is no selfkill and no death',
      (A^.Selfkills = Kills) and (A^.Points = SavedPoints));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Integrity(1, IGE_DOUBLECAP, 2, 4, 1, '');
  Integrity(0, IGE_RESPAWN, 0, 3, 0, '');
  Check('integrity events processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('the guard counts what it took back',
      (Engine.DB.Server.ScoreFixes = 1) and (Engine.DB.Server.VoidedCaptures = 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Sleep(400);
  ExportText := FileText(Root + PathDelim + 'logs' + PathDelim + 'zitrostats' + PathDelim + 'integrity.log');
  Check('the guard writes its own log', (Pos('capture of', ExportText) > 0) and
    (Pos('put back on their feet', ExportText) > 0));

  { an operation waiting for /yes shows the admin a countdown, /no cancels it }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.AdminConfirmPassword := 'secret';
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Sleep(1100);
  Cmd(3, '/resetserverstats', SRC_COMMAND, 1);
  Check('confirmation asked', WaitProcessed);
  Sleep(1500);
  DrainActions;
  Check('countdown for the admin', Seen('Confirm: /yes <password> or /no'));
  Cmd(3, '/no', SRC_COMMAND, 1);
  Check('cancel processed', WaitProcessed);
  DrainActions;
  Check('/no cancels the operation', Seen('Cancelled.'));

  CurTick := 7200;
  MapBefore(1, 0, 0, 10);
  Check('match end processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    B := Prof('S1002');
    C := Prof('S1003');
    M := Engine.DB.FindMap('ctf_Ash', False);
    Check('match results', (A <> nil) and (A^.Wins = 1) and (C^.Wins = 1) and (B^.Loses = 1) and (A^.AlphaWins = 1));
    Check('ratings updated after the match', (A <> nil) and (A^.Glicko[RF_CTF].Games = 1) and (A^.OpenSkill[RF_CTF].Games = 1));
    Check('map play counted once', (M >= 0) and (Engine.DB.Maps[M].ActiveMapPlays = 1) and (Engine.DB.Maps[M].LoadCount = 1));
    Check('match length counted with its match', (M >= 0) and (Engine.DB.Maps[M].MatchDurationCount = 1) and
      (Engine.DB.Maps[M].MatchDurationSum > 0));
    if A <> nil then
      SavedPoints := A^.Points
    else
      SavedPoints := -1;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  Check('match end announced with the team name', Seen('Match over: Alpha wins 1:0'));
  { the next map starts a new match, but the session of the players goes on }
  CurTick := 7300;
  MapAfter('ctf_Ash', GS_CTF, 10);
  Check('next map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('session counters survive the map change', (Engine.Live[1].SessionKills = 1) and (Engine.Live[1].SessionWins = 1) and
      (Engine.Live[1].SessionCaps = 1));
    Check('match counters start again', (Engine.Live[1].MatchKills = 0) and (Engine.Live[1].MatchCaps = 0) and
      (Engine.Live[1].MatchStartPoints = Prof('S1001')^.Points));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { reloads from the ammunition: a magazine fired empty, a reload with rounds left (they are thrown
    away, not fired), an early refill of the server followed by the late "empty" of the game, a
    weapon change in the middle, the same reload going on afterwards and a death; the Spas-12 loads
    shell by shell }
  CurTick := 7310;
  Spawn(5, WEP_AK74, 100, 100);
  CurTick := 7320; Ammo(5, WEP_AK74, 35, 34, 0);
  CurTick := 7330; Ammo(5, WEP_AK74, 34, 1, 0);
  CurTick := 7340; Ammo(5, WEP_AK74, 1, 0, 0);
  CurTick := 7505; Ammo(5, WEP_AK74, 0, 35, 0);
  CurTick := 7600; Ammo(5, WEP_AK74, 35, 20, 0);
  CurTick := 7610; Ammo(5, WEP_AK74, 20, 0, 1);
  CurTick := 7650; Ammo(5, WEP_AK74, 0, 35, 0);
  CurTick := 7655; Ammo(5, WEP_AK74, 35, 0, 0);
  CurTick := 7700; WeaponChange(5, WEP_SOCOM, WEP_AK74, 14, 0);
  CurTick := 7750; WeaponChange(5, WEP_AK74, WEP_SOCOM, 0, 14);
  CurTick := 7800;
  Kill(2, 5, WEP_BARRETT, WEP_AK74, 1500, 100, 100, 100, 110, 100, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 7900;
  Spawn(6, WEP_SPAS, 100, 100);
  CurTick := 7910; Ammo(6, WEP_SPAS, 7, 5, 0);
  CurTick := 7920; Ammo(6, WEP_SPAS, 5, 6, 0);
  CurTick := 7944; Ammo(6, WEP_SPAS, 6, 7, 0);
  { the flamethrower has no reload to follow, but the 255 of the bullet relay is no shots either }
  CurTick := 7950; Ammo(6, WEP_FLAMER, 255, 190, 0);
  CurTick := 7951; Ammo(6, WEP_FLAMER, 200, 190, 0);
  Cmd(0, '/wep ak up', SRC_CONSOLE, 1);
  Cmd(0, '/serverwep spas', SRC_CONSOLE, 1);
  Cmd(0, '/topweaponsby reloads', SRC_CONSOLE, 1);
  Check('reloads processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1004');
    B := Prof('S1006');
    with A^.Weapons[WEP_AK74] do
    begin
      WriteLn(Format('       AK of up: %d reloads, %d manual, %d dropped, %d done, %d cut, %d deaths, %d timed/%d ticks, ' +
        '%d ends, %d mille, %d at death, %d ticks in all, %d shots',
        [Reloads, ReloadsManual, RoundsDropped, ReloadsDone, ReloadsCut, ReloadDeaths, ReloadTimed, ReloadTicks,
         ReloadEnds, ReloadDoneMille, ReloadDeathMille, ReloadTicksAll, Shots]));
      Check('a magazine fired empty and a reload with rounds left are two reloads, one manual',
        (Reloads = 2) and (ReloadsManual = 1) and (RoundsDropped = 20));
      Check('the rounds a reload throws away are not shots', Shots = 50);
      Check('the finished reload is timed, the late "empty" of the game does not start another',
        (ReloadsDone = 1) and (ReloadTimed = 1) and (ReloadTicks = 165) and (ReloadNormTicks = 165));
      { the reload left for the Socom goes on where it stood when the AK comes back, and the death
        ends it: one reload, one end - not broken off and then killed as well }
      Check('a weapon change only pauses the reload, it goes on where it stood and ends once',
        (ReloadsCut = 0) and (ReloadDeaths = 1) and (ReloadDeathMille = 606));
      Check('how far the reloads got, and the time they took',
        (ReloadEnds = 2) and (ReloadDoneMille = 1606) and (ReloadTicksAll = 265));
      Check('no more reloads end than were started', ReloadsDone + ReloadsCut + ReloadDeaths <= Reloads);
    end;
    with B^.Weapons[WEP_SPAS] do
      Check('the Spas-12 loads shell by shell',
        (Reloads = 1) and (ReloadsManual = 1) and (ReloadsDone = 1) and (ReloadTimed = 1) and (ReloadTicks = 48) and
        (Shots = 2 * ShotMultiplier(WEP_SPAS)) and (RoundsDropped = 0));
    Check('a reading of 255 is no flame shots', (B^.FlamethrowerShots = 10) and (B^.Weapons[WEP_FLAMER].Shots = 10));
    { Bob's Barrett kill of up carries neither EF_LOS nor EF_RAY_CAL: RayCast was not calibrated }
    C := Prof('S1002');
    Check('no Cover (live) before RayCast is calibrated', (C <> nil) and (C^.Kills = 1) and (C^.WallKills = 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  Check('!wep shows the reloads', Seen('Reloads: 2 (1 manual)') and Seen('Killed reloading: 1 (50.0%)') and
    Seen('Rounds thrown away: 20') and Seen('At death: 61% of the reload done'));
  Check('!serverwep and !topweaponsby know the reloads', Seen('Reloads: 1 (1 manual)') and Seen('Top Weapons by Reloads'));

  { a reload left for the other weapon and not taken up again - the AK comes back loaded - was
    broken off, and counts once, with how far it had got; so does one left when the life ends }
  CurTick := 8000;
  Spawn(5, WEP_AK74, 100, 100);
  CurTick := 8010; Ammo(5, WEP_AK74, 35, 0, 1);
  CurTick := 8050; WeaponChange(5, WEP_SOCOM, WEP_AK74, 14, 0);
  CurTick := 8100; WeaponChange(5, WEP_AK74, WEP_SOCOM, 35, 14);
  CurTick := 8110; Ammo(5, WEP_AK74, 35, 0, 1);
  CurTick := 8170; WeaponChange(5, WEP_SOCOM, WEP_AK74, 14, 0);
  CurTick := 8200;
  Kill(2, 5, WEP_BARRETT, WEP_SOCOM, 1500, 100, 100, 100, 110, 100, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND);
  Check('reloads left behind processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    with Prof('S1004')^.Weapons[WEP_AK74] do
    begin
      WriteLn(Format('       AK of up: %d reloads, %d done, %d cut, %d deaths, %d ends, %d mille, %d ticks in all',
        [Reloads, ReloadsDone, ReloadsCut, ReloadDeaths, ReloadEnds, ReloadDoneMille, ReloadTicksAll]));
      Check('a reload that is not taken up again is broken off once, when it is clear',
        (Reloads = 4) and (ReloadsCut = 2) and (ReloadsDone = 1) and (ReloadDeaths = 1) and (ReloadEnds = 4) and
        (ReloadDoneMille = 1606 + 96 + 218) and (ReloadTicksAll = 265 + 16 + 36));
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CheckPacedOutput;
  Engine.Free;

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  { the new engine counts its processed events from 0 }
  Pushed := 0;
  Engine.Start;
  Check('restart', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof('S1001');
    Check('data survives a restart', (A <> nil) and (A^.Kills = 1) and (A^.Wins = 1) and (A^.Points = SavedPoints) and
      (A^.FlagsScore = 1) and (Engine.DB.LiveProfiles = 6));
    M := Engine.DB.FindMap('ctf_Ash', False);
    Check('a restart keeps the match lengths counted by 5.1', (M >= 0) and Engine.DB.Server.MatchLengthsSplit and
      (Engine.DB.Maps[M].MatchDurationBase = 0) and (Engine.DB.Maps[M].MatchDurationCount = 1) and
      (Engine.DB.Maps[M].MatchDurationSum > 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- survival deathmatch as the owner's server plays it: the weapon picks, the rounds of a
    free-for-all and what the server's own kill at the end of a round changes ---- }
  CurTick := 20000;
  MapAfterFlags('dm_Survive', GS_DM, 30, MF_SURVIVAL or MF_REALISTIC or MF_ADVANCE);
  Join(2, 'Bob', 'S1002', 'HWB', '2.2.2.2', TEAM_NONE, 0);
  Join(3, 'Carl', 'S1003', 'HWC', '3.3.3.3', TEAM_NONE, 0);
  Join(4, 'hardkorowy koksu', 'S1005', 'HWE', '5.5.5.5', TEAM_NONE, 0);
  Join(5, 'up', 'S1004', 'HWD', '4.4.4.4', TEAM_NONE, 0);
  Join(6, 'a', 'S1006', 'HWF', '6.6.6.6', TEAM_NONE, 0);
  Check('survival deathmatch processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    { the end of a round and the first kill of the next one fall into one multi-kill window }
    Engine.Cfg.MultiKillWindowSeconds := 20;
    for i := 2 to 6 do
      Snap[i] := PS(i)^;
    PS(6)^.DisplayHUD := True;
    for i := 0 to WSLOT_COUNT - 1 do
      Picks0[i] := Engine.DB.Server.WeaponGlobal[i].Picks;
    { a full HUD line: a feat pushes the oldest plain points entry out, and is dropped only when
      none is left }
    Engine.Extra[3].HudEvents := nil;
    Engine.HudEvent(3, '+20 pts');
    Engine.HudEvent(3, 'FIRST BLOOD!');
    Engine.HudEvent(3, '+21 pts');
    Engine.HudEvent(3, 'Double kill!');
    Engine.HudEvent(3, 'Triple kill!');
    Engine.HudEvent(3, '+19 pts');
    Engine.HudEvent(3, 'RAMPAGE!');
    Engine.HudEvent(3, 'Revenge!');
    Ok := (Length(Engine.Extra[3].HudEvents) = HUD_EVENTS_MAX) and (Engine.Extra[3].HudEvents[0] = 'FIRST BLOOD!') and
      (Engine.Extra[3].HudEvents[1] = 'Double kill!') and (Engine.Extra[3].HudEvents[2] = 'Triple kill!') and
      (Engine.Extra[3].HudEvents[3] = 'RAMPAGE!');
    Engine.Extra[3].HudEvents := nil;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a full HUD line gives its points entries up for the feats', Ok);
  { a note that had its time on the HUD makes way first, a points note before a feat; then a points
    note not shown yet; a feat not shown yet stays }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Extra[3].HudEvents := nil;
    Engine.Extra[3].HudUntil := nil;
    Engine.HudEvent(3, '+20 pts');
    Engine.HudEvent(3, 'FIRST BLOOD!');
    Engine.Extra[3].HudUntil[0] := Engine.GameTick + 1000;
    Engine.Extra[3].HudUntil[1] := Engine.GameTick + 1000;
    Engine.HudEvent(3, '+21 pts');
    Engine.HudEvent(3, 'Double kill!');
    Engine.HudEvent(3, 'Triple kill!');
    Engine.HudEvent(3, 'RAMPAGE!');
    Engine.HudEvent(3, 'Revenge!');
    Engine.HudEvent(3, 'Assist');
    Ok := (Length(Engine.Extra[3].HudUntil) = HUD_EVENTS_MAX) and
      (HudNotes(3) = '|Double kill!|Triple kill!|RAMPAGE!|Revenge!');
    WriteLn('       HUD notes: ', HudNotes(3));
    Engine.Extra[3].HudEvents := nil;
    Engine.Extra[3].HudUntil := nil;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a full HUD line gives up the notes it showed first (points before feats), then points not shown yet', Ok);

  { round 1: Bob spawns with the weapon menu open and takes his weapons with the first change; a
    swap and a gun from the ground are no picks. He wins the round with four kills, and the server
    kills him at its end. }
  CurTick := 20100;
  SpawnWith(2, WEP_NONE, WEP_NONE, 100, 100);
  SpawnWith(3, WEP_MP5, WEP_KNIFE, 300, 100);
  for i := 4 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 20130;
  WeaponChange(2, WEP_AK74, WEP_SOCOM, 35, 12);
  CurTick := 20160;
  WeaponChange(2, WEP_SOCOM, WEP_AK74, 12, 35);
  CurTick := 20190;
  WeaponChange(2, WEP_BARRETT, WEP_SOCOM, 10, 12);
  CurTick := 20200;
  WeaponChange(3, WEP_KNIFE, WEP_MP5, 1, 30);
  for i := 3 to 6 do
  begin
    CurTick := 20400 + (i - 3) * 300;
    Kill(2, i, WEP_BARRETT, WEP_AK74, 100, 100, 100 + 200 * i, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  end;
  Check('round 1 kills processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    SavedPoints := PS(2)^.Points;
    M := Engine.DB.FindMap('dm_Survive', False);
    Ok := M >= 0;
    for i := 0 to WSLOT_COUNT - 1 do
    begin
      case i of
        WEP_AK74, WEP_SOCOM: Kills := 4;
        WEP_MP5, WEP_KNIFE: Kills := 1;
        else Kills := 0;
      end;
      if (Engine.DB.Server.WeaponGlobal[i].Picks - Picks0[i] <> Kills) or
         ((M >= 0) and (Engine.DB.Maps[M].WeaponPicks[i] <> Kills)) then
        Ok := False;
    end;
    Check('weapon picks: from the spawn, or from the first change after a spawn with the menu open; ' +
      'no swap, no gun from the ground', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 21600;
  Kill(2, 2, WEP_BARRETT, WEP_BARRETT, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_SERVER_KILL);
  Check('end of round 1 processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    B := PS(2);
    Check('the server kill at the end of a round: no death, no selfkill, no points, the spree goes on',
      (B^.Deaths = Snap[2].Deaths) and (B^.Selfkills = Snap[2].Selfkills) and (B^.Points = SavedPoints) and
      (B^.Kills = Snap[2].Kills + 4) and (Engine.Live[2].KillStreak = 4) and Engine.Live[2].StreakCarry and
      not Engine.Live[2].Alive);
    Check('round 1: the last one standing won it, as the last man standing and in advance mode',
      (B^.RoundsWins = Snap[2].RoundsWins + 1) and (B^.RoundsLose = Snap[2].RoundsLose) and
      (B^.LastStand = Snap[2].LastStand + 1) and (B^.ClutchesWon = Snap[2].ClutchesWon) and
      (B^.AdvanceRoundsWon = Snap[2].AdvanceRoundsWon + 1) and (B^.AdvanceRoundsPlayed = Snap[2].AdvanceRoundsPlayed + 1));
    Ok := True;
    for i := 3 to 6 do
      if (PS(i)^.RoundsLose <> Snap[i].RoundsLose + 1) or (PS(i)^.RoundsWins <> Snap[i].RoundsWins) or
         (PS(i)^.AdvanceRoundsPlayed <> Snap[i].AdvanceRoundsPlayed + 1) or (PS(i)^.LastStand <> Snap[i].LastStand) then
        Ok := False;
    Check('round 1: every other human who played it lost it', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { round 2: everybody spawns together, and a kill a second later is no spawn kill in survival. It
    is Bob's fifth in a row - the server's kill did not end his spree - but no double kill with his
    last one of round 1. A real death ends the spree. }
  CurTick := 21700;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 21760;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 22000;
  Kill(4, 2, WEP_AK74, WEP_AK74, 500, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 22300;
  Kill(5, 4, WEP_AK74, WEP_AK74, 700, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 22600;
  Kill(6, 5, WEP_AK74, WEP_AK74, 900, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 22700;
  TickEv(0, 0, 600);
  Check('round 2 processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    B := PS(2);
    Check('the spree goes on across the end of the round: 4 + 1 kills are a killing spree',
      (B^.SpreeKills = Snap[2].SpreeKills + 1) and (B^.MaxKillStreak = Max(5, Snap[2].MaxKillStreak)));
    Check('a real death still ends the spree', (Engine.Live[2].KillStreak = 0) and
      (PS(4)^.ShutDownKills = Snap[4].ShutDownKills + 1));
    Check('the streak of 5 across the end of the round is counted at every length up to 5',
      (B^.SpreeLives[1] = Snap[2].SpreeLives[1] + 1) and (B^.SpreeLives[3] = Snap[2].SpreeLives[3] + 1) and
      (B^.SpreeLives[4] = Snap[2].SpreeLives[4] + 1) and (B^.SpreeLives[5] = Snap[2].SpreeLives[5] + 1) and
      (B^.SpreeLives[6] = Snap[2].SpreeLives[6]) and (PS(4)^.SpreeLives[1] = Snap[4].SpreeLives[1] + 1));
    Check('a kill right after the round spawn is no spawn kill in survival',
      (B^.SpawnKills = Snap[2].SpawnKills) and (PS(3)^.SpawnDeaths = Snap[3].SpawnDeaths));
    Check('first blood once per match, the first blood of a round once per round (the first round too)',
      (B^.FirstBloodCount = Snap[2].FirstBloodCount + 1) and
      (B^.RoundFirstBloodCount = Snap[2].RoundFirstBloodCount + 2));
    Check('no double kill across the end of a round',
      (B^.PointmatchMode.Multi.DOUBLE_KILL = Snap[2].PointmatchMode.Multi.DOUBLE_KILL + 1) and
      (B^.PointmatchMode.Multi.TRIPLE_KILL = Snap[2].PointmatchMode.Multi.TRIPLE_KILL + 1) and
      (B^.PointmatchMode.Multi.MULTI_KILL = Snap[2].PointmatchMode.Multi.MULTI_KILL + 1));
    Check('round 2: won by a, lost by everybody else',
      (PS(6)^.RoundsWins = Snap[6].RoundsWins + 1) and (PS(6)^.LastStand = Snap[6].LastStand + 1) and
      (B^.RoundsLose = Snap[2].RoundsLose + 1) and (PS(3)^.RoundsLose = Snap[3].RoundsLose + 2) and
      (PS(4)^.RoundsLose = Snap[4].RoundsLose + 2) and (PS(5)^.RoundsLose = Snap[5].RoundsLose + 2));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the winner of a round is announced and sees it on the HUD', Seen('Round won by Bob') and
    Seen('Round won by a') and Seen('Last man standing!'));
  { the built-in levels of [Sprees]: 3 kills in the chat, 5 in the chat and as a big text for each of
    the five players, and the end of it in the chat }
  Check('a killing spree is said in the chat, once', (SeenCount('Bob is on a KILLING SPREE!') = 1) and
    Seen(Format('%d|0|Bob is on a KILLING SPREE!', [ACT_BROADCAST])));
  Check('a rampage in the chat and in the middle of every player''s screen',
    Seen(Format('%d|0|Bob is on a RAMPAGE!', [ACT_BROADCAST])) and (SeenCount('Bob is on a RAMPAGE!') = 6) and
    Seen(Format('%d|2|Bob is on a RAMPAGE!', [ACT_BIGTEXT])) and Seen(Format('%d|6|Bob is on a RAMPAGE!', [ACT_BIGTEXT])));
  Check('the end of the spree: who ended whose, and how long it was',
    Seen(Format('%d|0|hardkorowy koksu ended the killing spree of Bob (5 kills)', [ACT_BROADCAST])) and
    not Seen('ended the killing spree of hardkorowy koksu'));

  { round 3: the last two kill each other in the same tick - nobody won it }
  CurTick := 23000;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 23100;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 23200;
  Kill(2, 4, WEP_AK74, WEP_AK74, 100, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 23300;
  Kill(5, 6, WEP_AK74, WEP_AK74, 700, 100, 900, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 23400;
  Kill(2, 5, WEP_AK74, WEP_AK74, 100, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Kill(5, 2, WEP_AK74, WEP_AK74, 700, 100, 100, 100, 0, 0, EF_A_ONGROUND);
  CurTick := 23500;
  TickEv(0, 0, 500);
  Check('round 3 processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('round 3: the last two died together, nobody won it',
      (PS(2)^.RoundsWins = Snap[2].RoundsWins + 1) and (PS(2)^.RoundsLose = Snap[2].RoundsLose + 2) and
      (PS(5)^.RoundsWins = Snap[5].RoundsWins) and (PS(5)^.RoundsLose = Snap[5].RoundsLose + 3) and
      (PS(6)^.RoundsWins = Snap[6].RoundsWins + 1) and (PS(6)^.RoundsLose = Snap[6].RoundsLose + 2));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { round 4: with a bot in the game the last human standing has not won yet - whether the bot lives
    is not known - and the server's kill at the end of the round says who stood last }
  CurTick := 23600;
  JoinBot(7, 'Bot', TEAM_NONE);
  CurTick := 23700;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  for i := 3 to 6 do
  begin
    CurTick := 23800 + (i - 3) * 100;
    Kill(2, i, WEP_AK74, WEP_AK74, 100, 100, 100 + 200 * i, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  end;
  CurTick := 24300;
  TickEv(0, 0, 400);
  Check('round 4 kills processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('with a bot in the game the round is not over at the last human', PS(2)^.RoundsWins = Snap[2].RoundsWins + 1);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 24500;
  Kill(2, 2, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_SERVER_KILL);
  Check('end of round 4 processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('round 4: the one the server killed at its end won it',
      (PS(2)^.RoundsWins = Snap[2].RoundsWins + 2) and (PS(3)^.RoundsLose = Snap[3].RoundsLose + 4));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { round 5: the bot outlives every human, and everybody lost the round }
  CurTick := 24600;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 24700;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  for i := 2 to 6 do
    if i <> 3 then
    begin
      CurTick := 24800 + i * 100;
      Kill(7, i, WEP_AK74, WEP_AK74, 1500, 100, 100 + 200 * i, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
    end;
  CurTick := 25500;
  TickEv(0, 0, 300);
  { round 6 is cut short by the map change: no round }
  CurTick := 25600;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 25700;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 25800;
  MapBefore(0, 0, 0, 30);
  MapAfterFlags('ctf_Survive', GS_CTF, 10, MF_SURVIVAL);
  LeaveEv(7);
  Check('rounds 5 and 6 processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('round 5: a bot won, every human lost; round 6: cut short by the map change, no round',
      (PS(2)^.RoundsWins = Snap[2].RoundsWins + 2) and (PS(2)^.RoundsLose = Snap[2].RoundsLose + 3) and
      (PS(3)^.RoundsLose = Snap[3].RoundsLose + 5) and (PS(4)^.RoundsLose = Snap[4].RoundsLose + 5) and
      (PS(5)^.RoundsLose = Snap[5].RoundsLose + 5) and (PS(6)^.RoundsWins = Snap[6].RoundsWins + 1) and
      (PS(6)^.RoundsLose = Snap[6].RoundsLose + 4));
    Engine.Cfg.MultiKillWindowSeconds := 3.5;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { Capture the Flag: after a capture the server kills both teams, slot by slot. That leaves up
    alone against two for a moment, which is no last stand. }
  CurTick := 25900;
  TeamSwitch(3, TEAM_ALPHA);
  TeamSwitch(5, TEAM_ALPHA);
  TeamSwitch(2, TEAM_BRAVO);
  TeamSwitch(4, TEAM_BRAVO);
  TeamSwitch(6, TEAM_BRAVO);
  CurTick := 26000;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 26100;
  Flag(3, FLAG_GRAB);
  CurTick := 26400;
  Flag(3, FLAG_SCORE);
  for i := 2 to 6 do
    Kill(i, i, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_SERVER_KILL);
  Check('capture processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('the server killing both teams after a capture is no last stand', PS(5)^.LastStand = Snap[5].LastStand);
    for i := 2 to 6 do
      Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { Infiltration: a capture ends the round for the capturing team at once, although the server
    kills both teams right after it }
  CurTick := 26500;
  MapAfterFlags('inf_Survive', GS_INF, 10, MF_SURVIVAL);
  CurTick := 26600;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 26800;
  Flag(3, FLAG_SCORE);
  for i := 2 to 6 do
    Kill(i, i, WEP_AK74, WEP_AK74, 100, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_SERVER_KILL);
  CurTick := 27000;
  TickEv(0, 0, 600);
  Check('Infiltration processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Check('Infiltration: the capture won the round', (PS(3)^.RoundsWins = Snap[3].RoundsWins + 1) and
      (PS(5)^.RoundsWins = Snap[5].RoundsWins + 1) and (PS(2)^.RoundsLose = Snap[2].RoundsLose + 1) and
      (PS(4)^.RoundsLose = Snap[4].RoundsLose + 1) and (PS(6)^.RoundsLose = Snap[6].RoundsLose + 1) and
      Seen('Round won by Alpha'));
    for i := 2 to 6 do
      Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { Teammatch with a bot: a team whose humans are dead may still stand on its bot, so its last human
    death does not end the round; the server's kill of the winners at the end says who won }
  CurTick := 27500;
  MapAfterFlags('tm_Survive', GS_TM, 30, MF_SURVIVAL);
  TeamSwitch(2, TEAM_SPEC);
  TeamSwitch(6, TEAM_SPEC);
  JoinBot(7, 'Bot', TEAM_BRAVO);
  CurTick := 27600;
  for i := 3 to 5 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 27700;
  TickEv(0, 0, 900);
  CurTick := 27800;
  Kill(3, 4, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 27900;
  TickEv(0, 0, 800);
  Check('Teammatch processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('Teammatch: no round while the other team may stand on a bot', (PS(3)^.RoundsWins = Snap[3].RoundsWins) and
      (PS(4)^.RoundsLose = Snap[4].RoundsLose));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 28200;
  Kill(3, 3, WEP_AK74, WEP_AK74, 300, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_SERVER_KILL);
  Kill(5, 5, WEP_AK74, WEP_AK74, 700, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_SERVER_KILL);
  CurTick := 28300;
  TickEv(0, 0, 700);
  Check('end of the Teammatch round processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('Teammatch: the server killing the winners at the end of the round gives them the round',
      (PS(3)^.RoundsWins = Snap[3].RoundsWins + 1) and (PS(5)^.RoundsWins = Snap[5].RoundsWins + 1) and
      (PS(4)^.RoundsLose = Snap[4].RoundsLose + 1) and (PS(2)^.RoundsLose = Snap[2].RoundsLose) and
      (PS(6)^.RoundsLose = Snap[6].RoundsLose));
    M := Engine.Match.MapIndex;
    VoteStarts0 := Engine.DB.Maps[M].VoteStarts;
    VotesWon0 := Engine.DB.Maps[M].VotesPassed;
    { with the map vote of ZitroStats off ([MapVote] Enabled = 0) the votes of Soldat and of other
      scripts are only counted (test_mapvote tests the map vote itself) }
    Engine.Cfg.MapVoteEnabled := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { a map vote another script started (Game.StartVoteMap) is seen only through the votes cast
    for it: the first one counts the vote, the others do not, and the change to that map wins it }
  VoteEv := NewEvent(zeVote);
  VoteEv.Slot := 2;
  VoteEv.I[0] := 3;
  VoteEv.S1 := 'ctf_voted_away';
  Push(VoteEv);
  VoteEv.Slot := 4;
  Push(VoteEv);
  VoteEv := NewEvent(zeMapBefore);
  VoteEv.I[4] := 300;
  VoteEv.S1 := 'ctf_voted_away';
  Push(VoteEv);
  Check('votes and the map change processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('a map vote of another script counts once, from its first vote cast, and the change to it wins it',
      (Engine.DB.Maps[M].VoteStarts = VoteStarts0 + 1) and (Engine.DB.Maps[M].VotesPassed = VotesWon0 + 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- Capture the Flag: a savior kill that saved the flag carrier is a flag defense, whoever else
    the victim had hit; a capture or a kill that pays nothing puts no "+0 pts" on the HUD ---- }
  CurTick := 29000;
  MapAfter('ctf_Guard', GS_CTF, 10);
  TeamSwitch(2, TEAM_ALPHA);
  TeamSwitch(6, TEAM_BRAVO);
  CurTick := 29010;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  Check('guard map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 2 to 6 do
      Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { up carries the flag, Carl (before him in the slots) does not; hardkorowy koksu hits both of
    them, and Bob kills him a moment later }
  CurTick := 29100;
  Flag(5, FLAG_GRAB);
  Sample(5, EF_A_ALIVE or EF_A_FLAGGER or EF_A_ONGROUND, 1100, 100);
  CurTick := 29110;
  Damage(4, 3, WEP_AK74, 20, 700, 100, -40, 0, 700, 100);
  Damage(4, 5, WEP_AK74, 20, 1100, 100, 40, 0, 1100, 100);
  CurTick := 29140;
  Kill(2, 4, WEP_AK74, WEP_AK74, 500, 100, 900, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('savior kill processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('a savior kill that saved the flag carrier is a flag defense, also when another teammate was hit too',
      (PS(2)^.SaviorKills = Snap[2].SaviorKills + 1) and (PS(2)^.SaviorFlaggerKills = Snap[2].SaviorFlaggerKills + 1));
    { a capture nobody pays for: no enemy pays into the pool, and no fallback points }
    Engine.Cfg.CapPoolPoints := 0;
    Engine.Cfg.FlagScoreFallbackPoints := 0;
    Engine.Extra[5].HudEvents := nil;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 29200;
  Flag(5, FLAG_SCORE);
  Check('capture without points processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    WriteLn('       HUD of the capper: ', HudNotes(5));
    Check('a capture that pays nothing is counted, with no "+0 pts capture" on the HUD',
      (PS(5)^.FlagsScore = Snap[5].FlagsScore + 1) and (Pos('+0 pts', HudNotes(5)) = 0));
    Engine.Cfg.CapPoolPoints := 13;
    Engine.Cfg.FlagScoreFallbackPoints := 25;
    { a kill that pays nothing: a victim who stood still for InactiveVictimSeconds, worth 0% }
    SetLength(Engine.Cfg.InactiveVictimMultipliers, 1);
    Engine.Cfg.InactiveVictimMultipliers[0] := 0;
    Engine.Extra[2].HudEvents := nil;
    SavedPoints := PS(2)^.Points;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 30300;
  Kill(2, 6, WEP_AK74, WEP_AK74, 500, 100, 1300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('kill without points processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    WriteLn('       HUD of the killer: ', HudNotes(2));
    Check('a kill that pays nothing is counted, with no "+0 pts" on the HUD',
      (PS(2)^.Kills = Snap[2].Kills + 2) and (PS(2)^.Points = SavedPoints) and (Pos('+0 pts', HudNotes(2)) = 0));
    SetLength(Engine.Cfg.InactiveVictimMultipliers, 4);
    Engine.Cfg.InactiveVictimMultipliers[0] := 100;
    Engine.Cfg.InactiveVictimMultipliers[1] := 50;
    Engine.Cfg.InactiveVictimMultipliers[2] := 25;
    Engine.Cfg.InactiveVictimMultipliers[3] := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- Hold the Flag: a point goes to the human who carried the flag when it was scored, also when
    he died a moment later, before the score was looked at again ---- }
  CurTick := 31000;
  MapAfter('htf_Hold', GS_HTF, 30);
  CurTick := 31010;
  for i := 2 to 6 do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 31060;
  TickEv(0, 0, 600);
  Check('htf map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 2 to 6 do
      Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 31100;
  Flag(5, FLAG_GRAB);
  Sample(5, EF_A_ALIVE or EF_A_FLAGGER or EF_A_ONGROUND, 1100, 100);
  CurTick := 31120;
  TickEv(1, 0, 590);
  { up dies with the flag after Alpha's next point, and an enemy picks it up, all before the score
    is looked at again }
  CurTick := 31150;
  Kill(4, 5, WEP_AK74, WEP_AK74, 900, 100, 1100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND or EF_B_FLAGGER);
  Flag(5, FLAG_DROP);
  CurTick := 31170;
  Flag(4, FLAG_GRAB);
  Sample(4, EF_A_ALIVE or EF_A_FLAGGER or EF_A_ONGROUND, 900, 100);
  CurTick := 31180;
  TickEv(2, 0, 580);
  Check('htf points processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    WriteLn(Format('       HTF points of up: %d, team points of Carl: %d',
      [PS(5)^.HTFMode.PointsScored - Snap[5].HTFMode.PointsScored,
       PS(3)^.HTFMode.TeamPointsScored - Snap[3].HTFMode.TeamPointsScored]));
    Check('both HTF points go to the carrier, the second although he died before the score was read',
      (PS(5)^.HTFMode.PointsScored = Snap[5].HTFMode.PointsScored + 2) and
      (PS(3)^.HTFMode.PointsScored = Snap[3].HTFMode.PointsScored) and
      (PS(4)^.HTFMode.PointsScored = Snap[4].HTFMode.PointsScored) and
      (PS(3)^.HTFMode.TeamPointsScored = Snap[3].HTFMode.TeamPointsScored + 2));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- leavers: the stays of an account in one match add up. Alpha wins a 200 s match (Need 80 s,
    a leaver loss from 100 s on the team). hardkorowy koksu plays 20 s, comes back and plays 110 s
    more; a plays 60 s twice; up plays 120 s, leaves, and is back for the last 10 s. ---- }
  CurTick := 32000;
  MapAfter('ctf_Leave', GS_CTF, 10);
  TeamSwitch(5, TEAM_BRAVO);
  Check('leaver map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 2 to 6 do
      Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 33200;
  LeaveEv(4);
  CurTick := 34400;
  Join(4, 'hardkorowy koksu', 'S1005', 'HWE', '5.5.5.5', TEAM_BRAVO, 0);
  CurTick := 35600;
  LeaveEv(6);
  CurTick := 36200;
  Join(6, 'a', 'S1006', 'HWF', '6.6.6.6', TEAM_BRAVO, 0);
  CurTick := 39200;
  LeaveEv(5);
  CurTick := 39800;
  LeaveEv(6);
  CurTick := 41000;
  LeaveEv(4);
  CurTick := 43400;
  Join(5, 'up', 'S1004', 'HWD', '4.4.4.4', TEAM_BRAVO, 0);
  CurTick := 44000;
  MapBefore(3, 1, 0, 10);
  Check('leaver match processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('stays add up: 20 s + 110 s on the losing team is a leaver loss (a first short stay does not hide it)',
      (PS(4)^.Loses = Snap[4].Loses + 1) and (PS(4)^.LeaveLosses = Snap[4].LeaveLosses + 1) and
      (PS(4)^.BravoLoses = Snap[4].BravoLoses + 1));
    Check('stays add up: 60 s + 60 s on the losing team is a leaver loss',
      (PS(6)^.Loses = Snap[6].Loses + 1) and (PS(6)^.LeaveLosses = Snap[6].LeaveLosses + 1));
    Check('a player back for the end has the result of all his stays: a loss and a rated match, no leaver loss',
      (PS(5)^.Loses = Snap[5].Loses + 1) and (PS(5)^.LeaveLosses = Snap[5].LeaveLosses) and
      (PS(5)^.Mmr[RF_CTF].Games = Snap[5].Mmr[RF_CTF].Games + 1));
    Check('the winners win', (PS(2)^.Wins = Snap[2].Wins + 1) and (PS(3)^.Wins = Snap[3].Wins + 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- [Sprees]: levels of its own, each with its place for the message; the end of a spree goes a
    line below a level, on a layer of its own; with Enabled = 0 nothing is said and the streaks
    still count ---- }
  CurTick := 44100;
  MapAfter('dm_Sprees', GS_DM, 30);
  Check('spree map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    SavedCfg := Engine.Cfg;
    Engine.Cfg.SpreeLevels[0].Kills := 1;
    Engine.Cfg.SpreeLevels[0].Name := 'Opener';
    Engine.Cfg.SpreeLevels[0].Style := SPREE_BIGTEXT;
    Engine.Cfg.SpreeLevels[0].Text := '%s opens (%d)';
    Engine.Cfg.SpreeLevels[1].Kills := 2;
    Engine.Cfg.SpreeLevels[1].Name := 'Quiet';
    Engine.Cfg.SpreeLevels[1].Style := SPREE_OFF;
    Engine.Cfg.SpreeLevels[1].Text := '%s is quiet';
    Engine.Cfg.SpreeLevels[2].Kills := 3;
    Engine.Cfg.SpreeLevels[2].Name := 'Loud';
    Engine.Cfg.SpreeLevels[2].Style := SPREE_CHAT;
    Engine.Cfg.SpreeLevels[2].Text := '%s is loud, 100% sure';
    Engine.Cfg.SpreeLevelCount := 3;
    Engine.Cfg.SpreeShutStyle := SPREE_BIGTEXT;
    Engine.Cfg.SpreeShutText := '%s stopped %s at %d';
    for i := 2 to 6 do
      if PS(i) <> nil then
        Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  CurTick := 44200;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(3, WEP_AK74, WEP_SOCOM, 300, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 44300;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 44400;
  Kill(2, 5, WEP_AK74, WEP_AK74, 100, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 44500;
  SpawnWith(3, WEP_AK74, WEP_SOCOM, 300, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 44600;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 44700;
  Kill(5, 2, WEP_AK74, WEP_AK74, 500, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('spree kills processed', WaitProcessed);
  Opens := 0;
  Stops := 0;
  OpenAct := NewAction(ACT_NONE, 0, 0, '');
  StopAct := OpenAct;
  while Engine.PopAction(Act) do
  begin
    if (Act.Kind = ACT_BIGTEXT) and (Act.Text = 'Bob opens (1)') then
    begin
      OpenAct := Act;
      Inc(Opens);
    end;
    if (Act.Kind = ACT_BIGTEXT) and (Act.Text = 'up stopped Bob at 3') then
    begin
      StopAct := Act;
      Inc(Stops);
    end;
    Console.Add(Format('%d|%d|%s', [Act.Kind, Act.Slot, Act.Text]));
  end;
  Check('a level as a big text only: one for each of the three players, nothing in the chat',
    (Opens = 3) and not Seen(Format('%d|0|Bob opens', [ACT_BROADCAST])));
  Check('a level that is off says nothing', not Seen('is quiet'));
  Check('a level in the chat only, with the % it holds', Seen(Format('%d|0|Bob is loud, 100%% sure', [ACT_BROADCAST])) and
    (SeenCount('Bob is loud') = 1));
  EnterCriticalSection(Engine.StateLock);
  try
    W := Round(Length('Bob opens (1)') * Engine.Cfg.SpreeBigScale * 140);
    Check('the big text: the layer after the HUD''s, centred on the screen, its size, time and colour',
      (OpenAct.P1 = Engine.Cfg.HudLayer + 2) and (OpenAct.P2 = Max(0, Min(427 - W div 2, 640 - W))) and
      (OpenAct.P3 = Engine.Cfg.SpreeBigY) and SameValue(OpenAct.F1, Engine.Cfg.SpreeBigScale) and
      (Round(OpenAct.F2) = Int64(Engine.Cfg.SpreeBigSeconds) * TICKS_PER_SECOND) and (OpenAct.Color = Engine.Cfg.SpreeColor));
    Check('the end of a spree a line below it, on the next layer, and the killer''s own level as well',
      (Stops = 3) and (StopAct.P1 = OpenAct.P1 + 1) and (StopAct.P3 = OpenAct.P3 + Round(Engine.Cfg.SpreeBigScale * 220)) and
      Seen(Format('%d|5|up opens (1)', [ACT_BIGTEXT])));
    Check('the streaks of the levels of its own are counted by their length',
      (PS(2)^.SpreeLives[1] = Snap[2].SpreeLives[1] + 1) and (PS(2)^.SpreeLives[3] = Snap[2].SpreeLives[3] + 1) and
      (PS(2)^.SpreeLives[4] = Snap[2].SpreeLives[4]) and (PS(5)^.SpreeLives[1] = Snap[5].SpreeLives[1] + 1));
    Engine.Cfg.SpreesEnabled := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 44800;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  Kill(3, 5, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 44900;
  Kill(3, 2, WEP_AK74, WEP_AK74, 300, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('kills without spree messages processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Check('Enabled = 0: no level and no end of a spree is said, the streaks still count',
      not Seen('Carl opens') and not Seen('Carl stopped') and (PS(3)^.SpreeLives[1] = Snap[3].SpreeLives[1] + 1) and
      (PS(3)^.SpreeLives[2] = Snap[3].SpreeLives[2] + 1));
    Engine.Cfg := SavedCfg;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- /zs_setpass: the new password counts once the service thread made its hash, and the admin
    hears so then - before that it is "being set" ---- }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.AdminConfirmPassword := 'secret';
    Engine.Cfg.SteamAuthWaitSeconds := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 45000;
  Join(9, 'Keyholder', '', 'HWK', '9.9.9.9', TEAM_SPEC, 0);
  Check('join without Steam processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    i := Engine.Identity.ProfileIndex(9);
    if Engine.DB.Valid(i) then
      M := Engine.DB.Profiles[i]^.ID
    else
      M := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  Console.Clear;
  Cmd(0, Format('/zs_setpass #%d n3wpass77', [M]), SRC_CONSOLE, 1);
  i := 0;
  repeat
    Cmd(0, '/yes secret', SRC_CONSOLE, 1);
    Done := WaitProcessed;
    DrainActions;
    Inc(i);
    if Seen('A save is in progress') and not Seen('is being set') then
      Sleep(500);
  until Seen('is being set') or not Seen('A save is in progress') or (i >= 10);
  Ok := Done and Seen(Format('password of #%d Keyholder is being set', [M]));
  T0 := MonoMs;
  while not Seen(Format('password of #%d Keyholder was changed', [M])) and (MonoMs - T0 < 10000) do
  begin
    Sleep(50);
    DrainActions;
  end;
  Check('/zs_setpass says the password is being set, and that it was changed once it was', Ok and (M > 0) and
    Seen(Format('password of #%d Keyholder was changed', [M])));
  EnterCriticalSection(Engine.StateLock);
  try
    i := Engine.DB.IndexOfId(M);
    Check('the password is stored', Engine.DB.Valid(i) and (Engine.DB.Profiles[i]^.PassHash <> ''));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  for i := 0 to Console.Count - 1 do
    if Pos('|0|', Console[i]) > 0 then
      WriteLn('       console: ', Copy(Console[i], Pos('|0|', Console[i]) + 3, 150));

  { ---- the HUD: a note stays [HUD] EventSeconds on the line (2: two refreshes, drawn once a
    second), with 1 one refresh ---- }
  CurTick := 46000;
  LeaveEv(7);
  MapAfter('dm_Hud', GS_DM, 30);
  CurTick := 46010;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(3, WEP_AK74, WEP_SOCOM, 300, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  { a refresh with the HUD off drops the notes the kills above left (no refresh since) }
  CurTick := 46060;
  TickEv(0, 0, 601);
  Check('hud map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 2 to 5 do
      if PS(i) <> nil then
        PS(i)^.DisplayHUD := True;
    Engine.Cfg.HudEventSeconds := 2;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  Console.Clear;
  CurTick := 46100;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 46120;
  TickEv(0, 0, 600);
  Done := WaitProcessed;
  DrainActions;
  ExportText := HudLineWith(2, '');
  WriteLn('       HUD line: ', ExportText);
  Check('the HUD line shows the notes of a kill at the next refresh', Done and (Pos('FIRST BLOOD!', ExportText) > 0) and
    (Pos(' pts', ExportText) > 0));
  Console.Clear;
  CurTick := 46180;
  TickEv(0, 0, 599);
  Done := WaitProcessed;
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Pos('FIRST BLOOD!', Engine.Extra[2].HudText) > 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('EventSeconds = 2: the notes stay on the line a second later (the same line, nothing sent again)',
    Done and Ok and (HudLineWith(2, '') = ''));
  Console.Clear;
  CurTick := 46240;
  TickEv(0, 0, 598);
  Done := WaitProcessed;
  DrainActions;
  ExportText := HudLineWith(2, '');
  Check('... and are gone after two seconds', Done and (ExportText <> '') and (Pos('FIRST BLOOD!', ExportText) = 0) and
    (Pos(' pts', ExportText) = 0));
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.HudEventSeconds := 1;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Console.Clear;
  CurTick := 46300;
  Kill(2, 5, WEP_AK74, WEP_AK74, 100, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 46360;
  TickEv(0, 0, 597);
  Done := WaitProcessed;
  DrainActions;
  ExportText := HudLineWith(2, '');
  Check('EventSeconds = 1: the notes of the next kill, and no first blood again in the same match',
    Done and (Pos(' pts', ExportText) > 0) and (Pos('FIRST BLOOD', ExportText) = 0));
  Console.Clear;
  CurTick := 46420;
  TickEv(0, 0, 596);
  Done := WaitProcessed;
  DrainActions;
  ExportText := HudLineWith(2, '');
  Check('... gone a second later', Done and (ExportText <> '') and (Pos(' pts', ExportText) = 0));
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.HudEventSeconds := 2;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- survival deathmatch: FIRST BLOOD! once a match; the first kill of every round counts as a
    round first blood of its own (the first round too), and the HUD says ROUND FIRST BLOOD for the
    rounds after the first; the last man standing needs [Mechanics] LastStandMinPlayers (3)
    players in the round ---- }
  CurTick := 47000;
  MapAfterFlags('dm_Rounds', GS_DM, 30, MF_SURVIVAL);
  Check('rounds map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 2 to 5 do
      if PS(i) <> nil then
        Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  Console.Clear;
  { round 1 of three players: Bob draws the first blood of the match, up stands last }
  CurTick := 47010;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(3, WEP_AK74, WEP_SOCOM, 300, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 47100;
  Kill(2, 3, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 47120;
  TickEv(0, 0, 600);
  CurTick := 47200;
  Kill(5, 2, WEP_AK74, WEP_AK74, 500, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 47260;
  TickEv(0, 0, 599);
  { round 2 of three players: Carl's first kill is the round's, and he stands last }
  CurTick := 47500;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(3, WEP_AK74, WEP_SOCOM, 300, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 47600;
  Kill(3, 5, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 47620;
  TickEv(0, 0, 590);
  CurTick := 47700;
  Kill(3, 2, WEP_AK74, WEP_AK74, 300, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 47760;
  TickEv(0, 0, 589);
  Check('rounds 1 and 2 of the first bloods processed', WaitProcessed);
  DrainActions;
  Check('round 1: FIRST BLOOD! for the first kill of the match, and no ROUND FIRST BLOOD on top',
    (HudLineWith(2, 'FIRST BLOOD!') <> '') and (HudLineWith(2, 'ROUND FIRST BLOOD') = ''));
  Check('round 2: ROUND FIRST BLOOD for the first kill of the round, no FIRST BLOOD! again',
    (HudLineWith(3, 'ROUND FIRST BLOOD') <> '') and (HudLineWith(3, 'FIRST BLOOD!') = ''));
  Check('the last man standing of three players, on the HUD', (HudLineWith(5, 'Last man standing!') <> '') and
    (HudLineWith(3, 'Last man standing!') <> ''));
  { round 3, one against one: Carl watches }
  Console.Clear;
  CurTick := 47800;
  TeamSwitch(3, TEAM_SPEC);
  CurTick := 48000;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 48100;
  Kill(2, 5, WEP_AK74, WEP_AK74, 100, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 48160;
  TickEv(0, 0, 580);
  Check('round 3 of the first bloods processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    A := PS(2);
    B := PS(3);
    C := PS(5);
    Check('Bob: the first blood of the match once, the first bloods of rounds 1 and 3, round 3 won, no last stand',
      (A^.FirstBloodCount = Snap[2].FirstBloodCount + 1) and
      (A^.RoundFirstBloodCount = Snap[2].RoundFirstBloodCount + 2) and
      (A^.RoundsWins = Snap[2].RoundsWins + 1) and (A^.LastStand = Snap[2].LastStand));
    Check('Carl: the first blood of round 2 only, the last man standing of it',
      (B^.FirstBloodCount = Snap[3].FirstBloodCount) and
      (B^.RoundFirstBloodCount = Snap[3].RoundFirstBloodCount + 1) and
      (B^.RoundsWins = Snap[3].RoundsWins + 1) and (B^.LastStand = Snap[3].LastStand + 1));
    Check('up: the last man standing of round 1, no first blood',
      (C^.FirstBloodCount = Snap[5].FirstBloodCount) and (C^.RoundFirstBloodCount = Snap[5].RoundFirstBloodCount) and
      (C^.RoundsWins = Snap[5].RoundsWins + 1) and (C^.LastStand = Snap[5].LastStand + 1) and
      (C^.RoundsLose = Snap[5].RoundsLose + 2));
    Engine.Cfg.LastStandMinPlayers := 2;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('round 3: one against one is a round won, no last man standing',
    (HudLineWith(2, 'ROUND FIRST BLOOD') <> '') and (SeenCount('Last man standing!') = 0) and Seen('Round won by Bob'));
  { round 4, one against one with LastStandMinPlayers = 2 }
  CurTick := 48400;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 48500;
  Kill(5, 2, WEP_AK74, WEP_AK74, 500, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  CurTick := 48560;
  TickEv(0, 0, 570);
  { the next match: the first blood of the match again }
  CurTick := 48600;
  MapAfterFlags('dm_Rounds', GS_DM, 30, MF_SURVIVAL);
  TeamSwitch(3, TEAM_NONE);
  CurTick := 48700;
  SpawnWith(2, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(3, WEP_AK74, WEP_SOCOM, 300, 100);
  SpawnWith(5, WEP_AK74, WEP_SOCOM, 500, 100);
  CurTick := 48800;
  Kill(5, 3, WEP_AK74, WEP_AK74, 500, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('round 4 and the next match processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    C := PS(5);
    Check('LastStandMinPlayers = 2: one against one is a last stand',
      (C^.LastStand = Snap[5].LastStand + 2) and (C^.RoundsWins = Snap[5].RoundsWins + 2));
    { up drew the first blood of round 4 and then the first kill of the next match }
    Check('a new match: its first kill is the first blood of the match and of its first round',
      (C^.FirstBloodCount = Snap[5].FirstBloodCount + 1) and
      (C^.RoundFirstBloodCount = Snap[5].RoundFirstBloodCount + 2));
    Engine.Cfg.LastStandMinPlayers := 3;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- team survival: a last stand needs LastStandMinPlayers humans on the teams in the round ---- }
  CurTick := 49000;
  Join(6, 'a', 'S1006', 'HWF', '6.6.6.6', TEAM_BRAVO, 0);
  MapAfterFlags('tm_Stand', GS_TM, 30, MF_SURVIVAL);
  TeamSwitch(2, TEAM_ALPHA);
  TeamSwitch(3, TEAM_ALPHA);
  TeamSwitch(5, TEAM_BRAVO);
  CurTick := 49100;
  for i := 2 to 6 do
    if i <> 4 then
      SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  Check('team survival map processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 2 to 6 do
      if PS(i) <> nil then
        Snap[i] := PS(i)^;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 49200;
  Kill(2, 5, WEP_AK74, WEP_AK74, 300, 100, 1100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('two against two processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('two against two: the one left alone against two has a last stand (4 players)',
      PS(6)^.LastStand = Snap[6].LastStand + 1);
    Engine.Cfg.LastStandMinPlayers := 5;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 49400;
  MapAfterFlags('tm_Stand2', GS_TM, 30, MF_SURVIVAL);
  CurTick := 49500;
  for i := 2 to 6 do
    if i <> 4 then
      SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
  CurTick := 49600;
  Kill(2, 5, WEP_AK74, WEP_AK74, 300, 100, 1100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND);
  Check('two against two again processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('LastStandMinPlayers = 5: two against two gives no last stand',
      (PS(6)^.LastStand = Snap[6].LastStand + 1) and (PS(2)^.Kills = Snap[2].Kills + 2));
    Engine.Cfg.LastStandMinPlayers := 3;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Engine.Free;

  { A database that cannot be read is replaced by the newest backup. The damaged files are renamed
    once, the journals with them, and nothing else of the folder: not the lock file of the server,
    not another file whose name starts the same. }
  ExportText := Root + PathDelim + 'nickreg' + PathDelim;
  WriteFileText(ExportText + 'zitrostats.zsdb', 'damaged');
  WriteFileText(ExportText + 'zitrostats.zsdb.prev', 'damaged');
  WriteFileText(ExportText + 'zitrostats.zsdb.tmp', 'damaged');
  WriteFileText(ExportText + 'zitrostats.readme', 'not a journal');
  Kills := CountFiles(ExportText + 'zitrostats.*.journal');
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Pushed := 0;
  Engine.Start;
  Check('a damaged database is replaced by the newest backup', WaitReady and not Engine.IsReadOnly);
  Check('the damaged files are renamed once', (CountFiles(ExportText + 'zitrostats.zsdb.damaged-*') = 1) and
    (CountFiles(ExportText + 'zitrostats.zsdb.prev.damaged-*') = 1) and
    (CountFiles(ExportText + '*.damaged-*.damaged-*') = 0));
  { Windows cannot rename a file to a path of 260 characters or more: in a folder that deep (a
    copy of the project far down in the temp folder) the renamed journals would be too long,
    which says nothing about the engine }
  Ok := True;
  {$IFDEF WINDOWS}
  Ok := Length(ExpandFileName(ExportText + 'zitrostats.00000000.journal.damaged-yyyymmdd-hhnnss')) < 260;
  if not Ok then
    WriteLn('       the folder is too deep for the renamed journal names: their renaming is not checked');
  {$ENDIF}
  Check('the journals with them, not the lock file or another file', (Kills > 0) and
    ((CountFiles(ExportText + 'zitrostats.*.journal.damaged-*') = Kills) or not Ok) and
    FileExists(ExportText + 'zitrostats.lock') and FileExists(ExportText + 'zitrostats.readme'));
  DrainActions;
  Engine.Free;
  Console.Free;

  Check('every metric name belongs to one metric only: ' + DuplicateAlias, DuplicateAlias = '');

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
