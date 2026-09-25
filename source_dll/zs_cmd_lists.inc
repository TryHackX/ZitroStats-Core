{ zs_commands: player rankings, custom metric leaderboards and search }

type
  TMetricFmt = (mfInt, mfDec1, mfDec2, mfPct, mfTime, mfMeters, mfSec, mfTier, mfDmg);

  TMetricDef = record
    Aliases: AnsiString;    { ' name alias ... ' }
    Header: AnsiString;
    Fmt: TMetricFmt;
    Asc: Boolean;           { a lower value is better (times); 0 means no value and sorts last }
  end;

const
  MET_WEAPON_KILLS = 1000;  { + weapon slot }
  MET_WEAPON_TIME = 1100;
  MET_WEAPON_ACC = 1200;
  MET_WEAPON_HS = 1300;
  MET_WEAPON_DMG = 1400;

  { The position in this table is the metric id used by PlayerMetricValue. }
  PLAYER_METRICS: array[0..166] of TMetricDef = (
    (Aliases: ' points pts point '; Header: 'Points'; Fmt: mfInt; Asc: False),                      { 0 }
    (Aliases: ' rating rate '; Header: 'Rating'; Fmt: mfDec1; Asc: False),
    (Aliases: ' tier division '; Header: 'Tier'; Fmt: mfTier; Asc: False),
    (Aliases: ' skill '; Header: 'Skill'; Fmt: mfDec1; Asc: False),
    (Aliases: ' kills kill k '; Header: 'Kills'; Fmt: mfInt; Asc: False),
    (Aliases: ' deaths death d '; Header: 'Deaths'; Fmt: mfInt; Asc: False),                        { 5 }
    (Aliases: ' kdr kd ratio '; Header: 'K/D'; Fmt: mfDec2; Asc: False),
    (Aliases: ' selfkills self selfs suicide suicides '; Header: 'Selfs'; Fmt: mfInt; Asc: False),
    (Aliases: ' assists assist ast '; Header: 'Assists'; Fmt: mfInt; Asc: False),
    (Aliases: ' shots shot '; Header: 'Shots'; Fmt: mfInt; Asc: False),
    (Aliases: ' hits hit '; Header: 'Hits'; Fmt: mfInt; Asc: False),                                { 10 }
    (Aliases: ' acc accuracy '; Header: 'Acc%'; Fmt: mfPct; Asc: False),
    (Aliases: ' dmg damage dmgdealt damagedealt dealtdmg '; Header: 'Damage'; Fmt: mfDmg; Asc: False),
    (Aliases: ' dmgtaken damagereceived dmgrec dmgin '; Header: 'DmgTaken'; Fmt: mfDmg; Asc: False),
    (Aliases: ' dmgratio damageratio dr '; Header: 'DmgRatio'; Fmt: mfDec2; Asc: False),
    (Aliases: ' dmgkills damagekills '; Header: 'DmgKills'; Fmt: mfDec1; Asc: False),               { 15 }
    (Aliases: ' dmgdeaths damagedeaths '; Header: 'DmgDeaths'; Fmt: mfDec1; Asc: False),
    (Aliases: ' tkdmg friendlydmg '; Header: 'TK_DmgOut'; Fmt: mfDmg; Asc: False),
    (Aliases: ' tkdmgrec friendlydmgrec '; Header: 'TK_DmgIn'; Fmt: mfDmg; Asc: False),
    (Aliases: ' longkill longestkill maxdist '; Header: 'LngKill'; Fmt: mfMeters; Asc: False),
    (Aliases: ' barretkill barrettkill barretdist longestbarret '; Header: 'BarrettLng'; Fmt: mfMeters; Asc: False), { 20 }
    (Aliases: ' avgdist avgdistance meandist '; Header: 'AvgDist'; Fmt: mfMeters; Asc: False),
    (Aliases: ' long100 kills100 '; Header: '100m+'; Fmt: mfInt; Asc: False),
    (Aliases: ' barrettlong '; Header: 'BarrettLong'; Fmt: mfInt; Asc: False),
    (Aliases: ' hs headshots headshot head '; Header: 'HS'; Fmt: mfInt; Asc: False),
    (Aliases: ' hsacc hs% '; Header: 'HS%'; Fmt: mfPct; Asc: False),                                { 25 }
    (Aliases: ' chest body '; Header: 'Body'; Fmt: mfInt; Asc: False),
    (Aliases: ' bodyacc body% '; Header: 'Body%'; Fmt: mfPct; Asc: False),
    (Aliases: ' legs leg '; Header: 'Legs'; Fmt: mfInt; Asc: False),
    (Aliases: ' legacc leg% '; Header: 'Leg%'; Fmt: mfPct; Asc: False),
    (Aliases: ' maxstreak streak killstreak '; Header: 'Streak'; Fmt: mfInt; Asc: False),           { 30 }
    (Aliases: ' double doublekills dk '; Header: 'Double'; Fmt: mfInt; Asc: False),
    (Aliases: ' triple triplekills '; Header: 'Triple'; Fmt: mfInt; Asc: False),
    (Aliases: ' multi multikills mk '; Header: 'Multi'; Fmt: mfInt; Asc: False),
    (Aliases: ' multix2 multi2 '; Header: 'MultiX2'; Fmt: mfInt; Asc: False),
    (Aliases: ' serial serialkill '; Header: 'Serial'; Fmt: mfInt; Asc: False),                     { 35 }
    (Aliases: ' insane insanekills '; Header: 'Insane'; Fmt: mfInt; Asc: False),
    (Aliases: ' multi57 bigmulti '; Header: 'Multi5-7'; Fmt: mfInt; Asc: False),
    (Aliases: ' gimme gimmemore '; Header: 'Gimme'; Fmt: mfInt; Asc: False),
    (Aliases: ' masta mastakilla '; Header: 'Masta'; Fmt: mfInt; Asc: False),
    (Aliases: ' stopit stop '; Header: 'StopIt'; Fmt: mfInt; Asc: False),                           { 40 }
    (Aliases: ' mercy '; Header: 'Mercy'; Fmt: mfInt; Asc: False),
    (Aliases: ' cheater '; Header: 'Cheater'; Fmt: mfInt; Asc: False),
    (Aliases: ' firstblood fb '; Header: 'FBlood'; Fmt: mfInt; Asc: False),
    (Aliases: ' firstdmg firstdamage fd '; Header: 'FDmg'; Fmt: mfInt; Asc: False),
    (Aliases: ' laststand ls '; Header: 'LastStand'; Fmt: mfInt; Asc: False),                       { 45 }
    (Aliases: ' clutches clutch '; Header: 'Clutches'; Fmt: mfInt; Asc: False),
    (Aliases: ' dom doms dominations dominating '; Header: 'Doms'; Fmt: mfInt; Asc: False),
    (Aliases: ' revenge '; Header: 'Revenge'; Fmt: mfInt; Asc: False),
    (Aliases: ' posthumous postromus post '; Header: 'Post'; Fmt: mfInt; Asc: False),
    (Aliases: ' savior '; Header: 'Savior'; Fmt: mfInt; Asc: False),                                { 50 }
    (Aliases: ' avenger '; Header: 'Avenger'; Fmt: mfInt; Asc: False),
    (Aliases: ' pmscore extrapoints '; Header: 'PMScore'; Fmt: mfInt; Asc: False),
    (Aliases: ' caps flags flag captures '; Header: 'Caps'; Fmt: mfInt; Asc: False),
    (Aliases: ' returns ret '; Header: 'Returns'; Fmt: mfInt; Asc: False),
    (Aliases: ' grabs grab '; Header: 'Grabs'; Fmt: mfInt; Asc: False),                             { 55 }
    (Aliases: ' drops drop flagdeny '; Header: 'Drops'; Fmt: mfInt; Asc: False),
    (Aliases: ' fkills flaggerkills '; Header: 'FKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' flagassist fkillsassist '; Header: 'FAssist'; Fmt: mfInt; Asc: False),
    (Aliases: ' saviorflag fdefense '; Header: 'FDefense'; Fmt: mfInt; Asc: False),
    (Aliases: ' flagtime timeholdingflags '; Header: 'FlagTime'; Fmt: mfTime; Asc: False),          { 60 }
    (Aliases: ' killswithflag '; Header: 'FlagKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' fastcap fastestcap '; Header: 'FastCap'; Fmt: mfSec; Asc: True),
    (Aliases: ' escort carrierescort '; Header: 'Escort'; Fmt: mfInt; Asc: False),
    (Aliases: ' juggles juggle flagjuggle '; Header: 'Juggles'; Fmt: mfInt; Asc: False),
    (Aliases: ' contested contestedhold '; Header: 'Contest'; Fmt: mfInt; Asc: False),              { 65 }
    (Aliases: ' fastcaps capsunder10 '; Header: 'Caps<10s'; Fmt: mfInt; Asc: False),
    (Aliases: ' htfpoints htfscore '; Header: 'HTFPts'; Fmt: mfInt; Asc: False),
    (Aliases: ' htftime htfholdtime '; Header: 'HTFTime'; Fmt: mfTime; Asc: False),
    (Aliases: ' htfteamtime '; Header: 'HTFTeam'; Fmt: mfTime; Asc: False),
    (Aliases: ' wins win w '; Header: 'Wins'; Fmt: mfInt; Asc: False),                              { 70 }
    (Aliases: ' losses loses lose l '; Header: 'Losses'; Fmt: mfInt; Asc: False),
    (Aliases: ' draws draw '; Header: 'Draws'; Fmt: mfInt; Asc: False),
    (Aliases: ' winrate wr win% '; Header: 'Win%'; Fmt: mfPct; Asc: False),
    (Aliases: ' rwins roundswon rw '; Header: 'RWins'; Fmt: mfInt; Asc: False),
    (Aliases: ' rlost roundslost rl '; Header: 'RLost'; Fmt: mfInt; Asc: False),                    { 75 }
    (Aliases: ' roundwr roundrate '; Header: 'Round%'; Fmt: mfPct; Asc: False),
    (Aliases: ' roundratio rr '; Header: 'RRatio'; Fmt: mfDec2; Asc: False),
    (Aliases: ' advrounds advr '; Header: 'AdvRnd'; Fmt: mfInt; Asc: False),
    (Aliases: ' advwins advw '; Header: 'AdvWin'; Fmt: mfInt; Asc: False),
    (Aliases: ' comebacks comebackwins '; Header: 'Comebacks'; Fmt: mfInt; Asc: False),             { 80 }
    (Aliases: ' leaverlosses leaves '; Header: 'LeftLost'; Fmt: mfInt; Asc: False),
    (Aliases: ' time timeplayed playtime '; Header: 'Time'; Fmt: mfTime; Asc: False),
    (Aliases: ' timealive alive survival '; Header: 'Alive'; Fmt: mfTime; Asc: False),
    (Aliases: ' lifespan avglife avglifespan '; Header: 'Lifespan'; Fmt: mfTime; Asc: False),
    (Aliases: ' timedead timedeath '; Header: 'Dead'; Fmt: mfTime; Asc: False),                     { 85 }
    (Aliases: ' spec spectator spectime '; Header: 'Spec'; Fmt: mfTime; Asc: False),
    (Aliases: ' longestlife longlife '; Header: 'LongLife'; Fmt: mfTime; Asc: False),
    (Aliases: ' days daysplayed '; Header: 'Days'; Fmt: mfInt; Asc: False),
    (Aliases: ' protect protection '; Header: 'Protect'; Fmt: mfInt; Asc: False),
    (Aliases: ' pace kph '; Header: 'Kills/h'; Fmt: mfDec1; Asc: False),                            { 90 }
    (Aliases: ' traveled distance km '; Header: 'Km'; Fmt: mfDec1; Asc: False),
    (Aliases: ' flytime jets jet fly '; Header: 'FlyTime'; Fmt: mfTime; Asc: False),
    (Aliases: ' tk teamkills '; Header: 'TK'; Fmt: mfInt; Asc: False),
    (Aliases: ' tked deathsbyfriendly '; Header: 'TKed'; Fmt: mfInt; Asc: False),
    (Aliases: ' friendlyhits tkhits '; Header: 'TKHits'; Fmt: mfInt; Asc: False),                   { 95 }
    (Aliases: ' friendlyhitsby tkedhits '; Header: 'TKedHits'; Fmt: mfInt; Asc: False),
    (Aliases: ' favvictim victim '; Header: 'FavVictim'; Fmt: mfInt; Asc: False),
    (Aliases: ' nemesis '; Header: 'Nemesis'; Fmt: mfInt; Asc: False),
    (Aliases: ' stabs stab '; Header: 'Stabs'; Fmt: mfInt; Asc: False),
    (Aliases: ' throws knifethrows '; Header: 'Throws'; Fmt: mfInt; Asc: False),                    { 100 }
    (Aliases: ' knifehits '; Header: 'KnifeHit'; Fmt: mfInt; Asc: False),
    (Aliases: ' knifeacc '; Header: 'KnifeAcc'; Fmt: mfPct; Asc: False),
    (Aliases: ' sawhits '; Header: 'SawHits'; Fmt: mfInt; Asc: False),
    (Aliases: ' sawtime '; Header: 'SawTime'; Fmt: mfTime; Asc: False),
    (Aliases: ' nades nade grenades '; Header: 'Nades'; Fmt: mfInt; Asc: False),                    { 105 }
    (Aliases: ' nadehits '; Header: 'NadeHits'; Fmt: mfInt; Asc: False),
    (Aliases: ' nadeacc '; Header: 'NadeAcc'; Fmt: mfPct; Asc: False),
    (Aliases: ' cluster clusternades '; Header: 'Cluster'; Fmt: mfInt; Asc: False),
    (Aliases: ' clusterhits '; Header: 'ClustHit'; Fmt: mfInt; Asc: False),
    (Aliases: ' fists punch '; Header: 'Fists'; Fmt: mfInt; Asc: False),                            { 110 }
    (Aliases: ' m79shots '; Header: 'M79Shots'; Fmt: mfInt; Asc: False),
    (Aliases: ' m79hits '; Header: 'M79Hits'; Fmt: mfInt; Asc: False),
    (Aliases: ' m79acc '; Header: 'M79Acc'; Fmt: mfPct; Asc: False),
    (Aliases: ' lawshots '; Header: 'LAWShots'; Fmt: mfInt; Asc: False),
    (Aliases: ' lawhits '; Header: 'LAWHits'; Fmt: mfInt; Asc: False),                              { 115 }
    (Aliases: ' lawacc '; Header: 'LAWAcc'; Fmt: mfPct; Asc: False),
    (Aliases: ' flamershots '; Header: 'FlamerSh'; Fmt: mfInt; Asc: False),
    (Aliases: ' flamerhits '; Header: 'FlamerHit'; Fmt: mfInt; Asc: False),
    (Aliases: ' flameracc '; Header: 'FlamerAcc'; Fmt: mfPct; Asc: False),
    (Aliases: ' statgun m2mg m2 '; Header: 'M2_Hits'; Fmt: mfInt; Asc: False),                      { 120 }
    (Aliases: ' rambo killrambo '; Header: 'Rambo'; Fmt: mfInt; Asc: False),
    (Aliases: ' bowkills '; Header: 'BowKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' bowtime '; Header: 'BowTime'; Fmt: mfTime; Asc: False),
    (Aliases: ' prone pronekills '; Header: 'Prone'; Fmt: mfInt; Asc: False),
    (Aliases: ' camp campkill campkills camper '; Header: 'Camp'; Fmt: mfInt; Asc: False),          { 125 }
    (Aliases: ' bink binkrecovery binkkills '; Header: 'Bink'; Fmt: mfInt; Asc: False),
    (Aliases: ' airkills air '; Header: 'AirKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' heightkills height '; Header: 'Height'; Fmt: mfInt; Asc: False),
    (Aliases: ' vestkills vest '; Header: 'VestKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' nadekills grenadekills '; Header: 'NadeKills'; Fmt: mfInt; Asc: False),             { 130 }
    (Aliases: ' explomulti explosionmulti '; Header: 'ExploMulti'; Fmt: mfInt; Asc: False),
    (Aliases: ' knifestreak knifelife '; Header: 'KnifeStreak'; Fmt: mfInt; Asc: False),
    (Aliases: ' spawnkills '; Header: 'SpawnKills'; Fmt: mfInt; Asc: False),
    (Aliases: ' spawndeaths '; Header: 'SpawnDeaths'; Fmt: mfInt; Asc: False),
    (Aliases: ' ttk avgttk '; Header: 'AvgTTK'; Fmt: mfSec; Asc: True),                             { 135 }
    (Aliases: ' bestttk '; Header: 'BestTTK'; Fmt: mfSec; Asc: True),
    (Aliases: ' spree sprees streak5 '; Header: 'Streak5'; Fmt: mfInt; Asc: False),
    (Aliases: ' rampage rampagespree rampage10 streak10 '; Header: 'Streak10'; Fmt: mfInt; Asc: False),
    (Aliases: ' domspree dominatingspree streak15 '; Header: 'Streak15'; Fmt: mfInt; Asc: False),
    (Aliases: ' unstoppable streak20 '; Header: 'Streak20'; Fmt: mfInt; Asc: False),                          { 140 }
    (Aliases: ' godlike streak25 '; Header: 'Streak25'; Fmt: mfInt; Asc: False),
    (Aliases: ' shutdowns shutdown '; Header: 'ShutDowns'; Fmt: mfInt; Asc: False),
    (Aliases: ' finishers finisher '; Header: 'Finishers'; Fmt: mfInt; Asc: False),
    (Aliases: ' seasonpoints season spts '; Header: 'SeasonPts'; Fmt: mfInt; Asc: False),
    (Aliases: ' achievements ach '; Header: 'Achiev'; Fmt: mfInt; Asc: False),                      { 145 }
    (Aliases: ' badges '; Header: 'Badges'; Fmt: mfInt; Asc: False),
    (Aliases: ' cover coverlive wallkills throughcover '; Header: 'CovLive'; Fmt: mfInt; Asc: False),
    (Aliases: ' mmr hots '; Header: 'MMR'; Fmt: mfInt; Asc: False),                                   { 148 }
    (Aliases: ' glicko glicko2 '; Header: 'Glicko'; Fmt: mfInt; Asc: False),
    (Aliases: ' openskill '; Header: 'OpenSkill'; Fmt: mfDec1; Asc: False),
    (Aliases: ' forced forcedselfkills forcedsuicides '; Header: 'Forced'; Fmt: mfInt; Asc: False),  { 151 }
    (Aliases: ' underfire suicidesunderfire '; Header: 'UnderFire'; Fmt: mfInt; Asc: False),
    (Aliases: ' covershot shotcover '; Header: 'CovShot'; Fmt: mfInt; Asc: False),
    (Aliases: ' balmoves balancemoves moved '; Header: 'BalMoves'; Fmt: mfInt; Asc: False),
    (Aliases: ' volunteered volunteers volunteer '; Header: 'Volunteer'; Fmt: mfInt; Asc: False),  { 155 }
    (Aliases: ' healed healing heal hp '; Header: 'Healed'; Fmt: mfDmg; Asc: False),
    (Aliases: ' regen regenerated fields '; Header: 'Regen'; Fmt: mfDmg; Asc: False),
    (Aliases: ' healkits healingkits '; Header: 'HealKits'; Fmt: mfInt; Asc: False),                 { 158 }
    (Aliases: ' kits allkits '; Header: 'Kits'; Fmt: mfInt; Asc: False),
    (Aliases: ' medkits medikits '; Header: 'MedKits'; Fmt: mfInt; Asc: False),                      { 160 }
    (Aliases: ' nadekits grenadekits '; Header: 'NadeKits'; Fmt: mfInt; Asc: False),
    (Aliases: ' clusterkits '; Header: 'ClusterKits'; Fmt: mfInt; Asc: False),
    (Aliases: ' vestkits '; Header: 'VestKits'; Fmt: mfInt; Asc: False),
    (Aliases: ' berserkkits berserkerkits '; Header: 'BerserkKits'; Fmt: mfInt; Asc: False),
    (Aliases: ' predatorkits '; Header: 'PredatorKits'; Fmt: mfInt; Asc: False),                     { 165 }
    (Aliases: ' flamerkits '; Header: 'FlamerKits'; Fmt: mfInt; Asc: False)                          { 166 }
  );

var
  { rows * SortCols keys for SortRows; filled by the caller }
  SortKeys: array of Double;
  SortTie: array of Double;
  SortCols: LongInt;

function RowFirst(A, B: LongInt): Boolean;
var
  f: LongInt;
  VA, VB: Double;
begin
  for f := 0 to SortCols - 1 do
  begin
    VA := SortKeys[A * SortCols + f];
    VB := SortKeys[B * SortCols + f];
    if VA <> VB then
      Exit(VA > VB);
  end;
  if SortTie[A] <> SortTie[B] then
    Exit(SortTie[A] > SortTie[B]);
  Result := A < B;
end;

procedure SortRows(var Rows: TIntArray; L, R: LongInt);
var
  i, j, Pivot, T: LongInt;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := Rows[(L + R) shr 1];
    repeat
      while RowFirst(Rows[i], Pivot) do
        Inc(i);
      while RowFirst(Pivot, Rows[j]) do
        Dec(j);
      if i <= j then
      begin
        T := Rows[i];
        Rows[i] := Rows[j];
        Rows[j] := T;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - L < R - i then
    begin
      if L < j then
        SortRows(Rows, L, j);
      L := i;
    end
    else
    begin
      if i < R then
        SortRows(Rows, i, R);
      R := j;
    end;
  end;
end;

procedure PrepareSort(Rows, Cols: LongInt);
begin
  SortCols := Cols;
  SetLength(SortKeys, Rows * Cols);
  SetLength(SortTie, Rows);
end;

function OrderedRows(Rows: LongInt): TIntArray;
var
  k: LongInt;
begin
  Result := nil;
  SetLength(Result, Rows);
  for k := 0 to Rows - 1 do
    Result[k] := k;
  if Rows > 1 then
    SortRows(Result, 0, Rows - 1);
end;

{ The first K rows in RowFirst order without sorting all of them: a heap holds the best K seen
  so far, with the one that comes last at the root. }
function BestRows(Rows, K: LongInt): TIntArray;
var
  Heap: TIntArray;
  n, r, i, c, T: LongInt;
begin
  Result := nil;
  K := Min(K, Rows);
  if K <= 0 then
    Exit;
  SetLength(Heap, K);
  n := 0;
  for r := 0 to Rows - 1 do
    if n < K then
    begin
      i := n;
      Heap[i] := r;
      Inc(n);
      while i > 0 do
      begin
        c := (i - 1) shr 1;
        if not RowFirst(Heap[c], Heap[i]) then
          Break;
        T := Heap[c];
        Heap[c] := Heap[i];
        Heap[i] := T;
        i := c;
      end;
    end
    else if RowFirst(r, Heap[0]) then
    begin
      Heap[0] := r;
      i := 0;
      while True do
      begin
        c := 2 * i + 1;
        if c >= n then
          Break;
        if (c + 1 < n) and RowFirst(Heap[c], Heap[c + 1]) then
          Inc(c);
        if not RowFirst(Heap[i], Heap[c]) then
          Break;
        T := Heap[c];
        Heap[c] := Heap[i];
        Heap[i] := T;
        i := c;
      end;
    end;
  if n > 1 then
    SortRows(Heap, 0, n - 1);
  Result := Heap;
end;

function SortValue(V: Double; Asc: Boolean): Double;
begin
  if not Asc then
    Result := V
  else if V <= 0 then
    Result := -MaxDouble
  else
    Result := -V;
end;

function RowColor(Rank: LongInt; Mine: Boolean): LongInt;
begin
  if Mine then
    Result := CLR_YOU
  else
    case Rank of
      1: Result := CLR_TOP1;
      2: Result := CLR_TOP2;
      3: Result := CLR_TOP3;
      else Result := CLR_OTHER_ROW;
    end;
end;

function MetricIndex(const Defs: array of TMetricDef; const Token: AnsiString): LongInt;
var
  k: LongInt;
  T: AnsiString;
begin
  T := ' ' + LowerCase(Trim(Token)) + ' ';
  if T = '  ' then
    Exit(-1);
  for k := 0 to High(Defs) do
    if Pos(T, Defs[k].Aliases) > 0 then
      Exit(k);
  Result := -1;
end;

function MetricText(Fmt: TMetricFmt; V: Double): AnsiString;
begin
  case Fmt of
    mfDec1: Result := FloatStr(V, 1);
    mfDec2: Result := FloatStr(V, 2);
    mfPct: Result := FloatStr(V, 1) + '%';
    mfTime: Result := FormatDurationShort(Round(V));
    mfMeters: Result := FloatStr(V, 1) + 'm';
    mfSec:
      if V > 0 then
        Result := FloatStr(V, 2) + 's'
      else
        Result := '-';
    { damage and counts are shortened like every other counter (Dmg, Num): 603 stays 603,
      15135 becomes 15.1k }
    else Result := Dmg(V);
  end;
end;

{ a gain or a loss of points, shortened like the counters: +603, -12, +15.1k }
function SignedShort(V: Int64): AnsiString;
begin
  if V >= 0 then
    Result := '+' + Num(V)
  else
    Result := Num(V);
end;

{ A / B with Decimals, '-' when there is nothing to divide by: a ratio of nothing is no 0 }
function RatioOrDash(A, B: Double; Decimals: LongInt): AnsiString;
begin
  if Abs(B) < 1e-9 then
    Result := '-'
  else
    Result := FloatStr(A / B, Decimals);
end;

{ A as a share of B, '-' when B is nothing }
function ShareOrDash(A, B: Double): AnsiString;
begin
  if B <= 0 then
    Result := '-'
  else
    Result := Pct(A, B);
end;

{ metric names separated by space, comma or semicolon; a trailing number is the page }
function MetricTokens(const Query: AnsiString; var Page: LongInt): TStringArray;
var
  Tokens: TStringArray;
  k, n: LongInt;
  Cur: AnsiString;
begin
  Tokens := nil;
  Cur := '';
  for k := 1 to Length(Query) + 1 do
    if (k > Length(Query)) or (Query[k] in [' ', ',', ';', #9]) then
    begin
      if Cur <> '' then
      begin
        n := Length(Tokens);
        SetLength(Tokens, n + 1);
        Tokens[n] := Cur;
        Cur := '';
      end;
    end
    else
      Cur := Cur + LowerCase(Query[k]);
  if (Length(Tokens) > 1) and (StrToIntDef(Tokens[High(Tokens)], -1) > 0) then
  begin
    Page := StrToIntDef(Tokens[High(Tokens)], Page);
    SetLength(Tokens, Length(Tokens) - 1);
  end;
  Result := Tokens;
end;

function WeaponSuffixId(const T, Sfx: AnsiString; Base: LongInt): LongInt;
var
  S: LongInt;
begin
  Result := -1;
  if (Length(T) > Length(Sfx)) and (Copy(T, Length(T) - Length(Sfx) + 1, Length(Sfx)) = Sfx) then
  begin
    S := WepSlot(ResolveWeapon(Copy(T, 1, Length(T) - Length(Sfx))));
    if S >= 0 then
      Result := Base + S;
  end;
end;

{ named metrics first, then <weapon>time / acc / hs / dmg, then <weapon> = kills with it }
function PlayerMetricId(const Token: AnsiString): LongInt;
var
  T: AnsiString;
begin
  T := LowerCase(Trim(Token));
  Result := MetricIndex(PLAYER_METRICS, T);
  if Result >= 0 then
    Exit;
  Result := WeaponSuffixId(T, 'time', MET_WEAPON_TIME);
  if Result < 0 then
    Result := WeaponSuffixId(T, 'acc', MET_WEAPON_ACC);
  if Result < 0 then
    Result := WeaponSuffixId(T, 'hs', MET_WEAPON_HS);
  if Result < 0 then
    Result := WeaponSuffixId(T, 'dmg', MET_WEAPON_DMG);
  if Result < 0 then
  begin
    Result := WepSlot(ResolveWeapon(T));
    if Result >= 0 then
      Result := MET_WEAPON_KILLS + Result;
  end;
end;

function PlayerMetricHeader(Id: LongInt): AnsiString;
begin
  if Id >= MET_WEAPON_DMG then
    Result := SlotShortName(Id - MET_WEAPON_DMG) + 'Dmg'
  else if Id >= MET_WEAPON_HS then
    Result := SlotShortName(Id - MET_WEAPON_HS) + 'HS'
  else if Id >= MET_WEAPON_ACC then
    Result := SlotShortName(Id - MET_WEAPON_ACC) + 'Ac%'
  else if Id >= MET_WEAPON_TIME then
    Result := SlotShortName(Id - MET_WEAPON_TIME) + 'Tm'
  else if Id >= MET_WEAPON_KILLS then
    Result := SlotShortName(Id - MET_WEAPON_KILLS)
  else
    Result := PLAYER_METRICS[Id].Header;
end;

function PlayerMetricFmt(Id: LongInt): TMetricFmt;
begin
  if Id >= MET_WEAPON_DMG then
    Result := mfDmg
  else if Id >= MET_WEAPON_HS then
    Result := mfInt
  else if Id >= MET_WEAPON_ACC then
    Result := mfPct
  else if Id >= MET_WEAPON_TIME then
    Result := mfTime
  else if Id >= MET_WEAPON_KILLS then
    Result := mfInt
  else
    Result := PLAYER_METRICS[Id].Fmt;
end;

function PlayerMetricAsc(Id: LongInt): Boolean;
begin
  Result := (Id >= 0) and (Id < MET_WEAPON_KILLS) and PLAYER_METRICS[Id].Asc;
end;

function SkillValue(E: TZSEngine; const P: TPlayerProfile; Family: LongInt): Double;
begin
  case E.RatingSystem of
    RS_GLICKO2:
      if P.Glicko[Family].Games > 0 then
        Result := GlickoConservative(P.Glicko[Family], E.Cfg.GlickoConservative)
      else
        Result := 0;
    RS_OPENSKILL:
      if P.OpenSkill[Family].Games > 0 then
        Result := OpenSkillOrdinal(P.OpenSkill[Family])
      else
        Result := 0;
    else
      { MMR; with elo (points) the MMR as well, like !topskill and the export }
      if P.Mmr[Family].Games > 0 then
        Result := P.Mmr[Family].R
      else
        Result := 0;
  end;
end;

function PlayerMetricValue(E: TZSEngine; const P: TPlayerProfile; Id: LongInt): Double;
var
  V: TWeaponView;
  M: TPointmatchMulti;
begin
  if Id >= MET_WEAPON_KILLS then
  begin
    if Id >= MET_WEAPON_DMG then
      V := WeaponView(P, Id - MET_WEAPON_DMG)
    else if Id >= MET_WEAPON_HS then
      V := WeaponView(P, Id - MET_WEAPON_HS)
    else if Id >= MET_WEAPON_ACC then
      V := WeaponView(P, Id - MET_WEAPON_ACC)
    else if Id >= MET_WEAPON_TIME then
      V := WeaponView(P, Id - MET_WEAPON_TIME)
    else
      V := WeaponView(P, Id - MET_WEAPON_KILLS);
    if Id >= MET_WEAPON_DMG then
      Result := V.Damage
    else if Id >= MET_WEAPON_HS then
      Result := V.Headshots
    { accuracy is for guns (CountsForAccuracy): melee has no shots, an explosion or a flame hurts
      several players or none; the others rank last instead of on top with 100% }
    else if Id >= MET_WEAPON_ACC then
    begin
      if CountsForAccuracy(SlotWeapon(Id - MET_WEAPON_ACC)) then
        Result := Min(100.0, SafeDivD(V.Hits * 100.0, V.Shots))
      else
        Result := 0;
    end
    else if Id >= MET_WEAPON_TIME then
      Result := V.Time
    else
      Result := V.Kills;
    Exit;
  end;
  M := P.PointmatchMode.Multi;
  case Id of
    0: Result := P.Points;
    1: Result := PerfRating(E, P);
    2: Result := E.Cfg.RankTierCount - 1 - TierIndex(E.Cfg, P, PerfRating(E, P), E.CurrentFamily, E.RatingSystem);
    3: Result := SkillValue(E, P, E.CurrentFamily);
    4: Result := P.Kills;
    5: Result := P.Deaths;
    6: Result := P.Kills / Max(1, P.Deaths);
    7: Result := P.Selfkills;
    8: Result := P.Assist;
    9: Result := Max(P.Shots, P.ShotsHits);
    10: Result := P.ShotsHits;
    11: Result := Min(100.0, SafeDivD(P.ShotsHits * 100.0, Max(P.Shots, P.ShotsHits)));
    12: Result := P.DamageDealt;
    13: Result := P.DamageReceived;
    14: Result := SafeDivD(P.DamageDealt, P.DamageReceived);
    15: Result := P.DamageDealt / Max(1, E.EffectiveMaxHealth);
    16: Result := P.DamageReceived / Max(1, E.EffectiveMaxHealth);
    17: Result := P.DamageFriendly;
    18: Result := P.DamageFriendlyReceived;
    19: Result := P.LongestKillDistance;
    20: Result := P.LongestBarrettDistance;
    21: Result := SafeDivD(P.TotalKillDistance, P.KillDistanceCount);
    22: Result := P.LongKills100;
    23: Result := P.BarrettLongKills;
    24: Result := P.ShotsHitsHead;
    25: Result := SafeDivD(P.ShotsHitsHead * 100.0, P.ShotsHits);
    26: Result := P.ShotsHitsBody;
    27: Result := SafeDivD(P.ShotsHitsBody * 100.0, P.ShotsHits);
    28: Result := P.ShotsHitsLeg;
    29: Result := SafeDivD(P.ShotsHitsLeg * 100.0, P.ShotsHits);
    30: Result := P.MaxKillStreak;
    31: Result := M.DOUBLE_KILL;
    32: Result := M.TRIPLE_KILL;
    33: Result := M.MULTI_KILL;
    34: Result := M.MULTI_KILL_X2;
    35: Result := M.SERIAL_KILL;
    36: Result := M.INSANE_KILLS;
    37: Result := M.INSANE_KILLS + M.SERIAL_KILL + M.MULTI_KILL_X2;
    38: Result := M.GIMME_MORE;
    39: Result := M.MASTA_KILLA;
    40: Result := M.STOP_IT;
    41: Result := M.MERCY;
    42: Result := M.CHEATER;
    43: Result := P.FirstBloodCount;
    44: Result := P.FirstDamageCount;
    45: Result := P.LastStand;
    46: Result := P.ClutchesWon;
    47: Result := P.DominatingCount;
    48: Result := P.RevengeFeats + P.RevengeKills;
    49: Result := P.PosthumousKills;
    50: Result := P.SaviorKills;
    51: Result := P.AvengerKills;
    52: Result := P.PointmatchMode.ExtraPoints;
    53: Result := P.FlagsScore;
    54: Result := P.FlagsReturn;
    55: Result := P.FlagsGrab;
    56: Result := P.FlagsDrop;
    57: Result := P.FlaggerKills;
    58: Result := P.FlaggerKillsAssist;
    59: Result := P.SaviorFlaggerKills;
    60: Result := P.TimeHoldingFlags;
    61: Result := P.KillsWhenHaveFlag;
    62: Result := P.FastestCapSeconds;
    63: Result := P.CarrierEscortKills;
    64: Result := P.FlagJuggles;
    65: Result := P.ContestedHolds;
    66: Result := P.CapsUnder10s;
    67: Result := P.HTFMode.PointsScored;
    68: Result := P.HTFMode.TimeWhenHaveFlag;
    69: Result := P.HTFMode.TimeWhenTeamHaveFlag;
    70: Result := P.Wins;
    71: Result := P.Loses;
    72: Result := P.Draws;
    73: Result := SafeDivD(P.Wins * 100.0, P.Wins + P.Loses);
    74: Result := P.RoundsWins;
    75: Result := P.RoundsLose;
    76: Result := SafeDivD(P.RoundsWins * 100.0, P.RoundsWins + P.RoundsLose);
    77: Result := P.RoundsWins / Max(1, P.RoundsLose);
    78: Result := P.AdvanceRoundsPlayed;
    79: Result := P.AdvanceRoundsWon;
    80: Result := P.ComebackWins;
    81: Result := P.LeaveLosses;
    82: Result := P.TimePlayed;
    83: Result := P.TimeAlive;
    84: Result := P.TimeAlive / Max(Int64(1), LivesEnded(P));
    85: Result := P.TimeDeath;
    86: Result := P.TimeOnSpectator;
    87: Result := P.LongestLifeSec;
    88: Result := P.DaysPlayed;
    89: Result := P.ProtectionDays;
    90: Result := SafeDivD(P.Kills * 3600.0, P.TimePlayed);
    91: Result := P.DistanceTraveledM / 1000;
    92: Result := P.JetFlyTimeSeconds;
    93: Result := P.Teamkills;
    94: Result := P.DeathsByFriendly;
    95: Result := P.ShotsHitsFriendly;
    96: Result := P.ShotsHitsByFriendly;
    97: Result := P.TopVictims[0].KillCount;
    98: Result := P.TopNemeses[0].KillCount;
    99: Result := P.KnivesStabsEnemy;
    100: Result := P.KnivesThrows;
    101: Result := P.KnivesThrowsHitsEnemy;
    102: Result := SafeDivD(P.KnivesThrowsHitsEnemy * 100.0, P.KnivesThrows);
    103: Result := P.ChainsawHurtsEnemy;
    104: Result := Max(Int64(P.ChainsawTimeUsedSeconds), P.Weapons[WEP_CHAINSAW].TimeUsedSeconds);
    105: Result := P.NadesThrows;
    106: Result := P.NadeHurtsEnemy;
    107: Result := SafeDivD(P.NadeHurtsEnemy * 100.0, P.NadesThrows);
    108: Result := P.ClusterNadesThrows;
    109: Result := P.ClusterNadesHurtsEnemy;
    110: Result := P.HandsHurtsEnemy;
    111: Result := P.M79Shots;
    112: Result := P.M79HurtsEnemy;
    113: Result := SafeDivD(P.M79HurtsEnemy * 100.0, P.M79Shots);
    114: Result := P.M72LAWShots;
    115: Result := P.M72LAWHurtsEnemy;
    116: Result := SafeDivD(P.M72LAWHurtsEnemy * 100.0, P.M72LAWShots);
    117: Result := P.FlamethrowerShots;
    118: Result := P.FlamethrowerHitsEnemy;
    119: Result := SafeDivD(P.FlamethrowerHitsEnemy * 100.0, P.FlamethrowerShots);
    120: Result := P.M2MGHitsEnemy;
    121: Result := P.RamboMode.KillRamboCount;
    122: Result := Max(P.RamboMode.KillsByBow, P.Weapons[WEP_BOW].Kills);
    123: Result := P.RamboMode.TimeWithBow;
    124: Result := P.ProneKills;
    125: Result := P.CampKills;
    126: Result := P.BinkRecoveryKills;
    127: Result := P.AirKills;
    128: Result := P.HeightKills;
    129: Result := P.VestKills;
    130: Result := P.GrenadeKills;
    131: Result := P.ExplosionMultiKills;
    132: Result := P.KnifeKillsLifeBest;
    133: Result := P.SpawnKills;
    134: Result := P.SpawnDeaths;
    135: Result := SafeDivD(P.TTKSumTicks, P.TTKCount) / TICKS_PER_SECOND;
    136: Result := P.BestTTKTicks / TICKS_PER_SECOND;
    137: Result := P.SpreeKills;
    138: Result := P.RampageKills;
    139: Result := P.DominatingSpreeKills;
    140: Result := P.UnstoppableKills;
    141: Result := P.GodlikeKills;
    142: Result := P.ShutDownKills;
    143: Result := P.FinisherKills;
    144: Result := P.SeasonPoints;
    145: Result := Length(P.Achievements);
    146: Result := Length(P.Badges);
    147: Result := P.WallKills;
    148:
      if P.Mmr[E.CurrentFamily].Games > 0 then
        Result := P.Mmr[E.CurrentFamily].R
      else
        Result := 0;
    149:
      if P.Glicko[E.CurrentFamily].Games > 0 then
        Result := GlickoConservative(P.Glicko[E.CurrentFamily], E.Cfg.GlickoConservative)
      else
        Result := 0;
    150:
      if P.OpenSkill[E.CurrentFamily].Games > 0 then
        Result := OpenSkillOrdinal(P.OpenSkill[E.CurrentFamily])
      else
        Result := 0;
    151: Result := P.ForcedSelfkills;
    152: Result := P.SelfkillsUnderFire;
    153: Result := P.CoverShotKills;
    154: Result := P.BalanceMoves;
    155: Result := P.BalanceVolunteers;
    156: Result := P.HealRegen + P.HealKits;
    157: Result := P.HealRegen;
    158: Result := P.HealKitCount;
    159: Result := KitsPickedUp(P);
    { the kits of one kind, in the order of KIT_KIND_STYLES }
    160..166: Result := P.KitPickups[Id - 160];
    else Result := 0;
  end;
end;

function PlayerMetricText(E: TZSEngine; Id: LongInt; V: Double): AnsiString;
var
  T: LongInt;
begin
  if PlayerMetricFmt(Id) = mfTier then
  begin
    T := E.Cfg.RankTierCount - 1 - Round(V);
    if (T >= 0) and (T < E.Cfg.RankTierCount) then
      Result := E.Cfg.RankTiers[T].Name
    else
      Result := '-';
  end
  else
    Result := MetricText(PlayerMetricFmt(Id), V);
end;

function IsPlayerMetricList(const Query: AnsiString): Boolean;
var
  Tokens: TStringArray;
  Page: LongInt;
begin
  Page := 1;
  Tokens := MetricTokens(Query, Page);
  Result := (Length(Tokens) > 0) and (PlayerMetricId(Tokens[0]) >= 0);
end;

{ the name column and the columns of 2-5 metrics after the 5 of the place: together LINE_W }
procedure ColumnWidths(Count: LongInt; out NameW: LongInt; var Widths: array of LongInt);
var
  k: LongInt;
begin
  case Count of
    2: begin NameW := 29; Widths[0] := 33; Widths[1] := 33; end;
    3: begin NameW := 26; Widths[0] := 23; Widths[1] := 23; Widths[2] := 23; end;
    4: begin NameW := 23; Widths[0] := 18; Widths[1] := 18; Widths[2] := 18; Widths[3] := 18; end;
    else
      begin
        NameW := 20;
        for k := 0 to High(Widths) do
          Widths[k] := 15;
      end;
  end;
end;

{ "A > B > C" for the title of a list by metrics, with as many of the headers as keep it within
  MaxLen: five long headers and the words around them would push the title out of its frame, so
  the ones that do not fit become " > ..." }
function MetricTitle(const Headers: array of AnsiString; MaxLen: LongInt): AnsiString;
var
  k, Room: LongInt;
begin
  Result := '';
  for k := 0 to High(Headers) do
  begin
    if k = 0 then
    begin
      Result := Headers[0];
      Continue;
    end;
    { room for the " > ..." of the headers after this one }
    Room := 0;
    if k < High(Headers) then
      Room := 6;
    if Length(Result) + 3 + Length(Headers[k]) + Room > MaxLen then
    begin
      Result := Result + ' > ...';
      Exit;
    end;
    Result := Result + ' > ' + Headers[k];
  end;
end;

{ ---------------- points ranking ---------------- }

{ the tier of an entry: this server's, '-' for a player of the other servers only }
function EntryTier(E: TZSEngine; Idx: LongInt): AnsiString;
begin
  if Idx >= 0 then
    Result := E.PlainTierName(Idx)
  else
    Result := '-';
end;

procedure TopRows(E: TZSEngine; Slot: LongInt; const Title: AnsiString; const Order: TRankEntryArray;
  First, Last, Mark: LongInt);
const
  { place, nick, tier, points, rating, K/D, kills, deaths (+ the mark): at most 90 of LINE_W }
  C: array[0..7] of LongInt = (5, 24, 16, 9, 9, 8, 8, 8);
var
  r, Idx, Me, Color: LongInt;
  P: PPlayerProfile;
  Tmp: TPlayerProfile;
  Suffix: AnsiString;
begin
  Header(E, Slot, Title, LINE_W);
  Row(E, Slot, ['#', 'Nick', 'Tier', 'Points', 'Rating', 'K/D', 'Kills', 'Deaths'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  Me := ViewerIndex(E, Slot);
  for r := First to Last do
  begin
    Idx := Order[r - 1].Idx;
    P := RankingView(E, Order[r - 1], Tmp);
    if P = nil then
      Continue;
    Suffix := '';
    if (Idx >= 0) and (Idx = Me) then
      Suffix := ' <YOU>';
    Color := RowColor(r, (Idx >= 0) and (Idx = Me));
    if r = Mark then
    begin
      { the own row keeps <YOU>, which marks it already }
      if Suffix = '' then
        Suffix := ' <*>';
      if (Idx < 0) or (Idx <> Me) then
        Color := CLR_SUBHEADER;
    end;
    Row(E, Slot, [IntToStr(r), Copy(P^.ActiveName, 1, C[1] - 1), Copy(EntryTier(E, Idx), 1, C[2] - 1), Num(P^.Points),
      FloatStr(PerfRating(E, P^), 1), KD(P^.Kills, P^.Deaths), Num(P^.Kills), Num(P^.Deaths) + Suffix], C, Color);
  end;
end;

procedure ListTop(E: TZSEngine; Slot, Page: LongInt);
var
  PerPage, Count, Pages, First: LongInt;
  Order: TRankEntryArray;
begin
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Order := RankingOrder(E);
  Count := Length(Order);
  if Count = 0 then
  begin
    Out(E, Slot, 'No players in the ranking yet.', CLR_HEADER);
    Exit;
  end;
  Pages := PageCount(Count, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage + 1;
  TopRows(E, Slot, Format('Top Ranking%s [Page %d/%d] (Total: %d)', [AllServers(E), Page, Pages, Count]), Order,
    First, Min(Count, First + PerPage - 1), 0);
  PageHint(E, Slot, Page, Pages, 'players');
  Remember(E, Slot, QK_TOP, '', Page, Pages);
end;

procedure ListTopAround(E: TZSEngine; Slot, Rank: LongInt);
var
  PerPage, Count, First, Last: LongInt;
  Order: TRankEntryArray;
begin
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Order := RankingOrder(E);
  Count := Length(Order);
  if Count = 0 then
  begin
    Out(E, Slot, 'No players in the ranking yet.', CLR_HEADER);
    Exit;
  end;
  Rank := EnsureRange(Rank, 1, Count);
  First := Max(1, Rank - PerPage div 2);
  Last := Min(Count, First + PerPage - 1);
  First := Max(1, Last - PerPage + 1);
  TopRows(E, Slot, Format('Top Ranking%s [Rank #%d-%d of %d]', [AllServers(E), First, Last, Count]), Order, First, Last, Rank);
  Out(E, Slot, 'Move with /zs_next and /zs_prev, or jump with !topi <position>.', CLR_HINT);
  Remember(E, Slot, QK_TOP, '', (First - 1) div PerPage + 1, PageCount(Count, PerPage));
end;

procedure ListTopOnline(E: TZSEngine; Slot: LongInt);
const
  { place, nick, tier, points, rank, rating, K/D, kills: 88 of LINE_W }
  C: array[0..7] of LongInt = (5, 24, 16, 9, 9, 9, 8, 8);
var
  List, Pts: array[0..MAX_PLAYERS - 1] of LongInt;
  n, S, Idx, i, j, T, V: LongInt;
  P: PPlayerProfile;
  RankCell: AnsiString;
begin
  n := 0;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human then
    begin
      Idx := E.Identity.ProfileIndex(S);
      if E.DB.Valid(Idx) then
      begin
        List[n] := Idx;
        Inc(n);
      end;
    end;
  if n = 0 then
  begin
    Out(E, Slot, 'No players online.', CLR_HEADER);
    Exit;
  end;
  for i := 0 to n - 1 do
    Pts[i] := RankingPoints(E, List[i]);
  for i := 1 to n - 1 do
  begin
    T := List[i];
    V := Pts[i];
    j := i - 1;
    while (j >= 0) and (Pts[j] < V) do
    begin
      List[j + 1] := List[j];
      Pts[j + 1] := Pts[j];
      Dec(j);
    end;
    List[j + 1] := T;
    Pts[j + 1] := V;
  end;
  Header(E, Slot, Format('Online Ranking (%d Players)', [n]), LINE_W);
  Row(E, Slot, ['#', 'Nick', 'Tier', 'Points', 'Rank', 'Rating', 'K/D', 'Kills'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for i := 0 to n - 1 do
  begin
    P := E.DB.Profiles[List[i]];
    { an account not in the ranking (yet) has no place: '-', not '#-' }
    RankCell := RankText(E, List[i]);
    if RankCell <> '-' then
      RankCell := '#' + RankCell;
    Row(E, Slot, [IntToStr(i + 1), Copy(P^.ActiveName, 1, C[1] - 1), Copy(E.PlainTierName(List[i]), 1, C[2] - 1), Num(Pts[i]),
      RankCell, FloatStr(PerfRating(E, P^), 1), KD(P^.Kills, P^.Deaths), Num(P^.Kills)], C,
      RowColor(i + 1, List[i] = ViewerIndex(E, Slot)));
  end;
  if RankingShared(E) then
    Out(E, Slot, 'Sorted by the points of every server; Rank is the place in the ranking of all servers.', CLR_HINT)
  else
    Out(E, Slot, 'Sorted by points; Rank is the place in the whole ranking.', CLR_HINT);
end;

{ ---------------- custom metric leaderboards ---------------- }

procedure TopByHelp(E: TZSEngine; Slot: LongInt);
begin
  Header(E, Slot, 'ZitroStats Custom Leaderboards - !topby Help', LINE_W);
  Out(E, Slot, 'Usage: !topby <metric1;metric2;...> [page]  (up to 5, separated by , ; or space)', CLR_HINT);
  Out(E, Slot, 'Sorted by the first metric, ties broken by the next ones.', CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  Out(E, Slot, '[Core & Rating] points, rating, tier, skill, kills, deaths, kdr, assists, selfkills, forced,', CLR_HEADER);
  Out(E, Slot, '  underfire, mmr, glicko, openskill, cover, covershot, favvictim, nemesis', CLR_HEADER);
  Out(E, Slot, '[Accuracy & Damage] shots, hits, acc, hs, hsacc, body, bodyacc, legs, legacc, dmg, dmgtaken,', CLR_COMBAT);
  Out(E, Slot, '  dmgratio, dmgkills, dmgdeaths, tkdmg, tkdmgrec', CLR_COMBAT);
  Out(E, Slot, '[Healing & Kits] healed, regen, healkits (kits that healed), kits (every kit picked up), medkits,',
    CLR_COMBAT);
  Out(E, Slot, '  nadekits, clusterkits, vestkits, berserkkits, predatorkits, flamerkits', CLR_COMBAT);
  Out(E, Slot, '[Distance & Timing] longkill, barretkill, avgdist, long100, barrettlong, ttk, bestttk, longestlife', CLR_SHOOTING);
  Out(E, Slot, '[Streaks & Feats] maxstreak, streak5, streak10, streak15, streak20, streak25, shutdowns,', CLR_FEATS);
  Out(E, Slot, '  finishers, firstblood, firstdmg, laststand, clutches, dom, revenge, posthumous, savior, avenger', CLR_FEATS);
  Out(E, Slot, '[Movement] prone, camp, bink, airkills, heightkills, vestkills, spawnkills, spawndeaths, flytime', CLR_MATCHES);
  Out(E, Slot, '[Objectives] caps, returns, grabs, drops, fkills, flagassist, fdefense, flagtime, killswithflag,', CLR_OBJECTIVE);
  Out(E, Slot, '  fastcap, fastcaps, escort, juggles, contested, htfpoints, htftime, htfteamtime', CLR_OBJECTIVE);
  Out(E, Slot, '[Matches] wins, losses, draws, winrate, rwins, rlost, roundwr, roundratio, advrounds, advwins,', CLR_SUBHEADER);
  Out(E, Slot, '  comebacks, leaverlosses, pmscore, balmoves, volunteered (the team balance)', CLR_SUBHEADER);
  Out(E, Slot, '[Activity] time, timealive, lifespan, timedead, spec, days, protect, pace, traveled, seasonpoints,', CLR_ACTIVITY);
  Out(E, Slot, '  achievements, badges', CLR_ACTIVITY);
  Out(E, Slot, '[Multi-Kills] double, triple, multi, multix2, serial, insane, multi57, gimme, masta, stopit,', CLR_TOP2);
  Out(E, Slot, '  mercy, cheater, explomulti', CLR_TOP2);
  Out(E, Slot, '[Weapons] socom deagle mp5 ak aug spas ruger m79 barrett minimi minigun knife saw law flamer bow', CLR_TOP1);
  Out(E, Slot, '  grenade = kills; add time/acc/hs/dmg: aktime, spasacc, barretths, lawdmg', CLR_TOP1);
  Out(E, Slot, '[Special] stabs, throws, knifehits, knifeacc, knifestreak, sawhits, sawtime, nades, nadehits,', CLR_TEAMPLAY);
  Out(E, Slot, '  nadeacc, nadekills, cluster, clusterhits, m79shots, m79hits, m79acc, lawshots, lawhits, lawacc,', CLR_TEAMPLAY);
  Out(E, Slot, '  flamershots, flamerhits, flameracc, rambo, bowkills, bowtime, tk, tked, friendlyhits,', CLR_TEAMPLAY);
  Out(E, Slot, '  friendlyhitsby, statgun = stationary gun hits, fists = punch hits', CLR_TEAMPLAY);
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'Example: !topby rating;kdr  or  !topby dmg,kills,acc 2', CLR_HINT);
end;

procedure ListTopBy(E: TZSEngine; Slot: LongInt; const Query: AnsiString; Page: LongInt);
const
  PER_PAGE = 15;
  { one metric: place 5, nick, tier, the metric, points 9, rating 9, K/D 8 and kills - 90 of LINE_W }
  NICK_W = 24;
  TIER_W = 16;
  METRIC_W = 14;
var
  Tokens, Heads: TStringArray;
  Ids, Rows: TIntArray;
  Widths: array[0..4] of LongInt;
  k, f, n, Pages, First, Last, NameW, Me, Idx: LongInt;
  Ignored, Canon, Title, Line: AnsiString;
  P: PPlayerProfile;
  Tmp: TPlayerProfile;
  Entries: TRankEntryArray;
  ShowTier, ShowPoints, ShowRating, ShowKD, ShowKills: Boolean;
begin
  Tokens := MetricTokens(Query, Page);
  Ids := nil;
  Ignored := '';
  Canon := '';
  for k := 0 to High(Tokens) do
  begin
    f := PlayerMetricId(Tokens[k]);
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
    Out(E, Slot, 'No valid metric given.', CLR_BAD);
    if Ignored <> '' then
      Out(E, Slot, '[Note] Unknown: ' + Ignored, CLR_HINT);
    TopByHelp(E, Slot);
    Exit;
  end;

  { the accounts of this server, and with SharedRankings of every server }
  Entries := RankingEntries(E);
  n := Length(Entries);
  if n = 0 then
  begin
    Out(E, Slot, 'No players yet.', CLR_HEADER);
    Exit;
  end;
  PrepareSort(n, Length(Ids));
  for k := 0 to n - 1 do
  begin
    P := RankingView(E, Entries[k], Tmp);
    for f := 0 to High(Ids) do
      if P = nil then
        SortKeys[k * SortCols + f] := -MaxDouble
      else
        SortKeys[k * SortCols + f] := SortValue(PlayerMetricValue(E, P^, Ids[f]), PlayerMetricAsc(Ids[f]));
    SortTie[k] := Entries[k].Points;
  end;
  Pages := PageCount(n, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Last := Min(n - 1, First + PER_PAGE - 1);
  Rows := BestRows(n, Last + 1);
  Me := ViewerIndex(E, Slot);
  Heads := nil;
  SetLength(Heads, Length(Ids));
  for f := 0 to High(Ids) do
    Heads[f] := PlayerMetricHeader(Ids[f]);
  Title := Format('%s [Page %d/%d]', [AllServers(E), Page, Pages]);
  Header(E, Slot, 'Top by ' + MetricTitle(Heads, LINE_W - 4 - Length('Top by ' + Title)) + Title, LINE_W);
  if Length(Ids) = 1 then
  begin
    { the fixed columns leave out whatever the list is already sorted by }
    ShowTier := Ids[0] <> PlayerMetricId('tier');
    ShowPoints := Ids[0] <> PlayerMetricId('points');
    ShowRating := Ids[0] <> PlayerMetricId('rating');
    ShowKD := Ids[0] <> PlayerMetricId('kdr');
    ShowKills := Ids[0] <> PlayerMetricId('kills');
    Line := PadR('#', 5) + PadR('Nick', NICK_W);
    if ShowTier then
      Line := Line + PadR('Tier', TIER_W);
    Line := Line + PadR(PlayerMetricHeader(Ids[0]), METRIC_W);
    if ShowPoints then
      Line := Line + PadR('Points', 9);
    if ShowRating then
      Line := Line + PadR('Rating', 9);
    if ShowKD then
      Line := Line + PadR('K/D', 8);
    if ShowKills then
      Line := Line + 'Kills';
    Out(E, Slot, TrimRight(Line), CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
    for k := First to Last do
    begin
      Idx := Entries[Rows[k]].Idx;
      P := RankingView(E, Entries[Rows[k]], Tmp);
      if P = nil then
        Continue;
      Line := PadR(IntToStr(k + 1), 5) + PadR(Copy(P^.ActiveName, 1, NICK_W - 1), NICK_W);
      { the tier of the lists, as in !top (and as the metric tier sorts) }
      if ShowTier then
        Line := Line + PadR(Copy(EntryTier(E, Idx), 1, TIER_W - 1), TIER_W);
      Line := Line + PadR(Copy(PlayerMetricText(E, Ids[0], PlayerMetricValue(E, P^, Ids[0])), 1, METRIC_W - 1), METRIC_W);
      if ShowPoints then
        Line := Line + PadR(Num(P^.Points), 9);
      if ShowRating then
        Line := Line + PadR(FloatStr(PerfRating(E, P^), 1), 9);
      if ShowKD then
        Line := Line + PadR(KD(P^.Kills, P^.Deaths), 8);
      if ShowKills then
        Line := Line + Num(P^.Kills);
      Out(E, Slot, TrimRight(Line), RowColor(k + 1, (Idx >= 0) and (Idx = Me)));
    end;
  end
  else
  begin
    ColumnWidths(Length(Ids), NameW, Widths);
    Line := PadR('#', 5) + PadR('Nick', NameW);
    for f := 0 to High(Ids) do
      Line := Line + PadR(PlayerMetricHeader(Ids[f]), Widths[f]);
    Out(E, Slot, TrimRight(Line), CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
    for k := First to Last do
    begin
      Idx := Entries[Rows[k]].Idx;
      P := RankingView(E, Entries[Rows[k]], Tmp);
      if P = nil then
        Continue;
      Line := PadR(IntToStr(k + 1), 5) + PadR(Copy(P^.ActiveName, 1, NameW - 1), NameW);
      for f := 0 to High(Ids) do
        Line := Line + PadR(Copy(PlayerMetricText(E, Ids[f], PlayerMetricValue(E, P^, Ids[f])), 1, Widths[f] - 1), Widths[f]);
      Out(E, Slot, TrimRight(Line), RowColor(k + 1, (Idx >= 0) and (Idx = Me)));
    end;
  end;
  if Ignored <> '' then
    Out(E, Slot, '[Note] Ignored unknown metric(s): ' + Ignored, CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'players');
  Remember(E, Slot, QK_TOPBY, Canon, Page, Pages);
end;

{ ---------------- skill ratings, seasons, periods ---------------- }

procedure ListTopSkill(E: TZSEngine; Slot, Page: LongInt);
const
  { place, nick, skill, games, points, K/D, kills: 80 of LINE_W }
  C: array[0..6] of LongInt = (5, 27, 11, 9, 10, 9, 9);
var
  F, L, Count, PerPage, Pages, First, r, Idx, Me, Games, Decimals: LongInt;
  P: PPlayerProfile;
begin
  if E.RatingSystem = RS_ELO then
  begin
    Out(E, Slot, Format('The ranking uses points (RankingSystem = elo); this is the MMR list of %s modes.',
      [FamilyName(E.CurrentFamily)]), CLR_HINT);
    ListTopBy(E, Slot, 'mmr', Page);
    Exit;
  end;
  F := E.CurrentFamily;
  L := RANK_RATING_FFA + F;
  Count := E.DB.Ranks[L].Count;
  if Count = 0 then
  begin
    Out(E, Slot, Format('No rated %s matches yet.', [FamilyName(F)]), CLR_HEADER);
    Exit;
  end;
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Pages := PageCount(Count, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage + 1;
  Me := ViewerIndex(E, Slot);
  Header(E, Slot, Format('Top %s %s [Page %d/%d] (Total: %d)', [SkillSystemName(E), FamilyName(F), Page, Pages, Count]), LINE_W);
  Row(E, Slot, ['#', 'Nick', 'Skill', 'Games', 'Points', 'K/D', 'Kills'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for r := First to Min(Count, First + PerPage - 1) do
  begin
    Idx := E.DB.Ranks[L].At(r);
    if not E.DB.Valid(Idx) then
      Continue;
    P := E.DB.Profiles[Idx];
    Decimals := 0;
    case E.RatingSystem of
      RS_GLICKO2: Games := P^.Glicko[F].Games;
      RS_MMR: Games := P^.Mmr[F].Games;
      else
        begin
          Games := P^.OpenSkill[F].Games;
          Decimals := 1;
        end;
    end;
    Row(E, Slot, [IntToStr(r), Copy(P^.ActiveName, 1, C[1] - 1), FloatStr(SkillValue(E, P^, F), Decimals), Num(Games),
      Num(P^.Points), KD(P^.Kills, P^.Deaths), Num(P^.Kills)], C, RowColor(r, Idx = Me));
  end;
  PageHint(E, Slot, Page, Pages, 'players');
  Remember(E, Slot, QK_TOPSKILL, '', Page, Pages);
end;

procedure ListTopSeason(E: TZSEngine; Slot: LongInt; const Arg: AnsiString; Page: LongInt);
const
  { place, nick, season points, points, K/D, caps, wins, time: 90 of LINE_W }
  C: array[0..7] of LongInt = (5, 27, 10, 10, 9, 9, 9, 11);
var
  Id, k, S, Count, PerPage, Pages, First, r, Idx, Me, MeId: LongInt;
  P: PPlayerProfile;
  SE: ^TSeasonEntry;
begin
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Id := StrToIntDef(Trim(Arg), 0);
  if Id > 0 then
  begin
    S := -1;
    for k := 0 to High(E.DB.Seasons) do
      if E.DB.Seasons[k].Id = Id then
        S := k;
    if S < 0 then
    begin
      Out(E, Slot, 'No archived season with that number.', CLR_BAD);
      if Length(E.DB.Seasons) > 0 then
        Out(E, Slot, Format('Archived seasons: %d-%d', [E.DB.Seasons[0].Id, E.DB.Seasons[High(E.DB.Seasons)].Id]), CLR_HINT);
      Exit;
    end;
    Count := Length(E.DB.Seasons[S].Entries);
    Pages := PageCount(Count, PerPage);
    Page := EnsureRange(Page, 1, Pages);
    First := (Page - 1) * PerPage;
    { the entries of an archived season keep the account number: the viewer's own row is marked }
    Me := ViewerIndex(E, Slot);
    if E.DB.Valid(Me) then
      MeId := E.DB.Profiles[Me]^.ID
    else
      MeId := 0;
    Header(E, Slot, Format('Season %d  %s - %s [Page %d/%d]', [Id, FormatDateTime('yyyy-mm-dd', E.DB.Seasons[S].StartDate),
      FormatDateTime('yyyy-mm-dd', E.DB.Seasons[S].EndDate), Page, Pages]), LINE_W);
    if Count = 0 then
      Out(E, Slot, 'Nobody played in this season.', CLR_HINT)
    else
    begin
      Row(E, Slot, ['#', 'Nick', 'Season', 'Points', 'K/D', 'Caps', 'Wins', 'Time'], C, CLR_SUBHEADER);
      Rule(E, Slot, LINE_W);
    end;
    for k := First to Min(Count - 1, First + PerPage - 1) do
    begin
      SE := @E.DB.Seasons[S].Entries[k];
      Row(E, Slot, [IntToStr(SE^.Place), Copy(SE^.Name, 1, C[1] - 1), SignedShort(SE^.SeasonPoints), Num(SE^.Points),
        KD(SE^.Kills, SE^.Deaths), Num(SE^.Caps), Num(SE^.Wins), FormatDurationShort(SE^.TimePlayed)], C,
        RowColor(SE^.Place, (MeId <> 0) and (SE^.ProfileId = MeId)));
    end;
    PageHint(E, Slot, Page, Pages, 'players');
    Remember(E, Slot, QK_TOPSEASON, IntToStr(Id), Page, Pages);
    Exit;
  end;

  if E.DB.Server.SeasonId <= 0 then
  begin
    Out(E, Slot, 'No season is running on this server.', CLR_WARN);
    Exit;
  end;
  Count := E.DB.Ranks[RANK_SEASON].Count;
  Pages := PageCount(Count, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage + 1;
  Me := ViewerIndex(E, Slot);
  Header(E, Slot, Format('Season %d - ends %s [Page %d/%d]', [E.DB.Server.SeasonId, FormatDateTime('yyyy-mm-dd', E.DB.Server.SeasonEnd),
    Page, Pages]), LINE_W);
  if Count = 0 then
    Out(E, Slot, 'Nobody has played in this season yet.', CLR_HINT)
  else
  begin
    Row(E, Slot, ['#', 'Nick', 'Season', 'Points', 'K/D', 'Caps', 'Wins', 'Time'], C, CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
    for r := First to Min(Count, First + PerPage - 1) do
    begin
      Idx := E.DB.Ranks[RANK_SEASON].At(r);
      if not E.DB.Valid(Idx) then
        Continue;
      P := E.DB.Profiles[Idx];
      Row(E, Slot, [IntToStr(r), Copy(P^.ActiveName, 1, C[1] - 1), SignedShort(P^.SeasonPoints), Num(P^.Points),
        KD(P^.SeasonKills, P^.SeasonDeaths), Num(P^.SeasonCaps), Num(P^.SeasonWins), FormatDurationShort(P^.SeasonTime)], C,
        RowColor(r, Idx = Me));
    end;
  end;
  if Length(E.DB.Seasons) > 0 then
    Out(E, Slot, Format('Past seasons: !topseason <%d-%d>', [E.DB.Seasons[0].Id, E.DB.Seasons[High(E.DB.Seasons)].Id]), CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'players');
  Remember(E, Slot, QK_TOPSEASON, '', Page, Pages);
end;

{ every season, newest first, so the number for !topseason can be looked up, with the podium: the
  final one of an archived season, the current standings of the running one }
procedure ListSeasons(E: TZSEngine; Slot, Page: LongInt);
const
  PER_PAGE = 10;
  { id, from, to and the three places: 96 of LINE_W }
  C: array[0..5] of LongInt = (6, 12, 12, 22, 22, 22);
var
  Count, Pages, First, Shown, k, Pos, Place, Idx: LongInt;
  Podium: array[1..3] of AnsiString;

  procedure SeasonLine(const Id: AnsiString; StartT, EndT: Double; Color: LongInt);
  begin
    Row(E, Slot, [Id, DateText(StartT, 'yyyy-mm-dd'), DateText(EndT, 'yyyy-mm-dd'), Copy(Podium[1], 1, C[3] - 1),
      Copy(Podium[2], 1, C[4] - 1), Copy(Podium[3], 1, C[5] - 1)], C, Color);
  end;

begin
  Count := Length(E.DB.Seasons);
  if E.DB.Server.SeasonId > 0 then
    Inc(Count);
  if Count = 0 then
  begin
    Out(E, Slot, 'No seasons yet ([Seasons] Enabled starts them).', CLR_WARN);
    Exit;
  end;
  Pages := PageCount(Count, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Header(E, Slot, Format('Seasons [Page %d/%d]', [Page, Pages]), LINE_W);
  Row(E, Slot, ['ID', 'From', 'To', '1st place', '2nd place', '3rd place'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  Pos := 0;
  Shown := 0;
  if E.DB.Server.SeasonId > 0 then
  begin
    if (Pos >= First) and (Shown < PER_PAGE) then
    begin
      for Place := 1 to 3 do
      begin
        Podium[Place] := '-';
        if Place <= E.DB.Ranks[RANK_SEASON].Count then
        begin
          Idx := E.DB.Ranks[RANK_SEASON].At(Place);
          if E.DB.Valid(Idx) then
            Podium[Place] := E.DB.Profiles[Idx]^.ActiveName;
        end;
      end;
      SeasonLine(IntToStr(E.DB.Server.SeasonId) + '*', E.DB.Server.SeasonStart, E.DB.Server.SeasonEnd, CLR_YOU);
      Inc(Shown);
    end;
    Inc(Pos);
  end;
  for k := High(E.DB.Seasons) downto 0 do
  begin
    if (Pos >= First) and (Shown < PER_PAGE) then
    begin
      for Place := 1 to 3 do
        if Place <= Length(E.DB.Seasons[k].Entries) then
          Podium[Place] := E.DB.Seasons[k].Entries[Place - 1].Name
        else
          Podium[Place] := '-';
      SeasonLine(IntToStr(E.DB.Seasons[k].Id), E.DB.Seasons[k].StartDate, E.DB.Seasons[k].EndDate, RowColor(Pos + 1, False));
      Inc(Shown);
    end;
    Inc(Pos);
  end;
  Out(E, Slot, '* = running now, current standings.  One season in detail: !topseason <ID>', CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'seasons');
  Remember(E, Slot, QK_SEASONS, '', Page, Pages);
end;

procedure ListTopPeriod(E: TZSEngine; Slot: LongInt; const Which: AnsiString; Page: LongInt);
const
  PER_PAGE = 15;
  { place, nick, points, kills, deaths, K/D, HS, caps, wins, time: 95 of LINE_W }
  C: array[0..9] of LongInt = (5, 24, 9, 8, 8, 8, 8, 7, 7, 11);
var
  PI, Key, k, n, Pages, First, Me, Idx: LongInt;
  Title: AnsiString;
  Rows: TIntArray;
  P: PPlayerProfile;
  PS: ^TPeriodStats;
  Tmp: TPlayerProfile;
  Entries: TRankEntryArray;
  Stats: array of TPeriodStats;
  Names: TStringArray;
  Owners: TIntArray;
begin
  if Which = 'day' then
  begin
    PI := PERIOD_DAY;
    Key := DayKey(Now);
    Title := 'Today';
  end
  else if Which = 'week' then
  begin
    PI := PERIOD_WEEK;
    Key := WeekKey(Now);
    Title := 'This Week';
  end
  else
  begin
    PI := PERIOD_MONTH;
    Key := MonthKey(Now);
    Title := 'This Month';
  end;
  { the accounts of this server, and with SharedRankings of every server: their period is kept
    with the name, so the view is built once }
  Entries := RankingEntries(E);
  SetLength(Stats, Length(Entries));
  SetLength(Names, Length(Entries));
  SetLength(Owners, Length(Entries));
  n := 0;
  for k := 0 to High(Entries) do
  begin
    P := RankingView(E, Entries[k], Tmp);
    if P = nil then
      Continue;
    { a period only counts while its key is the current day, week or month }
    if (P^.Period[PI].Key = Key) and (P^.Period[PI].Kills + P^.Period[PI].Deaths + P^.Period[PI].Caps + P^.Period[PI].Wins > 0) then
    begin
      Stats[n] := P^.Period[PI];
      Names[n] := P^.ActiveName;
      Owners[n] := Entries[k].Idx;
      Inc(n);
    end;
  end;
  if n = 0 then
  begin
    Out(E, Slot, Format('Nobody has played %s yet.', [LowerCase(Title)]), CLR_HEADER);
    Exit;
  end;
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
  begin
    SortKeys[k * 2] := Stats[k].PointsDelta;
    SortKeys[k * 2 + 1] := Stats[k].Kills;
    SortTie[k] := -Stats[k].Deaths;
  end;
  Pages := PageCount(n, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Rows := BestRows(n, Min(n, First + PER_PAGE));
  Me := ViewerIndex(E, Slot);
  Header(E, Slot, Format('Top %s%s [Page %d/%d] (%d players)', [Title, AllServers(E), Page, Pages, n]), LINE_W);
  Row(E, Slot, ['#', 'Nick', 'Points', 'Kills', 'Deaths', 'K/D', 'HS', 'Caps', 'Wins', 'Time'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Min(n - 1, First + PER_PAGE - 1) do
  begin
    Idx := Owners[Rows[k]];
    PS := @Stats[Rows[k]];
    Row(E, Slot, [IntToStr(k + 1), Copy(Names[Rows[k]], 1, C[1] - 1), SignedShort(PS^.PointsDelta), Num(PS^.Kills), Num(PS^.Deaths),
      KD(PS^.Kills, PS^.Deaths), Num(PS^.Headshots), Num(PS^.Caps), Num(PS^.Wins), FormatDurationShort(PS^.TimePlayed)], C,
      RowColor(k + 1, (Idx >= 0) and (Idx = Me)));
  end;
  PageHint(E, Slot, Page, Pages, 'players');
  Remember(E, Slot, QK_TOPPERIOD, Which, Page, Pages);
end;

{ ---------------- search ---------------- }

function AliasMatch(const Arr: TOtherDataArray; const Low: AnsiString; PrefixOnly: Boolean): Boolean;
var
  k, p: LongInt;
begin
  for k := 0 to High(Arr) do
  begin
    p := Pos(Low, LowerCase(OtherDataToString(Arr[k])));
    if (p = 1) or ((p > 1) and not PrefixOnly) then
      Exit(True);
  end;
  Result := False;
end;

{ Public: current names only. Admin: also former names, #id, the last IP (prefix), HWID and
  SteamID. The closest kind of match comes first (NameMatchRank): the whole name, then its
  beginning, the beginning of a word, any part; within a kind the one seen last first. One letter
  is enough - a nick can be one letter long. }
procedure ListSearch(E: TZSEngine; Slot: LongInt; const Phrase: AnsiString; Page: LongInt; AdminView: Boolean);
const
  PER_PAGE = 10;
  { what an admin finds by something other than the current name comes after every name }
  OTHER_MATCH = 5000;
  { place, nick, points, rank, last seen: 78 of LINE_W }
  CP: array[0..4] of LongInt = (5, 32, 12, 11, 18);
  { place, account, nick, points, rank, found by, last seen: 97 of LINE_W }
  CA: array[0..6] of LongInt = (5, 9, 29, 11, 10, 15, 18);
var
  Low, How, Shown: AnsiString;
  Found, Rows, Rank: TIntArray;
  Why: TStringArray;
  k, n, Pages, First, Idx, Me, R: LongInt;
  P: PPlayerProfile;
begin
  Low := LowerCase(Trim(Phrase));
  if Low = '' then
  begin
    Out(E, Slot, 'Type a name or a part of it to search.', CLR_WARN);
    Exit;
  end;
  SetLength(Found, E.DB.ProfileCount);
  SetLength(Why, E.DB.ProfileCount);
  SetLength(Rank, E.DB.ProfileCount);
  n := 0;
  for k := 0 to E.DB.ProfileCount - 1 do
  begin
    if not E.DB.Valid(k) then
      Continue;
    P := E.DB.Profiles[k];
    How := '';
    R := NameMatchRank(P^.ActiveName, Low);
    if R >= 0 then
      How := 'name'
    else if AdminView then
    begin
      if (Low[1] = '#') and (StrToIntDef(Copy(Low, 2, MaxInt), -1) = P^.ID) then
        How := 'id'
      else if AliasMatch(P^.OtherNames, Low, False) then
        How := 'old name'
      else if StartsLower(P^.ActiveIP, Low) then
        How := 'last IP'
      else if ContainsLower(P^.ActiveHWID, Low) then
        How := 'HWID'
      else if ContainsLower(P^.ActiveSteam, Low) then
        How := 'SteamID';
    end;
    if How <> '' then
    begin
      Found[n] := k;
      Why[n] := How;
      if R >= 0 then
        Rank[n] := R
      else
        Rank[n] := OTHER_MATCH;
      Inc(n);
    end;
  end;
  if n = 0 then
  begin
    Out(E, Slot, 'No players found matching: ' + Phrase, CLR_BAD);
    Exit;
  end;
  PrepareSort(n, 1);
  for k := 0 to n - 1 do
  begin
    SortKeys[k] := -(Rank[k] div 1000);
    SortTie[k] := E.DB.Profiles[Found[k]]^.LastPlayedTime;
  end;
  Pages := PageCount(n, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Rows := BestRows(n, Min(n, First + PER_PAGE));
  Me := ViewerIndex(E, Slot);
  { a long text would push the title out of the frame }
  Shown := Copy(Trim(Phrase), 1, 40);
  if AdminView then
  begin
    Header(E, Slot, Format('Admin Search: "%s" (%d matches) [Page %d/%d]', [Shown, n, Page, Pages]), LINE_W);
    Row(E, Slot, ['#', 'ID', 'Nick', 'Points', 'Rank', 'Found by', 'Last seen'], CA, CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
  end
  else
  begin
    Header(E, Slot, Format('Search: "%s" (%d matches) [Page %d/%d]', [Shown, n, Page, Pages]), LINE_W);
    Row(E, Slot, ['#', 'Nick', 'Points', 'Rank', 'Last seen'], CP, CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
  end;
  for k := First to Min(n - 1, First + PER_PAGE - 1) do
  begin
    Idx := Found[Rows[k]];
    P := E.DB.Profiles[Idx];
    { the points of the ranking whose place is shown next to them }
    if AdminView then
      Row(E, Slot, [IntToStr(k + 1), IntToStr(P^.ID), Copy(P^.ActiveName, 1, CA[2] - 1), Num(RankingPoints(E, Idx)),
        RankText(E, Idx), Why[Rows[k]], DateText(P^.LastPlayedTime, 'dd.mm.yyyy hh:nn')], CA, RowColor(0, Idx = Me))
    else
      Row(E, Slot, [IntToStr(k + 1), Copy(P^.ActiveName, 1, CP[1] - 1), Num(RankingPoints(E, Idx)), RankText(E, Idx),
        DateText(P^.LastPlayedTime, 'dd.mm.yyyy hh:nn')], CP, RowColor(0, Idx = Me));
  end;
  PageHint(E, Slot, Page, Pages, 'matches');
  if AdminView then
    Remember(E, Slot, QK_SEARCH_ADMIN, Phrase, Page, Pages)
  else
    Remember(E, Slot, QK_SEARCH, Phrase, Page, Pages);
end;
