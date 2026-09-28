{ zs_commands: map statistics and map rankings }

const
  MAP_METRICS: array[0..32] of TMetricDef = (
    (Aliases: ' time playtime duration '; Header: 'Playtime'; Fmt: mfTime; Asc: False),             { 0 }
    (Aliases: ' matches plays games '; Header: 'Matches'; Fmt: mfInt; Asc: False),
    (Aliases: ' kills kill k '; Header: 'Kills'; Fmt: mfInt; Asc: False),
    (Aliases: ' selfkills suicides self '; Header: 'Selfkills'; Fmt: mfInt; Asc: False),
    (Aliases: ' pace '; Header: 'Kills/min'; Fmt: mfDec1; Asc: False),
    (Aliases: ' avgmatch '; Header: 'AvgMatch'; Fmt: mfTime; Asc: False),                           { 5 }
    (Aliases: ' joins traffic '; Header: 'Joins'; Fmt: mfInt; Asc: False),
    (Aliases: ' leaves '; Header: 'Leaves'; Fmt: mfInt; Asc: False),
    (Aliases: ' quitrate qr '; Header: 'QuitRate'; Fmt: mfPct; Asc: False),
    (Aliases: ' kicks '; Header: 'Kicks'; Fmt: mfInt; Asc: False),
    (Aliases: ' spec specjoins '; Header: 'SpecJoins'; Fmt: mfInt; Asc: False),                     { 10 }
    (Aliases: ' caps flags '; Header: 'Caps'; Fmt: mfInt; Asc: False),
    (Aliases: ' returns '; Header: 'Returns'; Fmt: mfInt; Asc: False),
    (Aliases: ' grabs '; Header: 'Grabs'; Fmt: mfInt; Asc: False),
    (Aliases: ' drops '; Header: 'Drops'; Fmt: mfInt; Asc: False),
    (Aliases: ' thrown '; Header: 'Thrown'; Fmt: mfInt; Asc: False),                                { 15 }
    (Aliases: ' rwins rounds '; Header: 'Rounds'; Fmt: mfInt; Asc: False),
    (Aliases: ' fastcap speed '; Header: 'FastCap'; Fmt: mfSec; Asc: True),
    (Aliases: ' comebacks comeback '; Header: 'Comebacks'; Fmt: mfInt; Asc: False),
    (Aliases: ' close closematches '; Header: 'CloseMatch'; Fmt: mfInt; Asc: False),
    (Aliases: ' draws '; Header: 'Draws'; Fmt: mfInt; Asc: False),                                  { 20 }
    (Aliases: ' aborted '; Header: 'Aborted'; Fmt: mfInt; Asc: False),
    (Aliases: ' loads '; Header: 'Loads'; Fmt: mfInt; Asc: False),
    (Aliases: ' humans avghumans '; Header: 'AvgHumans'; Fmt: mfDec1; Asc: False),
    (Aliases: ' avgcap '; Header: 'AvgCap'; Fmt: mfSec; Asc: True),
    (Aliases: ' votes '; Header: 'Votes'; Fmt: mfInt; Asc: False),                                  { 25 }
    (Aliases: ' votedin chosen '; Header: 'VotedIn'; Fmt: mfInt; Asc: False),
    (Aliases: ' votedaway votewins '; Header: 'VotedAway'; Fmt: mfInt; Asc: False),
    (Aliases: ' stayed retention '; Header: 'Stayed%'; Fmt: mfPct; Asc: False),
    (Aliases: ' leftafter emptying '; Header: 'LeftAfter%'; Fmt: mfPct; Asc: False),
    (Aliases: ' endplayers lastplayers '; Header: 'EndPlayers'; Fmt: mfDec1; Asc: False),         { 30 }
    { the last second played with the statistics on, and the last time the map ran at all }
    (Aliases: ' lastplayed played '; Header: 'LastPlayed'; Fmt: mfDate; Asc: False),
    (Aliases: ' lastloaded loaded '; Header: 'LastLoaded'; Fmt: mfDate; Asc: False)                { 32 }
  );

{ every ended match adds its length; data from before 5.1 has no count of them yet }
function AvgMatchSeconds(const M: TMapProfile): Double;
begin
  { a reset map can have a base above the sum: the average is then simply unknown }
  Result := Max(0.0, SafeDivD(M.MatchDurationSum - M.MatchDurationBase, M.MatchDurationCount));
end;

{ of the players on the teams when a match here ended, the share still on the server two minutes
  into the next map; -1 before the first measured end }
function StayedPercent(const M: TMapProfile): Double;
begin
  if M.EndHumansSum > 0 then
    Result := Min(100.0, M.StayedHumansSum * 100.0 / M.EndHumansSum)
  else
    Result := -1;
end;

function MapMetricValue(const M: TMapProfile; Id: LongInt): Double;
begin
  case Id of
    0: Result := M.ActiveTimePlays;
    1: Result := M.ActiveMapPlays;
    2: Result := M.Kills;
    3: Result := M.Selfkills;
    4: Result := SafeDivD(M.Kills * 60.0, M.ActiveTimePlays);
    5: Result := AvgMatchSeconds(M);
    6: Result := M.JoinGameCount;
    7: Result := M.LeaveGameCount;
    8: Result := Min(100.0, SafeDivD(M.LeaveGameCount * 100.0, M.JoinGameCount));
    9: Result := M.KickedCount;
    10: Result := M.JoinToSpectator;
    11: Result := M.FlagsScore;
    12: Result := M.FlagsReturns;
    13: Result := M.FlagsGrabs;
    14: Result := M.FlagsDrop;
    15: Result := M.FlagsThrown;
    16: Result := M.AlphaRoundWins + M.BravoRoundWins + M.CharlieRoundWins + M.DeltaRoundWins;
    17: Result := M.FastestCapSeconds;
    18: Result := M.ComebackMatches;
    19: Result := M.CloseMatches;
    20: Result := M.Draws;
    21: Result := M.MatchesAborted;
    22: Result := M.LoadCount;
    23: Result := SafeDivD(M.HumansSampleSum, M.HumansSampleCount);
    24: Result := SafeDivD(M.CapTimeSum, M.CapTimeCount);
    25: Result := M.VoteStarts;
    26: Result := M.VotedIn;
    27: Result := M.VotesPassed;
    28: Result := Max(0.0, StayedPercent(M));
    29:
      if StayedPercent(M) >= 0 then
        Result := 100 - StayedPercent(M)
      else
        Result := 0;
    30: Result := SafeDivD(M.CurveSum[9], M.CurveSecs[9]);
    31: Result := M.LastPlayedTime;
    32: Result := M.LastLoadedTime;
    else Result := 0;
  end;
