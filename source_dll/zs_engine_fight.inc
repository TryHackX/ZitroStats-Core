{ zs_engine_fight.inc - !lastfight: the fight events of the humans and the records of their deaths
  (part of zs_engine, runtime only). zs_fight keeps the data in TSlotExtra.Fight, so a join or a
  leave clears it; zs_cmd_fight.inc shows it. EvDamage, EvKill, HudEvent and EvTick call in here. }

{ the events of a slot are kept: a human, while [LastFight] Enabled }
function FightOn(E: TZSEngine; S: LongInt): Boolean;
begin
  Result := E.Cfg.LastFightEnabled and (S >= 1) and (S <= MAX_PLAYERS) and E.Live[S].Active and E.Live[S].Human;
end;

{ a weapon number as the events keep it: -1 for anything that is none }
function FightWeapon(W: LongInt): LongInt;
begin
  if (W < 0) or (W > 255) then
    Result := WEP_WORLD
  else
    Result := W;
end;

{ Where the shot of a hit came from, never from where the players stand: Dist = pixels from where
  it was fired to where it hit (as for the kill distance), Flight = seconds in the air, -1 when not
  known. The shot main.pas saw - a human's ammunition went down, with his position - gives the
  distance, and the flight follows from it. A shot nobody saw (bots report no shots, the stationary
  gun is not followed) is worked out from the bullet (Est, LfBulletFlight): its velocity at the hit
  and the shooter's own velocity, which went into it at the shot - a dead shooter's body says
  nothing of that. Nothing for a blade, a hit of his own or no weapon; no flight for what does not
  fly straight (explosions, flames, a thrown knife). }
procedure FightShot(E: TZSEngine; var Ev: TZSEvent; S, W, Tick: LongInt; out Dist, Flight: Single; out Est: Boolean);
var
  HX, HY, BVX, BVY, SX, SY, SVX, SVY, Ticks: Single;
  Bullet: Boolean;
begin
  Dist := -1;
  Flight := -1;
  Est := False;
  if (S = Ev.Slot2) or IsMeleeWeapon(W) or (W = WEP_WORLD) then
    Exit;
  Bullet := Ev.I[2] and EF_BULLET <> 0;
  if Bullet then
  begin
    HX := Ev.F[2];
    HY := Ev.F[3];
    BVX := Ev.F[4];
    BVY := Ev.F[5];
  end
  else
  begin
    HX := Ev.F[6];
    HY := Ev.F[7];
    BVX := 0;
    BVY := 0;
  end;
  if LiveFindShot(E.Live[S], W, Tick, HX, HY, BVX, BVY, SX, SY) then
  begin
    Dist := Hypot(HX - SX, HY - SY);
    if LfStraightFlight(W) then
      Flight := LfFlightSeconds(W, Dist);
    Exit;
  end;
  if not Bullet then
    Exit;
  SVX := 0;
  SVY := 0;
  if Ev.I[2] and EF_A_ALIVE <> 0 then
  begin
    SVX := Ev.F[11];
    SVY := Ev.F[12];
  end;
  if LfBulletFlight(W, BVX, BVY, SVX, SVY, Dist, Ticks) then
  begin
    Flight := Ticks / TICKS_PER_SECOND;
    Est := True;
  end;
end;

function FightEntry(Kind, Other, W, Tick, Flags: LongInt; Dmg: Single; Zone: LongInt; Health, Dist, Flight,
  Speed: Single; Est: Boolean; const Name: AnsiString): TLfEvent;
begin
  Result := Default(TLfEvent);
  Result.Tick := Tick;
  Result.LastTick := Tick;
  Result.Kind := Kind;
  Result.Other := Other;
  Result.Count := 1;
  Result.Weapon := FightWeapon(W);
  Result.Flags := Flags;
  Result.LastZone := -1;
  if (Zone >= 0) and (Zone <= 3) then
  begin
    Result.Zones[Zone] := 1;
    Result.LastZone := Zone;
  end;
  Result.Damage := Dmg;
  if Health > 0 then
    Result.Health := Health;
  Result.Dist := Dist;
  if Est then
    Result.Flags := Result.Flags or LFF_DIST_EST;
  Result.Flight := Flight;
  Result.Speed := Speed;
  Result.Text := Name;
