unit zs_maps;

{ The maps of the server, for the map vote (zs_engine_mapvote.inc and zs_cmd_mapvote.inc).

  The catalog is every *.pms file of the maps folder, whatever case the extension is written in,
  with the name as the disk has it. A thread of its own reads the folder, never the game or the
  engine thread: a folder on a slow disk must hold up neither. The engine asks for a scan (at the
  start, every [MapVote] RescanMinutes, /zs_maps rescan) and takes the result when it is there.
  Soldat looks for <name>.pms, so on Linux, where names are case sensitive, a map whose file ends
  in .PMS or .Pms may fail to load; such files are listed and flagged (OddExt).

  The search of the map vote compares a text with names, case-insensitive. The kind of match comes
  first - the whole name (MK_EXACT), its beginning (MK_PREFIX), the beginning of a word in it
  (MK_WORD, words split at "_", "-" and spaces), any part of it (MK_PART) - then the shorter name,
  then the order of the names. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util;

const
  { MapMatchRank = kind * MAP_RANK_KIND + the length of the name }
  MAP_RANK_KIND = 100000;
  MK_EXACT = 0;
  MK_PREFIX = 1;
  MK_WORD = 2;
  MK_PART = 3;
  { a name of the maps list is cut here }
  MAP_NAME_MAX = 128;
  { Soldat's own vote runs 20 seconds whatever the library does: an F12 after the end of a vote of
    the library is a late vote for it, not a new vote }
  MV_SOLDAT_VOTE_TICKS = 21 * TICKS_PER_SECOND;
  { the map change of a passed vote comes within this, otherwise the server could not load the map }
  MV_CHANGE_WAIT_TICKS = 10 * TICKS_PER_SECOND;
  { the server announces a map change five seconds before it; a change the score guard cancelled
    never comes, so the wait for it ends by itself }
  MV_CHANGING_TICKS = 10 * TICKS_PER_SECOND;
  { a kick vote of Soldat lasts 20 seconds, and Game.StartVoteMap would take its place }
  MV_KICK_VOTE_TICKS = 21 * TICKS_PER_SECOND;
  { the other matches of a search that are named }
  MV_OTHERS_SHOWN = 5;

  { what MapVoteRequest did }
  MVR_REFUSED = 0;
  MVR_STARTED = 1;
  MVR_VOTED = 2;

type
  TCatalogMap = record
    Name: AnsiString;      { the file name without the extension, as on the disk }
    Ext: AnsiString;       { the extension as written }
    OddExt: Boolean;       { the extension is not written ".pms" }
  end;
  TCatalogMapArray = array of TCatalogMap;

  { what one scan of the maps folder found }
  TMapCatalogData = record
    Folder: AnsiString;
    Found: Boolean;          { the folder exists }
    Maps: TCatalogMapArray;  { sorted by name, case-insensitive }
    ScanTime: TDateTime;
    ScanMs: LongInt;
    Serial: LongInt;         { counts the scans of the catalog }
    Error: AnsiString;
  end;

  { reads the maps folder on a thread of its own }
  TMapCatalog = class
  private
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FThread: TThread;
    FFolder: AnsiString;
    FWanted: Boolean;
    FBusy: Boolean;
    FStop: Boolean;
    FResult: TMapCatalogData;
    FHasResult: Boolean;
    FSerial: LongInt;
  public
    constructor Create;
    destructor Destroy; override;
    { a scan of Folder soon; the thread starts with the first request }
    procedure RequestScan(const Folder: AnsiString);
    { True once for every finished scan }
    function TakeResult(out D: TMapCatalogData): Boolean;
    function Busy: Boolean;
  end;

  { the last start of a map vote of an account (Key = account id) or of a player without an account
    yet (Key = -slot) }
  TMapVoteStarter = record
    Key: LongInt;
    UntilTick: LongInt;
  end;

  { the best match of a search and the others of the same kind }
  TMapSearch = record
    Best: LongInt;           { index in the names searched, -1 = none }
    Rank: LongInt;           { MapMatchRank of Best }
    Others: TIntArray;       { up to MaxOthers more of the kind of Best, the closest first }
    OtherCount: LongInt;     { all of them, also those Others has no room for }
  end;

  { the map vote of the engine (zs_engine_mapvote.inc) }
  TMapVoteData = record
    { the server's maps list, as main.pas sent it last (the indexes of Game.MapsList) }
    List: TStringArray;
    ListOrder: TIntArray;          { the indexes sorted by name, for FindInList }
    ListCurrent: LongInt;          { Game.MapsList.CurrentMapId }
    ListKnown: Boolean;
    ListReason: LongInt;
    ListTick: LongInt;
    { the maps folder }
    Files: TMapCatalogData;
    FilesKnown: Boolean;
    FolderAsked: AnsiString;       { the folder of the last scan asked for }
    NextScanMs: Int64;
    ScanAsker: LongInt;            { /zs_maps rescan: who hears the result; -1 = nobody, 0 = the console }
    ScanReported: Boolean;         { the first scan was written to the server console }
    { the vote that runs }
    Active: Boolean;
    Target: AnsiString;
    TargetIsNext: Boolean;         { the next map of the list: Map.NextMap moves the list on }
    StarterName: AnsiString;
    StartTick: LongInt;
    Shown: Boolean;                { main.pas shows it as Soldat's own vote (ACT_VOTE_START) }
    Voted: array[1..MAX_PLAYERS] of Boolean;
    { the vote that ended last }
    LastTarget: AnsiString;
    LastResult: AnsiString;
    LastEndTick: LongInt;
    GapUntil: LongInt;             { no new vote before this tick ([MapVote] GapSeconds after a vote) }
    SoldatUntil: LongInt;          { Soldat's own vote (the clients' dialog, F12) lasts until this tick }
    { a vote that passed and waits for its map change }
    ChangeTarget: AnsiString;
    ChangeDue: LongInt;
    ChangingUntil: LongInt;        { the server announced a map change: no new vote before this tick }
    MapStartTick: LongInt;         { the last real map change }
    CurMap: AnsiString;
    PrevMap: AnsiString;           { the map played before CurMap }
    KickVoteUntil: LongInt;        { Soldat's kick vote may run until this tick }
    Starters: array of TMapVoteStarter;
  end;

{ the scan itself (the thread runs it; the tests call it) }
function ScanMapsFolder(const Folder: AnsiString): TMapCatalogData;
procedure SortCatalog(var Maps: TCatalogMapArray);
{ the map of that name (any case; the same case first), -1 = none }
function FindCatalog(const Maps: TCatalogMapArray; const Name: AnsiString): LongInt;
{ the map of exactly that name, -1 = none }
function FindCatalogExact(const Maps: TCatalogMapArray; const Name: AnsiString): LongInt;
{ how well Name answers LowText (lower case); lower is closer, -1 = not at all }
function MapMatchRank(const Name, LowText: AnsiString): LongInt;
function SearchNames(const Names: TStringArray; const LowText: AnsiString; MaxOthers: LongInt): TMapSearch;
{ the game style a map is made for by its prefix (ctf_, inf_, htf_), -1 = none of them }
function MapStyleOf(const Name: AnsiString): LongInt;
{ a map of the style played: ctf_/inf_/htf_ maps for their mode, the other maps for the others }
function MapFitsStyle(const Name: AnsiString; GameStyle: LongInt): Boolean;
{ <server>/maps: the server folder is two levels above the script folder }
function DefaultMapsFolder(const ScriptDir: AnsiString): AnsiString;
{ a random number 0..Count - 1 from the random source of the system }
function RandomIndex(Count: LongInt): LongInt;
{ the names main.pas sends, one per line; the indexes stay those of Game.MapsList }
function SplitMapList(const Text: AnsiString): TStringArray;
{ the indexes of List sorted by name (case-insensitive), then by index }
function ListOrderOf(const List: TStringArray): TIntArray;
{ the first index of Name in List (any case), -1 = none }
function FindInList(const List: TStringArray; const Order: TIntArray; const Name: AnsiString): LongInt;
{ how many maps a new scan found that the old one did not have, and the other way round }
procedure CatalogDiff(const Old, New: TCatalogMapArray; out Added, Removed: LongInt);
{ "votemap" or "/votemap", any case: the command Soldat's vote menu and F12 send }
function IsVoteMapWord(const W: AnsiString): Boolean;

implementation

type
  TMapScanThread = class(TThread)
  private
    FOwner: TMapCatalog;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TMapCatalog);
  end;

{ ---------------- the scan ---------------- }

function CatalogBefore(const A, B: TCatalogMap): Boolean;
var
  C: LongInt;
begin
  C := CompareText(A.Name, B.Name);
  if C = 0 then
    C := CompareStr(A.Name, B.Name);
  Result := C < 0;
end;

procedure SortCatalog(var Maps: TCatalogMapArray);

  procedure QSort(L, R: LongInt);
  var
    i, j: LongInt;
    P, T: TCatalogMap;
  begin
    while L < R do
    begin
      i := L;
      j := R;
      P := Maps[(L + R) div 2];
      repeat
        while CatalogBefore(Maps[i], P) do
          Inc(i);
        while CatalogBefore(P, Maps[j]) do
          Dec(j);
        if i <= j then
        begin
          T := Maps[i];
          Maps[i] := Maps[j];
          Maps[j] := T;
          Inc(i);
          Dec(j);
        end;
      until i > j;
      { the smaller part first keeps the recursion shallow }
      if j - L < R - i then
      begin
        QSort(L, j);
        L := i;
      end
      else
      begin
        QSort(i, R);
        R := j;
      end;
    end;
  end;

begin
  if Length(Maps) > 1 then
    QSort(0, High(Maps));
end;

function ScanMapsFolder(const Folder: AnsiString): TMapCatalogData;
var
  SR: TSearchRec;
  T0: Int64;
  Ext, Name: AnsiString;
  n: LongInt;
begin
  Result := Default(TMapCatalogData);
  Result.Folder := Folder;
  Result.ScanTime := Now;
  T0 := MonoMs;
  n := 0;
  Result.Found := (Folder <> '') and DirectoryExists(Folder);
  { every file: a mask of "*.pms" would miss .PMS on Linux }
  if Result.Found and (FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, SR) = 0) then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then
        Continue;
      Ext := ExtractFileExt(SR.Name);
      if not SameText(Ext, '.pms') then
        Continue;
      Name := Copy(SR.Name, 1, Length(SR.Name) - Length(Ext));
      if Name = '' then
        Continue;
      if n >= Length(Result.Maps) then
        SetLength(Result.Maps, n * 2 + 64);
      Result.Maps[n].Name := Name;
      Result.Maps[n].Ext := Ext;
      Result.Maps[n].OddExt := Ext <> '.pms';
      Inc(n);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  SetLength(Result.Maps, n);
  SortCatalog(Result.Maps);
  Result.ScanMs := MonoMs - T0;
end;

{ the first map whose name equals Name in any case }
function FirstOfName(const Maps: TCatalogMapArray; const Name: AnsiString): LongInt;
var
  L, R, M, C: LongInt;
begin
  Result := -1;
  L := 0;
  R := High(Maps);
  while L <= R do
  begin
    M := (L + R) div 2;
    C := CompareText(Maps[M].Name, Name);
    if C < 0 then
      L := M + 1
    else
    begin
      if C = 0 then
        Result := M;
      R := M - 1;
    end;
  end;
end;

function FindCatalog(const Maps: TCatalogMapArray; const Name: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := FirstOfName(Maps, Name);
  if Result < 0 then
    Exit;
  k := Result;
  while (k <= High(Maps)) and (CompareText(Maps[k].Name, Name) = 0) do
  begin
    if Maps[k].Name = Name then
      Exit(k);
    Inc(k);
  end;
end;

function FindCatalogExact(const Maps: TCatalogMapArray; const Name: AnsiString): LongInt;
begin
  Result := FindCatalog(Maps, Name);
  if (Result >= 0) and (Maps[Result].Name <> Name) then
    Result := -1;
end;

procedure CatalogDiff(const Old, New: TCatalogMapArray; out Added, Removed: LongInt);
var
  i, j: LongInt;
begin
  { both are sorted the same way: one walk through them }
  Added := 0;
  Removed := 0;
  i := 0;
  j := 0;
  while (i < Length(Old)) or (j < Length(New)) do
    if i >= Length(Old) then
    begin
      Inc(Added);
      Inc(j);
    end
    else if j >= Length(New) then
    begin
      Inc(Removed);
      Inc(i);
    end
    else if CatalogBefore(Old[i], New[j]) then
    begin
      Inc(Removed);
      Inc(i);
    end
    else if CatalogBefore(New[j], Old[i]) then
    begin
      Inc(Added);
      Inc(j);
    end
    else
    begin
      Inc(i);
      Inc(j);
    end;
end;

function IsVoteMapWord(const W: AnsiString): Boolean;
begin
  Result := SameText(W, 'votemap') or SameText(W, '/votemap');
end;

{ ---------------- the scan thread ---------------- }

constructor TMapScanThread.Create(Owner: TMapCatalog);
begin
  FOwner := Owner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TMapScanThread.Execute;
var
  Folder: AnsiString;
  D: TMapCatalogData;
  Go: Boolean;
begin
  GuardWorkerThread;
  while not FOwner.FStop do
  begin
    EnterCriticalSection(FOwner.FLock);
    try
      Go := FOwner.FWanted;
      FOwner.FWanted := False;
      Folder := FOwner.FFolder;
      UniqueString(Folder);
      if Go then
        FOwner.FBusy := True;
    finally
      LeaveCriticalSection(FOwner.FLock);
    end;
    if not Go then
    begin
      RTLEventWaitFor(FOwner.FWake, 1000);
      Continue;
    end;
    try
      D := ScanMapsFolder(Folder);
    except
      on Ex: Exception do
      begin
        D := Default(TMapCatalogData);
        D.Folder := Folder;
        D.ScanTime := Now;
        D.Error := Ex.ClassName + ': ' + Ex.Message;
      end;
    end;
    EnterCriticalSection(FOwner.FLock);
    try
      Inc(FOwner.FSerial);
      D.Serial := FOwner.FSerial;
      FOwner.FResult := D;
      FOwner.FHasResult := True;
      FOwner.FBusy := False;
    finally
      LeaveCriticalSection(FOwner.FLock);
    end;
    D := Default(TMapCatalogData);
  end;
end;

constructor TMapCatalog.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
end;

destructor TMapCatalog.Destroy;
begin
  FStop := True;
  if FThread <> nil then
  begin
    RTLEventSetEvent(FWake);
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TMapCatalog.RequestScan(const Folder: AnsiString);
begin
  EnterCriticalSection(FLock);
  try
    FFolder := Folder;
    UniqueString(FFolder);
    FWanted := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  if FThread = nil then
    FThread := TMapScanThread.Create(Self);
  RTLEventSetEvent(FWake);
end;

function TMapCatalog.TakeResult(out D: TMapCatalogData): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FHasResult;
    if Result then
    begin
      D := FResult;
      FResult := Default(TMapCatalogData);
      FHasResult := False;
    end
    else
      D := Default(TMapCatalogData);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMapCatalog.Busy: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FBusy or FWanted;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ ---------------- the search ---------------- }

function MapMatchRank(const Name, LowText: AnsiString): LongInt;
var
  Low: AnsiString;
  m, i, Kind: LongInt;
begin
  Result := -1;
  m := Length(LowText);
  if (m = 0) or (Name = '') then
    Exit;
  Low := LowerCase(Name);
  if Pos(LowText, Low) = 0 then
    Exit;
  if Low = LowText then
    Kind := MK_EXACT
  else if Copy(Low, 1, m) = LowText then
    Kind := MK_PREFIX
  else
  begin
    Kind := MK_PART;
    for i := 2 to Length(Low) - m + 1 do
      if Low[i - 1] in ['_', '-', ' '] then
        if Copy(Low, i, m) = LowText then
        begin
          Kind := MK_WORD;
          Break;
        end;
  end;
  Result := Kind * MAP_RANK_KIND + Min(MAP_RANK_KIND - 1, Length(Name));
end;

function SearchNames(const Names: TStringArray; const LowText: AnsiString; MaxOthers: LongInt): TMapSearch;
var
  k, j, n: LongInt;
  Ranks: TIntArray;
begin
  Result.Best := -1;
  Result.Rank := MaxInt;
  Result.Others := nil;
  Result.OtherCount := 0;
  if LowText = '' then
    Exit;
  Ranks := nil;
  SetLength(Ranks, Length(Names));
  for k := 0 to High(Names) do
  begin
    Ranks[k] := MapMatchRank(Names[k], LowText);
    { the first of equal ranks wins: the order of the names }
    if (Ranks[k] >= 0) and (Ranks[k] < Result.Rank) then
    begin
      Result.Rank := Ranks[k];
      Result.Best := k;
    end;
  end;
  if Result.Best < 0 then
    Exit;
  { the others of the same kind: a short list kept in order while going through them once }
  for k := 0 to High(Names) do
    if (k <> Result.Best) and (Ranks[k] >= 0) and (Ranks[k] div MAP_RANK_KIND = Result.Rank div MAP_RANK_KIND) then
    begin
      Inc(Result.OtherCount);
      n := Length(Result.Others);
      if n < MaxOthers then
      begin
        SetLength(Result.Others, n + 1);
        j := n;
      end
      else if (n > 0) and (Ranks[k] < Ranks[Result.Others[n - 1]]) then
        j := n - 1
      else
        Continue;
      while (j > 0) and (Ranks[Result.Others[j - 1]] > Ranks[k]) do
      begin
        Result.Others[j] := Result.Others[j - 1];
        Dec(j);
      end;
      Result.Others[j] := k;
    end;
end;

function MapStyleOf(const Name: AnsiString): LongInt;
var
  P: AnsiString;
begin
  P := LowerCase(Copy(Name, 1, 4));
  if P = 'ctf_' then
    Result := GS_CTF
  else if P = 'inf_' then
    Result := GS_INF
  else if P = 'htf_' then
    Result := GS_HTF
  else
    Result := -1;
end;

function MapFitsStyle(const Name: AnsiString; GameStyle: LongInt): Boolean;
begin
  if GameStyle in [GS_CTF, GS_INF, GS_HTF] then
    Result := MapStyleOf(Name) = GameStyle
  else
    Result := MapStyleOf(Name) < 0;
end;

function DefaultMapsFolder(const ScriptDir: AnsiString): AnsiString;
var
  Dir: AnsiString;
begin
  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(ScriptDir));
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(ExtractFileDir(Dir))) + 'maps';
end;

