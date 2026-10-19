unit ZitroStats_Core;

{ ZitroStats 5 - bridge between ScriptCore 3 and zitrostats_dll.

  The library keeps the statistics, accounts, rankings and files, and does all of that work in
  its own threads. The handlers below only hand game data over and print what the library asks
  for, so the game thread is never held up by disk, network or password hashing.

  The map vote ([MapVote] in settings.ini) runs in the library as well: the script sends it the
  maps list, turns the vote menu, /votemap and F12 into its requests and votes, shows a vote to
  the clients as Soldat's own vote (with a vote percent of 200, which never passes, put back
  afterwards) and changes the map when the library says so.

  The bridges ([Bridges] in settings.ini, 5.6): the library reads the soldiers and the bullets from
  the server's memory and sees every bullet the server makes (a hook in its code). Then the tick
  asks the properties only of the players the library cannot read (ZS_Frame), and a hit or a kill
  sends only the ids (ZS_Ev_Hit, ZS_Ev_Death). Whatever the library cannot read, the script reads
  as before; once a second one player's properties are compared with the memory, and a difference
  switches the reading off for good.

  The library is loaded from this script folder. If the folder is renamed, replace
  "scripts/ZitroStats-Core/" in the declarations below (the path must not contain spaces). The
  calls added since API 16 are declared "delayload": a library of an older release still loads
  with the script and ZS_Init says that the two do not belong together; they are called only
  after ZS_Init accepted the API. }

interface

