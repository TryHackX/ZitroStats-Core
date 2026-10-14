{ zs_engine_combat.inc - kills, damage and flags (part of zs_engine) }

const
  { a bullet from behind flies at least this fast across (pixels a tick) towards the victim's back }
  BACK_MIN_SPEED = 0.2;

procedure TZSEngine.UpdateNemesis(var List: TNemesisArray; TargetId: LongInt);
var
  i, j, Found: LongInt;
  T: TNemesisEntry;
begin
  if TargetId <= 0 then
    Exit;
  Found := -1;
  for i := 0 to 2 do
    if List[i].TargetPlayerID = TargetId then
    begin
      Found := i;
      Break;
    end;
  if Found < 0 then
  begin
    { only three rivals are kept: a new one replaces the weakest entry and starts at zero }
    Found := 0;
    for i := 1 to 2 do
      if List[i].KillCount < List[Found].KillCount then
        Found := i;
    List[Found].TargetPlayerID := TargetId;
    List[Found].KillCount := 0;
  end;
  Inc(List[Found].KillCount);
  for i := 0 to 1 do
    for j := i + 1 to 2 do
      if List[j].KillCount > List[i].KillCount then
      begin
        T := List[i];
        List[i] := List[j];
        List[j] := T;
      end;
end;

procedure TZSEngine.HeatAdd(MapIndex: LongInt; X, Y: Single; IsKill: Boolean);
const
  CELL_PX = 64;
  MAX_CELLS = 4096;
var
  MP: PMapProfile;
  Cell, Lo, Hi, Mid, n: LongInt;
begin
  if (MapIndex < 0) or (MapIndex >= DB.MapCount) then
    Exit;
  MP := @DB.Maps[MapIndex];
  Cell := EnsureRange(Floor(Y / CELL_PX) + 2048, 0, 4095) * 4096 + EnsureRange(Floor(X / CELL_PX) + 2048, 0, 4095);
  Lo := 0;
  Hi := High(MP^.Heat);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    if MP^.Heat[Mid].Cell = Cell then
    begin
      if IsKill then
        Inc(MP^.Heat[Mid].Kills)
      else
        Inc(MP^.Heat[Mid].Deaths);
      Exit;
    end;
    if MP^.Heat[Mid].Cell < Cell then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  n := Length(MP^.Heat);
  if n >= MAX_CELLS then
    Exit;
  SetLength(MP^.Heat, n + 1);
  if Lo < n then
    Move(MP^.Heat[Lo], MP^.Heat[Lo + 1], (n - Lo) * SizeOf(THeatCell));
  MP^.Heat[Lo].Cell := Cell;
  MP^.Heat[Lo].Kills := Ord(IsKill);
  MP^.Heat[Lo].Deaths := Ord(not IsKill);
end;

procedure TZSEngine.AfterProfileChange(Index: LongInt);
var
  Ach: TIntArray;
  k, S: LongInt;
begin
  if not Cfg.AchievementsEnabled or not DB.Valid(Index) then
    Exit;
  Ach := CheckAchievements(DB, Index, PlayerRank(Index));
  if Length(Ach) = 0 then
    Exit;
  S := Identity.SlotOfProfile(DB.Profiles[Index]^.ID);
  for k := 0 to High(Ach) do
    if Cfg.AchievementBroadcast then
      Broadcast(Format('%s unlocked "%s"', [DB.Profiles[Index]^.ActiveName, AchievementName(Ach[k])]), CLR_FEATS)
    else if S > 0 then
      Say(S, 'Achievement unlocked: ' + AchievementName(Ach[k]), CLR_FEATS);
end;

procedure TZSEngine.AskRay(ProfileId: LongInt; X1, Y1, X2, Y2: Single);
var
  A: TZSAction;
  R: ^TRayRequest;
begin
  Inc(FRayId);
  if FRayId <= 0 then
    FRayId := 1;
  { a ring: an answer never takes longer than a few ticks, so 64 open questions are plenty }
  R := @FRays[FRayNext];
  FRayNext := (FRayNext + 1) mod Length(FRays);
  R^.Id := FRayId;
  R^.ProfileId := ProfileId;
  R^.MapSerial := FMapSerial;
  R^.X1 := Round(X1);
  R^.Y1 := Round(Y1);
  R^.X2 := Round(X2);
  R^.Y2 := Round(Y2);
  A := NewAction(ACT_RAYCAST, 0, 0, '');
  A.P1 := FRayId;
  A.P2 := R^.X1;
  A.P3 := R^.Y1;
  A.P4 := R^.X2;
  A.P5 := R^.Y2;
  EmitAction(A);
end;

procedure TZSEngine.EvRay(var E: TZSEvent);
var
  k, Idx: LongInt;
  What: AnsiString;
  R: TRayRequest;
begin
  if E.I[0] <= 0 then
    Exit;
  for k := 0 to High(FRays) do
    if FRays[k].Id = E.I[0] then
    begin
      R := FRays[k];
      FRays[k].Id := 0;
      case E.I[1] of
        RAY_BLOCKED: What := 'blocked';
        RAY_CLEAR: What := 'clear';
        else What := 'unknown (RayCast is not calibrated yet)';
      end;
      Idx := DB.IndexOfId(R.ProfileId);
      if not DB.Valid(Idx) or (R.MapSerial <> FMapSerial) then
        Exit;
      if E.I[1] = RAY_BLOCKED then
      begin
        Inc(DB.Profiles[Idx]^.CoverShotKills);
        MxCoverShot(Self, Idx);
        DB.Touch(Idx);
        What := 'blocked, counted as Cover (shot)';
      end;
      if Cfg.DebugRayCast then
        NotifyAdmins(Format('[debug] %s: the line from the shot to the hit is %s', [DB.Profiles[Idx]^.ActiveName, What]),
          CLR_HINT);
      Exit;
    end;
end;

procedure TZSEngine.LogSuspicious(K, V: LongInt);
var
  KI, VI, KId, VId: LongInt;
  Line: AnsiString;
begin
  KI := Identity.ProfileIndex(K);
  VI := Identity.ProfileIndex(V);
  KId := 0;
  VId := 0;
  if DB.Valid(KI) then
    KId := DB.Profiles[KI]^.ID;
  if DB.Valid(VI) then
    VId := DB.Profiles[VI]^.ID;
  Line := Format('%s (#%d) killed %s (#%d) %d times within %d min, the victim killed %d; %d players on the server',
    [Live[K].Name, KId, Live[V].Name, VId, Live[K].Pair[V].WinKills, Cfg.SuspiciousWindowMinutes,
     Live[V].MatchKills - Live[K].Pair[V].WinVictimKills0, HumansPlaying]);
  AppendLog('suspicious.log', Line + Format(' [hwid %s / %s, ip %s / %s]',
    [Identity.Slots[K].Hwid, Identity.Slots[V].Hwid, Identity.Slots[K].IP, Identity.Slots[V].IP]));
  Suspects.Add(FormatDateTime('yyyy-mm-dd hh:nn', Now) + '  ' + Line);
  while Suspects.Count > SUSPECTS_MAX do
    Suspects.Delete(0);
  if Cfg.SuspiciousNotifyAdmins then
    NotifyAdmins('[ZitroStats] suspicious: ' + Line, CLR_WARN);
end;

{ Survival team games: a death that leaves one player of the team alive against two or more
  enemies, with at least [Mechanics] LastStandMinPlayers humans on the teams in the round (the
  dead count: they played it). In a free-for-all the last one standing is the winner of the round
  (RoundEndFfa). }
procedure TZSEngine.CheckLastStand(Victim: LongInt);
var
  S, T, Alive, Survivor, Enemies, Idx, Players: LongInt;
begin
  if not Match.Survival or not TeamGame or not StatsOn or not SlotValid(Victim) then
    Exit;
  T := Live[Victim].Team;
  if (T < TEAM_ALPHA) or (T > TEAM_DELTA) or Match.LastStandGiven[T] then
    Exit;
  Alive := 0;
  Survivor := 0;
  Enemies := 0;
  Players := 0;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human and (Live[S].Team >= TEAM_ALPHA) and (Live[S].Team <= TEAM_DELTA) then
    begin
      Inc(Players);
      if not Live[S].Alive then
        Continue;
      if Live[S].Team = T then
      begin
        Inc(Alive);
        Survivor := S;
      end
      else
        Inc(Enemies);
    end;
  if (Alive = 1) and (Enemies >= 2) and (Players >= Cfg.LastStandMinPlayers) then
  begin
    Match.LastStandGiven[T] := True;
    Match.ClutchSlot := Survivor;
    Match.ClutchProfile := 0;
    Idx := Identity.StatsIndex(Survivor);
    if DB.Valid(Idx) then
    begin
      Match.ClutchProfile := DB.Profiles[Idx]^.ID;
      Inc(DB.Profiles[Idx]^.LastStand);
      MxLastStand(Self, Idx);
      DB.Touch(Idx);
      HudEvent(Survivor, Format('Last stand vs %d', [Enemies]));
    end;
  end;
end;

{ A message of [Sprees] for everybody: in the chat, as a big text in the middle of the screen, or
  both. The big text is centred by its length on a 16:9 screen (427 is its middle in Soldat's
  interface, 480 high) and kept inside 640 where it fits, so a 4:3 screen shows it whole. The end
  of a spree (Below) goes a line below a level, on a layer of its own: one kill can do both. }
procedure SpreeMessage(E: TZSEngine; const Text: AnsiString; Style: LongInt; Below: Boolean);
const
  CENTER_X = 427;
  CHAR_W = 140;     { the width of a character of the big font at scale 1 }
var
  A: TZSAction;
  S, Layer, W, X: LongInt;
begin
  if (Text = '') or (Style = SPREE_OFF) then
    Exit;
  if (Style = SPREE_CHAT) or (Style = SPREE_BOTH) then
    E.Broadcast(Text, E.Cfg.SpreeColor);
  if (Style <> SPREE_BIGTEXT) and (Style <> SPREE_BOTH) then
    Exit;
  { the two layers after the HUD's own two }
  Layer := E.Cfg.HudLayer + 2;
  if Layer + 1 > 255 then
    Layer := Max(0, E.Cfg.HudLayer - 3);
  if Below then
    Inc(Layer);
  W := Round(Length(Text) * E.Cfg.SpreeBigScale * CHAR_W);
  X := Max(0, Min(CENTER_X - W div 2, 640 - W));
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human then
    begin
      A := NewAction(ACT_BIGTEXT, S, E.Cfg.SpreeColor, Text);
      A.P1 := Layer;
      A.P2 := X;
      A.P3 := E.Cfg.SpreeBigY;
      if Below then
        Inc(A.P3, Round(E.Cfg.SpreeBigScale * 220));
      A.F1 := E.Cfg.SpreeBigScale;
      A.F2 := E.Cfg.SpreeBigSeconds * TICKS_PER_SECOND;
      E.EmitAction(A);
    end;
end;

procedure TZSEngine.EvKill(var E: TZSEvent);
var
  K, V: LongInt;
  ServerKill, Joined: Boolean;
begin
  K := E.Slot;
  V := E.Slot2;
  if not SlotValid(V) then
    Exit;
  { the server kills players itself: a team change in survival, the end of a survival round and
    the players still standing after a capture. Soldat counts no death for those either. }
  ServerKill := (K = V) and ((E.I[2] and EF_SERVER_KILL <> 0) or
    (Match.Survival and (Live[V].TeamSinceTick = E.Tick)));
  ReloadOnDeath(V, E.Tick, not ServerKill);
  { !lastfight: the kill and the record of the death, while the hits of the life are still known }
  LastFightKill(Self, E, ServerKill);
  { the killer left in the same tick: the victim died, but it was nobody's selfkill }
  if not SlotValid(K) then
  begin
    LiveLifeEnded(Live, V, GameTick);
    CheckLastStand(V);
    RoundCheck(0);
    Exit;
  end;
  { [Debug] RayCastLog: what the server said about the line between killer and victim }
  if Cfg.DebugRayCast and (K <> V) then
    NotifyAdmins(Format('[debug] %s killed %s: RayCast answered %s, calibrated %s, counted as %s',
      [Live[K].Name, Live[V].Name, BoolToStr(E.I[2] and EF_RAY_RAW <> 0, 'true', 'false'),
       BoolToStr(E.I[2] and EF_RAY_CAL <> 0, 'yes', 'not yet'),
       BoolToStr(E.I[2] and EF_RAY_CAL = 0, 'not counted',
         BoolToStr(E.I[2] and EF_LOS <> 0, 'a clear line', 'Cover (live)'))]), CLR_HINT);
  if ServerKill then
  begin
    { A team change kills the player right after the spawn it causes: that player takes no part
      in the round. Any other kill of the server ends a round, and nobody beat the one it hits.
      No last stand either: after a capture the server kills both teams in the order of the
      slots, which leaves somebody alone against the others for a moment. }
    Joined := (Live[V].SpawnTick = GameTick) or (Live[V].TeamSinceTick = E.Tick);
    if Joined then
      Match.RoundIn[V] := False;
    LiveLifeEnded(Live, V, GameTick, True);
    if Joined then
      RoundCheck(0)
    else
      RoundCheck(V);
  end
  else
  begin
    try
      if K = V then
        KillSelf(V)
      else if TeamGame and (Live[K].Team = Live[V].Team) then
        KillTeammate(K, V, E.I[2])
      else
        KillEnemy(E);
    except
      on Ex: Exception do
      begin
        { the counters of the kill stopped half way; the death itself still ends the life, and the
          round and the balance below still see it }
        LiveLifeEnded(Live, V, GameTick);
        ReportError('event ' + IntToStr(Ord(E.Kind)), Ex);
      end;
    end;
    CheckLastStand(V);
    RoundCheck(0);
  end;
  BalOnKill(K, V, E.Tick);
end;

procedure TZSEngine.KillSelf(Slot: LongInt);
var
  Idx, A, Best, BestTick, BestIdx, Pts, Lost, M: LongInt;
begin
  Idx := Identity.StatsIndex(Slot);
  if Live[Slot].Human and StatsOn and DB.Valid(Idx) then
  begin
    Inc(DB.Profiles[Idx]^.Selfkills);
    M := Match.MapIndex;
    if (M >= 0) and (M < DB.MapCount) then
    begin
      Inc(DB.Maps[M].Selfkills);
      DB.TouchMap(M);
    end;
    { the human enemy who hit the player last, within AssistSeconds }
    Best := 0;
    BestTick := 0;
    for A := 1 to MAX_PLAYERS do
      if (A <> Slot) and Live[A].Active and Live[A].Human and LiveIsEnemy(Live, A, Slot, TeamGame) and
         (Live[A].Pair[Slot].LastDamageTick > BestTick) and
         (GameTick - Live[A].Pair[Slot].LastDamageTick <= Round(Cfg.AssistSeconds * TICKS_PER_SECOND)) then
      begin
        Best := A;
        BestTick := Live[A].Pair[Slot].LastDamageTick;
      end;
    BestIdx := -1;
    if Best > 0 then
    begin
      BestIdx := Identity.StatsIndex(Best);
      Inc(DB.Profiles[Idx]^.SelfkillsUnderFire);
    end;
    if DB.Valid(BestIdx) and SameText(Trim(Cfg.SelfkillMode), 'zerosum') and (Cfg.SelfkillAssistShare > 0) then
    begin
      { zero-sum: nobody was killed, so there is no kill and no death, only a selfkill; the enemy who
        pushed the player into it earns SelfkillAssistShare % of the kill points and the player
        loses exactly that }
      Pts := (KillPoints(Cfg, DB.Profiles[BestIdx]^.Points, DB.Profiles[Idx]^.Points, False, 0) *
        Cfg.SelfkillAssistShare + 50) div 100;
      Lost := -AddPoints(DB, Idx, -Pts, Cfg.MinimumPoints);
      AddPoints(DB, BestIdx, Lost, Cfg.MinimumPoints);
      MxPoints(Self, Idx, -Lost);
      MxPoints(Self, BestIdx, Lost);
      MxSelfkillPoints(Self, BestIdx, Idx, Lost);
      Inc(DB.Profiles[BestIdx]^.ForcedSelfkills);
      DB.Touch(BestIdx);
      if Lost > 0 then
      begin
        HudEvent(Slot, Format('-%d pts selfkill under fire', [Lost]));
        HudEvent(Best, Format('+%d pts (selfkill of %s)', [Lost, Live[Slot].Name]));
      end;
    end
    else if Cfg.SelfkillPenalty > 0 then
    begin
      Lost := -AddPoints(DB, Idx, -Cfg.SelfkillPenalty, Cfg.MinimumPoints);
      if Lost > 0 then
        HudEvent(Slot, Format('-%d pts selfkill', [Lost]));
      MxPoints(Self, Idx, -Lost);
    end;
    MxSelfkill(Self, Idx, Best > 0);
    DB.Touch(Idx);
  end;
  LiveLifeEnded(Live, Slot, GameTick);
end;

procedure TZSEngine.KillTeammate(K, V, Flags: LongInt);
var
  KIdx, VIdx, Lost: LongInt;
begin
  if Live[K].Human and Live[V].Human and StatsOn then
  begin
    KIdx := Identity.StatsIndex(K);
    VIdx := Identity.StatsIndex(V);
    if DB.Valid(KIdx) then
    begin
      Inc(DB.Profiles[KIdx]^.Teamkills);
      if Flags and EF_B_FLAGGER <> 0 then
        Inc(DB.Profiles[KIdx]^.FlaggerTeamkills);
      if Flags and EF_A_FLAGGER <> 0 then
        Inc(DB.Profiles[KIdx]^.TeamkillsWhenHaveFlag);
      Lost := 0;
      if Cfg.TeamkillPenalty > 0 then
        Lost := -AddPoints(DB, KIdx, -Cfg.TeamkillPenalty, Cfg.MinimumPoints);
      { at MinimumPoints the penalty takes nothing: no "-0 pts" }
      if Lost > 0 then
        HudEvent(K, Format('-%d pts teamkill', [Lost]))
      else
        HudEvent(K, 'Teamkill - no points');
      MxTeamkill(Self, KIdx, Lost, Flags);
      DB.Touch(KIdx);
    end;
    if DB.Valid(VIdx) then
    begin
      Inc(DB.Profiles[VIdx]^.DeathsByFriendly);
      MxTeamkillDeath(Self, VIdx);
      DB.Touch(VIdx);
    end;
  end;
  LiveLifeEnded(Live, V, GameTick);
end;

{ a bullet that flies straight from where it was made to where it hits, so its air time is its flight:
  not a blade or a fist (no flight at all), a flame (a cloud), nor a grenade or its clusters (a fuse) }
function AirTimed(W: LongInt): Boolean;
begin
  Result := not IsMeleeWeapon(W) and (W <> WEP_FLAMER) and (W <> WEP_FRAG) and (W <> WEP_CLUSTERNADE) and
    (W <> WEP_CLUSTER) and (W <> WEP_WORLD);
end;

procedure TZSEngine.KillEnemy(var E: TZSEvent);
var
  K, V, W, WS, VW, Flags, KIdx, VIdx, AIdx, Pts, Gain, Loss, A, M, D, TTK, Tk, Bucket, Lv, RayAns, Air: LongInt;
  KP, VP, AP: PPlayerProfile;
  KX, KY, VX, VY, HX, HY, SX, SY, R, OwnX, OwnY, FoeX, FoeY, BackDX: Single;
  DistM, AssistDamage: Double;
  DistOk, Inactive, Headshot, Saved, SavedFlagger: Boolean;
  { [Matrix]: the killer's first bloods before this kill }
  MxFB, MxRFB: LongInt;
  { [Matrix]: the counters of the killer and of the victim before this kill }
  MxK, MxV: TMxSnap;
begin
  K := E.Slot;
  V := E.Slot2;
  W := E.I[1];
  Flags := E.I[2];
  VW := E.I[3];
  KX := E.F[0];
  KY := E.F[1];
  VX := E.F[2];
  VY := E.F[3];
  Tk := GameTick;
  KIdx := Identity.StatsIndex(K);
  VIdx := Identity.StatsIndex(V);
  if not (Live[K].Human and Live[V].Human and StatsOn and DB.Valid(KIdx) and DB.Valid(VIdx)) then
  begin
    Live[K].Pair[V].KilledTick := Tk;
    LiveLifeEnded(Live, V, Tk);
    Exit;
  end;
  KP := DB.Profiles[KIdx];
  VP := DB.Profiles[VIdx];
  MxFirstBloods(KP^, MxFB, MxRFB);
  MxSnapTwo(Self, KIdx, VIdx, MxK, MxV);
  WS := WepSlot(W);
  M := Match.MapIndex;
  { no clear line to the victim when the kill landed: the shot went through cover (Map.RayCast).
    Until main.pas has settled which answer of RayCast means a clear line (EF_RAY_CAL), the answer
    says nothing, and no kill is Cover (live) - as Cover (shot) waits for it too (EvRay). }
  if not IsMeleeWeapon(W) and (W <> WEP_WORLD) and (W <> WEP_NONE) then
  begin
    { [Bridges]: from the killer's eyes to the victim's head, chest and hips, on the map's walls -
      covered when none of the three lines is clear }
    RayAns := -1;
    if Flags and EF_POINTS <> 0 then
    begin
      RayAns := GeoRay(E.F[9], E.F[10], E.F[11], E.F[12], Live[K].Team);
      if RayAns = 1 then
        RayAns := GeoRay(E.F[9], E.F[10], E.F[13], E.F[14], Live[K].Team);
      if RayAns = 1 then
        RayAns := GeoRay(E.F[9], E.F[10], E.F[15], E.F[16], Live[K].Team);
      if RayAns >= 0 then
        Inc(FGeoRays);
    end;
    if RayAns = 1 then
      Inc(KP^.WallKills)
    else if (RayAns < 0) and (Flags and EF_RAY_CAL <> 0) and (Flags and EF_LOS = 0) then
      Inc(KP^.WallKills);
  end;
  { near a flag base: defending the own one (victim close to it) or attacking the enemy's }
  if (M >= 0) and (M < DB.MapCount) and ((Match.GameStyle = GS_CTF) or (Match.GameStyle = GS_INF)) and
     ((Live[K].Team = TEAM_ALPHA) or (Live[K].Team = TEAM_BRAVO)) then
  begin
    R := Cfg.BaseRadiusMeters * PIXELS_PER_METER;
    if Live[K].Team = TEAM_ALPHA then
    begin
      OwnX := DB.Maps[M].AlphaFlagX;
      OwnY := DB.Maps[M].AlphaFlagY;
      FoeX := DB.Maps[M].BravoFlagX;
      FoeY := DB.Maps[M].BravoFlagY;
    end
    else
    begin
      OwnX := DB.Maps[M].BravoFlagX;
      OwnY := DB.Maps[M].BravoFlagY;
      FoeX := DB.Maps[M].AlphaFlagX;
      FoeY := DB.Maps[M].AlphaFlagY;
    end;
    if ((OwnX <> 0) or (OwnY <> 0)) and (Hypot(VX - OwnX, VY - OwnY) <= R) then
      Inc(KP^.BaseDefenseKills);
    if ((FoeX <> 0) or (FoeY <> 0)) and (Hypot(KX - FoeX, KY - FoeY) <= R) then
      Inc(KP^.BaseAttackKills);
  end;

  { distance from where the projectile was fired }
  if Flags and EF_BULLET <> 0 then
  begin
    HX := E.F[4];
    HY := E.F[5];
  end
  else
  begin
    HX := VX;
    HY := VY;
  end;
  if IsMeleeWeapon(W) or (W = WEP_NONE) then
  begin
    SX := KX;
    SY := KY;
    DistOk := True;
  end
  { [Bridges]: where the lethal bullet was made (its Initial), as the server's own kill message
    measures it - for every weapon and every shooter }
  else if Flags and EF_ORIGIN <> 0 then
  begin
    SX := E.F[7];
    SY := E.F[8];
    { a script's bullet made right at the victim says nothing about the distance: Basic-Extended
      finishes a bleeding or downed player with one made 8 px above him. One made far away (its
      Javelin, from the launcher) is measured. }
    DistOk := (Flags and EF_SCRIPT_BULLET = 0) or (Hypot(HX - SX, HY - SY) >= 2 * PIXELS_PER_METER);
  end
  else if W = WEP_M2 then
  begin
    SX := KX;
    SY := KY;
    DistOk := True;
  end
  { the lethal hit came a moment before the kill: its bullet velocity gives the direction of flight }
  else if Live[K].Pair[V].LastDamageTick >= Tk - 2 then
    DistOk := LiveFindShot(Live[K], W, Tk, HX, HY, Live[K].Pair[V].LastBVX, Live[K].Pair[V].LastBVY, SX, SY)
  else
    DistOk := LiveFindShot(Live[K], W, Tk, HX, HY, 0, 0, SX, SY);
  if DistOk then
    DistM := Hypot(HX - SX, HY - SY) / PIXELS_PER_METER
  else
    DistM := 0;
  { the same line the distance is measured on: from where the lethal shot was fired to where it hit.
    Only the script sees the walls, so it is asked and the answer arrives a tick later. }
  if DistOk and not IsMeleeWeapon(W) and (W <> WEP_NONE) and (W <> WEP_WORLD) then
  begin
    { [Bridges]: the engine has the map's walls and answers at once }
    RayAns := GeoRay(SX, SY, HX, HY, Live[K].Team);
    if RayAns >= 0 then
    begin
      Inc(FGeoRays);
      if RayAns = 1 then
      begin
        Inc(KP^.CoverShotKills);
        MxCoverShot(Self, KIdx);
      end;
      if Cfg.DebugRayCast then
        NotifyAdmins(Format('[debug] %s: the line from the shot to the hit is %s (the map in the library)',
          [KP^.ActiveName, BoolToStr(RayAns = 1, 'blocked, counted as Cover (shot)', 'clear')]), CLR_HINT);
    end
    else
      AskRay(KP^.ID, SX, SY, HX, HY);
  end;

  { points; InactiveVictimSeconds = 0 switches the inactive victim rule off (with 0 every victim
    would be inactive and every further kill of the same one worth less for the whole map) }
  Inactive := (Cfg.InactiveVictimSeconds > 0) and
    (LiveInactiveTicks(Live[V], Tk) >= Cfg.InactiveVictimSeconds * TICKS_PER_SECOND);
  if not Inactive then
    Live[K].Pair[V].InactiveKills := 0;
  Pts := KillPoints(Cfg, KP^.Points, VP^.Points, Inactive, Live[K].Pair[V].InactiveKills);
  if Inactive then
    Inc(Live[K].Pair[V].InactiveKills);
  Loss := -AddPoints(DB, VIdx, -Pts, Cfg.MinimumPoints);
  Gain := AddPoints(DB, KIdx, Pts, Cfg.MinimumPoints);
  { no "+0 pts": a victim who stood still too often is worth nothing (InactiveVictimMultipliers),
    and so is any kill with MinPointGive = 0 }
  if Gain > 0 then
  begin
    if Inactive then
      HudEvent(K, Format('+%d pts (inactive victim)', [Gain]))
    else
      HudEvent(K, Format('+%d pts', [Gain]));
  end;
  { a victim at MinimumPoints loses nothing: no "-0 pts" }
  if Loss > 0 then
    HudEvent(V, Format('-%d pts', [Loss]));

  { counters }
  Headshot := (Live[K].Pair[V].LastZone = HZ_HEAD) and (Live[K].Pair[V].LastDamageTick >= Tk - 2);
  Inc(KP^.Kills);
  Inc(VP^.Deaths);
  Inc(Live[K].SessionKills);
  Inc(Live[K].MatchKills);
  Inc(Live[V].SessionDeaths);
  Inc(Live[V].MatchDeaths);
  AddActivity(DB, KIdx, Match.GameStyle, 1, 0, 0, 0, 0, 0, Ord(Headshot), 0);
  AddActivity(DB, VIdx, Match.GameStyle, 0, 1, 0, 0, 0, 0, 0, 0);
  if WS >= 0 then
  begin
    Inc(KP^.Weapons[WS].Kills);
    Inc(VP^.Weapons[WS].Deaths);
    if Headshot then
      Inc(KP^.Weapons[WS].HSKills);
    if DistOk and (DistM > KP^.Weapons[WS].LongestKill) then
      KP^.Weapons[WS].LongestKill := DistM;
  end;

  if DistOk and (DistM > 0) then
  begin
    if DistM > KP^.LongestKillDistance then
      KP^.LongestKillDistance := DistM;
    KP^.TotalKillDistance := KP^.TotalKillDistance + DistM;
    Inc(KP^.KillDistanceCount);
    if WS = WEP_BARRETT then
    begin
      if DistM > KP^.LongestBarrettDistance then
        KP^.LongestBarrettDistance := DistM;
      if DistM >= 75 then
        Inc(KP^.BarrettLongKills);
    end;
    if DistM >= 100 then
    begin
      Inc(KP^.LongKills100);
      HudEvent(K, Format('Long shot: %d m', [Round(DistM)]));
    end;
  end;

  { [Bridges]: a second victim of one bullet (its slot, the tick it was fired and where - a slot is
    soon taken by another bullet); not for a blast, a flame or a blade (one grenade killing two is
    ExplosionMultiKills) }
  if (Flags and EF_ORIGIN <> 0) and (Flags and EF_SCRIPT_BULLET = 0) and not IsMeleeWeapon(W) and
     not IsExplosiveWeapon(W) and (W <> WEP_FLAMER) then
  begin
    if (Live[K].LastKillBullet = E.I[0]) and (Live[K].LastKillOrigin = E.I[4]) and
       (Live[K].LastKillOX = E.F[7]) and (Live[K].LastKillOY = E.F[8]) then
    begin
      Inc(KP^.CollateralKills);
      HudEvent(K, 'Collateral!');
    end;
    Live[K].LastKillBullet := E.I[0];
    Live[K].LastKillOrigin := E.I[4];
    Live[K].LastKillOX := E.F[7];
    Live[K].LastKillOY := E.F[8];
  end;
  { killed from behind: the lethal bullet flew the way the victim faced (his Direction), so it came
    at his back; not a blast, a flame, or a shot from (nearly) straight above or below }
  if (Flags and EF_MEMORY <> 0) and ((E.I[5] = 1) or (E.I[5] = -1)) and not IsExplosiveWeapon(W) and
     (W <> WEP_FLAMER) and (W <> WEP_WORLD) then
  begin
    BackDX := E.F[17];
    if (Abs(BackDX) > BACK_MIN_SPEED) and (Abs(BackDX) >= 0.5 * Abs(E.F[18])) and ((BackDX > 0) = (E.I[5] > 0)) then
    begin
      Inc(KP^.BackKills);
      Inc(VP^.BackDeaths);
    end;
  end;
  { the longest kill with a hit in the head: only when the server's own hit test named the head }
  if Headshot and DistOk and Live[K].Pair[V].LastZoneExact and (DistM > KP^.LongestHeadshotM) then
    KP^.LongestHeadshotM := DistM;
  { the flight of a lethal bullet fired straight at the victim - not a grenade (its time is a fuse),
    a flame, a blade, nor a script's bullet: the longest, and the ticks added up for the average (of
    the account and of the weapon) }
  Air := -1;
  if (Flags and EF_ORIGIN <> 0) and (Flags and EF_SCRIPT_BULLET = 0) and AirTimed(W) and (Tk >= E.I[4]) and
     (Tk - E.I[4] <= MAX_FLIGHT_TICKS) then
  begin
    Air := Tk - E.I[4];
    if Air / TICKS_PER_SECOND > KP^.LongestFlightKill then
      KP^.LongestFlightKill := Air / TICKS_PER_SECOND;
    Inc(KP^.KillAirTicks, Air);
    Inc(KP^.KillAirCount);
    if WS >= 0 then
    begin
      Inc(KP^.Weapons[WS].KillAirTicks, Air);
      Inc(KP^.Weapons[WS].KillAirCount);
      MxKillAir(Self, KIdx, WS, Air);
    end;
  end;

  if WS >= 0 then
  begin
    if DistOk then
    begin
      if DistM < 10 then
        Bucket := 0
      else if DistM < 25 then
        Bucket := 1
      else if DistM < 50 then
        Bucket := 2
      else if DistM < 100 then
        Bucket := 3
      else
        Bucket := 4;
      Inc(DB.Server.WeaponGlobal[WS].DistBucket[Bucket]);
      DB.Server.WeaponGlobal[WS].KillDistSum := DB.Server.WeaponGlobal[WS].KillDistSum + DistM;
      Inc(DB.Server.WeaponGlobal[WS].KillDistCount);
      { the same for the killer's own weapon }
      Inc(KP^.Weapons[WS].DistBucket[Bucket]);
      KP^.Weapons[WS].KillDistSum := KP^.Weapons[WS].KillDistSum + DistM;
      Inc(KP^.Weapons[WS].KillDistCount);
    end;
    if WepSlot(VW) >= 0 then
      Inc(DB.Server.Matchups[WS, WepSlot(VW)]);
    if E.F[6] > 0 then
      Inc(DB.Server.WeaponGlobal[WS].VestKills);
    if E.F[6] > 0 then
      Inc(KP^.Weapons[WS].VestKills);
  end;
  D := DailyEntry;
  if D >= 0 then
    Inc(DB.Server.Daily[D].Kills);
  DB.TouchServer;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    Inc(DB.Maps[M].Kills);
    if WS >= 0 then
      Inc(DB.Maps[M].WeaponKills[WS]);
    { [Bridges] (5.6): the flight of the lethal bullet, as the killer's }
    if Air >= 0 then
    begin
      Inc(DB.Maps[M].KillAirTicks, Air);
      Inc(DB.Maps[M].KillAirCount);
    end;
    HeatAdd(M, KX, KY, True);
    HeatAdd(M, VX, VY, False);
    MxMapKill(Self, M, K, WS, VW);
    DB.TouchMap(M);
  end;

  { streaks: the shut-downs keep counting from 5 kills, the message follows the first level }
  if Live[V].KillStreak >= 5 then
  begin
    Inc(KP^.ShutDownKills);
    HudEvent(K, 'Shut down ' + Live[V].Name + '''s spree');
  end;
  if Cfg.SpreesEnabled and (Cfg.SpreeLevelCount > 0) and (Live[V].KillStreak >= Cfg.SpreeLevels[0].Kills) then
    SpreeMessage(Self, SpreeText(Cfg.SpreeShutText, [Live[K].Name, Live[V].Name], Live[V].KillStreak),
      Cfg.SpreeShutStyle, True);
  Inc(Live[K].KillStreak);
  if Live[K].KillStreak > KP^.MaxKillStreak then
    KP^.MaxKillStreak := Live[K].KillStreak;
  { every length is counted (the levels of [Sprees] may change), the last one for longer streaks too }
  if Live[K].KillStreak <= SPREE_MAX_KILLS then
    Inc(KP^.SpreeLives[Live[K].KillStreak]);
  { the counters of the fixed levels before, which the achievements read }
  case Live[K].KillStreak of
    5: Inc(KP^.SpreeKills);
    10: Inc(KP^.RampageKills);
    15: Inc(KP^.DominatingSpreeKills);
    20: Inc(KP^.UnstoppableKills);
    25: Inc(KP^.GodlikeKills);
  end;
  Lv := SpreeLevelOf(Cfg, Live[K].KillStreak);
  if Lv >= 0 then
  begin
    HudEvent(K, UpperCase(Cfg.SpreeLevels[Lv].Name) + '!');
    if Cfg.SpreesEnabled then
      SpreeMessage(Self, SpreeText(Cfg.SpreeLevels[Lv].Text, [Live[K].Name], Live[K].KillStreak),
        Cfg.SpreeLevels[Lv].Style, False);
  end;
  if WS = WEP_KNIFE then
  begin
    Inc(Live[K].KnifeKillsLife);
    if Live[K].KnifeKillsLife > KP^.KnifeKillsLifeBest then
      KP^.KnifeKillsLifeBest := Live[K].KnifeKillsLife;
  end;

  if (Live[K].LastKillTick > 0) and (Tk - Live[K].LastKillTick <= Round(Cfg.MultiKillWindowSeconds * TICKS_PER_SECOND)) then
  begin
    Inc(Live[K].MultiKillCount);
    case Live[K].MultiKillCount of
      1:
        begin
          Inc(KP^.PointmatchMode.Multi.DOUBLE_KILL);
          HudEvent(K, 'Double kill!');
        end;
      2:
        begin
          Inc(KP^.PointmatchMode.Multi.TRIPLE_KILL);
          HudEvent(K, 'Triple kill!');
        end;
      3:
        begin
          Inc(KP^.PointmatchMode.Multi.MULTI_KILL);
          HudEvent(K, 'Multi kill!');
        end;
      4: Inc(KP^.PointmatchMode.Multi.MULTI_KILL_X2);
      5: Inc(KP^.PointmatchMode.Multi.SERIAL_KILL);
      6: Inc(KP^.PointmatchMode.Multi.INSANE_KILLS);
      7: Inc(KP^.PointmatchMode.Multi.GIMME_MORE);
      8..10: Inc(KP^.PointmatchMode.Multi.MASTA_KILLA);
      11: Inc(KP^.PointmatchMode.Multi.STOP_IT);
      12: Inc(KP^.PointmatchMode.Multi.MERCY);
      else Inc(KP^.PointmatchMode.Multi.CHEATER);
    end;
  end
  else
    Live[K].MultiKillCount := 0;
  Live[K].LastKillTick := Tk;

  if IsExplosiveWeapon(W) then
  begin
    if (Tk - Live[K].ExplosionTick <= 3) and (Live[K].ExplosionSlot = WS) then
    begin
      Inc(Live[K].ExplosionKills);
      if Live[K].ExplosionKills = 2 then
        Inc(KP^.ExplosionMultiKills);
    end
    else
    begin
      Live[K].ExplosionTick := Tk;
      Live[K].ExplosionSlot := WS;
      Live[K].ExplosionKills := 1;
    end;
  end;

  { the first kill of the match, once per match; in survival also the first kill of each round,
    counted apart. The first kill of the first round is both, and the HUD says the one of the
    match. }
  if not Match.FirstBlood then
  begin
    Match.FirstBlood := True;
    Inc(KP^.FirstBloodCount);
    HudEvent(K, 'FIRST BLOOD!');
  end
  else if Match.Survival and not Match.RoundFirstBlood then
    HudEvent(K, 'ROUND FIRST BLOOD');
  if Match.Survival and not Match.RoundFirstBlood then
  begin
    Match.RoundFirstBlood := True;
    Inc(KP^.RoundFirstBloodCount);
  end;

  UpdateNemesis(KP^.TopVictims, VP^.ID);
  UpdateNemesis(VP^.TopNemeses, KP^.ID);

  Inc(Live[K].Pair[V].Streak);
  if Live[K].Pair[V].Streak = 3 then
  begin
    Inc(KP^.DominatingCount);
    HudEvent(K, 'Dominating ' + Live[V].Name);
    HudEvent(V, Live[K].Name + ' is dominating you');
  end;
  if Live[V].Pair[K].Streak >= 3 then
  begin
    Inc(KP^.RevengeFeats);
    HudEvent(K, 'Domination ended!');
  end;
  Live[V].Pair[K].Streak := 0;
  if Live[K].Pair[V].RevengeOpen then
  begin
    Inc(KP^.RevengeKills);
    HudEvent(K, 'Revenge!');
    Live[K].Pair[V].RevengeOpen := False;
  end;
  Live[V].Pair[K].RevengeOpen := True;

  if Flags and EF_A_FLAGGER <> 0 then
    Inc(KP^.KillsWhenHaveFlag);
  if Flags and EF_B_FLAGGER <> 0 then
  begin
    Inc(KP^.FlaggerKills);
    HudEvent(K, 'Flag carrier down');
  end;
  if Flags and EF_A_PRONE <> 0 then
    Inc(KP^.ProneKills)
  else if Flags and EF_A_ONGROUND = 0 then
    Inc(KP^.AirKills);
  if Flags and EF_A_ALIVE = 0 then
    Inc(KP^.PosthumousKills);
  if LiveCampTicks(Live[K], Tk) >= Cfg.CampSeconds * TICKS_PER_SECOND then
    Inc(KP^.CampKills);
  if (Live[V].Pair[K].LastDamageTick > 0) and (Tk - Live[V].Pair[K].LastDamageTick <= Round(Cfg.BinkSeconds * TICKS_PER_SECOND)) and
     (Live[V].Pair[K].DamageThisLife >= Cfg.BinkDamage) then
    Inc(KP^.BinkRecoveryKills);
  if KY + Cfg.HeightAdvantagePixels < VY then
    Inc(KP^.HeightKills);
  if E.F[6] > 0 then
    Inc(KP^.VestKills);
  { Survival has no spawn kills: nobody respawns during a round, everybody spawns together when it
    starts, so a kill right after that spawn is an ordinary one. }
  if not Match.Survival and (Live[V].SpawnTick > 0) and
     (Tk - Live[V].SpawnTick <= Round(Cfg.SpawnKillSeconds * TICKS_PER_SECOND)) then
  begin
    Inc(KP^.SpawnKills);
    Inc(VP^.SpawnDeaths);
  end;
  if (WS = WSLOT_FRAG) or (WS = WSLOT_CLUSTER) then
    Inc(KP^.GrenadeKills);
  if IsFinisherWeapon(W) and (Live[K].Pair[V].LastPrimaryHitTick > 0) and
     (Tk - Live[K].Pair[V].LastPrimaryHitTick <= Round(Cfg.FinisherSeconds * TICKS_PER_SECOND)) then
  begin
    Inc(KP^.FinisherKills);
    HudEvent(K, 'Finisher');
  end;
  if TeamGame then
    for A := 1 to MAX_PLAYERS do
      if (A <> K) and Live[A].Active and Live[A].Alive and LiveIsTeammate(Live, K, A, True) and
         (Live[A].Flags and EF_A_FLAGGER <> 0) and
         ((Hypot(KX - Live[A].X, KY - Live[A].Y) <= Cfg.EscortRadius) or
          (Hypot(VX - Live[A].X, VY - Live[A].Y) <= Cfg.EscortRadius)) then
      begin
        Inc(KP^.CarrierEscortKills);
        Break;
      end;

  if Live[K].Pair[V].FirstDamageTick > 0 then
  begin
    TTK := Tk - Live[K].Pair[V].FirstDamageTick;
    if TTK >= 0 then
    begin
      Inc(KP^.TTKSumTicks, TTK);
      Inc(KP^.TTKCount);
      if (KP^.BestTTKTicks <= 0) or (Max(1, TTK) < KP^.BestTTKTicks) then
        KP^.BestTTKTicks := Max(1, TTK);
      if WS >= 0 then
      begin
        Inc(DB.Server.WeaponGlobal[WS].TTKSumTicks, TTK);
        Inc(DB.Server.WeaponGlobal[WS].TTKCount);
        Inc(KP^.Weapons[WS].TTKSumTicks, TTK);
        Inc(KP^.Weapons[WS].TTKCount);
      end;
    end;
  end;

  { assists work in every mode: any enemy of the victim who did enough damage recently }
  AssistDamage := Cfg.AssistMinDamagePercent / 100 * EffectiveMaxHealth;
  for A := 1 to MAX_PLAYERS do
  begin
    if (A = K) or (A = V) or not Live[A].Active or not Live[A].Human then
      Continue;
    if LiveIsEnemy(Live, A, V, TeamGame) and (Live[A].Pair[V].LastDamageTick > 0) and
       (Tk - Live[A].Pair[V].LastDamageTick <= Round(Cfg.AssistSeconds * TICKS_PER_SECOND)) and
       (Live[A].Pair[V].DamageThisLife >= AssistDamage) then
    begin
      AIdx := Identity.StatsIndex(A);
      if DB.Valid(AIdx) then
      begin
        AP := DB.Profiles[AIdx];
        Inc(AP^.Assist);
        if Flags and EF_B_FLAGGER <> 0 then
          Inc(AP^.FlaggerKillsAssist);
        MxAssist(Self, AIdx, Flags and EF_B_FLAGGER <> 0);
        DB.Touch(AIdx);
        HudEvent(A, 'Assist');
      end;
    end;
  end;
  if TeamGame then
  begin
    { one savior kill whoever of the team the victim had hit, and a flag defense when one of them
      carries a flag - not only when the first one the loop meets does }
    Saved := False;
    SavedFlagger := False;
    for A := 1 to MAX_PLAYERS do
      if (A <> K) and Live[A].Active and LiveIsTeammate(Live, K, A, True) and (Live[V].Pair[A].DamagedTick > 0) and
         (Tk - Live[V].Pair[A].DamagedTick <= Round(Cfg.SaviorSeconds * TICKS_PER_SECOND)) then
      begin
        Saved := True;
        if Live[A].Flags and EF_A_FLAGGER <> 0 then
          SavedFlagger := True;
      end;
    if Saved then
    begin
      Inc(KP^.SaviorKills);
      if SavedFlagger then
        Inc(KP^.SaviorFlaggerKills);
      HudEvent(K, 'Savior');
    end;
    for A := 1 to MAX_PLAYERS do
      if (A <> K) and Live[A].Active and LiveIsTeammate(Live, K, A, True) and (Live[V].Pair[A].KilledTick > 0) and
         (Tk - Live[V].Pair[A].KilledTick <= Round(Cfg.AvengerSeconds * TICKS_PER_SECOND)) then
      begin
        Inc(KP^.AvengerKills);
        HudEvent(K, 'Avenger');
        Break;
      end;
  end;
  Live[K].Pair[V].KilledTick := Tk;

  if Match.GameStyle = GS_RM then
  begin
    if IsBow(W) then
      Inc(KP^.RamboMode.KillsByBow);
    if IsBow(VW) then
      Inc(KP^.RamboMode.KillRamboCount)
    else if not IsBow(W) then
    begin
      Inc(KP^.RamboMode.KillsWhenNoRambo);
      Inc(VP^.RamboMode.DeathsWhenNoRambo);
    end;
  end;

  if SuspiciousKill(Live[K].Pair[V], Tk, Live[V].MatchKills, HumansPlaying, Cfg) then
    LogSuspicious(K, V);

  MxKill(Self, E, KIdx, VIdx, WS, DistOk, DistM, Gain, Loss, MxFB, MxRFB);
  MxFollow(Self, MxK);
  MxFollow(Self, MxV);
  NoteProtectionActivity(DB, KIdx, Cfg);
  NoteProtectionActivity(DB, VIdx, Cfg);
  DB.Touch(KIdx);
  DB.Touch(VIdx);
  AfterProfileChange(KIdx);
  LiveLifeEnded(Live, V, Tk);
end;

procedure TZSEngine.CountHurt(S, V, Weapon: LongInt; IsSelf, Friendly: Boolean; SIdx, VIdx: LongInt);
var
  SP, VP: PPlayerProfile;
begin
  SP := DB.Profiles[SIdx];
  if DB.Valid(VIdx) then
    VP := DB.Profiles[VIdx]
  else
    VP := nil;
  case Weapon of
    WEP_M79:
      if IsSelf then
        Inc(SP^.M79HurtsSelf)
      else if Friendly then
      begin
        Inc(SP^.M79HurtsFriendly);
        if VP <> nil then Inc(VP^.M79HurtsByFriendly);
      end
      else
        Inc(SP^.M79HurtsEnemy);
    WEP_KNIFE:
      if Friendly then
      begin
        Inc(SP^.KnivesStabsFriendly);
        if VP <> nil then Inc(VP^.KnivesStabsByFriendly);
      end
      else if not IsSelf then
        Inc(SP^.KnivesStabsEnemy);
    WEP_THROWNKNIFE:
      if IsSelf then
        Inc(SP^.KnivesThrowsHitsSelf)
      else if Friendly then
      begin
        Inc(SP^.KnivesThrowsHitsFriends);
        if VP <> nil then Inc(VP^.KnivesThrowsHitsByFriends);
      end
      else
        Inc(SP^.KnivesThrowsHitsEnemy);
    WEP_CHAINSAW:
      if Friendly then
      begin
        Inc(SP^.ChainsawHurtsFriendly);
        if VP <> nil then Inc(VP^.ChainsawHurtsByFriendly);
      end
      else if not IsSelf then
        Inc(SP^.ChainsawHurtsEnemy);
    WEP_LAW:
      if IsSelf then
        Inc(SP^.M72LAWHurtsSelf)
      else if Friendly then
      begin
        Inc(SP^.M72LAWHurtsFriendly);
        if VP <> nil then Inc(VP^.M72LAWHurtsByFriendly);
      end
      else
        Inc(SP^.M72LAWHurtsEnemy);
    WEP_FLAMER:
      if IsSelf then
        Inc(SP^.FlamethrowerHitsSelf)
      else if Friendly then
      begin
        Inc(SP^.FlamethrowerHitsFriendly);
        if VP <> nil then Inc(VP^.FlamethrowerHitsByFriendly);
      end
      else
        Inc(SP^.FlamethrowerHitsEnemy);
    WEP_BOW2:
      if IsSelf then
        Inc(SP^.BowFlamedArrowsHurtsSelf)
      else if Friendly then
      begin
        Inc(SP^.BowFlamedArrowsHurtsFriendly);
        if VP <> nil then Inc(VP^.BowFlamedArrowsHurtsByFriendly);
      end
      else
        Inc(SP^.BowFlamedArrowsHurtsEnemy);
    WEP_M2:
      if Friendly then
      begin
        Inc(SP^.M2MGHitsFriendly);
        if VP <> nil then Inc(VP^.M2MGHitsByFriendly);
      end
      else if not IsSelf then
        Inc(SP^.M2MGHitsEnemy);
    WEP_FRAG:
      if IsSelf then
        Inc(SP^.NadeHurtsSelf)
      else if Friendly then
      begin
        Inc(SP^.NadeHurtsFriendly);
        if VP <> nil then Inc(VP^.NadeHurtsByFriendly);
      end
      else
        Inc(SP^.NadeHurtsEnemy);
    WEP_CLUSTERNADE, WEP_CLUSTER:
      if IsSelf then
        Inc(SP^.ClusterNadesHurtsSelf)
      else if Friendly then
      begin
        Inc(SP^.ClusterNadesHurtsFriendly);
        if VP <> nil then Inc(VP^.ClusterNadesHurtsByFriendly);
      end
      else
        Inc(SP^.ClusterNadesHurtsEnemy);
    WEP_NONE:
      if Friendly then
      begin
        Inc(SP^.HandsHurtsFriendly);
        if VP <> nil then Inc(VP^.HandsHurtsByFriendly);
      end
      else if not IsSelf then
        Inc(SP^.HandsHurtsEnemy);
  end;
end;

{ [Bridges] (5.6): a hit on an enemy with a bullet whose origin the server's memory told (and the hook saw
  made): the metres from there to the hit - as the kill distance, the number of the server's own kill
  message - and the ticks it flew, for the account at SIdx and its weapon, the map, and the player's
  record of the map (its sums follow the account's). A blade or a fist has no distance; a flame or a
  grenade no air time. }
procedure CountHitFlight(Eng: TZSEngine; SIdx, WS, W: LongInt; const E: TZSEvent);
var
  HX, HY: Single;
  HitM: Double;
  Air, M: LongInt;
  SP: PPlayerProfile;
begin
  if IsMeleeWeapon(W) or (W = WEP_WORLD) then
    Exit;
  if E.I[2] and EF_BULLET <> 0 then
  begin
    HX := E.F[2];
    HY := E.F[3];
  end
  else
  begin
    HX := E.F[6];
    HY := E.F[7];
  end;
  HitM := Hypot(HX - E.F[13], HY - E.F[14]) / PIXELS_PER_METER;
  if IsNan(HitM) or IsInfinite(HitM) then
    Exit;
  if AirTimed(W) and (Eng.GameTick >= E.I[4]) and (Eng.GameTick - E.I[4] <= MAX_FLIGHT_TICKS) then
    Air := Eng.GameTick - E.I[4]
  else
    Air := -1;
  SP := Eng.DB.Profiles[SIdx];
  SP^.HitDistSum := SP^.HitDistSum + HitM;
  Inc(SP^.HitDistCount);
  if HitM > SP^.LongestHitM then
    SP^.LongestHitM := HitM;
  if Air >= 0 then
  begin
    Inc(SP^.HitAirTicks, Air);
    Inc(SP^.HitAirCount);
  end;
  if WS >= 0 then
  begin
    SP^.Weapons[WS].HitDistSum := SP^.Weapons[WS].HitDistSum + HitM;
    Inc(SP^.Weapons[WS].HitDistCount);
    if HitM > SP^.Weapons[WS].LongestHit then
      SP^.Weapons[WS].LongestHit := HitM;
    if Air >= 0 then
    begin
      Inc(SP^.Weapons[WS].HitAirTicks, Air);
      Inc(SP^.Weapons[WS].HitAirCount);
    end;
  end;
  { the map's own counters: how far the hits here flew }
  M := Eng.Match.MapIndex;
  if (M >= 0) and (M < Eng.DB.MapCount) then
  begin
    Eng.DB.Maps[M].HitDistSum := Eng.DB.Maps[M].HitDistSum + HitM;
    Inc(Eng.DB.Maps[M].HitDistCount);
    if HitM > Eng.DB.Maps[M].LongestHit then
      Eng.DB.Maps[M].LongestHit := HitM;
    if Air >= 0 then
    begin
      Inc(Eng.DB.Maps[M].HitAirTicks, Air);
      Inc(Eng.DB.Maps[M].HitAirCount);
    end;
    Eng.DB.TouchMap(M);
  end;
  MxHitFlight(Eng, SIdx, WS, HitM, Air);
end;

procedure TZSEngine.EvDamage(var E: TZSEvent);
var
  { [Matrix]: the counters of the shooter and of the victim before this hit }
  MxS, MxV: TMxSnap;
  S, V, W, WS, Flags, Zone, Posture, SIdx, VIdx: LongInt;
  Dmg, Speed, Cap: Single;
  DX, DY: Double;
  IsSelf, Friendly, Vest, Berserk, ShotHit: Boolean;
  SP, VP: PPlayerProfile;
begin
  S := E.Slot;
  V := E.Slot2;
  if not SlotValid(S) or not SlotValid(V) then
    Exit;
  Dmg := E.F[0];
  if Dmg <= 0 then
    Exit;
  W := E.I[1];
  Flags := E.I[2];
  { damage that is not a bullet of the shooter (fall, lava, a script): no hit and no weapon }
  if W = WEP_WORLD then
    Exit;
  WS := WepSlot(W);
  IsSelf := S = V;
  { survival kills a player who changes the team mid-round with a hit of their own }
  if IsSelf and (Flags and EF_SERVER_KILL <> 0) then
    Exit;
  if IsSelf and Match.Survival and (Live[V].TeamSinceTick = E.Tick) then
    Exit;
  Friendly := not IsSelf and TeamGame and (Live[S].Team = Live[V].Team);

  Zone := HZ_UNKNOWN;
  if (Flags and EF_BULLET <> 0) and ZoneClassifiableStyle(W) then
  begin
    Speed := Hypot(E.F[4], E.F[5]);
    Vest := E.F[1] > 0;
    Berserk := GameTick < Live[S].BerserkUntil;
    Posture := PostureOf(Flags, True);
    HitOffset(E.F[2], E.F[3], E.F[4], E.F[6], E.F[7], DX, DY);
    if WeaponHasDistinctZones(W) then
    begin
      Zone := ClassifyZoneByDamage(W, Dmg, Speed, Vest, Berserk);
      { hits whose damage names the zone teach the model used for weapons where it cannot }
      if (Zone >= HZ_HEAD) and (Zone <= HZ_LEGS) and not IsSelf then
      begin
        HitModelLearn(DB.Server.HitModel[Posture, Zone], DX, DY);
        DB.TouchServer;
      end;
    end
    else
      Zone := HitModelClassify(DB.Server.HitModel[Posture], DX, DY, HIT_MODEL_MIN_SAMPLES);
  end;
  { [Bridges]: the zone the bullet hit on the victim's skeleton, as the server tests it - exact for
    every weapon; the zone the damage tells is compared with it (/zs_perf) }
  if (Flags and EF_ZONE <> 0) and ZoneClassifiableStyle(W) and (E.I[3] >= HZ_HEAD) and (E.I[3] <= HZ_LEGS) then
  begin
    if WeaponHasDistinctZones(W) and (Zone >= HZ_HEAD) and (Zone <= HZ_LEGS) then
    begin
      if Zone = E.I[3] then
        Inc(FZoneSame)
      else
        Inc(FZoneDiff);
    end;
    Zone := E.I[3];
  end;

  { A hit takes at most the health the victim still had: a Barrett or a grenade on a wounded
    player counts only what was left. The zone above still used the raw damage. }
  Cap := EffectiveMaxHealth;
  if (E.F[8] > 0) and (E.F[8] < Cap) then
    Cap := E.F[8];
  if Dmg > Cap then
    Dmg := Cap;
  { !lastfight: the hit for the one who took it and the one who dealt it }
  LastFightHit(Self, E, Dmg, Zone);

  if not IsSelf and not Friendly then
  begin
    Live[S].Pair[V].DamagedTick := GameTick;
    Live[S].Pair[V].DamageThisLife := Live[S].Pair[V].DamageThisLife + Dmg;
    if Live[S].Pair[V].FirstDamageTick = 0 then
      Live[S].Pair[V].FirstDamageTick := GameTick;
    Live[S].Pair[V].LastDamageTick := GameTick;
    Live[S].Pair[V].LastZone := Zone;
    Live[S].Pair[V].LastZoneExact := Flags and EF_ZONE <> 0;
    if Flags and EF_BULLET <> 0 then
    begin
      Live[S].Pair[V].LastBVX := E.F[4];
      Live[S].Pair[V].LastBVY := E.F[5];
    end
    else
    begin
      Live[S].Pair[V].LastBVX := 0;
      Live[S].Pair[V].LastBVY := 0;
    end;
    if IsPrimaryGun(W) then
      Live[S].Pair[V].LastPrimaryHitTick := GameTick;
    if (Flags and EF_B_FLAGGER <> 0) and (Live[V].ContestedSinceTick = 0) then
      Live[V].ContestedSinceTick := GameTick;
  end;

  if not (Live[S].Human and Live[V].Human and StatsOn) then
    Exit;
  SIdx := Identity.StatsIndex(S);
  VIdx := Identity.StatsIndex(V);
  if not DB.Valid(SIdx) then
    Exit;
  SP := DB.Profiles[SIdx];
  if DB.Valid(VIdx) then
    VP := DB.Profiles[VIdx]
  else
    VP := nil;
  MxSnapTwo(Self, SIdx, VIdx, MxS, MxV);

  if IsSelf then
  begin
    Inc(SP^.ShotsHitsSelf);
    case Zone of
      HZ_HEAD: Inc(SP^.ShotsHitsSelfHead);
      HZ_BODY: Inc(SP^.ShotsHitsSelfBody);
      HZ_LEGS: Inc(SP^.ShotsHitsSelfLeg);
    end;
  end
  else if Friendly then
  begin
    SP^.DamageFriendly := SP^.DamageFriendly + Dmg;
    Inc(SP^.ShotsHitsFriendly);
    case Zone of
      HZ_HEAD: Inc(SP^.ShotsHitsFriendlyHead);
      HZ_BODY: Inc(SP^.ShotsHitsFriendlyBody);
      HZ_LEGS: Inc(SP^.ShotsHitsFriendlyLeg);
    end;
    if VP <> nil then
    begin
      VP^.DamageFriendlyReceived := VP^.DamageFriendlyReceived + Dmg;
      Inc(VP^.ShotsHitsByFriendly);
      case Zone of
        HZ_HEAD: Inc(VP^.ShotsHitsByFriendlyHead);
        HZ_BODY: Inc(VP^.ShotsHitsByFriendlyBody);
        HZ_LEGS: Inc(VP^.ShotsHitsByFriendlyLeg);
      end;
      DB.Touch(VIdx);
    end;
  end
  else
  begin
    SP^.DamageDealt := SP^.DamageDealt + Dmg;
    if not Match.FirstDamage then
    begin
      Match.FirstDamage := True;
      Inc(SP^.FirstDamageCount);
    end;
    { [Bridges]: a bullet the hook did not see made is a script's (a mine, a guided rocket, an
      extra shot of another script): its damage is the player's, but no shot of his went with it,
      so it is no hit of his accuracy and no hit of a zone }
    ShotHit := Flags and EF_SCRIPT_BULLET = 0;
    if CountsForAccuracy(W) and ShotHit then
    begin
      Inc(SP^.ShotsHits);
      { the accuracy by stance: how the shooter stood when he fired (the hook's shots) }
      if FBrHook and (E.I[5] >= POSTURE_STAND) and (E.I[5] <= POSTURE_AIR) and (Flags and EF_MEMORY <> 0) then
        Inc(SP^.StanceHits[E.I[5]]);
    end;
    { zones only exist for bullets; an explosion, a flame or a blade has none, so it is not an
      "unclear" hit either }
    if ZoneClassifiableStyle(W) and ShotHit then
      case Zone of
        HZ_HEAD:
          begin
            Inc(SP^.ShotsHitsHead);
            Inc(Live[S].SessionHeadshots);
          end;
        HZ_BODY: Inc(SP^.ShotsHitsBody);
        HZ_LEGS: Inc(SP^.ShotsHitsLeg);
        else Inc(SP^.ShotsHitsUnknown);
      end;
    if WS >= 0 then
    begin
      if ShotHit then
      begin
        Inc(SP^.Weapons[WS].Hits);
        if ZoneClassifiableStyle(W) then
          case Zone of
            HZ_HEAD: Inc(SP^.Weapons[WS].Headshots);
            HZ_BODY: Inc(SP^.Weapons[WS].HitsBody);
            HZ_LEGS: Inc(SP^.Weapons[WS].HitsLegs);
            else Inc(SP^.Weapons[WS].HitsUnknown);
          end;
      end;
      SP^.Weapons[WS].Damage := SP^.Weapons[WS].Damage + Dmg;
      if VP <> nil then
        VP^.Weapons[WS].DamageReceived := VP^.Weapons[WS].DamageReceived + Dmg;
    end;
    { [Bridges]: how far the hit flew and for how long, from where and when its bullet was made }
    if ShotHit and (Flags and EF_ORIGIN <> 0) then
      CountHitFlight(Self, SIdx, WS, W, E);
    if VP <> nil then
    begin
      VP^.DamageReceived := VP^.DamageReceived + Dmg;
      DB.Touch(VIdx);
    end;
    MxDamage(Self, SIdx, VIdx, W, Dmg, Zone, ShotHit);
  end;
  CountHurt(S, V, W, IsSelf, Friendly, SIdx, VIdx);
  MxFollow(Self, MxS);
  MxFollow(Self, MxV);
  DB.Touch(SIdx);
end;

procedure TZSEngine.EvFlag(var E: TZSEvent);
var
  S, Kind, Team, Idx, M, A, k, n, Gain: LongInt;
  P: PPlayerProfile;
  CapSec: Double;
  Enemies, Mates, EnemySlots, MateSlots, Gains, Losses: TIntArray;
  { [Matrix]: the counters of the player before this flag event }
  MxP: TMxSnap;
begin
  { main.pas reports where the flags stand in their bases, without a player }
  if E.I[0] = FLAG_BASE then
  begin
    M := Match.MapIndex;
    if (M >= 0) and (M < DB.MapCount) then
    begin
      if (E.I[1] = TEAM_ALPHA) and ((Abs(DB.Maps[M].AlphaFlagX - E.F[0]) > 1) or (Abs(DB.Maps[M].AlphaFlagY - E.F[1]) > 1)) then
      begin
        DB.Maps[M].AlphaFlagX := E.F[0];
        DB.Maps[M].AlphaFlagY := E.F[1];
        DB.TouchMap(M);
      end
      else if (E.I[1] = TEAM_BRAVO) and ((Abs(DB.Maps[M].BravoFlagX - E.F[0]) > 1) or (Abs(DB.Maps[M].BravoFlagY - E.F[1]) > 1)) then
      begin
        DB.Maps[M].BravoFlagX := E.F[0];
        DB.Maps[M].BravoFlagY := E.F[1];
        DB.TouchMap(M);
      end;
    end;
    Exit;
  end;
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  Kind := E.I[0];
  BalOnFlag(S, Kind);
  Team := Live[S].Team;
  M := Match.MapIndex;
  if (M >= DB.MapCount) or not StatsOn then
    M := -1;
  Idx := -1;
  if Live[S].Human and StatsOn then
    Idx := Identity.StatsIndex(S);
  if DB.Valid(Idx) then
    P := DB.Profiles[Idx]
  else
    P := nil;
  MxSnap(Self, Idx, MxP);

  case Kind of
    FLAG_SCORE:
      begin
        if P <> nil then
        begin
          Inc(P^.FlagsScore);
          if Team = TEAM_ALPHA then
            Inc(P^.AlphaScore)
          else if Team = TEAM_BRAVO then
            Inc(P^.BravoScore);
          Inc(Live[S].SessionCaps);
          Inc(Live[S].MatchCaps);
          AddActivity(DB, Idx, Match.GameStyle, 0, 0, 1, 0, 0, 0, 0, 0);
          if Live[S].FlagGrabTick > 0 then
          begin
            CapSec := (GameTick - Live[S].FlagGrabTick) / TICKS_PER_SECOND;
            if CapSec >= 0.5 then
            begin
              if (P^.FastestCapSeconds <= 0) or (CapSec < P^.FastestCapSeconds) then
                P^.FastestCapSeconds := CapSec;
              if CapSec < 10 then
                Inc(P^.CapsUnder10s);
              MxCapTime(Self, Idx, CapSec);
              if M >= 0 then
              begin
                DB.Maps[M].CapTimeSum := DB.Maps[M].CapTimeSum + CapSec;
                Inc(DB.Maps[M].CapTimeCount);
                if (DB.Maps[M].FastestCapSeconds <= 0) or (CapSec < DB.Maps[M].FastestCapSeconds) then
                begin
                  DB.Maps[M].FastestCapSeconds := CapSec;
                  DB.Maps[M].FastestCapHolder := P^.ActiveName;
                end;
              end;
            end;
          end;
          if Match.GameStyle = GS_CTF then
          begin
            Enemies := nil;
            Mates := nil;
            for A := 1 to MAX_PLAYERS do
            begin
              if (A = S) or not Live[A].Active or not Live[A].Human then
                Continue;
              k := Identity.StatsIndex(A);
              if not DB.Valid(k) then
                Continue;
              if (Live[A].Team >= TEAM_ALPHA) and (Live[A].Team <= TEAM_DELTA) and (Live[A].Team <> Team) then
              begin
                n := Length(Enemies);
                SetLength(Enemies, n + 1);
                SetLength(EnemySlots, n + 1);
                Enemies[n] := k;
                EnemySlots[n] := A;
              end
              else if Live[A].Team = Team then
              begin
                n := Length(Mates);
                SetLength(Mates, n + 1);
                SetLength(MateSlots, n + 1);
                Mates[n] := k;
                MateSlots[n] := A;
              end;
            end;
            CtfCapPool(DB, Cfg, Idx, Enemies, Mates, Gain, Gains, Losses);
            { a capture can pay nothing (nobody paid into the pool and FlagScoreFallbackPoints = 0, or
              CapWinnerSharePercent = 0 left the capper nothing): no "+0 pts" }
            if Gain > 0 then
              HudEvent(S, Format('+%d pts capture', [Gain]));
            for k := 0 to High(Mates) do
            begin
              if Team = TEAM_ALPHA then
                Inc(DB.Profiles[Mates[k]]^.AlphaTeamScore)
              else if Team = TEAM_BRAVO then
                Inc(DB.Profiles[Mates[k]]^.BravoTeamScore);
              DB.Touch(Mates[k]);
              if Gains[k] > 0 then
                HudEvent(MateSlots[k], Format('+%d pts team capture', [Gains[k]]));
            end;
            for k := 0 to High(Enemies) do
              if Losses[k] > 0 then
                HudEvent(EnemySlots[k], Format('-%d pts enemy capture', [Losses[k]]));
            MxPoints(Self, Idx, Gain);
            MxCapturePool(Self, Mates, Gains, Enemies, Losses);
          end
          else
          begin
            Gain := AddPoints(DB, Idx, Cfg.FlagScoreFallbackPoints, Cfg.MinimumPoints);
            if Gain > 0 then
              HudEvent(S, Format('+%d pts capture', [Gain]));
            MxPoints(Self, Idx, Gain);
          end;
          AfterProfileChange(Idx);
        end;
        Live[S].FlagGrabTick := 0;
        Match.CaptureTick := GameTick;
        if M >= 0 then
          Inc(DB.Maps[M].FlagsScore);
        { EvTick counts the survival rounds of Infiltration from the team still standing, but a
          capture ends the round and the server kills both teams at once: the capturing team
          won it (Capture the Flag reads the same from its score) }
        if Match.Survival and (Match.GameStyle = GS_INF) and Match.Active and StatsOn and not Match.RoundOver and
           (Team >= TEAM_ALPHA) and (Team <= TEAM_DELTA) then
        begin
          RoundEnd(Team);
          Match.RoundOver := True;
        end;
      end;
    FLAG_RETURN:
      begin
        if P <> nil then
          Inc(P^.FlagsReturn);
        if M >= 0 then
          Inc(DB.Maps[M].FlagsReturns);
      end;
    FLAG_GRAB:
      begin
        if (P <> nil) then
        begin
          Inc(P^.FlagsGrab);
          if (Live[S].FlagDropTick > 0) and (GameTick - Live[S].FlagDropTick <= Round(Cfg.JuggleSeconds * TICKS_PER_SECOND)) then
          begin
            Inc(P^.FlagJuggles);
            HudEvent(S, 'Flag juggle');
          end;
        end;
        Live[S].FlagGrabTick := GameTick;
        if M >= 0 then
          Inc(DB.Maps[M].FlagsGrabs);
      end;
    FLAG_DROP, FLAG_THROWN:
      begin
        if P <> nil then
        begin
          if Kind = FLAG_DROP then
            Inc(P^.FlagsDrop)
          else
            Inc(P^.FlagsThrown);
        end;
        Live[S].FlagDropTick := GameTick;
        Live[S].ContestedSinceTick := 0;
        if M >= 0 then
        begin
          if Kind = FLAG_DROP then
            Inc(DB.Maps[M].FlagsDrop)
          else
            Inc(DB.Maps[M].FlagsThrown);
        end;
      end;
  end;
  if P <> nil then
    MxFlag(Self, Idx, Kind);
  MxFollow(Self, MxP);
  if P <> nil then
    DB.Touch(Idx);
  if M >= 0 then
    DB.TouchMap(M);
end;
