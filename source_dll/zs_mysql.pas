unit zs_mysql;

{ Optional one-way mirror of the statistics into a MySQL or MariaDB database for websites.

  The connection is made by mysqlwire, which speaks the database protocol itself: no client
  library is needed, so a 32-bit server writes into any MySQL or MariaDB, 32- or 64-bit.
  The game never waits for the database: every MirrorIntervalSeconds the engine thread collects
  the changed rows and the mirror thread writes them, many rows per statement.
  The statistics files stay the source of truth; the database is only a copy, so tables can be
  dropped at any time and are filled again within an hour. Every full pass also deletes the rows
  it did not write again, so accounts that were removed or merged disappear from the copy.
  Several game servers can share one database; every row carries the ServerID. With a Shared
  switch the rows also carry what the other servers add up (zs_shared), and after every pass the
  thread reads what the other servers wrote into the pool of zs_shared. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_rules, zs_engine;

procedure MirrorTick(E: TZSEngine; NowMs: Int64);
procedure MirrorShutdown(E: TZSEngine);
{ the whole record of an account (SharedProfiles, SharedRankings) or of a map (SharedMaps) goes
  along in this pass: in every whole pass (the first one, then one an hour) - so a change made
  without a game, such as the daily balance or a reset, reaches the other servers within the hour,
  as the other columns do - and in between when it was played since the last pass (Active: on
  the server now, or the running map) }
function MirrorRecordDue(Full, Active: Boolean; LastPlayed, Since: TDateTime): Boolean;

implementation

uses
  base64, md5, mysqlwire, zs_fields, zs_service, zs_crash, zs_export, zs_shared, zs_matrix;

const
  ERROR_REPEAT_MS = 10 * 60 * 1000;
  FULL_MIRROR_MS = 60 * 60 * 1000;

  { the tables: a table that is already there gets the columns it lacks (MyPrepareTable) }
  PLAYER_COLS: array[0..21] of AnsiString = (
    'server_id INT NOT NULL', 'profile_id INT NOT NULL', 'name VARCHAR(64) NOT NULL DEFAULT ''''',
    'points INT NOT NULL DEFAULT 0', 'rank_pos INT NOT NULL DEFAULT 0', 'rating DOUBLE NOT NULL DEFAULT 0',
    'kills INT NOT NULL DEFAULT 0', 'deaths INT NOT NULL DEFAULT 0', 'assists INT NOT NULL DEFAULT 0',
    'headshots INT NOT NULL DEFAULT 0', 'shots INT NOT NULL DEFAULT 0', 'hits INT NOT NULL DEFAULT 0',
    'wins INT NOT NULL DEFAULT 0', 'loses INT NOT NULL DEFAULT 0', 'caps INT NOT NULL DEFAULT 0',
    'playtime_sec BIGINT NOT NULL DEFAULT 0', 'last_seen DATETIME NULL', 'updated_at DATETIME NULL',
    'data MEDIUMTEXT NULL', 'steam_id VARCHAR(40) NULL', 'shared_data MEDIUMTEXT NULL', 'shared_at DATETIME NULL');
  PLAYER_KEYS = 'PRIMARY KEY (server_id, profile_id), KEY idx_points (server_id, points)';
  MAP_COLS: array[0..10] of AnsiString = (
    'server_id INT NOT NULL', 'map_id INT NOT NULL', 'name VARCHAR(64) NOT NULL DEFAULT ''''',
    'plays INT NOT NULL DEFAULT 0', 'kills INT NOT NULL DEFAULT 0', 'caps INT NOT NULL DEFAULT 0',
    'playtime_sec BIGINT NOT NULL DEFAULT 0', 'last_played DATETIME NULL', 'updated_at DATETIME NULL',
    'shared_data MEDIUMTEXT NULL', 'shared_at DATETIME NULL');
  MAP_KEYS = 'PRIMARY KEY (server_id, map_id)';
  SERVER_COLS: array[0..7] of AnsiString = (
    'server_id INT NOT NULL', 'accounts INT NOT NULL DEFAULT 0', 'peak_online INT NOT NULL DEFAULT 0',
    'total_matches BIGINT NOT NULL DEFAULT 0', 'updated_at DATETIME NULL', 'shared_data MEDIUMTEXT NULL',
    'shared_sum MEDIUMTEXT NULL', 'shared_at DATETIME NULL');
  SERVER_KEYS = 'PRIMARY KEY (server_id)';

  { the rows go in many at a time: INSERT ... VALUES (...), (...) ON DUPLICATE KEY UPDATE ...; the
    columns of FullJson and of the Shared switches are added to these when they are on }
  SQL_PLAYER_COLS =
    'server_id, profile_id, name, points, rank_pos, rating, kills, deaths, assists, headshots, ' +
    'shots, hits, wins, loses, caps, playtime_sec, last_seen, updated_at';
  SQL_PLAYER_TAIL =
    'ON DUPLICATE KEY UPDATE name = VALUES(name), points = VALUES(points), rank_pos = VALUES(rank_pos), ' +
    'rating = VALUES(rating), kills = VALUES(kills), deaths = VALUES(deaths), assists = VALUES(assists), ' +
    'headshots = VALUES(headshots), shots = VALUES(shots), hits = VALUES(hits), wins = VALUES(wins), ' +
    'loses = VALUES(loses), caps = VALUES(caps), playtime_sec = VALUES(playtime_sec), last_seen = VALUES(last_seen), ' +
    'updated_at = VALUES(updated_at)';
  SQL_MAP_COLS = 'server_id, map_id, name, plays, kills, caps, playtime_sec, last_played, updated_at';
  SQL_MAP_TAIL =
    'ON DUPLICATE KEY UPDATE name = VALUES(name), plays = VALUES(plays), kills = VALUES(kills), caps = VALUES(caps), ' +
    'playtime_sec = VALUES(playtime_sec), last_played = VALUES(last_played), updated_at = VALUES(updated_at)';
  SQL_SERVER_COLS = 'server_id, accounts, peak_online, total_matches, updated_at';
  SQL_SERVER_TAIL =
    'ON DUPLICATE KEY UPDATE accounts = VALUES(accounts), peak_online = VALUES(peak_online), ' +
    'total_matches = VALUES(total_matches), updated_at = VALUES(updated_at)';

  { [Matrix]: what every account did on every map of this server (zs_matrix), the main counters of
    each record, for websites }
  PM_COLS: array[0..24] of AnsiString = (
    'server_id INT NOT NULL', 'account_id INT NOT NULL', 'map_name VARCHAR(64) NOT NULL',
    'matches INT NOT NULL DEFAULT 0', 'wins INT NOT NULL DEFAULT 0', 'losses INT NOT NULL DEFAULT 0',
    'draws INT NOT NULL DEFAULT 0', 'rounds_won INT NOT NULL DEFAULT 0', 'rounds_lost INT NOT NULL DEFAULT 0',
    'kills INT NOT NULL DEFAULT 0', 'deaths INT NOT NULL DEFAULT 0', 'assists INT NOT NULL DEFAULT 0',
    'selfkills INT NOT NULL DEFAULT 0', 'teamkills INT NOT NULL DEFAULT 0', 'points INT NOT NULL DEFAULT 0',
    'caps INT NOT NULL DEFAULT 0', 'shots INT NOT NULL DEFAULT 0', 'hits INT NOT NULL DEFAULT 0',
    'headshots INT NOT NULL DEFAULT 0', 'damage_dealt DOUBLE NOT NULL DEFAULT 0',
    'damage_received DOUBLE NOT NULL DEFAULT 0', 'playtime_sec BIGINT NOT NULL DEFAULT 0',
    'first_played DATETIME NULL', 'last_played DATETIME NULL', 'updated_at DATETIME NULL');
  PM_KEYS = 'PRIMARY KEY (server_id, account_id, map_name), KEY idx_map (server_id, map_name)';
  SQL_PM_COLS =
    'server_id, account_id, map_name, matches, wins, losses, draws, rounds_won, rounds_lost, kills, deaths, ' +
    'assists, selfkills, teamkills, points, caps, shots, hits, headshots, damage_dealt, damage_received, ' +
    'playtime_sec, first_played, last_played, updated_at';
  SQL_PM_TAIL =
    'ON DUPLICATE KEY UPDATE matches = VALUES(matches), wins = VALUES(wins), losses = VALUES(losses), ' +
    'draws = VALUES(draws), rounds_won = VALUES(rounds_won), rounds_lost = VALUES(rounds_lost), ' +
    'kills = VALUES(kills), deaths = VALUES(deaths), assists = VALUES(assists), selfkills = VALUES(selfkills), ' +
    'teamkills = VALUES(teamkills), points = VALUES(points), caps = VALUES(caps), shots = VALUES(shots), ' +
    'hits = VALUES(hits), headshots = VALUES(headshots), damage_dealt = VALUES(damage_dealt), ' +
    'damage_received = VALUES(damage_received), playtime_sec = VALUES(playtime_sec), ' +
    'first_played = VALUES(first_played), last_played = VALUES(last_played), updated_at = VALUES(updated_at)';

type
  TMirrorPlayer = record
    ProfileId, Points, RankPos, Kills, Deaths, Assists, Headshots, Shots, Hits, Wins, Loses, Caps: LongInt;
    Name: AnsiString;
    Json: AnsiString;
    SteamId: AnsiString;   { SharedProfiles/SharedRankings: the account's name on every server }
    Shared: AnsiString;    { its whole record (base64), '' = not in this pass (MirrorRecordDue) }
    Rating: Double;
    PlaySeconds: Int64;
    LastSeen: TDateTime;
  end;

  TMirrorMap = record
    MapId, Plays, Kills, Caps: LongInt;
    Name: AnsiString;
    Shared: AnsiString;    { SharedMaps: the whole record of the map (base64), '' = not in this pass }
    PlaySeconds: Int64;
    LastPlayed: TDateTime;
  end;

  { one player-on-map record ([Matrix]) }
  TMirrorPM = record
    AccountId, Matches, Wins, Losses, Draws, RoundsWon, RoundsLost, Kills, Deaths, Assists: LongInt;
    Selfkills, Teamkills, Points, Caps, Shots, Hits, Headshots: LongInt;
    MapName: AnsiString;
    DamageDealt, DamageReceived: Double;
    PlaySeconds: Int64;
    FirstPlayed, LastPlayed: TDateTime;
  end;

  TMirrorBatch = record
    Players: array of TMirrorPlayer;
    Maps: array of TMirrorMap;
    PlayerMaps: array of TMirrorPM;
    SendPM: Boolean;        { [Matrix] Enabled: the table zs_player_map_stats is written }
    Accounts, PeakOnline: LongInt;
    TotalMatches: Int64;
    Stamp: TDateTime;
    Full: Boolean;      { holds every account, so rows that are missing may be deleted }
    FullJson: Boolean;  { the rows carry the JSON column }
    SharePlayers: Boolean;  { the player rows carry the SteamID and the whole record }
    ShareMaps: Boolean;     { the map rows carry the whole record }
    ShareServer: Boolean;   { the server row carries its record and the sum of its accounts }
    ServerBlob, SumBlob: AnsiString;
  end;

  { what one key (a SteamID, a map name, a server) holds on each of the other servers }
  TRawEntry = record
    Sid: LongInt;
    Stamp: Int64;
    Data, Sum: AnsiString;
  end;

  TRawGroup = class
    Rows: array of TRawEntry;
    Seen: Boolean;
    function Find(Sid: LongInt): LongInt;
    function Put(Sid: LongInt; Stamp: Int64; const Data, Sum: AnsiString): Boolean;
  end;

  TMirrorThread = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FBatch: TMirrorBatch;
    FHasBatch: Boolean;
    FBusy: Boolean;
    FStop: Boolean;
    FDoneStamp: TDateTime;
    FFailures: LongInt;
    FMessages: TStringList;
    FLastError: AnsiString;
    FLastErrorMs: Int64;
    FHost, FDatabase, FUser, FPassword: AnsiString;
    FPort, FServerId, FCodepage: LongInt;
    FConn: TMyConnection;
    FWritePM: Boolean;     { [Matrix] Enabled: the table of the player-on-map records }
    { what is read from the other servers (zs_shared) }
    FReadPlayers, FReadMaps, FReadServer: Boolean;
    FStart: LongInt;
    FRawPlayers, FRawMaps, FRawServers: TStringList;   { key -> TRawGroup }
    FSincePlayers, FSinceMaps: Int64;                  { the newest shared_at read (database clock) }
    FListedMs: Int64;
    procedure Report(const Msg: AnsiString; IsError: Boolean);
    procedure Connect;
    procedure Disconnect;
    procedure WriteBatch(const B: TMirrorBatch);
    procedure SyncShared;
    procedure SyncRows(Raw: TStringList; const Table, KeyCol: AnsiString; var Since: Int64; Listing: Boolean;
      Changed: TStringList);
    procedure SyncServers;
    procedure RebuildPlayer(const Id: AnsiString);
    procedure RebuildMap(const Key: AnsiString);
  protected
    procedure Execute; override;
  public
    constructor Create(E: TZSEngine);
    destructor Destroy; override;
    function Busy: Boolean;
    function DoneStamp: TDateTime;
    function Failures: LongInt;
    procedure Submit(var B: TMirrorBatch);
    function TakeMessage(out Msg: AnsiString): Boolean;
    procedure StopAndWait;
  end;

var
  Owner: TZSEngine = nil;
  OwnerKey: AnsiString = '';        { the settings the thread was made with (MirrorKey) }
  Mirror: TMirrorThread = nil;
  LastRunMs: Int64;
  LastFullMs: Int64;
  { The whole seconds of the newest updated_at a pass wrote: every pass writes a later one. A whole
    pass deletes the rows older than its own, and DATETIME keeps whole seconds - the first pass of
    a copy started again (a reload of settings.ini) could fall into the second of the pass before
    it and keep a row that is gone. Only one copy runs at a time, the next after the last stopped. }
  LastStampSec: Int64 = 0;

{ ---------------- what the other servers wrote ---------------- }

function TRawGroup.Find(Sid: LongInt): LongInt;
var
  k: LongInt;
begin
  for k := 0 to High(Rows) do
    if Rows[k].Sid = Sid then
      Exit(k);
  Result := -1;
end;

{ True when the row is new or changed }
function TRawGroup.Put(Sid: LongInt; Stamp: Int64; const Data, Sum: AnsiString): Boolean;
var
  k: LongInt;
begin
  k := Find(Sid);
  if k < 0 then
  begin
    k := Length(Rows);
    SetLength(Rows, k + 1);
    Rows[k].Sid := Sid;
  end
  else if (Rows[k].Stamp = Stamp) and (Stamp <> 0) then
    Exit(False);
  Rows[k].Stamp := Stamp;
  Rows[k].Data := Data;
  Rows[k].Sum := Sum;
  Result := True;
end;

function NewRawList: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Result.CaseSensitive := True;
  Result.OwnsObjects := True;
end;

{ the other servers found in a list }
function ServersIn(Raw: TStringList): LongInt;
var
  Seen: TStringList;
  i, k: LongInt;
begin
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    for i := 0 to Raw.Count - 1 do
      for k := 0 to High(TRawGroup(Raw.Objects[i]).Rows) do
        Seen.Add(IntToStr(TRawGroup(Raw.Objects[i]).Rows[k].Sid));
    Result := Seen.Count;
  finally
    Seen.Free;
  end;
end;

{ ---------------- thread ---------------- }

constructor TMirrorThread.Create(E: TZSEngine);
begin
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
  FMessages := TStringList.Create;
  FHost := E.Cfg.MySQLHost;
  FPort := E.Cfg.MySQLPort;
  FDatabase := E.Cfg.MySQLDatabase;
  FUser := E.Cfg.MySQLUser;
  FPassword := E.Cfg.MySQLPassword;
  FServerId := E.Cfg.MySQLServerID;
  FCodepage := E.Cfg.SourceCodepage;
  FReadPlayers := E.Cfg.MySQLShareProfiles or E.Cfg.MySQLShareRankings;
  FReadMaps := E.Cfg.MySQLShareMaps;
  FReadServer := E.Cfg.MySQLShareWeapons or E.Cfg.MySQLShareServer;
  FWritePM := E.Cfg.MatrixEnabled;
  FStart := E.Cfg.StartingPoints;
  FRawPlayers := NewRawList;
  FRawMaps := NewRawList;
  FRawServers := NewRawList;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TMirrorThread.Destroy;
begin
  Disconnect;
  FMessages.Free;
  FRawPlayers.Free;
  FRawMaps.Free;
  FRawServers.Free;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
  WipeString(FPassword);
  inherited Destroy;
end;

procedure TMirrorThread.Report(const Msg: AnsiString; IsError: Boolean);
begin
  { the same connection error every minute would flood the console }
  if IsError and (Msg = FLastError) and (MonoMs - FLastErrorMs < ERROR_REPEAT_MS) then
    Exit;
  if IsError then
  begin
    FLastError := Msg;
    FLastErrorMs := MonoMs;
  end
  else
    FLastError := '';
  EnterCriticalSection(FLock);
  try
    FMessages.Add(Msg);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMirrorThread.Connect;
var
  C: TMyConnection;
begin
  { a connection the database ended while it waited (a restart, wait_timeout) is made again here,
    instead of failing the pass that finds it }
  if (FConn <> nil) and FConn.Usable then
    Exit;
  Disconnect;
  C := TMyConnection.Create;
  C.Host := FHost;
  C.Port := FPort;
  C.Database := FDatabase;
  C.User := FUser;
  C.Password := FPassword;
  { StopAndWait reaches the connection under the lock, to cut it }
  EnterCriticalSection(FLock);
  try
    FConn := C;
  finally
    LeaveCriticalSection(FLock);
  end;
  if FStop then
    FConn.Abort;
  FConn.Connect;
  MyPrepareTable(FConn, 'zs_players', PLAYER_COLS, PLAYER_KEYS);
  MyPrepareTable(FConn, 'zs_maps', MAP_COLS, MAP_KEYS);
  MyPrepareTable(FConn, 'zs_server', SERVER_COLS, SERVER_KEYS);
  if FWritePM then
    MyPrepareTable(FConn, 'zs_player_map_stats', PM_COLS, PM_KEYS);
  { the other servers read what changed since they last looked; the index is there after the
    first run (a second try fails, which is fine) }
  if FReadPlayers then
    try
      FConn.Exec('ALTER TABLE zs_players ADD INDEX idx_shared (shared_at)');
    except
    end;
  Report(Format('connected to %s:%d/%s (%s)', [FHost, FPort, FDatabase, FConn.ServerVersion]), False);
end;

procedure TMirrorThread.Disconnect;
var
  C: TMyConnection;
begin
  EnterCriticalSection(FLock);
  try
    C := FConn;
    FConn := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  if C <> nil then
  begin
    C.Close;
    WipeString(C.Password);
    C.Free;
  end;
end;

procedure TMirrorThread.WriteBatch(const B: TMirrorBatch);
var
  Rows, Whole: TMyBatch;
  k: LongInt;
  Stamp, Sid, Line, Cols, Tail: AnsiString;
  Secs: Int64;
begin
  { a second later than any pass before (LastStampSec); the half second keeps the formatting in it }
  Secs := Trunc(Now * 86400);
  if Secs <= LastStampSec then
    Secs := LastStampSec + 1;
  LastStampSec := Secs;
  Stamp := MyDate((Secs + 0.5) / 86400);
  Sid := MyInt(FServerId);
  Cols := SQL_PLAYER_COLS;
  Tail := SQL_PLAYER_TAIL;
  if B.FullJson then
  begin
    Cols := Cols + ', data';
    Tail := Tail + ', data = VALUES(data)';
  end;
  if B.SharePlayers then
  begin
    Cols := Cols + ', steam_id';
    Tail := Tail + ', steam_id = VALUES(steam_id)';
  end;
  FConn.Exec('START TRANSACTION');
  try
    { two shapes of row: the accounts whose whole record goes along (Shared switches) and the rest }
    Rows := TMyBatch.Create(FConn, 'INSERT INTO zs_players (' + Cols + ') VALUES', Tail, 1024 * 1024);
    Whole := TMyBatch.Create(FConn, 'INSERT INTO zs_players (' + Cols + ', shared_data, shared_at) VALUES',
      Tail + ', shared_data = VALUES(shared_data), shared_at = VALUES(shared_at)', 1024 * 1024);
    try
      for k := 0 to High(B.Players) do
      begin
        if FStop then
          Break;
        Line := '(' + Sid + ', ' + MyInt(B.Players[k].ProfileId) + ', ' +
          MyStrMax(CpToUtf8(B.Players[k].Name, FCodepage), 64) + ', ' + MyInt(B.Players[k].Points) + ', ' +
          MyInt(B.Players[k].RankPos) + ', ' + MyFloat(B.Players[k].Rating) + ', ' + MyInt(B.Players[k].Kills) + ', ' +
          MyInt(B.Players[k].Deaths) + ', ' + MyInt(B.Players[k].Assists) + ', ' + MyInt(B.Players[k].Headshots) + ', ' +
          MyInt(B.Players[k].Shots) + ', ' + MyInt(B.Players[k].Hits) + ', ' + MyInt(B.Players[k].Wins) + ', ' +
          MyInt(B.Players[k].Loses) + ', ' + MyInt(B.Players[k].Caps) + ', ' + MyInt(B.Players[k].PlaySeconds) + ', ' +
          MyDate(B.Players[k].LastSeen) + ', ' + Stamp;
        if B.FullJson then
          Line := Line + ', ' + MyStr(B.Players[k].Json);
        if B.SharePlayers then
        begin
          if B.Players[k].SteamId = '' then
            Line := Line + ', NULL'
          else
            Line := Line + ', ' + MyStr(B.Players[k].SteamId);
        end;
        if B.SharePlayers and (B.Players[k].Shared <> '') then
          Whole.Add(Line + ', ' + MyStr(B.Players[k].Shared) + ', NOW())')
        else
          Rows.Add(Line + ')');
      end;
      Rows.Flush;
      Whole.Flush;
    finally
      Rows.Free;
      Whole.Free;
    end;

    Rows := TMyBatch.Create(FConn, 'INSERT INTO zs_maps (' + SQL_MAP_COLS + ') VALUES', SQL_MAP_TAIL);
    Whole := TMyBatch.Create(FConn, 'INSERT INTO zs_maps (' + SQL_MAP_COLS + ', shared_data, shared_at) VALUES',
      SQL_MAP_TAIL + ', shared_data = VALUES(shared_data), shared_at = VALUES(shared_at)', 1024 * 1024);
    try
      for k := 0 to High(B.Maps) do
      begin
        if FStop then
          Break;
        Line := '(' + Sid + ', ' + MyInt(B.Maps[k].MapId) + ', ' + MyStrMax(CpToUtf8(B.Maps[k].Name, FCodepage), 64) +
          ', ' + MyInt(B.Maps[k].Plays) + ', ' + MyInt(B.Maps[k].Kills) + ', ' + MyInt(B.Maps[k].Caps) + ', ' +
          MyInt(B.Maps[k].PlaySeconds) + ', ' + MyDate(B.Maps[k].LastPlayed) + ', ' + Stamp;
        if B.ShareMaps and (B.Maps[k].Shared <> '') then
          Whole.Add(Line + ', ' + MyStr(B.Maps[k].Shared) + ', NOW())')
        else
          Rows.Add(Line + ')');
      end;
      Rows.Flush;
      Whole.Flush;
    finally
      Rows.Free;
      Whole.Free;
    end;

    { [Matrix]: the player-on-map records }
    if B.SendPM then
    begin
      Rows := TMyBatch.Create(FConn, 'INSERT INTO zs_player_map_stats (' + SQL_PM_COLS + ') VALUES', SQL_PM_TAIL,
        1024 * 1024);
      try
        for k := 0 to High(B.PlayerMaps) do
        begin
          if FStop then
            Break;
          Rows.Add('(' + Sid + ', ' + MyInt(B.PlayerMaps[k].AccountId) + ', ' +
            MyStrMax(CpToUtf8(B.PlayerMaps[k].MapName, FCodepage), 64) + ', ' + MyInt(B.PlayerMaps[k].Matches) + ', ' +
            MyInt(B.PlayerMaps[k].Wins) + ', ' + MyInt(B.PlayerMaps[k].Losses) + ', ' + MyInt(B.PlayerMaps[k].Draws) + ', ' +
            MyInt(B.PlayerMaps[k].RoundsWon) + ', ' + MyInt(B.PlayerMaps[k].RoundsLost) + ', ' +
            MyInt(B.PlayerMaps[k].Kills) + ', ' + MyInt(B.PlayerMaps[k].Deaths) + ', ' + MyInt(B.PlayerMaps[k].Assists) +
            ', ' + MyInt(B.PlayerMaps[k].Selfkills) + ', ' + MyInt(B.PlayerMaps[k].Teamkills) + ', ' +
            MyInt(B.PlayerMaps[k].Points) + ', ' + MyInt(B.PlayerMaps[k].Caps) + ', ' + MyInt(B.PlayerMaps[k].Shots) +
            ', ' + MyInt(B.PlayerMaps[k].Hits) + ', ' + MyInt(B.PlayerMaps[k].Headshots) + ', ' +
            MyFloat(B.PlayerMaps[k].DamageDealt) + ', ' + MyFloat(B.PlayerMaps[k].DamageReceived) + ', ' +
            MyInt(B.PlayerMaps[k].PlaySeconds) + ', ' + MyDate(B.PlayerMaps[k].FirstPlayed) + ', ' +
            MyDate(B.PlayerMaps[k].LastPlayed) + ', ' + Stamp + ')');
        end;
        Rows.Flush;
      finally
        Rows.Free;
      end;
    end;

    Line := ' (' + Sid + ', ' + MyInt(B.Accounts) + ', ' + MyInt(B.PeakOnline) + ', ' + MyInt(B.TotalMatches) + ', ' + Stamp;
    if B.ShareServer then
      FConn.Exec('INSERT INTO zs_server (' + SQL_SERVER_COLS + ', shared_data, shared_sum, shared_at) VALUES' + Line +
        ', ' + MyStr(B.ServerBlob) + ', ' + MyStr(B.SumBlob) + ', NOW()) ' + SQL_SERVER_TAIL +
        ', shared_data = VALUES(shared_data), shared_sum = VALUES(shared_sum), shared_at = VALUES(shared_at)')
    else
      FConn.Exec('INSERT INTO zs_server (' + SQL_SERVER_COLS + ') VALUES' + Line + ') ' + SQL_SERVER_TAIL);

    { this pass wrote every account and map of this server, so older rows are accounts that were
      deleted or merged in the meantime }
    if B.Full and not FStop then
    begin
      FConn.Exec('DELETE FROM zs_players WHERE server_id = ' + Sid + ' AND (updated_at < ' + Stamp +
        ' OR updated_at IS NULL)');
      FConn.Exec('DELETE FROM zs_maps WHERE server_id = ' + Sid + ' AND (updated_at < ' + Stamp +
        ' OR updated_at IS NULL)');
      { records pruned, reset or merged away here }
      if B.SendPM then
        FConn.Exec('DELETE FROM zs_player_map_stats WHERE server_id = ' + Sid + ' AND (updated_at < ' + Stamp +
          ' OR updated_at IS NULL)');
    end;
    FConn.Exec('COMMIT');
  except
    try
      if FConn.Connected then
        FConn.Exec('ROLLBACK');
    except
    end;
    raise;
  end;
end;

{ The rows of one table the other servers wrote, by key (an account's SharedIdentity - its SteamID
  or its computer - or a map name): the rows written since the newest one read before (with two
  minutes to spare, for passes that were still open), or every row the first time. Listing reads
  every key again - without the records - so rows the other servers deleted leave the pool as
  well. The keys whose rows changed go into Changed. }
procedure TMirrorThread.SyncRows(Raw: TStringList; const Table, KeyCol: AnsiString; var Since: Int64; Listing: Boolean;
  Changed: TStringList);
var
  C: TMyCursor;
  Where, Key: AnsiString;
  Sid, i, k: LongInt;
  Stamp, Newest: Int64;
  G: TRawGroup;
begin
  Where := ' FROM ' + Table + ' WHERE server_id <> ' + MyInt(FServerId) + ' AND ' + KeyCol + ' IS NOT NULL' +
    ' AND shared_data IS NOT NULL';
  Newest := Since;
  if Since > 0 then
    C := FConn.Open('SELECT ' + KeyCol + ', server_id, UNIX_TIMESTAMP(shared_at), shared_data' + Where +
      ' AND shared_at >= FROM_UNIXTIME(' + IntToStr(Since - 120) + ')')
  else
    C := FConn.Open('SELECT ' + KeyCol + ', server_id, UNIX_TIMESTAMP(shared_at), shared_data' + Where);
  try
    while C.Next do
    begin
      if FStop then
        Break;
      Key := Trim(C.Str(0));
      if KeyCol = 'name' then
        Key := LowerCase(Key);
      Sid := C.Int(1);
      Stamp := C.Int(2);
      if (Key = '') or (Sid = FServerId) then
        Continue;
      if Stamp > Newest then
        Newest := Stamp;
      i := Raw.IndexOf(Key);
      if i < 0 then
        i := Raw.AddObject(Key, TRawGroup.Create);
      if TRawGroup(Raw.Objects[i]).Put(Sid, Stamp, DecodeStringBase64(C.Str(3)), '') then
        Changed.Add(Key);
    end;
  finally
    C.Free;
  end;
  Since := Newest;
  if not Listing or FStop then
    Exit;
  for i := 0 to Raw.Count - 1 do
    TRawGroup(Raw.Objects[i]).Seen := False;
  { the keys and servers that are still there; the rows of the others are dropped }
  C := FConn.Open('SELECT ' + KeyCol + ', server_id' + Where);
  try
    while C.Next do
    begin
      Key := Trim(C.Str(0));
      if KeyCol = 'name' then
        Key := LowerCase(Key);
      i := Raw.IndexOf(Key);
      if i < 0 then
        Continue;
      G := TRawGroup(Raw.Objects[i]);
      k := G.Find(C.Int(1));
      if k >= 0 then
        G.Rows[k].Stamp := -Abs(G.Rows[k].Stamp) - 1;   { marked as seen }
    end;
  finally
    C.Free;
  end;
  for i := Raw.Count - 1 downto 0 do
  begin
    G := TRawGroup(Raw.Objects[i]);
    for k := High(G.Rows) downto 0 do
      if G.Rows[k].Stamp >= 0 then
      begin
        { not seen: the other server deleted it }
        G.Rows[k] := G.Rows[High(G.Rows)];
        SetLength(G.Rows, Length(G.Rows) - 1);
        Changed.Add(Raw[i]);
      end
      else
        G.Rows[k].Stamp := -G.Rows[k].Stamp - 1;
    if Length(G.Rows) = 0 then
      Raw.Delete(i);
  end;
end;

{ one account of the pool (SharedIdentity): every other server's record of it added up }
procedure TMirrorThread.RebuildPlayer(const Id: AnsiString);
var
  i, k, n: LongInt;
  Others, P: TPlayerProfile;
  Gain: Int64;
  Name: AnsiString;
  Latest: Double;
  G: TRawGroup;
begin
  i := FRawPlayers.IndexOf(Id);
  if i < 0 then
  begin
    PoolDropPlayer(Id);
    Exit;
  end;
  G := TRawGroup(FRawPlayers.Objects[i]);
  ClearProfile(Others);
  Gain := 0;
  n := 0;
  Name := '';
  Latest := -1;
  for k := 0 to High(G.Rows) do
  begin
    ClearProfile(P);
    if not DecodeProfile(G.Rows[k].Data, P) then
      Continue;
    AlignPeriods(Others, P);
    MergeProfileInto(Others, P, FStart);
    Inc(Gain, Int64(P.Points) - FStart);
    Inc(n);
    if P.LastPlayedTime > Latest then
    begin
      Latest := P.LastPlayedTime;
      Name := P.ActiveName;
    end;
  end;
  if n = 0 then
    PoolDropPlayer(Id)
  else
    PoolPutPlayer(Id, Name, Others, Gain, n);
end;

procedure TMirrorThread.RebuildMap(const Key: AnsiString);
var
  i, k, n: LongInt;
  Others, M: TMapProfile;
  G: TRawGroup;
begin
  i := FRawMaps.IndexOf(Key);
  if i < 0 then
  begin
    PoolDropMap(Key);
    Exit;
  end;
  G := TRawGroup(FRawMaps.Objects[i]);
  ClearMap(Others);
  n := 0;
  for k := 0 to High(G.Rows) do
  begin
    ClearMap(M);
    if not DecodeMap(G.Rows[k].Data, M) then
      Continue;
    MergeMapInto(Others, M);
    if Others.MapName = '' then
      Others.MapName := M.MapName;
    Inc(n);
  end;
  if n = 0 then
    PoolDropMap(Key)
  else
    PoolPutMap(Key, Others, n);
end;

{ the server rows are few and small: all of them every pass, the pool built again on a change }
procedure TMirrorThread.SyncServers;
var
  C: TMyCursor;
  Changed: Boolean;
  i, k, n: LongInt;
  Others, S: TServerRecords;
  Sums, P: TPlayerProfile;
  G: TRawGroup;
  Key: AnsiString;
begin
  Changed := False;
  for i := 0 to FRawServers.Count - 1 do
    TRawGroup(FRawServers.Objects[i]).Seen := False;
  C := FConn.Open('SELECT server_id, UNIX_TIMESTAMP(shared_at), shared_data, shared_sum FROM zs_server WHERE server_id <> ' +
    MyInt(FServerId) + ' AND shared_data IS NOT NULL');
  try
    while C.Next do
    begin
      Key := IntToStr(C.Int(0));
      i := FRawServers.IndexOf(Key);
      if i < 0 then
        i := FRawServers.AddObject(Key, TRawGroup.Create);
      G := TRawGroup(FRawServers.Objects[i]);
      G.Seen := True;
      if G.Put(C.Int(0), C.Int(1), DecodeStringBase64(C.Str(2)), DecodeStringBase64(C.Str(3))) then
        Changed := True;
    end;
  finally
    C.Free;
  end;
  for i := FRawServers.Count - 1 downto 0 do
    if not TRawGroup(FRawServers.Objects[i]).Seen then
    begin
      FRawServers.Delete(i);
      Changed := True;
    end;
  if Changed or (SharedServerCount(POOL_SERVER) <> FRawServers.Count) then
  begin
    ClearServer(Others);
    ClearProfile(Sums);
    n := 0;
    for i := 0 to FRawServers.Count - 1 do
    begin
      G := TRawGroup(FRawServers.Objects[i]);
      for k := 0 to High(G.Rows) do
      begin
        ClearServer(S);
        if not DecodeServer(G.Rows[k].Data, S) then
          Continue;
        MergeServerInto(Others, S);
        ClearProfile(P);
        if DecodeProfile(G.Rows[k].Sum, P) then
          SumProfileCounters(Sums, P);
        Inc(n);
      end;
    end;
    PoolPutServer(Others, Sums, n);
  end;
  PoolLoaded(POOL_SERVER, FRawServers.Count);
end;

procedure TMirrorThread.SyncShared;
var
  Changed: TStringList;
  Listing: Boolean;
  i: LongInt;
begin
  { every quarter of an hour the keys are read again, for the rows the other servers deleted }
  Listing := MonoMs - FListedMs >= 15 * 60 * 1000;
  if Listing then
    FListedMs := MonoMs;
  Changed := TStringList.Create;
  try
    Changed.Sorted := True;
    Changed.Duplicates := dupIgnore;
    Changed.CaseSensitive := True;
    if FReadPlayers and not FStop then
    begin
      SyncRows(FRawPlayers, 'zs_players', 'steam_id', FSincePlayers, Listing, Changed);
      for i := 0 to Changed.Count - 1 do
        RebuildPlayer(Changed[i]);
      PoolLoaded(POOL_PROFILES, ServersIn(FRawPlayers));
    end;
    Changed.Clear;
    if FReadMaps and not FStop then
    begin
      SyncRows(FRawMaps, 'zs_maps', 'name', FSinceMaps, Listing, Changed);
      for i := 0 to Changed.Count - 1 do
        RebuildMap(Changed[i]);
      PoolLoaded(POOL_MAPS, ServersIn(FRawMaps));
    end;
    if FReadServer and not FStop then
      SyncServers;
  finally
    Changed.Free;
  end;
end;

procedure TMirrorThread.Execute;
var
  B: TMirrorBatch;
  Have, Wrote: Boolean;
begin
  GuardWorkerThread;
  CrashThread(CT_MIRROR);
  while not FStop do
  begin
    RTLEventWaitFor(FWake, 1000);
    EnterCriticalSection(FLock);
    try
      Have := FHasBatch;
      if Have then
      begin
        B := FBatch;
        FBatch.Players := nil;
        FBatch.Maps := nil;
        FBatch.PlayerMaps := nil;
        FHasBatch := False;
      end;
    finally
      LeaveCriticalSection(FLock);
    end;
    if not Have or FStop then
      Continue;
    Wrote := False;
    try
      Connect;
      WriteBatch(B);
      Wrote := True;
      EnterCriticalSection(FLock);
      FDoneStamp := B.Stamp;
      FFailures := 0;
      LeaveCriticalSection(FLock);
    except
      on Ex: Exception do
      begin
        Report('mirror failed: ' + Ex.Message, True);
        Disconnect;
        EnterCriticalSection(FLock);
        Inc(FFailures);
        LeaveCriticalSection(FLock);
      end;
    end;
    { then what the other servers wrote, for the Shared switches of this one; the copy went in, so
      a failure here is not a failed pass (that would lengthen the pause of the copy) }
    if Wrote and (FReadPlayers or FReadMaps or FReadServer) and not FStop then
      try
        SyncShared;
      except
        on Ex: Exception do
        begin
          Report('reading what the other servers wrote failed: ' + Ex.Message, True);
          Disconnect;
        end;
      end;
    B.Players := nil;
    B.Maps := nil;
    B.PlayerMaps := nil;
    EnterCriticalSection(FLock);
    FBusy := False;
    LeaveCriticalSection(FLock);
  end;
end;

function TMirrorThread.Busy: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FBusy or FHasBatch;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ failed passes since the last one that reached the database }
function TMirrorThread.Failures: LongInt;
begin
  EnterCriticalSection(FLock);
  try
    Result := FFailures;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ collection time of the last batch that reached the database, 0 before the first success }
function TMirrorThread.DoneStamp: TDateTime;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDoneStamp;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMirrorThread.Submit(var B: TMirrorBatch);
begin
  EnterCriticalSection(FLock);
  try
    FBatch := B;
    FHasBatch := True;
    FBusy := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
end;

function TMirrorThread.TakeMessage(out Msg: AnsiString): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FMessages.Count > 0;
    if Result then
    begin
      Msg := FMessages[0];
      FMessages.Delete(0);
    end
    else
      Msg := '';
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ the server stops: a pass that waits for the database is cut at once instead of waiting out
  the time limit of a database that does not answer }
