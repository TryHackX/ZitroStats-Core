unit zs_util;

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF UNIX}BaseUnix, Unix,{$ENDIF}
  SysUtils, Classes, Math;

type
  TIntArray = array of LongInt;
  TSha256Digest = array[0..31] of Byte;

  TSha256Ctx = record
    H: array[0..7] of LongWord;
    Buf: array[0..63] of Byte;
    BufLen: Integer;
    TotalLen: QWord;
  end;

  THmacSha256 = record
    Inner, Outer: TSha256Ctx;
  end;

  { String key -> list of integer values (profile IDs). Keys are compared case-insensitively. }
  TStrIndexEntry = record
    Key: AnsiString;
    Hash: LongWord;
    Value: LongInt;
  end;

  TStrIndex = class
  private
    FBuckets: array of array of TStrIndexEntry;
    FCount: Integer;
    procedure Grow;
  public
    constructor Create(InitialBuckets: Integer = 1024);
    procedure Clear;
    procedure Add(const Key: AnsiString; Value: LongInt);
    procedure Remove(const Key: AnsiString; Value: LongInt);
    function Find(const Key: AnsiString): TIntArray;
    function FindFirst(const Key: AnsiString): LongInt;
    property Count: Integer read FCount;
  end;

procedure GuardWorkerThread;

{ Checksums and hashing }
function Crc32Update(Crc: LongWord; Data: PByte; Len: PtrInt): LongWord;
function Crc32Buf(Data: PByte; Len: PtrInt): LongWord;
function Crc32Str(const S: AnsiString): LongWord;
function Fnv1aLower(const S: AnsiString): LongWord;

procedure Sha256Init(out Ctx: TSha256Ctx);
procedure Sha256Update(var Ctx: TSha256Ctx; Data: PByte; Len: PtrInt);
procedure Sha256Final(var Ctx: TSha256Ctx; out Digest: TSha256Digest);
function Sha256Str(const Data: AnsiString): TSha256Digest;
procedure HmacInit(out H: THmacSha256; const Key: AnsiString);
procedure HmacCompute(const H: THmacSha256; Data: PByte; Len: PtrInt; out Digest: TSha256Digest);
function HmacSha256(const Key, Data: AnsiString): TSha256Digest;
function Pbkdf2Sha256(const Password, Salt: AnsiString; Iterations, DKLen: Integer): AnsiString;
function DigestToStr(const D: TSha256Digest): AnsiString;
function BytesToHex(const S: AnsiString): AnsiString;
function HexToBytes(const H: AnsiString): AnsiString;
function ConstantTimeEquals(const A, B: AnsiString): Boolean;

{ Lower end of the Wilson score interval: a share seen only a few times stays near zero, so
  3 headshots out of 3 hits do not beat 600 out of 1000. }
function WilsonLower(Successes, Trials: Int64; Z: Double = 1.96): Double;

{ Randomness }
function SecureRandomBytes(Count: Integer): AnsiString;
function RandomCode(Len: Integer): AnsiString;

{ Strings }
function LowerAscii(const S: AnsiString): AnsiString;
function SplitWords(const S: AnsiString; MaxParts: Integer = 0): TStringArray;
function RestAfterWords(const S: AnsiString; WordCount: Integer): AnsiString;
function IsValidEmail(const S: AnsiString): Boolean;
function IsPrintableNoSpace(const S: AnsiString): Boolean;
function SanitizeText(const S: AnsiString; MaxLen: Integer): AnsiString;
function CpToUtf8(const S: AnsiString; CodePage: Integer): AnsiString;
function JsonStr(const Utf8: AnsiString): AnsiString;
function FloatStr(V: Double; Decimals: Integer): AnsiString;
function PadR(const S: AnsiString; Width: Integer): AnsiString;
function PadL(const S: AnsiString; Width: Integer): AnsiString;
function FormatDuration(Sec: Int64): AnsiString;
function FormatDurationShort(Sec: Int64): AnsiString;

{ Time }
function MonoMs: Int64;
function MicroNow: Int64;
function DayKey(const T: TDateTime): LongInt;
function WeekKey(const T: TDateTime): LongInt;
function MonthKey(const T: TDateTime): LongInt;
function UnixNow: Int64;

{ Math }
function SafeDivD(A, B: Double): Double;
function Ratio(A, B: Double): Double;
procedure WilsonInterval(Success, Total: Int64; out Lo, Hi: Double);
function ClampI(V, Lo, Hi: LongInt): LongInt;
function ClampD(V, Lo, Hi: Double): Double;

