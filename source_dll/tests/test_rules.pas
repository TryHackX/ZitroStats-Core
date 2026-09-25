program test_rules;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_fields, zs_db, zs_rating, zs_live, zs_rules;

var
  Failures: Integer = 0;
  Cfg, Cfg2: TZSConfig;
  DB: TStatsDB;

procedure Check(const Name: string; Ok: Boolean);
begin
  if Ok then
    WriteLn('[ OK ] ', Name)
  else
  begin
    WriteLn('[FAIL] ', Name);
    Inc(Failures);
  end;
end;

function Mk(const Name: AnsiString; Points: LongInt; DaysAgo: Double): LongInt;
begin
  Result := DB.CreateProfile(Name, '', 'HW-' + Name, '1.1.1.1', 1000);
  DB.Profiles[Result]^.Points := Points;
  DB.Profiles[Result]^.LastPlayedTime := DB.NowValue - DaysAgo;
  DB.RefreshRanks(Result);
end;

function TotalPoints: Int64;
var
  i: LongInt;
begin
  Result := 0;
  for i := 0 to DB.ProfileCount - 1 do
    if DB.Profiles[i] <> nil then
      Inc(Result, DB.Profiles[i]^.Points);
end;

procedure FreshDB(When: TDateTime);
begin
  DB.Free;
  DB := TStatsDB.Create;
  DB.SetNow(When);
end;

var
  T0: TDateTime;
  a, c, i, Gain, Top, Rich, Low: LongInt;
  e: array[0..2] of LongInt;
  t: array[0..1] of LongInt;
  Gains, Losses, Ach: TIntArray;
  Before: Int64;
  Pair: TPairState;
  Hits: LongInt;
  Rep: TBalanceReport;
  Players: array[0..3] of LongInt;
  Q: array[0..4] of LongInt;
  Ok: Boolean;
  G: TGlickoState;
  Warn, Bad: TStringList;
  TierP, TierR: LongInt;
  T1, T2: Int64;
  R0: Double;
