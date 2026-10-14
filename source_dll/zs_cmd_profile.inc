{ zs_commands: help, profiles, account audit, session and small player commands }

{ Every command with its arguments: name* must be given, [name] may be left out, a|b takes either;
  the legend at the bottom says what the short argument names mean. }
procedure CmdHelp(E: TZSEngine; Slot: LongInt; Admin: Boolean);
const
  { a column every 20 characters, five to a row, the same in every section: a longer command
    takes two columns (CmdGrid), so none touches the next one }
  COLS = 5;
  COLW = LINE_W div COLS;
var
  Feats, Pw, Mx: TStringArray;
  Passwords: Boolean;
  Around: AnsiString;

  procedure AddFeat(const S: AnsiString);
  begin
    SetLength(Feats, Length(Feats) + 1);
    Feats[High(Feats)] := S;
  end;

begin
  { passwords exist only for players without Steam, admins included }
  Passwords := (Slot > 0) and not E.Identity.IsSteamSession(Slot);
  Header(E, Slot, 'ZitroStats ' + ZS_VERSION_STR + ' - commands', LINE_W);
  if Admin then
  begin
    Section(E, Slot, 'Admin commands', LINE_W);
    CmdGrid(E, Slot, ['/zs_status [p]', '/zs_statusid id*', '/zs_statusi n*', '/searcha t*', '/zs_suspects',
      '/zs_perf', '/zs_save', '/zs_reload', '/zs_export', '/zs_backup',
      '/zs_backups', '/zs_restore f*', '/yes cpw*', '/no', '/zs_merge id* id*',
      '/zs_unregister id*', '/zs_setpass id* npw*', '/removeolderthan d*',
      '/resetplayerstats p*', '/resetallplayersstats',
      '/resetserverstats', '/resetallmapsstats', '/resetmapstats [map]',
      '/balinfo', '/bal [on|off]', '/mix', '/swap p* p*', '/move p* team*', '/balexclude p*'], COLS, COLW, CLR_OBJECTIVE);
    { the map vote }
    CmdGrid(E, Slot, ['/zs_mapvote [cancel]', '/zs_maps [rescan]'], COLS, COLW, CLR_OBJECTIVE);
  end;
  Section(E, Slot, 'Profile', LINE_W);
  CmdGrid(E, Slot, ['!stats [p]', '!statsi n*', '!otherstats [p]', '!otherstatsi n*', '!hud',
    '!status [p]', '!statusi n*', '!rank [p]', '!ranki n*', '!session [p]',
    '!sessioni n*'], COLS, COLW, WHITE);
  Section(E, Slot, 'Rankings', LINE_W);
  CmdGrid(E, Slot, ['!top [pg|p|m]', '!topp [pg]', '!topi n*', '!topid [s]', '!topme',
    '!topo', '!topby m* [pg]', '!topskill [pg]', '!zs_search t*', '!seasons [pg]',
    '!topday [pg]', '!topweek [pg]', '!topmonth [pg]', '!topseason [season]'], COLS, COLW, WHITE);
  Section(E, Slot, 'Weapons and feats', LINE_W);
  Feats := nil;
  AddFeat('!allweapons [p]');
  AddFeat('!allweaponsi n*');
  AddFeat('!wep w* [p]');
  AddFeat('!wepi w* n*');
  AddFeat('!matchup [w] [pg]');
  { two columns each: in this order they fill their rows }
  AddFeat('!allweaponsby m* [p]');
  AddFeat('!allweaponsbyi m* n*');
  AddFeat('!serverweapons');
  AddFeat('!serverweaponsby m*');
  AddFeat('!serverwep w*');
  AddFeat('!topweapons [w] [pg]');
  AddFeat('!topwepsby m* [pg]');
  AddFeat('!spree [p]');
  AddFeat('!spreei n*');
  AddFeat('!achievements [p]');
  AddFeat('!achievementsi n*');
  AddFeat('!achlist [p]');
  AddFeat('!achlisti n*');
  { your last deaths, while [LastFight] is on }
  if E.Cfg.LastFightEnabled then
    AddFeat('!lastfight [1-3]');
  { the mode commands only where the mode is played }
  if E.Match.GameStyle = GS_PM then
    AddFeat('!pm [p]');
  if E.Match.GameStyle = GS_RM then
  begin
    AddFeat('!rambo [p]');
    AddFeat('!ramboi n*');
  end;
  CmdGrid(E, Slot, Feats, COLS, COLW, WHITE);
  Section(E, Slot, 'Maps and server', LINE_W);
  CmdGrid(E, Slot, ['!mapstats [map]', '!heatmap [map]', '!topmaps [pg|map]', '!topmapsp [pg]', '!topmapsi n*',
    '!topmapsby m* [pg]', '!server', '!activity', '!contact'], COLS, COLW, WHITE);
  { what the players did on the maps, while [Matrix] records it (zs_cmd_matrix.inc): x[i] is the
    command and its "i" form; two columns each (three for the longest), two to a row }
  if E.Cfg.MatrixEnabled then
  begin
    Section(E, Slot, 'A player over all maps', LINE_W);
    CmdGrid(E, Slot, ['!playermaps[i] [flag] [pg] [p]', '!rivals[i] [flag] [pg] [p]',
      '!versus[i] [flag] [pg] p* [p2]', '!playermatchup[i] [w] [flag] [pg] [p]'], COLS, COLW, WHITE);
    Section(E, Slot, 'A player on one map', LINE_W);
    Mx := ['!mapplayerstats[i] [map] [p]', '!mapplayerotherstats[i] [map] [p]', '!mapplayerweapstats[i] [map] [p]',
      '!mapplayerrivals[i] [map] [flag] [pg] [p]', '!mapplayermatchup[i] [map] [flag] [pg] [p]'];
    if E.Cfg.MatrixPlayerHeatmap then
    begin
      SetLength(Mx, Length(Mx) + 1);
      Mx[High(Mx)] := '!playerheatmap[i] [map] [p]';
    end;
    CmdGrid(E, Slot, Mx, COLS, COLW, WHITE);
    Section(E, Slot, 'One map, all its players', LINE_W);
    CmdGrid(E, Slot, ['!maprivals [map] [flag] [pg]', '!mapmatchup [map] [w] [flag] [pg]',
      '!mapweapstats [map] [flag] [pg]', '!mapwep w* [map]'], COLS, COLW, WHITE);
  end;
  { the map vote: the commands of it this server answers (zs_cmd_mapvote.inc) }
  if Length(MapVoteHelpItems(E)) > 0 then
  begin
    Section(E, Slot, 'Map vote', LINE_W);
    CmdGrid(E, Slot, MapVoteHelpItems(E), COLS, COLW, WHITE);
  end;
  { the team balance only where there are teams }
  if E.TeamGame then
  begin
    Section(E, Slot, 'Team balance', LINE_W);
    CmdGrid(E, Slot, ['!bal', '!switch', '!join'], COLS, COLW, WHITE);
  end;
  Section(E, Slot, 'Pages of the last list', LINE_W);
  CmdGrid(E, Slot, ['/zs_next', '/zs_prev', '/zs_page n*', '/zs_first', '/zs_end'], COLS, COLW, WHITE);
  Out(E, Slot, 'The same without the underscore works too: /zsnext, /zsprev, /zspage n ...', CLR_HINT);
  if Passwords then
  begin
    Section(E, Slot, 'Password (players without Steam, / only)', LINE_W);
    Pw := ['/register pw* pw*', '/login [p] pw*', '/changepass pw* pw* pw*', '/setemail mail*',
      '/verifyemail code*', '/account', '/forgotpass [p]', '/resetpass code* pw* pw*'];
    if E.Cfg.AllowPasswordRemoval then
    begin
      SetLength(Pw, Length(Pw) + 1);
      Pw[High(Pw)] := '/removemypass pw*';
    end;
    CmdGrid(E, Slot, Pw, COLS, COLW, WHITE);
  end;
  Rule(E, Slot, LINE_W);
  Out(E, Slot, '* required  [ ] optional  a|b = one of them  p = nick, part of it or #id', CLR_HINT);
  Out(E, Slot, 'n = ranking position  pg = page  map = map name or part of it  t = text  s = player slot', CLR_HINT);
  Out(E, Slot, 'm = metrics (!topby help, weapon metrics: !topwepsby help)  w = weapon (!wep help)', CLR_HINT);
  Out(E, Slot, 'wep or weap, either works in a command: !weap = !wep, !mapweap = !mapwep, !topweaps = !topweps',
    CLR_HINT);
  { the lists that open at the page of a player or a map }
  Around := '!topmaps';
  if MvOn(E, MVC_MAPS) then
    Around := Around + ', !maps';
  if MvOn(E, MVC_ALLMAPS) then
    Around := Around + ', !allmaps';
  Out(E, Slot, '!top p / ' + Around + ' map = the page around that player or map  !top m = !topby m', CLR_HINT);
  Out(E, Slot, 'commands ending in "i" take a ranking position: !statsi 3  !wepi ak 3  !achi 3', CLR_HINT);
  Out(E, Slot, 'a nick that is a number: use its #id (!stats #12) or the "i" command', CLR_HINT);
  { the per-map commands: the map comes first when the first word names one; the sort flag is
    written out, as f is the file of the admin commands }
  if E.Cfg.MatrixEnabled then
  begin
    Out(E, Slot, 'per-map commands: [map] (else the current one), [w], [flag], [pg], [p] in this order  p2 = player 2',
      CLR_HINT);
    Out(E, Slot, 'flag = the order (<cmd> help lists the flags, asc turns it round)  x[i] = also xi: n in place of p',
      CLR_HINT);
    Out(E, Slot, 'matrix = matchup: !playermatrix[i], !mapplayermatrix[i], !mapmatrix  !mapweapon = !mapwep', CLR_HINT);
  end;
  if E.Cfg.LastFightEnabled then
    Out(E, Slot, '!lastfight [1-3] = your last deaths (1 = the last): the hits both ways, points, a dodge estimate',
      CLR_HINT);
  if E.TeamGame then
    Out(E, Slot, '!bal, bal = team chances  !switch = to the weaker team  !join = spectator joins', CLR_HINT);
  if E.Cfg.MapVoteEnabled then
    Out(E, Slot, MapVoteLegend(E), CLR_HINT);
  if Admin then
  begin
    Out(E, Slot, 'id = account number  cpw = ConfirmPassword  npw = new password for that account', CLR_HINT);
    Out(E, Slot, 'f = file from /zs_backups  d = days  team = alpha, bravo, charlie, delta or spec', CLR_HINT);
  end;
  if Passwords then
    Out(E, Slot, 'pw = password  mail = e-mail address  code = code from the e-mail', CLR_HINT);
  Out(E, Slot, Frame('ZitroStats ' + ZS_VERSION_STR + ' by TryHackX', LINE_W, '='), CLR_HEADER);
