unit zs_bridge;

{ The bridges on the game thread ([Bridges] in settings.ini): what main.pas used to read through
  the properties of ScriptCore, read by the library from the server itself (zs_mem), and every
  bullet and every hit the server makes (zs_hook).

  ZS_Frame runs at the start of every tick: the bullets of the last tick become events (added up
  per player, weapon and stance), every human the library can read is followed here (the
  ammunition for the reloads, the grenades when there is no hook, the health for the kits, a
  sample of his place every 12 ticks) and the lives of the bots are watched. It returns the humans
  it followed; main.pas follows the others itself, as before.

  ZS_Ev_Hit and ZS_Ev_Death take only the ids of a hit or a kill and read the rest at that moment:
  the bullet (its weapon, place and speed, and where and when it was fired), the players (place,
  speed, health, vest, stance, the flag), the part of the body the server's own hit test chose
  (HealthHit) and the points for the engine's line of sight. A bullet the hook did not see made is
  a script's: its hits count as damage, never for the accuracy. When something cannot be read they
  answer 0 and main.pas sends the old, full event.

  Everything here runs on the game thread, the only one that touches zs_mem and zs_hook. The engine
  thread only gets events (BridgePush) and reads BridgeStatus under its lock. }

{$mode objfpc}{$H+}

interface

uses
  zs_types;

type
  TPushProc = procedure(var E: TZSEvent);