implementation

var
  CrcTable: array[0..255] of LongWord;

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

  { Windows-1250 bytes $80..$FF as Unicode code points (0 = undefined, mapped to '?'). }
  CP1250: array[$80..$FF] of Word = (
    $20AC, $0000, $201A, $0000, $201E, $2026, $2020, $2021, $0000, $2030, $0160, $2039, $015A, $0164, $017D, $0179,
    $0000, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $0000, $2122, $0161, $203A, $015B, $0165, $017E, $017A,
    $00A0, $02C7, $02D8, $0141, $00A4, $0104, $00A6, $00A7, $00A8, $00A9, $015E, $00AB, $00AC, $00AD, $00AE, $017B,
    $00B0, $00B1, $02DB, $0142, $00B4, $00B5, $00B6, $00B7, $00B8, $0105, $015F, $00BB, $013D, $02DD, $013E, $017C,
    $0154, $00C1, $00C2, $0102, $00C4, $0139, $0106, $00C7, $010C, $00C9, $0118, $00CB, $011A, $00CD, $00CE, $010E,
    $0110, $0143, $0147, $00D3, $00D4, $0150, $00D6, $00D7, $0158, $016E, $00DA, $0170, $00DC, $00DD, $0162, $00DF,
    $0155, $00E1, $00E2, $0103, $00E4, $013A, $0107, $00E7, $010D, $00E9, $0119, $00EB, $011B, $00ED, $00EE, $010F,
    $0111, $0144, $0148, $00F3, $00F4, $0151, $00F6, $00F7, $0159, $016F, $00FA, $0171, $00FC, $00FD, $0163, $02D9);

  { Windows-1252 bytes $80..$9F (the rest of the upper half equals Latin-1). }
  CP1252: array[$80..$9F] of Word = (
    $20AC, $0000, $201A, $0192, $201E, $2026, $2020, $2021, $02C6, $2030, $0160, $2039, $0152, $0000, $017D, $0000,
    $0000, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $02DC, $2122, $0161, $203A, $0153, $0000, $017E, $0178);

{$IFDEF WINDOWS}
function RtlGenRandom(RandomBuffer: Pointer; RandomBufferLength: ULONG): ByteBool; stdcall;
  external 'advapi32.dll' name 'SystemFunction036';
{$ENDIF}

procedure InitCrcTable;
var
  i, j: Integer;
  c: LongWord;
begin
  for i := 0 to 255 do
  begin
    c := LongWord(i);
    for j := 0 to 7 do
      if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1) else c := c shr 1;
    CrcTable[i] := c;
  end;
end;

function Crc32Update(Crc: LongWord; Data: PByte; Len: PtrInt): LongWord;
var
  i: PtrInt;
begin
  Result := not Crc;
  for i := 0 to Len - 1 do
    Result := CrcTable[(Result xor Data[i]) and $FF] xor (Result shr 8);
  Result := not Result;
end;

function Crc32Buf(Data: PByte; Len: PtrInt): LongWord;
begin
  Result := Crc32Update(0, Data, Len);
end;

function Crc32Str(const S: AnsiString): LongWord;
begin
  if S = '' then Exit(0);
  Result := Crc32Update(0, PByte(PAnsiChar(S)), Length(S));
end;

function Fnv1aLower(const S: AnsiString): LongWord;
var
  i: Integer;
  c: Byte;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
  begin
    c := Ord(S[i]);
    if (c >= 65) and (c <= 90) then Inc(c, 32);
    Result := (Result xor c) * 16777619;
  end;
end;

{ ---------------- SHA-256 ---------------- }

function Rol(X: LongWord; N: Byte): LongWord; inline;
begin
  Result := (X shl N) or (X shr (32 - N));
end;

procedure Sha256Compress(var Ctx: TSha256Ctx; Block: PByte);
var
  W: array[0..63] of LongWord;
  a, b, c, d, e, f, g, h, t1, t2: LongWord;
  i: Integer;
