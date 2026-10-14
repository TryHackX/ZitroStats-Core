program test_fix_ws4;

{ The fixes of workstream 4 of the audit of 2026-10-06, each against the engine like main.pas drives
  it (every ACT_MOVE is answered with the team event and ZS_Ev_Move_Result):
    ZSE2-01  a !switch that evens nothing is no move of the balance, and one !switch a minute
    ZSE2-03  two !switch or two !join in the same moment: the second waits for the first
    ZSE2-04  teammatch, TeammatchTeams = auto: one player alone in Charlie pulls nobody after him
    X-06     a player taken out of Charlie in CTF (BE TeamGuard) is sent on, not kept there (-1)
    ZSE2-05  [MapVote] GapSeconds: a pause after every vote, whoever starts the next
    ZSE2-07  an operation waiting for another admin's /yes is not silently taken over
    ZSE2-08  a reset or a merge of an account online leaves its session and match points as they were
    ZSE2-09  /removeolderthan says before /yes how many accounts go, and how many of them are Steam's
    ZSI-07   /zs_merge never loses a Steam account, and a password goes along to an account without
    ZSE2-02  [Matrix] MatrixPruneDays also by the map and by the rival, and its size in /zs_status
    X-09     the ranking for AntiFake with the computer of the account (ZS_API_Top_Player_Copy2) }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_weapons, zs_engine, zs_commands, zs_balance, zs_matrix;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console: TStringList;
  Moves: array of TZSAction;
  Root: AnsiString;
  CurStyle: LongInt = GS_CTF;

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

{ ---------------- the engine ---------------- }

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
    Sleep(2);
  end;
  Sleep(60);
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

{ output lines go to Console ("kind|slot|text"), team moves to Moves }
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

procedure Step;
begin
  Check('events processed', WaitProcessed);
  Drain;
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

{ a line to one slot (0 = the server console) holding Part }
function SaidTo(Slot: LongInt; const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to Console.Count - 1 do
    if (Pos(Part, Console[k]) > 0) and ((Pos(Format('%d|%d|', [ACT_CONSOLE, Slot]), Console[k]) = 1) or
       ((Slot = 0) and (Pos(Format('%d|', [ACT_WRITELN]), Console[k]) = 1))) then
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

procedure StartEngine(const Name, Settings: AnsiString);
var
  L: TStringList;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'fixws4_' + Name);
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  L := TStringList.Create;
  try
    L.Text := Settings;
    L.SaveToFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini');
  finally
    L.Free;
  end;
  Console.Clear;
  Moves := nil;
  Pushed := 0;
  CurTick := 1000;
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check(Name + ': engine ready', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure StopEngine;
begin
  Engine.Free;
  Engine := nil;
  SetCurrentDir(ExtractFileDir(ExtractFileDir(ExtractFileDir(Root))));
end;

procedure MapAfter(const Name: AnsiString; Style: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := 10;
  Push(Ev);
  CurStyle := Style;
end;

procedure Join(Slot: LongInt; const Name, Steam: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := 'HW' + Name;
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
    Ev.I[5] := CurStyle;
    Push(Ev);
  end;
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

{ under the state lock }
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

function TeamOf(Slot: LongInt): LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.Live[Slot].Team;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ---------------- the team balance ---------------- }

const
  BALANCE_INI =
    '[Ranking]' + LineEnding + 'MinHumansForStats = 2' + LineEnding +
    '[Balance]' + LineEnding + 'Enabled = 1' + LineEnding + 'MinPlayers = 4' + LineEnding +
    'SustainSeconds = 5' + LineEnding + 'CheckSeconds = 1' + LineEnding + 'CooldownSeconds = 90' + LineEnding +
    'MaxMovesPerMap = 4' + LineEnding + 'LeaveGraceSeconds = 3' + LineEnding + 'PendingMaxSeconds = 10' + LineEnding +
    'JoinReviewSeconds = 0' + LineEnding + 'UncertaintyGames = 0' + LineEnding + 'Volunteers = 0' + LineEnding +
    'MapStart = keep' + LineEnding + 'ProtectTop = 0' + LineEnding + 'UseMapBias = 0' + LineEnding +
    'FormWeight = 0' + LineEnding + 'AfkSeconds = 3600' + LineEnding + 'MinTimeLeftSeconds = 0' + LineEnding;

{ a !switch of Slot, answered by main.pas when it is sent; True when it was sent }
function Switch(Slot: LongInt): Boolean;
var
  A: TZSAction;
begin
  Moves := nil;
  Cmd(Slot, '!switch', SRC_CHAT, 0);
  Step;
  Result := MoveFor(Slot, A);
  if Result then
  begin
    Answer(Slot, A.P1, MOVE_DONE);
    Tick(1, 600);
    Step;
  end;
end;

{ ZSE2-01: six neutral switches at five against four used to count as six moves of the balance:
  MaxMovesPerMap was used up, the cooldown ran and a lasting imbalance was counted from zero again,
  so one or two players kept the balance away for the whole map }
procedure TestSwitchCounts;
const
  ORDER: array[0..5] of LongInt = (1, 6, 2, 7, 3, 8);
var
  i, k, Moved, Alpha: LongInt;
  Ok: Boolean;
  P: PPlayerProfile;
begin
  StartEngine('balance', BALANCE_INI);
  MapAfter('ctf_Gap', GS_CTF);
  for i := 1 to 9 do
    if i <= 5 then
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_ALPHA)
    else
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_BRAVO);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to 9 do
      SetMmr('S' + IntToStr(i), 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 9 do
    Spawn(i);
  Tick(3, 600);
  Step;

  { five against four of equal players: a switch only turns the sides round, it is allowed, but it
    helps nobody }
  Moved := 0;
  for k := 0 to High(ORDER) do
    if Switch(ORDER[k]) then
      Inc(Moved);
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Engine.Bal.MovesThisMap = 0) and (Engine.Bal.LastMoveTick < Engine.GameTick - 1000 * TICKS_PER_SECOND);
    for i := 1 to 9 do
    begin
      P := Prof('S' + IntToStr(i));
      if (P = nil) or (P^.BalanceVolunteers <> 0) then
        Ok := False;
    end;
    Alpha := 0;
    for i := 1 to 9 do
      if Engine.Live[i].Team = TEAM_ALPHA then
        Inc(Alpha);
    WriteLn(Format('       after %d switches: MovesThisMap %d, Alpha %d, Bravo %d', [Moved, Engine.Bal.MovesThisMap,
      Alpha, 9 - Alpha]));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-01: six !switch at five against four all go (each turns the sides round)', Moved = 6);
  Check('ZSE2-01: a !switch that evens nothing is no move of the balance: no MaxMovesPerMap, no cooldown, ' +
    'no Balance Volunteers', Ok);

  { the same player again within a minute: refused, nothing sent }
  Console.Clear;
  Check('ZSE2-01: the second !switch of a player within a minute is refused',
    not Switch(6) and SaidTo(6, 'You changed team a moment ago: !switch again in'));

  { Alpha (4, 5, 6, 7, 8 now) becomes far stronger: the balance still plans a change }
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 4 to 8 do
      SetMmr('S' + IntToStr(i), 1900);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Tick(8, 600);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Bal.Pending.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-01: after the six switches a lasting imbalance still gets a planned change', Ok);
  StopEngine;
