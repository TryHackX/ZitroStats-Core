unit zs_crash;

{ Crash diagnostics for the whole server process.

  A vectored exception handler writes every serious exception raised in the process (by any
  module: the server, Steam, another script library or this one) to crash.log in the log folder:
  the exception code, the module and offset of the faulting instruction, the thread, the
  registers, a stack trace and the last things this library did. The handler only reads memory
  and appends to the file; it never changes how an exception is handled, so the server behaves
  exactly as it would without it. Pascal exceptions of this library and of the server do not go
  through Windows exception handling and are not written here.

  The same exception at the same address is written three times at most, and a run writes 300
  records at most. The handler also runs on threads this library does not know and while the
  heap may be damaged, so it uses no Pascal exception handling, threadvars or heap memory. }

{$mode objfpc}{$H+}
{$R-}{$Q-}{$S-}
{$IMPLICITEXCEPTIONS OFF}

interface

const
  CT_GAME = 1;
  CT_ENGINE = 2;
  CT_IO = 3;
  CT_SERVICE = 4;
  CT_MIRROR = 5;

{ Starts the handler (once per process) and writes a header with the FPU state and the owner of
  the process-wide unhandled exception filter. Called from the game thread. }
procedure CrashInstall(const Dir, Title: AnsiString);
{ Names the calling thread in the records (CT_* constant). }
procedure CrashThread(Kind: LongInt);
{ Remembers a step of the library; the last 32 steps are written with every record. }
procedure CrashTrail(const Tag: ShortString; A, B: LongInt);
{ Path of the log file, '' when the handler is not active. }
function CrashLogFile: AnsiString;

implementation

{$IFDEF WINDOWS}

uses
  Windows, SysUtils;

type
  PExcRecord = ^TExcRecord;
  TExcRecord = record
    Code, Flags: DWORD;
    Nested: PExcRecord;
    Address: Pointer;
    NumParams: DWORD;
    Info: array[0..14] of PtrUInt;
  end;

  PExcPointers = ^TExcPointers;
  TExcPointers = record
    Rec: PExcRecord;
    Ctx: PContext;
  end;

  TTrailEntry = record
    Time: DWORD;
    Thread: DWORD;
    A, B, Count: LongInt;
    Tag: string[23];
  end;

  TOut = record
    Len: LongInt;
    Data: array[0..7999] of Char;
  end;

const
  TRAIL_SIZE = 32;
  SEEN_SIZE = 64;
  MAX_RECORDS = 300;
  MAX_LOG_BYTES = 1024 * 1024;
  APPEND_DATA = 4;
  FROM_ADDRESS = 4;
  UNCHANGED_REFCOUNT = 2;

