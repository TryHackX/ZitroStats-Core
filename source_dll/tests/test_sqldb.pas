program test_sqldb;

{ [MySQL] Engine = mysql end to end: two engines - two game servers - share one database.

    test_sqldb <host> <port> <database> <user> <password>

  Server A starts first and brings its data; server B joins and reads it. Kills on both servers
  add up on both, an account made on one appears on the other, the same new player made on both
  at once becomes one account, a map played on both adds up, and a job of the day goes to one of
  them only. Then what goes wrong: a SteamID longer than its column, a change counter that went
  back, a server that never joined and starts without the database (a table of another engine
  refuses it), and a counter of account numbers set back by hand. The player-on-map records
  ([Matrix]) go along: they add up on both servers, a server that joins brings its records with
  their rivals under the numbers of the database, a record pruned on one server goes on the
  others, and what a server collected without the database reaches them after its next start. It
  drops the zs_db_* tables at the start and at the end. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, md5, zs_types, zs_util, zs_fields, zs_db, zs_matrix, zs_identity, zs_engine, zs_sqldb, mysqlwire;

var
  Failures: Integer = 0;
  CurTick: LongInt = 0;

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

procedure Push(E: TZSEngine; Ev: TZSEvent);
begin
  Ev.Tick := CurTick;
  E.PushEvent(Ev);
end;

function WaitReady(E: TZSEngine): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not E.IsReady do
  begin
    if MonoMs - T0 > 30000 then
      Exit(False);
    Sleep(5);
  end;
  Result := True;
end;

procedure MapAfter(E: TZSEngine; const Name: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := GS_CTF;
  Ev.I[1] := 10;
  Push(E, Ev);
end;

procedure Join(E: TZSEngine; Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := Hwid;
  Ev.S4 := IP;
  Ev.I[0] := Team;
  Ev.I[1] := 1;
  Ev.I[2] := 0;
  Push(E, Ev);
end;

procedure Kill(E: TZSEngine; K, V: LongInt);
var
  Ev: TZSEvent;
begin
  Inc(CurTick, 60);
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND;
  Ev.I[3] := WEP_MP5;
  Ev.F[0] := 100;
  Ev.F[1] := 100;
  Ev.F[2] := 400;
  Ev.F[3] := 100;
  Push(E, Ev);
end;

procedure Leave(E: TZSEngine; Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(E, Ev);
end;

procedure Cmd(E: TZSEngine; Slot: LongInt; const Text: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  Ev.I[0] := SRC_COMMAND;
  Ev.I[1] := 0;
  Push(E, Ev);
end;

{ the account without Steam of a computer: its number and kills, 0 / -1 when there is none }
function ComputerAccount(E: TZSEngine; const Hwid: AnsiString; out Kills: LongInt; out Registered: Boolean): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  Kills := -1;
  Registered := False;
  EnterCriticalSection(E.StateLock);
  try
    for k := 0 to E.DB.ProfileCount - 1 do
      if E.DB.Valid(k) and (E.DB.Profiles[k]^.ActiveSteam = '') and (E.DB.Profiles[k]^.ActiveHWID = Hwid) then
      begin
        Result := E.DB.Profiles[k]^.ID;
        Kills := E.DB.Profiles[k]^.Kills;
        Registered := E.DB.Profiles[k]^.PassHash <> '';
      end;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function SessionOf(E: TZSEngine; Slot: LongInt; out Locked: Boolean): LongInt;
begin
  EnterCriticalSection(E.StateLock);
  try
    Result := E.Identity.Slots[Slot].ProfileId;
    Locked := E.Identity.Slots[Slot].Locked;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function Conn: TMyConnection;
begin
  Result := TMyConnection.Create;
  Result.Host := ParamStr(1);
  Result.Port := StrToIntDef(ParamStr(2), 3306);
  Result.Database := ParamStr(3);
  Result.User := ParamStr(4);
  Result.Password := ParamStr(5);
end;

procedure DropTables;
const
  TABLES: array[0..6] of AnsiString = ('zs_db_accounts', 'zs_db_maps', 'zs_db_server', 'zs_db_seasons', 'zs_db_meta',
    'zs_db_jobs', 'zs_db_player_maps');
var
  C: TMyConnection;
  k: LongInt;
begin
  C := Conn;
  try
    C.Connect;
    for k := 0 to High(TABLES) do
      C.Exec('DROP TABLE IF EXISTS ' + TABLES[k]);
  finally
    C.Free;
  end;
end;

function Scalar(const SQL: AnsiString): AnsiString;
var
  C: TMyConnection;
  R: TMyResult;
begin
  Result := '';
  C := Conn;
  try
    C.Connect;
    R := C.Query(SQL);
    try
      if R.RowCount > 0 then
        Result := R.Str(0, 0);
    finally
      R.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure ExecSql(const SQL: AnsiString);
var
  C: TMyConnection;
begin
  C := Conn;
  try
    C.Connect;
    C.Exec(SQL);
  finally
    C.Free;
  end;
end;

function MakeEngine(const Root: AnsiString; ServerId: LongInt; const Engine: AnsiString = 'mysql';
  Fresh: Boolean = True; const Port: AnsiString = ''): TZSEngine;
var
  L: TStringList;
begin
  if Fresh then
    DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  L := TStringList.Create;
  try
    L.Add('[General]');
    L.Add('SourceCodepage = 1250');
    { every server has files of its own }
    L.Add('DataPath = ' + Root + PathDelim + 'data' + PathDelim);
    L.Add('LogPath = ' + Root + PathDelim + 'logs' + PathDelim);
    L.Add('BackupPath = ' + Root + PathDelim + 'backup' + PathDelim);
    { a player without Steam counts at once }
    L.Add('[Identity]');
    L.Add('SteamAuthWaitSeconds = 0');
    L.Add('[MySQL]');
    L.Add('Engine = ' + Engine);
    L.Add('Host = ' + ParamStr(1));
    if Port <> '' then
      L.Add('Port = ' + Port)
    else
      L.Add('Port = ' + ParamStr(2));
    L.Add('Database = ' + ParamStr(3));
    L.Add('User = ' + ParamStr(4));
    L.Add('Password = ' + ParamStr(5));
    L.Add('ServerID = ' + IntToStr(ServerId));
    L.Add('SyncSeconds = 1');
    L.SaveToFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini');
  finally
    L.Free;
  end;
  Result := TZSEngine.Create(Root + PathDelim + 'script');
  Result.Start;
end;

{ a number of an account on an engine, read under its lock; -1 = no such account }
function KillsOf(E: TZSEngine; const Steam: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  EnterCriticalSection(E.StateLock);
  try
    k := E.DB.IndexOfSteam(Steam);
    if E.DB.Valid(k) then
      Result := E.DB.Profiles[k]^.Kills;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function IdOf(E: TZSEngine; const Steam: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  EnterCriticalSection(E.StateLock);
  try
    k := E.DB.IndexOfSteam(Steam);
    if E.DB.Valid(k) then
      Result := E.DB.Profiles[k]^.ID;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function CountSteam(E: TZSEngine; const Steam: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  EnterCriticalSection(E.StateLock);
  try
    for k := 0 to E.DB.ProfileCount - 1 do
      if E.DB.Valid(k) and (E.DB.Profiles[k]^.ActiveSteam = Steam) then
        Inc(Result);
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function MapKills(E: TZSEngine; const Name: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  EnterCriticalSection(E.StateLock);
  try
    k := E.DB.FindMap(Name, False);
    if k >= 0 then
      Result := E.DB.Maps[k].Kills;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function Job(E: TZSEngine; Key: LongInt): Boolean;
begin
  EnterCriticalSection(E.StateLock);
  try
    Result := SqlJob(E, 'test', Key);
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function StatusOf(E: TZSEngine): AnsiString;
begin
  EnterCriticalSection(E.StateLock);
  try
    Result := SqlStatusText(E);
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ the kills of the account of a name, -1 when there is none }
function KillsByName(E: TZSEngine; const Name: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  EnterCriticalSection(E.StateLock);
  try
    for k := 0 to E.DB.ProfileCount - 1 do
      if E.DB.Valid(k) and (E.DB.Profiles[k]^.ActiveName = Name) then
        Result := E.DB.Profiles[k]^.Kills;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ what an account of an old import can hold: a "SteamID" the game never sends }
procedure SetSteam(E: TZSEngine; const Name, Steam: AnsiString);
var
  k: LongInt;
begin
  EnterCriticalSection(E.StateLock);
  try
    for k := 0 to E.DB.ProfileCount - 1 do
      if E.DB.Valid(k) and (E.DB.Profiles[k]^.ActiveName = Name) then
      begin
        E.DB.BeginIdentityChange(k);
        E.DB.Profiles[k]^.ActiveSteam := Steam;
        E.DB.EndIdentityChange(k);
        E.DB.Touch(k);
      end;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ [Matrix]: the kills of the record of an account on a map on an engine, -1 when it has none }
function PMKills(E: TZSEngine; AccountId: LongInt; const Map: AnsiString): LongInt;
var
  R: PPlayerMapStats;
begin
  Result := -1;
  EnterCriticalSection(E.StateLock);
  try
    R := E.DB.PM.Find(AccountId, Map);
    if R <> nil then
      Result := R^.Kills;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

function PMDeaths(E: TZSEngine; AccountId: LongInt; const Map: AnsiString): LongInt;
var
  R: PPlayerMapStats;
begin
  Result := -1;
  EnterCriticalSection(E.StateLock);
  try
    R := E.DB.PM.Find(AccountId, Map);
    if R <> nil then
      Result := R^.Deaths;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ the kills and deaths of a record against one rival: 'kills/deaths', '-' when there is no entry }
function RivalKD(E: TZSEngine; AccountId: LongInt; const Map: AnsiString; RivalId: LongInt): AnsiString;
var
  R: PPlayerMapStats;
  p: LongInt;
begin
  Result := '-';
  EnterCriticalSection(E.StateLock);
  try
    R := E.DB.PM.Find(AccountId, Map);
    if (R <> nil) and PMRivalPos(R^.Rivals, RivalId, p) then
      Result := IntToStr(R^.Rivals[p].Kills) + '/' + IntToStr(R^.Rivals[p].Deaths);
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ the points of a record won from one rival and lost to him: 'won/lost', '-' when there is no entry }
function RivalPts(E: TZSEngine; AccountId: LongInt; const Map: AnsiString; RivalId: LongInt): AnsiString;
var
  R: PPlayerMapStats;
  p: LongInt;
begin
  Result := '-';
  EnterCriticalSection(E.StateLock);
  try
    R := E.DB.PM.Find(AccountId, Map);
    if (R <> nil) and PMRivalPos(R^.Rivals, RivalId, p) then
      Result := IntToStr(R^.Rivals[p].PointsWon) + '/' + IntToStr(R^.Rivals[p].PointsLost);
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ the points of the record of an account on a map, High(LongInt) when it has none }
function PMPoints(E: TZSEngine; AccountId: LongInt; const Map: AnsiString): LongInt;
var
  R: PPlayerMapStats;
begin
  Result := High(LongInt);
  EnterCriticalSection(E.StateLock);
  try
    R := E.DB.PM.Find(AccountId, Map);
    if R <> nil then
      Result := R^.Points;
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ every rival entry of a record as 'id:kills/deaths', for the output }
function RivalsText(E: TZSEngine; AccountId: LongInt; const Map: AnsiString): AnsiString;
var
  R: PPlayerMapStats;
  p: LongInt;
begin
  Result := '';
  EnterCriticalSection(E.StateLock);
  try
    R := E.DB.PM.Find(AccountId, Map);
    if R = nil then
      Exit('no record');
    for p := 0 to High(R^.Rivals) do
      Result := Result + Format(' #%d:%d/%d', [R^.Rivals[p].Id, R^.Rivals[p].Kills, R^.Rivals[p].Deaths]);
  finally
    LeaveCriticalSection(E.StateLock);
  end;
end;

{ a column of the row of a record in zs_db_player_maps }
function PMRow(AccountId: LongInt; const Map, Column: AnsiString): AnsiString;
begin
  Result := Scalar('SELECT ' + Column + ' FROM zs_db_player_maps WHERE account_id = ' + IntToStr(AccountId) +
    ' AND map_name = ' + MyStr(Map));
end;

var
  A, B, C, D: TZSEngine;
  Base, AliceRow: AnsiString;
  T0, MaxBefore, GusId: Int64;
  GotA, GotB: Boolean;
  NiaA, NiaB, KillsA, KillsB, Other, Session, K0, KB0: LongInt;
  RegA, RegB, Locked: Boolean;
  { [Matrix] }
  AliceId, BobId, CarolId, EveId, EveLocal, FrankId, Pruned, k: LongInt;
  CarolLast: Double;
begin
  if ParamCount < 4 then
  begin
    WriteLn('Usage: test_sqldb <host> <port> <database> <user> [password]');
    Halt(2);
  end;
  Base := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'sqldb_tmp');
  DropTables;

  { ---- server A: the first one, its data starts the database ---- }
  A := MakeEngine(Base + PathDelim + 'a', 1);
  Check('server A ready', WaitReady(A));
  MapAfter(A, 'ctf_Ash');
  Join(A, 1, 'Alice', 'S7001', 'HWA1', '1.1.1.1', TEAM_ALPHA);
  Join(A, 2, 'Bob', 'S7002', 'HWA2', '1.1.1.2', TEAM_BRAVO);
  Kill(A, 1, 2);
  Kill(A, 1, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until (Scalar('SELECT kills FROM zs_db_accounts WHERE steam = ''S7001''') = '2') or (MonoMs - T0 > 20000);
  Check('A writes its accounts into the shared database', Scalar('SELECT kills FROM zs_db_accounts WHERE steam = ''S7001''') = '2');

  { ---- server B joins and reads what A wrote ---- }
  B := MakeEngine(Base + PathDelim + 'b', 2);
  Check('server B ready', WaitReady(B));
  Check('B reads the accounts of A at the start', KillsOf(B, 'S7001') = 2);
  MapAfter(B, 'ctf_Ash');
  Join(B, 1, 'Alice', 'S7001', 'HWB1', '2.2.2.1', TEAM_ALPHA);
  Join(B, 2, 'Bob', 'S7002', 'HWB2', '2.2.2.2', TEAM_BRAVO);
  { both servers at the same time: 3 kills on B, 1 more on A }
  Kill(B, 1, 2);
  Kill(B, 1, 2);
  Kill(B, 1, 2);
  Kill(A, 1, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((KillsOf(A, 'S7001') = 6) and (KillsOf(B, 'S7001') = 6)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       Alice: %d kills on A, %d on B, %s in the database', [KillsOf(A, 'S7001'), KillsOf(B, 'S7001'),
    Scalar('SELECT kills FROM zs_db_accounts WHERE steam = ''S7001''')]));
  Check('kills on both servers add up on both', (KillsOf(A, 'S7001') = 6) and (KillsOf(B, 'S7001') = 6));
  EnterCriticalSection(A.StateLock);
  WriteLn('       A: ', SqlStatusText(A));
  LeaveCriticalSection(A.StateLock);
  EnterCriticalSection(B.StateLock);
  WriteLn('       B: ', SqlStatusText(B));
  LeaveCriticalSection(B.StateLock);
  Check('and in the database', Scalar('SELECT kills FROM zs_db_accounts WHERE steam = ''S7001''') = '6');
  Check('the same account number on both servers', (IdOf(A, 'S7001') > 0) and (IdOf(A, 'S7001') = IdOf(B, 'S7001')));

  { ---- [Matrix]: Alice's record of ctf_Ash, 3 kills on each server, adds up on both - with the
    rival entries on both sides - and in the database ---- }
  AliceId := IdOf(A, 'S7001');
  BobId := IdOf(A, 'S7002');
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((PMKills(A, AliceId, 'ctf_Ash') = 6) and (PMKills(B, AliceId, 'ctf_Ash') = 6) and
    (RivalKD(A, AliceId, 'ctf_Ash', BobId) = '6/0') and (RivalKD(B, AliceId, 'ctf_Ash', BobId) = '6/0') and
    (RivalKD(A, BobId, 'ctf_Ash', AliceId) = '0/6') and (RivalKD(B, BobId, 'ctf_Ash', AliceId) = '0/6') and
    (PMRow(AliceId, 'ctf_Ash', 'kills') = '6')) or (MonoMs - T0 > 20000);
  WriteLn(Format('       Alice on ctf_Ash: %d kills on A, %d on B, %s in the database; rivals on A:%s',
    [PMKills(A, AliceId, 'ctf_Ash'), PMKills(B, AliceId, 'ctf_Ash'), PMRow(AliceId, 'ctf_Ash', 'kills'),
     RivalsText(A, AliceId, 'ctf_Ash')]));
  Check('a record of a map played on both servers adds up on both',
    (PMKills(A, AliceId, 'ctf_Ash') = 6) and (PMKills(B, AliceId, 'ctf_Ash') = 6) and
    (PMDeaths(A, BobId, 'ctf_Ash') = 6) and (PMDeaths(B, BobId, 'ctf_Ash') = 6));
  Check('with the rival entries of both sides', (RivalKD(A, AliceId, 'ctf_Ash', BobId) = '6/0') and
    (RivalKD(B, AliceId, 'ctf_Ash', BobId) = '6/0') and (RivalKD(A, BobId, 'ctf_Ash', AliceId) = '0/6') and
    (RivalKD(B, BobId, 'ctf_Ash', AliceId) = '0/6'));
  Check('and in the database', (PMRow(AliceId, 'ctf_Ash', 'kills') = '6') and
    (PMRow(BobId, 'ctf_Ash', 'deaths') = '6') and (PMRow(AliceId, 'ctf_Ash', 'deleted') = '0'));
  { the points both ways: only kills moved points on the map, so what Alice won from Bob is her points
    of the map on both servers, and what Bob lost to her his }
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((PMPoints(A, AliceId, 'ctf_Ash') > 0) and (PMPoints(A, AliceId, 'ctf_Ash') < High(LongInt)) and
    (RivalPts(A, AliceId, 'ctf_Ash', BobId) = IntToStr(PMPoints(A, AliceId, 'ctf_Ash')) + '/0') and
    (RivalPts(B, AliceId, 'ctf_Ash', BobId) = RivalPts(A, AliceId, 'ctf_Ash', BobId)) and
    (RivalPts(A, BobId, 'ctf_Ash', AliceId) = '0/' + IntToStr(-PMPoints(A, BobId, 'ctf_Ash'))) and
    (RivalPts(B, BobId, 'ctf_Ash', AliceId) = RivalPts(A, BobId, 'ctf_Ash', AliceId))) or (MonoMs - T0 > 20000);
  WriteLn(Format('       points on ctf_Ash: Alice %d (A) %d (B), entry of Bob %s (A) %s (B); ' +
    'Bob %d, entry of Alice %s (A) %s (B)', [PMPoints(A, AliceId, 'ctf_Ash'), PMPoints(B, AliceId, 'ctf_Ash'),
     RivalPts(A, AliceId, 'ctf_Ash', BobId), RivalPts(B, AliceId, 'ctf_Ash', BobId), PMPoints(A, BobId, 'ctf_Ash'),
     RivalPts(A, BobId, 'ctf_Ash', AliceId), RivalPts(B, BobId, 'ctf_Ash', AliceId)]));
  Check('the points won from a rival and lost to him add up on both servers as well',
    (PMPoints(A, AliceId, 'ctf_Ash') > 0) and (PMPoints(A, AliceId, 'ctf_Ash') = PMPoints(B, AliceId, 'ctf_Ash')) and
    (RivalPts(A, AliceId, 'ctf_Ash', BobId) = IntToStr(PMPoints(A, AliceId, 'ctf_Ash')) + '/0') and
    (RivalPts(B, AliceId, 'ctf_Ash', BobId) = RivalPts(A, AliceId, 'ctf_Ash', BobId)) and
    (RivalPts(A, BobId, 'ctf_Ash', AliceId) = '0/' + IntToStr(-PMPoints(A, BobId, 'ctf_Ash'))) and
    (RivalPts(B, BobId, 'ctf_Ash', AliceId) = RivalPts(A, BobId, 'ctf_Ash', AliceId)) and
    (PMPoints(A, AliceId, 'ctf_Ash') = -PMPoints(A, BobId, 'ctf_Ash')));

  { ---- an account made on B appears on A ---- }
  Join(B, 3, 'Carol', 'S7003', 'HWB3', '2.2.2.3', TEAM_ALPHA);
  Kill(B, 3, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until (KillsOf(A, 'S7003') = 1) or (MonoMs - T0 > 20000);
  Check('an account made on B appears on A', (KillsOf(A, 'S7003') = 1) and (IdOf(A, 'S7003') = IdOf(B, 'S7003')));

  { ---- the same new player on both servers at once becomes one account ---- }
  Join(A, 4, 'Dave', 'S7004', 'HWA4', '1.1.1.4', TEAM_ALPHA);
  Join(B, 4, 'Dave', 'S7004', 'HWB4', '2.2.2.4', TEAM_ALPHA);
  Kill(A, 4, 2);
  Kill(B, 4, 2);
  Kill(B, 4, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((KillsOf(A, 'S7004') = 3) and (KillsOf(B, 'S7004') = 3) and (CountSteam(A, 'S7004') = 1) and
    (CountSteam(B, 'S7004') = 1)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       Dave: %d kills on A (#%d), %d on B (#%d), %s account(s) in the database', [KillsOf(A, 'S7004'),
    IdOf(A, 'S7004'), KillsOf(B, 'S7004'), IdOf(B, 'S7004'),
    Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE steam = ''S7004'' AND deleted = 0')]));
  Check('a player new on both servers at once becomes one account',
    (CountSteam(A, 'S7004') = 1) and (CountSteam(B, 'S7004') = 1) and (IdOf(A, 'S7004') = IdOf(B, 'S7004')) and
    (Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE steam = ''S7004'' AND deleted = 0') = '1'));
  Check('with the kills of both', (KillsOf(A, 'S7004') = 3) and (KillsOf(B, 'S7004') = 3));

  { ---- the map played on both ---- }
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((MapKills(A, 'ctf_Ash') = MapKills(B, 'ctf_Ash')) and (MapKills(A, 'ctf_Ash') >= 9)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       ctf_Ash: %d kills on A, %d on B', [MapKills(A, 'ctf_Ash'), MapKills(B, 'ctf_Ash')]));
  Check('a map played on both servers adds up', (MapKills(A, 'ctf_Ash') = MapKills(B, 'ctf_Ash')) and
    (MapKills(A, 'ctf_Ash') >= 9));

  { ---- a job of the day goes to one server ---- }
  GotA := False;
  GotB := False;
  Job(A, 20260922);
  Job(B, 20260922);
  T0 := MonoMs;
  repeat
    Sleep(200);
    if Job(A, 20260922) then GotA := True;
    if Job(B, 20260922) then GotB := True;
  until (GotA or GotB) and (MonoMs - T0 > 4000) or (MonoMs - T0 > 20000);
  Check('a job of the day goes to one server only', GotA <> GotB);

  { ---- a server with a past: its own files first, then the shared database ---- }
  C := MakeEngine(Base + PathDelim + 'c', 3, 'local');
  Check('server C ready with its own files', WaitReady(C));
  MapAfter(C, 'ctf_Ash');
  Join(C, 1, 'Alice', 'S7001', 'HWC1', '3.3.3.1', TEAM_ALPHA);
  Join(C, 2, 'Eve', '', 'HWC2', '3.3.3.2', TEAM_BRAVO);
  Kill(C, 1, 2);
  Kill(C, 1, 2);
  Kill(C, 1, 2);
  Kill(C, 1, 2);
  T0 := MonoMs;
  repeat
    Sleep(100);
  until (KillsOf(C, 'S7001') = 4) or (MonoMs - T0 > 5000);
  WriteLn(Format('       C before joining: Alice %d kills', [KillsOf(C, 'S7001')]));
  EveLocal := ComputerAccount(C, 'HWC2', KillsA, RegA);
  C.Shutdown;
  C.Free;
  C := MakeEngine(Base + PathDelim + 'c', 3, 'mysql', False);
  Check('server C joins the shared database', WaitReady(C));
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((KillsOf(A, 'S7001') = 10) and (KillsOf(C, 'S7001') = 10)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       Alice after C joined: %d kills on A, %d on C', [KillsOf(A, 'S7001'), KillsOf(C, 'S7001')]));
  Check('its accounts join the same players of the database', (KillsOf(A, 'S7001') = 10) and (KillsOf(C, 'S7001') = 10));
  Check('an account without Steam comes along', Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE steam IS NULL AND name = ''Eve''') = '1');

  { ---- [Matrix]: the records of C came along, their rivals under the numbers of the database:
    Eve's number of C's files may be another account's in the database (Bob's here), and Alice's
    kills against Eve must not go to that one ---- }
  EveId := ComputerAccount(A, 'HWC2', KillsA, RegA);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((PMKills(A, AliceId, 'ctf_Ash') = 10) and (PMKills(C, AliceId, 'ctf_Ash') = 10) and
    (RivalKD(A, AliceId, 'ctf_Ash', EveId) = '4/0') and (RivalKD(A, AliceId, 'ctf_Ash', BobId) = '6/0') and
    (RivalKD(A, EveId, 'ctf_Ash', AliceId) = '0/4')) or (MonoMs - T0 > 20000);
  WriteLn(Format('       Eve: #%d in C''s files, #%d in the database (Bob #%d); Alice''s rivals on A:%s',
    [EveLocal, EveId, BobId, RivalsText(A, AliceId, 'ctf_Ash')]));
  Check('a server that joins brings its records: they add to the records of the database',
    (PMKills(A, AliceId, 'ctf_Ash') = 10) and (PMKills(C, AliceId, 'ctf_Ash') = 10) and
    (PMRow(AliceId, 'ctf_Ash', 'kills') = '10') and (PMDeaths(A, EveId, 'ctf_Ash') = 4));
  Check('with their rivals under the numbers of the database', (EveId > 0) and (EveId <> EveLocal) and
    (RivalKD(A, AliceId, 'ctf_Ash', EveId) = '4/0') and (RivalKD(A, AliceId, 'ctf_Ash', BobId) = '6/0') and
    (RivalKD(A, EveId, 'ctf_Ash', AliceId) = '0/4') and (RivalKD(C, AliceId, 'ctf_Ash', EveId) = '4/0'));
  { the points of C's kills came along under the new numbers: Alice's entry of Eve won what Eve's
    entry of Alice lost, on A as on C, and the points against Bob stay }
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((RivalPts(A, AliceId, 'ctf_Ash', EveId) = RivalPts(C, AliceId, 'ctf_Ash', EveId)) and
    (RivalPts(A, EveId, 'ctf_Ash', AliceId) = RivalPts(C, EveId, 'ctf_Ash', AliceId))) or (MonoMs - T0 > 20000);
  WriteLn(Format('       after C joined: Alice''s entry of Eve %s (A) %s (C), Eve''s of Alice %s (A), Alice''s of Bob %s (A)',
    [RivalPts(A, AliceId, 'ctf_Ash', EveId), RivalPts(C, AliceId, 'ctf_Ash', EveId), RivalPts(A, EveId, 'ctf_Ash', AliceId),
     RivalPts(A, AliceId, 'ctf_Ash', BobId)]));
  Check('with the points both ways under the numbers of the database',
    (Pos('/0', RivalPts(A, AliceId, 'ctf_Ash', EveId)) > 1) and (RivalPts(A, AliceId, 'ctf_Ash', EveId) <> '0/0') and
    (RivalPts(A, AliceId, 'ctf_Ash', EveId) = RivalPts(C, AliceId, 'ctf_Ash', EveId)) and
    (RivalPts(A, EveId, 'ctf_Ash', AliceId) = '0/' + Copy(RivalPts(A, AliceId, 'ctf_Ash', EveId), 1,
      Pos('/', RivalPts(A, AliceId, 'ctf_Ash', EveId)) - 1)) and
    (RivalPts(C, EveId, 'ctf_Ash', AliceId) = RivalPts(A, EveId, 'ctf_Ash', AliceId)));

  { ---- [Matrix]: a record pruned on B ([Matrix] MatrixPruneDays) goes on A and in the database ---- }
  CarolId := IdOf(B, 'S7003');
  T0 := MonoMs;
  repeat
    Sleep(200);
  until (PMKills(A, CarolId, 'ctf_Ash') = 1) or (MonoMs - T0 > 20000);
  Check('the record of an account made on B reached A', PMKills(A, CarolId, 'ctf_Ash') = 1);
  EnterCriticalSection(B.StateLock);
  try
    k := B.DB.IndexOfSteam('S7003');
    CarolLast := B.DB.Profiles[k]^.LastPlayedTime;
    B.DB.Profiles[k]^.LastPlayedTime := B.DB.NowValue - 100;
    Pruned := B.DB.PrunePlayerMaps(90);
    B.DB.Profiles[k]^.LastPlayedTime := CarolLast;
  finally
    LeaveCriticalSection(B.StateLock);
  end;
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((PMKills(A, CarolId, 'ctf_Ash') = -1) and (PMRow(CarolId, 'ctf_Ash', 'deleted') = '1')) or
    (MonoMs - T0 > 20000);
  WriteLn(Format('       pruned on B: %d record(s); Carol on A: %d kills (-1 = no record), row deleted = %s',
    [Pruned, PMKills(A, CarolId, 'ctf_Ash'), PMRow(CarolId, 'ctf_Ash', 'deleted')]));
  Check('a record pruned on one server goes on the others and in the database', (Pruned = 1) and
    (PMKills(B, CarolId, 'ctf_Ash') = -1) and (PMKills(A, CarolId, 'ctf_Ash') = -1) and
    (PMRow(CarolId, 'ctf_Ash', 'deleted') = '1') and (PMRow(CarolId, 'ctf_Ash', 'data') = ''));
  Check('the other records stay', (PMKills(A, AliceId, 'ctf_Ash') = 10) and (PMKills(B, AliceId, 'ctf_Ash') = 10));

  { ---- a player without Steam is the account of the computer, as on one server ---- }
  Join(A, 6, 'Nia', '', 'HWN1', '1.1.1.6', TEAM_ALPHA);
  Kill(A, 6, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
    NiaA := ComputerAccount(A, 'HWN1', KillsA, RegA);
    NiaB := ComputerAccount(B, 'HWN1', KillsB, RegB);
  until ((NiaA > 0) and (NiaB = NiaA) and (KillsB = 1)) or (MonoMs - T0 > 20000);
  Check('the account of a computer made on A reaches B', (NiaA > 0) and (NiaB = NiaA) and (KillsB = 1));
  { the same computer on B, under another name: the same account }
  Join(B, 6, 'NiaOnB', '', 'HWN1', '2.2.2.6', TEAM_ALPHA);
  Kill(B, 6, 2);
  { the same name on another computer: an account of its own }
  Join(B, 7, 'Nia', '', 'HWN2', '2.2.2.7', TEAM_ALPHA);
  Kill(B, 7, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
    NiaA := ComputerAccount(A, 'HWN1', KillsA, RegA);
    Other := ComputerAccount(A, 'HWN2', KillsB, RegB);
  until ((KillsA = 2) and (Other > 0) and (KillsB = 1)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       on A: computer HWN1 #%d %d kills, computer HWN2 #%d %d kills', [NiaA, KillsA, Other, KillsB]));
  Check('the same computer under another name on B is the same account', KillsA = 2);
  Check('the same name on another computer is an account of its own', (Other > 0) and (Other <> NiaA) and (KillsB = 1));

  { ---- a password set on A: the same account logs in on B ---- }
  Cmd(A, 6, '/register nia-pass-7 nia-pass-7');
  T0 := MonoMs;
  repeat
    Sleep(200);
    NiaB := ComputerAccount(B, 'HWN1', KillsB, RegB);
  until RegB or (MonoMs - T0 > 20000);
  Check('a password set on A reaches B', RegB);
  { the owner leaves the first computer on B and comes back on one of their own: /login #id
    moves the session to the account - with the right password only }
  Leave(B, 6);
  Join(B, 8, 'NiaLaptop', '', 'HWN3', '2.2.2.8', TEAM_BRAVO);
  Sleep(300);
  Cmd(B, 8, Format('/login #%d wrong-pass-1', [NiaA]));
  Sleep(3000);
  Check('a wrong password does not log in on B', SessionOf(B, 8, Locked) <> NiaA);
  Cmd(B, 8, Format('/login #%d nia-pass-7', [NiaA]));
  T0 := MonoMs;
  repeat
    Sleep(200);
    Session := SessionOf(B, 8, Locked);
  until ((Session = NiaA) and not Locked) or (MonoMs - T0 > 20000);
  Check('the password set on A logs in on B', (Session = NiaA) and not Locked);

  { ---- a server that runs and stops without the database keeps what it collected ---- }
  C.Shutdown;
  C.Free;
  C := MakeEngine(Base + PathDelim + 'c', 3, 'mysql', False, '1');
  Check('server C starts from its files without the database', WaitReady(C));
  { the records of the map are counted without the database as well ([Matrix]) }
  MapAfter(C, 'ctf_Ash');
  Join(C, 1, 'Alice', 'S7001', 'HWC1', '3.3.3.1', TEAM_ALPHA);
  Join(C, 2, 'Eve', '', 'HWC2', '3.3.3.2', TEAM_BRAVO);
  Join(C, 3, 'Frank', 'S7006', 'HWC3', '3.3.3.3', TEAM_ALPHA);
  Kill(C, 1, 2);
  Kill(C, 1, 2);
  Kill(C, 3, 2);
  { meanwhile a new computer plays on A, and the same computer registers its account on C }
  Join(A, 10, 'OlaA', '', 'HWO1', '1.1.1.10', TEAM_ALPHA);
  Kill(A, 10, 2);
  Join(C, 4, 'Ola', '', 'HWO1', '3.3.3.4', TEAM_BRAVO);
  Sleep(300);
  Cmd(C, 4, '/register ola-pass-9 ola-pass-9');
  T0 := MonoMs;
  repeat
    Sleep(100);
    NiaB := ComputerAccount(C, 'HWO1', KillsB, RegB);
  until (RegB and (KillsOf(C, 'S7001') = 12) and (KillsOf(C, 'S7006') = 1) and
    (Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE name = ''OlaA''') = '1')) or (MonoMs - T0 > 20000);
  C.Shutdown;
  C.Free;
  Check('what waits for the database is kept beside the files',
    FileExists(Base + PathDelim + 'c' + PathDelim + 'data' + PathDelim + 'zitrostats.shared'));
  C := MakeEngine(Base + PathDelim + 'c', 3, 'mysql', False);
  Check('server C starts with the database again', WaitReady(C));
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((KillsOf(A, 'S7001') = 12) and (KillsOf(C, 'S7001') = 12) and (KillsOf(A, 'S7006') = 1)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       after C came back: Alice %d kills on A, %d on C; Frank %d on A', [KillsOf(A, 'S7001'),
    KillsOf(C, 'S7001'), KillsOf(A, 'S7006')]));
  Check('what C collected without the database reaches the others after its next start',
    (KillsOf(A, 'S7001') = 12) and (KillsOf(C, 'S7001') = 12) and (KillsOf(A, 'S7006') = 1));
  { the player-on-map records of an account new there ([Matrix]) waited for its number and go with
    the first exchange after the start: until then the list beside the files keeps them }
  T0 := MonoMs;
  repeat
    Sleep(200);
  until not FileExists(Base + PathDelim + 'c' + PathDelim + 'data' + PathDelim + 'zitrostats.shared') or
    (MonoMs - T0 > 20000);
  Check('and nothing waits beside the files any more',
    not FileExists(Base + PathDelim + 'c' + PathDelim + 'data' + PathDelim + 'zitrostats.shared'));
  { [Matrix]: the records C collected without the database were kept beside the files over the stop
    and reached the others after its next start - Frank's too, whose account was new there and got
    its number only in that start, and Eve's entry of Frank under that number }
  FrankId := IdOf(A, 'S7006');
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((PMKills(A, AliceId, 'ctf_Ash') = 12) and (PMKills(A, FrankId, 'ctf_Ash') = 1) and
    (PMDeaths(A, EveId, 'ctf_Ash') = 7) and (RivalKD(A, FrankId, 'ctf_Ash', EveId) = '1/0') and
    (RivalKD(A, EveId, 'ctf_Ash', FrankId) = '0/1') and (RivalKD(A, EveId, 'ctf_Ash', AliceId) = '0/6') and
    (PMRow(FrankId, 'ctf_Ash', 'kills') = '1')) or (MonoMs - T0 > 20000);
  WriteLn(Format('       after C came back: Alice %d kills on ctf_Ash on A, Frank #%d %d; Eve''s rivals on A:%s',
    [PMKills(A, AliceId, 'ctf_Ash'), FrankId, PMKills(A, FrankId, 'ctf_Ash'), RivalsText(A, EveId, 'ctf_Ash')]));
  Check('the records collected without the database survive the stop and reach the others',
    (PMKills(A, AliceId, 'ctf_Ash') = 12) and (PMKills(C, AliceId, 'ctf_Ash') = 12) and
    (RivalKD(A, EveId, 'ctf_Ash', AliceId) = '0/6') and (PMRow(AliceId, 'ctf_Ash', 'kills') = '12'));
  Check('a new account''s record too, and the entries naming it, under its number of the database',
    (FrankId > 0) and (PMKills(A, FrankId, 'ctf_Ash') = 1) and (RivalKD(A, FrankId, 'ctf_Ash', EveId) = '1/0') and
    (PMDeaths(A, EveId, 'ctf_Ash') = 7) and (RivalKD(A, EveId, 'ctf_Ash', FrankId) = '0/1') and
    (RivalsText(A, EveId, 'ctf_Ash') = RivalsText(C, EveId, 'ctf_Ash')));
  { the account registered on C without the database goes into the account of the same computer
    that A made meanwhile, with its password - as at the first start of a server (JoinDatabase) }
  T0 := MonoMs;
  repeat
    Sleep(200);
    NiaA := ComputerAccount(A, 'HWO1', KillsA, RegA);
  until RegA or (MonoMs - T0 > 20000);
  Check('a password set without the database joins the account of the same computer',
    RegA and (Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE hwid_key = ' +
    MyStr(MD5Print(MD5String('HWO1'))) + ' AND deleted = 0') = '1'));

  { ---- an account of an old import whose "SteamID" is longer than the column: the exchange
    goes on (strict mode would refuse the whole batch), the account goes in without it ---- }
  Join(A, 9, 'Legacy', 'S7109', 'HWA9', '1.1.1.9', TEAM_ALPHA);
  Kill(A, 9, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until (KillsByName(B, 'Legacy') = 1) or (MonoMs - T0 > 20000);
  SetSteam(A, 'Legacy', 'S' + StringOfChar('7', 60));
  Kill(A, 9, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until (KillsByName(B, 'Legacy') = 2) or (MonoMs - T0 > 20000);
  Check('a SteamID longer than its column does not stop the exchange', KillsByName(B, 'Legacy') = 2);
  Check('and the account goes in without it',
    Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE name = ''Legacy'' AND steam IS NULL AND deleted = 0') = '1');

  { ---- the change counter of the database went back (a backup put back): the servers go on
    reading each other's changes instead of waiting until it passes where it was ---- }
  K0 := KillsOf(A, 'S7001');
  KB0 := KillsOf(B, 'S7001');
  ExecSql('UPDATE zs_db_meta SET value = 1 WHERE name = ''seq''');
  Kill(B, 1, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((KillsOf(A, 'S7001') = K0 + 1) and (KillsOf(B, 'S7001') = KB0 + 1)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       after the counter went back: Alice %d kills on A (was %d), %d on B (was %d)',
    [KillsOf(A, 'S7001'), K0, KillsOf(B, 'S7001'), KB0]));
  Check('a change counter that went back does not stop the reading',
    (KillsOf(A, 'S7001') = K0 + 1) and (KillsOf(B, 'S7001') = KB0 + 1));

  { ---- a server that never joined the database and starts without it: it must not write its
    accounts by the numbers of its files (those numbers are other players' in the database) ---- }
  D := MakeEngine(Base + PathDelim + 'd', 4, 'local');
  Check('server D ready with its own files', WaitReady(D));
  Join(D, 1, 'Zed', 'S7101', 'HWD1', '4.4.4.1', TEAM_ALPHA);
  Join(D, 2, 'Yan', 'S7102', 'HWD2', '4.4.4.2', TEAM_BRAVO);
  Kill(D, 1, 2);
  Kill(D, 1, 2);
  T0 := MonoMs;
  repeat
    Sleep(100);
  until (KillsOf(D, 'S7101') = 2) or (MonoMs - T0 > 5000);
  D.Shutdown;
  D.Free;
  AliceRow := Scalar('SELECT CONCAT(id, '' '', steam, '' '', name) FROM zs_db_accounts WHERE steam = ''S7001'' AND deleted = 0');
  { a table made by hand with another engine refuses the start (no row locks, no transactions) }
  ExecSql('ALTER TABLE zs_db_jobs ENGINE = MyISAM');
  D := MakeEngine(Base + PathDelim + 'd', 4, 'mysql', False);
  GotA := WaitReady(D);
  WriteLn('       D: ', StatusOf(D));
  Check('server D starts from its files, the table of another engine refused', GotA and (Pos('InnoDB', StatusOf(D)) > 0));
  Join(D, 1, 'Zed', 'S7101', 'HWD1', '4.4.4.1', TEAM_ALPHA);
  Join(D, 2, 'Yan', 'S7102', 'HWD2', '4.4.4.2', TEAM_BRAVO);
  Kill(D, 1, 2);
  Kill(D, 1, 2);
  Sleep(1500);
  ExecSql('ALTER TABLE zs_db_jobs ENGINE = InnoDB');
  T0 := MonoMs;
  repeat
    Sleep(250);
  until (Pos('not joined', StatusOf(D)) > 0) or (MonoMs - T0 > 60000);
  WriteLn('       D: ', StatusOf(D));
  Check('a server that never joined finds out when the database answers, and stops', Pos('not joined', StatusOf(D)) > 0);
  Sleep(2500);
  Check('it wrote nothing into the accounts of the database',
    (Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE steam IN (''S7101'', ''S7102'')') = '0') and
    (Scalar('SELECT CONCAT(id, '' '', steam, '' '', name) FROM zs_db_accounts WHERE steam = ''S7001'' AND deleted = 0') = AliceRow));
  D.Shutdown;
  D.Free;
  Check('and keeps no list beside the files',
    not FileExists(Base + PathDelim + 'd' + PathDelim + 'data' + PathDelim + 'zitrostats.shared'));

  { ---- its next start joins it, with everything its files hold - even with the counter of the
    account numbers set back by hand, no account of the database is taken over ---- }
  MaxBefore := StrToInt64Def(Scalar('SELECT MAX(id) FROM zs_db_accounts'), 0);
  ExecSql('UPDATE zs_db_meta SET value = 1 WHERE name = ''next_account''');
  D := MakeEngine(Base + PathDelim + 'd', 4, 'mysql', False);
  Check('server D joins at its next start', WaitReady(D) and (Pos('connected', StatusOf(D)) > 0));
  T0 := MonoMs;
  repeat
    Sleep(200);
  until ((KillsOf(A, 'S7101') = 4) and (KillsOf(D, 'S7101') = 4)) or (MonoMs - T0 > 20000);
  WriteLn(Format('       Zed: %d kills on A, %d on D; numbers of D''s accounts from %s (the highest before: %d)',
    [KillsOf(A, 'S7101'), KillsOf(D, 'S7101'),
     Scalar('SELECT MIN(id) FROM zs_db_accounts WHERE steam IN (''S7101'', ''S7102'')'), MaxBefore]));
  Check('with everything its files hold', (KillsOf(A, 'S7101') = 4) and (KillsOf(D, 'S7101') = 4));
  Check('under numbers no account had',
    (StrToInt64Def(Scalar('SELECT MIN(id) FROM zs_db_accounts WHERE steam IN (''S7101'', ''S7102'')'), 0) > MaxBefore) and
    (Scalar('SELECT CONCAT(id, '' '', steam, '' '', name) FROM zs_db_accounts WHERE steam = ''S7001'' AND deleted = 0') = AliceRow));
  { a new player of D takes a free number too }
  Join(D, 2, 'Yan', 'S7102', 'HWD2', '4.4.4.2', TEAM_BRAVO);
  Join(D, 3, 'Gus', 'S7108', 'HWD8', '4.4.4.8', TEAM_ALPHA);
  Kill(D, 3, 2);
  T0 := MonoMs;
  repeat
    Sleep(200);
  until (KillsOf(A, 'S7108') = 1) or (MonoMs - T0 > 20000);
  GusId := StrToInt64Def(Scalar('SELECT id FROM zs_db_accounts WHERE steam = ''S7108'' AND deleted = 0'), 0);
  Check('a new account of D takes a number no account had', (KillsOf(A, 'S7108') = 1) and (GusId > MaxBefore) and
    (IdOf(D, 'S7108') = GusId) and (IdOf(A, 'S7108') = GusId) and
    (Scalar('SELECT COUNT(*) FROM zs_db_accounts WHERE steam = ''S7108''') = '1') and
    (Scalar('SELECT CONCAT(id, '' '', steam, '' '', name) FROM zs_db_accounts WHERE steam = ''S7001'' AND deleted = 0') = AliceRow));

  A.Shutdown;
  B.Shutdown;
  C.Shutdown;
  D.Shutdown;
  A.Free;
  B.Free;
  C.Free;
  D.Free;
  DropTables;
  DeleteTree(Base);
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  if Failures > 0 then
    Halt(1);
end.
