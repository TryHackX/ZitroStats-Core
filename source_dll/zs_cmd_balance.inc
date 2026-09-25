{ zs_commands: the team balance (!bal, /balinfo) and finding a player on the server }

function BalTeamName(Team: LongInt): AnsiString;
begin
  case Team of
    TEAM_ALPHA: Result := 'Alpha';
    TEAM_BRAVO: Result := 'Bravo';
    TEAM_CHARLIE: Result := 'Charlie';
    TEAM_DELTA: Result := 'Delta';
    TEAM_SPEC: Result := 'Spectators';
    else Result := 'none';
  end;
end;

{ alpha, bravo, charlie, delta, spec(tator) or a number 1-5; -1 when the text is none of them }
function TeamFromText(const Text: AnsiString): LongInt;
var
  T: AnsiString;
begin
  T := LowerCase(Trim(Text));
  if (T = 'alpha') or (T = 'a') or (T = 'red') then
    Result := TEAM_ALPHA
  else if (T = 'bravo') or (T = 'b') or (T = 'blue') then
    Result := TEAM_BRAVO
  else if (T = 'charlie') or (T = 'c') then
    Result := TEAM_CHARLIE
  else if (T = 'delta') or (T = 'd') then
    Result := TEAM_DELTA
  else if (T = 'spec') or (T = 'spectator') or (T = 'spectators') or (T = 's') then
    Result := TEAM_SPEC
  else
  begin
    Result := StrToIntDef(T, -1);
    if (Result < TEAM_ALPHA) or (Result > TEAM_SPEC) then
      Result := -1;
  end;
end;

{ A player on the server: slot number, #id, exact name, then a part of a name that only one
  player has. 0 when there is none, and Why says what is wrong in words an admin can act on. }
function ResolvePlayerSlot(E: TZSEngine; const Text: AnsiString; out Why: AnsiString): LongInt;
var
  T, Low, Names: AnsiString;
  S, Idx, Found, Count, N: LongInt;
begin
  Result := 0;
  Why := '';
  T := Trim(Text);
  if T = '' then
  begin
    Why := 'No player given.';
    Exit;
  end;
  { a plain number is a slot; a player may still carry that number as the name }
  N := StrToIntDef(T, -1);
  if (T[1] <> '#') and (N >= 0) and (IntToStr(N) = T) then
  begin
    if (N >= 1) and (N <= MAX_PLAYERS) and E.Live[N].Active then
      Exit(N);
    for S := 1 to MAX_PLAYERS do
      if E.Live[S].Active and SameText(E.Live[S].Name, T) then
        Exit(S);
    if (N < 1) or (N > MAX_PLAYERS) then
      Why := Format('There is no slot %d: the slots are 1-%d.', [N, MAX_PLAYERS])
    else
      Why := Format('Slot %d is empty.', [N]);
    Exit;
  end;
  if T[1] = '#' then
  begin
    Idx := E.DB.IndexOfId(StrToIntDef(Copy(T, 2, MaxInt), 0));
    if not E.DB.Valid(Idx) then
    begin
      Why := 'There is no account ' + T + '.';
      Exit;
    end;
    Result := SlotOfIndex(E, Idx);
    if Result = 0 then
      Why := Format('Account %s (%s) is not on the server.', [T, E.DB.Profiles[Idx]^.ActiveName]);
    Exit;
  end;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and SameText(E.Live[S].Name, T) then
      Exit(S);
  Low := LowerCase(T);
  Found := 0;
  Count := 0;
  Names := '';
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and ContainsLower(E.Live[S].Name, Low) then
    begin
      Found := S;
      Inc(Count);
      if Count <= 4 then
      begin
        if Names <> '' then
          Names := Names + ', ';
        Names := Names + Format('%s (%d)', [E.Live[S].Name, S]);
      end;
    end;
  if Count = 1 then
    Exit(Found);
  if Count = 0 then
    Why := Format('Nobody on the server has "%s" in the name.', [T])
  else
    Why := Format('"%s" fits %d players: %s - use the slot number.', [T, Count, Names]);
end;