begin
  for i := 0 to 15 do
    W[i] := (LongWord(Block[i * 4]) shl 24) or (LongWord(Block[i * 4 + 1]) shl 16) or
            (LongWord(Block[i * 4 + 2]) shl 8) or LongWord(Block[i * 4 + 3]);
  for i := 16 to 63 do
  begin
    t1 := Rol(W[i - 2], 32 - 17) xor Rol(W[i - 2], 32 - 19) xor (W[i - 2] shr 10);
    t2 := Rol(W[i - 15], 32 - 7) xor Rol(W[i - 15], 32 - 18) xor (W[i - 15] shr 3);
    W[i] := t1 + W[i - 7] + t2 + W[i - 16];
  end;
  a := Ctx.H[0]; b := Ctx.H[1]; c := Ctx.H[2]; d := Ctx.H[3];
  e := Ctx.H[4]; f := Ctx.H[5]; g := Ctx.H[6]; h := Ctx.H[7];
  for i := 0 to 63 do
  begin
    t1 := h + (Rol(e, 32 - 6) xor Rol(e, 32 - 11) xor Rol(e, 32 - 25)) + ((e and f) xor ((not e) and g)) + K256[i] + W[i];
    t2 := (Rol(a, 32 - 2) xor Rol(a, 32 - 13) xor Rol(a, 32 - 22)) + ((a and b) xor (a and c) xor (b and c));
    h := g; g := f; f := e; e := d + t1;
    d := c; c := b; b := a; a := t1 + t2;
  end;
  Inc(Ctx.H[0], a); Inc(Ctx.H[1], b); Inc(Ctx.H[2], c); Inc(Ctx.H[3], d);
  Inc(Ctx.H[4], e); Inc(Ctx.H[5], f); Inc(Ctx.H[6], g); Inc(Ctx.H[7], h);
end;

procedure Sha256Init(out Ctx: TSha256Ctx);
begin
  Ctx.H[0] := $6a09e667; Ctx.H[1] := $bb67ae85; Ctx.H[2] := $3c6ef372; Ctx.H[3] := $a54ff53a;
  Ctx.H[4] := $510e527f; Ctx.H[5] := $9b05688c; Ctx.H[6] := $1f83d9ab; Ctx.H[7] := $5be0cd19;
  Ctx.BufLen := 0;
  Ctx.TotalLen := 0;
  FillChar(Ctx.Buf, SizeOf(Ctx.Buf), 0);
end;

procedure Sha256Update(var Ctx: TSha256Ctx; Data: PByte; Len: PtrInt);
var
  Take: PtrInt;
begin
  Inc(Ctx.TotalLen, QWord(Len));
  while Len > 0 do
  begin
    if (Ctx.BufLen = 0) and (Len >= 64) then
    begin
      Sha256Compress(Ctx, Data);
      Inc(Data, 64);
      Dec(Len, 64);
      Continue;
    end;
    Take := 64 - Ctx.BufLen;
    if Take > Len then Take := Len;
    Move(Data^, Ctx.Buf[Ctx.BufLen], Take);
    Inc(Ctx.BufLen, Take);
    Inc(Data, Take);
    Dec(Len, Take);
    if Ctx.BufLen = 64 then
    begin
      Sha256Compress(Ctx, @Ctx.Buf[0]);
      Ctx.BufLen := 0;
    end;
  end;
end;

procedure Sha256Final(var Ctx: TSha256Ctx; out Digest: TSha256Digest);
var
  BitLen: QWord;
  Pad: array[0..71] of Byte;
  PadLen, i: Integer;
begin
  BitLen := Ctx.TotalLen * 8;
  FillChar(Pad, SizeOf(Pad), 0);
  Pad[0] := $80;
  if Ctx.BufLen < 56 then PadLen := 56 - Ctx.BufLen else PadLen := 120 - Ctx.BufLen;
  for i := 0 to 7 do
    Pad[PadLen + i] := Byte(BitLen shr (56 - 8 * i));
  Sha256Update(Ctx, @Pad[0], PadLen + 8);
  for i := 0 to 7 do
  begin
    Digest[i * 4] := Byte(Ctx.H[i] shr 24);
    Digest[i * 4 + 1] := Byte(Ctx.H[i] shr 16);
    Digest[i * 4 + 2] := Byte(Ctx.H[i] shr 8);
    Digest[i * 4 + 3] := Byte(Ctx.H[i]);
  end;
end;

function Sha256Str(const Data: AnsiString): TSha256Digest;
var
  Ctx: TSha256Ctx;
begin
  Sha256Init(Ctx);
  if Data <> '' then Sha256Update(Ctx, PByte(PAnsiChar(Data)), Length(Data));
  Sha256Final(Ctx, Result);
end;

procedure HmacInit(out H: THmacSha256; const Key: AnsiString);
var
  K: array[0..63] of Byte;
  Pad: array[0..63] of Byte;
  D: TSha256Digest;
  i: Integer;
