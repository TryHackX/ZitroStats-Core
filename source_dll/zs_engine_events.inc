{ zs_engine_events.inc - session, movement and weapon events (part of zs_engine) }

function IsBow(W: LongInt): Boolean;
begin
  Result := (W = WEP_BOW) or (W = WEP_BOW2);
end;

function IsPrimaryGun(W: LongInt): Boolean;
begin
  Result := (W >= WEP_MP5) and (W <= WEP_MINIGUN);
end;

function IsFinisherWeapon(W: LongInt): Boolean;
begin
  Result := (W = WEP_SOCOM) or (W = WEP_DEAGLES) or (W = WEP_KNIFE) or (W = WEP_THROWNKNIFE) or
    (W = WEP_CHAINSAW) or (W = WEP_LAW) or (W = WEP_FLAMER) or (W = WEP_NONE);
end;

procedure ClearExtra(var X: TSlotExtra);
begin
  Finalize(X);
  FillChar(X, SizeOf(TSlotExtra), 0);
end;

procedure TZSEngine.EvJoin(var E: TZSEvent);
var
  S, Idx, M, D: LongInt;
  Old: TZSEvent;
begin
  S := E.Slot;
  if (S < 1) or (S > MAX_PLAYERS) then
    Exit;
  if Live[S].Active then
  begin
    { a join without a leave: close the previous session first }
    Old := NewEvent(zeLeave);
    Old.Slot := S;
    EvLeave(Old);
  end;
  LiveResetSlot(Live, S);
  ClearExtra(Extra[S]);
  { a new player in the slot has not voted for the map vote that runs }
  MV.Voted[S] := False;
  Live[S].Active := True;
  Live[S].Human := E.I[1] <> 0;
  Live[S].Admin := E.I[2] <> 0;
  Live[S].Name := E.S1;
  Live[S].Team := E.I[0];
  Live[S].JoinTick := GameTick;
  Live[S].TeamSinceTick := GameTick;
  BalOnJoin(S);
  if not Live[S].Human then
    Exit;

  { DuplicateHWID / DuplicateIP: allow, tell the admins, or kick the player who joined later }
  if not CheckDuplicate(S, 'computer (HWID)', Cfg.DuplicateHWID, 1, E.S3) then
    Exit;
  if not CheckDuplicate(S, 'IP address', Cfg.DuplicateIP, 2, E.S4) then
    Exit;

  Identity.Join(S, E.S1, E.S2, E.S3, E.S4, True);
  Idx := Identity.ProfileIndex(S);
  if DB.Valid(Idx) then
  begin
    Live[S].SessionStartPoints := DB.Profiles[Idx]^.Points;
    Live[S].MatchStartPoints := DB.Profiles[Idx]^.Points;
  end;
  M := Match.MapIndex;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    { Spec Joins counts switches to the spectators, not the way a player arrives }
    Inc(DB.Maps[M].JoinGameCount);
    DB.TouchMap(M);
  end;
  D := DailyEntry;
  if D >= 0 then
  begin
    Inc(DB.Server.Daily[D].Sessions);
    DB.TouchServer;
  end;
  UpdatePeakOnline;
end;

procedure TZSEngine.EvLeave(var E: TZSEvent);
var
  S, Idx, M: LongInt;
