{ zs_engine_match.inc - maps, matches, rounds and per-second accounting (part of zs_engine) }

function TZSEngine.DailyEntry: LongInt;
var
  Today, n: LongInt;
begin
  Today := DayKey(Now);
  n := Length(DB.Server.Daily);
  if (n > 0) and (DB.Server.Daily[n - 1].Day = Today) then
    Exit(n - 1);
  { a year of daily history is kept }
  if n >= 366 then
  begin
    Move(DB.Server.Daily[1], DB.Server.Daily[0], (n - 1) * SizeOf(TDailyStat));
    Result := n - 1;
  end
  else
  begin
    SetLength(DB.Server.Daily, n + 1);
    Result := n;
  end;
  FillChar(DB.Server.Daily[Result], SizeOf(TDailyStat), 0);
  DB.Server.Daily[Result].Day := Today;
  DB.TouchServer;
end;

{ the team with the most ticks, the first of equal ones; 0 without any }
function MainTeam(const Ticks: TTeamTicks): LongInt;
var
  t, Best: LongInt;
begin
  Result := 0;
  Best := 0;
  for t := TEAM_ALPHA to TEAM_DELTA do
    if Ticks[t] > Best then
    begin
      Best := Ticks[t];
      Result := t;
    end;
end;

function TZSEngine.LeaverIndex(ProfileId: LongInt): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  for k := 0 to High(Match.Leavers) do
    if Match.Leavers[k].ProfileId = ProfileId then
      Exit(k);
end;

{ The account of slot S leaves the running match: its time on each team is kept for the end of the
  match. Leaving, coming back and leaving again is one match: the stays add up in one entry. }
procedure TZSEngine.NoteLeaver(S, ProfileId: LongInt);
var
  k, t, Played: LongInt;
begin
  Played := 0;
  for t := TEAM_ALPHA to TEAM_DELTA do
    Inc(Played, Live[S].TeamTicks[t]);
  if Played <= 0 then
    Exit;
  k := LeaverIndex(ProfileId);
  if k < 0 then
  begin
    k := Length(Match.Leavers);
    SetLength(Match.Leavers, k + 1);
    Match.Leavers[k].ProfileId := ProfileId;
    FillChar(Match.Leavers[k].TeamTicks, SizeOf(Match.Leavers[k].TeamTicks), 0);
  end;
  for t := TEAM_ALPHA to TEAM_DELTA do
    Inc(Match.Leavers[k].TeamTicks[t], Live[S].TeamTicks[t]);
end;

{ the ticks the player of Slot spent on each team in this match: this stay, and the stays the account
  left earlier in the match }
procedure TZSEngine.MatchTicks(Slot: LongInt; out Ticks: TTeamTicks);
var
  t, k, Idx: LongInt;
begin
  for t := TEAM_ALPHA to TEAM_DELTA do
  begin
    Ticks[t] := Live[Slot].TeamTicks[t];
    if Live[Slot].Team = t then
      Inc(Ticks[t], Max(0, GameTick - Live[Slot].TeamSinceTick));
  end;
  Idx := Identity.StatsIndex(Slot);
  if not DB.Valid(Idx) then
    Exit;
  k := LeaverIndex(DB.Profiles[Idx]^.ID);
  if k >= 0 then
    for t := TEAM_ALPHA to TEAM_DELTA do
      Inc(Ticks[t], Match.Leavers[k].TeamTicks[t]);
end;

function TZSEngine.MatchTeamOf(Slot: LongInt): LongInt;
var
  Ticks: TTeamTicks;
begin
  Result := 0;
  if not SlotValid(Slot) then
    Exit;
  MatchTicks(Slot, Ticks);
  Result := MainTeam(Ticks);
end;

{ Hold the Flag scores a point for the team that holds the yellow flag at that moment, and the score
  is looked at once a second. The point goes to the human of Team who carried the flag since that
  last look (Since): the carrier now, else the one who lost it after Since - a point scored a moment
  before the carrier died or threw the flag is still his. The flag events give the grab and the drop
  to the tick; the position samples (five a second) cover a carrier whose grab the script did not
  see. 0 = no human carried it (a bot). }
function TZSEngine.HtfCarrier(Team, Since: LongInt): LongInt;
var
  S, Lost: LongInt;
begin
  Result := 0;
  Lost := 0;
  for S := 1 to MAX_PLAYERS do
  begin
    if not Live[S].Active or not Live[S].Human or (Live[S].Team <> Team) then
      Continue;
    { carrying it now: a grab after the last sample and no drop since, or the last sample says so
      and no drop came after it }
    if Live[S].Alive and
       (((Live[S].FlagGrabTick > Live[S].FlagDropTick) and (Live[S].FlagGrabTick >= Live[S].SampleTick)) or
        ((Live[S].Flags and EF_A_FLAGGER <> 0) and (Live[S].FlagDropTick < Live[S].SampleTick))) then
      Exit(S);
    if (Live[S].FlagDropTick > Since) and (Live[S].FlagDropTick >= Live[S].FlagGrabTick) and
       (Live[S].FlagDropTick > Lost) then
    begin
      Lost := Live[S].FlagDropTick;
      Result := S;
    end;
  end;
end;

{ Whether players stay after a map: the players on the teams when it ended are looked at again
  STAY_CHECK_TICKS into the next map. A player who left and came back in between did not stay. }
procedure TZSEngine.StartStayCheck;
var
  S: LongInt;
begin
  FStay.MapIndex := -1;
  if (Match.MapIndex < 0) or (Match.MapIndex >= DB.MapCount) or not StatsOn then
    Exit;
  FStay.Humans := 0;
  for S := 1 to MAX_PLAYERS do
  begin
    FStay.Present[S] := Live[S].Active and Live[S].Human and (Live[S].Team <> TEAM_SPEC);
    if FStay.Present[S] then
      Inc(FStay.Humans);
  end;
  if FStay.Humans > 0 then
  begin
    FStay.MapIndex := Match.MapIndex;
    FStay.EndTick := GameTick;
  end;