begin
  FillChar(K, SizeOf(K), 0);
  if Length(Key) > 64 then
  begin
    D := Sha256Str(Key);
    Move(D[0], K[0], 32);
  end
  else if Key <> '' then
    Move(Key[1], K[0], Length(Key));
  for i := 0 to 63 do Pad[i] := K[i] xor $36;
  Sha256Init(H.Inner);
  Sha256Update(H.Inner, @Pad[0], 64);
  for i := 0 to 63 do Pad[i] := K[i] xor $5C;
  Sha256Init(H.Outer);
  Sha256Update(H.Outer, @Pad[0], 64);
end;

procedure HmacCompute(const H: THmacSha256; Data: PByte; Len: PtrInt; out Digest: TSha256Digest);
var
  Ctx: TSha256Ctx;
  InnerD: TSha256Digest;
begin
  Ctx := H.Inner;
  if Len > 0 then Sha256Update(Ctx, Data, Len);
  Sha256Final(Ctx, InnerD);
  Ctx := H.Outer;
  Sha256Update(Ctx, @InnerD[0], 32);
  Sha256Final(Ctx, Digest);
end;

function HmacSha256(const Key, Data: AnsiString): TSha256Digest;
var
  H: THmacSha256;
begin
  HmacInit(H, Key);
  HmacCompute(H, PByte(PAnsiChar(Data)), Length(Data), Result);
end;

function Pbkdf2Sha256(const Password, Salt: AnsiString; Iterations, DKLen: Integer): AnsiString;
var
  H: THmacSha256;
  Block, i, j, Take: Integer;
  U, T: TSha256Digest;
  SaltBlock: AnsiString;
begin
  Result := '';
  if Iterations < 1 then Iterations := 1;
  HmacInit(H, Password);
  Block := 1;
  while Length(Result) < DKLen do
  begin
    SaltBlock := Salt + Chr((Block shr 24) and $FF) + Chr((Block shr 16) and $FF) + Chr((Block shr 8) and $FF) + Chr(Block and $FF);
    HmacCompute(H, PByte(PAnsiChar(SaltBlock)), Length(SaltBlock), U);
    T := U;
    for i := 2 to Iterations do
    begin
      HmacCompute(H, @U[0], 32, U);
      for j := 0 to 31 do T[j] := T[j] xor U[j];
    end;
    Take := DKLen - Length(Result);
    if Take > 32 then Take := 32;
    SetLength(Result, Length(Result) + Take);
    Move(T[0], Result[Length(Result) - Take + 1], Take);
    Inc(Block);
  end;
end;

function WilsonLower(Successes, Trials: Int64; Z: Double = 1.96): Double;
var
  P, Denom, Centre, Margin: Double;
begin
  if (Trials <= 0) or (Successes <= 0) then
    Exit(0);
  P := Successes / Trials;
  Denom := 1 + Z * Z / Trials;
  Centre := P + Z * Z / (2 * Trials);
  Margin := Z * Sqrt(P * (1 - P) / Trials + Z * Z / (4 * Trials * Trials));
  Result := (Centre - Margin) / Denom;
  if Result < 0 then
    Result := 0;
end;

function DigestToStr(const D: TSha256Digest): AnsiString;
begin
  SetLength(Result, 32);
  Move(D[0], Result[1], 32);
end;

function BytesToHex(const S: AnsiString): AnsiString;
const
  Hex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(S) * 2);
  for i := 1 to Length(S) do
  begin
    Result[i * 2 - 1] := Hex[Ord(S[i]) shr 4];
    Result[i * 2] := Hex[Ord(S[i]) and 15];
  end;
end;

function HexToBytes(const H: AnsiString): AnsiString;
  function Nib(c: AnsiChar): Integer;
  begin
    case c of
      '0'..'9': Result := Ord(c) - 48;
      'a'..'f': Result := Ord(c) - 87;
      'A'..'F': Result := Ord(c) - 55;
      else Result := -1;
    end;
  end;
var
  i, a, b: Integer;
begin
  Result := '';
  if Odd(Length(H)) then Exit;
  SetLength(Result, Length(H) div 2);
  for i := 1 to Length(Result) do
  begin
    a := Nib(H[i * 2 - 1]);
    b := Nib(H[i * 2]);
    if (a < 0) or (b < 0) then Exit('');
    Result[i] := Chr(a * 16 + b);
  end;
end;

function ConstantTimeEquals(const A, B: AnsiString): Boolean;
var
  i: Integer;
  Diff: Byte;