begin
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  BalOnLeave(S);
  ReloadForget(S);
  { whoever takes the slot next did not ask for these answers }
  if BackupAsker = S then
    BackupAsker := -1;
  if ExportAsker = S then
    ExportAsker := -1;
  if SaveAsker = S then
    SaveAsker := -1;
  if MV.ScanAsker = S then
    MV.ScanAsker := -1;
  { the vote of a player who left no longer counts }
  MV.Voted[S] := False;
  { an admin who leaves cancels the operation waiting for their /yes; the slot may get a new player }
  if (Pending.Kind <> OP_NONE) and not Pending.WaitingBackup and (Pending.AdminSlot = S) then
  begin
    Audit('admin ' + Pending.AdminName + ': left the server, operation cancelled');
    ClearPending;
  end;
  if Live[S].Human then
  begin
    LiveCloseTeamTime(Live[S], GameTick);
    Idx := Identity.StatsIndex(S);
    if DB.Valid(Idx) then
    begin
      { players leaving a running match: the leaver rule is applied when it ends, with every stay
        of the account in the match added up }
      if Match.Active then
        NoteLeaver(S, DB.Profiles[Idx]^.ID);
      DB.NoteName(Idx, Live[S].Name, False, Extra[S].PlaySeconds, Extra[S].SpecSeconds, Cfg.NameHistoryLimit);
    end;
    M := Match.MapIndex;
    if (M >= 0) and (M < DB.MapCount) then
    begin
      Inc(DB.Maps[M].LeaveGameCount);
      if E.I[0] <> 0 then
        Inc(DB.Maps[M].KickedCount);
      DB.TouchMap(M);
    end;
    Identity.Leave(S);
  end;
  LiveResetSlot(Live, S);
  ClearExtra(Extra[S]);
  { whoever takes the slot next did not play this survival round }
  Match.RoundIn[S] := False;
  UpdatePeakOnline;
end;

procedure TZSEngine.EvTeam(var E: TZSEvent);
var
  S, M: LongInt;
begin
  S := E.Slot;
  if not SlotValid(S) or (Live[S].Team = E.I[0]) then
    Exit;
  LiveSetTeam(Live[S], E.I[0], GameTick);
  ReloadForget(S);
  BalOnTeam(S, E.I[0]);
  { a locked account that we parked on the spectators stays there until the player logs in }
  if (E.I[0] >= TEAM_ALPHA) and (E.I[0] <= TEAM_DELTA) and Live[S].Human and
     Identity.Slots[S].Locked and Identity.Slots[S].SpecByLogin then
  begin
    Say(S, 'Log in first: /login <password> - until then you stay a spectator.', CLR_WARN);
    ForceSpectator(S);
  end;
  if E.I[0] = TEAM_SPEC then
  begin
    Live[S].Alive := False;
    M := Match.MapIndex;
    { a move the balance or an admin asked for is not the player's own switch, and a player who
      bounces between the game and the spectators counts once per TeamSwitchCountSeconds }
    if Live[S].Human and (M >= 0) and (M < DB.MapCount) and not Live[S].PendingKick and
       (GameTick - Live[S].ScriptTeamTick > 3 * TICKS_PER_SECOND) then
    begin
      if (Live[S].SwitchCountTick = 0) or
         (GameTick - Live[S].SwitchCountTick >= Cfg.TeamSwitchCountSeconds * TICKS_PER_SECOND) then
      begin
        Inc(DB.Maps[M].JoinToSpectator);
        DB.TouchMap(M);
      end;
      { every try pushes the window, so switching in a loop never counts again }
      Live[S].SwitchCountTick := GameTick;
    end;
  end;
  Extra[S].HudText := '';
end;

procedure TZSEngine.EvSteamAuth(var E: TZSEvent);
begin
  if not SlotValid(E.Slot) or not Live[E.Slot].Human then
    Exit;
  { AuthState 0 = Steam confirmed the player; any other state: no Steam account for this session }
  if E.I[0] = 0 then
  begin
    if not CheckDuplicate(E.Slot, 'Steam account', Cfg.DuplicateSteam, 3, E.S1) then
      Exit;
    Identity.SteamAuth(E.Slot, E.S1);
  end
  else
    Identity.SteamAuthFailed(E.Slot);
end;

{ The first real primary (Which 0) and secondary (1) weapon of a life are the player's picks,
  whether they come with the spawn or - with the weapon menu open at the spawn, which gives no
  weapon (255) - with the first weapon change after it. A later change in the same life is none. }
procedure TZSEngine.NotePick(S, Which, Weapon: LongInt);
var
  M, W, T: LongInt;
