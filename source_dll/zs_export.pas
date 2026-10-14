unit zs_export;

{ JSON exports for websites and optional webhooks.

  stats.json   (JSONExportPath)  ranking top, maps, weapons, recent seasons. The keys of the
               4.x file are kept, "format": 2 marks the additions. The *_px keys hold distances
               in pixels (14 px = 1 m, the scale Soldat uses), the *_m keys the same in meters.
  players.json (FullExportPath)  every account with its detailed statistics.

  Neither file contains IP addresses, hardware IDs, SteamIDs or e-mail addresses.
  The JSON text is built on the engine thread and written by the IO thread (atomic replace);
  players.json a part every timer run, so the engine never stops for the whole file.
  Webhooks are posted by the service thread; events: export, match, season, record.

  Everything here only reads statistics. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, zs_types, zs_util, zs_config, zs_db, zs_rank, zs_rating, zs_weapons, zs_rules,
  zs_identity, zs_store, zs_service, zs_engine;

{ periodic and requested exports, deferred server record webhooks; called by the engine timers }
procedure ExportTick(E: TZSEngine; NowMs: Int64);
procedure WebhookMatch(E: TZSEngine);
procedure WebhookSeason(E: TZSEngine; ArchiveIndex: LongInt);
{ the detailed statistics of one account, the same object players.json holds }
function PlayerJson(E: TZSEngine; Index: LongInt): AnsiString;

implementation

uses
  zs_commands;

const
  RECORD_SETTLE_MS = 5 * 60 * 1000;   { a new online peak is reported after it held for 5 minutes }
  FULL_PART_BYTES = 1024 * 1024;      { players.json: a part holds about this much text at most }
  FULL_PART_MICROS = 20000;           { and takes about this much of a timer run }
  MODE_NAMES: array[0..6] of AnsiString = ('DM', 'PM', 'TM', 'CTF', 'RM', 'INF', 'HTF');
  TEAM_NAMES: array[0..5] of AnsiString = ('none', 'alpha', 'bravo', 'charlie', 'delta', 'spectator');

type
  TJson = record
    Buf: AnsiString;
    Len: LongInt;
  end;

var
  NameCodepage: LongInt = 1250;   { [General] SourceCodepage, set by every entry point }
  StateOwner: TZSEngine = nil;
  LastExportMs: Int64;
  PeakPosted: LongInt;
  PeakSeen: LongInt;
  PeakChangedMs: Int64;
  { players.json being built: the accounts (by id) when it started, the next of them (-1 = none
    being built), the accounts written, the file and the mark of who waits for it }
  FullIds: TIntArray;
  FullNext: LongInt = -1;
  FullCount: LongInt;
  FullPath: AnsiString;
  FullTag: LongInt;

procedure Put(var W: TJson; const S: AnsiString);
var
  n: LongInt;
begin
  n := Length(S);
  if n = 0 then
    Exit;
  if W.Len + n > Length(W.Buf) then
    SetLength(W.Buf, Max(W.Len + n, Length(W.Buf) * 2 + 16384));
  Move(S[1], W.Buf[W.Len + 1], n);
  Inc(W.Len, n);
end;

function Text(const W: TJson): AnsiString;
begin
  Result := Copy(W.Buf, 1, W.Len);
end;

function KS(const Key, Value: AnsiString): AnsiString;
begin
  Result := JsonStr(Key) + ': ' + JsonStr(CpToUtf8(Value, NameCodepage));
end;

function KI(const Key: AnsiString; V: Int64): AnsiString;
begin
  Result := JsonStr(Key) + ': ' + IntToStr(V);
end;

function KF(const Key: AnsiString; V: Double; Decimals: LongInt): AnsiString;
begin
  Result := JsonStr(Key) + ': ' + FloatStr(V, Decimals);
end;

function KB(const Key: AnsiString; V: Boolean): AnsiString;
begin
  Result := JsonStr(Key) + ': ' + BoolToStr(V, 'true', 'false');
end;

{ a whole number of a measured value: Round raises on a NaN, an infinity or a value beyond Int64,
  which would stop the whole export }
function WholeOf(V: Double): Int64;
begin
  if IsNan(V) or IsInfinite(V) or (Abs(V) > 9.0E18) then
    Result := 0
  else
    Result := Round(V);
end;

{ written with fixed separators: FormatDateTime puts the time separator of the system's language
  in place of ':' (a '.' on some) }
function IsoTime(T: TDateTime): AnsiString;
var
  Y, Mo, D, H, Mi, S, Ms: Word;
begin
  if IsNan(T) or IsInfinite(T) or (T <= 0) or (T > 2958465) then
    Exit('null');
  DecodeDate(T, Y, Mo, D);
  DecodeTime(T, H, Mi, S, Ms);
  Result := Format('"%.4d-%.2d-%.2dT%.2d:%.2d:%.2d"', [Y, Mo, D, H, Mi, S]);
end;

function KT(const Key: AnsiString; T: TDateTime): AnsiString;
begin
  Result := JsonStr(Key) + ': ' + IsoTime(T);
end;

function ModeName(GameStyle: LongInt): AnsiString;
begin
  if (GameStyle >= 0) and (GameStyle <= High(MODE_NAMES)) then
    Result := MODE_NAMES[GameStyle]
  else
    Result := 'unknown';
end;

function RatingSystemName(E: TZSEngine): AnsiString;
begin
  case E.RatingSystem of
    RS_MMR: Result := 'mmr';
    RS_GLICKO2: Result := 'glicko2';
    RS_OPENSKILL: Result := 'openskill';
    else Result := 'elo';
  end;
end;

function Perf(E: TZSEngine; const P: TPlayerProfile): Double;
begin
  Result := PerformanceRating(P, E.Match.GameStyle, E.Match.Survival, E.Match.FriendlyFire, E.Cfg.RatingMode);
end;

{ the value of the selected ranking system; with elo (points) the MMR, like !topskill }
function Skill(E: TZSEngine; const P: TPlayerProfile; Family: LongInt): Double;
begin
  case E.RatingSystem of
    RS_GLICKO2: Result := GlickoConservative(P.Glicko[Family], E.Cfg.GlickoConservative);
    RS_OPENSKILL: Result := OpenSkillOrdinal(P.OpenSkill[Family]);
    else Result := P.Mmr[Family].R;
  end;
end;

function WebhookWanted(E: TZSEngine; const Event: AnsiString): Boolean;
begin
  Result := E.Cfg.WebhookEnabled and (Trim(E.Cfg.WebhookUrl) <> '') and
    (Pos(',' + Event + ',', ',' + StringReplace(LowerCase(E.Cfg.WebhookEvents), ' ', '', [rfReplaceAll]) + ',') > 0);
end;

{ a player name inside a Discord message: markdown characters are shown as they are }
function DiscordName(const S: AnsiString): AnsiString;
var
  i: LongInt;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    if S[i] in ['\', '*', '_', '~', '`', '|', '>', '[', ']'] then
      Result := Result + '\';
    Result := Result + S[i];
  end;
end;

function DayText(T: TDateTime): AnsiString;
begin
  if T <= 0 then
    Result := '?'
  else
    Result := FormatDateTime('dd"."mm"."yyyy', T);
end;

{ Payload is the event as JSON; Summary is the same event as a chat message, sent instead
  when [Webhook] Format = discord. Discord takes at most 2000 characters, and a player
  called @everyone must not ping the whole channel. }
procedure PostWebhook(E: TZSEngine; const Payload, Summary: AnsiString);
var
  Job: TServiceJob;
begin
  Job := NewServiceJob(svHttpPost);
  Job.Url := Trim(E.Cfg.WebhookUrl);
  if E.Cfg.WebhookFormat = 'discord' then
    Job.Payload := '{' + JsonStr('content') + ': ' + JsonStr(CpToUtf8(Copy(Summary, 1, 1900), NameCodepage)) +
      ', "allowed_mentions": {"parse": []}}'
  else
    Job.Payload := Payload;
  if not E.SubmitJob(Job) then
    E.WriteServer('[ZitroStats] webhook skipped, the service queue is full');
end;

procedure WriteText(E: TZSEngine; const Path, Data: AnsiString; Tag: LongInt = 0);
var
  Job: TStoreJob;
begin
  if (E.IO = nil) or (Trim(Path) = '') then
    Exit;
  Job := NewJob(sjWriteFile, 0, Tag);
  Job.Path := ResolvePath(Path);
  Job.Data := Data;
  E.IO.Enqueue(Job);
end;

{ ---------------- stats.json ---------------- }

procedure PlayerCompat(E: TZSEngine; var W: TJson; Idx, Rank: LongInt);
var
  P: PPlayerProfile;
  Shots: Int64;
begin
  P := E.DB.Profiles[Idx];
  Shots := Max(Int64(P^.Shots), Int64(P^.ShotsHits));
  Put(W, '{' + KI('rank', Rank) + ', ' + KI('id', P^.ID) + ', ' + KS('name', P^.ActiveName) + ', ' + KS('tier', E.TierName(Idx)) + ', ' +
    KI('points', P^.Points) + ', ' + KF('rating', Perf(E, P^), 1) + ', ' + KF('kdr', P^.Kills / Max(1, P^.Deaths), 2) + ', ' +
    KI('kills', P^.Kills) + ', ' + KI('deaths', P^.Deaths) + ', ' + KI('selfkills', P^.Selfkills) + ', ' + KI('assists', P^.Assist) + ', ' +
    KI('headshots', P^.ShotsHitsHead) + ', ' + KF('accuracy_pct', Min(100.0, SafeDivD(P^.ShotsHits * 100.0, Shots)), 1) + ', ' +
    KF('headshot_pct', Min(100.0, SafeDivD(P^.ShotsHitsHead * 100.0, P^.ShotsHits)), 1) + ', ' + KI('playtime_sec', P^.TimePlayed) + ', ' +
    KI('max_killstreak', P^.MaxKillStreak) + ', ' + KI('longest_kill_px', WholeOf(P^.LongestKillDistance * PIXELS_PER_METER)) + ', ' +
    KI('longest_barret_px', WholeOf(P^.LongestBarrettDistance * PIXELS_PER_METER)) + ', ' +
    KI('avg_kill_dist_px', WholeOf(SafeDivD(P^.TotalKillDistance, P^.KillDistanceCount) * PIXELS_PER_METER)) + ', ' +
    KF('damage_dealt', P^.DamageDealt, 0) + ', ' + KF('damage_received', P^.DamageReceived, 0) + ', ' +
    KF('damage_ratio', SafeDivD(P^.DamageDealt, P^.DamageReceived), 2) + ', ' + KI('first_bloods', P^.FirstBloodCount) + ', ' +
    KI('round_first_bloods', P^.RoundFirstBloodCount) + ', ' +
    KI('first_damage', P^.FirstDamageCount) + ', ' +
    KF('longest_kill_m', P^.LongestKillDistance, 1) + ', ' + KF('longest_barrett_m', P^.LongestBarrettDistance, 1) + ', ' +
    KF('avg_kill_dist_m', SafeDivD(P^.TotalKillDistance, P^.KillDistanceCount), 1) + ', ' + KI('wins', P^.Wins) + ', ' +
    KI('loses', P^.Loses) + ', ' + KI('draws', P^.Draws) + ', ' + KI('caps', P^.FlagsScore) + ', ' +
    KI('season_points', P^.SeasonPoints) + ', ' + KI('achievements', Length(P^.Achievements)) + ', ' +
    KB('registered', IsRegistered(P^)) + ', ' + KT('last_seen', P^.LastPlayedTime) + '}');
end;

{ average players in every tenth of the match time; null for a tenth without data }
function PlayerCurveJson(const M: TMapProfile): AnsiString;
var
  k: LongInt;
begin
  Result := '[';
  for k := 0 to 9 do
  begin
    if k > 0 then
      Result := Result + ', ';
    if M.CurveSecs[k] > 0 then
      Result := Result + FloatStr(M.CurveSum[k] / M.CurveSecs[k], 2)
    else
      Result := Result + 'null';
  end;
  Result := Result + ']';
end;

procedure MapObject(var W: TJson; const M: TMapProfile);
var
  Stayed: AnsiString;
begin
  if M.EndHumansSum > 0 then
    Stayed := FloatStr(Min(100.0, M.StayedHumansSum * 100.0 / M.EndHumansSum), 1)
  else
    Stayed := 'null';
  Put(W, '{' + KI('id', M.ID) + ', ' + KS('map', M.MapName) + ', ' + KI('plays', M.ActiveMapPlays) + ', ' + KI('kills', M.Kills) + ', ' +
    KI('selfkills', M.Selfkills) + ', ' + KI('playtime_sec', M.ActiveTimePlays) + ', ' + KI('caps', M.FlagsScore) + ', ' +
    KI('alpha_wins', M.AlphaWins) + ', ' + KI('bravo_wins', M.BravoWins) + ', ' + KI('draws', M.Draws) + ', ' +
    KI('avg_match_sec', WholeOf(AvgMatchSeconds(M))) + ', ' +
    KF('avg_players', SafeDivD(M.HumansSampleSum, M.HumansSampleCount), 1) + ', ' + KF('fastest_cap_sec', M.FastestCapSeconds, 2) + ', ' +
    KI('votes_started', M.VoteStarts) + ', ' + KI('votes_won', M.VotesPassed) + ', ' + KI('voted_in', M.VotedIn) + ', ' +
    JsonStr('stayed_pct') + ': ' + Stayed + ', ' + JsonStr('players_by_time') + ': ' + PlayerCurveJson(M) + ', ' +
    KF('longest_hit_m', M.LongestHit, 1) + ', ' + KF('avg_hit_dist_m', SafeDivD(M.HitDistSum, M.HitDistCount), 1) + ', ' +
    KF('avg_hit_flight_sec', SafeDivD(M.HitAirTicks, M.HitAirCount) / TICKS_PER_SECOND, 2) + ', ' +
    KF('avg_kill_flight_sec', SafeDivD(M.KillAirTicks, M.KillAirCount) / TICKS_PER_SECOND, 2) + ', ' +
    KT('last_played', M.LastPlayedTime) + '}');
end;

{ the same totals as !topweapons and !server }
procedure WeaponsArray(E: TZSEngine; var W: TJson);
var
  S: LongInt;
  T: array[0..WSLOT_COUNT - 1] of TWeaponTotals;
  G: ^TWeaponGlobal;
  First: Boolean;
begin
  CollectWeaponTotals(E, T);
  Put(W, '[');
  First := True;
  for S := 0 to WSLOT_COUNT - 1 do
  begin
    G := @E.DB.Server.WeaponGlobal[S];
    if (T[S].Kills = 0) and (T[S].Shots = 0) and (T[S].Hits = 0) and (G^.Picks = 0) then
      Continue;
    if not First then
      Put(W, ',');
    First := False;
    Put(W, LineEnding + '    {' + KS('name', SlotName(S)) + ', ' + KI('kills', T[S].Kills) + ', ' + KI('deaths', T[S].Deaths) + ', ' +
      KI('shots', T[S].Shots) + ', ' + KI('hits', T[S].Hits) + ', ' + KI('headshots', T[S].Headshots) + ', ' +
      KF('accuracy_pct', Min(100.0, SafeDivD(T[S].Hits * 100.0, T[S].Shots)), 1) + ', ' +
      KF('headshot_pct', Min(100.0, SafeDivD(T[S].Headshots * 100.0, T[S].Hits)), 1) + ', ' +
      KF('damage', T[S].Damage, 0) + ', ' + KI('time_sec', T[S].Time) + ', ' +
      KF('damage_per_min', SafeDivD(T[S].Damage * 60.0, T[S].Time), 1) + ', ' +
      KF('hits_per_kill', SafeDivD(T[S].Hits, T[S].Kills), 2) + ', ' +
      KF('longest_kill_m', T[S].Longest, 1) + ', ' +
      KF('avg_kill_dist_m', SafeDivD(G^.KillDistSum, G^.KillDistCount), 1) + ', ' +
      KF('longest_hit_m', T[S].LongestHit, 1) + ', ' + KF('avg_hit_dist_m', SafeDivD(T[S].HitDistSum, T[S].HitDistCount), 1) +
      ', ' + KF('avg_hit_flight_sec', SafeDivD(T[S].HitAirTicks, T[S].HitAirCount) / TICKS_PER_SECOND, 2) + ', ' +
      KF('avg_kill_flight_sec', SafeDivD(T[S].KillAirTicks, T[S].KillAirCount) / TICKS_PER_SECOND, 2) + ', ' +
      KF('avg_ttk_sec', SafeDivD(G^.TTKSumTicks, G^.TTKCount) / TICKS_PER_SECOND, 2) + ', ' + KI('picks', G^.Picks) + ', ' +
      KI('picks_alpha', G^.PicksTeam[1]) + ', ' + KI('picks_bravo', G^.PicksTeam[2]) + ', ' +
      KI('picks_charlie', G^.PicksTeam[3]) + ', ' + KI('picks_delta', G^.PicksTeam[4]) + ', ' +
      KI('vest_kills', G^.VestKills) + '}');
  end;
  Put(W, LineEnding + '  ]');
end;

function StatsJson(E: TZSEngine): AnsiString;
var
  W: TJson;
  r, Idx, Count, k, n, S, T: LongInt;
  Rows: array of LongInt;
  SE: ^TSeasonEntry;
begin
  W.Buf := '';
  W.Len := 0;
  Put(W, '{' + LineEnding);
  Put(W, '  ' + KI('format', 2) + ',' + LineEnding);
  Put(W, '  ' + KS('generator', 'ZitroStats ' + ZS_VERSION_STR) + ',' + LineEnding);
  Put(W, '  ' + KT('generated_at', Now) + ',' + LineEnding);
  Put(W, '  ' + KS('version', ZS_VERSION_STR) + ',' + LineEnding);
  Put(W, '  ' + KI('total_players', E.DB.LiveProfiles) + ',' + LineEnding);
  Put(W, '  ' + KI('total_maps', E.DB.MapCount) + ',' + LineEnding);
  Put(W, '  "server": {' + KI('online', E.HumansOnline) + ', ' + KS('map', E.Match.MapName) + ', ' + KS('mode', ModeName(E.Match.GameStyle)) + ', ' +
    KI('peak_online', E.DB.Server.PeakOnlineCount) + ', ' + KT('peak_online_date', E.DB.Server.PeakOnlineDate) + ', ' +
    KI('total_matches', E.DB.Server.TotalMatches) + ', ' + KS('rating_system', RatingSystemName(E)) + ', ' +
    KI('season', E.DB.Server.SeasonId) + ', ' + KT('season_end', E.DB.Server.SeasonEnd) + '},' + LineEnding);

  Put(W, '  "players": [');
  Count := Min(E.DB.Ranks[RANK_POINTS].Count, Max(1, E.Cfg.JSONExportTopCount));
  n := 0;
  for r := 1 to Count do
  begin
    Idx := E.DB.Ranks[RANK_POINTS].At(r);
    if not E.DB.Valid(Idx) then
      Continue;
    if n > 0 then
      Put(W, ',');
    Inc(n);
    Put(W, LineEnding + '    ');
    PlayerCompat(E, W, Idx, r);
  end;
  Put(W, LineEnding + '  ],' + LineEnding);

  { maps by played time }
  SetLength(Rows, E.DB.MapCount);
  for k := 0 to E.DB.MapCount - 1 do
    Rows[k] := k;
  for k := 1 to E.DB.MapCount - 1 do
  begin
    T := Rows[k];
    n := k - 1;
    while (n >= 0) and (E.DB.Maps[Rows[n]].ActiveTimePlays < E.DB.Maps[T].ActiveTimePlays) do
    begin
      Rows[n + 1] := Rows[n];
      Dec(n);
    end;
    Rows[n + 1] := T;
  end;
  Put(W, '  "maps": [');
  for k := 0 to E.DB.MapCount - 1 do
  begin
    if k > 0 then
      Put(W, ',');
    Put(W, LineEnding + '    ');
    MapObject(W, E.DB.Maps[Rows[k]]);
  end;
  Put(W, LineEnding + '  ],' + LineEnding);

  Put(W, '  "weapons": ');
  WeaponsArray(E, W);
  Put(W, ',' + LineEnding);

  Put(W, '  "seasons": [');
  n := 0;
  for S := High(E.DB.Seasons) downto Max(0, High(E.DB.Seasons) - 2) do
  begin
    if n > 0 then
      Put(W, ',');
    Inc(n);
    Put(W, LineEnding + '    {' + KI('id', E.DB.Seasons[S].Id) + ', ' + KT('start', E.DB.Seasons[S].StartDate) + ', ' +
      KT('end', E.DB.Seasons[S].EndDate) + ', "top": [');
    for k := 0 to Min(2, High(E.DB.Seasons[S].Entries)) do
    begin
      if k > 0 then
        Put(W, ', ');
      SE := @E.DB.Seasons[S].Entries[k];
      Put(W, '{' + KI('place', SE^.Place) + ', ' + KS('name', SE^.Name) + ', ' + KI('season_points', SE^.SeasonPoints) + ', ' +
        KI('points', SE^.Points) + '}');
    end;
    Put(W, ']}');
  end;
  Put(W, LineEnding + '  ]' + LineEnding + '}' + LineEnding);
  Result := Text(W);
end;

{ ---------------- players.json ---------------- }

procedure PlayerFull(E: TZSEngine; var W: TJson; Idx: LongInt);
var
  P: PPlayerProfile;
  k, n: LongInt;
  WS: ^TWeaponStats;
  MS: ^TModeStats;
begin
  P := E.DB.Profiles[Idx];
  Put(W, '{' + KI('id', P^.ID) + ', ' + KS('name', P^.ActiveName) + ', ' + KI('rank', E.PlayerRank(Idx)) + ', ' +
    KS('tier', E.TierName(Idx)) + ', ' + KI('points', P^.Points) + ', ' + KF('rating', Perf(E, P^), 1) + ', ' +
    KF('skill_ffa', Skill(E, P^, RF_FFA), 1) + ', ' + KF('skill_team', Skill(E, P^, RF_TEAM), 1) + ', ' + KF('skill_ctf', Skill(E, P^, RF_CTF), 1) + ', ' +
    KI('kills', P^.Kills) + ', ' + KI('deaths', P^.Deaths) + ', ' + KI('assists', P^.Assist) + ', ' + KI('selfkills', P^.Selfkills) + ', ' +
    KI('teamkills', P^.Teamkills) + ', ' + KI('shots', Max(P^.Shots, P^.ShotsHits)) + ', ' + KI('hits', P^.ShotsHits) + ', ' +
    KI('hits_head', P^.ShotsHitsHead) + ', ' + KI('hits_body', P^.ShotsHitsBody) + ', ' + KI('hits_legs', P^.ShotsHitsLeg) + ', ' +
    KF('damage_dealt', P^.DamageDealt, 0) + ', ' + KF('damage_received', P^.DamageReceived, 0) + ', ' +
    KI('playtime_sec', P^.TimePlayed) + ', ' + KI('alive_sec', P^.TimeAlive) + ', ' + KI('spectator_sec', P^.TimeOnSpectator) + ', ' +
    KI('wins', P^.Wins) + ', ' + KI('loses', P^.Loses) + ', ' + KI('draws', P^.Draws) + ', ' + KI('rounds_won', P^.RoundsWins) + ', ' +
    KI('rounds_lost', P^.RoundsLose) + ', ' + KI('caps', P^.FlagsScore) + ', ' + KI('returns', P^.FlagsReturn) + ', ' +
    KI('grabs', P^.FlagsGrab) + ', ' + KI('flag_hold_sec', P^.TimeHoldingFlags) + ', ' + KF('fastest_cap_sec', P^.FastestCapSeconds, 2) + ', ' +
    KI('best_streak', P^.MaxKillStreak) + ', ' + KF('longest_kill_m', P^.LongestKillDistance, 1) + ', ' +
    KF('avg_kill_dist_m', SafeDivD(P^.TotalKillDistance, P^.KillDistanceCount), 1) + ', ' +
    KF('avg_ttk_sec', SafeDivD(P^.TTKSumTicks, P^.TTKCount) / TICKS_PER_SECOND, 2) + ', ' + KI('longest_life_sec', P^.LongestLifeSec) + ', ' +
    KI('first_bloods', P^.FirstBloodCount) + ', ' + KI('round_first_bloods', P^.RoundFirstBloodCount) + ', ' +
    KI('multi_kills', P^.PointmatchMode.Multi.MULTI_KILL) + ', ' +
    KI('knife_kills', P^.Weapons[WEP_KNIFE].Kills) + ', ' + KI('grenade_kills', P^.GrenadeKills) + ', ' +
    KF('traveled_km', P^.DistanceTraveledM / 1000, 2) + ', ' + KI('days_played', P^.DaysPlayed) + ', ' +
    KI('protection_days', P^.ProtectionDays) + ', ' + KI('season', P^.SeasonId) + ', ' + KI('season_points', P^.SeasonPoints) + ', ' +
    KB('registered', IsRegistered(P^)) + ', ' + KT('first_seen', P^.RegisterTime) + ', ' + KT('last_seen', P^.LastPlayedTime) + ', ');
  { added in 5.1 }
  Put(W, KS('league', E.LeagueLabel(Idx)) + ', ' + KF('mmr_ffa', P^.Mmr[RF_FFA].R, 0) + ', ' + KF('mmr_team', P^.Mmr[RF_TEAM].R, 0) + ', ' +
    KF('mmr_ctf', P^.Mmr[RF_CTF].R, 0) + ', ' + KI('through_cover_kills', P^.WallKills) + ', ' +
    KI('through_cover_shot_kills', P^.CoverShotKills) + ', ' +
    KI('base_defense_kills', P^.BaseDefenseKills) + ', ' + KI('base_attack_kills', P^.BaseAttackKills) + ', ' +
    KI('forced_suicides', P^.ForcedSelfkills) + ', ' + KI('suicides_under_fire', P^.SelfkillsUnderFire) + ', ' +
    KI('balance_moves', P^.BalanceMoves) + ', ' + KI('balance_volunteers', P^.BalanceVolunteers) + ', ' +
    KF('best_life_distance_m', P^.BestLifeDistanceM, 0) + ', ' + KF('healed_hp', P^.HealRegen + P^.HealKits, 0) + ', ' +
    KF('regen_hp', P^.HealRegen, 0) + ', ' + KI('heal_kits', P^.HealKitCount) + ', ' +
    KI('kits', KitsPickedUp(P^)) + ', ');
  { added in 5.6: read from the server directly ([Bridges]); the shots and hits by stance in the order
    stand, crouch, prone, air }
  Put(W, KI('collateral_kills', P^.CollateralKills) + ', ' + KI('back_kills', P^.BackKills) + ', ' +
    KI('back_deaths', P^.BackDeaths) + ', ' + KF('longest_headshot_m', P^.LongestHeadshotM, 1) + ', ' +
    KF('longest_bullet_flight_sec', P^.LongestFlightKill, 2) + ', ' + KF('longest_hit_m', P^.LongestHitM, 1) + ', ' +
    KF('avg_hit_dist_m', SafeDivD(P^.HitDistSum, P^.HitDistCount), 1) + ', ' +
    KF('avg_hit_flight_sec', SafeDivD(P^.HitAirTicks, P^.HitAirCount) / TICKS_PER_SECOND, 2) + ', ' +
    KF('avg_kill_flight_sec', SafeDivD(P^.KillAirTicks, P^.KillAirCount) / TICKS_PER_SECOND, 2) + ', "stance_shots": [');
  for k := 0 to 3 do
  begin
    if k > 0 then
      Put(W, ', ');
    Put(W, IntToStr(P^.StanceShots[k]));
  end;
  Put(W, '], "stance_hits": [');
  for k := 0 to 3 do
  begin
    if k > 0 then
      Put(W, ', ');
    Put(W, IntToStr(P^.StanceHits[k]));
  end;
  Put(W, '], ');
  { the kits picked up, by kind }
  Put(W, '"kit_pickups": {');
  for k := 0 to KIT_KINDS - 1 do
  begin
    if k > 0 then
      Put(W, ', ');
    Put(W, KI(KIT_KIND_NAMES[k], P^.KitPickups[k]));
  end;
  Put(W, '}, "achievements": [');
  for k := 0 to High(P^.Achievements) do
  begin
    if k > 0 then
      Put(W, ', ');
    Put(W, JsonStr(AchievementName(P^.Achievements[k].Id)));
  end;
  Put(W, '], "badges": [');
  for k := 0 to High(P^.Badges) do
  begin
    if k > 0 then
      Put(W, ', ');
    Put(W, '{' + KI('season', P^.Badges[k].SeasonId) + ', ' + KI('place', P^.Badges[k].Place) + '}');
  end;
  Put(W, '], "weapons": {');
  n := 0;
  for k := 0 to WSLOT_COUNT - 1 do
  begin
    WS := @P^.Weapons[k];
    if WS^.Kills + WS^.Deaths + WS^.Shots + WS^.Hits = 0 then
      Continue;
    if n > 0 then
      Put(W, ', ');
    Inc(n);
    Put(W, JsonStr(LowerCase(SlotShortName(k))) + ': {' + KI('kills', WS^.Kills) + ', ' + KI('deaths', WS^.Deaths) + ', ' +
      KI('shots', Max(WS^.Shots, WS^.Hits)) + ', ' + KI('hits', WS^.Hits) + ', ' + KI('headshots', WS^.Headshots) + ', ' +
      KF('damage', WS^.Damage, 0) + ', ' + KI('time_sec', WS^.TimeUsedSeconds) + ', ' +
      KI('reloads', WS^.Reloads) + ', ' + KI('reloads_finished', WS^.ReloadsDone) + ', ' +
      KI('killed_reloading', WS^.ReloadDeaths) + ', ' +
      KF('avg_reload_sec', SafeDivD(WS^.ReloadTicks, WS^.ReloadTimed) / TICKS_PER_SECOND, 2) + ', ' +
      KF('longest_hit_m', WS^.LongestHit, 1) + ', ' + KF('avg_hit_dist_m', SafeDivD(WS^.HitDistSum, WS^.HitDistCount), 1) +
      ', ' + KF('avg_hit_flight_sec', SafeDivD(WS^.HitAirTicks, WS^.HitAirCount) / TICKS_PER_SECOND, 2) + ', ' +
      KF('avg_kill_flight_sec', SafeDivD(WS^.KillAirTicks, WS^.KillAirCount) / TICKS_PER_SECOND, 2) + '}');
  end;
  Put(W, '}, "modes": {');
  n := 0;
  for k := 0 to High(P^.ModeStats) do
  begin
    MS := @P^.ModeStats[k];
    if MS^.Kills + MS^.Deaths + MS^.Wins + MS^.Loses = 0 then
      Continue;
    if n > 0 then
      Put(W, ', ');
    Inc(n);
    Put(W, JsonStr(LowerCase(ModeName(k))) + ': {' + KI('kills', MS^.Kills) + ', ' + KI('deaths', MS^.Deaths) + ', ' + KI('wins', MS^.Wins) + ', ' +
      KI('loses', MS^.Loses) + ', ' + KI('caps', MS^.Caps) + ', ' + KI('time_sec', MS^.TimePlayed) + '}');
  end;
  Put(W, '}}');
end;

{ players.json is built a part every timer run (StateLock is held only for that part) and handed to
  the IO thread part by part, so the file never stands whole in memory either; the IO thread puts it
  in place at once with the last part. total_players counts the accounts when it started: one
  removed while it is built is left out, one added comes with the next export. }
procedure FullStart(E: TZSEngine; Tag: LongInt);
var
  k, n: LongInt;
  Job: TStoreJob;
begin
  SetLength(FullIds, E.DB.ProfileCount);
  n := 0;
  for k := 0 to E.DB.ProfileCount - 1 do
    if E.DB.Valid(k) then
    begin
      FullIds[n] := E.DB.Profiles[k]^.ID;
      Inc(n);
    end;
  SetLength(FullIds, n);
  FullNext := 0;
  FullCount := 0;
  FullPath := ResolvePath(E.Cfg.FullExportPath);
  FullTag := Tag;
  Job := NewJob(sjWritePart, 0, FullTag);
  Job.Keep := PART_FIRST;
  Job.Path := FullPath;
  Job.Data := '{' + LineEnding + '  ' + KI('format', 2) + ',' + LineEnding + '  ' + KT('generated_at', Now) + ',' + LineEnding +
    '  ' + KI('total_players', n) + ',' + LineEnding + '  "players": [';
  E.IO.Enqueue(Job);
end;

procedure FullContinue(E: TZSEngine);
var
  W: TJson;
  T0: Int64;
  Idx: LongInt;
  Job: TStoreJob;
begin
  { a disk that does not keep up: the next part waits }
  if E.IO.PendingBytes >= SNAPSHOT_IO_HIGH_WATER then
    Exit;
  W.Buf := '';
  W.Len := 0;
  T0 := MicroNow;
  while (FullNext < Length(FullIds)) and (W.Len < FULL_PART_BYTES) and ((W.Len = 0) or (MicroNow - T0 < FULL_PART_MICROS)) do
  begin
    Idx := E.DB.IndexOfId(FullIds[FullNext]);
    Inc(FullNext);
    if not E.DB.Valid(Idx) then
      Continue;
    if FullCount > 0 then
      Put(W, ',');
    Inc(FullCount);
    Put(W, LineEnding + '    ');
    PlayerFull(E, W, Idx);
  end;
  Job := NewJob(sjWritePart, 0, FullTag);
  if FullNext >= Length(FullIds) then
  begin
    Put(W, LineEnding + '  ]' + LineEnding + '}' + LineEnding);
    Job.Keep := PART_LAST;
  end;
  Job.Path := FullPath;
  SetLength(W.Buf, W.Len);
  Job.Data := W.Buf;
  E.IO.Enqueue(Job);
  if Job.Keep = PART_LAST then
  begin
    FullNext := -1;
    FullIds := nil;
    { the mark behind the files says the asker has heard everything }
    if FullTag = TAG_EXPORT then
      E.IO.Enqueue(NewJob(sjNotify, 0, TAG_EXPORT_DONE));
  end;
end;

function PlayerJson(E: TZSEngine; Index: LongInt): AnsiString;
var
  W: TJson;
begin
  Result := '';
  if not E.DB.Valid(Index) then
    Exit;
  NameCodepage := E.Cfg.SourceCodepage;
  W.Buf := '';
  W.Len := 0;
  PlayerFull(E, W, Index);
  Result := Text(W);
end;

{ ---------------- webhooks ---------------- }

procedure WebhookExport(E: TZSEngine);
var
  W: TJson;
  r, Idx, n: LongInt;
  Sum: AnsiString;
begin
  W.Buf := '';
  W.Len := 0;
  Put(W, '{' + KS('event', 'export') + ', ' + KT('generated_at', Now) + ', ' + KI('players', E.DB.LiveProfiles) + ', ' +
    KI('online', E.HumansOnline) + ', "top": [');
  Sum := Format('**Ranking** - %d players, %d online now', [E.DB.LiveProfiles, E.HumansOnline]);
  n := 0;
  for r := 1 to Min(10, E.DB.Ranks[RANK_POINTS].Count) do
  begin
    Idx := E.DB.Ranks[RANK_POINTS].At(r);
    if not E.DB.Valid(Idx) then
      Continue;
    if n > 0 then
      Put(W, ', ');
    Inc(n);
    Put(W, '{' + KI('rank', r) + ', ' + KS('name', E.DB.Profiles[Idx]^.ActiveName) + ', ' + KI('points', E.DB.Profiles[Idx]^.Points) + '}');
    Sum := Sum + #10 + Format('%d. %s - %d pts', [r, DiscordName(E.DB.Profiles[Idx]^.ActiveName), E.DB.Profiles[Idx]^.Points]);
  end;
  Put(W, ']}');
  PostWebhook(E, Text(W), Sum);
end;

procedure WebhookMatch(E: TZSEngine);
var
  W: TJson;
  S, k, n, Best, T, Top: LongInt;
  Slots: array[0..MAX_PLAYERS - 1] of LongInt;
  Used: array[0..MAX_PLAYERS - 1] of Boolean;
  Winner, Sum, Score: AnsiString;
begin
  if not WebhookWanted(E, 'match') then
    Exit;
  NameCodepage := E.Cfg.SourceCodepage;
  n := 0;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human and (E.Live[S].Team <> TEAM_SPEC) then
    begin
      Slots[n] := S;
      Inc(n);
    end;
  Winner := '';
  if IsTeamStyle(E.Match.GameStyle) then
  begin
    Best := 1;
    for T := 2 to 4 do
      if E.Match.TeamScore[T] > E.Match.TeamScore[Best] then
        Best := T;
    Winner := TEAM_NAMES[Best];
    for T := 1 to 4 do
      if (T <> Best) and (E.Match.TeamScore[T] = E.Match.TeamScore[Best]) then
        Winner := 'draw';
  end;

  W.Buf := '';
  W.Len := 0;
  Put(W, '{' + KS('event', 'match') + ', ' + KT('ended_at', Now) + ', ' + KS('map', E.Match.MapName) + ', ' +
    KS('mode', ModeName(E.Match.GameStyle)) + ', ' + KI('duration_sec', Max(0, E.GameTick - E.Match.StartTick) div TICKS_PER_SECOND) + ', ');
  Sum := Format('**Match ended** - %s (%s, %d min)', [DiscordName(E.Match.MapName), ModeName(E.Match.GameStyle),
    Max(0, E.GameTick - E.Match.StartTick) div TICKS_PER_SECOND div 60]);
  if IsTeamStyle(E.Match.GameStyle) then
  begin
    Put(W, Format('"score": [%d, %d, %d, %d], ', [E.Match.TeamScore[1], E.Match.TeamScore[2], E.Match.TeamScore[3], E.Match.TeamScore[4]]) +
      KS('winner', Winner) + ', ');
    Score := '';
    for T := 1 to 4 do
      if (T <= 2) or (E.Match.TeamScore[T] > 0) then
      begin
        if Score <> '' then
          Score := Score + ', ';
        Score := Score + Format('%s %d', [TEAM_NAMES[T], E.Match.TeamScore[T]]);
      end;
    if Winner = 'draw' then
      Sum := Sum + #10 + 'Score: ' + Score + ' - draw'
    else
      Sum := Sum + #10 + 'Score: ' + Score + ' - ' + Winner + ' wins';
  end;
  Put(W, '"players": [');
  FillChar(Used, SizeOf(Used), 0);
  for k := 0 to Min(9, n - 1) do
  begin
    Top := -1;
    for S := 0 to n - 1 do
      if not Used[S] and ((Top < 0) or (E.Live[Slots[S]].MatchKills > E.Live[Slots[Top]].MatchKills)) then
        Top := S;
    Used[Top] := True;
    if k > 0 then
      Put(W, ', ');
    Put(W, '{' + KS('name', E.Live[Slots[Top]].Name) + ', ' + KS('team', TEAM_NAMES[EnsureRange(E.Live[Slots[Top]].Team, 0, 5)]) + ', ' +
      KI('kills', E.Live[Slots[Top]].MatchKills) + ', ' + KI('deaths', E.Live[Slots[Top]].MatchDeaths) + ', ' +
      KI('score', E.Live[Slots[Top]].MatchScore) + '}');
    Sum := Sum + #10 + Format('%d. %s - %d kills, %d deaths, score %d', [k + 1, DiscordName(E.Live[Slots[Top]].Name),
      E.Live[Slots[Top]].MatchKills, E.Live[Slots[Top]].MatchDeaths, E.Live[Slots[Top]].MatchScore]);
  end;
  Put(W, ']}');
  PostWebhook(E, Text(W), Sum);
end;

procedure WebhookSeason(E: TZSEngine; ArchiveIndex: LongInt);
var
  W: TJson;
  k: LongInt;
  SA: ^TSeasonArchive;
  Sum: AnsiString;
begin
  if not WebhookWanted(E, 'season') or (ArchiveIndex < 0) or (ArchiveIndex > High(E.DB.Seasons)) then
    Exit;
  NameCodepage := E.Cfg.SourceCodepage;
  SA := @E.DB.Seasons[ArchiveIndex];
  W.Buf := '';
  W.Len := 0;
  Put(W, '{' + KS('event', 'season') + ', ' + KI('id', SA^.Id) + ', ' + KT('start', SA^.StartDate) + ', ' + KT('end', SA^.EndDate) +
    ', "top": [');
  Sum := Format('**Season #%d finished** (%s - %s)', [SA^.Id, DayText(SA^.StartDate), DayText(SA^.EndDate)]);
  for k := 0 to Min(9, High(SA^.Entries)) do
  begin
    if k > 0 then
      Put(W, ', ');
    Put(W, '{' + KI('place', SA^.Entries[k].Place) + ', ' + KS('name', SA^.Entries[k].Name) + ', ' +
      KI('season_points', SA^.Entries[k].SeasonPoints) + ', ' + KI('points', SA^.Entries[k].Points) + ', ' +
      KI('kills', SA^.Entries[k].Kills) + ', ' + KI('deaths', SA^.Entries[k].Deaths) + '}');
    Sum := Sum + #10 + Format('%d. %s - %d season points, %d kills', [SA^.Entries[k].Place, DiscordName(SA^.Entries[k].Name),
      SA^.Entries[k].SeasonPoints, SA^.Entries[k].Kills]);
  end;
  Sum := Sum + #10 + Format('Full list in game: !topseason %d', [SA^.Id]);
  Put(W, ']}');
  PostWebhook(E, Text(W), Sum);
end;

procedure ExportTick(E: TZSEngine; NowMs: Int64);
var
  Tag: LongInt;
begin
  NameCodepage := E.Cfg.SourceCodepage;
  if StateOwner <> E then
  begin
    { a new engine: start the timers now and do not report the loaded peak as new }
    StateOwner := E;
    LastExportMs := NowMs;
    PeakPosted := E.DB.Server.PeakOnlineCount;
    PeakSeen := PeakPosted;
    PeakChangedMs := NowMs;
    { a players.json the engine before was building stays unfinished (its .part file) }
    FullNext := -1;
    FullIds := nil;
  end;
  if not E.IsReady then
    Exit;

  { a disk that does not keep up would collect a full copy of the files every interval: the
    timed export waits until the writes before it are done (one asked for is written anyway) }
  if E.ExportRequested or ((NowMs - LastExportMs >= Int64(Max(1, E.Cfg.ExportIntervalMinutes)) * 60000) and
     ((E.IO = nil) or (E.IO.PendingBytes < SNAPSHOT_IO_HIGH_WATER))) then
  begin
    { an export an admin asked for reports every file it wrote }
    if E.ExportRequested then
      Tag := TAG_EXPORT
    else
      Tag := 0;
    E.ExportRequested := False;
    LastExportMs := NowMs;
    if E.Cfg.JSONExportEnabled then
      WriteText(E, E.Cfg.JSONExportPath, StatsJson(E), Tag);
    { players.json: a new one, unless one is still being built - that one carries the asker's mark;
      the mark behind the files says the asker has heard everything }
    if E.Cfg.FullExportEnabled and (E.IO <> nil) and (Trim(E.Cfg.FullExportPath) <> '') then
    begin
      if FullNext < 0 then
        FullStart(E, Tag)
      else if Tag <> 0 then
        FullTag := Tag;
    end
    else if (Tag = TAG_EXPORT) and (E.IO <> nil) then
      E.IO.Enqueue(NewJob(sjNotify, 0, TAG_EXPORT_DONE));
    if WebhookWanted(E, 'export') then
      WebhookExport(E);
  end;
  if (FullNext >= 0) and (E.IO <> nil) then
    FullContinue(E);

  if E.DB.Server.PeakOnlineCount <> PeakSeen then
  begin
    PeakSeen := E.DB.Server.PeakOnlineCount;
    PeakChangedMs := NowMs;
  end;
  if (PeakSeen > PeakPosted) and (NowMs - PeakChangedMs >= RECORD_SETTLE_MS) then
  begin
    PeakPosted := PeakSeen;
    if WebhookWanted(E, 'record') then
      PostWebhook(E, '{' + KS('event', 'record') + ', ' + KS('type', 'peak_online') + ', ' + KI('players', PeakSeen) + ', ' +
        KT('date', E.DB.Server.PeakOnlineDate) + '}',
        Format('**New server record:** %d players online at once (%s)', [PeakSeen, DayText(E.DB.Server.PeakOnlineDate)]));
  end;
end;

end.
