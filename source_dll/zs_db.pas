unit zs_db;

{ In-memory statistics database, owned by the engine thread.

  Profiles are heap records reached through a pointer array: growing the array never copies
  profile data, and a deleted profile leaves a nil hole that is compacted later, outside a
  running snapshot. Code that keeps a profile across calls stores its ID and resolves the
  index again whenever IndexGen changes. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, zs_types, zs_util, zs_fields, zs_store, zs_rank, zs_rating, zs_legacy, zs_matrix;

const
  RANK_POINTS = 0;
  RANK_SEASON = 1;
  RANK_RATING_FFA = 2;
  RANK_RATING_TEAM = 3;
  RANK_RATING_CTF = 4;
  RANK_COUNT = 5;

  RS_ELO = 0;
  RS_GLICKO2 = 1;
  RS_OPENSKILL = 2;
  RS_MMR = 3;

type
  { an account that is gone, for the other servers of a shared database }
  TSyncDeleted = record
    Id, MergedInto: LongInt;
  end;
  TSyncDeletedArray = array of TSyncDeleted;
  TIdHook = function: LongInt of object;

  TStatsDB = class
  private
    FSyncProfiles: TIntArray;
    FSyncProfileCount: LongInt;
    FSyncMaps: TIntArray;
    FSyncMapCount: LongInt;
    FSyncServer: Boolean;
    FSyncSeasons: TIntArray;
    FSyncDeleted: TSyncDeletedArray;
    FSyncDeletedCount: LongInt;
    FSyncQuiet: LongInt;
    FIdIndex: array of LongInt;
    FSteam, FHwid, FName, FMapName: TStrIndex;
    FDirty: array of LongInt;
    FDirtyCount: LongInt;
    FDirtyMaps: array of LongInt;
    FDirtyMapCount: LongInt;
    FDirtySeasons: array of LongInt;
    FDeleted: array of LongInt;
    FDeletedCount: LongInt;
    FServerDirty: Boolean;
    FHoles: LongInt;
    FIndexGen: LongWord;
    FSnapActive: Boolean;
    FBulkDelete: Boolean;
    FSnapPhase, FSnapPos: LongInt;
    FNow: Double;
    procedure SetIdIndex(Id, Index: LongInt);
    procedure IndexProfile(Index: LongInt);
    procedure UnindexProfile(Index: LongInt);
    function RankKey(List: LongInt; const P: TPlayerProfile; out Include: Boolean): Int64;
    function PMSyncState: LongInt;
    function AccountLastPlayed(AccountId: LongInt): Double;
    function AccountExists(AccountId: LongInt): Double;
  public
    Server: TServerRecords;
    Profiles: TProfilePtrArray;
    ProfileCount: LongInt;
    Maps: TMapProfileArray;
    MapCount: LongInt;
    Seasons: TSeasonArchiveArray;
    Ranks: array[0..RANK_COUNT - 1] of TRankList;
    { the player-on-map records ([Matrix], zs_matrix): the API of the views is described there }
    PM: TPlayerMapTable;

    { Engine = mysql: every change is also remembered for the exchange with the shared database
      (zs_sqldb), and the numbers of new accounts come from it }
    SyncOn: Boolean;
    NextProfileIdHook: TIdHook;

    RatingSystem: LongInt;
    GlickoK: Double;
    HideAfterDays: LongInt;
    GlickoR, GlickoRD, GlickoVol: Double;
    SkillMu, SkillSigma: Double;
    MmrStart, MmrK: Double;
    MmrPlacement: LongInt;

    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure TakeState(var St: TStoreState);
    procedure SetNow(ANow: Double);
    property NowValue: Double read FNow;

    function Valid(Index: LongInt): Boolean; inline;
    function IndexOfId(Id: LongInt): LongInt;
    function IndexOfSteam(const Steam: AnsiString): LongInt;
    function IndexesOfHwid(const Hwid: AnsiString): TIntArray;
    function IndexesOfName(const Name: AnsiString): TIntArray;
    function FindMap(const Name: AnsiString; CreateIfMissing: Boolean): LongInt;
    function LiveProfiles: LongInt;
    property IndexGen: LongWord read FIndexGen;

    function CreateProfile(const Name, Steam, Hwid, IP: AnsiString; StartingPoints: LongInt): LongInt;
    procedure InitRatings(var P: TPlayerProfile);
    procedure EnsureRatingDefaults(var P: TPlayerProfile);
    procedure Touch(Index: LongInt);
    procedure TouchMap(Index: LongInt);
    procedure TouchServer;
    procedure TouchSeason(Index: LongInt);
    function NoteName(Index: LongInt; const Name: AnsiString; NewVisit: Boolean; TimePlayed, TimeSpec: Int64;
      Limit: LongInt): Boolean;
    procedure SetActiveIdentity(Index: LongInt; const Name, Hwid, IP: AnsiString);
    { bracket every change of the name, HWID, password or trusted computers of an account }
    procedure BeginIdentityChange(Index: LongInt);
    procedure EndIdentityChange(Index: LongInt);
    procedure DeleteProfile(Index: LongInt);
    { removal of many accounts at once: the ranking is rebuilt once at the end instead of
      shifting every list per account }
    procedure BeginBulkDelete;
    procedure EndBulkDelete;
    procedure MergeProfile(DstIndex, SrcIndex, StartingPoints: LongInt);
    procedure RefreshRanks(Index: LongInt);
    procedure RebuildRanks;
    procedure RebuildIndexes;
    { [Matrix] MatrixPruneDays: the player-on-map records of accounts that have not played for Days
      days go (0 = none); returns how many }
    function PrunePlayerMaps(Days: LongInt): LongInt;

    { the exchange with the shared database: what changed since the last one (the lists are
      emptied), changes of the database that must not be sent back, accounts and maps it brought }
    procedure SyncMark(Index: LongInt);
    procedure SyncMarkMap(Index: LongInt);
    procedure SyncMarkServer;
    procedure TakeSyncWork(out ProfileIdx, MapIdx: TIntArray; out ServerChanged: Boolean; out SeasonIdx: TIntArray;
      out Deleted: TSyncDeletedArray);
    procedure BeginRemote;
    procedure EndRemote;
    function AdoptProfile(P: PPlayerProfile): LongInt;
    function AdoptMap(const M: TMapProfile): LongInt;
    procedure ChangeProfileId(Index, NewId: LongInt);
    procedure RequeueDeleted(const D: TSyncDeletedArray);
    { what is marked for the next exchange, without taking it }
    function SyncServerPending: Boolean;
    function SyncSeasonsPending: TIntArray;
    function SyncDeletedPending: TSyncDeletedArray;

    procedure FlushJournal(W: TStoreWriter; IncludeShared: Boolean);
    procedure BeginSnapshot(W: TStoreWriter);
    function ContinueSnapshot(W: TStoreWriter; Budget: LongInt): Boolean;
    procedure AbortSnapshot(W: TStoreWriter);
    function CompactIfNeeded(Force: Boolean): Boolean;
    property SnapshotActive: Boolean read FSnapActive;
    property Holes: LongInt read FHoles;
  end;

function IsRealSteam(const S: AnsiString): Boolean;

implementation

function IsRealSteam(const S: AnsiString): Boolean;
begin
  Result := (S <> '') and (S <> '0') and (S <> 'S0');
end;

procedure AddUnique(Idx: TStrIndex; const Key: AnsiString; Value: LongInt);
var
  Found: TIntArray;
  k: LongInt;
begin
  if Key = '' then
    Exit;
  Found := Idx.Find(Key);
  for k := 0 to High(Found) do
    if Found[k] = Value then
      Exit;
  Idx.Add(Key, Value);
end;

{ ---------------- lifetime ---------------- }

constructor TStatsDB.Create;
var
  k: LongInt;
begin
  inherited Create;
  FSteam := TStrIndex.Create(4096);
  FHwid := TStrIndex.Create(8192);
  FName := TStrIndex.Create(8192);
  FMapName := TStrIndex.Create(256);
  for k := 0 to RANK_COUNT - 1 do
    Ranks[k] := TRankList.Create;
  PM := TPlayerMapTable.Create;
  PM.SyncState := @PMSyncState;
  GlickoK := 2;
  MmrStart := 1500;
  MmrK := 24;
  MmrPlacement := 10;
  GlickoR := 1500;
  GlickoRD := 350;
  GlickoVol := 0.06;
  SkillMu := 25;
  SkillSigma := 25 / 3;
  FNow := Now;
end;

destructor TStatsDB.Destroy;
var
  k: LongInt;
begin
  Clear;
  FSteam.Free;
  FHwid.Free;
  FName.Free;
  FMapName.Free;
  for k := 0 to RANK_COUNT - 1 do
    Ranks[k].Free;
  PM.Free;
  inherited Destroy;
end;

procedure TStatsDB.Clear;
var
  k: LongInt;
begin
  FreeProfiles(Profiles);
  ProfileCount := 0;
  Maps := nil;
  MapCount := 0;
  Seasons := nil;
  ClearServer(Server);
  FIdIndex := nil;
  FSteam.Clear;
  FHwid.Clear;
  FName.Clear;
  FMapName.Clear;
  for k := 0 to RANK_COUNT - 1 do
    Ranks[k].Clear;
  FDirtyCount := 0;
  FDirtyMapCount := 0;
  FDirtySeasons := nil;
  FDeletedCount := 0;
  FServerDirty := False;
  FHoles := 0;
  FSnapActive := False;
  FBulkDelete := False;
  FSyncProfileCount := 0;
  FSyncMapCount := 0;
  FSyncServer := False;
  FSyncSeasons := nil;
  FSyncDeletedCount := 0;
  PM.Clear;
  Inc(FIndexGen);
end;

procedure TStatsDB.TakeState(var St: TStoreState);
var
  i, MaxId: LongInt;
begin
  Clear;
  Profiles := St.Profiles;
  ProfileCount := St.ProfileCount;
  St.Profiles := nil;
  St.ProfileCount := 0;
  Maps := St.Maps;
  MapCount := St.MapCount;
  St.Maps := nil;
  St.MapCount := 0;
  Seasons := St.Seasons;
  St.Seasons := nil;
  Server := St.Server;
  ClearServer(St.Server);

  MaxId := 0;
  for i := 0 to ProfileCount - 1 do
    if Profiles[i] <> nil then
    begin
      if Profiles[i]^.ID > MaxId then
        MaxId := Profiles[i]^.ID;
      Profiles[i]^.Dirty := False;
      EnsureRatingDefaults(Profiles[i]^);
      { accounts imported from 4.x before the importer derived the damage totals from the
        weapons (!server showed less damage than a single weapon): repaired once, then saved }
      if LegacyDeriveTotals(Profiles[i]^) then
        Touch(i);
    end
    else
      Inc(FHoles);
  if Server.NextProfileID <= MaxId then
    Server.NextProfileID := MaxId + 1;
  MaxId := 0;
  for i := 0 to MapCount - 1 do
  begin
    Maps[i].Dirty := False;
    if Maps[i].ID > MaxId then
      MaxId := Maps[i].ID;
  end;
  if Server.NextMapID <= MaxId then
    Server.NextMapID := MaxId + 1;
  RebuildIndexes;
  RebuildRanks;
  { the player-on-map records; those of accounts that are not there any more go }
  PM.TakeState(St);
  PM.DropOrphans(@AccountExists);
  { 5.0 summed the match lengths without counting the matches, and a map imported from 4.x counts
    old matches that have no length at all. That old sum is set aside once, so the average match
    length starts with the first match played by 5.1. }
  if not Server.MatchLengthsSplit then
  begin
    for i := 0 to MapCount - 1 do
    begin
      Maps[i].MatchDurationBase := Maps[i].MatchDurationSum;
      Maps[i].MatchDurationCount := 0;
      TouchMap(i);
    end;
    Server.MatchLengthsSplit := True;
    TouchServer;
  end;
  { The winning scores were summed without counting their matches, and a map imported from 4.x
    counts matches that have no score at all. That sum is set aside once, so the average winning
    score starts with the first match that is counted. }
  if not Server.ScoresSplit then
  begin
    for i := 0 to MapCount - 1 do
    begin
      Maps[i].ScoreBase := Maps[i].ScoreSum;
      Maps[i].ScoreCount := 0;
      TouchMap(i);
    end;
    Server.ScoresSplit := True;
    TouchServer;
  end;
end;

procedure TStatsDB.SetNow(ANow: Double);
begin
  FNow := ANow;
end;

{ ---------------- lookup ---------------- }

function TStatsDB.Valid(Index: LongInt): Boolean;
begin
  Result := (Index >= 0) and (Index < ProfileCount) and (Profiles[Index] <> nil);
end;

procedure TStatsDB.SetIdIndex(Id, Index: LongInt);
var
  NewLen: LongInt;
begin
  if Id <= 0 then
    Exit;
  if Id >= Length(FIdIndex) then
  begin
    if Index < 0 then
      Exit;
    NewLen := Length(FIdIndex) * 2;
    if NewLen <= Id then
      NewLen := Id + 4096;
    SetLength(FIdIndex, NewLen);
  end;
  FIdIndex[Id] := Index + 1;
end;

function TStatsDB.IndexOfId(Id: LongInt): LongInt;
begin
  if (Id > 0) and (Id < Length(FIdIndex)) then
    Result := FIdIndex[Id] - 1
  else
    Result := -1;
end;

{ A Steam account is found only by its SteamID. An account without Steam is found by the HWID of
  its computer and, when registered, also by the computers trusted after a login. }
procedure TStatsDB.IndexProfile(Index: LongInt);
var
  P: PPlayerProfile;
  j: LongInt;
begin
  P := Profiles[Index];
  if P = nil then
    Exit;
  AddUnique(FName, P^.ActiveName, Index);
  if IsRealSteam(P^.ActiveSteam) then
  begin
    AddUnique(FSteam, P^.ActiveSteam, Index);
    Exit;
  end;
  AddUnique(FHwid, P^.ActiveHWID, Index);
  if P^.PassHash <> '' then
    for j := 0 to High(P^.TrustedDevices) do
      AddUnique(FHwid, P^.TrustedDevices[j].HWID, Index);
end;

{ removes every key IndexProfile can have added; missing keys are ignored }
procedure TStatsDB.UnindexProfile(Index: LongInt);
var
  P: PPlayerProfile;
  j: LongInt;
begin
  P := Profiles[Index];
  if P = nil then
    Exit;
  FName.Remove(P^.ActiveName, Index);
  FSteam.Remove(P^.ActiveSteam, Index);
  FHwid.Remove(P^.ActiveHWID, Index);
  for j := 0 to High(P^.TrustedDevices) do
    FHwid.Remove(P^.TrustedDevices[j].HWID, Index);
end;
procedure TStatsDB.RebuildIndexes;
var
  i: LongInt;
begin
  FIdIndex := nil;
  FSteam.Clear;
  FHwid.Clear;
  FName.Clear;
  FMapName.Clear;
  for i := 0 to ProfileCount - 1 do
    if Profiles[i] <> nil then
    begin
      SetIdIndex(Profiles[i]^.ID, i);
      IndexProfile(i);
    end;
  for i := 0 to MapCount - 1 do
    FMapName.Add(Maps[i].MapName, i);
  Inc(FIndexGen);
end;

function TStatsDB.IndexOfSteam(const Steam: AnsiString): LongInt;
var
  Found: TIntArray;
  k: LongInt;
begin
  Result := -1;
  if not IsRealSteam(Steam) then
    Exit;
  Found := FSteam.Find(Steam);
  { 4.x could leave one SteamID on two profiles: the older profile wins, as it did there }
  for k := 0 to High(Found) do
    if Valid(Found[k]) and ((Result < 0) or (Found[k] < Result)) then
      Result := Found[k];
end;

function TStatsDB.IndexesOfHwid(const Hwid: AnsiString): TIntArray;
begin
  if Hwid = '' then
    Result := nil
  else
    Result := FHwid.Find(Hwid);
end;

function TStatsDB.IndexesOfName(const Name: AnsiString): TIntArray;
begin
  if Name = '' then
    Result := nil
  else
    Result := FName.Find(Name);
end;

function TStatsDB.FindMap(const Name: AnsiString; CreateIfMissing: Boolean): LongInt;
begin
  Result := -1;
  if Trim(Name) = '' then
    Exit;
  Result := FMapName.FindFirst(Name);
  if (Result >= 0) or not CreateIfMissing then
    Exit;
  if MapCount >= Length(Maps) then
    SetLength(Maps, Length(Maps) + 64);
  Result := MapCount;
  Inc(MapCount);
  ClearMap(Maps[Result]);
  Maps[Result].ID := Server.NextMapID;
  if Maps[Result].ID <= 0 then
    Maps[Result].ID := 1;
  Server.NextMapID := Maps[Result].ID + 1;
  Maps[Result].MapName := Name;
  Maps[Result].FirstPlayedTime := FNow;
  FMapName.Add(Name, Result);
  TouchMap(Result);
  TouchServer;
end;

function TStatsDB.LiveProfiles: LongInt;
begin
  Result := ProfileCount - FHoles;
end;

{ a change of the player-on-map records goes to the shared database (Engine = mysql) when made
  here; one it brought changes the base as well }
function TStatsDB.PMSyncState: LongInt;
begin
  if not SyncOn then
    Result := PMS_OFF
  else if FSyncQuiet > 0 then
    Result := PMS_REMOTE
  else
    Result := PMS_LOCAL;
end;

function TStatsDB.AccountLastPlayed(AccountId: LongInt): Double;
var
  i: LongInt;
begin
  i := IndexOfId(AccountId);
  if Valid(i) then
    Result := Profiles[i]^.LastPlayedTime
  else
    Result := 0;
end;

function TStatsDB.AccountExists(AccountId: LongInt): Double;
begin
  if Valid(IndexOfId(AccountId)) then
    Result := 1
  else
    Result := 0;
end;

function TStatsDB.PrunePlayerMaps(Days: LongInt): LongInt;
begin
  Result := PM.Prune(Days, FNow, @AccountLastPlayed);
end;

{ ---------------- changes ---------------- }

procedure TStatsDB.InitRatings(var P: TPlayerProfile);
var
  f: LongInt;
begin
  for f := 0 to RF_COUNT - 1 do
  begin
    GlickoInit(P.Glicko[f], GlickoR, GlickoRD, GlickoVol);
    OpenSkillInit(P.OpenSkill[f], SkillMu, SkillSigma);
    MmrInit(P.Mmr[f], MmrStart);
  end;
end;

procedure TStatsDB.EnsureRatingDefaults(var P: TPlayerProfile);
var
  f: LongInt;
begin
  for f := 0 to RF_COUNT - 1 do
  begin
    if P.Glicko[f].RD <= 0 then
      GlickoInit(P.Glicko[f], GlickoR, GlickoRD, GlickoVol);
    if P.OpenSkill[f].Sigma <= 0 then
      OpenSkillInit(P.OpenSkill[f], SkillMu, SkillSigma);
    if P.Mmr[f].R <= 0 then
      MmrInit(P.Mmr[f], MmrStart);
  end;
end;

function TStatsDB.CreateProfile(const Name, Steam, Hwid, IP: AnsiString; StartingPoints: LongInt): LongInt;
var
  P: PPlayerProfile;
begin
  P := NewProfile;
  if Assigned(NextProfileIdHook) then
    P^.ID := NextProfileIdHook()
  else
  begin
    P^.ID := Server.NextProfileID;
    if P^.ID <= 0 then
      P^.ID := 1;
    Server.NextProfileID := P^.ID + 1;
    TouchServer;
  end;
  P^.ActiveName := Name;
  if IsRealSteam(Steam) then
    P^.ActiveSteam := Steam;
  P^.ActiveHWID := Hwid;
  P^.ActiveIP := IP;
  P^.Points := StartingPoints;
  P^.RegisterTime := FNow;
  P^.LastPlayedTime := FNow;
  InitRatings(P^);
  if ProfileCount >= Length(Profiles) then
    SetLength(Profiles, Length(Profiles) + 1024 + Length(Profiles) div 8);
  Result := ProfileCount;
  Profiles[Result] := P;
  Inc(ProfileCount);
  SetIdIndex(P^.ID, Result);
  IndexProfile(Result);
  NoteName(Result, Name, True, 0, 0, 0);
  Touch(Result);
  RefreshRanks(Result);
end;

procedure TStatsDB.SyncMark(Index: LongInt);
begin
  if not SyncOn or (FSyncQuiet > 0) or not Valid(Index) or Profiles[Index]^.SyncDirty then
    Exit;
  Profiles[Index]^.SyncDirty := True;
  if FSyncProfileCount >= Length(FSyncProfiles) then
    SetLength(FSyncProfiles, Length(FSyncProfiles) * 2 + 64);
  FSyncProfiles[FSyncProfileCount] := Index;
  Inc(FSyncProfileCount);
end;

procedure TStatsDB.SyncMarkMap(Index: LongInt);
begin
  if not SyncOn or (FSyncQuiet > 0) or (Index < 0) or (Index >= MapCount) or Maps[Index].SyncDirty then
    Exit;
  Maps[Index].SyncDirty := True;
  if FSyncMapCount >= Length(FSyncMaps) then
    SetLength(FSyncMaps, Length(FSyncMaps) * 2 + 16);
  FSyncMaps[FSyncMapCount] := Index;
  Inc(FSyncMapCount);
end;

procedure TStatsDB.SyncMarkServer;
begin
  if SyncOn and (FSyncQuiet = 0) then
    FSyncServer := True;
end;

procedure TStatsDB.TakeSyncWork(out ProfileIdx, MapIdx: TIntArray; out ServerChanged: Boolean; out SeasonIdx: TIntArray;
  out Deleted: TSyncDeletedArray);
begin
  ProfileIdx := Copy(FSyncProfiles, 0, FSyncProfileCount);
  FSyncProfileCount := 0;
  MapIdx := Copy(FSyncMaps, 0, FSyncMapCount);
  FSyncMapCount := 0;
  ServerChanged := FSyncServer;
  FSyncServer := False;
  SeasonIdx := FSyncSeasons;
  FSyncSeasons := nil;
  Deleted := Copy(FSyncDeleted, 0, FSyncDeletedCount);
  FSyncDeletedCount := 0;
end;

procedure TStatsDB.BeginRemote;
begin
  Inc(FSyncQuiet);
end;

procedure TStatsDB.EndRemote;
begin
  if FSyncQuiet > 0 then
    Dec(FSyncQuiet);
end;

{ an account the shared database brought: it keeps its number there }
function TStatsDB.AdoptProfile(P: PPlayerProfile): LongInt;
begin
  EnsureRatingDefaults(P^);
  LegacyDeriveTotals(P^);
  if ProfileCount >= Length(Profiles) then
    SetLength(Profiles, Length(Profiles) + 1024 + Length(Profiles) div 8);
  Result := ProfileCount;
  Profiles[Result] := P;
  Inc(ProfileCount);
  SetIdIndex(P^.ID, Result);
  IndexProfile(Result);
  Touch(Result);
  RefreshRanks(Result);
end;

function TStatsDB.AdoptMap(const M: TMapProfile): LongInt;
begin
  if MapCount >= Length(Maps) then
    SetLength(Maps, Length(Maps) + 64);
  Result := MapCount;
  Inc(MapCount);
  Maps[Result] := M;
  FMapName.Add(M.MapName, Result);
  TouchMap(Result);
end;

{ the shared database gave an account another number (a new account, or one that two servers
  made at the same time): the files forget the old number }
procedure TStatsDB.ChangeProfileId(Index, NewId: LongInt);
begin
  if not Valid(Index) or (Profiles[Index]^.ID = NewId) then
    Exit;
  if Profiles[Index]^.ID > 0 then
  begin
    SetIdIndex(Profiles[Index]^.ID, -1);
    if FDeletedCount >= Length(FDeleted) then
      SetLength(FDeleted, Length(FDeleted) * 2 + 16);
    FDeleted[FDeletedCount] := Profiles[Index]^.ID;
    Inc(FDeletedCount);
    { its records on the maps, and the rival entries that name it, follow it }
    PM.RenumberAccount(Profiles[Index]^.ID, NewId);
  end;
  Profiles[Index]^.ID := NewId;
  SetIdIndex(NewId, Index);
  Touch(Index);
  { the number decides between equal points: the ranking keys hold it }
  RefreshRanks(Index);
end;

procedure TStatsDB.RequeueDeleted(const D: TSyncDeletedArray);
var
  k: LongInt;
begin
  for k := 0 to High(D) do
  begin
    if FSyncDeletedCount >= Length(FSyncDeleted) then
      SetLength(FSyncDeleted, Length(FSyncDeleted) * 2 + 16);
    FSyncDeleted[FSyncDeletedCount] := D[k];
    Inc(FSyncDeletedCount);
  end;
end;

function TStatsDB.SyncServerPending: Boolean;
begin
  Result := FSyncServer;
end;

function TStatsDB.SyncSeasonsPending: TIntArray;
begin
  Result := Copy(FSyncSeasons, 0, Length(FSyncSeasons));
end;

function TStatsDB.SyncDeletedPending: TSyncDeletedArray;
begin
  Result := Copy(FSyncDeleted, 0, FSyncDeletedCount);
end;

procedure TStatsDB.Touch(Index: LongInt);
begin
  SyncMark(Index);
  if not Valid(Index) or Profiles[Index]^.Dirty then
    Exit;
  Profiles[Index]^.Dirty := True;
  if FDirtyCount >= Length(FDirty) then
    SetLength(FDirty, Length(FDirty) * 2 + 64);
  FDirty[FDirtyCount] := Index;
  Inc(FDirtyCount);
end;

procedure TStatsDB.TouchMap(Index: LongInt);
begin
  SyncMarkMap(Index);
  if (Index < 0) or (Index >= MapCount) or Maps[Index].Dirty then
    Exit;
  Maps[Index].Dirty := True;
  if FDirtyMapCount >= Length(FDirtyMaps) then
    SetLength(FDirtyMaps, Length(FDirtyMaps) * 2 + 16);
  FDirtyMaps[FDirtyMapCount] := Index;
  Inc(FDirtyMapCount);
end;

procedure TStatsDB.TouchServer;
begin
  FServerDirty := True;
  SyncMarkServer;
end;

procedure TStatsDB.TouchSeason(Index: LongInt);
var
  k: LongInt;
begin
  if SyncOn and (FSyncQuiet = 0) then
  begin
    k := 0;
    while (k < Length(FSyncSeasons)) and (FSyncSeasons[k] <> Index) do
      Inc(k);
    if k = Length(FSyncSeasons) then
    begin
      SetLength(FSyncSeasons, k + 1);
      FSyncSeasons[k] := Index;
    end;
  end;
  for k := 0 to High(FDirtySeasons) do
    if FDirtySeasons[k] = Index then
      Exit;
  k := Length(FDirtySeasons);
  SetLength(FDirtySeasons, k + 1);
  FDirtySeasons[k] := Index;
end;

function TStatsDB.NoteName(Index: LongInt; const Name: AnsiString; NewVisit: Boolean; TimePlayed, TimeSpec: Int64;
  Limit: LongInt): Boolean;
var
  A: ^TOtherDataArray;
  i, Found, Oldest: LongInt;
  V: AnsiString;
begin
  Result := False;
  V := Trim(Name);
  if (V = '') or not Valid(Index) then
    Exit;
  A := @Profiles[Index]^.OtherNames;
  Found := -1;
  for i := 0 to High(A^) do
  begin
    A^[i].LastUsed := False;
    if (Found < 0) and SameText(OtherDataToString(A^[i]), V) then
      Found := i;
  end;
  if Found >= 0 then
  begin
    A^[Found].IsActive := True;
    A^[Found].LastUsed := True;
    A^[Found].LastUsedDate := FNow;
    if NewVisit then
      Inc(A^[Found].LoginCount);
    Inc(A^[Found].TimePlayed, TimePlayed);
    Inc(A^[Found].TimeOnSpectator, TimeSpec);
  end
  else
  begin
    { a smaller limit shortens the list until it fits }
    while (Limit > 0) and (Length(A^) >= Limit) do
    begin
      { make room by forgetting the name used least recently }
      Oldest := 0;
      for i := 1 to High(A^) do
        if A^[i].LastUsedDate < A^[Oldest].LastUsedDate then
          Oldest := i;
      for i := Oldest to High(A^) - 1 do
        A^[i] := A^[i + 1];
      SetLength(A^, Length(A^) - 1);
    end;
    i := Length(A^);
    SetLength(A^, i + 1);
    FillChar(A^[i], SizeOf(TOtherData), 0);
    SetOtherDataString(A^[i], V);
    A^[i].IsActive := True;
    A^[i].FirstUsed := i = 0;
    A^[i].LastUsed := True;
    if NewVisit then
      A^[i].LoginCount := 1;
    A^[i].TimePlayed := TimePlayed;
    A^[i].TimeOnSpectator := TimeSpec;
    A^[i].FirstUsedDate := FNow;
    A^[i].LastUsedDate := FNow;
    Result := True;
  end;
  Touch(Index);
end;

{ the SteamID of an account never changes: a Steam player always keeps the Steam account }
procedure TStatsDB.SetActiveIdentity(Index: LongInt; const Name, Hwid, IP: AnsiString);
var
  P: PPlayerProfile;
begin
  if not Valid(Index) then
    Exit;
  P := Profiles[Index];
  BeginIdentityChange(Index);
  if Name <> '' then
    P^.ActiveName := Name;
  if Hwid <> '' then
    P^.ActiveHWID := Hwid;
  if IP <> '' then
    P^.ActiveIP := IP;
  EndIdentityChange(Index);
  Touch(Index);
end;

procedure TStatsDB.BeginIdentityChange(Index: LongInt);
begin
  if Valid(Index) then
    UnindexProfile(Index);
end;

procedure TStatsDB.EndIdentityChange(Index: LongInt);
begin
  if Valid(Index) then
    IndexProfile(Index);
end;
procedure TStatsDB.DeleteProfile(Index: LongInt);
var
  k: LongInt;
begin
  if not Valid(Index) then
    Exit;
  UnindexProfile(Index);
  if not FBulkDelete then
    for k := 0 to RANK_COUNT - 1 do
      Ranks[k].Remove(Index);
  SetIdIndex(Profiles[Index]^.ID, -1);
  if FDeletedCount >= Length(FDeleted) then
    SetLength(FDeleted, Length(FDeleted) * 2 + 16);
  FDeleted[FDeletedCount] := Profiles[Index]^.ID;
  Inc(FDeletedCount);
  { the other servers of a shared database drop it as well }
  if SyncOn and (FSyncQuiet = 0) and (Profiles[Index]^.ID > 0) then
  begin
    if FSyncDeletedCount >= Length(FSyncDeleted) then
      SetLength(FSyncDeleted, Length(FSyncDeleted) * 2 + 16);
    FSyncDeleted[FSyncDeletedCount].Id := Profiles[Index]^.ID;
    FSyncDeleted[FSyncDeletedCount].MergedInto := Profiles[Index]^.MergedInto;
    Inc(FSyncDeletedCount);
  end;
  { its records on the maps go, and so do the rival entries that name it (at EndBulkDelete when
    many accounts go at once) }
  PM.RemoveAccount(Profiles[Index]^.ID, FSyncQuiet > 0, FBulkDelete);
  FreeProfile(Profiles[Index]);
  Inc(FHoles);
end;

procedure TStatsDB.MergeProfile(DstIndex, SrcIndex, StartingPoints: LongInt);
begin
  if (DstIndex = SrcIndex) or not Valid(DstIndex) or not Valid(SrcIndex) then
    Exit;
  { the records of the maps are added up map by map, the rival entries follow }
  PM.MergeAccount(Profiles[SrcIndex]^.ID, Profiles[DstIndex]^.ID, FSyncQuiet > 0);
  UnindexProfile(SrcIndex);
  MergeProfileInto(Profiles[DstIndex]^, Profiles[SrcIndex]^, StartingPoints);
  IndexProfile(DstIndex);
  Profiles[SrcIndex]^.MergedInto := Profiles[DstIndex]^.ID;
  Touch(DstIndex);
  RefreshRanks(DstIndex);
  DeleteProfile(SrcIndex);
end;

{ ---------------- ranking ---------------- }

function TStatsDB.RankKey(List: LongInt; const P: TPlayerProfile; out Include: Boolean): Int64;
var
  F: LongInt;
begin
  Result := 0;
  Include := False;
  case List of
    RANK_POINTS:
      begin
        Include := (HideAfterDays <= 0) or (P.LastPlayedTime <= 0) or (FNow - P.LastPlayedTime <= HideAfterDays);
        Result := PointsKey(P.Points, P.ID);
      end;
    RANK_SEASON:
      begin
        Include := (Server.SeasonId > 0) and (P.SeasonId = Server.SeasonId) and (P.SeasonTime > 0);
        Result := PointsKey(P.SeasonPoints, P.ID);
      end;
    RANK_RATING_FFA..RANK_RATING_CTF:
      begin
        F := List - RANK_RATING_FFA;
        case RatingSystem of
          RS_GLICKO2:
            begin
              Include := P.Glicko[F].Games > 0;
              Result := RatingKey(GlickoConservative(P.Glicko[F], GlickoK), P.ID);
            end;
          RS_OPENSKILL:
            begin
              Include := P.OpenSkill[F].Games > 0;
              Result := RatingKey(OpenSkillOrdinal(P.OpenSkill[F]), P.ID);
            end;
          RS_MMR:
            begin
              Include := P.Mmr[F].Games > 0;
              Result := RatingKey(P.Mmr[F].R, P.ID);
            end;
        end;
      end;
  end;
end;

procedure TStatsDB.RefreshRanks(Index: LongInt);
var
  k: LongInt;
  Key: Int64;
  Include: Boolean;
begin
  if not Valid(Index) then
    Exit;
  for k := 0 to RANK_COUNT - 1 do
  begin
    Key := RankKey(k, Profiles[Index]^, Include);
    if Include then
      Ranks[k].Update(Index, Key)
    else
      Ranks[k].Remove(Index);
  end;
end;

procedure TStatsDB.BeginBulkDelete;
begin
  FBulkDelete := True;
end;

procedure TStatsDB.EndBulkDelete;
begin
  if not FBulkDelete then
    Exit;
  FBulkDelete := False;
  PM.FlushRivalRemovals(FSyncQuiet > 0);
  RebuildRanks;
end;

procedure TStatsDB.RebuildRanks;
var
  Keys: array of Int64;
  Incl: array of Boolean;
  i, k: LongInt;
begin
  SetLength(Keys, ProfileCount);
  SetLength(Incl, ProfileCount);
  for k := 0 to RANK_COUNT - 1 do
  begin
    for i := 0 to ProfileCount - 1 do
      if Profiles[i] <> nil then
        Keys[i] := RankKey(k, Profiles[i]^, Incl[i])
      else
      begin
        Keys[i] := 0;
        Incl[i] := False;
      end;
    Ranks[k].Build(Keys, Incl, ProfileCount);
  end;
end;

{ ---------------- persistence ---------------- }

procedure TStatsDB.FlushJournal(W: TStoreWriter; IncludeShared: Boolean);
var
  k, i: LongInt;
begin
  { removals first: a number that was given up and is used again in the same interval (the shared
    database hands out numbers, ChangeProfileId) must end with the account that has it now }
  for k := 0 to FDeletedCount - 1 do
    W.JournalDeleteProfile(FDeleted[k]);
  FDeletedCount := 0;
  for k := 0 to FDirtyCount - 1 do
  begin
    i := FDirty[k];
    if Valid(i) and Profiles[i]^.Dirty then
    begin
      W.JournalProfile(Profiles[i]^);
      Profiles[i]^.Dirty := False;
    end;
  end;
  FDirtyCount := 0;
  if IncludeShared then
  begin
    for k := 0 to FDirtyMapCount - 1 do
    begin
      i := FDirtyMaps[k];
      if (i < MapCount) and Maps[i].Dirty then
      begin
        W.JournalMap(Maps[i]);
        Maps[i].Dirty := False;
      end;
    end;
    FDirtyMapCount := 0;
    for k := 0 to High(FDirtySeasons) do
      if (FDirtySeasons[k] >= 0) and (FDirtySeasons[k] < Length(Seasons)) then
        W.JournalSeason(Seasons[FDirtySeasons[k]]);
    FDirtySeasons := nil;
    if FServerDirty then
    begin
      W.JournalServer(Server);
      FServerDirty := False;
    end;
  end;
  { the player-on-map records go with the maps; a removal (a merge, a reset) at once }
  if IncludeShared or PM.PendingRemovals then
    PM.FlushJournal(W);
  W.Flush;
end;

procedure TStatsDB.BeginSnapshot(W: TStoreWriter);
begin
  { pending changes belong to the old generation, before the writer switches }
  FlushJournal(W, True);
  CompactIfNeeded(False);
  W.BeginSnapshot(LiveProfiles, MapCount, Length(Seasons));
  FSnapActive := True;
  FSnapPhase := 0;
  FSnapPos := 0;
  PM.SnapshotBegin;
end;

{ the unfinished file is thrown away; the journal of the new generation stays and is replayed
  after the last complete snapshot }
procedure TStatsDB.AbortSnapshot(W: TStoreWriter);
begin
  if not FSnapActive then
    Exit;
  FSnapActive := False;
  W.AbortSnapshot;
end;

function TStatsDB.ContinueSnapshot(W: TStoreWriter; Budget: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := True;
  if not FSnapActive then
    Exit;
  Result := False;
  if FSnapPhase = 0 then
  begin
    W.SnapshotServer(Server);
    for k := 0 to High(Seasons) do
      W.SnapshotSeason(Seasons[k]);
    FSnapPhase := 1;
    FSnapPos := 0;
  end;
  if FSnapPhase = 1 then
  begin
    while (FSnapPos < MapCount) and (Budget > 0) do
    begin
      W.SnapshotMap(Maps[FSnapPos]);
      Inc(FSnapPos);
      Dec(Budget);
    end;
    if FSnapPos < MapCount then
      Exit;
    FSnapPhase := 2;
    FSnapPos := 0;
  end;
  if FSnapPhase = 2 then
  begin
    while (FSnapPos < ProfileCount) and (Budget > 0) do
    begin
      if Profiles[FSnapPos] <> nil then
      begin
        W.SnapshotProfile(Profiles[FSnapPos]^);
        Dec(Budget);
      end;
      Inc(FSnapPos);
    end;
    if FSnapPos < ProfileCount then
      Exit;
    FSnapPhase := 3;
  end;
  { the player-on-map records last }
  if not PM.SnapshotStep(W, Budget) then
    Exit;
  FSnapActive := False;
  Result := True;
end;

function TStatsDB.CompactIfNeeded(Force: Boolean): Boolean;
var
  i, n, k: LongInt;
  NewIndex: array of LongInt;
begin
  Result := False;
  { dirty lists hold indices, so they must be flushed before entries move }
  if FSnapActive or (FHoles = 0) or (FDirtyCount > 0) then
    Exit;
  if not Force and (FHoles < 256) and (FHoles * 20 < ProfileCount) then
    Exit;
  NewIndex := nil;
  SetLength(NewIndex, ProfileCount);
  n := 0;
  for i := 0 to ProfileCount - 1 do
    if Profiles[i] <> nil then
    begin
      if n <> i then
      begin
        Profiles[n] := Profiles[i];
        Profiles[i] := nil;
      end;
      NewIndex[i] := n;
      Inc(n);
    end
    else
      NewIndex[i] := -1;
  { the accounts waiting for the next exchange with the shared database are kept by index as
    well: they follow their account, and the removed ones are dropped. Without this the next
    exchange would send the wrong accounts and never send the moved ones (their SyncDirty mark
    stops them from being queued again). }
  k := 0;
  for i := 0 to FSyncProfileCount - 1 do
    if (FSyncProfiles[i] >= 0) and (FSyncProfiles[i] < ProfileCount) and (NewIndex[FSyncProfiles[i]] >= 0) then
    begin
      FSyncProfiles[k] := NewIndex[FSyncProfiles[i]];
      Inc(k);
    end;
  FSyncProfileCount := k;
  ProfileCount := n;
  FHoles := 0;
  RebuildIndexes;
  RebuildRanks;
  Result := True;
end;

end.