end;

var
  { SharedMaps: the maps only the other servers know, after the maps of this server in the lists
    (a row at or above MapCount is one of these); set again by every map list }
  PoolMapKeys: TStringArray;

function MapListCount(E: TZSEngine): LongInt;
begin
  Result := E.DB.MapCount + Length(PoolMapKeys);
end;

{ a row of a map list: a map of this server (with the others added) or one only the others know }
function MapAt(E: TZSEngine; Row: LongInt; var Tmp: TMapProfile): PMapProfile;
begin
  if Row < E.DB.MapCount then
    Result := SharedMapView(E, Row, Tmp)
  else
  begin
    Result := PoolMapView(E, PoolMapKeys[Row - E.DB.MapCount], Tmp);
    if Result = nil then
    begin
      ClearMap(Tmp);
      Tmp.MapName := PoolMapKeys[Row - E.DB.MapCount];
      Result := @Tmp;
    end;
  end;
end;

{ maps ordered by the time they were played with at least two players }
function MapsByPlaytime(E: TZSEngine): TIntArray;
var
  k: LongInt;
  M: PMapProfile;
  Tmp: TMapProfile;
begin
  PoolMapKeys := MapPoolOnly(E);
  PrepareSort(MapListCount(E), 1);
  for k := 0 to MapListCount(E) - 1 do
  begin
    M := MapAt(E, k, Tmp);
    SortKeys[k] := M^.ActiveTimePlays;
    SortTie[k] := M^.ActiveMapPlays;
  end;
  Result := OrderedRows(MapListCount(E));
end;

function MapPlayRank(E: TZSEngine; MapIndex: LongInt): LongInt;
var
  Rows: TIntArray;
  k: LongInt;
begin
  Rows := MapsByPlaytime(E);
  for k := 0 to High(Rows) do
    if Rows[k] = MapIndex then
      Exit(k + 1);
  Result := 1;
end;

{ the words a map title gets when the maps of every server are added (SharedMaps) }
function MapsAll(E: TZSEngine): AnsiString;
begin
  if MapsShared(E) then
    Result := ' of All Servers'
  else
    Result := '';
end;

procedure MapRows(E: TZSEngine; Slot: LongInt; const Title: AnsiString; const Rows: TIntArray; First, Last, Mark: LongInt);
const
  { place, map, played time, matches, kills, selfkills or caps (+ the marks): at most 84 of LINE_W }
  C: array[0..5] of LongInt = (5, 28, 14, 10, 9, 5);
var
  k, Color: LongInt;
  M: PMapProfile;
  Tmp: TMapProfile;
  Caps: Boolean;
  Suffix, LastCell: AnsiString;