end;

procedure CmdStats(E: TZSEngine; Slot, Idx: LongInt);
var
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
  Shots: Int64;
  Tier, Skill, Third: AnsiString;
  TeamStyle, FFRows, Seasons: Boolean;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  Shared := Default(TPlayerProfile);
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  Shots := Max(Int64(P^.Shots), Int64(P^.ShotsHits));
  { a tier of [Ranks] may have 24 letters: cut, so the rank keeps to its column }
  Tier := Copy(E.TierName(Idx), 1, 20);
  if Tier <> '' then
    Tier := ' (' + Tier + ')';
  TeamStyle := IsTeamStyle(E.Match.GameStyle);
  { friendly fire hits teammates only: its rows need a team mode with it on, or counters of it }
  FFRows := (TeamStyle and E.Match.FriendlyFire) or (P^.DamageFriendly > 0) or (P^.Teamkills > 0);

  Header(E, Slot, '[ Stats: ' + P^.ActiveName + ' ]', LINE_W);
  Row(E, Slot, ['Rank: ' + RankText(E, Idx) + Tier, 'Points: ' + Num(RankingPoints(E, Idx)),
    'Rating: ' + FloatStr(PerfRating(E, P^), 1)], COLS3, CLR_RANK_LINE);
  Row(E, Slot, ['Kills: ' + Num(P^.Kills), 'Deaths: ' + Num(P^.Deaths), 'K/D Ratio: ' + KD(P^.Kills, P^.Deaths)],
    COLS3, WHITE);
  Row(E, Slot, ['Best Streak: ' + IntToStr(P^.MaxKillStreak), 'Avg Life: ' + FormatDurationShort(P^.TimeAlive div Max(Int64(1), LivesEnded(P^))),
    'Dmg Ratio: ' + FloatStr(SafeDivD(P^.DamageDealt, P^.DamageReceived), 2)], COLS3, WHITE);
  if (P^.DamageDealt > 0) or (P^.DamageReceived > 0) then
  begin
    { the team modes show the assists in a row of their own (below) }
    if TeamStyle and FFRows then
      Third := 'TK Dmg: ' + Dmg(P^.DamageFriendly)
    else if not TeamStyle then
      Third := 'Assists: ' + Num(P^.Assist)
    else
      Third := '';
    Row(E, Slot, [Format('Dealt: %s (~%s kills)', [Dmg(P^.DamageDealt), KillEq(E, P^.DamageDealt)]),
      Format('Taken: %s (~%s deaths)', [Dmg(P^.DamageReceived), KillEq(E, P^.DamageReceived)]), Third], COLS3, WHITE);
  end;
  { health got back on the healing fields of a map and from kits }
  if P^.HealRegen + P^.HealKits > 0 then
    Row(E, Slot, ['Healed: ' + Dmg(P^.HealRegen + P^.HealKits) + ' HP', 'Regen: ' + Dmg(P^.HealRegen) + ' HP',
      Format('Heal Kits: %s (%s HP)', [Num(P^.HealKitCount), Dmg(P^.HealKits)])], COLS3, WHITE);
  if P^.TimeAlive > 0 then
    Row(E, Slot, ['Dmg/min alive: ' + FloatStr(P^.DamageDealt * 60.0 / P^.TimeAlive, 1),
      'Kills/min alive: ' + FloatStr(P^.Kills * 60.0 / P^.TimeAlive, 2),
      'Longest Life: ' + FormatDurationShort(P^.LongestLifeSec)], COLS3, WHITE);
  if P^.LongestKillDistance > 0 then
    Row(E, Slot, ['Longest: ' + FloatStr(P^.LongestKillDistance, 1) + 'm', 'Barrett: ' + FloatStr(P^.LongestBarrettDistance, 1) + 'm',
      'Avg Dist: ' + FloatStr(SafeDivD(P^.TotalKillDistance, P^.KillDistanceCount), 1) + 'm'], COLS3, WHITE);
  Row(E, Slot, ['Accuracy: ' + Pct(P^.ShotsHits, Shots), Format('Hits: %s/%s', [Num(P^.ShotsHits), Num(Shots)]),
    Format('Headshots: %s (%s)%s', [Num(P^.ShotsHitsHead), Pct(P^.ShotsHitsHead, P^.ShotsHits),
      ZoneEst(P^.ShotsHitsUnknown, P^.ShotsHitsHead, P^.ShotsHitsBody, P^.ShotsHitsLeg)])], COLS3, WHITE);
  { survival counts rounds in every mode, free-for-all included }
  if E.Match.Survival or (P^.RoundsWins + P^.RoundsLose > 0) then
    Third := Format('Rounds: %sW / %sL', [Num(P^.RoundsWins), Num(P^.RoundsLose)])
  else
    Third := 'Pace: ' + FloatStr(SafeDivD(P^.Kills * 3600.0, P^.TimePlayed), 1) + ' kills/h';
  Row(E, Slot, [Format('Matches: %sW / %sL', [Num(P^.Wins), Num(P^.Loses)]), 'Win%: ' + Pct(P^.Wins, P^.Wins + P^.Loses),
    Third], COLS3, WHITE);
  if ObjectiveMode(E) or (P^.FlagsScore + P^.FlagsReturn + P^.FlagsGrab > 0) then
    Row(E, Slot, ['Flag Caps: ' + Num(P^.FlagsScore), 'Returns: ' + Num(P^.FlagsReturn),
      Format('Held: %s (Grabs: %s)', [FormatDurationShort(P^.TimeHoldingFlags), Num(P^.FlagsGrab)])], COLS3, WHITE);
  Row(E, Slot, ['Playtime: ' + FormatDuration(P^.TimePlayed), 'Spectator: ' + FormatDurationShort(P^.TimeOnSpectator),
    'Selfkills: ' + Num(P^.Selfkills)], COLS3, WHITE);
  if TeamStyle then
  begin
    if FFRows then
      Row(E, Slot, ['Teamkills: ' + Num(P^.Teamkills), 'TK Deaths: ' + Num(P^.DeathsByFriendly),
        'Assists: ' + Num(P^.Assist)], COLS3, WHITE)
    else
    begin
      if E.Match.Survival then
        Third := 'Clutches: ' + Num(P^.ClutchesWon)
      else
        Third := 'First Dmg: ' + Num(P^.FirstDamageCount);
      Row(E, Slot, ['Assists: ' + Num(P^.Assist), 'First Blood: ' + Num(P^.FirstBloodCount), Third], COLS3, WHITE);
    end;
  end;
  if P^.KnivesThrows + P^.KnivesStabsEnemy > 0 then
    Row(E, Slot, ['Knife Throws: ' + Num(P^.KnivesThrows), 'Knife Hits: ' + Num(P^.KnivesThrowsHitsEnemy),
      'Knife Stabs: ' + Num(P^.KnivesStabsEnemy)], COLS3, WHITE);
  if (E.Match.GameStyle = GS_RM) or (P^.RamboMode.KillRamboCount > 0) or (P^.RamboMode.KillsByBow > 0) then
    Row(E, Slot, ['Bow Kills: ' + Num(P^.RamboMode.KillsByBow), 'Bow Time: ' + FormatDurationShort(P^.RamboMode.TimeWithBow),
      'Rambo Kills: ' + Num(P^.RamboMode.KillRamboCount)], COLS3, WHITE);
  Skill := SkillText(E, P^, E.CurrentFamily);
  if Skill <> '' then
    Skill := SkillSystemName(E) + ': ' + Skill;
  { the season (where there are seasons) with its K/D as every K/D: the ratio, then the kills and
    deaths }
  Seasons := E.Cfg.SeasonsEnabled or (P^.SeasonId > 0);
  CellRows(E, Slot, [Skill, IfText(Seasons, Format('Season: %s pts', [Signed(P^.SeasonPoints)])),
    IfText(Seasons, Format('Season K/D: %s (%s/%s)', [KD(P^.SeasonKills, P^.SeasonDeaths), Num(P^.SeasonKills),
      Num(P^.SeasonDeaths)])),
    Format('Achievements: %d/%d', [Length(P^.Achievements), ACH_COUNT]),
    IfText(Skill = '', Format('Protect: %d days', [P^.ProtectionDays]))], COLS3, CLR_MATCHES);
  Footer(E, Slot, LINE_W);