begin
  if (Extra[S].Picked[Which] <> 0) or (Weapon = WEP_NONE) then
    Exit;
  W := WepSlot(Weapon);
  if W < 0 then
    Exit;
  { the two weapons swapped places: the picked one only moved to the other slot }
  if Extra[S].Picked[1 - Which] = Weapon + 1 then
    Exit;
  Extra[S].Picked[Which] := Weapon + 1;
  if not Live[S].Human or not StatsOn then
    Exit;
  M := Match.MapIndex;
  T := Live[S].Team;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    Inc(DB.Maps[M].WeaponPicks[W]);
    if (T = TEAM_ALPHA) or (T = TEAM_BRAVO) then
      Inc(DB.Maps[M].WeaponPicksTeam[T, W]);
    DB.TouchMap(M);
  end;
  Inc(DB.Server.WeaponGlobal[W].Picks);
  if (T >= TEAM_ALPHA) and (T <= TEAM_DELTA) then
    Inc(DB.Server.WeaponGlobal[W].PicksTeam[T]);
  DB.TouchServer;
end;

procedure TZSEngine.EvSpawn(var E: TZSEvent);
var
  S: LongInt;
begin
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  LiveSpawn(Live, S, GameTick, E.F[0], E.F[1]);
  ReloadForget(S);
  Live[S].Weapon := E.I[0];
  RoundJoin(S);
  Extra[S].Picked[0] := 0;
  Extra[S].Picked[1] := 0;
  NotePick(S, 0, E.I[0]);
  NotePick(S, 1, E.I[1]);
end;

procedure TZSEngine.CountShots(Slot, Weapon, Count: LongInt);
var
  Idx, W, N: LongInt;
  P: PPlayerProfile;
begin
  Idx := Identity.StatsIndex(Slot);
  if not DB.Valid(Idx) or (Count <= 0) then
    Exit;
  P := DB.Profiles[Idx];
  W := WepSlot(Weapon);
  N := Count * Max(1, ShotMultiplier(Weapon));
  if CountsForAccuracy(Weapon) then
    Inc(P^.Shots, N);
  if W >= 0 then
    Inc(P^.Weapons[W].Shots, N);
  case Weapon of
    WEP_M79: Inc(P^.M79Shots, Count);
    WEP_LAW: Inc(P^.M72LAWShots, Count);
    WEP_FLAMER: Inc(P^.FlamethrowerShots, Count);
    WEP_BOW2: Inc(P^.BowFlamedArrowsShots, Count);
    WEP_THROWNKNIFE: Inc(P^.KnivesThrows, Count);
    WEP_FRAG: Inc(P^.NadesThrows, Count);
    WEP_CLUSTERNADE, WEP_CLUSTER: Inc(P^.ClusterNadesThrows, Count);
  end;
  DB.Touch(Idx);
end;

procedure TZSEngine.EvShot(var E: TZSEvent);
begin
  if not SlotValid(E.Slot) then
    Exit;
  LiveNoteShot(Live[E.Slot], GameTick, E.I[0], E.F[0], E.F[1]);
  if Live[E.Slot].Human and StatsOn then
    CountShots(E.Slot, E.I[0], Max(1, E.I[1]));
end;

procedure TZSEngine.EvGrenade(var E: TZSEvent);
var
  W: LongInt;
begin
  if not SlotValid(E.Slot) then
    Exit;
  { the script only sees the grenade count drop; a cluster kit picked up earlier tells the type }
  if (E.I[1] <> 0) or Live[E.Slot].ClusterNades then
    W := WEP_CLUSTERNADE
  else
    W := WEP_FRAG;
  LiveNoteShot(Live[E.Slot], GameTick, W, E.F[0], E.F[1]);
  if Live[E.Slot].Human and StatsOn then
    CountShots(E.Slot, W, Max(1, E.I[0]));
end;

procedure TZSEngine.EvKnifeThrow(var E: TZSEvent);
begin
  if not SlotValid(E.Slot) then
    Exit;
  LiveNoteShot(Live[E.Slot], GameTick, WEP_THROWNKNIFE, E.F[0], E.F[1]);
  if Live[E.Slot].Human and StatsOn then
    CountShots(E.Slot, WEP_THROWNKNIFE, 1);
end;

