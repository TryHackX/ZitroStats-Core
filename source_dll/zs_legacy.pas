unit zs_legacy;

{ One-way importers for data written by ZitroStats 4.x. Source files are only read.

    accounts.bin / maps.bin   binary formats v1..v8 ('ZSTS'), fields appended per version
    accounts.db / maps.db     line based text format of the ScriptCore-only script
    server_records.ini        peak online, hourly activity and weapon matchups

  Fixes applied while importing:
  - kill distance: v8 stored pixels / 10 and v5..v7 raw pixels; both become the meters Soldat
    prints in the kill console (pixels / 14).
  - matchups: 4.x counted every kill a second time as "victim weapon 0".
  - duplicate or invalid ids get fresh ids above the highest valid one. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  SysUtils, Classes, StrUtils, zs_types, zs_fields, zs_fileio;

const
  LEGACY_MAGIC = $5A535453;
  LEGACY_MAX_VERSION = 8;

function LegacyWeaponSlot(OldIndex: LongInt): LongInt;
function LegacyLoadAccountsBin(const Path: AnsiString; var Profiles: TProfilePtrArray;
  out Count, Version: LongInt; out Error: AnsiString): Boolean;
function LegacyLoadMapsBin(const Path: AnsiString; var Maps: TMapProfileArray;
  out Count, Version: LongInt; out Error: AnsiString): Boolean;
function LegacyImportAccountsDb(const Path: AnsiString; var Profiles: TProfilePtrArray;
  out Count: LongInt; out Error: AnsiString): Boolean;
function LegacyImportMapsDb(const Path: AnsiString; var Maps: TMapProfileArray;
  out Count: LongInt; out Error: AnsiString): Boolean;
function LegacyImportServerRecords(const Path: AnsiString; var S: TServerRecords;
  out PhantomsRemoved: Int64): Boolean;
procedure LegacyAssignProfileIds(var Profiles: TProfilePtrArray; Count: LongInt;
  out NextId, Reassigned: LongInt);
procedure LegacyAssignMapIds(var Maps: TMapProfileArray; Count: LongInt;
  out NextId, Reassigned: LongInt);
function LegacyFloat(const S: AnsiString; Def: Double): Double;
{ What 4.x kept only per weapon or only as a total, derived for 5.x, which keeps both and adds to
  both: the damage dealt and taken of an account is at least what its weapons dealt and took (4.x
  counted the weapons from format v3 on, the totals only from v5 and v6), and the longest Barrett
  kill is the record of the Barrett. True when something changed. Safe to run on any account:
  numbers of 5.x already satisfy it. }
function LegacyDeriveTotals(var P: TPlayerProfile): Boolean;

implementation

const
  MAX_SANE_ID = 10000000;

type
  TBinReader = record
    Data: AnsiString;
    Base: PAnsiChar;
    Pos: LongInt;
    Ok: Boolean;
  end;

function LegacyWeaponSlot(OldIndex: LongInt): LongInt;
begin
  case OldIndex of
    0..16: Result := OldIndex;
    30: Result := WSLOT_M2;
    else Result := -1;
  end;
end;

function LegacyFloat(const S: AnsiString; Def: Double): Double;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  Result := StrToFloatDef(StringReplace(Trim(S), ',', '.', [rfReplaceAll]), Def, FS);
end;

{ ---------------- bounds checked binary reader ---------------- }

procedure BRInit(out R: TBinReader; const Data: AnsiString);
begin
  R.Data := Data;
  R.Base := PAnsiChar(R.Data);
  R.Pos := 0;
  R.Ok := True;
end;

function BRNeed(var R: TBinReader; N: Int64): Boolean; inline;
begin
  if (N < 0) or (R.Pos + N > Length(R.Data)) then
    R.Ok := False;
  Result := R.Ok;
end;

procedure BRRaw(var R: TBinReader; Dst: Pointer; N: LongInt);
begin
  if not BRNeed(R, N) then
  begin
    FillChar(Dst^, N, 0);
    Exit;
  end;
  Move((R.Base + R.Pos)^, Dst^, N);
  Inc(R.Pos, N);
end;

function BRU8(var R: TBinReader): Byte;
begin
  Result := 0;
  BRRaw(R, @Result, 1);
end;

function BRU16(var R: TBinReader): Word;
begin
  Result := 0;
  BRRaw(R, @Result, 2);
end;

function BRI32(var R: TBinReader): LongInt;
begin
  Result := 0;
  BRRaw(R, @Result, 4);
end;

function BRI64(var R: TBinReader): Int64;
begin
  Result := 0;
  BRRaw(R, @Result, 8);
end;

{ Floats are validated on their bit pattern: loading a signalling NaN into the FPU could raise. }
function BRF32(var R: TBinReader): Single;
var
  Bits: LongWord;
begin
  Bits := 0;
  BRRaw(R, @Bits, 4);
  if (Bits and $7F800000) = $7F800000 then
    Bits := 0;
  Move(Bits, Result, 4);
end;

function BRF64(var R: TBinReader): Double;
var
  Bits: QWord;
begin
  Bits := 0;
  BRRaw(R, @Bits, 8);
  if (Bits and QWord($7FF0000000000000)) = QWord($7FF0000000000000) then
    Bits := 0;
  Move(Bits, Result, 8);
end;

function BRStr(var R: TBinReader): AnsiString;
var
  L: Word;
begin
  Result := '';
  L := BRU16(R);
  if (L = 0) or not BRNeed(R, L) then
    Exit;
  SetLength(Result, L);
  Move((R.Base + R.Pos)^, Result[1], L);
  Inc(R.Pos, L);
end;

{ ---------------- accounts.bin ---------------- }

procedure ReadOtherArray(var R: TBinReader; var Arr: TOtherDataArray);
var
  N, j: LongInt;
begin
  SetLength(Arr, 0);
  N := BRU16(R);
  if (N = 0) or not BRNeed(R, Int64(N) * SizeOf(TOtherData)) then
    Exit;
  SetLength(Arr, N);
  for j := 0 to N - 1 do
  begin
    BRRaw(R, @Arr[j], SizeOf(TOtherData));
    Arr[j].DataString[MAX_STRING_LEN - 1] := #0;
  end;
end;

procedure ReadOldWeapons(var R: TBinReader; Version: LongInt; var P: TPlayerProfile);
var
  w, s, Kills, Deaths, Shots, Hits, Headshots: LongInt;
  Damage, DamageRecv: Single;
  TimeUsed: Int64;
begin
  for w := 0 to 30 do
  begin
    Kills := BRI32(R);
    Deaths := BRI32(R);
    Shots := BRI32(R);
    Hits := BRI32(R);
    Headshots := BRI32(R);
    Damage := BRF32(R);
    DamageRecv := 0;
    TimeUsed := 0;
    if Version >= 6 then
      DamageRecv := BRF32(R);
    if Version >= 4 then
      TimeUsed := BRI64(R);
    s := LegacyWeaponSlot(w);
    if s < 0 then
      Continue;
    if Shots < Hits then
      Shots := Hits;
    P.Weapons[s].Kills := Kills;
    P.Weapons[s].Deaths := Deaths;
    P.Weapons[s].Shots := Shots;
    P.Weapons[s].Hits := Hits;
    P.Weapons[s].Headshots := Headshots;
    P.Weapons[s].Damage := Damage;
    P.Weapons[s].DamageReceived := DamageRecv;
    P.Weapons[s].TimeUsedSeconds := TimeUsed;
  end;
end;

procedure SynthesizeOldWeapons(var P: TPlayerProfile);
begin
  { v1 and v2 had no weapon table; 4.x rebuilt a partial one from the special counters }
  P.Weapons[WEP_M79].Shots := P.M79Shots;
  P.Weapons[WEP_M79].Hits := P.M79HurtsEnemy;
  P.Weapons[WEP_KNIFE].Shots := P.KnivesThrows;
  P.Weapons[WEP_KNIFE].Hits := P.KnivesThrowsHitsEnemy + P.KnivesStabsEnemy;
  P.Weapons[WEP_CHAINSAW].Hits := P.ChainsawHurtsEnemy;
  P.Weapons[WEP_LAW].Shots := P.M72LAWShots;
  P.Weapons[WEP_LAW].Hits := P.M72LAWHurtsEnemy;
  P.Weapons[WEP_FLAMER].Shots := P.FlamethrowerShots;
  P.Weapons[WEP_FLAMER].Hits := P.FlamethrowerHitsEnemy;
  P.Weapons[WEP_BOW].Kills := P.RamboMode.KillsByBow;
  P.Weapons[WEP_BOW2].Shots := P.BowFlamedArrowsShots;
  P.Weapons[WEP_BOW2].Hits := P.BowFlamedArrowsHurtsEnemy;
  P.Weapons[WSLOT_M2].Hits := P.M2MGHitsEnemy;
end;

{ a little slack: 4.x summed the weapons in single precision, and a total that is off by a
  rounding step only is not rewritten }
function BelowSum(Total, Sum: Double): Boolean;
var
  Slack: Double;
begin
  Slack := Total * 0.001;
  if Slack < 1 then
    Slack := 1;
  Result := Sum > Total + Slack;
end;

function LegacyDeriveTotals(var P: TPlayerProfile): Boolean;
var
  s, Barrett: LongInt;
  Dealt, Received: Double;
begin
  Result := False;
  Dealt := 0;
  Received := 0;
  for s := 0 to WSLOT_COUNT - 1 do
  begin
    Dealt := Dealt + P.Weapons[s].Damage;
    Received := Received + P.Weapons[s].DamageReceived;
  end;
  if BelowSum(P.DamageDealt, Dealt) then
  begin
    P.DamageDealt := Dealt;
    Result := True;
  end;
  if BelowSum(P.DamageReceived, Received) then
  begin
    P.DamageReceived := Received;
    Result := True;
  end;
  Barrett := LegacyWeaponSlot(WEP_BARRETT);
  if P.LongestBarrettDistance > P.Weapons[Barrett].LongestKill then
  begin
    P.Weapons[Barrett].LongestKill := P.LongestBarrettDistance;
    Result := True;
  end;
end;

function SaneDistance(V: Double): Single;
begin
  if (V < 0) or (V > 100000) then
    Result := 0
  else
    Result := V;
end;

procedure ConvertDistances(var P: TPlayerProfile; Version: LongInt);
var
  F: Double;
begin
  if Version >= 8 then
    F := 10.0 / PIXELS_PER_METER
  else
    F := 1.0 / PIXELS_PER_METER;
  P.LongestKillDistance := SaneDistance(P.LongestKillDistance * F);
  P.LongestBarrettDistance := SaneDistance(P.LongestBarrettDistance * F);
  { 4.x shrank values above 150 on every load, sometimes only one of the two }
  if P.LongestBarrettDistance > P.LongestKillDistance then
    P.LongestKillDistance := P.LongestBarrettDistance;
  if (P.KillDistanceCount > 0) and (P.TotalKillDistance > 0) then
    P.TotalKillDistance := P.TotalKillDistance * F
  else
  begin
    P.KillDistanceCount := 0;
    P.TotalKillDistance := 0;
  end;
end;

procedure ReadProfile(var R: TBinReader; Version: LongInt; var P: TPlayerProfile);
var
  i, s: LongInt;
  Skipped: TOtherDataArray;
begin
  P.ID := BRI32(R);
  P.ActiveName := BRStr(R);
  P.ActiveSteam := BRStr(R);
  P.ActiveHWID := BRStr(R);
  P.ActiveIP := BRStr(R);
  P.DisplayHUD := BRU8(R) <> 0;
  P.ProtectionDays := BRI32(R);
  P.ActivityForProtectDays := BRI32(R);
  P.TimePlayed := BRI64(R);
  P.TimeAlive := BRI64(R);
  P.TimeDeath := BRI64(R);
  P.TimeOnSpectator := BRI64(R);
  P.RegisterTime := BRF64(R);
  P.LastPlayedTime := BRF64(R);
  ReadOtherArray(R, P.OtherNames);
  { former SteamIDs, HWIDs and IPs are not kept since 5.1 }
  ReadOtherArray(R, Skipped);
  ReadOtherArray(R, Skipped);
  ReadOtherArray(R, Skipped);

  P.Points := BRI32(R);
  P.Kills := BRI32(R);
  P.Deaths := BRI32(R);
  P.Selfkills := BRI32(R);
  P.Assist := BRI32(R);
  P.Teamkills := BRI32(R);
  P.DeathsByFriendly := BRI32(R);
  P.PosthumousKills := BRI32(R);
  P.RevengeKills := BRI32(R);
  P.AvengerKills := BRI32(R);
  P.SaviorKills := BRI32(R);

  P.FlagsScore := BRI32(R);
  P.AlphaScore := BRI32(R);
  P.AlphaTeamScore := BRI32(R);
  P.BravoScore := BRI32(R);
  P.BravoTeamScore := BRI32(R);
  P.FlagsReturn := BRI32(R);
  P.FlagsGrab := BRI32(R);
  P.FlagsDrop := BRI32(R);
  P.FlagsThrown := BRI32(R);
  P.FlaggerKills := BRI32(R);
  P.FlaggerKillsAssist := BRI32(R);
  P.SaviorFlaggerKills := BRI32(R);
  P.FlaggerTeamkills := BRI32(R);
  P.KillsWhenHaveFlag := BRI32(R);
  P.TeamkillsWhenHaveFlag := BRI32(R);
  P.TimeHoldingFlags := BRI32(R);

  P.Wins := BRI32(R);
  P.Loses := BRI32(R);
  P.Draws := BRI32(R);
  P.AlphaWins := BRI32(R);
  P.AlphaLoses := BRI32(R);
  P.BravoWins := BRI32(R);
  P.BravoLoses := BRI32(R);
  P.CharlieWins := BRI32(R);
  P.CharlieLoses := BRI32(R);
  P.DeltaWins := BRI32(R);
  P.DeltaLoses := BRI32(R);
  P.RoundsWins := BRI32(R);
  P.RoundsLose := BRI32(R);
  P.RoundsAlphaWins := BRI32(R);
  P.RoundsAlphaLoses := BRI32(R);
  P.RoundsBravoWins := BRI32(R);
  P.RoundsBravoLoses := BRI32(R);
  P.RoundsCharlieWins := BRI32(R);
  P.RoundsCharlieLoses := BRI32(R);
  P.RoundsDeltaWins := BRI32(R);
  P.RoundsDeltaLoses := BRI32(R);

  P.Shots := BRI32(R);
  P.ShotsHits := BRI32(R);
  P.ShotsHitsFriendly := BRI32(R);
  P.ShotsHitsByFriendly := BRI32(R);
  P.ShotsHitsSelf := BRI32(R);
  P.ShotsHitsHead := BRI32(R);
  P.ShotsHitsBody := BRI32(R);
  P.ShotsHitsLeg := BRI32(R);
  P.ShotsHitsFriendlyHead := BRI32(R);
  P.ShotsHitsFriendlyBody := BRI32(R);
  P.ShotsHitsFriendlyLeg := BRI32(R);
  P.ShotsHitsByFriendlyHead := BRI32(R);
  P.ShotsHitsByFriendlyBody := BRI32(R);
  P.ShotsHitsByFriendlyLeg := BRI32(R);
  P.ShotsHitsSelfHead := BRI32(R);
  P.ShotsHitsSelfBody := BRI32(R);
  P.ShotsHitsSelfLeg := BRI32(R);
  if P.Shots < P.ShotsHits then
    P.Shots := P.ShotsHits;

  P.KnivesThrows := BRI32(R);
  P.KnivesThrowsHitsEnemy := BRI32(R);
  P.KnivesThrowsHitsSelf := BRI32(R);
  P.KnivesThrowsHitsFriends := BRI32(R);
  P.KnivesThrowsHitsByFriends := BRI32(R);
  P.KnivesStabsEnemy := BRI32(R);
  P.KnivesStabsFriendly := BRI32(R);
  P.KnivesStabsByFriendly := BRI32(R);
  P.ChainsawTimeUsedSeconds := BRI32(R);
  P.ChainsawHurtsEnemy := BRI32(R);
  P.ChainsawHurtsFriendly := BRI32(R);
  P.ChainsawHurtsByFriendly := BRI32(R);
  P.FlamethrowerShots := BRI32(R);
  P.FlamethrowerHitsEnemy := BRI32(R);
  P.FlamethrowerHitsFriendly := BRI32(R);
  P.FlamethrowerHitsSelf := BRI32(R);
  P.FlamethrowerHitsByFriendly := BRI32(R);
  P.HandsHurtsEnemy := BRI32(R);
  P.HandsHurtsFriendly := BRI32(R);
  P.NadesThrows := BRI32(R);
  P.NadeHurtsEnemy := BRI32(R);
  P.NadeHurtsFriendly := BRI32(R);
  P.NadeHurtsSelf := BRI32(R);
  P.NadeHurtsByFriendly := BRI32(R);
  P.ClusterNadesThrows := BRI32(R);
  P.ClusterNadesHurtsEnemy := BRI32(R);
  P.ClusterNadesHurtsFriendly := BRI32(R);
  P.ClusterNadesHurtsSelf := BRI32(R);
  P.ClusterNadesHurtsByFriendly := BRI32(R);
  P.M79Shots := BRI32(R);
  P.M79HurtsEnemy := BRI32(R);
  P.M79HurtsFriendly := BRI32(R);
  P.M79HurtsSelf := BRI32(R);
  P.M79HurtsByFriendly := BRI32(R);
  P.M72LAWShots := BRI32(R);
  P.M72LAWHurtsEnemy := BRI32(R);
  P.M72LAWHurtsFriendly := BRI32(R);
  P.M72LAWHurtsSelf := BRI32(R);
  P.M72LAWHurtsByFriendly := BRI32(R);
  P.BowFlamedArrowsShots := BRI32(R);
  P.BowFlamedArrowsHurtsEnemy := BRI32(R);
  P.BowFlamedArrowsHurtsFriendly := BRI32(R);
  P.BowFlamedArrowsHurtsSelf := BRI32(R);
  P.BowFlamedArrowsHurtsByFriendly := BRI32(R);
  P.HandsHurtsByFriendly := BRI32(R);
  P.M2MGHitsEnemy := BRI32(R);
  P.M2MGHitsFriendly := BRI32(R);
  P.M2MGHitsByFriendly := BRI32(R);

  P.RamboMode.KillRamboCount := BRI32(R);
  P.RamboMode.KillsByBow := BRI32(R);
  P.RamboMode.GetsBow := BRI32(R);
  P.RamboMode.DropBow := BRI32(R);
  P.RamboMode.KillsWhenNoRambo := BRI32(R);
  P.RamboMode.DeathsWhenNoRambo := BRI32(R);
  P.RamboMode.TimeWithBow := BRI64(R);
  P.RamboMode.TimeWithoutBow := BRI64(R);

  P.HTFMode.PointsScored := BRI32(R);
  P.HTFMode.TeamPointsScored := BRI32(R);
  P.HTFMode.AlphaPointsScored := BRI32(R);
  P.HTFMode.BravoPointsScored := BRI32(R);
  P.HTFMode.AlphaTeamPointsScored := BRI32(R);
  P.HTFMode.BravoTeamPointsScored := BRI32(R);
  P.HTFMode.TimeWhenHaveFlag := BRI64(R);
  P.HTFMode.TimeWhenTeamHaveFlag := BRI64(R);
  P.HTFMode.TimeWhenNotHaveFlag := BRI64(R);
  P.HTFMode.TimeWhenTeamNotHaveFlag := BRI64(R);

  P.PointmatchMode.ExtraPoints := BRI32(R);
  P.PointmatchMode.Multi.DOUBLE_KILL := BRI32(R);
  P.PointmatchMode.Multi.TRIPLE_KILL := BRI32(R);
  P.PointmatchMode.Multi.MULTI_KILL := BRI32(R);
  P.PointmatchMode.Multi.MULTI_KILL_X2 := BRI32(R);
  P.PointmatchMode.Multi.SERIAL_KILL := BRI32(R);
  P.PointmatchMode.Multi.INSANE_KILLS := BRI32(R);
  P.PointmatchMode.Multi.GIMME_MORE := BRI32(R);
  P.PointmatchMode.Multi.MASTA_KILLA := BRI32(R);
  P.PointmatchMode.Multi.STOP_IT := BRI32(R);
  P.PointmatchMode.Multi.MERCY := BRI32(R);
  P.PointmatchMode.Multi.CHEATER := BRI32(R);

  if Version >= 2 then
  begin
    P.LastStand := BRI32(R);
    P.ClutchesWon := BRI32(R);
    P.DominatingCount := BRI32(R);
    P.RevengeFeats := BRI32(R);
    P.AdvanceRoundsWon := BRI32(R);
    P.AdvanceRoundsPlayed := BRI32(R);
  end;

  if Version >= 3 then
    ReadOldWeapons(R, Version, P)
  else
    SynthesizeOldWeapons(P);

  if Version >= 5 then
  begin
    P.MaxKillStreak := BRI32(R);
    P.LongestKillDistance := BRF32(R);
    P.LongestBarrettDistance := BRF32(R);
    P.TotalKillDistance := BRF64(R);
    P.KillDistanceCount := BRI64(R);
    P.FirstBloodCount := BRI32(R);
    P.FirstDamageCount := BRI32(R);
    P.DamageDealt := BRF64(R);
    P.DamageReceived := BRF64(R);
    P.DamageFriendly := BRF64(R);
    P.DamageFriendlyReceived := BRF64(R);
    for i := 0 to 2 do
    begin
      P.TopVictims[i].TargetPlayerID := BRI32(R);
      P.TopVictims[i].KillCount := BRI32(R);
    end;
    for i := 0 to 2 do
    begin
      P.TopNemeses[i].TargetPlayerID := BRI32(R);
      P.TopNemeses[i].KillCount := BRI32(R);
    end;
    ConvertDistances(P, Version);
  end;

  if Version >= 7 then
  begin
    P.ProneKills := BRI32(R);
    P.JetFlyTimeSeconds := BRI64(R);
    P.CampKills := BRI32(R);
    P.BinkRecoveryKills := BRI32(R);
  end;

  if Version >= 8 then
  begin
    P.SpreeKills := BRI32(R);
    P.RampageKills := BRI32(R);
    P.DominatingSpreeKills := BRI32(R);
    P.UnstoppableKills := BRI32(R);
    P.GodlikeKills := BRI32(R);
    P.ShutDownKills := BRI32(R);
    P.FinisherKills := BRI32(R);
    P.FastestCapSeconds := BRF32(R);
    if P.FastestCapSeconds < 0 then
      P.FastestCapSeconds := 0;
    P.CarrierEscortKills := BRI32(R);
    P.FlagJuggles := BRI32(R);
    P.ContestedHolds := BRI32(R);
    for i := 0 to 30 do
    begin
      s := LegacyWeaponSlot(i);
      if s >= 0 then
        P.Weapons[s].HSKills := BRI32(R)
      else
        BRI32(R);
    end;
  end;
  LegacyDeriveTotals(P);
end;

function LegacyLoadAccountsBin(const Path: AnsiString; var Profiles: TProfilePtrArray;
  out Count, Version: LongInt; out Error: AnsiString): Boolean;
var
  R: TBinReader;
  Data: AnsiString;
  Magic, Total, i: LongInt;
begin
  Result := False;
  Count := 0;
  Version := 0;
  Error := '';
  FreeProfiles(Profiles);
  if not ReadWholeFile(Path, Data) then
  begin
    Error := 'cannot read ' + Path;
    Exit;
  end;
  BRInit(R, Data);
  Magic := BRI32(R);
  Version := BRI32(R);
  Total := BRI32(R);
  if not R.Ok or (Magic <> LEGACY_MAGIC) then
  begin
    Error := Path + ' is not a ZitroStats 4 accounts file';
    Exit;
  end;
  if (Version < 1) or (Version > LEGACY_MAX_VERSION) then
  begin
    Error := Format('%s: unsupported format version %d', [Path, Version]);
    Exit;
  end;
  { the smallest v1 profile takes 673 bytes }
  if (Total < 0) or (Int64(Total) * 600 > Length(Data)) then
  begin
    Error := Format('%s: invalid profile count %d', [Path, Total]);
    Exit;
  end;
  SetLength(Profiles, Total);
  for i := 0 to Total - 1 do
  begin
    Profiles[i] := NewProfile;
    ReadProfile(R, Version, Profiles[i]^);
    if not R.Ok then
    begin
      Error := Format('%s: truncated or corrupt at profile %d of %d', [Path, i + 1, Total]);
      FreeProfiles(Profiles);
      Exit;
    end;
  end;
  if R.Pos <> Length(Data) then
    Error := Format('%s: %d trailing bytes ignored', [Path, Length(Data) - R.Pos]);
  Count := Total;
  Result := True;
end;

function LegacyLoadMapsBin(const Path: AnsiString; var Maps: TMapProfileArray;
  out Count, Version: LongInt; out Error: AnsiString): Boolean;
var
  R: TBinReader;
  Data: AnsiString;
  Magic, Total, i: LongInt;
begin
  Result := False;
  Count := 0;
  Version := 0;
  Error := '';
  SetLength(Maps, 0);
  if not ReadWholeFile(Path, Data) then
  begin
    Error := 'cannot read ' + Path;
    Exit;
  end;
  BRInit(R, Data);
  Magic := BRI32(R);
  Version := BRI32(R);
  Total := BRI32(R);
  if not R.Ok or (Magic <> LEGACY_MAGIC) then
  begin
    Error := Path + ' is not a ZitroStats 4 maps file';
    Exit;
  end;
  if (Version < 1) or (Version > LEGACY_MAX_VERSION) then
  begin
    Error := Format('%s: unsupported format version %d', [Path, Version]);
    Exit;
  end;
  if (Total < 0) or (Int64(Total) * 100 > Length(Data)) then
  begin
    Error := Format('%s: invalid map count %d', [Path, Total]);
    Exit;
  end;
  SetLength(Maps, Total);
  for i := 0 to Total - 1 do
  begin
    Maps[i].ID := BRI32(R);
    Maps[i].MapName := BRStr(R);
    Maps[i].FirstPlayedTime := BRF64(R);
    Maps[i].LastPlayedTime := BRF64(R);
    Maps[i].Kills := BRI32(R);
    Maps[i].Selfkills := BRI32(R);
    Maps[i].ActiveMapPlays := BRI32(R);
    Maps[i].ActiveTimePlays := BRI32(R);
    Maps[i].AlphaWins := BRI32(R);
    Maps[i].BravoWins := BRI32(R);
    Maps[i].CharlieWins := BRI32(R);
    Maps[i].DeltaWins := BRI32(R);
    Maps[i].AlphaRoundWins := BRI32(R);
    Maps[i].BravoRoundWins := BRI32(R);
    Maps[i].CharlieRoundWins := BRI32(R);
    Maps[i].DeltaRoundWins := BRI32(R);
    Maps[i].FlagsGrabs := BRI32(R);
    Maps[i].FlagsReturns := BRI32(R);
    Maps[i].FlagsDrop := BRI32(R);
    Maps[i].FlagsThrown := BRI32(R);
    Maps[i].FlagsScore := BRI32(R);
    Maps[i].JoinGameCount := BRI32(R);
    Maps[i].LeaveGameCount := BRI32(R);
    Maps[i].KickedCount := BRI32(R);
    Maps[i].JoinToSpectator := BRI32(R);
    if Version >= 8 then
    begin
      Maps[i].FastestCapSeconds := BRF32(R);
      Maps[i].FastestCapHolder := BRStr(R);
      Maps[i].ComebackMatches := BRI32(R);
      Maps[i].CloseMatches := BRI32(R);
    end;
    if not R.Ok then
    begin
      Error := Format('%s: truncated or corrupt at map %d of %d', [Path, i + 1, Total]);
      SetLength(Maps, 0);
      Exit;
    end;
  end;
  if R.Pos <> Length(Data) then
    Error := Format('%s: %d trailing bytes ignored', [Path, Length(Data) - R.Pos]);
  Count := Total;
  Result := True;
end;

{ ---------------- text .db files ---------------- }

function IntField(const S: AnsiString; Def: LongInt = 0): LongInt;
begin
  Result := StrToIntDef(Trim(S), Def);
end;

function Int64Field(const S: AnsiString): Int64;
begin
  Result := StrToInt64Def(Trim(S), 0);
end;

function BoolField(const S: AnsiString): Boolean;
begin
  Result := SameText(Trim(S), 'true') or (Trim(S) = '1');
end;

function SplitOn(const S, Sep: AnsiString): TStringList;
var
  P, Start: LongInt;
begin
  Result := TStringList.Create;
  Start := 1;
  P := Pos(Sep, S);
  while P > 0 do
  begin
    Result.Add(Copy(S, Start, P - Start));
    Start := P + Length(Sep);
    P := PosEx(Sep, S, Start);
  end;
  Result.Add(Copy(S, Start, MaxInt));
end;

function ParseLegacyAliases(const Line: AnsiString): TOtherDataArray;
var
  Entries, Items: TStringList;
  i, n: LongInt;
begin
  Result := nil;
  if Trim(Line) = '' then
    Exit;
  { entries are separated by two tabs, the values of one entry by a single tab }
  Entries := SplitOn(Line, #9#9);
  try
    n := 0;
    SetLength(Result, Entries.Count);
    for i := 0 to Entries.Count - 1 do
    begin
      if Entries[i] = '' then
        Continue;
      Items := SplitOn(Entries[i], #9);
      try
        FillChar(Result[n], SizeOf(TOtherData), 0);
        SetOtherDataString(Result[n], Items[0]);
        if Items.Count > 1 then Result[n].IsActive := BoolField(Items[1]);
        if Items.Count > 2 then Result[n].FirstUsed := BoolField(Items[2]);
        if Items.Count > 3 then Result[n].LastUsed := BoolField(Items[3]);
        if Items.Count > 4 then Result[n].LoginCount := Int64Field(Items[4]);
        if Items.Count > 5 then Result[n].TimeOnSpectator := Int64Field(Items[5]);
        if Items.Count > 6 then Result[n].TimePlayed := Int64Field(Items[6]);
        if Items.Count > 7 then Result[n].FirstUsedDate := LegacyFloat(Items[7], 0);
        if Items.Count > 8 then Result[n].LastUsedDate := LegacyFloat(Items[8], 0);
        Inc(n);
      finally
        Items.Free;
      end;
    end;
    SetLength(Result, n);
  finally
    Entries.Free;
  end;
end;

function LegacyImportAccountsDb(const Path: AnsiString; var Profiles: TProfilePtrArray;
  out Count: LongInt; out Error: AnsiString): Boolean;
const
  LINES_PER_ACCOUNT = 160;
var
  L: TStringList;
  i, B: LongInt;
  P: PPlayerProfile;

  function F(Index: LongInt): AnsiString; inline;
  begin
    Result := L[B + Index];
  end;

begin
  Result := False;
  Count := 0;
  Error := '';
  FreeProfiles(Profiles);
  if not FileExists(Path) then
  begin
    Error := 'missing ' + Path;
    Exit;
  end;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        Error := Path + ': ' + E.Message;
        Exit;
      end;
    end;
    if L.Count < LINES_PER_ACCOUNT then
    begin
      Error := Path + ': no complete account';
      Exit;
    end;
    if L.Count mod LINES_PER_ACCOUNT <> 0 then
      Error := Format('%s: %d trailing lines ignored', [Path, L.Count mod LINES_PER_ACCOUNT]);
    Count := L.Count div LINES_PER_ACCOUNT;
    SetLength(Profiles, Count);
    for i := 0 to Count - 1 do
    begin
      B := i * LINES_PER_ACCOUNT;
      Profiles[i] := NewProfile;
      P := Profiles[i];
      P^.ID := i + 1;
      P^.ActiveName := F(0);
      P^.ActiveSteam := F(1);
      P^.ActiveHWID := F(2);
      P^.ActiveIP := F(3);
      P^.DisplayHUD := BoolField(F(4));
      P^.ProtectionDays := IntField(F(5));
      P^.ActivityForProtectDays := IntField(F(6));
      P^.TimePlayed := Int64Field(F(7));
      P^.TimeAlive := Int64Field(F(8));
      P^.TimeDeath := Int64Field(F(9));
      P^.TimeOnSpectator := Int64Field(F(10));
      P^.RegisterTime := LegacyFloat(F(11), 0);
      P^.LastPlayedTime := LegacyFloat(F(12), 0);
      P^.OtherNames := ParseLegacyAliases(F(13));
      { lines 14..16 (former SteamIDs, HWIDs, IPs) are not kept since 5.1 }
      P^.Points := IntField(F(17), 1000);
      P^.Kills := IntField(F(18));
      P^.Deaths := IntField(F(19));
      P^.Selfkills := IntField(F(20));
      P^.Assist := IntField(F(21));
      P^.Teamkills := IntField(F(22));
      P^.DeathsByFriendly := IntField(F(23));
      P^.PosthumousKills := IntField(F(24));
      P^.RevengeKills := IntField(F(25));
      P^.AvengerKills := IntField(F(26));
      P^.SaviorKills := IntField(F(27));
      P^.FlagsScore := IntField(F(28));
      P^.AlphaScore := IntField(F(29));
      P^.AlphaTeamScore := IntField(F(30));
      P^.BravoScore := IntField(F(31));
      P^.BravoTeamScore := IntField(F(32));
      P^.FlagsReturn := IntField(F(33));
      P^.FlagsGrab := IntField(F(34));
      P^.FlagsDrop := IntField(F(35));
      P^.FlagsThrown := IntField(F(36));
      P^.FlaggerKills := IntField(F(37));
      P^.FlaggerKillsAssist := IntField(F(38));
      P^.SaviorFlaggerKills := IntField(F(39));
      P^.FlaggerTeamkills := IntField(F(40));
      P^.KillsWhenHaveFlag := IntField(F(41));
      P^.TeamkillsWhenHaveFlag := IntField(F(42));
      P^.TimeHoldingFlags := IntField(F(43));
      P^.Wins := IntField(F(44));
      P^.Loses := IntField(F(45));
      P^.Draws := IntField(F(46));
      P^.AlphaWins := IntField(F(47));
      P^.AlphaLoses := IntField(F(48));
      P^.BravoWins := IntField(F(49));
      P^.BravoLoses := IntField(F(50));
      P^.CharlieWins := IntField(F(51));
      P^.CharlieLoses := IntField(F(52));
      P^.DeltaWins := IntField(F(53));
      P^.DeltaLoses := IntField(F(54));
      P^.RoundsWins := IntField(F(55));
      P^.RoundsLose := IntField(F(56));
      P^.RoundsAlphaWins := IntField(F(57));
      P^.RoundsAlphaLoses := IntField(F(58));
      P^.RoundsBravoWins := IntField(F(59));
      P^.RoundsBravoLoses := IntField(F(60));
      P^.RoundsCharlieWins := IntField(F(61));
      P^.RoundsCharlieLoses := IntField(F(62));
      P^.RoundsDeltaWins := IntField(F(63));
      P^.RoundsDeltaLoses := IntField(F(64));
      P^.Shots := IntField(F(65));
      P^.ShotsHits := IntField(F(66));
      P^.ShotsHitsFriendly := IntField(F(67));
      P^.ShotsHitsByFriendly := IntField(F(68));
      P^.ShotsHitsSelf := IntField(F(69));
      P^.ShotsHitsHead := IntField(F(70));
      P^.ShotsHitsBody := IntField(F(71));
      P^.ShotsHitsLeg := IntField(F(72));
      P^.ShotsHitsFriendlyHead := IntField(F(73));
      P^.ShotsHitsFriendlyBody := IntField(F(74));
      P^.ShotsHitsFriendlyLeg := IntField(F(75));
      P^.ShotsHitsByFriendlyHead := IntField(F(76));
      P^.ShotsHitsByFriendlyBody := IntField(F(77));
      P^.ShotsHitsByFriendlyLeg := IntField(F(78));
      P^.ShotsHitsSelfHead := IntField(F(79));
      P^.ShotsHitsSelfBody := IntField(F(80));
      P^.ShotsHitsSelfLeg := IntField(F(81));
      if P^.Shots < P^.ShotsHits then
        P^.Shots := P^.ShotsHits;
      P^.KnivesThrows := IntField(F(82));
      P^.KnivesThrowsHitsEnemy := IntField(F(83));
      P^.KnivesThrowsHitsSelf := IntField(F(84));
      P^.KnivesThrowsHitsFriends := IntField(F(85));
      P^.KnivesThrowsHitsByFriends := IntField(F(86));
      P^.KnivesStabsEnemy := IntField(F(87));
      P^.KnivesStabsFriendly := IntField(F(88));
      P^.KnivesStabsByFriendly := IntField(F(89));
      P^.ChainsawTimeUsedSeconds := IntField(F(90));
      P^.ChainsawHurtsEnemy := IntField(F(91));
      P^.ChainsawHurtsFriendly := IntField(F(92));
      P^.ChainsawHurtsByFriendly := IntField(F(93));
      P^.FlamethrowerShots := IntField(F(94));
      P^.FlamethrowerHitsEnemy := IntField(F(95));
      P^.FlamethrowerHitsFriendly := IntField(F(96));
      P^.FlamethrowerHitsSelf := IntField(F(97));
      P^.FlamethrowerHitsByFriendly := IntField(F(98));
      P^.HandsHurtsEnemy := IntField(F(99));
      P^.HandsHurtsFriendly := IntField(F(100));
      P^.NadesThrows := IntField(F(101));
      P^.NadeHurtsEnemy := IntField(F(102));
      P^.NadeHurtsFriendly := IntField(F(103));
      P^.NadeHurtsSelf := IntField(F(104));
      P^.NadeHurtsByFriendly := IntField(F(105));
      P^.ClusterNadesThrows := IntField(F(106));
      P^.ClusterNadesHurtsEnemy := IntField(F(107));
      P^.ClusterNadesHurtsFriendly := IntField(F(108));
      P^.ClusterNadesHurtsSelf := IntField(F(109));
      P^.ClusterNadesHurtsByFriendly := IntField(F(110));
      P^.M79Shots := IntField(F(111));
      P^.M79HurtsEnemy := IntField(F(112));
      P^.M79HurtsFriendly := IntField(F(113));
      P^.M79HurtsSelf := IntField(F(114));
      P^.M79HurtsByFriendly := IntField(F(115));
      P^.M72LAWShots := IntField(F(116));
      P^.M72LAWHurtsEnemy := IntField(F(117));
      P^.M72LAWHurtsFriendly := IntField(F(118));
      P^.M72LAWHurtsSelf := IntField(F(119));
      P^.M72LAWHurtsByFriendly := IntField(F(120));
      P^.BowFlamedArrowsShots := IntField(F(121));
      P^.BowFlamedArrowsHurtsEnemy := IntField(F(122));
      P^.BowFlamedArrowsHurtsFriendly := IntField(F(123));
      P^.BowFlamedArrowsHurtsSelf := IntField(F(124));
      P^.BowFlamedArrowsHurtsByFriendly := IntField(F(125));
      P^.HandsHurtsByFriendly := IntField(F(126));
      P^.M2MGHitsEnemy := IntField(F(127));
      P^.M2MGHitsFriendly := IntField(F(128));
      P^.M2MGHitsByFriendly := IntField(F(129));
      P^.RamboMode.KillRamboCount := IntField(F(130));
      P^.RamboMode.KillsByBow := IntField(F(131));
      P^.RamboMode.GetsBow := IntField(F(132));
      P^.RamboMode.DropBow := IntField(F(133));
      P^.RamboMode.KillsWhenNoRambo := IntField(F(134));
      P^.RamboMode.DeathsWhenNoRambo := IntField(F(135));
      P^.RamboMode.TimeWithBow := Int64Field(F(136));
      P^.RamboMode.TimeWithoutBow := Int64Field(F(137));
      P^.HTFMode.PointsScored := IntField(F(138));
      P^.HTFMode.TeamPointsScored := IntField(F(139));
      P^.HTFMode.AlphaPointsScored := IntField(F(140));
      P^.HTFMode.BravoPointsScored := IntField(F(141));
      P^.HTFMode.AlphaTeamPointsScored := IntField(F(142));
      P^.HTFMode.BravoTeamPointsScored := IntField(F(143));
      P^.HTFMode.TimeWhenHaveFlag := Int64Field(F(144));
      P^.HTFMode.TimeWhenTeamHaveFlag := Int64Field(F(145));
      P^.HTFMode.TimeWhenNotHaveFlag := Int64Field(F(146));
      P^.HTFMode.TimeWhenTeamNotHaveFlag := Int64Field(F(147));
      P^.PointmatchMode.ExtraPoints := IntField(F(148));
      P^.PointmatchMode.Multi.DOUBLE_KILL := IntField(F(149));
      P^.PointmatchMode.Multi.TRIPLE_KILL := IntField(F(150));
      P^.PointmatchMode.Multi.MULTI_KILL := IntField(F(151));
      P^.PointmatchMode.Multi.MULTI_KILL_X2 := IntField(F(152));
      P^.PointmatchMode.Multi.SERIAL_KILL := IntField(F(153));
      P^.PointmatchMode.Multi.INSANE_KILLS := IntField(F(154));
      P^.PointmatchMode.Multi.GIMME_MORE := IntField(F(155));
      P^.PointmatchMode.Multi.MASTA_KILLA := IntField(F(156));
      P^.PointmatchMode.Multi.STOP_IT := IntField(F(157));
      P^.PointmatchMode.Multi.MERCY := IntField(F(158));
      P^.PointmatchMode.Multi.CHEATER := IntField(F(159));
      SynthesizeOldWeapons(P^);
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

function LegacyImportMapsDb(const Path: AnsiString; var Maps: TMapProfileArray;
  out Count: LongInt; out Error: AnsiString): Boolean;
const
  LINES_PER_MAP = 24;
var
  L: TStringList;
  i, B: LongInt;
begin
  Result := False;
  Count := 0;
  Error := '';
  SetLength(Maps, 0);
  if not FileExists(Path) then
  begin
    Error := 'missing ' + Path;
    Exit;
  end;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        Error := Path + ': ' + E.Message;
        Exit;
      end;
    end;
    if L.Count < LINES_PER_MAP then
    begin
      Error := Path + ': no complete map';
      Exit;
    end;
    Count := L.Count div LINES_PER_MAP;
    SetLength(Maps, Count);
    for i := 0 to Count - 1 do
    begin
      B := i * LINES_PER_MAP;
      Maps[i].ID := i + 1;
      Maps[i].MapName := Trim(L[B]);
      Maps[i].FirstPlayedTime := LegacyFloat(L[B + 1], 0);
      Maps[i].LastPlayedTime := LegacyFloat(L[B + 2], 0);
      Maps[i].Kills := IntField(L[B + 3]);
      Maps[i].Selfkills := IntField(L[B + 4]);
      Maps[i].ActiveMapPlays := IntField(L[B + 5]);
      Maps[i].ActiveTimePlays := IntField(L[B + 6]);
      Maps[i].AlphaWins := IntField(L[B + 7]);
      Maps[i].BravoWins := IntField(L[B + 8]);
      Maps[i].CharlieWins := IntField(L[B + 9]);
      Maps[i].DeltaWins := IntField(L[B + 10]);
      Maps[i].AlphaRoundWins := IntField(L[B + 11]);
      Maps[i].BravoRoundWins := IntField(L[B + 12]);
      Maps[i].CharlieRoundWins := IntField(L[B + 13]);
      Maps[i].DeltaRoundWins := IntField(L[B + 14]);
      Maps[i].FlagsGrabs := IntField(L[B + 15]);
      Maps[i].FlagsReturns := IntField(L[B + 16]);
      Maps[i].FlagsDrop := IntField(L[B + 17]);
      Maps[i].FlagsThrown := IntField(L[B + 18]);
      Maps[i].FlagsScore := IntField(L[B + 19]);
      Maps[i].JoinGameCount := IntField(L[B + 20]);
      Maps[i].LeaveGameCount := IntField(L[B + 21]);
      Maps[i].KickedCount := IntField(L[B + 22]);
      Maps[i].JoinToSpectator := IntField(L[B + 23]);
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

{ ---------------- server_records.ini ---------------- }

function LegacyImportServerRecords(const Path: AnsiString; var S: TServerRecords;
  out PhantomsRemoved: Int64): Boolean;
var
  L: TStringList;
  Old: array[0..30, 0..30] of Int64;
  i, Eq, U, h, kw, vw, sk, sv: LongInt;
  Line, Key, Val, Rest: AnsiString;
  Others, Real0: Int64;
begin
  Result := False;
  PhantomsRemoved := 0;
  if not FileExists(Path) then
    Exit;
  FillChar(Old, SizeOf(Old), 0);
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if (Line = '') or (Line[1] in [';', '[']) then
        Continue;
      Eq := Pos('=', Line);
      if Eq <= 0 then
        Continue;
      Key := LowerCase(Trim(Copy(Line, 1, Eq - 1)));
      Val := Trim(Copy(Line, Eq + 1, MaxInt));
      if Key = 'peakonlinecount' then
        S.PeakOnlineCount := StrToIntDef(Val, 0)
      else if Key = 'peakonlinedurationsec' then
        S.PeakOnlineDurationSec := StrToInt64Def(Val, 0)
      else if Key = 'peakonlinedate' then
        S.PeakOnlineDate := LegacyFloat(Val, 0)
      else if Copy(Key, 1, 5) = 'hour_' then
      begin
        h := StrToIntDef(Copy(Key, 6, MaxInt), -1);
        if (h >= 0) and (h <= 23) then
          S.HourlyActivity[h] := StrToInt64Def(Val, 0);
      end
      else if Copy(Key, 1, 8) = 'matchup_' then
      begin
        Rest := Copy(Key, 9, MaxInt);
        U := Pos('_', Rest);
        if U <= 0 then
          Continue;
        kw := StrToIntDef(Copy(Rest, 1, U - 1), -1);
        vw := StrToIntDef(Copy(Rest, U + 1, MaxInt), -1);
        if (kw >= 0) and (kw <= 30) and (vw >= 0) and (vw <= 30) then
          Old[kw, vw] := StrToInt64Def(Val, 0);
      end;
    end;
  finally
    L.Free;
  end;

  { 4.x incremented [killer weapon, victim weapon] in the kill handler and again through the
    script call, which passed victim weapon 0. Column 0 therefore holds every real SOCOM-victim
    kill twice plus one phantom for each kill with another victim weapon. }
  for kw := 0 to 30 do
  begin
    Others := 0;
    for vw := 1 to 30 do
      Inc(Others, Old[kw, vw]);
    Real0 := (Old[kw, 0] - Others) div 2;
    if Real0 < 0 then
      Real0 := 0;
    Inc(PhantomsRemoved, Old[kw, 0] - Real0);
    Old[kw, 0] := Real0;
  end;

  for kw := 0 to 30 do
  begin
    sk := LegacyWeaponSlot(kw);
    if sk < 0 then
      Continue;
    for vw := 0 to 30 do
    begin
      sv := LegacyWeaponSlot(vw);
      if (sv >= 0) and (Old[kw, vw] > 0) then
        Inc(S.Matchups[sk, sv], LongInt(Old[kw, vw]));
    end;
  end;
  S.MatchupsFixed := True;
  Result := True;
end;

{ ---------------- id repair ---------------- }

procedure LegacyAssignProfileIds(var Profiles: TProfilePtrArray; Count: LongInt;
  out NextId, Reassigned: LongInt);
var
  Seen: array of Boolean;
  MaxId, i: LongInt;
begin
  MaxId := 0;
  for i := 0 to Count - 1 do
    if (Profiles[i]^.ID > MaxId) and (Profiles[i]^.ID <= MAX_SANE_ID) then
      MaxId := Profiles[i]^.ID;
  SetLength(Seen, MaxId + 1);
  NextId := MaxId + 1;
  Reassigned := 0;
  for i := 0 to Count - 1 do
    if (Profiles[i]^.ID > 0) and (Profiles[i]^.ID <= MaxId) and not Seen[Profiles[i]^.ID] then
      Seen[Profiles[i]^.ID] := True
    else
    begin
      Profiles[i]^.ID := NextId;
      Inc(NextId);
      Inc(Reassigned);
    end;
end;

procedure LegacyAssignMapIds(var Maps: TMapProfileArray; Count: LongInt;
  out NextId, Reassigned: LongInt);
var
  Seen: array of Boolean;
  MaxId, i: LongInt;
begin
  MaxId := 0;
  for i := 0 to Count - 1 do
    if (Maps[i].ID > MaxId) and (Maps[i].ID <= MAX_SANE_ID) then
      MaxId := Maps[i].ID;
  SetLength(Seen, MaxId + 1);
  NextId := MaxId + 1;
  Reassigned := 0;
  for i := 0 to Count - 1 do
    if (Maps[i].ID > 0) and (Maps[i].ID <= MaxId) and not Seen[Maps[i].ID] then
      Seen[Maps[i].ID] := True
    else
    begin
      Maps[i].ID := NextId;
      Inc(NextId);
      Inc(Reassigned);
    end;
end;

end.
