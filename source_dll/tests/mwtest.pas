program mwtest;

{ Tests of mysqlwire: the pieces on their own, RSA against openssl, and the whole client
  against real servers.
    mwtest unit
    mwtest rsa <public key file> <message> <cipher out>
    mwtest live <port> [mariadb]

  "live" runs against a server of its own on 127.0.0.1, never one with data that matters: it logs
  in as root without a password, sets the passwords of its test users again and creates and drops
  tables in the database wiretest. It expects these users, all with access to wiretest:
    MySQL:   sha2user 'Tst-pa55!#q', longpw (the long password in the code) and emptyuser ''
             (caching_sha2_password), nativeuser 'Nat1ve-pw' (mysql_native_password),
             sha256user 'Sha256-pw' (sha256_password)
    MariaDB: nativeuser 'Nat1ve-pw'
  Such a server is started from the MySQL or MariaDB binaries with --no-defaults, a --datadir and
  a port of its own, and stopped with SHUTDOWN afterwards.
  Built from source_dll: fpc -Mobjfpc -Sh -O2 -Fu. -FUbuild\test -FEbuild\test tests\mwtest.pas }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils, sockets, mysqlwire;

var
  Fails, Checks: LongInt;

procedure Check(const What: AnsiString; Ok: Boolean);
begin
  Inc(Checks);
  if Ok then
    WriteLn('[ OK ] ', What)
  else
  begin
    WriteLn('[FAIL] ', What);
    Inc(Fails);
  end;
end;

function Hex(const S: AnsiString): AnsiString;
var
  i: LongInt;
begin
  Result := '';
  for i := 1 to Length(S) do
    Result := Result + LowerCase(IntToHex(Byte(S[i]), 2));
end;

function ReadFileText(const Path: AnsiString): AnsiString;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

procedure WriteFileText(const Path, Data: AnsiString);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Data <> '' then
      F.WriteBuffer(Data[1], Length(Data));
  finally
    F.Free;
  end;
end;

procedure UnitTests;
var
  i, cp: LongInt;
  All, Back: AnsiString;
  Ok: Boolean;