end;

procedure TZSEngine.FinishStayCheck;
var
  S, M, Stayed: LongInt;
begin
  M := FStay.MapIndex;
  FStay.MapIndex := -1;
  if (M < 0) or (M >= DB.MapCount) then
    Exit;
  Stayed := 0;
  for S := 1 to MAX_PLAYERS do
    if FStay.Present[S] and Live[S].Active and Live[S].Human and (Live[S].JoinTick <= FStay.EndTick) then
      Inc(Stayed);
  Inc(DB.Maps[M].EndHumansSum, FStay.Humans);
  Inc(DB.Maps[M].StayedHumansSum, Stayed);
  Inc(DB.Maps[M].RetentionCount);
  DB.TouchMap(M);
end;

procedure TZSEngine.UpdatePeakOnline;
var
  Count, D, Dur: LongInt;
begin
  Count := HumansOnline;
  D := DailyEntry;
  if Count > DB.Server.Daily[D].PeakOnline then
  begin
    DB.Server.Daily[D].PeakOnline := Count;
    DB.TouchServer;
  end;
  if Count > DB.Server.PeakOnlineCount then
  begin
    DB.Server.PeakOnlineCount := Count;
    DB.Server.PeakOnlineDate := Now;
    DB.Server.PeakOnlineDurationSec := 1;
    FPeakSince := Now;
    DB.TouchServer;
  end
  else if (Count = DB.Server.PeakOnlineCount) and (Count > 0) and (FPeakSince > 0) then
  begin
    Dur := Round((Now - FPeakSince) * 86400);
    if Dur > DB.Server.PeakOnlineDurationSec then
    begin
      DB.Server.PeakOnlineDurationSec := Dur;
      DB.TouchServer;
    end;
  end
  else if Count < DB.Server.PeakOnlineCount then
    FPeakSince := 0;
end;

procedure TZSEngine.BeginMatch(const MapName: AnsiString; GameStyle, ScoreLimit, TimeLimit, Flags: LongInt);
var
  S, M: LongInt;
begin
  if Match.Active then
    EndMatch(False);
  Inc(FMapSerial);
  Match.Active := True;
  Match.MapName := MapName;
  Match.MapIndex := DB.FindMap(MapName, True);
  Match.GameStyle := GameStyle;
  Match.ScoreLimit := ScoreLimit;
  Match.TimeLimit := TimeLimit;
  Match.Survival := Flags and MF_SURVIVAL <> 0;
  Match.Realistic := Flags and MF_REALISTIC <> 0;
  Match.Advance := Flags and MF_ADVANCE <> 0;
  Match.FriendlyFire := Flags and MF_FRIENDLYFIRE <> 0;
  Match.StartTick := GameTick;
  Match.StartTime := Now;
  FillChar(Match.TeamScore, SizeOf(Match.TeamScore), 0);
  Match.ScoreTick := GameTick;
  FillChar(Match.MaxDeficit, SizeOf(Match.MaxDeficit), 0);
  Match.TimeLeft := 0;
  Match.FirstBlood := False;
  Match.RoundFirstBlood := False;
  Match.FirstDamage := False;
  FillChar(Match.LastStandGiven, SizeOf(Match.LastStandGiven), 0);
  Match.ClutchSlot := 0;
  Match.ClutchProfile := 0;
  { a round cut short by the map change is no round; the spawns on the new map start the next }
  Match.RoundOver := False;
  Match.RoundPending := False;
  FillChar(Match.RoundIn, SizeOf(Match.RoundIn), 0);
  Match.Leavers := nil;
  Match.HumansMax := HumansOnline;
  Match.LastVoteMap := '';
  Match.LastVoteTick := 0;
  Match.TotalSeconds := 0;
  Match.CaptureTick := 0;
  Match.RoundLive := False;
  M := Match.MapIndex;
  if M >= 0 then
  begin
    Inc(DB.Maps[M].LoadCount);
    { the map runs, whoever plays; LastPlayedTime follows the seconds played with the statistics
      on (SecondAccounting) }
    DB.Maps[M].LastLoadedTime := Now;
    DB.TouchMap(M);
  end;
  LiveResetMatch(Live, GameTick);
  { the session (!session) goes on across maps; only the match counters start again. The players
    the map change respawned (still alive after LiveResetMatch) are in the first round. }
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active then
    begin
      if DB.Valid(Identity.ProfileIndex(S)) then
        Live[S].MatchStartPoints := DB.Profiles[Identity.ProfileIndex(S)]^.Points;
      if Live[S].Alive then
        RoundJoin(S);
    end;
  LoadWeaponsForMode;
  ReloadForgetAll;
  BalMapStart;
end;

procedure TZSEngine.EvMapAfter(var E: TZSEvent);
begin
  MapVoteOnMapAfter(E.S1);
  BeginMatch(E.S1, E.I[0], E.I[1], E.I[2], E.I[3]);
end;

procedure TZSEngine.EvPlayerScore(var E: TZSEvent);
begin
  if SlotValid(E.Slot) then
    Live[E.Slot].MatchScore := E.I[0];
end;

procedure TZSEngine.EvMapBefore(var E: TZSEvent);
var
  T, S, Best, M: LongInt;
  Completed: Boolean;
