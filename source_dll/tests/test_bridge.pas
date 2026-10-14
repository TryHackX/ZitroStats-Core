program test_bridge;

{ [Bridges] (5.6) in the engine: what the events of the server's hooks and memory make of the
  statistics, without a server - the bullets of the hook (shots, throws, the stance), the script's
  shots ignored while the hook runs, the zone the server's hit test chose, the bullets of scripts,
  the kills read from memory (the distance from where the bullet was made, a second victim of one
  bullet, a kill from behind, the longest headshot and bullet flight), the state line for the
  console, the bots' lives in survival rounds, and the zone of a part number of the server. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_weapons, zs_engine, zs_bridge, zs_matrix;

const
  ALIVE = EF_A_ALIVE or EF_A_ONGROUND or EF_B_ONGROUND;
  B_ALL = 1 or 2 or 4;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console, L: TStringList;

procedure Check(const Name: string; Ok: Boolean);
begin
  if Ok then
    WriteLn('[ OK ] ', Name)
  else
  begin
    WriteLn('[FAIL] ', Name);
    Inc(Failures);
  end;
end;

procedure DeleteTree(const Dir: AnsiString);
var
  SR: TSearchRec;
  P: AnsiString;
begin
  if not DirectoryExists(Dir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure Push(Ev: TZSEvent);
begin
  Ev.Tick := CurTick;
  Engine.PushEvent(Ev);
  Inc(Pushed);
end;

function WaitProcessed: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while Engine.Processed < Pushed do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(2);
  end;
  Result := True;
end;

function WaitReady: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not Engine.IsReady do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Result := True;
end;

procedure DrainActions;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    Console.Add(Format('%d|%d|%s', [A.Kind, A.Slot, A.Text]));
end;

function ConsoleHas(const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  WaitProcessed;
  DrainActions;
  for k := 0 to Console.Count - 1 do
    if Pos(Part, Console[k]) > 0 then
      Exit(True);
  Result := False;
end;

procedure MapAfter(const Name: AnsiString; Style, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := 10;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := 'HW' + Steam;
  Ev.S4 := '10.0.0.' + IntToStr(Slot);
  Ev.I[0] := Team;
  Ev.I[1] := 1;
  Push(Ev);
end;

procedure JoinBot(Slot: LongInt; const Name: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.I[0] := Team;
  Push(Ev);
end;

procedure LeaveEv(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(Ev);
end;

procedure Spawn(Slot, Weapon: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSpawn);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := WEP_SOCOM;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ what ZS_Frame tells: the hooks and the reading (bits 1, 2, 4), with the console's line }
procedure BridgeEv(State: LongInt; const Text: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeBridge);
  Ev.I[0] := State;
  Ev.S1 := Text;
  Push(Ev);
end;

{ a bot came to life (1) or died (0), read from its record }
procedure LifeEv(Slot, Alive: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLife);
  Ev.Slot := Slot;
  Ev.I[0] := Alive;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ bullets of the hook, added up: Kind 1 a shot, 2 a throw; Posture POSTURE_* or -1 }
procedure BulletEv(Slot, Weapon, Count, Kind, Posture: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeBullet);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := Count;
  Ev.I[2] := Kind;
  Ev.I[3] := Posture;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ a shot as main.pas sees it from the ammunition }
procedure ShotEv(Slot, Weapon: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeShot);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := 1;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ a hit: Flags as ZS_Ev_Hit reads them (EF_MEMORY ...) or as main.pas sends them; Zone the server's
  (EF_ZONE), Posture how the shooter stood when he fired, the bullet made at OX, OY at OTick }
procedure HitEv(S, V, Bullet, Weapon, Flags, Zone, Posture, OTick: LongInt; Dmg, BX, BY, BVX, BVY, VX, VY, Health,
  OX, OY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeDamage);
  Ev.Slot := S;
  Ev.Slot2 := V;
  Ev.I[0] := Bullet;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags;
  Ev.I[3] := Zone;
  Ev.I[4] := OTick;
  Ev.I[5] := Posture;
  Ev.F[0] := Dmg;
  Ev.F[2] := BX;
  Ev.F[3] := BY;
  Ev.F[4] := BVX;
  Ev.F[5] := BVY;
  Ev.F[6] := VX;
  Ev.F[7] := VY;
  Ev.F[8] := Health;
  Ev.F[13] := OX;
  Ev.F[14] := OY;
  Push(Ev);
end;

{ a kill as ZS_Ev_Death reads it: the bullet at BX, BY flying BVX, BVY, made at OX, OY at OTick; Dir
  the victim's direction (1 right, -1 left) }
procedure KillEv(K, V, Bullet, Weapon, Flags, OTick, Dir: LongInt; KX, KY, VX, VY, BX, BY, OX, OY, BVX, BVY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := Bullet;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags;
  Ev.I[3] := WEP_AK74;
  Ev.I[4] := OTick;
  Ev.I[5] := Dir;
  Ev.I[6] := -1;
  Ev.F[0] := KX;
  Ev.F[1] := KY;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Ev.F[4] := BX;
  Ev.F[5] := BY;
  Ev.F[7] := OX;
  Ev.F[8] := OY;
  Ev.F[17] := BVX;
  Ev.F[18] := BVY;
  Push(Ev);
end;

function Prof(Slot: LongInt): PPlayerProfile;
var
  Idx: LongInt;
begin
  Idx := Engine.Identity.StatsIndex(Slot);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx]
  else
    Result := nil;
end;

function Near(A, B, Tol: Double): Boolean;
begin
  Result := Abs(A - B) <= Tol;
end;

var
  Root: AnsiString;
  A, B, C: PPlayerProfile;
  R: PPlayerMapStats;
  W: PPMWeapon;
  Mp: LongInt;
  Shots0, Hits0, Head0, NadeThrows0, BHits0: LongInt;
  Dealt0: Double;
  Lose0, Lose1, Win0, Win1: LongInt;
  Ok: Boolean;
begin
  { the zones of the server's hit test: its own rule }
  Check('the part numbers of the server''s hit test: up to 4 the legs, up to 11 the chest, then the head',
    (ZoneOfWhere(0) = HZ_UNKNOWN) and (ZoneOfWhere(-3) = HZ_UNKNOWN) and (ZoneOfWhere(1) = HZ_LEGS) and
    (ZoneOfWhere(4) = HZ_LEGS) and (ZoneOfWhere(5) = HZ_BODY) and (ZoneOfWhere(11) = HZ_BODY) and
    (ZoneOfWhere(12) = HZ_HEAD) and (ZoneOfWhere(25) = HZ_HEAD));
  Check('without a server nothing runs: no hooks, no reading, no map walls', BridgeState = 0);

  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'bridge_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Console := TStringList.Create;
  L := TStringList.Create;
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
    Check('[Bridges] all on by default', Engine.Cfg.BridgeHook and Engine.Cfg.BridgeMemory and
      Engine.Cfg.BridgeGeometry);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- a deathmatch: Alice, Bob and Carl; the hooks and the reading run ---- }
  CurTick := 0;
  MapAfter('dm_Bridge', GS_DM, 0);
  Join(1, 'Alice', 'S5001', TEAM_NONE);
  Join(2, 'Bob', 'S5002', TEAM_NONE);
  Join(3, 'Carl', 'S5003', TEAM_NONE);
  CurTick := 10;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_AK74, 800, 100);
  Spawn(3, WEP_AK74, 900, 100);
  BridgeEv(B_ALL, 'hooks: CreateBullet in place, HealthHit in place; memory: on (a test)');
  Check('the console hears what the bridges do', ConsoleHas('[ZitroStats] bridges: hooks: CreateBullet in place'));
  Console.Clear;
  BridgeEv(B_ALL or 8, 'the map walls came: no new line');
  Check('the map''s walls alone change no line of the console', not ConsoleHas('no new line'));

  { the shots: the hook's bullets count, the script's shots from the ammunition do not any more }
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    Shots0 := A^.Shots;
    NadeThrows0 := A^.NadesThrows;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 100;
  ShotEv(1, WEP_AK74, 100, 100);
  BulletEv(1, WEP_AK74, 3, 1, POSTURE_STAND, 100, 100);
  BulletEv(1, WEP_AK74, 2, 1, POSTURE_PRONE, 100, 104);
  BulletEv(1, WEP_AK74, 1, 1, -1, 100, 104);
  BulletEv(1, WEP_FRAG, 1, 2, POSTURE_CROUCH, 100, 100);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    Check(Format('the hook''s bullets are the shots, the ammunition counts none (%d)', [A^.Shots - Shots0]),
      (A^.Shots - Shots0 = 6) and (A^.Weapons[WepSlot(WEP_AK74)].Shots = 6) and (A^.NadesThrows - NadeThrows0 = 1));
    Check('the shots by stance: a throw and a stance not known count none',
      (A^.StanceShots[POSTURE_STAND] = 3) and (A^.StanceShots[POSTURE_CROUCH] = 0) and
      (A^.StanceShots[POSTURE_PRONE] = 2) and (A^.StanceShots[POSTURE_AIR] = 0));
    Shots0 := A^.Shots;
    Hits0 := A^.ShotsHits;
    Head0 := A^.ShotsHitsHead;
    Dealt0 := A^.DamageDealt;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { the hits: an AK bullet whose damage tells the chest (speed 24 x 1.004 x 0.95), while the server's
    hit test named the head }
  CurTick := 110;
  HitEv(1, 2, 7, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY or EF_ZONE or EF_ORIGIN, HZ_HEAD, POSTURE_PRONE, 100,
    24 * 1.004 * 0.95, 790, 100, 24, 0, 800, 100, 150, 100, 104);
  { a bullet the hook did not see made (a script's): damage, but no hit of a shot }
  CurTick := 111;
  HitEv(1, 2, 8, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY or EF_SCRIPT_BULLET, HZ_UNKNOWN, -1, 0, 10, 790, 100, 24, 0,
    800, 100, 127, 0, 0);
  { the old event of main.pas (no memory): no stance, whatever its I[5] }
  CurTick := 112;
  HitEv(1, 3, 9, WEP_AK74, ALIVE or EF_BULLET, HZ_UNKNOWN, 0, 0, 22.9, 890, 100, 24, 0, 900, 100, 150, 0, 0);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    Check(Format('the zone of the server''s hit test is the zone of the hit (%d heads)', [A^.ShotsHitsHead - Head0]),
      A^.ShotsHitsHead - Head0 = 1);
    Check(Format('a script''s bullet: its damage counts, no hit of a shot (%d hits, %s damage)',
      [A^.ShotsHits - Hits0, FloatStr(A^.DamageDealt - Dealt0, 1)]),
      (A^.ShotsHits - Hits0 = 2) and Near(A^.DamageDealt - Dealt0, 24 * 1.004 * 0.95 + 10 + 22.9, 0.01));
    Check('the hits by stance: the stance the shooter had when he fired, only from the memory',
      (A^.StanceHits[POSTURE_PRONE] = 1) and (A^.StanceHits[POSTURE_STAND] = 0) and (A^.StanceHits[POSTURE_AIR] = 0));
    Check('the shots stayed what the hook said', A^.Shots = Shots0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('/zs_perf: the zone the damage tells was another one once',
    Pos('0 the same, 1 different', Engine.BridgeReport) > 0);

  { ---- the kills read from memory ---- }
  { Alice's AK bullet 20, made at (100, 100) at tick 150, flies right and hits Bob, who faces right,
    in the head 700 px (50 m) away half a second later; then the same bullet kills Carl }
  CurTick := 180;
  HitEv(1, 2, 20, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY or EF_ZONE or EF_ORIGIN, HZ_HEAD, POSTURE_STAND, 150, 60,
    800, 100, 24, 0, 800, 100, 127, 100, 100);
  KillEv(1, 2, 20, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY or EF_ORIGIN, 150, 1, 100, 100, 800, 100, 800, 100, 100,
    100, 24, 0);
  CurTick := 182;
  HitEv(1, 3, 20, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY or EF_ZONE or EF_ORIGIN, HZ_BODY, POSTURE_STAND, 150, 160,
    900, 100, 23.8, 0, 900, 100, 150, 100, 100);
  KillEv(1, 3, 20, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY or EF_ORIGIN, 150, -1, 100, 100, 900, 100, 900, 100, 100,
    100, 23.8, 0);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    B := Prof(2);
    C := Prof(3);
    Check(Format('the distance from where the bullet was made, as the server''s message (%s m)',
      [FloatStr(A^.LongestKillDistance, 2)]), Near(A^.LongestKillDistance, 800 / PIXELS_PER_METER, 0.01));
    Check(Format('a second victim of one bullet is a collateral (%d)', [A^.CollateralKills]), A^.CollateralKills = 1);
    Check(Format('Bob faced the way the bullet flew: killed from behind (%d / %d); Carl faced it',
      [A^.BackKills, B^.BackDeaths]), (A^.BackKills = 1) and (B^.BackDeaths = 1) and (C^.BackDeaths = 0));
    Check(Format('the longest headshot only with the server''s zone (%s m)', [FloatStr(A^.LongestHeadshotM, 2)]),
      Near(A^.LongestHeadshotM, 700 / PIXELS_PER_METER, 0.01));
    Check(Format('the longest flight of a lethal bullet: from tick 150 to 182 (%s s)',
      [FloatStr(A^.LongestFlightKill, 3)]), Near(A^.LongestFlightKill, 32 / TICKS_PER_SECOND, 0.001));
    { the hits with an origin: 690.01 px at tick 110 (made at 100), 700 px at 180 and 800 px at 182 (made at
      150); not the script's bullet nor the hit main.pas sent without the memory }
    Check(Format('the hits'' distance from where their bullets were made: %d hits, %s m, the longest %s m',
      [A^.HitDistCount, FloatStr(A^.HitDistSum, 2), FloatStr(A^.LongestHitM, 2)]),
      (A^.HitDistCount = 3) and Near(A^.HitDistSum, (Sqrt(690 * 690 + 16) + 700 + 800) / PIXELS_PER_METER, 0.01) and
      Near(A^.LongestHitM, 800 / PIXELS_PER_METER, 0.01));
    Check(Format('the hits'' air time: %d hits, %d ticks (10 + 30 + 32)', [A^.HitAirCount, A^.HitAirTicks]),
      (A^.HitAirCount = 3) and (A^.HitAirTicks = 72));
    Check(Format('the kills'' air time: %d kills, %d ticks (30 + 32)', [A^.KillAirCount, A^.KillAirTicks]),
      (A^.KillAirCount = 2) and (A^.KillAirTicks = 62));
    Check('the same for the weapon (the AK)',
      (A^.Weapons[WEP_AK74].HitDistCount = 3) and (A^.Weapons[WEP_AK74].HitAirTicks = 72) and
      (A^.Weapons[WEP_AK74].KillAirCount = 2) and (A^.Weapons[WEP_AK74].KillAirTicks = 62) and
      Near(A^.Weapons[WEP_AK74].LongestHit, 800 / PIXELS_PER_METER, 0.01));
    R := Engine.DB.PM.Find(A^.ID, 'dm_Bridge');
    Check('the record of the map follows the account: the same hits'' distance and air times',
      (R <> nil) and (R^.HitDistCount = A^.HitDistCount) and Near(R^.HitDistSum, A^.HitDistSum, 0.0001) and
      (R^.HitAirTicks = A^.HitAirTicks) and (R^.HitAirCount = A^.HitAirCount) and
      (R^.KillAirTicks = A^.KillAirTicks) and (R^.KillAirCount = A^.KillAirCount));
    Ok := R <> nil;
    if Ok then
    begin
      W := PMWeaponOf(R^, WEP_AK74);
      Ok := Near(R^.LongestHit, 800 / PIXELS_PER_METER, 0.01) and (W^.HitDistCount = 3) and
        Near(W^.HitDistSum, A^.HitDistSum, 0.001) and Near(W^.LongestHit, 800 / PIXELS_PER_METER, 0.01) and
        (W^.HitAirTicks = 72) and (W^.HitAirCount = 3) and (W^.KillAirTicks = 62) and (W^.KillAirCount = 2);
    end;
    Check('the record''s longest hit and its AK: the same hits and kills', Ok);
    Mp := Engine.DB.FindMap('dm_Bridge', False);
    Ok := Mp >= 0;
    if Ok then
      Ok := (Engine.DB.Maps[Mp].HitDistCount = 3) and Near(Engine.DB.Maps[Mp].HitDistSum, A^.HitDistSum, 0.001) and
        Near(Engine.DB.Maps[Mp].LongestHit, 800 / PIXELS_PER_METER, 0.01) and (Engine.DB.Maps[Mp].HitAirTicks = 72) and
        (Engine.DB.Maps[Mp].HitAirCount = 3) and (Engine.DB.Maps[Mp].KillAirTicks = 62) and
        (Engine.DB.Maps[Mp].KillAirCount = 2);
    Check('the map''s own counters: the same hits and kills (dm_Bridge)', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { a grenade made at tick 200 kills Bob 3 seconds later: no flight (a fuse), no collateral, no back;
    a kill main.pas sent itself (no memory): no back kill either }
  CurTick := 300;
  Spawn(2, WEP_AK74, 800, 100);
  Spawn(3, WEP_AK74, 900, 100);
  CurTick := 380;
  KillEv(1, 2, 30, WEP_FRAG, ALIVE or EF_MEMORY or EF_ORIGIN, 200, 1, 100, 100, 800, 100, 0, 0, 100, 100, 5, 0);
  KillEv(1, 3, 30, WEP_FRAG, ALIVE or EF_MEMORY or EF_ORIGIN, 200, 1, 100, 100, 900, 100, 0, 0, 100, 100, 5, 0);
  CurTick := 500;
  Spawn(2, WEP_AK74, 800, 100);
  CurTick := 520;
  KillEv(1, 2, 31, WEP_AK74, ALIVE or EF_BULLET, 0, 1, 100, 100, 800, 100, 800, 100, 0, 0, 24, 0);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    B := Prof(2);
    Check('a grenade: no flight, no collateral, no kill from behind; a kill of main.pas: no kill from behind',
      (A^.CollateralKills = 1) and (A^.BackKills = 1) and (B^.BackDeaths = 1) and
      Near(A^.LongestFlightKill, 32 / TICKS_PER_SECOND, 0.001));
    Check(Format('a grenade''s kill has no air time (a fuse), a kill without the memory none either (%d)',
      [A^.KillAirCount]), (A^.KillAirCount = 2) and (A^.Weapons[WSLOT_FRAG].KillAirCount = 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  L.Clear;
  Console.Clear;

  { ---- survival deathmatch with a bot, its life read from memory ---- }
  CurTick := 990;
  LeaveEv(3);
  CurTick := 1000;
  MapAfter('dm_Survive', GS_DM, 1);
  JoinBot(7, 'Bot Boris', TEAM_NONE);
  BridgeEv(B_ALL, '');
  CurTick := 1010;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_AK74, 800, 100);
  LifeEv(7, 1, 500, 100);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Lose0 := Prof(1)^.RoundsLose;
    Win0 := Prof(1)^.RoundsWins;
    BHits0 := Prof(2)^.RoundsLose;
    Ok := Engine.Live[7].Alive;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a bot''s life from memory: it stands', Ok);
  { the bot kills Bob: Alice and the bot still stand - no round yet; then the bot kills Alice and
    outlives every human: nobody won, both lost }
  CurTick := 1100;
  KillEv(7, 2, 40, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY, 0, 1, 500, 100, 800, 100, 800, 100, 0, 0, 24, 0);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Prof(1)^.RoundsWins = Win0) and (Prof(1)^.RoundsLose = Lose0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('a living bot keeps the round going for the last human', Ok);
  CurTick := 1200;
  KillEv(7, 1, 41, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY, 0, 1, 500, 100, 100, 100, 100, 100, 0, 0, -24, 0);
  CurTick := 1201;
  { the next round (the server killed the bot, everybody respawns): a round settles with the next spawn }
  LifeEv(7, 0, 500, 100);
  CurTick := 1500;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_AK74, 800, 100);
  LifeEv(7, 1, 500, 100);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Lose1 := Prof(1)^.RoundsLose;
    Win1 := Prof(1)^.RoundsWins;
    Ok := (Win1 = Win0) and (Lose1 = Lose0 + 1) and (Prof(2)^.RoundsLose = BHits0 + 1);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check(Format('a round the bot outlived: won by nobody, both humans lost it (Alice %d won, %d lost)',
    [Win1 - Win0, Lose1 - Lose0]), Ok);
  { Alice kills the bot (its death comes with the kill), then Bob: she is the last one standing }
  CurTick := 1600;
  KillEv(1, 7, 42, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY, 0, 1, 100, 100, 500, 100, 500, 100, 0, 0, 24, 0);
  CurTick := 1601;
  LifeEv(7, 0, 500, 100);
  CurTick := 1700;
  KillEv(1, 2, 43, WEP_AK74, ALIVE or EF_BULLET or EF_MEMORY, 0, 1, 100, 100, 800, 100, 800, 100, 0, 0, 24, 0);
  CurTick := 2000;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_AK74, 800, 100);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (Prof(1)^.RoundsWins = Win1 + 1) and (Prof(1)^.RoundsLose = Lose1);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('the bot dead and Bob killed: Alice won the round', Ok);

  { the reading switched off: bots stand again, as before 5.6 - the last human standing has not won }
  BridgeEv(1 or 4, 'memory: off (a test)');
  Check('the console hears that the reading went off', ConsoleHas('bridges: memory: off (a test)'));
  CurTick := 2010;
  LifeEv(7, 1, 500, 100);
  CurTick := 2100;
  KillEv(1, 2, 44, WEP_AK74, ALIVE or EF_BULLET, 0, 1, 100, 100, 800, 100, 800, 100, 0, 0, 24, 0);
  CurTick := 2400;
  Spawn(2, WEP_AK74, 800, 100);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Prof(1)^.RoundsWins = Win1 + 1;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('without the reading a bot may stand: no round for the last human', Ok);

  WaitProcessed;
  DrainActions;
  Check('no engine errors', (Pos('internal error', Console.Text) = 0) and (Pos('ERROR', Console.Text) = 0));
  Engine.Free;
  L.Free;
  Console.Free;
  SetCurrentDir(ExtractFilePath(ParamStr(0)));
  DeleteTree(Root);
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  if Failures <> 0 then
    Halt(1);
end.
