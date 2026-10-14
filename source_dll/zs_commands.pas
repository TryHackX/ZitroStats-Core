unit zs_commands;

{ Player and admin commands.

  Everything here runs on the engine thread with the state lock held. Answers go to the
  caller's console, or to the server console for slot 0 (server console and Soldat Admin).
  Listings remember their query per caller, so /zs_next, /zs_prev, /zs_page <n>, /zs_first and
  /zs_end page through them (also without the underscore). The plain /next and the like are left
  to other scripts.

  Player arguments: nothing = yourself, a name or a part of it (the players on the server first,
  the accounts only when none of them matches), #id = account number.
  Commands ending in "i" take a ranking position instead. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_db, zs_rank, zs_rating, zs_weapons,
  zs_rules, zs_identity, zs_live, zs_service, zs_engine, zs_balance;

const
  { Every table is this wide. Soldat draws a console line as long as a script makes it, and on
    Full HD (where nine players in ten are) that is far more than the chat lets anybody type;
    100 keeps the tables readable on a small screen too. The column sets add up to LINE_W:
    a cell longer than its column shifts the cells after it, so the columns leave room for the
    longest cell they hold. }
  LINE_W = 100;
  COLS2: array[0..1] of LongInt = (50, 50);
  COLS3: array[0..2] of LongInt = (36, 34, 30);
  COLS4: array[0..3] of LongInt = (25, 25, 25, 25);

type
  { one weapon summed over all accounts, with the older special-weapon counters folded in }
  TWeaponTotals = record
    WSlot: LongInt;
    Kills, Deaths, Shots, Hits, Headshots, Time, Picks, VestKills: Int64;
    Damage, DamageIn: Double;
    Longest: Single;
    Reloads, ReloadsManual, RoundsDropped, ReloadsDone, ReloadsCut, ReloadDeaths, ReloadTimed,
      ReloadTicks, ReloadNormTicks, ReloadEnds, ReloadDoneMille, ReloadDeathMille, ReloadTicksAll: Int64;
    { [Bridges] (5.6): the hits' distances (metres) and the ticks their bullets and the lethal ones flew,
      added up, and the longest hit }
    HitDistSum: Double;
    HitDistCount: Int64;
    LongestHit: Single;
    HitAirTicks, HitAirCount, KillAirTicks, KillAirCount: Int64;
  end;

function IsZitroCommand(const Word: AnsiString): Boolean;
{ IsZitroCommand for a command from Source: the names Soldat itself uses (/info, /pm) stay
  Soldat's as / commands and are ZitroStats commands only in chat (!info, !pm) }
function IsZitroCommandFrom(const Word: AnsiString; Source: LongInt): Boolean;
{ True for the commands only admins may run (they are written to audit.log) }
function IsAdminCommand(const Word: AnsiString): Boolean;
{ True for Soldat's own admin commands: the server runs them, ZitroStats only writes them to audit.log }
function IsSoldatAdminCommand(const Word: AnsiString): Boolean;
{ index of the first argument audit.log hides (a password or a private message), MaxInt = none }
function AuditHiddenFrom(const Word: AnsiString): LongInt;
function NormalizeCommand(const Word: AnsiString): AnsiString;
function ExecuteCommand(E: TZSEngine; Slot: LongInt; const W: TStringArray; Source: LongInt; Admin: Boolean): Boolean;
function JoinWords(const W: TStringArray): AnsiString;
{ the weapon totals of !topweapons and !server, also written to stats.json }
{ Shared: with the other servers of the database added (SharedWeapons, SharedServer). MaxAgeMs: the
  sums of this server's accounts may be that old (a player's view, > 0) or are added up now and kept
  for those views (0, the server console); < 0 = added up now, nothing kept (the export) }
procedure CollectWeaponTotals(E: TZSEngine; var T: array of TWeaponTotals; Shared: Boolean = False; MaxAgeMs: Int64 = -1);
{ '' when every metric name belongs to one metric only, otherwise the offending name (for tests) }
function DuplicateAlias: AnsiString;
{ average length of the matches played on a map, in seconds }
function AvgMatchSeconds(const M: TMapProfile): Double;
{ team balance: /balinfo, a player on the server by slot, #id or name, a team by name or number }
procedure CmdBalanceInfo(E: TZSEngine; Slot: LongInt);
function FindPlayerSlot(E: TZSEngine; const Text: AnsiString): LongInt;
{ the same, with Why when there is no such player or the text fits several }
function ResolvePlayerSlot(E: TZSEngine; const Text: AnsiString; out Why: AnsiString): LongInt;
function TeamFromText(const Text: AnsiString): LongInt;

implementation

uses
  zs_fight,
  zs_fields, zs_shared, zs_maps, zs_matrix;

type
  PSlotExtra = ^TSlotExtra;

  { one weapon of one player, with the older special-weapon counters folded in }
  TWeaponView = record
    Kills, Deaths, Shots, Hits, Headshots, HSKills: Int64;
    Damage, DamageIn: Double;
    Time: Int64;
    Longest: Single;
  end;

const
  QK_NONE = 0;
  QK_TOP = 1;
  QK_TOPBY = 2;
  QK_SEARCH = 3;
  QK_SEARCH_ADMIN = 4;
  QK_TOPMAPS = 5;
  QK_TOPMAPSBY = 6;
  QK_TOPWEAPONS = 7;
  QK_TOPPERIOD = 8;
  QK_TOPSKILL = 9;
  QK_TOPSEASON = 10;
  QK_SEASONS = 11;
  QK_MATCHUP = 12;
  QK_MAPS = 13;
  QK_ALLMAPS = 14;
  QK_SEARCHMAP = 15;
  { the lists of the per-map data (zs_cmd_matrix.inc) }
  QK_PLAYERMAPS = 16;
  QK_RIVALS = 17;
  QK_MAPRIVALS = 18;
  QK_VERSUS = 19;
  QK_PMATCHUP = 20;
  QK_MAPMATCHUP = 21;
  QK_MAPWEAPONS = 22;

  { !commands and !cmds belong to the owner's Basic script, not to ZitroStats }
  PLAYER_COMMANDS = ' zitro help reginfo info credits autor tworca hud contact ' +
    'stats statsi otherstats otherstatsi status statusi rank ranki ranknum session sessioni today ' +
    'lastfight ' +
    'top topp topi topo toponline topme topid topby topskill toprating topseason topday topweek topmonth ' +
    'zs_search zssearch mapstats topmaps topmapsp topmapsi topmapsby server serverstats activity ' +
    'allweapons weapons allweaponsi weaponsi allweaponsby weaponsby allweaponsbyi weaponsbyi ' +
    'wep weapon wepi weaponi matchup matchups matrix ' +
    'serverweapons serverweps srvweapons srvweps serverweaponsby serverwepsby srvweaponsby srvwepsby ' +
    'serverwep serverweapon srvwep ' +
    'topweapons topweps topweaponsby topwepsby rambo ramboi spree spreei pointmatch pm ' +
    'achievements ach badges achievementsi achi badgesi achlist achievementslist achlisti achievementslisti seasons ' +
    'heatmap heat zs_next zs_prev zs_page zs_first zs_end bal teams switch join ' +
    'v vote nextmap lastmap votelast votelastmap randommap map votemap maps allmaps searchmap ' +
    'mapplayerstats mapplayerotherstats mapplayerweapstats mapplayerrivals mapplayermatchup playerheatmap ' +
    'playermaps rivals versus playermatchup maprivals mapmatchup ' +
    'mapplayerstatsi mapplayerotherstatsi mapplayerweapstatsi mapplayerrivalsi mapplayermatchupi playerheatmapi ' +
    'playermapsi rivalsi versusi playermatchupi playermatrix playermatrixi mapplayermatrix mapplayermatrixi mapmatrix ' +
    'mapweapstats mapweapsstats mapwep mapweapon ' +
    { weap for wep and wep for weap, as !weap is !wep (NormalizeCommand) }
    'serverweaps srvweaps serverweapsby srvweapsby serverweap srvweap topweaps topweapsby mapweap ' +
    'mapwepstats mapwepsstats mapplayerwepstats mapplayerwepstatsi ';
  IDENTITY_COMMANDS = ' register login changepass setemail verifyemail forgotpass resetpass account removemypass ';
  { names of Soldat's own server commands that ZitroStats also knows (as chat commands); /votemap
    goes to the map vote only while it is switched on (ZS_Command) }
  SOLDAT_COMMANDS = ' info pm map nextmap votemap ';
  ADMIN_COMMANDS = ' yes no zs_save zs_sync zs_backup zs_backups zs_restore resetallplayersstats resetallmapsstats ' +
    'resetserverstats resetplayerstats resetmapstats removeolderthan zs_merge zs_unregister zs_setpass ' +
    'zs_reload zs_status zs_statusid zs_statusi zs_export zs_suspects zs_perf searcha ' +
    'balinfo mix swap move balexclude zs_mapvote zs_maps ';
  { Soldat's own admin commands: the server runs them, audit.log records who did }
  SOLDAT_ADMIN_COMMANDS = ' addbot addbot1 addbot2 addbot3 addbot4 addbot5 nextmap map restart kick ban banip banhw ' +
    'unban unbanip unbanhw unbanlast tempban pkill timelimit maxplayers password bonus loadwep loadcon loadlist ' +
    'gamemode setteam1 setteam2 setteam3 setteam4 setteam5 say pm respawntime minrespawntime maxrespawntime ' +
    'maxgrenades friendlyfire survival realistic advance weaponon weaponoff limit vote% lobby scripting recompile ' +
    'gmute ungmute addmap delmap adminlog ';

var
  ConsoleState: TSlotExtra;

{ ---------------- names ---------------- }

function NormalizeCommand(const Word: AnsiString): AnsiString;
var
  Prefix, C: AnsiString;
begin
  C := LowerCase(Trim(Word));
  Prefix := '';
  if (C <> '') and (C[1] in ['/', '!']) then
  begin
    Prefix := C[1];
    Delete(C, 1, 1);
  end;
  C := StringReplace(C, '-', '_', [rfReplaceAll]);
  if C = 'zsstatus' then
    C := 'zs_status'
  else if C = 'zsstatusid' then
    C := 'zs_statusid'
  else if C = 'zsstatusi' then
    C := 'zs_statusi'
  { the pages go by names of their own, so /next and the like stay free for other scripts }
  else if C = 'zsnext' then
    C := 'zs_next'
  else if C = 'zsprev' then
    C := 'zs_prev'
  else if C = 'zspage' then
    C := 'zs_page'
  else if C = 'zsfirst' then
    C := 'zs_first'
  else if C = 'zsend' then
    C := 'zs_end'
  else if C = 'weap' then
    C := 'wep'
  else if C = 'weapi' then
    C := 'wepi';
  Result := Prefix + C;
end;

function BareCommand(const Word: AnsiString): AnsiString;
begin
  Result := NormalizeCommand(Word);
  if (Result <> '') and (Result[1] in ['/', '!']) then
    Delete(Result, 1, 1);
end;

function IsZitroCommand(const Word: AnsiString): Boolean;
var
  C: AnsiString;
begin
  C := BareCommand(Word);
  if (C = '') or (Pos(' ', C) > 0) then
    Exit(False);
  C := ' ' + C + ' ';
  Result := (Pos(C, PLAYER_COMMANDS) > 0) or (Pos(C, IDENTITY_COMMANDS) > 0) or (Pos(C, ADMIN_COMMANDS) > 0);
end;

function IsZitroCommandFrom(const Word: AnsiString; Source: LongInt): Boolean;
begin
  Result := IsZitroCommand(Word) and
    ((Source = SRC_CHAT) or (Pos(' ' + BareCommand(Word) + ' ', SOLDAT_COMMANDS) = 0));
end;

function IsAdminCommand(const Word: AnsiString): Boolean;
var
  C: AnsiString;
begin
  C := BareCommand(Word);
  Result := (C <> '') and (Pos(' ', C) = 0) and (Pos(' ' + C + ' ', ADMIN_COMMANDS) > 0);
end;

function IsSoldatAdminCommand(const Word: AnsiString): Boolean;
var
  C: AnsiString;
begin
  C := BareCommand(Word);
  Result := (C <> '') and (Pos(' ', C) = 0) and (Pos(' ' + C + ' ', SOLDAT_ADMIN_COMMANDS) > 0);
end;

function AuditHiddenFrom(const Word: AnsiString): LongInt;
var
  C: AnsiString;
begin
  C := BareCommand(Word);
  { /yes carries the confirm password, /password and /adminlog a server password }
  if (C = 'yes') or (C = 'password') or (C = 'adminlog') or (C = 'removemypass') then
    Result := 1
  { /zs_setpass the new password of an account, /pm the text after the player }
  else if (C = 'zs_setpass') or (C = 'pm') then
    Result := 2
  else
    Result := MaxInt;
end;

function JoinWords(const W: TStringArray): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := 0 to High(W) do
  begin
    if k > 0 then
      Result := Result + ' ';
    Result := Result + W[k];
  end;
end;

{ ---------------- output ---------------- }

procedure Out(E: TZSEngine; Slot: LongInt; const Text: AnsiString; Color: LongInt);
begin
  if Slot <= 0 then
    E.WriteServer(Text)
  else
    E.Say(Slot, Text, Color);
end;

function Frame(const Title: AnsiString; Width: LongInt; Ch: AnsiChar): AnsiString;
var
  Inner: AnsiString;
  L: LongInt;
begin
  Inner := ' ' + Title + ' ';
  if Length(Inner) >= Width then
    Exit(Inner);
  L := (Width - Length(Inner)) div 2;
  Result := StringOfChar(Ch, L) + Inner + StringOfChar(Ch, Width - Length(Inner) - L);
end;

procedure Header(E: TZSEngine; Slot: LongInt; const Title: AnsiString; Width: LongInt);
begin
  Out(E, Slot, Frame(Title, Width, '='), CLR_HEADER);
end;

procedure Section(E: TZSEngine; Slot: LongInt; const Title: AnsiString; Width: LongInt);
begin
  Out(E, Slot, Frame(Title, Width, '-'), CLR_SUBHEADER);
end;

procedure Footer(E: TZSEngine; Slot, Width: LongInt);
begin
  Out(E, Slot, StringOfChar('=', Width), CLR_HEADER);
end;

procedure Rule(E: TZSEngine; Slot, Width: LongInt);
begin
  Out(E, Slot, StringOfChar('-', Width), CLR_ACTIVITY);
end;

{ Commands laid out in columns of ColW, Cols to a row, like the tables of the statistics. Every
  item starts at a column; one that would leave fewer than two spaces before the next column
  takes two columns (or more), and a row ends where the next item no longer fits, so no two
  items ever touch and every section of a view has the same columns. }
procedure CmdGrid(E: TZSEngine; Slot: LongInt; const Items: array of AnsiString; Cols, ColW, Color: LongInt);
var
  k, Used, Span: LongInt;
  S: AnsiString;
begin
  S := '';
  Used := 0;
  ColW := Max(1, ColW);
  for k := 0 to High(Items) do
  begin
    Span := Max(1, (Length(Items[k]) + 2 + ColW - 1) div ColW);
    if (Used > 0) and (Used + Span > Cols) then
    begin
      Out(E, Slot, TrimRight(S), Color);
      S := '';
      Used := 0;
    end;
    S := S + PadR(Items[k], Span * ColW);
    Inc(Used, Span);
  end;
  if S <> '' then
    Out(E, Slot, TrimRight(S), Color);
end;

{ cells padded to fixed widths; the last cell is not padded }
procedure Row(E: TZSEngine; Slot: LongInt; const Cells: array of AnsiString; const Widths: array of LongInt; Color: LongInt);
var
  k: LongInt;
  S: AnsiString;
begin
  S := '';
  for k := 0 to High(Cells) do
    if k = High(Cells) then
      S := S + Cells[k]
    else if Length(Cells[k]) >= Widths[Min(k, High(Widths))] then
      S := S + Cells[k] + ' '
    else
      S := S + PadR(Cells[k], Widths[Min(k, High(Widths))]);
  Out(E, Slot, TrimRight(S), Color);
end;

{ ' est.' when more than one bullet hit in twenty could not be put in a zone }
function ZoneEst(Unknown, Head, Body, Legs: Int64): AnsiString;
begin
  if Unknown * 20 > Unknown + Head + Body + Legs then
    Result := ' est.'
  else
    Result := '';
end;

{ big numbers are shortened the same way everywhere, never wider than 5 characters (a minus makes
  6): in full below 10 000, then 12.3k, 123k, 4.5M, 45.6M, 456M, 1.2B ...; the unit is chosen
  after rounding, so 999 600 is 1.0M and not 1000k, and 9 999.7 is 10.0k and not 10000. NaN and
  infinity (a division the worker thread of Linux lets through) are 0. }
function Dmg(V: Double): AnsiString;
begin
  if IsNan(V) or IsInfinite(V) then
    Result := '0'
  else if V < 0 then
    Result := '-' + Dmg(-V)
  else if V < 9999.5 then
    Result := FloatStr(V, 0)
  else if V < 99950.0 then
    Result := FloatStr(V / 1000.0, 1) + 'k'
  else if V < 999500.0 then
    Result := FloatStr(V / 1000.0, 0) + 'k'
  else if V < 99950000.0 then
    Result := FloatStr(V / 1000000.0, 1) + 'M'
  else if V < 999500000.0 then
    Result := FloatStr(V / 1000000.0, 0) + 'M'
  else if V < 99950000000.0 then
    Result := FloatStr(V / 1000000000.0, 1) + 'B'
  else
    Result := FloatStr(V / 1000000000.0, 0) + 'B';
end;

{ the same rule for counts (kills, shots, hits, points) }
function Num(V: Int64): AnsiString;
begin
  Result := Dmg(V);
end;

{ damage as kills: how many full health bars of the current mode it is, a count like any other }
function KillEq(E: TZSEngine; Amount: Double): AnsiString;
begin
  Result := Dmg(Amount / Max(1, E.EffectiveMaxHealth));
end;

function Pct(A, B: Double): AnsiString;
begin
  Result := FloatStr(Min(100.0, SafeDivD(A * 100.0, B)), 1) + '%';
end;

{ "Top primary: AK-74 (34.5%)", the most picked weapon of a group and its share of the group }
function TopPickText(const Title: AnsiString; const Picks: array of Int64; Secondary, Short: Boolean): AnsiString;
var
  S: LongInt;
  Count, Total: Int64;
begin
  S := TopPickSlot(Picks, Secondary, Count, Total);
  if S < 0 then
    Result := Title + ': -'
  else if Short then
    Result := Format('%s: %s (%s)', [Title, SlotShortName(S), Pct(Count, Total)])
  else
    Result := Format('%s: %s (%s)', [Title, SlotName(S), Pct(Count, Total)]);
end;

function KD(Kills, Deaths: Int64): AnsiString;
begin
  Result := FloatStr(Kills / Max(Int64(1), Deaths), 2);
end;

{ every life that ended: a death is a death, no matter who caused it }
function LivesEnded(const P: TPlayerProfile): Int64;
begin
  Result := Int64(P.Deaths) + P.DeathsByFriendly + P.Selfkills;
end;

{ the denominator of the selfkill share, by [Ranking] SelfkillPercentBase }
function SelfkillBase(E: TZSEngine; const P: TPlayerProfile): Int64;
begin
  if SameText(E.Cfg.SelfkillPercentBase, 'enemy') then
    Result := P.Deaths
  else
    Result := LivesEnded(P);
end;

{ a change of points with its sign, shortened like every other counter (+13.8k) }
function Signed(V: Int64): AnsiString;
begin
  if V >= 0 then
    Result := '+' + Num(V)
  else
    Result := '-' + Num(-V);
end;

function DateText(T: Double; const Fmt: AnsiString): AnsiString;
begin
  if T <= 0 then
    Result := 'never'
  else
    Result := FormatDateTime(Fmt, T);
end;

procedure PageHint(E: TZSEngine; Slot, Page, Pages: LongInt; const What: AnsiString);
begin
  if Page < Pages then
    Out(E, Slot, Format('Page %d/%d - /zs_next or /zs_page %d for more %s, /zs_end for the last.', [Page, Pages, Page + 1, What]), CLR_HINT)
  else if Pages > 1 then
    Out(E, Slot, Format('Page %d/%d - /zs_prev goes back, /zs_first returns to page 1.', [Page, Pages]), CLR_HINT);
end;

function PageCount(Items, PerPage: LongInt): LongInt;
begin
  PerPage := Max(1, PerPage);
  Result := Max(1, (Items + PerPage - 1) div PerPage);
end;

{ what applies to the current mode, '' for a cell that is left out (CellRows) }
{ [Bridges] (5.6): the accuracy by how the shooter stood when he fired; '' when nothing was counted
  that way yet (the hook and the memory reading were never on) }
function StanceAccText(const Shots, Hits: array of LongInt): AnsiString;
var
  k, Sum: LongInt;
const
  NAMES: array[0..3] of AnsiString = ('stand', 'crouch', 'prone', 'air');
begin
  Result := '';
  Sum := 0;
  for k := 0 to 3 do
    Inc(Sum, Shots[k]);
  if Sum = 0 then
    Exit;
  Result := 'Accuracy by stance:';
  for k := 0 to 3 do
  begin
    if k > 0 then
      Result := Result + ',';
    if Shots[k] > 0 then
      Result := Result + ' ' + NAMES[k] + ' ' + Pct(Hits[k], Shots[k])
    else
      Result := Result + ' ' + NAMES[k] + ' -';
  end;
end;

function IfText(Cond: Boolean; const Text: AnsiString): AnsiString;
begin
  if Cond then
    Result := Text
  else
    Result := '';
end;

{ a text the caller typed, said back: cut to MaxLen with "..." at its end, so a line never grows past
  LINE_W because of it (a chat line holds 100 characters, a console line more) }
function Clip(const S: AnsiString; MaxLen: LongInt): AnsiString;
begin
  if Length(S) <= MaxLen then
    Result := S
  else
    Result := Copy(S, 1, Max(0, MaxLen - 3)) + '...';
end;

{ [Bridges] (5.6): the hits and kills measured from where and when their bullet was made. Metres, '-'
  for none; an average of metres or of ticks (in seconds), '-' without a count }
function MetersText(M: Single): AnsiString;
begin
  if M > 0 then
    Result := FloatStr(M, 1) + 'm'
  else
    Result := '-';
end;

function AvgMetersText(Sum: Double; Count: Int64): AnsiString;
begin
  if Count > 0 then
    Result := FloatStr(Sum / Count, 1) + 'm'
  else
    Result := '-';
end;

function AvgAirText(Ticks, Count: Int64): AnsiString;
begin
  if Count > 0 then
    Result := FloatStr(Ticks / Count / TICKS_PER_SECOND, 2) + 's'
  else
    Result := '-';
end;

{ the weapon slots whose hits have a distance - not the stab, the saw or the fists (the knife's slot has
  the thrown knives) - and whose bullets have an air time: not a flame or a grenade (a fuse) either }
function SlotHitMeasured(S: LongInt): Boolean;
begin
  Result := (S = WEP_KNIFE) or ((S >= 0) and (S < WSLOT_COUNT) and not IsMeleeWeapon(SlotWeapon(S)));
end;

function SlotAirTimed(S: LongInt): Boolean;
var
  W: LongInt;
begin
  W := SlotWeapon(S);
  Result := SlotHitMeasured(S) and (W <> WEP_FLAMER) and (W <> WEP_FRAG) and (W <> WEP_CLUSTERNADE) and
    (W <> WEP_CLUSTER);
end;

{ Cells of which some may be left out (''): the others in their order, as many to a row as
  Widths has columns, so a cell that does not belong to the mode leaves no gap. }
procedure CellRows(E: TZSEngine; Slot: LongInt; const Cells: array of AnsiString; const Widths: array of LongInt;
  Color: LongInt);
var
  k: LongInt;
  Line: TStringArray;
begin
  Line := nil;
  for k := 0 to High(Cells) do
    if Cells[k] <> '' then
    begin
      SetLength(Line, Length(Line) + 1);
      Line[High(Line)] := Cells[k];
      if Length(Line) >= Length(Widths) then
      begin
        Row(E, Slot, Line, Widths, Color);
        Line := nil;
      end;
    end;
  if Length(Line) > 0 then
    Row(E, Slot, Line, Widths, Color);
end;

{ "Prefix a, b, c" over as many lines as it takes: a line never grows past LINE_W, the lines
  after the first start under the first item }
procedure WrapList(E: TZSEngine; Slot: LongInt; const Prefix: AnsiString; const Items: array of AnsiString;
  Color: LongInt);
var
  k: LongInt;
  Line: AnsiString;
begin
  Line := Prefix;
  for k := 0 to High(Items) do
  begin
    if Length(Line) > Length(Prefix) then
    begin
      { ", item" has to leave room for the comma that ends the line when the next one wraps }
      if Length(Line) + 2 + Length(Items[k]) + 1 > LINE_W then
      begin
        Out(E, Slot, Line + ',', Color);
        Line := StringOfChar(' ', Length(Prefix));
      end
      else
        Line := Line + ', ';
    end;
    Line := Line + Items[k];
  end;
  if Length(Line) > Length(Prefix) then
    Out(E, Slot, Line, Color);
end;

{ ---------------- callers, targets, limits ---------------- }

function StateOf(E: TZSEngine; Slot: LongInt): PSlotExtra;
begin
  if (Slot >= 1) and (Slot <= MAX_PLAYERS) then
    Result := @E.Extra[Slot]
  else
    Result := @ConsoleState;
end;

procedure Remember(E: TZSEngine; Slot, Kind: LongInt; const Query: AnsiString; Page, Pages: LongInt);
var
  St: PSlotExtra;
begin
  St := StateOf(E, Slot);
  St^.LastQueryKind := Kind;
  St^.LastQuery := Query;
  St^.Page := Page;
  St^.Pages := Pages;
end;

function ViewerIndex(E: TZSEngine; Slot: LongInt): LongInt;
begin
  if (Slot >= 1) and (Slot <= MAX_PLAYERS) then
    Result := E.Identity.ProfileIndex(Slot)
  else
    Result := -1;
end;

function SlotOfIndex(E: TZSEngine; Idx: LongInt): LongInt;
var
  S: LongInt;
begin
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human and (E.Identity.ProfileIndex(S) = Idx) then
      Exit(S);
  Result := 0;
end;

const
  HEAVY_PER_SECOND = 3;
  { the admins on the server have this many more a second, which no player can take }
  HEAVY_ADMIN_RESERVE = 1;
  { a name no account has is remembered this long (the same text again is answered without going
    through every account), the last NOT_FOUND_KEPT of them }
  NOT_FOUND_MS = 10000;
  NOT_FOUND_KEPT = 8;

var
  FindRefused: Boolean = False;
  { the caller of the command that runs is an admin (set by ExecuteCommand) }
  CallerAdmin: Boolean = False;
  { the command that runs has had its turn of the player's search wait (SearchAllowed): a second
    name in it (!versus a b) does not wait again }
  SearchPaid: Boolean = False;
  NotFoundText: array[0..NOT_FOUND_KEPT - 1] of AnsiString;
  NotFoundUntil: array[0..NOT_FOUND_KEPT - 1] of Int64;
  NotFoundAccounts: array[0..NOT_FOUND_KEPT - 1] of LongInt;
  NotFoundEngine: array[0..NOT_FOUND_KEPT - 1] of Pointer;
  NotFoundNext: LongInt = 0;

{ Lists that go through every account: HEAVY_PER_SECOND on the whole server, also when paging;
  the admins on the server one more (HEAVY_ADMIN_RESERVE), so players cannot keep them out. The
  server console (slot 0) has no limit. }
function HeavyBudget(E: TZSEngine; Slot: LongInt): Boolean;
var
  NowMs: Int64;
  Limit: LongInt;
begin
  Result := True;
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  NowMs := MonoMs;
  if NowMs - E.HeavyWindowMs >= 1000 then
  begin
    E.HeavyWindowMs := NowMs;
    E.HeavyInWindow := 0;
  end;
  Limit := HEAVY_PER_SECOND;
  if CallerAdmin then
    Inc(Limit, HEAVY_ADMIN_RESERVE);
  if E.HeavyInWindow >= Limit then
  begin
    Out(E, Slot, 'The server is busy with other lists, try again in a moment.', CLR_WARN);
    Exit(False);
  end;
  Inc(E.HeavyInWindow);
end;

{ ... and one per HeavyCooldownSeconds per player, admins excepted }
function HeavyAllowed(E: TZSEngine; Slot: LongInt; Admin: Boolean): Boolean;
var
  NowMs: Int64;
begin
  Result := True;
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  NowMs := MonoMs;
  if not Admin and (E.Cfg.HeavyCooldownSeconds > 0) and (NowMs < E.Extra[Slot].HeavyUntilMs) then
  begin
    Out(E, Slot, Format('Please wait %d s before opening another list.', [(E.Extra[Slot].HeavyUntilMs - NowMs + 999) div 1000]), CLR_WARN);
    Exit(False);
  end;
  if not HeavyBudget(E, Slot) then
    Exit(False);
  if not Admin and (E.Cfg.HeavyCooldownSeconds > 0) then
    E.Extra[Slot].HeavyUntilMs := NowMs + Int64(E.Cfg.HeavyCooldownSeconds) * 1000;
end;

{ A name looked for in every account and a page of a list that goes through them: one per
  SearchCooldownSeconds per player (admins excepted; once per command), and within the server-wide
  limit. Without a wait of its own a few players typing names nobody has could keep every list of
  the server busy. }
function SearchAllowed(E: TZSEngine; Slot: LongInt): Boolean;
var
  NowMs: Int64;
  Wait: Boolean;
begin
  Result := True;
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  NowMs := MonoMs;
  Wait := not CallerAdmin and not SearchPaid and (E.Cfg.SearchCooldownSeconds > 0);
  if Wait and (NowMs < E.Extra[Slot].SearchUntilMs) then
  begin
    Out(E, Slot, Format('Please wait %d s before the next search or page.', [(E.Extra[Slot].SearchUntilMs - NowMs + 999) div 1000]),
      CLR_WARN);
    Exit(False);
  end;
  if not HeavyBudget(E, Slot) then
    Exit(False);
  if Wait then
    E.Extra[Slot].SearchUntilMs := NowMs + Int64(E.Cfg.SearchCooldownSeconds) * 1000;
  SearchPaid := True;
end;

{ the lower-case text was looked for in every account a moment ago and none had it (nor has one
  been made since) }
function KnownNotFound(E: TZSEngine; const Low: AnsiString): Boolean;
var
  k: LongInt;
  NowMs: Int64;
begin
  NowMs := MonoMs;
  for k := 0 to NOT_FOUND_KEPT - 1 do
    if (NowMs < NotFoundUntil[k]) and (NotFoundEngine[k] = Pointer(E)) and (NotFoundAccounts[k] = E.DB.ProfileCount) and
       (NotFoundText[k] = Low) then
      Exit(True);
  Result := False;
end;

procedure RememberNotFound(E: TZSEngine; const Low: AnsiString);
begin
  NotFoundText[NotFoundNext] := Low;
  NotFoundUntil[NotFoundNext] := MonoMs + NOT_FOUND_MS;
  NotFoundAccounts[NotFoundNext] := E.DB.ProfileCount;
  NotFoundEngine[NotFoundNext] := Pointer(E);
  NotFoundNext := (NotFoundNext + 1) mod NOT_FOUND_KEPT;
end;

{ case-insensitive (ASCII) search for a lower-case needle, without allocating }
function ContainsLower(const S, LowNeedle: AnsiString): Boolean;
var
  i, j, m: LongInt;
  c: AnsiChar;
begin
  m := Length(LowNeedle);
  if m = 0 then
    Exit(True);
  for i := 1 to Length(S) - m + 1 do
  begin
    j := 1;
    while j <= m do
    begin
      c := S[i + j - 1];
      if c in ['A'..'Z'] then
        c := AnsiChar(Ord(c) + 32);
      if c <> LowNeedle[j] then
        Break;
      Inc(j);
    end;
    if j > m then
      Exit(True);
  end;
  Result := False;
end;

function StartsLower(const S, LowNeedle: AnsiString): Boolean;
var
  j: LongInt;
  c: AnsiChar;
begin
  if Length(LowNeedle) > Length(S) then
    Exit(False);
  for j := 1 to Length(LowNeedle) do
  begin
    c := S[j];
    if c in ['A'..'Z'] then
      c := AnsiChar(Ord(c) + 32);
    if c <> LowNeedle[j] then
      Exit(False);
  end;
  Result := True;
end;

function MoreRecent(E: TZSEngine; A, B: LongInt): Boolean;
begin
  Result := (B < 0) or (E.DB.Profiles[A]^.LastPlayedTime > E.DB.Profiles[B]^.LastPlayedTime);
end;

{ How well a name answers what was typed; lower is closer, -1 = not at all. The kind of match
  comes first - the whole name (0), its beginning (1), the beginning of a word in it (2), any
  part of it (3) - and then the length: "u" finds "up" before "hardkorowy koksu". A name of one
  letter is found by that letter. }
function NameMatchRank(const Name, LowNeedle: AnsiString): LongInt;
var
  Low: AnsiString;
  i, m, Kind: LongInt;
begin
  Result := -1;
  m := Length(LowNeedle);
  if m = 0 then
    Exit;
  Low := LowerCase(Name);
  if Pos(LowNeedle, Low) = 0 then
    Exit;
  if Low = LowNeedle then
    Kind := 0
  else if Copy(Low, 1, m) = LowNeedle then
    Kind := 1
  else
  begin
    Kind := 3;
    for i := 2 to Length(Low) - m + 1 do
      if not (Low[i - 1] in ['a'..'z', '0'..'9']) then
        if Copy(Low, i, m) = LowNeedle then
        begin
          Kind := 2;
          Break;
        end;
  end;
  Result := Kind * 1000 + Min(999, Length(Low) - m);
end;

{ #id, then the players on the server: the closest name among them (NameMatchRank - the whole
  name, its beginning, the beginning of a word, any part, then the shorter name; the first slot
  of equal ones). Only when nobody on the server matches, the accounts: the exact name (the one
  seen last of several), then the closest name, and between equal ones the one seen last. Going
  through every account waits for the player's turn (SearchAllowed) and counts toward the
  server-wide list limit for a player (Slot > 0); a player on the server is found without it, and
  a text no account had a moment ago is not looked for again. }
function FindProfileText(E: TZSEngine; const Arg: AnsiString; Slot: LongInt = 0): LongInt;
var
  C: TIntArray;
  k, S, R, BestKind, BestLen, BestR: LongInt;
  Low: AnsiString;
begin
  Result := -1;
  if Arg = '' then
    Exit;
  if Arg[1] = '#' then
    Exit(E.DB.IndexOfId(StrToIntDef(Copy(Arg, 2, MaxInt), 0)));
  Low := LowerCase(Arg);
  BestR := MaxInt;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human then
    begin
      R := NameMatchRank(E.Live[S].Name, Low);
      if (R < 0) or (R >= BestR) then
        Continue;
      k := E.Identity.ProfileIndex(S);
      if E.DB.Valid(k) then
      begin
        Result := k;
        BestR := R;
      end;
    end;
  if Result >= 0 then
    Exit;
  C := E.DB.IndexesOfName(Arg);
  for k := 0 to High(C) do
    if E.DB.Valid(C[k]) and MoreRecent(E, C[k], Result) then
      Result := C[k];
  if Result >= 0 then
    Exit;
  if (Slot >= 1) and (Slot <= MAX_PLAYERS) and KnownNotFound(E, Low) then
    Exit;
  if not SearchAllowed(E, Slot) then
  begin
    FindRefused := True;
    Exit;
  end;
  BestKind := MaxInt;
  BestLen := MaxInt;
  for k := 0 to E.DB.ProfileCount - 1 do
    if E.DB.Valid(k) then
    begin
      R := NameMatchRank(E.DB.Profiles[k]^.ActiveName, Low);
      if R < 0 then
        Continue;
      if (R div 1000 < BestKind) or ((R div 1000 = BestKind) and ((R mod 1000 < BestLen) or
         ((R mod 1000 = BestLen) and MoreRecent(E, k, Result)))) then
      begin
        Result := k;
        BestKind := R div 1000;
        BestLen := R mod 1000;
      end;
    end;
  if (Result < 0) and (Slot >= 1) and (Slot <= MAX_PLAYERS) then
    RememberNotFound(E, Low);
end;

{ the server slot of a player on the server, for the session commands: the closest name among
  the players there, or the slot of the account Arg names (#id, a name); 0 = none }
function SessionSlotOf(E: TZSEngine; Slot: LongInt; const Arg: AnsiString): LongInt;
var
  S, R, Best, Idx: LongInt;
  Low: AnsiString;
begin
  Result := 0;
  Low := LowerCase(Trim(Arg));
  if Low = '' then
    Exit;
  if Low[1] <> '#' then
  begin
    Best := MaxInt;
    for S := 1 to MAX_PLAYERS do
      if E.Live[S].Active and E.Live[S].Human then
      begin
        R := NameMatchRank(E.Live[S].Name, Low);
        if (R >= 0) and (R < Best) then
        begin
          Best := R;
          Result := S;
        end;
      end;
    if Result > 0 then
      Exit;
  end;
  Idx := FindProfileText(E, Trim(Arg), Slot);
  if Idx < 0 then
    Exit;
  for S := 1 to MAX_PLAYERS do
    if E.Live[S].Active and E.Live[S].Human and (E.Identity.ProfileIndex(S) = Idx) then
      Exit(S);
end;

function TargetIndex(E: TZSEngine; Slot: LongInt; const Arg: AnsiString): LongInt;
begin
  if Trim(Arg) = '' then
    Result := ViewerIndex(E, Slot)
  else
    Result := FindProfileText(E, Trim(Arg), Slot);
end;

{ the account at a place of the ranking the lists show; -1 for a player of the other servers who
  never played here (SharedRankings) }
var
  { the last place asked for with an "i" command that holds a player of the other servers only:
    the profile commands have no account here to show, NotFound says who it is }
  PoolRankValid: Boolean = False;
  PoolRankEntry: TRankEntry;
  PoolRankPlace: LongInt;
  { why the last IndexAtRank gave nobody: no position, or one past the end; NotFound says it }
  RankRefusal: AnsiString = '';

{ Nothing is the first place. A text that is no position ("!statsi abc", 0) and a place past the
  end are nobody, with RankRefusal saying why: another place than the one asked for would show
  somebody else's numbers under the question. }
function IndexAtRank(E: TZSEngine; const Arg: AnsiString): LongInt;
var
  Count, Place: LongInt;
  Order: TRankEntryArray;
  T: AnsiString;
  Shared: Boolean;
begin
  PoolRankValid := False;
  RankRefusal := '';
  { asked once: the MySQL thread may finish loading the other servers in between }
  Shared := RankingShared(E);
  T := Trim(Arg);
  if T = '' then
    Place := 1
  else if AllDigits(T) then
    { a number too big for a LongInt is past the end as well }
    Place := StrToIntDef(T, MaxInt)
  else
    Place := 0;
  if Place <= 0 then
  begin
    RankRefusal := 'A ranking position is a number, e.g. !statsi 3; for a name leave out the "i": !stats <name>.';
    Exit(-1);
  end;
  if Shared then
  begin
    Order := RankingOrder(E);
    Count := Length(Order);
  end
  else
    Count := E.DB.Ranks[RANK_POINTS].Count;
  if Count = 0 then
    Exit(-1);
  if Place > Count then
  begin
    RankRefusal := Format('The ranking has %d places.', [Count]);
    Exit(-1);
  end;
  if Shared then
  begin
    Result := Order[Place - 1].Idx;
    if Result < 0 then
    begin
      PoolRankValid := True;
      PoolRankEntry := Order[Place - 1];
      PoolRankPlace := Place;
    end;
    Exit;
  end;
  Result := E.DB.Ranks[RANK_POINTS].At(Place);
end;

function RankText(E: TZSEngine; Idx: LongInt): AnsiString;
var
  R: LongInt;
begin
  R := RankingPosition(E, Idx);
  if R > 0 then
    Result := IntToStr(R)
  else
    Result := '-';
end;

{ the places of the ranking the lists show; this server's ranking knows its size, so only the
  ranking of every server needs RankingOrder (which builds this server's order again each time) }
function RankingCount(E: TZSEngine): LongInt;
begin
  if RankingShared(E) then
    Result := Length(RankingOrder(E))
  else
    Result := E.DB.Ranks[RANK_POINTS].Count;
end;

var
  WeaponSrvTmp: TServerRecords;

{ the server record the weapon commands read: with SharedWeapons the other servers' added }
function WeaponServer(E: TZSEngine): PServerRecords;
begin
  Result := SharedServerView(E, E.Cfg.MySQLShareWeapons, WeaponSrvTmp);
end;

{ the words a weapon title gets when the other servers are added (SharedWeapons) }
function WeaponsAll(E: TZSEngine): AnsiString;
var
  Sum: TPlayerProfile;
begin
  Sum := Default(TPlayerProfile);
  if SharedAccountSums(E, E.Cfg.MySQLShareWeapons, Sum) then
    Result := ' - all servers'
  else
    Result := '';
end;

{ the words a ranking title gets when it holds every server of the database }
function AllServers(E: TZSEngine): AnsiString;
begin
  if RankingShared(E) then
    Result := ' of All Servers'
  else
    Result := '';
end;

procedure NotFound(E: TZSEngine; Slot: LongInt);
var
  P: PPlayerProfile;
  Tmp: TPlayerProfile;
begin
  { the search was refused by a list limit, which already told the player }
  if FindRefused then
  begin
    FindRefused := False;
    Exit;
  end;
  { an "i" command without a place of the ranking }
  if RankRefusal <> '' then
  begin
    Out(E, Slot, RankRefusal, CLR_WARN);
    RankRefusal := '';
    Exit;
  end;
  { a place of the ranking of every server that a player of the other servers holds }
  if PoolRankValid then
  begin
    PoolRankValid := False;
    Tmp := Default(TPlayerProfile);
    P := RankingView(E, PoolRankEntry, Tmp);
    if P <> nil then
    begin
      Out(E, Slot, Format('#%d of all servers: %s - %s pts, %s kills, %s deaths, K/D %s, played %s.',
        [PoolRankPlace, P^.ActiveName, Num(P^.Points), Num(P^.Kills), Num(P^.Deaths), KD(P^.Kills, P^.Deaths),
         FormatDurationShort(P^.TimePlayed)]), CLR_COMBAT);
      Out(E, Slot, 'This player has not played on this server yet, so there is nothing more to show here.', CLR_HINT);
      Exit;
    end;
  end;
  Out(E, Slot, 'Player not found. Use a name or #id, or find the account with !zs_search <text>.', CLR_BAD);
end;

function PerfRating(E: TZSEngine; const P: TPlayerProfile): Double;
begin
  Result := PerformanceRating(P, E.Match.GameStyle, E.Match.Survival, E.Match.FriendlyFire, E.Cfg.RatingMode);
end;

{ the optional skill rating of the current game family, '' with the ELO points system }
function SkillText(E: TZSEngine; const P: TPlayerProfile; Family: LongInt): AnsiString;
begin
  case E.RatingSystem of
    RS_MMR:
      if P.Mmr[Family].Games > 0 then
        Result := Format('%s (%d games)', [FloatStr(P.Mmr[Family].R, 0), P.Mmr[Family].Games])
      else
        Result := 'unrated';
    RS_GLICKO2:
      if P.Glicko[Family].Games > 0 then
        Result := Format('%s (%d games)', [FloatStr(GlickoConservative(P.Glicko[Family], E.Cfg.GlickoConservative), 0), P.Glicko[Family].Games])
      else
        Result := 'unrated';
    RS_OPENSKILL:
      if P.OpenSkill[Family].Games > 0 then
        Result := Format('%s (%d games)', [FloatStr(OpenSkillOrdinal(P.OpenSkill[Family]), 1), P.OpenSkill[Family].Games])
      else
        Result := 'unrated';
    else
      Result := '';
  end;
end;

function SkillSystemName(E: TZSEngine): AnsiString;
begin
  case E.RatingSystem of
    RS_MMR: Result := 'MMR';
    RS_GLICKO2: Result := 'Glicko-2';
    RS_OPENSKILL: Result := 'OpenSkill';
    else Result := 'ELO';
  end;
end;

{ Every method on its own, so !otherstats can show them next to each other no matter which one
  the ranking uses. }
function MmrText(const P: TPlayerProfile; Family: LongInt): AnsiString;
begin
  if P.Mmr[Family].Games > 0 then
    Result := Format('%s (%d)', [FloatStr(P.Mmr[Family].R, 0), P.Mmr[Family].Games])
  else
    Result := 'unrated';
end;

function GlickoText(E: TZSEngine; const P: TPlayerProfile; Family: LongInt): AnsiString;
begin
  if P.Glicko[Family].Games > 0 then
    Result := Format('%s (%d)', [FloatStr(GlickoConservative(P.Glicko[Family], E.Cfg.GlickoConservative), 0),
      P.Glicko[Family].Games])
  else
    Result := 'unrated';
end;

function OpenSkillText(const P: TPlayerProfile; Family: LongInt): AnsiString;
begin
  if P.OpenSkill[Family].Games > 0 then
    Result := Format('%s (%d)', [FloatStr(OpenSkillOrdinal(P.OpenSkill[Family]), 1), P.OpenSkill[Family].Games])
  else
    Result := 'unrated';
end;

function FamilyName(Family: LongInt): AnsiString;
begin
  case Family of
    RF_FFA: Result := 'FFA';
    RF_TEAM: Result := 'Team';
    else Result := 'CTF';
  end;
end;

function ObjectiveMode(E: TZSEngine): Boolean;
begin
  Result := E.Match.GameStyle in [GS_CTF, GS_INF, GS_HTF];
end;

function WeaponView(const P: TPlayerProfile; Slot: LongInt): TWeaponView;
var
  W: LongInt;
begin
  Result := Default(TWeaponView);
  if (Slot < 0) or (Slot >= WSLOT_COUNT) then
    Exit;
  Result.Kills := P.Weapons[Slot].Kills;
  Result.Deaths := P.Weapons[Slot].Deaths;
  Result.Shots := P.Weapons[Slot].Shots;
  Result.Hits := P.Weapons[Slot].Hits;
  Result.Headshots := P.Weapons[Slot].Headshots;
  Result.HSKills := P.Weapons[Slot].HSKills;
  Result.Damage := P.Weapons[Slot].Damage;
  Result.DamageIn := P.Weapons[Slot].DamageReceived;
  Result.Time := P.Weapons[Slot].TimeUsedSeconds;
  Result.Longest := P.Weapons[Slot].LongestKill;
  { accounts imported from 4.x kept some weapons only in these counters }
  W := SlotWeapon(Slot);
  case W of
    WEP_M79:
      begin
        Result.Hits := Max(Result.Hits, Int64(P.M79HurtsEnemy));
        Result.Shots := Max(Result.Shots, Int64(P.M79Shots));
      end;
    WEP_KNIFE:
      begin
        Result.Shots := Max(Result.Shots, Int64(P.KnivesThrows));
        Result.Hits := Max(Result.Hits, Int64(P.KnivesThrowsHitsEnemy) + P.KnivesStabsEnemy);
      end;
    WEP_CHAINSAW:
      begin
        Result.Hits := Max(Result.Hits, Int64(P.ChainsawHurtsEnemy));
        Result.Time := Max(Result.Time, Int64(P.ChainsawTimeUsedSeconds));
      end;
    WEP_LAW:
      begin
        Result.Hits := Max(Result.Hits, Int64(P.M72LAWHurtsEnemy));
        Result.Shots := Max(Result.Shots, Int64(P.M72LAWShots));
      end;
    WEP_FLAMER:
      begin
        Result.Hits := Max(Result.Hits, Int64(P.FlamethrowerHitsEnemy));
        Result.Shots := Max(Result.Shots, Int64(P.FlamethrowerShots));
      end;
    WEP_BOW:
      begin
        Result.Kills := Max(Result.Kills, Int64(P.RamboMode.KillsByBow));
        Result.Time := Max(Result.Time, P.RamboMode.TimeWithBow);
      end;
    WEP_M2:
      Result.Hits := Max(Result.Hits, Int64(P.M2MGHitsEnemy));
    WEP_NONE:
      Result.Hits := Max(Result.Hits, Int64(P.HandsHurtsEnemy));
    WEP_FRAG:
      begin
        Result.Shots := Max(Result.Shots, Int64(P.NadesThrows));
        Result.Hits := Max(Result.Hits, Int64(P.NadeHurtsEnemy));
      end;
    WEP_CLUSTERNADE:
      begin
        Result.Shots := Max(Result.Shots, Int64(P.ClusterNadesThrows));
        Result.Hits := Max(Result.Hits, Int64(P.ClusterNadesHurtsEnemy));
      end;
  end;
  Result.Shots := Max(Result.Shots, Result.Hits);
end;

{ why a text is no weapon, in one line }
function WeaponProblem(const Text, HelpCmd: AnsiString): AnsiString;
begin
  if ResolveWeapon(Text) = -3 then
    Result := Clip(Format('"%s" can be more than one weapon: %s.', [Clip(Trim(Text), 30), WeaponCandidates(Text)]), LINE_W)
  else
    Result := Format('Unknown weapon: %s. %s help lists the names.', [Clip(Trim(Text), 40), HelpCmd]);
end;

{ "<weapon> [who]": the weapon is the longest start of the text, up to three words, that names
  one - whole names first, then the beginning, a part or a small typo of a single word - and the
  rest (Tail) says whose numbers: a player (name, part of it or #id), or with ByRank a ranking
  position. Nothing after the weapon means the caller. False with Why when the text holds no
  weapon or the rest is no ranking position. }
function SplitWeaponTarget(E: TZSEngine; Slot: LongInt; const Rest: AnsiString; ByRank: Boolean;
  out Weapon, Idx: LongInt; out Tail, Why: AnsiString): Boolean;
var
  S, Head: AnsiString;
  Ends: array[1..3] of LongInt;
  n, i, h, Pass: LongInt;
  NoTail: Boolean;
begin
  Result := False;
  Why := '';
  Tail := '';
  Idx := -1;
  Weapon := -2;
  S := Trim(Rest);
  { where each of the first three words ends }
  n := 0;
  i := 1;
  while (i <= Length(S)) and (n < 3) do
  begin
    while (i <= Length(S)) and (S[i] = ' ') do
      Inc(i);
    if i > Length(S) then
      Break;
    while (i <= Length(S)) and (S[i] <> ' ') do
      Inc(i);
    Inc(n);
    Ends[n] := i - 1;
  end;
  NoTail := False;
  for Pass := 1 to 2 do
    for h := n downto 1 do
    begin
      Head := Copy(S, 1, Ends[h]);
      Tail := Trim(Copy(S, Ends[h] + 1, MaxInt));
      if Pass = 1 then
        Weapon := ResolveWeaponExact(Head)
      else
        Weapon := ResolveWeapon(Head);
      if Weapon < 0 then
        Continue;
      if ByRank then
      begin
        { a ranking position has to follow: a shorter weapon may leave one ("!wepi 1 3") }
        if Tail = '' then
        begin
          NoTail := True;
          Continue;
        end;
        if not AllDigits(Tail) or (StrToIntDef(Tail, 0) <= 0) then
        begin
          Why := '!wepi takes a ranking position after the weapon, e.g. !wepi ak 3.';
          Exit(False);
        end;
        Idx := IndexAtRank(E, Tail);
      end
      else if Tail = '' then
        Idx := ViewerIndex(E, Slot)
      else
        Idx := FindProfileText(E, Tail, Slot);
      Exit(True);
    end;
  Weapon := -2;
  Tail := '';
  if NoTail then
    Why := 'Usage: !wepi <weapon> <ranking position>  (e.g. !wepi ak 3)'
  else if n > 1 then
    { no start of the text names a weapon: say it about the first word }
    Why := WeaponProblem(Copy(S, 1, Ends[1]), '!wep')
  else
    Why := WeaponProblem(S, '!wep');
end;

{ a weapon slot from a text, or -1 after telling the caller why there is none }
function WeaponSlotOrSay(E: TZSEngine; Slot: LongInt; const Text, HelpCmd: AnsiString): LongInt;
var
  W: LongInt;
begin
  W := ResolveWeapon(Trim(Text));
  Result := -1;
  if W >= 0 then
    Result := WepSlot(W);
  if Result < 0 then
    Out(E, Slot, WeaponProblem(Text, HelpCmd), CLR_BAD);
end;

{ a map by its exact name, otherwise the most played map whose name starts with or contains the text }
function FindMapText(E: TZSEngine; const Text: AnsiString): LongInt;
var
  k, Best: LongInt;
  Low: AnsiString;
begin
  Result := E.DB.FindMap(Trim(Text), False);
  if (Result >= 0) or (Trim(Text) = '') then
    Exit;
  Low := LowerCase(Trim(Text));
  Best := -1;
  for k := 0 to E.DB.MapCount - 1 do
    if StartsLower(E.DB.Maps[k].MapName, Low) and
       ((Best < 0) or (E.DB.Maps[k].ActiveTimePlays > E.DB.Maps[Best].ActiveTimePlays)) then
      Best := k;
  if Best < 0 then
    for k := 0 to E.DB.MapCount - 1 do
      if ContainsLower(E.DB.Maps[k].MapName, Low) and
         ((Best < 0) or (E.DB.Maps[k].ActiveTimePlays > E.DB.Maps[Best].ActiveTimePlays)) then
        Best := k;
  Result := Best;
end;

{$I zs_cmd_mapvote.inc}
{$I zs_cmd_profile.inc}
{$I zs_cmd_fight.inc}
{$I zs_cmd_lists.inc}
{$I zs_cmd_maps.inc}
{$I zs_cmd_weapons.inc}
{$I zs_cmd_matrix.inc}
{$I zs_cmd_server.inc}
{$I zs_cmd_balance.inc}

{ ---------------- paging ---------------- }

procedure RunQuery(E: TZSEngine; Slot, Kind: LongInt; const Query: AnsiString; Page: LongInt);
begin
  case Kind of
    QK_TOP: ListTop(E, Slot, Page);
    QK_TOPBY: ListTopBy(E, Slot, Query, Page);
    QK_SEARCH: ListSearch(E, Slot, Query, Page, False);
    QK_SEARCH_ADMIN: ListSearch(E, Slot, Query, Page, True);
    QK_TOPMAPS: ListTopMaps(E, Slot, Page);
    QK_TOPMAPSBY: ListTopMapsBy(E, Slot, Query, Page);
    QK_TOPWEAPONS: ListTopWeapons(E, Slot, Query, Page);
    QK_TOPPERIOD: ListTopPeriod(E, Slot, Query, Page);
    QK_TOPSKILL: ListTopSkill(E, Slot, Page);
    QK_TOPSEASON: ListTopSeason(E, Slot, Query, Page);
    QK_SEASONS: ListSeasons(E, Slot, Page);
    QK_MATCHUP: CmdMatchups(E, Slot, Query, Page);
    QK_MAPS: ListMapsList(E, Slot, Page, '');
    QK_ALLMAPS: ListAllMaps(E, Slot, Query, Page);
    QK_SEARCHMAP: ListSearchMaps(E, Slot, Query, Page);
    QK_PLAYERMAPS, QK_RIVALS, QK_MAPRIVALS, QK_VERSUS, QK_PMATCHUP, QK_MAPMATCHUP, QK_MAPWEAPONS:
      MatrixPage(E, Slot, Kind, Query, Page);
  end;
end;

procedure Navigate(E: TZSEngine; Slot: LongInt; const Cmd, Arg: AnsiString; Admin: Boolean);
var
  St: PSlotExtra;
  NewPage: LongInt;
begin
  St := StateOf(E, Slot);
  if St^.LastQueryKind = QK_NONE then
  begin
    Out(E, Slot, 'Nothing to page through yet - open a list first, e.g. !top.', CLR_WARN);
    Exit;
  end;
  { IP, HWID and SteamID of the admin search only while the caller still is an admin }
  if (St^.LastQueryKind = QK_SEARCH_ADMIN) and not Admin then
    St^.LastQueryKind := QK_SEARCH;
  if Cmd = 'zs_next' then
    NewPage := St^.Page + 1
  else if Cmd = 'zs_prev' then
    NewPage := St^.Page - 1
  else if Cmd = 'zs_first' then
    NewPage := 1
  else if Cmd = 'zs_end' then
    NewPage := St^.Pages
  else
    NewPage := StrToIntDef(Arg, St^.Page);
  { /zs_next after the last page shows the first one, /zs_prev before the first one the last }
  if NewPage > Max(1, St^.Pages) then
  begin
    if Cmd = 'zs_next' then
      NewPage := 1
    else
      NewPage := Max(1, St^.Pages);
  end
  else if NewPage < 1 then
  begin
    if Cmd = 'zs_page' then
      NewPage := 1
    else
      NewPage := Max(1, St^.Pages);
  end;
  if (St^.LastQueryKind in [QK_TOPBY, QK_SEARCH, QK_SEARCH_ADMIN, QK_TOPWEAPONS, QK_TOPPERIOD, QK_TOPMAPSBY,
     QK_MAPRIVALS, QK_MAPWEAPONS]) and not SearchAllowed(E, Slot) then
    Exit;
  RunQuery(E, Slot, St^.LastQueryKind, St^.LastQuery, NewPage);
end;

{ ---------------- dispatcher ---------------- }

function DuplicateAlias: AnsiString;

  function ScanTable(const Table: array of TMetricDef; const TableName: AnsiString): AnsiString;
  var
    Seen: TStringList;
    i, k: LongInt;
    Names: TStringArray;
  begin
    Result := '';
    Seen := TStringList.Create;
    try
      Seen.Sorted := True;
      Seen.Duplicates := dupAccept;
      for i := 0 to High(Table) do
      begin
        Names := SplitWords(Table[i].Aliases);
        for k := 0 to High(Names) do
        begin
          if Seen.IndexOf(Names[k]) >= 0 then
            Exit(Format('%s: "%s" is used by more than one metric (entry %d)', [TableName, Names[k], i]));
          Seen.Add(Names[k]);
        end;
      end;
    finally
      Seen.Free;
    end;
  end;

begin
  Result := ScanTable(PLAYER_METRICS, 'player metrics');
  if Result = '' then
    Result := ScanTable(WEAPON_METRICS, 'weapon metrics');
  if Result = '' then
    Result := ScanTable(MAP_METRICS, 'map metrics');
end;

function ExecuteCommand(E: TZSEngine; Slot: LongInt; const W: TStringArray; Source: LongInt; Admin: Boolean): Boolean;
var
  Cmd, Arg, Rest: AnsiString;
  Idx, N, S: LongInt;
  TopHint: Boolean;
begin
  Result := True;
  if Length(W) = 0 then
    Exit(False);
  { what NotFound reports belongs to this command only: what an earlier command found out and
    did not report (the ranking of every server, a refused position) is forgotten }
  FindRefused := False;
  PoolRankValid := False;
  RankRefusal := '';
  CallerAdmin := Admin;
  SearchPaid := False;
  Cmd := BareCommand(W[0]);
  Rest := Trim(RestAfterWords(JoinWords(W), 1));
  if Length(W) > 1 then
    Arg := W[1]
  else
    Arg := '';

  if (Cmd = 'zitro') or (Cmd = 'help') or (Cmd = 'reginfo') or
     (Cmd = 'info') or (Cmd = 'credits') or (Cmd = 'autor') or (Cmd = 'tworca') then
    CmdHelp(E, Slot, Admin)
  else if Cmd = 'contact' then
  begin
    { ContactText may be set empty in settings.ini }
    if Trim(E.Cfg.ContactText) = '' then
      Out(E, Slot, 'This server has no contact set.', CLR_HINT)
    else
      Out(E, Slot, E.Cfg.ContactText, CLR_HINT);
  end
  { team balance }
  else if (Cmd = 'bal') or (Cmd = 'teams') then
    CmdBalance(E, Slot)
  else if (Cmd = 'switch') or (Cmd = 'join') then
  begin
    if Slot <= 0 then
      Out(E, Slot, '!switch and !join are for players on the server.', CLR_WARN)
    else if Cmd = 'switch' then
      E.BalSwitch(Slot)
    else
      E.BalJoinTeam(Slot);
  end
  else if Cmd = 'hud' then
    CmdHud(E, Slot)
  { the caller's last deaths (zs_cmd_fight.inc) }
  else if Cmd = 'lastfight' then
    CmdLastFight(E, Slot, Rest)

  { profiles }
  else if Cmd = 'stats' then
    CmdStats(E, Slot, TargetIndex(E, Slot, Rest))
  else if Cmd = 'statsi' then
    CmdStats(E, Slot, IndexAtRank(E, Arg))
  else if Cmd = 'otherstats' then
    CmdOtherStats(E, Slot, TargetIndex(E, Slot, Rest))
  else if Cmd = 'otherstatsi' then
    CmdOtherStats(E, Slot, IndexAtRank(E, Arg))
  else if Cmd = 'status' then
    CmdStatus(E, Slot, TargetIndex(E, Slot, Rest))
  else if Cmd = 'statusi' then
    CmdStatus(E, Slot, IndexAtRank(E, Arg))
  else if Cmd = 'rank' then
    CmdRank(E, Slot, TargetIndex(E, Slot, Rest))
  else if (Cmd = 'ranki') or (Cmd = 'ranknum') then
    CmdRank(E, Slot, IndexAtRank(E, Arg))
  else if (Cmd = 'session') or (Cmd = 'today') then
  begin
    { someone else's session: a player on the server, by name or #id }
    if Trim(Rest) = '' then
      CmdSession(E, Slot, Slot)
    else
    begin
      N := SessionSlotOf(E, Slot, Rest);
      if N = 0 then
        N := -1;
      CmdSession(E, Slot, N);
    end;
  end
  else if Cmd = 'sessioni' then
  begin
    { no account at that place is said as for the other "i" commands; an account that is not
      on the server has no session }
    N := IndexAtRank(E, Arg);
    if not E.DB.Valid(N) then
      NotFound(E, Slot)
    else
    begin
      S := SlotOfIndex(E, N);
      if S = 0 then
        S := -1;
      CmdSession(E, Slot, S);
    end;
  end
  else if Cmd = 'rambo' then
    CmdRambo(E, Slot, TargetIndex(E, Slot, Rest))
  else if Cmd = 'ramboi' then
    CmdRambo(E, Slot, IndexAtRank(E, Arg))
  else if (Cmd = 'spree') or (Cmd = 'pointmatch') or (Cmd = 'pm') then
    CmdSpree(E, Slot, TargetIndex(E, Slot, Rest))
  else if Cmd = 'spreei' then
    CmdSpree(E, Slot, IndexAtRank(E, Arg))
  else if (Cmd = 'achievements') or (Cmd = 'ach') or (Cmd = 'badges') then
    CmdAchievements(E, Slot, TargetIndex(E, Slot, Rest))
  else if (Cmd = 'achievementsi') or (Cmd = 'achi') or (Cmd = 'badgesi') then
    CmdAchievements(E, Slot, IndexAtRank(E, Arg))
  { the list alone (no account) only when nobody was asked for }
  else if (Cmd = 'achlist') or (Cmd = 'achievementslist') or (Cmd = 'achlisti') or (Cmd = 'achievementslisti') then
  begin
    if (Cmd = 'achlisti') or (Cmd = 'achievementslisti') then
      Idx := IndexAtRank(E, Arg)
    else
      Idx := TargetIndex(E, Slot, Rest);
    if not E.DB.Valid(Idx) and ((Rest <> '') or (Cmd = 'achlisti') or (Cmd = 'achievementslisti')) then
      NotFound(E, Slot)
    else
      CmdAchievementList(E, Slot, Idx);
  end

  { rankings }
  else if Cmd = 'top' then
  begin
    if Rest = '' then
      ListTop(E, Slot, 1)
    else if StrToIntDef(Rest, -1) > 0 then
      ListTop(E, Slot, StrToIntDef(Rest, 1))
    { a number that is no page (0, -2, one too big) is no weapon by its number either }
    else if (StrToIntDef(Rest, 1) <= 0) or AllDigits(Rest) then
      Out(E, Slot, 'Usage: !top [page]   !top <player>   !top <metrics> = !topby <metrics>', CLR_WARN)
    { a metric by its whole name; a player on the server called exactly so is the player }
    else if IsPlayerMetricList(Rest) and not OnlineNameIs(E, Rest) then
    begin
      if HeavyAllowed(E, Slot, Admin) then
        ListTopBy(E, Slot, Rest, 1);
    end
    else
    begin
      Idx := FindProfileText(E, Rest, Slot);
      { a player called like a metric, or a text that names one only roughly: that list is !topby }
      TopHint := not FindRefused and (IsPlayerMetricList(Rest) or (not E.DB.Valid(Idx) and IsPlayerMetricList(Rest, False)));
      if E.DB.Valid(Idx) and (RankingPosition(E, Idx) > 0) then
        ListTopAround(E, Slot, RankingPosition(E, Idx))
      else if E.DB.Valid(Idx) then
        Out(E, Slot, E.DB.Profiles[Idx]^.ActiveName + ' is not in the ranking yet.', CLR_WARN)
      else
        NotFound(E, Slot);
      if TopHint then
        Out(E, Slot, 'The list by that metric: !topby ' + Clip(Rest, 40), CLR_HINT);
    end;
  end
  else if Cmd = 'topp' then
    ListTop(E, Slot, StrToIntDef(Arg, 1))
  else if Cmd = 'topi' then
    ListTopAround(E, Slot, StrToIntDef(Arg, 1))
  else if Cmd = 'topme' then
  begin
    Idx := ViewerIndex(E, Slot);
    if E.DB.Valid(Idx) and (RankingPosition(E, Idx) > 0) then
      ListTopAround(E, Slot, RankingPosition(E, Idx))
    else
      Out(E, Slot, 'You are not in the ranking yet.', CLR_WARN);
  end
  else if Cmd = 'topid' then
  begin
    N := StrToIntDef(Arg, Slot);
    Idx := -1;
    if E.SlotValid(N) and E.Live[N].Human then
      Idx := E.Identity.ProfileIndex(N);
    if E.DB.Valid(Idx) and (RankingPosition(E, Idx) > 0) then
      ListTopAround(E, Slot, RankingPosition(E, Idx))
    else if E.DB.Valid(Idx) then
      Out(E, Slot, E.Live[N].Name + ' is not in the ranking yet.', CLR_WARN)
    else
      Out(E, Slot, 'Usage: !topid <player slot number>', CLR_WARN);
  end
  else if (Cmd = 'topo') or (Cmd = 'toponline') then
    ListTopOnline(E, Slot)
  else if Cmd = 'topby' then
  begin
    if (Rest = '') or SameText(Rest, 'help') then
      TopByHelp(E, Slot)
    { a text without a metric gets the help without a turn of the list limits }
    else if not HasPlayerMetric(Rest) or HeavyAllowed(E, Slot, Admin) then
      ListTopBy(E, Slot, Rest, 1);
  end
  else if (Cmd = 'topskill') or (Cmd = 'toprating') then
  begin
    { with elo the list falls back to !topby mmr, which sorts every account }
    if (E.RatingSystem <> RS_ELO) or HeavyAllowed(E, Slot, Admin) then
      ListTopSkill(E, Slot, Max(1, StrToIntDef(Arg, 1)));
  end
  else if Cmd = 'topseason' then
    ListTopSeason(E, Slot, Arg, 1)
  else if Cmd = 'seasons' then
    ListSeasons(E, Slot, Max(1, StrToIntDef(Arg, 1)))
  else if (Cmd = 'topday') or (Cmd = 'topweek') or (Cmd = 'topmonth') then
  begin
    if HeavyAllowed(E, Slot, Admin) then
      ListTopPeriod(E, Slot, Copy(Cmd, 4, MaxInt), Max(1, StrToIntDef(Arg, 1)));
  end
  { search is an AntiFake command as well: here it is zs_search (or zssearch) }
  else if (Cmd = 'zs_search') or (Cmd = 'zssearch') or (Cmd = 'searcha') then
  begin
    if Rest = '' then
      Out(E, Slot, 'Usage: !zs_search <part of a name>' + BoolToStr(Admin, '   (admins: /zs_search also finds IP, HWID, SteamID)', ''), CLR_WARN)
    else if (Cmd = 'searcha') and not Admin then
      Out(E, Slot, 'This command is for admins. Use !zs_search <text>.', CLR_WARN)
    { the server shows a chat line to everybody before a script reads it: an IP, a HWID or a SteamID
      looked for there is read by every player, so the admin search runs as a / command only }
    else if (Cmd = 'searcha') and (Source = SRC_CHAT) then
      Out(E, Slot, 'Use /searcha <text>, never in chat: everybody on the server reads the chat.', CLR_BAD)
    else if Admin and ((Cmd = 'searcha') or (Source <> SRC_CHAT)) then
    begin
      if HeavyAllowed(E, Slot, Admin) then
        ListSearch(E, Slot, Rest, 1, True);
    end
    else if HeavyAllowed(E, Slot, Admin) then
      ListSearch(E, Slot, Rest, 1, False);
  end

  { maps }
  else if Cmd = 'mapstats' then
    CmdMapStats(E, Slot, Rest)
  else if Cmd = 'topmaps' then
  begin
    if (Rest = '') or (StrToIntDef(Rest, -1) > 0) then
      ListTopMaps(E, Slot, Max(1, StrToIntDef(Rest, 1)))
    else
    begin
      Idx := FindMapText(E, Rest);
      if Idx >= 0 then
        ListTopMapsAround(E, Slot, MapPlayRank(E, Idx))
      else
        Out(E, Slot, 'Map not found: ' + Clip(Rest, LINE_W - 15), CLR_BAD);
    end;
  end
  else if Cmd = 'topmapsp' then
    ListTopMaps(E, Slot, Max(1, StrToIntDef(Arg, 1)))
  else if Cmd = 'topmapsi' then
    ListTopMapsAround(E, Slot, Max(1, StrToIntDef(Arg, 1)))
  else if Cmd = 'topmapsby' then
  begin
    if (Rest = '') or SameText(Rest, 'help') then
      TopMapsByHelp(E, Slot)
    else if not HasMapMetric(Rest) or HeavyAllowed(E, Slot, Admin) then
      ListTopMapsBy(E, Slot, Rest, 1);
  end
  else if (Cmd = 'heatmap') or (Cmd = 'heat') then
    CmdHeatmap(E, Slot, Rest)

  { what the players did on the maps ([Matrix], zs_cmd_matrix.inc): a player on one map, a player
    over all his maps, one map with all its players; the "i" forms take a ranking position, matrix is
    matchup }
  else if (Cmd = 'mapplayerstats') or (Cmd = 'mapplayerstatsi') then
    CmdMapPlayerStats(E, Slot, Rest, Cmd = 'mapplayerstatsi')
  else if (Cmd = 'mapplayerotherstats') or (Cmd = 'mapplayerotherstatsi') then
    CmdMapPlayerOtherStats(E, Slot, Rest, Cmd = 'mapplayerotherstatsi')
  else if (Cmd = 'mapplayerweapstats') or (Cmd = 'mapplayerweapstatsi') or (Cmd = 'mapplayerwepstats') or
          (Cmd = 'mapplayerwepstatsi') then
    CmdMapPlayerWeapStats(E, Slot, Rest, (Cmd = 'mapplayerweapstatsi') or (Cmd = 'mapplayerwepstatsi'))
  else if (Cmd = 'mapplayerrivals') or (Cmd = 'mapplayerrivalsi') then
    CmdMapPlayerRivals(E, Slot, Rest, Cmd = 'mapplayerrivalsi')
  else if (Cmd = 'mapplayermatchup') or (Cmd = 'mapplayermatrix') or (Cmd = 'mapplayermatchupi') or
          (Cmd = 'mapplayermatrixi') then
    CmdMapPlayerMatchup(E, Slot, Rest, (Cmd = 'mapplayermatchupi') or (Cmd = 'mapplayermatrixi'))
  else if (Cmd = 'playerheatmap') or (Cmd = 'playerheatmapi') then
    CmdPlayerHeatmap(E, Slot, Rest, Cmd = 'playerheatmapi')
  else if (Cmd = 'playermaps') or (Cmd = 'playermapsi') then
    CmdPlayerMaps(E, Slot, Rest, Cmd = 'playermapsi')
  else if (Cmd = 'rivals') or (Cmd = 'rivalsi') then
    CmdRivals(E, Slot, Rest, Cmd = 'rivalsi')
  else if (Cmd = 'versus') or (Cmd = 'versusi') then
    CmdVersus(E, Slot, Rest, Cmd = 'versusi')
  else if (Cmd = 'playermatchup') or (Cmd = 'playermatrix') or (Cmd = 'playermatchupi') or (Cmd = 'playermatrixi') then
    CmdPlayerMatchup(E, Slot, Rest, (Cmd = 'playermatchupi') or (Cmd = 'playermatrixi'))
  { the pairs and the weapons of a map go through every record of it: a list limit once the map is
    known }
  else if Cmd = 'maprivals' then
    CmdMapRivals(E, Slot, Rest, Admin)
  else if (Cmd = 'mapmatchup') or (Cmd = 'mapmatrix') then
    CmdMapMatchup(E, Slot, Rest)
  else if (Cmd = 'mapweapstats') or (Cmd = 'mapweapsstats') or (Cmd = 'mapwepstats') or (Cmd = 'mapwepsstats') then
    CmdMapWeapStats(E, Slot, Rest, Admin)
  else if (Cmd = 'mapwep') or (Cmd = 'mapweapon') or (Cmd = 'mapweap') then
    CmdMapWeapon(E, Slot, Rest, Admin)

  { the map vote (zs_cmd_mapvote.inc) }
  else if IsMapVoteCommand(Cmd) then
    CmdMapVote(E, Slot, Cmd, Rest, Source, Admin)

  { weapons }
  else if (Cmd = 'allweapons') or (Cmd = 'weapons') then
    CmdAllWeapons(E, Slot, TargetIndex(E, Slot, Rest))
  else if (Cmd = 'allweaponsi') or (Cmd = 'weaponsi') then
    CmdAllWeapons(E, Slot, IndexAtRank(E, Arg))
  { the same table sorted by weapon metrics }
  else if (Cmd = 'allweaponsby') or (Cmd = 'weaponsby') then
    CmdAllWeaponsBy(E, Slot, Rest, False)
  else if (Cmd = 'allweaponsbyi') or (Cmd = 'weaponsbyi') then
    CmdAllWeaponsBy(E, Slot, Rest, True)
  else if (Cmd = 'wep') or (Cmd = 'weapon') then
    CmdWeapon(E, Slot, Rest, False)
  else if (Cmd = 'wepi') or (Cmd = 'weaponi') then
    CmdWeapon(E, Slot, Rest, True)
  { the same two views for the whole server: they read every account, so they are heavy }
  else if (Cmd = 'serverweapons') or (Cmd = 'serverweps') or (Cmd = 'srvweapons') or (Cmd = 'srvweps') or
          (Cmd = 'serverweaps') or (Cmd = 'srvweaps') then
  begin
    if HeavyAllowed(E, Slot, Admin) then
      CmdServerWeapons(E, Slot);
  end
  else if (Cmd = 'serverweaponsby') or (Cmd = 'serverwepsby') or (Cmd = 'srvweaponsby') or (Cmd = 'srvwepsby') or
          (Cmd = 'serverweapsby') or (Cmd = 'srvweapsby') then
  begin
    { the help and a text without a metric cost nothing; only a real table reads every account }
    if (Rest = '') or SameText(Rest, 'help') then
      WeaponsByHelp(E, Slot, True)
    else if not HasWeaponMetric(Rest, False) or HeavyAllowed(E, Slot, Admin) then
      CmdServerWeaponsBy(E, Slot, Rest);
  end
  else if (Cmd = 'serverwep') or (Cmd = 'serverweapon') or (Cmd = 'srvwep') or (Cmd = 'serverweap') or
          (Cmd = 'srvweap') then
  begin
    { the help and an unknown weapon cost nothing; only a real lookup reads every account }
    if (Rest = '') or SameText(Rest, 'help') or (WepSlot(ResolveWeapon(Rest)) < 0) then
      CmdServerWeapon(E, Slot, Rest)
    else if HeavyAllowed(E, Slot, Admin) then
      CmdServerWeapon(E, Slot, Rest);
  end
  else if (Cmd = 'matchup') or (Cmd = 'matchups') or (Cmd = 'matrix') then
  begin
    { a number at the end is the page: !matchup 2, !matchup ak 2 (weapons go by name here);
      a name that ends in a number stays a name: !matchup ak 47, !matchup ruger 77 }
    N := 1;
    if (Length(W) > 1) and AllDigits(W[High(W)]) and ((Length(W) = 2) or (ResolveWeaponExact(Rest) < 0)) then
    begin
      N := Max(1, StrToIntDef(W[High(W)], 1));
      Rest := Trim(Copy(Rest, 1, Length(Rest) - Length(W[High(W)])));
    end;
    CmdMatchups(E, Slot, Rest, N);
  end
  else if (Cmd = 'topweapons') or (Cmd = 'topweps') or (Cmd = 'topweaps') then
    CmdTopWeapons(E, Slot, Rest, Admin)
  else if (Cmd = 'topweaponsby') or (Cmd = 'topwepsby') or (Cmd = 'topweapsby') then
  begin
    if (Rest = '') or SameText(Rest, 'help') then
      TopWeaponsByHelp(E, Slot)
    else if not HasWeaponMetric(Rest, False) or HeavyAllowed(E, Slot, Admin) then
      ListTopWeapons(E, Slot, Rest, 1);
  end

  { server }
  else if (Cmd = 'server') or (Cmd = 'serverstats') then
  begin
    if HeavyAllowed(E, Slot, Admin) then
      CmdServerStats(E, Slot);
  end
  else if Cmd = 'activity' then
    CmdActivity(E, Slot)

  { pages }
  else if (Cmd = 'zs_next') or (Cmd = 'zs_prev') or (Cmd = 'zs_page') or (Cmd = 'zs_first') or (Cmd = 'zs_end') then
    Navigate(E, Slot, Cmd, Arg, Admin)

  { admin }
  else if (Cmd = 'zs_status') or (Cmd = 'zs_statusid') or (Cmd = 'zs_statusi') or (Cmd = 'zs_suspects') or
          (Cmd = 'zs_perf') or (Cmd = 'zs_export') then
  begin
    if not Admin then
      Out(E, Slot, 'This command is for admins.', CLR_BAD)
    else if Cmd = 'zs_status' then
      CmdAudit(E, Slot, FindProfileText(E, Rest))
    else if Cmd = 'zs_statusid' then
      CmdAudit(E, Slot, E.DB.IndexOfId(StrToIntDef(StringReplace(Arg, '#', '', []), -1)))
    else if Cmd = 'zs_statusi' then
      CmdAudit(E, Slot, IndexAtRank(E, Arg))
    else if Cmd = 'zs_suspects' then
      CmdSuspects(E, Slot)
    else if Cmd = 'zs_perf' then
      CmdPerf(E, Slot)
    else if E.IsReadOnly then
      Out(E, Slot, '[ZitroStats] The database is read-only (see the server console), nothing is exported.', CLR_BAD)
    else if not (E.Cfg.JSONExportEnabled or E.Cfg.FullExportEnabled) then
      Out(E, Slot, '[ZitroStats] The JSON export is off (settings.ini [Export]: JSONExportEnabled, FullExportEnabled).', CLR_WARN)
    else
    begin
      E.ExportRequested := True;
      E.ExportAsker := Slot;
      Out(E, Slot, '[ZitroStats] Writing the JSON export; you hear when the files are written.', CLR_HINT);
    end;
  end
  { the other admin commands run in the engine before this (AdminCommand); a player who types
    one hears why nothing happens }
  else if not Admin and IsAdminCommand(Cmd) then
    Out(E, Slot, 'This command is for admins.', CLR_BAD)
  { the password commands are answered for a player before this (Identity.HandleCommand) }
  else if (Slot <= 0) and (Pos(' ' + Cmd + ' ', IDENTITY_COMMANDS) > 0) then
    Out(E, Slot, 'The password commands are for players on the server.', CLR_WARN)
  else
    Result := False;
end;

end.
