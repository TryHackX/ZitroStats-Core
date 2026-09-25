program test_teambalance;

{ The team balance inside the engine: joins placed from the game thread, corrections carried out on
  death, locks, volunteers, admin commands, four teams, the start of a map and survival, swaps that
  are finished once started, and protections that give way to uneven numbers. main.pas is played by
  the test: every ACT_MOVE is answered with the team event and ZS_Ev_Move_Result. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_weapons, zs_engine, zs_commands, zs_balance;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console: TStringList;
  Moves: array of TZSAction;
  Root: AnsiString;
  NextAccount: LongInt = 100;

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

procedure WriteSettings(const Extra: AnsiString);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('[Ranking]');
    L.Add('MinHumansForStats = 2');
    L.Add('[Balance]');
    L.Add('Enabled = 1');
    L.Add('MinPlayers = 4');
    L.Add('SustainSeconds = 5');
    L.Add('CheckSeconds = 1');
    L.Add('CooldownSeconds = 0');
    L.Add('LeaveGraceSeconds = 3');
    L.Add('PendingMaxSeconds = 10');
    L.Add('JoinReviewSeconds = 10');
    L.Add('UncertaintyGames = 0');
    L.Add('Volunteers = 0');
    L.Add('MapStart = keep');
    L.Add('MapStartSeconds = 1');
    L.Add('ProtectTop = 1');
    L.Text := L.Text + Extra;
    L.SaveToFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini');
  finally
    L.Free;
  end;
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
  Sleep(120);
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

{ output lines go to Console, team moves to Moves }
procedure Drain;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
  begin
    if A.Kind = ACT_MOVE then
    begin
      SetLength(Moves, Length(Moves) + 1);
      Moves[High(Moves)] := A;
    end;
    Console.Add(Format('%d|%d|%s', [A.Kind, A.Slot, A.Text]));
  end;
end;

function Seen(const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to Console.Count - 1 do
    if Pos(Part, Console[k]) > 0 then
      Exit(True);
end;

function MoveFor(Slot: LongInt; out A: TZSAction): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := High(Moves) downto 0 do
    if Moves[k].Slot = Slot then
    begin
      A := Moves[k];
      Exit(True);
    end;
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

procedure MapBefore(const Next: AnsiString; A, B, TimeLeft: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapBefore);
  Ev.S1 := Next;
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Ev.I[5] := 10;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := 'HW' + Steam;
  Ev.S4 := '10.0.0.' + IntToStr(Slot);
  Ev.I[0] := Team;
  Ev.I[1] := 1;
  Push(Ev);
end;

procedure Leave(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(Ev);
end;

procedure TeamEv(Slot, Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTeam);
  Ev.Slot := Slot;
  Ev.I[0] := Team;
  Push(Ev);
end;

procedure Spawn(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSpawn);
  Ev.Slot := Slot;
  Ev.I[0] := WEP_AK74;
  Ev.I[1] := WEP_SOCOM;
  Ev.F[0] := 100 * Slot;
  Ev.F[1] := 100;
  Push(Ev);
end;

procedure Kill(K, V: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := EF_A_ALIVE or EF_A_ONGROUND or EF_LOS;
  Ev.I[3] := WEP_AK74;
  Ev.F[0] := 100 * K;
  Ev.F[1] := 100;
  Ev.F[2] := 100 * V;
  Ev.F[3] := 100;
  Push(Ev);
end;

procedure Tick(Count, TimeLeft: LongInt);
var
  Ev: TZSEvent;
  k: LongInt;
begin
  for k := 1 to Count do
  begin
    Inc(CurTick, TICKS_PER_SECOND);
    Ev := NewEvent(zeTick);
    Ev.I[4] := TimeLeft;
    Ev.I[6] := GS_CTF;
    Push(Ev);
  end;
end;

procedure VoteEv(Slot: LongInt; const Map: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeVote);
  Ev.Slot := Slot;
  Ev.I[0] := 1;
  Ev.S1 := Map;
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

{ what main.pas does with an ACT_MOVE }
procedure Answer(Slot, Team, MoveResult: LongInt);
var
  Ev: TZSEvent;
begin
  if MoveResult = MOVE_DONE then
    TeamEv(Slot, Team);
  Ev := NewEvent(zeMoveResult);
  Ev.Slot := Slot;
  Ev.I[0] := Team;
  Ev.I[1] := MoveResult;
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
procedure Sample(Slot, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSample);
  Ev.Slot := Slot;
  Ev.I[0] := Flags;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := 30;
  Ev.F[0] := 100 * Slot;
  Ev.F[1] := 100;
  Push(Ev);
end;

function MoveCount(Slot: LongInt): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to High(Moves) do
    if Moves[k].Slot = Slot then
      Inc(Result);
end;

{ the last decisions of the balance (teambalance.log), kept by the engine }
function Noted(const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 0 to High(Engine.Bal.Log) do
      if Pos(Part, Engine.Bal.Log[k]) > 0 then
        Result := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure ClearNotes;
var
  k: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 0 to High(Engine.Bal.Log) do
      Engine.Bal.Log[k] := '';
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function TeamSize(Team: LongInt): LongInt;
var
  S: LongInt;
begin
  Result := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    for S := 1 to MAX_PLAYERS do
      if Engine.Live[S].Active and (Engine.Live[S].Team = Team) then
        Inc(Result);
  finally
    LeaveCriticalSection(Engine.StateLock);
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

procedure SetMmr(const Steam: AnsiString; R: Double);
var
  P: PPlayerProfile;
  F: LongInt;
begin
  P := Prof(Steam);
  if P = nil then
    Exit;
  for F := 0 to RF_COUNT - 1 do
  begin
    P^.Mmr[F].R := R;
    P^.Mmr[F].Games := 20;
  end;
  P^.LastPlayedTime := Now;
end;

{ a new map with four new players First..First+3 in Teams, rated Mmr; the four players from Before
  on leave first (0 = nobody). Every line-up gets new accounts, so a slot used again is a stranger.
  Flags are those of the map (MF_SURVIVAL). }
procedure LineUp(const Map: AnsiString; First, Before: LongInt; const Teams: array of LongInt;
  const Mmr: array of Double; Flags: LongInt = 0);
var
  i: LongInt;
begin
  if Before > 0 then
    for i := Before to Before + 3 do
      Leave(i);
  MapAfter(Map, GS_CTF, 10, Flags);
  for i := 0 to 3 do
    Join(First + i, 'P' + IntToStr(First + i), 'S' + IntToStr(NextAccount + i), Teams[i]);
  Check('joins processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 0 to 3 do
      SetMmr('S' + IntToStr(NextAccount + i), Mmr[i]);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Inc(NextAccount, 4);
  for i := 0 to 3 do
    Spawn(First + i);
  Check('spawns processed', WaitProcessed);
  Drain;
end;

var
  A: TZSAction;
  Advice, k, MovedSlot, BravoCount, i, M1, M2, Idx, APart, BPart, X, Y: LongInt;
  Ok: Boolean;
  P: PPlayerProfile;
  ActiveSlots: array of LongInt;
  ImmBefore, LockBefore, MovesBefore: array[1..MAX_PLAYERS] of Int64;
  T0: Int64;
  Ev: TZSEvent;
  Steam: AnsiString;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'teambalance_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  WriteSettings('');
  Console := TStringList.Create;
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready', WaitReady and not Engine.IsReadOnly);

  { ---- six players: Alpha 1900, 1800, 1300 against three of 1500 ---- }
  CurTick := 0;
  MapAfter('ctf_Ash', GS_CTF, 10, 0);
  Join(1, 'Ace', 'S1', TEAM_ALPHA);
  Join(2, 'Blade', 'S2', TEAM_ALPHA);
  Join(3, 'Cub', 'S3', TEAM_ALPHA);
  Join(4, 'Dune', 'S4', TEAM_BRAVO);
  Join(5, 'Echo', 'S5', TEAM_BRAVO);
  Join(6, 'Fox', 'S6', TEAM_BRAVO);
  Check('joins processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    SetMmr('S1', 1900);
    SetMmr('S2', 1800);
    SetMmr('S3', 1300);
    SetMmr('S4', 1500);
    SetMmr('S5', 1500);
    SetMmr('S6', 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 6 do
    Spawn(i);
  Tick(2, 300);
  Check('ticks processed', WaitProcessed);
  Drain;

  { ---- joins placed from the game thread ---- }
  Advice := Engine.TeamJoinAdvice(0, TEAM_ALPHA, 255, CurTick);
  Check('a new player who asks for the stronger Alpha plays for Bravo', Advice = TEAM_BRAVO);
  Advice := Engine.TeamJoinAdvice(0, TEAM_BRAVO, 255, CurTick);
  Check('the next new player in the same tick sees the first one and goes to Alpha', Advice = TEAM_ALPHA);
  Advice := Engine.TeamJoinAdvice(0, TEAM_SPEC, 255, CurTick);
  Check('a join to the spectators is left alone', Advice = TEAM_SPEC);
  Advice := Engine.TeamJoinAdvice(4, TEAM_ALPHA, TEAM_BRAVO, CurTick);
  Check('a Bravo player may not switch to the stronger Alpha: stays (-1)', Advice = -1);
  Advice := Engine.TeamJoinAdvice(3, TEAM_BRAVO, TEAM_ALPHA, CurTick);
  Check('three against three: a switch would make two against four, so the player stays', Advice = -1);
  Check('the join requests reach the engine', WaitProcessed);
  { the requests above were not followed by joins: they expire }
  Tick(4, 300);
  Check('ticks processed', WaitProcessed);
  Drain;

  { ---- a sustained imbalance: a swap, carried out on the next deaths ---- }
  Tick(6, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and (Engine.Bal.Pending.Count = 2) and (Engine.Bal.Pending.Slot[0] = 2) and
      (Engine.Bal.Pending.Team[0] = TEAM_BRAVO) and (Engine.Live[Engine.Bal.Pending.Slot[1]].Team = TEAM_BRAVO);
    MovedSlot := Engine.Bal.Pending.Slot[1];
    WriteLn(Format('       pending: count %d, slots %d/%d', [Engine.Bal.Pending.Count, Engine.Bal.Pending.Slot[0],
      Engine.Bal.Pending.Slot[1]]));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('Alpha 64%: Blade (1800) and a Bravo player are to swap', Ok);
  Check('the chosen players are told it happens after their next death', Seen('after your next death'));
  Check('nobody is moved while alive', Length(Moves) = 0);

  Kill(MovedSlot, 2);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('Blade is moved once dead', MoveFor(2, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(2, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  Check('the other half of the swap follows at once, alive', MoveFor(MovedSlot, A) and (A.P1 = TEAM_ALPHA) and
    (A.P2 = 0));
  Kill(1, MovedSlot);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('a death while the move is on its way sends nothing more', MoveCount(MovedSlot) = 1);
  Answer(MovedSlot, TEAM_ALPHA, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof('S2');
    Ok := (P <> nil) and (P^.BalanceMoves = 1) and not Engine.Bal.Pending.Active and
      (Engine.Bal.Slots[2].LockTeam = TEAM_ALPHA) and (Engine.Live[2].Team = TEAM_BRAVO);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the swap is done, counted and locks the way back', Ok);
  Check('the move is announced', Seen('[Balance] ') and Seen('moved to'));
  Tick(1, 300);
  Check('ticks processed', WaitProcessed);
  Advice := Engine.TeamJoinAdvice(2, TEAM_ALPHA, TEAM_BRAVO, CurTick);
  Check('a moved player cannot go back to Alpha during the lock', Advice = -1);
  Check('request processed', WaitProcessed);
  Drain;
  Check('and hears why', Seen('can go back in'));

  { ---- a player leaves: a volunteer fixes the numbers before the balance has to ---- }
  { Alpha: Ace, Cub and the swapped Bravo player; Bravo: Blade and two others }
  BravoCount := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    k := 0;
    for i := 4 to 6 do
      if (i <> MovedSlot) and (Engine.Live[i].Team = TEAM_BRAVO) then
        k := i;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Leave(k);
  Tick(2, 300);
  Check('leave processed', WaitProcessed);
  Drain;
  SetLength(Moves, 0);
  Cmd(3, '!switch', SRC_CHAT, 0);
  Check('switch processed', WaitProcessed);
  Drain;
  Check('Cub may switch to Bravo: it evens the numbers', MoveFor(3, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = 0));
  Answer(3, TEAM_BRAVO, MOVE_DONE);
  Tick(8, 300);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof('S3');
    Ok := (P <> nil) and (P^.BalanceVolunteers = 1) and not Engine.Bal.Pending.Active;
    for i := 1 to MAX_PLAYERS do
      if Engine.Live[i].Active and (Engine.Live[i].Team = TEAM_BRAVO) then
        Inc(BravoCount);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the volunteer is counted and no automatic move follows', Ok and (Length(Moves) = 1));
  Check('the volunteer is thanked in public', Seen('volunteered for Bravo'));

  { ---- a switch that would hurt is refused ---- }
  Cmd(1, '!switch', SRC_CHAT, 0);
  Check('switch processed', WaitProcessed);
  Drain;
  Check('Ace may not leave Alpha for the stronger Bravo side', Seen('would make the teams uneven') and not MoveFor(1, A));

  { ---- numbers apart for longer than LeaveGraceSeconds: the balance moves somebody ---- }
  { Alpha: Ace and the swapped player; Bravo: Blade, Cub and Echo. Ace leaves: one against three.
    Blade and Cub changed team a moment ago, so Echo is the one who can go. }
  Leave(1);
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Count = 1) and
      (Engine.Bal.Pending.Slot[0] = 5) and (Engine.Bal.Pending.Team[0] = TEAM_ALPHA);
    k := Engine.Bal.Pending.Slot[0];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('one against three: Echo is chosen after the grace time, the players moved before are spared', Ok);
  { nobody dies: the move is made alive when PendingMaxSeconds is over }
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  Check('after PendingMaxSeconds the move happens without a death', MoveFor(k, A) and (A.P1 = TEAM_ALPHA) and (A.P2 = 0));
  { Echo took a flag meanwhile: main.pas does not move him, and the count fix waits for his death }
  Flag(k, FLAG_GRAB);
  Sample(k, EF_A_ALIVE or EF_A_FLAGGER);
  Answer(k, TEAM_ALPHA, MOVE_FLAGGER);
  Check('move answered', WaitProcessed);
  Drain;
  SetLength(Moves, 0);
  Tick(3, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Slot[0] = k);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a player who carries a flag is not moved, and the count fix waits for his death', Ok and not MoveFor(k, A));
  Kill(MovedSlot, k);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the flag carrier is moved once dead', MoveFor(k, A) and (A.P1 = TEAM_ALPHA) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(k, TEAM_ALPHA, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := not Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the count fix is done: two against two', Ok and (TeamSize(TEAM_ALPHA) = 2) and (TeamSize(TEAM_BRAVO) = 2));

  { ---- player and admin views ---- }
  Cmd(3, '!bal', SRC_CHAT, 0);
  Cmd(0, '/balinfo', SRC_CONSOLE, 1);
  Check('views processed', WaitProcessed);
  Drain;
  Check('!bal shows the teams and the status', Seen('Team Balance') and Seen('Status: ') and Seen('You:    strength'));
  Check('/balinfo shows the players and the decisions', Seen('Team Balance - details') and Seen('Last decisions'));
  SetLength(Moves, 0);
  Cmd(0, '/move echo bravo', SRC_CONSOLE, 1);
  Check('move processed', WaitProcessed);
  Drain;
  Check('/move sends the player at once', MoveFor(5, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = 0));
  Answer(5, TEAM_BRAVO, MOVE_DONE);
  Cmd(0, '/bal off', SRC_CONSOLE, 1);
  Tick(1, 300);
  Check('pause processed', WaitProcessed);
  Drain;
  Advice := Engine.TeamJoinAdvice(0, TEAM_BRAVO, 255, CurTick);
  Check('a paused balance leaves joins alone', Advice = TEAM_BRAVO);
  Cmd(0, '/bal on', SRC_CONSOLE, 1);
  Tick(1, 300);
  Check('resume processed', WaitProcessed);
  Drain;
  Check('the admin hears about the pause', Seen('Paused') and Seen('Running again'));

  { ---- teammatch with four teams ---- }
  MapAfter('tm_Test', GS_TM, 0, 0);
  for i := 7 to 12 do
    Join(i, 'Player' + IntToStr(i), 'S' + IntToStr(i), TEAM_ALPHA);
  Check('joins processed', WaitProcessed);
  ActiveSlots := nil;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to MAX_PLAYERS do
      if Engine.Live[i].Active then
      begin
        SetLength(ActiveSlots, Length(ActiveSlots) + 1);
        ActiveSlots[High(ActiveSlots)] := i;
        SetMmr('S' + IntToStr(i), 1500);
      end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { teams 1..4 with 2, 2, 2 and 1 player, the rest watching }
  for i := 0 to High(ActiveSlots) do
    case i of
      0, 1: TeamEv(ActiveSlots[i], TEAM_ALPHA);
      2, 3: TeamEv(ActiveSlots[i], TEAM_BRAVO);
      4, 5: TeamEv(ActiveSlots[i], TEAM_CHARLIE);
      6: TeamEv(ActiveSlots[i], TEAM_DELTA);
      else TeamEv(ActiveSlots[i], TEAM_SPEC);
    end;
  Tick(2, 0);
  Check('teams processed', WaitProcessed);
  Drain;
  Advice := Engine.TeamJoinAdvice(0, TEAM_ALPHA, 255, CurTick);
  Check('teammatch 2/2/2/1: a new player goes to Delta', Advice = TEAM_DELTA);
  Check('request processed', WaitProcessed);

  { ---- the start of a map evens the teams at once ---- }
  WriteSettings('MapStart = fix');
  Cmd(0, '/zs_reload', SRC_CONSOLE, 1);
  Check('reload processed', WaitProcessed);
  for i := 0 to High(ActiveSlots) do
    TeamEv(ActiveSlots[i], TEAM_SPEC);
  TeamEv(7, TEAM_ALPHA);
  TeamEv(8, TEAM_ALPHA);
  TeamEv(9, TEAM_ALPHA);
  TeamEv(10, TEAM_ALPHA);
  TeamEv(11, TEAM_BRAVO);
  TeamEv(12, TEAM_BRAVO);
  Check('teams processed', WaitProcessed);
  { slot 10 watched the last map, so its join review is still open - that is the next case; here
    the start of the map evens the teams by itself }
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 7 to 12 do
      Engine.Bal.Slots[k].Reviewed := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  SetLength(Moves, 0);
  Console.Clear;
  MapAfter('ctf_Run', GS_CTF, 10, 0);
  for k := 7 to 12 do
    Spawn(k);
  Tick(3, 300);
  Check('map start processed', WaitProcessed);
  Drain;
  Ok := False;
  for k := 0 to High(Moves) do
    if (Moves[k].P1 = TEAM_BRAVO) and (Moves[k].P2 = 0) and (Moves[k].Slot >= 7) and (Moves[k].Slot <= 10) then
      Ok := True;
  Check('four against two at the start of a map: one Alpha player changes team right away', Ok and (Length(Moves) = 1));
  Check('the new split is announced', Seen('New map:'));
  for k := 0 to High(Moves) do
    Answer(Moves[k].Slot, Moves[k].P1, MOVE_DONE);
  Check('moves answered', WaitProcessed);
  Drain;

  { ---- joins placed again at the start of a map: four against two of equal players is evened by
    one move. Every open review used to be judged on the same teams, and the start of the map on
    top: four moves in one second, and two against four at best. ---- }
  TeamEv(7, TEAM_ALPHA);
  TeamEv(8, TEAM_ALPHA);
  TeamEv(9, TEAM_ALPHA);
  TeamEv(10, TEAM_ALPHA);
  TeamEv(11, TEAM_BRAVO);
  TeamEv(12, TEAM_BRAVO);
  Check('teams processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 7 to 12 do
    begin
      Engine.Bal.Slots[k].Reviewed := False;
      Engine.Bal.Slots[k].ReviewUntil := Engine.GameTick + 30 * TICKS_PER_SECOND;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  SetLength(Moves, 0);
  MapAfter('ctf_Run2', GS_CTF, 10, 0);
  for k := 7 to 12 do
    Spawn(k);
  Tick(1, 300);
  Check('map start processed', WaitProcessed);
  Drain;
  { main.pas answers every move a tick later }
  M1 := Length(Moves);
  for k := 0 to High(Moves) do
    Answer(Moves[k].Slot, Moves[k].P1, MOVE_DONE);
  Tick(3, 300);
  Check('moves answered', WaitProcessed);
  Drain;
  for k := M1 to High(Moves) do
    Answer(Moves[k].Slot, Moves[k].P1, MOVE_DONE);
  Check('moves answered', WaitProcessed);
  Drain;
  Check('a join review and the start of a map at once move one player, three against three',
    (Length(Moves) = 1) and (TeamSize(TEAM_ALPHA) = 3) and (TeamSize(TEAM_BRAVO) = 3));

  { ---- MapStart = mix: new teams on every map; the way back is locked, but a mix is nobody's
    own move, so no immunity from the balance and no Balance Moves ---- }
  WriteSettings('MapStart = mix');
  Cmd(0, '/zs_reload', SRC_CONSOLE, 1);
  Check('reload processed', WaitProcessed);
  TeamEv(7, TEAM_ALPHA);
  TeamEv(8, TEAM_ALPHA);
  TeamEv(9, TEAM_ALPHA);
  TeamEv(10, TEAM_BRAVO);
  TeamEv(11, TEAM_BRAVO);
  TeamEv(12, TEAM_BRAVO);
  Check('teams processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 7 to 12 do
    begin
      ImmBefore[k] := Engine.Bal.Slots[k].ImmuneUntil;
      LockBefore[k] := Engine.Bal.Slots[k].LockUntil;
      Idx := Engine.Identity.StatsIndex(k);
      if Engine.DB.Valid(Idx) then
        MovesBefore[k] := Engine.DB.Profiles[Idx]^.BalanceMoves
      else
        MovesBefore[k] := -1;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  SetLength(Moves, 0);
  Console.Clear;
  MapAfter('ctf_Mix', GS_CTF, 10, 0);
  for k := 7 to 12 do
    Spawn(k);
  Tick(3, 300);
  Check('map start processed', WaitProcessed);
  Drain;
  WriteLn(Format('       map start mix: %d players change team', [Length(Moves)]));
  Check('map start mix: no internal error', not Seen('internal error'));
  Check('map start mix: somebody changes team, at most half of the six', (Length(Moves) > 0) and (Length(Moves) <= 3));
  Check('map start mix is announced', Seen('New map, new teams'));
  for k := 0 to High(Moves) do
    Answer(Moves[k].Slot, Moves[k].P1, MOVE_DONE);
  Check('moves answered', WaitProcessed);
  Drain;
  Ok := Length(Moves) > 0;
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 0 to High(Moves) do
    begin
      i := Moves[k].Slot;
      Idx := Engine.Identity.StatsIndex(i);
      if (Engine.Bal.Slots[i].ImmuneUntil <> ImmBefore[i]) or (Engine.Bal.Slots[i].LockUntil <= LockBefore[i]) or
         not Engine.DB.Valid(Idx) or (Engine.DB.Profiles[Idx]^.BalanceMoves <> MovesBefore[i]) then
        Ok := False;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a mixed player may not go back, but is neither immune nor counted', Ok);

  { ---- /mix from the console ---- }
  SetLength(Moves, 0);
  Console.Clear;
  Cmd(0, '/mix', SRC_CONSOLE, 1);
  Check('mix processed', WaitProcessed);
  Drain;
  Check('/mix mixes without an internal error', Seen('[Balance] New teams:') and not Seen('internal error'));
  for k := 0 to High(Moves) do
    Answer(Moves[k].Slot, Moves[k].P1, MOVE_DONE);
  Check('moves answered', WaitProcessed);
  Drain;

  { ---- survival: nobody is moved alive ---- }
  WriteSettings('');
  Cmd(0, '/zs_reload', SRC_CONSOLE, 1);
  Check('reload processed', WaitProcessed);
  TeamEv(7, TEAM_ALPHA);
  TeamEv(8, TEAM_ALPHA);
  TeamEv(9, TEAM_ALPHA);
  TeamEv(10, TEAM_ALPHA);
  TeamEv(11, TEAM_BRAVO);
  TeamEv(12, TEAM_BRAVO);
  Check('teams processed', WaitProcessed);
  Drain;
  SetLength(Moves, 0);
  Console.Clear;
  MapAfter('ctf_Survival', GS_CTF, 10, MF_SURVIVAL);
  for k := 7 to 12 do
    Spawn(k);
  Tick(200, 600);
  Check('survival processed', WaitProcessed);
  Drain;
  Ok := True;
  for k := 0 to High(Moves) do
    if Moves[k].P2 and MOVE_DEAD_ONLY = 0 then
      Ok := False;
  Check('survival: a move is planned for the next death, never for a living player',
    Ok and (Length(Moves) = 0) and Seen('after your next death'));
  EnterCriticalSection(Engine.StateLock);
  try
    if Engine.Bal.Pending.Active then
      k := Engine.Bal.Pending.Slot[0]
    else
      k := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('survival: a plan is waiting', k > 0);
  Kill(11, k);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('survival: the planned player is moved once dead', (k > 0) and MoveFor(k, A) and (A.P2 = MOVE_DEAD_ONLY));

  { an admin's swap in survival waits for the deaths as well }
  if (k > 0) and MoveFor(k, A) then
    Answer(k, A.P1, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  i := 7;
  if i = k then
    i := 8;
  SetLength(Moves, 0);
  Console.Clear;
  Cmd(0, Format('/swap %d 12', [i]), SRC_CONSOLE, 1);
  Check('swap processed', WaitProcessed);
  Drain;
  Check('survival: /swap sends moves for dead players only', MoveFor(i, A) and (A.P1 = TEAM_BRAVO) and
    (A.P2 = MOVE_DEAD_ONLY) and MoveFor(12, A) and (A.P1 = TEAM_ALPHA) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(i, TEAM_BRAVO, MOVE_ALIVE);
  Answer(12, TEAM_ALPHA, MOVE_ALIVE);
  Check('answers processed', WaitProcessed);
  Drain;
  Check('the admin hears that the swap waits for the deaths', Seen('is alive: the change to'));
  SetLength(Moves, 0);
  Kill(11, i);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('survival: the waiting admin move follows at the death, the living player still waits',
    MoveFor(i, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = MOVE_DEAD_ONLY) and not MoveFor(12, A));
  { whether /mix above moved slot 12 (and made it immune) depends on its random line-up: make it
    immune either way, the waiting move has to be the reason given }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Bal.Slots[12].ImmuneUntil := Engine.GameTick + 60 * TICKS_PER_SECOND;
    Ok := (Engine.Bal.Slots[12].WaitTeam = TEAM_ALPHA) and (Engine.BalBlocker(12) = 'being moved');
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the balance leaves a player alone while an admin move waits', Ok);

  { ---- maps: votes, players who stay after a map, players over the match, weapon picks by team ---- }
  { Soldat's own map vote, counted with the map vote of ZitroStats off ([MapVote] Enabled = 0) }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.MapVoteEnabled := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  VoteEv(7, 'ctf_Laos');
  Tick(5, 500);
  MapBefore('ctf_Laos', 0, 0, 480);
  MapAfter('ctf_Laos', GS_CTF, 10, 0);
  Leave(12);
  { the clock of a 5 minute map: the time left goes down every second }
  for i := 1 to 130 do
    Tick(1, 300 - i);
  Cmd(3, '!mapstats ctf_Survival', SRC_CHAT, 0);
  Cmd(3, '!mapstats', SRC_CHAT, 0);
  Check('map events processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    M1 := Engine.DB.FindMap('ctf_Survival', False);
    M2 := Engine.DB.FindMap('ctf_Laos', False);
    Ok := (M1 >= 0) and (M2 >= 0) and (Engine.DB.Maps[M1].VoteStarts = 1) and (Engine.DB.Maps[M1].VotesPassed = 1) and
      (Engine.DB.Maps[M2].VotedIn = 1);
    Check('a map vote followed by the map change counts as won', Ok);
    Ok := (M1 >= 0) and (Engine.DB.Maps[M1].RetentionCount = 1) and
      (Engine.DB.Maps[M1].StayedHumansSum = Engine.DB.Maps[M1].EndHumansSum - 1) and (Engine.DB.Maps[M1].EndHumansSum >= 4);
    WriteLn(Format('       after ctf_Survival: %d of %d stayed', [Engine.DB.Maps[Max(0, M1)].StayedHumansSum,
      Engine.DB.Maps[Max(0, M1)].EndHumansSum]));
    Check('two minutes into the next map, the player who left is missing', Ok);
    k := 0;
    for i := 0 to 9 do
      Inc(k, Engine.DB.Maps[Max(0, M2)].CurveSecs[i]);
    Check('players over the match are counted by tenths of the time', (M2 >= 0) and (k >= 120) and
      (Engine.DB.Maps[M2].CurveSecs[0] > 0) and (Engine.DB.Maps[M2].CurveSecs[2] > 0));
    k := WepSlot(WEP_AK74);
    Ok := (Engine.DB.Server.WeaponGlobal[k].PicksTeam[TEAM_ALPHA] > 0) and
      (Engine.DB.Server.WeaponGlobal[k].PicksTeam[TEAM_BRAVO] > 0) and
      (Engine.DB.Maps[Engine.DB.FindMap('ctf_Ash', False)].WeaponPicksTeam[TEAM_ALPHA, k] > 0);
    Check('weapon picks are counted for the team of the player', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('!mapstats shows the players, votes and team picks', Seen('Players on this Map') and Seen('Voted away: 1') and
    Seen('Over the match (each 10%):') and Seen('Alpha picks:'));

  { ---- volunteers: asked only when one of them can even the match ---- }
  WriteSettings('Volunteers = 1' + LineEnding + 'VolunteerSeconds = 30');
  Cmd(0, '/zs_reload', SRC_CONSOLE, 1);
  Join(13, 'Player13', 'S13', TEAM_SPEC);
  Join(14, 'Player14', 'S14', TEAM_SPEC);
  Check('reload processed', WaitProcessed);
  ActiveSlots := nil;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to MAX_PLAYERS do
      if Engine.Live[i].Active then
      begin
        SetLength(ActiveSlots, Length(ActiveSlots) + 1);
        ActiveSlots[High(ActiveSlots)] := i;
      end;
    for i := 7 to 14 do
      SetMmr('S' + IntToStr(i), 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 0 to High(ActiveSlots) do
    if ActiveSlots[i] < 7 then
      TeamEv(ActiveSlots[i], TEAM_SPEC);
  { three against two equal players: a volunteer would only turn the sides around }
  TeamEv(7, TEAM_ALPHA);
  TeamEv(8, TEAM_ALPHA);
  TeamEv(9, TEAM_ALPHA);
  TeamEv(10, TEAM_BRAVO);
  TeamEv(11, TEAM_BRAVO);
  for i := 7 to 11 do
    Spawn(i);
  Check('teams processed', WaitProcessed);
  Drain;
  Console.Clear;
  SetLength(Moves, 0);
  Tick(12, 160);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Engine.Bal.RequestUntil = 0) and Engine.Bal.RequestDone and Engine.Bal.NoChangeNoted and
      not Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('three against two equal players: nobody is asked to switch and nobody is moved',
    Ok and not Seen('Type !switch') and (Length(Moves) = 0));

  { even for a moment, then four against three with a much stronger Alpha }
  TeamEv(13, TEAM_BRAVO);
  Spawn(13);
  Tick(3, 160);
  Check('ticks processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    SetMmr('S7', 2700);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  TeamEv(13, TEAM_ALPHA);
  TeamEv(14, TEAM_BRAVO);
  Spawn(14);
  Tick(8, 160);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Engine.Bal.RequestUntil > Engine.GameTick) and (Engine.Bal.RequestFrom = TEAM_ALPHA) and
      (Engine.Bal.RequestTo = TEAM_BRAVO);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('four against three, one Alpha player could even it: Alpha is asked for a volunteer', Ok and Seen('Type !switch'));
  SetLength(Moves, 0);
  Cmd(7, '!switch', SRC_CHAT, 0);
  Check('switch processed', WaitProcessed);
  Drain;
  Check('the strongest player would only turn the sides around: refused',
    Seen('would not even the teams') and not MoveFor(7, A));
  Cmd(13, '!switch', SRC_CHAT, 0);
  Check('switch processed', WaitProcessed);
  Drain;
  Check('an average player evens it and goes', MoveFor(13, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = 0));
  Answer(13, TEAM_BRAVO, MOVE_DONE);
  Tick(1, 160);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof('S13');
    Ok := (P <> nil) and (P^.BalanceVolunteers = 1) and (Engine.Bal.RequestUntil = 0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the volunteer is counted and the request ends', Ok);

  { ---- a swap that has started is finished at once: half a swap would leave three against one ---- }
  WriteSettings('AssignJoins = 0');
  Cmd(0, '/zs_reload', SRC_CONSOLE, 1);
  Check('reload processed', WaitProcessed);
  ActiveSlots := nil;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to MAX_PLAYERS do
      if Engine.Live[i].Active then
      begin
        SetLength(ActiveSlots, Length(ActiveSlots) + 1);
        ActiveSlots[High(ActiveSlots)] := i;
      end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 0 to High(ActiveSlots) do
    TeamEv(ActiveSlots[i], TEAM_SPEC);
  LineUp('ctf_Replay', 15, 0, [TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO, TEAM_BRAVO], [1900, 1700, 1500, 1300]);
  ClearNotes;
  SetLength(Moves, 0);
  Tick(8, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  APart := 0;
  BPart := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and (Engine.Bal.Pending.Count = 2) and not Engine.Bal.Pending.CountFix;
    if Ok then
      for k := 0 to 1 do
        if Engine.Live[Engine.Bal.Pending.Slot[k]].Team = TEAM_ALPHA then
          APart := Engine.Bal.Pending.Slot[k]
        else
          BPart := Engine.Bal.Pending.Slot[k];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('two against two, Alpha much stronger: a swap waits for the deaths', Ok and (APart > 0) and (BPart > 0) and
    (Length(Moves) = 0));
  Kill(APart, BPart);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the dead Bravo partner is moved', MoveFor(BPart, A) and (A.P1 = TEAM_ALPHA) and (A.P2 = MOVE_DEAD_ONLY));
  SetLength(Moves, 0);
  Answer(BPart, TEAM_ALPHA, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  Check('with no further death and before the deadline, the Alpha partner follows at once',
    MoveFor(APart, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = 0));
  Answer(APart, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := not Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the swap is done: two against two, and nothing was dropped', Ok and (TeamSize(TEAM_ALPHA) = 2) and
    (TeamSize(TEAM_BRAVO) = 2) and not Noted('planned change dropped'));

  { ---- /bal against a planned count fix: it moves somebody now, and drops the plan only then ---- }
  LineUp('ctf_Bal', 19, 15, [TEAM_ALPHA, TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO], [1500, 1500, 1500, 1500]);
  ClearNotes;
  Console.Clear;
  SetLength(Moves, 0);
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Count = 1);
    Y := Engine.Bal.Pending.Slot[0];
    { the other two were moved a moment ago: only the planned player is free }
    for i := 19 to 21 do
      if i <> Y then
        Engine.Bal.Slots[i].ImmuneUntil := Engine.GameTick + 600 * TICKS_PER_SECOND;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('three against one: a count fix waits for a death', Ok and (Length(Moves) = 0));
  Cmd(0, '/bal', SRC_CONSOLE, 1);
  Check('/bal processed', WaitProcessed);
  Drain;
  X := 0;
  for k := 0 to High(Moves) do
    if (Moves[k].P1 = TEAM_BRAVO) and (Moves[k].P2 = 0) then
      X := Moves[k].Slot;
  Check('/bal moves the planned player right away', (X = Y) and not Seen('No fair change found'));
  Check('the plan is dropped only together with the change of /bal', Noted('replaced by /bal') and Noted('/bal: '));
  Answer(X, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  { three against one again; the planned player takes a flag and the other two are excluded }
  TeamEv(22, TEAM_ALPHA);
  Tick(5, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix;
    Y := Engine.Bal.Pending.Slot[0];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('three against one again: a new count fix is planned', Ok and (Y <> X));
  Flag(Y, FLAG_GRAB);
  Sample(Y, EF_A_ALIVE or EF_A_FLAGGER);
  for i := 19 to 22 do
    if (i <> X) and (i <> Y) then
      Cmd(0, Format('/balexclude %d', [i]), SRC_CONSOLE, 1);
  Check('exclusions processed', WaitProcessed);
  Drain;
  Console.Clear;
  ClearNotes;
  SetLength(Moves, 0);
  Cmd(0, '/bal', SRC_CONSOLE, 1);
  Check('/bal processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and (Engine.Bal.Pending.Slot[0] = Y);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('every Alpha player hard-blocked: /bal moves nobody and the planned change stays',
    Ok and (Length(Moves) = 0) and Seen('Nobody can be moved now') and not Seen('No fair change found') and
    not Noted('replaced by /bal'));
  Cmd(Y, '!bal', SRC_CHAT, 0);
  Check('view processed', WaitProcessed);
  Drain;
  Check('!bal tells the planned player when he moves', Seen('the balance moves you to Bravo at your next death'));
  { with the carrier excluded too, nobody can even the numbers: !bal says why }
  Cmd(0, Format('/balexclude %d', [Y]), SRC_CONSOLE, 1);
  Tick(2, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  Console.Clear;
  i := 19;
  while (i = X) or (i = Y) do
    Inc(i);
  Cmd(i, '!bal', SRC_CHAT, 0);
  Check('view processed', WaitProcessed);
  Drain;
  Check('!bal lists why nobody can be moved', Seen('nobody can be moved: ') and Seen(' (excluded)'));
  Check('!bal shows the switch BalSwitch would take', Seen('Switch: Alpha has 3 players, Bravo 1: !switch moves you to Bravo'));

  { ---- uneven numbers and nobody free: a soft protection gives way, the cheapest first; a flag
    carrier goes only at his death ---- }
  LineUp('ctf_Soft', 23, 19, [TEAM_ALPHA, TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO], [1500, 1500, 1500, 1500]);
  EnterCriticalSection(Engine.StateLock);
  try
    { 23 carries the team, 24 was moved a moment ago and may not go back yet }
    Engine.Bal.Slots[23].Form := 100;
    Engine.Bal.Slots[23].FormSince := Engine.GameTick - 200 * TICKS_PER_SECOND;
    Engine.Bal.Slots[24].ImmuneUntil := Engine.GameTick + 600 * TICKS_PER_SECOND;
    Engine.Bal.Slots[24].LockTeam := TEAM_BRAVO;
    Engine.Bal.Slots[24].LockUntil := Engine.GameTick + 180 * TICKS_PER_SECOND;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { and 25 carries a flag }
  Flag(25, FLAG_GRAB);
  Sample(25, EF_A_ALIVE or EF_A_FLAGGER);
  SetLength(Moves, 0);
  Tick(5, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Slot[0] = 23);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('three against one, nobody free: the top player goes, his protection is the cheapest', Ok);
  Cmd(0, '/balexclude 23', SRC_CONSOLE, 1);
  Tick(2, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Slot[0] = 24);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('with the top player excluded, the recently moved one goes', Ok);
  Cmd(0, '/balexclude 24', SRC_CONSOLE, 1);
  Tick(2, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Slot[0] = 25);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('only the flag carrier is left: his move waits for his death', Ok and not MoveFor(25, A));
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a flag carrier is not moved alive, not even after PendingMaxSeconds', Ok and not MoveFor(25, A));
  Kill(26, 25);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the carrier is moved once dead', MoveFor(25, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(25, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  Check('two against two', (TeamSize(TEAM_ALPHA) = 2) and (TeamSize(TEAM_BRAVO) = 2));

  { ---- a flag taken during a count fix: the plan stays, the move follows the death ---- }
  LineUp('ctf_Grab', 27, 23, [TEAM_ALPHA, TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO], [1500, 1500, 1500, 1500]);
  ClearNotes;
  SetLength(Moves, 0);
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix;
    X := Engine.Bal.Pending.Slot[0];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('three against one: a count fix waits for a death', Ok and (Length(Moves) = 0));
  Flag(X, FLAG_GRAB);
  Sample(X, EF_A_ALIVE or EF_A_FLAGGER);
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and (Engine.Bal.Pending.Slot[0] = X);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the flag keeps the plan, and the carrier is not moved alive after the deadline',
    Ok and not MoveFor(X, A) and not Noted('planned change dropped'));
  Kill(30, X);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the carrier is moved once dead', MoveFor(X, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(X, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := not Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the numbers end at most one apart', Ok and (Abs(TeamSize(TEAM_ALPHA) - TeamSize(TEAM_BRAVO)) <= 1));

  { ---- both halves of a swap sent at the deadline, one of them meets a flag: the other half is on
    its way, so the plan stays and the carrier follows at his death ---- }
  LineUp('ctf_Race', 15, 27, [TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO, TEAM_BRAVO], [1900, 1700, 1500, 1300]);
  SetLength(Moves, 0);
  Tick(18, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  APart := 0;
  BPart := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    if Engine.Bal.Pending.Active and (Engine.Bal.Pending.Count = 2) then
      for k := 0 to 1 do
        if Engine.Live[Engine.Bal.Pending.Slot[k]].Team = TEAM_ALPHA then
          APart := Engine.Bal.Pending.Slot[k]
        else
          BPart := Engine.Bal.Pending.Slot[k];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('nobody died: at the deadline both halves of the swap are sent', (APart > 0) and (BPart > 0) and
    MoveFor(APart, A) and (A.P2 = 0) and MoveFor(BPart, A) and (A.P2 = 0));
  Sample(APart, EF_A_ALIVE or EF_A_FLAGGER);
  Answer(APart, TEAM_BRAVO, MOVE_FLAGGER);
  Answer(BPart, TEAM_ALPHA, MOVE_DONE);
  Check('answers processed', WaitProcessed);
  Drain;
  SetLength(Moves, 0);
  Tick(2, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  X := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and (Engine.Live[BPart].Team = TEAM_ALPHA);
    for k := 0 to Engine.Bal.Pending.Count - 1 do
      if Engine.Bal.Pending.Slot[k] = BPart then
        Ok := Ok and Engine.Bal.Pending.Done[k]
      else if Engine.Bal.Pending.Slot[k] = APart then
        Ok := Ok and not Engine.Bal.Pending.Done[k];
    for i := 15 to 18 do
      if Engine.Live[i].Team = TEAM_BRAVO then
        X := i;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the half that was on its way is done, the carrier waits for his death', Ok and not MoveFor(APart, A));
  Kill(X, APart);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the carrier is moved once dead', MoveFor(APart, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(APart, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  Check('the swap is complete: two against two', (TeamSize(TEAM_ALPHA) = 2) and (TeamSize(TEAM_BRAVO) = 2));

  { ---- survival: a team change kills a living player, so !switch and /move wait for a death ---- }
  LineUp('ctf_SurvSwitch', 19, 15, [TEAM_ALPHA, TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO], [1500, 1500, 1500, 1500],
    MF_SURVIVAL);
  Console.Clear;
  SetLength(Moves, 0);
  Cmd(19, '!switch', SRC_CHAT, 0);
  Check('switch processed', WaitProcessed);
  Drain;
  Check('survival: the !switch of a living player is refused, it would cost his life',
    Seen('costs your life') and not MoveFor(19, A));
  { a little later than the start of the map: a death in the tick of a team change is that change }
  Inc(CurTick, 30);
  Kill(22, 19);
  Cmd(19, '!switch', SRC_CHAT, 0);
  Check('switch processed', WaitProcessed);
  Drain;
  Check('survival: once dead the same !switch goes, for the dead only', MoveFor(19, A) and (A.P1 = TEAM_BRAVO) and
    (A.P2 = MOVE_DEAD_ONLY));
  Answer(19, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  Console.Clear;
  SetLength(Moves, 0);
  Cmd(0, '/move 20 bravo', SRC_CONSOLE, 1);
  Check('move processed', WaitProcessed);
  Drain;
  Check('survival: /move of a living player is sent for the dead only', MoveFor(20, A) and (A.P1 = TEAM_BRAVO) and
    (A.P2 = MOVE_DEAD_ONLY));
  Answer(20, TEAM_BRAVO, MOVE_ALIVE);
  Check('answer processed', WaitProcessed);
  Drain;
  Check('the admin hears that it follows the death', Seen('is alive: the change to Bravo follows at the next death'));
  SetLength(Moves, 0);
  Kill(22, 20);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the waiting /move follows at the death', MoveFor(20, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(20, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  SetLength(Moves, 0);
  Cmd(0, '/move 21 spec', SRC_CONSOLE, 1);
  Check('move processed', WaitProcessed);
  Drain;
  Check('survival: /move to the spectators goes at once', MoveFor(21, A) and (A.P1 = TEAM_SPEC) and (A.P2 = 0));
  Answer(21, TEAM_SPEC, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;

  { ---- survival: a swap with one half done when the map ends is finished on the next map ---- }
  LineUp('ctf_SurvSwap', 23, 19, [TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO, TEAM_BRAVO], [1900, 1700, 1500, 1300],
    MF_SURVIVAL);
  SetLength(Moves, 0);
  Tick(8, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  APart := 0;
  BPart := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    if Engine.Bal.Pending.Active and (Engine.Bal.Pending.Count = 2) then
      for k := 0 to 1 do
        if Engine.Live[Engine.Bal.Pending.Slot[k]].Team = TEAM_ALPHA then
          APart := Engine.Bal.Pending.Slot[k]
        else
          BPart := Engine.Bal.Pending.Slot[k];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('survival two against two, Alpha much stronger: a swap waits for the deaths', (APart > 0) and (BPart > 0) and
    (Length(Moves) = 0));
  Kill(APart, BPart);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the dead Bravo partner is moved', MoveFor(BPart, A) and (A.P1 = TEAM_ALPHA) and (A.P2 = MOVE_DEAD_ONLY));
  Answer(BPart, TEAM_ALPHA, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  { the map ends before the Alpha partner dies: three against one on the next map }
  SetLength(Moves, 0);
  MapBefore('ctf_SurvSwap2', 0, 0, 0);
  MapAfter('ctf_SurvSwap2', GS_CTF, 10, MF_SURVIVAL);
  for i := 23 to 26 do
    Spawn(i);
  Tick(3, 300);
  Check('map change processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and (Engine.Bal.Pending.Count = 2) and not Engine.Bal.Pending.CountFix;
    for k := 0 to Engine.Bal.Pending.Count - 1 do
      if Engine.Bal.Pending.Slot[k] = APart then
        Ok := Ok and not Engine.Bal.Pending.Done[k]
      else
        Ok := Ok and Engine.Bal.Pending.Done[k];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the started swap is still planned on the new map, and nobody is moved alive', Ok and (Length(Moves) = 0));
  Kill(BPart, APart);
  Check('kill processed', WaitProcessed);
  Drain;
  Check('the Alpha partner is moved at his first death on the new map', MoveFor(APart, A) and (A.P1 = TEAM_BRAVO) and
    (A.P2 = MOVE_DEAD_ONLY));
  Answer(APart, TEAM_BRAVO, MOVE_DONE);
  Check('move answered', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := not Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the swap is complete: two against two', Ok and (TeamSize(TEAM_ALPHA) = 2) and (TeamSize(TEAM_BRAVO) = 2));

  { ---- /yes: /yes alone is no wrong password, a confirm password with a space in it works, and
    one typed in public chat cancels what waits and locks /yes, whoever typed it ---- }
  WriteSettings('AssignJoins = 0' + LineEnding + '[Admin]' + LineEnding + 'ConfirmPassword = open sesame');
  Cmd(0, '/zs_reload', SRC_CONSOLE, 1);
  Check('reload processed', WaitProcessed);
  Drain;
  Console.Clear;
  Cmd(0, '/resetmapstats ctf_Ash', SRC_CONSOLE, 1);
  Cmd(0, '/yes', SRC_CONSOLE, 1);
  Check('confirm processed', WaitProcessed);
  Drain;
  Check('/yes without the password locks nothing and the operation still waits',
    Seen('Confirm with the command /yes <confirm password>') and not Seen('Wrong password'));
  { a save of the engine in progress asks for the /yes again }
  i := 0;
  repeat
    Console.Clear;
    Cmd(0, '/yes open sesame', SRC_CONSOLE, 1);
    Check('confirm processed', WaitProcessed);
    Drain;
    Inc(i);
    if Seen('A save is in progress') then
      Sleep(500);
  until not Seen('A save is in progress') or (i >= 10);
  { the operation ends after its backup (in a folder deeper than MAX_PATH allows the backup fails
    and the operation is called off: either way nothing waits afterwards) }
  T0 := MonoMs;
  while not Seen('statistics of map ctf_Ash were reset') and not Seen('The backup failed') and (MonoMs - T0 < 10000) do
  begin
    Sleep(50);
    Drain;
  end;
  Check('a confirm password with a space in it is accepted', Seen('Confirmed. Making a backup first') and
    not Seen('Wrong password'));
  Console.Clear;
  Cmd(0, '/resetmapstats ctf_Ash', SRC_CONSOLE, 1);
  Cmd(23, '!yes open sesame', SRC_CHAT, 1);
  Check('confirm processed', WaitProcessed);
  Drain;
  Check('the password typed in chat by another admin cancels the waiting operation',
    Seen('Never type the confirm password in chat') and Seen('The operation waiting for /yes was cancelled'));
  Console.Clear;
  Cmd(0, '/yes open sesame', SRC_CONSOLE, 1);
  Cmd(0, '/resetmapstats ctf_Ash', SRC_CONSOLE, 1);
  Check('commands processed', WaitProcessed);
  Drain;
  Check('nothing waits any more, and /yes stays locked', Seen('Nothing is waiting for confirmation') and
    Seen('/yes is locked for') and not Seen('This will reset'));

  { ---- a new map drops a planned change that has not started, and the player who waited for it
    hears so; a move on its way when the map changes still counts once main.pas answers it ---- }
  LineUp('ctf_Plan', 27, 23, [TEAM_ALPHA, TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO], [1500, 1500, 1500, 1500]);
  SetLength(Moves, 0);
  Tick(12, 300);
  Check('ticks processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active and Engine.Bal.Pending.CountFix and (Engine.Bal.Pending.Count = 1);
    X := Engine.Bal.Pending.Slot[0];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('three against one: a count fix waits for a death', Ok and (Length(Moves) = 0));
  Console.Clear;
  ClearNotes;
  MapAfter('ctf_Plan2', GS_CTF, 10, 0);
  Check('map change processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := not Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a new map drops the planned change, and the player who waited for it hears so', Ok and
    Noted('planned change dropped: a new map started') and
    Seen(Format('|%d|[Balance] The planned team change is off (a new map started)', [X])));
  SetLength(Moves, 0);
  Cmd(0, '/move 28 bravo', SRC_CONSOLE, 1);
  Check('move processed', WaitProcessed);
  Drain;
  Check('/move sends the player at once', MoveFor(28, A) and (A.P1 = TEAM_BRAVO) and (A.P2 = 0));
  Console.Clear;
  MapAfter('ctf_Plan3', GS_CTF, 10, 0);
  Answer(28, TEAM_BRAVO, MOVE_DONE);
  Check('answer after the map change processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Engine.Live[28].Team = TEAM_BRAVO) and (Engine.Bal.Slots[28].LockTeam = TEAM_ALPHA) and
      (Engine.Bal.Slots[28].LockUntil > Engine.GameTick);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a move answered on the new map still counts: the player hears it and the way back is locked',
    Ok and Seen('An admin moved you to Bravo'));

  { ---- a player who comes back gets his lock and his team back also when Steam knows him only
    after JoinReviewSeconds ---- }
  LineUp('ctf_Memory', 27, 27, [TEAM_ALPHA, TEAM_ALPHA, TEAM_BRAVO, TEAM_BRAVO], [1500, 1500, 1500, 1500]);
  Steam := 'S' + IntToStr(NextAccount - 4);
  EnterCriticalSection(Engine.StateLock);
  try
    { no correction of the balance in the way, and Steam is waited for as long as it takes }
    Engine.Cfg.BalanceMinPlayers := 32;
    Engine.Cfg.SteamAuthWaitSeconds := 60;
    { 27 has played here (an account with nothing on it is not kept), and the balance moved him away
      from Bravo a moment ago }
    P := Prof(Steam);
    if P <> nil then
      P^.TimePlayed := 600;
    Engine.Bal.Slots[27].LockTeam := TEAM_BRAVO;
    Engine.Bal.Slots[27].LockUntil := Engine.GameTick + 180 * TICKS_PER_SECOND;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Leave(27);
  Tick(1, 300);
  Ev := NewEvent(zeJoin);
  Ev.Slot := 27;
  Ev.S1 := 'P27';
  Ev.S2 := '';
  Ev.S3 := 'HW' + Steam;
  Ev.S4 := '10.0.0.27';
  Ev.I[0] := TEAM_BRAVO;
  Ev.I[1] := 1;
  Push(Ev);
  Tick(12, 300);
  Check('rejoin processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Identity.IsPending(27);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('JoinReviewSeconds are over and Steam has not answered yet', Ok);
  SetLength(Moves, 0);
  Ev := NewEvent(zeSteamAuth);
  Ev.Slot := 27;
  Ev.S1 := Steam;
  Push(Ev);
  Tick(1, 300);
  Check('late Steam answer processed', WaitProcessed);
  Drain;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Engine.Bal.Slots[27].LockTeam = TEAM_BRAVO) and (Engine.Bal.Slots[27].LockUntil > Engine.GameTick);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a late Steam answer: the lock is back, and the player goes back to the team he played for',
    Ok and MoveFor(27, A) and (A.P1 = TEAM_ALPHA) and (A.P2 = 0));

  Engine.Free;
  Console.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
