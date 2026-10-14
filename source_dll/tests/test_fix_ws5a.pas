program test_fix_ws5a;

{ The audit fixes of WS5A: storage, the copy for other servers and the export.
    ZSD-01  the journals of short runs are folded into a snapshot: the limits of CompactJournalMB and
            CompactIntervalMinutes count over restarts; a last automatic backup dated in the future
            does not stop the backups
    ZSD-02  the record of an account in zs_players.shared_data (Engine = mirror, Shared*) carries no
            login data: no password hash or salt, e-mail, IP, HWID, trusted computer, codes
    ZSD-04  players.json is built a part every timer run: the engine never stops for the whole file,
            and the file is still complete and replaced at once
    VZ3-N01 a journal batch of the whole database goes to the IO thread in portions: the memory it
            needs does not grow with the batch, the generation and the order stay
    ZSI-13  thousands of accounts of one name ("Major"): the name index is built without a quadratic
            search, and still holds every account once }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, base64, zs_types, zs_util, zs_fields, zs_fileio, zs_store, zs_db, zs_engine, zs_config,
  zs_export;

var
  Failures: Integer = 0;
  SourceDir: AnsiString;
  Engine: TZSEngine;
  Pushed: LongInt;
  Console: TStringList;

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

procedure DeleteTree(const Dir: AnsiString);
var
  SR: TSearchRec;
  P: AnsiString;
