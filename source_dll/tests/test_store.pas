program test_store;

{ usage: test_store [profile count] [legacy data directory] }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, zs_types, zs_util, zs_fields, zs_fileio, zs_store, zs_legacy;

const
  SNAP = 'zitrostats.zsdb';
  JOUR = 'zitrostats.journal';

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

procedure MakeProfile(var P: TPlayerProfile; Id: LongInt);
begin
  ClearProfile(P);
  P.ID := Id;
  P.ActiveName := 'Player' + IntToStr(Id);
  P.ActiveHWID := 'HW' + IntToHex(Id * 7919, 8);
  P.Points := 1000 + Id mod 700;
  P.Kills := Id * 3;
  P.Deaths := Id * 2;
  P.TimePlayed := Id * 60;
  P.Weapons[Id mod WSLOT_COUNT].Kills := Id;
  P.Weapons[Id mod WSLOT_COUNT].Damage := Id * 12.5;
  P.LongestKillDistance := Id / 10;
  P.Glicko[0].R := 1500 + Id mod 300;
  SetLength(P.OtherNames, 1);
  FillChar(P.OtherNames[0], SizeOf(TOtherData), 0);
  SetOtherDataString(P.OtherNames[0], P.ActiveName);
  P.OtherNames[0].LoginCount := Id mod 50;
end;

procedure CleanDir(const Dir: AnsiString);
var
  L: TStringList;
  i: LongInt;
begin
  EnsureDir(Dir);
  L := ListFiles(Dir, '*');
  try
    for i := 0 to L.Count - 1 do
      DeleteFile(IncludeTrailingPathDelimiter(Dir) + L[i]);
  finally
    L.Free;
  end;
end;

function CountFiles(const Dir, Mask: AnsiString): LongInt;
var
  L: TStringList;
begin
  L := ListFiles(Dir, Mask);
  Result := L.Count;
  L.Free;
end;

function WaitIdle(IO: TStoreIO): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not IO.Idle do
  begin
    if MonoMs - T0 > 60000 then
      Exit(False);
    Sleep(2);
  end;
  Result := True;
end;

function WaitCommit(IO: TStoreIO; Tag: LongInt; out R: TStoreResult): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  repeat
    while IO.PollResult(R) do
    begin
      if (R.Kind = sjSnapshotCommit) and (R.Tag = Tag) then
      begin
        if not R.Ok then
          WriteLn('       io: ', R.Message);
        Exit(True);
      end;
      WriteLn('       io: ', R.Message);
    end;
    Sleep(2);
  until MonoMs - T0 > 60000;
  Result := False;
end;

procedure WriteFullSnapshot(W: TStoreWriter; const St: TStoreState; Tag: LongInt; const Backup: AnsiString);
var
  i: LongInt;
begin
  W.BeginSnapshot(St.ProfileCount, St.MapCount, Length(St.Seasons));
  W.SnapshotServer(St.Server);
  for i := 0 to High(St.Seasons) do
    W.SnapshotSeason(St.Seasons[i]);
  for i := 0 to St.MapCount - 1 do
    W.SnapshotMap(St.Maps[i]);
  for i := 0 to St.ProfileCount - 1 do
    if St.Profiles[i] <> nil then
      W.SnapshotProfile(St.Profiles[i]^);
  W.CommitSnapshot(Tag, Backup);
end;

function SameState(const A, B: TStoreState; out Why: string): Boolean;
var
  ById: array of LongInt;
  i, j, MaxId, Live: LongInt;
