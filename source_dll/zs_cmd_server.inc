{ zs_commands: server statistics and admin diagnostics }

function AsciiBar(Value, MaxValue: Int64; Width: LongInt; Fill, Empty: AnsiChar): AnsiString;
var
  Filled: Int64;
begin
  if (MaxValue <= 0) or (Value <= 0) then
    Exit('[' + StringOfChar(Empty, Width) + ']');
  Filled := Min(Int64(Width), Round(Value / MaxValue * Width));
  if Filled = 0 then
    Filled := 1;
  Result := '[' + StringOfChar(Fill, Filled) + StringOfChar(Empty, Width - Filled) + ']';
end;

{ whole minutes and hours gone by: 59.6 minutes are "59m ago", not "60m ago" }
function AgoText(Days: Double): AnsiString;
begin
  if Days < 1 / 24 then
    Result := Format('%dm ago', [Max(1, Trunc(Days * 1440))])
  else if Days < 1 then
    Result := Format('%dh ago', [Trunc(Days * 24)])
  else if Days < 2 then
    Result := 'yesterday'
  else
    Result := Format('%dd ago', [Trunc(Days)]);
end;

{ !activity: the whole week hour by hour (player time per server-clock hour, all-time),
  the same counters the busiest hour of !server comes from }
procedure CmdActivity(E: TZSEngine; Slot: LongInt);
const
  SHADES: array[1..6] of AnsiChar = ('.', ':', '+', '*', '#', '@');
  DAYS: array[0..6] of AnsiString = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  { Monday first, the way a calendar week reads }
  ORDER: array[0..6] of LongInt = (1, 2, 3, 4, 5, 6, 0);
var
  Wd, H, k, Level, BestDay: LongInt;
  V, MaxV, Total, DayTotal, BestDayTotal: Int64;
  TopWd, TopH: array[0..2] of LongInt;
  TopV: array[0..2] of Int64;
  Line: AnsiString;
  SV: PServerRecords;
  SrvTmp: TServerRecords;
begin
  { SharedServer: the hours of every server of the database }
  SrvTmp := Default(TServerRecords);
  SV := SharedServerView(E, E.Cfg.MySQLShareServer, SrvTmp);
  MaxV := 0;
  Total := 0;
  for k := 0 to 2 do
  begin
    TopWd[k] := -1;
    TopH[k] := 0;
    TopV[k] := 0;
  end;
  for Wd := 0 to 6 do
    for H := 0 to 23 do
    begin
      V := SV^.WeekdayHour[Wd, H];
      Inc(Total, V);
      MaxV := Max(MaxV, V);
      { the three busiest hours of the week, best first }
      for k := 0 to 2 do
        if V > TopV[k] then
        begin
          if k < 2 then
          begin
            TopV[2] := TopV[1]; TopWd[2] := TopWd[1]; TopH[2] := TopH[1];
            if k = 0 then
            begin
              TopV[1] := TopV[0]; TopWd[1] := TopWd[0]; TopH[1] := TopH[0];
            end;
          end;
          TopV[k] := V;
          TopWd[k] := Wd;
          TopH[k] := H;
          Break;
        end;
    end;

  if SV <> @E.DB.Server then
    Header(E, Slot, 'Server Activity: Week by Hour - all servers', LINE_W)
  else
    Header(E, Slot, 'Server Activity: Week by Hour', LINE_W);
  if MaxV <= 0 then
  begin
    Out(E, Slot, 'No activity recorded yet - it is counted while enough players are on the server.', CLR_OTHER_ROW);
    Footer(E, Slot, LINE_W);
    Exit;
  end;
  { "Day " and 24 hours of three characters (76), then the share of the day and its play time }
  Line := 'Day ';
  for H := 0 to 23 do
    Line := Line + Format('%.2d ', [H]);
  Out(E, Slot, Line + 'Day%  Play time', CLR_SUBHEADER);
  Rule(E, Slot, LINE_W);
  BestDay := 0;
  BestDayTotal := -1;
  for k := 0 to 6 do
  begin
    Wd := ORDER[k];
    Line := DAYS[Wd] + ' ';
    DayTotal := 0;
    for H := 0 to 23 do
    begin
      V := SV^.WeekdayHour[Wd, H];
      Inc(DayTotal, V);
      if V <= 0 then
        Line := Line + '   '
      else
      begin
        Level := EnsureRange(Ceil(V * 6.0 / MaxV), 1, 6);
        Line := Line + SHADES[Level] + SHADES[Level] + ' ';
      end;
    end;
    if DayTotal > BestDayTotal then
    begin
      BestDayTotal := DayTotal;
      BestDay := Wd;
    end;
    Line := Line + Format('%3d%%', [Round(DayTotal * 100.0 / Total)]);
    if DayTotal > 0 then
      Line := Line + '  ' + FormatDurationShort(DayTotal);
    Out(E, Slot, Line, WHITE);
  end;
  Rule(E, Slot, LINE_W);
  Out(E, Slot, 'few . : + * # @ many    blank = nobody played    hours = server clock', CLR_HINT);
  Line := '';
  for k := 0 to 2 do
    if TopWd[k] >= 0 then
    begin
      if Line <> '' then
        Line := Line + ', ';
      Line := Line + Format('%s %.2d:00-%.2d:00', [DAYS[TopWd[k]], TopH[k], (TopH[k] + 1) mod 24]);
    end;
  Out(E, Slot, 'Most players: ' + Line, CLR_OBJECTIVE);
  Out(E, Slot, Format('Busiest day: %s (%d%% of all play time) | Total play time: %s', [DAYS[BestDay],
    Round(BestDayTotal * 100.0 / Total), FormatDurationShort(Total)]), CLR_OBJECTIVE);
  Footer(E, Slot, LINE_W);