end;

{ "Kits: Med 3, Nade 12, ...": the kits an account picked up, every kind in the order of
  KIT_KIND_STYLES; with the counters shortened (five characters at most) it stays within LINE_W }
function KitPickupsText(const P: TPlayerProfile): AnsiString;
const
  KIT_LABELS: array[0..KIT_KINDS - 1] of AnsiString = ('Med', 'Nade', 'Cluster', 'Vest', 'Berserk', 'Predator',
    'Flamer');
var
  k: LongInt;
begin
  Result := 'Kits:';
  for k := 0 to KIT_KINDS - 1 do
  begin
    if k > 0 then
      Result := Result + ',';
    Result := Result + ' ' + KIT_LABELS[k] + ' ' + Num(P.KitPickups[k]);
  end;
end;

procedure CmdOtherStats(E: TZSEngine; Slot, Idx: LongInt);
const
  { three game modes to a line }
  MODE_W = 33;
var
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
  k, VI, F, n: LongInt;
  Victims, Nemeses, Name: AnsiString;
  Multi: TPointmatchMulti;
  TeamStyle, Seasons: Boolean;
  Badges: TStringArray;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  Shared := Default(TPlayerProfile);
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  TeamStyle := IsTeamStyle(E.Match.GameStyle);
  Header(E, Slot, '[ Detailed Telemetry: ' + P^.ActiveName + ' ]', LINE_W);

  Section(E, Slot, 'Damage Telemetry & Kill Equivalents', LINE_W);
  Row(E, Slot, [Format('Dmg Dealt: %s (~%s kills)', [Dmg(P^.DamageDealt), KillEq(E, P^.DamageDealt)]),
    Format('Dmg Taken: %s (~%s deaths)', [Dmg(P^.DamageReceived), KillEq(E, P^.DamageReceived)]),
    'Dmg Ratio: ' + FloatStr(SafeDivD(P^.DamageDealt, P^.DamageReceived), 2)], COLS3, WHITE);
  { the healing always, also at 0: a map without healing fields and a server without kits say so here
    (!stats shows it once there is some) }
  Row(E, Slot, ['Healed: ' + Dmg(P^.HealRegen + P^.HealKits) + ' HP', 'Regen: ' + Dmg(P^.HealRegen) + ' HP',
    Format('Heal Kits: %s (%s HP)', [Num(P^.HealKitCount), Dmg(P^.HealKits)])], COLS3, WHITE);
  { every kit picked up, by kind, also at 0 }
  Out(E, Slot, KitPickupsText(P^), WHITE);
  { friendly fire hits teammates only, so the row is there when the account has such counters }
  if (P^.DamageFriendly > 0) or (P^.DamageFriendlyReceived > 0) or (P^.Teamkills > 0) or (P^.DeathsByFriendly > 0) then
    Row(E, Slot, ['TK Dmg Out: ' + Dmg(P^.DamageFriendly), 'TK Dmg In: ' + Dmg(P^.DamageFriendlyReceived),
      Format('TK Kills/Deaths: %s/%s', [Num(P^.Teamkills), Num(P^.DeathsByFriendly)])], COLS3, WHITE);

  { three names of up to 18 letters and their kills fit the line }
  Victims := '';
  Nemeses := '';
  for k := 0 to 2 do
  begin
    if P^.TopVictims[k].TargetPlayerID > 0 then
    begin
      VI := E.DB.IndexOfId(P^.TopVictims[k].TargetPlayerID);
      if E.DB.Valid(VI) then
        Name := E.DB.Profiles[VI]^.ActiveName
      else
        Name := '#' + IntToStr(P^.TopVictims[k].TargetPlayerID);
      if Victims <> '' then
        Victims := Victims + ', ';
      Victims := Victims + Format('%s (%s)', [Copy(Name, 1, 18), Num(P^.TopVictims[k].KillCount)]);
    end;
    if P^.TopNemeses[k].TargetPlayerID > 0 then
    begin
      VI := E.DB.IndexOfId(P^.TopNemeses[k].TargetPlayerID);
      if E.DB.Valid(VI) then
        Name := E.DB.Profiles[VI]^.ActiveName
      else
        Name := '#' + IntToStr(P^.TopNemeses[k].TargetPlayerID);
      if Nemeses <> '' then
        Nemeses := Nemeses + ', ';
      Nemeses := Nemeses + Format('%s (%s)', [Copy(Name, 1, 18), Num(P^.TopNemeses[k].KillCount)]);
    end;
  end;
  if Victims = '' then
    Victims := 'None';
  if Nemeses = '' then
    Nemeses := 'None';
  Section(E, Slot, 'Top Encounters & Rivals', LINE_W);
  Out(E, Slot, 'Fav Victims: ' + Victims, WHITE);
  Out(E, Slot, 'Top Nemeses: ' + Nemeses, WHITE);

  Section(E, Slot, 'Hitzones, Aim & Distance', LINE_W);
  Row(E, Slot, [Format('Head: %s (%s)', [Num(P^.ShotsHitsHead), Pct(P^.ShotsHitsHead, P^.ShotsHits)]),
    Format('Body: %s (%s)', [Num(P^.ShotsHitsBody), Pct(P^.ShotsHitsBody, P^.ShotsHits)]),
    Format('Legs: %s (%s)', [Num(P^.ShotsHitsLeg), Pct(P^.ShotsHitsLeg, P^.ShotsHits)])], COLS3, WHITE);
  Row(E, Slot, ['Longest Kill: ' + FloatStr(P^.LongestKillDistance, 1) + 'm', 'Longest Barrett: ' + FloatStr(P^.LongestBarrettDistance, 1) + 'm',
    'Avg Kill Dist: ' + FloatStr(SafeDivD(P^.TotalKillDistance, P^.KillDistanceCount), 1) + 'm'], COLS3, WHITE);
  Row(E, Slot, ['100m+ Kills: ' + Num(P^.LongKills100), 'Barrett Long: ' + Num(P^.BarrettLongKills),
    'Unclear Zone: ' + Num(P^.ShotsHitsUnknown)], COLS3, WHITE);
  { [Bridges] (5.6): what only the server's memory and its bullets tell - the hits and the kills measured
    from where and when their bullet was made }
  if (P^.LongestHeadshotM > 0) or (P^.LongestFlightKill > 0) or (P^.HitDistCount > 0) or (P^.KillAirCount > 0) then
  begin
    Row(E, Slot, ['Longest Hit: ' + MetersText(P^.LongestHitM), 'Avg Hit Dist: ' + AvgMetersText(P^.HitDistSum,
      P^.HitDistCount), 'Avg Hit Air: ' + AvgAirText(P^.HitAirTicks, P^.HitAirCount)], COLS3, WHITE);
    Row(E, Slot, ['Longest Headshot: ' + FloatStr(P^.LongestHeadshotM, 1) + 'm',
      'Longest Air Time: ' + FloatStr(P^.LongestFlightKill, 2) + 's',
      'Avg Kill Air: ' + AvgAirText(P^.KillAirTicks, P^.KillAirCount)], COLS3, WHITE);
  end;
  Name := StanceAccText(P^.StanceShots, P^.StanceHits);
  if Name <> '' then
    Out(E, Slot, Name, WHITE);

  Section(E, Slot, 'Timing, Movement & Positioning', LINE_W);
  Row(E, Slot, ['Avg TTK: ' + FloatStr(SafeDivD(P^.TTKSumTicks, P^.TTKCount) / TICKS_PER_SECOND, 2) + 's',
    'Best TTK: ' + BoolToStr(P^.BestTTKTicks > 0, FloatStr(P^.BestTTKTicks / TICKS_PER_SECOND, 2) + 's', '-'), 'Longest Life: ' + FormatDurationShort(P^.LongestLifeSec)], COLS3, WHITE);
  { every life: those that ended, whoever ended them, and the one going on }
  Row(E, Slot, ['Traveled: ' + FloatStr(P^.DistanceTraveledM / 1000, 1) + ' km',
    'Dist/Life: ' + FloatStr(SafeDivD(P^.DistanceTraveledM, LivesEnded(P^) + 1), 0) + ' m',
    'Best Life: ' + FloatStr(P^.BestLifeDistanceM, 0) + ' m'], COLS3, WHITE);
  Row(E, Slot, ['Fly Time: ' + FormatDurationShort(P^.JetFlyTimeSeconds), 'Air Kills: ' + Num(P^.AirKills),
    'Height Kills: ' + Num(P^.HeightKills)], COLS3, WHITE);
  Row(E, Slot, ['Prone Kills: ' + Num(P^.ProneKills), 'Camp Kills: ' + Num(P^.CampKills),
    'Vest Kills: ' + Num(P^.VestKills)], COLS3, WHITE);
  { survival has no spawn kills: everybody spawns together and nobody respawns in a round }
  if not E.Match.Survival or (P^.SpawnKills + P^.SpawnDeaths > 0) then
    Row(E, Slot, ['Spawn Kills: ' + Num(P^.SpawnKills), 'Spawn Deaths: ' + Num(P^.SpawnDeaths)], COLS3, WHITE);

  { Round first bloods, last stands and clutches belong to survival, saviors, avengers and
    comebacks to the team modes; a feat of another mode shows only when the account has it. A
    kill that ends a domination usually is a revenge as well, so the two are shown apart, not
    added up. }
  Section(E, Slot, 'Combat Feats & Streaks', LINE_W);
  if E.Match.Realistic or (P^.BinkRecoveryKills > 0) then
    Name := 'Bink Recovery: ' + Num(P^.BinkRecoveryKills)
  else
    Name := 'Pace: ' + FloatStr(SafeDivD(P^.Kills * 3600.0, P^.TimePlayed), 1) + ' kills/h';
  CellRows(E, Slot, ['Max Streak: ' + IntToStr(P^.MaxKillStreak), 'First Bloods: ' + Num(P^.FirstBloodCount),
    IfText(E.Match.Survival or (P^.RoundFirstBloodCount > 0), 'Round First Bloods: ' + Num(P^.RoundFirstBloodCount)),
    'First Damage: ' + Num(P^.FirstDamageCount),
    'Dominations: ' + Num(P^.DominatingCount), 'Revenge Kills: ' + Num(P^.RevengeKills),
    'Dominations Ended: ' + Num(P^.RevengeFeats),
    IfText(E.Match.Survival or (P^.LastStand > 0), 'Last Stand: ' + Num(P^.LastStand)),
    IfText((E.Match.Survival and TeamStyle) or (P^.ClutchesWon > 0), 'Clutches Won: ' + Num(P^.ClutchesWon)),
    IfText(TeamStyle or (P^.SaviorKills > 0), 'Saviors: ' + Num(P^.SaviorKills)),
    IfText(TeamStyle or (P^.AvengerKills > 0), 'Avenger Kills: ' + Num(P^.AvengerKills)),
    IfText(TeamStyle or (P^.ComebackWins > 0), 'Comeback Wins: ' + Num(P^.ComebackWins)),
    'Assists: ' + Num(P^.Assist), 'Posthumous: ' + Num(P^.PosthumousKills),
    'Finishers: ' + Num(P^.FinisherKills), 'Shut Downs: ' + Num(P^.ShutDownKills),
    'Nade Kills: ' + Num(P^.GrenadeKills), Name, 'Explosive Multi: ' + Num(P^.ExplosionMultiKills),
    'Knife Streak: ' + IntToStr(P^.KnifeKillsLifeBest), 'Cover (live): ' + Num(P^.WallKills),
    'Cover (shot): ' + Num(P^.CoverShotKills), 'Forced Selfkills: ' + Num(P^.ForcedSelfkills),
    Format('Selfkills: %s (%s)', [Num(P^.Selfkills), Pct(P^.Selfkills, SelfkillBase(E, P^))]),
    IfText(P^.CollateralKills > 0, 'Collaterals: ' + Num(P^.CollateralKills)),
    IfText(P^.BackKills + P^.BackDeaths > 0, 'Back Kills: ' + Num(P^.BackKills)),
    IfText(P^.BackKills + P^.BackDeaths > 0, 'Back Deaths: ' + Num(P^.BackDeaths))], COLS3, WHITE);

  if (P^.FlagsScore + P^.FlagsReturn + P^.FlagsGrab + P^.FlagsDrop + P^.FlaggerKills + P^.TimeHoldingFlags > 0) or ObjectiveMode(E) then
  begin
    Section(E, Slot, 'CTF & Objective Telemetry', LINE_W);
    Row(E, Slot, ['Flag Caps: ' + Num(P^.FlagsScore), 'Flag Returns: ' + Num(P^.FlagsReturn),
      'Flag Grabs: ' + Num(P^.FlagsGrab)], COLS3, WHITE);
    Row(E, Slot, [Format('Flag Drops: %s (%s thrown)', [Num(P^.FlagsDrop), Num(P^.FlagsThrown)]), 'Flagger Kills: ' + Num(P^.FlaggerKills),
      'Flagger Assists: ' + Num(P^.FlaggerKillsAssist)], COLS3, WHITE);
    Row(E, Slot, ['Flag Defense: ' + Num(P^.SaviorFlaggerKills), 'Kills w/ Flag: ' + Num(P^.KillsWhenHaveFlag),
      'Flag Hold: ' + FormatDurationShort(P^.TimeHoldingFlags)], COLS3, WHITE);

    if P^.FastestCapSeconds > 0 then
      Name := 'Fastest Cap: ' + FloatStr(P^.FastestCapSeconds, 1) + 's'
    else
      Name := 'Fastest Cap: -';
    Row(E, Slot, [Name, 'Caps under 10s: ' + Num(P^.CapsUnder10s), 'Escort Kills: ' + Num(P^.CarrierEscortKills)], COLS3, WHITE);
    { the teamkills around the flag need friendly fire }
    Row(E, Slot, ['Flag Juggles: ' + Num(P^.FlagJuggles), 'Contested Holds: ' + Num(P^.ContestedHolds),
      IfText(E.Match.FriendlyFire or (P^.FlaggerTeamkills + P^.TeamkillsWhenHaveFlag > 0),
        Format('TK flagger: %s / w/flag: %s', [Num(P^.FlaggerTeamkills), Num(P^.TeamkillsWhenHaveFlag)]))], COLS3, WHITE);
    Row(E, Slot, ['Base Defense: ' + Num(P^.BaseDefenseKills), 'Base Attack: ' + Num(P^.BaseAttackKills),
      'Base Radius: ' + IntToStr(E.Cfg.BaseRadiusMeters) + ' m'], COLS3, WHITE);
    if (P^.HTFMode.PointsScored > 0) or (P^.HTFMode.TimeWhenHaveFlag > 0) or (E.Match.GameStyle = GS_HTF) then
      Row(E, Slot, ['HTF Points: ' + Num(P^.HTFMode.PointsScored), 'HTF Hold: ' + FormatDurationShort(P^.HTFMode.TimeWhenHaveFlag),
        'HTF Team: ' + FormatDurationShort(P^.HTFMode.TimeWhenTeamHaveFlag)], COLS3, WHITE);
  end;

  if (P^.Wins + P^.Loses + P^.Draws > 0) or TeamStyle then
  begin
    Section(E, Slot, 'Matches & Competitive Standings', LINE_W);
    Row(E, Slot, ['Matches Won: ' + Num(P^.Wins), 'Matches Lost: ' + Num(P^.Loses),
      Format('Win Rate: %s (%s draws)', [Pct(P^.Wins, P^.Wins + P^.Loses), Num(P^.Draws)])], COLS3, WHITE);
    { survival counts rounds in every mode, free-for-all included }
    if E.Match.Survival or (P^.RoundsWins + P^.RoundsLose > 0) then
      Row(E, Slot, ['Rounds Won: ' + Num(P^.RoundsWins), 'Rounds Lost: ' + Num(P^.RoundsLose),
        'Round WR: ' + Pct(P^.RoundsWins, P^.RoundsWins + P^.RoundsLose)], COLS3, WHITE);
    if (P^.AdvanceRoundsPlayed > 0) or (P^.AlphaWins + P^.BravoWins + P^.CharlieWins + P^.DeltaWins > 0) then
      Row(E, Slot, [Format('Adv Won: %s/%s', [Num(P^.AdvanceRoundsWon), Num(P^.AdvanceRoundsPlayed)]),
        Format('Alpha: %sW / %sL', [Num(P^.AlphaWins), Num(P^.AlphaLoses)]),
        Format('Bravo: %sW / %sL', [Num(P^.BravoWins), Num(P^.BravoLoses)])], COLS3, WHITE);
    Row(E, Slot, ['Left Lost Matches: ' + Num(P^.LeaveLosses), 'Days Played: ' + IntToStr(P^.DaysPlayed),
      'Protection: ' + IntToStr(P^.ProtectionDays) + ' days'], COLS3, WHITE);
    { the team balance: moved to the other team, or went there with !switch when it helped }
    if P^.BalanceMoves + P^.BalanceVolunteers > 0 then
      Row(E, Slot, ['Balance Moves: ' + Num(P^.BalanceMoves), 'Volunteered: ' + Num(P^.BalanceVolunteers)],
        COLS3, WHITE);
  end;

  Section(E, Slot, 'Other Ratings (' + FamilyName(E.CurrentFamily) + ')', LINE_W);
  Row(E, Slot, ['Elo Points: ' + Num(P^.Points),
    'Rating: ' + FloatStr(PerfRating(E, P^), 1) + ' (' + LowerCase(Trim(E.Cfg.RatingMode)) + ')',
    'Ranking uses: ' + SkillSystemName(E)], COLS3, CLR_MATCHES);
  Row(E, Slot, ['MMR: ' + MmrText(P^, E.CurrentFamily), 'Glicko-2: ' + GlickoText(E, P^, E.CurrentFamily),
    'OpenSkill: ' + OpenSkillText(P^, E.CurrentFamily)], COLS3, CLR_MATCHES);
  Row(E, Slot, ['MMR ' + FamilyName(RF_FFA) + ': ' + MmrText(P^, RF_FFA),
    FamilyName(RF_TEAM) + ': ' + MmrText(P^, RF_TEAM), FamilyName(RF_CTF) + ': ' + MmrText(P^, RF_CTF)], COLS3, CLR_MATCHES);
  { without tiers there are no leagues to be placed in }
  if P^.LeagueTier > 0 then
    Row(E, Slot, ['League: ' + E.LeagueLabel(Idx), 'Top ' + FloatStr(P^.LeaguePromille / 10, 1) + '% of placed',
      'Leagues by: ' + LowerCase(Trim(E.Cfg.LeagueSource))], COLS3, CLR_MATCHES)
  else if E.Cfg.RankTierCount > 0 then
    Row(E, Slot, ['League: ' + E.LeagueLabel(Idx), 'not placed yet',
      'Leagues by: ' + LowerCase(Trim(E.Cfg.LeagueSource))], COLS3, CLR_MATCHES);

  Section(E, Slot, 'Season & Achievements', LINE_W);
  { a K/D is the ratio, with the kills and deaths after it; no season cells where there are none }
  Seasons := E.Cfg.SeasonsEnabled or (P^.SeasonId > 0);
  CellRows(E, Slot, [IfText(Seasons, Format('Season %d: %s pts', [P^.SeasonId, Signed(P^.SeasonPoints)])),
    IfText(Seasons, Format('Season K/D: %s (%s/%s)', [KD(P^.SeasonKills, P^.SeasonDeaths), Num(P^.SeasonKills),
      Num(P^.SeasonDeaths)])),
    Format('Achievements: %d/%d', [Length(P^.Achievements), ACH_COUNT])], COLS3, CLR_MATCHES);
  { one badge a season: after many seasons the list goes on over more lines }
  Badges := nil;
  SetLength(Badges, Length(P^.Badges));
  for k := 0 to High(P^.Badges) do
    Badges[k] := Format('S%d #%d', [P^.Badges[k].SeasonId, P^.Badges[k].Place]);
  WrapList(E, Slot, 'Season badges: ', Badges, CLR_FEATS);

  Section(E, Slot, 'Multi-Kill Medals', LINE_W);
  Multi := P^.PointmatchMode.Multi;
  Row(E, Slot, ['Double Kills: ' + Num(Multi.DOUBLE_KILL), 'Triple Kills: ' + Num(Multi.TRIPLE_KILL),
    'Multi Kills: ' + Num(Multi.MULTI_KILL)], COLS3, WHITE);
  Row(E, Slot, ['Multi x2: ' + Num(Multi.MULTI_KILL_X2), 'Serial Kills: ' + Num(Multi.SERIAL_KILL),
    'Insane Kills: ' + Num(Multi.INSANE_KILLS)], COLS3, WHITE);
  if Multi.GIMME_MORE + Multi.MASTA_KILLA + Multi.STOP_IT > 0 then
    Row(E, Slot, ['Gimme More: ' + Num(Multi.GIMME_MORE), 'Masta Killa: ' + Num(Multi.MASTA_KILLA),
      'Stop It: ' + Num(Multi.STOP_IT)], COLS3, WHITE);

  Section(E, Slot, 'Melee, Explosives & Heavy Arsenal', LINE_W);
  Row(E, Slot, ['Knife Throws: ' + Num(P^.KnivesThrows), Format('Knife Hits: %s (%s)', [Num(P^.KnivesThrowsHitsEnemy),
    Pct(P^.KnivesThrowsHitsEnemy, P^.KnivesThrows)]), 'Knife Stabs: ' + Num(P^.KnivesStabsEnemy)], COLS3, WHITE);
  if P^.ClusterNadesThrows > 0 then
    Name := Format('Cluster hits: %s/%s', [Num(P^.ClusterNadesHurtsEnemy), Num(P^.ClusterNadesThrows)])
  else
    Name := 'Self Nades: ' + Num(P^.NadeHurtsSelf);
  Row(E, Slot, ['Nades Thrown: ' + Num(P^.NadesThrows), Format('Nade Hits: %s (%s)', [Num(P^.NadeHurtsEnemy),
    Pct(P^.NadeHurtsEnemy, P^.NadesThrows)]), Name], COLS3, WHITE);
  { hits/shots, the way Hits of !stats reads }
  Row(E, Slot, [Format('M79 hits: %s/%s (%s)', [Num(P^.M79HurtsEnemy), Num(P^.M79Shots), Pct(P^.M79HurtsEnemy, P^.M79Shots)]),
    Format('LAW hits: %s/%s (%s)', [Num(P^.M72LAWHurtsEnemy), Num(P^.M72LAWShots), Pct(P^.M72LAWHurtsEnemy, P^.M72LAWShots)]),
    'Fist Hurts: ' + Num(P^.HandsHurtsEnemy)], COLS3, WHITE);
  if (P^.ChainsawHurtsEnemy > 0) or (P^.ChainsawTimeUsedSeconds > 0) or (P^.FlamethrowerHitsEnemy > 0) or (P^.M2MGHitsEnemy > 0) then
    Row(E, Slot, [Format('Saw: %s, %s hits', [FormatDurationShort(P^.ChainsawTimeUsedSeconds), Num(P^.ChainsawHurtsEnemy)]),
      Format('Flamer hits: %s/%s', [Num(P^.FlamethrowerHitsEnemy), Num(P^.FlamethrowerShots)]),
      'M2 MG Hits: ' + Num(P^.M2MGHitsEnemy)], COLS3, WHITE);

  if (P^.Teamkills > 0) or (P^.DeathsByFriendly > 0) or (P^.ShotsHitsFriendly > 0) or (P^.ShotsHitsByFriendly > 0) then
  begin
    Section(E, Slot, 'Teamplay & Friendly Incidents', LINE_W);
    Row(E, Slot, ['Teamkills: ' + Num(P^.Teamkills), 'Deaths by Team: ' + Num(P^.DeathsByFriendly),
      'TK Ratio: ' + FloatStr(SafeDivD(P^.Teamkills, P^.DeathsByFriendly), 2)], COLS3, WHITE);
    Row(E, Slot, ['Friendly Hits: ' + Num(P^.ShotsHitsFriendly), 'Hit by Team: ' + Num(P^.ShotsHitsByFriendly),
      'Self Hits: ' + Num(P^.ShotsHitsSelf)], COLS3, WHITE);
    if P^.ShotsHitsFriendlyHead + P^.ShotsHitsFriendlyBody + P^.ShotsHitsFriendlyLeg > 0 then
      Row(E, Slot, ['TK Head: ' + Num(P^.ShotsHitsFriendlyHead), 'TK Body: ' + Num(P^.ShotsHitsFriendlyBody),
        'TK Legs: ' + Num(P^.ShotsHitsFriendlyLeg)], COLS3, WHITE);
  end;

  F := 0;
  for k := 0 to High(P^.ModeStats) do
    if P^.ModeStats[k].Kills + P^.ModeStats[k].Deaths > 0 then
      Inc(F);
  if F > 1 then
  begin
    Section(E, Slot, 'Game Modes (kills / deaths / wins / time)', LINE_W);
    Name := '';
    n := 0;
    for k := 0 to High(P^.ModeStats) do
      if P^.ModeStats[k].Kills + P^.ModeStats[k].Deaths > 0 then
      begin
        case k of
          GS_DM: Victims := 'DM';
          GS_PM: Victims := 'PM';
          GS_TM: Victims := 'TM';
          GS_CTF: Victims := 'CTF';
          GS_RM: Victims := 'RM';
          GS_INF: Victims := 'INF';
          else Victims := 'HTF';
        end;
        Name := Name + PadR(Format('%s %s/%s/%s %s', [Victims, Num(P^.ModeStats[k].Kills), Num(P^.ModeStats[k].Deaths),
          Num(P^.ModeStats[k].Wins), FormatDurationShort(P^.ModeStats[k].TimePlayed)]), MODE_W);
        Inc(n);
        if n mod (LINE_W div MODE_W) = 0 then
        begin
          Out(E, Slot, TrimRight(Name), WHITE);
          Name := '';
        end;
      end;
    if Name <> '' then
      Out(E, Slot, TrimRight(Name), WHITE);
  end;
  Footer(E, Slot, LINE_W);