begin
  Result := False;
  Why := '';
  MaxId := 0;
  Live := 0;
  for i := 0 to A.ProfileCount - 1 do
    if A.Profiles[i] <> nil then
    begin
      Inc(Live);
      if A.Profiles[i]^.ID > MaxId then
        MaxId := A.Profiles[i]^.ID;
    end;
  for i := 0 to B.ProfileCount - 1 do
    if B.Profiles[i]^.ID > MaxId then
      MaxId := B.Profiles[i]^.ID;
  if Live <> B.ProfileCount then
  begin
    Why := Format('profile count %d <> %d', [Live, B.ProfileCount]);
    Exit;
  end;
  SetLength(ById, MaxId + 1);
  for i := 0 to High(ById) do
    ById[i] := -1;
  for i := 0 to A.ProfileCount - 1 do
    if A.Profiles[i] <> nil then
      ById[A.Profiles[i]^.ID] := i;
  for j := 0 to B.ProfileCount - 1 do
  begin
    if (B.Profiles[j] = nil) or (B.Profiles[j]^.ID <= 0) then
    begin
      Why := 'loaded profile without id';
      Exit;
    end;
    i := ById[B.Profiles[j]^.ID];
    if (i < 0) or (EncodeProfile(A.Profiles[i]^) <> EncodeProfile(B.Profiles[j]^)) then
    begin
      Why := 'profile ' + IntToStr(B.Profiles[j]^.ID) + ' differs';
      Exit;
    end;
  end;
  if A.MapCount <> B.MapCount then
  begin
    Why := 'map count';
    Exit;
  end;
  for i := 0 to A.MapCount - 1 do
    if EncodeMap(A.Maps[i]) <> EncodeMap(B.Maps[i]) then
    begin
      Why := 'map ' + IntToStr(A.Maps[i].ID) + ' differs';
      Exit;
    end;
  if EncodeServer(A.Server) <> EncodeServer(B.Server) then
  begin
    Why := 'server records differ';
    Exit;
  end;
  if Length(A.Seasons) <> Length(B.Seasons) then
  begin
    Why := 'season count';
    Exit;
  end;
  for i := 0 to High(A.Seasons) do
    if EncodeSeason(A.Seasons[i]) <> EncodeSeason(B.Seasons[i]) then
    begin
      Why := 'season differs';
      Exit;
    end;
  Result := True;
end;

procedure Report(const Why: string);
begin
  if Why <> '' then
    WriteLn('       ', Why);
end;

{ some file of the directory holds exactly this text }
function FileHolds(const Dir, Text: AnsiString): Boolean;
var
  L: TStringList;
  i: LongInt;
  Data: AnsiString;
begin
  Result := False;
  L := ListFiles(Dir, '*');
  try
    for i := 0 to L.Count - 1 do
      if ReadWholeFile(StorePath(Dir, L[i]), Data) and (Data = Text) then
        Exit(True);
  finally
    L.Free;
  end;
end;

{ the file is a journal of this store (its header, and records after it) }
function IsJournal(const Path: AnsiString): Boolean;
var
  Data: AnsiString;
  Magic: LongWord;
begin
  Result := ReadWholeFile(Path, Data) and (Length(Data) > STORE_HEADER_SIZE);
  if Result then
  begin
    Move(Data[1], Magic, 4);
    Result := Magic = JOURNAL_MAGIC;
  end;
end;

procedure DrainResults(IO: TStoreIO);
var
  R: TStoreResult;
begin
  while IO.PollResult(R) do
    if R.Message <> '' then
      WriteLn('       io: ', R.Message);
end;

var
  Dir, BackupDir, LegacyDir, Main, Backup, Data, Err, Dir2, Path1, Path2, Stamp1, Stamp2: AnsiString;
  N, i, Cnt, Ver, NextId, Reassigned: LongInt;
  St, L: TStoreState;
  Info: TStoreLoadInfo;
  IO, IO2: TStoreIO;
  W: TStoreWriter;
  R: TStoreResult;
  Holder, Holder2: TFileStream;
  Committed: Boolean;
  Why: string;
  T0: Int64;
  Profiles: TProfilePtrArray;
  Maps: TMapProfileArray;
  Srv: TServerRecords;
  Phantoms: Int64;
  Res: TStoreLoadResult;
  Hdr: array[0..6] of LongWord;
  Lp: TPlayerProfile;
