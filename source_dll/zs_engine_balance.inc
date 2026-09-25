{ zs_engine_balance.inc - team balance (part of zs_engine)

  The balance judges teams by the strength of their players, not by the score of the map:

  - strength   the player's long-term rating (MMR by default) pulled towards the median of the
               server while it rests on few matches, plus how the player does on this map
               (Method = blend), only one of the two (global, map);
  - joins      main.pas asks TeamJoinAdvice from the game thread before a player enters a team;
               the answer comes from a snapshot the engine refreshes, never from the engine state;
  - checks     every CheckSeconds; a team that stays above Threshold for SustainSeconds, or
               numbers further apart than MaxCountDiff for LeaveGraceSeconds, get one correction:
               a volunteer first, then the move or swap with the best result, carried out when the
               player dies next (in survival only while dead); once half of a swap is done the other
               half follows at once, and uneven numbers are fixed even when only protected players
               can go (only a hard rule keeps a player);
  - memory     locks, immunity and form belong to the account and survive leaving the server for
               RejoinMemoryMinutes, so rejoining or going to the spectators changes nothing. }

const
  BK_NONE = 0;
  BK_AUTO = 1;         { a correction of the balance }
  BK_VOLUNTEER = 2;    { !switch }
  BK_ADMIN = 3;        { /bal, /move, /swap, /mix }
  BK_JOIN = 4;         { !join of a spectator }
  BK_REVIEW = 5;       { a join placed again once the player's account was known }
  BK_START = 6;        { the start of a map }
  BK_MIX = 7;          { the start of a map with MapStart = mix }
  BAL_MIX_TRIES = 40;  { line-ups a mix tries }

  BAL_MOVE_TIMEOUT = 3 * TICKS_PER_SECOND;     { a move main.pas did not answer is forgotten }
  BAL_EXPECT_TICKS = 3 * TICKS_PER_SECOND;     { how long an announced join is waited for }
  BAL_SAMPLE_TICKS = 10 * TICKS_PER_SECOND;    { predictions of the running match }
  BAL_REFERENCE_TICKS = 300 * TICKS_PER_SECOND;
  BAL_HISTORY_MAX = 400;
  BAL_NEVER = -1000000000;

function BalTeamIndexOf(const TeamNo: TBalTeamNos; TeamCount, Team: LongInt): LongInt;
var
  t: LongInt;
begin
  Result := -1;
  for t := 0 to TeamCount - 1 do
    if TeamNo[t] = Team then
      Exit(t);
end;

procedure SortDoubles(var A: array of Double; L, R: LongInt);
var
  i, j: LongInt;
  P, T: Double;
begin
  while L < R do
  begin
    i := L;
    j := R;
    P := A[(L + R) div 2];
    repeat
      while A[i] < P do
        Inc(i);
      while A[j] > P do
        Dec(j);
      if i <= j then
      begin
        T := A[i];
        A[i] := A[j];
        A[j] := T;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - L < R - i then
    begin
      if L < j then
        SortDoubles(A, L, j);
      L := i;
    end
    else
    begin
      if i < R then
        SortDoubles(A, i, R);
      R := j;
    end;
  end;
end;

function PercentText(V: Double): AnsiString;
begin
  Result := IntToStr(Round(V * 100)) + '%';
end;

{ ---------------- state ---------------- }

procedure TZSEngine.BalResetSlot(S: LongInt);
begin
  if (S < 1) or (S > MAX_PLAYERS) then
    Exit;
  Finalize(Bal.Slots[S]);
  FillChar(Bal.Slots[S], SizeOf(TBalSlot), 0);
  Bal.Slots[S].FormSince := GameTick;
  Bal.Slots[S].TeamSince := GameTick;
  Bal.Slots[S].ImmuneUntil := BAL_NEVER;
  Bal.Slots[S].LockUntil := BAL_NEVER;
end;

procedure TZSEngine.BalInit;
var
  S: LongInt;
begin
  Bal.Paused := False;
  for S := 1 to MAX_PLAYERS do
    BalResetSlot(S);
  Bal.Memory := nil;
  Bal.Expected := nil;
  Bal.Pending.Active := False;
  Bal.SeenId := 0;
  Bal.ChanceSince := 0;
  Bal.CountSince := 0;
  Bal.LastMoveTick := BAL_NEVER;
  Bal.LastCheckTick := BAL_NEVER;
  Bal.MovesThisMap := 0;
  Bal.RequestUntil := 0;
  Bal.RequestDone := False;
  Bal.MapStartTick := 0;
  Bal.Median := 1500;
  Bal.BotStrength := 1400;
  Bal.RefDone := False;
  Bal.RefTick := BAL_NEVER;
  Bal.PredSum := 0;
  Bal.PredCount := 0;
  Bal.PredTick := BAL_NEVER;
  Bal.LogNext := 0;
  Bal.History := nil;
  Bal.HistoryCount := 0;
  Bal.HistoryNext := 0;
  Bal.FitCount := 0;
  Bal.FitSize := 1.5;
  Bal.FitDouble := 400;
  Bal.FitBrier := 0.25;
  Bal.Dirty := True;
  InitCriticalSection(FBalLock);
  FBalSnap.Valid := False;
  FJoinReqs := nil;
  FJoinReqId := 0;
end;

function BalKindText(Kind: LongInt): AnsiString;
begin
  case Kind of
    BK_AUTO: Result := 'balance';
    BK_VOLUNTEER: Result := 'volunteer';
    BK_ADMIN: Result := 'admin';
    BK_JOIN: Result := 'join';
    BK_REVIEW: Result := 'join review';
    BK_START: Result := 'map start';
    BK_MIX: Result := 'map start mix';
    else Result := 'other';
  end;
end;

procedure TZSEngine.BalNote(const Text: AnsiString);
begin
  Bal.Log[Bal.LogNext] := FormatDateTime('hh:nn:ss', Now) + '  ' + Text;
  Bal.LogNext := (Bal.LogNext + 1) mod Length(Bal.Log);
  AppendLog('teambalance.log', Text);
end;

function TZSEngine.BalanceActive: Boolean;
begin
  Result := Cfg.BalanceEnabled and not Bal.Paused and FReady and Match.Active and TeamGame;
end;

function TZSEngine.BalTeams(out TeamNo: TBalTeamNos): LongInt;
var
  S, Highest: LongInt;
begin
  TeamNo[0] := TEAM_ALPHA;
  TeamNo[1] := TEAM_BRAVO;
  TeamNo[2] := TEAM_CHARLIE;
  TeamNo[3] := TEAM_DELTA;
  Result := 2;
  if Match.GameStyle <> GS_TM then
    Exit;
  if Cfg.BalanceTeammatchTeams >= 2 then
    Exit(Cfg.BalanceTeammatchTeams);
  { the teams in use, at least Alpha and Bravo }
  Highest := TEAM_BRAVO;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and (Live[S].Team >= TEAM_ALPHA) and (Live[S].Team <= TEAM_DELTA) then
      Highest := Max(Highest, Live[S].Team);
  Result := Highest;
end;

function TZSEngine.BalSizeImpact: Double;
begin
  if Cfg.BalanceAutoTune and (Bal.FitCount >= 50) then
    Result := Bal.FitSize
  else
    Result := Cfg.BalanceSizeImpact;
end;

function TZSEngine.BalSkillPerDouble: Double;
begin
  if Cfg.BalanceAutoTune and (Bal.FitCount >= 50) then
    Result := Bal.FitDouble
  else
    Result := Cfg.BalanceSkillPerDouble;
end;

{ the side advantage of the map, from its Alpha and Bravo wins; five even matches are added so a
  short history says little }
function TZSEngine.BalAlphaBias: Double;
var
  M, A, B: LongInt;
  P: Double;
begin
  Result := 1;
  M := Match.MapIndex;
  if not Cfg.BalanceUseMapBias or (M < 0) or (M >= DB.MapCount) then
    Exit;
  A := DB.Maps[M].AlphaWins;
  B := DB.Maps[M].BravoWins;
  if A + B < 10 then
    Exit;
  P := EnsureRange((A + 5) / (A + B + 10), 0.35, 0.65);
  Result := P / (1 - P);
end;

function TZSEngine.BalParamsFor(TeamCount: LongInt): TBalParams;
var
  t: LongInt;
begin
  Result.SizeImpact := BalSizeImpact;
  for t := 0 to BAL_MAX_TEAMS - 1 do
    Result.Bias[t] := 1;
  if TeamCount = 2 then
    Result.Bias[0] := BalAlphaBias;
end;

{ ---------------- strength ---------------- }

{ a rating on the MMR scale; Games tells how much it rests on }
function TZSEngine.BalSkill(const P: TPlayerProfile; Family: LongInt; out Games: LongInt): Double;
var
  Method: AnsiString;
  Lo, Hi, Mid, n: LongInt;
  Scale: Double;
begin
  Method := LowerCase(Trim(Cfg.BalanceSkill));
  if Method = 'glicko2' then
  begin
    Games := P.Glicko[Family].Games;
    Result := P.Glicko[Family].R;
  end
  else if Method = 'openskill' then
  begin
    Games := P.OpenSkill[Family].Games;
    { beta is the skill gap of a 76% favourite, 200 points on the Elo scale }
    Scale := 200 / Max(0.1, Cfg.OSBeta);
    Result := 1500 + (P.OpenSkill[Family].Mu - Cfg.OSMu) * Scale;
  end
  else if Method = 'points' then
  begin
    Games := P.Wins + P.Loses;
    n := Length(Bal.RefPoints);
    if n = 0 then
      Exit(1500);
    { the place among the active accounts, as a normal distribution around 1500 }
    Lo := 0;
    Hi := n;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if Bal.RefPoints[Mid] < P.Points then
        Lo := Mid + 1
      else
        Hi := Mid;
    end;
    Result := 1500 + 200 * EnsureRange(NormalQuantile((Lo + 0.5) / (n + 1)), -3.0, 3.0);
  end
  else
  begin
    Games := P.Mmr[Family].Games;
    Result := P.Mmr[Family].R;
    if Result <= 0 then
      Result := DB.MmrStart;
  end;
end;

procedure TZSEngine.BalRefreshReference;
var
  Vals: array of Double;
  i, n, np, Games, Family: LongInt;
  P: PPlayerProfile;
  Cutoff, V: Double;
begin
  Bal.RefTick := GameTick;
  Bal.RefDone := True;
  Family := CurrentFamily;
  Cutoff := Now - 30;
  SetLength(Bal.RefPoints, DB.ProfileCount);
  np := 0;
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if (P = nil) or (P^.LastPlayedTime < Cutoff) then
      Continue;
    Bal.RefPoints[np] := P^.Points;
    Inc(np);
  end;
  SetLength(Bal.RefPoints, np);
  if np > 1 then
    SortDoubles(Bal.RefPoints, 0, np - 1);
  SetLength(Vals, DB.ProfileCount);
  n := 0;
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if (P = nil) or (P^.LastPlayedTime < Cutoff) then
      Continue;
    V := BalSkill(P^, Family, Games);
    if Games > 0 then
    begin
      Vals[n] := V;
      Inc(n);
    end;
  end;
  if n > 1 then
    SortDoubles(Vals, 0, n - 1);
  if SameText(Trim(Cfg.BalanceSkill), 'points') then
  begin
    Bal.Median := 1500;
    Bal.BotStrength := 1500 + 200 * EnsureRange(NormalQuantile(Cfg.BalanceBotSkill / 100), -3.0, 3.0);
  end
  else if n = 0 then
  begin
    Bal.Median := 1500;
    Bal.BotStrength := 1500 + 200 * EnsureRange(NormalQuantile(Cfg.BalanceBotSkill / 100), -3.0, 3.0);
  end
  else
  begin
    if n mod 2 = 1 then
      Bal.Median := Vals[n div 2]
    else
      Bal.Median := (Vals[n div 2 - 1] + Vals[n div 2]) / 2;
    Bal.BotStrength := Vals[EnsureRange(Round((n - 1) * Cfg.BalanceBotSkill / 100), 0, n - 1)];
  end;
end;

{ the long-term strength, pulled towards the median while it rests on few matches }
function TZSEngine.BalBase(S: LongInt; out Skill: Double; out Games: LongInt): Double;
var
  Idx, U: LongInt;
begin
  Games := 0;
  Skill := Bal.Median;
  if not Live[S].Human then
  begin
    Skill := Bal.BotStrength;
    Exit(Bal.BotStrength);
  end;
  Idx := Identity.StatsIndex(S);
  if not DB.Valid(Idx) then
    Exit(Bal.Median);
  Skill := BalSkill(DB.Profiles[Idx]^, CurrentFamily, Games);
  U := Max(0, Cfg.BalanceUncertaintyGames);
  if Games + U <= 0 then
    Result := Skill
  else
    Result := Bal.Median + (Skill - Bal.Median) * Games / (Games + U);
end;

function TZSEngine.BalFormWeight(S: LongInt): Double;
begin
  if Cfg.BalanceFormFullMinutes <= 0 then
    Result := 1
  else
    Result := Min(1.0, Max(0, GameTick - Bal.Slots[S].FormSince) /
      (Cfg.BalanceFormFullMinutes * 60 * TICKS_PER_SECOND));
  Result := Result * Cfg.BalanceFormWeight;
end;

function TZSEngine.BalStrength(S: LongInt): Double;
var
  Skill: Double;
  Games: LongInt;
  Method: AnsiString;
begin
  if not Live[S].Human then
    Exit(Bal.BotStrength);
  Method := LowerCase(Trim(Cfg.BalanceMethod));
  if Method = 'map' then
    Result := Bal.Median + Bal.Slots[S].Form
  else if Method = 'global' then
    Result := BalBase(S, Skill, Games)
  else
    Result := BalBase(S, Skill, Games) + BalFormWeight(S) * Bal.Slots[S].Form;
end;

function TZSEngine.BalAfk(S: LongInt): Boolean;
var
  Last: LongInt;
begin
  { only a living player can be judged: in survival the dead wait for the next round }
  Last := Max(Max(Live[S].LastMoveTick, Live[S].LastShotTick), Max(Live[S].SpawnTick, Bal.Slots[S].TeamSince));
  Result := Live[S].Human and Live[S].Alive and (GameTick - Last >= Cfg.BalanceAfkSeconds * TICKS_PER_SECOND);
end;

function TZSEngine.BalPowerOf(S: LongInt): Double;
begin
  Result := BalPower(BalStrength(S), Bal.Median, BalSkillPerDouble);
  if BalAfk(S) then
    Result := Result * Cfg.BalanceAfkFactor;
end;

{ ---------------- who may be moved ---------------- }

function TZSEngine.BalExcludedAccount(S: LongInt): Boolean;
var
  Idx: LongInt;
begin
  Result := False;
  if Trim(Cfg.BalanceExclude) = '' then
    Exit;
  Idx := Identity.ProfileIndex(S);
  if DB.Valid(Idx) then
    Result := Pos(' #' + IntToStr(DB.Profiles[Idx]^.ID) + ' ',
      ' ' + StringReplace(StringReplace(Cfg.BalanceExclude, ',', ' ', [rfReplaceAll]), ';', ' ', [rfReplaceAll]) + ' ') > 0;
end;

function TZSEngine.BalInPending(S: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := False;
  if Bal.Pending.Active then
    for k := 0 to Bal.Pending.Count - 1 do
      if (Bal.Pending.Slot[k] = S) and not Bal.Pending.Done[k] then
        Exit(True);
end;

{ half of a swap is done: the other half has to follow }
function BalPlanStarted(const Pending: TBalPending): Boolean;
var
  k: LongInt;
begin
  Result := False;
  if Pending.Active then
    for k := 0 to Pending.Count - 1 do
      if Pending.Done[k] then
        Exit(True);
end;

{ a move sent to main.pas and not answered yet: the teams change in a moment, so nothing that
  counts the players of the teams should plan another change before (main.pas answers in a tick) }
function BalMoveUnderWay(const Bal: TBalState): Boolean;
var
  S: LongInt;
begin
  Result := False;
  for S := 1 to MAX_PLAYERS do
    if Bal.Slots[S].MoveKind <> BK_NONE then
      Exit(True);
end;

{ A count fix, or a swap with half of it done or on its way, is not given up because a player of it
  carries a flag or does not die in time: the move waits for the death instead. }
function BalPlanMustFinish(const Bal: TBalState): Boolean;
var
  k: LongInt;
begin
  Result := Bal.Pending.Active and (Bal.Pending.CountFix or BalPlanStarted(Bal.Pending));
  if Bal.Pending.Active then
    for k := 0 to Bal.Pending.Count - 1 do
      if not Bal.Pending.Done[k] and (Bal.Slots[Bal.Pending.Slot[k]].MoveKind <> BK_NONE) then
        Result := True;
end;

{ the player who does most for the team on this map }
function TZSEngine.BalIsTop(S: LongInt): Boolean;
var
  A: LongInt;
  F: Double;
begin
  F := Bal.Slots[S].Form;
  Result := (F >= 2 * Cfg.BalanceFormStep) and (GameTick - Bal.Slots[S].FormSince >= 120 * TICKS_PER_SECOND);
  if not Result then
    Exit;
  for A := 1 to MAX_PLAYERS do
    if (A <> S) and Live[A].Active and Live[A].Human and (Live[A].Team = Live[S].Team) and
       ((Bal.Slots[A].Form > F) or ((Bal.Slots[A].Form = F) and (A < S))) then
      Exit(False);
end;

{ Why the balance may not move S now, '' when nothing stands in the way. The hard reasons come first
  and always hold: a bot, an excluded player, a move that is planned or under way, and a living flag
  carrier. The others give way when the numbers are uneven and nobody free can go; Soft is the price
  of overruling them (0 for a free player, -1 after a hard reason). IgnorePlan leaves out the planned
  change, for /bal, which replaces it. }
function BalProtection(E: TZSEngine; S: LongInt; IgnorePlan: Boolean; out Soft: Double): AnsiString;
begin
  Soft := -1;
  if not E.Live[S].Human then
    Exit('bot');
  if E.Bal.Slots[S].Excluded or E.BalExcludedAccount(S) then
    Exit('excluded');
  if (E.Bal.Slots[S].MoveKind <> BK_NONE) or (E.Bal.Slots[S].WaitTeam > 0) or
     (not IgnorePlan and E.BalInPending(S)) then
    Exit('being moved');
  if E.Live[S].Alive and (E.Live[S].Flags and EF_A_FLAGGER <> 0) then
    Exit('carries a flag');
  Result := '';
  Soft := 0;
  if E.Bal.Slots[S].ImmuneUntil > E.GameTick then
  begin
    Result := 'moved recently';
    Soft := 0.10;
    { while the way back is locked as well, going back is dearer still }
    if E.Bal.Slots[S].LockUntil > E.GameTick then
      Soft := Soft + 0.15;
  end;
  if E.Cfg.BalanceProtectTop and E.BalIsTop(S) then
  begin
    if Result = '' then
      Result := 'carries the team';
    Soft := Soft + 0.05;
  end;
end;

function TZSEngine.BalBlocker(S: LongInt): AnsiString;
var
  Soft: Double;
begin
  Result := BalProtection(Self, S, False, Soft);
end;

{ what a move costs the player, in imbalance points }
function TZSEngine.BalCost(S: LongInt): Double;
begin
  if GameTick - Live[S].JoinTick < 60 * TICKS_PER_SECOND then
    Result := 0.005
  else if Live[S].Alive then
    Result := 0.03
  else
    Result := 0.01;
  Result := Result + Min(0.03, 0.01 * Max(0, GameTick - Bal.Slots[S].TeamSince) / (300.0 * TICKS_PER_SECOND));
  if Match.Survival and Live[S].Alive then
    Result := Result + 0.05;
end;

function TZSEngine.BalGather(out Cands: TBalCandArray; out TeamNo: TBalTeamNos; out TeamCount: LongInt;
  out Params: TBalParams; out Chances: TBalTeamValues): Double;
var
  S, T, n: LongInt;
begin
  TeamCount := BalTeams(TeamNo);
  Params := BalParamsFor(TeamCount);
  Cands := nil;
  n := 0;
  for S := 1 to MAX_PLAYERS do
  begin
    if not Live[S].Active then
      Continue;
    T := BalTeamIndexOf(TeamNo, TeamCount, Live[S].Team);
    if (T < 0) or (not Live[S].Human and not Cfg.BalanceCountBots) then
      Continue;
    SetLength(Cands, n + 1);
    Cands[n].Id := S;
    Cands[n].Team := T;
    Cands[n].Power := BalPowerOf(S);
    Cands[n].Counts := True;
    Cands[n].Movable := BalProtection(Self, S, False, Cands[n].Soft) = '';
    Cands[n].Cost := BalCost(S);
    Inc(n);
  end;
  Result := BalMatchImbalance(Cands, TeamCount, Params, Chances);
end;

function TZSEngine.BalHumans(const Cands: TBalCandArray): LongInt;
var
  i: LongInt;
begin
  Result := 0;
  for i := 0 to High(Cands) do
    if Live[Cands[i].Id].Human then
      Inc(Result);
end;

function TZSEngine.BalHumansOnTeams: LongInt;
var
  S: LongInt;
  TeamNo: TBalTeamNos;
  N: LongInt;
begin
  Result := 0;
  N := BalTeams(TeamNo);
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human and (BalTeamIndexOf(TeamNo, N, Live[S].Team) >= 0) then
      Inc(Result);
end;

{ decided matches of the running map, the history behind its side factor }
function TZSEngine.MapDecided: LongInt;
begin
  Result := 0;
  if (Match.MapIndex >= 0) and (Match.MapIndex < DB.MapCount) then
    Result := DB.Maps[Match.MapIndex].AlphaWins + DB.Maps[Match.MapIndex].BravoWins;
end;

function TZSEngine.BalChanceText(const Ch: TBalTeamValues; const TeamNo: TBalTeamNos; TeamCount: LongInt): AnsiString;
var
  t: LongInt;
begin
  if TeamCount = 2 then
    Exit(Format('%s %s : %s %s', [TeamTitle(TeamNo[0]), PercentText(Ch[0]), PercentText(Ch[1]), TeamTitle(TeamNo[1])]));
  Result := '';
  for t := 0 to TeamCount - 1 do
  begin
    if t > 0 then
      Result := Result + ', ';
    Result := Result + TeamTitle(TeamNo[t]) + ' ' + PercentText(Ch[t]);
  end;
end;

function TZSEngine.BalMatchDecided: Boolean;
var
  T, Hi, Second, Limit: LongInt;
begin
  Result := False;
  Limit := Match.ScoreLimit;
  if Limit <= 0 then
    Exit;
  Hi := 0;
  Second := 0;
  for T := 1 to 4 do
    if Match.TeamScore[T] > Hi then
    begin
      Second := Hi;
      Hi := Match.TeamScore[T];
    end
    else if Match.TeamScore[T] > Second then
      Second := Match.TeamScore[T];
  Result := (Limit - Hi <= Max(1, Limit div 10)) and (Hi - Second >= Max(2, Limit * 3 div 10));
end;

function TZSEngine.BalMayMove(CountFix: Boolean; out Why: AnsiString): Boolean;
var
  Cooldown: LongInt;
begin
  Result := False;
  if CountFix then
    Cooldown := 10 * TICKS_PER_SECOND
  else
    Cooldown := Cfg.BalanceCooldownSeconds * TICKS_PER_SECOND;
  if (Match.TimeLeft > 0) and (Match.TimeLeft < Cfg.BalanceMinTimeLeftSeconds) then
    Why := 'the map is about to end'
  else if BalMatchDecided then
    Why := 'the match is decided'
  else if Bal.MovesThisMap >= Cfg.BalanceMaxMovesPerMap then
    Why := 'enough moves on this map'
  else if GameTick - Bal.LastMoveTick < Cooldown then
    Why := 'a move was made a moment ago'
  else
  begin
    Why := '';
    Result := True;
  end;
end;

{ ---------------- moves ---------------- }

procedure TZSEngine.BalSend(S, Team, Kind: LongInt; DeadOnly: Boolean; FavTeam: LongInt; Before, After: Double;
  By: LongInt);
var
  A: TZSAction;
begin
  A := NewAction(ACT_MOVE, S, 0, '');
  A.P1 := Team;
  { a move of the balance is not the player's own team change }
  Live[S].ScriptTeamTick := GameTick;
  if DeadOnly then
    A.P2 := MOVE_DEAD_ONLY;
  EmitAction(A);
  Bal.Slots[S].MoveKind := Kind;
  Bal.Slots[S].MoveTeam := Team;
  Bal.Slots[S].MoveFrom := Live[S].Team;
  Bal.Slots[S].MoveSent := GameTick;
  Bal.Slots[S].MoveFav := FavTeam;
  Bal.Slots[S].MoveBefore := Before;
  Bal.Slots[S].MoveAfter := After;
  Bal.Slots[S].MoveBy := By;
end;

procedure TZSEngine.BalCancelPending(const Why: AnsiString);
var
  k, S: LongInt;
  MustFinish: Boolean;
  Reason: AnsiString;
begin
  if not Bal.Pending.Active then
    Exit;
  MustFinish := BalPlanMustFinish(Bal);
  Bal.Pending.Active := False;
  if Why <> '' then
    BalNote('planned change dropped: ' + Why);
  { the players who waited for the change hear that it is off; one whose move is on its way (the
    /bal or /move that replaces the plan) hears about that move instead }
  if Why <> '' then
    Reason := ' (' + Why + ')'
  else
    Reason := '';
  if Match.Active then
    for k := 0 to Bal.Pending.Count - 1 do
    begin
      S := Bal.Pending.Slot[k];
      if not Bal.Pending.Done[k] and SlotValid(S) and (Live[S].JoinTick = Bal.Pending.JoinTick[k]) and
         (Live[S].Team >= TEAM_ALPHA) and (Live[S].Team <= TEAM_DELTA) and (Bal.Slots[S].MoveKind = BK_NONE) and
         (Bal.Slots[S].WaitTeam = 0) then
        Say(S, Format('[Balance] The planned team change is off%s: you stay in %s.', [Reason, TeamTitle(Live[S].Team)]),
          CLR_HINT);
    end;
  { half a swap or an unfinished count fix leaves the numbers apart: the count fix starts again at
    once, without a new grace time }
  if MustFinish then
  begin
    Bal.CountSince := Max(1, GameTick - Cfg.BalanceLeaveGraceSeconds * TICKS_PER_SECOND);
    Bal.NoChangeNoted := False;
  end;
end;

{ The rest of a started swap goes at once: the teams are uneven until it is done. Survival waits for
  the death, and so does a player who carries a flag. }
procedure BalSendRest(E: TZSEngine);
var
  k, S: LongInt;
begin
  if not E.BalanceActive or not BalPlanStarted(E.Bal.Pending) or E.Match.Survival then
    Exit;
  for k := 0 to E.Bal.Pending.Count - 1 do
  begin
    S := E.Bal.Pending.Slot[k];
    if E.Bal.Pending.Done[k] or (E.Bal.Slots[S].MoveKind <> BK_NONE) or
       (E.Live[S].Alive and (E.Live[S].Flags and EF_A_FLAGGER <> 0)) then
      Continue;
    E.BalPendingSend(k, False);
  end;
end;

{ the chance of a team right now }
function TZSEngine.BalTeamChance(Team: LongInt): Double;
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, t: LongInt;
  P: TBalParams;
  Ch: TBalTeamValues;
begin
  BalGather(Cands, TeamNo, N, P, Ch);
  t := BalTeamIndexOf(TeamNo, N, Team);
  if t < 0 then
    Result := 0
  else
    Result := Ch[t];
end;

procedure TZSEngine.BalRemember(S: LongInt);
var
  Idx, Id, k, n: LongInt;
begin
  Idx := Identity.ProfileIndex(S);
  if not DB.Valid(Idx) or (Cfg.BalanceRejoinMemoryMinutes <= 0) then
    Exit;
  Id := DB.Profiles[Idx]^.ID;
  k := -1;
  for n := 0 to High(Bal.Memory) do
    if Bal.Memory[n].ProfileId = Id then
    begin
      k := n;
      Break;
    end;
  if k < 0 then
  begin
    k := Length(Bal.Memory);
    SetLength(Bal.Memory, k + 1);
  end;
  Bal.Memory[k].ProfileId := Id;
  Bal.Memory[k].Expires := Now + Cfg.BalanceRejoinMemoryMinutes / 1440;
  Bal.Memory[k].Team := Bal.Slots[S].LastTeam;
  Bal.Memory[k].LockTeam := Bal.Slots[S].LockTeam;
  Bal.Memory[k].LockUntil := Now + Max(0, Bal.Slots[S].LockUntil - GameTick) / TICKS_PER_SECOND / 86400;
  Bal.Memory[k].ImmuneUntil := Now + Max(0, Bal.Slots[S].ImmuneUntil - GameTick) / TICKS_PER_SECOND / 86400;
  Bal.Memory[k].Form := Bal.Slots[S].Form;
  Bal.Memory[k].FormSince := Bal.Slots[S].FormSince;
  Bal.Memory[k].MapSerial := FMapSerial;
end;

procedure TZSEngine.BalFinishMove(S, Kind: LongInt);
var
  Old, New, Idx, k, By: LongInt;
  Now1: Double;
  AllDone, Counted, Partial: Boolean;
  Change: AnsiString;
begin
  Old := Bal.Slots[S].MoveFrom;
  New := Bal.Slots[S].MoveTeam;
  By := Bal.Slots[S].MoveBy;
  Bal.Slots[S].TeamSince := GameTick;
  { a move for the balance locks the way back; a spectator or a neutral switch does not }
  Counted := (Kind in [BK_AUTO, BK_ADMIN, BK_START, BK_MIX, BK_VOLUNTEER]) and (New >= TEAM_ALPHA) and (New <= TEAM_DELTA);
  if Kind = BK_VOLUNTEER then
    Counted := Counted and Bal.Slots[S].MoveHelped;
  if Counted then
  begin
    { the mix at a map start moves about half of everybody: it locks the way back, but it is
      nobody's own move, so it gives no immunity from the balance and no Balance Moves }
    if Kind <> BK_MIX then
      Bal.Slots[S].ImmuneUntil := GameTick + Round(Cfg.BalanceImmunityMinutes * 60 * TICKS_PER_SECOND);
    if (Old >= TEAM_ALPHA) and (Old <= TEAM_DELTA) then
    begin
      Bal.Slots[S].LockTeam := Old;
      Bal.Slots[S].LockUntil := GameTick + Round(Cfg.BalanceLockMinutes * 60 * TICKS_PER_SECOND);
    end;
  end;
  Idx := Identity.StatsIndex(S);
  if DB.Valid(Idx) and Counted and (Kind <> BK_MIX) then
  begin
    if Kind = BK_VOLUNTEER then
      Inc(DB.Profiles[Idx]^.BalanceVolunteers)
    else
      Inc(DB.Profiles[Idx]^.BalanceMoves);
    DB.Touch(Idx);
  end;
  if Kind in [BK_AUTO, BK_VOLUNTEER] then
  begin
    Bal.LastMoveTick := GameTick;
    Inc(Bal.MovesThisMap);
    Bal.ChanceSince := 0;
    Bal.CountSince := 0;
  end;

  AllDone := True;
  if Bal.Pending.Active then
  begin
    for k := 0 to Bal.Pending.Count - 1 do
      if Bal.Pending.Slot[k] = S then
        Bal.Pending.Done[k] := True;
    for k := 0 to Bal.Pending.Count - 1 do
      if not Bal.Pending.Done[k] then
        AllDone := False;
    if AllDone then
      Bal.Pending.Active := False;
  end;

  { while other moves of the same change are still to come (the rest of a swap, the other half of
    a /bal swap, a mix), the chance of this moment says nothing: the last move gives it }
  Partial := not AllDone or BalMoveUnderWay(Bal);
  if not Partial and (Bal.Slots[S].MoveFav >= TEAM_ALPHA) and (Bal.Slots[S].MoveBefore > 0) then
  begin
    Now1 := BalTeamChance(Bal.Slots[S].MoveFav);
    Change := Format(' (%s %s -> %s)', [TeamTitle(Bal.Slots[S].MoveFav), PercentText(Bal.Slots[S].MoveBefore),
      PercentText(Now1)]);
  end
  else
    Change := '';
  case Kind of
    BK_AUTO:
      begin
        Say(S, Format('[Balance] You play for %s now%s. Thank you!', [TeamTitle(New), Change]), CLR_GOOD);
        if Cfg.BalanceAnnounce and AllDone then
          Broadcast(Format('[Balance] %s moved to %s%s.', [Live[S].Name, TeamTitle(New), Change]), CLR_HINT);
      end;
    BK_VOLUNTEER:
      begin
        if Counted then
        begin
          Say(S, Format('[Balance] You play for %s now%s. Thanks for helping!', [TeamTitle(New), Change]), CLR_GOOD);
          if Cfg.BalanceAnnounce then
            Broadcast(Format('[Balance] %s volunteered for %s%s.', [Live[S].Name, TeamTitle(New), Change]), CLR_HINT);
        end
        else
          Say(S, Format('[Balance] You play for %s now.', [TeamTitle(New)]), CLR_GOOD);
      end;
    BK_ADMIN:
      begin
        Say(S, Format('[Balance] An admin moved you to %s.', [TeamTitle(New)]), CLR_WARN);
        if SlotValid(By) and (By <> S) then
          Say(By, Format('[Balance] %s plays for %s now%s.', [Live[S].Name, TeamTitle(New), Change]), CLR_GOOD)
        else if By = 0 then
          WriteServer(Format('[Balance] %s plays for %s now%s.', [Live[S].Name, TeamTitle(New), Change]));
      end;
    BK_JOIN:
      Say(S, Format('[Balance] You joined %s, the team that needed a player%s.', [TeamTitle(New), Change]), CLR_GOOD);
    BK_REVIEW:
      begin
        if Bal.Slots[S].JoinNote <> '' then
          Say(S, '[Balance] ' + Bal.Slots[S].JoinNote, CLR_HINT)
        else
          Say(S, Format('[Balance] You were placed in %s, where a player was needed%s.', [TeamTitle(New), Change]), CLR_HINT);
        Bal.Slots[S].JoinNote := '';
      end;
    BK_START:
      Say(S, Format('[Balance] New map: you play for %s to even the teams%s.', [TeamTitle(New), Change]), CLR_HINT);
    BK_MIX:
      Say(S, Format('[Balance] New map, new teams: you play for %s.', [TeamTitle(New)]), CLR_HINT);
  end;
  BalNote(Format('%s moved from %s to %s (%s)%s', [Live[S].Name, TeamTitle(Old), TeamTitle(New), BalKindText(Kind),
    Change]));
  Bal.Dirty := True;
  BalSendRest(Self);
end;

procedure TZSEngine.EvMoveResult(var E: TZSEvent);
var
  S, Kind, By, k: LongInt;
  Done: Boolean;
  Why: AnsiString;
begin
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  Kind := Bal.Slots[S].MoveKind;
  By := Bal.Slots[S].MoveBy;
  Bal.Slots[S].MoveKind := BK_NONE;
  if Kind = BK_NONE then
    Exit;
  case E.I[1] of
    MOVE_DONE:
      BalFinishMove(S, Kind);
    MOVE_ALREADY:
      { the player got there without us: finish the plan, but count no move and lock nothing }
      begin
        for k := 0 to Bal.Pending.Count - 1 do
          if Bal.Pending.Slot[k] = S then
            Bal.Pending.Done[k] := True;
        if Bal.Pending.Active then
        begin
          Done := True;
          for k := 0 to Bal.Pending.Count - 1 do
            if not Bal.Pending.Done[k] then
              Done := False;
          if Done then
            Bal.Pending.Active := False;
        end;
        Bal.Dirty := True;
        BalSendRest(Self);
      end;
    MOVE_ALIVE:
      { a planned move waits in Bal.Pending; an admin's move waits here }
      if Kind = BK_ADMIN then
      begin
        Bal.Slots[S].WaitTeam := Bal.Slots[S].MoveTeam;
        Bal.Slots[S].WaitBy := By;
        if SlotValid(By) then
          Say(By, Format('[Balance] %s is alive: the change to %s follows at the next death.', [Live[S].Name,
            TeamTitle(Bal.Slots[S].MoveTeam)]), CLR_HINT)
        else if By = 0 then
          WriteServer(Format('[Balance] %s is alive: the change to %s follows at the next death.', [Live[S].Name,
            TeamTitle(Bal.Slots[S].MoveTeam)]));
      end
      { a survival round began before the move of a volunteer or a join was made }
      else if Kind = BK_VOLUNTEER then
        Say(S, '[Balance] You were alive again, so the team change did not happen: type !switch once you are dead.',
          CLR_WARN)
      else if Kind = BK_REVIEW then
        Bal.Slots[S].JoinNote := '';
    else
    begin
      if E.I[1] = MOVE_FLAGGER then
        Why := 'carries a flag'
      else
        Why := 'the server refused the team change';
      { a count fix, or a swap already under way, waits for the carrier's death instead }
      if (E.I[1] = MOVE_FLAGGER) and BalInPending(S) and BalPlanMustFinish(Bal) then
        BalNote(Format('%s was not moved: %s, the move follows at the next death', [Live[S].Name, Why]))
      else
      begin
        BalNote(Format('%s was not moved: %s', [Live[S].Name, Why]));
        if BalInPending(S) and (E.I[1] = MOVE_FLAGGER) then
          BalCancelPending(Live[S].Name + ' carries a flag')
        else if BalInPending(S) then
          BalCancelPending('the server refused to move ' + Live[S].Name);
      end;
      if Kind in [BK_VOLUNTEER, BK_JOIN] then
        Say(S, '[Balance] The team change did not work: ' + Why + '.', CLR_WARN)
      else if (Kind = BK_ADMIN) and SlotValid(By) then
        Say(By, Format('[Balance] %s was not moved: %s.', [Live[S].Name, Why]), CLR_WARN);
    end;
  end;
end;

{ still worth doing? The situation may have changed while the move waited for a death. }
function TZSEngine.BalPendingHelps: Boolean;
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, i, k, t: LongInt;
  P: TBalParams;
  Ch: TBalTeamValues;
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D0, D1: Double;
  Spread0: LongInt;
begin
  if BalPlanStarted(Bal.Pending) then
    Exit(True);
  D0 := BalGather(Cands, TeamNo, N, P, Ch);
  BalTotals(Cands, N, Pow, Cnt);
  Spread0 := BalSpread(Cnt, N);
  if Bal.Pending.CountFix then
    Exit(Spread0 > Cfg.BalanceMaxCountDiff);
  for i := 0 to High(Cands) do
    for k := 0 to Bal.Pending.Count - 1 do
      if Cands[i].Id = Bal.Pending.Slot[k] then
      begin
        t := BalTeamIndexOf(TeamNo, N, Bal.Pending.Team[k]);
        if t >= 0 then
          Cands[i].Team := t;
      end;
  D1 := BalMatchImbalance(Cands, N, P, Ch);
  Result := D1 <= D0 - Cfg.BalanceMinGain / 200;
end;

procedure TZSEngine.BalPendingSend(k: LongInt; DeadOnly: Boolean);
var
  S: LongInt;
begin
  S := Bal.Pending.Slot[k];
  BalSend(S, Bal.Pending.Team[k], BK_AUTO, DeadOnly, Bal.Pending.FavTeam, Bal.Pending.Before, Bal.Pending.After, 0);
end;

procedure TZSEngine.BalSchedule(const Move: TBalMove; const Cands: TBalCandArray; const TeamNo: TBalTeamNos;
  TeamCount: LongInt; const Ch: TBalTeamValues; CountFix: Boolean);
var
  k, S, Fav: LongInt;
  Why: AnsiString;
begin
  Fav := BalFavored(Ch, TeamCount);
  Bal.Pending.Active := True;
  Bal.Pending.CountFix := CountFix;
  Bal.Pending.Slot[0] := Cands[Move.A].Id;
  Bal.Pending.Team[0] := TeamNo[Move.ToTeam];
  Bal.Pending.Count := 1;
  if Move.Kind = BM_SWAP then
  begin
    Bal.Pending.Slot[1] := Cands[Move.B].Id;
    Bal.Pending.Team[1] := TeamNo[Cands[Move.A].Team];
    Bal.Pending.Count := 2;
  end;
  for k := 0 to Bal.Pending.Count - 1 do
  begin
    Bal.Pending.JoinTick[k] := Live[Bal.Pending.Slot[k]].JoinTick;
    Bal.Pending.Done[k] := False;
  end;
  Bal.Pending.Created := GameTick;
  if Match.Survival then
    Bal.Pending.Deadline := GameTick + 180 * TICKS_PER_SECOND
  else
    Bal.Pending.Deadline := GameTick + Cfg.BalancePendingMaxSeconds * TICKS_PER_SECOND;
  Bal.Pending.FavTeam := TeamNo[Fav];
  Bal.Pending.Before := Ch[Fav];
  Bal.Pending.After := Move.After;
  if CountFix then
    Why := 'the teams have uneven numbers'
  else
    Why := Format('%s is stronger (%s)', [TeamTitle(TeamNo[Fav]), BalChanceText(Ch, TeamNo, TeamCount)]);
  if Move.Kind = BM_SWAP then
    BalNote(Format('%s: %s and %s swap teams', [Why, Live[Bal.Pending.Slot[0]].Name, Live[Bal.Pending.Slot[1]].Name]))
  else
    BalNote(Format('%s: %s moves to %s', [Why, Live[Bal.Pending.Slot[0]].Name, TeamTitle(Bal.Pending.Team[0])]));
  { a flag carrier is never moved alive: his move always waits for the death }
  for k := 0 to Bal.Pending.Count - 1 do
  begin
    S := Bal.Pending.Slot[k];
    if not Live[S].Alive then
      BalPendingSend(k, True)
    else if Cfg.BalanceMoveOnDeath or Match.Survival or (Live[S].Flags and EF_A_FLAGGER <> 0) then
      Say(S, Format('[Balance] %s: you will play for %s after your next death.', [Why, TeamTitle(Bal.Pending.Team[k])]),
        CLR_WARN)
    else
      BalPendingSend(k, False);
  end;
end;

procedure TZSEngine.BalPendingTimers;
var
  k, S: LongInt;
  MustFinish: Boolean;
begin
  if not Bal.Pending.Active then
    Exit;
  for k := 0 to Bal.Pending.Count - 1 do
  begin
    S := Bal.Pending.Slot[k];
    if Bal.Pending.Done[k] then
      Continue;
    if not SlotValid(S) or (Live[S].JoinTick <> Bal.Pending.JoinTick[k]) or (Live[S].Team = TEAM_SPEC) then
    begin
      BalCancelPending('a player of it left the game');
      Exit;
    end;
  end;
  { a carrier may have dropped the flag, or a player respawned before a move for the dead reached
    him: the rest of a started swap goes as soon as it can }
  BalSendRest(Self);
  if GameTick < Bal.Pending.Deadline then
    Exit;
  MustFinish := BalPlanMustFinish(Bal);
  if Match.Survival then
  begin
    { a living player is never moved in survival: a count fix or a swap under way waits for the deaths }
    if not MustFinish then
      BalCancelPending('nobody died in time');
    Exit;
  end;
  if not BalPendingHelps then
  begin
    BalCancelPending('the teams changed meanwhile');
    Exit;
  end;
  { a flag carrier is never moved alive: a plan that may still be given up goes before any part of
    it is sent, so no half of a swap is left behind }
  if not MustFinish then
    for k := 0 to Bal.Pending.Count - 1 do
    begin
      S := Bal.Pending.Slot[k];
      if not Bal.Pending.Done[k] and (Bal.Slots[S].MoveKind = BK_NONE) and Live[S].Alive and
         (Live[S].Flags and EF_A_FLAGGER <> 0) then
      begin
        BalCancelPending(Live[S].Name + ' carries a flag');
        Exit;
      end;
    end;
  for k := 0 to Bal.Pending.Count - 1 do
  begin
    S := Bal.Pending.Slot[k];
    if Bal.Pending.Done[k] or (Bal.Slots[S].MoveKind <> BK_NONE) or
       (Live[S].Alive and (Live[S].Flags and EF_A_FLAGGER <> 0)) then
      Continue;
    BalPendingSend(k, False);
  end;
end;

{ ---------------- events ---------------- }

procedure TZSEngine.BalOnKill(K, V, Tick: LongInt);
var
  SK, SV, Ex, D, Skill: Double;
  Games, j, T: LongInt;
begin
  if not SlotValid(V) then
    Exit;
  { the form: every kill between humans of different teams is a small Elo duel }
  if TeamGame and (K <> V) and SlotValid(K) and Live[K].Human and Live[V].Human and
     (Live[K].Team <> Live[V].Team) then
  begin
    SK := BalBase(K, Skill, Games) + Bal.Slots[K].Form;
    SV := BalBase(V, Skill, Games) + Bal.Slots[V].Form;
    Ex := 1 / (1 + Power(10, EnsureRange((SV - SK) / 400, -8.0, 8.0)));
    D := Cfg.BalanceFormStep * (1 - Ex);
    Bal.Slots[K].Form := Bal.Slots[K].Form + D;
    Bal.Slots[V].Form := Bal.Slots[V].Form - D;
  end;
  { a move that waited for this death happens now; survival kills a player who changed the team,
    that death belongs to the move itself }
  if Live[V].TeamSinceTick = Tick then
    Exit;
  if (Bal.Slots[V].WaitTeam > 0) and (Bal.Slots[V].MoveKind = BK_NONE) then
  begin
    T := Bal.Slots[V].WaitTeam;
    Bal.Slots[V].WaitTeam := 0;
    if Live[V].Team <> T then
      BalSend(V, T, BK_ADMIN, True, Bal.Slots[V].MoveFav, Bal.Slots[V].MoveBefore, Bal.Slots[V].MoveAfter,
        Bal.Slots[V].WaitBy);
  end;
  if not Bal.Pending.Active then
    Exit;
  for j := 0 to Bal.Pending.Count - 1 do
    if (Bal.Pending.Slot[j] = V) and not Bal.Pending.Done[j] and (Bal.Slots[V].MoveKind = BK_NONE) then
    begin
      if not BalanceActive or not BalPendingHelps then
      begin
        BalCancelPending('the teams changed meanwhile');
        Exit;
      end;
      BalPendingSend(j, True);
    end;
end;

procedure TZSEngine.BalOnFlag(S, Kind: LongInt);
begin
  if not SlotValid(S) or not Live[S].Human then
    Exit;
  case Kind of
    FLAG_SCORE: Bal.Slots[S].Form := Bal.Slots[S].Form + 1.5 * Cfg.BalanceFormStep;
    FLAG_RETURN: Bal.Slots[S].Form := Bal.Slots[S].Form + 0.5 * Cfg.BalanceFormStep;
    FLAG_GRAB:
      { a count fix, or a swap already under way, waits for the carrier's death instead }
      if BalInPending(S) and not BalPlanMustFinish(Bal) then
        BalCancelPending(Live[S].Name + ' took a flag');
  end;
end;

procedure TZSEngine.BalOnJoin(S: LongInt);
var
  k, n: LongInt;
begin
  BalResetSlot(S);
  Bal.Slots[S].ReviewUntil := GameTick + Cfg.BalanceJoinReviewSeconds * TICKS_PER_SECOND;
  if (Live[S].Team >= TEAM_ALPHA) and (Live[S].Team <= TEAM_DELTA) then
    Bal.Slots[S].LastTeam := Live[S].Team;
  { the game thread placed this join: the note waits here until the player exists }
  n := Length(Bal.Expected);
  for k := 0 to n - 1 do
    if ((Bal.Expected[k].Slot = S) or (Bal.Expected[k].Slot = 0)) and (Bal.Expected[k].Team = Live[S].Team) then
    begin
      if Bal.Expected[k].Note and Live[S].Human then
        Bal.Slots[S].JoinNote := Format('%s needed a player, so you play for %s.',
          [TeamTitle(Live[S].Team), TeamTitle(Live[S].Team)]);
      Bal.Expected[k] := Bal.Expected[n - 1];
      SetLength(Bal.Expected, n - 1);
      Break;
    end;
  if Bal.Slots[S].JoinNote <> '' then
  begin
    Say(S, '[Balance] ' + Bal.Slots[S].JoinNote, CLR_HINT);
    Bal.Slots[S].JoinNote := '';
  end;
  Bal.Dirty := True;
end;

procedure TZSEngine.BalOnLeave(S: LongInt);
begin
  if not SlotValid(S) then
    Exit;
  if Live[S].Human then
    BalRemember(S);
  if BalInPending(S) then
    BalCancelPending(Live[S].Name + ' left');
  BalResetSlot(S);
  Bal.Dirty := True;
end;

procedure TZSEngine.BalOnTeam(S, NewTeam: LongInt);
var
  k, n: LongInt;
begin
  Bal.Slots[S].TeamSince := GameTick;
  Bal.Slots[S].WaitTeam := 0;
  if (NewTeam >= TEAM_ALPHA) and (NewTeam <= TEAM_DELTA) then
    Bal.Slots[S].LastTeam := NewTeam;
  n := Length(Bal.Expected);
  for k := 0 to n - 1 do
    if (Bal.Expected[k].Slot = S) and (Bal.Expected[k].Team = NewTeam) then
    begin
      Bal.Expected[k] := Bal.Expected[n - 1];
      SetLength(Bal.Expected, n - 1);
      Break;
    end;
  if (NewTeam = TEAM_SPEC) and BalInPending(S) then
    BalCancelPending(Live[S].Name + ' went to the spectators');
  Bal.Dirty := True;
end;

procedure TZSEngine.BalTellRedirect(S, Asked, Given: LongInt);
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N: LongInt;
  P: TBalParams;
  Ch: TBalTeamValues;
begin
  if not SlotValid(S) or not Live[S].Human then
    Exit;
  BalGather(Cands, TeamNo, N, P, Ch);
  if (Bal.Slots[S].LockTeam = Asked) and (Bal.Slots[S].LockUntil > GameTick) then
    Say(S, Format('[Balance] You were moved from %s a moment ago: you can go back in %s.',
      [TeamTitle(Asked), FormatDurationShort((Bal.Slots[S].LockUntil - GameTick) div TICKS_PER_SECOND + 1)]), CLR_WARN)
  else if Given < TEAM_ALPHA then
    Say(S, Format('[Balance] %s would make the teams uneven, you stay (%s). !bal shows the teams.',
      [TeamTitle(Asked), BalChanceText(Ch, TeamNo, N)]), CLR_WARN)
  else
    Say(S, Format('[Balance] %s needs a player, so you play for %s (%s).',
      [TeamTitle(Given), TeamTitle(Given), BalChanceText(Ch, TeamNo, N)]), CLR_HINT);
end;

procedure TZSEngine.EvTeamRequest(var E: TZSEvent);
var
  n, S, Asked, Given: LongInt;
begin
  Bal.SeenId := Max(Bal.SeenId, E.I[0]);
  S := E.Slot;
  Asked := E.I[1];
  Given := E.I[2];
  if (Given >= TEAM_ALPHA) and (Given <= TEAM_DELTA) and not (SlotValid(S) and (Live[S].Team = Given)) then
  begin
    n := Length(Bal.Expected);
    SetLength(Bal.Expected, n + 1);
    Bal.Expected[n].Id := E.I[0];
    Bal.Expected[n].Slot := S;
    Bal.Expected[n].Team := Given;
    Bal.Expected[n].Power := E.F[0];
    Bal.Expected[n].Tick := GameTick;
    Bal.Expected[n].Requested := Asked;
    Bal.Expected[n].Note := Given <> Asked;
  end;
  { a player who is already on the server hears about it now, a new one once the join is done }
  if (Given <> Asked) and SlotValid(S) and (E.I[3] >= 0) and (E.I[3] <= TEAM_SPEC) then
    BalTellRedirect(S, Asked, Given);
  Bal.Dirty := True;
end;

procedure TZSEngine.BalExpire;
var
  k: LongInt;
begin
  k := 0;
  while k < Length(Bal.Expected) do
    if GameTick - Bal.Expected[k].Tick > BAL_EXPECT_TICKS then
    begin
      Bal.Expected[k] := Bal.Expected[High(Bal.Expected)];
      SetLength(Bal.Expected, Length(Bal.Expected) - 1);
      Bal.Dirty := True;
    end
    else
      Inc(k);
  k := 0;
  while k < Length(Bal.Memory) do
    if Bal.Memory[k].Expires < Now then
    begin
      Bal.Memory[k] := Bal.Memory[High(Bal.Memory)];
      SetLength(Bal.Memory, Length(Bal.Memory) - 1);
    end
    else
      Inc(k);
  for k := 1 to MAX_PLAYERS do
    if (Bal.Slots[k].MoveKind <> BK_NONE) and (GameTick - Bal.Slots[k].MoveSent > BAL_MOVE_TIMEOUT) then
      Bal.Slots[k].MoveKind := BK_NONE;
end;

{ ---------------- joins placed again ---------------- }

procedure TZSEngine.BalReviewJoins;
var
  S, Idx, Id, k, Mem, T, Me, Best, i: LongInt;
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N: LongInt;
  P: TBalParams;
  Ch: TBalTeamValues;
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D0, D1, BestD: Double;
  Spread0: LongInt;
begin
  for S := 1 to MAX_PLAYERS do
  begin
    if not Live[S].Active or not Live[S].Human or Bal.Slots[S].Reviewed then
      Continue;
    { a slow Steam answer must not cost the player their locks: wait for the account }
    if Identity.IsPending(S) then
      Continue;
    { back within RejoinMemoryMinutes: the balance picks up where it left off as soon as the account is
      known - however long Steam took, and whether the player is in a team yet or not }
    if not Bal.Slots[S].Recalled then
    begin
      Bal.Slots[S].Recalled := True;
      Idx := Identity.ProfileIndex(S);
      Mem := -1;
      if DB.Valid(Idx) then
      begin
        Id := DB.Profiles[Idx]^.ID;
        for k := 0 to High(Bal.Memory) do
          if (Bal.Memory[k].ProfileId = Id) and (Bal.Memory[k].Expires >= Now) then
            Mem := k;
      end;
      if Mem >= 0 then
      begin
        if Bal.Memory[Mem].MapSerial = FMapSerial then
        begin
          Bal.Slots[S].Form := Bal.Memory[Mem].Form;
          Bal.Slots[S].FormSince := Bal.Memory[Mem].FormSince;
        end;
        if Bal.Memory[Mem].ImmuneUntil > Now then
          Bal.Slots[S].ImmuneUntil := GameTick + Round((Bal.Memory[Mem].ImmuneUntil - Now) * 86400 * TICKS_PER_SECOND);
        if Bal.Memory[Mem].LockUntil > Now then
        begin
          Bal.Slots[S].LockTeam := Bal.Memory[Mem].LockTeam;
          Bal.Slots[S].LockUntil := GameTick + Round((Bal.Memory[Mem].LockUntil - Now) * 86400 * TICKS_PER_SECOND);
        end;
        Bal.Slots[S].ReturnTeam := Bal.Memory[Mem].Team;
        Bal.Dirty := True;
      end;
    end;
    T := Live[S].Team;
    if (T < TEAM_ALPHA) or (T > TEAM_DELTA) then
    begin
      { not in a team yet: the join is looked at when the player enters one within JoinReviewSeconds;
        a lock holds by itself, the placing of joins keeps to it }
      if Bal.Slots[S].ReviewUntil < GameTick then
        Bal.Slots[S].Reviewed := True;
      Continue;
    end;
    Bal.Slots[S].Reviewed := True;
    { back in the team the balance moved the player away from: to the team played for before }
    if BalanceActive and (Bal.Slots[S].LockUntil > GameTick) and (Bal.Slots[S].LockTeam = T) and
       (Bal.Slots[S].ReturnTeam >= TEAM_ALPHA) and (Bal.Slots[S].ReturnTeam <> T) and
       (Live[S].Flags and EF_A_FLAGGER = 0) then
    begin
      Bal.Slots[S].JoinNote := Format('You played for %s before you left, so you play for %s again.',
        [TeamTitle(Bal.Slots[S].ReturnTeam), TeamTitle(Bal.Slots[S].ReturnTeam)]);
      { a survival round may have begun since the join: a living player is not moved }
      BalSend(S, Bal.Slots[S].ReturnTeam, BK_REVIEW, Match.Survival, 0, 0, 0, 0);
      Continue;
    end;
    { the join itself is placed again only within JoinReviewSeconds }
    if (Bal.Slots[S].ReviewUntil < GameTick) or not BalanceActive or not Cfg.BalanceAssignJoins then
      Continue;
    { the join was placed without knowing the player; now the account is known }
    if Live[S].MatchKills + Live[S].MatchDeaths + Live[S].MatchCaps > 0 then
      Continue;
    { a move on its way changes the teams in a moment: judged now, two joins of the same second
      would both be sent to the smaller team. This one is looked at again a second later. }
    if BalMoveUnderWay(Bal) then
    begin
      Bal.Slots[S].Reviewed := False;
      Continue;
    end;
    D0 := BalGather(Cands, TeamNo, N, P, Ch);
    if BalHumans(Cands) < 2 then
      Continue;
    Me := -1;
    for i := 0 to High(Cands) do
      if Cands[i].Id = S then
        Me := i;
    if Me < 0 then
      Continue;
    BalTotals(Cands, N, Pow, Cnt);
    Spread0 := BalSpread(Cnt, N);
    Best := -1;
    BestD := D0;
    for k := 0 to N - 1 do
    begin
      if k = Cands[Me].Team then
        Continue;
      Cands[Me].Team := k;
      BalTotals(Cands, N, Pow, Cnt);
      D1 := BalMatchImbalance(Cands, N, P, Ch);
      if (BalSpread(Cnt, N) <= Max(Cfg.BalanceMaxCountDiff, Spread0)) and (D1 < BestD) then
      begin
        BestD := D1;
        Best := k;
      end;
      Cands[Me].Team := BalTeamIndexOf(TeamNo, N, T);
    end;
    if (Best >= 0) and (BestD < D0 - Cfg.BalanceJoinTolerance / 100) and (Live[S].Flags and EF_A_FLAGGER = 0) then
    begin
      BalGather(Cands, TeamNo, N, P, Ch);
      Bal.Slots[S].JoinNote := '';
      BalSend(S, TeamNo[Best], BK_REVIEW, Match.Survival, TeamNo[BalFavored(Ch, N)], Ch[BalFavored(Ch, N)], BestD, 0);
    end;
  end;
end;

{ ---------------- corrections ---------------- }

{ a request for a volunteer goes from the biggest (or strongest) team to the smallest (or weakest) }
procedure BalRequestTeams(const Ch: TBalTeamValues; const Cnt: TBalTeamCounts; TeamCount: LongInt; CountFix: Boolean;
  out From, Into: LongInt);
var
  t: LongInt;
begin
  From := 0;
  Into := 0;
  for t := 1 to TeamCount - 1 do
    if CountFix then
    begin
      if Cnt[t] > Cnt[From] then
        From := t;
      if Cnt[t] < Cnt[Into] then
        Into := t;
    end
    else
    begin
      if Ch[t] > Ch[From] then
        From := t;
      if Ch[t] < Ch[Into] then
        Into := t;
    end;
end;

{ A switch helps when the chances even out by half of MinGain, when they get within Target from
  above it, or when the numbers get closer without making the chances worse than allowed. }
function TZSEngine.BalSwitchHelps(D0, D1: Double; Spread0, Spread1: LongInt): Boolean;
begin
  Result := BalSwitchHelpful(D0, D1, Spread0, Spread1, (Cfg.BalanceTarget - 50) / 100, Cfg.BalanceMinGain / 100);
end;

{ Could one human of team From even the match by going to Into? Three against two equal players,
  for example, cannot be helped by a volunteer: the switch only turns the sides around. }
function TZSEngine.BalVolunteerCanHelp(var Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  const TeamNo: TBalTeamNos; From, Into: LongInt; D0: Double; Spread0: LongInt): Boolean;
var
  i, S, Spread1: LongInt;
  Ch, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D1: Double;
begin
  Result := False;
  for i := 0 to High(Cands) do
  begin
    S := Cands[i].Id;
    { in survival only the dead are asked (a switch would cost a living player his life) }
    if (Cands[i].Team <> From) or not Live[S].Human or (Match.Survival and Live[S].Alive) then
      Continue;
    if (Bal.Slots[S].LockTeam = TeamNo[Into]) and (Bal.Slots[S].LockUntil > GameTick) then
      Continue;
    Cands[i].Team := Into;
    BalTotals(Cands, TeamCount, Pow, Cnt);
    Spread1 := BalSpread(Cnt, TeamCount);
    D1 := BalMatchImbalance(Cands, TeamCount, P, Ch);
    Cands[i].Team := From;
    if ((Spread1 <= Cfg.BalanceMaxCountDiff) or (Spread1 < Spread0)) and BalSwitchHelps(D0, D1, Spread0, Spread1) then
      Exit(True);
  end;
end;

procedure TZSEngine.BalAskVolunteers(const Ch: TBalTeamValues; const Cnt: TBalTeamCounts; const TeamNo: TBalTeamNos;
  TeamCount: LongInt; CountFix: Boolean);
var
  From, Into, S: LongInt;
  Text: AnsiString;
begin
  BalRequestTeams(Ch, Cnt, TeamCount, CountFix, From, Into);
  Bal.RequestDone := True;
  Bal.RequestFrom := TeamNo[From];
  Bal.RequestTo := TeamNo[Into];
  Bal.RequestUntil := GameTick + Cfg.BalanceVolunteerSeconds * TICKS_PER_SECOND;
  if CountFix then
    Text := Format('[Balance] %s has %d players, %s %d. Type !switch within %d s to play for %s.',
      [TeamTitle(TeamNo[From]), Cnt[From], TeamTitle(TeamNo[Into]), Cnt[Into], Cfg.BalanceVolunteerSeconds,
       TeamTitle(TeamNo[Into])])
  else
    Text := Format('[Balance] %s is stronger (%s). Type !switch within %d s to play for %s.',
      [TeamTitle(TeamNo[From]), BalChanceText(Ch, TeamNo, TeamCount), Cfg.BalanceVolunteerSeconds, TeamTitle(TeamNo[Into])]);
  { in survival a living player could only switch by dying: the dead are asked }
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human and (Live[S].Team = Bal.RequestFrom) and
       not (Match.Survival and Live[S].Alive) then
      Say(S, Text, CLR_HINT);
  BalNote(Format('asked %s for a volunteer', [TeamTitle(TeamNo[From])]));
end;

{ Only flag carriers could even the numbers: the one whose move helps most goes at his next death,
  which a count fix waits for. }
function BalCarrierMove(E: TZSEngine; const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  IgnorePlan: Boolean; out Move: TBalMove): Boolean;
var
  Work: TBalCandArray;
  i: LongInt;
  Soft: Double;
begin
  Work := Copy(Cands);
  for i := 0 to High(Work) do
    Work[i].Movable := BalProtection(E, Work[i].Id, IgnorePlan, Soft) = 'carries a flag';
  Result := BalBestChange(Work, TeamCount, P, E.Cfg.BalanceMaxCountDiff, 0, 0, True, False, Move);
end;

{ who keeps the balance from a change: the protected players of the biggest team (CountFix) or of
  the stronger one, each with the reason }
function BalProtectedText(E: TZSEngine; const Cands: TBalCandArray; TeamCount: LongInt; const Ch: TBalTeamValues;
  CountFix, IgnorePlan: Boolean): AnsiString;
var
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  i, t, Hi, Fav: LongInt;
  Why: AnsiString;
  Soft: Double;
begin
  Result := '';
  BalTotals(Cands, TeamCount, Pow, Cnt);
  Hi := 0;
  for t := 0 to TeamCount - 1 do
    Hi := Max(Hi, Cnt[t]);
  Fav := BalFavored(Ch, TeamCount);
  for i := 0 to High(Cands) do
  begin
    t := Cands[i].Team;
    if (t < 0) or (t >= TeamCount) or (CountFix and (Cnt[t] <> Hi)) or (not CountFix and (t <> Fav)) then
      Continue;
    Why := BalProtection(E, Cands[i].Id, IgnorePlan, Soft);
    if Why = '' then
      Continue;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Format('%s (%s)', [E.Live[Cands[i].Id].Name, Why]);
  end;
  if Result = '' then
    Result := 'nobody';
end;

procedure TZSEngine.BalCheck;
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, Spread, From, Into, S: LongInt;
  P: TBalParams;
  Ch, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D, ThresholdD, TargetD, GainD: Double;
  CountFix, ChanceFix, Warmup, Found: Boolean;
  Move: TBalMove;
  Why: AnsiString;
begin
  Bal.LastCheckTick := GameTick;
  D := BalGather(Cands, TeamNo, N, P, Ch);
  if BalHumans(Cands) < Cfg.BalanceMinPlayers then
  begin
    Bal.ChanceSince := 0;
    Bal.CountSince := 0;
    Exit;
  end;
  BalTotals(Cands, N, Pow, Cnt);
  Spread := BalSpread(Cnt, N);
  ThresholdD := (Cfg.BalanceThreshold - 50) / 100;
  TargetD := (Cfg.BalanceTarget - 50) / 100;
  GainD := Cfg.BalanceMinGain / 100;
  if Spread > Cfg.BalanceMaxCountDiff then
  begin
    if Bal.CountSince = 0 then
    begin
      Bal.CountSince := GameTick;
      { new uneven numbers get their own call for a volunteer, even when the chances had one }
      Bal.RequestDone := False;
    end;
  end
  else
    Bal.CountSince := 0;
  { Method = map knows nothing about the players at the start of a map }
  Warmup := SameText(Trim(Cfg.BalanceMethod), 'map') and
    (GameTick - Match.StartTick < Round(Cfg.BalanceMapWarmupMinutes * 60 * TICKS_PER_SECOND));
  if (D > ThresholdD) and not Warmup then
  begin
    if Bal.ChanceSince = 0 then
      Bal.ChanceSince := GameTick;
  end
  else if D <= TargetD then
  begin
    Bal.ChanceSince := 0;
    if Spread <= Cfg.BalanceMaxCountDiff then
    begin
      Bal.RequestDone := False;
      Bal.NoChangeNoted := False;
    end;
  end;
  CountFix := (Bal.CountSince > 0) and (GameTick - Bal.CountSince >= Cfg.BalanceLeaveGraceSeconds * TICKS_PER_SECOND);
  ChanceFix := (Bal.ChanceSince > 0) and (GameTick - Bal.ChanceSince >= Cfg.BalanceSustainSeconds * TICKS_PER_SECOND);
  if not (CountFix or ChanceFix) then
    Exit;
  if Bal.Pending.Active or (Bal.RequestUntil > GameTick) then
    Exit;
  { a move on its way (an admin's, a volunteer's) changes the teams in a moment: the next check sees
    the teams it leaves }
  for S := 1 to MAX_PLAYERS do
    if Bal.Slots[S].MoveKind <> BK_NONE then
      Exit;
  if not BalMayMove(CountFix, Why) then
    Exit;
  if Cfg.BalanceVolunteers and not Bal.RequestDone then
  begin
    BalRequestTeams(Ch, Cnt, N, CountFix, From, Into);
    if BalVolunteerCanHelp(Cands, N, P, TeamNo, From, Into, D, Spread) then
    begin
      BalAskVolunteers(Ch, Cnt, TeamNo, N, CountFix);
      Exit;
    end;
    { nobody could do it alone: the balance chooses at once }
    Bal.RequestDone := True;
  end;
  Found := BalBestChange(Cands, N, P, Cfg.BalanceMaxCountDiff, TargetD, GainD, CountFix, not CountFix, Move);
  { uneven numbers are always fixed: a protection that is no hard rule gives way when nobody free can
    go, and when only a flag carrier can, he goes at his next death }
  if not Found and CountFix then
    Found := BalBestCountFix(Cands, N, P, Cfg.BalanceMaxCountDiff, Move);
  if not Found and CountFix then
    Found := BalCarrierMove(Self, Cands, N, P, False, Move);
  if not Found then
  begin
    if not Bal.NoChangeNoted then
    begin
      Bal.NoChangeNoted := True;
      if CountFix then
        BalNote(Format('no fair change for %s, protected: %s', [BalChanceText(Ch, TeamNo, N),
          BalProtectedText(Self, Cands, N, Ch, True, False)]))
      else
        BalNote(Format('no fair change for %s', [BalChanceText(Ch, TeamNo, N)]));
    end;
    Exit;
  end;
  BalSchedule(Move, Cands, TeamNo, N, Ch, CountFix);
end;

procedure TZSEngine.BalPredictionSample;
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N: LongInt;
  P: TBalParams;
  Ch: TBalTeamValues;
begin
  if GameTick - Bal.PredTick < BAL_SAMPLE_TICKS then
    Exit;
  Bal.PredTick := GameTick;
  BalGather(Cands, TeamNo, N, P, Ch);
  if (N <> 2) or (BalHumans(Cands) < Cfg.BalanceMinPlayers) then
    Exit;
  Bal.PredSum := Bal.PredSum + Ch[0];
  Inc(Bal.PredCount);
end;

procedure TZSEngine.BalanceSecond;
begin
  BalExpire;
  if not Bal.RefDone or (GameTick - Bal.RefTick >= BAL_REFERENCE_TICKS) then
    BalRefreshReference;
  if not BalanceActive then
  begin
    if Bal.Pending.Active then
      BalCancelPending('the balance is off');
    Bal.ChanceSince := 0;
    Bal.CountSince := 0;
    Bal.RequestUntil := 0;
    BalRefreshSnapshot;
    Exit;
  end;
  BalPredictionSample;
  BalReviewJoins;
  BalPendingTimers;
  if (Bal.RequestUntil > 0) and (GameTick >= Bal.RequestUntil) then
  begin
    { nobody volunteered in time: the next check chooses }
    Bal.RequestUntil := 0;
    Bal.LastCheckTick := BAL_NEVER;
  end;
  if (Bal.MapStartTick > 0) and (GameTick >= Bal.MapStartTick) then
    BalMapStartFix;
  if GameTick - Bal.LastCheckTick >= Cfg.BalanceCheckSeconds * TICKS_PER_SECOND then
    BalCheck;
  BalRefreshSnapshot;
end;

{ ---------------- map start ---------------- }

procedure TZSEngine.BalMapStart;
var
  S: LongInt;
begin
  { A move on its way stays: main.pas answers it on the new map, and the answer still locks the way
    back and counts the move (BalExpire forgets one that is never answered). So does an admin's move
    that waits for the player's death. }
  for S := 1 to MAX_PLAYERS do
  begin
    Bal.Slots[S].Form := 0;
    Bal.Slots[S].FormSince := GameTick;
  end;
  { a swap with one half done is finished on the new map, where its teams would otherwise stay
    uneven: the rest goes at once (in survival at the next death); any other plan is dropped, and
    the players who waited for it hear so }
  if not BalPlanStarted(Bal.Pending) then
    BalCancelPending('a new map started');
  Bal.Expected := nil;
  Bal.RequestUntil := 0;
  Bal.RequestDone := False;
  Bal.ChanceSince := 0;
  Bal.CountSince := 0;
  Bal.MovesThisMap := 0;
  Bal.NoChangeNoted := False;
  Bal.PredSum := 0;
  Bal.PredCount := 0;
  Bal.PredTick := GameTick;
  Bal.RefDone := False;
  Bal.MapStartTick := 0;
  { survival would kill every player the start moves }
  if Cfg.BalanceEnabled and TeamGame and not Match.Survival and not SameText(Trim(Cfg.BalanceMapStart), 'keep') then
    Bal.MapStartTick := GameTick + Max(1, Cfg.BalanceMapStartSeconds) * TICKS_PER_SECOND;
  Bal.Dirty := True;
end;

{ Moves every changed player at once. Kind BK_START or BK_ADMIN; returns how many were moved. }
function TZSEngine.BalApplyTeams(const Cands: TBalCandArray; const NewTeams: array of LongInt; const TeamNo: TBalTeamNos;
  TeamCount: LongInt; const ChBefore: TBalTeamValues; Kind, By: LongInt): LongInt;
var
  i, Fav: LongInt;
  Work: TBalCandArray;
  P: TBalParams;
  ChAfter: TBalTeamValues;
  DAfter: Double;
begin
  Result := 0;
  Work := Copy(Cands);
  for i := 0 to High(Work) do
    Work[i].Team := NewTeams[i];
  P := BalParamsFor(TeamCount);
  DAfter := BalMatchImbalance(Work, TeamCount, P, ChAfter);
  Fav := BalFavored(ChBefore, TeamCount);
  for i := 0 to High(Cands) do
    if (NewTeams[i] <> Cands[i].Team) and Live[Cands[i].Id].Human then
    begin
      BalSend(Cands[i].Id, TeamNo[NewTeams[i]], Kind, Match.Survival, TeamNo[Fav], ChBefore[Fav], DAfter, By);
      Inc(Result);
    end;
end;

procedure TZSEngine.BalMapStartFix;
var
  Cands, Work: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, i, Step, Spread, Moved: LongInt;
  P: TBalParams;
  Ch, ChAfter, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D, TargetD: Double;
  NewTeams, Alt: array of LongInt;
  Move: TBalMove;
  Tmp: LongInt;
  Mix, Found: Boolean;
  Seed: LongWord;
begin
  Bal.MapStartTick := 0;
  if not BalanceActive then
    Exit;
  { the rest of a swap from the last map, or a move on its way (a join placed again), changes the
    teams in a moment: the start looks at the teams it leaves, a second later - within the first
    half minute of the map; after that the regular checks see to the teams. Without the wait four
    against two became two against four: the join review and the start moved a player each. }
  if Bal.Pending.Active or BalMoveUnderWay(Bal) then
  begin
    if GameTick - Match.StartTick < 30 * TICKS_PER_SECOND then
      Bal.MapStartTick := GameTick + TICKS_PER_SECOND;
    Exit;
  end;
  D := BalGather(Cands, TeamNo, N, P, Ch);
  if BalHumans(Cands) < Cfg.BalanceMinPlayers then
    Exit;
  BalTotals(Cands, N, Pow, Cnt);
  Spread := BalSpread(Cnt, N);
  TargetD := (Cfg.BalanceTarget - 50) / 100;
  Mix := SameText(Trim(Cfg.BalanceMapStart), 'mix');
  { fix and shuffle leave even teams alone; mix gives every map new teams }
  if not Mix and (D <= TargetD) and (Spread <= Cfg.BalanceMaxCountDiff) then
    Exit;
  SetLength(NewTeams, Length(Cands));
  for i := 0 to High(Cands) do
    NewTeams[i] := Cands[i].Team;
  if Mix then
  begin
    { a new map starts fresh: every human may change team, except the excluded ones and a player
      whose last move is still on its way; a move that waited for a death is replaced }
    for i := 0 to High(Cands) do
    begin
      Bal.Slots[Cands[i].Id].WaitTeam := 0;
      Cands[i].Movable := Live[Cands[i].Id].Human and not Bal.Slots[Cands[i].Id].Excluded and
        not BalExcludedAccount(Cands[i].Id) and (Bal.Slots[Cands[i].Id].MoveKind = BK_NONE);
    end;
    Seed := LongWord(MonoMs and $FFFFFFFF) xor LongWord((Int64(GameTick) * Int64(2654435761)) and $FFFFFFFF);
    BalMixTeams(Cands, N, P, Cfg.BalanceMaxCountDiff, BAL_MIX_TRIES, TargetD, Seed, NewTeams);
    Moved := BalApplyTeams(Cands, NewTeams, TeamNo, N, Ch, BK_MIX, 0);
    Work := Copy(Cands);
    for i := 0 to High(Work) do
      Work[i].Team := NewTeams[i];
    BalMatchImbalance(Work, N, P, ChAfter);
    BalNote(Format('map start mix: %d players change team (%s before, %s after)', [Moved,
      BalChanceText(Ch, TeamNo, N), BalChanceText(ChAfter, TeamNo, N)]));
    if Cfg.BalanceAnnounce and (Moved > 0) then
      Broadcast(Format('[Balance] New map, new teams: %d player(s) change team (%s).',
        [Moved, BalChanceText(ChAfter, TeamNo, N)]), CLR_HINT);
    Exit;
  end;
  if SameText(Trim(Cfg.BalanceMapStart), 'shuffle') then
  begin
    { the best split with a price on every change, from the current line-up and from a fresh draft }
    SetLength(Alt, Length(Cands));
    for i := 0 to High(Cands) do
      Alt[i] := Cands[i].Team;
    BalRearrange(Cands, N, P, Cfg.BalanceMaxCountDiff, 0.02, False, NewTeams);
    BalRearrange(Cands, N, P, Cfg.BalanceMaxCountDiff, 0.02, True, Alt);
    Work := Copy(Cands);
    for i := 0 to High(Work) do
      Work[i].Team := Alt[i];
    Moved := 0;
    for i := 0 to High(Work) do
      if Alt[i] <> Cands[i].Team then
        Inc(Moved);
    D := BalMatchImbalance(Work, N, P, ChAfter) + 0.02 * Moved;
    for i := 0 to High(Work) do
      Work[i].Team := NewTeams[i];
    Moved := 0;
    for i := 0 to High(Work) do
      if NewTeams[i] <> Cands[i].Team then
        Inc(Moved);
    if D < BalMatchImbalance(Work, N, P, ChAfter) + 0.02 * Moved then
      for i := 0 to High(Alt) do
        NewTeams[i] := Alt[i];
  end
  else
  begin
    { the fewest changes that bring the chances to the target; uneven numbers are fixed even when
      a protection that is no hard rule has to give way }
    Work := Copy(Cands);
    for Step := 1 to 4 do
    begin
      BalTotals(Work, N, Pow, Cnt);
      Spread := BalSpread(Cnt, N);
      Found := BalBestChange(Work, N, P, Cfg.BalanceMaxCountDiff, TargetD, 0.02,
        Spread > Cfg.BalanceMaxCountDiff, Spread <= Cfg.BalanceMaxCountDiff, Move);
      if not Found and (Spread > Cfg.BalanceMaxCountDiff) then
        Found := BalBestCountFix(Work, N, P, Cfg.BalanceMaxCountDiff, Move);
      if not Found then
        Break;
      Tmp := Work[Move.A].Team;
      Work[Move.A].Team := Move.ToTeam;
      Work[Move.A].Movable := False;
      Work[Move.A].Soft := -1;
      if Move.Kind = BM_SWAP then
      begin
        Work[Move.B].Team := Tmp;
        Work[Move.B].Movable := False;
        Work[Move.B].Soft := -1;
      end;
      BalTotals(Work, N, Pow, Cnt);
      if (Move.After <= TargetD) and (BalSpread(Cnt, N) <= Cfg.BalanceMaxCountDiff) then
        Break;
    end;
    for i := 0 to High(Work) do
      NewTeams[i] := Work[i].Team;
  end;
  Moved := BalApplyTeams(Cands, NewTeams, TeamNo, N, Ch, BK_START, 0);
  if Moved > 0 then
  begin
    BalNote(Format('map start: %d players change team (%s)', [Moved, BalChanceText(Ch, TeamNo, N)]));
    if Cfg.BalanceAnnounce then
      Broadcast(Format('[Balance] New map: %d player(s) change team to even the match (%s before).',
        [Moved, BalChanceText(Ch, TeamNo, N)]), CLR_HINT);
  end;
end;

{ ---------------- player commands ---------------- }

procedure TZSEngine.BalSwitch(S: LongInt);
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, Me, k, Best, Spread0, BestSpread, Fav: LongInt;
  P: TBalParams;
  Ch, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D0, BestD, TargetD: Double;
  Requested, Helped: Boolean;
  Allowed: array[0..BAL_MAX_TEAMS - 1] of Boolean;
begin
  if not TeamGame then
  begin
    Say(S, '[Balance] This game mode has no teams.', CLR_WARN);
    Exit;
  end;
  if not Cfg.BalanceEnabled or Bal.Paused then
  begin
    Say(S, '[Balance] The team balance is off: change the team from the menu.', CLR_WARN);
    Exit;
  end;
  if (Live[S].Team < TEAM_ALPHA) or (Live[S].Team > TEAM_DELTA) then
  begin
    Say(S, '[Balance] You are not in a team. !join puts you where a player is needed.', CLR_WARN);
    Exit;
  end;
  if Live[S].Alive and (Live[S].Flags and EF_A_FLAGGER <> 0) then
  begin
    Say(S, '[Balance] Drop the flag first.', CLR_WARN);
    Exit;
  end;
  if BalInPending(S) or (Bal.Slots[S].MoveKind <> BK_NONE) or (Bal.Slots[S].WaitTeam > 0) then
  begin
    Say(S, '[Balance] You are being moved already.', CLR_WARN);
    Exit;
  end;
  { survival kills a player who changes team, and the team would lose a living player in the
    middle of the round: the switch is made while dead, like every move of the balance there }
  if Match.Survival and Live[S].Alive then
  begin
    Say(S, '[Balance] In survival a team change costs your life: type !switch again once you are dead.', CLR_WARN);
    Exit;
  end;
  D0 := BalGather(Cands, TeamNo, N, P, Ch);
  Me := -1;
  for k := 0 to High(Cands) do
    if Cands[k].Id = S then
      Me := k;
  if Me < 0 then
    Exit;
  Fav := BalFavored(Ch, N);
  BalTotals(Cands, N, Pow, Cnt);
  Spread0 := BalSpread(Cnt, N);
  TargetD := (Cfg.BalanceTarget - 50) / 100;
  Requested := (Bal.RequestUntil > GameTick) and (Live[S].Team = Bal.RequestFrom);
  { never back to a locked team, and only to the team asked for while a volunteer is asked for }
  for k := 0 to BAL_MAX_TEAMS - 1 do
    Allowed[k] := (k < N) and not (Requested and (TeamNo[k] <> Bal.RequestTo)) and
      not ((Bal.Slots[S].LockTeam = TeamNo[k]) and (Bal.Slots[S].LockUntil > GameTick));
  Best := BalBestSwitch(Cands, N, P, Me, Allowed, Cfg.BalanceMaxCountDiff, BestD, BestSpread);
  if (Best < 0) or (BestD > Max(D0, TargetD) + 1e-9) then
  begin
    Say(S, Format('[Balance] A switch now would make the teams uneven (%s).', [BalChanceText(Ch, TeamNo, N)]), CLR_WARN);
    Exit;
  end;
  Helped := BalSwitchHelps(D0, BestD, Spread0, BestSpread);
  { a volunteer who would only turn the sides around is not taken }
  if Requested and not Helped then
  begin
    Say(S, Format('[Balance] Your switch would not even the teams (%s).', [BalChanceText(Ch, TeamNo, N)]), CLR_WARN);
    Exit;
  end;
  if Requested then
    Bal.RequestUntil := 0;
  Bal.Slots[S].MoveHelped := Helped;
  { in survival only while dead: a new round may have begun before main.pas makes the move }
  BalSend(S, TeamNo[Best], BK_VOLUNTEER, Match.Survival, TeamNo[Fav], Ch[Fav], BestD, 0);
end;

procedure TZSEngine.BalJoinTeam(S: LongInt);
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, Best, Fav, t: LongInt;
  P: TBalParams;
  Ch, Pow, After: TBalTeamValues;
  Cnt: TBalTeamCounts;
begin
  if not TeamGame then
  begin
    Say(S, '[Balance] This game mode has no teams.', CLR_WARN);
    Exit;
  end;
  if not Cfg.BalanceEnabled or Bal.Paused then
  begin
    Say(S, '[Balance] The team balance is off: choose a team from the menu.', CLR_WARN);
    Exit;
  end;
  if Live[S].Team <> TEAM_SPEC then
  begin
    Say(S, '[Balance] You are playing already. !switch moves you to the team that needs a player.', CLR_WARN);
    Exit;
  end;
  if Bal.Slots[S].MoveKind <> BK_NONE then
    Exit;
  BalGather(Cands, TeamNo, N, P, Ch);
  BalTotals(Cands, N, Pow, Cnt);
  Best := BalBestJoin(Pow, Cnt, N, P, BalPowerOf(S), True, Cfg.BalanceMaxCountDiff, -1, After);
  { a player moved a moment ago may not go straight back }
  if (Best >= 0) and (Bal.Slots[S].LockTeam = TeamNo[Best]) and (Bal.Slots[S].LockUntil > GameTick) then
  begin
    Best := -1;
    for t := 0 to N - 1 do
      if (TeamNo[t] <> Bal.Slots[S].LockTeam) and ((Best < 0) or (After[t] < After[Best])) then
        Best := t;
  end;
  Fav := BalFavored(Ch, N);
  BalSend(S, TeamNo[Best], BK_JOIN, False, TeamNo[Fav], Ch[Fav], After[Best], 0);
end;

{ ---------------- admin commands ---------------- }

procedure TZSEngine.BalAdminCheck(AdminSlot: LongInt);
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, Spread, i, k, S: LongInt;
  P: TBalParams;
  Ch, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D, TargetD: Double;
  Move: TBalMove;
  Fav: LongInt;
  Busy, CountFix, Found: Boolean;
  Who: AnsiString;
begin
  if not TeamGame or not Match.Active then
  begin
    Say(AdminSlot, '[Balance] There are no teams in this game mode.', CLR_WARN);
    Exit;
  end;
  { a planned change that is under way (half of a swap done, or a move on its way) is finished,
    not replaced }
  Busy := BalPlanStarted(Bal.Pending);
  if Bal.Pending.Active then
    for k := 0 to Bal.Pending.Count - 1 do
      if not Bal.Pending.Done[k] and (Bal.Slots[Bal.Pending.Slot[k]].MoveKind <> BK_NONE) then
        Busy := True;
  if Busy then
  begin
    for k := 0 to Bal.Pending.Count - 1 do
    begin
      S := Bal.Pending.Slot[k];
      if Bal.Pending.Done[k] then
        Continue;
      if Bal.Slots[S].MoveKind <> BK_NONE then
        Say(AdminSlot, Format('[Balance] %s is on the way to %s.', [Live[S].Name, TeamTitle(Bal.Pending.Team[k])]),
          CLR_HINT)
      else if Live[S].Alive and (Live[S].Flags and EF_A_FLAGGER <> 0) then
      begin
        Say(AdminSlot, Format('[Balance] %s carries a flag: the planned move to %s follows at the next death.',
          [Live[S].Name, TeamTitle(Bal.Pending.Team[k])]), CLR_HINT);
        BalNote(Format('/bal: the planned swap waits for %s, who carries a flag', [Live[S].Name]));
      end
      else
      begin
        BalSend(S, Bal.Pending.Team[k], BK_ADMIN, Match.Survival, Bal.Pending.FavTeam, Bal.Pending.Before,
          Bal.Pending.After, AdminSlot);
        Say(AdminSlot, Format('[Balance] %s moves to %s now, which finishes the planned swap.', [Live[S].Name,
          TeamTitle(Bal.Pending.Team[k])]), CLR_GOOD);
        BalNote(Format('/bal: finishes the planned swap, %s moves to %s', [Live[S].Name, TeamTitle(Bal.Pending.Team[k])]));
      end;
    end;
    Exit;
  end;
  D := BalGather(Cands, TeamNo, N, P, Ch);
  { /bal replaces the planned change, so its players are as free as anybody else }
  for i := 0 to High(Cands) do
    Cands[i].Movable := BalProtection(Self, Cands[i].Id, True, Cands[i].Soft) = '';
  BalTotals(Cands, N, Pow, Cnt);
  Spread := BalSpread(Cnt, N);
  TargetD := (Cfg.BalanceTarget - 50) / 100;
  if (D <= TargetD) and (Spread <= Cfg.BalanceMaxCountDiff) then
  begin
    Say(AdminSlot, Format('[Balance] The teams are even: %s.', [BalChanceText(Ch, TeamNo, N)]), CLR_GOOD);
    Exit;
  end;
  CountFix := Spread > Cfg.BalanceMaxCountDiff;
  Found := BalBestChange(Cands, N, P, Cfg.BalanceMaxCountDiff, TargetD, 0.01, CountFix, not CountFix, Move);
  { uneven numbers: a protection that is no hard rule gives way when nobody free can go }
  if not Found and CountFix then
    Found := BalBestCountFix(Cands, N, P, Cfg.BalanceMaxCountDiff, Move);
  if not Found then
  begin
    Who := BalProtectedText(Self, Cands, N, Ch, CountFix, True);
    { nobody can go now: the planned change stays and waits for its death }
    if Bal.Pending.Active then
    begin
      Say(AdminSlot, Format('[Balance] Nobody can be moved now: %s.', [Who]), CLR_WARN);
      for k := 0 to Bal.Pending.Count - 1 do
        if not Bal.Pending.Done[k] then
          Say(AdminSlot, Format('[Balance] The planned change stays: %s moves to %s at the next death.',
            [Live[Bal.Pending.Slot[k]].Name, TeamTitle(Bal.Pending.Team[k])]), CLR_HINT);
      BalNote(Format('/bal: nobody can be moved now, the planned change stays; protected: %s', [Who]));
      Exit;
    end;
    { only a flag carrier can even the numbers: he goes at his next death }
    if CountFix and BalCarrierMove(Self, Cands, N, P, True, Move) then
    begin
      BalSchedule(Move, Cands, TeamNo, N, Ch, True);
      Say(AdminSlot, Format('[Balance] Only %s, who carries a flag, can even the numbers: the move to %s follows at ' +
        'the next death.', [Live[Cands[Move.A].Id].Name, TeamTitle(TeamNo[Move.ToTeam])]), CLR_HINT);
      Exit;
    end;
    Say(AdminSlot, Format('[Balance] No fair change found for %s. Protected: %s.', [BalChanceText(Ch, TeamNo, N), Who]),
      CLR_WARN);
    BalNote(Format('/bal: no fair change for %s, protected: %s', [BalChanceText(Ch, TeamNo, N), Who]));
    Exit;
  end;
  Fav := BalFavored(Ch, N);
  BalSend(Cands[Move.A].Id, TeamNo[Move.ToTeam], BK_ADMIN, Match.Survival, TeamNo[Fav], Ch[Fav], Move.After, AdminSlot);
  if Move.Kind = BM_SWAP then
    BalSend(Cands[Move.B].Id, TeamNo[Cands[Move.A].Team], BK_ADMIN, Match.Survival, TeamNo[Fav], Ch[Fav], Move.After,
      AdminSlot);
  { the planned change is dropped only now that a move replaces it }
  if Bal.Pending.Active then
    BalCancelPending('replaced by /bal');
  k := Move.A;
  BalNote(Format('/bal: %s moves to %s (%s)', [Live[Cands[k].Id].Name, TeamTitle(TeamNo[Move.ToTeam]),
    BalChanceText(Ch, TeamNo, N)]));
end;

procedure TZSEngine.BalMix(AdminSlot: LongInt);
var
  Cands, Work: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, i, Moved: LongInt;
  P: TBalParams;
  Ch, ChAfter: TBalTeamValues;
  NewTeams: array of LongInt;
  Seed: LongWord;
begin
  if not TeamGame or not Match.Active then
  begin
    Say(AdminSlot, '[Balance] There are no teams in this game mode.', CLR_WARN);
    Exit;
  end;
  BalGather(Cands, TeamNo, N, P, Ch);
  if BalHumans(Cands) < 2 then
  begin
    Say(AdminSlot, '[Balance] There are fewer than two players in the teams, nothing to mix.', CLR_WARN);
    Exit;
  end;
  { new teams: everybody but the bots, excluded players, players carrying a flag and players
    whose last move is still on its way may change; a move that waited for a death is replaced }
  for i := 0 to High(Cands) do
  begin
    Bal.Slots[Cands[i].Id].WaitTeam := 0;
    Cands[i].Movable := Live[Cands[i].Id].Human and not (Live[Cands[i].Id].Alive and
      (Live[Cands[i].Id].Flags and EF_A_FLAGGER <> 0)) and not Bal.Slots[Cands[i].Id].Excluded and
      not BalExcludedAccount(Cands[i].Id) and (Bal.Slots[Cands[i].Id].MoveKind = BK_NONE);
  end;
  SetLength(NewTeams, Length(Cands));
  for i := 0 to High(Cands) do
    NewTeams[i] := Cands[i].Team;
  Seed := LongWord(MonoMs and $FFFFFFFF) xor LongWord((Int64(GameTick) * Int64(2654435761)) and $FFFFFFFF);
  BalMixTeams(Cands, N, P, Cfg.BalanceMaxCountDiff, BAL_MIX_TRIES, (Cfg.BalanceTarget - 50) / 100, Seed, NewTeams);
  Moved := BalApplyTeams(Cands, NewTeams, TeamNo, N, Ch, BK_ADMIN, AdminSlot);
  if Bal.Pending.Active then
    BalCancelPending('replaced by /mix');
  Work := Copy(Cands);
  for i := 0 to High(Work) do
    Work[i].Team := NewTeams[i];
  BalMatchImbalance(Work, N, P, ChAfter);
  Say(AdminSlot, Format('[Balance] New teams: %d player(s) change team; chances %s (before %s).',
    [Moved, BalChanceText(ChAfter, TeamNo, N), BalChanceText(Ch, TeamNo, N)]), CLR_GOOD);
  BalNote(Format('/mix: %d players change team (%s before, %s after)', [Moved, BalChanceText(Ch, TeamNo, N),
    BalChanceText(ChAfter, TeamNo, N)]));
  if Cfg.BalanceAnnounce and (Moved > 0) then
    Broadcast(Format('[Balance] An admin mixed the teams (%s).', [BalChanceText(ChAfter, TeamNo, N)]), CLR_HINT);
end;

procedure TZSEngine.BalMoveTo(AdminSlot, S, Team: LongInt);
begin
  if not SlotValid(S) then
  begin
    Say(AdminSlot, '[Balance] No such player.', CLR_WARN);
    Exit;
  end;
  if Live[S].Team = Team then
  begin
    Say(AdminSlot, Format('[Balance] %s plays for %s already.', [Live[S].Name, TeamTitle(Team)]), CLR_WARN);
    Exit;
  end;
  if (Team <> TEAM_SPEC) and (not TeamGame or (Team < TEAM_ALPHA) or (Team > TEAM_DELTA) or
     ((Match.GameStyle <> GS_TM) and (Team > TEAM_BRAVO))) then
  begin
    Say(AdminSlot, '[Balance] This team does not exist in this game mode.', CLR_WARN);
    Exit;
  end;
  { survival kills a living player who changes team: a move into another team waits for the death,
    as with /swap and /bal; a move to the spectators goes at once }
  BalSend(S, Team, BK_ADMIN, Match.Survival and (Team <> TEAM_SPEC), 0, 0, 0, AdminSlot);
  if BalInPending(S) then
    BalCancelPending('an admin moved ' + Live[S].Name);
  BalNote(Format('admin moves %s to %s', [Live[S].Name, TeamTitle(Team)]));
end;

procedure TZSEngine.BalSwap(AdminSlot, A, B: LongInt);
var
  TA, TB: LongInt;
begin
  if not TeamGame or not Match.Active then
  begin
    Say(AdminSlot, '[Balance] There are no teams in this game mode.', CLR_WARN);
    Exit;
  end;
  if not SlotValid(A) or not SlotValid(B) then
  begin
    Say(AdminSlot, '[Balance] That player is not on the server any more.', CLR_WARN);
    Exit;
  end;
  if A = B then
  begin
    Say(AdminSlot, Format('[Balance] Both names are %s (slot %d): give two different players.', [Live[A].Name, A]), CLR_WARN);
    Exit;
  end;
  TA := Live[A].Team;
  TB := Live[B].Team;
  if (TA < TEAM_ALPHA) or (TA > TEAM_DELTA) then
  begin
    Say(AdminSlot, Format('[Balance] %s (slot %d) is not in a team: /move %d <team> puts them in one.', [Live[A].Name, A, A]),
      CLR_WARN);
    Exit;
  end;
  if (TB < TEAM_ALPHA) or (TB > TEAM_DELTA) then
  begin
    Say(AdminSlot, Format('[Balance] %s (slot %d) is not in a team: /move %d <team> puts them in one.', [Live[B].Name, B, B]),
      CLR_WARN);
    Exit;
  end;
  if TA = TB then
  begin
    Say(AdminSlot, Format('[Balance] %s and %s both play for %s: a swap needs two teams.', [Live[A].Name, Live[B].Name,
      TeamTitle(TA)]), CLR_WARN);
    Exit;
  end;
  Say(AdminSlot, Format('[Balance] Swapping %s (%s) and %s (%s)...', [Live[A].Name, TeamTitle(TA), Live[B].Name,
    TeamTitle(TB)]), CLR_HINT);
  BalSend(A, TB, BK_ADMIN, Match.Survival, 0, 0, 0, AdminSlot);
  BalSend(B, TA, BK_ADMIN, Match.Survival, 0, 0, 0, AdminSlot);
  if BalInPending(A) or BalInPending(B) then
    BalCancelPending('replaced by /swap');
  BalNote(Format('admin swaps %s and %s', [Live[A].Name, Live[B].Name]));
end;

procedure TZSEngine.BalToggleExclude(AdminSlot, S: LongInt);
begin
  if not SlotValid(S) then
  begin
    Say(AdminSlot, '[Balance] No such player.', CLR_WARN);
    Exit;
  end;
  Bal.Slots[S].Excluded := not Bal.Slots[S].Excluded;
  if Bal.Slots[S].Excluded then
    Say(AdminSlot, Format('[Balance] %s is not moved by the balance until they leave.', [Live[S].Name]), CLR_GOOD)
  else
    Say(AdminSlot, Format('[Balance] %s may be moved by the balance again.', [Live[S].Name]), CLR_GOOD);
  BalNote(Format('exclusion of %s: %s', [Live[S].Name, BoolToStr(Bal.Slots[S].Excluded, 'on', 'off')]));
  { a change planned for the player is off; the balance looks for another one }
  if Bal.Slots[S].Excluded and BalInPending(S) then
    BalCancelPending(Live[S].Name + ' was excluded');
end;

procedure TZSEngine.BalSetPaused(AdminSlot: LongInt; Paused: Boolean);
begin
  Bal.Paused := Paused;
  if Paused then
  begin
    BalCancelPending('paused by an admin');
    Say(AdminSlot, '[Balance] Paused: no automatic moves and no placing of joins until /bal on.', CLR_WARN);
  end
  else if Cfg.BalanceEnabled then
    Say(AdminSlot, '[Balance] Running again.', CLR_GOOD)
  else
    Say(AdminSlot, '[Balance] Enabled = 0 in settings.ini: set it to 1 and use /zs_reload.', CLR_WARN);
  BalNote(BoolToStr(Paused, 'paused', 'resumed') + ' by an admin');
  Bal.Dirty := True;
end;

{ ---------------- the game thread's view ---------------- }

procedure TZSEngine.BalRefreshSnapshot;
var
  Snap: TBalSnapshot;
  S, k: LongInt;
begin
  Bal.Dirty := False;
  Snap.Valid := True;
  Snap.Assign := BalanceActive and Cfg.BalanceAssignJoins;
  Snap.TeamCount := BalTeams(Snap.TeamNo);
  Snap.Params := BalParamsFor(Snap.TeamCount);
  Snap.Tolerance := Cfg.BalanceJoinTolerance / 100;
  Snap.MaxSpread := Cfg.BalanceMaxCountDiff;
  for S := 1 to MAX_PLAYERS do
  begin
    Snap.Players[S].Active := Live[S].Active;
    Snap.Players[S].Team := Live[S].Team;
    Snap.Players[S].Counts := Live[S].Active and (Live[S].Human or Cfg.BalanceCountBots);
    if Snap.Players[S].Counts then
      Snap.Players[S].Power := BalPowerOf(S)
    else
      Snap.Players[S].Power := 0;
    Snap.Players[S].LockTeam := Bal.Slots[S].LockTeam;
    Snap.Players[S].Locked := Bal.Slots[S].LockUntil > GameTick;
  end;
  Snap.Expected := Copy(Bal.Expected);
  Snap.SeenId := Bal.SeenId;
  EnterCriticalSection(FBalLock);
  try
    FBalSnap := Snap;
    k := 0;
    while k < Length(FJoinReqs) do
      { seen by the engine, or so old that the join never arrived (a dropped event) }
      if (FJoinReqs[k].Id <= Bal.SeenId) or (GameTick - FJoinReqs[k].Tick > BAL_EXPECT_TICKS) then
      begin
        FJoinReqs[k] := FJoinReqs[High(FJoinReqs)];
        SetLength(FJoinReqs, Length(FJoinReqs) - 1);
      end
      else
        Inc(k);
  finally
    LeaveCriticalSection(FBalLock);
  end;
end;

{ Called by main.pas on the game thread before a player enters Team. The answer is the team to use,
  or -1 to keep a player who already plays where they are. It never waits for the engine. }
function TZSEngine.TeamJoinAdvice(Slot, Team, OldTeam, Tick: LongInt): LongInt;
var
  Pow, After: TBalTeamValues;
  Cnt: TBalTeamCounts;
  k, t, S, Req, Best, Id: LongInt;
  JoinPower, BestOther: Double;
  IsNew, Known, Locked: Boolean;
  Ev: TZSEvent;
begin
  Result := Team;
  Id := 0;
  JoinPower := 1;
  EnterCriticalSection(FBalLock);
  try
    if not FBalSnap.Valid or not FBalSnap.Assign then
      Exit;
    Req := BalTeamIndexOf(FBalSnap.TeamNo, FBalSnap.TeamCount, Team);
    { the spectators and team 0 are nobody's business }
    if Req < 0 then
      Exit;
    IsNew := (OldTeam < 0) or (OldTeam > TEAM_SPEC);
    Known := (Slot >= 1) and (Slot <= MAX_PLAYERS) and FBalSnap.Players[Slot].Active and not IsNew;
    for t := 0 to BAL_MAX_TEAMS - 1 do
    begin
      Pow[t] := 0;
      Cnt[t] := 0;
    end;
    for S := 1 to MAX_PLAYERS do
    begin
      if (S = Slot) or not FBalSnap.Players[S].Active or not FBalSnap.Players[S].Counts then
        Continue;
      t := BalTeamIndexOf(FBalSnap.TeamNo, FBalSnap.TeamCount, FBalSnap.Players[S].Team);
      if t < 0 then
        Continue;
      Pow[t] := Pow[t] + FBalSnap.Players[S].Power;
      Inc(Cnt[t]);
    end;
    { joins that are on their way: seen by the engine, or asked since its last look }
    for k := 0 to High(FBalSnap.Expected) do
    begin
      S := FBalSnap.Expected[k].Slot;
      if (S > 0) and (S = Slot) then
        Continue;
      { already counted as a player of that team }
      if (S >= 1) and (S <= MAX_PLAYERS) and FBalSnap.Players[S].Active and
         (FBalSnap.Players[S].Team = FBalSnap.Expected[k].Team) then
        Continue;
      t := BalTeamIndexOf(FBalSnap.TeamNo, FBalSnap.TeamCount, FBalSnap.Expected[k].Team);
      if t >= 0 then
      begin
        Pow[t] := Pow[t] + FBalSnap.Expected[k].Power;
        Inc(Cnt[t]);
      end;
    end;
    for k := 0 to High(FJoinReqs) do
    begin
      if (FJoinReqs[k].Id <= FBalSnap.SeenId) or ((FJoinReqs[k].Slot > 0) and (FJoinReqs[k].Slot = Slot)) then
        Continue;
      t := BalTeamIndexOf(FBalSnap.TeamNo, FBalSnap.TeamCount, FJoinReqs[k].Team);
      if t >= 0 then
      begin
        Pow[t] := Pow[t] + FJoinReqs[k].Power;
        Inc(Cnt[t]);
      end;
    end;
    { a player on the server is known; a new one is taken for the median until the engine knows more }
    if Known then
      JoinPower := FBalSnap.Players[Slot].Power;
    Best := BalBestJoin(Pow, Cnt, FBalSnap.TeamCount, FBalSnap.Params, JoinPower, True, FBalSnap.MaxSpread, Req, After);
    Locked := Known and FBalSnap.Players[Slot].Locked and (FBalSnap.Players[Slot].LockTeam = Team);
    if not Locked and (After[Req] <= After[Best] + FBalSnap.Tolerance) then
      Result := Team
    else if Best <> Req then
      Result := FBalSnap.TeamNo[Best]
    else
    begin
      { the team asked for is the best, but locked: the best of the others }
      Result := -1;
      BestOther := 9;
      for t := 0 to FBalSnap.TeamCount - 1 do
        if (t <> Req) and (After[t] < BestOther) then
        begin
          BestOther := After[t];
          Result := FBalSnap.TeamNo[t];
        end;
    end;
    { a player who plays in a team stays there instead of being sent somewhere not asked for }
    if (Result <> Team) and (OldTeam >= TEAM_ALPHA) and (OldTeam <= TEAM_DELTA) then
      Result := -1;
    { a new player is never refused: the server would treat that as a full server }
    if IsNew and (Result < TEAM_ALPHA) then
      Result := FBalSnap.TeamNo[Best];
    if ((Result >= TEAM_ALPHA) and (Result <> OldTeam)) or (Result <> Team) then
    begin
      Inc(FJoinReqId);
      Id := FJoinReqId;
      k := Length(FJoinReqs);
      SetLength(FJoinReqs, k + 1);
      FJoinReqs[k].Id := Id;
      FJoinReqs[k].Slot := Slot;
      FJoinReqs[k].Team := Result;
      FJoinReqs[k].Power := JoinPower;
      FJoinReqs[k].Tick := Tick;
      FJoinReqs[k].Requested := Team;
      FJoinReqs[k].Note := Result <> Team;
    end;
  finally
    LeaveCriticalSection(FBalLock);
  end;
  if Id > 0 then
  begin
    Ev := NewEvent(zeTeamRequest);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Id;
    Ev.I[1] := Team;
    Ev.I[2] := Result;
    Ev.I[3] := OldTeam;
    Ev.F[0] := JoinPower;
    PushEvent(Ev);
  end;
end;

{ ---------------- how good the predictions are ---------------- }

procedure TZSEngine.BalAddHistory(const R: TBalRecord; Save: Boolean);
begin
  if Length(Bal.History) < BAL_HISTORY_MAX then
    SetLength(Bal.History, BAL_HISTORY_MAX);
  Bal.History[Bal.HistoryNext] := R;
  Bal.History[Bal.HistoryNext].Strength := Copy(R.Strength);
  Bal.History[Bal.HistoryNext].Team := Copy(R.Team);
  Bal.History[Bal.HistoryNext].Weight := Copy(R.Weight);
  Bal.HistoryNext := (Bal.HistoryNext + 1) mod BAL_HISTORY_MAX;
  if Bal.HistoryCount < BAL_HISTORY_MAX then
    Inc(Bal.HistoryCount);
  if Save then
    AppendLog('teambalance-history.log', BalRecordText(R));
  { tune again every ten matches; with a full history the count no longer grows, so the matches
    are counted separately }
  Inc(Bal.SinceFit);
  if (Bal.HistoryCount >= 30) and (Bal.SinceFit >= 10) then
  begin
    BalFit(Bal.History, Bal.HistoryCount, Bal.FitSize, Bal.FitDouble, Bal.FitBrier);
    Bal.FitCount := Bal.HistoryCount;
    Bal.SinceFit := 0;
  end;
end;

procedure TZSEngine.BalLoadHistory;
var
  F: TFileStream;
  L: TStringList;
  Data, Path: AnsiString;
  k: LongInt;
  R: TBalRecord;
begin
  if LogDir = '' then
    Exit;
  Path := StorePath(LogDir, 'teambalance-history.log');
  if not FileExists(Path) then
    Exit;
  Data := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > 256 * 1024 then
        F.Position := F.Size - 256 * 1024;
      SetLength(Data, F.Size - F.Position);
      if Length(Data) > 0 then
        F.ReadBuffer(Data[1], Length(Data));
    finally
      F.Free;
    end;
  except
    Exit;
  end;
  L := TStringList.Create;
  try
    L.Text := Data;
    { one fit after the whole file instead of one every ten lines of it: a full history would
      otherwise be fitted some 37 times at start-up, half a second of the engine thread }
    Bal.SinceFit := -2 * BAL_HISTORY_MAX;
    for k := Max(0, L.Count - BAL_HISTORY_MAX) to L.Count - 1 do
      if BalParseRecord(L[k], R) then
        BalAddHistory(R, False);
    if Bal.HistoryCount >= 30 then
    begin
      BalFit(Bal.History, Bal.HistoryCount, Bal.FitSize, Bal.FitDouble, Bal.FitBrier);
      Bal.FitCount := Bal.HistoryCount;
      Bal.SinceFit := 0;
    end
    else
      Bal.SinceFit := Bal.HistoryCount;
  finally
    L.Free;
  end;
end;

procedure TZSEngine.BalanceMatchEnd(Completed: Boolean);
var
  TeamNo: TBalTeamNos;
  S, T, n, Bin, DurTicks, Games: LongInt;
  P, O, Skill: Double;
  R: TBalRecord;
  AlphaWon: Boolean;
begin
  { a match cut short by a vote or an admin says little about the teams }
  if not Completed or not TeamGame or (BalTeams(TeamNo) <> 2) or (Bal.PredCount < 6) or
     (Match.TeamScore[TEAM_ALPHA] = Match.TeamScore[TEAM_BRAVO]) then
    Exit;
  AlphaWon := Match.TeamScore[TEAM_ALPHA] > Match.TeamScore[TEAM_BRAVO];
  P := Bal.PredSum / Bal.PredCount;
  if AlphaWon then
    O := 1
  else
    O := 0;
  Inc(DB.Server.BalPredCount);
  DB.Server.BalBrierSum := DB.Server.BalBrierSum + Sqr(P - O);
  Bin := EnsureRange(Trunc(P * 10), 0, 9);
  Inc(DB.Server.BalBinCount[Bin]);
  if AlphaWon then
    Inc(DB.Server.BalBinWins[Bin]);
  DB.TouchServer;

  { the line-up for tuning: everybody by the share of the match played in Alpha and Bravo }
  DurTicks := Max(1, GameTick - Match.StartTick);
  R.Median := Bal.Median;
  R.Bias := BalAlphaBias;
  R.AlphaWon := AlphaWon;
  R.Strength := nil;
  R.Team := nil;
  R.Weight := nil;
  n := 0;
  for S := 1 to MAX_PLAYERS do
  begin
    if not Live[S].Active or (not Live[S].Human and not Cfg.BalanceCountBots) then
      Continue;
    for T := TEAM_ALPHA to TEAM_BRAVO do
      if Live[S].TeamTicks[T] > 0 then
      begin
        SetLength(R.Strength, n + 1);
        SetLength(R.Team, n + 1);
        SetLength(R.Weight, n + 1);
        R.Strength[n] := BalBase(S, Skill, Games);
        R.Team[n] := T - 1;
        R.Weight[n] := Min(1.0, Live[S].TeamTicks[T] / DurTicks);
        Inc(n);
      end;
  end;
  if n >= 2 then
    BalAddHistory(R, not FReadOnly);
end;

{ another balancer on the server would fight this one }
procedure TZSEngine.BalCheckOthers;
var
  SR: TSearchRec;
  Root: AnsiString;
begin
  if not Cfg.BalanceEnabled then
    Exit;
  Root := ExtractFileDir(ExcludeTrailingPathDelimiter(ExpandFileName(ScriptDir)));
  if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory <> 0) and (Pos('cube', LowerCase(SR.Name)) > 0) then
        WriteServer('[ZitroStats] WARNING: scripts/' + SR.Name + ' looks like another team balancer. ' +
          'Two balancers move players against each other: turn one of them off.');
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;
