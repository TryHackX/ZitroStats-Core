unit zs_weapons;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util;

type
  TWeaponDef = record
    Damage: Single;       { weapons.ini "Damage" (bullet HitMultiply) }
    Speed: Single;
    ModHead: Single;
    ModChest: Single;
    ModLegs: Single;
    BulletStyle: LongInt;
    Ammo: LongInt;        { the magazine }
    ReloadTime: LongInt;  { ticks }
    FireInterval: LongInt;
    StartUpTime: LongInt;
    Inherit: Single;      { "InheritedVelocity": the share of the shooter's own velocity a bullet gets }
  end;

var
  WeaponDefs: array[0..WSLOT_COUNT - 1] of TWeaponDef;
  WeaponsIniLoaded: AnsiString = '';

function WepSlot(W: LongInt): LongInt;
function SlotWeapon(Slot: LongInt): LongInt;
function WeaponName(W: LongInt): AnsiString;
function WeaponShortName(W: LongInt): AnsiString;
function SlotName(Slot: LongInt): AnsiString;
function SlotShortName(Slot: LongInt): AnsiString;
{ the second weapon of Soldat's menu (Socom, knife, chainsaw, LAW): a player spawns with one of
  these and one primary, so the picks of the two groups are counted apart }
function IsSecondarySlot(Slot: LongInt): Boolean;
{ the weapon picked most in one group, from the picks per weapon slot; -1 when none. Count is its
  picks, Total those of its whole group. }
function TopPickSlot(const Picks: array of Int64; Secondary: Boolean; out Count, Total: Int64): LongInt;
{ a weapon number from one word - a name, its beginning or a part of it, a small typo, or the
  weapon number itself - or from a name of several words ("desert eagles"), which has to be
  whole; -2 = no weapon, -3 = the word fits more than one (WeaponCandidates says which) }
function ResolveWeapon(const Query: AnsiString): LongInt;
{ the same, whole names and numbers only }
function ResolveWeaponExact(const Query: AnsiString): LongInt;
function WeaponCandidates(const Query: AnsiString): AnsiString;
{ True for a text of digits only: no sign, no space, no "$" or "x" of a hexadecimal number }
function AllDigits(const S: AnsiString): Boolean;
function WeaponSweetSpot(W: LongInt): AnsiString;
function ShotMultiplier(W: LongInt): LongInt;
function CountsForAccuracy(W: LongInt): Boolean;
function IsExplosiveWeapon(W: LongInt): Boolean;
function IsMeleeWeapon(W: LongInt): Boolean;
function WeaponMaxBulletSpeed(W: LongInt): Single;
{ the weapons whose reloads are counted: every gun with a magazine; not the knife, the flamer
  (a bonus without reloads), the stationary gun, the fists or the grenades }
function ReloadTracked(W: LongInt): Boolean;

procedure ResetWeaponDefs;
function LoadWeaponsIni(const Path: AnsiString): Boolean;

{ Reconstructs the hit zone of a bullet hit from the damage the server reported.
  Damage is the value passed to OnDamage (already adjusted for vest / berserker),
  Speed is the bullet speed at the moment of the hit. Returns HZ_UNKNOWN when the
  damage cannot be matched unambiguously (explosives, script-modified damage,
  weapons with identical modifiers, rounding collisions on vest hits). }
function ClassifyZoneByDamage(W: LongInt; Damage, Speed: Single; VestApplied, Berserk: Boolean): LongInt;
function WeaponHasDistinctZones(W: LongInt): Boolean;
function ZoneClassifiableStyle(W: LongInt): Boolean;

implementation

procedure SetDef(Slot: LongInt; Dmg, Spd, H, C, L: Single; Style, Ammo: LongInt);
begin
  WeaponDefs[Slot].Damage := Dmg;
  WeaponDefs[Slot].Speed := Spd;
  WeaponDefs[Slot].ModHead := H;
  WeaponDefs[Slot].ModChest := C;
  WeaponDefs[Slot].ModLegs := L;
  WeaponDefs[Slot].BulletStyle := Style;
  WeaponDefs[Slot].Ammo := Ammo;
end;

procedure SetTiming(Slot, Reload, Interval, StartUp: LongInt);
begin
  WeaponDefs[Slot].ReloadTime := Reload;
  WeaponDefs[Slot].FireInterval := Interval;
  WeaponDefs[Slot].StartUpTime := StartUp;
end;

procedure ResetWeaponDefs;
var
  i: LongInt;
begin
  { Soldat 1.7.1 default weapons.ini }
  SetDef(0, 1.49, 18, 1.1, 0.95, 0.85, BS_PLAIN, 14);
  SetDef(1, 1.81, 19, 1.1, 0.95, 0.85, BS_PLAIN, 7);
  SetDef(2, 1.01, 18.9, 1.1, 0.95, 0.85, BS_PLAIN, 30);
  SetDef(3, 1.004, 24.6, 1.1, 0.95, 0.85, BS_PLAIN, 35);
  SetDef(4, 0.71, 26, 1.1, 0.95, 0.85, BS_PLAIN, 25);
  SetDef(5, 1.22, 14, 1.1, 0.95, 0.85, BS_SHOTGUN, 7);
  SetDef(6, 2.49, 33, 1.2, 1.05, 1.0, BS_PLAIN, 4);
  SetDef(7, 1550, 10.7, 1.15, 1.0, 0.9, BS_M79, 1);
  SetDef(8, 4.45, 55, 1.0, 1.0, 1.0, BS_PLAIN, 10);
  SetDef(9, 0.85, 27, 1.1, 0.95, 0.85, BS_PLAIN, 50);
  SetDef(10, 0.468, 29, 1.1, 0.95, 0.85, BS_PLAIN, 100);
  SetDef(11, 2150, 6, 1.15, 1.0, 0.9, BS_KNIFE, 1);
  SetDef(12, 50, 8, 1.15, 1.0, 0.9, BS_KNIFE, 200);
  SetDef(13, 1550, 23, 1.15, 1.0, 0.9, BS_LAW, 1);
  SetDef(14, 19, 10.5, 1.15, 1.0, 0.9, BS_FLAME, 200);
  SetDef(15, 12, 21, 1.15, 1.0, 0.9, BS_ARROW, 1);
  SetDef(16, 8, 18, 1.15, 1.0, 0.9, BS_FLAMEARROW, 1);
  SetDef(WSLOT_M2, 1.8, 36, 1.1, 0.95, 0.85, BS_M2, 100);
  SetDef(WSLOT_FISTS, 330, 5, 1.15, 1.0, 0.9, BS_PUNCH, 1);
  SetDef(WSLOT_FRAG, 1500, 5, 1.0, 1.0, 1.0, BS_FRAGNADE, 1);
  SetDef(WSLOT_CLUSTER, 1500, 5, 1.0, 1.0, 1.0, BS_CLUSTER, 1);
  for i := 0 to WSLOT_COUNT - 1 do
    SetTiming(i, 0, 0, 0);
  { half of the shooter's velocity goes into a bullet; blades, fists and the stationary gun get
    none, a thrown grenade all of it }
  for i := 0 to WSLOT_COUNT - 1 do
    WeaponDefs[i].Inherit := 0.5;
  WeaponDefs[WEP_KNIFE].Inherit := 0;
  WeaponDefs[WEP_CHAINSAW].Inherit := 0;
  WeaponDefs[WSLOT_M2].Inherit := 0;
  WeaponDefs[WSLOT_FISTS].Inherit := 0;
  WeaponDefs[WSLOT_FRAG].Inherit := 1;
  WeaponDefs[WSLOT_CLUSTER].Inherit := 1;
  SetTiming(0, 60, 10, 0);
  SetTiming(1, 87, 24, 0);
  SetTiming(2, 105, 6, 0);
  SetTiming(3, 165, 10, 0);
  SetTiming(4, 125, 7, 0);
  SetTiming(5, 175, 32, 0);
  SetTiming(6, 78, 45, 0);
  SetTiming(7, 178, 6, 0);
  SetTiming(8, 70, 225, 19);
  SetTiming(9, 250, 9, 0);
  SetTiming(10, 480, 3, 25);
  SetTiming(12, 110, 2, 0);
  SetTiming(13, 300, 6, 13);
  SetTiming(15, 25, 10, 0);
  SetTiming(16, 39, 10, 0);
  WeaponsIniLoaded := '';
end;

function ReloadTracked(W: LongInt): Boolean;
begin
  Result := (W >= WEP_SOCOM) and (W <= WEP_BOW2) and (W <> WEP_KNIFE) and (W <> WEP_FLAMER);
end;

function WepSlot(W: LongInt): LongInt;
begin
  case W of
    0..16: Result := W;
    WEP_M2: Result := WSLOT_M2;
    WEP_NONE: Result := WSLOT_FISTS;
    WEP_FRAG: Result := WSLOT_FRAG;
    WEP_CLUSTERNADE, WEP_CLUSTER: Result := WSLOT_CLUSTER;
    WEP_THROWNKNIFE: Result := WEP_KNIFE;
    else Result := -1;
  end;
end;

function SlotWeapon(Slot: LongInt): LongInt;
begin
  case Slot of
    0..16: Result := Slot;
    WSLOT_M2: Result := WEP_M2;
    WSLOT_FISTS: Result := WEP_NONE;
    WSLOT_FRAG: Result := WEP_FRAG;
    WSLOT_CLUSTER: Result := WEP_CLUSTERNADE;
    else Result := -1;
  end;
end;

function WeaponName(W: LongInt): AnsiString;
begin
  case W of
    WEP_SOCOM: Result := 'USSOCOM';
    WEP_DEAGLES: Result := 'Desert Eagles';
    WEP_MP5: Result := 'HK MP5';
    WEP_AK74: Result := 'AK-74';
    WEP_AUG: Result := 'Steyr AUG';
    WEP_SPAS: Result := 'Spas-12';
    WEP_RUGER: Result := 'Ruger 77';
    WEP_M79: Result := 'M79';
    WEP_BARRETT: Result := 'Barrett M82A1';
    WEP_MINIMI: Result := 'FN Minimi';
    WEP_MINIGUN: Result := 'XM214 Minigun';
    WEP_KNIFE, WEP_THROWNKNIFE: Result := 'Combat Knife';
    WEP_CHAINSAW: Result := 'Chainsaw';
    WEP_LAW: Result := 'M72 LAW';
    WEP_FLAMER: Result := 'Flamer';
    WEP_BOW: Result := 'Rambo Bow';
    WEP_BOW2: Result := 'Flamed Arrows';
    WEP_M2: Result := 'Stationary Gun';
    WEP_FRAG: Result := 'Grenade';
    WEP_CLUSTERNADE, WEP_CLUSTER: Result := 'Cluster Grenade';
    WEP_NONE: Result := 'Fists';
    else Result := 'Other';
  end;
end;

function WeaponShortName(W: LongInt): AnsiString;
begin
  case W of
    WEP_SOCOM: Result := 'Socom';
    WEP_DEAGLES: Result := 'Deagle';
    WEP_MP5: Result := 'MP5';
    WEP_AK74: Result := 'AK';
    WEP_AUG: Result := 'AUG';
    WEP_SPAS: Result := 'Spas';
    WEP_RUGER: Result := 'Ruger';
    WEP_M79: Result := 'M79';
    WEP_BARRETT: Result := 'Barrett';
    WEP_MINIMI: Result := 'Minimi';
    WEP_MINIGUN: Result := 'Minigun';
    WEP_KNIFE, WEP_THROWNKNIFE: Result := 'Knife';
    WEP_CHAINSAW: Result := 'Saw';
    WEP_LAW: Result := 'LAW';
    WEP_FLAMER: Result := 'Flamer';
    WEP_BOW: Result := 'Bow';
    WEP_BOW2: Result := 'FlameBow';
    WEP_M2: Result := 'StatGun';
    WEP_FRAG: Result := 'Nade';
    WEP_CLUSTERNADE, WEP_CLUSTER: Result := 'Cluster';
    WEP_NONE: Result := 'Fists';
    else Result := 'Other';
  end;
end;

function SlotName(Slot: LongInt): AnsiString;
begin
  Result := WeaponName(SlotWeapon(Slot));
end;

function SlotShortName(Slot: LongInt): AnsiString;
begin
  Result := WeaponShortName(SlotWeapon(Slot));
end;

function IsSecondarySlot(Slot: LongInt): Boolean;
begin
  Result := (Slot = WEP_SOCOM) or (Slot = WEP_KNIFE) or (Slot = WEP_CHAINSAW) or (Slot = WEP_LAW);
end;

function TopPickSlot(const Picks: array of Int64; Secondary: Boolean; out Count, Total: Int64): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  Count := 0;
  Total := 0;
  for k := 0 to High(Picks) do
    if IsSecondarySlot(k) = Secondary then
    begin
      Inc(Total, Picks[k]);
      if Picks[k] > Count then
      begin
        Count := Picks[k];
        Result := k;
      end;
    end;
end;

function CleanQuery(const S: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := LowerCase(S[i]);
    if c in ['a'..'z', '0'..'9'] then Result := Result + c;
  end;
end;

const
  { the words a weapon is known by; the first one is its short name }
  WEAPON_WORDS: array[0..20] of AnsiString = (
    'socom ussocom colt pistol pistolet',
    'deagle deagles desert deserteagle deserteagles de',
    'mp5 mp5k hk hkmp5 heckler',
    'ak ak74 ak47 kalash kalasz kalashnikov kalaszek',
    'aug steyr steyraug',
    'spas spas12 shotgun pompka szotgan',
    'ruger ruger77 rug',
    'm79 grenadelauncher gl granatnik',
    'barrett barret barretm82a1 barrettm82a1 m82 m82a1 sniper snajper snajperka',
    'minimi fnminimi m249 fn',
    'minigun xm214 xm gatling chaingun mini xm214minigun',
    'knife combatknife noz nozyk kosa',
    'chainsaw saw pila pilka',
    'law m72 m72law bazooka rocket rpg rakieta',
    'flamer flame flamethrower miotacz ogien',
    'bow rambo rambobow luk',
    'arrows arrow flamedarrows flamebow strzala strzaly',
    'statgun stationary stationarygun m2 m2mg turret ckm',
    'nade nades grenade grenades granat granaty frag',
    'cluster clusters clusternade klaster clustergrenade clustergrenades',
    'fists fist hand hands punch piesc piesci');
  WEAPON_WORD_IDS: array[0..20] of LongInt = (WEP_SOCOM, WEP_DEAGLES, WEP_MP5, WEP_AK74, WEP_AUG,
    WEP_SPAS, WEP_RUGER, WEP_M79, WEP_BARRETT, WEP_MINIMI, WEP_MINIGUN, WEP_KNIFE, WEP_CHAINSAW,
    WEP_LAW, WEP_FLAMER, WEP_BOW, WEP_BOW2, WEP_M2, WEP_FRAG, WEP_CLUSTERNADE, WEP_NONE);

function EditDistance(const A, B: AnsiString): LongInt;
var
  Prev, Cur: array of LongInt;
  i, j, Cost: LongInt;
begin
  Prev := nil;
  Cur := nil;
  SetLength(Prev, Length(B) + 1);
  SetLength(Cur, Length(B) + 1);
  for j := 0 to Length(B) do
    Prev[j] := j;
  for i := 1 to Length(A) do
  begin
    Cur[0] := i;
    for j := 1 to Length(B) do
    begin
      if A[i] = B[j] then Cost := 0 else Cost := 1;
      Cur[j] := Min(Min(Prev[j] + 1, Cur[j - 1] + 1), Prev[j - 1] + Cost);
    end;
    Prev := Copy(Cur);
  end;
  Result := Prev[Length(B)];
end;

{ The weapons a query can mean, as places in WEAPON_WORDS, the strongest way that finds any:
  a whole word, the start of the short name, the start of any word, a part of a word (3 letters
  or more), a word with one typo (4 letters or more; two typos from 7). }
function WeaponMatches(const Query: AnsiString): TIntArray;
var
  W, Words: AnsiString;
  Parts: TStringArray;
  Step, k, j, Best, D, Allowed: LongInt;
  Hit: Boolean;
  Dist: array[0..20] of LongInt;

  procedure Take(k: LongInt);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := k;
  end;

begin
  Result := nil;
  { several words are a name as a whole or nothing (PhraseWeapon), never a beginning or a typo }
  if Pos(' ', Trim(Query)) > 0 then
    Exit;
  W := CleanQuery(Query);
  if W = '' then
    Exit;
  for Step := 1 to 5 do
  begin
    if (Step = 4) and (Length(W) < 3) then
      Continue;
    if (Step = 5) and (Length(W) < 4) then
      Continue;
    Best := MaxInt;
    for k := 0 to High(WEAPON_WORDS) do
    begin
      Words := WEAPON_WORDS[k];
      Parts := SplitWords(Words);
      Hit := False;
      Dist[k] := MaxInt;
      for j := 0 to High(Parts) do
        case Step of
          1: if Parts[j] = W then Hit := True;
          2: if (j = 0) and (Copy(Parts[j], 1, Length(W)) = W) then Hit := True;
          3: if Copy(Parts[j], 1, Length(W)) = W then Hit := True;
          4: if Pos(W, Parts[j]) > 0 then Hit := True;
          5:
            begin
              if Length(W) >= 7 then Allowed := 2 else Allowed := 1;
              D := EditDistance(W, Parts[j]);
              if (D <= Allowed) and (D < Dist[k]) then
                Dist[k] := D;
            end;
        end;
      if Step = 5 then
      begin
        if Dist[k] < Best then
          Best := Dist[k];
      end
      else if Hit then
        Take(k);
    end;
    if Step = 5 then
      for k := 0 to High(WEAPON_WORDS) do
        if (Best < MaxInt) and (Dist[k] = Best) then
          Take(k);
    if Length(Result) > 0 then
      Exit;
  end;
end;

function AllDigits(const S: AnsiString): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then
      Exit(False);
end;

const
  { names of more than one word; a text of several words is a weapon only when it is one of
    these, so the words after a weapon stay free for the player: "!wep deagle s" is player "s" }
  WEAPON_PHRASES: array[0..20] of AnsiString = ('desert eagles', 'desert eagle', 'hk mp5', 'ak 74', 'ak 47',
    'steyr aug', 'spas 12', 'ruger 77', 'grenade launcher', 'barrett m82a1', 'barrett m82', 'fn minimi',
    'xm214 minigun', 'combat knife', 'm72 law', 'rambo bow', 'flamed arrows', 'stationary gun',
    'cluster grenade', 'cluster grenades', 'frag grenade');
  WEAPON_PHRASE_IDS: array[0..20] of LongInt = (WEP_DEAGLES, WEP_DEAGLES, WEP_MP5, WEP_AK74, WEP_AK74,
    WEP_AUG, WEP_SPAS, WEP_RUGER, WEP_M79, WEP_BARRETT, WEP_BARRETT, WEP_MINIMI,
    WEP_MINIGUN, WEP_KNIFE, WEP_LAW, WEP_BOW, WEP_BOW2, WEP_M2,
    WEP_CLUSTERNADE, WEP_CLUSTERNADE, WEP_FRAG);

{ a name of several words: the words in lower case with one space between them must be one of
  WEAPON_PHRASES ("Desert  Eagles", "AK-47" and "ak 47" all fit) }
function PhraseWeapon(const Query: AnsiString): LongInt;
var
  S: AnsiString;
  i, k: LongInt;
  c: AnsiChar;
begin
  Result := -2;
  S := '';
  for i := 1 to Length(Query) do
  begin
    c := LowerCase(Query[i]);
    if c in ['a'..'z', '0'..'9'] then
      S := S + c
    else if (S <> '') and (S[Length(S)] <> ' ') then
      S := S + ' ';
  end;
  S := Trim(S);
  for k := 0 to High(WEAPON_PHRASES) do
    if WEAPON_PHRASES[k] = S then
      Exit(WEAPON_PHRASE_IDS[k]);
end;

{ a weapon by its number: 0-16, 30, 50, 51, 52 (cluster), 53 (knife) and 255 (fists) }
function NumberWeapon(const Digits: AnsiString): LongInt;
var
  Num: LongInt;
begin
  Result := -2;
  if not AllDigits(Digits) or (Length(Digits) > 3) then
    Exit;
  Num := StrToInt(Digits);
  if Num <= 16 then
    Result := Num
  else
    case Num of
      30, 50, 51, 255: Result := Num;
      52: Result := WEP_CLUSTERNADE;
      53: Result := WEP_KNIFE;
    end;
end;

function ResolveWeapon(const Query: AnsiString): LongInt;
var
  T: AnsiString;
  M: TIntArray;
begin
  Result := -2;
  T := Trim(Query);
  if T = '' then
    Exit;
  if Pos(' ', T) > 0 then
    Exit(PhraseWeapon(T));
  if AllDigits(T) then
    Exit(NumberWeapon(T));
  M := WeaponMatches(T);
  if Length(M) = 1 then
    Result := WEAPON_WORD_IDS[M[0]]
  else if Length(M) > 1 then
    Result := -3;
end;

function ResolveWeaponExact(const Query: AnsiString): LongInt;
var
  T, W: AnsiString;
  k, j: LongInt;
  Parts: TStringArray;
begin
  Result := -2;
  T := Trim(Query);
  if T = '' then
    Exit;
  if Pos(' ', T) > 0 then
    Exit(PhraseWeapon(T));
  if AllDigits(T) then
    Exit(NumberWeapon(T));
  W := CleanQuery(T);
  if W = '' then
    Exit;
  for k := 0 to High(WEAPON_WORDS) do
  begin
    Parts := SplitWords(WEAPON_WORDS[k]);
    for j := 0 to High(Parts) do
      if Parts[j] = W then
        Exit(WEAPON_WORD_IDS[k]);
  end;
end;

function WeaponCandidates(const Query: AnsiString): AnsiString;
var
  M: TIntArray;
  k: LongInt;
begin
  Result := '';
  M := WeaponMatches(Query);
  for k := 0 to High(M) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + WeaponName(WEAPON_WORD_IDS[M[k]]) + ' (' + SplitWords(WEAPON_WORDS[M[k]])[0] + ')';
  end;
end;

function WeaponSweetSpot(W: LongInt): AnsiString;
begin
  case W of
    WEP_SOCOM: Result := '0-25m (Close)';
    WEP_DEAGLES: Result := '10-40m (Mid)';
    WEP_MP5: Result := '0-30m (Close)';
    WEP_AK74, WEP_AUG, WEP_MINIMI: Result := '20-60m (Assault)';
    WEP_SPAS: Result := '0-20m (CQB)';
    WEP_RUGER: Result := '40-80m (Long)';
    WEP_M79: Result := '20-60m (Explosive)';
    WEP_BARRETT: Result := '60m+ (Sniper)';
    WEP_MINIGUN: Result := '10-40m (Close-Mid)';
    WEP_KNIFE, WEP_THROWNKNIFE: Result := '0-25m (Melee/Throw)';
    WEP_CHAINSAW, WEP_NONE: Result := '0-5m (Melee)';
    WEP_LAW: Result := '30-90m (Anti-Armor)';
    WEP_FLAMER: Result := '0-20m (Cone)';
    WEP_BOW, WEP_BOW2: Result := '20-70m (Bow)';
    WEP_M2: Result := '20-70m (Turret)';
    else Result := 'Variable';
  end;
end;

function ShotMultiplier(W: LongInt): LongInt;
begin
  case W of
    WEP_DEAGLES: Result := 2;
    WEP_SPAS: Result := 6;
    else Result := 1;
  end;
end;

{ overall accuracy is for guns: melee fires no shots, explosions or flames hit many players or none,
  and the shots of the stationary gun cannot be seen (main.pas follows the player's own weapon) }
function CountsForAccuracy(W: LongInt): Boolean;
begin
  Result := (WepSlot(W) >= 0) and not IsMeleeWeapon(W) and not IsExplosiveWeapon(W) and
    (W <> WEP_FLAMER) and (W <> WEP_THROWNKNIFE) and (W <> WEP_M2);
end;

function IsExplosiveWeapon(W: LongInt): Boolean;
begin
  Result := (W = WEP_M79) or (W = WEP_LAW) or (W = WEP_FRAG) or (W = WEP_CLUSTERNADE) or (W = WEP_CLUSTER) or
    (W = WEP_BOW2);
end;

function IsMeleeWeapon(W: LongInt): Boolean;
begin
  Result := (W = WEP_KNIFE) or (W = WEP_CHAINSAW) or (W = WEP_NONE);
end;

function WeaponMaxBulletSpeed(W: LongInt): Single;
var
  S: LongInt;
begin
  S := WepSlot(W);
  if S < 0 then Exit(60);
  Result := WeaponDefs[S].Speed;
  if Result < 5 then Result := 5;
end;

function SectionToWeapon(const Name: AnsiString): LongInt;
var
  N: AnsiString;
begin
  N := LowerCase(Trim(Name));
  if N = 'desert eagles' then Result := WEP_DEAGLES
  else if N = 'hk mp5' then Result := WEP_MP5
  else if (N = 'ak-74') or (N = 'ak-47') then Result := WEP_AK74
  else if N = 'steyr aug' then Result := WEP_AUG
  else if N = 'spas-12' then Result := WEP_SPAS
  else if N = 'ruger 77' then Result := WEP_RUGER
  else if N = 'm79' then Result := WEP_M79
  else if (N = 'barret m82a1') or (N = 'barrett m82a1') then Result := WEP_BARRETT
  else if N = 'fn minimi' then Result := WEP_MINIMI
  else if N = 'xm214 minigun' then Result := WEP_MINIGUN
  else if N = 'ussocom' then Result := WEP_SOCOM
  else if N = 'combat knife' then Result := WEP_KNIFE
  else if N = 'chainsaw' then Result := WEP_CHAINSAW
  else if N = 'm72 law' then Result := WEP_LAW
  else if N = 'punch' then Result := WEP_NONE
  else if N = 'grenade' then Result := WEP_FRAG
  else if N = 'stationary gun' then Result := WEP_M2
  else if N = 'flamer' then Result := WEP_FLAMER
  else if N = 'rambo bow' then Result := WEP_BOW
  else if N = 'flamed arrows' then Result := WEP_BOW2
  else Result := -2;
end;

function LoadWeaponsIni(const Path: AnsiString): Boolean;
var
  L: TStringList;
  i, Eq, W, S: LongInt;
  Line, Key, Val: AnsiString;
  FS: TFormatSettings;
begin
  Result := False;
  ResetWeaponDefs;
  if (Path = '') or not FileExists(Path) then Exit;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    S := -1;
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if (Line = '') or (Line[1] = ';') then Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        W := SectionToWeapon(Copy(Line, 2, Length(Line) - 2));
        if W = -2 then S := -1 else S := WepSlot(W);
        Continue;
      end;
      if S < 0 then Continue;
      Eq := Pos('=', Line);
      if Eq <= 0 then Continue;
      Key := LowerCase(Trim(Copy(Line, 1, Eq - 1)));
      Val := Trim(Copy(Line, Eq + 1, MaxInt));
      if Key = 'damage' then WeaponDefs[S].Damage := StrToFloatDef(Val, WeaponDefs[S].Damage, FS)
      else if Key = 'speed' then WeaponDefs[S].Speed := StrToFloatDef(Val, WeaponDefs[S].Speed, FS)
      else if Key = 'modifierhead' then WeaponDefs[S].ModHead := StrToFloatDef(Val, WeaponDefs[S].ModHead, FS)
      else if Key = 'modifierchest' then WeaponDefs[S].ModChest := StrToFloatDef(Val, WeaponDefs[S].ModChest, FS)
      else if Key = 'modifierlegs' then WeaponDefs[S].ModLegs := StrToFloatDef(Val, WeaponDefs[S].ModLegs, FS)
      else if Key = 'bulletstyle' then WeaponDefs[S].BulletStyle := StrToIntDef(Val, WeaponDefs[S].BulletStyle)
      else if Key = 'ammo' then WeaponDefs[S].Ammo := StrToIntDef(Val, WeaponDefs[S].Ammo)
      else if Key = 'reloadtime' then WeaponDefs[S].ReloadTime := StrToIntDef(Val, WeaponDefs[S].ReloadTime)
      else if Key = 'fireinterval' then WeaponDefs[S].FireInterval := StrToIntDef(Val, WeaponDefs[S].FireInterval)
      else if Key = 'startuptime' then WeaponDefs[S].StartUpTime := StrToIntDef(Val, WeaponDefs[S].StartUpTime)
      else if Key = 'inheritedvelocity' then WeaponDefs[S].Inherit := StrToFloatDef(Val, WeaponDefs[S].Inherit, FS);
    end;
    WeaponsIniLoaded := Path;
    Result := True;
  finally
    L.Free;
  end;
end;

function ZoneClassifiableStyle(W: LongInt): Boolean;
var
  S: LongInt;
begin
  S := WepSlot(W);
  { knife, chainsaw and fists hit at arm's length: the zone would only be a guess }
  if (S < 0) or (W = WEP_THROWNKNIFE) or IsMeleeWeapon(W) then Exit(False);
  Result := WeaponDefs[S].BulletStyle in [BS_PLAIN, BS_SHOTGUN, BS_ARROW, BS_M2];
end;

function WeaponHasDistinctZones(W: LongInt): Boolean;
var
  S: LongInt;
  D: TWeaponDef;
begin
  S := WepSlot(W);
  if S < 0 then Exit(False);
  D := WeaponDefs[S];
  Result := (Abs(D.ModHead - D.ModChest) > 0.001) and (Abs(D.ModChest - D.ModLegs) > 0.001) and
            (Abs(D.ModHead - D.ModLegs) > 0.001);
end;

function ClassifyZoneByDamage(W: LongInt; Damage, Speed: Single; VestApplied, Berserk: Boolean): LongInt;
var
  S, z, Matches, Best: LongInt;
  Base, Raw, Rel, BestErr, Err: Double;
  Mods: array[0..2] of Double;
begin
  Result := HZ_UNKNOWN;
  if (Damage <= 0) or (Speed <= 0.01) then Exit;
  if not ZoneClassifiableStyle(W) then Exit;
  if not WeaponHasDistinctZones(W) then Exit;
  S := WepSlot(W);
  Base := Speed * WeaponDefs[S].Damage;
  if Base <= 0 then Exit;
  Mods[HZ_HEAD] := WeaponDefs[S].ModHead;
  Mods[HZ_BODY] := WeaponDefs[S].ModChest;
  Mods[HZ_LEGS] := WeaponDefs[S].ModLegs;

  if Berserk then
  begin
    Raw := Damage / 4.0;
    VestApplied := False;
  end
  else
    Raw := Damage;

  if VestApplied then
  begin
    { Server: health damage = Round(0.25 * raw). Accept only a unique exact match. }
    Matches := 0;
    Best := HZ_UNKNOWN;
    for z := 0 to 2 do
      if Round(0.25 * Base * Mods[z]) = Round(Damage) then
      begin
        Inc(Matches);
        Best := z;
      end;
    if Matches = 1 then Result := Best;
    Exit;
  end;

  BestErr := 1e9;
  Best := HZ_UNKNOWN;
  for z := 0 to 2 do
  begin
    Rel := Raw / (Base * Mods[z]);
    Err := Abs(Rel - 1.0);
    if Err < BestErr then
    begin
      BestErr := Err;
      Best := z;
    end;
  end;
  { Distinct modifiers differ by at least ~5%, so a 2% window is unambiguous. }
  if BestErr <= 0.02 then Result := Best;
end;

initialization
  ResetWeaponDefs;

end.
