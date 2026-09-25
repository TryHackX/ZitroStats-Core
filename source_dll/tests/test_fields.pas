program test_fields;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, zs_types, zs_util, zs_fields;

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

procedure FillRandom(Base: Pointer; const Defs: TFieldDefArray);
var
  i, j, n: LongInt;
  Ptr: Pointer;
  Al: ^TOtherDataArray;
  Tr: ^TTrustedDeviceArray;
  Ba: ^TSeasonBadgeArray;
  Ac: ^TAchievementArray;
  He: ^THeatCellArray;
  Da: ^TDailyStatArray;
begin
  for i := 0 to High(Defs) do
  begin
    if Random(6) = 0 then Continue;
    Ptr := Pointer(PtrUInt(Base) + Defs[i].Offset);
    n := 1 + Random(5);
    case Defs[i].Kind of
      fkInt32: PLongInt(Ptr)^ := Random(2000000) - 1000000;
      fkInt64: PInt64(Ptr)^ := Int64(Random(2000000000)) * 1024 - 7;
      fkSingle: PSingle(Ptr)^ := Random * 1000 - 500;
      fkDouble: PDouble(Ptr)^ := Random * 1e7;
      fkBool: PBoolean(Ptr)^ := True;
      fkString: PAnsiString(Ptr)^ := 'value-' + IntToStr(Random(1000000)) + #$B9#$EA;
      fkAliases:
        begin
          Al := Ptr;
          SetLength(Al^, n);
          for j := 0 to n - 1 do
          begin
            FillChar(Al^[j], SizeOf(TOtherData), 0);
            SetOtherDataString(Al^[j], 'alias-' + IntToStr(Random(100000)));
            Al^[j].IsActive := j = 0;
            Al^[j].LoginCount := Random(1000);
            Al^[j].TimePlayed := Random(100000);
            Al^[j].TimeOnSpectator := Random(1000);
            Al^[j].FirstUsedDate := 40000 + Random * 1000;
            Al^[j].LastUsedDate := 45000 + Random * 1000;
          end;
        end;
      fkTrusted:
        begin
          Tr := Ptr;
          SetLength(Tr^, n);
          for j := 0 to n - 1 do
          begin
            Tr^[j].HWID := 'HW' + IntToStr(Random(1000000));
            Tr^[j].IPPrefix := '10.0.' + IntToStr(j);
            Tr^[j].Expire := 46000 + Random * 100;
            Tr^[j].LastUsed := 45900 + Random * 100;
          end;
        end;
      fkBadges:
        begin
          Ba := Ptr;
          SetLength(Ba^, n);
          for j := 0 to n - 1 do
          begin
            Ba^[j].SeasonId := j + 1;
            Ba^[j].Place := 1 + Random(50);
          end;
        end;
      fkAchievements:
        begin
          Ac := Ptr;
          SetLength(Ac^, n);
          for j := 0 to n - 1 do
          begin
            Ac^[j].Id := 100 + j;
            Ac^[j].Date := 45000 + Random * 1000;
          end;
        end;
      fkHeat:
        begin
          He := Ptr;
          SetLength(He^, n);
          for j := 0 to n - 1 do
          begin
            He^[j].Cell := Random(4096);
            He^[j].Kills := Random(100);
            He^[j].Deaths := Random(100);
          end;
        end;
      fkDaily:
        begin
          Da := Ptr;
          SetLength(Da^, n);
          for j := 0 to n - 1 do
          begin
            Da^[j].Day := 20260900 + j;
            Da^[j].Uniques := Random(500);
            Da^[j].NewPlayers := Random(50);
            Da^[j].Sessions := Random(900);
            Da^[j].PlaySeconds := Random(1000000);
            Da^[j].PeakOnline := Random(32);
            Da^[j].Kills := Random(10000);
          end;
        end;
    end;
  end;
end;

{ two fields with the same id would overwrite each other in the journal and the snapshot }
function DuplicateFieldId(const Defs: TFieldDefArray): AnsiString;
var
  i, j: LongInt;
begin
  Result := '';
  for i := 0 to High(Defs) do
    for j := i + 1 to High(Defs) do
      if Defs[i].Id = Defs[j].Id then
      begin
        Result := IntToStr(Defs[i].Id);
        Exit;
      end;
end;

{ two ids for one field would save it twice and let the later one win on reading }
function DuplicateOffset(const Defs: TFieldDefArray): AnsiString;
var
  i, j: LongInt;
begin
  Result := '';
  for i := 0 to High(Defs) do
    for j := i + 1 to High(Defs) do
      if Defs[i].Offset = Defs[j].Offset then
      begin
        Result := IntToStr(Defs[i].Id) + '/' + IntToStr(Defs[j].Id);
        Exit;
      end;
end;

function FieldSize(Kind: TFieldKind): PtrUInt;
begin
  case Kind of
    fkInt32, fkSingle: Result := 4;
    fkInt64, fkDouble: Result := 8;
    fkBool: Result := SizeOf(Boolean);
    else Result := SizeOf(Pointer);
  end;
end;

{ '' when every field lies inside the record }
function FieldOutside(const Defs: TFieldDefArray; RecSize: PtrUInt): AnsiString;
var
  i: LongInt;