begin
  { the map vote: a vote that runs is over, a passed one has its change }
  MapVoteOnMapBefore;
  if not Match.Active then
    Exit;
  { the map changes to the map a vote asked for: the vote was won }
  if (Match.LastVoteMap <> '') and SameText(Trim(E.S1), Match.LastVoteMap) and
     (GameTick - Match.LastVoteTick <= VOTE_PASS_TICKS) then
  begin
    M := Match.MapIndex;
    if (M >= 0) and (M < DB.MapCount) then
    begin
      Inc(DB.Maps[M].VotesPassed);
      DB.TouchMap(M);
    end;
    M := DB.FindMap(Match.LastVoteMap, True);
    if M >= 0 then
    begin
      Inc(DB.Maps[M].VotedIn);
      DB.TouchMap(M);
    end;
  end;
  Match.LastVoteMap := '';
  { a map shorter than the check: the previous map's players are counted now }
  FinishStayCheck;
  StartStayCheck;
  MxMapBefore(Self, E);
  for T := 1 to 4 do
    Match.TeamScore[T] := E.I[T - 1];
  Match.TimeLeft := E.I[4];
  if E.I[5] > 0 then
    Match.ScoreLimit := E.I[5];
  Best := 0;
  if TeamGame then
  begin
    for T := 1 to 4 do
      Best := Max(Best, Match.TeamScore[T]);
  end
  else
    for S := 1 to MAX_PLAYERS do
      if Live[S].Active then
        Best := Max(Best, Max(Live[S].MatchScore, Live[S].MatchKills));
  { a map left before the time or the score limit was reached is not a finished match }
  Completed := (Match.TimeLeft <= 2) or ((Match.ScoreLimit > 0) and (Best >= Match.ScoreLimit));
  EndMatch(Completed);
end;

procedure TZSEngine.EndMatch(Completed: Boolean);
var
  S, T, U, Idx, k, n, M, WinTeam, Best, Second, BestSlot, BestScore, BestDeaths, Family, Score, Rated: LongInt;
  DurTicks, Need, PlayTicks, KeptTicks: LongInt;
  IsDraw, Tied: Boolean;
  Players, Teams, Scores: TIntArray;
  Weights: array of Double;
  P: PPlayerProfile;
  TeamScores: array[0..3] of LongInt;
  Ticks: TTeamTicks;
begin
  { a survival round decided in the last tick of the map still counts }
  RoundSettle;
  if not Match.Active then
    Exit;
  Match.Active := False;
  M := Match.MapIndex;
  if M >= DB.MapCount then
    M := -1;
  DurTicks := Max(0, GameTick - Match.StartTick);
  if M >= 0 then
  begin
    { the length of a match is learned from finished matches: a map left after a few seconds
      says nothing about how long a match on it lasts }
    if Completed then
    begin
      Inc(DB.Maps[M].MatchDurationSum, DurTicks div TICKS_PER_SECOND);
      Inc(DB.Maps[M].MatchDurationCount);
    end
    else
      Inc(DB.Maps[M].MatchesAborted);
    DB.TouchMap(M);
  end;
  if not (Completed or Cfg.CountAbortedMatches) or not StatsOn or
     (DurTicks < Cfg.MinParticipationSeconds * TICKS_PER_SECOND) then
    Exit;

  for S := 1 to MAX_PLAYERS do
    if Live[S].Active then
      LiveCloseTeamTime(Live[S], GameTick);
  Need := Max(Cfg.MinParticipationSeconds * TICKS_PER_SECOND, DurTicks * Cfg.MinParticipationPercent div 100);
  Family := FamilyFor(Cfg, Match.GameStyle);
  Players := nil;
  Teams := nil;
  Weights := nil;
  Rated := 0;
  BalanceMatchEnd(Completed);

  if TeamGame then
  begin
    WinTeam := 0;
    Best := -1;
    IsDraw := False;
    for T := 1 to 4 do
      if Match.TeamScore[T] > Best then
      begin
        Best := Match.TeamScore[T];
        WinTeam := T;
        IsDraw := False;
      end
      else if Match.TeamScore[T] = Best then
        IsDraw := True;
    Second := -1;
    for T := 1 to 4 do
      if (T <> WinTeam) and (Match.TeamScore[T] > Second) then
        Second := Match.TeamScore[T];

    for S := 1 to MAX_PLAYERS do
    begin
      if not Live[S].Active or not Live[S].Human then
        Continue;
      Idx := Identity.StatsIndex(S);
      { this stay and the ones the account left earlier in the match count together }
      MatchTicks(S, Ticks);
      T := MatchTeamOf(S);
      PlayTicks := 0;
      for U := TEAM_ALPHA to TEAM_DELTA do
        Inc(PlayTicks, Ticks[U]);
      { the playing time counts on all teams together; the result goes to the team played longest }
      if not DB.Valid(Idx) or (T < TEAM_ALPHA) or (PlayTicks < Need) then
        Continue;
      P := DB.Profiles[Idx];
      if IsDraw then
      begin
        Inc(P^.Draws);
        AddActivity(DB, Idx, Match.GameStyle, 0, 0, 0, 0, 0, 1, 0, 0);
      end
      else if T = WinTeam then
      begin
        Inc(P^.Wins);
        Inc(Live[S].SessionWins);
        case T of
          TEAM_ALPHA: Inc(P^.AlphaWins);
          TEAM_BRAVO: Inc(P^.BravoWins);
          TEAM_CHARLIE: Inc(P^.CharlieWins);
          TEAM_DELTA: Inc(P^.DeltaWins);
        end;
        if Match.MaxDeficit[T] >= 2 then
          Inc(P^.ComebackWins);
        AddActivity(DB, Idx, Match.GameStyle, 0, 0, 0, 1, 0, 0, 0, 0);
      end
      else
      begin
        Inc(P^.Loses);
        case T of
          TEAM_ALPHA: Inc(P^.AlphaLoses);
          TEAM_BRAVO: Inc(P^.BravoLoses);
          TEAM_CHARLIE: Inc(P^.CharlieLoses);
          TEAM_DELTA: Inc(P^.DeltaLoses);
        end;
        AddActivity(DB, Idx, Match.GameStyle, 0, 0, 0, 0, 1, 0, 0, 0);
      end;
      MxMatchResult(Self, Idx, IsDraw, T = WinTeam, T);
      { the rating counts every team the player played for, by the share of the time spent there
        (a part under 5% is left out) }
      KeptTicks := 0;
      for U := TEAM_ALPHA to TEAM_DELTA do
        if Ticks[U] * 20 >= PlayTicks then
          Inc(KeptTicks, Ticks[U]);
      for U := TEAM_ALPHA to TEAM_DELTA do
        if (Ticks[U] * 20 >= PlayTicks) and (KeptTicks > 0) then
        begin
          n := Length(Players);
          SetLength(Players, n + 1);
          SetLength(Teams, n + 1);
          SetLength(Weights, n + 1);
          Players[n] := Idx;
          Teams[n] := U;
          Weights[n] := Ticks[U] / KeptTicks;
        end;
      Inc(Rated);
      DB.Touch(Idx);
      AfterProfileChange(Idx);
    end;

    { leaving a lost match after playing a good part of it still counts as a loss. Leaving, coming
      back and leaving again is one match and one loss: the stays of an account are one entry, their
      time adds up, and the team is the one played longest. An account that is back on the server is
      judged above instead, with these stays added to the one it plays now. }
    if Cfg.LeaverCountsAsLoss and not IsDraw then
      for k := 0 to High(Match.Leavers) do
      begin
        T := MainTeam(Match.Leavers[k].TeamTicks);
        if (T < TEAM_ALPHA) or (T = WinTeam) or
           (Match.Leavers[k].TeamTicks[T] < DurTicks * Cfg.LeaverMinProgressPercent div 100) then
          Continue;
        Idx := DB.IndexOfId(Match.Leavers[k].ProfileId);
        if not DB.Valid(Idx) or (Identity.SlotOfProfile(Match.Leavers[k].ProfileId) > 0) then
          Continue;
        P := DB.Profiles[Idx];
        Inc(P^.Loses);
        Inc(P^.LeaveLosses);
        case T of
          TEAM_ALPHA: Inc(P^.AlphaLoses);
          TEAM_BRAVO: Inc(P^.BravoLoses);
          TEAM_CHARLIE: Inc(P^.CharlieLoses);
          TEAM_DELTA: Inc(P^.DeltaLoses);
        end;
        AddActivity(DB, Idx, Match.GameStyle, 0, 0, 0, 0, 1, 0, 0, 0);
        MxMatchResult(Self, Idx, False, False, T, True);
        DB.Touch(Idx);
      end;

    for T := 0 to 3 do
      TeamScores[T] := Match.TeamScore[T + 1];
    if Rated >= 2 then
      RateTeams(DB, Cfg, Family, Players, Teams, Weights, TeamScores);

    if M >= 0 then
    begin
      if IsDraw then
        Inc(DB.Maps[M].Draws)
      else
        case WinTeam of
          TEAM_ALPHA: Inc(DB.Maps[M].AlphaWins);
          TEAM_BRAVO: Inc(DB.Maps[M].BravoWins);
          TEAM_CHARLIE: Inc(DB.Maps[M].CharlieWins);
          TEAM_DELTA: Inc(DB.Maps[M].DeltaWins);
        end;
      if IsDraw or (Best - Second <= 1) then
        Inc(DB.Maps[M].CloseMatches);
      Inc(DB.Maps[M].ScoreSum, Max(0, Best));
      Inc(DB.Maps[M].ScoreCount);
      if not IsDraw and (Match.MaxDeficit[WinTeam] >= 2) then
        Inc(DB.Maps[M].ComebackMatches);
    end;
    if Cfg.RoundWinBroadcast and not IsDraw and (WinTeam > 0) then
      Broadcast(Format('Match over: %s wins %d:%d', [TeamTitle(WinTeam), Best, Max(Second, 0)]), CLR_MATCHES);
  end
  else
  begin
    BestSlot := 0;
    BestScore := -1;
    BestDeaths := MaxInt;
    Tied := False;
    for S := 1 to MAX_PLAYERS do
    begin
      if not Live[S].Active or not Live[S].Human then
        Continue;
      Idx := Identity.StatsIndex(S);
      PlayTicks := 0;
      for T := 0 to 4 do
        Inc(PlayTicks, Live[S].TeamTicks[T]);
      if not DB.Valid(Idx) or (PlayTicks < Need) then
        Continue;
      Score := Max(Live[S].MatchScore, Live[S].MatchKills);
      { Pointmatch pays bonus points for special kills; the scoreboard shows them, the kill
        counter does not, so the difference is the bonus this player earned }
      if (Match.GameStyle = GS_PM) and (Live[S].MatchScore > Live[S].MatchKills) then
      begin
        Inc(DB.Profiles[Idx]^.PointmatchMode.ExtraPoints, Live[S].MatchScore - Live[S].MatchKills);
        DB.Touch(Idx);
      end;
      n := Length(Players);
      SetLength(Players, n + 1);
      SetLength(Scores, n + 1);
      SetLength(Teams, n + 1);
      Players[n] := Idx;
      Scores[n] := Score;
      Teams[n] := S;
      if (Score > BestScore) or ((Score = BestScore) and (Live[S].MatchDeaths < BestDeaths)) then
      begin
        { a new leader: whoever was tied before is behind now }
        Tied := False;
        BestSlot := S;
        BestScore := Score;
        BestDeaths := Live[S].MatchDeaths;
      end
      else if (Score = BestScore) and (Live[S].MatchDeaths = BestDeaths) then
        Tied := True;
    end;
    if Tied and (Length(Players) >= 2) then
    begin
      { nobody was better than the rest: everybody gets a draw }
      for k := 0 to High(Players) do
      begin
        Inc(DB.Profiles[Players[k]]^.Draws);
        AddActivity(DB, Players[k], Match.GameStyle, 0, 0, 0, 0, 0, 1, 0, 0);
        MxMatchResult(Self, Players[k], True, False);
        DB.Touch(Players[k]);
        AfterProfileChange(Players[k]);
      end;
      if Cfg.RoundWinBroadcast then
        Broadcast(Format('Match over: a draw with %d', [Max(0, BestScore)]), CLR_MATCHES);
    end
    else if (BestSlot > 0) and (Length(Players) >= 2) then
    begin
      for k := 0 to High(Players) do
      begin
        P := DB.Profiles[Players[k]];
        if Teams[k] = BestSlot then
        begin
          Inc(P^.Wins);
          Inc(Live[BestSlot].SessionWins);
          AddActivity(DB, Players[k], Match.GameStyle, 0, 0, 0, 1, 0, 0, 0, 0);
        end
        else
        begin
          Inc(P^.Loses);
          AddActivity(DB, Players[k], Match.GameStyle, 0, 0, 0, 0, 1, 0, 0, 0);
        end;
        MxMatchResult(Self, Players[k], False, Teams[k] = BestSlot);
        DB.Touch(Players[k]);
        AfterProfileChange(Players[k]);
      end;
      RateFFA(DB, Cfg, Family, Players, Scores);
      if M >= 0 then
      begin
        Inc(DB.Maps[M].ScoreSum, Max(0, BestScore));
        Inc(DB.Maps[M].ScoreCount);
      end;
      if Cfg.RoundWinBroadcast then
        Broadcast(Format('Match over: %s wins with %d', [Live[BestSlot].Name, BestScore]), CLR_MATCHES);
    end;
  end;

  if M >= 0 then
  begin
    Inc(DB.Maps[M].ActiveMapPlays);
    DB.Maps[M].LastPlayedTime := Now;
    DB.TouchMap(M);
  end;
  if not FReadOnly then
    WebhookMatch(Self);
  Inc(DB.Server.TotalMatches);
  DB.TouchServer;
  Match.Leavers := nil;
end;

procedure TZSEngine.RoundEnd(WinTeam: LongInt);
var
  S, Idx, T, M: LongInt;
  P: PPlayerProfile;
  Opponents: Boolean;
begin
  { how the round ended, for the map (zs_engine_matrix.inc) }
  MxRoundEnd(Self, WinTeam);
  { the server also hands a round to a team that plays alone: a round against nobody is none }
  Opponents := False;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and (Live[S].Team >= TEAM_ALPHA) and (Live[S].Team <= TEAM_DELTA) and
       (Live[S].Team <> WinTeam) then
      Opponents := True;
  if StatsOn and Opponents then
  begin
    for S := 1 to MAX_PLAYERS do
    begin
      if not Live[S].Active or not Live[S].Human then
        Continue;
      T := Live[S].Team;
      if (T < TEAM_ALPHA) or (T > TEAM_DELTA) then
        Continue;
      Idx := Identity.StatsIndex(S);
      if not DB.Valid(Idx) then
        Continue;
      P := DB.Profiles[Idx];
      if T = WinTeam then
      begin
        Inc(P^.RoundsWins);
        Inc(Live[S].SessionRoundWins);
        Inc(Live[S].MatchRoundWins);
        case T of
          TEAM_ALPHA: Inc(P^.RoundsAlphaWins);
          TEAM_BRAVO: Inc(P^.RoundsBravoWins);
          TEAM_CHARLIE: Inc(P^.RoundsCharlieWins);
          TEAM_DELTA: Inc(P^.RoundsDeltaWins);
        end;
        if Match.Advance then
          Inc(P^.AdvanceRoundsWon);
        { the account has to be the one that survived: the slot may hold somebody else by now }
        if (S = Match.ClutchSlot) and (Match.ClutchProfile <> 0) and (P^.ID = Match.ClutchProfile) then
        begin
          Inc(P^.ClutchesWon);
          HudEvent(S, 'Clutch won!');
        end;
        { round and clutch achievements unlock with the round, not with the next kill }
        AfterProfileChange(Idx);
      end
      else
      begin
        Inc(P^.RoundsLose);
        case T of
          TEAM_ALPHA: Inc(P^.RoundsAlphaLoses);
          TEAM_BRAVO: Inc(P^.RoundsBravoLoses);
          TEAM_CHARLIE: Inc(P^.RoundsCharlieLoses);
          TEAM_DELTA: Inc(P^.RoundsDeltaLoses);
        end;
      end;
      MxRound(Self, Idx, T = WinTeam, S);
      if Match.Advance then
        Inc(P^.AdvanceRoundsPlayed);
      DB.Touch(Idx);
    end;
    M := Match.MapIndex;
    if (M >= 0) and (M < DB.MapCount) then
    begin
      case WinTeam of
        TEAM_ALPHA: Inc(DB.Maps[M].AlphaRoundWins);
        TEAM_BRAVO: Inc(DB.Maps[M].BravoRoundWins);
        TEAM_CHARLIE: Inc(DB.Maps[M].CharlieRoundWins);
        TEAM_DELTA: Inc(DB.Maps[M].DeltaRoundWins);
      end;
      DB.TouchMap(M);
    end;
    if Cfg.RoundWinBroadcast and (WinTeam >= TEAM_ALPHA) and (WinTeam <= TEAM_DELTA) then
    begin
      if SlotValid(Match.ClutchSlot) and (Live[Match.ClutchSlot].Team = WinTeam) and
         (Match.ClutchProfile <> 0) and DB.Valid(Identity.StatsIndex(Match.ClutchSlot)) and
         (DB.Profiles[Identity.StatsIndex(Match.ClutchSlot)]^.ID = Match.ClutchProfile) then
        Broadcast(Format('Round won by %s - clutch by %s!', [TeamTitle(WinTeam), Live[Match.ClutchSlot].Name]), CLR_MATCHES)
      else
        Broadcast('Round won by ' + TeamTitle(WinTeam), CLR_MATCHES);
    end;
  end;
  RoundReset;
end;

{ what belongs to one survival round: the round's first blood, first damage and the last stands
  start again; the first blood of the match stays given until the next match }
procedure TZSEngine.RoundReset;
begin
  Match.ClutchSlot := 0;
  Match.ClutchProfile := 0;
  FillChar(Match.LastStandGiven, SizeOf(Match.LastStandGiven), 0);
  Match.RoundFirstBlood := False;
  Match.FirstDamage := False;
end;

{ Free-for-all survival: the humans who spawn in a round take part in it; the first spawn after a
  round ended starts the next one. }
procedure TZSEngine.RoundJoin(S: LongInt);
begin
  if not Match.Survival or TeamGame or not Live[S].Human then
    Exit;
  { a spawn in the very tick that decided the last round: that round is settled first }
  RoundSettle;
  if Match.RoundOver then
  begin
    Match.RoundOver := False;
    FillChar(Match.RoundIn, SizeOf(Match.RoundIn), 0);
  end;
  Match.RoundIn[S] := True;
end;

{ Free-for-all survival (Deathmatch, Pointmatch, Rambomatch): after every death the server ends the
  round once at most one player is left standing, and kills that one itself five seconds later. So
  the round is over when at most one of the humans who spawned in it still lives; who that is, is
  settled once the other deaths of the same tick are in (two players can kill each other at once).
  Bots send no spawn and no position, so whether a bot lives is not known: with a bot in the game
  the round is over only when none of the humans lives any more, and the one the server killed at
  its end (ServerWinner, 0 = the check after a death) is the last one standing. Team games count
  their rounds in EvTick; here only from that kill of the server. }
procedure TZSEngine.RoundCheck(ServerWinner: LongInt);
var
  S, T, Alive: LongInt;
  Bots: Boolean;
begin
  if not Match.Active or not Match.Survival or Match.RoundOver then
    Exit;
  if TeamGame then
  begin
    { Teammatch and Hold the Flag: the server kills the survivors of the winning team when the
      round is over. EvTick sees the end first unless a bot keeps the losing team standing in its
      count. Capture the Flag and Infiltration kill both teams after a capture, so such a kill
      says nothing there: their rounds come from the score and the capture. }
    if (ServerWinner > 0) and ((Match.GameStyle = GS_TM) or (Match.GameStyle = GS_HTF)) and StatsOn then
    begin
      T := Live[ServerWinner].Team;
      if (T >= TEAM_ALPHA) and (T <= TEAM_DELTA) then
      begin
        RoundEnd(T);
        Match.RoundOver := True;
      end;
    end;
    Exit;
  end;
  { a player whose spawn in this round was not seen did not take part in it }
  if (ServerWinner > 0) and not Match.RoundIn[ServerWinner] then
    ServerWinner := 0;
  Alive := 0;
  Bots := False;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and (Live[S].Team <> TEAM_SPEC) then
    begin
      if not Live[S].Human then
        Bots := True
      else if Match.RoundIn[S] and Live[S].Alive then
        Inc(Alive);
    end;
  if ServerWinner > 0 then
  begin
    { the server kills the last one standing only; with others of the round still alive this is
      no end of a round the engine can tell the winner of }
    if Alive > 0 then
      Exit;
    Match.RoundOver := True;
    RoundEndFfa(ServerWinner);
    Exit;
  end;
  if (Alive >= 2) or ((Alive = 1) and Bots) then
    Exit;
  Match.RoundOver := True;
  Match.RoundPending := True;
  Match.RoundTick := GameTick;
end;

{ the round RoundCheck decided: the one of it still alive won, nobody when none is }
procedure TZSEngine.RoundSettle;
var
  S, Alive, Survivor: LongInt;
begin
  if not Match.RoundPending then
    Exit;
  Match.RoundPending := False;
  Alive := 0;
  Survivor := 0;
  for S := 1 to MAX_PLAYERS do
    if Match.RoundIn[S] and Live[S].Active and Live[S].Human and Live[S].Alive and (Live[S].Team <> TEAM_SPEC) then
    begin
      Inc(Alive);
      Survivor := S;
    end;
  if Alive <> 1 then
    Survivor := 0;
  RoundEndFfa(Survivor);
end;

{ Free-for-all survival: the last one standing (WinSlot, 0 = nobody: the last ones died together,
  or a bot won) won the round, every other human who took part lost it. Only with at least two
  humans in the round and the survival statistics on (MinHumansForSurvival). With at least
  [Mechanics] LastStandMinPlayers of them the winner is also the last man standing (LastStand): one
  against one is a round won, no last stand. A clutch - the last of a team winning against the
  odds - has no meaning without teams. }
procedure TZSEngine.RoundEndFfa(WinSlot: LongInt);
var
  S, Idx, Players: LongInt;
  P: PPlayerProfile;
begin
  Players := 0;
  for S := 1 to MAX_PLAYERS do
    if Match.RoundIn[S] and Live[S].Active and Live[S].Human then
      Inc(Players);
  if (Players >= 2) and SurvivalOn then
  begin
    for S := 1 to MAX_PLAYERS do
    begin
      if not Match.RoundIn[S] or not Live[S].Active or not Live[S].Human then
        Continue;
      Idx := Identity.StatsIndex(S);
      if not DB.Valid(Idx) then
        Continue;
      P := DB.Profiles[Idx];
      if S = WinSlot then
      begin
        Inc(P^.RoundsWins);
        Inc(Live[S].SessionRoundWins);
        Inc(Live[S].MatchRoundWins);
        if Players >= Cfg.LastStandMinPlayers then
        begin
          Inc(P^.LastStand);
          HudEvent(S, 'Last man standing!');
        end;
        if Match.Advance then
          Inc(P^.AdvanceRoundsWon);
      end
      else
        Inc(P^.RoundsLose);
      MxRound(Self, Idx, S = WinSlot);
      if (S = WinSlot) and (Players >= Cfg.LastStandMinPlayers) then
        MxLastStand(Self, Idx);
      if Match.Advance then
        Inc(P^.AdvanceRoundsPlayed);
      DB.Touch(Idx);
      if S = WinSlot then
        AfterProfileChange(Idx);
    end;
    MxRoundEndFfa(Self, WinSlot);
    if Cfg.RoundWinBroadcast and (WinSlot > 0) then
      Broadcast('Round won by ' + Live[WinSlot].Name, CLR_MATCHES);
  end;
  RoundReset;
end;

procedure TZSEngine.EvTick(var E: TZSEvent);
var
  T, S, MaxLead, Delta, Holder, Idx, k: LongInt;
  NewScore: array[1..4] of LongInt;
  AliveTeam: array[0..5] of LongInt;
  P: PPlayerProfile;
begin
  ReloadDeadlines(E.Tick);
  for T := 1 to 4 do
    NewScore[T] := E.I[T - 1];
  Match.TimeLeft := E.I[4];
  { Game.TimeLeft is 60 * minutes + seconds, so the whole match lasts the time left plus the time
    already played }
  if Match.Active and (E.I[4] > 0) then
    Match.TotalSeconds := E.I[4] + Max(0, GameTick - Match.StartTick) div TICKS_PER_SECOND;
  if (FStay.MapIndex >= 0) and (GameTick - FStay.EndTick >= STAY_CHECK_TICKS) then
    FinishStayCheck;

  if Match.Active and StatsOn and TeamGame then
  begin
    if Match.Survival then
    begin
      if Match.GameStyle = GS_CTF then
      begin
        { a survival round of CTF ends with a capture or with a wiped out team, and the server
          gives the team a point for both }
        for T := 1 to 4 do
          if NewScore[T] > Match.TeamScore[T] then
            RoundEnd(T);
      end
      else
      begin
        { Infiltration and Hold the Flag score by time, Teammatch by kills, so the score says
          nothing about the rounds: the round is over when only one team is still standing. A bot
          sends no spawn and no position, so a team with a bot may still stand; a round such a team
          loses ends with the server's kill of the winners (RoundCheck), and a capture in
          Infiltration ends one at once (EvFlag). }
        FillChar(AliveTeam, SizeOf(AliveTeam), 0);
        for S := 1 to MAX_PLAYERS do
          if Live[S].Active and (Live[S].Alive or not Live[S].Human) and (Live[S].Team >= TEAM_ALPHA) and
             (Live[S].Team <= TEAM_DELTA) then
            Inc(AliveTeam[Live[S].Team]);
        k := 0;
        Holder := 0;
        for T := TEAM_ALPHA to TEAM_DELTA do
          if AliveTeam[T] > 0 then
          begin
            Inc(k);
            Holder := T;
          end;
        if k >= 2 then
          Match.RoundOver := False
        else if (k = 1) and not Match.RoundOver then
        begin
          RoundEnd(Holder);
          Match.RoundOver := True;
        end;
      end;
      { a round with nobody left standing, for the map (zs_engine_matrix.inc) }
      MxSurvivalTick(Self);
    end;

    { HTF points: credited to the human of the scoring team who carried the flag since the last look
      at the score }
    if Match.GameStyle = GS_HTF then
      for T := TEAM_ALPHA to TEAM_BRAVO do
      begin
        Delta := NewScore[T] - Match.TeamScore[T];
        if Delta <= 0 then
          Continue;
        Holder := HtfCarrier(T, Match.ScoreTick);
        for S := 1 to MAX_PLAYERS do
        begin
          if not Live[S].Active or not Live[S].Human or (Live[S].Team <> T) then
            Continue;
          Idx := Identity.StatsIndex(S);
          if not DB.Valid(Idx) then
            Continue;
          P := DB.Profiles[Idx];
          if S = Holder then
          begin
            Inc(P^.HTFMode.PointsScored, Delta);
            if T = TEAM_ALPHA then
              Inc(P^.HTFMode.AlphaPointsScored, Delta)
            else
              Inc(P^.HTFMode.BravoPointsScored, Delta);
            MxHtfPoints(Self, Idx, Delta);
          end;
          Inc(P^.HTFMode.TeamPointsScored, Delta);
          if T = TEAM_ALPHA then
            Inc(P^.HTFMode.AlphaTeamPointsScored, Delta)
          else
            Inc(P^.HTFMode.BravoTeamPointsScored, Delta);
          DB.Touch(Idx);
        end;
      end;

    MaxLead := 0;
    for T := 1 to 4 do
      MaxLead := Max(MaxLead, NewScore[T]);
    for T := 1 to 4 do
      Match.MaxDeficit[T] := Max(Match.MaxDeficit[T], MaxLead - NewScore[T]);
  end;
  for T := 1 to 4 do
    Match.TeamScore[T] := NewScore[T];
  Match.ScoreTick := GameTick;

  SecondAccounting;
  UpdatePeakOnline;
  BalanceSecond;
  MapVoteSecond;
  { !lastfight: the deaths whose seconds after them are over }
  LastFightSecond(Self);
  for k := 1 to MAX_PLAYERS do
    if Live[k].Active and Live[k].Human then
    begin
      if not Extra[k].Welcomed then
        WelcomePlayer(k);
      RefreshHud(k, False);
    end;
end;

procedure TZSEngine.SecondAccounting;
var
  S, Idx, D, M, W, Humans, T, B: LongInt;
  P: PPlayerProfile;
  H, Mi, Se, Ms: Word;
  Dow, Today: LongInt;
  TeamFlag: array[0..5] of Boolean;
  On, Survive: Boolean;
  { [Matrix]: the counters of the player before the second counts }
  MxS: TMxSnap;
begin
  Humans := HumansPlaying;
  On := StatsOn;
  Survive := SurvivalOn;
  M := Match.MapIndex;
  if M >= DB.MapCount then
    M := -1;
  DecodeTime(Now, H, Mi, Se, Ms);
  Dow := DayOfWeek(Now) - 1;
  Today := DayKey(Now);
  D := DailyEntry;
  { how many play at which part of the match, counted whenever somebody plays }
  if Match.Active and (M >= 0) and (Match.TotalSeconds > 0) and (Humans > 0) then
  begin
    B := EnsureRange(Max(0, GameTick - Match.StartTick) div TICKS_PER_SECOND * 10 div Match.TotalSeconds, 0, 9);
    Inc(DB.Maps[M].CurveSum[B], Humans);
    Inc(DB.Maps[M].CurveSecs[B]);
    DB.TouchMap(M);
  end;
  if On then
  begin
    if M >= 0 then
    begin
      Inc(DB.Maps[M].ActiveTimePlays);
      Inc(DB.Maps[M].HumansSampleSum, Humans);
      Inc(DB.Maps[M].HumansSampleCount);
      { played with the statistics on (LastLoadedTime: the map ran at all) }
      DB.Maps[M].LastPlayedTime := Now;
      DB.TouchMap(M);
    end;
    Inc(DB.Server.HourlyActivity[H], Humans);
    Inc(DB.Server.WeekdayHour[Dow, H], Humans);
    Inc(DB.Server.Daily[D].PlaySeconds, Humans);
    DB.TouchServer;
  end;

  FillChar(TeamFlag, SizeOf(TeamFlag), 0);
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Alive and (Live[S].Flags and EF_A_FLAGGER <> 0) and (Live[S].Team >= 0) and (Live[S].Team <= 5) then
      TeamFlag[Live[S].Team] := True;

  for S := 1 to MAX_PLAYERS do
  begin
    if not Live[S].Active or not Live[S].Human then
      Continue;
    if Live[S].Team = TEAM_SPEC then
      Inc(Extra[S].SpecSeconds)
    else
      Inc(Extra[S].PlaySeconds);
    Idx := Identity.StatsIndex(S);
    if not DB.Valid(Idx) then
      Continue;
    P := DB.Profiles[Idx];
    if Live[S].Team = TEAM_SPEC then
    begin
      Inc(P^.TimeOnSpectator);
      DB.Touch(Idx);
      Continue;
    end;
    if not On then
      Continue;
    if P^.Period[PERIOD_DAY].Key <> Today then
    begin
      Inc(DB.Server.Daily[D].Uniques);
      if P^.RegisterTime >= Trunc(Now) then
        Inc(DB.Server.Daily[D].NewPlayers);
    end;
    Inc(P^.TimePlayed);
    MxSecond(Self, S, Idx);
    MxSnap(Self, Idx, MxS);
    if Live[S].Alive then
    begin
      if Survive then
        Inc(P^.TimeAlive);
      W := WepSlot(Live[S].Weapon);
      if (W >= 0) and (Live[S].Weapon <> WEP_NONE) then
        Inc(P^.Weapons[W].TimeUsedSeconds);
      if Live[S].Weapon = WEP_CHAINSAW then
        Inc(P^.ChainsawTimeUsedSeconds);
      if Match.GameStyle = GS_RM then
      begin
        if IsBow(Live[S].Weapon) then
          Inc(P^.RamboMode.TimeWithBow)
        else
          Inc(P^.RamboMode.TimeWithoutBow);
      end;
      if Live[S].Flags and EF_A_FLAGGER <> 0 then
        Inc(P^.TimeHoldingFlags);
      if Match.GameStyle = GS_HTF then
      begin
        T := Live[S].Team;
        if Live[S].Flags and EF_A_FLAGGER <> 0 then
          Inc(P^.HTFMode.TimeWhenHaveFlag)
        else
          Inc(P^.HTFMode.TimeWhenNotHaveFlag);
        if (T >= 0) and (T <= 5) and TeamFlag[T] then
          Inc(P^.HTFMode.TimeWhenTeamHaveFlag)
        else
          Inc(P^.HTFMode.TimeWhenTeamNotHaveFlag);
        if (Live[S].Flags and EF_A_FLAGGER <> 0) and (Live[S].ContestedSinceTick > 0) and
           (GameTick - Live[S].ContestedSinceTick >= Round(Cfg.ContestedHoldSeconds * TICKS_PER_SECOND)) then
        begin
          Inc(P^.ContestedHolds);
          Live[S].ContestedSinceTick := 0;
          HudEvent(S, 'Held the flag under fire');
        end;
      end;
      { only the seconds that counted: a life begun on an empty server does not turn into a record
        the moment a second player joins }
      if Survive then
      begin
        Inc(Live[S].LifeSeconds);
        if Live[S].LifeSeconds > P^.LongestLifeSec then
          P^.LongestLifeSec := Live[S].LifeSeconds;
      end;
    end
    else if Survive then
      Inc(P^.TimeDeath);
    if Live[S].Flags and EF_A_FLAGGER = 0 then
      Live[S].ContestedSinceTick := 0;
    MxSecondEnd(Self, S, MxS);
    AddActivity(DB, Idx, Match.GameStyle, 0, 0, 0, 0, 0, 0, 0, 1);
    NoteProtectionActivity(DB, Idx, Cfg);
    DB.Touch(Idx);
  end;
end;