function RandomIndex(Count: LongInt): LongInt;
var
  B: AnsiString;
  V: LongWord;
begin
  if Count <= 1 then
    Exit(0);
  V := 0;
  B := SecureRandomBytes(SizeOf(V));
  if Length(B) >= SizeOf(V) then
    Move(B[1], V, SizeOf(V));
  Result := LongInt(V mod LongWord(Count));
end;

{ ---------------- the maps list ---------------- }

function SplitMapList(const Text: AnsiString): TStringArray;
var
  i, Start, n: LongInt;
begin
  Result := nil;
  n := 0;
  Start := 1;
  for i := 1 to Length(Text) + 1 do
    if (i > Length(Text)) or (Text[i] = #10) then
    begin
      { the line break after the last name ends the list, it starts no empty name }
      if (i <= Length(Text)) or (i > Start) then
      begin
        if n >= Length(Result) then
          SetLength(Result, n * 2 + 16);
        Result[n] := Copy(Trim(Copy(Text, Start, i - Start)), 1, MAP_NAME_MAX);
        Inc(n);
      end;
      Start := i + 1;
    end;
  SetLength(Result, n);
end;

function ListOrderOf(const List: TStringArray): TIntArray;
var
  Idx: TIntArray;
  k: LongInt;

  function Before(A, B: LongInt): Boolean;
  var
    C: LongInt;
  begin
    C := CompareText(List[A], List[B]);
    if C = 0 then
      C := A - B;
    Result := C < 0;
  end;

  procedure QSort(L, R: LongInt);
  var
    i, j, P, T: LongInt;
  begin
    while L < R do
    begin
      i := L;
      j := R;
      P := Idx[(L + R) div 2];
      repeat
        while Before(Idx[i], P) do
          Inc(i);
        while Before(P, Idx[j]) do
          Dec(j);
        if i <= j then
        begin
          T := Idx[i];
          Idx[i] := Idx[j];
          Idx[j] := T;
          Inc(i);
          Dec(j);
        end;
      until i > j;
      if j - L < R - i then
      begin
        QSort(L, j);
        L := i;
      end
      else
      begin
        QSort(i, R);
        R := j;
      end;
    end;
  end;

begin
  Idx := nil;
  SetLength(Idx, Length(List));
  for k := 0 to High(List) do
    Idx[k] := k;
  if Length(Idx) > 1 then
    QSort(0, High(Idx));
  Result := Idx;
end;

function FindInList(const List: TStringArray; const Order: TIntArray; const Name: AnsiString): LongInt;
var
  L, R, M, C: LongInt;
begin
  Result := -1;
  if (Name = '') or (Length(Order) <> Length(List)) then
    Exit;
  L := 0;
  R := High(Order);
  while L <= R do
  begin
    M := (L + R) div 2;
    C := CompareText(List[Order[M]], Name);
    if C < 0 then
      L := M + 1
    else
    begin
      { equal names are sorted by index: the first one found going left is the lowest }
      if C = 0 then
        Result := Order[M];
      R := M - 1;
    end;
  end;
end;

end.
