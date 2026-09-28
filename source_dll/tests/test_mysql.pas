program test_mysql;

{ The MySQL copy end to end: the engine runs with [MySQL] switched on, and what reaches the
  tables is read back. Needs a MySQL or MariaDB server and a user that may create tables:

    test_mysql <host> <port> <database> <user> <password>

  It works in its own server id (7777, and 7778 after a reload of the settings) and removes its
  tables at the end. The player-on-map records ([Matrix]) go to zs_player_map_stats: written,
  written again after a game, and a whole pass deletes the rows of records that are gone. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, base64, md5, zs_types, zs_util, zs_db, zs_fields, zs_weapons, zs_engine, zs_shared, zs_matrix,
  mysqlwire;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;

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

procedure MapAfter(const Name: AnsiString; Style, Limit: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := Limit;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Team: LongInt);
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
  Push(Ev);
end;

procedure Kill(K, V, Weapon: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND;
  Ev.I[3] := WEP_MP5;
  Ev.F[0] := 100;
  Ev.F[1] := 100;
  Ev.F[2] := 400;
  Ev.F[3] := 100;
  Push(Ev);
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

function Scalar(C: TMyConnection; const SQL: AnsiString): AnsiString;
var
  R: TMyResult;
begin
  R := C.Query(SQL);
  try
    Result := R.Str(0, 0);
  finally
    R.Free;
  end;
end;

procedure WriteSettings(const Root: AnsiString; ServerId: LongInt);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('[General]');
    L.Add('SourceCodepage = 1250');
    { a player without Steam counts at once }
    L.Add('[Identity]');
    L.Add('SteamAuthWaitSeconds = 0');
    L.Add('[MySQL]');
    L.Add('Enabled = 1');
    L.Add('Host = ' + ParamStr(1));
    L.Add('Port = ' + ParamStr(2));
    L.Add('Database = ' + ParamStr(3));
    L.Add('User = ' + ParamStr(4));
    L.Add('Password = ' + ParamStr(5));
    L.Add('ServerID = ' + IntToStr(ServerId));
    L.Add('MirrorIntervalSeconds = 5');
    L.Add('FullJson = 1');
    L.Add('SharedProfiles = 1');
    L.Add('SharedRankings = 1');
    L.Add('SharedMaps = 1');
    L.Add('SharedWeapons = 1');
    L.Add('SharedServer = 1');
    L.SaveToFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini');
  finally
    L.Free;
  end;
end;

{ an entry of a ranking whose account (with the other servers' numbers) has this name }
function EntryNamed(E: TZSEngine; const Entries: TRankEntryArray; const Name: AnsiString): Boolean;
var
  k: LongInt;
  Tmp: TPlayerProfile;
  P: PPlayerProfile;
begin
  Result := False;
  Tmp := Default(TPlayerProfile);
  for k := 0 to High(Entries) do
  begin
    P := RankingView(E, Entries[k], Tmp);
    if (P <> nil) and (P^.ActiveName = Name) then
      Exit(True);
  end;
end;

function EntryOf(const Entries: TRankEntryArray; Idx: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(Entries) do
    if Entries[k].Idx = Idx then
      Exit(True);
end;

{ [Matrix]: the number of the account of a name, -1 when there is none }
function AccountNamed(const Name: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 0 to Engine.DB.ProfileCount - 1 do
      if Engine.DB.Valid(k) and (Engine.DB.Profiles[k]^.ActiveName = Name) then
        Result := Engine.DB.Profiles[k]^.ID;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ the record of an account on a map in memory as 'kills deaths points', '' when there is none }
function RecordText(AccountId: LongInt; const Map: AnsiString): AnsiString;
var
  R: PPlayerMapStats;
begin
  Result := '';
  EnterCriticalSection(Engine.StateLock);
  try
    R := Engine.DB.PM.Find(AccountId, Map);
    if R <> nil then
      Result := Format('%d %d %d', [R^.Kills, R^.Deaths, R^.Points]);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ the same from the row of zs_player_map_stats, '' when there is none }
function RowText(C: TMyConnection; ServerId, AccountId: LongInt; const Map: AnsiString): AnsiString;
var
  R: TMyResult;
begin
  Result := '';
  R := C.Query(Format('SELECT CONCAT(kills, '' '', deaths, '' '', points) FROM zs_player_map_stats WHERE ' +
    'server_id = %d AND account_id = %d AND map_name = %s', [ServerId, AccountId, MyStr(Map)]));
  try
    if R.RowCount > 0 then
      Result := R.Str(0, 0);
  finally
    R.Free;
  end;
end;

var
  Root: AnsiString;
  C: TMyConnection;
  T0: Int64;
  Rows, k, Idx: LongInt;
  Name, Got, Steam, Note: AnsiString;
  Other, Tmp, Sums: TPlayerProfile;
  V: PPlayerProfile;
  LocalPoints, MI, LocalMapKills, Combined, FarPoints: LongInt;
  OtherMap, MapTmp: TMapProfile;
  OtherSrv, SrvTmp: TServerRecords;
  LocalMatches: Int64;
  Order, Entries: TRankEntryArray;
  MapOk, SrvOk, SumOk, RankOk: Boolean;
  HanaKills: LongInt;
  BobIdx, ZbIdx, BobPlace, ZbPoints, ZbLocal: LongInt;
  BobLast, ZbLast: Double;
  OldIn, BobIn, ZbIn, AllIn: Boolean;
  { [Matrix] }
  ZbNo, BobNo: LongInt;
  Mem, Row, BobRow: AnsiString;
  QR: TMyResult;
  Act: TZSAction;
begin
  if ParamCount < 4 then
  begin
    WriteLn('Usage: test_mysql <host> <port> <database> <user> [password]');
    Halt(2);
  end;
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'mysql_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);

  { a table from another layout (no JSON column) and a row of an account that no longer exists }
  C := Conn;
  try
    C.Connect;
    C.Exec('DROP TABLE IF EXISTS zs_players');
    C.Exec('DROP TABLE IF EXISTS zs_maps');
    C.Exec('DROP TABLE IF EXISTS zs_server');
    C.Exec('DROP TABLE IF EXISTS zs_player_map_stats');
    C.Exec('CREATE TABLE zs_players (server_id INT NOT NULL, profile_id INT NOT NULL, name VARCHAR(64) NOT NULL, ' +
      'points INT NOT NULL, updated_at DATETIME NOT NULL, PRIMARY KEY (server_id, profile_id))');
    C.Exec('INSERT INTO zs_players VALUES (7777, 999, ''Gone'', 1000, ''2020-01-01 00:00:00'')');
    C.Exec('INSERT INTO zs_players VALUES (8888, 1, ''Another server'', 1000, ''2020-01-01 00:00:00'')');
  finally
    C.Free;
  end;

  WriteSettings(Root, 7777);

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready', WaitReady);
  CurTick := 0;
  MapAfter('ctf_Ash', GS_CTF, 10);
  { a Polish name as the game sends it, in code page 1250: Zbyszek with an l with stroke }
  Name := 'Zbyszek '#$B3#$F3#$BF' ''q'' \x';
  Join(1, Name, 'S2001', 'HW1', '1.1.1.1', TEAM_ALPHA);
  Join(2, 'Bob', 'S2002', 'HW2', '2.2.2.2', TEAM_BRAVO);
  CurTick := 100;
  Kill(1, 2, WEP_AK74);

  { the first run of the copy is a whole one; it comes within MirrorIntervalSeconds }
  C := Conn;
  try
    C.Connect;
    T0 := MonoMs;
    Rows := 0;
    repeat
      Sleep(250);
      try
        Rows := StrToIntDef(Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 7777'), 0);
      except
        Rows := 0;
      end;
    until (Rows >= 2) or (MonoMs - T0 > 20000);
    Check('both accounts reached the table', Rows = 2);
    Check('the missing JSON column was added to the old table',
      Scalar(C, 'SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND ' +
        'table_name = ''zs_players'' AND column_name = ''data''') = '1');
    Got := Scalar(C, 'SELECT name FROM zs_players WHERE server_id = 7777 AND kills = 1');
    Check('the name arrives as UTF-8', Got = 'Zbyszek '#$C5#$82#$C3#$B3#$C5#$BC' ''q'' \x');
    if Got <> 'Zbyszek '#$C5#$82#$C3#$B3#$C5#$BC' ''q'' \x' then
      WriteLn('       got: ', Got, ' (', Length(Got), ' bytes)');
    Check('the numbers arrive', (Scalar(C, 'SELECT kills FROM zs_players WHERE server_id = 7777 AND kills = 1') = '1') and
      (StrToIntDef(Scalar(C, 'SELECT points FROM zs_players WHERE server_id = 7777 AND kills = 1'), 0) > 1000));
    Check('the complete statistics as JSON', Pos('"kills"', Scalar(C, 'SELECT data FROM zs_players WHERE server_id = 7777 ' +
      'AND kills = 1')) > 0);
    Check('the account that is gone was removed', Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 7777 AND ' +
      'profile_id = 999') = '0');
    Check('another server''s rows stay', Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 8888') = '1');
    Check('the map and the server rows', (Scalar(C, 'SELECT name FROM zs_maps WHERE server_id = 7777') = 'ctf_Ash') and
      (Scalar(C, 'SELECT accounts FROM zs_server WHERE server_id = 7777') = '2'));

    { [Matrix]: the records of both players on ctf_Ash, as memory has them }
    ZbNo := AccountNamed(Name);
    BobNo := AccountNamed('Bob');
    T0 := MonoMs;
    repeat
      Sleep(250);
      Mem := RecordText(ZbNo, 'ctf_Ash');
      try
        Row := RowText(C, 7777, ZbNo, 'ctf_Ash');
        BobRow := RowText(C, 7777, BobNo, 'ctf_Ash');
      except
        Row := '';
        BobRow := '';
      end;
    until ((Mem <> '') and (Row = Mem) and (Pos('1 ', Row) = 1) and (BobRow = RecordText(BobNo, 'ctf_Ash'))) or
      (MonoMs - T0 > 20000);
    WriteLn('       zs_player_map_stats: ', Name, ' "', Row, '", Bob "', BobRow, '" (kills deaths points)');
    Check('the records of every account on every map reach zs_player_map_stats', (Mem <> '') and (Row = Mem) and
      (Pos('1 ', Row) = 1) and (BobRow <> '') and (BobRow = RecordText(BobNo, 'ctf_Ash')) and
      (Scalar(C, 'SELECT COUNT(*) FROM zs_player_map_stats WHERE server_id = 7777') = '2'));
    { a row of a record that is gone, and a row of another server }
    C.Exec('INSERT INTO zs_player_map_stats (server_id, account_id, map_name, kills, updated_at) VALUES ' +
      '(7777, 999, ''ctf_Gone'', 5, ''2020-01-01 00:00:00''), (8888, 1, ''ctf_Ash'', 3, ''2020-01-01 00:00:00'')');

    { a player who has been on the server for a long time: the time of the last game is only
      written at join and leave, and the next (partial) pass sends the new kill all the same }
    EnterCriticalSection(Engine.StateLock);
    try
      for k := 0 to Engine.DB.ProfileCount - 1 do
        if Engine.DB.Valid(k) then
          Engine.DB.Profiles[k]^.LastPlayedTime := Now - 1 / 24;
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    CurTick := 200;
    Kill(1, 2, WEP_AK74);
    T0 := MonoMs;
    repeat
      Sleep(250);
      Got := Scalar(C, 'SELECT MAX(kills) FROM zs_players WHERE server_id = 7777');
    until (Got = '2') or (MonoMs - T0 > 20000);
    Check('a player on the server for long reaches the copy in the next partial pass', Got = '2');
    { [Matrix]: the record played again is written again in a partial pass }
    T0 := MonoMs;
    repeat
      Sleep(250);
      Mem := RecordText(ZbNo, 'ctf_Ash');
      Row := RowText(C, 7777, ZbNo, 'ctf_Ash');
    until ((Pos('2 ', Mem) = 1) and (Row = Mem)) or (MonoMs - T0 > 20000);
    Check('a record played again is written again in the next partial pass', (Pos('2 ', Mem) = 1) and (Row = Mem) and
      (Scalar(C, 'SELECT COUNT(*) FROM zs_player_map_stats WHERE server_id = 7777 AND account_id = 999') = '1'));

    { Another server of this database (8888) wrote what it shares: the same Steam account with 5
      kills there, a Steam player who never played here, the map ctf_Ash with 7 kills, and its
      server record with the sum of its accounts. Every Shared switch is on here. }
    Steam := Scalar(C, 'SELECT steam_id FROM zs_players WHERE server_id = 7777 AND kills = 2');
    Check('the SteamID and the whole record reach the table', (Steam <> '') and
      (Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 7777 AND shared_data IS NOT NULL') = '2') and
      (Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 7777 AND shared_at IS NOT NULL') = '2'));
    Check('the map and the server share their records',
      (Scalar(C, 'SELECT COUNT(*) FROM zs_maps WHERE server_id = 7777 AND shared_data IS NOT NULL') = '1') and
      (Scalar(C, 'SELECT COUNT(*) FROM zs_server WHERE server_id = 7777 AND shared_sum IS NOT NULL') = '1'));
    ClearProfile(Other);
    Other.Kills := 5;
    Other.Deaths := 3;
    Other.Points := 5000;
    C.Exec('UPDATE zs_players SET steam_id = ' + MyStr(Steam) + ', shared_data = ' +
      MyStr(EncodeStringBase64(EncodeProfile(Other))) + ', shared_at = NOW() WHERE server_id = 8888');
    ClearProfile(Other);
    Other.ActiveName := 'Farplayer';
    Other.Kills := 9;
    Other.Points := 1500;
    C.Exec('INSERT INTO zs_players (server_id, profile_id, name, points, updated_at, steam_id, shared_data, shared_at) ' +
      'VALUES (8888, 2, ''Farplayer'', 1500, NOW(), ''S9999'', ' + MyStr(EncodeStringBase64(EncodeProfile(Other))) + ', NOW())');
    ClearMap(OtherMap);
    OtherMap.MapName := 'ctf_Ash';
    OtherMap.Kills := 7;
    OtherMap.ActiveMapPlays := 2;
    C.Exec('INSERT INTO zs_maps (server_id, map_id, name, updated_at, shared_data, shared_at) VALUES (8888, 1, ''ctf_Ash'', NOW(), ' +
      MyStr(EncodeStringBase64(EncodeMap(OtherMap))) + ', NOW())');
    { and a map this server never played }
    OtherMap.MapName := 'ctf_Faraway';
    C.Exec('INSERT INTO zs_maps (server_id, map_id, name, updated_at, shared_data, shared_at) VALUES (8888, 2, ''ctf_Faraway'', ' +
      'NOW(), ' + MyStr(EncodeStringBase64(EncodeMap(OtherMap))) + ', NOW())');
    ClearServer(OtherSrv);
    OtherSrv.TotalMatches := 5;
    OtherSrv.PeakOnlineCount := 99;
    OtherSrv.WeaponGlobal[WepSlot(WEP_AK74)].Picks := 4;
    ClearProfile(Other);
    Other.Kills := 11;
    C.Exec('INSERT INTO zs_server (server_id, updated_at, shared_data, shared_sum, shared_at) VALUES (8888, NOW(), ' +
      MyStr(EncodeStringBase64(EncodeServer(OtherSrv))) + ', ' + MyStr(EncodeStringBase64(EncodeProfile(Other))) + ', NOW())');
    T0 := MonoMs;
    LocalPoints := -1;
    repeat
      Sleep(250);
      Got := '';
      MapOk := False;
      SrvOk := False;
      SumOk := False;
      RankOk := False;
      EnterCriticalSection(Engine.StateLock);
      try
        Idx := -1;
        for k := 0 to Engine.DB.ProfileCount - 1 do
          if Engine.DB.Valid(k) and (Engine.DB.Profiles[k]^.Kills = 2) then
            Idx := k;
        if Idx >= 0 then
        begin
          V := SharedView(Engine, Idx, Tmp, Note);
          Got := IntToStr(V^.Kills) + ' ' + V^.ActiveName;
          if V^.Points = Engine.DB.Profiles[Idx]^.Points then
            LocalPoints := V^.Points;
          { the ranking of every server: 4000 points won there, and the player of the other server }
          Order := RankingOrder(Engine);
          Combined := -1;
          FarPoints := -1;
          for k := 0 to High(Order) do
          begin
            if Order[k].Idx = Idx then
              Combined := Order[k].Points;
            if Order[k].Idx < 0 then
              FarPoints := Order[k].Points;
          end;
          RankOk := (Combined = Engine.DB.Profiles[Idx]^.Points + 4000) and (FarPoints = 1500) and
            (RankingPosition(Engine, Idx) = 1);
        end;
        MI := Engine.DB.FindMap('ctf_Ash', False);
        if MI >= 0 then
        begin
          LocalMapKills := Engine.DB.Maps[MI].Kills;
          MapOk := (SharedMapView(Engine, MI, MapTmp)^.Kills = LocalMapKills + 7) and
            (FindPoolMap(Engine, 'faraway') = 'ctf_faraway') and (PoolMapView(Engine, 'ctf_faraway', MapTmp) <> nil) and
            (MapTmp.Kills = 7);
        end;
        LocalMatches := Engine.DB.Server.TotalMatches;
        SrvOk := (SharedServerView(Engine, True, SrvTmp)^.TotalMatches = LocalMatches + 5) and
          (SrvTmp.PeakOnlineCount = 99) and (SrvTmp.WeaponGlobal[WepSlot(WEP_AK74)].Picks >=
          Engine.DB.Server.WeaponGlobal[WepSlot(WEP_AK74)].Picks + 4);
        SumOk := SharedAccountSums(Engine, True, Sums) and (Sums.Kills = 11);
      finally
        LeaveCriticalSection(Engine.StateLock);
      end;
    until ((Pos('7 ', Got) = 1) and RankOk and MapOk and SrvOk and SumOk) or (MonoMs - T0 > 20000);
    WriteLn('       shared view: ', Got);
    Check('SharedProfiles adds the kills of the other server', Pos('7 ', Got) = 1);
    Check('and names the number of servers', Pos('[2 servers]', Got) > 0);
    Check('the points of the profile stay this server''s', (LocalPoints > 0) and (LocalPoints < 5000));
    Check('SharedRankings: the points won everywhere, and the player who never played here', RankOk);
    Check('SharedMaps: the same map on the other server is added, and a map never played here is known', MapOk);
    Check('SharedServer: the matches, the peak and the picks of the other server', SrvOk);
    Check('SharedWeapons: the accounts of the other server added up', SumOk);
    { the original record is not touched by the views }
    EnterCriticalSection(Engine.StateLock);
    try
      Check('the views leave this server''s account alone', (Idx >= 0) and (Engine.DB.Profiles[Idx]^.Kills = 2) and
        (Pos('servers', Engine.DB.Profiles[Idx]^.ActiveName) = 0));
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;

    { an account without Steam is the account of its computer, on the other servers as well: the row
      of the same computer adds up, a row of the same name from another computer does not }
    Join(3, 'Hana', '', 'HW3', '3.3.3.3', TEAM_ALPHA);
    CurTick := 300;
    Kill(3, 2, WEP_AK74);
    ClearProfile(Other);
    Other.ActiveName := 'Hana';
    Other.Kills := 4;
    C.Exec('INSERT INTO zs_players (server_id, profile_id, name, points, updated_at, steam_id, shared_data, shared_at) ' +
      'VALUES (8888, 3, ''Hana'', 1000, NOW(), ' + MyStr('H:' + MD5Print(MD5String('HW3'))) + ', ' +
      MyStr(EncodeStringBase64(EncodeProfile(Other))) + ', NOW())');
    Other.Kills := 50;
    C.Exec('INSERT INTO zs_players (server_id, profile_id, name, points, updated_at, steam_id, shared_data, shared_at) ' +
      'VALUES (8888, 4, ''Hana'', 1000, NOW(), ' + MyStr('H:' + MD5Print(MD5String('HW9'))) + ', ' +
      MyStr(EncodeStringBase64(EncodeProfile(Other))) + ', NOW())');
    T0 := MonoMs;
    HanaKills := -1;
    repeat
      Sleep(250);
      EnterCriticalSection(Engine.StateLock);
      try
        for k := 0 to Engine.DB.ProfileCount - 1 do
          if Engine.DB.Valid(k) and (Engine.DB.Profiles[k]^.ActiveHWID = 'HW3') and (Engine.DB.Profiles[k]^.Kills = 1) then
            HanaKills := SharedView(Engine, k, Tmp, Note)^.Kills;
      finally
        LeaveCriticalSection(Engine.StateLock);
      end;
    until (HanaKills = 5) or (MonoMs - T0 > 20000);
    WriteLn('       Hana (no Steam, computer HW3): ', HanaKills, ' kills in the shared view');
    Check('SharedProfiles: an account without Steam adds the account of the same computer, not of the same name',
      HanaKills = 5);

    { SharedRankings leaves out, as this server's ranking does (InactivityMode = decay), who has
      played on no server for DecayHideAfterDays: an account of this server, and a player of the
      other server only; the lists that go through every account still have them }
    ClearProfile(Other);
    Other.ActiveName := 'Oldfar';
    Other.Kills := 3;
    Other.Points := 1200;
    Other.LastPlayedTime := Now - 100;
    C.Exec('INSERT INTO zs_players (server_id, profile_id, name, points, updated_at, steam_id, shared_data, shared_at) ' +
      'VALUES (8888, 5, ''Oldfar'', 1200, NOW(), ''S9998'', ' + MyStr(EncodeStringBase64(EncodeProfile(Other))) + ', NOW())');
    T0 := MonoMs;
    OldIn := False;
    repeat
      Sleep(250);
      EnterCriticalSection(Engine.StateLock);
      try
        OldIn := EntryNamed(Engine, RankingEntries(Engine), 'Oldfar');
      finally
        LeaveCriticalSection(Engine.StateLock);
      end;
    until OldIn or (MonoMs - T0 > 20000);
    Check('the player of the other server who stopped playing long ago is known', OldIn);
    BobIdx := -1;
    ZbIdx := -1;
    BobLast := 0;
    ZbLast := 0;
    EnterCriticalSection(Engine.StateLock);
    try
      for k := 0 to Engine.DB.ProfileCount - 1 do
        if Engine.DB.Valid(k) then
        begin
          if Engine.DB.Profiles[k]^.ActiveName = 'Bob' then
            BobIdx := k;
          if Engine.DB.Profiles[k]^.ActiveSteam = Steam then
            ZbIdx := k;
        end;
      if (BobIdx >= 0) and (ZbIdx >= 0) then
      begin
        BobLast := Engine.DB.Profiles[BobIdx]^.LastPlayedTime;
        ZbLast := Engine.DB.Profiles[ZbIdx]^.LastPlayedTime;
        Engine.DB.HideAfterDays := 30;
        Engine.DB.Profiles[BobIdx]^.LastPlayedTime := Now - 100;
        Engine.DB.Profiles[ZbIdx]^.LastPlayedTime := Now - 100;
        Engine.DB.RebuildRanks;
      end;
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    { the ranking of every server is built again after a few seconds }
    Sleep(3500);
    BobIn := True;
    ZbIn := True;
    AllIn := False;
    BobPlace := -1;
    ZbPoints := -1;
    ZbLocal := -2;
    EnterCriticalSection(Engine.StateLock);
    try
      if (BobIdx >= 0) and (ZbIdx >= 0) then
      begin
        Order := RankingOrder(Engine);
        BobIn := EntryOf(Order, BobIdx);
        ZbIn := EntryOf(Order, ZbIdx);
        OldIn := EntryNamed(Engine, Order, 'Oldfar');
        Entries := RankingEntries(Engine);
        AllIn := EntryOf(Entries, BobIdx) and EntryOf(Entries, ZbIdx) and EntryNamed(Engine, Entries, 'Oldfar');
        BobPlace := RankingPosition(Engine, BobIdx);
        ZbPoints := RankingPoints(Engine, ZbIdx);
        ZbLocal := Engine.DB.Profiles[ZbIdx]^.Points;
        { back as it was }
        Engine.DB.HideAfterDays := 0;
        Engine.DB.Profiles[BobIdx]^.LastPlayedTime := BobLast;
        Engine.DB.Profiles[ZbIdx]^.LastPlayedTime := ZbLast;
        Engine.DB.RebuildRanks;
      end;
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    Check('SharedRankings leaves out who played on no server for too long, here or there',
      not BobIn and not ZbIn and not OldIn and (BobPlace = 0));
    Check('the lists that go through every account still have them', AllIn);
    Check('an account left out keeps the points of every server', ZbPoints = ZbLocal + 4000);

    { an account of an old import whose "SteamID" is longer than the column: the copy goes on
      (strict mode would refuse the whole pass) and the row goes in without it }
    EnterCriticalSection(Engine.StateLock);
    try
      for k := 0 to Engine.DB.ProfileCount - 1 do
        if Engine.DB.Valid(k) and (Engine.DB.Profiles[k]^.ActiveName = 'Bob') then
        begin
          Engine.DB.BeginIdentityChange(k);
          Engine.DB.Profiles[k]^.ActiveSteam := 'S' + StringOfChar('8', 50);
          Engine.DB.EndIdentityChange(k);
          Engine.DB.Touch(k);
        end;
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    CurTick := 400;
    Kill(2, 1, WEP_AK74);
    T0 := MonoMs;
    repeat
      Sleep(250);
      Got := Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 7777 AND name = ''Bob'' AND kills = 1 AND ' +
        'steam_id IS NULL');
    until (Got = '1') or (MonoMs - T0 > 20000);
    Check('a SteamID longer than its column does not stop the copy', Got = '1');

    { a reload of settings.ini with other [MySQL] settings moves the copy to them: the thread made
      with the old ones stops and one with the new ones starts }
    WriteSettings(Root, 7778);
    Push(NewEvent(zeReloadConfig));
    T0 := MonoMs;
    Rows := 0;
    repeat
      Sleep(250);
      Rows := StrToIntDef(Scalar(C, 'SELECT COUNT(*) FROM zs_players WHERE server_id = 7778'), 0);
    until (Rows >= 3) or (MonoMs - T0 > 20000);
    Check('a reload with another ServerID moves the copy to it', Rows >= 3);

    { [Matrix]: the records went along; then Bob's records go here (a reset of his statistics), and
      the whole pass of the copy that starts again under 7777 deletes the rows of the records that
      are gone - Bob's and the one inserted by hand - and leaves the other server's row alone }
    T0 := MonoMs;
    repeat
      Sleep(250);
      Row := Scalar(C, 'SELECT COUNT(*) FROM zs_player_map_stats WHERE server_id = 7778');
    until (StrToIntDef(Row, 0) >= 3) or (MonoMs - T0 > 20000);
    Check('the records went along to the other ServerID', StrToIntDef(Row, 0) >= 3);
    EnterCriticalSection(Engine.StateLock);
    try
      Engine.DB.PM.RemoveRecordsOf(BobNo);
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    Check('Bob had a row before', RowText(C, 7777, BobNo, 'ctf_Ash') <> '');
    WriteSettings(Root, 7777);
    Push(NewEvent(zeReloadConfig));
    T0 := MonoMs;
    repeat
      Sleep(250);
      Rows := StrToIntDef(Scalar(C, 'SELECT COUNT(*) FROM zs_player_map_stats WHERE server_id = 7777 AND ' +
        '(account_id = 999 OR account_id = ' + IntToStr(BobNo) + ')'), -1);
      Mem := RecordText(ZbNo, 'ctf_Ash');
      Row := RowText(C, 7777, ZbNo, 'ctf_Ash');
    until ((Rows = 0) and (Row = Mem) and (Mem <> '')) or (MonoMs - T0 > 20000);
    WriteLn('       after the whole pass: ', Rows, ' row(s) of records that are gone, ', Name, ' "', Row, '"');
    if Rows <> 0 then
    begin
      { what is left, and what the copy said }
      QR := C.Query('SELECT account_id, map_name, updated_at FROM zs_player_map_stats WHERE server_id = 7777');
      try
        for k := 0 to QR.RowCount - 1 do
          WriteLn('       left: #', QR.Str(k, 0), ' ', QR.Str(k, 1), ' ', QR.Str(k, 2));
      finally
        QR.Free;
      end;
      while Engine.PopAction(Act) do
        if Pos('MySQL', Act.Text) > 0 then
          WriteLn('       console: ', Act.Text);
    end;
    Check('the whole pass deletes the rows of records that are gone, and writes the others', (Rows = 0) and
      (Mem <> '') and (Row = Mem) and (RowText(C, 7777, BobNo, 'ctf_Ash') = ''));
    Check('the rows of another server stay', Scalar(C, 'SELECT kills FROM zs_player_map_stats WHERE server_id = 8888 ' +
      'AND account_id = 1') = '3');
    { the whole pass after the restart of the copy may come within the second of the last pass
      before it: every pass writes a later second, or that pass would keep the rows of that second }
    Check('every pass of the copy writes a later time than the passes before it, also after a restart',
      Scalar(C, 'SELECT (SELECT MIN(updated_at) FROM zs_player_map_stats WHERE server_id = 7777) > ' +
        '(SELECT MAX(updated_at) FROM zs_player_map_stats WHERE server_id = 7778)') = '1');
  finally
    C.Free;
  end;

  Engine.Shutdown;
  Engine.Free;

  C := Conn;
  try
    C.Connect;
    C.Exec('DROP TABLE IF EXISTS zs_players');
    C.Exec('DROP TABLE IF EXISTS zs_maps');
    C.Exec('DROP TABLE IF EXISTS zs_server');
    C.Exec('DROP TABLE IF EXISTS zs_player_map_stats');
  finally
    C.Free;
  end;
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  if Failures > 0 then
    Halt(1);
end.
