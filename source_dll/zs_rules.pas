unit zs_rules;

{ Rules that move points or change account-wide state:
  - kill points (ELO) with diminishing returns on an inactive victim, capture point pools
  - day, week, month, season and game mode counters
  - protection days: a day with enough play time and kills/deaths earns one day, an inactive
    day uses one up before any points are taken
  - the daily balance: inactive accounts pay into a pool shared by active players; accounts
    never drop below the floor (BalanceFloorPoints)
  - check points: keeps the total close to accounts x StartingPoints by paying the deficit to
    active players or taking a surplus back from inactive accounts, a little each day
  - seasons with an archived top list and badges, achievements, match ratings and tiers }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, zs_types, zs_util, zs_config, zs_fields, zs_db, zs_rating, zs_live;

const
  PERIOD_DAY = 0;
  PERIOD_WEEK = 1;
  PERIOD_MONTH = 2;
  CHECKPOINTS_MAX_DAILY = 25;
  CHECKPOINTS_TAKE_DAILY = 50;
  ACH_COUNT = 50;

type
  TAchievementDef = record
    Id: LongInt;
    Name: AnsiString;
    Info: AnsiString;
  end;

  TBalanceReport = record
    Accounts: LongInt;
    Active: LongInt;
    Inactive: LongInt;
    Recipients: LongInt;
    ProtectionUsed: LongInt;
    Collected: Int64;
    Paid: Int64;
    CheckPaid: Int64;
    CheckTaken: Int64;
    CheckWaiting: Int64;    { a surplus nobody could pay: every inactive account is protected }
    CheckForced: Int64;     { of the surplus, taken after CheckPointsMaxWaitDays from the least active accounts }
    CheckWaitDays: LongInt; { how long the surplus has been waiting }
    Total: Int64;
    Expected: Int64;
    MatrixPruned: LongInt;  { player-on-map records removed ([Matrix] MatrixPruneDays) }
  end;

var
  AchievementDefs: array[1..ACH_COUNT] of TAchievementDef;

function RatingSystemOf(const Cfg: TZSConfig): LongInt;
function FamilyFor(const Cfg: TZSConfig; GameStyle: LongInt): LongInt;

procedure RollPeriods(var P: TPlayerProfile; T: TDateTime);
procedure RollSeason(var P: TPlayerProfile; SeasonId: LongInt);
function AddPoints(DB: TStatsDB; Index, Delta, Floor: LongInt): LongInt;
procedure AddActivity(DB: TStatsDB; Index, GameStyle, Kills, Deaths, Caps, Wins, Loses, Draws, Headshots: LongInt;
  Seconds: Int64);
procedure NoteProtectionActivity(DB: TStatsDB; Index: LongInt; const Cfg: TZSConfig);

function InactiveMultiplier(const Cfg: TZSConfig; PreviousKills: LongInt): LongInt;
function KillPoints(const Cfg: TZSConfig; KillerPoints, VictimPoints: LongInt; VictimInactive: Boolean;
  PreviousInactiveKills: LongInt): LongInt;
procedure CtfCapPool(DB: TStatsDB; const Cfg: TZSConfig; Capper: LongInt; const Enemies, Teammates: array of LongInt;
  out CapperGain: LongInt; out Gains, Losses: TIntArray);
function SuspiciousKill(var Pair: TPairState; Tick, VictimKillsNow, Humans: LongInt; const Cfg: TZSConfig): Boolean;

function IsActiveAccount(const P: TPlayerProfile; NowT: Double; Days: LongInt): Boolean;
function Distribute(DB: TStatsDB; var Recipients: TIntArray; Pool: Int64; Cap: LongInt): Int64;
procedure DailyMaintenance(DB: TStatsDB; const Cfg: TZSConfig; out Rep: TBalanceReport);

function SeasonDue(DB: TStatsDB; const Cfg: TZSConfig): Boolean;
function SeasonEndFor(const Cfg: TZSConfig; Start: TDateTime): TDateTime;
function ArchiveSeason(DB: TStatsDB; const Cfg: TZSConfig): LongInt;
procedure StartSeason(DB: TStatsDB; const Cfg: TZSConfig);

function HasAchievement(const P: TPlayerProfile; Id: LongInt): Boolean;
function CheckAchievements(DB: TStatsDB; Index, Rank: LongInt): TIntArray;
function AchievementName(Id: LongInt): AnsiString;
{ The achievements Rampage and Godlike are the kill streak levels of the same name in [Sprees]:
  reached at the kills of that level (10 and 25 when there is no such level), so a player who hears
  "RAMPAGE!" has the achievement of that name as well. Called whenever the settings are read. }
procedure SetStreakAchievements(const Cfg: TZSConfig);

