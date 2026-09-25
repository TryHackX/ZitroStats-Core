program test_crash;

{ zs_crash: exceptions are written with code, module and trail, the program still handles them
  itself, and repeats at the same address are limited. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, zs_crash;

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

var
  Dir, Text: AnsiString;
  L: TStringList;
  Caught: Boolean;
  i: LongInt;
begin
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'crash_tmp');
  ForceDirectories(Dir);
  if FileExists(Dir + PathDelim + 'crash.log') then
    DeleteFile(Dir + PathDelim + 'crash.log');
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

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