procedure TZSEngine.EvWeapon(var E: TZSEvent);
var
  S, Idx, Old, New: LongInt;
  P: PPlayerProfile;
begin
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  Old := Live[S].Weapon;
  New := E.I[0];
  { I[4] = 1: the script said the ammunition of both weapons too }
  if E.I[4] <> 0 then
    ReloadOnWeapon(S, Old, New, E.I[2], E.Tick);
  Live[S].Weapon := New;
  { the weapons chosen in the menu after a spawn without one; a dead player only drops the gun }
  if Live[S].Alive then
  begin
    NotePick(S, 0, New);
    NotePick(S, 1, E.I[1]);
  end;
  if (Match.GameStyle <> GS_RM) or not Live[S].Human or not StatsOn then
    Exit;
  Idx := Identity.StatsIndex(S);
  if not DB.Valid(Idx) then
    Exit;
  P := DB.Profiles[Idx];
  if IsBow(New) and not IsBow(Old) then
    Inc(P^.RamboMode.GetsBow)
  else if IsBow(Old) and not IsBow(New) and Live[S].Alive then
    Inc(P^.RamboMode.DropBow);
  DB.Touch(Idx);
end;

procedure TZSEngine.EvKit(var E: TZSEvent);
var
  K, Idx: LongInt;
begin
  if not SlotValid(E.Slot) then
    Exit;
  case E.I[0] of
    KIT_BERSERK: Live[E.Slot].BerserkUntil := GameTick + BERSERK_TICKS;
    KIT_CLUSTER: Live[E.Slot].ClusterNades := True;
    KIT_GRENADE: Live[E.Slot].ClusterNades := False;
  end;
  { the kit picked up, by its kind: humans only, while the statistics are on }
  K := KitKind(E.I[0]);
  if (K < 0) or not Live[E.Slot].Human or not StatsOn then
    Exit;
  Idx := Identity.StatsIndex(E.Slot);
  if DB.Valid(Idx) then
  begin
    Inc(DB.Profiles[Idx]^.KitPickups[K]);
    DB.Touch(Idx);
  end;
end;

{ health a player got back, sent by the script once a second: F[0] from regenerating polygons,
  F[1] from medical, berserker and predator kits, I[0] the kits that healed }
procedure TZSEngine.EvHeal(var E: TZSEvent);
var
  Idx, M: LongInt;
  P: PPlayerProfile;
begin
  if not SlotValid(E.Slot) or not Live[E.Slot].Human or not StatsOn then
    Exit;
  Idx := Identity.StatsIndex(E.Slot);
  if DB.Valid(Idx) then
  begin
    P := DB.Profiles[Idx];
    if E.F[0] > 0 then
      P^.HealRegen := P^.HealRegen + E.F[0];
    if E.F[1] > 0 then
      P^.HealKits := P^.HealKits + E.F[1];
    if E.I[0] > 0 then
      Inc(P^.HealKitCount, E.I[0]);
    DB.Touch(Idx);
  end;
  M := Match.MapIndex;
  if (M >= 0) and (M < DB.MapCount) and (E.F[0] > 0) then
  begin
    DB.Maps[M].HealRegen := DB.Maps[M].HealRegen + E.F[0];
    DB.TouchMap(M);
  end;
end;

procedure TZSEngine.EvSample(var E: TZSEvent);
var
  S, Idx, M, PrevTick, PrevJets, Elapsed: LongInt;
  Moved: Single;
  P: PPlayerProfile;
  MP: PMapProfile;
  Grew: Boolean;
