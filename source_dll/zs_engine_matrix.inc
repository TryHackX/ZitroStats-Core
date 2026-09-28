{ zs_engine_matrix.inc - [Matrix]: what the engine records into the player-on-map records
  (zs_matrix), and the counters of the maps that came with them (part of zs_engine)

  Every routine here is called from the place where the same event is counted for the account, so
  a record counts exactly what the account's own statistics count: humans only, while the
  statistics count (MinHumansForStats), and a record only with [Matrix] Enabled = 1.

  Most counters of a record simply follow a counter of the account (PMFollows, zs_fields): the
  handlers that count them (KillEnemy, EvDamage, EvFlag, EvSample, SecondAccounting) take the
  account's counters before they count (MxSnap) and add what changed to the record of the map
  afterwards (MxFollow), so the record cannot miss a condition the account's own code has. The
  bests of a map, and what the other handlers count (teamkills, selfkills, assists, rounds, match
  results, kits, healing, knife throws, the answer of Map.RayCast), are counted here by name. }

type
  { the account's counters that the record of its map follows (PMFollows), as an event found them;
    Idx = -1: nothing to follow ([Matrix] off, no account) }
  TMxSnap = record
    Idx: LongInt;
    V: array[0..PM_FOLLOW_MAX - 1] of Double;
  end;

var
  { where the counter of the round first bloods lies in TPlayerProfile (profile field 700): -2 not
    looked up yet, -1 not there }
  MxRoundFirstBloodOfs: PtrInt = -2;

{ the record of the account at DB index Idx on the running map, made when missing; nil when nothing
  is recorded ([Matrix] off, no map, no account) }
function MxRec(E: TZSEngine; Idx: LongInt): PPlayerMapStats;
var
  M, No, P: LongInt;
begin
  Result := nil;
  if not E.Cfg.MatrixEnabled or not E.DB.Valid(Idx) then
    Exit;
  M := E.Match.MapIndex;
  if (M < 0) or (M >= E.DB.MapCount) then
    Exit;
  No := E.DB.PM.MapNumber(E.DB.Maps[M].MapName, True);
  P := E.DB.PM.Obtain(E.DB.Profiles[Idx]^.ID, No, E.DB.NowValue);
  if P < 0 then
    Exit;
  Result := E.DB.PM.Items[P];
  Result^.LastPlayed := E.DB.NowValue;
  E.DB.PM.Touch(P);
end;

{ a counter of the account (or of a record) as a number; Base + Ofs is a field of Kind }
function MxFollowValue(Base: Pointer; Ofs: PtrUInt; Kind: TFieldKind): Double; inline;
begin
  case Kind of
    fkInt32: Result := PLongInt(PtrUInt(Base) + Ofs)^;
    fkInt64: Result := PInt64(PtrUInt(Base) + Ofs)^;
    fkDouble: Result := PDouble(PtrUInt(Base) + Ofs)^;
    else Result := 0;
  end;
end;

{ the counters of the account at DB index Idx before an event counts (MxFollow afterwards) }
procedure MxSnap(E: TZSEngine; Idx: LongInt; out S: TMxSnap);
var
  k: LongInt;
  P: PPlayerProfile;
begin
  S.Idx := -1;
  if not E.Cfg.MatrixEnabled or not E.DB.Valid(Idx) then
    Exit;
  S.Idx := Idx;
  P := E.DB.Profiles[Idx];
  for k := 0 to High(PMFollows) do
    S.V[k] := MxFollowValue(P, PMFollows[k].ProfileOffset, PMFollows[k].Kind);
end;

{ the same for the two accounts of an event; one account on both sides is followed once }
procedure MxSnapTwo(E: TZSEngine; Idx1, Idx2: LongInt; out S1, S2: TMxSnap);
begin
  MxSnap(E, Idx1, S1);
  if Idx2 = Idx1 then
    S2.Idx := -1
  else
    MxSnap(E, Idx2, S2);
end;

{ what the event added to the counters of the account since MxSnap goes into the record of the map
  (made only when something was added); the record, nil for none }