begin
  if Length(A) <> Length(B) then Exit(False);
  Diff := 0;
  for i := 1 to Length(A) do
    Diff := Diff or (Ord(A[i]) xor Ord(B[i]));
  Result := Diff = 0;
end;

{ ---------------- Random ---------------- }

function SecureRandomBytes(Count: Integer): AnsiString;
{$IFDEF UNIX}
var
  F: THandle;
  Got, R: Integer;
{$ENDIF}
var
  i: Integer;
begin
  SetLength(Result, Count);
  if Count <= 0 then Exit('');
  {$IFDEF WINDOWS}
  if RtlGenRandom(@Result[1], Count) then Exit;
  {$ENDIF}
  {$IFDEF UNIX}
  F := FpOpen('/dev/urandom', O_RDONLY);
  if F >= 0 then
  begin
    Got := 0;
    while Got < Count do
    begin
      R := FpRead(F, Result[Got + 1], Count - Got);
      if R <= 0 then Break;
      Inc(Got, R);
    end;
    FpClose(F);
    if Got = Count then Exit;
  end;
  {$ENDIF}
  { Last resort: never reached on supported platforms. }
  Randomize;
  for i := 1 to Count do
    Result[i] := Chr(Random(256) xor Byte(MicroNow shr (i mod 17)));
end;

function RandomCode(Len: Integer): AnsiString;
const
  Alphabet: AnsiString = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
var
  R: AnsiString;
  i: Integer;
begin
  R := SecureRandomBytes(Len);
  SetLength(Result, Len);
  for i := 1 to Len do
    Result[i] := Alphabet[1 + (Ord(R[i]) mod Length(Alphabet))];
end;

{ ---------------- Strings ---------------- }

function LowerAscii(const S: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if (Result[i] >= 'A') and (Result[i] <= 'Z') then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function SplitWords(const S: AnsiString; MaxParts: Integer): TStringArray;
var
  i, n, Start: Integer;
begin
  Result := nil;
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] <= ' ') do Inc(i);
    if i > Length(S) then Break;
    Start := i;
    if (MaxParts > 0) and (n = MaxParts - 1) then
    begin
      SetLength(Result, n + 1);
      Result[n] := TrimRight(Copy(S, Start, MaxInt));
      Exit;
    end;
    while (i <= Length(S)) and (S[i] > ' ') do Inc(i);
    SetLength(Result, n + 1);
    Result[n] := Copy(S, Start, i - Start);
    Inc(n);
  end;
end;

function RestAfterWords(const S: AnsiString; WordCount: Integer): AnsiString;
var
  i, w: Integer;
begin
  i := 1;
  for w := 1 to WordCount do
  begin
    while (i <= Length(S)) and (S[i] <= ' ') do Inc(i);
    while (i <= Length(S)) and (S[i] > ' ') do Inc(i);
  end;
  Result := Trim(Copy(S, i, MaxInt));
end;

function IsValidEmail(const S: AnsiString): Boolean;
var
  AtPos, i, LabelLen, Dots: Integer;
  Local, Domain: AnsiString;
  c: AnsiChar;
begin
  Result := False;
  if (Length(S) < 6) or (Length(S) > 80) then Exit;
  AtPos := Pos('@', S);
  if (AtPos <= 1) or (AtPos <> LastDelimiter('@', S)) then Exit;
  Local := Copy(S, 1, AtPos - 1);
  Domain := Copy(S, AtPos + 1, MaxInt);
  if (Length(Local) > 64) or (Length(Domain) < 4) then Exit;
  if (Local[1] = '.') or (Local[Length(Local)] = '.') or (Pos('..', Local) > 0) then Exit;
  for i := 1 to Length(Local) do
  begin
    c := Local[i];
    if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '.', '_', '%', '+', '-']) then Exit;
  end;
  LabelLen := 0;
  Dots := 0;
  for i := 1 to Length(Domain) do
  begin
    c := Domain[i];
    if c = '.' then
    begin
      if (LabelLen = 0) or (Domain[i - 1] = '-') then Exit;
      LabelLen := 0;
      Inc(Dots);
    end
    else if c in ['a'..'z', 'A'..'Z', '0'..'9', '-'] then
    begin
      if (LabelLen = 0) and (c = '-') then Exit;
      Inc(LabelLen);
      if LabelLen > 63 then Exit;
    end
    else
      Exit;
  end;
  if (Dots = 0) or (LabelLen < 2) then Exit;
  for i := Length(Domain) - LabelLen + 1 to Length(Domain) do
    if not (Domain[i] in ['a'..'z', 'A'..'Z']) then Exit;
  Result := True;