end;

{ ZSE2-03: at five against three two Alpha players typed !switch in the same tick and both went
  (three against five); two spectators with !join at four against four both went to the same team }
procedure TestTwoAtOnce;
var
  i: LongInt;
  A: TZSAction;
begin
  StartEngine('twoatonce', BALANCE_INI);
  MapAfter('ctf_Twice', GS_CTF);
  for i := 1 to 10 do
    if i <= 5 then
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_ALPHA)
    else if i <= 8 then
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_BRAVO)
    else
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_SPEC);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to 10 do
      SetMmr('S' + IntToStr(i), 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 8 do
    Spawn(i);
  Tick(1, 600);
  Step;

  Moves := nil;
  Console.Clear;
  Cmd(1, '!switch', SRC_CHAT, 0);
  Cmd(2, '!switch', SRC_CHAT, 0);
  Step;
  Check('ZSE2-03: five against three, two !switch in one tick: the first goes to Bravo',
    MoveFor(1, A) and (A.P1 = TEAM_BRAVO));
  Check('ZSE2-03: ... the second waits for it and hears why',
    not MoveFor(2, A) and SaidTo(2, 'A team change is on its way, try again in a moment.'));
  Answer(1, TEAM_BRAVO, MOVE_DONE);
  Tick(1, 600);
  Step;
  Check('ZSE2-03: four against four after the one switch', (TeamOf(1) = TEAM_BRAVO) and (TeamOf(2) = TEAM_ALPHA));

  Moves := nil;
  Console.Clear;
  Cmd(9, '!join', SRC_CHAT, 0);
  Cmd(10, '!join', SRC_CHAT, 0);
  Step;
  Check('ZSE2-03: two !join at four against four in one tick: one goes, the other waits for it',
    MoveFor(9, A) and not MoveFor(10, A) and SaidTo(10, 'A team change is on its way, try again in a moment.'));
  Answer(9, A.P1, MOVE_DONE);
  Tick(1, 600);
  Step;
  Moves := nil;
  Cmd(10, '!join', SRC_CHAT, 0);
  Step;
  Check('ZSE2-03: the second !join a moment later goes to the other team',
    MoveFor(10, A) and (A.P1 <> TeamOf(9)) and (A.P1 >= TEAM_ALPHA) and (A.P1 <= TEAM_BRAVO));
  StopEngine;
end;

function TeamsInUse: LongInt;
var
  TeamNo: TBalTeamNos;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.BalTeams(TeamNo);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function MovedInto(Team: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(Moves) do
    if Moves[k].P1 = Team then
      Exit(True);
end;

{ ZSE2-04: three against three in a teammatch; a new player picks the empty Charlie. Charlie counted
  as a team in use, and the count fix moved an Alpha player and, once the first one had gone to the
  spectators, a Bravo player into it: 2/2/2 for a match of two teams. }
procedure TestUnusedTeam;
var
  i, Advice: LongInt;
begin
  StartEngine('unusedteam', BALANCE_INI);
  MapAfter('tm_Spare', GS_TM);
  for i := 1 to 8 do
    if i <= 3 then
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_ALPHA)
    else if i <= 6 then
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_BRAVO)
    else
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_SPEC);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to 8 do
      SetMmr('S' + IntToStr(i), 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 6 do
    Spawn(i);
  Tick(2, 600);
  Step;
  Advice := Engine.TeamJoinAdvice(7, TEAM_CHARLIE, TEAM_SPEC, CurTick);
  Check('ZSE2-04: the unused Charlie is no team of the balance, the join is left alone', Advice = TEAM_CHARLIE);
  TeamEv(7, TEAM_CHARLIE);
  Spawn(7);
  Moves := nil;
  Console.Clear;
  Tick(20, 600);
  Step;
  Check('ZSE2-04: one player alone in Charlie: the balance still evens two teams', TeamsInUse = 2);
  Check('ZSE2-04: ... and moves nobody into Charlie (20 s, LeaveGraceSeconds 3)', not MovedInto(TEAM_CHARLIE));
  Cmd(7, '!switch', SRC_CHAT, 0);
  Step;
  Check('ZSE2-04: !switch alone in Charlie says why nothing happens',
    SaidTo(7, 'The balance does not even your team: change the team from the menu.'));
  TeamEv(7, TEAM_SPEC);
  Tick(20, 600);
  Step;
  Check('ZSE2-04: he went to the spectators: still nobody moved into Charlie', not MovedInto(TEAM_CHARLIE) and
    (TeamOf(1) = TEAM_ALPHA) and (TeamOf(4) = TEAM_BRAVO));
  TeamEv(7, TEAM_CHARLIE);
  TeamEv(8, TEAM_CHARLIE);
  Tick(1, 600);
  Step;
  Check('ZSE2-04: two players in Charlie: three teams in use', TeamsInUse = 3);
  StopEngine;
end;

{ X-06: a human in Charlie in CTF (an admin's /setteam3) is moved to Alpha by the TeamGuard of
  Basic-Extended; the balance, which would rather see him in Bravo, answered -1 as for a player of a
  team, the server cancelled the change and the player stayed in a team the mode does not have }
procedure TestOutsideTeam;
var
  i, Advice: LongInt;
begin
  StartEngine('outsideteam', BALANCE_INI);
  MapAfter('ctf_Guard', GS_CTF);
  for i := 1 to 7 do
    if i <= 3 then
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_ALPHA)
    else
      Join(i, 'P' + IntToStr(i), 'S' + IntToStr(i), TEAM_BRAVO);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to 7 do
      if i <= 3 then
        SetMmr('S' + IntToStr(i), 1900)
      else
        SetMmr('S' + IntToStr(i), 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 7 do
    Spawn(i);
  TeamEv(7, TEAM_CHARLIE);
  Tick(2, 600);
  Step;
  { (an answer that is not the team asked for counts as a join on its way until the engine saw it:
    the refusal is asked first) }
  Advice := Engine.TeamJoinAdvice(4, TEAM_ALPHA, TEAM_BRAVO, CurTick);
  Check('X-06: a Bravo player who asks for the stronger Alpha still stays where he is (-1)', Advice = -1);
  Advice := Engine.TeamJoinAdvice(7, TEAM_ALPHA, TEAM_CHARLIE, CurTick);
  Check(Format('X-06: out of Charlie in CTF into the stronger Alpha: sent on to Bravo, never kept in Charlie (%d)',
    [Advice]), Advice = TEAM_BRAVO);
  Advice := Engine.TeamJoinAdvice(7, TEAM_BRAVO, TEAM_CHARLIE, CurTick);
  Check('X-06: out of Charlie into Bravo: allowed', Advice = TEAM_BRAVO);
  Step;
  StopEngine;
end;

{ ---------------- the map vote ---------------- }

procedure MapList(const Names: AnsiString; Reason: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapList);
  Ev.I[1] := 0;
  Ev.I[2] := Reason;
  Ev.S1 := Names;
  Push(Ev);
end;

procedure MapBefore(const Next: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapBefore);
  Ev.S1 := Next;
  Ev.I[4] := 300;
  Push(Ev);
end;

function VoteRuns: Boolean;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.MV.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ZSE2-05: the only limit was the starter's own wait, so three players taking turns kept a vote (and
  Soldat's vote dialog, during which the server ignores a kick vote) on the screens all the time }
procedure TestMapVoteGap;
const
  LIST = 'ctf_A' + #10 + 'ctf_B' + #10 + 'ctf_C' + #10;
begin
  StartEngine('mapvote', '[MapVote]' + LineEnding + 'GapSeconds = 60' + LineEnding + 'StarterCooldownSeconds = 0' +
    LineEnding + 'VoteSeconds = 20' + LineEnding + 'BlockAfterChangeSeconds = 20' + LineEnding);
  MapAfter('ctf_A', GS_CTF);
  MapList(LIST, MAPLIST_START);
  Join(1, 'Ann', 'S1', TEAM_ALPHA);
  Join(2, 'Ben', 'S2', TEAM_BRAVO);
  Join(3, 'Cid', 'S3', TEAM_ALPHA);
  Tick(2, 600);
  Step;
  Console.Clear;
  Cmd(1, '!map ctf_b', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: a vote starts', Seen('Ann wants ctf_B') and VoteRuns);
  Tick(21, 600);
  Step;
  Check('ZSE2-05: ... and fails after VoteSeconds', Seen('The vote for ctf_B failed') and not VoteRuns);
  Console.Clear;
  Cmd(2, '!map ctf_c', SRC_CHAT, 0);
  Step;
  { the vote failed 20 s after its start, a second ago }
  Check('ZSE2-05: another player at once: refused, GapSeconds after the last vote',
    SaidTo(2, 'A map vote ended a moment ago: the next one can start in 59 s.') and not VoteRuns);
  Tick(40, 600);
  Cmd(3, '!map ctf_c', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: 40 s later still refused', SaidTo(3, 'the next one can start in 19 s.') and not VoteRuns);
  Tick(20, 600);
  Console.Clear;
  Cmd(3, '!map ctf_c', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: after GapSeconds the next vote starts', Seen('Cid wants ctf_C') and VoteRuns);
  Console.Clear;
  Cmd(0, '/zs_mapvote cancel', SRC_CONSOLE, 1);
  Cmd(1, '!map ctf_b', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: an admin''s cancel is followed by the gap as well',
    Seen('An admin cancelled the vote for ctf_C') and SaidTo(1, 'the next one can start in 60 s.') and not VoteRuns);

  { a reload of the script and a map change are no votes of the players: no gap after them }
  Tick(61, 600);
  Console.Clear;
  Cmd(1, '!map ctf_b', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: a vote after the gap', Seen('Ann wants ctf_B') and VoteRuns);
  MapList(LIST, MAPLIST_START);
  Cmd(2, '!map ctf_c', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: a vote the script reload ended leaves no gap',
    Seen('The script was loaded again') and Seen('Ben wants ctf_C') and VoteRuns);
  MapBefore('ctf_B');
  Tick(1, 600);
  MapAfter('ctf_B', GS_CTF);
  MapList(LIST, MAPLIST_MAPCHANGE);
  Tick(21, 600);
  Console.Clear;
  Cmd(3, '!map ctf_c', SRC_CHAT, 0);
  Step;
  Check('ZSE2-05: on the next map only BlockAfterChangeSeconds count, not the gap after the vote the change ended',
    Seen('Cid wants ctf_C') and VoteRuns);
  Console.Clear;
  Cmd(0, '/zs_mapvote', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-05: /zs_mapvote shows the gap',
    SaidTo(0, '[Map vote] after a vote the next one on the same map waits 60 s, whoever starts it'));
  StopEngine;
end;

{ ---------------- admin operations ---------------- }

const
  ADMIN_INI = '[Admin]' + LineEnding + 'ConfirmPassword = pw-for-tests' + LineEnding + '[Ranking]' + LineEnding +
    'MinHumansForStats = 1' + LineEnding + '[Identity]' + LineEnding + 'SteamAuthWaitSeconds = 0' + LineEnding;

function PendingKind: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.Pending.Kind;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ZSE2-07: a second admin's operation replaced the one waiting for the first admin's /yes without a
  word (he heard "Only the admin who started the operation can confirm it" at his /yes), and a
  password of /zs_setpass waiting in it was not wiped }
procedure TestPendingTakeover;
var
  Arg: AnsiString;
  Slot: LongInt;
begin
  StartEngine('pending', ADMIN_INI);
  MapAfter('ctf_A', GS_CTF);
  Join(1, 'Ann', 'S1', TEAM_ALPHA);
  Tick(1, 600);
  Step;
  Console.Clear;
  Cmd(1, '/resetmapstats ctf_A', SRC_COMMAND, 1);
  Step;
  Check('ZSE2-07: Ann''s operation waits for her /yes', SaidTo(1, 'This will reset the statistics of map ctf_A') and
    (PendingKind = OP_RESET_MAP));
  Console.Clear;
  Cmd(0, '/resetserverstats', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-07: the console cannot take it over while it waits',
    SaidTo(0, 'reset-map of Ann waits for /yes (') and not SaidTo(0, 'This will') and (PendingKind = OP_RESET_MAP));
  Cmd(1, '/no', SRC_COMMAND, 1);
  Step;
  Console.Clear;
  Cmd(0, '/resetserverstats', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-07: once she said /no the console may start one', SaidTo(0, 'This will reset the server statistics') and
    (PendingKind = OP_RESET_SERVER));
  Console.Clear;
  Cmd(0, '/zs_setpass #1 new-secret-pass', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-07: the same admin replaces his own operation and hears so',
    SaidTo(0, 'The reset-server that waited for your /yes is replaced.') and (PendingKind = OP_SETPASS));
  { the confirmation time of the console is over: Ann may start hers, and the password waiting in the
    console's operation goes }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Pending.Expires := Now - 1 / 86400;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Console.Clear;
  Cmd(1, '/resetmapstats ctf_A', SRC_COMMAND, 1);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    Arg := Engine.Pending.Arg;
    Slot := Engine.Pending.AdminSlot;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-07: an operation whose time is over is replaced, the password in it is gone',
    SaidTo(1, 'This will reset the statistics of map ctf_A') and (PendingKind = OP_RESET_MAP) and (Slot = 1) and
    (Arg = 'ctf_A'));
  StopEngine;
end;

{ /yes for the console's operation, and the wait for its backup and the operation itself }
function ConfirmAndWait: Boolean;
var
  T0: Int64;
begin
  Cmd(0, '/yes pw-for-tests', SRC_CONSOLE, 1);
  Step;
  T0 := MonoMs;
  repeat
    Tick(1, 600);
    WaitProcessed;
    Drain;
  until (PendingKind = OP_NONE) or (MonoMs - T0 > 15000);
  Result := PendingKind = OP_NONE;
end;

function IdOf(const Steam: AnsiString): LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    if Prof(Steam) <> nil then
      Result := Prof(Steam)^.ID
    else
      Result := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ZSE2-08: an admin reset the statistics of a player online from 3500 to 1000 points: !session showed
  "Points: -2500" until he joined again and the table of the match until the next map; a merge into
  an account online made the same jump upwards }
procedure TestSessionPoints;
var
  Ann, Ben: LongInt;
  Ok: Boolean;
begin
  StartEngine('points', ADMIN_INI);
  MapAfter('ctf_A', GS_CTF);
  Join(1, 'Ann', 'S1', TEAM_ALPHA);
  Join(2, 'Ben', 'S2', TEAM_BRAVO);
  Tick(1, 600);
  Step;
  Ann := IdOf('S1');
  Ben := IdOf('S2');
  { Ben played (an account that never played goes when its player leaves) and leaves }
  EnterCriticalSection(Engine.StateLock);
  try
    Prof('S2')^.Points := 1500;
    Prof('S2')^.Kills := 5;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Leave(2);
  Tick(1, 600);
  Step;
  { Ann won 100 points this session and 50 of them in this match }
  EnterCriticalSection(Engine.StateLock);
  try
    Prof('S1')^.Points := 3500;
    Engine.Live[1].SessionStartPoints := 3400;
    Engine.Live[1].MatchStartPoints := 3450;
    Ok := (Prof('S2') <> nil) and (Prof('S2')^.Points = 1500);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-08: Ben''s account stays after he left', Ok);
  Cmd(0, Format('/resetplayerstats #%d', [Ann]), SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-08: the reset is done', ConfirmAndWait);
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Prof('S1')^.Points = 1000) and (Engine.Live[1].SessionStartPoints = 900) and
      (Engine.Live[1].MatchStartPoints = 950);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-08: after a reset to 1000 points the session still shows +100, the match +50', Ok);
  Console.Clear;
  Cmd(1, '!session', SRC_CHAT, 0);
  Step;
  Check('ZSE2-08: !session says Points: +100', SaidTo(1, 'Points: +100'));
  Cmd(0, Format('/zs_merge #%d #%d', [Ben, Ann]), SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-08: the merge is done', ConfirmAndWait);
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Prof('S1')^.Points = 1500) and (Engine.Live[1].SessionStartPoints = 1400) and
      (Engine.Live[1].MatchStartPoints = 1450);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-08: a merge of 500 points into the account online: still +100 in the session, +50 in the match', Ok);
  StopEngine;
end;

{ an account that played (one that never did goes when its player leaves); Steam '' = a computer
  account; under the state lock afterwards: Prof / ProfOfHwid }
procedure Account(Slot: LongInt; const Name, Steam: AnsiString);
var
  Idx: LongInt;
begin
  Join(Slot, Name, Steam, TEAM_ALPHA);
  Tick(1, 600);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    Idx := Engine.Identity.ProfileIndex(Slot);
    if Engine.DB.Valid(Idx) then
      Engine.DB.Profiles[Idx]^.Kills := 3;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Leave(Slot);
  Tick(1, 600);
  Step;
end;

function ProfNamed(const Name: AnsiString): PPlayerProfile;
var
  C: TIntArray;
begin
  Result := nil;
  C := Engine.DB.IndexesOfName(Name);
  if (Length(C) > 0) and Engine.DB.Valid(C[0]) then
    Result := Engine.DB.Profiles[C[0]];
end;

{ ZSE2-09: "delete unregistered accounts not seen for N days" - but an account is registered only
  with a password, which a Steam account cannot have: every Steam account that long away went, and
  the admin learned how many only afterwards }
procedure TestRemoveOlder;
var
  Ok: Boolean;
begin
  StartEngine('removeolder', ADMIN_INI);
  MapAfter('ctf_A', GS_CTF);
  Join(1, 'Ann', 'S1', TEAM_ALPHA);
  Account(2, 'Ben', 'S2');
  Account(3, 'Cid', '');
  Account(4, 'Dee', '');
  Account(5, 'Eve', 'S5');
  Account(6, 'Fay', 'S6');
  EnterCriticalSection(Engine.StateLock);
  try
    { Ben (Steam) and Cid (a computer) are long away; Dee as well, with a password; Eve as well,
      with protection days; Fay played a moment ago, Ann plays }
    Prof('S2')^.LastPlayedTime := Now - 100;
    ProfNamed('Cid')^.LastPlayedTime := Now - 100;
    ProfNamed('Dee')^.LastPlayedTime := Now - 100;
    ProfNamed('Dee')^.PassHash := 'hash-for-tests';
    Prof('S5')^.LastPlayedTime := Now - 100;
    Prof('S5')^.ProtectionDays := 3;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Console.Clear;
  Cmd(0, '/removeolderthan 90', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-09: the confirmation counts the accounts that go',
    SaidTo(0, 'This will delete 2 accounts not seen for 90 days.'));
  Check('ZSE2-09: ... says how many of them are Steam accounts, and how many as old stay',
    SaidTo(0, '1 of them are Steam accounts; 2 as old stay (a password, protection days or online).'));
  Check('ZSE2-09: the count holds', ConfirmAndWait);
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Prof('S2') = nil) and (ProfNamed('Cid') = nil) and (ProfNamed('Dee') <> nil) and (Prof('S5') <> nil) and
      (Prof('S6') <> nil) and (Prof('S1') <> nil);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSE2-09: exactly those two went', Ok and SaidTo(0, '2 accounts inactive for 90 days were removed'));
  Console.Clear;
  Cmd(0, '/removeolderthan 90', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-09: nothing left to delete: no confirmation is asked for',
    SaidTo(0, 'Nothing to delete (2 accounts not seen for 90 days, all registered, protected or online).') and
    (PendingKind = OP_NONE));
  StopEngine;
end;

function IdNamed(const Name: AnsiString): LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    if ProfNamed(Name) <> nil then
      Result := ProfNamed(Name)^.ID
    else
      Result := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ZSI-07: the merged account keeps the identity of #into only: /zs_merge #steam #computer left no
  account with that SteamID (the next join with Steam made a new, empty one), and
  /zs_merge #registered #unregistered left an account without a password }
procedure TestMergeIdentity;
var
  Ben, Cid, Dee, Eve, Idx: LongInt;
  Ok: Boolean;
  H: TIntArray;
begin
  StartEngine('merge', ADMIN_INI);
  MapAfter('ctf_A', GS_CTF);
  Account(2, 'Ben', 'S2');
  Account(3, 'Cid', '');
  Account(4, 'Dee', '');
  Account(5, 'Eve', '');
  Ben := IdNamed('Ben');
  Cid := IdNamed('Cid');
  Dee := IdNamed('Dee');
  Eve := IdNamed('Eve');
  EnterCriticalSection(Engine.StateLock);
  try
    { Dee has a password and trusts the computer HWDee2 as well }
    Idx := Engine.DB.IndexOfId(Dee);
    Engine.DB.BeginIdentityChange(Idx);
    Engine.DB.Profiles[Idx]^.PassHash := 'hash-for-tests';
    Engine.DB.Profiles[Idx]^.PassSalt := 'salt-for-tests';
    Engine.DB.Profiles[Idx]^.PassIter := 7;
    SetLength(Engine.DB.Profiles[Idx]^.TrustedDevices, 1);
    Engine.DB.Profiles[Idx]^.TrustedDevices[0].HWID := 'HWDee2';
    Engine.DB.Profiles[Idx]^.TrustedDevices[0].Expire := Now + 30;
    Engine.DB.EndIdentityChange(Idx);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Console.Clear;
  Cmd(0, Format('/zs_merge #%d #%d', [Ben, Cid]), SRC_CONSOLE, 1);
  Step;
  Check('ZSI-07: a Steam account into a computer account is refused, with the other order to use',
    SaidTo(0, Format('#%d is a Steam account, #%d is not: the merge would lose it. Use /zs_merge #%d #%d.',
      [Ben, Cid, Cid, Ben])) and (PendingKind = OP_NONE));
  Console.Clear;
  Cmd(0, Format('/zs_merge #%d #%d', [Cid, Ben]), SRC_CONSOLE, 1);
  Step;
  Check('ZSI-07: the other way round is asked for, and says whose identity stays',
    SaidTo(0, Format('This will merge #%d Cid into #%d Ben.', [Cid, Ben])) and
    SaidTo(0, Format('#%d keeps its Steam ID.', [Ben])) and (PendingKind = OP_MERGE));
  Cmd(0, '/no', SRC_CONSOLE, 1);
  Step;
  Console.Clear;
  Cmd(0, Format('/zs_merge #%d #%d', [Dee, Eve]), SRC_CONSOLE, 1);
  Step;
  Check('ZSI-07: a registered account into one without a password: the password goes along, and the admin hears so',
    SaidTo(0, Format('#%d keeps its computer and gets the password of #%d.', [Eve, Dee])));
  Check('ZSI-07: the merge is done', ConfirmAndWait);
  EnterCriticalSection(Engine.StateLock);
  try
    Idx := Engine.DB.IndexOfId(Eve);
    H := Engine.DB.IndexesOfHwid('HWDee2');
    Ok := Engine.DB.Valid(Idx) and (Engine.DB.IndexOfId(Dee) < 0) and
      (Engine.DB.Profiles[Idx]^.PassHash = 'hash-for-tests') and (Engine.DB.Profiles[Idx]^.PassSalt = 'salt-for-tests') and
      (Engine.DB.Profiles[Idx]^.PassIter = 7) and (Length(Engine.DB.Profiles[Idx]^.TrustedDevices) = 1) and
      (Length(H) = 1) and (H[0] = Idx);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('ZSI-07: the merged account has the password and the trusted computer of #from, the computer finds it', Ok);
  StopEngine;
end;

{ ---------------- [Matrix] ---------------- }

type
  { when an account played last: every account of the test played today (1000) }
  TPlayedToday = class
    function LastPlayed(AccountId: LongInt): Double;
  end;

function TPlayedToday.LastPlayed(AccountId: LongInt): Double;
begin
  Result := 1000;
end;

{ ZSE2-02: the records of an account that keeps playing were never pruned - neither a map it had
  left for years nor the rivals it no longer met - so [Matrix] only grew (accounts x maps x rivals),
  and /zs_status did not show it }
procedure TestMatrixPrune;
var
  T: TPlayerMapTable;
  LP: TPlayedToday;
  R: PPlayerMapStats;
  Rv: PPMRival;
  Place, n: LongInt;
  B0, B1: Int64;
  Ok: Boolean;
begin
  T := TPlayerMapTable.Create;
  LP := TPlayedToday.Create;
  try
    { account 1 played ctf_Old 200 days ago and ctf_New today, where it met 2 today and 3 200 days
      ago; the entry of 5 has no date and stays }
    T.Obtain(1, T.MapNumber('ctf_Old', True), 800);
    Place := T.Obtain(1, T.MapNumber('ctf_New', True), 1000);
    R := T.Items[Place];
    Rv := PMRivalOf(R^, 2, 0);
    Rv^.Kills := 1;
    Rv^.LastFight := 1000;
    Rv := PMRivalOf(R^, 3, 0);
    Rv^.Kills := 5;
    Rv^.LastFight := 800;
    Rv := PMRivalOf(R^, 5, 0);
    Rv^.Deaths := 2;
    Rv^.LastFight := 0;
    T.Obtain(2, T.MapNumber('ctf_New', True), 995);
    B0 := T.ApproxBytes;
    { MatrixMapPruneDays = 0 (the default): an account that plays keeps every map and rival }
    n := T.Prune(90, 0, 1000, @LP.LastPlayed);
    R := T.Find(1, 'ctf_New');
    Check('ZSE2-02: MatrixMapPruneDays = 0 keeps the maps and rivals of an account that plays',
      (n = 0) and (T.Find(1, 'ctf_Old') <> nil) and (R <> nil) and (Length(R^.Rivals) = 3));
    n := T.Prune(90, 90, 1000, @LP.LastPlayed);
    R := T.Find(1, 'ctf_New');
    Ok := (n = 1) and (T.Find(1, 'ctf_Old') = nil) and (T.Find(2, 'ctf_New') <> nil) and (R <> nil) and
      (Length(R^.Rivals) = 2) and (R^.Rivals[0].Id = 2) and (R^.Rivals[1].Id = 5) and (T.Count = 2);
    Check('ZSE2-02: the record of a map not played for MatrixMapPruneDays goes, though the account plays', Ok);
    Check('ZSE2-02: ... and of the rivals of a record that stays, those not fought for so many days go',
      (R <> nil) and (Length(R^.Rivals) = 2));
    B1 := T.ApproxBytes;
    WriteLn(Format('       [Matrix] in memory: %d bytes before the prune, %d after', [B0, B1]));
    Check('ZSE2-02: the size of the records: at least the records, less after the prune',
      (B1 >= 2 * SizeOf(TPlayerMapStats)) and (B1 < B0));
    Check('ZSE2-02: Prune(0, 0) prunes nothing', T.Prune(0, 0, 5000, @LP.LastPlayed) = 0);
  finally
    T.Free;
    LP.Free;
  end;

  StartEngine('matrix', ADMIN_INI);
  MapAfter('ctf_A', GS_CTF);
  Join(1, 'Ann', 'S1', TEAM_ALPHA);
  Tick(1, 600);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    n := Engine.DB.PM.Count;
    Engine.DB.PM.Obtain(Prof('S1')^.ID, Engine.DB.PM.MapNumber('ctf_B', True), Now);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Console.Clear;
  Cmd(0, '/zs_status', SRC_CONSOLE, 1);
  Step;
  Check('ZSE2-02: /zs_status shows the player-on-map records and their size',
    SaidTo(0, Format('[Matrix] %d player-on-map records, about ', [n + 1])) and SaidTo(0, ' MB in memory'));
  StopEngine;
end;

{ ---------------- the ranking for AntiFake ---------------- }

{ X-09: AntiFake asks for the account at a position of the ranking (<command>i <position>) and got
  only the name and the SteamID: an account without Steam was looked up by its name, which anybody
  can play under. ZS_API_Top_Player_Copy2 adds the computer; the old answer stays as it was. }
procedure TestTopPlayerHwid;
var
  Two, Three: array[1..2] of AnsiString;
  k: LongInt;
begin
  StartEngine('topplayer', ADMIN_INI);
  MapAfter('ctf_A', GS_CTF);
  Account(2, 'Ben', 'S2');
  Account(3, 'Cid', '');
  EnterCriticalSection(Engine.StateLock);
  try
    Prof('S2')^.Points := 1500;
    ProfNamed('Cid')^.Points := 1400;
    Engine.DB.RebuildRanks;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for k := 1 to 2 do
  begin
    Two[k] := Engine.ApiTopPlayerWait(k);
    Three[k] := Engine.ApiTopPlayerWait(k, True);
  end;
  WriteLn('       ranking for AntiFake: ', StringReplace(Three[1], #9, '<TAB>', [rfReplaceAll]), ' / ',
    StringReplace(Three[2], #9, '<TAB>', [rfReplaceAll]));
  Check('X-09: the old answer stays name, tab, SteamID', (Two[1] = 'Ben' + #9 + 'S2') and (Two[2] = 'Cid' + #9));
  Check('X-09: the new one adds a tab and the computer of the account',
    (Three[1] = 'Ben' + #9 + 'S2' + #9 + 'HWBen') and (Three[2] = 'Cid' + #9 + #9 + 'HWCid'));
  Check('X-09: nobody at a position past the end', Engine.ApiTopPlayerWait(3, True) = '');
  StopEngine;
end;

begin
  Console := TStringList.Create;
  TestSwitchCounts;
  TestTwoAtOnce;
  TestUnusedTeam;
  TestOutsideTeam;
  TestMapVoteGap;
  TestPendingTakeover;
  TestSessionPoints;
  TestRemoveOlder;
  TestMergeIdentity;
  TestMatrixPrune;
  TestTopPlayerHwid;
  Console.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