procedure TMirrorThread.StopAndWait;
begin
  FStop := True;
  EnterCriticalSection(FLock);
  try
    if FConn <> nil then
      FConn.Abort;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
  WaitFor;
end;

{ ---------------- engine side ---------------- }

function MirrorRecordDue(Full, Active: Boolean; LastPlayed, Since: TDateTime): Boolean;
begin
  Result := Full or (Since <= 0) or Active or (LastPlayed >= Since - 5 / 1440);
end;

{ what the mirror thread takes from the settings when it is made (the password only as a
  fingerprint) }
function MirrorKey(E: TZSEngine): AnsiString;
begin
  Result := Format('%s|%d|%s|%s|%s|%d|%d|%d|%d%d%d%d', [E.Cfg.MySQLHost, E.Cfg.MySQLPort, E.Cfg.MySQLDatabase,
    E.Cfg.MySQLUser, MD5Print(MD5String(E.Cfg.MySQLPassword)), E.Cfg.MySQLServerID, E.Cfg.SourceCodepage,
    E.Cfg.StartingPoints, Ord(E.Cfg.MySQLShareProfiles or E.Cfg.MySQLShareRankings), Ord(E.Cfg.MySQLShareMaps),
    Ord(E.Cfg.MySQLShareWeapons or E.Cfg.MySQLShareServer), Ord(E.Cfg.MatrixEnabled)]);
