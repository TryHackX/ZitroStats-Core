program test_mapvote;

{ The map vote (zs_maps, zs_engine_mapvote.inc, zs_cmd_mapvote.inc): the scan of the maps folder
  (.pms in any case, other files left out), the search, the maps list main.pas sends, and the vote
  through the engine - starts, votes, the percent with and without spectators, the rules (starter
  wait, time left, the first seconds of a map, kick votes, players), the actions for main.pas
  (VotePercent start and end, the map change), the statistics, the admin views and the notice of a
  /recompile. Every answer is checked to come once. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_maps, zs_engine, zs_commands;

var
  Failures: Integer = 0;
  Engine: TZSEngine;
  Pushed: LongInt;
  CurTick: LongInt;
  Acts, AllActs: TStringList;
  Root, MapsDir: AnsiString;

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

procedure MakeFile(const Path, Text: AnsiString);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := Text;
    L.SaveToFile(Path);
  finally
    L.Free;
  end;
end;

{ ---------------- the engine ---------------- }

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
    Sleep(2);
  end;
  Sleep(60);
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

{ everything the engine asked for since the last step: "kind|slot|p1|p2|text" }
procedure Drain;
var
  A: TZSAction;
  S: AnsiString;
begin
  while Engine.PopAction(A) do
  begin
    S := Format('%d|%d|%d|%d|%s', [A.Kind, A.Slot, A.P1, A.P2, A.Text]);
    Acts.Add(S);
    AllActs.Add(S);
  end;
end;

{ the events of a step are in and answered: Acts holds what they caused }
procedure Step;
begin
  WaitProcessed;
  Drain;
end;

function Field(const Entry: AnsiString; Index: LongInt): AnsiString;
var
  k, p: LongInt;
  S: AnsiString;
begin
  S := Entry;
  for k := 1 to Index do
  begin
    p := Pos('|', S);
    if p = 0 then
      Exit('');
    Delete(S, 1, p);
  end;
  if Index < 4 then
  begin
    p := Pos('|', S);
    if p > 0 then
      S := Copy(S, 1, p - 1);
  end;
  Result := S;
end;

function KindOf(const Entry: AnsiString): LongInt;
begin
  Result := StrToIntDef(Field(Entry, 0), -1);
end;

function SlotOf(const Entry: AnsiString): LongInt;
begin
  Result := StrToIntDef(Field(Entry, 1), -1);
end;

function P1Of(const Entry: AnsiString): LongInt;
begin
  Result := StrToIntDef(Field(Entry, 2), -1);
end;

function P2Of(const Entry: AnsiString): LongInt;
begin
  Result := StrToIntDef(Field(Entry, 3), -1);
end;

function TextOf(const Entry: AnsiString): AnsiString;
begin
  Result := Field(Entry, 4);
end;

{ Part = '' holds for any text (Pos of '' is 0) }
function Holds(const Text, Part: AnsiString): Boolean;
begin
  Result := (Part = '') or (Pos(Part, Text) > 0);
end;

{ the actions of the last step of a kind (and a slot, -1 = any) whose text holds Part }
function Count(L: TStringList; Kind, Slot: LongInt; const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to L.Count - 1 do
    if (KindOf(L[k]) = Kind) and ((Slot < 0) or (SlotOf(L[k]) = Slot)) and Holds(TextOf(L[k]), Part) then
      Inc(Result);
end;

function IndexOfAct(L: TStringList; Kind: LongInt; const Part: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  for k := 0 to L.Count - 1 do
    if (KindOf(L[k]) = Kind) and Holds(TextOf(L[k]), Part) then
      Exit(k);
end;

function Said(Slot: LongInt; const Part: AnsiString): Boolean;
begin
  Result := Count(Acts, ACT_CONSOLE, Slot, Part) = 1;
end;

{ exactly this line, once }
function SaidLine(Slot: LongInt; const Line: AnsiString): Boolean;
var
  k, n: LongInt;
begin
  n := 0;
  for k := 0 to Acts.Count - 1 do
    if (KindOf(Acts[k]) = ACT_CONSOLE) and (SlotOf(Acts[k]) = Slot) and (TextOf(Acts[k]) = Line) then
      Inc(n);
  Result := n = 1;
end;

function Told(const Part: AnsiString): Boolean;
begin
  Result := Count(Acts, ACT_BROADCAST, -1, Part) = 1;
end;

{ the console lines to a slot in the last step }
function LinesTo(Slot: LongInt): LongInt;
begin
  Result := Count(Acts, ACT_CONSOLE, Slot, '');
end;

function Broadcasts: LongInt;
begin
  Result := Count(Acts, ACT_BROADCAST, -1, '');
end;

function Written(const Part: AnsiString): Boolean;
begin
  Result := Count(Acts, ACT_WRITELN, -1, Part) >= 1;
end;

{ every line the players saw so far, and every server line of the map vote, fits LINE_W (the
  folder of /zs_maps as well: it is named from the server folder, a long one by its end) }
function AllFit(out Worst: AnsiString): Boolean;
var
  k: LongInt;
  T: AnsiString;
begin
  Result := True;
  Worst := '';
  for k := 0 to AllActs.Count - 1 do
    if (KindOf(AllActs[k]) = ACT_CONSOLE) or ((KindOf(AllActs[k]) = ACT_WRITELN) and
       ((Copy(TextOf(AllActs[k]), 1, 4) = '[Map') or (Pos('map vote', TextOf(AllActs[k])) > 0))) then
    begin
      T := TextOf(AllActs[k]);
      if Length(T) > LINE_W then
      begin
        if Result then
          Worst := Format('(%d) %s', [Length(T), T]);
        Result := False;
      end;
    end;
end;

procedure MapAfter(const Name: AnsiString; Style: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := Name;
  Ev.I[0] := Style;
  Ev.I[1] := 10;
  { a time limit of 10 minutes }
  Ev.I[2] := 10;
  Push(Ev);
end;

procedure MapBefore(const Next: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapBefore);
  Ev.S1 := Next;
  Ev.I[4] := 300;
  Push(Ev);
end;

procedure MapList(const Names: AnsiString; Current, Reason: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeMapList);
  Ev.I[1] := Current;
  Ev.I[2] := Reason;
  Ev.S1 := Names;
  Push(Ev);
end;

procedure TickEv(TimeLeft: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeTick);
  Ev.I[4] := TimeLeft;
  Ev.I[5] := GS_CTF;
  Push(Ev);
end;

procedure Join(Slot: LongInt; const Name, Steam: AnsiString; Team, Human, Admin: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S2 := Steam;
  Ev.S3 := 'HW-' + Name;
  Ev.S4 := '10.0.0.' + IntToStr(Slot);
  if Human = 0 then
  begin
    Ev.S2 := '';
    Ev.S3 := '';
    Ev.S4 := '';
  end;
  Ev.I[0] := Team;
  Ev.I[1] := Human;
  Ev.I[2] := Admin;
  Push(Ev);
end;

procedure Leave(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(Ev);
end;

{ Alice (slot 1) is an admin: every command of hers says so, as main.pas does }
procedure Cmd(Slot: LongInt; const Text: AnsiString; Source: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  Ev.I[0] := Source;
  Ev.I[1] := Ord((Source = SRC_CONSOLE) or (Slot = 1));
  Push(Ev);
end;

procedure Chat(Slot: LongInt; const Text: AnsiString);
begin
  Cmd(Slot, Text, SRC_CHAT);
end;

{ ZS_Ev_Vote: 1 = the vote menu or the server's /votemap asked for a map, 2 = a kick vote started,
  3 = F12 for the vote that shows }
procedure SoldatVote(Slot, Kind: LongInt; const Map: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeVote);
  Ev.Slot := Slot;
  Ev.I[0] := Kind;
  Ev.S1 := Map;
  Push(Ev);
end;

function MapStat(const Name: AnsiString; What: LongInt): LongInt;
var
  M: LongInt;
begin
  Result := -1;
  EnterCriticalSection(Engine.StateLock);
  try
    M := Engine.DB.FindMap(Name, False);
    if M >= 0 then
      case What of
        0: Result := Engine.DB.Maps[M].VoteStarts;
        1: Result := Engine.DB.Maps[M].VotesPassed;
        2: Result := Engine.DB.Maps[M].VotedIn;
      end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

function VoteActive: Boolean;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Result := Engine.MV.Active;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure SetCfg(Kind, Value: LongInt);
begin
  EnterCriticalSection(Engine.StateLock);
  try
    case Kind of
      0: Engine.Cfg.MapVoteCountSpectators := Value <> 0;
      1: Engine.Cfg.MapVoteMinPlayers := Value;
      2: Engine.Cfg.MapVoteAllowAnyMap := Value <> 0;
      3: Engine.Cfg.MapVoteCommands := Value;
      4: Engine.Cfg.MapVoteFilterByStyle := Value <> 0;
    end;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

{ ---------------- the parts of zs_maps on their own ---------------- }

procedure TestUnits;
var
  D: TMapCatalogData;
  S: TMapSearch;
  L: TStringArray;
  O: TIntArray;
  C: TMapCatalog;
  Maps, Maps2: TCatalogMapArray;
  k, Added, Removed, R: LongInt;
  T0: Int64;
  Ok: Boolean;
  Names: AnsiString;
begin
  { the scan: .pms in any case, the case of the name kept; no other file, no folder, no empty name }
  D := ScanMapsFolder(MapsDir);
  Names := '';
  for k := 0 to High(D.Maps) do
    Names := Names + D.Maps[k].Name + ' ';
  Check('scan: the maps folder is found', D.Found and (D.Error = ''));
  Check('scan: every .pms, .PMS and .Pms file and nothing else, sorted by name: ' + Names,
    Names = 'Arena Arena2 ctf_Ash ctf_cs_Ashbury ctf_Run dm_Other inf_Moon ');
  Ok := Length(D.Maps) = 7;
  if Ok then
    Ok := not D.Maps[0].OddExt and (D.Maps[4].Ext = '.PMS') and D.Maps[4].OddExt and (D.Maps[6].Ext = '.Pms') and
      D.Maps[6].OddExt and (D.Maps[2].Ext = '.pms');
  Check('scan: an extension in another case is flagged, with its spelling', Ok);
  D := ScanMapsFolder(MapsDir + PathDelim + 'nothing-here');
  Check('scan: a folder that is not there is found empty', not D.Found and (Length(D.Maps) = 0));

  { the kind of a match first, then the length }
  Check('rank: the whole name beats its beginning', MapMatchRank('ctf_Ash', 'ctf_ash') < MapMatchRank('ctf_Ashbury', 'ctf_ash'));
  Check('rank: the beginning beats the beginning of a word', MapMatchRank('ashes', 'ash') < MapMatchRank('ctf_Ash', 'ash'));
  Check('rank: the beginning of a word beats a part', MapMatchRank('ctf_cs_Ashbury', 'ash') < MapMatchRank('ctf_Clash', 'ash'));
  Check('rank: words split at "_", "-" and spaces', (MapMatchRank('big-ash', 'ash') div MAP_RANK_KIND = MK_WORD) and
    (MapMatchRank('big ash', 'ash') div MAP_RANK_KIND = MK_WORD) and (MapMatchRank('bigash', 'ash') div MAP_RANK_KIND = MK_PART));
  Check('rank: the shorter of the same kind first', MapMatchRank('ctf_Ash', 'ash') < MapMatchRank('ctf_cs_Ashbury', 'ash'));
  Check('rank: no match, no empty text', (MapMatchRank('ctf_Run', 'ash') = -1) and (MapMatchRank('ctf_Run', '') = -1));

  { the search: the best, then the others of its kind, in their order }
  L := ['ctf_Run', 'ctf_Ash', 'ctf_Missing', 'ctf_Arena', 'ctf_cs_Ashbury', 'Mashed', 'ctf_X', 'ctf_Y', 'ctf_Z'];
  S := SearchNames(L, 'ash', 5);
  Check('search: ctf_Ash for "ash", ctf_cs_Ashbury also a word start, Mashed only a part', (S.Best = 1) and
    (S.OtherCount = 1) and (Length(S.Others) = 1) and (S.Others[0] = 4));
  S := SearchNames(L, 'ctf', 3);
  Check('search: equal ones in the order of the list, the others by length and order, counted all', (S.Best = 6) and
    (S.OtherCount = 7) and (Length(S.Others) = 3) and (S.Others[0] = 7) and (S.Others[1] = 8) and (S.Others[2] = 0));
  S := SearchNames(L, 'zzz', 5);
  Check('search: nothing for a text no name holds', (S.Best = -1) and (S.OtherCount = 0));

  { the list main.pas sends }
  L := SplitMapList('ctf_Ash' + #10 + 'ctf_Run' + #13#10 + #10 + 'arena' + #10);
  Check('list: the names in their places, an empty line kept, the last line break ends it', (Length(L) = 4) and
    (L[0] = 'ctf_Ash') and (L[1] = 'ctf_Run') and (L[2] = '') and (L[3] = 'arena'));
  Check('list: no names', Length(SplitMapList('')) = 0);
  L := ['ctf_Run', 'ctf_Ash', 'CTF_ASH', 'arena'];
  O := ListOrderOf(L);
  Check('list: a name in any case, the first place of a name that is there twice', (FindInList(L, O, 'ctf_ash') = 1) and
    (FindInList(L, O, 'ARENA') = 3) and (FindInList(L, O, 'ctf_Run') = 0) and (FindInList(L, O, 'nope') = -1) and
    (FindInList(L, O, '') = -1));

  { the folder: any case, the same case first }
  SetLength(Maps, 3);
  Maps[0].Name := 'arena';
  Maps[1].Name := 'Arena';
  Maps[2].Name := 'ctf_Ash';
  SortCatalog(Maps);
  Check('folder: a name in any case, the same case first', (Maps[FindCatalog(Maps, 'Arena')].Name = 'Arena') and
    (Maps[FindCatalog(Maps, 'arena')].Name = 'arena') and (Maps[FindCatalog(Maps, 'ARENA')].Name <> '') and
    (FindCatalogExact(Maps, 'ARENA') = -1) and (FindCatalog(Maps, 'ctf_ash') = 2) and (FindCatalog(Maps, 'x') = -1));
  Maps2 := Copy(Maps, 0, 2);
  SetLength(Maps2, 3);
  Maps2[2].Name := 'ctf_New';
  SortCatalog(Maps2);
  CatalogDiff(Maps, Maps2, Added, Removed);
  Check('folder: what a new scan added and what is gone', (Added = 1) and (Removed = 1));

  Check('style: ctf_/inf_/htf_ maps for their mode, the others for the rest', MapFitsStyle('ctf_Ash', GS_CTF) and
    not MapFitsStyle('ctf_Ash', GS_DM) and MapFitsStyle('Arena', GS_DM) and not MapFitsStyle('Arena', GS_CTF) and
    MapFitsStyle('INF_Moon', GS_INF) and MapFitsStyle('htf_Tower', GS_HTF) and not MapFitsStyle('htf_Tower', GS_INF));
  Ok := True;
  for k := 1 to 200 do
  begin
    R := RandomIndex(7);
    if (R < 0) or (R > 6) then
      Ok := False;
  end;
  Check('random: always a place of the list', Ok and (RandomIndex(1) = 0) and (RandomIndex(0) = 0));
  Check('the command of F12 and the vote menu', IsVoteMapWord('votemap') and IsVoteMapWord('/VoteMap') and
    not IsVoteMapWord('!votemap') and not IsVoteMapWord('map'));
  Check('the maps folder of the server is two levels above the script folder',
    DefaultMapsFolder('C:' + PathDelim + 'srv' + PathDelim + 'scripts' + PathDelim + 'ZitroStats-Core' + PathDelim) =
    'C:' + PathDelim + 'srv' + PathDelim + 'maps');

  { the thread: asked, it reads the folder and hands the result over once }
  C := TMapCatalog.Create;
  try
    C.RequestScan(MapsDir);
    T0 := MonoMs;
    Ok := False;
    while MonoMs - T0 < 10000 do
    begin
      if C.TakeResult(D) then
      begin
        Ok := True;
        Break;
      end;
      Sleep(5);
    end;
    Check('the thread reads the folder', Ok and (Length(D.Maps) = 7) and (D.Serial = 1));
    Check('a result is handed over once', not C.TakeResult(D));
  finally
    C.Free;
  end;
end;

{ ---------------- the vote through the engine ---------------- }

const
  { the maps list of the server: ctf_Missing has no file, arena is Arena.pms in another case }
  LIST5 = 'ctf_Ash' + #10 + 'ctf_Run' + #10 + 'ctf_Missing' + #10 + 'arena' + #10 + 'ctf_cs_Ashbury' + #10;

var
  Worst, Why, Others, Target, S: AnsiString;
  T0, k, i: LongInt;
  Ok: Boolean;
  Picks: TStringList;
begin
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'mapvote_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  MapsDir := Root + PathDelim + 'maps';
  ForceDirectories(MapsDir);
  ForceDirectories(MapsDir + PathDelim + 'dir.pms');
  MakeFile(MapsDir + PathDelim + 'ctf_Ash.pms', 'map');
  MakeFile(MapsDir + PathDelim + 'ctf_Run.PMS', 'map');
  MakeFile(MapsDir + PathDelim + 'inf_Moon.Pms', 'map');
  MakeFile(MapsDir + PathDelim + 'ctf_cs_Ashbury.pms', 'map');
  MakeFile(MapsDir + PathDelim + 'Arena.pms', 'map');
  MakeFile(MapsDir + PathDelim + 'Arena2.pms', 'map');
  MakeFile(MapsDir + PathDelim + 'dm_Other.pms', 'map');
  MakeFile(MapsDir + PathDelim + 'readme.txt', 'no map');
  MakeFile(MapsDir + PathDelim + 'x.pms.bak', 'no map');
  MakeFile(MapsDir + PathDelim + 'noext', 'no map');
  MakeFile(MapsDir + PathDelim + '.pms', 'no name');
  SetCurrentDir(Root);
  Acts := TStringList.Create;
  AllActs := TStringList.Create;
  Picks := TStringList.Create;
  Picks.Sorted := True;
  Picks.Duplicates := dupIgnore;

  TestUnits;

  { the votes here follow each other on purpose: no gap between them (test_fix_ws4 has the gap) }
  MakeFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini', '[MapVote]' + LineEnding + 'MapsFolder = ' +
    MapsDir + LineEnding + 'GapSeconds = 0');
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  Check('engine ready and writable', WaitReady and not Engine.IsReadOnly);
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('/votemap belongs to the map vote while it is on', Engine.MapVoteSlash = 1);
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.Cfg.MapVoteCountSpectators;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('CountSpectators is on by default', Ok);
  { the votes below run with CountSpectators = 0 up to the part that switches it on }
  SetCfg(0, 0);

  { five players on the teams (Alice is an admin), a spectator and a bot; the script starts in the
    middle of ctf_Ash and sends the maps list }
  T0 := 60000;
  CurTick := T0;
  MapAfter('ctf_Ash', GS_CTF);
  Join(1, 'Alice', 'S3001', TEAM_ALPHA, 1, 1);
  Join(2, 'Bob', 'S3002', TEAM_BRAVO, 1, 0);
  Join(3, 'Carl', 'S3003', TEAM_ALPHA, 1, 0);
  Join(4, 'Dora', 'S3004', TEAM_BRAVO, 1, 0);
  Join(5, 'Emil', 'S3005', TEAM_ALPHA, 1, 0);
  Join(6, 'Spec', 'S3006', TEAM_SPEC, 1, 0);
  Join(7, 'Bot Boogie', '', TEAM_BRAVO, 0, 0);
  MapList(LIST5, 0, MAPLIST_START);
  CurTick := T0 + 60;
  TickEv(599);
  Step;
  { the folder is read on a thread of its own }
  k := 0;
  repeat
    EnterCriticalSection(Engine.StateLock);
    try
      Ok := Engine.MV.FilesKnown;
    finally
      LeaveCriticalSection(Engine.StateLock);
    end;
    if not Ok then
    begin
      Sleep(20);
      Inc(k);
    end;
  until Ok or (k > 500);
  { the timers write the first scan to the console }
  Sleep(200);
  Drain;
  Check('the settings of the map vote go to main.pas: on, percent 60 to put back', Count(AllActs, ACT_MAPVOTE, -1, '') >= 1);
  k := IndexOfAct(AllActs, ACT_MAPVOTE, '');
  Check('ACT_MAPVOTE carries MV_ENABLED and RestoreVotePercent', (k >= 0) and (P1Of(AllActs[k]) = MV_ENABLED) and
    (P2Of(AllActs[k]) = 60));
  Check('the script started while people play: the console hears it',
    Count(AllActs, ACT_WRITELN, -1, 'ZitroStats ' + ZS_VERSION_STR + ': script compiled and running, loaded ') = 1);
  Check('... and the admin in the game, the others not', (Count(AllActs, ACT_CONSOLE, 1, 'script compiled and running') = 1) and
    (Count(AllActs, ACT_CONSOLE, 2, 'script compiled and running') = 0));
  Check('the first read of the maps folder goes to the console, without the path',
    Count(AllActs, ACT_WRITELN, -1, '[ZitroStats] map vote: 7 maps in the maps folder, 2 not ending in ".pms" (/zs_maps)') = 1);

  { ---- the search of the engine: the list first, then the folder ---- }
  EnterCriticalSection(Engine.StateLock);
  try
    Check('find: "run" is ctf_Run of the list', Engine.MapVoteFind('run', Target, Why, Others) and (Target = 'ctf_Run') and
      (Others = ''));
    Check('find: "ash" is ctf_Ash, and ctf_cs_Ashbury is named', Engine.MapVoteFind('ash', Target, Why, Others) and
      (Target = 'ctf_Ash') and (Others = 'Also matching: ctf_cs_Ashbury.'));
    Check('find: "ctf" names the others of the same kind', Engine.MapVoteFind('ctf', Target, Why, Others) and
      (Target = 'ctf_Ash') and (Others = 'Also matching: ctf_Run, ctf_Missing, ctf_cs_Ashbury.'));
    Check('find: "moon" is inf_Moon of the folder (not in the list)', Engine.MapVoteFind('moon', Target, Why, Others) and
      (Target = 'inf_Moon'));
    Check('find: "arena" is the entry of the list as the list writes it', Engine.MapVoteFind('arena', Target, Why, Others) and
      (Target = 'arena'));
    Check('find: "ARENA2" is Arena2 of the folder', Engine.MapVoteFind('ARENA2', Target, Why, Others) and (Target = 'Arena2'));
    Check('find: "ctf ash" with a space for the "_"', Engine.MapVoteFind('ctf ash', Target, Why, Others) and
      (Target = 'ctf_Ash'));
    Check('find: "ctf_run.pms" without the extension', Engine.MapVoteFind('ctf_run.pms', Target, Why, Others) and
      (Target = 'ctf_Run'));
    Check('find: nothing for "xyz", and where to look', not Engine.MapVoteFind('xyz', Target, Why, Others) and
      (Why = 'No map matches "xyz" - see !maps or !allmaps.'));
    Engine.Cfg.MapVoteAllowAnyMap := False;
    Check('find: a map of the folder alone with AllowAnyMap = 0 says why', not Engine.MapVoteFind('moon', Target, Why, Others)
      and (Why = 'inf_Moon is not in the maps list (only those maps can be voted).'));
    Engine.Cfg.MapVoteAllowAnyMap := True;
    Check('the next map is the entry after the current one', Engine.MapVoteNextMap = 'ctf_Run');
    Check('no map before this one yet (the statistics know none)', Engine.MapVoteLastMap = '');
    { !randommap with FilterByGameStyle: ctf_ maps only, never the one played }
    Engine.Cfg.MapVoteFilterByStyle := True;
    for k := 1 to 60 do
      Picks.Add(Engine.MapVoteRandomMap(Why));
    Engine.Cfg.MapVoteFilterByStyle := False;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Ok := True;
  for k := 0 to Picks.Count - 1 do
    if (Copy(Picks[k], 1, 4) <> 'ctf_') or (Picks[k] = 'ctf_Ash') then
      Ok := False;
  S := Picks.CommaText;
  Check('random map of the mode played, never the one played: ' + S, Ok and (Pos('ctf_Run', S) > 0) and
    (Pos('ctf_cs_Ashbury', S) > 0));

  { ---- no vote yet ---- }
  Acts.Clear;
  CurTick := T0 + 120;
  Chat(2, '!v');
  Step;
  Check('!v without a vote: how to start one, once, to that player only',
    Said(2, 'No map vote is running. Start one with !nextmap, !lastmap, !randommap or !map <part>.') and
    (LinesTo(2) = 1) and (Broadcasts = 0));

  { ---- a vote that passes: Alice asks, Bob votes, Carl presses F12 ---- }
  Acts.Clear;
  CurTick := T0 + 180;
  Chat(1, '!map run');
  Step;
  Check('!map run starts the vote for ctf_Run: Soldat shows it to the clients',
    (Count(Acts, ACT_VOTE_START, -1, 'ctf_Run') = 1) and VoteActive);
  Check('everybody hears who wants which map, how to vote, the time and the percent, the players on the teams only',
    Told('Alice wants ctf_Run: !v or F12 to vote, 20 s, 60% needed (1/5).') and (Broadcasts = 1) and (LinesTo(1) = 0));
  Check('the vote counts for the map it started on', MapStat('ctf_Ash', 0) = 1);

  Acts.Clear;
  CurTick := T0 + 240;
  Chat(2, '!v');
  Step;
  Check('!v: one line to everybody with the count', Told('Bob voted for ctf_Run (2/5, 60% needed).') and
    (Broadcasts = 1) and (LinesTo(2) = 0));
  Acts.Clear;
  Chat(2, '!vote');
  Step;
  Check('a second vote: the player hears it once, nobody else', Said(2, 'You voted for ctf_Run already (2/5, 60% needed, 19 s left).')
    and (LinesTo(2) = 1) and (Broadcasts = 0));
  Acts.Clear;
  Chat(6, '!v');
  Step;
  Check('CountSpectators = 0: a spectator who votes joins the voters of this vote, a voter and a yes',
    Told('Spec voted for ctf_Run (3/6, 60% needed).') and (Broadcasts = 1) and (LinesTo(6) = 0) and VoteActive);
  Acts.Clear;
  Chat(6, '!v');
  Step;
  Check('... and counts as one of them when voting again',
    Said(6, 'You voted for ctf_Run already (3/6, 60% needed, 19 s left).') and (Broadcasts = 0));
  Acts.Clear;
  Chat(4, '!map arena2');
  Step;
  Check('another map while a vote runs: which one runs and how to vote for it',
    Said(4, 'A vote for ctf_Run is running (19 s left): !v or F12 to vote for it.') and (Count(Acts, ACT_VOTE_START, -1, '') = 0));

  Acts.Clear;
  CurTick := T0 + 300;
  SoldatVote(3, 3, 'ctf_Run');
  Step;
  Check('F12 (OnVoteMap) is a vote', Told('Carl voted for ctf_Run (4/6, 60% needed).'));
  Check('4 of 6 is 60% or more: the vote passes', Told('ctf_Run won the vote (4/6).') and not VoteActive);
  k := IndexOfAct(Acts, ACT_MAP_CHANGE, 'ctf_Run');
  i := IndexOfAct(Acts, ACT_VOTE_END, '');
  Check('the map changes (Map.NextMap: it is the next map of the list), then the vote percent goes back',
    (k >= 0) and (P1Of(Acts[k]) = 1) and (i > k) and (P1Of(Acts[i]) = 60) and (Count(Acts, ACT_VOTE_END, -1, '') = 1));
  Check('statistics: won on ctf_Ash, voted in on ctf_Run', (MapStat('ctf_Ash', 1) = 1) and (MapStat('ctf_Run', 2) = 1) and
    (MapStat('ctf_Ash', 0) = 1));

  Acts.Clear;
  CurTick := T0 + 400;
  Cmd(5, 'votemap ctf_Run', SRC_COMMAND);
  Chat(5, '!map arena2');
  Step;
  Check('a late F12 (/votemap of the map of the vote that just ended) starts nothing and says so',
    Said(5, 'The vote for ctf_Run is over (passed).') and (Count(Acts, ACT_VOTE_START, -1, '') = 0));
  Check('while the map changes no vote starts', Said(5, 'The map is changing, wait a moment.'));

  { ---- the map changes; the first seconds of a map, the starter's wait ---- }
  Acts.Clear;
  CurTick := T0 + 420;
  MapBefore('ctf_Run');
  CurTick := T0 + 720;
  MapAfter('ctf_Run', GS_CTF);
  MapList(LIST5, 1, MAPLIST_MAPCHANGE);
  TickEv(599);
  CurTick := T0 + 780;
  Chat(1, '!lastmap');
  Step;
  Check('no vote in the first seconds of a map', Said(1, 'No map vote in the first 20 s of a map (19 s left).'));
  Acts.Clear;
  CurTick := T0 + 720 + 1201;
  Chat(1, '!lastmap');
  Step;
  Check('the starter waits StarterCooldownSeconds after the start of the vote',
    Said(1, 'Wait 16 s before you start another map vote.'));
  Check('after the change the list moves on: the next map is the one after ctf_Run', Engine.MapVoteNextMap = 'ctf_Missing');

  { ---- a vote that fails: Bob asks for the last map, nobody else votes ---- }
  Acts.Clear;
  Chat(2, '!votelast');
  Step;
  Check('!votelast (!lastmap) asks for the map before this one', (Count(Acts, ACT_VOTE_START, -1, 'ctf_Ash') = 1) and
    Told('Bob wants ctf_Ash: !v or F12 to vote, 20 s, 60% needed (1/5).'));
  Acts.Clear;
  CurTick := T0 + 1921 + 1140;
  TickEv(500);
  Step;
  Check('19 seconds into the vote it still runs', VoteActive and (Count(Acts, ACT_VOTE_END, -1, '') = 0));
  Acts.Clear;
  CurTick := T0 + 1921 + 1200;
  TickEv(499);
  Step;
  Check('after VoteSeconds it fails, once, and the percent goes back',
    Told('The vote for ctf_Ash failed (1/5, 60% needed).') and (Count(Acts, ACT_VOTE_END, -1, '') = 1) and not VoteActive and
    (Count(Acts, ACT_MAP_CHANGE, -1, '') = 0));
  Check('statistics: a start on ctf_Run and nothing won', (MapStat('ctf_Run', 0) = 1) and (MapStat('ctf_Run', 1) = 0) and
    (MapStat('ctf_Ash', 2) = 0));

  { ---- CountSpectators = 1: the spectator counts and votes; a map change that does not come ---- }
  SetCfg(0, 1);
  Acts.Clear;
  CurTick := T0 + 3200;
  Chat(3, '!nextmap');
  Step;
  Check('!nextmap asks for the next map of the list; with CountSpectators the spectator counts',
    (Count(Acts, ACT_VOTE_START, -1, 'ctf_Missing') = 1) and Told('Carl wants ctf_Missing: !v or F12 to vote, 20 s, 60% needed (1/6).'));
  Acts.Clear;
  Chat(4, '!v');
  Chat(6, '!v');
  Step;
  Check('the spectator votes', Told('Spec voted for ctf_Missing (3/6, 60% needed).') and VoteActive);
  Acts.Clear;
  Chat(5, '!v');
  Step;
  Check('4 of 6 is 60% or more: passed', Told('ctf_Missing won the vote (4/6).') and
    (Count(Acts, ACT_MAP_CHANGE, -1, 'ctf_Missing') = 1));
  SetCfg(0, 0);
  Acts.Clear;
  CurTick := T0 + 3200 + 660;
  TickEv(400);
  Step;
  Check('a map change that does not come: everybody hears it, the admins what to look at',
    Told('The server could not change the map to ctf_Missing.') and
    Said(1, '[ZitroStats] map vote: the map did not change to ctf_Missing.') and
    Written('On Linux the server looks for exactly "ctf_Missing.pms".'));

  { ---- the time left, a kick vote, the players ---- }
  Acts.Clear;
  CurTick := T0 + 4000;
  TickEv(20);
  Chat(1, '!map arena2');
  Step;
  Check('no vote with less than MinTimeLeftSeconds left', Said(1, 'Only 20 s of the map are left: a map vote needs 26 s.'));
  Acts.Clear;
  CurTick := T0 + 4060;
  TickEv(500);
  SoldatVote(4, 2, 'Bob');
  Chat(1, '!map arena2');
  Step;
  Check('no map vote while a kick vote of Soldat may run', Said(1, 'A kick vote is running: try again in 21 s.'));
  Acts.Clear;
  CurTick := T0 + 4060 + 1261;
  SetCfg(1, 10);
  Chat(1, '!map arena2');
  Step;
  Check('MinPlayers: the players on the teams', Said(1, 'A map vote needs 10 players on the teams (5 now).'));
  Acts.Clear;
  Chat(6, '!map arena2');
  Step;
  Check('MinPlayers: a spectator who asks for a vote is one of its voters (CountSpectators = 0)',
    Said(6, 'A map vote needs 10 players (6 now: the players on the teams and you).'));
  SetCfg(1, 1);
  Acts.Clear;
  Chat(6, '!map arena2');
  Step;
  Check('CountSpectators = 0: a spectator starts a vote as its voter and a yes, the other spectators do not count',
    (Count(Acts, ACT_VOTE_START, -1, 'Arena2') = 1) and
    Told('Spec wants Arena2: !v or F12 to vote, 20 s, 60% needed (1/6).'));
  Acts.Clear;
  Cmd(0, '/zs_mapvote cancel', SRC_CONSOLE);
  Step;
  Check('the vote of the spectator is cancelled', Told('An admin cancelled the vote for Arena2.') and not VoteActive);

  { ---- AllowAnyMap: a map of the folder; the admin's view and cancel ---- }
  SetCfg(2, 0);
  Acts.Clear;
  Chat(1, '!map arena2');
  Step;
  Check('AllowAnyMap = 0: a map that is only in the folder is refused',
    Said(1, 'Arena2 is not in the maps list (only those maps can be voted).'));
  SetCfg(2, 1);
  Acts.Clear;
  Chat(1, '!map arena2');
  Step;
  Check('AllowAnyMap = 1: the map of the folder is voted', Count(Acts, ACT_VOTE_START, -1, 'Arena2') = 1);
  Acts.Clear;
  Cmd(0, '/zs_mapvote', SRC_CONSOLE);
  Step;
  Check('/zs_mapvote: the settings and the vote that runs',
    Written('[Map vote] on: passes with 60% of the players on the teams and voting spectators, fails after 20 s') and
    Written('[Map vote] running: Arena2, 20 s left, 1/5') and
    Written('[Map vote] asked by Alice just now - /zs_mapvote cancel ends it.') and
    Written('[Map vote] maps list: 5 maps, next ctf_Missing') and Written('[Map vote] maps folder: 7 maps (/zs_maps)'));
  Acts.Clear;
  Cmd(0, '/zs_mapvote cancel', SRC_CONSOLE);
  Step;
  Check('/zs_mapvote cancel: everybody hears it, the console once, the percent goes back',
    Told('An admin cancelled the vote for Arena2.') and Written('[Map vote] The vote was cancelled.') and
    (Count(Acts, ACT_VOTE_END, -1, '') = 1) and not VoteActive);
  Acts.Clear;
  Chat(2, '!zs_mapvote');
  Step;
  Check('/zs_mapvote is for admins', Said(2, 'This command is for admins.'));

  { ---- the vote menu (kind 1) asks for a map of the list; a map change ends a vote ---- }
  Acts.Clear;
  CurTick := T0 + 5500;
  SoldatVote(4, 1, 'CTF_CS_ASHBURY');
  Step;
  Check('the vote menu: a vote for that map, as the list writes it', Count(Acts, ACT_VOTE_START, -1, 'ctf_cs_Ashbury') = 1);
  Acts.Clear;
  CurTick := T0 + 5600;
  MapBefore('ctf_Ash');
  Step;
  Check('a map change ends the vote that runs', Told('The map is changing: the vote for ctf_cs_Ashbury is over.') and
    (Count(Acts, ACT_VOTE_END, -1, '') = 1) and not VoteActive);
  CurTick := T0 + 5900;
  MapAfter('ctf_Ash', GS_CTF);
  MapList(LIST5, 0, MAPLIST_MAPCHANGE);
  TickEv(599);
  Step;

  { ---- nobody left to vote ---- }
  Acts.Clear;
  CurTick := T0 + 5900 + 1300;
  Chat(5, '!map moon');
  Step;
  Check('a map of the folder by a part of its name', Count(Acts, ACT_VOTE_START, -1, 'inf_Moon') = 1);
  Acts.Clear;
  for k := 1 to 5 do
    Leave(k);
  CurTick := CurTick + 60;
  TickEv(500);
  Step;
  Check('everybody on the teams left: the vote ends', Told('The vote for inf_Moon ended: nobody is left to vote.') and
    not VoteActive);

  { ---- one player: the vote passes at once, the clients never see it ---- }
  Acts.Clear;
  Join(8, 'Finn', 'S3008', TEAM_ALPHA, 1, 0);
  CurTick := CurTick + 60;
  TickEv(500);
  Chat(8, '!map arena2');
  Step;
  Check('alone on the teams: passed at once, no vote on the screens, nothing to put back',
    Told('Finn wants Arena2: the vote passed at once (1/1).') and (Count(Acts, ACT_VOTE_START, -1, '') = 0) and
    (Count(Acts, ACT_VOTE_END, -1, '') = 0) and (Count(Acts, ACT_MAP_CHANGE, -1, 'Arena2') = 1));
  k := IndexOfAct(Acts, ACT_MAP_CHANGE, 'Arena2');
  Check('a map that is not the next one: Map.SetMap', (k >= 0) and (P1Of(Acts[k]) = 0));
  CurTick := CurTick + 60;
  MapBefore('Arena2');
  CurTick := CurTick + 300;
  MapAfter('Arena2', GS_DM);
  MapList(LIST5, 0, MAPLIST_MAPCHANGE);
  Step;

  { ---- a voter who leaves takes the vote along; the new player of the slot has not voted ---- }
  Join(1, 'Alice', 'S3001', TEAM_ALPHA, 1, 1);
  Join(2, 'Bob', 'S3002', TEAM_BRAVO, 1, 0);
  Join(3, 'Carl', 'S3003', TEAM_ALPHA, 1, 0);
  Join(4, 'Dora', 'S3004', TEAM_BRAVO, 1, 0);
  CurTick := CurTick + 1300;
  TickEv(500);
  Step;
  Acts.Clear;
  Chat(3, '!map ctf_run');
  Chat(2, '!v');
  Step;
  Check('a vote with five players', Told('Bob voted for ctf_Run (2/5, 60% needed).'));
  Acts.Clear;
  Leave(2);
  CurTick := CurTick + 60;
  TickEv(499);
  Join(2, 'Gina', 'S3009', TEAM_BRAVO, 1, 0);
  Chat(1, '!v');
  Step;
  Check('the vote of the player who left is gone, the new player of the slot has not voted',
    Told('Alice voted for ctf_Run (2/5, 60% needed).') and VoteActive);
  Acts.Clear;
  Cmd(2, 'votemap ctf_Run', SRC_COMMAND);
  Step;
  Check('/votemap <map of the vote> (F12 through the command) is a vote; 3 of 5 passes',
    Told('Gina voted for ctf_Run (3/5, 60% needed).') and Told('ctf_Run won the vote (3/5).'));
  CurTick := CurTick + 60;
  MapBefore('ctf_Run');
  CurTick := CurTick + 300;
  MapAfter('ctf_Run', GS_CTF);
  MapList(LIST5, 1, MAPLIST_MAPCHANGE);
  CurTick := CurTick + 1300;
  TickEv(500);
  Step;

  { ---- the views ---- }
  Acts.Clear;
  Chat(4, '!map');
  Chat(4, '!maps');
  Chat(4, '!allmaps');
  Step;
  Check('!map: the map now, the time left, the next and the last map',
    Said(4, 'Now: ctf_Run (8:20 left)  Next: ctf_Missing  Last: Arena2'));
  Check('!maps: the list with the map being played in brackets, the next and the last map',
    Said(4, 'Maps list: 5 maps [Page 1/1]') and
    Said(4, 'ctf_Ash             [ctf_Run]           ctf_Missing         arena               ctf_cs_Ashbury') and
    SaidLine(4, '[ ] = the map being played  Next: ctf_Missing  Last: Arena2  !map <part> starts a vote'));
  Check('!allmaps: every map of the folder, * = not in the list',
    Said(4, 'All maps of the server: 7 [Page 1/1]') and
    Said(4, 'Arena               Arena2*             ctf_Ash             ctf_cs_Ashbury      [ctf_Run]') and
    Said(4, 'dm_Other*           inf_Moon*') and
    Said(4, '* = not in the maps list, can be voted too  [ ] = the map being played'));

  { !maps and !allmaps with a map: the page that has it, the map marked > < }
  Acts.Clear;
  Chat(4, '!allmaps ash');
  Step;
  Check('!allmaps <map>: the whole folder at the page of the map, the map marked',
    Said(4, 'All maps of the server: 7 [Page 1/1]') and
    SaidLine(4, 'Arena               Arena2*             >ctf_Ash<           ctf_cs_Ashbury      [ctf_Run]') and
    SaidLine(4, '* = not in the maps list, can be voted too  [ ] = the map being played  > < = the map you asked for'));
  Acts.Clear;
  Chat(4, '!maps ash');
  Step;
  Check('!maps <map>: the page of the map, the map marked; a legend too long for one line takes two',
    SaidLine(4, '>ctf_Ash<           [ctf_Run]           ctf_Missing         arena               ctf_cs_Ashbury') and
    SaidLine(4, '[ ] = the map being played  > < = the map you asked for  Next: ctf_Missing  Last: Arena2') and
    SaidLine(4, '!map <part> starts a vote'));
  Acts.Clear;
  Chat(4, '!maps ctf cs');
  Chat(4, '!maps zzz.pms');
  Chat(4, '!allmaps zzz');
  Step;
  Check('!maps: a space for the "_" of a name; a map the list does not have; !allmaps the same',
    SaidLine(4, 'ctf_Ash             [ctf_Run]           ctf_Missing         arena               >ctf_cs_Ashbury<') and
    SaidLine(4, 'No map of the maps list matches "zzz" - try !searchmap.') and
    SaidLine(4, 'No map of the server matches "zzz".'));
  { a maps list of 70: the page of the map asked for, then the pages of the whole list }
  S := 'dm_Map01';
  for k := 2 to 70 do
    S := S + #10 + Format('dm_Map%.2d', [k]);
  MapList(S, 0, MAPLIST_CHANGED);
  Acts.Clear;
  Chat(4, '!maps map65');
  Step;
  Check('!maps <map> in a list of 70: page 2 of 2, the map marked', Said(4, 'Maps list: 70 maps [Page 2/2]') and
    Said(4, '>dm_Map65<') and Said(4, 'Page 2/2 - /zs_prev goes back'));
  Acts.Clear;
  Cmd(4, '/zs_first', SRC_COMMAND);
  Step;
  Check('... then /zs_first: page 1 of the whole list, nothing marked', Said(4, 'Maps list: 70 maps [Page 1/2]') and
    (Count(Acts, ACT_CONSOLE, 4, '> < =') = 0) and (Count(Acts, ACT_CONSOLE, 4, '>dm_Map') = 0));
  MapList(LIST5, 1, MAPLIST_CHANGED);
  Step;

  { !searchmap: the maps list and the folder, in the order of the vote's search }
  Acts.Clear;
  Chat(4, '!searchmap ash');
  Step;
  Check('!searchmap ash: the maps of the list with the text, the closest first',
    Said(4, 'Map search "ash": 2 maps [Page 1/1]') and SaidLine(4, 'ctf_Ash             ctf_cs_Ashbury') and
    (LinesTo(4) = 2));
  Acts.Clear;
  Chat(4, '!searchmap ctf_');
  Step;
  Check('!searchmap ctf_: every ctf_ map, the shorter first, then the order of the list; the map being played marked',
    Said(4, 'Map search "ctf_": 4 maps [Page 1/1]') and
    SaidLine(4, 'ctf_Ash             [ctf_Run]           ctf_Missing         ctf_cs_Ashbury') and
    SaidLine(4, '[ ] = the map being played'));
  Acts.Clear;
  Chat(4, '!searchmap ar');
  Step;
  Check('!searchmap ar: the maps list first, then a map only the folder has, marked *',
    Said(4, 'Map search "ar": 2 maps [Page 1/1]') and SaidLine(4, 'arena               Arena2*') and
    SaidLine(4, '* = not in the maps list, can be voted too'));
  Acts.Clear;
  Chat(4, '!searchmap o');
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    Ok := Engine.MapVoteFind('o', Target, Why, Others) and (Target = 'dm_Other');
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
  Check('!searchmap o: only the folder has it; the beginning of a word before a part, as the vote picks',
    Said(4, 'Map search "o": 2 maps [Page 1/1]') and SaidLine(4, 'dm_Other*           inf_Moon*') and Ok);
  Acts.Clear;
  Chat(4, '!searchmap ctf cs');
  Chat(4, '!searchmap ctf 2');
  Chat(4, '!searchmap');
  Chat(4, '!searchmap zzz');
  Step;
  Check('!searchmap: a space for the "_", a number at the end is the page, a usage line, nothing found',
    Said(4, 'Map search "ctf cs": 1 map [Page 1/1]') and Said(4, 'Map search "ctf": 4 maps [Page 1/1]') and
    SaidLine(4, 'Usage: !searchmap <part of a map name> [page]') and SaidLine(4, 'No map of the server matches "zzz".'));
  Acts.Clear;
  Chat(4, '!searchmap arena');
  Cmd(4, '/zs_next', SRC_COMMAND);
  Step;
  Check('/zs_next after !searchmap: the search again (one page)', Count(Acts, ACT_CONSOLE, 4, 'Map search "arena": 2 maps') = 2);
  SetCfg(3, MVC_ALL and not MVC_SEARCHMAP);
  Acts.Clear;
  Chat(4, '!searchmap ash');
  Step;
  Check('SearchMapCommand = 0: !searchmap gets no answer', LinesTo(4) = 0);
  SetCfg(3, MVC_ALL);
  Acts.Clear;
  Cmd(0, '/zs_maps', SRC_CONSOLE);
  Step;
  Check('/zs_maps: the folder (from the server folder, no path of the disk) and its maps', Written('[Maps] folder: maps') and
    not Written('[Maps] folder: ' + MapsDir) and Written('[Maps] 7 maps, read at '));
  Check('/zs_maps: the files Linux may not load', Written('[Maps] 2 file(s) not ending in ".pms"') and
    Written('  ctf_Run.PMS, inf_Moon.Pms'));
  Check('/zs_maps: the maps of the list without a file, and in another case than their file',
    Written('[Maps] 1 map(s) of the list have no file in the folder:') and Written('  ctf_Missing') and
    Written('[Maps] 1 map(s) of the list differ from their file in case') and Written('  arena (file Arena.pms)'));
  MakeFile(MapsDir + PathDelim + 'ctf_New.pms', 'map');
  Acts.Clear;
  Cmd(0, '/zs_maps rescan', SRC_CONSOLE);
  Step;
  Check('/zs_maps rescan: the folder is read again', Written('[Maps] Reading the maps folder; you hear when it is done.'));
  k := 0;
  repeat
    Sleep(20);
    Drain;
    Inc(k);
  until Written('[Maps] 8 maps in the folder (1 new, 0 gone), read in ') or (k > 300);
  Check('... and the console hears what changed', Written('[Maps] 8 maps in the folder (1 new, 0 gone), read in '));
  { a folder of two pages: !allmaps <map> opens the second one (the folder is sorted as CompareText
    sorts, "_" after the letters: Arena, Arena2, a_Fill01 ...) }
  for k := 1 to 60 do
    MakeFile(MapsDir + PathDelim + Format('a_Fill%.2d.pms', [k]), 'map');
  Acts.Clear;
  Cmd(0, '/zs_maps rescan', SRC_CONSOLE);
  Step;
  k := 0;
  repeat
    Sleep(20);
    Drain;
    Inc(k);
  until Written('[Maps] 68 maps in the folder (60 new, 0 gone), read in ') or (k > 300);
  Acts.Clear;
  Chat(4, '!allmaps moon');
  Step;
  Check('!allmaps <map> in a folder of 68: page 2 of 2, the map marked',
    Said(4, 'All maps of the server: 68 [Page 2/2]') and
    SaidLine(4, 'a_Fill59*           a_Fill60*           ctf_Ash             ctf_cs_Ashbury      ctf_New*') and
    SaidLine(4, '[ctf_Run]           dm_Other*           >inf_Moon*<'));

  { a long name: !map says it on two lines rather than on one wider than the tables }
  S := 'ctf_A_Very_Long_Name_Of_A_Map_That_Somebody_Made_Up_For_This_Test';
  Acts.Clear;
  MapList('ctf_Run' + #10 + S + #10 + LIST5, 0, MAPLIST_CHANGED);
  Chat(4, '!map');
  Step;
  Check('!map with a long name: two lines', SaidLine(4, 'Now: ctf_Run (8:20 left)') and
    SaidLine(4, 'Next: ' + S + '  Last: Arena2'));
  MapList(LIST5, 1, MAPLIST_CHANGED);
  Step;

  { ---- the switches: !v off (F12 still works), then the whole map vote off ---- }
  SetCfg(3, MVC_ALL and not MVC_VOTE);
  Acts.Clear;
  Chat(4, '!v');
  Step;
  Check('!v switched off: no answer at all (another script may have one)', (LinesTo(4) = 0) and (Broadcasts = 0));
  Acts.Clear;
  Chat(4, '!zitro');
  Step;
  Check('!zitro: the map vote section without !v, F12 in the legend', Said(4, '-- Map vote --') and
    SaidLine(4, '!nextmap            !lastmap            !randommap          !map [map]          !votemap map*') and
    SaidLine(4, '/votemap map*       !maps [pg|map]      !allmaps [pg|map]   !searchmap t* [pg]') and
    Said(4, 'F12 = yes to the running map vote  !map alone = the current, next and last map'));
  Check('!zitro: the lists that open at the page of a map',
    SaidLine(4, '!top p / !topmaps, !maps, !allmaps map = the page around that player or map  !top m = !topby m'));
  SetCfg(3, MVC_ALL and not MVC_MAPS);
  Acts.Clear;
  Chat(4, '!zitro');
  Step;
  Check('!zitro with MapsCommand = 0: !maps left out of the grid and of the legend',
    SaidLine(4, '!votemap map*       /votemap map*       !allmaps [pg|map]   !searchmap t* [pg]') and
    SaidLine(4, '!top p / !topmaps, !allmaps map = the page around that player or map  !top m = !topby m'));
  SetCfg(3, MVC_ALL);
  Acts.Clear;
  Chat(4, '!zitro');
  Step;
  Check('!zitro with every map command on: the rows of the map vote in Message.txt',
    SaidLine(4, '!v                  !nextmap            !lastmap            !randommap          !map [map]') and
    SaidLine(4, '!votemap map*       /votemap map*       !maps [pg|map]      !allmaps [pg|map]   !searchmap t* [pg]'));
  MakeFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini', '[MapVote]' + LineEnding + 'Enabled = 0' + LineEnding +
    'MapsFolder = ' + MapsDir);
  Acts.Clear;
  Cmd(0, '/zs_reload', SRC_CONSOLE);
  Step;
  k := IndexOfAct(Acts, ACT_MAPVOTE, '');
  Check('Enabled = 0: main.pas hears it (Soldat''s own vote runs again), /votemap is the server''s',
    (k >= 0) and (P1Of(Acts[k]) = 0) and (Engine.MapVoteSlash = 0));
  Acts.Clear;
  CurTick := CurTick + 60;
  i := MapStat('ctf_Run', 0);
  Chat(3, '!nextmap');
  SoldatVote(3, 1, 'ctf_Missing');
  Step;
  Check('Enabled = 0: the commands are left to other scripts, Soldat''s vote only counted',
    (LinesTo(3) = 0) and (Count(Acts, ACT_VOTE_START, -1, '') = 0) and (MapStat('ctf_Run', 0) = i + 1));
  MakeFile(Root + PathDelim + 'script' + PathDelim + 'settings.ini', '[MapVote]' + LineEnding + 'MapsFolder = ' + MapsDir +
    LineEnding + 'GapSeconds = 0');
  Cmd(0, '/zs_reload', SRC_CONSOLE);
  Step;
  EnterCriticalSection(Engine.StateLock);
  try
    Engine.Cfg.CommandsPerSecond := 100000;
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;

  { ---- the script is loaded again while the library keeps running ---- }
  Acts.Clear;
  CurTick := CurTick + 60;
  Chat(4, '!map ash');
  Step;
  Check('a vote before the reload', Count(Acts, ACT_VOTE_START, -1, 'ctf_Ash') = 1);
  Acts.Clear;
  Engine.NoteScriptReloaded;
  MapAfter('ctf_Run', GS_CTF);
  MapList(LIST5, 1, MAPLIST_START);
  Step;
  Check('the vote of the script before is over', Told('The script was loaded again: the vote for ctf_Ash is over.') and
    (Count(Acts, ACT_VOTE_END, -1, '') = 1));
  Check('the admins hear that the script runs again with the data the library kept',
    Written('ZitroStats ' + ZS_VERSION_STR + ': script compiled and running (library kept its data: ') and
    Said(1, 'script compiled and running (library kept its data: '));
  Acts.Clear;
  CurTick := CurTick + 60;
  Chat(8, '!map ash');
  Step;
  Check('after a reload in the middle of a map a vote starts at once', Count(Acts, ACT_VOTE_START, -1, 'ctf_Ash') = 1);
  { nobody online: no notice }
  Acts.Clear;
  for k := 1 to 8 do
    Leave(k);
  MapList(LIST5, 1, MAPLIST_START);
  Step;
  Check('a start with nobody online says nothing', Count(Acts, ACT_WRITELN, -1, 'script compiled and running') = 0);

  Check('every line fits LINE_W', AllFit(Worst));
  if Worst <> '' then
    WriteLn('       too wide: ', Worst);
  AllActs.SaveToFile(Root + PathDelim + 'actions.txt');

  Engine.Free;
  Picks.Free;
  Acts.Free;
  AllActs.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
