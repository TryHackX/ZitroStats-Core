program test_crash;

{ zs_crash: exceptions are written with code, module and trail, the program still handles them
  itself, and repeats at the same address are limited. Caught Pascal exceptions are no crash and
  are not written; other software exceptions (C++) are told apart by the place that raised them. }

{$mode objfpc}{$H+}

uses
  Windows, SysUtils, Classes, zs_crash;

var
  Failures: Integer = 0;

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

function Occurrences(const Sub, S: AnsiString): LongInt;
var
  p: LongInt;
begin
  Result := 0;
  p := Pos(Sub, S);
  while p > 0 do
  begin
    Inc(Result);
    p := Pos(Sub, S, p + Length(Sub));
  end;
end;

procedure WriteNil;
var
  P: PLongInt;
begin
  P := nil;
  P^ := 1;
end;

{ a C++ exception as a throw raises it, from two places }
procedure ThrowHere;
begin
  RaiseException($E06D7363, 0, 0, nil);
end;

procedure ThrowThere;
begin
  RaiseException($E06D7363, 0, 0, nil);
end;

function SetUnhandledExceptionFilter(Filter: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'SetUnhandledExceptionFilter';

type
  TFilterFunc = function(P: PExceptionPointers): LongInt; stdcall;

var
  DummyCalls: LongInt = 0;

{ stands for the filter the server had before the library: counts and lets Windows decide }
function DummyFilter(P: PExceptionPointers): LongInt; stdcall;
begin
  Inc(DummyCalls);
  Result := 0;
end;

var
  Dir, Text: AnsiString;
  L: TStringList;
  Caught: Boolean;
  i, n: LongInt;
  Filter: Pointer;
  Rec: TExceptionRecord;
  Ptrs: TExceptionPointers;
begin
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'crash_tmp');
  ForceDirectories(Dir);
  if FileExists(Dir + PathDelim + 'crash.log') then
    DeleteFile(Dir + PathDelim + 'crash.log');
  SetUnhandledExceptionFilter(@DummyFilter);
  CrashInstall(Dir, 'ZitroStats test');
  CrashTrail('before fault', 7, 8);
  CrashTrail('script action', 3, 1);
  CrashTrail('script action', 3, 1);
  Check('log file active', CrashLogFile <> '');

  Caught := False;
  try
    WriteNil;
  except
    on E: EAccessViolation do
      Caught := True;
  end;
  Check('the program still handles the access violation itself', Caught);

  for i := 1 to 6 do
    try
      WriteNil;
    except
    end;

  { Pascal exceptions that the program catches, from several places (Free Pascal 3.2 raises them
    all through RaiseException with the code E0465043) }
  n := 0;
  for i := 1 to 4 do
    try
      raise Exception.Create('caught');
    except
      Inc(n);
    end;
  try
    i := StrToInt('abc');
  except
    on E: EConvertError do
      Inc(n);
  end;
  try
    L := TStringList.Create;
    try
      L.LoadFromFile(Dir + PathDelim + 'no such file.txt');
    finally
      L.Free;
    end;
  except
    Inc(n);
  end;
  Check('the program catches its own Pascal exceptions (6)', n = 6);

  { C++ exceptions: four from one place, one from another }
  n := 0;
  for i := 1 to 4 do
    try
      ThrowHere;
    except
      Inc(n);
    end;
  try
    ThrowThere;
  except
    Inc(n);
  end;
  Check('the program catches the C++ exceptions too (5)', n = 5);

  L := TStringList.Create;
  try
    L.LoadFromFile(CrashLogFile);
    Text := L.Text;
  finally
    L.Free;
  end;
  Check('header with FPU state', (Pos('ZitroStats test diagnostics started', Text) > 0) and (Pos('FPU control word', Text) > 0));
  Check('code and name', Pos('code C0000005 (access violation)', Text) > 0);
  Check('faulting module and offset', Pos('test_crash.exe+', Text) > 0);
  Check('written address', Pos('writing 00000000', Text) > 0);
  Check('thread named', Pos('thread game', Text) > 0);
  Check('trail with repeat count', (Pos('before fault 7 8', Text) > 0) and (Pos('script action 3 1 (x2)', Text) > 0));
  Check('stack trace', Pos('frames: ', Text) > 0);
  Check('same address written three times at most', Occurrences('code C0000005', Text) = 3);
  Check('a caught Pascal exception is no crash: not written', Occurrences('E0465043', Text) = 0);
  Check(Format('a C++ exception: three from one place, one from the other (%d)', [Occurrences('code E06D7363', Text)]),
    Occurrences('code E06D7363 (C++ exception)', Text) = 4);
  Check('a C++ exception names the place that raised it', Occurrences('raised from test_crash.exe+', Text) = 4);

  { a Pascal exception nothing caught reaches the process's last filter: written once, then the filter
    that was there before decides }
  Filter := SetUnhandledExceptionFilter(nil);
  SetUnhandledExceptionFilter(Filter);
  Check('the unhandled-exception filter is the library''s, not the one before', (Filter <> nil) and
    (Filter <> Pointer(@DummyFilter)));
  FillChar(Rec, SizeOf(Rec), 0);
  Rec.ExceptionCode := $E0465043;
  Ptrs.ExceptionRecord := @Rec;
  Ptrs.ContextRecord := nil;
  if Filter <> nil then
    TFilterFunc(Filter)(@Ptrs);
  Check('the filter before it decides as it did (called once)', DummyCalls = 1);
  L := TStringList.Create;
  try
    L.LoadFromFile(CrashLogFile);
    Text := L.Text;
  finally
    L.Free;
  end;
  Check('an uncaught Pascal exception is written once, marked', (Occurrences('E0465043', Text) = 1) and
    (Pos('not caught by any handler', Text) > 0));

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
