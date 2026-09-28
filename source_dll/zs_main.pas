library zitrostats_dll;

{ ZitroStats 5 native core.

  Every export uses cdecl and never lets an exception reach the caller. All of them return at
  once except ZS_Shutdown, which waits while the engine thread writes what is pending and stops,
  and ZS_API_Top_Player_Copy, which waits for the engine and is never called from the game
  thread. Game events are only queued here; the engine thread does the work (see zs_engine).
  When the engine falls far behind, the queue drops the events other than joins, leaves and map
  changes, so the game thread never waits for it and the queue does not grow without end.

  The library pins itself on the first ZS_Init. A script reload therefore finds the running
  engine again instead of unloading code under running threads. ZS_Shutdown (called from the
  script's finalization) writes pending data and stops the threads; the next ZS_Init starts a
  fresh engine from the files.

  Lifecycle:
    ZS_Init             script folder, API version: ZS_API_VERSION when the engine runs,
                        -ZS_API_VERSION when main.pas comes from another release, 0 when the
                        engine could not start (nothing is left running then)
    ZS_Shutdown         writes pending data and stops the threads
    ZS_Is_Ready         1 once the data is loaded
    ZS_Get_Api_Version  the ZS_API_VERSION of this library
    ZS_Reload_Config    reads settings.ini again, on the engine thread

  Event exports (Tick = Game.TickCount):
    ZS_Ev_Join          slot, name, SteamID ('' until Steam confirmed it), HWID, IP (all three ''
                        for a bot), team, human, admin token
    ZS_Ev_Leave         slot, kicked
    ZS_Ev_Team          slot, new team
    ZS_Ev_Steam_Auth    slot, SteamID, auth state (0 = ok)
    ZS_Ev_Spawn         slot, primary, secondary, position
    ZS_Ev_Kill          killer, victim, bullet id, weapon, EF_* flags (EF_SERVER_KILL: the server
                        killed the player itself, no death), victim weapon,
                        killer x/y, victim x/y, bullet x/y (valid with EF_BULLET), victim vest
    ZS_Ev_Damage        shooter, victim, bullet id, weapon, EF_* flags, damage, victim vest
                        before the hit, bullet x/y, bullet velocity x/y, victim x/y, victim health
                        before the hit, victim velocity x/y, shooter velocity x/y (pixels a tick)
    ZS_Ev_Shot          slot, weapon, shots fired this tick, shooter position (scripts before
                        API 12; main.pas sends ZS_Ev_Ammo)
    ZS_Ev_Ammo          slot, weapon, ammunition before and now, 1 = the reload key was down when
                        the magazine emptied, shooter position: shots and reloads
    ZS_Ev_Grenade       slot, grenades thrown, cluster (0/1), position
    ZS_Ev_Knife_Throw   slot, position
    ZS_Ev_Weapon        slot, primary, secondary, the ammunition of both
    ZS_Ev_Realistic     realistic mode switched on (1) or off (0) while the script runs
    ZS_Ev_Kit           slot, kit style
    ZS_Ev_Heal          slot, kits that healed, health got back from regenerating polygons (up to
                        the full health) and from medical, berserker and predator kits; the script
                        adds it up and sends it once a second and when the player leaves
    ZS_Ev_Flag          slot, FLAG_* kind, team, position; FLAG_BASE (slot 0) = where a flag
                        stands in its base
    ZS_Ev_Sample        slot, EF_A_* flags, weapon, ammo, jets, position
    ZS_Ev_Tick          once per second: team scores, time left, game style
    ZS_Ev_Map_Before    next map, final team scores, time left, score limit
    ZS_Ev_Map_After     map, game style, score limit, time limit, MF_* flags
    ZS_Ev_Player_Score  slot, scoreboard kills, deaths (sent right before ZS_Ev_Map_Before)
    ZS_Ev_Vote          slot, kind (1 map vote started, 2 kick vote started, 3 a vote cast for the
                        map vote that runs), target. With [MapVote] Enabled the map vote is the
                        library's: kind 1 (the vote menu, the server's /votemap; OnVoteMapStart
                        returns True so Soldat's own vote does not start) asks for a vote for that
                        map, kind 3 (F12) is a yes vote
    ZS_Ev_Map_List      the server's maps list: the number of maps, Game.MapsList.CurrentMapId, why
                        it is sent (MAPLIST_START, MAPLIST_MAPCHANGE, MAPLIST_ADMIN after /addmap,
                        /delmap or /loadlist, MAPLIST_CHANGED when the check of the script saw
                        another list), the tick and the names, each followed by a line break (#10)
    ZS_Ev_Ray           answer to an ACT_RAYCAST action: request id, RAY_CLEAR / RAY_BLOCKED /
                        RAY_UNKNOWN (Map.RayCast not calibrated yet)
    ZS_Ev_Move_Result   answer to an ACT_MOVE action: slot, team, MOVE_DONE / MOVE_ALIVE /
                        MOVE_FLAGGER / MOVE_REFUSED / MOVE_ALREADY
    ZS_Ev_Integrity     what the score guard of main.pas did: slot, IGE_* kind, team, a value (the
                        score it set back, or how many players IGE_RESPAWN put back on their
                        feet), 1 when a capture was taken back, text (the map of IGE_MAPCHANGE)
  Actions: ZS_Action_Begin once a tick (it returns how many wait, and 0 for a tick that comes
  less than 8 ms after the last one, when Soldat catches up after a stall), then ZS_Action_Next
  until 0. ZS_Action_Slot, ZS_Action_Color, ZS_Action_Int and ZS_Action_Text describe the action
  ZS_Action_Next returned last (0 and '' after it returned 0); the text stays valid until the
  next ZS_Action_Next. They are for one reader, the game thread. The library keeps to the limits
  of a tick (4 console lines or big texts per player and 24 in all, 2 team moves or kicks, 2
  broadcasts, 4 server console lines, 8 ray casts) and leaves the rest for the next tick. Kinds:
  ACT_CONSOLE (slot, colour, text), ACT_BROADCAST (colour, text), ACT_BIGTEXT (slot, colour,
  text, Int 1 layer, Int 2,3 position, Int 4 scale x 10000, Int 5 time in ticks), ACT_WRITELN
  (text for the server console), ACT_SETTEAM (slot, team Int 1), ACT_KICK (slot, a last line to
  the player), ACT_RAYCAST - the library cannot see the map, so it asks the script whether the
  line from Int 2,3 to Int 6,7 is clear and waits for ZS_Ev_Ray with Int 1 - and
  ACT_MOVE: the team balance moves the player to team Int 1 (Int 2 = MOVE_DEAD_ONLY: only while
  dead), the script answers with ZS_Ev_Move_Result, and ACT_INTEGRITY, which carries the settings
  of the score guard (Int 1 = IG_* flags, Int 2 = the opponents a point needs). The map vote:
  ACT_VOTE_START (text = the map: the script keeps Game.VotePercent, sets it to 200 and calls
  Game.StartVoteMap, so the clients see the vote and F12 works while Soldat never passes it),
  ACT_VOTE_END (the percent goes back once Soldat's own vote has run out; Int 1 = the percent when
  the script does not know the old one, 0 = leave it), ACT_MAP_CHANGE (text = the map; Int 1 = 1:
  it is Game.NextMap, Map.NextMap moves the list on, otherwise Map.SetMap) and ACT_MAPVOTE, its
  settings (Int 1 = MV_* flags, Int 2 = [MapVote] RestoreVotePercent).
  ZS_Team_Join is called from a Game.Teams[n].OnBeforeJoin handler: it returns the team the
  player should enter (or -1 to keep a player in the team they have) at once, from a picture of
  the teams the engine keeps up to date; it never waits for the engine. A player who joins the
  server (OldTeam 255) always gets a team, never -1.
  ZS_Command copies the text and returns at once, 1 when it is a ZitroStats command; the script
  should then report the command as handled so it is neither processed further nor logged. The
  answer comes later, through the actions. /votemap (what F12 and the vote menu of the clients send
  too) is a ZitroStats command while [MapVote] Enabled and SlashVoteMap are on; /map and /nextmap
  always stay the server's.
  ZS_Claim_Token hands main.pas a random token, once per script. A script that is loaded again
  (a recompile or a change of the game mode) may claim it again. The admin arguments of
  ZS_Ev_Join and ZS_Command count only when they carry this token, and console commands need
  it, so another script cannot run admin commands through the library.
  Developer API (compatible with 4.5, see DEVELOPER_API.md): the ZS_API_Get_* functions answer
  at once, from the last picture of the statistics when the engine is busy. The text that
  ZS_API_Get_Player_Name and ZS_API_Get_Top_Player return is one buffer, valid until the next of
  these calls, so they belong to the game thread; another library on a thread of its own uses
  ZS_API_Top_Player_Copy, which writes into a buffer of the caller. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, zs_types, zs_util, zs_engine, zs_commands, zs_crash, zs_maps;

const
  { the names of the maps list (ZS_Ev_Map_List) are read up to this length }
  MAPLIST_TEXT_MAX = 256 * 1024;
  GET_MODULE_HANDLE_EX_FLAG_PIN = 1;
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 2;
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 4;
{$IFNDEF WINDOWS}
  RTLD_NOW_FLAG = 2;
  RTLD_NODELETE_FLAG = $1000;
{$ENDIF}

var
  Engine: TZSEngine = nil;
  Pinned: Boolean = False;
  CurAction: TZSAction;
  ActionTextBuf: AnsiString;
  ApiTextBuf: AnsiString;
  { another library asks the engine on a thread of its own (ZS_API_Top_Player_Copy) while the game
    thread may free it (ZS_Shutdown): the engine is freed only when no such call is inside }
  ExtLock: TRTLCriticalSection;

{$IFDEF WINDOWS}
function PinModuleHandle(Flags: DWORD; Addr: Pointer; var Module: HMODULE): BOOL; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleExA';
{$ELSE}
type
  TDlInfo = record
    dli_fname: PAnsiChar;
    dli_fbase: Pointer;
    dli_sname: PAnsiChar;
    dli_saddr: Pointer;
  end;

function zs_dladdr(Addr: Pointer; var Info: TDlInfo): LongInt; cdecl; external 'dl' name 'dladdr';
function zs_dlopen(Name: PAnsiChar; Flags: LongInt): Pointer; cdecl; external 'dl' name 'dlopen';
{$ENDIF}

procedure PinModule;
{$IFDEF WINDOWS}
var
  H: HMODULE;
begin
  H := 0;
  if not Pinned then
    Pinned := PinModuleHandle(GET_MODULE_HANDLE_EX_FLAG_PIN or GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, @PinModule, H);
end;
{$ELSE}
var
  Info: TDlInfo;
begin
  if Pinned then
    Exit;
  FillChar(Info, SizeOf(Info), 0);
  if (zs_dladdr(@PinModule, Info) <> 0) and (Info.dli_fname <> nil) then
    Pinned := zs_dlopen(Info.dli_fname, RTLD_NOW_FLAG or RTLD_NODELETE_FLAG) <> nil;
end;
{$ENDIF}

{ the file this code runs from, so the log can name it }
function SelfModulePath: AnsiString;
{$IFDEF WINDOWS}
var
  H: HMODULE;
  Buf: array[0..MAX_PATH] of AnsiChar;
  n: DWORD;
begin
  Result := '';
  H := 0;
  if not PinModuleHandle(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
       @PinModule, H) or (H = 0) then
    Exit;
  n := GetModuleFileNameA(H, @Buf[0], MAX_PATH);
  if n > 0 then
    Result := Copy(StrPas(@Buf[0]), 1, n);
end;
{$ELSE}
var
  Info: TDlInfo;
begin
  Result := '';
  FillChar(Info, SizeOf(Info), 0);
  if (zs_dladdr(@PinModule, Info) <> 0) and (Info.dli_fname <> nil) then
    Result := StrPas(Info.dli_fname);
end;
{$ENDIF}

function Str(P: PChar; MaxLen: LongInt): AnsiString;
begin
  if P = nil then
    Result := ''
  else
    Result := Copy(StrPas(P), 1, MaxLen);
end;

procedure Queue(var Ev: TZSEvent);
begin
  if Engine <> nil then
    Engine.PushEvent(Ev);
end;

{ ---------------- lifecycle ---------------- }

{ where the crash log goes: the log folder, or the data folder without one }
function CrashDirOf(E: TZSEngine): AnsiString;
begin
  if E.LogDir <> '' then
    Result := E.LogDir
  else
    Result := E.DataDir;
  UniqueString(Result);
end;

function ZS_Init(ScriptDir: PChar; ApiVersion: LongInt): LongInt; cdecl;
var
  Fresh: Boolean;
  Dir: AnsiString;
begin
  Result := 0;
  Fresh := False;
  try
    if ApiVersion <> ZS_API_VERSION then
      Exit(-ZS_API_VERSION);
    PinModule;
    if Engine = nil then
    begin
      Fresh := True;
      Engine := TZSEngine.Create(Str(ScriptDir, 1024));
      Engine.LibraryPath := SelfModulePath;
      { read before the engine thread runs: loading the database holds the state lock for long }
      Dir := CrashDirOf(Engine);
      Engine.Start;
    end
    else
    begin
      { the script was loaded again while the library kept running: the new main.pas claims the
        admin token again, and the settings of the score guard are sent to it again }
      Engine.NoteScriptReloaded;
      { a settings reload on the engine thread may give the log folder a new value; the engine
        holds the state lock for one event at a time, so this waits no longer than that }
      EnterCriticalSection(Engine.StateLock);
      try
        Dir := CrashDirOf(Engine);
      finally
        LeaveCriticalSection(Engine.StateLock);
      end;
    end;
    CrashInstall(Dir, 'ZitroStats ' + ZS_VERSION_STR);
    CrashTrail('init', ApiVersion, 0);
    Result := ZS_API_VERSION;
  except
    Result := 0;
    { main.pas stays off after a failed start and never calls ZS_Shutdown: an engine this call
      created goes again, or the next ZS_Init would take it for a running one }
    if Fresh then
      try
        EnterCriticalSection(ExtLock);
        try
          FreeAndNil(Engine);
        finally
          LeaveCriticalSection(ExtLock);
        end;
      except
        Engine := nil;
      end;
  end;
end;

procedure ZS_Shutdown; cdecl;
begin
  try
    CrashTrail('shutdown', 0, 0);
    if Engine <> nil then
    begin
      Engine.Shutdown;
      EnterCriticalSection(ExtLock);
      try
        FreeAndNil(Engine);
      finally
        LeaveCriticalSection(ExtLock);
      end;
    end;
  except
  end;
end;

function ZS_Is_Ready: LongInt; cdecl;
begin
  try
    Result := Ord((Engine <> nil) and Engine.IsReady);
  except
    Result := 0;
  end;
end;

function ZS_Get_Api_Version: LongInt; cdecl;
begin
  try
    Result := ZS_API_VERSION;
  except
    Result := 0;
  end;
end;

function ZS_Claim_Token: LongInt; cdecl;
begin
  try
    if Engine <> nil then
      Result := Engine.ClaimToken
    else
      Result := 0;
  except
    Result := 0;
  end;
end;

procedure ZS_Reload_Config; cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeReloadConfig);
    Queue(Ev);
  except
  end;
end;

{ ---------------- events ---------------- }

procedure ZS_Ev_Join(Slot: LongInt; Name, Steam, Hwid, IP: PChar; Team, Human, Admin, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeJoin);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.S1 := Str(Name, 64);
    Ev.S2 := Str(Steam, 64);
    Ev.S3 := Str(Hwid, 64);
    Ev.S4 := Str(IP, 64);
    Ev.I[0] := Team;
    Ev.I[1] := Human;
    Ev.I[2] := Ord((Engine <> nil) and Engine.TokenValid(Admin));
    Queue(Ev);
    CrashTrail('join', Slot, Human);
  except
  end;
end;

procedure ZS_Ev_Leave(Slot, Kicked, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeLeave);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Kicked;
    Queue(Ev);
    CrashTrail('leave', Slot, Kicked);
  except
  end;
end;

procedure ZS_Ev_Team(Slot, Team, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeTeam);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Team;
    Queue(Ev);
    CrashTrail('team', Slot, Team);
  except
  end;
end;

procedure ZS_Ev_Steam_Auth(Slot: LongInt; Steam: PChar; State, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeSteamAuth);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.S1 := Str(Steam, 64);
    Ev.I[0] := State;
    Queue(Ev);
    CrashTrail('steam auth', Slot, State);
  except
  end;
end;

procedure ZS_Ev_Spawn(Slot, Primary, Secondary, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeSpawn);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Primary;
    Ev.I[1] := Secondary;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Kill(Killer, Victim, BulletId, Weapon, Flags, VictimWeapon, Tick: LongInt;
  KX, KY, VX, VY, BX, BY, VictimVest: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeKill);
    Ev.Tick := Tick;
    Ev.Slot := Killer;
    Ev.Slot2 := Victim;
    Ev.I[0] := BulletId;
    Ev.I[1] := Weapon;
    Ev.I[2] := Flags;
    Ev.I[3] := VictimWeapon;
    Ev.F[0] := KX;
    Ev.F[1] := KY;
    Ev.F[2] := VX;
    Ev.F[3] := VY;
    Ev.F[4] := BX;
    Ev.F[5] := BY;
    Ev.F[6] := VictimVest;
    Queue(Ev);
    CrashTrail('kill', Killer, Victim);
  except
  end;
end;

procedure ZS_Ev_Damage(Shooter, Victim, BulletId, Weapon, Flags, Tick: LongInt;
  Damage, VictimVest, BX, BY, BVX, BVY, VX, VY, VictimHealth, VictimVelX, VictimVelY, ShooterVelX,
  ShooterVelY: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeDamage);
    Ev.Tick := Tick;
    Ev.Slot := Shooter;
    Ev.Slot2 := Victim;
    Ev.I[0] := BulletId;
    Ev.I[1] := Weapon;
    Ev.I[2] := Flags;
    Ev.F[0] := Damage;
    Ev.F[1] := VictimVest;
    Ev.F[2] := BX;
    Ev.F[3] := BY;
    Ev.F[4] := BVX;
    Ev.F[5] := BVY;
    Ev.F[6] := VX;
    Ev.F[7] := VY;
    Ev.F[8] := VictimHealth;
    Ev.F[9] := VictimVelX;
    Ev.F[10] := VictimVelY;
    Ev.F[11] := ShooterVelX;
    Ev.F[12] := ShooterVelY;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Shot(Slot, Weapon, Count, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeShot);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Weapon;
    Ev.I[1] := Count;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Grenade(Slot, Count, Cluster, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeGrenade);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Count;
    Ev.I[1] := Cluster;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Knife_Throw(Slot, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeKnifeThrow);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Weapon(Slot, Primary, Secondary, PrimaryAmmo, SecondaryAmmo, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeWeapon);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Primary;
    Ev.I[1] := Secondary;
    Ev.I[2] := PrimaryAmmo;
    Ev.I[3] := SecondaryAmmo;
    { the ammunition of both weapons is known (the reload tracking uses it) }
    Ev.I[4] := 1;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Ammo(Slot, Weapon, OldAmmo, NewAmmo, Flags, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeAmmo);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Weapon;
    Ev.I[1] := OldAmmo;
    Ev.I[2] := NewAmmo;
    Ev.I[3] := Flags;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Realistic(Realistic, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeRealistic);
    Ev.Tick := Tick;
    Ev.I[0] := Realistic;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Kit(Slot, Style, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeKit);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Style;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Heal(Slot, Kits, Tick: LongInt; Regen, Kit: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeHeal);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Kits;
    Ev.F[0] := Regen;
    Ev.F[1] := Kit;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Flag(Slot, Kind, Team, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeFlag);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Kind;
    Ev.I[1] := Team;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Sample(Slot, Flags, Weapon, Ammo, Jets, Tick: LongInt; X, Y: Single); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeSample);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Flags;
    Ev.I[1] := Weapon;
    Ev.I[2] := Ammo;
    Ev.I[3] := Jets;
    Ev.F[0] := X;
    Ev.F[1] := Y;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Tick(Tick, Alpha, Bravo, Charlie, Delta, TimeLeft, GameStyle: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeTick);
    Ev.Tick := Tick;
    Ev.I[0] := Alpha;
    Ev.I[1] := Bravo;
    Ev.I[2] := Charlie;
    Ev.I[3] := Delta;
    Ev.I[4] := TimeLeft;
    Ev.I[5] := GameStyle;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Map_Before(NextMap: PChar; Alpha, Bravo, Charlie, Delta, TimeLeft, ScoreLimit, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeMapBefore);
    Ev.Tick := Tick;
    Ev.S1 := Str(NextMap, 64);
    Ev.I[0] := Alpha;
    Ev.I[1] := Bravo;
    Ev.I[2] := Charlie;
    Ev.I[3] := Delta;
    Ev.I[4] := TimeLeft;
    Ev.I[5] := ScoreLimit;
    Queue(Ev);
    CrashTrail('map end', Alpha, Bravo);
  except
  end;
end;

procedure ZS_Ev_Map_After(MapName: PChar; GameStyle, ScoreLimit, TimeLimit, Flags, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeMapAfter);
    Ev.Tick := Tick;
    Ev.S1 := Str(MapName, 64);
    Ev.I[0] := GameStyle;
    Ev.I[1] := ScoreLimit;
    Ev.I[2] := TimeLimit;
    Ev.I[3] := Flags;
    Queue(Ev);
    CrashTrail('map start', GameStyle, Flags);
  except
  end;
end;

procedure ZS_Ev_Player_Score(Slot, Kills, Deaths, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zePlayerScore);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Kills;
    Ev.I[1] := Deaths;
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Vote(Slot, Kind: LongInt; Target: PChar; Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeVote);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Kind;
    Ev.S1 := Str(Target, 64);
    Queue(Ev);
    CrashTrail('vote', Slot, Kind);
  except
  end;
end;

{ the server's maps list (the map vote); Names = every name followed by #10 }
procedure ZS_Ev_Map_List(Count, CurrentId, Reason, Tick: LongInt; Names: PChar); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeMapList);
    Ev.Tick := Tick;
    Ev.I[0] := Count;
    Ev.I[1] := CurrentId;
    Ev.I[2] := Reason;
    Ev.S1 := Str(Names, MAPLIST_TEXT_MAX);
    Queue(Ev);
    CrashTrail('map list', Count, Reason);
  except
  end;
end;

procedure ZS_Ev_Ray(RequestId, Answer, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeRay);
    Ev.Tick := Tick;
    Ev.I[0] := RequestId;
    Ev.I[1] := Answer;
    Queue(Ev);
  except
  end;
end;

{ the score guard of main.pas took something back or repaired something }
procedure ZS_Ev_Integrity(Slot, Kind, Team, Value, Extra: LongInt; Text: PChar; Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeIntegrity);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Kind;
    Ev.I[1] := Team;
    Ev.I[2] := Value;
    Ev.I[3] := Extra;
    Ev.S1 := Str(Text, 64);
    Queue(Ev);
  except
  end;
end;

procedure ZS_Ev_Move_Result(Slot, Team, MoveResult, Tick: LongInt); cdecl;
var
  Ev: TZSEvent;
begin
  try
    Ev := NewEvent(zeMoveResult);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.I[0] := Team;
    Ev.I[1] := MoveResult;
    Queue(Ev);
  except
  end;
end;

{ OnBeforeJoin: OldTeam 255 for a player who is joining the server. The answer is never -1 for
  such a player, because the server would send them away as if it were full. }
function ZS_Team_Join(Slot, Team, OldTeam, Tick: LongInt): LongInt; cdecl;
begin
  Result := Team;
  try
    if Engine <> nil then
      Result := Engine.TeamJoinAdvice(Slot, Team, OldTeam, Tick);
    if ((OldTeam < 0) or (OldTeam > TEAM_SPEC)) and ((Result < 0) or (Result > TEAM_SPEC)) then
      Result := Team;
  except
    Result := Team;
  end;
end;

function ZS_Command(Slot: LongInt; Text: PChar; Source, AdminToken, Tick: LongInt): LongInt; cdecl;
var
  S, First: AnsiString;
  Sp: LongInt;
  Ev: TZSEvent;
  AdminOk, Mine: Boolean;
begin
  Result := 0;
  try
    if (Engine = nil) or (Text = nil) then
      Exit;
    AdminOk := Engine.TokenValid(AdminToken);
    if (Source = SRC_CONSOLE) and not AdminOk then
      Exit;
    S := Trim(Str(Text, 256));
    Sp := Pos(' ', S);
    if Sp > 0 then
      First := Copy(S, 1, Sp - 1)
    else
      First := S;
    Mine := IsZitroCommandFrom(First, Source);
    { /votemap - also what F12 and the vote menu of the clients send - belongs to the map vote while
      [MapVote] Enabled and SlashVoteMap are on (the engine keeps MapVoteSlash); otherwise it is
      the server's own }
    if not Mine and (Source = SRC_COMMAND) and (Engine.MapVoteSlash <> 0) and IsVoteMapWord(First) then
      Mine := True;
    if not Mine then
    begin
      { Soldat's own admin commands stay the server's; audit.log still records who ran them }
      if AdminOk and (Source <> SRC_CHAT) and IsSoldatAdminCommand(First) then
      begin
        Ev := NewEvent(zeCommand);
        Ev.Tick := Tick;
        Ev.Slot := Slot;
        Ev.S1 := S;
        Ev.I[0] := Source;
        Ev.I[1] := 1;
        Ev.I[2] := 1;
        Queue(Ev);
      end;
      Exit;
    end;
    Ev := NewEvent(zeCommand);
    Ev.Tick := Tick;
    Ev.Slot := Slot;
    Ev.S1 := S;
    Ev.I[0] := Source;
    Ev.I[1] := Ord(AdminOk);
    Queue(Ev);
    Result := 1;
    CrashTrail('command', Slot, Source);
  except
    Result := 0;
  end;
end;

{ ---------------- output ---------------- }

function ZS_Action_Begin: LongInt; cdecl;
begin
  Result := 0;
  try
    if Engine <> nil then
      Result := Engine.BeginActions;
  except
    Result := 0;
  end;
end;

{ the action the script reads after ZS_Action_Next said 0: nothing, not the last one again }
procedure ClearAction;
begin
  try
    CurAction := NewAction(ACT_NONE, 0, 0, '');
    ActionTextBuf := '';
  except
  end;
end;

function ZS_Action_Next: LongInt; cdecl;
begin
  Result := 0;
  try
    if (Engine <> nil) and Engine.PopAction(CurAction) then
    begin
      ActionTextBuf := CurAction.Text;
      Result := CurAction.Kind;
      CrashTrail('script action', CurAction.Kind, CurAction.Slot);
    end
    else
      ClearAction;
  except
    Result := 0;
    ClearAction;
  end;
end;

function ZS_Action_Slot: LongInt; cdecl;
begin
  try
    Result := CurAction.Slot;
  except
    Result := 0;
  end;
end;

function ZS_Action_Color: LongInt; cdecl;
begin
  try
    Result := CurAction.Color;
  except
    Result := 0;
  end;
end;

{ Index 1..3 = P1..P3; 4 = F1 x 10000 (BigText scale), 5 = F2 rounded (BigText time in ticks);
  6, 7 = P4, P5. Scripts get whole numbers only, floating point results are not passed through
  the script engine. }
function ZS_Action_Int(Index: LongInt): LongInt; cdecl;
begin
  try
    case Index of
      1: Result := CurAction.P1;
      2: Result := CurAction.P2;
      3: Result := CurAction.P3;
      4: Result := Round(CurAction.F1 * 10000);
      5: Result := Round(CurAction.F2);
      6: Result := CurAction.P4;
      7: Result := CurAction.P5;
      else Result := 0;
    end;
  except
    Result := 0;
  end;
end;

{ valid until the next ZS_Action_Next: the buffer holds the text of the current action only }
function ZS_Action_Text: PChar; cdecl;
begin
  try
    Result := PChar(ActionTextBuf);
  except
    Result := PChar('');
  end;
end;

{ ---------------- developer API (compatible with 4.5) ---------------- }

function ZS_API_Get_Player_Stat(SlotID: LongInt; StatID: LongInt): Double; cdecl;
begin
  try
    if Engine <> nil then
      Result := Engine.ApiPlayerStat(SlotID, StatID)
    else
      Result := 0;
  except
    Result := 0;
  end;
end;

function ZS_API_Get_Player_Name(SlotID: LongInt): PChar; cdecl;
begin
  try
    if Engine <> nil then
      ApiTextBuf := Engine.ApiPlayerName(SlotID)
    else
      ApiTextBuf := '';
  except
    ApiTextBuf := '';
  end;
  Result := PChar(ApiTextBuf);
end;

function ZS_API_Get_Player_Rank(SlotID: LongInt): LongInt; cdecl;
begin
  try
    if Engine <> nil then
      Result := Engine.ApiPlayerRank(SlotID)
    else
      Result := 0;
  except
    Result := 0;
  end;
end;

function ZS_API_Get_Profile_Stat(ProfileID: LongInt; StatID: LongInt): Double; cdecl;
begin
  try
    if Engine <> nil then
      Result := Engine.ApiProfileStat(ProfileID, StatID)
    else
      Result := 0;
  except
    Result := 0;
  end;
end;

function ZS_API_Get_Profile_Count: LongInt; cdecl;
begin
  try
    if Engine <> nil then
      Result := Engine.ApiProfileCount
    else
      Result := 0;
  except
    Result := 0;
  end;
end;

function ZS_API_Get_Top_Player(Rank: LongInt): PChar; cdecl;
begin
  try
    if Engine <> nil then
      ApiTextBuf := Engine.ApiTopPlayer(Rank)
    else
      ApiTextBuf := '';
  except
    ApiTextBuf := '';
  end;
  Result := PChar(ApiTextBuf);
end;

{ For another library of the server, on a thread of its own - never the game thread, it waits
  for the statistics: the account at a position of the ranking (!top) as name, tab, SteamID,
  copied into Buf of Size bytes with the closing zero. The result is the length; 0 = nobody,
  and Buf is then an empty string. }
function ZS_API_Top_Player_Copy(Rank: LongInt; Buf: PChar; Size: LongInt): LongInt; cdecl;
var
  S: AnsiString;
begin
  Result := 0;
  try
    if (Buf = nil) or (Size < 1) then
      Exit;
    Buf[0] := #0;
    if Size < 2 then
      Exit;
    S := '';
    EnterCriticalSection(ExtLock);
    try
      if Engine <> nil then
        S := Engine.ApiTopPlayerWait(Rank);
    finally
      LeaveCriticalSection(ExtLock);
    end;
    if Length(S) >= Size then
      SetLength(S, Size - 1);
    if S <> '' then
      Move(S[1], Buf^, Length(S));
    Buf[Length(S)] := #0;
    Result := Length(S);
  except
    Result := 0;
  end;
end;

function ZS_API_Get_Server_Peak: LongInt; cdecl;
begin
  try
    if Engine <> nil then
      Result := Engine.ApiServerPeak
    else
      Result := 0;
  except
    Result := 0;
  end;
end;

function ZS_API_Get_Player_HUD(SlotID: LongInt): LongInt; cdecl;
begin
  try
    Result := Ord((Engine <> nil) and Engine.ApiPlayerHud(SlotID));
  except
    Result := 0;
  end;
end;

exports
  ZS_Init,
  ZS_Shutdown,
  ZS_Is_Ready,
  ZS_Get_Api_Version,
  ZS_Reload_Config,
  ZS_Claim_Token,
  ZS_Ev_Join,
  ZS_Ev_Leave,
  ZS_Ev_Team,
  ZS_Ev_Steam_Auth,
  ZS_Ev_Spawn,
  ZS_Ev_Kill,
  ZS_Ev_Damage,
  ZS_Ev_Shot,
  ZS_Ev_Grenade,
  ZS_Ev_Knife_Throw,
  ZS_Ev_Weapon,
  ZS_Ev_Ammo,
  ZS_Ev_Realistic,
  ZS_Ev_Kit,
  ZS_Ev_Heal,
  ZS_Ev_Flag,
  ZS_Ev_Sample,
  ZS_Ev_Tick,
  ZS_Ev_Map_Before,
  ZS_Ev_Map_After,
  ZS_Ev_Player_Score,
  ZS_Ev_Vote,
  ZS_Ev_Map_List,
  ZS_Ev_Ray,
  ZS_Ev_Move_Result,
  ZS_Ev_Integrity,
  ZS_Team_Join,
  ZS_Command,
  ZS_Action_Begin,
  ZS_Action_Next,
  ZS_Action_Slot,
  ZS_Action_Color,
  ZS_Action_Int,
  ZS_Action_Text,
  ZS_API_Get_Player_Stat,
  ZS_API_Get_Player_Name,
  ZS_API_Get_Player_Rank,
  ZS_API_Get_Profile_Stat,
  ZS_API_Get_Profile_Count,
  ZS_API_Get_Top_Player,
  ZS_API_Top_Player_Copy,
  ZS_API_Get_Server_Peak,
  ZS_API_Get_Player_HUD;

begin
  InitCriticalSection(ExtLock);
end.