end;

{ EvDamage: a hit, Dmg at most the health that was left, Zone as EvDamage told it. The one who was
  hit gets a line "hit you", the shooter "you hit"; the hits of one burst are one line. Both lines
  get the same distance, flight and speed - the speed of the one who was hit, from his velocity at
  the hit (main.pas sends it) -, worked out only for a new line. }
procedure LastFightHit(E: TZSEngine; var Ev: TZSEvent; Dmg: Single; Zone: LongInt);
var
  S, V, W, Tick, Base, Mine: LongInt;
  Take, Deal, Measured, Est: Boolean;
  Dist, Flight, Speed: Single;
  P: PLfEvent;
  N: TLfEvent;
begin
  S := Ev.Slot;
  V := Ev.Slot2;
  Take := FightOn(E, V);
  Deal := (S <> V) and FightOn(E, S);
  if not Take and not Deal then
    Exit;
  W := FightWeapon(Ev.I[1]);
  Tick := E.GameTick;
  { zones only for the bullets whose zone can be told }
  if not ZoneClassifiableStyle(W) then
    Zone := -1;
  Base := 0;
  if Ev.F[1] > 0 then
    Base := Base or LFF_VEST;
  if (Zone >= HZ_HEAD) and (Zone <= HZ_LEGS) and not WeaponHasDistinctZones(W) then
    Base := Base or LFF_ZONE_EST;
  if S = V then
    Base := Base or LFF_SELF
  else
  begin
    if E.TeamGame and (E.Live[S].Team = E.Live[V].Team) then
      Base := Base or LFF_MATE;
    { the shooter was dead: his bullet was still flying }
    if Ev.I[2] and EF_A_ALIVE = 0 then
      Base := Base or LFF_AFTER;
  end;
  Measured := False;
  Dist := -1;
  Flight := -1;
  Est := False;
  Speed := Hypot(Ev.F[9], Ev.F[10]) * TICKS_PER_SECOND / PIXELS_PER_METER;
  if IsNan(Speed) or IsInfinite(Speed) then
    Speed := -1;
  if Take then
  begin
    Mine := Base;
    if not E.Live[S].Human then
      Mine := Mine or LFF_BOT;
    P := LfBurst(E.Extra[V].Fight, LFE_TAKEN, S, W, Tick, Mine and LFF_AFTER);
    if P <> nil then
      LfAddHit(P, Tick, Dmg, Zone, Mine)
    else
    begin
      FightShot(E, Ev, S, W, Tick, Dist, Flight, Est);
      Measured := True;
      N := FightEntry(LFE_TAKEN, S, W, Tick, Mine, Dmg, Zone, Ev.F[8], Dist, Flight, Speed, Est, E.Live[S].Name);
      LfAppend(E.Extra[V].Fight, N);
    end;
  end;
  if Deal then
  begin
    Mine := Base;
    if not E.Live[V].Human then
      Mine := Mine or LFF_BOT;
    P := LfBurst(E.Extra[S].Fight, LFE_DEALT, V, W, Tick, Mine and LFF_AFTER);
    if P <> nil then
      LfAddHit(P, Tick, Dmg, Zone, Mine)
    else
    begin
      if not Measured then
        FightShot(E, Ev, S, W, Tick, Dist, Flight, Est);
      N := FightEntry(LFE_DEALT, V, W, Tick, Mine, Dmg, Zone, Ev.F[8], Dist, Flight, Speed, Est, E.Live[V].Name);
      LfAppend(E.Extra[S].Fight, N);
    end;
  end;
end;

{ The players who get an assist for this death, by the rule of KillEnemy: the enemies of the victim
  other than the killer whose damage in his life reached AssistMinDamagePercent of the health within
  AssistSeconds - between humans with accounts, while the statistics count. Bit (slot - 1). }
function FightAssists(E: TZSEngine; K, V: LongInt): LongWord;
var
  A: LongInt;
  Need: Double;
