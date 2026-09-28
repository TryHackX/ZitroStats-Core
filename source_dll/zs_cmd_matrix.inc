{ zs_commands: what the players did on the maps - the player-on-map records of [Matrix] (zs_matrix):
  a player on one map (!mapplayerstats, !mapplayerotherstats, !mapplayerweapstats, !mapplayerrivals,
  !mapplayermatchup, !playerheatmap), a player over all his maps (!playermaps, !rivals, !versus,
  !playermatchup) and one map with all its players (!maprivals, !mapmatchup, !mapweapstats, !mapwep).

  The words of a command, in this order: the map, when the first word names a map of the statistics -
  its exact name, else the closest one as the map vote finds it -, unless the word is a number, a sort
  flag of the view, the start of a weapon's name (the views that take a weapon) or exactly the name of
  a player on the server and of no map; then the weapon; then the sort flags (asc turns the order
  round); then the page number; then the player - or, in the "i" form of a command, the position in
  the points ranking (the last number). A text without a map is the map played now. The lists keep
  the order of before as well: a number at the end of "[p] [pg]" is the page.

  A record exists since 5.5, once something was counted for the account on the map while the
  statistics counted ([Matrix] Enabled); the records of an account go after [Matrix] MatrixPruneDays
  days without play. The lists page with /zs_next and the others: their query keeps the account ids,
  the order and the map. }

const
  { !playermaps: place, map, time, kills, deaths, K/D, won/lost and points; the last game (and the
    mark of the map played now) ends the line - at most 97 of LINE_W }
  PM_MAPS_COLS: array[0..8] of LongInt = (5, 25, 9, 7, 7, 7, 12, 8, 17);
  { the rivals, and the maps of !versus: place, rival or map, kills, deaths, K/D, the points won and
    lost and their difference, the damage both ways; the last fight ends the line - at most 98 of
    LINE_W }
  PM_RIVAL_COLS: array[0..10] of LongInt = (5, 17, 6, 7, 7, 8, 9, 10, 8, 7, 14);
  { !maprivals: place, the two players, their kills, the points won - lost of the first and their
    difference, the damage (the first player's - the second's); the day of the last fight ends the
    line - LINE_W }
  PM_PAIR_COLS: array[0..6] of LongInt = (5, 33, 14, 14, 10, 14, 10);
  { the weapon matchups of a player: place, his weapon against the other's, duels, won, lost; the
    edge ends the line - at most 85 of LINE_W }
  PM_DUEL_COLS: array[0..5] of LongInt = (5, 24, 8, 16, 16, 16);
  { one weapon of a player against the others, as !matchup <weapon>: at most 77 of LINE_W }
  PM_WEAPON_DUEL_COLS: array[0..6] of LongInt = (18, 8, 8, 10, 11, 8, 14);
  { !mapweapstats: weapon, kills, share of the kills, share of the picks of its group, shots, hits,
    Acc%, HS%, damage and players; the time ends the line - at most 90 of LINE_W }
  PM_MAP_WEAPON_COLS: array[0..10] of LongInt = (17, 7, 7, 7, 7, 7, 7, 7, 8, 8, 9);
  { the players with the most kills with one weapon on a map (!mapwep): place, nick, kills, deaths,
    K/D, Acc%, HS%, damage; the time ends the line - at most 92 of LINE_W }
  PM_WEAPON_PLAYER_COLS: array[0..8] of LongInt = (5, 22, 8, 8, 8, 8, 7, 8, 10);
  PM_WEAPON_PLAYERS = 5;

  { the parts of the text a view takes (MxParse) }
  MXA_MAP = 1;       { a map first, when the first word names one }
  MXA_WEAPON = 2;    { a weapon after the map: its exact name, of up to three words }
  MXA_PAGE = 4;      { a page number }
  MXA_PLAYER = 8;    { a player, or in the "i" form a position of the ranking }
  MXA_TWO = 16;      { a second player (!versus) }

  { the sets of sort flags: the rivals (!rivals, !mapplayerrivals, the maps of !versus), the pairs of
    a map (!maprivals), the weapon duels (!playermatchup, !mapplayermatchup, !mapmatchup), the maps
    of a player (!playermaps) and the weapons of a map (!mapweapstats) }
  MXF_NONE = -1;
  MXF_RIVALS = 0;
  MXF_PAIRS = 1;
  MXF_DUELS = 2;
  MXF_MAPS = 3;
  MXF_WEAPONS = 4;

  { the flags of each set by their place in it; the first one (0: fights, fights, duels, time, kills)
    is the default }
  RVS_KILLS = 1;
  RVS_DEATHS = 2;
  RVS_KD = 3;
  RVS_DELTA = 4;
  RVS_WON = 5;
  RVS_LOST = 6;
  RVS_DMG = 7;
  RVS_DMGIN = 8;
  RVS_LAST = 9;
  PRS_DMG = 1;
  PRS_POINTS = 2;
  PRS_DELTA = 3;
  PRS_LAST = 4;
  MPS_KILLS = 1;
  MPS_DEATHS = 2;
  MPS_KD = 3;
  MPS_POINTS = 4;
  MPS_WINS = 5;
  MPS_LAST = 6;
  WPS_PICKS = 1;
  WPS_SHOTS = 2;
  WPS_HITS = 3;
  WPS_ACC = 4;
  WPS_HS = 5;
  WPS_DMG = 6;
  WPS_TIME = 7;
  WPS_PLAYERS = 8;

  { what the rivals of a record are picked by (TopRivalsText) }
  TRV_VICTIMS = 0;
  TRV_NEMESES = 1;
  TRV_WON = 2;
  TRV_LOST = 3;