end;

procedure CmdServerStats(E: TZSEngine; Slot: LongInt);
const
  WEEKDAYS: array[0..6] of AnsiString = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  { the bars of the 30-day benchmark }
  BAR_W = 60;
var
  k, j, Wd, H, Accounts, Today, Yesterday, D7, D14, D30, D90, D365, Returning, MvpIdx, TopIdx: LongInt;
  TopKillSlot, TopDmgSlot, PeakHour, BestWd, BestWh, New7, Key7, DayNow, Ret2, Ret7, SinceDay, NewSince: LongInt;
  Kills, Deaths, Selfs, Assists, Caps, TKs, Shots, Hits, Head, Body, Legs, Play, Visits, V, MaxHour, MaxWd: Int64;
  WHits, Matches, MapKills, MapMatches: Int64;
  MvpPts: LongInt;
  WDmg, NowT, Delta, TodayStart, R: Double;
  Recent: array[0..2] of LongInt;
  RecentDelta: array[0..2] of Double;
  Totals: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
  BestDist: Single;
  BestStreak: LongInt;
  BestDistName, BestStreakName, Bar, Line, Third: AnsiString;
  P: PPlayerProfile;
  SV: PServerRecords;
  SrvTmp: TServerRecords;
  Others: TPlayerProfile;
  Shared: Boolean;

  { one bar of the 30-day benchmark: the accounts seen in a span against those of 30 days }
  procedure BenchLine(const Title: AnsiString; Count: LongInt);
  begin
    Out(E, Slot, PadR(Title, 8) + AsciiBar(Count, Max(1, D30), BAR_W, '#', '-') + ' ' + PadL(Num(Count), 5) +
      ' (' + Pct(Count, Max(1, D30)) + ')', WHITE);
  end;