function MxFollow(E: TZSEngine; const S: TMxSnap): PPlayerMapStats;
var
  k: LongInt;
  P: PPlayerProfile;
  D: Double;
  Ptr: Pointer;
begin
  Result := nil;
  if (S.Idx < 0) or not E.DB.Valid(S.Idx) then
    Exit;
  P := E.DB.Profiles[S.Idx];
  for k := 0 to High(PMFollows) do
  begin
    D := MxFollowValue(P, PMFollows[k].ProfileOffset, PMFollows[k].Kind) - S.V[k];
    if D = 0 then
      Continue;
    if Result = nil then
    begin
      Result := MxRec(E, S.Idx);
      if Result = nil then
        Exit;
    end;
    Ptr := Pointer(PtrUInt(Result) + PMFollows[k].RecordOffset);
    case PMFollows[k].Kind of
      fkInt32: Inc(PLongInt(Ptr)^, LongInt(Round(D)));
      fkInt64: Inc(PInt64(Ptr)^, Round(D));
      fkDouble: PDouble(Ptr)^ := PDouble(Ptr)^ + D;
    end;
  end;
end;

{ the first bloods of an account: of a match (FirstBloodCount) and of a survival round (the counter
  with profile id 700, 0 while there is none) }
procedure MxFirstBloods(const P: TPlayerProfile; out MatchFB, RoundFB: LongInt);
var
  k: LongInt;
begin
  if MxRoundFirstBloodOfs = -2 then
  begin
    MxRoundFirstBloodOfs := -1;
    for k := 0 to High(ProfileFields) do
      if (ProfileFields[k].Id = 700) and (ProfileFields[k].Kind = fkInt32) then
        MxRoundFirstBloodOfs := ProfileFields[k].Offset;
  end;
  MatchFB := P.FirstBloodCount;
  if MxRoundFirstBloodOfs >= 0 then
    RoundFB := PLongInt(PtrUInt(@P) + PtrUInt(MxRoundFirstBloodOfs))^
  else
    RoundFB := 0;
end;

{ KillEnemy: the kill and the death, the points, the weapon of each side, the rivals and weapon
  matchups on both sides, where it happened. Gain and Loss are the points the two accounts really
  got and gave (Loss can be less than Gain at [Ranking] MinimumPoints): the killer's entry of the
  victim wins Gain, the victim's entry of the killer loses Loss. FB0/RFB0: the killer's first bloods
  before the kill. }
procedure MxKill(E: TZSEngine; const Ev: TZSEvent; KIdx, VIdx, WS: LongInt; DistOk: Boolean; DistM: Double;
  Gain, Loss, FB0, RFB0: LongInt);
var
  VWS, FB, RFB, TTK: LongInt;
  KR, VR: PPlayerMapStats;
  Rv: PPMRival;
  NowT: Double;