function ZS_Init(ScriptDir: PChar; ApiVersion: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Init@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Init@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Claim_Token(): Integer;
external {$IFDEF WIN32} 'ZS_Claim_Token@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Claim_Token@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Shutdown();
external {$IFDEF WIN32} 'ZS_Shutdown@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Shutdown@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Join(Slot: Integer; Name, Steam, Hwid, IP: PChar; Team, Human, AdminToken, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Join@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Join@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Leave(Slot, Kicked, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Leave@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Leave@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Team(Slot, Team, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Team@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Team@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Steam_Auth(Slot: Integer; Steam: PChar; State, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Steam_Auth@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Steam_Auth@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

{ the server's admin rights of a human changed (API 17): the admin token, or 0 }
procedure ZS_Ev_Admin(Slot, IsAdmin: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Admin@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Ev_Admin@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};

procedure ZS_Ev_Spawn(Slot, Primary, Secondary, Tick: Integer; X, Y: Single);
external {$IFDEF WIN32} 'ZS_Ev_Spawn@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Spawn@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Kill(Killer, Victim, BulletId, Weapon, Flags, VictimWeapon, Tick: Integer; KX, KY, VX, VY, BX, BY, VictimVest: Single);
external {$IFDEF WIN32} 'ZS_Ev_Kill@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Kill@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Damage(Shooter, Victim, BulletId, Weapon, Flags, Tick: Integer; Damage, VictimVest, BX, BY, BVX, BVY, VX, VY, VictimHealth, VictimVelX, VictimVelY, ShooterVelX, ShooterVelY: Single);
external {$IFDEF WIN32} 'ZS_Ev_Damage@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Damage@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Grenade(Slot, Count, Cluster, Tick: Integer; X, Y: Single);
external {$IFDEF WIN32} 'ZS_Ev_Grenade@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Grenade@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Knife_Throw(Slot, Tick: Integer; X, Y: Single);
external {$IFDEF WIN32} 'ZS_Ev_Knife_Throw@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Knife_Throw@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Weapon(Slot, Primary, Secondary, PrimaryAmmo, SecondaryAmmo, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Weapon@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Weapon@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Ammo(Slot, Weapon, OldAmmo, NewAmmo, Flags, Tick: Integer; X, Y: Single);
external {$IFDEF WIN32} 'ZS_Ev_Ammo@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Ammo@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Realistic(Realistic, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Realistic@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Realistic@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

{ 1 = the library read the health and counted what the kit gave ([Bridges]) }
function ZS_Ev_Kit(Slot, Style, Tick: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Ev_Kit@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Kit@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Heal(Slot, Kits, Tick: Integer; Regen, Kit: Single);
external {$IFDEF WIN32} 'ZS_Ev_Heal@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Heal@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Flag(Slot, Kind, Team, Tick: Integer; X, Y: Single);
external {$IFDEF WIN32} 'ZS_Ev_Flag@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Flag@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Sample(Slot, Flags, Weapon, Ammo, Jets, Tick: Integer; X, Y: Single);
external {$IFDEF WIN32} 'ZS_Ev_Sample@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Sample@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Tick(Tick, Alpha, Bravo, Charlie, Delta, TimeLeft, GameStyle, Paused: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Tick@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Tick@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Map_Before(NextMap: PChar; Alpha, Bravo, Charlie, Delta, TimeLeft, ScoreLimit, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Map_Before@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Map_Before@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Map_After(MapName: PChar; GameStyle, ScoreLimit, TimeLimit, Flags, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Map_After@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Map_After@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Player_Score(Slot, Kills, Deaths, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Player_Score@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Player_Score@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Vote(Slot, Kind: Integer; Target: PChar; Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Vote@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Vote@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Map_List(Count, CurrentId, Reason, Tick: Integer; Names: PChar);
external {$IFDEF WIN32} 'ZS_Ev_Map_List@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Map_List@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Ray(RequestId, Answer, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Ray@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Ray@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Integrity(Slot, Kind, Team, Value, Extra: Integer; Text: PChar; Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Integrity@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Integrity@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

procedure ZS_Ev_Move_Result(Slot, Team, MoveResult, Tick: Integer);
external {$IFDEF WIN32} 'ZS_Ev_Move_Result@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Ev_Move_Result@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Team_Join(Slot, Team, OldTeam, Tick: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Team_Join@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Team_Join@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Command(Slot: Integer; Text: PChar; Source, AdminToken, Tick: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Command@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Command@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Action_Begin(): Integer;
external {$IFDEF WIN32} 'ZS_Action_Begin@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Action_Begin@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Action_Next(): Integer;
external {$IFDEF WIN32} 'ZS_Action_Next@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Action_Next@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Action_Slot(): Integer;
external {$IFDEF WIN32} 'ZS_Action_Slot@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Action_Slot@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Action_Color(): Integer;
external {$IFDEF WIN32} 'ZS_Action_Color@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Action_Color@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Action_Int(Index: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Action_Int@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Action_Int@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Action_Text(): PChar;
external {$IFDEF WIN32} 'ZS_Action_Text@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Action_Text@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

{ [Bridges]: the first call of every tick; the answer has a bit for every human the library reads
  from the server's memory itself (bit = slot - 1) }
function ZS_Frame(Tick: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Frame@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Frame@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};
{ the soldier of a slot in the server's memory: the player object and where it stands; 1 = found }
function ZS_Bind(Slot: Integer; P: TActivePlayer; X, Y: Single): Integer;
external {$IFDEF WIN32} 'ZS_Bind@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Bind@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};
{ one player's properties against the memory: 1 = the same, 0 = a difference (the reading is off) }
function ZS_Check(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys: Integer; X, Y, Health, Vest: Single): Integer;
external {$IFDEF WIN32} 'ZS_Check@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Check@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};
{ what runs: BR_* bits }
function ZS_Bridges(): Integer;
external {$IFDEF WIN32} 'ZS_Bridges@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Bridges@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};
{ a hit and a kill with the ids only: 1 = the library read the rest, 0 = send the full event }
function ZS_Ev_Hit(Shooter, Victim, BulletId, Tick: Integer; Damage: Single): Integer;
external {$IFDEF WIN32} 'ZS_Ev_Hit@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Ev_Hit@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};
function ZS_Ev_Death(Killer, Victim, BulletId, Flags, Tick: Integer): Integer;
external {$IFDEF WIN32} 'ZS_Ev_Death@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload' {$ELSE} 'ZS_Ev_Death@scripts/ZitroStats-Core/zitrostats_dll.so cdecl delayload' {$ENDIF};

const
  ZS_API_VERSION = 17;

  { what ZS_Bridges answers }
  BR_HOOK = 1;       { the hook in CreateBullet: shots, grenades and thrown knives come from the server }
  BR_MEMORY = 2;     { the soldiers are read from the server's memory }
  BR_HITHOOK = 4;    { the hook in HealthHit: the part of the body every hit landed on }
  BR_MAPWALLS = 8;   { the library has the walls of the map: a kill needs no Map.RayCast }

  { command sources }
  SRC_CHAT = 0;
  SRC_COMMAND = 1;
  SRC_CONSOLE = 2;
  { the handler a player's command came through (an admin's comes through both) }
  CMD_VIA_COMMAND = 1;
  CMD_VIA_ADMIN = 2;

  { output requested by the library }
  ACT_CONSOLE = 1;
  ACT_BROADCAST = 2;
  ACT_BIGTEXT = 3;
  ACT_WRITELN = 4;
  ACT_SETTEAM = 5;
  ACT_KICK = 6;
  ACT_RAYCAST = 7;
  ACT_MOVE = 8;
  ACT_INTEGRITY = 9;
  { the map vote of the library: Soldat's own vote shows it (Text = the map), the vote is over (Int 1
    = the percent to put back when the old one is not known), the map changes (Text; Int 1 = 1: it is
    the next map of the list), and its settings (Int 1 = MV_* flags, Int 2 = RestoreVotePercent) }
  ACT_VOTE_START = 10;
  ACT_VOTE_END = 11;
  ACT_MAP_CHANGE = 12;
  ACT_MAPVOTE = 13;
  MV_ENABLED = 1;

  { why the maps list goes to the library (ZS_Ev_Map_List) }
  MAPLIST_START = 1;
  MAPLIST_MAPCHANGE = 2;
  MAPLIST_ADMIN = 3;
  MAPLIST_CHANGED = 4;
  { once a second the list is compared with what the library has: the count, the current entry and
    this many names, so a list of 200 maps is looked at whole every 10 seconds }
  MAPLIST_CHECK_NAMES = 20;
  { Soldat's own vote, which shows the vote of the library to the clients, runs 20 seconds (and
    one more to be sure); a vote percent of 200 is one no vote reaches }
  SOLDAT_VOTE_TICKS = 1260;
  VOTE_PERCENT_NEVER = 200;

  { ACT_MOVE: Int 2 flags, and the answers of ZS_Ev_Move_Result }
  MOVE_DEAD_ONLY = 1;
  MOVE_DONE = 1;
  MOVE_ALIVE = 2;
  MOVE_FLAGGER = 3;
  MOVE_REFUSED = 4;
  MOVE_ALREADY = 5;
  NEW_PLAYER_TEAM = 255;

  { ACT_INTEGRITY: what the score guard watches (Int 1) and how many opponents it needs (Int 2) }
  IG_ENABLED = 1;
  IG_JOINSCORE = 2;
  IG_DOUBLECAP = 4;
  IG_SOLO = 8;
  IG_RESPAWN = 16;
  IG_MAPCHANGE = 32;
  IG_ANNOUNCE = 64;

  { what ZS_Ev_Integrity reports }
  IGE_JOINSCORE = 1;
  IGE_DOUBLECAP = 2;
  IGE_SOLO = 3;
  IGE_RESPAWN = 4;
  IGE_PAUSE = 5;
  IGE_MAPCHANGE = 6;

  { answers to ACT_RAYCAST }
  RAY_BLOCKED = 0;
  RAY_CLEAR = 1;
  RAY_UNKNOWN = -1;

  { player state bits: A = killer / shooter / sampled player, B = victim }
  EF_A_FLAGGER = 1;
  EF_B_FLAGGER = 2;
  EF_A_PRONE = 4;
  EF_A_ONGROUND = 8;
  EF_A_ALIVE = 16;
  EF_BULLET = 32;
  EF_B_PRONE = 64;
  EF_B_ONGROUND = 128;
  EF_A_CROUCH = 256;
  EF_B_CROUCH = 512;
  EF_LOS = 4096;
  EF_RAY_RAW = 8192;
  EF_RAY_CAL = 16384;
  { the server killed the player itself: a survival round ended, somebody joined a team or the
    server refused a respawn }
  EF_SERVER_KILL = 32768;

  FLAG_SCORE = 0;
  FLAG_RETURN = 1;
  FLAG_GRAB = 2;
  FLAG_DROP = 3;
  FLAG_THROWN = 4;
  FLAG_BASE = 5;

  MF_SURVIVAL = 1;
  MF_REALISTIC = 2;
  MF_ADVANCE = 4;
  MF_FRIENDLYFIRE = 8;
  { the map already runs: sent only from the script's start (a /recompile in the middle of a map) }
  MF_RUNNING = 16;

  VOTE_MAP = 1;
  VOTE_KICK = 2;
  { a vote cast for the map vote that runs (the vote menu, /votemap) }
  VOTE_MAP_CAST = 3;

  TEAM_ALPHA = 1;
  TEAM_BRAVO = 2;
  TEAM_DELTA = 4;
  TEAM_SPECTATOR = 5;
  GS_TM = 2;
  GS_CTF = 3;
  GS_INF = 5;
  GS_HTF = 6;
  { the server hits a player with 4000 when it kills them itself, and a vest turns that hit into
    exactly 1000; the heaviest hits of players and admins (/brutalkill 3423, pkill 3430) stay
    below SERVER_HIT_DAMAGE and are never 1000 }
  SERVER_HIT_DAMAGE = 3900;
  SERVER_HIT_VEST = 1000;
  { such a hit is the server's own only at the end of a survival round (no bullet: id 255) or in the
    tick a player asked to enter a team (OnBeforeJoin); the same hit from a script's Player.Damage
    (Basic-Extended kills that way) is a real death }
  SERVER_HIT_BULLET = 255;
  { a map change that was announced and never happened: a pause threw it away }
  MAPCHANGE_LOST_TICKS = 420;
  CLR_GUARD = $FFCC44;
  FLAG_REPORT_TICKS = 300;   { flag bases are reported every 5 seconds }
  MAP_SETTLE_TICKS = 180;    { and not before 3 seconds after a map change }
  WEP_KNIFE = 11;
  WEP_NONE = 255;
  { kits that fill the health up before OnKitPickup runs }
  KIT_MEDICAL = 16;
  KIT_PREDATOR = 19;
  KIT_BERSERK = 21;
  { the health a player spawns with, and what kits and the healing fields fill up to }
  DEFAULT_HEALTH = 150;
  REALISTIC_HEALTH = 65;
  WEP_WORLD = -1;          { damage that is not a bullet of the shooter: fall, lava, a script }
  BS_THROWNKNIFE = 13;
  MAX_BULLET_ID = 254;
  TICKS_PER_SECOND = 60;
  SAMPLE_INTERVAL = 12;    { each player's position is sampled 5 times per second }
  ACTIONS_PER_TICK = 50;
  THROW_CONFIRM_TICKS = 3;
  SCRIPT_ERRORS_SHOWN = 20;
  ANNOUNCE_MAX = 8;
  ANNOUNCES_PER_TICK = 2;    { lines to everybody per tick, like the library's broadcasts }
  PAUSE_NOTE = '[ZitroStats] The map is changing: /pause would cancel it. Try again in a moment.';
  { the library did not start: the commands of the accounts (the library's identity commands and
    /zs_setpass) are still taken, so that a password never reaches the server's log }
  DOWN_COMMANDS = ' register login changepass setemail verifyemail forgotpass resetpass account removemypass zs_setpass ';
  DOWN_NOTE = '[ZitroStats] The statistics are off on this server now: the account commands do not work.';

var
  Started: Boolean;
  ClockTicks: Integer;
  { admin token from the library: admin commands count only with it }
  Token: Integer;
  { the admin rights of each human as the library heard them last (1/0); a change goes once a second }
  AdminSent: array[1..32] of Integer;
  { weapon, ammo and grenades seen on the previous tick; LastWeapon -1 = not tracked yet }
  LastWeapon: array[1..32] of Integer;
  LastAmmo: array[1..32] of Integer;
  LastNades: array[1..32] of Integer;
  { the health of the previous tick (-1 = not tracked) and the healing collected since the last
    report: what regenerating polygons gave (OnDamage says -2 for each of their heals) and what
    medical, berserker and predator kits filled up, with the number of those kits }
  LastHealth: array[1..32] of Single;
  HealRegen: array[1..32] of Single;
  HealKit: array[1..32] of Single;
  HealKits: array[1..32] of Integer;
  { realistic mode as the library last heard it (1/0), -1 = not said yet }
  LastRealistic: Integer;
  { commands of admins arrive through OnCommand and then OnAdminCommand: the copy in the other
    handler (same tick, same text by its hash) gets the answer of the first }
  CmdTick: array[1..32] of Integer;
  CmdHash: array[1..32] of Integer;
  CmdVia: array[1..32] of Integer;
  CmdHandled: array[1..32] of Boolean;
  { a knife left the hand of a living player: it counts as a throw once a thrown knife flies }
  ThrowWaiting: array[1..32] of Boolean;
  ThrowTick: array[1..32] of Integer;
  ThrowX: array[1..32] of Single;
  ThrowY: array[1..32] of Single;
  ThrowsWaiting: Integer;
  ScriptErrors: Integer;
  { which answer of Map.RayCast means a clear line, settled by CalibrateRayCast }
  RayClearIsTrue: Boolean;
  RayCalibrated: Boolean;
  MapChangeTick: Integer;
  { a team change the library asked for: OnBeforeJoin lets exactly this one through }
  MoveTeam: array[1..32] of Integer;
  { an admin's /setteam, allowed in the tick it was typed }
  AdminTeam: array[1..32] of Integer;
  AdminTeamTick: array[1..32] of Integer;
  { ---- the score guard ---- }
  { the settings the library sent (ACT_INTEGRITY) }
  IgFlags: Integer;
  IgMinOpp: Integer;
  { the team scores as they were at the start of this tick, plus what happened since for a reason
    the guard accepts }
  ScoreOk: array[1..4] of Integer;
  { a player put back on their feet after a map change takes no damage and changes no team }
  Resurrect: array[1..32] of Boolean;
  { the tick the server killed a player itself }
  ServerKillTick: array[1..32] of Integer;
  { the tick a player last asked to enter a team (OnBeforeJoin, bots too): survival kills him then }
  JoinTick: array[1..32] of Integer;
  { the tick of a player's last respawn: a selfkill in that tick is the server refusing it }
  RespawnTick: array[1..32] of Integer;
  { the last tick a player died for real; survival gives the round away only then }
  LastRealDeath: Integer;
  { a map change the server announced but has not carried out yet }
  MapPendActive: Boolean;
  MapPendTick: Integer;
  MapPendName: string;
  { the library hears about the map change one tick later, so a voided capture can cancel it }
  MapBeforeWaiting: Boolean;
  { the guard never works inside itself: setting a score or moving a player calls handlers again }
  GuardBusy: Boolean;
  { a move or a resurrect is running: the flags of it are cleared at the next tick in any case }
  ResurrectBusy: Boolean;
  { Soldat 2.8.2 places a joining player at a spawn point of the team they asked for before it
    asks OnBeforeJoin; another team there changes only the colour. Such a player is put at the
    base of the team they were given on the next tick (0 = nothing to do). }
  JoinFixTeam: array[1..32] of Integer;
  JoinFixTick: array[1..32] of Integer;
  JoinFixes: Integer;
  { what a command or an event handler wants to say is written on the next tick: a write to a
    player inside such a handler can hold up the whole server }
  PauseNote: array[1..32] of Boolean;
  PauseNotes: Integer;
  { the library did not start: who used an account command hears it on the next tick }
  DownNote: array[1..32] of Boolean;
  DownNotes: Integer;
  AnnounceText: array[1..8] of string;
  Announces: Integer;
  { the humans, noted when they join, so the tick loop does not ask every slot: by slot, as a list
    and as bits (bit = slot - 1); a loop of ScriptCore costs about a microsecond a turn }
  HumanSlot: array[1..32] of Boolean;
  HumanList: array[1..32] of Integer;
  HumanCount: Integer;
  HumanMask: Integer;
  { the humans the library followed in the last tick (ZS_Frame) }
  FollowMask: Integer;
  { the teams that can score in the game style that runs: the score guard reads only theirs (a
    score costs two property reads) }
  ScoreTeams: Integer;
  { the guard was off: it notes the scores before it watches them again }
  GuardWasOff: Boolean;
  { [Bridges]: the slot's soldier was found in the server's memory (ZS_Bind; the record of a slot
    never moves), what ZS_Bridges said last, and where the once-a-second look goes on }
  Bound: array[1..32] of Boolean;
  BridgeBits: Integer;
  BindSlot: Integer;
  CheckSlot: Integer;
  { OnJoin has been seen for the slot (humans and bots) }
  InGame: array[1..32] of Boolean;
  { Map.RayCast is calibrated at most once per map }
  RayTried: Boolean;
  { ---- the map vote of the library ---- }
  { its settings (ACT_MAPVOTE): MV_* flags and [MapVote] RestoreVotePercent }
  MvFlags: Integer;
  MvFallback: Integer;
  MvConfigSeen: Boolean;
  { a vote of the library shows as Soldat's own vote, with a vote percent of 200 }
  MvActive: Boolean;
  { the vote percent before that, -1 = not known; it goes back once Soldat's own vote is over }
  MvSavedPercent: Integer;
  MvRestoreWanted: Boolean;
  MvSoldatUntil: Integer;
  { the tick a passed vote changed the map: the score guard never cancels that change }
  MvChangeTick: Integer;
  { the maps list as the library has it, and where the check once a second goes on }
  ListNames: array of string;
  ListCount: Integer;
  ListCurrent: Integer;
  ListCheckPos: Integer;
  { an admin changed the list (/addmap, /delmap, /loadlist): it is sent at this tick, 0 = no }
  ListResendTick: Integer;

implementation

function BoolInt(Value: Boolean): Integer;
begin
  if Value then
    Result := 1
  else
    Result := 0;
end;

function AdminToken(IsAdmin: Boolean): Integer;
begin
  if IsAdmin then
    Result := Token
  else
    Result := 0;
end;

function SteamIdOf(Player: TActivePlayer): string;
begin
  Result := Player.SteamIDString;
  if (Result = 'S0') or (Result = '0') then
    Result := '';
end;

function PoseFlags(Player: TActivePlayer; FlaggerBit, ProneBit, GroundBit, CrouchBit: Integer): Integer;
begin
  Result := 0;
  if Player.Flagger then
    Result := Result or FlaggerBit;
  if Player.IsProne then
    Result := Result or ProneBit;
  if Player.OnGround then
    Result := Result or GroundBit;
  if Player.KeyCrouch then
    Result := Result or CrouchBit;
end;

function ModeFlags(): Integer;
begin
  Result := 0;
  if Game.Survival then
    Result := Result or MF_SURVIVAL;
  if Game.Realistic then
    Result := Result or MF_REALISTIC;
  if Game.Advance then
    Result := Result or MF_ADVANCE;
  if Game.FriendlyFire then
    Result := Result or MF_FRIENDLYFIRE;
end;

{ the health the server fills up to: realistic mode starts the players with less }
function FullHealth(): Single;
begin
  if Game.Realistic then
    Result := REALISTIC_HEALTH
  else
    Result := DEFAULT_HEALTH;
end;

{ Weapon that fired the bullet, or WEP_WORLD when the damage did not come from a bullet of this
  player (fall, lava, /kill, a script calling Damage). Valid is True while the bullet is still
  in flight, so its position and velocity describe the hit. }
function BulletWeapon(BulletId: Byte; Owner: TActivePlayer; var Valid: Boolean): Integer;
var
  B: TActiveMapBullet;
begin
  Valid := False;
  Result := WEP_WORLD;
  if (BulletId < 1) or (BulletId > MAX_BULLET_ID) then
    Exit;
  B := Map.Bullets[BulletId];
  if B.Owner <> Owner.ID then
    Exit;
  Result := B.GetOwnerWeaponId;
  Valid := B.Active;
end;

{ the list and the bits of the humans, after a join or a leave }
procedure NoteHumans();
var
  i: Integer;
begin
  HumanCount := 0;
  HumanMask := 0;
  for i := 1 to 32 do
    if HumanSlot[i] then
    begin
      HumanCount := HumanCount + 1;
      HumanList[HumanCount] := i;
      HumanMask := HumanMask or (1 shl (i - 1));
    end;
end;

{ the teams that score: none in Deathmatch, Pointmatch and Rambomatch, Alpha and Bravo in the flag
  games, all four in Teammatch }
procedure NoteStyle(Style: Integer);
begin
  if Style = GS_TM then
    ScoreTeams := TEAM_DELTA
  else if (Style = GS_CTF) or (Style = GS_INF) or (Style = GS_HTF) then
    ScoreTeams := TEAM_BRAVO
  else
    ScoreTeams := 0;
end;

procedure SendJoin(Player: TActivePlayer);
var
  ID: Integer;
  IsHuman, Admin: Boolean;
  PName, PSteam, PHwid, PIp: string;
begin
  ID := Player.ID;
  IsHuman := Player.Human;
  PName := Player.Name;
  { a bot has no identity: its HWID and IP are empty and its SteamIDString is the server's own }
  PSteam := '';
  PHwid := '';
  PIp := '';
  if IsHuman then
  begin
    PSteam := SteamIdOf(Player);
    PHwid := Player.HWID;
    PIp := Player.IP;
  end;
  LastWeapon[ID] := -1;
  CmdTick[ID] := -1;
  ThrowWaiting[ID] := False;
  HumanSlot[ID] := IsHuman;
  InGame[ID] := True;
  NoteHumans();
  { the join tells the library the admin rights; CheckAdmins sends a later change }
  Admin := Player.IsAdmin;
  AdminSent[ID] := BoolInt(Admin);
  ZS_Ev_Join(ID, PChar(PName), PChar(PSteam), PChar(PHwid), PChar(PIp), Player.Team,
    BoolInt(IsHuman), AdminToken(Admin), Game.TickCount);
  { the bots too: the library watches their lives }
  if not Bound[ID] then
    if ZS_Bind(ID, Player, Player.X, Player.Y) = 1 then
      Bound[ID] := True;
end;

{ Extra: MF_RUNNING from the script's start, 0 at a map change }
procedure SendMapAfter(MapName: string; Extra: Integer);
var
  S: string;
begin
  S := MapName;
  LastRealistic := BoolInt(Game.Realistic);
  ZS_Ev_Map_After(PChar(S), Game.GameStyle, Game.ScoreLimit, Game.TimeLimit, ModeFlags() or Extra, Game.TickCount);
end;

{ Realistic mode can be switched by a command or by another script while a map runs: the library
  then reads the other weapons file, whose reload times differ. Once a second, one read. }
procedure CheckRealistic(Tick: Integer);
var
  R: Integer;
begin
  R := BoolInt(Game.Realistic);
  if R = LastRealistic then
    Exit;
  LastRealistic := R;
  ZS_Ev_Realistic(R, Tick);
end;

{ Where the flags stand in their bases. ScriptCore reports a new map only after a moment, so this
  starts a few seconds after the map change and repeats, which also notices a moved base. }
procedure ReportFlagBases(Tick: Integer);
begin
  if (Game.GameStyle <> GS_CTF) and (Game.GameStyle <> GS_INF) then
    Exit;
  if Map.RedFlag <> nil then
    if Map.RedFlag.InBase then
      ZS_Ev_Flag(0, FLAG_BASE, TEAM_ALPHA, Tick, Map.RedFlag.X, Map.RedFlag.Y);
  if Map.BlueFlag <> nil then
    if Map.BlueFlag.InBase then
      ZS_Ev_Flag(0, FLAG_BASE, TEAM_BRAVO, Tick, Map.BlueFlag.X, Map.BlueFlag.Y);
end;

procedure SendSample(Player: TActivePlayer; Weapon, Ammo, Tick: Integer);
var
  Flags: Integer;
begin
  Flags := PoseFlags(Player, EF_A_FLAGGER, EF_A_PRONE, EF_A_ONGROUND, EF_A_CROUCH) or EF_A_ALIVE;
  ZS_Ev_Sample(Player.ID, Flags, Weapon, Ammo, Player.Jets, Tick, Player.X, Player.Y);
end;

{ the healing collected for a player goes to the library once a second, and when the player leaves }
procedure SendHeal(ID, Tick: Integer);
begin
  if (HealRegen[ID] > 0) or (HealKit[ID] > 0) then
    ZS_Ev_Heal(ID, HealKits[ID], Tick, HealRegen[ID], HealKit[ID]);
  HealRegen[ID] := 0;
  HealKit[ID] := 0;
  HealKits[ID] := 0;
end;

{ Shots, reloads and grenades are read from the ammunition, together with the position the player
  had at that moment. The library uses it for the kill distance, so boosting towards the victim
  after firing does not make a kill look longer. A change of the ammunition goes to the library
  as it is: a drop is shots or the start of a reload, a rise the end of one. The reload key is
  only asked for in the tick a magazine runs empty, to tell a reload from the last shot. }
procedure TrackPlayer(Player: TActivePlayer; Tick: Integer);
var
  ID, Weapon, Ammo, Nades, Flags: Integer;
  W: TPlayerWeapon;
begin
  ID := Player.ID;
  { every read here runs 60 times a second for every player; ScriptCore evaluates both sides of
    "or", so the second question is only asked when the first one lets the player through }
  if Player.Team = TEAM_SPECTATOR then
  begin
    LastWeapon[ID] := -1;
    LastHealth[ID] := -1;
    Exit;
  end;
  if not Player.Alive then
  begin
    LastWeapon[ID] := -1;
    LastHealth[ID] := -1;
    Exit;
  end;
  LastHealth[ID] := Player.Health;
  W := Player.Primary;
  Weapon := W.WType;
  Ammo := W.Ammo;
  Nades := Player.Grenades;
  if LastWeapon[ID] >= 0 then
  begin
    if (Weapon = LastWeapon[ID]) and (Ammo <> LastAmmo[ID]) and (Weapon <> WEP_KNIFE) and (Weapon <> WEP_NONE) then
    begin
      Flags := 0;
      if Ammo = 0 then
        if Player.KeyReload then
          Flags := 1;
      ZS_Ev_Ammo(ID, Weapon, LastAmmo[ID], Ammo, Flags, Tick, Player.X, Player.Y);
    end;
    if Nades < LastNades[ID] then
      ZS_Ev_Grenade(ID, LastNades[ID] - Nades, 0, Tick, Player.X, Player.Y);
  end;
  LastWeapon[ID] := Weapon;
  LastAmmo[ID] := Ammo;
  LastNades[ID] := Nades;
  if (ClockTicks + ID) mod SAMPLE_INTERVAL = 0 then
    SendSample(Player, Weapon, Ammo, Tick);
end;

{ A knife that leaves the hand is a throw only when a thrown knife of the player appears within
  a few ticks; a knife lost on death or taken away by a script is not. }
procedure ConfirmThrows(Tick: Integer);
var
  i, b, o: Integer;
  Bul: TActiveMapBullet;
begin
  { one look at the bullets for everybody who waits: a thrown knife in flight confirms its owner;
    each bullet is fetched once, not once per question }
  for b := 1 to MAX_BULLET_ID do
  begin
    Bul := Map.Bullets[b];
    if Bul.Active then
      if Bul.Style = BS_THROWNKNIFE then
      begin
        o := Bul.Owner;
        if (o >= 1) and (o <= 32) then
          if ThrowWaiting[o] then
          begin
            ZS_Ev_Knife_Throw(o, ThrowTick[o], ThrowX[o], ThrowY[o]);
            ThrowWaiting[o] := False;
          end;
      end;
  end;
  ThrowsWaiting := 0;
  for i := 1 to 32 do
    if ThrowWaiting[i] then
    begin
      if Tick - ThrowTick[i] >= THROW_CONFIRM_TICKS then
        ThrowWaiting[i] := False
      else
        ThrowsWaiting := ThrowsWaiting + 1;
    end;
end;

{ Map.RayCast tells whether a line is clear, but the wiki does not say which way round the answer
  goes. Two probes settle it: a ray of zero length where a living player stands can never hit
  anything, a ray across the whole map always does. The long ray looks at the whole map, so it
  is tried once per map at most. }
procedure CalibrateRayCast(X, Y: Single);
var
  Free, Blocked: Boolean;
begin
  RayTried := True;
  Free := Map.RayCast(X, Y, X, Y, False, False, True, False, 0);
  Blocked := Map.RayCast(-30000, -30000, 30000, 30000, False, False, True, False, 0);
  if Free <> Blocked then
  begin
    RayClearIsTrue := Free;
    RayCalibrated := True;
  end;
end;

{ Could the killer still see the victim when the victim died (Cover (live))? Map.RayCast answers
  with the real map geometry; the library uses it when it has no walls of the map itself
  (BR_MAPWALLS). The first kill of a map calibrates it. }
function RayFlags(Killer, Victim: TActivePlayer; KillerAlive: Boolean): Integer;
var
  Ray: Boolean;
begin
  Result := 0;
  if KillerAlive then
    if not RayCalibrated then
      if not RayTried then
        CalibrateRayCast(Killer.X, Killer.Y);
  if RayCalibrated then
    Result := EF_RAY_CAL;
  if Killer.ID <> Victim.ID then
  begin
    Ray := Map.RayCast(Killer.X, Killer.Y, Victim.X, Victim.Y, False, False, True, False, 0);
    if Ray then
      Result := Result or EF_RAY_RAW;
    if Ray = RayClearIsTrue then
      Result := Result or EF_LOS;
  end;
end;

{ The library measures a kill from the place the lethal shot was fired, which only it knows, and
  asks here whether that line was clear; the walls do not move, so a tick later gives the same
  answer. }
procedure AnswerRay(RequestId, X1, Y1, X2, Y2: Integer);
var
  Answer: Integer;
  AX, AY, BX, BY: Single;
begin
  { calibrated by the first kill of a map (HandleKill); until then the answer is unknown }
  Answer := RAY_UNKNOWN;
  if RayCalibrated then
  begin
    AX := X1;
    AY := Y1;
    BX := X2;
    BY := Y2;
    if Map.RayCast(AX, AY, BX, BY, False, False, True, False, 0) = RayClearIsTrue then
      Answer := RAY_CLEAR
    else
      Answer := RAY_BLOCKED;
  end;
  ZS_Ev_Ray(RequestId, Answer, Game.TickCount);
end;

{ The team balance moves a player. A player carrying a flag is never moved; a move for a dead
  player waits when the player has already respawned. ChangeTeam runs the OnBeforeJoin handlers,
  so MoveTeam tells ours that this change comes from the library. }
function MovePlayer(Player: TActivePlayer; Team, Flags: Integer): Integer;
var
  ID: Integer;
begin
  ID := Player.ID;
  { ChangeTeam throws for anything but a team 0..5, which would lose the rest of the tick }
  if (Team < 0) or (Team > TEAM_SPECTATOR) then
  begin
    Result := MOVE_REFUSED;
    Exit;
  end;
  if Player.Team = Team then
  begin
    { the player got there without us: no move was made }
    Result := MOVE_ALREADY;
    Exit;
  end;
  if Player.Flagger then
  begin
    Result := MOVE_FLAGGER;
    Exit;
  end;
  if ((Flags and MOVE_DEAD_ONLY) <> 0) and Player.Alive then
  begin
    Result := MOVE_ALIVE;
    Exit;
  end;
  MoveTeam[ID] := Team;
  ResurrectBusy := True;
  Player.ChangeTeam(Team, TJoinSilent);
  ResurrectBusy := False;
  MoveTeam[ID] := -1;
  if Player.Team = Team then
    Result := MOVE_DONE
  else
    Result := MOVE_REFUSED;
end;

{ ---------------- the map vote of the library ---------------- }

{ The maps list goes to the library whole: the names in their order, each followed by a line break,
  and the entry being played (the next map is the one after it). A copy stays here for the check. }
procedure SendMapList(Reason: Integer);
var
  i, n: Integer;
  S, Entry: string;
begin
  n := Game.MapsList.MapsCount;
  if n < 0 then
    n := 0;
  SetLength(ListNames, n);
  S := '';
  for i := 0 to n - 1 do
  begin
    Entry := Game.MapsList.Map[i];
    ListNames[i] := Entry;
    S := S + Entry + #10;
  end;
  ListCount := n;
  ListCurrent := Game.MapsList.CurrentMapId;
  ListCheckPos := 0;
  ZS_Ev_Map_List(n, ListCurrent, Reason, Game.TickCount, PChar(S));
end;

{ Other scripts change the list without any event (Game.LoadList, MapsList.AddMap): once a second the
  count, the entry being played and a part of the names are compared with the copy. }
procedure CheckMapList();
var
  k, i: Integer;
  Changed: Boolean;
begin
  Changed := False;
  if Game.MapsList.MapsCount <> ListCount then
    Changed := True
  else if Game.MapsList.CurrentMapId <> ListCurrent then
    Changed := True
  else
    for k := 1 to MAPLIST_CHECK_NAMES do
      if not Changed then
        if ListCount > 0 then
        begin
          if ListCheckPos >= ListCount then
            ListCheckPos := 0;
          i := ListCheckPos;
          ListCheckPos := ListCheckPos + 1;
          if Game.MapsList.Map[i] <> ListNames[i] then
            Changed := True;
        end;
  if Changed then
    SendMapList(MAPLIST_CHANGED);
end;

{ /addmap, /delmap and /loadlist change the list after the handlers of the command have run: it goes
  to the library on the next tick }
procedure NoteMapListCommand(Command: string);
var
  C: string;
begin
  C := LowerCase(Trim(Command));
  if Length(C) > 0 then
    if C[1] = '/' then
      Delete(C, 1, 1);
  if (Copy(C, 1, 7) = 'addmap ') or (Copy(C, 1, 7) = 'delmap ') or (C = 'loadlist') or (Copy(C, 1, 9) = 'loadlist ') then
    ListResendTick := Game.TickCount + 1;
end;

{ ACT_VOTE_START: the clients see the vote of the library as Soldat's own vote, so F12 works; with a
  vote percent of 200 Soldat never lets it pass by itself, the library decides. The percent it had
  is kept for later (a 200 left from before is not one to keep). }
procedure StartSoldatVote(Target: string; Tick: Integer);
var
  P: Integer;
begin
  P := Game.VotePercent;
  if P <> VOTE_PERCENT_NEVER then
    MvSavedPercent := P;
  MvActive := True;
  MvRestoreWanted := True;
  MvSoldatUntil := Tick + SOLDAT_VOTE_TICKS;
  Game.VotePercent := VOTE_PERCENT_NEVER;
  Game.StartVoteMap(Target);
end;

{ ACT_VOTE_END: the percent goes back once Soldat's own vote has run out (CheckVotePercent); until
  then an F12 that reached the server's /votemap could still let that vote pass }
procedure EndSoldatVote(Fallback: Integer);
begin
  MvActive := False;
  if Fallback > 0 then
    MvFallback := Fallback;
  MvRestoreWanted := True;
end;

procedure CheckVotePercent(Tick: Integer);
var
  P: Integer;
begin
  if MvActive then
    Exit;
  if Tick < MvSoldatUntil then
    Exit;
  MvRestoreWanted := False;
  P := MvSavedPercent;
  MvSavedPercent := -1;
  { somebody set another percent in the meantime: that one stays }
  if Game.VotePercent <> VOTE_PERCENT_NEVER then
    Exit;
  if P < 0 then
    P := MvFallback;
  if P > 0 then
    if P < VOTE_PERCENT_NEVER then
      Game.VotePercent := P;
end;

{ A percent of 200 that nobody puts back - left by a script that stopped in the middle of a vote, or
  by the old map vote of Respawn_control after a failed vote, which blocks every later vote, kick
  votes too - goes back after a map change and at the start ([MapVote] RestoreVotePercent, 0 =
  leave it). }
procedure NoteStuckVotePercent();
begin
  if MvActive then
    Exit;
  if Game.VotePercent = VOTE_PERCENT_NEVER then
    MvRestoreWanted := True;
end;

{ ACT_MAP_CHANGE: the next map of the list with Map.NextMap, so the list goes on after it instead of
  coming back to it; any other map with Map.SetMap }
procedure ChangeMapTo(Target: string; IsNext: Integer);
begin
  MvChangeTick := Game.TickCount;
  if IsNext = 1 then
    if Game.NextMap = Target then
    begin
      Map.NextMap();
      Exit;
    end;
  Map.SetMap(Target);
end;

procedure SnapScores();
var
  t: Integer;
begin
  for t := TEAM_ALPHA to TEAM_DELTA do
    ScoreOk[t] := Game.Teams[t].Score;
end;

procedure PollActions();
var
  n, Kind, Slot, Team, Answer: Integer;
  Text: string;
  Kicked: Boolean;
begin
  { the library keeps to the limits of a tick: a few lines per player, two team moves; an empty
    queue costs this one call }
  if ZS_Action_Begin() = 0 then
    Exit;
  for n := 1 to ACTIONS_PER_TICK do
  begin
    Kind := ZS_Action_Next();
    if Kind = 0 then
      Exit;
    Slot := ZS_Action_Slot();
    Text := ZS_Action_Text();
    if Kind = ACT_INTEGRITY then
    begin
      { the guard turned on: the scores of now are the ones it accepts (it read none while off) }
      if (IgFlags and IG_ENABLED) = 0 then
        if (ZS_Action_Int(1) and IG_ENABLED) <> 0 then
        begin
          SnapScores();
          GuardWasOff := False;
        end;
      IgFlags := ZS_Action_Int(1);
      IgMinOpp := ZS_Action_Int(2);
    end
    else if Kind = ACT_BROADCAST then
      Players.WriteConsole(Text, ZS_Action_Color())
    else if Kind = ACT_WRITELN then
      WriteLn(Text)
    else if Kind = ACT_RAYCAST then
      AnswerRay(ZS_Action_Int(1), ZS_Action_Int(2), ZS_Action_Int(3), ZS_Action_Int(6), ZS_Action_Int(7))
    else if Kind = ACT_VOTE_START then
      StartSoldatVote(Text, Game.TickCount)
    else if Kind = ACT_VOTE_END then
      EndSoldatVote(ZS_Action_Int(1))
    else if Kind = ACT_MAP_CHANGE then
      ChangeMapTo(Text, ZS_Action_Int(1))
    else if Kind = ACT_MAPVOTE then
    begin
      MvFlags := ZS_Action_Int(1);
      MvFallback := ZS_Action_Int(2);
      { the first settings after the start: a percent of 200 left from before goes back }
      if not MvConfigSeen then
      begin
        MvConfigSeen := True;
        NoteStuckVotePercent();
      end;
    end
    else if (Slot >= 1) and (Slot <= 32) then
    begin
      if Players[Slot].Active then
        case Kind of
          ACT_CONSOLE:
            Players[Slot].WriteConsole(Text, ZS_Action_Color());
          ACT_BIGTEXT:
            { Int 4 = scale x 10000, Int 5 = display time in ticks }
            Players[Slot].BigText(ZS_Action_Int(1), Text, ZS_Action_Int(5), ZS_Action_Color(),
              ZS_Action_Int(4) / 10000.0, ZS_Action_Int(2), ZS_Action_Int(3));
          ACT_SETTEAM:
            begin
              Team := ZS_Action_Int(1);
              if (Team >= 0) and (Team <= TEAM_SPECTATOR) then
                Players[Slot].Team := Team;
            end;
          ACT_KICK:
            begin
              if Text <> '' then
                Players[Slot].WriteConsole(Text, $FF8C00);
              Kicked := Players[Slot].Kick(TKickConsole);
            end;
          ACT_MOVE:
            begin
              Team := ZS_Action_Int(1);
              Answer := MovePlayer(Players[Slot], Team, ZS_Action_Int(2));
              ZS_Ev_Move_Result(Slot, Team, Answer, Game.TickCount);
            end;
        end;
    end;
  end;
end;

function RunCommand(Slot: Integer; Command: string; Source, Admin: Integer): Boolean;
var
  S: string;
begin
  S := Command;
  Result := ZS_Command(Slot, PChar(S), Source, AdminToken(Admin = 1), Game.TickCount) = 1;
end;

{ a command told from another without keeping its text (a password maybe); H stays below
  1000003 * 31 + 256, so nothing overflows }
function CommandHash(S: string): Integer;
var
  i, H: Integer;
begin
  H := Length(S);
  for i := 1 to Length(S) do
    H := (H mod 1000003) * 31 + Ord(S[i]);
  Result := H;
end;

{ True tells the server the command is handled: it is then neither executed nor written to the
  console log, which keeps /login and /register passwords out of the logs. Via: CMD_VIA_COMMAND or
  CMD_VIA_ADMIN, the handler it came through. }
function PlayerCommand(Player: TActivePlayer; Command: string; Admin, Via: Integer): Boolean;
var
  ID, Tick, Hash: Integer;
begin
  ID := Player.ID;
  Tick := Game.TickCount;
  Hash := CommandHash(Command);
  { the second copy of an admin's command: the other handler, the same tick and text. Two commands
    of a player in one tick both run. }
  if CmdTick[ID] = Tick then
    if CmdVia[ID] <> Via then
      if CmdHash[ID] = Hash then
      begin
        CmdTick[ID] := -1;
        Result := CmdHandled[ID];
        Exit;
      end;
  Result := RunCommand(ID, Command, SRC_COMMAND, Admin);
  CmdTick[ID] := Tick;
  CmdHash[ID] := Hash;
  CmdVia[ID] := Via;
  CmdHandled[ID] := Result;
end;

{ ---------------- score guard ---------------- }

{ Soldat gives points for things that are not play: a player who joins a team in survival is killed
  by the server, and that death can look like a wiped out team; a flag carrier can still score after
  the round or the match is over; and points can be farmed with nobody to play against. The guard
  sets such a score back and tells the library, so the statistics do not count them either. }

{ living players of the other teams, in one look at the slots }
function OtherTeamsAlive(Team: Integer): Integer;
var
  i, T: Integer;
begin
  Result := 0;
  for i := 1 to 32 do
    if Players[i].Active then
    begin
      T := Players[i].Team;
      if (T >= TEAM_ALPHA) and (T <= TEAM_DELTA) and (T <> Team) then
        if Players[i].Alive then
          Result := Result + 1;
    end;
end;

{ players of the other teams, alive or not; spectators do not count }
function OtherTeamsPlayers(Team: Integer): Integer;
var
  i, T: Integer;
begin
  Result := 0;
  for i := 1 to 32 do
    if Players[i].Active then
    begin
      T := Players[i].Team;
      if (T >= TEAM_ALPHA) and (T <= TEAM_DELTA) and (T <> Team) then
        Result := Result + 1;
    end;
end;

function GuardOn(Flag: Integer): Boolean;
begin
  Result := ((IgFlags and IG_ENABLED) <> 0) and ((IgFlags and Flag) <> 0) and not GuardBusy;
end;

procedure ReportIntegrity(Slot, Kind, Team, Value, Extra: Integer; Text: string);
var
  S: string;
begin
  if not Started then
    Exit;
  S := Text;
  ZS_Ev_Integrity(Slot, Kind, Team, Value, Extra, PChar(S), Game.TickCount);
end;

{ written at the end of the tick (FlushWrites), never inside the event that caused it }
procedure Announce(Text: string);
begin
  if not GuardOn(IG_ANNOUNCE) then
    Exit;
  if Announces < ANNOUNCE_MAX then
  begin
    Announces := Announces + 1;
    AnnounceText[Announces] := '[ZitroStats] ' + Text;
  end;
end;

{ A map change the server has already started can only be stopped by a pause and an unpause: both
  write the counter that runs it. Nothing else in the script reaches that counter. }
procedure CancelMapChange();
begin
  MapPendActive := False;
  MapBeforeWaiting := False;
  if Game.Paused then
    Exit;
  Game.Paused := True;
  Game.Paused := False;
end;

{ Sets a team score back to the last value the guard accepted. Kind says why, for the log. }
function TakeBackPoint(Team, Kind, Slot, Extra: Integer): Boolean;
begin
  Result := False;
  if (Team < TEAM_ALPHA) or (Team > TEAM_DELTA) or GuardBusy then
    Exit;
  if Game.Teams[Team].Score <= ScoreOk[Team] then
    Exit;
  GuardBusy := True;
  { the point may have ended the map: the change goes with it - never the change of a passed map
    vote, which no point made }
  if MapPendActive and (Game.TickCount - MapPendTick <= 2) then
    if MapPendTick <> MvChangeTick then
      CancelMapChange();
  Game.Teams[Team].Score := ScoreOk[Team];
  GuardBusy := False;
  Result := True;
  ReportIntegrity(Slot, Kind, Team, ScoreOk[Team], Extra, '');
end;

{ survival gives the round to the last team standing; only a real death can do that }
function RoundPointTeam(Team: Integer): Boolean;
begin
  Result := False;
  if not Game.Survival then
    Exit;
  if Game.GameStyle = GS_CTF then
    Result := True
  else if (Game.GameStyle = GS_INF) and (Team = TEAM_ALPHA) then
    Result := True;
end;

{ Every tick: what changed the scores since the last look? A point without an opposing team, or a
  survival round point without anybody dying for it, is taken back. Only the teams that can score
  in the game style are read, every score once; what the guard leaves of a score that rose is the
  new ScoreOk (read again only then). Off, the guard reads nothing; turned on, it first notes the
  scores. }
procedure GuardTick(Tick: Integer);
var
  t, Score: Integer;
  Solo: Boolean;
begin
  if (IgFlags and IG_ENABLED) = 0 then
  begin
    GuardWasOff := True;
    Exit;
  end;
  if GuardWasOff then
  begin
    GuardWasOff := False;
    SnapScores();
    Exit;
  end;
  for t := TEAM_ALPHA to ScoreTeams do
  begin
    Score := Game.Teams[t].Score;
    if Score <= ScoreOk[t] then
      ScoreOk[t] := Score
    else
    begin
      { ScriptCore evaluates both sides of "and": the players are counted only when the guard
        needs them }
      Solo := False;
      if GuardOn(IG_SOLO) then
        if OtherTeamsPlayers(t) < IgMinOpp then
          Solo := True;
      if Solo then
      begin
        if TakeBackPoint(t, IGE_SOLO, 0, 0) then
          Announce('A point without an opposing team does not count.');
      end
      else if GuardOn(IG_JOINSCORE) and RoundPointTeam(t) and (Tick - LastRealDeath > 2) then
      begin
        if TakeBackPoint(t, IGE_JOINSCORE, 0, 0) then
          Announce('A round point that nobody played for was taken back.');
      end;
      ScoreOk[t] := Game.Teams[t].Score;
    end;
  end;
end;

{ after a map change the server leaves players who were dead lying dead; they are put back on
  their feet by joining their own team again, without the damage the survival rule would deal.
  The survival rule also takes the death of that kill off the scoreboard, a kill that Resurrect
  turns away: the count the player had is put back. }
procedure ResurrectDead();
var
  i, n, D: Integer;
begin
  if GuardBusy then
    Exit;
  n := 0;
  GuardBusy := True;
  ResurrectBusy := True;
  for i := 1 to 32 do
    if Players[i].Active then
      { team 0 too: in deathmatch, pointmatch and rambo every player is in it }
      if Players[i].Team <= TEAM_DELTA then
        if not Players[i].Alive then
        begin
          Resurrect[i] := True;
          MoveTeam[i] := Players[i].Team;
          D := Players[i].Deaths;
          Players[i].ChangeTeam(Players[i].Team, TJoinSilent);
          if Players[i].Deaths <> D then
            Players[i].Deaths := D;
          MoveTeam[i] := -1;
          Resurrect[i] := False;
          n := n + 1;
        end;
  ResurrectBusy := False;
  GuardBusy := False;
  if n > 0 then
    ReportIntegrity(0, IGE_RESPAWN, 0, n, 0, '');
end;

{ /pause while the map is changing throws the change away: the server then keeps the map and gives
  it the full time again. The command is refused for those few seconds. }
function PauseRefused(Slot: Integer; Command: string): Boolean;
var
  C: string;
begin
  Result := False;
  if not GuardOn(IG_MAPCHANGE) or not MapPendActive then
    Exit;
  C := LowerCase(Trim(Command));
  if (C <> '/pause') and (C <> 'pause') then
    Exit;
  Result := True;
  { the player hears it on the next tick: a write inside a command handler can hold the server up.
    The command of an admin comes twice (OnCommand, then OnAdminCommand): noted and reported once. }
  if (Slot >= 1) and (Slot <= 32) then
  begin
    if PauseNote[Slot] then
      Exit;
    PauseNote[Slot] := True;
    PauseNotes := PauseNotes + 1;
  end
  else
    WriteLn(PAUSE_NOTE);
  ReportIntegrity(Slot, IGE_PAUSE, 0, 0, 0, '');
end;

{ what handlers wanted to say (Announce, PauseRefused), written from the clock; a few lines to
  everybody per tick, the rest waits for the next ticks }
procedure FlushWrites();
var
  i, n: Integer;
begin
  n := Announces;
  if n > ANNOUNCES_PER_TICK then
    n := ANNOUNCES_PER_TICK;
  for i := 1 to n do
    Players.WriteConsole(AnnounceText[i], CLR_GUARD);
  for i := n + 1 to Announces do
    AnnounceText[i - n] := AnnounceText[i];
  Announces := Announces - n;
  if PauseNotes > 0 then
  begin
    PauseNotes := 0;
    for i := 1 to 32 do
      if PauseNote[i] then
      begin
        PauseNote[i] := False;
        if Players[i].Active then
          Players[i].WriteConsole(PAUSE_NOTE, CLR_GUARD);
      end;
  end;
end;

{ One of the spawn points of a team, the way the server picks one (RandomizeStart): a random
  point of the team, a few pixels off. No point of that team: nothing is moved. }
procedure PlaceAtTeamSpawn(Player: TActivePlayer; Team: Integer);
var
  i, Count, Pick: Integer;
  X, Y: Single;
begin
  Count := 0;
  for i := 1 to 255 do
    if Map.Spawns[i].Active then
      if Map.Spawns[i].Style = Team then
        Count := Count + 1;
  if Count = 0 then
    Exit;
  Pick := Random(1, Count + 1);
  if Pick > Count then
    Pick := Count;
  if Pick < 1 then
    Pick := 1;
  for i := 1 to 255 do
    if Map.Spawns[i].Active then
      if Map.Spawns[i].Style = Team then
      begin
        Pick := Pick - 1;
        if Pick = 0 then
        begin
          X := Map.Spawns[i].X + Random(-4, 4);
          Y := Map.Spawns[i].Y + Random(-4, 0);
          Player.Move(X, Y);
          Exit;
        end;
      end;
end;

{ Soldat 2.8.2 puts a joining player at a spawn point of the team they clicked and only then asks
  OnBeforeJoin; another team there changes the colour, not the place. BeforeJoin notes such a
  player and here, on the next tick, they are moved to a spawn point of the team they were given.
  Not inside the join itself: sending to the players from inside a handler of an incoming packet
  is what once froze the server. Not in survival (the join kills the player there, and the round
  respawn is at the right base), not with a flag, not when somebody moved them in the meantime. }
procedure FixJoinSpawns(Tick: Integer);
var
  i, T: Integer;
begin
  JoinFixes := 0;
  for i := 1 to 32 do
    if JoinFixTeam[i] > 0 then
    begin
      if Tick <= JoinFixTick[i] then
        JoinFixes := JoinFixes + 1
      else
      begin
        T := JoinFixTeam[i];
        JoinFixTeam[i] := 0;
        if Players[i].Active then
          if Players[i].Team = T then
            if Players[i].Alive then
              if not Players[i].Flagger then
                PlaceAtTeamSpawn(Players[i], T);
      end;
    end;
end;

{ the map change was announced and never happened: a pause threw the counter away }
procedure CheckLostMapChange(Tick: Integer);
begin
  { runs every tick: the server is asked about the pause only while a map change waits }
  if not MapPendActive then
    Exit;
  if Game.Paused then
    Exit;
  if Tick - MapPendTick <= MAPCHANGE_LOST_TICKS then
    Exit;
  MapPendActive := False;
  if not GuardOn(IG_MAPCHANGE) then
    Exit;
  ReportIntegrity(0, IGE_MAPCHANGE, 0, 0, 0, MapPendName);
  WriteLn('[ZitroStats] The map change to ' + MapPendName + ' was lost (a pause) and is repeated.');
  if MapPendName <> '' then
    Map.SetMap(MapPendName)
  else
    Map.NextMap();
end;

{ [Bridges] once a second: the next soldier not found in the server's memory yet is looked for (most
  are found when they join or respawn) }
procedure BindNext();
var
  k, i: Integer;
  P: TActivePlayer;
begin
  for k := 1 to 32 do
  begin
    BindSlot := BindSlot + 1;
    if BindSlot > 32 then
      BindSlot := 1;
    i := BindSlot;
    if InGame[i] then
      if not Bound[i] then
      begin
        P := Players[i];
        if P.Active then
          if ZS_Bind(i, P, P.X, P.Y) = 1 then
            Bound[i] := True;
        Exit;
      end;
  end;
end;

{ [Bridges] once a second: the next soldier's record against his properties. A difference switches
  the reading off for good: the script reads the properties again, as before. }
procedure CheckMemory();
var
  k, i, State, Keys, R: Integer;
  P: TActivePlayer;
begin
  for k := 1 to 32 do
  begin
    CheckSlot := CheckSlot + 1;
    if CheckSlot > 32 then
      CheckSlot := 1;
    i := CheckSlot;
    if Bound[i] then
      if InGame[i] then
      begin
        P := Players[i];
        if not P.Active then
          Exit;
        State := BoolInt(P.Alive) + BoolInt(P.OnGround) * 2 + BoolInt(P.IsProne) * 4 + BoolInt(P.Flagger) * 8;
        { the keys in the record's order: left, right, up, crouch, fire, jetpack, grenade, change, throw,
          reload, prone, flag throw }
        Keys := BoolInt(P.KeyLeft) + BoolInt(P.KeyRight) * 2 + BoolInt(P.KeyUp) * 4 + BoolInt(P.KeyCrouch) * 8 +
          BoolInt(P.KeyShoot) * 16 + BoolInt(P.KeyJetpack) * 32 + BoolInt(P.KeyGrenade) * 64 +
          BoolInt(P.KeyChangeWeap) * 128 + BoolInt(P.KeyThrow) * 256 + BoolInt(P.KeyReload) * 512 +
          BoolInt(P.KeyProne) * 1024 + BoolInt(P.KeyFlagThrow) * 2048;
        R := ZS_Check(i, State, P.Primary.WType, P.Primary.Ammo, P.Secondary.WType, P.Secondary.Ammo, P.Grenades,
          P.Jets, P.Team, Keys, P.X, P.Y, P.Health, P.Vest);
        if R = 0 then
          WriteLn('[ZitroStats] The server''s memory is not read any more (/zs_perf tells why); the script reads ' +
            'the players itself again.');
        Exit;
      end;
  end;
end;

{ ---------------- event handlers ---------------- }

procedure SendMapBefore();
var
  i, Tick: Integer;
  S: string;
begin
  MapBeforeWaiting := False;
  Tick := Game.TickCount;
  { the scoreboard is still complete here; it is reset for the next map }
  for i := 1 to 32 do
    if Players[i].Active then
      if Players[i].Human then
        ZS_Ev_Player_Score(i, Players[i].Kills, Players[i].Deaths, Tick);
  S := MapPendName;
  ZS_Ev_Map_Before(PChar(S), Game.Teams[1].Score, Game.Teams[2].Score, Game.Teams[3].Score, Game.Teams[4].Score,
    Game.TimeLeft, Game.ScoreLimit, Tick);
end;

{ Admin rights change while a player plays (Basic-Extended gives its Steam admins theirs, /adm,
  remote.txt): once a second the rights of the humans are compared with what the library heard last,
  so its notices to the admins follow them. One property read per human. }
procedure CheckAdmins();
var
  k, i, A: Integer;
begin
  for k := 1 to HumanCount do
  begin
    i := HumanList[k];
    A := BoolInt(Players[i].IsAdmin);
    if A <> AdminSent[i] then
    begin
      AdminSent[i] := A;
      ZS_Ev_Admin(i, AdminToken(A = 1));
    end;
  end;
end;

procedure HandleClock(Ticks: Integer);
var
  i, k, Tick, Mask, Rest, Changed, Style: Integer;
begin
  Tick := Game.TickCount;
  { [Bridges]: the bullets of the last tick, and the humans the library reads itself }
  Mask := ZS_Frame(Tick);
  ClockTicks := ClockTicks + 1;
  { nothing of these spans a tick: a handler that was cut short leaves nothing behind }
  GuardBusy := False;
  if ResurrectBusy then
  begin
    ResurrectBusy := False;
    for i := 1 to 32 do
    begin
      Resurrect[i] := False;
      MoveTeam[i] := -1;
    end;
  end;
  { the score guard notes the scores of this tick itself }
  GuardTick(Tick);
  if MapBeforeWaiting then
    SendMapBefore();
  CheckLostMapChange(Tick);
  if JoinFixes > 0 then
    FixJoinSpawns(Tick);
  { a human the library starts or stops reading starts afresh in TrackPlayer (and a kit counts from
    his health of the next tick) }
  if Mask <> FollowMask then
  begin
    Changed := Mask xor FollowMask;
    FollowMask := Mask;
    for k := 1 to HumanCount do
    begin
      i := HumanList[k];
      if (Changed shr (i - 1)) and 1 <> 0 then
      begin
        LastWeapon[i] := -1;
        LastHealth[i] := -1;
      end;
    end;
  end;
  { the humans the library does not read follow through their properties }
  Rest := HumanMask and not Mask;
  if Rest <> 0 then
    for k := 1 to HumanCount do
    begin
      i := HumanList[k];
      if (Rest shr (i - 1)) and 1 <> 0 then
        if Players[i].Active then
          TrackPlayer(Players[i], Tick);
    end;
  if ThrowsWaiting > 0 then
    ConfirmThrows(Tick);
  { the map vote: the list an admin changed, and the vote percent once Soldat's own vote is over }
  if ListResendTick <> 0 then
    if Tick >= ListResendTick then
    begin
      ListResendTick := 0;
      SendMapList(MAPLIST_ADMIN);
    end;
  if MvRestoreWanted then
    CheckVotePercent(Tick);
  if ClockTicks mod TICKS_PER_SECOND = 0 then
  begin
    Style := Game.GameStyle;
    ZS_Ev_Tick(Tick, Game.Teams[1].Score, Game.Teams[2].Score, Game.Teams[3].Score, Game.Teams[4].Score,
      Game.TimeLeft, Style, BoolInt(Game.Paused));
    NoteStyle(Style);
    CheckRealistic(Tick);
    for k := 1 to HumanCount do
      SendHeal(HumanList[k], Tick);
    CheckAdmins();
    CheckMapList();
    BridgeBits := ZS_Bridges();
    BindNext();
    if BridgeBits and BR_MEMORY <> 0 then
      CheckMemory();
  end;
  if (ClockTicks mod FLAG_REPORT_TICKS = 0) and (Tick - MapChangeTick > MAP_SETTLE_TICKS) then
    ReportFlagBases(Tick);
  if Announces + PauseNotes > 0 then
    FlushWrites();
  PollActions();
end;

procedure HandleJoinGame(Player: TActivePlayer; Team: TTeam);
begin
  SendJoin(Player);
end;

procedure HandleJoinTeam(Player: TActivePlayer; Team: TTeam);
var
  ID, t, Mine: Integer;
  Taken: Boolean;
begin
  ID := Player.ID;
  LastWeapon[ID] := -1;
  { a player put back on their feet after a map change did not change team }
  if not Resurrect[ID] then
    ZS_Ev_Team(ID, Player.Team, Game.TickCount);
  { Survival kills a player who joins a team, so that nobody joins alive in the middle of a round.
    The server reads that death like any other and gives the round to the only team that still has
    somebody alive. Nobody played for that point, so it is taken back in the same tick. }
  if not GuardOn(IG_JOINSCORE) or not Game.Survival then
    Exit;
  Mine := Player.Team;
  if (Mine < TEAM_ALPHA) or (Mine > TEAM_DELTA) then
    Exit;
  if Player.Alive then
    Exit;
  { somebody really died in this tick: then the round was won and the point is theirs }
  if LastRealDeath = Game.TickCount then
    Exit;
  { one line for the players, however many teams got a point }
  Taken := False;
  for t := TEAM_ALPHA to TEAM_DELTA do
    if TakeBackPoint(t, IGE_JOINSCORE, ID, 0) then
      Taken := True;
  if Taken then
    Announce(Player.Name + ' changed team: the round point was taken back.');
end;

procedure HandleLeave(Player: TActivePlayer; Kicked: Boolean);
var
  ID: Integer;
begin
  ID := Player.ID;
  HumanSlot[ID] := False;
  NoteHumans();
  InGame[ID] := False;
  JoinFixTeam[ID] := 0;
  PauseNote[ID] := False;
  LastWeapon[ID] := -1;
  Resurrect[ID] := False;
  MoveTeam[ID] := -1;
  AdminTeam[ID] := -1;
  ServerKillTick[ID] := -1;
  RespawnTick[ID] := -1;
  CmdTick[ID] := -1;
  ThrowWaiting[ID] := False;
  LastHealth[ID] := -1;
  SendHeal(ID, Game.TickCount);
  ZS_Ev_Leave(ID, BoolInt(Kicked), Game.TickCount);
end;

{ Before a player enters a team the library may pick another one, to keep the teams even. A player
  who joins the server has no old team (OldTeam = nil) and may have no player object yet; such a
  player is never refused, because the server would take that for a full server. The ID of the
  team is not read from the team object: every team has its own handler. }
function BeforeJoin(Player: TActivePlayer; Team: Integer; OldTeam: TTeam): ShortInt;
var
  ID, Old, Answer: Integer;
begin
  Result := Team;
  { survival kills a player who enters a team right after this handler, with a hit of his own
    (HandleDamage): noted for everybody, bots too, whatever the answer below }
  if Player <> nil then
  begin
    ID := Player.ID;
    if (ID >= 1) and (ID <= 32) then
      JoinTick[ID] := Game.TickCount;
  end;
  if not Started then
    Exit;
  ID := 0;
  Old := NEW_PLAYER_TEAM;
  if Player <> nil then
  begin
    ID := Player.ID;
    if (OldTeam <> nil) and Player.Active then
      Old := Player.Team;
  end;
  { a change to the team the player is in is a respawn: ChangeTeam to the own team is the only one
    ScriptCore has (other scripts use it, Respawn_control's /testrespawn too). The balance has no say
    in it - its answer for a player it would rather see in another team (-1) would cancel it. }
  if Old <> NEW_PLAYER_TEAM then
    if Team = Old then
      Exit;
  if (ID >= 1) and (ID <= 32) then
  begin
    if MoveTeam[ID] = Team then
      Exit;
    if (AdminTeam[ID] = Team) and (AdminTeamTick[ID] = Game.TickCount) then
      Exit;
    { bots are placed by the server and by admins }
    if (Old <> NEW_PLAYER_TEAM) and not Player.Human then
      Exit;
  end;
  Answer := ZS_Team_Join(ID, Team, Old, Game.TickCount);
  if (Answer >= 0) and (Answer <= TEAM_SPECTATOR) then
    Result := Answer
  else if Old <> NEW_PLAYER_TEAM then
    Result := -1;
  { a joining player already stands at a spawn point of the team they asked for (Soldat 2.8.2
    asks this handler only after that): given another team, they are moved to its base on the
    next tick (FixJoinSpawns) }
  if Old = NEW_PLAYER_TEAM then
    if (ID >= 1) and (ID <= 32) then
      if (Result <> Team) and (Result >= TEAM_ALPHA) and (Result <= TEAM_DELTA) then
      begin
        JoinFixTeam[ID] := Result;
        JoinFixTick[ID] := Game.TickCount;
        JoinFixes := JoinFixes + 1;
      end;
end;

function HandleBeforeJoin0(Player: TActivePlayer; Team, OldTeam: TTeam): ShortInt;
begin
  Result := BeforeJoin(Player, 0, OldTeam);
end;

function HandleBeforeJoin1(Player: TActivePlayer; Team, OldTeam: TTeam): ShortInt;
begin
  Result := BeforeJoin(Player, 1, OldTeam);
end;

function HandleBeforeJoin2(Player: TActivePlayer; Team, OldTeam: TTeam): ShortInt;
begin
  Result := BeforeJoin(Player, 2, OldTeam);
end;

function HandleBeforeJoin3(Player: TActivePlayer; Team, OldTeam: TTeam): ShortInt;
begin
  Result := BeforeJoin(Player, 3, OldTeam);
end;

function HandleBeforeJoin4(Player: TActivePlayer; Team, OldTeam: TTeam): ShortInt;
begin
  Result := BeforeJoin(Player, 4, OldTeam);
end;

function HandleBeforeJoin5(Player: TActivePlayer; Team, OldTeam: TTeam): ShortInt;
begin
  Result := BeforeJoin(Player, 5, OldTeam);
end;

{ AuthState 0 = Steam confirmed the player; the SteamID becomes readable only then }
function HandleSteamAuth(ID: Byte; AuthState: Byte): Byte;
var
  PSteam: string;
begin
  Result := AuthState;
  if (ID < 1) or (ID > 32) then
    Exit;
  if not Players[ID].Active then
    Exit;
  PSteam := SteamIdOf(Players[ID]);
  ZS_Ev_Steam_Auth(ID, PChar(PSteam), AuthState, Game.TickCount);
end;

{ Survival refuses the respawn of a player who died in a round that is still running (the server
  respawns everybody at a map change): it runs this handler and then kills the player again with
  a selfkill in the same tick, which HandleKill knows by RespawnTick. }
procedure HandleRespawn(Player: TActivePlayer);
var
  ID: Integer;
begin
  ID := Player.ID;
  RespawnTick[ID] := Game.TickCount;
  if not Bound[ID] then
    if InGame[ID] then
      if ZS_Bind(ID, Player, Player.X, Player.Y) = 1 then
        Bound[ID] := True;
  if not HumanSlot[ID] then
    Exit;
  LastWeapon[ID] := -1;
  { the health is full now; kits count from the next tick on, when TrackPlayer has read it }
  LastHealth[ID] := -1;
  ZS_Ev_Spawn(ID, Player.Primary.WType, Player.Secondary.WType, Game.TickCount, Player.X, Player.Y);
end;

procedure HandleWeaponChange(Player: TActivePlayer; Primary, Secondary: TPlayerWeapon);
var
  ID: Integer;
begin
  ID := Player.ID;
  if not HumanSlot[ID] then
    Exit;
  { a knife leaving the hands of a living player without a new weapon may be a throw; with the hook
    in CreateBullet the library sees the thrown knife itself }
  if Player.Alive and (Player.Primary.WType = WEP_KNIFE) and (Primary.WType = WEP_NONE) and
     (Secondary.WType <> WEP_KNIFE) then
    if ZS_Bridges() and BR_HOOK = 0 then
    begin
      ThrowWaiting[ID] := True;
      ThrowTick[ID] := Game.TickCount;
      ThrowX[ID] := Player.X;
      ThrowY[ID] := Player.Y;
      ThrowsWaiting := ThrowsWaiting + 1;
    end;
  ZS_Ev_Weapon(ID, Primary.WType, Secondary.WType, Primary.Ammo, Secondary.Ammo, Game.TickCount);
  if LastWeapon[ID] >= 0 then
  begin
    LastWeapon[ID] := Primary.WType;
    LastAmmo[ID] := Primary.Ammo;
  end;
end;

procedure HandleKitPickup(Player: TActivePlayer; Kit: TActiveMapObject);
var
  ID, Style: Integer;
begin
  ID := Player.ID;
  if not HumanSlot[ID] then
    Exit;
  Style := Kit.Style;
  { [Bridges]: the library read the health itself and counted what the kit gave }
  if ZS_Ev_Kit(ID, Style, Game.TickCount) = 1 then
    Exit;
  { a medical, berserker or predator kit fills the health up before this handler runs; what it
    added is the difference to the health of the previous tick }
  if (Style = KIT_MEDICAL) or (Style = KIT_BERSERK) or (Style = KIT_PREDATOR) then
    if LastHealth[ID] >= 0 then
      if Player.Health > LastHealth[ID] then
      begin
        HealKit[ID] := HealKit[ID] + (Player.Health - LastHealth[ID]);
        HealKits[ID] := HealKits[ID] + 1;
        LastHealth[ID] := Player.Health;
      end;
end;

procedure HandleKill(Killer, Victim: TActivePlayer; BulletId: Byte);
var
  Weapon, Flags, KID, VID, Tick, Br, Rays: Integer;
  Valid, ServerKill, Alive: Boolean;
  BX, BY: Single;
  B: TActiveMapBullet;
begin
  KID := Killer.ID;
  VID := Victim.ID;
  Tick := Game.TickCount;
  { survival: the server kills players itself when a round ends or somebody joins a team
    (HandleDamage), and kills again the player whose respawn it refuses (HandleRespawn) }
  ServerKill := False;
  if KID = VID then
    if (ServerKillTick[VID] = Tick) or (RespawnTick[VID] = Tick) then
      ServerKill := True;
  if not ServerKill then
    LastRealDeath := Tick;
  if not (HumanSlot[KID] or HumanSlot[VID]) then
    Exit;
  Flags := 0;
  if ServerKill then
    Flags := EF_SERVER_KILL;
  { [Bridges]: the library reads the rest itself (and casts the rays of Cover on the map's walls) }
  Rays := -1;
  Br := ZS_Bridges();
  if Br and BR_MEMORY <> 0 then
  begin
    if Br and BR_MAPWALLS = 0 then
    begin
      Rays := RayFlags(Killer, Victim, Killer.Alive);
      Flags := Flags or Rays;
    end;
    if ZS_Ev_Death(KID, VID, BulletId, Flags, Tick) = 1 then
      Exit;
  end;
  Weapon := BulletWeapon(BulletId, Killer, Valid);
  Flags := Flags or PoseFlags(Killer, EF_A_FLAGGER, EF_A_PRONE, EF_A_ONGROUND, EF_A_CROUCH) or
    PoseFlags(Victim, EF_B_FLAGGER, EF_B_PRONE, EF_B_ONGROUND, EF_B_CROUCH);
  Alive := Killer.Alive;
  if Alive then
    Flags := Flags or EF_A_ALIVE;
  { the line from where the shot was fired is checked later, when the library asks for it
    (AnswerRay) }
  if Rays < 0 then
    Flags := Flags or RayFlags(Killer, Victim, Alive);
  BX := 0;
  BY := 0;
  if Valid then
  begin
    Flags := Flags or EF_BULLET;
    B := Map.Bullets[BulletId];
    BX := B.X;
    BY := B.Y;
  end;
  ZS_Ev_Kill(KID, VID, BulletId, Weapon, Flags, Victim.Primary.WType, Tick,
    Killer.X, Killer.Y, Victim.X, Victim.Y, BX, BY, Victim.Vest);
end;

function HandleDamage(Shooter, Victim: TActivePlayer; Damage: Single; BulletId: Byte): Single;
var
  Weapon, Flags, SID, VID: Integer;
  Valid, ServerHit: Boolean;
  Heal, Room, BX, BY, BVX, BVY: Single;
  B: TActiveMapBullet;
begin
  Result := Damage;
  { a regenerating polygon heals 2 health every 12 ticks (a berserker 8, through a vest nothing),
    which the server reports here as a damage below zero. The server stops at the full health, so
    only what fits is counted; it is added up and sent once a second. }
  if Damage < 0 then
  begin
    if HumanSlot[Victim.ID] then
    begin
      Heal := -Damage;
      Room := FullHealth() - Victim.Health;
      if Heal > Room then
        Heal := Room;
      if Heal > 0 then
        HealRegen[Victim.ID] := HealRegen[Victim.ID] + Heal;
    end;
    Exit;
  end;
  if Damage = 0 then
    Exit;
  VID := Victim.ID;
  { a player who is put back on their feet after a map change takes no damage }
  if Resurrect[VID] then
  begin
    Result := 0;
    Exit;
  end;
  { survival kills players with a hit of 4000 of their own (1000 through a vest) when a round ends
    (no bullet) or somebody joins a team (the tick of OnBeforeJoin); that is the server's doing and
    no damage of the player. The same hit from a script (Player.Damage) is a real death. A player
    who connects is hit with 150 instead, before OnJoin: a self-hit of somebody who is not in the
    game yet is the server's as well. Survival is asked about self-hits only. }
  SID := Shooter.ID;
  if SID = VID then
    if Game.Survival then
    begin
      ServerHit := not InGame[VID];
      if (Damage > SERVER_HIT_DAMAGE) or (Damage = SERVER_HIT_VEST) then
        if (BulletId = SERVER_HIT_BULLET) or (JoinTick[VID] = Game.TickCount) then
          ServerHit := True;
      if ServerHit then
      begin
        ServerKillTick[VID] := Game.TickCount;
        Exit;
      end;
    end;
  if not (HumanSlot[SID] or HumanSlot[VID]) then
    Exit;
  { [Bridges]: the library reads the rest itself }
  if ZS_Ev_Hit(SID, VID, BulletId, Game.TickCount, Damage) = 1 then
    Exit;
  Weapon := BulletWeapon(BulletId, Shooter, Valid);
  Flags := PoseFlags(Shooter, EF_A_FLAGGER, EF_A_PRONE, EF_A_ONGROUND, EF_A_CROUCH) or
    PoseFlags(Victim, EF_B_FLAGGER, EF_B_PRONE, EF_B_ONGROUND, EF_B_CROUCH);
  if Shooter.Alive then
    Flags := Flags or EF_A_ALIVE;
  BX := 0;
  BY := 0;
  BVX := 0;
  BVY := 0;
  if Valid then
  begin
    Flags := Flags or EF_BULLET;
    B := Map.Bullets[BulletId];
    BX := B.X;
    BY := B.Y;
    BVX := B.VelX;
    BVY := B.VelY;
  end;
  { the velocities (pixels a tick): how fast the one who was hit moved, and the shooter's share of
    his bullet's speed, for the flight of a shot the library did not see (a bot's) }
  ZS_Ev_Damage(SID, VID, BulletId, Weapon, Flags, Game.TickCount, Damage, Victim.Vest,
    BX, BY, BVX, BVY, Victim.X, Victim.Y, Victim.Health, Victim.VelX, Victim.VelY, Shooter.VelX, Shooter.VelY);
end;

procedure HandleFlagGrab(Player: TActivePlayer; Flag: TActiveFlag; Team: Byte; GrabbedInBase: Boolean);
begin
  if Player.Human then
    ZS_Ev_Flag(Player.ID, FLAG_GRAB, Team, Game.TickCount, Player.X, Player.Y);
end;

procedure HandleFlagReturn(Player: TActivePlayer; Flag: TActiveFlag; Team: Byte);
begin
  if Player.Human then
    ZS_Ev_Flag(Player.ID, FLAG_RETURN, Team, Game.TickCount, Player.X, Player.Y);
end;

{ A capture counts when there is somebody to play against and the round and the match are still
  running. Soldat scores captures even after the winning point, while the map is already changing,
  and after a survival round is decided. }
procedure HandleFlagScore(Player: TActivePlayer; Flag: TActiveFlag; Team: Byte);
var
  ID, Mine, Kind: Integer;
  Why: string;
  Solo: Boolean;
begin
  ID := Player.ID;
  Mine := Player.Team;
  Kind := 0;
  Why := '';
  if ((IgFlags and IG_ENABLED) <> 0) and (Mine >= TEAM_ALPHA) and (Mine <= TEAM_DELTA) then
  begin
    Solo := False;
    if GuardOn(IG_SOLO) then
      if OtherTeamsPlayers(Mine) < IgMinOpp then
        Solo := True;
    if Solo then
    begin
      Kind := IGE_SOLO;
      Why := 'there is no other team';
    end
    else if GuardOn(IG_DOUBLECAP) then
    begin
      if MapPendActive and (MapPendTick < Game.TickCount) then
      begin
        Kind := IGE_DOUBLECAP;
        Why := 'the match is already over';
      end
      else if Game.Survival then
      begin
        if OtherTeamsAlive(Mine) = 0 then
        begin
          Kind := IGE_DOUBLECAP;
          Why := 'the round was already won';
        end;
      end;
    end;
  end;
  if Kind <> 0 then
  begin
    if TakeBackPoint(Mine, Kind, ID, 1) then
      Announce('The capture of ' + Player.Name + ' does not count: ' + Why + '.');
    Exit;
  end;
  if (Mine >= TEAM_ALPHA) and (Mine <= TEAM_DELTA) then
    ScoreOk[Mine] := Game.Teams[Mine].Score;
  if Player.Human then
    ZS_Ev_Flag(ID, FLAG_SCORE, Team, Game.TickCount, Player.X, Player.Y);
end;

procedure HandleFlagDrop(Player: TActivePlayer; Flag: TActiveFlag; Team: Byte; Thrown: Boolean);
var
  Kind: Integer;
begin
  if not Player.Human then
    Exit;
  if Thrown then
    Kind := FLAG_THROWN
  else
    Kind := FLAG_DROP;
  ZS_Ev_Flag(Player.ID, Kind, Team, Game.TickCount, Player.X, Player.Y);
end;

{ The vote menu and the server's /votemap. With the map vote of the library on, True keeps Soldat's
  own vote from starting and the library starts its vote for this map instead (ZS_Ev_Vote kind 1);
  with it off Soldat's vote runs and the library only counts it. Nothing is written here. }
function HandleVoteMapStart(Player: TActivePlayer; MapName: string): Boolean;
var
  S: string;
begin
  Result := (MvFlags and MV_ENABLED) <> 0;
  S := MapName;
  ZS_Ev_Vote(Player.ID, VOTE_MAP, PChar(S), Game.TickCount);
end;

{ A vote cast for the map vote that shows (F12, or /votemap <map> when the server runs its own
  command): a yes vote for the vote of the library. With the map vote off, a vote another script
  starts with Game.StartVoteMap never passes OnVoteMapStart, and the library counts such a vote
  from the first vote cast for it. }
procedure HandleVoteMap(Player: TActivePlayer; MapName: string);
var
  S: string;
begin
  S := MapName;
  ZS_Ev_Vote(Player.ID, VOTE_MAP_CAST, PChar(S), Game.TickCount);
end;

function HandleVoteKickStart(Player, Victim: TActivePlayer; Reason: string): Boolean;
var
  S: string;
begin
  Result := False;
  S := Victim.Name;
  ZS_Ev_Vote(Player.ID, VOTE_KICK, PChar(S), Game.TickCount);
end;

{ public chat: only "!" commands, team chat arrives with a "^" in front; "bal" on its own is
  what people have always typed for the team chances, so it counts as !bal }
procedure HandleSpeak(Player: TActivePlayer; Text: string);
var
  S: string;
  Handled: Integer;
begin
  S := Text;
  { ScriptCore evaluates both sides of "and", so S[1] is only read once S has a character }
  if Length(S) > 1 then
    if S[1] = '^' then
      Delete(S, 1, 1);
  if LowerCase(Trim(S)) = 'bal' then
    S := '!bal';
  if Length(S) < 2 then
    Exit;
  if S[1] <> '!' then
    Exit;
  Handled := ZS_Command(Player.ID, PChar(S), SRC_CHAT, AdminToken(Player.IsAdmin), Game.TickCount);
end;

function HandleCommand(Player: TActivePlayer; Command: string): Boolean;
begin
  if PauseRefused(Player.ID, Command) then
  begin
    Result := True;
    Exit;
  end;
  Result := PlayerCommand(Player, Command, BoolInt(Player.IsAdmin), CMD_VIA_COMMAND);
end;

{ /setteam1 5 moves player 5 to Alpha through OnBeforeJoin; the balance lets it pass }
procedure NoteSetTeam(Command: string);
var
  S: string;
  Team, ID: Integer;
begin
  S := LowerCase(Trim(Command));
  if Copy(S, 1, 8) <> '/setteam' then
    Exit;
  Team := StrToIntDef(Copy(S, 9, 1), -1);
  ID := StrToIntDef(Trim(Copy(S, 10, 16)), 0);
  if (Team < 0) or (Team > TEAM_SPECTATOR) or (ID < 1) or (ID > 32) then
    Exit;
  AdminTeam[ID] := Team;
  AdminTeamTick[ID] := Game.TickCount;
end;

{ Player = nil: server console or an admin connected with the Soldat Admin client }
function HandleAdminCommand(Player: TActivePlayer; Command: string): Boolean;
var
  Slot: Integer;
begin
  Slot := 0;
  if Player <> nil then
    Slot := Player.ID;
  NoteMapListCommand(Command);
  if PauseRefused(Slot, Command) then
  begin
    Result := True;
    Exit;
  end;
  NoteSetTeam(Command);
  if Player = nil then
    Result := RunCommand(0, Command, SRC_CONSOLE, 1)
  else
    Result := PlayerCommand(Player, Command, 1, CMD_VIA_ADMIN);
end;

{ The server announces a map change a few seconds before it happens. The library hears about it on
  the next tick: a capture that is taken back in this tick may cancel the change again. The server
  raises the score and starts the change before the script sees the point that did it (OnFlagScore,
  the death of a survival round, GuardTick), so TakeBackPoint is where such a change is cancelled.
  A change that comes after a point was taken back is not that point's doing (the score is lower
  again): a vote, an admin, the time limit or a real point, and it goes ahead. }
procedure HandleBeforeMapChange(NextMap: string);
begin
  MapPendActive := True;
  MapPendTick := Game.TickCount;
  MapPendName := NextMap;
  MapBeforeWaiting := True;
end;

procedure HandleAfterMapChange(NewMap: string);
var
  i: Integer;
begin
  MapChangeTick := Game.TickCount;
  if MapBeforeWaiting then
    SendMapBefore();
  MapPendActive := False;
  MapPendName := '';
  LastRealDeath := Game.TickCount;
  for i := 1 to 32 do
  begin
    LastWeapon[i] := -1;
    ThrowWaiting[i] := False;
    ServerKillTick[i] := -1;
  end;
  ThrowsWaiting := 0;
  ScriptErrors := 0;
  { a map where the calibration did not work gets one try of its own }
  RayTried := False;
  SendMapAfter(NewMap, 0);
  { the map vote: the list moves on with Map.NextMap, and a vote percent of 200 that nobody puts
    back goes back }
  SendMapList(MAPLIST_MAPCHANGE);
  NoteStuckVotePercent();
  NoteStyle(Game.GameStyle);
  SnapScores();
  { survival leaves players who were dead at the map change lying dead on the new map }
  if GuardOn(IG_RESPAWN) then
    ResurrectDead();
end;

{ An error in a handler would otherwise stop the script. It is reported (the first few per map)
  and the script keeps running. }
function HandleScriptError(ErrorCode: TErrorType; Message, UnitName, FunctionName: string; Row, Col: Cardinal): Boolean;
begin
  Result := True;
  ScriptErrors := ScriptErrors + 1;
  if ScriptErrors <= SCRIPT_ERRORS_SHOWN then
    WriteLn('[ZitroStats] script error in ' + FunctionName + ' (' + UnitName + ' ' + IntToStr(Row) + ':' +
      IntToStr(Col) + '): ' + Message);
end;

{ The library did not start (ZS_Init refused it) and main.pas stays off - but the commands that
  carry a password are still taken: the server then neither runs them nor writes them, password and
  all, to its console log. The player hears why on the next tick. }
function HandleCommandDown(Player: TActivePlayer; Command: string): Boolean;
var
  S: string;
  Sp, ID: Integer;
begin
  Result := False;
  S := LowerCase(Trim(Command));
  Sp := Pos(' ', S);
  if Sp > 0 then
    S := Copy(S, 1, Sp - 1);
  { S[1] is read only once S has a character }
  if Length(S) > 0 then
    if (S[1] = '/') or (S[1] = '!') then
      Delete(S, 1, 1);
  if Length(S) = 0 then
    Exit;
  if Pos(' ' + S + ' ', DOWN_COMMANDS) = 0 then
    Exit;
  Result := True;
  ID := Player.ID;
  if (ID >= 1) and (ID <= 32) then
    if not DownNote[ID] then
    begin
      DownNote[ID] := True;
      DownNotes := DownNotes + 1;
    end;
end;

procedure HandleClockDown(Ticks: Integer);
var
  i: Integer;
begin
  if DownNotes = 0 then
    Exit;
  DownNotes := 0;
  for i := 1 to 32 do
    if DownNote[i] then
    begin
      DownNote[i] := False;
      if Players[i].Active then
        Players[i].WriteConsole(DOWN_NOTE, CLR_GUARD);
    end;
end;

procedure Startup();
var
  i, Version: Integer;
  Dir: string;
begin
  Started := False;
  ClockTicks := 0;
  ThrowsWaiting := 0;
  ScriptErrors := 0;
  for i := 1 to 32 do
  begin
    LastWeapon[i] := -1;
    LastAmmo[i] := 0;
    LastNades[i] := 0;
    LastHealth[i] := -1;
    HealRegen[i] := 0;
    HealKit[i] := 0;
    HealKits[i] := 0;
    CmdTick[i] := -1;
    CmdHash[i] := 0;
    CmdVia[i] := 0;
    CmdHandled[i] := False;
    ThrowWaiting[i] := False;
    MoveTeam[i] := -1;
    AdminTeam[i] := -1;
    AdminTeamTick[i] := -1;
    Resurrect[i] := False;
    ServerKillTick[i] := -1;
    JoinTick[i] := -1;
    RespawnTick[i] := -1;
    JoinFixTeam[i] := 0;
    JoinFixTick[i] := 0;
    PauseNote[i] := False;
    HumanSlot[i] := False;
    InGame[i] := False;
    Bound[i] := False;
    AdminSent[i] := 0;
  end;
  BridgeBits := 0;
  BindSlot := 0;
  CheckSlot := 0;
  HumanCount := 0;
  HumanMask := 0;
  FollowMask := 0;
  GuardWasOff := True;
  NoteStyle(Game.GameStyle);
  JoinFixes := 0;
  PauseNotes := 0;
  Announces := 0;
  RayTried := False;
  IgFlags := 0;
  IgMinOpp := 1;
  GuardBusy := False;
  ResurrectBusy := False;
  MapPendActive := False;
  MapPendName := '';
  MapBeforeWaiting := False;
  LastRealDeath := 0;
  LastRealistic := -1;
  SnapScores();
  MvFlags := 0;
  MvFallback := 0;
  MvConfigSeen := False;
  MvActive := False;
  MvSavedPercent := -1;
  MvRestoreWanted := False;
  MvSoldatUntil := 0;
  MvChangeTick := -1;
  ListCount := 0;
  ListCurrent := -1;
  ListCheckPos := 0;
  ListResendTick := 0;

  Dir := Script.Dir;
  Version := ZS_Init(PChar(Dir), ZS_API_VERSION);
  if Version <> ZS_API_VERSION then
  begin
    WriteLn('[ZitroStats] ERROR: zitrostats_dll could not be started (code ' + IntToStr(Version) +
      '). main.pas and the library must come from the same release. Statistics are disabled.');
    { only the account commands are still taken (no call of the library) }
    for i := 1 to 32 do
    begin
      DownNote[i] := False;
      Players[i].OnCommand := @HandleCommandDown;
    end;
    DownNotes := 0;
    Script.OnUnhandledException := @HandleScriptError;
    Game.OnClockTick := @HandleClockDown;
    Exit;
  end;
  Started := True;
  RayClearIsTrue := True;
  RayCalibrated := False;
  Token := ZS_Claim_Token();
  if Token = 0 then
    WriteLn('[ZitroStats] WARNING: the admin token was already taken - admin commands are disabled until the server restarts.');

  Script.OnUnhandledException := @HandleScriptError;
  Game.OnJoin := @HandleJoinGame;
  Game.OnLeave := @HandleLeave;
  Game.OnSteamAuth := @HandleSteamAuth;
  Game.OnAdminCommand := @HandleAdminCommand;
  Map.OnBeforeMapChange := @HandleBeforeMapChange;
  Map.OnAfterMapChange := @HandleAfterMapChange;
  for i := 0 to 5 do
    Game.Teams[i].OnJoin := @HandleJoinTeam;
  Game.Teams[0].OnBeforeJoin := @HandleBeforeJoin0;
  Game.Teams[1].OnBeforeJoin := @HandleBeforeJoin1;
  Game.Teams[2].OnBeforeJoin := @HandleBeforeJoin2;
  Game.Teams[3].OnBeforeJoin := @HandleBeforeJoin3;
  Game.Teams[4].OnBeforeJoin := @HandleBeforeJoin4;
  Game.Teams[5].OnBeforeJoin := @HandleBeforeJoin5;
  for i := 1 to 32 do
  begin
    Players[i].OnSpeak := @HandleSpeak;
    Players[i].OnCommand := @HandleCommand;
    Players[i].OnKill := @HandleKill;
    Players[i].OnDamage := @HandleDamage;
    Players[i].OnFlagGrab := @HandleFlagGrab;
    Players[i].OnFlagReturn := @HandleFlagReturn;
    Players[i].OnFlagScore := @HandleFlagScore;
    Players[i].OnFlagDrop := @HandleFlagDrop;
    Players[i].OnKitPickup := @HandleKitPickup;
    Players[i].OnWeaponChange := @HandleWeaponChange;
    Players[i].OnAfterRespawn := @HandleRespawn;
    Players[i].OnVoteMapStart := @HandleVoteMapStart;
    Players[i].OnVoteMap := @HandleVoteMap;
    Players[i].OnVoteKickStart := @HandleVoteKickStart;
  end;

  { the script can be loaded or recompiled in the middle of a map }
  if Game.CurrentMap <> '' then
    SendMapAfter(Game.CurrentMap, MF_RUNNING);
  for i := 1 to 32 do
    if Players[i].Active then
      SendJoin(Players[i]);
  { after the players: the library tells the admins in the game that the script runs again }
  SendMapList(MAPLIST_START);

  Game.TickThreshold := 1;
  Game.OnClockTick := @HandleClock;
  WriteLn('[ZitroStats] 5.7.1 started, loading data in the background.');
end;

initialization
begin
  Startup();
end;

finalization
begin
  { writes pending changes and stops the library threads }
  if Started then
    ZS_Shutdown();
end;

end.
