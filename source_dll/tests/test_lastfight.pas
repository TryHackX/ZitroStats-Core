program test_lastfight;

{ !lastfight (zs_fight, zs_engine_fight.inc, zs_cmd_fight.inc): the estimates, the ring and the
  records of zs_fight on their own, the flight of a bullet against Soldat's physics; then scripted
  fights through the engine - the record of a death, the two lines of the summary, the report of the
  command, every line within LINE_W, the kinds of deaths, the rotation of the records, a ring that
  overflows, the same cells for the hits both ways (a bot's shot worked out from its bullet, the
  speed of whoever was hit) - and nothing for bots, spectators, the server's own kills, the server
  console or with the settings off. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_engine, zs_commands, zs_fight, zs_weapons;

const
  LONG_NAME = 'LongNameLongNameLongName';
  ALIVE = EF_A_ALIVE or EF_A_ONGROUND or EF_B_ONGROUND;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console, AllOut, L, L2: TStringList;

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

{ ---------------- zs_fight on its own ---------------- }

function Near(A, B, Tol: Double): Boolean;
begin
  Result := Abs(A - B) <= Tol;
end;

function Hit(Kind, Other, Weapon, Tick: LongInt; Dmg: Single): TLfEvent;
begin
  Result := Default(TLfEvent);
  Result.Tick := Tick;
  Result.LastTick := Tick;
  Result.Kind := Kind;
  Result.Other := Other;
  Result.Count := 1;
  Result.Weapon := Weapon;
  Result.LastZone := -1;
  Result.Damage := Dmg;
  Result.Dist := -1;
  Result.Flight := -1;
  Result.Speed := -1;
  Result.Text := 'P' + IntToStr(Other);
end;

{ A bullet as Soldat moves it (Parts.pas, Euler, BulletParts): fired at V0 in the direction Angle
  (degrees, 0 = to the right, more = down) with the share Inherit of the shooter's velocity SVX, SVY;
  every tick gravity adds to its velocity, it moves by it and keeps 99% of it. K ticks later it hits
  within the step of that tick, in its middle: HX, HY from the gun, and its velocity VX, VY then. }
procedure SimBullet(V0, Angle, Inherit, SVX, SVY: Double; K: LongInt; out HX, HY, VX, VY: Double);
var
  n: LongInt;
  PX, PY: Double;
begin
  VX := V0 * Cos(Angle * Pi / 180) + Inherit * SVX;
  VY := V0 * Sin(Angle * Pi / 180) + Inherit * SVY;
  PX := 0;
  PY := 0;
  for n := 1 to K do
  begin
    VY := VY + LF_GRAVITY;
    PX := PX + VX;
    PY := PY + VY;
    VX := VX * (1 - LF_DRAG);
    VY := VY * (1 - LF_DRAG);
  end;
  HX := PX + 0.5 * VX;
  HY := PY + 0.5 * VY;
end;

{ the bullet's own flight against Soldat's steps, for weapons, directions, flights and shooters }
procedure BulletFlightTests;
const
  GUNS: array[0..4] of LongInt = (WEP_SOCOM, WEP_AK74, WEP_BARRETT, WEP_BOW, WEP_M2);
  ANGLES: array[0..4] of Double = (-50, -15, 0, 20, 60);
  FLIGHTS: array[0..5] of LongInt = (0, 1, 4, 12, 30, 90);
  SHOOTERS: array[0..2, 0..1] of Double = ((0, 0), (3, 0), (-2.5, 1.5));
var
  g, a, f, s, S0, Tried: LongInt;
  HX, HY, VX, VY, WorstD, WorstT: Double;
  D, T, D2, T2, Saved: Single;
  AllTold: Boolean;
begin
  WorstD := 0;
  WorstT := 0;
  AllTold := True;
  Tried := 0;
  for g := 0 to High(GUNS) do
    for a := 0 to High(ANGLES) do
      for f := 0 to High(FLIGHTS) do
        for s := 0 to High(SHOOTERS) do
        begin
          S0 := WepSlot(GUNS[g]);
          SimBullet(WeaponDefs[S0].Speed, ANGLES[a], WeaponDefs[S0].Inherit, SHOOTERS[s, 0], SHOOTERS[s, 1], FLIGHTS[f],
            HX, HY, VX, VY);
          Inc(Tried);
          if not LfBulletFlight(GUNS[g], VX, VY, SHOOTERS[s, 0], SHOOTERS[s, 1], D, T) then
          begin
            AllTold := False;
            WriteLn(Format('       not told: weapon %d, %s degrees, %d ticks',
              [GUNS[g], FloatStr(ANGLES[a], 0), FLIGHTS[f]]));
            Continue;
          end;
          WorstD := Max(WorstD, Abs(D - Hypot(HX, HY)));
          WorstT := Max(WorstT, Abs(T - (FLIGHTS[f] + 0.5)));
        end;
  Check(Format('the bullet''s own flight: Soldat''s steps back to the gun (%d bullets, %s px, %s ticks off at most)',
    [Tried, FloatStr(WorstD, 3), FloatStr(WorstT, 4)]), AllTold and (WorstD < 1) and (WorstT < 0.02));
  { a shooter who kept running at 3 pixels a tick: without his velocity the AK bullet of 20 ticks
    looks 6 ticks younger and 150 px shorter }
  SimBullet(24.6, 0, 0.5, 3, 0, 20, HX, HY, VX, VY);
  Check('the shooter''s velocity is part of the bullet''s speed',
    LfBulletFlight(WEP_AK74, VX, VY, 3, 0, D, T) and LfBulletFlight(WEP_AK74, VX, VY, 0, 0, D2, T2) and
    Near(D, Hypot(HX, HY), 1) and (D - D2 > 140) and (T - T2 > 5));
  Check('a bullet faster than it left the gun was fired a moment ago: half a tick, half a step',
    LfBulletFlight(WEP_AK74, 26, 0, 0, 0, D, T) and Near(T, 0.5, 0.01) and Near(D, 13, 0.5));
  Saved := WeaponDefs[WEP_SPAS].Speed;
  WeaponDefs[WEP_SPAS].Speed := 13.2;
  Check('the realistic Spas-12 (13.2) is too slow for its gravity', not LfBulletFlight(WEP_SPAS, 12, 1, 0, 0, D, T));
  WeaponDefs[WEP_SPAS].Speed := Saved;
  Check('no flight from the bullet for the Spas-12, blasts, blades, flames, a thrown knife, no velocity, no weapon',
    not LfBulletFlight(WEP_SPAS, 12, 1, 0, 0, D, T) and not LfBulletFlight(WEP_M79, 9, 1, 0, 0, D, T) and
    not LfBulletFlight(WEP_LAW, 20, 0, 0, 0, D, T) and not LfBulletFlight(WEP_KNIFE, 5, 0, 0, 0, D, T) and
    not LfBulletFlight(WEP_FLAMER, 9, 0, 0, 0, D, T) and not LfBulletFlight(WEP_THROWNKNIFE, 8, 0, 0, 0, D, T) and
    not LfBulletFlight(WEP_AK74, 0, 0, 0, 0, D, T) and not LfBulletFlight(WEP_WORLD, 20, 0, 0, 0, D, T) and
    (D < 0) and (T < 0));
  Check('no flight from a bullet longer in the air than a bullet lives',
    not LfBulletFlight(WEP_AK74, 0.3, 13.3, 0, 0, D, T));
  Check('straight flights: guns and bows; not blasts, flames, blades or a thrown knife',
    LfStraightFlight(WEP_AK74) and LfStraightFlight(WEP_SPAS) and LfStraightFlight(WEP_BOW) and LfStraightFlight(WEP_M2) and
    not LfStraightFlight(WEP_M79) and not LfStraightFlight(WEP_BOW2) and not LfStraightFlight(WEP_FLAMER) and
    not LfStraightFlight(WEP_KNIFE) and not LfStraightFlight(WEP_THROWNKNIFE) and not LfStraightFlight(WEP_FRAG) and
    not LfStraightFlight(WEP_WORLD));
end;

procedure UnitTests;
var
  F: PLfSlot;
  R: TLfRecord;
  Ev: TLfEvent;
  P: PLfEvent;
  k: LongInt;
  Foes: TLfFoes;
begin
  BulletFlightTests;
  { the flight of a bullet that keeps 99% of its speed a tick }
  Check('flight: 0 px takes no time', Near(LfFlightSeconds(WEP_AK74, 0), 0, 0.0001));
  Check('flight: AK-74 over 246 px, 10.5 ticks with the drag', Near(LfFlightSeconds(WEP_AK74, 246),
    Ln(0.9) / Ln(0.99) / 60, 0.0005));
  Check('flight: Barrett over 100 m, about half a second', Near(LfFlightSeconds(WEP_BARRETT, 1400), 0.487, 0.005));
  Check('flight: farther than the bullet carries is unknown', LfFlightSeconds(WEP_AK74, 2400) < 0);
  Check('flight: no weapon, no distance', (LfFlightSeconds(WEP_WORLD, 100) < 0) and (LfFlightSeconds(WEP_AK74, -1) < 0));
  Check('flight: a thrown knife flies faster than the knife''s speed',
    LfFlightSeconds(WEP_THROWNKNIFE, 100) < LfFlightSeconds(WEP_KNIFE, 100));

  Check('points of HUD notes', (LfNotePoints('+22 pts') = 22) and (LfNotePoints('-18 pts') = -18) and
    (LfNotePoints('-5 pts teamkill') = -5) and (LfNotePoints('+3 pts (inactive victim)') = 3) and
    (LfNotePoints('Assist') = 0) and (LfNotePoints('+x pts') = 0) and (LfNotePoints('Long shot: 120 m') = 0) and
    (LfNotePoints('+12pts') = 0));

  Ev := Hit(LFE_TAKEN, 2, WEP_AK74, 100, 20);
  Ev.Flight := 0.1;
  Check('dodge: faster than a reaction', LfDodge(Ev) = 'no');
  Ev.Flight := 0.3;
  Ev.Speed := 8;
  Check('dodge: hard while moving', LfDodge(Ev) = 'hard');
  Ev.Speed := 0.5;
  Check('dodge: hard, standing still', LfDodge(Ev) = 'hard (still)');
  Ev.Flight := 0.6;
  Check('dodge: a chance, standing still', LfDodge(Ev) = 'maybe (still)');
  Ev.Speed := -1;
  Check('dodge: a chance, speed unknown', LfDodge(Ev) = 'maybe');
  Ev.Flight := -1;
  Check('dodge: unknown flight', LfDodge(Ev) = '?');
  Ev.Weapon := WEP_KNIFE;
  Check('dodge: a blade', LfDodge(Ev) = 'melee');
  Ev.Weapon := WEP_M79;
  Check('dodge: an explosion', LfDodge(Ev) = 'blast');
  Ev.Weapon := WEP_FLAMER;
  Check('dodge: flames', LfDodge(Ev) = 'flame');
  Ev.Weapon := WEP_THROWNKNIFE;
  Check('dodge: a thrown knife', LfDodge(Ev) = 'thrown');
  Ev.Flags := LFF_SELF;
  Check('dodge: his own hit', LfDodge(Ev) = 'self');

  Check('zones: one hit by name, more as counts, a guess marked', (LfZones(1, 0, 0, 0, False, '') = 'head') and
    (LfZones(2, 1, 0, 0, False, '') = '2h1b') and (LfZones(0, 3, 1, 1, False, ' ') = '3b 1l 1?') and
    (LfZones(0, 1, 0, 0, True, '') = '~body') and (LfZones(0, 0, 0, 1, True, '') = '?') and
    (LfZones(0, 0, 0, 0, False, '') = '-'));
  Check('seconds from the death: no sign at 0, never -0', (LfSeconds(0, 2) = '0.00') and (LfSeconds(-145, 2) = '-2.42') and
    (LfSeconds(21, 2) = '+0.35') and (LfSeconds(-1, 1) = '0.0') and (LfSeconds(6, 1) = '+0.1'));
  Check('meters', (LfMeters(490, False) = '35 m') and (LfMeters(490, True) = '~35 m') and (LfMeters(-1, False) = ''));

  New(F);
  try
    F^ := Default(TLfSlot);
    { a burst: the next hit of the same player and weapon within the gap joins the entry }
    LfAppend(F^, Hit(LFE_TAKEN, 2, WEP_SPAS, 100, 10));
    P := LfBurst(F^, LFE_TAKEN, 2, WEP_SPAS, 101, 0);
    Check('a pellet of the same shot joins its entry', P <> nil);
    if P <> nil then
      LfAddHit(P, 101, 12, HZ_BODY, 0);
    Check('the entry counts both', (F^.Count = 1) and (F^.Ring[0].Count = 2) and Near(F^.Ring[0].Damage, 22, 0.01) and
      (F^.Ring[0].Zones[HZ_BODY] = 1) and (F^.Ring[0].LastTick = 101));
    Check('another player, weapon, kind or a later bullet is a new line',
      (LfBurst(F^, LFE_TAKEN, 3, WEP_SPAS, 101, 0) = nil) and (LfBurst(F^, LFE_TAKEN, 2, WEP_AK74, 101, 0) = nil) and
      (LfBurst(F^, LFE_DEALT, 2, WEP_SPAS, 101, 0) = nil) and (LfBurst(F^, LFE_TAKEN, 2, WEP_SPAS, 110, 0) = nil) and
      (LfBurst(F^, LFE_TAKEN, 2, WEP_SPAS, 101, LFF_AFTER) = nil));
    F^.Ring[0].Flags := LFF_LETHAL;
    Check('nothing joins the hit that killed', LfBurst(F^, LFE_TAKEN, 2, WEP_SPAS, 102, 0) = nil);
    LfAppend(F^, Hit(LFE_DEALT, 3, WEP_MINIGUN, 200, 5));
    Check('the hits dealt on one player join for half a second', (LfBurst(F^, LFE_DEALT, 3, WEP_MINIGUN, 229, 0) <> nil) and
      (LfBurst(F^, LFE_DEALT, 3, WEP_MINIGUN, 231, 0) = nil));
    Check('the newest entry of a kind and player', (LfLatest(F^, LFE_TAKEN, 2, 90) = @F^.Ring[0]) and
      (LfLatest(F^, LFE_TAKEN, 2, 150) = nil));

    { the ring keeps LF_RING entries; a record that reaches back further says so }
    F^ := Default(TLfSlot);
    for k := 1 to LF_RING + 10 do
      LfAppend(F^, Hit(LFE_DEALT, 4, WEP_AK74, k * 10, 1));
    Check('the ring is full and knows what it lost', (F^.Count = LF_RING) and (F^.LostTick = 100));
    R := Default(TLfRecord);
    R.DeathTick := (LF_RING + 10) * 10;
    R.FromTick := 0;
    LfCollect(F^, R, R.DeathTick);
    Check('a window of more entries than a record holds: the newest ones, and what is missing',
      (R.Count = LF_EVENTS) and (R.Events[LF_EVENTS - 1].Tick = R.DeathTick) and (R.Missed = LF_RING - LF_EVENTS + 1));
    R := Default(TLfRecord);
    R.DeathTick := 500;
    R.FromTick := 400;
    LfCollect(F^, R, 520);
    Check('the window from FromTick to the end', (R.Count = 13) and (R.Events[0].Tick = 400) and
      (R.Events[12].Tick = 520) and (R.Missed = 0));

    { the records: the last LF_DEATHS, the newest first }
    F^ := Default(TLfSlot);
    Check('no records', (LfRecords(F^) = 0) and (LfRecordAt(F^, 1) = nil) and (LfOpenRecord(F^) = nil));
    for k := 1 to LF_DEATHS + 2 do
      LfNewRecord(F^)^.DeathTick := k;
    Check('the last three deaths, newest first', (LfRecords(F^) = LF_DEATHS) and
      (LfRecordAt(F^, 1)^.DeathTick = LF_DEATHS + 2) and (LfRecordAt(F^, LF_DEATHS)^.DeathTick = 3) and
      (LfRecordAt(F^, LF_DEATHS + 1) = nil) and (LfRecordAt(F^, 0) = nil));
    Check('the newest is open until it is closed', LfOpenRecord(F^) = LfRecordAt(F^, 1));
    LfRecordAt(F^, 1)^.Closed := True;
    Check('closed', LfOpenRecord(F^) = nil);
    R := Default(TLfRecord);
    R.DeathTick := 1000;
    R.EndTick := 1240;
    Check('the window ends with the seconds after the death, at a respawn, or now', (LfWindowEnd(R, 0, 5000) = 1240) and
      (LfWindowEnd(R, 1100, 5000) = 1099) and (LfWindowEnd(R, 900, 5000) = 1240) and (LfWindowEnd(R, 0, 1050) = 1050));

    { the tables: per player, most damage first, kills with the hits }
    R := Default(TLfRecord);
    R.Events[0] := Hit(LFE_TAKEN, 2, WEP_AK74, 10, 20);
    R.Events[1] := Hit(LFE_TAKEN, 3, WEP_DEAGLES, 20, 45);
    R.Events[2] := Hit(LFE_TAKEN, 2, WEP_DEAGLES, 30, 30);
    R.Events[3] := Hit(LFE_DEALT, 2, WEP_AK74, 5, 12);
    R.Events[4] := Hit(LFE_KILL, 2, WEP_AK74, 40, 0);
    R.Count := 5;
    Check('who hurt him: one line per player, most damage first, the weapons of each',
      (LfFoes(R, False, Foes) = 2) and (Foes[0].Slot = 2) and Near(Foes[0].Damage, 50, 0.01) and (Foes[0].Hits = 2) and
      (Foes[0].WeaponCount = 2) and (Foes[1].Slot = 3) and (Foes[0].First = 10) and (Foes[0].Last = 30));
    Check('whom he hit and killed', (LfFoes(R, True, Foes) = 1) and Foes[0].Killed and (Foes[0].KillTick = 40) and
      (Foes[0].Hits = 1));
  finally
    Dispose(F);
  end;
end;


{ ---------------- through the engine ---------------- }

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

{ everything the engine wrote since the last look: Console holds it until the next Fresh, AllOut
  for good }
procedure DrainActions;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
  begin
    Console.Add(Format('%d|%d|%s', [A.Kind, A.Slot, A.Text]));
    AllOut.Add(Format('%d|%d|%s', [A.Kind, A.Slot, A.Text]));
  end;
end;

procedure Fresh;
begin
  WaitProcessed;
  DrainActions;
  Console.Clear;
end;

function TextOf(const Entry: AnsiString): AnsiString;
var
  p: LongInt;
begin
  Result := Entry;
  p := Pos('|', Result);
  Delete(Result, 1, p);
  p := Pos('|', Result);
  Delete(Result, 1, p);
end;

{ Dest := the console lines to Slot since the last Fresh; slot 0 is the server console }
procedure LinesOf(Slot: LongInt; Dest: TStringList);
var
  k: LongInt;
  Prefix: AnsiString;
begin
  Dest.Clear;
  if Slot = 0 then
    Prefix := Format('%d|0|', [ACT_WRITELN])
  else
    Prefix := Format('%d|%d|', [ACT_CONSOLE, Slot]);
  for k := 0 to Console.Count - 1 do
    if Copy(Console[k], 1, Length(Prefix)) = Prefix then
      Dest.Add(TextOf(Console[k]));
end;

function Has(Src: TStringList; const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  for k := 0 to Src.Count - 1 do
    if Pos(Part, Src[k]) > 0 then
      Exit(True);
  Result := False;
end;

function LineOf(Src: TStringList; const Part: AnsiString): AnsiString;
var
  k: LongInt;
begin
  for k := 0 to Src.Count - 1 do
    if Pos(Part, Src[k]) > 0 then
      Exit(Src[k]);
  Result := '';
end;

{ the line of a table that starts with this cell }
function RowOf(Src: TStringList; const Cell: AnsiString): AnsiString;
var
  k: LongInt;
begin
  for k := 0 to Src.Count - 1 do
    if Copy(Src[k], 1, Length(Cell) + 1) = Cell + ' ' then
      Exit(Src[k]);
  Result := '';
end;

function CountOf(Src: TStringList; const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to Src.Count - 1 do
    if Pos(Part, Src[k]) > 0 then
      Inc(Result);
end;

{ every line within LINE_W, no trailing space, nothing of a format left, no "-0" }
function Tidy(Src: TStringList): Boolean;
var
  k: LongInt;
  T: AnsiString;
begin
  Result := Src.Count > 0;
  for k := 0 to Src.Count - 1 do
  begin
    T := Src[k];
    if (Length(T) > LINE_W) or ((T <> '') and (T[Length(T)] = ' ')) or (Pos('%s', T) > 0) or (Pos('%d', T) > 0) or
       (Pos('%.', T) > 0) or (Pos(' -0.00', T) > 0) or (Pos(' -0 ', T) > 0) or (Pos('()', T) > 0) then
    begin
      Result := False;
      WriteLn(Format('       not tidy (%d): %s', [Length(T), T]));
    end;
  end;
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

procedure TeamEv(Slot, Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTeam);
  Ev.Slot := Slot;
  Ev.I[0] := Team;
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

procedure Sample(Slot: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSample);
  Ev.Slot := Slot;
  Ev.I[0] := EF_A_ALIVE or EF_A_ONGROUND;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := 30;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ a shot as main.pas sees it: the ammunition went down, with the shooter's position }
procedure Shot(Slot, Weapon: LongInt; X, Y: Single);
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

{ OnDamage as main.pas reports it: the bullet where it hit and its velocity, the victim's position,
  his health before the hit, his velocity and the shooter's (pixels a tick) }
procedure DamageMoving(S, V, Weapon: LongInt; Dmg, BX, BY, BVX, BVY, VX, VY, Health, VelX, VelY, SVelX, SVelY: Single;
  Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeDamage);
  Ev.Slot := S;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags or EF_BULLET;
  Ev.F[0] := Dmg;
  Ev.F[2] := BX;
  Ev.F[3] := BY;
  Ev.F[4] := BVX;
  Ev.F[5] := BVY;
  Ev.F[6] := VX;
  Ev.F[7] := VY;
  Ev.F[8] := Health;
  Ev.F[9] := VelX;
  Ev.F[10] := VelY;
  Ev.F[11] := SVelX;
  Ev.F[12] := SVelY;
  Push(Ev);
end;

{ the same between two players who stand still }
procedure Damage(S, V, Weapon: LongInt; Dmg, BX, BY, BVX, BVY, VX, VY, Health: Single; Flags: LongInt);
begin
  DamageMoving(S, V, Weapon, Dmg, BX, BY, BVX, BVY, VX, VY, Health, 0, 0, 0, 0, Flags);
end;

procedure Kill(K, V, Weapon: LongInt; KX, KY, VX, VY: Single; Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags;
  Ev.I[3] := WEP_AK74;
  Ev.F[0] := KX;
  Ev.F[1] := KY;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Push(Ev);
end;

{ the second of main.pas at Tick: the records whose window is over close; Console gets what came }
procedure SecondAt(Tick: LongInt);
var
  Ev: TZSEvent;
begin
  Fresh;
  CurTick := Tick;
  Ev := NewEvent(zeTick);
  Ev.I[4] := 300;
  Push(Ev);
  WaitProcessed;
  DrainActions;
end;

{ a command; Dest gets what it wrote to the caller }
procedure RunCmd(Slot: LongInt; const Text: AnsiString; Dest: TStringList);
var
  Ev: TZSEvent;
begin
  Fresh;
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  if Slot = 0 then
  begin
    Ev.I[0] := SRC_CONSOLE;
    Ev.I[1] := 1;
  end
  else
    Ev.I[0] := SRC_CHAT;
  Push(Ev);
  WaitProcessed;
  DrainActions;
  LinesOf(Slot, Dest);
end;

function FightOf(Slot: LongInt): PLfSlot;
begin
  Result := @Engine.Extra[Slot].Fight;
end;

function Points(Slot: LongInt): LongInt;
var
  Idx: LongInt;
begin
  Idx := Engine.Identity.ProfileIndex(Slot);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx]^.Points
  else
    Result := -1;
end;

{ the notes of a record: points taken at or after the death, and the points won }
procedure NotePoints(const R: TLfRecord; out Lost, Won: LongInt);
var
  k: LongInt;
begin
  Lost := 0;
  Won := 0;
  for k := 0 to R.Count - 1 do
    if R.Events[k].Kind = LFE_NOTE then
      if (R.Events[k].Points < 0) and (R.Events[k].Tick >= R.DeathTick) then
        Inc(Lost, -R.Events[k].Points)
      else if R.Events[k].Points > 0 then
        Inc(Won, R.Events[k].Points);
end;

{ the first event of a kind with a player (and a weapon, -2 = any), -1 = none }
function FindEvent(const R: TLfRecord; Kind, Other, Weapon: LongInt): LongInt;
var
  k: LongInt;
begin
  for k := 0 to R.Count - 1 do
    if (R.Events[k].Kind = Kind) and (R.Events[k].Other = Other) and ((Weapon = -2) or (R.Events[k].Weapon = Weapon)) then
      Exit(k);
  Result := -1;
end;

{ the event of a kind with a player that began at a tick, -1 = none }
function FindEventAt(const R: TLfRecord; Kind, Other, Tick: LongInt): LongInt;
var
  k: LongInt;
begin
  for k := 0 to R.Count - 1 do
    if (R.Events[k].Kind = Kind) and (R.Events[k].Other = Other) and (R.Events[k].Tick = Tick) then
      Exit(k);
  Result := -1;
end;

{ the first line that holds both parts, '' = none }
function LineOf2(Src: TStringList; const A, B: AnsiString): AnsiString;
var
  k: LongInt;
begin
  for k := 0 to Src.Count - 1 do
    if (Pos(A, Src[k]) > 0) and (Pos(B, Src[k]) > 0) then
      Exit(Src[k]);
  Result := '';
end;

procedure Show(Src: TStringList);
var
  k: LongInt;
begin
  for k := 0 to Src.Count - 1 do
    WriteLn('       | ', Src[k]);
end;

var
  Root, S1, S2, Lr: AnsiString;
  R, RB: TLfRecord;
  k, i, Lost, Won, AlicePts0, AlicePts1, Deaths0, Count0: LongInt;
  BotHX, BotHY, BotVX, BotVY, HX1, HY1, VX1, VY1, HX2, HY2, VX2, VY2: Double;
  WepIni: TStringList;
  Pd, Pk: PLfEvent;
begin
  UnitTests;

  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'lastfight_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);

  { the share of the shooter's velocity a bullet gets comes from weapons.ini like its speed }
  WepIni := TStringList.Create;
  try
    WepIni.Text := '[Ak-74]' + LineEnding + 'Speed=30' + LineEnding + 'InheritedVelocity=0.25' + LineEnding +
      '[Stationary Gun]' + LineEnding + 'InheritedVelocity=0.7';
    WepIni.SaveToFile(Root + PathDelim + 'weapons.ini');
  finally
    WepIni.Free;
  end;
  Check('weapons.ini: InheritedVelocity is read', LoadWeaponsIni(Root + PathDelim + 'weapons.ini') and
    Near(WeaponDefs[WEP_AK74].Inherit, 0.25, 0.0001) and Near(WeaponDefs[WEP_AK74].Speed, 30, 0.0001) and
    Near(WeaponDefs[WSLOT_M2].Inherit, 0.7, 0.0001) and Near(WeaponDefs[WEP_BARRETT].Inherit, 0.5, 0.0001));
  ResetWeaponDefs;
  Check('without weapons.ini: half for guns, nothing for blades, fists and the stationary gun, all for grenades',
    Near(WeaponDefs[WEP_AK74].Inherit, 0.5, 0.0001) and Near(WeaponDefs[WEP_AK74].Speed, 24.6, 0.0001) and
    (WeaponDefs[WEP_KNIFE].Inherit = 0) and (WeaponDefs[WEP_CHAINSAW].Inherit = 0) and (WeaponDefs[WSLOT_M2].Inherit = 0) and
    (WeaponDefs[WSLOT_FISTS].Inherit = 0) and (WeaponDefs[WSLOT_FRAG].Inherit = 1) and
    (WeaponDefs[WSLOT_CLUSTER].Inherit = 1));
  DeleteFile(Root + PathDelim + 'weapons.ini');
  Console := TStringList.Create;
  AllOut := TStringList.Create;
  L := TStringList.Create;
  L2 := TStringList.Create;
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
    Check('[LastFight] on by default: 10 s before, 4 s after, the summary', Engine.Cfg.LastFightEnabled and
      Engine.Cfg.LastFightSummary and (Engine.Cfg.LastFightBeforeSeconds = 10) and (Engine.Cfg.LastFightAfterSeconds = 4));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- realistic survival deathmatch: Carl and a bot wound Alice, Bob kills her; a grenade she
    fired kills Bob after her death ---- }
  CurTick := 0;
  MapAfter('rscs_fight', GS_DM, 1 or 2);
  Join(1, 'Alice', 'S3001', TEAM_NONE);
  Join(2, 'Bob', 'S3002', TEAM_NONE);
  Join(3, 'Carl', 'S3003', TEAM_NONE);
  Join(4, 'Dave', 'S3004', TEAM_SPEC);
  JoinBot(7, 'Bot Boogie', TEAM_NONE);
  CurTick := 10;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_AK74, 600, 100);
  Spawn(3, WEP_DEAGLES, 100, 400);
  { Alice fires at 100 and hits Bob 490 px away 20 ticks later (22.9 = an AK body hit at speed 24) }
  CurTick := 100;
  Sample(1, 100, 100);
  Sample(2, 600, 100);
  Sample(3, 100, 400);
  Shot(1, WEP_AK74, 100, 100);
  CurTick := 120;
  Damage(1, 2, WEP_AK74, 24 * 1.004 * 0.95, 590, 100, 24, 0, 600, 100, 65, ALIVE);
  { Carl's Deagles: two bullets of one shot from 290 px, while Alice stands still }
  CurTick := 190;
  Sample(1, 100, 100);
  Shot(3, WEP_DEAGLES, 100, 400);
  CurTick := 212;
  Damage(3, 1, WEP_DEAGLES, 28, 100, 110, 0, -28 / (1.81 * 0.95), 100, 100, 65, ALIVE);
  CurTick := 213;
  Damage(3, 1, WEP_DEAGLES, 17, 100, 112, 0, -28 / (1.81 * 0.95), 100, 100, 37, ALIVE);
  { the bot reports no shots and no positions: its Minimi bullet flew 20 ticks, and tells it; Alice
    walks at 1.4 pixels a tick }
  CurTick := 400;
  SimBullet(27, 0, 0.5, 0, 0, 20, BotHX, BotHY, BotVX, BotVY);
  DamageMoving(7, 1, WEP_MINIMI, 5, 100, 100, BotVX, BotVY, 100, 100, 20, 1.4, 0, 0, 0, ALIVE);
  { Bob's head shot from 490 px while Alice runs at 2.5 pixels a tick: 26.5 raw, the 15 health left }
  CurTick := 550;
  Shot(2, WEP_AK74, 600, 100);
  CurTick := 564;
  Sample(1, 80, 100);
  CurTick := 572;
  DamageMoving(2, 1, WEP_AK74, 24 * 1.004 * 1.1, 110, 100, -24, 0, 100, 100, 15, -2.5, 0, 0, 0, ALIVE);
  Kill(2, 1, WEP_AK74, 600, 100, 100, 100, EF_BULLET or ALIVE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    AlicePts0 := Points(1);
    R := LfOpenRecord(FightOf(1)^)^;
    Check('Alice''s death is recorded and open', (LfRecords(FightOf(1)^) = 1) and not R.Closed and
      (R.Kind = LFD_ENEMY) and (R.Killer = 2) and (R.KillerName = 'Bob') and (R.KillerWeapon = WEP_AK74) and
      (R.KillerFlags = 0) and (R.DeathTick = 572) and (R.LifeTick = 10) and (R.FromTick = 10) and
      (R.EndTick = 572 + 4 * 60) and R.StatsOn and (R.MapName = 'rscs_fight'));
    Check('Carl met the assist rule (45 of 65 health within 7 s), the bot is none',
      R.Assists = LongWord(1) shl (3 - 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { her grenade, fired before she died, kills Bob after her death }
  CurTick := 590;
  Damage(1, 2, WEP_M79, 60, 600, 100, 0, 0, 600, 100, 65 - 24 * 1.004 * 0.95, EF_B_ONGROUND);
  Kill(1, 2, WEP_M79, 80, 100, 600, 100, EF_BULLET);
  SecondAt(700);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('the window after the death still runs at +2 s', LfOpenRecord(FightOf(1)^) <> nil);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  SecondAt(900);
  LinesOf(1, L);
  LinesOf(2, L2);
  EnterCriticalSection(Engine.StateLock);
  try
    AlicePts1 := Points(1);
    R := LfRecordAt(FightOf(1)^, 1)^;
    RB := LfRecordAt(FightOf(2)^, 1)^;
    Check('closed after the window', R.Closed and RB.Closed and (LfOpenRecord(FightOf(1)^) = nil));
    k := FindEvent(R, LFE_TAKEN, 3, WEP_DEAGLES);
    Check('Carl''s two bullets are one line: 45 dmg, body and a zone not told, 290 px from his shot, 0.27 s, still',
      (k >= 0) and (R.Events[k].Count = 2) and Near(R.Events[k].Damage, 45, 0.01) and (R.Events[k].Zones[HZ_BODY] = 1) and
      (R.Events[k].Zones[HZ_UNKNOWN] = 1) and Near(R.Events[k].Dist, 290, 0.5) and (R.Events[k].Flags and LFF_DIST_EST = 0) and
      Near(R.Events[k].Flight, LfFlightSeconds(WEP_DEAGLES, 290), 0.001) and Near(R.Events[k].Speed, 0, 0.01) and
      Near(R.Events[k].Health, 65, 0.01) and (LfDodge(R.Events[k]) = 'hard (still)'));
    k := FindEvent(R, LFE_TAKEN, 7, -2);
    Check('the bot''s hit: marked, distance and flight from its bullet (~), her speed, a dodge', (k >= 0) and
      (R.Events[k].Flags and LFF_BOT <> 0) and (R.Events[k].Flags and LFF_DIST_EST <> 0) and
      Near(R.Events[k].Dist, Hypot(BotHX, BotHY), 1) and Near(R.Events[k].Flight, 20.5 / 60, 0.001) and
      Near(R.Events[k].Speed, 1.4 * 60 / 14, 0.01) and (R.Events[k].Text = 'Bot Boogie') and
      (LfDodge(R.Events[k]) = 'hard'));
    k := FindEvent(R, LFE_TAKEN, 2, WEP_AK74);
    Check('Bob''s hit killed her: the 15 health she had, the head, 490 px, 0.37 s, 11 m/s', (k >= 0) and
      (R.Events[k].Flags and LFF_LETHAL <> 0) and Near(R.Events[k].Damage, 15, 0.01) and (R.Events[k].LastZone = HZ_HEAD) and
      Near(R.Events[k].Dist, 490, 0.5) and Near(R.Events[k].Flight, 0.368, 0.005) and
      Near(R.Events[k].Speed, 2.5 * 60 / 14, 0.05) and (LfDodge(R.Events[k]) = 'hard'));
    k := FindEvent(R, LFE_DEALT, 2, WEP_AK74);
    Check('her hit on Bob before: 490 px from her shot, body', (k >= 0) and Near(R.Events[k].Dist, 490, 0.5) and
      (R.Events[k].Zones[HZ_BODY] = 1) and (R.Events[k].Flags and LFF_AFTER = 0));
    k := FindEvent(R, LFE_DEALT, 2, WEP_M79);
    Check('her grenade after her death: at most his health, the one that killed; nobody saw it fired and a blast ' +
      'tells no flight: no distance, never one from where she stood', (k >= 0) and
      (R.Events[k].Flags and LFF_AFTER <> 0) and (R.Events[k].Flags and LFF_LETHAL <> 0) and
      (R.Events[k].Dist < 0) and (R.Events[k].Flight < 0) and (R.Events[k].Flags and LFF_DIST_EST = 0) and
      Near(R.Events[k].Damage, 65 - 24 * 1.004 * 0.95, 0.01) and (LfDodge(R.Events[k]) = 'blast'));
    k := FindEvent(R, LFE_KILL, 2, WEP_M79);
    Check('the kill after her death is in her record', (k >= 0) and (R.Events[k].Flags and LFF_AFTER <> 0) and
      (R.Events[k].Tick = 590));
    NotePoints(R, Lost, Won);
    Check(Format('the points of the HUD: -%d for the death, +%d for the kill after it, as the account has them',
      [Lost, Won]), (Lost > 0) and (Won > 0) and (AlicePts1 - AlicePts0 = Won) and (AlicePts0 = 1000 - Lost));
    Check('Bob''s death: killed by Alice after her death, her grenade', (RB.Kind = LFD_ENEMY) and (RB.Killer = 1) and
      (RB.KillerFlags and LFF_AFTER <> 0) and (RB.KillerWeapon = WEP_M79) and (RB.Assists = 0));
    Check('Carl has no death, the assist is among his events', (LfRecords(FightOf(3)^) = 0) and
      (LfLatest(FightOf(3)^, LFE_NOTE, 0, 572) <> nil) and (FindEvent(R, LFE_NOTE, 0, -2) >= 0));
    Check('nothing for the bot, which dealt a hit', (FightOf(7)^.Count = 0) and (FightOf(7)^.Deaths = 0));
    Check('nothing for the spectator', (FightOf(4)^.Count = 0) and (FightOf(4)^.Deaths = 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  S1 := LineOf(L, 'Killed by Bob (');
  S2 := LineOf(L, 'You dealt');
  WriteLn('       ', S1);
  WriteLn('       ', S2);
  WriteLn('       ', LineOf(L2, 'Killed by'));
  Check('the summary: the killer, the weapon, the distance and zone of the lethal hit, his hits',
    Pos('Killed by Bob (AK-74, 35 m, head): 1 hit, 15 dmg (head)', S1) = 1);
  Check('the summary: who else hurt her and the points of the death',
    (Pos('; also hurt by Carl 45, Bot Boogie 5', S1) > 0) and (Pos(Format('; -%d pts', [Lost]), S1) > 0));
  Check('the summary: what she dealt, the kill after her death, the points, the hint',
    (Pos('You dealt 65 dmg: Bob 65; killed Bob after your death', S2) = 1) and (Pos(Format('; +%d pts', [Won]), S2) > 0) and
    (Pos(' - details: !lastfight', S2) > 0));
  Check('the summary: two lines within LINE_W, once', (Length(S1) <= LINE_W) and (Length(S2) <= LINE_W) and
    (CountOf(L, 'Killed by') = 1) and (CountOf(L, 'You dealt') = 1));
  Check('Bob''s summary: killed by a grenade of the dead',
    Pos('Killed by Alice (M79) after his death: 2 hits, 65 dmg (body)', LineOf(L2, 'Killed by')) = 1);
  LinesOf(3, L);
  LinesOf(4, L2);
  Check('no summary for the living and the spectator', not Has(L, 'Killed by') and (L2.Count = 0));
  SecondAt(960);
  LinesOf(1, L);
  Check('the summary comes once', not Has(L, 'Killed by'));

  { the report }
  RunCmd(1, '!lastfight', L);
  Show(L);
  Check('report: header, when and where', Has(L, '[ Last Fight 1/1: Alice ]') and Has(L, 'Died just now (') and
    Has(L, ' on rscs_fight, 9s into the life'));
  Check('report: the killer and the lethal hit', Has(L, 'Killed by Bob with AK-74') and
    Has(L, 'The hit that killed you: 15 dmg to the head from 35 m, you had 15 HP'));
  Check('report: the timeline', Has(L, 'Timeline (seconds from the death, 10 s before to 4 s after)') and
    Has(L, 'hit you x2') and Has(L, 'killed you') and Has(L, 'you hit') and Has(L, 'you killed') and
    Has(L, 'Bot Boogie') and Has(L, 'hard (still)') and Has(L, 'after death') and Has(L, 'points'));
  Check('report: the timeline begins with the first event of her life', Has(L, ' -7.53 you hit'));
  Check('report: who hurt her, with the roles', Has(L, 'Who hurt you') and (Pos('killer', RowOf(L, 'Bob')) > 0) and
    (Pos('assist', RowOf(L, 'Carl')) > 0) and (Pos(' bot ', RowOf(L, 'Bot Boogie')) > 0));
  Check('report: the shares of the damage', (Pos('23%', RowOf(L, 'Bob')) > 0) and (Pos('69%', RowOf(L, 'Carl')) > 0) and
    (Pos('8%', RowOf(L, 'Bot Boogie')) > 0));
  Check('report: what she dealt and the kill after her death', Has(L, 'What you dealt') and
    Has(L, 'killed +0.30 s after your death'));
  Check('report: the points', Has(L, Format('Points: -%d for the death, +%d won (+%d after it)', [Lost, Won, Won])));
  { the columns of the timeline: 7, 16, 14, 9, 6, 4, 8, 7, 8, 7 and the dodge }
  Lr := RowOf(L, '  Time');
  Check('report: the columns of the timeline', (Pos('Event', Lr) = 8) and (Pos('Player', Lr) = 24) and
    (Pos('Weapon', Lr) = 38) and (Pos(' HP', Lr) = 53) and (Pos('Zone', Lr) = 57) and (Pos('Dist', Lr) = 65) and
    (Pos('Flight', Lr) = 72) and (Pos('Speed', Lr) = 80) and (Pos('Dodge (est.)', Lr) = 87));
  Lr := LineOf2(L, 'you hit', 'Bob');
  Check('report: her hit on Bob - from where she fired, its flight, his speed, could he dodge',
    (Copy(Lr, 65, 5) = '35 m ') and (Copy(Lr, 72, 7) = '0.37 s ') and (Copy(Lr, 80, 6) = '0 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'hard (still)'));
  Lr := LineOf2(L, 'hit you', 'Bot Boogie');
  Check('report: the bot''s hit - distance and flight from its bullet (~), her speed, the dodge',
    (Copy(Lr, 65, 6) = '~36 m ') and (Copy(Lr, 72, 8) = '~0.34 s ') and (Copy(Lr, 80, 6) = '6 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'hard'));
  Lr := LineOf2(L, 'killed you', 'Bob');
  Check('report: Bob''s hit that killed her - his shot, the flight, her speed running',
    (Copy(Lr, 65, 5) = '35 m ') and (Copy(Lr, 72, 7) = '0.37 s ') and (Copy(Lr, 80, 7) = '11 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'hard'));
  Check('report: the legend says what every column is and what is estimated',
    Has(L, 'Time: s from your death (+ = after it)  HP: health before the hit  Zone: ~ = a guess, ? = not told') and
    (LineOf(L, 'Dist: ') = 'Dist: from where the shot was fired to the hit  Flight: time in the air') and
    Has(L, '~ = worked out from the bullet at the hit (nobody saw the shot, e.g. a bot''s): within a few m') and
    Has(L, 'Speed: of the one who was hit  Dodge (est.): under 0.25 s of flight no, to 0.4 s hard, then maybe') and
    Has(L, 'No flight or dodge for blasts, flames, blades, thrown knives; no ~ for Spas  (still) = stood still'));
  Check('report: every line within LINE_W, tidy', Tidy(L));
  RunCmd(1, '!lastfight 2', L);
  Check('only one death so far', Has(L, 'Only your last death is recorded so far: !lastfight 1.'));
  RunCmd(1, '!lastfight x', L);
  Check('usage for a wrong number', Has(L, 'Usage: !lastfight [1-3]'));
  RunCmd(1, '!lastfight 4', L);
  Check('usage past the deaths kept', Has(L, 'Usage: !lastfight [1-3]'));
  RunCmd(4, '!lastfight', L);
  Check('a spectator without a death', Has(L, 'No death of yours is recorded yet'));
  RunCmd(0, '/lastfight', L);
  Check('the server console has no deaths', Has(L, '!lastfight is for players on the server'));
  RunCmd(1, '!zitro', L);
  Check('!zitro names it and says what it is', Has(L, '!lastfight [1-3]') and
    Has(L, '!lastfight [1-3] = your last deaths (1 = the last)') and Tidy(L));

  { ---- the kinds of deaths: a selfkill, no weapon, a teammate, the server's own kill, a killer who
    left; a quick respawn; the last three kept ---- }
  CurTick := 1000;
  MapAfter('ctf_fight', GS_CTF, 8);
  TeamEv(1, TEAM_ALPHA);
  TeamEv(2, TEAM_BRAVO);
  TeamEv(3, TEAM_ALPHA);
  CurTick := 1010;
  Spawn(1, WEP_M79, 100, 100);
  Spawn(2, WEP_AK74, 600, 100);
  Spawn(3, WEP_M79, 150, 100);
  CurTick := 1100;
  Damage(1, 1, WEP_M79, 40, 100, 100, 0, 0, 100, 100, 150, ALIVE);
  Kill(1, 1, WEP_M79, 100, 100, 100, 100, EF_BULLET or ALIVE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(1)^, 1)^;
    Check('a selfkill: his own weapon, his own hit killed', (LfRecords(FightOf(1)^) = 2) and (R.Kind = LFD_SELF) and
      (R.Killer = 1) and (R.KillerWeapon = WEP_M79) and (FindEvent(R, LFE_TAKEN, 1, WEP_M79) < 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the respawn closes the window at once }
  CurTick := 1160;
  Spawn(1, WEP_AK74, 100, 100);
  SecondAt(1170);
  LinesOf(1, L);
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(1)^, 1)^;
    k := FindEvent(R, LFE_TAKEN, 1, WEP_M79);
    Check('the respawn closes the record, with his own hit that killed', R.Closed and (k >= 0) and
      (R.Events[k].Flags and (LFF_SELF or LFF_LETHAL) = LFF_SELF or LFF_LETHAL));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('and the summary follows', Has(L, 'You killed yourself (M79): 1 hit, 40 dmg'));
  { a death without a weapon }
  CurTick := 1200;
  Kill(1, 1, WEP_WORLD, 100, 100, 100, 100, ALIVE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(1)^, 1)^;
    Check('no weapon: a fall, the map or a script', (LfRecords(FightOf(1)^) = 3) and (R.Kind = LFD_WORLD) and
      (R.Killer = 0) and (R.LifeTick = 1160) and (R.FromTick = 1160));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { a quick respawn and a teammate's grenade: the death before is complete when the next one comes }
  CurTick := 1230;
  Spawn(1, WEP_AK74, 100, 100);
  CurTick := 1250;
  Damage(3, 1, WEP_M79, 150, 100, 100, 0, 0, 100, 100, 150, ALIVE);
  Kill(3, 1, WEP_M79, 150, 100, 100, 100, EF_BULLET or ALIVE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(1)^, 2)^;
    Check('the death before closed at the next one, its window cut at the respawn', R.Closed and (R.Kind = LFD_WORLD) and
      (FindEvent(R, LFE_TAKEN, 3, -2) < 0));
    R := LfRecordAt(FightOf(1)^, 1)^;
    Check('a teammate: marked, no assist', (R.Kind = LFD_TEAM) and (R.Killer = 3) and (R.KillerFlags and LFF_MATE <> 0) and
      (R.Assists = 0));
    Check('the last three deaths are kept', (LfRecords(FightOf(1)^) = LF_DEATHS) and (FightOf(1)^.Deaths = 4) and
      (LfRecordAt(FightOf(1)^, 3)^.Kind = LFD_SELF));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  RunCmd(1, '!lastfight 1', L);
  Check('report of a teamkill', Has(L, '[ Last Fight 1/3: Alice ]') and Has(L, 'Killed by your teammate Carl with M79') and
    (Pos('killer', RowOf(L, 'Carl')) > 0) and Has(L, 'blast') and Tidy(L));
  Lr := LineOf2(L, 'killed you', 'Carl');
  Check('report of a teamkill: the teammate by his name, a grenade nobody saw fired has no distance or flight',
    (Copy(Lr, 24, 12) = 'Carl (mate) ') and (Trim(Copy(Lr, 65, 15)) = '') and (Copy(Lr, 80, 6) = '0 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'blast') and
    Has(L, 'Dist: from where the shot was fired to the hit  Flight: time in the air  (mate) = a teammate'));
  Check('its window still runs', Has(L, 'The seconds after this death are still being recorded'));
  RunCmd(1, '!lastfight 3', L);
  Check('the oldest one kept: the selfkill', Has(L, '[ Last Fight 3/3: Alice ]') and
    Has(L, 'You killed yourself with M79') and (Pos('yourself', RowOf(L, 'Alice')) > 0) and Has(L, 'own hit') and
    Has(L, ' self') and Tidy(L));
  RunCmd(1, '!lastfight 2', L);
  Check('no weapon, nothing hit her', Has(L, 'You died without a weapon hit') and Has(L, 'Nobody hit you in these seconds.') and
    Tidy(L));
  { the server's own kill (the end of a survival round, a team change) is no death }
  EnterCriticalSection(Engine.StateLock);
  try
    Deaths0 := FightOf(2)^.Deaths;
    Count0 := FightOf(2)^.Count;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 1300;
  Kill(2, 2, WEP_AK74, 600, 100, 600, 100, EF_SERVER_KILL);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Check('the server''s own kill leaves nothing', (FightOf(2)^.Deaths = Deaths0) and (FightOf(2)^.Count = Count0) and
      (Deaths0 = 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the killer left in that moment: the last hit of his slot says who it was }
  CurTick := 1310;
  Damage(2, 3, WEP_AK74, 30, 150, 100, -24, 0, 150, 100, 150, ALIVE);
  LeaveEv(2);
  Kill(2, 3, WEP_AK74, 600, 100, 150, 100, EF_BULLET or ALIVE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(3)^, 1)^;
    Check('a killer who left: his name from his last hit', (R.Kind = LFD_LEFT) and (R.Killer = 2) and
      (R.KillerName = 'Bob'));
    Check('a leave clears the slot', (FightOf(2)^.Deaths = 0) and (FightOf(2)^.Count = 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  SecondAt(1600);
  LinesOf(3, L);
  { his shot of long ago is no shot of this bullet: the bullet itself tells the distance }
  Check('the summary of a killer who left', Has(L, 'Killed by Bob (AK-74, ~5 m), who left: 1 hit, 30 dmg'));
  RunCmd(3, '!lastfight', L);
  Check('report of a killer who left', Has(L, 'Killed by Bob, who left the server, with AK-74') and Tidy(L));

  { ---- the settings: no summary, then nothing at all; a bot and long names in the report ---- }
  CurTick := 2000;
  MapAfter('dm_fight', GS_DM, 0);
  Join(2, LONG_NAME, 'S3005', TEAM_NONE);
  JoinBot(8, 'Bot ' + LONG_NAME, TEAM_NONE);
  TeamEv(1, TEAM_NONE);
  TeamEv(3, TEAM_NONE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.LastFightSummary := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 2010;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(2, WEP_BARRETT, 1500, 100);
  Spawn(3, WEP_AK74, 150, 100);
  CurTick := 2100;
  Shot(2, WEP_BARRETT, 1500, 100);
  CurTick := 2120;
  Sample(3, 150, 100);
  CurTick := 2130;
  Damage(8, 3, WEP_MINIGUN, 13, 150, 100, 29, 0, 150, 100, 150, ALIVE);
  Damage(2, 3, WEP_BARRETT, 150, 160, 100, -50, 0, 150, 100, 137, ALIVE);
  Kill(2, 3, WEP_BARRETT, 1500, 100, 150, 100, EF_BULLET or ALIVE);
  SecondAt(2500);
  LinesOf(3, L);
  Check('DeathSummary = 0: no lines after the death', not Has(L, 'Killed by'));
  RunCmd(3, '!lastfight', L);
  Show(L);
  Check('but the report, with a long name and a bot', Has(L, 'Killed by ' + LONG_NAME + ' with Barrett M82A1') and
    Has(L, 'The hit that killed you: 137 dmg from 96 m, you had 137 HP') and
    (RowOf(L, 'Bot LongNameLongNa') <> '') and Has(L, 'maybe (still)') and Tidy(L));
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.LastFightEnabled := False;
    Deaths0 := FightOf(3)^.Deaths;
    Count0 := FightOf(3)^.Count;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 2600;
  Spawn(3, WEP_AK74, 150, 100);
  CurTick := 2650;
  Damage(2, 3, WEP_BARRETT, 150, 160, 100, -50, 0, 150, 100, 150, ALIVE);
  Kill(2, 3, WEP_BARRETT, 1500, 100, 150, 100, EF_BULLET or ALIVE);
  WaitProcessed;
  EnterCriticalSection(Engine.StateLock);
  try
    Check('Enabled = 0: nothing is recorded', (FightOf(3)^.Deaths = Deaths0) and (FightOf(3)^.Count = Count0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  RunCmd(3, '!lastfight', L);
  Check('Enabled = 0: the command says it is off', Has(L, '!lastfight is switched off on this server.'));
  RunCmd(3, '!zitro', L);
  Check('Enabled = 0: !zitro does not name it', not Has(L, '!lastfight') and Has(L, '!achlisti n*'));
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.LastFightEnabled := True;
    Engine.Cfg.LastFightSummary := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- a long fight: more hits than the ring holds; the report says what it leaves out ---- }
  CurTick := 3000;
  Spawn(3, WEP_MINIGUN, 150, 100);
  for i := 1 to LF_RING + 20 do
  begin
    { four ticks apart: every bullet a line of its own }
    CurTick := 3000 + i * 4;
    Damage(3, 1, WEP_MINIGUN, 0.5, 100, 100, -29, 0, 100, 100, 150, ALIVE);
  end;
  CurTick := 3000 + (LF_RING + 21) * 4;
  Damage(3, 1, WEP_KNIFE, 150, 100, 100, 0, 0, 100, 100, 100, ALIVE);
  Kill(3, 1, WEP_KNIFE, 100, 100, 100, 100, ALIVE);
  SecondAt(4000);
  LinesOf(1, L);
  S1 := LineOf(L, 'Killed by Carl (');
  WriteLn('       ', S1);
  Check('a long fight: the summary within LINE_W', (S1 <> '') and (Length(S1) <= LINE_W));
  RunCmd(1, '!lastfight', L);
  Check('a long fight: the newest lines, the rest said', Has(L, 'earlier events of these seconds are not shown') and
    Has(L, 'melee') and (CountOf(L, ' hit you') <= 12) and Tidy(L));
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(1)^, 1)^;
    Check('a long fight: the record is full and counts what it misses', (R.Count = LF_EVENTS) and (R.Missed > 0) and
      (R.Events[R.Count - 1].Tick >= R.DeathTick));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { three pellets of one shot of the Spas-12 kill: one line, the shot that killed }
  CurTick := 3600;
  Spawn(1, WEP_AK74, 100, 100);
  CurTick := 3620;
  Shot(3, WEP_SPAS, 150, 100);
  CurTick := 3624;
  for i := 0 to 2 do
    Damage(3, 1, WEP_SPAS, 20, 110, 100, -14, 0, 100, 100, 60 - i * 20, ALIVE);
  Kill(3, 1, WEP_SPAS, 150, 100, 100, 100, EF_BULLET or ALIVE);
  WaitProcessed;
  RunCmd(1, '!lastfight', L);
  Check('a shot of pellets that killed: its hits together', Has(L, 'The shot that killed you: 3 hits, 60 dmg (3?) from 3 m') and
    Has(L, 'killed you x3') and Has(L, ' no') and Tidy(L));

  { a player who goes to the spectators after his death hears nothing; his report is still there }
  CurTick := 4100;
  TeamEv(4, TEAM_NONE);
  Spawn(4, WEP_AK74, 300, 100);
  CurTick := 4150;
  Damage(3, 4, WEP_MINIGUN, 150, 300, 100, 29, 0, 300, 100, 150, ALIVE);
  Kill(3, 4, WEP_MINIGUN, 150, 100, 300, 100, EF_BULLET or ALIVE);
  CurTick := 4160;
  TeamEv(4, TEAM_SPEC);
  SecondAt(4500);
  LinesOf(4, L);
  Check('no summary for a player who went to the spectators', not Has(L, 'Killed by'));
  RunCmd(4, '!lastfight', L);
  Check('his report is still there', Has(L, '[ Last Fight 1/1: Dave ]') and Has(L, 'Killed by Carl with XM214 Minigun') and
    Tidy(L));

  { ---- the hits both ways have the same cells. Alice hits the bot from her shot (the bot's speed at
    the hit); the bot hits her from a shot nobody saw - its bullet tells where it came from, with the
    bot's velocity - and once more after its death, when its body's velocity says nothing; Carl's
    Barrett kills her from his shot, and his line of that hit has what hers has ---- }
  CurTick := 5000;
  MapAfter('dm_both', GS_DM, 0);
  CurTick := 5010;
  Spawn(1, WEP_AK74, 100, 100);
  Spawn(3, WEP_BARRETT, 1100, 100);
  CurTick := 5100;
  Shot(1, WEP_AK74, 100, 100);
  CurTick := 5115;
  DamageMoving(1, 7, WEP_AK74, 20, 450, 100, 21, 1, 450, 100, 150, 5, 0, 0, 0, ALIVE);
  CurTick := 5200;
  SimBullet(27, 0, 0.5, 3, 0, 20, HX1, HY1, VX1, VY1);
  DamageMoving(7, 1, WEP_MINIMI, 10, 100, 100, VX1, VY1, 100, 100, 130, 0, -4, 3, 0, ALIVE);
  CurTick := 5230;
  SimBullet(27, 0, 0.5, 0, 0, 12, HX2, HY2, VX2, VY2);
  DamageMoving(7, 1, WEP_MINIMI, 10, 100, 100, VX2, VY2, 100, 100, 120, 0, 0, 9, 0, EF_A_ONGROUND or EF_B_ONGROUND);
  CurTick := 5300;
  Shot(3, WEP_BARRETT, 1100, 100);
  CurTick := 5320;
  DamageMoving(3, 1, WEP_BARRETT, 110, 110, 100, -45, 0, 100, 100, 110, 0, 0, 0, 0, ALIVE);
  Kill(3, 1, WEP_BARRETT, 1100, 100, 100, 100, EF_BULLET or ALIVE);
  SecondAt(5700);
  EnterCriticalSection(Engine.StateLock);
  try
    R := LfRecordAt(FightOf(1)^, 1)^;
    k := FindEventAt(R, LFE_DEALT, 7, 5115);
    Check('you hit: the bot from her shot - 350 px, its flight, the bot''s speed, hard to dodge', (k >= 0) and
      Near(R.Events[k].Dist, 350, 0.5) and (R.Events[k].Flags and LFF_DIST_EST = 0) and
      Near(R.Events[k].Flight, LfFlightSeconds(WEP_AK74, 350), 0.001) and Near(R.Events[k].Speed, 5 * 60 / 14, 0.01) and
      (R.Events[k].Flags and LFF_BOT <> 0) and (LfDodge(R.Events[k]) = 'hard'));
    k := FindEventAt(R, LFE_TAKEN, 7, 5200);
    Check('hit you: the bot''s shot from its bullet and its velocity (~), her speed jumping, hard to dodge', (k >= 0) and
      (R.Events[k].Flags and LFF_DIST_EST <> 0) and Near(R.Events[k].Dist, Hypot(HX1, HY1), 1) and
      Near(R.Events[k].Flight, 20.5 / 60, 0.001) and Near(R.Events[k].Speed, 4 * 60 / 14, 0.01) and
      (LfDodge(R.Events[k]) = 'hard'));
    k := FindEventAt(R, LFE_TAKEN, 7, 5230);
    Check('hit you: a bullet of the dead bot - the velocity of its body is left out', (k >= 0) and
      (R.Events[k].Flags and (LFF_DIST_EST or LFF_AFTER) = LFF_DIST_EST or LFF_AFTER) and
      Near(R.Events[k].Dist, Hypot(HX2, HY2), 1) and Near(R.Events[k].Flight, 12.5 / 60, 0.001) and
      (LfDodge(R.Events[k]) = 'no'));
    k := FindEventAt(R, LFE_TAKEN, 3, 5320);
    Check('killed you: Carl''s Barrett from his shot, 990 px, she stood still', (k >= 0) and
      (R.Events[k].Flags and LFF_LETHAL <> 0) and Near(R.Events[k].Dist, 990, 0.5) and
      Near(R.Events[k].Flight, LfFlightSeconds(WEP_BARRETT, 990), 0.001) and Near(R.Events[k].Speed, 0, 0.01) and
      (LfDodge(R.Events[k]) = 'hard (still)'));
    Pd := LfLatest(FightOf(3)^, LFE_DEALT, 1, 5300);
    Pk := LfLatest(FightOf(3)^, LFE_KILL, 1, 5300);
    Check('Carl''s line of that hit has the same distance, flight, speed and dodge, and his kill as well',
      (k >= 0) and (Pd <> nil) and (Pk <> nil) and Near(Pd^.Dist, 990, 0.5) and
      Near(Pd^.Flight, R.Events[k].Flight, 0.0001) and Near(Pd^.Speed, 0, 0.01) and (LfDodge(Pd^) = 'hard (still)') and
      Near(Pk^.Dist, 990, 0.5) and Near(Pk^.Flight, Pd^.Flight, 0.0001) and Near(Pk^.Speed, 0, 0.01));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  RunCmd(1, '!lastfight', L);
  Show(L);
  Lr := LineOf2(L, 'you hit', 'Bot Boogie');
  Check('report: you hit - the distance of her shot, its flight, the speed of the one hit and his dodge',
    (Copy(Lr, 65, 5) = '25 m ') and (Copy(Lr, 72, 7) = '0.25 s ') and (Copy(Lr, 80, 7) = '21 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'hard'));
  Lr := LineOf2(L, 'hit you', 'Bot Boogie');
  Check('report: hit you by the bot - worked out from its bullet (~), her speed, her dodge',
    (Copy(Lr, 65, 6) = '~38 m ') and (Copy(Lr, 72, 8) = '~0.34 s ') and (Copy(Lr, 80, 7) = '17 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'hard'));
  Lr := LineOf2(L, 'killed you', 'Carl');
  Check('report: killed you - Carl''s shot, its flight, she stood still',
    (Copy(Lr, 65, 5) = '71 m ') and (Copy(Lr, 72, 7) = '0.33 s ') and (Copy(Lr, 80, 6) = '0 m/s ') and
    (Copy(Lr, 87, MaxInt) = 'hard (still)'));
  Check('report: no teammates in a deathmatch, every line tidy', not Has(L, '(mate)') and Tidy(L));

  { a player who leaves takes his deaths with him; the next one in the slot has none }
  LeaveEv(1);
  Join(1, 'Newcomer', 'S3009', TEAM_NONE);
  RunCmd(1, '!lastfight', L);
  Check('the next player in the slot has no deaths', Has(L, 'No death of yours is recorded yet'));
  Fresh;
  Check('no engine errors', (Pos('internal error', AllOut.Text) = 0) and (Pos('ERROR', AllOut.Text) = 0));

  Engine.Free;
  L.Free;
  L2.Free;
  AllOut.Free;
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