begin
  if KIdx = VIdx then
    Exit;
  KR := MxRec(E, KIdx);
  VR := MxRec(E, VIdx);
  if (KR = nil) or (VR = nil) then
    Exit;
  NowT := E.DB.NowValue;
  VWS := WepSlot(Ev.I[3]);
  Inc(KR^.Kills);
  Inc(VR^.Deaths);
  Inc(KR^.Points, Gain);
  Dec(VR^.Points, Loss);
  if E.Live[Ev.Slot].KillStreak > KR^.BestStreak then
    KR^.BestStreak := E.Live[Ev.Slot].KillStreak;
  if DistOk and (DistM > KR^.LongestKill) then
    KR^.LongestKill := DistM;
  MxFirstBloods(E.DB.Profiles[KIdx]^, FB, RFB);
  if FB > FB0 then
    Inc(KR^.FirstBloods, FB - FB0);
  if RFB > RFB0 then
    Inc(KR^.RoundFirstBloods, RFB - RFB0);
  if WS >= 0 then
  begin
    Inc(PMWeaponOf(KR^, WS)^.Kills);
    Inc(PMWeaponOf(VR^, WS)^.Deaths);
    if VWS >= 0 then
    begin
      Inc(PMMatchupOf(KR^, WS, VWS)^.Wins);
      Inc(PMMatchupOf(VR^, VWS, WS)^.Losses);
    end;
  end;
  Rv := PMRivalOf(KR^, VR^.AccountId, E.DB.PM.MaxRivals);
  Inc(Rv^.Kills);
  Inc(Rv^.PointsWon, Gain);
  Rv^.LastFight := NowT;
  Rv := PMRivalOf(VR^, KR^.AccountId, E.DB.PM.MaxRivals);
  Inc(Rv^.Deaths);
  Inc(Rv^.PointsLost, Loss);
  Rv^.LastFight := NowT;
  if E.Cfg.MatrixPlayerHeatmap then
  begin
    PMHeatAdd(KR^, Ev.F[0], Ev.F[1], True);
    PMHeatAdd(VR^, Ev.F[2], Ev.F[3], False);
  end;
  { the bests of the map as KillEnemy has just counted the account's: the longest Barrett kill,
    the knife kills of one life, the fastest kill from the first hit }
  if DistOk and (DistM > 0) and (WS = WEP_BARRETT) and (DistM > KR^.LongestBarrett) then
    KR^.LongestBarrett := DistM;
  if (WS = WEP_KNIFE) and (E.Live[Ev.Slot].KnifeKillsLife > KR^.KnifeStreak) then
    KR^.KnifeStreak := E.Live[Ev.Slot].KnifeKillsLife;
  if E.Live[Ev.Slot].Pair[Ev.Slot2].FirstDamageTick > 0 then
  begin
    TTK := E.GameTick - E.Live[Ev.Slot].Pair[Ev.Slot2].FirstDamageTick;
    if (TTK >= 0) and ((KR^.BestTTKTicks <= 0) or (Max(1, TTK) < KR^.BestTTKTicks)) then
      KR^.BestTTKTicks := Max(1, TTK);
  end;
end;

{ KillEnemy, the map: the kill balance of the teams and the weapon matchups of the map }
procedure MxMapKill(E: TZSEngine; M, K, WS, VW: LongInt);
var
  T, VWS: LongInt;
begin
  T := E.Live[K].Team;
  if E.TeamGame and (T >= TEAM_ALPHA) and (T <= TEAM_DELTA) then
    Inc(E.DB.Maps[M].KillsByTeam[T]);
  VWS := WepSlot(VW);
  if E.Cfg.MatrixEnabled and (WS >= 0) and (VWS >= 0) then
    MapMatchupAdd(E.DB.Maps[M], WS, VWS);
end;

{ an assist; Flagger: the victim carried a flag }
procedure MxAssist(E: TZSEngine; Idx: LongInt; Flagger: Boolean);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  Inc(R^.Assists);
  if Flagger then
    Inc(R^.FlaggerAssists);
end;

{ points won (Delta > 0) or lost on the map }
procedure MxPoints(E: TZSEngine; Idx, Delta: LongInt);
var
  R: PPlayerMapStats;
begin
  if Delta = 0 then
    Exit;
  R := MxRec(E, Idx);
  if R <> nil then
    Inc(R^.Points, Delta);
end;

