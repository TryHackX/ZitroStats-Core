program test_fuzz;

{ Damaged and hostile input must never crash the library: a torn or scrambled database, a journal
  full of noise and a settings file with random text. Everything is expected to be refused with a
  message, never with an exception. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_fileio, zs_config, zs_fields, zs_store, zs_rank, zs_db;

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

procedure CleanDir(const Dir: AnsiString);
var
  L: TStringList;
  i: LongInt;
begin
  EnsureDir(Dir);
  L := ListFiles(Dir, '*');
  for i := 0 to L.Count - 1 do
    DeleteFile(IncludeTrailingPathDelimiter(Dir) + L[i]);
  L.Free;
end;

function WaitCommit(IO: TStoreIO; Tag: LongInt): Boolean;
var
  R: TStoreResult;
  Deadline: Int64;
begin
  Deadline := MonoMs + 30000;
  repeat
    while IO.PollResult(R) do
      if (R.Kind = sjSnapshotCommit) and (R.Tag = Tag) then
        Exit(R.Ok);
    Sleep(2);
  until MonoMs > Deadline;
  Result := False;
end;

{ a small but complete database on disk, the starting point for every mutation }
procedure MakeGood(const Dir: AnsiString);
var
  DB: TStatsDB;
  IO: TStoreIO;
  W: TStoreWriter;
  i, n: LongInt;
begin
  CleanDir(Dir);
  DB := TStatsDB.Create;
  DB.SetNow(Now);
  for i := 1 to 200 do
  begin
    n := DB.CreateProfile('Fuzz' + IntToStr(i), 'S' + IntToStr(70000 + i), 'HW' + IntToStr(i), '10.0.0.1', 1000);
    DB.Profiles[n]^.Kills := i;
    DB.RefreshRanks(n);
  end;
  DB.FindMap('ctf_Ash', True);
  IO := TStoreIO.Create(Dir, 'fuzz.zsdb', 'fuzz.journal');
  W := TStoreWriter.Create(IO, 0);
  DB.BeginSnapshot(W);
  while not DB.ContinueSnapshot(W, 64) do ;
  W.CommitSnapshot(1, '');
  WaitCommit(IO, 1);
  DB.Profiles[0]^.Kills := 999;
  DB.Touch(0);
  DB.FlushJournal(W, True);
  while not IO.Idle do
    Sleep(2);
  W.Free;
  IO.Free;
  DB.Free;
end;

function ReadFileText(const Path: AnsiString): AnsiString;
begin
  if not ReadWholeFile(Path, Result) then
    Result := '';
end;

{ every load attempt has to end in a result, never in an exception }
function TryLoad(const Dir: AnsiString; out Res: TStoreLoadResult): Boolean;
var
  St: TStoreState;
  Info: TStoreLoadInfo;
begin
  Result := True;
  try
    Res := StoreLoad(Dir, 'fuzz.zsdb', 'fuzz.journal', St, Info);
    ClearStoreState(St);
  except
    on E: Exception do
    begin
      WriteLn('       exception: ', E.ClassName, ': ', E.Message);
      Res := slFailed;
      Result := False;
    end;
  end;
end;

var
  Dir, Path, Good, Broken, Line: AnsiString;
  Res: TStoreLoadResult;
  Survived: Boolean;
  i, k, At: LongInt;
  Loaded, Refused: LongInt;
  Cfg: TZSConfig;
  Warn, L: TStringList;
begin
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'fuzz_tmp');
  Path := IncludeTrailingPathDelimiter(Dir) + 'fuzz.zsdb';
  RandSeed := 20260916;

  MakeGood(Dir);
  Check('the intact database loads', TryLoad(Dir, Res) and (Res = slLoaded));
  Good := ReadFileText(Path);
  Check('the snapshot file is there', Length(Good) > 500);

  Survived := True;
  for i := 1 to 60 do
  begin
    WriteFileAtomic(Path, Copy(Good, 1, Random(Length(Good)) + 1), False);
    if not TryLoad(Dir, Res) then
      Survived := False;
  end;
  Check('a truncated snapshot never raises', Survived);

  Survived := True;
  Loaded := 0;
  Refused := 0;
  for i := 1 to 120 do
  begin
    Broken := Good;
    for k := 1 to 1 + Random(8) do
    begin
      At := 1 + Random(Length(Broken));
      Broken[At] := AnsiChar(Random(256));
    end;
    WriteFileAtomic(Path, Broken, False);
    if not TryLoad(Dir, Res) then
      Survived := False;
    if Res = slLoaded then
      Inc(Loaded)
    else
      Inc(Refused);
  end;
  Check('scrambled bytes never raise', Survived);
  Check('a scrambled snapshot is usually refused', Refused > 0);
  WriteLn(Format('       of 120 scrambled files: %d refused, %d still readable', [Refused, Loaded]));

  { a journal of pure noise next to a good snapshot }
  MakeGood(Dir);
  Survived := True;
  for i := 1 to 40 do
  begin
    SetLength(Broken, 200 + Random(2000));
    for k := 1 to Length(Broken) do
      Broken[k] := AnsiChar(Random(256));
    WriteFileAtomic(IncludeTrailingPathDelimiter(Dir) + 'fuzz.journal.000000002', Broken, False);
    if not TryLoad(Dir, Res) then
      Survived := False;
  end;
  Check('a journal full of noise never raises', Survived);

  CleanDir(Dir);
  Check('an empty folder means an empty database', TryLoad(Dir, Res) and (Res = slEmpty));
  WriteFileAtomic(Path, '', False);
  Check('an empty file is refused, not read as empty data', TryLoad(Dir, Res) and (Res = slFailed));

  { settings files of random text }
  Survived := True;
  for i := 1 to 100 do
  begin
    L := TStringList.Create;
    try
      for k := 1 to 1 + Random(30) do
      begin
        Line := '';
        for At := 1 to 1 + Random(40) do
          Line := Line + AnsiChar(32 + Random(96));
        L.Add(Line);
      end;
      L.SaveToFile(IncludeTrailingPathDelimiter(Dir) + 'fuzz.ini');
    finally
      L.Free;
    end;
    SetConfigDefaults(Cfg);
    Warn := TStringList.Create;
    try
      try
        LoadConfigFile(IncludeTrailingPathDelimiter(Dir) + 'fuzz.ini', Cfg, Warn);
      except
        on E: Exception do
        begin
          WriteLn('       exception: ', E.ClassName, ': ', E.Message);
          Survived := False;
        end;
      end;
    finally
      Warn.Free;
    end;
    if (Cfg.MaxPointGive < 1) or (Cfg.StartingPoints < 0) or (Cfg.JournalFlushSeconds < 1) then
      Survived := False;
  end;
  Check('random settings files never raise and keep sane values', Survived);

  { a misspelt section is reported once, a wrong Engine leaves the older switch in charge }
  L := TStringList.Create;
  try
    L.Add('[Mysqll]');
    L.Add('Engine = mysql');
    L.Add('Host = db.example.com');
    L.Add('Port = 3307');
    L.Add('[MySQL]');
    L.Add('Engine = maybe');
    L.Add('Enabled = 1');
    L.Add('[Database]');
    L.Add('Type = sql');
    L.Add('[General]');
    L.Add('SourceCodepage = 1251');
    L.SaveToFile(IncludeTrailingPathDelimiter(Dir) + 'fuzz.ini');
  finally
    L.Free;
  end;
  SetConfigDefaults(Cfg);
  Warn := TStringList.Create;
  try
    LoadConfigFile(IncludeTrailingPathDelimiter(Dir) + 'fuzz.ini', Cfg, Warn);
    for k := 0 to Warn.Count - 1 do
      WriteLn('       ', Warn[k]);
    Check('an unknown section is reported once, a wrong value by its name',
      (Warn.Count = 4) and (Pos('[mysqll] is not a known section', Warn.Text) > 0) and
      (Pos('not local, mirror or mysql', Warn.Text) > 0) and (Pos('not file or mysql', Warn.Text) > 0) and
      (Pos('names are read as Latin-1', Warn.Text) > 0) and (Cfg.SourceCodepage = 1251));
    Check('the older switch still works after a wrong Engine', (Cfg.MySQLEngine = MYSQL_MIRROR) and Cfg.MySQLEnabled and
      (Cfg.MySQLPort = 3306));
  finally
    Warn.Free;
  end;

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