begin
  if not DirectoryExists(Dir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure WriteText(const Path, Text: AnsiString);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Text <> '' then
      F.WriteBuffer(Text[1], Length(Text));
  finally
    F.Free;
  end;
end;

{ ---------------- the engine ---------------- }

procedure StartEngine(const ScriptDir: AnsiString);
var
  T0: Int64;
begin
  Engine := TZSEngine.Create(ScriptDir);
  Pushed := 0;
  Engine.Start;
  T0 := MonoMs;
  while not Engine.IsReady and (MonoMs - T0 < 20000) do
    Sleep(5);
  { the first timer run (the daily jobs) is over before the test changes anything }
  Sleep(300);
end;

procedure DrainActions;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    Console.Add(A.Text);
end;

procedure StopEngine;
begin
  DrainActions;
  FreeAndNil(Engine);
end;

procedure Cmd(const Text: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := 0;
  Ev.S1 := Text;
  Ev.I[0] := SRC_CONSOLE;
  Ev.I[1] := 1;
  Engine.PushEvent(Ev);
  Inc(Pushed);
end;

function WaitProcessed: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while Engine.Processed < Pushed do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Sleep(100);
  Result := True;
end;

function Seen(const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  DrainActions;
  for k := 0 to Console.Count - 1 do
    if Pos(Part, Console[k]) > 0 then
      Exit(True);
  Result := False;
end;

function WriterGen: LongWord;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.Writer.Generation;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function WriterBytes: Int64;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.Writer.JournalBytes;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function SnapshotRunning: Boolean;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.DB.SnapshotActive;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ every number of the account set, so its record is as big as that of a player of many games }
procedure FillNumbers(var P: TPlayerProfile; Seed: LongInt);
var
  k: LongInt;
  Ptr: Pointer;
begin
  for k := 0 to High(ProfileFields) do
  begin
    if ProfileFields[k].Id < 100 then
      Continue;
    Ptr := Pointer(PtrUInt(@P) + ProfileFields[k].Offset);
    case ProfileFields[k].Kind of
      fkInt32: PLongInt(Ptr)^ := 1 + (Seed + ProfileFields[k].Id) mod 1000;
      fkInt64: PInt64(Ptr)^ := 1 + (Seed + ProfileFields[k].Id) mod 1000;
      fkSingle: PSingle(Ptr)^ := 0.5 + (Seed + ProfileFields[k].Id) mod 1000;
      fkDouble: PDouble(Ptr)^ := 0.5 + (Seed + ProfileFields[k].Id) mod 1000;
    end;
  end;
end;

{ ---------------- ZSD-01 ---------------- }

type
  TFileHeader = packed record
    Magic: LongWord;
    Format: LongWord;
    Gen: LongWord;
    Created: Double;
    Reserved: LongWord;
    Crc: LongWord;
  end;

{ the date in the header of a snapshot, as an older run would have left it }
procedure SetSnapshotDate(const Path: AnsiString; Created: Double);
var
  F: TFileStream;
  H: TFileHeader;
begin
  F := TFileStream.Create(Path, fmOpenReadWrite);
  try
    F.ReadBuffer(H, SizeOf(H));
    H.Created := Created;
    H.Crc := Crc32Buf(@H, SizeOf(H) - 4);
    F.Position := 0;
    F.WriteBuffer(H, SizeOf(H));
  finally
    F.Free;
  end;
end;

function StoredInfo(const DataDir: AnsiString): TStoreLoadInfo;
var
  St: TStoreState;
begin
  St.Profiles := nil;
  St.Maps := nil;
  St.Seasons := nil;
  St.PlayerMaps := nil;
  StoreLoad(DataDir, 'zitrostats.zsdb', 'zitrostats.journal', St, Result);
  ClearStoreState(St);
end;

function CountFiles(const Dir, Mask: AnsiString): LongInt;
var
  L: TStringList;
begin
  L := ListFiles(Dir, Mask);
  try
    Result := L.Count;
  finally
    L.Free;
  end;
end;

{ Every account of the test changed once: the journal of one run, about PER_RUN bytes. }
procedure TouchAll(const Ids: TIntArray; Round: LongInt);
var
  k, Idx: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 0 to High(Ids) do
    begin
      Idx := Engine.DB.IndexOfId(Ids[k]);
      if Engine.DB.Valid(Idx) then
      begin
        Inc(Engine.DB.Profiles[Idx]^.Kills, Round);
        Engine.DB.Touch(Idx);
      end;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function WaitBytes(AtLeast: Int64): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while WriterBytes < AtLeast do
  begin
    if MonoMs - T0 > 15000 then
      Exit(False);
    Sleep(20);
  end;
  Result := True;
end;

{ the generation a writer starts with on these files: one above every number in use }
function StartGen(const DataDir: AnsiString): LongWord;
begin
  Result := StoredInfo(DataDir).MaxGen + 1;
end;

{ a routine snapshot started and written to the end; False when none started within Ms }
function WaitSnapshot(FromGen: LongWord; Ms: LongInt): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while (WriterGen <= FromGen) or SnapshotRunning do
  begin
    if MonoMs - T0 > Ms then
      Exit(False);
    Sleep(20);
  end;
  Result := True;
end;

procedure TestCompaction;
const
  PER_RUN = 400 * 1024;
var
  Root, Script, Data, Backups: AnsiString;
  Ids: TIntArray;
  Info: TStoreLoadInfo;
  Size, Carried: Int64;
  Gen0, SnapGen: LongWord;
  k, Idx: LongInt;
  Last: Double;
  Ok: Boolean;
  T0: Int64;
begin
  WriteLn('--- ZSD-01: the journals of short runs and the snapshot');
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'ws5a_compact');
  DeleteTree(Root);
  Script := Root + PathDelim + 'script' + PathDelim;
  ForceDirectories(Script);
  SetCurrentDir(Root);
  Data := Root + PathDelim + 'nickreg';
  { the smallest limits: 1 MB of journal, 10 minutes }
  WriteText(Script + 'settings.ini', '[Database]' + LineEnding + 'JournalFlushSeconds = 1' + LineEnding +
    'CompactIntervalMinutes = 10' + LineEnding + 'CompactJournalMB = 1' + LineEnding + 'AutoBackupDays = 0' + LineEnding +
    '[Export]' + LineEnding + 'JSONExportEnabled = 0' + LineEnding + '[Seasons]' + LineEnding + 'Enabled = 0' + LineEnding +
    '[Inactivity]' + LineEnding + 'Mode = none' + LineEnding + '[MapVote]' + LineEnding + 'Enabled = 0' + LineEnding);

  { run 1: a new database (its first snapshot is written at the start) and about 400 KB of journal }
  StartEngine(Script);
  Check('ZSD-01 run 1: engine ready and writable', Engine.IsReady and not Engine.IsReadOnly);
  Ids := nil;
  Size := 0;
  EnterCriticalSection(Engine.StateLock);
  try
    k := 0;
    while Size < PER_RUN do
    begin
      Idx := Engine.DB.CreateProfile('Player' + IntToStr(k), 'S' + IntToStr(500000 + k), '', '', 1000);
      FillNumbers(Engine.DB.Profiles[Idx]^, k);
      SetLength(Ids, Length(Ids) + 1);
      Ids[High(Ids)] := Engine.DB.Profiles[Idx]^.ID;
      Inc(Size, Length(EncodeProfile(Engine.DB.Profiles[Idx]^)) + 9);
      Inc(k);
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  WriteLn(Format('       %d accounts, %d KB of journal a run', [Length(Ids), Size div 1024]));
  Check('ZSD-01 run 1: the journal is written', WaitBytes(Size));
  StopEngine;
  Info := StoredInfo(Data);
  SnapGen := Info.SnapshotGen;
  Check('ZSD-01 run 1: the snapshot of the start, the journal after it', (SnapGen > 0) and (Info.JournalRecords >= Length(Ids)));

  { run 2: the journal of run 1 counts at once; it and this run's stay below 1 MB: no snapshot }
  Gen0 := StartGen(Data);
  StartEngine(Script);
  Carried := WriterBytes;
  WriteLn(Format('       run 2 starts with %d KB of journal since the snapshot', [Carried div 1024]));
  Check('ZSD-01 run 2: the journal written before the restart counts towards CompactJournalMB',
    (Carried >= Size) and (Carried < Size + 64 * 1024));
  Cmd('/zs_perf');
  Check('ZSD-01 run 2: /zs_perf shows the journal since the snapshot, the earlier runs included',
    WaitProcessed and (Carried >= Size) and Seen(Format('%d KB since snapshot', [Carried div 1024])));
  TouchAll(Ids, 1);
  Check('ZSD-01 run 2: the changes are written', WaitBytes(Carried + Size));
  Sleep(500);
  Check('ZSD-01 run 2: no snapshot below the limits - a start does not write one by itself',
    (WriterGen = Gen0) and not SnapshotRunning);
  StopEngine;
  Info := StoredInfo(Data);
  Check('ZSD-01 run 2: the snapshot on disk is still that of run 1', Info.SnapshotGen = SnapGen);

  { run 3: together the three runs pass 1 MB - the journals are folded into a snapshot }
  Gen0 := StartGen(Data);
  StartEngine(Script);
  TouchAll(Ids, 2);
  Ok := WaitSnapshot(Gen0, 15000);
  Check('ZSD-01 run 3: the journals of three short runs reach CompactJournalMB together and a snapshot is written', Ok);
  StopEngine;
  Info := StoredInfo(Data);
  WriteLn(Format('       after run 3: snapshot %d (was %d), %d journal records replayed from %d files',
    [Int64(Info.SnapshotGen), Int64(SnapGen), Info.JournalRecords, Info.JournalFiles]));
  Check('ZSD-01 run 3: the next start reads the new snapshot and replays (almost) nothing',
    (Info.SnapshotGen > SnapGen) and (Info.JournalRecords < Length(Ids)));
  SnapGen := Info.SnapshotGen;

  { run 4: a fresh snapshot and a few changes: nothing to fold }
  Gen0 := StartGen(Data);
  StartEngine(Script);
  Check('ZSD-01 run 4: the writer starts above the numbers in use', WriterGen = Gen0);
  TouchAll(Copy(Ids, 0, 5), 3);
  Check('ZSD-01 run 4: the changes are written', WaitBytes(1));
  Sleep(1500);
  Check('ZSD-01 run 4: a start with a fresh snapshot and a small journal writes no snapshot',
    (WriterGen = Gen0) and not SnapshotRunning);
  StopEngine;

  { run 5: the snapshot is 11 minutes old (CompactIntervalMinutes = 10) and there is journal after
    it: it is replaced soon after the start, not 10 minutes later }
  SetSnapshotDate(StorePath(Data, 'zitrostats.zsdb'), Now - 11 / 1440);
  Gen0 := StartGen(Data);
  StartEngine(Script);
  Ok := WaitSnapshot(Gen0, 5000);
  Check('ZSD-01 run 5: a snapshot older than CompactIntervalMinutes is replaced right after a start', Ok);
  Check('ZSD-01 run 5: after it the journal since the snapshot starts from zero', WriterBytes < 64 * 1024);

  { a last automatic backup dated a month ahead (a clock that was wrong): a backup is due }
  Backups := '';
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.AutoBackupDays := 14;
    Engine.DB.Server.LastAutoBackup := Now + 30;
    Engine.DB.TouchServer;
    Backups := Engine.BackupDir;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  T0 := MonoMs;
  repeat
    Sleep(50);
    EnterCriticalSection(Engine.StateLock);
    try
      Last := Engine.DB.Server.LastAutoBackup;
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
  until (Last < Now + 1) or (MonoMs - T0 > 10000);
  Check('ZSD-01: a last automatic backup dated in the future does not stop the backups',
    (Last < Now + 1) and (Last > Now - 1) and (CountFiles(Backups, 'zitrostats-*-auto.zsdb') = 1));
  StopEngine;
end;

{ ---------------- VZ3-N01 ---------------- }

{ N accounts with every number set, all of them waiting for the journal (a new season) }
function BigDB(N: LongInt): TStatsDB;
var
  k, Idx: LongInt;
begin
  Result := TStatsDB.Create;
  for k := 0 to N - 1 do
  begin
    Idx := Result.CreateProfile('Soldier' + IntToStr(k), 'S' + IntToStr(700000 + k), '', '', 1000);
    FillNumbers(Result.Profiles[Idx]^, k);
  end;
end;

procedure TestJournalPortions;
const
  N = 6000;
var
  Dir: AnsiString;
  DB: TStatsDB;
  IO: TStoreIO;
  W: TStoreWriter;
  St: TStoreState;
  Info: TStoreLoadInfo;
  U0, Peak, Batch: Int64;
  Gen: LongWord;
  k, Bad: LongInt;
begin
  WriteLn('--- VZ3-N01: the journal of a big batch');
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'ws5a_portions');
  DeleteTree(Dir);
  ForceDirectories(Dir);
  DB := BigDB(N);
  try
    { the worst case: the IO thread takes nothing while the batch is encoded (a disk that does not
      keep up), so everything handed over stays in its queue }
    IO := TStoreIO.Create(Dir + PathDelim + 'stalled', 'zitrostats.zsdb', 'zitrostats.journal');
    IO.StopAndWait;
    W := TStoreWriter.Create(IO, 0);
    U0 := GetFPCHeapStatus.CurrHeapUsed;
    DB.FlushJournal(W, True);
    Peak := GetFPCHeapStatus.MaxHeapUsed - U0;
    Batch := W.JournalBytes;
    WriteLn(Format('       %d accounts: a batch of %d KB, the flush needed %d KB more memory at most (%d%% of the batch)',
      [N, Batch div 1024, Peak div 1024, Peak * 100 div Max(Int64(1), Batch)]));
    Check('VZ3-N01: the batch is big enough for the test (over 10 portions)', Batch > 10 * JOURNAL_PORTION);
    Check('VZ3-N01: the whole batch is handed to the IO thread', (W.PendingJournal = 0) and (IO.PendingBytes = Batch));
    { before: the buffer grew to the whole batch (doubling) and Flush copied it once more: twice the
      batch at least; now the queue holds the batch and the buffer a portion or two }
    Check('VZ3-N01: the flush needs at most the batch and a few portions of memory, not twice the batch',
      Peak < Batch + 6 * Int64(JOURNAL_PORTION));
    W.Free;
    IO.Free;

    { with the IO thread working: one journal, the generation of the writer, every record in order }
    IO := TStoreIO.Create(Dir, 'zitrostats.zsdb', 'zitrostats.journal');
    W := TStoreWriter.Create(IO, 0);
    DB.BeginSnapshot(W);
    while not DB.ContinueSnapshot(W, MaxInt) do ;
    W.CommitSnapshot(0, '');
    Gen := W.Generation;
    for k := 0 to DB.ProfileCount - 1 do
    begin
      DB.Profiles[k]^.Kills := 7;
      DB.Touch(k);
    end;
    DB.FlushJournal(W, True);
    for k := 0 to DB.ProfileCount - 1 do
    begin
      DB.Profiles[k]^.Kills := 1000 + DB.Profiles[k]^.ID;
      DB.Touch(k);
    end;
    DB.FlushJournal(W, True);
    Check('VZ3-N01: the portions keep the generation of the writer', W.Generation = Gen);
    W.Free;
    IO.Free;
    St.Profiles := nil;
    St.Maps := nil;
    St.Seasons := nil;
    St.PlayerMaps := nil;
    Check('VZ3-N01: the store loads', StoreLoad(Dir, 'zitrostats.zsdb', 'zitrostats.journal', St, Info) = slLoaded);
    Bad := 0;
    for k := 0 to St.ProfileCount - 1 do
      if St.Profiles[k]^.Kills <> 1000 + St.Profiles[k]^.ID then
        Inc(Bad);
    WriteLn(Format('       replayed %d journal records from %d file(s), %d torn tails', [Info.JournalRecords, Info.JournalFiles,
      Info.TornTails]));
    Check('VZ3-N01: one journal file, every record of both batches, in their order',
      (Info.JournalFiles = 1) and (Info.JournalRecords = 2 * N) and (Info.TornTails = 0) and (St.ProfileCount = N) and
      (Bad = 0));
    ClearStoreState(St);
  finally
    DB.Free;
  end;
end;

{ ---------------- ZSI-13 ---------------- }

{ every index of 0 .. Count - 1 exactly once }
function AllOnce(const Found: TIntArray; Count: LongInt): Boolean;
var
  Hit: array of Boolean;
  k: LongInt;
begin
  Result := Length(Found) = Count;
  if not Result then
    Exit;
  SetLength(Hit, Count);
  for k := 0 to High(Found) do
  begin
    if (Found[k] < 0) or (Found[k] >= Count) or Hit[Found[k]] then
      Exit(False);
    Hit[Found[k]] := True;
  end;
end;

procedure TestNameIndex;
const
  M = 12000;
var
  DB: TStatsDB;
  k: LongInt;
  T0, Ms: Int64;
begin
  WriteLn('--- ZSI-13: many accounts of one name');
  DB := TStatsDB.Create;
  try
    for k := 0 to M - 1 do
      DB.CreateProfile('Major', '', 'HW' + IntToStr(k), '', 1000);
    Check('ZSI-13: every account of the name once after creating them', AllOnce(DB.IndexesOfName('Major'), M));
    T0 := MicroNow;
    DB.RebuildIndexes;
    Ms := (MicroNow - T0) div 1000;
    WriteLn(Format('       %d accounts named Major: the indexes built in %d ms', [M, Ms]));
    Check('ZSI-13: every account of the name once after the indexes are built again', AllOnce(DB.IndexesOfName('MAJOR'), M));
    { a join takes the account out of the index and puts it back }
    DB.SetActiveIdentity(M div 2, 'Major', 'HW-new', '1.2.3.4');
    { an account indexed again without being taken out first stays once (TStrIndex.Add passes over
      a key it holds with that value) }
    DB.EndIdentityChange(M div 3);
    Check('ZSI-13: re-indexing an account (a join) keeps it once', AllOnce(DB.IndexesOfName('major'), M));
    Check('ZSI-13: the new computer of the account is found', (Length(DB.IndexesOfHwid('HW-new')) = 1) and
      (DB.IndexesOfHwid('HW-new')[0] = M div 2));
    { before: 12000 accounts of one name took several seconds (each key searched with a list that
      grew by one per account); now well under one }
    Check('ZSI-13: the index of 12000 accounts of one name is built in under 1.5 s', Ms < 1500);
  finally
    DB.Free;
  end;
end;

{ ---------------- ZSD-02 ---------------- }

function FileText(const Path: AnsiString): AnsiString;
begin
  if not ReadWholeFile(Path, Result) then
    Result := '';
end;

type
  PTrustedList = ^TTrustedDeviceArray;

procedure TestSharedRecord;
const
  SECRETS: array[0..10] of AnsiString = ('alice@example.com', 'new-alice@example.com', '83.12.34.56', 'HW-ALICE-1234',
    'HW-TRUSTED-9', '83.12.', 'PBKDF2HASHPBKDF2HASH', 'SALTSALTSALT', 'EMAILCODEHASH', 'RESETCODEHASH',
    '76561198000000001');
var
  P, Q, Others: TPlayerProfile;
  Column, Raw, Src: AnsiString;
  k, Leaks: LongInt;
  Ptr: Pointer;
  Empty: Boolean;
begin
  WriteLn('--- ZSD-02: the record of an account in the copy for websites');
  ClearProfile(P);
  FillNumbers(P, 3);
  P.ID := 42;
  P.ActiveName := 'Alice';
  P.ActiveSteam := '76561198000000001';
  P.ActiveHWID := 'HW-ALICE-1234';
  P.ActiveIP := '83.12.34.56';
  P.RegisterTime := Now - 100;
  P.LastPlayedTime := Now - 1;
  P.PassHash := 'PBKDF2HASHPBKDF2HASH';
  P.PassSalt := 'SALTSALTSALT';
  P.PassIter := 120000;
  P.PassSetTime := Now - 50;
  P.Email := 'alice@example.com';
  P.EmailVerified := True;
  P.EmailPending := 'new-alice@example.com';
  P.EmailCodeHash := 'EMAILCODEHASH';
  P.EmailCodeExpire := Now + 0.01;
  P.ResetCodeHash := 'RESETCODEHASH';
  P.ResetCodeExpire := Now + 0.01;
  P.MailLastSent := Now - 0.5;
  P.MailDayKey := 20261014;
  P.MailSentToday := 2;
  P.LoginFailCount := 3;
  P.LoginLockUntil := Now + 0.001;
  SetLength(P.TrustedDevices, 1);
  P.TrustedDevices[0].HWID := 'HW-TRUSTED-9';
  P.TrustedDevices[0].IPPrefix := '83.12.';
  P.TrustedDevices[0].Expire := Now + 30;
  P.TrustedDevices[0].LastUsed := Now - 1;
  P.NoTrustedDevices := True;
  P.LoginFailSince := Now - 0.002;

  { the column as the mirror writes it and as the other servers (and any website) read it }
  Column := EncodeStringBase64(EncodeSharedProfile(P));
  Raw := DecodeStringBase64(Column);
  Leaks := 0;
  for k := 0 to High(SECRETS) do
    if Pos(SECRETS[k], Raw) > 0 then
    begin
      WriteLn('       the column holds ', SECRETS[k]);
      Inc(Leaks);
    end;
  Check('ZSD-02: shared_data holds no e-mail, IP, HWID, trusted computer, SteamID, password hash or salt, code hash',
    Leaks = 0);
  Check('ZSD-02: the column decodes', DecodeProfile(Raw, Q));
  Check('ZSD-02: no login data after decoding',
    (Q.ActiveSteam = '') and (Q.ActiveHWID = '') and (Q.ActiveIP = '') and (Q.PassHash = '') and (Q.PassSalt = '') and
    (Q.PassIter = 0) and (Q.PassSetTime = 0) and (Q.Email = '') and not Q.EmailVerified and (Q.EmailPending = '') and
    (Q.EmailCodeHash = '') and (Q.EmailCodeExpire = 0) and (Q.ResetCodeHash = '') and (Q.ResetCodeExpire = 0) and
    (Q.MailLastSent = 0) and (Q.MailDayKey = 0) and (Q.MailSentToday = 0) and (Q.LoginFailCount = 0) and
    (Q.LoginLockUntil = 0) and (Length(Q.TrustedDevices) = 0) and not Q.NoTrustedDevices and (Q.LoginFailSince = 0));
  { every registered field the encoder leaves out is empty, whatever its kind }
  Empty := True;
  for k := 0 to High(ProfileFields) do
    if IsLoginField(ProfileFields[k].Id) then
    begin
      Ptr := Pointer(PtrUInt(@Q) + ProfileFields[k].Offset);
      case ProfileFields[k].Kind of
        fkInt32: if PLongInt(Ptr)^ <> 0 then Empty := False;
        fkInt64: if PInt64(Ptr)^ <> 0 then Empty := False;
        fkSingle: if PSingle(Ptr)^ <> 0 then Empty := False;
        fkDouble: if PDouble(Ptr)^ <> 0 then Empty := False;
        fkBool: if PBoolean(Ptr)^ then Empty := False;
        fkString: if PAnsiString(Ptr)^ <> '' then Empty := False;
        fkTrusted: if Length(PTrustedList(Ptr)^) > 0 then Empty := False;
      end;
    end;
  Check('ZSD-02: every field left out (ids 3-5, 20-38) is empty in the copy', Empty and (EncodeProfile(Q) = EncodeSharedProfile(P)));
  { what the other servers add up (RebuildPlayer): the statistics, the points, the name, the date }
  Check('ZSD-02: the statistics, points, name and last game are all there',
    (EncodeSharedProfile(Q) = EncodeSharedProfile(P)) and (Q.ID = 42) and (Q.ActiveName = 'Alice') and
    (Q.Kills = P.Kills) and (Q.Points = P.Points) and (Q.Weapons[3].Kills = P.Weapons[3].Kills) and
    (Q.LastPlayedTime = P.LastPlayedTime) and (Length(Q.OtherNames) = Length(P.OtherNames)));
  ClearProfile(Others);
  MergeProfileInto(Others, Q, 1000);
  Check('ZSD-02: the sum of the other servers gets no e-mail either', (Others.Email = '') and (Others.Kills = P.Kills));
  { the mirror writes the column with it }
  Src := FileText(IncludeTrailingPathDelimiter(SourceDir) + 'zs_mysql.pas');
  Check('ZSD-02: zs_mysql writes shared_data with EncodeSharedProfile, never the whole record',
    (Pos('B.Players[n].Shared := EncodeStringBase64(EncodeSharedProfile(P^));', Src) > 0) and
    (Pos('EncodeStringBase64(EncodeProfile(P^))', Src) = 0));
end;

{ ---------------- ZSD-04 ---------------- }

function CountOf(const Part, Text: AnsiString): LongInt;
var
  p: LongInt;
begin
  Result := 0;
  p := Pos(Part, Text);
  while p > 0 do
  begin
    Inc(Result);
    p := Pos(Part, Text, p + Length(Part));
  end;
end;

procedure TestFullExport;
const
  N = 3000;
var
  Root, Script, Path, Body: AnsiString;
  Samples: array[0..2] of AnsiString;
  k, Idx: LongInt;
  T0, MaxMs: Int64;
  Done: Boolean;
begin
  WriteLn('--- ZSD-04: players.json');
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'ws5a_export');
  DeleteTree(Root);
  Script := Root + PathDelim + 'script' + PathDelim;
  ForceDirectories(Script);
  SetCurrentDir(Root);
  WriteText(Script + 'settings.ini', '[Database]' + LineEnding + 'JournalFlushSeconds = 1' + LineEnding +
    'CompactJournalMB = 1024' + LineEnding + 'AutoBackupDays = 0' + LineEnding +
    '[Export]' + LineEnding + 'JSONExportEnabled = 0' + LineEnding + 'FullExportEnabled = 1' + LineEnding +
    'FullExportPath = nickreg/players.json' + LineEnding + 'ExportIntervalMinutes = 1440' + LineEnding +
    '[Seasons]' + LineEnding + 'Enabled = 0' + LineEnding + '[Inactivity]' + LineEnding + 'Mode = none' + LineEnding +
    '[MapVote]' + LineEnding + 'Enabled = 0' + LineEnding);
  Path := Root + PathDelim + 'nickreg' + PathDelim + 'players.json';
  StartEngine(Script);
  Check('ZSD-04: engine ready and writable', Engine.IsReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    for k := 0 to N - 1 do
    begin
      Idx := Engine.DB.CreateProfile('Gamer' + IntToStr(k), 'S' + IntToStr(900000 + k), '', '', 1000);
      FillNumbers(Engine.DB.Profiles[Idx]^, k);
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  { the new accounts go to the journal first: that timer run is not the export's }
  Check('ZSD-04: the accounts are written', WaitBytes(N * 1000));
  Sleep(1500);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.PerfTimerMaxMicros := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Cmd('/zs_export');
  T0 := MonoMs;
  repeat
    Sleep(50);
    Done := Seen('Export written: nickreg' + PathDelim + 'players.json (');
  until Done or (MonoMs - T0 > 120000);
  WriteLn(Format('       %d accounts written in %d ms', [N, MonoMs - T0]));
  Check('ZSD-04: /zs_export reports players.json written', Done);
  EnterCriticalSection(Engine.StateLock);
  try
    MaxMs := Engine.PerfTimerMaxMicros div 1000;
    Samples[0] := PlayerJson(Engine, 0);
    Samples[1] := PlayerJson(Engine, N div 2);
    Samples[2] := PlayerJson(Engine, N - 1);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  WriteLn(Format('       the longest timer run while it was built: %d ms', [MaxMs]));
  { before: the whole file in one timer run, under StateLock }
  Check('ZSD-04: no timer run holds the engine for the whole file (at most 250 ms)', MaxMs < 250);
  StopEngine;
  Body := FileText(Path);
  Check('ZSD-04: the file is complete: the head, every account once, the end',
    (Pos('{' + LineEnding + '  "format": 2,' + LineEnding + '  "generated_at": "', Body) = 1) and
    (Pos('"total_players": ' + IntToStr(N) + ',' + LineEnding + '  "players": [' + LineEnding + '    {"id": ', Body) > 0) and
    (CountOf('{"id": ', Body) = N) and (CountOf('},' + LineEnding + '    {"id": ', Body) = N - 1) and
    (Copy(Body, Length(Body) - Length('}}' + LineEnding + '  ]' + LineEnding + '}' + LineEnding) + 1, MaxInt) =
      '}}' + LineEnding + '  ]' + LineEnding + '}' + LineEnding));
  Check('ZSD-04: the accounts are the objects of PlayerJson (first, middle, last)',
    (Samples[0] <> '') and (Pos(Samples[0], Body) > 0) and (Pos(Samples[1], Body) > 0) and (Pos(Samples[2], Body) > 0));
  Check('ZSD-04: the file was put in place at once, no part file is left', not FileExists(Path + '.part'));
end;

begin
  SourceDir := GetCurrentDir;
  Console := TStringList.Create;
  try
    TestSharedRecord;
    TestCompaction;
    TestJournalPortions;
    TestNameIndex;
    TestFullExport;
  except
    on E: Exception do
    begin
      WriteLn('[FAIL] exception: ', E.ClassName, ': ', E.Message);
      Inc(Failures);
    end;
  end;
  Console.Free;
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
  begin
    WriteLn(Failures, ' TEST(S) FAILED');
    Halt(1);
  end;
end.