begin
  Result := 0;
  if not (E.Live[K].Human and E.Live[V].Human and E.StatsOn and E.DB.Valid(E.Identity.StatsIndex(K)) and
     E.DB.Valid(E.Identity.StatsIndex(V))) then
    Exit;
  Need := E.Cfg.AssistMinDamagePercent / 100 * E.EffectiveMaxHealth;
  for A := 1 to MAX_PLAYERS do
    if (A <> K) and (A <> V) and E.Live[A].Active and E.Live[A].Human and LiveIsEnemy(E.Live, A, V, E.TeamGame) and
       (E.Live[A].Pair[V].LastDamageTick > 0) and
       (Int64(E.GameTick) - E.Live[A].Pair[V].LastDamageTick <= Round(E.Cfg.AssistSeconds * TICKS_PER_SECOND)) and
       (E.Live[A].Pair[V].DamageThisLife >= Need) and E.DB.Valid(E.Identity.StatsIndex(A)) then
      Result := Result or (LongWord(1) shl (A - 1));
end;

{ The seconds after a death are over, or the player is back in the game: the record takes its
  events, and with [LastFight] DeathSummary the player gets one or two lines about it - through the
  paced output like any answer. Nothing for a spectator: he has left the game. }
procedure FightClose(E: TZSEngine; S: LongInt);
var
  F: PLfSlot;
  R: PLfRecord;
  L1, L2: AnsiString;
begin
  F := @E.Extra[S].Fight;
  R := LfOpenRecord(F^);
  if R = nil then
    Exit;
  LfCollect(F^, R^, LfWindowEnd(R^, E.Live[S].SpawnTick, E.GameTick));
  R^.Closed := True;
  if not E.Cfg.LastFightEnabled or not E.Cfg.LastFightSummary or not E.Live[S].Active or not E.Live[S].Human or
     (E.Live[S].Team = TEAM_SPEC) then
    Exit;
  LfSummary(R^, E.Cfg.LastFightBeforeSeconds, L1, L2);
  E.Say(S, L1, CLR_BAD);
  if L2 <> '' then
    E.Say(S, L2, CLR_COMBAT);
end;

{ EvKill, before the kill is counted, while the hits of the life are still known: the kill for the
  killer, a record of the death for the one who died. The server's own kills (the end of a survival
  round, a team change) are no deaths and leave nothing. }
procedure LastFightKill(E: TZSEngine; var Ev: TZSEvent; ServerKill: Boolean);
var
  K, V, W, Tick: LongInt;
  KValid: Boolean;
  P: PLfEvent;
  R: PLfRecord;
  F: PLfSlot;
  N: TLfEvent;