end;

procedure MirrorTick(E: TZSEngine; NowMs: Int64);
var
  B: TMirrorBatch;
  k, n, S: LongInt;
  P: PPlayerProfile;
  Since: TDateTime;
  Full: Boolean;
  Msg: AnsiString;
  Wait: Int64;
  Online: array of Boolean;
  SharePlayers: Boolean;
  Sum: TPlayerProfile;
  PR: PPlayerMapStats;
begin
  { [MySQL] switched off or changed by a reload of settings.ini: the thread still works with the
    old settings, so it stops (a pass that waits for the database is cut) and the copy starts
    again with the new ones }
  if (Mirror <> nil) and (Owner = E) and (not MirrorOn(E) or (MirrorKey(E) <> OwnerKey)) then
  begin
    while Mirror.TakeMessage(Msg) do
      E.WriteServer('[ZitroStats] MySQL: ' + Msg);
    MirrorShutdown(E);
    PoolReset;
  end;
  if not MirrorOn(E) or not E.IsReady or E.IsReadOnly then
    Exit;
  if Owner <> E then
  begin
    Owner := E;
    OwnerKey := MirrorKey(E);
    Mirror := TMirrorThread.Create(E);
    LastRunMs := NowMs - Int64(E.Cfg.MySQLMirrorSeconds) * 1000;
    LastFullMs := 0;
    PoolReset;
  end;
  while Mirror.TakeMessage(Msg) do
    E.WriteServer('[ZitroStats] MySQL: ' + Msg);
  { while the database cannot be reached the pause doubles after every failed pass, up to 15
    minutes: every pass before the first success sends every account again }
  Wait := Int64(Max(5, E.Cfg.MySQLMirrorSeconds)) * 1000;
  if Mirror.Failures > 0 then
    Wait := Max(Wait, Min(Int64(15 * 60 * 1000), Wait shl Min(Mirror.Failures, 8)));
  if (NowMs - LastRunMs < Wait) or Mirror.Busy then
    Exit;
  LastRunMs := NowMs;

  { accounts played since the last successful run (a few minutes of overlap); every account until a
    run succeeds and then once an hour, so points changed by the daily balance reach the copy too }
  Since := Mirror.DoneStamp;
  Full := (Since <= 0) or (NowMs - LastFullMs >= FULL_MIRROR_MS);
  if Full then
    LastFullMs := NowMs;
  B.Stamp := E.DB.NowValue;
  { the players on the server change all the time, but their last-played time is only written
    when they join and leave, so they are always sent }
  Online := nil;
  SetLength(Online, E.DB.ProfileCount);
  for S := 1 to MAX_PLAYERS do
  begin
    k := E.Identity.ProfileIndex(S);
    if (k >= 0) and (k < Length(Online)) then
      Online[k] := True;
  end;
  SetLength(B.Players, E.DB.ProfileCount);
  SharePlayers := E.Cfg.MySQLShareProfiles or E.Cfg.MySQLShareRankings;
  n := 0;
  for k := 0 to E.DB.ProfileCount - 1 do
  begin
    if not E.DB.Valid(k) then
      Continue;
    P := E.DB.Profiles[k];
    if not Full and not Online[k] and (P^.LastPlayedTime < Since - 5 / 1440) then
      Continue;
    B.Players[n].ProfileId := P^.ID;
    B.Players[n].Name := P^.ActiveName;
    B.Players[n].Points := P^.Points;
    B.Players[n].RankPos := E.PlayerRank(k);
    B.Players[n].Rating := PerformanceRating(P^, E.Match.GameStyle, E.Match.Survival, E.Match.FriendlyFire, E.Cfg.RatingMode);
    B.Players[n].Kills := P^.Kills;
    B.Players[n].Deaths := P^.Deaths;
    B.Players[n].Assists := P^.Assist;
    B.Players[n].Headshots := P^.ShotsHitsHead;
    B.Players[n].Shots := Max(P^.Shots, P^.ShotsHits);
    B.Players[n].Hits := P^.ShotsHits;
    B.Players[n].Wins := P^.Wins;
    B.Players[n].Loses := P^.Loses;
    B.Players[n].Caps := P^.FlagsScore;
    B.Players[n].PlaySeconds := P^.TimePlayed;
    B.Players[n].LastSeen := P^.LastPlayedTime;
    if E.Cfg.MySQLFullJson then
      B.Players[n].Json := PlayerJson(E, k);
    { the whole record of an account (by SteamID, or by computer without Steam), for the other
      servers of this database (SharedProfiles, SharedRankings): MirrorRecordDue }
    if SharePlayers then
    begin
      B.Players[n].SteamId := SharedIdentityOf(E.DB, k);
      if (B.Players[n].SteamId <> '') and MirrorRecordDue(Full, Online[k], P^.LastPlayedTime, Since) then
        B.Players[n].Shared := EncodeStringBase64(EncodeProfile(P^));
    end;
    Inc(n);
  end;
  SetLength(B.Players, n);
  SetLength(B.Maps, E.DB.MapCount);
  for k := 0 to E.DB.MapCount - 1 do
  begin
    B.Maps[k].MapId := E.DB.Maps[k].ID;
    B.Maps[k].Name := E.DB.Maps[k].MapName;
    B.Maps[k].Plays := E.DB.Maps[k].ActiveMapPlays;
    B.Maps[k].Kills := E.DB.Maps[k].Kills;
    B.Maps[k].Caps := E.DB.Maps[k].FlagsScore;
    B.Maps[k].PlaySeconds := E.DB.Maps[k].ActiveTimePlays;
    B.Maps[k].LastPlayed := E.DB.Maps[k].LastPlayedTime;
    { SharedMaps: the whole map (MirrorRecordDue; the running map always) }
    if E.Cfg.MySQLShareMaps and MirrorRecordDue(Full, k = E.Match.MapIndex, E.DB.Maps[k].LastPlayedTime, Since) then
      B.Maps[k].Shared := EncodeStringBase64(EncodeMap(E.DB.Maps[k]));
  end;
  { [Matrix]: the player-on-map records played since the last pass, every one in a whole pass }
  B.SendPM := E.Cfg.MatrixEnabled;
  B.PlayerMaps := nil;
  if B.SendPM then
  begin
    SetLength(B.PlayerMaps, E.DB.PM.Count);
    n := 0;
    for k := 0 to E.DB.PM.Places - 1 do
    begin
      PR := E.DB.PM.Items[k];
      if (PR = nil) or (n >= Length(B.PlayerMaps)) or (not Full and (PR^.LastPlayed < Since - 5 / 1440)) then
        Continue;
      B.PlayerMaps[n].AccountId := PR^.AccountId;
      B.PlayerMaps[n].MapName := PR^.MapName;
      B.PlayerMaps[n].Matches := PR^.Matches;
      B.PlayerMaps[n].Wins := PR^.Wins;
      B.PlayerMaps[n].Losses := PR^.Losses;
      B.PlayerMaps[n].Draws := PR^.Draws;
      B.PlayerMaps[n].RoundsWon := PR^.RoundsWon;
      B.PlayerMaps[n].RoundsLost := PR^.RoundsLost;
      B.PlayerMaps[n].Kills := PR^.Kills;
      B.PlayerMaps[n].Deaths := PR^.Deaths;
      B.PlayerMaps[n].Assists := PR^.Assists;
      B.PlayerMaps[n].Selfkills := PR^.Selfkills;
      B.PlayerMaps[n].Teamkills := PR^.Teamkills;
      B.PlayerMaps[n].Points := PR^.Points;
      B.PlayerMaps[n].Caps := PR^.Caps;
      B.PlayerMaps[n].Shots := PR^.Shots;
      B.PlayerMaps[n].Hits := PR^.Hits;
      B.PlayerMaps[n].Headshots := PR^.HitsHead;
      B.PlayerMaps[n].DamageDealt := PR^.DamageDealt;
      B.PlayerMaps[n].DamageReceived := PR^.DamageReceived;
      B.PlayerMaps[n].PlaySeconds := PR^.TimePlayed;
      B.PlayerMaps[n].FirstPlayed := PR^.FirstPlayed;
      B.PlayerMaps[n].LastPlayed := PR^.LastPlayed;
      Inc(n);
    end;
    SetLength(B.PlayerMaps, n);
  end;
  { SharedWeapons, SharedServer: the server record and every account added up }
  if E.Cfg.MySQLShareWeapons or E.Cfg.MySQLShareServer then
  begin
    B.ServerBlob := EncodeStringBase64(EncodeServer(E.DB.Server));
    ClearProfile(Sum);
    for k := 0 to E.DB.ProfileCount - 1 do
      if E.DB.Valid(k) then
        SumProfileCounters(Sum, E.DB.Profiles[k]^);
    B.SumBlob := EncodeStringBase64(EncodeProfile(Sum));
  end;
  B.Full := Full;
  B.FullJson := E.Cfg.MySQLFullJson;
  B.SharePlayers := SharePlayers;
  B.ShareMaps := E.Cfg.MySQLShareMaps;
  B.ShareServer := E.Cfg.MySQLShareWeapons or E.Cfg.MySQLShareServer;
  B.Accounts := E.DB.LiveProfiles;
  B.PeakOnline := E.DB.Server.PeakOnlineCount;
  B.TotalMatches := E.DB.Server.TotalMatches;
  Mirror.Submit(B);
end;

procedure MirrorShutdown(E: TZSEngine);
begin
  if (Mirror = nil) or (Owner <> E) then
    Exit;
  Mirror.StopAndWait;
  FreeAndNil(Mirror);
  Owner := nil;
end;

end.