end;

procedure CmdStatus(E: TZSEngine; Slot, Idx: LongInt);
var
  P: PPlayerProfile;
  S, Dur: LongInt;
  Account: AnsiString;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  P := E.DB.Profiles[Idx];
  Header(E, Slot, '[ Status: ' + P^.ActiveName + ' ]', LINE_W);
  Row(E, Slot, ['Rank: ' + RankText(E, Idx), 'Points: ' + Num(RankingPoints(E, Idx)), 'Rating: ' + FloatStr(PerfRating(E, P^), 1)],
    COLS3, CLR_SUBHEADER);
  Row(E, Slot, ['Play: ' + FormatDuration(P^.TimePlayed), 'Spec: ' + FormatDurationShort(P^.TimeOnSpectator),
    Format('Protect: %d days', [P^.ProtectionDays])], COLS3, CLR_SHOOTING);
  Row(E, Slot, ['First Seen: ' + DateText(P^.RegisterTime, 'dd.mm.yyyy'), 'Last Seen: ' + DateText(P^.LastPlayedTime, 'dd.mm.yyyy'),
    'Seen At: ' + DateText(P^.LastPlayedTime, 'hh:nn')], COLS3, CLR_SHOOTING);
  if IsRealSteam(P^.ActiveSteam) then
    Account := 'Account: Steam'
  else if IsRegistered(P^) then
  begin
    Account := 'Account: computer, password protected';
    if P^.EmailVerified then
      Account := Account + ', e-mail verified';
  end
  else
    Account := 'Account: computer, no password';
  Out(E, Slot, Account, CLR_ACTIVITY);

  S := SlotOfIndex(E, Idx);
  if S = 0 then
    Out(E, Slot, 'Not on the server now; the current session shows while the player is here.', CLR_OTHER_ROW)
  else
  begin
    Section(E, Slot, 'Current Session (since joining)', LINE_W);
    Dur := Max(0, E.GameTick - E.Live[S].JoinTick) div TICKS_PER_SECOND;
    Row(E, Slot, [Format('Kills/Deaths: %s/%s', [Num(E.Live[S].SessionKills), Num(E.Live[S].SessionDeaths)]),
      Format('K/D: %s (HS: %s)', [KD(E.Live[S].SessionKills, E.Live[S].SessionDeaths), Num(E.Live[S].SessionHeadshots)]),
      'Time: ' + FormatDurationShort(Dur)], COLS3, CLR_SHOOTING);
    Row(E, Slot, [Format('Streak: %d kills', [E.Live[S].KillStreak]), 'Pts Delta: ' + Signed(Int64(P^.Points) - E.Live[S].SessionStartPoints),
      Format('Slot: %d (Active)', [S])], COLS3, CLR_SHOOTING);
  end;
  Footer(E, Slot, LINE_W);
