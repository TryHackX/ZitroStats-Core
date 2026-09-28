program test_cmd_core;

{ The core commands (zs_commands, zs_cmd_profile, zs_cmd_server) through the engine: every line
  fits LINE_W, the columns start where they should, big counters are shortened, the rows follow
  the game mode, !server takes its damage from one source, and the dispatcher answers - the weapon
  commands under both spellings, wep and weap. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_db, zs_engine, zs_commands;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Console: TStringList;

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

procedure DeleteTree(const Dir: AnsiString);
var
  SR: TSearchRec;
  P: AnsiString;
begin
  if not DirectoryExists(Dir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure Push(Ev: TZSEvent);
begin
  Ev.Tick := CurTick;
  Engine.PushEvent(Ev);
  Inc(Pushed);
end;

function WaitProcessed: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while Engine.Processed < Pushed do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Sleep(150);
  Result := True;
end;

function WaitReady: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while not Engine.IsReady do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Result := True;
end;

procedure DrainActions;
var
  A: TZSAction;
begin
  while Engine.PopAction(A) do
    Console.Add(Format('%d|%d|%s', [A.Kind, A.Slot, A.Text]));
end;

{ the text of a console entry "kind|slot|text" }
function TextOf(const Entry: AnsiString): AnsiString;
var
  p: LongInt;
begin
  Result := Entry;
  p := Pos('|', Result);
  Delete(Result, 1, p);
  p := Pos('|', Result);
  Delete(Result, 1, p);
end;

function KindOf(const Entry: AnsiString): LongInt;
begin
  Result := StrToIntDef(Copy(Entry, 1, Pos('|', Entry) - 1), -1);
end;

function SeenCount(const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to Console.Count - 1 do
    if Pos(Part, Console[k]) > 0 then
      Inc(Result);
end;

function Seen(const Part: AnsiString): Boolean;
begin
  Result := SeenCount(Part) > 0;
end;

{ the text of the last line that contains Part }
function LineWith(const Part: AnsiString): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := Console.Count - 1 downto 0 do
    if Pos(Part, Console[k]) > 0 then
      Exit(TextOf(Console[k]));
end;

{ the lines of the last answer whose header holds Title, up to its footer (a line of '=' only) }
function Block(const Title: AnsiString): TStringList;
var
  k, From: LongInt;
  T: AnsiString;
begin
  Result := TStringList.Create;
  From := -1;
  for k := Console.Count - 1 downto 0 do
    if (Pos(Title, Console[k]) > 0) and (Pos('==', Console[k]) > 0) then
    begin
      From := k;
      Break;
    end;
  if From < 0 then
    Exit;
  for k := From to Console.Count - 1 do
  begin
    T := TextOf(Console[k]);
    Result.Add(T);
    if (k > From) and (T <> '') and (T = StringOfChar('=', Length(T))) then
      Break;
  end;
end;

function CountIn(L: TStringList; const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to L.Count - 1 do
    if Pos(Part, L[k]) > 0 then
      Inc(Result);
end;

function LineIn(L: TStringList; const Part: AnsiString): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := 0 to L.Count - 1 do
    if Pos(Part, L[k]) > 0 then
      Exit(L[k]);
end;

{ every console line of the commands fits LINE_W }
function AllFit(out Worst: AnsiString): Boolean;
var
  k: LongInt;
  T: AnsiString;
begin
  Result := True;
  Worst := '';
  for k := 0 to Console.Count - 1 do
    if KindOf(Console[k]) in [ACT_CONSOLE, ACT_WRITELN] then
    begin
      T := TextOf(Console[k]);
      if Length(T) > LINE_W then
      begin
        if Result then
          Worst := Format('(%d) %s', [Length(T), T]);
        Result := False;
      end;
    end;
end;

procedure MapAfter(const Name: AnsiString; Style, Flags: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := 10;
  Ev.I[3] := Flags;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Team: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := Hwid;
  Ev.S4 := IP;
  Ev.I[0] := Team;
  Ev.I[1] := 1;
  Ev.I[2] := 0;
  Push(Ev);
end;

procedure Cmd(Slot: LongInt; const Text: AnsiString; Source, Admin: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  Ev.I[0] := Source;
  Ev.I[1] := Admin;
  Push(Ev);
end;

{ a console command, answered on the server console }
procedure Run(const Text: AnsiString);
begin
  Cmd(0, Text, SRC_CONSOLE, 1);
end;

function Prof(Slot: LongInt): PPlayerProfile;
var
  Idx: LongInt;
begin
  Idx := Engine.Identity.ProfileIndex(Slot);
  if Engine.DB.Valid(Idx) then
    Result := Engine.DB.Profiles[Idx]
  else
    Result := nil;
end;

{ everything a console command writes, alone }
function Answer(const Text: AnsiString): AnsiString;
begin
  Console.Clear;
  Run(Text);
  WaitProcessed;
  DrainActions;
  Result := Console.Text;
end;

{ wep or weap: every weapon command takes both spellings, and answers the same }
procedure WeapAliases;
const
  PAIRS: array[0..12, 0..1] of AnsiString = (
    ('/mapweap ak rscs_test', '/mapwep ak rscs_test'),
    ('/serverweap ak', '/serverwep ak'),
    ('/srvweap ak', '/serverwep ak'),
    ('/serverweaps', '/serverweapons'),
    ('/srvweaps', '/serverweapons'),
    ('/serverweapsby kills', '/serverweaponsby kills'),
    ('/srvweapsby kills', '/serverweaponsby kills'),
    ('/topweaps ak', '/topweapons ak'),
    ('/topweapsby kills', '/topweaponsby kills'),
    ('/mapwepstats rscs_test', '/mapweapstats rscs_test'),
    ('/mapwepsstats rscs_test', '/mapweapstats rscs_test'),
    ('/mapplayerwepstats rscs_test alice', '/mapplayerweapstats rscs_test alice'),
    ('/mapplayerwepstatsi rscs_test 1', '/mapplayerweapstatsi rscs_test 1'));
var
  k: LongInt;
  Mine, Theirs, Word: AnsiString;
begin
  for k := 0 to High(PAIRS) do
  begin
    Word := Copy(PAIRS[k, 0], 1, Pos(' ', PAIRS[k, 0] + ' ') - 1);
    Theirs := Answer(PAIRS[k, 1]);
    Mine := Answer(PAIRS[k, 0]);
    Check(Format('%s is %s: a ZitroStats command with the same answer', [PAIRS[k, 0], PAIRS[k, 1]]),
      IsZitroCommand(Word) and IsZitroCommand('!' + Copy(Word, 2, MaxInt)) and (Theirs <> '') and (Mine = Theirs));
  end;
end;

var
  Root, Worst, L: AnsiString;
  A, B, D: PPlayerProfile;
  Blk: TStringList;
  M: LongInt;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'cmdcore_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Console := TStringList.Create;

  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);

  { the owner's server: realistic survival deathmatch with friendly fire on }
  CurTick := 0;
  MapAfter('rscs_test', GS_DM, 1 or 2 or 8);
  Join(1, 'Alice', 'S2001', 'HWA', '1.1.1.1', TEAM_NONE);
  Join(2, 'Bob', 'S2002', 'HWB', '2.2.2.2', TEAM_NONE);
  { Carl has no Steam: his account waits for Steam (SteamAuthWaitSeconds), his help has passwords }
  Join(3, 'Carl', '', 'HWC', '3.3.3.3', TEAM_NONE);
  Join(4, 'Dave', 'S2004', 'HWD', '4.4.4.4', TEAM_NONE);
  Check('joins processed', WaitProcessed);
  DrainActions;
  { the settings warning of the missing settings.ini carries a path of any length }
  Console.Clear;

  EnterCriticalSection(Engine.StateLock);
  try
    A := Prof(1);
    B := Prof(2);
    D := Prof(4);
    Check('three accounts', (A <> nil) and (B <> nil) and (D <> nil));
    if (A <> nil) and (B <> nil) and (D <> nil) then
    begin
      { counters around every step of the shortened numbers }
      A^.Kills := 9999;
      A^.Deaths := 10000;
      A^.Selfkills := 99949;
      A^.Assist := 99950;
      A^.ShotsHits := 999499;
      A^.Shots := 999500;
      A^.ShotsHitsHead := 13800;
      A^.ShotsHitsBody := 20000;
      A^.ShotsHitsLeg := 1000;
      A^.Wins := 5;
      A^.Loses := 3;
      A^.RoundsWins := 12000;
      A^.RoundsLose := 800;
      A^.TimeAlive := 36000;
      A^.TimePlayed := 40000;
      A^.LastStand := 4;
      A^.ClutchesWon := 4;
      A^.FirstBloodCount := 7;
      A^.RoundFirstBloodCount := 12345;
      { the streaks: 5 and 10 kills from the counters of before the lengths were kept, 3 kills from
        the lengths, the best streak 12 }
      A^.SpreeKills := 40;
      A^.RampageKills := 9;
      A^.SpreeLives[3] := 55;
      A^.MaxKillStreak := 12;
      A^.SeasonKills := 112;
      A^.SeasonDeaths := 47;
      { the kits picked up, by kind, one of them past 10 000 and one past 99 999 }
      A^.KitPickups[0] := 3;
      A^.KitPickups[1] := 12345;
      A^.KitPickups[3] := 2;
      A^.KitPickups[4] := 1;
      A^.KitPickups[6] := 99999;
      { a 4.x import: the weapons hold the damage, the account total much less }
      A^.DamageDealt := 19100;
      A^.DamageReceived := 5000;
      A^.Weapons[WEP_AK74].Damage := 67700;
      A^.Weapons[WEP_AK74].Hits := 677;
      A^.Weapons[WEP_AK74].Kills := 50;
      A^.TopVictims[0].TargetPlayerID := B^.ID;
      A^.TopVictims[0].KillCount := 123456;
      SetLength(A^.Badges, 30);
      for M := 0 to 29 do
      begin
        A^.Badges[M].SeasonId := M + 1;
        A^.Badges[M].Place := 1 + M mod 3;
      end;
      { who came back: the accounts first seen since the daily record began (Bob, Dave), not
        the one brought over from before it (Alice) }
      if Length(Engine.DB.Server.Daily) = 0 then
        SetLength(Engine.DB.Server.Daily, 1);
      Engine.DB.Server.Daily[0].Day := DayKey(Now) - 10;
      A^.RegisterTime := Now - 400;
      A^.DaysPlayed := 1;
      B^.RegisterTime := Now - 3;
      B^.DaysPlayed := 2;
      D^.RegisterTime := Now - 2;
      D^.DaysPlayed := 1;
      { an hour of play on a Wednesday evening }
      Engine.DB.Server.WeekdayHour[3, 20] := 3600;
      Engine.DB.Server.HourlyActivity[20] := 3600;
      { a record of 4.x without its date and length }
      Engine.DB.Server.PeakOnlineCount := 50;
      Engine.DB.Server.PeakOnlineDate := 0;
      Engine.DB.Server.PeakOnlineDurationSec := 0;
      { the maps brought their matches along, the server count did not }
      M := Engine.DB.FindMap('rscs_test', False);
      if M >= 0 then
      begin
        Engine.DB.Maps[M].Kills := 300;
        Engine.DB.Maps[M].ActiveMapPlays := 10;
      end;
      Engine.DB.Server.TotalMatches := 0;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  Run('/stats alice');
  Run('/otherstats alice');
  Run('/status alice');
  Run('/session alice');
  Run('/rank alice');
  Run('/spree alice');
  Run('/rambo alice');
  Run('/achievements alice');
  Run('/achlist alice');
  Run('/server');
  Run('/activity');
  Run('/zs_status alice');
  Run('/help');
  Run('/switch');
  Run('/register a b');
  Run('/achlist nobodyhere');
  Run('/topid 30');
  Run('/statsi abc');
  Run('/statsi 0');
  Run('/ranki 999');
  Run('/sessioni 99999999999');
  Run('/achlisti 999');
  Cmd(2, '/mix', SRC_COMMAND, 0);
  Cmd(3, '!zitro', SRC_CHAT, 0);
  Check('commands processed', WaitProcessed);
  DrainActions;

  Check('every line of the answers fits LINE_W', AllFit(Worst));
  if Worst <> '' then
    WriteLn('       too wide: ', Worst);

  { !stats: the shortened counters and the columns of COLS3 }
  Blk := Block('[ Stats: Alice ]');
  try
    L := LineIn(Blk, 'Kills: ');
    Check('!stats: 9999 stays, 10000 is 10.0k', (Pos('Kills: 9999', L) = 1) and (Pos('Deaths: 10.0k', L) = COLS3[0] + 1) and
      (Pos('K/D Ratio: ', L) = COLS3[0] + COLS3[1] + 1));
    Check('!stats: 999 499 is 999k, 999 500 is 1.0M', Pos('Hits: 999k/1.0M', LineIn(Blk, 'Accuracy: ')) > 0);
    Check('!stats: head hits shortened', Pos('Headshots: 13.8k', LineIn(Blk, 'Accuracy: ')) > 0);
    Check('!stats: 99 950 is 100k, the assists once and in the damage row of a free-for-all mode',
      (CountIn(Blk, 'Assists: ') = 1) and (Pos('Assists: 100k', LineIn(Blk, 'Dealt: ')) > 0));
    Check('!stats: damage as kills is a count like any other', Pos('Dealt: 19.1k (~', LineIn(Blk, 'Dealt: ')) = 1);
    Check('!stats: survival deathmatch shows its rounds', Pos('Rounds: 12.0kW / 800L', LineIn(Blk, 'Matches: ')) > 0);
    Check('!stats: no flags, no teamkills and no team row on a deathmatch server',
      (CountIn(Blk, 'Flag Caps') = 0) and (CountIn(Blk, 'TK Dmg') = 0) and (CountIn(Blk, 'Teamkills') = 0) and
      (CountIn(Blk, 'First Blood') = 0));
    Check('!stats: the footer is LINE_W wide', (Blk.Count > 2) and (Blk[Blk.Count - 1] = StringOfChar('=', LINE_W)));
    Check('!stats: the season K/D as a ratio with the kills and deaths, in the columns of COLS3',
      Pos('Season K/D: 2.38 (112/47)', LineIn(Blk, 'Season K/D')) = COLS3[0] + 1);
    Check('!stats: no healing row without healing', CountIn(Blk, 'Healed: ') = 0);
  finally
    Blk.Free;
  end;

  { !otherstats: the feats of the mode, the revenge counted apart, the badges on more lines }
  Blk := Block('[ Detailed Telemetry: Alice ]');
  try
    Check('!otherstats: survival feats, no team feats on a deathmatch server',
      (CountIn(Blk, 'Last Stand: 4') = 1) and (CountIn(Blk, 'Clutches Won: 4') = 1) and (CountIn(Blk, 'Saviors') = 0) and
      (CountIn(Blk, 'Avenger') = 0) and (CountIn(Blk, 'Comeback') = 0));
    Check('!otherstats: revenge kills and ended dominations apart',
      (CountIn(Blk, 'Revenge Kills: ') = 1) and (CountIn(Blk, 'Dominations Ended: ') = 1) and (CountIn(Blk, 'Revenge Feats') = 0));
    Check('!otherstats: the draws say what they are', Pos('Win Rate: 62.5% (0 draws)', LineIn(Blk, 'Matches Won: ')) > 0);
    Check('!otherstats: a victim with its kills shortened', Pos('Fav Victims: Bob (123k)', LineIn(Blk, 'Fav Victims')) = 1);
    Check('!otherstats: thirty season badges over more lines', (CountIn(Blk, 'Season badges: ') = 1) and
      (Pos('S30 #3', Blk.Text) > 0));
    Check('!otherstats: no teamplay section without teamkills', CountIn(Blk, 'Teamplay & Friendly') = 0);
    Check('!otherstats: the healing row also at 0', Pos('Healed: 0 HP', LineIn(Blk, 'Healed: ')) = 1);
    Check('!otherstats: the kits that healed apart from the kits picked up',
      Pos('Heal Kits: 0 (0 HP)', LineIn(Blk, 'Healed: ')) = COLS3[0] + COLS3[1] + 1);
    Check('!otherstats: every kind of kit picked up in one row, the counters shortened',
      LineIn(Blk, 'Kits: Med') = 'Kits: Med 3, Nade 12.3k, Cluster 0, Vest 2, Berserk 1, Predator 0, Flamer 100k');
    Check('!otherstats: the season K/D as a ratio with the kills and deaths',
      Pos('Season K/D: 2.38 (112/47)', LineIn(Blk, 'Season K/D')) = COLS3[0] + 1);
    Check('!otherstats: the first bloods of the rounds next to those of the matches, shortened',
      (Pos('First Bloods: 7', LineIn(Blk, 'Max Streak: ')) = COLS3[0] + 1) and
      (Pos('Round First Bloods: 12.3k', LineIn(Blk, 'Max Streak: ')) = COLS3[0] + COLS3[1] + 1));
  finally
    Blk.Free;
  end;

  { !session: no captures in deathmatch, the rounds of survival, the rank in the last row }
  Blk := Block('Session Stats: Alice');
  try
    Check('!session: rounds but no captures in survival deathmatch', (CountIn(Blk, 'Caps: ') = 0) and
      (CountIn(Blk, 'Rounds Won: ') = 1) and (CountIn(Blk, 'Rank: ') = 1));
  finally
    Blk.Free;
  end;

  L := LineWith('[Rank] Alice');
  Check('!rank: one line of LINE_W at most, counters shortened', (L <> '') and (Length(L) <= LINE_W) and
    (Pos('K/D 1.00 (9999/10.0k)', L) > 0));
  { !spree: every level with the streaks that reached it, two to a row; 5 and 10 kills read the
    counters of before, and no length has fewer than a longer one }
  Blk := Block('Spree Records: Alice');
  try
    L := LineIn(Blk, 'Killing Spree (3 kills)');
    Check('!spree: the levels two to a row, the kills in words, not thousands',
      (Pos('Killing Spree (3 kills): 55', L) = 1) and (Pos('Rampage (5 kills): 40', L) = COLS2[0] + 1) and not Seen('(5k)'));
    Check('!spree: the counters of before and the longer streaks', (CountIn(Blk, 'Dominating (7 kills): 9') = 1) and
      (CountIn(Blk, 'Unstoppable (10 kills): 9') = 1) and (CountIn(Blk, 'Mega Kill (12 kills): 1') = 1) and
      (CountIn(Blk, 'Ultra Kill (15 kills): 0') = 1) and (CountIn(Blk, 'Holy Shit (30 kills): 0') = 1));
    Check('!spree: the medals stay', (CountIn(Blk, 'Double: ') = 1) and (CountIn(Blk, 'Mercy: ') = 1) and
      (CountIn(Blk, 'Best Streak: 12') = 1));
  finally
    Blk.Free;
  end;
  Check('/zs_status: the K/D as a ratio with the kills and deaths', Seen('K/D: 1.00 (9999/10.0k)'));

  { !server: one source for the damage, the numbers shortened, the rows of the mode }
  Blk := Block('Server Statistics & Activity Analytics');
  try
    Check('!server: the damage is the weapons'' total, never less than one weapon',
      (Pos('Combat Dmg: 67.7k', LineIn(Blk, 'Combat Dmg')) = 1) and (Pos('Top Gun (Damage): AK-74 (67.7k)', Blk.Text) > 0));
    Check('!server: damage per hit divides the same totals', Pos('Avg Dmg/Hit: 100.0 HP', LineIn(Blk, 'Combat Dmg')) > 0);
    Check('!server: head hits shortened like the damage', Pos('Head: 13.8k (', LineIn(Blk, 'Head: ')) = 1);
    Check('!server: counters shortened', (Pos('Kills: 9999', LineIn(Blk, 'Suicides: ')) = 1) and
      (Pos('Suicides: 99.9k', LineIn(Blk, 'Suicides: ')) > 0));
    Check('!server: no flag caps and no friendly fire index on a deathmatch server',
      (CountIn(Blk, 'Flag Caps') = 0) and (CountIn(Blk, 'FF Index') = 0));
    Check('!server: kills per match of the maps, matches of the maps', (CountIn(Blk, 'Kills/Match: 30.0') = 1) and
      (CountIn(Blk, 'Matches played: 10') = 1));
    Check('!server: who came back, of the accounts whose days were counted',
      Pos('Came back: 50.0% of the 2 accounts new since ', LineIn(Blk, 'Came back')) = 1);
    Check('!server: a peak record without date and length says neither', LineIn(Blk, 'Peak Record') = 'Peak Record: 50 players');
    Check('!server: the columns of COLS4', Pos('Yesterday: ', LineIn(Blk, 'Today: ')) = COLS4[0] + 1);
  finally
    Blk.Free;
  end;

  Check('!activity: the day''s play time next to its share', Seen('Day%  Play time') and Seen('100%  1h 0m'));
  Check('!server: the busiest hour and the matches', Seen('Busiest hour: Wed 20:00-21:00 (!activity) | Matches played: 10'));
  Check('/zs_status: the audit', Seen('[ Admin Audit: Alice ]'));

  { the command overview }
  Check('!zitro: the frame is LINE_W wide', Length(LineWith(' - commands ')) = LINE_W);
  L := LineWith('/zs_unregister id*');
  Check('!zitro: the admin commands start their columns where the other sections do',
    (Pos('/zs_setpass', L) = 21) and (Pos('/removeolderthan', L) = 61) and
    (Pos('!statsi', LineWith('!stats [p]')) = 21) and (Pos('!hud', LineWith('!stats [p]')) = 81));
  { a command that would touch the next column takes two columns instead }
  Check('!zitro: a long command takes two columns and touches nothing',
    (Pos('/resetallplayersstats', LineWith('/resetplayerstats p*')) = 41) and
    (Pos('/resetserverstats', LineWith('/resetplayerstats p*')) = 81) and
    (Pos('/balinfo', LineWith('/resetmapstats [map]')) = 61) and (Pos('/move', LineWith('/mix')) = 41));
  Check('!zitro: the page commands in one row', Pos('/zs_end', LineWith('/zs_next')) = 81);
  L := LineWith('!allweaponsby m* [p]');
  Check('!zitro: the weapon tables by metrics take two columns each and fill their rows',
    (Pos('!allweaponsbyi m* n*', L) = 41) and (Pos('!serverweapons', L) = 81) and
    (Pos('!serverwep w*', LineWith('!serverweaponsby m*')) = 41) and
    (Pos('!topweapons [w] [pg]', LineWith('!serverweaponsby m*')) = 61));
  Check('!zitro: the legend says where the weapon metrics are listed',
    Seen('m = metrics (!topby help, weapon metrics: !topwepsby help)  w = weapon (!wep help)'));
  Check('!zitro: the legend says that wep and weap are the same in every command',
    Seen('wep or weap, either works in a command: !weap = !wep, !mapweap = !mapwep, !topweaps = !topweps'));
  { the per-map commands ([Matrix]): three sections, two columns each (the longest three), in the
    columns of the others; x[i] is the command and its "i" form }
  L := LineWith('!playermaps[i] [flag] [pg] [p]');
  Check('!zitro: a player over all maps, in the columns of the other sections',
    (Pos('!rivals[i] [flag] [pg] [p]', L) = 41) and
    (Pos('!playermatchup[i] [w] [flag] [pg] [p]', LineWith('!versus[i] [flag] [pg] p* [p2]')) = 41));
  Check('!zitro: a player on one map, two commands to a row',
    (Pos('!mapplayerotherstats[i] [map] [p]', LineWith('!mapplayerstats[i] [map] [p]')) = 41) and
    (Pos('!mapplayerrivals[i] [map] [flag] [pg] [p]', LineWith('!mapplayerweapstats[i] [map] [p]')) = 41) and
    (Pos('!playerheatmap[i] [map] [p]', LineWith('!mapplayermatchup[i] [map] [flag] [pg] [p]')) = 61));
  Check('!zitro: one map, all its players',
    (Pos('!mapmatchup [map] [w] [flag] [pg]', LineWith('!maprivals [map] [flag] [pg]')) = 41) and
    (Pos('!mapwep w* [map]', LineWith('!mapweapstats [map] [flag] [pg]')) = 41));
  Check('!zitro: the sections and the legend of the per-map commands', Seen('A player over all maps') and
    Seen('A player on one map') and Seen('One map, all its players') and
    Seen('per-map commands: [map] (else the current one), [w], [flag], [pg], [p] in this order  p2 = player 2') and
    Seen('flag = the order (<cmd> help lists the flags, asc turns it round)  x[i] = also xi: n in place of p') and
    Seen('matrix = matchup: !playermatrix[i], !mapplayermatrix[i], !mapmatrix  !mapweapon = !mapwep'));
  Check('!zitro: the password commands for a player without Steam only', Seen('1|3|/register pw* pw*') and
    not Seen('0|/register pw* pw*'));
  Check('!zitro: no team balance on a deathmatch server', not Seen('!switch = to the weaker team'));

  { the dispatcher }
  Check('an admin command from a player is refused out loud', Seen('1|2|This command is for admins.'));
  Check('!switch from the console says why nothing happens', Seen('!switch and !join are for players on the server.'));
  Check('a password command from the console says why nothing happens',
    Seen('The password commands are for players on the server.'));
  Check('!achlist of nobody says so instead of the bare list', Seen('Player not found.'));
  Check('!topid of an empty slot explains itself', Seen('Usage: !topid <player slot number>'));
  Check('an "i" command with a name or 0 says what it takes instead of showing the first place',
    SeenCount('A ranking position is a number, e.g. !statsi 3') = 2);
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.Ranks[RANK_POINTS].Count;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('an "i" command past the end says how long the ranking is instead of showing the last place',
    SeenCount(Format('The ranking has %d places.', [M])) = 3);

  { every answer of the commands above, to look at the layout of the tables }
  Console.SaveToFile(Root + PathDelim + 'console_dm.txt');

  WeapAliases;

  { capture the flag: the flags and the team rows come back }
  Console.Clear;
  MapAfter('ctf_test', GS_CTF, 0);
  Run('/stats alice');
  Run('/server');
  Run('/otherstats bob');
  Run('/otherstats alice');
  Check('ctf commands processed', WaitProcessed);
  DrainActions;
  Blk := Block('[ Detailed Telemetry: Bob ]');
  try
    Check('!otherstats on ctf without survival: no round first bloods of an account without them',
      (Blk.Count > 2) and (CountIn(Blk, 'First Bloods: 0') = 1) and (CountIn(Blk, 'Round First Bloods') = 0));
  finally
    Blk.Free;
  end;
  Blk := Block('[ Detailed Telemetry: Alice ]');
  try
    Check('!otherstats on ctf: the round first bloods of an account that has them',
      CountIn(Blk, 'Round First Bloods: 12.3k') = 1);
  finally
    Blk.Free;
  end;
  Blk := Block('[ Stats: Alice ]');
  try
    Check('!stats on ctf: the flags row, the assists once', (CountIn(Blk, 'Flag Caps: ') = 1) and
      (CountIn(Blk, 'Assists: ') = 1));
  finally
    Blk.Free;
  end;
  Check('!server on ctf: flag caps', Seen('Flag Caps: 0'));
  Check('every line of the ctf answers fits LINE_W', AllFit(Worst));
  if Worst <> '' then
    WriteLn('       too wide: ', Worst);
  Console.SaveToFile(Root + PathDelim + 'console_ctf.txt');

  { a player by a name or a part of it: the players on the server first, the closest name among
    them; the accounts only when nobody on the server matches, also an account with exactly the
    name typed }
  Console.Clear;
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.DB.CreateProfile('Al', '', 'HWAL1', '9.9.9.1', 1000);
    Engine.DB.CreateProfile('Bo', '', 'HWBO1', '9.9.9.2', 1000);
    Engine.DB.CreateProfile('lic', '', 'HWLIC1', '9.9.9.3', 1000);
    Engine.DB.CreateProfile('Zed Offline', '', 'HWZED1', '9.9.9.4', 1000);
    M := Engine.DB.CreateProfile('Dave Long Gone', '', 'HWDLG1', '9.9.9.5', 1000);
    if Engine.DB.Valid(M) then
      Engine.DB.Profiles[M]^.LastPlayedTime := Now - 3;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/rank al');
  Run('/rank bo');
  Run('/rank lic');
  Run('/rank zed');
  Run('/rank dave long');
  Run('/stats offline');
  Run('/rank nobody at all');
  Check('player searches processed', WaitProcessed);
  DrainActions;
  Check('a player on the server whose name begins with the text before an account named exactly so',
    Seen('[Rank] Alice #') and Seen('[Rank] Bob #') and not Seen('[Rank] Al #') and not Seen('[Rank] Bo #'));
  Check('a player on the server with the text inside the name before an account named exactly so',
    (SeenCount('[Rank] Alice #') = 2) and not Seen('[Rank] lic #'));
  Check('the accounts only when nobody on the server matches: the closest name among them',
    Seen('[Rank] Zed Offline #') and Seen('[ Stats: Zed Offline ]'));
  Check('the words of a name: nobody on the server has "dave long", an account does',
    Seen('[Rank] Dave Long Gone #'));
  Check('nobody at all: not found', Seen('Player not found.'));

  { !commands and !cmds belong to the owner's Basic script: ZitroStats does not take them }
  Check('!commands and !cmds are no ZitroStats commands, !zitro and !help are',
    not IsZitroCommand('!commands') and not IsZitroCommand('/cmds') and not IsZitroCommand('commands') and
    IsZitroCommand('!zitro') and IsZitroCommand('!help') and IsZitroCommand('/zitro'));
  Console.Clear;
  Run('/commands');
  Run('/cmds');
  Run('/zitro');
  Check('help commands processed', WaitProcessed);
  DrainActions;
  Check('the engine answers !zitro once, !commands and !cmds not at all', SeenCount(' - commands ') = 1);

  { the longest names, last seen long ago: "Recent Visitors" still fits the line }
  Console.Clear;
  EnterCriticalSection(Engine.StateLock);
  try
    for M := 0 to Engine.DB.ProfileCount - 1 do
      if Engine.DB.Valid(M) then
      begin
        Engine.DB.Profiles[M]^.ActiveName := Format('Longest_Name_Of_All_%.4d', [M]);
        Engine.DB.Profiles[M]^.LastPlayedTime := Now - 1234.5;
      end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Run('/server');
  Check('long names processed', WaitProcessed);
  DrainActions;
  Check('!server: three long names long ago fit the line', Seen('(1234d ago)') and AllFit(Worst));
  if Worst <> '' then
    WriteLn('       too wide: ', Worst);

  Engine.Free;
  Console.Free;

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