var
  { the engine's queue (set by zs_main) }
  BridgePush: TPushProc = nil;
  { the switches of [Bridges], published by the engine whenever it reads settings.ini (single
    words: the game thread reads them in ZS_Frame) }
  BridgeWantHook: LongInt = 1;
  BridgeWantMemory: LongInt = 1;
  { 1 = the engine has the walls of the map that runs ([Bridges] MapGeometry): main.pas casts no
    Map.RayCast for a kill (published by the engine thread, a single word) }
  BridgeGeoReady: LongInt = 0;

{ once a tick, first thing: the mask of the humans followed here (bit = slot - 1) }
function BridgeFrame(Tick: LongInt): LongInt;
{ the soldier of a slot from the script's player object }
function BridgeBind(Slot: LongInt; Obj: Pointer; X, Y: Single): LongInt;
{ a script start (ZS_Init): the engine may be a new one - the state is told again at the next
  frame, and the slots start empty (main.pas sends a join for everybody on the server) }
procedure BridgeReset;
{ what the exports of the old events tell the bridge, so its picture of the slots stays right }
procedure BridgeJoin(Slot, Human: LongInt);
procedure BridgeLeave(Slot: LongInt);
procedure BridgeRestart(Slot: LongInt);
procedure BridgeWeapon(Slot, W, A: LongInt);
procedure BridgeMapChange;
{ a hit / a kill read from memory into E; False = not readable (the script sends the full event) }
function BridgeHit(Shooter, Victim, BulletId, Tick: LongInt; Damage: Single; var E: TZSEvent): Boolean;
function BridgeDeath(Killer, Victim, BulletId, Flags, Tick: LongInt; var E: TZSEvent): Boolean;
{ what the hooks and the bullet's record add to an event the script sent itself (the old exports):
  the zone of the hit, where and when the bullet was fired, whether it was a script's }
procedure BridgeAddToDamage(var E: TZSEvent);
procedure BridgeAddToKill(var E: TZSEvent);
{ the health a medical, berserker or predator kit gave (memory), False = not followed here }
function BridgeKitHeal(Slot, Style: LongInt; out Heal: Single): Boolean;
{ the once-a-second check against the properties (see MemCheck) }
function BridgeCheck(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys: LongInt; X, Y, Health, Vest: Single): LongInt;
{ 1 = the CreateBullet hook is in place, 2 = the soldiers are read from memory, 4 = the HealthHit hook,
  8 = the engine has the map's walls }
function BridgeState: LongInt;
{ the end of the script's tick (ZS_Action_Begin): its length is measured from ZS_Frame }
procedure BridgeTickEnd;
{ the script stops (ZS_Shutdown): the bullets the hook saw since the last frame go to the engine
  before the hook is taken out }
procedure BridgeDrainShots;
{ the lines of /zs_perf about the bridges (taken under a lock: the engine thread reads them) }
function BridgeStatus: AnsiString;
{ the zone of the body a part number of the server's hit test belongs to (HZ_*): its own rule -
  Where <= 4 the legs, <= 11 the chest, else the head; 0 or less = none }
function ZoneOfWhere(Where: LongInt): LongInt;

implementation

uses
  SysUtils, zs_util, zs_mem, zs_hook;

const
  SAMPLE_TICKS = 12;
  WEP_KNIFE_NUM = 11;
  WEP_NONE_NUM = 255;
  KIT_MEDICAL = 16;
  KIT_PREDATOR = 19;
  KIT_BERSERK = 21;
  { the bullet styles whose hits have a zone }
  ST_PLAIN = 1;
  ST_SHOTGUN = 3;
  ST_ARROW = 7;
  ST_M2 = 14;
  { at most this many shot events a tick (players x weapons x stances) }
  AGG_MAX = 96;

type
  TBridgeSlot = record
    InGame, Human: Boolean;
    LastW, LastA, LastGren: LongInt;
    LastHealth: Single;
    { the bots: alive as last told (-1 = not told yet) }
    BotAlive: LongInt;
  end;

  { what ZS_Ev_Hit found out about the bullet that hit a victim, for the kill that may follow in
    the same tick (another script's OnDamage may make bullets in the meantime) }
  THitSnap = record
    Tick, Bullet, Shooter, W: LongInt;
    Ours, Origin: Boolean;
    OX, OY: Single;
    OTick, Stance: LongInt;
    BVX, BVY: Single;
  end;

  TAgg = record
    Owner, W, Kind, Stance, Count: LongInt;
    Tick: LongInt;
    X, Y: Single;
  end;

var
  G: array[1..32] of TBridgeSlot;
  Snap: array[1..32] of THitSnap;
  { Game.TickCount - MainTickCounter, measured every frame }
  TickOff: LongInt = 0;
  TickOffKnown: Boolean = False;
  LastState: LongInt = -1;
  FrameStartUs: Int64 = 0;
  TickRuns: Int64 = 0;
  TickUs: Int64 = 0;
  TickMaxUs: Int64 = 0;
  FrameUs: Int64 = 0;
  CntHits: Int64 = 0;
  CntDeaths: Int64 = 0;
  CntFallback: Int64 = 0;
  CntZones: Int64 = 0;
  CntScriptHits: Int64 = 0;
  StatusLock: TRTLCriticalSection;
  StatusText: AnsiString = '';
  StatusTick: LongInt = -1000;
  Agg: array[0..AGG_MAX - 1] of TAgg;
  AggN: LongInt = 0;
  { the humans the last frame followed (bit = slot - 1) }
  LastMask: LongInt = 0;
  { the soldiers were read in the last frame }
  MemWasReady: Boolean = False;
  { the server's tick was looked for without the hook (once) }
  LocateTried: Boolean = False;

function MakeEvent(Kind: TZSEventKind): TZSEvent;
begin
  Result.Kind := Kind;
  Result.Tick := 0;
  Result.Slot := 0;
  Result.Slot2 := 0;
  Result.Serial := 0;
  Result.Serial2 := 0;
  FillChar(Result.I, SizeOf(Result.I), 0);
  FillChar(Result.F, SizeOf(Result.F), 0);
  Result.S1 := '';
  Result.S2 := '';
  Result.S3 := '';
  Result.S4 := '';
end;

procedure Push(var E: TZSEvent);
begin
  if Assigned(BridgePush) then
    BridgePush(E);
end;

function SlotOk(S: LongInt): Boolean; inline;
begin
  Result := (S >= 1) and (S <= 32);
end;

function Bits(B: LongWord): Single; inline;
begin
  Result := PSingle(@B)^;
end;

function ZoneOfWhere(Where: LongInt): LongInt;
begin
  if Where <= 0 then
    Result := HZ_UNKNOWN
  else if Where <= 4 then
    Result := HZ_LEGS
  else if Where <= 11 then
    Result := HZ_BODY
  else
    Result := HZ_HEAD;
end;

{ how one stood: in the air, lying, crouching, standing - in that order (-1 = not known) }
function PostureAt(Stance: LongInt; Ground: Boolean): LongInt;
begin
  if Stance = 0 then
    Result := -1
  else if not Ground then
    Result := POSTURE_AIR
  else if Stance = STANCE_PRONE then
    Result := POSTURE_PRONE
  else if Stance = STANCE_CROUCH then
    Result := POSTURE_CROUCH
  else
    Result := POSTURE_STAND;
end;

{ ---------------- the slots ---------------- }

procedure ResetSlot(S: LongInt);
begin
  G[S].LastW := -1;
  G[S].LastA := 0;
  G[S].LastGren := 0;
  G[S].LastHealth := -1;
end;

procedure BridgeJoin(Slot, Human: LongInt);
begin
  if not SlotOk(Slot) then
    Exit;
  G[Slot].InGame := True;
  G[Slot].Human := Human <> 0;
  G[Slot].BotAlive := -1;
  Snap[Slot].Tick := -1;
  ResetSlot(Slot);
end;

procedure BridgeLeave(Slot: LongInt);
begin
  if not SlotOk(Slot) then
    Exit;
  G[Slot].InGame := False;
  G[Slot].Human := False;
  G[Slot].BotAlive := -1;
  Snap[Slot].Tick := -1;
  ResetSlot(Slot);
end;

procedure BridgeRestart(Slot: LongInt);
begin
  if SlotOk(Slot) then
    ResetSlot(Slot);
end;

{ main.pas's HandleWeaponChange: the weapon the player has from now on }
procedure BridgeWeapon(Slot, W, A: LongInt);
begin
  if not SlotOk(Slot) then
    Exit;
  if G[Slot].LastW >= 0 then
  begin
    G[Slot].LastW := W;
    G[Slot].LastA := A;
  end;
end;

{ R3: the engine takes every life for ended at a map start, and a bot sends no spawn - its life is
  told again at the next frame }
procedure BridgeMapChange;
var
  S: LongInt;
begin
  for S := 1 to 32 do
  begin
    ResetSlot(S);
    Snap[S].Tick := -1;
    G[S].BotAlive := -1;
  end;
end;

procedure BridgeReset;
var
  S: LongInt;
begin
  LastState := -1;
  LastMask := 0;
  AggN := 0;
  for S := 1 to 32 do
  begin
    G[S].InGame := False;
    G[S].Human := False;
    G[S].BotAlive := -1;
    ResetSlot(S);
    Snap[S].Tick := -1;
  end;
end;

function BridgeBind(Slot: LongInt; Obj: Pointer; X, Y: Single): LongInt;
begin
  Result := 0;
  try
    if not SlotOk(Slot) then
      Exit;
    if BridgeWantMemory = 0 then
      Exit;
    Result := MemBind(Slot, Obj, X, Y);
  except
    Result := 0;
  end;
end;

{ ---------------- the frame ---------------- }

function ScriptTick(ServerTick: LongInt): LongInt;
begin
  Result := ServerTick + TickOff;
end;

procedure FlushAgg;
var
  k: LongInt;
  E: TZSEvent;
begin
  for k := 0 to AggN - 1 do
  begin
    E := MakeEvent(zeBullet);
    E.Tick := Agg[k].Tick;
    E.Slot := Agg[k].Owner;
    E.I[0] := Agg[k].W;
    E.I[1] := Agg[k].Count;
    E.I[2] := Agg[k].Kind;
    E.I[3] := Agg[k].Stance;
    E.F[0] := Agg[k].X;
    E.F[1] := Agg[k].Y;
    Push(E);
  end;
  AggN := 0;
end;

{ the bullets the hook saw since the last look, added up per player, weapon, kind and stance }
procedure DrainShots;
var
  S: TShotRec;
  k, Pos: LongInt;
begin
  AggN := 0;
  while HookNext(S) do
  begin
    if not SlotOk(S.Owner) then
      Continue;
    Pos := PostureAt(S.Stance, S.Ground <> 0);
    k := 0;
    while (k < AggN) and not ((Agg[k].Owner = S.Owner) and (Agg[k].W = S.W) and (Agg[k].Kind = S.Kind) and
      (Agg[k].Stance = Pos)) do
      Inc(k);
    if k < AggN then
      Inc(Agg[k].Count)
    else
    begin
      if AggN >= AGG_MAX then
        FlushAgg;
      k := AggN;
      Agg[k].Owner := S.Owner;
      Agg[k].W := S.W;
      Agg[k].Kind := S.Kind;
      Agg[k].Stance := Pos;
      Agg[k].Count := 1;
      Agg[k].Tick := ScriptTick(S.Tick);
      Agg[k].X := Bits(S.XB);
      Agg[k].Y := Bits(S.YB);
      Inc(AggN);
    end;
  end;
  FlushAgg;
end;

function StanceFlags(const S: TMemSoldier; FlaggerBit, ProneBit, GroundBit, CrouchBit: LongInt): LongInt;
begin
  Result := 0;
  if (S.Holded > 0) and (S.Holded < 4) then
    Result := Result or FlaggerBit;
  if S.Stance = STANCE_PRONE then
    Result := Result or ProneBit;
  if S.OnGround then
    Result := Result or GroundBit;
  { the crouch key, as Player.KeyCrouch (the hit model's posture reads the key) }
  if S.Keys and MK_CROUCH <> 0 then
    Result := Result or CrouchBit;
end;

procedure FollowHuman(Slot, Tick: LongInt; Hook: Boolean; var Mask: LongInt);
var
  S: TMemSoldier;
  E: TZSEvent;
begin
  if not MemRead(Slot, S) then
    Exit;
  Mask := Mask or LongInt(LongWord(1) shl (Slot - 1));
  if (not S.Active) or (S.Team = TEAM_SPEC) or not S.Alive then
  begin
    G[Slot].LastW := -1;
    G[Slot].LastHealth := -1;
    Exit;
  end;
  G[Slot].LastHealth := S.Health;
  if G[Slot].LastW >= 0 then
  begin
    if (S.W = G[Slot].LastW) and (S.A <> G[Slot].LastA) and (S.W <> WEP_KNIFE_NUM) and (S.W <> WEP_NONE_NUM) then
    begin
      E := MakeEvent(zeAmmo);
      E.Tick := Tick;
      E.Slot := Slot;
      E.I[0] := S.W;
      E.I[1] := G[Slot].LastA;
      E.I[2] := S.A;
      if (S.A = 0) and (S.Keys and MK_RELOAD <> 0) then
        E.I[3] := 1;
      E.F[0] := S.X;
      E.F[1] := S.Y;
      Push(E);
    end;
    { without the hook the grenades are read from their count }
    if (not Hook) and (S.Gren < G[Slot].LastGren) then
    begin
      E := MakeEvent(zeGrenade);
      E.Tick := Tick;
      E.Slot := Slot;
      E.I[0] := G[Slot].LastGren - S.Gren;
      E.F[0] := S.X;
      E.F[1] := S.Y;
      Push(E);
    end;
  end;
  G[Slot].LastW := S.W;
  G[Slot].LastA := S.A;
  G[Slot].LastGren := S.Gren;
  if (Tick + Slot) mod SAMPLE_TICKS = 0 then
  begin
    E := MakeEvent(zeSample);
    E.Tick := Tick;
    E.Slot := Slot;
    E.I[0] := StanceFlags(S, EF_A_FLAGGER, EF_A_PRONE, EF_A_ONGROUND, EF_A_CROUCH) or EF_A_ALIVE;
    E.I[1] := S.W;
    E.I[2] := S.A;
    E.I[3] := S.Jets;
    E.F[0] := S.X;
    E.F[1] := S.Y;
    Push(E);
  end;
end;

{ a bot's life as the server has it, told when it changes (bots send no spawn, and a bot killed by
  a bot sends no kill) }
procedure WatchBot(Slot, Tick: LongInt);
var
  Alive: Boolean;
  A: LongInt;
  E: TZSEvent;
  X, Y: Single;
begin
  if not MemAlive(Slot, Alive) then
    Exit;
  A := Ord(Alive);
  if A = G[Slot].BotAlive then
    Exit;
  G[Slot].BotAlive := A;
  E := MakeEvent(zeLife);
  E.Tick := Tick;
  E.Slot := Slot;
  E.I[0] := A;
  if MemPos(Slot, X, Y) then
  begin
    E.F[0] := X;
    E.F[1] := Y;
  end;
  Push(E);
end;

procedure TellState(St: LongInt; Tick: LongInt);
var
  E: TZSEvent;
  S: LongInt;
begin
  if St = LastState then
    Exit;
  E := MakeEvent(zeBridge);
  { one line for the server's console (the engine writes it when the hooks or the reading change) }
  E.S1 := 'hooks: ' + HookWhy + '; memory: ' + MemInfo;
  { the memory reading went off: the bots' lives told so far are forgotten (the engine counts the
    bots as standing again) }
  if (St and 2) = 0 then
    for S := 1 to 32 do
      G[S].BotAlive := -1;
  LastState := St;
  E.Tick := Tick;
  E.I[0] := St;
  Push(E);
end;

function BridgeState: LongInt;
begin
  Result := 0;
  if HookInstalled then
    Result := Result or 1;
  if MemReady then
    Result := Result or 2;
  if HitHookInstalled then
    Result := Result or 4;
  if BridgeGeoReady <> 0 then
    Result := Result or 8;
end;

procedure UpdateStatus;
var
  T: AnsiString;
begin
  T := 'hook ' + HookInfo;
  T := T + #10 + 'memory: ' + MemInfo;
  if TickOffKnown and (TickOff <> 0) then
    T := T + ' (script tick = server tick + ' + IntToStr(TickOff) + ')';
  T := T + #10 + Format('read from memory: %d hits, %d kills; from the script: %d', [CntHits, CntDeaths, CntFallback]);
  T := T + #10 + Format('zones from the server: %d; hits of scripts'' bullets: %d', [CntZones, CntScriptHits]);
  if TickRuns > 0 then
  begin
    T := T + #10 + Format('script tick: %d us on average, %d us at most, %d ticks', [TickUs div TickRuns, TickMaxUs,
      TickRuns]);
    T := T + #10 + Format('library frame: %d us on average', [FrameUs div TickRuns]);
  end;
  EnterCriticalSection(StatusLock);
  try
    StatusText := T;
  finally
    LeaveCriticalSection(StatusLock);
  end;
end;

function BridgeStatus: AnsiString;
begin
  EnterCriticalSection(StatusLock);
  try
    Result := StatusText;
    UniqueString(Result);
  finally
    LeaveCriticalSection(StatusLock);
  end;
end;

function BridgeFrame(Tick: LongInt): LongInt;
var
  S, ST: LongInt;
  Hook, Mem: Boolean;
begin
  Result := 0;
  FrameStartUs := MicroNow;
  try
    { the switches of settings.ini, applied here: the server's code is patched only on this thread }
    MemSetWanted(BridgeWantMemory <> 0);
    if BridgeWantHook <> 0 then
    begin
      if not HookCheck then
        HookInstall
      else if not HitHookInstalled then
        HookInstall;
    end
    else if HookInstalled or HitHookInstalled then
    begin
      { the bullets of the last tick still count: the ammunition of this frame does not count them
        again (the engine hears that the hook is out after them) }
      if HookInstalled then
        DrainShots;
      HookRemove;
    end;
    Hook := HookInstalled;
    Mem := MemReady;
    { the reading back on: what the slots held from before it went off is forgotten }
    if Mem and not MemWasReady then
      for S := 1 to 32 do
        ResetSlot(S);
    MemWasReady := Mem;
    { the server's tick is found where the CreateBullet hook goes: without the hook (ServerHook = 0)
      that place is looked for once, and nothing is patched }
    if Mem and (MemServerTick < 0) and not LocateTried then
    begin
      LocateTried := True;
      HookLocateOnly;
    end;
    ST := MemServerTick;
    if ST >= 0 then
    begin
      TickOff := Tick - ST;
      TickOffKnown := True;
    end;
    if Mem then
      HookSoldiers(MemSpriteBase)
    else
      HookSoldiers(0);
    if Hook then
      DrainShots;
    if Mem then
      for S := 1 to 32 do
        if G[S].InGame then
        begin
          if G[S].Human then
            FollowHuman(S, Tick, Hook, Result)
          else if MemBound(S) then
            WatchBot(S, Tick);
        end;
    TellState(BridgeState, Tick);
    LastMask := Result;
    if Tick - StatusTick >= 60 then
    begin
      StatusTick := Tick;
      UpdateStatus;
    end;
  except
    Result := 0;
    LastMask := 0;
  end;
  Inc(FrameUs, MicroNow - FrameStartUs);
end;

procedure BridgeTickEnd;
var
  D: Int64;
begin
  if FrameStartUs = 0 then
    Exit;
  D := MicroNow - FrameStartUs;
  FrameStartUs := 0;
  if (D < 0) or (D > 1000000) then
    Exit;
  Inc(TickRuns);
  Inc(TickUs, D);
  if D > TickMaxUs then
    TickMaxUs := D;
end;

procedure BridgeDrainShots;
begin
  try
    if HookInstalled then
      DrainShots;
  except
    AggN := 0;
  end;
end;

{ ---------------- hits and kills ---------------- }

{ The bullet of a hit by Shooter: its weapon (WEP_WORLD when the bullet is not his - a fall, a
  script's Player.Damage, lava), whether it still flies (its place and speed describe the hit),
  whether the hook saw it made (else a script made it: no shot of his), and where, when and how he
  stood when it was fired. Read whatever its Active says: an M79 or LAW is taken out before its
  direct hit. }
procedure BulletOf(BulletId, Shooter: LongInt; out W: LongInt; out Valid, Ours, Origin: Boolean; out OX, OY: Single;
  out OTick, Stance: LongInt);
var
  Act, St, Own, Wn, T: LongInt;
  Sh: TShadow;
  X, Y: Single;
begin
  W := WEP_WORLD;
  Valid := False;
  Ours := False;
  Origin := False;
  OX := 0;
  OY := 0;
  OTick := 0;
  Stance := -1;
  if (BulletId < 1) or (BulletId > 254) then
    Exit;
  if not MemBullet(BulletId, Act, St, Own, Wn) then
    Exit;
  if Own <> Shooter then
    Exit;
  W := Wn;
  Valid := Act = 1;
  if MemBulletOrigin(BulletId, X, Y, T) and TickOffKnown then
  begin
    Origin := True;
    OX := X;
    OY := Y;
    OTick := ScriptTick(T);
  end;
  if HookShadow(BulletId, Sh) then
    if (Sh.Owner = Own) and (Sh.Tick = T) and (Sh.XB = PLongWord(@X)^) and (Sh.YB = PLongWord(@Y)^) then
    begin
      Ours := True;
      Stance := PostureAt(Sh.Stance, Sh.Ground <> 0);
    end;
end;

{ the server's own hit test for this hit (HealthHit): the zone, and whether the damage is a script's
  Player.Damage (Where 1, What 1 and no push; a blast of the bullet in slot 1 has the same numbers but
  pushes) - then it is no bullet of anybody's }
procedure HitOf(Shooter, Victim, BulletId: LongInt; out Zone: LongInt; out ScriptDamage: Boolean);
var
  H: THitRec;
begin
  Zone := HZ_UNKNOWN;
  ScriptDamage := False;
  if not HookTakeHit(Victim, H) then
    Exit;
  if (H.Who <> Shooter) or (H.What <> BulletId) then
    Exit;
  if (H.Where = 1) and (H.What = 1) and (H.Push = 0) then
  begin
    ScriptDamage := True;
    Exit;
  end;
  Zone := ZoneOfWhere(H.Where);
end;

function ReadHit(Shooter, Victim, BulletId, Tick: LongInt; Damage: Single; var E: TZSEvent): Boolean;
var
  SS, VS: TMemSoldier;
  W, Zone, OTick, Stance, Act, Style, Own, Wn: LongInt;
  Valid, Ours, Origin, ScriptDamage: Boolean;
  BX, BY, BVX, BVY, OX, OY: Single;
begin
  Result := False;
  try
    if not (SlotOk(Shooter) and SlotOk(Victim)) then
      Exit;
    if not (MemRead(Shooter, SS) and MemRead(Victim, VS)) then
      Exit;
    { the shots of this tick come before their hits }
    if HookInstalled then
      DrainShots;
    E := MakeEvent(zeDamage);
    E.Tick := Tick;
    E.Slot := Shooter;
    E.Slot2 := Victim;
    BulletOf(BulletId, Shooter, W, Valid, Ours, Origin, OX, OY, OTick, Stance);
    HitOf(Shooter, Victim, BulletId, Zone, ScriptDamage);
    if ScriptDamage then
    begin
      W := WEP_WORLD;
      Valid := False;
      Origin := False;
      Ours := False;
    end;
    E.I[0] := BulletId;
    E.I[1] := W;
    E.I[2] := StanceFlags(SS, EF_A_FLAGGER, EF_A_PRONE, EF_A_ONGROUND, EF_A_CROUCH) or
      StanceFlags(VS, EF_B_FLAGGER, EF_B_PRONE, EF_B_ONGROUND, EF_B_CROUCH) or EF_MEMORY;
    if SS.Alive then
      E.I[2] := E.I[2] or EF_A_ALIVE;
    E.I[3] := HZ_UNKNOWN;
    E.I[5] := -1;
    BX := 0;
    BY := 0;
    BVX := 0;
    BVY := 0;
    if Valid and MemBulletPos(BulletId, BX, BY, BVX, BVY) then
      E.I[2] := E.I[2] or EF_BULLET;
    if Origin then
    begin
      E.I[2] := E.I[2] or EF_ORIGIN;
      E.I[4] := OTick;
      E.F[13] := OX;
      E.F[14] := OY;
    end;
    if W <> WEP_WORLD then
    begin
      if HookInstalled and not Ours then
      begin
        E.I[2] := E.I[2] or EF_SCRIPT_BULLET;
        Inc(CntScriptHits);
      end;
      { the zone of the bullets that have one, as the server chose it }
      if (Zone <> HZ_UNKNOWN) and MemBullet(BulletId, Act, Style, Own, Wn) then
        if (Style = ST_PLAIN) or (Style = ST_SHOTGUN) or (Style = ST_ARROW) or (Style = ST_M2) then
        begin
          E.I[3] := Zone;
          E.I[2] := E.I[2] or EF_ZONE;
          Inc(CntZones);
        end;
      { how he stood when he fired it (the hook), else how he stands now }
      if Stance >= 0 then
        E.I[5] := Stance
      else if Ours or not HookInstalled then
        E.I[5] := PostureAt(SS.Stance, SS.OnGround);
    end;
    E.F[0] := Damage;
    E.F[1] := VS.Vest;
    E.F[2] := BX;
    E.F[3] := BY;
    E.F[4] := BVX;
    E.F[5] := BVY;
    E.F[6] := VS.X;
    E.F[7] := VS.Y;
    E.F[8] := VS.Health;
    E.F[9] := VS.VX;
    E.F[10] := VS.VY;
    E.F[11] := SS.VX;
    E.F[12] := SS.VY;
    { for the kill that may follow }
    Snap[Victim].Tick := Tick;
    Snap[Victim].Bullet := BulletId;
    Snap[Victim].Shooter := Shooter;
    Snap[Victim].W := W;
    Snap[Victim].Ours := Ours and not ScriptDamage;
    Snap[Victim].Origin := Origin;
    Snap[Victim].OX := OX;
    Snap[Victim].OY := OY;
    Snap[Victim].OTick := OTick;
    Snap[Victim].Stance := E.I[5];
    Snap[Victim].BVX := BVX;
    Snap[Victim].BVY := BVY;
    Inc(CntHits);
    Result := True;
  except
    Result := False;
  end;
end;

function BridgeHit(Shooter, Victim, BulletId, Tick: LongInt; Damage: Single; var E: TZSEvent): Boolean;
begin
  Result := ReadHit(Shooter, Victim, BulletId, Tick, Damage, E);
  if not Result then
    Inc(CntFallback);
end;

{ the kill's bullet: the hit a moment ago when it is that bullet's, else its record now }
procedure KillBullet(Killer, Victim, BulletId, Tick: LongInt; var E: TZSEvent; out W: LongInt; out Valid: Boolean;
  out BVX, BVY: Single);
var
  Ours, Origin: Boolean;
  OX, OY, BX, BY: Single;
  OTick, Stance: LongInt;
begin
  BulletOf(BulletId, Killer, W, Valid, Ours, Origin, OX, OY, OTick, Stance);
  BVX := 0;
  BVY := 0;
  if (Snap[Victim].Tick = Tick) and (Snap[Victim].Bullet = BulletId) and (Snap[Victim].Shooter = Killer) then
  begin
    { the slot may hold another bullet by now (a script made one in its OnDamage): the hit knew }
    W := Snap[Victim].W;
    Ours := Snap[Victim].Ours;
    Origin := Snap[Victim].Origin;
    OX := Snap[Victim].OX;
    OY := Snap[Victim].OY;
    OTick := Snap[Victim].OTick;
    Stance := Snap[Victim].Stance;
    BVX := Snap[Victim].BVX;
    BVY := Snap[Victim].BVY;
  end
  else if Valid then
    MemBulletPos(BulletId, BX, BY, BVX, BVY);
  if Origin and (W <> WEP_WORLD) then
  begin
    E.I[2] := E.I[2] or EF_ORIGIN;
    E.I[4] := OTick;
    E.F[7] := OX;
    E.F[8] := OY;
  end;
  if (W <> WEP_WORLD) and HookInstalled and not Ours then
    E.I[2] := E.I[2] or EF_SCRIPT_BULLET;
  E.I[6] := Stance;
  E.F[17] := BVX;
  E.F[18] := BVY;
end;

function ReadDeath(Killer, Victim, BulletId, Flags, Tick: LongInt; var E: TZSEvent): Boolean;
var
  KS, VS: TMemSoldier;
  W: LongInt;
  Valid: Boolean;
  BX, BY, BVX, BVY, PX, PY: Single;
  Pts: LongInt;
begin
  Result := False;
  try
    if not (SlotOk(Killer) and SlotOk(Victim)) then
      Exit;
    if not (MemRead(Killer, KS) and MemRead(Victim, VS)) then
      Exit;
    if HookInstalled then
      DrainShots;
    E := MakeEvent(zeKill);
    E.Tick := Tick;
    E.Slot := Killer;
    E.Slot2 := Victim;
    E.I[2] := StanceFlags(KS, EF_A_FLAGGER, EF_A_PRONE, EF_A_ONGROUND, EF_A_CROUCH) or
      StanceFlags(VS, EF_B_FLAGGER, EF_B_PRONE, EF_B_ONGROUND, EF_B_CROUCH) or EF_MEMORY or
      (Flags and (EF_SERVER_KILL or EF_LOS or EF_RAY_RAW or EF_RAY_CAL));
    KillBullet(Killer, Victim, BulletId, Tick, E, W, Valid, BVX, BVY);
    E.I[0] := BulletId;
    E.I[1] := W;
    if KS.Alive then
      E.I[2] := E.I[2] or EF_A_ALIVE;
    E.I[3] := VS.W;
    E.I[5] := VS.Direction;
    BX := 0;
    BY := 0;
    if Valid and MemBulletPos(BulletId, BX, BY, PX, PY) then
      E.I[2] := E.I[2] or EF_BULLET;
    E.F[0] := KS.X;
    E.F[1] := KS.Y;
    E.F[2] := VS.X;
    E.F[3] := VS.Y;
    E.F[4] := BX;
    E.F[5] := BY;
    E.F[6] := VS.Vest;
    { the points of the line of sight: the killer's eyes, the victim's head, chest and hips }
    Pts := 0;
    if MemEyes(Killer, PX, PY) then
    begin
      E.F[9] := PX;
      E.F[10] := PY;
      Inc(Pts);
    end;
    if MemPoint(Victim, 12, PX, PY) then
    begin
      E.F[11] := PX;
      E.F[12] := PY;
      Inc(Pts);
    end;
    if MemPoint(Victim, 7, PX, PY) then
    begin
      E.F[13] := PX;
      E.F[14] := PY;
      Inc(Pts);
    end;
    if MemPoint(Victim, 5, PX, PY) then
    begin
      E.F[15] := PX;
      E.F[16] := PY;
      Inc(Pts);
    end;
    if Pts = 4 then
      E.I[2] := E.I[2] or EF_POINTS;
    Snap[Victim].Tick := -1;
    Inc(CntDeaths);
    Result := True;
  except
    Result := False;
  end;
end;

function BridgeDeath(Killer, Victim, BulletId, Flags, Tick: LongInt; var E: TZSEvent): Boolean;
begin
  Result := ReadDeath(Killer, Victim, BulletId, Flags, Tick, E);
  if not Result then
    Inc(CntFallback);
end;

{ the script's full damage event (no memory reading for these players): the hooks still tell the
  zone and the shot, the bullet's record the origin }
procedure BridgeAddToDamage(var E: TZSEvent);
var
  W, Zone, OTick, Stance, Act, Style, Own, Wn: LongInt;
  Valid, Ours, Origin, ScriptDamage: Boolean;
  OX, OY: Single;
begin
  try
    if not (SlotOk(E.Slot) and SlotOk(E.Slot2)) then
      Exit;
    if HookInstalled then
      DrainShots;
    HitOf(E.Slot, E.Slot2, E.I[0], Zone, ScriptDamage);
    if ScriptDamage then
    begin
      E.I[1] := WEP_WORLD;
      E.I[2] := E.I[2] and not EF_BULLET;
      Exit;
    end;
    if E.I[1] = WEP_WORLD then
      Exit;
    if MemTablesOk then
    begin
      BulletOf(E.I[0], E.Slot, W, Valid, Ours, Origin, OX, OY, OTick, Stance);
      if Origin and (BridgeWantMemory <> 0) then
      begin
        E.I[2] := E.I[2] or EF_ORIGIN;
        E.I[4] := OTick;
        E.F[13] := OX;
        E.F[14] := OY;
      end;
      if HookInstalled and not Ours then
        E.I[2] := E.I[2] or EF_SCRIPT_BULLET;
      if (Zone <> HZ_UNKNOWN) and MemBullet(E.I[0], Act, Style, Own, Wn) then
        if (Style = ST_PLAIN) or (Style = ST_SHOTGUN) or (Style = ST_ARROW) or (Style = ST_M2) then
        begin
          E.I[3] := Zone;
          E.I[2] := E.I[2] or EF_ZONE;
          Inc(CntZones);
        end;
    end;
  except
  end;
end;

procedure BridgeAddToKill(var E: TZSEvent);
var
  W: LongInt;
  Valid: Boolean;
  BVX, BVY: Single;
begin
  try
    if not (SlotOk(E.Slot) and SlotOk(E.Slot2)) then
      Exit;
    if not MemTablesOk or (BridgeWantMemory = 0) or (E.I[1] = WEP_WORLD) then
      Exit;
    if HookInstalled then
      DrainShots;
    KillBullet(E.Slot, E.Slot2, E.I[0], E.Tick, E, W, Valid, BVX, BVY);
  except
  end;
end;

function BridgeKitHeal(Slot, Style: LongInt; out Heal: Single): Boolean;
var
  H: Single;
begin
  Result := False;
  Heal := 0;
  if not SlotOk(Slot) then
    Exit;
  if not (G[Slot].InGame and G[Slot].Human) or ((LastMask shr (Slot - 1)) and 1 = 0) then
    Exit;
  if not MemHealth(Slot, H) then
    Exit;
  if HookInstalled then
    DrainShots;
  Result := True;
  if (Style = KIT_MEDICAL) or (Style = KIT_BERSERK) or (Style = KIT_PREDATOR) then
    if (G[Slot].LastHealth >= 0) and (H > G[Slot].LastHealth) then
      Heal := H - G[Slot].LastHealth;
  G[Slot].LastHealth := H;
end;

function BridgeCheck(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys: LongInt; X, Y, Health, Vest: Single): LongInt;
begin
  Result := MemCheck(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys, X, Y, Health, Vest);
end;

var
  k: LongInt;

initialization
  InitCriticalSection(StatusLock);
  for k := 1 to 32 do
  begin
    G[k].InGame := False;
    G[k].Human := False;
    G[k].BotAlive := -1;
    G[k].LastW := -1;
    G[k].LastHealth := -1;
    Snap[k].Tick := -1;
  end;

finalization
  DoneCriticalSection(StatusLock);
end.