end;

{ names of an account: most recent (Kind 0), longest played (1) or most joins (2) first }
function TopNames(const A: TOtherDataArray; Kind, Count: LongInt): AnsiString;
var
  Used: array of Boolean;
  n, k, Best: LongInt;

  function Better(i, j: LongInt): Boolean;
  begin
    case Kind of
      0: Result := A[i].LastUsedDate > A[j].LastUsedDate;
      1: Result := A[i].TimePlayed > A[j].TimePlayed;
      else Result := A[i].LoginCount > A[j].LoginCount;
    end;
  end;

begin
  Result := '';
  Used := nil;
  SetLength(Used, Length(A));
  for n := 1 to Min(Count, Length(A)) do
  begin
    Best := -1;
    for k := 0 to High(A) do
      if not Used[k] and ((Best < 0) or Better(k, Best)) then
        Best := k;
    Used[Best] := True;
    if Result <> '' then
      Result := Result + ', ';
    { long nicks are cut so three of them and their play time or joins fit the line }
    Result := Result + Copy(OtherDataToString(A[Best]), 1, 18);
    case Kind of
      1: Result := Result + ' ' + FormatDurationShort(A[Best].TimePlayed);
      2: Result := Result + ' (' + Num(A[Best].LoginCount) + ')';
    end;
  end;
  if Result = '' then
    Result := '-';