begin
  { captures only where flags are captured; Teammatch and Hold the Flag have none }
  Caps := E.Match.GameStyle in [GS_CTF, GS_INF];
  Header(E, Slot, Title, LINE_W);
  if Caps then
    Row(E, Slot, ['#', 'Map Name', 'Played Time', 'Matches', 'Kills', 'Caps'], C, CLR_SUBHEADER)
  else
    Row(E, Slot, ['#', 'Map Name', 'Played Time', 'Matches', 'Kills', 'Selfs'], C, CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  for k := First to Last do
  begin
    M := MapAt(E, Rows[k - 1], Tmp);
    Suffix := '';
    Color := CLR_OTHER_ROW;
    if Rows[k - 1] = E.Match.MapIndex then
    begin
      Color := CLR_YOU;
      Suffix := ' <actual>';
    end;
    if k = Mark then
    begin
      Suffix := Suffix + ' <*>';
      if Color <> CLR_YOU then
        Color := CLR_SUBHEADER;
    end;
    if Caps then
      LastCell := Num(M^.FlagsScore)
    else
      LastCell := Num(M^.Selfkills);
    Row(E, Slot, [IntToStr(k), Copy(M^.MapName, 1, C[1] - 1), FormatDurationShort(M^.ActiveTimePlays), Num(M^.ActiveMapPlays),
      Num(M^.Kills), LastCell + Suffix], C, Color);
  end;
end;

procedure ListTopMaps(E: TZSEngine; Slot, Page: LongInt);
const
  PER_PAGE = 10;
var
  Rows: TIntArray;
  Pages, First: LongInt;
begin
  Rows := MapsByPlaytime(E);
  if MapListCount(E) = 0 then
  begin
    Out(E, Slot, 'No map records yet.', CLR_HEADER);
    Exit;
  end;
  Pages := PageCount(MapListCount(E), PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE + 1;
  MapRows(E, Slot, Format('Top Maps%s [Page %d/%d] (Total: %d)', [MapsAll(E), Page, Pages, MapListCount(E)]), Rows, First,
    Min(MapListCount(E), First + PER_PAGE - 1), 0);
  PageHint(E, Slot, Page, Pages, 'maps');
  Remember(E, Slot, QK_TOPMAPS, '', Page, Pages);
end;

procedure ListTopMapsAround(E: TZSEngine; Slot, Rank: LongInt);
const
  PER_PAGE = 10;
var
  Rows: TIntArray;
  First, Last, Count: LongInt;
begin
  Rows := MapsByPlaytime(E);
  Count := MapListCount(E);
  if Count = 0 then
  begin
    Out(E, Slot, 'No map records yet.', CLR_HEADER);
    Exit;
  end;
  Rank := EnsureRange(Rank, 1, Count);
  First := Max(1, Rank - PER_PAGE div 2);
  Last := Min(Count, First + PER_PAGE - 1);
  First := Max(1, Last - PER_PAGE + 1);
  MapRows(E, Slot, Format('Top Maps%s [Rank #%d-%d of %d]', [MapsAll(E), First, Last, Count]), Rows, First, Last, Rank);
  Out(E, Slot, 'Move with /zs_next and /zs_prev, or jump with !topmapsi <position>.', CLR_HINT);
  Remember(E, Slot, QK_TOPMAPS, '', (First - 1) div PER_PAGE + 1, PageCount(Count, PER_PAGE));
end;

procedure TopMapsByHelp(E: TZSEngine; Slot: LongInt);
const
  W = LINE_W;
begin
  Header(E, Slot, 'ZitroStats Top Maps - !topmapsby Help', W);
  Out(E, Slot, 'Usage: !topmapsby <metric> [page]  or  !topmapsby <m1>; <m2>; <m3>  (up to 5)', CLR_HINT);
  Out(E, Slot, 'Examples: !topmapsby pace  |  !topmapsby selfkills; returns; caps', CLR_HINT);
  Rule(E, Slot, W);
  Out(E, Slot, '[Activity & Retention]', CLR_HEADER);
  Out(E, Slot, '  time, matches, pace, avgmatch, joins, leaves, quitrate, kicks, spec, loads, votes', WHITE);
  Out(E, Slot, '  humans (average players), aborted, draws, endplayers (last 10% of a match)', WHITE);
  Out(E, Slot, '[Votes & Players After the Map]', CLR_HEADER);
  Out(E, Slot, '  votedin, votedaway (votes won here), stayed, leftafter (2 min after the map)', WHITE);
  Out(E, Slot, '[Combat & Objectives]', CLR_HEADER);
  Out(E, Slot, '  kills, selfkills, caps, returns, grabs, drops, thrown, rwins, fastcap, avgcap,', WHITE);
  Out(E, Slot, '  comebacks, close', WHITE);
  Out(E, Slot, '[Dates, newest first]', CLR_HEADER);
  Out(E, Slot, '  lastplayed (the last game with the statistics on), lastloaded (the map ran at all)', WHITE);
  Footer(E, Slot, W);
end;

procedure ListTopMapsBy(E: TZSEngine; Slot: LongInt; const Query: AnsiString; Page: LongInt);
const
  PER_PAGE = 10;
  W = LINE_W;
  { place 5, the map and up to five metrics of 12: with " <actual>" after them at most LINE_W }
  NAME_W = 26;
  METRIC_W = 12;
var
  Tokens, Heads: TStringArray;
  Ids, Rows: TIntArray;
  k, f, n, Pages, First, NameW, Color: LongInt;
  Ignored, Canon, Title, Line: AnsiString;
  M: PMapProfile;
  Tmp: TMapProfile;
  ShowKills, ShowMatches, ShowTime: Boolean;
begin
  Tokens := MetricTokens(Query, Page);
  Ids := nil;
  Ignored := '';
  Canon := '';
  for k := 0 to High(Tokens) do
  begin
    f := MetricIndex(MAP_METRICS, Tokens[k]);
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
    Out(E, Slot, 'No valid map metric given.', CLR_BAD);
    if Ignored <> '' then
      Out(E, Slot, '[Note] Unknown: ' + Ignored, CLR_HINT);
    TopMapsByHelp(E, Slot);
    Exit;
  end;
  PoolMapKeys := MapPoolOnly(E);
  n := MapListCount(E);
  if n = 0 then
  begin
    Out(E, Slot, 'No map records yet.', CLR_HEADER);
    Exit;
  end;
  PrepareSort(n, Length(Ids));
  for k := 0 to n - 1 do
  begin
    M := MapAt(E, k, Tmp);
    for f := 0 to High(Ids) do
      SortKeys[k * SortCols + f] := SortValue(MapMetricValue(M^, Ids[f]), MAP_METRICS[Ids[f]].Asc);
    SortTie[k] := M^.ActiveTimePlays;
  end;
  Rows := OrderedRows(n);
  Pages := PageCount(n, PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * PER_PAGE;
  Heads := nil;
  SetLength(Heads, Length(Ids));
  for f := 0 to High(Ids) do
    Heads[f] := MAP_METRICS[Ids[f]].Header;
  Title := Format('%s [Page %d/%d]', [MapsAll(E), Page, Pages]);
  Header(E, Slot, 'Top Maps by ' + MetricTitle(Heads, W - 4 - Length('Top Maps by ' + Title)) + Title, W);
  ShowKills := False;
  ShowMatches := False;
  ShowTime := False;
  NameW := NAME_W;
  if Length(Ids) = 1 then
  begin
    ShowKills := Ids[0] <> MetricIndex(MAP_METRICS, 'kills');
    ShowMatches := Ids[0] <> MetricIndex(MAP_METRICS, 'matches');
    ShowTime := Ids[0] <> MetricIndex(MAP_METRICS, 'time');
    Line := PadR('#', 5) + PadR('Map Name', NameW) + PadR(MAP_METRICS[Ids[0]].Header, 16);
    if ShowKills then
      Line := Line + PadR('Kills', 10);
    if ShowMatches then
      Line := Line + PadR('Matches', 10);
    if ShowTime then
      Line := Line + 'Playtime';
    Out(E, Slot, TrimRight(Line), CLR_SUBHEADER);
  end
  else
  begin
    Line := PadR('#', 5) + PadR('Map Name', NameW);
    for f := 0 to High(Ids) do
      Line := Line + PadR(MAP_METRICS[Ids[f]].Header, METRIC_W);
    Out(E, Slot, TrimRight(Line), CLR_SUBHEADER);
  end;
  Rule(E, Slot, W);
  for k := First to Min(n - 1, First + PER_PAGE - 1) do
  begin
    M := MapAt(E, Rows[k], Tmp);
    if Rows[k] = E.Match.MapIndex then
      Color := CLR_YOU
    else
      Color := RowColor(k + 1, False);
    Line := PadR(IntToStr(k + 1), 5) + PadR(Copy(M^.MapName, 1, NameW - 1), NameW);
    if Length(Ids) = 1 then
    begin
      { a date alone has room for its hour as well }
      if MAP_METRICS[Ids[0]].Fmt = mfDate then
        Line := Line + PadR(DateText(MapMetricValue(M^, Ids[0]), 'dd.mm.yy hh:nn'), 16)
      else
        Line := Line + PadR(MetricText(MAP_METRICS[Ids[0]].Fmt, MapMetricValue(M^, Ids[0])), 16);
      if ShowKills then
        Line := Line + PadR(Num(M^.Kills), 10);
      if ShowMatches then
        Line := Line + PadR(Num(M^.ActiveMapPlays), 10);
      if ShowTime then
        Line := Line + FormatDurationShort(M^.ActiveTimePlays);
    end
    else
      for f := 0 to High(Ids) do
        Line := Line + PadR(Copy(MetricText(MAP_METRICS[Ids[f]].Fmt, MapMetricValue(M^, Ids[f])), 1, METRIC_W - 1), METRIC_W);
    if Rows[k] = E.Match.MapIndex then
      Line := TrimRight(Line) + ' <actual>';
    Out(E, Slot, TrimRight(Line), Color);
  end;
  if Ignored <> '' then
    Out(E, Slot, '[Note] Ignored unknown metric(s): ' + Ignored, CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'maps');
  Remember(E, Slot, QK_TOPMAPSBY, Canon, Page, Pages);
end;

function BiasBar(A, B: LongInt): AnsiString;
var
  Filled: LongInt;
begin
  Filled := EnsureRange(Round(SafeDivD(A * 20.0, A + B)), 0, 20);
  Result := StringOfChar('#', Filled) + '|' + StringOfChar('=', 20 - Filled);
end;

{ top three of one session value among the players online; nobody leads with none of a count, or
  when nothing changed for anybody }
procedure LeaderRow(E: TZSEngine; Slot: LongInt; const Title: AnsiString; const Slots, Values: array of LongInt; Count: LongInt;
  SignedValues: Boolean);
const
  { the title and three places: LINE_W }
  TITLE_W = 10;
  PLACE_W = 30;
var
  Used: array[0..MAX_PLAYERS - 1] of Boolean;
  Place, k, Best, Shown: LongInt;
  Line, V: AnsiString;
  Any: Boolean;
begin
  FillChar(Used, SizeOf(Used), 0);
  Line := PadR('[' + Title + ']', TITLE_W);
  Shown := 0;
  Any := False;
  for k := 0 to Count - 1 do
    if Values[k] <> 0 then
      Any := True;
  if not Any then
    Count := 0;
  for Place := 1 to Min(3, Count) do
  begin
    Best := -1;
    for k := 0 to Count - 1 do
      if not Used[k] and ((Best < 0) or (Values[k] > Values[Best])) then
        Best := k;
    if (Best < 0) or (not SignedValues and (Values[Best] <= 0)) then
      Break;
    Used[Best] := True;
    if SignedValues then
      V := SignedShort(Values[Best])
    else
      V := Num(Values[Best]);
    Line := Line + PadR(Format('%d. %s (%s)', [Place, Copy(E.Live[Slots[Best]].Name, 1, 16), V]), PLACE_W);
    Inc(Shown);
  end;
  if Shown = 0 then
    Line := Line + 'nobody yet';
  Out(E, Slot, TrimRight(Line), WHITE);
end;

{ Where people die on a map, shrunk to the console. Every character stands for a patch of the map:
  the more kills and deaths happened there, the denser the sign. A and B mark the flag bases once
  main.pas has reported them. }
procedure CmdHeatmap(E: TZSEngine; Slot: LongInt; const Arg: AnsiString);
const
  W = LINE_W;
  { 60 x 16 signs keep about the shape of a map in the console; the picture sits in the middle }
  COLS = 60;
  ROWS = 16;
  MIN_EVENTS = 10;
  SHADES: array[1..6] of AnsiChar = ('.', ':', '+', '*', '#', '@');
var
  MI, k, c, r, MinC, MaxC, MinR, MaxR, Col, Row, Best, V, Total, Spot, Pick: LongInt;
  M: PMapProfile;
  Tmp: TMapProfile;
  Grid: array[0..ROWS - 1, 0..COLS - 1] of LongInt;
  Canvas: array[0..ROWS - 1] of AnsiString;
  Used: array of Boolean;
  HasA, HasB: Boolean;
  Indent, Legend: AnsiString;

  procedure Widen(Px, Py: Single);
  begin
    MinC := Min(MinC, Floor(Px / 64));
    MaxC := Max(MaxC, Floor(Px / 64));
    MinR := Min(MinR, Floor(Py / 64));
    MaxR := Max(MaxR, Floor(Py / 64));
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
  if Arg = '' then
    MI := E.Match.MapIndex
  else
    MI := FindMapText(E, Arg);
  M := nil;
  if (MI < 0) or (MI >= E.DB.MapCount) then
  begin
    { SharedMaps: a map this server never played, from the other servers }
    if Arg <> '' then
      M := PoolMapView(E, FindPoolMap(E, Arg), Tmp, True);
    if M = nil then
    begin
      Out(E, Slot, 'Map not found.', CLR_BAD);
      Exit;
    end;
  end
  else
    M := SharedMapView(E, MI, Tmp, True);
  if Length(M^.Heat) = 0 then
  begin
    Out(E, Slot, 'Nobody has died on ' + M^.MapName + ' yet.', CLR_WARN);
    Exit;
  end;
  MinC := MaxInt;
  MaxC := -MaxInt;
  MinR := MaxInt;
  MaxR := -MaxInt;
  for k := 0 to High(M^.Heat) do
  begin
    c := (M^.Heat[k].Cell mod 4096) - 2048;
    r := (M^.Heat[k].Cell div 4096) - 2048;
    MinC := Min(MinC, c);
    MaxC := Max(MaxC, c);
    MinR := Min(MinR, r);
    MaxR := Max(MaxR, r);
  end;
  HasA := (M^.AlphaFlagX <> 0) or (M^.AlphaFlagY <> 0);
  HasB := (M^.BravoFlagX <> 0) or (M^.BravoFlagY <> 0);
  if HasA then
    Widen(M^.AlphaFlagX, M^.AlphaFlagY);
  if HasB then
    Widen(M^.BravoFlagX, M^.BravoFlagY);

  FillChar(Grid, SizeOf(Grid), 0);
  Best := 0;
  Total := 0;
  for k := 0 to High(M^.Heat) do
  begin
    Col := ColOfCell((M^.Heat[k].Cell mod 4096) - 2048);
    Row := RowOfCell((M^.Heat[k].Cell div 4096) - 2048);
    V := M^.Heat[k].Kills + M^.Heat[k].Deaths;
    Inc(Grid[Row, Col], V);
    Inc(Total, V);
    Best := Max(Best, Grid[Row, Col]);
  end;
  for Row := 0 to ROWS - 1 do
  begin
    Canvas[Row] := StringOfChar(' ', COLS);
    for Col := 0 to COLS - 1 do
      if Grid[Row, Col] > 0 then
        Canvas[Row][Col + 1] := SHADES[EnsureRange(1 + (Grid[Row, Col] * 5) div Max(1, Best), 1, 6)];
  end;
  if HasA then
    Canvas[RowOfCell(Floor(M^.AlphaFlagY / 64))][ColOfCell(Floor(M^.AlphaFlagX / 64)) + 1] := 'A';
  if HasB then
    Canvas[RowOfCell(Floor(M^.BravoFlagY / 64))][ColOfCell(Floor(M^.BravoFlagX / 64)) + 1] := 'B';

  Header(E, Slot, '[ Where people die: ' + M^.MapName + ' ]', W);
  if Total < MIN_EVENTS then
    Out(E, Slot, Format('Only %d kills and deaths so far; the picture becomes useful from about %d.',
      [Total, MIN_EVENTS]), CLR_WARN);
  Indent := StringOfChar(' ', (W - COLS - 2) div 2);
  Out(E, Slot, Indent + '+' + StringOfChar('-', COLS) + '+', CLR_ACTIVITY);
  for Row := 0 to ROWS - 1 do
    Out(E, Slot, Indent + '|' + Canvas[Row] + '|', CLR_SHOOTING);
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
  SetLength(Used, Length(M^.Heat));
  for Spot := 1 to Min(3, Length(M^.Heat)) do
  begin
    Pick := -1;
    for k := 0 to High(M^.Heat) do
      if not Used[k] and ((Pick < 0) or
         (M^.Heat[k].Kills + M^.Heat[k].Deaths > M^.Heat[Pick].Kills + M^.Heat[Pick].Deaths)) then
        Pick := k;
    Used[Pick] := True;
    Out(E, Slot, Format('Hot spot %d: %s of the map - %s kills made there, %s deaths', [Spot,
      Where(M^.Heat[Pick].Cell), Num(M^.Heat[Pick].Kills), Num(M^.Heat[Pick].Deaths)]), WHITE);
  end;
  Footer(E, Slot, W);
end;

{ cells in rows of Per, 3 (COLS3) or 4 (COLS4): a cell the mode has not is left out and the next
  one moves up }
procedure PushCell(var Cells: TStringArray; const Text: AnsiString);
begin
  SetLength(Cells, Length(Cells) + 1);
  Cells[High(Cells)] := Text;
end;

procedure FlowCells(E: TZSEngine; Slot: LongInt; const Cells: TStringArray; Per, Color: LongInt);
var
  k, c, n: LongInt;
  Part: array[0..3] of AnsiString;
begin
  Per := EnsureRange(Per, 3, 4);
  k := 0;
  while k <= High(Cells) do
  begin
    n := Min(Per, Length(Cells) - k);
    for c := 0 to n - 1 do
      Part[c] := Cells[k + c];
    if Per = 3 then
      Row(E, Slot, Slice(Part, n), COLS3, Color)
    else
      Row(E, Slot, Slice(Part, n), COLS4, Color);
    Inc(k, n);
  end;
end;

{ !mapstats [map]: the record of a map. The rows of teams, flags and rounds only where the mode
  has them: a free-for-all counts no team wins, draws, close games or comebacks of a map (the
  engine counts those in team matches only), and a survival free-for-all no rounds won. }
procedure CmdMapStats(E: TZSEngine; Slot: LongInt; const Arg: AnsiString);
const
  W = LINE_W;
var
  MI, S, k, n, Idx, BestKills, KillSlot, T, CurveSecs: LongInt;
  Picks: array[0..WSLOT_COUNT - 1] of Int64;
  TeamPicks: array[1..2, 0..WSLOT_COUNT - 1] of Int64;
  AnyPick, AnyTeam, Teams, Rounds, Caps: Boolean;
  AvgText, Line, StayText: AnsiString;
  Cells: TStringArray;
  M: PMapProfile;
  Tmp: TMapProfile;
  Slots, Kills, Points, Extra: array[0..MAX_PLAYERS - 1] of LongInt;
  Games, Wipes: Int64;
begin
  if Arg = '' then
    MI := E.Match.MapIndex
  else
    MI := FindMapText(E, Arg);
  M := nil;
  if (MI < 0) or (MI >= E.DB.MapCount) then
  begin
    { SharedMaps: a map this server never played, from the other servers }
    if Arg <> '' then
      M := PoolMapView(E, FindPoolMap(E, Arg), Tmp);
    if M = nil then
    begin
      Out(E, Slot, 'Map not found.', CLR_BAD);
      Exit;
    end;
    MI := -1;
    Header(E, Slot, Format('[ Map Statistics: %s - other servers ]', [M^.MapName]), W);
  end
  else
  begin
    M := SharedMapView(E, MI, Tmp);
    if M <> @E.DB.Maps[MI] then
      Header(E, Slot, Format('[ Map Statistics: %s - %d servers ]', [M^.MapName, SharedServerCount(POOL_MAPS) + 1]), W)
    else
      Header(E, Slot, '[ Map Statistics: ' + M^.MapName + ' ]', W);
  end;
  Teams := E.TeamGame;
  { rounds are won by teams; captures happen in CTF and Infiltration only }
  Rounds := E.Match.Survival and Teams;
  Caps := E.Match.GameStyle in [GS_CTF, GS_INF];

  Cells := nil;
  { the time played with the statistics on }
  PushCell(Cells, 'Played Time: ' + FormatDurationShort(M^.ActiveTimePlays));
  PushCell(Cells, 'Matches: ' + Num(M^.ActiveMapPlays));
  PushCell(Cells, 'Kills: ' + Num(M^.Kills));
  PushCell(Cells, 'Selfkills: ' + Num(M^.Selfkills));
  PushCell(Cells, 'Pace: ' + FloatStr(MapMetricValue(M^, 4), 1) + ' k/min');
  { lengths are counted since 5.1; before the first measured match there is no average }
  if M^.MatchDurationCount > 0 then
    AvgText := 'Avg Match: ' + FormatDurationShort(Round(AvgMatchSeconds(M^)))
  else
    AvgText := 'Avg Match: -';
  PushCell(Cells, AvgText);
  PushCell(Cells, 'Quit Rate: ' + FloatStr(MapMetricValue(M^, 8), 1) + '%');
  PushCell(Cells, 'Leaves: ' + Num(M^.LeaveGameCount));
  PushCell(Cells, 'Joins: ' + Num(M^.JoinGameCount));
  PushCell(Cells, 'Spec Joins: ' + Num(M^.JoinToSpectator));
  PushCell(Cells, 'Kicks: ' + Num(M^.KickedCount));
  { played: the last second with the statistics on; loaded: the last time the map ran at all }
  PushCell(Cells, 'Last Played: ' + DateText(M^.LastPlayedTime, 'dd.mm.yy'));
  PushCell(Cells, 'Last Loaded: ' + DateText(M^.LastLoadedTime, 'dd.mm.yy'));
  PushCell(Cells, 'Loads: ' + Num(M^.LoadCount));
  PushCell(Cells, 'Aborted: ' + Num(M^.MatchesAborted));
  if Teams then
    PushCell(Cells, 'Draws: ' + Num(M^.Draws));
  PushCell(Cells, Format('Votes: %s (%s won)', [Num(M^.VoteStarts), Num(M^.VotesPassed)]));
  { measured every second the statistics are on; an imported map may have no second yet }
  if M^.HumansSampleCount > 0 then
    PushCell(Cells, 'Avg Humans: ' + FloatStr(MapMetricValue(M^, 23), 1))
  else
    PushCell(Cells, 'Avg Humans: -');
  if Teams then
  begin
    PushCell(Cells, 'Close: ' + Num(M^.CloseMatches));
    PushCell(Cells, 'Comebacks: ' + Num(M^.ComebackMatches));
  end;
  PushCell(Cells, 'First: ' + DateText(M^.FirstPlayedTime, 'dd.mm.yy'));
  { the score of the winner: the winning team, or the best player of a free-for-all }
  if M^.ScoreCount > 0 then
    PushCell(Cells, 'Avg Win Score: ' + FloatStr(Max(0.0, (M^.ScoreSum - M^.ScoreBase) / M^.ScoreCount), 1))
  else
    PushCell(Cells, 'Avg Win Score: -');
  { main.pas reports where the flags stand in their bases (CTF, INF); the gap needs both of them }
  if ObjectiveMode(E) and ((M^.AlphaFlagX <> 0) or (M^.AlphaFlagY <> 0)) and ((M^.BravoFlagX <> 0) or (M^.BravoFlagY <> 0)) then
    PushCell(Cells, 'Base Gap: ' + FloatStr(Sqrt(Sqr(M^.AlphaFlagX - M^.BravoFlagX) +
      Sqr(M^.AlphaFlagY - M^.BravoFlagY)) / PIXELS_PER_METER, 0) + ' m');
  PushCell(Cells, 'Heatmap: !heatmap');
  PushCell(Cells, 'Kills/Match: ' + FloatStr(SafeDivD(M^.Kills, M^.ActiveMapPlays), 1));
  { the healing fields of the map (regenerating polygons) }
  if M^.HealRegen > 0 then
  begin
    PushCell(Cells, 'Healing: ' + Dmg(M^.HealRegen) + ' HP');
    PushCell(Cells, 'Healing/Match: ' + Dmg(SafeDivD(M^.HealRegen, M^.ActiveMapPlays)) + ' HP');
  end;
  FlowCells(E, Slot, Cells, 4, WHITE);

  { the teams against each other, in the team modes only (also a map shared with a server that
    plays it with teams has these counters) }
  if Teams then
  begin
    Games := Int64(M^.AlphaWins) + M^.BravoWins;
    if M^.CharlieWins + M^.DeltaWins + M^.CharlieRoundWins + M^.DeltaRoundWins > 0 then
    begin
      Section(E, Slot, 'Team Breakdown (Alpha / Bravo / Charlie / Delta)', W);
      Row(E, Slot, ['Alpha: ' + Num(M^.AlphaWins) + ' wins', 'Bravo: ' + Num(M^.BravoWins) + ' wins',
        'Charlie: ' + Num(M^.CharlieWins) + ' wins', 'Delta: ' + Num(M^.DeltaWins) + ' wins'], COLS4, WHITE);
    end
    else if Games > 0 then
    begin
      Section(E, Slot, 'Match Win Bias: Alpha [#] vs Bravo [=]', W);
      Out(E, Slot, Format('Alpha %5s wins (%6s)  [%s]  (%6s) %5s wins Bravo', [Num(M^.AlphaWins), Pct(M^.AlphaWins, Games),
        BiasBar(M^.AlphaWins, M^.BravoWins), Pct(M^.BravoWins, Games), Num(M^.BravoWins)]), WHITE);
      { with few matches the share says little, so the range it can hide is shown as well }
      Out(E, Slot, Format('Alpha share is between %.0f%% and %.0f%% (95%% confidence, %s matches)',
        [WilsonLower(M^.AlphaWins, Games) * 100, (1 - WilsonLower(M^.BravoWins, Games)) * 100, Num(Games)]), CLR_HINT);
    end;
    { survival rounds; a map played in survival before shows them in the other team modes too }
    Games := Int64(M^.AlphaRoundWins) + M^.BravoRoundWins;
    if (Games > 0) and (E.Match.Survival or (Games > 5)) then
    begin
      Section(E, Slot, 'Survival Round Balance (Alpha vs Bravo)', W);
      Out(E, Slot, Format('Alpha %5s rounds (%6s)  [%s]  (%6s) %5s rounds Bravo', [Num(M^.AlphaRoundWins),
        Pct(M^.AlphaRoundWins, Games), BiasBar(M^.AlphaRoundWins, M^.BravoRoundWins), Pct(M^.BravoRoundWins, Games),
        Num(M^.BravoRoundWins)]), WHITE);
    end;
    { the kills made by the players of each team on the map }
    Games := Int64(M^.KillsByTeam[1]) + M^.KillsByTeam[2];
    if M^.KillsByTeam[3] + M^.KillsByTeam[4] > 0 then
    begin
      Section(E, Slot, 'Kill Balance (Alpha / Bravo / Charlie / Delta)', W);
      Row(E, Slot, ['Alpha: ' + Num(M^.KillsByTeam[1]) + ' kills', 'Bravo: ' + Num(M^.KillsByTeam[2]) + ' kills',
        'Charlie: ' + Num(M^.KillsByTeam[3]) + ' kills', 'Delta: ' + Num(M^.KillsByTeam[4]) + ' kills'], COLS4, WHITE);
    end
    else if Games > 0 then
    begin
      Section(E, Slot, 'Kill Balance: Alpha [#] vs Bravo [=]', W);
      Out(E, Slot, Format('Alpha %5s kills (%6s)  [%s]  (%6s) %5s kills Bravo', [Num(M^.KillsByTeam[1]),
        Pct(M^.KillsByTeam[1], Games), BiasBar(M^.KillsByTeam[1], M^.KillsByTeam[2]), Pct(M^.KillsByTeam[2], Games),
        Num(M^.KillsByTeam[2])]), WHITE);
    end;
  end;

  { how the survival rounds of the map ended: in the team modes won by the team that wiped out the
    others or by a capture (CTF, INF), in free-for-all by the last one standing, in both without a
    survivor or cut short by the map change. The ways the current mode ends its rounds show also at
    0, the others only when rounds ended so; free-for-all names no team. }
  Wipes := Int64(M^.RoundsElimination[1]) + M^.RoundsElimination[2] + M^.RoundsElimination[3] +
    M^.RoundsElimination[4];
  if E.Match.Survival or (Wipes + M^.RoundsCapture + M^.RoundsLastStanding + M^.RoundsNoSurvivor +
     M^.RoundsMapChange > 0) then
  begin
    Section(E, Slot, 'How the Survival Rounds Ended', W);
    Cells := nil;
    if Teams then
    begin
      if E.Match.Survival or (M^.RoundsElimination[1] > 0) then
        PushCell(Cells, 'Alpha by elimination: ' + Num(M^.RoundsElimination[1]));
      if E.Match.Survival or (M^.RoundsElimination[2] > 0) then
        PushCell(Cells, 'Bravo by elimination: ' + Num(M^.RoundsElimination[2]));
      if M^.RoundsElimination[3] > 0 then
        PushCell(Cells, 'Charlie by elimination: ' + Num(M^.RoundsElimination[3]));
      if M^.RoundsElimination[4] > 0 then
        PushCell(Cells, 'Delta by elimination: ' + Num(M^.RoundsElimination[4]));
      if (E.Match.Survival and Caps) or (M^.RoundsCapture > 0) then
        PushCell(Cells, 'By capture: ' + Num(M^.RoundsCapture));
      if M^.RoundsLastStanding > 0 then
        PushCell(Cells, 'Last one standing: ' + Num(M^.RoundsLastStanding));
    end
    else
    begin
      if E.Match.Survival or (M^.RoundsLastStanding > 0) then
        PushCell(Cells, 'Last one standing: ' + Num(M^.RoundsLastStanding));
      if Wipes + M^.RoundsCapture > 0 then
        PushCell(Cells, 'Team rounds: ' + Num(Wipes + M^.RoundsCapture));
    end;
    if E.Match.Survival or (M^.RoundsNoSurvivor > 0) then
      PushCell(Cells, 'No survivor: ' + Num(M^.RoundsNoSurvivor));
    if E.Match.Survival or (M^.RoundsMapChange > 0) then
      PushCell(Cells, 'Cut by map change: ' + Num(M^.RoundsMapChange));
    FlowCells(E, Slot, Cells, 3, WHITE);
  end;

  CurveSecs := 0;
  for k := 0 to 9 do
    Inc(CurveSecs, M^.CurveSecs[k]);
  if (CurveSecs >= 60) or (M^.RetentionCount > 0) or (M^.VotedIn + M^.VotesPassed > 0) then
  begin
    Section(E, Slot, 'Players on this Map', W);
    if CurveSecs >= 60 then
    begin
      { average players in every tenth of the match time, start to end }
      Line := 'Over the match (each 10%):';
      for k := 0 to 9 do
        if M^.CurveSecs[k] > 0 then
          Line := Line + ' ' + FloatStr(M^.CurveSum[k] / M^.CurveSecs[k], 1)
        else
          Line := Line + ' -';
      Out(E, Slot, Line, WHITE);
    end;
    if M^.RetentionCount > 0 then
      StayText := Format('After the map %s stayed (%s ends)', [Pct(M^.StayedHumansSum, M^.EndHumansSum), Num(M^.RetentionCount)])
    else
      StayText := 'After the map: not measured yet';
    Row(E, Slot, ['Voted in: ' + Num(M^.VotedIn), 'Voted away: ' + Num(M^.VotesPassed), StayText], COLS4, WHITE);
  end;

  { flags: in the modes with flags, or from matches with flags this map had before }
  if ObjectiveMode(E) or (M^.FlagsScore + M^.FlagsReturns + M^.FlagsGrabs > 0) then
  begin
    Section(E, Slot, 'Objective Telemetry', W);
    Row(E, Slot, ['Caps: ' + Num(M^.FlagsScore), 'Returns: ' + Num(M^.FlagsReturns), 'Grabs: ' + Num(M^.FlagsGrabs),
      Format('Drops: %s (%s thr)', [Num(M^.FlagsDrop), Num(M^.FlagsThrown)])], COLS4, WHITE);
    if M^.FastestCapSeconds > 0 then
      Out(E, Slot, Format('Fastest Cap: %s (by %s) | Avg Cap: %s', [MetricText(mfSec, M^.FastestCapSeconds), M^.FastestCapHolder,
        MetricText(mfSec, MapMetricValue(M^, 24))]), WHITE);
  end;

  BestKills := 0;
  KillSlot := -1;
  AnyPick := False;
  AnyTeam := False;
  for k := 0 to WSLOT_COUNT - 1 do
  begin
    if M^.WeaponKills[k] > BestKills then
    begin
      BestKills := M^.WeaponKills[k];
      KillSlot := k;
    end;
    Picks[k] := M^.WeaponPicks[k];
    if Picks[k] > 0 then
      AnyPick := True;
    for T := 1 to 2 do
    begin
      TeamPicks[T, k] := M^.WeaponPicksTeam[T, k];
      if TeamPicks[T, k] > 0 then
        AnyTeam := True;
    end;
  end;
  if (KillSlot >= 0) or AnyPick then
  begin
    { everybody spawns with a secondary too, so the picks are shown for each group apart }
    Section(E, Slot, 'Arsenal on this Map', W);
    if KillSlot >= 0 then
      Line := Format('Deadliest: %s (%s kills)', [SlotName(KillSlot), Num(BestKills)])
    else
      Line := 'Deadliest: -';
    Row(E, Slot, [Line, TopPickText('Top primary', Picks, False, False)], COLS2, WHITE);
    { what each side takes on this map }
    if Teams and AnyTeam then
      Row(E, Slot, [TopPickText('Alpha picks', TeamPicks[1], False, False), TopPickText('Bravo picks', TeamPicks[2], False, False)],
        COLS2, WHITE);
    Row(E, Slot, [TopPickText('Top secondary', Picks, True, False), ''], COLS2, WHITE);
  end;

  if (MI >= 0) and (MI = E.Match.MapIndex) then
  begin
    Section(E, Slot, 'Match Leaders (players on the server now)', W);
    n := 0;
    for S := 1 to MAX_PLAYERS do
      if E.Live[S].Active and E.Live[S].Human then
      begin
        Idx := E.Identity.ProfileIndex(S);
        Slots[n] := S;
        { counted since this map started; a match win only exists once the match is over }
        Kills[n] := E.Live[S].MatchKills;
        if E.DB.Valid(Idx) then
          Points[n] := E.DB.Profiles[Idx]^.Points - E.Live[S].MatchStartPoints
        else
          Points[n] := 0;
        if Rounds then
          Extra[n] := E.Live[S].MatchRoundWins
        else if Caps then
          Extra[n] := E.Live[S].MatchCaps
        else
          Extra[n] := 0;
        Inc(n);
      end;
    if n = 0 then
      Out(E, Slot, 'No players on the server.', WHITE)
    else
    begin
      LeaderRow(E, Slot, 'Kills', Slots, Kills, n, False);
      LeaderRow(E, Slot, 'Points', Slots, Points, n, True);
      if Rounds then
        LeaderRow(E, Slot, 'Rounds', Slots, Extra, n, False)
      else if Caps then
        LeaderRow(E, Slot, 'Caps', Slots, Extra, n, False);
    end;
  end;
  Footer(E, Slot, W);
end;