procedure RateFFA(DB: TStatsDB; const Cfg: TZSConfig; Family: LongInt; const Players, Scores: array of LongInt);
procedure RateTeams(DB: TStatsDB; const Cfg: TZSConfig; Family: LongInt; const Players, Teams: array of LongInt;
  const TeamScores: array of LongInt); overload;
{ Partial play: an account may appear once per team it played for, Weights[i] being the share of the
  match it spent there. Each part is rated against that team's result and counts by its share, and
  a team's strength counts its players by the same shares. }
procedure RateTeams(DB: TStatsDB; const Cfg: TZSConfig; Family: LongInt; const Players, Teams: array of LongInt;
  const Weights: array of Double; const TeamScores: array of LongInt); overload;
procedure GlickoCatchUp(var S: TGlickoState; NowT: Double);

function PerformanceRating(const P: TPlayerProfile; GameStyle: LongInt; Survival, FriendlyFire: Boolean;
  const Mode: AnsiString): Double;
function TierIndex(const Cfg: TZSConfig; const P: TPlayerProfile; Perf: Double; Family, RatingSystem: LongInt): LongInt;
{ the skill index of [Ranking] RatingMode = skill, also usable on its own }
function SkillRating(const P: TPlayerProfile; GameStyle: LongInt; Survival, FriendlyFire: Boolean): Double;
{ the mode family an account has played most rated matches in }
function MainFamily(const P: TPlayerProfile): LongInt;
{ matches that count for league placement: MMR matches of the main family, or all matches }
function LeagueGames(const Cfg: TZSConfig; const P: TPlayerProfile): LongInt;
{ sorts the placed accounts into leagues and divisions; called once a day }
procedure UpdateLeagues(DB: TStatsDB; const Cfg: TZSConfig);

implementation

function RatingSystemOf(const Cfg: TZSConfig): LongInt;
var
  S: AnsiString;
begin
  S := LowerCase(Trim(Cfg.RankingSystem));
  if (S = 'glicko2') or (S = 'glicko-2') or (S = 'glicko') then
    Result := RS_GLICKO2
  else if S = 'openskill' then
    Result := RS_OPENSKILL
  else if S = 'mmr' then
    Result := RS_MMR
  else
    Result := RS_ELO;
end;

function FamilyFor(const Cfg: TZSConfig; GameStyle: LongInt): LongInt;
var
  S: AnsiString;
begin
  S := LowerCase(Trim(Cfg.RankingFamily));
  if S = 'ffa' then
    Result := RF_FFA
  else if S = 'team' then
    Result := RF_TEAM
  else if S = 'ctf' then
    Result := RF_CTF
  else
    Result := RatingFamilyOf(GameStyle);
end;

{ ---------------- counters ---------------- }

procedure RollPeriods(var P: TPlayerProfile; T: TDateTime);
var
  Keys: array[0..2] of LongInt;
  k: LongInt;
begin
  Keys[PERIOD_DAY] := DayKey(T);
  Keys[PERIOD_WEEK] := WeekKey(T);
  Keys[PERIOD_MONTH] := MonthKey(T);
  for k := 0 to 2 do
    if P.Period[k].Key <> Keys[k] then
    begin
      FillChar(P.Period[k], SizeOf(TPeriodStats), 0);
      P.Period[k].Key := Keys[k];
    end;
end;

procedure RollSeason(var P: TPlayerProfile; SeasonId: LongInt);
begin
  if P.SeasonId = SeasonId then
    Exit;
  P.SeasonId := SeasonId;
  P.SeasonPoints := 0;
  P.SeasonKills := 0;
  P.SeasonDeaths := 0;
  P.SeasonCaps := 0;
  P.SeasonWins := 0;
  P.SeasonTime := 0;
end;

function AddPoints(DB: TStatsDB; Index, Delta, Floor: LongInt): LongInt;
var
  P: PPlayerProfile;
  Old, New: Int64;
  k: LongInt;
begin
  Result := 0;
  if not DB.Valid(Index) or (Delta = 0) then
    Exit;
  P := DB.Profiles[Index];
  Old := P^.Points;
  New := Old + Delta;
  { losses stop at the floor; an account already below it loses nothing more }
  if (Delta < 0) and (New < Floor) then
    New := Min(Old, Int64(Floor));
  { the sum is taken in 64 bits: at the end of the range the points stop instead of wrapping round
    to the other end }
  New := EnsureRange(New, Int64(Low(LongInt)), Int64(High(LongInt)));
  P^.Points := New;
  Result := New - Old;
  if Result = 0 then
    Exit;
  RollPeriods(P^, DB.NowValue);
  RollSeason(P^, DB.Server.SeasonId);
  for k := 0 to 2 do
    Inc(P^.Period[k].PointsDelta, Result);
  Inc(P^.SeasonPoints, Result);
  DB.Touch(Index);
  DB.RefreshRanks(Index);
end;

procedure AddActivity(DB: TStatsDB; Index, GameStyle, Kills, Deaths, Caps, Wins, Loses, Draws, Headshots: LongInt;
  Seconds: Int64);
var
  P: PPlayerProfile;
  k, Today: LongInt;
begin
  if not DB.Valid(Index) then
    Exit;
  P := DB.Profiles[Index];
  RollPeriods(P^, DB.NowValue);
  RollSeason(P^, DB.Server.SeasonId);
  for k := 0 to 2 do
  begin
    Inc(P^.Period[k].Kills, Kills);
    Inc(P^.Period[k].Deaths, Deaths);
    Inc(P^.Period[k].Caps, Caps);
    Inc(P^.Period[k].Wins, Wins);
    Inc(P^.Period[k].Headshots, Headshots);
    Inc(P^.Period[k].TimePlayed, Seconds);
  end;
  Inc(P^.SeasonKills, Kills);
  Inc(P^.SeasonDeaths, Deaths);
  Inc(P^.SeasonCaps, Caps);
  Inc(P^.SeasonWins, Wins);
  Inc(P^.SeasonTime, Seconds);
  if (GameStyle >= 0) and (GameStyle <= 6) then
  begin
    Inc(P^.ModeStats[GameStyle].Kills, Kills);
    Inc(P^.ModeStats[GameStyle].Deaths, Deaths);
    Inc(P^.ModeStats[GameStyle].Caps, Caps);
    Inc(P^.ModeStats[GameStyle].Wins, Wins);
    Inc(P^.ModeStats[GameStyle].Loses, Loses);
    Inc(P^.ModeStats[GameStyle].Draws, Draws);
    Inc(P^.ModeStats[GameStyle].TimePlayed, Seconds);
  end;
  if Seconds > 0 then
  begin
    Today := DayKey(DB.NowValue);
    if P^.LastDayKey <> Today then
    begin
      P^.LastDayKey := Today;
      Inc(P^.DaysPlayed);
    end;
  end;
  DB.Touch(Index);
  { the season list only includes players who played this season }
  if (Seconds > 0) or (Kills > 0) or (Deaths > 0) then
    DB.RefreshRanks(Index);
end;

procedure NoteProtectionActivity(DB: TStatsDB; Index: LongInt; const Cfg: TZSConfig);
var
  P: PPlayerProfile;
  Today: LongInt;
begin
  if not DB.Valid(Index) or not SameText(Trim(Cfg.InactivityMode), 'protection') then
    Exit;
  P := DB.Profiles[Index];
  Today := DayKey(DB.NowValue);
  if P^.ActivityForProtectDays = Today then
    Exit;
  RollPeriods(P^, DB.NowValue);
  if (P^.Period[PERIOD_DAY].TimePlayed >= Cfg.ProtectSessionSeconds) and
     (P^.Period[PERIOD_DAY].Kills + P^.Period[PERIOD_DAY].Deaths >= Cfg.ProtectEventsPerDay) then
  begin
    { ActivityForProtectDays holds the last day that earned protection }
    P^.ActivityForProtectDays := Today;
    if P^.ProtectionDays < Cfg.ProtectMaxDays then
      Inc(P^.ProtectionDays);
    DB.Touch(Index);
  end;
end;

{ ---------------- combat points ---------------- }

function InactiveMultiplier(const Cfg: TZSConfig; PreviousKills: LongInt): LongInt;
begin
  if Length(Cfg.InactiveVictimMultipliers) = 0 then
    Exit(100);
  Result := Cfg.InactiveVictimMultipliers[Min(Max(PreviousKills, 0), High(Cfg.InactiveVictimMultipliers))];
  Result := EnsureRange(Result, 0, 100);
end;

function KillPoints(const Cfg: TZSConfig; KillerPoints, VictimPoints: LongInt; VictimInactive: Boolean;
  PreviousInactiveKills: LongInt): LongInt;
begin
  Result := EloKillPoints(KillerPoints, VictimPoints, Cfg.MaxPointGive, Cfg.MinimumPointDivider, Cfg.Divider,
    Cfg.PowerDivider, Cfg.MinPointGive);
  if VictimInactive then
    Result := Result * InactiveMultiplier(Cfg, PreviousInactiveKills) div 100;
end;

procedure CtfCapPool(DB: TStatsDB; const Cfg: TZSConfig; Capper: LongInt; const Enemies, Teammates: array of LongInt;
  out CapperGain: LongInt; out Gains, Losses: TIntArray);
var
  i, PerEnemy, Share, Rest, Each, Pool: LongInt;
begin
  SetLength(Gains, Length(Teammates));
  SetLength(Losses, Length(Enemies));
  CapperGain := 0;
  Pool := 0;
  PerEnemy := Cfg.CapPoolPoints;
  if PerEnemy > 0 then
    for i := 0 to High(Enemies) do
    begin
      Losses[i] := -AddPoints(DB, Enemies[i], -PerEnemy, Cfg.MinimumPoints);
      Inc(Pool, Losses[i]);
    end;
  if Pool <= 0 then
  begin
    CapperGain := AddPoints(DB, Capper, Cfg.FlagScoreFallbackPoints, Cfg.MinimumPoints);
    Exit;
  end;
  Share := EnsureRange(Cfg.CapWinnerSharePct, 0, 100);
  CapperGain := Share * Pool div 100;
  Rest := Pool - CapperGain;
  if Length(Teammates) > 0 then
  begin
    Each := Rest div Length(Teammates);
    for i := 0 to High(Teammates) do
      Gains[i] := AddPoints(DB, Teammates[i], Each, Cfg.MinimumPoints);
    Inc(CapperGain, Rest - Each * Length(Teammates));
  end
  else
    CapperGain := Pool;
  CapperGain := AddPoints(DB, Capper, CapperGain, Cfg.MinimumPoints);
end;

function SuspiciousKill(var Pair: TPairState; Tick, VictimKillsNow, Humans: LongInt; const Cfg: TZSConfig): Boolean;
var
  Window: LongInt;
begin
  Result := False;
  if not Cfg.SuspiciousEnabled then
    Exit;
  Window := Max(1, Cfg.SuspiciousWindowMinutes) * 60 * TICKS_PER_SECOND;
  if (Pair.WinStartTick = 0) or (Tick - Pair.WinStartTick > Window) then
  begin
    Pair.WinStartTick := Tick;
    Pair.WinKills := 0;
    Pair.WinVictimKills0 := VictimKillsNow;
    Pair.WinLogged := False;
  end;
  Inc(Pair.WinKills);
  Result := (Humans <= Cfg.SuspiciousMaxHumans) and not Pair.WinLogged and
    (Pair.WinKills >= Cfg.SuspiciousKills) and (VictimKillsNow - Pair.WinVictimKills0 <= Cfg.SuspiciousVictimMaxKills);
  if Result then
    Pair.WinLogged := True;
end;

{ ---------------- daily balance ---------------- }

function IsActiveAccount(const P: TPlayerProfile; NowT: Double; Days: LongInt): Boolean;
begin
  Result := (P.LastPlayedTime > 0) and (NowT - P.LastPlayedTime <= Days);
end;

procedure SortByPoints(DB: TStatsDB; var A: TIntArray; L, R: LongInt);
var
  i, j, T, Pivot: LongInt;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := DB.Profiles[A[(L + R) shr 1]]^.Points;
    repeat
      while DB.Profiles[A[i]]^.Points < Pivot do
        Inc(i);
      while DB.Profiles[A[j]]^.Points > Pivot do
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
    if j - L < R - i then
    begin
      SortByPoints(DB, A, L, j);
      L := i;
    end
    else
    begin
      SortByPoints(DB, A, i, R);
      R := j;
    end;
  end;
end;

function Distribute(DB: TStatsDB; var Recipients: TIntArray; Pool: Int64; Cap: LongInt): Int64;
var
  i, n, Each: LongInt;
  Rem: Int64;
begin
  Result := 0;
  n := Length(Recipients);
  if (Pool <= 0) or (n = 0) or (Cap <= 0) then
    Exit;
  SortByPoints(DB, Recipients, 0, n - 1);
  Each := Min(Pool div n, Cap);
  if Each > 0 then
    for i := 0 to n - 1 do
      Inc(Result, AddPoints(DB, Recipients[i], Each, 0));
  { what does not divide evenly goes one point each to the poorest recipients }
  Rem := Pool - Result;
  if (Rem > 0) and (Each < Cap) then
    for i := 0 to Min(Rem, n) - 1 do
      Inc(Result, AddPoints(DB, Recipients[i], 1, 0));
end;

{ the accounts that played longest ago first }
procedure SortByLastPlayed(DB: TStatsDB; var A: TIntArray; L, R: LongInt);
var
  i, j, T: LongInt;
  Pivot: Double;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := DB.Profiles[A[(L + R) shr 1]]^.LastPlayedTime;
    repeat
      while DB.Profiles[A[i]]^.LastPlayedTime < Pivot do
        Inc(i);
      while DB.Profiles[A[j]]^.LastPlayedTime > Pivot do
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
    if j - L < R - i then
    begin
      SortByLastPlayed(DB, A, L, j);
      L := i;
    end
    else
    begin
      SortByLastPlayed(DB, A, i, R);
      R := j;
    end;
  end;
end;

procedure DailyMaintenance(DB: TStatsDB; const Cfg: TZSConfig; out Rep: TBalanceReport);
var
  i, k, n, Rank, Loss: LongInt;
  NowT: Double;
  Recipients: TIntArray;
  P: PPlayerProfile;
  Mode: AnsiString;
  Excess, Take, Part: Int64;
  UsedDay: array of Boolean;
  Taken: array of Int64;
begin
  FillChar(Rep, SizeOf(Rep), 0);
  NowT := DB.NowValue;
  Mode := LowerCase(Trim(Cfg.InactivityMode));
  Rep.Accounts := DB.LiveProfiles;
  { accounts that used a protection day today, the last one included: protected all day }
  UsedDay := nil;
  SetLength(UsedDay, DB.ProfileCount);

  n := 0;
  SetLength(Recipients, DB.ProfileCount);
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if P = nil then
      Continue;
    if IsActiveAccount(P^, NowT, Cfg.InactivityDays) then
    begin
      Inc(Rep.Active);
      if P^.Points < Cfg.BalanceRecipientMaxPoints then
      begin
        Recipients[n] := i;
        Inc(n);
      end;
    end
    else if P^.LastPlayedTime > 0 then
      Inc(Rep.Inactive);
  end;
  SetLength(Recipients, n);
  Rep.Recipients := n;

  if ((Mode = 'protection') or (Mode = 'decay')) and (Rep.Accounts >= Cfg.BalanceMinAccounts) and
     (n >= Cfg.BalanceMinRecipients) then
  begin
    for i := 0 to DB.ProfileCount - 1 do
    begin
      P := DB.Profiles[i];
      if (P = nil) or (P^.LastPlayedTime <= 0) or IsActiveAccount(P^, NowT, Cfg.InactivityDays) then
        Continue;
      if Mode = 'protection' then
      begin
        { a protection day is used up only when it spares points: at or below the floor the day
          would take nothing anyway, and the account keeps its days }
        if (P^.ProtectionDays > 0) and (P^.Points > Cfg.BalanceFloorPoints) then
        begin
          Dec(P^.ProtectionDays);
          UsedDay[i] := True;
          DB.Touch(i);
          Inc(Rep.ProtectionUsed);
          Continue;
        end;
        Rank := DB.Ranks[RANK_POINTS].RankOf(i);
        if (Rank > 0) and (Rank <= 15) then
          Loss := 80 + (15 - Rank) * 10
        else
          Loss := 35;
      end
      else
        Loss := Max(1, (P^.Points - Cfg.BalanceFloorPoints) * 2 div 100);
      Loss := Min(Loss, P^.Points - Cfg.BalanceFloorPoints);
      if Loss > 0 then
        Inc(Rep.Collected, -AddPoints(DB, i, -Loss, Cfg.BalanceFloorPoints));
    end;
    Rep.Paid := Distribute(DB, Recipients, Rep.Collected, Cfg.BalanceMaxPayout);
  end;

  if Cfg.CheckPointsEnabled then
  begin
    Rep.Total := 0;
    for i := 0 to DB.ProfileCount - 1 do
      if DB.Profiles[i] <> nil then
        Inc(Rep.Total, DB.Profiles[i]^.Points);
    Rep.Expected := Int64(Rep.Accounts) * Cfg.StartingPoints;
    if Rep.Total < Rep.Expected then
    begin
      n := 0;
      SetLength(Recipients, DB.ProfileCount);
      for i := 0 to DB.ProfileCount - 1 do
        if (DB.Profiles[i] <> nil) and IsActiveAccount(DB.Profiles[i]^, NowT, Cfg.CheckPointsActiveDays) then
        begin
          Recipients[n] := i;
          Inc(n);
        end;
      SetLength(Recipients, n);
      Rep.CheckPaid := Distribute(DB, Recipients, Rep.Expected - Rep.Total, CHECKPOINTS_MAX_DAILY);
    end
    else if Rep.Total > Rep.Expected then
    begin
      { A surplus is taken back from inactive accounts above the floor, proportionally. An
        account with protection days - or one that used its last one today - is protected from
        this as well; when every inactive account is, the surplus waits (it is small, and
        protection runs out). }
      Excess := 0;
      n := 0;
      SetLength(Recipients, DB.ProfileCount);
      for i := 0 to DB.ProfileCount - 1 do
      begin
        P := DB.Profiles[i];
        if (P <> nil) and not IsActiveAccount(P^, NowT, Cfg.InactivityDays) and (P^.Points > Cfg.BalanceFloorPoints) and
           not ((Mode = 'protection') and ((P^.ProtectionDays > 0) or UsedDay[i])) then
        begin
          Inc(Excess, P^.Points - Cfg.BalanceFloorPoints);
          Recipients[n] := i;
          Inc(n);
        end;
      end;
      SetLength(Recipients, n);
      Take := Min(Rep.Total - Rep.Expected, Excess);
      if Take > 0 then
      begin
        Taken := nil;
        SetLength(Taken, DB.ProfileCount);
        for k := 0 to n - 1 do
        begin
          i := Recipients[k];
          Part := Min((Int64(DB.Profiles[i]^.Points - Cfg.BalanceFloorPoints) * Take) div Excess, CHECKPOINTS_TAKE_DAILY);
          if Part > 0 then
          begin
            Taken[i] := -AddPoints(DB, i, -Part, Cfg.BalanceFloorPoints);
            Inc(Rep.CheckTaken, Taken[i]);
          end;
        end;
        { what does not divide evenly - all of it when the surplus is small next to the accounts -
          comes a point each from the richest of them }
        if Rep.CheckTaken < Take then
        begin
          SortByPoints(DB, Recipients, 0, n - 1);
          for k := n - 1 downto 0 do
          begin
            if Rep.CheckTaken >= Take then
              Break;
            i := Recipients[k];
            if (Taken[i] < CHECKPOINTS_TAKE_DAILY) and (DB.Profiles[i]^.Points > Cfg.BalanceFloorPoints) then
            begin
              Part := -AddPoints(DB, i, -1, Cfg.BalanceFloorPoints);
              Inc(Taken[i], Part);
              Inc(Rep.CheckTaken, Part);
            end;
          end;
        end;
      end;
      Rep.CheckWaiting := Max(0, Rep.Total - Rep.Expected - Rep.CheckTaken);
      { a surplus that waited CheckPointsMaxWaitDays is taken anyway, protection or not, from the
        accounts that have not played for the longest time - a point at a time up to the daily cap
        of each, the least active first }
      if Rep.CheckWaiting > 0 then
      begin
        if DB.Server.CheckWaitSince <= 0 then
        begin
          DB.Server.CheckWaitSince := NowT;
          DB.TouchServer;
        end;
        { whole days, so a balance that runs a second earlier than yesterday counts the day all the same }
        Rep.CheckWaitDays := Trunc(NowT) - Trunc(DB.Server.CheckWaitSince);
        if (Cfg.CheckPointsMaxWaitDays > 0) and (Rep.CheckWaitDays >= Cfg.CheckPointsMaxWaitDays) then
        begin
          if Taken = nil then
            SetLength(Taken, DB.ProfileCount);
          n := 0;
          SetLength(Recipients, DB.ProfileCount);
          for i := 0 to DB.ProfileCount - 1 do
          begin
            P := DB.Profiles[i];
            if (P <> nil) and (P^.Points > Cfg.BalanceFloorPoints) then
            begin
              Recipients[n] := i;
              Inc(n);
            end;
          end;
          SetLength(Recipients, n);
          if n > 1 then
            SortByLastPlayed(DB, Recipients, 0, n - 1);
          for k := 0 to n - 1 do
          begin
            if Rep.CheckWaiting <= 0 then
              Break;
            i := Recipients[k];
            Part := Min(Min(CHECKPOINTS_TAKE_DAILY - Taken[i], Int64(DB.Profiles[i]^.Points - Cfg.BalanceFloorPoints)),
              Rep.CheckWaiting);
            if Part <= 0 then
              Continue;
            Part := -AddPoints(DB, i, -Part, Cfg.BalanceFloorPoints);
            Inc(Taken[i], Part);
            Inc(Rep.CheckForced, Part);
            Dec(Rep.CheckWaiting, Part);
          end;
        end;
      end;
    end;
    if (Rep.CheckWaiting <= 0) and (DB.Server.CheckWaitSince > 0) then
    begin
      DB.Server.CheckWaitSince := 0;
      DB.TouchServer;
    end;
  end;

  { [Matrix]: the records of every map of accounts that have not played for MatrixPruneDays go }
  if Cfg.MatrixPruneDays > 0 then
    Rep.MatrixPruned := DB.PrunePlayerMaps(Cfg.MatrixPruneDays);
end;

{ ---------------- leagues ---------------- }

type
  TLeagueRow = record
    Idx: LongInt;
    Value: Double;
  end;
  TLeagueRows = array of TLeagueRow;

procedure SortLeague(var A: TLeagueRows; L, R: LongInt);
var
  i, j: LongInt;
  Pivot: Double;
  T: TLeagueRow;
begin
  while L < R do
  begin
    i := L;
    j := R;
    Pivot := A[(L + R) div 2].Value;
    while i <= j do
    begin
      while A[i].Value > Pivot do Inc(i);
      while A[j].Value < Pivot do Dec(j);
      if i <= j then
      begin
        T := A[i];
        A[i] := A[j];
        A[j] := T;
        Inc(i);
        Dec(j);
      end;
    end;
    if j - L < R - i then
    begin
      if L < j then SortLeague(A, L, j);
      L := i;
    end
    else
    begin
      if i < R then SortLeague(A, i, R);
      R := j;
    end;
  end;
end;

{ next whole number in a list like "2,8,20", 0 when the list is used up }
function NextNumber(const S: AnsiString; var Pos: LongInt): LongInt;
var
  Start: LongInt;
begin
  while (Pos <= Length(S)) and not (S[Pos] in ['0'..'9']) do
    Inc(Pos);
  Start := Pos;
  while (Pos <= Length(S)) and (S[Pos] in ['0'..'9']) do
    Inc(Pos);
  if Pos > Start then
    Result := StrToIntDef(Copy(S, Start, Pos - Start), 0)
  else
    Result := 0;
end;

function MainFamily(const P: TPlayerProfile): LongInt;
var
  f: LongInt;
begin
  Result := 0;
  for f := 1 to RF_COUNT - 1 do
    if P.Mmr[f].Games > P.Mmr[Result].Games then
      Result := f;
end;

function LeagueGames(const Cfg: TZSConfig; const P: TPlayerProfile): LongInt;
begin
  if SameText(Trim(Cfg.LeagueSource), 'rating') then
    Result := P.Wins + P.Loses
  else
    Result := P.Mmr[MainFamily(P)].Games;
end;

{ Leagues and the season archive do not depend on the map that is being played: the Rating index
  of an account is taken for a mode of the family it plays most (FFA -> Deathmatch,
  Team -> Teammatch, CTF -> CTF). }
function MainFamilyRating(const P: TPlayerProfile; const Cfg: TZSConfig): Double;
const
  FAMILY_STYLE: array[0..RF_COUNT - 1] of LongInt = (GS_DM, GS_TM, GS_CTF);
begin
  Result := PerformanceRating(P, FAMILY_STYLE[MainFamily(P)], False, False, Cfg.RatingMode);
end;

procedure UpdateLeagues(DB: TStatsDB; const Cfg: TZSConfig);
var
  Rows: TLeagueRows;
  Cuts: array[0..MAX_TIERS - 1] of LongInt;
  i, k, n, Tiers, Pos, Prev, V, Start, Stop, Span, Divi, NewTier, Promille: LongInt;
  P: PPlayerProfile;
begin
  Tiers := Cfg.RankTierCount;
  if DB.ProfileCount <= 0 then
    Exit;
  { the leagues are the tiers: without tiers there are none, and what an earlier [Ranks] left in the
    accounts goes }
  if Tiers <= 0 then
  begin
    for i := 0 to DB.ProfileCount - 1 do
    begin
      P := DB.Profiles[i];
      if (P <> nil) and ((P^.LeagueTier <> 0) or (P^.LeagueDivision <> 0) or (P^.LeaguePromille <> 0)) then
      begin
        P^.LeagueTier := 0;
        P^.LeagueDivision := 0;
        P^.LeaguePromille := 0;
        DB.Touch(i);
      end;
    end;
    Exit;
  end;
  SetLength(Rows, DB.ProfileCount);
  n := 0;
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if P = nil then
      Continue;
    { too few matches: the account is still in placement }
    if LeagueGames(Cfg, P^) < Cfg.LeaguePlacementMatches then
    begin
      if P^.LeagueTier <> 0 then
      begin
        P^.LeagueTier := 0;
        P^.LeagueDivision := 0;
        P^.LeaguePromille := 0;
        DB.Touch(i);
      end;
      Continue;
    end;
    Rows[n].Idx := i;
    { Heroes of the Storm orders its leagues by MMR; the Rating index is the other choice }
    if SameText(Trim(Cfg.LeagueSource), 'rating') then
      Rows[n].Value := MainFamilyRating(P^, Cfg)
    else
      Rows[n].Value := P^.Mmr[MainFamily(P^)].R;
    Inc(n);
  end;
  SetLength(Rows, n);
  if n = 0 then
    Exit;
  SortLeague(Rows, 0, n - 1);

  { "the best 2 %, then up to 8 %, ..."; the last league takes whatever is left }
  Pos := 1;
  Prev := 0;
  for k := 0 to Tiers - 1 do
  begin
    V := NextNumber(Cfg.LeaguePercents, Pos);
    if (k = Tiers - 1) or (V <= 0) then
      V := 100;
    Cuts[k] := EnsureRange(V, Prev, 100);
    Prev := Cuts[k];
  end;

  Start := 0;
  for k := 0 to Tiers - 1 do
  begin
    Stop := Min(n, Round(n * Cuts[k] / 100.0));
    if k = Tiers - 1 then
      Stop := n;
    Span := Stop - Start;
    NewTier := k + 1;
    for i := Start to Stop - 1 do
    begin
      P := DB.Profiles[Rows[i].Idx];
      if Span > 0 then
        Divi := EnsureRange(1 + (i - Start) * Cfg.LeagueDivisions div Span, 1, Cfg.LeagueDivisions)
      else
        Divi := 1;
      Promille := Round((i + 1) * 1000.0 / n);
      if (P^.LeagueTier <> NewTier) or (P^.LeagueDivision <> Divi) or (P^.LeaguePromille <> Promille) then
      begin
        P^.LeagueTier := NewTier;
        P^.LeagueDivision := Divi;
        P^.LeaguePromille := Promille;
        DB.Touch(Rows[i].Idx);
      end;
    end;
    Start := Stop;
  end;
end;

{ ---------------- seasons ---------------- }

function SeasonDue(DB: TStatsDB; const Cfg: TZSConfig): Boolean;
begin
  Result := Cfg.SeasonsEnabled and ((DB.Server.SeasonId <= 0) or (DB.NowValue >= DB.Server.SeasonEnd));
end;

function SeasonEndFor(const Cfg: TZSConfig; Start: TDateTime): TDateTime;
var
  Y, M, D: Word;
begin
  if SameText(Trim(Cfg.SeasonLength), 'days') then
    Result := Trunc(Start) + Max(1, Cfg.SeasonDays)
  else
  begin
    DecodeDate(Start, Y, M, D);
    if M = 12 then
      Result := EncodeDate(Y + 1, 1, 1)
    else
      Result := EncodeDate(Y, M + 1, 1);
  end;
end;

function SeasonBetter(DB: TStatsDB; A, B: LongInt): Boolean;
var
  PA, PB: PPlayerProfile;
begin
  PA := DB.Profiles[A];
  PB := DB.Profiles[B];
  if PA^.SeasonPoints <> PB^.SeasonPoints then
    Exit(PA^.SeasonPoints > PB^.SeasonPoints);
  if PA^.SeasonKills <> PB^.SeasonKills then
    Exit(PA^.SeasonKills > PB^.SeasonKills);
  Result := PA^.ID < PB^.ID;
end;

function ArchiveSeason(DB: TStatsDB; const Cfg: TZSConfig): LongInt;
var
  Cand: TIntArray;
  i, j, n, T, Top, k: LongInt;
  A: TSeasonArchive;
  P: PPlayerProfile;
begin
  Result := -1;
  if DB.Server.SeasonId <= 0 then
    Exit;
  n := 0;
  SetLength(Cand, DB.ProfileCount);
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if (P <> nil) and (P^.SeasonId = DB.Server.SeasonId) and (P^.SeasonTime >= Int64(Cfg.SeasonMinMinutes) * 60) then
    begin
      Cand[n] := i;
      Inc(n);
    end;
  end;
  Top := Min(n, Max(1, Cfg.SeasonArchiveTop));
  { partial selection sort: only the archived top is ordered }
  for i := 0 to Top - 1 do
  begin
    k := i;
    for j := i + 1 to n - 1 do
      if SeasonBetter(DB, Cand[j], Cand[k]) then
        k := j;
    T := Cand[i];
    Cand[i] := Cand[k];
    Cand[k] := T;
  end;
  A.Id := DB.Server.SeasonId;
  A.StartDate := DB.Server.SeasonStart;
  A.EndDate := DB.NowValue;
  SetLength(A.Entries, Top);
  for i := 0 to Top - 1 do
  begin
    P := DB.Profiles[Cand[i]];
    A.Entries[i].Place := i + 1;
    A.Entries[i].ProfileId := P^.ID;
    A.Entries[i].Name := P^.ActiveName;
    A.Entries[i].Points := P^.Points;
    A.Entries[i].SeasonPoints := P^.SeasonPoints;
    A.Entries[i].Kills := P^.SeasonKills;
    A.Entries[i].Deaths := P^.SeasonDeaths;
    A.Entries[i].Caps := P^.SeasonCaps;
    A.Entries[i].Wins := P^.SeasonWins;
    A.Entries[i].TimePlayed := P^.SeasonTime;
    A.Entries[i].Rating := MainFamilyRating(P^, Cfg);
    if i < 3 then
    begin
      k := Length(P^.Badges);
      SetLength(P^.Badges, k + 1);
      P^.Badges[k].SeasonId := A.Id;
      P^.Badges[k].Place := i + 1;
      DB.Touch(Cand[i]);
    end;
  end;
  Result := Length(DB.Seasons);
  SetLength(DB.Seasons, Result + 1);
  DB.Seasons[Result] := A;
  DB.TouchSeason(Result);
end;

procedure StartSeason(DB: TStatsDB; const Cfg: TZSConfig);
var
  i: LongInt;
  P: PPlayerProfile;
  Reset: AnsiString;
  First: Boolean;
begin
  { the first season only starts the calendar; points are reset when one season follows another }
  First := DB.Server.SeasonId <= 0;
  DB.Server.SeasonId := Max(DB.Server.NextSeasonId, DB.Server.SeasonId + 1);
  DB.Server.NextSeasonId := DB.Server.SeasonId + 1;
  DB.Server.SeasonStart := DB.NowValue;
  DB.Server.SeasonEnd := SeasonEndFor(Cfg, DB.NowValue);
  DB.TouchServer;
  Reset := LowerCase(Trim(Cfg.SeasonPointsReset));
  for i := 0 to DB.ProfileCount - 1 do
  begin
    P := DB.Profiles[i];
    if P = nil then
      Continue;
    { every account starts the new season at zero right away, so no command or export shows the
      numbers of the old season until the player comes back }
    if P^.SeasonId <> DB.Server.SeasonId then
    begin
      RollSeason(P^, DB.Server.SeasonId);
      DB.Touch(i);
    end;
    if not First and ((Reset = 'soft') or (Reset = 'hard')) then
    begin
      if Reset = 'hard' then
        P^.Points := Cfg.StartingPoints
      else
        P^.Points := Cfg.StartingPoints + Round((P^.Points - Cfg.StartingPoints) * EnsureRange(Cfg.SeasonSoftFactor, 0, 1));
      DB.Touch(i);
    end;
  end;
  DB.RebuildRanks;
end;

{ ---------------- achievements ---------------- }

var
  { the kills of the streak levels Rampage and Godlike (SetStreakAchievements) }
  StreakAchRampage: LongInt = 10;
  StreakAchGodlike: LongInt = 25;

procedure DefineAchievement(Id: LongInt; const Name, Info: AnsiString);
begin
  AchievementDefs[Id].Id := Id;
  AchievementDefs[Id].Name := Name;
  AchievementDefs[Id].Info := Info;
end;

procedure SetStreakAchievements(const Cfg: TZSConfig);

  function LevelKills(const Name: AnsiString; Default: LongInt): LongInt;
  var
    k: LongInt;
  begin
    Result := Default;
    for k := 0 to Cfg.SpreeLevelCount - 1 do
      if SameText(Trim(Cfg.SpreeLevels[k].Name), Name) then
        Exit(Cfg.SpreeLevels[k].Kills);
  end;

begin
  StreakAchRampage := LevelKills('Rampage', 10);
  StreakAchGodlike := LevelKills('Godlike', 25);
  AchievementDefs[10].Info := IntToStr(StreakAchRampage) + ' kills in a row';
  AchievementDefs[11].Info := IntToStr(StreakAchGodlike) + ' kills in a row';
end;

function AchievementName(Id: LongInt): AnsiString;
begin
  if (Id >= 1) and (Id <= ACH_COUNT) then
    Result := AchievementDefs[Id].Name
  else
    Result := '#' + IntToStr(Id);
end;

function HasAchievement(const P: TPlayerProfile; Id: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(P.Achievements) do
    if P.Achievements[k].Id = Id then
      Exit(True);
end;

function HSKillsTotal(const P: TPlayerProfile): LongInt;
var
  s: LongInt;
begin
  Result := 0;
  for s := 0 to WSLOT_COUNT - 1 do
    Inc(Result, P.Weapons[s].HSKills);
end;

{ how many weapons the player killed with at least Min times }
function WeaponsWithKills(const P: TPlayerProfile; Min: LongInt): LongInt;
var
  s: LongInt;
begin
  Result := 0;
  for s := 0 to WSLOT_COUNT - 1 do
    if P.Weapons[s].Kills >= Min then
      Inc(Result);
end;

function WonSeason(const P: TPlayerProfile): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(P.Badges) do
    if P.Badges[k].Place = 1 then
      Exit(True);
end;

function AchievementEarned(Id: LongInt; const P: TPlayerProfile; Rank: LongInt): Boolean;
var
  Shots: Int64;
begin
  Shots := Max(Int64(P.Shots), Int64(P.ShotsHits));
  case Id of
    1: Result := P.Kills >= 1;
    2: Result := P.Kills >= 100;
    3: Result := P.Kills >= 1000;
    4: Result := P.Kills >= 10000;
    5: Result := HSKillsTotal(P) >= 500;
    6: Result := P.LongestKillDistance >= 100;
    7: Result := P.BarrettLongKills >= 50;
    8: Result := P.FlagsScore >= 50;
    9: Result := P.FlagsReturn >= 100;
    10: Result := SpreeLivesAt(P, StreakAchRampage) >= 1;
    11: Result := SpreeLivesAt(P, StreakAchGodlike) >= 1;
    12: Result := P.Weapons[WEP_KNIFE].Kills >= 100;
    13: Result := P.GrenadeKills >= 100;
    14: Result := P.Assist >= 250;
    15: Result := P.SaviorKills >= 100;
    16: Result := P.TimePlayed >= 100 * 3600;
    17: Result := P.DaysPlayed >= 100;
    18: Result := P.Wins >= 100;
    19: Result := P.ClutchesWon >= 25;
    20: Result := P.CapsUnder10s >= 10;
    21: Result := P.LongestLifeSec >= 600;
    22: Result := P.FinisherKills >= 100;
    23: Result := P.ComebackWins >= 10;
    24: Result := (Rank >= 1) and (Rank <= 10);
    25: Result := P.KnifeKillsLifeBest >= 5;
    26: Result := P.Kills >= 25000;
    { the day record holds the last day played, so this is checked right after the kills }
    27: Result := P.Period[PERIOD_DAY].Kills >= 100;
    28: Result := P.SpreeKills >= 100;
    29: Result := P.PointmatchMode.Multi.MASTA_KILLA >= 1;
    30: Result := (Shots >= 5000) and (Int64(P.ShotsHits) * 100 >= Shots * 35);
    31: Result := P.ShotsHitsHead >= 2000;
    32: Result := P.LongKills100 >= 100;
    33: Result := P.AirKills >= 100;
    34: Result := P.HeightKills >= 100;
    35: Result := P.RamboMode.KillRamboCount >= 100;
    36: Result := P.WallKills >= 50;
    37: Result := P.ExplosionMultiKills >= 25;
    38: Result := WeaponsWithKills(P, 1) >= 14;
    39: Result := WeaponsWithKills(P, 100) >= 10;
    40: Result := P.Weapons[WEP_CHAINSAW].Kills >= 100;
    41: Result := P.Weapons[WEP_BOW].Kills + P.Weapons[WEP_BOW2].Kills >= 100;
    42: Result := P.FlagsScore >= 250;
    43: Result := P.FlaggerKills >= 100;
    44: Result := P.BaseDefenseKills >= 100;
    45: Result := P.BaseAttackKills >= 100;
    46: Result := P.HTFMode.TimeWhenHaveFlag >= 30 * 60;
    47: Result := P.RoundsWins >= 250;
    48: Result := P.PointmatchMode.ExtraPoints >= 500;
    49: Result := P.DistanceTraveledM >= 1000 * 1000;
    50: Result := WonSeason(P);
    else Result := False;
  end;
end;

function CheckAchievements(DB: TStatsDB; Index, Rank: LongInt): TIntArray;
const
  TOP10_MIN_RANKED = 30;
var
  Id, n: LongInt;
  P: PPlayerProfile;
begin
  Result := nil;
  if not DB.Valid(Index) then
    Exit;
  P := DB.Profiles[Index];
  { a top 10 place means little while the ranking is nearly empty }
  if DB.Ranks[RANK_POINTS].Count < TOP10_MIN_RANKED then
    Rank := 0;
  for Id := 1 to ACH_COUNT do
    if not HasAchievement(P^, Id) and AchievementEarned(Id, P^, Rank) then
    begin
      n := Length(P^.Achievements);
      SetLength(P^.Achievements, n + 1);
      P^.Achievements[n].Id := Id;
      P^.Achievements[n].Date := DB.NowValue;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := Id;
    end;
  if Length(Result) > 0 then
    DB.Touch(Index);
end;

{ ---------------- match ratings ---------------- }

{ Glicko-2 treats every whole day without a rated match as an empty rating period, so the
  deviation of a returning player grows again and the next results move the rating faster. }
procedure GlickoCatchUp(var S: TGlickoState; NowT: Double);
var
  Days: Double;
begin
  if (S.Games <= 0) or (S.LastUpdate <= 0) then
    Exit;
  Days := Int(NowT - S.LastUpdate);
  if Days >= 1 then
    Glicko2Decay(S, Trunc(Min(Days, 36500.0)));
end;

procedure RateFFA(DB: TStatsDB; const Cfg: TZSConfig; Family: LongInt; const Players, Scores: array of LongInt);
var
  n, i, j, k: LongInt;
  Before: array of TGlickoState;
  MmrBefore: array of Double;
  Sum, Beaten: Double;
  Opp: array of TGlickoOpponent;
  Skill: TSkillEntryArray;
  Ranks: array of LongInt;
  P: PPlayerProfile;
begin
  n := Length(Players);
  if (n < 2) or (Length(Scores) < n) then
    Exit;
  SetLength(Before, n);
  for i := 0 to n - 1 do
  begin
    GlickoCatchUp(DB.Profiles[Players[i]]^.Glicko[Family], DB.NowValue);
    Before[i] := DB.Profiles[Players[i]]^.Glicko[Family];
  end;
  SetLength(Opp, n - 1);
  for i := 0 to n - 1 do
  begin
    k := 0;
    for j := 0 to n - 1 do
      if j <> i then
      begin
        Opp[k].R := Before[j].R;
        Opp[k].RD := Before[j].RD;
        if Scores[i] > Scores[j] then
          Opp[k].Score := 1
        else if Scores[i] = Scores[j] then
          Opp[k].Score := 0.5
        else
          Opp[k].Score := 0;
        Inc(k);
      end;
    P := DB.Profiles[Players[i]];
    Glicko2Update(P^.Glicko[Family], Opp, k, Cfg.GlickoTau);
    P^.Glicko[Family].LastUpdate := DB.NowValue;
  end;

  { MMR: everybody is measured against the average of the others in this match; an account
    without an MMR yet (0) gets the start value first, so the others are not measured against 0 }
  SetLength(MmrBefore, n);
  for i := 0 to n - 1 do
  begin
    MmrBefore[i] := DB.Profiles[Players[i]]^.Mmr[Family].R;
    if IsNan(MmrBefore[i]) or (MmrBefore[i] <= 0) then
    begin
      MmrInit(DB.Profiles[Players[i]]^.Mmr[Family], DB.MmrStart);
      MmrBefore[i] := DB.Profiles[Players[i]]^.Mmr[Family].R;
    end;
  end;
  for i := 0 to n - 1 do
  begin
    Sum := 0;
    Beaten := 0;
    for j := 0 to n - 1 do
      if j <> i then
      begin
        Sum := Sum + MmrBefore[j];
        if Scores[i] > Scores[j] then
          Beaten := Beaten + 1
        else if Scores[i] = Scores[j] then
          Beaten := Beaten + 0.5;
      end;
    MmrUpdate(DB.Profiles[Players[i]]^.Mmr[Family], MmrBefore[i], Sum / (n - 1), Beaten / (n - 1),
      DB.MmrK, DB.MmrPlacement);
  end;

  SetLength(Skill, n);
  SetLength(Ranks, n);
  for i := 0 to n - 1 do
  begin
    P := DB.Profiles[Players[i]];
    Skill[i].Mu := P^.OpenSkill[Family].Mu;
    Skill[i].Sigma := P^.OpenSkill[Family].Sigma;
    Skill[i].Team := i;
    Skill[i].Weight := 1;
    Ranks[i] := 0;
    for j := 0 to n - 1 do
      if Scores[j] > Scores[i] then
        Inc(Ranks[i]);
  end;
  OpenSkillRate(Skill, n, Ranks, n, Cfg.OSBeta, Cfg.OSKappa, Cfg.OSMu / 300);
  for i := 0 to n - 1 do
  begin
    P := DB.Profiles[Players[i]];
    P^.OpenSkill[Family].Mu := Skill[i].Mu;
    P^.OpenSkill[Family].Sigma := Skill[i].Sigma;
    Inc(P^.OpenSkill[Family].Games);
    DB.Touch(Players[i]);
    DB.RefreshRanks(Players[i]);
  end;
end;

procedure RateTeams(DB: TStatsDB; const Cfg: TZSConfig; Family: LongInt; const Players, Teams: array of LongInt;
  const TeamScores: array of LongInt);
var
  Weights: array of Double;
  i: LongInt;
begin
  SetLength(Weights, Length(Players));
  for i := 0 to High(Weights) do
    Weights[i] := 1;
  RateTeams(DB, Cfg, Family, Players, Teams, Weights, TeamScores);
end;

procedure RateTeams(DB: TStatsDB; const Cfg: TZSConfig; Family: LongInt; const Players, Teams: array of LongInt;
  const Weights: array of Double; const TeamScores: array of LongInt);
var
  n, m, i, t, u, k, TeamCount, OppCount: LongInt;
  SumR, SumRD2, SumM, CountW: array[1..4] of Double;
  OppSum, ScoreSum, W: Double;
  TeamIndex: array[1..4] of LongInt;
  Opp: array[0..3] of TGlickoOpponent;
  Skill: TSkillEntryArray;
  Ranks: array of LongInt;
  P: PPlayerProfile;
  Uniq, Owner: array of LongInt;
  PreG: array of TGlickoState;
  PreM: array of TMmrState;
  PreS: array of TOpenSkillState;
  AccR, AccRD, AccVol, AccM, AccMu, AccSig: array of Double;
  G: TGlickoState;

  function Score(Team: LongInt): LongInt;
  begin
    if (Team - 1 >= 0) and (Team - 1 <= High(TeamScores)) then
      Result := TeamScores[Team - 1]
    else
      Result := 0;
  end;

  function Outcome(Own, Other: LongInt): Double;
  begin
    if Score(Own) > Score(Other) then
      Result := 1
    else if Score(Own) = Score(Other) then
      Result := 0.5
    else
      Result := 0;
  end;

  function WeightOf(Entry: LongInt): Double;
  begin
    if Entry <= High(Weights) then
      Result := Weights[Entry]
    else
      Result := 1;
    if IsNan(Result) then
      Result := 0;
    Result := EnsureRange(Result, 0.0, 1.0);
  end;

begin
  n := Length(Players);
  if (n < 2) or (Length(Teams) < n) then
    Exit;

  { every account once, with its ratings from before the match }
  SetLength(Owner, n);
  Uniq := nil;
  for i := 0 to n - 1 do
  begin
    Owner[i] := -1;
    for u := 0 to High(Uniq) do
      if Uniq[u] = Players[i] then
      begin
        Owner[i] := u;
        Break;
      end;
    if Owner[i] < 0 then
    begin
      SetLength(Uniq, Length(Uniq) + 1);
      Uniq[High(Uniq)] := Players[i];
      Owner[i] := High(Uniq);
    end;
  end;
  m := Length(Uniq);
  SetLength(PreG, m);
  SetLength(PreM, m);
  SetLength(PreS, m);
  SetLength(AccR, m);
  SetLength(AccRD, m);
  SetLength(AccVol, m);
  SetLength(AccM, m);
  SetLength(AccMu, m);
  SetLength(AccSig, m);
  for u := 0 to m - 1 do
  begin
    P := DB.Profiles[Uniq[u]];
    { the days without a rated match count on the copy: a match that is not rated after all (every
      part in one team) leaves the account as it was, so the same days are not counted twice }
    PreG[u] := P^.Glicko[Family];
    GlickoCatchUp(PreG[u], DB.NowValue);
    PreM[u] := P^.Mmr[Family];
    if IsNan(PreM[u].R) or (PreM[u].R <= 0) then
      MmrInit(PreM[u], DB.MmrStart);
    PreS[u] := P^.OpenSkill[Family];
    AccR[u] := 0;
    AccRD[u] := 0;
    AccVol[u] := 0;
    AccM[u] := 0;
    AccMu[u] := 0;
    AccSig[u] := 0;
  end;

  for t := 1 to 4 do
  begin
    SumR[t] := 0;
    SumRD2[t] := 0;
    SumM[t] := 0;
    CountW[t] := 0;
    TeamIndex[t] := -1;
  end;
  for i := 0 to n - 1 do
  begin
    t := Teams[i];
    W := WeightOf(i);
    if (t < 1) or (t > 4) or (W <= 0) then
      Continue;
    u := Owner[i];
    SumR[t] := SumR[t] + W * PreG[u].R;
    SumRD2[t] := SumRD2[t] + W * Sqr(PreG[u].RD);
    SumM[t] := SumM[t] + W * PreM[u].R;
    CountW[t] := CountW[t] + W;
  end;
  TeamCount := 0;
  for t := 1 to 4 do
    if CountW[t] > 0 then
    begin
      TeamIndex[t] := TeamCount;
      Inc(TeamCount);
    end;
  if TeamCount < 2 then
    Exit;

  { Glicko-2: every other team is one opponent with its average rating }
  for i := 0 to n - 1 do
  begin
    t := Teams[i];
    W := WeightOf(i);
    if (t < 1) or (t > 4) or (W <= 0) then
      Continue;
    k := 0;
    for u := 1 to 4 do
      if (u <> t) and (CountW[u] > 0) then
      begin
        Opp[k].R := SumR[u] / CountW[u];
        Opp[k].RD := Sqrt(SumRD2[u] / CountW[u]);
        Opp[k].Score := Outcome(t, u);
        Inc(k);
      end;
    u := Owner[i];
    G := PreG[u];
    Glicko2Update(G, Opp, k, Cfg.GlickoTau);
    AccR[u] := AccR[u] + W * (G.R - PreG[u].R);
    AccRD[u] := AccRD[u] + W * (G.RD - PreG[u].RD);
    AccVol[u] := AccVol[u] + W * (G.Vol - PreG[u].Vol);
  end;

  { MMR: your team average against the average of every other team, so the strength of the
    line-up decides how much a win is worth }
  for i := 0 to n - 1 do
  begin
    t := Teams[i];
    W := WeightOf(i);
    if (t < 1) or (t > 4) or (W <= 0) then
      Continue;
    OppSum := 0;
    ScoreSum := 0;
    OppCount := 0;
    for u := 1 to 4 do
      if (u <> t) and (CountW[u] > 0) then
      begin
        OppSum := OppSum + SumM[u] / CountW[u];
        ScoreSum := ScoreSum + Outcome(t, u);
        Inc(OppCount);
      end;
    if OppCount > 0 then
    begin
      u := Owner[i];
      AccM[u] := AccM[u] + W * MmrDelta(PreM[u], SumM[t] / CountW[t], OppSum / OppCount, ScoreSum / OppCount,
        DB.MmrK, DB.MmrPlacement);
    end;
  end;

  { OpenSkill: teams ranked by score }
  SetLength(Skill, n);
  SetLength(Ranks, TeamCount);
  for t := 1 to 4 do
    if TeamIndex[t] >= 0 then
    begin
      Ranks[TeamIndex[t]] := 0;
      for u := 1 to 4 do
        if (TeamIndex[u] >= 0) and (Score(u) > Score(t)) then
          Inc(Ranks[TeamIndex[t]]);
    end;
  for i := 0 to n - 1 do
  begin
    u := Owner[i];
    Skill[i].Mu := PreS[u].Mu;
    Skill[i].Sigma := PreS[u].Sigma;
    Skill[i].Weight := WeightOf(i);
    if (Teams[i] >= 1) and (Teams[i] <= 4) and (Skill[i].Weight > 0) then
      Skill[i].Team := TeamIndex[Teams[i]]
    else
      Skill[i].Team := -1;
  end;
  OpenSkillRate(Skill, n, Ranks, TeamCount, Cfg.OSBeta, Cfg.OSKappa, Cfg.OSMu / 300);
  for i := 0 to n - 1 do
    if Skill[i].Team >= 0 then
    begin
      u := Owner[i];
      AccMu[u] := AccMu[u] + Skill[i].Mu - PreS[u].Mu;
      AccSig[u] := AccSig[u] + Skill[i].Sigma - PreS[u].Sigma;
    end;

  { one rated match more for every account, with the parts added up }
  for u := 0 to m - 1 do
  begin
    P := DB.Profiles[Uniq[u]];
    G := PreG[u];
    G.R := PreG[u].R + AccR[u];
    G.RD := EnsureRange(PreG[u].RD + AccRD[u], 30, 350);
    G.Vol := EnsureRange(PreG[u].Vol + AccVol[u], 0.001, 1.0);
    G.Games := PreG[u].Games + 1;
    G.LastUpdate := DB.NowValue;
    P^.Glicko[Family] := G;
    P^.Mmr[Family].R := Max(100.0, PreM[u].R + AccM[u]);
    P^.Mmr[Family].Games := PreM[u].Games + 1;
    P^.OpenSkill[Family].Mu := PreS[u].Mu + AccMu[u];
    P^.OpenSkill[Family].Sigma := Max(0.001, PreS[u].Sigma + AccSig[u]);
    P^.OpenSkill[Family].Games := PreS[u].Games + 1;
    DB.Touch(Uniq[u]);
    DB.RefreshRanks(Uniq[u]);
  end;
end;

{ ---------------- performance rating and tiers ---------------- }

{ How well someone plays, without the points balance and without the map: accuracy, kill ratio,
  headshots, won matches and objective work, scaled to roughly 0..100. An account with few kills
  is pulled toward the lower baseline, so one lucky evening does not read as mastery. }
function SkillRating(const P: TPlayerProfile; GameStyle: LongInt; Survival, FriendlyFire: Boolean): Double;
const
  BASELINE = 15.0;
  SAMPLE_HALF = 300.0;
var
  Acc, KD, AccFactor, HSFactor, WinFactor, RoundFactor, ObjFactor, Core, Confidence: Double;
  Shots, Sample, Matches, Rounds: Int64;
begin
  Shots := Max(P.Shots, P.ShotsHits);
  if Shots > 0 then
    Acc := Min(P.ShotsHits / Shots, 1.0)
  else
    Acc := 0.2;
  AccFactor := EnsureRange(0.6 + Acc * 2.0, 0.6, 1.8);
  if P.Deaths > 0 then
  begin
    if FriendlyFire and IsTeamStyle(GameStyle) then
      KD := (P.Kills - P.Teamkills) / P.Deaths
    else
      KD := P.Kills / P.Deaths;
  end
  else if P.Kills > 0 then
    KD := P.Kills
  else
    KD := 1.0;
  KD := EnsureRange(KD, 0.2, 4.0);
  if P.ShotsHits > 0 then
    HSFactor := EnsureRange(0.9 + (P.ShotsHitsHead / P.ShotsHits) * 1.0, 0.9, 1.3)
  else
    HSFactor := 1.0;
  Matches := Int64(P.Wins) + P.Loses;
  if Matches > 0 then
    WinFactor := EnsureRange(0.8 + P.Wins / Matches * 0.5, 0.8, 1.3)
  else
    WinFactor := 1.0;
  Rounds := Int64(P.RoundsWins) + P.RoundsLose;
  if Survival and (Rounds > 0) then
    RoundFactor := EnsureRange(0.85 + P.RoundsWins / Rounds * 0.4, 0.85, 1.25)
  else
    RoundFactor := 1.0;
  if IsTeamStyle(GameStyle) then
    ObjFactor := EnsureRange(0.9 + (P.FlagsScore * 2.0 + P.FlagsReturn + P.FlaggerKills + P.Assist) / 150.0, 0.9, 1.3)
  else
    ObjFactor := 1.0;
  Core := AccFactor * KD * HSFactor * WinFactor * RoundFactor * ObjFactor;
  Result := EnsureRange(Core * 25.0, 0.0, 100.0);
  Sample := Int64(P.Kills) + P.Deaths;
  Confidence := Sample / (Sample + SAMPLE_HALF);
  Result := BASELINE + (Result - BASELINE) * Confidence;
end;

function PerformanceRating(const P: TPlayerProfile; GameStyle: LongInt; Survival, FriendlyFire: Boolean;
  const Mode: AnsiString): Double;
var
  Acc, KD, WinRatio, RoundRatio, AccFactor, HSFactor, StreakFactor, FlagFactor, TeamFactor: Double;
  Shots: Int64;
begin
  if SameText(Trim(Mode), 'skill') then
    Exit(SkillRating(P, GameStyle, Survival, FriendlyFire));
  { the ZitroStats 4 performance index, kept for tiers and !stats }
  Shots := Max(P.Shots, P.ShotsHits);
  if Shots > 0 then
    Acc := Min(P.ShotsHits / Shots, 1.0)
  else
    Acc := 0.2;
  AccFactor := EnsureRange(0.5 + Acc * 2.5, 0.5, 2.0);
  if P.Deaths > 0 then
  begin
    if FriendlyFire and IsTeamStyle(GameStyle) then
      KD := (P.Kills - P.Teamkills) / P.Deaths
    else
      KD := P.Kills / P.Deaths;
  end
  else if P.Kills > 0 then
    KD := P.Kills
  else
    KD := 1.0;
  KD := EnsureRange(KD, 0.2, 4.0);
  { a player who never lost still deserves the full ratio, so the loss count starts at one }
  if P.Wins + P.Loses > 0 then
    WinRatio := EnsureRange(P.Wins / Max(1, P.Loses), 0.5, 3.0)
  else
    WinRatio := 1.0;
  if Survival and (P.RoundsWins + P.RoundsLose > 0) then
    RoundRatio := EnsureRange(P.RoundsWins / Max(1, P.RoundsLose), 0.5, 3.0)
  else
    RoundRatio := 1.0;

  if SameText(Trim(Mode), 'unified') then
  begin
    FlagFactor := Min(1.0 + (P.FlagsScore * 2.0 + P.FlagsReturn + P.FlaggerKills) / 50.0, 1.4);
    TeamFactor := Min(1.0 + (P.Assist + P.SaviorKills + P.AvengerKills) / 60.0, 1.3);
    Result := AccFactor * KD * WinRatio * RoundRatio * FlagFactor * TeamFactor / 4.14 * P.Points / 2.0;
  end
  else
    case GameStyle of
      GS_DM, GS_PM, GS_RM:
        begin
          if P.ShotsHits > 0 then
            HSFactor := EnsureRange(0.85 + (P.ShotsHitsHead / P.ShotsHits) * 1.5, 0.85, 1.5)
          else
            HSFactor := 1.0;
          StreakFactor := Min(1.0 + (P.PointmatchMode.Multi.DOUBLE_KILL + P.PointmatchMode.Multi.TRIPLE_KILL * 2 +
            P.PointmatchMode.Multi.MULTI_KILL * 3) / 100.0, 1.4);
          Result := AccFactor * KD * HSFactor * StreakFactor / 4.14 * P.Points / 2.0;
        end;
      GS_CTF:
        begin
          FlagFactor := EnsureRange(0.8 + (P.FlagsScore * 3.0 + P.FlagsReturn * 1.5 + P.FlaggerKills) / 40.0, 0.8, 1.6);
          Result := AccFactor * KD * WinRatio * FlagFactor / 4.14 * P.Points / 2.0;
        end;
      else
        begin
          TeamFactor := EnsureRange(0.85 + (P.Assist * 1.5 + P.SaviorKills + P.AvengerKills) / 45.0, 0.85, 1.5);
          Result := AccFactor * KD * WinRatio * TeamFactor * RoundRatio / 4.14 * P.Points / 2.0;
        end;
    end;
  if Result < 1.0 then
    Result := 1.0;
end;

{ [Ranking] TierBy: points (like the ranking, so a higher place in !top never has a lower tier),
  rating (the Rating of the game mode, a badge of how somebody plays), mmr, glicko2 or openskill
  (that rating of the family of the game mode), both (points and rating) or all (every limit the
  line gives). A line without a limit for the measure is skipped; the last line is the rest. }
function TierIndex(const Cfg: TZSConfig; const P: TPlayerProfile; Perf: Double; Family, RatingSystem: LongInt): LongInt;
const
  UNSET = -99999;
var
  i: LongInt;
  Ok: Boolean;
  By: AnsiString;
  Mmr, Glk, Os: Double;
begin
  Result := Cfg.RankTierCount - 1;
  By := LowerCase(Trim(Cfg.TierBy));
  Mmr := P.Mmr[Family].R;
  Glk := GlickoConservative(P.Glicko[Family], Cfg.GlickoConservative);
  Os := OpenSkillOrdinal(P.OpenSkill[Family]);
  for i := 0 to Cfg.RankTierCount - 1 do
  begin
    { a rating limit of UNSET or below is no limit, like those of MMR, Glicko-2 and OpenSkill }
    with Cfg.RankTiers[i] do
      if By = 'rating' then
        Ok := (MinRating > UNSET) and (Perf >= MinRating)
      else if By = 'mmr' then
        Ok := (MinMmr > UNSET) and (Mmr >= MinMmr)
      else if By = 'glicko2' then
        Ok := (MinGlicko > UNSET) and (Glk >= MinGlicko)
      else if By = 'openskill' then
        Ok := (MinOpenSkill > UNSET) and (Os >= MinOpenSkill)
      else if By = 'both' then
        Ok := (P.Points >= MinPoints) and ((MinRating <= UNSET) or (Perf >= MinRating))
      else if By = 'all' then
        Ok := (P.Points >= MinPoints) and ((MinRating <= UNSET) or (Perf >= MinRating)) and
          ((MinMmr <= UNSET) or (Mmr >= MinMmr)) and ((MinGlicko <= UNSET) or (Glk >= MinGlicko)) and
          ((MinOpenSkill <= UNSET) or (Os >= MinOpenSkill))
      else
        Ok := P.Points >= MinPoints;
    if Ok then
      Exit(i);
  end;
end;

initialization
  { names up to 15 characters and conditions up to 19, so !achlist fits two per line (tested) }
  DefineAchievement(1, 'First Blood', 'your first kill');
  DefineAchievement(2, 'Soldier', '100 kills');
  DefineAchievement(3, 'Veteran', '1000 kills');
  DefineAchievement(4, 'Legend', '10000 kills');
  DefineAchievement(5, 'Headhunter', '500 headshot kills');
  DefineAchievement(6, 'Long Shot', 'a kill from 100 m');
  DefineAchievement(7, 'Sniper Elite', '50 Barrett 75 m+');
  DefineAchievement(8, 'Flag Runner', '50 flag caps');
  DefineAchievement(9, 'Defender', '100 flag returns');
  { the streaks of the fixed counters, whatever the levels of [Sprees] call them; a streak goes on
    over the end of a survival round, so it is kills in a row, not in one life }
  DefineAchievement(10, 'Rampage', '10 kills in a row');
  DefineAchievement(11, 'Godlike', '25 kills in a row');
  DefineAchievement(12, 'Blade Master', '100 knife kills');
  DefineAchievement(13, 'Grenadier', '100 grenade kills');
  DefineAchievement(14, 'Team Player', '250 assists');
  DefineAchievement(15, 'Guardian', '100 savior kills');
  DefineAchievement(16, 'Marathon', '100 hours played');
  DefineAchievement(17, 'Regular', '100 days played');
  DefineAchievement(18, 'Winner', '100 matches won');
  DefineAchievement(19, 'Clutch King', '25 clutches won');
  DefineAchievement(20, 'Speed Runner', '10 caps under 10 s');
  DefineAchievement(21, 'Survivor', '10 min in one life');
  DefineAchievement(22, 'Finisher', '100 finisher kills');
  DefineAchievement(23, 'Comeback', '10 comeback wins');
  DefineAchievement(24, 'Top 10', 'ranking top 10');
  DefineAchievement(25, 'Butcher', '5 knife kills/life');
  DefineAchievement(26, 'Immortal', '25000 kills');
  DefineAchievement(27, 'Centurion', '100 kills in a day');
  DefineAchievement(28, 'Spree Master', '100 5-kill streaks');
  DefineAchievement(29, 'Masta Killa', '9-kill multi-kill');
  DefineAchievement(30, 'Sharpshooter', '35% acc, 5000 shots');
  DefineAchievement(31, 'Brain Surgeon', '2000 headshot hits');
  DefineAchievement(32, 'Far Sight', '100 kills of 100 m');
  DefineAchievement(33, 'Sky Hunter', '100 kills in flight');
  DefineAchievement(34, 'High Ground', '100 height kills');
  DefineAchievement(35, 'Rambo Slayer', 'kill Rambo 100x');
  DefineAchievement(36, 'Wallbanger', '50 kills thru cover');
  DefineAchievement(37, 'Demolition', '25 explosive multis');
  DefineAchievement(38, 'Arsenal', 'kill with 14 guns');
  DefineAchievement(39, 'Weapon Master', '100 kills, 10 guns');
  DefineAchievement(40, 'Chainsaw Maniac', '100 chainsaw kills');
  DefineAchievement(41, 'Bow Master', '100 bow kills');
  DefineAchievement(42, 'Flag Master', '250 flag caps');
  DefineAchievement(43, 'Flag Hunter', '100 flagger kills');
  DefineAchievement(44, 'Iron Wall', '100 base defenses');
  DefineAchievement(45, 'Raider', '100 base attacks');
  DefineAchievement(46, 'Holder', 'HTF: 30 min on flag');
  DefineAchievement(47, 'Round Winner', '250 rounds won');
  DefineAchievement(48, 'Point Hunter', '500 PM bonus pts');
  DefineAchievement(49, 'Globetrotter', 'travel 1000 km');
  DefineAchievement(50, 'Champion', 'win a season');

end.