end;

{ admin account audit: identity data is shown to admins only }
{ the computers of an account that are still trusted: not expired and added after the password was set }
function TrustedNow(E: TZSEngine; const P: TPlayerProfile): LongInt;
var
  k: LongInt;
  T: Double;
begin
  Result := 0;
  T := LocalToUtc(E.DB.NowValue);
  for k := 0 to High(P.TrustedDevices) do
    if (P.TrustedDevices[k].Expire >= T) and (P.TrustedDevices[k].LastUsed >= P.PassSetTime) then
      Inc(Result);
end;

procedure CmdAudit(E: TZSEngine; Slot, Idx: LongInt);
var
  P: PPlayerProfile;
  S, Clr: LongInt;
  SlotText, Steam, Mail, TK: AnsiString;
begin
  if not E.DB.Valid(Idx) then
  begin
    Out(E, Slot, 'Account not found. Usage: /zs_status <name> | /zs_statusid <id> | /zs_statusi <pos>', CLR_BAD);
    Exit;
  end;
  P := E.DB.Profiles[Idx];
  S := SlotOfIndex(E, Idx);
  if S > 0 then
    SlotText := 'Slot: ' + IntToStr(S)
  else
    SlotText := 'Slot: Offline';
  if IsRealSteam(P^.ActiveSteam) then
    Steam := P^.ActiveSteam
  else
    Steam := 'none (computer account)';
  Header(E, Slot, '[ Admin Audit: ' + P^.ActiveName + ' ]', LINE_W);
  Row(E, Slot, ['DB ID: ' + IntToStr(P^.ID), SlotText, 'Rank: ' + RankText(E, Idx)], COLS3, CLR_SUBHEADER);
  Row(E, Slot, ['Points: ' + Num(P^.Points), 'Rating: ' + FloatStr(PerfRating(E, P^), 1),
    Format('Protect: %d days', [P^.ProtectionDays])], COLS3, CLR_SUBHEADER);
  Row(E, Slot, ['Steam: ' + Steam, 'IP: ' + P^.ActiveIP], COLS2, CLR_SHOOTING);
  Out(E, Slot, 'HWID:  ' + P^.ActiveHWID, CLR_SHOOTING);
  Out(E, Slot, Format('Names (%d), last used: %s', [Length(P^.OtherNames), TopNames(P^.OtherNames, 0, 3)]), CLR_FEATS);
  Out(E, Slot, 'Most played: ' + TopNames(P^.OtherNames, 1, 3), CLR_FEATS);
  Out(E, Slot, 'Most joins:  ' + TopNames(P^.OtherNames, 2, 3), CLR_FEATS);
  Row(E, Slot, ['First Seen: ' + DateText(P^.RegisterTime, 'dd.mm.yyyy hh:nn'), 'Last Seen:  ' + DateText(P^.LastPlayedTime, 'dd.mm.yyyy hh:nn')],
    COLS2, CLR_ACTIVITY);
  Row(E, Slot, ['Playtime: ' + FormatDuration(P^.TimePlayed), 'Spectator: ' + FormatDurationShort(P^.TimeOnSpectator),
    Format('K/D: %s (%s/%s)', [KD(P^.Kills, P^.Deaths), Num(P^.Kills), Num(P^.Deaths)])], COLS3, CLR_COMBAT);
  { many selfkills right after an enemy hit (more than 1 in 10 deaths): somebody who uses /kill to deny kills }
  if P^.SelfkillsUnderFire * 10 > Max(20, P^.Deaths) then
    Clr := CLR_WARN
  else
    Clr := CLR_COMBAT;
  { teamkills only where friendly fire can make them, or when the account has some }
  if (IsTeamStyle(E.Match.GameStyle) and E.Match.FriendlyFire) or (P^.Teamkills > 0) then
    TK := 'Teamkills: ' + Num(P^.Teamkills)
  else
    TK := '';
  Row(E, Slot, [Format('Selfkills: %s (%s)', [Num(P^.Selfkills), Pct(P^.Selfkills, SelfkillBase(E, P^))]),
    Format('Under fire: %s (%s)', [Num(P^.SelfkillsUnderFire), Pct(P^.SelfkillsUnderFire, P^.Selfkills)]),
    TK], COLS3, Clr);
  if IsRegistered(P^) then
  begin
    if P^.Email <> '' then
      Mail := MaskEmail(P^.Email) + BoolToStr(P^.EmailVerified, ' (verified)', ' (not verified)')
    else
      Mail := 'no e-mail';
    Row(E, Slot, ['Password: set ' + DateText(UtcToLocal(P^.PassSetTime), 'dd.mm.yyyy'), 'E-mail: ' + Mail], COLS2, CLR_HINT);
    Row(E, Slot, [Format('Trusted devices: %d', [TrustedNow(E, P^)]), Format('Failed logins: %d', [P^.LoginFailCount]),
      BoolToStr(P^.LoginLockUntil > LocalToUtc(E.DB.NowValue), 'LOCKED', 'not locked')], COLS3, CLR_HINT);
  end
  else
    Out(E, Slot, 'Password: none (unregistered account)', CLR_HINT);
  Footer(E, Slot, LINE_W);