begin
  Warn := TStringList.Create;
  SetConfigDefaults(Cfg);
  Check('shipped settings.ini loads without warnings', LoadConfigFile(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' +
    PathDelim + '..' + PathDelim + 'settings.ini', Cfg, Warn) and (Warn.Count = 0));
  for i := 0 to Warn.Count - 1 do
    WriteLn('       ', Warn[i]);
  Bad := TStringList.Create;
  Bad.Add('[Admin]');
  Bad.Add('AdminConfirmPassword = secret');
  Bad.Add('[Ranking]');
  Bad.Add('MaxPointGive = many');
  Bad.Add('[Messages]');
  Bad.Add('WelcomeEnabled = maybe');
  Bad.SaveToFile(ExtractFilePath(ParamStr(0)) + 'bad_settings.ini');
  Bad.Free;
  Warn.Clear;
  SetConfigDefaults(Cfg);
  LoadConfigFile(ExtractFilePath(ParamStr(0)) + 'bad_settings.ini', Cfg, Warn);
  Check('misspelt keys and bad values are reported', (Warn.Count = 3) and (Cfg.MaxPointGive = 45) and
    (Cfg.AdminConfirmPassword = ''));
  for i := 0 to Warn.Count - 1 do
    WriteLn('       ', Warn[i]);

  { [Sprees]: the built-in levels, the block the documentation gives (the same levels), a file with
    levels of its own, and every mistake in one }
  SetConfigDefaults(Cfg);
  Check('[Sprees] built in: ten levels from 3 kills, the first one in the chat', Cfg.SpreesEnabled and
    (Cfg.SpreeLevelCount = 10) and (Cfg.SpreeLevels[0].Kills = 3) and (Cfg.SpreeLevels[0].Name = 'Killing Spree') and
    (Cfg.SpreeLevels[0].Style = SPREE_CHAT) and (Cfg.SpreeLevels[1].Style = SPREE_BOTH) and
    (Cfg.SpreeLevels[9].Kills = 30) and (Cfg.SpreeLevels[9].Name = 'Holy Shit') and (Cfg.SpreeShutStyle = SPREE_CHAT) and
    (Cfg.SpreeColor = $FF4500) and (Cfg.SpreeBigSeconds = 3) and SameValue(Cfg.SpreeBigScale, 0.1, 1e-6) and
    (Cfg.SpreeBigY = 130));
  Bad := TStringList.Create;
  Bad.Add('[Sprees]');
  Bad.Add('; kill streaks');
  Bad.Add('Enabled = 1');
  Bad.Add('Level1 = 3, Killing Spree, chat, %s is on a KILLING SPREE!');
  Bad.Add('Level2 = 5, Rampage, both, %s is on a RAMPAGE!');
  Bad.Add('Level3 = 7, Dominating, both, %s is DOMINATING!');
  Bad.Add('Level4 = 10, Unstoppable, both, %s is UNSTOPPABLE!');
  Bad.Add('Level5 = 12, Mega Kill, both, %s: MEGA KILL!');
  Bad.Add('Level6 = 15, Ultra Kill, both, %s: ULTRA KILL!');
  Bad.Add('Level7 = 17, Wicked Sick, both, %s is WICKED SICK!');
  Bad.Add('Level8 = 20, Monster Kill, both, %s: MONSTER KILL!');
  Bad.Add('Level9 = 25, Godlike, both, %s is GODLIKE!');
  Bad.Add('Level10 = 30, Holy Shit, both, %s: HOLY SHIT! %d kills in a row!');
  Bad.Add('ShutDown = chat, %s ended the killing spree of %s (%d kills)');
  Bad.Add('Color = FF4500');
  Bad.Add('BigTextSeconds = 3');
  Bad.Add('BigTextScale = 0.1');
  Bad.Add('BigTextY = 130');
  Bad.SaveToFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini');
  SetConfigDefaults(Cfg);
  Warn.Clear;
  LoadConfigFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini', Cfg, Warn);
  Ok := (Warn.Count = 0) and (Cfg.SpreeLevelCount = 10) and (Cfg.SpreeShutText = '%s ended the killing spree of %s (%d kills)');
  Cfg2 := Default(TZSConfig);
  SetConfigDefaults(Cfg2);
  for i := 0 to 9 do
    if (Cfg.SpreeLevels[i].Kills <> Cfg2.SpreeLevels[i].Kills) or (Cfg.SpreeLevels[i].Name <> Cfg2.SpreeLevels[i].Name) or
       (Cfg.SpreeLevels[i].Style <> Cfg2.SpreeLevels[i].Style) or (Cfg.SpreeLevels[i].Text <> Cfg2.SpreeLevels[i].Text) then
      Ok := False;
  Check('[Sprees] the block of settings.ini loads without warnings and is the built-in levels', Ok);
  for i := 0 to Warn.Count - 1 do
    WriteLn('       ', Warn[i]);
  Bad.Clear;
  Bad.Add('[Sprees]');
  Bad.Add('Enabled = 0');
  Bad.Add('Level2 = 6, Rampage, bigtext, %s is on a RAMPAGE, 6 kills!');
  Bad.Add('Level1 = 2, Double, off');
  Bad.Add('Level3 = 9, Beyond Godlike');
  Bad.Add('ShutDown = both, %s stopped %s at %d kills');
  Bad.Add('Color = #00FF00');
  Bad.Add('BigTextSeconds = 5');
  Bad.Add('BigTextScale = 0.12');
  Bad.Add('BigTextY = 100');
  Bad.SaveToFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini');
  SetConfigDefaults(Cfg);
  Warn.Clear;
  LoadConfigFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini', Cfg, Warn);
  Check('[Sprees] levels of its own replace the built-in ones, by their kills, a message may hold commas',
    (Warn.Count = 0) and not Cfg.SpreesEnabled and (Cfg.SpreeLevelCount = 3) and (Cfg.SpreeLevels[0].Kills = 2) and
    (Cfg.SpreeLevels[0].Name = 'Double') and (Cfg.SpreeLevels[0].Style = SPREE_OFF) and
    (Cfg.SpreeLevels[1].Kills = 6) and (Cfg.SpreeLevels[1].Style = SPREE_BIGTEXT) and
    (Cfg.SpreeLevels[1].Text = '%s is on a RAMPAGE, 6 kills!') and (Cfg.SpreeLevels[2].Kills = 9) and
    (Cfg.SpreeLevels[2].Style = SPREE_BOTH) and (Cfg.SpreeLevels[2].Text = '%s: BEYOND GODLIKE!'));
  Check('[Sprees] the shut-down line, the colour and the big text', (Cfg.SpreeShutStyle = SPREE_BOTH) and
    (Cfg.SpreeShutText = '%s stopped %s at %d kills') and (Cfg.SpreeColor = $00FF00) and (Cfg.SpreeBigSeconds = 5) and
    SameValue(Cfg.SpreeBigScale, 0.12, 1e-6) and (Cfg.SpreeBigY = 100) and (SpreeLevelOf(Cfg, 6) = 1) and
    (SpreeLevelOf(Cfg, 5) = -1));
  for i := 0 to Warn.Count - 1 do
    WriteLn('       ', Warn[i]);
  Bad.Clear;
  Bad.Add('[Sprees]');
  Bad.Add('Level1 = 0, Zero');
  Bad.Add('Level2 = 51, Too Many');
  Bad.Add('Level3 = abc, Letters');
  Bad.Add('Level4 = 5');
  Bad.Add('Level5 = 5, Five, loud, %s five');
  Bad.Add('Level6 = 5, Again');
  Bad.Add('Level5 = 8, Twice');
  Bad.Add('Level13 = 9, Thirteen');
  Bad.Add('ShutDown = shout, %s ended %s');
  Bad.Add('BigTextSeconds = 99');
  Bad.Add('Mystery = 1');
  Bad.SaveToFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini');
  SetConfigDefaults(Cfg);
  Warn.Clear;
  LoadConfigFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini', Cfg, Warn);
  for i := 0 to Warn.Count - 1 do
    WriteLn('       ', Warn[i]);
  Check('[Sprees] every mistake is named and left out, a wrong style falls back',
    (Warn.Count = 11) and (Cfg.SpreeLevelCount = 1) and (Cfg.SpreeLevels[0].Name = 'Five') and
    (Cfg.SpreeLevels[0].Style = SPREE_BOTH) and (Cfg.SpreeShutStyle = SPREE_CHAT) and (Cfg.SpreeShutText = '%s ended %s') and
    (Cfg.SpreeBigSeconds = 30));
  Bad.Clear;
  Bad.Add('[Sprees]');
  Bad.Add('Level1 = 0, Zero');
  Bad.SaveToFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini');
  SetConfigDefaults(Cfg);
  Warn.Clear;
  LoadConfigFile(ExtractFilePath(ParamStr(0)) + 'spree_settings.ini', Cfg, Warn);
  Check('[Sprees] no valid level at all: the built-in ones are back, and it is said', (Warn.Count = 2) and
    (Cfg.SpreeLevelCount = 10) and (Pos('built-in levels', Warn.Text) > 0));
  Bad.Free;
  Check('a spree message: %s the names in turn, %d the kills, %% a %, any other % as written',
    (SpreeText('%s is on a %d-kill spree, 100%% sure, 50% %x %', ['Bob'], 7) = 'Bob is on a 7-kill spree, 100% sure, 50% %x %') and
    (SpreeText('%s ended the spree of %s (%d)', ['Ann', 'Bob'], 12) = 'Ann ended the spree of Bob (12)') and
    (SpreeText('%s and %s', ['Ann'], 1) = 'Ann and ') and (SpreeText('%s', ['50%s off %d'], 3) = '50%s off %d'));
  Warn.Free;
  SetConfigDefaults(Cfg);

  SetConfigDefaults(Cfg);
  T0 := EncodeDate(2026, 9, 15) + EncodeTime(4, 0, 0, 0);
  DB := TStatsDB.Create;
  DB.SetNow(T0);

  a := Mk('A', 1005, 0);
  Check('floor stops losses', (AddPoints(DB, a, -20, 1000) = -5) and (DB.Profiles[a]^.Points = 1000));
  DB.Profiles[a]^.Points := 900;
  Check('below the floor nothing more is lost', (AddPoints(DB, a, -20, 1000) = 0) and (DB.Profiles[a]^.Points = 900));
  Check('gains are not limited', AddPoints(DB, a, 30, 1000) = 30);
  Check('day and season deltas', (DB.Profiles[a]^.Period[PERIOD_DAY].PointsDelta = 25) and
    (DB.Profiles[a]^.Period[PERIOD_MONTH].Key = 202609) and (DB.Profiles[a]^.SeasonPoints = 25));
  DB.Profiles[a]^.Points := High(LongInt) - 5;
  Check('points stop at the end of the range instead of wrapping round', (AddPoints(DB, a, 20, 1000) = 5) and
    (DB.Profiles[a]^.Points = High(LongInt)) and (DB.Ranks[RANK_POINTS].At(1) = a));

  Check('elo kill points', KillPoints(Cfg, 1000, 1000, False, 0) = 22);
  Check('inactive victim: 100/50/25/0', (KillPoints(Cfg, 1000, 1000, True, 0) = 22) and
    (KillPoints(Cfg, 1000, 1000, True, 1) = 11) and (KillPoints(Cfg, 1000, 1000, True, 2) = 5) and
    (KillPoints(Cfg, 1000, 1000, True, 3) = 0) and (KillPoints(Cfg, 1000, 1000, True, 9) = 0));

  FreshDB(T0);
  c := Mk('Capper', 1000, 0);
  t[0] := Mk('T1', 1000, 0);
  t[1] := Mk('T2', 1000, 0);
  for i := 0 to 2 do
    e[i] := Mk('E' + IntToStr(i), 1000, 0);
  Before := TotalPoints;
  CtfCapPool(DB, Cfg, c, e, t, Gain, Gains, Losses);
  Check('cap pool is zero-sum', (TotalPoints = Before) and (Losses[0] = 13) and (Gain + Gains[0] + Gains[1] = 39));
  Check('capper share', (Gain = 23) and (Gains[0] = 8) and (Gains[1] = 8));
  CtfCapPool(DB, Cfg, c, [], [], Gain, Gains, Losses);
  Check('no enemies: fallback points', Gain = Cfg.FlagScoreFallbackPoints);
  Cfg.CapPoolPoints := 0;
  Before := TotalPoints;
  CtfCapPool(DB, Cfg, c, e, t, Gain, Gains, Losses);
  Check('CapPoolPoints = 0: enemies pay nothing, fallback points', (Losses[0] = 0) and
    (Gain = Cfg.FlagScoreFallbackPoints) and (TotalPoints = Before + Cfg.FlagScoreFallbackPoints));
  Cfg.CapPoolPoints := 13;
  Cfg.CapWinnerSharePct := 0;
  CtfCapPool(DB, Cfg, c, e, t, Gain, Gains, Losses);
  Check('CapWinnerSharePercent = 0: the team gets the pool', (Gains[0] + Gains[1] >= 38) and (Gain <= 1));
  Cfg.CapWinnerSharePct := 60;

  FillChar(Pair, SizeOf(Pair), 0);
  Hits := 0;
  for i := 1 to 15 do
    if SuspiciousKill(Pair, 1000 + i * 60, 0, 2, Cfg) then
      Inc(Hits);
  Check('suspicious series logged once', (Hits = 1) and (Pair.WinKills = 15));
  FillChar(Pair, SizeOf(Pair), 0);
  Hits := 0;
  for i := 1 to 15 do
    if SuspiciousKill(Pair, 1000 + i * 60, 0, 8, Cfg) then
      Inc(Hits);
  Check('busy server is not suspicious', Hits = 0);

  FreshDB(T0);
  a := Mk('Prot', 1200, 0);
  AddActivity(DB, a, GS_CTF, 6, 3, 0, 0, 0, 0, 0, 100);
  NoteProtectionActivity(DB, a, Cfg);
  Check('not enough events yet', DB.Profiles[a]^.ProtectionDays = 0);
  AddActivity(DB, a, GS_CTF, 1, 0, 0, 0, 0, 0, 0, 0);
  NoteProtectionActivity(DB, a, Cfg);
  NoteProtectionActivity(DB, a, Cfg);
  Check('a qualifying day earns one protection day', (DB.Profiles[a]^.ProtectionDays = 1) and (DB.Profiles[a]^.DaysPlayed = 1));
  DB.SetNow(T0 + 1);
  AddActivity(DB, a, GS_CTF, 10, 0, 0, 0, 0, 0, 0, 95);
  NoteProtectionActivity(DB, a, Cfg);
  Check('next day earns another', (DB.Profiles[a]^.ProtectionDays = 2) and (DB.Profiles[a]^.DaysPlayed = 2));

  { the owner's first evening: four hours and 240 kills and deaths on one calendar day are one
    protection day, however long the evening; played on past midnight, the new day earns the next
    one once it has 90 s and 10 kills and deaths of its own }
  FreshDB(EncodeDate(2026, 9, 21) + EncodeTime(19, 0, 0, 0));
  a := Mk('Owner', 1000, 0);
  for i := 1 to 240 do
  begin
    DB.SetNow(EncodeDate(2026, 9, 21) + EncodeTime(19, 0, 0, 0) + i * (60 / 86400));
    AddActivity(DB, a, GS_DM, i mod 2, 1 - i mod 2, 0, 0, 0, 0, 0, 60);
    NoteProtectionActivity(DB, a, Cfg);
  end;
  Check('a long first evening is one protection day', (DB.Profiles[a]^.ProtectionDays = 1) and
    (DB.Profiles[a]^.ActivityForProtectDays = DayKey(EncodeDate(2026, 9, 21))));
  DB.SetNow(EncodeDate(2026, 9, 22) + EncodeTime(0, 0, 30, 0));
  AddActivity(DB, a, GS_DM, 5, 4, 0, 0, 0, 0, 0, 60);
  NoteProtectionActivity(DB, a, Cfg);
  Check('after midnight the new day starts from nothing', DB.Profiles[a]^.ProtectionDays = 1);
  AddActivity(DB, a, GS_DM, 1, 0, 0, 0, 0, 0, 0, 30);
  NoteProtectionActivity(DB, a, Cfg);
  Check('and earns its own day with 90 s and 10 kills and deaths', DB.Profiles[a]^.ProtectionDays = 2);
  DB.Profiles[a]^.ProtectionDays := Cfg.ProtectMaxDays;
  DB.SetNow(EncodeDate(2026, 9, 23) + EncodeTime(12, 0, 0, 0));
  AddActivity(DB, a, GS_DM, 10, 0, 0, 0, 0, 0, 0, 90);
  NoteProtectionActivity(DB, a, Cfg);
  Check('never more than ProtectMaxDays', DB.Profiles[a]^.ProtectionDays = Cfg.ProtectMaxDays);

  FreshDB(T0);
  Cfg.CheckPointsEnabled := False;
  for i := 1 to 40 do
    Mk('Pro' + IntToStr(i), 2600, 0);
  for i := 1 to 20 do
    Mk('Rec' + IntToStr(i), 1000, 0);
  for i := 1 to 30 do
    Mk('Gone' + IntToStr(i), 1500, 40);
  for i := 1 to 10 do
  begin
    a := Mk('Safe' + IntToStr(i), 1500, 40);
    DB.Profiles[a]^.ProtectionDays := 3;
  end;
  Rich := Mk('RichGone', 5000, 40);
  Low := Mk('LowGone', 1010, 40);
  Before := TotalPoints;
  DailyMaintenance(DB, Cfg, Rep);
  Check('balance keeps the total', (TotalPoints = Before) and (Rep.Collected = Rep.Paid));
  Check('rank 1 inactive pays 220', DB.Profiles[Rich]^.Points = 5000 - 220);
  Check('nobody drops below the floor', DB.Profiles[Low]^.Points = 1000);
  Check('protection days are used first', (Rep.ProtectionUsed = 10) and (DB.Profiles[a]^.Points = 1500) and
    (DB.Profiles[a]^.ProtectionDays = 2));
  Check('pool reaches the recipients', (Rep.Collected = 30 * 35 + 220 + 10) and (Rep.Recipients = 20));
  WriteLn(Format('       balance: collected %d, paid %d to %d players', [Rep.Collected, Rep.Paid, Rep.Recipients]));

  Cfg.InactivityMode := 'decay';
  a := DB.IndexOfId(DB.Profiles[Low]^.ID - 12);
  Before := TotalPoints;
  DailyMaintenance(DB, Cfg, Rep);
  Check('decay takes 2% above the floor', (TotalPoints = Before) and (Rep.ProtectionUsed = 0) and
    (DB.Profiles[a]^.Points < 1500));
  Cfg.InactivityMode := 'protection';

  { a protection day is used only when it spares points: an inactive account at the floor would
    pay nothing anyway, and it keeps its days }
  FreshDB(T0);
  for i := 1 to 100 do
    Mk('Act' + IntToStr(i), 1000, 0);
  a := Mk('AtFloor', Cfg.BalanceFloorPoints, 40);
  DB.Profiles[a]^.ProtectionDays := 5;
  c := Mk('Above', Cfg.BalanceFloorPoints + 500, 40);
  DB.Profiles[c]^.ProtectionDays := 5;
  DailyMaintenance(DB, Cfg, Rep);
  Check('an inactive account at the floor keeps its protection days and pays nothing',
    (DB.Profiles[a]^.ProtectionDays = 5) and (DB.Profiles[a]^.Points = Cfg.BalanceFloorPoints) and
    (DB.Profiles[c]^.ProtectionDays = 4) and (DB.Profiles[c]^.Points = Cfg.BalanceFloorPoints + 500) and
    (Rep.ProtectionUsed = 1));
  { the engine runs the balance once a day (Server.LastBalanceDay); run twice here, the day is
    still used only once per run }
  DailyMaintenance(DB, Cfg, Rep);
  Check('every run uses one day of an account above the floor, none of one at the floor',
    (DB.Profiles[a]^.ProtectionDays = 5) and (DB.Profiles[c]^.ProtectionDays = 3));

  FreshDB(T0);
  Cfg.CheckPointsEnabled := True;
  for i := 1 to 10 do
    Mk('Def' + IntToStr(i), 900, 0);
  DailyMaintenance(DB, Cfg, Rep);
  Check('deficit paid gently to active players', (Rep.CheckPaid = 250) and (TotalPoints = 9250));
  FreshDB(T0);
  for i := 1 to 5 do
    Mk('Old' + IntToStr(i), 3000, 60);
  for i := 1 to 5 do
    Mk('New' + IntToStr(i), 1000, 0);
  DailyMaintenance(DB, Cfg, Rep);
  Check('surplus taken back from inactive accounts', (Rep.CheckTaken = 250) and (TotalPoints = 19750));
  { protection days spare an inactive account from the correction too; the surplus then waits }
  FreshDB(T0);
  for i := 1 to 5 do
  begin
    a := Mk('Kept' + IntToStr(i), 3000, 60);
    DB.Profiles[a]^.ProtectionDays := 5;
  end;
  for i := 1 to 5 do
    Mk('Now' + IntToStr(i), 1000, 0);
  DailyMaintenance(DB, Cfg, Rep);
  Check('protected accounts keep their points, the surplus waits', (Rep.CheckTaken = 0) and
    (Rep.CheckWaiting = 10000) and (TotalPoints = 20000));
  a := Mk('Unprotected', 3000, 60);
  DailyMaintenance(DB, Cfg, Rep);
  Check('an account without protection days pays the correction', (Rep.CheckTaken = 50) and
    (DB.Profiles[a]^.Points = 2950));
  { the day an account uses its last protection day it is still protected from the correction }
  FreshDB(T0);
  for i := 1 to 90 do
    Mk('Here' + IntToStr(i), 1000, 0);
  for i := 1 to 10 do
  begin
    a := Mk('Last' + IntToStr(i), 3000, 60);
    DB.Profiles[a]^.ProtectionDays := 1;
  end;
  DailyMaintenance(DB, Cfg, Rep);
  Check('the last protection day protects from the correction too', (Rep.ProtectionUsed = 10) and
    (DB.Profiles[a]^.ProtectionDays = 0) and (DB.Profiles[a]^.Points = 3000) and (Rep.CheckTaken = 0) and
    (Rep.CheckWaiting = 20000));
  { a surplus smaller than the accounts is still taken, a point each from the richest }
  FreshDB(T0);
  Cfg.InactivityMode := 'none';
  for i := 1 to 200 do
    Mk('Idle' + IntToStr(i), 1300, 60);
  for i := 1 to 99 do
    Mk('Poor' + IntToStr(i), 400, 0);
  Mk('Poor100', 460, 0);
  Before := TotalPoints;
  DailyMaintenance(DB, Cfg, Rep);
  WriteLn(Format('       small surplus: %d taken, %d waiting', [Rep.CheckTaken, Rep.CheckWaiting]));
  Check('a small surplus over many accounts is taken all the same', (Rep.CheckTaken = 60) and
    (Rep.CheckWaiting = 0) and (TotalPoints = Before - 60));
  Cfg.InactivityMode := 'protection';

  { a surplus nobody may give waits CheckPointsMaxWaitDays, then the account that played longest
    ago gives it, protection or not }
  Cfg.CheckPointsMaxWaitDays := 3;
  FreshDB(T0);
  a := Mk('Oldest', 1040, 200);
  DB.Profiles[a]^.ProtectionDays := 30;
  c := Mk('Older', 1040, 100);
  DB.Profiles[c]^.ProtectionDays := 30;
  for i := 1 to 3 do
    Mk('Here' + IntToStr(i), 980, 0);
  Ok := True;
  for i := 0 to 2 do
  begin
    DB.SetNow(T0 + i);
    DailyMaintenance(DB, Cfg, Rep);
    Ok := Ok and (Rep.CheckTaken = 0) and (Rep.CheckForced = 0) and (Rep.CheckWaiting = 20) and (Rep.CheckWaitDays = i);
  end;
  Check('the surplus waits while every inactive account is protected', Ok and (DB.Server.CheckWaitSince = T0));
  DB.SetNow(T0 + 3);
  DailyMaintenance(DB, Cfg, Rep);
  Check('after CheckPointsMaxWaitDays the least active account gives it', (Rep.CheckForced = 20) and
    (Rep.CheckWaiting = 0) and (DB.Profiles[a]^.Points = 1020) and (DB.Profiles[c]^.Points = 1040) and
    (DB.Server.CheckWaitSince = 0) and (TotalPoints = 5000));
  Cfg.CheckPointsMaxWaitDays := 0;
  FreshDB(T0);
  a := Mk('Oldest', 1040, 200);
  DB.Profiles[a]^.ProtectionDays := 30;
  for i := 1 to 3 do
    Mk('Here' + IntToStr(i), 1000, 0);
  DailyMaintenance(DB, Cfg, Rep);
  DB.SetNow(T0 + 20);
  DailyMaintenance(DB, Cfg, Rep);
  Check('CheckPointsMaxWaitDays = 0 lets the surplus wait', (Rep.CheckForced = 0) and (Rep.CheckWaiting = 40) and
    (Rep.CheckWaitDays = 20) and (DB.Profiles[a]^.Points = 1040));
  Cfg.CheckPointsMaxWaitDays := 14;

  FreshDB(T0);
  Cfg.SeasonsEnabled := True;
  Check('first season is due', SeasonDue(DB, Cfg));
  StartSeason(DB, Cfg);
  Check('season dates', (DB.Server.SeasonId = 1) and (DB.Server.SeasonEnd = EncodeDate(2026, 10, 1)) and not SeasonDue(DB, Cfg));
  for i := 0 to 3 do
  begin
    Players[i] := Mk('S' + IntToStr(i), 1000, 0);
    AddActivity(DB, Players[i], GS_CTF, 10 * i, 5, 0, 0, 0, 0, 0, 3600);
    AddPoints(DB, Players[i], 10 * (i + 1), 0);
  end;
  Check('season ranking', (DB.Ranks[RANK_SEASON].Count = 4) and (DB.Ranks[RANK_SEASON].At(1) = Players[3]));
  DB.SetNow(EncodeDate(2026, 10, 1) + EncodeTime(0, 1, 0, 0));
  Check('season ends on the first of the month', SeasonDue(DB, Cfg));
  a := ArchiveSeason(DB, Cfg);
  StartSeason(DB, Cfg);
  Check('archive top list', (a = 0) and (Length(DB.Seasons) = 1) and (Length(DB.Seasons[0].Entries) = 4) and
    (DB.Seasons[0].Entries[0].ProfileId = DB.Profiles[Players[3]]^.ID) and (DB.Seasons[0].Entries[0].SeasonPoints = 40));
  Check('badges for the podium', (Length(DB.Profiles[Players[3]]^.Badges) = 1) and
    (DB.Profiles[Players[3]]^.Badges[0].Place = 1) and (Length(DB.Profiles[Players[0]]^.Badges) = 0));
  Check('new season starts empty', (DB.Server.SeasonId = 2) and (DB.Ranks[RANK_SEASON].Count = 0));
  Check('every account starts the new season at zero at once', (DB.Profiles[Players[3]]^.SeasonId = 2) and
    (DB.Profiles[Players[3]]^.SeasonPoints = 0) and (DB.Profiles[Players[3]]^.SeasonKills = 0) and
    (DB.Profiles[Players[0]]^.SeasonTime = 0));

  a := Players[0];
  DB.Profiles[a]^.Kills := 100;
  Ach := CheckAchievements(DB, a, 50);
  Check('achievements unlock', (Length(Ach) = 2) and (Ach[0] = 1) and (Ach[1] = 2));
  Check('achievements unlock once', Length(CheckAchievements(DB, a, 50)) = 0);
  { Rampage and Godlike are the streak levels of the same name in [Sprees] }
  SetConfigDefaults(Cfg2);
  SetStreakAchievements(Cfg2);
  Check('the Rampage achievement follows the Rampage level of [Sprees] (5 kills by default)',
    (AchievementDefs[10].Info = '5 kills in a row') and (AchievementDefs[11].Info = '25 kills in a row'));
  DB.Profiles[Players[1]]^.SpreeLives[5] := 1;
  if DB.Profiles[Players[1]]^.MaxKillStreak < 5 then
    DB.Profiles[Players[1]]^.MaxKillStreak := 5;
  Ach := CheckAchievements(DB, Players[1], 50);
  Ok := False;
  for i := 0 to High(Ach) do
    if Ach[i] = 10 then
      Ok := True;
  Check('a 5-kill streak earns Rampage when the Rampage level is at 5', Ok);
  Cfg2.SpreeLevelCount := 0;
  SetStreakAchievements(Cfg2);
  Check('without such a level Rampage is 10 kills and Godlike 25',
    (AchievementDefs[10].Info = '10 kills in a row') and (AchievementDefs[11].Info = '25 kills in a row'));
  Ach := CheckAchievements(DB, Players[3], 50);
  Check('season winner gets Champion', (Length(Ach) >= 1) and (Ach[High(Ach)] = 50));
  Ok := True;
  for i := 1 to ACH_COUNT do
    if (AchievementDefs[i].Id <> i) or (Length(AchievementDefs[i].Name) > 15) or (Length(AchievementDefs[i].Info) > 19) or
       (AchievementDefs[i].Info = '') then
    begin
      WriteLn('       achievement ', i, ': "', AchievementDefs[i].Name, '" / "', AchievementDefs[i].Info, '"');
      Ok := False;
    end;
  Check('50 achievements, each fits one !achlist cell', (ACH_COUNT = 50) and Ok);
  Check('the streak achievements name their kills (here without a Rampage or Godlike level)',
    (AchievementDefs[10].Info = '10 kills in a row') and (AchievementDefs[11].Info = '25 kills in a row') and
    (AchievementDefs[28].Info = '100 5-kill streaks'));

  FreshDB(T0);
  Cfg.SeasonPointsReset := 'soft';
  Cfg.SeasonSoftFactor := 0.5;
  a := Mk('Veteran', 1600, 0);
  StartSeason(DB, Cfg);
  Check('first season keeps the points', DB.Profiles[a]^.Points = 1600);
  DB.SetNow(DB.Server.SeasonEnd + 1 / 1440);
  ArchiveSeason(DB, Cfg);
  StartSeason(DB, Cfg);
  Check('soft reset keeps SoftResetFactor of the distance to the start', DB.Profiles[a]^.Points = 1300);
  Cfg.SeasonPointsReset := 'none';

  FreshDB(T0);
  for i := 0 to 2 do
    Players[i] := Mk('F' + IntToStr(i), 1000, 0);
  RateFFA(DB, Cfg, RF_FFA, [Players[0], Players[1], Players[2]], [10, 5, 1]);
  Check('ffa glicko order', (DB.Profiles[Players[0]]^.Glicko[RF_FFA].R > 1500) and
    (DB.Profiles[Players[2]]^.Glicko[RF_FFA].R < 1500) and (DB.Profiles[Players[0]]^.Glicko[RF_FFA].Games = 1));
  Check('ffa openskill order', (OpenSkillOrdinal(DB.Profiles[Players[0]]^.OpenSkill[RF_FFA]) >
    OpenSkillOrdinal(DB.Profiles[Players[1]]^.OpenSkill[RF_FFA])) and
    (DB.Profiles[Players[1]]^.OpenSkill[RF_FFA].Mu > DB.Profiles[Players[2]]^.OpenSkill[RF_FFA].Mu));
  Players[3] := Mk('F3', 1000, 0);
  RateTeams(DB, Cfg, RF_CTF, Players, [1, 1, 2, 2], [5, 2, 0, 0]);
  Check('team ratings follow the result', (DB.Profiles[Players[0]]^.Glicko[RF_CTF].R > DB.Profiles[Players[2]]^.Glicko[RF_CTF].R) and
    (DB.Profiles[Players[1]]^.OpenSkill[RF_CTF].Mu > DB.Profiles[Players[3]]^.OpenSkill[RF_CTF].Mu));

  { an account without an MMR (0) is the start value to the others, not a pushover: the one in the
    middle, second of three, neither gains nor loses }
  FreshDB(T0);
  for i := 0 to 2 do
    Players[i] := Mk('Z' + IntToStr(i), 1000, 0);
  DB.Profiles[Players[0]]^.Mmr[RF_FFA].R := 0;
  RateFFA(DB, Cfg, RF_FFA, [Players[0], Players[1], Players[2]], [10, 5, 1]);
  Check('ffa: an account without an MMR counts with the start value',
    (Abs(DB.Profiles[Players[0]]^.Mmr[RF_FFA].R - (DB.MmrStart + 30)) < 0.01) and
    (Abs(DB.Profiles[Players[1]]^.Mmr[RF_FFA].R - DB.MmrStart) < 0.01) and (DB.Profiles[Players[0]]^.Mmr[RF_FFA].Games = 1));

  GlickoInit(G, 1500, 50, 0.06);
  G.Games := 10;
  G.LastUpdate := T0 - 30;
  GlickoCatchUp(G, T0);
  Check('glicko-2 deviation grows after 30 days without a match', (G.RD > 70) and (G.RD < 80));
  GlickoInit(G, 1500, 50, 0.06);
  G.Games := 10;
  G.LastUpdate := T0 - 0.5;
  GlickoCatchUp(G, T0);
  Check('glicko-2 deviation unchanged on the same day', G.RD = 50);
  G.Games := 0;
  G.LastUpdate := T0 - 30;
  GlickoCatchUp(G, T0);
  Check('unrated glicko-2 state is left alone', G.RD = 50);

  Ok := PerformanceRating(DB.Profiles[Players[0]]^, GS_CTF, False, False, 'gamemode') >= 1;
  Check('performance rating', Ok);
  if Cfg.RankTierCount > 0 then
  begin
    DB.Profiles[Players[0]]^.Points := 99999;
    Top := TierIndex(Cfg, DB.Profiles[Players[0]]^, 1000, RF_CTF, RS_ELO);
    Check('tiers', (Top >= 0) and (TierIndex(Cfg, DB.Profiles[Players[1]]^, 1, RF_CTF, RS_ELO) >= Top));
    { the case of the screenshot: more points and a lower Rating than the next player }
    DB.Profiles[Players[0]]^.Points := 1346;
    DB.Profiles[Players[1]]^.Points := 1270;
    Cfg.TierBy := 'points';
    Check('tier by points: a higher place never has a lower tier',
      TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO) <=
      TierIndex(Cfg, DB.Profiles[Players[1]]^, 30.0, RF_CTF, RS_ELO));
    Cfg.TierBy := 'rating';
    Check('tier by rating follows the Rating', TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO) >
      TierIndex(Cfg, DB.Profiles[Players[1]]^, 30.0, RF_CTF, RS_ELO));
    Cfg.TierBy := 'both';
    Check('tier by both needs the points and the Rating', TierIndex(Cfg, DB.Profiles[Players[1]]^, 30.0, RF_CTF, RS_ELO) = 4);
    { any rating: the MMR of the family of the game mode against MinMMR }
    DB.Profiles[Players[0]]^.Mmr[RF_CTF].R := 2150;
    DB.Profiles[Players[1]]^.Mmr[RF_CTF].R := 1000;
    Cfg.TierBy := 'mmr';
    Check('tier by mmr follows the MMR', (TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO) = 0) and
      (TierIndex(Cfg, DB.Profiles[Players[1]]^, 30.0, RF_CTF, RS_ELO) = Cfg.RankTierCount - 1));
    Cfg.RankTiers[0].MinMmr := -100000;
    Check('a tier line without the MMR limit is skipped', TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO) = 1);
    Cfg.RankTiers[0].MinMmr := 2100;
    Cfg.TierBy := 'rating';
    R0 := Cfg.RankTiers[0].MinRating;
    Cfg.RankTiers[0].MinRating := -100000;
    Check('a tier line without the rating limit is skipped as well', TierIndex(Cfg, DB.Profiles[Players[0]]^, 1000, RF_CTF,
      RS_ELO) = 1);
    Cfg.RankTiers[0].MinRating := R0;
    Check('with the limit back the line counts again', TierIndex(Cfg, DB.Profiles[Players[0]]^, 1000, RF_CTF, RS_ELO) = 0);
    Cfg.TierBy := 'points';
    TierP := TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO);
    Cfg.TierBy := 'rating';
    TierR := TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO);
    Cfg.TierBy := 'all';
    Top := TierIndex(Cfg, DB.Profiles[Players[0]]^, 27.7, RF_CTF, RS_ELO);
    WriteLn(Format('       tiers of the same player: points %d, rating %d, all %d', [TierP, TierR, Top]));
    Check('tier by all needs every limit of the line', (Top >= TierP) and (Top >= TierR) and (Top > 0));
    Cfg.TierBy := 'points';
  end;

  { the skill index: only how someone plays }
  FreshDB(T0);
  a := Mk('Skilled', 1000, 0);
  c := Mk('Rich', 5000, 0);
  for i := 0 to 1 do
  begin
    if i = 0 then Top := a else Top := c;
    DB.Profiles[Top]^.Kills := 2000;
    DB.Profiles[Top]^.Deaths := 1000;
    DB.Profiles[Top]^.Shots := 10000;
    DB.Profiles[Top]^.ShotsHits := 4000;
    DB.Profiles[Top]^.ShotsHitsHead := 800;
    DB.Profiles[Top]^.Wins := 60;
    DB.Profiles[Top]^.Loses := 40;
  end;
  Check('skill rating ignores the points balance', Abs(SkillRating(DB.Profiles[a]^, GS_DM, False, False) -
    SkillRating(DB.Profiles[c]^, GS_DM, False, False)) < 0.001);
  Check('the gamemode rating still follows the points',
    PerformanceRating(DB.Profiles[c]^, GS_DM, False, False, 'gamemode') >
    PerformanceRating(DB.Profiles[a]^, GS_DM, False, False, 'gamemode') * 4);
  Low := Mk('Fresh', 1000, 0);
  DB.Profiles[Low]^.Kills := 10;
  DB.Profiles[Low]^.Shots := 12;
  DB.Profiles[Low]^.ShotsHits := 12;
  DB.Profiles[Low]^.ShotsHitsHead := 12;
  DB.Profiles[Low]^.Wins := 3;
  Check('a short lucky series stays below a long career',
    SkillRating(DB.Profiles[Low]^, GS_DM, False, False) < SkillRating(DB.Profiles[a]^, GS_DM, False, False));
  Check('the confidence bound needs a sample', (WilsonLower(3, 3) < WilsonLower(300, 300)) and
    (WilsonLower(300, 300) < 1.0) and (WilsonLower(0, 100) = 0));

  { leagues }
  Cfg.LeaguesEnabled := True;
  Cfg.LeagueSource := 'rating';
  Cfg.LeaguePlacementMatches := 2;
  Cfg.LeagueDivisions := 5;
  Cfg.LeaguePercents := '10,30,60,80,90,95';
  FreshDB(T0);
  for i := 0 to 99 do
  begin
    Top := Mk('L' + IntToStr(i), 1000, 0);
    DB.Profiles[Top]^.Kills := 1000 + i * 20;
    DB.Profiles[Top]^.Deaths := 1000;
    DB.Profiles[Top]^.Shots := 10000;
    DB.Profiles[Top]^.ShotsHits := 3000 + i * 10;
    DB.Profiles[Top]^.Wins := 10;
    DB.Profiles[Top]^.Loses := 10;
  end;
  Low := Mk('Rookie', 1000, 0);
  UpdateLeagues(DB, Cfg);
  Ach := DB.IndexesOfName('L99');
  a := Ach[0];
  Ach := DB.IndexesOfName('L0');
  c := Ach[0];
  Check('the best account reaches the top league', (DB.Profiles[a]^.LeagueTier = 1) and
    (DB.Profiles[a]^.LeagueDivision >= 1) and (DB.Profiles[a]^.LeagueDivision <= Cfg.LeagueDivisions));
  Check('the weakest account is further down', DB.Profiles[c]^.LeagueTier > DB.Profiles[a]^.LeagueTier);
  Check('an account without matches is not placed', DB.Profiles[Low]^.LeagueTier = 0);

  { leagues from MMR, the Heroes of the Storm way }
  Cfg.LeagueSource := 'mmr';
  FreshDB(T0);
  for i := 0 to 49 do
  begin
    Top := Mk('Q' + IntToStr(i), 1000, 0);
    DB.Profiles[Top]^.Mmr[RF_TEAM].R := 1000 + i * 20;
    DB.Profiles[Top]^.Mmr[RF_TEAM].Games := 5;
  end;
  UpdateLeagues(DB, Cfg);
  Ach := DB.IndexesOfName('Q49');
  a := Ach[0];
  Ach := DB.IndexesOfName('Q0');
  c := Ach[0];
  Check('mmr leagues follow the match rating of the main mode family', (DB.Profiles[a]^.LeagueTier = 1) and
    (DB.Profiles[c]^.LeagueTier > DB.Profiles[a]^.LeagueTier) and (MainFamily(DB.Profiles[a]^) = RF_TEAM) and
    (LeagueGames(Cfg, DB.Profiles[a]^) = 5));
  { the leagues are the tiers: a [Ranks] without tiers leaves no league behind }
  Top := Cfg.RankTierCount;
  Cfg.RankTierCount := 0;
  UpdateLeagues(DB, Cfg);
  Cfg.RankTierCount := Top;
  Check('without tiers no account keeps a league', (DB.Profiles[a]^.LeagueTier = 0) and
    (DB.Profiles[a]^.LeagueDivision = 0) and (DB.Profiles[a]^.LeaguePromille = 0) and (DB.Profiles[c]^.LeagueTier = 0));

  { MMR: the strength of the side you beat decides how much the rating moves }
  FreshDB(T0);
  for i := 0 to 3 do
    Players[i] := Mk('M' + IntToStr(i), 1000, 0);
  DB.Profiles[Players[0]]^.Mmr[RF_TEAM].R := 1400;
  DB.Profiles[Players[1]]^.Mmr[RF_TEAM].R := 1400;
  DB.Profiles[Players[2]]^.Mmr[RF_TEAM].R := 1800;
  DB.Profiles[Players[3]]^.Mmr[RF_TEAM].R := 1800;
  DB.MmrPlacement := 0;
  RateTeams(DB, Cfg, RF_TEAM, Players, [1, 1, 2, 2], [5, 2, 0, 0]);
  Check('mmr rises for the winner and falls for the loser',
    (DB.Profiles[Players[0]]^.Mmr[RF_TEAM].R > 1400) and (DB.Profiles[Players[2]]^.Mmr[RF_TEAM].R < 1800));
  Check('every rating method is updated by the same match',
    (DB.Profiles[Players[0]]^.Mmr[RF_TEAM].Games = 1) and (DB.Profiles[Players[0]]^.Glicko[RF_TEAM].Games = 1) and
    (DB.Profiles[Players[0]]^.OpenSkill[RF_TEAM].Games = 1));
  Gain := Round(DB.Profiles[Players[0]]^.Mmr[RF_TEAM].R - 1400);

  FreshDB(T0);
  for i := 0 to 3 do
    Players[i] := Mk('N' + IntToStr(i), 1000, 0);
  for i := 0 to 3 do
    DB.Profiles[Players[i]]^.Mmr[RF_TEAM].R := 1400;
  DB.MmrPlacement := 0;
  RateTeams(DB, Cfg, RF_TEAM, Players, [1, 1, 2, 2], [5, 2, 0, 0]);
  Check('beating a stronger team is worth more',
    Round(DB.Profiles[Players[0]]^.Mmr[RF_TEAM].R - 1400) < Gain);

  FreshDB(T0);
  for i := 0 to 3 do
    Players[i] := Mk('P' + IntToStr(i), 1000, 0);
  DB.MmrPlacement := 10;
  RateTeams(DB, Cfg, RF_TEAM, Players, [1, 1, 2, 2], [5, 2, 0, 0]);
  Check('placement matches move the rating faster',
    DB.Profiles[Players[0]]^.Mmr[RF_TEAM].R - 1500 > 20);

  { partial play: Q4 played half of the match for the winners and half for the losers }
  FreshDB(T0);
  for i := 0 to 4 do
    Q[i] := Mk('Q' + IntToStr(i), 1000, 0);
  DB.MmrPlacement := 0;
  RateTeams(DB, Cfg, RF_TEAM, [Q[0], Q[1], Q[2], Q[3], Q[4], Q[4]], [1, 1, 2, 2, 1, 2],
    [1, 1, 1, 1, 0.5, 0.5], [5, 2, 0, 0]);
  WriteLn(Format('       partial play: MMR %s, Glicko %s, OpenSkill mu %s', [FloatToStr(DB.Profiles[Q[4]]^.Mmr[RF_TEAM].R),
    FloatToStr(DB.Profiles[Q[4]]^.Glicko[RF_TEAM].R), FloatToStr(DB.Profiles[Q[4]]^.OpenSkill[RF_TEAM].Mu)]));
  Check('half a win and half a loss leave the rating where it was',
    (Abs(DB.Profiles[Q[4]]^.Mmr[RF_TEAM].R - 1500) < 0.01) and (Abs(DB.Profiles[Q[4]]^.Glicko[RF_TEAM].R - 1500) < 0.5) and
    (Abs(DB.Profiles[Q[4]]^.OpenSkill[RF_TEAM].Mu - DB.SkillMu) < 0.05));
  Check('a match played for two teams is still one rated match',
    (DB.Profiles[Q[4]]^.Mmr[RF_TEAM].Games = 1) and (DB.Profiles[Q[4]]^.Glicko[RF_TEAM].Games = 1) and
    (DB.Profiles[Q[4]]^.OpenSkill[RF_TEAM].Games = 1));
  Check('the winners still gain', (DB.Profiles[Q[0]]^.Mmr[RF_TEAM].R > 1500) and (DB.Profiles[Q[2]]^.Mmr[RF_TEAM].R < 1500));

  { a match with every rated player in one team is not rated, and it leaves the Glicko-2 state as
    it was: the 30 days since the last rated match count once, at the next one }
  FreshDB(T0);
  for i := 0 to 3 do
  begin
    Players[i] := Mk('G' + IntToStr(i), 1000, 0);
    GlickoInit(DB.Profiles[Players[i]]^.Glicko[RF_TEAM], 1500, 50, 0.06);
    DB.Profiles[Players[i]]^.Glicko[RF_TEAM].Games := 10;
    DB.Profiles[Players[i]]^.Glicko[RF_TEAM].LastUpdate := T0 - 30;
  end;
  RateTeams(DB, Cfg, RF_TEAM, [Players[0], Players[1]], [1, 1], [5, 2, 0, 0]);
  Check('a match that is not rated leaves the rating state alone',
    (DB.Profiles[Players[0]]^.Glicko[RF_TEAM].RD = 50) and (DB.Profiles[Players[0]]^.Glicko[RF_TEAM].Games = 10) and
    (DB.Profiles[Players[0]]^.Mmr[RF_TEAM].Games = 0));
  RateTeams(DB, Cfg, RF_TEAM, Players, [1, 1, 2, 2], [5, 2, 0, 0]);
  { the 30 idle days alone, counted once }
  GlickoInit(G, 1500, 50, 0.06);
  G.Games := 10;
  G.LastUpdate := T0 - 30;
  GlickoCatchUp(G, T0);
  WriteLn(Format('       glicko-2 after 30 idle days and a rated match: RD %s (the idle days alone: %s)',
    [FloatStr(DB.Profiles[Players[0]]^.Glicko[RF_TEAM].RD, 1), FloatStr(G.RD, 1)]));
  Check('the idle days count once: the rated match after them lowers the deviation they raised',
    (DB.Profiles[Players[0]]^.Glicko[RF_TEAM].Games = 11) and (DB.Profiles[Players[0]]^.Glicko[RF_TEAM].RD < G.RD));

  { what a kill costs the always-current rankings with 3000 accounts: a changed account moves past
    the neighbours it overtakes (TRankList.Update), nothing is sorted again }
  FreshDB(T0);
  RandSeed := 4242;
  for i := 0 to 2999 do
    Mk('R' + IntToStr(i), 700 + Random(900), Random(20));
  T1 := MicroNow;
  for i := 1 to 20000 do
  begin
    a := Random(3000);
    c := Random(3000);
    if a = c then
      Continue;
    Gain := KillPoints(Cfg, DB.Profiles[a]^.Points, DB.Profiles[c]^.Points, False, 0);
    AddPoints(DB, c, -Gain, Cfg.MinimumPoints);
    AddPoints(DB, a, Gain, Cfg.MinimumPoints);
    AddActivity(DB, a, GS_DM, 1, 0, 0, 0, 0, 0, 0, 0);
    AddActivity(DB, c, GS_DM, 0, 1, 0, 0, 0, 0, 0, 0);
  end;
  T1 := MicroNow - T1;
  T2 := MicroNow;
  for i := 1 to 20 do
    DB.RebuildRanks;
  T2 := (MicroNow - T2) div 20;
  WriteLn(Format('       3000 accounts: %.2f us per kill (points, both rankings, periods); a full re-sort %.2f ms',
    [T1 / 20000, T2 / 1000]));
  Ok := DB.Ranks[RANK_POINTS].Count = 3000;
  for i := 1 to DB.Ranks[RANK_POINTS].Count - 1 do
    if DB.Profiles[DB.Ranks[RANK_POINTS].At(i)]^.Points < DB.Profiles[DB.Ranks[RANK_POINTS].At(i + 1)]^.Points then
      Ok := False;
  Check('after 20000 kills the ranking is still in order', Ok);
  Check('a kill costs far less than sorting the accounts again', T1 / 20000 < T2 / 10);

  DB.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