end;

function IsPrintableNoSpace(const S: AnsiString): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if (Ord(S[i]) <= 32) or (Ord(S[i]) >= 127) then Exit(False);
end;

function SanitizeText(const S: AnsiString; MaxLen: Integer): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if Ord(S[i]) >= 32 then
      Result := Result + S[i];
  if (MaxLen > 0) and (Length(Result) > MaxLen) then
    SetLength(Result, MaxLen);
end;

procedure AppendUtf8(var R: AnsiString; CP: LongWord);
begin
  if CP < $80 then
    R := R + Chr(CP)
  else if CP < $800 then
    R := R + Chr($C0 or (CP shr 6)) + Chr($80 or (CP and $3F))
  else
    R := R + Chr($E0 or (CP shr 12)) + Chr($80 or ((CP shr 6) and $3F)) + Chr($80 or (CP and $3F));
end;

{ the length of the well-formed UTF-8 sequence at S[i], 0 when the byte does not start one }
function Utf8SeqLen(const S: AnsiString; i: Integer): Integer;
var
  b, n, k: Integer;
  CP: LongWord;
begin
  Result := 0;
  b := Ord(S[i]);
  if b < $80 then
    Exit(1);
  if (b >= $C2) and (b <= $DF) then
    n := 2
  else if (b >= $E0) and (b <= $EF) then
    n := 3
  else if (b >= $F0) and (b <= $F4) then
    n := 4
  else
    Exit;
  if i + n - 1 > Length(S) then
    Exit;
  CP := LongWord(b) and ($FF shr (n + 1));
  for k := 1 to n - 1 do
  begin
    if (Ord(S[i + k]) and $C0) <> $80 then
      Exit;
    CP := (CP shl 6) or LongWord(Ord(S[i + k]) and $3F);
  end;
  { overlong forms, surrogates and code points above U+10FFFF are not UTF-8 }
  if ((n = 3) and (CP < $800)) or ((n = 4) and ((CP < $10000) or (CP > $10FFFF))) or
     ((CP >= $D800) and (CP <= $DFFF)) then
    Exit;
  Result := n;
end;

function CpToUtf8(const S: AnsiString; CodePage: Integer): AnsiString;
var
  i, n: Integer;
  b: Byte;
  CP: LongWord;
begin
  Result := '';
  if CodePage = 65001 then
  begin
    { the text is UTF-8 already: a stray byte would make the JSON, the webhook or the mail
      invalid, so every byte that is not part of a complete sequence becomes '?' }
    i := 1;
    while i <= Length(S) do
    begin
      n := Utf8SeqLen(S, i);
      if n = 1 then
      begin
        if Ord(S[i]) >= 32 then
          Result := Result + S[i];
      end
      else if n > 1 then
        Result := Result + Copy(S, i, n)
      else
      begin
        Result := Result + '?';
        n := 1;
      end;
      Inc(i, n);
    end;
    Exit;
  end;
  for i := 1 to Length(S) do
  begin
    b := Ord(S[i]);
    if b < $80 then
    begin
      if b >= 32 then Result := Result + S[i];
      Continue;
    end;
    case CodePage of
      1250: CP := CP1250[b];
      1252: if b <= $9F then CP := CP1252[b] else CP := b;
      else CP := b; { ISO-8859-1 }
    end;
    if CP = 0 then CP := Ord('?');
    AppendUtf8(Result, CP);
  end;
end;

