unit mysqlwire;

{ A MySQL and MariaDB client that speaks the network protocol itself.

  A library loaded into the Soldat server can only load libraries of the server's own word
  size, so the usual way - libmysql.dll or libmysqlclient.so next to the server - needs a
  client library built for 32 bits, which is hard to find today. This unit needs none: it
  opens a TCP connection and talks to the database server directly. The database server may
  be 32- or 64-bit, on this machine or on another one; MySQL 5.7, 8.x, 9.x and MariaDB 10.x
  and 11.x all speak the same protocol.

  Covered: the handshake, the password methods the servers use (mysql_native_password,
  caching_sha2_password with its fast and its full path, sha256_password), a server that
  switches the method half way, text queries and their result sets. Not covered: TLS (this
  client never asks for it: a server that demands it refuses the login with an error of its
  own, and a user that must use it gets "access denied"), compression, prepared statements.

  Values go into statements as hex literals (MyStr), so no text a player typed can ever
  change a statement, whatever sql_mode the server runs with.

  One TMyConnection is used by one thread at a time. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils, Classes, Math, sockets, ssockets, sha1, base64;

type
  EMyError = class(Exception)
  public
    Code: LongInt;
    constructor CreateCode(ACode: LongInt; const Msg: AnsiString);
  end;

  TMyRow = array of AnsiString;
  TMyNulls = array of Boolean;
  TMyConnection = class;

  { the rows of a SELECT; the values are text, as the server sent them }
  TMyResult = class
  private
    FColumns: array of AnsiString;
    FRows: array of TMyRow;
    FNulls: array of array of Boolean;
    FCount: LongInt;
    procedure AddRow(const R: TMyRow; const N: array of Boolean);
  public
    function ColCount: LongInt;
    function RowCount: LongInt;
    function ColumnName(C: LongInt): AnsiString;
    { the number of a column by its name, -1 when there is none }
    function Col(const Name: AnsiString): LongInt;
    function Str(Row, C: LongInt): AnsiString;
    function IsNull(Row, C: LongInt): Boolean;
    function Int(Row, C: LongInt): Int64;
    function Float(Row, C: LongInt): Double;
    { 0 for NULL and for a zero date }
    function Date(Row, C: LongInt): TDateTime;
  end;

  { the rows of a SELECT one at a time, for results too big to hold at once; nothing else may
    use the connection until the cursor is freed }
  TMyCursor = class
  private
    FConn: TMyConnection;
    FColumns: array of AnsiString;
    FRow: TMyRow;
    FNull: TMyNulls;
    FDone: Boolean;
  public
    destructor Destroy; override;
    function Next: Boolean;
    function Col(const Name: AnsiString): LongInt;
    function Str(C: LongInt): AnsiString;
    function IsNull(C: LongInt): Boolean;
    function Int(C: LongInt): Int64;
    function Float(C: LongInt): Double;
    function Date(C: LongInt): TDateTime;
  end;

  TMyConnection = class
  private
    FSock: TInetSocket;
    FLock: TRTLCriticalSection;     { FSock between the owner and Abort }
    FAborted: Boolean;
    FSeq: Byte;
    FServerVersion: AnsiString;
    FAffected: Int64;
    FPublicKey: AnsiString;
    procedure Drop;
    procedure ReadExact(var Buf; Count: LongInt);
    procedure WriteAll(const Buf; Count: LongInt);
    function ReadPacket: AnsiString;
    procedure WritePacket(const Payload: AnsiString);
    procedure ServerError(const P: AnsiString);
    procedure Authenticate(const Greeting: AnsiString);
    function Send(const SQL: AnsiString): AnsiString;
    function ReadRows(const First: AnsiString): TMyResult;
    procedure ReadColumns(const First: AnsiString; var Names: array of AnsiString);
  public
    Host: AnsiString;
    Port: LongInt;
    User: AnsiString;
    Password: AnsiString;
    Database: AnsiString;
    ConnectTimeoutMs: LongInt;
    IOTimeoutMs: LongInt;
    constructor Create;
    destructor Destroy; override;
    procedure Connect;
    procedure Close;
    function Connected: Boolean;
    { Connected, and nothing waits from the server while the connection is not in use: a server
      that ended an idle connection (wait_timeout, a restart, KILL) sent its last error or closed
      it. Such a connection is dropped here, so the next exchange connects again at once instead
      of failing on it. Only between statements. }
    function Usable: Boolean;
    { cuts the connection from another thread: a statement that waits for the server fails at
      once, and so does every later use of this object (the server is shutting down) }
    procedure Abort;
    { a statement that returns no rows (or whose rows nobody needs) }
    procedure Exec(const SQL: AnsiString);
    { a statement that returns rows; the caller frees the result }
    function Query(const SQL: AnsiString): TMyResult;
    { the same, one row at a time (TMyCursor.Next); the caller frees the cursor }
    function Open(const SQL: AnsiString): TMyCursor;
    function Ping: Boolean;
    property ServerVersion: AnsiString read FServerVersion;
    property AffectedRows: Int64 read FAffected;
  end;

  { INSERT ... VALUES (...), (...) ... ON DUPLICATE KEY UPDATE ..., cut into statements of a
    limited size: Add one row after the other, Flush at the end }
  TMyBatch = class
  private
    FConn: TMyConnection;
    FHead, FTail, FBuf: AnsiString;
    FRows, FTotal, FLimit: LongInt;
  public
    constructor Create(Conn: TMyConnection; const Head, Tail: AnsiString; LimitBytes: LongInt = 262144);
    procedure Add(const Values: AnsiString);
    procedure Flush;
    property Total: LongInt read FTotal;
  end;

{ CREATE TABLE IF NOT EXISTS (InnoDB, utf8mb4) with these columns ('name definition') and keys,
  then every column a table that was already there lacks is added, so a table made by hand or
  with fewer columns works as well. A column added that way must allow NULL or have a DEFAULT. }
procedure MyPrepareTable(Conn: TMyConnection; const Table: AnsiString; const Cols: array of AnsiString;
  const Keys: AnsiString);

{ the pieces of a statement }
function MyStr(const Utf8: AnsiString): AnsiString;
function MyStrMax(const Utf8: AnsiString; MaxChars: LongInt): AnsiString;
function MyInt(V: Int64): AnsiString;
function MyFloat(V: Double): AnsiString;
{ NULL for a date that is not one }
function MyDate(V: TDateTime): AnsiString;

{ player names arrive in a Windows code page (1250, 1252, 28591 = Latin-1, 65001 = UTF-8);
  the database holds UTF-8. Both ways give back the same bytes for every byte. }
function CodepageToUtf8(const S: AnsiString; CodePage: LongInt): AnsiString;
function Utf8ToCodepage(const S: AnsiString; CodePage: LongInt): AnsiString;
{ UTF-8 that a server takes: every broken sequence becomes a question mark }
function CleanUtf8(const S: AnsiString): AnsiString;
{ at most MaxChars characters of UTF-8 text }
function Utf8Left(const S: AnsiString; MaxChars: LongInt): AnsiString;

{ the building blocks, for the tests }
function MySha1(const S: AnsiString): AnsiString;
function MySha256(const S: AnsiString): AnsiString;
function MyScrambleNative(const Password, Nonce: AnsiString): AnsiString;
function MyScrambleSha2(const Password, Nonce: AnsiString): AnsiString;
function MyRsaEncrypt(const Pem, Msg: AnsiString): AnsiString;

implementation

const
  CLIENT_LONG_PASSWORD = $00000001;
  CLIENT_LONG_FLAG = $00000004;
  CLIENT_CONNECT_WITH_DB = $00000008;
  CLIENT_PROTOCOL_41 = $00000200;
  CLIENT_TRANSACTIONS = $00002000;
  CLIENT_SECURE_CONNECTION = $00008000;
  CLIENT_PLUGIN_AUTH = $00080000;

  COM_QUIT = $01;
  COM_QUERY = $03;
  { how long one wait for the server lasts before Abort is looked at again }
  WAIT_STEP_MS = 100;
  { a table has at most 4096 columns; a larger count is a broken answer }
  MAX_COLUMNS = 4096;
  COM_PING = $0E;

  { utf8mb4_general_ci: every MySQL since 5.5 and every MariaDB has it }
  CHARSET_UTF8MB4 = 45;
  MAX_PACKET = $FFFFFF;

{ ---------------- small helpers ---------------- }

constructor EMyError.CreateCode(ACode: LongInt; const Msg: AnsiString);
begin
  inherited Create(Msg);
  Code := ACode;
end;

function Le32(V: LongWord): AnsiString;
begin
  Result := AnsiChar(V and $FF) + AnsiChar((V shr 8) and $FF) + AnsiChar((V shr 16) and $FF) +
    AnsiChar((V shr 24) and $FF);
end;

function GetLe(const S: AnsiString; At, Count: LongInt): Int64;
var
  i: LongInt;
begin
  Result := 0;
  for i := Count - 1 downto 0 do
    if At + i <= Length(S) then
      Result := (Result shl 8) or Byte(S[At + i]);
end;

{ a length-encoded number at P, which moves past it; -1 for the NULL marker }
function LenEnc(const S: AnsiString; var P: LongInt): Int64;
var
  B: Byte;
begin
  Result := 0;
  if P > Length(S) then
    Exit;
  B := Byte(S[P]);
  Inc(P);
  case B of
    $FB: Result := -1;
    $FC: begin Result := GetLe(S, P, 2); Inc(P, 2); end;
    $FD: begin Result := GetLe(S, P, 3); Inc(P, 3); end;
    $FE: begin Result := GetLe(S, P, 8); Inc(P, 8); end;
  else
    Result := B;
  end;
end;

function LenEncStr(const S: AnsiString; var P: LongInt): AnsiString;
var
  L: Int64;
begin
  L := LenEnc(S, P);
  if L <= 0 then
    Exit('');
  { a length longer than the packet (only a broken or hostile server sends one) stops at its end }
  if L > Int64(Length(S)) - P + 1 then
    L := Int64(Length(S)) - P + 1;
  if L <= 0 then
    Exit('');
  Result := Copy(S, P, L);
  Inc(P, LongInt(L));
end;

function XorStr(const A, B: AnsiString): AnsiString;
var
  i: LongInt;
begin
  Result := A;
  if B = '' then
    Exit;
  for i := 1 to Length(Result) do
    Result[i] := AnsiChar(Byte(Result[i]) xor Byte(B[((i - 1) mod Length(B)) + 1]));
end;

function HexOf(const S: AnsiString): AnsiString;
const
  Digits: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  i: LongInt;
begin
  SetLength(Result, Length(S) * 2);
  for i := 1 to Length(S) do
  begin
    Result[i * 2 - 1] := Digits[Byte(S[i]) shr 4];
    Result[i * 2] := Digits[Byte(S[i]) and 15];
  end;
end;

{$IFDEF WINDOWS}
function RtlGenRandom(RandomBuffer: Pointer; RandomBufferLength: LongWord): ByteBool; stdcall;
  external 'advapi32.dll' name 'SystemFunction036';
{$ENDIF}

function RandomBytes(Count: LongInt): AnsiString;
var
  i: LongInt;
{$IFNDEF WINDOWS}
  F: TFileStream;
{$ENDIF}
begin
  SetLength(Result, Count);
  if Count = 0 then
    Exit;
{$IFDEF WINDOWS}
  if RtlGenRandom(@Result[1], Count) then
    Exit;
{$ELSE}
  try
    F := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
    try
      if F.Read(Result[1], Count) = Count then
        Exit;
    finally
      F.Free;
    end;
  except
  end;
{$ENDIF}
  Randomize;
  for i := 1 to Count do
    Result[i] := AnsiChar(Random(256));
end;

{ ---------------- SHA-1 and SHA-256 ---------------- }

function MySha1(const S: AnsiString): AnsiString;
var
  D: TSHA1Digest;
begin
  D := SHA1String(S);
  SetLength(Result, SizeOf(D));
  Move(D[0], Result[1], SizeOf(D));
end;

const
  K256: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function Ror32(V: LongWord; N: LongInt): LongWord; inline;
begin
  Result := (V shr N) or (V shl (32 - N));
end;

function MySha256(const S: AnsiString): AnsiString;
var
  H: array[0..7] of LongWord;
  W: array[0..63] of LongWord;
  Msg: AnsiString;
  BitLen: QWord;
  a, b, c, d, e, f, g, hh, t1, t2: LongWord;
  Blk, i: LongInt;
begin
  H[0] := $6a09e667; H[1] := $bb67ae85; H[2] := $3c6ef372; H[3] := $a54ff53a;
  H[4] := $510e527f; H[5] := $9b05688c; H[6] := $1f83d9ab; H[7] := $5be0cd19;
  BitLen := QWord(Length(S)) * 8;
  Msg := S + #$80;
  while Length(Msg) mod 64 <> 56 do
    Msg := Msg + #0;
  for i := 7 downto 0 do
    Msg := Msg + AnsiChar((BitLen shr (i * 8)) and $FF);
  Blk := 0;
  while Blk * 64 < Length(Msg) do
  begin
    for i := 0 to 15 do
      W[i] := (LongWord(Byte(Msg[Blk * 64 + i * 4 + 1])) shl 24) or
              (LongWord(Byte(Msg[Blk * 64 + i * 4 + 2])) shl 16) or
              (LongWord(Byte(Msg[Blk * 64 + i * 4 + 3])) shl 8) or
              LongWord(Byte(Msg[Blk * 64 + i * 4 + 4]));
    for i := 16 to 63 do
      W[i] := (Ror32(W[i - 2], 17) xor Ror32(W[i - 2], 19) xor (W[i - 2] shr 10)) + W[i - 7] +
              (Ror32(W[i - 15], 7) xor Ror32(W[i - 15], 18) xor (W[i - 15] shr 3)) + W[i - 16];
    a := H[0]; b := H[1]; c := H[2]; d := H[3]; e := H[4]; f := H[5]; g := H[6]; hh := H[7];
    for i := 0 to 63 do
    begin
      t1 := hh + (Ror32(e, 6) xor Ror32(e, 11) xor Ror32(e, 25)) + ((e and f) xor ((not e) and g)) +
            K256[i] + W[i];
      t2 := (Ror32(a, 2) xor Ror32(a, 13) xor Ror32(a, 22)) + ((a and b) xor (a and c) xor (b and c));
      hh := g; g := f; f := e; e := d + t1;
      d := c; c := b; b := a; a := t1 + t2;
    end;
    H[0] := H[0] + a; H[1] := H[1] + b; H[2] := H[2] + c; H[3] := H[3] + d;
    H[4] := H[4] + e; H[5] := H[5] + f; H[6] := H[6] + g; H[7] := H[7] + hh;
    Inc(Blk);
  end;
  SetLength(Result, 32);
  for i := 0 to 7 do
  begin
    Result[i * 4 + 1] := AnsiChar(H[i] shr 24);
    Result[i * 4 + 2] := AnsiChar((H[i] shr 16) and $FF);
    Result[i * 4 + 3] := AnsiChar((H[i] shr 8) and $FF);
    Result[i * 4 + 4] := AnsiChar(H[i] and $FF);
  end;
end;

{ ---------------- the password methods ---------------- }

{ mysql_native_password: SHA1(pw) xor SHA1(nonce + SHA1(SHA1(pw))) }
function MyScrambleNative(const Password, Nonce: AnsiString): AnsiString;
var
  S1: AnsiString;
begin
  if Password = '' then
    Exit('');
  S1 := MySha1(Password);
  Result := XorStr(S1, MySha1(Nonce + MySha1(S1)));
end;

{ caching_sha2_password: SHA256(pw) xor SHA256(SHA256(SHA256(pw)) + nonce) }
function MyScrambleSha2(const Password, Nonce: AnsiString): AnsiString;
var
  S1: AnsiString;
begin
  if Password = '' then
    Exit('');
  S1 := MySha256(Password);
  Result := XorStr(S1, MySha256(MySha256(S1) + Nonce));
end;

{ ---------------- RSA with OAEP, for the full caching_sha2 path ----------------

  Without TLS the server wants the password encrypted with its public key. The numbers are
  kept as 32-bit limbs, lowest first, and multiplied the Montgomery way; with the exponent the
  servers use (65537) that is seventeen multiplications, nothing a thread notices. }

type
  TLimbs = array of LongWord;

function BytesToLimbs(const B: AnsiString; K: LongInt): TLimbs;
var
  i, n, j: LongInt;
begin
  Result := nil;
  SetLength(Result, K);
  for i := 0 to K - 1 do
    Result[i] := 0;
  n := Length(B);
  for i := 0 to n - 1 do
  begin
    j := i div 4;
    if j < K then
      Result[j] := Result[j] or (LongWord(Byte(B[n - i])) shl (8 * (i mod 4)));
  end;
end;

function LimbsToBytes(const L: TLimbs; Len: LongInt): AnsiString;
var
  i, j: LongInt;
begin
  SetLength(Result, Len);
  for i := 0 to Len - 1 do
  begin
    j := i div 4;
    if j <= High(L) then
      Result[Len - i] := AnsiChar((L[j] shr (8 * (i mod 4))) and $FF)
    else
      Result[Len - i] := #0;
  end;
end;

function LimbsGE(const A, B: TLimbs): Boolean;
var
  i: LongInt;
begin
  for i := High(A) downto 0 do
    if A[i] <> B[i] then
      Exit(A[i] > B[i]);
  Result := True;
end;

procedure LimbsSub(var A: TLimbs; const B: TLimbs);
var
  i: LongInt;
  D, Borrow: Int64;
begin
  Borrow := 0;
  for i := 0 to High(A) do
  begin
    D := Int64(A[i]) - Int64(B[i]) - Borrow;
    if D < 0 then
    begin
      D := D + $100000000;
      Borrow := 1;
    end
    else
      Borrow := 0;
    A[i] := LongWord(D);
  end;
end;

function MontMul(const A, B, N: TLimbs; N0Inv: LongWord): TLimbs;
var
  K, i, j: LongInt;
  T: array of LongWord;
  S, C: QWord;
  M: LongWord;
begin
  K := Length(N);
  SetLength(T, K + 2);
  for i := 0 to K + 1 do
    T[i] := 0;
  for i := 0 to K - 1 do
  begin
    C := 0;
    for j := 0 to K - 1 do
    begin
      S := QWord(T[j]) + QWord(A[j]) * QWord(B[i]) + C;
      T[j] := LongWord(S);
      C := S shr 32;
    end;
    S := QWord(T[K]) + C;
    T[K] := LongWord(S);
    T[K + 1] := LongWord(S shr 32);
    M := LongWord(QWord(T[0]) * QWord(N0Inv));
    S := QWord(T[0]) + QWord(M) * QWord(N[0]);
    C := S shr 32;
    for j := 1 to K - 1 do
    begin
      S := QWord(T[j]) + QWord(M) * QWord(N[j]) + C;
      T[j - 1] := LongWord(S);
      C := S shr 32;
    end;
    S := QWord(T[K]) + C;
    T[K - 1] := LongWord(S);
    T[K] := T[K + 1] + LongWord(S shr 32);
  end;
  Result := nil;
  SetLength(Result, K);
  for i := 0 to K - 1 do
    Result[i] := T[i];
  if (T[K] <> 0) or LimbsGE(Result, N) then
    LimbsSub(Result, N);
end;

{ Base^Exp mod Modulus, all big-endian byte strings; the result has the modulus' length }
function ModPow(const Base, Exp, Modulus: AnsiString): AnsiString;
var
  K, i, Bit: LongInt;
  N, A, R2, X, One: TLimbs;
  N0, Inv: LongWord;
  Carry: LongWord;
  Started: Boolean;
begin
  K := (Length(Modulus) + 3) div 4;
  N := BytesToLimbs(Modulus, K);
  A := BytesToLimbs(Base, K);
  { -N^-1 mod 2^32, by Newton's iteration }
  N0 := N[0];
  Inv := 1;
  for i := 1 to 5 do
    Inv := Inv * (2 - N0 * Inv);
  Inv := LongWord(0) - Inv;
  { R^2 mod N, R = 2^(32K), by doubling 1 that many times }
  SetLength(R2, K);
  for i := 0 to K - 1 do
    R2[i] := 0;
  R2[0] := 1;
  for i := 1 to 64 * K do
  begin
    Carry := R2[K - 1] shr 31;
    for Bit := K - 1 downto 1 do
      R2[Bit] := (R2[Bit] shl 1) or (R2[Bit - 1] shr 31);
    R2[0] := R2[0] shl 1;
    if (Carry <> 0) or LimbsGE(R2, N) then
      LimbsSub(R2, N);
  end;
  SetLength(One, K);
  for i := 0 to K - 1 do
    One[i] := 0;
  One[0] := 1;
  A := MontMul(A, R2, N, Inv);
  X := MontMul(One, R2, N, Inv);
  Started := False;
  for i := 1 to Length(Exp) do
    for Bit := 7 downto 0 do
    begin
      if Started then
        X := MontMul(X, X, N, Inv);
      if (Byte(Exp[i]) shr Bit) and 1 = 1 then
      begin
        X := MontMul(X, A, N, Inv);
        Started := True;
      end;
    end;
  X := MontMul(X, One, N, Inv);
  Result := LimbsToBytes(X, Length(Modulus));
end;

{ one element of DER at P: its tag and its content; P moves past it }
function DerNext(const D: AnsiString; var P: LongInt; out Tag: Byte; out Content: AnsiString): Boolean;
var
  L, n, i: LongInt;
begin
  Result := False;
  Content := '';
  Tag := 0;
  if P + 1 > Length(D) then
    Exit;
  Tag := Byte(D[P]);
  Inc(P);
  L := Byte(D[P]);
  Inc(P);
  if L and $80 <> 0 then
  begin
    n := L and $7F;
    if (n < 1) or (n > 4) then
      Exit;
    L := 0;
    for i := 1 to n do
    begin
      if P > Length(D) then
        Exit;
      L := (L shl 8) or Byte(D[P]);
      Inc(P);
    end;
  end;
  if (L < 0) or (L > Length(D) - P + 1) then
    Exit;
  Content := Copy(D, P, L);
  Inc(P, L);
  Result := True;
end;

function StripZeros(const S: AnsiString): AnsiString;
var
  i: LongInt;
begin
  i := 1;
  while (i < Length(S)) and (S[i] = #0) do
    Inc(i);
  Result := Copy(S, i, MaxInt);
end;

{ the modulus and the exponent of a PEM public key, either "PUBLIC KEY" (the kind MySQL
  sends) or "RSA PUBLIC KEY" }
procedure ReadPublicKey(const Pem: AnsiString; out N, E: AnsiString);
var
  Body, Der, Seq, First, Bits, Inner: AnsiString;
  Lines: TStringList;
  i, P, Q, R: LongInt;
  Tag: Byte;
begin
  N := '';
  E := '';
  Body := '';
  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(Pem, #13, '', [rfReplaceAll]);
    for i := 0 to Lines.Count - 1 do
      if (Trim(Lines[i]) <> '') and (Pos('-----', Lines[i]) = 0) then
        Body := Body + Trim(Lines[i]);
  finally
    Lines.Free;
  end;
  Der := DecodeStringBase64(Body);
  P := 1;
  if not DerNext(Der, P, Tag, Seq) or (Tag <> $30) then
    raise EMyError.CreateCode(0, 'the server sent a public key that cannot be read');
  Q := 1;
  if not DerNext(Seq, Q, Tag, First) then
    raise EMyError.CreateCode(0, 'the server sent a public key that cannot be read');
  if Tag = $02 then
  begin
    N := First;
    DerNext(Seq, Q, Tag, E);
  end
  else if Tag = $30 then
  begin
    if not DerNext(Seq, Q, Tag, Bits) or (Tag <> $03) or (Length(Bits) < 2) then
      raise EMyError.CreateCode(0, 'the server sent a public key that cannot be read');
    Bits := Copy(Bits, 2, MaxInt);
    R := 1;
    if not DerNext(Bits, R, Tag, Inner) or (Tag <> $30) then
      raise EMyError.CreateCode(0, 'the server sent a public key that cannot be read');
    R := 1;
    DerNext(Inner, R, Tag, N);
    DerNext(Inner, R, Tag, E);
  end;
  N := StripZeros(N);
  E := StripZeros(E);
  if (Length(N) < 64) or (E = '') then
    raise EMyError.CreateCode(0, 'the server sent a public key that cannot be read');
end;

{ MGF1 with SHA-1 }
function Mgf1(const Seed: AnsiString; Len: LongInt): AnsiString;
var
  Counter: LongWord;
begin
  Result := '';
  Counter := 0;
  while Length(Result) < Len do
  begin
    Result := Result + MySha1(Seed + AnsiChar(Counter shr 24) + AnsiChar((Counter shr 16) and $FF) +
      AnsiChar((Counter shr 8) and $FF) + AnsiChar(Counter and $FF));
    Inc(Counter);
  end;
  SetLength(Result, Len);
end;

{ RSAES-OAEP with SHA-1 and an empty label, the padding MySQL decrypts with }
function MyRsaEncrypt(const Pem, Msg: AnsiString): AnsiString;
var
  N, E, DB, Seed, MaskedDB, MaskedSeed, EM: AnsiString;
  K: LongInt;
begin
  ReadPublicKey(Pem, N, E);
  K := Length(N);
  if Length(Msg) > K - 2 * 20 - 2 then
    raise EMyError.CreateCode(0, 'the password is too long for the server''s key');
  DB := MySha1('') + StringOfChar(#0, K - Length(Msg) - 2 * 20 - 2) + #1 + Msg;
  Seed := RandomBytes(20);
  MaskedDB := XorStr(DB, Mgf1(Seed, K - 20 - 1));
  MaskedSeed := XorStr(Seed, Mgf1(MaskedDB, 20));
  EM := #0 + MaskedSeed + MaskedDB;
  Result := ModPow(EM, E, N);
end;

{ ---------------- values for statements ---------------- }

{ the length of the valid UTF-8 sequence at I, 0 when there is none }
function Utf8SeqLen(const S: AnsiString; i: LongInt): LongInt;
var
  B: Byte;
  Need, k: LongInt;
  CP: LongWord;
begin
  B := Byte(S[i]);
  if B < $80 then
    Exit(1);
  Result := 0;
  if (B and $E0) = $C0 then begin Need := 1; CP := B and $1F; end
  else if (B and $F0) = $E0 then begin Need := 2; CP := B and $0F; end
  else if (B and $F8) = $F0 then begin Need := 3; CP := B and $07; end
  else Exit;
  if i + Need > Length(S) then
    Exit;
  for k := 1 to Need do
  begin
    if (Byte(S[i + k]) and $C0) <> $80 then
      Exit;
    CP := (CP shl 6) or (Byte(S[i + k]) and $3F);
  end;
  { too long a form, a surrogate or beyond the last code point: not UTF-8 }
  if ((Need = 1) and (CP < $80)) or ((Need = 2) and (CP < $800)) or ((Need = 3) and (CP < $10000)) or
     ((CP >= $D800) and (CP <= $DFFF)) or (CP > $10FFFF) then
    Exit;
  Result := Need + 1;
end;

function CleanUtf8(const S: AnsiString): AnsiString;
var
  i, n, L: LongInt;
begin
  n := Length(S);
  i := 1;
  while i <= n do
  begin
    L := Utf8SeqLen(S, i);
    if L = 0 then
      Break;
    Inc(i, L);
  end;
  if i > n then
    Exit(S);
  Result := Copy(S, 1, i - 1);
  while i <= n do
  begin
    L := Utf8SeqLen(S, i);
    if L = 0 then
    begin
      Result := Result + '?';
      Inc(i);
    end
    else
    begin
      Result := Result + Copy(S, i, L);
      Inc(i, L);
    end;
  end;
end;

function Utf8Left(const S: AnsiString; MaxChars: LongInt): AnsiString;
var
  i, Chars: LongInt;
begin
  Chars := 0;
  i := 1;
  while i <= Length(S) do
  begin
    if (Byte(S[i]) and $C0) <> $80 then
    begin
      Inc(Chars);
      if Chars > MaxChars then
        Exit(Copy(S, 1, i - 1));
    end;
    Inc(i);
  end;
  Result := S;
end;

function MyStr(const Utf8: AnsiString): AnsiString;
begin
  if Utf8 = '' then
    Result := ''''''
  else
    Result := '_utf8mb4 X''' + HexOf(CleanUtf8(Utf8)) + '''';
end;

function MyStrMax(const Utf8: AnsiString; MaxChars: LongInt): AnsiString;
begin
  Result := MyStr(Utf8Left(CleanUtf8(Utf8), MaxChars));
end;

function MyInt(V: Int64): AnsiString;
begin
  Result := IntToStr(V);
end;

function MyFloat(V: Double): AnsiString;
var
  F: TFormatSettings;
begin
  if IsNan(V) or IsInfinite(V) then
    Exit('0');
  F := DefaultFormatSettings;
  F.DecimalSeparator := '.';
  F.ThousandSeparator := #0;
  Result := FloatToStrF(V, ffGeneral, 15, 0, F);
end;

function MyDate(V: TDateTime): AnsiString;
begin
  { 1 = 31.12.1899; a real date of this program is later than 2000, and DATETIME ends in 9999 }
  if IsNan(V) or (V <= 1) or (V >= 2958465) then
    Result := 'NULL'
  else
    Result := '''' + FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss', V) + '''';
end;

{ ---------------- code pages ---------------- }

const
  { Windows-1250 bytes $80..$FF; bytes Windows leaves undefined keep their own code point }
  CP1250: array[$80..$FF] of Word = (
    $20AC, $0081, $201A, $0083, $201E, $2026, $2020, $2021, $0088, $2030, $0160, $2039, $015A, $0164, $017D, $0179,
    $0090, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $0098, $2122, $0161, $203A, $015B, $0165, $017E, $017A,
    $00A0, $02C7, $02D8, $0141, $00A4, $0104, $00A6, $00A7, $00A8, $00A9, $015E, $00AB, $00AC, $00AD, $00AE, $017B,
    $00B0, $00B1, $02DB, $0142, $00B4, $00B5, $00B6, $00B7, $00B8, $0105, $015F, $00BB, $013D, $02DD, $013E, $017C,
    $0154, $00C1, $00C2, $0102, $00C4, $0139, $0106, $00C7, $010C, $00C9, $0118, $00CB, $011A, $00CD, $00CE, $010E,
    $0110, $0143, $0147, $00D3, $00D4, $0150, $00D6, $00D7, $0158, $016E, $00DA, $0170, $00DC, $00DD, $0162, $00DF,
    $0155, $00E1, $00E2, $0103, $00E4, $013A, $0107, $00E7, $010D, $00E9, $0119, $00EB, $011B, $00ED, $00EE, $010F,
    $0111, $0144, $0148, $00F3, $00F4, $0151, $00F6, $00F7, $0159, $016F, $00FA, $0171, $00FC, $00FD, $0163, $02D9);
  { Windows-1252 bytes $80..$9F; the rest of the upper half is Latin-1 }
  CP1252: array[$80..$9F] of Word = (
    $20AC, $0081, $201A, $0192, $201E, $2026, $2020, $2021, $02C6, $2030, $0160, $2039, $0152, $008D, $017D, $008F,
    $0090, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $02DC, $2122, $0161, $203A, $0153, $009D, $017E, $0178);

function CodePointOf(B: Byte; CodePage: LongInt): LongWord;
begin
  if B < $80 then
    Exit(B);
  case CodePage of
    1250: Result := CP1250[B];
    1252: if B <= $9F then Result := CP1252[B] else Result := B;
  else
    Result := B;
  end;
end;

procedure PutUtf8(var R: AnsiString; CP: LongWord);
begin
  if CP < $80 then
    R := R + AnsiChar(CP)
  else if CP < $800 then
    R := R + AnsiChar($C0 or (CP shr 6)) + AnsiChar($80 or (CP and $3F))
  else
    R := R + AnsiChar($E0 or (CP shr 12)) + AnsiChar($80 or ((CP shr 6) and $3F)) + AnsiChar($80 or (CP and $3F));
end;

function CodepageToUtf8(const S: AnsiString; CodePage: LongInt): AnsiString;
var
  i: LongInt;
begin
  if CodePage = 65001 then
    Exit(CleanUtf8(S));
  Result := '';
  for i := 1 to Length(S) do
    PutUtf8(Result, CodePointOf(Byte(S[i]), CodePage));
end;

function Utf8ToCodepage(const S: AnsiString; CodePage: LongInt): AnsiString;
var
  i, n, Need, k, B2: LongInt;
  B: Byte;
  CP: LongWord;
  Found, Valid: Boolean;
begin
  if CodePage = 65001 then
    Exit(S);
  Result := '';
  n := Length(S);
  i := 1;
  while i <= n do
  begin
    B := Byte(S[i]);
    if B < $80 then
    begin
      Result := Result + AnsiChar(B);
      Inc(i);
      Continue;
    end;
    if (B and $E0) = $C0 then begin Need := 1; CP := B and $1F; end
    else if (B and $F0) = $E0 then begin Need := 2; CP := B and $0F; end
    else if (B and $F8) = $F0 then begin Need := 3; CP := B and $07; end
    else begin Need := 0; CP := 0; end;
    { a byte that starts nothing, a sequence cut short or one whose next bytes do not belong to
      it is not a character: it becomes "?" and the next byte is read on its own }
    Valid := (Need > 0) and (i + Need <= n);
    if Valid then
      for k := 1 to Need do
        if (Byte(S[i + k]) and $C0) <> $80 then
          Valid := False;
    if not Valid then
    begin
      Result := Result + '?';
      Inc(i);
      Continue;
    end;
    for k := 1 to Need do
      CP := (CP shl 6) or (Byte(S[i + k]) and $3F);
    Inc(i, Need + 1);
    if CP < $80 then
    begin
      Result := Result + AnsiChar(CP);
      Continue;
    end;
    Found := False;
    for B2 := $80 to $FF do
      if CodePointOf(B2, CodePage) = CP then
      begin
        Result := Result + AnsiChar(B2);
        Found := True;
        Break;
      end;
    if not Found then
      Result := Result + '?';
  end;
end;

{ ---------------- results ---------------- }

function TextInt(const S: AnsiString): Int64;
var
  P: LongInt;
begin
  P := Pos('.', S);
  if P > 0 then
    Result := StrToInt64Def(Copy(S, 1, P - 1), 0)
  else
    Result := StrToInt64Def(S, 0);
end;

function TextFloat(const S: AnsiString): Double;
var
  F: TFormatSettings;
begin
  F := DefaultFormatSettings;
  F.DecimalSeparator := '.';
  Result := StrToFloatDef(S, 0, F);
end;

function TextDate(const S: AnsiString): TDateTime;
var
  Y, Mo, D, H, Mi, Se: LongInt;
  T: TDateTime;
begin
  Result := 0;
  if Length(S) < 10 then
    Exit;
  Y := StrToIntDef(Copy(S, 1, 4), 0);
  Mo := StrToIntDef(Copy(S, 6, 2), 0);
  D := StrToIntDef(Copy(S, 9, 2), 0);
  H := StrToIntDef(Copy(S, 12, 2), 0);
  Mi := StrToIntDef(Copy(S, 15, 2), 0);
  Se := StrToIntDef(Copy(S, 18, 2), 0);
  if (Y < 1) or (Mo < 1) or (D < 1) then
    Exit;
  if not TryEncodeDate(Y, Mo, D, Result) then
    Exit(0);
  if TryEncodeTime(H, Mi, Se, 0, T) then
    Result := Result + T;
end;

{ one row of the text protocol: a length-encoded value per column, $FB for NULL }
procedure ParseRow(const Pkt: AnsiString; var Row: TMyRow; var Nul: TMyNulls);
var
  i, P: LongInt;
  L: Int64;
begin
  P := 1;
  for i := 0 to High(Row) do
  begin
    if (P <= Length(Pkt)) and (Byte(Pkt[P]) = $FB) then
    begin
      Inc(P);
      Row[i] := '';
      Nul[i] := True;
    end
    else
    begin
      L := LenEnc(Pkt, P);
      { a length past the end of the packet (a broken answer) stops at its end, as in LenEncStr }
      if L > Int64(Length(Pkt)) - P + 1 then
        L := Int64(Length(Pkt)) - P + 1;
      if L > 0 then
      begin
        Row[i] := Copy(Pkt, P, L);
        Inc(P, LongInt(L));
      end
      else
        Row[i] := '';
      Nul[i] := False;
    end;
  end;
end;

procedure TMyResult.AddRow(const R: TMyRow; const N: array of Boolean);
var
  i: LongInt;
begin
  if FCount >= Length(FRows) then
  begin
    SetLength(FRows, FCount * 2 + 16);
    SetLength(FNulls, FCount * 2 + 16);
  end;
  FRows[FCount] := R;
  SetLength(FNulls[FCount], Length(N));
  for i := 0 to High(N) do
    FNulls[FCount][i] := N[i];
  Inc(FCount);
end;

function TMyResult.ColCount: LongInt;
begin
  Result := Length(FColumns);
end;

function TMyResult.RowCount: LongInt;
begin
  Result := FCount;
end;

function TMyResult.ColumnName(C: LongInt): AnsiString;
begin
  if (C >= 0) and (C <= High(FColumns)) then
    Result := FColumns[C]
  else
    Result := '';
end;

function TMyResult.Col(const Name: AnsiString): LongInt;
var
  i: LongInt;
begin
  for i := 0 to High(FColumns) do
    if SameText(FColumns[i], Name) then
      Exit(i);
  Result := -1;
end;

function TMyResult.Str(Row, C: LongInt): AnsiString;
begin
  Result := '';
  if (Row >= 0) and (Row < FCount) and (C >= 0) and (C <= High(FRows[Row])) then
    Result := FRows[Row][C];
end;

function TMyResult.IsNull(Row, C: LongInt): Boolean;
begin
  Result := True;
  if (Row >= 0) and (Row < FCount) and (C >= 0) and (C <= High(FNulls[Row])) then
    Result := FNulls[Row][C];
end;

function TMyResult.Int(Row, C: LongInt): Int64;
begin
  Result := TextInt(Str(Row, C));
end;

function TMyResult.Float(Row, C: LongInt): Double;
begin
  Result := TextFloat(Str(Row, C));
end;

function TMyResult.Date(Row, C: LongInt): TDateTime;
begin
  Result := TextDate(Str(Row, C));
end;

{ ---------------- cursors ---------------- }

destructor TMyCursor.Destroy;
begin
  { the rest of the rows, so the connection is ready for the next statement }
  try
    while (FConn <> nil) and FConn.Connected and Next do
      ;
  except
  end;
  inherited Destroy;
end;

function TMyCursor.Next: Boolean;
var
  Pkt: AnsiString;
begin
  Result := False;
  if FDone or (FConn = nil) then
    Exit;
  Pkt := FConn.ReadPacket;
  if (Pkt <> '') and (Byte(Pkt[1]) = $FE) and (Length(Pkt) < 9) then
  begin
    FDone := True;
    Exit;
  end;
  if (Pkt <> '') and (Byte(Pkt[1]) = $FF) then
  begin
    FDone := True;
    FConn.ServerError(Pkt);
  end;
  ParseRow(Pkt, FRow, FNull);
  Result := True;
end;

function TMyCursor.Col(const Name: AnsiString): LongInt;
var
  i: LongInt;
begin
  for i := 0 to High(FColumns) do
    if SameText(FColumns[i], Name) then
      Exit(i);
  Result := -1;
end;

function TMyCursor.Str(C: LongInt): AnsiString;
begin
  if (C >= 0) and (C <= High(FRow)) then
    Result := FRow[C]
  else
    Result := '';
end;

function TMyCursor.IsNull(C: LongInt): Boolean;
begin
  Result := (C < 0) or (C > High(FNull)) or FNull[C];
end;

function TMyCursor.Int(C: LongInt): Int64;
begin
  Result := TextInt(Str(C));
end;

function TMyCursor.Float(C: LongInt): Double;
begin
  Result := TextFloat(Str(C));
end;

function TMyCursor.Date(C: LongInt): TDateTime;
begin
  Result := TextDate(Str(C));
end;

{ ---------------- the connection ---------------- }

constructor TMyConnection.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  Port := 3306;
  ConnectTimeoutMs := 5000;
  IOTimeoutMs := 30000;
end;

destructor TMyConnection.Destroy;
begin
  Close;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TMyConnection.Connected: Boolean;
begin
  Result := FSock <> nil;
end;

procedure TMyConnection.Drop;
var
  S: TInetSocket;
begin
  EnterCriticalSection(FLock);
  try
    S := FSock;
    FSock := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  S.Free;
end;

procedure TMyConnection.Abort;
begin
  EnterCriticalSection(FLock);
  try
    FAborted := True;
    if FSock <> nil then
      fpShutdown(FSock.Handle, 2);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{$IFDEF WINDOWS}
type
  TWsFdSet = record
    fd_count: LongWord;
    fd_array: array[0..63] of PtrUInt;
  end;
  TWsTimeVal = record
    tv_sec, tv_usec: LongInt;
  end;

function WsSelect(nfds: LongInt; readfds, writefds, exceptfds, timeout: Pointer): LongInt; stdcall;
  external 'ws2_32.dll' name 'select';
{$ENDIF}

{ True when the socket has something to read (an answer, the end of the connection or an
  error) within Ms; a socket that cannot be waited for this way counts as ready and the read
  itself waits, as it always did }
function WaitReadable(H: PtrInt; Ms: LongInt): Boolean;
{$IFDEF WINDOWS}
var
  S: TWsFdSet;
  T: TWsTimeVal;
begin
  S.fd_count := 1;
  S.fd_array[0] := PtrUInt(H);
  T.tv_sec := Ms div 1000;
  T.tv_usec := (Ms mod 1000) * 1000;
  Result := WsSelect(0, @S, nil, nil, @T) <> 0;
end;
{$ELSE}
var
  S: TFDSet;
  T: TTimeVal;
begin
  if (H < 0) or (H >= FD_MAXFDSET) then
    Exit(True);
  fpFD_ZERO(S);
  fpFD_SET(H, S);
  T.tv_sec := Ms div 1000;
  T.tv_usec := (Ms mod 1000) * 1000;
  Result := fpSelect(H + 1, @S, nil, nil, @T) <> 0;
end;
{$ENDIF}

procedure TMyConnection.ReadExact(var Buf; Count: LongInt);
var
  P: PByte;
  Got: LongInt;
  Deadline: QWord;
begin
  if FSock = nil then
    raise EMyError.CreateCode(0, 'not connected');
  P := @Buf;
  while Count > 0 do
  begin
    { the answer is waited for in short steps: Abort from another thread is noticed at once,
      whatever the system does with a socket shut down under a waiting read }
    Deadline := GetTickCount64 + QWord(Max(1, IOTimeoutMs));
    while not WaitReadable(PtrInt(FSock.Handle), WAIT_STEP_MS) do
    begin
      if FAborted then
      begin
        Drop;
        raise EMyError.CreateCode(0, 'the connection was cut: the server is shutting down');
      end;
      if GetTickCount64 >= Deadline then
      begin
        Drop;
        raise EMyError.CreateCode(0, 'the connection to the database was lost (no answer)');
      end;
    end;
    if FAborted then
    begin
      Drop;
      raise EMyError.CreateCode(0, 'the connection was cut: the server is shutting down');
    end;
    Got := FSock.Read(P^, Count);
    if Got <= 0 then
    begin
      Drop;
      raise EMyError.CreateCode(0, 'the connection to the database was lost (no answer)');
    end;
    Inc(P, Got);
    Dec(Count, Got);
  end;
end;

procedure TMyConnection.WriteAll(const Buf; Count: LongInt);
var
  P: PByte;
  Sent: LongInt;
begin
  if FSock = nil then
    raise EMyError.CreateCode(0, 'not connected');
  if FAborted then
  begin
    Drop;
    raise EMyError.CreateCode(0, 'the connection was cut: the server is shutting down');
  end;
  P := @Buf;
  while Count > 0 do
  begin
    Sent := FSock.Write(P^, Count);
    if Sent <= 0 then
    begin
      Drop;
      raise EMyError.CreateCode(0, 'the connection to the database was lost (cannot send)');
    end;
    Inc(P, Sent);
    Dec(Count, Sent);
  end;
end;

function TMyConnection.ReadPacket: AnsiString;
var
  Hd: array[0..3] of Byte;
  Len: LongInt;
  Part: AnsiString;
begin
  Result := '';
  repeat
    ReadExact(Hd, 4);
    Len := Hd[0] or (Hd[1] shl 8) or (Hd[2] shl 16);
    FSeq := Byte(Hd[3] + 1);
    SetLength(Part, Len);
    if Len > 0 then
      ReadExact(Part[1], Len);
    Result := Result + Part;
  until Len < MAX_PACKET;
end;

procedure TMyConnection.WritePacket(const Payload: AnsiString);
var
  P, Len: LongInt;
  Hd: AnsiString;
begin
  P := 1;
  repeat
    Len := Length(Payload) - P + 1;
    if Len > MAX_PACKET then
      Len := MAX_PACKET;
    Hd := AnsiChar(Len and $FF) + AnsiChar((Len shr 8) and $FF) + AnsiChar((Len shr 16) and $FF) + AnsiChar(FSeq);
    FSeq := Byte(FSeq + 1);
    if Len > 0 then
      Hd := Hd + Copy(Payload, P, Len);
    WriteAll(Hd[1], Length(Hd));
    Inc(P, Len);
    { a packet of exactly the maximum size is followed by one more, empty if need be }
  until Len < MAX_PACKET;
end;

procedure TMyConnection.ServerError(const P: AnsiString);
var
  Code: LongInt;
  Msg: AnsiString;
begin
  Code := GetLe(P, 2, 2);
  if (Length(P) >= 4) and (P[4] = '#') then
    Msg := Copy(P, 10, MaxInt)
  else
    Msg := Copy(P, 4, MaxInt);
  { the last word of a server that closes the connection: shutting down (1053), aborting it (1152,
    1184), killed (1927 MariaDB, 3169 MySQL), idle too long (4031). The socket is dead now, and
    Connected says so; after any other error the connection goes on. }
  if (Code = 1053) or (Code = 1152) or (Code = 1184) or (Code = 1927) or (Code = 3169) or (Code = 4031) then
    Drop;
  raise EMyError.CreateCode(Code, Format('MySQL error %d: %s', [Code, Msg]));
end;

procedure TMyConnection.Authenticate(const Greeting: AnsiString);
var
  P, Z: LongInt;
  Caps, Flags: LongWord;
  Nonce, Plugin, Reply, Resp, Pkt, Data: AnsiString;

  function Answer(const Method, Seed: AnsiString): AnsiString;
  begin
    if Method = 'mysql_native_password' then
      Result := MyScrambleNative(Password, Seed)
    else if Method = 'caching_sha2_password' then
      Result := MyScrambleSha2(Password, Seed)
    else if Method = 'sha256_password' then
    begin
      { without TLS the password travels encrypted with the server's key, which it sends
        when asked with a 1 }
      if Password = '' then
        Result := #0
      else
        Result := #1;
    end
    else
      raise EMyError.CreateCode(0, 'the server wants the password method "' + Method +
        '", which this client does not know (use mysql_native_password or caching_sha2_password)');
  end;

  function Encrypted(const Pem, Seed: AnsiString): AnsiString;
  begin
    FPublicKey := Pem;
    Result := MyRsaEncrypt(Pem, XorStr(Password + #0, Seed));
  end;

begin
  if Greeting = '' then
    raise EMyError.CreateCode(0, 'the database server sent nothing');
  if Byte(Greeting[1]) = $FF then
    ServerError(Greeting);
  if Byte(Greeting[1]) <> 10 then
    raise EMyError.CreateCode(0, 'this is not a MySQL or MariaDB server (protocol ' +
      IntToStr(Byte(Greeting[1])) + ')');
  P := 2;
  Z := P;
  while (Z <= Length(Greeting)) and (Greeting[Z] <> #0) do
    Inc(Z);
  FServerVersion := Copy(Greeting, P, Z - P);
  P := Z + 1;
  Inc(P, 4);                                       { connection id }
  Nonce := Copy(Greeting, P, 8);
  Inc(P, 9);                                       { and the filler }
  Caps := GetLe(Greeting, P, 2);
  Inc(P, 2);
  Plugin := 'mysql_native_password';
  if P <= Length(Greeting) then
  begin
    Inc(P, 3);                                     { character set, status }
    Caps := Caps or (LongWord(GetLe(Greeting, P, 2)) shl 16);
    Inc(P, 2);
    { length of the whole nonce; a greeting cut short has none }
    if P <= Length(Greeting) then
      Z := Byte(Greeting[P])
    else
      Z := 0;
    Inc(P, 11);                                    { and ten reserved bytes }
    if Caps and CLIENT_SECURE_CONNECTION <> 0 then
    begin
      if Z - 8 > 13 then
        Z := Z - 8
      else
        Z := 13;
      Nonce := Nonce + Copy(Greeting, P, Z - 1);
      Inc(P, Z);
    end;
    if Caps and CLIENT_PLUGIN_AUTH <> 0 then
    begin
      Z := P;
      while (Z <= Length(Greeting)) and (Greeting[Z] <> #0) do
        Inc(Z);
      if Z > P then
        Plugin := Copy(Greeting, P, Z - P);
    end;
  end;
  if Caps and CLIENT_PROTOCOL_41 = 0 then
    raise EMyError.CreateCode(0, 'the database server is older than MySQL 4.1');

  Flags := CLIENT_LONG_PASSWORD or CLIENT_LONG_FLAG or CLIENT_PROTOCOL_41 or CLIENT_TRANSACTIONS or
    (Caps and (CLIENT_SECURE_CONNECTION or CLIENT_PLUGIN_AUTH));
  if Database <> '' then
    Flags := Flags or (Caps and CLIENT_CONNECT_WITH_DB);
  Resp := Answer(Plugin, Nonce);
  Pkt := Le32(Flags) + Le32($01000000) + AnsiChar(CHARSET_UTF8MB4) + StringOfChar(#0, 23) + User + #0;
  if Flags and CLIENT_SECURE_CONNECTION <> 0 then
    Pkt := Pkt + AnsiChar(Length(Resp)) + Resp
  else
    Pkt := Pkt + Resp + #0;
  if Flags and CLIENT_CONNECT_WITH_DB <> 0 then
    Pkt := Pkt + Database + #0;
  if Flags and CLIENT_PLUGIN_AUTH <> 0 then
    Pkt := Pkt + Plugin + #0;
  WritePacket(Pkt);

  { OK, an error, a switch to another method, or more of the same method }
  while True do
  begin
    Reply := ReadPacket;
    if Reply = '' then
      raise EMyError.CreateCode(0, 'the database server closed the login');
    case Byte(Reply[1]) of
      $00:
        Exit;
      $FF:
        ServerError(Reply);
      $FE:
        begin
          if Length(Reply) = 1 then
            raise EMyError.CreateCode(0, 'the server wants the pre-4.1 password method, which is not safe and not supported');
          Z := 2;
          while (Z <= Length(Reply)) and (Reply[Z] <> #0) do
            Inc(Z);
          Plugin := Copy(Reply, 2, Z - 2);
          Nonce := Copy(Reply, Z + 1, MaxInt);
          if (Nonce <> '') and (Nonce[Length(Nonce)] = #0) then
            SetLength(Nonce, Length(Nonce) - 1);
          WritePacket(Answer(Plugin, Nonce));
        end;
      $01:
        begin
          Data := Copy(Reply, 2, MaxInt);
          if Plugin = 'caching_sha2_password' then
          begin
            if Data = #3 then
              Continue                             { the server knew the password: OK follows }
            else if Data = #4 then
            begin
              if Password = '' then
                WritePacket(#0)
              else if FPublicKey <> '' then
                WritePacket(Encrypted(FPublicKey, Nonce))
              else
                WritePacket(#2);                   { send your public key, please }
            end
            else if Pos('-----BEGIN', Data) > 0 then
              WritePacket(Encrypted(Data, Nonce))
            else
              raise EMyError.CreateCode(0, 'the database server answered the login in a way this client does not know');
          end
          else if Plugin = 'sha256_password' then
          begin
            if Pos('-----BEGIN', Data) > 0 then
              WritePacket(Encrypted(Data, Nonce))
            else
              raise EMyError.CreateCode(0, 'the database server answered the login in a way this client does not know');
          end
          else
            raise EMyError.CreateCode(0, 'the database server answered the login in a way this client does not know');
        end;
    else
      raise EMyError.CreateCode(0, 'the database server answered the login in a way this client does not know');
    end;
  end;
end;

procedure TMyConnection.Connect;
var
  S: TInetSocket;
begin
  Close;
  if FAborted then
    raise EMyError.CreateCode(0, 'the connection was cut: the server is shutting down');
  if Trim(Host) = '' then
    raise EMyError.CreateCode(0, 'no database host is set');
  try
    S := TInetSocket.Create(Host, Port, ConnectTimeoutMs);
  except
    on E: Exception do
      raise EMyError.CreateCode(0, Format('cannot reach the database at %s:%d (%s)', [Host, Port, E.Message]));
  end;
  { a write to a connection the server has closed fails instead of raising SIGPIPE }
  {$IFDEF LINUX}S.WriteFlags := MSG_NOSIGNAL;{$ENDIF}
  EnterCriticalSection(FLock);
  try
    FSock := S;
  finally
    LeaveCriticalSection(FLock);
  end;
  if FAborted then
  begin
    Drop;
    raise EMyError.CreateCode(0, 'the connection was cut: the server is shutting down');
  end;
  try
    FSock.IOTimeout := IOTimeoutMs;
    FSeq := 0;
    Authenticate(ReadPacket);
    { the login already asked for utf8mb4; this makes sure of it on servers that ignore that }
    Exec('SET NAMES utf8mb4');
  except
    { a public key that did not work (the server may have new ones) is asked for again }
    FPublicKey := '';
    Drop;
    raise;
  end;
end;

procedure TMyConnection.Close;
var
  Quit: AnsiString;
begin
  if FSock = nil then
    Exit;
  try
    FSeq := 0;
    Quit := AnsiChar(COM_QUIT);
    WritePacket(Quit);
  except
  end;
  Drop;
end;

function TMyConnection.Send(const SQL: AnsiString): AnsiString;
begin
  if FSock = nil then
    raise EMyError.CreateCode(0, 'not connected');
  FSeq := 0;
  WritePacket(AnsiChar(COM_QUERY) + SQL);
  Result := ReadPacket;
  if Result = '' then
    raise EMyError.CreateCode(0, 'the database server sent an empty answer');
  if Byte(Result[1]) = $FF then
    ServerError(Result);
end;

procedure TMyConnection.ReadColumns(const First: AnsiString; var Names: array of AnsiString);
var
  i, P: LongInt;
  Pkt: AnsiString;
begin
  for i := 0 to High(Names) do
  begin
    Pkt := ReadPacket;
    { the server may stop with an error instead of the next column; the answer ends there }
    if (Pkt <> '') and (Byte(Pkt[1]) = $FF) then
      ServerError(Pkt);
    P := 1;
    LenEncStr(Pkt, P);                             { catalog }
    LenEncStr(Pkt, P);                             { schema }
    LenEncStr(Pkt, P);                             { table }
    LenEncStr(Pkt, P);                             { original table }
    Names[i] := LenEncStr(Pkt, P);
  end;
  { the end of the column list }
  Pkt := ReadPacket;
  if (Pkt <> '') and (Byte(Pkt[1]) = $FF) then
    ServerError(Pkt);
end;

function TMyConnection.ReadRows(const First: AnsiString): TMyResult;
var
  Cols, P: LongInt;
  Pkt: AnsiString;
  Row: TMyRow;
  Nul: TMyNulls;
begin
  Result := TMyResult.Create;
  try
    P := 1;
    Cols := LenEnc(First, P);
    if (Cols < 1) or (Cols > MAX_COLUMNS) then
    begin
      Drop;
      raise EMyError.CreateCode(0, 'the database server sent an answer this client cannot read');
    end;
    SetLength(Result.FColumns, Cols);
    ReadColumns(First, Result.FColumns);
    Nul := nil;
    SetLength(Nul, Cols);
    while True do
    begin
      Pkt := ReadPacket;
      if (Pkt <> '') and (Byte(Pkt[1]) = $FE) and (Length(Pkt) < 9) then
        Break;
      if (Pkt <> '') and (Byte(Pkt[1]) = $FF) then
        ServerError(Pkt);
      Row := nil;
      SetLength(Row, Cols);
      ParseRow(Pkt, Row, Nul);
      Result.AddRow(Row, Nul);
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TMyConnection.Exec(const SQL: AnsiString);
var
  First: AnsiString;
  P: LongInt;
begin
  First := Send(SQL);
  if Byte(First[1]) = $00 then
  begin
    P := 2;
    FAffected := LenEnc(First, P);
  end
  else if Byte(First[1]) = $FB then
  begin
    { the server now waits for the file: the connection is out of step, so it is closed }
    Drop;
    raise EMyError.CreateCode(0, 'the database server asked for a local file, which is never sent');
  end
  else
    ReadRows(First).Free;
end;

function TMyConnection.Query(const SQL: AnsiString): TMyResult;
var
  First: AnsiString;
  P: LongInt;
begin
  First := Send(SQL);
  if Byte(First[1]) = $00 then
  begin
    P := 2;
    FAffected := LenEnc(First, P);
    Result := TMyResult.Create;
  end
  else if Byte(First[1]) = $FB then
  begin
    Drop;
    raise EMyError.CreateCode(0, 'the database server asked for a local file, which is never sent');
  end
  else
    Result := ReadRows(First);
end;

function TMyConnection.Open(const SQL: AnsiString): TMyCursor;
var
  First: AnsiString;
  P, Cols: LongInt;
begin
  First := Send(SQL);
  if Byte(First[1]) = $FB then
  begin
    Drop;
    raise EMyError.CreateCode(0, 'the database server asked for a local file, which is never sent');
  end;
  Result := TMyCursor.Create;
  Result.FConn := Self;
  if Byte(First[1]) = $00 then
  begin
    Result.FDone := True;
    Exit;
  end;
  try
    P := 1;
    Cols := LenEnc(First, P);
    if (Cols < 1) or (Cols > MAX_COLUMNS) then
    begin
      Drop;
      raise EMyError.CreateCode(0, 'the database server sent an answer this client cannot read');
    end;
    SetLength(Result.FColumns, Cols);
    ReadColumns(First, Result.FColumns);
    SetLength(Result.FRow, Cols);
    SetLength(Result.FNull, Cols);
  except
    Result.FDone := True;
    Result.Free;
    raise;
  end;
end;

function TMyConnection.Usable: Boolean;
begin
  Result := False;
  if FSock = nil then
    Exit;
  if FAborted or WaitReadable(PtrInt(FSock.Handle), 0) then
  begin
    Drop;
    Exit;
  end;
  Result := True;
end;

function TMyConnection.Ping: Boolean;
var
  R: AnsiString;
begin
  Result := False;
  if FSock = nil then
    Exit;
  try
    FSeq := 0;
    WritePacket(AnsiChar(COM_PING));
    R := ReadPacket;
    Result := (R <> '') and (Byte(R[1]) = $00);
  except
    Drop;
  end;
end;

{ ---------------- tables ---------------- }

procedure MyPrepareTable(Conn: TMyConnection; const Table: AnsiString; const Cols: array of AnsiString;
  const Keys: AnsiString);
var
  SQL, Name: AnsiString;
  R: TMyResult;
  Have: TStringList;
  i, Sp: LongInt;
begin
  SQL := 'CREATE TABLE IF NOT EXISTS ' + Table + ' (';
  for i := 0 to High(Cols) do
  begin
    if i > 0 then
      SQL := SQL + ', ';
    SQL := SQL + Cols[i];
  end;
  if Keys <> '' then
    SQL := SQL + ', ' + Keys;
  { InnoDB whatever the server's default engine is: the writers take turns by row locks inside
    transactions, which the other engines do not give }
  Conn.Exec(SQL + ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
  Have := TStringList.Create;
  try
    R := Conn.Query('SHOW COLUMNS FROM ' + Table);
    try
      Have.CaseSensitive := False;
      for i := 0 to R.RowCount - 1 do
        Have.Add(R.Str(i, 0));
      for i := 0 to High(Cols) do
      begin
        Sp := Pos(' ', Cols[i]);
        if Sp = 0 then
          Continue;
        Name := Copy(Cols[i], 1, Sp - 1);
        if Have.IndexOf(Name) < 0 then
          try
            Conn.Exec('ALTER TABLE ' + Table + ' ADD COLUMN ' + Cols[i]);
          except
            { another server that started at the same moment added it first (1060, duplicate
              column name): the table is as it should be }
            on Ex: EMyError do
              if Ex.Code <> 1060 then
                raise;
          end;
      end;
    finally
      R.Free;
    end;
  finally
    Have.Free;
  end;
end;

{ ---------------- batches ---------------- }

constructor TMyBatch.Create(Conn: TMyConnection; const Head, Tail: AnsiString; LimitBytes: LongInt);
begin
  inherited Create;
  FConn := Conn;
  FHead := Head;
  FTail := Tail;
  FLimit := LimitBytes;
  FBuf := '';
end;

procedure TMyBatch.Add(const Values: AnsiString);
begin
  if (FRows > 0) and (Length(FBuf) + Length(Values) + Length(FHead) + Length(FTail) > FLimit) then
    Flush;
  if FRows > 0 then
    FBuf := FBuf + ', ' + Values
  else
    FBuf := Values;
  Inc(FRows);
end;

procedure TMyBatch.Flush;
begin
  if FRows = 0 then
    Exit;
  FConn.Exec(FHead + ' ' + FBuf + ' ' + FTail);
  Inc(FTotal, FRows);
  FRows := 0;
  FBuf := '';
end;

end.
