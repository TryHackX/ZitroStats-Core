program test_fix_ws1;

{ The fixes of the audit of 2026-10-06, workstream 1. main.pas compiles only on a server, so what
  it must say is read from its text here: the API number and the start line of this release. The
  same for build.sh, which runs only on Linux. The bridges of the library (zs_bridge, zs_hook) run
  here without a server: what they must leave as it is. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, dynlibs, zs_types, zs_hook, zs_bridge;

const
  DLL_IMPORT = '@scripts/ZitroStats-Core/zitrostats_dll.dll';
  { CMD_VIA_COMMAND and CMD_VIA_ADMIN of main.pas }
  CMD_VIA_COMMAND_T = 1;
  CMD_VIA_ADMIN_T = 2;
  { the exports of ZitroStats 5.5 (API 15) that main.pas imports: every other import is newer and
    must be "delayload", so that main.pas still loads with an older library and ZS_Init can say so }
  API15_IMPORTS = ' ZS_Init ZS_Claim_Token ZS_Shutdown ZS_Ev_Join ZS_Ev_Leave ZS_Ev_Team ZS_Ev_Steam_Auth ' +
    'ZS_Ev_Spawn ZS_Ev_Kill ZS_Ev_Damage ZS_Ev_Grenade ZS_Ev_Knife_Throw ZS_Ev_Weapon ZS_Ev_Ammo ' +
    'ZS_Ev_Realistic ZS_Ev_Kit ZS_Ev_Heal ZS_Ev_Flag ZS_Ev_Sample ZS_Ev_Tick ZS_Ev_Map_Before ZS_Ev_Map_After ' +
    'ZS_Ev_Player_Score ZS_Ev_Vote ZS_Ev_Map_List ZS_Ev_Ray ZS_Ev_Integrity ZS_Ev_Move_Result ZS_Team_Join ' +
    'ZS_Command ZS_Action_Begin ZS_Action_Next ZS_Action_Slot ZS_Action_Color ZS_Action_Int ZS_Action_Text ';

var
  Failures: Integer = 0;
  Pushed: LongInt = 0;

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

procedure CountPush(var E: TZSEvent);
begin
  Inc(Pushed);
end;

function ReadText(const Path: AnsiString): AnsiString;
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

{ the names main.pas imports from the library (its Windows import strings), one per line }
function ImportedNames(const Src: AnsiString): TStringList;
var
  p, q: LongInt;
begin
  Result := TStringList.Create;
  p := Pos(DLL_IMPORT, Src);
  while p > 0 do
  begin
    q := p - 1;
    while (q > 0) and (Src[q] <> '''') do
      Dec(q);
    Result.Add(Copy(Src, q + 1, p - q - 1));
    p := Pos(DLL_IMPORT, Src, p + Length(DLL_IMPORT));
  end;
end;

{ both import strings of a declaration of main.pas (Windows and Linux) end in "cdecl delayload" }
function DelayLoaded(const Src, Name: AnsiString): Boolean;
begin
  Result := (Pos('''' + Name + '@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload''', Src) > 0) and
    (Pos('''' + Name + '@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload''', Src) > 0);
end;

{ the text of Src from From up to the next Till (or the end) }
function Between(const Src, From, Till: AnsiString): AnsiString;
var
  p, q: LongInt;
begin
  Result := '';
  p := Pos(From, Src);
  if p = 0 then
    Exit;
  q := Pos(Till, Src, p + Length(From));
  if q = 0 then
    q := Length(Src) + 1;
  Result := Copy(Src, p, q - p);
end;

{ the value of a string constant Name = '...'; of a Pascal source ('' when there is none) }
function ConstText(const Src, Name: AnsiString): AnsiString;
var
  p, q: LongInt;
begin
  Result := '';
  p := Pos(Name + ' = ''', Src);
  if p = 0 then
    Exit;
  Inc(p, Length(Name) + 4);
  q := Pos('''', Src, p);
  if q > p then
    Result := Copy(Src, p, q - p);
end;

{ HandleCommandDown of main.pas, word for word: True = the command is taken }
function TakenWhileDown(const Command, Words: AnsiString): Boolean;
var
  S: AnsiString;
  Sp: LongInt;
begin
  Result := False;
  S := LowerCase(Trim(Command));
  Sp := Pos(' ', S);
  if Sp > 0 then
    S := Copy(S, 1, Sp - 1);
  if Length(S) > 0 then
    if (S[1] = '/') or (S[1] = '!') then
      Delete(S, 1, 1);
  if Length(S) = 0 then
    Exit;
  Result := Pos(' ' + S + ' ', Words) > 0;
end;

{ CommandHash of main.pas, word for word (built here with overflow and range checks) }
function CommandHash(S: AnsiString): Integer;
var
  i, H: Integer;
begin
  H := Length(S);
  for i := 1 to Length(S) do
    H := (H mod 1000003) * 31 + Ord(S[i]);
  Result := H;
end;

{ PlayerCommand of main.pas for one slot: Runs counts the commands that reach the library }
var
  CmdTick, CmdHash, CmdVia, Runs: Integer;
  CmdHandled: Boolean;

function PlayerCommand(const Command: AnsiString; Via, Tick: Integer): Boolean;
var
  Hash: Integer;
begin
  Hash := CommandHash(Command);
  if CmdTick = Tick then
    if CmdVia <> Via then
      if CmdHash = Hash then
      begin
        CmdTick := -1;
        Result := CmdHandled;
        Exit;
      end;
  Inc(Runs);
  Result := Pos('/login', Command) = 1;
  CmdTick := Tick;
  CmdHash := Hash;
  CmdVia := Via;
  CmdHandled := Result;
end;

{ the rule of HandleDamage in main.pas (survival, a hit of a player on himself): True = the server
  killed him itself (no death of his), False = a real death }
function ServerHitRule(InGame: Boolean; Damage: Single; BulletId: Byte; JoinedThisTick: Boolean): Boolean;
begin
  Result := not InGame;
  if (Damage > 3900) or (Damage = 1000) then
    if (BulletId = 255) or JoinedThisTick then
      Result := True;
end;

var
  MainPas, BuildSh, WhyBefore, Missing, NotDelayed, Ident, Down, Body, Lost, Long: AnsiString;
  Words: TStringList;
  R1, R2, R3, R4: Boolean;
  Names: TStringList;
  Lib: TLibHandle;
  k: LongInt;
begin
  { the runner starts the tests in source_dll; main.pas lies one level up }
  MainPas := ReadText('..' + PathDelim + 'main.pas');
  Check('main.pas found', MainPas <> '');

  { the release: main.pas and the library speak the same API and name the same version }
  Check('main.pas speaks the API of the library (' + IntToStr(ZS_API_VERSION) + ')',
    Pos('  ZS_API_VERSION = ' + IntToStr(ZS_API_VERSION) + ';', MainPas) > 0);
  Check('main.pas names the release of the library (' + ZS_VERSION_STR + ')',
    Pos('''[ZitroStats] ' + ZS_VERSION_STR + ' started, loading data in the background.''', MainPas) > 0);
  Check('ZitroStats 5.7, API 17', (ZS_VERSION_STR = '5.7') and (ZS_API_VERSION = 17));

  { ZSS-01: build.sh never writes into the library a running server has loaded: a new file, renamed
    over the old one }
  BuildSh := ReadText('build.sh');
  Check('build.sh found', BuildSh <> '');
  Check('build.sh: no copy onto the loaded library',
    Pos('cp -f "$OUT/zitrostats_dll.so" ../zitrostats_dll.so' + LineEnding, BuildSh) = 0);
  Check('build.sh: a new file renamed over the old one',
    (Pos('cp -f "$OUT/zitrostats_dll.so" ../zitrostats_dll.so.new', BuildSh) > 0) and
    (Pos('mv -f ../zitrostats_dll.so.new ../zitrostats_dll.so', BuildSh) > 0) and
    (Pos('mv -f', BuildSh) > Pos('cp -f "$OUT/zitrostats_dll.so"', BuildSh)));

  { ZSS-02: without the hook the place of the server's tick is still looked for - patching nothing,
    and the reason the hook is not in place stays 'not installed' (here no server is found at all) }
  WhyBefore := HookWhy;
  HookLocateOnly;
  Check('HookLocateOnly patches nothing', not HookInstalled and not HitHookInstalled);
  Check('HookLocateOnly leaves the reason of the hook as it was: ' + HookWhy,
    (HookWhy = WhyBefore) and (HookWhy = 'CreateBullet not installed, HealthHit not installed'));
  BridgeWantHook := 0;
  BridgeWantMemory := 1;
  BridgeFrame(100);
  BridgeFrame(101);
  Check('ServerHook = 0: the frames install no hook and keep its reason: ' + HookWhy,
    not HookInstalled and (HookWhy = 'CreateBullet not installed, HealthHit not installed'));

  { ZSE1-03: ZS_Shutdown hands the bullets of the last tick to the engine before the hook goes;
    without a hook there are none, and nothing else is sent }
  BridgePush := @CountPush;
  Pushed := 0;
  BridgeDrainShots;
  Check('BridgeDrainShots without a hook sends nothing', Pushed = 0);

  { ZSS-06: every declaration of main.pas is an export of the library; ZS_Ev_Shot, which main.pas
    never called, is no longer imported - the library keeps it for older scripts }
  Names := ImportedNames(MainPas);
  Lib := LoadLibrary('build' + PathDelim + 'win32' + PathDelim + 'zitrostats_dll.dll');
  Check('the built library loads', Lib <> NilHandle);
  Missing := '';
  if Lib <> NilHandle then
    for k := 0 to Names.Count - 1 do
      if GetProcedureAddress(Lib, Names[k]) = nil then
        Missing := Missing + ' ' + Names[k];
  Check(Format('the %d imports of main.pas are exports of the library%s', [Names.Count, Missing]),
    (Names.Count >= 40) and (Missing = ''));
  Check('main.pas does not import ZS_Ev_Shot', Names.IndexOf('ZS_Ev_Shot') < 0);
  Check('the library still exports ZS_Ev_Shot', (Lib <> NilHandle) and (GetProcedureAddress(Lib, 'ZS_Ev_Shot') <> nil));

  { ZSS-07: the imports newer than API 15 are loaded when they are first called }
  NotDelayed := '';
  for k := 0 to Names.Count - 1 do
    if (Pos(' ' + Names[k] + ' ', API15_IMPORTS) = 0) and not DelayLoaded(MainPas, Names[k]) then
      NotDelayed := NotDelayed + ' ' + Names[k];
  Check('every import newer than API 15 is delayload' + NotDelayed, NotDelayed = '');
  Check('ZS_Frame, ZS_Bind, ZS_Check, ZS_Bridges, ZS_Ev_Hit, ZS_Ev_Death are delayload',
    DelayLoaded(MainPas, 'ZS_Frame') and DelayLoaded(MainPas, 'ZS_Bind') and DelayLoaded(MainPas, 'ZS_Check') and
    DelayLoaded(MainPas, 'ZS_Bridges') and DelayLoaded(MainPas, 'ZS_Ev_Hit') and DelayLoaded(MainPas, 'ZS_Ev_Death'));
  Check('ZS_Init and ZS_Shutdown load the library with the script', not DelayLoaded(MainPas, 'ZS_Init') and
    not DelayLoaded(MainPas, 'ZS_Shutdown'));

  { ZSI-04: when the library does not start, main.pas still takes every command of the accounts (a
    password must never reach the server's log) and answers from the tick, without the library }
  Ident := ConstText(ReadText('zs_commands.pas'), 'IDENTITY_COMMANDS');
  Down := ConstText(MainPas, 'DOWN_COMMANDS');
  Check('the identity commands of the library found', Pos(' login ', Ident) > 0);
  Words := TStringList.Create;
  try
    Words.Delimiter := ' ';
    Words.StrictDelimiter := True;
    Words.DelimitedText := Trim(Ident) + ' zs_setpass';
    Lost := '';
    for k := 0 to Words.Count - 1 do
      if (Words[k] <> '') and (Pos(' ' + Words[k] + ' ', Down) = 0) then
        Lost := Lost + ' ' + Words[k];
  finally
    Words.Free;
  end;
  Check('main.pas takes every identity command and /zs_setpass without the library' + Lost, Lost = '');
  Check('the commands taken: /login, /REGISTER, /changepass with their passwords, /zs_setpass',
    TakenWhileDown('/login secret', Down) and TakenWhileDown('/REGISTER name pass pass', Down) and
    TakenWhileDown('/changepass a b', Down) and TakenWhileDown('  /zs_setpass acc newpass', Down) and
    TakenWhileDown('/removemypass pw', Down));
  Check('other commands stay the server''s', not TakenWhileDown('/loginx a', Down) and
    not TakenWhileDown('/kick 2', Down) and not TakenWhileDown('/', Down) and not TakenWhileDown('', Down) and
    not TakenWhileDown('/log in', Down) and not TakenWhileDown('/zs_status', Down));
  Body := Between(MainPas, 'function HandleCommandDown(', 'procedure Startup();');
  Check('the fallback handlers call nothing of the library', (Body <> '') and (Pos('ZS_', Body) = 0) and
    (Pos('WriteConsole', Between(Body, 'function HandleCommandDown(', 'procedure HandleClockDown(')) = 0));
  Body := Between(MainPas, 'Version := ZS_Init(', 'Started := True;');
  Check('a failed ZS_Init sets the fallback handlers before it leaves', (Pos('@HandleCommandDown', Body) > 0) and
    (Pos('@HandleClockDown', Body) > 0) and (Pos('@HandleCommandDown', Body) < Pos('Exit;', Body)));

  { ZSS-05: only the second copy of an admin's command (OnCommand, then OnAdminCommand) is answered
    from the first; two commands of the same length in one tick both reach the library }
  Check('main.pas: CommandHash as tested here', Pos('    H := (H mod 1000003) * 31 + Ord(S[i]);', MainPas) > 0);
  Check('main.pas: no command is told by its length any more', Pos('CmdLength', MainPas) = 0);
  Check('main.pas: OnCommand and OnAdminCommand say where a command came from',
    (Pos('PlayerCommand(Player, Command, BoolInt(Player.IsAdmin), CMD_VIA_COMMAND)', MainPas) > 0) and
    (Pos('PlayerCommand(Player, Command, 1, CMD_VIA_ADMIN)', MainPas) > 0));
  SetLength(Long, 4096);
  FillChar(Long[1], Length(Long), #255);
  Check('CommandHash of 4096 x #255 does not overflow', CommandHash(Long) > 0);
  Check('CommandHash tells commands of one length apart',
    (CommandHash('/zs_xyz12') <> CommandHash('/login ab')) and (CommandHash('/login abc') <> CommandHash('/login abd')) and
    (CommandHash('/login abc') <> CommandHash('/login acb')));
  CmdTick := -1;
  Runs := 0;
  R1 := PlayerCommand('/zs_xyz12', CMD_VIA_COMMAND_T, 500);
  R2 := PlayerCommand('/login ab', CMD_VIA_COMMAND_T, 500);
  Check(Format('a player: two commands of one length in one tick both run (%d)', [Runs]),
    (Runs = 2) and not R1 and R2);
  Runs := 0;
  R1 := PlayerCommand('/zs_top', CMD_VIA_COMMAND_T, 600);
  R2 := PlayerCommand('/zs_top', CMD_VIA_ADMIN_T, 600);
  R3 := PlayerCommand('/login x', CMD_VIA_COMMAND_T, 600);
  R4 := PlayerCommand('/login x', CMD_VIA_ADMIN_T, 600);
  Check(Format('an admin: each command runs once, its copy gets the same answer (%d)', [Runs]),
    (Runs = 2) and not R1 and not R2 and R3 and R4);
  Runs := 0;
  R1 := PlayerCommand('/zs_top', CMD_VIA_COMMAND_T, 700);
  R2 := PlayerCommand('/login y', CMD_VIA_ADMIN_T, 700);
  Check(Format('an admin: another command in the other handler is no copy (%d)', [Runs]), (Runs = 2) and R2);

  { X-02: in survival a hit of 4000 on oneself is the server's only at the end of a round (bullet id
    255) or in the tick of OnBeforeJoin; Basic-Extended's Player.Damage(V, 4000) is a real death }
  Body := Between(MainPas, 'function BeforeJoin(', 'function HandleBeforeJoin0(');
  Check('main.pas: OnBeforeJoin notes the tick first, for everybody',
    (Pos('JoinTick[ID] := Game.TickCount;', Body) > 0) and
    (Pos('JoinTick[ID] := Game.TickCount;', Body) < Pos('if not Started then', Body)) and
    (Pos('if Player <> nil then', Body) < Pos('JoinTick[ID] := Game.TickCount;', Body)));
  Body := Between(MainPas, 'function HandleDamage(', 'procedure HandleFlagGrab(');
  Check('main.pas: HandleDamage uses the rule tested here',
    (Pos('      ServerHit := not InGame[VID];', Body) > 0) and
    (Pos('      if (Damage > SERVER_HIT_DAMAGE) or (Damage = SERVER_HIT_VEST) then', Body) > 0) and
    (Pos('        if (BulletId = SERVER_HIT_BULLET) or (JoinTick[VID] = Game.TickCount) then', Body) > 0) and
    (Pos('  SERVER_HIT_BULLET = 255;', MainPas) > 0) and (Pos('  SERVER_HIT_DAMAGE = 3900;', MainPas) > 0) and
    (Pos('  SERVER_HIT_VEST = 1000;', MainPas) > 0));
  Check('the server''s kills: the end of a round (also through a vest, of a berserker), a team change, a connect',
    ServerHitRule(True, 4000, 255, False) and ServerHitRule(True, 1000, 255, False) and
    ServerHitRule(True, 16000, 255, False) and ServerHitRule(True, 4000, 1, True) and
    ServerHitRule(False, 150, 1, False));
  Check('real deaths: Player.Damage(V, 4000) of a script (also through a vest, of a berserker), /kill, /brutalkill, '+
    'an own grenade', not ServerHitRule(True, 4000, 1, False) and not ServerHitRule(True, 1000, 1, False) and
    not ServerHitRule(True, 16000, 1, False) and not ServerHitRule(True, 150, 1, False) and
    not ServerHitRule(True, 3423, 1, False) and not ServerHitRule(True, 95, 12, False));

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
