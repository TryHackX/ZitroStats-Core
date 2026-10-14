program test_matrix;

{ [Matrix] (5.5): the player-on-map records (zs_matrix) with their lists and store records, the new
  fields of maps and of the weapons of an account, merges, removals, renumbering and pruning through
  TStatsDB, the bookkeeping of the table for a shared database, the [Matrix] settings, and an engine
  run in which every record counts what the account's own statistics count on its map. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_fileio, zs_fields, zs_store, zs_db, zs_matrix, zs_config,
  zs_engine;

const
  SNAP = 'zitrostats.zsdb';
  JOUR = 'zitrostats.journal';
  { the wire types of zs_fields }
  T_I32 = 1;
  T_STR = 6;
  T_BLOB = 7;
  STEAMS: array[1..4] of AnsiString = ('S2001', 'S2002', 'S2003', 'S2004');

var
  Failures: Integer = 0;
  DummyP: TPlayerProfile;
  DummyR: TPlayerMapStats;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  { the id of the last Map.RayCast question the engine asked (ACT_RAYCAST) }
  LastRayId: LongInt;
  { the accounts of the engine run before and after a map }
  Before, After: array[1..4] of TPlayerProfile;

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
  try
    for i := 0 to L.Count - 1 do
      DeleteFile(IncludeTrailingPathDelimiter(Dir) + L[i]);
  finally
    L.Free;
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

function WaitCommit(IO: TStoreIO; Tag: LongInt): Boolean;
var
  R: TStoreResult;
  T0: Int64;
begin
  T0 := MonoMs;
  repeat
    while IO.PollResult(R) do
    begin
      if R.Message <> '' then
        WriteLn('       io: ', R.Message);
      if (R.Kind = sjSnapshotCommit) and (R.Tag = Tag) then
        Exit(R.Ok);
    end;
    Sleep(2);
  until MonoMs - T0 > 30000;
  Result := False;
end;

function WaitIdle(IO: TStoreIO): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not IO.Idle do
  begin
    if MonoMs - T0 > 30000 then
      Exit(False);
    Sleep(2);
  end;
  Result := True;
end;

{ ---------------- records and fields written by hand ---------------- }

function U8(V: Byte): AnsiString;
begin
  Result := AnsiChar(V);
end;

function U16(V: Word): AnsiString;
begin
  SetLength(Result, 2);
  Move(V, Result[1], 2);
end;

function U32(V: LongWord): AnsiString;
begin
  SetLength(Result, 4);
  Move(V, Result[1], 4);
end;

{ a field as zs_fields writes it: its id, its wire type and its value }
function FInt(Id: Word; V: LongInt): AnsiString;
begin
  Result := U16(Id) + U8(T_I32) + U32(LongWord(V));
end;

function FStr(Id: Word; const S: AnsiString): AnsiString;
begin
  Result := U16(Id) + U8(T_STR) + U16(Length(S)) + S;
end;

function FBlob(Id: Word; const B: AnsiString): AnsiString;
begin
  Result := U16(Id) + U8(T_BLOB) + U32(Length(B)) + B;
end;

{ the entries of a list: their count, then each with its length in front }
function Entries(const E: array of AnsiString): AnsiString;
var
  i: LongInt;
begin
  Result := U32(Length(E));
  for i := 0 to High(E) do
    Result := Result + U16(Length(E[i])) + E[i];
end;

{ heat cells: their count, then the cell, kills and deaths of each }
function HeatBlob(const V: array of LongInt): AnsiString;
var
  i: LongInt;
begin
  Result := U32(Length(V) div 3);
  for i := 0 to High(V) do
    Result := Result + U32(LongWord(V[i]));
end;

function Weapon(Slot, Kills, Deaths: LongInt): TPMWeapon;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Slot := Slot;
  Result.Kills := Kills;
  Result.Deaths := Deaths;
end;

function Rival(Id, Kills, Deaths: LongInt; Dealt, Taken: Single; Last: Double): TPMRival;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := Id;
  Result.Kills := Kills;
  Result.Deaths := Deaths;
  Result.DamageDealt := Dealt;
  Result.DamageTaken := Taken;
  Result.LastFight := Last;
end;

{ the same with the points won from the rival and lost to him }
function RivalPts(Id, Kills, Deaths, Won, Lost: LongInt; Last: Double): TPMRival;
begin
  Result := Rival(Id, Kills, Deaths, 0, 0, Last);
  Result.PointsWon := Won;
  Result.PointsLost := Lost;
end;

function Matchup(Mine, Theirs, Wins, Losses: LongInt): TPMMatchup;
begin
  Result.Mine := Mine;
  Result.Theirs := Theirs;
  Result.Wins := Wins;
  Result.Losses := Losses;
end;

function HeatCell(Cell, Kills, Deaths: LongInt): THeatCell;
begin
  Result.Cell := Cell;
  Result.Kills := Kills;
  Result.Deaths := Deaths;
end;

function RivalAt(const R: TPlayerMapStats; Id: LongInt): LongInt;
begin
  if not PMRivalPos(R.Rivals, Id, Result) then
    Result := -1;
end;

procedure SampleRecord(out R: TPlayerMapStats);
begin
  ClearPlayerMap(R);
  R.AccountId := 42;
  R.MapName := 'ctf_Ash';
  R.FirstPlayed := 46000.5;
  R.LastPlayed := 46001.25;
  R.TimePlayed := 5000000000;
  R.Matches := 3;
  R.Wins := 2;
  R.Losses := 1;
  R.Draws := 1;
  R.RoundsWon := 4;
  R.RoundsLost := 5;
  R.Kills := 17;
  R.Deaths := 9;
  R.Selfkills := 1;
  R.Teamkills := 2;
  R.Assists := 3;
  R.Points := -12;
  R.Caps := 1;
  R.Returns := 2;
  R.Grabs := 3;
  R.Shots := 400;
  R.Hits := 120;
  R.HitsHead := 10;
  R.HitsBody := 90;
  R.HitsLegs := 20;
  R.DamageDealt := 2345.5;
  R.DamageReceived := 1234.25;
  R.HealRegen := 55.5;
  R.BestStreak := 6;
  R.FirstBloods := 2;
  R.RoundFirstBloods := 1;
  R.LastStands := 1;
  R.LongestKill := 87.5;
  SetLength(R.Weapons, 2);
  R.Weapons[0] := Weapon(WEP_AK74, 10, 3);
  R.Weapons[0].Shots := 300;
  R.Weapons[0].Hits := 90;
  R.Weapons[0].Headshots := 7;
  R.Weapons[0].Damage := 1800.5;
  R.Weapons[0].TimeUsed := 600;
  R.Weapons[1] := Weapon(WEP_BARRETT, 7, 6);
  SetLength(R.Rivals, 3);
  R.Rivals[0] := Rival(5, 4, 1, 300, 90, 46001);
  R.Rivals[0].PointsWon := 88;
  R.Rivals[0].PointsLost := 21;
  R.Rivals[1] := Rival(17, 2, 5, 120, 400, 46001.1);
  R.Rivals[1].PointsLost := 2000000;
  R.Rivals[2] := Rival(99, 0, 1, 0, 150, 46000.9);
  SetLength(R.Matchups, 2);
  R.Matchups[0] := Matchup(WEP_AK74, WEP_BARRETT, 5, 2);
  R.Matchups[1] := Matchup(WEP_BARRETT, WEP_AK74, 1, 0);
  SetLength(R.Heat, 3);
  R.Heat[0] := HeatCell(100, 3, 0);
  R.Heat[1] := HeatCell(200, 0, 2);
  R.Heat[2] := HeatCell(300, 1, 1);
end;

{ every list sorted by its key, and every key one that exists }
function ListsSorted(const R: TPlayerMapStats): Boolean;
var
  i: LongInt;
begin
  Result := False;
  for i := 0 to High(R.Weapons) do
    if (R.Weapons[i].Slot < 0) or (R.Weapons[i].Slot >= WSLOT_COUNT) or
       ((i > 0) and (R.Weapons[i].Slot <= R.Weapons[i - 1].Slot)) then
      Exit;
  for i := 0 to High(R.Rivals) do
    if (R.Rivals[i].Id <= 0) or ((i > 0) and (R.Rivals[i].Id <= R.Rivals[i - 1].Id)) then
      Exit;
  for i := 0 to High(R.Matchups) do
    if (R.Matchups[i].Mine < 0) or (R.Matchups[i].Mine >= WSLOT_COUNT) or (R.Matchups[i].Theirs < 0) or
       (R.Matchups[i].Theirs >= WSLOT_COUNT) or ((i > 0) and (R.Matchups[i].Mine * 64 + R.Matchups[i].Theirs <=
       R.Matchups[i - 1].Mine * 64 + R.Matchups[i - 1].Theirs)) then
      Exit;
  for i := 1 to High(R.Heat) do
    if R.Heat[i].Cell <= R.Heat[i - 1].Cell then
      Exit;
  Result := True;
end;

{ ---------------- the field registry ---------------- }

function DefAt(const Defs: TFieldDefArray; Id: LongInt): LongInt;
var
  i: LongInt;
begin
  Result := -1;
  for i := 0 to High(Defs) do
    if Defs[i].Id = Id then
      Exit(i);
end;

{ the field of a registry at an offset, -1 for none }
function DefAtOffset(const Defs: TFieldDefArray; Ofs: PtrUInt): LongInt;
var
  i: LongInt;
begin
  Result := -1;
  for i := 0 to High(Defs) do
    if Defs[i].Offset = Ofs then
      Exit(i);
end;

procedure TestRegistry;
const
  { the counters of a record that follow the account's (5.5 round 3; 200-216: [Bridges], 5.6) }
  FOLLOW_IDS: array[0..83] of Word = (60, 63, 65, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 90, 91, 92, 93, 94, 95,
    96, 97, 98, 99, 100, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 113, 114, 115, 116, 121, 122, 123, 124, 125,
    126, 127, 128, 129, 130, 131, 140, 141, 142, 144, 145, 148, 150, 151, 152, 153, 155, 156, 171, 172, 173, 174, 175,
    176, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216);
  { and the ones the engine counts itself: the bests (61, 64, 112, 117, 118, 149, 217) and the counts it
    keeps by name }
  OWN_IDS: array[0..33] of Word = (61, 62, 64, 80, 81, 82, 83, 84, 85, 86, 87, 88, 101, 112, 117, 118, 119, 120, 143,
    146, 147, 149, 154, 160, 161, 162, 163, 164, 165, 166, 167, 168, 170, 217);
var
  i, j, k, p: LongInt;
  Ok, Ok2: Boolean;
  Used: array[0..217] of Boolean;
begin
  WriteLn('       SizeOf(TPlayerMapStats) = ', SizeOf(TPlayerMapStats), ', fields: ', Length(PlayerMapFields),
    ', follows: ', Length(PMFollows));
  Check('player-on-map fields: 155 in a record, 15, 8 and 4 in the entries of its lists, 3 in a map matchup',
    (Length(PlayerMapFields) = 155) and (Length(PMWeaponFields) = 15) and (Length(PMRivalFields) = 8) and
    (Length(PMMatchupFields) = 4) and (Length(MatchupCellFields) = 3));
  { the new ids, the free ones between them, and every follow a counter of the record and of the
    account alike }
  FillChar(Used, SizeOf(Used), 0);
  for i := 0 to High(FOLLOW_IDS) do
    Used[FOLLOW_IDS[i]] := True;
  for i := 0 to High(OWN_IDS) do
    Used[OWN_IDS[i]] := True;
  Ok := Length(PMFollows) = Length(FOLLOW_IDS);
  for i := 60 to 217 do
    if (DefAt(PlayerMapFields, i) >= 0) <> Used[i] then
    begin
      WriteLn('       player-on-map id ', i, ' registered: ', DefAt(PlayerMapFields, i) >= 0);
      Ok := False;
    end;
  for i := 39 to 49 do
    if DefAt(PlayerMapFields, i) >= 0 then
      Ok := False;
  Check('player-on-map ids 60-176 and 200-217 as documented (84 follow the account, 34 the engine counts), 39-49 and ' +
    '177-199 free', Ok);
  { a weapon entry: 9-15 the hits and kills measured from their bullet's origin (5.6) }
  Ok := True;
  for i := 9 to 15 do
  begin
    k := DefAt(PMWeaponFields, i);
    if (k < 0) or not PMWeaponFields[k].Stat then
      Ok := False
    else if i = 11 then
      Ok := Ok and (PMWeaponFields[k].Kind = fkSingle) and (PMWeaponFields[k].Merge = mkMax)
    else if i = 9 then
      Ok := Ok and (PMWeaponFields[k].Kind = fkDouble) and (PMWeaponFields[k].Merge = mkSum)
    else
      Ok := Ok and (PMWeaponFields[k].Kind = fkInt32) and (PMWeaponFields[k].Merge = mkSum);
  end;
  k := DefAt(PlayerMapFields, 217);
  Ok := Ok and (k >= 0) and (PlayerMapFields[k].Kind = fkSingle) and (PlayerMapFields[k].Merge = mkMax) and
    (DefAt(PMWeaponFields, 16) < 0);
  Check('a weapon entry: 9-15 the hits'' distance and air time (the longest hit the larger); 217 the record''s longest hit',
    Ok);
  Ok := True;
  Ok2 := True;
  for i := 0 to High(PMFollows) do
  begin
    k := DefAt(PlayerMapFields, PMFollows[i].Id);
    j := DefAtOffset(ProfileFields, PMFollows[i].ProfileOffset);
    if (k < 0) or (PlayerMapFields[k].Offset <> PMFollows[i].RecordOffset) or
       (PlayerMapFields[k].Kind <> PMFollows[i].Kind) or (PlayerMapFields[k].Merge <> mkSum) or
       not PlayerMapFields[k].Stat then
    begin
      WriteLn('       follow ', PMFollows[i].Id, ': not the record''s counter');
      Ok := False;
    end;
    if (j < 0) or (ProfileFields[j].Kind <> PMFollows[i].Kind) or (ProfileFields[j].Merge <> mkSum) or
       not ProfileFields[j].Stat or not (PMFollows[i].Kind in [fkInt32, fkInt64, fkDouble]) then
    begin
      WriteLn('       follow ', PMFollows[i].Id, ': not an account''s counter of the same kind');
      Ok := False;
    end;
    for p := i + 1 to High(PMFollows) do
      if (PMFollows[p].ProfileOffset = PMFollows[i].ProfileOffset) or
         (PMFollows[p].RecordOffset = PMFollows[i].RecordOffset) then
        Ok2 := False;
  end;
  Check('every follow: a counter of the record (added up, reset) and a counter of the account of the same kind', Ok);
  Check('no two follows share a counter', Ok2);
  Ok := True;
  for i := 0 to High(PlayerMapFields) do
    for j := i + 1 to High(PlayerMapFields) do
      if PlayerMapFields[i].Offset = PlayerMapFields[j].Offset then
        Ok := False;
  Check('no two ids of a record share a field', Ok);
  Ok := (PlayerMapFields[DefAt(PlayerMapFields, 61)].Merge = mkMax) and
    (PlayerMapFields[DefAt(PlayerMapFields, 64)].Merge = mkMax) and
    (PlayerMapFields[DefAt(PlayerMapFields, 112)].Merge = mkMax) and
    (PlayerMapFields[DefAt(PlayerMapFields, 118)].Merge = mkMax) and
    (PlayerMapFields[DefAt(PlayerMapFields, 117)].Merge = mkMinPos) and
    (PlayerMapFields[DefAt(PlayerMapFields, 149)].Merge = mkMinPos) and
    (PlayerMapFields[DefAt(PlayerMapFields, 82)].Offset = PtrUInt(@DummyR.KitPickups[0]) - PtrUInt(@DummyR)) and
    (PlayerMapFields[DefAt(PlayerMapFields, 88)].Offset = PtrUInt(@DummyR.KitPickups[KIT_KINDS - 1]) - PtrUInt(@DummyR));
  Check('the bests of a record merge by the larger value, the fastest times by the smaller one; kits 82-88 by kind', Ok);
  k := DefAt(PMRivalFields, 7);
  j := DefAt(PMRivalFields, 8);
  Check('a rival entry: 7 = the points won from him, 8 = the points lost to him, counters that add up',
    (k >= 0) and (j >= 0) and (PMRivalFields[k].Kind = fkInt32) and (PMRivalFields[k].Merge = mkSum) and
    PMRivalFields[k].Stat and (PMRivalFields[j].Kind = fkInt32) and (PMRivalFields[j].Merge = mkSum) and
    PMRivalFields[j].Stat and (DefAt(PMRivalFields, 9) < 0));
  Ok := True;
  for i := 260 to 280 do
    if DefAt(MapFields, i) < 0 then
      Ok := False;
  for i := 281 to 299 do
    if DefAt(MapFields, i) >= 0 then
      Ok := False;
  k := DefAt(MapFields, 260);
  Ok := Ok and (k >= 0) and (MapFields[k].Kind = fkDouble) and not MapFields[k].Stat;
  k := DefAt(MapFields, 273);
  Ok := Ok and (k >= 0) and (MapFields[k].Kind = fkMatchups) and MapFields[k].Stat;
  Check('map fields 260-280 (the load date is no statistic; 274-280 the hits'' distance and air time), 281-299 free', Ok);
  Ok := True;
  for i := 0 to WSLOT_COUNT - 1 do
    for j := 0 to 15 do
      if (DefAt(ProfileFields, 3000 + i * 16 + j) >= 0) <> (j <= 9) then
        Ok := False;
  for i := 710 to 749 do
    if DefAt(ProfileFields, i) >= 0 then
      Ok := False;
  k := DefAt(ProfileFields, 3000 + WEP_AK74 * 16 + 5);
  Ok := Ok and (k >= 0) and
    (ProfileFields[k].Offset = PtrUInt(@DummyP.Weapons[WEP_AK74].KillDistSum) - PtrUInt(@DummyP));
  Check('the weapon extras of an account at 3000 + slot * 16 + 0..9 (710-749 left free)', Ok);
end;

{ ---------------- a record written and read ---------------- }

procedure TestCodec;
var
  R, D, D2: TPlayerMapStats;
  Enc, X, E2: AnsiString;
  i, k, L: LongInt;
  Ok, Raised, Stable: Boolean;
begin
  SampleRecord(R);
  Enc := EncodePlayerMap(R);
  Ok := DecodePlayerMap(Enc, D) and (EncodePlayerMap(D) = Enc) and (D.AccountId = 42) and (D.MapName = 'ctf_Ash') and
    (D.TimePlayed = 5000000000) and (D.Points = -12) and (D.LongestKill = 87.5) and SameValue(D.FirstPlayed, 46000.5) and
    (D.RoundFirstBloods = 1) and (Length(D.Weapons) = 2) and (D.Weapons[0].Slot = WEP_AK74) and
    (D.Weapons[0].TimeUsed = 600) and SameValue(D.Weapons[0].Damage, 1800.5) and (Length(D.Rivals) = 3) and
    (D.Rivals[1].Id = 17) and (D.Rivals[1].Deaths = 5) and SameValue(D.Rivals[1].LastFight, 46001.1) and
    (D.Rivals[0].PointsWon = 88) and (D.Rivals[0].PointsLost = 21) and (D.Rivals[1].PointsWon = 0) and
    (D.Rivals[1].PointsLost = 2000000) and
    (D.Rivals[2].DamageTaken = 150) and (Length(D.Matchups) = 2) and (D.Matchups[1].Mine = WEP_BARRETT) and
    (D.Matchups[0].Losses = 2) and (Length(D.Heat) = 3) and (D.Heat[2].Deaths = 1) and ListsSorted(D);
  Check('a record with every list comes back as it was', Ok);
  ClearPlayerMap(D);
  Check('an empty record is empty and written as nothing', PlayerMapEmpty(D) and (EncodePlayerMap(D) = '') and
    DecodePlayerMap('', D2) and PlayerMapEmpty(D2));
  D.AccountId := 3;
  D.MapName := 'x';
  D.FirstPlayed := 1;
  D.LastPlayed := 2;
  Check('the key and the dates are no statistics', PlayerMapEmpty(D) and not PlayerMapEmpty(R));

  X := Enc + FInt(999, 7) + FBlob(998, 'abc');
  Check('fields a newer build added are skipped', DecodePlayerMap(X, D) and (EncodePlayerMap(D) = Enc));

  X := FInt(1, 7) + FStr(2, 'dm_X') + FInt(17, 4) +
    FBlob(51, Entries([FInt(1, 9) + FInt(2, 1), FInt(1, 4) + FInt(2, 2) + FInt(77, 123), FInt(1, 9) + FInt(2, 3),
      FInt(1, 0) + FInt(2, 5)])) +
    FBlob(50, Entries([FInt(1, 30) + FInt(2, 1), FInt(1, WEP_BARRETT) + FInt(2, 2), FInt(1, WEP_AK74) + FInt(2, 1)])) +
    FBlob(53, HeatBlob([300, 1, 0, 100, 0, 2, 300, 2, 1]));
  Ok := DecodePlayerMap(X, D) and (D.AccountId = 7) and (D.MapName = 'dm_X') and (D.Kills = 4) and
    (Length(D.Rivals) = 2) and (D.Rivals[0].Id = 4) and (D.Rivals[0].Kills = 2) and (D.Rivals[1].Id = 9) and
    (D.Rivals[1].Kills = 4) and (Length(D.Weapons) = 2) and (D.Weapons[0].Slot = WEP_AK74) and
    (D.Weapons[1].Kills = 2) and (Length(D.Heat) = 2) and (D.Heat[0].Cell = 100) and (D.Heat[0].Deaths = 2) and
    (D.Heat[1].Kills = 3) and (D.Heat[1].Deaths = 1);
  Check('lists in any order come back sorted, an entry listed twice added up, a key that is none dropped, ' +
    'an unknown field of an entry skipped', Ok);

  Raised := False;
  for L := 0 to Length(Enc) - 1 do
    try
      DecodePlayerMap(Copy(Enc, 1, L), D);
    except
      Raised := True;
    end;
  Check('every cut of a record is read without an exception', not Raised);

  RandSeed := 20260927;
  Raised := False;
  Stable := True;
  for i := 1 to 3000 do
  begin
    X := Enc;
    for k := 1 to 1 + Random(4) do
      X[1 + Random(Length(X))] := AnsiChar(Random(256));
    if Random(4) = 0 then
      Delete(X, 1 + Random(Length(X)), 1 + Random(8));
    try
      if DecodePlayerMap(X, D) then
      begin
        E2 := EncodePlayerMap(D);
        if not ListsSorted(D) or not DecodePlayerMap(E2, D2) or (EncodePlayerMap(D2) <> E2) then
          Stable := False;
      end;
    except
      Raised := True;
    end;
  end;
  Check('damaged records never raise; what they are read as is sorted and stays the same written again',
    not Raised and Stable);
  Check('a list whose count is larger than its data is refused', not DecodePlayerMap(FBlob(51, U32(1000000)), D) and
    not DecodePlayerMap(FBlob(50, U32(3)), D) and not DecodePlayerMap(FBlob(52, U32(2) + U16(0)), D));
end;

{ a value in every statistic of a record, by the place of its field in the registry (Scale times) }
procedure FillAllFields(var R: TPlayerMapStats; Scale: LongInt);
var
  i: LongInt;
  Ptr: Pointer;
begin
  for i := 0 to High(PlayerMapFields) do
  begin
    if not PlayerMapFields[i].Stat then
      Continue;
    Ptr := Pointer(PtrUInt(@R) + PlayerMapFields[i].Offset);
    case PlayerMapFields[i].Kind of
      fkInt32: PLongInt(Ptr)^ := (i + 1) * Scale;
      fkInt64: PInt64(Ptr)^ := Int64(i + 1) * Scale * 100000000;
      fkSingle: PSingle(Ptr)^ := (i + 1) * Scale + 0.5;
      fkDouble: PDouble(Ptr)^ := (i + 1) * Scale + 0.25;
    end;
  end;
end;

{ the first field of the registry in which the numbers of A and B are not Factor to 1 (1: alike) by the
  rule of the field - a best stays, a counter is Factor times -, 0 for none }
function FieldsOff(const A, B: TPlayerMapStats; Factor: LongInt): LongInt;
var
  i, F: LongInt;
  PA, PB: Pointer;
begin
  Result := 0;
  for i := 0 to High(PlayerMapFields) do
  begin
    PA := Pointer(PtrUInt(@A) + PlayerMapFields[i].Offset);
    PB := Pointer(PtrUInt(@B) + PlayerMapFields[i].Offset);
    if PlayerMapFields[i].Merge = mkSum then
      F := Factor
    else
      F := 1;
    case PlayerMapFields[i].Kind of
      fkInt32: if PLongInt(PA)^ <> Int64(PLongInt(PB)^) * F then Exit(PlayerMapFields[i].Id);
      fkInt64: if PInt64(PA)^ <> PInt64(PB)^ * F then Exit(PlayerMapFields[i].Id);
      fkSingle: if Abs(PSingle(PA)^ - PSingle(PB)^ * F) > 0.001 then Exit(PlayerMapFields[i].Id);
      fkDouble: if Abs(PDouble(PA)^ - PDouble(PB)^ * F) > 0.001 then Exit(PlayerMapFields[i].Id);
      fkString: if PAnsiString(PA)^ <> PAnsiString(PB)^ then Exit(PlayerMapFields[i].Id);
    end;
  end;
end;

{ every field of the registry, the ones of 5.5 round 3 included: written and read, added up, three ways }
procedure TestAllFields;
var
  R, D, S, C, B, Rm: TPlayerMapStats;
  Off: LongInt;
begin
  ClearPlayerMap(R);
  R.AccountId := 5;
  R.MapName := 'ctf_All';
  R.FirstPlayed := 46000;
  R.LastPlayed := 46001;
  FillAllFields(R, 3);
  Off := -1;
  if DecodePlayerMap(EncodePlayerMap(R), D) then
    Off := FieldsOff(D, R, 1);
  Check('every field of a record comes back as it was (off: ' + IntToStr(Off) + ')', Off = 0);
  ClearPlayerMap(S);
  S.AccountId := 5;
  S.MapName := 'ctf_All';
  FillAllFields(S, 3);
  MergePlayerMapInto(S, R, 0);
  Off := FieldsOff(S, R, 2);
  Check('two records added up: every counter twice, every best as it was (off: ' + IntToStr(Off) + ')', Off = 0);
  ClearPlayerMap(B);
  ClearPlayerMap(Rm);
  C := R;
  Merge3PlayerMap(C, B, Rm);
  Off := FieldsOff(C, R, 1);
  Check('three ways against an empty database: the record as it was (off: ' + IntToStr(Off) + ')', Off = 0);
  FillAllFields(Rm, 1);
  Rm.AccountId := 5;
  Rm.MapName := 'ctf_All';
  B := Rm;
  C := R;
  Merge3PlayerMap(C, B, Rm);
  Off := FieldsOff(C, R, 1);
  Check('three ways with nothing new in the database: the record as it was (off: ' + IntToStr(Off) + ')', Off = 0);
end;

{ ---------------- the new fields of maps and weapons ---------------- }

procedure TestMapFields;
var
  M, D, S, B, C, R: TMapProfile;
  Enc: AnsiString;
  i: LongInt;
  Ok: Boolean;
begin
  ClearMap(M);
  M.ID := 7;
  M.MapName := 'ctf_Ash';
  M.LastLoadedTime := 46002.5;
  for i := 1 to 4 do
  begin
    M.RoundsElimination[i] := i;
    M.KillsByTeam[i] := i * 10;
  end;
  M.RoundsLastStanding := 5;
  M.RoundsCapture := 6;
  M.RoundsNoSurvivor := 7;
  M.RoundsMapChange := 8;
  MapMatchupAdd(M, WEP_BARRETT, WEP_AK74);
  MapMatchupAdd(M, WEP_AK74, WEP_BARRETT);
  MapMatchupAdd(M, WEP_AK74, WEP_BARRETT);
  Check('the weapon matchups of a map: a cell per pair, sorted, counted', (Length(M.Matchups) = 2) and
    (M.Matchups[0].Killer = WEP_AK74) and (M.Matchups[0].Victim = WEP_BARRETT) and (M.Matchups[0].Kills = 2) and
    (M.Matchups[1].Killer = WEP_BARRETT) and (M.Matchups[1].Kills = 1));
  Enc := EncodeMap(M);
  Ok := DecodeMap(Enc, D) and (EncodeMap(D) = Enc) and (D.LastLoadedTime = 46002.5) and (D.RoundsElimination[4] = 4) and
    (D.RoundsLastStanding = 5) and (D.RoundsCapture = 6) and (D.RoundsNoSurvivor = 7) and (D.RoundsMapChange = 8) and
    (D.KillsByTeam[3] = 30) and (Length(D.Matchups) = 2) and (D.Matchups[0].Kills = 2);
  Check('the new fields of a map are saved', Ok);

  ClearMap(S);
  S.MapName := 'ctf_Ash';
  S.LastLoadedTime := 46003;
  S.RoundsCapture := 1;
  S.KillsByTeam[1] := 1;
  MapMatchupAdd(S, WEP_SOCOM, WEP_MP5);
  MapMatchupAdd(S, WEP_AK74, WEP_BARRETT);
  MergeMapInto(S, M);
  Ok := (S.RoundsCapture = 7) and (S.KillsByTeam[1] = 11) and (S.RoundsMapChange = 8) and (S.LastLoadedTime = 46003) and
    (Length(S.Matchups) = 3) and (S.Matchups[0].Killer = WEP_SOCOM) and (S.Matchups[1].Kills = 3) and
    (S.Matchups[2].Killer = WEP_BARRETT) and (M.Matchups[0].Kills = 2);
  Check('a map of two servers added up: the round ends, the kills of each team, the matchups by pair, the later load',
    Ok);

  ClearMap(B);
  B.MapName := 'ctf_Ash';
  B.RoundsCapture := 2;
  B.LastLoadedTime := 100;
  MapMatchupAdd(B, WEP_AK74, WEP_BARRETT);
  MapMatchupAdd(B, WEP_AK74, WEP_BARRETT);
  C := B;
  C.Matchups := Copy(B.Matchups);
  C.RoundsCapture := 3;
  C.LastLoadedTime := 150;
  MapMatchupAdd(C, WEP_AK74, WEP_BARRETT);
  MapMatchupAdd(C, WEP_DEAGLES, WEP_MP5);
  R := B;
  R.Matchups := Copy(B.Matchups);
  R.RoundsCapture := 4;
  R.LastLoadedTime := 120;
  MapMatchupAdd(R, WEP_AK74, WEP_BARRETT);
  MapMatchupAdd(R, WEP_BARRETT, WEP_AK74);
  Merge3Map(C, B, R);
  Ok := (C.RoundsCapture = 5) and (C.LastLoadedTime = 150) and (Length(C.Matchups) = 3) and
    (C.Matchups[0].Killer = WEP_DEAGLES) and (C.Matchups[0].Kills = 1) and (C.Matchups[1].Kills = 4) and
    (C.Matchups[2].Killer = WEP_BARRETT) and (C.Matchups[2].Kills = 1) and (B.Matchups[0].Kills = 2);
  Check('a map three ways: what both servers added to the matchups adds up', Ok);

  ResetMapStats(M);
  Check('a reset of a map clears the round ends, the kills of the teams and the matchups, and keeps the load date',
    (M.LastLoadedTime = 46002.5) and (M.RoundsCapture = 0) and (M.RoundsElimination[2] = 0) and
    (M.KillsByTeam[4] = 0) and (Length(M.Matchups) = 0));
end;

procedure TestWeaponExtras;
var
  P, Q: TPlayerProfile;
  j: LongInt;
  Ok: Boolean;
begin
  ClearProfile(P);
  P.ID := 1;
  for j := 0 to 4 do
    P.Weapons[WEP_AK74].DistBucket[j] := j + 1;
  P.Weapons[WEP_AK74].KillDistSum := 123.5;
  P.Weapons[WEP_AK74].KillDistCount := 7;
  P.Weapons[WEP_AK74].TTKSumTicks := 5000000000;
  P.Weapons[WEP_AK74].TTKCount := 9;
  P.Weapons[WEP_AK74].VestKills := 2;
  P.Weapons[WSLOT_CLUSTER].VestKills := 1;
  Ok := DecodeProfile(EncodeProfile(P), Q) and (Q.Weapons[WEP_AK74].DistBucket[4] = 5) and
    (Q.Weapons[WEP_AK74].KillDistSum = 123.5) and (Q.Weapons[WEP_AK74].KillDistCount = 7) and
    (Q.Weapons[WEP_AK74].TTKSumTicks = 5000000000) and (Q.Weapons[WEP_AK74].TTKCount = 9) and
    (Q.Weapons[WEP_AK74].VestKills = 2) and (Q.Weapons[WSLOT_CLUSTER].VestKills = 1);
  Check('the distances, times to kill and vest kills of an account''s weapons are saved', Ok);
  SumProfileCounters(Q, P);
  MergeProfileInto(Q, P, 1000);
  Check('... added up when accounts are added up or merged', (Q.Weapons[WEP_AK74].DistBucket[0] = 3) and
    (Q.Weapons[WEP_AK74].KillDistSum = 370.5) and (Q.Weapons[WEP_AK74].TTKSumTicks = 15000000000) and
    (Q.Weapons[WSLOT_CLUSTER].VestKills = 3));
  ResetProfileStats(Q);
  Check('... and reset with the statistics', (Q.Weapons[WEP_AK74].DistBucket[4] = 0) and
    (Q.Weapons[WEP_AK74].KillDistSum = 0) and (Q.Weapons[WEP_AK74].TTKCount = 0) and
    (Q.Weapons[WEP_AK74].VestKills = 0));
end;

{ ---------------- records added up, three ways, the rival list ---------------- }

procedure TestMerges;
var
  Dst, Src, B, C, R: TPlayerMapStats;
  Ok: Boolean;
begin
  ClearPlayerMap(Dst);
  Dst.AccountId := 1;
  Dst.MapName := 'ctf_Ash';
  Dst.FirstPlayed := 10;
  Dst.LastPlayed := 20;
  Dst.Kills := 1;
  Dst.BestStreak := 3;
  Dst.LongestKill := 50;
  Dst.Points := 5;
  SetLength(Dst.Weapons, 1);
  Dst.Weapons[0] := Weapon(WEP_AK74, 1, 0);
  SetLength(Dst.Rivals, 1);
  Dst.Rivals[0] := Rival(5, 1, 0, 10, 0, 20);
  Dst.Rivals[0].PointsWon := 7;
  ClearPlayerMap(Src);
  Src.AccountId := 2;
  Src.MapName := 'CTF_ASH';
  Src.FirstPlayed := 5;
  Src.LastPlayed := 30;
  Src.Kills := 2;
  Src.BestStreak := 2;
  Src.LongestKill := 70;
  Src.Points := -8;
  SetLength(Src.Weapons, 2);
  Src.Weapons[0] := Weapon(WEP_AK74, 2, 1);
  Src.Weapons[1] := Weapon(WEP_BARRETT, 1, 0);
  SetLength(Src.Rivals, 2);
  Src.Rivals[0] := Rival(5, 2, 0, 5, 0, 25);
  Src.Rivals[0].PointsWon := 9;
  Src.Rivals[0].PointsLost := 4;
  Src.Rivals[1] := Rival(6, 1, 0, 0, 0, 15);
  Src.Rivals[1].PointsLost := 3;
  SetLength(Src.Heat, 1);
  Src.Heat[0] := HeatCell(7, 1, 0);
  MergePlayerMapInto(Dst, Src, 0);
  Ok := (Dst.AccountId = 1) and (Dst.MapName = 'ctf_Ash') and (Dst.Kills = 3) and (Dst.Points = -3) and
    (Dst.BestStreak = 3) and (Dst.LongestKill = 70) and (Dst.FirstPlayed = 5) and (Dst.LastPlayed = 30) and
    (Length(Dst.Weapons) = 2) and (Dst.Weapons[0].Kills = 3) and (Dst.Weapons[0].Deaths = 1) and
    (Dst.Weapons[1].Slot = WEP_BARRETT) and (Length(Dst.Rivals) = 2) and (Dst.Rivals[0].Kills = 3) and
    (Dst.Rivals[0].LastFight = 25) and (Abs(Dst.Rivals[0].DamageDealt - 15) < 0.001) and (Dst.Rivals[1].Id = 6) and
    (Dst.Rivals[0].PointsWon = 16) and (Dst.Rivals[0].PointsLost = 4) and (Dst.Rivals[1].PointsLost = 3) and
    (Length(Dst.Heat) = 1) and (Src.Weapons[0].Kills = 2) and (Src.Rivals[0].PointsWon = 9);
  Check('two records added up: counters, bests and dates by their rule, the lists entry by entry (the points of ' +
    'a rival too); the keys stay the target''s and the source is left as it was', Ok);
  MergePlayerMapInto(Dst, Src, 1);
  Check('... and cut to MaxRivals, the weakest going', (Length(Dst.Rivals) = 1) and (Dst.Rivals[0].Id = 5) and
    (Dst.Rivals[0].Kills = 5));

  ClearPlayerMap(B);
  B.AccountId := 9;
  B.MapName := 'm';
  B.Kills := 10;
  B.Points := 5;
  B.FirstPlayed := 100;
  B.LastPlayed := 110;
  SetLength(B.Weapons, 2);
  B.Weapons[0] := Weapon(WEP_AK74, 5, 0);
  B.Weapons[1] := Weapon(WEP_MINIGUN, 1, 0);
  SetLength(B.Rivals, 1);
  B.Rivals[0] := RivalPts(5, 2, 0, 20, 5, 10);
  SetLength(B.Heat, 1);
  B.Heat[0] := HeatCell(100, 1, 0);
  { this server: two kills more, points lost, the Minigun entry gone (a reset), a new rival }
  C := B;
  C.Kills := 12;
  C.Points := 2;
  C.LastPlayed := 120;
  C.Weapons := nil;
  SetLength(C.Weapons, 2);
  C.Weapons[0] := Weapon(WEP_AK74, 6, 0);
  C.Weapons[1] := Weapon(WEP_BARRETT, 1, 0);
  C.Rivals := nil;
  SetLength(C.Rivals, 2);
  C.Rivals[0] := RivalPts(5, 2, 0, 30, 5, 11);
  C.Rivals[1] := RivalPts(7, 0, 1, 0, 9, 12);
  C.Heat := nil;
  SetLength(C.Heat, 1);
  C.Heat[0] := HeatCell(100, 2, 0);
  { the database: another server added a kill and points, played earlier, fought rival 5 again }
  R := B;
  R.Kills := 11;
  R.Points := 9;
  R.FirstPlayed := 90;
  R.LastPlayed := 115;
  R.Weapons := nil;
  SetLength(R.Weapons, 2);
  R.Weapons[0] := Weapon(WEP_AK74, 7, 0);
  R.Weapons[1] := Weapon(WEP_MINIGUN, 1, 0);
  R.Rivals := nil;
  SetLength(R.Rivals, 1);
  R.Rivals[0] := RivalPts(5, 3, 0, 26, 8, 15);
  R.Heat := nil;
  SetLength(R.Heat, 2);
  R.Heat[0] := HeatCell(100, 1, 0);
  R.Heat[1] := HeatCell(200, 0, 1);
  Merge3PlayerMap(C, B, R);
  Ok := (C.AccountId = 9) and (C.MapName = 'm') and (C.Kills = 13) and (C.Points = 6) and (C.FirstPlayed = 90) and
    (C.LastPlayed = 120) and (Length(C.Weapons) = 2) and (C.Weapons[0].Kills = 8) and
    (C.Weapons[1].Slot = WEP_BARRETT) and (Length(C.Rivals) = 2) and (C.Rivals[0].Kills = 3) and
    (C.Rivals[0].LastFight = 15) and (C.Rivals[1].Id = 7) and (C.Rivals[1].Deaths = 1) and (Length(C.Heat) = 2) and
    (C.Heat[0].Kills = 2) and (C.Heat[1].Deaths = 1) and (Length(B.Weapons) = 2) and (B.Weapons[1].Kills = 1);
  Check('three ways: this server''s changes on top of the database''s, entry by entry; an entry reset here ' +
    'takes its part out', Ok);
  Check('three ways: the points won from a rival and lost to him add up as the kills do',
    (Length(C.Rivals) = 2) and (C.Rivals[0].PointsWon = 36) and (C.Rivals[0].PointsLost = 8) and
    (C.Rivals[1].PointsWon = 0) and (C.Rivals[1].PointsLost = 9));

  { a reset here: the database's counts lose what this server had sent, never below 0; the points
    of a map may be below 0 }
  ClearPlayerMap(C);
  C.AccountId := 9;
  C.MapName := 'm';
  R := B;
  R.Kills := 4;
  R.Points := 3;
  R.Weapons := nil;
  SetLength(R.Weapons, 2);
  R.Weapons[0] := Weapon(WEP_AK74, 7, 0);
  R.Weapons[1] := Weapon(WEP_MINIGUN, 1, 0);
  Merge3PlayerMap(C, B, R);
  Check('a reset here takes the base out of the database''s counts, never below 0; the points may go below',
    (C.Kills = 0) and (C.Points = -2) and (Length(C.Weapons) = 1) and (C.Weapons[0].Kills = 2) and
    (Length(C.Rivals) = 0));
end;

procedure TestRivalCap;
var
  R: TPlayerMapStats;
  Rv: PPMRival;
  A: TPMRivalArray;
  i, p: LongInt;
  Ok: Boolean;
begin
  ClearPlayerMap(R);
  for i := 1 to 5 do
  begin
    Rv := PMRivalOf(R, i, 3);
    Inc(Rv^.Kills, i);
    Rv^.LastFight := i;
  end;
  Check('a full rival list makes room for a new rival by dropping the one with the fewest fights',
    (Length(R.Rivals) = 3) and (R.Rivals[0].Id = 3) and (R.Rivals[2].Id = 5) and (R.Rivals[2].Kills = 5));
  ClearPlayerMap(R);
  SetLength(R.Rivals, 3);
  R.Rivals[0] := Rival(10, 1, 0, 0, 0, 5);
  R.Rivals[1] := Rival(11, 0, 1, 0, 0, 3);
  R.Rivals[2] := Rival(12, 2, 0, 0, 0, 1);
  PMRivalOf(R, 13, 3);
  Ok := (Length(R.Rivals) = 3) and (RivalAt(R, 11) < 0) and (RivalAt(R, 10) >= 0) and (RivalAt(R, 13) >= 0);
  PMRivalOf(R, 12, 3);
  Check('of two with as few fights the one fought longest ago goes; a rival already there pushes nobody out',
    Ok and (Length(R.Rivals) = 3) and (RivalAt(R, 10) >= 0));
  SetLength(A, 5);
  A[0] := Rival(1, 5, 0, 0, 0, 1);
  A[1] := Rival(2, 1, 0, 0, 0, 2);
  A[2] := Rival(3, 4, 0, 0, 0, 3);
  A[3] := Rival(4, 2, 0, 0, 0, 4);
  A[4] := Rival(5, 3, 0, 0, 0, 5);
  PMTrimRivals(A, 2);
  Ok := (Length(A) = 2) and (A[0].Id = 1) and (A[1].Id = 3);
  PMTrimRivals(A, 0);
  Ok := Ok and (Length(A) = 2);
  A := nil;
  Check('many at once: the strongest stay in their order; 0 is no limit', Ok and (PMWeakestRival(A) = -1));

  ClearPlayerMap(R);
  for i := 0 to PM_MAX_HEAT + 9 do
    PMHeatAdd(R, (i - 1024) * PM_HEAT_CELL_PX + 1, 1, True);
  PMHeatAdd(R, 1, 1, False);
  Ok := (Length(R.Heat) = PM_MAX_HEAT) and ListsSorted(R) and HeatCellPos(R.Heat, 2048 * 4096 + 2048, p) and
    (R.Heat[p].Kills = 1) and (R.Heat[p].Deaths = 1);
  Check('a record keeps PM_MAX_HEAT heat cells at most, and the cells it has go on counting', Ok);
end;

{ ---------------- the store ---------------- }

procedure MakeRec(out R: TPlayerMapStats; Id: LongInt; const Map: AnsiString; Kills: LongInt);
begin
  ClearPlayerMap(R);
  R.AccountId := Id;
  R.MapName := Map;
  R.FirstPlayed := 46000;
  R.LastPlayed := 46001;
  R.Kills := Kills;
end;

function FindIn(const St: TStoreState; Id: LongInt; const Map: AnsiString): PPlayerMapStats;
var
  i: LongInt;
begin
  Result := nil;
  for i := 0 to St.PlayerMapCount - 1 do
    if (St.PlayerMaps[i] <> nil) and (St.PlayerMaps[i]^.AccountId = Id) and SameText(St.PlayerMaps[i]^.MapName, Map) then
      Exit(St.PlayerMaps[i]);
end;

procedure TestStore(const Dir: AnsiString);
var
  L: TStoreState;
  Info: TStoreLoadInfo;
  IO: TStoreIO;
  W: TStoreWriter;
  A1, B1, C1, C2, D1, Bad: TPlayerMapStats;
  P1, P2: TPlayerProfile;
  M: TMapProfile;
  Srv: TServerRecords;
  R: PPlayerMapStats;
  Ok: Boolean;
begin
  CleanDir(Dir);
  ClearProfile(P1);
  P1.ID := 1;
  P1.ActiveName := 'One';
  ClearProfile(P2);
  P2.ID := 2;
  P2.ActiveName := 'Two';
  ClearMap(M);
  M.ID := 1;
  M.MapName := 'ctf_Ash';
  M.RoundsCapture := 3;
  M.LastLoadedTime := 46000;
  MapMatchupAdd(M, WEP_AK74, WEP_BARRETT);
  ClearServer(Srv);
  Srv.NextProfileID := 3;
  Srv.NextMapID := 2;
  MakeRec(A1, 1, 'ctf_Ash', 5);
  SetLength(A1.Rivals, 1);
  A1.Rivals[0] := Rival(2, 5, 0, 100, 0, 46000);
  MakeRec(B1, 2, 'ctf_Ash', 0);
  B1.Deaths := 5;
  MakeRec(C1, 1, 'dm_Z', 1);

  IO := TStoreIO.Create(Dir, SNAP, JOUR);
  W := TStoreWriter.Create(IO, 0);
  W.BeginSnapshot(2, 1, 0);
  W.SnapshotServer(Srv);
  W.SnapshotMap(M);
  W.SnapshotProfile(P1);
  W.SnapshotProfile(P2);
  W.SnapshotPlayerMap(A1);
  W.SnapshotPlayerMap(B1);
  W.SnapshotPlayerMap(C1);
  W.CommitSnapshot(1, '');
  Ok := WaitCommit(IO, 1);
  { the journal: a change, a removal named in another case, a new record, a record removed and made
    again, and one of no account }
  A1.Kills := 8;
  W.JournalPlayerMap(A1);
  W.JournalDeletePlayerMap(2, 'CTF_ASH');
  MakeRec(D1, 2, 'dm_Z', 2);
  W.JournalPlayerMap(D1);
  W.JournalDeletePlayerMap(1, 'dm_Z');
  MakeRec(C2, 1, 'dm_Z', 9);
  W.JournalPlayerMap(C2);
  MakeRec(Bad, 0, 'dm_Z', 1);
  W.JournalPlayerMap(Bad);
  W.Flush;
  Ok := Ok and WaitIdle(IO);
  W.Free;
  IO.Free;

  Ok := Ok and (StoreLoad(Dir, SNAP, JOUR, L, Info) = slLoaded) and (L.PlayerMapCount = 3);
  R := FindIn(L, 1, 'ctf_ash');
  Ok := Ok and (R <> nil) and (R^.Kills = 8) and (Length(R^.Rivals) = 1) and (R^.Rivals[0].Id = 2) and
    (R^.Rivals[0].Kills = 5);
  Ok := Ok and (FindIn(L, 2, 'ctf_Ash') = nil);
  R := FindIn(L, 2, 'dm_Z');
  Ok := Ok and (R <> nil) and (R^.Kills = 2);
  R := FindIn(L, 1, 'dm_Z');
  Ok := Ok and (R <> nil) and (R^.Kills = 9);
  Check('player-on-map records in the store: the snapshot, then a change, a removal (any case), a new record ' +
    'and one removed and made again from the journal', Ok);
  Check('a record of no account is refused', Info.BadRecords = 1);
  Check('the store keeps the new fields of a map', (L.MapCount = 1) and (L.Maps[0].RoundsCapture = 3) and
    (Length(L.Maps[0].Matchups) = 1) and (L.Maps[0].LastLoadedTime = 46000));
  ClearStoreState(L);
end;

{ ---------------- through TStatsDB ---------------- }

function AddRec(DB: TStatsDB; Id: LongInt; const Map: AnsiString): PPlayerMapStats;
var
  Place: LongInt;
begin
  Place := DB.PM.Obtain(Id, DB.PM.MapNumber(Map, True), DB.NowValue);
  Result := DB.PM.Items[Place];
  DB.PM.Touch(Place);
end;

procedure AddRival(R: PPlayerMapStats; Id, Kills, Deaths: LongInt);
var
  Rv: PPMRival;
begin
  Rv := PMRivalOf(R^, Id, 0);
  Inc(Rv^.Kills, Kills);
  Inc(Rv^.Deaths, Deaths);
  Rv^.LastFight := 46000 + Id;
end;

{ the points won from a rival and lost to him }
procedure AddRivalPoints(R: PPlayerMapStats; Id, Won, Lost: LongInt);
var
  Rv: PPMRival;
begin
  Rv := PMRivalOf(R^, Id, 0);
  Inc(Rv^.PointsWon, Won);
  Inc(Rv^.PointsLost, Lost);
end;

{ an entry of a record: 'kills/deaths won/lost', '-' when there is none }
function RivalText(R: PPlayerMapStats; Id: LongInt): AnsiString;
var
  p: LongInt;
begin
  if (R = nil) or not PMRivalPos(R^.Rivals, Id, p) then
    Exit('-');
  Result := Format('%d/%d %d/%d', [R^.Rivals[p].Kills, R^.Rivals[p].Deaths, R^.Rivals[p].PointsWon,
    R^.Rivals[p].PointsLost]);
end;

function PlaceOf(DB: TStatsDB; Id: LongInt; const Map: AnsiString): LongInt;
begin
  Result := DB.PM.FindNo(Id, DB.PM.MapNumber(Map, False));
end;

procedure TestDatabase(const Dir: AnsiString);
var
  DB, DB2: TStatsDB;
  R: PPlayerMapStats;
  S: TPlayerMapStats;
  Pairs: TPMPairArray;
  IO: TStoreIO;
  W: TStoreWriter;
  St: TStoreState;
  Info: TStoreLoadInfo;
  i, n: LongInt;
  Ok: Boolean;
begin
  DB := TStatsDB.Create;
  DB.SetNow(EncodeDate(2026, 9, 20));
  for i := 1 to 5 do
    DB.CreateProfile('Map' + IntToStr(i), 'S' + IntToStr(3000 + i), 'HWM' + IntToStr(i), '10.3.0.' + IntToStr(i), 1000);
  { the points: account 2 at MinimumPoints lost less to 1 than 1 won from it }
  R := AddRec(DB, 1, 'ctf_A');
  R^.Kills := 5;
  AddRival(R, 2, 3, 0);
  AddRivalPoints(R, 2, 30, 0);
  AddRival(R, 3, 1, 0);
  AddRivalPoints(R, 3, 7, 0);
  R := AddRec(DB, 2, 'ctf_A');
  R^.Kills := 2;
  R^.Deaths := 3;
  AddRival(R, 1, 0, 3);
  AddRivalPoints(R, 1, 0, 27);
  AddRival(R, 3, 1, 0);
  AddRivalPoints(R, 3, 5, 0);
  R := AddRec(DB, 3, 'ctf_A');
  R^.Deaths := 2;
  AddRival(R, 1, 0, 1);
  AddRivalPoints(R, 1, 0, 7);
  AddRival(R, 2, 0, 1);
  AddRivalPoints(R, 2, 0, 5);
  R := AddRec(DB, 2, 'ctf_B');
  R^.Kills := 1;
  AddRival(R, 4, 1, 0);
  R := AddRec(DB, 4, 'ctf_B');
  R^.Deaths := 1;
  AddRival(R, 2, 0, 1);
  { 5 killed 1, whose entry of 5 is gone (MaxRivals): the pair takes 5's side turned round }
  R := AddRec(DB, 5, 'ctf_A');
  R^.Kills := 1;
  AddRival(R, 1, 1, 0);
  AddRivalPoints(R, 1, 12, 0);
  Check('records found by account and map name in any case, by account and by map', (DB.PM.Count = 6) and
    (DB.PM.Find(1, 'CTF_a') <> nil) and (DB.PM.Find(1, 'ctf_B') = nil) and (Length(DB.PM.OfAccount(2)) = 2) and
    (Length(DB.PM.OfMap('ctf_a')) = 4) and (Length(DB.PM.OfMap('nope')) = 0));
  DB.PM.SumAccount(2, S);
  Check('an account over all its maps', (S.Kills = 3) and (S.Deaths = 3) and (Length(S.Rivals) = 3) and
    (S.Rivals[0].Id = 1) and (S.Rivals[0].Deaths = 3) and (S.MapName = '') and (S.AccountId = 2));
  DB.PM.SumMap('CTF_A', S);
  Check('a map over all its accounts, without the rivals', (S.Kills = 8) and (S.Deaths = 5) and
    (Length(S.Rivals) = 0) and (S.MapName = 'ctf_A'));
  Pairs := DB.PM.MapPairs('ctf_A');
  Check('the pairs of a map: each once from both sides, the most fights first', (Length(Pairs) = 4) and
    (Pairs[0].A = 1) and (Pairs[0].B = 2) and (Pairs[0].AKills = 3) and (Pairs[0].BKills = 0) and (Pairs[3].A = 1) and
    (Pairs[3].B = 5) and (Pairs[3].AKills = 0) and (Pairs[3].BKills = 1));
  Check('the pairs of a map: the points of each side from its own entry, a side without one the other''s turned round',
    (Length(Pairs) = 4) and (Pairs[0].AWon = 30) and (Pairs[0].ALost = 0) and (Pairs[0].BWon = 0) and
    (Pairs[0].BLost = 27) and (Pairs[3].AWon = 0) and (Pairs[3].ALost = 12) and (Pairs[3].BWon = 12) and
    (Pairs[3].BLost = 0));

  { account 2 goes into account 1 }
  DB.MergeProfile(DB.IndexOfId(1), DB.IndexOfId(2), 1000);
  R := DB.PM.Find(1, 'ctf_A');
  Ok := (R <> nil) and (R^.Kills = 7) and (R^.Deaths = 3) and (Length(R^.Rivals) = 1) and (RivalAt(R^, 3) >= 0) and
    (R^.Rivals[RivalAt(R^, 3)].Kills = 2) and (RivalText(R, 3) = '2/0 12/0');
  R := DB.PM.Find(1, 'ctf_B');
  Ok := Ok and (R <> nil) and (R^.Kills = 1) and (RivalAt(R^, 4) >= 0);
  Ok := Ok and (DB.PM.Find(2, 'ctf_A') = nil) and (DB.PM.Find(2, 'ctf_B') = nil) and (DB.PM.Count = 5);
  Check('a merge adds the records map by map, the points of the rivals too; the fights of the two with each other ' +
    'go', Ok);
  R := DB.PM.Find(3, 'ctf_A');
  Ok := (R <> nil) and (Length(R^.Rivals) = 1) and (R^.Rivals[0].Id = 1) and (R^.Rivals[0].Deaths = 2) and
    (RivalText(R, 1) = '0/2 0/12');
  R := DB.PM.Find(4, 'ctf_B');
  Ok := Ok and (R <> nil) and (Length(R^.Rivals) = 1) and (R^.Rivals[0].Id = 1);
  Check('every rival entry that named the merged account names the account it went into', Ok);

  DB.DeleteProfile(DB.IndexOfId(3));
  R := DB.PM.Find(1, 'ctf_A');
  Check('a removed account takes its records and the rival entries naming it along',
    (DB.PM.Find(3, 'ctf_A') = nil) and (R <> nil) and (Length(R^.Rivals) = 0) and (R^.Kills = 7));
  DB.BeginBulkDelete;
  DB.DeleteProfile(DB.IndexOfId(4));
  Ok := (DB.PM.Find(4, 'ctf_B') = nil) and (DB.PM.Find(1, 'ctf_B') <> nil) and (RivalAt(DB.PM.Find(1, 'ctf_B')^, 4) >= 0);
  DB.EndBulkDelete;
  Check('many removed at once: the rival entries go at the end', Ok and (RivalAt(DB.PM.Find(1, 'ctf_B')^, 4) < 0));

  DB.ChangeProfileId(DB.IndexOfId(1), 50);
  R := DB.PM.Find(50, 'ctf_A');
  Ok := (DB.PM.Find(1, 'ctf_A') = nil) and (R <> nil) and (R^.Kills = 7) and (DB.PM.Find(50, 'ctf_B') <> nil);
  R := DB.PM.Find(5, 'ctf_A');
  Ok := Ok and (R <> nil) and (RivalAt(R^, 50) >= 0) and (RivalAt(R^, 1) < 0);
  Check('an account with a new number takes its records and the rival entries naming it along', Ok);

  DB.Profiles[DB.IndexOfId(5)]^.LastPlayedTime := DB.NowValue - 100;
  DB.Profiles[DB.IndexOfId(50)]^.LastPlayedTime := DB.NowValue - 1;
  n := DB.PrunePlayerMaps(90, 0);
  Check('MatrixPruneDays: the records of an account that has not played for so many days go', (n = 1) and
    (DB.PM.Find(5, 'ctf_A') = nil) and (DB.PM.Find(50, 'ctf_A') <> nil) and (DB.PrunePlayerMaps(0, 0) = 0));

  DB.Profiles[DB.IndexOfId(5)]^.LastPlayedTime := DB.NowValue;
  R := AddRec(DB, 5, 'ctf_B');
  AddRival(R, 50, 1, 0);
  DB.PM.RemoveRecordsOf(50);
  R := DB.PM.Find(5, 'ctf_B');
  Check('a reset of an account removes its records; entries naming it are the others'' statistics and stay',
    (DB.PM.Find(50, 'ctf_A') = nil) and (DB.PM.Find(50, 'ctf_B') = nil) and (R <> nil) and (RivalAt(R^, 50) >= 0));
  AddRec(DB, 50, 'ctf_A')^.Kills := 1;
  DB.PM.RemoveMap('CTF_b');
  Check('a reset of a map removes its records', (DB.PM.Find(5, 'ctf_B') = nil) and (DB.PM.Find(50, 'ctf_A') <> nil));
  DB.PM.RemoveAll;
  Check('a reset of everything removes every record', DB.PM.Count = 0);

  { saved through TStatsDB: a snapshot in pieces, the journal after it }
  R := AddRec(DB, 50, 'ctf_A');
  R^.Kills := 1;
  AddRival(R, 5, 1, 0);
  AddRec(DB, 5, 'ctf_A')^.Kills := 2;
  AddRec(DB, 5, 'dm_B')^.Kills := 3;
  AddRec(DB, 999, 'ctf_A')^.Kills := 4;
  CleanDir(Dir);
  IO := TStoreIO.Create(Dir, SNAP, JOUR);
  W := TStoreWriter.Create(IO, 0);
  DB.BeginSnapshot(W);
  n := 0;
  while not DB.ContinueSnapshot(W, 2) do
    Inc(n);
  W.CommitSnapshot(1, '');
  Ok := WaitCommit(IO, 1) and (n >= 2);
  DB.PM.Find(50, 'ctf_A')^.Kills := 11;
  DB.PM.Touch(PlaceOf(DB, 50, 'ctf_A'));
  DB.PM.Remove(PlaceOf(DB, 5, 'dm_B'));
  AddRec(DB, 5, 'dm_C')^.Kills := 6;
  DB.FlushJournal(W, True);
  Ok := Ok and WaitIdle(IO);
  W.Free;
  IO.Free;
  DB2 := TStatsDB.Create;
  Ok := Ok and (StoreLoad(Dir, SNAP, JOUR, St, Info) = slLoaded);
  DB2.TakeState(St);
  R := DB2.PM.Find(50, 'ctf_A');
  Ok := Ok and (DB2.PM.Count = 3) and (R <> nil) and (R^.Kills = 11) and (RivalAt(R^, 5) >= 0) and
    (DB2.PM.Find(5, 'ctf_A') <> nil) and (DB2.PM.Find(5, 'ctf_A')^.Kills = 2) and (DB2.PM.Find(5, 'dm_B') = nil) and
    (DB2.PM.Find(5, 'dm_C') <> nil) and (DB2.PM.Find(999, 'ctf_A') = nil);
  Check('saved through TStatsDB: the snapshot in pieces and the journal after it; a record of no account is ' +
    'dropped when read', Ok);
  DB2.Free;
  DB.Free;
end;

{ ---------------- a large table ---------------- }

type
  { when the accounts of the stress test played last: the even ones today, the odd ones long ago }
  TLastPlayed = class
    function LastPlayed(AccountId: LongInt): Double;
  end;

function TLastPlayed.LastPlayed(AccountId: LongInt): Double;
begin
  if AccountId mod 2 = 0 then
    Result := 1000
  else
    Result := 1;
end;

{ every record is found by its key, and the lists of the maps and accounts hold exactly the live
  records, each at the place it keeps }
function TableConsistent(T: TPlayerMapTable): Boolean;
var
  i, k, Live, Listed: LongInt;
  R: PPlayerMapStats;
  L: TPMRefArray;
begin
  Result := False;
  Live := 0;
  for i := 0 to T.Places - 1 do
  begin
    R := T.Items[i];
    if R = nil then
      Continue;
    Inc(Live);
    if T.Find(R^.AccountId, R^.MapName) <> R then
      Exit;
  end;
  if Live <> T.Count then
    Exit;
  { a list with a removed record in it would put the ones after it off their places }
  Listed := 0;
  for i := 0 to 9 do
  begin
    L := T.OfMap('map' + IntToStr(i));
    for k := 0 to High(L) do
      if (L[k]^.MapPos <> k) or not SameText(L[k]^.MapName, 'map' + IntToStr(i)) then
        Exit;
    Inc(Listed, Length(L));
  end;
  if Listed <> Live then
    Exit;
  Listed := 0;
  for i := 1 to 4000 do
  begin
    L := T.OfAccount(i);
    for k := 0 to High(L) do
      if (L[k]^.AccPos <> k) or (L[k]^.AccountId <> i) then
        Exit;
    Inc(Listed, Length(L));
  end;
  Result := Listed = Live;
end;

procedure TestTableStress;
var
  T: TPlayerMapTable;
  LP: TLastPlayed;
  i, Place, n: LongInt;
  Ok: Boolean;
  T0: Int64;
begin
  T := TPlayerMapTable.Create;
  LP := TLastPlayed.Create;
  try
    RandSeed := 77;
    T0 := MonoMs;
    { every record played on today (1000): the prune goes by the accounts }
    for i := 1 to 20000 do
    begin
      Place := T.Obtain(1 + Random(4000), T.MapNumber('map' + IntToStr(Random(10)), True), 1000);
      Inc(T.Items[Place]^.Kills);
    end;
    Ok := TableConsistent(T);
    for i := 1 to 3000 do
    begin
      Place := Random(T.Places);
      if T.Items[Place] <> nil then
        T.Remove(Place);
    end;
    Ok := Ok and TableConsistent(T);
    T.RemoveMap('MAP3');
    Ok := Ok and (Length(T.OfMap('map3')) = 0) and TableConsistent(T);
    for i := 1 to 2000 do
    begin
      Place := T.Obtain(1 + Random(4000), T.MapNumber('map' + IntToStr(Random(10)), True), 1000);
      Inc(T.Items[Place]^.Deaths);
    end;
    Ok := Ok and TableConsistent(T);
    n := T.Count;
    Ok := Ok and (T.Prune(90, 0, 1000, @LP.LastPlayed) > 0) and (T.Count < n) and TableConsistent(T);
    for i := 0 to T.Places - 1 do
      if (T.Items[i] <> nil) and (T.Items[i]^.AccountId mod 2 <> 0) then
        Ok := False;
    T.RemoveRecordsOf(2);
    Ok := Ok and (Length(T.OfAccount(2)) = 0) and TableConsistent(T);
    WriteLn(Format('       22000 records made, removed one by one, by map, by prune: %d ms', [MonoMs - T0]));
    Check('a large table stays consistent through removals one by one and many at once', Ok);
    T.RemoveAll;
    Check('... and empties', (T.Count = 0) and TableConsistent(T));
  finally
    LP.Free;
    T.Free;
  end;
end;

{ ---------------- the shared database's bookkeeping ---------------- }

procedure TestSync;
var
  DB: TStatsDB;
  R, R1, R5, R6, R7, R8: PPlayerMapStats;
  Marked: TIntArray;
  Gone: TPMGoneArray;
  B: TPlayerMapStats;
  i: LongInt;
  Ok: Boolean;

  procedure ClearMarks;
  var
    k: LongInt;
  begin
    DB.PM.TakeSyncWork(Marked, Gone);
    for k := 0 to High(Marked) do
      if DB.PM.Items[Marked[k]] <> nil then
        DB.PM.Items[Marked[k]]^.SyncDirty := False;
  end;

begin
  DB := TStatsDB.Create;
  DB.SetNow(EncodeDate(2026, 9, 20));
  for i := 1 to 8 do
    DB.CreateProfile('Sync' + IntToStr(i), 'S' + IntToStr(4000 + i), 'HWS' + IntToStr(i), '10.4.0.' + IntToStr(i), 1000);
  DB.SyncOn := True;
  R := AddRec(DB, 1, 'm');
  R^.Kills := 1;
  Check('a change made here waits for the exchange', R^.SyncDirty and (Length(DB.PM.SyncPending) = 1));
  ClearMarks;
  DB.BeginRemote;
  DB.PM.Touch(PlaceOf(DB, 1, 'm'));
  DB.EndRemote;
  Check('a change the shared database brought is not sent back', not R^.SyncDirty and (Length(DB.PM.SyncPending) = 0));

  R := AddRec(DB, 2, 'm');
  R^.Kills := 2;
  R^.SyncBase := EncodePlayerMap(R^);
  R := AddRec(DB, 3, 'm');
  R^.Kills := 3;
  R^.SyncBase := EncodePlayerMap(R^);
  R := AddRec(DB, 4, 'm');
  R^.Kills := 4;
  ClearMarks;
  DB.BeginRemote;
  DB.PM.Remove(PlaceOf(DB, 2, 'm'));
  DB.EndRemote;
  DB.PM.Remove(PlaceOf(DB, 3, 'm'));
  DB.PM.Remove(PlaceOf(DB, 4, 'm'));
  Gone := DB.PM.GonePending;
  Check('a removal made here goes to the database from the state it had there; one the database brought, or of a ' +
    'record it never had, does not', (Length(Gone) = 1) and (Gone[0].AccountId = 3) and
    DecodePlayerMap(Gone[0].Base, B) and (B.Kills = 3));
  Ok := DB.PM.UpdateGone(3, 'M', 'x') and (DB.PM.GonePending[0].Base = 'x') and not DB.PM.UpdateGone(9, 'm', '');
  DB.PM.RequeueGone(Gone);
  Check('a waiting removal takes the newest base, and the same removal waits once', Ok and
    (Length(DB.PM.GonePending) = 1) and (DB.PM.GonePending[0].Base = Gone[0].Base));
  ClearMarks;

  { a merge the database made: the bases are merged the same way, nothing is sent back }
  R5 := AddRec(DB, 5, 'm');
  R5^.Kills := 2;
  AddRival(R5, 1, 1, 0);
  AddRivalPoints(R5, 1, 10, 0);
  R6 := AddRec(DB, 6, 'm');
  R6^.Kills := 3;
  AddRival(R6, 1, 2, 0);
  AddRivalPoints(R6, 1, 20, 0);
  R1 := DB.PM.Find(1, 'm');
  AddRival(R1, 5, 0, 1);
  AddRivalPoints(R1, 5, 0, 10);
  AddRival(R1, 6, 0, 2);
  AddRivalPoints(R1, 6, 0, 20);
  R1^.SyncBase := EncodePlayerMap(R1^);
  R5^.SyncBase := EncodePlayerMap(R5^);
  R6^.SyncBase := EncodePlayerMap(R6^);
  ClearMarks;
  DB.BeginRemote;
  DB.MergeProfile(DB.IndexOfId(5), DB.IndexOfId(6), 1000);
  DB.EndRemote;
  R5 := DB.PM.Find(5, 'm');
  Ok := (R5 <> nil) and (R5^.Kills = 5) and (Length(R5^.Rivals) = 1) and (R5^.Rivals[0].Kills = 3) and
    (EncodePlayerMap(R5^) = R5^.SyncBase) and R5^.SyncDirty and (DB.PM.Find(6, 'm') = nil);
  Ok := Ok and (Length(R1^.Rivals) = 1) and (R1^.Rivals[0].Id = 5) and (R1^.Rivals[0].Deaths = 3) and
    (EncodePlayerMap(R1^) = R1^.SyncBase) and not R1^.SyncDirty and (Length(DB.PM.GonePending) = 0);
  Ok := Ok and (RivalText(R5, 1) = '3/0 30/0') and (RivalText(R1, 5) = '0/3 0/30');
  Check('a merge the shared database made: the bases are merged and renumbered alike, the points of the rivals ' +
    'with them; nothing goes back but what this server added', Ok);

  { a new account of this server the database put into one this server has, during the exchange:
    that is this server's change and goes to the database }
  R7 := AddRec(DB, 7, 'm');
  R7^.Kills := 7;
  R8 := AddRec(DB, 8, 'm');
  R8^.Kills := 8;
  R8^.SyncBase := EncodePlayerMap(R8^);
  ClearMarks;
  DB.BeginRemote;
  DB.PM.MergeAccount(7, 8, False);
  DB.EndRemote;
  R8 := DB.PM.Find(8, 'm');
  Check('a merge of this server during the exchange is marked for it, the base stays',
    (R8 <> nil) and (R8^.Kills = 15) and R8^.SyncDirty and DecodePlayerMap(R8^.SyncBase, B) and (B.Kills = 8) and
    (DB.PM.Find(7, 'm') = nil) and (Length(DB.PM.GonePending) = 0));

  { the database gives a new account of this server another number during the exchange }
  R := AddRec(DB, 3, 'n');
  R^.Kills := 1;
  R^.SyncBase := EncodePlayerMap(R^);
  R := AddRec(DB, 2, 'n');
  AddRival(R, 3, 1, 0);
  R^.SyncBase := EncodePlayerMap(R^);
  ClearMarks;
  DB.BeginRemote;
  DB.ChangeProfileId(DB.IndexOfId(3), 30);
  DB.EndRemote;
  R := DB.PM.Find(30, 'n');
  Ok := (R <> nil) and (R^.Kills = 1) and (R^.SyncBase = '') and R^.SyncDirty and (DB.PM.Find(3, 'n') = nil);
  Gone := DB.PM.GonePending;
  Ok := Ok and (Length(Gone) = 1) and (Gone[0].AccountId = 3) and SameText(Gone[0].MapName, 'n');
  R := DB.PM.Find(2, 'n');
  Ok := Ok and (R <> nil) and (RivalAt(R^, 30) >= 0) and (RivalAt(R^, 3) < 0) and R^.SyncDirty;
  Check('a new number from the database: the records are new there under it and the old ones go; the entries ' +
    'naming it follow as a change of this server', Ok);

  DB.SyncOn := False;
  ClearMarks;
  R := AddRec(DB, 1, 'q');
  Check('without a shared database nothing is marked', not R^.SyncDirty and (Length(DB.PM.SyncPending) = 0));
  DB.PM.SetBasesFromRecords;
  Check('a start without the database: what the files hold counts as the database''s',
    (R^.SyncBase = EncodePlayerMap(R^)) and (DB.PM.Find(30, 'n')^.SyncBase <> ''));
  DB.Free;
end;

{ ---------------- the settings ---------------- }

procedure TestConfig(const SettingsPath, TmpDir: AnsiString);
var
  C: TZSConfig;
  Warn, L: TStringList;
  Path: AnsiString;
  k: LongInt;
  Ok: Boolean;
begin
  SetConfigDefaults(C);
  Check('[Matrix] defaults: on, 90 days, heat cells, 200 rivals', C.MatrixEnabled and (C.MatrixPruneDays = 90) and
    C.MatrixPlayerHeatmap and (C.MatrixMaxRivals = 200));
  Warn := TStringList.Create;
  L := TStringList.Create;
  try
    EnsureDir(TmpDir);
    Path := IncludeTrailingPathDelimiter(TmpDir) + 'matrix.ini';
    L.Add('[Matrix]');
    L.Add('Enabled = 0');
    L.Add('MatrixPruneDays = 5000');
    L.Add('PlayerHeatmap = off');
    L.Add('MaxRivals = 0');
    L.SaveToFile(Path);
    SetConfigDefaults(C);
    LoadConfigFile(Path, C, Warn);
    Check('[Matrix] read, the numbers kept in their ranges', not C.MatrixEnabled and (C.MatrixPruneDays = 3650) and
      not C.MatrixPlayerHeatmap and (C.MatrixMaxRivals = 1) and (Warn.Count = 2));
    Warn.Clear;
    SetConfigDefaults(C);
    LoadConfigFile(SettingsPath, C, Warn);
    Ok := FileExists(SettingsPath);
    for k := 0 to Warn.Count - 1 do
      if Pos('matrix', LowerCase(Warn[k])) > 0 then
        Ok := False;
    Check('settings.ini: [Matrix] as shipped, read without a warning', Ok and C.MatrixEnabled and
      (C.MatrixPruneDays = 90) and C.MatrixPlayerHeatmap and (C.MatrixMaxRivals = 200));
  finally
    L.Free;
    Warn.Free;
  end;
end;

{ ---------------- the engine ---------------- }

procedure Push(Ev: TZSEvent);
begin
  Ev.Tick := CurTick;
  Engine.PushEvent(Ev);
  Inc(Pushed);
end;

function WaitProcessed: Boolean;
var
  T0: Int64;
  A: TZSAction;
begin
  T0 := MonoMs;
  while Engine.Processed < Pushed do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Sleep(150);
  while Engine.PopAction(A) do
    if A.Kind = ACT_RAYCAST then
      LastRayId := A.P1;
  Result := True;
end;

function WaitReady: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not Engine.IsReady do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Result := True;
end;

procedure MapAfter(const Name: AnsiString; Style, Limit, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := Limit;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure MapBefore(A, B, TimeLeft, Limit: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapBefore);
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Ev.I[5] := Limit;
  Push(Ev);
end;

procedure Join(Slot: LongInt; Team: LongInt);
const
  NAMES: array[1..4] of AnsiString = ('Alice', 'Bob', 'Carl', 'Dave');
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := NAMES[Slot];
  Ev.S2 := STEAMS[Slot];
  Ev.S3 := 'HWMX' + IntToStr(Slot);
  Ev.S4 := '10.9.0.' + IntToStr(Slot);
  Ev.I[0] := Team;
  Ev.I[1] := 1;
  Ev.I[2] := 0;
  Push(Ev);
end;

procedure JoinBot(Slot: LongInt; const Name: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.I[0] := Team;
  Push(Ev);
end;

procedure LeaveEv(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(Ev);
end;

procedure SpawnWith(Slot, Primary, Secondary: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSpawn);
  Ev.Slot := Slot;
  Ev.I[0] := Primary;
  Ev.I[1] := Secondary;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure Shot(Slot, Weapon: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeShot);
  Ev.Slot := Slot;
  Ev.I[0] := Weapon;
  Ev.I[1] := 1;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure Damage(S, V, Weapon: LongInt; Dmg, BX, BY, BVX, BVY, VX, VY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeDamage);
  Ev.Slot := S;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := EF_BULLET or EF_B_ONGROUND;
  Ev.F[0] := Dmg;
  Ev.F[2] := BX;
  Ev.F[3] := BY;
  Ev.F[4] := BVX;
  Ev.F[5] := BVY;
  Ev.F[6] := VX;
  Ev.F[7] := VY;
  Push(Ev);
end;

{ a kill; Vest: what the victim's vest still held }
procedure KillEv(K, V, Weapon, VictimWeapon: LongInt; KX, KY, VX, VY, BX, BY: Single; Flags: LongInt; Vest: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKill);
  Ev.Slot := K;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags;
  Ev.I[3] := VictimWeapon;
  Ev.F[0] := KX;
  Ev.F[1] := KY;
  Ev.F[2] := VX;
  Ev.F[3] := VY;
  Ev.F[4] := BX;
  Ev.F[5] := BY;
  Ev.F[6] := Vest;
  Push(Ev);
end;

procedure FlagEv(Slot, Kind: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeFlag);
  Ev.Slot := Slot;
  Ev.I[0] := Kind;
  Push(Ev);
end;

procedure HealEv(Slot: LongInt; Regen: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeHeal);
  Ev.Slot := Slot;
  Ev.F[0] := Regen;
  Push(Ev);
end;

procedure TickEv(A, B, TimeLeft: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTick);
  Ev.I[0] := A;
  Ev.I[1] := B;
  Ev.I[4] := TimeLeft;
  Push(Ev);
end;

procedure SpawnAll(Count: LongInt);
var
  i: LongInt;
begin
  for i := 1 to Count do
    SpawnWith(i, WEP_AK74, WEP_SOCOM, 100 + 200 * i, 100);
end;

{ a hit with the flags of the event: B the bullet at the hit, BV its velocity }
procedure DamageEv(S, V, Weapon: LongInt; Dmg: Single; Flags: LongInt; BX, BY, BVX, BVY: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeDamage);
  Ev.Slot := S;
  Ev.Slot2 := V;
  Ev.I[0] := 5;
  Ev.I[1] := Weapon;
  Ev.I[2] := Flags;
  Ev.F[0] := Dmg;
  Ev.F[2] := BX;
  Ev.F[3] := BY;
  Ev.F[4] := BVX;
  Ev.F[5] := BVY;
  Ev.F[6] := BX;
  Ev.F[7] := BY + 10;
  Push(Ev);
end;

{ where a flag stands in its base, as main.pas reports it }
procedure FlagBase(Team: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeFlag);
  Ev.I[0] := FLAG_BASE;
  Ev.I[1] := Team;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

{ a position sample: the EF_A_* flags (alive, on the ground, flag carrier), the jet fuel }
procedure SampleEv(Slot, Flags: LongInt; X, Y: Single; Jets: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeSample);
  Ev.Slot := Slot;
  Ev.I[0] := Flags;
  Ev.I[1] := WEP_AK74;
  Ev.I[2] := 30;
  Ev.I[3] := Jets;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure KnifeThrowEv(Slot: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKnifeThrow);
  Ev.Slot := Slot;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure GrenadeEv(Slot: LongInt; X, Y: Single);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeGrenade);
  Ev.Slot := Slot;
  Ev.I[0] := 1;
  Ev.F[0] := X;
  Ev.F[1] := Y;
  Push(Ev);
end;

procedure KitEv(Slot, Style: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeKit);
  Ev.Slot := Slot;
  Ev.I[0] := Style;
  Push(Ev);
end;

{ the health of Count kits that healed the player }
procedure HealKitEv(Slot: LongInt; Health: Single; Count: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeHeal);
  Ev.Slot := Slot;
  Ev.F[1] := Health;
  Ev.I[0] := Count;
  Push(Ev);
end;

procedure RayAnswer(Id, Answer: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeRay);
  Ev.I[0] := Id;
  Ev.I[1] := Answer;
  Push(Ev);
end;

function Prof(Slot: LongInt): PPlayerProfile;
var
  Idx: LongInt;
begin
  Result := nil;
  Idx := Engine.DB.IndexOfSteam(STEAMS[Slot]);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx];
end;

function RecOf(Slot: LongInt; const Map: AnsiString): PPlayerMapStats;
begin
  Result := nil;
  if Prof(Slot) <> nil then
    Result := Engine.DB.PM.Find(Prof(Slot)^.ID, Map);
end;

procedure TakeSnap(IntoAfter: Boolean);
var
  i: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to 4 do
    begin
      if Prof(i) = nil then
        Continue;
      if IntoAfter then
        After[i] := Prof(i)^
      else
        Before[i] := Prof(i)^;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ a counter of a record or an account as a number (Base + Ofs is a field of Kind) }
function FieldNum(Base: Pointer; Ofs: PtrUInt; Kind: TFieldKind): Double;
begin
  case Kind of
    fkInt32: Result := PLongInt(PtrUInt(Base) + Ofs)^;
    fkInt64: Result := PInt64(PtrUInt(Base) + Ofs)^;
    fkSingle: Result := PSingle(PtrUInt(Base) + Ofs)^;
    fkDouble: Result := PDouble(PtrUInt(Base) + Ofs)^;
    else Result := 0;
  end;
end;

{ the record counts what the account's own statistics counted between the two snapshots (nil: a
  record with nothing); every kill and death is one of a rival and, with Heat, of a heat cell }
function DeltaOk(const Name: AnsiString; const B, A: TPlayerProfile; R: PPlayerMapStats; Heat: Boolean): Boolean;
var
  Why: AnsiString;
  E: TPMWeapon;
  Z: TPlayerMapStats;
  w, p, SumK, SumD, HK, HD: LongInt;
  Dealt, Taken: Double;

  procedure Cmp(const Field: AnsiString; Got, Want: Int64);
  begin
    if Got <> Want then
      Why := Why + Format(' %s %d<>%d', [Field, Got, Want]);
  end;

  procedure CmpF(const Field: AnsiString; Got, Want: Double);
  begin
    if Abs(Got - Want) > 0.01 then
      Why := Why + Format(' %s %.2f<>%.2f', [Field, Got, Want]);
  end;

  { the entry of a weapon slot in the record, zero without one }
  function Wep(Slot: LongInt): TPMWeapon;
  var
    q: LongInt;
  begin
    if PMWeaponPos(R^.Weapons, Slot, q) then
      Result := R^.Weapons[q]
    else
      Result := Weapon(Slot, 0, 0);
  end;

begin
  Why := '';
  ClearPlayerMap(Z);
  if R = nil then
    R := @Z;
  Cmp('time', R^.TimePlayed, A.TimePlayed - B.TimePlayed);
  Cmp('kills', R^.Kills, A.Kills - B.Kills);
  Cmp('deaths', R^.Deaths, A.Deaths - B.Deaths);
  Cmp('selfkills', R^.Selfkills, A.Selfkills - B.Selfkills);
  Cmp('teamkills', R^.Teamkills, A.Teamkills - B.Teamkills);
  Cmp('assists', R^.Assists, A.Assist - B.Assist);
  Cmp('points', R^.Points, A.Points - B.Points);
  Cmp('caps', R^.Caps, A.FlagsScore - B.FlagsScore);
  Cmp('returns', R^.Returns, A.FlagsReturn - B.FlagsReturn);
  Cmp('grabs', R^.Grabs, A.FlagsGrab - B.FlagsGrab);
  Cmp('shots', R^.Shots, A.Shots - B.Shots);
  Cmp('hits', R^.Hits, A.ShotsHits - B.ShotsHits);
  Cmp('head', R^.HitsHead, A.ShotsHitsHead - B.ShotsHitsHead);
  Cmp('body', R^.HitsBody, A.ShotsHitsBody - B.ShotsHitsBody);
  Cmp('legs', R^.HitsLegs, A.ShotsHitsLeg - B.ShotsHitsLeg);
  CmpF('dealt', R^.DamageDealt, A.DamageDealt - B.DamageDealt);
  CmpF('received', R^.DamageReceived, A.DamageReceived - B.DamageReceived);
  CmpF('healed', R^.HealRegen, A.HealRegen - B.HealRegen);
  Cmp('wins', R^.Wins, A.Wins - B.Wins);
  Cmp('losses', R^.Losses, A.Loses - B.Loses);
  Cmp('draws', R^.Draws, A.Draws - B.Draws);
  Cmp('rounds won', R^.RoundsWon, A.RoundsWins - B.RoundsWins);
  Cmp('rounds lost', R^.RoundsLost, A.RoundsLose - B.RoundsLose);
  Cmp('last stands', R^.LastStands, A.LastStand - B.LastStand);
  Cmp('first bloods', R^.FirstBloods, A.FirstBloodCount - B.FirstBloodCount);
  for w := 0 to WSLOT_COUNT - 1 do
  begin
    if PMWeaponPos(R^.Weapons, w, p) then
      E := R^.Weapons[p]
    else
      E := Weapon(w, 0, 0);
    Cmp('w' + IntToStr(w) + ' kills', E.Kills, A.Weapons[w].Kills - B.Weapons[w].Kills);
    Cmp('w' + IntToStr(w) + ' deaths', E.Deaths, A.Weapons[w].Deaths - B.Weapons[w].Deaths);
    Cmp('w' + IntToStr(w) + ' shots', E.Shots, A.Weapons[w].Shots - B.Weapons[w].Shots);
    Cmp('w' + IntToStr(w) + ' hits', E.Hits, A.Weapons[w].Hits - B.Weapons[w].Hits);
    Cmp('w' + IntToStr(w) + ' headshots', E.Headshots, A.Weapons[w].Headshots - B.Weapons[w].Headshots);
    CmpF('w' + IntToStr(w) + ' damage', E.Damage, A.Weapons[w].Damage - B.Weapons[w].Damage);
    Cmp('w' + IntToStr(w) + ' time', E.TimeUsed, A.Weapons[w].TimeUsedSeconds - B.Weapons[w].TimeUsedSeconds);
  end;
  SumK := 0;
  SumD := 0;
  Dealt := 0;
  Taken := 0;
  for p := 0 to High(R^.Rivals) do
  begin
    Inc(SumK, R^.Rivals[p].Kills);
    Inc(SumD, R^.Rivals[p].Deaths);
    Dealt := Dealt + R^.Rivals[p].DamageDealt;
    Taken := Taken + R^.Rivals[p].DamageTaken;
  end;
  Cmp('rival kills', SumK, R^.Kills);
  Cmp('rival deaths', SumD, R^.Deaths);
  CmpF('rival damage', Dealt, R^.DamageDealt);
  CmpF('rival damage taken', Taken, R^.DamageReceived);
  if Heat then
  begin
    HK := 0;
    HD := 0;
    for p := 0 to High(R^.Heat) do
    begin
      Inc(HK, R^.Heat[p].Kills);
      Inc(HD, R^.Heat[p].Deaths);
    end;
    Cmp('heat kills', HK, R^.Kills);
    Cmp('heat deaths', HD, R^.Deaths);
  end;
  if R^.LongestKill > A.LongestKillDistance + 0.01 then
    Why := Why + ' longest kill';
  if R^.BestStreak > A.MaxKillStreak then
    Why := Why + ' best streak';
  Cmp('round first bloods', R^.RoundFirstBloods, A.RoundFirstBloodCount - B.RoundFirstBloodCount);
  { 5.5 round 3: every counter that follows one of the account's }
  for p := 0 to High(PMFollows) do
    CmpF('id' + IntToStr(PMFollows[p].Id), FieldNum(R, PMFollows[p].RecordOffset, PMFollows[p].Kind),
      FieldNum(@A, PMFollows[p].ProfileOffset, PMFollows[p].Kind) - FieldNum(@B, PMFollows[p].ProfileOffset,
      PMFollows[p].Kind));
  { the counts the engine keeps by name }
  Cmp('tk deaths', R^.TeamkillDeaths, A.DeathsByFriendly - B.DeathsByFriendly);
  Cmp('flagger assists', R^.FlaggerAssists, A.FlaggerKillsAssist - B.FlaggerKillsAssist);
  Cmp('flagger teamkills', R^.FlaggerTeamkills, A.FlaggerTeamkills - B.FlaggerTeamkills);
  Cmp('teamkills with flag', R^.TeamkillsWithFlag, A.TeamkillsWhenHaveFlag - B.TeamkillsWhenHaveFlag);
  Cmp('forced selfkills', R^.ForcedSelfkills, A.ForcedSelfkills - B.ForcedSelfkills);
  Cmp('selfkills under fire', R^.SelfkillsUnderFire, A.SelfkillsUnderFire - B.SelfkillsUnderFire);
  Cmp('cover shots', R^.CoverShotKills, A.CoverShotKills - B.CoverShotKills);
  for w := 0 to KIT_KINDS - 1 do
    Cmp('kits' + IntToStr(w), R^.KitPickups[w], A.KitPickups[w] - B.KitPickups[w]);
  CmpF('heal kits', R^.HealKits, A.HealKits - B.HealKits);
  Cmp('heal kit count', R^.HealKitCount, A.HealKitCount - B.HealKitCount);
  Cmp('knife throws', R^.KnifeThrows, A.KnivesThrows - B.KnivesThrows);
  Cmp('leave losses', R^.LeaveLosses, A.LeaveLosses - B.LeaveLosses);
  Cmp('alpha wins', R^.AlphaWins, A.AlphaWins - B.AlphaWins);
  Cmp('alpha losses', R^.AlphaLosses, A.AlphaLoses - B.AlphaLoses);
  Cmp('bravo wins', R^.BravoWins, A.BravoWins - B.BravoWins);
  Cmp('bravo losses', R^.BravoLosses, A.BravoLoses - B.BravoLoses);
  Cmp('comebacks', R^.ComebackWins, A.ComebackWins - B.ComebackWins);
  Cmp('clutches', R^.ClutchesWon, A.ClutchesWon - B.ClutchesWon);
  Cmp('advance won', R^.AdvanceRoundsWon, A.AdvanceRoundsWon - B.AdvanceRoundsWon);
  Cmp('advance played', R^.AdvanceRoundsPlayed, A.AdvanceRoundsPlayed - B.AdvanceRoundsPlayed);
  Cmp('htf points', R^.HtfPoints, A.HTFMode.PointsScored - B.HTFMode.PointsScored);
  { the special weapons the views read from the weapon entries count what the account's own
    counters of them count }
  Cmp('nades thrown', Wep(WSLOT_FRAG).Shots, A.NadesThrows - B.NadesThrows);
  Cmp('nade hits', Wep(WSLOT_FRAG).Hits, A.NadeHurtsEnemy - B.NadeHurtsEnemy);
  Cmp('cluster throws', Wep(WSLOT_CLUSTER).Shots, A.ClusterNadesThrows - B.ClusterNadesThrows);
  Cmp('cluster hits', Wep(WSLOT_CLUSTER).Hits, A.ClusterNadesHurtsEnemy - B.ClusterNadesHurtsEnemy);
  Cmp('m79 shots', Wep(WEP_M79).Shots, A.M79Shots - B.M79Shots);
  Cmp('m79 hits', Wep(WEP_M79).Hits, A.M79HurtsEnemy - B.M79HurtsEnemy);
  Cmp('law shots', Wep(WEP_LAW).Shots, A.M72LAWShots - B.M72LAWShots);
  Cmp('law hits', Wep(WEP_LAW).Hits, A.M72LAWHurtsEnemy - B.M72LAWHurtsEnemy);
  Cmp('fist hits', Wep(WSLOT_FISTS).Hits, A.HandsHurtsEnemy - B.HandsHurtsEnemy);
  Cmp('saw time', Wep(WEP_CHAINSAW).TimeUsed, A.ChainsawTimeUsedSeconds - B.ChainsawTimeUsedSeconds);
  Cmp('saw hits', Wep(WEP_CHAINSAW).Hits, A.ChainsawHurtsEnemy - B.ChainsawHurtsEnemy);
  Cmp('flamer shots', Wep(WEP_FLAMER).Shots, A.FlamethrowerShots - B.FlamethrowerShots);
  Cmp('flamer hits', Wep(WEP_FLAMER).Hits, A.FlamethrowerHitsEnemy - B.FlamethrowerHitsEnemy);
  Cmp('m2 hits', Wep(WSLOT_M2).Hits, A.M2MGHitsEnemy - B.M2MGHitsEnemy);
  { a best of the map is never better than the account's own }
  if R^.LongestLife > A.LongestLifeSec then
    Why := Why + ' longest life';
  if R^.BestLifeDistance > A.BestLifeDistanceM + 0.01 then
    Why := Why + ' best life distance';
  if R^.LongestBarrett > A.LongestBarrettDistance + 0.01 then
    Why := Why + ' longest barrett';
  if R^.KnifeStreak > A.KnifeKillsLifeBest then
    Why := Why + ' knife streak';
  if (R^.BestTTKTicks > 0) and (R^.BestTTKTicks < A.BestTTKTicks) then
    Why := Why + ' best ttk';
  if (R^.TTKCount > 0) <> (R^.BestTTKTicks > 0) then
    Why := Why + ' best ttk without a ttk';
  if (R^.FastestCap > 0) and (R^.FastestCap < A.FastestCapSeconds - 0.01) then
    Why := Why + ' fastest cap';
  Result := Why = '';
  if not Result then
    WriteLn('       ', Name, ':', Why);
end;

{ the points won from every rival of a record less those lost to them: on a map where only kills (and
  selfkills under fire) moved points, the points of the record }
function RivalPointsNet(R: PPlayerMapStats): Int64;
var
  p: LongInt;
begin
  Result := 0;
  if R <> nil then
    for p := 0 to High(R^.Rivals) do
      Inc(Result, Int64(R^.Rivals[p].PointsWon) - R^.Rivals[p].PointsLost);
end;

function MapDeltasOk(const Map: AnsiString; Count: LongInt; Heat: Boolean): Boolean;
var
  i: LongInt;
begin
  Result := True;
  EnterCriticalSection(Engine.StateLock);
  try
    for i := 1 to Count do
      if not DeltaOk(Map + ' ' + STEAMS[i], Before[i], After[i], RecOf(i, Map), Heat) then
        Result := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ Everything else the account counts is counted on the map as well (5.5 round 3): Capture the Flag
  with friendly fire (kills of every kind, hits both ways, flags, a kit, samples, a selfkill under
  fire, a leaver, a comeback), a survival round won in a last stand with advance, Hold the Flag,
  Rambomatch, and a survival duel (two players make no last stand). }
procedure TestEngineFeats;
var
  i: LongInt;
  R, Rb, Rc, Rd: PPlayerMapStats;
  Ok: Boolean;
begin
  { ---- Capture the Flag with friendly fire: Alice and Carl (Alpha) against Bob and Dave (Bravo) ---- }
  CurTick := 4000;
  for i := 1 to 4 do
    LeaveEv(i);
  MapAfter('ctf_Feats', GS_CTF, 10, MF_FRIENDLYFIRE);
  Join(1, TEAM_ALPHA);
  Join(2, TEAM_BRAVO);
  Join(3, TEAM_ALPHA);
  Join(4, TEAM_BRAVO);
  FlagBase(TEAM_ALPHA, 100, 100);
  FlagBase(TEAM_BRAVO, 3000, 100);
  Check('ctf_Feats: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 4010;
  SpawnWith(1, WEP_AK74, WEP_SOCOM, 200, 100);
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 400, 180);
  SpawnWith(3, WEP_MP5, WEP_SOCOM, 220, 100);
  SpawnWith(4, WEP_AK74, WEP_SOCOM, 600, 100);
  CurTick := 4020;
  Shot(1, WEP_AK74, 200, 100);
  { Bob hits Alice first (the first damage of the match, enough for a bink recovery), Carl hits Bob
    enough for an assist and carries a flag, Bob hits Carl (Alice saves him) }
  CurTick := 4030;
  DamageEv(2, 1, WEP_BARRETT, 60, EF_BULLET or EF_B_ONGROUND, 205, 100, -55, 0);
  CurTick := 4035;
  DamageEv(3, 2, WEP_MP5, 100, EF_BULLET or EF_B_ONGROUND, 395, 180, 18, 0);
  CurTick := 4036;
  SampleEv(3, EF_A_ALIVE or EF_A_ONGROUND or EF_A_FLAGGER, 220, 100, 0);
  CurTick := 4038;
  DamageEv(2, 3, WEP_BARRETT, 10, EF_BULLET or EF_B_ONGROUND or EF_B_FLAGGER, 220, 100, -55, 0);
  CurTick := 4040;
  DamageEv(1, 2, WEP_AK74, 30, EF_BULLET or EF_B_ONGROUND, 380, 175, 24, 0);
  { through cover, near her base, from above, of a flag carrier in a vest just after his spawn, with
    Carl's flag close by }
  CurTick := 4045;
  KillEv(1, 2, WEP_AK74, WEP_BARRETT, 200, 100, 400, 180, 380, 175, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND or
    EF_RAY_CAL or EF_B_FLAGGER, 20);
  Check('ctf_Feats: the first kill', WaitProcessed);
  { the line of that shot was blocked }
  CurTick := 4046;
  RayAnswer(LastRayId, RAY_BLOCKED);
  CurTick := 4060;
  TickEv(0, 2, 300);
  { Bob, far away: a long Barrett kill lying down, his revenge }
  CurTick := 4100;
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 1700, 100);
  CurTick := 4110;
  Shot(2, WEP_BARRETT, 1700, 100);
  CurTick := 4140;
  DamageEv(2, 1, WEP_BARRETT, 150, EF_BULLET or EF_B_ONGROUND, 205, 100, -55, 0);
  KillEv(2, 1, WEP_BARRETT, WEP_AK74, 1700, 100, 200, 100, 205, 100, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND or
    EF_A_PRONE, 0);
  CurTick := 4160;
  TickEv(0, 2, 299);
  { Alice at the enemy base: an AK hit on Dave, a finisher in the air with a flag, a double kill with
    her revenge on Bob }
  CurTick := 4200;
  SpawnWith(1, WEP_AK74, WEP_SOCOM, 2900, 150);
  CurTick := 4210;
  SpawnWith(4, WEP_AK74, WEP_SOCOM, 2950, 100);
  CurTick := 4220;
  DamageEv(1, 4, WEP_AK74, 40, EF_BULLET or EF_B_ONGROUND, 2945, 100, 24, 0);
  CurTick := 4230;
  KillEv(1, 4, WEP_SOCOM, WEP_AK74, 2900, 150, 2950, 100, 2945, 100, EF_BULLET or EF_A_ALIVE or EF_A_FLAGGER, 0);
  CurTick := 4232;
  KillEv(1, 2, WEP_SOCOM, WEP_BARRETT, 2900, 150, 1700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 4260;
  TickEv(0, 2, 298);
  { two M79 kills at once (an explosive multi kill), then a grenade: she dominates Bob }
  CurTick := 4300;
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 500, 100);
  SpawnWith(4, WEP_AK74, WEP_SOCOM, 520, 100);
  CurTick := 4310;
  KillEv(1, 2, WEP_M79, WEP_BARRETT, 2900, 150, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 4311;
  KillEv(1, 4, WEP_M79, WEP_AK74, 2900, 150, 520, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 4320;
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 500, 100);
  CurTick := 4325;
  GrenadeEv(1, 2900, 150);
  DamageEv(1, 2, WEP_FRAG, 40, EF_B_ONGROUND, 500, 100, 0, 0);
  CurTick := 4330;
  KillEv(1, 2, WEP_FRAG, WEP_BARRETT, 2900, 150, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 4360;
  TickEv(0, 2, 297);
  { knives: a throw that hits Dave, a stab, and a knife kill that ends his spree }
  CurTick := 4400;
  SpawnWith(4, WEP_AK74, WEP_SOCOM, 2960, 100);
  Check('ctf_Feats: halfway', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Live[4].KillStreak := 6;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 4405;
  KnifeThrowEv(1, 2900, 150);
  CurTick := 4410;
  DamageEv(1, 4, WEP_THROWNKNIFE, 50, EF_BULLET or EF_B_ONGROUND, 2955, 100, 6, 0);
  CurTick := 4415;
  DamageEv(1, 4, WEP_KNIFE, 60, EF_B_ONGROUND, 2955, 100, 0, 0);
  CurTick := 4420;
  KillEv(1, 4, WEP_KNIFE, WEP_AK74, 2900, 150, 2960, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  { a kill after her death, then friendly fire: a hit on Carl and a teamkill of him, both carrying a
    flag, and her own grenade }
  CurTick := 4440;
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 500, 100);
  CurTick := 4450;
  KillEv(1, 2, WEP_AK74, WEP_BARRETT, 2900, 150, 500, 100, 0, 0, EF_A_ONGROUND, 0);
  CurTick := 4460;
  TickEv(0, 2, 296);
  CurTick := 4500;
  DamageEv(1, 3, WEP_AK74, 20, EF_BULLET or EF_B_ONGROUND, 220, 100, 24, 0);
  CurTick := 4510;
  KillEv(1, 3, WEP_AK74, WEP_MP5, 2900, 150, 220, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND or EF_A_FLAGGER or
    EF_B_FLAGGER, 0);
  CurTick := 4520;
  DamageEv(1, 1, WEP_FRAG, 30, EF_B_ONGROUND, 2900, 150, 0, 0);
  CurTick := 4560;
  TickEv(0, 2, 295);
  { the flag: a grab, a drop and a juggle, a throw and a juggle, a grab; samples with it, in the air
    with the jets on; a medical kit that healed her }
  CurTick := 4600;
  FlagEv(1, FLAG_GRAB);
  CurTick := 4610;
  FlagEv(1, FLAG_DROP);
  CurTick := 4650;
  FlagEv(1, FLAG_GRAB);
  CurTick := 4660;
  FlagEv(1, FLAG_THROWN);
  CurTick := 4700;
  FlagEv(1, FLAG_GRAB);
  CurTick := 4710;
  SampleEv(1, EF_A_ALIVE or EF_A_ONGROUND or EF_A_FLAGGER, 2900, 150, 100);
  CurTick := 4720;
  SampleEv(1, EF_A_ALIVE or EF_A_FLAGGER, 2900, 150, 100);
  CurTick := 4760;
  TickEv(0, 2, 294);
  CurTick := 4780;
  SampleEv(1, EF_A_ALIVE or EF_A_FLAGGER, 2910, 150, 80);
  CurTick := 4800;
  KitEv(1, KIT_MEDICAL);
  HealKitEv(1, 50, 1);
  CurTick := 4820;
  TickEv(0, 2, 293);
  { Dave kills himself right after Alice hit him: under fire, forced by her ([Ranking] SelfkillMode =
    zerosum) }
  CurTick := 4840;
  SpawnWith(4, WEP_AK74, WEP_SOCOM, 2960, 100);
  CurTick := 4850;
  DamageEv(1, 4, WEP_AK74, 10, EF_BULLET or EF_B_ONGROUND, 2955, 100, 24, 0);
  CurTick := 4860;
  KillEv(4, 4, WEP_M79, WEP_M79, 2960, 100, 2960, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  { the capture five seconds after the grab }
  CurTick := 5000;
  FlagEv(1, FLAG_SCORE);
  { Bob kills Carl, and Alice - who has not left her place since her spawn - avenges him at once }
  CurTick := 5010;
  SpawnWith(3, WEP_MP5, WEP_SOCOM, 2920, 150);
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 2800, 150);
  CurTick := 5015;
  KillEv(2, 3, WEP_BARRETT, WEP_MP5, 2800, 150, 2920, 150, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 5020;
  KillEv(1, 2, WEP_AK74, WEP_BARRETT, 2910, 150, 2800, 150, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 5060;
  TickEv(1, 2, 290);
  { Dave leaves the match his team loses; Alpha, 0:2 behind once, wins 3:2 }
  CurTick := 5070;
  LeaveEv(4);
  CurTick := 5100;
  MapBefore(3, 2, 0, 10);
  Check('ctf_Feats: played', WaitProcessed);
  TakeSnap(True);
  Check('ctf_Feats: every record counts what its account counted on the map, every counter of 5.5 round 3 too',
    MapDeltasOk('ctf_Feats', 4, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'ctf_Feats');
    Rb := RecOf(2, 'ctf_Feats');
    Rc := RecOf(3, 'ctf_Feats');
    Rd := RecOf(4, 'ctf_Feats');
    Ok := (R <> nil) and (Rb <> nil) and (Rc <> nil) and (Rd <> nil);
    Check('ctf_Feats: a record of each player', Ok);
    if Ok then
    begin
      Check('ctf_Feats: the kills of Alice - cover, bases, bink, height, vest, spawn, flagger, savior, escort, air, ' +
        'finisher, multi kills, explosive multi, grenade, dominations (of Bob and of Dave), revenge, shut down, knife, ' +
        'posthumous, camp, avenger, distances, the fastest kill',
        (R^.WallKills = 1) and (R^.CoverShotKills = 1) and (R^.BaseDefenseKills >= 1) and (R^.BaseAttackKills >= 1) and
        (R^.BinkRecoveryKills = 1) and (R^.HeightKills = 1) and (R^.VestKills = 1) and (R^.SpawnKills >= 2) and
        (R^.FlaggerKills = 1) and (R^.SaviorKills = 1) and (R^.FlagDefenses = 1) and (R^.EscortKills >= 1) and
        (R^.AirKills = 1) and (R^.KillsWithFlag = 1) and (R^.Finishers = 1) and (R^.DoubleKills = 1) and
        (R^.TripleKills = 1) and (R^.MultiKills = 1) and (R^.MultiKillsX2 = 1) and (R^.SerialKills = 1) and
        (R^.InsaneKills = 1) and (R^.ExplosionMultiKills = 1) and (R^.GrenadeKills = 1) and (R^.Dominations = 2) and
        (R^.RevengeKills = 1) and (R^.ShutDowns = 1) and (R^.KnifeStreak = 1) and (R^.PosthumousKills = 1) and
        (R^.CampKills = 1) and (R^.AvengerKills = 1) and (R^.KillDistCount >= 2) and (R^.KillDistSum > 0) and
        (R^.TTKCount >= 1) and (R^.BestTTKTicks = 5));
      Check('ctf_Feats: the hits and the rest of Alice - friendly fire, a teamkill around flags, her own nade, ' +
        'knives, flags, the flag held, jets, the way, a kit, a forced selfkill, time alive, the comeback',
        (R^.FriendlyHits = 1) and (Abs(R^.DamageFriendly - 20) < 0.01) and (R^.Teamkills = 1) and
        (R^.FlaggerTeamkills = 1) and (R^.TeamkillsWithFlag = 1) and (R^.SelfHits = 1) and (R^.NadeSelfHits = 1) and
        (R^.KnifeThrows = 1) and (R^.KnifeThrowHits = 1) and (R^.KnifeStabs = 1) and (R^.FlagDrops = 1) and
        (R^.FlagThrows = 1) and (R^.FlagJuggles = 2) and (R^.CapsUnder10s = 1) and (Abs(R^.FastestCap - 5) < 0.01) and
        (R^.FlagHoldTime >= 2) and (R^.JetTime = 1) and (R^.Traveled > 0) and (R^.BestLifeDistance > 0) and
        (R^.KitPickups[0] = 1) and (Abs(R^.HealKits - 50) < 0.01) and (R^.HealKitCount = 1) and
        (R^.ForcedSelfkills = 1) and (R^.TimeAlive > 0) and (R^.LongestLife > 0) and (R^.AlphaWins = 1) and
        (R^.ComebackWins = 1));
      Check('ctf_Feats: Bob - the first damage, a long Barrett kill lying down, his revenge; Carl - a flagger assist, ' +
        'the teamkill and the hit he took; Dave - a selfkill under fire and a loss for leaving',
        (Rb^.FirstDamages = 1) and (Rb^.ProneKills = 1) and (Rb^.RevengeKills = 1) and (Rb^.LongKills100 = 1) and
        (Rb^.BarrettLongKills = 1) and (Rb^.LongestBarrett > 100) and (Rb^.SpawnDeaths >= 1) and
        (Rb^.BravoLosses = 1) and (Rc^.FlaggerAssists = 1) and (Rc^.TeamkillDeaths = 1) and (Rc^.HitsByFriendly = 1) and
        (Abs(Rc^.DamageFriendlyReceived - 20) < 0.01) and (Rc^.AlphaWins = 1) and (Rd^.Selfkills = 1) and
        (Rd^.SelfkillsUnderFire = 1) and (Rd^.LeaveLosses = 1) and (Rd^.BravoLosses = 1) and (Rd^.Losses = 1));
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- survival Capture the Flag with advance: a last stand won by a capture is a clutch ---- }
  CurTick := 5200;
  for i := 1 to 4 do
    LeaveEv(i);
  MapAfter('ctf_Clutch', GS_CTF, 10, MF_SURVIVAL or MF_ADVANCE);
  Join(1, TEAM_ALPHA);
  Join(2, TEAM_BRAVO);
  Join(3, TEAM_ALPHA);
  Join(4, TEAM_BRAVO);
  Check('ctf_Clutch: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 5300;
  SpawnAll(4);
  CurTick := 5360;
  TickEv(0, 0, 600);
  CurTick := 5400;
  KillEv(2, 3, WEP_AK74, WEP_AK74, 500, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 5450;
  FlagEv(1, FLAG_GRAB);
  CurTick := 5500;
  FlagEv(1, FLAG_SCORE);
  CurTick := 5560;
  TickEv(1, 0, 599);
  CurTick := 5600;
  MapBefore(1, 0, 0, 10);
  Check('ctf_Clutch: played', WaitProcessed);
  TakeSnap(True);
  Check('ctf_Clutch: every record counts what its account counted on the map', MapDeltasOk('ctf_Clutch', 4, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'ctf_Clutch');
    Rb := RecOf(2, 'ctf_Clutch');
    Rc := RecOf(3, 'ctf_Clutch');
    Ok := (R <> nil) and (Rb <> nil) and (Rc <> nil) and (R^.LastStands = 1) and (R^.ClutchesWon = 1) and
      (R^.RoundsWon = 1) and (R^.AdvanceRoundsWon = 1) and (R^.AdvanceRoundsPlayed = 1) and (Rc^.ClutchesWon = 0) and
      (Rc^.AdvanceRoundsWon = 1) and (Rb^.AdvanceRoundsWon = 0) and (Rb^.AdvanceRoundsPlayed = 1);
    Check('survival with advance: the last stand won by a capture is a clutch; the advance rounds of both teams', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- Hold the Flag: Alice holds the flag under fire and scores twice ---- }
  CurTick := 5700;
  for i := 1 to 4 do
    LeaveEv(i);
  MapAfter('htf_Feats', GS_HTF, 10, 0);
  Join(1, TEAM_ALPHA);
  Join(2, TEAM_BRAVO);
  Check('htf_Feats: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 5710;
  SpawnAll(2);
  CurTick := 5720;
  FlagEv(1, FLAG_GRAB);
  CurTick := 5725;
  SampleEv(1, EF_A_ALIVE or EF_A_ONGROUND or EF_A_FLAGGER, 300, 100, 0);
  CurTick := 5730;
  DamageEv(2, 1, WEP_AK74, 10, EF_BULLET or EF_B_ONGROUND or EF_B_FLAGGER, 300, 100, -24, 0);
  CurTick := 5790;
  TickEv(1, 0, 300);
  CurTick := 6040;
  TickEv(2, 0, 299);
  CurTick := 6100;
  MapBefore(2, 0, 0, 10);
  Check('htf_Feats: played', WaitProcessed);
  TakeSnap(True);
  Check('htf_Feats: every record counts what its account counted on the map', MapDeltasOk('htf_Feats', 2, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'htf_Feats');
    Ok := (R <> nil) and (R^.HtfPoints = 2) and (R^.HtfHoldTime = 2) and (R^.HtfTeamHoldTime = 2) and
      (R^.ContestedHolds = 1) and (R^.FlagHoldTime = 2);
    Check('Hold the Flag: the points of the carrier, the time with the flag, a hold under fire', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- Rambomatch: a bow kill of the Rambo ---- }
  CurTick := 6200;
  for i := 1 to 2 do
    LeaveEv(i);
  MapAfter('rm_Feats', GS_RM, 10, 0);
  Join(1, TEAM_NONE);
  Join(2, TEAM_NONE);
  Check('rm_Feats: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 6210;
  SpawnWith(1, WEP_BOW, WEP_SOCOM, 100, 100);
  SpawnWith(2, WEP_BOW, WEP_SOCOM, 300, 100);
  CurTick := 6270;
  TickEv(0, 0, 300);
  CurTick := 6300;
  KillEv(1, 2, WEP_BOW, WEP_BOW, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 6360;
  TickEv(0, 0, 299);
  Check('rm_Feats: played', WaitProcessed);
  TakeSnap(True);
  Check('rm_Feats: every record counts what its account counted on the map', MapDeltasOk('rm_Feats', 2, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'rm_Feats');
    Check('Rambomatch: the bow kill, the kill of the Rambo, the time with the bow',
      (R <> nil) and (R^.BowKills = 1) and (R^.RamboKills = 1) and (R^.BowTime = 2));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- a survival duel: the round is won, but two players make no last stand ---- }
  CurTick := 6400;
  for i := 1 to 2 do
    LeaveEv(i);
  MapAfter('dm_Duel', GS_DM, 10, MF_SURVIVAL);
  Join(1, TEAM_NONE);
  Join(2, TEAM_NONE);
  Check('dm_Duel: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 6410;
  SpawnAll(2);
  CurTick := 6470;
  TickEv(0, 0, 300);
  CurTick := 6500;
  KillEv(1, 2, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 6560;
  TickEv(0, 0, 299);
  Check('dm_Duel: played', WaitProcessed);
  TakeSnap(True);
  Check('dm_Duel: every record counts what its account counted on the map', MapDeltasOk('dm_Duel', 2, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'dm_Duel');
    Check('a survival round won against one player: no last stand on the map, as none on the account ' +
      '(LastStandMinPlayers)', (R <> nil) and (R^.RoundsWon = 1) and (R^.LastStands = 0) and
      (After[1].RoundsWins - Before[1].RoundsWins = 1) and (After[1].LastStand = Before[1].LastStand));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure TestEngine(const Root: AnsiString);
var
  i, M, p, k: LongInt;
  R, R2: PPlayerMapStats;
  Ok: Boolean;
  SavedIds: array of LongInt;
  SavedMaps, SavedData: array of AnsiString;
  SavedMap: TMapProfile;
begin
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Pushed := 0;
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Check('[Matrix] MaxRivals reaches the table', (Engine.DB.PM.MaxRivals = 200) and
      (Engine.DB.PM.MaxRivals = Engine.Cfg.MatrixMaxRivals));
    { the short matches of this run count their results }
    Engine.Cfg.MinParticipationSeconds := 0;
    Engine.Cfg.MinParticipationPercent := 0;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- Capture the Flag: Alice and Carl (Alpha) against Bob (Bravo) ---- }
  CurTick := 0;
  MapAfter('ctf_Mx', GS_CTF, 10, 0);
  Join(1, TEAM_ALPHA);
  Join(2, TEAM_BRAVO);
  Join(3, TEAM_ALPHA);
  Check('ctf_Mx: the players are in', WaitProcessed);
  TakeSnap(False);
  SpawnWith(1, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 1500, 100);
  SpawnWith(3, WEP_MP5, WEP_SOCOM, 120, 100);
  CurTick := 20;
  Shot(1, WEP_AK74, 100, 100);
  CurTick := 60;
  TickEv(0, 0, 300);
  CurTick := 95;
  { enough for an assist of Carl (AssistMinDamagePercent) }
  Damage(3, 2, WEP_MP5, 110, 1490, 95, 40, 0, 1500, 100);
  CurTick := 102;
  Damage(1, 2, WEP_AK74, 30, 1480, 90, 40, 0, 1500, 100);
  KillEv(1, 2, WEP_AK74, WEP_BARRETT, 100, 100, 1500, 100, 1480, 90, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND, 50);
  CurTick := 120;
  TickEv(0, 0, 299);
  CurTick := 150;
  { a teamkill: no rival, no death }
  KillEv(1, 3, WEP_AK74, WEP_MP5, 100, 100, 120, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 200;
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 1500, 100);
  SpawnWith(3, WEP_MP5, WEP_SOCOM, 120, 100);
  FlagEv(1, FLAG_GRAB);
  FlagEv(2, FLAG_RETURN);
  HealEv(3, 12.5);
  CurTick := 700;
  KillEv(3, 3, WEP_MP5, WEP_MP5, 120, 100, 120, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 800;
  FlagEv(1, FLAG_SCORE);
  CurTick := 860;
  TickEv(1, 0, 290);
  CurTick := 870;
  Shot(2, WEP_BARRETT, 1500, 100);
  CurTick := 880;
  Damage(2, 1, WEP_BARRETT, 40, 110, 95, -40, 0, 100, 100);
  CurTick := 900;
  KillEv(2, 1, WEP_BARRETT, WEP_AK74, 1500, 100, 100, 100, 110, 95, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 960;
  TickEv(1, 0, 289);
  CurTick := 1000;
  MapBefore(1, 0, 0, 10);
  Check('ctf_Mx: played', WaitProcessed);
  TakeSnap(True);
  Check('ctf_Mx: every record counts what its account counted on the map', MapDeltasOk('ctf_Mx', 3, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'ctf_Mx');
    R2 := RecOf(2, 'ctf_Mx');
    Ok := (R <> nil) and (R2 <> nil) and (R^.Kills = 1) and (R^.Deaths = 1) and (R^.Teamkills = 1) and (R^.Caps = 1) and
      (R^.Grabs = 1) and (R^.FirstBloods = 1) and (R^.Matches = 1) and (R^.TimePlayed = 4) and
      (Abs(R^.LongestKill - Hypot(1380, 10) / 14) < 0.1) and (R2^.Returns = 1) and (R^.LastPlayed > 0) and
      (R^.FirstPlayed > 0) and (RecOf(3, 'ctf_Mx') <> nil) and (RecOf(3, 'ctf_Mx')^.Selfkills = 1) and
      (RecOf(3, 'ctf_Mx')^.Deaths = 0) and (RecOf(3, 'ctf_Mx')^.HealRegen = 12.5) and
      (RecOf(3, 'ctf_Mx')^.Assists = 1) and (R^.Wins = 1) and (R2^.Losses = 1) and (R^.Points > 0) and (R2^.Points < 0);
    if (R <> nil) and (R2 <> nil) and (RecOf(3, 'ctf_Mx') <> nil) then
      WriteLn(Format('       ctf_Mx points on the map: Alice %d, Bob %d, Carl %d', [R^.Points, R2^.Points,
        RecOf(3, 'ctf_Mx')^.Points]));
    Check('ctf_Mx: the counters of the records', Ok);
    Ok := (R <> nil) and (R2 <> nil) and (RivalAt(R^, Prof(2)^.ID) >= 0) and (RivalAt(R2^, Prof(1)^.ID) >= 0) and
      (RivalAt(R^, Prof(3)^.ID) < 0);
    if Ok then
    begin
      k := RivalAt(R^, Prof(2)^.ID);
      p := RivalAt(R2^, Prof(1)^.ID);
      Ok := (R^.Rivals[k].Kills = 1) and (R^.Rivals[k].Deaths = 1) and (Abs(R^.Rivals[k].DamageDealt - 30) < 0.01) and
        (Abs(R^.Rivals[k].DamageTaken - 40) < 0.01) and (R^.Rivals[k].LastFight > 0) and (R2^.Rivals[p].Kills = 1) and
        (R2^.Rivals[p].Deaths = 1) and (Abs(R2^.Rivals[p].DamageDealt - 40) < 0.01) and
        (Abs(R2^.Rivals[p].DamageTaken - 30) < 0.01);
    end;
    Check('ctf_Mx: rivals on both sides with the damage both ways; a teammate is no rival', Ok);
    Ok := (R <> nil) and (R2 <> nil) and PMMatchupPos(R^.Matchups, WEP_AK74, WEP_BARRETT, p) and
      (R^.Matchups[p].Wins = 1) and (R^.Matchups[p].Losses = 1) and PMMatchupPos(R2^.Matchups, WEP_BARRETT, WEP_AK74, p) and
      (R2^.Matchups[p].Wins = 1) and (R2^.Matchups[p].Losses = 1) and (Length(R^.Heat) >= 1);
    Check('ctf_Mx: the weapon matchups on both sides', Ok);
    M := Engine.DB.FindMap('ctf_Mx', False);
    Ok := (M >= 0) and (Engine.DB.Maps[M].KillsByTeam[TEAM_ALPHA] = 1) and (Engine.DB.Maps[M].KillsByTeam[TEAM_BRAVO] = 1);
    Ok := Ok and (Length(Engine.DB.Maps[M].Matchups) = 2) and
      MatchupCellPos(Engine.DB.Maps[M].Matchups, WEP_AK74, WEP_BARRETT, p) and (Engine.DB.Maps[M].Matchups[p].Kills = 1) and
      (Engine.DB.Maps[M].LastLoadedTime > 0) and (Engine.DB.Maps[M].LastPlayedTime >= Engine.DB.Maps[M].LastLoadedTime);
    Check('ctf_Mx: the kills of each team and the weapon matchups of the map; the map was loaded and played', Ok);
    Ok := (After[1].Weapons[WEP_AK74].DistBucket[3] - Before[1].Weapons[WEP_AK74].DistBucket[3] = 1) and
      (After[1].Weapons[WEP_AK74].KillDistCount - Before[1].Weapons[WEP_AK74].KillDistCount = 1) and
      (Abs(After[1].Weapons[WEP_AK74].KillDistSum - Before[1].Weapons[WEP_AK74].KillDistSum - Hypot(1380, 10) / 14) < 0.1) and
      (After[1].Weapons[WEP_AK74].TTKCount - Before[1].Weapons[WEP_AK74].TTKCount = 1) and
      (After[1].Weapons[WEP_AK74].VestKills - Before[1].Weapons[WEP_AK74].VestKills = 1) and
      (After[2].Weapons[WEP_BARRETT].TTKCount - Before[2].Weapons[WEP_BARRETT].TTKCount = 1) and
      (After[2].Weapons[WEP_BARRETT].TTKSumTicks - Before[2].Weapons[WEP_BARRETT].TTKSumTicks = 20) and
      (After[2].Weapons[WEP_BARRETT].VestKills = Before[2].Weapons[WEP_BARRETT].VestKills);
    Check('ctf_Mx: the distance, time to kill and vest kills of the account''s weapon', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- [Matrix] Enabled = 0 ---- }
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.MatrixEnabled := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  CurTick := 1100;
  MapAfter('ctf_Off', GS_CTF, 10, 0);
  Check('ctf_Off: loaded', WaitProcessed);
  TakeSnap(False);
  SpawnWith(1, WEP_AK74, WEP_SOCOM, 100, 100);
  SpawnWith(2, WEP_BARRETT, WEP_SOCOM, 1500, 100);
  SpawnWith(3, WEP_MP5, WEP_SOCOM, 120, 100);
  CurTick := 1120;
  Shot(1, WEP_AK74, 100, 100);
  CurTick := 1160;
  TickEv(0, 0, 300);
  CurTick := 1202;
  Damage(1, 2, WEP_AK74, 30, 1480, 90, 40, 0, 1500, 100);
  KillEv(1, 2, WEP_AK74, WEP_BARRETT, 100, 100, 1500, 100, 1480, 90, EF_BULLET or EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 1260;
  TickEv(0, 0, 299);
  Check('ctf_Off: played', WaitProcessed);
  TakeSnap(True);
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap('ctf_Off', False);
    Ok := (M >= 0) and (Length(Engine.DB.PM.OfMap('ctf_Off')) = 0) and (Length(Engine.DB.Maps[M].Matchups) = 0) and
      (Engine.DB.Maps[M].KillsByTeam[TEAM_ALPHA] = 1) and (After[1].Kills - Before[1].Kills = 1) and
      (After[1].Weapons[WEP_AK74].KillDistCount - Before[1].Weapons[WEP_AK74].KillDistCount = 1);
    Check('[Matrix] Enabled = 0: no record and no map matchup; everything else goes on', Ok);
    Engine.Cfg.MatrixEnabled := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- one human: the statistics do not count ---- }
  CurTick := 1300;
  MapBefore(0, 0, 0, 10);
  LeaveEv(2);
  LeaveEv(3);
  MapAfter('dm_Solo', GS_DM, 10, 0);
  JoinBot(7, 'Bot', TEAM_NONE);
  CurTick := 1310;
  SpawnWith(1, WEP_AK74, WEP_SOCOM, 100, 100);
  CurTick := 1370;
  TickEv(0, 0, 300);
  CurTick := 1430;
  TickEv(0, 0, 299);
  CurTick := 1450;
  KillEv(1, 7, WEP_AK74, WEP_AK74, 100, 100, 300, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 1460;
  KillEv(7, 1, WEP_AK74, WEP_AK74, 300, 100, 100, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  Check('dm_Solo: played', WaitProcessed);
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap('dm_Solo', False);
    Check('one human with a bot: no record; the map ran but was not played with the statistics on',
      (Length(Engine.DB.PM.OfMap('dm_Solo')) = 0) and (M >= 0) and (Engine.DB.Maps[M].LastLoadedTime > 0) and
      (Engine.DB.Maps[M].LastPlayedTime = 0));
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- survival deathmatch: the last one standing, nobody left, cut by the map change ---- }
  CurTick := 1500;
  MapBefore(0, 0, 0, 10);
  LeaveEv(7);
  LeaveEv(1);
  MapAfter('dm_Mx', GS_DM, 30, MF_SURVIVAL);
  for i := 1 to 3 do
    Join(i, TEAM_NONE);
  Check('dm_Mx: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 1600;
  SpawnAll(3);
  CurTick := 1660;
  TickEv(0, 0, 600);
  CurTick := 1700;
  KillEv(1, 2, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 1750;
  KillEv(1, 3, WEP_AK74, WEP_AK74, 300, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 1810;
  TickEv(0, 0, 599);
  CurTick := 1900;
  SpawnAll(3);
  CurTick := 1960;
  TickEv(0, 0, 598);
  CurTick := 2000;
  KillEv(2, 3, WEP_AK74, WEP_AK74, 500, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 2100;
  KillEv(1, 2, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  KillEv(2, 1, WEP_AK74, WEP_AK74, 500, 100, 300, 100, 0, 0, EF_A_ONGROUND, 0);
  CurTick := 2160;
  TickEv(0, 0, 597);
  CurTick := 2200;
  SpawnAll(3);
  CurTick := 2260;
  TickEv(0, 0, 596);
  CurTick := 2300;
  KillEv(1, 3, WEP_AK74, WEP_AK74, 300, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 2400;
  MapBefore(0, 0, 0, 30);
  Check('dm_Mx: played', WaitProcessed);
  TakeSnap(True);
  Check('dm_Mx: every record counts what its account counted on the map', MapDeltasOk('dm_Mx', 3, True));
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap('dm_Mx', False);
    Ok := (M >= 0) and (Engine.DB.Maps[M].RoundsLastStanding = 1) and (Engine.DB.Maps[M].RoundsNoSurvivor = 1) and
      (Engine.DB.Maps[M].RoundsMapChange = 1) and (Engine.DB.Maps[M].RoundsCapture = 0) and
      (Engine.DB.Maps[M].KillsByTeam[TEAM_ALPHA] = 0);
    Check('survival deathmatch: a round won by the last one standing, one nobody survived, one cut by the map change',
      Ok);
    R := RecOf(1, 'dm_Mx');
    Ok := (R <> nil) and (R^.RoundsWon = 1) and (R^.RoundsLost = 1) and (R^.LastStands = 1) and (R^.Wins = 1) and
      (R^.Matches = 1) and (RecOf(2, 'dm_Mx') <> nil) and (RecOf(2, 'dm_Mx')^.RoundsLost = 2) and
      (RecOf(2, 'dm_Mx')^.Losses = 1) and (RecOf(3, 'dm_Mx') <> nil) and (RecOf(3, 'dm_Mx')^.RoundsLost = 2);
    Check('survival deathmatch: the rounds and the match of each player', Ok);
    { only kills moved points here: what every account won from its rivals less what it lost to them is
      its points of the map, and what one won from another the other lost (nobody is at MinimumPoints) }
    Ok := True;
    for i := 1 to 3 do
      if (RecOf(i, 'dm_Mx') = nil) or (RivalPointsNet(RecOf(i, 'dm_Mx')) <> RecOf(i, 'dm_Mx')^.Points) or
         (RecOf(i, 'dm_Mx')^.Points <> After[i].Points - Before[i].Points) then
        Ok := False;
    R := RecOf(1, 'dm_Mx');
    R2 := RecOf(2, 'dm_Mx');
    if Ok and (R <> nil) and (R2 <> nil) then
    begin
      k := RivalAt(R^, Prof(2)^.ID);
      p := RivalAt(R2^, Prof(1)^.ID);
      Ok := (k >= 0) and (p >= 0) and (R^.Rivals[k].PointsWon > 0) and (R^.Rivals[k].PointsWon = R2^.Rivals[p].PointsLost) and
        (R^.Rivals[k].PointsLost > 0) and (R^.Rivals[k].PointsLost = R2^.Rivals[p].PointsWon);
    end;
    Check('survival deathmatch: the points won from each rival and lost to him are the points of the map, both sides ' +
      'alike', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- survival Capture the Flag: a capture, a wipe-out, nobody left, cut by the map change ---- }
  CurTick := 2500;
  for i := 1 to 3 do
    LeaveEv(i);
  MapAfter('ctf_Surv', GS_CTF, 10, MF_SURVIVAL);
  Join(1, TEAM_ALPHA);
  Join(2, TEAM_BRAVO);
  Join(3, TEAM_ALPHA);
  Check('ctf_Surv: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 2600;
  SpawnAll(3);
  CurTick := 2660;
  TickEv(0, 0, 600);
  CurTick := 2700;
  FlagEv(1, FLAG_GRAB);
  CurTick := 2800;
  FlagEv(1, FLAG_SCORE);
  CurTick := 2860;
  TickEv(1, 0, 599);
  CurTick := 2900;
  SpawnAll(3);
  CurTick := 2960;
  TickEv(1, 0, 598);
  CurTick := 3000;
  KillEv(1, 2, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 3060;
  TickEv(2, 0, 597);
  CurTick := 3100;
  SpawnAll(3);
  CurTick := 3160;
  TickEv(2, 0, 596);
  CurTick := 3200;
  KillEv(2, 3, WEP_AK74, WEP_AK74, 500, 100, 700, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 3300;
  KillEv(1, 2, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  KillEv(2, 1, WEP_AK74, WEP_AK74, 500, 100, 300, 100, 0, 0, EF_A_ONGROUND, 0);
  CurTick := 3360;
  TickEv(2, 0, 595);
  CurTick := 3400;
  SpawnAll(3);
  CurTick := 3460;
  TickEv(2, 0, 594);
  CurTick := 3500;
  MapBefore(2, 0, 0, 10);
  Check('ctf_Surv: played', WaitProcessed);
  TakeSnap(True);
  Check('ctf_Surv: every record counts what its account counted on the map', MapDeltasOk('ctf_Surv', 3, True));
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap('ctf_Surv', False);
    Ok := (M >= 0) and (Engine.DB.Maps[M].RoundsCapture = 1) and (Engine.DB.Maps[M].RoundsElimination[TEAM_ALPHA] = 1) and
      (Engine.DB.Maps[M].RoundsElimination[TEAM_BRAVO] = 0) and (Engine.DB.Maps[M].RoundsNoSurvivor = 1) and
      (Engine.DB.Maps[M].RoundsMapChange = 1) and (Engine.DB.Maps[M].RoundsLastStanding = 0) and
      (Engine.DB.Maps[M].KillsByTeam[TEAM_ALPHA] = 2) and (Engine.DB.Maps[M].KillsByTeam[TEAM_BRAVO] = 2);
    Check('survival Capture the Flag: a round won by a capture, one by wiping the other team out, one nobody ' +
      'survived, one cut by the map change; the kills of each team', Ok);
    Ok := (RecOf(1, 'ctf_Surv') <> nil) and (RecOf(1, 'ctf_Surv')^.RoundsWon = 2) and (RecOf(3, 'ctf_Surv') <> nil) and
      (RecOf(3, 'ctf_Surv')^.RoundsWon = 2) and (RecOf(2, 'ctf_Surv') <> nil) and (RecOf(2, 'ctf_Surv')^.RoundsLost = 2);
    Check('survival Capture the Flag: the rounds of each player', Ok);
    Engine.Cfg.MatrixPlayerHeatmap := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- [Matrix] PlayerHeatmap = 0 ---- }
  CurTick := 3600;
  for i := 1 to 3 do
    LeaveEv(i);
  MapAfter('dm_Cold', GS_DM, 10, 0);
  Join(1, TEAM_NONE);
  Join(2, TEAM_NONE);
  Check('dm_Cold: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 3610;
  SpawnAll(2);
  CurTick := 3670;
  TickEv(0, 0, 300);
  CurTick := 3700;
  KillEv(1, 2, WEP_AK74, WEP_AK74, 300, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 3760;
  TickEv(0, 0, 299);
  Check('dm_Cold: played', WaitProcessed);
  TakeSnap(True);
  Check('dm_Cold: every record counts what its account counted on the map', MapDeltasOk('dm_Cold', 2, False));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'dm_Cold');
    R2 := RecOf(2, 'dm_Cold');
    Check('[Matrix] PlayerHeatmap = 0: no heat cells, the rest is counted', (R <> nil) and (R2 <> nil) and
      (R^.Kills = 1) and (R2^.Deaths = 1) and (Length(R^.Heat) = 0) and (Length(R2^.Heat) = 0));
    Ok := (R <> nil) and (R2 <> nil) and (R^.Points > 0) and (R^.Points = After[1].Points - Before[1].Points) and
      (RivalText(R, Prof(2)^.ID) = Format('1/0 %d/0', [R^.Points])) and
      (RivalText(R2, Prof(1)^.ID) = Format('0/1 0/%d', [-R2^.Points]));
    if (R <> nil) and (R2 <> nil) then
      WriteLn(Format('       dm_Cold: Alice''s entry of Bob %s, Bob''s of Alice %s', [RivalText(R, Prof(2)^.ID),
        RivalText(R2, Prof(1)^.ID)]));
    Check('a kill: the killer''s entry of the victim wins what the kill paid, the victim''s entry of the killer ' +
      'loses what it cost', Ok);
    Engine.Cfg.MatrixPlayerHeatmap := True;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- a selfkill under fire with [Ranking] SelfkillMode = zerosum: the points go from one player
    to the other without a kill ---- }
  CurTick := 3800;
  for i := 1 to 2 do
    LeaveEv(i);
  MapAfter('dm_Self', GS_DM, 10, 0);
  Join(1, TEAM_NONE);
  Join(2, TEAM_NONE);
  Check('dm_Self: the players are in', WaitProcessed);
  TakeSnap(False);
  CurTick := 3810;
  SpawnAll(2);
  CurTick := 3870;
  TickEv(0, 0, 300);
  CurTick := 3900;
  Damage(1, 2, WEP_AK74, 20, 480, 95, 40, 0, 500, 100);
  CurTick := 3930;
  KillEv(2, 2, WEP_M79, WEP_M79, 500, 100, 500, 100, 0, 0, EF_A_ALIVE or EF_A_ONGROUND, 0);
  CurTick := 3990;
  TickEv(0, 0, 299);
  Check('dm_Self: played', WaitProcessed);
  TakeSnap(True);
  Check('dm_Self: every record counts what its account counted on the map', MapDeltasOk('dm_Self', 2, True));
  EnterCriticalSection(Engine.StateLock);
  try
    R := RecOf(1, 'dm_Self');
    R2 := RecOf(2, 'dm_Self');
    k := After[1].Points - Before[1].Points;
    Ok := (R <> nil) and (R2 <> nil) and (k > 0) and (After[2].Points - Before[2].Points = -k) and
      (After[2].Selfkills - Before[2].Selfkills = 1) and (After[1].ForcedSelfkills - Before[1].ForcedSelfkills = 1) and
      (R^.Points = k) and (R2^.Points = -k) and (R2^.Selfkills = 1) and
      (RivalText(R, Prof(2)^.ID) = Format('0/0 %d/0', [k])) and (RivalText(R2, Prof(1)^.ID) = Format('0/0 0/%d', [k]));
    if (R <> nil) and (R2 <> nil) then
      WriteLn(Format('       dm_Self: %d points; Alice''s entry of Bob %s, Bob''s of Alice %s', [k,
        RivalText(R, Prof(2)^.ID), RivalText(R2, Prof(1)^.ID)]));
    Check('zerosum: the selfkill under fire moves its points from the selfkiller''s entry of the enemy to the enemy''s ' +
      'entry of him, without a kill or a death', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  TestEngineFeats;

  EnterCriticalSection(Engine.StateLock);
  try
    { what the restart has to bring back }
    SetLength(SavedIds, Engine.DB.PM.Count);
    SetLength(SavedMaps, Engine.DB.PM.Count);
    SetLength(SavedData, Engine.DB.PM.Count);
    k := 0;
    for i := 0 to Engine.DB.PM.Places - 1 do
      if (Engine.DB.PM.Items[i] <> nil) and (k < Length(SavedIds)) then
      begin
        SavedIds[k] := Engine.DB.PM.Items[i]^.AccountId;
        SavedMaps[k] := Engine.DB.PM.Items[i]^.MapName;
        SavedData[k] := EncodePlayerMap(Engine.DB.PM.Items[i]^);
        Inc(k);
      end;
    M := Engine.DB.FindMap('ctf_Surv', False);
    SavedMap := Engine.DB.Maps[M];
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- a restart brings every record back ---- }
  Engine.Free;
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Pushed := 0;
  Engine.Start;
  Check('restart', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := (k = Length(SavedIds)) and (k >= 10) and (Engine.DB.PM.Count = k);
    for i := 0 to k - 1 do
    begin
      R := Engine.DB.PM.Find(SavedIds[i], SavedMaps[i]);
      if (R = nil) or (EncodePlayerMap(R^) <> SavedData[i]) then
        Ok := False;
    end;
    M := Engine.DB.FindMap('ctf_Surv', False);
    Ok := Ok and (M >= 0) and (Engine.DB.Maps[M].RoundsCapture = SavedMap.RoundsCapture) and
      (Engine.DB.Maps[M].RoundsElimination[TEAM_ALPHA] = SavedMap.RoundsElimination[TEAM_ALPHA]) and
      (Engine.DB.Maps[M].RoundsNoSurvivor = SavedMap.RoundsNoSurvivor) and
      (Engine.DB.Maps[M].RoundsMapChange = SavedMap.RoundsMapChange) and
      (Engine.DB.Maps[M].KillsByTeam[TEAM_BRAVO] = SavedMap.KillsByTeam[TEAM_BRAVO]) and
      (Engine.DB.Maps[M].LastLoadedTime = SavedMap.LastLoadedTime);
    Check('a restart brings every record and the new fields of the maps back', Ok);
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Engine.Free;
end;

var
  Base, Tmp: AnsiString;
begin
  Base := ExpandFileName('build' + PathDelim + 'test');
  Tmp := Base + PathDelim + 'matrix_tmp';
  TestRegistry;
  TestCodec;
  TestAllFields;
  TestMapFields;
  TestWeaponExtras;
  TestMerges;
  TestRivalCap;
  TestStore(Base + PathDelim + 'matrix_store');
  TestDatabase(Base + PathDelim + 'matrix_db');
  TestTableStress;
  TestSync;
  TestConfig(ExpandFileName('..' + PathDelim + 'settings.ini'), Tmp);
  TestEngine(Base + PathDelim + 'matrix_engine');

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
