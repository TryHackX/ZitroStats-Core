# ZitroStats 5.7 - Developer API

Other ScriptCore 3 scripts on the same server can read ZitroStats data - points, ranks, kills, ratings and more - by calling functions of the ZitroStats library. The values come from the statistics ZitroStats keeps in memory, so no files are read.

The API was tested from a second script on Soldat Server 2.8.2 (Windows).

---

## Requirements

- ZitroStats 5.7 is installed and running; its `main.pas` starts the library.
- The server allows libraries for scripts: `server.ini`, section `[ScriptCore3]`, `AllowDlls=1`.
- Your script's `config.ini` contains `Sandboxed = 0` and `AllowDlls = 1`.

---

## Declarations

Copy these declarations into your script. ScriptCore 3 expects `'FunctionName@path cdecl'`, with the path relative to the server folder and without spaces.

```pascal
function ZS_Is_Ready(): Integer;
external {$IFDEF WIN32} 'ZS_Is_Ready@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Is_Ready@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_Get_Api_Version(): Integer;
external {$IFDEF WIN32} 'ZS_Get_Api_Version@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_Get_Api_Version@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Player_Stat(SlotID, StatID: Integer): Double;
external {$IFDEF WIN32} 'ZS_API_Get_Player_Stat@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Player_Stat@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Player_Name(SlotID: Integer): PChar;
external {$IFDEF WIN32} 'ZS_API_Get_Player_Name@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Player_Name@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Player_Rank(SlotID: Integer): Integer;
external {$IFDEF WIN32} 'ZS_API_Get_Player_Rank@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Player_Rank@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Player_HUD(SlotID: Integer): Integer;
external {$IFDEF WIN32} 'ZS_API_Get_Player_HUD@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Player_HUD@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Profile_Stat(ProfileID, StatID: Integer): Double;
external {$IFDEF WIN32} 'ZS_API_Get_Profile_Stat@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Profile_Stat@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Profile_Count(): Integer;
external {$IFDEF WIN32} 'ZS_API_Get_Profile_Count@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Profile_Count@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Top_Player(Rank: Integer): PChar;
external {$IFDEF WIN32} 'ZS_API_Get_Top_Player@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Top_Player@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};

function ZS_API_Get_Server_Peak(): Integer;
external {$IFDEF WIN32} 'ZS_API_Get_Server_Peak@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl' {$ELSE} 'ZS_API_Get_Server_Peak@scripts/ZitroStats-Core/zitrostats_dll.so cdecl' {$ENDIF};
```

Use exactly the library path ZitroStats uses. A copy of the library in another folder is a separate instance without any data and returns only zeros.

ScriptCore refuses to load a script whose declaration names an export the library does not have (`Cannot Import`). Every function above exists since API 14 (ZitroStats 5.2). A function a later library adds can be declared with `delayload` after the calling convention - `'Name@scripts/ZitroStats-Core/zitrostats_dll.dll cdecl delayload'` - so the script loads with an older library too; call it only after `ZS_Get_Api_Version` returned the API that has it, because a delay-loaded import whose export is missing throws when it is called. ZitroStats' own `main.pas` declares its calls newer than API 15 that way.

---

## Functions