begin
  Result := '';
  for i := 0 to High(Defs) do
    if Defs[i].Offset + FieldSize(Defs[i].Kind) > RecSize then
      Exit(IntToStr(Defs[i].Id));
end;

function FieldIndex(const Defs: TFieldDefArray; Id: Word): LongInt;
var
  i: LongInt;
begin
  for i := 0 to High(Defs) do
    if Defs[i].Id = Id then
      Exit(i);
  Result := -1;
end;

{ the field with this id is the one at Addr (inside the record at Base), of this kind and rule }
function FieldIs(const Defs: TFieldDefArray; Id: Word; Base, Addr: Pointer; Kind: TFieldKind;
  Merge: TMergeKind; Stat: Boolean): Boolean;
var
  k: LongInt;
begin
  k := FieldIndex(Defs, Id);
  Result := (k >= 0) and (Defs[k].Offset = PtrUInt(Addr) - PtrUInt(Base)) and (Defs[k].Kind = Kind) and
    (Defs[k].Merge = Merge) and (Defs[k].Stat = Stat);
end;

function MergeOf(const Defs: TFieldDefArray; Id: Word): TMergeKind;
var
  k: LongInt;
begin
  k := FieldIndex(Defs, Id);
  if k >= 0 then
    Result := Defs[k].Merge
  else
    Result := mkSum;
end;

{ a record field of kind T_F64 with the raw bits given, the way a damaged record could hold it }
function RawDouble(Id: Word; Bits: QWord): AnsiString;
begin
  SetLength(Result, 11);
  Move(Id, Result[1], 2);
  Result[3] := #4;
  Move(Bits, Result[4], 8);
end;

function RawSingle(Id: Word; Bits: LongWord): AnsiString;
begin
  SetLength(Result, 7);
  Move(Id, Result[1], 2);
  Result[3] := #3;
  Move(Bits, Result[4], 4);
end;

function FirstDifference(A, B: Pointer; const Defs: TFieldDefArray): LongInt;
var
  i, j: LongInt;
  PA, PB: Pointer;
  AA, AB: ^TOtherDataArray;
  TA, TB: ^TTrustedDeviceArray;
  BA, BB: ^TSeasonBadgeArray;
  CA, CB: ^TAchievementArray;
  HA, HB: ^THeatCellArray;
  DA, DB: ^TDailyStatArray;
begin
  Result := -1;
  for i := 0 to High(Defs) do
  begin
    PA := Pointer(PtrUInt(A) + Defs[i].Offset);
    PB := Pointer(PtrUInt(B) + Defs[i].Offset);
    case Defs[i].Kind of
      fkInt32: if PLongInt(PA)^ <> PLongInt(PB)^ then Exit(Defs[i].Id);
      fkInt64: if PInt64(PA)^ <> PInt64(PB)^ then Exit(Defs[i].Id);
      fkSingle: if PSingle(PA)^ <> PSingle(PB)^ then Exit(Defs[i].Id);
      fkDouble: if PDouble(PA)^ <> PDouble(PB)^ then Exit(Defs[i].Id);
      fkBool: if PBoolean(PA)^ <> PBoolean(PB)^ then Exit(Defs[i].Id);
      fkString: if PAnsiString(PA)^ <> PAnsiString(PB)^ then Exit(Defs[i].Id);
      fkAliases:
        begin
          AA := PA; AB := PB;
          if Length(AA^) <> Length(AB^) then Exit(Defs[i].Id);
          for j := 0 to High(AA^) do
            if not CompareMem(@AA^[j], @AB^[j], SizeOf(TOtherData)) then Exit(Defs[i].Id);
        end;
      fkTrusted:
        begin
          TA := PA; TB := PB;
          if Length(TA^) <> Length(TB^) then Exit(Defs[i].Id);
          for j := 0 to High(TA^) do
            if (TA^[j].HWID <> TB^[j].HWID) or (TA^[j].IPPrefix <> TB^[j].IPPrefix) or
               (TA^[j].Expire <> TB^[j].Expire) or (TA^[j].LastUsed <> TB^[j].LastUsed) then Exit(Defs[i].Id);
        end;
      fkBadges:
        begin
          BA := PA; BB := PB;
          if Length(BA^) <> Length(BB^) then Exit(Defs[i].Id);
          for j := 0 to High(BA^) do
            if (BA^[j].SeasonId <> BB^[j].SeasonId) or (BA^[j].Place <> BB^[j].Place) then Exit(Defs[i].Id);
        end;
      fkAchievements:
        begin
          CA := PA; CB := PB;
          if Length(CA^) <> Length(CB^) then Exit(Defs[i].Id);
          for j := 0 to High(CA^) do
            if (CA^[j].Id <> CB^[j].Id) or (CA^[j].Date <> CB^[j].Date) then Exit(Defs[i].Id);
        end;
      fkHeat:
        begin
          HA := PA; HB := PB;
          if Length(HA^) <> Length(HB^) then Exit(Defs[i].Id);
          for j := 0 to High(HA^) do
            if (HA^[j].Cell <> HB^[j].Cell) or (HA^[j].Kills <> HB^[j].Kills) or (HA^[j].Deaths <> HB^[j].Deaths) then Exit(Defs[i].Id);
        end;
      fkDaily:
        begin
          DA := PA; DB := PB;
          if Length(DA^) <> Length(DB^) then Exit(Defs[i].Id);
          for j := 0 to High(DA^) do
            if (DA^[j].Day <> DB^[j].Day) or (DA^[j].Uniques <> DB^[j].Uniques) or
               (DA^[j].NewPlayers <> DB^[j].NewPlayers) or (DA^[j].Sessions <> DB^[j].Sessions) or
               (DA^[j].PlaySeconds <> DB^[j].PlaySeconds) or (DA^[j].PeakOnline <> DB^[j].PeakOnline) or
               (DA^[j].Kills <> DB^[j].Kills) then Exit(Defs[i].Id);
        end;
    end;
  end;