end;

{ the session of the player on server slot T (!session, !session <p>, !sessioni <n>): only a
  player in the game has one; T = -1 when nobody on the server matched }
procedure CmdSession(E: TZSEngine; Slot, T: LongInt);
var
  Idx, Dur: LongInt;
  P: PPlayerProfile;
  Own: Boolean;
begin
  Own := T = Slot;
  if not E.SlotValid(T) or not E.Live[T].Active or not E.Live[T].Human then
  begin
    if Own then
      Out(E, Slot, 'Session statistics are for players in the game.', CLR_WARN)
    else
      Out(E, Slot, 'No player on the server matches that (sessions are for players in the game).', CLR_BAD);
    Exit;
  end;
  Idx := E.Identity.ProfileIndex(T);
  if not E.DB.Valid(Idx) then
  begin
    if E.Identity.IsPending(T) then
    begin
      if Own then
        Out(E, Slot, 'Waiting for Steam to confirm your account, try again in a moment.', CLR_WARN)
      else
        Out(E, Slot, 'Waiting for Steam to confirm the account of ' + E.Live[T].Name + '.', CLR_WARN);
    end
    else if Own then
      Out(E, Slot, 'Statistics are off for this session.', CLR_WARN)
    else
      Out(E, Slot, 'Statistics are off for the session of ' + E.Live[T].Name + '.', CLR_WARN);
    Exit;
  end;
  P := E.DB.Profiles[Idx];
  Dur := Max(0, E.GameTick - E.Live[T].JoinTick) div TICKS_PER_SECOND;
  Header(E, Slot, 'Session Stats: ' + E.Live[T].Name, LINE_W);
  Row(E, Slot, ['Kills: ' + Num(E.Live[T].SessionKills), 'Deaths: ' + Num(E.Live[T].SessionDeaths),
    'K/D: ' + KD(E.Live[T].SessionKills, E.Live[T].SessionDeaths)], COLS3, CLR_SHOOTING);
  Row(E, Slot, ['Headshots: ' + Num(E.Live[T].SessionHeadshots), 'Points: ' + Signed(Int64(P^.Points) - E.Live[T].SessionStartPoints),
    'Time: ' + FormatDurationShort(Dur)], COLS3, CLR_SHOOTING);
  { captures only where there are flags, won rounds only in survival (or when some were won) }
  CellRows(E, Slot, ['Wins: ' + Num(E.Live[T].SessionWins),
    IfText(ObjectiveMode(E) or (E.Live[T].SessionCaps > 0), 'Caps: ' + Num(E.Live[T].SessionCaps)),
    IfText(E.Match.Survival or (E.Live[T].SessionRoundWins > 0), 'Rounds Won: ' + Num(E.Live[T].SessionRoundWins))],
    COLS3, CLR_SHOOTING);
  Row(E, Slot, ['Current Streak: ' + IntToStr(E.Live[T].KillStreak), 'Total Points: ' + Num(RankingPoints(E, Idx)),
    'Rank: ' + RankText(E, Idx)], COLS3, CLR_SHOOTING);
  if E.Identity.StatsIndex(T) < 0 then
  begin
    if Own then
      Out(E, Slot, 'Not logged in: this session is not saved to the account (/login).', CLR_WARN)
    else
      Out(E, Slot, E.Live[T].Name + ' is not logged in: the session is not saved to the account.', CLR_WARN);
  end;
  Footer(E, Slot, LINE_W);
end;

procedure CmdRank(E: TZSEngine; Slot, Idx: LongInt);
var
  P: PPlayerProfile;
  Tier, Tail: AnsiString;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  P := E.DB.Profiles[Idx];
  Tier := Copy(E.TierName(Idx), 1, 14);
  if Tier <> '' then
    Tier := ' ' + Tier;
  { the name takes what is left of the LINE_W characters, so the line never wraps }
  Tail := Format(' #%s/%d%s | Pts %s | Rating %s | K/D %s (%s/%s)',
    [RankText(E, Idx), RankingCount(E), Tier, Num(RankingPoints(E, Idx)), FloatStr(PerfRating(E, P^), 1),
     KD(P^.Kills, P^.Deaths), Num(P^.Kills), Num(P^.Deaths)]);
  Out(E, Slot, '[Rank] ' + Copy(P^.ActiveName, 1, Max(6, LINE_W - 7 - Length(Tail))) + Tail, CLR_COMBAT);
end;

