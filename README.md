# ZitroStats 5.7

Statistics, rankings and optional player accounts for **Soldat Dedicated Server 2.8.2 (Soldat 1.7.1)**.

Author: **Dominik (TryHackX)** - based on the original ZitroStats by Zitro - MIT License.

Every statistic, where it is shown and in which game modes: [STATISTICS.md](STATISTICS.md). Reading ZitroStats data from other scripts: [DEVELOPER_API.md](DEVELOPER_API.md). What is new or different since 5.6: [Changes in 5.7](#changes-in-57).

---

## Contents

1. [How it works](#how-it-works)
2. [Installation](#installation)
3. [Commands](#commands)
4. [Points](#points)
5. [Ranking systems: ELO, MMR, Glicko-2, OpenSkill](#ranking-systems-elo-mmr-glicko-2-openskill)
6. [Team balance](#team-balance)
7. [Map vote](#map-vote)
8. [Score guard](#score-guard)
9. [Server bridges](#server-bridges)
10. [Inactive accounts: protection or decay](#inactive-accounts-protection-or-decay)
11. [Accounts and identity](#accounts-and-identity)
12. [Seasons, achievements and the HUD](#seasons-achievements-and-the-hud)
13. [Exports, webhook and MySQL](#exports-webhook-and-mysql)
14. [Files, backups and admin safety](#files-backups-and-admin-safety)
15. [Colours](#colours)
16. [Building from source](#building-from-source)
17. [Troubleshooting](#troubleshooting)
18. [Changes in 5.7](#changes-in-57)

---

## How it works

```text
Soldat game thread                        zitrostats_dll
------------------                        --------------
main.pas event handlers  --queue-->  engine thread: statistics, rules, commands
main.pas clock tick     <--queue--   output (console lines, HUD, broadcasts)
                                     IO thread: journal, snapshots, backups, logs, exports
                                     service thread: password hashing, e-mail, webhooks
                                     [optional] MySQL thread: the mirror, or the database of every server
```

How the exported functions behave:

- The event functions (`ZS_Ev_*`) and `ZS_Command` only put data into a queue and return. The engine applies them in order.
- `main.pas` opens every game tick with `ZS_Action_Begin` and prints what the library hands out: at most 4 lines or big texts per player, 24 of them in all, 2 team moves or kicks, 2 broadcasts, 4 server console lines and 8 line-of-sight questions (`Map.RayCast`) a tick, and nothing in the ticks Soldat runs back to back to catch up after a stall. A long answer such as `!zitro` arrives within a few ticks, well under a second.
- `ZS_Frame` comes first in every tick: with the [server bridges](#server-bridges) the library reads the players and the bullets of the server itself, and `main.pas` asks the properties only of the players it cannot read.
- `ZS_Init` reads `settings.ini` when the script starts.
- `ZS_Shutdown` applies the events still in the queue (3 seconds at most), adds the time on the names of the players still on the server, writes the journal and waits for it; the next start replays it after the last snapshot, so a `/recompile` does not wait for a whole snapshot.
- A full queue (an engine far behind) drops only what comes many times a second - position samples, bullets, ammunition, hits, shots and healing; joins, leaves, team changes, kills and the other events that carry a state always go in. The text a player is sent waits in a queue of his own (see [Commands](#commands)); kicks, team moves and map changes are never held back by text.
- The developer API functions try a short lock once and never wait: when the engine holds it, they answer with the value they read last.

---

## Installation

The server folder after installation:

```text
soldatserver/
|-- nickreg/                         created on the first start
|   |-- zitrostats.zsdb              statistics snapshot (+ .prev = previous snapshot)
|   |-- zitrostats.<n>.journal       changes since the snapshot
|   |-- zitrostats.lock              prevents two servers from saving the same data
|   |-- accounts.bin, maps.bin       4.x data, if any: read for the import, never changed
|   |-- stats.json                   website export
|   `-- backup/                      zitrostats-YYYYMMDD-HHMMSS-<reason>.zsdb
|-- logs/zitrostats/                 balance.log, audit.log, suspicious.log, errors.log,
|                                    teambalance.log, teambalance-history.log, integrity.log,
|                                    crash.log
`-- scripts/
    `-- ZitroStats-Core/
        |-- main.pas                 ScriptCore 3 bridge
        |-- config.ini               script settings for the server
        |-- settings.ini             ZitroStats settings (every option is commented)
        |-- Example-configs/         settings.ini files for typical servers, with a README.txt
        |-- zitrostats_dll.dll       Windows library
        |-- zitrostats_dll.so        Linux library (build it with source_dll/build.sh)
        |-- README.md
        |-- STATISTICS.md            every statistic and where it is shown
        |-- DEVELOPER_API.md
        `-- source_dll/              Free Pascal source, tests, build scripts
```

1. Copy the `ZitroStats-Core` folder into `scripts/`.
2. Make sure the script may load libraries:
   - `config.ini` of the script: `Sandboxed = 0` and `AllowDlls = 1` (already set)
   - `server.ini` of the server, section `[ScriptCore3]`: `AllowDlls=1`
3. Pick a start: `Example-configs/` holds complete `settings.ini` files for typical servers (deathmatch, survival realistic deathmatch, CTF, survival realistic CTF, teammatch, infiltration, hold the flag, pointmatch, rambomatch, several servers on one MySQL database, a website copy); its `README.txt` says what each one changes. Copy the one that fits over `settings.ini` (keep a backup), or keep the included `settings.ini`.
4. Set `[Admin] ConfirmPassword` in `settings.ini`. Resets, restores, merges and the other operations confirmed with `/yes` are refused until it is set.
5. Start the server. The console shows the library file with its SHA-256 and `[ZitroStats] 5.7 started, loading data in the background.`, then what the [server bridges](#server-bridges) found (`[ZitroStats] bridges: hooks: CreateBullet in place, HealthHit in place; memory: on, ...`), and one of:
   - `imported N accounts from ...` after a 4.x import (and lines for the maps and server records);
   - `N accounts, M maps loaded ...` with existing data;
   - nothing more on a fresh installation.

   After a 4.x import or on a fresh installation the first automatic backup follows at once: `backup saved: ...-auto.zsdb`.

   A `/recompile` (and a change of the game mode, which reloads every script) stops the library and starts it again. The game thread waits while the events the game sent before are applied (3 seconds at most), the time on the names of the players online is added and the journal is written (with `Engine = mysql` also the last exchange, a few seconds at most); then the data is read again from the snapshot and the journal, and admins in the game and the console hear `ZitroStats 5.7: script compiled and running, loaded N accounts, M maps in X ms` once it is ready (nothing is said with nobody online). A `/recompile` in the middle of a map goes on with the match: the score so far is not counted again (no rounds, Hold the Flag points or a second `FIRST BLOOD!` out of it), and it is no new load of the map (`Loads` of `!mapstats`). What lives only in memory starts anew: the kill streaks and `!session` of the players online, `!lastfight`, the form of the players on the map and the locks of the team balance, an operation waiting for `/yes`. A `/recompile` while the data is still loading (the first seconds after the start) stops the load: nothing of it is written, and the next start reads the files again.

`main.pas` loads the library from `scripts/ZitroStats-Core/`. If you rename the folder, replace that path in the `external` declarations at the top of `main.pas`; the path must not contain spaces. Copies of `zitrostats_dll.dll` / `.so` left in the server root by version 4.x are not used and can be deleted; ZitroStats names them in the console at start.

Coming from 4.x: the old data is imported on the first start, when `DataPath` holds no ZitroStats 5 data yet (no `zitrostats.zsdb`, no `.prev`, no journal with changes). ZitroStats reads `nickreg/accounts.bin` (or `accounts.db` of the ScriptCore-only 4.x script when there is no `.bin`), `maps.bin` (or `maps.db`) and `server_records.ini`. The paths are in `[Database]`; the old files are only read, never changed. While importing:

- kill distances become meters (pixels / 14, as in the kill console);
- the weapon matchups that 4.x counted twice are removed (the console says how many);
- duplicate or invalid account numbers get new ones above the highest one;
- former SteamIDs, HWIDs and IPs are left out; the names are kept;
- damage dealt and taken are raised to at least the sum of the player's weapons, and the longest Barrett kill becomes the record of the Barrett.

The last check also runs on every load and on accounts from a shared MySQL database, so an account imported with lower totals is repaired once and saved; right totals stay as they are. If `accounts.bin` or `accounts.db` cannot be read, the console says `ERROR: import of ... failed` and nothing is saved: fix or remove the file and restart.

When you update, replace `main.pas` and the library together (on Linux build the `.so` again with `source_dll/build.sh`) and delete `main.psb` in the script folder if there is one: that is the compiled script of the old version, and the server may run it instead of compiling the new `main.pas`. On Linux `build.sh` writes the new library beside the old one and renames it over it: a running server keeps the library it loaded (it is pinned) and uses the new one after its next start. Never copy a `.so` over the one a running server loaded (`cp`): the server crashes. An older `settings.ini` works as it is: a section or key it lacks (such as `[Matrix]` or `[LastFight]`) takes its default. What a 5.6 server notices after the update is listed in [Changes in 5.7](#changes-in-57).

---

## Commands

Commands work with `!` in the chat and with `/` as a command.

- **Passwords:** password commands only work with `/`; never type passwords in the chat.
- **Logging:** the server does not write `/` commands handled by ZitroStats to its console log. Even when the library does not start (`ERROR: zitrostats_dll could not be started`), `main.pas` still takes `/register`, `/login`, `/changepass`, `/setemail`, `/verifyemail`, `/forgotpass`, `/resetpass`, `/account`, `/removemypass` and `/zs_setpass`, so no password reaches the console log; the player hears `[ZitroStats] The statistics are off on this server now: the account commands do not work.`
- **Answers and limits:** a player may send `[Commands] CommandsPerSecond` (2) commands a second. Every player's answers wait in a queue of their own: while 300 or more of his lines still wait, a new command is answered only with `Wait a moment - your last answers are still being sent.` Lists that go through every account (`!topby`, `!zs_search`, `!server`, `!serverweapons` ...) come once per `HeavyCooldownSeconds` (5) per player and three a second on the whole server; a page of such a list (`/zs_next` ...) and a name looked for in every account (a player not on the server, by a part of his name) wait `SearchCooldownSeconds` (2) per player (`Please wait N s before the next search or page.`). Admins have no per-player wait, and the admins on the server have one list a second that no player can take.
- **`p` (player commands):** nothing for yourself, a name or part of it, or `#id` (account number). One letter is enough. The players on the server are searched first, the accounts only when none of them matches (`!stats al` shows `Alice`, who plays now, not an account called `Al`). The closest name wins: the whole name, then a name that begins with the text, then one with a word that begins with it, then any other; between two of the same kind the shorter name (`!rank u` finds `up`, not `hardkorowy koksu`), and between two accounts the one seen last. Name lists (`!zs_search`) are sorted the same way.
- **`pos`:** a position in the ranking. Every command whose name ends in `i` takes a position instead of a name (`!statsi 3`, `!wepi ak 3`, `!achi 3`), so a player whose nick is a number can still be looked up.
- **Big numbers** are shortened the same way in every answer, signed point changes included, never wider than five characters: in full below 10 000, then `12.3k`, `123k`, `4.5M`, `456M`, `1.2B` (the HUD and the welcome line show the points in full).

### Player

| Command | Description |
| :--- | :--- |
| `!zitro`, `!help` | Every command with its arguments (`*` = required, `[ ]` = optional) and a legend; admin commands first for admins, password commands only for players without Steam (`/removemypass` only with `AllowPasswordRemoval = 1`), the team balance only in team modes, `!pm` only in Pointmatch, `!rambo` only in Rambomatch, `!lastfight` only with `[LastFight] Enabled = 1`, the map vote commands that are switched on and the per-map commands only with `[Matrix] Enabled = 1` (`!playerheatmap` with `PlayerHeatmap = 1`) |
| `!stats [p]`, `!statsi <pos>` | Profile: rank, tier, points, rating, K/D, accuracy, distances, matches, season |
| `!otherstats [p]`, `!otherstatsi <pos>` | Everything else: damage, healing and the kits picked up, rivals, hit zones, timing, movement, feats, CTF, ratings, badges, medals, modes |
| `!status [p]`, `!statusi <pos>` | Play time, protection days, account status and, for any player on the server, the statistics since joining; about a player who is not here it says so |
| `!session [p]`, `!sessioni <pos>` | Statistics since joining the server, yours or those of a player on the server: kills, headshots, points, caps, wins, rounds (a map change does not reset them) |
| `!lastfight [1-3]` | Your own last deaths since you joined, 1 = the last of the 3 kept: who killed you with what, a timeline of the hits you took and dealt - the same cells both ways: zone, the distance from where the shot was fired, the flight time of the bullet, the speed of the one who was hit and a dodge estimate -, who hurt you, what you dealt and whether it killed - also after your death -, points and assists. See **The last fight** below |
| `!rank [p]`, `!ranki <pos>` | One-line ranking position |
| `!top [page]`, `!topp <page>` | Ranking by points |
| `!top <name>`, `!topi <pos>`, `!topme` | Ranking around a player or position |
| `!top <metrics>`, `!topby <metrics> [page]` | Ranking by up to 5 metrics, for example `!topby kd;acc`; `!topby` alone lists the common ones, [STATISTICS.md](STATISTICS.md) all of them. A share or an average made of too few (fewer than 100 shots for `acc`, 10 matches for `winrate` ...; `[Commands] MinSamplePercent` scales them) is `-` and listed last. `!top <metrics>` takes a metric by its whole name (a weapon by a whole word of its names); a player on the server called exactly like a metric is that player, and a text that names a metric only roughly is a player name - `!topby` takes beginnings and typos. `!top 0` or a negative number shows the usage |
| `!topo` | Players on the server |
| `!topskill [page]` | Ranking by the value of `RankingSystem` (MMR, Glicko-2 or OpenSkill) in the current mode's family (FFA, Team, CTF); with `RankingSystem = elo` the MMR list |
| `!topday`, `!topweek`, `!topmonth` `[page]` | Best players of the day, week, month |
| `!topseason [id]` | Current season, or an archived one |
| `!seasons [page]` | Every season, newest first, with its number, dates and podium (1st, 2nd, 3rd); the running season shows the current standings |
| `!zs_search <text>` (`!zssearch`) | Find accounts by name: the closest kind of match first (the whole name, its beginning, a word, a part), and within it the one seen last; the last visit with its date and hour (AntiFake has its own `!af_search`) |
| `!mapstats [map]` | Map statistics, balance, arsenal, leaders of the running match (kills, points, rounds or caps); the time played, the last game with the statistics on and the last load, how the survival rounds ended, the kill balance of the teams and how far the hits there flew |
| `!heatmap [map]`, `!heat` | Picture of where kills and deaths happen on the map, with the flag bases and the three busiest spots in words |
| `!topmaps [page\|map]`, `!topmapsi <pos>`, `!topmapsby <metrics>` | Map rankings; `!topmapsby lastplayed` and `lastloaded` sort the maps by their last game and their last load, newest first |
| `!mapplayerstats [map] [p]`, `!mapplayerotherstats [map] [p]`, `!mapplayerweapstats [map] [p]` | One player on one map: the rows of `!stats` and the sections of `!otherstats` in their places, with everything a record of one map keeps (the rank, the ratings, the season and the achievements belong to the account), and the weapon table of `!allweapons` for the map; `!mapplayerotherstats` also names the rivals he won the most points from and lost the most to. See **Per-map data** below |
| `!mapplayerrivals [map] [flag] [page] [p]`, `!mapplayermatchup [map] [flag] [page] [p]`, `!playerheatmap [map] [p]` | The same player on that map: whom he fought (kills, deaths, the points won from and lost to each of them and their difference, the damage both ways, the last fight), his weapon against the weapon of the other player, and where he killed and died |
| `!playermaps [flag] [page] [p]` | Every map of a player, the one played longest first: time, kills, deaths, K/D, matches won and lost, points, the last game; the last row adds them up |
| `!rivals [flag] [page] [p]`, `!versus [flag] [page] <p> [p2]` | The rivals of a player over all his maps, the most fights first, with the points won from and lost to each (`!rivals lost`: who takes the most points from you, `!rivals delta`: on whom you gain the most); two players head to head (you when `p2` is left out): all maps together, then one line per map |
| `!playermatchup [weapon] [flag] [page] [p]` | A player's weapon against the weapon of the other player over all his maps, in the tables of `!matchup` (the order `[p] [weapon]` works too) |
| `!maprivals [map] [flag] [page]`, `!mapmatchup [map] [weapon] [flag] [page]` | One map with all its players: the pairs with the most fights, with the points won - lost of the first player; the weapon duels of the map |
| `!mapweapstats [map] [flag] [page]`, `!mapwep <weapon> [map]` | The weapons of a map in the table of `!serverweapons`: the kills and picks the map counted (all time) next to the shots, hits, accuracy, headshots, damage, players and time of the players' records of the map; one weapon on a map in the style of `!serverwep`, with the duels of the map and the players with the most kills with it there; both with how far the weapons' hits there flew |
| `!server` | Visitors, activity graph, server totals, hall of fame |
| `!activity` | The whole week hour by hour: when players are on the server, the three busiest hours and the busiest day |
| `!allweapons [p]`, `!allweaponsi <pos>` | All weapons of a player |
| `!allweaponsby <metrics> [p]`, `!allweaponsbyi <metrics> <pos>` | The same table sorted by up to 5 weapon metrics of `!topweaponsby`, for example `!allweaponsby acc` or `!allweaponsby kd;acc Alice` (several metrics joined by `;` or `,`, the player after them): best first by the first metric, ties by the next ones, and a weapon for which a metric means nothing (`-`, like the accuracy of a knife) last. The metrics stand right after the weapon, followed by the other columns of `!allweapons` as far as they fit. The kill distances, times to kill, picks and vest kills of the whole server belong to `!serverweaponsby` (a player's own distances and times to kill are in `!wep`); `!allweaponsby` alone or `!allweaponsby help` lists the metrics |
| `!serverweapons` | The same table for the whole server: every account added up, with the share of all kills and each weapon's share of the picks of its group (primaries, or the secondaries Socom, knife, chainsaw and LAW) in place of the deaths; the totals, the most picked primary and secondary, and the knives, grenades and explosives of `!allweapons` |
| `!serverweaponsby <metrics>` | The weapon table of `!serverweapons` sorted by up to 5 weapon metrics, every metric of `!topweaponsby` included (`!serverweaponsby picks`, `!serverweaponsby acc;kills`); `!serverweaponsby help` lists them |
| `!serverwep <weapon>` | One weapon for the whole server, with the best player, the best accuracy, the reloads, and the kill distances, times to kill, duels and picks of the server |
| `!wep <weapon> [p]`, `!wepi <weapon> <pos>` | One weapon in detail: hits, zones, damage, the reloads (see below) and the player's own kill distances, times to kill and vest kills (kept since 5.5; the whole server's: `!serverwep`; `!wep help` lists the weapons). A beginning or a part of a name is enough (`barr`, `sni`, `mini`) and a small typo is forgiven; a text that fits more than one weapon gets the list of what it could be |
| `!matchup [weapon] [page]` | Weapon against weapon results with the 95% range of the win rate, most duels first, in pages; a weapon counts as favored only when the whole range is above 50% |
| `!topweapons [page]`, `!topweapons <weapon> [page]`, `!topweaponsby <metrics>` | Weapon rankings, by up to 5 metrics, the reload metrics included (`!topweaponsby` alone lists them); a weapon name instead lists the players who used it most |
| `!spree [p]`, `!pm [p]` | Sprees and multi-kills; in Pointmatch also the PM bonus |
| `!rambo [p]` | Rambomatch: bow kills, Rambo kills, time with the bow |
| `!achievements [p]`, `!achievementsi <pos>` | Unlocked achievements, five per line, and season badges |
| `!achlist [p]`, `!achlisti <pos>` | All 50 achievements with what they take, two per line, `[x]` = unlocked (listed first) |
| `!bal`, `!teams`, or just `bal` | Team balance: players, average strength and chance of every team, what the balance is doing, and your own strength (team modes). A chat line that is only `bal` counts too |
| `!switch` | Volunteer for the weaker team; allowed when it does not make the teams uneven. Not with a flag, in survival only while dead, and once a minute (a switch the balance asked for always goes). While another team change is on its way, `!switch` and `!join` say so: try again a moment later |
| `!join` | Spectators: join the team that needs a player |
| `!hud` | Show or hide the on-screen rank line |
| `!contact` | Contact text of the server |

**Aliases:**

| Alias | Same as |
| :--- | :--- |
| `!info`, `!reginfo`, `!credits`, `!autor`, `!tworca` | `!zitro` (`!info` only in chat: `/info` stays Soldat's server info; `!commands` and `!cmds` are left to other scripts) |
| `!ranknum` | `!ranki` |
| `!today` | `!session` |
| `!toponline` | `!topo` |
| `!toprating` | `!topskill` |
| `!topmapsp <page>` | `!topmaps <page>` |
| `!serverstats` | `!server` |
| `!weapons`, `!weaponsi` | `!allweapons`, `!allweaponsi` |
| `!weaponsby`, `!weaponsbyi` | `!allweaponsby`, `!allweaponsbyi` |
| `!serverweps`, `!serverweaps`, `!srvweapons`, `!srvweps`, `!srvweaps` | `!serverweapons` |
| `!serverwepsby`, `!serverweapsby`, `!srvweaponsby`, `!srvwepsby`, `!srvweapsby` | `!serverweaponsby` |
| `!serverweapon`, `!serverweap`, `!srvwep`, `!srvweap` | `!serverwep` |
| `!weapon`, `!weap` | `!wep` |
| `!matchups`, `!matrix` | `!matchup` |
| `!playermatrix`, `!playermatrixi`, `!mapplayermatrix`, `!mapplayermatrixi`, `!mapmatrix` | `!playermatchup`, `!playermatchupi`, `!mapplayermatchup`, `!mapplayermatchupi`, `!mapmatchup` |
| `!mapplayerwepstats`, `!mapplayerwepstatsi` | `!mapplayerweapstats`, `!mapplayerweapstatsi` |
| `!mapweapsstats`, `!mapwepstats`, `!mapwepsstats` | `!mapweapstats` |
| `!mapweapon`, `!mapweap` | `!mapwep` |
| `!topweps`, `!topweaps` | `!topweapons` |
| `!topwepsby`, `!topweapsby` | `!topweaponsby` |
| `!pointmatch`, `!pm` | `!spree` (`!pm` only in chat: `/pm` stays Soldat's private message for admins) |
| `!ach`, `!badges` | `!achievements` |
| `!achi`, `!badgesi` | `!achievementsi` |
| `!achievementslist`, `!achievementslisti` | `!achlist`, `!achlisti` |
| `!weaponi`, `!weapi` | `!wepi` |
| `!teams` | `!bal` |

More forms of the same kind: `!spreei <pos>` and `!ramboi <pos>` show the sprees and the Rambomatch record of a ranking position, and `!topid <slot>` shows the ranking around the player in that server slot. Every per-map command that shows a player has an `i` form with the ranking position in place of the player, as the last number: `!mapplayerstatsi [map] <pos>`, `!mapplayerotherstatsi [map] <pos>`, `!mapplayerweapstatsi [map] <pos>`, `!playerheatmapi [map] <pos>`, `!mapplayerrivalsi [map] [flag] [page] <pos>`, `!mapplayermatchupi [map] [flag] [page] <pos>`, `!playermapsi [flag] [page] <pos>`, `!rivalsi [flag] [page] <pos>`, `!playermatchupi [weapon] [flag] [page] <pos>` and `!versusi [flag] <pos> [pos2]` (you when `pos2` is left out; three numbers are page, pos and pos2). In the name of a weapon command `wep` and `weap` are the same (`!weap` = `!wep`, `!mapweap` = `!mapwep`, `!topweaps` = `!topweps`, the table above).

**Reloads.** Soldat tells scripts nothing about reloading, so ZitroStats reads it from the ammunition of the weapon in hand: a magazine at 0 is being reloaded and the jump back to a full one ends the reload (the Spas-12 loads shell by shell). `!wep` shows how many reloads a player started and how many of them with rounds still in the magazine (the reload key throws those rounds away, and they are not counted as shots), how many ran through or were broken off by a weapon change, a thrown gun or a shot of the Spas-12, how long a reload takes against the time of `weapons.ini`, and how often the player was killed in the middle of one and how far that reload had got. The times come from `weapons.ini`, from `weapons_realistic.ini` in Realistic mode (also when a script or `/realistic` switches it) and from the file `/loadwep` loads. [STATISTICS.md](STATISTICS.md) says how every number is counted.

**Per-map data.** With `[Matrix] Enabled = 1` (default) ZitroStats keeps what every player did on every map, a record per account and map from the first event counted there (humans, while the statistics count). A record counts on its map what the account's own statistics count, as far as it can belong to one map: time, matches, results and rounds, kills, deaths, points, flags, shots, hits by zone, damage, healing and kits, times to kill, movement, the feats, the multi-kill medals, melee and explosives, teamkills, the weapons used there, the rivals (who killed whom, the points won from and lost to each other, the damage both ways, the last fight), the weapon matchups and where the kills and deaths were. What belongs to the account as a whole has no map: the rank and the points ranking, the Rating, MMR, Glicko-2 and OpenSkill, the tier and the league, seasons, achievements and badges, protection days, the spectator time, the totals of each game mode, the balance moves, the streak levels, the Mercy and Cheater medals and the Pointmatch bonus of `!spree`, and of `!rambo` all but the bow kills, the Rambo kills and the time with a bow. The records exist since 5.5; with `Enabled = 0` the views say that nothing is recorded.

**Old per-map data** (`[Matrix] MatrixPruneDays`, 90; 0 = never). The daily work at `[Inactivity] BalanceHour` deletes the records of an account that has not been on the server for that many days, with everything they hold: its counters on every map, its weapons there, its rivals (player against player, with the points and the damage), its weapon matchups and its heat cells. The console and `balance.log` say how many went. What stays: the account's own statistics (`!stats`, `!otherstats`, `!allweapons` ...), the maps' own data (`!mapstats`, `!heatmap`, the weapon matchups of the maps) and the rival entries the other players keep about the account, which go on showing its name; an account deleted altogether (`/removeolderthan`) takes those entries along. The views say how far back the data reaches: `Per-map data: counted since 5.5 while the statistics count; deleted after 90 days without play.` `[Matrix] MatrixMapPruneDays` (0 = never, the default) prunes by the map and by the rival as well, also for accounts that still play: the record of a map the account has not played on for that many days goes, and of the records that stay, the rival entries of opponents not fought for that many days. `/zs_status` shows how many records `[Matrix]` holds and about how much memory they take.

- **The words of a per-map command, in this order:** the map, when the first word names a map of the statistics (its exact name, else the closest name as `!map` finds it) and is not a number, a sort flag of the command, the start of a weapon's name (the commands that take a weapon) or exactly the name of a player on the server; then the weapon; then the sort flags; then the page number; then the player - or in an `i` form the ranking position. `!mapplayerrivals ctf_ash 2 Alice` is page 2 of Alice on ctf_Ash, `!mapplayerrivals lost Alice` Alice on the map being played, who took the most points from her first; `!mapplayerstats ctf_ash Alice`, `!mapplayerstats ash` and `!mapplayerstats Alice` all work. Without a map it is the map being played, without a player yourself. The lists still take the page after the player as well (`!rivals Alice 2`); a player whose nick is a number or a sort flag is found by his `#id`.
- **Sort flags:** `<command> help` lists them (`!rivals help`, `!maprivals help`, `!playermaps help`, `!playermatchup help`, `!mapweapstats help`), the title of a list says the order, and `asc` turns it round. The rivals (`!rivals`, `!mapplayerrivals` and the maps of `!versus`): `fights` (default), `kills`, `deaths`, `kd`, `delta` (points won - lost), `won`, `lost` (who takes the most points from you), `dmg`, `dmgin`, `last`. The pairs of `!maprivals`: `fights` (default), `dmg`, `points` (won both ways), `delta` (the most one-sided first), `last`. The weapon duels (`!playermatchup`, `!mapplayermatchup`, `!mapmatchup`): `duels` (default), `wins`, `losses`, `rate`. `!playermaps`: `time` (default), `kills`, `deaths`, `kd`, `points`, `wins`, `last`. `!mapweapstats`: `kills` (default), `picks`, `shots`, `hits`, `acc`, `hs`, `dmg`, `time`, `players`, `hitdist`, `longesthit`, `hitair`, `killair`.
- **Points won and lost against a rival:** a kill adds to the killer's entry of the victim the points it paid him and to the victim's entry of the killer the points it cost him - as they really moved, after the inactive-victim rule of `[AntiFarm]` and `[Ranking] MinimumPoints` (a victim at the floor loses less than his killer wins). With `[Ranking] SelfkillMode = zerosum` a selfkill under an enemy's fire moves its points the same way, without a kill or a death. Penalties of teamkills and selfkills (they go to nobody), the capture pool of Capture the Flag (the enemy team pays the capping team) and the daily balance of `[Inactivity]` are no rival's points. `Pts Delta` is the points won less the points lost.
- **The weapons of a map** (`!mapweapstats`, `!mapwep`): the kills with each weapon, their share and the share of the picks come from the map's own counters (all time, with `SharedMaps` those of every server); the shots, hits, accuracy, headshots, damage, time and players come from the players' records of the map, since 5.5 and for the last `MatrixPruneDays` days of play. Both commands go through every record of the map, so they count toward the list limits like `!maprivals`.

The lists page with `/zs_next` and the others, in the order they were opened with.

**The last fight.** For every human on the server ZitroStats keeps what happened from `[LastFight] BeforeSeconds` (10) before each of his last 3 deaths to `AfterSeconds` (4) after it, or to the respawn: the hits he took and dealt, his kills and the notes of his HUD (points, assists, feats). Nothing of it is saved, a leave clears it, and bots keep none (a bot that hit or killed a player is in that player's record). The server's own kills (the end of a survival round, a team change) are no deaths here either. What is measured and what is estimated:
- the damage is the server's number, at most the health that was left; with `[Bridges] ServerHook` (default) the zone is the part of the body the server's own hit test chose; without it the zone comes from the damage, or is a guess of the hit model (`~head`) for weapons whose zones do the same damage;
- the hits he took and the hits he dealt have the same cells: the distance, the flight time, the speed and the dodge estimate of a hit belong to the shot and to the one who was hit;
- the distance is measured from where the shot was fired to where it hit, like the kill distance - never from where the players stand. With `[Bridges] MemoryReads` (default) the bullet itself says where it was made: exact for every shot, a bot's too, without `~`. Without the reading, a shot `main.pas` saw (a human's ammunition went down, or a grenade or a knife left his hand, with his position) gives it exactly. A shot nobody saw (a bot's, the stationary gun's) is worked out from the bullet at the hit and marked `~`: its velocity then, the speed it left the gun with (the weapon's speed in `weapons.ini` plus its `InheritedVelocity` share of the shooter's velocity) and Soldat's physics of a bullet (gravity pulls it every tick and it keeps 99% of its speed) lead back to the gun. That is exact while the shooter kept his pace from the shot to the hit and a few meters off when he did not; a bullet slowed by a body or a wall reads as a longer shot. Nothing is worked out for the Spas-12 (too slow for its gravity), explosions, flames, blades and thrown knives;
- the flight time of the bullet follows from that distance and the bullet speed of the weapon, with the drag of Soldat's bullets (or from the ticks the worked out bullet flew); explosions, flames, blades and thrown knives have none;
- the speed is that of the one who was hit - the player himself, or the one he hit -, from his velocity at the hit, which `main.pas` sends with the hit;
- `Dodge (est.)` reads the flight time: under 0.25 s `no` (nobody reacts that fast), up to 0.4 s `hard`, longer `maybe`, `(still)` when the one who was hit stood still (under 2 m/s); blades, explosions, flames and thrown knives get no estimate (`melee`, `blast`, `flame`, `thrown`);
- `(mate)` after a name marks a teammate, and `assist` marks who met the assist rule of `[Mechanics]` (`AssistSeconds`, `AssistMinDamagePercent`) at the death.

`DeathSummary = 1` sends a player two console lines a moment after each death (when the seconds after it are over, or at the respawn): the killer, the weapon, the distance and zone of the hit that killed, the killer's hits and damage by zone, who else hurt him and the points lost, then what he dealt; not to a player who went to the spectators. `Enabled = 0` records nothing and `!lastfight` says it is off.

### Pages

Lists remember what you opened:

| Command | Page |
| :--- | :--- |
| `/zs_next` | Next |
| `/zs_prev` | Previous |
| `/zs_page <n>` | Page n |
| `/zs_first` | First |
| `/zs_end` | Last |

`/zs_next` on the last page shows the first one again, and `/zs_prev` on the first page shows the last. The underscore may be left out (`/zsnext`, `/zspage 3` ...). The plain `/next`, `/prev`, `/page` and the like are left to other scripts: ZitroStats does not answer them.

### Account (optional)

| Command | Description |
| :--- | :--- |
| `/register <password> <password>` | Protect your account with a password |
| `/login <password>`, `/login <name\|#id> <password>` | Log in; the computer becomes trusted for `TrustedDeviceDays` |
| `/changepass <old> <new> <new>` | Change the password |
| `/setemail <address>`, `/verifyemail <code>` | Add an e-mail address for password recovery |
| `/forgotpass [name\|#id]`, `/resetpass <code> <new> <new>` | Reset a forgotten password with a code sent by e-mail |
| `/account`, `/account untrust`, `/account trust on\|off` | Account status; forget all trusted computers; let this account trust computers or not (only with `AllowTrustChoice = 1`) |
| `/removemypass <password>` | Take the password off your account (only with `AllowPasswordRemoval = 1`) |

These commands exist for players without Steam. A Steam account needs no password: it is found by its SteamID, and `/account` only says that it is a Steam account. Commands with a password work only with `/`, never in the chat.

### Admin

Admin commands that take an account accept `#id`, an account number or the exact name.

| Command | Description |
| :--- | :--- |
| `/zs_status` | Library status: accounts, maps, journal, read-only state, the records of `[Matrix]` and about how much memory they take |
| `/zs_status <p>`, `/zs_statusid <id>`, `/zs_statusi <pos>` | Account audit: SteamID, IP, HWID, number of stored aliases, password state, masked e-mail |
| `/zs_search <text>`, `/searcha <text>` | Also finds accounts by former name, `#id`, IP prefix, HWID or SteamID (as a `/` command only: `!searcha` in the chat is refused, since the server shows every chat line to all players) |
| `/resetplayerstats <p>`, `/resetmapstats [map]`, `/resetserverstats` | Resets |
| `/resetallplayersstats`, `/resetallmapsstats` | Full resets |
| `/removeolderthan <days>` | Delete the accounts without a password not seen for that many days (at least 30) - Steam accounts too, as they cannot have a password. Accounts with a password, accounts with protection days and players online are kept. The confirmation says how many go, how many of them are Steam accounts and how many as old stay; with nothing to delete nothing is asked |
| `/zs_merge <#from> <#into>` | Merge two accounts (skipped if `#from` is online when confirmed). The result keeps the identity of `#into` - its SteamID, computer and password; a Steam account is never merged into one without Steam (use the other order); when only `#from` has a password, it goes to `#into` with its trusted computers. The confirmation says whose identity stays |
| `/zs_unregister <#id>` | Remove the password, e-mail, reset codes, lock and trusted computers of a registered account; a player waiting to log in on it plays on |
| `/zs_setpass <#id> <password>` | Set a password (only as a command, never in chat; needs `/yes`; not for Steam accounts; the password rules apply; ends a lock and removes all trusted computers) |
| `/yes <password>`, `/no` | Confirm or cancel a pending operation |
| `/zs_backup`, `/zs_backups`, `/zs_restore <file>` | Make a backup, list the 10 newest, restore one |
| `/zs_save` (`/zs_sync`), `/zs_reload`, `/zs_export` | Write changes now, reload `settings.ini`, write the JSON export now |
| `/zs_suspects`, `/zs_perf` | Suspicious kill series; timing of the library |
| `/bal`, `/bal off`, `/bal on` | Team balance: the best change now (protected players only to even the numbers); pause or resume the automatic changes and the placing of joins |
| `/mix` | New teams: a random line-up evened out for the best chances, different every time (see [Team balance](#team-balance)) |
| `/swap <p> <p>`, `/move <p> <team>` | Swap two players, or move one to `alpha`, `bravo`, `charlie`, `delta` or `spec` (or `1`-`5`); `p` = slot number, `#id` or a part of the name (`/swap` takes one word per player, so a name with a space is given by its slot). A slot that does not exist or is empty, a name that fits nobody or several players, two players of the same team, a spectator - each is said in so many words |
| `/balinfo` | Balance details: settings, every player's strength and form, predictions and the last decisions |
| `/zs_mapvote [cancel]` | Map vote: the settings and the vote that runs; `cancel` ends it |
| `/zs_maps [rescan]` | The maps folder, its files Linux may not load and the maps of the list without a file; `rescan` reads the folder again. The folder is named from the server folder (`maps`), one elsewhere by its last folders (`...\soldat\maps`) |
| `/balexclude <p>` | The balance does not move this player until they leave; the same command again lifts it |

Resets, restores, merges, `/zs_unregister`, `/zs_setpass` and `/removeolderthan` need confirmation with `/yes <password>` (see [Files, backups and admin safety](#files-backups-and-admin-safety)). Commands typed in the server console or sent with Soldat Admin work too, and their answers appear in the console. Admin rights a player gets or loses while he plays (`/adminlog`, Basic-Extended's `/steamadmin` or `/adm`) reach ZitroStats within a second: the notices to the admins follow them.

Whatever runs in the background says when it is done, to the admin who asked: `/zs_save` ("All changes are written"), `/zs_backup` (the file, its size and the number of accounts), `/zs_export` (every file written, with its size), `/zs_reload` (and every line of `settings.ini` it could not use), a restore, and every operation confirmed with `/yes`. A failure is said the same way.

---

## Points

- **Kill:** `MaxPointGive / (MinimumPointDivider + Divider ^ ((killer points - victim points) / PowerDivider))`, rounded and at least `MinPointGive`. Beating a stronger player gives more.
  - The victim loses the same amount, but never below `MinimumPoints`.
  - A victim already at that floor loses nothing, while the killer still gains.
- **Teamkill:** no points, no kill for the killer and no death for the victim (they count as a teamkill and a death by a teammate); `TeamkillPenalty` can take points from the killer.
- **Killed by the server:** in Survival the server kills players itself (a team change mid-round, the end of a round, the players still standing after a capture). That is no death and no selfkill, and the killing spree goes on in the next round. Only the server's own hit counts so: 4000 (1000 through a vest) on the player in the tick he asked to enter a team, or without a bullet at the end of a round. The same hit from a script (`Player.Damage(V, 4000)`: Basic-Extended's `/slay`, `/killall`, bleeding out, the team-kill punishment) is a real death and counts as a selfkill.
- **Selfkill:**
  - A selfkill is never a kill for anybody and never a death, only a selfkill.
  - `SelfkillMode = zerosum` (default): the human enemy who last hit the player within `AssistSeconds` earns what the player loses: `SelfkillAssistShare` % (default 50) of the points a kill would have paid, taken only down to `MinimumPoints`. Without such a hit (or when that enemy's account records no statistics) the penalty below applies.
  - `SelfkillMode = penalty`: `SelfkillPenalty` points are always lost.
  - Penalty points leave the pool; the daily Check Points pays the missing sum back to active accounts (at most 25 points per account per day).
- **Inactive victim:** a player who has not moved or fired for `InactiveVictimSeconds` is inactive.
  - Repeated kills of the same inactive player by the same killer give 100%, 50%, 25% and then 0% of the points (`InactiveVictimMultipliers`, applied after the minimum).
  - The count starts again once the victim is active.
  - `InactiveVictimSeconds = 0` switches the rule off.
- **CTF capture:**
  - Every human enemy with statistics pays `CapPoolPoints` into a pool, but only down to `MinimumPoints`.
  - The capper receives `CapWinnerSharePercent` of it and the human teammates share the rest; without teammates the capper gets everything.
  - If nobody paid (`CapPoolPoints = 0`, no human enemies, or all of them at `MinimumPoints`), and for captures in Infiltration, the capper gets `FlagScoreFallbackPoints`. Holding the flag in Hold the Flag pays no points.
- **Suspicious series:** many kills of the same victim on a nearly empty server are written to `suspicious.log` and shown to admins (`[AntiFarm]`, `/zs_suspects`). Points are not changed.
- **Match results:** wins, losses, draws and ratings count for players who played at least `MinParticipationSeconds` and `MinParticipationPercent` of the match (on all teams together) and are still connected at its end.
  - The win or loss goes to the team a player played for longest. The ratings count every team the player played for, by the share of the time spent there (a part under 5% is left out), so a player the balance moved half way is rated half for each side.
  - Only a match that reached the time or the score limit counts, unless `CountAbortedMatches = 1`.
  - In team modes, leaving a match the team lost can count as a loss (`LeaverCountsAsLoss`).
  - In FFA the player with the best score (ties: fewer deaths) wins and everybody else loses; it needs at least two players, and when nobody is ahead every player gets a draw.

Statistics (kills, points, damage, flags, play time, results and ratings) are only recorded while at least `MinHumansForStats` human players, not counting spectators, are in the game. Against farming on an almost empty server, `MinTeamPerSide` can also require that the two strongest teams are filled, and `MinFFAHumans` how many players a free-for-all needs (both 0 = off). Time alive and the longest life have their own limit, `MinHumansForSurvival`, and a last stand of a Survival round needs `[Mechanics] LastStandMinPlayers` (3) players in the round.

**/pause.** While the game is paused, no time played, alive, with a weapon or with a flag is counted, the match does not grow longer and the team balance waits; when it goes on, inactivity, camping and the windows of assists, multi kills and spawn kills skip the pause. The HUD and a map vote go on.

---

## Ranking systems: ELO, MMR, Glicko-2, OpenSkill

The points above are always kept and `!top` always ranks by points. ZitroStats also calculates an MMR, a Glicko-2 and an OpenSkill rating for every account after every counted match. Each rating is kept separately for three families - FFA (DM, PM, RM), Team (TM, INF, HTF) and CTF - so a CTF specialist is not judged by deathmatch results (`RankingFamily`).

`RankingSystem` selects which rating is used by:

- `!topskill` and the `skill` metric of `!topby`;
- the skill value in `!stats`;
- the JSON export (`rating_system`, `skill_ffa` / `skill_team` / `skill_ctf`).

Because all ratings are calculated all the time, switching later keeps their history.

### `elo` (default)

The classic ZitroStats points. They reward activity as well as skill: somebody who plays a lot gains points even with average results. Simple and familiar for players. `!topskill`, the `skill` metric and the `skill_*` export keys then use the MMR of the current mode's family, and `!topskill` says so.

### `mmr`

The match rating of `[MMR]`: every account starts at `Start` (1500) and a finished match moves it by `Step` times the difference between what the result was and what the ratings expected, using the **average rating of each side**, not single players. Beating a stronger team therefore pays more than beating a weaker one, and the first `PlacementMatches` games move 2.5 times faster, like the placement matches in Heroes of the Storm. In free-for-all modes every player is measured against the average of everyone else in the match.

### `glicko2`

After every match each player's rating is updated from the result:

- **Rating** - the estimated skill, starting at 1500.
- **Deviation (RD)** - how sure the system is. It starts at 350, shrinks with every rated match and grows again for every day without one, so a returning player's rating adapts faster.
- **Volatility** - how consistent the player is.

In FFA modes every pair of players in the match is compared by score. In team modes each player is compared with the average rating of each opposing team. The ranking uses the conservative value `rating - ConservativeFactor x RD`, so a new player is not placed high after a few lucky games. Glicko-2 measures skill, not play time: playing more does not raise the rating by itself.

### `openskill`

A Bayesian system based on the Plackett-Luce model, comparable to Microsoft TrueSkill. Every player has a skill estimate *mu* and an uncertainty *sigma*. After a match all players, or all teams, are ordered by result, and the estimates move according to how surprising the order was. The ranking uses `mu - 3 x sigma`. OpenSkill handles more than two teams and uneven team sizes.

Which one to choose:

| System | Choose it for |
| :--- | :--- |
| `elo` | The familiar points system; rewards activity |
| `mmr` | Match rating that follows the strength of the side you beat, in the style of Heroes of the Storm |
| `glicko2` | A well-known skill rating that separates skill from activity |
| `openskill` | Team play and several teams |

### The Rating index and leagues

`RatingMode` decides what the "Rating" in `!stats`, `!topby rating`, the tier limits and the exports mean:

- `skill` (default): only how somebody plays - accuracy, kill ratio, headshots, won matches and objective work - on a scale of roughly 0 to 100. An account with few kills and deaths is pulled toward the lower baseline, so one lucky evening does not read as mastery, and the points balance never moves the value.
- `gamemode`: the ZitroStats 4 index, weighted per game mode and multiplied by the points.
- `unified`: one formula for every mode, also multiplied by the points.

**Tiers** (Bronze, Silver, Gold ... Grand Master, the lines of `[Ranks]`) follow `[Ranking] TierBy`:

- `points` (default): the points decide, like the ranking itself, so a higher place in `!top` never has a lower tier than a place below it;
- `rating`: the Rating of the current game mode decides (`RatingMode` picks its formula) - a badge of how somebody plays, which can differ from the order of the points;
- `mmr`, `glicko2`, `openskill`: that rating of the family of the current game mode, against the columns `MinMMR`, `MinGlicko` and `MinOpenSkill` of the tier line;
- `both`: points and Rating;
- `all`: every limit the tier line gives.

A tier line is `Name, MinPoints, MinRating, Color, MinGlicko, MinOpenSkill, MinMMR`; a line without the limit the chosen measure needs is skipped, and the last line takes everybody who reaches no other.

**Leagues** are calculated at start and once a day, whether or not they are shown. Every account with at least `PlacementMatches` matches (with `Source = mmr` the MMR matches of the mode family it plays most, with `rating` all its won and lost matches) is ordered by `[Leagues] Source` - `mmr` (default, as in Heroes of the Storm: the MMR of the mode family the account plays most) or `rating` (the Rating index for that family's mode, so the map being played does not matter) - and cut into the tiers of `[Ranks]` by `Percents`, counted from the top: `2,8,20,...` puts the best 2 % into the first league, the rest up to 8 % into the second and so on, and the last league takes everybody left; each league is split into `Divisions` steps, 1 being the best. `!otherstats` always shows the league; with `Enabled = 1`, `!stats` and `!rank` show "Gold 3" in place of the plain tier, and an account that is still in placement says so.

---

## Team balance

`[Balance]` in `settings.ini` evens the teams of Teammatch, CTF, Infiltration and Hold the Flag. Deathmatch, Pointmatch and Rambomatch have no teams. The teams of Teammatch are `TeammatchTeams`: `auto` (Alpha, Bravo, and Charlie and Delta once two players play in them: one player alone in an empty team pulls nobody after him), 2, 3 or 4. For an ordinary two-team teammatch set `TeammatchTeams = 2`.

**How strong a player is.** The balance starts from the player's rating of the current mode family (`Skill = mmr` by default; `glicko2`, `openskill` or `points` work as well). A rating from few matches is pulled towards the median of the server (`UncertaintyGames`), and a player without an account yet counts as the median. On top of it comes the form on the current map: every kill between two teams is a small Elo duel (`FormStep`), captures and returns add to it, and the form counts more with every minute played (`FormFullMinutes`). `Method = global` uses the rating only, `Method = map` only the form, so every map starts even and the chances are not acted on in its first `MapWarmupMinutes` (uneven numbers are).

**How strong a team is.** Every `SkillPerDouble` (400) rating points above the median double a player's weight; a team's weight is the sum, and its chance to win is its weight raised to `SizeImpact` (1.5) against the other teams. The number of players counts by itself: five average players against four have 58%. The Alpha/Bravo record of the map is a factor as well (`UseMapBias`), a player who does not move counts with `AfkFactor`, and bots count with the rating of the `BotSkill` percentile of the server.

**Joins.** Before a player enters a team, `main.pas` asks the library (`OnBeforeJoin`). The player keeps the chosen team if it is at most `JoinTolerance` percent points worse than the best one and the numbers stay within `MaxCountDiff`; otherwise the player goes to the team that needs a player and is told why. A player in a team who wants to switch to the stronger one stays where they are. With fewer than `MinPlayers` humans in the teams no strength is judged and no lock holds: a player keeps the chosen team unless the numbers would end up more uneven than `MaxCountDiff` and than they are (then a new player goes to the smallest team, one who plays stays) - three players may play the strongest alone against the other two. A player who leaves a team the mode does not have (Charlie or Delta in CTF, INF and HTF, e.g. after an admin's `/setteam3` when another script moves him out) is placed in the team the balance prefers; he is never kept there. Two players joining in the same moment are placed one after the other. A new player whose account is not known yet is placed as the median; once the account is known (`JoinReviewSeconds`) the join is looked at again, and a clearly wrong one is corrected before the player has done anything. Soldat 2.8.2 puts a joining player at a spawn point of the team they clicked before it asks the scripts, so a player placed in another team is moved to a spawn point of that team on the next tick (not in survival, where the join kills the player and the round starts them at the right base).

**Corrections.** Every `CheckSeconds` the balance looks at the chances, once at least `MinPlayers` humans play in the teams (with fewer, joins and switches only keep the numbers even):

- A team above `Threshold` (60%) for `SustainSeconds` (45), or teams further apart than `MaxCountDiff` players for `LeaveGraceSeconds` (20, a new player often fills the gap), need a change.
- With `Volunteers = 1` the stronger team (with uneven numbers, the bigger one) is asked first, when one player's switch can even the match: `!switch` within `VolunteerSeconds` moves the first player whose switch helps, right away (in survival only the dead are asked, and they switch while dead). Uneven numbers get their own call, even when the chances had one a moment before. With equal numbers a single switch cannot help (three against three would become two against four), so the balance goes on to a swap at once.
- Otherwise the balance picks the move or swap that brings the chances closest to even, counting what it costs the players: a dead player costs less than a living one, a fresh player less than one who has played in the team for a long time. A change for the chances has to reach `Target` (55%) or gain `MinGain` points, and it may hand the advantage to the other team only within `Target`. A fix of uneven numbers only has to bring the numbers closer; of those moves it takes the one that leaves the chances closest to even.
- The chosen player changes team at the next death (`MoveOnDeath`), at the latest after `PendingMaxSeconds`. Once one half of a swap is done, the other half follows at once, so a swap never leaves three against one; when the map changes in between, the swap is finished on the new map. Any other planned change ends with the map, and its players are told. In survival a living player is never moved: the change waits for the death; a count fix or a swap under way waits for it as long as it takes, any other change is dropped after three minutes.
- Never moved: bots, excluded players (`Exclude`, `/balexclude`), a player whose move is already on its way, and a living flag carrier. A flag carrier's move waits for his death: taking a flag does not cancel a count fix or a swap under way, and when only a flag carrier can even the numbers, he changes team at his next death.
- Protected only while somebody else can go: the player with the best form of the team on this map (`ProtectTop`) and players moved in the last `ImmunityMinutes`. A change for the chances never moves them; uneven numbers do when no free player can even them, the cheapest protection first - the best form before a recent move, and a recent move whose way back is still locked (`LockMinutes`) last.
- A moved player cannot go back for `LockMinutes`. Leaving the server and coming back within `RejoinMemoryMinutes` keeps the lock, the form and the team, so leaving does not help anybody to change sides. A player who changes team in the middle of a match is rated for each team by the share of the time played there; the win or the loss goes to the team played longest.
- No changes in the last `MinTimeLeftSeconds` of a map, when the score is decided, after `MaxMovesPerMap` changes, or within `CooldownSeconds` of the last change (10 seconds when the numbers are uneven). A `!switch` counts here only when it evened the match; a switch that only turns the sides around uses up no change, starts no cooldown and does not restart the count of a lasting imbalance. A player may `!switch` once a minute, unless the balance asks his team for a volunteer.
- A planned change that is dropped - its player left or went to the spectators, an admin moved somebody, `/balexclude` - is told to the players who waited for it; when that leaves the numbers uneven, the balance looks for another change at once, without a new grace time. `!bal` shows who moves next and when, whether `!switch` would take you and where to, and why nobody can be moved when that is the case.

**Admin commands.** `/bal` makes one change now. A swap that is half done is finished; otherwise the players of a planned change count as free, and the plan is dropped only when `/bal` has found a change to replace it. With uneven numbers `/bal`, like the balance, moves a protected player when nobody free can go; when nobody can be moved at all it says who is protected and why, and a planned change stays. `/bal off` and `/bal on` pause and resume the automatic changes and the placing of joins; `/bal off` drops a planned change. `/mix` makes new teams of everybody except bots, excluded players, flag carriers and players whose move is on its way (see below). `/swap` exchanges two players and `/move` puts a player in a team (or with the spectators), both at once; a living flag carrier is not moved, and the admin is told so. In survival `/bal`, `/mix`, `/swap` and `/move` change a living player only at the next death, and the admin is told so, because the server kills a living player who changes team; `/move` to the spectators works at once. `/balexclude` keeps the balance away from a player until they leave (a change planned for them is dropped), and `/balinfo` shows the settings, every player's strength, the predictions and the last decisions.

**Map start.** `MapStartSeconds` (2) after a new map starts - by then the players whose game does not have the map have dropped out to download it (they come back as new players, placed where one is needed), and the players who are still loading stay in their teams and can be moved; a shorter wait moves players while they still pick their weapons at the spawn: `MapStart = fix` makes the fewest changes that even the teams, `shuffle` looks for the best split with a price on every change (both only when the teams are uneven), `mix` gives every map new teams, and `keep` does nothing. In survival the start is left alone, because the server kills a player who changes team.

**Mixing the teams.** `/mix` and `MapStart = mix` do the same: the players are dealt into the teams at random forty times, each line-up is evened out by moves and swaps, and one of the fairest is picked at random - within four points of imbalance of the best one found and never beyond `Target` (unless no line-up gets there). So a mix is always as fair as the balance itself would make it, and two mixes in a row give different teams. The same teams under the other names are no new teams: of the two ways to name them, the one that moves fewer players is used, so a mix never sends everybody across to play with the same mates. After the mix the balance goes on watching the match as usual. A mixed player may not change back for `LockMinutes`; a mix at the start of a map is nobody's own move, so it gives no immunity from the balance and does not count in `Balance Moves`.

**Tuning.** After every completed two-team match that one side won the balance compares its prediction with the result. `/balinfo` shows the Brier score (0.25 is a coin flip, lower is better), the result by predicted chance, and after 30 matches the `SizeImpact` and `SkillPerDouble` that would have predicted this server best; `AutoTune = 1` uses them after 50 matches. The last decisions are in `logs/zitrostats/teambalance.log`, the recorded matches in `teambalance-history.log`.

**Other balancers.** Turn off other balancing scripts such as cube: two balancers move players against each other, and ZitroStats warns about a `cube` script folder at start. The same goes for `[Teams] AutoBalance` of Basic-Extended: keep it at 0 while `[Balance] Enabled = 1` - ZitroStats may refuse a move it makes, and Basic-Extended announces the move anyway. The server's own `Balance_Teams` may stay on. An admin's `/setteam` is carried out as typed. A player in a team the balance does not count (Charlie or Delta in CTF, INF and HTF, or alone in an unused team of Teammatch) hears from `!switch` that the balance does not even his team: he changes it from the menu.

---

## Map vote

`[MapVote]` in `settings.ini` runs its own map vote inside the library - `!v`, `!nextmap`, `!lastmap`, `!randommap`, `!map`, `!votemap`, `/votemap`, `!maps`, `!allmaps` and `!searchmap` - so a vote fits the same account system, statistics and page browsing (`/zs_next` and the rest) as everything else, and a server needs no separate map-vote script. `Enabled = 0` leaves these commands to another script and lets Soldat's own map vote run as usual; `/map` and `/nextmap` always stay the server's own admin commands.

**The maps.** A vote asks for a map of the server's own maps list first, then, with `AllowAnyMap = 1` (default), a map of the maps folder as well (`MapsFolder`, empty = the server's own `maps` folder, two levels above the script folder). A text is matched to a name the same way everywhere: the whole name, then its beginning, then the beginning of a word (names split at `_`, `-` and spaces), then any part of it, and between matches of the same kind the shorter name, then the order of the list or the folder. The maps folder is read at the start, every `RescanMinutes` and on `/zs_maps rescan`, on a thread of its own; it catalogs every `*.pms` file whatever case the extension is written in, and flags one not spelled exactly `.pms` - on Linux, where file names are case sensitive, the server looks for exactly `<name>.pms` and such a file may not load. The maps list itself is followed as it changes: after `/addmap`, `/delmap` and `/loadlist`, and once a second for a change another script makes with `Game.LoadList` or `MapsList.AddMap`/`RemoveMap` directly.

**The vote.** A player starts a vote with `!nextmap`, `!lastmap`, `!randommap` or `!map <part>` and votes yes with `!v` or F12; `/votemap <map>` (also what the vote menu and F12 send) starts or joins a vote the same way. The players on the teams count for a vote, and so do the spectators with `CountSpectators = 1` (default); with 0 a spectator counts only for a vote they start or vote for, as one of its voters and a yes. It needs `MinPlayers` players able to vote, none in the first `BlockAfterChangeSeconds` of a map or with less than `MinTimeLeftSeconds` left (only on a map with a time limit), and the player who started it waits `StarterCooldownSeconds` before starting another; after every vote of a map the next one waits `GapSeconds` (60), whoever starts it (a vote that a map change or a script reload ended leaves no pause) - players taking turns cannot keep a vote, and with it Soldat's vote dialog that blocks kick votes, on the screens all the time. A vote already running, or a kick vote a player started, is voted on or waited out instead of starting a new one. A kick vote another script starts with `Game.StartVoteKick` (Basic-Extended's `[AntiCheat] VoteKick`) is not seen by ZitroStats: a vote of the map replaces it on the screens, and while ZitroStats' vote runs (`Game.VotePercent` 200) such a kick vote cannot pass - keep `VoteKick` at 0, or let that script wait while `Game.VotePercent` is 200. It passes once `VotePercent` % of the players who may vote said yes - alone on the teams, at once, without ever showing on the clients' screens - and otherwise fails after `VoteSeconds`, or ends early once nobody eligible to vote is left. While it runs, `main.pas` shows it to the clients as Soldat's own vote: it sets `Game.VotePercent` to 200 so Soldat itself never lets it pass by itself, and puts back what it was before (or `RestoreVotePercent`, when the value from before is not known - a stuck 200% left by a stopped script or an old map vote is cleared the same way) once Soldat's own vote dialog is gone; that dialog always shows 20 seconds on the clients, whatever `VoteSeconds` says. A script reload (a `/recompile`, or a change of the game mode) ends a vote that is running. The map changes within a few seconds of passing; a vote for the next map of the list moves the list on (`Map.NextMap`), any other map is set directly (`Map.SetMap`). `VoteStarts`, `VotesPassed` and `VotedIn` of `!mapstats` count these votes directly - see [STATISTICS.md](STATISTICS.md) for exactly how.

| Command | Description |
| :--- | :--- |
| `!v`, `!vote` (or F12) | Vote yes for the map being voted |
| `!nextmap` | Vote for the next map of the maps list |
| `!lastmap`, `!votelast`, `!votelastmap` | Vote for the map played before this one |
| `!randommap` | Vote for a random other map (restricted to the mode's style with `FilterByGameStyle`) |
| `!map [map]` | Alone: the map being played, the next and the last map, and the vote running, if any. With a name or a part of it: vote for that map |
| `!votemap <map>`, `/votemap <map>` | Vote for that map (`/votemap` also what F12 and the vote menu send) |
| `!maps [page\|map]` | The maps list, the map being played marked; below it the next and the last map. With a map (its name or a part of it, found as `!map <part>` finds it): the page that has it, the map marked `>name<` |
| `!allmaps [page\|map]` | Every map of the maps folder, `*` for one not in the maps list. With a map: the page that has it, the map marked `>name<` |
| `!searchmap <part> [page]` | The maps of the maps list and of the maps folder whose name holds the text, in the order the vote searches: the maps list first, then the maps only the folder has, and in each the whole name, its beginning, the beginning of a word, any part, the shorter name first, then the order of the list or the folder - so the first one is the map `!map <part>` finds. `!searchmap ctf_` lists every ctf_ map; `[ ]` marks the map being played and `*` a map that is not in the maps list, as in `!allmaps`; a space may stand for the `_` of a name. `!searchmap` alone says how it is used |
| `/zs_mapvote [cancel]` | Admin: the settings and the vote that runs; `cancel` ends it |
| `/zs_maps [rescan]` | Admin: the maps folder, its files Linux may not load and the maps of the list without a file; `rescan` reads the folder again. The folder is named from the server folder (`maps`), one elsewhere by its last folders (`...\soldat\maps`) |

Every player command above can be switched off on its own in `[MapVote]` (`VoteCommand`, `NextMapCommand`, `LastMapCommand`, `RandomMapCommand`, `MapCommand`, `VoteMapCommand`, `SlashVoteMap` for `/votemap`, `MapsCommand`, `AllMapsCommand`, `SearchMapCommand`): switched off, it gets no answer at all, so another script may answer it instead. `/zs_mapvote` and `/zs_maps` are admin commands and always work, even with `[MapVote] Enabled = 0`.

**Troubleshooting.**

| Problem | Cause and fix |
| :--- | :--- |
| A vote passed but the map did not change | Check the map's file (`/zs_maps`): on Linux the server looks for exactly `<name>.pms`. |
| `!allmaps`, or a vote of a map outside the maps list, finds nothing there | The maps folder was not found: set `[MapVote] MapsFolder` in `settings.ini`, then `/zs_reload` (`/zs_maps` says so too). |

---

## Score guard

`[Integrity]` in `settings.ini`. Soldat hands out team points for things that are no play, and it leaves players lying dead after a map change. `main.pas` sets those scores back in the same moment, before anybody sees them, and the library never counts what was taken back. Every decision is written to `logs/zitrostats/integrity.log`.

| What the server does | What the guard does |
| :--- | :--- |
| **A join or a team change in survival.** The server kills a player who joins a team, so that nobody joins alive in the middle of a round. It reads that death like any other and gives the round to the only team that still has somebody alive. Only the server's own hit counts so: 4000 (1000 through a vest) on the player in the tick he asked to enter a team, or without a bullet at the end of a round. The same hit from a script (`Player.Damage(V, 4000)`: Basic-Extended's `/slay`, `/killall`, bleeding out, the team-kill punishment) is a real death: the round point stays and the death counts as a selfkill. | The point goes back in the same tick (`FixJoinScore`), unless somebody really died in it. The kill itself counts for nobody: no death, no selfkill and no lost points. |
| **A double capture.** A flag carrier still scores after the round was won (survival) or after the winning point, while the map is already changing. | The capture counts for nobody (`VoidDoubleCaptures`): the score goes back, and the player gets no capture in the statistics. A map change the point had started is stopped. |
| **Points without an opponent.** Captures and round points on a server where only one team has players. | They count for nobody while the other teams together have fewer than `MinOpponents` players (dead players count, spectators do not). |
| **A map change in survival.** Players who were dead when the map changed stay dead on the new map. | They are put back on their feet at once (`RespawnAfterMapChange`), without the damage or the death that would normally come with it. The server writes a "has joined" line for each of them. |
| **A pause while the map is changing.** `/pause` overwrites the counter that runs the map change: the map never changes and gets the full time again. | `/pause` is refused for those few seconds (`ProtectMapChange`), and a map change that was thrown away anyway is repeated. |

`Announce = 1` tells everybody in one line what was taken back; at most 2 such lines are written per tick, the rest wait for the next ticks. `/zs_status` counts the points and captures the guard took back.

**What players see.** Soldat's own game code counts captures and survival round points on the client as well, and the server sends the real score about once a second. A point the guard takes back can therefore stay on the scoreboard of the players for up to a second before the server's value replaces it - the same blink that Soldat itself produces when a client counted something the server did not.

**Other scripts.** The guard only sets scores back that the server itself gave. A script of your own that keeps the score (an older AutoScoreFix, a tournament script) does the same work twice: turn one of them off.

---

## Server bridges

`[Bridges]` in `settings.ini` (5.6). Instead of asking ScriptCore for every property - each read costs the game thread one to two microseconds, and `main.pas` used to make dozens per player and tick - the library reads the running server itself. Three switches, all on by default:

| Switch | What it does |
| :--- | :--- |
| `ServerHook` | Two hooks in the server's code. **CreateBullet** reports every bullet the server makes: each shot (every pellet of the Spas-12, both bullets of the Desert Eagles, the Minigun, the stationary gun, the saw), every grenade (frag and cluster told apart) and every thrown knife, with how the shooter stood when he fired. **HealthHit** notes the part of the body the server's own hit test chose for every hit, after its ping compensation: the head, chest and legs of the statistics are the server's, for every weapon. Bullets made by scripts (mines, rockets or extra shots of other scripts) do not pass the hook: they are no shots of the player, and their hits do not count for his accuracy (their damage does). |
| `MemoryReads` | The soldiers and the bullets are read from the server's memory. `ZS_Frame`, the first call of every tick, follows the ammunition, grenades and health of every human (reloads, kits) and samples their places; a hit or a kill sends only the ids (`ZS_Ev_Hit`, `ZS_Ev_Death`) and the library reads the rest - the bullet's place, speed and where and when it was made, the players' places, speeds, health, vest, stance and flag. Every kill is measured from where its bullet was made, like the server's own `You killed` message, and so is every hit on an enemy: the longest hit, the average distance of the hits and how long the bullets of the hits and of the kills flew, per account, per weapon and per map (`!otherstats`, `!wep`, `!serverwep`, `!mapstats`, `!topmapsby`, `!mapweapstats`; kept as sums and counts - two numbers, whatever the number of shots). The bots' lives are known, so survival rounds with bots end as they do in the game. This needs no hook: with `ServerHook = 0` the library still looks up once, patching nothing, where the server keeps its tick (the place of the CreateBullet hook), so hits and kills are measured from where their bullet was made. |
| `MapGeometry` | The library reads the map file (`maps/<map>.pms`, or `[MapVote] MapsFolder`) and casts the rays of Cover (live) - from the killer's eyes to the victim's head, chest and hips - and Cover (shot) itself, at once. |

**Every switch has its way back.** Off, or on a server the library does not recognise (another build, another version), `main.pas` reads the properties and sends the full events as in 5.5; the statistics are the same, the game thread works harder. The hooks are placed only where a signature of 34 (CreateBullet) and 37 bytes (HealthHit) is found exactly once in the server's code, every address is checked before it is read, and once a second one player's properties are compared with the memory: a difference switches the reading off until the server restarts, and the console says `The server's memory is not read any more (/zs_perf tells why)`. The hooks are taken out when the script stops (`/recompile`) and when `/zs_reload` finds `ServerHook = 0`; the console says what runs whenever that changes (`[ZitroStats] bridges: hooks: CreateBullet in place, HealthHit in place; memory: on, ...`).

**With Basic-Extended.** Basic-Extended hooks the start of CreateBullet; ZitroStats hooks a place inside it, after the bullet is made, and the start of HealthHit, which Basic-Extended does not touch. Both run together and count every bullet, in any load order and after a `/recompile` of either script. Bullets Basic-Extended makes for its mines, classes, mortars or extra shots are scripts' bullets for ZitroStats (`hits of scripts' bullets` in `/zs_perf`). Two things the hooks do not cover:

- **The damage of a hit** is what reaches ZitroStats' `OnDamage` handler: Soldat hands every script the damage the script before it returned. At the start of the server and after a full `/recompile` ZitroStats comes after Basic-Extended and counts the damage Basic-Extended left (spawn protection, `/god`, `/dmgfix`, ...). `/recompile ZitroStats_Core` alone puts ZitroStats first, before Basic-Extended changes anything, until the next full `/recompile` or restart: after it, give `/recompile BasicExtended` as well (settings need no `/recompile`: `/zs_reload` reads them).
- **Shots in shock.** A soldier in shock (`[Bleeding]` of Basic-Extended) or downed still fires in his own game, and Basic-Extended removes those bullets right after the server made them. ZitroStats has counted them by then: they are shots without a chance to hit and lower his accuracy a little.

**What it costs and saves.** Measured on a scratch copy of the server with 8 bots counted as humans: the script's tick fell from 176 to 42 microseconds (an empty server: from 81 to 36), the library's own part is about 1 microsecond per player. `/zs_perf` shows what runs, why something does not, the hits and kills read from memory, the zones the server named and how often the damage named the same one, and the script's tick.

**Linux.** The same signatures, records and offsets were found in the Linux server binary; the `.so` has to be built there (`build.sh`) and was not tried on a running Linux server. On Linux a hardware fault inside the library (a bad memory read, an integer division by zero) is not caught by the library's own error handling as it is on Windows: a Free Pascal library hands the signals back to the server, so such a fault may stop the server instead of being written to `errors.log`, and `crash.log` is not written there.

**MySQL.** The new statistics are new fields of the accounts and the per-map records: all servers that share one database (`Engine = mysql`) have to run 5.6 or newer together, a 5.5 server writes them back without them (and 5.7 keeps the times of the account security in UTC: see [MySQL / MariaDB](#mysql--mariadb)).

---

## Inactive accounts: protection or decay

An account is **inactive** when its player has not joined the server for `InactivityDays`. `[Inactivity] Mode` decides what happens to inactive accounts once a day at `BalanceHour`.

### `protection` (default, the classic behaviour)

- **Earning protection:** a day with at least `ProtectSessionSeconds` of play and `ProtectEventsPerDay` kills and deaths earns a protection day, up to `ProtectMaxDays`.
- **Paying:** an inactive account uses one protection day or pays points: ranking places 1-15 pay 220 down to 80, all other inactive accounts pay 35. An account at or below `BalanceFloorPoints` pays nothing and keeps its protection days; a day is used only when it actually spares points.
- **Who receives the points:**
  - Active accounts below `BalanceRecipientMaxPoints`, at most `BalanceMaxPayout` each.
  - Points that cannot be paid out are removed.
  - No inactive account drops below `BalanceFloorPoints`.

### `decay`

- Each inactive account loses 2% of its points above `BalanceFloorPoints` (at least 1 point) per day.
- The points are paid to active accounts as in protection mode.
- Accounts whose player has not joined for `DecayHideAfterDays` are hidden from the ranking and come back as soon as they play.

### `none`

No daily balance.

Both balance modes run only when the server has at least `BalanceMinAccounts` accounts and `BalanceMinRecipients` accounts that can receive points.

**Check points.** Independently of the mode (`none` included) and of `BalanceMinAccounts`, `CheckPointsEnabled` corrects slow inflation or deflation of the server's points once a day. The server should hold `accounts x StartingPoints` points in total:

- Missing points are paid to accounts active within `CheckPointsActiveDays`, at most 25 per account.
- Surplus points are taken from inactive accounts above `BalanceFloorPoints`, in proportion to what they have above it, at most 50 per account; what does not divide evenly comes a point at a time from the richest of them. In `protection` mode an account with protection days is spared here as well, the day it uses its last one included - protection means no losses at all.

**When every inactive account is protected** nothing is taken from anybody that day: the daily balance collects nothing and pays nothing, and a surplus waits. `balance.log` says how much is left over and for how long, and it is taken, a little each day, from the first inactive accounts whose protection runs out (at most `ProtectMaxDays`). A surplus that has waited `CheckPointsMaxWaitDays` (14) is taken anyway, from the accounts that have not played for the longest time, protection or not, at most 50 points each a day; `0` lets it wait for as long as it takes. A deficit is never held up this way: it is paid to active accounts whatever the protection days. Protection days are only used by inactive accounts, and only on days the balance runs (`BalanceMinAccounts`, `BalanceMinRecipients`); playing earns them. Kills and deaths against bots do not count for them.

The daily result is written to `logs/zitrostats/balance.log`.

---

## Accounts and identity

**Automatic identity.** A player is recognised by the SteamID or, without Steam, by the hardware ID.

- **Steam:** the SteamID alone decides. A Steam player always gets the account of that SteamID, whatever computer they play from, and a new one when the SteamID is new here.
- **Without Steam:** the hardware ID decides. The account of that computer is used, and a registered account of that computer only after `/login` or from a trusted computer. A computer that a registered account used before but does not trust gets an account of its own, and the player is told how to log in to the registered one (`/login #id <password>`).
- **One player per account.** When the account of the SteamID or of the computer is already played by somebody on the server, or the game sends no hardware ID, the player records no statistics for that session. Bots get no account.
- **The two are never joined automatically.** A player with Steam and the same player without Steam are two accounts until an admin merges them with `/zs_merge #computer #steam` (the Steam account stays the account; the 4.x keys `AutoMergeHwidIntoSteam` and `MatchByNameForUnregistered` are read and ignored).
- **Late Steam logins:** a player whose Steam answer is still missing has no account yet; after `SteamAuthWaitSeconds` (8) the account of the computer is used, and a confirmation that arrives later moves the session to the Steam account.
- **Several servers:** with `[MySQL] Engine = mysql` these rules hold for every server of the database at once - one account, one password, the same trusted computers everywhere. With `Engine = mirror` each server keeps its own accounts and passwords; only the statistics add up (see [MySQL / MariaDB](#mysql--mariadb)).

**Registration is optional.** An account without a password needs no command at all. `/register` protects the account of a computer with a password (Steam accounts have none):

- **Password storage:** stored as a salted PBKDF2-SHA256 hash (`PasswordIterations`), computed on a background thread.
- **Password rules:** `MinPasswordLength` to `MaxPasswordLength` characters (4-20), no spaces or accented letters, not the account's name, not one repeated character and not a well-known password such as `123456`. Password commands typed in the chat are refused with a warning, because everybody can read the chat.
- **Collecting statistics:** a registered account collects statistics only after `/login`, when its player joins with the account's SteamID, or from a trusted computer.
- **Trusted computers:**
  - A computer used for `/register` or `/login` stays trusted for `TrustedDeviceDays`. With `TrustDeviceSameIP`, it must also be on the same network (first three IP octets).
  - `/account untrust` and `/zs_setpass` remove all trusted computers.
  - `/changepass` and `/resetpass` remove all except the current one; a computer trusted before the password was set or changed is not trusted any more, on every server.
  - An account keeps at most 8; a new one replaces the oldest.
  - `TrustedDevices = 0` turns them off: the password is needed on every join. With `AllowTrustChoice = 1` a player turns them off or on for their own account with `/account trust off` or `/account trust on`.
- **Impostors:** names are free, so another name is no problem. A player on the computer of a registered account who is not logged in (another network, a shared computer or a copied HWID) collects no statistics and is reminded every `LoginReminderSeconds`. After `LoginGraceSeconds` they can be moved to spectators or kicked (`UnauthenticatedAction`, default `none`); `LoginGraceSeconds = 0` does it the moment the account is known.
  - With `UnauthenticatedAction = spectator` the player stays a spectator: every try to join a team sends them back until the password is right.
  - After a successful `/login` they are put into the game again (`LoginReturnToGame`), into the team the balance wants, or the smaller team when the balance is off.
- **Giving up the password:** with `AllowPasswordRemoval = 1` a logged in player can take the password off their own account with `/removemypass <password>`. The account then works like an unregistered one and every player on that computer uses it, so it is off by default.
- **Lockout:** wrong passwords are counted for their source: the computer and the network (first three IP octets) they came from. After `LoginMaxAttempts` wrong passwords within `LoginLockMinutes` that computer or network cannot try this account for `LoginLockMinutes`; the owner on another computer or network is not affected, and a computer of the account itself (the one it was last played on, or a trusted one) counts only for itself on its network, so another player in the same network does not lock it either. After `LoginMaxAttemptsAccount` (20) wrong passwords from all sources together the account is locked for everybody for `LoginLockMinutes` (protection against guessing from many networks). A wrong password older than `LoginLockMinutes` does not add to the counts; wrong passwords in `/changepass` and `/removemypass` count too. A player who cannot log in because of somebody else's wrong passwords is not moved or kicked (`UnauthenticatedAction`): the countdown of `LoginGraceSeconds` starts when the lock ends. `/forgotpass` and `/resetpass` still work and end the lock. A player can send one password command every 2 seconds.

**E-mail recovery.** Configure `[Mail]` (SMTP with curl, sendmail or your own command). Then:

1. `/setemail` (on a registered account, logged in) sends a code, which is confirmed with `/verifyemail`. The address is used only after that.
2. `/forgotpass` - for the account of this computer - or `/forgotpass <name|#id>` from another computer sends a reset code to the verified address. A name finds the registered account without Steam that played most recently under it.
3. `/resetpass` works in the session that asked for the code with `/forgotpass`, or on the computer of that account before logging in (`/login #id` does not choose the account for `/resetpass`).

Codes have 12 characters, expire after `CodeLifetimeMinutes`, and the fifth wrong code makes a code invalid - for a reset code counted on the account, whatever session or join the tries come from. A code is stored only as a hash keyed with the salt of the account's password; changing the password makes a pending code invalid. Each account gets at most one e-mail per `MinIntervalMinutes` and `MaxPerDay` a day; the server sends at most `MaxPerDayServer` (50) a day, and one computer or one network may ask for at most `MaxPerDaySource` (5) a day (accounts are easy to make). The e-mails name the account by its number only, never by a player name. When the server is too busy to take a mail, nothing is sent, nothing counts against these limits and the player is told to try later. Codes of ZitroStats 5.6 still pending at the update are no longer valid: ask for a new one. A mail counts as delivered when the mail program ends without an error:

- **curl:** `SmtpUrl` with `smtps://` (port 465) or `smtp://` (port 587, STARTTLS required). `SmtpUser` and `SmtpPassword` go to curl in a temporary file only the server's user can read, never on the command line, and the file is deleted after the mail.
- **sendmail:** `SendmailPath -t -i` with the message on its input.
- **command:** `CommandTemplate` is split into words first, then the placeholders are filled; the program runs without a shell.

A mail program still running `TimeoutSeconds` + 5 seconds after it started is stopped. Delivery errors are written to `audit.log`, and the player is told that sending failed.

**Privacy.** Public commands never show IP addresses, HWIDs, SteamIDs or e-mail addresses, and exports never contain them. Admins see them in `/zs_status <p>` (the e-mail address masked) and can search by them with `/zs_search`. Passwords and e-mail codes are stored only as hashes; `audit.log` holds the IP address of logins, registrations and password changes.

---

## Seasons, achievements and the HUD

- **Seasons.**
  - A season lasts a calendar month, or `Days` days.
  - When it ends, the best `ArchiveTop` players (50; by points won in the season, then kills) with at least `MinSeasonMinutes` of play are archived, and the top three receive a badge shown in `!achievements` and `!otherstats`.
  - `!topseason` shows the running season and `!topseason <id>` an archived one.
  - `PointsReset` can change the points when a new season starts:
    - `hard` sets everybody back to `StartingPoints`.
    - `soft` sets `StartingPoints + (points - StartingPoints) x SoftResetFactor`.
    - The first season never changes points. The default is no change.
- **Achievements.** 50 goals, announced when unlocked (`AchievementBroadcast`). `!achlist` shows all of them with what they take; [STATISTICS.md](STATISTICS.md) lists the exact conditions.

  | Group | Achievements |
  | :--- | :--- |
  | Kills | First Blood, Soldier, Veteran, Legend, Immortal, Centurion, Headhunter, Finisher |
  | Sprees and multi-kills | Rampage, Godlike, Spree Master, Masta Killa, Butcher, Survivor |
  | Precision and distance | Sharpshooter, Brain Surgeon, Long Shot, Far Sight, Sniper Elite, Wallbanger |
  | Movement | Sky Hunter, High Ground, Globetrotter |
  | Weapons | Blade Master, Grenadier, Demolition, Chainsaw Maniac, Bow Master, Arsenal, Weapon Master |
  | Objectives | Flag Runner, Flag Master, Defender, Flag Hunter, Speed Runner, Iron Wall (CTF, INF), Raider (CTF, INF), Holder (HTF) |
  | Team, rounds and matches | Team Player, Guardian, Winner, Clutch King, Comeback, Round Winner |
  | Modes | Point Hunter (Pointmatch), Rambo Slayer (Rambomatch) |
  | Activity and ranking | Marathon, Regular, Top 10 (needs at least 30 ranked players), Champion (win a season) |

- **Kill streaks.** `[Sprees]` sets the levels of a kill streak: up to 12 (`Level1` to `Level12` as `<kills>, <name>, <style>, <message>`; kills 1-50, name up to 20 characters, message up to 100 - everything after the third comma, so it may hold commas of its own; `style` is `off`, `chat`, `bigtext` or `both`, `both` if left out or not one of these; `%s` the player, `%d` the kills, `%%` a `%`), and `ShutDown` for the message an enemy gets for ending a streak that had reached the lowest level. The first `Level` line found in `settings.ini` replaces every built-in level, the levels are sorted by their kills, and a kills number given twice is ignored. `Enabled = 0` sends no chat line or big text, but the streaks are always counted by their length (`!spree`'s "Kill Streaks - times reached") and the short HUD note (`RAMPAGE!`, `GODLIKE!`, ...) still shows at each configured level. The achievements `Rampage` and `Godlike` are the levels of those names: a player who hears `RAMPAGE!` has reached the `Rampage` achievement too (at the kills of that level; 10 and 25 when no level has the name). The `Shut Downs` statistic and the achievement `Spree Master` (100 streaks of 5 kills) keep to fixed lengths, whatever `[Sprees]` says. Kill streaks are not multi-kills: a streak counts the kills of one life, however long it lasts, while a multi-kill (`!spree`'s "Multi-Kill Medals": Double, Triple, Multi, ...) counts kills that follow each other within `MultiKillWindowSeconds` (3.5). `BigTextSeconds`, `BigTextScale`, `BigTextY` and `Color` style the big text and the chat line.

- **HUD.** A line with rank and points plus short notes such as points won. Players switch it with `!hud`. `[HUD]` sets it up: `Enabled` (0 = no HUD on this server), `DefaultOn` (new accounts start with it on), `X` and `Y` (the position in the 640x480 space of the game), `Scale` (the size of the letters), `Color` (`$RRGGBB`), `Layer` (change it when another script draws on layer 12), `RefreshSeconds` and `EventSeconds` (how long each note after the points - points won or lost, `FIRST BLOOD!`, a multi-kill - stays on the line; 2 seconds).

---

## Exports, webhook and MySQL

Nothing is exported while the database is read-only (see below).

### Files

- **`nickreg/stats.json`** (`JSONExportEnabled`), written every `ExportIntervalMinutes` (the first time one interval after the start) or on `/zs_export`.
  - Contents: the best `JSONExportTopCount` players, every map, weapons, the last three seasons with their best three and server totals.
  - It keeps the 4.x player keys and marks the additions with `"format": 2`.
  - The `*_px` distance keys hold whole pixels (14 pixels = 1 meter), the `*_m` keys the same distance in meters with one decimal.
- **`nickreg/players.json`** (`FullExportEnabled`), started together with `stats.json` and built a part every timer run, so the engine does not stop for it (a few seconds for thousands of accounts); the parts go to `players.json.part`, and the finished file replaces `players.json` at once. Also with `"format": 2`. Every account with detailed statistics, weapons, modes, achievements and badges, among them `league`, `mmr_ffa` / `mmr_team` / `mmr_ctf`, `through_cover_kills` (live), `through_cover_shot_kills`, `base_defense_kills`, `base_attack_kills`, `forced_suicides`, `suicides_under_fire`, `best_life_distance_m`, `balance_moves`, `balance_volunteers`, `healed_hp` (regen + kits), `regen_hp`, `heal_kits` (medical, berserker and predator kits that healed), `kits` (every kit picked up) and `kit_pickups` (the kits picked up by kind: `medical`, `grenade`, `cluster`, `vest`, `berserker`, `predator`, `flamer`), what the [server bridges](#server-bridges) tell (`collateral_kills`, `back_kills`, `back_deaths`, `longest_headshot_m`, `longest_bullet_flight_sec`, `longest_hit_m`, `avg_hit_dist_m`, `avg_hit_flight_sec`, `avg_kill_flight_sec`, `stance_shots` and `stance_hits` - standing, crouching, prone, in the air), and per weapon the reloads (`reloads`, `reloads_finished`, `killed_reloading`, `avg_reload_sec`) and the same four of the hits and kills.
- In `stats.json` the maps have `votes_started`, `votes_won`, `voted_in`, `stayed_pct`, `players_by_time` (the average number of players in each tenth of a match; `null` where there is no data) and (5.6) `longest_hit_m`, `avg_hit_dist_m`, `avg_hit_flight_sec`, `avg_kill_flight_sec`, and the weapons `picks_alpha` ... `picks_delta` and (5.6) `longest_hit_m`, `avg_hit_dist_m`, `avg_hit_flight_sec`, `avg_kill_flight_sec`.

Files are written through a temporary file and replaced in one step, so a website never reads half a file. Neither file contains IP addresses, hardware IDs, SteamIDs or e-mail addresses.

### Webhook

`[Webhook]` sends an HTTP POST with a JSON body, using curl from `[Mail] CurlPath`; the `Url` must start with `http://` or `https://`. A post fails on an HTTP error or after 15 seconds without an answer; failed posts are not repeated and not logged. Events:

| Event | When it is sent |
| :--- | :--- |
| `export` | Top 10 of the points ranking on every export run, `/zs_export` included |
| `match` | Map, mode, length, team scores with the winner, and the 10 players with the most kills of every counted match |
| `season` | The top 10 of a season when it is archived |
| `record` | A new online peak, reported once it has not grown for five minutes |

`Format = json` (default) sends the event as JSON. `Format = discord` sends the same event as a readable message for a Discord webhook URL (`https://discord.com/api/webhooks/...`): cut to 1900 characters (Discord takes 2000), markdown in player names shown as typed, and no `@everyone` pings from a player name.

### MySQL / MariaDB

`[MySQL] Engine` says where the statistics live:

| Engine | What it does |
| :--- | :--- |
| `local` (default) | The files alone. No database, nothing shared. |
| `mirror` | The files are the statistics; a copy goes into the tables `zs_players`, `zs_maps` and `zs_server` for a website (with `[Matrix] Enabled = 1` also `zs_player_map_stats`), and five switches let several servers of the database add up what they know. |
| `mysql` | One database for every server: the accounts, maps, server record and seasons of all servers are the same, and each server sees the games of the others within two exchanges (every `SyncSeconds`). |

Without `Engine`, the older `Enabled = 1` means `mirror`. Every server of one database needs its own `ServerID`. Without a `Host` the statistics stay in the files (`Engine = local`) and the console says so. The database itself has to exist; ZitroStats makes the tables in it, so the user needs the right to create and alter tables.

**Which engine?** For most servers the best choice is `mysql` (several servers sharing one live database) or `local` (a single server, files only). `mirror` is for a different job: a read-only copy of a server's statistics for a website, or adding up the statistics of separate servers that each keep their own accounts.

#### Engine = mirror

The tables are made on the first run; a table that is already there gets the columns it lacks.

- **Updates:** every `MirrorIntervalSeconds` it sends the players on the server, the accounts that played recently and all maps, many rows per statement, in one transaction. Every account is sent in each run until one succeeds, and then once an hour. While the database cannot be reached, the pause between tries doubles up to 15 minutes.
- **Deleted accounts:** such a full run also deletes the rows it did not write again, so accounts removed or merged here disappear from the copy as well.
- **Everything of an account:** `FullJson = 1` adds the complete statistics of every account as JSON in the column `zs_players.data`. Handy for a website that wants every number; each full run then sends a few MB per 1000 accounts.
- **Several servers:** every row carries the `ServerID`, so more than one game server can share one database.
- **Statistics added up over several servers:** five switches, each off by default and each on its own, let the servers of one database add up what they know. A server with a switch on also writes what the others need - the record of its accounts (`zs_players.steam_id`, `shared_data`), of its maps (`zs_maps.shared_data`) and of the server with the sum of all its accounts (`zs_server.shared_data`, `shared_sum`) - and after every pass reads what the others wrote. The record of an account goes without its login data: no password hash or salt, e-mail, IP, HWID, SteamID, trusted computers, codes or login counters. The numbers of the others are at most about two `MirrorIntervalSeconds` old (the other server writes them with its pass, this one reads them after its own), and every hourly full pass sends the whole record of every account and map, so a change without a game, such as the daily balance or a reset, reaches the others within the hour. While the database cannot be reached, the server shows what it read last. A Steam account is the same account on every server; an account without Steam is the account of the same computer (HWID; `steam_id` then holds `H:` and an MD5 of the computer, for a registered account the computer it last played from; when one server has two accounts of one computer, only one carries that key - the one without a password, else the older one - and the other is not shared) - as on one server, where names are free and the same nick on another computer is somebody else. Passwords stay on each server: an account registered here is registered only here (with `Engine = mysql` it is registered everywhere).

  | Switch | What adds up |
  | :--- | :--- |
  | `SharedProfiles` | `!stats`, `!otherstats`, `!allweapons`, `!allweaponsby`, `!wep`, `!spree`, `!rambo`, `!achievements`: what the other servers hold for the same player - 2 kills on one server and 2 on another show 4 on a third, and the name says `[3 servers]` (this server included). Points, ratings, seasons, badges, rivals and the per-map data of `[Matrix]` stay this server's. The older name `SharedStats` works too. |
  | `SharedRankings` | `!top`, `!topby`, `!topday`, `!topweek`, `!topmonth`, `!topo` and the positions of the `i` commands: every server's players, ranked by the points won on all of them (above the starting points, so every server needs the same `StartingPoints`); players known only to the others are listed as well (`-` in the tier column). `!stats`, `!status`, `!rank`, `!session` and `!zs_search` show that place and those points; the titles say `of All Servers`. `!statsi <n>` shows the player at place n even when they never played here: their numbers of all servers (points, kills, deaths, K/D, time played) and a note. Tiers, `!topskill`, seasons and the HUD stay this server's, and `!zs_search` finds only this server's accounts. |
  | `SharedMaps` | `!topmaps`, `!topmapsby`, `!mapstats`, `!heatmap` and the map's own counters in `!mapmatchup`, `!mapweapstats` and `!mapwep`: the map of the same name on the other servers. A map played only on the others is listed too. |
  | `SharedWeapons` | `!serverweapons`, `!serverweaponsby`, `!serverwep`, `!topweapons`, `!topweaponsby` and `!matchup`. |
  | `SharedServer` | `!server`, `!activity`: the activity, the online peak, the matches, the combat numbers and the weapons. Visitors, returning players and the hall of fame stay this server's. |

The files stay the source of truth; the tables can be dropped at any time. `source_dll/tests/test_mysql.pas` runs the mirror against a database of your own and reads every table back (`test_mysql <host> <port> <database> <user> <password>`).

#### Engine = mysql: one database for every server

- **Everything is shared.** Points, ratings, weapons, medals, achievements, rivals, maps, the server record (activity, online peak, hall of fame) and the seasons: `!stats` on any server shows the games of all of them, `!top` ranks every player of every server, and an account has the same number everywhere. The five switches of the mirror are not needed.
- **Nothing waits for the database.** Every server keeps all of it in memory, as with the files: commands, rankings and the HUD read memory. A thread of its own exchanges the changes every `SyncSeconds` (3); the engine hands a batch over and takes the answer on a later tick, and the game thread never waits for it. Only a stop of the server or of the script waits a few seconds at most for the last changes.
- **Nothing is overwritten.** What changed on a server goes in as a three-way merge: the thread locks the rows, reads what the others wrote, puts this server's changes since the last exchange on top and writes the result. Counters and points add up (kills made at the same moment on two servers too), a record keeps the better value, a name, a rating or a password takes the newest change (the hash, salt, rounds and date of a password always come together from the server that changed it), achievements and badges are joined, and the names used and the trusted computers are merged as sets: what one server removed (`/changepass`, `/resetpass`, `/account untrust`, a name over `NameHistoryLimit`) stays removed. The writers take turns on one row of `zs_db_meta`, so any number of servers can write at once.
- **One account on every server.** A player is recognised as on one server: by the SteamID, or without Steam by the computer (HWID) - names are free, so the same nick on another computer is another account. A password set with `/register` on one server works with `/login` on every server (after the next exchange of both servers), and so do the e-mail, `/forgotpass`, the trusted computers and the lock of the whole account after `LoginMaxAttemptsAccount` wrong passwords (the lock of one computer or network is kept by each server for itself, and so are the daily limits of `[Mail] MaxPerDayServer` and `MaxPerDaySource`).
- **Times.** The times of the account's security (locks after wrong passwords, e-mail codes, trusted computers, the date of the password, the last e-mail) are kept in UTC, so servers in different time zones read them alike. Run 5.7 on every server of one database: 5.6 keeps them in the server's local time. At the update, a lock or a wait between e-mails running at that moment may last once up to the time zone's offset longer.
- **New players.** A player new on two servers at once becomes one account: always with the same SteamID, and without Steam with the same computer unless the account already in the database has a password (a registered account is joined by logging in). New accounts take their numbers from the database, 200 at a time per server; an account numbered while the database does not answer can get a new number at the next exchange.
- **The first start of a server** brings its files along: an account with the same SteamID is added to the account that is there (Steam accounts have no password); without Steam, an account of the same computer is added unless both have a password (two owners stay two accounts; `/zs_merge` joins them); every other account gets a number of the database. The first server (it finds `zs_db_accounts` empty) keeps its numbers. Maps of the same name and the server records add up; of two running seasons only the one with the higher number goes on, and an archived season goes in when the database has none of that number. A server whose first start with `Engine = mysql` does not reach the database runs on its files and exchanges nothing until it is started again while the database answers; that start joins it. The console and `/zs_status` say so.
- **Jobs of the whole database** (the daily balance of inactive accounts, the change of a season) run on one server only: the first one that finds a job due takes it at its exchange (`zs_db_jobs`) and runs it with its own settings, so keep `StartingPoints`, `[Inactivity]` and `[Seasons]` the same on every server.
- **Without the database** a server works from its files and sends what it collected once the database answers; the pause between tries doubles up to half a minute. What has not gone in yet is kept beside the files (`zitrostats.shared` in `DataPath`, for this `ServerID` and `Database` only) when the server stops, and every half a minute while the database does not answer; the next start sends it before it reads the database. A crash loses what had reached neither the database nor that file: the changes since the last exchange, or up to about half a minute of them while the database does not answer.
- **The files** stay a cache of the database: every start with the database writes them again.
- **`/zs_restore` is refused:** a backup of one server's files cannot take the place of the database - also when the files of a server cannot be read: move the damaged files away and restart, the start reads the database. Restore the database itself (from its own dump), or start with `Engine = local` first. After a restore of the database, restart every server: the console warns that the change counter of `zs_db_meta` went back.
- **Status:** `/zs_status` shows the exchange: connected (with the exchanges and changes so far), not answering, not reached yet, or off until the next start.
- **Tables** (InnoDB; another table engine is refused): `zs_db_accounts` (`id`, `steam`, `hwid_key` for an account without Steam, `name`, `points`, `kills`, `deaths`, `playtime_sec` and `last_seen` for a website; the whole record in `data`; a removed account keeps its row with `deleted = 1`, and `merged_into` names the account it went into; `data` holds the whole account, its login data included - password hash and salt, e-mail, HWID, IP, trusted computers -, because the servers share the passwords: give a website's database user SELECT on the statistics columns only, e.g. `GRANT SELECT (id, name, points, kills, deaths, playtime_sec, last_seen) ON zs_db_accounts TO 'web'@'...'`, never on `data`), `zs_db_maps`, `zs_db_server`, `zs_db_seasons`, `zs_db_meta`, `zs_db_jobs` and `zs_db_player_maps` (the per-map player records of `[Matrix]`, keyed by account id and map name, merged the same three-way as the accounts).
- `source_dll/tests/test_sqldb.pas` runs three servers against a database of your own (`test_sqldb <host> <port> <database> <user> <password>`), a restart without the database included.

#### Both

- **Settings:** after `/zs_reload` the mirror starts again with changed `[MySQL]` settings; `Engine = mysql` takes them at the next start of the server, and a running exchange says so on the console.
- **Console:** the mirror writes `[ZitroStats] MySQL: ...` lines (`connected to ...`, `mirror failed: ...`; the same error at most every 10 minutes), `Engine = mysql` writes `[ZitroStats] shared database: ...` lines. An error the database itself answers reads `MySQL error <n>: <text>`.
- **Timeouts:** 5 seconds to connect and 30 seconds for every answer. A slower answer (a busy database, a lock another server holds) counts as a lost connection (`the connection to the database was lost (no answer)`); the next try opens a new one.
- **No client library.** ZitroStats speaks the MySQL protocol itself, so the 32-bit server writes into any MySQL or MariaDB - 32- or 64-bit, on the same machine or another one - without `libmysql.dll` or `libmysqlclient.so`. Tested against MySQL 8.4 and MariaDB 11.4 with the login methods servers use: `caching_sha2_password` (the MySQL 8 default, including the first login after a server start, when the password is sent encrypted with the server's RSA key) and `mysql_native_password`; `sha256_password` works with the server's RSA key as well. What it does not do is an encrypted (TLS) connection: a user made with `REQUIRE SSL` or a server with `require_secure_transport = ON` refuses the login, and the console shows the answer of the database (for `REQUIRE SSL` that is `Access denied`). So the statistics, the account records and the login cross the network unencrypted, and the server's RSA key is taken without a check: reach a database on another machine through a LAN, a VPN or an SSH tunnel. Other login methods (MariaDB's `ed25519`, PAM, LDAP and the like) are not supported either.
- **Text:** the tables are `utf8mb4`; player and map names are converted from `[General] SourceCodepage`. Values are sent as hex literals, so no name a player chooses can change a statement.

---

## Files, backups and admin safety

- **Journal and snapshots.**
  - Player statistics go to the journal every `JournalFlushSeconds`, map and server totals once a minute.
  - A new snapshot is written `CompactIntervalMinutes` after the last one (when anything changed) or when the journals since it reach `CompactJournalMB`. Both count over restarts and `/recompile`: the time from the date of the last snapshot, the size from the journals on disk since it, so a server restarted often still folds its journals. A start writes no snapshot by itself. `/zs_perf` and `/zs_status` show the journal since the last snapshot (`KB since snapshot`), the runs before this one included.
  - The previous snapshot is kept as `zitrostats.zsdb.prev`, together with the journals it needs.
  - A damaged snapshot or journal end is detected by checksums, and the last good state is loaded: the previous snapshot with its journals, or a journal up to its damaged end. A journal file found under the number that is about to be used is never appended to; it is renamed to `*.journal.<date>.old`.
  - A journal that cannot be written makes ZitroStats write a full snapshot instead.
  - When the server stops or the script is recompiled, the events queued before are applied (3 seconds at most), the time on the names of the players still on the server is added, and only the journal is written; the next start replays it after the last snapshot. A snapshot or backup that is still being written is dropped; a due automatic backup runs again after the next start.
- **A database that cannot be read.** With `RestoreOnDamage = 1` (default) the unreadable files (snapshot, `.prev`, `.tmp` and journals) are renamed to `*.damaged-<date>` - never deleted - and the newest readable backup from `BackupPath` (`nickreg/backup/`) becomes the live database. With `RestoreOnDamage = 0`, or when no backup can be read, the server only reports it and saves nothing until an admin runs `/zs_restore <file>`, which is allowed in that state (not with `Engine = mysql`, where the start reads the shared database). A file another program holds open cannot be renamed: the console names it, and such a journal is never emptied or replayed. A locked folder (see below) gets neither the automatic restore nor `/zs_restore`.
- **A database of a newer ZitroStats.** A snapshot written by a newer release (a higher file format) is not damaged: it is left as it is, never replaced by a backup (also not with `RestoreOnDamage = 1`), and the library stays read-only and saves nothing. Use `main.pas` and the library of that release.
- **One server per data folder.** `zitrostats.lock` stops a second server from using the same `DataPath`. That server prints `ERROR: data directory ... is locked or not writable (...) - statistics are NOT saved`, keeps nothing and exports nothing. The same happens when the data cannot be loaded.
- **Backups.**
  - Backups are saved in `BackupPath` as `zitrostats-YYYYMMDD-HHMMSS-auto.zsdb`, `-manual.zsdb` (`/zs_backup`) or `-before-<operation>.zsdb`. Each is a complete snapshot. A second backup made in the same second gets a number before the reason (`zitrostats-YYYYMMDD-HHMMSS-2-<reason>.zsdb`, `-3-` ...), so no backup overwrites another and the automatic ones still end in `-auto.zsdb`.
  - Automatic backups run every `AutoBackupDays` (default 14, 0 = off), the first one right after the first start; the newest `BackupKeep` automatic backups are kept. A date of the last automatic backup more than a day in the future (a clock that was wrong) counts as due: the backup runs at once.
  - Backups made with `/zs_backup` and `before-<operation>` backups stay until you delete them.
  - `/zs_backups` lists the 10 newest; `/zs_restore <file>` restores one (refused with `[MySQL] Engine = mysql`, see [MySQL / MariaDB](#mysql--mariadb)).
- **Two-step admin operations.** Resets, restores, merges, `/zs_unregister`, `/zs_setpass` and `/removeolderthan` need:
  1. The command says what will happen.
  2. The same admin confirms within `ConfirmSeconds` with `/yes <ConfirmPassword>`.
  3. A backup named `before-<operation>` is saved before the operation runs (not for `/zs_setpass`, which changes one password, and not while the database is read-only).

  A wrong password - or `!yes <text>` typed in public chat - locks `/yes` for `ConfirmLockMinutes` and cancels the operation that was waiting; `/yes` typed without a password is only a hint to use `/yes <ConfirmPassword>`. While an operation waits for one admin's `/yes`, another admin's operation is refused until it is confirmed, cancelled or its `ConfirmSeconds` are over; an admin who starts a new one replaces his own waiting operation and is told so. The server console and every admin connected over TCP (Soldat Admin) count as one admin: one of them can confirm what another started.
- **Audit log.** With `AuditLog = 1`, `audit.log` records every admin command - ZitroStats' and Soldat's own - with the admin's name, IP address and account (the server console and TCP admins as `console`, without an address; the passwords of `/yes`, `/zs_setpass`, `/password` and `/adminlog` and the text of `/pm` are written as `***`), confirmed admin operations, account events and e-mail errors. Internal errors go to `errors.log` (at most 10 lines a minute of each place and kind of error, then one line with how many more there were). Line breaks and other control characters in names and texts are written as `?` in every log. `crash.log` records every serious exception of the server process (any module: the server, Steam, a script library) with module, address, registers, a stack trace and the last events of ZitroStats; a C++ exception also with the place that raised it. Exceptions that Free Pascal code raises and catches itself (code E0465043) are not written; one that nothing catches is written before the process ends (`not caught by any handler: the process ends`).

---

## Colours

Every colour ZitroStats writes in the game is a setting, so the output can match the rest of
your server. They live in `[Colors]` in `settings.ini` and are written as `RRGGBB` (a `#`, a
`$` or a `0x` in front is allowed). A line left out keeps the built-in colour.

| Setting | Default | Where it is used |
| :-- | :-- | :-- |
| `ColorHeader` | `FFD700` | the title line of a table |
| `ColorSubHeader` | `00E5FF` | the section lines inside a table |
| `ColorCombat` | `55FF55` | kills, deaths, streaks |
| `ColorShooting` | `FFFFFF` | shots, hits, accuracy |
| `ColorFeats` | `FFB703` | sprees, achievements, records |
| `ColorObjective` | `FFA500` | flags, points, admin commands |
| `ColorTeamplay` | `FF6B6B` | assists, team damage, balance |
| `ColorMatches` | `A8E6CF` | matches, rounds, wins |
| `ColorActivity` | `B0C4DE` | time played, visits, rules |
| `ColorHint` | `80D0FF` | the legends under a table |
| `ColorTop1` / `ColorTop2` / `ColorTop3` | `FFD700` / `E0E0E0` / `CD7F32` | the first three places |
| `ColorYou` | `00FF66` | the row that is you |
| `ColorOtherRow` | `9BD0E8` | the other rows of a ranking |
| `ColorBad` | `CC3300` | something went wrong |
| `ColorGood` | `66CC66` | something worked |
| `ColorWarn` | `FF8C00` | something to notice |
| `ColorRankLine` | `00E5FF` | the rank line of a profile |

A colour that is not a hex number from `000000` to `FFFFFF` is refused with a line in the console
and the built-in one is used, so a typo never leaves the output unreadable. Write all six digits:
`FFF` is read as `000FFF`.

---
## Building from source

Requirements: Free Pascal 3.2 for **i386**, because the Soldat server is 32-bit. On 64-bit Linux that is the official `fpc-3.2.2.i386-linux.tar` (it has every package the library uses; the i386 packages of Debian and Ubuntu do not), `binutils` and the 32-bit C library files (`libc6-dev-i386`):

```bash
sudo apt-get install binutils libc6-dev-i386
wget https://downloads.sourceforge.net/project/freepascal/Linux/3.2.2/fpc-3.2.2.i386-linux.tar
tar xf fpc-3.2.2.i386-linux.tar && cd fpc-3.2.2.i386-linux && sudo ./install.sh
```

```bat
cd scripts\ZitroStats-Core\source_dll
build.bat            :: zitrostats_dll.dll
build.bat debug      :: range and overflow checks, line numbers in crash.log
```

```bash
cd scripts/ZitroStats-Core/source_dll
sh build.sh          # zitrostats_dll.so
sh build.sh debug    # range and overflow checks, line numbers
```

`build.sh` writes the new library beside the old one and renames it over it: a running server keeps the library it loaded; the new one takes effect when the server starts again.

`build.sh` first compiles a small library with the same units. When a package is missing it names the unit and says how to get it, instead of stopping the real build halfway (`Can't find unit StrUtils` means the packages of FPC are not installed or not in `fpc.cfg`). `FPCUNITS=/usr/local/lib/fpc/3.2.2/units/i386-linux sh build.sh` reads the packages from that folder whatever `fpc.cfg` says.

MySQL - the mirror and the database of every server - is always part of the library and needs nothing else on the server.

The scripts compile into `source_dll/build/` and copy only the finished library into the script folder. `clean.bat` / `clean.sh` remove `build/`.

The tests in `source_dll/tests/` are plain programs, for example:

```bash
mkdir -p build/test
fpc -Mobjfpc -Sh -Fu. -Fi. -FUbuild/test -FEbuild/test tests/test_engine.pas
```

`test_dll` takes the path of the built library as its argument. Two programs are not tests but tools:
`tests/test_fuzz.pas` throws truncated, scrambled and random files at the storage and the settings reader,
and `tests/bench_db.pas [accounts]` times the heavy paths on a large ranking (60000 accounts by default).

---

## Troubleshooting

| Message or problem | Cause and fix |
| :--- | :--- |
| `ERROR: zitrostats_dll could not be started (code -15)` (or another negative number) | `main.pas` and the library come from different releases: the library answers with its own API number, negative (17 for ZitroStats 5.7), when `main.pas` speaks another one. Copy both again and delete `main.psb`. A library of an older release is reported this way too: `main.pas` 5.7 loads with it (the newer calls are delay-loaded) and says so at the start instead of ScriptCore's `Cannot Import`; `main.pas` then keeps the account commands out of the console log (see [Commands](#commands)). |
| `ERROR: zitrostats_dll could not be started (code 0)` | The library could not start its engine; nothing of it keeps running. Look at the console lines before it. |
| `WARNING: the admin token was already taken - admin commands are disabled until the server restarts.` | Another script called the reserved `ZS_Claim_Token` first. Remove that script and restart the server. |
| Changes to `main.pas` have no effect | The server runs `main.psb`, the compiled script of the old version: delete it and restart the server. |
| Script error about `zitrostats_dll` or an unknown external | The library is not in `scripts/ZitroStats-Core/`, the folder was renamed, or `AllowDlls` is off. |
| Linux: `Cannot Import dll` and `cannot restore segment prot after reloc: Permission denied` | SELinux (Fedora, RHEL, CentOS in enforcing mode) refuses a library whose code the loader has to relocate, as the `.so` built by `build.sh` does. Allow it once: `chcon -t textrel_shlib_t scripts/ZitroStats-Core/zitrostats_dll.so`. Debian and Ubuntu load it as it is. |
| `ERROR: data directory ... is locked or not writable (...) - statistics are NOT saved` | Another server uses the same `DataPath`, or the folder is not writable. |
| `ERROR: the database in ... could not be read` | The data files are damaged (or there are journals without a snapshot). With `RestoreOnDamage = 1` ZitroStats renames them to `*.damaged-<date>` and continues from the newest readable backup by itself; otherwise, or when no backup can be read, use `/zs_backups` and `/zs_restore <file>`, which work in this state. |
| `ERROR: loading failed: ... - statistics are NOT saved` | An error stopped the loading; the text says which. No backup is loaded and `/zs_restore` is refused: fix the cause and restart. |
| `ERROR: the database in ... was written by a newer ZitroStats` | The files come from a newer release. They are left as they are and nothing is saved: use `main.pas` and the library of that release. |
| `ERROR: import of ... failed` | The 4.x accounts file cannot be read. Nothing is saved: fix or remove the file and restart. |
| A line `library ... (... bytes, sha256 ...)` at start | Normal: it says which file the server really runs. A `WARNING` after it means the library was loaded from another folder. |
| "Cover (live)" or "Cover (shot)" looks wrong | With `[Bridges] MapGeometry` the library casts the rays on the map file: `/zs_perf` says whether it read it (`map walls: ...`). Without it, set `[Debug] RayCastLog = 1`, `/zs_reload`, and kill a bot: every kill prints what `Map.RayCast` answered for both lines and how the kill was counted. |
| `bridges: hook CreateBullet not found` / `... holds other code` / `memory: not available: ...` in `/zs_perf` | The server is not the Soldat 2.8.2 build the library knows, or another program changed its code there: the script reads the players itself, as before 5.6. Nothing to do; `[Bridges] ServerHook = 0` and `MemoryReads = 0` stop the attempts. |
| `The server's memory is not read any more (/zs_perf tells why)` | The check once a second found a player whose properties differ from the server's memory (`memory: off: soldier <n>: <what> differs ...`). The script reads the players itself until the server restarts; please report the line. |
| `MySQL: ... Access denied` or `shared database: ... Access denied` | The user, the password or the host part of the user (`'user'@'%'`, `'user'@'localhost'`) do not match, or the user was made with `REQUIRE SSL` (ZitroStats does not speak TLS); the same login has to work with `mysql -h <host> -u <user> -p` with TLS turned off. |
| `... the server wants the password method ...` | The user was made with a method ZitroStats does not speak (MariaDB's `ed25519`, PAM, LDAP): give it `mysql_native_password` or `caching_sha2_password`. |
| `... cannot reach the database` | Host or port wrong, the database server is down, or a firewall is in the way. The mirror and `Engine = mysql` try again on their own. |
| `... the connection to the database was lost (no answer)` | The database closed the connection, or took longer than 30 seconds to answer (busy, or waiting for a lock). The mirror and `Engine = mysql` try again on their own. |
| `... Unknown database ...` | The database named in `[MySQL] Database` does not exist: create it (`CREATE DATABASE soldat_stats`); ZitroStats makes only the tables. |
| `shared database: ... so nothing is exchanged until ... started again ...` | The first start with `Engine = mysql` did not reach the database (`has not joined the database yet`), or joining it or reading it back failed. Restart the server while the database answers; one that has not joined yet joins then. After `reading it back failed`, what the server collects until that restart does not reach the database. |
| `shared database: ... needs InnoDB` | A `zs_db_*` table uses another table engine: run the `ALTER TABLE ... ENGINE = InnoDB` the line names. |
| The server stops without a message | Look at `logs/zitrostats/crash.log`. From the start of the server (the line `ZitroStats 5.7 diagnostics started` with the time) it records every serious exception of the server process - in any module, the server, Steam or a script library - with module, address, registers, a stack trace and the last events of ZitroStats, and a Free Pascal exception that nothing caught. If the last start has no record after its line, the process ended without such an exception (closed, killed) or ZitroStats was not running; on Linux the file is not written. |
| `Set ConfirmPassword in the [Admin] section of settings.ini ...` | Every operation confirmed with `/yes` (resets, restores, merges, `/zs_unregister`, `/zs_setpass`, `/removeolderthan`) needs `[Admin] ConfirmPassword`. |
| A team score jumped and went back, or a capture did not count | The score guard took a point back that the server gave for a join, a team change, a double capture or a match without opponents; the line is in `integrity.log`. `[Integrity] Enabled = 0` turns it off. |
| A player was moved to the other team, or could not join a team | The team balance. `/balinfo` shows every player's strength and the last decisions (all of them are in `teambalance.log`); `/bal off` pauses it, `[Balance] Enabled = 0` turns it off. |
| `WARNING: scripts/... looks like another team balancer` | Two balancers move players against each other: turn one of them off. |
| No e-mails | Check `[Mail] Enabled = 1`, a valid `FromAddress` (otherwise the console warns at start and e-mail stays off) and curl, sendmail or your command; delivery errors are in `audit.log` (`mail: delivery failed`). `/forgotpass` needs an address verified with `/verifyemail`, `MinIntervalMinutes` and `MaxPerDay` limit the e-mails of each account, `MaxPerDayServer` those of the server and `MaxPerDaySource` those one computer or network asks for (`audit.log` says when the server reached its limit). |
| `Please wait N s before the next search or page.`, `The server is busy with other lists, try again in a moment.` | The limits of the heavy lists: `[Commands] SearchCooldownSeconds` and `HeavyCooldownSeconds` per player, three lists a second on the whole server (see [Commands](#commands)). |
| `Wait a moment - your last answers are still being sent.` | 300 or more lines of the player's earlier answers still wait to be sent; the command is answered once they are out. |
| `Logins to this account from here are locked for N min.` | `LoginMaxAttempts` wrong passwords came from this computer or network; the owner elsewhere can still log in, and `/forgotpass` works. |
| `settings.ini: [section] key=value ...` lines in the console | A key is misspelt or a value is invalid or out of range; the line says what is used instead. |

For scripts that read statistics from ZitroStats see [DEVELOPER_API.md](DEVELOPER_API.md).

---

## Changes in 5.7

5.7 fixes what an audit of 5.6 found. Replace `main.pas` and the library together (API 17; on Linux build the `.so` again) and delete `main.psb`; the `settings.ini` of 5.6 works as it is, the new keys take their defaults.

**What a server owner notices**

- **`/recompile` in the middle of a map** goes on with the match: no round won or lost, no Hold the Flag points and no second `FIRST BLOOD!` out of the score so far, and no new load of the map. The events of the last moment before it are applied, the time on the names of the players online is kept, and a `/recompile` in the first seconds after the start stops the loading cleanly.
- **`/pause`** counts no time played, alive, with a weapon or with a flag, and the team balance waits.
- **Survival:** a kill a script makes with `Player.Damage(V, 4000)` (Basic-Extended's `/slay`, `/killall`, bleeding out, the team-kill punishment) is a real death and a selfkill; the round point it gave stays.
- **Rankings by metrics** show `-` for a share or an average made of too few, listed last (`[Commands] MinSamplePercent`; the minimums are in [STATISTICS.md](STATISTICS.md#minimum-samples)). `!top <text>` takes a metric only by its whole name, and a player on the server called like a metric is that player.
- **Limits:** a page of a heavy list and a name looked for in every account wait `[Commands] SearchCooldownSeconds` (2) per player; a name no account has is answered at once for 10 seconds; the admins on the server have one list a second that no player can take; `!topby`, `!topmapsby` and `!topweaponsby` without a metric show their help at once. Every player's answers wait in a queue of their own (`Wait a moment ...`), and kicks and team moves are never held back by text.
- **Team balance:** `!switch` once a minute, and a switch that evens nothing uses no change of `MaxMovesPerMap` and starts no cooldown; two `!switch` or `!join` in the same moment no longer both go; in Teammatch with `TeammatchTeams = auto` one player alone in Charlie or Delta pulls nobody after him; a player out of a team the mode does not have goes where the balance wants him; with fewer than `MinPlayers` humans in the teams a join or a switch is never refused for strength or a lock, only for uneven numbers, and the balance moves nobody.
- **Map vote:** `[MapVote] GapSeconds` (60) after every vote, whoever starts the next.
- **Admins:** an operation waiting for another admin's `/yes` is not taken over; the console and TCP admins count as one admin; `/removeolderthan` says before `/yes` how many accounts go and how many of them are Steam accounts (nothing to delete: nothing asked); `/zs_merge` refuses to merge a Steam account into one without Steam and takes the password of `#from` along when only it has one; `!searcha` in the chat is refused (use `/searcha`); admin rights given or taken in the game reach ZitroStats within a second.
- **Accounts:** wrong passwords lock only the computer and the network they came from; the whole account is locked after `[Accounts] LoginMaxAttemptsAccount` (20), and a player locked by others is not kicked. E-mail codes have 12 characters and are stored as a hash keyed with the account's salt - codes of 5.6 pending at the update are no longer valid; the fifth wrong reset code ends it, counted on the account; `/login #id` no longer opens `/resetpass` for that account; the server sends at most `[Mail] MaxPerDayServer` (50) e-mails a day and one computer or network asks for at most `MaxPerDaySource` (5); the e-mails no longer name the player; a password change ends the trust of every computer trusted before it, also with `Engine = mysql`.
- **Files:** `CompactIntervalMinutes` and `CompactJournalMB` count over restarts and `/recompile` - the first start after the update may fold the old journals into a new snapshot at once; a start writes no snapshot by itself. Two backups in the same second get numbers; an automatic backup dated in the future is due at once. `players.json` is built in parts and replaces the file when complete. `errors.log` takes at most 10 lines a minute of each error; control characters in the logs are written as `?`.
- **crash.log** works again (5.6 never started it): a line at every start of the server, every serious exception of the process, and a Free Pascal exception nothing caught; the exceptions Free Pascal code catches itself are not written.
- **MySQL:** the mirror's `zs_players.shared_data` holds no login data; with `Engine = mysql` the security times are UTC (run 5.7 on every server of the database), the parts of a password come together from the server that changed it, and computers and names removed on one server stay removed.
- **MySQL connection:** the code that speaks the MySQL protocol (`mysqlwire.pas`, the same file as in AntiFake 2.1) refuses an RSA key of the server over 8192 bits or with an exponent over 4 bytes and an answer over 64 MB, and cutting a connection also stops a login that is still computing with that key. Nothing changes for a database that answers normally.
- **`[Matrix] MatrixMapPruneDays`** (new, 0 = never): prunes the per-map records of maps an account left and the rivals it no longer meets; `MatrixPruneDays` works as before. `/zs_status` shows the records of `[Matrix]` and their size.
- **Bridges:** with `ServerHook = 0` and `MemoryReads = 1` the hits and kills are measured from where their bullet was made again (5.6 lost the hit distances and air times then).
- **Linux:** `build.sh` no longer copies over the loaded library (that crashed a running server); the new one is used from the next start. SELinux: see [Troubleshooting](#troubleshooting).
- **Older library:** `main.pas` 5.7 loads with a library of 5.5 or 5.6 and says that they do not belong together; when the library does not start, `main.pas` keeps the account commands (passwords) out of the console log.

**Bugs fixed besides:** the season podium shows `+25 pts` (5.6 printed the name again); a `weapons.ini` with a zone modifier of 0 no longer stops the counting of that weapon's hits; the engine's ticks go on after about 414 days of server uptime; a full event queue no longer drops team changes, kills or Steam answers; a script's bullet made at the victim (Basic-Extended finishing a bleeding or downed player) gives the kill no distance; two different commands of a player in the same tick are both answered; `/zs_maps` no longer shows the whole path of the maps folder; a long text a player typed is cut in the answers; `!serverweapons`, `!server` and `!serverwep` use the sums of up to 10 seconds ago for players (the console counts anew); many accounts of one name no longer slow the start down; a big journal is written in 4 MB portions; the bullets of the last tick before a `/recompile` still count.

**New keys of `settings.ini`**

| Section | Key | Default | Range | What it does |
| :--- | :--- | :--- | :--- | :--- |
| `[Commands]` | `SearchCooldownSeconds` | 2 | 0-60 | A page of a heavy list or a name looked for in every account once per this many seconds per player |
| `[Commands]` | `MinSamplePercent` | 100 | 0-1000 | Scales the minimum a share or an average needs in the rankings by metrics (0 = none) |
| `[Accounts]` | `LoginMaxAttemptsAccount` | 20 | 1-1000 | Wrong passwords from all sources before the whole account is locked (at least `LoginMaxAttempts`) |
| `[Mail]` | `MaxPerDayServer` | 50 | 1-100000 | E-mails the server sends a day |
| `[Mail]` | `MaxPerDaySource` | 5 | 1-1000 | E-mails one computer or one network may ask for a day |
| `[MapVote]` | `GapSeconds` | 60 | 0-3600 | Pause after every vote of a map before the next one |
| `[Matrix]` | `MatrixMapPruneDays` | 0 | 0-3650 | Prune per-map records by the map and rival entries by the last fight (0 = never) |

**For other scripts and libraries** (API 17, [DEVELOPER_API.md](DEVELOPER_API.md)): `ZS_API_Get_Player_Stat` and `ZS_API_Get_Player_Rank` give 0 for a player not logged in to his registered account; the new `ZS_API_Top_Player_Copy2` adds the computer of the account for AntiFake; the reserved calls of `main.pas` changed (`ZS_Ev_Tick` with the pause, `MF_RUNNING`, `ZS_Ev_Admin`).