end;

var
  P1, P2, P3, PB, PR: TPlayerProfile;
  M1, M2, MB, MR: TMapProfile;
  S1, S2, SB, SR: TServerRecords;
  A1, A2: TSeasonArchive;
  Data, Data2, Bad, Str: AnsiString;
  i, Diff, Cut, Crashes, Names, Trusted, Badges, Ach: LongInt;
  Ok: Boolean;
  T0: Int64;
begin
  RandSeed := 12345;
  WriteLn('       SizeOf(TPlayerProfile) = ', SizeOf(TPlayerProfile), ', fields: ', Length(ProfileFields));
  Check('every profile field has its own id: ' + DuplicateFieldId(ProfileFields), DuplicateFieldId(ProfileFields) = '');
  Check('every map field has its own id: ' + DuplicateFieldId(MapFields), DuplicateFieldId(MapFields) = '');
  Check('every server field has its own id: ' + DuplicateFieldId(ServerFields), DuplicateFieldId(ServerFields) = '');
  WriteLn('       SizeOf(TMapProfile) = ', SizeOf(TMapProfile), ', fields: ', Length(MapFields));
  WriteLn('       SizeOf(TServerRecords) = ', SizeOf(TServerRecords), ', fields: ', Length(ServerFields));

  { the registries: one id and one place per field, and the fields added last where they belong }
  Check('no two profile ids share a field: ' + DuplicateOffset(ProfileFields), DuplicateOffset(ProfileFields) = '');
  Check('no two map ids share a field: ' + DuplicateOffset(MapFields), DuplicateOffset(MapFields) = '');
  Check('no two server ids share a field: ' + DuplicateOffset(ServerFields), DuplicateOffset(ServerFields) = '');
  Check('every field lies inside its record', (FieldOutside(ProfileFields, SizeOf(TPlayerProfile)) = '') and
    (FieldOutside(MapFields, SizeOf(TMapProfile)) = '') and (FieldOutside(ServerFields, SizeOf(TServerRecords)) = ''));
  Check('healing fields of the profile (429-431)',
    FieldIs(ProfileFields, 429, @P1, @P1.HealRegen, fkDouble, mkSum, True) and
    FieldIs(ProfileFields, 430, @P1, @P1.HealKits, fkDouble, mkSum, True) and
    FieldIs(ProfileFields, 431, @P1, @P1.HealKitCount, fkInt32, mkSum, True));
  Check('healing field of the map (245)', FieldIs(MapFields, 245, @M1, @M1.HealRegen, fkDouble, mkSum, True));
  Ok := True;
  for i := 1 to SPREE_MAX_KILLS do
    if not FieldIs(ProfileFields, 600 + i, @P1, @P1.SpreeLives[i], fkInt32, mkSum, True) then
      Ok := False;
  Check('kill streaks by length (601-650): counters, added up on a merge, cleared by a reset', Ok);
  Ok := True;
  for i := 0 to KIT_KINDS - 1 do
    if not FieldIs(ProfileFields, 651 + i, @P1, @P1.KitPickups[i], fkInt32, mkSum, True) then
      Ok := False;
  Check('kits picked up by kind (651-657): counters, added up on a merge, cleared by a reset', Ok);
  Check('the kinds of kit in the order of their ids', (KitKind(KIT_MEDICAL) = 0) and (KitKind(KIT_GRENADE) = 1) and
    (KitKind(KIT_CLUSTER) = 2) and (KitKind(KIT_VEST) = 3) and (KitKind(KIT_BERSERK) = 4) and (KitKind(KIT_PREDATOR) = 5) and
    (KitKind(KIT_FLAMER) = 6) and (KitKind(15) = -1) and (KitKind(23) = -1) and (KitKind(0) = -1));
  Ok := (MergeOf(ProfileFields, 356) = mkMax) and (MergeOf(ProfileFields, 357) = mkMax) and
    (MergeOf(ProfileFields, 358) = mkMax) and (MergeOf(ProfileFields, 400) = mkMax) and
    (MergeOf(ProfileFields, 411) = mkMax) and (MergeOf(ProfileFields, 423) = mkMax) and
    (MergeOf(ProfileFields, 8) = mkMax) and (MergeOf(ProfileFields, 378) = mkMinPos) and
    (MergeOf(ProfileFields, 403) = mkMinPos);
  for i := 0 to WSLOT_COUNT - 1 do
    if MergeOf(ProfileFields, 1000 + i * 16 + 12) <> mkMax then
      Ok := False;
  Check('records merge by the larger value, best times by the smaller one', Ok);
  Ok := True;
  for i := 0 to High(ProfileFields) do
  begin
    { identity and account (ids below 40), names, switches and lists: never reset, kept on a merge
      (the last visit takes the later date) }
    if (ProfileFields[i].Id < 40) or
       (ProfileFields[i].Kind in [fkString, fkBool, fkAliases, fkTrusted, fkBadges, fkAchievements]) then
    begin
      if ProfileFields[i].Stat then
        Ok := False;
      if (ProfileFields[i].Merge <> mkKeep) and (ProfileFields[i].Id <> 8) then
        Ok := False;
    end;
    { the ratings are kept on a merge }
    if (ProfileFields[i].Id >= 1400) and (ProfileFields[i].Id < 1450) and (ProfileFields[i].Merge <> mkKeep) then
      Ok := False;
  end;
  for i := 0 to High(ServerFields) do
    if ServerFields[i].Stat or (ServerFields[i].Merge <> mkKeep) then
      Ok := False;
  Check('identity, account, settings and ratings are kept', Ok);

  ClearProfile(P1);
  Check('empty profile encodes to nothing', EncodeProfile(P1) = '');
  Check('empty profile decodes', DecodeProfile('', P2) and (FirstDifference(@P1, @P2, ProfileFields) = -1));

  Ok := True;
  for i := 1 to 300 do
  begin
    ClearProfile(P1);
    FillRandom(@P1, ProfileFields);
    Data := EncodeProfile(P1);
    if not DecodeProfile(Data, P2) then
    begin
      Ok := False;
      WriteLn('       decode failed at ', i);
      Break;
    end;
    Diff := FirstDifference(@P1, @P2, ProfileFields);
    if Diff >= 0 then
    begin
      Ok := False;
      WriteLn('       field ', Diff, ' differs at ', i);
      Break;
    end;
    if EncodeProfile(P2) <> Data then
    begin
      Ok := False;
      WriteLn('       re-encode differs at ', i);
      Break;
    end;
  end;
  Check('profile roundtrip x300', Ok);

  ClearProfile(P1);
  FillRandom(@P1, ProfileFields);
  Data := EncodeProfile(P1);
  Data2 := Data + #$E8#$FD#1 + #1#2#3#4 + #$E7#$FD#7 + #3#0#0#0 + 'xyz';
  Check('unknown ids are skipped', DecodeProfile(Data2, P2) and (FirstDifference(@P1, @P2, ProfileFields) = -1));

  Crashes := 0;
  for Cut := 0 to Length(Data) - 1 do
  try
    DecodeProfile(Copy(Data, 1, Cut), P2);
  except
    Inc(Crashes);
  end;
  Check('truncated records never raise', Crashes = 0);
  Check('truncated record detected', not DecodeProfile(Copy(Data, 1, Length(Data) - 3), P2));
  Bad := Data;
  Bad[3] := #99;
  Check('unknown wire type rejected', not DecodeProfile(Bad, P2));

  Crashes := 0;
  for i := 1 to 20000 do
  begin
    SetLength(Bad, Random(200));
    for Cut := 1 to Length(Bad) do
      Bad[Cut] := AnsiChar(Random(256));
    try
      DecodeProfile(Bad, P2);
      DecodeMap(Bad, M2);
      DecodeServer(Bad, S2);
      DecodeSeason(Bad, A2);
    except
      Inc(Crashes);
    end;
  end;
  Check('fuzzed input never raises', Crashes = 0);

  ClearMap(M1);
  FillRandom(@M1, MapFields);
  Check('map roundtrip', DecodeMap(EncodeMap(M1), M2) and (FirstDifference(@M1, @M2, MapFields) = -1));
  ClearServer(S1);
  FillRandom(@S1, ServerFields);
  Check('server roundtrip', DecodeServer(EncodeServer(S1), S2) and (FirstDifference(@S1, @S2, ServerFields) = -1));

  A1.Id := 3;
  A1.StartDate := 46000;
  A1.EndDate := 46030;
  SetLength(A1.Entries, 50);
  for i := 0 to 49 do
  begin
    A1.Entries[i].Place := i + 1;
    A1.Entries[i].ProfileId := 1000 + i;
    A1.Entries[i].Name := 'Player' + IntToStr(i);
    A1.Entries[i].Points := 2000 - i;
    A1.Entries[i].SeasonPoints := 500 - i;
    A1.Entries[i].Kills := i * 3;
    A1.Entries[i].Deaths := i;
    A1.Entries[i].Caps := i div 2;
    A1.Entries[i].Wins := i div 3;
    A1.Entries[i].TimePlayed := i * 3600;
    A1.Entries[i].Rating := 1500.5 + i;
  end;
  Ok := DecodeSeason(EncodeSeason(A1), A2) and (A2.Id = 3) and (A2.StartDate = 46000) and
    (A2.EndDate = 46030) and (Length(A2.Entries) = 50);
  if Ok then
    for i := 0 to 49 do
      if (A2.Entries[i].Name <> A1.Entries[i].Name) or (A2.Entries[i].Rating <> A1.Entries[i].Rating) or
         (A2.Entries[i].TimePlayed <> A1.Entries[i].TimePlayed) or (A2.Entries[i].Place <> A1.Entries[i].Place) then
        Ok := False;
  Check('season roundtrip', Ok);

  ClearProfile(P1);
  ClearProfile(P3);
  P1.Kills := 10;
  P3.Kills := 5;
  P1.Points := 1200;
  P3.Points := 900;
  P1.MaxKillStreak := 7;
  P3.MaxKillStreak := 12;
  P3.BestTTKTicks := 30;
  P1.FastestCapSeconds := 12.5;
  P3.FastestCapSeconds := 9.25;
  P1.Weapons[WEP_AK74].Kills := 3;
  P3.Weapons[WEP_AK74].Kills := 4;
  P1.ActiveName := 'Keep';
  P3.ActiveName := 'Other';
  SetLength(P1.OtherNames, 1);
  FillChar(P1.OtherNames[0], SizeOf(TOtherData), 0);
  SetOtherDataString(P1.OtherNames[0], 'Dominik');
  P1.OtherNames[0].LoginCount := 2;
  SetLength(P3.OtherNames, 2);
  FillChar(P3.OtherNames[0], SizeOf(TOtherData), 0);
  FillChar(P3.OtherNames[1], SizeOf(TOtherData), 0);
  SetOtherDataString(P3.OtherNames[0], 'dominik');
  P3.OtherNames[0].LoginCount := 3;
  SetOtherDataString(P3.OtherNames[1], 'Alt');
  P1.TopVictims[0].TargetPlayerID := 5;
  P1.TopVictims[0].KillCount := 4;
  P3.TopVictims[0].TargetPlayerID := 6;
  P3.TopVictims[0].KillCount := 9;
  P3.TopVictims[1].TargetPlayerID := 5;
  P3.TopVictims[1].KillCount := 1;
  P1.KitPickups[0] := 2;
  P3.KitPickups[0] := 3;
  P3.KitPickups[6] := 4;
  MergeProfileInto(P1, P3, 1000);
  Check('merge sums counters', (P1.Kills = 15) and (P1.Weapons[WEP_AK74].Kills = 7));
  Check('merge sums the kits picked up', (P1.KitPickups[0] = 5) and (P1.KitPickups[6] = 4) and (KitsPickedUp(P1) = 9));
  Check('merge keeps point gains', P1.Points = 1100);
  Check('merge max / min-positive', (P1.MaxKillStreak = 12) and (P1.BestTTKTicks = 30) and SameValue(P1.FastestCapSeconds, 9.25));
  Check('merge keeps identity', P1.ActiveName = 'Keep');
  Check('merge dedupes aliases', (Length(P1.OtherNames) = 2) and (P1.OtherNames[0].LoginCount = 5));
  Check('merge nemesis lists', (P1.TopVictims[0].TargetPlayerID = 6) and (P1.TopVictims[0].KillCount = 9) and
    (P1.TopVictims[1].TargetPlayerID = 5) and (P1.TopVictims[1].KillCount = 5));

  ClearProfile(P1);
  FillRandom(@P1, ProfileFields);
  P1.ID := 77;
  P1.ActiveName := 'Name';
  P1.PassHash := 'hash';
  P1.Email := 'a@b.pl';
  P1.RegisterTime := 45000;
  P1.Kills := 5;
  P1.Weapons[2].Kills := 9;
  ResetProfileStats(P1);
  Check('reset keeps account', (P1.ID = 77) and (P1.ActiveName = 'Name') and (P1.PassHash = 'hash') and
    (P1.Email = 'a@b.pl') and (P1.RegisterTime = 45000));
  Check('reset clears stats', (P1.Kills = 0) and (P1.Weapons[2].Kills = 0) and (P1.Points = 0));

  ClearProfile(P1);
  FillRandom(@P1, ProfileFields);
  P1.DisplayHUD := True;
  P1.NoTrustedDevices := True;
  P1.EmailVerified := True;
  P1.PassSalt := 'salt';
  P1.PassIter := 1234;
  P1.LoginFailCount := 2;
  P1.LastPlayedTime := 45100;
  P1.LastDayKey := 45100;
  P1.SeasonId := 4;
  P1.HealRegen := 50;
  P1.HealKits := 150;
  P1.HealKitCount := 1;
  P1.KitPickups[2] := 7;
  SetLength(P1.OtherNames, 2);
  SetLength(P1.TrustedDevices, 1);
  P1.TrustedDevices[0].HWID := 'HW1';
  SetLength(P1.Badges, 1);
  SetLength(P1.Achievements, 3);
  Names := Length(P1.OtherNames);
  Trusted := Length(P1.TrustedDevices);
  Badges := Length(P1.Badges);
  Ach := Length(P1.Achievements);
  ResetProfileStats(P1);
  Check('reset keeps settings, the account and the lists', P1.DisplayHUD and P1.NoTrustedDevices and P1.EmailVerified and
    (P1.PassSalt = 'salt') and (P1.PassIter = 1234) and (P1.LoginFailCount = 2) and (P1.LastPlayedTime = 45100) and
    (P1.LastDayKey = 45100) and (P1.SeasonId = 4) and (Length(P1.OtherNames) = Names) and
    (Length(P1.TrustedDevices) = Trusted) and (P1.TrustedDevices[0].HWID = 'HW1') and (Length(P1.Badges) = Badges) and
    (Length(P1.Achievements) = Ach));
  Check('reset clears the healing', (P1.HealRegen = 0) and (P1.HealKits = 0) and (P1.HealKitCount = 0));
  Check('reset clears the kits picked up', KitsPickedUp(P1) = 0);

  { the kill streaks by length: the counts of the array, the five counters of the fixed levels from
    before it, never fewer than a longer streak, and one below the best streak }
  ClearProfile(P1);
  P1.SpreeKills := 40;
  P1.RampageKills := 9;
  P1.GodlikeKills := 1;
  P1.MaxKillStreak := 27;
  P1.SpreeLives[3] := 55;
  P1.SpreeLives[5] := 12;
  P1.SpreeLives[6] := 11;
  Check('streaks by length: the array, the counters of before and the longer streaks',
    (SpreeLivesAt(P1, 3) = 55) and (SpreeLivesAt(P1, 4) = 40) and (SpreeLivesAt(P1, 5) = 40) and
    (SpreeLivesAt(P1, 6) = 11) and (SpreeLivesAt(P1, 7) = 9) and (SpreeLivesAt(P1, 10) = 9) and
    (SpreeLivesAt(P1, 11) = 1) and (SpreeLivesAt(P1, 25) = 1) and (SpreeLivesAt(P1, 27) = 1) and
    (SpreeLivesAt(P1, 28) = 0));
  Check('streaks by length: a length outside 1-50 reads the nearest one', (SpreeLivesAt(P1, 0) = 55) and
    (SpreeLivesAt(P1, -5) = 55) and (SpreeLivesAt(P1, 99) = 0));
  ClearProfile(P3);
  P3.SpreeLives[3] := 5;
  P3.SpreeLives[50] := 2;
  MergeProfileInto(P1, P3, 1000);
  Check('a merge adds up the streaks by length', (P1.SpreeLives[3] = 60) and (P1.SpreeLives[5] = 12) and
    (P1.SpreeLives[50] = 2) and (SpreeLivesAt(P1, 50) = 2));
  Check('a record keeps them', DecodeProfile(EncodeProfile(P1), P2) and (P2.SpreeLives[3] = 60) and (P2.SpreeLives[50] = 2) and
    (P2.SpreeLives[4] = 0));
  ResetProfileStats(P1);
  Check('a reset clears them, and the counters of before with them', (P1.SpreeLives[3] = 0) and (P1.SpreeLives[50] = 0) and
    (SpreeLivesAt(P1, 1) = 0));
  ClearProfile(PB);
  PB.SpreeLives[4] := 10;
  PR := PB;
  PR.SpreeLives[4] := 12;
  P1 := PB;
  P1.SpreeLives[4] := 13;
  Merge3Profile(P1, PB, PR);
  Check('three-way: the streaks by length of both servers add up', P1.SpreeLives[4] = 15);

  { a badge without a place takes the known place, and two accounts of one player are no rivals }
  ClearProfile(P1);
  ClearProfile(P3);
  P1.ID := 10;
  P3.ID := 11;
  P1.Points := 1000;
  P3.Points := 900;
  SetLength(P1.Badges, 1);
  P1.Badges[0].SeasonId := 3;
  P1.Badges[0].Place := 0;
  SetLength(P3.Badges, 1);
  P3.Badges[0].SeasonId := 3;
  P3.Badges[0].Place := 4;
  P1.TopVictims[0].TargetPlayerID := 11;
  P1.TopVictims[0].KillCount := 50;
  P1.TopVictims[1].TargetPlayerID := 7;
  P1.TopVictims[1].KillCount := 3;
  P3.TopNemeses[0].TargetPlayerID := 10;
  P3.TopNemeses[0].KillCount := 50;
  P3.TopNemeses[1].TargetPlayerID := 8;
  P3.TopNemeses[1].KillCount := 2;
  MergeProfileInto(P1, P3, 1000);
  Check('merge: a badge without a place takes the known one', (Length(P1.Badges) = 1) and (P1.Badges[0].Place = 4));
  Check('merge: the two accounts are not each other''s rivals', (P1.TopVictims[0].TargetPlayerID = 7) and
    (P1.TopVictims[1].TargetPlayerID = 0) and (P1.TopNemeses[0].TargetPlayerID = 8) and
    (P1.TopNemeses[1].TargetPlayerID = 0));
  Check('merge: points the merged account lost are lost', P1.Points = 900);

  { three-way merges: two servers change the same account, the database keeps both changes }
  ClearProfile(PB);
  PB.ID := 5;
  PB.ActiveName := 'Base';
  PB.Kills := 10;
  PB.Points := 1000;
  PB.MaxKillStreak := 5;
  PB.FastestCapSeconds := 12;
  PB.Weapons[3].Damage := 100;
  PB.DamageDealt := 100;
  PB.HealRegen := 20;
  PR := PB;
  PR.Kills := 13;
  PR.Points := 1010;
  PR.MaxKillStreak := 8;
  PR.FastestCapSeconds := 11;
  PR.Weapons[3].Damage := 130;
  PR.DamageDealt := 130;
  PR.HealRegen := 26;
  PR.Email := 'x@y.pl';
  P1 := PB;
  P1.ActiveName := 'Renamed';
  P1.DisplayHUD := True;
  P1.Kills := 12;
  P1.Points := 995;
  P1.MaxKillStreak := 7;
  P1.Weapons[3].Damage := 150;
  P1.DamageDealt := 150;
  P1.HealRegen := 30;
  Merge3Profile(P1, PB, PR);
  Check('three-way: the counters of both servers add up', (P1.Kills = 15) and SameValue(P1.Weapons[3].Damage, 180.0) and
    SameValue(P1.DamageDealt, 180.0) and SameValue(P1.HealRegen, 36.0) and (P1.Points = 1005));
  Check('three-way: records and best times', (P1.MaxKillStreak = 8) and SameValue(P1.FastestCapSeconds, 11.0));
  Check('three-way: a setting changed here and one changed there both stay', P1.DisplayHUD and
    (P1.Email = 'x@y.pl') and (P1.ActiveName = 'Renamed'));
  PB := P1;
  PR := P1;
  Inc(PR.Kills, 1);
  Inc(P1.Kills, 4);
  Merge3Profile(P1, PB, PR);
  Check('three-way: the next round loses nothing either', P1.Kills = 20);

  ClearMap(MB);
  MB.ID := 3;
  MB.MapName := 'ctf_Ash';
  MB.Kills := 100;
  MB.HealRegen := 10;
  SetLength(MB.Heat, 1);
  MB.Heat[0].Cell := 7;
  MB.Heat[0].Kills := 2;
  MR := MB;
  MR.Heat := Copy(MB.Heat);
  MR.Kills := 110;
  MR.HealRegen := 14;
  MR.Heat[0].Kills := 5;
  M1 := MB;
  M1.Heat := Copy(MB.Heat);
  M1.ID := 9;
  M1.Kills := 104;
  M1.HealRegen := 13;
  M1.Heat[0].Kills := 3;
  Merge3Map(M1, MB, MR);
  Check('three-way map: counters, heat cells, and the number stays this server''s', (M1.Kills = 114) and
    SameValue(M1.HealRegen, 17.0) and (Length(M1.Heat) = 1) and (M1.Heat[0].Kills = 6) and (M1.ID = 9));

  ClearServer(SB);
  SB.TotalMatches := 10;
  SB.HourlyActivity[5] := 100;
  SB.PeakOnlineCount := 12;
  SR := SB;
  SR.TotalMatches := 12;
  SR.HourlyActivity[5] := 130;
  SR.PeakOnlineCount := 15;
  S1 := SB;
  S1.TotalMatches := 11;
  S1.HourlyActivity[5] := 120;
  Merge3Server(S1, SB, SR);
  Check('three-way server: counters add up, the higher peak stays', (S1.TotalMatches = 13) and
    (S1.HourlyActivity[5] = 150) and (S1.PeakOnlineCount = 15));

  { three-way after a reset: a record that went down, or a best time that went up or was cleared,
    is a reset - the database's old value must not come back (Engine = mysql) }
  ClearProfile(PB);
  PB.ID := 5;
  PB.Kills := 40;
  PB.MaxKillStreak := 10;
  PB.LongestKillDistance := 300;
  PB.FastestCapSeconds := 12;
  PB.BestTTKTicks := 30;
  PB.ProtectionDays := 5;
  PB.Weapons[3].LongestKill := 250;
  PR := PB;
  PR.Kills := 42;
  P1 := PB;
  ResetProfileStats(P1);
  P1.Kills := 1;
  P1.MaxKillStreak := 3;
  Merge3Profile(P1, PB, PR);
  Check('three-way: a reset here stays (records, best times, protection days)', (P1.Kills = 3) and
    (P1.MaxKillStreak = 3) and (P1.LongestKillDistance = 0) and (P1.FastestCapSeconds = 0) and (P1.BestTTKTicks = 0) and
    (P1.ProtectionDays = 0) and (P1.Weapons[3].LongestKill = 0));
  P1 := PB;
  PR := PB;
  ResetProfileStats(PR);
  Merge3Profile(P1, PB, PR);
  Check('three-way: a reset on another server reaches this one', (P1.Kills = 0) and (P1.MaxKillStreak = 0) and
    (P1.LongestKillDistance = 0) and (P1.FastestCapSeconds = 0) and (P1.BestTTKTicks = 0) and (P1.ProtectionDays = 0));
  { a protection day the daily balance spent here, one earned on another server }
  P1 := PB;
  PR := PB;
  P1.ProtectionDays := 4;
  PR.ProtectionDays := 6;
  Merge3Profile(P1, PB, PR);
  Check('three-way: a protection day spent here comes off the database''s days', P1.ProtectionDays = 5);
  { the first start with the database: two accounts of one player, the larger number of days }
  ClearProfile(P3);
  P1 := PB;
  P1.ProtectionDays := 50;
  PR := PB;
  PR.ProtectionDays := 40;
  Merge3Profile(P1, P3, PR);
  Check('three-way: protection days of two accounts are not added up', P1.ProtectionDays = 50);
  P1 := PB;
  PR := PB;
  P1.MaxKillStreak := 11;
  PR.MaxKillStreak := 14;
  P1.FastestCapSeconds := 9;
  PR.FastestCapSeconds := 10;
  Merge3Profile(P1, PB, PR);
  Check('three-way: new records on both servers keep the better one', (P1.MaxKillStreak = 14) and
    SameValue(P1.FastestCapSeconds, 9.0));

  ClearMap(MB);
  MB.ID := 3;
  MB.MapName := 'ctf_Ash';
  MB.Kills := 50;
  MB.FastestCapSeconds := 8.5;
  MB.FastestCapHolder := 'Old';
  MR := MB;
  M1 := MB;
  ResetMapStats(M1);
  Merge3Map(M1, MB, MR);
  Check('three-way map: a reset here stays', (M1.Kills = 0) and (M1.FastestCapSeconds = 0) and (M1.FastestCapHolder = ''));
  M1 := MB;
  MR := MB;
  ResetMapStats(MR);
  Merge3Map(M1, MB, MR);
  Check('three-way map: a reset on another server reaches this one', (M1.Kills = 0) and (M1.FastestCapSeconds = 0) and
    (M1.FastestCapHolder = ''));

  { the server statistics reset here: the online peak and the days do not come back }
  ClearServer(SB);
  SB.PeakOnlineCount := 20;
  SB.PeakOnlineDurationSec := 600;
  SB.TotalMatches := 10;
  SetLength(SB.Daily, 2);
  SB.Daily[0].Day := 20260920;
  SB.Daily[0].Sessions := 30;
  SB.Daily[0].PeakOnline := 12;
  SB.Daily[1].Day := 20260921;
  SB.Daily[1].Sessions := 40;
  SB.Daily[1].PeakOnline := 20;
  SR := SB;
  SR.Daily := Copy(SB.Daily);
  SR.Daily[1].Sessions := 45;
  ClearServer(S1);
  SetLength(S1.Daily, 1);
  S1.Daily[0].Day := 20260921;
  S1.Daily[0].Sessions := 2;
  S1.Daily[0].PeakOnline := 3;
  Merge3Server(S1, SB, SR);
  Check('three-way server: a reset here stays (the peak and the days)', (S1.PeakOnlineCount = 0) and
    (S1.TotalMatches = 0) and (Length(S1.Daily) = 1) and (S1.Daily[0].Day = 20260921) and (S1.Daily[0].Sessions = 7) and
    (S1.Daily[0].PeakOnline = 3));
  S1 := SB;
  S1.Daily := Copy(SB.Daily);
  SR := SB;
  SR.Daily := nil;
  SR.PeakOnlineCount := 0;
  SR.PeakOnlineDurationSec := 0;
  SR.TotalMatches := 0;
  Merge3Server(S1, SB, SR);
  Check('three-way server: a reset on another server reaches this one', (S1.PeakOnlineCount = 0) and
    (S1.TotalMatches = 0) and (Length(S1.Daily) = 0));

  { the season: its number and its dates come from the same server, the higher number goes on }
  ClearServer(SB);
  ClearServer(S1);
  S1.SeasonId := 2;
  S1.SeasonStart := 46000;
  S1.SeasonEnd := 46030;
  ClearServer(SR);
  SR.SeasonId := 4;
  SR.SeasonStart := 46100;
  SR.SeasonEnd := 46130;
  Merge3Server(S1, SB, SR);
  Check('three-way server: the higher season goes on with its own dates', (S1.SeasonId = 4) and
    (S1.SeasonStart = 46100) and (S1.SeasonEnd = 46130));
  ClearServer(S1);
  S1.SeasonId := 5;
  S1.SeasonStart := 46200;
  S1.SeasonEnd := 46230;
  Merge3Server(S1, SB, SR);
  Check('three-way server: a higher season of this server goes in with its dates', (S1.SeasonId = 5) and
    (S1.SeasonStart = 46200) and (S1.SeasonEnd = 46230));

  { strings with zero bytes and at the 16-bit limit, and floats that are no numbers }
  ClearProfile(P1);
  P1.ActiveName := 'a'#0'b'#0;
  SetLength(Str, 65535);
  FillChar(Str[1], 65535, 'x');
  P1.ActiveHWID := Str;
  P1.ActiveIP := Str + 'yz';
  SetLength(P1.TrustedDevices, 1);
  P1.TrustedDevices[0].HWID := Str;
  Ok := DecodeProfile(EncodeProfile(P1), P2);
  Check('zero bytes and 65535 byte strings survive', Ok and (P2.ActiveName = 'a'#0'b'#0) and (P2.ActiveHWID = Str) and
    (Length(P2.TrustedDevices) = 1) and (P2.TrustedDevices[0].HWID = Str));
  Check('a longer string is cut at 65535 bytes and the record stays readable', Ok and (P2.ActiveIP = Str));
  Check('a NaN or an infinity in a record reads as 0', DecodeProfile(RawDouble(363, QWord($7FF8000000000000)) +
    RawDouble(364, QWord($7FF0000000000000)) + RawSingle(357, $7FC00000) + RawDouble(429, QWord($4059000000000000)), P2) and
    (P2.DamageDealt = 0) and (P2.DamageReceived = 0) and (P2.LongestKillDistance = 0) and (P2.HealRegen = 100));

  ClearProfile(P1);
  FillRandom(@P1, ProfileFields);
  T0 := MicroNow;
  for i := 1 to 20000 do
    Data := EncodeProfile(P1);
  WriteLn('       encode 20000 dense profiles: ', (MicroNow - T0) div 1000, ' ms, ', Length(Data), ' bytes each');
  T0 := MicroNow;
  for i := 1 to 20000 do
    DecodeProfile(Data, P2);
  WriteLn('       decode 20000 dense profiles: ', (MicroNow - T0) div 1000, ' ms');

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
