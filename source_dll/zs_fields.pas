unit zs_fields;

{ Field registry and TLV (id / type / value) encoding of every persisted record.

  RULES
  - A field id, once released, is never reused or renumbered: files written by older
    builds must keep decoding. Remove a field by deleting its registration only.
  - Unknown ids are skipped on read, missing ids keep their default value (zero), so adding
    a field needs no migration code.
  - The same registry drives persistence, stat resets and account merges, so a field that
    is registered here is automatically saved, reset and merged. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util;

type
  TFieldKind = (fkInt32, fkInt64, fkSingle, fkDouble, fkBool, fkString,
    fkAliases, fkTrusted, fkBadges, fkAchievements, fkHeat, fkDaily,
    fkPMWeapons, fkPMRivals, fkPMMatchups, fkMatchups);
  TMergeKind = (mkSum, mkMax, mkMinPos, mkKeep);

  TFieldDef = record
    Id: Word;
    Kind: TFieldKind;
    Offset: PtrUInt;
    Merge: TMergeKind;
    Stat: Boolean;
  end;
  TFieldDefArray = array of TFieldDef;

const
  { the most counters of a player-on-map record that follow a counter of the account (PMFollows) }
  PM_FOLLOW_MAX = 96;
  { the most trusted computers an account keeps (zs_identity); a three-way merge keeps no more }
  MAX_TRUSTED_DEVICES = 8;

type
  { A counter of the player-on-map record that counts what a counter of the account counts: the
    engine adds what an event added to the account's counter to the record of the map
    (zs_engine_matrix.inc). Both are of the same Kind (fkInt32, fkInt64 or fkDouble); Id is the
    record's field in PlayerMapFields. }
  TPMFollow = record
    Id: Word;
    Kind: TFieldKind;
    ProfileOffset: PtrUInt;
    RecordOffset: PtrUInt;
  end;

var
  ProfileFields: TFieldDefArray;
  MapFields: TFieldDefArray;
  ServerFields: TFieldDefArray;
  { the player-on-map records (zs_matrix) have ids of their own, and so has every entry of their
    lists and of the weapon matchups of a map: each entry is a small record of its own }
  PlayerMapFields: TFieldDefArray;
  PMWeaponFields: TFieldDefArray;
  PMRivalFields: TFieldDefArray;
  PMMatchupFields: TFieldDefArray;
  MatchupCellFields: TFieldDefArray;
  { the counters of a player-on-map record that follow the account's own (at most PM_FOLLOW_MAX) }
  PMFollows: array of TPMFollow;

function EncodeProfile(const P: TPlayerProfile): AnsiString;
function DecodeProfile(const Data: AnsiString; var P: TPlayerProfile): Boolean;
{ The record of an account for a copy other servers and websites read (Engine = mirror,
  zs_players.shared_data): without the fields that identify the person or open the account - the
  SteamID, HWID and IP (ids 3-5), the password, e-mail, codes, mail and login counters and the
  trusted computers (20-38). DecodeProfile reads it; those fields stay empty. }
function EncodeSharedProfile(const P: TPlayerProfile): AnsiString;
{ True for the fields EncodeSharedProfile leaves out }
function IsLoginField(Id: Word): Boolean;
function EncodeMap(const M: TMapProfile): AnsiString;
function DecodeMap(const Data: AnsiString; var M: TMapProfile): Boolean;
function EncodeServer(const S: TServerRecords): AnsiString;
function DecodeServer(const Data: AnsiString; var S: TServerRecords): Boolean;
function EncodeSeason(const A: TSeasonArchive): AnsiString;
function DecodeSeason(const Data: AnsiString; var A: TSeasonArchive): Boolean;

procedure ClearProfile(var P: TPlayerProfile);
procedure ClearMap(var M: TMapProfile);
procedure ClearServer(var S: TServerRecords);
function NewProfile: PPlayerProfile;
procedure FreeProfile(var P: PPlayerProfile);
procedure FreeProfiles(var Arr: TProfilePtrArray);
procedure ResetProfileStats(var P: TPlayerProfile);
procedure ResetMapStats(var M: TMapProfile);
procedure MergeProfileInto(var Dst: TPlayerProfile; const Src: TPlayerProfile; StartingPoints: LongInt);
{ the number fields alone, each by its rule (added, the larger, the smaller): totals of many accounts }
procedure SumProfileCounters(var Dst: TPlayerProfile; const Src: TPlayerProfile);
procedure MergeAliasArrays(var Dst: TOtherDataArray; const Src: TOtherDataArray);
{ A copy of a record shares its lists with the original, and a merge changes lists in place: this
  gives the copy lists of its own first, so the original stays as it was. }
procedure UniqueProfileLists(var P: TPlayerProfile);
{ the same map on two servers added up: the counters by their rule, the fastest capture with its
  holder, the heat cells by cell; the bases and the size of the map stay Dst's when it knows them }
procedure MergeMapInto(var Dst: TMapProfile; const Src: TMapProfile; Heat: Boolean = True);
{ the records of two servers added up: activity, weapons, matchups, hit model and the days; the
  online peak is the higher one; numbering, seasons and the marks of done work stay Dst's }
procedure MergeServerInto(var Dst: TServerRecords; const Src: TServerRecords);
{ Three-way merges for one database shared by several servers (zs_sqldb): Cur is this server's
  record, Base the one the database had when this server last saw it, Remote the one it has now.
  Cur becomes Remote with this server's changes since Base put on top: counters add up, a record
  or a best time keeps the better value (one that got worse here is a reset, and it stays), and
  a setting, a name or a rating takes this server's value when it changed here, otherwise the
  database's. Nothing another server wrote in the meantime is lost, whatever the order. Base
  empty (all zero) means "everything is new". The trusted computers and the names are sets: what
  one side removed stays removed. NameLimit > 0 ([Identity] NameHistoryLimit) cuts the names to
  that many, the least recently used go first. }
procedure Merge3Profile(var Cur: TPlayerProfile; const Base, Remote: TPlayerProfile; NameLimit: LongInt = 0);
procedure Merge3Map(var Cur: TMapProfile; const Base, Remote: TMapProfile);
procedure Merge3Server(var Cur: TServerRecords; const Base, Remote: TServerRecords);
{ the streaks of P that reached Kills kills (1-50, 50 = 50 or more), read from SpreeLives together
  with the five counters of the fixed levels before it (5, 10, 15, 20 and 25 kills) }
function SpreeLivesAt(const P: TPlayerProfile; Kills: LongInt): LongInt;

{ ---- the player-on-map records ([Matrix], zs_matrix) ---- }
function EncodePlayerMap(const R: TPlayerMapStats): AnsiString;
{ the lists come back sorted by their keys, whatever order the data had }
function DecodePlayerMap(const Data: AnsiString; var R: TPlayerMapStats): Boolean;
procedure ClearPlayerMap(var R: TPlayerMapStats);
function NewPlayerMap: PPlayerMapStats;
procedure FreePlayerMap(var P: PPlayerMapStats);
procedure FreePlayerMaps(var Arr: TPlayerMapPtrArray);
{ nothing counted: every statistic zero and every list empty (the key and the dates aside) }
function PlayerMapEmpty(const R: TPlayerMapStats): Boolean;
{ Src added to Dst: the numbers by their rule, the lists entry by entry; with MaxRivals > 0 the
  rivals are cut to that many (PMTrimRivals). The keys (account, map) stay Dst's. }
procedure MergePlayerMapInto(var Dst: TPlayerMapStats; const Src: TPlayerMapStats; MaxRivals: LongInt);
{ three ways, as Merge3Map: Cur becomes Remote with Cur's changes since Base on top, entry by entry
  in the lists; a count never goes below 0, an entry with nothing left goes. Cur's lists are new
  lists afterwards, the keys and the runtime fields stay Cur's. }
procedure Merge3PlayerMap(var Cur: TPlayerMapStats; const Base, Remote: TPlayerMapStats);
{ the place of a key in a sorted list: True when it is there, else False and the place it belongs }
function PMWeaponPos(const A: TPMWeaponArray; Slot: LongInt; out Pos: LongInt): Boolean;
function PMRivalPos(const A: TPMRivalArray; Id: LongInt; out Pos: LongInt): Boolean;
function PMMatchupPos(const A: TPMMatchupArray; Mine, Theirs: LongInt; out Pos: LongInt): Boolean;
function MatchupCellPos(const A: TMatchupCellArray; Killer, Victim: LongInt; out Pos: LongInt): Boolean;
function HeatCellPos(const A: THeatCellArray; Cell: LongInt; out Pos: LongInt): Boolean;
{ the rival that goes first from a full list: the fewest fights (kills and deaths), of those the
  oldest last fight; -1 for an empty list }
function PMWeakestRival(const A: TPMRivalArray): LongInt;
{ drops the weakest rivals until at most MaxRivals are left (0 = no limit) }
procedure PMTrimRivals(var A: TPMRivalArray; MaxRivals: LongInt);
{ the weapon matchups of maps: Src added to Dst cell by cell, and three ways as the heat cells }
procedure MergeMatchupCells(var Dst: TMatchupCellArray; const Src: TMatchupCellArray);
function Merge3MatchupCells(const Cur, Base, Remote: TMatchupCellArray): TMatchupCellArray;
{ the fields of Src added to Dst by the rule of each (Defs: a registry above; one entry of a list
  with PMRivalFields ...) }
procedure SumFields(Dst, Src: Pointer; const Defs: TFieldDefArray);
{ Places (0 .. n-1) put in the order of their keys, the smallest first; the keys stay }
procedure SortByKeys(const Keys: array of Int64; var Places: array of LongInt);

implementation

const
  T_I32 = 1;
  T_I64 = 2;
  T_F32 = 3;
  T_F64 = 4;
  T_BOOL = 5;
  T_STR = 6;
  T_BLOB = 7;

type
  TWriter = record
    Buf: AnsiString;
    Len: LongInt;
  end;

  TReader = record
    P: PByte;
    Remaining: LongInt;
    Ok: Boolean;
  end;

var
  DP: TPlayerProfile;
  DM: TMapProfile;
  DS: TServerRecords;
  DPM: TPlayerMapStats;
  DPW: TPMWeapon;
  DPR: TPMRival;
  DPX: TPMMatchup;
  DMC: TMatchupCell;

{ ---------------- low level writer / reader ---------------- }

procedure WInit(out W: TWriter; Capacity: LongInt);
begin
  SetLength(W.Buf, Capacity);
  W.Len := 0;
end;

procedure WRaw(var W: TWriter; Src: Pointer; Count: LongInt);
var
  NewCap: LongInt;
begin
  if Count <= 0 then Exit;
  if W.Len + Count > Length(W.Buf) then
  begin
    NewCap := Length(W.Buf) * 2;
    if NewCap < W.Len + Count then NewCap := W.Len + Count + 256;
    SetLength(W.Buf, NewCap);
  end;
  Move(Src^, W.Buf[W.Len + 1], Count);
  Inc(W.Len, Count);
end;

procedure WU8(var W: TWriter; V: Byte); begin WRaw(W, @V, 1); end;
procedure WU16(var W: TWriter; V: Word); begin WRaw(W, @V, 2); end;
procedure WI32(var W: TWriter; V: LongInt); begin WRaw(W, @V, 4); end;
procedure WU32(var W: TWriter; V: LongWord); begin WRaw(W, @V, 4); end;
procedure WI64(var W: TWriter; V: Int64); begin WRaw(W, @V, 8); end;
procedure WF32(var W: TWriter; V: Single); begin WRaw(W, @V, 4); end;
procedure WF64(var W: TWriter; V: Double); begin WRaw(W, @V, 8); end;

procedure WStr16(var W: TWriter; const S: AnsiString);
var
  L: LongInt;
begin
  L := Length(S);
  if L > 65535 then L := 65535;
  WU16(W, L);
  if L > 0 then WRaw(W, @S[1], L);
end;

function WDone(var W: TWriter): AnsiString;
begin
  SetLength(W.Buf, W.Len);
  Result := W.Buf;
end;

procedure RInit(out R: TReader; const Data: AnsiString);
begin
  R.P := PByte(PAnsiChar(Data));
  R.Remaining := Length(Data);
  R.Ok := True;
end;

function RNeed(var R: TReader; Count: LongInt): Boolean; inline;
begin
  if (Count < 0) or (R.Remaining < Count) then R.Ok := False;
  Result := R.Ok;
end;

procedure RRaw(var R: TReader; Dst: Pointer; Count: LongInt);
begin
  if not RNeed(R, Count) then Exit;
  Move(R.P^, Dst^, Count);
  Inc(R.P, Count);
  Dec(R.Remaining, Count);
end;

procedure RSkip(var R: TReader; Count: LongInt);
begin
  if not RNeed(R, Count) then Exit;
  Inc(R.P, Count);
  Dec(R.Remaining, Count);
end;

function RU8(var R: TReader): Byte; begin Result := 0; RRaw(R, @Result, 1); end;
function RU16(var R: TReader): Word; begin Result := 0; RRaw(R, @Result, 2); end;
function RI32(var R: TReader): LongInt; begin Result := 0; RRaw(R, @Result, 4); end;
function RU32(var R: TReader): LongWord; begin Result := 0; RRaw(R, @Result, 4); end;
function RI64(var R: TReader): Int64; begin Result := 0; RRaw(R, @Result, 8); end;

{ Floats are checked on their bit pattern before they reach the FPU: a NaN or an infinity from a
  damaged record (or a Linux build, where a worker thread may compute one) would raise on
  Windows or spread through every sum, so it is read as 0. }
function RF32(var R: TReader): Single;
var
  Bits: LongWord;
begin
  Result := 0;
  Bits := 0;
  RRaw(R, @Bits, 4);
  if (Bits and $7F800000) <> $7F800000 then
    Move(Bits, Result, 4);
end;

function RF64(var R: TReader): Double;
var
  Bits: QWord;
begin
  Result := 0;
  Bits := 0;
  RRaw(R, @Bits, 8);
  if (Bits and QWord($7FF0000000000000)) <> QWord($7FF0000000000000) then
    Move(Bits, Result, 8);
end;

function RStr16(var R: TReader): AnsiString;
var
  L: Word;
begin
  Result := '';
  L := RU16(R);
  if not RNeed(R, L) then Exit;
  SetLength(Result, L);
  if L > 0 then RRaw(R, @Result[1], L);
end;

{ ---------------- registry ---------------- }

procedure AddDef(var Arr: TFieldDefArray; Base: Pointer; Id: Word; Kind: TFieldKind; Addr: Pointer;
  Merge: TMergeKind; Stat: Boolean);
var
  n, i: LongInt;
begin
  for i := 0 to High(Arr) do
    if Arr[i].Id = Id then
      raise Exception.CreateFmt('zs_fields: duplicate field id %d', [Id]);
  n := Length(Arr);
  SetLength(Arr, n + 1);
  Arr[n].Id := Id;
  Arr[n].Kind := Kind;
  Arr[n].Offset := PtrUInt(Addr) - PtrUInt(Base);
  Arr[n].Merge := Merge;
  Arr[n].Stat := Stat;
end;

procedure P32(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(ProfileFields, @DP, Id, fkInt32, Addr, Merge, Stat); end;
procedure P64(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(ProfileFields, @DP, Id, fkInt64, Addr, Merge, Stat); end;
procedure PF32(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(ProfileFields, @DP, Id, fkSingle, Addr, Merge, Stat); end;
procedure PF64(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(ProfileFields, @DP, Id, fkDouble, Addr, Merge, Stat); end;
procedure PB(Id: Word; Addr: Pointer; Stat: Boolean = False);
begin AddDef(ProfileFields, @DP, Id, fkBool, Addr, mkKeep, Stat); end;
procedure PS(Id: Word; Addr: Pointer);
begin AddDef(ProfileFields, @DP, Id, fkString, Addr, mkKeep, False); end;
procedure PX(Id: Word; Kind: TFieldKind; Addr: Pointer);
begin AddDef(ProfileFields, @DP, Id, Kind, Addr, mkKeep, False); end;

procedure M32(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(MapFields, @DM, Id, fkInt32, Addr, Merge, Stat); end;
procedure M64(Id: Word; Addr: Pointer; Stat: Boolean = True);
begin AddDef(MapFields, @DM, Id, fkInt64, Addr, mkSum, Stat); end;
procedure MF32(Id: Word; Addr: Pointer; Stat: Boolean = True);
begin AddDef(MapFields, @DM, Id, fkSingle, Addr, mkKeep, Stat); end;
procedure MF64(Id: Word; Addr: Pointer; Stat: Boolean = True);
begin AddDef(MapFields, @DM, Id, fkDouble, Addr, mkSum, Stat); end;

procedure S32(Id: Word; Addr: Pointer);
begin AddDef(ServerFields, @DS, Id, fkInt32, Addr, mkKeep, False); end;
procedure S64(Id: Word; Addr: Pointer);
begin AddDef(ServerFields, @DS, Id, fkInt64, Addr, mkKeep, False); end;
procedure SF64(Id: Word; Addr: Pointer);
begin AddDef(ServerFields, @DS, Id, fkDouble, Addr, mkKeep, False); end;

procedure RegisterProfileFields;
var
  i, k: LongInt;
begin
  { identity & account (ids 1..99) }
  P32(1, @DP.ID, mkKeep, False);
  PS(2, @DP.ActiveName);
  PS(3, @DP.ActiveSteam);
  PS(4, @DP.ActiveHWID);
  PS(5, @DP.ActiveIP);
  PB(6, @DP.DisplayHUD);
  PF64(7, @DP.RegisterTime, mkKeep, False);
  PF64(8, @DP.LastPlayedTime, mkMax, False);
  P32(9, @DP.MergedInto, mkKeep, False);
  PX(10, fkAliases, @DP.OtherNames);
  { ids 11..13 held former SteamIDs, HWIDs and IPs; retired in 5.1 and skipped when read }
  PS(20, @DP.PassHash);
  PS(21, @DP.PassSalt);
  P32(22, @DP.PassIter, mkKeep, False);
  PF64(23, @DP.PassSetTime, mkKeep, False);
  PS(24, @DP.Email);
  PB(25, @DP.EmailVerified);
  PS(26, @DP.EmailPending);
  PS(27, @DP.EmailCodeHash);
  PF64(28, @DP.EmailCodeExpire, mkKeep, False);
  PS(29, @DP.ResetCodeHash);
  PF64(30, @DP.ResetCodeExpire, mkKeep, False);
  PF64(31, @DP.MailLastSent, mkKeep, False);
  P32(32, @DP.MailDayKey, mkKeep, False);
  P32(33, @DP.MailSentToday, mkKeep, False);
  P32(34, @DP.LoginFailCount, mkKeep, False);
  PF64(35, @DP.LoginLockUntil, mkKeep, False);
  PX(36, fkTrusted, @DP.TrustedDevices);
  PB(37, @DP.NoTrustedDevices);
  PF64(38, @DP.LoginFailSince, mkKeep, False);
  P32(40, @DP.ProtectionDays, mkMax);
  P32(41, @DP.ActivityForProtectDays, mkMax);
  P64(42, @DP.TimePlayed);
  P64(43, @DP.TimeAlive);
  P64(44, @DP.TimeDeath);
  P64(45, @DP.TimeOnSpectator);
  P32(46, @DP.DaysPlayed);
  P32(47, @DP.LastDayKey, mkMax, False);

  { core combat, objectives, matches (100..199) }
  P32(100, @DP.Points, mkKeep);
  P32(101, @DP.Kills);
  P32(102, @DP.Deaths);
  P32(103, @DP.Selfkills);
  P32(104, @DP.Assist);
  P32(105, @DP.Teamkills);
  P32(106, @DP.DeathsByFriendly);
  P32(107, @DP.PosthumousKills);
  P32(108, @DP.RevengeKills);
  P32(109, @DP.AvengerKills);
  P32(110, @DP.SaviorKills);
  P32(120, @DP.FlagsScore);
  P32(121, @DP.AlphaScore);
  P32(122, @DP.AlphaTeamScore);
  P32(123, @DP.BravoScore);
  P32(124, @DP.BravoTeamScore);
  P32(125, @DP.FlagsReturn);
  P32(126, @DP.FlagsGrab);
  P32(127, @DP.FlagsDrop);
  P32(128, @DP.FlagsThrown);
  P32(129, @DP.FlaggerKills);
  P32(130, @DP.FlaggerKillsAssist);
  P32(131, @DP.SaviorFlaggerKills);
  P32(132, @DP.FlaggerTeamkills);
  P32(133, @DP.KillsWhenHaveFlag);
  P32(134, @DP.TeamkillsWhenHaveFlag);
  P32(135, @DP.TimeHoldingFlags);
  P32(140, @DP.Wins);
  P32(141, @DP.Loses);
  P32(142, @DP.Draws);
  P32(143, @DP.LeaveLosses);
  P32(144, @DP.AlphaWins);
  P32(145, @DP.AlphaLoses);
  P32(146, @DP.BravoWins);
  P32(147, @DP.BravoLoses);
  P32(148, @DP.CharlieWins);
  P32(149, @DP.CharlieLoses);
  P32(150, @DP.DeltaWins);
  P32(151, @DP.DeltaLoses);
  P32(152, @DP.RoundsWins);
  P32(153, @DP.RoundsLose);
  P32(154, @DP.RoundsAlphaWins);
  P32(155, @DP.RoundsAlphaLoses);
  P32(156, @DP.RoundsBravoWins);
  P32(157, @DP.RoundsBravoLoses);
  P32(158, @DP.RoundsCharlieWins);
  P32(159, @DP.RoundsCharlieLoses);
  P32(160, @DP.RoundsDeltaWins);
  P32(161, @DP.RoundsDeltaLoses);

  { shooting & special weapons (200..299) }
  P32(200, @DP.Shots);
  P32(201, @DP.ShotsHits);
  P32(202, @DP.ShotsHitsFriendly);
  P32(203, @DP.ShotsHitsByFriendly);
  P32(204, @DP.ShotsHitsSelf);
  P32(205, @DP.ShotsHitsHead);
  P32(206, @DP.ShotsHitsBody);
  P32(207, @DP.ShotsHitsLeg);
  P32(208, @DP.ShotsHitsUnknown);
  P32(209, @DP.ShotsHitsFriendlyHead);
  P32(210, @DP.ShotsHitsFriendlyBody);
  P32(211, @DP.ShotsHitsFriendlyLeg);
  P32(212, @DP.ShotsHitsByFriendlyHead);
  P32(213, @DP.ShotsHitsByFriendlyBody);
  P32(214, @DP.ShotsHitsByFriendlyLeg);
  P32(215, @DP.ShotsHitsSelfHead);
  P32(216, @DP.ShotsHitsSelfBody);
  P32(217, @DP.ShotsHitsSelfLeg);
  P32(220, @DP.KnivesThrows);
  P32(221, @DP.KnivesThrowsHitsEnemy);
  P32(222, @DP.KnivesThrowsHitsSelf);
  P32(223, @DP.KnivesThrowsHitsFriends);
  P32(224, @DP.KnivesThrowsHitsByFriends);
  P32(225, @DP.KnivesStabsEnemy);
  P32(226, @DP.KnivesStabsFriendly);
  P32(227, @DP.KnivesStabsByFriendly);
  P32(228, @DP.ChainsawTimeUsedSeconds);
  P32(229, @DP.ChainsawHurtsEnemy);
  P32(230, @DP.ChainsawHurtsFriendly);
  P32(231, @DP.ChainsawHurtsByFriendly);
  P32(232, @DP.FlamethrowerShots);
  P32(233, @DP.FlamethrowerHitsEnemy);
  P32(234, @DP.FlamethrowerHitsFriendly);
  P32(235, @DP.FlamethrowerHitsSelf);
  P32(236, @DP.FlamethrowerHitsByFriendly);
  P32(237, @DP.HandsHurtsEnemy);
  P32(238, @DP.HandsHurtsFriendly);
  P32(239, @DP.HandsHurtsByFriendly);
  P32(240, @DP.NadesThrows);
  P32(241, @DP.NadeHurtsEnemy);
  P32(242, @DP.NadeHurtsFriendly);
  P32(243, @DP.NadeHurtsSelf);
  P32(244, @DP.NadeHurtsByFriendly);
  P32(245, @DP.ClusterNadesThrows);
  P32(246, @DP.ClusterNadesHurtsEnemy);
  P32(247, @DP.ClusterNadesHurtsFriendly);
  P32(248, @DP.ClusterNadesHurtsSelf);
  P32(249, @DP.ClusterNadesHurtsByFriendly);
  P32(250, @DP.M79Shots);
  P32(251, @DP.M79HurtsEnemy);
  P32(252, @DP.M79HurtsFriendly);
  P32(253, @DP.M79HurtsSelf);
  P32(254, @DP.M79HurtsByFriendly);
  P32(255, @DP.M72LAWShots);
  P32(256, @DP.M72LAWHurtsEnemy);
  P32(257, @DP.M72LAWHurtsFriendly);
  P32(258, @DP.M72LAWHurtsSelf);
  P32(259, @DP.M72LAWHurtsByFriendly);
  P32(260, @DP.BowFlamedArrowsShots);
  P32(261, @DP.BowFlamedArrowsHurtsEnemy);
  P32(262, @DP.BowFlamedArrowsHurtsFriendly);
  P32(263, @DP.BowFlamedArrowsHurtsSelf);
  P32(264, @DP.BowFlamedArrowsHurtsByFriendly);
  P32(265, @DP.M2MGHitsEnemy);
  P32(266, @DP.M2MGHitsFriendly);
  P32(267, @DP.M2MGHitsByFriendly);

  { game mode records (300..349) }
  P32(300, @DP.RamboMode.KillRamboCount);
  P32(301, @DP.RamboMode.KillsByBow);
  P32(302, @DP.RamboMode.GetsBow);
  P32(303, @DP.RamboMode.DropBow);
  P32(304, @DP.RamboMode.KillsWhenNoRambo);
  P32(305, @DP.RamboMode.DeathsWhenNoRambo);
  P64(306, @DP.RamboMode.TimeWithBow);
  P64(307, @DP.RamboMode.TimeWithoutBow);
  P32(310, @DP.HTFMode.PointsScored);
  P32(311, @DP.HTFMode.TeamPointsScored);
  P32(312, @DP.HTFMode.AlphaPointsScored);
  P32(313, @DP.HTFMode.BravoPointsScored);
  P32(314, @DP.HTFMode.AlphaTeamPointsScored);
  P32(315, @DP.HTFMode.BravoTeamPointsScored);
  P64(316, @DP.HTFMode.TimeWhenHaveFlag);
  P64(317, @DP.HTFMode.TimeWhenTeamHaveFlag);
  P64(318, @DP.HTFMode.TimeWhenNotHaveFlag);
  P64(319, @DP.HTFMode.TimeWhenTeamNotHaveFlag);
  P32(320, @DP.PointmatchMode.ExtraPoints);
  P32(321, @DP.PointmatchMode.Multi.DOUBLE_KILL);
  P32(322, @DP.PointmatchMode.Multi.TRIPLE_KILL);
  P32(323, @DP.PointmatchMode.Multi.MULTI_KILL);
  P32(324, @DP.PointmatchMode.Multi.MULTI_KILL_X2);
  P32(325, @DP.PointmatchMode.Multi.SERIAL_KILL);
  P32(326, @DP.PointmatchMode.Multi.INSANE_KILLS);
  P32(327, @DP.PointmatchMode.Multi.GIMME_MORE);
  P32(328, @DP.PointmatchMode.Multi.MASTA_KILLA);
  P32(329, @DP.PointmatchMode.Multi.STOP_IT);
  P32(330, @DP.PointmatchMode.Multi.MERCY);
  P32(331, @DP.PointmatchMode.Multi.CHEATER);

  { feats (350..399) }
  P32(350, @DP.LastStand);
  P32(351, @DP.ClutchesWon);
  P32(352, @DP.DominatingCount);
  P32(353, @DP.RevengeFeats);
  P32(354, @DP.AdvanceRoundsWon);
  P32(355, @DP.AdvanceRoundsPlayed);
  P32(356, @DP.MaxKillStreak, mkMax);
  PF32(357, @DP.LongestKillDistance, mkMax);
  PF32(358, @DP.LongestBarrettDistance, mkMax);
  PF64(359, @DP.TotalKillDistance);
  P64(360, @DP.KillDistanceCount);
  P32(361, @DP.FirstBloodCount);
  P32(362, @DP.FirstDamageCount);
  { the first kill of a survival round; 361 is the first kill of the match }
  P32(700, @DP.RoundFirstBloodCount);
  PF64(363, @DP.DamageDealt);
  PF64(364, @DP.DamageReceived);
  PF64(365, @DP.DamageFriendly);
  PF64(366, @DP.DamageFriendlyReceived);
  P32(367, @DP.ProneKills);
  P64(368, @DP.JetFlyTimeSeconds);
  P32(369, @DP.CampKills);
  P32(370, @DP.BinkRecoveryKills);
  P32(371, @DP.SpreeKills);
  P32(372, @DP.RampageKills);
  P32(373, @DP.DominatingSpreeKills);
  P32(374, @DP.UnstoppableKills);
  P32(375, @DP.GodlikeKills);
  P32(376, @DP.ShutDownKills);
  P32(377, @DP.FinisherKills);
  PF32(378, @DP.FastestCapSeconds, mkMinPos);
  P32(379, @DP.CarrierEscortKills);
  P32(380, @DP.FlagJuggles);
  P32(381, @DP.ContestedHolds);

  { v9 telemetry (400..499) }
  P32(400, @DP.LongestLifeSec, mkMax);
  P64(401, @DP.TTKSumTicks);
  P32(402, @DP.TTKCount);
  P32(403, @DP.BestTTKTicks, mkMinPos);
  P32(404, @DP.SpawnKills);
  P32(405, @DP.SpawnDeaths);
  P32(406, @DP.AirKills);
  P32(407, @DP.HeightKills);
  P32(408, @DP.VestKills);
  P32(409, @DP.GrenadeKills);
  P32(410, @DP.ExplosionMultiKills);
  P32(411, @DP.KnifeKillsLifeBest, mkMax);
  PF64(412, @DP.DistanceTraveledM);
  P32(413, @DP.BarrettLongKills);
  P32(414, @DP.LongKills100);
  P32(415, @DP.CapsUnder10s);
  P32(416, @DP.ComebackWins);
  { the league is recomputed every day, a merge keeps the one of the surviving account }
  P32(417, @DP.LeagueTier, mkKeep);
  P32(418, @DP.LeagueDivision, mkKeep);
  P32(419, @DP.LeaguePromille, mkKeep);
  P32(420, @DP.WallKills);
  P32(421, @DP.BaseDefenseKills);
  P32(422, @DP.BaseAttackKills);
  PF32(423, @DP.BestLifeDistanceM, mkMax);
  P32(424, @DP.ForcedSelfkills);
  P32(425, @DP.SelfkillsUnderFire);
  P32(426, @DP.CoverShotKills);
  P32(427, @DP.BalanceMoves);
  P32(428, @DP.BalanceVolunteers);
  PF64(429, @DP.HealRegen);
  PF64(430, @DP.HealKits);
  P32(431, @DP.HealKitCount);
  { [Bridges] (5.6): 432-444 }
  P32(432, @DP.CollateralKills);
  P32(433, @DP.BackKills);
  P32(434, @DP.BackDeaths);
  PF32(435, @DP.LongestHeadshotM, mkMax);
  PF32(436, @DP.LongestFlightKill, mkMax);
  for i := 0 to 3 do
  begin
    P32(437 + i, @DP.StanceShots[i]);
    P32(441 + i, @DP.StanceHits[i]);
  end;
  { the hits' distance and air time, the kills' air time (445-451) }
  PF64(445, @DP.HitDistSum);
  P64(446, @DP.HitDistCount);
  PF32(447, @DP.LongestHitM, mkMax);
  P64(448, @DP.HitAirTicks);
  P64(449, @DP.HitAirCount);
  P64(450, @DP.KillAirTicks);
  P64(451, @DP.KillAirCount);

  { nemesis lists are merged by a dedicated routine }
  for i := 0 to 2 do
  begin
    P32(500 + i * 2, @DP.TopVictims[i].TargetPlayerID, mkKeep);
    P32(501 + i * 2, @DP.TopVictims[i].KillCount, mkKeep);
    P32(510 + i * 2, @DP.TopNemeses[i].TargetPlayerID, mkKeep);
    P32(511 + i * 2, @DP.TopNemeses[i].KillCount, mkKeep);
  end;

  { kill streaks by their length: 600 + N, the streaks that reached N kills (650: 50 or more) }
  for i := 1 to SPREE_MAX_KILLS do
    P32(600 + i, @DP.SpreeLives[i]);

  { the kits picked up, by kind: 651 + the place in KIT_KIND_STYLES (651 medical, 652 grenade,
    653 cluster, 654 vest, 655 berserker, 656 predator, 657 flamer) }
  for i := 0 to KIT_KINDS - 1 do
    P32(651 + i, @DP.KitPickups[i]);

  { weapons: 1000 + slot * 16 + k }
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    k := 1000 + i * 16;
    P32(k + 0, @DP.Weapons[i].Kills);
    P32(k + 1, @DP.Weapons[i].Deaths);
    P32(k + 2, @DP.Weapons[i].Shots);
    P32(k + 3, @DP.Weapons[i].Hits);
    P32(k + 4, @DP.Weapons[i].Headshots);
    P32(k + 5, @DP.Weapons[i].HitsBody);
    P32(k + 6, @DP.Weapons[i].HitsLegs);
    P32(k + 7, @DP.Weapons[i].HitsUnknown);
    P32(k + 8, @DP.Weapons[i].HSKills);
    PF64(k + 9, @DP.Weapons[i].Damage);
    PF64(k + 10, @DP.Weapons[i].DamageReceived);
    P64(k + 11, @DP.Weapons[i].TimeUsedSeconds);
    PF32(k + 12, @DP.Weapons[i].LongestKill, mkMax);
  end;

  { reloading: 2000 + slot * 16 + k }
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    k := 2000 + i * 16;
    P32(k + 0, @DP.Weapons[i].Reloads);
    P32(k + 1, @DP.Weapons[i].ReloadsManual);
    P32(k + 2, @DP.Weapons[i].RoundsDropped);
    P32(k + 3, @DP.Weapons[i].ReloadsDone);
    P32(k + 4, @DP.Weapons[i].ReloadsCut);
    P32(k + 5, @DP.Weapons[i].ReloadDeaths);
    P32(k + 6, @DP.Weapons[i].ReloadTimed);
    P64(k + 7, @DP.Weapons[i].ReloadTicks);
    P64(k + 8, @DP.Weapons[i].ReloadNormTicks);
    P32(k + 9, @DP.Weapons[i].ReloadEnds);
    P64(k + 10, @DP.Weapons[i].ReloadDoneMille);
    P64(k + 11, @DP.Weapons[i].ReloadDeathMille);
    P64(k + 12, @DP.Weapons[i].ReloadTicksAll);
  end;

  { rating systems: kept on merge, reset with stats }
  for i := 0 to RF_COUNT - 1 do
  begin
    k := 1400 + i * 8;
    PF64(k + 0, @DP.Glicko[i].R, mkKeep);
    PF64(k + 1, @DP.Glicko[i].RD, mkKeep);
    PF64(k + 2, @DP.Glicko[i].Vol, mkKeep);
    PF64(k + 3, @DP.Glicko[i].LastUpdate, mkKeep);
    P32(k + 4, @DP.Glicko[i].Games, mkKeep);
    k := 1430 + i * 4;
    PF64(k + 0, @DP.OpenSkill[i].Mu, mkKeep);
    PF64(k + 1, @DP.OpenSkill[i].Sigma, mkKeep);
    P32(k + 2, @DP.OpenSkill[i].Games, mkKeep);
    k := 1441 + i * 3;   { 1441..1448, the gap between OpenSkill and the mode statistics }
    PF64(k + 0, @DP.Mmr[i].R, mkKeep);
    P32(k + 1, @DP.Mmr[i].Games, mkKeep);
  end;

  for i := 0 to 6 do
  begin
    k := 1450 + i * 8;
    P32(k + 0, @DP.ModeStats[i].Kills);
    P32(k + 1, @DP.ModeStats[i].Deaths);
    P32(k + 2, @DP.ModeStats[i].Wins);
    P32(k + 3, @DP.ModeStats[i].Loses);
    P32(k + 4, @DP.ModeStats[i].Draws);
    P32(k + 5, @DP.ModeStats[i].Caps);
    P64(k + 6, @DP.ModeStats[i].TimePlayed);
  end;

  for i := 0 to 2 do
  begin
    k := 1510 + i * 8;
    P32(k + 0, @DP.Period[i].Key, mkKeep);
    P32(k + 1, @DP.Period[i].Kills, mkKeep);
    P32(k + 2, @DP.Period[i].Deaths, mkKeep);
    P32(k + 3, @DP.Period[i].PointsDelta, mkKeep);
    P32(k + 4, @DP.Period[i].Caps, mkKeep);
    P32(k + 5, @DP.Period[i].Wins, mkKeep);
    P32(k + 6, @DP.Period[i].Headshots, mkKeep);
    P64(k + 7, @DP.Period[i].TimePlayed, mkKeep);
  end;

  P32(1540, @DP.SeasonId, mkKeep, False);
  P32(1541, @DP.SeasonPoints, mkKeep);
  P32(1542, @DP.SeasonKills, mkKeep);
  P32(1543, @DP.SeasonDeaths, mkKeep);
  P32(1544, @DP.SeasonCaps, mkKeep);
  P32(1545, @DP.SeasonWins, mkKeep);
  P64(1546, @DP.SeasonTime, mkKeep);
  PX(1550, fkBadges, @DP.Badges);
  PX(1551, fkAchievements, @DP.Achievements);
end;

procedure RegisterMapFields;
var
  i: LongInt;
begin
  M32(1, @DM.ID, mkKeep, False);
  AddDef(MapFields, @DM, 2, fkString, @DM.MapName, mkKeep, False);
  AddDef(MapFields, @DM, 3, fkDouble, @DM.FirstPlayedTime, mkKeep, False);
  AddDef(MapFields, @DM, 4, fkDouble, @DM.LastPlayedTime, mkKeep, False);
  M32(10, @DM.Kills);
  M32(11, @DM.Selfkills);
  M32(12, @DM.ActiveMapPlays);
  M32(13, @DM.ActiveTimePlays);
  M32(14, @DM.AlphaWins);
  M32(15, @DM.BravoWins);
  M32(16, @DM.CharlieWins);
  M32(17, @DM.DeltaWins);
  M32(18, @DM.Draws);
  M32(19, @DM.AlphaRoundWins);
  M32(20, @DM.BravoRoundWins);
  M32(21, @DM.CharlieRoundWins);
  M32(22, @DM.DeltaRoundWins);
  M32(23, @DM.FlagsGrabs);
  M32(24, @DM.FlagsReturns);
  M32(25, @DM.FlagsDrop);
  M32(26, @DM.FlagsThrown);
  M32(27, @DM.FlagsScore);
  M32(28, @DM.JoinGameCount);
  M32(29, @DM.LeaveGameCount);
  M32(30, @DM.KickedCount);
  M32(31, @DM.JoinToSpectator);
  MF32(32, @DM.FastestCapSeconds);
  AddDef(MapFields, @DM, 33, fkString, @DM.FastestCapHolder, mkKeep, True);
  M32(34, @DM.ComebackMatches);
  M32(35, @DM.CloseMatches);
  M32(36, @DM.MatchesAborted);
  M32(37, @DM.LoadCount);
  MF64(38, @DM.CapTimeSum);
  M32(39, @DM.CapTimeCount);
  M64(40, @DM.MatchDurationSum);
  M64(41, @DM.HumansSampleSum);
  M32(42, @DM.HumansSampleCount);
  M32(43, @DM.VoteStarts);
  M32(240, @DM.VotesPassed);
  M32(241, @DM.VotedIn);
  M64(242, @DM.EndHumansSum);
  M64(243, @DM.StayedHumansSum);
  M32(244, @DM.RetentionCount);
  MF64(245, @DM.HealRegen);
  M32(246, @DM.ScoreCount);
  M64(247, @DM.ScoreBase);
  for i := 0 to 9 do
  begin
    M64(220 + i, @DM.CurveSum[i]);
    M32(230 + i, @DM.CurveSecs[i]);
  end;
  M64(48, @DM.ScoreSum);
  M32(49, @DM.MatchDurationCount);
  M64(51, @DM.MatchDurationBase);
  MF32(60, @DM.AlphaFlagX, False);
  MF32(61, @DM.AlphaFlagY, False);
  MF32(62, @DM.BravoFlagX, False);
  MF32(63, @DM.BravoFlagY, False);
  MF32(44, @DM.MinX, False);
  MF32(45, @DM.MinY, False);
  MF32(46, @DM.MaxX, False);
  MF32(47, @DM.MaxY, False);
  AddDef(MapFields, @DM, 50, fkHeat, @DM.Heat, mkKeep, True);
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    M32(100 + i, @DM.WeaponKills[i]);
    M32(130 + i, @DM.WeaponPicks[i]);
    M32(160 + i, @DM.WeaponPicksTeam[1, i]);
    M32(190 + i, @DM.WeaponPicksTeam[2, i]);
  end;
end;

procedure RegisterServerFields;
var
  i, j, k: LongInt;
begin
  S32(1, @DS.PeakOnlineCount);
  S64(2, @DS.PeakOnlineDurationSec);
  SF64(3, @DS.PeakOnlineDate);
  for i := 0 to 23 do
    S64(10 + i, @DS.HourlyActivity[i]);
  for i := 0 to 6 do
    for j := 0 to 23 do
      S64(40 + i * 24 + j, @DS.WeekdayHour[i, j]);
  for i := 0 to WSLOT_COUNT - 1 do
    for j := 0 to WSLOT_COUNT - 1 do
      S32(300 + i * WSLOT_COUNT + j, @DS.Matchups[i, j]);
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    k := 800 + i * 10;
    for j := 0 to 4 do
      S64(k + j, @DS.WeaponGlobal[i].DistBucket[j]);
    SF64(k + 5, @DS.WeaponGlobal[i].KillDistSum);
    S64(k + 6, @DS.WeaponGlobal[i].KillDistCount);
    S64(k + 7, @DS.WeaponGlobal[i].TTKSumTicks);
    S64(k + 8, @DS.WeaponGlobal[i].TTKCount);
    S64(k + 9, @DS.WeaponGlobal[i].VestKills);
    S64(1020 + i, @DS.WeaponGlobal[i].Picks);
    for j := 1 to 4 do
      S64(1400 + i * 4 + j - 1, @DS.WeaponGlobal[i].PicksTeam[j]);
  end;
  for i := 0 to 3 do
    for j := 0 to 2 do
    begin
      k := 1100 + i * 18 + j * 6;
      S64(k + 0, @DS.HitModel[i, j].N);
      SF64(k + 1, @DS.HitModel[i, j].SumX);
      SF64(k + 2, @DS.HitModel[i, j].SumY);
      SF64(k + 3, @DS.HitModel[i, j].SumXX);
      SF64(k + 4, @DS.HitModel[i, j].SumYY);
      SF64(k + 5, @DS.HitModel[i, j].SumXY);
    end;
  AddDef(ServerFields, @DS, 1200, fkDaily, @DS.Daily, mkKeep, False);
  S32(1300, @DS.NextProfileID);
  S32(1301, @DS.NextMapID);
  S32(1302, @DS.NextSeasonId);
  S32(1303, @DS.SeasonId);
  SF64(1304, @DS.SeasonStart);
  SF64(1305, @DS.SeasonEnd);
  S32(1306, @DS.LastBalanceDay);
  S32(1307, @DS.LastCheckpointsDay);
  SF64(1308, @DS.LastAutoBackup);
  SF64(1312, @DS.CheckWaitSince);
  S64(1309, @DS.TotalMatches);
  AddDef(ServerFields, @DS, 1310, fkBool, @DS.MatchupsFixed, mkKeep, False);
  AddDef(ServerFields, @DS, 1311, fkBool, @DS.MatchLengthsSplit, mkKeep, False);
  AddDef(ServerFields, @DS, 1313, fkBool, @DS.ScoresSplit, mkKeep, False);
  S64(1318, @DS.ScoreFixes);
  S64(1319, @DS.VoidedCaptures);
  S64(1320, @DS.BalPredCount);
  SF64(1321, @DS.BalBrierSum);
  for i := 0 to 9 do
  begin
    S64(1330 + i, @DS.BalBinCount[i]);
    S64(1340 + i, @DS.BalBinWins[i]);
  end;
end;

procedure PM32(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(PlayerMapFields, @DPM, Id, fkInt32, Addr, Merge, Stat); end;
procedure PMF64(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(PlayerMapFields, @DPM, Id, fkDouble, Addr, Merge, Stat); end;
procedure PMF32(Id: Word; Addr: Pointer; Merge: TMergeKind = mkSum; Stat: Boolean = True);
begin AddDef(PlayerMapFields, @DPM, Id, fkSingle, Addr, Merge, Stat); end;

{ a counter of the player-on-map record (added up, a statistic) that follows the account's counter
  at PAddr, of the same Kind (PMFollows) }
procedure PMFollow(Id: Word; RAddr, PAddr: Pointer; Kind: TFieldKind);
var
  n: LongInt;
begin
  AddDef(PlayerMapFields, @DPM, Id, Kind, RAddr, mkSum, True);
  n := Length(PMFollows);
  if n >= PM_FOLLOW_MAX then
    raise Exception.CreateFmt('zs_fields: more than %d counters follow the account''s', [PM_FOLLOW_MAX]);
  SetLength(PMFollows, n + 1);
  PMFollows[n].Id := Id;
  PMFollows[n].Kind := Kind;
  PMFollows[n].ProfileOffset := PtrUInt(PAddr) - PtrUInt(@DP);
  PMFollows[n].RecordOffset := PtrUInt(RAddr) - PtrUInt(@DPM);
end;

{ [Matrix]: the distances and times to kill of an account's weapons, the fields of maps added with
  it, the player-on-map records and the entries of their lists }
procedure RegisterMatrixFields;
var
  i, j, k: LongInt;
begin
  { the kills of the account with each weapon as the server keeps them (TWeaponGlobal):
    3000 + slot * 16 + k }
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    k := 3000 + i * 16;
    for j := 0 to 4 do
      P32(k + j, @DP.Weapons[i].DistBucket[j]);
    PF64(k + 5, @DP.Weapons[i].KillDistSum);
    P32(k + 6, @DP.Weapons[i].KillDistCount);
    P64(k + 7, @DP.Weapons[i].TTKSumTicks);
    P32(k + 8, @DP.Weapons[i].TTKCount);
    P32(k + 9, @DP.Weapons[i].VestKills);
  end;
  { [Bridges] (5.6): the hits' distance and air time and the kills' air time of each weapon:
    4000 + slot * 16 + k }
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    k := 4000 + i * 16;
    PF64(k + 0, @DP.Weapons[i].HitDistSum);
    P32(k + 1, @DP.Weapons[i].HitDistCount);
    PF32(k + 2, @DP.Weapons[i].LongestHit, mkMax);
    P64(k + 3, @DP.Weapons[i].HitAirTicks);
    P32(k + 4, @DP.Weapons[i].HitAirCount);
    P64(k + 5, @DP.Weapons[i].KillAirTicks);
    P32(k + 6, @DP.Weapons[i].KillAirCount);
  end;

  { maps (260..299): the date is no statistic, a reset keeps it }
  AddDef(MapFields, @DM, 260, fkDouble, @DM.LastLoadedTime, mkMax, False);
  for i := 1 to 4 do
    M32(260 + i, @DM.RoundsElimination[i]);
  M32(265, @DM.RoundsLastStanding);
  M32(266, @DM.RoundsCapture);
  M32(267, @DM.RoundsNoSurvivor);
  M32(268, @DM.RoundsMapChange);
  for i := 1 to 4 do
    M32(268 + i, @DM.KillsByTeam[i]);
  AddDef(MapFields, @DM, 273, fkMatchups, @DM.Matchups, mkKeep, True);
  { [Bridges] (5.6): the hits and kills of the map measured from where their bullet was made }
  MF64(274, @DM.HitDistSum);
  M64(275, @DM.HitDistCount);
  AddDef(MapFields, @DM, 276, fkSingle, @DM.LongestHit, mkMax, True);
  M64(277, @DM.HitAirTicks);
  M64(278, @DM.HitAirCount);
  M64(279, @DM.KillAirTicks);
  M64(280, @DM.KillAirCount);

  { the player-on-map record: the key, the dates, the counters, the lists }
  PM32(1, @DPM.AccountId, mkKeep, False);
  AddDef(PlayerMapFields, @DPM, 2, fkString, @DPM.MapName, mkKeep, False);
  PMF64(3, @DPM.FirstPlayed, mkMinPos, False);
  PMF64(4, @DPM.LastPlayed, mkMax, False);
  AddDef(PlayerMapFields, @DPM, 10, fkInt64, @DPM.TimePlayed, mkSum, True);
  PM32(11, @DPM.Matches);
  PM32(12, @DPM.Wins);
  PM32(13, @DPM.Losses);
  PM32(14, @DPM.Draws);
  PM32(15, @DPM.RoundsWon);
  PM32(16, @DPM.RoundsLost);
  PM32(17, @DPM.Kills);
  PM32(18, @DPM.Deaths);
  PM32(19, @DPM.Selfkills);
  PM32(20, @DPM.Teamkills);
  PM32(21, @DPM.Assists);
  PM32(22, @DPM.Points);
  PM32(23, @DPM.Caps);
  PM32(24, @DPM.Returns);
  PM32(25, @DPM.Grabs);
  PM32(26, @DPM.Shots);
  PM32(27, @DPM.Hits);
  PM32(28, @DPM.HitsHead);
  PM32(29, @DPM.HitsBody);
  PM32(30, @DPM.HitsLegs);
  PMF64(31, @DPM.DamageDealt);
  PMF64(32, @DPM.DamageReceived);
  PMF64(33, @DPM.HealRegen);
  PM32(34, @DPM.BestStreak, mkMax);
  PM32(35, @DPM.FirstBloods);
  PM32(36, @DPM.RoundFirstBloods);
  PM32(37, @DPM.LastStands);
  AddDef(PlayerMapFields, @DPM, 38, fkSingle, @DPM.LongestKill, mkMax, True);
  AddDef(PlayerMapFields, @DPM, 50, fkPMWeapons, @DPM.Weapons, mkKeep, True);
  AddDef(PlayerMapFields, @DPM, 51, fkPMRivals, @DPM.Rivals, mkKeep, True);
  AddDef(PlayerMapFields, @DPM, 52, fkPMMatchups, @DPM.Matchups, mkKeep, True);
  AddDef(PlayerMapFields, @DPM, 53, fkHeat, @DPM.Heat, mkKeep, True);

  { what else the account's own statistics count, the same way on the map (60-199): the counters
    that follow the account's (PMFollow), and the bests and counts the engine keeps itself
    (zs_engine_matrix.inc) }
  { lives, time and movement (60-69) }
  PMFollow(60, @DPM.TimeAlive, @DP.TimeAlive, fkInt64);
  PM32(61, @DPM.LongestLife, mkMax);
  PM32(62, @DPM.TeamkillDeaths);
  PMFollow(63, @DPM.Traveled, @DP.DistanceTraveledM, fkDouble);
  PMF32(64, @DPM.BestLifeDistance, mkMax);
  PMFollow(65, @DPM.JetTime, @DP.JetFlyTimeSeconds, fkInt64);
  { damage, hits and healing (70-89) }
  PMFollow(70, @DPM.DamageFriendly, @DP.DamageFriendly, fkDouble);
  PMFollow(71, @DPM.DamageFriendlyReceived, @DP.DamageFriendlyReceived, fkDouble);
  PMFollow(72, @DPM.HitsUnknown, @DP.ShotsHitsUnknown, fkInt32);
  PMFollow(73, @DPM.FriendlyHits, @DP.ShotsHitsFriendly, fkInt32);
  PMFollow(74, @DPM.FriendlyHitsHead, @DP.ShotsHitsFriendlyHead, fkInt32);
  PMFollow(75, @DPM.FriendlyHitsBody, @DP.ShotsHitsFriendlyBody, fkInt32);
  PMFollow(76, @DPM.FriendlyHitsLegs, @DP.ShotsHitsFriendlyLeg, fkInt32);
  PMFollow(77, @DPM.HitsByFriendly, @DP.ShotsHitsByFriendly, fkInt32);
  PMFollow(78, @DPM.SelfHits, @DP.ShotsHitsSelf, fkInt32);
  PMFollow(79, @DPM.FirstDamages, @DP.FirstDamageCount, fkInt32);
  PMF64(80, @DPM.HealKits);
  PM32(81, @DPM.HealKitCount);
  { the kits by kind: 82 + the place in KIT_KIND_STYLES (82 medical ... 88 flamer) }
  for i := 0 to KIT_KINDS - 1 do
    PM32(82 + i, @DPM.KitPickups[i]);
  { kills (90-139) }
  PMFollow(90, @DPM.PosthumousKills, @DP.PosthumousKills, fkInt32);
  PMFollow(91, @DPM.RevengeKills, @DP.RevengeKills, fkInt32);
  PMFollow(92, @DPM.AvengerKills, @DP.AvengerKills, fkInt32);
  PMFollow(93, @DPM.SaviorKills, @DP.SaviorKills, fkInt32);
  PMFollow(94, @DPM.Dominations, @DP.DominatingCount, fkInt32);
  PMFollow(95, @DPM.DominationsEnded, @DP.RevengeFeats, fkInt32);
  PMFollow(96, @DPM.ShutDowns, @DP.ShutDownKills, fkInt32);
  PMFollow(97, @DPM.Finishers, @DP.FinisherKills, fkInt32);
  PMFollow(98, @DPM.GrenadeKills, @DP.GrenadeKills, fkInt32);
  PMFollow(99, @DPM.ExplosionMultiKills, @DP.ExplosionMultiKills, fkInt32);
  PMFollow(100, @DPM.WallKills, @DP.WallKills, fkInt32);
  PM32(101, @DPM.CoverShotKills);
  PMFollow(102, @DPM.BinkRecoveryKills, @DP.BinkRecoveryKills, fkInt32);
  PMFollow(103, @DPM.ProneKills, @DP.ProneKills, fkInt32);
  PMFollow(104, @DPM.AirKills, @DP.AirKills, fkInt32);
  PMFollow(105, @DPM.HeightKills, @DP.HeightKills, fkInt32);
  PMFollow(106, @DPM.CampKills, @DP.CampKills, fkInt32);
  PMFollow(107, @DPM.VestKills, @DP.VestKills, fkInt32);
  PMFollow(108, @DPM.SpawnKills, @DP.SpawnKills, fkInt32);
  PMFollow(109, @DPM.SpawnDeaths, @DP.SpawnDeaths, fkInt32);
  PMFollow(110, @DPM.LongKills100, @DP.LongKills100, fkInt32);
  PMFollow(111, @DPM.BarrettLongKills, @DP.BarrettLongKills, fkInt32);
  PMF32(112, @DPM.LongestBarrett, mkMax);
  PMFollow(113, @DPM.KillDistSum, @DP.TotalKillDistance, fkDouble);
  PMFollow(114, @DPM.KillDistCount, @DP.KillDistanceCount, fkInt64);
  PMFollow(115, @DPM.TTKSumTicks, @DP.TTKSumTicks, fkInt64);
  PMFollow(116, @DPM.TTKCount, @DP.TTKCount, fkInt32);
  PM32(117, @DPM.BestTTKTicks, mkMinPos);
  PM32(118, @DPM.KnifeStreak, mkMax);
  PM32(119, @DPM.ForcedSelfkills);
  PM32(120, @DPM.SelfkillsUnderFire);
  PMFollow(121, @DPM.BaseDefenseKills, @DP.BaseDefenseKills, fkInt32);
  PMFollow(122, @DPM.BaseAttackKills, @DP.BaseAttackKills, fkInt32);
  PMFollow(123, @DPM.DoubleKills, @DP.PointmatchMode.Multi.DOUBLE_KILL, fkInt32);
  PMFollow(124, @DPM.TripleKills, @DP.PointmatchMode.Multi.TRIPLE_KILL, fkInt32);
  PMFollow(125, @DPM.MultiKills, @DP.PointmatchMode.Multi.MULTI_KILL, fkInt32);
  PMFollow(126, @DPM.MultiKillsX2, @DP.PointmatchMode.Multi.MULTI_KILL_X2, fkInt32);
  PMFollow(127, @DPM.SerialKills, @DP.PointmatchMode.Multi.SERIAL_KILL, fkInt32);
  PMFollow(128, @DPM.InsaneKills, @DP.PointmatchMode.Multi.INSANE_KILLS, fkInt32);
  PMFollow(129, @DPM.GimmeMore, @DP.PointmatchMode.Multi.GIMME_MORE, fkInt32);
  PMFollow(130, @DPM.MastaKilla, @DP.PointmatchMode.Multi.MASTA_KILLA, fkInt32);
  PMFollow(131, @DPM.StopIt, @DP.PointmatchMode.Multi.STOP_IT, fkInt32);
  { flags (140-159) }
  PMFollow(140, @DPM.FlagDrops, @DP.FlagsDrop, fkInt32);
  PMFollow(141, @DPM.FlagThrows, @DP.FlagsThrown, fkInt32);
  PMFollow(142, @DPM.FlaggerKills, @DP.FlaggerKills, fkInt32);
  PM32(143, @DPM.FlaggerAssists);
  PMFollow(144, @DPM.FlagDefenses, @DP.SaviorFlaggerKills, fkInt32);
  PMFollow(145, @DPM.KillsWithFlag, @DP.KillsWhenHaveFlag, fkInt32);
  PM32(146, @DPM.FlaggerTeamkills);
  PM32(147, @DPM.TeamkillsWithFlag);
  PMFollow(148, @DPM.FlagHoldTime, @DP.TimeHoldingFlags, fkInt32);
  PMF32(149, @DPM.FastestCap, mkMinPos);
  PMFollow(150, @DPM.CapsUnder10s, @DP.CapsUnder10s, fkInt32);
  PMFollow(151, @DPM.EscortKills, @DP.CarrierEscortKills, fkInt32);
  PMFollow(152, @DPM.FlagJuggles, @DP.FlagJuggles, fkInt32);
  PMFollow(153, @DPM.ContestedHolds, @DP.ContestedHolds, fkInt32);
  PM32(154, @DPM.HtfPoints);
  PMFollow(155, @DPM.HtfHoldTime, @DP.HTFMode.TimeWhenHaveFlag, fkInt64);
  PMFollow(156, @DPM.HtfTeamHoldTime, @DP.HTFMode.TimeWhenTeamHaveFlag, fkInt64);
  { matches and rounds (160-169) }
  PM32(160, @DPM.LeaveLosses);
  PM32(161, @DPM.AlphaWins);
  PM32(162, @DPM.AlphaLosses);
  PM32(163, @DPM.BravoWins);
  PM32(164, @DPM.BravoLosses);
  PM32(165, @DPM.ComebackWins);
  PM32(166, @DPM.ClutchesWon);
  PM32(167, @DPM.AdvanceRoundsWon);
  PM32(168, @DPM.AdvanceRoundsPlayed);
  { the special weapons (170-179) }
  PM32(170, @DPM.KnifeThrows);
  PMFollow(171, @DPM.KnifeThrowHits, @DP.KnivesThrowsHitsEnemy, fkInt32);
  PMFollow(172, @DPM.KnifeStabs, @DP.KnivesStabsEnemy, fkInt32);
  PMFollow(173, @DPM.NadeSelfHits, @DP.NadeHurtsSelf, fkInt32);
  PMFollow(174, @DPM.BowKills, @DP.RamboMode.KillsByBow, fkInt32);
  PMFollow(175, @DPM.BowTime, @DP.RamboMode.TimeWithBow, fkInt64);
  PMFollow(176, @DPM.RamboKills, @DP.RamboMode.KillRamboCount, fkInt32);
  { [Bridges] (5.6): 200-210 }
  PMFollow(200, @DPM.CollateralKills, @DP.CollateralKills, fkInt32);
  PMFollow(201, @DPM.BackKills, @DP.BackKills, fkInt32);
  PMFollow(202, @DPM.BackDeaths, @DP.BackDeaths, fkInt32);
  for i := 0 to 3 do
  begin
    PMFollow(203 + i, @DPM.StanceShots[i], @DP.StanceShots[i], fkInt32);
    PMFollow(207 + i, @DPM.StanceHits[i], @DP.StanceHits[i], fkInt32);
  end;
  { the hits' distance and air time, the kills' air time (211-216) }
  PMFollow(211, @DPM.HitDistSum, @DP.HitDistSum, fkDouble);
  PMFollow(212, @DPM.HitDistCount, @DP.HitDistCount, fkInt64);
  PMFollow(213, @DPM.HitAirTicks, @DP.HitAirTicks, fkInt64);
  PMFollow(214, @DPM.HitAirCount, @DP.HitAirCount, fkInt64);
  PMFollow(215, @DPM.KillAirTicks, @DP.KillAirTicks, fkInt64);
  PMFollow(216, @DPM.KillAirCount, @DP.KillAirCount, fkInt64);
  PMF32(217, @DPM.LongestHit, mkMax);

  { the entries of the lists: the key is kept, the counters add up, a date takes the later one }
  AddDef(PMWeaponFields, @DPW, 1, fkInt32, @DPW.Slot, mkKeep, False);
  AddDef(PMWeaponFields, @DPW, 2, fkInt32, @DPW.Kills, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 3, fkInt32, @DPW.Deaths, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 4, fkInt32, @DPW.Shots, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 5, fkInt32, @DPW.Hits, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 6, fkInt32, @DPW.Headshots, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 7, fkDouble, @DPW.Damage, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 8, fkInt32, @DPW.TimeUsed, mkSum, True);
  { [Bridges] (5.6): the weapon's hits and kills measured from where their bullet was made }
  AddDef(PMWeaponFields, @DPW, 9, fkDouble, @DPW.HitDistSum, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 10, fkInt32, @DPW.HitDistCount, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 11, fkSingle, @DPW.LongestHit, mkMax, True);
  AddDef(PMWeaponFields, @DPW, 12, fkInt32, @DPW.HitAirTicks, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 13, fkInt32, @DPW.HitAirCount, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 14, fkInt32, @DPW.KillAirTicks, mkSum, True);
  AddDef(PMWeaponFields, @DPW, 15, fkInt32, @DPW.KillAirCount, mkSum, True);
  AddDef(PMRivalFields, @DPR, 1, fkInt32, @DPR.Id, mkKeep, False);
  AddDef(PMRivalFields, @DPR, 2, fkInt32, @DPR.Kills, mkSum, True);
  AddDef(PMRivalFields, @DPR, 3, fkInt32, @DPR.Deaths, mkSum, True);
  AddDef(PMRivalFields, @DPR, 4, fkSingle, @DPR.DamageDealt, mkSum, True);
  AddDef(PMRivalFields, @DPR, 5, fkSingle, @DPR.DamageTaken, mkSum, True);
  AddDef(PMRivalFields, @DPR, 6, fkDouble, @DPR.LastFight, mkMax, False);
  { the points won from the rival and lost to him }
  AddDef(PMRivalFields, @DPR, 7, fkInt32, @DPR.PointsWon, mkSum, True);
  AddDef(PMRivalFields, @DPR, 8, fkInt32, @DPR.PointsLost, mkSum, True);
  AddDef(PMMatchupFields, @DPX, 1, fkInt32, @DPX.Mine, mkKeep, False);
  AddDef(PMMatchupFields, @DPX, 2, fkInt32, @DPX.Theirs, mkKeep, False);
  AddDef(PMMatchupFields, @DPX, 3, fkInt32, @DPX.Wins, mkSum, True);
  AddDef(PMMatchupFields, @DPX, 4, fkInt32, @DPX.Losses, mkSum, True);
  AddDef(MatchupCellFields, @DMC, 1, fkInt32, @DMC.Killer, mkKeep, False);
  AddDef(MatchupCellFields, @DMC, 2, fkInt32, @DMC.Victim, mkKeep, False);
  AddDef(MatchupCellFields, @DMC, 3, fkInt32, @DMC.Kills, mkSum, True);
end;

{ ---------------- generic encode / decode ---------------- }

procedure EncodeEntries(var W: TWriter; First: Pointer; Count, Size: LongInt; const Defs: TFieldDefArray); forward;

procedure EncodeFields(var W: TWriter; Base: Pointer; const Defs: TFieldDefArray);
var
  i, j: LongInt;
  Ptr: Pointer;
  V32: LongInt;
  V64: Int64;
  VF32: Single;
  VF64: Double;
  Sub: TWriter;
  Aliases: ^TOtherDataArray;
  Trusted: ^TTrustedDeviceArray;
  Badges: ^TSeasonBadgeArray;
  Ach: ^TAchievementArray;
  Heat: ^THeatCellArray;
  Daily: ^TDailyStatArray;
  Weps: ^TPMWeaponArray;
  Rivs: ^TPMRivalArray;
  Mups: ^TPMMatchupArray;
  Cells: ^TMatchupCellArray;
  Blob: AnsiString;
begin
  for i := 0 to High(Defs) do
  begin
    Ptr := Pointer(PtrUInt(Base) + Defs[i].Offset);
    case Defs[i].Kind of
      fkInt32:
        begin
          V32 := PLongInt(Ptr)^;
          if V32 = 0 then Continue;
          WU16(W, Defs[i].Id); WU8(W, T_I32); WI32(W, V32);
        end;
      fkInt64:
        begin
          V64 := PInt64(Ptr)^;
          if V64 = 0 then Continue;
          WU16(W, Defs[i].Id); WU8(W, T_I64); WI64(W, V64);
        end;
      fkSingle:
        begin
          VF32 := PSingle(Ptr)^;
          if VF32 = 0 then Continue;
          WU16(W, Defs[i].Id); WU8(W, T_F32); WF32(W, VF32);
        end;
      fkDouble:
        begin
          VF64 := PDouble(Ptr)^;
          if VF64 = 0 then Continue;
          WU16(W, Defs[i].Id); WU8(W, T_F64); WF64(W, VF64);
        end;
      fkBool:
        begin
          if not PBoolean(Ptr)^ then Continue;
          WU16(W, Defs[i].Id); WU8(W, T_BOOL); WU8(W, 1);
        end;
      fkString:
        begin
          if PAnsiString(Ptr)^ = '' then Continue;
          WU16(W, Defs[i].Id); WU8(W, T_STR); WStr16(W, PAnsiString(Ptr)^);
        end;
      fkAliases, fkTrusted, fkBadges, fkAchievements, fkHeat, fkDaily, fkPMWeapons, fkPMRivals, fkPMMatchups,
      fkMatchups:
        begin
          WInit(Sub, 256);
          case Defs[i].Kind of
            fkPMWeapons:
              begin
                Weps := Ptr;
                if Length(Weps^) = 0 then Continue;
                EncodeEntries(Sub, @Weps^[0], Length(Weps^), SizeOf(TPMWeapon), PMWeaponFields);
              end;
            fkPMRivals:
              begin
                Rivs := Ptr;
                if Length(Rivs^) = 0 then Continue;
                EncodeEntries(Sub, @Rivs^[0], Length(Rivs^), SizeOf(TPMRival), PMRivalFields);
              end;
            fkPMMatchups:
              begin
                Mups := Ptr;
                if Length(Mups^) = 0 then Continue;
                EncodeEntries(Sub, @Mups^[0], Length(Mups^), SizeOf(TPMMatchup), PMMatchupFields);
              end;
            fkMatchups:
              begin
                Cells := Ptr;
                if Length(Cells^) = 0 then Continue;
                EncodeEntries(Sub, @Cells^[0], Length(Cells^), SizeOf(TMatchupCell), MatchupCellFields);
              end;
            fkAliases:
              begin
                Aliases := Ptr;
                if Length(Aliases^) = 0 then Continue;
                WU32(Sub, Length(Aliases^));
                for j := 0 to High(Aliases^) do
                  WRaw(Sub, @Aliases^[j], SizeOf(TOtherData));
              end;
            fkTrusted:
              begin
                Trusted := Ptr;
                if Length(Trusted^) = 0 then Continue;
                WU32(Sub, Length(Trusted^));
                for j := 0 to High(Trusted^) do
                begin
                  WStr16(Sub, Trusted^[j].HWID);
                  WStr16(Sub, Trusted^[j].IPPrefix);
                  WF64(Sub, Trusted^[j].Expire);
                  WF64(Sub, Trusted^[j].LastUsed);
                end;
              end;
            fkBadges:
              begin
                Badges := Ptr;
                if Length(Badges^) = 0 then Continue;
                WU32(Sub, Length(Badges^));
                for j := 0 to High(Badges^) do
                begin
                  WI32(Sub, Badges^[j].SeasonId);
                  WI32(Sub, Badges^[j].Place);
                end;
              end;
            fkAchievements:
              begin
                Ach := Ptr;
                if Length(Ach^) = 0 then Continue;
                WU32(Sub, Length(Ach^));
                for j := 0 to High(Ach^) do
                begin
                  WI32(Sub, Ach^[j].Id);
                  WF64(Sub, Ach^[j].Date);
                end;
              end;
            fkHeat:
              begin
                Heat := Ptr;
                if Length(Heat^) = 0 then Continue;
                WU32(Sub, Length(Heat^));
                for j := 0 to High(Heat^) do
                begin
                  WI32(Sub, Heat^[j].Cell);
                  WI32(Sub, Heat^[j].Kills);
                  WI32(Sub, Heat^[j].Deaths);
                end;
              end;
            fkDaily:
              begin
                Daily := Ptr;
                if Length(Daily^) = 0 then Continue;
                WU32(Sub, Length(Daily^));
                for j := 0 to High(Daily^) do
                begin
                  WI32(Sub, Daily^[j].Day);
                  WI32(Sub, Daily^[j].Uniques);
                  WI32(Sub, Daily^[j].NewPlayers);
                  WI32(Sub, Daily^[j].Sessions);
                  WI64(Sub, Daily^[j].PlaySeconds);
                  WI32(Sub, Daily^[j].PeakOnline);
                  WI32(Sub, Daily^[j].Kills);
                end;
              end;
          end;
          Blob := WDone(Sub);
          WU16(W, Defs[i].Id); WU8(W, T_BLOB); WU32(W, Length(Blob));
          if Blob <> '' then WRaw(W, @Blob[1], Length(Blob));
        end;
    end;
  end;
end;

{ the entries of a list, each a small record of its own: the count, then per entry its length (two
  bytes) and its fields, so a field added to an entry later needs no migration either }
procedure EncodeEntries(var W: TWriter; First: Pointer; Count, Size: LongInt; const Defs: TFieldDefArray);
var
  j, At: LongInt;
  L: Word;
begin
  WU32(W, Count);
  for j := 0 to Count - 1 do
  begin
    At := W.Len;
    WU16(W, 0);
    EncodeFields(W, Pointer(PtrUInt(First) + PtrUInt(j) * PtrUInt(Size)), Defs);
    { the fields of one entry take a few dozen bytes, far from the limit of the length }
    L := Word(Min(W.Len - At - 2, 65535));
    Move(L, W.Buf[At + 1], 2);
  end;
end;

type
  TDefLookup = array of SmallInt;

var
  ProfileLookup, MapLookup, ServerLookup: TDefLookup;
  SharedProfileFields: TFieldDefArray;   { ProfileFields without the login fields }
  PlayerMapLookup, PMWeaponLookup, PMRivalLookup, PMMatchupLookup, MatchupCellLookup: TDefLookup;

procedure BuildLookup(const Defs: TFieldDefArray; out Lookup: TDefLookup);
var
  i, MaxId: LongInt;
begin
  MaxId := 0;
  for i := 0 to High(Defs) do
    if Defs[i].Id > MaxId then MaxId := Defs[i].Id;
  SetLength(Lookup, MaxId + 1);
  for i := 0 to MaxId do Lookup[i] := -1;
  for i := 0 to High(Defs) do Lookup[Defs[i].Id] := i;
end;

function FindDef(const Lookup: TDefLookup; Id: Word): LongInt; inline;
begin
  if Id < Length(Lookup) then Result := Lookup[Id] else Result := -1;
end;

function DecodeFieldsAt(Data: PByte; Len: LongInt; Base: Pointer; const Defs: TFieldDefArray;
  const Lookup: TDefLookup): Boolean; forward;

{ Places (0..n-1) put in the order of their keys; the keys stay where they are }
procedure SortPlaces(const Keys: array of Int64; var Places: array of LongInt; L, R: LongInt);
var
  i, j, T: LongInt;
  Pivot: Int64;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := Keys[Places[(L + R) shr 1]];
    repeat
      while Keys[Places[i]] < Pivot do
        Inc(i);
      while Keys[Places[j]] > Pivot do
        Dec(j);
      if i <= j then
      begin
        T := Places[i];
        Places[i] := Places[j];
        Places[j] := T;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - L < R - i then
    begin
      SortPlaces(Keys, Places, L, j);
      L := i;
    end
    else
    begin
      SortPlaces(Keys, Places, i, R);
      R := j;
    end;
  end;
end;

procedure SortByKeys(const Keys: array of Int64; var Places: array of LongInt);
begin
  if Length(Places) > 1 then
    SortPlaces(Keys, Places, 0, High(Places));
end;

{ The order a list of n entries with these keys needs, nil when it is in order already (each key
  larger than the one before) }
function OrderOf(const Keys: array of Int64): TIntArray;
var
  i: LongInt;
  Sorted: Boolean;
begin
  Result := nil;
  Sorted := True;
  for i := 1 to High(Keys) do
    if Keys[i] <= Keys[i - 1] then
      Sorted := False;
  if Sorted then
    Exit;
  SetLength(Result, Length(Keys));
  for i := 0 to High(Result) do
    Result[i] := i;
  SortPlaces(Keys, Result, 0, High(Result));
end;

{ A list as the data brought it: the entries whose key is no weapon slot (or no account) go, the
  rest is put in the order of the keys, and an entry that is there twice is added up into one. The
  lists this library writes are in order already. }
procedure NormalizeWeapons(var A: TPMWeaponArray);
var
  Keys: array of Int64;
  Order: TIntArray;
  B: TPMWeaponArray;
  i, n: LongInt;
begin
  n := 0;
  for i := 0 to High(A) do
    if (A[i].Slot >= 0) and (A[i].Slot < WSLOT_COUNT) then
    begin
      A[n] := A[i];
      Inc(n);
    end;
  SetLength(A, n);
  SetLength(Keys, n);
  for i := 0 to n - 1 do
    Keys[i] := A[i].Slot;
  Order := OrderOf(Keys);
  if Order = nil then
    Exit;
  SetLength(B, n);
  for i := 0 to n - 1 do
    B[i] := A[Order[i]];
  n := 0;
  for i := 0 to High(B) do
    if (n > 0) and (B[n - 1].Slot = B[i].Slot) then
      SumFields(@B[n - 1], @B[i], PMWeaponFields)
    else
    begin
      B[n] := B[i];
      Inc(n);
    end;
  SetLength(B, n);
  A := B;
end;

procedure NormalizeRivals(var A: TPMRivalArray);
var
  Keys: array of Int64;
  Order: TIntArray;
  B: TPMRivalArray;
  i, n: LongInt;
begin
  n := 0;
  for i := 0 to High(A) do
    if A[i].Id > 0 then
    begin
      A[n] := A[i];
      Inc(n);
    end;
  SetLength(A, n);
  SetLength(Keys, n);
  for i := 0 to n - 1 do
    Keys[i] := A[i].Id;
  Order := OrderOf(Keys);
  if Order = nil then
    Exit;
  SetLength(B, n);
  for i := 0 to n - 1 do
    B[i] := A[Order[i]];
  n := 0;
  for i := 0 to High(B) do
    if (n > 0) and (B[n - 1].Id = B[i].Id) then
      SumFields(@B[n - 1], @B[i], PMRivalFields)
    else
    begin
      B[n] := B[i];
      Inc(n);
    end;
  SetLength(B, n);
  A := B;
end;

procedure NormalizeMatchups(var A: TPMMatchupArray);
var
  Keys: array of Int64;
  Order: TIntArray;
  B: TPMMatchupArray;
  i, n: LongInt;
begin
  n := 0;
  for i := 0 to High(A) do
    if (A[i].Mine >= 0) and (A[i].Mine < WSLOT_COUNT) and (A[i].Theirs >= 0) and (A[i].Theirs < WSLOT_COUNT) then
    begin
      A[n] := A[i];
      Inc(n);
    end;
  SetLength(A, n);
  SetLength(Keys, n);
  for i := 0 to n - 1 do
    Keys[i] := A[i].Mine * 64 + A[i].Theirs;
  Order := OrderOf(Keys);
  if Order = nil then
    Exit;
  SetLength(B, n);
  for i := 0 to n - 1 do
    B[i] := A[Order[i]];
  n := 0;
  for i := 0 to High(B) do
    if (n > 0) and (B[n - 1].Mine = B[i].Mine) and (B[n - 1].Theirs = B[i].Theirs) then
      SumFields(@B[n - 1], @B[i], PMMatchupFields)
    else
    begin
      B[n] := B[i];
      Inc(n);
    end;
  SetLength(B, n);
  A := B;
end;

procedure NormalizeCells(var A: TMatchupCellArray);
var
  Keys: array of Int64;
  Order: TIntArray;
  B: TMatchupCellArray;
  i, n: LongInt;
begin
  n := 0;
  for i := 0 to High(A) do
    if (A[i].Killer >= 0) and (A[i].Killer < WSLOT_COUNT) and (A[i].Victim >= 0) and (A[i].Victim < WSLOT_COUNT) then
    begin
      A[n] := A[i];
      Inc(n);
    end;
  SetLength(A, n);
  SetLength(Keys, n);
  for i := 0 to n - 1 do
    Keys[i] := A[i].Killer * 64 + A[i].Victim;
  Order := OrderOf(Keys);
  if Order = nil then
    Exit;
  SetLength(B, n);
  for i := 0 to n - 1 do
    B[i] := A[Order[i]];
  n := 0;
  for i := 0 to High(B) do
    if (n > 0) and (B[n - 1].Killer = B[i].Killer) and (B[n - 1].Victim = B[i].Victim) then
      SumFields(@B[n - 1], @B[i], MatchupCellFields)
    else
    begin
      B[n] := B[i];
      Inc(n);
    end;
  SetLength(B, n);
  A := B;
end;

{ the heat cells of a player on a map, kept in the order of the cells as the map's own }
procedure NormalizeHeat(var A: THeatCellArray);
var
  Keys: array of Int64;
  Order: TIntArray;
  B: THeatCellArray;
  i, n: LongInt;
begin
  SetLength(Keys, Length(A));
  for i := 0 to High(A) do
    Keys[i] := A[i].Cell;
  Order := OrderOf(Keys);
  if Order = nil then
    Exit;
  SetLength(B, Length(A));
  for i := 0 to High(A) do
    B[i] := A[Order[i]];
  n := 0;
  for i := 0 to High(B) do
    if (n > 0) and (B[n - 1].Cell = B[i].Cell) then
    begin
      Inc(B[n - 1].Kills, B[i].Kills);
      Inc(B[n - 1].Deaths, B[i].Deaths);
    end
    else
    begin
      B[n] := B[i];
      Inc(n);
    end;
  SetLength(B, n);
  A := B;
end;

{ Count entries of a list, each with its length in front (EncodeEntries), into the fresh (zeroed)
  entries at First }
function DecodeEntries(var R: TReader; First: Pointer; Count, Size: LongInt; const Defs: TFieldDefArray;
  const Lookup: TDefLookup): Boolean;
var
  j: LongInt;
  L: Word;
begin
  Result := False;
  for j := 0 to Count - 1 do
  begin
    L := RU16(R);
    if not RNeed(R, L) then
      Exit;
    if not DecodeFieldsAt(R.P, L, Pointer(PtrUInt(First) + PtrUInt(j) * PtrUInt(Size)), Defs, Lookup) then
      Exit;
    RSkip(R, L);
  end;
  Result := R.Ok;
end;

function DecodeBlob(Kind: TFieldKind; Ptr: Pointer; const Blob: AnsiString): Boolean;
var
  R: TReader;
  Count: LongWord;
  j, n: LongInt;
  Aliases: ^TOtherDataArray;
  Trusted: ^TTrustedDeviceArray;
  Badges: ^TSeasonBadgeArray;
  Ach: ^TAchievementArray;
  Heat: ^THeatCellArray;
  Daily: ^TDailyStatArray;
  Weps: ^TPMWeaponArray;
  Rivs: ^TPMRivalArray;
  Mups: ^TPMMatchupArray;
  Cells: ^TMatchupCellArray;
begin
  RInit(R, Blob);
  Count := RU32(R);
  if not R.Ok or (Count > 1000000) then Exit(False);
  n := LongInt(Count);
  { every entry of these lists takes two bytes at least (its length) }
  if (Kind in [fkPMWeapons, fkPMRivals, fkPMMatchups, fkMatchups]) and (R.Remaining < Int64(Count) * 2) then
    Exit(False);
  case Kind of
    fkPMWeapons:
      begin
        Weps := Ptr;
        Weps^ := nil;
        SetLength(Weps^, n);
        if (n > 0) and not DecodeEntries(R, @Weps^[0], n, SizeOf(TPMWeapon), PMWeaponFields, PMWeaponLookup) then
          Exit(False);
        NormalizeWeapons(Weps^);
      end;
    fkPMRivals:
      begin
        Rivs := Ptr;
        Rivs^ := nil;
        SetLength(Rivs^, n);
        if (n > 0) and not DecodeEntries(R, @Rivs^[0], n, SizeOf(TPMRival), PMRivalFields, PMRivalLookup) then
          Exit(False);
        NormalizeRivals(Rivs^);
      end;
    fkPMMatchups:
      begin
        Mups := Ptr;
        Mups^ := nil;
        SetLength(Mups^, n);
        if (n > 0) and not DecodeEntries(R, @Mups^[0], n, SizeOf(TPMMatchup), PMMatchupFields, PMMatchupLookup) then
          Exit(False);
        NormalizeMatchups(Mups^);
      end;
    fkMatchups:
      begin
        Cells := Ptr;
        Cells^ := nil;
        SetLength(Cells^, n);
        if (n > 0) and not DecodeEntries(R, @Cells^[0], n, SizeOf(TMatchupCell), MatchupCellFields, MatchupCellLookup) then
          Exit(False);
        NormalizeCells(Cells^);
      end;
    fkAliases:
      begin
        Aliases := Ptr;
        if R.Remaining < Int64(Count) * SizeOf(TOtherData) then Exit(False);
        SetLength(Aliases^, Count);
        for j := 0 to n - 1 do
        begin
          RRaw(R, @Aliases^[j], SizeOf(TOtherData));
          Aliases^[j].DataString[MAX_STRING_LEN - 1] := #0;
        end;
      end;
    fkTrusted:
      begin
        Trusted := Ptr;
        if R.Remaining < Int64(Count) * 20 then Exit(False);
        SetLength(Trusted^, Count);
        for j := 0 to n - 1 do
        begin
          Trusted^[j].HWID := RStr16(R);
          Trusted^[j].IPPrefix := RStr16(R);
          Trusted^[j].Expire := RF64(R);
          Trusted^[j].LastUsed := RF64(R);
          if not R.Ok then Break;
        end;
      end;
    fkBadges:
      begin
        Badges := Ptr;
        if R.Remaining < Int64(Count) * 8 then Exit(False);
        SetLength(Badges^, Count);
        for j := 0 to n - 1 do
        begin
          Badges^[j].SeasonId := RI32(R);
          Badges^[j].Place := RI32(R);
        end;
      end;
    fkAchievements:
      begin
        Ach := Ptr;
        if R.Remaining < Int64(Count) * 12 then Exit(False);
        SetLength(Ach^, Count);
        for j := 0 to n - 1 do
        begin
          Ach^[j].Id := RI32(R);
          Ach^[j].Date := RF64(R);
        end;
      end;
    fkHeat:
      begin
        Heat := Ptr;
        if R.Remaining < Int64(Count) * 12 then Exit(False);
        SetLength(Heat^, Count);
        for j := 0 to n - 1 do
        begin
          Heat^[j].Cell := RI32(R);
          Heat^[j].Kills := RI32(R);
          Heat^[j].Deaths := RI32(R);
        end;
      end;
    fkDaily:
      begin
        Daily := Ptr;
        if R.Remaining < Int64(Count) * 32 then Exit(False);
        SetLength(Daily^, Count);
        for j := 0 to n - 1 do
        begin
          Daily^[j].Day := RI32(R);
          Daily^[j].Uniques := RI32(R);
          Daily^[j].NewPlayers := RI32(R);
          Daily^[j].Sessions := RI32(R);
          Daily^[j].PlaySeconds := RI64(R);
          Daily^[j].PeakOnline := RI32(R);
          Daily^[j].Kills := RI32(R);
        end;
      end;
  end;
  Result := R.Ok;
end;

{ the fields in the Len bytes at Data (a record, or one entry of a list) }
function DecodeFieldsAt(Data: PByte; Len: LongInt; Base: Pointer; const Defs: TFieldDefArray;
  const Lookup: TDefLookup): Boolean;
var
  R: TReader;
  Id: Word;
  T: Byte;
  Idx: LongInt;
  Ptr: Pointer;
  V32: LongInt;
  V64: Int64;
  VF32: Single;
  VF64: Double;
  B: Byte;
  S: AnsiString;
  BlobLen: LongWord;
  Blob: AnsiString;
begin
  R.P := Data;
  R.Remaining := Len;
  R.Ok := Len >= 0;
  while R.Ok and (R.Remaining > 0) do
  begin
    Id := RU16(R);
    T := RU8(R);
    if not R.Ok then Break;
    Idx := FindDef(Lookup, Id);
    if Idx >= 0 then Ptr := Pointer(PtrUInt(Base) + Defs[Idx].Offset) else Ptr := nil;
    case T of
      T_I32:
        begin
          V32 := RI32(R);
          if Ptr <> nil then
            case Defs[Idx].Kind of
              fkInt32: PLongInt(Ptr)^ := V32;
              fkInt64: PInt64(Ptr)^ := V32;
              fkSingle: PSingle(Ptr)^ := V32;
              fkDouble: PDouble(Ptr)^ := V32;
              fkBool: PBoolean(Ptr)^ := V32 <> 0;
            end;
        end;
      T_I64:
        begin
          V64 := RI64(R);
          if Ptr <> nil then
            case Defs[Idx].Kind of
              fkInt32: PLongInt(Ptr)^ := LongInt(EnsureRange(V64, Low(LongInt), High(LongInt)));
              fkInt64: PInt64(Ptr)^ := V64;
              fkDouble: PDouble(Ptr)^ := V64;
            end;
        end;
      T_F32:
        begin
          VF32 := RF32(R);
          if Ptr <> nil then
            case Defs[Idx].Kind of
              fkSingle: PSingle(Ptr)^ := VF32;
              fkDouble: PDouble(Ptr)^ := VF32;
            end;
        end;
      T_F64:
        begin
          VF64 := RF64(R);
          if Ptr <> nil then
            case Defs[Idx].Kind of
              fkSingle: PSingle(Ptr)^ := VF64;
              fkDouble: PDouble(Ptr)^ := VF64;
            end;
        end;
      T_BOOL:
        begin
          B := RU8(R);
          if (Ptr <> nil) and (Defs[Idx].Kind = fkBool) then PBoolean(Ptr)^ := B <> 0;
        end;
      T_STR:
        begin
          S := RStr16(R);
          if (Ptr <> nil) and (Defs[Idx].Kind = fkString) then PAnsiString(Ptr)^ := S;
        end;
      T_BLOB:
        begin
          BlobLen := RU32(R);
          if not RNeed(R, BlobLen) then Break;
          if (Ptr <> nil) and (Defs[Idx].Kind in [fkAliases, fkTrusted, fkBadges, fkAchievements, fkHeat, fkDaily,
            fkPMWeapons, fkPMRivals, fkPMMatchups, fkMatchups]) then
          begin
            SetLength(Blob, BlobLen);
            if BlobLen > 0 then RRaw(R, @Blob[1], BlobLen);
            if not DecodeBlob(Defs[Idx].Kind, Ptr, Blob) then Exit(False);
          end
          else
            RSkip(R, BlobLen);
        end;
      else
        Exit(False); { unknown wire type: the record is corrupt }
    end;
  end;
  Result := R.Ok;
end;

function DecodeFields(const Data: AnsiString; Base: Pointer; const Defs: TFieldDefArray;
  const Lookup: TDefLookup): Boolean;
begin
  Result := DecodeFieldsAt(PByte(PAnsiChar(Data)), Length(Data), Base, Defs, Lookup);
end;

function EncodeProfile(const P: TPlayerProfile): AnsiString;
var
  W: TWriter;
begin
  WInit(W, 1024);
  EncodeFields(W, @P, ProfileFields);
  Result := WDone(W);
end;

function DecodeProfile(const Data: AnsiString; var P: TPlayerProfile): Boolean;
begin
  ClearProfile(P);
  Result := DecodeFields(Data, @P, ProfileFields, ProfileLookup);
end;

function IsLoginField(Id: Word): Boolean;
begin
  Result := ((Id >= 3) and (Id <= 5)) or ((Id >= 20) and (Id <= 38));
end;

procedure BuildSharedProfileFields;
var
  i, n: LongInt;
begin
  SetLength(SharedProfileFields, Length(ProfileFields));
  n := 0;
  for i := 0 to High(ProfileFields) do
    if not IsLoginField(ProfileFields[i].Id) then
    begin
      SharedProfileFields[n] := ProfileFields[i];
      Inc(n);
    end;
  SetLength(SharedProfileFields, n);
end;

function EncodeSharedProfile(const P: TPlayerProfile): AnsiString;
var
  W: TWriter;
begin
  WInit(W, 1024);
  EncodeFields(W, @P, SharedProfileFields);
  Result := WDone(W);
end;

function EncodeMap(const M: TMapProfile): AnsiString;
var
  W: TWriter;
begin
  WInit(W, 512);
  EncodeFields(W, @M, MapFields);
  Result := WDone(W);
end;

function DecodeMap(const Data: AnsiString; var M: TMapProfile): Boolean;
begin
  ClearMap(M);
  Result := DecodeFields(Data, @M, MapFields, MapLookup);
end;

function EncodeServer(const S: TServerRecords): AnsiString;
var
  W: TWriter;
begin
  WInit(W, 4096);
  EncodeFields(W, @S, ServerFields);
  Result := WDone(W);
end;

function DecodeServer(const Data: AnsiString; var S: TServerRecords): Boolean;
begin
  ClearServer(S);
  Result := DecodeFields(Data, @S, ServerFields, ServerLookup);
end;

function EncodePlayerMap(const R: TPlayerMapStats): AnsiString;
var
  W: TWriter;
begin
  WInit(W, 256);
  EncodeFields(W, @R, PlayerMapFields);
  Result := WDone(W);
end;

function DecodePlayerMap(const Data: AnsiString; var R: TPlayerMapStats): Boolean;
begin
  ClearPlayerMap(R);
  Result := DecodeFields(Data, @R, PlayerMapFields, PlayerMapLookup);
  if Result then
    NormalizeHeat(R.Heat);
end;

function EncodeSeason(const A: TSeasonArchive): AnsiString;
var
  W, Sub: TWriter;
  j: LongInt;
  Blob: AnsiString;
begin
  WInit(W, 1024);
  WU16(W, 1); WU8(W, T_I32); WI32(W, A.Id);
  WU16(W, 2); WU8(W, T_F64); WF64(W, A.StartDate);
  WU16(W, 3); WU8(W, T_F64); WF64(W, A.EndDate);
  WInit(Sub, 1024);
  WU32(Sub, Length(A.Entries));
  for j := 0 to High(A.Entries) do
  begin
    WI32(Sub, A.Entries[j].Place);
    WI32(Sub, A.Entries[j].ProfileId);
    WStr16(Sub, A.Entries[j].Name);
    WI32(Sub, A.Entries[j].Points);
    WI32(Sub, A.Entries[j].SeasonPoints);
    WI32(Sub, A.Entries[j].Kills);
    WI32(Sub, A.Entries[j].Deaths);
    WI32(Sub, A.Entries[j].Caps);
    WI32(Sub, A.Entries[j].Wins);
    WI64(Sub, A.Entries[j].TimePlayed);
    WF32(Sub, A.Entries[j].Rating);
  end;
  Blob := WDone(Sub);
  WU16(W, 10); WU8(W, T_BLOB); WU32(W, Length(Blob));
  WRaw(W, @Blob[1], Length(Blob));
  Result := WDone(W);
end;

function DecodeSeason(const Data: AnsiString; var A: TSeasonArchive): Boolean;
var
  R, Sub: TReader;
  Id: Word;
  T: Byte;
  L, Count: LongWord;
  j: LongInt;
  Blob: AnsiString;
begin
  A.Id := 0;
  A.StartDate := 0;
  A.EndDate := 0;
  SetLength(A.Entries, 0);
  RInit(R, Data);
  while R.Ok and (R.Remaining > 0) do
  begin
    Id := RU16(R);
    T := RU8(R);
    case T of
      T_I32: if Id = 1 then A.Id := RI32(R) else RSkip(R, 4);
      T_I64: RSkip(R, 8);
      T_F32: RSkip(R, 4);
      T_F64:
        if Id = 2 then A.StartDate := RF64(R)
        else if Id = 3 then A.EndDate := RF64(R)
        else RSkip(R, 8);
      T_BOOL: RSkip(R, 1);
      T_STR: RStr16(R);
      T_BLOB:
        begin
          L := RU32(R);
          if not RNeed(R, L) then Break;
          SetLength(Blob, L);
          if L > 0 then RRaw(R, @Blob[1], L);
          if Id = 10 then
          begin
            RInit(Sub, Blob);
            Count := RU32(Sub);
            if (Count > 100000) or (Sub.Remaining < Int64(Count) * 46) then Exit(False);
            SetLength(A.Entries, Count);
            for j := 0 to LongInt(Count) - 1 do
            begin
              A.Entries[j].Place := RI32(Sub);
              A.Entries[j].ProfileId := RI32(Sub);
              A.Entries[j].Name := RStr16(Sub);
              A.Entries[j].Points := RI32(Sub);
              A.Entries[j].SeasonPoints := RI32(Sub);
              A.Entries[j].Kills := RI32(Sub);
              A.Entries[j].Deaths := RI32(Sub);
              A.Entries[j].Caps := RI32(Sub);
              A.Entries[j].Wins := RI32(Sub);
              A.Entries[j].TimePlayed := RI64(Sub);
              A.Entries[j].Rating := RF32(Sub);
            end;
            if not Sub.Ok then Exit(False);
          end;
        end;
      else Exit(False);
    end;
  end;
  Result := R.Ok;
end;

{ ---------------- reset / merge ---------------- }

procedure ClearProfile(var P: TPlayerProfile);
begin
  Finalize(P);
  FillChar(P, SizeOf(P), 0);
end;

procedure ClearMap(var M: TMapProfile);
begin
  Finalize(M);
  FillChar(M, SizeOf(M), 0);
end;

procedure ClearServer(var S: TServerRecords);
begin
  Finalize(S);
  FillChar(S, SizeOf(S), 0);
end;

procedure ClearPlayerMap(var R: TPlayerMapStats);
begin
  Finalize(R);
  FillChar(R, SizeOf(R), 0);
end;

function NewPlayerMap: PPlayerMapStats;
begin
  New(Result);
  FillChar(Result^, SizeOf(TPlayerMapStats), 0);
end;

procedure FreePlayerMap(var P: PPlayerMapStats);
begin
  if P <> nil then
  begin
    Dispose(P);
    P := nil;
  end;
end;

procedure FreePlayerMaps(var Arr: TPlayerMapPtrArray);
var
  i: LongInt;
begin
  for i := 0 to High(Arr) do
    FreePlayerMap(Arr[i]);
  Arr := nil;
end;

function NewProfile: PPlayerProfile;
begin
  New(Result);
  FillChar(Result^, SizeOf(TPlayerProfile), 0);
end;

procedure FreeProfile(var P: PPlayerProfile);
begin
  if P <> nil then
  begin
    Dispose(P);
    P := nil;
  end;
end;

procedure FreeProfiles(var Arr: TProfilePtrArray);
var
  i: LongInt;
begin
  for i := 0 to High(Arr) do
    FreeProfile(Arr[i]);
  Arr := nil;
end;

procedure ZeroStatFields(Base: Pointer; const Defs: TFieldDefArray);
var
  i: LongInt;
  Ptr: Pointer;
begin
  for i := 0 to High(Defs) do
  begin
    if not Defs[i].Stat then Continue;
    Ptr := Pointer(PtrUInt(Base) + Defs[i].Offset);
    case Defs[i].Kind of
      fkInt32: PLongInt(Ptr)^ := 0;
      fkInt64: PInt64(Ptr)^ := 0;
      fkSingle: PSingle(Ptr)^ := 0;
      fkDouble: PDouble(Ptr)^ := 0;
      fkBool: PBoolean(Ptr)^ := False;
      fkString: PAnsiString(Ptr)^ := '';
      fkHeat: SetLength(THeatCellArray(Ptr^), 0);
      fkMatchups: SetLength(TMatchupCellArray(Ptr^), 0);
      fkPMWeapons: SetLength(TPMWeaponArray(Ptr^), 0);
      fkPMRivals: SetLength(TPMRivalArray(Ptr^), 0);
      fkPMMatchups: SetLength(TPMMatchupArray(Ptr^), 0);
    end;
  end;
end;

procedure ResetProfileStats(var P: TPlayerProfile);
begin
  ZeroStatFields(@P, ProfileFields);
  P.Dirty := True;
end;

procedure ResetMapStats(var M: TMapProfile);
begin
  ZeroStatFields(@M, MapFields);
  M.Dirty := True;
end;

procedure MergeAliasArrays(var Dst: TOtherDataArray; const Src: TOtherDataArray);
var
  i, j, n: LongInt;
  Found: Boolean;
begin
  for i := 0 to High(Src) do
  begin
    Found := False;
    for j := 0 to High(Dst) do
      if SameText(OtherDataToString(Dst[j]), OtherDataToString(Src[i])) then
      begin
        Inc(Dst[j].LoginCount, Src[i].LoginCount);
        Inc(Dst[j].TimePlayed, Src[i].TimePlayed);
        Inc(Dst[j].TimeOnSpectator, Src[i].TimeOnSpectator);
        if (Src[i].FirstUsedDate > 0) and ((Dst[j].FirstUsedDate = 0) or (Src[i].FirstUsedDate < Dst[j].FirstUsedDate)) then
          Dst[j].FirstUsedDate := Src[i].FirstUsedDate;
        if Src[i].LastUsedDate > Dst[j].LastUsedDate then
          Dst[j].LastUsedDate := Src[i].LastUsedDate;
        Found := True;
        Break;
      end;
    if not Found then
    begin
      n := Length(Dst);
      SetLength(Dst, n + 1);
      Dst[n] := Src[i];
      Dst[n].FirstUsed := False;
    end;
  end;
end;

{ Skip1 and Skip2 (0 = none): the two accounts being merged, which are one player afterwards and
  cannot be that player's own victim or nemesis }
procedure MergeNemesis(var Dst: TNemesisArray; const Src: TNemesisArray; Skip1, Skip2: LongInt);
var
  Tmp: array[0..5] of TNemesisEntry;
  n, i, j: LongInt;
  T: TNemesisEntry;
begin
  n := 0;
  for i := 0 to 2 do
    if (Dst[i].TargetPlayerID > 0) and (Dst[i].TargetPlayerID <> Skip1) and (Dst[i].TargetPlayerID <> Skip2) then
    begin
      Tmp[n] := Dst[i];
      Inc(n);
    end;
  for i := 0 to 2 do
  begin
    if (Src[i].TargetPlayerID <= 0) or (Src[i].TargetPlayerID = Skip1) or (Src[i].TargetPlayerID = Skip2) then
      Continue;
    j := 0;
    while (j < n) and (Tmp[j].TargetPlayerID <> Src[i].TargetPlayerID) do Inc(j);
    if j < n then
      Inc(Tmp[j].KillCount, Src[i].KillCount)
    else
    begin
      Tmp[n] := Src[i];
      Inc(n);
    end;
  end;
  for i := 0 to n - 2 do
    for j := i + 1 to n - 1 do
      if Tmp[j].KillCount > Tmp[i].KillCount then
      begin
        T := Tmp[i]; Tmp[i] := Tmp[j]; Tmp[j] := T;
      end;
  FillChar(Dst, SizeOf(Dst), 0);
  for i := 0 to Min(2, n - 1) do Dst[i] := Tmp[i];
end;

procedure SumFields(Dst, Src: Pointer; const Defs: TFieldDefArray);
var
  i: LongInt;
  PD, PS: Pointer;
begin
  for i := 0 to High(Defs) do
  begin
    if Defs[i].Merge = mkKeep then Continue;
    PD := Pointer(PtrUInt(Dst) + Defs[i].Offset);
    PS := Pointer(PtrUInt(Src) + Defs[i].Offset);
    case Defs[i].Kind of
      fkInt32:
        case Defs[i].Merge of
          mkSum: Inc(PLongInt(PD)^, PLongInt(PS)^);
          mkMax: if PLongInt(PS)^ > PLongInt(PD)^ then PLongInt(PD)^ := PLongInt(PS)^;
          mkMinPos: if (PLongInt(PS)^ > 0) and ((PLongInt(PD)^ <= 0) or (PLongInt(PS)^ < PLongInt(PD)^)) then PLongInt(PD)^ := PLongInt(PS)^;
        end;
      fkInt64:
        case Defs[i].Merge of
          mkSum: Inc(PInt64(PD)^, PInt64(PS)^);
          mkMax: if PInt64(PS)^ > PInt64(PD)^ then PInt64(PD)^ := PInt64(PS)^;
          mkMinPos: if (PInt64(PS)^ > 0) and ((PInt64(PD)^ <= 0) or (PInt64(PS)^ < PInt64(PD)^)) then PInt64(PD)^ := PInt64(PS)^;
        end;
      fkSingle:
        case Defs[i].Merge of
          mkSum: PSingle(PD)^ := PSingle(PD)^ + PSingle(PS)^;
          mkMax: if PSingle(PS)^ > PSingle(PD)^ then PSingle(PD)^ := PSingle(PS)^;
          mkMinPos: if (PSingle(PS)^ > 0) and ((PSingle(PD)^ <= 0) or (PSingle(PS)^ < PSingle(PD)^)) then PSingle(PD)^ := PSingle(PS)^;
        end;
      fkDouble:
        case Defs[i].Merge of
          mkSum: PDouble(PD)^ := PDouble(PD)^ + PDouble(PS)^;
          mkMax: if PDouble(PS)^ > PDouble(PD)^ then PDouble(PD)^ := PDouble(PS)^;
          mkMinPos: if (PDouble(PS)^ > 0) and ((PDouble(PD)^ <= 0) or (PDouble(PS)^ < PDouble(PD)^)) then PDouble(PD)^ := PDouble(PS)^;
        end;
    end;
  end;
end;

procedure SumProfileCounters(var Dst: TPlayerProfile; const Src: TPlayerProfile);
begin
  SumFields(@Dst, @Src, ProfileFields);
end;

procedure UniqueProfileLists(var P: TPlayerProfile);
begin
  P.OtherNames := Copy(P.OtherNames);
  P.TrustedDevices := Copy(P.TrustedDevices);
  P.Badges := Copy(P.Badges);
  P.Achievements := Copy(P.Achievements);
end;

procedure SortHeat(var A: THeatCellArray; L, R: LongInt);
var
  i, j, Pivot: LongInt;
  T: THeatCell;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := A[(L + R) shr 1].Cell;
    repeat
      while A[i].Cell < Pivot do
        Inc(i);
      while A[j].Cell > Pivot do
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
      SortHeat(A, L, j);
      L := i;
    end
    else
    begin
      SortHeat(A, i, R);
      R := j;
    end;
  end;
end;

procedure MergeMapInto(var Dst: TMapProfile; const Src: TMapProfile; Heat: Boolean = True);
var
  i, Lo, Hi, Mid, n, Base: LongInt;
  Found: Boolean;
begin
  SumFields(@Dst, @Src, MapFields);
  if (Src.FirstPlayedTime > 0) and ((Dst.FirstPlayedTime <= 0) or (Src.FirstPlayedTime < Dst.FirstPlayedTime)) then
    Dst.FirstPlayedTime := Src.FirstPlayedTime;
  if Src.LastPlayedTime > Dst.LastPlayedTime then
    Dst.LastPlayedTime := Src.LastPlayedTime;
  if (Src.FastestCapSeconds > 0) and ((Dst.FastestCapSeconds <= 0) or (Src.FastestCapSeconds < Dst.FastestCapSeconds)) then
  begin
    Dst.FastestCapSeconds := Src.FastestCapSeconds;
    Dst.FastestCapHolder := Src.FastestCapHolder;
  end;
  if (Dst.AlphaFlagX = 0) and (Dst.AlphaFlagY = 0) then
  begin
    Dst.AlphaFlagX := Src.AlphaFlagX;
    Dst.AlphaFlagY := Src.AlphaFlagY;
  end;
  if (Dst.BravoFlagX = 0) and (Dst.BravoFlagY = 0) then
  begin
    Dst.BravoFlagX := Src.BravoFlagX;
    Dst.BravoFlagY := Src.BravoFlagY;
  end;
  if (Src.MinX <> 0) or (Src.MaxX <> 0) or (Src.MinY <> 0) or (Src.MaxY <> 0) then
  begin
    if (Dst.MinX = 0) and (Dst.MaxX = 0) and (Dst.MinY = 0) and (Dst.MaxY = 0) then
    begin
      Dst.MinX := Src.MinX;
      Dst.MinY := Src.MinY;
      Dst.MaxX := Src.MaxX;
      Dst.MaxY := Src.MaxY;
    end
    else
    begin
      Dst.MinX := Min(Dst.MinX, Src.MinX);
      Dst.MinY := Min(Dst.MinY, Src.MinY);
      Dst.MaxX := Max(Dst.MaxX, Src.MaxX);
      Dst.MaxY := Max(Dst.MaxY, Src.MaxY);
    end;
  end;
  { the weapon matchups of the map, by the pair of weapons }
  MergeMatchupCells(Dst.Matchups, Src.Matchups);
  { the heat cells are places on the map, the same on every server: the cells of Src are added to
    the same cell of Dst, found by halving the sorted cells of Dst }
  if not Heat or (Length(Src.Heat) = 0) then
    Exit;
  if Length(Dst.Heat) > 1 then
    SortHeat(Dst.Heat, 0, High(Dst.Heat));
  Base := Length(Dst.Heat);
  for i := 0 to High(Src.Heat) do
  begin
    Lo := 0;
    Hi := Base - 1;
    Found := False;
    while Lo <= Hi do
    begin
      Mid := (Lo + Hi) shr 1;
      if Dst.Heat[Mid].Cell = Src.Heat[i].Cell then
      begin
        Inc(Dst.Heat[Mid].Kills, Src.Heat[i].Kills);
        Inc(Dst.Heat[Mid].Deaths, Src.Heat[i].Deaths);
        Found := True;
        Break;
      end
      else if Dst.Heat[Mid].Cell < Src.Heat[i].Cell then
        Lo := Mid + 1
      else
        Hi := Mid - 1;
    end;
    if not Found then
    begin
      n := Length(Dst.Heat);
      SetLength(Dst.Heat, n + 1);
      Dst.Heat[n] := Src.Heat[i];
    end;
  end;
end;

procedure MergeServerInto(var Dst: TServerRecords; const Src: TServerRecords);
var
  i, j, n: LongInt;
  Found: Boolean;
begin
  if Src.PeakOnlineCount > Dst.PeakOnlineCount then
  begin
    Dst.PeakOnlineCount := Src.PeakOnlineCount;
    Dst.PeakOnlineDurationSec := Src.PeakOnlineDurationSec;
    Dst.PeakOnlineDate := Src.PeakOnlineDate;
  end;
  for i := 0 to 23 do
    Inc(Dst.HourlyActivity[i], Src.HourlyActivity[i]);
  for i := 0 to 6 do
    for j := 0 to 23 do
      Inc(Dst.WeekdayHour[i, j], Src.WeekdayHour[i, j]);
  for i := 0 to WSLOT_COUNT - 1 do
    for j := 0 to WSLOT_COUNT - 1 do
      Inc(Dst.Matchups[i, j], Src.Matchups[i, j]);
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    for j := 0 to 4 do
      Inc(Dst.WeaponGlobal[i].DistBucket[j], Src.WeaponGlobal[i].DistBucket[j]);
    Dst.WeaponGlobal[i].KillDistSum := Dst.WeaponGlobal[i].KillDistSum + Src.WeaponGlobal[i].KillDistSum;
    Inc(Dst.WeaponGlobal[i].KillDistCount, Src.WeaponGlobal[i].KillDistCount);
    Inc(Dst.WeaponGlobal[i].TTKSumTicks, Src.WeaponGlobal[i].TTKSumTicks);
    Inc(Dst.WeaponGlobal[i].TTKCount, Src.WeaponGlobal[i].TTKCount);
    Inc(Dst.WeaponGlobal[i].VestKills, Src.WeaponGlobal[i].VestKills);
    Inc(Dst.WeaponGlobal[i].Picks, Src.WeaponGlobal[i].Picks);
    for j := 1 to 4 do
      Inc(Dst.WeaponGlobal[i].PicksTeam[j], Src.WeaponGlobal[i].PicksTeam[j]);
  end;
  for i := 0 to 3 do
    for j := 0 to 2 do
    begin
      Inc(Dst.HitModel[i, j].N, Src.HitModel[i, j].N);
      Dst.HitModel[i, j].SumX := Dst.HitModel[i, j].SumX + Src.HitModel[i, j].SumX;
      Dst.HitModel[i, j].SumY := Dst.HitModel[i, j].SumY + Src.HitModel[i, j].SumY;
      Dst.HitModel[i, j].SumXX := Dst.HitModel[i, j].SumXX + Src.HitModel[i, j].SumXX;
      Dst.HitModel[i, j].SumYY := Dst.HitModel[i, j].SumYY + Src.HitModel[i, j].SumYY;
      Dst.HitModel[i, j].SumXY := Dst.HitModel[i, j].SumXY + Src.HitModel[i, j].SumXY;
    end;
  for i := 0 to High(Src.Daily) do
  begin
    Found := False;
    for j := 0 to High(Dst.Daily) do
      if Dst.Daily[j].Day = Src.Daily[i].Day then
      begin
        Inc(Dst.Daily[j].Uniques, Src.Daily[i].Uniques);
        Inc(Dst.Daily[j].NewPlayers, Src.Daily[i].NewPlayers);
        Inc(Dst.Daily[j].Sessions, Src.Daily[i].Sessions);
        Inc(Dst.Daily[j].PlaySeconds, Src.Daily[i].PlaySeconds);
        Inc(Dst.Daily[j].Kills, Src.Daily[i].Kills);
        if Src.Daily[i].PeakOnline > Dst.Daily[j].PeakOnline then
          Dst.Daily[j].PeakOnline := Src.Daily[i].PeakOnline;
        Found := True;
        Break;
      end;
    if not Found then
    begin
      n := Length(Dst.Daily);
      SetLength(Dst.Daily, n + 1);
      Dst.Daily[n] := Src.Daily[i];
    end;
  end;
  Inc(Dst.TotalMatches, Src.TotalMatches);
  Inc(Dst.ScoreFixes, Src.ScoreFixes);
  Inc(Dst.VoidedCaptures, Src.VoidedCaptures);
  Inc(Dst.BalPredCount, Src.BalPredCount);
  Dst.BalBrierSum := Dst.BalBrierSum + Src.BalBrierSum;
  for i := 0 to 9 do
  begin
    Inc(Dst.BalBinCount[i], Src.BalBinCount[i]);
    Inc(Dst.BalBinWins[i], Src.BalBinWins[i]);
  end;
end;

{ ---------------- three-way merges ---------------- }

{ A record (the larger value wins) or a best time (the smaller positive one) three ways: C this
  server's value, B the database's when this server last saw it, R the database's now; True when R
  replaces C. Unchanged here: the database's value, also when another server lowered it (a reset
  there). Better here: the better of the two. Worse here - a record that went down, a best time
  that went up or was cleared - is a reset and stays: the better of the two would bring the old
  value back. }
function TakeRemoteBest(C, B, R: Int64; Smaller: Boolean): Boolean; overload;
begin
  if C = B then
    Result := True
  else if not Smaller then
    Result := (C > B) and (R > C)
  else
    Result := (C > 0) and ((B <= 0) or (C < B)) and (R > 0) and (R < C);
end;

function TakeRemoteBest(C, B, R: Double; Smaller: Boolean): Boolean; overload;
begin
  if C = B then
    Result := True
  else if not Smaller then
    Result := (C > B) and (R > C)
  else
    Result := (C > 0) and ((B <= 0) or (C < B)) and (R > 0) and (R < C);
end;

procedure Merge3Fields(Cur, Base, Remote: Pointer; const Defs: TFieldDefArray);
var
  i: LongInt;
  PC, PB, PR: Pointer;
  Smaller: Boolean;
begin
  for i := 0 to High(Defs) do
  begin
    PC := Pointer(PtrUInt(Cur) + Defs[i].Offset);
    PB := Pointer(PtrUInt(Base) + Defs[i].Offset);
    PR := Pointer(PtrUInt(Remote) + Defs[i].Offset);
    Smaller := Defs[i].Merge = mkMinPos;
    case Defs[i].Kind of
      fkInt32:
        case Defs[i].Merge of
          mkSum: PLongInt(PC)^ := PLongInt(PR)^ + (PLongInt(PC)^ - PLongInt(PB)^);
          mkMax, mkMinPos:
            if TakeRemoteBest(Int64(PLongInt(PC)^), PLongInt(PB)^, PLongInt(PR)^, Smaller) then
              PLongInt(PC)^ := PLongInt(PR)^;
          mkKeep: if PLongInt(PC)^ = PLongInt(PB)^ then PLongInt(PC)^ := PLongInt(PR)^;
        end;
      fkInt64:
        case Defs[i].Merge of
          mkSum: PInt64(PC)^ := PInt64(PR)^ + (PInt64(PC)^ - PInt64(PB)^);
          mkMax, mkMinPos:
            if TakeRemoteBest(PInt64(PC)^, PInt64(PB)^, PInt64(PR)^, Smaller) then
              PInt64(PC)^ := PInt64(PR)^;
          mkKeep: if PInt64(PC)^ = PInt64(PB)^ then PInt64(PC)^ := PInt64(PR)^;
        end;
      fkSingle:
        case Defs[i].Merge of
          mkSum: PSingle(PC)^ := PSingle(PR)^ + (PSingle(PC)^ - PSingle(PB)^);
          mkMax, mkMinPos:
            if TakeRemoteBest(PSingle(PC)^, PSingle(PB)^, PSingle(PR)^, Smaller) then
              PSingle(PC)^ := PSingle(PR)^;
          mkKeep: if PSingle(PC)^ = PSingle(PB)^ then PSingle(PC)^ := PSingle(PR)^;
        end;
      fkDouble:
        case Defs[i].Merge of
          mkSum: PDouble(PC)^ := PDouble(PR)^ + (PDouble(PC)^ - PDouble(PB)^);
          mkMax, mkMinPos:
            if TakeRemoteBest(PDouble(PC)^, PDouble(PB)^, PDouble(PR)^, Smaller) then
              PDouble(PC)^ := PDouble(PR)^;
          mkKeep: if PDouble(PC)^ = PDouble(PB)^ then PDouble(PC)^ := PDouble(PR)^;
        end;
      fkBool:
        if PBoolean(PC)^ = PBoolean(PB)^ then PBoolean(PC)^ := PBoolean(PR)^;
      fkString:
        if PAnsiString(PC)^ = PAnsiString(PB)^ then PAnsiString(PC)^ := PAnsiString(PR)^;
    end;
  end;
end;

{ the day, week and month, and the season: the numbers of the newest one add up; an older one
  is gone for everybody }
procedure Merge3Periods(var Cur: TPlayerProfile; const Base, Remote: TPlayerProfile; const Saved: TPlayerProfile);
var
  i: LongInt;
  K: LongInt;
  C, B, R: TPeriodStats;
begin
  for i := 0 to 2 do
  begin
    K := Max(Saved.Period[i].Key, Remote.Period[i].Key);
    FillChar(C, SizeOf(C), 0);
    FillChar(B, SizeOf(B), 0);
    FillChar(R, SizeOf(R), 0);
    if Saved.Period[i].Key = K then C := Saved.Period[i];
    if Base.Period[i].Key = K then B := Base.Period[i];
    if Remote.Period[i].Key = K then R := Remote.Period[i];
    Cur.Period[i].Key := K;
    Cur.Period[i].Kills := R.Kills + (C.Kills - B.Kills);
    Cur.Period[i].Deaths := R.Deaths + (C.Deaths - B.Deaths);
    Cur.Period[i].PointsDelta := R.PointsDelta + (C.PointsDelta - B.PointsDelta);
    Cur.Period[i].Caps := R.Caps + (C.Caps - B.Caps);
    Cur.Period[i].Wins := R.Wins + (C.Wins - B.Wins);
    Cur.Period[i].Headshots := R.Headshots + (C.Headshots - B.Headshots);
    Cur.Period[i].TimePlayed := R.TimePlayed + (C.TimePlayed - B.TimePlayed);
  end;
  K := Max(Saved.SeasonId, Remote.SeasonId);
  Cur.SeasonId := K;
  Cur.SeasonPoints := 0;
  Cur.SeasonKills := 0;
  Cur.SeasonDeaths := 0;
  Cur.SeasonCaps := 0;
  Cur.SeasonWins := 0;
  Cur.SeasonTime := 0;
  if Remote.SeasonId = K then
  begin
    Cur.SeasonPoints := Remote.SeasonPoints;
    Cur.SeasonKills := Remote.SeasonKills;
    Cur.SeasonDeaths := Remote.SeasonDeaths;
    Cur.SeasonCaps := Remote.SeasonCaps;
    Cur.SeasonWins := Remote.SeasonWins;
    Cur.SeasonTime := Remote.SeasonTime;
  end;
  if Saved.SeasonId = K then
  begin
    Inc(Cur.SeasonPoints, Saved.SeasonPoints);
    Inc(Cur.SeasonKills, Saved.SeasonKills);
    Inc(Cur.SeasonDeaths, Saved.SeasonDeaths);
    Inc(Cur.SeasonCaps, Saved.SeasonCaps);
    Inc(Cur.SeasonWins, Saved.SeasonWins);
    Inc(Cur.SeasonTime, Saved.SeasonTime);
  end;
  if Base.SeasonId = K then
  begin
    Dec(Cur.SeasonPoints, Base.SeasonPoints);
    Dec(Cur.SeasonKills, Base.SeasonKills);
    Dec(Cur.SeasonDeaths, Base.SeasonDeaths);
    Dec(Cur.SeasonCaps, Base.SeasonCaps);
    Dec(Cur.SeasonWins, Base.SeasonWins);
    Dec(Cur.SeasonTime, Base.SeasonTime);
  end;
end;

function AliasIndex(const Arr: TOtherDataArray; const Key: AnsiString): LongInt;
var
  k: LongInt;
begin
  for k := 0 to High(Arr) do
    if SameText(OtherDataToString(Arr[k]), Key) then
      Exit(k);
  Result := -1;
end;

{ the names of an account: what this server added to a name since Base goes on top of the name in
  Remote; a name only this server knows is added, one the database dropped stays dropped, and one
  this server dropped (NameHistoryLimit) is dropped there too - unless another server used it
  since. NameLimit > 0 cuts the list to that many, the least recently used go first. }
function Merge3Aliases(const Cur, Base, Remote: TOtherDataArray; NameLimit: LongInt): TOtherDataArray;
var
  i, b, r, n: LongInt;
  Key: AnsiString;
begin
  SetLength(Result, Length(Remote));
  n := 0;
  for i := 0 to High(Remote) do
  begin
    Key := OtherDataToString(Remote[i]);
    b := AliasIndex(Base, Key);
    if (b >= 0) and (AliasIndex(Cur, Key) < 0) and (Remote[i].LastUsedDate <= Base[b].LastUsedDate) then
      Continue;
    Result[n] := Remote[i];
    Inc(n);
  end;
  SetLength(Result, n);
  for i := 0 to High(Cur) do
  begin
    Key := OtherDataToString(Cur[i]);
    b := AliasIndex(Base, Key);
    r := AliasIndex(Result, Key);
    if r >= 0 then
    begin
      if b >= 0 then
      begin
        Inc(Result[r].LoginCount, Cur[i].LoginCount - Base[b].LoginCount);
        Inc(Result[r].TimePlayed, Cur[i].TimePlayed - Base[b].TimePlayed);
        Inc(Result[r].TimeOnSpectator, Cur[i].TimeOnSpectator - Base[b].TimeOnSpectator);
        if Cur[i].IsActive <> Base[b].IsActive then Result[r].IsActive := Cur[i].IsActive;
        if Cur[i].LastUsed <> Base[b].LastUsed then Result[r].LastUsed := Cur[i].LastUsed;
      end
      else
      begin
        Inc(Result[r].LoginCount, Cur[i].LoginCount);
        Inc(Result[r].TimePlayed, Cur[i].TimePlayed);
        Inc(Result[r].TimeOnSpectator, Cur[i].TimeOnSpectator);
      end;
      if (Cur[i].FirstUsedDate > 0) and ((Result[r].FirstUsedDate <= 0) or (Cur[i].FirstUsedDate < Result[r].FirstUsedDate)) then
        Result[r].FirstUsedDate := Cur[i].FirstUsedDate;
      if Cur[i].LastUsedDate > Result[r].LastUsedDate then
        Result[r].LastUsedDate := Cur[i].LastUsedDate;
    end
    else if b < 0 then
    begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := Cur[i];
    end;
  end;
  while (NameLimit > 0) and (Length(Result) > NameLimit) do
  begin
    r := 0;
    for i := 1 to High(Result) do
      if Result[i].LastUsedDate < Result[r].LastUsedDate then
        r := i;
    for i := r to High(Result) - 1 do
      Result[i] := Result[i + 1];
    SetLength(Result, Length(Result) - 1);
  end;
end;

function TrustedIndex(const Arr: TTrustedDeviceArray; const D: TTrustedDevice): LongInt;
var
  k: LongInt;
begin
  for k := 0 to High(Arr) do
    if SameText(Arr[k].HWID, D.HWID) and (Arr[k].IPPrefix = D.IPPrefix) then
      Exit(k);
  Result := -1;
end;

{ the trusted computers of an account, a set: one this server removed (/changepass and /resetpass
  keep only the current computer, /account untrust none) stays removed, one the database removed
  stays removed, one added on either side is kept; a computer on both sides keeps the later
  dates. At most MAX_TRUSTED_DEVICES, the least recently added go first. }
function Merge3Trusted(const Cur, Base, Remote: TTrustedDeviceArray): TTrustedDeviceArray;
var
  i, c, n: LongInt;
begin
  SetLength(Result, Length(Remote) + Length(Cur));
  n := 0;
  for i := 0 to High(Remote) do
  begin
    c := TrustedIndex(Cur, Remote[i]);
    if (c < 0) and (TrustedIndex(Base, Remote[i]) >= 0) then
      Continue;
    Result[n] := Remote[i];
    if c >= 0 then
    begin
      if Cur[c].LastUsed > Result[n].LastUsed then
        Result[n].LastUsed := Cur[c].LastUsed;
      if Cur[c].Expire > Result[n].Expire then
        Result[n].Expire := Cur[c].Expire;
    end;
    Inc(n);
  end;
  for i := 0 to High(Cur) do
    if (TrustedIndex(Remote, Cur[i]) < 0) and (TrustedIndex(Base, Cur[i]) < 0) then
    begin
      Result[n] := Cur[i];
      Inc(n);
    end;
  SetLength(Result, n);
  while Length(Result) > MAX_TRUSTED_DEVICES do
  begin
    c := 0;
    for i := 1 to High(Result) do
      if Result[i].LastUsed < Result[c].LastUsed then
        c := i;
    for i := c to High(Result) - 1 do
      Result[i] := Result[i + 1];
    SetLength(Result, Length(Result) - 1);
  end;
end;

procedure Merge3Profile(var Cur: TPlayerProfile; const Base, Remote: TPlayerProfile; NameLimit: LongInt);
var
  Saved: TPlayerProfile;
  i, j, n: LongInt;
  Found: Boolean;
  Victims, Nemeses: TNemesisArray;
  SameVictims, SameNemeses: Boolean;
begin
  Saved := Cur;
  Merge3Fields(@Cur, @Base, @Remote, ProfileFields);
  { the password is one thing in four fields (hash, salt, rounds, date): all four come from the
    side that changed it - field by field, two changes at once could mix the hash of one server
    with the rounds of the other, and no password would work }
  if (Saved.PassHash <> Base.PassHash) or (Saved.PassSalt <> Base.PassSalt) or (Saved.PassIter <> Base.PassIter) or
     (Saved.PassSetTime <> Base.PassSetTime) then
  begin
    Cur.PassHash := Saved.PassHash;
    Cur.PassSalt := Saved.PassSalt;
    Cur.PassIter := Saved.PassIter;
    Cur.PassSetTime := Saved.PassSetTime;
  end
  else
  begin
    Cur.PassHash := Remote.PassHash;
    Cur.PassSalt := Remote.PassSalt;
    Cur.PassIter := Remote.PassIter;
    Cur.PassSetTime := Remote.PassSetTime;
  end;
  { the points are won and lost in steps on every server: they add up like a counter }
  Cur.Points := Max(0, Remote.Points + (Saved.Points - Base.Points));
  { the protection days are earned a day at a time and spent by the daily balance: fewer here (a
    day spent, a reset) come off the database's days, more here keep the larger of the two (as
    when two accounts are merged, and at the first start with the database) }
  if Saved.ProtectionDays < Base.ProtectionDays then
    Cur.ProtectionDays := Max(0, Remote.ProtectionDays + (Saved.ProtectionDays - Base.ProtectionDays));
  Merge3Periods(Cur, Base, Remote, Saved);
  { the rivals are three pairs: this server's when they changed here, otherwise the database's }
  SameVictims := True;
  SameNemeses := True;
  for i := 0 to 2 do
  begin
    if (Saved.TopVictims[i].TargetPlayerID <> Base.TopVictims[i].TargetPlayerID) or
       (Saved.TopVictims[i].KillCount <> Base.TopVictims[i].KillCount) then
      SameVictims := False;
    if (Saved.TopNemeses[i].TargetPlayerID <> Base.TopNemeses[i].TargetPlayerID) or
       (Saved.TopNemeses[i].KillCount <> Base.TopNemeses[i].KillCount) then
      SameNemeses := False;
  end;
  if SameVictims then Victims := Remote.TopVictims else Victims := Saved.TopVictims;
  if SameNemeses then Nemeses := Remote.TopNemeses else Nemeses := Saved.TopNemeses;
  Cur.TopVictims := Victims;
  Cur.TopNemeses := Nemeses;
  Cur.OtherNames := Merge3Aliases(Saved.OtherNames, Base.OtherNames, Remote.OtherNames, NameLimit);
  { the trusted computers merge as a set with removals (Merge3Trusted); season badges and
    achievements are sets: everything either side has }
  Cur.TrustedDevices := Merge3Trusted(Saved.TrustedDevices, Base.TrustedDevices, Remote.TrustedDevices);
  Cur.Badges := Copy(Remote.Badges);
  for i := 0 to High(Saved.Badges) do
  begin
    Found := False;
    for j := 0 to High(Cur.Badges) do
      if Cur.Badges[j].SeasonId = Saved.Badges[i].SeasonId then
      begin
        if (Saved.Badges[i].Place > 0) and ((Cur.Badges[j].Place <= 0) or (Saved.Badges[i].Place < Cur.Badges[j].Place)) then
          Cur.Badges[j].Place := Saved.Badges[i].Place;
        Found := True;
      end;
    if not Found then
    begin
      n := Length(Cur.Badges);
      SetLength(Cur.Badges, n + 1);
      Cur.Badges[n] := Saved.Badges[i];
    end;
  end;
  Cur.Achievements := Copy(Remote.Achievements);
  for i := 0 to High(Saved.Achievements) do
  begin
    Found := False;
    for j := 0 to High(Cur.Achievements) do
      if Cur.Achievements[j].Id = Saved.Achievements[i].Id then
      begin
        if Saved.Achievements[i].Date < Cur.Achievements[j].Date then
          Cur.Achievements[j].Date := Saved.Achievements[i].Date;
        Found := True;
      end;
    if not Found then
    begin
      n := Length(Cur.Achievements);
      SetLength(Cur.Achievements, n + 1);
      Cur.Achievements[n] := Saved.Achievements[i];
    end;
  end;
  { the runtime fields stay this server's }
  Cur.Dirty := Saved.Dirty;
  Cur.SyncBase := Saved.SyncBase;
  Cur.SyncVersion := Saved.SyncVersion;
  Cur.SyncDirty := Saved.SyncDirty;
end;

function HeatValue(const Arr: THeatCellArray; Cell: LongInt; out Kills, Deaths: LongInt): Boolean;
var
  k: LongInt;
begin
  for k := 0 to High(Arr) do
    if Arr[k].Cell = Cell then
    begin
      Kills := Arr[k].Kills;
      Deaths := Arr[k].Deaths;
      Exit(True);
    end;
  Kills := 0;
  Deaths := 0;
  Result := False;
end;

procedure Merge3Map(var Cur: TMapProfile; const Base, Remote: TMapProfile);
var
  Saved: TMapProfile;
  i, n, BK, BD, RK, RD: LongInt;
  Cells: THeatCellArray;
begin
  Saved := Cur;
  Merge3Fields(@Cur, @Base, @Remote, MapFields);
  Cur.ID := Saved.ID;
  if (Remote.FirstPlayedTime > 0) and ((Saved.FirstPlayedTime <= 0) or (Remote.FirstPlayedTime < Saved.FirstPlayedTime)) then
    Cur.FirstPlayedTime := Remote.FirstPlayedTime
  else
    Cur.FirstPlayedTime := Saved.FirstPlayedTime;
  Cur.LastPlayedTime := Max(Saved.LastPlayedTime, Remote.LastPlayedTime);
  { the fastest capture with its holder, as a best time: a reset here stays }
  Cur.FastestCapSeconds := Saved.FastestCapSeconds;
  Cur.FastestCapHolder := Saved.FastestCapHolder;
  if TakeRemoteBest(Saved.FastestCapSeconds, Base.FastestCapSeconds, Remote.FastestCapSeconds, True) then
  begin
    Cur.FastestCapSeconds := Remote.FastestCapSeconds;
    Cur.FastestCapHolder := Remote.FastestCapHolder;
  end;
  { the heat cells add up cell by cell }
  Cells := Copy(Remote.Heat);
  for i := 0 to High(Saved.Heat) do
  begin
    HeatValue(Base.Heat, Saved.Heat[i].Cell, BK, BD);
    n := -1;
    for RK := 0 to High(Cells) do
      if Cells[RK].Cell = Saved.Heat[i].Cell then
      begin
        n := RK;
        Break;
      end;
    if n < 0 then
    begin
      n := Length(Cells);
      SetLength(Cells, n + 1);
      Cells[n].Cell := Saved.Heat[i].Cell;
      Cells[n].Kills := 0;
      Cells[n].Deaths := 0;
    end;
    Inc(Cells[n].Kills, Saved.Heat[i].Kills - BK);
    Inc(Cells[n].Deaths, Saved.Heat[i].Deaths - BD);
  end;
  { a cell this server does not have any more (a reset) takes its part out of the database's }
  for i := 0 to High(Base.Heat) do
    if not HeatValue(Saved.Heat, Base.Heat[i].Cell, RK, RD) then
      for n := 0 to High(Cells) do
        if Cells[n].Cell = Base.Heat[i].Cell then
        begin
          Dec(Cells[n].Kills, Base.Heat[i].Kills);
          Dec(Cells[n].Deaths, Base.Heat[i].Deaths);
        end;
  n := 0;
  for i := 0 to High(Cells) do
    if (Cells[i].Kills > 0) or (Cells[i].Deaths > 0) then
    begin
      Cells[n] := Cells[i];
      if Cells[n].Kills < 0 then Cells[n].Kills := 0;
      if Cells[n].Deaths < 0 then Cells[n].Deaths := 0;
      Inc(n);
    end;
  SetLength(Cells, n);
  Cur.Heat := Cells;
  { the weapon matchups add up pair by pair; the date of the last load is the later one }
  Cur.Matchups := Merge3MatchupCells(Saved.Matchups, Base.Matchups, Remote.Matchups);
  Cur.LastLoadedTime := Max(Saved.LastLoadedTime, Remote.LastLoadedTime);
  Cur.Dirty := Saved.Dirty;
  Cur.SyncBase := Saved.SyncBase;
  Cur.SyncVersion := Saved.SyncVersion;
  Cur.SyncDirty := Saved.SyncDirty;
end;

procedure Merge3Server(var Cur: TServerRecords; const Base, Remote: TServerRecords);
var
  Saved: TServerRecords;
  i, j, k, n: LongInt;
  Found: Boolean;

  function S64(C, B, R: Int64): Int64;
  begin
    Result := R + (C - B);
  end;

  function SD(C, B, R: Double): Double;
  begin
    Result := R + (C - B);
  end;

begin
  Saved := Cur;
  Cur := Remote;
  Cur.Daily := Copy(Remote.Daily);
  { the online peak, a record: the database's while it is unchanged here (also when another server
    reset it), the higher one after a new peak here; a lower one here is a reset of the server
    statistics and stays }
  if (Saved.PeakOnlineCount <> Base.PeakOnlineCount) or (Saved.PeakOnlineDurationSec <> Base.PeakOnlineDurationSec) then
  begin
    if (Saved.PeakOnlineCount < Base.PeakOnlineCount) or ((Saved.PeakOnlineCount = Base.PeakOnlineCount) and
       (Saved.PeakOnlineDurationSec < Base.PeakOnlineDurationSec)) or (Saved.PeakOnlineCount > Cur.PeakOnlineCount) then
    begin
      Cur.PeakOnlineCount := Saved.PeakOnlineCount;
      Cur.PeakOnlineDurationSec := Saved.PeakOnlineDurationSec;
      Cur.PeakOnlineDate := Saved.PeakOnlineDate;
    end
    else if (Saved.PeakOnlineCount = Cur.PeakOnlineCount) and (Saved.PeakOnlineDurationSec > Cur.PeakOnlineDurationSec) then
      Cur.PeakOnlineDurationSec := Saved.PeakOnlineDurationSec;
  end;
  for i := 0 to 23 do
    Cur.HourlyActivity[i] := S64(Saved.HourlyActivity[i], Base.HourlyActivity[i], Remote.HourlyActivity[i]);
  for i := 0 to 6 do
    for j := 0 to 23 do
      Cur.WeekdayHour[i, j] := S64(Saved.WeekdayHour[i, j], Base.WeekdayHour[i, j], Remote.WeekdayHour[i, j]);
  for i := 0 to WSLOT_COUNT - 1 do
    for j := 0 to WSLOT_COUNT - 1 do
      Cur.Matchups[i, j] := Remote.Matchups[i, j] + (Saved.Matchups[i, j] - Base.Matchups[i, j]);
  for i := 0 to WSLOT_COUNT - 1 do
  begin
    for j := 0 to 4 do
      Cur.WeaponGlobal[i].DistBucket[j] := S64(Saved.WeaponGlobal[i].DistBucket[j], Base.WeaponGlobal[i].DistBucket[j],
        Remote.WeaponGlobal[i].DistBucket[j]);
    Cur.WeaponGlobal[i].KillDistSum := SD(Saved.WeaponGlobal[i].KillDistSum, Base.WeaponGlobal[i].KillDistSum,
      Remote.WeaponGlobal[i].KillDistSum);
    Cur.WeaponGlobal[i].KillDistCount := S64(Saved.WeaponGlobal[i].KillDistCount, Base.WeaponGlobal[i].KillDistCount,
      Remote.WeaponGlobal[i].KillDistCount);
    Cur.WeaponGlobal[i].TTKSumTicks := S64(Saved.WeaponGlobal[i].TTKSumTicks, Base.WeaponGlobal[i].TTKSumTicks,
      Remote.WeaponGlobal[i].TTKSumTicks);
    Cur.WeaponGlobal[i].TTKCount := S64(Saved.WeaponGlobal[i].TTKCount, Base.WeaponGlobal[i].TTKCount,
      Remote.WeaponGlobal[i].TTKCount);
    Cur.WeaponGlobal[i].VestKills := S64(Saved.WeaponGlobal[i].VestKills, Base.WeaponGlobal[i].VestKills,
      Remote.WeaponGlobal[i].VestKills);
    Cur.WeaponGlobal[i].Picks := S64(Saved.WeaponGlobal[i].Picks, Base.WeaponGlobal[i].Picks, Remote.WeaponGlobal[i].Picks);
    for j := 1 to 4 do
      Cur.WeaponGlobal[i].PicksTeam[j] := S64(Saved.WeaponGlobal[i].PicksTeam[j], Base.WeaponGlobal[i].PicksTeam[j],
        Remote.WeaponGlobal[i].PicksTeam[j]);
  end;
  for i := 0 to 3 do
    for j := 0 to 2 do
    begin
      Cur.HitModel[i, j].N := S64(Saved.HitModel[i, j].N, Base.HitModel[i, j].N, Remote.HitModel[i, j].N);
      Cur.HitModel[i, j].SumX := SD(Saved.HitModel[i, j].SumX, Base.HitModel[i, j].SumX, Remote.HitModel[i, j].SumX);
      Cur.HitModel[i, j].SumY := SD(Saved.HitModel[i, j].SumY, Base.HitModel[i, j].SumY, Remote.HitModel[i, j].SumY);
      Cur.HitModel[i, j].SumXX := SD(Saved.HitModel[i, j].SumXX, Base.HitModel[i, j].SumXX, Remote.HitModel[i, j].SumXX);
      Cur.HitModel[i, j].SumYY := SD(Saved.HitModel[i, j].SumYY, Base.HitModel[i, j].SumYY, Remote.HitModel[i, j].SumYY);
      Cur.HitModel[i, j].SumXY := SD(Saved.HitModel[i, j].SumXY, Base.HitModel[i, j].SumXY, Remote.HitModel[i, j].SumXY);
    end;
  { the days: counters of the same day add up }
  for i := 0 to High(Saved.Daily) do
  begin
    k := -1;
    for j := 0 to High(Base.Daily) do
      if Base.Daily[j].Day = Saved.Daily[i].Day then
        k := j;
    Found := False;
    for j := 0 to High(Cur.Daily) do
      if Cur.Daily[j].Day = Saved.Daily[i].Day then
      begin
        Found := True;
        if k >= 0 then
        begin
          Inc(Cur.Daily[j].Uniques, Saved.Daily[i].Uniques - Base.Daily[k].Uniques);
          Inc(Cur.Daily[j].NewPlayers, Saved.Daily[i].NewPlayers - Base.Daily[k].NewPlayers);
          Inc(Cur.Daily[j].Sessions, Saved.Daily[i].Sessions - Base.Daily[k].Sessions);
          Inc(Cur.Daily[j].PlaySeconds, Saved.Daily[i].PlaySeconds - Base.Daily[k].PlaySeconds);
          Inc(Cur.Daily[j].Kills, Saved.Daily[i].Kills - Base.Daily[k].Kills);
        end
        else
        begin
          Inc(Cur.Daily[j].Uniques, Saved.Daily[i].Uniques);
          Inc(Cur.Daily[j].NewPlayers, Saved.Daily[i].NewPlayers);
          Inc(Cur.Daily[j].Sessions, Saved.Daily[i].Sessions);
          Inc(Cur.Daily[j].PlaySeconds, Saved.Daily[i].PlaySeconds);
          Inc(Cur.Daily[j].Kills, Saved.Daily[i].Kills);
        end;
        { the peak of the day is a record: a lower one here (a reset) stays }
        if k >= 0 then
        begin
          if not TakeRemoteBest(Int64(Saved.Daily[i].PeakOnline), Base.Daily[k].PeakOnline, Cur.Daily[j].PeakOnline, False) then
            Cur.Daily[j].PeakOnline := Saved.Daily[i].PeakOnline;
        end
        else if Saved.Daily[i].PeakOnline > Cur.Daily[j].PeakOnline then
          Cur.Daily[j].PeakOnline := Saved.Daily[i].PeakOnline;
        Break;
      end;
    if not Found and (k < 0) then
    begin
      n := Length(Cur.Daily);
      SetLength(Cur.Daily, n + 1);
      Cur.Daily[n] := Saved.Daily[i];
    end;
  end;
  { a day this server does not have any more (a reset of the server statistics, or the oldest day
    dropped after a year) takes its part out of the database's day, and a day nothing is left of
    goes, as the heat cells of a map do; the other servers' part since then stays }
  for k := 0 to High(Base.Daily) do
  begin
    Found := False;
    for i := 0 to High(Saved.Daily) do
      if Saved.Daily[i].Day = Base.Daily[k].Day then
        Found := True;
    if Found then
      Continue;
    for j := High(Cur.Daily) downto 0 do
      if Cur.Daily[j].Day = Base.Daily[k].Day then
      begin
        Cur.Daily[j].Uniques := Max(0, Cur.Daily[j].Uniques - Base.Daily[k].Uniques);
        Cur.Daily[j].NewPlayers := Max(0, Cur.Daily[j].NewPlayers - Base.Daily[k].NewPlayers);
        Cur.Daily[j].Sessions := Max(0, Cur.Daily[j].Sessions - Base.Daily[k].Sessions);
        Cur.Daily[j].PlaySeconds := Max(Int64(0), Cur.Daily[j].PlaySeconds - Base.Daily[k].PlaySeconds);
        Cur.Daily[j].Kills := Max(0, Cur.Daily[j].Kills - Base.Daily[k].Kills);
        if Cur.Daily[j].PeakOnline <= Base.Daily[k].PeakOnline then
          Cur.Daily[j].PeakOnline := 0;
        if (Cur.Daily[j].Uniques = 0) and (Cur.Daily[j].NewPlayers = 0) and (Cur.Daily[j].Sessions = 0) and
           (Cur.Daily[j].PlaySeconds = 0) and (Cur.Daily[j].Kills = 0) and (Cur.Daily[j].PeakOnline = 0) then
        begin
          for n := j to High(Cur.Daily) - 1 do
            Cur.Daily[n] := Cur.Daily[n + 1];
          SetLength(Cur.Daily, Length(Cur.Daily) - 1);
        end;
      end;
  end;
  Cur.TotalMatches := S64(Saved.TotalMatches, Base.TotalMatches, Remote.TotalMatches);
  Cur.ScoreFixes := S64(Saved.ScoreFixes, Base.ScoreFixes, Remote.ScoreFixes);
  Cur.VoidedCaptures := S64(Saved.VoidedCaptures, Base.VoidedCaptures, Remote.VoidedCaptures);
  Cur.BalPredCount := S64(Saved.BalPredCount, Base.BalPredCount, Remote.BalPredCount);
  Cur.BalBrierSum := SD(Saved.BalBrierSum, Base.BalBrierSum, Remote.BalBrierSum);
  for i := 0 to 9 do
  begin
    Cur.BalBinCount[i] := S64(Saved.BalBinCount[i], Base.BalBinCount[i], Remote.BalBinCount[i]);
    Cur.BalBinWins[i] := S64(Saved.BalBinWins[i], Base.BalBinWins[i], Remote.BalBinWins[i]);
  end;
  { the settings of the whole database: this server's when it changed them }
  if Saved.NextProfileID <> Base.NextProfileID then Cur.NextProfileID := Max(Saved.NextProfileID, Remote.NextProfileID);
  if Saved.NextMapID <> Base.NextMapID then Cur.NextMapID := Max(Saved.NextMapID, Remote.NextMapID);
  if Saved.NextSeasonId <> Base.NextSeasonId then Cur.NextSeasonId := Max(Saved.NextSeasonId, Remote.NextSeasonId);
  { the running season is one: its number and its dates come from the same server - this one's
    when it began a season with a higher number than the database's (of two seasons, begun at the
    same time or brought along at the first start with the database, the higher number goes on) }
  if ((Saved.SeasonId <> Base.SeasonId) or (Saved.SeasonStart <> Base.SeasonStart) or
     (Saved.SeasonEnd <> Base.SeasonEnd)) and (Saved.SeasonId > Remote.SeasonId) then
  begin
    Cur.SeasonId := Saved.SeasonId;
    Cur.SeasonStart := Saved.SeasonStart;
    Cur.SeasonEnd := Saved.SeasonEnd;
  end;
  if Saved.LastBalanceDay <> Base.LastBalanceDay then Cur.LastBalanceDay := Max(Saved.LastBalanceDay, Remote.LastBalanceDay);
  if Saved.LastCheckpointsDay <> Base.LastCheckpointsDay then
    Cur.LastCheckpointsDay := Max(Saved.LastCheckpointsDay, Remote.LastCheckpointsDay);
  if Saved.CheckWaitSince <> Base.CheckWaitSince then Cur.CheckWaitSince := Saved.CheckWaitSince;
  if Saved.LastAutoBackup <> Base.LastAutoBackup then Cur.LastAutoBackup := Max(Saved.LastAutoBackup, Remote.LastAutoBackup);
  if Saved.MatchupsFixed <> Base.MatchupsFixed then Cur.MatchupsFixed := Saved.MatchupsFixed;
  if Saved.MatchLengthsSplit <> Base.MatchLengthsSplit then Cur.MatchLengthsSplit := Saved.MatchLengthsSplit;
  if Saved.ScoresSplit <> Base.ScoresSplit then Cur.ScoresSplit := Saved.ScoresSplit;
  Cur.Dirty := Saved.Dirty;
  Cur.SyncBase := Saved.SyncBase;
  Cur.SyncVersion := Saved.SyncVersion;
  Cur.SyncDirty := Saved.SyncDirty;
end;

procedure MergeProfileInto(var Dst: TPlayerProfile; const Src: TPlayerProfile; StartingPoints: LongInt);
var
  i, j, n, Skip1, Skip2: LongInt;
  Found: Boolean;
begin
  SumProfileCounters(Dst, Src);
  { points: keep what both accounts earned above the starting value }
  Dst.Points := Max(0, Dst.Points + (Src.Points - StartingPoints));
  if (Src.RegisterTime > 0) and ((Dst.RegisterTime = 0) or (Src.RegisterTime < Dst.RegisterTime)) then
    Dst.RegisterTime := Src.RegisterTime;
  { two accounts of this database become one player: kills between them are no rivalry; the sums
    of other servers (no id or the same id) keep their lists as they are }
  Skip1 := 0;
  Skip2 := 0;
  if (Dst.ID > 0) and (Src.ID > 0) and (Dst.ID <> Src.ID) then
  begin
    Skip1 := Dst.ID;
    Skip2 := Src.ID;
  end;
  MergeNemesis(Dst.TopVictims, Src.TopVictims, Skip1, Skip2);
  MergeNemesis(Dst.TopNemeses, Src.TopNemeses, Skip1, Skip2);
  MergeAliasArrays(Dst.OtherNames, Src.OtherNames);
  if (Dst.Email = '') and (Src.Email <> '') and Src.EmailVerified then
  begin
    Dst.Email := Src.Email;
    Dst.EmailVerified := True;
  end;
  if Src.SeasonId = Dst.SeasonId then
  begin
    Inc(Dst.SeasonPoints, Src.SeasonPoints);
    Inc(Dst.SeasonKills, Src.SeasonKills);
    Inc(Dst.SeasonDeaths, Src.SeasonDeaths);
    Inc(Dst.SeasonCaps, Src.SeasonCaps);
    Inc(Dst.SeasonWins, Src.SeasonWins);
    Inc(Dst.SeasonTime, Src.SeasonTime);
  end;
  for i := 0 to 2 do
    if (Src.Period[i].Key <> 0) and (Src.Period[i].Key = Dst.Period[i].Key) then
    begin
      Inc(Dst.Period[i].Kills, Src.Period[i].Kills);
      Inc(Dst.Period[i].Deaths, Src.Period[i].Deaths);
      Inc(Dst.Period[i].PointsDelta, Src.Period[i].PointsDelta);
      Inc(Dst.Period[i].Caps, Src.Period[i].Caps);
      Inc(Dst.Period[i].Wins, Src.Period[i].Wins);
      Inc(Dst.Period[i].Headshots, Src.Period[i].Headshots);
      Inc(Dst.Period[i].TimePlayed, Src.Period[i].TimePlayed);
    end;
  for i := 0 to High(Src.Badges) do
  begin
    Found := False;
    for j := 0 to High(Dst.Badges) do
      if Dst.Badges[j].SeasonId = Src.Badges[i].SeasonId then
      begin
        { the better place of the season; a badge without a place takes the other one's }
        if (Src.Badges[i].Place > 0) and ((Dst.Badges[j].Place <= 0) or (Src.Badges[i].Place < Dst.Badges[j].Place)) then
          Dst.Badges[j].Place := Src.Badges[i].Place;
        Found := True;
      end;
    if not Found then
    begin
      n := Length(Dst.Badges);
      SetLength(Dst.Badges, n + 1);
      Dst.Badges[n] := Src.Badges[i];
    end;
  end;
  for i := 0 to High(Src.Achievements) do
  begin
    Found := False;
    for j := 0 to High(Dst.Achievements) do
      if Dst.Achievements[j].Id = Src.Achievements[i].Id then
      begin
        if Src.Achievements[i].Date < Dst.Achievements[j].Date then
          Dst.Achievements[j].Date := Src.Achievements[i].Date;
        Found := True;
      end;
    if not Found then
    begin
      n := Length(Dst.Achievements);
      SetLength(Dst.Achievements, n + 1);
      Dst.Achievements[n] := Src.Achievements[i];
    end;
  end;
  Dst.Dirty := True;
end;

{ The counts by length came after five fixed levels, so an older account holds its streaks of 5,
  10, 15, 20 and 25 kills only in SpreeKills ... GodlikeKills, which still count up with them. The
  larger of the two is taken where they meet, never fewer than for a longer streak (a streak that
  reached 7 kills reached 5 as well), and at least one up to the best streak. This is read, never
  written back: with Engine = mysql every server would add what it filled in to the shared record. }
function SpreeLivesAt(const P: TPlayerProfile; Kills: LongInt): LongInt;
var
  k: LongInt;
begin
  Kills := EnsureRange(Kills, 1, SPREE_MAX_KILLS);
  Result := 0;
  for k := SPREE_MAX_KILLS downto Kills do
  begin
    Result := Max(Result, P.SpreeLives[k]);
    case k of
      5: Result := Max(Result, P.SpreeKills);
      10: Result := Max(Result, P.RampageKills);
      15: Result := Max(Result, P.DominatingSpreeKills);
      20: Result := Max(Result, P.UnstoppableKills);
      25: Result := Max(Result, P.GodlikeKills);
    end;
  end;
  if (Result = 0) and (P.MaxKillStreak >= Kills) then
    Result := 1;
end;

{ ---------------- player-on-map records ([Matrix]) ---------------- }

const
  PM_POINTS_ID = 22;   { the points won and lost on a map may be below 0 }

function PMWeaponPos(const A: TPMWeaponArray; Slot: LongInt; out Pos: LongInt): Boolean;
var
  Lo, Hi, Mid: LongInt;
begin
  Lo := 0;
  Hi := High(A);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    if A[Mid].Slot = Slot then
    begin
      Pos := Mid;
      Exit(True);
    end;
    if A[Mid].Slot < Slot then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Pos := Lo;
  Result := False;
end;

function PMRivalPos(const A: TPMRivalArray; Id: LongInt; out Pos: LongInt): Boolean;
var
  Lo, Hi, Mid: LongInt;
begin
  Lo := 0;
  Hi := High(A);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    if A[Mid].Id = Id then
    begin
      Pos := Mid;
      Exit(True);
    end;
    if A[Mid].Id < Id then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Pos := Lo;
  Result := False;
end;

function PMMatchupPos(const A: TPMMatchupArray; Mine, Theirs: LongInt; out Pos: LongInt): Boolean;
var
  Lo, Hi, Mid, Key, K: LongInt;
begin
  Key := Mine * 64 + Theirs;
  Lo := 0;
  Hi := High(A);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    K := A[Mid].Mine * 64 + A[Mid].Theirs;
    if K = Key then
    begin
      Pos := Mid;
      Exit(True);
    end;
    if K < Key then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Pos := Lo;
  Result := False;
end;

function MatchupCellPos(const A: TMatchupCellArray; Killer, Victim: LongInt; out Pos: LongInt): Boolean;
var
  Lo, Hi, Mid, Key, K: LongInt;
begin
  Key := Killer * 64 + Victim;
  Lo := 0;
  Hi := High(A);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    K := A[Mid].Killer * 64 + A[Mid].Victim;
    if K = Key then
    begin
      Pos := Mid;
      Exit(True);
    end;
    if K < Key then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Pos := Lo;
  Result := False;
end;

function HeatCellPos(const A: THeatCellArray; Cell: LongInt; out Pos: LongInt): Boolean;
var
  Lo, Hi, Mid: LongInt;
begin
  Lo := 0;
  Hi := High(A);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    if A[Mid].Cell = Cell then
    begin
      Pos := Mid;
      Exit(True);
    end;
    if A[Mid].Cell < Cell then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Pos := Lo;
  Result := False;
end;

{ the counters (the fields added up on a merge) of a record or an entry that went below 0 are 0;
  SkipId is a counter that may be below 0 (0 = none) }
procedure ClampSums(Base: Pointer; const Defs: TFieldDefArray; SkipId: Word);
var
  i: LongInt;
  Ptr: Pointer;
begin
  for i := 0 to High(Defs) do
  begin
    if (Defs[i].Merge <> mkSum) or (Defs[i].Id = SkipId) then
      Continue;
    Ptr := Pointer(PtrUInt(Base) + Defs[i].Offset);
    case Defs[i].Kind of
      fkInt32: if PLongInt(Ptr)^ < 0 then PLongInt(Ptr)^ := 0;
      fkInt64: if PInt64(Ptr)^ < 0 then PInt64(Ptr)^ := 0;
      fkSingle: if PSingle(Ptr)^ < 0 then PSingle(Ptr)^ := 0;
      fkDouble: if PDouble(Ptr)^ < 0 then PDouble(Ptr)^ := 0;
    end;
  end;
end;

{ every counter of an entry is 0: nothing is left of it }
function SumsZero(Base: Pointer; const Defs: TFieldDefArray): Boolean;
var
  i: LongInt;
  Ptr: Pointer;
begin
  Result := False;
  for i := 0 to High(Defs) do
  begin
    if Defs[i].Merge <> mkSum then
      Continue;
    Ptr := Pointer(PtrUInt(Base) + Defs[i].Offset);
    case Defs[i].Kind of
      fkInt32: if PLongInt(Ptr)^ <> 0 then Exit;
      fkInt64: if PInt64(Ptr)^ <> 0 then Exit;
      fkSingle: if PSingle(Ptr)^ <> 0 then Exit;
      fkDouble: if PDouble(Ptr)^ <> 0 then Exit;
    end;
  end;
  Result := True;
end;

function PlayerMapEmpty(const R: TPlayerMapStats): Boolean;
var
  i: LongInt;
  Ptr: Pointer;
begin
  Result := False;
  if (Length(R.Weapons) > 0) or (Length(R.Rivals) > 0) or (Length(R.Matchups) > 0) or (Length(R.Heat) > 0) then
    Exit;
  for i := 0 to High(PlayerMapFields) do
  begin
    if not PlayerMapFields[i].Stat then
      Continue;
    Ptr := Pointer(PtrUInt(@R) + PlayerMapFields[i].Offset);
    case PlayerMapFields[i].Kind of
      fkInt32: if PLongInt(Ptr)^ <> 0 then Exit;
      fkInt64: if PInt64(Ptr)^ <> 0 then Exit;
      fkSingle: if PSingle(Ptr)^ <> 0 then Exit;
      fkDouble: if PDouble(Ptr)^ <> 0 then Exit;
    end;
  end;
  Result := True;
end;

{ the kills and deaths between the two, the rival's weight in a full list }
function RivalFights(const E: TPMRival): Int64; inline;
begin
  Result := Int64(E.Kills) + E.Deaths;
end;

function PMWeakestRival(const A: TPMRivalArray): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  for k := 0 to High(A) do
    if (Result < 0) or (RivalFights(A[k]) < RivalFights(A[Result])) or
       ((RivalFights(A[k]) = RivalFights(A[Result])) and (A[k].LastFight < A[Result].LastFight)) then
      Result := k;
end;

procedure PMTrimRivals(var A: TPMRivalArray; MaxRivals: LongInt);
var
  Keys: array of Int64;
  Order, Drop: TIntArray;
  i, n, Excess: LongInt;
begin
  Excess := Length(A) - MaxRivals;
  if (MaxRivals <= 0) or (Excess <= 0) then
    Exit;
  if Excess = 1 then
  begin
    Delete(A, PMWeakestRival(A), 1);
    Exit;
  end;
  { many at once (lists added up): the weakest first, by fights, then by the minute of the last one }
  SetLength(Keys, Length(A));
  for i := 0 to High(A) do
    Keys[i] := (RivalFights(A[i]) shl 32) + EnsureRange(Trunc(A[i].LastFight * 1440), 0, High(LongInt));
  SetLength(Order, Length(A));
  for i := 0 to High(Order) do
    Order[i] := i;
  SortPlaces(Keys, Order, 0, High(Order));
  SetLength(Drop, Length(A));
  for i := 0 to Excess - 1 do
    Drop[Order[i]] := 1;
  n := 0;
  for i := 0 to High(A) do
    if Drop[i] = 0 then
    begin
      A[n] := A[i];
      Inc(n);
    end;
  SetLength(A, n);
end;

procedure MergeMatchupCells(var Dst: TMatchupCellArray; const Src: TMatchupCellArray);
var
  i, p: LongInt;
begin
  if Length(Src) = 0 then
    Exit;
  Dst := Copy(Dst);
  for i := 0 to High(Src) do
    if MatchupCellPos(Dst, Src[i].Killer, Src[i].Victim, p) then
      Inc(Dst[p].Kills, Src[i].Kills)
    else
      Insert(Src[i], Dst, p);
end;

function Merge3MatchupCells(const Cur, Base, Remote: TMatchupCellArray): TMatchupCellArray;
var
  i, p, q, n: LongInt;
  E, Z: TMatchupCell;
begin
  Result := Copy(Remote);
  for i := 0 to High(Cur) do
  begin
    E := Cur[i];
    FillChar(Z, SizeOf(Z), 0);
    if MatchupCellPos(Base, E.Killer, E.Victim, q) then
      Z := Base[q];
    if MatchupCellPos(Result, E.Killer, E.Victim, p) then
      Inc(Result[p].Kills, E.Kills - Z.Kills)
    else
    begin
      Dec(E.Kills, Z.Kills);
      Insert(E, Result, p);
    end;
  end;
  { a pair this server does not have any more (a reset) takes its part out of the database's }
  for i := 0 to High(Base) do
    if not MatchupCellPos(Cur, Base[i].Killer, Base[i].Victim, q) and
       MatchupCellPos(Result, Base[i].Killer, Base[i].Victim, p) then
      Dec(Result[p].Kills, Base[i].Kills);
  n := 0;
  for i := 0 to High(Result) do
    if Result[i].Kills > 0 then
    begin
      Result[n] := Result[i];
      Inc(n);
    end;
  SetLength(Result, n);
end;

procedure MergePlayerMapInto(var Dst: TPlayerMapStats; const Src: TPlayerMapStats; MaxRivals: LongInt);
var
  i, p: LongInt;
begin
  SumFields(@Dst, @Src, PlayerMapFields);
  if Length(Src.Weapons) > 0 then
  begin
    Dst.Weapons := Copy(Dst.Weapons);
    for i := 0 to High(Src.Weapons) do
      if PMWeaponPos(Dst.Weapons, Src.Weapons[i].Slot, p) then
        SumFields(@Dst.Weapons[p], @Src.Weapons[i], PMWeaponFields)
      else
        Insert(Src.Weapons[i], Dst.Weapons, p);
  end;
  if Length(Src.Rivals) > 0 then
  begin
    Dst.Rivals := Copy(Dst.Rivals);
    for i := 0 to High(Src.Rivals) do
      if PMRivalPos(Dst.Rivals, Src.Rivals[i].Id, p) then
        SumFields(@Dst.Rivals[p], @Src.Rivals[i], PMRivalFields)
      else
        Insert(Src.Rivals[i], Dst.Rivals, p);
  end;
  if Length(Src.Matchups) > 0 then
  begin
    Dst.Matchups := Copy(Dst.Matchups);
    for i := 0 to High(Src.Matchups) do
      if PMMatchupPos(Dst.Matchups, Src.Matchups[i].Mine, Src.Matchups[i].Theirs, p) then
        SumFields(@Dst.Matchups[p], @Src.Matchups[i], PMMatchupFields)
      else
        Insert(Src.Matchups[i], Dst.Matchups, p);
  end;
  if Length(Src.Heat) > 0 then
  begin
    Dst.Heat := Copy(Dst.Heat);
    for i := 0 to High(Src.Heat) do
      if HeatCellPos(Dst.Heat, Src.Heat[i].Cell, p) then
      begin
        Inc(Dst.Heat[p].Kills, Src.Heat[i].Kills);
        Inc(Dst.Heat[p].Deaths, Src.Heat[i].Deaths);
      end
      else
        Insert(Src.Heat[i], Dst.Heat, p);
  end;
  PMTrimRivals(Dst.Rivals, MaxRivals);
end;

{ The lists three ways, entry by entry (Merge3Fields per entry): an entry of Cur puts its change
  since Base on top of Remote's entry (or on nothing, when Remote has none); an entry of Base that
  Cur does not have any more (a reset, a trimmed rival) takes its part out of Remote's. A count
  never goes below 0, and an entry with nothing left goes. }
function Merge3Weapons(const Cur, Base, Remote: TPMWeaponArray): TPMWeaponArray;
var
  i, p, q, n: LongInt;
  E, B0, R0: TPMWeapon;
begin
  Result := Copy(Remote);
  for i := 0 to High(Cur) do
  begin
    E := Cur[i];
    FillChar(B0, SizeOf(B0), 0);
    B0.Slot := E.Slot;
    if PMWeaponPos(Base, E.Slot, q) then
      B0 := Base[q];
    if PMWeaponPos(Result, E.Slot, p) then
    begin
      Merge3Fields(@E, @B0, @Result[p], PMWeaponFields);
      Result[p] := E;
    end
    else
    begin
      FillChar(R0, SizeOf(R0), 0);
      R0.Slot := E.Slot;
      Merge3Fields(@E, @B0, @R0, PMWeaponFields);
      Insert(E, Result, p);
    end;
  end;
  for i := 0 to High(Base) do
    if not PMWeaponPos(Cur, Base[i].Slot, q) and PMWeaponPos(Result, Base[i].Slot, p) then
    begin
      FillChar(E, SizeOf(E), 0);
      E.Slot := Base[i].Slot;
      Merge3Fields(@E, @Base[i], @Result[p], PMWeaponFields);
      Result[p] := E;
    end;
  n := 0;
  for i := 0 to High(Result) do
  begin
    ClampSums(@Result[i], PMWeaponFields, 0);
    if not SumsZero(@Result[i], PMWeaponFields) then
    begin
      Result[n] := Result[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

{ as Merge3Weapons; the last fight is the later of the two sides }
function Merge3Rivals(const Cur, Base, Remote: TPMRivalArray): TPMRivalArray;
var
  i, p, q, n: LongInt;
  E, B0, R0: TPMRival;
  Last: Double;
begin
  Result := Copy(Remote);
  for i := 0 to High(Cur) do
  begin
    E := Cur[i];
    FillChar(B0, SizeOf(B0), 0);
    B0.Id := E.Id;
    if PMRivalPos(Base, E.Id, q) then
      B0 := Base[q];
    if PMRivalPos(Result, E.Id, p) then
    begin
      Last := Max(E.LastFight, Result[p].LastFight);
      Merge3Fields(@E, @B0, @Result[p], PMRivalFields);
      E.LastFight := Last;
      Result[p] := E;
    end
    else
    begin
      Last := E.LastFight;
      FillChar(R0, SizeOf(R0), 0);
      R0.Id := E.Id;
      Merge3Fields(@E, @B0, @R0, PMRivalFields);
      E.LastFight := Last;
      Insert(E, Result, p);
    end;
  end;
  for i := 0 to High(Base) do
    if not PMRivalPos(Cur, Base[i].Id, q) and PMRivalPos(Result, Base[i].Id, p) then
    begin
      Last := Result[p].LastFight;
      FillChar(E, SizeOf(E), 0);
      E.Id := Base[i].Id;
      Merge3Fields(@E, @Base[i], @Result[p], PMRivalFields);
      E.LastFight := Last;
      Result[p] := E;
    end;
  n := 0;
  for i := 0 to High(Result) do
  begin
    ClampSums(@Result[i], PMRivalFields, 0);
    if not SumsZero(@Result[i], PMRivalFields) then
    begin
      Result[n] := Result[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

function Merge3Matchups(const Cur, Base, Remote: TPMMatchupArray): TPMMatchupArray;
var
  i, p, q, n: LongInt;
  E, B0, R0: TPMMatchup;
begin
  Result := Copy(Remote);
  for i := 0 to High(Cur) do
  begin
    E := Cur[i];
    FillChar(B0, SizeOf(B0), 0);
    B0.Mine := E.Mine;
    B0.Theirs := E.Theirs;
    if PMMatchupPos(Base, E.Mine, E.Theirs, q) then
      B0 := Base[q];
    if PMMatchupPos(Result, E.Mine, E.Theirs, p) then
    begin
      Merge3Fields(@E, @B0, @Result[p], PMMatchupFields);
      Result[p] := E;
    end
    else
    begin
      FillChar(R0, SizeOf(R0), 0);
      R0.Mine := E.Mine;
      R0.Theirs := E.Theirs;
      Merge3Fields(@E, @B0, @R0, PMMatchupFields);
      Insert(E, Result, p);
    end;
  end;
  for i := 0 to High(Base) do
    if not PMMatchupPos(Cur, Base[i].Mine, Base[i].Theirs, q) and
       PMMatchupPos(Result, Base[i].Mine, Base[i].Theirs, p) then
    begin
      FillChar(E, SizeOf(E), 0);
      E.Mine := Base[i].Mine;
      E.Theirs := Base[i].Theirs;
      Merge3Fields(@E, @Base[i], @Result[p], PMMatchupFields);
      Result[p] := E;
    end;
  n := 0;
  for i := 0 to High(Result) do
  begin
    ClampSums(@Result[i], PMMatchupFields, 0);
    if not SumsZero(@Result[i], PMMatchupFields) then
    begin
      Result[n] := Result[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

{ the heat cells three ways, as Merge3Map does it for the map, by halving the sorted lists }
function Merge3HeatCells(const Cur, Base, Remote: THeatCellArray): THeatCellArray;
var
  i, p, q, n, BK, BD: LongInt;
  E: THeatCell;
begin
  Result := Copy(Remote);
  for i := 0 to High(Cur) do
  begin
    BK := 0;
    BD := 0;
    if HeatCellPos(Base, Cur[i].Cell, q) then
    begin
      BK := Base[q].Kills;
      BD := Base[q].Deaths;
    end;
    if HeatCellPos(Result, Cur[i].Cell, p) then
    begin
      Inc(Result[p].Kills, Cur[i].Kills - BK);
      Inc(Result[p].Deaths, Cur[i].Deaths - BD);
    end
    else
    begin
      E.Cell := Cur[i].Cell;
      E.Kills := Cur[i].Kills - BK;
      E.Deaths := Cur[i].Deaths - BD;
      Insert(E, Result, p);
    end;
  end;
  for i := 0 to High(Base) do
    if not HeatCellPos(Cur, Base[i].Cell, q) and HeatCellPos(Result, Base[i].Cell, p) then
    begin
      Dec(Result[p].Kills, Base[i].Kills);
      Dec(Result[p].Deaths, Base[i].Deaths);
    end;
  n := 0;
  for i := 0 to High(Result) do
  begin
    if Result[i].Kills < 0 then
      Result[i].Kills := 0;
    if Result[i].Deaths < 0 then
      Result[i].Deaths := 0;
    if (Result[i].Kills > 0) or (Result[i].Deaths > 0) then
    begin
      Result[n] := Result[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

procedure Merge3PlayerMap(var Cur: TPlayerMapStats; const Base, Remote: TPlayerMapStats);
var
  Saved: TPlayerMapStats;
begin
  Saved := Cur;
  Merge3Fields(@Cur, @Base, @Remote, PlayerMapFields);
  ClampSums(@Cur, PlayerMapFields, PM_POINTS_ID);
  Cur.AccountId := Saved.AccountId;
  Cur.MapName := Saved.MapName;
  { the dates: the first one and the last one of both sides }
  if (Remote.FirstPlayed > 0) and ((Saved.FirstPlayed <= 0) or (Remote.FirstPlayed < Saved.FirstPlayed)) then
    Cur.FirstPlayed := Remote.FirstPlayed
  else
    Cur.FirstPlayed := Saved.FirstPlayed;
  Cur.LastPlayed := Max(Saved.LastPlayed, Remote.LastPlayed);
  Cur.Weapons := Merge3Weapons(Saved.Weapons, Base.Weapons, Remote.Weapons);
  Cur.Rivals := Merge3Rivals(Saved.Rivals, Base.Rivals, Remote.Rivals);
  Cur.Matchups := Merge3Matchups(Saved.Matchups, Base.Matchups, Remote.Matchups);
  Cur.Heat := Merge3HeatCells(Saved.Heat, Base.Heat, Remote.Heat);
end;

procedure SortDefs(var Defs: TFieldDefArray);
var
  i, j: LongInt;
  T: TFieldDef;
begin
  for i := 1 to High(Defs) do
  begin
    T := Defs[i];
    j := i - 1;
    while (j >= 0) and (Defs[j].Id > T.Id) do
    begin
      Defs[j + 1] := Defs[j];
      Dec(j);
    end;
    Defs[j + 1] := T;
  end;
end;

initialization
  RegisterProfileFields;
  RegisterMapFields;
  RegisterServerFields;
  RegisterMatrixFields;
  SortDefs(ProfileFields);
  SortDefs(MapFields);
  SortDefs(ServerFields);
  BuildLookup(ProfileFields, ProfileLookup);
  BuildSharedProfileFields;
  BuildLookup(MapFields, MapLookup);
  BuildLookup(ServerFields, ServerLookup);
  SortDefs(PlayerMapFields);
  SortDefs(PMWeaponFields);
  SortDefs(PMRivalFields);
  SortDefs(PMMatchupFields);
  SortDefs(MatchupCellFields);
  BuildLookup(PlayerMapFields, PlayerMapLookup);
  BuildLookup(PMWeaponFields, PMWeaponLookup);
  BuildLookup(PMRivalFields, PMRivalLookup);
  BuildLookup(PMMatchupFields, PMMatchupLookup);
  BuildLookup(MatchupCellFields, MatchupCellLookup);

end.