{ a player on the server: slot number, #id, exact name, then a unique part of a name }
function FindPlayerSlot(E: TZSEngine; const Text: AnsiString): LongInt;
var
  Why: AnsiString;
begin
  Result := ResolvePlayerSlot(E, Text, Why);
end;

{ one line per team: players, average strength, power, chance and score }
procedure BalTeamLines(E: TZSEngine; Slot: LongInt; const Cands: TBalCandArray; const TeamNo: TBalTeamNos;
  TeamCount: LongInt; const Ch: TBalTeamValues);
var
  t, i, Count, Bots: LongInt;
  Sum, Pow: Double;
begin
  for t := 0 to TeamCount - 1 do
  begin
    Count := 0;
    Bots := 0;
    Sum := 0;
    Pow := 0;
    for i := 0 to High(Cands) do
      if Cands[i].Team = t then
      begin
        Inc(Count);
        if not E.Live[Cands[i].Id].Human then
          Inc(Bots);
        Sum := Sum + E.BalStrength(Cands[i].Id);
        Pow := Pow + Cands[i].Power;
      end;
    Out(E, Slot, Format('%-8s %2d players%s  avg %5s  power %5s  chance %4s  score %d',
      [BalTeamName(TeamNo[t]), Count, BoolToStr(Bots > 0, Format(' (%d bots)', [Bots]), ''),
       FloatStr(SafeDivD(Sum, Count), 0), FloatStr(Pow, 2), IntToStr(Round(Ch[t] * 100)) + '%',
       E.Match.TeamScore[TeamNo[t]]]), CLR_MATCHES);
  end;
end;

function BalSecondsText(Ticks: LongInt): AnsiString;
begin
  Result := FormatDurationShort(Max(0, Ticks) div TICKS_PER_SECOND);
end;

{ The players of the biggest team, each with the reason, when none of them can even the numbers;
  '' when somebody can: a free player, one whose protection gives way to uneven numbers, or a flag
  carrier at his next death. }
function BalNobodyText(E: TZSEngine; const Cands: TBalCandArray; TeamCount: LongInt): AnsiString;
var
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  i, t, Hi: LongInt;
  Block: AnsiString;
begin
  Result := '';
  BalTotals(Cands, TeamCount, Pow, Cnt);
  Hi := 0;
  for t := 0 to TeamCount - 1 do
    Hi := Max(Hi, Cnt[t]);
  for i := 0 to High(Cands) do
  begin
    t := Cands[i].Team;
    if (t < 0) or (t >= TeamCount) or (Cnt[t] <> Hi) then
      Continue;
    Block := E.BalBlocker(Cands[i].Id);
    if (Cands[i].Soft >= 0) or (Block = 'carries a flag') then
      Exit('');
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Format('%s (%s)', [E.Live[Cands[i].Id].Name, Block]);
  end;
end;

{ what the balance is doing now, in one line }
function BalStatusText(E: TZSEngine; D: Double; Spread: LongInt; const Cands: TBalCandArray; const Ch: TBalTeamValues;
  const TeamNo: TBalTeamNos; TeamCount, Humans: LongInt): AnsiString;
var
  Why: AnsiString;
  Fav: LongInt;
begin
  Fav := BalFavored(Ch, TeamCount);
  if not E.Cfg.BalanceEnabled then
    Exit('the team balance is off on this server');
  if E.Bal.Paused then
    Exit('paused by an admin');
  if not E.Match.Active then
    Exit('waiting for the map');
  if Humans < E.Cfg.BalanceMinPlayers then
    Exit(Format('waiting for %d players', [E.Cfg.BalanceMinPlayers]));
  if E.Bal.RequestUntil > E.GameTick then
    Exit(Format('%s is asked for a volunteer (!switch), %s left', [BalTeamName(E.Bal.RequestFrom),
      BalSecondsText(E.Bal.RequestUntil - E.GameTick)]));
  if (Spread > E.Cfg.BalanceMaxCountDiff) and (E.Bal.CountSince > 0) then
  begin
    Result := Format('the numbers differ by %d', [Spread]);
    if E.GameTick - E.Bal.CountSince < E.Cfg.BalanceLeaveGraceSeconds * TICKS_PER_SECOND then
      Result := Result + Format(', waiting %s for a new player',
        [BalSecondsText(E.Bal.CountSince + E.Cfg.BalanceLeaveGraceSeconds * TICKS_PER_SECOND - E.GameTick)])
    else if not E.BalMayMove(True, Why) then
      Result := Result + ', no move: ' + Why
    else if not E.Bal.Pending.Active then
    begin
      Why := BalNobodyText(E, Cands, TeamCount);
      if Why <> '' then
        Result := Result + ', nobody can be moved: ' + Why;
    end;
    Exit;
  end;
  if D > (E.Cfg.BalanceThreshold - 50) / 100 then
  begin
    Result := Format('%s is stronger (%d%%)', [BalTeamName(TeamNo[Fav]), Round(Ch[Fav] * 100)]);
    if (E.Bal.ChanceSince > 0) and (E.GameTick - E.Bal.ChanceSince < E.Cfg.BalanceSustainSeconds * TICKS_PER_SECOND) then
      Result := Result + Format(', a change if it lasts %s more',
        [BalSecondsText(E.Bal.ChanceSince + E.Cfg.BalanceSustainSeconds * TICKS_PER_SECOND - E.GameTick)])
    else if not E.BalMayMove(False, Why) then
      Result := Result + ', no move: ' + Why
    else if E.Bal.NoChangeNoted then
      Result := Result + ', no change would help now';
    Exit;
  end;
  if D > (E.Cfg.BalanceTarget - 50) / 100 then
    Result := Format('close enough (%s %d%%)', [BalTeamName(TeamNo[Fav]), Round(Ch[Fav] * 100)])
  else
    Result := 'even';
end;

{ When part k of the planned change happens. AtDeath is False when it happens now (the move is on
  its way, or the time is up); otherwise the result is the note after "at the next death". }
function BalPlanWait(E: TZSEngine; k: LongInt; out AtDeath: Boolean): AnsiString;
var
  S, j: LongInt;
  MustFinish: Boolean;
begin
  Result := '';
  AtDeath := False;
  S := E.Bal.Pending.Slot[k];
  { MoveKind 0: no move of the player is on its way }
  if E.Bal.Slots[S].MoveKind <> 0 then
    Exit;
  { a count fix, or a swap with half of it done or on its way: survival never drops it }
  MustFinish := E.Bal.Pending.CountFix;
  for j := 0 to E.Bal.Pending.Count - 1 do
    if E.Bal.Pending.Done[j] or (E.Bal.Slots[E.Bal.Pending.Slot[j]].MoveKind <> 0) then
      MustFinish := True;
  AtDeath := True;
  if E.Live[S].Alive and (E.Live[S].Flags and EF_A_FLAGGER <> 0) then
    Result := ' (carries a flag)'
  else if E.Match.Survival then
  begin
    if not MustFinish then
      Result := Format(' (dropped after %s)', [BalSecondsText(E.Bal.Pending.Deadline - E.GameTick)]);
  end
  else if E.GameTick < E.Bal.Pending.Deadline then
    Result := Format(' (at most %s)', [BalSecondsText(E.Bal.Pending.Deadline - E.GameTick)])
  else
    AtDeath := False;
end;

{ The !switch line for a player: only when BalSwitch would take the switch, with the same checks,
  and why it helps. '' otherwise. }
function BalSwitchHint(E: TZSEngine; Slot: LongInt; const Cands: TBalCandArray; const TeamNo: TBalTeamNos;
  TeamCount: LongInt; const P: TBalParams; D0: Double; const Ch: TBalTeamValues): AnsiString;
var
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  k, Me, Mine, Best, Spread0, Spread1: LongInt;
  D1, TargetD: Double;
  Requested: Boolean;
  Allowed: array[0..BAL_MAX_TEAMS - 1] of Boolean;
begin
  Result := '';
  if not E.Cfg.BalanceEnabled or E.Bal.Paused then
    Exit;
  if E.Live[Slot].Alive and (E.Live[Slot].Flags and EF_A_FLAGGER <> 0) then
    Exit;
  { being moved already }
  if (E.Bal.Slots[Slot].MoveKind <> 0) or (E.Bal.Slots[Slot].WaitTeam > 0) then
    Exit;
  if E.Bal.Pending.Active then
    for k := 0 to E.Bal.Pending.Count - 1 do
      if (E.Bal.Pending.Slot[k] = Slot) and not E.Bal.Pending.Done[k] then
        Exit;
  Me := -1;
  for k := 0 to High(Cands) do
    if Cands[k].Id = Slot then
      Me := k;
  if Me < 0 then
    Exit;
  Mine := Cands[Me].Team;
  BalTotals(Cands, TeamCount, Pow, Cnt);
  Spread0 := BalSpread(Cnt, TeamCount);
  TargetD := (E.Cfg.BalanceTarget - 50) / 100;
  Requested := (E.Bal.RequestUntil > E.GameTick) and (E.Live[Slot].Team = E.Bal.RequestFrom);
  for k := 0 to BAL_MAX_TEAMS - 1 do
    Allowed[k] := (k < TeamCount) and not (Requested and (TeamNo[k] <> E.Bal.RequestTo)) and
      not ((E.Bal.Slots[Slot].LockTeam = TeamNo[k]) and (E.Bal.Slots[Slot].LockUntil > E.GameTick));
  Best := BalBestSwitch(Cands, TeamCount, P, Me, Allowed, E.Cfg.BalanceMaxCountDiff, D1, Spread1);
  if (Best < 0) or (D1 > Max(D0, TargetD) + 1e-9) then
    Exit;
  if Requested and not BalSwitchHelpful(D0, D1, Spread0, Spread1, TargetD, E.Cfg.BalanceMinGain / 100) then
    Exit;
  if Spread1 < Spread0 then
    Result := Format('%s has %d players, %s %d: !switch moves you to %s', [BalTeamName(TeamNo[Mine]), Cnt[Mine],
      BalTeamName(TeamNo[Best]), Cnt[Best], BalTeamName(TeamNo[Best])])
  else if BalFavored(Ch, TeamCount) = Mine then
    Result := Format('%s is stronger (%d%%): !switch moves you to %s', [BalTeamName(TeamNo[Mine]),
      Round(Ch[Mine] * 100), BalTeamName(TeamNo[Best])])
  else
    Result := Format('!switch moves you to %s', [BalTeamName(TeamNo[Best])]);
  { survival moves nobody who is alive: the switch waits for the death }
  if E.Match.Survival and E.Live[Slot].Alive then
    Result := Result + ' once you are dead';
end;

procedure CmdBalance(E: TZSEngine; Slot: LongInt);
const
  W = LINE_W;
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, k, Spread, Games, Mine: LongInt;
  P: TBalParams;
  Ch, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D, Skill, Base, Wt, Soft: Double;
  Line, Block, Method, Hint: AnsiString;
  AtDeath: Boolean;
begin
  if not E.TeamGame then
  begin
    Out(E, Slot, 'This game mode has no teams, so there is nothing to balance.', CLR_WARN);
    Exit;
  end;
  D := E.BalGather(Cands, TeamNo, N, P, Ch);
  BalTotals(Cands, N, Pow, Cnt);
  Spread := BalSpread(Cnt, N);
  Header(E, Slot, 'Team Balance', W);
  BalTeamLines(E, Slot, Cands, TeamNo, N, Ch);
  Rule(E, Slot, W);
  Out(E, Slot, 'Status: ' + BalStatusText(E, D, Spread, Cands, Ch, TeamNo, N, E.BalHumansOnTeams), WHITE);
  Mine := -1;
  if E.Bal.Pending.Active then
    for k := 0 to E.Bal.Pending.Count - 1 do
      if not E.Bal.Pending.Done[k] then
      begin
        if E.Bal.Pending.Slot[k] = Slot then
          Mine := k;
        Line := BalPlanWait(E, k, AtDeath);
        if AtDeath then
          Line := ' after the next death' + Line
        else
          Line := ' now';
        Out(E, Slot, Format('Next:   %s to %s%s', [E.Live[E.Bal.Pending.Slot[k]].Name,
          BalTeamName(E.Bal.Pending.Team[k]), Line]), CLR_WARN);
      end;
  Hint := '';
  if (Slot >= 1) and E.SlotValid(Slot) then
  begin
    if (E.Live[Slot].Team >= TEAM_ALPHA) and (E.Live[Slot].Team <= TEAM_DELTA) then
    begin
      Base := E.BalBase(Slot, Skill, Games);
      Method := LowerCase(Trim(E.Cfg.BalanceMethod));
      if Method = 'global' then
        Out(E, Slot, Format('You:    strength %s (rating %s from %d games)', [FloatStr(Base, 0), FloatStr(Skill, 0),
          Games]), CLR_YOU)
      else if Method = 'map' then
        Out(E, Slot, Format('You:    strength %s = median %s + form %s on this map', [FloatStr(E.BalStrength(Slot), 0),
          FloatStr(E.Bal.Median, 0), FloatStr(E.Bal.Slots[Slot].Form, 0)]), CLR_YOU)
      else
      begin
        Out(E, Slot, Format('You:    strength %s = rating %s (%d games, counted as %s)', [FloatStr(E.BalStrength(Slot), 0),
          FloatStr(Skill, 0), Games, FloatStr(Base, 0)]), CLR_YOU);
        Wt := E.BalFormWeight(Slot);
        if Wt < E.Cfg.BalanceFormWeight - 0.005 then
          Line := Format(', %s after %s min on the map', [FloatStr(E.Cfg.BalanceFormWeight, 2),
            FloatStr(E.Cfg.BalanceFormFullMinutes, 0)])
        else
          Line := '';
        Out(E, Slot, Format('        + form %s on this map x %s%s', [FloatStr(E.Bal.Slots[Slot].Form, 0),
          FloatStr(Wt, 2), Line]), CLR_YOU);
      end;
      Block := E.BalBlocker(Slot);
      if Mine >= 0 then
      begin
        Line := BalPlanWait(E, Mine, AtDeath);
        if AtDeath then
          Line := ' at your next death' + Line
        else
          Line := ' now';
        Out(E, Slot, Format('        the balance moves you to %s%s', [BalTeamName(E.Bal.Pending.Team[Mine]), Line]),
          CLR_WARN);
      end
      else if (Block <> '') and (Block <> 'bot') then
      begin
        { a protection that is no hard rule gives way when only this player can even the numbers }
        Soft := -1;
        for k := 0 to High(Cands) do
          if Cands[k].Id = Slot then
            Soft := Cands[k].Soft;
        if Soft > 0 then
          Out(E, Slot, '        you move only if nobody else can even the numbers: ' + Block, CLR_HINT)
        else
          Out(E, Slot, '        the balance does not move you now: ' + Block, CLR_HINT);
      end;
      if E.BalAfk(Slot) then
        Out(E, Slot, Format('        you count as away (%s of your power) until you move',
          [IntToStr(Round(E.Cfg.BalanceAfkFactor * 100)) + '%']), CLR_WARN);
      Hint := BalSwitchHint(E, Slot, Cands, TeamNo, N, P, D, Ch);
    end
    else
      Out(E, Slot, 'You:    watching; !join puts you in the team that needs a player', CLR_YOU);
  end;
  if Hint <> '' then
    Out(E, Slot, 'Switch: ' + Hint, CLR_HINT);
  if E.Cfg.BalanceEnabled then
    Out(E, Slot, Format('Method: %s, rating %s', [LowerCase(E.Cfg.BalanceMethod), LowerCase(E.Cfg.BalanceSkill)]),
      CLR_HINT);
  Footer(E, Slot, W);
end;

{ the reason a player cannot be moved, short enough for the table of /balinfo }
function BalShortNote(const Block: AnsiString): AnsiString;
begin
  if Block = 'carries a flag' then
    Result := 'flag'
  else if Block = 'moved recently' then
    Result := 'moved'
  else if Block = 'being moved' then
    Result := 'moving'
  else if Block = 'carries the team' then
    Result := 'top'
  else
    Result := Block;
end;

procedure CmdBalanceInfo(E: TZSEngine; Slot: LongInt);
const
  W = LINE_W;
  { slot, name, team, strength, rating, games, form, power: 72 of LINE_W, then the note }
  ROW = '%-4s %-24s %-8s %5s %6s %5s %5s %6s  %s';
var
  Cands: TBalCandArray;
  TeamNo: TBalTeamNos;
  N, i, k, S, Games, Spread, Count: LongInt;
  P: TBalParams;
  Ch, Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  D, Skill, Brier: Double;
  Line, Line2, Line3, Note, State: AnsiString;
  Pred: Int64;
begin
  D := E.BalGather(Cands, TeamNo, N, P, Ch);
  BalTotals(Cands, N, Pow, Cnt);
  Spread := BalSpread(Cnt, N);
  Header(E, Slot, 'Team Balance - details', W);
  Out(E, Slot, Format('Settings: method %s, rating %s, act above %s%% until %s%% (gain %s)',
    [LowerCase(E.Cfg.BalanceMethod), LowerCase(E.Cfg.BalanceSkill), FloatStr(E.Cfg.BalanceThreshold, 0),
     FloatStr(E.Cfg.BalanceTarget, 0), FloatStr(E.Cfg.BalanceMinGain, 0)]), CLR_HINT);
  Out(E, Slot, Format('          sustain %ds, cooldown %ds, at most %d moves a map, numbers +-%d',
    [E.Cfg.BalanceSustainSeconds, E.Cfg.BalanceCooldownSeconds, E.Cfg.BalanceMaxMovesPerMap,
     E.Cfg.BalanceMaxCountDiff]), CLR_HINT);
  Out(E, Slot, Format('          joins %s (tolerance %s), map start %s, volunteers %s',
    [BoolToStr(E.Cfg.BalanceAssignJoins, 'placed', 'free'), FloatStr(E.Cfg.BalanceJoinTolerance, 0),
     LowerCase(E.Cfg.BalanceMapStart), BoolToStr(E.Cfg.BalanceVolunteers, 'on', 'off')]), CLR_HINT);
  Out(E, Slot, Format('          protect top %s, SizeImpact %s, SkillPerDouble %s%s',
    [BoolToStr(E.Cfg.BalanceProtectTop, 'on', 'off'), FloatStr(E.BalSizeImpact, 2), FloatStr(E.BalSkillPerDouble, 0),
     BoolToStr(E.Cfg.BalanceAutoTune and (E.Bal.FitCount >= 50), ' (tuned)', '')]), CLR_HINT);
  { in Int64: before the first move LastMoveTick lies far back, and the difference would not fit }
  if Int64(E.GameTick) - E.Bal.LastMoveTick < 86400 * TICKS_PER_SECOND then
    Line := BalSecondsText(E.GameTick - E.Bal.LastMoveTick) + ' ago'
  else
    Line := 'none yet';
  if not E.Cfg.BalanceEnabled then
    State := 'off'
  else if E.Bal.Paused then
    State := 'paused'
  else if E.BalanceActive then
    State := 'running'
  else
    State := 'waiting for a team match';
  Out(E, Slot, Format('State:    %s, moves on this map %d/%d, last move %s',
    [State, E.Bal.MovesThisMap, E.Cfg.BalanceMaxMovesPerMap, Line]), CLR_HINT);
  Out(E, Slot, Format('          median %s, bots %s, imbalance %s (acts above %s)',
    [FloatStr(E.Bal.Median, 0), FloatStr(E.Bal.BotStrength, 0), FloatStr(D * 100, 1),
     FloatStr(E.Cfg.BalanceThreshold - 50, 0)]), CLR_HINT);
  Out(E, Slot, 'Status:   ' + BalStatusText(E, D, Spread, Cands, Ch, TeamNo, N, E.BalHumansOnTeams), WHITE);
  Section(E, Slot, 'Players', W);
  Out(E, Slot, Format(ROW, ['Slot', 'Name', 'Team', 'Str', 'Rating', 'Games', 'Form', 'Power', 'Note']), CLR_SUBHEADER);
  for i := 0 to High(Cands) do
  begin
    S := Cands[i].Id;
    E.BalBase(S, Skill, Games);
    Note := BalShortNote(E.BalBlocker(S));
    if E.BalAfk(S) then
      Note := Trim(Note + ' away');
    Out(E, Slot, TrimRight(Format(ROW, [IntToStr(S), Copy(E.Live[S].Name, 1, 24), BalTeamName(E.Live[S].Team),
      FloatStr(E.BalStrength(S), 0), FloatStr(Skill, 0), IntToStr(Games), FloatStr(E.Bal.Slots[S].Form, 0),
      FloatStr(Cands[i].Power, 2), Note])), WHITE);
  end;
  BalTeamLines(E, Slot, Cands, TeamNo, N, Ch);
  Out(E, Slot, 'Notes: top = best form of its team, moved = recently moved, away = counts less', CLR_HINT);
  Section(E, Slot, 'Predictions', W);
  Pred := E.DB.Server.BalPredCount;
  if Pred > 0 then
  begin
    Brier := E.DB.Server.BalBrierSum / Pred;
    Out(E, Slot, Format('%s matches, Brier score %s (a coin flip is 0.250, lower is better)',
      [Num(Pred), FloatStr(Brier, 3)]), WHITE);
    { the predicted chance of Alpha in tenths, the matches of each tenth and how often Alpha won
      them; a count of its own in each column, so a big one cannot push the columns apart }
    Line := Format('%-10s', ['Chance %']);
    Line2 := Format('%-10s', ['Matches']);
    Line3 := Format('%-10s', ['Alpha won']);
    for k := 0 to 9 do
    begin
      Line := Line + Format('%8s', [Format('%d-%d', [k * 10, k * 10 + 10])]);
      Line2 := Line2 + Format('%8s', [Num(E.DB.Server.BalBinCount[k])]);
      Line3 := Line3 + Format('%8s', [Num(E.DB.Server.BalBinWins[k])]);
    end;
    Out(E, Slot, Line, CLR_SUBHEADER);
    Out(E, Slot, Line2, WHITE);
    Out(E, Slot, Line3, WHITE);
  end
  else
    Out(E, Slot, 'No two-team match was predicted yet.', WHITE);
  Count := E.Bal.HistoryCount;
  if E.Bal.FitCount >= 30 then
  begin
    Out(E, Slot, Format('Best fit (%d matches): SizeImpact %s, SkillPerDouble %s, Brier %s',
      [E.Bal.FitCount, FloatStr(E.Bal.FitSize, 2), FloatStr(E.Bal.FitDouble, 0), FloatStr(E.Bal.FitBrier, 3)]), CLR_HINT);
    if E.Cfg.BalanceAutoTune and (E.Bal.FitCount >= 50) then
      Out(E, Slot, '          in use (AutoTune = 1)', CLR_HINT)
    else if E.Cfg.BalanceAutoTune then
      Out(E, Slot, '          AutoTune uses it from 50 matches', CLR_HINT)
    else
      Out(E, Slot, '          not in use; AutoTune = 1 uses it from 50 matches', CLR_HINT);
  end
  else
    Out(E, Slot, Format('Tuning starts after 30 recorded matches (%d so far).', [Count]), CLR_HINT);
  if N = 2 then
    Out(E, Slot, Format('Map side: Alpha factor %s (from %d decided matches of this map)',
      [FloatStr(E.BalAlphaBias, 2), E.MapDecided]), CLR_HINT);
  Section(E, Slot, 'Last decisions', W);
  Count := 0;
  for k := 0 to High(E.Bal.Log) do
  begin
    Line := E.Bal.Log[(E.Bal.LogNext + k) mod Length(E.Bal.Log)];
    if Line <> '' then
    begin
      Out(E, Slot, Copy(Line, 1, W), WHITE);
      Inc(Count);
    end;
  end;
  if Count = 0 then
    Out(E, Slot, 'None yet.', WHITE);
  Footer(E, Slot, W);
end;
