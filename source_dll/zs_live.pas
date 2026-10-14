unit zs_live;

{ Live per-player state kept by the engine thread between game events.

  - Recent shots with the shooter position at the moment of firing. A kill is matched to the
    newest shot of the same weapon that could have covered the distance in time and, for
    bullets flying straight, lies behind the bullet in its direction of flight. The kill
    distance is measured from where the projectile left the gun: moving while a bullet or
    grenade is in flight (nade boost, M79 jump) does not change it.
  - Movement samples: distance travelled, camping (staying inside a radius) and inactivity.
  - Per pair of players: damage dealt during the other one's current life, last hit and kill
    times, kill streaks against each other and the open revenge flag. Savior, avenger,
    assists, finisher, bink recovery, domination and time-to-kill are read from these.
  - A 2D hit model that learns where head, body and leg hits land relative to the victim
    (per posture) from weapons whose damage identifies the zone, and classifies hits of
    weapons that cannot be told apart by damage (e.g. Barrett). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, zs_types, zs_weapons;

const
  SHOT_RING = 96;
  MAX_FLIGHT_TICKS = 10 * TICKS_PER_SECOND;   { long maps: slow projectiles can fly for seconds }
  ACTIVITY_RADIUS = 24.0;
  TELEPORT_PX = 250.0;
  HIT_MODEL_MIN_SAMPLES = 40;

type
  TShotSnap = record
    Tick: LongInt;
    Weapon: LongInt;
    X, Y: Single;
  end;

  TPairState = record
    DamagedTick: LongInt;
    KilledTick: LongInt;
    DamageThisLife: Single;
    FirstDamageTick: LongInt;
    LastDamageTick: LongInt;
    LastPrimaryHitTick: LongInt;
    LastZone: LongInt;
    LastZoneExact: Boolean;     { the zone came from the server's own hit test ([Bridges], 5.6) }
    LastBVX, LastBVY: Single;   { velocity of the bullet of the last hit }
    Streak: LongInt;
    RevengeOpen: Boolean;
    InactiveKills: LongInt;
    WinStartTick: LongInt;
    WinKills: LongInt;
    WinVictimKills0: LongInt;
    WinLogged: Boolean;
  end;

  TLiveSlot = record
    Active: Boolean;
    Human: Boolean;
    Admin: Boolean;
    Serial: LongWord;
    Name: AnsiString;
    Team: LongInt;
    JoinTick: LongInt;
    TeamSinceTick: LongInt;
    TeamTicks: array[0..5] of LongInt;
    Alive: Boolean;
    SpawnTick: LongInt;
    DeathTick: LongInt;
    HasSample: Boolean;
    SampleTick: LongInt;
    LifeSeconds: LongInt;      { seconds of this life that counted for the survival statistics }
    LifeDistance: Single;      { meters covered in this life }
    X, Y: Single;
    Weapon: LongInt;
    Ammo: LongInt;
    Jets: LongInt;
    Flags: LongInt;
    BerserkUntil: LongInt;
    ClusterNades: Boolean;   { grenades come from a cluster kit }
    AnchorX, AnchorY: Single;
    AnchorTick: LongInt;
    ActX, ActY: Single;
    LastMoveTick: LongInt;
    LastShotTick: LongInt;
    Shots: array[0..SHOT_RING - 1] of TShotSnap;
    ShotCount: LongInt;
    ShotHead: LongInt;
    KillStreak: LongInt;
    StreakCarry: Boolean;      { the last life ended by the server (a survival round end): the
                                 streak goes on in the next one }
    MultiKillCount: LongInt;
    LastKillTick: LongInt;
    { the bullet of the last kill: its slot and the tick it was fired (a second kill by the same
      bullet is a collateral; 5.6) }
    LastKillBullet: LongInt;
    LastKillOrigin: LongInt;
    LastKillOX, LastKillOY: Single;
    KnifeKillsLife: LongInt;
    ExplosionTick: LongInt;
    ExplosionSlot: LongInt;
    ExplosionKills: LongInt;
    FlagGrabTick: LongInt;
    FlagDropTick: LongInt;
    ContestedSinceTick: LongInt;
    { since the player joined the server (!session) }
    SessionKills: LongInt;
    SessionDeaths: LongInt;
    SessionHeadshots: LongInt;
    SessionStartPoints: LongInt;
    SessionWins: LongInt;
    SessionRoundWins: LongInt;
    SessionCaps: LongInt;
    { since the current map started (match leaders, webhook) }
    MatchKills: LongInt;
    MatchDeaths: LongInt;
    MatchScore: LongInt;
    MatchCaps: LongInt;
    MatchRoundWins: LongInt;
    MatchStartPoints: LongInt;
    { a kick this script asked for: the player is still in the slot, but counts for nothing }
    PendingKick: Boolean;
    { the tick of the last team change this script asked for, so it is not counted as the
      player's own switch }
    ScriptTeamTick: LongInt;
    { the tick of the last spectator switch that was counted, for the anti-spam window }
    SwitchCountTick: LongInt;
    Pair: array[1..MAX_PLAYERS] of TPairState;
  end;
  PLiveSlot = ^TLiveSlot;

  TLiveTable = array[1..MAX_PLAYERS] of TLiveSlot;

procedure LiveResetSlot(var L: TLiveTable; Slot: LongInt);
procedure LiveResetMatch(var L: TLiveTable; Tick: LongInt);
{ The game time moved by Delta against the ticks of the server (a pause, the tick counter starting
  again): T + Delta, at most Limit (now, for a tick in the past); 0 (not set) stays 0, and a tick
  more than a billion before 0 is one of long ago and becomes 0 }
function ShiftTick(T, Delta, Limit: LongInt): LongInt;
procedure LiveShiftTicks(var L: TLiveTable; Delta, NowTick: LongInt);
procedure LiveSetTeam(var S: TLiveSlot; Team, Tick: LongInt);
procedure LiveCloseTeamTime(var S: TLiveSlot; Tick: LongInt);
procedure LiveSpawn(var L: TLiveTable; Slot, Tick: LongInt; X, Y: Single);
{ ServerKill: the server ended the life itself (the end of a survival round, a team change), which
  is no death - the killing spree of the player goes on in the next life }
procedure LiveLifeEnded(var L: TLiveTable; Slot, Tick: LongInt; ServerKill: Boolean = False);
procedure LiveNoteShot(var S: TLiveSlot; Tick, Weapon: LongInt; X, Y: Single);
function LiveFindShot(const S: TLiveSlot; Weapon, HitTick: LongInt; HX, HY, BVX, BVY: Single; out SX, SY: Single): Boolean;
function LiveNoteSample(var S: TLiveSlot; Tick: LongInt; X, Y: Single; Weapon, Ammo, Jets, Flags: LongInt;
  CampRadius: Single): Single;
function LiveInactiveTicks(const S: TLiveSlot; Tick: LongInt): LongInt;
function LiveCampTicks(const S: TLiveSlot; Tick: LongInt): LongInt;
function LiveIsEnemy(const L: TLiveTable; A, B: LongInt; TeamGame: Boolean): Boolean;
function LiveIsTeammate(const L: TLiveTable; A, B: LongInt; TeamGame: Boolean): Boolean;
function LiveHumansPlaying(const L: TLiveTable): LongInt;

function PostureOf(Flags: LongInt; Victim: Boolean): LongInt;
procedure HitModelLearn(var Cell: THitModelCell; DX, DY: Double);
function HitModelClassify(const Cells: array of THitModelCell; DX, DY: Double; MinSamples: LongInt): LongInt;
procedure HitOffset(BX, BY, BVX, VX, VY: Single; out DX, DY: Double);

implementation

procedure ClearPair(var P: TPairState);
begin
  FillChar(P, SizeOf(P), 0);
end;

procedure LiveResetSlot(var L: TLiveTable; Slot: LongInt);
var
  A: LongInt;
begin
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  Finalize(L[Slot]);
  FillChar(L[Slot], SizeOf(TLiveSlot), 0);
  L[Slot].Weapon := WEP_NONE;
  for A := 1 to MAX_PLAYERS do
    ClearPair(L[A].Pair[Slot]);
end;

procedure LiveResetMatch(var L: TLiveTable; Tick: LongInt);
var
  S, A: LongInt;
begin
  for S := 1 to MAX_PLAYERS do
  begin
    FillChar(L[S].TeamTicks, SizeOf(L[S].TeamTicks), 0);
    L[S].TeamSinceTick := Tick;
    L[S].KillStreak := 0;
    L[S].StreakCarry := False;
    L[S].MultiKillCount := 0;
    L[S].KnifeKillsLife := 0;
    L[S].MatchKills := 0;
    L[S].MatchDeaths := 0;
    L[S].MatchScore := 0;
    L[S].MatchCaps := 0;
    L[S].MatchRoundWins := 0;
    L[S].FlagGrabTick := 0;
    L[S].FlagDropTick := 0;
    L[S].ContestedSinceTick := 0;
    { A new map starts new lives; what was lived on the old map is not one long life. The server
      respawns everybody for the new map before the script hears of it, so a life begun in this
      very tick is already one of the new map. }
    if L[S].SpawnTick <> Tick then
      L[S].Alive := False;
    L[S].LifeSeconds := 0;
    L[S].LifeDistance := 0;
    for A := 1 to MAX_PLAYERS do
    begin
      L[S].Pair[A].Streak := 0;
      L[S].Pair[A].RevengeOpen := False;
      L[S].Pair[A].InactiveKills := 0;
    end;
  end;
end;

function ShiftTick(T, Delta, Limit: LongInt): LongInt;
var
  V: Int64;
begin
  if T = 0 then
    Exit(0);
  V := Int64(T) + Delta;
  if V > Limit then
    V := Limit;
  if V < -1000000000 then
    V := 0;
  Result := V;
end;

{ every tick the table keeps, moved along (ShiftTick) }
procedure LiveShiftTicks(var L: TLiveTable; Delta, NowTick: LongInt);
var
  S, A, k: LongInt;
begin
  for S := 1 to MAX_PLAYERS do
    with L[S] do
    begin
      JoinTick := ShiftTick(JoinTick, Delta, NowTick);
      TeamSinceTick := ShiftTick(TeamSinceTick, Delta, NowTick);
      SpawnTick := ShiftTick(SpawnTick, Delta, NowTick);
      DeathTick := ShiftTick(DeathTick, Delta, NowTick);
      SampleTick := ShiftTick(SampleTick, Delta, NowTick);
      BerserkUntil := ShiftTick(BerserkUntil, Delta, MaxLongInt);
      AnchorTick := ShiftTick(AnchorTick, Delta, NowTick);
      LastMoveTick := ShiftTick(LastMoveTick, Delta, NowTick);
      LastShotTick := ShiftTick(LastShotTick, Delta, NowTick);
      for k := 0 to SHOT_RING - 1 do
        Shots[k].Tick := ShiftTick(Shots[k].Tick, Delta, NowTick);
      LastKillTick := ShiftTick(LastKillTick, Delta, NowTick);
      ExplosionTick := ShiftTick(ExplosionTick, Delta, NowTick);
      FlagGrabTick := ShiftTick(FlagGrabTick, Delta, NowTick);
      FlagDropTick := ShiftTick(FlagDropTick, Delta, NowTick);
      ContestedSinceTick := ShiftTick(ContestedSinceTick, Delta, NowTick);
      ScriptTeamTick := ShiftTick(ScriptTeamTick, Delta, NowTick);
      SwitchCountTick := ShiftTick(SwitchCountTick, Delta, NowTick);
      for A := 1 to MAX_PLAYERS do
        with Pair[A] do
        begin
          DamagedTick := ShiftTick(DamagedTick, Delta, NowTick);
          KilledTick := ShiftTick(KilledTick, Delta, NowTick);
          FirstDamageTick := ShiftTick(FirstDamageTick, Delta, NowTick);
          LastDamageTick := ShiftTick(LastDamageTick, Delta, NowTick);
          LastPrimaryHitTick := ShiftTick(LastPrimaryHitTick, Delta, NowTick);
          WinStartTick := ShiftTick(WinStartTick, Delta, NowTick);
        end;
    end;
end;

procedure LiveCloseTeamTime(var S: TLiveSlot; Tick: LongInt);
begin
  if (S.Team >= 0) and (S.Team <= 5) and (Tick > S.TeamSinceTick) then
    Inc(S.TeamTicks[S.Team], Tick - S.TeamSinceTick);
  S.TeamSinceTick := Tick;
end;

procedure LiveSetTeam(var S: TLiveSlot; Team, Tick: LongInt);
begin
  LiveCloseTeamTime(S, Tick);
  S.Team := Team;
end;

procedure LiveSpawn(var L: TLiveTable; Slot, Tick: LongInt; X, Y: Single);
var
  A: LongInt;
begin
  L[Slot].Alive := True;
  L[Slot].SpawnTick := Tick;
  L[Slot].X := X;
  L[Slot].Y := Y;
  L[Slot].AnchorX := X;
  L[Slot].AnchorY := Y;
  L[Slot].AnchorTick := Tick;
  L[Slot].ActX := X;
  L[Slot].ActY := Y;
  L[Slot].LastMoveTick := Tick;
  L[Slot].HasSample := True;
  L[Slot].SampleTick := Tick;
  L[Slot].LifeSeconds := 0;
  L[Slot].LifeDistance := 0;
  if not L[Slot].StreakCarry then
  begin
    L[Slot].KillStreak := 0;
    L[Slot].KnifeKillsLife := 0;
  end;
  L[Slot].StreakCarry := False;
  { a kill of the last life and one of this life are no double kill, however close together
    (the end of a survival round and the next round's spawn are a moment apart) }
  L[Slot].MultiKillCount := 0;
  L[Slot].LastKillTick := 0;
  { the flag and the posture of the last life are gone; the first sample of this life says them }
  L[Slot].Flags := 0;
  L[Slot].ClusterNades := False;
  { the hits of an earlier life are no part of this one: a selfkill right after the spawn (in
    survival right after the round starts) owes nothing to them }
  for A := 1 to MAX_PLAYERS do
  begin
    L[A].Pair[Slot].DamageThisLife := 0;
    L[A].Pair[Slot].FirstDamageTick := 0;
    L[A].Pair[Slot].LastDamageTick := 0;
    L[A].Pair[Slot].LastPrimaryHitTick := 0;
  end;
end;

procedure LiveLifeEnded(var L: TLiveTable; Slot, Tick: LongInt; ServerKill: Boolean = False);
var
  A: LongInt;
begin
  L[Slot].Alive := False;
  L[Slot].DeathTick := Tick;
  L[Slot].StreakCarry := ServerKill;
  if not ServerKill then
  begin
    L[Slot].KillStreak := 0;
    L[Slot].KnifeKillsLife := 0;
  end;
  L[Slot].MultiKillCount := 0;
  L[Slot].ContestedSinceTick := 0;
  { a dead player carries no flag: what the last sample said must not count after the death }
  L[Slot].Flags := 0;
  { the hits on this life end with it; the kill and the selfkill that end it read them before }
  for A := 1 to MAX_PLAYERS do
  begin
    L[A].Pair[Slot].DamageThisLife := 0;
    L[A].Pair[Slot].FirstDamageTick := 0;
    L[A].Pair[Slot].LastDamageTick := 0;
    L[A].Pair[Slot].LastPrimaryHitTick := 0;
  end;
end;

procedure LiveNoteShot(var S: TLiveSlot; Tick, Weapon: LongInt; X, Y: Single);
begin
  S.Shots[S.ShotHead].Tick := Tick;
  S.Shots[S.ShotHead].Weapon := Weapon;
  S.Shots[S.ShotHead].X := X;
  S.Shots[S.ShotHead].Y := Y;
  S.ShotHead := (S.ShotHead + 1) mod SHOT_RING;
  if S.ShotCount < SHOT_RING then
    Inc(S.ShotCount);
  S.LastShotTick := Tick;
end;

{ Frag and cluster grenades are thrown the same way and a throw is not always known to be a
  cluster one, so both count as the same kind of shot when a kill is matched to its throw. }
function ShotFamily(Slot: LongInt): LongInt;
begin
  if Slot = WSLOT_CLUSTER then
    Result := WSLOT_FRAG
  else
    Result := Slot;
end;

{ projectiles whose path bends too much for the direction check }
function ArcingWeapon(W: LongInt): Boolean;
begin
  Result := (W = WEP_M79) or (W = WEP_FRAG) or (W = WEP_CLUSTERNADE) or (W = WEP_CLUSTER) or
    (W = WEP_THROWNKNIFE) or (W = WEP_KNIFE) or (W = WEP_BOW) or (W = WEP_BOW2) or (W = WEP_FLAMER);
end;

{ BVX/BVY: velocity of the bullet at the hit, 0/0 when unknown }
function LiveFindShot(const S: TLiveSlot; Weapon, HitTick: LongInt; HX, HY, BVX, BVY: Single; out SX, SY: Single): Boolean;
var
  k, Idx, Age, Want: LongInt;
  Speed, D, VLen: Single;
  CheckDir: Boolean;
begin
  Result := False;
  SX := 0;
  SY := 0;
  Want := ShotFamily(WepSlot(Weapon));
  if Want < 0 then
    Exit;
  Speed := WeaponMaxBulletSpeed(Weapon);
  VLen := Hypot(BVX, BVY);
  CheckDir := (VLen > 1) and not ArcingWeapon(Weapon);
  for k := 0 to S.ShotCount - 1 do
  begin
    Idx := (S.ShotHead - 1 - k + 2 * SHOT_RING) mod SHOT_RING;
    Age := HitTick - S.Shots[Idx].Tick;
    if Age < -2 then
      Continue;
    if Age > MAX_FLIGHT_TICKS then
      Break;
    if ShotFamily(WepSlot(S.Shots[Idx].Weapon)) <> Want then
      Continue;
    D := Hypot(HX - S.Shots[Idx].X, HY - S.Shots[Idx].Y);
    { a projectile cannot be faster than its weapon allows; a few ticks and pixels of slack
      cover sampling at game ticks }
    if D > Speed * (Max(Age, 0) + 3) + 40 then
      Continue;
    { a straight bullet flies away from where it was fired (within 60 degrees) }
    if CheckDir and (D > 60) and
       ((HX - S.Shots[Idx].X) * BVX + (HY - S.Shots[Idx].Y) * BVY < 0.5 * D * VLen) then
      Continue;
    SX := S.Shots[Idx].X;
    SY := S.Shots[Idx].Y;
    Exit(True);
  end;
end;

function LiveNoteSample(var S: TLiveSlot; Tick: LongInt; X, Y: Single; Weapon, Ammo, Jets, Flags: LongInt;
  CampRadius: Single): Single;
begin
  Result := 0;
  if S.HasSample and S.Alive then
  begin
    Result := Hypot(X - S.X, Y - S.Y);
    if Result > TELEPORT_PX then
      Result := 0;
  end;
  if not S.HasSample or (Hypot(X - S.AnchorX, Y - S.AnchorY) > CampRadius) then
  begin
    S.AnchorX := X;
    S.AnchorY := Y;
    S.AnchorTick := Tick;
  end;
  if not S.HasSample or (Hypot(X - S.ActX, Y - S.ActY) > ACTIVITY_RADIUS) then
  begin
    S.ActX := X;
    S.ActY := Y;
    S.LastMoveTick := Tick;
  end;
  S.X := X;
  S.Y := Y;

  S.Weapon := Weapon;
  S.Ammo := Ammo;
  S.Jets := Jets;
  S.Flags := Flags;
  S.HasSample := True;
  S.SampleTick := Tick;
end;

function LiveInactiveTicks(const S: TLiveSlot; Tick: LongInt): LongInt;
begin
  Result := Tick - Max(Max(S.LastMoveTick, S.LastShotTick), S.SpawnTick);
  if Result < 0 then
    Result := 0;
end;

function LiveCampTicks(const S: TLiveSlot; Tick: LongInt): LongInt;
begin
  if not S.Alive then
    Exit(0);
  Result := Tick - Max(S.AnchorTick, S.SpawnTick);
  if Result < 0 then
    Result := 0;
end;

function LiveIsEnemy(const L: TLiveTable; A, B: LongInt; TeamGame: Boolean): Boolean;
begin
  Result := (A <> B) and (A >= 1) and (A <= MAX_PLAYERS) and (B >= 1) and (B <= MAX_PLAYERS);
  if Result and TeamGame then
    Result := L[A].Team <> L[B].Team;
end;

function LiveIsTeammate(const L: TLiveTable; A, B: LongInt; TeamGame: Boolean): Boolean;
begin
  Result := TeamGame and (A <> B) and (A >= 1) and (A <= MAX_PLAYERS) and (B >= 1) and (B <= MAX_PLAYERS) and
    (L[A].Team = L[B].Team) and (L[A].Team >= TEAM_ALPHA) and (L[A].Team <= TEAM_DELTA);
end;

function LiveHumansPlaying(const L: TLiveTable): LongInt;
var
  S: LongInt;
begin
  Result := 0;
  for S := 1 to MAX_PLAYERS do
    { a player the script kicked is on the way out and must not fill the line-up }
    if L[S].Active and L[S].Human and not L[S].PendingKick and (L[S].Team <> TEAM_SPEC) then
      Inc(Result);
end;

{ ---------------- hit model ---------------- }

function PostureOf(Flags: LongInt; Victim: Boolean): LongInt;
var
  Prone, Crouch, Ground: LongInt;
begin
  if Victim then
  begin
    Prone := EF_B_PRONE;
    Crouch := EF_B_CROUCH;
    Ground := EF_B_ONGROUND;
  end
  else
  begin
    Prone := EF_A_PRONE;
    Crouch := EF_A_CROUCH;
    Ground := EF_A_ONGROUND;
  end;
  if Flags and Prone <> 0 then
    Result := POSTURE_PRONE
  else if Flags and Crouch <> 0 then
    Result := POSTURE_CROUCH
  else if Flags and Ground = 0 then
    Result := POSTURE_AIR
  else
    Result := POSTURE_STAND;
end;

procedure HitOffset(BX, BY, BVX, VX, VY: Single; out DX, DY: Double);
begin
  { along the bullet direction, so hits from the left and the right share one model }
  DX := BX - VX;
  if BVX < 0 then
    DX := -DX;
  DY := BY - VY;
end;

procedure HitModelLearn(var Cell: THitModelCell; DX, DY: Double);
begin
  Inc(Cell.N);
  Cell.SumX := Cell.SumX + DX;
  Cell.SumY := Cell.SumY + DY;
  Cell.SumXX := Cell.SumXX + DX * DX;
  Cell.SumYY := Cell.SumYY + DY * DY;
  Cell.SumXY := Cell.SumXY + DX * DY;
end;

function HitModelClassify(const Cells: array of THitModelCell; DX, DY: Double; MinSamples: LongInt): LongInt;
var
  z: LongInt;
  N, Total, MX, MY, SXX, SYY, SXY, Det, EX, EY, Maha, Score, Best: Double;
begin
  Result := HZ_UNKNOWN;
  if Length(Cells) < 3 then
    Exit;
  Total := 0;
  for z := 0 to 2 do
  begin
    if Cells[z].N < MinSamples then
      Exit;
    Total := Total + Cells[z].N;
  end;
  Best := -1e300;
  for z := 0 to 2 do
  begin
    N := Cells[z].N;
    MX := Cells[z].SumX / N;
    MY := Cells[z].SumY / N;
    { a small variance floor keeps a very tight cluster from swallowing its neighbours }
    SXX := Max(Cells[z].SumXX / N - MX * MX, 0) + 4;
    SYY := Max(Cells[z].SumYY / N - MY * MY, 0) + 4;
    SXY := Cells[z].SumXY / N - MX * MY;
    Det := SXX * SYY - SXY * SXY;
    if Det <= 1e-6 then
      Continue;
    EX := DX - MX;
    EY := DY - MY;
    Maha := (EX * EX * SYY - 2 * EX * EY * SXY + EY * EY * SXX) / Det;
    Score := -0.5 * Maha - 0.5 * Ln(Det) + Ln(N / Total);
    if Score > Best then
    begin
      Best := Score;
      Result := z;
    end;
  end;
end;

end.
