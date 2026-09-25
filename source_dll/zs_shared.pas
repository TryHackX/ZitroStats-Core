unit zs_shared;

{ Statistics of several game servers on one database ([MySQL] SharedProfiles, SharedRankings,
  SharedMaps, SharedWeapons, SharedServer - each off by default).

  Every server keeps its own files, points and rankings. With a Shared switch on, the MySQL copy
  also carries what the other servers need: the complete record of every account (by SteamID, or
  by computer without Steam - SharedIdentity), of every map, and of the server with the sum of all
  its accounts. The mirror thread (zs_mysql) reads what the other servers of the database wrote
  into the pool below - one entry per account, one per map name and one for all the other servers
  together - and the commands add the pool to this server's numbers. The pool has a lock of its
  own: the mirror thread changes one entry at a time, the engine thread reads it. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, md5, zs_types, zs_util, zs_fields, zs_db, zs_engine;

const
  POOL_PROFILES = 1;
  POOL_MAPS = 2;
  POOL_SERVER = 4;

type
  { an account of a ranking: this server's (Idx), known only to the other servers (Pool), or both }
  TRankEntry = record
    Idx: LongInt;
    Pool: LongInt;
    Points: LongInt;
  end;
  TRankEntryArray = array of TRankEntry;

{ Engine = mirror runs: the setting, and no exchange with a shared database (Engine = mysql) that
  runs since the start - a reload from mysql to mirror takes effect at the next start, as every
  other [MySQL] change of a running exchange does, instead of a copy next to it }
function MirrorOn(E: TZSEngine): Boolean;
{ an account's name across servers: its SteamID, and for an account without Steam its computer
  (H: and an MD5 fingerprint of its HWID, the same on every server); '' when it has neither, or
  when it is longer than the column it goes into (zs_players.steam_id, 40 characters) }
function SharedIdentity(const P: TPlayerProfile): AnsiString;
{ SharedIdentity of this server's account Idx, which no other account of this server has: when two
  of them are the account of one computer (a registered one and one without a password, after the
  owner logged in there again), the computer goes to one of them only - the one without a
  password, else the older one - and the other has none, so the other servers join that computer
  to one account, and this server joins their numbers to one account }
function SharedIdentityOf(DB: TStatsDB; Idx: LongInt): AnsiString;
{ SharedMaps: the maps the other servers know and this one never played, and one of them as a
  record (nil when it is gone); a map by its name or a part of it, '' when none }
function MapPoolOnly(E: TZSEngine): TStringArray;
function PoolMapView(E: TZSEngine; const Key: AnsiString; var Tmp: TMapProfile; Heat: Boolean = False): PMapProfile;
function FindPoolMap(E: TZSEngine; const Text: AnsiString): AnsiString;
{ the day, week and month add up only for the same period: the newer one of the two starts from
  zero in Dst, and AddPeriods adds what belongs to it }
procedure AlignPeriods(var Dst: TPlayerProfile; const Src: TPlayerProfile);
procedure AddPeriods(var Dst: TPlayerProfile; const Src: TPlayerProfile);

{ ---- the engine thread: what the commands show ---- }

{ SharedProfiles: this server's account with the numbers of the other servers added; points,
  ratings, seasons, badges and rivals stay this server's. Note is a line to print first, '' when
  there is nothing to say. }
function SharedView(E: TZSEngine; Idx: LongInt; var Tmp: TPlayerProfile; out Note: AnsiString): PPlayerProfile;
{ SharedMaps: this server's map with the maps of the same name on the other servers; the heat
  cells only when Heat (they take the longest) }
function SharedMapView(E: TZSEngine; MI: LongInt; var Tmp: TMapProfile; Heat: Boolean = False): PMapProfile;
function MapsShared(E: TZSEngine): Boolean;
{ the server record with the other servers' added, when Use (SharedWeapons or SharedServer) is on }
function SharedServerView(E: TZSEngine; Use: Boolean; var Tmp: TServerRecords): PServerRecords;
{ the accounts of the other servers added up; False when there is nothing to add }
function SharedAccountSums(E: TZSEngine; Use: Boolean; var Sum: TPlayerProfile): Boolean;
{ how many other servers the pool holds for a group (POOL_*) }
function SharedServerCount(What: LongInt): LongInt;

{ SharedRankings: the ranking of every server of the database - the points an account won on
  every one of them, above the starting points - best first, without the accounts that played on
  no server for DecayHideAfterDays (as in this server's ranking); without it this server's ranking }
function RankingShared(E: TZSEngine): Boolean;
function RankingOrder(E: TZSEngine): TRankEntryArray;
{ every account the lists go through, in no order: this server's and, with SharedRankings, the
  players known only to the other servers }
function RankingEntries(E: TZSEngine): TRankEntryArray;
{ the account of an entry with the numbers of every server; Tmp holds it when it is not this
  server's own record }
function RankingView(E: TZSEngine; const R: TRankEntry; var Tmp: TPlayerProfile): PPlayerProfile;
{ the place of this server's account in the ranking the lists show (1 = best, 0 = none) }
function RankingPosition(E: TZSEngine; Idx: LongInt): LongInt;
{ the points the lists show for this server's account }
function RankingPoints(E: TZSEngine; Idx: LongInt): LongInt;

{ ---- the mirror thread ---- }

procedure PoolPutPlayer(const Identity, Name: AnsiString; const Others: TPlayerProfile; Gain: Int64; Servers: LongInt);
procedure PoolDropPlayer(const Identity: AnsiString);
procedure PoolPutMap(const Key: AnsiString; const Others: TMapProfile; Servers: LongInt);
procedure PoolDropMap(const Key: AnsiString);
procedure PoolPutServer(const Others: TServerRecords; const Sums: TPlayerProfile; Servers: LongInt);
procedure PoolLoaded(What, Servers: LongInt);
procedure PoolReset;

implementation

const
  ORDER_CACHE_MS = 3000;   { the ranking of every server is built again after this long }

type
  TPoolPlayer = record
    Identity: AnsiString;
    Name: AnsiString;          { the name last used on the other servers }
    Others: TPlayerProfile;    { the other servers added up }
    Gain: Int64;               { points won there above the starting points }
    Servers: LongInt;
    Used: Boolean;
  end;

  TPoolMap = record
    Key: AnsiString;           { the name in small letters }
    Others: TMapProfile;
    Servers: LongInt;
    Used: Boolean;
  end;

var
  Lock: TRTLCriticalSection;
  Players: array of TPoolPlayer;
  PlayerIndex: TStringList = nil;   { identity -> slot in Players }
  Maps: array of TPoolMap;
  MapIndex: TStringList = nil;
  ServerOthers: TServerRecords;
  ServerSums: TPlayerProfile;
  ServerCount: LongInt = 0;
  PlayerServers: LongInt = 0;       { other servers with accounts, maps in the pool }
  MapServers: LongInt = 0;
  Loaded: LongInt = 0;
  Version: LongInt = 0;             { changes with every change of the players }

  { the engine thread's copy of the ranking of every server }
  OrderCache: TRankEntryArray;
  OrderPos: array of LongInt;       { account of this server -> place, 0 = none }
  OrderStamp: Int64 = 0;
  OrderVersion: LongInt = -1;
  OrderShared: Boolean = False;
  OrderGen: LongWord = 0;           { E.DB.IndexGen of the order: a compaction moves the accounts }

function MirrorOn(E: TZSEngine): Boolean;
begin
  Result := E.Cfg.MySQLEnabled and (E.SqlState = nil);
end;

{ the same player on every server: a Steam account by its SteamID, an account without Steam by
  its computer - as on one server, where names are free - hashed, so the table shows no HWID }
function SharedIdentity(const P: TPlayerProfile): AnsiString;
begin
  Result := Trim(P.ActiveSteam);
  if (Result = 'S0') or (Result = '0') then
    Result := '';
  if (Result = '') and (Trim(P.ActiveHWID) <> '') then
    Result := 'H:' + MD5Print(MD5String(UpperCase(Trim(P.ActiveHWID))));
  { a value the column cannot hold would make the whole pass of the copy fail (strict mode) }
  if Length(Result) > 40 then
    Result := '';
end;

function SharedIdentityOf(DB: TStatsDB; Idx: LongInt): AnsiString;
var
  P, Q: PPlayerProfile;
  C: TIntArray;
  k: LongInt;
begin
  Result := '';
  if not DB.Valid(Idx) then
    Exit;
  P := DB.Profiles[Idx];
  Result := SharedIdentity(P^);
  if Copy(Result, 1, 2) <> 'H:' then
    Exit;
  { the accounts of this computer: HWID and trusted computers are indexed, Steam accounts are not }
  C := DB.IndexesOfHwid(Trim(P^.ActiveHWID));
  for k := 0 to High(C) do
  begin
    if (C[k] = Idx) or not DB.Valid(C[k]) then
      Continue;
    Q := DB.Profiles[C[k]];
    if SharedIdentity(Q^) <> Result then
      Continue;
    if ((Q^.PassHash = '') and (P^.PassHash <> '')) or
       (((Q^.PassHash = '') = (P^.PassHash = '')) and (Q^.ID < P^.ID)) then
      Exit('');
  end;
end;

procedure AlignPeriods(var Dst: TPlayerProfile; const Src: TPlayerProfile);
var
  j: LongInt;
begin
  for j := 0 to 2 do
    if Src.Period[j].Key > Dst.Period[j].Key then
    begin
      FillChar(Dst.Period[j], SizeOf(TPeriodStats), 0);
      Dst.Period[j].Key := Src.Period[j].Key;
    end;
end;

procedure AddPeriods(var Dst: TPlayerProfile; const Src: TPlayerProfile);
var
  j: LongInt;
begin
  for j := 0 to 2 do
    if (Src.Period[j].Key <> 0) and (Src.Period[j].Key = Dst.Period[j].Key) then
    begin
      Inc(Dst.Period[j].Kills, Src.Period[j].Kills);
      Inc(Dst.Period[j].Deaths, Src.Period[j].Deaths);
      Inc(Dst.Period[j].PointsDelta, Src.Period[j].PointsDelta);
      Inc(Dst.Period[j].Caps, Src.Period[j].Caps);
      Inc(Dst.Period[j].Wins, Src.Period[j].Wins);
      Inc(Dst.Period[j].Headshots, Src.Period[j].Headshots);
      Inc(Dst.Period[j].TimePlayed, Src.Period[j].TimePlayed);
    end;
end;

function PlayerSlot(const Identity: AnsiString): LongInt;
var
  i: LongInt;
begin
  Result := -1;
  if (PlayerIndex <> nil) and PlayerIndex.Find(Identity, i) then
    Result := PtrInt(PlayerIndex.Objects[i]);
end;

function MapSlot(const Key: AnsiString): LongInt;
var
  i: LongInt;
begin
  Result := -1;
  if (MapIndex <> nil) and MapIndex.Find(Key, i) then
    Result := PtrInt(MapIndex.Objects[i]);
end;

function NewIndex: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Result.CaseSensitive := True;
end;

{ ---------------- the mirror thread ---------------- }

procedure PoolPutPlayer(const Identity, Name: AnsiString; const Others: TPlayerProfile; Gain: Int64; Servers: LongInt);
var
  k: LongInt;
begin
  EnterCriticalSection(Lock);
  try
    if PlayerIndex = nil then
      PlayerIndex := NewIndex;
    k := PlayerSlot(Identity);
    if k < 0 then
    begin
      { the slots are never used again: an entry the engine found stays what it was }
      k := Length(Players);
      SetLength(Players, k + 1);
      PlayerIndex.AddObject(Identity, TObject(PtrInt(k)));
    end;
    Players[k].Identity := Identity;
    Players[k].Name := Name;
    Players[k].Others := Others;
    Players[k].Gain := Gain;
    Players[k].Servers := Servers;
    Players[k].Used := True;
    Inc(Version);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure PoolDropPlayer(const Identity: AnsiString);
var
  i, k: LongInt;
begin
  EnterCriticalSection(Lock);
  try
    if (PlayerIndex = nil) or not PlayerIndex.Find(Identity, i) then
      Exit;
    k := PtrInt(PlayerIndex.Objects[i]);
    PlayerIndex.Delete(i);
    Players[k].Used := False;
    ClearProfile(Players[k].Others);
    Inc(Version);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure PoolPutMap(const Key: AnsiString; const Others: TMapProfile; Servers: LongInt);
var
  k: LongInt;
begin
  EnterCriticalSection(Lock);
  try
    if MapIndex = nil then
      MapIndex := NewIndex;
    k := MapSlot(Key);
    if k < 0 then
    begin
      k := Length(Maps);
      SetLength(Maps, k + 1);
      MapIndex.AddObject(Key, TObject(PtrInt(k)));
    end;
    Maps[k].Key := Key;
    Maps[k].Others := Others;
    Maps[k].Servers := Servers;
    Maps[k].Used := True;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure PoolDropMap(const Key: AnsiString);
var
  i, k: LongInt;
begin
  EnterCriticalSection(Lock);
  try
    if (MapIndex = nil) or not MapIndex.Find(Key, i) then
      Exit;
    k := PtrInt(MapIndex.Objects[i]);
    MapIndex.Delete(i);
    Maps[k].Used := False;
    ClearMap(Maps[k].Others);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure PoolPutServer(const Others: TServerRecords; const Sums: TPlayerProfile; Servers: LongInt);
begin
  EnterCriticalSection(Lock);
  try
    ServerOthers := Others;
    ServerSums := Sums;
    ServerCount := Servers;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure PoolLoaded(What, Servers: LongInt);
begin
  EnterCriticalSection(Lock);
  try
    Loaded := Loaded or What;
    case What of
      POOL_PROFILES: PlayerServers := Servers;
      POOL_MAPS: MapServers := Servers;
    end;
    Inc(Version);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure PoolReset;
begin
  EnterCriticalSection(Lock);
  try
    Players := nil;
    FreeAndNil(PlayerIndex);
    Maps := nil;
    FreeAndNil(MapIndex);
    ClearServer(ServerOthers);
    ClearProfile(ServerSums);
    ServerCount := 0;
    PlayerServers := 0;
    MapServers := 0;
    Loaded := 0;
    Inc(Version);
  finally
    LeaveCriticalSection(Lock);
  end;
  OrderCache := nil;
  OrderPos := nil;
  OrderStamp := 0;
end;

function IsLoaded(What: LongInt): Boolean;
begin
  EnterCriticalSection(Lock);
  try
    Result := (Loaded and What) <> 0;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function SharedServerCount(What: LongInt): LongInt;
begin
  EnterCriticalSection(Lock);
  try
    case What of
      POOL_PROFILES: Result := PlayerServers;
      POOL_MAPS: Result := MapServers;
      else Result := ServerCount;
    end;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

{ ---------------- profiles ---------------- }

function SharedView(E: TZSEngine; Idx: LongInt; var Tmp: TPlayerProfile; out Note: AnsiString): PPlayerProfile;
var
  Id: AnsiString;
  k, Servers: LongInt;
  L: PPlayerProfile;
begin
  Note := '';
  L := E.DB.Profiles[Idx];
  Result := L;
  if not MirrorOn(E) or not E.Cfg.MySQLShareProfiles then
    Exit;
  Id := SharedIdentityOf(E.DB, Idx);
  if Id = '' then
    Exit;
  if not IsLoaded(POOL_PROFILES) then
  begin
    Note := 'Other servers: their numbers are still being loaded - ask again in a moment.';
    Exit;
  end;
  Tmp := L^;
  { the copy has to have lists of its own before anything is added to them }
  UniqueProfileLists(Tmp);
  EnterCriticalSection(Lock);
  try
    k := PlayerSlot(Id);
    if (k < 0) or not Players[k].Used then
      Exit;
    AlignPeriods(Tmp, Players[k].Others);
    MergeProfileInto(Tmp, Players[k].Others, E.Cfg.StartingPoints);
    Servers := Players[k].Servers;
  finally
    LeaveCriticalSection(Lock);
  end;
  { the rankings are per server: points, ratings, seasons, badges and rivals stay this server's }
  Tmp.Points := L^.Points;
  Tmp.SeasonId := L^.SeasonId;
  Tmp.SeasonPoints := L^.SeasonPoints;
  Tmp.SeasonKills := L^.SeasonKills;
  Tmp.SeasonDeaths := L^.SeasonDeaths;
  Tmp.SeasonCaps := L^.SeasonCaps;
  Tmp.SeasonWins := L^.SeasonWins;
  Tmp.SeasonTime := L^.SeasonTime;
  Tmp.Badges := Copy(L^.Badges);
  Tmp.TopVictims := L^.TopVictims;
  Tmp.TopNemeses := L^.TopNemeses;
  Tmp.ActiveName := L^.ActiveName + Format(' [%d servers]', [Servers + 1]);
  Result := @Tmp;
end;

{ ---------------- maps and the server ---------------- }

function MapsShared(E: TZSEngine): Boolean;
begin
  Result := MirrorOn(E) and E.Cfg.MySQLShareMaps and IsLoaded(POOL_MAPS);
end;

function SharedMapView(E: TZSEngine; MI: LongInt; var Tmp: TMapProfile; Heat: Boolean = False): PMapProfile;
var
  k: LongInt;
begin
  Result := @E.DB.Maps[MI];
  if not MapsShared(E) then
    Exit;
  EnterCriticalSection(Lock);
  try
    k := MapSlot(LowerCase(E.DB.Maps[MI].MapName));
    if (k < 0) or not Maps[k].Used then
      Exit;
    Tmp := E.DB.Maps[MI];
    if Heat then
      Tmp.Heat := Copy(Tmp.Heat)
    else
      Tmp.Heat := nil;
    MergeMapInto(Tmp, Maps[k].Others, Heat);
  finally
    LeaveCriticalSection(Lock);
  end;
  Result := @Tmp;
end;

function SharedServerView(E: TZSEngine; Use: Boolean; var Tmp: TServerRecords): PServerRecords;
begin
  Result := @E.DB.Server;
  if not Use or not MirrorOn(E) or not IsLoaded(POOL_SERVER) then
    Exit;
  Tmp := E.DB.Server;
  Tmp.Daily := Copy(Tmp.Daily);
  EnterCriticalSection(Lock);
  try
    if ServerCount = 0 then
      Exit;
    MergeServerInto(Tmp, ServerOthers);
  finally
    LeaveCriticalSection(Lock);
  end;
  Result := @Tmp;
end;

function SharedAccountSums(E: TZSEngine; Use: Boolean; var Sum: TPlayerProfile): Boolean;
begin
  Result := False;
  if not Use or not MirrorOn(E) or not IsLoaded(POOL_SERVER) then
    Exit;
  EnterCriticalSection(Lock);
  try
    Result := ServerCount > 0;
    if Result then
      Sum := ServerSums;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function MapPoolOnly(E: TZSEngine): TStringArray;
var
  Local: TStringList;
  k, n: LongInt;
begin
  Result := nil;
  if not MapsShared(E) then
    Exit;
  Local := TStringList.Create;
  try
    Local.Sorted := True;
    Local.Duplicates := dupIgnore;
    for k := 0 to E.DB.MapCount - 1 do
      Local.Add(LowerCase(E.DB.Maps[k].MapName));
    EnterCriticalSection(Lock);
    try
      SetLength(Result, Length(Maps));
      n := 0;
      for k := 0 to High(Maps) do
        if Maps[k].Used and (Local.IndexOf(Maps[k].Key) < 0) then
        begin
          Result[n] := Maps[k].Key;
          Inc(n);
        end;
      SetLength(Result, n);
    finally
      LeaveCriticalSection(Lock);
    end;
  finally
    Local.Free;
  end;
end;

function PoolMapView(E: TZSEngine; const Key: AnsiString; var Tmp: TMapProfile; Heat: Boolean = False): PMapProfile;
var
  k: LongInt;
begin
  Result := nil;
  EnterCriticalSection(Lock);
  try
    k := MapSlot(Key);
    if (k < 0) or not Maps[k].Used then
      Exit;
    Tmp := Maps[k].Others;
    if not Heat then
      Tmp.Heat := nil;
    if Tmp.MapName = '' then
      Tmp.MapName := Key;
    Tmp.ID := 0;
    Result := @Tmp;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function FindPoolMap(E: TZSEngine; const Text: AnsiString): AnsiString;
var
  Keys: TStringArray;
  k, Best: LongInt;
  Low: AnsiString;
begin
  Result := '';
  Low := LowerCase(Trim(Text));
  if Low = '' then
    Exit;
  Keys := MapPoolOnly(E);
  Best := -1;
  for k := 0 to High(Keys) do
    if Keys[k] = Low then
      Exit(Keys[k])
    else if (Best < 0) and (Pos(Low, Keys[k]) = 1) then
      Best := k;
  if Best < 0 then
    for k := 0 to High(Keys) do
      if Pos(Low, Keys[k]) > 0 then
      begin
        Best := k;
        Break;
      end;
  if Best >= 0 then
    Result := Keys[Best];
end;

{ ---------------- the ranking of every server ---------------- }

function RankingShared(E: TZSEngine): Boolean;
begin
  Result := MirrorOn(E) and E.Cfg.MySQLShareRankings and IsLoaded(POOL_PROFILES);
end;

function CombinedPoints(Local: LongInt; Gain: Int64): LongInt;
begin
  Result := LongInt(EnsureRange(Int64(Local) + Gain, 0, High(LongInt)));
end;

{ more points first; the same points keep this server's accounts first, the older one first }
function Before(const X, Y: TRankEntry): Boolean;
begin
  if X.Points <> Y.Points then
    Result := X.Points > Y.Points
  else if (X.Idx >= 0) <> (Y.Idx >= 0) then
    Result := X.Idx >= 0
  else if X.Idx >= 0 then
    Result := X.Idx < Y.Idx
  else
    Result := X.Pool < Y.Pool;
end;

procedure SortEntries(var A: TRankEntryArray; L, R: LongInt);
var
  i, j: LongInt;
  Pivot, T: TRankEntry;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := A[(L + R) shr 1];
    repeat
      while Before(A[i], Pivot) do
        Inc(i);
      while Before(Pivot, A[j]) do
        Dec(j);
      if i <= j then
      begin
        T := A[i];
        A[i] := A[j];
        A[j] := T;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - L < R - j then
    begin
      SortEntries(A, L, j);
      L := i;
    end
    else
    begin
      SortEntries(A, i, R);
      R := j;
    end;
  end;
end;

{ an account the points ranking shows: with InactivityMode = decay one that played within
  DecayHideAfterDays - the rule of this server's own ranking (zs_db RankKey) }
function Shown(E: TZSEngine; LastPlayed: Double): Boolean;
begin
  Result := (E.DB.HideAfterDays <= 0) or (LastPlayed <= 0) or (E.DB.NowValue - LastPlayed <= E.DB.HideAfterDays);
end;

{ every valid account of this server, its entry of the other servers joined to it by
  SharedIdentity, and then the players of the other servers who never played here; Ranked
  leaves out who has not played on any server for too long, as the ranking of this server does }
function CollectEntries(E: TZSEngine; Shared, Ranked: Boolean): TRankEntryArray;
var
  k, n, Slot: LongInt;
  Seen: array of Boolean;
  Id: AnsiString;
  Last: Double;
begin
  Result := nil;
  if not Shared then
  begin
    SetLength(Result, E.DB.ProfileCount);
    n := 0;
    for k := 0 to E.DB.ProfileCount - 1 do
      if E.DB.Valid(k) then
      begin
        Result[n].Idx := k;
        Result[n].Pool := -1;
        Result[n].Points := E.DB.Profiles[k]^.Points;
        Inc(n);
      end;
    SetLength(Result, n);
    Exit;
  end;
  EnterCriticalSection(Lock);
  try
    SetLength(Seen, Length(Players));
    SetLength(Result, E.DB.ProfileCount + Length(Players));
    n := 0;
    for k := 0 to E.DB.ProfileCount - 1 do
    begin
      if not E.DB.Valid(k) then
        Continue;
      Result[n].Idx := k;
      Result[n].Pool := -1;
      Result[n].Points := E.DB.Profiles[k]^.Points;
      Last := E.DB.Profiles[k]^.LastPlayedTime;
      Id := SharedIdentityOf(E.DB, k);
      if Id <> '' then
      begin
        Slot := PlayerSlot(Id);
        if (Slot >= 0) and Players[Slot].Used then
        begin
          Result[n].Pool := Slot;
          Result[n].Points := CombinedPoints(E.DB.Profiles[k]^.Points, Players[Slot].Gain);
          Seen[Slot] := True;
          if Players[Slot].Others.LastPlayedTime > Last then
            Last := Players[Slot].Others.LastPlayedTime;
        end;
      end;
      if Ranked and not Shown(E, Last) then
        Continue;
      Inc(n);
    end;
    for k := 0 to High(Players) do
      if Players[k].Used and not Seen[k] and (not Ranked or Shown(E, Players[k].Others.LastPlayedTime)) then
      begin
        Result[n].Idx := -1;
        Result[n].Pool := k;
        Result[n].Points := CombinedPoints(E.Cfg.StartingPoints, Players[k].Gain);
        Inc(n);
      end;
  finally
    LeaveCriticalSection(Lock);
  end;
  SetLength(Result, n);
end;

function RankingEntries(E: TZSEngine): TRankEntryArray;
begin
  Result := CollectEntries(E, RankingShared(E), False);
end;

procedure BuildOrder(E: TZSEngine);
var
  k, n, r, Count: LongInt;
begin
  OrderShared := RankingShared(E);
  OrderStamp := MonoMs;
  OrderGen := E.DB.IndexGen;
  if not OrderShared then
  begin
    { this server's ranking, in its own order }
    Count := E.DB.Ranks[RANK_POINTS].Count;
    SetLength(OrderCache, Count);
    n := 0;
    for r := 1 to Count do
    begin
      k := E.DB.Ranks[RANK_POINTS].At(r);
      if not E.DB.Valid(k) then
        Continue;
      OrderCache[n].Idx := k;
      OrderCache[n].Pool := -1;
      OrderCache[n].Points := E.DB.Profiles[k]^.Points;
      Inc(n);
    end;
    SetLength(OrderCache, n);
  end
  else
  begin
    EnterCriticalSection(Lock);
    OrderVersion := Version;
    LeaveCriticalSection(Lock);
    OrderCache := CollectEntries(E, True, True);
    if Length(OrderCache) > 1 then
      SortEntries(OrderCache, 0, High(OrderCache));
  end;
  OrderPos := nil;
  SetLength(OrderPos, E.DB.ProfileCount);
  for k := 0 to High(OrderCache) do
    if (OrderCache[k].Idx >= 0) and (OrderCache[k].Idx < Length(OrderPos)) then
      OrderPos[OrderCache[k].Idx] := k + 1;
end;

procedure FreshOrder(E: TZSEngine);
var
  V: LongInt;
begin
  EnterCriticalSection(Lock);
  V := Version;
  LeaveCriticalSection(Lock);
  if (OrderStamp = 0) or (MonoMs - OrderStamp >= ORDER_CACHE_MS) or (RankingShared(E) <> OrderShared) or
     (OrderShared and (V <> OrderVersion)) or (Length(OrderPos) <> E.DB.ProfileCount) or (OrderGen <> E.DB.IndexGen) then
    BuildOrder(E);
end;

function RankingOrder(E: TZSEngine): TRankEntryArray;
begin
  { this server's ranking is always current; the ranking of every server is built again after a
    few seconds or when the other servers' numbers change }
  if not RankingShared(E) then
    OrderStamp := 0;
  FreshOrder(E);
  Result := OrderCache;
end;

function RankingPosition(E: TZSEngine; Idx: LongInt): LongInt;
begin
  if not RankingShared(E) then
    Exit(E.PlayerRank(Idx));
  FreshOrder(E);
  if (Idx >= 0) and (Idx < Length(OrderPos)) then
    Result := OrderPos[Idx]
  else
    Result := 0;
end;

function RankingPoints(E: TZSEngine; Idx: LongInt): LongInt;
var
  p, Slot: LongInt;
  Id: AnsiString;
begin
  Result := E.DB.Profiles[Idx]^.Points;
  if not RankingShared(E) then
    Exit;
  FreshOrder(E);
  if (Idx >= 0) and (Idx < Length(OrderPos)) then
  begin
    p := OrderPos[Idx];
    if (p > 0) and (p <= Length(OrderCache)) then
      Exit(OrderCache[p - 1].Points);
  end;
  { an account the ranking leaves out (not played for too long) has the points of every server
    all the same }
  Id := SharedIdentityOf(E.DB, Idx);
  if Id = '' then
    Exit;
  EnterCriticalSection(Lock);
  try
    Slot := PlayerSlot(Id);
    if (Slot >= 0) and Players[Slot].Used then
      Result := CombinedPoints(Result, Players[Slot].Gain);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function RankingView(E: TZSEngine; const R: TRankEntry; var Tmp: TPlayerProfile): PPlayerProfile;
begin
  { an entry of an order built a moment ago: its account may be gone since }
  if (R.Idx >= 0) and not E.DB.Valid(R.Idx) then
    Exit(nil);
  if (R.Pool < 0) and (R.Idx >= 0) then
    Exit(E.DB.Profiles[R.Idx]);
  Result := nil;
  EnterCriticalSection(Lock);
  try
    if (R.Pool < 0) or (R.Pool > High(Players)) or not Players[R.Pool].Used then
    begin
      if R.Idx >= 0 then
        Result := E.DB.Profiles[R.Idx];
      Exit;
    end;
    if R.Idx >= 0 then
    begin
      { counters and periods only: the lists need no names, badges or rivals of the others }
      Tmp := E.DB.Profiles[R.Idx]^;
      AlignPeriods(Tmp, Players[R.Pool].Others);
      SumProfileCounters(Tmp, Players[R.Pool].Others);
      AddPeriods(Tmp, Players[R.Pool].Others);
    end
    else
    begin
      Tmp := Players[R.Pool].Others;
      Tmp.ActiveName := Players[R.Pool].Name;
      Tmp.ActiveSteam := Players[R.Pool].Identity;
      Tmp.ID := 0;
    end;
    Tmp.Points := R.Points;
    Result := @Tmp;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

initialization
  InitCriticalSection(Lock);

finalization
  PoolReset;
  DoneCriticalSection(Lock);

end.