function JsonStr(const Utf8: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '"';
  for i := 1 to Length(Utf8) do
  begin
    c := Utf8[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      else
        if Ord(c) < 32 then
          Result := Result + '\u' + IntToHex(Ord(c), 4)
        else
          Result := Result + c;
    end;
  end;
  Result := Result + '"';
end;

function FloatStr(V: Double; Decimals: Integer): AnsiString;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  if IsNan(V) or IsInfinite(V) then V := 0;
  Result := FloatToStrF(V, ffFixed, 18, Decimals, FS);
end;

function PadR(const S: AnsiString; Width: Integer): AnsiString;
begin
  if Length(S) >= Width then Result := S
  else Result := S + StringOfChar(' ', Width - Length(S));
end;

function PadL(const S: AnsiString; Width: Integer): AnsiString;
begin
  if Length(S) >= Width then Result := S
  else Result := StringOfChar(' ', Width - Length(S)) + S;
end;

function FormatDuration(Sec: Int64): AnsiString;
var
  D, H, M, S: Int64;
begin
  if Sec < 0 then Sec := 0;
  D := Sec div 86400; Sec := Sec mod 86400;
  H := Sec div 3600; Sec := Sec mod 3600;
  M := Sec div 60; S := Sec mod 60;
  if D > 0 then Result := Format('%dd %dh %dm', [D, H, M])
  else if H > 0 then Result := Format('%dh %dm %ds', [H, M, S])
  else if M > 0 then Result := Format('%dm %ds', [M, S])
  else Result := Format('%ds', [S]);
end;

function FormatDurationShort(Sec: Int64): AnsiString;
var
  D, H, M: Int64;
begin
  if Sec < 0 then Sec := 0;
  D := Sec div 86400;
  H := (Sec mod 86400) div 3600;
  M := (Sec mod 3600) div 60;
  if D > 0 then Result := Format('%dd %dh', [D, H])
  else if H > 0 then Result := Format('%dh %dm', [H, M])
  else if M > 0 then Result := Format('%dm %ds', [M, Sec mod 60])
  else Result := Format('%ds', [Sec]);
end;

{ ---------------- Time ---------------- }

function MonoMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;

function MicroNow: Int64;
{$IFDEF WINDOWS}
var
  C, F: Int64;
begin
  if QueryPerformanceFrequency(F) and (F > 0) and QueryPerformanceCounter(C) then
    Result := Trunc(C / F * 1000000.0)
  else
    Result := Int64(GetTickCount64) * 1000;
end;
{$ELSE}
var
  TV: TTimeVal;
begin
  fpgettimeofday(@TV, nil);
  Result := Int64(TV.tv_sec) * 1000000 + TV.tv_usec;
end;
{$ENDIF}

function DayKey(const T: TDateTime): LongInt;
begin
  Result := Trunc(T);
end;

function WeekKey(const T: TDateTime): LongInt;
var
  Y, W, DOW: Word;
  D: TDateTime;
begin
  { ISO-8601 week: Thursday of the week decides the year. }
  DOW := DayOfWeek(T); { 1 = Sunday }
  if DOW = 1 then DOW := 7 else Dec(DOW);
  D := Trunc(T) - (DOW - 1) + 3;
  Y := StrToIntDef(FormatDateTime('yyyy', D), 1970);
  W := (Trunc(D) - Trunc(EncodeDate(Y, 1, 1))) div 7 + 1;
  Result := Y * 100 + W;
end;

function MonthKey(const T: TDateTime): LongInt;
var
  Y, M, D: Word;
begin
  DecodeDate(T, Y, M, D);
  Result := Y * 100 + M;
end;

{ seconds since 1970 in UTC: Now is the local time, GetLocalTimeOffset the minutes to UTC }
function UnixNow: Int64;
begin
  Result := Round((Now + GetLocalTimeOffset / 1440 - EncodeDate(1970, 1, 1)) * 86400.0);
end;

{ ---------------- Math ---------------- }

function SafeDivD(A, B: Double): Double;
begin
  if Abs(B) < 1e-9 then Result := 0 else Result := A / B;
end;

function Ratio(A, B: Double): Double;
begin
  if Abs(B) < 1e-9 then Result := A else Result := A / B;
end;

procedure WilsonInterval(Success, Total: Int64; out Lo, Hi: Double);
const
  Z = 1.96;
var
  P, Den, Centre, Margin: Double;
begin
  if Total <= 0 then
  begin
    Lo := 0; Hi := 0;
    Exit;
  end;
  P := Success / Total;
  Den := 1 + Z * Z / Total;
  Centre := P + Z * Z / (2 * Total);
  Margin := Z * Sqrt(P * (1 - P) / Total + Z * Z / (4.0 * Total * Total));
  Lo := Max(0, (Centre - Margin) / Den);
  Hi := Min(1, (Centre + Margin) / Den);
end;

function ClampI(V, Lo, Hi: LongInt): LongInt;
begin
  if V < Lo then Result := Lo else if V > Hi then Result := Hi else Result := V;
end;

function ClampD(V, Lo, Hi: Double): Double;
begin
  if V < Lo then Result := Lo else if V > Hi then Result := Hi else Result := V;
end;

{ ---------------- TStrIndex ---------------- }

constructor TStrIndex.Create(InitialBuckets: Integer);
var
  n: Integer;
begin
  inherited Create;
  n := 16;
  while n < InitialBuckets do n := n * 2;
  SetLength(FBuckets, n);
  FCount := 0;
end;

procedure TStrIndex.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FBuckets) do
    SetLength(FBuckets[i], 0);
  FCount := 0;
end;

procedure TStrIndex.Grow;
var
  Old: array of array of TStrIndexEntry;
  i, j, b, n: Integer;
begin
  Old := FBuckets;
  SetLength(FBuckets, 0);
  SetLength(FBuckets, Length(Old) * 2);
  for i := 0 to High(Old) do
    for j := 0 to High(Old[i]) do
    begin
      b := Old[i][j].Hash and LongWord(High(FBuckets));
      n := Length(FBuckets[b]);
      SetLength(FBuckets[b], n + 1);
      FBuckets[b][n] := Old[i][j];
    end;
end;

procedure TStrIndex.Add(const Key: AnsiString; Value: LongInt);
var
  H: LongWord;
  b, n, j: Integer;
  LKey: AnsiString;
begin
  if Key = '' then Exit;
  LKey := LowerAscii(Key);
  H := Fnv1aLower(LKey);
  b := H and LongWord(High(FBuckets));
  for j := 0 to High(FBuckets[b]) do
    if (FBuckets[b][j].Hash = H) and (FBuckets[b][j].Value = Value) and (FBuckets[b][j].Key = LKey) then
      Exit;
  n := Length(FBuckets[b]);
  SetLength(FBuckets[b], n + 1);
  FBuckets[b][n].Key := LKey;
  FBuckets[b][n].Hash := H;
  FBuckets[b][n].Value := Value;
  Inc(FCount);
  if FCount > Length(FBuckets) * 2 then Grow;
end;

procedure TStrIndex.Remove(const Key: AnsiString; Value: LongInt);
var
  H: LongWord;
  b, j, n: Integer;
  LKey: AnsiString;
begin
  if Key = '' then Exit;
  LKey := LowerAscii(Key);
  H := Fnv1aLower(LKey);
  b := H and LongWord(High(FBuckets));
  n := Length(FBuckets[b]);
  for j := 0 to n - 1 do
    if (FBuckets[b][j].Hash = H) and (FBuckets[b][j].Value = Value) and (FBuckets[b][j].Key = LKey) then
    begin
      FBuckets[b][j] := FBuckets[b][n - 1];
      SetLength(FBuckets[b], n - 1);
      Dec(FCount);
      Exit;
    end;
end;

function TStrIndex.Find(const Key: AnsiString): TIntArray;
var
  H: LongWord;
  b, j, n: Integer;
  LKey: AnsiString;
begin
  Result := nil;
  if Key = '' then Exit;
  LKey := LowerAscii(Key);
  H := Fnv1aLower(LKey);
  b := H and LongWord(High(FBuckets));
  n := 0;
  for j := 0 to High(FBuckets[b]) do
    if (FBuckets[b][j].Hash = H) and (FBuckets[b][j].Key = LKey) then
    begin
      SetLength(Result, n + 1);
      Result[n] := FBuckets[b][j].Value;
      Inc(n);
    end;
end;

function TStrIndex.FindFirst(const Key: AnsiString): LongInt;
var
  R: TIntArray;
begin
  R := Find(Key);
  if Length(R) > 0 then Result := R[0] else Result := -1;
end;

{ The first line of every worker thread. On Linux the server takes its own signal handlers back
  once the library is loaded, so a floating point error on a worker would end the whole server
  instead of raising an exception the worker catches; there the worker gets NaN and infinity
  instead. Windows keeps its exceptions. }
procedure GuardWorkerThread;
begin
  {$IFDEF UNIX}
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  {$ENDIF}
end;

{$IFDEF UNIX}
{ A write to a connection the other side has closed (MySQL, a web request, the mail pipe) raises
  SIGPIPE on Linux, and a SIGPIPE nobody catches ends the whole server. It is ignored instead,
  unless the server installed a handler of its own; the write then simply fails. }
procedure IgnoreBrokenPipes;
var
  Cur, Act: SigActionRec;
begin
  FillChar(Cur, SizeOf(Cur), 0);
  if FPSigaction(SIGPIPE, nil, @Cur) <> 0 then Exit;
  if PPointer(@Cur.sa_handler)^ <> nil then Exit;
  FillChar(Act, SizeOf(Act), 0);
  PPointer(@Act.sa_handler)^ := Pointer(1);   { SIG_IGN }
  FPSigaction(SIGPIPE, @Act, nil);
end;
{$ENDIF}

initialization
  InitCrcTable;
  {$IFDEF UNIX}IgnoreBrokenPipes;{$ENDIF}

end.