type
  { the duels a player won and lost, by his weapon slot and the one the other player held }
  TDuelGrid = array[0..WSLOT_COUNT - 1, 0..WSLOT_COUNT - 1] of LongInt;
  { the picture of !playerheatmap: 16 rows of 60 signs, as !heatmap }
  THeatGrid = array[0..15, 0..59] of LongInt;

  { one map of !versus: the kills, the damage and the points of each of the two against the other;
    HasA, HasB: that side has an entry of the other on the map }
  TVersusMap = record
    MapName: AnsiString;
    AKills, BKills: LongInt;
    ADamage, BDamage: Double;
    LastFight: Double;
    AWon, ALost, BWon, BLost: LongInt;
    HasA, HasB: Boolean;
  end;
  TVersusMapArray = array of TVersusMap;

  { a sort flag of a list: its set, its names, how a title says it ("by <Head>") and what it sorts by
    (<cmd> help) }
  TMxFlag = record
    Kind: LongInt;
    Words: AnsiString;
    Head: AnsiString;
    Help: AnsiString;
  end;

  { what a view of the per-map data was asked for (MxParse) }
  TMxArgs = record
    MapName: AnsiString;   { the map: the one played now when none was named ('' before the first map) }
    MapGiven: Boolean;
    WeaponSlot: LongInt;   { -1 = none }
    Sort: LongInt;         { the place of the flag in its set, 0 = the first (the default) }
    Asc: Boolean;
    Page: LongInt;
    PageGiven: Boolean;
    Who, Who2: AnsiString; { the player ('' = the caller); in the "i" form the ranking position(s) }
    Rest: AnsiString;      { a view without a player: the words no part took }
  end;

  { one weapon on one map: the map's own counters (all time) and the per-map records added up }
  TMapWeapon = record
    Slot: LongInt;
    Kills, Picks: Int64;
    RKills, Deaths, Shots, Hits, Headshots, Time: Int64;
    Damage: Double;
    Players: LongInt;      { accounts that used it there }
  end;
  TMapWeaponArray = array[0..WSLOT_COUNT - 1] of TMapWeapon;

const
  MX_FLAGS: array[0..34] of TMxFlag = (
    (Kind: MXF_RIVALS; Words: ' fights fight '; Head: 'fights'; Help: 'kills both ways; the default'),
    (Kind: MXF_RIVALS; Words: ' kills kill '; Head: 'kills'; Help: 'the player killed the rival'),
    (Kind: MXF_RIVALS; Words: ' deaths death '; Head: 'deaths'; Help: 'the rival killed the player'),
    (Kind: MXF_RIVALS; Words: ' kd kdr '; Head: 'K/D'; Help: 'kills per death'),
    (Kind: MXF_RIVALS; Words: ' delta net '; Head: 'points delta'; Help: 'points won - lost, the best first'),
    (Kind: MXF_RIVALS; Words: ' won '; Head: 'points won'; Help: 'on whom the player gains the most'),
    (Kind: MXF_RIVALS; Words: ' lost '; Head: 'points lost'; Help: 'who takes the most points from the player'),
    (Kind: MXF_RIVALS; Words: ' dmg damage dmgout '; Head: 'damage out'; Help: 'dealt to the rival'),
    (Kind: MXF_RIVALS; Words: ' dmgin dmgtaken '; Head: 'damage in'; Help: 'taken from the rival'),
    (Kind: MXF_RIVALS; Words: ' last recent '; Head: 'last fight'; Help: 'the newest fight first'),
    (Kind: MXF_PAIRS; Words: ' fights fight kills '; Head: 'fights'; Help: 'kills both ways; the default'),
    (Kind: MXF_PAIRS; Words: ' dmg damage '; Head: 'damage'; Help: 'damage both ways'),
    (Kind: MXF_PAIRS; Words: ' points pts '; Head: 'points'; Help: 'points won both ways'),
    (Kind: MXF_PAIRS; Words: ' delta net '; Head: 'points delta'; Help: 'the most one-sided in points first'),
    (Kind: MXF_PAIRS; Words: ' last recent '; Head: 'last fight'; Help: 'the newest fight first'),
    (Kind: MXF_DUELS; Words: ' duels duel '; Head: 'duels'; Help: 'won and lost; the default'),
    (Kind: MXF_DUELS; Words: ' wins win won '; Head: 'wins'; Help: 'duels won'),
    (Kind: MXF_DUELS; Words: ' losses loss lost '; Head: 'losses'; Help: 'duels lost'),
    (Kind: MXF_DUELS; Words: ' rate winrate '; Head: 'win rate'; Help: 'the share of the duels won'),
    (Kind: MXF_MAPS; Words: ' time playtime '; Head: 'time'; Help: 'time played; the default'),
    (Kind: MXF_MAPS; Words: ' kills kill '; Head: 'kills'; Help: ''),
    (Kind: MXF_MAPS; Words: ' deaths death '; Head: 'deaths'; Help: ''),
    (Kind: MXF_MAPS; Words: ' kd kdr '; Head: 'K/D'; Help: 'kills per death'),
    (Kind: MXF_MAPS; Words: ' points pts '; Head: 'points'; Help: 'won - lost on the map'),
    (Kind: MXF_MAPS; Words: ' wins win won '; Head: 'wins'; Help: 'matches won'),
    (Kind: MXF_MAPS; Words: ' last recent '; Head: 'last game'; Help: 'the newest first'),
    (Kind: MXF_WEAPONS; Words: ' kills kill '; Head: 'kills'; Help: 'on the map, all time; the default'),
    (Kind: MXF_WEAPONS; Words: ' picks pick '; Head: 'picks'; Help: 'spawns with the weapon there'),
    (Kind: MXF_WEAPONS; Words: ' shots shot '; Head: 'shots'; Help: ''),
    (Kind: MXF_WEAPONS; Words: ' hits hit '; Head: 'hits'; Help: ''),
    (Kind: MXF_WEAPONS; Words: ' acc accuracy '; Head: 'accuracy'; Help: 'Acc%'),
    (Kind: MXF_WEAPONS; Words: ' hs headshots '; Head: 'headshot share'; Help: 'HS%'),
    (Kind: MXF_WEAPONS; Words: ' dmg damage '; Head: 'damage'; Help: ''),
    (Kind: MXF_WEAPONS; Words: ' time usage '; Head: 'time'; Help: 'time in hand'),
    (Kind: MXF_WEAPONS; Words: ' players users '; Head: 'players'; Help: 'players who used it there'));

{ ---------------- arguments ---------------- }

{ the map played now, '' before the first map }
function MatrixMapNow(E: TZSEngine): AnsiString;
begin
  if (E.Match.MapIndex >= 0) and (E.Match.MapIndex < E.DB.MapCount) then
    Result := E.DB.Maps[E.Match.MapIndex].MapName
  else
    Result := '';
end;

{ a map of the statistics by a text: its exact name (any case, a ".pms" left out), else the closest
  name as the map vote finds one (the whole name, its beginning, the beginning of a word, any part;
  the shorter first); -1 = none. A text that starts with # names an account, never a map. }
function MatrixMapIndex(E: TZSEngine; const Text: AnsiString): LongInt;
var
  Names: TStringArray;
  T: AnsiString;
  k: LongInt;
begin
  Result := -1;
  T := MapQuery(Text);
  if (T = '') or (T[1] = '#') then
    Exit;
  Result := E.DB.FindMap(T, False);
  if Result >= 0 then
    Exit;
  Names := nil;
  SetLength(Names, E.DB.MapCount);
  for k := 0 to E.DB.MapCount - 1 do
    Names[k] := E.DB.Maps[k].MapName;
  Result := FindMapIn(Names, T);
end;

{ Text is the name of a player on the server as he is called (any case) }
function OnlineNameIs(E: TZSEngine; const Text: AnsiString): Boolean;
var
  S: LongInt;
begin
  Result := False;
  if Text = '' then
    Exit;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human and SameText(E.Live[S].Name, Text) then
      Exit(True);
end;

{ the words of a text and where each of them starts in it, so that the words from one on can be
  taken as they were typed }
procedure MxWords(const Text: AnsiString; out W: TStringArray; out At: TIntArray);
var
  i, n: LongInt;
begin
  W := nil;
  At := nil;
  n := 0;
  i := 1;
  while i <= Length(Text) do
  begin
    while (i <= Length(Text)) and (Text[i] <= ' ') do
      Inc(i);
    if i > Length(Text) then
      Break;
    SetLength(W, n + 1);
    SetLength(At, n + 1);
    At[n] := i;
    while (i <= Length(Text)) and (Text[i] > ' ') do
      Inc(i);
    W[n] := Copy(Text, At[n], i - At[n]);
    Inc(n);
  end;
end;

{ the place in its set of the flag a word names, -1 for none }
function MxFlagIndex(FlagSet: LongInt; const Word: AnsiString): LongInt;
var
  k, n: LongInt;
  T: AnsiString;
begin
  Result := -1;
  if FlagSet < 0 then
    Exit;
  T := ' ' + LowerCase(Word) + ' ';
  n := 0;
  for k := 0 to High(MX_FLAGS) do
    if MX_FLAGS[k].Kind = FlagSet then
    begin
      if Pos(T, MX_FLAGS[k].Words) > 0 then
        Exit(n);
      Inc(n);
    end;
end;

{ the flag at a place of its set; the first one for a place the set does not have }
function MxFlagAt(FlagSet, Place: LongInt): TMxFlag;
var
  k, n: LongInt;
begin
  Result := Default(TMxFlag);
  n := 0;
  for k := 0 to High(MX_FLAGS) do
    if MX_FLAGS[k].Kind = FlagSet then
    begin
      if (n = 0) or (n = Place) then
        Result := MX_FLAGS[k];
      if n = Place then
        Exit;
      Inc(n);
    end;
end;

{ a word is a sort flag of the set, asc included }
function MxIsFlag(FlagSet: LongInt; const Word: AnsiString): Boolean;
begin
  Result := (FlagSet >= 0) and (SameText(Word, 'asc') or (MxFlagIndex(FlagSet, Word) >= 0));
end;

{ a word that is a sort flag of the set goes into A (the last one counts, asc turns the order round) }
function MxFlagWord(FlagSet: LongInt; const Word: AnsiString; var A: TMxArgs): Boolean;
var
  k: LongInt;
begin
  Result := False;
  if FlagSet < 0 then
    Exit;
  if SameText(Word, 'asc') then
  begin
    A.Asc := True;
    Exit(True);
  end;
  k := MxFlagIndex(FlagSet, Word);
  if k >= 0 then
  begin
    A.Sort := k;
    Result := True;
  end;
end;

{ "fights", "points lost (asc)": what the title of a list says it is sorted by }
function MxSortText(FlagSet, Sort: LongInt; Asc: Boolean): AnsiString;
begin
  Result := MxFlagAt(FlagSet, Sort).Head;
  if Asc then
    Result := Result + ' (asc)';
end;

{ the order of a list in the query the page commands keep, and back }
function MxCode(Sort: LongInt; Asc: Boolean): LongInt;
begin
  Result := Sort * 2 + Ord(Asc);
end;

function MxSortOf(Code: LongInt): LongInt;
begin
  Result := Max(0, Code) div 2;
end;

function MxAscOf(Code: LongInt): Boolean;
begin
  Result := Odd(Max(0, Code));
end;

procedure MxSetPage(var A: TMxArgs; const Word: AnsiString);
begin
  A.Page := Max(1, StrToIntDef(Word, MaxInt));
  A.PageGiven := True;
end;

{ the length (1-3 words) of the exact name of a weapon that starts at the word From - a number is a
  page or a ranking position here, never a weapon -, 0 for none; Slot is its weapon slot }
function MxWeaponAt(const W: TStringArray; From: LongInt; out Slot: LongInt): LongInt;
var
  h, k, Wep: LongInt;
  T: AnsiString;
begin
  Result := 0;
  Slot := -1;
  for h := Min(3, Length(W) - From) downto 1 do
  begin
    T := '';
    for k := From to From + h - 1 do
    begin
      if T <> '' then
        T := T + ' ';
      T := T + W[k];
    end;
    if AllDigits(T) then
      Continue;
    Wep := ResolveWeaponExact(T);
    if (Wep >= 0) and (WepSlot(Wep) >= 0) then
    begin
      Slot := WepSlot(Wep);
      Exit(h);
    end;
  end;
end;

{ the first word of a view names a map of the statistics: its exact name; else the closest one,
  unless the word is a number (a page or a ranking position), an #id, a sort flag of the view, the
  start of a weapon's name (in a view that takes one) or exactly the name of a player on the server }
function MxMapFirst(E: TZSEngine; const W: TStringArray; const Text: AnsiString; Parts, FlagSet: LongInt; ByRank: Boolean;
  out MI: LongInt): Boolean;
var
  T: AnsiString;
  S: LongInt;
begin
  Result := False;
  T := W[0];
  MI := E.DB.FindMap(MapQuery(T), False);
  if MI >= 0 then
    Exit(True);
  if AllDigits(T) or (T[1] = '#') or MxIsFlag(FlagSet, T) then
    Exit;
  if (Parts and MXA_WEAPON <> 0) and (MxWeaponAt(W, 0, S) > 0) then
    Exit;
  if not ByRank and (Parts and MXA_PLAYER <> 0) and (OnlineNameIs(E, T) or OnlineNameIs(E, Trim(Text))) then
    Exit;
  MI := MatrixMapIndex(E, T);
  Result := MI >= 0;
end;

{ The text of a view by the parts it takes (MXA_...) and the flags of its set (MXF_..., MXF_NONE for
  none): map, weapon, flags, page and player in this order, see the top of this file. With ByRank
  the words after the flags are ranking positions: [pg] n (two players: n [n2], [pg] n n2); False
  when they are no numbers or too many. A view without a player takes the flags and the page after
  the map in any order and keeps the words that are none of them in Rest. }
function MxParse(E: TZSEngine; const Text: AnsiString; Parts, FlagSet: LongInt; ByRank: Boolean; out A: TMxArgs): Boolean;
var
  W: TStringArray;
  At: TIntArray;
  n, i, m, k, MI, S: LongInt;
begin
  Result := True;
  A := Default(TMxArgs);
  A.MapName := MatrixMapNow(E);
  A.WeaponSlot := -1;
  A.Page := 1;
  MxWords(Text, W, At);
  n := Length(W);
  i := 0;
  if (Parts and MXA_MAP <> 0) and (n > 0) and MxMapFirst(E, W, Text, Parts, FlagSet, ByRank, MI) then
  begin
    A.MapName := E.DB.Maps[MI].MapName;
    A.MapGiven := True;
    i := 1;
  end;
  { the weapon by its exact name; a single word that is all that is left and exactly the name of a
    player on the server stays the player }
  if (Parts and MXA_WEAPON <> 0) and (i < n) and not MxIsFlag(FlagSet, W[i]) then
  begin
    k := MxWeaponAt(W, i, S);
    if (k > 0) and ((k < n - i) or (k > 1) or ByRank or (Parts and MXA_PLAYER = 0) or not OnlineNameIs(E, W[i])) then
    begin
      A.WeaponSlot := S;
      Inc(i, k);
    end;
  end;
  while (i < n) and MxFlagWord(FlagSet, W[i], A) do
    Inc(i);
  m := n - i;
  if ByRank then
  begin
    for k := i to n - 1 do
      if not AllDigits(W[k]) then
        Exit(False);
    if Parts and MXA_TWO <> 0 then
      case m of
        1: A.Who := W[i];
        2:
          begin
            A.Who := W[i];
            A.Who2 := W[i + 1];
          end;
        3:
          begin
            if Parts and MXA_PAGE = 0 then
              Exit(False);
            MxSetPage(A, W[i]);
            A.Who := W[i + 1];
            A.Who2 := W[i + 2];
          end;
        else
          Exit(False);
      end
    else
      case m of
        0: A.Who := '';
        1: A.Who := W[i];
        2:
          begin
            if Parts and MXA_PAGE = 0 then
              Exit(False);
            MxSetPage(A, W[i]);
            A.Who := W[i + 1];
          end;
        else
          Exit(False);
      end;
    Exit;
  end;
  if Parts and MXA_PLAYER = 0 then
  begin
    while i < n do
    begin
      if (Parts and MXA_PAGE <> 0) and AllDigits(W[i]) then
        MxSetPage(A, W[i])
      else if not MxFlagWord(FlagSet, W[i], A) then
      begin
        if A.Rest <> '' then
          A.Rest := A.Rest + ' ';
        A.Rest := A.Rest + W[i];
      end;
      Inc(i);
    end;
    Exit;
  end;
  { the page before the player; a number alone is the page of the caller's list }
  if (Parts and MXA_PAGE <> 0) and (m >= 1) and AllDigits(W[i]) and ((m >= 2) or (Parts and MXA_TWO = 0)) then
  begin
    MxSetPage(A, W[i]);
    Inc(i);
    Dec(m);
  end;
  if i < n then
    A.Who := TrimRight(Copy(Text, At[i], MaxInt));
  { the order of before: the page after the player ("!rivals alice 2") }
  if (Parts and MXA_PAGE <> 0) and (Parts and (MXA_TWO or MXA_WEAPON) = 0) and not A.PageGiven and (m >= 2) and
     AllDigits(W[n - 1]) then
  begin
    MxSetPage(A, W[n - 1]);
    A.Who := TrimRight(Copy(Text, At[i], At[n - 1] - At[i]));
  end;
end;

{ an "i" form asked for with words that are no ranking position, or with too many }
procedure MxRankUsage(E: TZSEngine; Slot: LongInt; const Usage: AnsiString);
begin
  Out(E, Slot, 'Usage: ' + Usage + '  (n = a position of the points ranking)', CLR_WARN);
end;

{ "[p] [weapon]" of !playermatchup as it was before the weapon came first: the weapon is the longest
  end of the text (up to three words) that is the name of one - a part or a typo of a name only after
  a player -, and a single word that is exactly the name of a player on the server stays the player;
  S = -1 without a weapon }
procedure SplitWhoWeapon(E: TZSEngine; const Rest: AnsiString; out Who: AnsiString; out S: LongInt);
var
  W: TStringArray;
  n, h, k, Wep, Pass: LongInt;
  Head, Tail: AnsiString;
begin
  Who := Trim(Rest);
  S := -1;
  W := SplitWords(Who);
  n := Length(W);
  for Pass := 1 to 2 do
    for h := Min(3, n) downto 1 do
    begin
      if (Pass = 2) and (h >= n) then
        Continue;
      Tail := '';
      for k := n - h to n - 1 do
      begin
        if Tail <> '' then
          Tail := Tail + ' ';
        Tail := Tail + W[k];
      end;
      Head := '';
      for k := 0 to n - h - 1 do
      begin
        if Head <> '' then
          Head := Head + ' ';
        Head := Head + W[k];
      end;
      if Pass = 1 then
        Wep := ResolveWeaponExact(Tail)
      else
        Wep := ResolveWeapon(Tail);
      if (Wep < 0) or (WepSlot(Wep) < 0) then
        Continue;
      if (Head = '') and OnlineNameIs(E, Tail) then
        Continue;
      S := WepSlot(Wep);
      Who := Head;
      Exit;
    end;
end;

{ ---------------- names, notes ---------------- }

{ the name of an account by its id; one this server does not have (deleted, or not loaded from a
  shared database) is its number }
function AccountNameOf(E: TZSEngine; Id: LongInt): AnsiString;
var
  Idx: LongInt;
begin
  Idx := E.DB.IndexOfId(Id);
  if E.DB.Valid(Idx) then
    Result := E.DB.Profiles[Idx]^.ActiveName
  else
    Result := '#' + IntToStr(Id);
end;

{ the account id of the caller, 0 for none }
function ViewerId(E: TZSEngine; Slot: LongInt): LongInt;
var
  Idx: LongInt;
begin
  Idx := ViewerIndex(E, Slot);
  if E.DB.Valid(Idx) then
    Result := E.DB.Profiles[Idx]^.ID
  else
    Result := 0;
end;

{ "Map Stats: Alice on ctf_Ash", the name and the map cut so that a title keeps to its frame }
function MatrixTitle(const What, Name, MapName: AnsiString): AnsiString;
begin
  Result := What + ': ' + Copy(Name, 1, 24) + ' on ' + Copy(MapName, 1, 32);
end;

{ how far back the per-map data goes, for the notes of the views }
function MatrixKeptText(E: TZSEngine): AnsiString;
begin
  if E.Cfg.MatrixPruneDays > 0 then
    Result := Format('Per-map data: counted since 5.5 while the statistics count; deleted after %d days ' +
      'without play.', [E.Cfg.MatrixPruneDays])
  else
    Result := 'Per-map data: counted since 5.5 while the statistics count.';
end;

{ a view of records made before [Matrix] Enabled = 0 shows them with this line }
procedure MatrixOldNote(E: TZSEngine; Slot: LongInt);
begin
  if not E.Cfg.MatrixEnabled then
    Out(E, Slot, 'Not recorded any more ([Matrix] Enabled = 0): this was recorded before.', CLR_WARN);
end;

{ nothing recorded: What, or that nothing is recorded at all }
procedure NoMatrixData(E: TZSEngine; Slot: LongInt; const What: AnsiString);
begin
  if not E.Cfg.MatrixEnabled then
    Out(E, Slot, 'Per-map player data is not recorded on this server ([Matrix] Enabled = 0).', CLR_WARN)
  else
  begin
    Out(E, Slot, What, CLR_WARN);
    Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  end;
end;

{ the account of a view: Who (the caller when ''), or with ByRank the position Who of the points
  ranking; -1 after saying why there is none. Example is the command with a player, for the console. }
function MxAccount(E: TZSEngine; Slot: LongInt; const Who: AnsiString; ByRank: Boolean; const Example: AnsiString): LongInt;
begin
  if ByRank then
    Result := IndexAtRank(E, Who)
  else
    Result := TargetIndex(E, Slot, Who);
  if E.DB.Valid(Result) then
    Exit;
  Result := -1;
  if not ByRank and (Slot < 1) and (Who = '') then
    Out(E, Slot, 'The console has no statistics of its own: name a player, e.g. ' + Example + '.', CLR_WARN)
  else
    NotFound(E, Slot);
end;

{ the map and the account of a view of one player on one map (A from MxParse); False after saying
  why there is none. Cmd is the command without its "i". }
function MxMapAccount(E: TZSEngine; Slot: LongInt; const A: TMxArgs; ByRank: Boolean; const Cmd: AnsiString;
  out Idx: LongInt): Boolean;
var
  Refused: Boolean;
begin
  Result := False;
  Idx := -1;
  if A.MapName = '' then
  begin
    if ByRank then
      Out(E, Slot, 'No map is being played: name one, e.g. ' + Cmd + 'i <map> <n>.', CLR_WARN)
    else
      Out(E, Slot, 'No map is being played: name one, e.g. ' + Cmd + ' <map> <player>.', CLR_WARN);
    Exit;
  end;
  if ByRank then
    Idx := IndexAtRank(E, A.Who)
  else
    Idx := TargetIndex(E, Slot, A.Who);
  if E.DB.Valid(Idx) then
    Exit(True);
  Idx := -1;
  if not ByRank and (Slot < 1) and (A.Who = '') then
  begin
    Out(E, Slot, 'The console has no statistics of its own: name a player, e.g. ' + Cmd + ' <map> <player>.', CLR_WARN);
    Exit;
  end;
  Refused := FindRefused;
  NotFound(E, Slot);
  { a word that is no map and no player: say both }
  if not ByRank and not Refused and not A.MapGiven and (A.Who <> '') then
    Out(E, Slot, Format('"%s" is no map of the statistics either (!topmaps lists them).', [Copy(SplitWords(A.Who)[0], 1, 24)]),
      CLR_HINT);
end;

{ "[map] [p]" (the "i" form: "[map] <n>") of a view of one record: the map, the account and its
  record there; False after saying why there is none. Cmd is the command without its "i". }
function MatrixRecord(E: TZSEngine; Slot: LongInt; const Rest, Cmd: AnsiString; ByRank: Boolean; out MapName: AnsiString;
  out Idx: LongInt; out R: PPlayerMapStats): Boolean;
var
  A: TMxArgs;
begin
  Result := False;
  R := nil;
  Idx := -1;
  MapName := '';
  if not MxParse(E, Rest, MXA_MAP or MXA_PLAYER, MXF_NONE, ByRank, A) then
  begin
    MxRankUsage(E, Slot, Cmd + 'i [map] <n>');
    Exit;
  end;
  MapName := A.MapName;
  if not MxMapAccount(E, Slot, A, ByRank, Cmd, Idx) then
    Exit;
  R := E.DB.PM.Find(E.DB.Profiles[Idx]^.ID, MapName);
  if R = nil then
  begin
    NoMatrixData(E, Slot, Format('No per-map data yet for %s on %s.', [E.DB.Profiles[Idx]^.ActiveName,
      Copy(MapName, 1, 40)]));
    Exit;
  end;
  MatrixOldNote(E, Slot);
  Result := True;
end;

{ ---------------- a player on one map ---------------- }

{ every life of a record that ended, as LivesEnded of an account: a death is a death, whoever caused
  it }
function PMLivesEnded(const R: TPlayerMapStats): Int64;
begin
  Result := Int64(R.Deaths) + R.TeamkillDeaths + R.Selfkills;
end;

{ the entry of a weapon slot in a record, all zero when the record has none }
function PMWeaponStat(const R: TPlayerMapStats; Slot: LongInt): TPMWeapon;
var
  p: LongInt;
begin
  if PMWeaponPos(R.Weapons, Slot, p) then
    Result := R.Weapons[p]
  else
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Slot := Slot;
  end;
end;

{ !mapplayerstats [map] [p]: the rows of !stats in their places, with what a record of one map has;
  the rows of a mode (flags, rounds, teamkills, Rambo) in that mode or when the record has such
  counters. The rank, the rating and the season of the account have no map: the map's points, time
  and dates stand there. }
procedure CmdMapPlayerStats(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  MapName, Name, Third: AnsiString;
  Idx: LongInt;
  R: PPlayerMapStats;
  Shots: Int64;
  TeamStyle, Rounds, FFRows: Boolean;
begin
  if not MatrixRecord(E, Slot, Rest, '!mapplayerstats', ByRank, MapName, Idx, R) then
    Exit;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  TeamStyle := IsTeamStyle(E.Match.GameStyle);
  Rounds := E.Match.Survival or (R^.RoundsWon + R^.RoundsLost > 0);
  Shots := Max(Int64(R^.Shots), Int64(R^.Hits));
  { friendly fire hits teammates only: its rows need a team mode with it on, or counters of it }
  FFRows := (TeamStyle and E.Match.FriendlyFire) or (R^.DamageFriendly > 0) or (R^.Teamkills > 0);
  Header(E, Slot, '[ ' + MatrixTitle('Map Stats', Name, MapName) + ' ]', LINE_W);
  Row(E, Slot, ['Map Points: ' + Signed(R^.Points), 'Played: ' + FormatDuration(R^.TimePlayed),
    'Kills/h: ' + FloatStr(SafeDivD(R^.Kills * 3600.0, R^.TimePlayed), 1)], COLS3, CLR_RANK_LINE);
  Row(E, Slot, ['Kills: ' + Num(R^.Kills), 'Deaths: ' + Num(R^.Deaths), 'K/D Ratio: ' + KD(R^.Kills, R^.Deaths)], COLS3,
    WHITE);
  Row(E, Slot, ['Best Streak: ' + IntToStr(R^.BestStreak),
    'Avg Life: ' + FormatDurationShort(R^.TimeAlive div Max(Int64(1), PMLivesEnded(R^))),
    'Dmg Ratio: ' + RatioOrDash(R^.DamageDealt, R^.DamageReceived, 2)], COLS3, WHITE);
  if (R^.DamageDealt > 0) or (R^.DamageReceived > 0) then
  begin
    { the team modes show the assists in a row of their own (below) }
    if TeamStyle and FFRows then
      Third := 'TK Dmg: ' + Dmg(R^.DamageFriendly)
    else if not TeamStyle then
      Third := 'Assists: ' + Num(R^.Assists)
    else
      Third := '';
    Row(E, Slot, [Format('Dealt: %s (~%s kills)', [Dmg(R^.DamageDealt), KillEq(E, R^.DamageDealt)]),
      Format('Taken: %s (~%s deaths)', [Dmg(R^.DamageReceived), KillEq(E, R^.DamageReceived)]), Third], COLS3, WHITE);
  end;
  { health got back on the healing fields of the map and from the kits picked up here }
  if R^.HealRegen + R^.HealKits > 0 then
    Row(E, Slot, ['Healed: ' + Dmg(R^.HealRegen + R^.HealKits) + ' HP', 'Regen: ' + Dmg(R^.HealRegen) + ' HP',
      Format('Heal Kits: %s (%s HP)', [Num(R^.HealKitCount), Dmg(R^.HealKits)])], COLS3, WHITE);
  if R^.TimeAlive > 0 then
    Row(E, Slot, ['Dmg/min alive: ' + FloatStr(R^.DamageDealt * 60.0 / R^.TimeAlive, 1),
      'Kills/min alive: ' + FloatStr(R^.Kills * 60.0 / R^.TimeAlive, 2),
      'Longest Life: ' + FormatDurationShort(R^.LongestLife)], COLS3, WHITE);
  if R^.LongestKill > 0 then
    Row(E, Slot, ['Longest: ' + FloatStr(R^.LongestKill, 1) + 'm', 'Barrett: ' + FloatStr(R^.LongestBarrett, 1) + 'm',
      'Avg Dist: ' + FloatStr(SafeDivD(R^.KillDistSum, R^.KillDistCount), 1) + 'm'], COLS3, WHITE);
  Row(E, Slot, ['Accuracy: ' + Pct(R^.Hits, Shots), Format('Hits: %s/%s', [Num(R^.Hits), Num(Shots)]),
    Format('Headshots: %s (%s)%s', [Num(R^.HitsHead), Pct(R^.HitsHead, R^.Hits),
      ZoneEst(R^.HitsUnknown, R^.HitsHead, R^.HitsBody, R^.HitsLegs)])], COLS3, WHITE);
  { the matches played here and their results; the draws of team matches }
  CellRows(E, Slot, [Format('Matches: %s (%sW / %sL)', [Num(R^.Matches), Num(R^.Wins), Num(R^.Losses)]),
    'Win%: ' + Pct(R^.Wins, Int64(R^.Wins) + R^.Losses),
    IfText(TeamStyle or (R^.Draws > 0), 'Draws: ' + Num(R^.Draws))], COLS3, WHITE);
  { the rounds of survival }
  if Rounds then
    Row(E, Slot, [Format('Rounds: %sW / %sL', [Num(R^.RoundsWon), Num(R^.RoundsLost)]),
      'Round Win%: ' + Pct(R^.RoundsWon, Int64(R^.RoundsWon) + R^.RoundsLost),
      'Round First Bloods: ' + Num(R^.RoundFirstBloods)], COLS3, WHITE);
  if ObjectiveMode(E) or (R^.Caps + R^.Returns + R^.Grabs > 0) then
    Row(E, Slot, ['Flag Caps: ' + Num(R^.Caps), 'Returns: ' + Num(R^.Returns),
      Format('Held: %s (Grabs: %s)', [FormatDurationShort(R^.FlagHoldTime), Num(R^.Grabs)])], COLS3, WHITE);
  if TeamStyle then
  begin
    if FFRows then
      Row(E, Slot, ['Teamkills: ' + Num(R^.Teamkills), 'TK Deaths: ' + Num(R^.TeamkillDeaths),
        'Assists: ' + Num(R^.Assists)], COLS3, WHITE)
    else
    begin
      if E.Match.Survival then
        Third := 'Clutches: ' + Num(R^.ClutchesWon)
      else
        Third := 'First Dmg: ' + Num(R^.FirstDamages);
      Row(E, Slot, ['Assists: ' + Num(R^.Assists), 'First Blood: ' + Num(R^.FirstBloods), Third], COLS3, WHITE);
    end;
  end;
  if R^.KnifeThrows + R^.KnifeStabs > 0 then
    Row(E, Slot, ['Knife Throws: ' + Num(R^.KnifeThrows), 'Knife Hits: ' + Num(R^.KnifeThrowHits),
      'Knife Stabs: ' + Num(R^.KnifeStabs)], COLS3, WHITE);
  if (E.Match.GameStyle = GS_RM) or (R^.RamboKills > 0) or (R^.BowKills > 0) then
    Row(E, Slot, ['Bow Kills: ' + Num(R^.BowKills), 'Bow Time: ' + FormatDurationShort(R^.BowTime),
      'Rambo Kills: ' + Num(R^.RamboKills)], COLS3, WHITE);
  { what the map adds where !stats has the account's season: the first bloods (the team modes have
    them above), the round first bloods without a rounds row, the last stands of survival, the
    teamkills a team mode counted when a free-for-all runs now, the selfkills }
  CellRows(E, Slot, [IfText(not TeamStyle or FFRows, 'First Bloods: ' + Num(R^.FirstBloods)),
    IfText(not Rounds and (R^.RoundFirstBloods > 0), 'Round First Bloods: ' + Num(R^.RoundFirstBloods)),
    IfText(E.Match.Survival or (R^.LastStands > 0), 'Last Stands: ' + Num(R^.LastStands)),
    IfText(not TeamStyle and (R^.Teamkills > 0), 'Teamkills: ' + Num(R^.Teamkills)),
    'Selfkills: ' + Num(R^.Selfkills)], COLS3, WHITE);
  Row(E, Slot, ['First Played: ' + DateText(R^.FirstPlayed, 'dd.mm.yyyy'),
    'Last Played: ' + DateText(R^.LastPlayed, 'dd.mm.yyyy hh:nn')], COLS3, CLR_MATCHES);
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'The same map: !mapplayerotherstats  !mapplayerweapstats  !mapplayerrivals  !mapplayermatchup', CLR_HINT);
end;

{ three rivals of a record, the most of one kind first (What: TRV_... - his kills of them, their kills
  of him, the points won from them or lost to them): "Bob (12), Carl (5)", None without any }
function TopRivalsText(E: TZSEngine; const Rv: TPMRivalArray; Own, What: LongInt): AnsiString;
var
  Used: array of Boolean;
  k, n, Best, V, BestV: LongInt;
begin
  Result := '';
  Used := nil;
  SetLength(Used, Length(Rv));
  for n := 1 to 3 do
  begin
    Best := -1;
    BestV := 0;
    for k := 0 to High(Rv) do
    begin
      if Used[k] or (Rv[k].Id = Own) then
        Continue;
      case What of
        TRV_NEMESES: V := Rv[k].Deaths;
        TRV_WON: V := Rv[k].PointsWon;
        TRV_LOST: V := Rv[k].PointsLost;
        else V := Rv[k].Kills;
      end;
      if (V > 0) and ((Best < 0) or (V > BestV) or ((V = BestV) and (Rv[k].LastFight > Rv[Best].LastFight))) then
      begin
        Best := k;
        BestV := V;
      end;
    end;
    if Best < 0 then
      Break;
    Used[Best] := True;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Format('%s (%s)', [Copy(AccountNameOf(E, Rv[Best].Id), 1, 18), Num(BestV)]);
  end;
  if Result = '' then
    Result := 'None';
end;

{ "Kits: Med 3, Nade 12, ...": the kits of a record by kind, written as !otherstats writes an
  account's (KitPickupsText) }
function PMKitsText(const R: TPlayerMapStats): AnsiString;
var
  P: TPlayerProfile;
begin
  P := Default(TPlayerProfile);
  Move(R.KitPickups, P.KitPickups, SizeOf(P.KitPickups));
  Result := KitPickupsText(P);
end;

{ !mapplayerotherstats [map] [p]: the sections of !otherstats in their order, with what a record of
  one map has; a section, row or cell of a mode in that mode or when the record has such counters.
  The ratings, the season, the achievements and the game modes of the account have no map; the
  rivals, the time and the weapons of the map are added. }
procedure CmdMapPlayerOtherStats(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  MapName, Name, Top, Held: AnsiString;
  Idx, k, TopW, HeldW: LongInt;
  R: PPlayerMapStats;
  Shots, Base: Int64;
  TeamStyle, Rounds, Teams: Boolean;
  Frag, Cluster, M79, Law, Fists, Saw, Flamer, M2: TPMWeapon;
begin
  if not MatrixRecord(E, Slot, Rest, '!mapplayerotherstats', ByRank, MapName, Idx, R) then
    Exit;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  TeamStyle := IsTeamStyle(E.Match.GameStyle);
  Rounds := E.Match.Survival or (R^.RoundsWon + R^.RoundsLost > 0);
  Shots := Max(Int64(R^.Shots), Int64(R^.Hits));
  Header(E, Slot, '[ ' + MatrixTitle('Map Telemetry', Name, MapName) + ' ]', LINE_W);

  Section(E, Slot, 'Damage & Healing', LINE_W);
  Row(E, Slot, [Format('Dmg Dealt: %s (~%s kills)', [Dmg(R^.DamageDealt), KillEq(E, R^.DamageDealt)]),
    Format('Dmg Taken: %s (~%s deaths)', [Dmg(R^.DamageReceived), KillEq(E, R^.DamageReceived)]),
    'Dmg Ratio: ' + RatioOrDash(R^.DamageDealt, R^.DamageReceived, 2)], COLS3, WHITE);
  { the healing always, also at 0: a map without healing fields and a server without kits say so
    here (!mapplayerstats shows it once there is some) }
  Row(E, Slot, ['Healed: ' + Dmg(R^.HealRegen + R^.HealKits) + ' HP', 'Regen: ' + Dmg(R^.HealRegen) + ' HP',
    Format('Heal Kits: %s (%s HP)', [Num(R^.HealKitCount), Dmg(R^.HealKits)])], COLS3, WHITE);
  { every kit picked up here, by kind, also at 0 }
  Out(E, Slot, PMKitsText(R^), WHITE);
  { friendly fire hits teammates only, so the row is there when the record has such counters }
  if (R^.DamageFriendly > 0) or (R^.DamageFriendlyReceived > 0) or (R^.Teamkills > 0) or (R^.TeamkillDeaths > 0) then
    Row(E, Slot, ['TK Dmg Out: ' + Dmg(R^.DamageFriendly), 'TK Dmg In: ' + Dmg(R^.DamageFriendlyReceived),
      Format('TK Kills/Deaths: %s/%s', [Num(R^.Teamkills), Num(R^.TeamkillDeaths)])], COLS3, WHITE);
  Row(E, Slot, ['Dmg/Kill: ' + PerUnit(R^.DamageDealt, R^.Kills, 0, ' HP'),
    'Dmg/Death: ' + PerUnit(R^.DamageReceived, R^.Deaths, 0, ' HP')], COLS3, WHITE);

  { three names of up to 18 letters and their numbers fit the line }
  Section(E, Slot, 'Rivals on this Map', LINE_W);
  Out(E, Slot, 'Fav Victims: ' + TopRivalsText(E, R^.Rivals, R^.AccountId, TRV_VICTIMS), WHITE);
  Out(E, Slot, 'Top Nemeses: ' + TopRivalsText(E, R^.Rivals, R^.AccountId, TRV_NEMESES), WHITE);
  { on whom the player gains the most points, and who takes the most from him }
  Out(E, Slot, 'Pts Won From: ' + TopRivalsText(E, R^.Rivals, R^.AccountId, TRV_WON), WHITE);
  Out(E, Slot, 'Pts Lost To: ' + TopRivalsText(E, R^.Rivals, R^.AccountId, TRV_LOST), WHITE);
  Out(E, Slot, Format('Players fought here: %s (every one: !mapplayerrivals)', [Num(Length(R^.Rivals))]), WHITE);

  Section(E, Slot, 'Hitzones, Aim & Distance', LINE_W);
  Row(E, Slot, [Format('Head: %s (%s)', [Num(R^.HitsHead), Pct(R^.HitsHead, R^.Hits)]),
    Format('Body: %s (%s)', [Num(R^.HitsBody), Pct(R^.HitsBody, R^.Hits)]),
    Format('Legs: %s (%s)', [Num(R^.HitsLegs), Pct(R^.HitsLegs, R^.Hits)])], COLS3, WHITE);
  if R^.LongestKill > 0 then
    Top := FloatStr(R^.LongestKill, 1) + 'm'
  else
    Top := '-';
  Row(E, Slot, ['Longest Kill: ' + Top, 'Longest Barrett: ' + FloatStr(R^.LongestBarrett, 1) + 'm',
    'Avg Kill Dist: ' + FloatStr(SafeDivD(R^.KillDistSum, R^.KillDistCount), 1) + 'm'], COLS3, WHITE);
  Row(E, Slot, ['100m+ Kills: ' + Num(R^.LongKills100), 'Barrett Long: ' + Num(R^.BarrettLongKills),
    'Unclear Zone: ' + Num(R^.HitsUnknown)], COLS3, WHITE);
  Row(E, Slot, ['Accuracy: ' + Pct(R^.Hits, Shots), Format('Hits: %s/%s', [Num(R^.Hits), Num(Shots)])], COLS3, WHITE);

  Section(E, Slot, 'Timing, Movement & Positioning', LINE_W);
  Row(E, Slot, ['Avg TTK: ' + FloatStr(SafeDivD(R^.TTKSumTicks, R^.TTKCount) / TICKS_PER_SECOND, 2) + 's',
    'Best TTK: ' + BoolToStr(R^.BestTTKTicks > 0, FloatStr(R^.BestTTKTicks / TICKS_PER_SECOND, 2) + 's', '-'),
    'Longest Life: ' + FormatDurationShort(R^.LongestLife)], COLS3, WHITE);
  { every life: those that ended, whoever ended them, and the one going on }
  Row(E, Slot, ['Traveled: ' + FloatStr(R^.Traveled / 1000, 1) + ' km',
    'Dist/Life: ' + FloatStr(SafeDivD(R^.Traveled, PMLivesEnded(R^) + 1), 0) + ' m',
    'Best Life: ' + FloatStr(R^.BestLifeDistance, 0) + ' m'], COLS3, WHITE);
  Row(E, Slot, ['Fly Time: ' + FormatDurationShort(R^.JetTime), 'Air Kills: ' + Num(R^.AirKills),
    'Height Kills: ' + Num(R^.HeightKills)], COLS3, WHITE);
  Row(E, Slot, ['Prone Kills: ' + Num(R^.ProneKills), 'Camp Kills: ' + Num(R^.CampKills),
    'Vest Kills: ' + Num(R^.VestKills)], COLS3, WHITE);
  { survival has no spawn kills: everybody spawns together and nobody respawns in a round }
  if not E.Match.Survival or (R^.SpawnKills + R^.SpawnDeaths > 0) then
    Row(E, Slot, ['Spawn Kills: ' + Num(R^.SpawnKills), 'Spawn Deaths: ' + Num(R^.SpawnDeaths)], COLS3, WHITE);

  { the selfkill share as !otherstats takes it ([Ranking] SelfkillPercentBase): of the enemies'
    kills, or of every life that ended }
  if SameText(E.Cfg.SelfkillPercentBase, 'enemy') then
    Base := R^.Deaths
  else
    Base := PMLivesEnded(R^);
  if E.Match.Realistic or (R^.BinkRecoveryKills > 0) then
    Held := 'Bink Recovery: ' + Num(R^.BinkRecoveryKills)
  else
    Held := 'Pace: ' + FloatStr(SafeDivD(R^.Kills * 3600.0, R^.TimePlayed), 1) + ' kills/h';
  { as !otherstats: round first bloods, last stands and clutches belong to survival, saviors,
    avengers and comebacks to the team modes; a feat of another mode shows only when the record has
    it. The selfkills under fire (only the admins' /zs_status shows an account's) tell how many of
    the selfkills came right after an enemy hit. }
  Section(E, Slot, 'Feats & Streaks', LINE_W);
  CellRows(E, Slot, ['Best Streak: ' + IntToStr(R^.BestStreak), 'First Bloods: ' + Num(R^.FirstBloods),
    IfText(E.Match.Survival or (R^.RoundFirstBloods > 0), 'Round First Bloods: ' + Num(R^.RoundFirstBloods)),
    'First Damage: ' + Num(R^.FirstDamages),
    'Dominations: ' + Num(R^.Dominations), 'Revenge Kills: ' + Num(R^.RevengeKills),
    'Dominations Ended: ' + Num(R^.DominationsEnded),
    IfText(E.Match.Survival or (R^.LastStands > 0), 'Last Stands: ' + Num(R^.LastStands)),
    IfText((E.Match.Survival and TeamStyle) or (R^.ClutchesWon > 0), 'Clutches Won: ' + Num(R^.ClutchesWon)),
    IfText(TeamStyle or (R^.SaviorKills > 0), 'Saviors: ' + Num(R^.SaviorKills)),
    IfText(TeamStyle or (R^.AvengerKills > 0), 'Avenger Kills: ' + Num(R^.AvengerKills)),
    IfText(TeamStyle or (R^.ComebackWins > 0), 'Comeback Wins: ' + Num(R^.ComebackWins)),
    'Assists: ' + Num(R^.Assists), 'Posthumous: ' + Num(R^.PosthumousKills),
    'Finishers: ' + Num(R^.Finishers), 'Shut Downs: ' + Num(R^.ShutDowns),
    'Nade Kills: ' + Num(R^.GrenadeKills), Held, 'Explosive Multi: ' + Num(R^.ExplosionMultiKills),
    'Knife Streak: ' + IntToStr(R^.KnifeStreak), 'Cover (live): ' + Num(R^.WallKills),
    'Cover (shot): ' + Num(R^.CoverShotKills), 'Forced Selfkills: ' + Num(R^.ForcedSelfkills),
    Format('Selfkills: %s (%s)', [Num(R^.Selfkills), Pct(R^.Selfkills, Base)]),
    IfText(R^.SelfkillsUnderFire > 0, Format('Under Fire: %s (%s)', [Num(R^.SelfkillsUnderFire),
      Pct(R^.SelfkillsUnderFire, R^.Selfkills)])),
    'Map Points: ' + Signed(R^.Points)], COLS3, WHITE);

  if (R^.Caps + R^.Returns + R^.Grabs + R^.FlagDrops + R^.FlaggerKills + R^.FlagHoldTime > 0) or ObjectiveMode(E) then
  begin
    Section(E, Slot, 'Flags on this Map', LINE_W);
    Row(E, Slot, ['Flag Caps: ' + Num(R^.Caps), 'Flag Returns: ' + Num(R^.Returns), 'Flag Grabs: ' + Num(R^.Grabs)], COLS3,
      WHITE);
    Row(E, Slot, [Format('Flag Drops: %s (%s thrown)', [Num(R^.FlagDrops), Num(R^.FlagThrows)]),
      'Flagger Kills: ' + Num(R^.FlaggerKills), 'Flagger Assists: ' + Num(R^.FlaggerAssists)], COLS3, WHITE);
    Row(E, Slot, ['Flag Defense: ' + Num(R^.FlagDefenses), 'Kills w/ Flag: ' + Num(R^.KillsWithFlag),
      'Flag Hold: ' + FormatDurationShort(R^.FlagHoldTime)], COLS3, WHITE);
    if R^.FastestCap > 0 then
      Top := 'Fastest Cap: ' + FloatStr(R^.FastestCap, 1) + 's'
    else
      Top := 'Fastest Cap: -';
    Row(E, Slot, [Top, 'Caps under 10s: ' + Num(R^.CapsUnder10s), 'Escort Kills: ' + Num(R^.EscortKills)], COLS3, WHITE);
    { the teamkills around the flag need friendly fire }
    Row(E, Slot, ['Flag Juggles: ' + Num(R^.FlagJuggles), 'Contested Holds: ' + Num(R^.ContestedHolds),
      IfText(E.Match.FriendlyFire or (R^.FlaggerTeamkills + R^.TeamkillsWithFlag > 0),
        Format('TK flagger: %s / w/flag: %s', [Num(R^.FlaggerTeamkills), Num(R^.TeamkillsWithFlag)]))], COLS3, WHITE);
    Row(E, Slot, ['Base Defense: ' + Num(R^.BaseDefenseKills), 'Base Attack: ' + Num(R^.BaseAttackKills),
      'Base Radius: ' + IntToStr(E.Cfg.BaseRadiusMeters) + ' m'], COLS3, WHITE);
    if (R^.HtfPoints > 0) or (R^.HtfHoldTime > 0) or (E.Match.GameStyle = GS_HTF) then
      Row(E, Slot, ['HTF Points: ' + Num(R^.HtfPoints), 'HTF Hold: ' + FormatDurationShort(R^.HtfHoldTime),
        'HTF Team: ' + FormatDurationShort(R^.HtfTeamHoldTime)], COLS3, WHITE);
  end;

  { the draws of team matches, the rounds of survival }
  if Rounds then
    Section(E, Slot, 'Matches & Rounds', LINE_W)
  else
    Section(E, Slot, 'Matches', LINE_W);
  Top := 'Win Rate: ' + Pct(R^.Wins, Int64(R^.Wins) + R^.Losses);
  if TeamStyle or (R^.Draws > 0) then
    Top := Top + ' (' + Num(R^.Draws) + ' draws)';
  Row(E, Slot, ['Matches Won: ' + Num(R^.Wins), 'Matches Lost: ' + Num(R^.Losses), Top], COLS3, WHITE);
  if Rounds then
    Row(E, Slot, ['Rounds Won: ' + Num(R^.RoundsWon), 'Rounds Lost: ' + Num(R^.RoundsLost),
      'Round WR: ' + Pct(R^.RoundsWon, Int64(R^.RoundsWon) + R^.RoundsLost)], COLS3, WHITE);
  { the advance rounds, the results by the team played for, and leaving a lost match - a loss in the
    team modes ([Matches] LeaverCountsAsLoss) }
  Teams := R^.AlphaWins + R^.AlphaLosses + R^.BravoWins + R^.BravoLosses > 0;
  CellRows(E, Slot, [IfText(R^.AdvanceRoundsPlayed > 0, Format('Adv Won: %s/%s', [Num(R^.AdvanceRoundsWon),
    Num(R^.AdvanceRoundsPlayed)])),
    IfText(Teams, Format('Alpha: %sW / %sL', [Num(R^.AlphaWins), Num(R^.AlphaLosses)])),
    IfText(Teams, Format('Bravo: %sW / %sL', [Num(R^.BravoWins), Num(R^.BravoLosses)])),
    IfText(TeamStyle or (R^.LeaveLosses > 0), 'Left Lost Matches: ' + Num(R^.LeaveLosses))], COLS3, WHITE);

  Section(E, Slot, 'Multi-Kill Medals', LINE_W);
  Row(E, Slot, ['Double Kills: ' + Num(R^.DoubleKills), 'Triple Kills: ' + Num(R^.TripleKills),
    'Multi Kills: ' + Num(R^.MultiKills)], COLS3, WHITE);
  Row(E, Slot, ['Multi x2: ' + Num(R^.MultiKillsX2), 'Serial Kills: ' + Num(R^.SerialKills),
    'Insane Kills: ' + Num(R^.InsaneKills)], COLS3, WHITE);
  if R^.GimmeMore + R^.MastaKilla + R^.StopIt > 0 then
    Row(E, Slot, ['Gimme More: ' + Num(R^.GimmeMore), 'Masta Killa: ' + Num(R^.MastaKilla),
      'Stop It: ' + Num(R^.StopIt)], COLS3, WHITE);

  { the special weapons as !otherstats counts them: the throws, the stabs and the own nades have
    counters of their own, the rest are the weapons' entries (shots, and hits on enemies) }
  Frag := PMWeaponStat(R^, WSLOT_FRAG);
  Cluster := PMWeaponStat(R^, WSLOT_CLUSTER);
  M79 := PMWeaponStat(R^, WEP_M79);
  Law := PMWeaponStat(R^, WEP_LAW);
  Fists := PMWeaponStat(R^, WSLOT_FISTS);
  Saw := PMWeaponStat(R^, WEP_CHAINSAW);
  Flamer := PMWeaponStat(R^, WEP_FLAMER);
  M2 := PMWeaponStat(R^, WSLOT_M2);
  Section(E, Slot, 'Melee, Explosives & Heavy Arsenal', LINE_W);
  Row(E, Slot, ['Knife Throws: ' + Num(R^.KnifeThrows), Format('Knife Hits: %s (%s)', [Num(R^.KnifeThrowHits),
    Pct(R^.KnifeThrowHits, R^.KnifeThrows)]), 'Knife Stabs: ' + Num(R^.KnifeStabs)], COLS3, WHITE);
  if Cluster.Shots > 0 then
    Top := Format('Cluster hits: %s/%s', [Num(Cluster.Hits), Num(Cluster.Shots)])
  else
    Top := 'Self Nades: ' + Num(R^.NadeSelfHits);
  Row(E, Slot, ['Nades Thrown: ' + Num(Frag.Shots), Format('Nade Hits: %s (%s)', [Num(Frag.Hits),
    Pct(Frag.Hits, Frag.Shots)]), Top], COLS3, WHITE);
  { hits/shots, the way Hits of !mapplayerstats reads }
  Row(E, Slot, [Format('M79 hits: %s/%s (%s)', [Num(M79.Hits), Num(M79.Shots), Pct(M79.Hits, M79.Shots)]),
    Format('LAW hits: %s/%s (%s)', [Num(Law.Hits), Num(Law.Shots), Pct(Law.Hits, Law.Shots)]),
    'Fist Hurts: ' + Num(Fists.Hits)], COLS3, WHITE);
  if (Saw.Hits > 0) or (Saw.TimeUsed > 0) or (Flamer.Hits > 0) or (M2.Hits > 0) then
    Row(E, Slot, [Format('Saw: %s, %s hits', [FormatDurationShort(Saw.TimeUsed), Num(Saw.Hits)]),
      Format('Flamer hits: %s/%s', [Num(Flamer.Hits), Num(Flamer.Shots)]), 'M2 MG Hits: ' + Num(M2.Hits)], COLS3, WHITE);

  { the teamkills and the friendly hits: in a team mode with friendly fire, or when the record has
    such counters }
  if (TeamStyle and E.Match.FriendlyFire) or (R^.Teamkills > 0) or (R^.TeamkillDeaths > 0) or (R^.FriendlyHits > 0) or
     (R^.HitsByFriendly > 0) then
  begin
    Section(E, Slot, 'Teamplay & Friendly Incidents', LINE_W);
    Row(E, Slot, ['Teamkills: ' + Num(R^.Teamkills), 'Deaths by Team: ' + Num(R^.TeamkillDeaths),
      'TK Ratio: ' + FloatStr(SafeDivD(R^.Teamkills, R^.TeamkillDeaths), 2)], COLS3, WHITE);
    Row(E, Slot, ['Friendly Hits: ' + Num(R^.FriendlyHits), 'Hit by Team: ' + Num(R^.HitsByFriendly),
      'Self Hits: ' + Num(R^.SelfHits)], COLS3, WHITE);
    if R^.FriendlyHitsHead + R^.FriendlyHitsBody + R^.FriendlyHitsLegs > 0 then
      Row(E, Slot, ['TK Head: ' + Num(R^.FriendlyHitsHead), 'TK Body: ' + Num(R^.FriendlyHitsBody),
        'TK Legs: ' + Num(R^.FriendlyHitsLegs)], COLS3, WHITE);
  end;

  Section(E, Slot, 'Time on this Map', LINE_W);
  Row(E, Slot, ['Played: ' + FormatDuration(R^.TimePlayed), 'Matches Played: ' + Num(R^.Matches),
    'Kills/h: ' + FloatStr(SafeDivD(R^.Kills * 3600.0, R^.TimePlayed), 1)], COLS3, WHITE);
  Row(E, Slot, ['First Played: ' + DateText(R^.FirstPlayed, 'dd.mm.yyyy hh:nn'),
    'Last Played: ' + DateText(R^.LastPlayed, 'dd.mm.yyyy hh:nn'),
    'Dmg/min: ' + RatioOrDash(R^.DamageDealt * 60.0, R^.TimePlayed, 1)], COLS3, WHITE);

  { the weapon with the most kills and the one held longest }
  TopW := -1;
  HeldW := -1;
  for k := 0 to High(R^.Weapons) do
  begin
    if (R^.Weapons[k].Kills > 0) and ((TopW < 0) or (R^.Weapons[k].Kills > R^.Weapons[TopW].Kills)) then
      TopW := k;
    if (R^.Weapons[k].TimeUsed > 0) and ((HeldW < 0) or (R^.Weapons[k].TimeUsed > R^.Weapons[HeldW].TimeUsed)) then
      HeldW := k;
  end;
  if TopW >= 0 then
    Top := Format('Most Kills: %s (%s)', [SlotShortName(R^.Weapons[TopW].Slot), Num(R^.Weapons[TopW].Kills)])
  else
    Top := 'Most Kills: -';
  if HeldW >= 0 then
    Held := Format('Most Held: %s (%s)', [SlotShortName(R^.Weapons[HeldW].Slot),
      FormatDurationShort(R^.Weapons[HeldW].TimeUsed)])
  else
    Held := 'Most Held: -';
  Section(E, Slot, 'Weapons on this Map', LINE_W);
  Row(E, Slot, [Top, Held, 'Weapons Used: ' + IntToStr(Length(R^.Weapons))], COLS3, WHITE);
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'Every weapon: !mapplayerweapstats  weapon against weapon: !mapplayermatchup  where: !playerheatmap',
    CLR_HINT);
end;

{ !mapplayerweapstats [map] [p]: the weapon table of !allweapons for one map - only the weapons the
  record has; Share is the weapon's share of the kills there }
procedure CmdMapPlayerWeapStats(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  MapName, Name: AnsiString;
  Idx, k: LongInt;
  R: PPlayerMapStats;
  Wp: TPMWeapon;
  Shots: Int64;
begin
  if not MatrixRecord(E, Slot, Rest, '!mapplayerweapstats', ByRank, MapName, Idx, R) then
    Exit;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  Header(E, Slot, MatrixTitle('Map Weapons', Name, MapName), LINE_W);
  if Length(R^.Weapons) = 0 then
    Out(E, Slot, 'No weapon counted here yet.', CLR_OTHER_ROW)
  else
  begin
    Row(E, Slot, ['Weapon', 'Kills', 'Deaths', 'K/D', 'Shots', 'Hits', 'Acc%', 'HS%', 'DmgOut', 'Share', 'Time'], WEAPON_COLS,
      CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
    for k := 0 to High(R^.Weapons) do
    begin
      Wp := R^.Weapons[k];
      if (Wp.Slot < 0) or (Wp.Slot >= WSLOT_COUNT) then
        Continue;
      { a hit without a shot counted (a stab) is one as well, as in !allweapons }
      Shots := Max(Int64(Wp.Shots), Int64(Wp.Hits));
      Row(E, Slot, [SlotName(Wp.Slot), Num(Wp.Kills), Num(Wp.Deaths), KD(Wp.Kills, Wp.Deaths), WeaponShotsText(Wp.Slot, Shots),
        Num(Wp.Hits), WeaponAccText(Wp.Slot, Wp.Hits, Shots), WeaponHSText(Wp.Slot, Wp.Headshots, Wp.Hits), Dmg(Wp.Damage),
        ShareOrDash(Wp.Kills, R^.Kills), FormatDurationShort(Wp.TimeUsed)], WEAPON_COLS, CLR_SHOOTING);
    end;
  end;
  Section(E, Slot, 'Damage on this Map', LINE_W);
  DamageRows(E, Slot, R^.DamageDealt, R^.DamageReceived, R^.Kills, R^.Deaths, CLR_SHOOTING);
  Out(E, Slot, 'Share = of the kills here. Every map together: !allweapons; one weapon in detail: !wep <name>', CLR_HINT);
  Footer(E, Slot, LINE_W);
end;

{ ---------------- the rivals ---------------- }

{ the rivals of an account over all its maps, a rival met on several maps once }
function AccountRivals(E: TZSEngine; AccountId: LongInt): TPMRivalArray;
var
  L: TPMRefArray;
  All: TPMRivalArray;
  Keys: array of Int64;
  Order: TIntArray;
  k, j, n: LongInt;
  Rv: TPMRival;
begin
  Result := nil;
  L := E.DB.PM.OfAccount(AccountId);
  n := 0;
  for k := 0 to High(L) do
    Inc(n, Length(L[k]^.Rivals));
  All := nil;
  SetLength(All, n);
  n := 0;
  for k := 0 to High(L) do
    for j := 0 to High(L[k]^.Rivals) do
    begin
      All[n] := L[k]^.Rivals[j];
      Inc(n);
    end;
  { by the rival: one pass adds up the maps of each }
  Keys := nil;
  SetLength(Keys, n);
  Order := nil;
  SetLength(Order, n);
  for k := 0 to n - 1 do
  begin
    Keys[k] := All[k].Id;
    Order[k] := k;
  end;
  SortByKeys(Keys, Order);
  SetLength(Result, n);
  j := 0;
  for k := 0 to n - 1 do
  begin
    Rv := All[Order[k]];
    if (j > 0) and (Result[j - 1].Id = Rv.Id) then
    begin
      Inc(Result[j - 1].Kills, Rv.Kills);
      Inc(Result[j - 1].Deaths, Rv.Deaths);
      Result[j - 1].DamageDealt := Result[j - 1].DamageDealt + Rv.DamageDealt;
      Result[j - 1].DamageTaken := Result[j - 1].DamageTaken + Rv.DamageTaken;
      Result[j - 1].LastFight := Max(Result[j - 1].LastFight, Rv.LastFight);
      Inc(Result[j - 1].PointsWon, Rv.PointsWon);
      Inc(Result[j - 1].PointsLost, Rv.PointsLost);
    end
    else
    begin
      Result[j] := Rv;
      Inc(j);
    end;
  end;
  SetLength(Result, j);
end;

{ the sort keys of a rival (also a map line of !versus in the shape of one) for a flag of MXF_RIVALS:
  its value, then a second one and the last fight or the damage }
procedure RivalSortKeys(Row: LongInt; const X: TPMRival; Sort: LongInt; Asc: Boolean);
var
  Fights: Double;
begin
  Fights := Int64(X.Kills) + X.Deaths;
  case Sort of
    RVS_KILLS: SetSortKeys(Row, X.Kills, X.LastFight, X.DamageDealt, Asc);
    RVS_DEATHS: SetSortKeys(Row, X.Deaths, X.LastFight, X.DamageTaken, Asc);
    RVS_KD: SetSortKeys(Row, X.Kills / Max(1, X.Deaths), Fights, X.LastFight, Asc);
    RVS_DELTA: SetSortKeys(Row, Int64(X.PointsWon) - X.PointsLost, X.PointsWon, X.LastFight, Asc);
    RVS_WON: SetSortKeys(Row, X.PointsWon, X.Kills, X.LastFight, Asc);
    RVS_LOST: SetSortKeys(Row, X.PointsLost, X.Deaths, X.LastFight, Asc);
    RVS_DMG: SetSortKeys(Row, X.DamageDealt, X.Kills, X.LastFight, Asc);
    RVS_DMGIN: SetSortKeys(Row, X.DamageTaken, X.Deaths, X.LastFight, Asc);
    RVS_LAST: SetSortKeys(Row, X.LastFight, Fights, X.DamageDealt + X.DamageTaken, Asc);
    else SetSortKeys(Row, Fights, X.LastFight, X.DamageDealt + X.DamageTaken, Asc);
  end;
end;

{ the rivals of an account - over all its maps (MapName '') or on one map - in an order of the rival
  lists (MXF_RIVALS); the points won from each and lost to each with their difference }
procedure ListRivals(E: TZSEngine; Slot, Idx: LongInt; const MapName: AnsiString; Sort: LongInt; Asc: Boolean;
  Page: LongInt);
var
  Rv, Keep: TPMRivalArray;
  R: PPlayerMapStats;
  Rows: TIntArray;
  Id, MeId, n, k, PerPage, Pages, First, Last: LongInt;
  Name, Title, Who: AnsiString;
  X: TPMRival;
begin
  Id := E.DB.Profiles[Idx]^.ID;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  if MapName = '' then
    Rv := AccountRivals(E, Id)
  else
  begin
    R := E.DB.PM.Find(Id, MapName);
    if R = nil then
    begin
      NoMatrixData(E, Slot, Format('No per-map data yet for %s on %s.', [Name, Copy(MapName, 1, 40)]));
      Exit;
    end;
    Rv := R^.Rivals;
  end;
  { an account is no rival of its own (two accounts merged into one) }
  Keep := nil;
  SetLength(Keep, Length(Rv));
  n := 0;
  for k := 0 to High(Rv) do
    if Rv[k].Id <> Id then
    begin
      Keep[n] := Rv[k];
      Inc(n);
    end;
  if n = 0 then
  begin
    if MapName = '' then
      NoMatrixData(E, Slot, Format('No rivals of %s recorded yet.', [Name]))
    else
      NoMatrixData(E, Slot, Format('No rivals of %s on %s recorded yet.', [Name, Copy(MapName, 1, 40)]));
    Exit;
  end;
  MatrixOldNote(E, Slot);
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
    RivalSortKeys(k, Keep[k], Sort, Asc);
  Rows := OrderedRows(n);
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  MeId := ViewerId(E, Slot);
  if MapName = '' then
    Title := Format('Rivals of %s, all maps', [Copy(Name, 1, 16)])
  else
    Title := Format('Rivals of %s on %s', [Copy(Name, 1, 16), Copy(MapName, 1, 20)]);
  Header(E, Slot, Format('%s, by %s [Page %d/%d] (%d)', [Title, MxSortText(MXF_RIVALS, Sort, Asc), Page, Pages, n]), LINE_W);
  Row(E, Slot, ['#', 'Rival', 'Kills', 'Deaths', 'K/D', 'Pts Won', 'Pts Lost', 'Pts Delta', 'Dmg Out', 'Dmg In',
    'Last Fight'], PM_RIVAL_COLS, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    X := Keep[Rows[k]];
    { a rival this server has no account of any more is his number }
    Who := AccountNameOf(E, X.Id);
    if not E.DB.Valid(E.DB.IndexOfId(X.Id)) then
      Who := Who + ' (gone)';
    Row(E, Slot, [IntToStr(k + 1), Copy(Who, 1, PM_RIVAL_COLS[1] - 1), Num(X.Kills), Num(X.Deaths), KD(X.Kills, X.Deaths),
      Num(X.PointsWon), Num(X.PointsLost), Signed(Int64(X.PointsWon) - X.PointsLost), Dmg(X.DamageDealt),
      Dmg(X.DamageTaken), DateText(X.LastFight, 'dd.mm.yy hh:nn')], PM_RIVAL_COLS,
      RowColor(k + 1, (MeId > 0) and (X.Id = MeId)));
  end;
  Out(E, Slot, Format('Kills, Pts Won, Dmg Out: by %s   Deaths, Pts Lost, Dmg In: by him', [Copy(Name, 1, 16)]), CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'rivals');
  if MapName = '' then
    Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  Remember(E, Slot, QK_RIVALS, IntToStr(Id) + '|' + IntToStr(MxCode(Sort, Asc)) + '|' + MapName, Page, Pages);
end;

{ the sort keys of a pair of players of a map for a flag of MXF_PAIRS }
procedure PairSortKeys(Row: LongInt; const P: TPMPair; Sort: LongInt; Asc: Boolean);
var
  Fights, Damage: Double;
begin
  Fights := Int64(P.AKills) + P.BKills;
  Damage := P.ADamage + P.BDamage;
  case Sort of
    PRS_DMG: SetSortKeys(Row, Damage, Fights, P.LastFight, Asc);
    PRS_POINTS: SetSortKeys(Row, Int64(P.AWon) + P.BWon, Fights, P.LastFight, Asc);
    PRS_DELTA: SetSortKeys(Row, Abs(Int64(P.AWon) - P.ALost), Int64(P.AWon) + P.BWon, P.LastFight, Asc);
    PRS_LAST: SetSortKeys(Row, P.LastFight, Fights, Damage, Asc);
    else SetSortKeys(Row, Fights, P.LastFight, Damage, Asc);
  end;
end;

{ the pairs of players of a map (!maprivals) in an order of MXF_PAIRS }
procedure ListMapRivals(E: TZSEngine; Slot: LongInt; const MapName: AnsiString; Sort: LongInt; Asc: Boolean; Page: LongInt);
var
  Pairs: TPMPairArray;
  Rows: TIntArray;
  n, k, PerPage, Pages, First, Last, MeId: LongInt;
  P: TPMPair;
begin
  Pairs := E.DB.PM.MapPairs(MapName);
  n := Length(Pairs);
  if n = 0 then
  begin
    NoMatrixData(E, Slot, Format('No rivalries recorded on %s yet.', [Copy(MapName, 1, 40)]));
    Exit;
  end;
  MatrixOldNote(E, Slot);
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
    PairSortKeys(k, Pairs[k], Sort, Asc);
  Rows := OrderedRows(n);
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  MeId := ViewerId(E, Slot);
  Header(E, Slot, Format('Rivalries on %s, by %s [Page %d/%d] (%d pairs)', [Copy(MapName, 1, 32),
    MxSortText(MXF_PAIRS, Sort, Asc), Page, Pages, n]), LINE_W);
  Row(E, Slot, ['#', 'Players', 'Kills', 'Points', 'Pts Delta', 'Damage', 'Last Fight'], PM_PAIR_COLS, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    P := Pairs[Rows[k]];
    Row(E, Slot, [IntToStr(k + 1), Copy(AccountNameOf(E, P.A), 1, 14) + ' vs ' + Copy(AccountNameOf(E, P.B), 1, 14),
      Num(P.AKills) + ' - ' + Num(P.BKills), Num(P.AWon) + ' - ' + Num(P.ALost), Signed(Int64(P.AWon) - P.ALost),
      Dmg(P.ADamage) + ' - ' + Dmg(P.BDamage), DateText(P.LastFight, 'dd.mm.yy')], PM_PAIR_COLS,
      RowColor(k + 1, (MeId > 0) and ((P.A = MeId) or (P.B = MeId))));
  end;
  Out(E, Slot, 'Kills, Damage: the first player''s - the second''s   Points, Pts Delta: won - lost by the first', CLR_HINT);
  Out(E, Slot, 'One player''s own: !mapplayerrivals   other orders: !maprivals help', CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'pairs');
  Remember(E, Slot, QK_MAPRIVALS, IntToStr(MxCode(Sort, Asc)) + '|' + MapName, Page, Pages);
end;

{ a map of !versus: the entry of one side (Swap: the entry B keeps of A); both sides count the same
  kills and damage, so of a map the larger of each count holds - one side may have lost its entry to
  MaxRivals -, and each side keeps the points it won and lost itself }
procedure VersusAdd(var V: TVersusMapArray; var n: LongInt; const MapName: AnsiString; const Rv: TPMRival; Swap: Boolean);
var
  k, AK, BK: LongInt;
  AD, BD: Double;
begin
  if Swap then
  begin
    AK := Rv.Deaths;
    BK := Rv.Kills;
    AD := Rv.DamageTaken;
    BD := Rv.DamageDealt;
  end
  else
  begin
    AK := Rv.Kills;
    BK := Rv.Deaths;
    AD := Rv.DamageDealt;
    BD := Rv.DamageTaken;
  end;
  k := 0;
  while (k < n) and not SameText(V[k].MapName, MapName) do
    Inc(k);
  if k = n then
  begin
    if n >= Length(V) then
      SetLength(V, n * 2 + 8);
    V[n].MapName := MapName;
    V[n].AKills := 0;
    V[n].BKills := 0;
    V[n].ADamage := 0;
    V[n].BDamage := 0;
    V[n].LastFight := 0;
    V[n].AWon := 0;
    V[n].ALost := 0;
    V[n].BWon := 0;
    V[n].BLost := 0;
    V[n].HasA := False;
    V[n].HasB := False;
    Inc(n);
  end;
  V[k].AKills := Max(V[k].AKills, AK);
  V[k].BKills := Max(V[k].BKills, BK);
  V[k].ADamage := Max(V[k].ADamage, AD);
  V[k].BDamage := Max(V[k].BDamage, BD);
  V[k].LastFight := Max(V[k].LastFight, Rv.LastFight);
  if Swap then
  begin
    V[k].BWon := Max(V[k].BWon, Rv.PointsWon);
    V[k].BLost := Max(V[k].BLost, Rv.PointsLost);
    V[k].HasB := True;
  end
  else
  begin
    V[k].AWon := Max(V[k].AWon, Rv.PointsWon);
    V[k].ALost := Max(V[k].ALost, Rv.PointsLost);
    V[k].HasA := True;
  end;
end;

{ a map of !versus in the shape of the first player's entry of the second: his own points, or the
  second one's turned round when he has no entry there }
function VersusAsRival(const X: TVersusMap): TPMRival;
begin
  Result := Default(TPMRival);
  Result.Kills := X.AKills;
  Result.Deaths := X.BKills;
  Result.DamageDealt := X.ADamage;
  Result.DamageTaken := X.BDamage;
  Result.LastFight := X.LastFight;
  if X.HasA then
  begin
    Result.PointsWon := X.AWon;
    Result.PointsLost := X.ALost;
  end
  else
  begin
    Result.PointsWon := X.BLost;
    Result.PointsLost := X.BWon;
  end;
end;

{ !versus: two accounts head to head - all their maps together, then a line per map in an order of
  MXF_RIVALS; the points are the first player's }
procedure ListVersus(E: TZSEngine; Slot, IdA, IdB, Sort: LongInt; Asc: Boolean; Page: LongInt);
var
  V: TVersusMapArray;
  L: TPMRefArray;
  Rows: TIntArray;
  n, k, p, IA, IB, PerPage, Pages, First, Last, Color: LongInt;
  NA, NB, Lead, MapNow: AnsiString;
  TAK, TBK, TWon, TLost: Int64;
  TAD, TBD, TLast: Double;
  X: TVersusMap;
  Y: TPMRival;
begin
  IA := E.DB.IndexOfId(IdA);
  IB := E.DB.IndexOfId(IdB);
  if not E.DB.Valid(IA) or not E.DB.Valid(IB) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  NA := E.DB.Profiles[IA]^.ActiveName;
  NB := E.DB.Profiles[IB]^.ActiveName;
  V := nil;
  n := 0;
  L := E.DB.PM.OfAccount(IdA);
  for k := 0 to High(L) do
    if PMRivalPos(L[k]^.Rivals, IdB, p) then
      VersusAdd(V, n, L[k]^.MapName, L[k]^.Rivals[p], False);
  L := E.DB.PM.OfAccount(IdB);
  for k := 0 to High(L) do
    if PMRivalPos(L[k]^.Rivals, IdA, p) then
      VersusAdd(V, n, L[k]^.MapName, L[k]^.Rivals[p], True);
  if n = 0 then
  begin
    NoMatrixData(E, Slot, Format('%s and %s have not fought each other yet.', [NA, NB]));
    Exit;
  end;
  MatrixOldNote(E, Slot);
  TAK := 0;
  TBK := 0;
  TAD := 0;
  TBD := 0;
  TLast := 0;
  TWon := 0;
  TLost := 0;
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
  begin
    Y := VersusAsRival(V[k]);
    Inc(TAK, V[k].AKills);
    Inc(TBK, V[k].BKills);
    TAD := TAD + V[k].ADamage;
    TBD := TBD + V[k].BDamage;
    TLast := Max(TLast, V[k].LastFight);
    Inc(TWon, Y.PointsWon);
    Inc(TLost, Y.PointsLost);
    RivalSortKeys(k, Y, Sort, Asc);
  end;
  Rows := OrderedRows(n);
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  Header(E, Slot, Format('[ %s vs %s - head to head ]', [Copy(NA, 1, 24), Copy(NB, 1, 24)]), LINE_W);
  Row(E, Slot, [Format('%s: %s kills', [Copy(NA, 1, 20), Num(TAK)]), Format('%s: %s kills', [Copy(NB, 1, 20), Num(TBK)]),
    'K/D: ' + KD(TAK, TBK)], COLS3, CLR_RANK_LINE);
  Row(E, Slot, [Format('Dmg by %s: %s', [Copy(NA, 1, 16), Dmg(TAD)]), Format('Dmg by %s: %s', [Copy(NB, 1, 16), Dmg(TBD)]),
    'Maps: ' + IntToStr(n)], COLS3, WHITE);
  { the points the first player won from the second and lost to him }
  Row(E, Slot, [Format('Pts won by %s: %s', [Copy(NA, 1, 16), Num(TWon)]),
    Format('Pts lost by %s: %s', [Copy(NA, 1, 14), Num(TLost)]), 'Pts Delta: ' + Signed(TWon - TLost)], COLS3, WHITE);
  if TAK > TBK then
    Lead := Format('Ahead: %s by %s', [Copy(NA, 1, 16), Num(TAK - TBK)])
  else if TBK > TAK then
    Lead := Format('Ahead: %s by %s', [Copy(NB, 1, 16), Num(TBK - TAK)])
  else
    Lead := 'Even';
  Row(E, Slot, ['Last Fight: ' + DateText(TLast, 'dd.mm.yy hh:nn'), Lead], COLS3, WHITE);
  Section(E, Slot, Format('Per map by %s - the numbers of %s first', [MxSortText(MXF_RIVALS, Sort, Asc),
    Copy(NA, 1, 24)]), LINE_W);
  Row(E, Slot, ['#', 'Map', 'Kills', 'Deaths', 'K/D', 'Pts Won', 'Pts Lost', 'Pts Delta', 'Dmg Out', 'Dmg In',
    'Last Fight'], PM_RIVAL_COLS, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  MapNow := MatrixMapNow(E);
  for k := First to Last do
  begin
    X := V[Rows[k]];
    Y := VersusAsRival(X);
    if SameText(X.MapName, MapNow) then
      Color := CLR_YOU
    else
      Color := CLR_OTHER_ROW;
    Row(E, Slot, [IntToStr(k + 1), Copy(X.MapName, 1, PM_RIVAL_COLS[1] - 1), Num(X.AKills), Num(X.BKills),
      KD(X.AKills, X.BKills), Num(Y.PointsWon), Num(Y.PointsLost), Signed(Int64(Y.PointsWon) - Y.PointsLost), Dmg(X.ADamage),
      Dmg(X.BDamage), DateText(X.LastFight, 'dd.mm.yy hh:nn')], PM_RIVAL_COLS, Color);
  end;
  Footer(E, Slot, LINE_W);
  Out(E, Slot, Format('Kills, Pts Won, Dmg Out: by %s   Deaths, Pts Lost, Dmg In: by %s', [Copy(NA, 1, 16),
    Copy(NB, 1, 16)]), CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'maps');
  Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  Remember(E, Slot, QK_VERSUS, IntToStr(IdA) + '|' + IntToStr(IdB) + '|' + IntToStr(MxCode(Sort, Asc)), Page, Pages);
end;

{ ---------------- weapon against weapon ---------------- }

{ the duels an account won and lost by its weapon and the other's - over all its maps (MapName '') or
  on one map; False when there are none }
function AccountDuels(E: TZSEngine; AccountId: LongInt; const MapName: AnsiString; out Won, Lost: TDuelGrid): Boolean;
var
  L: TPMRefArray;
  R: PPlayerMapStats;
  k, j: LongInt;
  X: TPMMatchup;
begin
  Won := Default(TDuelGrid);
  Lost := Default(TDuelGrid);
  L := nil;
  if MapName = '' then
    L := E.DB.PM.OfAccount(AccountId)
  else
  begin
    R := E.DB.PM.Find(AccountId, MapName);
    if R <> nil then
    begin
      SetLength(L, 1);
      L[0] := R;
    end;
  end;
  Result := False;
  for k := 0 to High(L) do
    for j := 0 to High(L[k]^.Matchups) do
    begin
      X := L[k]^.Matchups[j];
      if (X.Mine < 0) or (X.Mine >= WSLOT_COUNT) or (X.Theirs < 0) or (X.Theirs >= WSLOT_COUNT) then
        Continue;
      Inc(Won[X.Mine, X.Theirs], X.Wins);
      Inc(Lost[X.Mine, X.Theirs], X.Losses);
      if X.Wins + X.Losses > 0 then
        Result := True;
    end;
end;

{ the weapon matchups of an account (over all its maps, or on one map) in the style of !matchup: S < 0
  every pair of his weapon and the other's; else his weapon S against every weapon it met (also the
  same one); in an order of MXF_DUELS (the most duels first by default) }
procedure ListPlayerDuels(E: TZSEngine; Slot, Idx: LongInt; const MapName: AnsiString; S, Sort: LongInt; Asc: Boolean;
  Page: LongInt);
var
  Won, Lost: TDuelGrid;
  A, B, Rows: TIntArray;
  Id, n, k, i, j, W, L, Total, Color, PerPage, Pages, First, Last: LongInt;
  Name, Where, Edge, By: AnsiString;
begin
  Id := E.DB.Profiles[Idx]^.ID;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  if MapName = '' then
    Where := ', all maps'
  else
    Where := ' on ' + Copy(MapName, 1, 20);
  if not AccountDuels(E, Id, MapName, Won, Lost) then
  begin
    if MapName = '' then
      NoMatrixData(E, Slot, Format('No weapon duels of %s recorded yet.', [Name]))
    else
      NoMatrixData(E, Slot, Format('No weapon duels of %s on %s recorded yet.', [Name, Copy(MapName, 1, 40)]));
    Exit;
  end;
  MatrixOldNote(E, Slot);
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  A := nil;
  B := nil;
  SetLength(A, WSLOT_COUNT * WSLOT_COUNT);
  SetLength(B, WSLOT_COUNT * WSLOT_COUNT);
  n := 0;
  for i := 0 to WSLOT_COUNT - 1 do
    if (S < 0) or (i = S) then
      for j := 0 to WSLOT_COUNT - 1 do
        if Won[i, j] + Lost[i, j] > 0 then
        begin
          A[n] := i;
          B[n] := j;
          Inc(n);
        end;
  if n = 0 then
  begin
    if MapName = '' then
      Out(E, Slot, Format('No duels of %s with the %s recorded yet.', [Name, SlotName(S)]), CLR_HINT)
    else
      Out(E, Slot, Format('No duels of %s with the %s on %s recorded yet.', [Name, SlotName(S), Copy(MapName, 1, 40)]),
        CLR_HINT);
    Exit;
  end;
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
    DuelSortKeys(k, Won[A[k], B[k]], Lost[A[k], B[k]], Sort, Asc, Won[A[k], B[k]]);
  Rows := OrderedRows(n);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  By := MxSortText(MXF_DUELS, Sort, Asc);
  if S < 0 then
  begin
    Header(E, Slot, Format('Weapon Matchups of %s%s, by %s [Page %d/%d] (%d)', [Copy(Name, 1, 16), Where, By, Page, Pages, n]),
      LINE_W);
    Row(E, Slot, ['#', 'Own Weapon vs Theirs', 'Duels', 'Won', 'Lost', 'Edge'], PM_DUEL_COLS, CLR_SUBHEADER);
  end
  else
  begin
    Header(E, Slot, Format('Matchups of %s: %s%s, by %s [Page %d/%d]', [Copy(Name, 1, 14), SlotName(S),
      Copy(Where, 1, 20), By, Page, Pages]), LINE_W);
    Row(E, Slot, ['Opponent Weapon', 'Kills', 'Deaths', 'Win Rate', '95% Range', 'Ratio', 'Matchup Edge'], PM_WEAPON_DUEL_COLS,
      CLR_SUBHEADER);
  end;
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    i := A[Rows[k]];
    j := B[Rows[k]];
    W := Won[i, j];
    L := Lost[i, j];
    Total := W + L;
    Edge := MatchupEdge(W, Total, Color);
    if S < 0 then
      Row(E, Slot, [IntToStr(k + 1), SlotShortName(i) + ' vs ' + SlotShortName(j), Num(Total),
        Format('%s (%s)', [Num(W), Pct(W, Total)]), Format('%s (%s)', [Num(L), Pct(L, Total)]), Edge], PM_DUEL_COLS, Color)
    else
      Row(E, Slot, [SlotName(j), Num(W), Num(L), Pct(W, Total), WilsonRangeText(W, Total), FloatStr(W / Max(1, L), 2), Edge],
        PM_WEAPON_DUEL_COLS, Color);
  end;
  Out(E, Slot, Format('Won: %s killed a player who held the other weapon; Lost: such a player killed %s.',
    [Copy(Name, 1, 16), Copy(Name, 1, 16)]), CLR_HINT);
  if S < 0 then
    Out(E, Slot, 'Edge: only when 50% is outside the 95% range of the win rate.  One weapon: ' +
      '!playermatchup <w> [p]', CLR_HINT)
  else
    Out(E, Slot, 'Range: the real win rate is in it with 95% certainty. An edge only when 50% is outside the range.',
      CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'matchups');
  if MapName = '' then
    Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  Remember(E, Slot, QK_PMATCHUP, IntToStr(Id) + '|' + IntToStr(S) + '|' + IntToStr(MxCode(Sort, Asc)) + '|' + MapName, Page,
    Pages);
end;

{ the weapon matchups of a map (all-time) in the style of !matchup: S < 0 every pair, else one weapon;
  in an order of MXF_DUELS }
procedure ShowMapMatchups(E: TZSEngine; Slot: LongInt; const MapName: AnsiString; S, Sort: LongInt; Asc: Boolean;
  Page: LongInt);
var
  MI, k: LongInt;
  M: PMapProfile;
  Tmp: TMapProfile;
  MU: TMatchupTable;
  C: TMatchupCell;
begin
  MI := E.DB.FindMap(MapName, False);
  if MI < 0 then
  begin
    Out(E, Slot, 'Map not found: ' + MapName, CLR_BAD);
    Exit;
  end;
  if (S < -1) or (S >= WSLOT_COUNT) then
    S := -1;
  { SharedMaps: the other servers' duels of the map added }
  Tmp := Default(TMapProfile);
  M := SharedMapView(E, MI, Tmp);
  if Length(M^.Matchups) = 0 then
  begin
    if not E.Cfg.MatrixEnabled then
      Out(E, Slot, 'The weapon matchups of the maps are not recorded on this server ([Matrix] Enabled = 0).', CLR_WARN)
    else
      Out(E, Slot, 'No weapon duels recorded on ' + Copy(M^.MapName, 1, 40) + ' yet.', CLR_OTHER_ROW);
    Exit;
  end;
  MatrixOldNote(E, Slot);
  MU := Default(TMatchupTable);
  for k := 0 to High(M^.Matchups) do
  begin
    C := M^.Matchups[k];
    if (C.Killer >= 0) and (C.Killer < WSLOT_COUNT) and (C.Victim >= 0) and (C.Victim < WSLOT_COUNT) then
      Inc(MU[C.Killer, C.Victim], C.Kills);
  end;
  MatchupList(E, Slot, @MU, S, ' on ' + Copy(M^.MapName, 1, 24), '!mapmatchup <map> <weapon> shows one weapon; ' +
    '!mapmatchup help lists the orders.', Page, QK_MAPMATCHUP, IntToStr(S) + '|' + IntToStr(MxCode(Sort, Asc)) + '|' +
    M^.MapName, Sort, Asc, ', by ' + MxSortText(MXF_DUELS, Sort, Asc));
end;

{ ---------------- where a player kills and dies ---------------- }

{ !playerheatmap [map] [p]: !heatmap of one player - his kills and deaths on the map, in the frame of
  the map's own picture so both show the map the same way }
procedure CmdPlayerHeatmap(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
const
  W = LINE_W;
  { 60 x 16 signs, as !heatmap }
  COLS = 60;
  ROWS = 16;
  MIN_EVENTS = 10;
  SHADES: array[1..6] of AnsiChar = ('.', ':', '+', '*', '#', '@');
var
  MapName, Name, Indent, Legend: AnsiString;
  Idx, MI, k, GX, GY, MinC, MaxC, MinR, MaxR, Cl, Rw, Best, V, Total, Spot, Pick, KillSpots, DeathSpots: LongInt;
  Kills, Deaths: Int64;
  R: PPlayerMapStats;
  M: PMapProfile;
  Grid: THeatGrid;
  Canvas: array[0..ROWS - 1] of AnsiString;
  Used: array of Boolean;
  HasA, HasB: Boolean;

  procedure Widen(Cc, Rr: LongInt);
  begin
    MinC := Min(MinC, Cc);
    MaxC := Max(MaxC, Cc);
    MinR := Min(MinR, Rr);
    MaxR := Max(MaxR, Rr);
  end;

  function ColOfCell(Cc: LongInt): LongInt;
  begin
    Result := EnsureRange(Round((Cc - MinC) * (COLS - 1) / Max(1, MaxC - MinC)), 0, COLS - 1);
  end;

  function RowOfCell(Rr: LongInt): LongInt;
  begin
    Result := EnsureRange(Round((Rr - MinR) * (ROWS - 1) / Max(1, MaxR - MinR)), 0, ROWS - 1);
  end;

  function Where(Cell: LongInt): AnsiString;
  const
    HORIZ: array[0..2] of AnsiString = ('left', 'middle', 'right');
    VERT: array[0..2] of AnsiString = ('upper', 'central', 'lower');
  var
    Cc, Rr: LongInt;
  begin
    Cc := (Cell mod 4096) - 2048;
    Rr := (Cell div 4096) - 2048;
    Result := VERT[EnsureRange((Rr - MinR) * 3 div Max(1, MaxR - MinR + 1), 0, 2)] + ' ' +
      HORIZ[EnsureRange((Cc - MinC) * 3 div Max(1, MaxC - MinC + 1), 0, 2)] + ' part';
  end;

begin
  if not MatrixRecord(E, Slot, Rest, '!playerheatmap', ByRank, MapName, Idx, R) then
    Exit;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  if Length(R^.Heat) = 0 then
  begin
    if not E.Cfg.MatrixPlayerHeatmap then
      Out(E, Slot, 'Where each player kills and dies is not recorded on this server ([Matrix] PlayerHeatmap = 0).',
        CLR_WARN)
    else
      Out(E, Slot, Format('No kills or deaths of %s on %s yet.', [Name, Copy(MapName, 1, 40)]), CLR_WARN);
    Exit;
  end;
  if E.Cfg.MatrixEnabled and not E.Cfg.MatrixPlayerHeatmap then
    Out(E, Slot, 'Not recorded any more ([Matrix] PlayerHeatmap = 0): this was recorded before.', CLR_WARN);
  MI := E.DB.FindMap(MapName, False);
  M := nil;
  if MI >= 0 then
    M := @E.DB.Maps[MI];
  MinC := MaxInt;
  MaxC := -MaxInt;
  MinR := MaxInt;
  MaxR := -MaxInt;
  for k := 0 to High(R^.Heat) do
    Widen((R^.Heat[k].Cell mod 4096) - 2048, (R^.Heat[k].Cell div 4096) - 2048);
  HasA := False;
  HasB := False;
  if M <> nil then
  begin
    for k := 0 to High(M^.Heat) do
      Widen((M^.Heat[k].Cell mod 4096) - 2048, (M^.Heat[k].Cell div 4096) - 2048);
    HasA := (M^.AlphaFlagX <> 0) or (M^.AlphaFlagY <> 0);
    HasB := (M^.BravoFlagX <> 0) or (M^.BravoFlagY <> 0);
    if HasA then
      Widen(Floor(M^.AlphaFlagX / 64), Floor(M^.AlphaFlagY / 64));
    if HasB then
      Widen(Floor(M^.BravoFlagX / 64), Floor(M^.BravoFlagY / 64));
  end;

  Grid := Default(THeatGrid);
  Best := 0;
  Total := 0;
  Kills := 0;
  Deaths := 0;
  KillSpots := 0;
  DeathSpots := 0;
  for k := 0 to High(R^.Heat) do
  begin
    GX := ColOfCell((R^.Heat[k].Cell mod 4096) - 2048);
    GY := RowOfCell((R^.Heat[k].Cell div 4096) - 2048);
    V := R^.Heat[k].Kills + R^.Heat[k].Deaths;
    Inc(Grid[GY, GX], V);
    Inc(Total, V);
    Best := Max(Best, Grid[GY, GX]);
    Inc(Kills, R^.Heat[k].Kills);
    Inc(Deaths, R^.Heat[k].Deaths);
    if R^.Heat[k].Kills > 0 then
      Inc(KillSpots);
    if R^.Heat[k].Deaths > 0 then
      Inc(DeathSpots);
  end;
  for Rw := 0 to ROWS - 1 do
  begin
    Canvas[Rw] := StringOfChar(' ', COLS);
    for Cl := 0 to COLS - 1 do
      if Grid[Rw, Cl] > 0 then
        Canvas[Rw][Cl + 1] := SHADES[EnsureRange(1 + (Grid[Rw, Cl] * 5) div Max(1, Best), 1, 6)];
  end;
  if HasA then
    Canvas[RowOfCell(Floor(M^.AlphaFlagY / 64))][ColOfCell(Floor(M^.AlphaFlagX / 64)) + 1] := 'A';
  if HasB then
    Canvas[RowOfCell(Floor(M^.BravoFlagY / 64))][ColOfCell(Floor(M^.BravoFlagX / 64)) + 1] := 'B';

  Header(E, Slot, Format('[ Where %s kills and dies: %s ]', [Copy(Name, 1, 24), Copy(MapName, 1, 32)]), W);
  if Total < MIN_EVENTS then
    Out(E, Slot, Format('Only %d kills and deaths so far; the picture becomes useful from about %d.', [Total, MIN_EVENTS]),
      CLR_WARN);
  Indent := StringOfChar(' ', (W - COLS - 2) div 2);
  Out(E, Slot, Indent + '+' + StringOfChar('-', COLS) + '+', CLR_ACTIVITY);
  for Rw := 0 to ROWS - 1 do
    Out(E, Slot, Indent + '|' + Canvas[Rw] + '|', CLR_SHOOTING);
  Out(E, Slot, Indent + '+' + StringOfChar('-', COLS) + '+', CLR_ACTIVITY);
  { the bases are only drawn on maps whose flags main.pas has reported }
  Legend := 'few . : + * # @ many    ';
  if HasA and HasB then
    Legend := Legend + 'A, B = flag bases    '
  else if HasA then
    Legend := Legend + 'A = Alpha flag base    '
  else if HasB then
    Legend := Legend + 'B = Bravo flag base    ';
  Out(E, Slot, Legend + 'up = top of the map', CLR_HINT);
  Out(E, Slot, Format('Kills: %s at %d spots   Deaths: %s at %d spots', [Num(Kills), KillSpots, Num(Deaths), DeathSpots]),
    WHITE);
  Used := nil;
  SetLength(Used, Length(R^.Heat));
  for Spot := 1 to Min(3, Length(R^.Heat)) do
  begin
    Pick := -1;
    for k := 0 to High(R^.Heat) do
      if not Used[k] and ((Pick < 0) or
         (R^.Heat[k].Kills + R^.Heat[k].Deaths > R^.Heat[Pick].Kills + R^.Heat[Pick].Deaths)) then
        Pick := k;
    Used[Pick] := True;
    Out(E, Slot, Format('Hot spot %d: %s of the map - %s kills made there, %s deaths', [Spot,
      Where(R^.Heat[Pick].Cell), Num(R^.Heat[Pick].Kills), Num(R^.Heat[Pick].Deaths)]), WHITE);
  end;
  Footer(E, Slot, W);
  Out(E, Slot, 'Every player on this map: !heatmap <map>', CLR_HINT);
end;

{ ---------------- the maps of a player ---------------- }

{ the sort keys of a map of a player for a flag of MXF_MAPS }
procedure PlayerMapSortKeys(Row: LongInt; const R: TPlayerMapStats; Sort: LongInt; Asc: Boolean);
begin
  case Sort of
    MPS_KILLS: SetSortKeys(Row, R.Kills, R.TimePlayed, R.LastPlayed, Asc);
    MPS_DEATHS: SetSortKeys(Row, R.Deaths, R.TimePlayed, R.LastPlayed, Asc);
    MPS_KD: SetSortKeys(Row, R.Kills / Max(1, R.Deaths), R.Kills, R.TimePlayed, Asc);
    MPS_POINTS: SetSortKeys(Row, R.Points, R.TimePlayed, R.LastPlayed, Asc);
    MPS_WINS: SetSortKeys(Row, R.Wins, -1.0 * R.Losses, R.TimePlayed, Asc);
    MPS_LAST: SetSortKeys(Row, R.LastPlayed, R.TimePlayed, R.Kills, Asc);
    else SetSortKeys(Row, R.TimePlayed, R.LastPlayed, R.Kills, Asc);
  end;
end;

{ !playermaps [flag] [pg] [p]: every map of a player, in an order of MXF_MAPS (the one played longest
  first by default) }
procedure ListPlayerMaps(E: TZSEngine; Slot, Idx, Sort: LongInt; Asc: Boolean; Page: LongInt);
var
  L: TPMRefArray;
  Rows: TIntArray;
  R: PPlayerMapStats;
  Id, n, k, PerPage, Pages, First, Last, Color: LongInt;
  Name, MapNow, Suffix: AnsiString;
  TTime, TK, TD, TW, TL, TP: Int64;
begin
  Id := E.DB.Profiles[Idx]^.ID;
  Name := E.DB.Profiles[Idx]^.ActiveName;
  L := E.DB.PM.OfAccount(Id);
  n := Length(L);
  if n = 0 then
  begin
    NoMatrixData(E, Slot, Format('No per-map data yet for %s.', [Name]));
    Exit;
  end;
  MatrixOldNote(E, Slot);
  TTime := 0;
  TK := 0;
  TD := 0;
  TW := 0;
  TL := 0;
  TP := 0;
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
  begin
    PlayerMapSortKeys(k, L[k]^, Sort, Asc);
    Inc(TTime, L[k]^.TimePlayed);
    Inc(TK, L[k]^.Kills);
    Inc(TD, L[k]^.Deaths);
    Inc(TW, L[k]^.Wins);
    Inc(TL, L[k]^.Losses);
    Inc(TP, L[k]^.Points);
  end;
  Rows := OrderedRows(n);
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  MapNow := MatrixMapNow(E);
  Header(E, Slot, Format('Maps of %s, by %s [Page %d/%d] (%s)', [Copy(Name, 1, 24), MxSortText(MXF_MAPS, Sort, Asc), Page,
    Pages, MapCount(n)]), LINE_W);
  Row(E, Slot, ['#', 'Map', 'Time', 'Kills', 'Deaths', 'K/D', 'Won/Lost', 'Points', 'Last Played'], PM_MAPS_COLS,
    CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    R := L[Rows[k]];
    Color := CLR_OTHER_ROW;
    Suffix := '';
    if SameText(R^.MapName, MapNow) then
    begin
      Color := CLR_YOU;
      Suffix := ' <actual>';
    end;
    Row(E, Slot, [IntToStr(k + 1), Copy(R^.MapName, 1, PM_MAPS_COLS[1] - 1), FormatDurationShort(R^.TimePlayed),
      Num(R^.Kills), Num(R^.Deaths), KD(R^.Kills, R^.Deaths), Num(R^.Wins) + '/' + Num(R^.Losses), Signed(R^.Points),
      DateText(R^.LastPlayed, 'dd.mm.yy') + Suffix], PM_MAPS_COLS, Color);
  end;
  { every map of the player together }
  Rule(E, Slot, LINE_W);
  Row(E, Slot, ['', 'All ' + MapCount(n), FormatDurationShort(TTime), Num(TK), Num(TD), KD(TK, TD),
    Num(TW) + '/' + Num(TL), Signed(TP)], PM_MAPS_COLS, CLR_SUBHEADER);
  PageHint(E, Slot, Page, Pages, 'maps');
  Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  Remember(E, Slot, QK_PLAYERMAPS, IntToStr(Id) + '|' + IntToStr(MxCode(Sort, Asc)), Page, Pages);
end;

{ ---------------- the weapons of a map ---------------- }

{ an entry of a record that shows the weapon in the player's hands, not only deaths by it }
function PMWeaponUsed(const W: TPMWeapon): Boolean;
begin
  Result := (Int64(W.Kills) + W.Shots + W.Hits + W.TimeUsed > 0) or (W.Damage > 0);
end;

{ the weapons of a map: the counters of its record M (with SharedMaps the other servers' added) and
  every player-on-map record of it added up; Records: how many records the map has }
procedure CollectMapWeapons(E: TZSEngine; const M: TMapProfile; out T: TMapWeaponArray; out Records: LongInt);
var
  L: TPMRefArray;
  k, j, S: LongInt;
  W: TPMWeapon;
begin
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    T[S] := Default(TMapWeapon);
    T[S].Slot := S;
    T[S].Kills := M.WeaponKills[S];
    T[S].Picks := M.WeaponPicks[S];
  end;
  L := E.DB.PM.OfMap(M.MapName);
  Records := Length(L);
  for k := 0 to High(L) do
    for j := 0 to High(L[k]^.Weapons) do
    begin
      W := L[k]^.Weapons[j];
      S := W.Slot;
      if (S < 0) or (S >= WSLOT_COUNT) then
        Continue;
      Inc(T[S].RKills, W.Kills);
      Inc(T[S].Deaths, W.Deaths);
      Inc(T[S].Shots, W.Shots);
      Inc(T[S].Hits, W.Hits);
      Inc(T[S].Headshots, W.Headshots);
      Inc(T[S].Time, W.TimeUsed);
      T[S].Damage := T[S].Damage + W.Damage;
      if PMWeaponUsed(W) then
        Inc(T[S].Players);
    end;
end;

{ a weapon has something counted on the map }
function MapWeaponShown(const T: TMapWeapon): Boolean;
begin
  Result := (T.Kills + T.Picks + T.RKills + T.Deaths + T.Shots + T.Hits + T.Time > 0) or (T.Damage > 0);
end;

{ the share of a weapon in the picks of its group on the map (the primaries, or the secondaries),
  '-' for a weapon nobody spawned with there }
function MapPickShare(const T: TMapWeaponArray; S: LongInt): AnsiString;
var
  k: LongInt;
  Group: Int64;
begin
  if T[S].Picks <= 0 then
    Exit('-');
  Group := 0;
  for k := 0 to WSLOT_COUNT - 1 do
    if IsSecondarySlot(k) = IsSecondarySlot(S) then
      Inc(Group, T[k].Picks);
  Result := Pct(T[S].Picks, Group);
end;

{ the sort keys of a weapon of a map for a flag of MXF_WEAPONS; a value that means nothing for the
  weapon (the accuracy of a knife) comes last either way }
procedure MapWeaponSortKeys(Row: LongInt; const T: TMapWeapon; Sort: LongInt; Asc: Boolean);
var
  Wep: LongInt;
  Shots: Int64;
  V: Double;
  Defined: Boolean;
begin
  Wep := SlotWeapon(T.Slot);
  Shots := Max(T.Shots, T.Hits);
  Defined := True;
  case Sort of
    WPS_PICKS: V := T.Picks;
    WPS_SHOTS:
      begin
        V := Shots;
        Defined := ShotsCounted(Wep);
      end;
    WPS_HITS: V := T.Hits;
    WPS_ACC:
      begin
        V := SafeDivD(T.Hits * 100.0, Shots);
        Defined := CountsForAccuracy(Wep) and (Shots > 0);
      end;
    WPS_HS:
      begin
        V := SafeDivD(T.Headshots * 100.0, T.Hits);
        Defined := (ZoneClassifiableStyle(Wep) or (T.Headshots > 0)) and (T.Hits > 0);
      end;
    WPS_DMG: V := T.Damage;
    WPS_TIME: V := T.Time;
    WPS_PLAYERS: V := T.Players;
    else V := T.Kills;
  end;
  if Defined then
    SetSortKeys(Row, V, T.Kills, T.Damage, Asc)
  else
  begin
    SortKeys[Row * 2] := -MaxDouble;
    SortKeys[Row * 2 + 1] := 0;
    SortTie[Row] := 0;
  end;
end;

{ !mapweapstats [map] [flag] [pg]: every weapon used on a map in the table of !serverweapons - the
  kills, their share and the share of the picks of its group from the map's own counters (all time),
  the shots, hits, accuracy, headshots, damage, players and time from the per-map records; in an
  order of MXF_WEAPONS }
procedure ListMapWeapons(E: TZSEngine; Slot: LongInt; const MapName: AnsiString; Sort: LongInt; Asc: Boolean; Page: LongInt);
var
  MI, k, n, S, Records, PerPage, Pages, First, Last, Best: LongInt;
  M: PMapProfile;
  Tmp: TMapProfile;
  T: TMapWeaponArray;
  Shown, Rows: TIntArray;
  AllKills, Shots: Int64;
  AllDmg: Double;
  Picks: array[0..WSLOT_COUNT - 1] of Int64;
  Cells: TStringArray;
  X: TMapWeapon;
begin
  MI := E.DB.FindMap(MapName, False);
  if MI < 0 then
  begin
    Out(E, Slot, 'Map not found: ' + Copy(MapName, 1, 40), CLR_BAD);
    Exit;
  end;
  Tmp := Default(TMapProfile);
  M := SharedMapView(E, MI, Tmp);
  CollectMapWeapons(E, M^, T, Records);
  Shown := nil;
  n := 0;
  AllKills := 0;
  AllDmg := 0;
  Best := 0;
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    Inc(AllKills, T[S].Kills);
    AllDmg := AllDmg + T[S].Damage;
    Picks[S] := T[S].Picks;
    if T[S].Kills > T[Best].Kills then
      Best := S;
    if MapWeaponShown(T[S]) then
    begin
      SetLength(Shown, n + 1);
      Shown[n] := S;
      Inc(n);
    end;
  end;
  if n = 0 then
  begin
    Out(E, Slot, 'No weapon counted on ' + Copy(M^.MapName, 1, 40) + ' yet.', CLR_WARN);
    if not E.Cfg.MatrixEnabled then
      Out(E, Slot, 'Per-map player data is not recorded on this server ([Matrix] Enabled = 0).', CLR_WARN);
    Exit;
  end;
  if Records > 0 then
    MatrixOldNote(E, Slot);
  PrepareSort(n, 2);
  for k := 0 to n - 1 do
    MapWeaponSortKeys(k, T[Shown[k]], Sort, Asc);
  Rows := OrderedRows(n);
  PerPage := Max(5, E.Cfg.TopDisplayLinesCount);
  Pages := PageCount(n, PerPage);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PerPage;
  Last := Min(n, First + PerPage) - 1;
  Header(E, Slot, Format('Weapons on %s, by %s [Page %d/%d] (%d)', [Copy(M^.MapName, 1, 32),
    MxSortText(MXF_WEAPONS, Sort, Asc), Page, Pages, n]), LINE_W);
  Row(E, Slot, ['Weapon', 'Kills', 'Share', 'Pick%', 'Shots', 'Hits', 'Acc%', 'HS%', 'DmgOut', 'Players', 'Time'],
    PM_MAP_WEAPON_COLS, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    X := T[Shown[Rows[k]]];
    { a hit without a shot counted (a stab) is one as well, as in !allweapons }
    Shots := Max(X.Shots, X.Hits);
    Row(E, Slot, [SlotName(X.Slot), Num(X.Kills), ShareOrDash(X.Kills, AllKills), MapPickShare(T, X.Slot),
      WeaponShotsText(X.Slot, Shots), Num(X.Hits), WeaponAccText(X.Slot, X.Hits, Shots),
      WeaponHSText(X.Slot, X.Headshots, X.Hits), Dmg(X.Damage), Num(X.Players), FormatDurationShort(X.Time)],
      PM_MAP_WEAPON_COLS, RowColor(k + 1, False));
  end;
  Section(E, Slot, 'Map totals', LINE_W);
  Cells := nil;
  PushCell(Cells, 'Kills: ' + Num(AllKills));
  if AllKills > 0 then
    PushCell(Cells, 'Deadliest: ' + SlotShortName(Best))
  else
    PushCell(Cells, 'Deadliest: -');
  PushCell(Cells, 'Players: ' + Num(Records));
  { everybody spawns with a secondary as well, so the most picked weapon is named for each group }
  PushCell(Cells, TopPickText('Top primary', Picks, False, True));
  PushCell(Cells, TopPickText('Top secondary', Picks, True, True));
  PushCell(Cells, Format('Damage: %s (~%s kills)', [Dmg(AllDmg), KillEq(E, AllDmg)]));
  FlowCells(E, Slot, Cells, 3, WHITE);
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'Kills, Share, Pick%: the map''s own counters, all time. Shots to Time, Players: the per-map records.',
    CLR_HINT);
  if M <> @E.DB.Maps[MI] then
    Out(E, Slot, 'The map''s own counters add those of the other servers of the database (SharedMaps).', CLR_HINT);
  if not E.Cfg.MatrixEnabled and (Records = 0) then
    Out(E, Slot, 'Per-map player data is not recorded on this server ([Matrix] Enabled = 0).', CLR_WARN)
  else
    Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'weapons');
  Out(E, Slot, 'One weapon here: !mapwep <weapon> [map]   other orders: !mapweapstats help', CLR_HINT);
  Remember(E, Slot, QK_MAPWEAPONS, IntToStr(MxCode(Sort, Asc)) + '|' + M^.MapName, Page, Pages);
end;

{ !mapwep <weapon> [map]: one weapon on one map in the style of !serverwep - the map's own counters
  and duels (all time), what the per-map records hold of it, and the players with the most kills
  with it there }
procedure ShowMapWeapon(E: TZSEngine; Slot: LongInt; const MapName: AnsiString; S: LongInt);
var
  MI, k, j, Wep, Nem, Vic, Records, u, Me, Idx: LongInt;
  NemCount, VicCount, AllKills, Shots, TeamPicks: Int64;
  M: PMapProfile;
  Tmp: TMapProfile;
  T: TMapWeaponArray;
  X: TMapWeapon;
  L: TPMRefArray;
  Users: array of TPMWeapon;
  UserIds: TIntArray;
  Rows: TIntArray;
  C: TMatchupCell;
  Cells: TStringArray;
  W: TPMWeapon;
begin
  MI := E.DB.FindMap(MapName, False);
  if MI < 0 then
  begin
    Out(E, Slot, 'Map not found: ' + Copy(MapName, 1, 40), CLR_BAD);
    Exit;
  end;
  Tmp := Default(TMapProfile);
  M := SharedMapView(E, MI, Tmp);
  CollectMapWeapons(E, M^, T, Records);
  X := T[S];
  Wep := SlotWeapon(S);
  if not MapWeaponShown(X) then
  begin
    Out(E, Slot, Format('Nothing of the %s counted on %s yet.', [SlotName(S), Copy(M^.MapName, 1, 40)]), CLR_WARN);
    if not E.Cfg.MatrixEnabled then
      Out(E, Slot, 'Per-map player data is not recorded on this server ([Matrix] Enabled = 0).', CLR_WARN);
    Exit;
  end;
  AllKills := 0;
  for k := 0 to WSLOT_COUNT - 1 do
    Inc(AllKills, T[k].Kills);
  Header(E, Slot, 'Weapon: ' + SlotName(S) + ' on ' + Copy(M^.MapName, 1, 40), LINE_W);
  { the map's own counters }
  Cells := nil;
  PushCell(Cells, 'Kills: ' + Num(X.Kills));
  PushCell(Cells, 'Share: ' + ShareOrDash(X.Kills, AllKills) + ' of kills');
  if (S <= WEP_LAW) or (X.Picks > 0) then
  begin
    PushCell(Cells, 'Picks: ' + Num(X.Picks));
    if IsSecondarySlot(S) then
      PushCell(Cells, 'Of secondaries: ' + MapPickShare(T, S))
    else
      PushCell(Cells, 'Of primaries: ' + MapPickShare(T, S));
  end;
  { the split by the team of the player, in the team modes }
  TeamPicks := Int64(M^.WeaponPicksTeam[1, S]) + M^.WeaponPicksTeam[2, S];
  if E.TeamGame and (TeamPicks > 0) then
  begin
    PushCell(Cells, Format('Alpha picks: %s (%s)', [Num(M^.WeaponPicksTeam[1, S]), Pct(M^.WeaponPicksTeam[1, S], TeamPicks)]));
    PushCell(Cells, Format('Bravo picks: %s (%s)', [Num(M^.WeaponPicksTeam[2, S]), Pct(M^.WeaponPicksTeam[2, S], TeamPicks)]));
  end;
  { the weapon that killed this one most on the map and the one it killed most; itself is left out
    as in !serverwep }
  Nem := -1;
  Vic := -1;
  NemCount := 0;
  VicCount := 0;
  for k := 0 to High(M^.Matchups) do
  begin
    C := M^.Matchups[k];
    if (C.Killer = C.Victim) or (C.Killer < 0) or (C.Killer >= WSLOT_COUNT) or (C.Victim < 0) or
       (C.Victim >= WSLOT_COUNT) then
      Continue;
    if (C.Victim = S) and (C.Kills > NemCount) then
    begin
      NemCount := C.Kills;
      Nem := C.Killer;
    end;
    if (C.Killer = S) and (C.Kills > VicCount) then
    begin
      VicCount := C.Kills;
      Vic := C.Victim;
    end;
  end;
  if Nem >= 0 then
    PushCell(Cells, Format('Nemesis: %s (%s)', [SlotShortName(Nem), Num(NemCount)]));
  if Vic >= 0 then
    PushCell(Cells, Format('Top Victim: %s (%s)', [SlotShortName(Vic), Num(VicCount)]));
  FlowCells(E, Slot, Cells, 3, CLR_SHOOTING);

  Section(E, Slot, 'The per-map records of the players', LINE_W);
  if Records = 0 then
  begin
    if not E.Cfg.MatrixEnabled then
      Out(E, Slot, 'Per-map player data is not recorded on this server ([Matrix] Enabled = 0).', CLR_WARN)
    else
      Out(E, Slot, 'No per-map data of this map yet.', CLR_OTHER_ROW);
  end
  else
  begin
    MatrixOldNote(E, Slot);
    Shots := Max(X.Shots, X.Hits);
    Cells := nil;
    PushCell(Cells, 'Kills: ' + Num(X.RKills));
    PushCell(Cells, 'Deaths by it: ' + Num(X.Deaths));
    PushCell(Cells, 'Players: ' + Num(X.Players));
    PushCell(Cells, Format('Dmg Out: %s (~%s kills)', [Dmg(X.Damage), KillEq(E, X.Damage)]));
    PushCell(Cells, 'Dmg/Kill: ' + PerUnit(X.Damage, X.RKills, 0, ' HP'));
    PushCell(Cells, 'Dmg/Hit: ' + PerUnit(X.Damage, X.Hits, 1, ' HP'));
    PushCell(Cells, 'Shots: ' + WeaponShotsText(S, Shots));
    if CountsForAccuracy(Wep) then
      PushCell(Cells, Format('Hits: %s (%s)', [Num(X.Hits), ShareOrDash(X.Hits, Shots)]))
    else
      PushCell(Cells, 'Hits: ' + Num(X.Hits));
    PushCell(Cells, 'Time: ' + FormatDurationShort(X.Time));
    { only bullets, pellets, arrows and the stationary gun have hit zones }
    if ZoneClassifiableStyle(Wep) or (X.Headshots > 0) then
      PushCell(Cells, Format('Headshots: %s (%s)', [Num(X.Headshots), ShareOrDash(X.Headshots, X.Hits)]));
    PushCell(Cells, 'Hits/Kill: ' + RatioOrDash(X.Hits, X.RKills, 2));
    FlowCells(E, Slot, Cells, 3, WHITE);
  end;

  { the players with the most kills with it there, then the most damage }
  L := E.DB.PM.OfMap(M^.MapName);
  Users := nil;
  UserIds := nil;
  SetLength(Users, Length(L));
  SetLength(UserIds, Length(L));
  u := 0;
  for k := 0 to High(L) do
    if PMWeaponPos(L[k]^.Weapons, S, j) and PMWeaponUsed(L[k]^.Weapons[j]) then
    begin
      Users[u] := L[k]^.Weapons[j];
      UserIds[u] := L[k]^.AccountId;
      Inc(u);
    end;
  if u > 0 then
  begin
    Section(E, Slot, 'Best players with the ' + SlotName(S) + ' here', LINE_W);
    PrepareSort(u, 2);
    for k := 0 to u - 1 do
      SetSortKeys(k, Users[k].Kills, Users[k].Damage, -1.0 * Users[k].Deaths, False);
    Rows := BestRows(u, PM_WEAPON_PLAYERS);
    Row(E, Slot, ['#', 'Nick', 'Kills', 'Deaths', 'K/D', 'Acc%', 'HS%', 'Damage', 'Time'], PM_WEAPON_PLAYER_COLS,
      CLR_SUBHEADER);
    Rule(E, Slot, LINE_W);
    Me := ViewerIndex(E, Slot);
    for k := 0 to High(Rows) do
    begin
      W := Users[Rows[k]];
      Idx := E.DB.IndexOfId(UserIds[Rows[k]]);
      Shots := Max(Int64(W.Shots), Int64(W.Hits));
      Row(E, Slot, [IntToStr(k + 1), Copy(AccountNameOf(E, UserIds[Rows[k]]), 1, PM_WEAPON_PLAYER_COLS[1] - 1),
        Num(W.Kills), Num(W.Deaths), KD(W.Kills, W.Deaths), WeaponAccText(S, W.Hits, Shots),
        WeaponHSText(S, W.Headshots, W.Hits), Dmg(W.Damage), FormatDurationShort(W.TimeUsed)], PM_WEAPON_PLAYER_COLS,
        RowColor(k + 1, (Idx >= 0) and (Idx = Me)));
    end;
  end;
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'Kills, Share, Picks and the duels: the map''s own counters, all time; the rest: the per-map records.',
    CLR_HINT);
  if M <> @E.DB.Maps[MI] then
    Out(E, Slot, 'The map''s own counters add those of the other servers of the database (SharedMaps).', CLR_HINT);
  if Records > 0 then
    Out(E, Slot, MatrixKeptText(E), CLR_HINT);
  Out(E, Slot, Format('The whole server: !serverwep %s   every weapon here: !mapweapstats %s',
    [LowerCase(SlotShortName(S)), Copy(M^.MapName, 1, 32)]), CLR_HINT);
end;

{ ---------------- the help of the sort flags ---------------- }

{ <cmd> help of the lists with sort flags: how the commands of a set are used, and its flags }
procedure MxFlagsHelp(E: TZSEngine; Slot, FlagSet: LongInt);
var
  Items: TStringArray;
  F: TMxFlag;
  k: LongInt;
begin
  case FlagSet of
    MXF_RIVALS:
      begin
        Header(E, Slot, 'ZitroStats Rivals - !rivals Help', LINE_W);
        Out(E, Slot, 'Usage: !rivals [flag] [pg] [p]   !rivalsi [flag] [pg] <n>   !versus [flag] [pg] <p> [p2]', CLR_HINT);
        Out(E, Slot, '       !mapplayerrivals [map] [flag] [pg] [p]   !mapplayerrivalsi [map] [flag] [pg] <n>', CLR_HINT);
        Out(E, Slot, '       !versusi [flag] <n> [n2]   n = a position of the points ranking', CLR_HINT);
      end;
    MXF_PAIRS:
      begin
        Header(E, Slot, 'ZitroStats Rivalries of a Map - !maprivals Help', LINE_W);
        Out(E, Slot, 'Usage: !maprivals [map] [flag] [pg]   (the map played now when left out)', CLR_HINT);
      end;
    MXF_DUELS:
      begin
        Header(E, Slot, 'ZitroStats Weapon Matchups - !playermatchup Help', LINE_W);
        Out(E, Slot, 'Usage: !playermatchup [w] [flag] [pg] [p]   !playermatchupi [w] [flag] [pg] <n>', CLR_HINT);
        Out(E, Slot, '       !mapplayermatchup [map] [flag] [pg] [p]   !mapplayermatchupi [map] [flag] [pg] <n>', CLR_HINT);
        Out(E, Slot, '       !mapmatchup [map] [w] [flag] [pg]   n = a position of the points ranking', CLR_HINT);
      end;
    MXF_MAPS:
      begin
        Header(E, Slot, 'ZitroStats Maps of a Player - !playermaps Help', LINE_W);
        Out(E, Slot, 'Usage: !playermaps [flag] [pg] [p]   !playermapsi [flag] [pg] <n>   (n = a ranking position)', CLR_HINT);
      end;
    else
      begin
        Header(E, Slot, 'ZitroStats Weapons of a Map - !mapweapstats Help', LINE_W);
        Out(E, Slot, 'Usage: !mapweapstats [map] [flag] [pg]   one weapon: !mapwep <weapon> [map]', CLR_HINT);
      end;
  end;
  Out(E, Slot, 'The most first by the flag; asc turns the order round. Without a flag: the first one.', CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  Items := nil;
  for k := 0 to High(MX_FLAGS) do
    if MX_FLAGS[k].Kind = FlagSet then
    begin
      F := MX_FLAGS[k];
      SetLength(Items, Length(Items) + 1);
      if F.Help <> '' then
        Items[High(Items)] := SplitWords(F.Words)[0] + ' (' + F.Help + ')'
      else
        Items[High(Items)] := SplitWords(F.Words)[0];
    end;
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := 'asc (turns the order round)';
  WrapList(E, Slot, '  ', Items, WHITE);
  Footer(E, Slot, LINE_W);
  case FlagSet of
    MXF_RIVALS, MXF_PAIRS:
      begin
        Out(E, Slot, 'Pts Won: what killing the rival paid (after the inactive-victim rule and MinimumPoints) and, with',
          CLR_HINT);
        Out(E, Slot, 'SelfkillMode = zerosum, his selfkills under the player''s fire. Pts Lost: the same the other way.',
          CLR_HINT);
        Out(E, Slot, 'Penalties of teamkills and selfkills and the capture pool move no points between two players.', CLR_HINT);
      end;
    MXF_DUELS:
      begin
        Out(E, Slot, '!mapmatchup without a weapon lists pairs of weapons: wins, losses and rate are the first weapon''s.',
          CLR_HINT);
        Out(E, Slot, 'The same commands: !playermatrix[i], !mapplayermatrix[i], !mapmatrix (matrix = matchup).', CLR_HINT);
      end;
    MXF_WEAPONS:
      begin
        Out(E, Slot, 'Kills and picks: the map''s own counters, all time; the others: the per-map records.', CLR_HINT);
        Out(E, Slot, 'The same commands: !mapweapsstats, !mapwepstats, !mapwepsstats (wep or weap, either works).',
          CLR_HINT);
      end;
  end;
end;

{ ---------------- the commands ---------------- }

{ !playermaps [flag] [pg] [p], !playermapsi [flag] [pg] <n>: every map of a player }
procedure CmdPlayerMaps(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  A: TMxArgs;
  Idx: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_MAPS);
    Exit;
  end;
  if not MxParse(E, Rest, MXA_PAGE or MXA_PLAYER, MXF_MAPS, ByRank, A) then
  begin
    MxRankUsage(E, Slot, '!playermapsi [flag] [pg] <n>');
    Exit;
  end;
  Idx := MxAccount(E, Slot, A.Who, ByRank, '!playermaps <player>');
  if Idx >= 0 then
    ListPlayerMaps(E, Slot, Idx, A.Sort, A.Asc, A.Page);
end;

{ !rivals [flag] [pg] [p], !rivalsi [flag] [pg] <n>: the rivals of a player over all his maps }
procedure CmdRivals(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  A: TMxArgs;
  Idx: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_RIVALS);
    Exit;
  end;
  if not MxParse(E, Rest, MXA_PAGE or MXA_PLAYER, MXF_RIVALS, ByRank, A) then
  begin
    MxRankUsage(E, Slot, '!rivalsi [flag] [pg] <n>');
    Exit;
  end;
  Idx := MxAccount(E, Slot, A.Who, ByRank, '!rivals <player>');
  if Idx >= 0 then
    ListRivals(E, Slot, Idx, '', A.Sort, A.Asc, A.Page);
end;

{ !mapplayerrivals [map] [flag] [pg] [p], !mapplayerrivalsi [map] [flag] [pg] <n>: the rivals of a
  player on one map }
procedure CmdMapPlayerRivals(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  A: TMxArgs;
  Idx: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_RIVALS);
    Exit;
  end;
  if not MxParse(E, Rest, MXA_MAP or MXA_PAGE or MXA_PLAYER, MXF_RIVALS, ByRank, A) then
  begin
    MxRankUsage(E, Slot, '!mapplayerrivalsi [map] [flag] [pg] <n>');
    Exit;
  end;
  if MxMapAccount(E, Slot, A, ByRank, '!mapplayerrivals', Idx) then
    ListRivals(E, Slot, Idx, A.MapName, A.Sort, A.Asc, A.Page);
end;

{ the map of a view of one map (A from MxParse): words no part took name it when no map came first
  (a map after the flags), else they are said to be ignored; False after saying why there is none }
function MxMapOfView(E: TZSEngine; Slot: LongInt; var A: TMxArgs; const Cmd: AnsiString): Boolean;
var
  MI: LongInt;
begin
  Result := False;
  if A.Rest <> '' then
  begin
    if A.MapGiven then
      Out(E, Slot, Format('[Note] Ignored: %s (%s help lists the sort flags)', [Copy(A.Rest, 1, 40), Cmd]), CLR_HINT)
    else
    begin
      MI := MatrixMapIndex(E, A.Rest);
      if MI < 0 then
      begin
        Out(E, Slot, 'Map not found: ' + Copy(A.Rest, 1, 40), CLR_BAD);
        Exit;
      end;
      A.MapName := E.DB.Maps[MI].MapName;
      A.MapGiven := True;
    end;
  end;
  if A.MapName = '' then
  begin
    Out(E, Slot, 'No map is being played: name one, e.g. ' + Cmd + ' <map>.', CLR_WARN);
    Exit;
  end;
  Result := True;
end;

{ !maprivals [map] [flag] [pg]: the pairs of players of a map. It goes through every record of the
  map, so it counts toward the list limits - once the map is known. }
procedure CmdMapRivals(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; Admin: Boolean);
var
  A: TMxArgs;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_PAIRS);
    Exit;
  end;
  MxParse(E, Rest, MXA_MAP or MXA_PAGE, MXF_PAIRS, False, A);
  if MxMapOfView(E, Slot, A, '!maprivals') and HeavyAllowed(E, Slot, Admin) then
    ListMapRivals(E, Slot, A.MapName, A.Sort, A.Asc, A.Page);
end;

{ !versus [flag] [pg] <p> [p2], !versusi [flag] <n> [n2] }
procedure VersusUsage(E: TZSEngine; Slot: LongInt);
begin
  Out(E, Slot, 'Usage: !versus [flag] [pg] <player> [player2]   !versusi [flag] <n> [n2]   (!versus help: the flags)',
    CLR_WARN);
  Out(E, Slot, 'player2 = you when left out; a name with spaces: its #id; n = a position of the points ranking', CLR_HINT);
end;

{ !versus [flag] [pg] <p> [p2]: two players head to head, p2 = the caller when left out; the whole text
  is one player when it is exactly the name of a player on the server or of an account, else the first
  word is p and the rest p2. !versusi [flag] <n> [n2]: the same by ranking positions. }
procedure CmdVersus(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  A: TMxArgs;
  T, A1, A2: AnsiString;
  W: TStringArray;
  IA, IB: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_RIVALS);
    Exit;
  end;
  if not MxParse(E, Rest, MXA_PAGE or MXA_PLAYER or MXA_TWO, MXF_RIVALS, ByRank, A) or (A.Who = '') then
  begin
    VersusUsage(E, Slot);
    Exit;
  end;
  if ByRank then
  begin
    IA := IndexAtRank(E, A.Who);
    if not E.DB.Valid(IA) then
    begin
      NotFound(E, Slot);
      Exit;
    end;
    if A.Who2 = '' then
      IB := MxAccount(E, Slot, '', False, '!versusi <n> <n2>')
    else
      IB := MxAccount(E, Slot, A.Who2, True, '');
  end
  else
  begin
    T := A.Who;
    if (Pos(' ', T) = 0) or OnlineNameIs(E, T) or (Length(E.DB.IndexesOfName(T)) > 0) then
    begin
      A1 := T;
      A2 := '';
    end
    else
    begin
      W := SplitWords(T, 2);
      A1 := W[0];
      A2 := Trim(W[1]);
    end;
    IA := FindProfileText(E, A1, Slot);
    if not E.DB.Valid(IA) then
    begin
      NotFound(E, Slot);
      Exit;
    end;
    IB := MxAccount(E, Slot, A2, False, '!versus <player> <player2>');
  end;
  if IB < 0 then
    Exit;
  if IA = IB then
  begin
    Out(E, Slot, 'Two different players, please: !versus <player> [player2].', CLR_WARN);
    Exit;
  end;
  ListVersus(E, Slot, E.DB.Profiles[IA]^.ID, E.DB.Profiles[IB]^.ID, A.Sort, A.Asc, A.Page);
end;

{ !playermatchup [w] [flag] [pg] [p] (also !playermatrix; the order of before, [p] [w], works as well),
  !playermatchupi [w] [flag] [pg] <n>: the weapon matchups of a player over all his maps }
procedure CmdPlayerMatchup(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  A: TMxArgs;
  Who: AnsiString;
  S, Idx: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_DUELS);
    Exit;
  end;
  if not MxParse(E, Rest, MXA_WEAPON or MXA_PAGE or MXA_PLAYER, MXF_DUELS, ByRank, A) then
  begin
    MxRankUsage(E, Slot, '!playermatchupi [w] [flag] [pg] <n>');
    Exit;
  end;
  Who := A.Who;
  S := A.WeaponSlot;
  if not ByRank and (S < 0) then
    SplitWhoWeapon(E, A.Who, Who, S);
  Idx := MxAccount(E, Slot, Who, ByRank, '!playermatchup [w] <player>');
  if Idx >= 0 then
    ListPlayerDuels(E, Slot, Idx, '', S, A.Sort, A.Asc, A.Page);
end;

{ !mapplayermatchup [map] [flag] [pg] [p] (also !mapplayermatrix), !mapplayermatchupi [map] [flag]
  [pg] <n>: the weapon matchups of a player on one map }
procedure CmdMapPlayerMatchup(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean);
var
  A: TMxArgs;
  Idx: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_DUELS);
    Exit;
  end;
  if not MxParse(E, Rest, MXA_MAP or MXA_PAGE or MXA_PLAYER, MXF_DUELS, ByRank, A) then
  begin
    MxRankUsage(E, Slot, '!mapplayermatchupi [map] [flag] [pg] <n>');
    Exit;
  end;
  if MxMapAccount(E, Slot, A, ByRank, '!mapplayermatchup', Idx) then
    ListPlayerDuels(E, Slot, Idx, A.MapName, -1, A.Sort, A.Asc, A.Page);
end;

{ !mapmatchup [map] [w] [flag] [pg] (also !mapmatrix): the weapon matchups of a map; a text that is
  exactly a weapon's name is the weapon on the map played now, unless a map is called so. The words no
  part took are the map (after a weapon or the flags), else a weapon by a part or a typo of its name. }
procedure CmdMapMatchup(E: TZSEngine; Slot: LongInt; const Rest: AnsiString);
var
  A: TMxArgs;
  S, MI: LongInt;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_DUELS);
    Exit;
  end;
  MxParse(E, Rest, MXA_MAP or MXA_WEAPON or MXA_PAGE, MXF_DUELS, False, A);
  if A.Rest <> '' then
  begin
    MI := -1;
    if not A.MapGiven then
      MI := MatrixMapIndex(E, A.Rest);
    if MI >= 0 then
    begin
      A.MapName := E.DB.Maps[MI].MapName;
      A.MapGiven := True;
    end
    else if A.WeaponSlot < 0 then
    begin
      S := WeaponSlotOrSay(E, Slot, A.Rest, '!wep');
      if S < 0 then
        Exit;
      A.WeaponSlot := S;
    end
    else if not A.MapGiven then
    begin
      Out(E, Slot, 'Map not found: ' + Copy(A.Rest, 1, 40), CLR_BAD);
      Exit;
    end
    else
      Out(E, Slot, Format('[Note] Ignored: %s (!mapmatchup help lists the sort flags)', [Copy(A.Rest, 1, 40)]), CLR_HINT);
  end;
  if A.MapName = '' then
  begin
    Out(E, Slot, 'No map is being played: name one, e.g. !mapmatchup <map> [weapon].', CLR_WARN);
    Exit;
  end;
  ShowMapMatchups(E, Slot, A.MapName, A.WeaponSlot, A.Sort, A.Asc, A.Page);
end;

{ !mapweapstats [map] [flag] [pg] (also !mapweapsstats): every weapon used on a map. It goes through
  every record of the map, so it counts toward the list limits - once the map is known. }
procedure CmdMapWeapStats(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; Admin: Boolean);
var
  A: TMxArgs;
begin
  if SameText(Rest, 'help') then
  begin
    MxFlagsHelp(E, Slot, MXF_WEAPONS);
    Exit;
  end;
  MxParse(E, Rest, MXA_MAP or MXA_PAGE, MXF_WEAPONS, False, A);
  if MxMapOfView(E, Slot, A, '!mapweapstats') and HeavyAllowed(E, Slot, Admin) then
    ListMapWeapons(E, Slot, A.MapName, A.Sort, A.Asc, A.Page);
end;

{ !mapwep <weapon> [map] (also !mapweapon): one weapon on a map; the weapon is the longest start of
  the text (up to three words) that names one - whole names first, then a part or a typo of a single
  word -, the rest is the map (the one played now when left out). A heavy list, as !mapweapstats. }
procedure CmdMapWeapon(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; Admin: Boolean);
var
  W: TStringArray;
  At: TIntArray;
  n, h, k, Pass, Wep, S, MI: LongInt;
  Head, MapText, MapName: AnsiString;
begin
  if (Rest = '') or SameText(Rest, 'help') then
  begin
    WeaponHelp(E, Slot, 'Map Weapon Lookup', 'Usage: !mapwep <weapon> [map]   (the map played now when left out)',
      'e.g. !mapwep ak   !mapwep barrett ctf_ash   !mapwep desert eagles ash   !mapwep 8');
    Exit;
  end;
  MxWords(Rest, W, At);
  n := Length(W);
  S := -1;
  MapText := '';
  for Pass := 1 to 2 do
  begin
    for h := Min(3, n) downto 1 do
    begin
      Head := '';
      for k := 0 to h - 1 do
      begin
        if Head <> '' then
          Head := Head + ' ';
        Head := Head + W[k];
      end;
      if Pass = 1 then
        Wep := ResolveWeaponExact(Head)
      else
        Wep := ResolveWeapon(Head);
      if (Wep >= 0) and (WepSlot(Wep) >= 0) then
      begin
        S := WepSlot(Wep);
        if h < n then
          MapText := TrimRight(Copy(Rest, At[h], MaxInt));
        Break;
      end;
    end;
    if S >= 0 then
      Break;
  end;
  if S < 0 then
  begin
    Out(E, Slot, WeaponProblem(W[0], '!mapwep'), CLR_BAD);
    Exit;
  end;
  if MapText = '' then
  begin
    MapName := MatrixMapNow(E);
    if MapName = '' then
    begin
      Out(E, Slot, 'No map is being played: name one, e.g. !mapwep ' + LowerCase(SlotShortName(S)) + ' <map>.', CLR_WARN);
      Exit;
    end;
  end
  else
  begin
    MI := MatrixMapIndex(E, MapText);
    if MI < 0 then
    begin
      Out(E, Slot, 'Map not found: ' + Copy(MapText, 1, 40), CLR_BAD);
      Exit;
    end;
    MapName := E.DB.Maps[MI].MapName;
  end;
  if HeavyAllowed(E, Slot, Admin) then
    ShowMapWeapon(E, Slot, MapName, S);
end;

{ the first field of the query of a list of the per-map data (the fields end with |); Q keeps the rest }
function CutField(var Q: AnsiString): AnsiString;
var
  p: LongInt;
begin
  p := Pos('|', Q);
  if p = 0 then
  begin
    Result := Q;
    Q := '';
  end
  else
  begin
    Result := Copy(Q, 1, p - 1);
    Delete(Q, 1, p);
  end;
end;

{ /zs_next and the others on a list of the per-map data, from what the list kept in its query: the
  account ids, a weapon slot, the order and the map (last, as it may hold anything) }
procedure MatrixPage(E: TZSEngine; Slot, Kind: LongInt; const Query: AnsiString; Page: LongInt);
var
  Q: AnsiString;
  Idx, S, Code, Other: LongInt;
begin
  Q := Query;
  if Kind = QK_MAPRIVALS then
  begin
    Code := StrToIntDef(CutField(Q), 0);
    ListMapRivals(E, Slot, Q, MxSortOf(Code), MxAscOf(Code), Page);
    Exit;
  end;
  if Kind = QK_MAPWEAPONS then
  begin
    Code := StrToIntDef(CutField(Q), 0);
    ListMapWeapons(E, Slot, Q, MxSortOf(Code), MxAscOf(Code), Page);
    Exit;
  end;
  if Kind = QK_MAPMATCHUP then
  begin
    S := StrToIntDef(CutField(Q), -1);
    Code := StrToIntDef(CutField(Q), 0);
    ShowMapMatchups(E, Slot, Q, S, MxSortOf(Code), MxAscOf(Code), Page);
    Exit;
  end;
  Idx := E.DB.IndexOfId(StrToIntDef(CutField(Q), 0));
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  case Kind of
    QK_PLAYERMAPS:
      begin
        Code := StrToIntDef(CutField(Q), 0);
        ListPlayerMaps(E, Slot, Idx, MxSortOf(Code), MxAscOf(Code), Page);
      end;
    QK_RIVALS:
      begin
        Code := StrToIntDef(CutField(Q), 0);
        ListRivals(E, Slot, Idx, Q, MxSortOf(Code), MxAscOf(Code), Page);
      end;
    QK_VERSUS:
      begin
        Other := StrToIntDef(CutField(Q), 0);
        Code := StrToIntDef(CutField(Q), 0);
        ListVersus(E, Slot, E.DB.Profiles[Idx]^.ID, Other, MxSortOf(Code), MxAscOf(Code), Page);
      end;
    QK_PMATCHUP:
      begin
        S := StrToIntDef(CutField(Q), -1);
        if (S < -1) or (S >= WSLOT_COUNT) then
          S := -1;
        Code := StrToIntDef(CutField(Q), 0);
        ListPlayerDuels(E, Slot, Idx, Q, S, MxSortOf(Code), MxAscOf(Code), Page);
      end;
  end;
end;
