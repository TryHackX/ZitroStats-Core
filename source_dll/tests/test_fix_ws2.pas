program test_fix_ws2;

{ Regression tests of the audit fixes of workstream 2 (ZitroStats 5.7): a restart in the middle of a
  map, the time on the names, the events queued before a shutdown, errors in the handlers, /pause, the
  season announcement, the tick counter of the server starting again, the limit of the event queue,
  the distance of a script's bullet, the admins, a shutdown during the load, the output queue and the
  log lines. Every part runs an engine of its own in a folder of its own. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, dynlibs, zs_types, zs_util, zs_db, zs_engine, zs_weapons, zs_live, zs_config;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console: TStringList;
  Root: AnsiString;
  DllPath: AnsiString;

type
  { calls Engine.Shutdown from a thread of its own, as the game thread does at a /recompile }
  TStopper = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TStopper.Execute;
begin
  Engine.Shutdown;
end;

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

function FileText(const Path: AnsiString): AnsiString;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
      Result := L.Text;
    except
      Result := '';
    end;
  finally
    L.Free;
  end;
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
    if MonoMs - T0 > 30000 then
      Exit(False);
    Sleep(5);
  end;
  Sleep(100);
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

function SeenCount(const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to Console.Count - 1 do
    if Pos(Part, Console[k]) > 0 then
      Inc(Result);
end;

{ an engine of its own in Root\Name (a fresh folder unless Keep), its data under the working folder }
procedure StartEngine(const Name: AnsiString; Keep: Boolean);
var
  Dir: AnsiString;
begin
  Dir := Root + PathDelim + Name;
  if not Keep then
    DeleteTree(Dir);
  ForceDirectories(Dir + PathDelim + 'script');
  SetCurrentDir(Dir);
  Engine := TZSEngine.Create(Dir + PathDelim + 'script');
  Pushed := 0;
  Console.Clear;
  Engine.Start;
end;

procedure StopEngine;
begin
  FreeAndNil(Engine);
end;

procedure MapAfterFlags(const Name: AnsiString; Style, Limit, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := Limit;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure MapBefore(A, B, TimeLeft, Limit: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapBefore);
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Ev.I[5] := Limit;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam: AnsiString; Team, Admin: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := 'HW' + Steam;
  Ev.S4 := Format('10.0.0.%d', [Slot]);
  Ev.I[0] := Team;
  Ev.I[1] := 1;
  Ev.I[2] := Admin;
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

procedure Spawn(Slot: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSpawn);
  Ev.Slot := Slot;
  Ev.I[0] := WEP_AK74;
  Ev.I[1] := WEP_SOCOM;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure Sample(Slot, Flags: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSample);
  Ev.Slot := Slot;
  Ev.I[0] := Flags;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := 30;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure Flag(Slot, Kind: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeFlag);
  Ev.Slot := Slot;
  Ev.I[0] := Kind;
  Push(Ev);
end;

procedure Damage(S, V, Weapon: LongInt; Dmg, BX, BY, BVX, VX, VY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeDamage);
  Ev.Slot := S;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := EF_BULLET or EF_B_ONGROUND;
  Ev.F[0] := Dmg;
  Ev.F[2] := BX;
  Ev.F[3] := BY;
  Ev.F[4] := BVX;
  Ev.F[6] := VX;
  Ev.F[7] := VY;
  Push(Ev);
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
  Ev.I[2] := Flags or EF_A_ALIVE or EF_A_ONGROUND;
  Ev.I[3] := WEP_AK74;
  Ev.F[0] := KX;
  Ev.F[1] := KY;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Ev.F[4] := VX;
  Ev.F[5] := VY;
  Push(Ev);
end;

{ ZS_Ev_Tick: the team scores, the time left and (API 17) whether the game is paused }
procedure TickEv(A, B, TimeLeft, Paused: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTick);
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Ev.I[6] := Paused;
  Push(Ev);
end;

function Prof(const Steam: AnsiString): PPlayerProfile;
var
  Idx: LongInt;
begin
  Idx := Engine.DB.IndexOfSteam(Steam);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx]
  else
    Result := nil;
end;

{ the seconds the account of Steam has on its name Name (OtherNames), -1 = no such name }
function NameTime(const Steam, Name: AnsiString): Int64;
var
  P: PPlayerProfile;
  k: LongInt;
begin
  Result := -1;
  P := Prof(Steam);
  if P = nil then
    Exit;
  for k := 0 to High(P^.OtherNames) do
    if OtherDataToString(P^.OtherNames[k]) = Name then
      Exit(P^.OtherNames[k].TimePlayed);
end;

const
  STEAMS: array[1..4] of AnsiString = ('S2001', 'S2002', 'S2003', 'S2004');
  NAMES: array[1..4] of AnsiString = ('Alpha1', 'Alpha2', 'Bravo1', 'Bravo2');

{ Alpha1 and Alpha2 for Alpha, Bravo1 and Bravo2 for Bravo, all alive }
procedure JoinFour;
var
  i: LongInt;
begin
  for i := 1 to 4 do
    Join(i, NAMES[i], STEAMS[i], TEAM_ALPHA + Ord(i > 2), 0);
  for i := 1 to 4 do
    Spawn(i, 100 * i, 100);
end;

{ ---- ZSE1-01: a restart in the middle of a map (every /recompile) ---- }

procedure TestRestart;
var
  Snap: array[1..4] of TPlayerProfile;
  Loads0, M, i: LongInt;
  Same: Boolean;

  procedure TakeSnap;
  var
    k: LongInt;
  begin
    for k := 1 to 4 do
      Snap[k] := Prof(STEAMS[k])^;
  end;

begin
  StartEngine('restart', False);
  Check('ZSE1-01 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Run', GS_CTF, 10, MF_SURVIVAL);
  JoinFour;
  CurTick := 1060;
  TickEv(0, 0, 600, 0);
  CurTick := 1100;
  Kill(1, 3, WEP_AK74, 100, 100, 300, 100, 0);
  CurTick := 1120;
  TickEv(1, 0, 590, 0);
  Check('ZSE1-01 the match before the restart processed', WaitProcessed);
  StopEngine;

  { CTF survival: the engine starts again at 3:2 }
  StartEngine('restart', True);
  Check('ZSE1-01 restart ready', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap('ctf_Run', False);
    Loads0 := Engine.DB.Maps[M].LoadCount;
    TakeSnap;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 5000;
  MapAfterFlags('ctf_Run', GS_CTF, 10, MF_SURVIVAL or MF_RUNNING);
  JoinFour;
  CurTick := 5060;
  TickEv(3, 2, 400, 0);
  CurTick := 5100;
  Kill(2, 4, WEP_AK74, 200, 100, 400, 100, 0);
  Check('ZSE1-01 restart at 3:2 processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Same := True;
    for i := 1 to 4 do
      if (Prof(STEAMS[i])^.RoundsWins <> Snap[i].RoundsWins) or (Prof(STEAMS[i])^.RoundsLose <> Snap[i].RoundsLose) then
        Same := False;
    Check('ZSE1-01 CTF survival 3:2 after a restart: no round won or lost by anybody', Same);
    Check('ZSE1-01 no "Round won by" after the restart', SeenCount('Round won by') = 0);
    Check('ZSE1-01 the first kill after the restart is no second first blood',
      (Prof(STEAMS[2])^.FirstBloodCount = Snap[2].FirstBloodCount) and
      (Prof(STEAMS[2])^.RoundFirstBloodCount = Snap[2].RoundFirstBloodCount) and
      (Prof(STEAMS[2])^.Kills = Snap[2].Kills + 1));
    Check('ZSE1-01 the restart is no load of the map', Engine.DB.Maps[M].LoadCount = Loads0);
    TakeSnap;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the next round after the restart counts as before }
  CurTick := 5120;
  TickEv(4, 2, 390, 0);
  Check('ZSE1-01 the next round processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Check('ZSE1-01 a round after the restart counts: Alpha won, Bravo lost',
      (Prof(STEAMS[1])^.RoundsWins = Snap[1].RoundsWins + 1) and (Prof(STEAMS[2])^.RoundsWins = Snap[2].RoundsWins + 1) and
      (Prof(STEAMS[3])^.RoundsLose = Snap[3].RoundsLose + 1) and (Prof(STEAMS[4])^.RoundsLose = Snap[4].RoundsLose + 1) and
      (Prof(STEAMS[1])^.RoundsLose = Snap[1].RoundsLose) and (Prof(STEAMS[3])^.RoundsWins = Snap[3].RoundsWins));
    Check('ZSE1-01 and is announced once', SeenCount('Round won by Alpha') = 1);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;

  { CTF survival at 1:0 }
  StartEngine('restart', True);
  Check('ZSE1-01 second restart ready', WaitReady);
  EnterCriticalSection(Engine.StateLock);
  try
    TakeSnap;
    Loads0 := Engine.DB.Maps[Engine.DB.FindMap('ctf_Run', False)].LoadCount;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 9000;
  MapAfterFlags('ctf_Run', GS_CTF, 10, MF_SURVIVAL or MF_RUNNING);
  JoinFour;
  CurTick := 9060;
  TickEv(1, 0, 400, 0);
  Check('ZSE1-01 restart at 1:0 processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Same := True;
    for i := 1 to 4 do
      if (Prof(STEAMS[i])^.RoundsWins <> Snap[i].RoundsWins) or (Prof(STEAMS[i])^.RoundsLose <> Snap[i].RoundsLose) then
        Same := False;
    Check('ZSE1-01 CTF survival 1:0 after a restart: no phantom round', Same and (SeenCount('Round won by') = 0));
    Check('ZSE1-01 LoadCount unchanged again',
      Engine.DB.Maps[Engine.DB.FindMap('ctf_Run', False)].LoadCount = Loads0);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { Hold the Flag at 40:25: the carrier and the teams get no points of the past }
  CurTick := 9100;
  MapBefore(1, 0, 300, 10);
  MapAfterFlags('htf_Run', GS_HTF, 80, 0);
  CurTick := 9160;
  TickEv(0, 0, 600, 0);
  Check('ZSE1-01 htf map processed', WaitProcessed);
  StopEngine;
  StartEngine('restart', True);
  Check('ZSE1-01 htf restart ready', WaitReady);
  EnterCriticalSection(Engine.StateLock);
  try
    TakeSnap;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 12000;
  MapAfterFlags('htf_Run', GS_HTF, 80, MF_RUNNING);
  JoinFour;
  CurTick := 12010;
  Flag(1, FLAG_GRAB);
  Sample(1, EF_A_ALIVE or EF_A_FLAGGER or EF_A_ONGROUND, 100, 100);
  CurTick := 12060;
  TickEv(40, 25, 400, 0);
  Check('ZSE1-01 htf restart at 40:25 processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Same := True;
    for i := 1 to 4 do
      if (Prof(STEAMS[i])^.HTFMode.PointsScored <> Snap[i].HTFMode.PointsScored) or
         (Prof(STEAMS[i])^.HTFMode.TeamPointsScored <> Snap[i].HTFMode.TeamPointsScored) then
        Same := False;
    Check('ZSE1-01 HTF 40:25 after a restart: no HTF or team points', Same);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 12120;
  TickEv(41, 25, 399, 0);
  Check('ZSE1-01 htf point processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('ZSE1-01 a point after the restart goes to the carrier and his team',
      (Prof(STEAMS[1])^.HTFMode.PointsScored = Snap[1].HTFMode.PointsScored + 1) and
      (Prof(STEAMS[1])^.HTFMode.TeamPointsScored = Snap[1].HTFMode.TeamPointsScored + 1) and
      (Prof(STEAMS[2])^.HTFMode.TeamPointsScored = Snap[2].HTFMode.TeamPointsScored + 1) and
      (Prof(STEAMS[3])^.HTFMode.TeamPointsScored = Snap[3].HTFMode.TeamPointsScored));
    TakeSnap;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { an ordinary map change is as it was: a load, and the first kill is the first blood }
  CurTick := 12200;
  MapBefore(41, 25, 300, 80);
  MapAfterFlags('ctf_Next', GS_CTF, 10, 0);
  for i := 1 to 4 do
    Spawn(i, 100 * i, 100);
  CurTick := 12300;
  Kill(3, 1, WEP_AK74, 300, 100, 100, 100, 0);
  CurTick := 12320;
  TickEv(0, 0, 600, 0);
  Check('ZSE1-01 map change processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap('ctf_Next', False);
    Check('ZSE1-01 an ordinary map change: one load, the first kill is the first blood',
      (M >= 0) and (Engine.DB.Maps[M].LoadCount = 1) and
      (Prof(STEAMS[3])^.FirstBloodCount = Snap[3].FirstBloodCount + 1));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
end;

{ ---- ZSE1-02: the time on the name of a player who is still on the server at a shutdown ---- }

procedure TestNameTime;
var
  i: LongInt;
  Played: Int64;
begin
  StartEngine('names', False);
  Check('ZSE1-02 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Names', GS_CTF, 10, 0);
  JoinFour;
  for i := 1 to 10 do
  begin
    CurTick := 1000 + i * 60;
    TickEv(0, 0, 600 - i, 0);
  end;
  Check('ZSE1-02 ten seconds processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Played := Prof(STEAMS[1])^.TimePlayed;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
  StartEngine('names', True);
  Check('ZSE1-02 restart ready', WaitReady);
  EnterCriticalSection(Engine.StateLock);
  try
    WriteLn(Format('       after the restart: account TimePlayed %d s, time of the name "Alpha1" %d s',
      [Prof(STEAMS[1])^.TimePlayed, NameTime(STEAMS[1], 'Alpha1')]));
    Check('ZSE1-02 the seconds of a player still online reach his name at the shutdown',
      (Played = 10) and (NameTime(STEAMS[1], 'Alpha1') = 10) and (NameTime(STEAMS[4], 'Bravo2') = 10));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { every NAME_TIME_FLUSH_SECONDS the time goes to the name without a leave or a shutdown }
  CurTick := 5000;
  MapAfterFlags('ctf_Names', GS_CTF, 10, MF_RUNNING);
  JoinFour;
  for i := 1 to NAME_TIME_FLUSH_SECONDS do
  begin
    CurTick := 5000 + i * 60;
    TickEv(0, 0, 900, 0);
  end;
  Check('ZSE1-02 five minutes processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('ZSE1-02 the time goes to the name every 5 minutes',
      NameTime(STEAMS[2], 'Alpha2') = 10 + NAME_TIME_FLUSH_SECONDS);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { a leave writes the rest, as before }
  CurTick := 5000 + (NAME_TIME_FLUSH_SECONDS + 3) * 60;
  TickEv(0, 0, 900, 0);
  LeaveEv(2);
  Check('ZSE1-02 leave processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('ZSE1-02 a leave adds the seconds since then', NameTime(STEAMS[2], 'Alpha2') = 11 + NAME_TIME_FLUSH_SECONDS);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
end;

{ ---- ZSE1-03: what was queued before ZS_Shutdown is applied before the engine stops ---- }

procedure TestDrain;
var
  i: LongInt;
  T0: Int64;
begin
  StartEngine('drain', False);
  Check('ZSE1-03 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Drain', GS_CTF, 10, 0);
  JoinFour;
  Check('ZSE1-03 joins processed', WaitProcessed);
  { a burst the engine is still working on when the shutdown comes, the leave last }
  for i := 1 to 30000 do
  begin
    CurTick := 1100 + i div 4;
    Sample(1 + i mod 4, EF_A_ALIVE or EF_A_ONGROUND, 100 + i mod 50, 100);
  end;
  LeaveEv(3);
  T0 := MonoMs;
  Engine.Shutdown;
  WriteLn(Format('       %d events pushed, %d processed, %d dropped; the shutdown took %d ms',
    [Pushed, Engine.Processed, Engine.EventsDropped, MonoMs - T0]));
  Check('ZSE1-03 every event queued before the shutdown is processed, the leave too',
    (Engine.Processed = Pushed) and (Engine.EventsDropped = 0));
  StopEngine;
end;

{ ---- ZSE1-04: a modifier of 0 in the weapons file, an error that repeats with every event ---- }

function LinesWith(const Text, Part: AnsiString): LongInt;
var
  L: TStringList;
  k: LongInt;
begin
  Result := 0;
  L := TStringList.Create;
  try
    L.Text := Text;
    for k := 0 to L.Count - 1 do
      if Pos(Part, L[k]) > 0 then
        Inc(Result);
  finally
    L.Free;
  end;
end;

procedure TestErrors;
var
  i, WS, Zone, Kills0: LongInt;
  Hits0, Body0: Int64;
  Raised: Boolean;
  Log: AnsiString;
  P: PPlayerProfile;
  Alive: Boolean;
begin
  { the classification itself: legs 0, head and chest as they were }
  WS := WepSlot(WEP_AK74);
  ResetWeaponDefs;
  WeaponDefs[WS].ModLegs := 0;
  Raised := False;
  Zone := HZ_UNKNOWN;
  try
    Zone := ClassifyZoneByDamage(WEP_AK74, 40 * WeaponDefs[WS].Damage * WeaponDefs[WS].ModChest, 40, False, False);
  except
    Raised := True;
  end;
  Check('ZSE1-04 a zone with the modifier 0 is skipped: no division by zero, the chest is found',
    not Raised and (Zone = HZ_BODY));
  ResetWeaponDefs;

  StartEngine('errors', False);
  Check('ZSE1-04 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('dm_Errors', GS_DM, 30, 0);
  Join(1, 'Shooter', 'S2101', TEAM_NONE, 0);
  Join(2, 'Target', 'S2102', TEAM_NONE, 0);
  Spawn(1, 100, 100);
  Spawn(2, 500, 100);
  Check('ZSE1-04 players processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    { the map start read the weapons of the mode; this server's file has no damage on the legs }
    WeaponDefs[WS].ModLegs := 0;
    P := Prof('S2101');
    Hits0 := P^.Weapons[WS].Hits;
    Body0 := P^.ShotsHitsBody;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 300 do
  begin
    CurTick := 1100 + i;
    Damage(1, 2, WEP_AK74, 40 * WeaponDefs[WS].Damage * WeaponDefs[WS].ModChest, 490, 90, 40, 500, 100);
  end;
  Check('ZSE1-04 hits processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof('S2101');
    WriteLn(Format('       AK hits counted with ModifierLegs 0: %d of 300, in the chest %d',
      [P^.Weapons[WS].Hits - Hits0, P^.ShotsHitsBody - Body0]));
    Check('ZSE1-04 every hit of a weapon with a leg modifier of 0 counts',
      (P^.Weapons[WS].Hits = Hits0 + 300) and (P^.ShotsHitsBody = Body0 + 300));
    ResetWeaponDefs;
    Kills0 := P^.Kills;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { an error half way through a kill (a position that is no number): the victim still dies, and
    errors.log takes 10 lines of it a minute plus one that counts the rest }
  for i := 1 to 300 do
  begin
    CurTick := 2000 + i * 10;
    Spawn(2, 500, 100);
    Kill(1, 2, WEP_AK74, NaN, NaN, 500, 100, 0);
  end;
  Check('ZSE1-04 failing kills processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Alive := Engine.Live[2].Alive;
    P := Prof('S2101');
    Check('ZSE1-04 a kill whose counters fail half way still ends the life of the victim',
      not Alive and (P^.Kills = Kills0 + 300));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  Check('ZSE1-04 the console gets 10 lines a minute, as before', SeenCount('internal error') = 10);
  StopEngine;
  Log := FileText(Root + PathDelim + 'errors' + PathDelim + 'logs' + PathDelim + 'zitrostats' + PathDelim +
    'errors.log');
  WriteLn(Format('       errors.log: %d lines of the error, %d summary lines',
    [LinesWith(Log, 'event 6: EInvalidOp'), LinesWith(Log, '290 more in the same minute')]));
  Check('ZSE1-04 errors.log: 10 lines of the error and one line with the 290 more',
    (LinesWith(Log, 'event 6: EInvalidOp') = 11) and (LinesWith(Log, 'event 6: EInvalidOp: 290 more in the same minute') = 1));
end;

{ ---- ZSE1-05: /pause - the seconds of a paused game count for nothing ---- }

procedure TestPause;
var
  i: LongInt;
  P: PPlayerProfile;
  Played0, Alive0: LongInt;
begin
  StartEngine('pause', False);
  Check('ZSE1-05 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Pause', GS_CTF, 10, 0);
  JoinFour;
  for i := 1 to 5 do
  begin
    CurTick := 1000 + i * 60;
    TickEv(0, 0, 600 - i, 0);
  end;
  Check('ZSE1-05 five seconds processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    Played0 := P^.TimePlayed;
    Alive0 := P^.TimeAlive;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { ten minutes of /pause: the time left stands, the ticks go on }
  for i := 1 to 600 do
  begin
    CurTick := 1300 + i * 60;
    TickEv(0, 0, 595, 1);
  end;
  Check('ZSE1-05 the pause processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    WriteLn(Format('       after 10 minutes of pause: TimePlayed +%d, TimeAlive +%d, LongestLifeSec %d, match %d s',
      [P^.TimePlayed - Played0, P^.TimeAlive - Alive0, P^.LongestLifeSec, Engine.Match.TotalSeconds]));
    Check('ZSE1-05 a paused game adds no time played, alive or of the longest life',
      (P^.TimePlayed = Played0) and (P^.TimeAlive = Alive0) and (P^.LongestLifeSec = 5));
    Check('ZSE1-05 the length of the match does not grow while paused', Engine.Match.TotalSeconds = 600);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 1300 + 601 * 60;
  TickEv(0, 0, 594, 0);
  Check('ZSE1-05 the end of the pause processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    WriteLn(Format('       after the pause: still for %d ticks, the match runs %d ticks',
      [Engine.GameTick - Engine.Live[2].LastMoveTick, Engine.GameTick - Engine.Match.StartTick]));
    Check('ZSE1-05 the game goes on: the next second counts',
      (P^.TimePlayed = Played0 + 1) and (P^.LongestLifeSec = 6));
    Check('ZSE1-05 the windows of the game time skip the pause (inactivity, the start of the match)',
      (Engine.GameTick - Engine.Live[2].LastMoveTick = 360) and (Engine.GameTick - Engine.Match.StartTick = 360) and
      (Engine.Match.TotalSeconds = 600));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
end;

{ ---- ZSE1-06: the podium of a season that ended shows the points ---- }

procedure TestSeasonPodium;
var
  T0: Int64;
  P: PPlayerProfile;
begin
  StartEngine('season', False);
  Check('ZSE1-06 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Season', GS_CTF, 10, 0);
  JoinFour;
  Check('ZSE1-06 players processed', WaitProcessed);
  DrainActions;
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.SeasonsEnabled := True;
    Engine.Cfg.SeasonBroadcast := True;
    Engine.Cfg.SeasonMinMinutes := 0;
    Engine.DB.Server.SeasonId := 7;
    Engine.DB.Server.SeasonStart := Now - 40;
    Engine.DB.Server.SeasonEnd := Now - 1;
    P := Prof(STEAMS[1]);
    P^.SeasonId := 7;
    P^.SeasonPoints := 25;
    P^.SeasonTime := 3600;
    P := Prof(STEAMS[3]);
    P^.SeasonId := 7;
    P^.SeasonPoints := -7;
    P^.SeasonTime := 3600;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the season ends with the next second of the engine }
  T0 := MonoMs;
  repeat
    Sleep(50);
    DrainActions;
  until (SeenCount('Season 7 is over!') > 0) or (MonoMs - T0 > 5000);
  Sleep(100);
  DrainActions;
  WriteLn('       podium: ', Trim(Console[Console.Count - 1]));
  Check('ZSE1-06 the podium shows "+25 pts" and "-7 pts", not the name again',
    (SeenCount('  1. Alpha1  +25 pts') = 1) and (SeenCount('  2. Bravo1  -7 pts') = 1) and
    (SeenCount('Alpha1d pts') = 0));
  StopEngine;
end;

{ ---- ZSE1-08: the tick counter of the server starts again at 0 after 414 days ---- }

procedure TestTickWrap;
var
  P: PPlayerProfile;
  Doubles0, Kills0, Dur: LongInt;
begin
  StartEngine('wrap', False);
  Check('ZSE1-08 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 2147480000;
  MapAfterFlags('ctf_Wrap', GS_CTF, 10, 0);
  JoinFour;
  CurTick := 2147480060;
  TickEv(0, 0, 600, 0);
  CurTick := 2147483600;
  Kill(1, 3, WEP_AK74, 100, 100, 300, 100, 0);
  Check('ZSE1-08 the time before processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    Doubles0 := P^.PointmatchMode.Multi.DOUBLE_KILL;
    Kills0 := P^.Kills;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the counter starts again at 0; ten seconds later the same player kills again }
  CurTick := 30;
  TickEv(0, 0, 540, 0);
  CurTick := 640;
  Spawn(4, 400, 100);
  Kill(1, 4, WEP_AK74, 100, 100, 400, 100, 0);
  CurTick := 660;
  TickEv(0, 0, 530, 0);
  Check('ZSE1-08 the time after processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    Dur := Engine.GameTick - Engine.Match.StartTick;
    WriteLn(Format('       after the counter started again: GameTick %d, the match runs %d ticks', [Engine.GameTick, Dur]));
    Check('ZSE1-08 the engine follows the new ticks', Engine.GameTick = 660);
    Check('ZSE1-08 a kill 10 s after the last one is no double kill (the windows go on)',
      (P^.Kills = Kills0 + 1) and (P^.PointmatchMode.Multi.DOUBLE_KILL = Doubles0));
    Check('ZSE1-08 the length of the match goes on', (Dur >= 3600 + 600) and (Dur <= 3700 + 660));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
end;

{ ---- ZSE1-09: a full event queue drops only the events that come many times a second ---- }

procedure TestQueueLimit;
var
  i, Dropped0, Dropped1, Queued1: LongInt;
  Ev: TZSEvent;
begin
  StartEngine('queue', False);
  Check('ZSE1-09 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Queue', GS_CTF, 10, 0);
  JoinFour;
  Check('ZSE1-09 players processed', WaitProcessed);
  { the engine stalls (the state lock is held) while the queue fills up }
  EnterCriticalSection(Engine.StateLock);
  try
    { the events taken out before the engine stopped at the lock do not count }
    Sleep(100);
    Dropped0 := Engine.EventsDropped;
    for i := 1 to EVENT_LIMIT + 10 do
    begin
      Ev := NewEvent(zeSample);
      Ev.Slot := 1;
      Ev.I[0] := EF_A_ALIVE;
      Ev.Tick := 1100;
      Engine.PushEvent(Ev);
    end;
    Dropped1 := Engine.EventsDropped;
    Queued1 := Engine.EventsQueued;
    Ev := NewEvent(zeTeam);
    Ev.Slot := 4;
    Ev.I[0] := TEAM_ALPHA;
    Ev.Tick := 1200;
    Engine.PushEvent(Ev);
    Ev := NewEvent(zeSteamAuth);
    Ev.Slot := 2;
    Ev.S1 := STEAMS[2];
    Ev.Tick := 1200;
    Engine.PushEvent(Ev);
    WriteLn(Format('       queued %d, dropped %d', [Engine.EventsQueued, Engine.EventsDropped - Dropped0]));
    Check('ZSE1-09 a full queue drops samples', (Queued1 >= EVENT_LIMIT) and (Dropped1 > Dropped0));
    Check('ZSE1-09 but takes a team change and a Steam answer',
      (Engine.EventsDropped = Dropped1) and (Engine.EventsQueued = Queued1 + 2));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the engine goes on and applies the team change }
  i := 0;
  while (i < 400) and (Engine.EventsQueued > 0) do
  begin
    Sleep(25);
    Inc(i);
  end;
  Sleep(200);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('ZSE1-09 the team change behind the full queue arrives', Engine.Live[4].Team = TEAM_ALPHA);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
end;

{ ---- X-04: a script's bullet made at the victim (a finishing bullet of Basic-Extended) has no
  kill distance ---- }

{ a kill by a bullet the bridge knows the origin of (EF_ORIGIN: F7/F8); Script: the hook did not
  see it fired }
procedure KillFrom(K, V: LongInt; OX, OY, VX, VY: Single; Script: Boolean);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 7;
  Ev.I[1] := WEP_BARRETT;
  Ev.I[2] := EF_BULLET or EF_ORIGIN or EF_A_ALIVE or EF_A_ONGROUND;
  if Script then
    Ev.I[2] := Ev.I[2] or EF_SCRIPT_BULLET;
  Ev.I[3] := WEP_AK74;
  Ev.I[4] := CurTick - 2;
  Ev.F[0] := 100;
  Ev.F[1] := 100;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Ev.F[4] := VX;
  Ev.F[5] := VY;
  Ev.F[7] := OX;
  Ev.F[8] := OY;
  Push(Ev);
end;

procedure TestScriptBulletDistance;
var
  P: PPlayerProfile;
  Count0, Count1, WS: LongInt;
  Sum0: Double;
  Near0: Int64;
begin
  StartEngine('scriptbullet', False);
  Check('X-04 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Bleed', GS_CTF, 10, 0);
  JoinFour;
  Check('X-04 players processed', WaitProcessed);
  WS := WepSlot(WEP_BARRETT);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    Count0 := P^.KillDistanceCount;
    Sum0 := P^.TotalKillDistance;
    Near0 := P^.Weapons[WS].DistBucket[0];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the victim bleeds out: the finishing bullet is made 2 px left of him and 8 px above }
  CurTick := 1100;
  KillFrom(1, 3, 498, 92, 500, 100, True);
  Check('X-04 finishing kill processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    Check('X-04 a script bullet made at the victim: no kill distance, no "< 10 m" kill of the weapon',
      (P^.KillDistanceCount = Count0) and (P^.TotalKillDistance = Sum0) and (P^.Weapons[WS].DistBucket[0] = Near0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { a script's bullet from far away (a Javelin) and a shot of the player from close by count }
  CurTick := 1200;
  Spawn(4, 900, 100);
  KillFrom(1, 4, 200, 100, 900, 100, True);
  CurTick := 1300;
  Spawn(3, 500, 100);
  KillFrom(2, 3, 495, 100, 500, 100, False);
  Check('X-04 other kills processed', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    P := Prof(STEAMS[1]);
    Count1 := Prof(STEAMS[2])^.KillDistanceCount;
    WriteLn(Format('       kill distances counted: %d (%.1f m in all)', [P^.KillDistanceCount - Count0,
      P^.TotalKillDistance - Sum0]));
    Check('X-04 a script bullet from the launcher keeps its distance (50 m)',
      (P^.KillDistanceCount = Count0 + 1) and (Abs(P^.TotalKillDistance - Sum0 - 700 / PIXELS_PER_METER) < 0.01));
    Check('X-04 a shot of the player from 5 px is measured as before', Count1 >= 1);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  StopEngine;
end;

{ ---- X-07: admin rights that change while the player plays reach the notices to the admins ---- }

procedure AdminEv(Slot, IsAdmin: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeAdmin);
  Ev.Slot := Slot;
  Ev.I[0] := IsAdmin;
  Push(Ev);
end;

procedure ReloadSettings;
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeReloadConfig);
  Push(Ev);
end;

procedure TestAdminChange;
var
  Lib: TLibHandle;
begin
  { the export is in the library the runner built }
  Lib := LoadLibrary(DllPath);
  Check('X-07 the library exports ZS_Ev_Admin (API 17)',
    (Lib <> NilHandle) and (GetProcedureAddress(Lib, 'ZS_Ev_Admin') <> nil));
  if Lib <> NilHandle then
    UnloadLibrary(Lib);

  StartEngine('admins', False);
  Check('X-07 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Admins', GS_CTF, 10, 0);
  JoinFour;
  Check('X-07 players processed', WaitProcessed);
  DrainActions;
  { Basic-Extended makes Alpha2 an admin (a Steam admin) after the join: the notices reach him }
  AdminEv(2, 1);
  ReloadSettings;
  Check('X-07 rights processed', WaitProcessed);
  DrainActions;
  { (no settings.ini here: the notice says it could not be read) }
  Check('X-07 an admin made after the join gets the notices to the admins',
    (SeenCount(Format('%d|2|[ZitroStats] settings.ini', [ACT_CONSOLE])) = 1) and
    (SeenCount(Format('%d|1|[ZitroStats] settings.ini', [ACT_CONSOLE])) = 0));
  { /steamadmin remove: the rights are gone, and so are the notices }
  Console.Clear;
  AdminEv(2, 0);
  ReloadSettings;
  Check('X-07 rights taken processed', WaitProcessed);
  DrainActions;
  Check('X-07 an admin whose rights were taken gets no more notices',
    (SeenCount('|2|[ZitroStats] settings.ini') = 0) and (SeenCount('|0|[ZitroStats] settings.ini') = 1));
  StopEngine;
end;

{ ---- X-10: a shutdown while the data loads stops the load, and nothing of it is written ---- }

procedure TestStopDuringLoad;
var
  Stopper: TStopper;
  T0: Int64;
  Snap: AnsiString;
begin
  { for comparison: a start in an empty folder writes a fresh database at once }
  StartEngine('loadok', False);
  Check('X-10 a normal start is ready', WaitReady and not Engine.IsReadOnly);
  StopEngine;
  Snap := Root + PathDelim + 'loadok' + PathDelim + 'nickreg' + PathDelim + 'zitrostats.zsdb';
  Check('X-10 a normal start in an empty folder writes the fresh database', FileExists(Snap));

  { the engine thread waits at the state lock before it loads; the shutdown comes then }
  DeleteTree(Root + PathDelim + 'loadstop');
  ForceDirectories(Root + PathDelim + 'loadstop' + PathDelim + 'script');
  SetCurrentDir(Root + PathDelim + 'loadstop');
  Engine := TZSEngine.Create(Root + PathDelim + 'loadstop' + PathDelim + 'script');
  EnterCriticalSection(Engine.StateLock);
  Engine.Start;
  Sleep(200);
  Stopper := TStopper.Create(False);
  Sleep(300);
  T0 := MonoMs;
  LeaveCriticalSection(Engine.StateLock);
  Stopper.WaitFor;
  Stopper.Free;
  WriteLn(Format('       the shutdown during the load ended %d ms after the load could begin', [MonoMs - T0]));
  Check('X-10 the stopped load leaves the engine read-only', Engine.IsReadOnly);
  StopEngine;
  Snap := Root + PathDelim + 'loadstop' + PathDelim + 'nickreg' + PathDelim + 'zitrostats.zsdb';
  Check('X-10 a stopped load writes nothing: no database file, no journal',
    not FileExists(Snap) and not FileExists(Root + PathDelim + 'loadstop' + PathDelim + 'nickreg' + PathDelim +
    'zitrostats.1.journal'));
end;

{ ---- ZSC-02: text has limits of its own; kicks and moves are never dropped ---- }

procedure Cmd(Slot: LongInt; const Text: AnsiString; Source, Admin: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  Ev.I[0] := Source;
  Ev.I[1] := Admin;
  Push(Ev);
end;

procedure TestOutputQueue;
var
  i, Lines, Waits: LongInt;
  Kicked: Boolean;
begin
  StartEngine('output', False);
  Check('ZSC-02 engine ready', WaitReady and not Engine.IsReadOnly);
  CurTick := 1000;
  MapAfterFlags('ctf_Output', GS_CTF, 10, 0);
  JoinFour;
  Check('ZSC-02 players processed', WaitProcessed);
  DrainActions;
  Console.Clear;
  { the output is full of lines to everybody; a kick and a team move come after them }
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to ACTION_LIMIT + 500 do
      Engine.Broadcast('flood line', 0);
    Engine.KickPlayer(4, 'kicked by the test');
    Engine.ForceSpectator(3);
    Kicked := Engine.Live[4].PendingKick;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  DrainActions;
  WriteLn(Format('       lines to everybody taken: %d of %d', [SeenCount('|0|flood line'), ACTION_LIMIT + 500]));
  Check('ZSC-02 a full output drops text above the limit',
    SeenCount('|0|flood line') = ACTION_LIMIT);
  Check('ZSC-02 but the kick and the team move behind it go out, and the kick is pending',
    (SeenCount(Format('%d|4|kicked by the test', [ACT_KICK])) = 1) and
    (SeenCount(Format('%d|3|', [ACT_SETTEAM])) = 1) and Kicked);

  { one player asks for long lists faster than they can be sent: later ones wait }
  Console.Clear;
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  for i := 1 to 12 do
    Cmd(1, '/zitro', SRC_COMMAND, 0);
  Check('ZSC-02 commands processed', WaitProcessed);
  DrainActions;
  Lines := SeenCount(Format('%d|1|', [ACT_CONSOLE]));
  Waits := SeenCount('|1|Wait a moment - your last answers are still being sent.');
  WriteLn(Format('       12 x /zitro without a tick in between: %d lines for the player, %d commands told to wait',
    [Lines, Waits]));
  Check('ZSC-02 a player whose answers still wait gets new commands answered later',
    (Waits >= 1) and (Lines < SLOT_TEXT_WAIT + 100));
  { the lines went out (DrainActions): the next command is answered }
  Console.Clear;
  Cmd(1, '/zitro', SRC_COMMAND, 0);
  Check('ZSC-02 a later command processed', WaitProcessed);
  DrainActions;
  Check('ZSC-02 once the answers are out the player is answered again',
    (SeenCount('|1|Wait a moment') = 0) and (SeenCount(Format('%d|1|', [ACT_CONSOLE])) > 10));
  StopEngine;
end;

{ ---- ZSE2-10: control characters of names and texts never reach the log files ---- }

procedure TestLogControlChars;
var
  Ev: TZSEvent;
  Log: AnsiString;
  L: TStringList;
  k, Dated: LongInt;
  Clean: Boolean;
begin
  StartEngine('logs', False);
  Check('ZSE2-10 engine ready', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.DuplicateHWID := 'kick';
    Engine.Cfg.AdminAuditLog := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 1000;
  MapAfterFlags('ctf_Logs', GS_CTF, 10, 0);
  Ev := NewEvent(zeJoin);
  Ev.Slot := 1;
  Ev.S1 := 'Bob';
  Ev.S2 := 'S2301';
  Ev.S3 := 'HWSAME';
  Ev.S4 := '10.0.0.1';
  Ev.I[0] := TEAM_ALPHA;
  Ev.I[1] := 1;
  Push(Ev);
  { the second computer of the same HWID is kicked, and its name goes to audit.log }
  Ev.Slot := 2;
  Ev.S1 := 'evil' + #10 + '2026-10-06 12:00:00  admin console: all player statistics were reset' + #27 + '[2J' + #127;
  Ev.S2 := 'S2302';
  Ev.S4 := '10.0.0.2';
  Push(Ev);
  Check('ZSE2-10 joins processed', WaitProcessed);
  StopEngine;
  Log := FileText(Root + PathDelim + 'logs' + PathDelim + 'logs' + PathDelim + 'zitrostats' + PathDelim + 'audit.log');
  L := TStringList.Create;
  try
    L.Text := Log;
    Dated := 0;
    Clean := True;
    for k := 0 to L.Count - 1 do
    begin
      if Copy(L[k], 1, 2) = '20' then
        Inc(Dated);
      if (Pos(#27, L[k]) > 0) or (Pos(#127, L[k]) > 0) or (Pos('admin console: all player', L[k]) = 31) then
        Clean := False;
    end;
    WriteLn('       audit.log: ', Trim(Log));
    Check('ZSE2-10 a name with a line break makes no line of its own in audit.log',
      (L.Count = 1) and (Dated = 1) and (Pos('identity: evil?2026-10-06 12:00:00  admin console', Log) > 0));
    Check('ZSE2-10 ESC and DEL become ?', Clean and (Pos('reset?[2J?', Log) > 0));
  finally
    L.Free;
  end;
end;

begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'fixws2_tmp');
  DllPath := ExpandFileName('build' + PathDelim + 'win32' + PathDelim + 'zitrostats_dll.dll');
  DeleteTree(Root);
  ForceDirectories(Root);
  Console := TStringList.Create;

  TestRestart;
  TestNameTime;
  TestDrain;
  TestErrors;
  TestPause;
  TestSeasonPodium;
  TestTickWrap;
  TestQueueLimit;
  TestScriptBulletDistance;
  TestAdminChange;
  TestStopDuringLoad;
  TestOutputQueue;
  TestLogControlChars;

  Console.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
  begin
    WriteLn(Failures, ' TEST(S) FAILED');
    ExitCode := 1;
  end;
end.