begin
  N := StrToIntDef(ParamStr(1), 5000);
  LegacyDir := ParamStr(2);
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'store_tmp');
  BackupDir := Dir + PathDelim + 'backup';
  CleanDir(BackupDir);
  CleanDir(Dir);
  Why := '';

  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('empty directory loads as empty', Res = slEmpty);

  ClearStoreState(St);
  SetLength(St.Profiles, N + 16);
  St.ProfileCount := N;
  for i := 0 to N - 1 do
  begin
    St.Profiles[i] := NewProfile;
    MakeProfile(St.Profiles[i]^, i + 1);
  end;
  SetLength(St.Maps, 20);
  St.MapCount := 20;
  for i := 0 to 19 do
  begin
    ClearMap(St.Maps[i]);
    St.Maps[i].ID := i + 1;
    St.Maps[i].MapName := 'ctf_Map' + IntToStr(i);
    St.Maps[i].Kills := i * 100;
    SetLength(St.Maps[i].Heat, 2);
    St.Maps[i].Heat[0].Cell := 5;
    St.Maps[i].Heat[0].Kills := i;
    St.Maps[i].Heat[1].Cell := 9;
    St.Maps[i].Heat[1].Deaths := i;
  end;
  St.Server.PeakOnlineCount := 17;
  St.Server.Matchups[3, 2] := 5;
  St.Server.NextProfileID := N + 1;
  SetLength(St.Server.Daily, 1);
  St.Server.Daily[0].Day := 20260915;
  St.Server.Daily[0].Kills := 1234;
  SetLength(St.Seasons, 1);
  St.Seasons[0].Id := 1;
  St.Seasons[0].StartDate := 46000;
  St.Seasons[0].EndDate := 46030;
  SetLength(St.Seasons[0].Entries, 2);
  St.Seasons[0].Entries[0].Place := 1;
  St.Seasons[0].Entries[0].ProfileId := 3;
  St.Seasons[0].Entries[0].Name := 'Player3';
  St.Seasons[0].Entries[1].Place := 2;
  St.Seasons[0].Entries[1].ProfileId := 4;
  St.Seasons[0].Entries[1].Name := 'Player4';

  IO := TStoreIO.Create(Dir, SNAP, JOUR);
  Check('data directory lock acquired', IO.LockError = '');
  IO2 := TStoreIO.Create(Dir, SNAP, JOUR);
  Check('second instance is locked out', IO2.LockError <> '');
  IO2.Free;

  W := TStoreWriter.Create(IO, Info.MaxGen);
  T0 := MonoMs;
  WriteFullSnapshot(W, St, 1, '');
  Check('initial snapshot committed', WaitCommit(IO, 1, R) and R.Ok);
  WriteLn(Format('       snapshot of %d profiles: %d ms, %d KB', [N, MonoMs - T0, R.Bytes div 1024]));

  for i := 10 to 60 do
  begin
    Inc(St.Profiles[i]^.Kills, 100);
    W.JournalProfile(St.Profiles[i]^);
  end;
  St.Profiles[N] := NewProfile;
  MakeProfile(St.Profiles[N]^, N + 1);
  St.Profiles[N]^.ActiveName := 'Newcomer';
  St.ProfileCount := N + 1;
  W.JournalProfile(St.Profiles[N]^);
  W.JournalDeleteProfile(St.Profiles[4]^.ID);
  FreeProfile(St.Profiles[4]);
  St.Maps[3].Kills := 999;
  W.JournalMap(St.Maps[3]);
  St.Server.PeakOnlineCount := 21;
  W.JournalServer(St.Server);
  W.Flush;
  Check('journal written', WaitIdle(IO));
  W.Free;
  IO.Free;

  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('snapshot + journal load', (Res = slLoaded) and SameState(St, L, Why));
  Report(Why);
  Check('journal record count', Info.JournalRecords = 55);

  AppendToFile(JournalFileName(Dir, JOUR, Info.MaxGen), #2#100#0#0#0'torn');
  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('torn journal tail is ignored', (Res = slLoaded) and (Info.TornTails = 1) and SameState(St, L, Why));
  Report(Why);

  IO := TStoreIO.Create(Dir, SNAP, JOUR);
  W := TStoreWriter.Create(IO, Info.MaxGen);
  Inc(St.Profiles[7]^.Deaths, 5);
  W.JournalProfile(St.Profiles[7]^);
  W.Flush;
  WaitIdle(IO);
  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('next run continues in a new generation', (Res = slLoaded) and (Info.TornTails = 1) and SameState(St, L, Why));
  Report(Why);

  { snapshot written in pieces while changes keep arriving, with a backup }
  Backup := BackupDir + PathDelim + 'zitrostats-20260915-120000-test.zsdb';
  W.BeginSnapshot(St.ProfileCount, St.MapCount, Length(St.Seasons));
  W.SnapshotServer(St.Server);
  for i := 0 to High(St.Seasons) do
    W.SnapshotSeason(St.Seasons[i]);
  for i := 0 to St.MapCount - 1 do
    W.SnapshotMap(St.Maps[i]);
  for i := 0 to St.ProfileCount div 2 do
    if St.Profiles[i] <> nil then
      W.SnapshotProfile(St.Profiles[i]^);
  Inc(St.Profiles[20]^.Kills, 7);
  W.JournalProfile(St.Profiles[20]^);
  Inc(St.Profiles[St.ProfileCount - 5]^.Kills, 9);
  W.JournalProfile(St.Profiles[St.ProfileCount - 5]^);
  W.Flush;
  for i := St.ProfileCount div 2 + 1 to St.ProfileCount - 1 do
    if St.Profiles[i] <> nil then
      W.SnapshotProfile(St.Profiles[i]^);
  W.CommitSnapshot(2, Backup);
  Check('snapshot with backup committed', WaitCommit(IO, 2, R) and R.Ok);
  Check('backup file exists', FileExists(Backup));
  Check('previous snapshot kept', FileExists(StorePath(Dir, SNAP + '.prev')));

  T0 := MonoMs;
  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  WriteLn(Format('       load of %d profiles: %d ms', [L.ProfileCount, MonoMs - T0]));
  Check('state after chunked snapshot', (Res = slLoaded) and SameState(St, L, Why));
  Report(Why);
  Check('backup holds the same state', StoreLoadFile(Backup, L, Info) and SameState(St, L, Why));
  Report(Why);

  WriteFullSnapshot(W, St, 3, '');
  Check('third snapshot committed', WaitCommit(IO, 3, R) and R.Ok);
  W.Free;
  IO.Free;
  WriteLn('       journals left: ', CountFiles(Dir, '*.journal'));
  Check('old journals removed', CountFiles(Dir, '*.journal') <= 3);

  Main := StorePath(Dir, SNAP);
  ReadWholeFile(Main, Data);
  Data[Length(Data) div 2] := AnsiChar(Byte(Data[Length(Data) div 2]) xor $FF);
  WriteFileAtomic(Main, Data, False);
  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('damaged snapshot falls back to .prev', (Res = slLoaded) and (Pos('.prev', Info.Source) > 0) and SameState(St, L, Why));
  Report(Why);

  ReadWholeFile(Main + '.prev', Data);
  Data[Length(Data) div 2] := AnsiChar(Byte(Data[Length(Data) div 2]) xor $FF);
  WriteFileAtomic(Main + '.prev', Data, False);
  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('no usable snapshot is a hard failure', Res = slFailed);
  Check('damage is not taken for a newer format', not Info.NewerFormat);

  { a snapshot a newer build wrote: not readable here, but not damaged either }
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr[0] := SNAPSHOT_MAGIC;
  Hdr[1] := STORE_FORMAT + 1;
  Hdr[2] := 99;
  Hdr[6] := Crc32Buf(@Hdr[0], 24);
  SetLength(Data, 28);
  Move(Hdr[0], Data[1], 28);
  WriteFileAtomic(Main, Data + 'records of the future', False);
  Res := StoreLoad(Dir, SNAP, JOUR, L, Info);
  Check('a newer store format is named as such', (Res = slFailed) and Info.NewerFormat and
    (Pos('newer ZitroStats', Info.Messages) > 0));
  Check('a newer backup is named as such', not StoreLoadFile(Main, L, Info) and Info.NewerFormat);

  { nothing can be read, but the journals there still count: a backup restored over these files
    goes on above their numbers, so it never meets one of them as its own }
  Dir2 := Dir + PathDelim + 'j';
  CleanDir(Dir2);
  WriteFileAtomic(StorePath(Dir2, SNAP), 'no snapshot at all', False);
  WriteFileAtomic(JournalFileName(Dir2, JOUR, 3), 'journal three', False);
  WriteFileAtomic(JournalFileName(Dir2, JOUR, 5), 'journal five', False);
  Res := StoreLoad(Dir2, SNAP, JOUR, L, Info);
  Check('an unreadable store still names the journal numbers in use', (Res = slFailed) and (Info.MaxGen = 5));

  { a journal of an earlier run with the number the writer starts at, held open by another program:
    Windows then refuses to move it, but would let it be emptied - it is never emptied }
  CleanDir(Dir2);
  Path1 := JournalFileName(Dir2, JOUR, 1);
  WriteFileAtomic(Path1, 'records of an earlier run', False);
  Holder := TFileStream.Create(Path1, fmOpenRead or fmShareDenyNone);
  try
    IO := TStoreIO.Create(Dir2, SNAP, JOUR);
    W := TStoreWriter.Create(IO, 0);
    W.JournalProfile(St.Profiles[7]^);
    W.Flush;
    WaitIdle(IO);
    DrainResults(IO);
    Check('a journal that cannot be moved aside is kept, not emptied', FileHolds(Dir2, 'records of an earlier run'));
    { a snapshot with the number of another such journal: the next start would replay that journal
      over it, so it is not written, and the next number is used later }
    Path2 := JournalFileName(Dir2, JOUR, 2);
    WriteFileAtomic(Path2, 'another earlier journal', False);
    Holder2 := TFileStream.Create(Path2, fmOpenRead or fmShareDenyNone);
    try
      WriteFullSnapshot(W, St, 4, '');
      Committed := WaitCommit(IO, 4, R) and R.Ok;
      DrainResults(IO);
      Check('the journal of the snapshot''s number is kept as well', FileHolds(Dir2, 'another earlier journal'));
      Check('no snapshot is written over a journal of its number that is kept',
        not (Committed and ReadWholeFile(Path2, Data) and (Data = 'another earlier journal')));
    finally
      Holder2.Free;
    end;
  finally
    Holder.Free;
  end;
  WriteFullSnapshot(W, St, 5, '');
  Check('the next snapshot is written', WaitCommit(IO, 5, R) and R.Ok);
  W.Free;
  IO.Free;
  Res := StoreLoad(Dir2, SNAP, JOUR, L, Info);
  Check('the store reads back after the kept journals', (Res = slLoaded) and SameState(St, L, Why));
  Report(Why);

  { journals of one number moved aside twice in one second: both keep their records (a rename onto
    an existing file would replace it on Linux, and fail on Windows) }
  CleanDir(Dir2);
  Path1 := JournalFileName(Dir2, JOUR, 1);
  Stamp1 := Path1 + '.' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.old';
  Stamp2 := Path1 + '.' + FormatDateTime('yyyymmdd-hhnnss', Now + 1 / 86400) + '.old';
  WriteFileAtomic(Stamp1, 'moved aside before', False);
  WriteFileAtomic(Stamp2, 'moved aside before, too', False);
  WriteFileAtomic(Path1, 'records of an earlier run', False);
  IO := TStoreIO.Create(Dir2, SNAP, JOUR);
  W := TStoreWriter.Create(IO, 0);
  W.JournalProfile(St.Profiles[7]^);
  W.Flush;
  WaitIdle(IO);
  DrainResults(IO);
  W.Free;
  IO.Free;
  Check('a journal moved aside takes a name no other file has', FileHolds(Dir2, 'moved aside before') and
    FileHolds(Dir2, 'moved aside before, too') and FileHolds(Dir2, 'records of an earlier run') and IsJournal(Path1));

  { what 4.x kept only per weapon }
  ClearProfile(Lp);
  Lp.Weapons[2].Damage := 10;
  Lp.Weapons[5].Damage := 5.5;
  Lp.Weapons[5].DamageReceived := 7;
  Lp.LongestBarrettDistance := 42;
  Check('4.x totals are derived from the weapons', LegacyDeriveTotals(Lp) and (Abs(Lp.DamageDealt - 15.5) < 1e-9) and
    (Abs(Lp.DamageReceived - 7) < 1e-9) and (Abs(Lp.Weapons[8].LongestKill - 42) < 1e-6));
  Check('derived once', not LegacyDeriveTotals(Lp));
  Lp.DamageDealt := 15.2;
  Check('a rounding difference is left alone', not LegacyDeriveTotals(Lp) and (Abs(Lp.DamageDealt - 15.2) < 1e-9));

  if LegacyDir <> '' then
  begin
    LegacyDir := IncludeTrailingPathDelimiter(LegacyDir);
    if LegacyLoadAccountsBin(LegacyDir + 'accounts.bin', Profiles, Cnt, Ver, Err) then
    begin
      WriteLn(Format('       accounts.bin v%d: %d profiles %s', [Ver, Cnt, Err]));
      for i := 0 to Cnt - 1 do
        WriteLn(Format('         #%d %s steam=%s kills=%d deaths=%d points=%d longest=%.1fm barrett=%.1fm names=%d',
          [Profiles[i]^.ID, Profiles[i]^.ActiveName, Profiles[i]^.ActiveSteam, Profiles[i]^.Kills, Profiles[i]^.Deaths,
           Profiles[i]^.Points, Profiles[i]^.LongestKillDistance, Profiles[i]^.LongestBarrettDistance,
           Length(Profiles[i]^.OtherNames)]));
      LegacyAssignProfileIds(Profiles, Cnt, NextId, Reassigned);
      Check('legacy accounts.bin parsed completely', (Cnt > 0) and (Err = '') and (Reassigned = 0));
    end
    else
      Check('legacy accounts.bin: ' + Err, False);
    if LegacyLoadMapsBin(LegacyDir + 'maps.bin', Maps, Cnt, Ver, Err) then
    begin
      for i := 0 to Cnt - 1 do
        WriteLn(Format('       map #%d %s plays=%d kills=%d', [Maps[i].ID, Maps[i].MapName, Maps[i].ActiveMapPlays, Maps[i].Kills]));
      Check('legacy maps.bin parsed completely', (Cnt > 0) and (Err = ''));
    end
    else
      Check('legacy maps.bin: ' + Err, False);
    ClearServer(Srv);
    if LegacyImportServerRecords(LegacyDir + 'server_records.ini', Srv, Phantoms) then
    begin
      WriteLn(Format('       server_records: peak=%d hour18=%d phantoms removed=%d',
        [Srv.PeakOnlineCount, Srv.HourlyActivity[18], Phantoms]));
      Check('matchup phantom correction', (Srv.Matchups[2, 0] = 0) and (Srv.Matchups[2, 8] = 3) and
        (Srv.Matchups[8, 0] = 0) and (Srv.Matchups[8, 2] = 1) and (Phantoms = 4));
    end
    else
      Check('legacy server_records.ini', False);
  end;

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