function AddVectoredExceptionHandler(First: ULONG; Handler: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'AddVectoredExceptionHandler';
function GetModuleHandleExA(Flags: DWORD; Addr: Pointer; out Module: HMODULE): BOOL; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleExA';
function SetUnhandledExceptionFilter(Filter: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'SetUnhandledExceptionFilter';
function Ticks32: DWORD; stdcall; external 'kernel32.dll' name 'GetTickCount';

var
  Handler: Pointer = nil;
  LogPath: array[0..MAX_PATH + 1] of Char;
  ThreadIds: array[CT_GAME..CT_MIRROR] of DWORD;
  Trail: array[0..TRAIL_SIZE - 1] of TTrailEntry;
  TrailPos: LongInt = -1;
  SeenCode: array[0..SEEN_SIZE - 1] of DWORD;
  SeenAddr: array[0..SEEN_SIZE - 1] of Pointer;
  SeenCount: array[0..SEEN_SIZE - 1] of LongInt;
  SeenUsed: LongInt = 0;
  Records: LongInt = 0;
  Busy: LongInt = 0;
  OutBuf: TOut;   { one record at a time, guarded by Busy }

procedure Put(var O: TOut; const S: ShortString);
var
  n: LongInt;
begin
  n := Length(S);
  if O.Len + n > High(O.Data) then
    n := High(O.Data) - O.Len;
  if n > 0 then
  begin
    Move(S[1], O.Data[O.Len], n);
    Inc(O.Len, n);
  end;
end;

function Num(V: Int64): ShortString;
begin
  Str(V, Result);
end;

function Two(V: LongInt): ShortString;
begin
  Str(V, Result);
  if Length(Result) < 2 then
    Result := '0' + Result;
end;

function Stamp: ShortString;
var
  T: TSystemTime;
  Ms: ShortString;
begin
  GetLocalTime(T);
  Str(T.wMilliseconds, Ms);
  while Length(Ms) < 3 do
    Ms := '0' + Ms;
  Result := Num(T.wYear) + '-' + Two(T.wMonth) + '-' + Two(T.wDay) + ' ' + Two(T.wHour) + ':' +
    Two(T.wMinute) + ':' + Two(T.wSecond) + '.' + Ms;
end;

{ module+offset of a code address, or the bare address outside any module }
function Where(Addr: Pointer): ShortString;
var
  M: HMODULE;
  Name: array[0..MAX_PATH] of Char;
  n, i, Start: LongInt;
begin
  Result := HexStr(PtrUInt(Addr), 8);
  M := 0;
  if (Addr = nil) or not GetModuleHandleExA(FROM_ADDRESS or UNCHANGED_REFCOUNT, Addr, M) or (M = 0) then
    Exit;
  n := GetModuleFileNameA(M, @Name[0], MAX_PATH);
  if n <= 0 then
    Exit;
  Start := 0;
  for i := 0 to n - 1 do
    if (Name[i] = '\') or (Name[i] = '/') then
      Start := i + 1;
  Result := '';
  for i := Start to n - 1 do
    if Length(Result) < 40 then
      Result := Result + Name[i];
  Result := Result + '+' + HexStr(PtrUInt(Addr) - PtrUInt(M), 8);
end;

function IsCode(Addr: PtrUInt): Boolean;
var
  Mbi: TMemoryBasicInformation;
begin
  Result := False;
  if Addr < $10000 then
    Exit;
  if VirtualQuery(Pointer(Addr), Mbi, SizeOf(Mbi)) <> SizeOf(Mbi) then
    Exit;
  Result := (Mbi.State = MEM_COMMIT) and
    ((Mbi.Protect and (PAGE_EXECUTE or PAGE_EXECUTE_READ or PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_WRITECOPY)) <> 0);
end;

{$asmmode intel}
procedure StackBounds(out Lo, Hi: PtrUInt);
var
  L, H: PtrUInt;
begin
  asm
    mov eax, fs:[8]
    mov L, eax
    mov eax, fs:[4]
    mov H, eax
  end;
  Lo := L;
  Hi := H;
end;
{$asmmode default}

function ThreadName(Id: DWORD): ShortString;
begin
  if Id = ThreadIds[CT_GAME] then
    Result := 'game'
  else if Id = ThreadIds[CT_ENGINE] then
    Result := 'zs-engine'
  else if Id = ThreadIds[CT_IO] then
    Result := 'zs-io'
  else if Id = ThreadIds[CT_SERVICE] then
    Result := 'zs-service'
  else if Id = ThreadIds[CT_MIRROR] then
    Result := 'zs-mysql'
  else
    Result := 'other';
  Result := Result + ' ' + Num(Id);
end;

function Serious(Code: DWORD): Boolean;
begin
  { errors (C...) and software exceptions (E...: C++ and others), not .NET, debugger notices or
    thread naming }
  Result := ((Code and $F0000000) = $C0000000) or
    (((Code and $F0000000) = $E0000000) and (Code <> $E0434352));
end;

{ False when this exception at this address was written often enough already }
function FirstTimes(Code: DWORD; Addr: Pointer): Boolean;
var
  i: LongInt;
begin
  for i := 0 to SeenUsed - 1 do
    if (SeenCode[i] = Code) and (SeenAddr[i] = Addr) then
    begin
      Inc(SeenCount[i]);
      Exit(SeenCount[i] <= 3);
    end;
  if SeenUsed < SEEN_SIZE then
  begin
    SeenCode[SeenUsed] := Code;
    SeenAddr[SeenUsed] := Addr;
    SeenCount[SeenUsed] := 1;
    Inc(SeenUsed);
  end;
  Result := True;
end;

procedure WriteOut(var O: TOut);
var
  H: THandle;
  W: DWORD;
begin
  if LogPath[0] = #0 then
    Exit;
  H := CreateFileA(@LogPath[0], APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit;
  WriteFile(H, O.Data[0], O.Len, W, nil);
  CloseHandle(H);
end;

function ExceptionName(Code: DWORD): ShortString;
begin
  case Code of
    $C0000005: Result := 'access violation';
    $C000001D: Result := 'illegal instruction';
    $C0000025: Result := 'noncontinuable exception: a handler tried to continue after a fatal error';
    $C000008C: Result := 'array bounds exceeded';
    $C000008D..$C0000093: Result := 'floating point error';
    $C0000094: Result := 'integer division by zero';
    $C0000095: Result := 'integer overflow';
    $C00000FD: Result := 'stack overflow';
    $C0000264: Result := 'critical section released by a thread that does not own it';
    $C0000374: Result := 'heap corruption';
    $C0000409: Result := 'stack buffer overrun';
    $C0000417: Result := 'invalid C runtime parameter';
    $C00002B4, $C00002B5: Result := 'floating point error (SSE)';
    $E06D7363: Result := 'C++ exception';
    else Result := '';
  end;
end;

procedure PutException(var O: TOut; R: PExcRecord; Depth: LongInt);
begin
  Put(O, 'code ' + HexStr(R^.Code, 8));
  if ExceptionName(R^.Code) <> '' then
    Put(O, ' (' + ExceptionName(R^.Code) + ')');
  Put(O, ' flags ' + HexStr(R^.Flags, 2) + ' at ' + Where(R^.Address));
  if (R^.Code = $C0000005) and (R^.NumParams >= 2) then
  begin
    case R^.Info[0] of
      0: Put(O, ', reading ');
      1: Put(O, ', writing ');
      8: Put(O, ', executing ');
      else Put(O, ', accessing ');
    end;
    Put(O, HexStr(R^.Info[1], 8));
  end;
  Put(O, #13#10);
  if (R^.Nested <> nil) and (Depth < 4) then
  begin
    Put(O, '  caused by: ');
    PutException(O, R^.Nested, Depth + 1);
  end;
end;

procedure BuildRecord(P: PExcPointers; var O: TOut);
var
  R: PExcRecord;
  C: PContext;
  Lo, Hi, Frame, Next, Slot, V: PtrUInt;
  i, k, Hits: LongInt;
  NowT, Ago: DWORD;
begin
  R := P^.Rec;
  C := P^.Ctx;
  O.Len := 0;
  Put(O, #13#10 + Stamp + '  thread ' + ThreadName(GetCurrentThreadId) + #13#10 + '  ');
  PutException(O, R, 0);
  if (C <> nil) and (R^.Code <> $C00000FD) then
  begin
    Put(O, '  eax ' + HexStr(C^.Eax, 8) + ' ebx ' + HexStr(C^.Ebx, 8) + ' ecx ' + HexStr(C^.Ecx, 8) +
      ' edx ' + HexStr(C^.Edx, 8) + ' esi ' + HexStr(C^.Esi, 8) + ' edi ' + HexStr(C^.Edi, 8) + #13#10);
    Put(O, '  eip ' + HexStr(C^.Eip, 8) + ' esp ' + HexStr(C^.Esp, 8) + ' ebp ' + HexStr(C^.Ebp, 8) + #13#10);
    StackBounds(Lo, Hi);
    { frame chain: reliable for Pascal code }
    Put(O, '  frames:');
    Frame := C^.Ebp;
    for i := 1 to 16 do
    begin
      if (Frame < Lo) or (Frame + 8 > Hi) or ((Frame and 3) <> 0) then
        Break;
      Put(O, ' ' + Where(Pointer(PPtrUInt(Frame + 4)^)));
      Next := PPtrUInt(Frame)^;
      if Next <= Frame then
        Break;
      Frame := Next;
    end;
    { code addresses on the stack: also covers code without frame pointers }
    Put(O, #13#10 + '  stack scan:');
    Slot := C^.Esp;
    Hits := 0;
    k := 0;
    while (k < 1024) and (Hits < 20) and (Slot >= Lo) and (Slot + 4 <= Hi) do
    begin
      V := PPtrUInt(Slot)^;
      if IsCode(V) then
      begin
        Put(O, ' ' + Where(Pointer(V)));
        Inc(Hits);
      end;
      Inc(Slot, 4);
      Inc(k);
    end;
    Put(O, #13#10);
  end;
  Put(O, '  last steps of ZitroStats (time before the exception, thread):' + #13#10);
  NowT := Ticks32;
  for i := 1 to TRAIL_SIZE do
  begin
    k := (TrailPos + i) and (TRAIL_SIZE - 1);
    if Trail[k].Time = 0 then
      Continue;
    Ago := NowT - Trail[k].Time;
    Put(O, '    -' + Num(Ago div 1000) + '.' + Num((Ago mod 1000) div 100) + 's ' + Trail[k].Tag + ' ' +
      Num(Trail[k].A) + ' ' + Num(Trail[k].B));
    if Trail[k].Count > 1 then
      Put(O, ' (x' + Num(Trail[k].Count) + ')');
    Put(O, ' [' + ThreadName(Trail[k].Thread) + ']' + #13#10);
  end;
end;

function OnException(P: PExcPointers): LongInt; stdcall;
var
  R: PExcRecord;
begin
  Result := 0; { EXCEPTION_CONTINUE_SEARCH: the other handlers decide what happens }
  R := P^.Rec;
  if (R = nil) or not Serious(R^.Code) or (Records >= MAX_RECORDS) then
    Exit;
  { one record at a time; an exception raised while a record is written is not written }
  if InterlockedCompareExchange(Busy, 1, 0) <> 0 then
    Exit;
  if FirstTimes(R^.Code, R^.Address) then
  begin
    Inc(Records);
    BuildRecord(P, OutBuf);
    WriteOut(OutBuf);
  end;
  Busy := 0;
end;

procedure CrashInstall(const Dir, Title: AnsiString);
var
  Path: AnsiString;
  Prev: Pointer;
  Info: TWin32FileAttributeData;
begin
  if (Handler <> nil) or (Dir = '') then
    Exit;
  ThreadIds[CT_GAME] := GetCurrentThreadId;
  Path := IncludeTrailingPathDelimiter(Dir);
  ForceDirectories(Path);
  Path := Path + 'crash.log';
  if Length(Path) > MAX_PATH then
    Exit;
  { keep one older file }
  if GetFileAttributesExA(PChar(Path), GetFileExInfoStandard, @Info) and (Info.nFileSizeLow > MAX_LOG_BYTES) then
    MoveFileExA(PChar(Path), PChar(Path + '.old'), MOVEFILE_REPLACE_EXISTING);
  FillChar(LogPath, SizeOf(LogPath), 0);
  Move(Path[1], LogPath[0], Length(Path));
  Prev := SetUnhandledExceptionFilter(nil);
  SetUnhandledExceptionFilter(Prev);
  OutBuf.Len := 0;
  Put(OutBuf, #13#10 + Stamp + '  ' + ShortString(Title) + ' diagnostics started, process ' + Num(GetCurrentProcessId) +
    ', game thread ' + Num(GetCurrentThreadId) + #13#10);
  Put(OutBuf, '  FPU control word ' + HexStr(Get8087CW, 4) + ', SSE control ' + HexStr(GetMXCSR, 8) +
    ', unhandled exception filter ' + Where(Prev) + #13#10);
  WriteOut(OutBuf);
  Handler := AddVectoredExceptionHandler(1, @OnException);
end;

procedure CrashThread(Kind: LongInt);
begin
  if (Kind >= CT_GAME) and (Kind <= CT_MIRROR) then
    ThreadIds[Kind] := GetCurrentThreadId;
end;

procedure CrashTrail(const Tag: ShortString; A, B: LongInt);
var
  k: LongInt;
  Me, NowT: DWORD;
begin
  Me := GetCurrentThreadId;
  NowT := Ticks32;
  k := TrailPos and (TRAIL_SIZE - 1);
  if (TrailPos >= 0) and (Trail[k].A = A) and (Trail[k].B = B) and (Trail[k].Thread = Me) and
     (NowT - Trail[k].Time < 2000) and (Trail[k].Tag = Tag) then
  begin
    Inc(Trail[k].Count);
    Trail[k].Time := NowT;
    Exit;
  end;
  k := InterlockedIncrement(TrailPos) and (TRAIL_SIZE - 1);
  Trail[k].Time := 0;
  Trail[k].Tag := Copy(Tag, 1, 23);
  Trail[k].A := A;
  Trail[k].B := B;
  Trail[k].Count := 1;
  Trail[k].Thread := Me;
  Trail[k].Time := NowT;
end;

function CrashLogFile: AnsiString;
begin
  if Handler = nil then
    Result := ''
  else
    Result := StrPas(@LogPath[0]);
end;

{$ELSE}

procedure CrashInstall(const Dir, Title: AnsiString);
begin
end;

procedure CrashThread(Kind: LongInt);
begin
end;

procedure CrashTrail(const Tag: ShortString; A, B: LongInt);
begin
end;

function CrashLogFile: AnsiString;
begin
  Result := '';
end;

{$ENDIF}

end.
