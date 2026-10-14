program test_dll;

{ Loads the built library like the server does and drives it through its exports. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, dynlibs, zs_types;

type
  TInit = function(ScriptDir: PChar; ApiVersion: LongInt): LongInt; cdecl;
  TProc = procedure; cdecl;
  TIntFunc = function: LongInt; cdecl;
  TJoin = procedure(Slot: LongInt; Name, Steam, Hwid, IP: PChar; Team, Human, Admin, Tick: LongInt); cdecl;
  TMapAfter = procedure(MapName: PChar; GameStyle, ScoreLimit, TimeLimit, Flags, Tick: LongInt); cdecl;
  TCommand = function(Slot: LongInt; Text: PChar; Source, Admin, Tick: LongInt): LongInt; cdecl;
  TTextFunc = function: PChar; cdecl;
  TStatFunc = function(Id, Stat: LongInt): Double; cdecl;
  THeal = procedure(Slot, Kits, Tick: LongInt; Regen, Kit: Single); cdecl;
  TKit = function(Slot, Style, Tick: LongInt): LongInt; cdecl;
  { [Bridges] (API 16) }
  TFrame = function(Tick: LongInt): LongInt; cdecl;
  TBind = function(Slot: LongInt; Obj: Pointer; X, Y: Single): LongInt; cdecl;
  TCheckMem = function(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys: LongInt; X, Y, Health, Vest: Single): LongInt;
    cdecl;
  THit = function(Shooter, Victim, BulletId, Tick: LongInt; Damage: Single): LongInt; cdecl;
  TDeath = function(Killer, Victim, BulletId, Flags, Tick: LongInt): LongInt; cdecl;
  TTeamJoin = function(Slot, Team, OldTeam, Tick: LongInt): LongInt; cdecl;
  TTopCopy = function(Rank: LongInt; Buf: PChar; Size: LongInt): LongInt; cdecl;
  TMapList = procedure(Count, CurrentId, Reason, Tick: LongInt; Names: PChar); cdecl;
  TDamage = procedure(Shooter, Victim, BulletId, Weapon, Flags, Tick: LongInt; Damage, VictimVest, BX, BY, BVX, BVY,
    VX, VY, VictimHealth, VictimVelX, VictimVelY, ShooterVelX, ShooterVelY: Single); cdecl;
  TKill = procedure(Killer, Victim, BulletId, Weapon, Flags, VictimWeapon, Tick: LongInt;
    KX, KY, VX, VY, BX, BY, VictimVest: Single); cdecl;

var
  Failures: Integer = 0;

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

function Sym(Lib: TLibHandle; const Name: AnsiString): Pointer;
begin
  Result := GetProcedureAddress(Lib, Name);
  if Result = nil then
  begin
    WriteLn('[FAIL] missing export ', Name);
    Inc(Failures);
  end;
end;

function FileText(const Path: AnsiString): AnsiString;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function Occurrences(const Sub, S: AnsiString): LongInt;
var
  p: LongInt;
begin
  Result := 0;
  p := Pos(Sub, S);
  while p > 0 do
  begin
    Inc(Result);
    p := Pos(Sub, S, p + Length(Sub));
  end;
end;

procedure WriteNil;
var
  P: PLongInt;
begin
  P := nil;
  P^ := 1;
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

var
  Lib: TLibHandle;
  DllPath, Root, CrashLog: AnsiString;
  Init: TInit;
  Shutdown: TProc;
  IsReady, ActionBegin, ActionNext, ActionSlot, ProfileCount, ClaimToken, ApiVersion: TIntFunc;
  Token: LongInt;
  Join: TJoin;
  MapAfter: TMapAfter;
  Command: TCommand;
  ActionText: TTextFunc;
  PlayerStat: TStatFunc;
  Heal: THeal;
  Kit: TKit;
  TeamJoin: TTeamJoin;
  TopCopy: TTopCopy;
  TopCopy2: TTopCopy;
  MapListEv: TMapList;
  DamageEv: TDamage;
  KillEv: TKill;
  Frame: TFrame;
  Bind: TBind;
  CheckMem: TCheckMem;
  Bridges: TIntFunc;
  Hit: THit;
  Death: TDeath;
  T0: Int64;
  Kind, Lines, Ticks, InTick, MostInTick, n: LongInt;
  Help: Boolean;
  Txt, HealLine, Txt2: AnsiString;
  Buf: array[0..127] of AnsiChar;

{ Polls the output the way main.pas does (ZS_Action_Begin, then ZS_Action_Next until 0), every
  10 ms, until a line for Slot holds Needle or TimeoutMs passed; Line is that line. }
function WaitLine(Slot: LongInt; const Needle: AnsiString; TimeoutMs: LongInt; out Line: AnsiString): Boolean;
var
  Start: Int64;
  K: LongInt;
  S: AnsiString;
begin
  Result := False;
  Line := '';
  Start := GetTickCount64;
  while GetTickCount64 - Start < TimeoutMs do
  begin
    Sleep(10);
    if ActionBegin() = 0 then
      Continue;
    repeat
      K := ActionNext();
      if K <> 0 then
      begin
        S := StrPas(ActionText());
        if (ActionSlot() = Slot) and (Pos(Needle, S) > 0) then
        begin
          Line := S;
          Result := True;
        end;
      end;
    until K = 0;
    if Result then
      Exit;
  end;
end;

begin
  DllPath := ExpandFileName(ParamStr(1));
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'dll_tmp');
  { every run starts from no data, so the numbers below are exact }
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  Lib := LoadLibrary(DllPath);
  Check('library loads', Lib <> NilHandle);
  if Lib = NilHandle then
    Halt(1);
  Init := TInit(Sym(Lib, 'ZS_Init'));
  Shutdown := TProc(Sym(Lib, 'ZS_Shutdown'));
  IsReady := TIntFunc(Sym(Lib, 'ZS_Is_Ready'));
  Join := TJoin(Sym(Lib, 'ZS_Ev_Join'));
  MapAfter := TMapAfter(Sym(Lib, 'ZS_Ev_Map_After'));
  Command := TCommand(Sym(Lib, 'ZS_Command'));
  ActionBegin := TIntFunc(Sym(Lib, 'ZS_Action_Begin'));
  ActionNext := TIntFunc(Sym(Lib, 'ZS_Action_Next'));
  ActionSlot := TIntFunc(Sym(Lib, 'ZS_Action_Slot'));
  ActionText := TTextFunc(Sym(Lib, 'ZS_Action_Text'));
  ProfileCount := TIntFunc(Sym(Lib, 'ZS_API_Get_Profile_Count'));
  PlayerStat := TStatFunc(Sym(Lib, 'ZS_API_Get_Player_Stat'));
  ClaimToken := TIntFunc(Sym(Lib, 'ZS_Claim_Token'));
  ApiVersion := TIntFunc(Sym(Lib, 'ZS_Get_Api_Version'));
  { the healing main.pas collects (regenerating polygons, medical / berserker / predator kits) }
  Heal := THeal(Sym(Lib, 'ZS_Ev_Heal'));
  { every kit a human picks up }
  Kit := TKit(Sym(Lib, 'ZS_Ev_Kit'));
  { the exports main.pas needs for the team balance and the score guard }
  TeamJoin := TTeamJoin(Sym(Lib, 'ZS_Team_Join'));
  Sym(Lib, 'ZS_Ev_Move_Result');
  Sym(Lib, 'ZS_Ev_Integrity');
  Sym(Lib, 'ZS_Ev_Ray');
  { for AntiFake, on a thread of its own }
  TopCopy := TTopCopy(Sym(Lib, 'ZS_API_Top_Player_Copy'));
  { the same with the computer of the account (API 17) }
  TopCopy2 := TTopCopy(Sym(Lib, 'ZS_API_Top_Player_Copy2'));
  { the maps list of the map vote }
  MapListEv := TMapList(Sym(Lib, 'ZS_Ev_Map_List'));
  { a hit with the velocities of both players (API 15), and a kill }
  DamageEv := TDamage(Sym(Lib, 'ZS_Ev_Damage'));
  KillEv := TKill(Sym(Lib, 'ZS_Ev_Kill'));
  Frame := TFrame(Sym(Lib, 'ZS_Frame'));
  Bind := TBind(Sym(Lib, 'ZS_Bind'));
  CheckMem := TCheckMem(Sym(Lib, 'ZS_Check'));
  Bridges := TIntFunc(Sym(Lib, 'ZS_Bridges'));
  Hit := THit(Sym(Lib, 'ZS_Ev_Hit'));
  Death := TDeath(Sym(Lib, 'ZS_Ev_Death'));
  if Failures > 0 then
    Halt(Failures);

  SetCurrentDir(Root);
  Check('wrong API version refused', Init(PChar(Root + PathDelim + 'script'), ZS_API_VERSION - 1) = -ZS_API_VERSION);
  Check('init', Init(PChar(Root + PathDelim + 'script'), ZS_API_VERSION) = ZS_API_VERSION);
  { the crash diagnostics start with the first engine - every script start of main.pas makes one
    (its finalization stops the engine) - in the log folder of settings.ini }
  CrashLog := Root + PathDelim + 'logs' + PathDelim + 'zitrostats' + PathDelim + 'crash.log';
  Check('crash.log started by the first init', Pos('ZitroStats ' + ZS_VERSION_STR + ' diagnostics started',
    FileText(CrashLog)) > 0);
  Check('second init reuses the engine', Init(PChar(Root + PathDelim + 'script'), ZS_API_VERSION) = ZS_API_VERSION);
  { the handler watches the whole process: a caught access violation of this program is written, the
    Pascal exceptions it catches are not }
  for n := 1 to 4 do
    try
      raise Exception.Create('caught');
    except
    end;
  try
    WriteNil;
  except
  end;
  Txt := FileText(CrashLog);
  Check('crash.log: a caught access violation of the process is written',
    (Occurrences('code C0000005', Txt) = 1) and (Pos('test_dll.exe+', Txt) > 0));
  Check('crash.log: a caught Pascal exception is no crash', Pos('E0465043', Txt) = 0);
  T0 := GetTickCount64;
  while (IsReady() = 0) and (GetTickCount64 - T0 < 10000) do
    Sleep(10);
  Check('ready', IsReady() = 1);

  MapAfter('ctf_Run', 3, 10, 15, 0, 0);
  Join(1, 'Tester', 'S777001', 'HW-T', '10.0.0.1', 1, 1, 1, 0);
  Join(2, 'Other', 'S777002', 'HW-O', '10.0.0.2', 2, 1, 0, 0);
  Token := ClaimToken();
  Check('admin token handed out once', (Token <> 0) and (ClaimToken() = 0));
  Check('console commands need the token', (Command(0, '/zs_status', 2, 0, 10) = 0) and
    (Command(0, '/zs_status', 2, Token + 1, 10) = 0) and (Command(0, '/zs_status', 2, Token, 10) = 1));
  Check('ZitroStats commands are claimed', Command(1, '/zitro', 1, 0, 10) = 1);
  Check('other commands are left alone', Command(1, '/kick someone', 1, 0, 10) = 0);
  Check('Soldat''s /info and /pm stay Soldat''s, !info and !pm are ours', (Command(1, '/info', 1, 0, 10) = 0) and
    (Command(0, '/pm 2 hello', 2, Token, 10) = 0) and (Command(1, '!info', 0, 0, 10) = 1) and (Command(1, '!pm', 0, 0, 10) = 1));
  Check('identity commands are claimed', Command(1, '/login secret', 1, 0, 10) = 1);
  Sleep(400);

  { the way main.pas polls: ZS_Action_Begin opens a tick, ZS_Action_Next until 0 }
  Help := False;
  Lines := 0;
  Ticks := 0;
  MostInTick := 0;
  while Ticks < 1000 do
  begin
    { main.pas polls once a tick; ticks that come back to back get nothing }
    Sleep(10);
    if ActionBegin() = 0 then
      Break;
    Inc(Ticks);
    InTick := 0;
    repeat
      Kind := ActionNext();
      if Kind <> 0 then
      begin
        Inc(Lines);
        Txt := StrPas(ActionText());
        if ActionSlot() = 1 then
        begin
          Inc(InTick);
          if Pos('ZitroStats', Txt) > 0 then
            Help := True;
        end;
      end;
    until Kind = 0;
    if InTick > MostInTick then
      MostInTick := InTick;
  end;
  Check('command output polled through the exports', Help and (Lines >= 3));
  Check(Format('one player gets at most 4 lines a tick (%d lines in %d ticks)', [Lines, Ticks]), MostInTick <= 4);
  Check('developer API: profile count', ProfileCount() = 2);
  Check('developer API: player points', Round(PlayerStat(1, 0)) = 1000);
  Check('developer API: MMR before the first rated match', Round(PlayerStat(1, 39)) = 1500);
  Check('developer API: unknown StatID gives 0', PlayerStat(1, 40) = 0);
  Check('the API version of the library', ApiVersion() = ZS_API_VERSION);

  { main.pas sends the healing of a player once a second; it lands in the profile and !stats
    shows it. Negative values and slots without a player change nothing. Slot 2, because slot 1
    has used up its commands of this second above. }
  Heal(2, 2, 20, 12.0, 30.0);
  Heal(2, -3, 21, -50.0, -20.0);
  Heal(40, 1, 21, 5.0, 5.0);
  Heal(0, 1, 21, 5.0, 5.0);
  Check('!stats is a ZitroStats command', Command(2, '!stats', 0, 0, 25) = 1);
  Help := WaitLine(2, 'Healed:', 5000, HealLine);
  Check('healing lands in the profile: ' + Trim(HealLine), Help and (Pos('Healed: 42 HP', HealLine) > 0) and
    (Pos('Regen: 12 HP', HealLine) > 0) and (Pos('Kits: 2 (30 HP)', HealLine) > 0));
  Check('after the last action there is nothing left to read', (ActionSlot() = 0) and (StrPas(ActionText()) = ''));

  { OnBeforeJoin of a player who joins the server: never -1, the server would take it for full }
  n := TeamJoin(3, TEAM_ALPHA, 255, 30);
  Check(Format('a player who joins the server gets a team (%d)', [n]), (n >= 0) and (n <= TEAM_SPEC));

  { the copy for another library: the result is the length, the text always ends with a zero }
  Buf[0] := 'X';
  Check('Top_Player_Copy: a buffer of one byte gets the closing zero', (TopCopy(1, @Buf[0], 1) = 0) and (Buf[0] = #0));
  Check('Top_Player_Copy: no buffer', TopCopy(1, nil, 16) = 0);
  FillChar(Buf, SizeOf(Buf), Ord('X'));
  n := TopCopy(1, @Buf[0], SizeOf(Buf));
  Check(Format('Top_Player_Copy: the text ends with a zero (%d)', [n]), (n >= 0) and (n < SizeOf(Buf)) and (Buf[n] = #0));
  Txt := StrPas(@Buf[0]);
  Buf[0] := 'X';
  Check('Top_Player_Copy2: a buffer of one byte gets the closing zero', (TopCopy2(1, @Buf[0], 1) = 0) and (Buf[0] = #0));
  Check('Top_Player_Copy2: no buffer', TopCopy2(1, nil, 16) = 0);
  FillChar(Buf, SizeOf(Buf), Ord('X'));
  n := TopCopy2(1, @Buf[0], SizeOf(Buf));
  Txt2 := StrPas(@Buf[0]);
  Check(Format('Top_Player_Copy2: the text of Top_Player_Copy, a tab and the computer (%d)', [n]),
    (n >= 0) and (n < SizeOf(Buf)) and (Buf[n] = #0) and (((Txt = '') and (Txt2 = '')) or
    ((Copy(Txt2, 1, Length(Txt) + 1) = Txt + #9) and (Pos(#9, Copy(Txt2, Length(Txt) + 2, MaxInt)) = 0))));

  { the map vote: the maps list of main.pas; /votemap (also what F12 sends) is claimed while the map
    vote is on (the default), /map and /nextmap stay the server's (slot 5 plays no part here) }
  MapListEv(2, 0, MAPLIST_CHANGED, 40, PChar('ctf_Run' + #10 + 'ctf_Ash' + #10));
  Check('/votemap belongs to the map vote, also as F12 sends it',
    (Command(5, '/votemap ctf_Run', SRC_COMMAND, 0, 41) = 1) and (Command(5, 'votemap ctf_Run', SRC_COMMAND, 0, 41) = 1));
  Check('/map and /nextmap stay the server''s, !map and !nextmap are ZitroStats commands',
    (Command(5, '/map ctf_Run', SRC_COMMAND, 0, 41) = 0) and (Command(5, '/nextmap', SRC_COMMAND, 0, 41) = 0) and
    (Command(5, '!nextmap', SRC_CHAT, 0, 41) = 1) and (Command(5, '!map ash', SRC_CHAT, 0, 41) = 1));
  Check('the maps list reaches the map vote', (Command(0, '/zs_mapvote', SRC_CONSOLE, Token, 42) = 1) and
    WaitLine(0, 'maps list: 2 maps, next ctf_Ash', 5000, Txt));
  Check('!searchmap, !allweaponsby and !serverweaponsby are ZitroStats commands',
    (Command(5, '!searchmap ctf', SRC_CHAT, 0, 43) = 1) and (Command(5, '!allweaponsby kills', SRC_CHAT, 0, 43) = 1) and
    (Command(5, '/serverweaponsby kills', SRC_COMMAND, 0, 43) = 1));

  { the kits a player picks up, by kind; a style that is no kit counts nothing. Slot 2 has used its
    commands of this second above, so the answer waits for the next second. }
  { outside a server the library reads no health: main.pas counts what a kit gave (0) }
  Check('ZS_Ev_Kit leaves the health of the kits to main.pas when nothing is read (0)',
    (Kit(2, KIT_MEDICAL, 50) = 0) and (Kit(2, KIT_VEST, 51) = 0) and (Kit(2, 5, 52) = 0));
  Sleep(1100);
  Check('!otherstats is a ZitroStats command', Command(2, '!otherstats', 0, 0, 120) = 1);
  Help := WaitLine(2, 'Kits: Med', 5000, Txt);
  Check('the kits picked up land in the profile: ' + Trim(Txt), Help and
    (Txt = 'Kits: Med 1, Nade 0, Cluster 0, Vest 1, Berserk 0, Predator 0, Flamer 0'));

  { a hit as main.pas sends it, with the velocities of both players: the AK bullet of Other reaches
    Tester, who runs at 7 pixels a tick, and kills him. Nobody saw the shot, so the bullet tells
    where it came from (~); Tester's !lastfight shows his speed at the hit, 30 m/s. }
  DamageEv(2, 1, 5, WEP_AK74, EF_BULLET or EF_A_ALIVE, 200, 20, 0, 300, 100, -24, 0, 300, 100, 150, 7, 0, 0, 0);
  KillEv(2, 1, 5, WEP_AK74, EF_BULLET or EF_A_ALIVE, WEP_AK74, 200, 600, 100, 300, 100, 300, 100, 0);
  Sleep(1100);
  Check('!lastfight is a ZitroStats command', Command(1, '!lastfight', SRC_CHAT, 0, 210) = 1);
  { the line of the hit in the timeline, the only one with a speed }
  Help := WaitLine(1, ' m/s', 5000, Txt);
  Check('ZS_Ev_Damage: the victim''s velocity is his speed, the bullet tells the distance: ' + Trim(Txt),
    Help and (Pos('killed you', Txt) > 0) and (Pos('30 m/s', Txt) > 0) and (Pos('~5 m', Txt) > 0));

  { [Bridges] (5.6): this program is no Soldat server - nothing of one is found, every bridge says so,
    and the events of the script go on as before }
  Check('ZS_Frame follows nobody here', Frame(300) = 0);
  Check(Format('no hook and no memory reading outside a server (%d)', [Bridges()]), Bridges() and 7 = 0);
  Check('ZS_Bind finds no soldier', (Bind(1, nil, 0, 0) = 0) and (Bind(40, nil, 0, 0) = 0));
  Check('ZS_Check checks nothing', CheckMem(1, 1, 3, 30, 1, 7, 2, 190, 1, 0, 100, 200, 150, 0) = -1);
  Check('ZS_Ev_Hit and ZS_Ev_Death leave the events to main.pas', (Hit(2, 1, 5, 300, 20) = 0) and
    (Death(2, 1, 5, 0, 300) = 0) and (Hit(0, 33, 5, 300, 20) = 0) and (Death(33, 0, 5, 0, 300) = 0));
  Check('/zs_perf tells why the bridges do not run', (Command(0, '/zs_perf', SRC_CONSOLE, Token, 301) = 1) and
    WaitLine(0, 'bridges: memory: not available', 5000, Txt));

  T0 := GetTickCount64;
  Shutdown();
  Check('shutdown returns', GetTickCount64 - T0 < 10000);
  Check('restart after shutdown', Init(PChar(Root + PathDelim + 'script'), ZS_API_VERSION) = ZS_API_VERSION);
  { a /recompile is a shutdown and an init: the diagnostics go on }
  try
    WriteNil;
  except
  end;
  Txt := FileText(CrashLog);
  Check('crash.log after a shutdown and a new init', (Occurrences('code C0000005', Txt) = 2) and
    (Pos('E0465043', Txt) = 0));
  Check('a new engine has a new token', ClaimToken() <> 0);
  T0 := GetTickCount64;
  while (IsReady() = 0) and (GetTickCount64 - T0 < 10000) do
    Sleep(10);
  Check('accounts persisted', ProfileCount() = 2);
  { the engine of a script start is a new one: the bridges tell it again what runs (else it would
    count the shots of the hook and of the ammunition both) }
  Check('a new engine hears what the bridges do', (Frame(400) = 0) and
    WaitLine(0, '[ZitroStats] bridges: hooks:', 5000, Txt));
  Shutdown();

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