begin
  if ServerKill or not E.Cfg.LastFightEnabled then
    Exit;
  K := Ev.Slot;
  V := Ev.Slot2;
  W := FightWeapon(Ev.I[1]);
  Tick := E.GameTick;
  KValid := E.SlotValid(K);
  if KValid and (K <> V) and FightOn(E, K) then
  begin
    N := Default(TLfEvent);
    N.Tick := Tick;
    N.LastTick := Tick;
    N.Kind := LFE_KILL;
    N.Other := V;
    N.Count := 1;
    N.Weapon := W;
    N.LastZone := -1;
    N.Dist := -1;
    N.Flight := -1;
    N.Speed := -1;
    N.Text := E.Live[V].Name;
    if Ev.I[2] and EF_A_ALIVE = 0 then
      N.Flags := N.Flags or LFF_AFTER;
    if not E.Live[V].Human then
      N.Flags := N.Flags or LFF_BOT;
    if E.TeamGame and (E.Live[K].Team = E.Live[V].Team) then
      N.Flags := N.Flags or LFF_MATE;
    { the hit that did it: his last hit on the victim a moment ago }
    P := LfLatest(E.Extra[K].Fight, LFE_DEALT, V, Tick - 2);
    if P <> nil then
    begin
      P^.Flags := P^.Flags or LFF_LETHAL;
      N.Dist := P^.Dist;
      N.Flight := P^.Flight;
      N.Speed := P^.Speed;
      N.LastZone := P^.LastZone;
      N.Flags := N.Flags or (P^.Flags and (LFF_DIST_EST or LFF_ZONE_EST));
    end;
    LfAppend(E.Extra[K].Fight, N);
  end;

  if not FightOn(E, V) or (E.Live[V].Team = TEAM_SPEC) then
    Exit;
  F := @E.Extra[V].Fight;
  { a death in the seconds after the last one (a quick respawn): that one is complete now }
  if LfOpenRecord(F^) <> nil then
    FightClose(E, V);
  R := LfNewRecord(F^);
  R^.DeathTick := Tick;
  if (E.Live[V].SpawnTick > 0) and (E.Live[V].SpawnTick <= Tick) then
    R^.LifeTick := E.Live[V].SpawnTick;
  R^.FromTick := Max(Tick - E.Cfg.LastFightBeforeSeconds * TICKS_PER_SECOND, R^.LifeTick);
  R^.EndTick := Tick + E.Cfg.LastFightAfterSeconds * TICKS_PER_SECOND;
  R^.When := Now;
  R^.StatsOn := E.StatsOn;
  R^.MapName := E.Match.MapName;
  R^.KillerWeapon := W;
  if K = V then
  begin
    { his own weapon, or nothing of anybody: a fall, a deadly polygon, the kill command, a script }
    if W = WEP_WORLD then
      R^.Kind := LFD_WORLD
    else
    begin
      R^.Kind := LFD_SELF;
      R^.Killer := V;
      R^.KillerName := E.Live[V].Name;
    end;
  end
  else if not KValid then
  begin
    { the killer left the server in that moment: the last hit of that slot a moment ago says who }
    R^.Kind := LFD_LEFT;
    if (K >= 1) and (K <= MAX_PLAYERS) then
    begin
      P := LfLatest(F^, LFE_TAKEN, K, Tick - 2);
      if P <> nil then
      begin
        R^.Killer := K;
        R^.KillerName := P^.Text;
      end;
    end;
  end
  else
  begin
    R^.Killer := K;
    R^.KillerName := E.Live[K].Name;
    if E.TeamGame and (E.Live[K].Team = E.Live[V].Team) then
    begin
      R^.Kind := LFD_TEAM;
      R^.KillerFlags := LFF_MATE;
    end
    else
    begin
      R^.Kind := LFD_ENEMY;
      R^.Assists := FightAssists(E, K, V);
    end;
    if Ev.I[2] and EF_A_ALIVE = 0 then
      R^.KillerFlags := R^.KillerFlags or LFF_AFTER;
    if not E.Live[K].Human then
      R^.KillerFlags := R^.KillerFlags or LFF_BOT;
  end;
  { the hit that killed him }
  if R^.Killer > 0 then
  begin
    P := LfLatest(F^, LFE_TAKEN, R^.Killer, Tick - 2);
    if P <> nil then
      P^.Flags := P^.Flags or LFF_LETHAL;
  end;
end;

{ HudEvent: a note of the player's HUD - points, an assist, a feat }
procedure LastFightNote(E: TZSEngine; Slot: LongInt; const Text: AnsiString);
var
  N: TLfEvent;
begin
  if (Text = '') or not FightOn(E, Slot) then
    Exit;
  N := Default(TLfEvent);
  N.Tick := E.GameTick;
  N.LastTick := N.Tick;
  N.Kind := LFE_NOTE;
  N.Count := 1;
  N.Weapon := WEP_WORLD;
  N.LastZone := -1;
  N.Dist := -1;
  N.Flight := -1;
  N.Speed := -1;
  N.Points := LfNotePoints(Text);
  N.Text := Text;
  LfAppend(E.Extra[Slot].Fight, N);
end;

{ EvTick, once a second: the records whose seconds after the death are over, or whose player is
  back; also when [LastFight] was switched off in between, so no record stays open }
procedure LastFightSecond(E: TZSEngine);
var
  S: LongInt;
  R: PLfRecord;
begin
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and (E.Extra[S].Fight.Deaths > 0) then
    begin
      R := LfOpenRecord(E.Extra[S].Fight);
      if (R <> nil) and ((E.GameTick >= R^.EndTick) or (E.Live[S].SpawnTick > R^.DeathTick)) then
        FightClose(E, S);
    end;
end;
