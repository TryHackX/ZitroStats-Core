unit zs_store;

{ Persistent storage: snapshot + append-only journal, written by a dedicated IO thread.

  Files in the data directory:
    zitrostats.zsdb               last complete snapshot
    zitrostats.zsdb.prev          the snapshot before it
    zitrostats.zsdb.tmp           snapshot being written (used only if it is complete)
    zitrostats.<gen>.journal      changes made since snapshot <gen> started
    zitrostats.lock               held while a server uses the directory

  Every file starts with a 28 byte header (magic, format, generation, date, crc) followed by
  records framed as  type u8 | length u32 | payload | crc32 u32.
  A snapshot must end with an END record. A journal simply stops; a damaged record at its
  tail is the normal result of a crash and ends the replay of that journal.

  Journal records replace whole objects, so replaying the journals of a snapshot's
  generation and later ones, in order, reproduces the last flushed state even though the
  snapshot itself is written in chunks while the game keeps changing data. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  SysUtils, Classes, zs_types, zs_util, zs_fields, zs_fileio, zs_crash;

const
  REC_SERVER = 1;
  REC_PROFILE = 2;
  REC_MAP = 3;
  REC_SEASON = 4;
  REC_META = 5;
  REC_DEL_PROFILE = 6;
  REC_DEL_MAP = 7;
  { a player-on-map record ([Matrix], zs_matrix), and its removal: the account id (4 bytes) and the
    map name. Builds before 5.5 skip both. }
  REC_PLAYERMAP = 8;
  REC_DEL_PLAYERMAP = 9;
  REC_END = 255;

  STORE_FORMAT = 9;
  SNAPSHOT_MAGIC = $4244535A; { 'ZSDB' }
  JOURNAL_MAGIC = $4C4A535A;  { 'ZSJL' }
  STORE_HEADER_SIZE = 28;
  SNAPSHOT_CHUNK = 1024 * 1024;
  MAX_STORE_ID = 20000000;

type
  TStoreState = record
    Server: TServerRecords;
    Profiles: TProfilePtrArray;
    ProfileCount: LongInt;
    Maps: TMapProfileArray;
    MapCount: LongInt;
    Seasons: TSeasonArchiveArray;
    { the player-on-map records; a nil place is one that was removed }
    PlayerMaps: TPlayerMapPtrArray;
    PlayerMapCount: LongInt;
  end;

  TStoreLoadInfo = record
    Source: AnsiString;
    SnapshotGen: LongWord;
    MaxGen: LongWord;
    SnapshotRecords: LongInt;
    JournalFiles: LongInt;
    JournalRecords: LongInt;
    JournalBytes: Int64;
    TornTails: LongInt;
    BadRecords: LongInt;
    Messages: AnsiString;
    { a snapshot of a newer store format is there: this build cannot read it, but the file is
      not damaged and must not be replaced by an older backup }
    NewerFormat: Boolean;
  end;

  TStoreLoadResult = (slEmpty, slLoaded, slFailed);

  { sjNotify does nothing and reports that it was reached: every job before it is done then }
  TStoreJobKind = (sjAppend, sjSnapshotBegin, sjSnapshotData, sjSnapshotCommit, sjSnapshotAbort,
    sjWriteFile, sjAppendText, sjPruneBackups, sjNotify, sjStop);

  TStoreJob = record
    Kind: TStoreJobKind;
    Gen: LongWord;
    Tag: LongInt;
    Keep: LongInt;
    Data: AnsiString;
    Path: AnsiString;
  end;

  TStoreResult = record
    Kind: TStoreJobKind;
    Tag: LongInt;
    Ok: Boolean;
    Bytes: Int64;
    Message: AnsiString;
  end;

  TStoreIO = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FJobs: array of TStoreJob;
    FJobCount: LongInt;
    FResults: array of TStoreResult;
    FResultCount: LongInt;
    FPendingBytes: Int64;
    FBusy: Boolean;
    FDir, FSnapshotName, FJournalName: AnsiString;
    FLockFile: TFileStream;
    FLockError: AnsiString;
    FJournal: TFileStream;
    FJournalGen: LongWord;
    FJournalBroken: Boolean;
    FJournalKept: Boolean;   { an older journal of this number could not be moved aside }
    FSnap: TFileStream;
    FSnapGen: LongWord;
    FSnapFailed: Boolean;
    procedure Post(Kind: TStoreJobKind; Tag: LongInt; Ok: Boolean; const Msg: AnsiString; Bytes: Int64 = 0);
    procedure CloseJournal;
    function OpenJournal(Gen: LongWord): Boolean;
    procedure CloseSnapshot(DeleteFile: Boolean);
    procedure DeleteJournalsBelow(Gen: LongWord);
    function WriteBackup(const Main: AnsiString; Gen: LongWord; const EndRecord, Dest: AnsiString): Boolean;
    procedure DoAppend(const Job: TStoreJob);
    procedure DoSnapshotBegin(const Job: TStoreJob);
    procedure DoSnapshotData(const Job: TStoreJob);
    procedure DoSnapshotCommit(const Job: TStoreJob);
    procedure DoPrune(const Job: TStoreJob);
  protected
    procedure Execute; override;
  public
    constructor Create(const Dir, SnapshotName, JournalName: AnsiString);
    destructor Destroy; override;
    procedure Enqueue(const Job: TStoreJob);
    function PollResult(out R: TStoreResult): Boolean;
    function PendingBytes: Int64;
    function Idle: Boolean;
    procedure StopAndWait;
    property LockError: AnsiString read FLockError;
  end;

  { Used by the engine thread only. }
  TStoreWriter = class
  private
    FIO: TStoreIO;
    FGen: LongWord;
    FJBuf: AnsiString;
    FJLen: LongInt;
    FSBuf: AnsiString;
    FSLen: LongInt;
    FSnapActive: Boolean;
    FSnapRecords: LongInt;
    FJournalBytes: Int64;
    procedure PushSnapshotChunk;
  public
    constructor Create(IO: TStoreIO; LastGen: LongWord);
    procedure JournalProfile(const P: TPlayerProfile);
    procedure JournalMap(const M: TMapProfile);
    procedure JournalServer(const S: TServerRecords);
    procedure JournalSeason(const A: TSeasonArchive);
    procedure JournalDeleteProfile(Id: LongInt);
    procedure JournalDeleteMap(Id: LongInt);
    procedure JournalPlayerMap(const R: TPlayerMapStats);
    procedure JournalDeletePlayerMap(AccountId: LongInt; const MapName: AnsiString);
    procedure Flush;
    procedure BeginSnapshot(ProfileCount, MapCount, SeasonCount: LongInt);
    procedure SnapshotProfile(const P: TPlayerProfile);
    procedure SnapshotMap(const M: TMapProfile);
    procedure SnapshotServer(const S: TServerRecords);
    procedure SnapshotSeason(const A: TSeasonArchive);
    procedure SnapshotPlayerMap(const R: TPlayerMapStats);
    procedure CommitSnapshot(Tag: LongInt; const BackupPath: AnsiString);
    procedure AbortSnapshot;
    property Generation: LongWord read FGen;
    property SnapshotActive: Boolean read FSnapActive;
    property JournalBytes: Int64 read FJournalBytes;
    property PendingJournal: LongInt read FJLen;
  end;

function NewJob(Kind: TStoreJobKind; Gen: LongWord = 0; Tag: LongInt = 0): TStoreJob;
procedure ClearStoreState(var St: TStoreState);
function StoreLoad(const Dir, SnapshotName, JournalName: AnsiString; var St: TStoreState;
  out Info: TStoreLoadInfo): TStoreLoadResult;
function StoreLoadFile(const Path: AnsiString; var St: TStoreState; out Info: TStoreLoadInfo): Boolean;
function StorePath(const Dir, Name: AnsiString): AnsiString;
function JournalFileName(const Dir, JournalName: AnsiString; Gen: LongWord): AnsiString;
function FrameRecord(RecType: Byte; const Payload: AnsiString): AnsiString;
function ListBackups(const BackupDir: AnsiString): TStringList;

implementation

type
  TStoreHeader = packed record
    Magic: LongWord;
    Format: LongWord;
    Gen: LongWord;
    Created: Double;
    Reserved: LongWord;
    Crc: LongWord;
  end;

  TGenArray = array of LongWord;
  TIdIndex = array of LongInt;

  TApplyCtx = record
    ProfileIdx: TIdIndex;
    MapIdx: TIdIndex;
    { the player-on-map records by account and map: open addressing, place + 1 in
      St.PlayerMaps (0 = empty; a place that holds nil was removed and is passed over) }
    PMHash: TIdIndex;
    PMUsed: LongInt;
  end;

{ ---------------- helpers ---------------- }

function NewJob(Kind: TStoreJobKind; Gen: LongWord; Tag: LongInt): TStoreJob;
begin
  Result.Kind := Kind;
  Result.Gen := Gen;
  Result.Tag := Tag;
  Result.Keep := 0;
  Result.Data := '';
  Result.Path := '';
end;

function StorePath(const Dir, Name: AnsiString): AnsiString;
begin
  if Dir = '' then
    Result := Name
  else
    Result := IncludeTrailingPathDelimiter(Dir) + Name;
end;

function JournalFileName(const Dir, JournalName: AnsiString; Gen: LongWord): AnsiString;
var
  Ext: AnsiString;
begin
  Ext := ExtractFileExt(JournalName);
  if Ext = '' then
    Ext := '.journal';
  Result := StorePath(Dir, ChangeFileExt(ExtractFileName(JournalName), '') + '.' +
    Format('%.8d', [Int64(Gen)]) + Ext);
end;

procedure AddMessage(var Info: TStoreLoadInfo; const S: AnsiString);
begin
  Info.Messages := Info.Messages + S + LineEnding;
end;

procedure ResetInfo(out Info: TStoreLoadInfo);
begin
  Info.Source := '';
  Info.SnapshotGen := 0;
  Info.MaxGen := 0;
  Info.SnapshotRecords := 0;
  Info.JournalFiles := 0;
  Info.JournalRecords := 0;
  Info.JournalBytes := 0;
  Info.TornTails := 0;
  Info.BadRecords := 0;
  Info.Messages := '';
  Info.NewerFormat := False;
end;

function MakeHeader(Magic, Gen: LongWord): AnsiString;
var
  H: TStoreHeader;
begin
  FillChar(H, SizeOf(H), 0);
  H.Magic := Magic;
  H.Format := STORE_FORMAT;
  H.Gen := Gen;
  H.Created := Now;
  H.Crc := Crc32Buf(@H, SizeOf(H) - 4);
  SetLength(Result, SizeOf(H));
  Move(H, Result[1], SizeOf(H));
end;

function ParseHeader(const Data: AnsiString; Magic: LongWord; out Gen: LongWord): Boolean;
var
  H: TStoreHeader;
begin
  Gen := 0;
  Result := False;
  if Length(Data) < SizeOf(H) then
    Exit;
  Move(Data[1], H, SizeOf(H));
  if (H.Magic <> Magic) or (H.Format <> STORE_FORMAT) then
    Exit;
  if H.Crc <> Crc32Buf(@H, SizeOf(H) - 4) then
    Exit;
  Gen := H.Gen;
  Result := True;
end;

function ReadHeaderGen(const Path: AnsiString; Magic: LongWord; out Gen: LongWord): Boolean;
var
  F: TFileStream;
  S: AnsiString;
begin
  Result := False;
  Gen := 0;
  if not FileExists(Path) then
    Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(S, STORE_HEADER_SIZE);
      if F.Read(S[1], STORE_HEADER_SIZE) <> STORE_HEADER_SIZE then
        Exit;
    finally
      F.Free;
    end;
    Result := ParseHeader(S, Magic, Gen);
  except
    Result := False;
  end;
end;

{ the store format of a file whose header is sound and of this kind, -1 otherwise: a header with a
  valid checksum and a higher format was written by a newer build, it is not damaged }
function ReadHeaderFormat(const Path: AnsiString; Magic: LongWord): LongInt;
var
  F: TFileStream;
  H: TStoreHeader;
begin
  Result := -1;
  if not FileExists(Path) then
    Exit;
  try
    FillChar(H, SizeOf(H), 0);
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Read(H, SizeOf(H)) <> SizeOf(H) then
        Exit;
    finally
      F.Free;
    end;
    if (H.Magic = Magic) and (H.Crc = Crc32Buf(@H, SizeOf(H) - 4)) then
      Result := LongInt(H.Format);
  except
    Result := -1;
  end;
end;

procedure AppendFrame(var Buf: AnsiString; var Len: LongInt; RecType: Byte; const Payload: AnsiString);
var
  PL, Crc: LongWord;
  Need: LongInt;
  P: PAnsiChar;
begin
  PL := Length(Payload);
  Need := Len + 9 + LongInt(PL);
  if Need > Length(Buf) then
  begin
    if Length(Buf) * 2 > Need then
      SetLength(Buf, Length(Buf) * 2)
    else
      SetLength(Buf, Need + 4096);
  end;
  UniqueString(Buf);
  P := PAnsiChar(Buf) + Len;
  P^ := AnsiChar(RecType);
  Move(PL, (P + 1)^, 4);
  if PL > 0 then
    Move(Payload[1], (P + 5)^, PL);
  Crc := Crc32Buf(PByte(P), 5 + PL);
  Move(Crc, (P + 5 + PL)^, 4);
  Len := Need;
end;

function FrameRecord(RecType: Byte; const Payload: AnsiString): AnsiString;
var
  Len: LongInt;
begin
  Result := '';
  Len := 0;
  AppendFrame(Result, Len, RecType, Payload);
  SetLength(Result, Len);
end;

{ 1 = record read, 0 = clean end of data, -1 = truncated or damaged record.
  Offset only advances past a valid record. }
function NextRecord(const Data: AnsiString; var Offset: LongInt; out RecType: Byte;
  out PayloadOfs, PayloadLen: LongInt): Integer;
var
  P: PAnsiChar;
  PL, Stored: LongWord;
  Remaining: Int64;
begin
  RecType := 0;
  PayloadOfs := 0;
  PayloadLen := 0;
  Remaining := Int64(Length(Data)) - Offset;
  if Remaining <= 0 then
    Exit(0);
  if Remaining < 9 then
    Exit(-1);
  P := PAnsiChar(Data) + Offset;
  RecType := Byte(P^);
  Move((P + 1)^, PL, 4);
  if Int64(PL) + 9 > Remaining then
    Exit(-1);
  Move((P + 5 + PL)^, Stored, 4);
  if Crc32Buf(PByte(P), 5 + PL) <> Stored then
    Exit(-1);
  PayloadOfs := Offset + 5;
  PayloadLen := PL;
  Offset := Offset + 9 + LongInt(PL);
  Result := 1;
end;

function ListJournalGens(const Dir, JournalName: AnsiString): TGenArray;
var
  L: TStringList;
  Base, Ext, Name, Mid, SearchDir: AnsiString;
  i, j, n: LongInt;
  G: Int64;
  T: LongWord;
begin
  Result := nil;
  Ext := ExtractFileExt(JournalName);
  if Ext = '' then
    Ext := '.journal';
  Base := ChangeFileExt(ExtractFileName(JournalName), '');
  SearchDir := Dir;
  if SearchDir = '' then
    SearchDir := '.';
  L := ListFiles(SearchDir, Base + '.*' + Ext);
  try
    for i := 0 to L.Count - 1 do
    begin
      Name := L[i];
      if Length(Name) <= Length(Base) + 1 + Length(Ext) then
        Continue;
      if not SameText(Copy(Name, 1, Length(Base) + 1), Base + '.') then
        Continue;
      if not SameText(Copy(Name, Length(Name) - Length(Ext) + 1, Length(Ext)), Ext) then
        Continue;
      Mid := Copy(Name, Length(Base) + 2, Length(Name) - Length(Base) - 1 - Length(Ext));
      G := StrToInt64Def(Mid, -1);
      if (G <= 0) or (G > High(LongWord)) then
        Continue;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := G;
    end;
  finally
    L.Free;
  end;
  for i := 1 to High(Result) do
  begin
    T := Result[i];
    j := i - 1;
    while (j >= 0) and (Result[j] > T) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := T;
  end;
end;

function ListBackups(const BackupDir: AnsiString): TStringList;
begin
  Result := ListFiles(BackupDir, 'zitrostats-*.zsdb');
end;

{ ---------------- loading ---------------- }

procedure ClearStoreState(var St: TStoreState);
begin
  ClearServer(St.Server);
  FreeProfiles(St.Profiles);
  St.ProfileCount := 0;
  St.Maps := nil;
  St.MapCount := 0;
  St.Seasons := nil;
  FreePlayerMaps(St.PlayerMaps);
  St.PlayerMapCount := 0;
end;

procedure GrowIndex(var Idx: TIdIndex; Id: LongInt);
var
  NewLen: LongInt;
begin
  if Id < Length(Idx) then
    Exit;
  NewLen := Length(Idx) * 2;
  if NewLen <= Id then
    NewLen := Id + 1024;
  SetLength(Idx, NewLen);
end;

function PMHashOf(AccountId: LongInt; const MapName: AnsiString): LongWord;
begin
  Result := Fnv1aLower(MapName) xor (LongWord(AccountId) * LongWord(2654435761));
end;

{ the place of the player-on-map record of this account and map in St.PlayerMaps, -1 for none }
function PMFind(const St: TStoreState; const Ctx: TApplyCtx; AccountId: LongInt; const MapName: AnsiString): LongInt;
var
  Mask, h, v: LongInt;
  P: PPlayerMapStats;
begin
  Result := -1;
  if Length(Ctx.PMHash) = 0 then
    Exit;
  Mask := High(Ctx.PMHash);
  h := LongInt(PMHashOf(AccountId, MapName) and LongWord(Mask));
  while Ctx.PMHash[h] <> 0 do
  begin
    v := Ctx.PMHash[h] - 1;
    P := St.PlayerMaps[v];
    if (P <> nil) and (P^.AccountId = AccountId) and SameText(P^.MapName, MapName) then
      Exit(v);
    h := (h + 1) and Mask;
  end;
end;

procedure PMHashPut(const St: TStoreState; var Ctx: TApplyCtx; Place: LongInt);
var
  Mask, h: LongInt;
begin
  Mask := High(Ctx.PMHash);
  h := LongInt(PMHashOf(St.PlayerMaps[Place]^.AccountId, St.PlayerMaps[Place]^.MapName) and LongWord(Mask));
  while Ctx.PMHash[h] <> 0 do
    h := (h + 1) and Mask;
  Ctx.PMHash[h] := Place + 1;
  Inc(Ctx.PMUsed);
end;

{ the record at Place joins the hash; the hash stays at most half full (a power of two long), and
  growing it leaves the removed places out }
procedure PMHashAdd(const St: TStoreState; var Ctx: TApplyCtx; Place: LongInt);
var
  Old: TIdIndex;
  NewLen, k: LongInt;
begin
  if (Length(Ctx.PMHash) = 0) or ((Ctx.PMUsed + 1) * 2 > Length(Ctx.PMHash)) then
  begin
    Old := Ctx.PMHash;
    NewLen := Length(Old) * 2;
    if NewLen < 1024 then
      NewLen := 1024;
    Ctx.PMHash := nil;
    SetLength(Ctx.PMHash, NewLen);
    Ctx.PMUsed := 0;
    for k := 0 to High(Old) do
      if (Old[k] > 0) and (St.PlayerMaps[Old[k] - 1] <> nil) then
        PMHashPut(St, Ctx, Old[k] - 1);
  end;
  PMHashPut(St, Ctx, Place);
end;

function ApplyRecord(var St: TStoreState; var Ctx: TApplyCtx; RecType: Byte;
  const Payload: AnsiString): Boolean;
var
  n, j, k, Id: LongInt;
  P: PPlayerProfile;
  PM: PPlayerMapStats;
  A: TSeasonArchive;
  Meta: array[0..3] of LongWord;
begin
  Result := True;
  case RecType of
    REC_META:
      begin
        FillChar(Meta, SizeOf(Meta), 0);
        if Length(Payload) >= SizeOf(Meta) then
          Move(Payload[1], Meta, SizeOf(Meta));
        if (Meta[0] <= MAX_STORE_ID) and (LongInt(Meta[0]) + 256 > Length(St.Profiles)) then
          SetLength(St.Profiles, LongInt(Meta[0]) + 256);
        if (Meta[1] <= 1000000) and (LongInt(Meta[1]) + 16 > Length(St.Maps)) then
          SetLength(St.Maps, LongInt(Meta[1]) + 16);
      end;

    REC_SERVER:
      Result := DecodeServer(Payload, St.Server);

    REC_PROFILE:
      begin
        P := NewProfile;
        if not DecodeProfile(Payload, P^) or (P^.ID <= 0) or (P^.ID > MAX_STORE_ID) then
        begin
          FreeProfile(P);
          Exit(False);
        end;
        Id := P^.ID;
        GrowIndex(Ctx.ProfileIdx, Id);
        j := Ctx.ProfileIdx[Id] - 1;
        if j >= 0 then
        begin
          FreeProfile(St.Profiles[j]);
          St.Profiles[j] := P;
        end
        else
        begin
          if St.ProfileCount >= Length(St.Profiles) then
            SetLength(St.Profiles, Length(St.Profiles) + 1024 + Length(St.Profiles) div 4);
          St.Profiles[St.ProfileCount] := P;
          Inc(St.ProfileCount);
          Ctx.ProfileIdx[Id] := St.ProfileCount;
        end;
      end;

    REC_MAP:
      begin
        if St.MapCount >= Length(St.Maps) then
          SetLength(St.Maps, Length(St.Maps) + 64 + Length(St.Maps) div 4);
        n := St.MapCount;
        if not DecodeMap(Payload, St.Maps[n]) or (St.Maps[n].ID <= 0) or (St.Maps[n].ID > MAX_STORE_ID) then
        begin
          ClearMap(St.Maps[n]);
          Exit(False);
        end;
        Id := St.Maps[n].ID;
        GrowIndex(Ctx.MapIdx, Id);
        j := Ctx.MapIdx[Id] - 1;
        if j >= 0 then
        begin
          St.Maps[j] := St.Maps[n];
          ClearMap(St.Maps[n]);
        end
        else
        begin
          Ctx.MapIdx[Id] := n + 1;
          Inc(St.MapCount);
        end;
      end;

    REC_SEASON:
      begin
        if not DecodeSeason(Payload, A) or (A.Id <= 0) then
          Exit(False);
        for k := 0 to High(St.Seasons) do
          if St.Seasons[k].Id = A.Id then
          begin
            St.Seasons[k] := A;
            Exit(True);
          end;
        k := Length(St.Seasons);
        SetLength(St.Seasons, k + 1);
        St.Seasons[k] := A;
      end;

    REC_DEL_PROFILE:
      begin
        if Length(Payload) < 4 then
          Exit(False);
        Move(Payload[1], Id, 4);
        if (Id > 0) and (Id < Length(Ctx.ProfileIdx)) then
        begin
          j := Ctx.ProfileIdx[Id] - 1;
          if j >= 0 then
          begin
            FreeProfile(St.Profiles[j]); { nil marks a hole, compacted after loading }
            Ctx.ProfileIdx[Id] := 0;
          end;
        end;
      end;

    REC_DEL_MAP:
      begin
        if Length(Payload) < 4 then
          Exit(False);
        Move(Payload[1], Id, 4);
        if (Id > 0) and (Id < Length(Ctx.MapIdx)) then
        begin
          j := Ctx.MapIdx[Id] - 1;
          if j >= 0 then
          begin
            ClearMap(St.Maps[j]);
            Ctx.MapIdx[Id] := 0;
          end;
        end;
      end;

    REC_PLAYERMAP:
      begin
        PM := NewPlayerMap;
        if not DecodePlayerMap(Payload, PM^) or (PM^.AccountId <= 0) or (PM^.AccountId > MAX_STORE_ID) or
           (Trim(PM^.MapName) = '') then
        begin
          FreePlayerMap(PM);
          Exit(False);
        end;
        j := PMFind(St, Ctx, PM^.AccountId, PM^.MapName);
        if j >= 0 then
        begin
          FreePlayerMap(St.PlayerMaps[j]);
          St.PlayerMaps[j] := PM;
        end
        else
        begin
          if St.PlayerMapCount >= Length(St.PlayerMaps) then
            SetLength(St.PlayerMaps, Length(St.PlayerMaps) + 1024 + Length(St.PlayerMaps) div 4);
          St.PlayerMaps[St.PlayerMapCount] := PM;
          PMHashAdd(St, Ctx, St.PlayerMapCount);
          Inc(St.PlayerMapCount);
        end;
      end;

    REC_DEL_PLAYERMAP:
      begin
        if Length(Payload) < 4 then
          Exit(False);
        Move(Payload[1], Id, 4);
        j := PMFind(St, Ctx, Id, Copy(Payload, 5, MaxInt));
        { nil marks a hole, compacted after loading }
        if j >= 0 then
          FreePlayerMap(St.PlayerMaps[j]);
      end;
  end;
  { unknown record types come from newer builds and are skipped }
end;

procedure CompactState(var St: TStoreState);
var
  i, n: LongInt;
begin
  n := 0;
  for i := 0 to St.ProfileCount - 1 do
    if St.Profiles[i] <> nil then
    begin
      if n <> i then
      begin
        St.Profiles[n] := St.Profiles[i];
        St.Profiles[i] := nil;
      end;
      Inc(n);
    end;
  St.ProfileCount := n;
  n := 0;
  for i := 0 to St.MapCount - 1 do
    if St.Maps[i].ID > 0 then
    begin
      if n <> i then
      begin
        St.Maps[n] := St.Maps[i];
        ClearMap(St.Maps[i]);
      end;
      Inc(n);
    end;
  St.MapCount := n;
  n := 0;
  for i := 0 to St.PlayerMapCount - 1 do
    if St.PlayerMaps[i] <> nil then
    begin
      if n <> i then
      begin
        St.PlayerMaps[n] := St.PlayerMaps[i];
        St.PlayerMaps[i] := nil;
      end;
      Inc(n);
    end;
  St.PlayerMapCount := n;
end;

function LoadSnapshotData(const Data: AnsiString; var St: TStoreState; var Ctx: TApplyCtx;
  var Info: TStoreLoadInfo; out Gen: LongWord): Boolean;
var
  Ofs, PO, PLen: LongInt;
  RT: Byte;
begin
  Result := False;
  if not ParseHeader(Data, SNAPSHOT_MAGIC, Gen) then
    Exit;
  Ofs := STORE_HEADER_SIZE;
  while NextRecord(Data, Ofs, RT, PO, PLen) > 0 do
  begin
    if RT = REC_END then
      Exit(Ofs = Length(Data));
    if ApplyRecord(St, Ctx, RT, Copy(Data, PO + 1, PLen)) then
      Inc(Info.SnapshotRecords)
    else
      Inc(Info.BadRecords);
  end;
end;

procedure ReplayJournal(const Path: AnsiString; ExpectedGen: LongWord; var St: TStoreState;
  var Ctx: TApplyCtx; var Info: TStoreLoadInfo);
var
  Data: AnsiString;
  Gen: LongWord;
  Ofs, PO, PLen, Rc: LongInt;
  RT: Byte;
begin
  if not ReadWholeFile(Path, Data) then
  begin
    AddMessage(Info, 'cannot read ' + ExtractFileName(Path));
    Exit;
  end;
  if not ParseHeader(Data, JOURNAL_MAGIC, Gen) or (Gen <> ExpectedGen) then
  begin
    if Length(Data) > 0 then
      AddMessage(Info, ExtractFileName(Path) + ' has no valid header, skipped');
    Exit;
  end;
  Inc(Info.JournalFiles);
  Inc(Info.JournalBytes, Length(Data));
  Ofs := STORE_HEADER_SIZE;
  repeat
    Rc := NextRecord(Data, Ofs, RT, PO, PLen);
    if Rc < 0 then
    begin
      Inc(Info.TornTails);
      AddMessage(Info, Format('%s: %d damaged bytes at the end ignored',
        [ExtractFileName(Path), Length(Data) - Ofs]));
    end
    else if Rc > 0 then
    begin
      if ApplyRecord(St, Ctx, RT, Copy(Data, PO + 1, PLen)) then
        Inc(Info.JournalRecords)
      else
        Inc(Info.BadRecords);
    end;
  until Rc <= 0;
end;

function StoreLoad(const Dir, SnapshotName, JournalName: AnsiString; var St: TStoreState;
  out Info: TStoreLoadInfo): TStoreLoadResult;
var
  Cand: array[0..2] of AnsiString;
  CandGen: array[0..2] of LongWord;
  CandOk: array[0..2] of Boolean;
  Order: array[0..2] of LongInt;
  Gens: TGenArray;
  Ctx: TApplyCtx;
  Data: AnsiString;
  i, j, t, Fmt: LongInt;
  G: LongWord;
  AnySnapshot, Loaded: Boolean;
begin
  ResetInfo(Info);
  ClearStoreState(St);
  Cand[0] := StorePath(Dir, SnapshotName);
  Cand[1] := Cand[0] + '.tmp';
  Cand[2] := Cand[0] + '.prev';
  AnySnapshot := False;
  for i := 0 to 2 do
  begin
    CandOk[i] := ReadHeaderGen(Cand[i], SNAPSHOT_MAGIC, CandGen[i]);
    if (i <> 1) and FileExists(Cand[i]) then
      AnySnapshot := True;
    Order[i] := i;
  end;
  { newest readable snapshot first }
  for i := 0 to 1 do
    for j := i + 1 to 2 do
      if (CandOk[Order[j]] and not CandOk[Order[i]]) or
         ((CandOk[Order[j]] = CandOk[Order[i]]) and (CandGen[Order[j]] > CandGen[Order[i]])) then
      begin
        t := Order[i];
        Order[i] := Order[j];
        Order[j] := t;
      end;

  Loaded := False;
  for j := 0 to 2 do
  begin
    i := Order[j];
    if not CandOk[i] then
    begin
      if (i <> 1) and FileExists(Cand[i]) then
      begin
        Fmt := ReadHeaderFormat(Cand[i], SNAPSHOT_MAGIC);
        if Fmt > STORE_FORMAT then
        begin
          Info.NewerFormat := True;
          AddMessage(Info, Format('%s was written by a newer ZitroStats (store format %d, this build reads %d): ' +
            'use the newer library, the file is left as it is', [ExtractFileName(Cand[i]), Fmt, STORE_FORMAT]));
        end
        else
          AddMessage(Info, ExtractFileName(Cand[i]) + ' has no valid header');
      end;
      Continue;
    end;
    ClearStoreState(St);
    Ctx.ProfileIdx := nil;
    Ctx.MapIdx := nil;
    Ctx.PMHash := nil;
    Ctx.PMUsed := 0;
    Info.SnapshotRecords := 0;
    Info.BadRecords := 0;
    if ReadWholeFile(Cand[i], Data) and LoadSnapshotData(Data, St, Ctx, Info, G) then
    begin
      Info.Source := Cand[i];
      Info.SnapshotGen := G;
      Loaded := True;
      Break;
    end;
    if i = 1 then
      AddMessage(Info, 'unfinished snapshot ' + ExtractFileName(Cand[i]) + ' ignored')
    else
      AddMessage(Info, ExtractFileName(Cand[i]) + ' is incomplete or damaged');
  end;
  Data := '';

  { the numbers in use, also when nothing can be read: a store that goes on over these files (a
    backup restored after damage) has to continue above them, or it would take a journal left
    here for one of its own }
  Gens := ListJournalGens(Dir, JournalName);
  Info.MaxGen := Info.SnapshotGen;
  for i := 0 to High(Gens) do
    if Gens[i] > Info.MaxGen then
      Info.MaxGen := Gens[i];

  if not Loaded then
  begin
    ClearStoreState(St);
    Ctx.ProfileIdx := nil;
    Ctx.MapIdx := nil;
    Ctx.PMHash := nil;
    Ctx.PMUsed := 0;
    Info.SnapshotRecords := 0;
    if AnySnapshot then
    begin
      AddMessage(Info, 'no usable snapshot: refusing to continue with empty data');
      Exit(slFailed);
    end;
  end;

  for i := 0 to High(Gens) do
    if Gens[i] >= Info.SnapshotGen then
      ReplayJournal(JournalFileName(Dir, JournalName, Gens[i]), Gens[i], St, Ctx, Info);

  if not Loaded then
  begin
    if Info.JournalRecords = 0 then
    begin
      ClearStoreState(St);
      Exit(slEmpty);
    end;
    AddMessage(Info, 'journals exist but no snapshot: refusing to rebuild partial data');
    ClearStoreState(St);
    Exit(slFailed);
  end;

  CompactState(St);
  Result := slLoaded;
end;

function StoreLoadFile(const Path: AnsiString; var St: TStoreState; out Info: TStoreLoadInfo): Boolean;
var
  Data: AnsiString;
  Ctx: TApplyCtx;
  G: LongWord;
begin
  ResetInfo(Info);
  ClearStoreState(St);
  Ctx.PMUsed := 0;
  Result := ReadWholeFile(Path, Data) and LoadSnapshotData(Data, St, Ctx, Info, G);
  if Result then
  begin
    Info.Source := Path;
    Info.SnapshotGen := G;
    Info.MaxGen := G;
    CompactState(St);
  end
  else
  begin
    ClearStoreState(St);
    if ReadHeaderFormat(Path, SNAPSHOT_MAGIC) > STORE_FORMAT then
    begin
      Info.NewerFormat := True;
      AddMessage(Info, ExtractFileName(Path) + ' was written by a newer ZitroStats: use the newer library');
    end;
  end;
end;

{ ---------------- IO thread ---------------- }

constructor TStoreIO.Create(const Dir, SnapshotName, JournalName: AnsiString);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
  FDir := Dir;
  FSnapshotName := SnapshotName;
  FJournalName := JournalName;
  try
    EnsureDir(Dir);
    { one server per data directory: a second instance would interleave its journal with ours }
    FLockFile := TFileStream.Create(StorePath(Dir, 'zitrostats.lock'), fmCreate or fmShareExclusive);
  except
    on E: Exception do
    begin
      FLockFile := nil;
      FLockError := 'data directory ' + Dir + ' is locked or not writable (' + E.Message + ')';
    end;
  end;
  Start;
end;

destructor TStoreIO.Destroy;
begin
  StopAndWait;
  inherited Destroy;
  FreeAndNil(FLockFile);
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
end;

procedure TStoreIO.StopAndWait;
begin
  if Finished then
    Exit;
  Enqueue(NewJob(sjStop));
  WaitFor;
end;

procedure TStoreIO.Enqueue(const Job: TStoreJob);
begin
  EnterCriticalSection(FLock);
  try
    if FJobCount >= Length(FJobs) then
      SetLength(FJobs, Length(FJobs) * 2 + 16);
    FJobs[FJobCount] := Job;
    Inc(FJobCount);
    Inc(FPendingBytes, Length(Job.Data));
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
end;

function TStoreIO.PollResult(out R: TStoreResult): Boolean;
var
  i: LongInt;
begin
  EnterCriticalSection(FLock);
  try
    Result := FResultCount > 0;
    if not Result then
      Exit;
    R := FResults[0];
    for i := 1 to FResultCount - 1 do
      FResults[i - 1] := FResults[i];
    Dec(FResultCount);
    FResults[FResultCount].Message := '';
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStoreIO.PendingBytes: Int64;
begin
  EnterCriticalSection(FLock);
  Result := FPendingBytes;
  LeaveCriticalSection(FLock);
end;

function TStoreIO.Idle: Boolean;
begin
  EnterCriticalSection(FLock);
  Result := (FJobCount = 0) and not FBusy;
  LeaveCriticalSection(FLock);
end;

procedure TStoreIO.Post(Kind: TStoreJobKind; Tag: LongInt; Ok: Boolean; const Msg: AnsiString; Bytes: Int64);
begin
  EnterCriticalSection(FLock);
  try
    if FResultCount >= 1000 then
      Exit;
    if FResultCount >= Length(FResults) then
      SetLength(FResults, Length(FResults) * 2 + 8);
    FResults[FResultCount].Kind := Kind;
    FResults[FResultCount].Tag := Tag;
    FResults[FResultCount].Ok := Ok;
    FResults[FResultCount].Bytes := Bytes;
    FResults[FResultCount].Message := Msg;
    Inc(FResultCount);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStoreIO.Execute;
var
  Batch: array of TStoreJob;
  Count, i: LongInt;
  Stop: Boolean;
begin
  GuardWorkerThread;
  CrashThread(CT_IO);
  Stop := False;
  repeat
    EnterCriticalSection(FLock);
    Batch := FJobs;
    Count := FJobCount;
    FJobs := nil;
    FJobCount := 0;
    FBusy := Count > 0;
    LeaveCriticalSection(FLock);

    if Count = 0 then
    begin
      if Terminated then
        Break;
      RTLEventWaitFor(FWake, 250);
      Continue;
    end;

    for i := 0 to Count - 1 do
    begin
      try
        case Batch[i].Kind of
          sjAppend: DoAppend(Batch[i]);
          sjSnapshotBegin: DoSnapshotBegin(Batch[i]);
          sjSnapshotData: DoSnapshotData(Batch[i]);
          sjSnapshotCommit: DoSnapshotCommit(Batch[i]);
          sjSnapshotAbort: CloseSnapshot(True);
          sjWriteFile:
            if not WriteFileAtomic(Batch[i].Path, Batch[i].Data, False) then
              Post(sjWriteFile, Batch[i].Tag, False, 'cannot write ' + Batch[i].Path)
            else if Batch[i].Tag <> 0 then
              { somebody waits for this file (/zs_export) }
              Post(sjWriteFile, Batch[i].Tag, True, Batch[i].Path, Length(Batch[i].Data));
          sjNotify:
            Post(sjNotify, Batch[i].Tag, True, '');
          sjAppendText:
            if not AppendToFile(Batch[i].Path, Batch[i].Data) then
              Post(sjAppendText, Batch[i].Tag, False, 'cannot append to ' + Batch[i].Path);
          sjPruneBackups: DoPrune(Batch[i]);
          sjStop: Stop := True;
        end;
      except
        on E: Exception do
          Post(Batch[i].Kind, Batch[i].Tag, False, E.ClassName + ': ' + E.Message);
      end;
      EnterCriticalSection(FLock);
      Dec(FPendingBytes, Length(Batch[i].Data));
      LeaveCriticalSection(FLock);
      Batch[i].Data := '';
    end;
    Batch := nil;
    EnterCriticalSection(FLock);
    FBusy := FJobCount > 0;
    LeaveCriticalSection(FLock);
  until Stop;
  CloseJournal;
  CloseSnapshot(True);
end;

procedure TStoreIO.CloseJournal;
begin
  if FJournal = nil then
    Exit;
  try
    SyncHandle(FJournal.Handle);
  except
  end;
  FreeAndNil(FJournal);
end;

function TStoreIO.OpenJournal(Gen: LongWord): Boolean;
var
  Path, H, Stamp, Old: AnsiString;
  n: LongInt;
begin
  CloseJournal;
  FJournalGen := Gen;
  FJournalBroken := False;
  FJournalKept := False;
  Path := JournalFileName(FDir, FJournalName, Gen);
  try
    if FileExists(Path) then
    begin
      { a journal with this number from an earlier run: never append behind a possibly torn tail,
        and never truncate it either. It is moved aside under a name no file has (a rename onto an
        existing file replaces it on Linux); when it cannot be moved (another program holds it
        open), it stays as it is and this number goes without a journal. }
      Stamp := Path + '.' + FormatDateTime('yyyymmdd-hhnnss', Now);
      Old := Stamp + '.old';
      n := 1;
      while FileExists(Old) do
      begin
        Inc(n);
        Old := Stamp + '-' + IntToStr(n) + '.old';
      end;
      if not RenameFile(Path, Old) then
      begin
        FJournalKept := True;
        raise EInOutError.Create('an older journal with this number cannot be moved aside, it is kept as it is');
      end;
    end;
    FJournal := TFileStream.Create(Path, fmCreate or fmShareDenyWrite);
    H := MakeHeader(JOURNAL_MAGIC, Gen);
    FJournal.WriteBuffer(H[1], Length(H));
    SyncHandle(FJournal.Handle);
    Result := True;
  except
    on E: Exception do
    begin
      FreeAndNil(FJournal);
      FJournalBroken := True;
      Post(sjAppend, 0, False, 'cannot create journal ' + Path + ': ' + E.Message);
      Result := False;
    end;
  end;
end;

procedure TStoreIO.CloseSnapshot(DeleteFile: Boolean);
begin
  if FSnap = nil then
    Exit;
  FreeAndNil(FSnap);
  if DeleteFile then
    SysUtils.DeleteFile(StorePath(FDir, FSnapshotName) + '.tmp');
end;

procedure TStoreIO.DeleteJournalsBelow(Gen: LongWord);
var
  Gens: TGenArray;
  i: LongInt;
begin
  Gens := ListJournalGens(FDir, FJournalName);
  for i := 0 to High(Gens) do
    if (Gens[i] < Gen) and (Gens[i] <> FJournalGen) then
      SysUtils.DeleteFile(JournalFileName(FDir, FJournalName, Gens[i]));
end;

procedure TStoreIO.DoAppend(const Job: TStoreJob);
begin
  if Job.Data = '' then
    Exit;
  if (FJournal = nil) or (FJournalGen <> Job.Gen) then
  begin
    if (FJournal = nil) and FJournalBroken and (FJournalGen = Job.Gen) then
    begin
      Post(sjAppend, Job.Tag, False, Format('journal %d unavailable, changes wait for the next snapshot', [Int64(Job.Gen)]));
      Exit;
    end;
    if not OpenJournal(Job.Gen) then
      Exit;
  end;
  try
    FJournal.WriteBuffer(Job.Data[1], Length(Job.Data));
    SyncHandle(FJournal.Handle);
  except
    on E: Exception do
    begin
      CloseJournal;
      FJournalBroken := True;
      Post(sjAppend, Job.Tag, False, 'journal write failed: ' + E.Message);
      Exit;
    end;
  end;
  if Job.Tag <> 0 then
    Post(sjAppend, Job.Tag, True, '', Length(Job.Data));
end;

procedure TStoreIO.DoSnapshotBegin(const Job: TStoreJob);
var
  H: AnsiString;
begin
  { switch the journal first: every change queued after this job belongs to the new generation }
  OpenJournal(Job.Gen);
  CloseSnapshot(True);
  FSnapGen := Job.Gen;
  FSnapFailed := False;
  { the next start would replay that older journal over this snapshot: the snapshot waits for the
    next number (the commit reports it as not written) }
  if FJournalKept then
  begin
    FSnapFailed := True;
    Exit;
  end;
  try
    FSnap := TFileStream.Create(StorePath(FDir, FSnapshotName) + '.tmp', fmCreate);
    H := MakeHeader(SNAPSHOT_MAGIC, Job.Gen);
    FSnap.WriteBuffer(H[1], Length(H));
  except
    on E: Exception do
    begin
      FreeAndNil(FSnap);
      FSnapFailed := True;
      Post(sjSnapshotBegin, Job.Tag, False, 'cannot create snapshot: ' + E.Message);
    end;
  end;
end;

procedure TStoreIO.DoSnapshotData(const Job: TStoreJob);
begin
  if (FSnap = nil) or FSnapFailed or (Job.Data = '') then
    Exit;
  try
    FSnap.WriteBuffer(Job.Data[1], Length(Job.Data));
  except
    on E: Exception do
    begin
      FSnapFailed := True;
      CloseSnapshot(True);
      Post(sjSnapshotData, Job.Tag, False, 'snapshot write failed: ' + E.Message);
    end;
  end;
end;

procedure TStoreIO.DoSnapshotCommit(const Job: TStoreJob);
var
  Main: AnsiString;
  PrevGen: LongWord;
  Size: Int64;
begin
  if (FSnap = nil) or FSnapFailed or (FSnapGen <> Job.Gen) then
  begin
    CloseSnapshot(True);
    Post(sjSnapshotCommit, Job.Tag, False, 'snapshot was not written completely');
    Exit;
  end;
  Main := StorePath(FDir, FSnapshotName);
  try
    FSnap.WriteBuffer(Job.Data[1], Length(Job.Data));
    SyncHandle(FSnap.Handle);
    Size := FSnap.Size;
  except
    on E: Exception do
    begin
      CloseSnapshot(True);
      Post(sjSnapshotCommit, Job.Tag, False, 'snapshot write failed: ' + E.Message);
      Exit;
    end;
  end;
  FreeAndNil(FSnap);

  if FileExists(Main) then
    ReplaceFile(Main, Main + '.prev');
  if not ReplaceFile(Main + '.tmp', Main) then
  begin
    Post(sjSnapshotCommit, Job.Tag, False, 'cannot replace ' + Main);
    Exit;
  end;
  { the previous snapshot stays usable together with the journals from its generation on. The
    generation is read from the .prev that is there now: when the old snapshot could not be
    renamed, an older .prev is left, and it needs its older journals }
  if not ReadHeaderGen(Main + '.prev', SNAPSHOT_MAGIC, PrevGen) then
    PrevGen := Job.Gen;
  DeleteJournalsBelow(PrevGen);

  if Job.Path <> '' then
  begin
    if not WriteBackup(Main, Job.Gen, Job.Data, Job.Path) then
    begin
      Post(sjSnapshotCommit, Job.Tag, False, 'snapshot saved, but backup ' + Job.Path + ' failed');
      Exit;
    end;
    Post(sjSnapshotCommit, Job.Tag, True, Job.Path, Size);
  end
  else
    Post(sjSnapshotCommit, Job.Tag, True, '', Size);
end;

function TStoreIO.WriteBackup(const Main: AnsiString; Gen: LongWord; const EndRecord, Dest: AnsiString): Boolean;
var
  FOut, FIn: TFileStream;
  Journal, Tmp: AnsiString;
  Ofs, PO, PLen, ValidEnd: LongInt;
  RT: Byte;
  JGen: LongWord;
begin
  Result := False;
  Tmp := Dest + '.tmp';
  try
    EnsureDir(ExtractFileDir(Dest));
    FOut := TFileStream.Create(Tmp, fmCreate);
    try
      FIn := TFileStream.Create(Main, fmOpenRead or fmShareDenyNone);
      try
        if FIn.Size - Length(EndRecord) > 0 then
          FOut.CopyFrom(FIn, FIn.Size - Length(EndRecord));
      finally
        FIn.Free;
      end;
      { changes made while the snapshot was being encoded are in the journal of its generation }
      if ReadWholeFile(JournalFileName(FDir, FJournalName, Gen), Journal) and
         ParseHeader(Journal, JOURNAL_MAGIC, JGen) and (JGen = Gen) then
      begin
        Ofs := STORE_HEADER_SIZE;
        ValidEnd := Ofs;
        while NextRecord(Journal, Ofs, RT, PO, PLen) > 0 do
          ValidEnd := Ofs;
        if ValidEnd > STORE_HEADER_SIZE then
          FOut.WriteBuffer(Journal[STORE_HEADER_SIZE + 1], ValidEnd - STORE_HEADER_SIZE);
      end;
      FOut.WriteBuffer(EndRecord[1], Length(EndRecord));
      SyncHandle(FOut.Handle);
    finally
      FOut.Free;
    end;
    Result := ReplaceFile(Tmp, Dest);
  except
    Result := False;
  end;
  if not Result then
    SysUtils.DeleteFile(Tmp);
end;

procedure TStoreIO.DoPrune(const Job: TStoreJob);
const
  AUTO_SUFFIX = '-auto.zsdb';
var
  L: TStringList;
  i: LongInt;
begin
  if Job.Keep <= 0 then
    Exit;
  L := ListBackups(Job.Path);
  try
    { only automatic backups rotate; manual and pre-operation backups stay until an admin deletes them }
    for i := L.Count - 1 downto 0 do
      if LowerCase(Copy(L[i], Length(L[i]) - Length(AUTO_SUFFIX) + 1, MaxInt)) <> AUTO_SUFFIX then
        L.Delete(i);
    for i := 0 to L.Count - Job.Keep - 1 do
      SysUtils.DeleteFile(StorePath(Job.Path, L[i]));
  finally
    L.Free;
  end;
end;

{ ---------------- writer ---------------- }

constructor TStoreWriter.Create(IO: TStoreIO; LastGen: LongWord);
begin
  inherited Create;
  FIO := IO;
  FGen := LastGen + 1;
end;

procedure TStoreWriter.JournalProfile(const P: TPlayerProfile);
begin
  AppendFrame(FJBuf, FJLen, REC_PROFILE, EncodeProfile(P));
end;

procedure TStoreWriter.JournalMap(const M: TMapProfile);
begin
  AppendFrame(FJBuf, FJLen, REC_MAP, EncodeMap(M));
end;

procedure TStoreWriter.JournalServer(const S: TServerRecords);
begin
  AppendFrame(FJBuf, FJLen, REC_SERVER, EncodeServer(S));
end;

procedure TStoreWriter.JournalSeason(const A: TSeasonArchive);
begin
  AppendFrame(FJBuf, FJLen, REC_SEASON, EncodeSeason(A));
end;

procedure TStoreWriter.JournalDeleteProfile(Id: LongInt);
var
  S: AnsiString;
begin
  SetLength(S, 4);
  Move(Id, S[1], 4);
  AppendFrame(FJBuf, FJLen, REC_DEL_PROFILE, S);
end;

procedure TStoreWriter.JournalDeleteMap(Id: LongInt);
var
  S: AnsiString;
begin
  SetLength(S, 4);
  Move(Id, S[1], 4);
  AppendFrame(FJBuf, FJLen, REC_DEL_MAP, S);
end;

procedure TStoreWriter.JournalPlayerMap(const R: TPlayerMapStats);
begin
  AppendFrame(FJBuf, FJLen, REC_PLAYERMAP, EncodePlayerMap(R));
end;

procedure TStoreWriter.JournalDeletePlayerMap(AccountId: LongInt; const MapName: AnsiString);
var
  S: AnsiString;
begin
  SetLength(S, 4 + Length(MapName));
  Move(AccountId, S[1], 4);
  if MapName <> '' then
    Move(MapName[1], S[5], Length(MapName));
  AppendFrame(FJBuf, FJLen, REC_DEL_PLAYERMAP, S);
end;

procedure TStoreWriter.Flush;
var
  Job: TStoreJob;
begin
  if FJLen = 0 then
    Exit;
  Job := NewJob(sjAppend, FGen);
  Job.Data := Copy(FJBuf, 1, FJLen);
  Inc(FJournalBytes, FJLen);
  FJLen := 0;
  if Length(FJBuf) > 4 * 1024 * 1024 then
    SetLength(FJBuf, 65536);
  FIO.Enqueue(Job);
end;

procedure TStoreWriter.BeginSnapshot(ProfileCount, MapCount, SeasonCount: LongInt);
var
  Meta: array[0..3] of LongWord;
  S: AnsiString;
begin
  if FSnapActive then
    AbortSnapshot;
  Flush;
  Inc(FGen);
  FIO.Enqueue(NewJob(sjSnapshotBegin, FGen));
  FSnapActive := True;
  FSnapRecords := 0;
  FJournalBytes := 0;
  FSLen := 0;
  Meta[0] := ProfileCount;
  Meta[1] := MapCount;
  Meta[2] := SeasonCount;
  Meta[3] := 0;
  SetLength(S, SizeOf(Meta));
  Move(Meta, S[1], SizeOf(Meta));
  AppendFrame(FSBuf, FSLen, REC_META, S);
end;

procedure TStoreWriter.PushSnapshotChunk;
var
  Job: TStoreJob;
begin
  if FSLen = 0 then
    Exit;
  Job := NewJob(sjSnapshotData, FGen);
  Job.Data := Copy(FSBuf, 1, FSLen);
  FSLen := 0;
  FIO.Enqueue(Job);
end;

procedure TStoreWriter.SnapshotProfile(const P: TPlayerProfile);
begin
  if not FSnapActive then
    Exit;
  AppendFrame(FSBuf, FSLen, REC_PROFILE, EncodeProfile(P));
  Inc(FSnapRecords);
  if FSLen >= SNAPSHOT_CHUNK then
    PushSnapshotChunk;
end;

procedure TStoreWriter.SnapshotMap(const M: TMapProfile);
begin
  if not FSnapActive then
    Exit;
  AppendFrame(FSBuf, FSLen, REC_MAP, EncodeMap(M));
  Inc(FSnapRecords);
  if FSLen >= SNAPSHOT_CHUNK then
    PushSnapshotChunk;
end;

procedure TStoreWriter.SnapshotServer(const S: TServerRecords);
begin
  if not FSnapActive then
    Exit;
  AppendFrame(FSBuf, FSLen, REC_SERVER, EncodeServer(S));
  Inc(FSnapRecords);
end;

procedure TStoreWriter.SnapshotSeason(const A: TSeasonArchive);
begin
  if not FSnapActive then
    Exit;
  AppendFrame(FSBuf, FSLen, REC_SEASON, EncodeSeason(A));
  Inc(FSnapRecords);
  if FSLen >= SNAPSHOT_CHUNK then
    PushSnapshotChunk;
end;

procedure TStoreWriter.SnapshotPlayerMap(const R: TPlayerMapStats);
begin
  if not FSnapActive then
    Exit;
  AppendFrame(FSBuf, FSLen, REC_PLAYERMAP, EncodePlayerMap(R));
  Inc(FSnapRecords);
  if FSLen >= SNAPSHOT_CHUNK then
    PushSnapshotChunk;
end;

procedure TStoreWriter.CommitSnapshot(Tag: LongInt; const BackupPath: AnsiString);
var
  Job: TStoreJob;
  Counts: array[0..1] of LongWord;
  S: AnsiString;
begin
  if not FSnapActive then
    Exit;
  PushSnapshotChunk;
  Counts[0] := FSnapRecords;
  Counts[1] := 0;
  SetLength(S, SizeOf(Counts));
  Move(Counts, S[1], SizeOf(Counts));
  Job := NewJob(sjSnapshotCommit, FGen, Tag);
  Job.Data := FrameRecord(REC_END, S);
  Job.Path := BackupPath;
  FIO.Enqueue(Job);
  FSnapActive := False;
  if Length(FSBuf) > 4 * 1024 * 1024 then
    SetLength(FSBuf, 0);
end;

procedure TStoreWriter.AbortSnapshot;
begin
  if not FSnapActive then
    Exit;
  FSLen := 0;
  FSnapActive := False;
  FIO.Enqueue(NewJob(sjSnapshotAbort, FGen));
end;

end.
