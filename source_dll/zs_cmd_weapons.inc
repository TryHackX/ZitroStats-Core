{ zs_commands: weapons - personal arsenal, deep dive, matchups and weapon rankings }

const
  WEAPON_METRICS: array[0..33] of TMetricDef = (
    (Aliases: ' kills kill k '; Header: 'Kills'; Fmt: mfInt; Asc: False),                           { 0 }
    (Aliases: ' deaths death d '; Header: 'Deaths'; Fmt: mfInt; Asc: False),
    (Aliases: ' kd kdr '; Header: 'K/D'; Fmt: mfDec2; Asc: False),
    (Aliases: ' shots shot '; Header: 'Shots'; Fmt: mfInt; Asc: False),
    (Aliases: ' hits hit '; Header: 'Hits'; Fmt: mfInt; Asc: False),
    (Aliases: ' acc accuracy '; Header: 'Acc%'; Fmt: mfPct; Asc: False),                            { 5 }
    (Aliases: ' hs headshots head '; Header: 'Headshots'; Fmt: mfInt; Asc: False),
    (Aliases: ' hs% hsacc '; Header: 'HS%'; Fmt: mfPct; Asc: False),
    (Aliases: ' dmg damage '; Header: 'Damage'; Fmt: mfDmg; Asc: False),
    (Aliases: ' dmgtaken dmgin '; Header: 'DmgIn'; Fmt: mfDmg; Asc: False),
    (Aliases: ' dmgratio dr '; Header: 'DmgRatio'; Fmt: mfDec2; Asc: False),                        { 10 }
    (Aliases: ' time playtime usage '; Header: 'Time'; Fmt: mfTime; Asc: False),
    (Aliases: ' avgdist distance dist '; Header: 'AvgDist'; Fmt: mfMeters; Asc: False),
    (Aliases: ' ttk avgttk '; Header: 'AvgTTK'; Fmt: mfSec; Asc: True),
    (Aliases: ' picks pick popularity '; Header: 'Picks'; Fmt: mfInt; Asc: False),
    (Aliases: ' vestkills vest '; Header: 'VestKills'; Fmt: mfInt; Asc: False),                     { 15 }
    (Aliases: ' longest longkill '; Header: 'Longest'; Fmt: mfMeters; Asc: False),
    (Aliases: ' alphapicks picksalpha '; Header: 'AlphaPicks'; Fmt: mfInt; Asc: False),
    (Aliases: ' bravopicks picksbravo '; Header: 'BravoPicks'; Fmt: mfInt; Asc: False),               { 18 }
    (Aliases: ' reloads reload '; Header: 'Reloads'; Fmt: mfInt; Asc: False),
    (Aliases: ' reloadtime rtime '; Header: 'AvgReload'; Fmt: mfSec; Asc: True),                      { 20 }
    (Aliases: ' finished reloaddone '; Header: 'Finished%'; Fmt: mfPct; Asc: False),
    (Aliases: ' progress reloadprogress '; Header: 'Progress%'; Fmt: mfPct; Asc: False),
    (Aliases: ' rdeaths reloaddeaths '; Header: 'DiedReloading'; Fmt: mfInt; Asc: False),
    (Aliases: ' rdeath% reloaddeath% '; Header: 'DiedRel%'; Fmt: mfPct; Asc: False),
    (Aliases: ' manual manual% '; Header: 'Manual%'; Fmt: mfPct; Asc: False),                         { 25 }
    (Aliases: ' dropped roundsdropped '; Header: 'RoundsLost'; Fmt: mfInt; Asc: False),
    (Aliases: ' reloading reloadingtime '; Header: 'Reloading'; Fmt: mfTime; Asc: False),              { 27 }
    (Aliases: ' pick% pickshare '; Header: 'Pick%'; Fmt: mfPct; Asc: False),
    (Aliases: ' killeq dmgk '; Header: 'DmgKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' deatheq dmgd '; Header: 'DmgDeaths'; Fmt: mfInt; Asc: False),                         { 30 }
    (Aliases: ' dmgperkill dpk '; Header: 'Dmg/Kill'; Fmt: mfInt; Asc: True),
    (Aliases: ' dmgperdeath dpd '; Header: 'Dmg/Death'; Fmt: mfInt; Asc: False),
    (Aliases: ' kdmgratio kdmg '; Header: 'KDmgRatio'; Fmt: mfDec2; Asc: True)                         { 33 }
  );

  DIST_BUCKET_NAMES: array[0..4] of AnsiString = ('<10m', '10-25m', '25-50m', '50-100m', '100m+');

  { !allweapons: weapon, kills, deaths, K/D, shots, hits, Acc%, HS%, damage out, damage ratio and
    time - at most 92 of LINE_W }
  WEAPON_COLS: array[0..10] of LongInt = (17, 7, 7, 7, 7, 7, 8, 8, 8, 8, 9);
  { !serverweapons: weapon, kills, share of all kills, share of the picks of its group, shots, hits,
    Acc%, HS%, damage out and time - at most 85 of LINE_W }
  SERVER_WEAPON_COLS: array[0..9] of LongInt = (17, 7, 7, 8, 7, 7, 8, 8, 8, 9);

{ the weapons of one account added to the totals }
procedure AddWeaponTotals(var T: array of TWeaponTotals; const P: TPlayerProfile);
var
  S: LongInt;
  V: TWeaponView;
  R: PWeaponStats;
begin
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    V := WeaponView(P, S);
    Inc(T[S].Kills, V.Kills);
    Inc(T[S].Deaths, V.Deaths);
    Inc(T[S].Shots, V.Shots);
    Inc(T[S].Hits, V.Hits);
    Inc(T[S].Headshots, V.Headshots);
    Inc(T[S].Time, V.Time);
    T[S].Damage := T[S].Damage + V.Damage;
    T[S].DamageIn := T[S].DamageIn + V.DamageIn;
    if V.Longest > T[S].Longest then
      T[S].Longest := V.Longest;
    R := @P.Weapons[S];
    Inc(T[S].Reloads, R^.Reloads);
    Inc(T[S].ReloadsManual, R^.ReloadsManual);
    Inc(T[S].RoundsDropped, R^.RoundsDropped);
    Inc(T[S].ReloadsDone, R^.ReloadsDone);
    Inc(T[S].ReloadsCut, R^.ReloadsCut);
    Inc(T[S].ReloadDeaths, R^.ReloadDeaths);
    Inc(T[S].ReloadTimed, R^.ReloadTimed);
    Inc(T[S].ReloadTicks, R^.ReloadTicks);
    Inc(T[S].ReloadNormTicks, R^.ReloadNormTicks);
    Inc(T[S].ReloadEnds, R^.ReloadEnds);
    Inc(T[S].ReloadDoneMille, R^.ReloadDoneMille);
    Inc(T[S].ReloadDeathMille, R^.ReloadDeathMille);
    Inc(T[S].ReloadTicksAll, R^.ReloadTicksAll);
  end;
end;

procedure CollectWeaponTotals(E: TZSEngine; var T: array of TWeaponTotals; Shared: Boolean = False);
var
  k, S: LongInt;
  SV: PServerRecords;
  SrvTmp: TServerRecords;
  Sum: TPlayerProfile;
begin
  SV := SharedServerView(E, Shared, SrvTmp);
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    FillChar(T[S], SizeOf(T[S]), 0);
    T[S].WSlot := S;
    T[S].Picks := SV^.WeaponGlobal[S].Picks;
    T[S].VestKills := SV^.WeaponGlobal[S].VestKills;
  end;
  for k := 0 to E.DB.ProfileCount - 1 do
    if E.DB.Valid(k) then
      AddWeaponTotals(T, E.DB.Profiles[k]^);
  { the other servers: their accounts added up }
  if Shared and SharedAccountSums(E, True, Sum) then
    AddWeaponTotals(T, Sum);
end;

{ the reload counters of one account and weapon, in the shape of the server totals }
function ReloadTotalsOf(const R: TWeaponStats): TWeaponTotals;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Reloads := R.Reloads;
  Result.ReloadsManual := R.ReloadsManual;
  Result.RoundsDropped := R.RoundsDropped;
  Result.ReloadsDone := R.ReloadsDone;
  Result.ReloadsCut := R.ReloadsCut;
  Result.ReloadDeaths := R.ReloadDeaths;
  Result.ReloadTimed := R.ReloadTimed;
  Result.ReloadTicks := R.ReloadTicks;
  Result.ReloadNormTicks := R.ReloadNormTicks;
  Result.ReloadEnds := R.ReloadEnds;
  Result.ReloadDoneMille := R.ReloadDoneMille;
  Result.ReloadDeathMille := R.ReloadDeathMille;
  Result.ReloadTicksAll := R.ReloadTicksAll;
end;

{ the weapons whose shots are shots: the guns, the explosives and the throws of the knife; not
  the fuel of the chainsaw and the flamer, the fists, or the stationary gun main.pas cannot follow }
function ShotsCounted(W: LongInt): Boolean;
begin
  Result := CountsForAccuracy(W) or IsExplosiveWeapon(W) or (W = WEP_KNIFE);
end;

{ the shots of a weapon slot, '-' where they are no shots (ShotsCounted) }
function WeaponShotsText(S: LongInt; Shots: Int64): AnsiString;
begin
  if ShotsCounted(SlotWeapon(S)) then
    Result := Num(Shots)
  else
    Result := '-';
end;

{ the hit share of the shots, for the guns only (CountsForAccuracy): melee has no shots, and an
  explosion or a flame hurts several players or none }
function WeaponAccText(S: LongInt; Hits, Shots: Int64): AnsiString;
begin
  if CountsForAccuracy(SlotWeapon(S)) then
    Result := ShareOrDash(Hits, Shots)
  else
    Result := '-';
end;

{ the headshot share of the hits, for the weapons with hit zones (or with headshots counted) }
function WeaponHSText(S: LongInt; Heads, Hits: Int64): AnsiString;
begin
  if ZoneClassifiableStyle(SlotWeapon(S)) or (Heads > 0) then
    Result := ShareOrDash(Heads, Hits)
  else
    Result := '-';
end;

{ A / B with a unit, '-' when there is nothing to divide by }
function PerUnit(A, B: Double; Decimals: LongInt; const UnitText: AnsiString): AnsiString;
begin
  Result := RatioOrDash(A, B, Decimals);
  if Result <> '-' then
    Result := Result + UnitText;
end;

{ Reloading, for !wep (one account) and !serverwep (the whole server). "Manual" is a reload
  started with rounds in the magazine (the reload key), which throws those rounds away. The
  times are those of reloads that ran through; a roll, a grenade or a thrown gun makes one
  longer, which the time of weapons.ini (the standard) does not. }
procedure ReloadSection(E: TZSEngine; Slot, Wep: LongInt; const T: TWeaponTotals; W: LongInt);
var
  Progress, AtDeath: AnsiString;
begin
  if not ReloadTracked(Wep) then
    Exit;
  Section(E, Slot, 'Reloading', W);
  if T.Reloads + T.ReloadEnds = 0 then
  begin
    Out(E, Slot, 'No reloads counted yet.', WHITE);
    Exit;
  end;
  { how far the reloads that ended got, and the ones a death cut short }
  if T.ReloadEnds > 0 then
    Progress := FloatStr(T.ReloadDoneMille / T.ReloadEnds / 10, 0) + '%'
  else
    Progress := '-';
  if T.ReloadDeaths > 0 then
    AtDeath := FloatStr(T.ReloadDeathMille / T.ReloadDeaths / 10, 0) + '% of the reload done'
  else
    AtDeath := '-';
  Row(E, Slot, [Format('Reloads: %s (%s manual)', [Num(T.Reloads), Num(T.ReloadsManual)]),
    Format('Finished: %s, broken off: %s', [ShareOrDash(Min(T.ReloadsDone, T.Reloads), T.Reloads), Num(T.ReloadsCut)])],
    COLS2, CLR_SHOOTING);
  Row(E, Slot, [Format('Avg reload: %s (standard %s)', [MetricText(mfSec, SafeDivD(T.ReloadTicks, T.ReloadTimed) / TICKS_PER_SECOND),
      MetricText(mfSec, SafeDivD(T.ReloadNormTicks, T.ReloadTimed) / TICKS_PER_SECOND)]),
    'Avg progress of a reload: ' + Progress], COLS2, CLR_SHOOTING);
  Row(E, Slot, [Format('Killed reloading: %s (%s)', [Num(T.ReloadDeaths), ShareOrDash(T.ReloadDeaths, T.Reloads)]),
    'At death: ' + AtDeath], COLS2, WHITE);
  Row(E, Slot, ['Rounds thrown away: ' + Num(T.RoundsDropped),
    'Time reloading: ' + FormatDurationShort(T.ReloadTicksAll div TICKS_PER_SECOND)], COLS2, WHITE);
end;

{ the spawns with a weapon of the group of S: a primary, or a secondary (IsSecondarySlot) }
function GroupPicks(SV: PServerRecords; S: LongInt): Int64;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to WSLOT_COUNT - 1 do
    if IsSecondarySlot(k) = IsSecondarySlot(S) then
      Inc(Result, SV^.WeaponGlobal[k].Picks);
end;

{ the share of a weapon in the picks of its group, '-' for a weapon nobody spawns with; SV is the
  server record the weapon commands read (WeaponServer), taken once per list }
function PickShareText(SV: PServerRecords; S: LongInt): AnsiString;
begin
  if SV^.WeaponGlobal[S].Picks <= 0 then
    Result := '-'
  else
    Result := Pct(SV^.WeaponGlobal[S].Picks, GroupPicks(SV, S));
end;

{ the damage one kill takes against the damage one death takes: under 1, a kill costs less than
  a death (0 without kills or deaths) }
function DmgKDRatio(DmgOut: Double; Kills: Int64; DmgIn: Double; Deaths: Int64): Double;
begin
  Result := SafeDivD(SafeDivD(DmgOut, Kills), SafeDivD(DmgIn, Deaths));
end;

{ the two damage rows of one account: as kills and deaths, per kill and per death, and the two
  against each other; '-' where there is nothing to divide by }
procedure DamageRows(E: TZSEngine; Slot: LongInt; DmgOut, DmgIn: Double; Kills, Deaths: Int64; Color: LongInt);
var
  KDDmg: AnsiString;
begin
  if (Kills > 0) and (Deaths > 0) and (DmgIn > 0) then
    KDDmg := FloatStr(DmgKDRatio(DmgOut, Kills, DmgIn, Deaths), 2)
  else
    KDDmg := '-';
  Row(E, Slot, [Format('Dmg Out: %s (~%s kills)', [Dmg(DmgOut), KillEq(E, DmgOut)]),
    Format('Dmg In: %s (~%s deaths)', [Dmg(DmgIn), KillEq(E, DmgIn)]),
    'Dmg Ratio: ' + RatioOrDash(DmgOut, DmgIn, 2)], COLS3, Color);
  Row(E, Slot, ['Dmg/Kill: ' + PerUnit(DmgOut, Kills, 0, ' HP'), 'Dmg/Death: ' + PerUnit(DmgIn, Deaths, 0, ' HP'),
    'K-D Dmg: ' + KDDmg], COLS3, Color);
end;

function WeaponUsed(const T: TWeaponTotals): Boolean;
begin
  Result := (T.Kills + T.Deaths + T.Shots + T.Hits + T.Time + T.Picks > 0) or (T.Damage > 0);
end;

{ SV: the server record the weapon commands read (WeaponServer), taken once per list }
function WeaponMetricValue(E: TZSEngine; SV: PServerRecords; const T: TWeaponTotals; Id: LongInt): Double;
begin
  case Id of
    0: Result := T.Kills;
    1: Result := T.Deaths;
    2: Result := T.Kills / Max(Int64(1), T.Deaths);
    3: Result := T.Shots;
    4: Result := T.Hits;
    5: Result := Min(100.0, SafeDivD(T.Hits * 100.0, T.Shots));
    6: Result := T.Headshots;
    7: Result := Min(100.0, SafeDivD(T.Headshots * 100.0, T.Hits));
    8: Result := T.Damage;
    9: Result := T.DamageIn;
    10: Result := SafeDivD(T.Damage, T.DamageIn);
    11: Result := T.Time;
    12: Result := SafeDivD(SV^.WeaponGlobal[T.WSlot].KillDistSum, SV^.WeaponGlobal[T.WSlot].KillDistCount);
    13: Result := SafeDivD(SV^.WeaponGlobal[T.WSlot].TTKSumTicks, SV^.WeaponGlobal[T.WSlot].TTKCount) / TICKS_PER_SECOND;
    14: Result := T.Picks;
    15: Result := T.VestKills;
    16: Result := T.Longest;
    17: Result := SV^.WeaponGlobal[T.WSlot].PicksTeam[1];
    18: Result := SV^.WeaponGlobal[T.WSlot].PicksTeam[2];
    19: Result := T.Reloads;
    20: Result := SafeDivD(T.ReloadTicks, T.ReloadTimed) / TICKS_PER_SECOND;
    21: Result := Min(100.0, SafeDivD(T.ReloadsDone * 100.0, T.Reloads));
    22: Result := SafeDivD(T.ReloadDoneMille, T.ReloadEnds) / 10;
    23: Result := T.ReloadDeaths;
    24: Result := Min(100.0, SafeDivD(T.ReloadDeaths * 100.0, T.Reloads));
    25: Result := Min(100.0, SafeDivD(T.ReloadsManual * 100.0, T.Reloads));
    26: Result := T.RoundsDropped;
    27: Result := T.ReloadTicksAll div TICKS_PER_SECOND;
    28: Result := Min(100.0, SafeDivD(T.Picks * 100.0, GroupPicks(SV, T.WSlot)));
    29: Result := T.Damage / Max(1, E.EffectiveMaxHealth);
    30: Result := T.DamageIn / Max(1, E.EffectiveMaxHealth);
    31: Result := SafeDivD(T.Damage, T.Kills);
    32: Result := SafeDivD(T.DamageIn, T.Deaths);
    33: Result := DmgKDRatio(T.Damage, T.Kills, T.DamageIn, T.Deaths);
    else Result := 0;
  end;
end;

{ a metric that means nothing for a weapon - accuracy without shots of its own, headshots without
  hit zones, reloads of a weapon that has none, a share or a ratio of nothing - shows '-' and
  ranks last }
function WeaponMetricDefined(SV: PServerRecords; const T: TWeaponTotals; Id: LongInt): Boolean;
var
  W: LongInt;
begin
  W := SlotWeapon(T.WSlot);
  case Id of
    { the fuel of the chainsaw and the flamer, the fists and the stationary gun have no shots of
      their own (their hits stand in for them), as the tables show }
    3: Result := ShotsCounted(W);
    5: Result := CountsForAccuracy(W) and (T.Shots > 0);
    6: Result := ZoneClassifiableStyle(W) or (T.Headshots > 0);
    7: Result := (ZoneClassifiableStyle(W) or (T.Headshots > 0)) and (T.Hits > 0);
    10: Result := T.DamageIn > 0;
    12: Result := SV^.WeaponGlobal[T.WSlot].KillDistCount > 0;
    19, 23, 26, 27: Result := ReloadTracked(W);
    20: Result := T.ReloadTimed > 0;
    21, 24, 25: Result := ReloadTracked(W) and (T.Reloads > 0);
    22: Result := T.ReloadEnds > 0;
    28: Result := T.Picks > 0;
    31: Result := T.Kills > 0;
    32: Result := T.Deaths > 0;
    33: Result := (T.Kills > 0) and (T.Deaths > 0) and (T.DamageIn > 0);
    else Result := True;
  end;
end;

{ the text of a weapon metric in a column that holds MaxLen characters }
function WeaponMetricCell(E: TZSEngine; SV: PServerRecords; const T: TWeaponTotals; Id, MaxLen: LongInt): AnsiString;
begin
  if WeaponMetricDefined(SV, T, Id) then
    Result := Copy(MetricText(WEAPON_METRICS[Id].Fmt, WeaponMetricValue(E, SV, T, Id)), 1, MaxLen)
  else
    Result := '-';
end;

procedure TopWeaponsByHelp(E: TZSEngine; Slot: LongInt);
const
  W = LINE_W;
begin
  Header(E, Slot, 'ZitroStats Weapon Rankings - !topweapons / !topweaponsby Help', W);
  Out(E, Slot, 'Usage: !topweaponsby <metric1;metric2;...> [page]  (up to 5)', CLR_HINT);
  Out(E, Slot, '!topweapons [page] = !topweaponsby kills   !topweapons <weapon> [page] = the players with it', CLR_HINT);
  Out(E, Slot, 'Sorted by the first metric, ties broken by the next ones.', CLR_SUBHEADER);
  Rule(E, Slot, W);
  Out(E, Slot, '[Weapon Metrics]', CLR_HEADER);
  Out(E, Slot, '  kills, deaths, kd, shots, hits, acc, hs, hs%, dmg, dmgtaken, dmgratio, time', WHITE);
  Out(E, Slot, '  avgdist (average kill distance), ttk (average time to kill), vestkills, longest', WHITE);
  Out(E, Slot, '  picks, pick% (share of its group: the primaries, or socom/knife/saw/law)', WHITE);
  Out(E, Slot, '  killeq, deatheq (damage as kills / deaths), dmgperkill, dmgperdeath, kdmgratio', WHITE);
  Out(E, Slot, '  alphapicks, bravopicks (spawns with the weapon on that team)', WHITE);
  Out(E, Slot, '[Reload Metrics]', CLR_HEADER);
  Out(E, Slot, '  reloads, reloadtime (average), finished (% run through), progress (how far one gets)', WHITE);
  Out(E, Slot, '  rdeaths, rdeath% (killed reloading), manual (% with rounds left), dropped (rounds lost)', WHITE);
  Out(E, Slot, '  reloading (time spent reloading)', WHITE);
  Footer(E, Slot, W);
  Out(E, Slot, 'A value that means nothing for a weapon (the accuracy of a knife) is "-" and comes last.', CLR_HINT);
end;

const
  { the query /zs_next and the others page with for the players by one weapon: this mark and the
    weapon slot - a character nobody can type, so no metric of !topweaponsby is taken for it }
  WEAPON_PLAYERS_MARK = #1;

{ !topweapons <weapon> [page]: the players by one weapon, the most kills with it first (then the
  most damage), with what their accounts keep of it; '-' where the weapon has no such value }
procedure ListWeaponPlayers(E: TZSEngine; Slot, S, Page: LongInt);
const
  PER_PAGE = 15;
  { place, nick, kills, deaths, K/D, Acc%, HS%, damage and time: 84 of LINE_W, then the longest
    kill and the <YOU> of the caller's row }
  C: array[0..9] of LongInt = (5, 22, 8, 8, 8, 8, 7, 8, 10, 16);
var
  Entries: TRankEntryArray;
  Used: TIntArray;
  Kills, Deaths: array of Int64;
  Damage: array of Double;
  Rows: TIntArray;
  k, n, Pages, First, Last, Me, Idx: LongInt;
  P: PPlayerProfile;
  Tmp: TPlayerProfile;
  V: TWeaponView;
  KDText, TimeText, Longest: AnsiString;
  Mine: Boolean;
begin
  if (S < 0) or (S >= WSLOT_COUNT) then
    Exit;
  { the accounts of this server, and with SharedRankings of every server, that used the weapon (to
    have died by it only is no use of it) }
  Entries := RankingEntries(E);
  Used := nil;
  Kills := nil;
  Deaths := nil;
  Damage := nil;
  SetLength(Used, Length(Entries));
  SetLength(Kills, Length(Entries));
  SetLength(Deaths, Length(Entries));
  SetLength(Damage, Length(Entries));
  Tmp := Default(TPlayerProfile);
  n := 0;
  for k := 0 to High(Entries) do
  begin
    P := RankingView(E, Entries[k], Tmp);
    if P = nil then
      Continue;
    V := WeaponView(P^, S);
    if (V.Kills + V.Shots + V.Hits + V.Time > 0) or (V.Damage > 0) then
    begin
      Used[n] := k;
      Kills[n] := V.Kills;
      Deaths[n] := V.Deaths;
      Damage[n] := V.Damage;
      Inc(n);
    end;
  end;
  if n = 0 then
  begin
    Out(E, Slot, Format('Nobody has used the %s yet.', [SlotName(S)]), CLR_HEADER);
    Exit;
  end;
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
  begin
    SortKeys[k * 2] := Kills[k];
    SortKeys[k * 2 + 1] := Damage[k];
    SortTie[k] := -Deaths[k];
  end;
  Pages := PageCount(n, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Last := Min(n - 1, First + PER_PAGE - 1);
  Rows := BestRows(n, Last + 1);
  Me := ViewerIndex(E, Slot);
  Header(E, Slot, Format('Top Players with %s%s [Page %d/%d] (%d %s)', [SlotName(S), AllServers(E), Page, Pages, n,
    BoolToStr(n = 1, 'player', 'players')]), LINE_W);
  Row(E, Slot, ['#', 'Nick', 'Kills', 'Deaths', 'K/D', 'Acc%', 'HS%', 'Damage', 'Time', 'Longest'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    Idx := Entries[Used[Rows[k]]].Idx;
    P := RankingView(E, Entries[Used[Rows[k]]], Tmp);
    if P = nil then
      Continue;
    V := WeaponView(P^, S);
    Mine := (Idx >= 0) and (Idx = Me);
    { a ratio of nothing, a time never counted and a kill distance never measured are no numbers }
    if V.Kills + V.Deaths > 0 then
      KDText := KD(V.Kills, V.Deaths)
    else
      KDText := '-';
    if V.Time > 0 then
      TimeText := FormatDurationShort(V.Time)
    else
      TimeText := '-';
    if V.Longest > 0 then
      Longest := FloatStr(V.Longest, 1) + 'm'
    else
      Longest := '-';
    if Mine then
      Longest := Longest + ' <YOU>';
    Row(E, Slot, [IntToStr(k + 1), Copy(P^.ActiveName, 1, C[1] - 1), Num(V.Kills), Num(V.Deaths), KDText,
      WeaponAccText(S, V.Hits, V.Shots), WeaponHSText(S, V.Headshots, V.Hits), Dmg(V.Damage), TimeText, Longest], C,
      RowColor(k + 1, Mine));
  end;
  PageHint(E, Slot, Page, Pages, 'players');
  Remember(E, Slot, QK_TOPWEAPONS, WEAPON_PLAYERS_MARK + IntToStr(S), Page, Pages);
end;

procedure ListTopWeapons(E: TZSEngine; Slot: LongInt; const Query: AnsiString; Page: LongInt);
const
  PER_PAGE = 12;
  W = LINE_W;
  { one metric: place, weapon, the metric, share of all kills, Acc%, HS%, damage and time - at
    most 83 of LINE_W; over the whole server every kill with a weapon is somebody's death to it,
    so the share of the kills stands where a K/D would only be about 1 }
  C1: array[0..7] of LongInt = (5, 18, 14, 9, 9, 9, 10, 9);
var
  Tokens, Heads: TStringArray;
  Ids, Cand, Rows: TIntArray;
  Widths: array[0..4] of LongInt;
  Totals: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
  k, f, n, Pages, First, NameW, WS: LongInt;
  AllKills: Int64;
  Ignored, Canon, Title, Line: AnsiString;
  SV: PServerRecords;
  Show: array[0..7] of Boolean;

  { a row of the list by one metric, without the columns Show leaves out }
  procedure FixedCells(const Cells: array of AnsiString; Color: LongInt);
  var
    c, Kept: LongInt;
    KeepCells: array[0..7] of AnsiString;
    KeepW: array[0..7] of LongInt;
  begin
    Kept := 0;
    for c := 0 to Min(High(Cells), High(Show)) do
      if Show[c] then
      begin
        KeepCells[Kept] := Cells[c];
        KeepW[Kept] := C1[c];
        Inc(Kept);
      end;
    Row(E, Slot, Slice(KeepCells, Kept), Slice(KeepW, Kept), Color);
  end;

begin
  { a page of the players by one weapon (/zs_next and the others) }
  if (Query <> '') and (Query[1] = WEAPON_PLAYERS_MARK) then
  begin
    ListWeaponPlayers(E, Slot, StrToIntDef(Copy(Query, 2, MaxInt), -1), Page);
    Exit;
  end;
  Tokens := MetricTokens(Query, Page);
  Ids := nil;
  Ignored := '';
  Canon := '';
  for k := 0 to High(Tokens) do
  begin
    f := MetricIndex(WEAPON_METRICS, Tokens[k]);
    if f < 0 then
    begin
      if Ignored <> '' then
        Ignored := Ignored + ', ';
      Ignored := Ignored + Tokens[k];
    end
    else if Length(Ids) < 5 then
    begin
      SetLength(Ids, Length(Ids) + 1);
      Ids[High(Ids)] := f;
      if Canon <> '' then
        Canon := Canon + ';';
      Canon := Canon + Tokens[k];
    end;
  end;
  if Length(Ids) = 0 then
  begin
    Out(E, Slot, 'No valid weapon metric given.', CLR_BAD);
    if Ignored <> '' then
      Out(E, Slot, '[Note] Unknown: ' + Ignored, CLR_HINT);
    TopWeaponsByHelp(E, Slot);
    Exit;
  end;

  CollectWeaponTotals(E, Totals, E.Cfg.MySQLShareWeapons);
  SV := WeaponServer(E);
  AllKills := 0;
  for k := 0 to WSLOT_COUNT - 1 do
    Inc(AllKills, Totals[k].Kills);
  SetLength(Cand, WSLOT_COUNT);
  n := 0;
  for k := 0 to WSLOT_COUNT - 1 do
    if (k <= WEP_LAW) or WeaponUsed(Totals[k]) then
    begin
      Cand[n] := k;
      Inc(n);
    end;
  PrepareSort(n, Length(Ids));
  for k := 0 to n - 1 do
  begin
    for f := 0 to High(Ids) do
      if WeaponMetricDefined(SV, Totals[Cand[k]], Ids[f]) then
        SortKeys[k * SortCols + f] := SortValue(WeaponMetricValue(E, SV, Totals[Cand[k]], Ids[f]), WEAPON_METRICS[Ids[f]].Asc)
      else
        SortKeys[k * SortCols + f] := -MaxDouble;
    SortTie[k] := Totals[Cand[k]].Kills;
  end;
  Rows := OrderedRows(n);
  Pages := PageCount(n, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Heads := nil;
  SetLength(Heads, Length(Ids));
  for f := 0 to High(Ids) do
    Heads[f] := WEAPON_METRICS[Ids[f]].Header;
  Title := Format('%s [Page %d/%d]', [WeaponsAll(E), Page, Pages]);
  Header(E, Slot, 'Top Weapons by ' + MetricTitle(Heads, W - 4 - Length('Top Weapons by ' + Title)) + Title, W);
  if Length(Ids) = 1 then
  begin
    { the fixed columns leave out whatever the list is already sorted by: Acc% (metric 5), HS%
      (7), Damage (8) and Time (11) }
    for f := 0 to High(Show) do
      Show[f] := True;
    Show[4] := Ids[0] <> 5;
    Show[5] := Ids[0] <> 7;
    Show[6] := Ids[0] <> 8;
    Show[7] := Ids[0] <> 11;
    FixedCells(['#', 'Weapon', WEAPON_METRICS[Ids[0]].Header, 'Share', 'Acc%', 'HS%', 'Damage', 'Time'], CLR_SUBHEADER);
    Rule(E, Slot, W);
    for k := First to Min(n - 1, First + PER_PAGE - 1) do
    begin
      WS := Cand[Rows[k]];
      FixedCells([IntToStr(k + 1), Copy(SlotName(WS), 1, C1[1] - 1), WeaponMetricCell(E, SV, Totals[WS], Ids[0], C1[2] - 1),
        ShareOrDash(Totals[WS].Kills, AllKills), WeaponAccText(WS, Totals[WS].Hits, Totals[WS].Shots),
        WeaponHSText(WS, Totals[WS].Headshots, Totals[WS].Hits), Dmg(Totals[WS].Damage), FormatDurationShort(Totals[WS].Time)],
        RowColor(k + 1, False));
    end;
  end
  else
  begin
    ColumnWidths(Length(Ids), NameW, Widths);
    Line := PadR('#', 5) + PadR('Weapon', NameW);
    for f := 0 to High(Ids) do
      Line := Line + PadR(WEAPON_METRICS[Ids[f]].Header, Widths[f]);
    Out(E, Slot, TrimRight(Line), CLR_SUBHEADER);
    Rule(E, Slot, W);
    for k := First to Min(n - 1, First + PER_PAGE - 1) do
    begin
      WS := Cand[Rows[k]];
      Line := PadR(IntToStr(k + 1), 5) + PadR(Copy(SlotName(WS), 1, NameW - 1), NameW);
      for f := 0 to High(Ids) do
        Line := Line + PadR(WeaponMetricCell(E, SV, Totals[WS], Ids[f], Widths[f] - 1), Widths[f]);
      Out(E, Slot, TrimRight(Line), RowColor(k + 1, False));
    end;
  end;
  if Ignored <> '' then
    Out(E, Slot, '[Note] Ignored unknown metric(s): ' + Ignored, CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'weapons');
  Remember(E, Slot, QK_TOPWEAPONS, Canon, Page, Pages);
end;

{ !topweapons [page]: the weapons by their kills; !topweapons <weapon> [page]: the players with
  that weapon; a metric of the weapons (!topweapons acc) sorts them as !topweaponsby does. Only a
  real list counts toward the list limits. }
procedure CmdTopWeapons(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; Admin: Boolean);
var
  T: AnsiString;
  Tokens: TStringArray;
  W, Page, MetricPage, p: LongInt;
begin
  T := Trim(Rest);
  if (T = '') or AllDigits(T) then
  begin
    if HeavyAllowed(E, Slot, Admin) then
      ListTopWeapons(E, Slot, 'kills', Max(1, StrToIntDef(T, 1)));
    Exit;
  end;
  { a number after the weapon is the page, unless the name ends in it (ak 47, ruger 77, spas 12) }
  Page := 1;
  p := LastDelimiter(' ', T);
  if (p > 0) and AllDigits(Copy(T, p + 1, MaxInt)) and (ResolveWeaponExact(T) < 0) then
  begin
    Page := Max(1, StrToIntDef(Copy(T, p + 1, MaxInt), 1));
    T := Trim(Copy(T, 1, p - 1));
  end;
  W := ResolveWeapon(T);
  if W >= 0 then
  begin
    if HeavyAllowed(E, Slot, Admin) then
      ListWeaponPlayers(E, Slot, WepSlot(W), Page);
    Exit;
  end;
  MetricPage := 1;
  Tokens := MetricTokens(Rest, MetricPage);
  if (W <> -3) and (Length(Tokens) > 0) and (MetricIndex(WEAPON_METRICS, Tokens[0]) >= 0) then
  begin
    if HeavyAllowed(E, Slot, Admin) then
      ListTopWeapons(E, Slot, Rest, 1);
    Exit;
  end;
  Out(E, Slot, WeaponProblem(T, '!wep'), CLR_BAD);
  Out(E, Slot, 'Usage: !topweapons [page]   !topweapons <weapon> [page]   !topweaponsby <metric> [page]', CLR_HINT);
end;

{ one row of !allweapons }
procedure WeaponLine(E: TZSEngine; Slot, S: LongInt; const V: TWeaponView);
begin
  Row(E, Slot, [SlotName(S), Num(V.Kills), Num(V.Deaths), KD(V.Kills, V.Deaths), WeaponShotsText(S, V.Shots), Num(V.Hits),
    WeaponAccText(S, V.Hits, V.Shots), WeaponHSText(S, V.Headshots, V.Hits), Dmg(V.Damage), RatioOrDash(V.Damage, V.DamageIn, 2),
    FormatDurationShort(V.Time)], WEAPON_COLS, CLR_SHOOTING);
end;

{ knives, chainsaw, fists, grenades and explosives: one account (!allweapons) or the sum of
  all of them (!serverweapons) }
procedure MeleeSection(E: TZSEngine; Slot: LongInt; const P: TPlayerProfile; W: LongInt);
var
  Third: AnsiString;
begin
  Section(E, Slot, 'Melee, Throws & Combat Hurts', W);
  Row(E, Slot, ['Knife Throws: ' + Num(P.KnivesThrows), 'Knife Hits: ' + Num(P.KnivesThrowsHitsEnemy),
    'Knife Stabs: ' + Num(P.KnivesStabsEnemy)], COLS3, CLR_SHOOTING);
  Row(E, Slot, ['Saw Time: ' + FormatDurationShort(P.ChainsawTimeUsedSeconds), 'Saw Hurts: ' + Num(P.ChainsawHurtsEnemy),
    'Fist Hurts: ' + Num(P.HandsHurtsEnemy)], COLS3, CLR_SHOOTING);
  if P.ClusterNadesThrows > 0 then
    Third := Format('Clusters: %s/%s', [Num(P.ClusterNadesHurtsEnemy), Num(P.ClusterNadesThrows)])
  else if P.NadeHurtsFriendly > 0 then
    Third := 'TK Nades: ' + Num(P.NadeHurtsFriendly)
  else
    Third := 'Self Nades: ' + Num(P.NadeHurtsSelf);
  Row(E, Slot, ['Nade Throws: ' + Num(P.NadesThrows), 'Nade Hurts: ' + Num(P.NadeHurtsEnemy), Third], COLS3, CLR_SHOOTING);
  if P.M2MGHitsEnemy > 0 then
    Third := 'M2 MG Hits: ' + Num(P.M2MGHitsEnemy)
  else if P.M79HurtsFriendly + P.M72LAWHurtsFriendly > 0 then
    Third := 'TK Explo: ' + Num(Int64(P.M79HurtsFriendly) + P.M72LAWHurtsFriendly)
  else
    Third := 'Self Explo: ' + Num(Int64(P.M79HurtsSelf) + P.M72LAWHurtsSelf);
  Row(E, Slot, [Format('M79: %ss / %sh', [Num(P.M79Shots), Num(P.M79HurtsEnemy)]),
    Format('LAW: %ss / %sh', [Num(P.M72LAWShots), Num(P.M72LAWHurtsEnemy)]), Third], COLS3, CLR_SHOOTING);
  { the flamer is a bonus and the bow Rambomatch's: in that mode, or with counters of them }
  if (P.FlamethrowerHitsEnemy > 0) or (P.BowFlamedArrowsHurtsEnemy > 0) or (P.RamboMode.KillsByBow > 0) or (E.Match.GameStyle = GS_RM) then
    Row(E, Slot, ['Flamer Hurts: ' + Num(P.FlamethrowerHitsEnemy), 'Flame Arrow: ' + Num(P.BowFlamedArrowsHurtsEnemy),
      'Bow Kills: ' + Num(P.RamboMode.KillsByBow)], COLS3, CLR_SHOOTING);
end;

procedure CmdAllWeapons(E: TZSEngine; Slot, Idx: LongInt);
const
  W = LINE_W;
var
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
  S: LongInt;
  V: TWeaponView;
  Special: Boolean;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  Header(E, Slot, 'All Weapons Breakdown: ' + P^.ActiveName, W);
  Row(E, Slot, ['Weapon', 'Kills', 'Deaths', 'K/D', 'Shots', 'Hits', 'Acc%', 'HS%', 'DmgOut', 'DmgR', 'Time'], WEAPON_COLS,
    CLR_SUBHEADER);
  Rule(E, Slot, W);
  for S := 0 to WEP_LAW do
    WeaponLine(E, Slot, S, WeaponView(P^, S));
  Special := False;
  for S := WEP_LAW + 1 to WSLOT_COUNT - 1 do
  begin
    V := WeaponView(P^, S);
    if (V.Kills + V.Deaths + V.Shots + V.Hits + V.Time > 0) or (V.Damage > 0) or
       (((S = WEP_BOW) or (S = WEP_BOW2)) and (E.Match.GameStyle = GS_RM)) then
    begin
      if not Special then
      begin
        Section(E, Slot, 'Bonus, Special & Thrown Weapons', W);
        Special := True;
      end;
      WeaponLine(E, Slot, S, V);
    end;
  end;

  Section(E, Slot, 'Damage & Combat Telemetry', W);
  Row(E, Slot, [Format('Dmg Dealt: %s (~%s kills)', [Dmg(P^.DamageDealt), KillEq(E, P^.DamageDealt)]),
    Format('Dmg Taken: %s (~%s deaths)', [Dmg(P^.DamageReceived), KillEq(E, P^.DamageReceived)]),
    'Dmg Ratio: ' + RatioOrDash(P^.DamageDealt, P^.DamageReceived, 2)], COLS3, CLR_SHOOTING);
  if (E.Match.FriendlyFire and ((P^.DamageFriendly > 0) or (P^.DamageFriendlyReceived > 0))) or (P^.Teamkills > 0) or
     (P^.DeathsByFriendly > 0) then
    Row(E, Slot, ['TK Dmg Out: ' + Dmg(P^.DamageFriendly), 'TK Dmg In: ' + Dmg(P^.DamageFriendlyReceived),
      Format('TK Kills/Deaths: %s/%s', [Num(P^.Teamkills), Num(P^.DeathsByFriendly)])], COLS3, CLR_TEAMPLAY);

  MeleeSection(E, Slot, P^, W);
  Out(E, Slot, 'Use !wep <name> (e.g. !wep ak, !wep barrett, !wep knife) for details.', CLR_HINT);
  Footer(E, Slot, W);
end;

{ what the whole server knows about one weapon: used by !wep and by !serverwep }
procedure WeaponGlobalSection(E: TZSEngine; Slot, S, W: LongInt);
const
  { the kill distances: the name and five ranges, each range with its share and a bar under it }
  DIST_NAME_W = 16;
  DIST_COL_W = 16;
  DIST_BAR = 12;
var
  G: TWeaponGlobal;
  SV: PServerRecords;
  k, Nem, Vic: LongInt;
  NemCount, VicCount: LongInt;
  Total, TeamPicks: Int64;
  Line: AnsiString;
  Cells: TStringArray;
begin
  SV := WeaponServer(E);
  G := SV^.WeaponGlobal[S];
  Section(E, Slot, 'Server-wide for this weapon', W);
  Total := G.DistBucket[0] + G.DistBucket[1] + G.DistBucket[2] + G.DistBucket[3] + G.DistBucket[4];
  if Total > 0 then
  begin
    { a row of numbers is hard to read: the shares get their own columns under their names,
      with a bar under them so the shape is visible at a glance }
    Line := PadR('Kill distance', DIST_NAME_W);
    for k := 0 to 4 do
      Line := Line + PadR(DIST_BUCKET_NAMES[k], DIST_COL_W);
    Out(E, Slot, TrimRight(Line), CLR_SUBHEADER);
    Line := PadR('', DIST_NAME_W);
    for k := 0 to 4 do
      Line := Line + PadR(Pct(G.DistBucket[k], Total), DIST_COL_W);
    Out(E, Slot, TrimRight(Line), WHITE);
    { a range with kills gets one sign at least }
    Line := PadR('', DIST_NAME_W);
    for k := 0 to 4 do
      if G.DistBucket[k] > 0 then
        Line := Line + PadR(StringOfChar('#', Max(Int64(1), Round(G.DistBucket[k] * DIST_BAR / Total))), DIST_COL_W)
      else
        Line := Line + PadR('', DIST_COL_W);
    Out(E, Slot, TrimRight(Line), CLR_OTHER_ROW);
  end;
  Cells := nil;
  if G.KillDistCount > 0 then
    PushCell(Cells, 'Avg Kill Dist: ' + FloatStr(G.KillDistSum / G.KillDistCount, 1) + 'm')
  else
    PushCell(Cells, 'Avg Kill Dist: -');
  PushCell(Cells, 'Avg TTK: ' + MetricText(mfSec, SafeDivD(G.TTKSumTicks, G.TTKCount) / TICKS_PER_SECOND));
  { the vest is a bonus: a server without bonuses has no vest kills }
  if G.VestKills > 0 then
    PushCell(Cells, 'Vest kills: ' + Num(G.VestKills));
  { the weapon that killed this one most and the one it killed most; itself is left out like in
    !matchup (the weapon against itself would fill both) }
  NemCount := 0;
  VicCount := 0;
  Nem := -1;
  Vic := -1;
  for k := 0 to WSLOT_COUNT - 1 do
  begin
    if k = S then
      Continue;
    if SV^.Matchups[k, S] > NemCount then
    begin
      NemCount := SV^.Matchups[k, S];
      Nem := k;
    end;
    if SV^.Matchups[S, k] > VicCount then
    begin
      VicCount := SV^.Matchups[S, k];
      Vic := k;
    end;
  end;
  if Nem >= 0 then
    PushCell(Cells, Format('Nemesis: %s (%s)', [SlotShortName(Nem), Num(NemCount)]));
  if Vic >= 0 then
    PushCell(Cells, Format('Top Victim: %s (%s)', [SlotShortName(Vic), Num(VicCount)]));
  { spawns with this weapon: the weapons of Soldat's menu (or any that has picks), with the share
    among the weapons of its group - everybody spawns with a secondary as well, so the two are
    counted apart }
  if (S <= WEP_LAW) or (G.Picks > 0) then
  begin
    PushCell(Cells, 'Picks: ' + Num(G.Picks));
    if IsSecondarySlot(S) then
      PushCell(Cells, 'Of secondaries: ' + PickShareText(SV, S))
    else
      PushCell(Cells, 'Of primaries: ' + PickShareText(SV, S));
  end;
  { and the split by the team of the player, in the team modes }
  TeamPicks := G.PicksTeam[1] + G.PicksTeam[2] + G.PicksTeam[3] + G.PicksTeam[4];
  if E.TeamGame and (TeamPicks > 0) then
  begin
    PushCell(Cells, Format('Alpha picks: %s (%s)', [Num(G.PicksTeam[1]), Pct(G.PicksTeam[1], TeamPicks)]));
    PushCell(Cells, Format('Bravo picks: %s (%s)', [Num(G.PicksTeam[2]), Pct(G.PicksTeam[2], TeamPicks)]));
    if G.PicksTeam[3] + G.PicksTeam[4] > 0 then
      PushCell(Cells, Format('Charlie/Delta picks: %s/%s', [Num(G.PicksTeam[3]), Num(G.PicksTeam[4])]));
  end;
  FlowCells(E, Slot, Cells, 3, WHITE);
end;

{ the weapon names, for !wep help and !serverwep help }
procedure WeaponHelp(E: TZSEngine; Slot: LongInt; const Title, Usage, Example: AnsiString);
const
  W = LINE_W;
begin
  Header(E, Slot, Title, W);
  Out(E, Slot, Usage, CLR_HINT);
  Out(E, Slot, Example, CLR_HINT);
  Out(E, Slot, 'Pistol:  socom(0), deagles(1)', CLR_SHOOTING);
  Out(E, Slot, 'Primary: mp5(2), ak(3), aug(4), spas(5), ruger(6)', CLR_SHOOTING);
  Out(E, Slot, 'Heavy:   m79(7), barrett(8), minimi(9), minigun(10)', CLR_SHOOTING);
  Out(E, Slot, 'Special: knife(11), saw(12), law(13), flamer(14), bow(15), arrows(16)', CLR_SHOOTING);
  Out(E, Slot, 'Other:   statgun(30), grenade(50), cluster(51), fists(255)', CLR_SHOOTING);
  Out(E, Slot, 'A beginning or a part of a name is enough (barr, sni, mini), a typo too.', CLR_HINT);
  Footer(E, Slot, W);
end;

{ One row of the server table, big numbers shortened. Over the whole server every kill with a
  weapon is somebody's death to it, so deaths, K/D and the damage taken say nothing here: the
  share of all kills and how often the weapon is picked do - among the primaries, or among the
  secondaries, which everybody spawns with as well. }
procedure WeaponTotalsLine(E: TZSEngine; Slot: LongInt; SV: PServerRecords; const T: TWeaponTotals; AllKills: Int64);
begin
  Row(E, Slot, [SlotName(T.WSlot), Num(T.Kills), ShareOrDash(T.Kills, AllKills), PickShareText(SV, T.WSlot),
    WeaponShotsText(T.WSlot, T.Shots), Num(T.Hits), WeaponAccText(T.WSlot, T.Hits, T.Shots),
    WeaponHSText(T.WSlot, T.Headshots, T.Hits), Dmg(T.Damage), FormatDurationShort(T.Time)], SERVER_WEAPON_COLS, CLR_SHOOTING);
end;

{ the best account with one weapon: most kills, and the best accuracy of those who shot enough }
procedure WeaponBestPlayers(E: TZSEngine; S: LongInt; out KillName, AccName: AnsiString;
  out KillCount: Int64; out AccValue: Double; out Users: LongInt);
const
  MIN_SHOTS = 200;
var
  k: LongInt;
  V: TWeaponView;
  Acc: Double;
  Entries: TRankEntryArray;
  P: PPlayerProfile;
  Tmp: TPlayerProfile;
begin
  KillName := '';
  AccName := '';
  KillCount := 0;
  AccValue := 0;
  Users := 0;
  { the accounts of the rankings: with SharedRankings those of every server }
  Entries := RankingEntries(E);
  for k := 0 to High(Entries) do
  begin
    P := RankingView(E, Entries[k], Tmp);
    if P <> nil then
    begin
      V := WeaponView(P^, S);
      if V.Kills + V.Shots + V.Hits = 0 then
        Continue;
      Inc(Users);
      if V.Kills > KillCount then
      begin
        KillCount := V.Kills;
        KillName := P^.ActiveName;
      end;
      if V.Shots >= MIN_SHOTS then
      begin
        Acc := SafeDivD(V.Hits * 100.0, V.Shots);
        if Acc > AccValue then
        begin
          AccValue := Acc;
          AccName := P^.ActiveName;
        end;
      end;
    end;
  end;
end;

{ !serverweapons: the same breakdown as !allweapons, counted over every account }
procedure CmdServerWeapons(E: TZSEngine; Slot: LongInt);
const
  W = LINE_W;
var
  Totals: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
  Picks: array[0..WSLOT_COUNT - 1] of Int64;
  S, k, BestKill: LongInt;
  Special: Boolean;
  AllKills: Int64;
  AllDmg: Double;
  Sum, Others: TPlayerProfile;
  SV: PServerRecords;
  Cells: TStringArray;
begin
  CollectWeaponTotals(E, Totals, E.Cfg.MySQLShareWeapons);
  SV := WeaponServer(E);
  AllKills := 0;
  for S := 0 to WSLOT_COUNT - 1 do
    Inc(AllKills, Totals[S].Kills);
  if WeaponsAll(E) <> '' then
    Header(E, Slot, 'All Weapons Breakdown: all servers', W)
  else
    Header(E, Slot, 'All Weapons Breakdown: the whole server', W);
  Row(E, Slot, ['Weapon', 'Kills', 'Share', 'Pick%', 'Shots', 'Hits', 'Acc%', 'HS%', 'DmgOut', 'Time'], SERVER_WEAPON_COLS,
    CLR_SUBHEADER);
  Rule(E, Slot, W);
  for S := 0 to WEP_LAW do
    WeaponTotalsLine(E, Slot, SV, Totals[S], AllKills);
  Special := False;
  for S := WEP_LAW + 1 to WSLOT_COUNT - 1 do
    if WeaponUsed(Totals[S]) then
    begin
      if not Special then
      begin
        Section(E, Slot, 'Bonus, Special & Thrown Weapons', W);
        Special := True;
      end;
      WeaponTotalsLine(E, Slot, SV, Totals[S], AllKills);
    end;

  AllDmg := 0;
  BestKill := 0;
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    AllDmg := AllDmg + Totals[S].Damage;
    if Totals[S].Kills > Totals[BestKill].Kills then
      BestKill := S;
    Picks[S] := Totals[S].Picks;
  end;
  { the counters of every account added up, for the same sections as !allweapons; with
    SharedWeapons those of the other servers as well }
  ClearProfile(Sum);
  for k := 0 to E.DB.ProfileCount - 1 do
    if E.DB.Valid(k) then
      SumProfileCounters(Sum, E.DB.Profiles[k]^);
  if SharedAccountSums(E, E.Cfg.MySQLShareWeapons, Others) then
    SumProfileCounters(Sum, Others);
  Section(E, Slot, 'Server totals', W);
  { the shots, hits and headshots of the guns, as in !stats and !server (CountsForAccuracy); the
    damage taken and the deaths would only repeat the damage dealt and the kills }
  Cells := nil;
  PushCell(Cells, 'Kills: ' + Num(AllKills));
  PushCell(Cells, 'Shots: ' + Num(Max(Int64(Sum.Shots), Int64(Sum.ShotsHits))));
  PushCell(Cells, Format('Hits: %s (%s)', [Num(Sum.ShotsHits), ShareOrDash(Sum.ShotsHits, Max(Int64(Sum.Shots), Int64(Sum.ShotsHits)))]));
  PushCell(Cells, 'Headshots: ' + Num(Sum.ShotsHitsHead));
  PushCell(Cells, 'HS%: ' + ShareOrDash(Sum.ShotsHitsHead, Sum.ShotsHits));
  PushCell(Cells, Format('Damage: %s (~%s kills)', [Dmg(AllDmg), KillEq(E, AllDmg)]));
  PushCell(Cells, 'Dmg/Kill: ' + PerUnit(AllDmg, AllKills, 0, ' HP'));
  if Totals[BestKill].Kills > 0 then
    PushCell(Cells, 'Most kills: ' + SlotShortName(BestKill))
  else
    PushCell(Cells, 'Most kills: -');
  { everybody spawns with a secondary as well (the Socom unless another is chosen), so the most
    picked weapon is named for each group }
  PushCell(Cells, TopPickText('Top primary', Picks, False, True));
  PushCell(Cells, TopPickText('Top secondary', Picks, True, True));
  { teamkills: in the team modes, or when the accounts have some from them }
  if E.TeamGame or (Sum.Teamkills > 0) or (Sum.DamageFriendly > 0) then
  begin
    PushCell(Cells, 'TK Kills: ' + Num(Sum.Teamkills));
    PushCell(Cells, 'TK Dmg: ' + Dmg(Sum.DamageFriendly));
  end;
  PushCell(Cells, 'Accounts: ' + Num(E.DB.LiveProfiles));
  FlowCells(E, Slot, Cells, 3, WHITE);
  MeleeSection(E, Slot, Sum, W);
  Out(E, Slot, 'Use !serverwep <name> for one weapon, !allweapons for your own.', CLR_HINT);
  Footer(E, Slot, W);
end;

{ !serverwep <weapon>: the deep dive of !wep, counted over every account }
procedure CmdServerWeapon(E: TZSEngine; Slot: LongInt; const Rest: AnsiString);
const
  W = LINE_W;
var
  Totals: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
  Wep, S, Users, k: LongInt;
  T: TWeaponTotals;
  KillName, AccName: AnsiString;
  KillCount, AllKills: Int64;
  AccValue: Double;
  Cells: TStringArray;
begin
  if (Trim(Rest) = '') or SameText(Trim(Rest), 'help') then
  begin
    WeaponHelp(E, Slot, 'Server Weapon Lookup', 'Usage: !serverwep <weapon>', 'e.g. !serverwep ak   !serverwep m79   !serverwep 8');
    Exit;
  end;
  S := WeaponSlotOrSay(E, Slot, Rest, '!serverwep');
  if S < 0 then
    Exit;
  Wep := SlotWeapon(S);
  CollectWeaponTotals(E, Totals, E.Cfg.MySQLShareWeapons);
  T := Totals[S];
  AllKills := 0;
  for k := 0 to WSLOT_COUNT - 1 do
    Inc(AllKills, Totals[k].Kills);
  WeaponBestPlayers(E, S, KillName, AccName, KillCount, AccValue, Users);

  { every kill with this weapon is somebody's death to it, and the damage taken from it is the
    damage dealt with it: over the whole server the share of all kills says how much it is used,
    deaths, K/D and the damage taken would only repeat the other side }
  if WeaponsAll(E) <> '' then
    Header(E, Slot, 'Weapon: ' + SlotName(S) + ' - all servers', W)
  else
    Header(E, Slot, 'Weapon: ' + SlotName(S) + ' - the whole server', W);
  Row(E, Slot, ['Kills: ' + Num(T.Kills), 'Share: ' + ShareOrDash(T.Kills, AllKills) + ' of kills',
    'Accounts: ' + Num(Users)], COLS3, CLR_SHOOTING);
  Row(E, Slot, [Format('Dmg Out: %s (~%s kills)', [Dmg(T.Damage), KillEq(E, T.Damage)]),
    'Dmg/Kill: ' + PerUnit(T.Damage, T.Kills, 0, ' HP'), 'Dmg/Hit: ' + PerUnit(T.Damage, T.Hits, 1, ' HP')], COLS3, CLR_SHOOTING);
  Cells := nil;
  PushCell(Cells, 'Shots: ' + WeaponShotsText(S, T.Shots));
  if CountsForAccuracy(Wep) then
    PushCell(Cells, Format('Hits: %s (%s)', [Num(T.Hits), ShareOrDash(T.Hits, T.Shots)]))
  else
    PushCell(Cells, 'Hits: ' + Num(T.Hits));
  PushCell(Cells, 'Time: ' + FormatDurationShort(T.Time));
  { only bullets, pellets, arrows and the stationary gun have hit zones }
  if ZoneClassifiableStyle(Wep) or (T.Headshots > 0) then
    PushCell(Cells, Format('Headshots: %s (%s)', [Num(T.Headshots), ShareOrDash(T.Headshots, T.Hits)]));
  PushCell(Cells, 'Hits/Kill: ' + RatioOrDash(T.Hits, T.Kills, 2));
  if T.Longest > 0 then
    PushCell(Cells, 'Longest: ' + FloatStr(T.Longest, 1) + 'm')
  else
    PushCell(Cells, 'Longest: -');
  FlowCells(E, Slot, Cells, 3, CLR_SHOOTING);
  if KillName <> '' then
    Out(E, Slot, Format('Top killer: %s (%s)', [KillName, Num(KillCount)]), CLR_TOP1);
  if (AccName <> '') and CountsForAccuracy(Wep) then
    Out(E, Slot, Format('Best accuracy (200+ shots): %s (%s)', [AccName, FloatStr(AccValue, 1) + '%']), CLR_TOP2);
  Out(E, Slot, 'Sweet Spot: ' + WeaponSweetSpot(Wep), WHITE);
  ReloadSection(E, Slot, Wep, T, W);
  WeaponGlobalSection(E, Slot, S, W);
  Out(E, Slot, 'Use !wep ' + LowerCase(SlotShortName(S)) + ' for your own numbers.', CLR_HINT);
  Footer(E, Slot, W);
end;

{ ---------------- the weapon tables by metrics: !allweaponsby, !serverweaponsby ---------------- }

type
  { the columns of the plain weapon tables (!allweapons, !serverweapons) }
  TWeaponCol = (wcKills, wcDeaths, wcKD, wcShots, wcHits, wcAcc, wcHS, wcDmg, wcDmgRatio, wcTime, wcShare, wcPickShare);

const
  WCOL_HEADERS: array[TWeaponCol] of AnsiString = ('Kills', 'Deaths', 'K/D', 'Shots', 'Hits', 'Acc%', 'HS%', 'DmgOut',
    'DmgR', 'Time', 'Share', 'Pick%');
  { the weapon metric a column shows, -1 for none (the share of all kills) }
  WCOL_METRICS: array[TWeaponCol] of LongInt = (0, 1, 2, 3, 4, 5, 7, 8, 10, 11, -1, 28);
  { the columns of !allweapons and of !serverweapons, in their order }
  PLAYER_WCOLS: array[0..9] of TWeaponCol = (wcKills, wcDeaths, wcKD, wcShots, wcHits, wcAcc, wcHS, wcDmg, wcDmgRatio,
    wcTime);
  SERVER_WCOLS: array[0..8] of TWeaponCol = (wcKills, wcShare, wcPickShare, wcShots, wcHits, wcAcc, wcHS, wcDmg, wcTime);

{ the metrics of the server record - kill distances, times to kill, picks and vest kills: an account
  has no such values of its own }
function ServerOnlyWeaponMetric(Id: LongInt): Boolean;
begin
  case Id of
    12, 13, 14, 15, 17, 18, 28: Result := True;
    else Result := False;
  end;
end;

{ one weapon of one account in the shape of the server totals, for the weapon metrics }
function PlayerWeaponTotals(const P: TPlayerProfile; S: LongInt): TWeaponTotals;
var
  V: TWeaponView;
begin
  Result := ReloadTotalsOf(P.Weapons[S]);
  V := WeaponView(P, S);
  Result.WSlot := S;
  Result.Kills := V.Kills;
  Result.Deaths := V.Deaths;
  Result.Shots := V.Shots;
  Result.Hits := V.Hits;
  Result.Headshots := V.Headshots;
  Result.Time := V.Time;
  Result.Damage := V.Damage;
  Result.DamageIn := V.DamageIn;
  Result.Longest := V.Longest;
end;

{ a cell of the plain weapon tables, as WeaponLine and WeaponTotalsLine write it }
function WeaponColCell(SV: PServerRecords; const T: TWeaponTotals; C: TWeaponCol; AllKills: Int64): AnsiString;
begin
  case C of
    wcKills: Result := Num(T.Kills);
    wcDeaths: Result := Num(T.Deaths);
    wcKD: Result := KD(T.Kills, T.Deaths);
    wcShots: Result := WeaponShotsText(T.WSlot, T.Shots);
    wcHits: Result := Num(T.Hits);
    wcAcc: Result := WeaponAccText(T.WSlot, T.Hits, T.Shots);
    wcHS: Result := WeaponHSText(T.WSlot, T.Headshots, T.Hits);
    wcDmg: Result := Dmg(T.Damage);
    wcDmgRatio: Result := RatioOrDash(T.Damage, T.DamageIn, 2);
    wcTime: Result := FormatDurationShort(T.Time);
    wcShare: Result := ShareOrDash(T.Kills, AllKills);
    else Result := PickShareText(SV, T.WSlot);
  end;
end;

{ "<metrics> [rest]" of !allweaponsby: the metrics are the first word, more of them joined by ";" or
  "," (spaces next to those do not end them); Rest is what follows - a player, or a ranking position }
procedure SplitMetricsWord(const Text: AnsiString; out Metrics, Rest: AnsiString);
var
  S: AnsiString;
  i, j: LongInt;
begin
  S := Trim(Text);
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = ' ' then
    begin
      j := i;
      while (j <= Length(S)) and (S[j] = ' ') do
        Inc(j);
      if not (((i > 1) and (S[i - 1] in [',', ';'])) or ((j <= Length(S)) and (S[j] in [',', ';']))) then
        Break;
      i := j;
      Continue;
    end;
    Inc(i);
  end;
  Metrics := Copy(S, 1, i - 1);
  Rest := Trim(Copy(S, i, MaxInt));
end;

{ the weapon metrics of a text, separated by space, comma or semicolon, each once and up to five as
  !topweaponsby takes them; Unknown gets the words that are none, and with PlayerView ServerOnly the
  metrics an account does not have (ServerOnlyWeaponMetric) }
function WeaponMetricIds(const Text: AnsiString; PlayerView: Boolean; out Unknown, ServerOnly: AnsiString): TIntArray;
var
  k, f, j: LongInt;
  Cur: AnsiString;
  Seen: Boolean;
begin
  Result := nil;
  Unknown := '';
  ServerOnly := '';
  Cur := '';
  for k := 1 to Length(Text) + 1 do
    if (k > Length(Text)) or (Text[k] in [' ', ',', ';', #9]) then
    begin
      if Cur = '' then
        Continue;
      f := MetricIndex(WEAPON_METRICS, Cur);
      if f < 0 then
      begin
        if Unknown <> '' then
          Unknown := Unknown + ', ';
        Unknown := Unknown + Cur;
      end
      else if PlayerView and ServerOnlyWeaponMetric(f) then
      begin
        if ServerOnly <> '' then
          ServerOnly := ServerOnly + ', ';
        ServerOnly := ServerOnly + Cur;
      end
      else if Length(Result) < 5 then
      begin
        Seen := False;
        for j := 0 to High(Result) do
          if Result[j] = f then
            Seen := True;
        if not Seen then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := f;
        end;
      end;
      Cur := '';
    end
    else
      Cur := Cur + LowerCase(Text[k]);
end;

{ a text that names at least one weapon metric (of the server with not PlayerView) }
function HasWeaponMetric(const Text: AnsiString; PlayerView: Boolean): Boolean;
var
  Unknown, ServerOnly: AnsiString;
begin
  Result := Length(WeaponMetricIds(Text, PlayerView, Unknown, ServerOnly)) > 0;
end;

{ !allweaponsby help and !serverweaponsby help: the metrics each of them takes }
procedure WeaponsByHelp(E: TZSEngine; Slot: LongInt; Server: Boolean);
begin
  if Server then
  begin
    Header(E, Slot, 'ZitroStats Weapons by Metrics - !serverweaponsby Help', LINE_W);
    Out(E, Slot, 'Usage: !serverweaponsby <metric1;metric2;...>  (up to 5)', CLR_HINT);
    Out(E, Slot, 'The weapon table of !serverweapons, every account added up, sorted by the metrics.', CLR_HINT);
  end
  else
  begin
    Header(E, Slot, 'ZitroStats Weapons by Metrics - !allweaponsby Help', LINE_W);
    Out(E, Slot, 'Usage: !allweaponsby <metric1;metric2;...> [player]   !allweaponsbyi <metrics> <ranking position>',
      CLR_HINT);
    Out(E, Slot, 'The weapon table of !allweapons, sorted by the metrics (up to 5).', CLR_HINT);
  end;
  Out(E, Slot, 'Best first by the first metric, ties broken by the next ones.', CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  Out(E, Slot, '[Weapon Metrics]', CLR_HEADER);
  Out(E, Slot, '  kills, deaths, kd, shots, hits, acc, hs, hs%, dmg, dmgtaken, dmgratio, time, longest', WHITE);
  Out(E, Slot, '  killeq, deatheq (damage as kills / deaths), dmgperkill, dmgperdeath, kdmgratio', WHITE);
  if Server then
  begin
    Out(E, Slot, '  avgdist (average kill distance), ttk (average time to kill), vestkills', WHITE);
    Out(E, Slot, '  picks, pick% (share of its group: the primaries, or socom/knife/saw/law)', WHITE);
    Out(E, Slot, '  alphapicks, bravopicks (spawns with the weapon on that team)', WHITE);
  end;
  Out(E, Slot, '[Reload Metrics]', CLR_HEADER);
  Out(E, Slot, '  reloads, reloadtime (average), finished (% run through), progress (how far one gets)', WHITE);
  Out(E, Slot, '  rdeaths, rdeath% (killed reloading), manual (% with rounds left), dropped (rounds lost)', WHITE);
  Out(E, Slot, '  reloading (time spent reloading)', WHITE);
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'A value that means nothing for a weapon (the accuracy of a knife) is "-" and comes last.', CLR_HINT);
  if not Server then
    Out(E, Slot, 'Kill distances, times to kill, picks and vest kills are the whole server''s: !serverweaponsby.',
      CLR_HINT);
end;

{ the metrics a weapon table by metrics left out, and why }
procedure WeaponsByNotes(E: TZSEngine; Slot: LongInt; const Unknown, ServerOnly: AnsiString);
begin
  if Unknown <> '' then
    Out(E, Slot, '[Note] Ignored unknown metric(s): ' + Unknown, CLR_HINT);
  if ServerOnly <> '' then
    Out(E, Slot, '[Note] Counted for the whole server only (!serverweaponsby): ' + ServerOnly, CLR_HINT);
end;

{ A weapon table sorted by metrics: the weapons of the plain table (Shown), best first by the first
  metric and ties by the next ones, then by the kills, a value that means nothing for a weapon ("-")
  last. The columns are the weapon, the metrics in their order, then the columns of the plain table
  (Std) that are no metric of the list. Every column is as wide as its longest cell and two spaces,
  so no cell ever pushes the ones after it; the columns of the plain table that do not fit LINE_W
  are left out, from the end (one space between the columns only if the metrics alone need it). }
procedure WeaponsByTable(E: TZSEngine; Slot: LongInt; const TitleStart, TitleEnd: AnsiString;
  const Totals: array of TWeaponTotals; const Shown, Ids: TIntArray; SV: PServerRecords; const Std: array of TWeaponCol;
  AllKills: Int64);
var
  Rows, Widths, Padded: TIntArray;
  Heads, Line: TStringArray;
  Cells: array of TStringArray;
  StdCols: array of TWeaponCol;
  n, k, c, f, Cols, Gap, Total: LongInt;
  T: TWeaponTotals;
  Metric: Boolean;
begin
  n := Length(Shown);
  PrepareSort(n, Length(Ids));
  for k := 0 to n - 1 do
  begin
    for f := 0 to High(Ids) do
      if WeaponMetricDefined(SV, Totals[Shown[k]], Ids[f]) then
        SortKeys[k * SortCols + f] := SortValue(WeaponMetricValue(E, SV, Totals[Shown[k]], Ids[f]), WEAPON_METRICS[Ids[f]].Asc)
      else
        SortKeys[k * SortCols + f] := -MaxDouble;
    SortTie[k] := Totals[Shown[k]].Kills;
  end;
  Rows := OrderedRows(n);
  { the columns of the plain table that are no metric of the list }
  StdCols := nil;
  for c := 0 to High(Std) do
  begin
    Metric := False;
    for f := 0 to High(Ids) do
      if WCOL_METRICS[Std[c]] = Ids[f] then
        Metric := True;
    if not Metric then
    begin
      SetLength(StdCols, Length(StdCols) + 1);
      StdCols[High(StdCols)] := Std[c];
    end;
  end;
  Cols := 1 + Length(Ids) + Length(StdCols);
  Heads := nil;
  SetLength(Heads, Cols);
  Heads[0] := 'Weapon';
  for f := 0 to High(Ids) do
    Heads[1 + f] := WEAPON_METRICS[Ids[f]].Header;
  for c := 0 to High(StdCols) do
    Heads[1 + Length(Ids) + c] := WCOL_HEADERS[StdCols[c]];
  Cells := nil;
  SetLength(Cells, n);
  for k := 0 to n - 1 do
  begin
    T := Totals[Shown[Rows[k]]];
    SetLength(Cells[k], Cols);
    Cells[k][0] := SlotName(T.WSlot);
    for f := 0 to High(Ids) do
      Cells[k][1 + f] := WeaponMetricCell(E, SV, T, Ids[f], MaxInt);
    for c := 0 to High(StdCols) do
      Cells[k][1 + Length(Ids) + c] := WeaponColCell(SV, T, StdCols[c], AllKills);
  end;
  Widths := nil;
  SetLength(Widths, Cols);
  for c := 0 to Cols - 1 do
  begin
    Widths[c] := Length(Heads[c]);
    for k := 0 to n - 1 do
      Widths[c] := Max(Widths[c], Length(Cells[k][c]));
  end;
  Gap := 2;
  repeat
    Total := 0;
    for c := 0 to Cols - 1 do
      Inc(Total, Widths[c]);
    Inc(Total, Gap * (Cols - 1));
    if Total <= LINE_W then
      Break;
    if Cols > 1 + Length(Ids) then
      Dec(Cols)
    else if Gap = 2 then
      Gap := 1
    else
      Break;
  until False;
  Padded := nil;
  SetLength(Padded, Cols);
  for c := 0 to Cols - 1 do
    Padded[c] := Widths[c] + Gap;
  Header(E, Slot, TitleStart + MetricTitle(Copy(Heads, 1, Length(Ids)), LINE_W - 4 - Length(TitleStart + TitleEnd)) +
    TitleEnd, LINE_W);
  Row(E, Slot, Copy(Heads, 0, Cols), Padded, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := 0 to n - 1 do
  begin
    Line := Copy(Cells[k], 0, Cols);
    Row(E, Slot, Line, Padded, RowColor(k + 1, False));
  end;
end;

{ !allweaponsby <metrics> [player], !allweaponsbyi <metrics> <ranking position>: the table of
  !allweapons of one account, sorted by weapon metrics }
procedure CmdAllWeaponsBy(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  Metrics, Who, Unknown, ServerOnly, Note: AnsiString;
  Ids, Shown: TIntArray;
  Idx, S: LongInt;
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Totals: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
begin
  if (Rest = '') or SameText(Rest, 'help') then
  begin
    WeaponsByHelp(E, Slot, False);
    Exit;
  end;
  SplitMetricsWord(Rest, Metrics, Who);
  Ids := WeaponMetricIds(Metrics, True, Unknown, ServerOnly);
  if Length(Ids) = 0 then
  begin
    Out(E, Slot, 'No valid weapon metric given.', CLR_BAD);
    WeaponsByNotes(E, Slot, Unknown, ServerOnly);
    WeaponsByHelp(E, Slot, False);
    Exit;
  end;
  if ByRank then
    Idx := IndexAtRank(E, Who)
  else
    Idx := TargetIndex(E, Slot, Who);
  if not E.DB.Valid(Idx) then
  begin
    if not ByRank and (Slot < 1) and (Who = '') then
      Out(E, Slot, 'The console has no statistics of its own: name a player, e.g. !allweaponsby ' + Metrics +
        ' <player>.', CLR_WARN)
    else
    begin
      NotFound(E, Slot);
      { "!allweaponsby kills 3" looks for a player called 3; the ranking position is !allweaponsbyi }
      if not ByRank and AllDigits(Who) then
        Out(E, Slot, Format('For ranking position %s: !allweaponsbyi %s %s', [Who, Metrics, Who]), CLR_HINT);
    end;
    Exit;
  end;
  Shared := Default(TPlayerProfile);
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  { the weapons of !allweapons: those of Soldat's menu always, the others once used (the bows
    always in Rambomatch) }
  Shown := nil;
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    Totals[S] := PlayerWeaponTotals(P^, S);
    if (S <= WEP_LAW) or (Totals[S].Kills + Totals[S].Deaths + Totals[S].Shots + Totals[S].Hits + Totals[S].Time > 0) or
       (Totals[S].Damage > 0) or (((S = WEP_BOW) or (S = WEP_BOW2)) and (E.Match.GameStyle = GS_RM)) then
    begin
      SetLength(Shown, Length(Shown) + 1);
      Shown[High(Shown)] := S;
    end;
  end;
  WeaponsByTable(E, Slot, 'All Weapons by ', ': ' + P^.ActiveName, Totals, Shown, Ids, WeaponServer(E), PLAYER_WCOLS, 0);
  WeaponsByNotes(E, Slot, Unknown, ServerOnly);
  Out(E, Slot, 'Best first, "-" (no such value for the weapon) last. !allweaponsby help lists the metrics.', CLR_HINT);
  Footer(E, Slot, LINE_W);
end;

{ !serverweaponsby <metrics>: the table of !serverweapons, every account added up, sorted by weapon
  metrics }
procedure CmdServerWeaponsBy(E: TZSEngine; Slot: LongInt; const Rest: AnsiString);
var
  Unknown, ServerOnly: AnsiString;
  Ids, Shown: TIntArray;
  Totals: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
  S: LongInt;
  AllKills: Int64;
begin
  Ids := WeaponMetricIds(Rest, False, Unknown, ServerOnly);
  if Length(Ids) = 0 then
  begin
    Out(E, Slot, 'No valid weapon metric given.', CLR_BAD);
    WeaponsByNotes(E, Slot, Unknown, ServerOnly);
    WeaponsByHelp(E, Slot, True);
    Exit;
  end;
  CollectWeaponTotals(E, Totals, E.Cfg.MySQLShareWeapons);
  AllKills := 0;
  for S := 0 to WSLOT_COUNT - 1 do
    Inc(AllKills, Totals[S].Kills);
  { the weapons of !serverweapons: those of Soldat's menu always, the others once used }
  Shown := nil;
  for S := 0 to WSLOT_COUNT - 1 do
    if (S <= WEP_LAW) or WeaponUsed(Totals[S]) then
    begin
      SetLength(Shown, Length(Shown) + 1);
      Shown[High(Shown)] := S;
    end;
  if WeaponsAll(E) <> '' then
    WeaponsByTable(E, Slot, 'All Weapons by ', ': all servers', Totals, Shown, Ids, WeaponServer(E), SERVER_WCOLS, AllKills)
  else
    WeaponsByTable(E, Slot, 'All Weapons by ', ': the whole server', Totals, Shown, Ids, WeaponServer(E), SERVER_WCOLS,
      AllKills);
  WeaponsByNotes(E, Slot, Unknown, ServerOnly);
  Out(E, Slot, 'Best first, "-" (no such value for the weapon) last. !serverweaponsby help lists the metrics.', CLR_HINT);
  Footer(E, Slot, LINE_W);
end;

{ !wep <weapon> [player], !wepi <weapon> <ranking position> }
procedure CmdWeapon(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
const
  W = LINE_W;
var
  Wep, Idx, S: LongInt;
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
  V: TWeaponView;
  Why, Tail, HitsText, Longest, KillsShot: AnsiString;
begin
  if (Rest = '') or SameText(Rest, 'help') then
  begin
    WeaponHelp(E, Slot, 'Weapon Deep-Dive Lookup', 'Usage: !wep <weapon> [player]   !wepi <weapon> <ranking position>',
      'e.g. !wep ak   !wep barr xu   !wep desert eagles #12   !wepi deagle 1');
    Exit;
  end;
  if not SplitWeaponTarget(E, Slot, Rest, ByRank, Wep, Idx, Tail, Why) then
  begin
    Out(E, Slot, Why, CLR_BAD);
    Exit;
  end;
  S := WepSlot(Wep);
  if S < 0 then
  begin
    Out(E, Slot, WeaponProblem(Rest, '!wep'), CLR_BAD);
    Exit;
  end;
  if not E.DB.Valid(Idx) then
  begin
    if (Slot < 1) and (Tail = '') then
      Out(E, Slot, 'The console has no statistics of its own: name a player, e.g. !wep ' + Trim(Rest) + ' <player>.', CLR_WARN)
    else
    begin
      NotFound(E, Slot);
      { "!wep ak 3" looks for a player called 3; the ranking position is !wepi }
      if not ByRank and AllDigits(Tail) then
        Out(E, Slot, Format('For ranking position %s: !wepi %s %s', [Tail, WeaponShortName(Wep), Tail]), CLR_HINT);
    end;
    Exit;
  end;
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  V := WeaponView(P^, S);

  Header(E, Slot, 'Weapon: ' + SlotName(S) + ' - ' + P^.ActiveName, W);
  Row(E, Slot, ['Kills: ' + Num(V.Kills), 'Deaths: ' + Num(V.Deaths), 'K/D: ' + KD(V.Kills, V.Deaths)], COLS3, CLR_SHOOTING);
  DamageRows(E, Slot, V.Damage, V.DamageIn, V.Kills, V.Deaths, CLR_SHOOTING);
  { the hit share of the shots for the guns only (CountsForAccuracy) }
  if CountsForAccuracy(Wep) then
    HitsText := Format('Hits: %s (%s)', [Num(V.Hits), ShareOrDash(V.Hits, V.Shots)])
  else
    HitsText := 'Hits: ' + Num(V.Hits);
  Row(E, Slot, ['Shots: ' + WeaponShotsText(S, V.Shots), HitsText, 'Time: ' + FormatDurationShort(V.Time)], COLS3, CLR_SHOOTING);
  { only bullets, pellets, arrows and the stationary gun have hit zones }
  if ZoneClassifiableStyle(Wep) or (P^.Weapons[S].Headshots + P^.Weapons[S].HitsBody + P^.Weapons[S].HitsLegs > 0) then
    Row(E, Slot, [Format('Head: %s (%s)%s', [Num(V.Headshots), ShareOrDash(V.Headshots, V.Hits),
        ZoneEst(P^.Weapons[S].HitsUnknown, P^.Weapons[S].Headshots, P^.Weapons[S].HitsBody, P^.Weapons[S].HitsLegs)]),
      Format('Body: %s (%s)', [Num(P^.Weapons[S].HitsBody), ShareOrDash(P^.Weapons[S].HitsBody, V.Hits)]),
      Format('Legs: %s (%s)', [Num(P^.Weapons[S].HitsLegs), ShareOrDash(P^.Weapons[S].HitsLegs, V.Hits)])], COLS3, CLR_SHOOTING);
  if V.Longest > 0 then
    Longest := FloatStr(V.Longest, 1) + 'm'
  else
    Longest := '-';
  Row(E, Slot, ['Avg Dmg/Hit: ' + PerUnit(V.Damage, V.Hits, 1, ' HP'), 'HS Lethality: ' + ShareOrDash(V.HSKills, V.Headshots),
    'Longest Kill: ' + Longest], COLS3, WHITE);
  { a kill per shot needs shots of their own: the guns and the explosives, not the melee weapons
    (the knife kills by stabs as well as by its throws), the fuel of the flamer or the stationary gun }
  if CountsForAccuracy(Wep) or IsExplosiveWeapon(Wep) then
    KillsShot := RatioOrDash(V.Kills, V.Shots, 2)
  else
    KillsShot := '-';
  Row(E, Slot, ['Dmg/min: ' + RatioOrDash(V.Damage * 60.0, V.Time, 1), 'Hits/Kill: ' + RatioOrDash(V.Hits, V.Kills, 2),
    'Kills/Shot: ' + KillsShot], COLS3, WHITE);
  Out(E, Slot, 'Sweet Spot: ' + WeaponSweetSpot(Wep), WHITE);
  ReloadSection(E, Slot, Wep, ReloadTotalsOf(P^.Weapons[S]), W);

  WeaponGlobalSection(E, Slot, S, W);

  case Wep of
    WEP_M79:
      Row(E, Slot, ['Explode Hurts: ' + Num(P^.M79HurtsEnemy), Format('TK: %s | Self: %s', [Num(P^.M79HurtsFriendly), Num(P^.M79HurtsSelf)])],
        COLS2, CLR_SHOOTING);
    WEP_KNIFE:
      begin
        Row(E, Slot, [Format('Throws: %s (Hits: %s)', [Num(P^.KnivesThrows), Num(P^.KnivesThrowsHitsEnemy)]),
          Format('Stabs: %s (TK: %s)', [Num(P^.KnivesStabsEnemy), Num(P^.KnivesStabsFriendly)])], COLS2, CLR_SHOOTING);
        if (P^.KnivesThrowsHitsSelf > 0) or (P^.KnivesThrowsHitsFriends > 0) then
          Row(E, Slot, ['Self Hits: ' + Num(P^.KnivesThrowsHitsSelf), 'TK Throw Hits: ' + Num(P^.KnivesThrowsHitsFriends)],
            COLS2, CLR_SHOOTING);
      end;
    WEP_CHAINSAW:
      Row(E, Slot, ['Saw Hurts: ' + Num(P^.ChainsawHurtsEnemy), 'TK Hurts: ' + Num(P^.ChainsawHurtsFriendly)], COLS2, CLR_SHOOTING);
    WEP_LAW:
      Row(E, Slot, ['Rocket Hurts: ' + Num(P^.M72LAWHurtsEnemy), Format('TK: %s | Self: %s', [Num(P^.M72LAWHurtsFriendly),
        Num(P^.M72LAWHurtsSelf)])], COLS2, CLR_SHOOTING);
    WEP_FLAMER:
      Row(E, Slot, ['Fire Hurts: ' + Num(P^.FlamethrowerHitsEnemy),
        Format('TK: %s | Self: %s', [Num(P^.FlamethrowerHitsFriendly), Num(P^.FlamethrowerHitsSelf)])], COLS2, CLR_SHOOTING);
    WEP_BOW, WEP_BOW2:
      begin
        Row(E, Slot, [Format('Pickups: %s | Drops: %s', [Num(P^.RamboMode.GetsBow), Num(P^.RamboMode.DropBow)]),
          'Held: ' + FormatDurationShort(P^.RamboMode.TimeWithBow)], COLS2, CLR_SHOOTING);
        if P^.BowFlamedArrowsHurtsEnemy > 0 then
          Row(E, Slot, ['Flame Arrow Hurts: ' + Num(P^.BowFlamedArrowsHurtsEnemy),
            Format('TK: %s | Self: %s', [Num(P^.BowFlamedArrowsHurtsFriendly), Num(P^.BowFlamedArrowsHurtsSelf)])], COLS2, CLR_SHOOTING);
      end;
    WEP_M2:
      Row(E, Slot, ['Stationary Hits: ' + Num(P^.M2MGHitsEnemy), 'TK Hits: ' + Num(P^.M2MGHitsFriendly)], COLS2, CLR_SHOOTING);
    WEP_NONE:
      Row(E, Slot, ['Fist Hurts: ' + Num(P^.HandsHurtsEnemy), 'TK Hurts: ' + Num(P^.HandsHurtsFriendly)], COLS2, CLR_SHOOTING);
    WEP_FRAG:
      Row(E, Slot, [Format('Throws: %s, enemy hits %s (%s)', [Num(P^.NadesThrows), Num(P^.NadeHurtsEnemy),
        ShareOrDash(P^.NadeHurtsEnemy, P^.NadesThrows)]),
        Format('TK: %s | Self: %s | Kills: %s', [Num(P^.NadeHurtsFriendly), Num(P^.NadeHurtsSelf), Num(P^.GrenadeKills)])],
        COLS2, CLR_SHOOTING);
    WEP_CLUSTERNADE:
      Row(E, Slot, [Format('Throws: %s, enemy hits %s', [Num(P^.ClusterNadesThrows), Num(P^.ClusterNadesHurtsEnemy)]),
        Format('TK: %s | Self: %s', [Num(P^.ClusterNadesHurtsFriendly), Num(P^.ClusterNadesHurtsSelf)])], COLS2, CLR_SHOOTING);
  end;
  Footer(E, Slot, W);
end;

{ 'few duels' below 10 duels; otherwise an edge only when the 95% Wilson range of the win rate
  stays on one side of 50%, so a lucky streak on a few duels is not called an advantage }
function MatchupEdge(Won, Total: LongInt; out Color: LongInt): AnsiString;
var
  Lo, Hi, WinPct: Double;
begin
  WilsonInterval(Won, Total, Lo, Hi);
  WinPct := SafeDivD(Won * 100.0, Total);
  if Total < 10 then
  begin
    Result := 'few duels';
    Color := CLR_OTHER_ROW;
  end
  else if Lo > 0.5 then
  begin
    if WinPct >= 58 then
    begin
      Result := 'FAVORED';
      Color := CLR_TOP1;
    end
    else
    begin
      Result := 'slight edge';
      Color := CLR_GOOD;
    end;
  end
  else if Hi < 0.5 then
  begin
    if WinPct <= 42 then
    begin
      Result := 'DISADVANTAGE';
      Color := CLR_BAD;
    end
    else
    begin
      Result := 'slight deficit';
      Color := CLR_WARN;
    end;
  end
  else
  begin
    Result := 'EVEN';
    Color := CLR_SHOOTING;
  end;
end;

function WilsonRangeText(Won, Total: LongInt): AnsiString;
var
  Lo, Hi: Double;
begin
  WilsonInterval(Won, Total, Lo, Hi);
  Result := Format('%d-%d%%', [Round(Lo * 100), Round(Hi * 100)]);
end;

{ !matchup [page]: the duels between two weapons, most duels first; !matchup <weapon> [page]:
  one weapon against every other one it met. Both page like the other lists (/zs_next, /zs_page n). }
type
  TMatchupTable = array[0..WSLOT_COUNT - 1, 0..WSLOT_COUNT - 1] of LongInt;
  PMatchupTable = ^TMatchupTable;

procedure CmdMatchups(E: TZSEngine; Slot: LongInt; const Query: AnsiString; Page: LongInt);
const
  W = LINE_W;
  { place, the two weapons, duels, the wins of each and the verdict: at most 85 of LINE_W }
  CR: array[0..5] of LongInt = (5, 24, 8, 16, 16, 16);
  { opponent, kills, deaths, win rate, its 95% range, ratio and the edge: at most 77 of LINE_W }
  CW: array[0..6] of LongInt = (18, 8, 8, 10, 11, 8, 14);
var
  S, k, j, n, Won, Lost, Total, Color, PerPage, Pages, First, Last: LongInt;
  A, B: array of LongInt;
  Rows: TIntArray;
  Lo, Hi: Double;
  Edge: AnsiString;
  MU: PMatchupTable;
begin
  MU := @WeaponServer(E)^.Matchups;
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  if Trim(Query) = '' then
  begin
    A := nil;
    B := nil;
    SetLength(A, WSLOT_COUNT * WSLOT_COUNT);
    SetLength(B, WSLOT_COUNT * WSLOT_COUNT);
    n := 0;
    for k := 0 to WSLOT_COUNT - 1 do
      for j := k + 1 to WSLOT_COUNT - 1 do
        if MU^[k, j] + MU^[j, k] > 0 then
        begin
          A[n] := k;
          B[n] := j;
          Inc(n);
        end;
    if n = 0 then
    begin
      Out(E, Slot, 'No weapon duels recorded yet.', CLR_OTHER_ROW);
      Exit;
    end;
    Pages := PageCount(n, PerPage);
    Page := EnsureRange(Page, 1, Pages);
    First := (Page - 1) * PerPage;
    Last := Min(n, First + PerPage) - 1;
    Header(E, Slot, Format('Weapon Matchups: Top Rivalries [Page %d/%d] (%d)', [Page, Pages, n]), W);
    Row(E, Slot, ['#', 'Duel Rivalry', 'Duels', 'A Wins', 'B Wins', 'Verdict'], CR, CLR_SUBHEADER);
    Rule(E, Slot, W);
    PrepareSort(n, 1);
    for k := 0 to n - 1 do
    begin
      SortKeys[k] := MU^[A[k], B[k]] + MU^[B[k], A[k]];
      SortTie[k] := 0;
    end;
    Rows := OrderedRows(n);
    for k := First to Last do
    begin
      j := Rows[k];
      Won := MU^[A[j], B[j]];
      Lost := MU^[B[j], A[j]];
      Total := Won + Lost;
      WilsonInterval(Won, Total, Lo, Hi);
      if Total < 10 then
        Edge := 'few duels'
      else if Lo > 0.5 then
        Edge := SlotShortName(A[j]) + ' favored'
      else if Hi < 0.5 then
        Edge := SlotShortName(B[j]) + ' favored'
      else
        Edge := 'even';
      Row(E, Slot, [IntToStr(k + 1), SlotShortName(A[j]) + ' vs ' + SlotShortName(B[j]), Num(Total),
        Format('%s (%s)', [Num(Won), Pct(Won, Total)]), Format('%s (%s)', [Num(Lost), Pct(Lost, Total)]), Edge], CR, CLR_SHOOTING);
    end;
    Out(E, Slot, 'A weapon is favored only when its 95% win-rate range stays above 50%.', CLR_HINT);
    Out(E, Slot, '!matchup <weapon> shows one weapon; a number at the end is the page.', CLR_HINT);
    PageHint(E, Slot, Page, Pages, 'rivalries');
    Remember(E, Slot, QK_MATCHUP, '', Page, Pages);
    Exit;
  end;

  S := WeaponSlotOrSay(E, Slot, Query, '!wep');
  if S < 0 then
    Exit;
  { the opponents with duels, most duels first }
  A := nil;
  SetLength(A, WSLOT_COUNT);
  n := 0;
  for j := 0 to WSLOT_COUNT - 1 do
    if (j <> S) and (MU^[S, j] + MU^[j, S] > 0) then
    begin
      A[n] := j;
      Inc(n);
    end;
  if n = 0 then
  begin
    Out(E, Slot, 'No duels recorded for ' + SlotName(S) + ' yet.', CLR_HINT);
    Exit;
  end;
  PrepareSort(n, 1);
  for k := 0 to n - 1 do
  begin
    SortKeys[k] := MU^[S, A[k]] + MU^[A[k], S];
    SortTie[k] := 0;
  end;
  Rows := OrderedRows(n);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  Header(E, Slot, Format('Matchups: %s [Page %d/%d]', [SlotName(S), Page, Pages]), W);
  Row(E, Slot, ['Opponent Weapon', 'Kills', 'Deaths', 'Win Rate', '95% Range', 'Ratio', 'Matchup Edge'], CW, CLR_SUBHEADER);
  Rule(E, Slot, W);
  for k := First to Last do
  begin
    j := A[Rows[k]];
    Won := MU^[S, j];
    Lost := MU^[j, S];
    Total := Won + Lost;
    Edge := MatchupEdge(Won, Total, Color);
    Row(E, Slot, [SlotName(j), Num(Won), Num(Lost), Pct(Won, Total), WilsonRangeText(Won, Total), FloatStr(Won / Max(1, Lost), 2),
      Edge], CW, Color);
  end;
  Out(E, Slot, 'Range: 95% sure the real win rate is inside. Edge only if the range misses 50%.', CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'weapons');
  Remember(E, Slot, QK_MATCHUP, SlotShortName(S), Page, Pages);
end;