begin
  Check('sha256 empty', Hex(MySha256('')) = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  Check('sha256 abc', Hex(MySha256('abc')) = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  Check('sha256 two blocks', Hex(MySha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')) =
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  Check('sha256 55/56/64 bytes', (Length(MySha256(StringOfChar('a', 55))) = 32) and
    (Hex(MySha256(StringOfChar('a', 64))) = 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb'));
  Check('sha1 abc', Hex(MySha1('abc')) = 'a9993e364706816aba3e25717850c26c9cd0d89d');
  Check('native scramble is 20 bytes', Length(MyScrambleNative('pw', StringOfChar('x', 20))) = 20);
  Check('sha2 scramble is 32 bytes', Length(MyScrambleSha2('pw', StringOfChar('x', 20))) = 32);
  Check('empty password sends nothing', (MyScrambleNative('', 'n') = '') and (MyScrambleSha2('', 'n') = ''));

  { every byte of the code pages survives the way to UTF-8 and back }
  SetLength(All, 255);
  for i := 1 to 255 do
    All[i] := AnsiChar(i);
  for cp := 0 to 2 do
  begin
    case cp of
      0: i := 1250;
      1: i := 1252;
    else
      i := 28591;
    end;
    Back := Utf8ToCodepage(CodepageToUtf8(All, i), i);
    Check(Format('code page %d round trip', [i]), Back = All);
    Check(Format('code page %d gives valid UTF-8', [i]), CleanUtf8(CodepageToUtf8(All, i)) = CodepageToUtf8(All, i));
  end;
  Check('1250: l with stroke', CodepageToUtf8(#$B3, 1250) = #$C5#$82);
  Check('1250 back', Utf8ToCodepage(#$C5#$82#$C4#$85, 1250) = #$B3#$B9);
  Check('broken UTF-8 becomes ?', CleanUtf8('a'#$C5'b'#$FF#$E2#$82) = 'a?b???');
  { from the database back to a code page: a broken sequence is "?" and swallows nothing }
  Check('a cut sequence at the end becomes ?', Utf8ToCodepage('abc'#$C5, 1250) = 'abc?');
  Check('a lead byte before a plain letter keeps the letter', Utf8ToCodepage(#$C5'A', 1250) = '?A');
  Check('a lone continuation byte becomes ?', Utf8ToCodepage(#$80'x'#$BF, 1250) = '?x?');
  Check('valid UTF-8 stays', CleanUtf8('za'#$C5#$BC#$C3#$B3#$C5#$82#$C4#$87' '#$F0#$9F#$98#$80) =
    'za'#$C5#$BC#$C3#$B3#$C5#$82#$C4#$87' '#$F0#$9F#$98#$80);
  Check('overlong form refused', CleanUtf8(#$C0#$AF) = '??');
  Check('Utf8Left counts characters', Utf8Left('a'#$C5#$82'bc', 2) = 'a'#$C5#$82);
  Check('MyStr hex literal', MyStr('a''b') = '_utf8mb4 X''612762''');
  Check('MyStr empty', MyStr('') = '''''');
  Check('MyDate null', (MyDate(0) = 'NULL') and (MyDate(-5) = 'NULL'));
  Check('MyDate text', MyDate(EncodeDateTime(2026, 9, 21, 13, 5, 9, 0)) = '''2026-09-21 13:05:09''');
  Check('MyFloat dot', (MyFloat(1.5) = '1.5') and (MyFloat(-0.25) = '-0.25'));
  Ok := True;
  try
    MyRsaEncrypt('-----BEGIN PUBLIC KEY-----'#10'bm90IGEga2V5'#10'-----END PUBLIC KEY-----', 'x');
    Ok := False;
  except
    on E: EMyError do ;
  end;
  Check('a key that is not one is refused', Ok);
end;

{ ---------------- a database server of a few lines, for the offline tests ---------------- }

type
  { greets, takes any login and SET NAMES, then gives the last word MySQL gives a client it
    closes (error 4031): the first connection gets it at once, while it is idle, the second one
    as the answer to its next statement; both are closed after it }
  TFakeServer = class(TThread)
  private
    FListen: LongInt;
  protected
    procedure Execute; override;
  public
    Port: Word;
    Ready: Boolean;
    constructor Create;
    procedure Cut;
  end;

function WirePacket(Seq: Byte; const Payload: AnsiString): AnsiString;
var
  L: LongInt;
begin
  L := Length(Payload);
  Result := AnsiChar(L and $FF) + AnsiChar((L shr 8) and $FF) + AnsiChar((L shr 16) and $FF) + AnsiChar(Seq) + Payload;
end;

function RecvAll(S: LongInt; P: PByte; Count: LongInt): Boolean;
var
  Got: LongInt;
begin
  while Count > 0 do
  begin
    Got := fpRecv(S, P, Count, 0);
    if Got <= 0 then
      Exit(False);
    Inc(P, Got);
    Dec(Count, Got);
  end;
  Result := True;
end;

{ one packet of the client, read and thrown away }
function RecvPacket(S: LongInt): Boolean;
var
  Hd: array[0..3] of Byte;
  Buf: array[0..4095] of Byte;
  L, n: LongInt;
begin
  Result := RecvAll(S, @Hd[0], 4);
  if not Result then
    Exit;
  L := Hd[0] or (Hd[1] shl 8) or (Hd[2] shl 16);
  while L > 0 do
  begin
    n := L;
    if n > SizeOf(Buf) then
      n := SizeOf(Buf);
    if not RecvAll(S, @Buf[0], n) then
      Exit(False);
    Dec(L, n);
  end;
end;

procedure SendText(S: LongInt; const Data: AnsiString);
begin
  if Data <> '' then
    fpSend(S, @Data[1], Length(Data), 0);
end;

constructor TFakeServer.Create;
var
  A: TInetSockAddr;
  Len: TSockLen;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := 0;
  A.sin_addr := StrToNetAddr('127.0.0.1');
  Ready := (FListen >= 0) and (fpBind(FListen, @A, SizeOf(A)) = 0) and (fpListen(FListen, 4) = 0);
  Len := SizeOf(A);
  if Ready and (fpGetSockName(FListen, @A, @Len) = 0) then
    Port := NToHs(A.sin_port)
  else
    Ready := False;
end;

procedure TFakeServer.Execute;
const
  { long password, with a database, 4.1, transactions, secure connection; plugin auth }
  CAPS_LOW = #$09#$A2;
  CAPS_HIGH = #$08#$00;
var
  C, n: LongInt;
  Ok, Bye: AnsiString;
begin
  Ok := #0#0#0#2#0#0#0;
  Bye := #$FF#$BF#$0F'#HY000The client was disconnected by the server because of inactivity.';
  for n := 1 to 2 do
  begin
    C := fpAccept(FListen, nil, nil);
    if C < 0 then
      Exit;
    SendText(C, WirePacket(0, #10'8.0.99-fake'#0#7#0#0#0'12345678'#0 + CAPS_LOW + #45#2#0 + CAPS_HIGH + #21 +
      StringOfChar(#0, 10) + 'abcdefghijkl'#0'mysql_native_password'#0));
    if RecvPacket(C) then
    begin
      SendText(C, WirePacket(2, Ok));
      if RecvPacket(C) then
      begin
        SendText(C, WirePacket(1, Ok));
        if n = 2 then
          RecvPacket(C);
        SendText(C, WirePacket(1, Bye));
      end;
    end;
    CloseSocket(C);
  end;
end;

{ ends a wait for a connection that does not come }
procedure TFakeServer.Cut;
begin
  fpShutdown(FListen, 2);
  CloseSocket(FListen);
end;

procedure FakeServerTests;
var
  F: TFakeServer;
  C: TMyConnection;
  Code: LongInt;
  Ok: Boolean;
  Msg: AnsiString;

  function NewFakeConn: TMyConnection;
  begin
    Result := TMyConnection.Create;
    Result.Host := '127.0.0.1';
    Result.Port := F.Port;
    Result.User := 'u';
    Result.Password := 'p';
    Result.ConnectTimeoutMs := 3000;
    Result.IOTimeoutMs := 3000;
  end;

begin
  F := TFakeServer.Create;
  try
    Check('a fake database server listens on 127.0.0.1', F.Ready);
    if not F.Ready then
      Exit;
    F.Start;
    C := NewFakeConn;
    try
      Ok := True;
      Msg := '';
      try
        C.Connect;
      except
        on E: Exception do
        begin
          Ok := False;
          Msg := E.Message;
        end;
      end;
      Check('the fake server takes the login', Ok and C.Connected);
      if Msg <> '' then
        WriteLn('       ', Msg);
      Sleep(300);
      Check('an idle connection the server ended is not used again', not C.Usable and not C.Connected);
    finally
      C.Free;
    end;
    C := NewFakeConn;
    try
      Code := -1;
      try
        C.Connect;
        C.Exec('SELECT 1');
      except
        on E: EMyError do
          Code := E.Code;
      end;
      Check('the last word of the server closes the connection', (Code = 4031) and not C.Connected);
    finally
      C.Free;
    end;
  finally
    F.Cut;
    F.WaitFor;
    F.Free;
  end;
end;

procedure RsaCase(const PubFile, Msg, OutFile: AnsiString);
begin
  WriteFileText(OutFile, MyRsaEncrypt(ReadFileText(PubFile), Msg));
end;

function NewConn(Port: LongInt; const User, Pw: AnsiString): TMyConnection;
begin
  Result := TMyConnection.Create;
  Result.Host := '127.0.0.1';
  Result.Port := Port;
  Result.User := User;
  Result.Password := Pw;
  Result.Database := 'wiretest';
  Result.ConnectTimeoutMs := 3000;
  Result.IOTimeoutMs := 20000;
end;

function TryLogin(Port: LongInt; const User, Pw: AnsiString; out Msg: AnsiString): Boolean;
var
  C: TMyConnection;
  R: TMyResult;
begin
  Result := False;
  Msg := '';
  C := NewConn(Port, User, Pw);
  try
    try
      C.Connect;
      R := C.Query('SELECT CURRENT_USER() AS u, 1 + 1 AS two');
      try
        Result := (R.RowCount = 1) and (R.Int(0, R.Col('two')) = 2);
        Msg := R.Str(0, 0);
      finally
        R.Free;
      end;
    except
      on E: Exception do
        Msg := E.Message;
    end;
  finally
    C.Free;
  end;
end;

type
  { cuts a connection from another thread after a moment }
  TCutter = class(TThread)
  private
    FConn: TMyConnection;
    FAfter: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(Conn: TMyConnection; AfterMs: LongInt);
  end;

constructor TCutter.Create(Conn: TMyConnection; AfterMs: LongInt);
begin
  inherited Create(True);
  FConn := Conn;
  FAfter := AfterMs;
end;

procedure TCutter.Execute;
begin
  Sleep(FAfter);
  FConn.Abort;
end;

procedure LiveTests(Port: LongInt; MariaDB: Boolean);
var
  C: TMyConnection;
  R: TMyResult;
  Cur: TMyCursor;
  B: TMyBatch;
  Msg, Name, Big: AnsiString;
  i: LongInt;
  T0: QWord;
  Ok: Boolean;
  Cutter: TCutter;
begin
  if not MariaDB then
  begin
    { setting the password again empties the server's cache for that user, so the next login
      has to take the full path (RSA), and the one after it the fast path }
    C := NewConn(Port, 'root', '');
    try
      C.Database := '';
      C.Connect;
      C.Exec('ALTER USER ''sha2user''@''%'' IDENTIFIED WITH caching_sha2_password BY ''Tst-pa55!#q''');
      C.Exec('ALTER USER ''longpw''@''%'' IDENTIFIED WITH caching_sha2_password BY ' +
        '''a-very-long-password-with-many-characters-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ''');
    finally
      C.Free;
    end;
    Check('caching_sha2 full path: ' , TryLogin(Port, 'sha2user', 'Tst-pa55!#q', Msg));
    WriteLn('       ', Msg);
    Check('caching_sha2 fast path', TryLogin(Port, 'sha2user', 'Tst-pa55!#q', Msg));
    Check('caching_sha2 wrong password refused', not TryLogin(Port, 'sha2user', 'wrong', Msg) and (Pos('1045', Msg) > 0));
    WriteLn('       ', Msg);
    Check('caching_sha2 long password', TryLogin(Port, 'longpw',
      'a-very-long-password-with-many-characters-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ', Msg));
    WriteLn('       ', Msg);
    Check('caching_sha2 empty password', TryLogin(Port, 'emptyuser', '', Msg));
    Check('mysql_native_password by a switch', TryLogin(Port, 'nativeuser', 'Nat1ve-pw', Msg));
    WriteLn('       ', Msg);
    Check('mysql_native_password wrong refused', not TryLogin(Port, 'nativeuser', 'nope', Msg));
    Check('sha256_password', TryLogin(Port, 'sha256user', 'Sha256-pw', Msg));
    WriteLn('       ', Msg);
    Check('root without a password', TryLogin(Port, 'root', '', Msg));
  end
  else
  begin
    Check('mariadb native password', TryLogin(Port, 'nativeuser', 'Nat1ve-pw', Msg));
    WriteLn('       ', Msg);
    Check('mariadb wrong password refused', not TryLogin(Port, 'nativeuser', 'nope', Msg));
    WriteLn('       ', Msg);
    Check('mariadb ed25519 is refused with a reason', not TryLogin(Port, 'eduser', 'Ed-pw', Msg) and
      (Pos('ed25519', Msg) > 0));
    WriteLn('       ', Msg);
  end;
  Check('unknown host port refused quickly', not TryLogin(Port + 7, 'x', 'y', Msg) and (Pos('cannot reach', Msg) > 0));
  WriteLn('       ', Msg);

  if MariaDB then
    C := NewConn(Port, 'nativeuser', 'Nat1ve-pw')
  else
    C := NewConn(Port, 'sha2user', 'Tst-pa55!#q');
  try
    C.Connect;
    WriteLn('server: ', C.ServerVersion);
    C.Exec('DROP TABLE IF EXISTS t1');
    C.Exec('CREATE TABLE t1 (id INT PRIMARY KEY, name VARCHAR(64) NULL, n BIGINT NOT NULL, f DOUBLE NULL, ' +
      'd DATETIME NULL) DEFAULT CHARSET=utf8mb4');
    { quotes, backslashes, a NUL, Polish letters from 1250, an emoji }
    Name := CodepageToUtf8('Za'#$BF#$F3#$B3#$E6' '' " \ ; --', 1250) + #0 + 'x' + #$F0#$9F#$98#$80;
    C.Exec('INSERT INTO t1 VALUES (1, ' + MyStr(Name) + ', 9007199254740993, ' + MyFloat(3.25) + ', ' +
      MyDate(EncodeDateTime(2026, 9, 21, 13, 5, 9, 0)) + ')');
    C.Exec('INSERT INTO t1 VALUES (2, NULL, -5, NULL, NULL)');
    Check('affected rows', C.AffectedRows = 1);
    R := C.Query('SELECT id, name, n, f, d FROM t1 ORDER BY id');
    try
      Check('two rows', R.RowCount = 2);
      Check('text comes back byte for byte', R.Str(0, 1) = Name);
      Check('big number', R.Int(0, 2) = 9007199254740993);
      Check('float', Abs(R.Float(0, 3) - 3.25) < 1e-9);
      Check('date', Abs(R.Date(0, 4) - EncodeDateTime(2026, 9, 21, 13, 5, 9, 0)) < 1 / 86400 / 2);
      Check('nulls', R.IsNull(1, 1) and R.IsNull(1, 3) and R.IsNull(1, 4) and not R.IsNull(1, 2) and (R.Int(1, 2) = -5));
      Check('column by name', (R.Col('N') = 2) and (R.Col('nothing') = -1));
    finally
      R.Free;
    end;
    { a statement that fails leaves the connection usable }
    Ok := False;
    try
      C.Exec('INSERT INTO no_such_table VALUES (1)');
    except
      on E: EMyError do
        Ok := E.Code = 1146;
    end;
    Check('error code of a bad statement', Ok);
    Check('the connection still works', C.Ping);

    { many rows in batches }
    T0 := GetTickCount64;
    C.Exec('START TRANSACTION');
    B := TMyBatch.Create(C, 'INSERT INTO t1 (id, name, n) VALUES', 'ON DUPLICATE KEY UPDATE name = VALUES(name), n = VALUES(n)', 65536);
    try
      for i := 10 to 20009 do
        B.Add('(' + MyInt(i) + ', ' + MyStr('player ' + IntToStr(i)) + ', ' + MyInt(i * 3) + ')');
      B.Flush;
      Check('20000 rows written', B.Total = 20000);
    finally
      B.Free;
    end;
    C.Exec('COMMIT');
    WriteLn('       20000 rows in ', GetTickCount64 - T0, ' ms');
    R := C.Query('SELECT COUNT(*) AS c, SUM(n) AS s FROM t1 WHERE id >= 10');
    try
      Check('count and sum after the batch', (R.Int(0, 0) = 20000) and (R.Int(0, 1) = Int64(3) * (10 + 20009) * 20000 div 2));
    finally
      R.Free;
    end;
    T0 := GetTickCount64;
    R := C.Query('SELECT id, name, n FROM t1');
    try
      Check('read 20002 rows', R.RowCount = 20002);
    finally
      R.Free;
    end;
    WriteLn('       read in ', GetTickCount64 - T0, ' ms');

    { the same rows one at a time }
    Cur := C.Open('SELECT id, name, n FROM t1 WHERE id >= 10 ORDER BY id');
    try
      i := 0;
      Ok := True;
      while Cur.Next do
      begin
        if (Cur.Int(Cur.Col('id')) <> i + 10) or (Cur.Str(1) <> 'player ' + IntToStr(i + 10)) or
           (Cur.Int(2) <> (i + 10) * 3) then
          Ok := False;
        Inc(i);
      end;
      Check('cursor reads 20000 rows in order', Ok and (i = 20000));
    finally
      Cur.Free;
    end;
    { a cursor freed half way leaves the connection ready }
    Cur := C.Open('SELECT id FROM t1');
    Cur.Next;
    Cur.Free;
    Check('connection ready after a cursor left early', C.Ping);

    { a table that is already there with fewer columns gets the missing ones }
    C.Exec('DROP TABLE IF EXISTS t3');
    C.Exec('CREATE TABLE t3 (id INT PRIMARY KEY, a INT NOT NULL)');
    C.Exec('INSERT INTO t3 VALUES (1, 5)');
    MyPrepareTable(C, 't3', ['id INT NOT NULL', 'a INT NOT NULL DEFAULT 0', 'b VARCHAR(10) NULL',
      'c BIGINT NOT NULL DEFAULT 7', 'd DATETIME NULL'], 'PRIMARY KEY (id)');
    R := C.Query('SELECT a, b, c, d FROM t3');
    try
      Check('missing columns added to an old table', (R.ColCount = 4) and (R.Int(0, 0) = 5) and R.IsNull(0, 1) and
        (R.Int(0, 2) = 7) and R.IsNull(0, 3));
    finally
      R.Free;
    end;
    C.Exec('DROP TABLE t3');

    { a statement bigger than one packet (16 MB) }
    if not MariaDB then
    begin
      SetLength(Big, 9 * 1024 * 1024);
      for i := 1 to Length(Big) do
        Big[i] := AnsiChar(Ord('a') + i mod 26);
      C.Exec('DROP TABLE IF EXISTS t2');
      C.Exec('CREATE TABLE t2 (id INT PRIMARY KEY, body LONGTEXT) DEFAULT CHARSET=utf8mb4');
      C.Exec('INSERT INTO t2 VALUES (1, ' + MyStr(Big) + ')');
      R := C.Query('SELECT LENGTH(body) AS l, body FROM t2');
      try
        Check('18 MB statement, 9 MB value back', (R.Int(0, 0) = Length(Big)) and (R.Str(0, 1) = Big));
      finally
        R.Free;
      end;
      R := C.Query('SELECT REPEAT(''x'', 20000000) AS r');
      try
        Check('a 20 MB value read across packets', Length(R.Str(0, 0)) = 20000000);
      finally
        R.Free;
      end;
    end;
    C.Exec('DROP TABLE IF EXISTS t1');
    C.Exec('DROP TABLE IF EXISTS t2');
    C.Close;
    Check('closed', not C.Connected);
  finally
    C.Free;
  end;

  { the server shuts down: Abort from another thread ends a statement that waits for the database }
  C := NewConn(Port, 'nativeuser', 'Nat1ve-pw');
  try
    C.Connect;
    Cutter := TCutter.Create(C, 300);
    Cutter.Start;
    T0 := GetTickCount64;
    Ok := False;
    try
      C.Exec('DO SLEEP(5)');
    except
      on E: Exception do
      begin
        Ok := True;
        Msg := E.Message;
      end;
    end;
    Cutter.WaitFor;
    Cutter.Free;
    WriteLn(Format('       cut after %d ms: %s', [GetTickCount64 - T0, Msg]));
    Check('Abort ends a statement that waits for the server', Ok and (GetTickCount64 - T0 < 3000));
    Ok := False;
    try
      C.Connect;
    except
      Ok := True;
    end;
    Check('a connection that was cut does not come back', Ok and not C.Connected);
  finally
    C.Free;
  end;
end;

begin
  Fails := 0;
  Checks := 0;
  if ParamStr(1) = 'unit' then
  begin
    UnitTests;
    FakeServerTests;
  end
  else if ParamStr(1) = 'rsa' then
  begin
    RsaCase(ParamStr(2), ParamStr(3), ParamStr(4));
    Exit;
  end
  else if ParamStr(1) = 'live' then
    LiveTests(StrToIntDef(ParamStr(2), 3306), ParamStr(3) = 'mariadb');
  WriteLn;
  if Fails = 0 then
    WriteLn('ALL ', Checks, ' CHECKS PASSED')
  else
    WriteLn(Fails, ' OF ', Checks, ' CHECKS FAILED');
  if Fails > 0 then
    Halt(1);
end.
