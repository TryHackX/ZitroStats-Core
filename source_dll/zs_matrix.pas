unit zs_matrix;

{ [Matrix]: the player-on-map records - what one account did on one map, with whom and with which
  weapons - kept in memory by TPlayerMapTable (TStatsDB.PM) and saved in the store as REC_PLAYERMAP
  records (a removal as REC_DEL_PLAYERMAP).

  A record (TPlayerMapStats, zs_types) is made at the first event counted for an account on a map
  and is keyed by the account id and the map NAME, as maps are in the shared database: a name
  survives resets and means the same map on every server. Its lists are sparse and sorted by their
  keys: weapons (slot), rivals (the opponent's account), weapon matchups (my weapon, their weapon)
  and heat cells (the cells of the map heatmap). A rival list holds at most MaxRivals entries
  ([Matrix] MaxRivals): when it is full, the entry with the fewest fights (kills and deaths) and,
  of those, the oldest last fight goes. What an account did over all maps is the sum of its records
  (SumAccount); nothing of it is kept twice.

  The engine records into it (zs_engine_matrix.inc) only for humans while the statistics count, and
  only with [Matrix] Enabled = 1. Everything runs on the engine thread under the state lock.

  API for the views (engine thread, state lock held; E.DB.PM is the table):
    E.Cfg.MatrixEnabled                       [Matrix] Enabled: 0 = nothing is recorded
    DB.PM.Find(AccountId, MapName): PPlayerMapStats
                                              one account on one map (the map name in any case),
                                              nil when there is no record
    DB.PM.OfAccount(AccountId): TPMRefArray   the records of an account, one per map, in no order
    DB.PM.OfMap(MapName): TPMRefArray         the records of a map, one per account, in no order
    DB.PM.SumAccount(AccountId, Sum)          an account over all its maps: every counter added up
                                              (the best streak and the longest kill: the largest,
                                              the dates: the first and the last), the weapons,
                                              rivals, matchups and heat cells added entry by entry
                                              (heat cells of different maps only share numbers);
                                              Sum.MapName = ''
    DB.PM.SumMap(MapName, Sum)                a map over all its accounts, as SumAccount; the rivals
                                              stay empty (see MapPairs), Sum.AccountId = 0
    DB.PM.MapPairs(MapName): TPMPairArray     the pairs of players of a map with their kills,
                                              damage and points both ways, each pair once (A < B),
                                              most fights first
    DB.PM.Count                               records in the table
    DB.PM.Places / DB.PM.Items[Place]         every record: Items is nil for a free place
    PMWeaponPos, PMRivalPos, PMMatchupPos, HeatCellPos, MatchupCellPos (zs_fields)
                                              an entry of a list by its key (binary search)
  The pointers hold until the table changes (the next event or command); a view reads them at once.
  The records of a map on the server right now are E.Match.MapName's; account ids are
  TPlayerProfile.ID (DB.IndexOfId). A rival id may name an account this server does not have (yet,
  or any more): a view skips it. A rival entry holds the kills, the damage and the points both ways
  (PointsWon: what the account won from him, PointsLost: what it lost to him). The per-account
  weapon distances and times to kill are fields of TWeaponStats (DistBucket, KillDistSum/Count,
  TTKSumTicks/Count, VestKills), the new fields of a map are in TMapProfile (LastLoadedTime,
  Rounds*, KillsByTeam, Matchups).

  With a shared database (Engine = mysql, zs_sqldb) a change made here marks the record for the
  next exchange (SyncState PMS_LOCAL); a change the database brought (PMS_REMOTE) changes the base
  (SyncBase) as well, so the three-way merge does not send it back. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, zs_types, zs_util, zs_fields, zs_store;

const
  { the heat cells one record keeps at most (a map keeps 4096 of its own) }
  PM_MAX_HEAT = 2048;
  { the size of a heat cell in pixels, the grid of the map heatmap (HeatAdd, zs_engine_combat.inc) }
  PM_HEAT_CELL_PX = 64;

  { TPlayerMapTable.SyncState }
  PMS_OFF = 0;       { no shared database }
  PMS_LOCAL = 1;     { a change made here: it goes to the database with the next exchange }
  PMS_REMOTE = 2;    { a change the database brought: it is the database's already }

type
  TPMRefArray = array of PPlayerMapStats;

  { a record removed here that the shared database still has: the removal goes in with the next
    exchange, from the state the database had (Base) }
  TPMGone = record
    AccountId: LongInt;
    MapName: AnsiString;
    Base: AnsiString;
  end;
  TPMGoneArray = array of TPMGone;

  { two players of one map (MapPairs), each pair once: A < B }
  TPMPair = record
    A, B: LongInt;             { account ids }
    AKills, BKills: LongInt;   { A killed B, B killed A }
    ADamage, BDamage: Double;  { A dealt to B, B dealt to A }
    LastFight: Double;
    { the points A won from B and lost to B, and B's the same way: each from its own entry; a side
      whose entry of the other is gone (MaxRivals, a prune) has the other side's turned round }
    AWon, ALost, BWon, BLost: LongInt;
  end;
  TPMPairArray = array of TPMPair;

  TPMSyncStateFunc = function: LongInt of object;
  { when an account played last, 0 when there is no such account (Prune) }
  TPMLastPlayedFunc = function(AccountId: LongInt): Double of object;

  TPMKey = record
    AccountId: LongInt;
    MapName: AnsiString;
  end;

  TPlayerMapTable = class
  private
    FRecs: TPlayerMapPtrArray;
    FCount: LongInt;                 { places in use, the free ones among them }
    FLive: LongInt;
    FFree: TIntArray;                { free places, used again first }
    FFreeCount: LongInt;
    FMapIdx: TStrIndex;              { map name (any case) -> map number }
    FMapNames: array of AnsiString;
    FMapRecs: array of TIntArray;    { map number -> places }
    FAccKeys: array of LongInt;      { open addressing: account id, 0 = empty }
    FAccRecs: array of TIntArray;    { the places of that account }
    FAccUsed: LongInt;
    FDirty: TIntArray;
    FDirtyCount: LongInt;
    FRemoved: array of TPMKey;       { removals for the journal }
    FRemovedCount: LongInt;
    FSync: TIntArray;
    FSyncCount: LongInt;
    FGone: TPMGoneArray;
    FGoneCount: LongInt;
    FSnapPos: LongInt;
    FRivalGone: TIntArray;           { accounts removed: their rival entries go (FlushRivalRemovals) }
    FRivalHold: LongInt;             { HoldRivalRemovals: they go at ReleaseRivalRemovals }
    { a change made here while the shared database's changes are applied (a renumbering, a merge
      of a new account): it is this server's, and goes to the database }
    FForceLocal: Boolean;
    function GetItem(Place: LongInt): PPlayerMapStats;
    function State: LongInt;
    function AccSlot(AccountId: LongInt; Add: Boolean): LongInt;
    procedure GrowAcc;
    procedure Link(Place: LongInt);
    procedure CutLink(var A: TIntArray; Pos, Place: LongInt; OfMap: Boolean);
    procedure Unlink(Place: LongInt);
    procedure RebuildIndexes;
    procedure QueueGone(AccountId: LongInt; const MapName, Base: AnsiString);
    procedure ForceSyncMark(Place: LongInt);
    function RenumberRivalsIn(var R: TPlayerMapStats; OldId, NewId, Owner: LongInt): Boolean;
    procedure RenumberBase(Place, OldId, NewId: LongInt);
    procedure Release(Place: LongInt; Journal: Boolean);
    procedure DropEmptyLinks;
    procedure RemovePlaces(const L: TIntArray);
  public
    { [Matrix] MaxRivals (0 = no limit) }
    MaxRivals: LongInt;
    { set by the owner (TStatsDB): whether a change goes to a shared database, and how }
    SyncState: TPMSyncStateFunc;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { the records of the store (St.PlayerMaps) become the table's; St gives them up }
    procedure TakeState(var St: TStoreState);
    { records of accounts that are not there any more go (after loading) }
    function DropOrphans(Exists: TPMLastPlayedFunc): LongInt;

    property Count: LongInt read FLive;
    property Places: LongInt read FCount;
    property Items[Place: LongInt]: PPlayerMapStats read GetItem;
    { the number of a map in the table (map names in any case are one map), -1 when the table has
      none (Add = False) }
    function MapNumber(const MapName: AnsiString; Add: Boolean): LongInt;
    function FindNo(AccountId, MapNo: LongInt): LongInt;
    function Find(AccountId: LongInt; const MapName: AnsiString): PPlayerMapStats;
    { the place of the record of an account on a map, made (empty, FirstPlayed = NowT) when missing }
    function Obtain(AccountId, MapNo: LongInt; NowT: Double): LongInt;
    function OfAccount(AccountId: LongInt): TPMRefArray;
    function OfMap(const MapName: AnsiString): TPMRefArray;
    procedure SumAccount(AccountId: LongInt; out Sum: TPlayerMapStats);
    procedure SumMap(const MapName: AnsiString; out Sum: TPlayerMapStats);
    function MapPairs(const MapName: AnsiString): TPMPairArray;

    { the record at Place changed: it goes into the journal, and to a shared database }
    procedure Touch(Place: LongInt);
    procedure Remove(Place: LongInt);
    procedure RemoveAll;
    procedure RemoveMap(const MapName: AnsiString);
    { the records of an account go (a reset of its statistics); the rival entries that name it in
      the other records are their statistics and stay }
    procedure RemoveRecordsOf(AccountId: LongInt);
    { the records of an account go; its rival entries in the other records go with the next
      FlushRivalRemovals (at once unless Batch). Remote: the shared database removed the account,
      the bases lose the entries too. }
    procedure RemoveAccount(AccountId: LongInt; Remote, Batch: Boolean);
    procedure FlushRivalRemovals(Remote: Boolean);
    { many accounts removed one by one (the changes of the shared database): the rival entries
      naming them go once, at the matching ReleaseRivalRemovals }
    procedure HoldRivalRemovals;
    procedure ReleaseRivalRemovals(Remote: Boolean);
    { two accounts are one now: the records of SrcId are added to DstId's map by map, and every
      rival entry that names SrcId names DstId (an entry of the account itself goes). Remote: the
      shared database merged them already, the bases are merged the same way. }
    procedure MergeAccount(SrcId, DstId: LongInt; Remote: Boolean);
    { the shared database gave a new account of this server another number }
    procedure RenumberAccount(OldId, NewId: LongInt);
    { the records of accounts that have not played for Days days (or are not there any more) go
      (0 = none of these); with MapDays > 0 also the records of a map the account has not played on
      for MapDays days, and the rival entries not fought for MapDays days of the records that stay;
      returns how many records }
    function Prune(Days, MapDays: LongInt; NowT: Double; LastPlayed: TPMLastPlayedFunc): LongInt;
    { what the records take in memory, roughly: the records with their lists and texts, not the
      indexes of the table (/zs_status) }
    function ApproxBytes: Int64;

    procedure FlushJournal(W: TStoreWriter);
    function PendingRemovals: Boolean;
    procedure SnapshotBegin;
    { writes records while Budget lasts (Budget goes down); True when every record is written }
    function SnapshotStep(W: TStoreWriter; var Budget: LongInt): Boolean;

    { the exchange with a shared database (zs_sqldb) }
    procedure SyncMark(Place: LongInt);
    procedure TakeSyncWork(out Marked: TIntArray; out Gone: TPMGoneArray);
    procedure RequeueGone(const Gone: TPMGoneArray);
    function SyncPending: TIntArray;
    function GonePending: TPMGoneArray;
    { a removal waiting to go in: its base becomes Base (the answer to a push that was on its way) }
    function UpdateGone(AccountId: LongInt; const MapName, Base: AnsiString): Boolean;
    { what the files hold counts as the database's (a start without the database) }
    procedure SetBasesFromRecords;
  end;

{ the list entries, made when missing; the pointers hold until the list changes }
function PMWeaponOf(var R: TPlayerMapStats; Slot: LongInt): PPMWeapon;
{ a new rival when the list is full: the weakest goes first (PMWeakestRival) }
function PMRivalOf(var R: TPlayerMapStats; Id, MaxRivals: LongInt): PPMRival;
function PMMatchupOf(var R: TPlayerMapStats; Mine, Theirs: LongInt): PPMMatchup;
{ a kill (IsKill) or a death at X, Y in the cell of the map heatmap; a new cell only while the
  record has fewer than PM_MAX_HEAT }
procedure PMHeatAdd(var R: TPlayerMapStats; X, Y: Single; IsKill: Boolean);
{ the weapon matchups of a map: one kill with Killer against Victim (weapon slots) }
procedure MapMatchupAdd(var M: TMapProfile; Killer, Victim: LongInt);

implementation

const
  HASH_MUL = LongWord(2654435761);

{ ---------------- list entries ---------------- }

function PMWeaponOf(var R: TPlayerMapStats; Slot: LongInt): PPMWeapon;
var
  p: LongInt;
  E: TPMWeapon;
begin
  if not PMWeaponPos(R.Weapons, Slot, p) then
  begin
    FillChar(E, SizeOf(E), 0);
    E.Slot := Slot;
    Insert(E, R.Weapons, p);
  end;
  Result := @R.Weapons[p];
end;

function PMRivalOf(var R: TPlayerMapStats; Id, MaxRivals: LongInt): PPMRival;
var
  p: LongInt;
  E: TPMRival;
begin
  if not PMRivalPos(R.Rivals, Id, p) then
  begin
    if (MaxRivals > 0) and (Length(R.Rivals) >= MaxRivals) then
    begin
      PMTrimRivals(R.Rivals, MaxRivals - 1);
      PMRivalPos(R.Rivals, Id, p);
    end;
    FillChar(E, SizeOf(E), 0);
    E.Id := Id;
    Insert(E, R.Rivals, p);
  end;
  Result := @R.Rivals[p];
end;

function PMMatchupOf(var R: TPlayerMapStats; Mine, Theirs: LongInt): PPMMatchup;
var
  p: LongInt;
  E: TPMMatchup;
begin
  if not PMMatchupPos(R.Matchups, Mine, Theirs, p) then
  begin
    FillChar(E, SizeOf(E), 0);
    E.Mine := Mine;
    E.Theirs := Theirs;
    Insert(E, R.Matchups, p);
  end;
  Result := @R.Matchups[p];
end;

procedure PMHeatAdd(var R: TPlayerMapStats; X, Y: Single; IsKill: Boolean);
var
  Cell, p: LongInt;
  E: THeatCell;
begin
  Cell := EnsureRange(Floor(Y / PM_HEAT_CELL_PX) + 2048, 0, 4095) * 4096 +
    EnsureRange(Floor(X / PM_HEAT_CELL_PX) + 2048, 0, 4095);
  if not HeatCellPos(R.Heat, Cell, p) then
  begin
    if Length(R.Heat) >= PM_MAX_HEAT then
      Exit;
    E.Cell := Cell;
    E.Kills := 0;
    E.Deaths := 0;
    Insert(E, R.Heat, p);
  end;
  if IsKill then
    Inc(R.Heat[p].Kills)
  else
    Inc(R.Heat[p].Deaths);
end;

procedure MapMatchupAdd(var M: TMapProfile; Killer, Victim: LongInt);
var
  p: LongInt;
  E: TMatchupCell;
begin
  if MatchupCellPos(M.Matchups, Killer, Victim, p) then
    Inc(M.Matchups[p].Kills)
  else
  begin
    E.Killer := Killer;
    E.Victim := Victim;
    E.Kills := 1;
    Insert(E, M.Matchups, p);
  end;
end;

{ ---------------- the table ---------------- }

constructor TPlayerMapTable.Create;
begin
  inherited Create;
  FMapIdx := TStrIndex.Create(256);
  MaxRivals := 200;
end;

destructor TPlayerMapTable.Destroy;
begin
  Clear;
  FMapIdx.Free;
  inherited Destroy;
end;

procedure TPlayerMapTable.Clear;
begin
  FreePlayerMaps(FRecs);
  FCount := 0;
  FLive := 0;
  FFree := nil;
  FFreeCount := 0;
  FMapIdx.Clear;
  FMapNames := nil;
  FMapRecs := nil;
  FAccKeys := nil;
  FAccRecs := nil;
  FAccUsed := 0;
  FDirty := nil;
  FDirtyCount := 0;
  FRemoved := nil;
  FRemovedCount := 0;
  FSync := nil;
  FSyncCount := 0;
  FGone := nil;
  FGoneCount := 0;
  FSnapPos := 0;
  FRivalGone := nil;
end;

function TPlayerMapTable.GetItem(Place: LongInt): PPlayerMapStats;
begin
  if (Place >= 0) and (Place < FCount) then
    Result := FRecs[Place]
  else
    Result := nil;
end;

function TPlayerMapTable.State: LongInt;
begin
  if Assigned(SyncState) then
    Result := SyncState()
  else
    Result := PMS_OFF;
  if FForceLocal and (Result = PMS_REMOTE) then
    Result := PMS_LOCAL;
end;

{$PUSH}{$Q-}{$R-}
function AccHash(AccountId: LongInt): LongWord; inline;
begin
  Result := LongWord(AccountId) * HASH_MUL;
end;
{$POP}

function TPlayerMapTable.AccSlot(AccountId: LongInt; Add: Boolean): LongInt;
var
  Mask, h: LongInt;
begin
  Result := -1;
  if AccountId <= 0 then
    Exit;
  if Length(FAccKeys) = 0 then
  begin
    if not Add then
      Exit;
    SetLength(FAccKeys, 1024);
    SetLength(FAccRecs, 1024);
    FAccUsed := 0;
  end;
  Mask := High(FAccKeys);
  h := LongInt(AccHash(AccountId) and LongWord(Mask));
  while FAccKeys[h] <> 0 do
  begin
    if FAccKeys[h] = AccountId then
      Exit(h);
    h := (h + 1) and Mask;
  end;
  if not Add then
    Exit;
  if (FAccUsed + 1) * 2 > Length(FAccKeys) then
  begin
    GrowAcc;
    Exit(AccSlot(AccountId, True));
  end;
  FAccKeys[h] := AccountId;
  FAccRecs[h] := nil;
  Inc(FAccUsed);
  Result := h;
end;

procedure TPlayerMapTable.GrowAcc;
var
  OldKeys: array of LongInt;
  OldRecs: array of TIntArray;
  k, h, Mask: LongInt;
begin
  OldKeys := FAccKeys;
  OldRecs := FAccRecs;
  FAccKeys := nil;
  FAccRecs := nil;
  SetLength(FAccKeys, Length(OldKeys) * 2);
  SetLength(FAccRecs, Length(OldKeys) * 2);
  Mask := High(FAccKeys);
  FAccUsed := 0;
  for k := 0 to High(OldKeys) do
    if (OldKeys[k] <> 0) and (Length(OldRecs[k]) > 0) then
    begin
      h := LongInt(AccHash(OldKeys[k]) and LongWord(Mask));
      while FAccKeys[h] <> 0 do
        h := (h + 1) and Mask;
      FAccKeys[h] := OldKeys[k];
      FAccRecs[h] := OldRecs[k];
      Inc(FAccUsed);
    end;
end;

procedure AddInt(var A: TIntArray; V: LongInt);
var
  n: LongInt;
begin
  n := Length(A);
  SetLength(A, n + 1);
  A[n] := V;
end;

{ the list of a map (OfMap) or of an account without Place, which a record keeps at Pos: the last
  one takes its place, so nothing is looked for }
procedure TPlayerMapTable.CutLink(var A: TIntArray; Pos, Place: LongInt; OfMap: Boolean);
var
  n, k: LongInt;
begin
  n := Length(A);
  if (Pos < 0) or (Pos >= n) or (A[Pos] <> Place) then
  begin
    Pos := -1;
    for k := 0 to n - 1 do
      if A[k] = Place then
      begin
        Pos := k;
        Break;
      end;
    if Pos < 0 then
      Exit;
  end;
  A[Pos] := A[n - 1];
  SetLength(A, n - 1);
  if (Pos < n - 1) and (FRecs[A[Pos]] <> nil) then
  begin
    if OfMap then
      FRecs[A[Pos]]^.MapPos := Pos
    else
      FRecs[A[Pos]]^.AccPos := Pos;
  end;
end;

procedure TPlayerMapTable.Link(Place: LongInt);
var
  R: PPlayerMapStats;
  h: LongInt;
begin
  R := FRecs[Place];
  if (R^.MapNo >= 0) and (R^.MapNo < Length(FMapRecs)) then
  begin
    R^.MapPos := Length(FMapRecs[R^.MapNo]);
    AddInt(FMapRecs[R^.MapNo], Place);
  end;
  h := AccSlot(R^.AccountId, True);
  if h >= 0 then
  begin
    R^.AccPos := Length(FAccRecs[h]);
    AddInt(FAccRecs[h], Place);
  end;
end;

procedure TPlayerMapTable.Unlink(Place: LongInt);
var
  R: PPlayerMapStats;
  h: LongInt;
begin
  R := FRecs[Place];
  if (R^.MapNo >= 0) and (R^.MapNo < Length(FMapRecs)) then
    CutLink(FMapRecs[R^.MapNo], R^.MapPos, Place, True);
  h := AccSlot(R^.AccountId, False);
  if h >= 0 then
    CutLink(FAccRecs[h], R^.AccPos, Place, False);
end;

{ the numbers of the maps, the lists of the maps and the accounts, and the free places, from the
  records: the lists are counted first and made at their size, so a large table loads in a time
  that grows with it, not with its square }
procedure TPlayerMapTable.RebuildIndexes;
var
  i, h, m, Size: LongInt;
  MapCounts, AccCounts: TIntArray;
  R: PPlayerMapStats;
begin
  FMapIdx.Clear;
  FMapNames := nil;
  FMapRecs := nil;
  FAccKeys := nil;
  FAccRecs := nil;
  FAccUsed := 0;
  FFree := nil;
  FFreeCount := 0;
  FLive := 0;
  { the hash of the accounts at most half full even with every record another account: no growing
    in between }
  Size := 1024;
  while Size < FCount * 2 do
    Size := Size * 2;
  SetLength(FAccKeys, Size);
  SetLength(FAccRecs, Size);
  AccCounts := nil;
  SetLength(AccCounts, Size);
  MapCounts := nil;
  for i := 0 to FCount - 1 do
  begin
    R := FRecs[i];
    if R = nil then
    begin
      if FFreeCount >= Length(FFree) then
        SetLength(FFree, FFreeCount * 2 + 16);
      FFree[FFreeCount] := i;
      Inc(FFreeCount);
      Continue;
    end;
    Inc(FLive);
    R^.MapNo := MapNumber(R^.MapName, True);
    if R^.MapNo >= 0 then
    begin
      if R^.MapNo >= Length(MapCounts) then
        SetLength(MapCounts, R^.MapNo * 2 + 16);
      Inc(MapCounts[R^.MapNo]);
    end;
    h := AccSlot(R^.AccountId, True);
    if h >= 0 then
      Inc(AccCounts[h]);
  end;
  if Length(MapCounts) < Length(FMapRecs) then
    SetLength(MapCounts, Length(FMapRecs));
  for m := 0 to High(FMapRecs) do
  begin
    SetLength(FMapRecs[m], MapCounts[m]);
    MapCounts[m] := 0;
  end;
  for h := 0 to High(FAccKeys) do
    if FAccKeys[h] <> 0 then
    begin
      SetLength(FAccRecs[h], AccCounts[h]);
      AccCounts[h] := 0;
    end;
  for i := 0 to FCount - 1 do
  begin
    R := FRecs[i];
    if R = nil then
      Continue;
    if R^.MapNo >= 0 then
    begin
      R^.MapPos := MapCounts[R^.MapNo];
      FMapRecs[R^.MapNo][R^.MapPos] := i;
      Inc(MapCounts[R^.MapNo]);
    end;
    h := AccSlot(R^.AccountId, False);
    if h >= 0 then
    begin
      R^.AccPos := AccCounts[h];
      FAccRecs[h][R^.AccPos] := i;
      Inc(AccCounts[h]);
    end;
  end;
end;

procedure TPlayerMapTable.TakeState(var St: TStoreState);
var
  i: LongInt;
begin
  Clear;
  FRecs := St.PlayerMaps;
  FCount := St.PlayerMapCount;
  if FCount > Length(FRecs) then
    FCount := Length(FRecs);
  St.PlayerMaps := nil;
  St.PlayerMapCount := 0;
  for i := 0 to FCount - 1 do
    if FRecs[i] <> nil then
    begin
      FRecs[i]^.Dirty := False;
      FRecs[i]^.SyncDirty := False;
      FRecs[i]^.MatchKey := 0;
    end;
  { two records of one account and map (map names in another case): the later one is added to the
    first }
  RebuildIndexes;
  for i := 0 to FCount - 1 do
    if (FRecs[i] <> nil) and (FindNo(FRecs[i]^.AccountId, FRecs[i]^.MapNo) <> i) then
    begin
      MergePlayerMapInto(FRecs[FindNo(FRecs[i]^.AccountId, FRecs[i]^.MapNo)]^, FRecs[i]^, 0);
      Unlink(i);
      FreePlayerMap(FRecs[i]);
    end;
  RebuildIndexes;
end;

function TPlayerMapTable.DropOrphans(Exists: TPMLastPlayedFunc): LongInt;
var
  i: LongInt;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
    if (FRecs[i] <> nil) and (Exists(FRecs[i]^.AccountId) <= 0) then
    begin
      Release(i, False);
      Inc(Result);
    end;
  if Result > 0 then
    DropEmptyLinks;
end;

function TPlayerMapTable.MapNumber(const MapName: AnsiString; Add: Boolean): LongInt;
begin
  Result := -1;
  if Trim(MapName) = '' then
    Exit;
  Result := FMapIdx.FindFirst(MapName);
  if (Result >= 0) or not Add then
    Exit;
  Result := Length(FMapNames);
  SetLength(FMapNames, Result + 1);
  SetLength(FMapRecs, Result + 1);
  FMapNames[Result] := MapName;
  FMapRecs[Result] := nil;
  FMapIdx.Add(MapName, Result);
end;

function TPlayerMapTable.FindNo(AccountId, MapNo: LongInt): LongInt;
var
  h, k: LongInt;
  L: TIntArray;
begin
  Result := -1;
  if MapNo < 0 then
    Exit;
  h := AccSlot(AccountId, False);
  if h < 0 then
    Exit;
  L := FAccRecs[h];
  for k := 0 to High(L) do
    if (FRecs[L[k]] <> nil) and (FRecs[L[k]]^.MapNo = MapNo) then
      Exit(L[k]);
end;

function TPlayerMapTable.Find(AccountId: LongInt; const MapName: AnsiString): PPlayerMapStats;
var
  p: LongInt;
begin
  Result := nil;
  p := FindNo(AccountId, MapNumber(MapName, False));
  if p >= 0 then
    Result := FRecs[p];
end;

function TPlayerMapTable.Obtain(AccountId, MapNo: LongInt; NowT: Double): LongInt;
var
  R: PPlayerMapStats;
begin
  Result := FindNo(AccountId, MapNo);
  if (Result >= 0) or (AccountId <= 0) or (MapNo < 0) or (MapNo >= Length(FMapNames)) then
    Exit;
  R := NewPlayerMap;
  R^.AccountId := AccountId;
  R^.MapName := FMapNames[MapNo];
  R^.MapNo := MapNo;
  R^.FirstPlayed := NowT;
  R^.LastPlayed := NowT;
  if FFreeCount > 0 then
  begin
    Dec(FFreeCount);
    Result := FFree[FFreeCount];
  end
  else
  begin
    if FCount >= Length(FRecs) then
      SetLength(FRecs, Length(FRecs) + 1024 + Length(FRecs) div 4);
    Result := FCount;
    Inc(FCount);
  end;
  FRecs[Result] := R;
  Link(Result);
  Inc(FLive);
  Touch(Result);
end;

function TPlayerMapTable.OfAccount(AccountId: LongInt): TPMRefArray;
var
  h, k, n: LongInt;
begin
  Result := nil;
  h := AccSlot(AccountId, False);
  if h < 0 then
    Exit;
  SetLength(Result, Length(FAccRecs[h]));
  n := 0;
  for k := 0 to High(FAccRecs[h]) do
    if FRecs[FAccRecs[h][k]] <> nil then
    begin
      Result[n] := FRecs[FAccRecs[h][k]];
      Inc(n);
    end;
  SetLength(Result, n);
end;

function TPlayerMapTable.OfMap(const MapName: AnsiString): TPMRefArray;
var
  m, k, n: LongInt;
begin
  Result := nil;
  m := MapNumber(MapName, False);
  if m < 0 then
    Exit;
  SetLength(Result, Length(FMapRecs[m]));
  n := 0;
  for k := 0 to High(FMapRecs[m]) do
    if FRecs[FMapRecs[m][k]] <> nil then
    begin
      Result[n] := FRecs[FMapRecs[m][k]];
      Inc(n);
    end;
  SetLength(Result, n);
end;

procedure TPlayerMapTable.SumAccount(AccountId: LongInt; out Sum: TPlayerMapStats);
var
  L: TPMRefArray;
  k: LongInt;
begin
  ClearPlayerMap(Sum);
  Sum.AccountId := AccountId;
  L := OfAccount(AccountId);
  for k := 0 to High(L) do
    MergePlayerMapInto(Sum, L[k]^, 0);
end;

procedure TPlayerMapTable.SumMap(const MapName: AnsiString; out Sum: TPlayerMapStats);
var
  L: TPMRefArray;
  k, m: LongInt;
  R: TPlayerMapStats;
begin
  ClearPlayerMap(Sum);
  m := MapNumber(MapName, False);
  if m >= 0 then
    Sum.MapName := FMapNames[m]
  else
    Sum.MapName := MapName;
  L := OfMap(MapName);
  { the rivals of every account of the map added up would be each pair twice (MapPairs): a copy of
    each record without them is added, so they are not merged only to be thrown away }
  for k := 0 to High(L) do
  begin
    R := L[k]^;
    R.Rivals := nil;
    MergePlayerMapInto(Sum, R, 0);
  end;
end;

function TPlayerMapTable.MapPairs(const MapName: AnsiString): TPMPairArray;
var
  L: TPMRefArray;
  Keys: array of Int64;
  Order: TIntArray;
  Tmp: TPMPairArray;
  { which side an entry of Tmp came from, and which sides a pair of Result has }
  FromA, HasA, HasB: array of Boolean;
  i, j, n: LongInt;
  E: TPMPair;
  R: PPlayerMapStats;
begin
  Result := nil;
  Tmp := nil;
  FromA := nil;
  L := OfMap(MapName);
  n := 0;
  for i := 0 to High(L) do
  begin
    R := L[i];
    for j := 0 to High(R^.Rivals) do
    begin
      if R^.Rivals[j].Id = R^.AccountId then
        Continue;
      FillChar(E, SizeOf(E), 0);
      if n >= Length(Tmp) then
      begin
        SetLength(Tmp, n * 2 + 16);
        SetLength(FromA, Length(Tmp));
      end;
      FromA[n] := R^.AccountId < R^.Rivals[j].Id;
      if FromA[n] then
      begin
        E.A := R^.AccountId;
        E.B := R^.Rivals[j].Id;
        E.AKills := R^.Rivals[j].Kills;
        E.BKills := R^.Rivals[j].Deaths;
        E.ADamage := R^.Rivals[j].DamageDealt;
        E.BDamage := R^.Rivals[j].DamageTaken;
        E.AWon := R^.Rivals[j].PointsWon;
        E.ALost := R^.Rivals[j].PointsLost;
      end
      else
      begin
        E.A := R^.Rivals[j].Id;
        E.B := R^.AccountId;
        E.AKills := R^.Rivals[j].Deaths;
        E.BKills := R^.Rivals[j].Kills;
        E.ADamage := R^.Rivals[j].DamageTaken;
        E.BDamage := R^.Rivals[j].DamageDealt;
        E.BWon := R^.Rivals[j].PointsWon;
        E.BLost := R^.Rivals[j].PointsLost;
      end;
      E.LastFight := R^.Rivals[j].LastFight;
      Tmp[n] := E;
      Inc(n);
    end;
  end;
  if n = 0 then
    Exit;
  { both sides tell a pair: by the pair, the larger of each count (a side may have lost entries to
    MaxRivals, or the other one was pruned); the points each side keeps of its own }
  SetLength(Keys, n);
  SetLength(Order, n);
  for i := 0 to n - 1 do
  begin
    Keys[i] := Int64(Tmp[i].A) shl 32 + Tmp[i].B;
    Order[i] := i;
  end;
  SortByKeys(Keys, Order);
  SetLength(Result, n);
  HasA := nil;
  HasB := nil;
  SetLength(HasA, n);
  SetLength(HasB, n);
  j := 0;
  for i := 0 to n - 1 do
  begin
    E := Tmp[Order[i]];
    if (j > 0) and (Result[j - 1].A = E.A) and (Result[j - 1].B = E.B) then
    begin
      Result[j - 1].AKills := Max(Result[j - 1].AKills, E.AKills);
      Result[j - 1].BKills := Max(Result[j - 1].BKills, E.BKills);
      Result[j - 1].ADamage := Max(Result[j - 1].ADamage, E.ADamage);
      Result[j - 1].BDamage := Max(Result[j - 1].BDamage, E.BDamage);
      Result[j - 1].LastFight := Max(Result[j - 1].LastFight, E.LastFight);
      Result[j - 1].AWon := Max(Result[j - 1].AWon, E.AWon);
      Result[j - 1].ALost := Max(Result[j - 1].ALost, E.ALost);
      Result[j - 1].BWon := Max(Result[j - 1].BWon, E.BWon);
      Result[j - 1].BLost := Max(Result[j - 1].BLost, E.BLost);
    end
    else
    begin
      Result[j] := E;
      HasA[j] := False;
      HasB[j] := False;
      Inc(j);
    end;
    if FromA[Order[i]] then
      HasA[j - 1] := True
    else
      HasB[j - 1] := True;
  end;
  SetLength(Result, j);
  { a side without an entry of the other: what the other side won it lost, and the other way round }
  for i := 0 to j - 1 do
    if not HasA[i] then
    begin
      Result[i].AWon := Result[i].BLost;
      Result[i].ALost := Result[i].BWon;
    end
    else if not HasB[i] then
    begin
      Result[i].BWon := Result[i].ALost;
      Result[i].BLost := Result[i].AWon;
    end;
  { the most fights first, of equal ones the latest fight }
  SetLength(Keys, j);
  SetLength(Order, j);
  for i := 0 to j - 1 do
  begin
    Keys[i] := -((Int64(Result[i].AKills) + Result[i].BKills) shl 32 +
      EnsureRange(Trunc(Result[i].LastFight * 1440), 0, High(LongInt)));
    Order[i] := i;
  end;
  SortByKeys(Keys, Order);
  Tmp := Copy(Result);
  for i := 0 to j - 1 do
    Result[i] := Tmp[Order[i]];
end;

procedure TPlayerMapTable.Touch(Place: LongInt);
var
  R: PPlayerMapStats;
begin
  R := GetItem(Place);
  if R = nil then
    Exit;
  if State = PMS_LOCAL then
    SyncMark(Place);
  if R^.Dirty then
    Exit;
  R^.Dirty := True;
  if FDirtyCount >= Length(FDirty) then
    SetLength(FDirty, FDirtyCount * 2 + 64);
  FDirty[FDirtyCount] := Place;
  Inc(FDirtyCount);
end;

procedure TPlayerMapTable.SyncMark(Place: LongInt);
var
  R: PPlayerMapStats;
begin
  R := GetItem(Place);
  if (R = nil) or R^.SyncDirty or (State = PMS_OFF) then
    Exit;
  ForceSyncMark(Place);
end;

procedure TPlayerMapTable.ForceSyncMark(Place: LongInt);
var
  R: PPlayerMapStats;
begin
  R := GetItem(Place);
  if (R = nil) or R^.SyncDirty then
    Exit;
  R^.SyncDirty := True;
  if FSyncCount >= Length(FSync) then
    SetLength(FSync, FSyncCount * 2 + 64);
  FSync[FSyncCount] := Place;
  Inc(FSyncCount);
end;

procedure TPlayerMapTable.QueueGone(AccountId: LongInt; const MapName, Base: AnsiString);
begin
  if UpdateGone(AccountId, MapName, Base) then
    Exit;
  if FGoneCount >= Length(FGone) then
    SetLength(FGone, FGoneCount * 2 + 16);
  FGone[FGoneCount].AccountId := AccountId;
  FGone[FGoneCount].MapName := MapName;
  FGone[FGoneCount].Base := Base;
  Inc(FGoneCount);
end;

function TPlayerMapTable.UpdateGone(AccountId: LongInt; const MapName, Base: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to FGoneCount - 1 do
    if (FGone[k].AccountId = AccountId) and SameText(FGone[k].MapName, MapName) then
    begin
      FGone[k].Base := Base;
      Exit(True);
    end;
end;

{ the record at Place goes, the lists of its map and account left to the caller; Journal: the
  removal is saved, and goes to the shared database when the record is there }
procedure TPlayerMapTable.Release(Place: LongInt; Journal: Boolean);
var
  R: PPlayerMapStats;
begin
  R := GetItem(Place);
  if R = nil then
    Exit;
  if Journal then
  begin
    if FRemovedCount >= Length(FRemoved) then
      SetLength(FRemoved, FRemovedCount * 2 + 16);
    FRemoved[FRemovedCount].AccountId := R^.AccountId;
    FRemoved[FRemovedCount].MapName := R^.MapName;
    Inc(FRemovedCount);
    { a record the shared database has goes there as well; one it brought the removal of does not }
    if (State = PMS_LOCAL) and (R^.SyncBase <> '') then
      QueueGone(R^.AccountId, R^.MapName, R^.SyncBase);
  end;
  FreePlayerMap(FRecs[Place]);
  if FFreeCount >= Length(FFree) then
    SetLength(FFree, FFreeCount * 2 + 16);
  FFree[FFreeCount] := Place;
  Inc(FFreeCount);
  Dec(FLive);
end;

{ the places of released records out of the lists of the maps and accounts, in one pass }
procedure TPlayerMapTable.DropEmptyLinks;
var
  m, h, j, n: LongInt;
begin
  for m := 0 to High(FMapRecs) do
  begin
    n := 0;
    for j := 0 to High(FMapRecs[m]) do
      if FRecs[FMapRecs[m][j]] <> nil then
      begin
        FMapRecs[m][n] := FMapRecs[m][j];
        FRecs[FMapRecs[m][n]]^.MapPos := n;
        Inc(n);
      end;
    SetLength(FMapRecs[m], n);
  end;
  for h := 0 to High(FAccKeys) do
  begin
    if FAccKeys[h] = 0 then
      Continue;
    n := 0;
    for j := 0 to High(FAccRecs[h]) do
      if FRecs[FAccRecs[h][j]] <> nil then
      begin
        FAccRecs[h][n] := FAccRecs[h][j];
        FRecs[FAccRecs[h][n]]^.AccPos := n;
        Inc(n);
      end;
    SetLength(FAccRecs[h], n);
  end;
end;

{ many records at once (a reset, a prune): released, then the lists filtered once - taking each out
  of a long list of its map one by one would take a time that grows with the square of it }
procedure TPlayerMapTable.RemovePlaces(const L: TIntArray);
var
  k: LongInt;
begin
  if Length(L) < 32 then
  begin
    for k := 0 to High(L) do
      Remove(L[k]);
    Exit;
  end;
  for k := 0 to High(L) do
    Release(L[k], True);
  DropEmptyLinks;
end;

procedure TPlayerMapTable.Remove(Place: LongInt);
begin
  if GetItem(Place) = nil then
    Exit;
  Unlink(Place);
  Release(Place, True);
end;

procedure TPlayerMapTable.RemoveAll;
var
  i, n: LongInt;
  L: TIntArray;
begin
  L := nil;
  SetLength(L, FLive);
  n := 0;
  for i := 0 to FCount - 1 do
    if (FRecs[i] <> nil) and (n < Length(L)) then
    begin
      L[n] := i;
      Inc(n);
    end;
  SetLength(L, n);
  RemovePlaces(L);
end;

procedure TPlayerMapTable.RemoveMap(const MapName: AnsiString);
var
  m: LongInt;
begin
  m := MapNumber(MapName, False);
  if m < 0 then
    Exit;
  RemovePlaces(Copy(FMapRecs[m]));
end;

procedure TPlayerMapTable.RemoveRecordsOf(AccountId: LongInt);
var
  h: LongInt;
begin
  h := AccSlot(AccountId, False);
  if h < 0 then
    Exit;
  RemovePlaces(Copy(FAccRecs[h]));
end;

procedure TPlayerMapTable.RemoveAccount(AccountId: LongInt; Remote, Batch: Boolean);
begin
  if AccountId <= 0 then
    Exit;
  RemoveRecordsOf(AccountId);
  AddInt(FRivalGone, AccountId);
  if not Batch then
    FlushRivalRemovals(Remote);
end;

{ the entries of R naming OldId name NewId (0: they go); an entry naming the record's own account
  (Owner) goes as well - two accounts that became one are no rivals. True when R changed. }
function TPlayerMapTable.RenumberRivalsIn(var R: TPlayerMapStats; OldId, NewId, Owner: LongInt): Boolean;
var
  p, q: LongInt;
  E: TPMRival;
begin
  Result := False;
  if PMRivalPos(R.Rivals, OldId, p) then
  begin
    R.Rivals := Copy(R.Rivals);
    E := R.Rivals[p];
    Delete(R.Rivals, p, 1);
    if (NewId > 0) and (NewId <> Owner) then
    begin
      if PMRivalPos(R.Rivals, NewId, q) then
        SumFields(@R.Rivals[q], @E, PMRivalFields)
      else
      begin
        E.Id := NewId;
        Insert(E, R.Rivals, q);
      end;
    end;
    Result := True;
  end;
  if (Owner > 0) and PMRivalPos(R.Rivals, Owner, p) then
  begin
    R.Rivals := Copy(R.Rivals);
    Delete(R.Rivals, p, 1);
    Result := True;
  end;
end;

{ the same change on the base of a record (the state the shared database had) }
procedure TPlayerMapTable.RenumberBase(Place, OldId, NewId: LongInt);
var
  R: PPlayerMapStats;
  B: TPlayerMapStats;
begin
  R := GetItem(Place);
  if (R = nil) or (R^.SyncBase = '') then
    Exit;
  if DecodePlayerMap(R^.SyncBase, B) and RenumberRivalsIn(B, OldId, NewId, R^.AccountId) then
    R^.SyncBase := EncodePlayerMap(B);
end;

{ Id is one of the sorted A }
function IdIn(const A: TIntArray; Id: LongInt): Boolean;
var
  Lo, Hi, Mid: LongInt;
begin
  Lo := 0;
  Hi := High(A);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    if A[Mid] = Id then
      Exit(True);
    if A[Mid] < Id then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := False;
end;

{ the entries of L naming one of the accounts Gone (sorted) go; True when any did }
function DropRivals(var L: TPMRivalArray; const Gone: TIntArray): Boolean;
var
  j, n: LongInt;
begin
  Result := False;
  for j := 0 to High(L) do
    if IdIn(Gone, L[j].Id) then
    begin
      Result := True;
      Break;
    end;
  if not Result then
    Exit;
  L := Copy(L);
  n := 0;
  for j := 0 to High(L) do
    if not IdIn(Gone, L[j].Id) then
    begin
      L[n] := L[j];
      Inc(n);
    end;
  SetLength(L, n);
end;

procedure TPlayerMapTable.FlushRivalRemovals(Remote: Boolean);
var
  Ids, Order: TIntArray;
  Keys: array of Int64;
  i: LongInt;
  R: PPlayerMapStats;
  B: TPlayerMapStats;
begin
  if (Length(FRivalGone) = 0) or (FRivalHold > 0) then
    Exit;
  { the accounts in order: one look per entry, however many accounts went }
  Keys := nil;
  SetLength(Keys, Length(FRivalGone));
  Order := nil;
  SetLength(Order, Length(FRivalGone));
  for i := 0 to High(FRivalGone) do
  begin
    Keys[i] := FRivalGone[i];
    Order[i] := i;
  end;
  SortByKeys(Keys, Order);
  Ids := nil;
  SetLength(Ids, Length(Order));
  for i := 0 to High(Order) do
    Ids[i] := FRivalGone[Order[i]];
  FRivalGone := nil;
  for i := 0 to FCount - 1 do
  begin
    R := FRecs[i];
    if (R = nil) or (Length(R^.Rivals) = 0) or not DropRivals(R^.Rivals, Ids) then
      Continue;
    { the shared database removed the accounts: the entries are gone from what it had as well }
    if Remote and (R^.SyncBase <> '') and DecodePlayerMap(R^.SyncBase, B) and DropRivals(B.Rivals, Ids) then
      R^.SyncBase := EncodePlayerMap(B);
    Touch(i);
  end;
end;

procedure TPlayerMapTable.HoldRivalRemovals;
begin
  Inc(FRivalHold);
end;

procedure TPlayerMapTable.ReleaseRivalRemovals(Remote: Boolean);
begin
  if FRivalHold > 0 then
    Dec(FRivalHold);
  FlushRivalRemovals(Remote);
end;

procedure TPlayerMapTable.MergeAccount(SrcId, DstId: LongInt; Remote: Boolean);
var
  h, k, At, i: LongInt;
  L: TIntArray;
  SR, DR: PPlayerMapStats;
  BS, BD: TPlayerMapStats;
  WasLocal: Boolean;
begin
  if (SrcId <= 0) or (DstId <= 0) or (SrcId = DstId) then
    Exit;
  { a merge made here goes to a shared database, also while its own changes are applied }
  WasLocal := FForceLocal;
  FForceLocal := not Remote;
  try
    h := AccSlot(SrcId, False);
    if h >= 0 then
    begin
      L := Copy(FAccRecs[h]);
      for k := 0 to High(L) do
      begin
        SR := FRecs[L[k]];
        if SR = nil then
          Continue;
        At := Obtain(DstId, SR^.MapNo, SR^.FirstPlayed);
        if At < 0 then
          Continue;
        DR := FRecs[At];
        { the kills between the two are no rivalry of one player }
        RenumberRivalsIn(SR^, DstId, 0, SrcId);
        MergePlayerMapInto(DR^, SR^, MaxRivals);
        RenumberRivalsIn(DR^, SrcId, 0, DstId);
        if Remote then
        begin
          { the database added the two already: the base is their bases added up }
          if (SR^.SyncBase <> '') and DecodePlayerMap(SR^.SyncBase, BS) then
          begin
            if (DR^.SyncBase = '') or not DecodePlayerMap(DR^.SyncBase, BD) then
            begin
              ClearPlayerMap(BD);
              BD.MapName := DR^.MapName;
            end;
            RenumberRivalsIn(BS, DstId, 0, SrcId);
            MergePlayerMapInto(BD, BS, 0);
            RenumberRivalsIn(BD, SrcId, 0, DstId);
            BD.AccountId := DstId;
            DR^.SyncBase := EncodePlayerMap(BD);
          end;
          { what this server added to either record since the last exchange goes in with it }
          if State <> PMS_OFF then
            ForceSyncMark(At);
        end;
        Touch(At);
        Remove(L[k]);
      end;
    end;
    { every rival entry that names SrcId names DstId }
    for i := 0 to FCount - 1 do
      if (FRecs[i] <> nil) and (PMRivalPos(FRecs[i]^.Rivals, SrcId, k) or
         ((FRecs[i]^.AccountId = DstId) and PMRivalPos(FRecs[i]^.Rivals, DstId, k))) then
      begin
        RenumberRivalsIn(FRecs[i]^, SrcId, DstId, FRecs[i]^.AccountId);
        if Remote then
          RenumberBase(i, SrcId, DstId);
        Touch(i);
      end;
  finally
    FForceLocal := WasLocal;
  end;
end;

procedure TPlayerMapTable.RenumberAccount(OldId, NewId: LongInt);
var
  h, k, d, i: LongInt;
  L: TIntArray;
  R: PPlayerMapStats;
  WasLocal: Boolean;
begin
  if (OldId <= 0) or (NewId <= 0) or (OldId = NewId) then
    Exit;
  { the database has none of it under the new number yet: this server sends it }
  WasLocal := FForceLocal;
  FForceLocal := True;
  try
    h := AccSlot(OldId, False);
    if h >= 0 then
    begin
      L := Copy(FAccRecs[h]);
      for k := 0 to High(L) do
      begin
        R := FRecs[L[k]];
        if R = nil then
          Continue;
        d := FindNo(NewId, R^.MapNo);
        if d >= 0 then
        begin
          RenumberRivalsIn(R^, NewId, 0, OldId);
          MergePlayerMapInto(FRecs[d]^, R^, MaxRivals);
          Touch(d);
          Remove(L[k]);
          Continue;
        end;
        { the database never had it under the old number, or it goes there as a removal: under the
          new number it is a new record }
        if (State <> PMS_OFF) and (R^.SyncBase <> '') then
          QueueGone(OldId, R^.MapName, R^.SyncBase);
        R^.SyncBase := '';
        R^.SyncVersion := 0;
        Unlink(L[k]);
        R^.AccountId := NewId;
        Link(L[k]);
        if FRemovedCount >= Length(FRemoved) then
          SetLength(FRemoved, FRemovedCount * 2 + 16);
        FRemoved[FRemovedCount].AccountId := OldId;
        FRemoved[FRemovedCount].MapName := R^.MapName;
        Inc(FRemovedCount);
        Touch(L[k]);
      end;
    end;
    for i := 0 to FCount - 1 do
      if (FRecs[i] <> nil) and PMRivalPos(FRecs[i]^.Rivals, OldId, k) then
      begin
        RenumberRivalsIn(FRecs[i]^, OldId, NewId, FRecs[i]^.AccountId);
        Touch(i);
      end;
  finally
    FForceLocal := WasLocal;
  end;
end;

function TPlayerMapTable.Prune(Days, MapDays: LongInt; NowT: Double; LastPlayed: TPMLastPlayedFunc): LongInt;
var
  i, k, n: LongInt;
  T: Double;
  L: TIntArray;
  R: PPlayerMapStats;
begin
  Result := 0;
  if ((Days <= 0) and (MapDays <= 0)) or not Assigned(LastPlayed) then
    Exit;
  L := nil;
  for i := 0 to FCount - 1 do
    if FRecs[i] <> nil then
    begin
      R := FRecs[i];
      T := LastPlayed(R^.AccountId);
      { a player who stays keeps a record per map he ever played on, and every rival he ever met,
        unless MapDays > 0: then the maps he left and the rivals he no longer meets go as well }
      if ((Days > 0) and ((T <= 0) or (NowT - T > Days))) or
        ((MapDays > 0) and (R^.LastPlayed > 0) and (NowT - R^.LastPlayed > MapDays)) then
      begin
        if Result >= Length(L) then
          SetLength(L, Result * 2 + 64);
        L[Result] := i;
        Inc(Result);
      end
      else if MapDays > 0 then
      begin
        n := 0;
        for k := 0 to High(R^.Rivals) do
          if (R^.Rivals[k].LastFight <= 0) or (NowT - R^.Rivals[k].LastFight <= MapDays) then
          begin
            if n <> k then
              R^.Rivals[n] := R^.Rivals[k];
            Inc(n);
          end;
        if n < Length(R^.Rivals) then
        begin
          SetLength(R^.Rivals, n);
          Touch(i);
        end;
      end;
    end;
  SetLength(L, Result);
  RemovePlaces(L);
end;

function TPlayerMapTable.ApproxBytes: Int64;
var
  i: LongInt;
  R: PPlayerMapStats;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
  begin
    R := FRecs[i];
    if R = nil then
      Continue;
    Result := Result + SizeOf(TPlayerMapStats) + Length(R^.MapName) + Length(R^.SyncBase) +
      Int64(Length(R^.Weapons)) * SizeOf(TPMWeapon) + Int64(Length(R^.Rivals)) * SizeOf(TPMRival) +
      Int64(Length(R^.Matchups)) * SizeOf(TPMMatchup) + Int64(Length(R^.Heat)) * SizeOf(THeatCell);
  end;
end;

procedure TPlayerMapTable.FlushJournal(W: TStoreWriter);
var
  k, p: LongInt;
begin
  { removals first: a record removed and made again in the same interval ends as the new one }
  for k := 0 to FRemovedCount - 1 do
    W.JournalDeletePlayerMap(FRemoved[k].AccountId, FRemoved[k].MapName);
  FRemovedCount := 0;
  if Length(FRemoved) > 1024 then
    FRemoved := nil;
  for k := 0 to FDirtyCount - 1 do
  begin
    p := FDirty[k];
    if (p < FCount) and (FRecs[p] <> nil) and FRecs[p]^.Dirty then
    begin
      W.JournalPlayerMap(FRecs[p]^);
      FRecs[p]^.Dirty := False;
    end;
  end;
  FDirtyCount := 0;
end;

function TPlayerMapTable.PendingRemovals: Boolean;
begin
  Result := FRemovedCount > 0;
end;

procedure TPlayerMapTable.SnapshotBegin;
begin
  FSnapPos := 0;
end;

function TPlayerMapTable.SnapshotStep(W: TStoreWriter; var Budget: LongInt): Boolean;
begin
  while (FSnapPos < FCount) and (Budget > 0) do
  begin
    if FRecs[FSnapPos] <> nil then
    begin
      W.SnapshotPlayerMap(FRecs[FSnapPos]^);
      Dec(Budget);
    end;
    Inc(FSnapPos);
  end;
  Result := FSnapPos >= FCount;
end;

procedure TPlayerMapTable.TakeSyncWork(out Marked: TIntArray; out Gone: TPMGoneArray);
begin
  Marked := Copy(FSync, 0, FSyncCount);
  FSyncCount := 0;
  Gone := Copy(FGone, 0, FGoneCount);
  FGoneCount := 0;
end;

procedure TPlayerMapTable.RequeueGone(const Gone: TPMGoneArray);
var
  k: LongInt;
begin
  for k := 0 to High(Gone) do
    QueueGone(Gone[k].AccountId, Gone[k].MapName, Gone[k].Base);
end;

function TPlayerMapTable.SyncPending: TIntArray;
begin
  Result := Copy(FSync, 0, FSyncCount);
end;

function TPlayerMapTable.GonePending: TPMGoneArray;
begin
  Result := Copy(FGone, 0, FGoneCount);
end;

procedure TPlayerMapTable.SetBasesFromRecords;
var
  i: LongInt;
begin
  for i := 0 to FCount - 1 do
    if FRecs[i] <> nil then
      FRecs[i]^.SyncBase := EncodePlayerMap(FRecs[i]^);
end;

end.