begin
  { SharedServer: the activity, the peak, the matches, the combat numbers and the weapons of every
    server of the database; visitors, returning players and the hall of fame stay this server's }
  SrvTmp := Default(TServerRecords);
  SV := SharedServerView(E, E.Cfg.MySQLShareServer, SrvTmp);
  Others := Default(TPlayerProfile);
  Shared := SharedAccountSums(E, E.Cfg.MySQLShareServer, Others);
  Kills := 0; Deaths := 0; Selfs := 0; Assists := 0; Caps := 0; TKs := 0;
  Shots := 0; Hits := 0; Head := 0; Body := 0; Legs := 0; Play := 0; Visits := 0;
  Accounts := 0; Today := 0; Yesterday := 0; D7 := 0; D14 := 0; D30 := 0; D90 := 0; D365 := 0; Returning := 0;
  Ret2 := 0; Ret7 := 0; NewSince := 0;
  NowT := Now;
  TodayStart := Int(NowT);
  DayNow := DayKey(NowT);
  { Who came back is asked of the accounts first seen since the server keeps its daily record:
    every day they played was counted (DaysPlayed). Accounts brought over from 4.x have no count
    of their days, and the accounts of today cannot have come back yet. }
  SinceDay := 0;
  if Length(E.DB.Server.Daily) > 0 then
    SinceDay := E.DB.Server.Daily[0].Day;
  for k := 0 to 2 do
  begin
    Recent[k] := -1;
    RecentDelta[k] := MaxDouble;
  end;

  BestDist := 0;
  BestDistName := 'None';
  BestStreak := 0;
  BestStreakName := 'None';
  MvpIdx := -1;
  MvpPts := Low(LongInt);

  for k := 0 to E.DB.ProfileCount - 1 do
  begin
    if not E.DB.Valid(k) then
      Continue;
    P := E.DB.Profiles[k];
    Inc(Accounts);
    Inc(Kills, P^.Kills);
    Inc(Deaths, P^.Deaths);
    Inc(Selfs, P^.Selfkills);
    Inc(Assists, P^.Assist);
    Inc(Caps, P^.FlagsScore);
    Inc(TKs, P^.Teamkills);
    Inc(Shots, Max(P^.Shots, P^.ShotsHits));
    Inc(Hits, P^.ShotsHits);
    Inc(Head, P^.ShotsHitsHead);
    Inc(Body, P^.ShotsHitsBody);
    Inc(Legs, P^.ShotsHitsLeg);
    Inc(Play, P^.TimePlayed);
    V := 0;
    for j := 0 to High(P^.OtherNames) do
      Inc(V, P^.OtherNames[j].LoginCount);
    Inc(Visits, Max(Int64(1), V));

    if P^.LongestKillDistance > BestDist then
    begin
      BestDist := P^.LongestKillDistance;
      BestDistName := Copy(P^.ActiveName, 1, 16);
    end;
    if P^.MaxKillStreak > BestStreak then
    begin
      BestStreak := P^.MaxKillStreak;
      BestStreakName := Copy(P^.ActiveName, 1, 16);
    end;
    if (P^.Period[PERIOD_DAY].Key = DayNow) and (P^.Period[PERIOD_DAY].Kills + P^.Period[PERIOD_DAY].Deaths > 0) and
       (P^.Period[PERIOD_DAY].PointsDelta > MvpPts) then
    begin
      MvpPts := P^.Period[PERIOD_DAY].PointsDelta;
      MvpIdx := k;
    end;
    if (SinceDay > 0) and (P^.RegisterTime > 0) and (DayKey(P^.RegisterTime) >= SinceDay) and
       (DayKey(P^.RegisterTime) < DayNow) then
    begin
      Inc(NewSince);
      if P^.DaysPlayed >= 2 then
        Inc(Ret2);
      if P^.DaysPlayed >= 7 then
        Inc(Ret7);
    end;
    if P^.LastPlayedTime > 0 then
    begin
      Delta := NowT - P^.LastPlayedTime;
      if P^.LastPlayedTime >= TodayStart then
        Inc(Today);
      if Delta < 7 then Inc(D7);
      if Delta < 14 then Inc(D14);
      if Delta < 30 then Inc(D30);
      if Delta < 90 then Inc(D90);
      if Delta < 365 then Inc(D365);
      { the same 14 days as D14, which the share is taken of }
      if (Delta < 14) and (V > 1) then
        Inc(Returning);
      if Delta < RecentDelta[0] then
      begin
        Recent[2] := Recent[1]; RecentDelta[2] := RecentDelta[1];
        Recent[1] := Recent[0]; RecentDelta[1] := RecentDelta[0];
        Recent[0] := k; RecentDelta[0] := Delta;
      end
      else if Delta < RecentDelta[1] then
      begin
        Recent[2] := Recent[1]; RecentDelta[2] := RecentDelta[1];
        Recent[1] := k; RecentDelta[1] := Delta;
      end
      else if Delta < RecentDelta[2] then
      begin
        Recent[2] := k;
        RecentDelta[2] := Delta;
      end;
    end;
  end;

  if Shared then
  begin
    Inc(Kills, Others.Kills);
    Inc(Deaths, Others.Deaths);
    Inc(Selfs, Others.Selfkills);
    Inc(Assists, Others.Assist);
    Inc(Caps, Others.FlagsScore);
    Inc(TKs, Others.Teamkills);
    Inc(Shots, Max(Others.Shots, Others.ShotsHits));
    Inc(Hits, Others.ShotsHits);
    Inc(Head, Others.ShotsHitsHead);
    Inc(Body, Others.ShotsHitsBody);
    Inc(Legs, Others.ShotsHitsLeg);
    Inc(Play, Others.TimePlayed);
  end;
  { The damage of the whole section and the hits it is divided by come from the weapon totals:
    accounts imported from 4.x have their damage only there, so the sum of the accounts' own
    damage can be smaller than the damage of one weapon (Top Gun). The hits of the accuracy stay
    the accounts' own: bullets only, where the weapon totals count explosions and blades too. }
  for j := 0 to WSLOT_COUNT - 1 do
    Totals[j] := Default(TWeaponTotals);
  CollectWeaponTotals(E, Totals, E.Cfg.MySQLShareServer);
  WDmg := 0;
  WHits := 0;
  TopKillSlot := 0;
  TopDmgSlot := 0;
  for j := 0 to WSLOT_COUNT - 1 do
  begin
    WDmg := WDmg + Totals[j].Damage;
    Inc(WHits, Totals[j].Hits);
    if Totals[j].Kills > Totals[TopKillSlot].Kills then
      TopKillSlot := j;
    if Totals[j].Damage > Totals[TopDmgSlot].Damage then
      TopDmgSlot := j;
  end;
  { Every match counts on its map as well. The maps of 4.x brought their matches along and the
    server count did not, so this server's matches are the larger of the two, and its kills per
    match divide the kills of the maps by the matches of the maps. }
  MapKills := 0;
  MapMatches := 0;
  for k := 0 to E.DB.MapCount - 1 do
  begin
    Inc(MapKills, E.DB.Maps[k].Kills);
    Inc(MapMatches, E.DB.Maps[k].ActiveMapPlays);
  end;
  Matches := SV^.TotalMatches;
  if not Shared then
    Matches := Max(Matches, MapMatches);

  { The players of yesterday come from the daily record: an account keeps only its last visit,
    and the last visit of a player who played yesterday and came back today is today. Like the
    other visitors, the new players and those of yesterday are this server's. }
  New7 := 0;
  Key7 := DayKey(NowT - 6);
  for k := 0 to High(E.DB.Server.Daily) do
  begin
    if E.DB.Server.Daily[k].Day >= Key7 then
      Inc(New7, E.DB.Server.Daily[k].NewPlayers);
    if E.DB.Server.Daily[k].Day = DayNow - 1 then
      Yesterday := E.DB.Server.Daily[k].Uniques;
  end;

  if Shared then
    Header(E, Slot, 'Server Statistics & Activity Analytics - all servers', LINE_W)
  else
    Header(E, Slot, 'Server Statistics & Activity Analytics', LINE_W);
  Section(E, Slot, 'Server Visitors & Retention', LINE_W);
  Row(E, Slot, ['Today: ' + Num(Today), 'Yesterday: ' + Num(Yesterday), '7 Days: ' + Num(D7),
    '14 Days: ' + Num(D14)], COLS4, WHITE);
  Row(E, Slot, ['30 Days: ' + Num(D30), '90 Days: ' + Num(D90), '365 Days: ' + Num(D365),
    'All-Time: ' + Num(Accounts)], COLS4, WHITE);
  Out(E, Slot, Format('Visits: %s sessions | Returning (14d): %s | Online: %d', [Num(Visits),
    Pct(Returning, Max(1, D14)), E.HumansOnline]), WHITE);
  Out(E, Slot, 'New players (7 days): ' + Num(New7), WHITE);
  if NewSince > 0 then
    Out(E, Slot, Format('Came back: %s of the %s accounts new since %s played on 2+ days, %s on 7+',
      [Pct(Ret2, NewSince), Num(NewSince), DateText(SinceDay, 'dd.mm.yyyy'), Pct(Ret7, NewSince)]), WHITE);
  if SV^.PeakOnlineCount > 0 then
  begin
    { a record brought over from 4.x may have no date or length }
    Line := Format('Peak Record: %d players', [SV^.PeakOnlineCount]);
    if SV^.PeakOnlineDate > 0 then
      Line := Line + ' on ' + DateText(SV^.PeakOnlineDate, 'dd.mm.yyyy hh:nn');
    if SV^.PeakOnlineDurationSec > 0 then
      Line := Line + ' (held for ' + FormatDurationShort(SV^.PeakOnlineDurationSec) + ')';
    Out(E, Slot, Line, WHITE);
  end
  else
    Out(E, Slot, 'Peak Record: None', WHITE);

  Section(E, Slot, 'Player Activity (30-Day Benchmark & 24h Peak)', LINE_W);
  BenchLine('Today', Today);
  BenchLine('7 Days', D7);
  BenchLine('14 Days', D14);
  BenchLine('30 Days', D30);
  { player time per hour of the day, all-time }
  MaxHour := 0;
  PeakHour := 0;
  for H := 0 to 23 do
    if SV^.HourlyActivity[H] > MaxHour then
    begin
      MaxHour := SV^.HourlyActivity[H];
      PeakHour := H;
    end;
  if MaxHour > 0 then
  begin
    Bar := '';
    for H := 0 to 23 do
    begin
      R := SV^.HourlyActivity[H] / MaxHour;
      if R <= 0.05 then Bar := Bar + '.'
      else if R <= 0.25 then Bar := Bar + '_'
      else if R <= 0.50 then Bar := Bar + '-'
      else if R <= 0.75 then Bar := Bar + '='
      else if R <= 0.90 then Bar := Bar + '+'
      else Bar := Bar + '#';
    end;
    Out(E, Slot, Format('24h Peak [%s] Peak: %.2d:00-%.2d:00 (%s played)', [Bar, PeakHour, (PeakHour + 1) mod 24,
      FormatDurationShort(MaxHour)]), WHITE);
  end
  else
    Out(E, Slot, '24h Peak: None', WHITE);
  MaxWd := 0;
  BestWd := 0;
  BestWh := 0;
  for Wd := 0 to 6 do
    for H := 0 to 23 do
      if SV^.WeekdayHour[Wd, H] > MaxWd then
      begin
        MaxWd := SV^.WeekdayHour[Wd, H];
        BestWd := Wd;
        BestWh := H;
      end;
  if MaxWd > 0 then
    Out(E, Slot, Format('Busiest hour: %s %.2d:00-%.2d:00 (!activity) | Matches played: %s',
      [WEEKDAYS[BestWd], BestWh, (BestWh + 1) mod 24, Num(Matches)]), WHITE)
  else
    Out(E, Slot, 'Matches played: ' + Num(Matches), WHITE);
  { three names of up to 14 letters and how long ago ("(1234d ago)", "(yesterday)") fit the line }
  Line := '';
  for k := 0 to 2 do
    if Recent[k] >= 0 then
    begin
      if Line <> '' then
        Line := Line + ', ';
      Line := Line + Copy(E.DB.Profiles[Recent[k]]^.ActiveName, 1, 14) + ' (' + AgoText(RecentDelta[k]) + ')';
    end;
  if Line = '' then
    Line := 'None';
  Out(E, Slot, 'Recent Visitors: ' + Line, WHITE);

  Section(E, Slot, 'Server Combat & Damage Telemetry', LINE_W);
  Row(E, Slot, ['Kills: ' + Num(Kills), 'Deaths: ' + Num(Deaths), 'Suicides: ' + Num(Selfs)], COLS3, WHITE);
  Row(E, Slot, [Format('Combat Dmg: %s (~%s kills)', [Dmg(WDmg), KillEq(E, WDmg)]),
    'Avg Dmg/Hit: ' + FloatStr(SafeDivD(WDmg, WHits), 1) + ' HP', 'Assists: ' + Num(Assists)], COLS3, WHITE);
  if Shared then
    Third := 'Kills/Match: ' + FloatStr(SafeDivD(Kills, Matches), 1)
  else
    Third := 'Kills/Match: ' + FloatStr(SafeDivD(MapKills, MapMatches), 1);
  { flag caps where flags are played or were, the friendly fire index where teammates can hurt
    each other or teamkills were counted }
  CellRows(E, Slot, ['Shots: ' + Num(Shots), Format('Hits: %s (%s)', [Num(Hits), Pct(Hits, Shots)]), Third,
    'Pace: ' + FloatStr(SafeDivD(Kills * 3600.0, Play), 1) + ' kills/h', 'Playtime: ' + FormatDurationShort(Play),
    IfText(ObjectiveMode(E) or (Caps > 0), 'Flag Caps: ' + Num(Caps)),
    IfText((E.Match.FriendlyFire and E.TeamGame) or (TKs > 0), Format('FF Index: %s (TK: %s)', [Pct(TKs, Kills + TKs), Num(TKs)]))],
    COLS3, WHITE);
  Row(E, Slot, [Format('Head: %s (%s)', [Num(Head), Pct(Head, Hits)]), Format('Body: %s (%s)', [Num(Body), Pct(Body, Hits)]),
    Format('Legs: %s (%s)', [Num(Legs), Pct(Legs, Hits)])], COLS3, WHITE);

  Section(E, Slot, 'Server Hall of Fame & Weapon Mastery', LINE_W);
  if Totals[TopKillSlot].Kills > 0 then
    Line := Format('Top Gun (Kills): %s (%s)', [SlotName(TopKillSlot), Num(Totals[TopKillSlot].Kills)])
  else
    Line := 'Top Gun (Kills): None';
  if Totals[TopDmgSlot].Damage > 0 then
    Third := Format('Top Gun (Damage): %s (%s)', [SlotName(TopDmgSlot), Dmg(Totals[TopDmgSlot].Damage)])
  else
    Third := 'Top Gun (Damage): None';
  Row(E, Slot, [Line, Third], COLS2, WHITE);
  if BestDist > 0 then
    Line := Format('Longest Kill: %sm by %s', [FloatStr(BestDist, 1), BestDistName])
  else
    Line := 'Longest Kill: None';
  if BestStreak > 0 then
    Third := Format('Top Streak: %d kills by %s', [BestStreak, BestStreakName])
  else
    Third := 'Top Streak: None';
  Row(E, Slot, [Line, Third], COLS2, WHITE);
  if MvpIdx >= 0 then
    Line := Format('MVP Today: %s (%s pts)', [Copy(E.DB.Profiles[MvpIdx]^.ActiveName, 1, 24), Signed(MvpPts)])
  else
    Line := 'MVP Today: None';
  TopIdx := E.DB.Ranks[RANK_POINTS].At(1);
  if E.DB.Valid(TopIdx) then
    Out(E, Slot, Format('#1 Ranked Player: %s (%s pts, Rating: %s)', [Copy(E.DB.Profiles[TopIdx]^.ActiveName, 1, 20),
      Num(E.DB.Profiles[TopIdx]^.Points), FloatStr(PerfRating(E, E.DB.Profiles[TopIdx]^), 1)]), WHITE);
  Out(E, Slot, Line, WHITE);
  Footer(E, Slot, LINE_W);
end;

procedure CmdSuspects(E: TZSEngine; Slot: LongInt);
const
  SHOWN = 15;
var
  k: LongInt;
begin
  if E.Suspects.Count = 0 then
  begin
    Out(E, Slot, 'No suspicious kill series and no notes from the daily report.', CLR_GOOD);
    Out(E, Slot, 'The full history with HWID and IP is in logs/zitrostats/suspicious.log.', CLR_HINT);
    Exit;
  end;
  { the list keeps its entries across restarts: kill series and the notes of the daily report;
    the newest SHOWN of them are listed }
  Out(E, Slot, Format('[ZitroStats] %d notes, newest first (kill series and daily report; HWID/IP in suspicious.log):',
    [E.Suspects.Count]), CLR_HEADER);
  for k := E.Suspects.Count - 1 downto Max(0, E.Suspects.Count - SHOWN) do
    Out(E, Slot, E.Suspects[k], CLR_WARN);
  if E.Suspects.Count > SHOWN then
    Out(E, Slot, Format('... and %d older ones in logs/zitrostats/suspicious.log.', [E.Suspects.Count - SHOWN]), CLR_HINT);
end;

procedure CmdPerf(E: TZSEngine; Slot: LongInt);
begin
  Out(E, Slot, Format('[ZitroStats %s] engine timing since %s', [ZS_VERSION_STR, FormatDateTime('yyyy-mm-dd hh:nn', E.PerfSince)]), CLR_HEADER);
  Out(E, Slot, Format('events: %d, avg %s ms, max %s ms, batch max %d, queued %d, dropped %d', [E.PerfEvents,
    FloatStr(SafeDivD(E.PerfEventMicros, E.PerfEvents) / 1000, 3), FloatStr(E.PerfEventMaxMicros / 1000, 2), E.PerfBatchMax,
    E.EventsQueued, E.EventsDropped]), CLR_HINT);
  Out(E, Slot, Format('timers: %d runs, avg %s ms, max %s ms', [E.PerfTimerRuns, FloatStr(SafeDivD(E.PerfTimerMicros, E.PerfTimerRuns) / 1000, 3),
    FloatStr(E.PerfTimerMaxMicros / 1000, 2)]), CLR_HINT);
  Out(E, Slot, Format('data: %d accounts, %d free slots, %d maps, %d archived seasons', [E.DB.LiveProfiles, E.DB.Holes, E.DB.MapCount,
    Length(E.DB.Seasons)]), CLR_HINT);
  if E.Writer <> nil then
    Out(E, Slot, Format('storage: journal gen %d, %d KB since snapshot, IO queue %d KB, saving now: %s',
      [Int64(E.Writer.Generation), E.Writer.JournalBytes div 1024, E.IO.PendingBytes div 1024, BoolToStr(E.DB.SnapshotActive, 'yes', 'no')]),
      CLR_HINT)
  else
    Out(E, Slot, 'storage: read-only, nothing is saved', CLR_WARN);
  if E.Service <> nil then
    Out(E, Slot, Format('service: %d password jobs waiting', [E.Service.PendingHashes]), CLR_HINT);
end;