{ KillSelf with [Ranking] SelfkillMode = zerosum: the enemy who hit the selfkiller last forced the
  selfkill (ForcedSelfkills, whatever it paid), and the Pts the selfkiller lost went to him -
  besides a kill the only way points go from one player to another. A teamkill penalty, a selfkill
  penalty and the capture pool are nobody's gain from one rival. }
procedure MxSelfkillPoints(E: TZSEngine; WinIdx, LoseIdx, Pts: LongInt);
var
  WR, LR: PPlayerMapStats;
  Rv: PPMRival;
  NowT: Double;
begin
  WR := MxRec(E, WinIdx);
  if WR <> nil then
    Inc(WR^.ForcedSelfkills);
  if (Pts <= 0) or (WinIdx = LoseIdx) then
    Exit;
  LR := MxRec(E, LoseIdx);
  if (WR = nil) or (LR = nil) then
    Exit;
  NowT := E.DB.NowValue;
  Rv := PMRivalOf(WR^, LR^.AccountId, E.DB.PM.MaxRivals);
  Inc(Rv^.PointsWon, Pts);
  Rv^.LastFight := NowT;
  Rv := PMRivalOf(LR^, WR^.AccountId, E.DB.PM.MaxRivals);
  Inc(Rv^.PointsLost, Pts);
  Rv^.LastFight := NowT;
end;

{ a capture of Capture the Flag: what the pool gave the team and took from the enemies
  (CtfCapPool); the capper's own gain goes through MxPoints }
procedure MxCapturePool(E: TZSEngine; const Mates, Gains, Enemies, Losses: TIntArray);
var
  k: LongInt;
begin
  for k := 0 to Min(High(Mates), High(Gains)) do
    MxPoints(E, Mates[k], Gains[k]);
  for k := 0 to Min(High(Enemies), High(Losses)) do
    MxPoints(E, Enemies[k], -Losses[k]);
end;

{ a selfkill; UnderFire: an enemy had hit the player within AssistSeconds }
procedure MxSelfkill(E: TZSEngine; Idx: LongInt; UnderFire: Boolean);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  Inc(R^.Selfkills);
  if UnderFire then
    Inc(R^.SelfkillsUnderFire);
end;

{ a teamkill with the Lost points of the penalty; Flags of the kill event: the victim or the killer
  carried a flag }
procedure MxTeamkill(E: TZSEngine; Idx, Lost, Flags: LongInt);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  Inc(R^.Teamkills);
  Dec(R^.Points, Lost);
  if Flags and EF_B_FLAGGER <> 0 then
    Inc(R^.FlaggerTeamkills);
  if Flags and EF_A_FLAGGER <> 0 then
    Inc(R^.TeamkillsWithFlag);
end;

{ the victim of a teamkill }
procedure MxTeamkillDeath(E: TZSEngine; Idx: LongInt);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R <> nil then
    Inc(R^.TeamkillDeaths);
end;

{ EvDamage, a hit on an enemy: the shooter's hits and damage, the victim's damage taken, the rivals
  of both }
procedure MxDamage(E: TZSEngine; SIdx, VIdx, W: LongInt; Dmg: Single; Zone: LongInt);
var
  SR, VR: PPlayerMapStats;
  Wp: PPMWeapon;
  Rv: PPMRival;
  WS: LongInt;
  NowT: Double;
begin
  SR := MxRec(E, SIdx);
  if SR = nil then
    Exit;
  NowT := E.DB.NowValue;
  WS := WepSlot(W);
  SR^.DamageDealt := SR^.DamageDealt + Dmg;
  if CountsForAccuracy(W) then
    Inc(SR^.Hits);
  if ZoneClassifiableStyle(W) then
    case Zone of
      HZ_HEAD: Inc(SR^.HitsHead);
      HZ_BODY: Inc(SR^.HitsBody);
      HZ_LEGS: Inc(SR^.HitsLegs);
    end;
  if WS >= 0 then
  begin
    Wp := PMWeaponOf(SR^, WS);
    Inc(Wp^.Hits);
    if ZoneClassifiableStyle(W) and (Zone = HZ_HEAD) then
      Inc(Wp^.Headshots);
    Wp^.Damage := Wp^.Damage + Dmg;
  end;
  if VIdx = SIdx then
    Exit;
  VR := MxRec(E, VIdx);
  if VR = nil then
    Exit;
  VR^.DamageReceived := VR^.DamageReceived + Dmg;
  Rv := PMRivalOf(SR^, VR^.AccountId, E.DB.PM.MaxRivals);
  Rv^.DamageDealt := Rv^.DamageDealt + Dmg;
  Rv^.LastFight := NowT;
  Rv := PMRivalOf(VR^, SR^.AccountId, E.DB.PM.MaxRivals);
  Rv^.DamageTaken := Rv^.DamageTaken + Dmg;
  Rv^.LastFight := NowT;
end;

{ CountShots: N shots with Weapon, as the account's own shots count them; the knife throws count
  the throws, not the shots a weapon fires at once }
procedure MxShots(E: TZSEngine; Idx, Weapon, N: LongInt);
var
  R: PPlayerMapStats;
  W: LongInt;
begin
  if N <= 0 then
    Exit;
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  if CountsForAccuracy(Weapon) then
    Inc(R^.Shots, N);
  W := WepSlot(Weapon);
  if W >= 0 then
    Inc(PMWeaponOf(R^, W)^.Shots, N);
  if Weapon = WEP_THROWNKNIFE then
    Inc(R^.KnifeThrows, N div Max(1, ShotMultiplier(Weapon)));
end;

{ EvFlag: captures, returns and grabs }
procedure MxFlag(E: TZSEngine; Idx, Kind: LongInt);
var
  R: PPlayerMapStats;
begin
  if (Kind <> FLAG_SCORE) and (Kind <> FLAG_RETURN) and (Kind <> FLAG_GRAB) then
    Exit;
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  case Kind of
    FLAG_SCORE: Inc(R^.Caps);
    FLAG_RETURN: Inc(R^.Returns);
    FLAG_GRAB: Inc(R^.Grabs);
  end;
end;

{ EvFlag, a capture of a flag the account grabbed Seconds before (from half a second on, as the
  account's own fastest capture): the fastest capture of the map }
procedure MxCapTime(E: TZSEngine; Idx: LongInt; Seconds: Double);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if (R <> nil) and ((R^.FastestCap <= 0) or (Seconds < R^.FastestCap)) then
    R^.FastestCap := Seconds;
end;

{ EvHeal: health the healing fields of the map gave back (Regen) and the health of the kits picked
  up here (Kits, KitCount kits) }
procedure MxHeal(E: TZSEngine; Idx: LongInt; Regen, Kits: Single; KitCount: LongInt);
var
  R: PPlayerMapStats;
begin
  if (Regen <= 0) and (Kits <= 0) and (KitCount <= 0) then
    Exit;
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  if Regen > 0 then
    R^.HealRegen := R^.HealRegen + Regen;
  if Kits > 0 then
    R^.HealKits := R^.HealKits + Kits;
  if KitCount > 0 then
    Inc(R^.HealKitCount, KitCount);
end;

{ EvKit: a kit of the kind K (the place in KIT_KIND_STYLES) picked up }
procedure MxKit(E: TZSEngine; Idx, K: LongInt);
var
  R: PPlayerMapStats;
begin
  if (K < 0) or (K >= KIT_KINDS) then
    Exit;
  R := MxRec(E, Idx);
  if R <> nil then
    Inc(R^.KitPickups[K]);
end;

{ EvRay: the line of a kill's lethal shot was blocked, a Cover (shot) kill of the map the kill was
  made on (EvRay checks that it still runs) }
procedure MxCoverShot(E: TZSEngine; Idx: LongInt);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R <> nil then
    Inc(R^.CoverShotKills);
end;

{ EvTick, Hold the Flag: Delta points scored by the account as the carrier }
procedure MxHtfPoints(E: TZSEngine; Idx, Delta: LongInt);
var
  R: PPlayerMapStats;
begin
  if Delta <= 0 then
    Exit;
  R := MxRec(E, Idx);
  if R <> nil then
    Inc(R^.HtfPoints, Delta);
end;

{ EvSample after MxSnap: the metres and the flight the sample added, and the longest way of one
  life on the map }
procedure MxSampleEnd(E: TZSEngine; S: LongInt; const Sn: TMxSnap);
var
  R: PPlayerMapStats;
begin
  R := MxFollow(E, Sn);
  if (R <> nil) and (E.Live[S].LifeDistance > R^.BestLifeDistance) then
    R^.BestLifeDistance := E.Live[S].LifeDistance;
end;

{ SecondAccounting, a second played with the statistics on: the time, the weapon in hand, and the
  first second of a match counts the match }
procedure MxSecond(E: TZSEngine; S, Idx: LongInt);
var
  R: PPlayerMapStats;
  W: LongInt;
begin
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  Inc(R^.TimePlayed);
  if R^.MatchKey <> E.Match.StartTime then
  begin
    R^.MatchKey := E.Match.StartTime;
    Inc(R^.Matches);
  end;
  if E.Live[S].Alive and (E.Live[S].Weapon <> WEP_NONE) then
  begin
    W := WepSlot(E.Live[S].Weapon);
    if W >= 0 then
      Inc(PMWeaponOf(R^, W)^.TimeUsed);
  end;
end;

{ SecondAccounting after MxSnap, at the end of the player's second: the time alive, with the flag,
  with the bow ... that the second added, and the longest life of the map (the seconds of this
  life that counted, as the account's own) }
procedure MxSecondEnd(E: TZSEngine; S: LongInt; const Sn: TMxSnap);
var
  R: PPlayerMapStats;
begin
  R := MxFollow(E, Sn);
  if not E.Live[S].Alive or (E.Live[S].LifeSeconds <= 0) or (Sn.Idx < 0) then
    Exit;
  if R = nil then
    R := MxRec(E, Sn.Idx);
  if (R <> nil) and (E.Live[S].LifeSeconds > R^.LongestLife) then
    R^.LongestLife := E.Live[S].LifeSeconds;
end;

{ EndMatch: a win, a loss or a draw on the map. Team (team games): the team the result went to,
  for the wins and losses of Alpha and Bravo and a comeback (a win after trailing by 2); Leaver: a
  loss of an account that left the match (LeaverCountsAsLoss) }
procedure MxMatchResult(E: TZSEngine; Idx: LongInt; Draw, Won: Boolean; Team: LongInt = 0;
  Leaver: Boolean = False);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  if Draw then
    Inc(R^.Draws)
  else if Won then
  begin
    Inc(R^.Wins);
    case Team of
      TEAM_ALPHA: Inc(R^.AlphaWins);
      TEAM_BRAVO: Inc(R^.BravoWins);
    end;
    if (Team >= TEAM_ALPHA) and (Team <= TEAM_DELTA) and (E.Match.MaxDeficit[Team] >= 2) then
      Inc(R^.ComebackWins);
  end
  else
  begin
    Inc(R^.Losses);
    case Team of
      TEAM_ALPHA: Inc(R^.AlphaLosses);
      TEAM_BRAVO: Inc(R^.BravoLosses);
    end;
    if Leaver then
      Inc(R^.LeaveLosses);
  end;
end;

{ RoundEnd, RoundEndFfa: a survival round won or lost, and of an advance game played; Slot (team
  survival): the survivor of a last stand (CheckLastStand) wins a clutch }
procedure MxRound(E: TZSEngine; Idx: LongInt; Won: Boolean; Slot: LongInt = 0);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R = nil then
    Exit;
  if Won then
    Inc(R^.RoundsWon)
  else
    Inc(R^.RoundsLost);
  if E.Match.Advance then
  begin
    Inc(R^.AdvanceRoundsPlayed);
    if Won then
      Inc(R^.AdvanceRoundsWon);
  end;
  if Won and (Slot > 0) and (Slot = E.Match.ClutchSlot) and (E.Match.ClutchProfile <> 0) and
     (E.DB.Profiles[Idx]^.ID = E.Match.ClutchProfile) then
    Inc(R^.ClutchesWon);
end;

procedure MxLastStand(E: TZSEngine; Idx: LongInt);
var
  R: PPlayerMapStats;
begin
  R := MxRec(E, Idx);
  if R <> nil then
    Inc(R^.LastStands);
end;

{ the teams that still have somebody standing; a bot sends no spawn and no position, so a team with
  a bot counts as standing (as in EvTick) }
function MxTeamsStanding(E: TZSEngine): LongInt;
var
  S: LongInt;
  Standing: array[TEAM_ALPHA..TEAM_DELTA] of Boolean;
begin
  FillChar(Standing, SizeOf(Standing), 0);
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and (E.Live[S].Alive or not E.Live[S].Human) and (E.Live[S].Team >= TEAM_ALPHA) and
       (E.Live[S].Team <= TEAM_DELTA) then
      Standing[E.Live[S].Team] := True;
  Result := 0;
  for S := TEAM_ALPHA to TEAM_DELTA do
    if Standing[S] then
      Inc(Result);
end;

{ RoundEnd (team survival): how the round was won - by a capture (Capture the Flag, Infiltration: a
  capture since the last look at the score) or by wiping out the other teams - counted where and as
  the round wins of the map are counted. Every round end closes the round that ran. }
procedure MxRoundEnd(E: TZSEngine; WinTeam: LongInt);
var
  S, M: LongInt;
  Opponents: Boolean;
begin
  E.Match.RoundLive := False;
  M := E.Match.MapIndex;
  if (M < 0) or (M >= E.DB.MapCount) or not E.StatsOn then
    Exit;
  Opponents := False;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and (E.Live[S].Team >= TEAM_ALPHA) and (E.Live[S].Team <= TEAM_DELTA) and
       (E.Live[S].Team <> WinTeam) then
      Opponents := True;
  if not Opponents then
    Exit;
  if (E.Match.CaptureTick > 0) and (E.Match.CaptureTick >= E.Match.ScoreTick) then
    Inc(E.DB.Maps[M].RoundsCapture)
  else if (WinTeam >= TEAM_ALPHA) and (WinTeam <= TEAM_DELTA) then
    Inc(E.DB.Maps[M].RoundsElimination[WinTeam]);
  E.DB.TouchMap(M);
end;

{ RoundEndFfa (free-for-all survival), counted with the round wins: the last one standing won, or
  nobody was left (the last ones died together, or a bot won) }
procedure MxRoundEndFfa(E: TZSEngine; WinSlot: LongInt);
var
  M: LongInt;
begin
  M := E.Match.MapIndex;
  if (M < 0) or (M >= E.DB.MapCount) then
    Exit;
  if WinSlot > 0 then
    Inc(E.DB.Maps[M].RoundsLastStanding)
  else
    Inc(E.DB.Maps[M].RoundsNoSurvivor);
  E.DB.TouchMap(M);
end;

{ EvTick, team survival with the statistics on: a round runs once two teams stand; when nobody is
  left standing, the round ended without a winner }
procedure MxSurvivalTick(E: TZSEngine);
var
  k, M: LongInt;
begin
  k := MxTeamsStanding(E);
  if k >= 2 then
    E.Match.RoundLive := True
  else if (k = 0) and E.Match.RoundLive then
  begin
    E.Match.RoundLive := False;
    M := E.Match.MapIndex;
    if (M >= 0) and (M < E.DB.MapCount) then
    begin
      Inc(E.DB.Maps[M].RoundsNoSurvivor);
      E.DB.TouchMap(M);
    end;
  end;
end;

{ EvMapBefore, before the scores of the event are taken: a survival round that still ran when the
  map ended was cut short by the map change - not one the last point or death of the map decided }
procedure MxMapBefore(E: TZSEngine; const Ev: TZSEvent);
var
  S, T, M, Players: LongInt;
  Scored: Boolean;
begin
  M := E.Match.MapIndex;
  if not E.Match.Active or not E.Match.Survival or not E.StatsOn or (M < 0) or (M >= E.DB.MapCount) then
    Exit;
  if E.TeamGame then
  begin
    if not E.Match.RoundLive or (MxTeamsStanding(E) < 2) then
      Exit;
    { Capture the Flag scores only when a round ends: a point more than at the last look ended it }
    Scored := False;
    for T := 1 to 4 do
      if Ev.I[T - 1] > E.Match.TeamScore[T] then
        Scored := True;
    if Scored and (E.Match.GameStyle = GS_CTF) then
      Exit;
  end
  else
  begin
    { the rounds of a free-for-all count with two humans in them and the survival statistics on }
    if E.Match.RoundOver or E.Match.RoundPending or not E.SurvivalOn then
      Exit;
    Players := 0;
    for S := 1 to MAX_PLAYERS do
      if E.Match.RoundIn[S] and E.Live[S].Active and E.Live[S].Human then
        Inc(Players);
    if Players < 2 then
      Exit;
  end;
  Inc(E.DB.Maps[M].RoundsMapChange);
  E.DB.TouchMap(M);
end;
