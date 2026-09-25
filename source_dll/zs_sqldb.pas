unit zs_sqldb;

{ [MySQL] Engine = mysql: one statistics database for every game server.

  The tables hold the accounts, maps, server record and seasons of all servers together. Every
  server keeps the whole of it in memory as before - commands, rankings and the HUD read memory,
  so nothing waits for the database - and exchanges its changes with the tables every
  SyncSeconds, on a thread of its own:
  - what changed here goes in as a three-way merge (zs_fields, Merge3*): the thread locks the
    rows, reads what the other servers wrote, puts this server's changes since the last exchange
    on top and writes the result. Counters of several servers add up and nothing is overwritten,
    however many servers write at the same time. The writers take turns on one row of zs_db_meta,
    which also numbers the changes (seq);
  - what the other servers wrote since the last exchange (a higher seq) comes back and is merged
    the same way into memory, on the engine thread.
  The game thread never waits: the engine thread hands a batch over and takes the answer on a
  later tick. The files stay as a cache: a server that cannot reach the database starts from them
  and sends what it collected once the database answers again.

  The first time a server uses the database it brings its own data along: an account of the same
  SteamID - or, without Steam, of the same computer (HWID), as on one server - is added to the one
  that is there, every other account gets a number of the database. Two accounts with a password
  each stay apart: two owners, two passwords.

  What changed here and has not reached the database yet is kept beside the files
  (zitrostats.shared) when the server stops, and every half a minute while the database does not
  answer, with the state the database had before it. A server that stops without the database
  sends it at its next start, before the database is read.

  A server that starts without the database exchanges by the numbers of its files only once it
  finds its join mark in the database: one that never joined it (or whose join went in while the
  rest of its start failed) writes nothing until its next start, which joins it, instead of
  writing its accounts over the accounts that have those numbers in the database. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_fields, zs_db, zs_store, zs_engine;

{ LoadData, on the engine thread before the engine is ready. True when the shared database is
  in memory now; False when it could not be reached (the files are used, and the exchange starts
  as soon as it answers). }
function SqlStart(E: TZSEngine): Boolean;
procedure SqlTick(E: TZSEngine; NowMs: Int64);
{ at shutdown: what is left goes in, waiting a few seconds at most }
procedure SqlShutdown(E: TZSEngine);
{ a job of the whole database (the daily balance, the season): True for the one server that got
  it; asked on the next exchange, so the first calls say False }
function SqlJob(E: TZSEngine; const Name: AnsiString; Key: LongInt): Boolean;
function SqlStatusText(E: TZSEngine): AnsiString;

implementation

uses
  DateUtils, md5, mysqlwire, zs_crash, zs_service;

const
  SK_ACCOUNT = 1;
  SK_MAP = 2;
  SK_SERVER = 3;
  SK_SEASON = 4;
  SK_DELETE = 5;
  ID_BLOCK = 200;
  ID_LOW = 50;
  PUSH_CHUNK = 200;

  ACC_COLS: array[0..15] of AnsiString = (
    'id INT NOT NULL', 'steam VARCHAR(40) NULL', 'hwid_key VARCHAR(32) NULL', 'name VARCHAR(64) NOT NULL DEFAULT ''''',
    'points INT NOT NULL DEFAULT 0', 'kills INT NOT NULL DEFAULT 0', 'deaths INT NOT NULL DEFAULT 0',
    'playtime_sec BIGINT NOT NULL DEFAULT 0', 'last_seen DATETIME NULL', 'data MEDIUMBLOB NULL',
    'version BIGINT NOT NULL DEFAULT 0', 'seq BIGINT NOT NULL DEFAULT 0', 'deleted TINYINT NOT NULL DEFAULT 0',
    'merged_into INT NOT NULL DEFAULT 0', 'updated_by INT NOT NULL DEFAULT 0', 'updated_at DATETIME NULL');
  ACC_KEYS = 'PRIMARY KEY (id), KEY idx_seq (seq), KEY idx_steam (steam), KEY idx_hwid (hwid_key), KEY idx_name (name), ' +
    'KEY idx_points (points)';
  MAP_COLS: array[0..9] of AnsiString = (
    'name VARCHAR(64) NOT NULL', 'id INT NOT NULL DEFAULT 0', 'plays INT NOT NULL DEFAULT 0',
    'kills INT NOT NULL DEFAULT 0', 'playtime_sec BIGINT NOT NULL DEFAULT 0', 'data MEDIUMBLOB NULL',
    'version BIGINT NOT NULL DEFAULT 0', 'seq BIGINT NOT NULL DEFAULT 0', 'updated_by INT NOT NULL DEFAULT 0',
    'updated_at DATETIME NULL');
  MAP_KEYS = 'PRIMARY KEY (name), KEY idx_seq (seq)';
  SRV_COLS: array[0..5] of AnsiString = (
    'id INT NOT NULL', 'data MEDIUMBLOB NULL', 'version BIGINT NOT NULL DEFAULT 0', 'seq BIGINT NOT NULL DEFAULT 0',
    'updated_by INT NOT NULL DEFAULT 0', 'updated_at DATETIME NULL');
  SRV_KEYS = 'PRIMARY KEY (id)';
  SEASON_COLS: array[0..4] of AnsiString = (
    'id INT NOT NULL', 'data MEDIUMBLOB NULL', 'seq BIGINT NOT NULL DEFAULT 0', 'updated_by INT NOT NULL DEFAULT 0',
    'updated_at DATETIME NULL');
  SEASON_KEYS = 'PRIMARY KEY (id), KEY idx_seq (seq)';
  META_COLS: array[0..1] of AnsiString = ('name VARCHAR(40) NOT NULL', 'value BIGINT NOT NULL DEFAULT 0');
  META_KEYS = 'PRIMARY KEY (name)';
  JOB_COLS: array[0..3] of AnsiString = ('job VARCHAR(32) NOT NULL', 'day INT NOT NULL DEFAULT 0',
    'server_id INT NOT NULL DEFAULT 0', 'taken_at DATETIME NULL');
  JOB_KEYS = 'PRIMARY KEY (job)';

type
  TSyncItem = record
    Kind: Byte;
    Id: LongInt;            { account or season number }
    Key: AnsiString;        { map name }
    Snap, Base: AnsiString; { the record now, and as the database had it (a new one: as it began) }
    IsNew: Boolean;         { made here, the database does not know it yet }
    Steam, Name: AnsiString;
    Hwid: AnsiString;       { the key of an account without Steam: its computer (HwidKey) }
    Points, Kills, Deaths: LongInt;
    PlaySeconds: Int64;
    LastSeen: Double;
    MergedInto: LongInt;
  end;
  TSyncItems = array of TSyncItem;

  TSyncOut = record
    Kind: Byte;
    Id, NewId: LongInt;     { NewId: the number in the database when it is not Id }
    Key: AnsiString;
    Data: AnsiString;
    Version: Int64;
    Deleted: Boolean;
    MergedInto: LongInt;
    Pushed: Boolean;        { the answer to an item of this server }
  end;
  TSyncOuts = array of TSyncOut;

  TSyncJob = record
    Job: AnsiString;
    Day: LongInt;
    Granted: LongInt;       { 1 this server, -1 another one }
  end;
  TSyncJobs = array of TSyncJob;

  TSyncResult = record
    Ok: Boolean;
    Error: AnsiString;
    Rows: TSyncOuts;
    Seq: Int64;
    IdFrom, IdTo: LongInt;
    Jobs: TSyncJobs;
    Joined, NotJoined: Boolean;  { the answer to CheckJoin: this server's join mark is there, or not }
    SeqBack: Boolean;            { the seq of the database is below the one this server read last }
    CommitUnsure: Boolean;       { the push failed after its COMMIT was sent: it may be in }
  end;

  TSqlThread = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FHost, FDatabase, FUser, FPassword: AnsiString;
    FPort, FServerId, FCodepage: LongInt;
    FConn: TMyConnection;
    FStop: Boolean;
    FHave, FDone: Boolean;
    FItems: TSyncItems;
    FJobs: TSyncJobs;
    FPullSeq: Int64;
    FNeedIds: Boolean;
    FCheckJoin: Boolean;
    FCommitSeq: Int64;      { the seq of a push whose COMMIT was sent and not answered yet }
    FRes: TSyncResult;
    FOutCount: LongInt;
    procedure Connect;
    procedure Disconnect;
    procedure Add(const O: TSyncOut);
    procedure Push;
    procedure Pull;
    procedure TakeIds;
    procedure ClaimJobs;
    function Landed(Seq: Int64): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(E: TZSEngine);
    destructor Destroy; override;
    procedure Submit(const Items: TSyncItems; const Jobs: TSyncJobs; PullSeq: Int64; NeedIds, CheckJoin: Boolean);
    function TakeResult(out R: TSyncResult): Boolean;
    procedure StopAndWait;
  end;

  TSnapObj = class
    Data: AnsiString;
    Base: AnsiString;
    Id: LongInt;
    MergedInto: LongInt;
  end;

  TSqlState = class
    Thread: TSqlThread;
    Engine: TZSEngine;
    Busy: Boolean;
    InFlight: TStringList;     { 'A<id>', 'M<name>', 'S', 'N<season>', 'D<id>' -> TSnapObj }
    PullSeq: Int64;
    NeedFull: Boolean;         { read the whole database again on the next exchange }
    Online: Boolean;
    EverOnline: Boolean;
    Fresh: AnsiString;         { a new account as it begins: the base of an account the database does not know }
    LastCycleMs: Int64;
    LastOkMs: Int64;
    IdNext, IdEnd: LongInt;
    Jobs: TStringList;         { 'job|key' -> 0 asked, 1 granted, -1 refused }
    LastError: AnsiString;
    Cycles, Pushed, Pulled: Int64;
    PendingOnDisk: Boolean;    { zitrostats.shared holds changes }
    PendingAt: Int64;
    Joined: Boolean;           { the numbers in memory are the database's: it was read at the start, or
                                 the join mark of this server was found }
    Blocked: AnsiString;       { why nothing is exchanged until the next start, '' while it runs }
    Fails: LongInt;            { exchanges in a row that did not reach the database }
    SeqWarned, CfgWarned: Boolean;
    CfgKey: AnsiString;        { the [MySQL] settings the exchange runs with (SqlKey) }
    constructor Create(E: TZSEngine);
    destructor Destroy; override;
    function NextProfileId: LongInt;
  end;

{ ---------------- little helpers ---------------- }

function State(E: TZSEngine): TSqlState;
begin
  if (E <> nil) and (E.SqlState is TSqlState) then
    Result := TSqlState(E.SqlState)
  else
    Result := nil;
end;

{ a binary literal: the records go in as they are }
function MyBin(const S: AnsiString): AnsiString;
const
  HexDigits: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  i: LongInt;
begin
  SetLength(Result, Length(S) * 2 + 3);
  Result[1] := 'X';
  Result[2] := '''';
  for i := 1 to Length(S) do
  begin
    Result[i * 2 + 1] := HexDigits[Ord(S[i]) shr 4];
    Result[i * 2 + 2] := HexDigits[Ord(S[i]) and 15];
  end;
  Result[Length(Result)] := '''';
end;

function IdList(const Ids: array of LongInt; First, Last: LongInt): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := First to Last do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + IntToStr(Ids[k]);
  end;
end;

function DecodeP(const Data: AnsiString; var P: TPlayerProfile): Boolean;
begin
  ClearProfile(P);
  Result := (Data = '') or DecodeProfile(Data, P);
end;

function DecodeM(const Data: AnsiString; var M: TMapProfile): Boolean;
begin
  ClearMap(M);
  Result := (Data = '') or DecodeMap(Data, M);
end;

function DecodeS(const Data: AnsiString; var S: TServerRecords): Boolean;
begin
  ClearServer(S);
  Result := (Data = '') or DecodeServer(Data, S);
end;

{ An account without Steam is the account of a computer, as on one server: the key of its HWID,
  hashed, so a website reading the table sees no HWID. '' for a Steam account. }
function HwidKey(const P: TPlayerProfile): AnsiString;
begin
  Result := '';
  if IsRealSteam(P.ActiveSteam) or (Trim(P.ActiveHWID) = '') then
    Exit;
  Result := MD5Print(MD5String(UpperCase(Trim(P.ActiveHWID))));
end;

function KeyValue(const Key: AnsiString): AnsiString;
begin
  if Key = '' then
    Result := 'NULL'
  else
    Result := MyStr(Key);
end;

{ a new account as it begins: its points and ratings are not something it won }
function FreshProfile(E: TZSEngine): AnsiString;
var
  P: TPlayerProfile;
begin
  ClearProfile(P);
  P.Points := E.Cfg.StartingPoints;
  E.DB.InitRatings(P);
  Result := EncodeProfile(P);
end;

procedure PrepareTables(C: TMyConnection); forward;
function MetaValue(C: TMyConnection; const Name: AnsiString; Lock: Boolean): Int64; forward;

{ Count account numbers of the database inside the caller's transaction, the first one returned:
  past the counter, and past every number a row has - a counter set back by hand must not hand
  out a number another account has, which the write would take over (ON DUPLICATE KEY UPDATE) }
function TakeAccountIds(C: TMyConnection; Count: LongInt): LongInt;
var
  R: TMyResult;
  First, Top: Int64;
begin
  First := MetaValue(C, 'next_account', True);
  if First < 0 then
    raise EMyError.CreateCode(0, 'the row next_account of zs_db_meta is missing');
  R := C.Query('SELECT MAX(id) FROM zs_db_accounts');
  try
    Top := R.Int(0, 0);
  finally
    R.Free;
  end;
  First := Max(Max(First, Top + 1), 1);
  if First + Count > High(LongInt) then
    raise EMyError.CreateCode(0, 'the account numbers of the shared database are used up');
  C.Exec('UPDATE zs_db_meta SET value = ' + MyInt(First + Count) + ' WHERE name = ''next_account''');
  Result := LongInt(First);
end;

{ the steam column of an account: NULL without Steam, and for a value longer than the column,
  which is no SteamID and would make the whole exchange fail (strict mode) }
function SteamValue(const Steam: AnsiString): AnsiString;
begin
  if IsRealSteam(Steam) and (Length(Steam) <= 40) then
    Result := MyStr(Steam)
  else
    Result := 'NULL';
end;

{ the settings the exchange takes at the start (the password only as a fingerprint): a reload of
  settings.ini cannot move it to others }
function SqlKey(E: TZSEngine): AnsiString;
begin
  Result := Format('%d|%s|%d|%s|%s|%s|%d|%d', [E.Cfg.MySQLEngine, E.Cfg.MySQLHost, E.Cfg.MySQLPort, E.Cfg.MySQLDatabase,
    E.Cfg.MySQLUser, MD5Print(MD5String(E.Cfg.MySQLPassword)), E.Cfg.MySQLServerID, E.Cfg.SourceCodepage]);
end;

{ ---------------- the thread ---------------- }

constructor TSqlThread.Create(E: TZSEngine);
begin
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
  FHost := E.Cfg.MySQLHost;
  FPort := E.Cfg.MySQLPort;
  FDatabase := E.Cfg.MySQLDatabase;
  FUser := E.Cfg.MySQLUser;
  FPassword := E.Cfg.MySQLPassword;
  FServerId := E.Cfg.MySQLServerID;
  FCodepage := E.Cfg.SourceCodepage;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TSqlThread.Destroy;
begin
  Disconnect;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
  WipeString(FPassword);
  inherited Destroy;
end;

procedure TSqlThread.Connect;
var
  C: TMyConnection;
begin
  { a connection the database ended while it waited (a restart, wait_timeout) is made again here,
    instead of failing the exchange that finds it }
  if (FConn <> nil) and FConn.Usable then
    Exit;
  Disconnect;
  C := TMyConnection.Create;
  C.Host := FHost;
  C.Port := FPort;
  C.Database := FDatabase;
  C.User := FUser;
  C.Password := FPassword;
  EnterCriticalSection(FLock);
  try
    FConn := C;
  finally
    LeaveCriticalSection(FLock);
  end;
  if FStop then
    FConn.Abort;
  FConn.Connect;
end;

procedure TSqlThread.Disconnect;
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
    try
      C.Close;
    except
    end;
    WipeString(C.Password);
    C.Free;
  end;
end;

procedure TSqlThread.Add(const O: TSyncOut);
begin
  if FOutCount >= Length(FRes.Rows) then
    SetLength(FRes.Rows, FOutCount * 2 + 64);
  FRes.Rows[FOutCount] := O;
  Inc(FOutCount);
end;

{ The changes of this server go in: one transaction, after the turn on the seq row. Every row
  is read with a lock, merged with what this server changed since it last saw it, and written
  back with the next seq. }
procedure TSqlThread.Push;
var
  Seq: Int64;
  R: TMyResult;
  i, k, Target, Hops: LongInt;
  Cur, Base, Remote: TPlayerProfile;
  MC, MB, MR: TMapProfile;
  SC, SB, SR: TServerRecords;
  O: TSyncOut;
  Version: Int64;
  Data, Stamp, Sid, SeqText, Line: AnsiString;
  RowDeleted: Boolean;
  RowMerged: LongInt;
  Rows: TMyBatch;
  Written: TStringList;

  { the row of one account, locked: its version, data, and where it went when it is gone }
  function LockAccount(Id: LongInt; out V: Int64; out D: AnsiString; out Del: Boolean; out Merged: LongInt): Boolean;
  var
    Q: TMyResult;
  begin
    Q := FConn.Query('SELECT version, data, deleted, merged_into FROM zs_db_accounts WHERE id = ' + MyInt(Id) + ' FOR UPDATE');
    try
      Result := Q.RowCount > 0;
      if Result then
      begin
        V := Q.Int(0, 0);
        D := Q.Str(0, 1);
        Del := Q.Int(0, 2) <> 0;
        Merged := Q.Int(0, 3);
      end
      else
      begin
        V := 0;
        D := '';
        Del := False;
        Merged := 0;
      end;
    finally
      Q.Free;
    end;
  end;

  { a new account: the one the database already has for the same SteamID or, without Steam, the
    same computer; 0 = none }
  function SameAccount(const Steam, Hwid: AnsiString): LongInt;
  var
    Q: TMyResult;
  begin
    Result := 0;
    if Steam <> '' then
      Q := FConn.Query('SELECT id FROM zs_db_accounts WHERE steam = ' + MyStr(Steam) +
        ' AND deleted = 0 ORDER BY id LIMIT 1 FOR UPDATE')
    else if Hwid <> '' then
      Q := FConn.Query('SELECT id FROM zs_db_accounts WHERE steam IS NULL AND hwid_key = ' + MyStr(Hwid) +
        ' AND deleted = 0 ORDER BY id LIMIT 1 FOR UPDATE')
    else
      Exit;
    try
      if Q.RowCount > 0 then
        Result := Q.Int(0, 0);
    finally
      Q.Free;
    end;
  end;

  function NewAccountId: LongInt;
  begin
    Result := TakeAccountIds(FConn, 1);
  end;

begin
  if Length(FItems) = 0 then
    Exit;
  Stamp := MyDate(Now);
  Sid := MyInt(FServerId);
  FConn.Exec('START TRANSACTION');
  try
    { without the row the writers would not take turns, and the other servers would not read
      what goes in }
    Seq := MetaValue(FConn, 'seq', True);
    if Seq < 0 then
      raise EMyError.CreateCode(0, 'the row seq of zs_db_meta is missing');
    Inc(Seq);
    SeqText := MyInt(Seq);

    { accounts }
    Rows := TMyBatch.Create(FConn, 'INSERT INTO zs_db_accounts (id, steam, hwid_key, name, points, kills, deaths, ' +
      'playtime_sec, last_seen, data, version, seq, deleted, merged_into, updated_by, updated_at) VALUES',
      'ON DUPLICATE KEY UPDATE steam = VALUES(steam), hwid_key = VALUES(hwid_key), name = VALUES(name), points = VALUES(points), ' +
      'kills = VALUES(kills), deaths = VALUES(deaths), playtime_sec = VALUES(playtime_sec), last_seen = VALUES(last_seen), ' +
      'data = VALUES(data), version = VALUES(version), seq = VALUES(seq), deleted = VALUES(deleted), ' +
      'merged_into = VALUES(merged_into), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)', 1024 * 1024);
    { the account rows of this push so far, by number }
    Written := TStringList.Create;
    try
      Written.Sorted := True;
      Written.Duplicates := dupIgnore;
      for i := 0 to High(FItems) do
      begin
        if FStop then
          Break;
        if FItems[i].Kind <> SK_ACCOUNT then
          Continue;
        Target := FItems[i].Id;
        O.Kind := SK_ACCOUNT;
        O.Id := FItems[i].Id;
        O.NewId := 0;
        O.Key := '';
        O.Deleted := False;
        O.MergedInto := 0;
        O.Pushed := True;
        if not DecodeP(FItems[i].Snap, Cur) or not DecodeP(FItems[i].Base, Base) then
          Continue;
        k := 0;
        if FItems[i].IsNew then
        begin
          { new here: the same player may already be in the database }
          k := SameAccount(FItems[i].Steam, FItems[i].Hwid);
          if k > 0 then
            Target := k;
        end;
        { an account that was merged away on another server: its changes go to the one it went into }
        Hops := 0;
        while True do
        begin
          { a row this push has written already (two accounts of this server that go into one): the
            rows still waiting in the batch go in first, or this one would be merged onto the row
            as it was and the batch would write the first one's changes over }
          if Written.IndexOf(IntToStr(Target)) >= 0 then
            Rows.Flush;
          if not LockAccount(Target, Version, Data, RowDeleted, RowMerged) then
          begin
            Data := '';
            Version := 0;
            Break;
          end;
          if RowDeleted and (RowMerged > 0) and (Hops < 5) then
          begin
            Target := RowMerged;
            Inc(Hops);
            Continue;
          end;
          { a new account whose number another account has: it gets a number of its own }
          if FItems[i].IsNew and (k = 0) and (Data <> '') then
          begin
            Target := NewAccountId;
            Data := '';
            Version := 0;
          end;
          Break;
        end;
        { a new computer account goes into the account of the same computer, as at the first start
          (JoinDatabase) - a password set here comes along - unless that account has a password:
          the player of a registered account joins it by logging in, and a session here would play
          on it without one }
        if FItems[i].IsNew and (k > 0) and (FItems[i].Steam = '') and (Data <> '') then
          if not DecodeP(Data, Remote) or (Remote.PassHash <> '') then
          begin
            Target := NewAccountId;
            Data := '';
            Version := 0;
          end;
        if Data <> '' then
        begin
          if not DecodeP(Data, Remote) then
            Continue;
          Merge3Profile(Cur, Base, Remote);
        end;
        Cur.ID := Target;
        Cur.MergedInto := 0;
        O.NewId := Target;
        O.Data := EncodeProfile(Cur);
        O.Version := Version + 1;
        Line := '(' + MyInt(Target) + ', ' + SteamValue(Cur.ActiveSteam) + ', ' + KeyValue(HwidKey(Cur));
        Line := Line + ', ' + MyStrMax(CodepageToUtf8(Cur.ActiveName, FCodepage), 64) + ', ' + MyInt(Cur.Points) + ', ' +
          MyInt(Cur.Kills) + ', ' + MyInt(Cur.Deaths) + ', ' + MyInt(Cur.TimePlayed) + ', ' + MyDate(Cur.LastPlayedTime) + ', ' +
          MyBin(O.Data) + ', ' + MyInt(O.Version) + ', ' + SeqText + ', 0, 0, ' + Sid + ', ' + Stamp + ')';
        Rows.Add(Line);
        Written.Add(IntToStr(Target));
        Add(O);
      end;
      Rows.Flush;
    finally
      Written.Free;
      Rows.Free;
    end;

    { accounts that are gone here }
    for i := 0 to High(FItems) do
      if (FItems[i].Kind = SK_DELETE) and not FStop then
        FConn.Exec('UPDATE zs_db_accounts SET deleted = 1, merged_into = ' + MyInt(FItems[i].MergedInto) +
          ', version = version + 1, seq = ' + SeqText + ', updated_by = ' + Sid + ', updated_at = ' + Stamp +
          ' WHERE id = ' + MyInt(FItems[i].Id));

    { maps, by name }
    for i := 0 to High(FItems) do
    begin
      if (FItems[i].Kind <> SK_MAP) or FStop then
        Continue;
      if not DecodeM(FItems[i].Snap, MC) or not DecodeM(FItems[i].Base, MB) then
        Continue;
      R := FConn.Query('SELECT id, version, data FROM zs_db_maps WHERE name = ' +
        MyStrMax(CodepageToUtf8(FItems[i].Key, FCodepage), 64) + ' FOR UPDATE');
      try
        if R.RowCount > 0 then
        begin
          k := R.Int(0, 0);
          Version := R.Int(0, 1);
          Data := R.Str(0, 2);
        end
        else
        begin
          k := 0;
          Version := 0;
          Data := '';
        end;
      finally
        R.Free;
      end;
      if Data <> '' then
      begin
        if not DecodeM(Data, MR) then
          Continue;
        Merge3Map(MC, MB, MR);
      end;
      if k <= 0 then
      begin
        R := FConn.Query('SELECT value FROM zs_db_meta WHERE name = ''next_map'' FOR UPDATE');
        try
          k := R.Int(0, 0);
        finally
          R.Free;
        end;
        FConn.Exec('UPDATE zs_db_meta SET value = value + 1 WHERE name = ''next_map''');
      end;
      MC.ID := k;
      O.Kind := SK_MAP;
      O.Id := k;
      O.NewId := k;
      O.Key := FItems[i].Key;
      O.Data := EncodeMap(MC);
      O.Version := Version + 1;
      O.Deleted := False;
      O.MergedInto := 0;
      O.Pushed := True;
      FConn.Exec('INSERT INTO zs_db_maps (name, id, plays, kills, playtime_sec, data, version, seq, updated_by, updated_at) VALUES (' +
        MyStrMax(CodepageToUtf8(FItems[i].Key, FCodepage), 64) + ', ' + MyInt(k) + ', ' + MyInt(MC.ActiveMapPlays) + ', ' +
        MyInt(MC.Kills) + ', ' + MyInt(MC.ActiveTimePlays) + ', ' + MyBin(O.Data) + ', ' + MyInt(O.Version) + ', ' + SeqText +
        ', ' + Sid + ', ' + Stamp + ') ON DUPLICATE KEY UPDATE id = VALUES(id), plays = VALUES(plays), kills = VALUES(kills), ' +
        'playtime_sec = VALUES(playtime_sec), data = VALUES(data), version = VALUES(version), seq = VALUES(seq), ' +
        'updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)');
      Add(O);
    end;

    { the server record: one row for all of them }
    for i := 0 to High(FItems) do
    begin
      if (FItems[i].Kind <> SK_SERVER) or FStop then
        Continue;
      if not DecodeS(FItems[i].Snap, SC) or not DecodeS(FItems[i].Base, SB) then
        Continue;
      R := FConn.Query('SELECT version, data FROM zs_db_server WHERE id = 1 FOR UPDATE');
      try
        if R.RowCount > 0 then
        begin
          Version := R.Int(0, 0);
          Data := R.Str(0, 1);
        end
        else
        begin
          Version := 0;
          Data := '';
        end;
      finally
        R.Free;
      end;
      if Data <> '' then
      begin
        if not DecodeS(Data, SR) then
          Continue;
        Merge3Server(SC, SB, SR);
      end;
      O.Kind := SK_SERVER;
      O.Id := 1;
      O.NewId := 1;
      O.Key := '';
      O.Data := EncodeServer(SC);
      O.Version := Version + 1;
      O.Deleted := False;
      O.MergedInto := 0;
      O.Pushed := True;
      FConn.Exec('INSERT INTO zs_db_server (id, data, version, seq, updated_by, updated_at) VALUES (1, ' + MyBin(O.Data) + ', ' +
        MyInt(O.Version) + ', ' + SeqText + ', ' + Sid + ', ' + Stamp + ') ON DUPLICATE KEY UPDATE data = VALUES(data), ' +
        'version = VALUES(version), seq = VALUES(seq), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)');
      Add(O);
    end;

    { the season archives: written by the server that closed the season }
    for i := 0 to High(FItems) do
      if (FItems[i].Kind = SK_SEASON) and not FStop then
        FConn.Exec('INSERT INTO zs_db_seasons (id, data, seq, updated_by, updated_at) VALUES (' + MyInt(FItems[i].Id) + ', ' +
          MyBin(FItems[i].Snap) + ', ' + SeqText + ', ' + Sid + ', ' + Stamp + ') ON DUPLICATE KEY UPDATE data = VALUES(data), ' +
          'seq = VALUES(seq), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)');

    FConn.Exec('UPDATE zs_db_meta SET value = ' + SeqText + ' WHERE name = ''seq''');
    { the mark of this server's last write: a COMMIT whose answer is lost can be looked up (Landed) }
    FConn.Exec('INSERT INTO zs_db_meta (name, value) VALUES (' + MyStr('push_' + IntToStr(FServerId)) + ', ' + SeqText +
      ') ON DUPLICATE KEY UPDATE value = VALUES(value)');
    FCommitSeq := Seq;
    FConn.Exec('COMMIT');
    FCommitSeq := 0;
  except
    { an error the server answered with: the COMMIT, if it was sent, did not go in }
    if (ExceptObject is EMyError) and (EMyError(ExceptObject).Code <> 0) then
      FCommitSeq := 0;
    try
      if FConn.Connected then
        FConn.Exec('ROLLBACK');
    except
    end;
    raise;
  end;
  FRes.Seq := Max(FRes.Seq, Seq);
end;

{ what the other servers wrote since the newest change this server knows }
procedure TSqlThread.Pull;
var
  C: TMyCursor;
  Top, From: Int64;
  O: TSyncOut;
  Since, Sid, Upto: AnsiString;
begin
  Top := MetaValue(FConn, 'seq', False);
  if Top < 0 then
    raise EMyError.CreateCode(0, 'the row seq of zs_db_meta is missing');
  { the seq went back (a database restored from a backup, or another one): everything up to where
    it stands now is read again - the versions leave out what is known - and the engine says the
    server should be started again. High(Int64) asks for no changes at all (PushPending). }
  From := FPullSeq;
  if (Top < FPullSeq) and (FPullSeq <> High(Int64)) then
  begin
    FRes.SeqBack := True;
    From := 0;
  end;
  if Top <= From then
  begin
    if FRes.SeqBack then
      FRes.Seq := Top
    else
      FRes.Seq := Max(FRes.Seq, Top);
    Exit;
  end;
  Since := MyInt(From);
  Upto := MyInt(Top);
  Sid := MyInt(FServerId);
  C := FConn.Open('SELECT id, version, deleted, merged_into, data FROM zs_db_accounts WHERE seq > ' + Since +
    ' AND seq <= ' + Upto + ' AND updated_by <> ' + Sid);
  try
    while C.Next do
    begin
      O.Kind := SK_ACCOUNT;
      O.Id := C.Int(0);
      O.NewId := 0;
      O.Key := '';
      O.Version := C.Int(1);
      O.Deleted := C.Int(2) <> 0;
      O.MergedInto := C.Int(3);
      O.Data := C.Str(4);
      O.Pushed := False;
      Add(O);
    end;
  finally
    C.Free;
  end;
  C := FConn.Open('SELECT name, id, version, data FROM zs_db_maps WHERE seq > ' + Since + ' AND seq <= ' + Upto +
    ' AND updated_by <> ' + Sid);
  try
    while C.Next do
    begin
      O.Kind := SK_MAP;
      O.Key := Utf8ToCodepage(C.Str(0), FCodepage);
      O.Id := C.Int(1);
      O.NewId := 0;
      O.Version := C.Int(2);
      O.Data := C.Str(3);
      O.Deleted := False;
      O.MergedInto := 0;
      O.Pushed := False;
      Add(O);
    end;
  finally
    C.Free;
  end;
  C := FConn.Open('SELECT version, data FROM zs_db_server WHERE id = 1 AND seq > ' + Since + ' AND seq <= ' + Upto +
    ' AND updated_by <> ' + Sid);
  try
    while C.Next do
    begin
      O.Kind := SK_SERVER;
      O.Id := 1;
      O.NewId := 0;
      O.Key := '';
      O.Version := C.Int(0);
      O.Data := C.Str(1);
      O.Deleted := False;
      O.MergedInto := 0;
      O.Pushed := False;
      Add(O);
    end;
  finally
    C.Free;
  end;
  C := FConn.Open('SELECT id, data FROM zs_db_seasons WHERE seq > ' + Since + ' AND seq <= ' + Upto +
    ' AND updated_by <> ' + Sid);
  try
    while C.Next do
    begin
      O.Kind := SK_SEASON;
      O.Id := C.Int(0);
      O.NewId := 0;
      O.Key := '';
      O.Version := 0;
      O.Data := C.Str(1);
      O.Deleted := False;
      O.MergedInto := 0;
      O.Pushed := False;
      Add(O);
    end;
  finally
    C.Free;
  end;
  if FRes.SeqBack then
    FRes.Seq := Top
  else
    FRes.Seq := Max(FRes.Seq, Top);
end;

{ a block of account numbers for the accounts this server makes }
procedure TSqlThread.TakeIds;
var
  First: LongInt;
begin
  FConn.Exec('START TRANSACTION');
  try
    First := TakeAccountIds(FConn, ID_BLOCK);
    FConn.Exec('COMMIT');
  except
    try
      if FConn.Connected then
        FConn.Exec('ROLLBACK');
    except
    end;
    raise;
  end;
  FRes.IdFrom := First;
  FRes.IdTo := First + ID_BLOCK;
end;

{ one server for a job of the day: whoever writes the new day first }
procedure TSqlThread.ClaimJobs;
var
  i: LongInt;
  R: TMyResult;
begin
  for i := 0 to High(FJobs) do
  begin
    FConn.Exec('INSERT INTO zs_db_jobs (job, day, server_id, taken_at) VALUES (' + MyStr(FJobs[i].Job) + ', ' +
      MyInt(FJobs[i].Day) + ', ' + MyInt(FServerId) + ', ' + MyDate(Now) + ') ON DUPLICATE KEY UPDATE ' +
      'server_id = IF(day < VALUES(day), VALUES(server_id), server_id), ' +
      'taken_at = IF(day < VALUES(day), VALUES(taken_at), taken_at), day = GREATEST(day, VALUES(day))');
    R := FConn.Query('SELECT day, server_id FROM zs_db_jobs WHERE job = ' + MyStr(FJobs[i].Job));
    try
      if (R.RowCount > 0) and (R.Int(0, 0) = FJobs[i].Day) and (R.Int(0, 1) = FServerId) then
        FJobs[i].Granted := 1
      else
        FJobs[i].Granted := -1;
    finally
      R.Free;
    end;
  end;
  FRes.Jobs := Copy(FJobs);
end;

{ after a COMMIT whose answer never came: True when that push is in the database (the mark of this
  server's last write holds its seq), False when it is not or when that cannot be known now }
function TSqlThread.Landed(Seq: Int64): Boolean;
begin
  Result := False;
  if FStop then
    Exit;
  try
    Connect;
    Result := MetaValue(FConn, 'push_' + IntToStr(FServerId), False) = Seq;
  except
    Disconnect;
  end;
end;

procedure TSqlThread.Execute;
var
  Have, Pulled: Boolean;
begin
  GuardWorkerThread;
  CrashThread(CT_MIRROR);
  while not FStop do
  begin
    RTLEventWaitFor(FWake, 1000);
    EnterCriticalSection(FLock);
    try
      Have := FHave;
    finally
      LeaveCriticalSection(FLock);
    end;
    if not Have or FStop then
      Continue;
    FOutCount := 0;
    FRes.Rows := nil;
    FRes.Ok := False;
    FRes.Error := '';
    FRes.Seq := FPullSeq;
    FRes.IdFrom := 0;
    FRes.IdTo := 0;
    FRes.Jobs := nil;
    FRes.Joined := False;
    FRes.NotJoined := False;
    FRes.SeqBack := False;
    FRes.CommitUnsure := False;
    FCommitSeq := 0;
    try
      Connect;
      if FCheckJoin then
      begin
        { the server started without the database: the numbers of its files are the database's
          only when it joined the database before; otherwise nothing may go in by them }
        PrepareTables(FConn);
        FRes.NotJoined := MetaValue(FConn, 'joined_' + IntToStr(FServerId), False) < 0;
        FRes.Joined := not FRes.NotJoined;
      end;
      if not FRes.NotJoined then
      begin
        Push;
        FRes.Ok := True;
        { the answers of the push are in; a failure after it only loses the news of this round }
        Pulled := False;
        try
          Pull;
          Pulled := True;
          if FNeedIds then
            TakeIds;
          if Length(FJobs) > 0 then
            ClaimJobs;
        except
          on Ex: Exception do
          begin
            FRes.Error := Ex.Message;
            { the next round reads the other servers' changes from where this one began: the seq
              of this push would skip the ones below it that were not read }
            if not Pulled then
              FRes.Seq := FPullSeq;
            Disconnect;
          end;
        end;
      end;
    except
      on Ex: Exception do
      begin
        FRes.Error := Ex.Message;
        Disconnect;
        if (FCommitSeq > 0) and Landed(FCommitSeq) then
        begin
          { only the answer to the COMMIT was lost: the push is in and its answers stand; nothing
            was read }
          FRes.Ok := True;
          FRes.Seq := FPullSeq;
        end
        else
        begin
          FRes.Ok := False;
          FRes.CommitUnsure := FCommitSeq > 0;
          FOutCount := 0;
        end;
        FCommitSeq := 0;
      end;
    end;
    SetLength(FRes.Rows, FOutCount);
    EnterCriticalSection(FLock);
    try
      FHave := False;
      FDone := True;
      FItems := nil;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
end;

procedure TSqlThread.Submit(const Items: TSyncItems; const Jobs: TSyncJobs; PullSeq: Int64; NeedIds, CheckJoin: Boolean);
begin
  EnterCriticalSection(FLock);
  try
    FItems := Items;
    FJobs := Copy(Jobs);
    FPullSeq := PullSeq;
    FNeedIds := NeedIds;
    FCheckJoin := CheckJoin;
    FHave := True;
    FDone := False;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
end;

function TSqlThread.TakeResult(out R: TSyncResult): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDone;
    if Result then
    begin
      R := FRes;
      FRes.Rows := nil;
      FRes.Jobs := nil;
      FDone := False;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TSqlThread.StopAndWait;
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

{ ---------------- the engine side ---------------- }

constructor TSqlState.Create(E: TZSEngine);
begin
  Engine := E;
  InFlight := TStringList.Create;
  InFlight.Sorted := True;
  InFlight.Duplicates := dupIgnore;
  InFlight.CaseSensitive := True;
  InFlight.OwnsObjects := True;
  Jobs := TStringList.Create;
  Jobs.Sorted := True;
  Jobs.Duplicates := dupIgnore;
end;

destructor TSqlState.Destroy;
begin
  if Thread <> nil then
  begin
    Thread.StopAndWait;
    FreeAndNil(Thread);
  end;
  InFlight.Free;
  Jobs.Free;
  inherited Destroy;
end;

{ the next account number: from the block of the database, else the server's own counter (a
  number that is taken already is changed by the database on the next exchange) }
function TSqlState.NextProfileId: LongInt;
begin
  if IdNext < IdEnd then
  begin
    Result := IdNext;
    Inc(IdNext);
    Exit;
  end;
  Result := Engine.DB.Server.NextProfileID;
  if Result <= 0 then
    Result := 1;
  Engine.DB.Server.NextProfileID := Result + 1;
end;

function FindById(E: TZSEngine; Id: LongInt): LongInt;
begin
  Result := E.DB.IndexOfId(Id);
end;

{ the players on the server follow their account to its new number }
procedure FollowSlots(E: TZSEngine; OldId, NewId: LongInt);
var
  k: LongInt;
begin
  if (OldId = NewId) or (OldId <= 0) then
    Exit;
  for k := 1 to MAX_PLAYERS do
    if E.Identity.Slots[k].InUse and (E.Identity.Slots[k].ProfileId = OldId) then
    begin
      E.Identity.Slots[k].ProfileId := NewId;
      E.Identity.Slots[k].CachedIndex := -1;
    end;
end;

{ Cur := Remote with the changes of Cur since Base on top, and the database's new base }
procedure RebaseProfile(E: TZSEngine; Idx: LongInt; const BaseData, RemoteData: AnsiString; Version: Int64);
var
  B, R: TPlayerProfile;
  P: PPlayerProfile;
begin
  if not E.DB.Valid(Idx) then
    Exit;
  if not DecodeP(BaseData, B) or not DecodeP(RemoteData, R) then
    Exit;
  P := E.DB.Profiles[Idx];
  E.DB.BeginIdentityChange(Idx);
  Merge3Profile(P^, B, R);
  E.DB.EndIdentityChange(Idx);
  P^.SyncBase := RemoteData;
  P^.SyncVersion := Version;
  E.DB.RefreshRanks(Idx);
  E.DB.Touch(Idx);
end;

procedure ApplyAccount(E: TZSEngine; St: TSqlState; const O: TSyncOut; var Again: TIntArray; var AgainCount: LongInt);
var
  Idx, Other, k: LongInt;
  Snap: TSnapObj;
  X, T, B, M, OB: TPlayerProfile;
  P: PPlayerProfile;
begin
  if O.Pushed then
  begin
    k := St.InFlight.IndexOf('A' + IntToStr(O.Id));
    if k < 0 then
      Exit;
    Snap := TSnapObj(St.InFlight.Objects[k]);
    Idx := FindById(E, O.Id);
    if not E.DB.Valid(Idx) then
      Exit;
    if (O.NewId > 0) and (O.NewId <> O.Id) then
    begin
      Other := FindById(E, O.NewId);
      if E.DB.Valid(Other) and (Other <> Idx) then
      begin
        { the database put this account into one this server has as well: the two become one
          here too - the other one's own changes and this one's since the snapshot go on top }
        if not DecodeP(Snap.Data, B) or not DecodeP(O.Data, M) or not DecodeP(E.DB.Profiles[Other]^.SyncBase, OB) then
          Exit;
        T := E.DB.Profiles[Other]^;
        UniqueProfileLists(T);
        Merge3Profile(T, OB, M);
        X := E.DB.Profiles[Idx]^;
        UniqueProfileLists(X);
        Merge3Profile(X, B, T);
        X.ID := O.NewId;
        E.DB.BeginIdentityChange(Other);
        P := E.DB.Profiles[Other];
        X.SyncBase := O.Data;
        X.SyncVersion := O.Version;
        X.SyncDirty := P^.SyncDirty;
        X.Dirty := P^.Dirty;
        P^ := X;
        E.DB.EndIdentityChange(Other);
        E.DB.RefreshRanks(Other);
        E.DB.Touch(Other);
        FollowSlots(E, O.Id, O.NewId);
        E.DB.DeleteProfile(Idx);
        { what this server added on top still has to go in }
        if AgainCount >= Length(Again) then
          SetLength(Again, AgainCount * 2 + 8);
        Again[AgainCount] := Other;
        Inc(AgainCount);
        Exit;
      end;
      E.DB.ChangeProfileId(Idx, O.NewId);
      FollowSlots(E, O.Id, O.NewId);
      { another account may have had the number this one had: read everything again once }
      St.NeedFull := True;
    end;
    RebaseProfile(E, Idx, Snap.Data, O.Data, O.Version);
    Exit;
  end;

  { a change of another server. One of an account this server has just pushed is older than the
    push (which read it and merged it) or newer (written after it): the version tells them apart,
    so a change written between the push and the pull is not lost. }
  Idx := FindById(E, O.Id);
  if O.Deleted then
  begin
    if not E.DB.Valid(Idx) then
      Exit;
    Other := -1;
    if O.MergedInto > 0 then
      Other := FindById(E, O.MergedInto);
    if E.Identity.SlotOfProfile(O.Id) > 0 then
    begin
      { the player is here now: the account stays, and the next exchange brings it back }
      if E.DB.Valid(Other) then
        Exit;
      E.DB.Profiles[Idx]^.SyncBase := '';
      if AgainCount >= Length(Again) then
        SetLength(Again, AgainCount * 2 + 8);
      Again[AgainCount] := Idx;
      Inc(AgainCount);
      Exit;
    end;
    E.DB.DeleteProfile(Idx);
    Exit;
  end;
  if E.DB.Valid(Idx) then
  begin
    if O.Version <= E.DB.Profiles[Idx]^.SyncVersion then
      Exit;
    { an account made here under the same number and not sent yet: the push gives it a number
      of its own, and the whole database is read again after it }
    if E.DB.Profiles[Idx]^.SyncBase = '' then
    begin
      St.NeedFull := True;
      Exit;
    end;
    RebaseProfile(E, Idx, E.DB.Profiles[Idx]^.SyncBase, O.Data, O.Version);
    Exit;
  end;
  { an account made on another server }
  P := NewProfile;
  if not DecodeP(O.Data, P^) then
  begin
    FreeProfile(P);
    Exit;
  end;
  P^.ID := O.Id;
  P^.SyncBase := O.Data;
  P^.SyncVersion := O.Version;
  E.DB.AdoptProfile(P);
end;

procedure ApplyMap(E: TZSEngine; St: TSqlState; const O: TSyncOut);
var
  MI, k: LongInt;
  B, R: TMapProfile;
  Snap: TSnapObj;
begin
  MI := E.DB.FindMap(O.Key, False);
  if O.Pushed then
  begin
    k := St.InFlight.IndexOf('M' + O.Key);
    if (k < 0) or (MI < 0) then
      Exit;
    Snap := TSnapObj(St.InFlight.Objects[k]);
    if not DecodeM(Snap.Data, B) or not DecodeM(O.Data, R) then
      Exit;
  end
  else
  begin
    { as with the accounts: the version says whether it is newer than this server's own push }
    if MI < 0 then
    begin
      if not DecodeM(O.Data, R) then
        Exit;
      R.ID := O.Id;
      R.MapName := O.Key;
      R.SyncBase := O.Data;
      R.SyncVersion := O.Version;
      E.DB.AdoptMap(R);
      Exit;
    end;
    if O.Version <= E.DB.Maps[MI].SyncVersion then
      Exit;
    if not DecodeM(E.DB.Maps[MI].SyncBase, B) or not DecodeM(O.Data, R) then
      Exit;
  end;
  E.DB.Maps[MI].Heat := Copy(E.DB.Maps[MI].Heat);
  Merge3Map(E.DB.Maps[MI], B, R);
  if O.Id > 0 then
    E.DB.Maps[MI].ID := O.Id;
  E.DB.Maps[MI].SyncBase := O.Data;
  E.DB.Maps[MI].SyncVersion := O.Version;
  E.DB.TouchMap(MI);
end;

procedure ApplyServer(E: TZSEngine; St: TSqlState; const O: TSyncOut);
var
  B, R: TServerRecords;
  k: LongInt;
begin
  if O.Pushed then
  begin
    k := St.InFlight.IndexOf('S');
    if k < 0 then
      Exit;
    if not DecodeS(TSnapObj(St.InFlight.Objects[k]).Data, B) then
      Exit;
  end
  else
  begin
    if O.Version <= E.DB.Server.SyncVersion then
      Exit;
    if not DecodeS(E.DB.Server.SyncBase, B) then
      Exit;
  end;
  if not DecodeS(O.Data, R) then
    Exit;
  E.DB.Server.Daily := Copy(E.DB.Server.Daily);
  Merge3Server(E.DB.Server, B, R);
  E.DB.Server.SyncBase := O.Data;
  E.DB.Server.SyncVersion := O.Version;
  E.DB.TouchServer;
end;

procedure ApplySeason(E: TZSEngine; const O: TSyncOut);
var
  A: TSeasonArchive;
  k, n: LongInt;
begin
  if not DecodeSeason(O.Data, A) then
    Exit;
  for k := 0 to High(E.DB.Seasons) do
    if E.DB.Seasons[k].Id = A.Id then
    begin
      E.DB.Seasons[k] := A;
      E.DB.TouchSeason(k);
      Exit;
    end;
  n := Length(E.DB.Seasons);
  SetLength(E.DB.Seasons, n + 1);
  E.DB.Seasons[n] := A;
  E.DB.TouchSeason(n);
end;

{ ---------------- what waits for the database, beside the files ---------------- }

const
  PENDING_MAGIC = $4853535A;   { "ZSSH" }
  PENDING_FORMAT = 1;

type
  TPendAccount = record
    Id: LongInt;
    IsNew: Boolean;
    Base: AnsiString;
  end;
  TPendMap = record
    Name, Base: AnsiString;
  end;
  TPending = record
    Accounts: array of TPendAccount;
    Maps: array of TPendMap;
    HasServer: Boolean;
    ServerBase: AnsiString;
    Seasons: array of LongInt;
    Deleted: TSyncDeletedArray;
  end;

function PendingPath(E: TZSEngine): AnsiString;
begin
  Result := StorePath(E.DataDir, ChangeFileExt(E.Cfg.SnapshotFile, '.shared'));
end;

{ Every record marked for the next exchange or on its way, with the state the database had
  before; nothing waiting removes the file. The engine thread calls it. }
procedure WritePending(E: TZSEngine; St: TSqlState);
var
  Pend: TPending;
  k, n, Idx: LongInt;
  P: PPlayerProfile;
  SI: TIntArray;
  D: TSyncDeletedArray;
  FS: TFileStream;
  Path: AnsiString;

  procedure PutStr(const V: AnsiString);
  var
    L: LongInt;
  begin
    L := Length(V);
    FS.WriteBuffer(L, SizeOf(L));
    if L > 0 then FS.WriteBuffer(V[1], L);
  end;

  procedure PutInt(V: LongInt);
  begin
    FS.WriteBuffer(V, SizeOf(V));
  end;

begin
  Path := PendingPath(E);
  St.PendingAt := MonoMs;
  { a server that is not in the database by the numbers of its files keeps no list: its next start
    joins it with everything the files hold, and a list would go in by the wrong numbers }
  if St.Blocked <> '' then
  begin
    try
      if FileExists(Path) then
        DeleteFile(Path);
    except
    end;
    St.PendingOnDisk := False;
    Exit;
  end;
  Pend.Accounts := nil;
  Pend.Maps := nil;
  Pend.Seasons := nil;
  Pend.Deleted := nil;
  n := 0;
  for k := 0 to E.DB.ProfileCount - 1 do
  begin
    if not E.DB.Valid(k) then
      Continue;
    P := E.DB.Profiles[k];
    if not P^.SyncDirty and (St.InFlight.IndexOf('A' + IntToStr(P^.ID)) < 0) then
      Continue;
    if n >= Length(Pend.Accounts) then
      SetLength(Pend.Accounts, n * 2 + 16);
    Pend.Accounts[n].Id := P^.ID;
    Pend.Accounts[n].IsNew := P^.SyncBase = '';
    Pend.Accounts[n].Base := P^.SyncBase;
    Inc(n);
  end;
  SetLength(Pend.Accounts, n);
  n := 0;
  for k := 0 to E.DB.MapCount - 1 do
    if E.DB.Maps[k].SyncDirty or (St.InFlight.IndexOf('M' + E.DB.Maps[k].MapName) >= 0) then
    begin
      SetLength(Pend.Maps, n + 1);
      Pend.Maps[n].Name := E.DB.Maps[k].MapName;
      Pend.Maps[n].Base := E.DB.Maps[k].SyncBase;
      Inc(n);
    end;
  Pend.HasServer := E.DB.SyncServerPending or (St.InFlight.IndexOf('S') >= 0);
  Pend.ServerBase := E.DB.Server.SyncBase;
  SI := E.DB.SyncSeasonsPending;
  for k := 0 to High(SI) do
    if (SI[k] >= 0) and (SI[k] <= High(E.DB.Seasons)) then
    begin
      SetLength(Pend.Seasons, Length(Pend.Seasons) + 1);
      Pend.Seasons[High(Pend.Seasons)] := E.DB.Seasons[SI[k]].Id;
    end;
  D := E.DB.SyncDeletedPending;
  for k := 0 to St.InFlight.Count - 1 do
    case St.InFlight[k][1] of
      'N':
        begin
          SetLength(Pend.Seasons, Length(Pend.Seasons) + 1);
          Pend.Seasons[High(Pend.Seasons)] := StrToIntDef(Copy(St.InFlight[k], 2, MaxInt), 0);
        end;
      'D':
        begin
          Idx := Length(D);
          SetLength(D, Idx + 1);
          D[Idx].Id := TSnapObj(St.InFlight.Objects[k]).Id;
          D[Idx].MergedInto := TSnapObj(St.InFlight.Objects[k]).MergedInto;
        end;
    end;
  Pend.Deleted := D;
  try
    if (Length(Pend.Accounts) = 0) and (Length(Pend.Maps) = 0) and not Pend.HasServer and (Length(Pend.Seasons) = 0) and
       (Length(Pend.Deleted) = 0) then
    begin
      if FileExists(Path) then
        DeleteFile(Path);
      St.PendingOnDisk := False;
      Exit;
    end;
    FS := TFileStream.Create(Path + '.tmp', fmCreate);
    try
      PutInt(LongInt(PENDING_MAGIC));
      PutInt(PENDING_FORMAT);
      PutInt(E.Cfg.MySQLServerID);
      PutStr(LowerCase(E.Cfg.MySQLDatabase));
      PutInt(Length(Pend.Accounts));
      for k := 0 to High(Pend.Accounts) do
      begin
        PutInt(Pend.Accounts[k].Id);
        PutInt(Ord(Pend.Accounts[k].IsNew));
        PutStr(Pend.Accounts[k].Base);
      end;
      PutInt(Length(Pend.Maps));
      for k := 0 to High(Pend.Maps) do
      begin
        PutStr(Pend.Maps[k].Name);
        PutStr(Pend.Maps[k].Base);
      end;
      PutInt(Ord(Pend.HasServer));
      PutStr(Pend.ServerBase);
      PutInt(Length(Pend.Seasons));
      for k := 0 to High(Pend.Seasons) do
        PutInt(Pend.Seasons[k]);
      PutInt(Length(Pend.Deleted));
      for k := 0 to High(Pend.Deleted) do
      begin
        PutInt(Pend.Deleted[k].Id);
        PutInt(Pend.Deleted[k].MergedInto);
      end;
    finally
      FS.Free;
    end;
    if FileExists(Path) then
      DeleteFile(Path);
    RenameFile(Path + '.tmp', Path);
    St.PendingOnDisk := True;
  except
    on Ex: Exception do
      E.WriteServer('[ZitroStats] shared database: ' + Path + ' could not be written (' + Ex.Message + ')');
  end;
end;

{ what waited beside the files, when it belongs to this server and this database }
function ReadPending(E: TZSEngine; out Pend: TPending): Boolean;
var
  FS: TFileStream;
  n, k, V: LongInt;
  S: AnsiString;

  function GetInt(out X: LongInt): Boolean;
  begin
    Result := FS.Read(X, SizeOf(X)) = SizeOf(X);
  end;

  function GetStr(out X: AnsiString): Boolean;
  var
    L: LongInt;
  begin
    X := '';
    Result := GetInt(L) and (L >= 0) and (L <= 64 * 1024 * 1024);
    if not Result or (L = 0) then
      Exit;
    SetLength(X, L);
    Result := FS.Read(X[1], L) = L;
  end;

begin
  Result := False;
  Pend.Accounts := nil;
  Pend.Maps := nil;
  Pend.HasServer := False;
  Pend.ServerBase := '';
  Pend.Seasons := nil;
  Pend.Deleted := nil;
  if not FileExists(PendingPath(E)) then
    Exit;
  try
    FS := TFileStream.Create(PendingPath(E), fmOpenRead or fmShareDenyWrite);
    try
      if not GetInt(V) or (V <> LongInt(PENDING_MAGIC)) then Exit;
      if not GetInt(V) or (V <> PENDING_FORMAT) then Exit;
      if not GetInt(V) or (V <> E.Cfg.MySQLServerID) then Exit;
      if not GetStr(S) or (S <> LowerCase(E.Cfg.MySQLDatabase)) then Exit;
      { a count larger than the file is a damaged file, not a reason to reserve that much memory }
      if not GetInt(n) or (n < 0) or (n > FS.Size) then Exit;
      SetLength(Pend.Accounts, n);
      for k := 0 to n - 1 do
      begin
        if not GetInt(Pend.Accounts[k].Id) or not GetInt(V) or not GetStr(Pend.Accounts[k].Base) then Exit;
        Pend.Accounts[k].IsNew := V <> 0;
      end;
      if not GetInt(n) or (n < 0) or (n > FS.Size) then Exit;
      SetLength(Pend.Maps, n);
      for k := 0 to n - 1 do
        if not GetStr(Pend.Maps[k].Name) or not GetStr(Pend.Maps[k].Base) then Exit;
      if not GetInt(V) or not GetStr(Pend.ServerBase) then Exit;
      Pend.HasServer := V <> 0;
      if not GetInt(n) or (n < 0) or (n > FS.Size) then Exit;
      SetLength(Pend.Seasons, n);
      for k := 0 to n - 1 do
        if not GetInt(Pend.Seasons[k]) then Exit;
      if not GetInt(n) or (n < 0) or (n > FS.Size) then Exit;
      SetLength(Pend.Deleted, n);
      for k := 0 to n - 1 do
        if not GetInt(Pend.Deleted[k].Id) or not GetInt(Pend.Deleted[k].MergedInto) then Exit;
      Result := True;
    finally
      FS.Free;
    end;
  except
    Result := False;
  end;
end;

{ the waiting changes go into the next exchange, from the state the database had before them }
procedure ApplyPending(E: TZSEngine; const Pend: TPending);
var
  k, i, Idx: LongInt;
begin
  for k := 0 to High(Pend.Accounts) do
  begin
    Idx := FindById(E, Pend.Accounts[k].Id);
    if not E.DB.Valid(Idx) then
      Continue;
    if Pend.Accounts[k].IsNew then
      E.DB.Profiles[Idx]^.SyncBase := ''
    else
      E.DB.Profiles[Idx]^.SyncBase := Pend.Accounts[k].Base;
    E.DB.Profiles[Idx]^.SyncDirty := False;
    E.DB.SyncMark(Idx);
  end;
  for k := 0 to High(Pend.Maps) do
  begin
    Idx := E.DB.FindMap(Pend.Maps[k].Name, False);
    if Idx < 0 then
      Continue;
    E.DB.Maps[Idx].SyncBase := Pend.Maps[k].Base;
    E.DB.Maps[Idx].SyncDirty := False;
    E.DB.SyncMarkMap(Idx);
  end;
  if Pend.HasServer then
  begin
    E.DB.Server.SyncBase := Pend.ServerBase;
    E.DB.SyncMarkServer;
  end;
  for k := 0 to High(Pend.Seasons) do
    for i := 0 to High(E.DB.Seasons) do
      if E.DB.Seasons[i].Id = Pend.Seasons[k] then
        E.DB.TouchSeason(i);
  E.DB.RequeueDeleted(Pend.Deleted);
end;

{ the batch could not be written: its changes wait for the next one }
procedure Requeue(E: TZSEngine; St: TSqlState);
var
  k, Idx: LongInt;
  Key: AnsiString;
  D: TSyncDeletedArray;
begin
  D := nil;
  for k := 0 to St.InFlight.Count - 1 do
  begin
    Key := St.InFlight[k];
    case Key[1] of
      'A':
        begin
          Idx := FindById(E, StrToIntDef(Copy(Key, 2, MaxInt), 0));
          if E.DB.Valid(Idx) then
          begin
            E.DB.Profiles[Idx]^.SyncDirty := False;
            E.DB.SyncMark(Idx);
          end;
        end;
      'M':
        begin
          Idx := E.DB.FindMap(Copy(Key, 2, MaxInt), False);
          if Idx >= 0 then
          begin
            E.DB.Maps[Idx].SyncDirty := False;
            E.DB.SyncMarkMap(Idx);
          end;
        end;
      'S':
        E.DB.SyncMarkServer;
      'N':
        for Idx := 0 to High(E.DB.Seasons) do
          if E.DB.Seasons[Idx].Id = StrToIntDef(Copy(Key, 2, MaxInt), 0) then
            E.DB.TouchSeason(Idx);
      'D':
        begin
          SetLength(D, Length(D) + 1);
          D[High(D)].Id := TSnapObj(St.InFlight.Objects[k]).Id;
          D[High(D)].MergedInto := TSnapObj(St.InFlight.Objects[k]).MergedInto;
        end;
    end;
  end;
  E.DB.RequeueDeleted(D);
end;

{ nothing is exchanged any more until the server starts again: the numbers in memory are not the
  database's. Why is short (the status shows it), Text says it all once on the console. }
procedure Block(E: TZSEngine; St: TSqlState; const Why, Text: AnsiString);
begin
  if St.Blocked <> '' then
    Exit;
  St.Blocked := Why;
  St.Online := False;
  St.InFlight.Clear;
  { nothing is marked for an exchange that does not come }
  E.DB.SyncOn := False;
  E.WriteServer('[ZitroStats] shared database: ' + Text);
  WritePending(E, St);
end;

procedure ApplyResult(E: TZSEngine; St: TSqlState; const R: TSyncResult);
var
  i, k, AgainCount: LongInt;
  Again: TIntArray;
begin
  if R.Joined then
    St.Joined := True;
  if R.NotJoined then
  begin
    Block(E, St, 'this server has not joined it yet', 'this server has not joined the database yet (it started ' +
      'without it), so nothing is exchanged until it is started again while the database answers - that start ' +
      'joins it with everything its files hold');
    Exit;
  end;
  if R.SeqBack and not St.SeqWarned then
  begin
    St.SeqWarned := True;
    E.WriteServer('[ZitroStats] shared database: its change counter (zs_db_meta seq) went back - a database restored ' +
      'from a backup? The exchange goes on from where it stands now; restart this server to read the database again');
  end;
  if not R.Ok then
  begin
    if St.Online or (St.LastError <> R.Error) then
      E.WriteServer('[ZitroStats] shared database: ' + R.Error + ' - the changes wait and go in once it answers');
    St.Online := False;
    St.LastError := R.Error;
    Inc(St.Fails);
    Requeue(E, St);
    St.InFlight.Clear;
    St.NeedFull := True;
    { what waits is kept beside the files every half a minute, so a server that stops before the
      database answers again still sends it after its next start }
    if MonoMs - St.PendingAt > 30000 then
      WritePending(E, St);
    Exit;
  end;
  St.Fails := 0;
  if not St.Online then
    E.WriteServer('[ZitroStats] shared database: connected, the exchange runs');
  St.Online := True;
  St.EverOnline := True;
  St.LastOkMs := MonoMs;
  if R.Error <> '' then
    St.LastError := R.Error
  else
    St.LastError := '';
  Inc(St.Cycles);
  if R.IdTo > R.IdFrom then
  begin
    St.IdNext := R.IdFrom;
    St.IdEnd := R.IdTo;
  end;
  Again := nil;
  AgainCount := 0;
  E.DB.BeginRemote;
  try
    for i := 0 to High(R.Rows) do
    begin
      if R.Rows[i].Pushed then
        Inc(St.Pushed)
      else
        Inc(St.Pulled);
      case R.Rows[i].Kind of
        SK_ACCOUNT: ApplyAccount(E, St, R.Rows[i], Again, AgainCount);
        SK_MAP: ApplyMap(E, St, R.Rows[i]);
        SK_SERVER: ApplyServer(E, St, R.Rows[i]);
        SK_SEASON: ApplySeason(E, R.Rows[i]);
      end;
    end;
  finally
    E.DB.EndRemote;
  end;
  for i := 0 to AgainCount - 1 do
    E.DB.SyncMark(Again[i]);
  { a seq that went back is taken as it is, or nothing would be read until it passes the old one }
  if R.SeqBack or (R.Seq > St.PullSeq) then
    St.PullSeq := R.Seq;
  for i := 0 to High(R.Jobs) do
  begin
    k := St.Jobs.IndexOf(R.Jobs[i].Job + '|' + IntToStr(R.Jobs[i].Day));
    if k >= 0 then
      St.Jobs.Objects[k] := TObject(PtrInt(R.Jobs[i].Granted));
  end;
  St.InFlight.Clear;
  { what waited beside the files is in: the file says so }
  if St.PendingOnDisk then
    WritePending(E, St);
end;

{ what is marked goes to the thread. A long list (after hours without the database) goes in
  PUSH_CHUNK accounts at a time: one exchange holds the turn of every server only that long, and
  the rest stays marked for the next one. All sends everything at once (PushPending: the database
  is read right after it). }
procedure SubmitBatch(E: TZSEngine; St: TSqlState; All: Boolean = False);
var
  PIdx, MIdx, SIdx: TIntArray;
  Del: TSyncDeletedArray;
  Srv: Boolean;
  Items: TSyncItems;
  Jobs: TSyncJobs;
  n, k, j: LongInt;
  P: PPlayerProfile;
  Snap: TSnapObj;
begin
  E.DB.TakeSyncWork(PIdx, MIdx, Srv, SIdx, Del);
  SetLength(Items, Length(PIdx) + Length(MIdx) + Length(SIdx) + Length(Del) + 1);
  n := 0;
  St.InFlight.Clear;
  for k := 0 to High(PIdx) do
  begin
    if not E.DB.Valid(PIdx[k]) then
      Continue;
    P := E.DB.Profiles[PIdx[k]];
    P^.SyncDirty := False;
    if not All and (n >= PUSH_CHUNK) then
    begin
      E.DB.SyncMark(PIdx[k]);
      Continue;
    end;
    if St.InFlight.IndexOf('A' + IntToStr(P^.ID)) >= 0 then
      Continue;
    Items[n].Kind := SK_ACCOUNT;
    Items[n].Id := P^.ID;
    Items[n].Snap := EncodeProfile(P^);
    Items[n].IsNew := P^.SyncBase = '';
    if Items[n].IsNew then
      Items[n].Base := St.Fresh
    else
      Items[n].Base := P^.SyncBase;
    if IsRealSteam(P^.ActiveSteam) then
      Items[n].Steam := P^.ActiveSteam
    else
      Items[n].Steam := '';
    Items[n].Name := P^.ActiveName;
    Items[n].Hwid := HwidKey(P^);
    Snap := TSnapObj.Create;
    Snap.Data := Items[n].Snap;
    Snap.Id := P^.ID;
    St.InFlight.AddObject('A' + IntToStr(P^.ID), Snap);
    Inc(n);
  end;
  for k := 0 to High(MIdx) do
  begin
    if (MIdx[k] < 0) or (MIdx[k] >= E.DB.MapCount) then
      Continue;
    E.DB.Maps[MIdx[k]].SyncDirty := False;
    if St.InFlight.IndexOf('M' + E.DB.Maps[MIdx[k]].MapName) >= 0 then
      Continue;
    Items[n].Kind := SK_MAP;
    Items[n].Key := E.DB.Maps[MIdx[k]].MapName;
    Items[n].Snap := EncodeMap(E.DB.Maps[MIdx[k]]);
    Items[n].Base := E.DB.Maps[MIdx[k]].SyncBase;
    Snap := TSnapObj.Create;
    Snap.Data := Items[n].Snap;
    St.InFlight.AddObject('M' + Items[n].Key, Snap);
    Inc(n);
  end;
  if Srv then
  begin
    Items[n].Kind := SK_SERVER;
    Items[n].Snap := EncodeServer(E.DB.Server);
    Items[n].Base := E.DB.Server.SyncBase;
    Snap := TSnapObj.Create;
    Snap.Data := Items[n].Snap;
    St.InFlight.AddObject('S', Snap);
    Inc(n);
  end;
  for k := 0 to High(SIdx) do
  begin
    if (SIdx[k] < 0) or (SIdx[k] > High(E.DB.Seasons)) then
      Continue;
    Items[n].Kind := SK_SEASON;
    Items[n].Id := E.DB.Seasons[SIdx[k]].Id;
    Items[n].Snap := EncodeSeason(E.DB.Seasons[SIdx[k]]);
    Snap := TSnapObj.Create;
    St.InFlight.AddObject('N' + IntToStr(Items[n].Id), Snap);
    Inc(n);
  end;
  for k := 0 to High(Del) do
  begin
    Items[n].Kind := SK_DELETE;
    Items[n].Id := Del[k].Id;
    Items[n].MergedInto := Del[k].MergedInto;
    Snap := TSnapObj.Create;
    Snap.Id := Del[k].Id;
    Snap.MergedInto := Del[k].MergedInto;
    St.InFlight.AddObject('D' + IntToStr(Del[k].Id), Snap);
    Inc(n);
  end;
  SetLength(Items, n);
  Jobs := nil;
  for k := 0 to St.Jobs.Count - 1 do
    if PtrInt(St.Jobs.Objects[k]) = 0 then
    begin
      j := Length(Jobs);
      SetLength(Jobs, j + 1);
      Jobs[j].Job := Copy(St.Jobs[k], 1, Pos('|', St.Jobs[k]) - 1);
      Jobs[j].Day := StrToIntDef(Copy(St.Jobs[k], Pos('|', St.Jobs[k]) + 1, MaxInt), 0);
      Jobs[j].Granted := 0;
    end;
  if St.NeedFull then
  begin
    St.Thread.Submit(Items, Jobs, 0, St.IdEnd - St.IdNext < ID_LOW, not St.Joined);
    St.NeedFull := False;
  end
  else
    St.Thread.Submit(Items, Jobs, St.PullSeq, St.IdEnd - St.IdNext < ID_LOW, not St.Joined);
  St.Busy := True;
end;

{ ---------------- start ---------------- }

procedure PrepareTables(C: TMyConnection);
var
  R: TMyResult;
  i: LongInt;
begin
  MyPrepareTable(C, 'zs_db_accounts', ACC_COLS, ACC_KEYS);
  MyPrepareTable(C, 'zs_db_maps', MAP_COLS, MAP_KEYS);
  MyPrepareTable(C, 'zs_db_server', SRV_COLS, SRV_KEYS);
  MyPrepareTable(C, 'zs_db_seasons', SEASON_COLS, SEASON_KEYS);
  MyPrepareTable(C, 'zs_db_meta', META_COLS, META_KEYS);
  MyPrepareTable(C, 'zs_db_jobs', JOB_COLS, JOB_KEYS);
  { the servers take turns by row locks inside transactions: a table made by hand with another
    engine (MyISAM has neither) would let them write over each other's changes }
  R := C.Query('SELECT table_name, engine FROM information_schema.tables WHERE table_schema = DATABASE() AND ' +
    'table_name IN (''zs_db_accounts'', ''zs_db_maps'', ''zs_db_server'', ''zs_db_seasons'', ''zs_db_meta'', ' +
    '''zs_db_jobs'')');
  try
    for i := 0 to R.RowCount - 1 do
      if not SameText(R.Str(i, 1), 'InnoDB') then
        raise EMyError.CreateCode(0, Format('the table %s uses the engine %s, the shared database needs InnoDB ' +
          '(ALTER TABLE %s ENGINE = InnoDB)', [R.Str(i, 0), R.Str(i, 1), R.Str(i, 0)]));
  finally
    R.Free;
  end;
  C.Exec('INSERT IGNORE INTO zs_db_meta (name, value) VALUES (''seq'', 0), (''next_account'', 1), (''next_map'', 1)');
end;

function MetaValue(C: TMyConnection; const Name: AnsiString; Lock: Boolean): Int64;
var
  R: TMyResult;
  Q: AnsiString;
begin
  Q := 'SELECT value FROM zs_db_meta WHERE name = ' + MyStr(Name);
  if Lock then
    Q := Q + ' FOR UPDATE';
  R := C.Query(Q);
  try
    if R.RowCount > 0 then
      Result := R.Int(0, 0)
    else
      Result := -1;
  finally
    R.Free;
  end;
end;

{ The first time: this server's data goes into the shared database. An account of the same
  SteamID, or without Steam of the same computer, gets this server's numbers added - unless both
  have a password - and every other one comes in with a number of the database; the first server
  keeps its own numbers. Tried: this server was not in the database yet, so the join was begun
  (whether it went in or not, the numbers of the files are not the database's any more). }
function JoinDatabase(E: TZSEngine; C: TMyConnection; out Note: AnsiString; out Tried: Boolean): Boolean;
var
  R: TMyResult;
  BySteam, ByHwid, Taken: TStringList;
  k, i, Id, Added, Merged, NextId, MaxId: LongInt;
  Key: AnsiString;
  Empty: Boolean;
  P: PPlayerProfile;
  Cur, Base, Remote: TPlayerProfile;
  MC, MB, MR: TMapProfile;
  SC, SB, SR: TServerRecords;
  Seq, TopId: Int64;
  Stamp, Sid, SeqText, Data, Line: AnsiString;
  Version: Int64;
  Rows: TMyBatch;
begin
  Result := False;
  Tried := False;
  Note := '';
  Added := 0;
  Merged := 0;
  Stamp := MyDate(Now);
  Sid := MyInt(E.Cfg.MySQLServerID);
  BySteam := TStringList.Create;
  ByHwid := TStringList.Create;
  Taken := TStringList.Create;
  C.Exec('START TRANSACTION');
  try
    Seq := MetaValue(C, 'seq', True);
    if Seq < 0 then
      raise EMyError.CreateCode(0, 'the row seq of zs_db_meta is missing');
    Inc(Seq);
    SeqText := MyInt(Seq);
    if MetaValue(C, 'joined_' + IntToStr(E.Cfg.MySQLServerID), False) >= 0 then
    begin
      C.Exec('ROLLBACK');
      BySteam.Free;
      ByHwid.Free;
      Taken.Free;
      Exit(True);
    end;
    Tried := True;
    BySteam.Sorted := True;
    BySteam.Duplicates := dupIgnore;
    ByHwid.Sorted := True;
    ByHwid.Duplicates := dupIgnore;
    Taken.Sorted := True;
    Taken.Duplicates := dupIgnore;
    { every row, the removed ones too: no number a row has is handed out again (the write would
      take that row over), and of two rows of one SteamID or computer the lower number is the
      account, as in SameAccount }
    R := C.Query('SELECT id, steam, hwid_key, deleted FROM zs_db_accounts ORDER BY id');
    try
      Empty := R.RowCount = 0;
      TopId := 0;
      for i := 0 to R.RowCount - 1 do
      begin
        if R.Int(i, 0) > TopId then
          TopId := R.Int(i, 0);
        if R.Int(i, 3) <> 0 then
          Continue;
        if not R.IsNull(i, 1) and (R.Str(i, 1) <> '') then
          BySteam.AddObject(R.Str(i, 1), TObject(PtrInt(R.Int(i, 0))))
        else if not R.IsNull(i, 2) and (R.Str(i, 2) <> '') then
          ByHwid.AddObject(R.Str(i, 2), TObject(PtrInt(R.Int(i, 0))));
      end;
    finally
      R.Free;
    end;
    NextId := LongInt(Max(MetaValue(C, 'next_account', True), TopId + 1));
    MaxId := 0;
    Rows := TMyBatch.Create(C, 'INSERT INTO zs_db_accounts (id, steam, hwid_key, name, points, kills, deaths, ' +
      'playtime_sec, last_seen, data, version, seq, deleted, merged_into, updated_by, updated_at) VALUES',
      'ON DUPLICATE KEY UPDATE steam = VALUES(steam), hwid_key = VALUES(hwid_key), name = VALUES(name), points = VALUES(points), ' +
      'kills = VALUES(kills), deaths = VALUES(deaths), playtime_sec = VALUES(playtime_sec), last_seen = VALUES(last_seen), ' +
      'data = VALUES(data), version = VALUES(version), seq = VALUES(seq), deleted = 0, merged_into = 0, ' +
      'updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)', 1024 * 1024);
    try
      DecodeP(FreshProfile(E), Base);
      for k := 0 to E.DB.ProfileCount - 1 do
      begin
        if not E.DB.Valid(k) then
          Continue;
        P := E.DB.Profiles[k];
        Id := 0;
        if IsRealSteam(P^.ActiveSteam) then
        begin
          i := BySteam.IndexOf(P^.ActiveSteam);
          if i >= 0 then
            Id := PtrInt(BySteam.Objects[i]);
        end
        else
        begin
          Key := HwidKey(P^);
          i := -1;
          if Key <> '' then
            i := ByHwid.IndexOf(Key);
          if i >= 0 then
            Id := PtrInt(ByHwid.Objects[i]);
        end;
        { one account of the database takes one account of this server }
        if (Id > 0) and (Taken.IndexOf(IntToStr(Id)) >= 0) then
          Id := 0;
        Cur := P^;
        Version := 0;
        if Id > 0 then
        begin
          R := C.Query('SELECT version, data FROM zs_db_accounts WHERE id = ' + MyInt(Id) + ' FOR UPDATE');
          try
            if R.RowCount > 0 then
            begin
              Version := R.Int(0, 0);
              Data := R.Str(0, 1);
            end
            else
              Data := '';
          finally
            R.Free;
          end;
          if (Data <> '') and DecodeP(Data, Remote) then
          begin
            { two accounts of one computer that both have a password: two owners, they stay apart }
            if not IsRealSteam(P^.ActiveSteam) and (P^.PassHash <> '') and (Remote.PassHash <> '') then
            begin
              Id := 0;
              Version := 0;
            end
            else
            begin
              UniqueProfileLists(Cur);
              Merge3Profile(Cur, Base, Remote);
            end;
          end;
          if Id > 0 then
          begin
            Taken.Add(IntToStr(Id));
            Inc(Merged);
          end;
        end;
        if Id <= 0 then
        begin
          { the first server keeps its numbers; the others get new ones }
          if Empty then
            Id := P^.ID
          else
          begin
            Id := NextId;
            Inc(NextId);
          end;
          Inc(Added);
        end;
        if Id > MaxId then
          MaxId := Id;
        Cur.ID := Id;
        Data := EncodeProfile(Cur);
        Line := '(' + MyInt(Id) + ', ' + SteamValue(Cur.ActiveSteam) + ', ' + KeyValue(HwidKey(Cur));
        Rows.Add(Line + ', ' + MyStrMax(CodepageToUtf8(Cur.ActiveName, E.Cfg.SourceCodepage), 64) + ', ' +
          MyInt(Cur.Points) + ', ' + MyInt(Cur.Kills) + ', ' + MyInt(Cur.Deaths) + ', ' + MyInt(Cur.TimePlayed) + ', ' +
          MyDate(Cur.LastPlayedTime) + ', ' + MyBin(Data) + ', ' + MyInt(Version + 1) + ', ' + SeqText + ', 0, 0, ' + Sid +
          ', ' + Stamp + ')');
      end;
      Rows.Flush;
    finally
      Rows.Free;
    end;
    if MaxId >= NextId then
      NextId := MaxId + 1;
    C.Exec('UPDATE zs_db_meta SET value = ' + MyInt(NextId) + ' WHERE name = ''next_account''');

    { the maps, by name }
    ClearMap(MB);
    for k := 0 to E.DB.MapCount - 1 do
    begin
      MC := E.DB.Maps[k];
      MC.Heat := Copy(MC.Heat);
      R := C.Query('SELECT id, version, data FROM zs_db_maps WHERE name = ' +
        MyStrMax(CodepageToUtf8(MC.MapName, E.Cfg.SourceCodepage), 64) + ' FOR UPDATE');
      try
        if R.RowCount > 0 then
        begin
          Id := R.Int(0, 0);
          Version := R.Int(0, 1);
          Data := R.Str(0, 2);
        end
        else
        begin
          Id := 0;
          Version := 0;
          Data := '';
        end;
      finally
        R.Free;
      end;
      if (Data <> '') and DecodeM(Data, MR) then
        Merge3Map(MC, MB, MR);
      if Id <= 0 then
      begin
        Id := MetaValue(C, 'next_map', True);
        C.Exec('UPDATE zs_db_meta SET value = value + 1 WHERE name = ''next_map''');
      end;
      MC.ID := Id;
      C.Exec('INSERT INTO zs_db_maps (name, id, plays, kills, playtime_sec, data, version, seq, updated_by, updated_at) VALUES (' +
        MyStrMax(CodepageToUtf8(MC.MapName, E.Cfg.SourceCodepage), 64) + ', ' + MyInt(Id) + ', ' + MyInt(MC.ActiveMapPlays) + ', ' +
        MyInt(MC.Kills) + ', ' + MyInt(MC.ActiveTimePlays) + ', ' + MyBin(EncodeMap(MC)) + ', ' + MyInt(Version + 1) + ', ' +
        SeqText + ', ' + Sid + ', ' + Stamp + ') ON DUPLICATE KEY UPDATE id = VALUES(id), plays = VALUES(plays), ' +
        'kills = VALUES(kills), playtime_sec = VALUES(playtime_sec), data = VALUES(data), version = VALUES(version), ' +
        'seq = VALUES(seq), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)');
    end;

    { the server record }
    SC := E.DB.Server;
    SC.Daily := Copy(SC.Daily);
    ClearServer(SB);
    R := C.Query('SELECT version, data FROM zs_db_server WHERE id = 1 FOR UPDATE');
    try
      if R.RowCount > 0 then
      begin
        Version := R.Int(0, 0);
        Data := R.Str(0, 1);
      end
      else
      begin
        Version := 0;
        Data := '';
      end;
    finally
      R.Free;
    end;
    if (Data <> '') and DecodeS(Data, SR) then
      Merge3Server(SC, SB, SR);
    C.Exec('INSERT INTO zs_db_server (id, data, version, seq, updated_by, updated_at) VALUES (1, ' + MyBin(EncodeServer(SC)) + ', ' +
      MyInt(Version + 1) + ', ' + SeqText + ', ' + Sid + ', ' + Stamp + ') ON DUPLICATE KEY UPDATE data = VALUES(data), ' +
      'version = VALUES(version), seq = VALUES(seq), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)');

    { the season archives it has and the database does not }
    for k := 0 to High(E.DB.Seasons) do
      C.Exec('INSERT IGNORE INTO zs_db_seasons (id, data, seq, updated_by, updated_at) VALUES (' + MyInt(E.DB.Seasons[k].Id) +
        ', ' + MyBin(EncodeSeason(E.DB.Seasons[k])) + ', ' + SeqText + ', ' + Sid + ', ' + Stamp + ')');

    C.Exec('INSERT INTO zs_db_meta (name, value) VALUES (' + MyStr('joined_' + IntToStr(E.Cfg.MySQLServerID)) + ', ' +
      MyInt(DateTimeToUnix(Now)) + ') ON DUPLICATE KEY UPDATE value = VALUES(value)');
    C.Exec('UPDATE zs_db_meta SET value = ' + SeqText + ' WHERE name = ''seq''');
    C.Exec('COMMIT');
    Note := Format('this server joined: %d accounts added, %d joined to accounts of other servers', [Added, Merged]);
    Result := True;
  except
    on Ex: Exception do
    begin
      try
        C.Exec('ROLLBACK');
      except
      end;
      Note := 'joining failed: ' + Ex.Message;
    end;
  end;
  BySteam.Free;
  ByHwid.Free;
  Taken.Free;
end;

{ everything of the shared database, read in one consistent view }
function LoadDatabase(E: TZSEngine; C: TMyConnection; out St: TStoreState; out Seq: Int64; out Note: AnsiString): Boolean;
var
  Cur: TMyCursor;
  P: PPlayerProfile;
  n, m: LongInt;
  A: TSeasonArchive;
begin
  Result := False;
  ClearStoreState(St);
  n := 0;
  m := 0;
  C.Exec('START TRANSACTION WITH CONSISTENT SNAPSHOT');
  try
    Seq := MetaValue(C, 'seq', False);
    Cur := C.Open('SELECT id, version, data FROM zs_db_accounts WHERE deleted = 0 AND data IS NOT NULL');
    try
      while Cur.Next do
      begin
        P := NewProfile;
        if not DecodeP(Cur.Str(2), P^) then
        begin
          FreeProfile(P);
          Continue;
        end;
        P^.ID := Cur.Int(0);
        P^.SyncBase := Cur.Str(2);
        P^.SyncVersion := Cur.Int(1);
        if n >= Length(St.Profiles) then
          SetLength(St.Profiles, n * 2 + 1024);
        St.Profiles[n] := P;
        Inc(n);
      end;
    finally
      Cur.Free;
    end;
    St.ProfileCount := n;
    SetLength(St.Profiles, n);
    Cur := C.Open('SELECT name, id, version, data FROM zs_db_maps WHERE data IS NOT NULL');
    try
      while Cur.Next do
      begin
        if m >= Length(St.Maps) then
          SetLength(St.Maps, m * 2 + 32);
        if not DecodeM(Cur.Str(3), St.Maps[m]) then
          Continue;
        St.Maps[m].MapName := Utf8ToCodepage(Cur.Str(0), E.Cfg.SourceCodepage);
        St.Maps[m].ID := Cur.Int(1);
        St.Maps[m].SyncBase := Cur.Str(3);
        St.Maps[m].SyncVersion := Cur.Int(2);
        Inc(m);
      end;
    finally
      Cur.Free;
    end;
    St.MapCount := m;
    SetLength(St.Maps, m);
    Cur := C.Open('SELECT version, data FROM zs_db_server WHERE id = 1');
    try
      if Cur.Next then
      begin
        DecodeS(Cur.Str(1), St.Server);
        St.Server.SyncBase := Cur.Str(1);
        St.Server.SyncVersion := Cur.Int(0);
      end;
    finally
      Cur.Free;
    end;
    Cur := C.Open('SELECT data FROM zs_db_seasons ORDER BY id');
    try
      while Cur.Next do
        if DecodeSeason(Cur.Str(0), A) then
        begin
          SetLength(St.Seasons, Length(St.Seasons) + 1);
          St.Seasons[High(St.Seasons)] := A;
        end;
    finally
      Cur.Free;
    end;
    C.Exec('COMMIT');
    Note := Format('%d accounts, %d maps', [n, m]);
    Result := True;
  except
    on Ex: Exception do
    begin
      try
        C.Exec('ROLLBACK');
      except
      end;
      ClearStoreState(St);
      Note := 'reading failed: ' + Ex.Message;
    end;
  end;
end;

procedure StartExchange(E: TZSEngine; St: TSqlState);
begin
  St.Fresh := FreshProfile(E);
  E.DB.NextProfileIdHook := @St.NextProfileId;
  E.DB.SyncOn := St.Blocked = '';
  if St.Thread = nil then
    St.Thread := TSqlThread.Create(E);
  St.LastCycleMs := MonoMs;
end;

{ at a start with the database: what waited beside the files goes in before the database is
  read, on the thread of the exchange, waiting half a minute at most }
function PushPending(E: TZSEngine; St: TSqlState; const Pend: TPending; out Why: AnsiString): Boolean;
var
  R: TSyncResult;
  T0: Int64;
  Got: Boolean;
begin
  Result := False;
  Why := '';
  StartExchange(E, St);
  ApplyPending(E, Pend);
  { nothing comes back: the whole database is read after this, so everything goes in at once }
  St.PullSeq := High(Int64);
  SubmitBatch(E, St, True);
  T0 := MonoMs;
  Got := False;
  while MonoMs - T0 < 30000 do
  begin
    if St.Thread.TakeResult(R) then
    begin
      Got := True;
      Break;
    end;
    SysUtils.Sleep(20);
  end;
  if not Got then
  begin
    { the answer comes with a later tick }
    St.PullSeq := 0;
    Why := 'the database did not answer in time';
    Exit;
  end;
  St.Busy := False;
  ApplyResult(E, St, R);
  St.PullSeq := 0;
  Result := R.Ok;
  if not Result then
    Why := R.Error;
end;

function SqlStart(E: TZSEngine): Boolean;
var
  St: TSqlState;
  C: TMyConnection;
  S: TStoreState;
  Seq: Int64;
  Note, JoinNote, Why: AnsiString;
  k: LongInt;
  Pend: TPending;
  HavePend, JoinTried, JoinOk: Boolean;
begin
  Result := False;
  JoinTried := False;
  JoinOk := False;
  St := TSqlState.Create(E);
  E.SqlState := St;
  St.CfgKey := SqlKey(E);
  HavePend := ReadPending(E, Pend);
  St.PendingOnDisk := HavePend;
  C := TMyConnection.Create;
  try
    C.Host := E.Cfg.MySQLHost;
    C.Port := E.Cfg.MySQLPort;
    C.Database := E.Cfg.MySQLDatabase;
    C.User := E.Cfg.MySQLUser;
    C.Password := E.Cfg.MySQLPassword;
    try
      C.Connect;
      PrepareTables(C);
      JoinOk := JoinDatabase(E, C, JoinNote, JoinTried);
      if not JoinOk then
        raise Exception.Create(JoinNote);
      { a server that was in the database before: the numbers of its files are the database's }
      St.Joined := not JoinTried;
      { a server that has just joined brought everything along; one that was here before sends what
        it collected while the database could not be reached }
      if JoinNote <> '' then
        HavePend := False
      else if HavePend then
      begin
        if not PushPending(E, St, Pend, Why) then
          raise Exception.Create(Why);
        HavePend := False;
        E.WriteServer(Format('[ZitroStats] shared database: %d accounts collected without it went in',
          [Length(Pend.Accounts)]));
      end;
      if not LoadDatabase(E, C, S, Seq, Note) then
        raise Exception.Create(Note);
      { a block of account numbers for this server }
      C.Exec('START TRANSACTION');
      St.IdNext := TakeAccountIds(C, ID_BLOCK);
      C.Exec('COMMIT');
      St.IdEnd := St.IdNext + ID_BLOCK;
      E.DB.TakeState(S);
      St.Joined := True;
      St.PullSeq := Seq;
      if St.PendingOnDisk or FileExists(PendingPath(E)) then
        WritePending(E, St);
      St.Online := True;
      St.EverOnline := True;
      St.LastOkMs := MonoMs;
      if JoinNote <> '' then
        E.WriteServer('[ZitroStats] shared database: ' + JoinNote);
      E.WriteServer(Format('[ZitroStats] shared database %s:%d/%s (%s): %s read, the exchange runs every %d s',
        [E.Cfg.MySQLHost, E.Cfg.MySQLPort, E.Cfg.MySQLDatabase, C.ServerVersion, Note, E.Cfg.MySQLSyncSeconds]));
      Result := True;
    except
      on Ex: Exception do
      begin
        St.LastError := Ex.Message;
        St.Online := False;
        if JoinTried and JoinOk then
          { the join went in, the rest of the start did not: the files still hold the numbers of
            before the join }
          Block(E, St, 'joined, but reading it failed', 'this server joined the database, but reading it back ' +
            'failed (' + Ex.Message + '), so nothing is exchanged until it is started again while the database ' +
            'answers - what it collects until then does not reach the database')
        else if JoinTried then
          { this server was not in the database: its files have no numbers of the database }
          Block(E, St, 'joining it failed', 'joining the database failed (' + Ex.Message + '), so nothing is ' +
            'exchanged until the server is started again while the database answers - that start joins it with ' +
            'everything its files hold')
        else
        begin
          E.WriteServer('[ZitroStats] shared database: ' + Ex.Message + ' - started from the files, the exchange starts ' +
            'once the database answers');
          { what the files hold counts as known to the database: only what changes from now on goes in
            (by the numbers of the files - the first exchange makes sure this server joined before) }
          for k := 0 to E.DB.ProfileCount - 1 do
            if E.DB.Valid(k) then
              E.DB.Profiles[k]^.SyncBase := EncodeProfile(E.DB.Profiles[k]^);
          for k := 0 to E.DB.MapCount - 1 do
            E.DB.Maps[k].SyncBase := EncodeMap(E.DB.Maps[k]);
          E.DB.Server.SyncBase := EncodeServer(E.DB.Server);
          { but what waited beside the files still has to go in, from the state before it }
          if HavePend then
          begin
            StartExchange(E, St);
            ApplyPending(E, Pend);
          end;
        end;
      end;
    end;
  finally
    try
      C.Close;
    except
    end;
    WipeString(C.Password);
    C.Free;
  end;
  StartExchange(E, St);
end;

procedure SqlTick(E: TZSEngine; NowMs: Int64);
var
  St: TSqlState;
  R: TSyncResult;
  Wait: Int64;
begin
  St := State(E);
  if (St = nil) or (St.Thread = nil) or (St.Blocked <> '') then
    Exit;
  if St.Busy then
  begin
    if not St.Thread.TakeResult(R) then
      Exit;
    St.Busy := False;
    ApplyResult(E, St, R);
    if St.Blocked <> '' then
      Exit;
  end;
  { while the database does not answer the pause doubles after every failed exchange, up to half a
    minute: every exchange encodes every record that waits for it }
  Wait := Int64(Max(1, E.Cfg.MySQLSyncSeconds)) * 1000;
  if St.Fails > 0 then
    Wait := Max(Wait, Min(Int64(30000), Wait shl Min(St.Fails, 5)));
  if NowMs - St.LastCycleMs < Wait then
    Exit;
  St.LastCycleMs := NowMs;
  { a reload of settings.ini does not move the running exchange to other settings }
  if not St.CfgWarned and (SqlKey(E) <> St.CfgKey) then
  begin
    St.CfgWarned := True;
    E.WriteServer('[ZitroStats] shared database: the [MySQL] settings changed - they are used from the next start ' +
      'of the server on');
  end;
  SubmitBatch(E, St);
end;

procedure SqlShutdown(E: TZSEngine);
var
  St: TSqlState;
  R: TSyncResult;
  T0: Int64;
  Got: Boolean;
begin
  St := State(E);
  if St = nil then
    Exit;
  if St.Thread <> nil then
  begin
    { the answer of a running exchange, then what is left (PUSH_CHUNK accounts at most, the rest
      waits beside the files), a few seconds at most each }
    T0 := MonoMs;
    while St.Busy and (MonoMs - T0 < 5000) do
      if St.Thread.TakeResult(R) then
      begin
        St.Busy := False;
        ApplyResult(E, St, R);
      end
      else
        SysUtils.Sleep(20);
    if not St.Busy and St.Online then
    begin
      SubmitBatch(E, St);
      T0 := MonoMs;
      while St.Busy and (MonoMs - T0 < 5000) do
        if St.Thread.TakeResult(R) then
        begin
          St.Busy := False;
          ApplyResult(E, St, R);
        end
        else
          SysUtils.Sleep(20);
    end;
  end;
  { what could not go in waits beside the files for the next start. A batch still on its way is
    cut, and then it is known whether it went in (applied), did not (kept), or may have - its
    COMMIT was sent and not answered: that one is left out rather than sent twice. }
  if St.Thread <> nil then
  begin
    if St.Busy then
    begin
      { waited for once and freed here: a second wait for the same thread (TSqlState.Destroy) is
        not allowed on Linux }
      St.Thread.StopAndWait;
      Got := St.Thread.TakeResult(R);
      FreeAndNil(St.Thread);
      St.Busy := False;
      if not Got then
        { the thread stopped before it began the batch: nothing of it was sent }
        Requeue(E, St)
      else if R.Ok or not R.CommitUnsure then
        ApplyResult(E, St, R);
      St.InFlight.Clear;
    end;
    WritePending(E, St);
  end;
  E.DB.SyncOn := False;
  E.DB.NextProfileIdHook := nil;
  E.SqlState := nil;
  St.Free;
end;

function SqlJob(E: TZSEngine; const Name: AnsiString; Key: LongInt): Boolean;
var
  St: TSqlState;
  k: LongInt;
  Id: AnsiString;
begin
  St := State(E);
  if St = nil then
    Exit(True);
  Id := Name + '|' + IntToStr(Key);
  k := St.Jobs.IndexOf(Id);
  if k < 0 then
  begin
    St.Jobs.AddObject(Id, TObject(PtrInt(0)));
    Exit(False);
  end;
  Result := PtrInt(St.Jobs.Objects[k]) = 1;
  if Result then
    St.Jobs.Delete(k);
end;

function SqlStatusText(E: TZSEngine): AnsiString;
var
  St: TSqlState;
begin
  St := State(E);
  if St = nil then
    Exit('');
  if St.Blocked <> '' then
    Result := 'shared database: off until the next start - ' + St.Blocked
  else if St.Online then
    Result := Format('shared database: connected, %d exchanges, %d changes written, %d read, last %d s ago',
      [St.Cycles, St.Pushed, St.Pulled, (MonoMs - St.LastOkMs) div 1000])
  else if St.EverOnline then
    Result := 'shared database: not answering (' + St.LastError + '), the changes wait'
  else
    Result := 'shared database: not reached yet (' + St.LastError + '), working from the files';
end;

end.