begin
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  if E.I[0] and EF_A_ALIVE = 0 then
  begin
    Live[S].Alive := False;
    Exit;
  end;
  { alive without a spawn the engine saw (main.pas was loaded in the middle of a map) }
  if not Live[S].Alive then
  begin
    LiveSpawn(Live, S, GameTick, E.F[0], E.F[1]);
    RoundJoin(S);
  end;
  PrevTick := Live[S].SampleTick;
  PrevJets := Live[S].Jets;
  Moved := LiveNoteSample(Live[S], GameTick, E.F[0], E.F[1], E.I[1], E.I[2], E.I[3], E.I[0], Cfg.CampRadius);
  if not Live[S].Human or (Live[S].Team = TEAM_SPEC) or not StatsOn then
    Exit;
  Idx := Identity.StatsIndex(S);
  if not DB.Valid(Idx) then
    Exit;
  P := DB.Profiles[Idx];
  if Moved > 0 then
  begin
    P^.DistanceTraveledM := P^.DistanceTraveledM + Moved / PIXELS_PER_METER;
    Live[S].LifeDistance := Live[S].LifeDistance + Moved / PIXELS_PER_METER;
    if Live[S].LifeDistance > P^.BestLifeDistanceM then
      P^.BestLifeDistanceM := Live[S].LifeDistance;
  end;
  Elapsed := EnsureRange(GameTick - PrevTick, 0, TICKS_PER_SECOND);
  if (E.I[0] and EF_A_ONGROUND = 0) and (E.I[3] < PrevJets) then
  begin
    Inc(Extra[S].JetTicks, Elapsed);
    if Extra[S].JetTicks >= TICKS_PER_SECOND then
    begin
      Inc(P^.JetFlyTimeSeconds, Extra[S].JetTicks div TICKS_PER_SECOND);
      Extra[S].JetTicks := Extra[S].JetTicks mod TICKS_PER_SECOND;
    end;
  end;
  M := Match.MapIndex;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    MP := @DB.Maps[M];
    Grew := False;
    if (MP^.MinX = 0) and (MP^.MaxX = 0) and (MP^.MinY = 0) and (MP^.MaxY = 0) then
    begin
      MP^.MinX := E.F[0];
      MP^.MaxX := E.F[0];
      MP^.MinY := E.F[1];
      MP^.MaxY := E.F[1];
      Grew := True;
    end
    else
    begin
      if E.F[0] < MP^.MinX then begin MP^.MinX := E.F[0]; Grew := True; end;
      if E.F[0] > MP^.MaxX then begin MP^.MaxX := E.F[0]; Grew := True; end;
      if E.F[1] < MP^.MinY then begin MP^.MinY := E.F[1]; Grew := True; end;
      if E.F[1] > MP^.MaxY then begin MP^.MaxY := E.F[1]; Grew := True; end;
    end;
    { the area of the map is saved with it: a sample that widened it marks the map for the
      journal, the others do not }
    if Grew then
      DB.TouchMap(M);
  end;
  DB.Touch(Idx);
end;

procedure TZSEngine.EvVote(var E: TZSEvent);
var
  M: LongInt;
begin
  { a kick vote of Soldat runs: a map vote shown now would take its place }
  if E.I[0] = 2 then
    MV.KickVoteUntil := GameTick + MV_KICK_VOTE_TICKS;
  { the map vote of ZitroStats (zs_engine_mapvote.inc): main.pas cancelled Soldat's own vote, the
    vote menu asks for a map (1), F12 votes for the vote that shows (3); these votes count their
    statistics themselves }
  if Cfg.MapVoteEnabled and ((E.I[0] = 1) or (E.I[0] = 3)) then
  begin
    MapVoteSoldat(E.Slot, E.I[0], E.S1);
    Exit;
  end;
  { 1 = a map vote started, 3 = a vote cast for the map vote that runs: a vote another script
    started (Game.StartVoteMap) is only seen that way, so its first vote cast counts it; the
    later ones keep the minute in which a map change to it counts as won }
  if E.I[0] = 3 then
  begin
    if (Match.LastVoteMap <> '') and SameText(Trim(E.S1), Match.LastVoteMap) then
    begin
      Match.LastVoteTick := GameTick;
      Exit;
    end;
  end
  else if E.I[0] <> 1 then
    Exit;
  { a map change to this map soon after tells that the vote was won }
  Match.LastVoteMap := Trim(E.S1);
  Match.LastVoteTick := GameTick;
  M := Match.MapIndex;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    Inc(DB.Maps[M].VoteStarts);
    DB.TouchMap(M);
  end;
end;
