unit zs_fight;

{ !lastfight: what happened around the last deaths of a player. Runtime only, nothing is saved.

  Every human on the server keeps a ring of his recent fight events (TLfSlot, a field of the
  engine's TSlotExtra, so a join or a leave clears it): the hits he took and the hits he dealt, his
  kills and the notes of his HUD (points, assists, feats). The hits of one burst are one entry: the
  pellets of a shot, a stream of flames, a blade or a volley of hits on the same player. A death
  opens a record (the killer, the weapon, who met the assist rule); when the seconds after the death
  are over, or at the respawn, the record takes the events of its window out of the ring - from
  BeforeSeconds before the death (not before the life began) to that moment - so it also holds the
  bullets that still hit or killed after the death and the points the death cost. The last
  LF_DEATHS records are kept. Everything has a fixed size: no allocation for a hit.

  What is measured and what is estimated:
  - damage: the server's number, at most the health that was left; the zone from the damage, or
    from the hit model for weapons whose zones do the same damage (a guess, marked ~);
  - distance: from where the shot was fired to where the bullet hit, as for the kill distance -
    never from where the players stand. The place of the shot is the one main.pas saw with it (the
    ammunition of a human went down). A shot nobody saw (bots report no shots, the stationary gun
    is not followed) is worked out from the bullet itself (marked ~, LfBulletFlight): its velocity
    at the hit, the speed it left the gun with (the weapon's, plus the share of the shooter's own
    velocity it inherits) and Soldat's physics of a bullet (every tick gravity pulls it and it
    keeps 99% of its speed). That is exact while the shooter kept his pace from the shot to the
    hit; every pixel a tick he changed it along the line of fire moves the estimate by about 3.6 m,
    and a bullet slowed by a body it went through or a wall it glanced off reads as a longer shot.
    None for bullets too slow for their gravity (the Spas-12), explosions, flames, blades and a
    thrown knife;
  - flight time: from the distance and the bullet speed of the weapon, with the drag of Soldat's
    bullets, or the ticks the estimate above counted; none for what does not fly straight
    (explosions, flames, a thrown knife);
  - speed: of the one who was hit - the player himself or the one he hit -, from his velocity at
    the hit, which main.pas sends with it;
  - dodge: an estimate from the flight time and that speed: under LF_REACT_SECONDS nobody reacts,
    up to LF_HARD_SECONDS it is hard, a longer flight gave a chance; standing still is said. Blades,
    explosions, flames and thrown knives get none. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, zs_types, zs_util, zs_weapons;

const
  LF_RING = 96;          { recent events of a player }
  LF_EVENTS = 48;        { events of one death }
  LF_DEATHS = 3;         { deaths kept of a player }
  LF_FOES = 8;           { players the tables of one death name }

  { kinds of events }
  LFE_TAKEN = 1;         { a hit on the player }
  LFE_DEALT = 2;         { a hit of the player on somebody }
  LFE_KILL = 3;          { the player killed somebody }
  LFE_NOTE = 4;          { a note of his HUD: points, an assist, a feat }

  { flags of events and of the killer of a record }
  LFF_SELF = 1;          { his own hit on himself }
  LFF_MATE = 2;          { between teammates }
  LFF_LETHAL = 4;        { the hit that killed him, or the hit of his kill }
  LFF_AFTER = 8;         { the shooter was dead already: a bullet still flying }
  LFF_DIST_EST = 16;     { distance and flight are worked out from the bullet: nobody saw the shot }
  LFF_VEST = 32;         { the one who was hit wore a vest }
  LFF_ZONE_EST = 64;     { the zone is the hit model's guess }
  LFF_BOT = 128;         { the other one is a bot }

  { kinds of deaths }
  LFD_ENEMY = 1;
  LFD_TEAM = 2;          { a teammate killed him }
  LFD_SELF = 3;          { his own weapon }
  LFD_WORLD = 4;         { no weapon: a fall, a deadly polygon, the kill command, a script }
  LFD_LEFT = 5;          { the killer left the server in that moment }

  { the dodge estimate: seconds of flight nobody reacts to, and up to which it is hard }
  LF_REACT_SECONDS = 0.25;
  LF_HARD_SECONDS = 0.40;
  { slower than this (m/s) is standing still }
  LF_STILL_MS = 2.0;
  { the share of its speed a bullet loses every tick (Soldat's BulletParts.EDamping = 0.99) }
  LF_DRAG = 0.01;
  { what gravity adds to a bullet's velocity every tick, in pixels a tick (BulletParts.Gravity =
    2.25 times sv_gravity, 0.06 unless the server changed it) }
  LF_GRAVITY = 0.135;
  { a bullet lives 7 seconds (BULLET_TIMEOUT): an estimate of a longer flight is wrong }
  LF_MAX_FLIGHT_TICKS = 7 * TICKS_PER_SECOND;

type
  TLfEvent = record
    Tick: LongInt;             { the first hit, the kill, the note }
    LastTick: LongInt;         { the last hit of the entry }
    Kind: Byte;                { LFE_* }
    Other: Byte;               { the slot of the other player, 0 = none }
    Count: Word;               { hits in the entry }
    Weapon: SmallInt;          { weapon number, -1 = none }
    Flags: Word;               { LFF_* }
    LastZone: ShortInt;        { zone of the last hit, -1 = none }
    Zones: array[0..3] of Byte;   { hits by zone: head, body, legs, not known }
    Damage: Single;            { all hits, each at most the health that was left }
    Health: Single;            { health of the one who was hit before the first hit, 0 = unknown }
    Dist: Single;              { pixels from where the shot was fired to the hit, < 0 = unknown }
    Flight: Single;            { seconds the bullet flew (estimated), < 0 = unknown }
    Speed: Single;             { m/s of the one who was hit (he or the one he hit), < 0 = unknown }
    Points: LongInt;           { a note: the points it gives or takes }
    Text: string[31];          { the other player's name, or the text of a note }
  end;
  PLfEvent = ^TLfEvent;

  TLfRecord = record
    Used: Boolean;
    Closed: Boolean;           { the window after the death is over: Events hold it }
    Kind: Byte;                { LFD_* }
    Killer: Byte;              { slot, 0 = none or left }
    KillerWeapon: SmallInt;
    KillerFlags: Word;         { LFF_AFTER, LFF_BOT, LFF_MATE }
    StatsOn: Boolean;          { the statistics counted: points and assists could change }
    DeathTick: LongInt;
    LifeTick: LongInt;         { the spawn of the life that ended, 0 = not known }
    FromTick: LongInt;         { the first tick the record holds }
    EndTick: LongInt;          { the last tick of the seconds after the death }
    When: TDateTime;
    Assists: LongWord;         { bit (slot - 1): that player met the assist rule at the death }
    KillerName: string[24];
    MapName: string[40];
    Count: LongInt;
    Missed: LongInt;           { events of the window that were not kept }
    Events: array[0..LF_EVENTS - 1] of TLfEvent;
  end;
  PLfRecord = ^TLfRecord;

  TLfSlot = record
    Head: LongInt;             { the next place in Ring }
    Count: LongInt;
    LostTick: LongInt;         { the newest tick an overwritten entry reached }
    Ring: array[0..LF_RING - 1] of TLfEvent;
    Deaths: LongInt;           { records written; the newest is Recs[(Deaths - 1) mod LF_DEATHS] }
    Recs: array[0..LF_DEATHS - 1] of TLfRecord;
  end;
  PLfSlot = ^TLfSlot;

  { one player in the tables of a death: who hurt him, or whom he hit }
  TLfFoe = record
    Slot: LongInt;
    Name: string[24];
    Flags: LongInt;            { LFF_BOT, LFF_MATE, LFF_SELF of the hits }
    Hits: LongInt;
    Damage: Double;
    Zones: array[0..3] of LongInt;
    ZoneEst: Boolean;
    First, Last: LongInt;      { ticks of the first and the last hit }
    Weapons: array[0..1] of LongInt;
    WeaponCount: LongInt;      { weapons used, may be more than kept }
    Killed: Boolean;           { dealt: the player killed this one }
    KillTick: LongInt;
    KillFlags: LongInt;
  end;
  TLfFoes = array[0..LF_FOES - 1] of TLfFoe;

{ seconds a bullet of weapon W needs for DistPx pixels, -1 when it cannot be told }
function LfFlightSeconds(W: LongInt; DistPx: Single): Single;
{ the bullet of weapon W flies straight, so its time in the air follows from the distance: not a
  blade, an explosion, a flame or a thrown knife }
function LfStraightFlight(W: LongInt): Boolean;
{ How far the bullet of weapon W that hit with the velocity VX, VY (pixels a tick) flew, worked out
  from the bullet itself: it left the gun at the weapon's speed plus InheritedVelocity times the
  shooter's velocity SVX, SVY (0, 0 when not known), and every tick of Soldat's physics gravity
  pulled it and it kept 99% of its speed. Dist = pixels from the gun to the hit, Ticks = ticks in
  the air. False when the bullet cannot tell: not a straight bullet, too slow for its gravity (the
  Spas-12), no velocity, or longer in the air than a bullet lives. }
function LfBulletFlight(W: LongInt; VX, VY, SVX, SVY: Single; out Dist, Ticks: Single): Boolean;
{ ticks a hit may follow the last one of an entry and still belong to it }
function LfMergeTicks(Kind, W: LongInt): LongInt;
{ the entry of the ring a hit of the same burst goes into, nil = none }
function LfBurst(var F: TLfSlot; Kind, Other, Weapon, Tick, After: LongInt): PLfEvent;
{ a hit added to its entry }
procedure LfAddHit(P: PLfEvent; Tick: LongInt; Dmg: Single; Zone, Flags: LongInt);
{ a new entry at the end of the ring }
function LfAppend(var F: TLfSlot; const Ev: TLfEvent): PLfEvent;
{ the newest entry of a kind with Other since SinceTick, nil = none }
function LfLatest(var F: TLfSlot; Kind, Other, SinceTick: LongInt): PLfEvent;
{ the points of a HUD note ("+22 pts", "-18 pts teamkill"), 0 = none }
function LfNotePoints(const Text: AnsiString): LongInt;
{ the deaths kept, and death N of them (1 = the last), nil when there is none }
function LfRecords(const F: TLfSlot): LongInt;
function LfRecordAt(var F: TLfSlot; N: LongInt): PLfRecord;
{ the newest record while its window is still open, nil = none }
function LfOpenRecord(var F: TLfSlot): PLfRecord;
{ the record for a new death (the oldest one goes), empty }
function LfNewRecord(var F: TLfSlot): PLfRecord;
{ the last tick of the window of R: the seconds after the death, cut at the respawn (SpawnTick) and
  at NowTick }
function LfWindowEnd(const R: TLfRecord; SpawnTick, NowTick: LongInt): LongInt;
{ R.Events := the events of the ring from R.FromTick to ToTick, oldest first; the newest ones when they
  do not all fit }
procedure LfCollect(const F: TLfSlot; var R: TLfRecord; ToTick: LongInt);
{ the players who hurt him (Dealt = False) or whom he hit and killed (True), most damage first }
function LfFoes(const R: TLfRecord; Dealt: Boolean; out Foes: TLfFoes): LongInt;
{ could the one who was hit have dodged it (he, or the one he hit): no, hard, maybe (still), melee,
  blast, flame, thrown, self, ? }
function LfDodge(const Ev: TLfEvent): AnsiString;
{ hits by zone: "head" for one hit, "2h1b" for more (Sep between the parts), "-" for none }
function LfZones(Head, Body, Legs, Unknown: LongInt; Est: Boolean; const Sep: AnsiString): AnsiString;
function LfEventZones(const Ev: TLfEvent; const Sep: AnsiString): AnsiString;
{ ticks from the death as seconds: "-2.41", "+0.35", "0.00" }
function LfSeconds(Ticks, Decimals: LongInt): AnsiString;
{ a distance in pixels as meters ("23 m", "~23 m"), '' when unknown }
function LfMeters(Px: Single; Est: Boolean): AnsiString;
function LfWeaponShort(W: LongInt): AnsiString;
function LfWeaponLong(W: LongInt): AnsiString;
{ the two console lines of [LastFight] DeathSummary, each at most 100 characters }
procedure LfSummary(const R: TLfRecord; BeforeSeconds: LongInt; out Line1, Line2: AnsiString);

implementation

const
  SUMMARY_W = 100;

function LfFlightSeconds(W: LongInt; DistPx: Single): Single;
var
  S: LongInt;
  V0, X: Double;
begin
  Result := -1;
  S := WepSlot(W);
  if (S < 0) or (DistPx < 0) then
    Exit;
  V0 := WeaponDefs[S].Speed;
  { a thrown knife flies up to half again as fast as the weapon's speed }
  if W = WEP_THROWNKNIFE then
    V0 := V0 * 1.5;
  if V0 < 1 then
    Exit;
  { after n ticks a bullet has flown V0 * (1 - 0.99^n) / 0.01 }
  X := 1 - LF_DRAG * DistPx / V0;
  { farther than the bullet carries: the distance belongs to another shot }
  if X < 0.05 then
    Exit;
  Result := Ln(X) / Ln(1 - LF_DRAG) / TICKS_PER_SECOND;
end;

function LfStraightFlight(W: LongInt): Boolean;
var
  S: LongInt;
begin
  S := WepSlot(W);
  Result := (S >= 0) and not IsMeleeWeapon(W) and not IsExplosiveWeapon(W) and (W <> WEP_FLAMER) and
    (W <> WEP_THROWNKNIFE) and (WeaponDefs[S].BulletStyle in [BS_PLAIN, BS_SHOTGUN, BS_ARROW, BS_M2]);
end;

function LfBulletFlight(W: LongInt; VX, VY, SVX, SVY: Single; out Dist, Ticks: Single): Boolean;
var
  S: LongInt;
  V0, D, G, CX, CY, A, B, C, Q, K, Back, PX, PY: Double;
begin
  Result := False;
  Dist := -1;
  Ticks := -1;
  if not LfStraightFlight(W) or (Hypot(VX, VY) < 1) then
    Exit;
  S := WepSlot(W);
  V0 := WeaponDefs[S].Speed;
  D := 1 - LF_DRAG;
  { the speed a falling bullet ends up with, gravity against the drag: 13.4 pixels a tick }
  G := LF_GRAVITY * D / LF_DRAG;
  CX := WeaponDefs[S].Inherit * SVX;
  CY := WeaponDefs[S].Inherit * SVY;
  { After n ticks a bullet keeps Q = 0.99^n of the velocity U it left the gun with, and gravity has
    added G * (1 - Q) downwards: V = Q * U + (0, G * (1 - Q)). U is the weapon's speed V0 in some
    direction plus C, the shooter's share: |U - C| = V0, a quadratic in Q. Where gravity weighs
    this much against the speed, the answer swings with every error: no estimate. }
  A := Sqr(V0) - Sqr(CX) - Sqr(G - CY);
  if A < 0.25 * Sqr(V0) then
    Exit;
  B := 2 * VX * CX - 2 * (VY - G) * (G - CY);
  C := Sqr(VX) + Sqr(VY - G);
  Q := (Sqrt(Sqr(B) + 4 * A * C) - B) / (2 * A);
  if IsNan(Q) or (Q <= 0) then
    Exit;
  { faster than it left the gun: it was fired a moment before the hit }
  if Q > 1 then
    Q := 1;
  K := Ln(Q) / Ln(D);
  if K > LF_MAX_FLIGHT_TICKS then
    Exit;
  { back to the gun as Soldat moves a bullet (Parts.pas, Euler): every tick the velocity grows by
    gravity, the bullet moves by it, then keeps 99% of it; the hit lies within the step of the
    last tick, taken as its middle }
  Back := (1 - Q) / LF_DRAG;
  PX := VX / Q * Back + 0.5 * VX;
  PY := (VY - G * (1 - Q)) / Q * Back + K * G / D - G * Back + 0.5 * VY;
  if IsNan(PX) or IsNan(PY) or IsInfinite(PX) or IsInfinite(PY) then
    Exit;
  Dist := Hypot(PX, PY);
  Ticks := K + 0.5;
  Result := True;
end;

function LfMergeTicks(Kind, W: LongInt): LongInt;
begin
  case Kind of
    { every bullet he took is a line of its own; only the pellets and bullets of one shot, the
      bomblets of a cluster and a stream of flames or a blade are one }
    LFE_TAKEN:
      if IsMeleeWeapon(W) or (W = WEP_FLAMER) then
        Result := 20
      else if IsExplosiveWeapon(W) then
        Result := 6
      else
        Result := 2;
    LFE_DEALT:
      Result := 30;
    else
      Result := -1;
  end;
end;

function RingIndex(const F: TLfSlot; k: LongInt): LongInt;
begin
  { k = 0 is the newest entry }
  Result := (F.Head - 1 - k + 2 * LF_RING) mod LF_RING;
end;

function LfBurst(var F: TLfSlot; Kind, Other, Weapon, Tick, After: LongInt): PLfEvent;
var
  k, Gap: LongInt;
  P: PLfEvent;
begin
  Result := nil;
  Gap := LfMergeTicks(Kind, Weapon);
  if Gap < 0 then
    Exit;
  { a few entries back: the hits of two players on each other alternate }
  for k := 0 to Min(F.Count, 6) - 1 do
  begin
    P := @F.Ring[RingIndex(F, k)];
    if (P^.Kind = Kind) and (P^.Other = Other) and (P^.Weapon = Weapon) and (P^.Flags and LFF_AFTER = After) and
       (P^.Flags and LFF_LETHAL = 0) and (Tick >= P^.LastTick) and (Tick - P^.LastTick <= Gap) then
      Exit(P);
  end;
end;

procedure LfAddHit(P: PLfEvent; Tick: LongInt; Dmg: Single; Zone, Flags: LongInt);
begin
  P^.LastTick := Tick;
  if P^.Count < High(Word) then
    Inc(P^.Count);
  P^.Damage := P^.Damage + Dmg;
  P^.Flags := P^.Flags or (Flags and (LFF_VEST or LFF_ZONE_EST));
  if (Zone >= 0) and (Zone <= 3) then
  begin
    if P^.Zones[Zone] < High(Byte) then
      Inc(P^.Zones[Zone]);
    P^.LastZone := Zone;
  end;
end;

function LfAppend(var F: TLfSlot; const Ev: TLfEvent): PLfEvent;
begin
  { the entry about to be overwritten: the window of a record that reaches back to it lost it }
  if F.Count >= LF_RING then
    F.LostTick := Max(F.LostTick, F.Ring[F.Head].LastTick)
  else
    Inc(F.Count);
  F.Ring[F.Head] := Ev;
  Result := @F.Ring[F.Head];
  F.Head := (F.Head + 1) mod LF_RING;
end;

function LfLatest(var F: TLfSlot; Kind, Other, SinceTick: LongInt): PLfEvent;
var
  k: LongInt;
  P: PLfEvent;
begin
  Result := nil;
  for k := 0 to F.Count - 1 do
  begin
    P := @F.Ring[RingIndex(F, k)];
    if P^.LastTick < SinceTick then
      Exit;
    if (P^.Kind = Kind) and (P^.Other = Other) then
      Exit(P);
  end;
end;

function LfNotePoints(const Text: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  if (Length(Text) < 6) or not (Text[1] in ['+', '-']) then
    Exit;
  k := 2;
  while (k <= Length(Text)) and (Text[k] in ['0'..'9']) do
    Inc(k);
  if (k = 2) or (k > 10) or (Copy(Text, k, 4) <> ' pts') then
    Exit;
  Result := StrToIntDef(Copy(Text, 2, k - 2), 0);
  if Text[1] = '-' then
    Result := -Result;
end;

function LfRecords(const F: TLfSlot): LongInt;
begin
  Result := Min(F.Deaths, LF_DEATHS);
end;

function LfRecordAt(var F: TLfSlot; N: LongInt): PLfRecord;
begin
  if (N < 1) or (N > LfRecords(F)) then
    Exit(nil);
  Result := @F.Recs[(F.Deaths - N) mod LF_DEATHS];
  if not Result^.Used then
    Result := nil;
end;

function LfOpenRecord(var F: TLfSlot): PLfRecord;
begin
  Result := LfRecordAt(F, 1);
  if (Result <> nil) and Result^.Closed then
    Result := nil;
end;

function LfNewRecord(var F: TLfSlot): PLfRecord;
begin
  Result := @F.Recs[F.Deaths mod LF_DEATHS];
  FillChar(Result^, SizeOf(TLfRecord), 0);
  Result^.Used := True;
  { the counter only counts on; a server that runs for years is far from its end }
  if F.Deaths < MaxInt - LF_DEATHS then
    Inc(F.Deaths)
  else
    F.Deaths := LF_DEATHS + F.Deaths mod LF_DEATHS + 1;
end;

function LfWindowEnd(const R: TLfRecord; SpawnTick, NowTick: LongInt): LongInt;
begin
  Result := R.EndTick;
  if SpawnTick > R.DeathTick then
    Result := Min(Result, SpawnTick - 1);
  Result := Max(R.DeathTick, Min(Result, NowTick));
end;

procedure LfCollect(const F: TLfSlot; var R: TLfRecord; ToTick: LongInt);
var
  k, Total, Skip: LongInt;
  P: ^TLfEvent;
begin
  { the entries of the window, oldest first; when they do not fit, the oldest ones are left out:
    the last moments and what came after the death matter most }
  Total := 0;
  for k := F.Count - 1 downto 0 do
  begin
    P := @F.Ring[RingIndex(F, k)];
    if (P^.LastTick >= R.FromTick) and (P^.Tick <= ToTick) then
      Inc(Total);
  end;
  Skip := Max(0, Total - LF_EVENTS);
  R.Missed := Skip;
  { the ring overwrote an entry of the window before the record took it }
  if F.LostTick >= R.FromTick then
    Inc(R.Missed);
  R.Count := 0;
  for k := F.Count - 1 downto 0 do
  begin
    P := @F.Ring[RingIndex(F, k)];
    if (P^.LastTick < R.FromTick) or (P^.Tick > ToTick) then
      Continue;
    if Skip > 0 then
    begin
      Dec(Skip);
      Continue;
    end;
    R.Events[R.Count] := P^;
    Inc(R.Count);
  end;
end;

function LfFoes(const R: TLfRecord; Dealt: Boolean; out Foes: TLfFoes): LongInt;
var
  k, f, z, n: LongInt;
  Ev: ^TLfEvent;
  T: TLfFoe;
  Hit: Boolean;
begin
  Result := 0;
  Foes := Default(TLfFoes);
  for k := 0 to R.Count - 1 do
  begin
    Ev := @R.Events[k];
    if Dealt then
      Hit := Ev^.Kind = LFE_DEALT
    else
      Hit := Ev^.Kind = LFE_TAKEN;
    if not Hit and not (Dealt and (Ev^.Kind = LFE_KILL)) then
      Continue;
    f := 0;
    while (f < Result) and ((Foes[f].Slot <> Ev^.Other) or (Foes[f].Name <> Ev^.Text)) do
      Inc(f);
    if f >= Result then
    begin
      { more players than the tables name: the rest is left out }
      if Result >= LF_FOES then
        Continue;
      f := Result;
      Inc(Result);
      Foes[f].Slot := Ev^.Other;
      Foes[f].Name := Ev^.Text;
      Foes[f].First := Ev^.Tick;
      Foes[f].Last := Ev^.LastTick;
    end;
    Foes[f].Flags := Foes[f].Flags or (Ev^.Flags and (LFF_BOT or LFF_MATE or LFF_SELF));
    if Ev^.Kind = LFE_KILL then
    begin
      Foes[f].Killed := True;
      Foes[f].KillTick := Ev^.Tick;
      Foes[f].KillFlags := Ev^.Flags;
      Continue;
    end;
    Inc(Foes[f].Hits, Ev^.Count);
    Foes[f].Damage := Foes[f].Damage + Ev^.Damage;
    for z := 0 to 3 do
      Inc(Foes[f].Zones[z], Ev^.Zones[z]);
    if Ev^.Flags and LFF_ZONE_EST <> 0 then
      Foes[f].ZoneEst := True;
    Foes[f].First := Min(Foes[f].First, Ev^.Tick);
    Foes[f].Last := Max(Foes[f].Last, Ev^.LastTick);
    n := 0;
    while (n < Min(Foes[f].WeaponCount, 2)) and (Foes[f].Weapons[n] <> Ev^.Weapon) do
      Inc(n);
    if n >= Min(Foes[f].WeaponCount, 2) then
    begin
      if Foes[f].WeaponCount < 2 then
        Foes[f].Weapons[Foes[f].WeaponCount] := Ev^.Weapon;
      Inc(Foes[f].WeaponCount);
    end;
  end;
  { most damage first }
  for k := 1 to Result - 1 do
  begin
    T := Foes[k];
    f := k - 1;
    while (f >= 0) and (Foes[f].Damage < T.Damage) do
    begin
      Foes[f + 1] := Foes[f];
      Dec(f);
    end;
    Foes[f + 1] := T;
  end;
end;

function LfDodge(const Ev: TLfEvent): AnsiString;
begin
  if Ev.Flags and LFF_SELF <> 0 then
    Exit('self');
  if IsMeleeWeapon(Ev.Weapon) then
    Exit('melee');
  if IsExplosiveWeapon(Ev.Weapon) then
    Exit('blast');
  if Ev.Weapon = WEP_FLAMER then
    Exit('flame');
  { a thrown knife flies an arc at the strength of the throw }
  if Ev.Weapon = WEP_THROWNKNIFE then
    Exit('thrown');
  if Ev.Flight < 0 then
    Exit('?');
  if Ev.Flight < LF_REACT_SECONDS then
    Exit('no');
  if Ev.Flight < LF_HARD_SECONDS then
    Result := 'hard'
  else
    Result := 'maybe';
  { standing still, nothing moved him out of the line }
  if (Ev.Speed >= 0) and (Ev.Speed < LF_STILL_MS) then
    Result := Result + ' (still)';
end;

function LfZones(Head, Body, Legs, Unknown: LongInt; Est: Boolean; const Sep: AnsiString): AnsiString;
const
  NAMES: array[0..3] of AnsiString = ('head', 'body', 'legs', '?');
  SHORT: array[0..3] of AnsiString = ('h', 'b', 'l', '?');
var
  Z: array[0..3] of LongInt;
  k, n: LongInt;
begin
  Z[0] := Head;
  Z[1] := Body;
  Z[2] := Legs;
  Z[3] := Unknown;
  n := Head + Body + Legs + Unknown;
  if n <= 0 then
    Exit('-');
  Result := '';
  if n = 1 then
  begin
    for k := 0 to 3 do
      if Z[k] > 0 then
        Result := NAMES[k];
  end
  else
    for k := 0 to 3 do
      if Z[k] > 0 then
      begin
        if Result <> '' then
          Result := Result + Sep;
        Result := Result + IntToStr(Z[k]) + SHORT[k];
      end;
  if Est and (Result <> '?') then
    Result := '~' + Result;
end;

function LfEventZones(const Ev: TLfEvent; const Sep: AnsiString): AnsiString;
begin
  Result := LfZones(Ev.Zones[0], Ev.Zones[1], Ev.Zones[2], Ev.Zones[3], Ev.Flags and LFF_ZONE_EST <> 0, Sep);
end;

function LfSeconds(Ticks, Decimals: LongInt): AnsiString;
begin
  Result := FloatStr(Abs(Ticks) / TICKS_PER_SECOND, Decimals);
  { a moment shorter than the last decimal is 0, without a sign }
  if (Ticks = 0) or (Result = FloatStr(0, Decimals)) then
    Exit;
  if Ticks < 0 then
    Result := '-' + Result
  else
    Result := '+' + Result;
end;

function LfMeters(Px: Single; Est: Boolean): AnsiString;
begin
  if Px < 0 then
    Exit('');
  Result := FloatStr(Px / PIXELS_PER_METER, 0) + ' m';
  if Est then
    Result := '~' + Result;
end;

function LfWeaponShort(W: LongInt): AnsiString;
begin
  if W = WEP_WORLD then
    Result := '-'
  else
    Result := WeaponShortName(W);
end;

function LfWeaponLong(W: LongInt): AnsiString;
begin
  if W = WEP_WORLD then
    Result := 'no weapon'
  else
    Result := WeaponName(W);
end;

{ parts added to a line while it stays within SUMMARY_W }
procedure AddPart(var Line: AnsiString; const Part: AnsiString);
begin
  if (Part <> '') and (Length(Line) + Length(Part) <= SUMMARY_W) then
    Line := Line + Part;
end;

function HitsText(Hits: LongInt): AnsiString;
begin
  if Hits = 1 then
    Result := '1 hit'
  else
    Result := IntToStr(Hits) + ' hits';
end;

procedure LfSummary(const R: TLfRecord; BeforeSeconds: LongInt; out Line1, Line2: AnsiString);
var
  Taken, Dealt: TLfFoes;
  nTaken, nDealt, k, KillerFoe, Lost, Won, Assists: LongInt;
  Lethal: ^TLfEvent;
  Dmg: Double;
  S, Z, Name, Tail, Kills: AnsiString;
begin
  nTaken := LfFoes(R, False, Taken);
  nDealt := LfFoes(R, True, Dealt);
  Lethal := nil;
  Lost := 0;
  Won := 0;
  Assists := 0;
  for k := 0 to R.Count - 1 do
    case R.Events[k].Kind of
      LFE_TAKEN:
        if R.Events[k].Flags and LFF_LETHAL <> 0 then
          Lethal := @R.Events[k];
      LFE_NOTE:
        begin
          { what the death cost is taken from the moment of the death on; anything else won }
          if (R.Events[k].Points < 0) and (R.Events[k].Tick >= R.DeathTick) then
            Inc(Lost, -R.Events[k].Points)
          else if R.Events[k].Points > 0 then
            Inc(Won, R.Events[k].Points);
          if R.Events[k].Text = 'Assist' then
            Inc(Assists);
        end;
    end;
  Name := Copy(R.KillerName, 1, 16);
  { the killer's line of the table: his own for a selfkill }
  KillerFoe := -1;
  for k := 0 to nTaken - 1 do
    if R.Kind = LFD_SELF then
    begin
      if Taken[k].Flags and LFF_SELF <> 0 then
        KillerFoe := k;
    end
    else if (R.Kind <> LFD_WORLD) and (R.KillerName <> '') and (Taken[k].Slot = R.Killer) and
      (Taken[k].Name = R.KillerName) then
      KillerFoe := k;

  { who killed him, with what, how the killer's hits landed }
  case R.Kind of
    LFD_SELF:
      Line1 := 'You killed yourself (' + LfWeaponLong(R.KillerWeapon) + ')';
    LFD_WORLD:
      Line1 := 'You died without a weapon hit (a fall, the map, the kill command or a script)';
    else
    begin
      if R.Kind = LFD_TEAM then
        Line1 := 'Killed by your teammate ' + Name
      else if Name = '' then
        Line1 := 'Killed by a player who left'
      else
        Line1 := 'Killed by ' + Name;
      Line1 := Line1 + ' (' + LfWeaponLong(R.KillerWeapon);
      if (Lethal <> nil) and (Lethal^.Dist >= 0) then
        Line1 := Line1 + ', ' + LfMeters(Lethal^.Dist, Lethal^.Flags and LFF_DIST_EST <> 0);
      if (Lethal <> nil) and (Lethal^.LastZone >= HZ_HEAD) and (Lethal^.LastZone <= HZ_LEGS) then
        Line1 := Line1 + ', ' + LfZones(Ord(Lethal^.LastZone = HZ_HEAD), Ord(Lethal^.LastZone = HZ_BODY),
          Ord(Lethal^.LastZone = HZ_LEGS), 0, Lethal^.Flags and LFF_ZONE_EST <> 0, '');
      Line1 := Line1 + ')';
      if (R.Kind = LFD_LEFT) and (Name <> '') then
        Line1 := Line1 + ', who left';
      if R.KillerFlags and LFF_AFTER <> 0 then
        Line1 := Line1 + ' after his death';
    end;
  end;
  if KillerFoe >= 0 then
  begin
    S := Format(': %s, %s dmg', [HitsText(Taken[KillerFoe].Hits), FloatStr(Taken[KillerFoe].Damage, 0)]);
    { the zones that were told; explosions, blades and flames have none }
    Z := LfZones(Taken[KillerFoe].Zones[0], Taken[KillerFoe].Zones[1], Taken[KillerFoe].Zones[2], 0,
      Taken[KillerFoe].ZoneEst, ' ');
    if Z <> '-' then
      S := S + ' (' + Z + ')';
    AddPart(Line1, S);
  end;
  { the points close the line; everybody else who hurt him, most damage first, fills the rest }
  if not R.StatsOn then
    Tail := '; no points (statistics off)'
  else if Lost > 0 then
    Tail := Format('; -%d pts', [Lost])
  else
    Tail := '';
  S := '';
  for k := 0 to nTaken - 1 do
    if k <> KillerFoe then
    begin
      if Taken[k].Flags and LFF_SELF <> 0 then
        Z := 'yourself'
      else
        Z := Copy(Taken[k].Name, 1, 16);
      Z := Z + ' ' + FloatStr(Taken[k].Damage, 0);
      if S = '' then
        Z := '; also hurt by ' + Z
      else
        Z := ', ' + Z;
      if Length(Line1) + Length(S) + Length(Z) + Length(Tail) > SUMMARY_W then
        Break;
      S := S + Z;
    end;
  AddPart(Line1, S);
  AddPart(Line1, Tail);

  { what he did in those seconds: the kills first, then whom he hit, as far as the line goes; the
    points, the assists and the hint close it }
  Tail := '';
  if R.StatsOn and (Won > 0) then
    Tail := Tail + Format('; +%d pts', [Won]);
  if R.StatsOn and (Assists > 0) then
    Tail := Tail + Format('; %d assist%s', [Assists, BoolToStr(Assists = 1, '', 's')]);
  Tail := Tail + ' - details: !lastfight';
  if nDealt = 0 then
    Line2 := Format('You hit nobody in the last %d s', [BeforeSeconds])
  else
  begin
    Dmg := 0;
    for k := 0 to nDealt - 1 do
      Dmg := Dmg + Dealt[k].Damage;
    Line2 := 'You dealt ' + FloatStr(Dmg, 0) + ' dmg';
    Kills := '';
    for k := 0 to nDealt - 1 do
      if Dealt[k].Killed then
      begin
        Z := Copy(Dealt[k].Name, 1, 16);
        if (Dealt[k].KillFlags and LFF_AFTER <> 0) and (Dealt[k].KillTick > R.DeathTick) then
          Z := Z + ' after your death';
        if Kills = '' then
          Z := '; killed ' + Z
        else
          Z := ', ' + Z;
        if Length(Line2) + Length(Kills) + Length(Z) + Length(Tail) > SUMMARY_W then
          Break;
        Kills := Kills + Z;
      end;
    S := '';
    for k := 0 to nDealt - 1 do
      if Dealt[k].Hits > 0 then
      begin
        Z := Copy(Dealt[k].Name, 1, 16) + ' ' + FloatStr(Dealt[k].Damage, 0);
        if S = '' then
          Z := ': ' + Z
        else
          Z := ', ' + Z;
        if Length(Line2) + Length(S) + Length(Z) + Length(Kills) + Length(Tail) > SUMMARY_W then
          Break;
        S := S + Z;
      end;
    Line2 := Line2 + S + Kills;
  end;
  AddPart(Line2, Tail);
end;

end.