| Function | Result |
| :--- | :--- |
| `ZS_Is_Ready(): Integer` | 1 when ZitroStats has loaded its data, otherwise 0 |
| `ZS_Get_Api_Version(): Integer` | `17` for ZitroStats 5.7. The number follows the reserved calls of `main.pas` as well: the functions and StatIDs of this document are the same as with API 14 (ZitroStats 5.2), 15 (5.5) and 16 (5.6); 17 adds `ZS_API_Top_Player_Copy2` for other libraries |
| `ZS_API_Get_Player_Stat(SlotID, StatID): Double` | A statistic of the account used by the player in slot 1-32; 0 while the player is on a registered account without having logged in (`/login`) |
| `ZS_API_Get_Player_Name(SlotID): PChar` | Name of the player in the slot |
| `ZS_API_Get_Player_Rank(SlotID): Integer` | Position of the player's account in the points ranking (1 = best); 0 while the player is not logged in to a registered account |
| `ZS_API_Get_Player_HUD(SlotID): Integer` | 1 when the player has the ZitroStats HUD switched on (`!hud`) and the server shows it (`[HUD] Enabled`) |
| `ZS_API_Get_Profile_Stat(ProfileID, StatID): Double` | A statistic of the account with number `ProfileID` (`#id`), online or not |
| `ZS_API_Get_Profile_Count(): Integer` | Number of accounts |
| `ZS_API_Get_Top_Player(Rank): PChar` | Name of the account at this position of the points ranking |
| `ZS_API_Top_Player_Copy(Rank, Buf, Size): Integer` | For another library on a thread of its own, not for scripts (it waits for the statistics): name, tab and SteamID of the account at this ranking position, copied into `Buf` (`Size` bytes with the closing zero); the result is the length, 0 = nobody. AntiFake uses it for `/visitsi <position>` and the other `i` forms |
| `ZS_API_Top_Player_Copy2(Rank, Buf, Size): Integer` | API 17 (ZitroStats 5.7). The same as `ZS_API_Top_Player_Copy` with the computer of the account as well: name, tab, SteamID, tab, HWID. For another library on a thread of its own, not for scripts; AntiFake can find an account without Steam by its computer instead of by a name (see [For other libraries](#for-other-libraries-zs_api_top_player_copy2)) |
| `ZS_API_Get_Server_Peak(): Integer` | Highest number of players online at the same time |

When there is no value, numeric functions return `0` and text functions return an empty string. That happens:

- before `ZS_Is_Ready` returns 1;
- for an empty slot, or a player who has no account assigned yet;
- for a player on a registered account who has not logged in (`ZS_API_Get_Player_HUD` still says whether the ZitroStats HUD is shown: it shows "Not logged in" then);
- for an unknown account number or ranking position;
- for an unknown StatID.

The account number of an online player is `ZS_API_Get_Player_Stat(SlotID, 37)` (0 until a player on a registered account logs in).

---

## StatID reference

| StatID | Value | Unit / notes |
| :---: | :--- | :--- |
| 0 | Points | ranking points |
| 1 | Kills | |
| 2 | Deaths | |
| 3 | K/D | kills / deaths; kills when there are no deaths |
| 4 | Rating | the performance rating shown in `!stats` and `!top`, calculated for the current game mode |
| 5 | Rank | position in the points ranking, 0 = not ranked |
| 6 | Time played | seconds |
| 7 | Headshot kills | all weapons |
| 8 | Accuracy | percent, 0-100 |
| 9 | Flag captures | |
| 10 | Assists | |
| 11 | Clutches won | Survival rounds won after being the team's last player alive against at least two enemies (team modes only; free-for-all Survival counts no clutches) |
| 12 | Best kill streak | |
| 13 | Damage dealt | hit points |
| 14 | Damage received | hit points |
| 15 | Prone kills | |
| 16 | Jetpack time | seconds |
| 17 | Camp kills | kills after staying within `[Mechanics] CampRadius` for `CampSeconds` |
| 18 | Bink recovery kills | kills of a player who hit the killer within `[Mechanics] BinkSeconds` and did at least `BinkDamage` to the killer in the killer's life |
| 19 | Killing sprees | times a streak reached 5 kills |
| 20 | Rampages | times a streak reached 10 kills |
| 21 | Dominating | times a streak reached 15 kills |
| 22 | Unstoppable | times a streak reached 20 kills |
| 23 | Godlike | times a streak reached 25 kills |
| 24 | Shutdowns | kills of players who had a streak of 5 or more |
| 25 | Finisher kills | kills with USSOCOM, Desert Eagles, knife (also thrown), chainsaw, LAW, flamer or fists within `[Mechanics] FinisherSeconds` of the killer's last hit on the victim with MP5, AK-74, AUG, Spas-12, Ruger, M79, Barrett, Minimi or Minigun |
| 26 | Fastest capture | seconds from the capper's last grab; 0 = no timed capture (a capture under 0.5 s is not timed) |
| 27 | Escort kills | team modes: kills near a living human teammate who carries a flag (`[Mechanics] EscortRadius`) |
| 28 | Flag juggles | grabs within `[Mechanics] JuggleSeconds` after dropping or throwing the flag |
| 29 | Contested holds | Hold the Flag only (`[Mechanics] ContestedHoldSeconds`) |
| 30 | Longest kill | meters |
| 31 | Wins | matches |
| 32 | Losses | matches |
| 33 | Protection days | |
| 34 | Season points | points won or lost in the current season |
| 35 | Glicko-2 value | rating - ConservativeFactor x deviation, for the family (FFA, Team, CTF) of the current game mode; calculated whatever `RankingSystem` is selected |
| 36 | OpenSkill value | mu - 3 x sigma, for the family of the current game mode; calculated whatever `RankingSystem` is selected |
| 37 | Account number | the `#id` used by commands |
| 38 | Registered | 1 = the account is protected with a password |
| 39 | MMR | Heroes of the Storm style match rating for the family of the current game mode (the start value, 1500 by default, before the first rated match); calculated whatever `RankingSystem` is selected |

Constants to copy:

```pascal
const
  ZS_STAT_POINTS = 0;         ZS_STAT_KILLS = 1;            ZS_STAT_DEATHS = 2;
  ZS_STAT_KD = 3;             ZS_STAT_RATING = 4;           ZS_STAT_RANK = 5;
  ZS_STAT_TIME_PLAYED = 6;    ZS_STAT_HEADSHOTS = 7;        ZS_STAT_ACCURACY = 8;
  ZS_STAT_FLAGS = 9;          ZS_STAT_ASSISTS = 10;         ZS_STAT_CLUTCHES = 11;
  ZS_STAT_MAX_STREAK = 12;    ZS_STAT_DMG_DEALT = 13;       ZS_STAT_DMG_RECEIVED = 14;
  ZS_STAT_PRONE_KILLS = 15;   ZS_STAT_JET_TIME = 16;        ZS_STAT_CAMP_KILLS = 17;
  ZS_STAT_BINK_KILLS = 18;    ZS_STAT_SPREES = 19;          ZS_STAT_RAMPAGES = 20;
  ZS_STAT_DOMINATING = 21;    ZS_STAT_UNSTOPPABLE = 22;     ZS_STAT_GODLIKE = 23;
  ZS_STAT_SHUTDOWNS = 24;     ZS_STAT_FINISHERS = 25;       ZS_STAT_FASTEST_CAP = 26;
  ZS_STAT_ESCORT_KILLS = 27;  ZS_STAT_FLAG_JUGGLES = 28;    ZS_STAT_CONTESTED = 29;
  ZS_STAT_LONGEST_KILL = 30;  ZS_STAT_WINS = 31;            ZS_STAT_LOSSES = 32;
  ZS_STAT_PROTECT_DAYS = 33;  ZS_STAT_SEASON_POINTS = 34;   ZS_STAT_GLICKO = 35;
  ZS_STAT_OPENSKILL = 36;     ZS_STAT_ACCOUNT_ID = 37;      ZS_STAT_REGISTERED = 38;
  ZS_STAT_MMR = 39;
```

---

## Examples

The examples use the declarations and constants above.

### Announce the rank of a player once per visit

A joining player may not have an account assigned yet (for example while the Steam login is checked), so the example waits for the first respawn that returns a rank.

```pascal
var
  Announced: array[1..32] of Boolean;

procedure OnRespawn(Player: TActivePlayer);
var
  Rank: Integer;
begin
  if Announced[Player.ID] or (ZS_Is_Ready() = 0) then
    Exit;
  Rank := ZS_API_Get_Player_Rank(Player.ID);
  if Rank = 0 then
    Exit;
  Announced[Player.ID] := True;
  Players.WriteConsole(Player.Name + ' is ranked #' + IntToStr(Rank) + ' with ' +
    IntToStr(Round(ZS_API_Get_Player_Stat(Player.ID, ZS_STAT_POINTS))) + ' points.', $FFAA00);
end;

procedure OnLeave(Player: TActivePlayer; Kicked: Boolean);
begin
  Announced[Player.ID] := False;
end;

var
  i: Integer;
begin
  for i := 1 to 32 do
    Players[i].OnAfterRespawn := @OnRespawn;
  Game.OnLeave := @OnLeave;
end.
```

### Compare team strength

```pascal
function TeamPoints(Team: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to 32 do
    if Players[i].Active and (Players[i].Team = Team) then
      Result := Result + Round(ZS_API_Get_Player_Stat(i, ZS_STAT_POINTS));
end;

var
  NextReport: Integer;

procedure OnTick(Ticks: Integer);
begin
  if (Ticks < NextReport) or (ZS_Is_Ready() = 0) then
    Exit;
  NextReport := Ticks + 60 * 120;   // every two minutes
  Players.WriteConsole('Team points - Alpha: ' + IntToStr(TeamPoints(1)) +
    ', Bravo: ' + IntToStr(TeamPoints(2)), $AAAAFF);
end;

begin
  Game.OnClockTick := @OnTick;
end.
```

### Best three players on request

ZitroStats handles only its own commands, so a script can react to other chat text, here `!best`.

```pascal
procedure OnSpeak(Player: TActivePlayer; Text: string);
var
  i: Integer;
  Name: string;
begin
  if (Text <> '!best') or (ZS_Is_Ready() = 0) then
    Exit;
  for i := 1 to 3 do
  begin
    Name := ZS_API_Get_Top_Player(i);
    if Name <> '' then
      Player.WriteConsole('#' + IntToStr(i) + ' ' + Name, $FFFFFF);
  end;
end;

var
  i: Integer;
begin
  for i := 1 to 32 do
    Players[i].OnSpeak := @OnSpeak;
end.
```

### Account that is not online

```pascal
Kills := Round(ZS_API_Get_Profile_Stat(42, ZS_STAT_KILLS));   // account #42
```

---

## Notes

- **Timing.** ZitroStats applies game events on its own thread a moment after they happen. Inside your own `OnKill` handler, the kill may not be counted yet.
- **Locking.** Each call copies one value under a short lock. It never waits: when the engine is busy the call returns the value it read last for the same arguments (0 or an empty string when it has none), so the game tick is not held up. `/zs_perf` shows how long the engine takes per event. Read values when you need them or cache them per second, rather than reading every statistic of every slot on every tick.
- **Strings.** A returned `PChar` points to a buffer inside the library that the next text call replaces. Assign it to a `string` straight away and never free it. Names use the server's code page.
- **Numbers.** Counters are whole numbers returned as `Double`; use `Round` or `FormatFloat` to display them.
- **Reserved functions.** Only ZitroStats' own `main.pas` may call the other exports: `ZS_Init`, `ZS_Shutdown`, `ZS_Claim_Token`, `ZS_Reload_Config`, `ZS_Ev_*` (including `ZS_Ev_Ray`, `ZS_Ev_Move_Result`, `ZS_Ev_Integrity`, `ZS_Ev_Hit`, `ZS_Ev_Death` and `ZS_Ev_Admin`), `ZS_Team_Join`, `ZS_Command`, `ZS_Action_*`, `ZS_Frame`, `ZS_Bind`, `ZS_Check` and `ZS_Bridges`. Calling them from another script adds false statistics or takes output away from ZitroStats. The admin flag of `ZS_Ev_Join`, `ZS_Ev_Admin` and `ZS_Command` and every console command need the token that `ZS_Claim_Token` hands out once, so another script cannot run admin commands through the library.

---

## How main.pas works with the library

These are the reserved calls of the Notes above. They are described so that a script of your own does not get in their way.

- The reserved damage event carries the health the victim had before the hit, so damage statistics never count more than the victim could lose, and the velocities of the victim and of the shooter at the hit (`Victim.VelX`, `Victim.VelY`, `Shooter.VelX`, `Shooter.VelY`): `!lastfight` shows how fast the one who was hit moved, and works out from the bullet where a shot nobody saw came from (the shots of a bot).
- `main.pas` tells the library with `Map.RayCast` whether the killer still had a clear line to the victim (reserved kill event). The library can also ask `main.pas` about any line: it queues the reserved action `ACT_RAYCAST` (7; `ZS_Action_Int` 1 = request id, 2-3 = start, 6-7 = end) and `main.pas` answers with the reserved `ZS_Ev_Ray(RequestId, Answer, Tick)` (1 clear, 0 blocked, -1 not calibrated). ZitroStats uses it for "Cover (shot)", the line from where the lethal shot was fired to where it hit.
- The team balance (`[Balance]` in `settings.ini`) works through two reserved calls. `main.pas` sets a `Game.Teams[n].OnBeforeJoin` handler for every team and asks `ZS_Team_Join(Slot, Team, OldTeam, Tick)` which team a joining player should enter (-1 keeps a player in their team; a new player, `OldTeam` 255, is never refused). The library moves players with the reserved action `ACT_MOVE` (8; `ZS_Action_Int` 1 = team, 2 = 1 when only a dead player may be moved) and `main.pas` answers with `ZS_Ev_Move_Result(Slot, Team, Result, Tick)` (1 moved, 2 still alive, 3 carries a flag, 4 refused, 5 already in the team). A script of your own that moves players with `ChangeTeam` goes through the same handlers, so the balance may place those players elsewhere; turn `[Balance] AssignJoins` off if your script decides the teams. A `ChangeTeam` to the player's own team - a respawn, the only kind `ScriptCore` itself has - is let through by `main.pas` untouched and never reaches `ZS_Team_Join`.
- The score guard (`[Integrity]`) works in `main.pas`: it sets team scores the server gave for a join, a team change, a double capture or a match without opponents back, puts players a map change left dead back on their feet and keeps `/pause` from throwing a running map change away. It tells the library with the reserved call `ZS_Ev_Integrity`, and the library sends it its settings with the reserved action `ACT_INTEGRITY` (9). A script of your own that changes team scores may see them set back: turn `[Integrity] Enabled` off if your script keeps the score.
- `main.pas` reports every change of the ammunition in hand with the reserved `ZS_Ev_Ammo` (the reload key only in the tick a magazine runs empty), and the ammunition of both weapons with the reserved weapon change; the library tells shots from reloads (README, Reloads). A script of your own that takes ammunition away from a player (`Primary.Ammo`, `ForceWeapon`) may be counted as shots or as a reload; ammunition a script adds is not counted.
- `main.pas` adds up the healing of human players and sends it once a second and when the player leaves (nothing when there was no healing), with the reserved `ZS_Ev_Heal` (slot, kits that healed, tick, health from regenerating polygons, health from kits): a regenerating polygon reports as damage below zero, which `main.pas` turns into health up to the full health (150, or 65 in realistic mode); a medical, berserker or predator kit fills the health before `OnKitPickup` runs, and the difference to the health of the previous tick is what it healed.
- The map vote (`[MapVote]` in `settings.ini`) works through the reserved `ZS_Ev_Vote(Slot, Kind, Target, Tick)` and four reserved actions. `main.pas` reports votes with `ZS_Ev_Vote`: kind 1 a map vote started (`OnVoteMapStart`), 2 a kick vote started (`OnVoteKickStart`; not counted), 3 a vote cast for the map vote that shows (`OnVoteMap`: the vote menu or `/votemap`). With `[MapVote] Enabled`, `OnVoteMapStart` returns `True` - so Soldat's own vote never starts - and the library starts its own vote for that map instead; with it off these handlers only report, a map vote another script starts with `Game.StartVoteMap` (which never passes `OnVoteMapStart`) is counted from its first vote cast, and a vote a script counts entirely on its own (chat commands such as `!v` that never touch Soldat's vote) is not seen at all, only the map change it makes. The library then drives `main.pas` with `ACT_VOTE_START` (10; text = the map: `main.pas` keeps `Game.VotePercent`, sets it to 200 and calls `Game.StartVoteMap`, so the clients see the vote and F12 works while Soldat itself never lets it pass), `ACT_VOTE_END` (11; the percent goes back once Soldat's own vote dialog - always 20 seconds on the clients, whatever `[MapVote] VoteSeconds` says - has run out; `Int 1` = the percent to use when the one from before the vote is not known, 0 = leave it) and `ACT_MAP_CHANGE` (12; text = the map; `Int 1` = 1 when it is `Game.NextMap`, so `Map.NextMap` moves the maps list on, otherwise `Map.SetMap`). `ACT_MAPVOTE` (13) carries the settings the vote needs: `Int 1` = `MV_*` flags (`MV_ENABLED` = 1, the vote is on) and `Int 2` = `[MapVote] RestoreVotePercent`. The reserved `ZS_Ev_Map_List(Count, CurrentId, Reason, Tick, Names)` sends the server's maps list the same way, at the start, after a map change, after `/addmap`, `/delmap` or `/loadlist`, and when a check once a second sees another list (`Reason` 1-4 in that order: `MAPLIST_START`, `MAPLIST_MAPCHANGE`, `MAPLIST_ADMIN`, `MAPLIST_CHANGED`).
- The server bridges (`[Bridges]`, README): `ZS_Frame(Tick)` is the first call of every tick and answers with a bit (slot - 1) for every human the library reads from the server's memory; `main.pas` reads the properties of the others only. `ZS_Bind(Slot, Player, X, Y)` finds a player's soldier in the server's memory (at the join, the respawn and once a second for one not found yet), `ZS_Check` compares one player's properties with the memory once a second, `ZS_Bridges` says what runs (1 the hook in CreateBullet, 2 the memory, 4 the hook in HealthHit, 8 the library has the map's walls). With the memory a hit and a kill go as `ZS_Ev_Hit(Shooter, Victim, BulletId, Tick, Damage)` and `ZS_Ev_Death(Killer, Victim, BulletId, Flags, Tick)` (1 = read, 0 = `main.pas` sends the full `ZS_Ev_Damage` / `ZS_Ev_Kill`), and `ZS_Ev_Kit` answers 1 when the library counted the health a kit gave. The library hooks two places in the server's code - inside `CreateBullet` and the start of `TSprite.HealthHit` -; a script of your own that patches the same places would collide with it (Basic-Extended's hooks are elsewhere). Bullets your script makes with `Map.CreateBullet` do not pass the hook: their damage and kills count, but they are no shots and no hits of the accuracy.
- (API 17) `main.pas` sends the reserved `ZS_Ev_Tick(Tick, Alpha, Bravo, Charlie, Delta, TimeLeft, GameStyle, Paused)` once a second: the team scores, the time left, the game style and 1 while the game is paused (`Game.Paused`) - the seconds of a paused game count for nothing. `ZS_Ev_Map_After` carries `MF_RUNNING` (16) in its flags only when it comes from the script's start: the map already runs (a `/recompile`), so its score is no new points, its first blood was drawn and it is no new load of the map. The reserved `ZS_Ev_Admin(Slot, AdminToken)` tells a change of a human's admin rights (the token while he has them, 0 when he lost them); `main.pas` looks once a second.
- `main.pas` reads a player's team from `Player.Team`, never from `Game.Teams[n].Count`. A script that changes a player's team inside its own `OnJoinTeam` handler (Basic-Extended's TeamGuard and LagGuard) makes Soldat call the `OnJoinTeam` of the scripts loaded after it twice, and their `Game.Teams` lists keep the player in two teams until his slot is taken again: a script of your own that counts the teams should read `Player.Team` too.
- A script that is loaded again (a recompile, or a change of the game mode, which reloads every script) may claim the admin token again; the library notices the new `ZS_Init` and hands it out once more.
- StatID 4 ("Rating") follows `[Ranking] RatingMode`; the default `skill` is a value of roughly 0 to 100 that does not depend on the points.
- Points, Rating, MMR, Glicko-2 and OpenSkill are all kept for every account; `[Ranking] RankingSystem` only decides which one the ranking and `!topskill` use.

---

## For other libraries: ZS_API_Top_Player_Copy2

API 17 (ZitroStats 5.7). For a library such as AntiFake that runs its own thread; never from a script or the game thread, because it waits for the state lock of the engine, as `ZS_API_Top_Player_Copy` does.

```pascal
function ZS_API_Top_Player_Copy2(Rank: LongInt; Buf: PChar; Size: LongInt): LongInt; cdecl;
```

- **Finding it.** `GetProcedureAddress(H, 'ZS_API_Top_Player_Copy2')` on the handle of the loaded library; an older library does not have it (nil): use `ZS_API_Top_Player_Copy` then, which has no third field.
- **Rank** is the position in the points ranking (`!top`), from 1. **Buf** gets `Size` bytes at most with the closing zero; a longer text is cut to `Size - 1` characters. The result is the length of the text without the zero; 0 = nobody at that position (or the library is not ready, `Buf = nil`, `Size < 2`), and with `Size >= 1` `Buf[0]` is then `#0`. 512 bytes are enough (a Soldat name has at most 24 characters, and the library takes a SteamID and a HWID with 64 at most).
- **The text** is `Name#9SteamID#9HWID`. `Name` is the current name of the account. `SteamID` is the SteamID as ZitroStats keeps it (as in `ZS_API_Top_Player_Copy`); empty (or `0`) for an account without Steam. `HWID` is the computer of the account: for an account without Steam the key ZitroStats knows it by, for a Steam account the computer of its last session (information only); it may be empty. No field holds a tab. A later API may add more fields after another tab: read the HWID up to the next tab or to the end.
- **`ZS_API_Top_Player_Copy`** is unchanged: `Name#9SteamID`, so an older AntiFake works as before.
- **Matching the account** (the order recommended for AntiFake): by the SteamID first; without one, the AntiFake account of that computer; only then by the name, with a warning that it was matched by the name only.

---

## Scripts written for ZitroStats 4.5

- The function names and StatIDs 0-30 are the same; StatIDs 31-39, `ZS_Is_Ready`, `ZS_Get_Api_Version` and `ZS_API_Get_Player_HUD` did not exist in 4.5.
- The library is loaded from `scripts/ZitroStats-Core/`, not from the server folder.
- The 4.5 document used declarations (`cdecl; external 'lib'`) that ScriptCore 3 does not accept; use the declarations above.
- Some statistics are measured differently, for example the kill distance; see README.md.