procedure CmdRambo(E: TZSEngine; Slot, Idx: LongInt);
var
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  Shared := Default(TPlayerProfile);
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  Header(E, Slot, 'Rambomatch Stats: ' + P^.ActiveName, LINE_W);
  Row(E, Slot, ['Rambo Kills: ' + Num(P^.RamboMode.KillRamboCount), 'Kills With Bow: ' + Num(P^.RamboMode.KillsByBow)],
    COLS2, CLR_SHOOTING);
  Row(E, Slot, ['Bow Pickups: ' + Num(P^.RamboMode.GetsBow), 'Bow Drops: ' + Num(P^.RamboMode.DropBow)], COLS2, CLR_SHOOTING);
  Row(E, Slot, ['Kills Non-Rambo: ' + Num(P^.RamboMode.KillsWhenNoRambo), 'Deaths Non-Rambo: ' + Num(P^.RamboMode.DeathsWhenNoRambo)],
    COLS2, CLR_SHOOTING);
  Row(E, Slot, ['Time With Bow: ' + FormatDurationShort(P^.RamboMode.TimeWithBow), 'Time Without Bow: ' + FormatDurationShort(P^.RamboMode.TimeWithoutBow)],
    COLS2, CLR_SHOOTING);
  Footer(E, Slot, LINE_W);
end;

procedure CmdSpree(E: TZSEngine; Slot, Idx: LongInt);
var
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
  M: TPointmatchMulti;
  Title, Third: AnsiString;
  Levels: TStringArray;
  k, n: LongInt;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  Shared := Default(TPlayerProfile);
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  M := P^.PointmatchMode.Multi;
  if E.Match.GameStyle = GS_PM then
    Title := 'Pointmatch & Spree Records: '
  else
    Title := 'Multi-Kill & Spree Records: ';
  Header(E, Slot, Title + P^.ActiveName, LINE_W);
  Row(E, Slot, ['Best Streak: ' + IntToStr(P^.MaxKillStreak), 'Shut Downs: ' + Num(P^.ShutDownKills),
    'Finishers: ' + Num(P^.FinisherKills)], COLS3, CLR_SHOOTING);
  { every level of [Sprees] with the streaks that reached its kills: they are counted by their
    length, so a level whose kills change shows its own count at once }
  if E.Cfg.SpreeLevelCount > 0 then
  begin
    Section(E, Slot, 'Kill Streaks - times reached', LINE_W);
    Levels := nil;
    SetLength(Levels, E.Cfg.SpreeLevelCount);
    for k := 0 to E.Cfg.SpreeLevelCount - 1 do
    begin
      n := E.Cfg.SpreeLevels[k].Kills;
      Levels[k] := Format('%s (%d %s): %s', [E.Cfg.SpreeLevels[k].Name, n, BoolToStr(n = 1, 'kill', 'kills'),
        Num(SpreeLivesAt(P^, n))]);
    end;
    CellRows(E, Slot, Levels, COLS2, CLR_SHOOTING);
    Section(E, Slot, 'Multi-Kill Medals', LINE_W);
  end;
  if (E.Match.GameStyle = GS_PM) or (P^.PointmatchMode.ExtraPoints > 0) then
    Third := 'PM Bonus: ' + Num(P^.PointmatchMode.ExtraPoints)
  else
    Third := '';
  Row(E, Slot, ['Double: ' + Num(M.DOUBLE_KILL), 'Triple: ' + Num(M.TRIPLE_KILL), 'Multi: ' + Num(M.MULTI_KILL)], COLS3, CLR_SHOOTING);
  Row(E, Slot, ['Multi X2: ' + Num(M.MULTI_KILL_X2), 'Serial: ' + Num(M.SERIAL_KILL), 'Insane: ' + Num(M.INSANE_KILLS)], COLS3, CLR_SHOOTING);
  Row(E, Slot, ['Gimme More: ' + Num(M.GIMME_MORE), 'Masta Killa: ' + Num(M.MASTA_KILLA), 'Stop It: ' + Num(M.STOP_IT)], COLS3, CLR_SHOOTING);
  Row(E, Slot, ['Mercy: ' + Num(M.MERCY), 'Cheater: ' + Num(M.CHEATER), Third], COLS3, CLR_SHOOTING);
  Footer(E, Slot, LINE_W);
end;

{ the unlocked achievements, five per line, and the season badges }
procedure CmdAchievements(E: TZSEngine; Slot, Idx: LongInt);
var
  k, n: LongInt;
  P: PPlayerProfile;
  Shared: TPlayerProfile;
  Note: AnsiString;
  Names, Badges: TStringArray;
begin
  if not E.DB.Valid(Idx) then
  begin
    NotFound(E, Slot);
    Exit;
  end;
  Shared := Default(TPlayerProfile);
  P := SharedView(E, Idx, Shared, Note);
  if Note <> '' then
    Out(E, Slot, Note, CLR_HINT);
  n := 0;
  Names := nil;
  SetLength(Names, ACH_COUNT);
  for k := 1 to ACH_COUNT do
    if HasAchievement(P^, k) then
    begin
      Names[n] := AchievementName(k);
      Inc(n);
    end;
  SetLength(Names, n);
  Header(E, Slot, Format('Achievements of %s: %d/%d', [P^.ActiveName, n, ACH_COUNT]), LINE_W);
  if n = 0 then
    Out(E, Slot, 'None yet.', CLR_OTHER_ROW)
  else
    CmdGrid(E, Slot, Names, 5, LINE_W div 5, CLR_FEATS);
  { one badge a season: after many seasons the list goes on over more lines }
  Badges := nil;
  SetLength(Badges, Length(P^.Badges));
  for k := 0 to High(P^.Badges) do
    Badges[k] := Format('Season %d: #%d', [P^.Badges[k].SeasonId, P^.Badges[k].Place]);
  WrapList(E, Slot, 'Season badges: ', Badges, CLR_TOP1);
  Footer(E, Slot, LINE_W);
  Out(E, Slot, 'Every achievement and what it takes: !achlist', CLR_HINT);
end;

{ every achievement with what it takes, two per line; for a player the unlocked ones come first }
procedure CmdAchievementList(E: TZSEngine; Slot, Idx: LongInt);
const
  CELL = LINE_W div 2;
var
  k, n, Got: LongInt;
  P: PPlayerProfile;
  Order: array[0..ACH_COUNT - 1] of LongInt;
  Has: array[1..ACH_COUNT] of Boolean;
  Line: AnsiString;

  function CellText(Id: LongInt): AnsiString;
  begin
    if Has[Id] then
      Result := '[x] '
    else
      Result := '[ ] ';
    Result := Result + PadR(AchievementDefs[Id].Name, 16) + AchievementDefs[Id].Info;
  end;

begin
  P := nil;
  if E.DB.Valid(Idx) then
    P := E.DB.Profiles[Idx];
  Got := 0;
  for k := 1 to ACH_COUNT do
  begin
    Has[k] := (P <> nil) and HasAchievement(P^, k);
    if Has[k] then
      Inc(Got);
  end;
  n := 0;
  for k := 1 to ACH_COUNT do
    if Has[k] then
    begin
      Order[n] := k;
      Inc(n);
    end;
  for k := 1 to ACH_COUNT do
    if not Has[k] then
    begin
      Order[n] := k;
      Inc(n);
    end;
  if P <> nil then
    Header(E, Slot, Format('Achievements of %s: %d/%d', [P^.ActiveName, Got, ACH_COUNT]), LINE_W)
  else
    Header(E, Slot, Format('Achievements (%d)', [ACH_COUNT]), LINE_W);
  k := 0;
  while k < ACH_COUNT do
  begin
    Line := PadR(CellText(Order[k]), CELL);
    if k + 1 < ACH_COUNT then
      Line := Line + CellText(Order[k + 1]);
    if Has[Order[k]] then
      Out(E, Slot, TrimRight(Line), CLR_GOOD)
    else
      Out(E, Slot, TrimRight(Line), WHITE);
    Inc(k, 2);
  end;
  Footer(E, Slot, LINE_W);
end;

procedure CmdHud(E: TZSEngine; Slot: LongInt);
var
  Idx: LongInt;
begin
  if not E.Cfg.HudEnabled then
  begin
    Out(E, Slot, 'The HUD is turned off on this server.', CLR_WARN);
    Exit;
  end;
  Idx := ViewerIndex(E, Slot);
  if not E.DB.Valid(Idx) then
  begin
    Out(E, Slot, 'The HUD is for players with statistics on this server.', CLR_WARN);
    Exit;
  end;
  E.DB.Profiles[Idx]^.DisplayHUD := not E.DB.Profiles[Idx]^.DisplayHUD;
  E.DB.Touch(Idx);
  if E.DB.Profiles[Idx]^.DisplayHUD then
    Out(E, Slot, 'HUD enabled.', CLR_GOOD)
  else
    Out(E, Slot, 'HUD disabled.', CLR_WARN);
end;
