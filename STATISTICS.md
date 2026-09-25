# ZitroStats 5.2 - Statistics reference

This document lists every statistic ZitroStats 5.2 collects, how the code counts it and where it is shown. It is written from the source code (`source_dll/`, `main.pas`). Setting names are given as `[Section] Key`; the values in brackets are the ones in the shipped `settings.ini`.

## Contents

1. [Basics](#basics)
2. [Where to look](#where-to-look)
3. [Command outputs](#command-outputs)
4. [Metrics for !topby, !topweaponsby and !topmapsby](#metrics-for-topby-topweaponsby-and-topmapsby)
5. [Achievements](#achievements)
6. [Ratings, points and leagues](#ratings-points-and-leagues)
7. [Team balance](#team-balance)
8. [Exports](#exports)
9. [Counted but only in exports or the API](#counted-but-only-in-exports-or-the-api)

---

## Basics

### When statistics are counted ("statistics are on")

The code checks a condition called `StatsOn` at the moment of every event (kill, hit, shot, flag event, and once per second for time counters). Statistics are on when all of these are true:

- The library has finished loading its data.
- At least `[Ranking] MinHumansForStats` (2) human players are in the game. Spectators do not count.
- The line-up is filled (`TeamsFilled`):
  - Team modes (TM, CTF, INF, HTF): if `[Ranking] MinTeamPerSide` (0 = off) is above 0, the two teams with the most human players must each have at least that many humans.
  - Free-for-all modes (DM, PM, RM): if `[Ranking] MinFFAHumans` (0 = off) is above 0, at least that many humans must be in the game.

Time alive and the longest life use a stricter condition, `SurvivalOn`: statistics are on and at least `[Ranking] MinHumansForSurvival` (2) humans are in the game.

The score guard (`[Integrity]`) takes team points back that Soldat gives for a join, a team change, a double capture or a match without an opposing team. What it takes back is never counted: the capture is no capture, and the kill the server makes to end a survival round or to stop somebody joining alive is no death, no selfkill and no loss of points (Soldat counts no death for it either).

A few things are counted even while statistics are off: spectator time, the play and spectator time stored with each name of an account, map joins, leaves, kicks, spectator joins, map loads, map votes and their results, the players over the match, match durations, aborted matches, the online peak, the number of server sessions per day and the form on the map that the team balance uses.

### Whose statistics are counted

- A player records statistics only when the session is bound to an account that records statistics:
  - A Steam player gets the account of the SteamID once Steam confirms it (the library waits up to `[Identity] SteamAuthWaitSeconds`, 8). Until then the player records nothing. Without a confirmation in that time the account of the computer is used, and a later confirmation moves the player to the Steam account.
  - A player without Steam gets the account of the computer (HWID).
  - A password-protected account records nothing until `/login` or from a trusted computer. The HUD then says `Not logged in - stats are not saved`.
  - If the account is already used by another player on the server, or the game sent no HWID, nothing is recorded for that session.
- Such players still count as humans for `MinHumansForStats` and the other limits.
- If the database could not be read, statistics are still counted in memory but not saved, and there is no daily balance and no export.

### Bots

- `main.pas` sends shots, grenades, knife throws, position samples, spawns, weapon changes, kit pickups and flag events only for human players. Kill and damage events are sent only when at least one human takes part.
- The library counts a kill, death, hit, damage, assist, teamkill or selfkill only when the players involved are human. A kill by or of a bot gives no points, no kill, no death, no map kill, no heat map cell, no weapon matchup and no distance data.
- Bots never count toward `MinHumansForStats`, `MinHumansForSurvival`, `MinTeamPerSide`, `MinFFAHumans` or the online peak.
- Bots have no account, so they never get match results, ratings or achievements, and they are never the winner of a free-for-all match.
- Bots still affect some counters of humans: team scores (match results, rounds in CTF Survival, HTF team points), a bot teammate can be the protected or avenged player of a Savior or Avenger kill, and a hit by a bot on a flag carrier starts the Contested Hold timer.
- Whether a bot lives is not known (a bot sends no spawn and no position). So at the end of a Survival round in TM, INF and HTF a team with a bot counts as standing, and in DM/PM/RM with a bot in the game a round ends only when no human of it lives or when the server kills the last one standing.

### Definitions used below

| Term | Meaning in the code |
| :--- | :--- |
| Counted kill | A kill of an enemy (another team in TM, CTF, INF, HTF; any other player in DM, PM, RM) while statistics are on, where killer and victim are humans whose accounts both record statistics. Only counted kills move points and feed kill counters, feats, map kills, heat maps and weapon data. |
| Enemy hit | A damage event from a human to an enemy human while statistics are on, where the shooter's account records statistics. Damage that is not from the shooter's own bullet (fall, lava, script) is ignored. |
| Friendly hit | The same between two humans of the same team in a team mode. It is counted whether or not friendly fire is on. |
| Self hit | Damage players do to themselves with their own weapon. |
| Damage | Hit points of one hit, capped at the health the victim had before the hit (when known) and never more than `[Mechanics] MaxHealth` (150, or `MaxHealthRealistic` 65 in Realistic). |
| Assist | Given at a counted kill to every other human enemy of the victim (in team modes anybody on another team than the victim) whose account records statistics, whose last hit on the victim came at most `[Mechanics] AssistSeconds` (7) before the kill and who did at least `AssistMinDamagePercent` (65) % of the full health (`MaxHealth`, `MaxHealthRealistic` in Realistic) as damage in the victim's current life. Counted in every mode; several players can get an assist for the same kill. |
| Kill distance | Meters from where the lethal shot was fired to where it hit. The shot is the killer's newest shot of the same weapon that could have reached the hit in time (for straight bullets, one that lies behind the bullet in its direction of flight), so moving while a projectile flies (nade boost, M79 jump) does not change the distance. Knife, chainsaw, fists and the stationary gun measure from where the killer stood at the kill. A kill whose shot is not found has no distance and is left out of the longest and average distances. |
| Accuracy weapons | USSOCOM, Desert Eagles, HK MP5, AK-74, Steyr AUG, Spas-12, Ruger 77, Barrett M82A1, FN Minimi, XM214 Minigun and Rambo Bow. `Shots` and `Hits` (overall accuracy) use only these. The Stationary Gun has its own counter (`M2 MG Hits`) and is not part of the accuracy, because its shots are not detected. |
| Shots | Detected by `main.pas` when the ammunition of the primary weapon drops (never for knife or fists). One shot per bullet: Desert Eagles count 2 per ammo, Spas-12 6. A magazine that drops to 0 with several rounds still in it was reloaded with the reload key: those rounds are thrown away, not fired, and are not shots (see Reload). Commands show `max(shots, hits)` as shots. |
| Reload | Soldat tells scripts nothing about reloading, so it is read from the ammunition of the weapon in hand. A magazine at 0 is being reloaded and the jump back to a full magazine ends the reload; the Spas-12 loads shell by shell. `main.pas` asks for the reload key only in the tick a magazine runs empty, which tells a reload with one round left from the last shot. A reload with rounds left is *manual*. A reload ends once: finished, broken off (the weapon was thrown away, or changed and not taken up again - a reload taken up again goes on where it stood, as in the game, and still ends once; a shot of the Spas-12 stops its loading and breaks it off too) or by the death of the player. A kill the server makes itself (a team change in Survival, the end of a round), a respawn, a team change, a map change, leaving and `/loadwep` end a reload without counting it anywhere. A weapon taken with an empty magazine (picked up, or given by a script) starts a reload at once. Its length is measured in game ticks and compared with `ReloadTime` of `weapons.ini` (`weapons_realistic.ini` in Realistic, or the file `/loadwep` loaded; a Realistic switch while a map runs is noticed within a second). The ammunition of a human arrives from the game a few ticks late, so a refill that comes more than 15 ticks early is only believed when the game's late "empty" does not follow; such a reload counts as finished but not in the times, and neither does one that went on after a weapon change. Counted for USSOCOM, Desert Eagles, HK MP5, AK-74, Steyr AUG, Spas-12, Ruger 77, M79, Barrett M82A1, FN Minimi, XM214 Minigun, Chainsaw, M72 LAW and both bows; not for the knife, the flamer, the stationary gun, fists or grenades. A `Game.LoadWeap` of another script is not seen. |
| Hit zone | Head, body, legs or unclear. Only hits of plain bullets, shotgun pellets, Rambo Bow arrows and the stationary gun have a zone. They are classified from the damage and the weapon's head/chest/leg modifiers (`weapons.ini`, `weapons_realistic.ini` in Realistic). Weapons whose three modifiers are not all different (for example Barrett) use a learned model of where hits land (per victim posture, after 40 samples per zone). A hit of these weapons that cannot be matched is "unclear". Explosives, flames, melee and thrown knives have no zone at all and are not counted as unclear either (data saved by older versions may still hold such hits among the unclear ones). |
| Hurts / special hits | The weapon counters in `!otherstats`, `!allweapons` and `!wep` (knife stabs, saw hurts, nade hurts ...) count damage events, not shots. |
| Life | From spawn to death. A map change also ends a life without counting a death. So does a kill by the server itself (Survival: the end of a round, a team change mid-round, the players still standing after a capture): it is no death and no selfkill, and the kill streak goes on in the next life on the same map. |
| Current mode | The game mode and switches of the map that is running when the command is typed. Many rows depend on it, not on where the numbers were collected. |

### Units and formats

- Distances are in meters: pixels / 14 (`PIXELS_PER_METER`). Some settings are in pixels (`CampRadius`, `EscortRadius`, `HeightAdvantagePixels`); `[CaptureTheFlag] BaseRadius` is in meters.
- Times are in seconds. The game runs 60 ticks per second; `main.pas` sends one clock event per second and the time counters add 1 per event.
- Durations are printed as `1d 2h`, `2h 3m`, `3m 4s` or `4s`. Play time in `!stats`, `!status` and `/zs_status` uses the longer form `1d 2h 3m` or `2h 3m 4s`.
- Percentages have one decimal and never exceed 100%. `K/D` is kills / max(1, deaths) with 2 decimals.
- Counters in the command answers (kills, deaths, shots, hits, damage, points, visits ...) and signed point changes (`Season: +7.7M pts`, `Pts Delta: -12.3k`) are written in full below 10 000 and shortened above, never wider than five characters plus the sign: `12.3k`, `123k`, `4.5M`, `45.6M`, `456M`, `1.2B`. The unit is chosen after rounding, so 999 960 is `1.0M`, not `1000k`, and 9 999.7 is `10.0k`. Ids, ranks, positions, pages, slots, dates, percentages and small counts stay in full, and so do the points of the HUD line and of the welcome line.

### Game modes, switches and rating families

| Number | Mode | Kind | Rating family (`RankingFamily = auto`) |
| :---: | :--- | :--- | :--- |
| 0 | DM Deathmatch | free-for-all | FFA |
| 1 | PM Pointmatch | free-for-all | FFA |
| 2 | TM Teammatch | team | Team |
| 3 | CTF Capture the Flag | team, objective | CTF |
| 4 | RM Rambomatch | free-for-all | FFA |
| 5 | INF Infiltration | team, objective | Team |
| 6 | HTF Hold the Flag | team, objective | Team |

- `FamilyFor` uses `RatingFamilyOf`: DM, PM, RM = FFA; CTF = CTF; every other mode (TM, INF, HTF) = Team. `[Ranking] RankingFamily = ffa`, `team` or `ctf` puts every mode into that family.
- `main.pas` sends the Survival, Realistic, Advance and Friendly fire switches at every map start.
- "Objective mode" in the tables below means CTF, INF or HTF.

---

## Where to look

`[p]` = nothing for yourself, a name or part of it, or `#id`. `<pos>` = position in the points ranking. `<pg>` = page. Player commands work with `!` in the chat and with `/`, except `info` and `pm`: ZitroStats answers them only in the chat (`!info`, `!pm`), because `/info` and `/pm` are Soldat's own commands.

| Command or output | What it shows | Game modes / mode-dependent parts |
| :--- | :--- | :--- |
| `!zitro`, `!help`, `!commands`, `!cmds`, `!info`, `!reginfo`, `!credits`, `!autor`, `!tworca` | Every command with its arguments. | `!pm` is listed only in PM, `!rambo` and `!ramboi` only in RM, the team balance commands only in team modes. Password commands only for players without Steam (`/removemypass` only with `AllowPasswordRemoval = 1`), admin commands only for admins. |
| `!stats [p]`, `!statsi <pos>` | Main profile. | Team row only in team modes; flag row in objective modes or with flag data; Rambo row in RM or with bow data; Survival and Friendly fire change some cells. |
| `!otherstats [p]`, `!otherstatsi <pos>` | Detailed profile in 13 sections. | CTF section in objective modes or with flag data; HTF row in HTF or with HTF data; cells change with Survival, Realistic and Friendly fire; ratings of the current family. |
| `!status [p]`, `!statusi <pos>` | Play time, dates, account type and, for any player on the server, the live session. | none |
| `!rank [p]`, `!ranki <pos>`, `!ranknum <pos>` | One line with rank, points, rating, K/D. | Rating depends on the current mode. |
| `!session`, `!today` | Your counters since you joined the server; a map change does not reset them. | none |
| `!spree [p]`, `!spreei <pos>`, `!pointmatch [p]`, `!pm [p]` | Kill streaks and multi-kill medals. | Title and `PM Bonus` cell depend on PM. |
| `!rambo [p]` | Rambomatch counters. | Counted only in RM. |
| `!achievements [p]`, `!ach`, `!badges`, `!achievementsi <pos>`, `!achi`, `!badgesi` | Unlocked achievements and season badges. | none |
| `!achlist [p]`, `!achievementslist`, `!achlisti <pos>`, `!achievementslisti` | All 50 achievements with their goal. | none |
| `!allweapons [p]`, `!weapons`, `!allweaponsi <pos>`, `!weaponsi` | Table of all weapons and the special weapon counters. | Bow rows and the flamer/bow row are always shown in RM. |
| `!allweaponsby <metrics> [p]`, `!weaponsby`, `!allweaponsbyi <metrics> <pos>`, `!weaponsbyi` | The weapon table of `!allweapons`, sorted by weapon metrics. | Bow rows always shown in RM, as in `!allweapons`. |
| `!wep <weapon> [p]`, `!weapon`, `!wepi <weapon> <pos>`, `!weaponi` | One weapon of one player plus server-wide data for it. | Hit zone row not for explosives. |
| `!serverweapons`, `!serverweps`, `!srvweapons`, `!srvweps` | The weapon table of the whole server: every account added up. | Heavy list (one per `HeavyCooldownSeconds`). |
| `!serverweaponsby <metrics>`, `!serverwepsby`, `!srvweaponsby`, `!srvwepsby` | The weapon table of `!serverweapons`, sorted by weapon metrics. | Heavy list; `!serverweaponsby help` is free. |
| `!serverwep <weapon>`, `!serverweapon`, `!srvwep` | One weapon for the whole server, with the top killer and the best accuracy. | Heavy list; `!serverwep help` is free. |
| `!matchup [weapon] [pg]`, `!matchups`, `!matrix` | Weapon against weapon results of the whole server, in pages. | none |
| `!topweapons [pg]`, `!topweps`, `!topweaponsby <metrics>`, `!topwepsby` | Weapon rankings. | none |
| `!top [pg]`, `!topp <pg>`, `!top <name>`, `!topi <pos>`, `!topme`, `!topid <slot>` | Points ranking, or the part around a player or position. | Rating column depends on the current mode. |
| `!top <metrics>`, `!topby <metrics> [pg]` | Ranking by up to 5 metrics. | `rating`, `tier`, `skill`, `mmr`, `glicko`, `openskill` use the current mode or family. |
| `!topo`, `!toponline` | Players on the server, by points. | none |
| `!topday`, `!topweek`, `!topmonth` `[pg]` | Best players of the day, ISO week, month. | none |
| `!topskill [pg]`, `!toprating` | Rating list of the current family. | Family from the current mode; with `RankingSystem = elo` the MMR list. |
| `!topseason [id]`, `!seasons [pg]` | Season standings and archive. | Needs `[Seasons] Enabled`. |
| `!zs_search <text>`; admins: `/zs_search`, `/searcha` | Account search. | none |
| `!v`, `!vote`, `!nextmap`, `!lastmap`, `!randommap`, `!map [map]`, `!votemap`, `/votemap` | The map vote: vote yes, or start one. | Needs `[MapVote] Enabled`; a command switched off in `[MapVote]` gets no answer. |
| `!maps [pg\|map]`, `!allmaps [pg\|map]`, `!searchmap <part> [pg]` | The maps list with the next and the last map; every map of the maps folder (with a map, both open at the page that has it); the maps of both whose name holds a text. | `[MapVote] Enabled` |
| `/zs_mapvote [cancel]`, `/zs_maps [rescan]` | The map vote's settings and state; the maps folder and its problem files. | admins |
| `!mapstats [map]` | Map record. | Sections depend on data and the current mode; leaders only for the running map. |
| `!heatmap [map]`, `!heat` | Picture of where kills and deaths happen. | Flag bases are only known in CTF and INF. |
| `!topmaps [pg or map]`, `!topmapsp <pg>`, `!topmapsi <pos>`, `!topmapsby <metrics>` | Map rankings. | Last column of `!topmaps` is `Selfs` in DM/PM/RM and `Flags` in team modes. |
| `!server`, `!serverstats` | Visitors, activity, server totals, hall of fame. | `FF Index` cell only with friendly fire on. |
| `!activity` | Play time by weekday and hour. | none |
| `!hud` and the HUD line | Rank and points on screen with short event notes. | Hidden for spectators. |
| `!contact` | The contact text from settings. | none |
| `!bal`, `!teams`, a chat line that is only `bal` | Team balance: players, strength and chance of every team, what the balance does, your strength. | Team modes only (TM, CTF, INF, HTF). |
| `!switch`, `!join` | Change to the weaker team (not with a flag; in survival only while dead); a spectator joins the team that needs a player. No statistic except `Volunteered`. | Team modes only. |
| Chat messages | Welcome, achievement unlocked, round won, match over, season end and start. | Round messages only with Survival. |
| `/zs_status` (no argument) | Library status. | admins |
| `/zs_status <p>`, `/zs_statusid <id>`, `/zs_statusi <pos>` | Account audit. | admins |
| `/zs_suspects` | Suspicious kill series and the daily scan notes. | admins |
| `/zs_perf` | Engine timing and data sizes. | admins |
| `/balinfo` | Team balance details: settings, every player's strength and form, predictions, last decisions. | admins, team modes |
| `/zs_status` | Library status; with `score guard:` the points and captures the guard took back (see `integrity.log`). | admins |
| `stats.json` | Website export: top players, maps, weapons, seasons. | `server.mode` names the current mode. |
| `players.json` | Every account with detailed statistics. | none |
| Webhooks | Events `export`, `match`, `season`, `record`. | `match`: team scores and winner only in team modes. |
| MySQL | The mirror: tables `zs_players`, `zs_maps`, `zs_server`. One database for every server: the tables `zs_db_*`. | With `[MySQL] Engine = mirror` or `mysql`. |
| Developer API | 40 StatIDs and helper functions for other scripts. | StatIDs 4, 35, 36 and 39 depend on the current mode. |
| Logs | `balance.log` (daily balance), `suspicious.log`, `audit.log`, `teambalance.log` (decisions of the team balance), `teambalance-history.log` (matches recorded for tuning), `integrity.log` (what the score guard took back). | none |

Lists that go through every account (`!topby`, `!top <metrics>`, `!topday`/`week`/`month`, `!zs_search`, `!server`, `!serverweapons`, `!serverweaponsby`, `!serverwep`, `!topweapons`, `!topweaponsby`, `!topmapsby`, and `!topskill` with `elo`) are limited to one per `[Commands] HeavyCooldownSeconds` (5) per player and three per second on the whole server; admins have no per-player limit.

---

## Command outputs

### !stats

Header: `[ Stats: <name> ]`.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Rank: <n> (<tier>)` | Position in the points ranking (`-` if the account is hidden from it, see decay). The bracket holds the league (with `[Leagues] Enabled = 1`) or the tier. | always; bracket only when a name exists |
| `Points:` | Current points. | always |
| `Rating: <x>` | Rating index for the current mode and switches (`[Ranking] RatingMode`). It is not points. | always |
| `Kills:` | Counted kills. | always |
| `Deaths:` | Counted deaths (killed by an enemy). | always |
| `K/D Ratio:` | Kills / max(1, deaths). | always |
| `Best Streak:` | Most counted kills in one life (in Survival a streak goes on after a round end, see `Max Streak` in `!otherstats`). | always |
| `Avg Life:` | Time alive / max(1, ended lives). The ended lives are the counted deaths, the deaths by a teammate and the selfkills; a life ended by a bot, by the server or by a map change adds its time but is not counted. | always |
| `Dmg Ratio:` | Damage dealt / damage received (0 if nothing was received). | always |
| `Dealt: <x> (~<y> kills)` | Damage dealt in enemy hits; y = damage / the full health of the current mode (`[Mechanics] MaxHealth` 150, or `MaxHealthRealistic` 65 in Realistic), so "kill equivalents". | when damage dealt or received is above 0 |
| `Taken: <x> (~<y> deaths)` | Damage received in enemy hits; y = damage / full health, as above ("death equivalents"). | same |
| `TK Dmg:` | Damage dealt in friendly hits. | third cell of that row in team modes, when friendly fire is on or the account has friendly damage; blank in a team mode otherwise |
| `Assists:` | Assists. | third cell of that row instead, outside team modes (shown once: team modes show it in the row below) |
| `Healed:` / `Regen:` / `Heal Kits: <n> (<hp> HP)` | Health got back, all told; from regenerating polygons (the healing fields of RSCS maps); from medical, berserker and predator kits, with how many of them healed. Capped at the full health of the current mode. | when the account has healing |
| `Dmg/min alive:` | Damage dealt x 60 / time alive. | when time alive is above 0 |
| `Kills/min alive:` | Kills x 60 / time alive. | same |
| `Longest Life:` | Longest life, counting only seconds when `SurvivalOn` was true. | same |
| `Longest: <x>m` | Longest counted kill. | when the longest kill is above 0 |
| `Barrett: <x>m` | Longest Barrett kill. | same |
| `Avg Dist: <x>m` | Sum of kill distances / number of kills that have a distance. | same |
| `Accuracy:` | Hits / shots, accuracy weapons only. | always |
| `Hits: <h>/<s>` | Enemy hits with accuracy weapons / shots. | always |
| `Headshots: <n> (<x>%)` | Head hits on enemies and their share of `Hits`. ` est.` is added when more than 5% of the account's zone hits are unclear, so the zone shares are partly estimated. | always |
| `Matches: <w>W / <l>L` | Match wins and losses. | always |
| `Win%:` | Wins / (wins + losses). | always |
| `Rounds: <w>W / <l>L` | Survival rounds won and lost. | third cell when the current map has Survival on or the account has rounds |
| `Pace: <x> kills/h` | Kills x 3600 / play time. | third cell otherwise |
| `Flag Caps: <n>` | Flag captures. | in objective modes, or when the account has captures, returns or grabs |
| `Returns:` | Flag returns. | same |
| `Held: <time> (Grabs: <n>)` | Time alive carrying a flag; flag grabs. | same |
| `Playtime:` | Play time: seconds on a team while statistics were on (alive or dead). | always |
| `Spectator:` | Seconds in the spectator team (counted also while statistics are off). | always |
| `Selfkills:` | Selfkills. | always |
| `Teamkills:` / `TK Deaths:` / `Assists:` | Teamkills made; deaths by a teammate; assists. | team modes, when friendly fire is on or the account has teamkills |
| `Assists:` / `First Blood:` / `Clutches:` | Assists; first bloods; clutches won. | team modes without the row above; `Clutches:` when the current map has Survival on |
| `First Dmg:` | Times the account dealt the first enemy damage of a match or round. | replaces `Clutches:` without Survival |
| `Knife Throws:` | Knife throws. | when throws + stabs are above 0 |
| `Knife Hits:` | Thrown knife hits on enemies. | same |
| `Knife Stabs:` | Knife (melee) hits on enemies. | same |
| `Bow Kills:` | Kills with a bow (Rambo Bow or Flamed Arrows) in RM. | in RM, or when the account has Rambo kills or bow kills |
| `Bow Time:` | Seconds alive holding a bow in RM. | same |
| `Rambo Kills:` | Kills of a player who held a bow, in RM. | same |
| `MMR:` / `Glicko-2:` / `OpenSkill:` `<value> (<n> games)` | The value of `[Ranking] RankingSystem` for the current family: MMR, Glicko-2 rating - ConservativeFactor x RD, or OpenSkill mu - 3 x sigma; `unrated` without games. | only when `RankingSystem` is `mmr`, `glicko2` or `openskill` |
| `Season: <+n> pts` | Points won or lost in the running season. When a new season starts, every account starts again at 0. | with `[Seasons] Enabled = 1` or a season stored on the account |
| `Season K/D: <ratio> (<k>/<d>)` | Counted kills and deaths in that season, and their ratio. | same |
| `Achievements: <n>/50` | Unlocked achievements. | always |
| `Protect: <n> days` | Protection days. | only with `RankingSystem = elo` (takes the place of the skill cell) |

### !otherstats

Header: `[ Detailed Telemetry: <name> ]`. The sections follow in this order.

#### Damage Telemetry & Kill Equivalents

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Dmg Dealt: <x> (~<y> kills)` | Damage dealt in enemy hits; y = damage / full health of the current mode (see `!stats`). | always |
| `Dmg Taken: <x> (~<y> deaths)` | Damage received in enemy hits; y = damage / full health of the current mode. | always |
| `Dmg Ratio:` | Dealt / taken. | always |
| `Healed:` / `Regen:` / `Heal Kits: <n> (<hp> HP)` | Health got back, all told; from regenerating polygons (the healing fields of RSCS maps); from medical, berserker and predator kits, with how many of them healed. Capped at the full health of the current mode. | always (`!stats` shows this row only once there is some) |
| `Kits: Med <n>, Nade <n>, Cluster <n>, Vest <n>, Berserk <n>, Predator <n>, Flamer <n>` | The kits picked up, by kind: medical, grenade, cluster, vest, berserker, predator and flamer kits. Counted for every kit a human picks up while statistics are on, whether it did anything or not (a medical kit that healed also counts in `Heal Kits`). | always, every kind also at 0 |
| `TK Dmg Out:` | Damage dealt in friendly hits. | friendly fire on and friendly damage in or out above 0, or the account has teamkills or deaths by teammates |
| `TK Dmg In:` | Damage received in friendly hits. | same |
| `TK Kills/Deaths: <a>/<b>` | Teamkills made / deaths by a teammate. | same |

#### Top Encounters & Rivals

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Fav Victims:` | Up to three accounts this player killed most, with counts (`None` if empty). Only three names are kept: a new name replaces the weakest of the three and starts again from its first kill, so counts can be too low (kills before a name was dropped are lost). | always |
| `Top Nemeses:` | Up to three accounts that killed this player most, counted the same way. | always |

#### Hitzones, Aim & Distance

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Head: <n> (<x>%)` | Head hits on enemies; share of `Hits` (accuracy weapons). | always |
| `Body: <n> (<x>%)` | Body hits on enemies; share of `Hits`. | always |
| `Legs: <n> (<x>%)` | Leg hits on enemies; share of `Hits`. | always |
| `Longest Kill: <x>m` | Longest counted kill. | always |
| `Longest Barrett: <x>m` | Longest Barrett kill. | always |
| `Avg Kill Dist: <x>m` | Average distance of kills that have a distance. | always |
| `100m+ Kills:` | Counted kills from 100 m or more (any weapon). | always |
| `Barrett Long:` | Barrett kills from 75 m or more. | always |
| `Unclear Zone:` | Enemy hits of bullets, pellets, arrows and the stationary gun whose zone could not be worked out (see Hit zone). | always |

#### Timing, Movement & Positioning

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Avg TTK: <x>s` | Average time to kill: from the killer's first hit on the victim in the victim's current life to the kill. | always |
| `Best TTK: <x>s` | Shortest such time (at least 1 tick). | always |
| `Longest Life:` | Longest life (survival seconds only). | always |
| `Traveled: <x> km` | Distance moved while alive on a team with statistics on. Position samples 5 times per second; jumps over 250 px (teleports) are ignored. | always |
| `Dist/Life: <x> m` | Traveled meters / (ended lives + 1). | always |
| `Best Life: <x> m` | Most meters moved in one life. | always |
| `Fly Time:` | Seconds in the air while jet fuel was being used (sampled 5 times per second, added in whole seconds). | always |
| `Air Kills:` | Counted kills while the killer was not on the ground (and not prone). | always |
| `Height Kills:` | Counted kills where the killer was more than `[Mechanics] HeightAdvantagePixels` (60) above the victim. | always |
| `Prone Kills:` | Counted kills made lying down. | always |
| `Camp Kills:` | Counted kills after the killer stayed within `CampRadius` (80 px) for `CampSeconds` (12) in the current life. | always |
| `Vest Kills:` | Counted kills of a victim who wore a vest. | always |
| `Spawn Kills:` | Counted kills of a victim who spawned at most `SpawnKillSeconds` (3) ago. Never in Survival: everybody spawns together at the start of a round. | hidden when the current map has Survival on and the account has neither (survival has no spawn kills) |
| `Spawn Deaths:` | Counted deaths at most `SpawnKillSeconds` after spawning. Never in Survival. | same |

#### Combat Feats & Streaks

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Max Streak:` | Most counted kills in one life. A death, a selfkill and a map change end the streak; a kill by the server in Survival (round end, team change) does not, so a streak can go on over several rounds. | always |
| `First Bloods:` | First counted kill of a match; with Survival, of each round. | always |
| `First Damage:` | First enemy damage of a match (or of a Survival round). | always |
| `Dominations:` | Times this player killed the same player 3 times in a row (without being killed by that player in between; the count restarts at map start). | always |
| `Revenge Kills:` | The first kill of a player who killed this player since this player last killed them (an open revenge ends at map start). | always |
| `Dominations Ended:` | Counted kills of a player who had 3 or more kills in a row on this player. | always |
| `Last Stand:` | Team modes with Survival: a death (not a kill by the server) left this player as the last living human of the team while at least 2 enemy humans lived; once per team and round. DM/PM/RM: the player was the last human alive in a Survival round. | when the current map has Survival on or the value is above 0 |
| `Clutches Won:` | Team Survival: a round won by the team whose last-stand player this was. Not counted in DM/PM/RM, where the last one standing gets `Last Stand`. | when the current map has Survival on in a team mode, or the value is above 0 |
| `Saviors:` | Team modes: counted kills of a player who had hit a teammate of the killer within `SaviorSeconds` (3). | in team modes, or when the value is above 0 |
| `Avenger Kills:` | Team modes: counted kills of a player who had killed a teammate of the killer within `AvengerSeconds` (2). | same |
| `Comeback Wins:` | Team match wins where the winning team had been 2 or more points behind the leader at some point (tracked each second while statistics were on). | same |
| `Assists:` | Assists. | always |
| `Posthumous:` | Counted kills made while the killer was already dead. | always |
| `Finishers:` | Counted kills with USSOCOM, Desert Eagles, knife, thrown knife, chainsaw, LAW, flamer or fists within `FinisherSeconds` (3) after the killer's last hit on this victim (in its current life) with MP5, AK-74, AUG, Spas-12, Ruger, M79, Barrett, Minimi or Minigun. | always |
| `Shut Downs:` | Counted kills of a player whose current streak was 5 or more. | always |
| `Nade Kills:` | Counted kills with frag or cluster grenades. | always |
| `Bink Recovery:` | Counted kills of a player who hit the killer within `BinkSeconds` (1.0) before and did at least `BinkDamage` (35) damage to the killer during the killer's current life. Counted in every mode. | instead of `Pace` when the current map has Realistic on or the value is above 0 |
| `Pace: <x> kills/h` | Kills x 3600 / play time. | instead of `Bink Recovery` otherwise |
| `Explosive Multi:` | Times a second kill came from the same explosive weapon (M79, LAW, grenade, cluster, flamed arrows) within 3 ticks of the first. | always |
| `Knife Streak:` | Most knife kills (melee and thrown) in one life. | always |
| `Cover (live):` | Counted kills where `Map.RayCast` found no clear line from the killer to the victim at the moment of the kill. Not for knife, chainsaw, fists or non-weapon damage. Counted only after `main.pas` has worked out which answer of `Map.RayCast` means a clear line on this server; until then no kill is Cover (live) or Cover (shot). | always |
| `Cover (shot):` | Counted kills where the line from where the lethal shot was fired to where it hit was blocked. `main.pas` answers a tick later; the kill needs a known firing position, and an answer that arrives after a map change is dropped. Not for melee or fists. | always |
| `Forced Selfkills:` | Selfkills of enemies whom this player hit last within `AssistSeconds`. Counted only when the zerosum rule applies (`SelfkillMode = zerosum`, `SelfkillAssistShare` above 0), also when the enemy had no points left to lose. It is not a kill. | always |
| `Selfkills: <n> (<x>%)` | Selfkills and their share of the ended lives. `[Ranking] SelfkillPercentBase` decides what the share is of: `all` (default) every ended life, `enemy` only the deaths caused by opponents. | always |

#### CTF & Objective Telemetry

The whole section is shown in objective modes (CTF, INF, HTF), or when the account has captures, returns, grabs, drops, flagger kills or flag time.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Flag Caps:` | Flag captures reported by the server. | section |
| `Flag Returns:` | Flag returns. | section |
| `Flag Grabs:` | Flag grabs, from the base or from the ground. | section |
| `Flag Drops: <n> (<m> thrown)` | Flags dropped (n; a carrier who dies drops the flag) and thrown (m); the two are counted separately. | section |
| `Flagger Kills:` | Counted kills of a flag carrier. | section |
| `Flagger Assists:` | Assists on a kill of a flag carrier. | section |
| `Flag Defense:` | Savior kills where a teammate the victim had hit carried a flag. | section |
| `Kills w/ Flag:` | Counted kills made while carrying a flag. | section |
| `Flag Hold:` | Seconds alive carrying a flag (any mode). | section |
| `Fastest Cap: <x>s` | Shortest time from the capper's last grab to the capture (only times of 0.5 s or more count); `-` if none. | section |
| `Caps under 10s:` | Captures less than 10 s after the capper's last grab (a capture under 0.5 s is not timed and does not count). | section |
| `Escort Kills:` | Team modes: counted kills where a living human teammate carrying a flag was within `EscortRadius` (350 px) of the killer or the victim. | section |
| `Flag Juggles:` | Grabs within `JuggleSeconds` (1.5) after the same player dropped or threw a flag. | section |
| `Contested Holds:` | HTF only: the player kept the flag for `ContestedHoldSeconds` (5) after an enemy first hit them while they carried it. | section |
| `TK flagger: <a> / w/flag: <b>` | Teamkills of a teammate who carried a flag (a); teamkills made while carrying a flag (b). | section |
| `Base Defense:` | CTF and INF, killer on Alpha or Bravo: counted kills where the victim was within `BaseRadius` (30 m) of the killer's own flag base. | section |
| `Base Attack:` | Same modes: counted kills where the killer was within `BaseRadius` of the enemy flag base. | section |
| `Base Radius: <n> m` | The `[CaptureTheFlag] BaseRadius` setting, not a statistic. | section |
| `HTF Points:` | HTF: points the team scored while this player was its living flag carrier. | when HTF points or HTF hold time are above 0, or the current mode is HTF |
| `HTF Hold:` | HTF: seconds alive carrying the flag. | same |
| `HTF Team:` | HTF: seconds alive while a living player of the own team (this player included; carriers are known only for humans) carried a flag. | same |

Flag bases are the positions `main.pas` reports every 5 seconds while a flag stands in its base (CTF and INF only); they are saved with the map record. Base Defense, Base Attack and the `A`/`B` marks of the heat map need them.

#### Matches & Competitive Standings

The section is shown when the account has wins, losses or draws, or the current mode is a team mode.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Matches Won:` | Match wins. | section |
| `Matches Lost:` | Match losses (including leaver losses). | section |
| `Win Rate: <x>% (<n>d)` | Wins / (wins + losses); n = draws. | section |
| `Rounds Won:` | Survival rounds won. | when the current map has Survival on or the account has rounds |
| `Rounds Lost:` | Survival rounds lost. | same |
| `Round WR:` | Rounds won / rounds played. | same |
| `Adv Won: <w>/<p>` | Rounds won / rounds played while the Advance switch was on (Survival rounds only). | when Advance rounds or Alpha/Bravo/Charlie/Delta wins are above 0 |
| `Alpha: <w>W / <l>L` | Team match wins and losses on Alpha. | same |
| `Bravo: <w>W / <l>L` | Team match wins and losses on Bravo. | same |
| `Left Lost Matches:` | Losses given for leaving a team match (see match results). | section |
| `Days Played:` | Days with at least one counted second of play. | section |
| `Protection: <n> days` | Protection days. | section |
| `Balance Moves:` | Times the team balance (or an admin through it: `/bal`, `/mix`, `/swap`, `/move`; or the start of a map with `fix` or `shuffle`) moved the player to another team. Not counted: `MapStart = mix`, a join placed in a team, a move to the spectators. | when this or `Volunteered` is above 0 |
| `Volunteered:` | Times the player went to the weaker team with `!switch` and it evened the match (a switch that helps neither the chances nor the numbers counts nothing). | same |

#### Other Ratings (FFA / Team / CTF)

The title names the family of the current mode. The section is always shown.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Elo Points:` | Current points. | always |
| `Rating: <x> (<mode>)` | Rating index and the `RatingMode` in use (`skill`, `gamemode` or `unified`). | always |
| `Ranking uses:` | `ELO`, `MMR`, `Glicko-2` or `OpenSkill` (`RankingSystem`). | always |
| `MMR: <v> (<n>)` | MMR of the current family and its rated matches; `unrated` without matches. | always |
| `Glicko-2: <v> (<n>)` | Glicko-2 rating - ConservativeFactor x RD of the current family; `unrated` without matches. | always |
| `OpenSkill: <v> (<n>)` | mu - 3 x sigma of the current family; `unrated` without matches. | always |
| `MMR FFA:` / `Team:` / `CTF:` | MMR of each family. | always |
| `League: <name> <division>` | League label; during placement `Placement <played>/<needed>`. Shown whether or not `[Leagues] Enabled` is on. | always |
| `Top <x>% of placed` | Position from the top among placed accounts. | when the account is placed |
| `not placed yet` | The account has too few matches. | otherwise |
| `Leagues by:` | `[Leagues] Source` (`mmr` or `rating`). | always |

#### Season & Achievements

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Season <id>: <+n> pts` | Season stored on the account and the points won or lost in it. | always |
| `Season K/D: <ratio> (<k>/<d>)` | Counted kills and deaths in that season, and their ratio. | always |
| `Achievements: <n>/50` | Unlocked achievements. | always |
| `Season badges: S<id> #<place>, ...` | Top 3 places in archived seasons. | when the account has badges |

#### Multi-Kill Medals

A kill within `[Mechanics] MultiKillWindowSeconds` (3.5) after the same player's previous kill continues a chain. The chain restarts when the player's life ends (also by a selfkill or a kill by the server) and at every spawn, so kills of two lives never form a chain. Each step of a chain adds one medal, so a 4-kill chain gives one Double, one Triple and one Multi. They are stored under "Pointmatch" but counted in every mode.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Double Kills:` | 2nd kill of a chain. | always |
| `Triple Kills:` | 3rd kill of a chain. | always |
| `Multi Kills:` | 4th kill of a chain. | always |
| `Multi x2:` | 5th kill. | always |
| `Serial Kills:` | 6th kill. | always |
| `Insane Kills:` | 7th kill. | always |
| `Gimme More:` | 8th kill. | when Gimme More + Masta Killa + Stop It are above 0 |
| `Masta Killa:` | 9th, 10th and 11th kill (one medal each). | same |
| `Stop It:` | 12th kill. | same |

#### Melee, Explosives & Heavy Arsenal

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Knife Throws:` | Knife throws (a knife left the hand of a living player and a thrown knife appeared within 3 ticks). | always |
| `Knife Hits: <n> (<x>%)` | Thrown knife hits on enemies; share of throws. | always |
| `Knife Stabs:` | Knife (melee) hits on enemies. | always |
| `Nades Thrown:` | Frag grenade throws (grenade count dropped, no cluster kit picked up since the last spawn or grenade kit). | always |
| `Nade Hits: <n> (<x>%)` | Frag grenade damage events on enemies; share of throws. | always |
| `Clusters: <h>/<t>` | Cluster grenade damage events on enemies / cluster throws. | third cell when cluster throws are above 0 |
| `Self Nades:` | Frag grenade self hits. | third cell otherwise |
| `M79 hits: <h>/<s> (<x>%)` | M79 damage events on enemies / M79 shots, their ratio. | always |
| `LAW hits: <h>/<s> (<x>%)` | LAW damage events on enemies / LAW shots, their ratio. | always |
| `Fist Hurts:` | Fist hits on enemies. | always |
| `Saw: <time>, <n> hits` | Seconds alive holding the chainsaw; chainsaw damage events on enemies. | when chainsaw hurts or time, flamer hits or stationary gun hits are above 0 |
| `Flamer hits: <h>/<s>` | Flamer damage events on enemies / flamer shots (ammo drops). | same |
| `M2 MG Hits:` | Stationary gun hits on enemies. | same |

#### Teamplay & Friendly Incidents

The section is shown when the account has teamkills or deaths by teammates, or friendly fire is on and the account has friendly hits.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Teamkills:` | Kills of a teammate (both human, statistics on). | section |
| `Deaths by Team:` | Deaths caused by a teammate. | section |
| `TK Ratio:` | Teamkills / deaths by team (0 if no deaths by team). | section |
| `Friendly Hits:` | Friendly hits made. | section |
| `Hit by Team:` | Friendly hits received. | section |
| `Self Hits:` | Self hits. | section |
| `TK Head:` / `TK Body:` / `TK Legs:` | Friendly hits made, by zone. | when any of the three is above 0 |

#### Game Modes (kills / deaths / wins / time)

Shown only when the account has kills or deaths in more than one mode. One entry per mode: `<mode> <kills>/<deaths>/<wins> <time>` (`DM`, `PM`, `TM`, `CTF`, `RM`, `INF`, `HTF`), counted in the mode where they happened.

### !status

Header: `[ Status: <name> ]`.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Rank:` | Position in the points ranking or `-`. | always |
| `Points:` | Current points. | always |
| `Rating: <x>` | Rating index for the current mode. | always |
| `Play:` | Play time. | always |
| `Spec:` | Spectator time. | always |
| `Protect: <n> days` | Protection days. | always |
| `First Seen:` | Date the account was created (the first visit; not the date a password was set). | always |
| `Last Seen:` | Date of the last join or leave. For a player who is online this is the join time. | always |
| `Seen At:` | Time of day of the same moment. | always |
| `Account: Steam` / `Account: computer, password protected[, e-mail verified]` / `Account: computer, no password` | Account type. | always |
| `Kills/Deaths: <k>/<d>` | Counted kills and deaths since the player joined the server. | section "Current Session (since joining)", only when the player is online |
| `K/D: <x> (HS: <n>)` | Their ratio; head hits on enemies since joining. | same |
| `Time:` | Time since the player joined the server. | same |
| `Streak: <n> kills` | Counted kills in the current life. | same |
| `Pts Delta:` | Points now minus points when the player joined. | same |
| `Slot: <n> (Active)` | Server slot. | same |
| `Not on the server now; the current session shows while the player is here.` | Said instead of the session. | when the player is not on the server |

### !rank

One line: `[Rank] <name> - Rank: <r>/<N> (<tier>) | Points: <p> | Rating: <x> | K/D: <y> | Kills: <k> | Deaths: <d>`.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Rank: <r>/<N>` | Position in the points ranking (`-` if hidden) / accounts in the ranking. | always |
| `(<tier>)` | League (with `[Leagues] Enabled = 1`) or tier. | when a name exists |
| `Points:` | Current points. | always |
| `Rating:` | Rating index for the current mode. | always |
| `K/D:` / `Kills:` / `Deaths:` | As in `!stats`. | always |

### !session

`!session [p]` (`!today`) for yourself or a player on the server, `!sessioni <pos>` for the player on the server at that ranking position. Sessions exist only for players who are on the server: about anybody else the answer is `No player on the server matches that (sessions are for players in the game).` Header: `Session Stats: <name>`. The session starts when the player joins the server; a map change does not reset it.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Kills:` / `Deaths:` / `K/D:` | Counted kills and deaths since joining. | always |
| `Headshots:` | Head hits on enemies (not kills) since joining. | always |
| `Points:` | Points now minus points when the player joined. | always |
| `Time:` | Time since the player joined the server. | always |
| `Caps:` | Flag captures since joining. | in objective modes, or when the account has captures since joining |
| `Wins:` | Match wins since joining (a win is added when a counted match ends). | always |
| `Rounds Won:` | Survival rounds won since joining. | when the current map has Survival on, or the account has round wins since joining |
| `Current Streak:` | Counted kills in the current life. | always |
| `Total Points:` | Current points. | always |
| `Rank:` | Position in the points ranking or `-`. | always |
| `Not logged in: this session is not saved to the account (/login).` | The account is password protected and the player is not logged in. | only then |

If Steam has not answered yet the command says `Waiting for Steam to confirm your account, try again in a moment.`; without an account it says `Statistics are off for this session.`

### !spree, !pm, !pointmatch

Header: `Pointmatch & Spree Records: <name>` in PM, otherwise `Multi-Kill & Spree Records: <name>`.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Best Streak:` | Most counted kills in one life (in Survival a streak goes on after a round end, see `Max Streak` in `!otherstats`). | always |
| `Shut Downs:` | Kills of a player with a current streak of 5 or more; this stays 5, whatever `[Sprees]` says. | always |
| `Finishers:` | See `!otherstats`. | always |

Section `Kill Streaks - times reached`: one cell `<Name> (<N> kill(s)): <count>` per level of `[Sprees]` (name and kills from the level itself), two per row - times a streak reached at least that many kills; a streak of 25 counts for every lower level it passed too. Always shown: at least the built-in levels apply when `settings.ini` sets none.

Section `Multi-Kill Medals`:

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Double:` ... `Cheater:` | Multi-kill medals (see `!otherstats`): `Double` 2nd, `Triple` 3rd, `Multi` 4th, `Multi X2` 5th, `Serial` 6th, `Insane` 7th, `Gimme More` 8th, `Masta Killa` 9th-11th, `Stop It` 12th, `Mercy` 13th, `Cheater` 14th and every later kill of a chain. | always |
| `PM Bonus:` | Pointmatch bonus points: at the end of a counted PM match, scoreboard score minus counted kills of that map, when positive. This also includes the score of kills ZitroStats did not count (bots, kills while statistics were off). Shares its row with `Mercy` and `Cheater`. | in PM, or when the value is above 0 |

The streak is the number of counted kills since the last spawn; it restarts on death and map change, but not on a kill the server makes itself (the end of a survival round, a team change): that streak goes on at the next spawn.

### !rambo

Header: `Rambomatch Stats: <name>`. Every counter here changes only in Rambomatch (RM). `!zitro` lists the command only in RM, but it works everywhere.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Rambo Kills:` | Counted kills of a victim whose primary weapon was a bow (Rambo Bow or Flamed Arrows). | always |
| `Kills With Bow:` | Counted kills made with a bow. | always |
| `Bow Pickups:` | Weapon changes from a non-bow to a bow. | always |
| `Bow Drops:` | Weapon changes from a bow to a non-bow while alive. | always |
| `Kills Non-Rambo:` | Counted kills where neither the killer's weapon nor the victim's weapon was a bow. | always |
| `Deaths Non-Rambo:` | The same kills, counted for the victim. | always |
| `Time With Bow:` | Seconds alive holding a bow. | always |
| `Time Without Bow:` | Seconds alive holding anything else. | always |

### !achievements and !achlist

`!achievements [p]` (`!ach`, `!badges`; by ranking position `!achievementsi <pos>`, `!achi`, `!badgesi`):

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Achievements of <name>: <n>/50` | Header with the number unlocked. | always |
| names, four per line | Unlocked achievements in id order. `None yet.` if there are none. | always |
| `Season badges: Season <id>: #<place>, ...` | Top 3 places in archived seasons. | when the account has badges |
| `Every achievement and what it takes: !achlist` | Hint. | always |

`!achlist [p]` (`!achievementslist`; by ranking position `!achlisti <pos>`, `!achievementslisti`): header `Achievements of <name>: <n>/50` (or `Achievements (50)` without an account), then all 50 as `[x] <name> <goal>` or `[ ] <name> <goal>`, two per line, unlocked ones first. The goals are listed in [Achievements](#achievements).

### !allweapons

Header: `All Weapons Breakdown: <name>`.

Table columns (one row per weapon):

| Column | What it means |
| :--- | :--- |
| `Weapon` | Weapon name. |
| `Kills` | Counted kills with the weapon. For Rambo Bow the larger of this and the RM bow kills. |
| `Deaths` | Counted deaths caused by this weapon (not deaths while holding it). |
| `K/D` | Kills / max(1, deaths). |
| `Shots` | Shots with the weapon (at least `Hits`). Thrown knives count as knife shots. |
| `Hits` | Enemy hits with the weapon. |
| `Acc%` | Hits / shots. |
| `HS%` | Head hits / hits. |
| `DmgOut` | Damage dealt in enemy hits with the weapon. |
| `DmgR` | DmgOut divided by the damage received from this weapon (`!wep <weapon>` shows both numbers). |
| `Time` | Seconds alive with this as the active primary weapon (fists are not timed). |

- Rows for USSOCOM, Desert Eagles, HK MP5, AK-74, Steyr AUG, Spas-12, Ruger 77, M79, Barrett M82A1, FN Minimi, XM214 Minigun, Combat Knife, Chainsaw and M72 LAW are always shown.
- Section `Bonus, Special & Thrown Weapons`: Flamer, Rambo Bow, Flamed Arrows, Stationary Gun, Fists, Grenade and Cluster Grenade, each only when it has kills, deaths, shots, hits, time or damage. In RM the two bow rows are always shown.
- `Combat Knife` holds melee stabs and thrown knives together.
- Accounts imported from 4.x kept some weapons only in the special counters; for those weapons the table shows the larger of the per-weapon value and the special counter (M79, knife, chainsaw, LAW, flamer, bow kills and time, stationary gun, fists, grenade, cluster).

Then:

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Dmg Dealt:` / `Dmg Taken:` / `Dmg Ratio:` | As in `!otherstats` (section `Damage & Combat Telemetry`). | always |
| `TK Dmg Out:` / `TK Dmg In:` / `TK Kills/Deaths:` | As in `!otherstats`. | same condition as there |
| `Knife Throws:` / `Knife Hits:` / `Knife Stabs:` | As in `!otherstats` (section `Melee, Throws & Combat Hurts`). | always |
| `Saw Time:` | Seconds alive holding the chainsaw. | always |
| `Saw Hurts:` | Chainsaw damage events on enemies. | always |
| `Fist Hurts:` | Fist hits on enemies. | always |
| `Nade Throws:` | Frag grenade throws. | always |
| `Nade Hurts:` | Frag grenade damage events on enemies. | always |
| `Clusters: <h>/<t>` | Cluster damage events on enemies / cluster throws. | third cell when cluster throws are above 0 |
| `TK Nades:` | Frag grenade friendly hits. | third cell otherwise, when above 0 |
| `Self Nades:` | Frag grenade self hits. | third cell otherwise |
| `M79: <s>s / <h>h` | M79 shots and damage events on enemies. | always |
| `LAW: <s>s / <h>h` | LAW shots and damage events on enemies. | always |
| `M2 MG Hits:` | Stationary gun hits on enemies. | third cell when above 0 |
| `TK Explo:` | M79 + LAW friendly hits. | third cell otherwise, when above 0 |
| `Self Explo:` | M79 + LAW self hits. | third cell otherwise |
| `Flamer Hurts:` | Flamer damage events on enemies. | when flamer hurts, flame arrow hurts or bow kills are above 0, or in RM |
| `Flame Arrow:` | Flamed Arrows damage events on enemies. | same |
| `Bow Kills:` | Counted bow kills in RM. | same |

### !serverweapons and !serverwep

`!serverweapons` (`!serverweps`, `!srvweapons`, `!srvweps`) draws the table of `!allweapons` with the numbers of every account added together. Header: `All Weapons Breakdown: the whole server`. Over the whole server every kill with a weapon is somebody's death to it, so the deaths, the K/D and the damage taken would only repeat the kills: the columns are `Weapon`, `Kills`, `Share` (of all kills), `Pick%`, `Shots`, `Hits`, `Acc%`, `HS%`, `DmgOut` and `Time`. `Pick%` is the weapon's share of the spawns with a weapon of its group: the primaries, or the secondaries (Socom, knife, chainsaw, LAW), which every player spawns with as well - counted together, the Socom would always lead; `-` for a weapon nobody spawns with. Numbers of 10000 and more are shortened (`12.3k`, `1.2M`). After the table comes `Server totals`:

| Label as shown | What it means |
| :--- | :--- |
| `Kills:` / `Shots:` / `Hits: <n> (<x>%)` | All weapons together. |
| `Headshots:` / `HS%:` / `Damage: <x> (~<y> kills)` | All weapons together; y = the damage as kills. |
| `Dmg/Kill:` | Damage dealt with every weapon, over every account, per kill. |
| `Most kills:` / `Top primary: <weapon> (<x>%)` / `Top secondary: <weapon> (<x>%)` | The weapon with the most kills; the primary and the secondary weapon players spawn with most often, with their share of their group. |
| `TK Kills:` / `TK Dmg:` | Teamkills and damage to teammates, over every account. Shown in team modes, or when the accounts have some. |
| `Accounts:` | Accounts in the database. |

Then the section `Melee, Throws & Combat Hurts` of `!allweapons`, counted over every account.

`!serverwep <weapon>` (`!serverweapon`, `!srvwep`) is the deep dive of `!wep` for the whole server. Header: `Weapon: <weapon> - the whole server`. Rows: kills, their share of all kills and how many accounts ever used the weapon; the damage dealt with it as kills (`~<y> kills`), per kill and per hit (the damage taken from it would only repeat the damage dealt); shots, hits (with the accuracy for the guns) and time; headshots (for the weapons with hit zones), hits per kill and the longest kill. Then `Top killer` (the account with the most kills), `Best accuracy (200+ shots)`, `Sweet Spot`, the `Reloading` section of `!wep` counted over every account, and the same `Server-wide for this weapon` section as `!wep`.

Both commands read every account, so they are heavy lists: one per `[Commands] HeavyCooldownSeconds` per player (admins have no limit). `!serverwep help` lists the weapon names and is free.

### !allweaponsby and !serverweaponsby

`!allweaponsby <metrics> [p]` (`!weaponsby`), `!allweaponsbyi <metrics> <pos>` (`!weaponsbyi`) and `!serverweaponsby <metrics>` (`!serverwepsby`, `!srvweaponsby`, `!srvwepsby`) draw the weapon table of `!allweapons` or of `!serverweapons` sorted by up to 5 [weapon metrics](#weapon-metrics-topweaponsby). Header: `All Weapons by <m1> > <m2> ...: <name>` (`: the whole server`, or `: all servers` with `SharedWeapons`); metric names that would not fit the line are written ` > ...`.

- The metrics of `!allweaponsby` are its first word, several of them joined by `;` or `,` (`!allweaponsby kd;acc`, `!allweaponsby kd; acc Alice`); what follows is the player, or the ranking position of `!allweaponsbyi`. `!serverweaponsby` takes metrics only, separated by space, comma or semicolon. A metric given twice counts once; unknown words are listed as `[Note] Ignored unknown metric(s): ...`.
- The rows are the weapons of the plain table: USSOCOM to M72 LAW always, the others when they have kills, deaths, shots, hits, time or damage (with `!serverweaponsby` also picks; with `!allweaponsby` in RM the two bows always). There are no sections: every row is sorted.
- Sorted by the first metric, ties by the next ones, then by kills, then in the order of the plain table. Best first: the highest value, or the lowest for the metrics that are lower-is-better (`ttk`, `reloadtime`, `dmgperkill`, `kdmgratio`), where 0 counts as no value. A value that means nothing for a weapon is `-` and comes last: the accuracy of a weapon without shots of its own or without a shot yet, the headshots of a weapon without hit zones, the shots of the chainsaw, the flamer, the fists and the stationary gun, the reloads of a weapon that has none (knife, flamer, stationary gun, fists, grenades), a share or a ratio of nothing.
- Columns: `Weapon`, the metrics in their order, then the columns of the plain table that are no metric of the list (`!allweapons`: `Kills`, `Deaths`, `K/D`, `Shots`, `Hits`, `Acc%`, `HS%`, `DmgOut`, `DmgR`, `Time`; `!serverweapons`: `Kills`, `Share`, `Pick%`, `Shots`, `Hits`, `Acc%`, `HS%`, `DmgOut`, `Time`), with the values as there. Every column is as wide as its longest cell and two spaces; columns of the plain table that do not fit the 100 characters of a line are left out, from the end (with five long metrics the last ones go).
- Kill distances, times to kill, picks and vest kills are counted for the whole server, not per account: `avgdist`, `ttk`, `picks`, `pick%`, `vestkills`, `alphapicks` and `bravopicks` work with `!serverweaponsby`, and `!allweaponsby` names them in `[Note] Counted for the whole server only (!serverweaponsby): ...` instead.
- Without metrics, or with `help`, each command lists the metrics it takes. On the server console `!allweaponsby` needs a player. `!serverweaponsby` reads every account, so it is a heavy list like `!serverweapons` (its help and a text without a metric are free); `!allweaponsby` reads one account. Neither has pages: `/zs_next` and the others go on with the last list that has them.

### !wep

`!wep <weapon> [player]` (`!weapon`, `!weap`), and by ranking position `!wepi <weapon> <pos>` (`!weaponi`, `!weapi`). Without a weapon or with `help` it lists the weapon names. Header: `Weapon: <weapon> - <name>`. Values marked "view" use the same larger-of rule for 4.x accounts as `!allweapons`.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Kills:` | Counted kills with the weapon (view). | always |
| `Deaths:` | Counted deaths caused by this weapon. | always |
| `K/D:` | Kills / max(1, deaths). | always |
| `Dmg Out: <x> (~<y> kills)` | Damage dealt with the weapon; y = that damage as kills: damage / full health of the current mode (as in `!otherstats`). | always |
| `Dmg In: <x> (~<y> deaths)` | Damage received from this weapon; y = the same as deaths. | always |
| `Dmg Ratio:` | Out / in. | always |
| `Dmg/Kill: <x> HP` | Damage dealt with the weapon per kill with it. | always |
| `Dmg/Death: <x> HP` | Damage received from it per death by it. | always |
| `K-D Dmg:` | Dmg/Kill / Dmg/Death: below 1 the weapon needs less of your damage for a kill than the enemies need of theirs to kill you with it. | always |
| `Shots:` | Shots (view, at least hits). | always |
| `Hits: <n> (<x>%)` | Enemy hits (view); share of shots. | always |
| `Time:` | Seconds alive with the weapon as active primary weapon (view). | always |
| `Head: <n> (<x>%)[ est.]` | Head hits with this weapon; share of hits. ` est.` when more than 5% of this weapon's zone hits are unclear. | only for weapons with hit zones (bullets, pellets, Rambo Bow, stationary gun), or when older data holds zone hits |
| `Body: <n> (<x>%)` | Body hits with this weapon. | same |
| `Legs: <n> (<x>%)` | Leg hits with this weapon. | same |
| `Avg Dmg/Hit: <x> HP` | Damage / hits. | always |
| `HS Lethality:` | Headshot kills / head hits. A headshot kill is a kill whose lethal hit (at most 2 ticks before the kill) was a head hit. | always |
| `Longest Kill: <x>m` | Longest counted kill with the weapon. | always |
| `Dmg/min:` | Damage x 60 / time. | always |
| `Hits/Kill:` | Hits / kills. | always |
| `Kills/Shot:` | Kills / shots. | always |
| `Sweet Spot:` | Fixed text per weapon, not measured. | always |
| `Reloads: <n> (<m> manual)` | Reloads started with the weapon; of them with rounds still in the magazine. `No reloads counted yet.` before the first one. | section `Reloading`, weapons whose reloads are counted (see Reload) |
| `Finished: <x>%, broken off: <n>` | Reloads that ran through, as a share of the reloads started; reloads broken off by a thrown gun, a shot of the Spas-12 or a weapon change after which the reload was not taken up again. Every reload ends once, so finished, broken off and killed reloading never add up to more than the reloads started. | same |
| `Avg reload: <t> (standard <t>)` | Average length of the finished reloads whose length is known (not one that went on after a weapon change); what `weapons.ini` says the same reloads take. A roll, a grenade or a buttstock hit during a reload makes it longer. | same |
| `Avg progress of a reload: <x>%` | How far a reload got when it ended, on average: 100% for a finished one, the share of its time for one broken off or cut short by death. | same |
| `Killed reloading: <n> (<x>%)` | Deaths in the middle of a reload with this weapon (not the kills the server makes itself); their share of the reloads started. | same |
| `At death: <x>% of the reload done` | How far those reloads had got, on average. | same |
| `Rounds thrown away:` | Rounds that were still in the magazine when a manual reload started (the Spas-12 loads on top of its shells and throws none away). | same |
| `Time reloading:` | All the time spent reloading this weapon. | same |
| `Kill distance: <10m .. 100m+` | Server-wide: share of counted kills with this weapon in the ranges under 10, 10-25, 25-50, 50-100 and 100 m or more (kills with a known distance). | section `Server-wide for this weapon`, when such kills exist |
| `Avg Kill Dist:` | Server-wide average kill distance with the weapon. | section |
| `Avg TTK:` | Server-wide average time to kill with the weapon (`-` if none). | section |
| `Vest kills:` | Server-wide counted kills with this weapon of victims wearing a vest. | section, when above 0 |
| `Nemesis: <weapon> (<n>)` | Server-wide: the weapon that most often killed players holding this weapon (never the weapon itself). | section, when any other weapon has |
| `Top Victim: <weapon> (<n>)` | Server-wide: the weapon most often held by players this weapon killed (never the weapon itself). | section, when any other weapon has |
| `Picks:` | Server-wide: how often human players took the weapon (primary or secondary) for a life while statistics were on: the weapons of the spawn or, when the weapon menu was open at the spawn, the first ones taken after it. A later change in the same life is no pick. | section, for USSOCOM through M72 LAW, or any other weapon with picks |
| `Alpha picks: <n> (<x>%)` / `Bravo picks: <n> (<x>%)` | The same picks of players in Alpha and in Bravo, and their share of the picks made in a team. | section, when players in a team took the weapon |
| `Of primaries: <x>%` / `Of secondaries: <x>%` | The weapon's share of the picks of its group (secondaries: Socom, knife, chainsaw, LAW). | section, when the weapon was picked |
| `Charlie/Delta picks: <c>/<d>` | Picks of players in Charlie and Delta (Teammatch). | same, when above 0 |
| `Explode Hurts:` / `TK: <a> \| Self: <b>` | M79: damage events on enemies; friendly and self hits. | M79 only |
| `Throws: <t> (Hits: <h>)` / `Stabs: <s> (TK: <f>)` | Knife: throws and thrown hits on enemies; stabs on enemies and on teammates. | knife only |
| `Self Hits:` / `TK Throw Hits:` | Knife: thrown knife self hits and friendly hits. | knife, when one of them is above 0 |
| `Saw Hurts:` / `TK Hurts:` | Chainsaw damage events on enemies and teammates. | chainsaw only |
| `Rocket Hurts:` / `TK: \| Self:` | LAW damage events on enemies; friendly and self hits. | LAW only |
| `Fire Hurts:` / `TK: \| Self:` | Flamer damage events on enemies; friendly and self hits. | flamer only |
| `Pickups: <p> \| Drops: <d>` / `Held:` | RM bow pickups and drops; seconds alive with a bow in RM. | Rambo Bow and Flamed Arrows |
| `Flame Arrow Hurts:` / `TK: \| Self:` | Flamed Arrows damage events on enemies; friendly and self hits. | bows, when above 0 |
| `Stationary Hits:` / `TK Hits:` | Stationary gun hits on enemies and teammates. | stationary gun only |
| `Fist Hurts:` / `TK Hurts:` | Fist hits on enemies and teammates. | fists only |
| `Throws: <t>, enemy hits <h> (<x>%)` / `TK: \| Self: \| Kills:` | Frag throws and enemy damage events; friendly and self hits; `Kills` is the grenade kill counter, which includes cluster kills. | grenade only |
| `Throws: <t>, enemy hits <h>` / `TK: \| Self:` | Cluster throws and enemy damage events; friendly and self hits. | cluster only |

Weapon names accepted: numbers 0-16, 30, 50, 51, 52 (cluster), 53 (knife), 255 (fists), and the names listed under [weapon metrics](#weapon-based-player-metrics), with a few more words for each weapon (`sniper` and `m82` for the Barrett, `shotgun` for the Spas, `gl` for the M79 ...). The search takes the strongest match it finds: a whole word, then the beginning of the short name, then the beginning of any word (`barr` = Barrett M82A1), then a part of a word (3 letters or more), then one typo (4 letters or more; two from 7 letters). A text that fits more than one weapon gets the list of what it could be, for example `!wep m` - `HK MP5 (mp5), M79 (m79), ...`. With more words, the longest beginning that names a weapon is the weapon and the rest is the player (`!wep desert eagles bob`); whole names are tried before parts of names, and a name of several words has to be whole (`!wep deagle s` is player "s"). A weapon number is digits only. When the rest is a number that no player has in the name, the answer points to `!wepi`, which takes a ranking position.

### !matchup

Server-wide weapon duels. A duel result is added for every counted kill: the killer's weapon beat the victim's primary weapon at the moment of death.

`!matchup [pg]` without a weapon: `Weapon Matchups: Top Rivalries [Page p/P] (<n>)`, every weapon pair that met, the most duels first, `[Ranking] TopDisplayLinesCount` (15) rows per page. A number at the end is the page, unless the whole text is the name of a weapon (`!matchup ak 47`, `!matchup ruger 77`); `/zs_next` and `/zs_prev` browse.

| Column | What it means |
| :--- | :--- |
| `#` | Place by number of duels. |
| `Duel Rivalry` | `<weapon A> vs <weapon B>`. |
| `Duels` | Kills of A on B-holders plus kills of B on A-holders. |
| `A Wins` | Kills by A on B-holders and their share. |
| `B Wins` | Kills by B on A-holders and their share. |
| `Verdict` | `few duels` under 10 duels; `<A> favored` when the lower end of the 95% Wilson range of A's win rate is above 50%; `<B> favored` when the upper end is below 50%; otherwise `even`. |

`!matchup <weapon> [pg]`: `Matchups: <weapon> [Page p/P]`, one row per opponent weapon with duels, the most duels first.

| Column | What it means |
| :--- | :--- |
| `Opponent Weapon` | The other weapon. |
| `Kills` | Kills by this weapon on players holding the opponent weapon. |
| `Deaths` | Kills by the opponent weapon on players holding this weapon. |
| `Win Rate` | Kills / (kills + deaths). |
| `95% Range` | Wilson 95% interval of the win rate. |
| `Ratio` | Kills / max(1, deaths). |
| `Matchup Edge` | `few duels` (under 10); `FAVORED` (lower end above 50% and win rate 58% or more); `slight edge` (lower end above 50%); `DISADVANTAGE` (upper end below 50% and win rate 42% or less); `slight deficit` (upper end below 50%); otherwise `EVEN`. |

### !topweapons and !topweaponsby

`!topweapons [pg]` ranks weapons by server-wide kills; `!topweapons <weapon> [pg]` instead ranks the players who used that weapon (a trailing number is the page, unless it is part of the weapon's own name: `ak 47`, `ruger 77`, `spas 12`); `!topweaponsby <metrics> [pg]` ranks the weapons by up to 5 [weapon metrics](#weapon-metrics-topweaponsby), and so does `!topweapons <metric>` when the word is a metric rather than a weapon. `!topweaponsby` alone, or `!topweaponsby help`, shows the metric names.

**`!topweapons <weapon> [pg]`**: header `Top Players with <Weapon>[ of All Servers] [Page p/P] (<n> players)`, 15 rows per page, sorted by kills with the weapon, ties by damage dealt with it, then by fewer deaths to it. `Nobody has used the <Weapon> yet.` when no account has it.

| Column | What it means |
| :--- | :--- |
| `#` | Place. |
| `Nick` | Current name. |
| `Kills` | Counted kills with the weapon. |
| `Deaths` | Counted deaths caused by the weapon. |
| `K/D` | Kills / max(1, deaths); `-` without a kill or a death. |
| `Acc%` | Hits / shots with the weapon. |
| `HS%` | Head hits / hits with the weapon. |
| `Damage` | Damage dealt with the weapon. |
| `Time` | Seconds held as the active primary weapon; `-` if never. |
| `Longest` | Longest kill with the weapon; `-` if none; ` <YOU>` marks the viewer's own row. |

**`!topweapons [pg]`** (weapon rankings) and **`!topweaponsby <metrics> [pg]`**: header `Top Weapons by <metrics> [Page p/P]`, 12 rows per page. Sorted by the first metric, ties by the next ones, then by kills.

- The weapons 0-13 (USSOCOM to M72 LAW) are always listed; the others only when they have kills, deaths, shots, hits, time, picks or damage.
- Weapon values are sums over all accounts (with the 4.x larger-of rule per account); `Picks` and `VestKills` come from the server record; `Longest` is the longest single kill of any account.

With one metric the columns are:

| Column | What it means |
| :--- | :--- |
| `#` | Place. |
| `Weapon` | Weapon name. |
| `<metric>` | The chosen metric. |
| `Share` | The weapon's share of all kills of every weapon, added over all accounts. |
| `Acc%` | Hits / shots. |
| `HS%` | Head hits / hits. |
| `Damage` | Damage dealt. |
| `Time` | Seconds held. |

With several metrics: `#`, `Weapon` and one column per metric.

### !top and !topby

**Points ranking** (`!top [pg]`, `!topp <pg>`): header `Top Ranking [Page p/P] (Total: N)`, `[Ranking] TopDisplayLinesCount` (15) rows per page.

**Around a player or position** (`!top <name>`, `!topi <pos>`, `!topme`, `!topid <slot>`): header `Top Ranking [Rank #a-b of N]`, the target row marked ` <*>`.

| Column | What it means |
| :--- | :--- |
| `#` | Position in the points ranking. |
| `Nick` | Current name (17 characters). |
| `Tier` | League (with `[Leagues] Enabled = 1`) or tier (13 characters). |
| `Points` | Current points. |
| `Rating` | Rating index for the current mode. |
| `K/D` | Kills / max(1, deaths). |
| `Kills` | Counted kills. |
| `Deaths` | Counted deaths. |
| ` <YOU>` | Marks the viewer's own account. |

Who is in the points ranking: every account, sorted by points; equal points put the older account (lower id) first. In `[Inactivity] Mode = decay`, accounts not seen for `DecayHideAfterDays` (60) are left out until they play again.

**Custom lists** (`!topby <metrics> [pg]`, or `!top <metrics>` when the first word is a metric): header `Top by <m1> > <m2> ... [Page p/P]`, 15 rows per page.

- Up to 5 metrics, separated by space, comma or semicolon; a trailing number is the page. Unknown words are listed as `[Note] Ignored unknown metric(s): ...`.
- Sorted by the first metric, ties by the next ones, then by points. Metrics marked "lower is better" sort a value of 0 last.
- Every account is a candidate, also accounts without any game.
- With one metric the columns are `#`, `Nick`, `Tier`, the metric, `Points`, `Rating`, `K/D`, `Kills`; a column that is the metric itself (`tier`, `points`, `rating`, `kdr`, `kills`) is left out.
- With several metrics: `#`, `Nick` and one column per metric.
- `!topby` alone or `!topby help` prints a short list of common metric names. All metrics are listed in [Metrics for !topby](#player-metrics-topby).

### Period lists: !topday, !topweek, !topmonth

Header: `Top Today`, `Top This Week` or `Top This Month` `[Page p/P] (N players)`, 15 rows per page. The week is the ISO week (Monday to Sunday); day and month follow the server clock.

- Candidates: accounts whose period record belongs to the current day, week or month and has kills, deaths, captures or wins in it.
- Sorted by the points change, then kills, then fewer deaths.

| Column | What it means |
| :--- | :--- |
| `#` | Place. |
| `Nick` | Current name. |
| `Points` | Sum of all point changes in the period: kills, deaths, captures, selfkill and teamkill penalties, daily balance and check points. |
| `Kills` | Counted kills in the period. |
| `Deaths` | Counted deaths in the period. |
| `K/D` | Kills / max(1, deaths). |
| `HS` | Headshot kills in the period (kills whose lethal hit was a head hit), not head hits. |
| `Caps` | Flag captures in the period. |
| `Wins` | Match wins in the period. |
| `Time` | Play time in the period. |

### !topskill

`!topskill [pg]` (`!toprating`) uses the family of the current mode.

- With `[Ranking] RankingSystem = elo` it prints `The ranking uses points (RankingSystem = elo); this is the MMR list of <family> modes.` and then shows `!topby mmr` (every account, 0 for unrated).
- Otherwise the header is `Top <MMR|Glicko-2|OpenSkill> <FFA|Team|CTF> [Page p/P] (Total: N)`. Only accounts with at least one rated match of that system in the family are listed, best value first (equal values: older account first).

| Column | What it means |
| :--- | :--- |
| `#` | Place. |
| `Nick` | Current name. |
| `Skill` | MMR; Glicko-2 rating - ConservativeFactor x RD; or OpenSkill mu - 3 x sigma (1 decimal). |
| `Games` | Rated matches of that system in the family. |
| `Points` | Current points. |
| `K/D` | Kills / max(1, deaths), all modes. |
| `Kills` | Counted kills, all modes. |

### Seasons: !topseason and !seasons

Seasons run when `[Seasons] Enabled = 1`: a calendar month (`Length = monthly`) or `Days` days (`Length = days`). When a new season starts, the season counters of every account start again from 0 at once.

`!topseason` (running season): header `Season <id> - ends <date> [Page p/P]`. Candidates: accounts with activity in this season (season play time above 0), sorted by season points (equal: older account first). `Nobody has played in this season yet.` if empty.

`!topseason <id>` (archived season): header `Season <id>  <start> - <end> [Page p/P]`. The archive holds the best `ArchiveTop` (50) accounts with at least `MinSeasonMinutes` (30) of play, sorted by season points, then season kills, then lower id.

| Column | What it means |
| :--- | :--- |
| `#` | Place. |
| `Nick` | Name (in the archive: the name at archive time). |
| `Season` | Points won or lost in the season. |
| `Points` | Current points (in the archive: points at archive time). |
| `K/D` | Season kills / max(1, season deaths). |
| `Caps` | Season captures. |
| `Wins` | Season match wins. |
| `Time` | Season play time. |

After the list: `Past seasons: !topseason <first-last>` when archives exist.

`!seasons [pg]`: header `Seasons [Page p/P]`, 10 per page, newest first.

| Column | What it means |
| :--- | :--- |
| `ID` | Season number; `*` marks the running season. |
| `From` / `To` | Start and end date (for the running season the planned end). |
| `1st place` / `2nd place` / `3rd place` | Running season: current standings. Archived season: final top 3. `-` if empty. |

When a season ends, the top 3 archived accounts get a badge (`S<id> #<place>`), and with `[Messages] SeasonBroadcast` the chat shows `Season <id> is over!` with the top 3 and `Season <id> has started. Standings: !topseason`.

### !toponline

`!topo` (`!toponline`): header `Online Ranking (N Players)`. Every human on the server who has an account (also spectators and players not logged in), sorted by points.

| Column | What it means |
| :--- | :--- |
| `#` | Place among the players online. |
| `Nick` | Current name. |
| `Tier` | League or tier. |
| `Points` | Current points. |
| `Rank` | `#<position>` in the whole points ranking, `#-` if hidden. |
| `Rating` | Rating index for the current mode. |
| `K/D` | Kills / max(1, deaths). |
| `Kills` | Counted kills. |

### !zs_search

`!zs_search <text>` (`!zssearch`; AntiFake's search is `!af_search`) takes one character or more: a nick may be a single letter. The closest names come first: the whole name, then names that begin with the text, then names with a word that begins with it, then any other name that holds it; within each of these the player seen last comes first (`Last seen` gives the date and the hour). What an admin finds by a former name, an address, a HWID or a SteamID comes after the names. 10 per page.

Public view: header `Search: "<text>" (N matches) [Page p/P]`; it matches only current account names that contain the text.

| Column | What it means |
| :--- | :--- |
| `#` | Place in the result list. |
| `Nick` | Current name. |
| `Points` | Current points. |
| `Rank` | Position in the points ranking or `-`. |
| `Last seen` | Date and hour of the last join or leave. |

Admin view (an admin using `searcha`, also from the chat, or `/zs_search` typed as a command or in the server console): header `Admin Search: ...`, extra columns `ID` (account number) and `Found by`: `name`, `id` (text `#<id>`), `old name` (name history), `last IP` (prefix of the last IP), `HWID` (part of the last HWID) or `SteamID` (part of the SteamID).

### Map vote

The library's own map vote of `[MapVote]`; see [README.md](README.md#map-vote) for the rules. `map` = a map name or a part of it.

**`!map`** alone: the map being played, the next and the last map of the server's maps list, and the vote running, if any (with a name or a part of it, `!map` votes instead: see the commands table of the README).

| Output | What it means |
| :--- | :--- |
| `Now: <map>[ (<m>:ss left)]  Next: <next>  Last: <last>` | The map being played, with the time left when it has a time limit; the next map of the maps list; the map played before this one. Two lines instead of one when a long name would not fit next to them. |
| `Vote: <map>, <n> s left, <yes>/<voters> (<pct>% needed) - <keys> to vote` | Added when a vote is running. |

**`!maps [page|map]`**: header `Maps list: <n> maps [Page p/P]`, the names of the maps list in a grid of five columns, 60 to a page, the map being played shown as `[name]`. With a map - its name or a part of it, found as `!map <part>` finds it (a space may stand for the `_` of a name, a `.pms` at the end is left out; a number is a page) - the page that has it opens and the map is marked `>name<` (`>[name]<` when it is being played); `/zs_next` and the rest then turn the pages of the whole list. Below the grid, two spaces apart and on a second line when they do not fit on one: `[ ] = the map being played` (when shown on the page), `> < = the map you asked for`, `Next: <next>`, `Last: <last>` (the map played before this one, as in `!map`) and, when a command to start a vote answers, `!map <part> starts a vote` (or `!votemap <part> starts a vote`). A map the list does not have: `No map of the maps list matches "<text>" - try !searchmap.` (`- try !allmaps.` when `!searchmap` is off).

**`!allmaps [page|map]`**: every map of the maps folder, in the order of the folder (by name). Header `All maps of the server: <n> [Page p/P]` (`FilterByGameStyle`: `Maps of this game mode: <n> [Page p/P]`, only the maps of the style played), names in the same grid. With a map, found as in `!maps` among the maps shown, the page that has it opens and the map is marked `>name<`. `*` marks a map that is not in the maps list (`name*`, or `[name*]` for the map being played); below, `* = not in the maps list, can be voted too` (or `cannot be voted` with `AllowAnyMap = 0`), `[ ] = the map being played` and `> < = the map you asked for`. A map the folder does not have: `No map of the server matches "<text>".` (`No map of this game mode matches "<text>".` with `FilterByGameStyle`).

**`!searchmap <part> [page]`**: the maps of the maps list and of the maps folder whose name holds the text, in the order of the search of the vote, so the first one is the map `!map <part>` finds: the maps list first (a map there twice counts once), then the maps only the folder has; in each the whole name, its beginning, the beginning of a word, any part, the shorter name first, then the order of the list or the folder. Header `Map search "<text>": <n> maps [Page p/P]`, the names in the grid of `!maps`, 60 to a page, `*` for a map that is not in the maps list and `[name]` for the map being played, with the legend of `!allmaps` below. When nothing matches as typed, a space stands for the `_` of a name (`!searchmap ctf ash`); a `.pms` at the end is left out, and a number after the text is the page (`!searchmap ctf 2`). `FilterByGameStyle` does not restrict it, as it does not restrict the vote. Without a text: `Usage: !searchmap <part of a map name> [page]`; with no match: `No map of the server matches "<text>".`

**`/zs_mapvote [cancel]`** (admin): the settings, the vote running or the last one, the maps list and the maps folder.

| Output | What it means |
| :--- | :--- |
| `[Map vote] off ([MapVote] Enabled = 0): the server's own map vote works as usual.` | `Enabled = 0`. |
| `[Map vote] on: passes with <pct>% of <who>, fails after <n> s` | `who` is "the players" (`CountSpectators = 1`) or "the players on the teams". |
| `[Map vote] none in the first <n> s of a map or with less than <m> s left, a starter waits <s> s` | `BlockAfterChangeSeconds`, `MinTimeLeftSeconds`, `StarterCooldownSeconds`. |
| `[Map vote] at least <n> player(s), maps outside the list: yes/no, vote percent put back: <pct>` | `MinPlayers`, `AllowAnyMap`, `RestoreVotePercent`. |
| `[Map vote] running: <map>, <n> s left, <yes>/<voters>` then `[Map vote] asked by <name> <time> ago - /zs_mapvote cancel ends it.` | The vote that runs, and how long ago it was asked (`just now` at first). |
| `[Map vote] none running; the last one: <map>, <result> <time> ago.` (or `[Map vote] no vote since the library started.`) | Without a running vote. |
| `[Map vote] maps list: <n> maps, next <next>` (or `not known yet`) | The maps list. |
| `[Map vote] maps folder: <n> maps (/zs_maps)` (or `not read (/zs_maps)`) | The maps folder. |

`/zs_mapvote cancel` ends a running vote (everybody hears it, see the broadcasts below; the console alone also gets `[Map vote] The vote was cancelled.`); without a vote running it says `No map vote is running.`

**`/zs_maps [rescan]`** (admin): the maps folder, the files Linux may not load, and the maps of the list without a file. `rescan` reads the folder again and, when it is done, tells the admin who asked `[Maps] <n> maps in the folder (<a> new, <r> gone), read in <n> ms.` (or the same error lines as below).

| Output | What it means |
| :--- | :--- |
| `[Maps] folder: <path>` | The folder read for the maps outside the maps list. |
| `[Maps] The folder has not been read yet (/zs_maps rescan reads it now).` / `[Maps] The folder could not be read: <error>` / `[Maps] The folder was not found: set [MapVote] MapsFolder in settings.ini, then /zs_reload.` | The state of the last scan. |
| `[Maps] <n> maps, read at <hh:nn:ss> in <n> ms, read again every <n> min` (or `read again on /zs_maps rescan`) | The last successful scan. |
| `[Maps] <n> file(s) not ending in ".pms" - Linux looks for ".pms" and may not load them:` | Files whose extension is not exactly `.pms`, listed below the line. |
| `[Maps] maps list: <n> maps` | The maps list. |
| `[Maps] <n> map(s) of the list have no file in the folder:` | A map of the list with no matching file, listed below. |
| `[Maps] <n> map(s) of the list differ from their file in case (Linux needs the same case):` | A map found only in another case, listed below. |
| `[Maps] Every map of the list has its file.` | Neither problem exists. |

**Broadcasts.** Everybody in the game hears:

| Message | When |
| :--- | :--- |
| `<name> wants <map>: <keys> to vote, <n> s, <pct>% needed (<yes>/<voters>).` | A vote starts. |
| `<name> wants <map>: the vote passed at once (<yes>/<voters>).` | It already meets `VotePercent` when it starts (nobody else able to vote): the clients never see a vote. |
| `<name> voted for <map> (<yes>/<voters>, <pct>% needed).` | A vote is cast (`!v`, F12, `/votemap`). |
| `<map> won the vote (<yes>/<voters>).` | The vote passes. |
| `The vote for <map> failed (<yes>/<voters>, <pct>% needed).` | `VoteSeconds` runs out first. |
| `The vote for <map> ended: nobody is left to vote.` | Everybody able to vote left the server. |
| `An admin cancelled the vote for <map>.` | `/zs_mapvote cancel`. |
| `The map is changing: the vote for <map> is over.` / `The script was loaded again: the vote for <map> is over.` / `The map vote was switched off: the vote for <map> is over.` | A map change, a script reload or `[MapVote] Enabled` turning off end a running vote. |
| `The server could not change the map to <map>.` | A passed vote's map change did not happen (admins also get `[ZitroStats] map vote: the map did not change to <map>.` and `Is its file there (/zs_maps)? On Linux the server looks for exactly "<map>.pms".`). |

### !mapstats

`!mapstats [map]`: the current map, or the map with that exact name, else the most played map whose name starts with or contains the text. Header: `[ Map Statistics: <map> ]`. Map counters are counted only for human players; most need statistics to be on (the exceptions are marked).

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Time:` | Seconds the map ran while statistics were on. | always |
| `Matches:` | Counted matches (see match results). | always |
| `Kills:` | Counted kills on the map. | always |
| `Selfkills:` | Selfkills on the map. | always |
| `Pace: <x> k/min` | Kills x 60 / time. | always |
| `Avg Match:` | Sum of the durations of the matches that reached the time or score limit / the number of those matches; a match left early (see `Aborted`) adds no duration, whether or not it had enough players to count for player statistics. Durations kept from before this counting began are set aside once, so the average starts with the first match measured after that; until then `-`. | always |
| `Quit Rate: <x>%` | Leaves / joins. | always |
| `Leaves:` | Humans who left while the map ran (always counted). | always |
| `Joins:` | Humans who joined while the map ran (always counted). | always |
| `Spec Joins:` | Humans who moved to the spectators during the map. Arriving on the server as a spectator is not counted, and neither are moves made by the balance, `/move`, `/swap` or `/mix`. One switch counts per `[Ranking] TeamSwitchCountSeconds` (5 s); every further switch pushes that window, so going game - spec - game - spec in a loop counts once. | always |
| `Kicks:` | Leaves that the server reported as kicks (always counted). | always |
| `Last:` | When the map last started or last ended a counted match. | always |
| `Loads:` | Times the map was started (always counted). | always |
| `Aborted:` | Matches that ended before the time or score limit (always counted). | always |
| `Draws:` | Counted team matches that ended in a draw: two teams on the same highest score. A free-for-all draw counts for the players only, not here. | always |
| `Votes: <n> (<w> won)` | Map votes started while this map ran, and how many of them changed the map. With `[MapVote] Enabled = 1` (default) these are the library's own map vote (see [Map vote](#map-vote) below): a vote counts here when it starts, and as won when it passes. With `Enabled = 0` a vote counts as won when the map changes to the voted map within 60 s of the vote's start or of its last vote cast (always counted); these are then Soldat's own map votes (the vote menu, `/votemap`), also one another script starts with `Game.StartVoteMap`, which is counted from the first vote cast for it. A vote a script counts entirely on its own (chat commands such as `!v`) is not seen, only the map change it makes. | always |
| `Avg Humans:` | Average number of humans in the game, over the seconds counted in `Time`; `-` before the map has such a second. | always |
| `Close:` | Counted team matches that ended in a draw or with the winner at most 1 point ahead of the next team. | always |
| `Comebacks:` | Counted team matches won by a team that was 2 or more points behind the leader at some point. | always |
| `First:` | Date the map record was created. | always |
| `Avg Win Score:` | The score of the winner, summed over the matches counted this way (team: the best team's score; free-for-all: the winner's score, only when the match had one) / their count. Scores kept from before this counting began are set aside once, so the average starts with the first match measured after that; until then `-`. | always |
| `Base Gap: <x> m` | Distance between the Alpha and Bravo flag bases. | in CTF, Infiltration or Hold the Flag, once both bases are known |
| `Heatmap: !heatmap` | A hint, no statistic. | always |
| `Kills/Match:` | Kills / counted matches. | always |
| `Healing: <hp> HP` / `Healing/Match: <hp> HP` | Health players got back from the map's regenerating polygons (the healing fields of RSCS maps); the same, per counted match. | when the map has healing |
| `Alpha: <n> wins` ... `Delta: <n> wins` | Counted match wins per team (section `Team Breakdown (Alpha / Bravo / Charlie / Delta)`). | when Charlie or Delta have match or round wins |
| `Alpha <n> wins (<x>%) [bar] (<y>%) <m> wins Bravo` | Match wins of Alpha against Bravo (section `Match Win Bias: Alpha [#] vs Bravo [=]`). | otherwise, when Alpha + Bravo wins are above 0 |
| `Alpha share is between <a>% and <b>% (95% confidence, <n> matches)` | Wilson 95% range of Alpha's win share. | same |
| `Alpha <n> rounds (<x>%) [bar] (<y>%) <m> rounds Bravo` | Survival rounds won by Alpha and Bravo (section `Survival Round Balance (Alpha vs Bravo)`). | when they have rounds and the current map has Survival on or there are more than 5 rounds |
| `Over the match (each 10%): <ten numbers>` | Average players on the teams in every tenth of a match, from the start to the end (section `Players on this Map`). The tenth follows from the time played and the time left, so it needs a time limit; seconds without players are not counted. `-` for a tenth without data. | when at least 60 such seconds were counted |
| `Voted in:` | Times a won vote chose this map. | section, shown when there is a curve, a measured map end or a vote |
| `Voted away:` | Votes started on this map that changed the map (the `won` of `Votes`). | same |
| `After the map <x>% stayed (<n> ends)` | Of the players on the teams when a match on this map ended (with statistics on), the share still on the server 120 s into the next map; a player who left and came back in between did not stay. `After the map: not measured yet` without data. | same |
| `Caps:` / `Returns:` / `Grabs:` | Flag captures, returns and grabs on the map (section `Objective Telemetry`). | in objective modes, or when the map has captures, returns or grabs |
| `Drops: <n> (<m> thr)` | Flags dropped and thrown. | same |
| `Fastest Cap: <x>s (by <name>) \| Avg Cap: <y>s` | Fastest capture on the map, timed from the capper's last grab (0.5 s or more, as `Fastest Cap` in `!otherstats`), and who made it; average over all timed captures. | same, when a fastest capture exists |
| `Deadliest: <weapon> (<n> kills)` | Weapon with the most counted kills on the map (section `Arsenal on this Map`). | when any weapon has kills or picks |
| `Top primary: <weapon> (<x>%)` | Primary weapon held most often at spawn on the map, and its share of the primary picks there. | same |
| `Alpha picks: <weapon> (<x>%)` / `Bravo picks: <weapon> (<x>%)` | The primary weapon Alpha players, and Bravo players, took most often at spawn on this map. | when a team has picks |
| `Top secondary: <weapon> (<x>%)` | The same for the secondaries (Socom, knife, chainsaw, LAW), which every player spawns with as well. | when any weapon has kills or picks |
| `[Kills]` | Top 3 players online by counted kills in this match (since the map started; section `Match Leaders (players on the server now)`). | only for the map that is running |
| `[Points]` | Top 3 by points change in this match (since the map started, or since they joined later). | same |
| `[Rounds]` | Top 3 by Survival rounds won in this match. | same, when the current map has Survival on |
| `[Caps]` | Top 3 by captures in this match. | same, in objective modes without Survival |

### !bal and /balinfo

`!bal` (`!teams`, or a chat line that is only `bal`), team modes only. Header `Team Balance`.

| Output | What it means |
| :--- | :--- |
| `<Team> <n> players [(<b> bots)] avg <s> power <p> chance <c>% score <x>` | One line per team: players, their average strength, the team's power (sum of the players' powers), its chance to win and its score. |
| `Status: ...` | What the balance does: `even`, `close enough`, `<Team> is stronger (x%)` with the seconds until a change or why none comes (the map is about to end, the match is decided, enough moves on this map, a move was made a moment ago, no change would help now), `the numbers differ by n` with the grace time and, after it, `nobody can be moved: <name> (<why>), ...` when nobody of the bigger team may go, a request for a volunteer, `waiting for n players`, `paused by an admin`, `the team balance is off`. |
| `Next: <name> to <team> after the next death (at most <time>)` | A planned change. ` now` instead when the move is on its way or its time is up; `(carries a flag)` when it waits for the death of a flag carrier; `(dropped after <time>)` in survival for a change that may still be dropped (a count fix and a swap under way never are). |
| `the balance moves you to <team> at your next death (at most <time>)` | The viewer is part of the planned change (` now` when the move is on its way). |
| `You: strength <s> = rating <r> (<g> games, counted as <e>) + form <f> x <w>` | The viewer's strength: the rating of the mode family, the value after the pull towards the median, the form on this map and its weight (`Method = blend`; `global` and `map` show only their part). A spectator sees how to join. |
| `the balance does not move you now: <why>` | carries a flag, excluded, being moved: the balance never moves the viewer then. |
| `you move only if nobody else can even the numbers: <why>` | carries the team (best form of the team), moved recently: protected for the chances, but uneven numbers move such a player when no free player can go. |
| `Switch: ...` | Only when `!switch` would take the viewer, with the same checks: `<Team> has <n> players, <Team> <m>: !switch moves you to <Team>`, `<Team> is stronger (x%): !switch moves you to <Team>`, or `!switch moves you to <Team>`. In survival, while the viewer is still alive, the line ends with `once you are dead`. |
| `you count as away (x% of your power) until you move` | No movement for `AfkSeconds`. |
| `Method: <method>, rating <skill>` | The settings `Method` and `Skill`. |

`/balinfo` (admins): the settings in use (`(tuned)` when `AutoTune` uses the fitted `SizeImpact` and `SkillPerDouble`), the state (running, paused, off or waiting for a team match; moves on this map; the last move; the median, the bot strength and the imbalance in points next to the one the balance acts above), the status, one line per player (slot, name, team, strength, rating, games, form, power and a note: `top` = best form of its team, `flag`, `moved` = moved recently, `moving`, `excluded`, `bot`, `away`), the team lines, the predictions (see [Team balance](#team-balance)), the best fit, the side factor of the map and the last ten decisions (the kind of a move in brackets: balance, volunteer, admin, join, join review, map start).

### !heatmap

`!heatmap [map]` (`!heat`). Header: `[ Where people die: <map> ]`.

- Every counted kill adds a kill at the killer's position and a death at the victim's position, in cells of 64 x 64 px (at most 4096 cells per map).
- The picture has 60 x 16 characters. Each character sums the kills and deaths of the cells that fall on it; `. : + * # @` go from few to many, relative to the busiest character.
- `A` and `B` mark the Alpha and Bravo flag bases when known (CTF and INF).
- A warning is printed when the map has fewer than 10 kills and deaths.
- `Hot spot 1..3: <upper|central|lower> <left|middle|right> part of the map - <k> kills made there, <d> deaths`: the three busiest single cells.
- `Nobody has died on <map> yet.` when the map has no cells.

### !topmaps and !topmapsby

`!topmaps [pg]` (`!topmapsp <pg>`): header `Top Maps [Page p/P] (Total: N)`, 10 per page, sorted by `Time` (ties: matches). `!topmaps <map>` and `!topmapsi <pos>` show the part around a map, marked ` <*>`. The running map is marked ` <actual>`.

| Column | What it means |
| :--- | :--- |
| `#` | Place by played time. |
| `Map Name` | Map name. |
| `Played Time` | Seconds the map ran while statistics were on. |
| `Matches` | Counted matches. |
| `Kills` | Counted kills. |
| `Selfs` | Selfkills (when the current mode is DM, PM or RM). |
| `Flags` | Flag captures (when the current mode is a team mode). |

`!topmapsby <metrics> [pg]`: header `Top Maps by <metrics> [Page p/P]`, 10 per page, up to 5 [map metrics](#map-metrics-topmapsby), ties by played time. With one metric the columns are `#`, `Map Name`, the metric, `Kills`, `Matches`, `Playtime` (a column equal to the metric is left out).

### !server

`!server` (`!serverstats`). Header: `Server Statistics & Activity Analytics`. Totals are sums over all accounts.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `Today:` | Accounts last seen today (section `Server Visitors & Retention`). | always |
| `Yesterday:` | Accounts counted as unique players in the daily record of yesterday (a player seen yesterday who is back again today still counts here: this is yesterday's own record, not a live query). | always |
| `7 Days:` / `14 Days:` / `30 Days:` / `90 Days:` / `365 Days:` | Accounts last seen within that many days. | always |
| `All-Time:` | Number of accounts. | always |
| `Visits: <n> sessions` | Sum of visits in the name history of every account (at least 1 per account). A join is a new visit when the previous session ended at least `[Mechanics] VisitCooldownMinutes` (15) ago. | always |
| `Returning (14d):` | Accounts seen within 14 days that have more than one visit, as a share of accounts seen within 14 days. | always |
| `Online:` | Humans on the server now, spectators included. | always |
| `New players (7d):` | Accounts created on one of the last 7 days that played a counted second on the day they were created. | always |
| `Came back: <x>% of the <n> accounts new since <date> played on 2+ days, <y>% on 7+` | Of the accounts created since the daily record began (the date named), the share with at least 2, and with at least 7, days played. | when at least one account was created since that date |
| `Peak Record: <n> players (held for <time> on <date>)` | Most humans online at once (spectators included); how long the count stayed at that record after it was set (until it first dropped, measured only while the server kept running); when it was set. `Peak Record: None` without data. | always |
| `Today` / `7 Days` / `14 Days` / `30 Days` bars | The visitor counts above as bars 60 characters wide, relative to the 30-day count (section `Player Activity (30-Day Benchmark & 24h Peak)`). | always |
| `24h Peak [<24 chars>] Peak: <hh>:00-<hh>:00 (<time>)` | Player seconds per hour of the day (all days), one character per hour: `.` up to 5%, `_` 25%, `-` 50%, `=` 75%, `+` 90%, `#` above, of the busiest hour; the busiest hour and its player time. Counted each second while statistics are on: humans in the game added up. `24h Peak: None` without data. | always |
| `Busiest hour of the week: <day> <hh>:00-<hh>:00 (whole week: !activity)` | Busiest weekday-hour cell (see `!activity`). | when weekday data exists |
| `Matches played:` | Counted matches on the server. | same line |
| `Recent Visitors:` | The three accounts seen most recently, with `<n>m ago`, `<n>h ago`, `yesterday` or `<n>d ago`. | always |
| `Kills:` / `Deaths:` / `Suicides:` | Counted kills, counted deaths, selfkills (section `Server Combat & Damage Telemetry`). | always |
| `Combat Dmg: <x> (~<y> kills)` | Damage dealt in enemy hits; y = damage / full health of the current mode. | always |
| `Assists:` / `Flag Caps:` | Assists and flag captures. | always |
| `Shots:` / `Hits: <n> (<x>%)` | Shots and enemy hits of accuracy weapons. | always |
| `Avg Dmg/Hit: <x> HP` | Damage of all weapons / enemy hits of all weapons (explosions, flames and melee included on both sides). | always |
| `Pace: <x> kills/h` | Kills x 3600 / total play time. | always |
| `Playtime:` | Sum of the play time of all accounts. | always |
| `FF Index: <x>% (TK: <n>)` | Teamkills / (kills + teamkills). | third cell when friendly fire is on |
| `Kills/Match: <x>` | Counted kills / counted matches. | third cell otherwise |
| `Head:` / `Body:` / `Legs:` `<n> (<x>%)` | Hits by zone and their share of hits. | always |
| `Top Gun (Kills): <weapon> (<n>)` | Weapon with the most kills (section `Server Hall of Fame & Weapon Mastery`). | always |
| `Top Gun (Damage): <weapon> (<dmg>)` | Weapon with the most damage dealt. | always |
| `Longest Kill: <x>m by <name>` | Longest kill of any account (`None` if none). | always |
| `Top Streak: <n> kills by <name>` | Best kill streak of any account (`None` if none). | always |
| `#1 Ranked Player: <name> (<p> pts, Rating: <x>)` | First place of the points ranking. | when the ranking is not empty |
| `MVP Today: <name> (<+n> pts)` | Account with the largest points change today among accounts with a kill or death today (`None` if none). | always |

### !activity

Header: `Server Activity: Week by Hour`. The data is the same player-second counter as the 24h line of `!server`, split by weekday and hour of the server clock, for all time.

| Label as shown | What it means |
| :--- | :--- |
| Rows `Mon` ... `Sun` | One row per weekday, Monday first. |
| Columns `00` ... `23` | Hour of the day. A cell shows `..`, `::`, `++`, `**`, `##` or `@@` (6 levels relative to the busiest cell of the week); blank = nobody played. |
| `Day%` | The weekday's share of all counted play time. |
| `Most players:` | The three busiest weekday hours. |
| `Busiest day: <day> (<x>% of all play time)` | Weekday with the most play time. |
| `Total play time:` | Sum of all cells (player seconds). |

`No activity recorded yet - it is counted while enough players are on the server.` when there is no data.

### HUD and messages

The HUD line is sent by `RefreshHud` once per second for every human when the text changed, and otherwise every `[HUD] RefreshSeconds` (3).

| Output | What it means | When it is shown |
| :--- | :--- | :--- |
| `Rank: <r>/<N>  Points: <p>` | Position in the points ranking (0 when hidden) / accounts in it; current points. Event notes of the last second follow on the same line (at most 4). | when `[HUD] Enabled` is on, the account has `!hud` switched on and the player is not a spectator. New accounts start with the HUD off (on with `[HUD] DefaultOn = 1`). |
| `Not logged in - stats are not saved` | The account is password protected and the player is not logged in. | instead of the rank line |
| `+<n> pts`, `+<n> pts (inactive victim)`, `-<n> pts` | Points of a counted kill for killer and victim; a kill or a capture that pays 0 points gives no note. | notes |
| `-<n> pts selfkill`, `-<n> pts selfkill under fire`, `+<n> pts (selfkill of <name>)` | Selfkill points. | notes |
| `-<n> pts teamkill`, `Teamkill - no points` | Teamkill. | notes |
| `+<n> pts capture`, `+<n> pts team capture`, `-<n> pts enemy capture` | Capture points (CTF pool or fallback). | notes |
| `KILLING SPREE!`, `RAMPAGE!`, `DOMINATING!`, `UNSTOPPABLE!`, `GODLIKE!` | Streak of 5, 10, 15, 20, 25. | notes |
| `Double kill!`, `Triple kill!`, `Multi kill!` | Multi-kill levels 2-4 (higher levels have no note). | notes |
| `FIRST BLOOD!`, `Long shot: <n> m`, `Shut down <name>'s spree`, `Dominating <name>`, `<name> is dominating you`, `Domination ended!`, `Revenge!`, `Flag carrier down`, `Finisher`, `Assist`, `Savior`, `Avenger` | The feat was counted. | notes |
| `Flag juggle`, `Held the flag under fire`, `Last man standing!`, `Last stand vs <n>`, `Clutch won!` | The feat was counted. | notes |
| `Welcome <name>! Rank <r>/<N>, <p> points.` | Welcome after joining (to the player, or to everybody with `WelcomeBroadcast`). | `[Messages] WelcomeEnabled`, not for spectators or players not logged in |
| `<name> unlocked "<achievement>"` / `Achievement unlocked: <achievement>` | New achievement, to everybody or only to the player. | `[Messages] AchievementBroadcast` decides |
| `Round won by <team>` / `Round won by <team> - clutch by <name>!` | End of a Survival round; in DM/PM/RM `Round won by <name>` names the last one standing. | Survival and `RoundWinBroadcast` |
| `Match over: <team> wins <a>:<b>` / `Match over: <name> wins with <n>` | End of a counted match with a winner; a free-for-all where nobody is ahead gives `Match over: a draw with <n>`. | `RoundWinBroadcast` |
| `[Balance] ...` | Team balance messages: why a join went to another team, a planned change (`you will play for Bravo after your next death`), a change made (`X moved to Bravo (Alpha 64% -> 51%)`), a request for a volunteer, a new split at the start of a map. | `[Balance] Enabled`; broadcasts with `Announce` |

### /zs_status

Admins only.

Without an argument (library status):

| Output | What it means |
| :--- | :--- |
| `[ZitroStats 5.2] <a> accounts, <m> maps, <o> online, read-only: <no/YES>` | Accounts, map records, humans online, whether saving is off. |
| `journal gen <g>, <k> KB since the last snapshot, IO queue <q> KB, dropped events <d>` | Storage state; events dropped because the queue was full. |
| `load: <message>` | Load problem or restore note, if any. |
| `shared database: connected, <n> exchanges, <w> changes written, <r> read, last <s> s ago` | `[MySQL] Engine = mysql`: the exchange with the database of every server. `not answering (<why>), the changes wait` while it does not answer; `not reached yet (<why>), working from the files` after a start without it; `off until the next start - <why>` when nothing is exchanged until a restart (README, Troubleshooting). |

With an account (`/zs_status <name or #id>`, `/zs_statusid <id>`, `/zs_statusi <pos>`): header `[ Admin Audit: <name> ]`.

| Label as shown | What it means | When it is shown |
| :--- | :--- | :--- |
| `DB ID:` | Account number. | always |
| `Slot:` | Server slot, or `Offline`. | always |
| `Rank:` | Position in the points ranking or `-`. | always |
| `Points:` / `Rating: <x>` / `Protect: <n> days` | As in `!status`. | always |
| `Steam:` | SteamID, or `none (computer account)`. | always |
| `IP:` | Last IP address. | always |
| `HWID:` | Last hardware ID. | always |
| `Names (<n>), last used:` | Number of stored names; the three used most recently. | always |
| `Most played:` | The three names with the most time on the server (time on a team, counted also while statistics are off; added when the player leaves). | always |
| `Most joins:` | The three names with the most visits. | always |
| `First Seen:` / `Last Seen:` | Account creation; last join or leave (date and time). | always |
| `Playtime:` / `Spectator:` | Play time and spectator time. | always |
| `K/D: <ratio> (<k>/<d>)` | Counted kills and deaths, and their ratio. | always |
| `Selfkills: <n> (<x>%)` | Selfkills and their share, see `[Ranking] SelfkillPercentBase`. | always |
| `Under fire: <n> (<x>%)` | Selfkills within `AssistSeconds` of a hit by a human enemy (both selfkill modes), and their share of selfkills. The row turns orange when under-fire selfkills x 10 exceed max(20, deaths). | always |
| `Teamkills:` | Teamkills made. | in a team mode with friendly fire on, or when the account has teamkills |
| `Password: set <date>` / `E-mail: <masked> (verified or not verified)` or `no e-mail` | Password date and recovery address. | registered accounts |
| `Trusted devices:` / `Failed logins:` / `LOCKED` or `not locked` | Trusted computers, wrong passwords in a row, login lock. | registered accounts |
| `Password: none (unregistered account)` | No password. | other accounts |

### /zs_suspects

Admins only. Prints `[ZitroStats] <n> notes: suspicious kill series and the daily report (newest first, HWID/IP in suspicious.log):` and up to 15 of the newest lines. Without notes it prints `No suspicious kill series and no notes from the daily report.` and points to `logs/zitrostats/suspicious.log` for the full history. The list also holds the last 30 lines of `suspicious.log` read at start, so it survives a restart. Nothing here changes points.

| Line | When it is written |
| :--- | :--- |
| `<killer> (#id) killed <victim> (#id) <n> times within <m> min, the victim killed <k>; <h> players on the server` | A killer made `[AntiFarm] SuspiciousKills` (10) counted kills of the same victim within `SuspiciousWindowMinutes` (10, counted from the first of them), the victim made at most `SuspiciousVictimMaxKills` (1) kills on that map meanwhile, and at most `SuspiciousMaxHumans` (4) humans were in the game. Logged once per window. |
| `<n> accounts last used the same computer: ...` / `... came from the same address: ...` | Daily scan with the balance (`SharedDevices`): accounts whose last HWID or last IP is the same. |
| `#<id> <name>: headshots at least <x>% of <n> hits (server <y>%)` | Daily scan (`Outliers`): accounts with at least 200 hits whose head-hit share (lower end of the 95% Wilson range) is above twice the server average and above 35%. |
| `#<id> <name>: accuracy at least <x>% of <n> shots (server <y>%)` | Same scan: at least 500 shots, lower end of the accuracy range above 1.8 times the server average and above 60%. |

The daily outlier scan runs only when the server has at least 2000 hits and 5000 shots in total, and reports at most 12 accounts per scan.

### /zs_perf

Admins only. Diagnostics, no player statistics.

| Output | What it means |
| :--- | :--- |
| `[ZitroStats 5.2] engine timing since <date>` | Start of the measurement. |
| `events: <n>, avg <x> ms, max <y> ms, largest batch <b>, queued now <q>, dropped <d>` | Game events applied, time per event, queue size. |
| `timers: <n> runs, avg <x> ms, max <y> ms` | Timer passes of the engine thread. |
| `data: <a> accounts, <h> free slots, <m> maps, <s> archived seasons` | Data sizes. |
| `storage: journal gen <g>, <k> KB since the last snapshot, IO queue <q> KB, snapshot running: <yes/no>` | Storage state, or `storage: read-only, nothing is saved`. |
| `service: <n> password jobs waiting` | Background password hashing queue. |

---

## Metrics for !topby, !topweaponsby and !topmapsby

### Player metrics (!topby)

The first alias that matches wins; names are not case sensitive. "Lower is better" metrics sort a value of 0 last.

| # | Aliases | Header | What it means |
| ---: | :--- | :--- | :--- |
| 0 | points pts point | Points | Current points. |
| 1 | rating rate | Rating | Rating index for the current mode (`RatingMode`). |
| 2 | tier division | Tier | Tier from `[Ranks]` (best tier first), shown by name. It uses the tier rules even when leagues are enabled. |
| 3 | skill | Skill | Value of `RankingSystem` for the current family: Glicko-2 conservative value, OpenSkill ordinal or MMR (0 if unrated); with `elo` the MMR, as in `!topskill`. |
| 4 | kills kill k | Kills | Counted kills. |
| 5 | deaths death d | Deaths | Counted deaths. |
| 6 | kdr kd ratio | K/D | Kills / max(1, deaths). |
| 7 | selfkills self selfs suicide suicides | Selfs | Selfkills. |
| 8 | assists assist ast | Assists | Assists. |
| 9 | shots shot | Shots | max(shots, hits), accuracy weapons. |
| 10 | hits hit | Hits | Enemy hits with accuracy weapons. |
| 11 | acc accuracy | Acc% | Hits / shots. |
| 12 | dmg damage dmgdealt damagedealt dealtdmg | Damage | Damage dealt to enemies. |
| 13 | dmgtaken damagereceived dmgrec dmgin | DmgTaken | Damage received from enemies. |
| 14 | dmgratio damageratio dr | DmgRatio | Dealt / taken. |
| 15 | dmgkills damagekills | DmgKills | Damage dealt / full health of the current mode (150, or 65 in Realistic). |
| 16 | dmgdeaths damagedeaths | DmgDeaths | Damage received / full health of the current mode. |
| 17 | tkdmg friendlydmg | TK_DmgOut | Damage dealt in friendly hits. |
| 18 | tkdmgrec friendlydmgrec | TK_DmgIn | Damage received in friendly hits. |
| 19 | longkill longestkill maxdist | LngKill | Longest counted kill (m). |
| 20 | barretkill barrettkill barretdist longestbarret | BarrettLng | Longest Barrett kill (m). |
| 21 | avgdist avgdistance meandist | AvgDist | Average kill distance (m). |
| 22 | long100 kills100 | 100m+ | Kills from 100 m or more. |
| 23 | barrettlong | BarrettLong | Barrett kills from 75 m or more. |
| 24 | hs headshots headshot head | HS | Head hits on enemies. |
| 25 | hsacc hs% | HS% | Head hits / hits. |
| 26 | chest body | Body | Body hits on enemies. |
| 27 | bodyacc body% | Body% | Body hits / hits. |
| 28 | legs leg | Legs | Leg hits on enemies. |
| 29 | legacc leg% | Leg% | Leg hits / hits. |
| 30 | maxstreak streak killstreak | Streak | Best kill streak in one life. |
| 31 | double doublekills dk | Double | Double kill medals. |
| 32 | triple triplekills | Triple | Triple kill medals. |
| 33 | multi multikills mk | Multi | Multi kill medals (4th kill of a chain). |
| 34 | multix2 multi2 | MultiX2 | 5th kill of a chain. |
| 35 | serial serialkill | Serial | 6th kill of a chain. |
| 36 | insane insanekills | Insane | 7th kill of a chain. |
| 37 | multi57 bigmulti | Multi5-7 | Sum of the MultiX2, Serial and Insane medals (5th to 7th kill of a chain). |
| 38 | gimme gimmemore | Gimme | 8th kill of a chain. |
| 39 | masta mastakilla | Masta | 9th to 11th kill of a chain. |
| 40 | stopit stop | StopIt | 12th kill of a chain. |
| 41 | mercy | Mercy | 13th kill of a chain. |
| 42 | cheater | Cheater | 14th and later kills of a chain. |
| 43 | firstblood fb | FBlood | First bloods. |
| 44 | firstdmg firstdamage fd | FDmg | First damage of a match or round. |
| 45 | laststand ls | LastStand | Last stands. |
| 46 | clutches clutch | Clutches | Clutches won. |
| 47 | dom doms dominations dominating | Doms | Dominations (3 kills in a row on one player). |
| 48 | revenge | Revenge | Domination-ending kills + revenge kills. |
| 49 | posthumous postromus post | Post | Kills made after the killer died. |
| 50 | savior | Savior | Savior kills. |
| 51 | avenger | Avenger | Avenger kills. |
| 52 | pmscore extrapoints | PMScore | Pointmatch bonus points. |
| 53 | caps flags flag captures | Caps | Flag captures. |
| 54 | returns ret | Returns | Flag returns. |
| 55 | grabs grab | Grabs | Flag grabs. |
| 56 | drops drop flagdeny | Drops | Flags dropped (not thrown). |
| 57 | fkills flaggerkills | FKills | Kills of flag carriers. |
| 58 | flagassist fkillsassist | FAssist | Assists on kills of flag carriers. |
| 59 | saviorflag fdefense | FDefense | Savior kills protecting a flag carrier. |
| 60 | flagtime timeholdingflags | FlagTime | Seconds alive carrying a flag. |
| 61 | killswithflag | FlagKills | Kills made while carrying a flag. |
| 62 | fastcap fastestcap | FastCap | Fastest capture in seconds (lower is better). |
| 63 | escort carrierescort | Escort | Escort kills. |
| 64 | juggles juggle flagjuggle | Juggles | Flag juggles. |
| 65 | contested contestedhold | Contest | Contested holds (HTF). |
| 66 | fastcaps capsunder10 | Caps<10s | Captures less than 10 s after the grab (0.5 s or more). |
| 67 | htfpoints htfscore | HTFPts | HTF points scored as carrier. |
| 68 | htftime htfholdtime | HTFTime | HTF seconds carrying the flag. |
| 69 | htfteamtime | HTFTeam | HTF seconds alive while the own team carried a flag. |
| 70 | wins win w | Wins | Match wins. |
| 71 | losses loses lose l | Losses | Match losses. |
| 72 | draws draw | Draws | Match draws. |
| 73 | winrate wr win% | Win% | Wins / (wins + losses). |
| 74 | rwins roundswon rw | RWins | Survival rounds won. |
| 75 | rlost roundslost rl | RLost | Survival rounds lost. |
| 76 | roundwr roundrate | Round% | Rounds won / rounds played. |
| 77 | roundratio rr | RRatio | Rounds won / max(1, rounds lost). |
| 78 | advrounds advr | AdvRnd | Rounds played with Advance on. |
| 79 | advwins advw | AdvWin | Rounds won with Advance on. |
| 80 | comebacks comebackwins | Comebacks | Comeback wins. |
| 81 | leaverlosses leaves | LeftLost | Losses for leaving a match. |
| 82 | time timeplayed playtime | Time | Play time. |
| 83 | timealive alive survival | Alive | Time alive (survival seconds). |
| 84 | lifespan avglife avglifespan | Lifespan | Time alive / max(1, ended lives), as `Avg Life` in `!stats`. |
| 85 | timedead timedeath | Dead | Seconds dead while on a team, counted like time alive (statistics on and at least `MinHumansForSurvival` humans). |
| 86 | spec spectator spectime | Spec | Spectator time. |
| 87 | longestlife longlife | LongLife | Longest life. |
| 88 | days daysplayed | Days | Days played. |
| 89 | protect protection | Protect | Protection days. |
| 90 | pace kph | Kills/h | Kills x 3600 / play time. |
| 91 | traveled distance km | Km | Distance moved in km. |
| 92 | flytime jets jet fly | FlyTime | Jet flight time. |
| 93 | tk teamkills | TK | Teamkills. |
| 94 | tked deathsbyfriendly | TKed | Deaths by a teammate. |
| 95 | friendlyhits tkhits | TKHits | Friendly hits made. |
| 96 | friendlyhitsby tkedhits | TKedHits | Friendly hits received. |
| 97 | favvictim victim | FavVictim | Kill count of the top victim. |
| 98 | nemesis | Nemesis | Death count by the top nemesis. |
| 99 | stabs stab | Stabs | Knife stabs on enemies. |
| 100 | throws knifethrows | Throws | Knife throws. |
| 101 | knifehits | KnifeHit | Thrown knife hits on enemies. |
| 102 | knifeacc | KnifeAcc | Thrown knife hits / throws. |
| 103 | sawhits | SawHits | Chainsaw damage events on enemies. |
| 104 | sawtime | SawTime | Seconds holding the chainsaw (larger of the two stored counters). |
| 105 | nades nade grenades | Nades | Frag grenade throws. |
| 106 | nadehits | NadeHits | Frag grenade damage events on enemies. |
| 107 | nadeacc | NadeAcc | Nade hits / throws. |
| 108 | cluster clusternades | Cluster | Cluster grenade throws. |
| 109 | clusterhits | ClustHit | Cluster damage events on enemies. |
| 110 | fists punch | Fists | Fist hits on enemies. |
| 111 | m79shots | M79Shots | M79 shots. |
| 112 | m79hits | M79Hits | M79 damage events on enemies. |
| 113 | m79acc | M79Acc | M79 hits / shots. |
| 114 | lawshots | LAWShots | LAW shots. |
| 115 | lawhits | LAWHits | LAW damage events on enemies. |
| 116 | lawacc | LAWAcc | LAW hits / shots. |
| 117 | flamershots | FlamerSh | Flamer shots. |
| 118 | flamerhits | FlamerHit | Flamer damage events on enemies. |
| 119 | flameracc | FlamerAcc | Flamer hits / shots. |
| 120 | statgun m2mg m2 | M2_Hits | Stationary gun hits on enemies. |
| 121 | rambo killrambo | Rambo | RM kills of a bow holder. |
| 122 | bowkills | BowKills | Larger of the RM bow kills and the Rambo Bow weapon kills. |
| 123 | bowtime | BowTime | RM seconds holding a bow. |
| 124 | prone pronekills | Prone | Prone kills. |
| 125 | camp campkill campkills camper | Camp | Camp kills. |
| 126 | bink binkrecovery binkkills | Bink | Bink recovery kills. |
| 127 | airkills air | AirKills | Air kills. |
| 128 | heightkills height | Height | Height kills. |
| 129 | vestkills vest | VestKills | Kills of vest wearers. |
| 130 | nadekills grenadekills | NadeKills | Frag and cluster grenade kills. |
| 131 | explomulti explosionmulti | ExploMulti | Explosive multi-kills. |
| 132 | knifestreak knifelife | KnifeStreak | Most knife kills in one life. |
| 133 | spawnkills | SpawnKills | Spawn kills. |
| 134 | spawndeaths | SpawnDeaths | Spawn deaths. |
| 135 | ttk avgttk | AvgTTK | Average time to kill in seconds (lower is better). |
| 136 | bestttk | BestTTK | Best time to kill in seconds (lower is better). |
| 137 | spree sprees streak5 | Streak5 | Streaks that reached 5. |
| 138 | rampage rampagespree rampage10 streak10 | Streak10 | Streaks that reached 10. |
| 139 | domspree dominatingspree streak15 | Streak15 | Streaks that reached 15. |
| 140 | unstoppable streak20 | Streak20 | Streaks that reached 20. |
| 141 | godlike streak25 | Streak25 | Streaks that reached 25. |
| 142 | shutdowns shutdown | ShutDowns | Shut down kills. |
| 143 | finishers finisher | Finishers | Finisher kills. |
| 144 | seasonpoints season spts | SeasonPts | Points of the season stored on the account. |
| 145 | achievements ach | Achiev | Unlocked achievements. |
| 146 | badges | Badges | Season badges. |
| 147 | cover coverlive wallkills throughcover | CovLive | Cover (live) kills. |
| 148 | mmr hots | MMR | MMR of the current family (0 if unrated). |
| 149 | glicko glicko2 | Glicko | Glicko-2 conservative value of the current family (0 if unrated). |
| 150 | openskill | OpenSkill | OpenSkill ordinal of the current family (0 if unrated). |
| 151 | forced forcedselfkills forcedsuicides | Forced | Forced selfkills. |
| 152 | underfire suicidesunderfire | UnderFire | Own selfkills under fire. |
| 153 | covershot shotcover | CovShot | Cover (shot) kills. |
| 154 | balmoves balancemoves moved | BalMoves | Moves by the team balance. |
| 155 | volunteered volunteers volunteer | Volunteer | `!switch` moves that evened the match. |
| 156 | healed healing heal hp | Healed | Health got back, all told: regen + kits. |
| 157 | regen regenerated fields | Regen | Health got back from regenerating polygons (the healing fields of RSCS maps). |
| 158 | healkits healingkits | HealKits | Medical, berserker and predator kits that healed (`Heal Kits` of `!stats`). |
| 159 | kits allkits | Kits | Every kit picked up, all kinds together. |
| 160 | medkits medikits | MedKits | Medical kits picked up. |
| 161 | nadekits grenadekits | NadeKits | Grenade kits picked up. |
| 162 | clusterkits | ClusterKits | Cluster grenade kits picked up. |
| 163 | vestkits | VestKits | Vest kits picked up. |
| 164 | berserkkits berserkerkits | BerserkKits | Berserker kits picked up. |
| 165 | predatorkits | PredatorKits | Predator kits picked up. |
| 166 | flamerkits | FlamerKits | Flamer kits picked up. |

### Weapon-based player metrics

A word that is not a player metric is read as a weapon: `<weapon>` ranks by kills with it, and a suffix gives another value (for example `aktime`, `spasacc`). Named metrics come first, so `nade`, `cluster`, `fists`, `m2`, `rambo`, `sawtime`, `bowtime`, `knifeacc`, `m79acc`, `lawacc` and `flameracc` mean the table entries above, not the weapon values.

| Form | Header | What it means |
| :--- | :--- | :--- |
| `<weapon>` | `<Short>` | Kills with the weapon (with the 4.x larger-of rule). |
| `<weapon>time` | `<Short>Tm` | Seconds held. |
| `<weapon>acc` | `<Short>Ac%` | Weapon hits / weapon shots. |
| `<weapon>hs` | `<Short>HS` | Head hits with the weapon. |
| `<weapon>dmg` | `<Short>Dmg` | Damage dealt with the weapon. |

Weapon names (short name in brackets, used as header and as key in `players.json` in lower case):

| Weapon | Names accepted |
| :--- | :--- |
| USSOCOM (Socom) | socom, ussocom, colt, pistol, pistolet, 0 |
| Desert Eagles (Deagle) | deagle, deagles, desert, deserteagle, deserteagles, de, 1 |
| HK MP5 (MP5) | mp5, mp5k, hk, hkmp5, heckler, 2 |
| AK-74 (AK) | ak, ak74, ak47, kalash, kalasz, kalashnikov, kalaszek, 3 |
| Steyr AUG (AUG) | aug, steyr, steyraug, 4 |
| Spas-12 (Spas) | spas, spas12, shotgun, pompka, szotgan, 5 |
| Ruger 77 (Ruger) | ruger, ruger77, rug, 6 |
| M79 (M79) | m79, grenadelauncher, gl, granatnik, 7 |
| Barrett M82A1 (Barrett) | barret, barrett, barretm82a1, barrettm82a1, m82, m82a1, sniper, snajper, snajperka, 8 |
| FN Minimi (Minimi) | minimi, fnminimi, m249, fn, 9 |
| XM214 Minigun (Minigun) | minigun, xm214, xm, gatling, chaingun, mini, 10 |
| Combat Knife (Knife) | knife, combatknife, noz, nozyk, kosa, 11, 53 |
| Chainsaw (Saw) | chainsaw, saw, pila, pilka, 12 |
| M72 LAW (LAW) | law, m72, m72law, bazooka, rocket, rpg, rakieta, 13 |
| Flamer (Flamer) | flamer, flame, flamethrower, miotacz, ogien, 14 |
| Rambo Bow (Bow) | bow, rambo, rambobow, luk, 15 |
| Flamed Arrows (FlameBow) | arrow, arrows, flamedarrows, flamebow, strzala, strzaly, 16 |
| Stationary Gun (StatGun) | statgun, stationary, stationarygun, m2, m2mg, turret, ckm, 30 |
| Fists (Fists) | fist, fists, hand, hands, punch, piesc, piesci, 255 |
| Grenade (Nade) | nade, nades, grenade, grenades, granat, granaty, frag, 50 |
| Cluster Grenade (Cluster) | cluster, clusters, clusternade, klaster, 51, 52 |

### Weapon metrics (!topweaponsby)

The same names sort `!allweaponsby` and `!serverweaponsby`. With `!allweaponsby` every value is the account's own, and the values of the server record - 12, 13, 14, 15, 17, 18 and 28 - are not there: an account keeps no kill distances, times to kill, picks or vest kills of its own.

| # | Aliases | Header | What it means |
| ---: | :--- | :--- | :--- |
| 0 | kills kill k | Kills | Counted kills with the weapon, all accounts. |
| 1 | deaths death d | Deaths | Counted deaths caused by the weapon. |
| 2 | kd kdr | K/D | Kills / max(1, deaths). |
| 3 | shots shot | Shots | Shots; `-` for the chainsaw and the flamer (their fuel is no shot), the fists and the stationary gun (whose shots are not seen). |
| 4 | hits hit | Hits | Enemy hits. |
| 5 | acc accuracy | Acc% | Hits / shots. |
| 6 | hs headshots head | Headshots | Head hits. |
| 7 | hs% hsacc | HS% | Head hits / hits. |
| 8 | dmg damage | Damage | Damage dealt. |
| 9 | dmgtaken dmgin | DmgIn | Damage received from the weapon. |
| 10 | dmgratio dr | DmgRatio | Dealt / received. |
| 11 | time playtime usage | Time | Seconds held, all accounts. |
| 12 | avgdist distance dist | AvgDist | Server average kill distance. |
| 13 | ttk avgttk | AvgTTK | Server average time to kill (lower is better). |
| 14 | picks pick popularity | Picks | Times held at spawn. |
| 15 | vestkills vest | VestKills | Kills of vest wearers. |
| 16 | longest longkill | Longest | Longest kill of any account. |
| 17 | alphapicks picksalpha | AlphaPicks | Picks by players in Alpha. |
| 18 | bravopicks picksbravo | BravoPicks | Picks by players in Bravo. |
| 19 | reloads reload | Reloads | Reloads started (see Reload). |
| 20 | reloadtime rtime | AvgReload | Average length of a finished reload (lower is better). |
| 21 | finished reloaddone | Finished% | Finished reloads / reloads started. |
| 22 | progress reloadprogress | Progress% | How far a reload gets before it ends, on average. |
| 23 | rdeaths reloaddeaths | DiedReloading | Deaths in the middle of a reload. |
| 24 | rdeath% reloaddeath% | DiedRel% | Those deaths / reloads started. |
| 25 | manual manual% | Manual% | Reloads started with rounds left / reloads started. |
| 26 | dropped roundsdropped | RoundsLost | Rounds thrown away by manual reloads. |
| 27 | reloading reloadingtime | Reloading | Time spent reloading. |
| 28 | pick% pickshare | Pick% | Share of the picks of its group: the primaries, or the secondaries (Socom, knife, chainsaw, LAW). |
| 29 | killeq dmgk | DmgKills | Damage dealt as kills: damage / full health of the current mode. |
| 30 | deatheq dmgd | DmgDeaths | Damage received as deaths. |
| 31 | dmgperkill dpk | Dmg/Kill | Damage dealt per kill (lower is better). |
| 32 | dmgperdeath dpd | Dmg/Death | Damage received per death. |
| 33 | kdmgratio kdmg | KDmgRatio | Dmg/Kill / Dmg/Death (lower is better). |

### Map metrics (!topmapsby)

| # | Aliases | Header | What it means |
| ---: | :--- | :--- | :--- |
| 0 | time playtime duration | Playtime | Seconds the map ran with statistics on. |
| 1 | matches plays games | Matches | Counted matches. |
| 2 | kills kill k | Kills | Counted kills. |
| 3 | selfkills suicides self | Selfkills | Selfkills. |
| 4 | pace | Kills/min | Kills x 60 / played seconds. |
| 5 | avgmatch | AvgMatch | As `Avg Match` in `!mapstats` (0 before the first measured match). |
| 6 | joins traffic | Joins | Human joins. |
| 7 | leaves | Leaves | Human leaves. |
| 8 | quitrate qr | QuitRate | Leaves / joins. |
| 9 | kicks | Kicks | Kicks. |
| 10 | spec specjoins | SpecJoins | Spectator joins. |
| 11 | caps flags | Caps | Flag captures. |
| 12 | returns | Returns | Flag returns. |
| 13 | grabs | Grabs | Flag grabs. |
| 14 | drops | Drops | Flags dropped. |
| 15 | thrown | Thrown | Flags thrown. |
| 16 | rwins rounds | Rounds | Survival round wins of all four teams together. |
| 17 | fastcap speed | FastCap | Fastest capture (lower is better). |
| 18 | comebacks comeback | Comebacks | Comeback matches. |
| 19 | close closematches | CloseMatch | Close matches. |
| 20 | draws | Draws | Draws. |
| 21 | aborted | Aborted | Aborted matches. |
| 22 | loads | Loads | Map starts. |
| 23 | humans avghumans | AvgHumans | Average humans in the game. |
| 24 | avgcap | AvgCap | Average capture time (lower is better). |
| 25 | votes | Votes | Map votes started. |
| 26 | votedin chosen | VotedIn | Won votes that chose the map. |
| 27 | votedaway votewins | VotedAway | Votes on the map that changed it. |
| 28 | stayed retention | Stayed% | Share of the players who stayed after the map (0 without data). |
| 29 | leftafter emptying | LeftAfter% | 100 - Stayed% (0 without data): the maps after which the server empties first. |
| 30 | endplayers lastplayers | EndPlayers | Average players in the last tenth of a match. |

---

## Achievements

Achievements need `[Achievements] Enabled = 1`. The code checks them for an account after it makes a counted kill, after it captures a flag, when it wins a Survival round, and when it gets a match result (in free-for-all only when the match had a winner or was a draw, with at least two players). A goal reached at another moment (for example returns, play time, days played, distance, the ranking place or a season badge) unlocks at the next of these events. `!achlist` shows the "Goal" text.

| Id | Name | Goal (as shown) | Exact condition |
| ---: | :--- | :--- | :--- |
| 1 | First Blood | your first kill | Kills >= 1 |
| 2 | Soldier | 100 kills | Kills >= 100 |
| 3 | Veteran | 1000 kills | Kills >= 1000 |
| 4 | Legend | 10000 kills | Kills >= 10000 |
| 5 | Headhunter | 500 headshot kills | Headshot kills of all weapons together >= 500 |
| 6 | Long Shot | a kill from 100 m | Longest kill >= 100 m |
| 7 | Sniper Elite | 50 Barrett 75 m+ | Barrett kills from 75 m or more >= 50 |
| 8 | Flag Runner | 50 flag caps | Flag captures >= 50 |
| 9 | Defender | 100 flag returns | Flag returns >= 100 |
| 10 | Rampage | <n> kills in a row | A streak reached the kills of the `[Sprees]` level named Rampage (5 with the built-in levels; 10 when no level has that name) |
| 11 | Godlike | <n> kills in a row | A streak reached the kills of the `[Sprees]` level named Godlike (25 with the built-in levels; 25 when no level has that name) |
| 12 | Blade Master | 100 knife kills | Combat Knife weapon kills (melee and thrown) >= 100 |
| 13 | Grenadier | 100 grenade kills | Frag + cluster grenade kills >= 100 |
| 14 | Team Player | 250 assists | Assists >= 250 |
| 15 | Guardian | 100 savior kills | Savior kills >= 100 |
| 16 | Marathon | 100 hours played | Play time >= 360000 s |
| 17 | Regular | 100 days played | Days played >= 100 |
| 18 | Winner | 100 matches won | Match wins >= 100 |
| 19 | Clutch King | 25 clutches won | Clutches won >= 25 |
| 20 | Speed Runner | 10 caps under 10 s | Captures less than 10 s after the grab (0.5 s or more) >= 10 |
| 21 | Survivor | 10 min in one life | Longest life >= 600 s |
| 22 | Finisher | 100 finisher kills | Finisher kills >= 100 |
| 23 | Comeback | 10 comeback wins | Comeback wins >= 10 |
| 24 | Top 10 | ranking top 10 | Points ranking position 1-10 while the ranking holds at least 30 accounts |
| 25 | Butcher | 5 knife kills/life | Most knife kills in one life >= 5 |
| 26 | Immortal | 25000 kills | Kills >= 25000 |
| 27 | Centurion | 100 kills in a day | Counted kills of the current day >= 100 |
| 28 | Spree Master | 100 5-kill streaks | Streaks that reached 5 >= 100 |
| 29 | Masta Killa | 9-kill multi-kill | Masta Killa medals >= 1 (a chain reached its 9th kill) |
| 30 | Sharpshooter | 35% acc, 5000 shots | max(shots, hits) >= 5000 and hits x 100 >= that number x 35 |
| 31 | Brain Surgeon | 2000 headshot hits | Head hits on enemies >= 2000 |
| 32 | Far Sight | 100 kills of 100 m | Kills from 100 m or more >= 100 |
| 33 | Sky Hunter | 100 kills in flight | Air kills >= 100 |
| 34 | High Ground | 100 height kills | Height kills >= 100 |
| 35 | Rambo Slayer | kill Rambo 100x | RM kills of a bow holder >= 100 |
| 36 | Wallbanger | 50 kills thru cover | Cover (live) kills >= 50 |
| 37 | Demolition | 25 explosive multis | Explosive multi-kills >= 25 |
| 38 | Arsenal | kill with 14 guns | At least 1 kill with 14 of the 21 weapon slots (fists, grenades and the stationary gun count as slots) |
| 39 | Weapon Master | 100 kills, 10 guns | At least 100 kills with each of 10 weapon slots |
| 40 | Chainsaw Maniac | 100 chainsaw kills | Chainsaw weapon kills >= 100 |
| 41 | Bow Master | 100 bow kills | Rambo Bow + Flamed Arrows weapon kills >= 100 |
| 42 | Flag Master | 250 flag caps | Flag captures >= 250 |
| 43 | Flag Hunter | 100 flagger kills | Kills of flag carriers >= 100 |
| 44 | Iron Wall | 100 base defenses | Base defense kills >= 100 (CTF and INF only) |
| 45 | Raider | 100 base attacks | Base attack kills >= 100 (CTF and INF only) |
| 46 | Holder | HTF: 30 min on flag | HTF seconds carrying the flag >= 1800 |
| 47 | Round Winner | 250 rounds won | Survival rounds won >= 250 |
| 48 | Point Hunter | 500 PM bonus pts | Pointmatch bonus points >= 500 |
| 49 | Globetrotter | travel 1000 km | Distance moved >= 1000000 m |
| 50 | Champion | win a season | The account has a season badge with place 1 |

Weapon-slot conditions (12, 38-41) use the stored per-weapon kills, without the 4.x larger-of rule.

---

## Ratings, points and leagues

The account keeps points, the Rating index, MMR, Glicko-2 and OpenSkill at the same time. `[Ranking] RankingSystem` (`elo`, `mmr`, `glicko2`, `openskill`; default `elo`) only decides which rating drives `!topskill`, the `skill` metric, the skill cell of `!stats` and the `rating_system`/`skill_*` export keys. The tiers follow `TierBy` (see Tiers below), whatever the `RankingSystem`. With `elo` the points make the ranking, and `!topskill`, the `skill` metric and `skill_*` use the MMR. `!top` always ranks by points.

### Points

- **Start.** A new account gets `StartingPoints` (1000).
- **Kill.** `MaxPointGive / (MinimumPointDivider + Divider ^ ((killer points - victim points) / PowerDivider))`, rounded, at least `MinPointGive` (defaults 45, 1, 10, 1000, 1). The exponent is limited to -20..20. Beating an account with more points pays more. Only counted kills pay.
- **Victim loss.** The victim loses the same amount, but not below `MinimumPoints` (0); an account already below it loses nothing. The killer still gains the full amount.
- **Inactive victim.** A victim who has not moved more than 24 px or fired for `[AntiFarm] InactiveVictimSeconds` (20) since the last move, shot or spawn is inactive. Repeated kills of the same inactive victim by the same killer pay `InactiveVictimMultipliers` (100,50,25,0) percent in order; the last value applies to all further kills. The count restarts once the victim is active at a kill. The percentage is applied after the minimum, so it can give 0.
- **Selfkill.** A selfkill is never a kill or a death. The code looks for the human enemy who hit the player last within `[Mechanics] AssistSeconds` (7).
  - `SelfkillMode = zerosum` (default), with such an enemy whose account records statistics and `SelfkillAssistShare` (50) above 0: the player loses that percentage of the points a kill of this player would pay (rounded), but not below `MinimumPoints`, and the enemy gets exactly what the player lost. The enemy's Forced Selfkills counter goes up. The enemy gets no kill and the player no death.
  - Otherwise (no such enemy, `penalty` mode, or a share of 0): the player loses `SelfkillPenalty` (2) points. These points leave the pool.
  - In both cases the player's `Under fire` counter (`/zs_status`) goes up when such an enemy exists.
  - Points of a penalty leave the pool; nobody gets them. The daily Check Points pay a missing sum back to active accounts (see below).
  - A player the server kills itself (Survival: a team change mid-round, the end of a round, the players still standing after a capture) gets no selfkill, no death and no penalty.
- **Teamkill.** Never pays anybody. It is no kill for the killer and no death for the victim, who gets a death by a teammate instead. `TeamkillPenalty` (0) points are taken from the killer when above 0.
- **CTF capture.** Every human enemy (on another team, not spectating) whose account records statistics pays `[CaptureTheFlag] CapPoolPoints` (13), not below `MinimumPoints`. The capper gets `CapWinnerSharePercent` (60) percent of what was paid (rounded down); the human teammates with statistics share the rest equally, and what does not divide evenly goes to the capper. Without teammates the capper gets the whole pool. If nobody paid, the capper gets `FlagScoreFallbackPoints` (25).
- **Captures in other modes.** Besides CTF only Infiltration has captures; each pays `FlagScoreFallbackPoints` to the capper. Holding the flag in Hold the Flag pays no points.
- **Floor.** Losses from kills, selfkills, teamkills and captures stop at `MinimumPoints`; the daily balance and check points stop at `[Inactivity] BalanceFloorPoints` (1000).
- **Period and season counters.** Every point change through these rules (kills, captures, penalties, daily balance, check points) is added to the day, week and month record and to the season points. A season reset of the points is not.

### Daily balance, protection and Check Points

The daily work runs once per day, the first time the server clock is at or past `[Inactivity] BalanceHour` (4), and not while the database is read-only. It writes a line to the console and `balance.log`: `daily balance (<mode>): <n> accounts, <n> active, <n> inactive, protection used <n>, collected <n>, paid <n> to <n>; check points +<n> -<n>`. It also recalculates the leagues and runs the suspect scan.

- **Active and inactive.** An account is active when its player joined or left within `InactivityDays` (14). Accounts that were never seen are ignored.
- **Recipients.** Active accounts below `BalanceRecipientMaxPoints` (2500).
- **When it runs.** Only in `Mode = protection` or `decay`, with at least `BalanceMinAccounts` (100) accounts and `BalanceMinRecipients` (15) recipients.
- **Protection mode.** An account at or below `BalanceFloorPoints` pays nothing and keeps its protection days: a day is spent only when it actually spares points. Otherwise an inactive account with protection days uses one and pays nothing; without one it pays 80 + (15 - rank) x 10 points when it is ranked 1-15 (220 down to 80), and 35 otherwise.
- **Protection days.** In protection mode an account earns one protection day per day, the first time that day has at least `ProtectSessionSeconds` (90) of play and `ProtectEventsPerDay` (10) counted kills + deaths, up to `ProtectMaxDays` (60). This is checked on every counted kill (killer and victim) and every counted second.
- **Decay mode.** Every inactive account pays 2% of its points above `BalanceFloorPoints` (at least 1). Accounts not seen for `DecayHideAfterDays` (60) are left out of the points ranking until they play.
- **Payment.** No payer drops below `BalanceFloorPoints`. The collected points are split equally among the recipients, at most `BalanceMaxPayout` (225) each; what does not divide evenly goes 1 point each to the poorest recipients. The rest is removed.
- **Check Points** (`CheckPointsEnabled`, independent of the mode, `none` included, and of `BalanceMinAccounts` and `BalanceMinRecipients`). The code compares the sum of all points with accounts x `StartingPoints`.
  - A deficit is paid to accounts active within `CheckPointsActiveDays` (90), at most 25 points each per day, split the same way.
  - A surplus is taken from inactive accounts above the floor, in proportion to their points above the floor, at most 50 each per day; what does not divide evenly comes a point at a time from the richest of them. In `protection` mode an account with protection days is spared, like in the balance itself, also on the day it uses its last one.
  - When no inactive account can give anything (every one of them is protected, or at the floor), nothing is taken that day and `balance.log` says how much is left over; it is taken from the first inactive accounts whose protection runs out. A deficit is paid whatever the protection days.
  - A surplus that has waited `CheckPointsMaxWaitDays` (14) whole days is taken anyway, protection or not: from every account above the floor, active or not, the one that played longest ago first, until the surplus is gone, at most 50 points per account per day (what the account already gave that day included). `0` lets it wait for as long as it takes.

### Rating index (RatingMode)

The "Rating" shown in `!stats`, `!status`, `!rank`, `!top` and the exports is calculated when it is shown, for the mode and the Survival and Friendly fire switches of the current map. The same account can therefore show different values on different maps.

Common parts: accuracy = hits / max(shots, hits), or 0.2 without shots. K/D = kills / deaths (with Friendly fire on in a team mode: (kills - teamkills) / deaths); with no deaths it is the kills (or 1 with no kills); always limited to 0.2-4.0.

- **`skill`** (default): a value of about 0-100 that ignores points.
  - Factors: accuracy 0.6 + 2 x acc (0.6-1.8); head share 0.9 + head hits / hits (0.9-1.3); win share 0.8 + 0.5 x wins / (wins + losses) (0.8-1.3); rounds, only when the current map has Survival: 0.85 + 0.4 x round win share (0.85-1.25); objectives, only in team modes: 0.9 + (2 x caps + returns + flagger kills + assists) / 150 (0.9-1.3).
  - Value = product of the factors and K/D, times 25, limited to 0-100.
  - It is then pulled toward 15: 15 + (value - 15) x n / (n + 300), where n = kills + deaths.
- **`gamemode`**: the ZitroStats 4 index, multiplied by the points.
  - Factors: accuracy 0.5 + 2.5 x acc (0.5-2.0); win ratio wins / losses (0.5-3, 1 without losses); round ratio, only with Survival: rounds won / rounds lost (0.5-3).
  - DM, PM, RM: accuracy x K/D x head factor (0.85 + 1.5 x head share, 0.85-1.5) x streak factor (1 + (double + 2 x triple + 3 x multi) / 100, at most 1.4) / 4.14 x points / 2.
  - CTF: accuracy x K/D x win ratio x flag factor (0.8 + (3 x caps + 1.5 x returns + flagger kills) / 40, 0.8-1.6) / 4.14 x points / 2.
  - TM, INF, HTF: accuracy x K/D x win ratio x team factor (0.85 + (1.5 x assists + saviors + avengers) / 45, 0.85-1.5) x round ratio / 4.14 x points / 2.
  - The result is at least 1.
- **`unified`**: accuracy x K/D x win ratio x round ratio x flag factor (1 + (2 x caps + returns + flagger kills) / 50, at most 1.4) x team factor (1 + (assists + saviors + avengers) / 60, at most 1.3) / 4.14 x points / 2, at least 1.

### Tiers

`[Ranks] TierN = Name, MinPoints, MinRating, Color, MinGlicko, MinOpenSkill, MinMMR`. An account gets the first tier (in file order) whose limit is met, otherwise the last tier. A tier line that leaves out the limit `TierBy` needs is skipped by that check, so a line meant only for `points` still works when `TierBy` asks for something else. `[Ranking] TierBy` says which limit counts:

- `points` (default, and what an unrecognised value falls back to): points >= `MinPoints`, nothing else. The tiers then follow the same order as `!top`, so a higher place never has a lower tier.
- `rating`: only the Rating index for the current mode >= `MinRating`.
- `mmr`: only the MMR of the family of the current mode >= `MinMMR`.
- `glicko2`: only the Glicko-2 conservative value of that family >= `MinGlicko`.
- `openskill`: only the OpenSkill ordinal of that family >= `MinOpenSkill`.
- `both`: points >= `MinPoints` and, when the tier line gives one, Rating >= `MinRating`.
- `all`: every limit the tier line gives - points, Rating, MMR, Glicko-2 and OpenSkill together.

### Match results

- **When a match counts.** A match ends when the map changes. It is completed when the time left is 2 seconds or less, or the score limit was reached (best team score in team modes; best scoreboard score or counted kills in DM/PM/RM).
- A match gives results only when it is completed (or `[Matches] CountAbortedMatches = 1`), statistics are on at its end, and it lasted at least `MinParticipationSeconds` (60).
- **Who gets a result.** A human with an account who is still connected and played at least max(`MinParticipationSeconds`, `MinParticipationPercent` (40) % of the match), on all teams together. In team modes the result (win, loss, draw and the per-team counters) goes to the team the player spent most time on.
- **Team modes.**
  - The team with the highest score wins; if two teams share the highest score, every player gets a draw.
  - Per-team counters (`Alpha: W / L` etc.) use the player's main team.
  - Comeback wins, map comebacks and close matches are counted here.
  - **Leavers.** With `LeaverCountsAsLoss` (1), a player who left a match their team did not win or draw, after `LeaverMinProgressPercent` (50) % of the match on that team, gets a loss (and a leaver loss); the time of every stay in the match adds up, and the team played longest counts. Such a player gets no rating update, and only if the account is not online again (a player back on the server is judged with all stays added).
- **DM, PM, RM.**
  - The player with the best score (the larger of scoreboard score and counted kills; ties: fewer deaths) wins; every other player with a result loses.
  - This needs at least two players with a result; a score of 0 can win. When the best of them share the same score and the same deaths, nobody is ahead and every player with a result gets a draw.
  - In PM the bonus points (see `!pm`) are added here, even when there is no winner.
- **Survival rounds.** In Capture the Flag a round ends when a team scores (a capture or a wiped out team both give the point). In Teammatch, Infiltration and Hold the Flag the score does not follow the rounds, so a round ends when only one team still has a living player. Everybody in a team at that moment gets the win or the loss.
- **Ratings.** MMR, Glicko-2 and OpenSkill are updated for the players with a result, when there are at least two of them (in team modes on at least two teams, in free-for-all only with a winner).
  - **Partial play (team modes).** A player who played for several teams is rated for each of them against that team's result, weighted by the share of the time spent there (a part under 5% is left out); the parts are added up and count as one rated match. A team's strength counts its players by the same shares. A player the balance moved half way through a match is therefore rated half for each side. Every counted match also adds 1 to the server's `Matches played`, to the map's `Matches` and sends the `match` webhook.

### Survival rounds

**Team modes.**

- **When a round ends.** Only in team modes with the Survival switch, while statistics are on.
  - CTF: every time a team's score rises, that team wins a round (a capture or a wiped out team both give the point).
  - TM, INF and HTF: the score does not follow the rounds (kills in TM, time in INF and HTF), so a round ends when only one of the teams still has a living player. Whether a bot lives is not known, so a team with a bot counts as standing; a round such a team loses ends with the kill the server makes of the winners (TM, HTF) or with a capture (INF).
  - A round needs an opposing team: the server also gives a round to a team that plays alone, and such a round counts for nobody.
- **Counters.** Every human on Alpha-Delta with an account gets a round win or loss (`Rounds Won`, `Rounds Lost`, per-team round counters). With the Advance switch the Advance counters are added too.
- **Clutch.** The player stored at the latest last stand of the round gets a clutch win when their team wins the round. The account is stored with the slot, so a player who takes over the slot afterwards gets nothing.

**Free-for-all (DM, PM, RM) with Survival.** Rounds are tracked per player, not per team.

- The humans who spawn once a round has ended take part in the next one; a round needs at least two of them and `SurvivalOn`. A player who leaves before the round ends gets nothing for it.
- It ends once at most one of the players who took part is still alive: that player wins the round (`Rounds Won`, `Last Stand`) and every other human who took part loses it (`Rounds Lost`).
- When the last two of them die together, or a bot ends up the only one left standing, the round still ends and everybody who took part gets a loss, but nobody wins it.

**Reset.** First blood, first damage and last stands are reset for the next round, team and free-for-all alike. A round the map change cuts short counts for nobody; one decided in the last tick of the map still counts.

### MMR (Heroes of the Storm style)

- Kept per family (FFA, Team, CTF). It starts at `[MMR] Start` (1500).
- A counted match changes it by `Step` (24) x (result - expected), where expected = 1 / (1 + 10 ^ ((opponent - own) / 400)).
- During the first `PlacementMatches` (10) matches of the family the step is 2.5 times larger. The value never drops below 100.
- **Team modes.** Own = average MMR of the player's team (players counted by their share of the match). Opponent = average of the other teams' averages. Result = share of other teams with a lower score (a tie counts 0.5). With partial play the change is the time-weighted sum of the changes for every team played for.
- **DM, PM, RM.** Own = the player's own MMR. Opponent = average of all other players in the match. Result = share of other players with a lower score (a tie counts 0.5).

### Glicko-2

- Kept per family. It starts from `[Glicko2] InitialRating` (1500), `InitialRD` (350) and `InitialVolatility` (0.06); `Tau` is 0.5.
- Every counted match is one rating period (Glickman 2012). Before an update, each full day since the account's last rated match increases the deviation as one empty period.
- **Opponents.** In DM, PM and RM every other player is an opponent, with win, draw or loss by score. In team modes each other team is one opponent, with its average rating and root-mean-square deviation, and the result by team score.
- The deviation is kept within 30-350. The value shown is rating - `ConservativeFactor` (2) x deviation.

### OpenSkill

- Kept per family. The Weng-Lin Plackett-Luce model starts from `[OpenSkill] Mu` (25) and `Sigma` (8.333), with `Beta` (4.1667) and `Kappa` (0.0001). Before each match sigma becomes sqrt(sigma^2 + tau^2) with tau = Mu / 300.
- **Order.** In DM, PM and RM every player is ranked by score. In team modes the teams are ranked by team score.
- **Partial play.** A player counts for a team's mu and sigma^2 by the share of the match played for it, and the player's update shrinks by the same share.
- The value shown is mu - 3 x sigma.

### Leagues

- **When.** Calculated at start and with the daily balance, also while `[Leagues] Enabled = 0`. They need at least one tier in `[Ranks]`.
- **Placement.**
  - With `Source = mmr` (default), the account's main family is the one with the most MMR matches (FFA wins a tie). The account needs `PlacementMatches` (10) MMR matches in that family.
  - With `Source = rating` it needs `PlacementMatches` (10) match wins + losses in all modes. The order is then the Rating index for the mode of the account's main family (FFA: DM, Team: TM, CTF: CTF), without switches, so it does not depend on the map that is running.
  - Accounts with fewer matches are "in placement" and show `Placement <played>/<needed>`.
- **Cut into leagues.** Placed accounts are sorted by the MMR of the main family (`mmr`) or by the Rating index (`rating`) and cut by `Percents` (2,8,20,40,65,85):
  - the best 2% get the first tier, up to 8% the second, and so on;
  - the last tier takes the rest, and a missing number also takes the rest.
- **Divisions.** Each league is split into `Divisions` (5) equal parts by position; division 1 is the best.
- **Where shown.** `!otherstats` always shows the league and "Top x% of placed". With `Enabled = 1` the league replaces the tier in `!stats`, `!rank`, `!top`, `!topo`, `!topby` and `stats.json`/`players.json` `tier`. The `tier` metric of `!topby` still uses the tier rules.

---

## Team balance

`[Balance]`, team modes only. The balance does not change any statistic except `Balance Moves` and `Volunteered`; a team change it makes is a normal team change for all other counters (team time, match results, partial-play ratings).

| Value | How it is calculated |
| :--- | :--- |
| Rating | The rating of `Skill` for the family of the current mode: MMR (`mmr`, the start value when unrated), Glicko-2 rating (`glicko2`, not the conservative value), 1500 + (mu - `[OpenSkill] Mu`) x 200 / `Beta` (`openskill`), or the place of the account's points among the accounts seen in the last 30 days as a normal distribution around 1500 with 200 per standard deviation (`points`). |
| Median | The median rating of the accounts seen in the last 30 days that have rated matches in the family, refreshed every 5 minutes and at every map start; 1500 without such accounts and with `points`. |
| Counted rating | median + (rating - median) x games / (games + `UncertaintyGames`); a player without statistics (no account yet, not logged in) counts as the median. |
| Form | Starts at 0 on every map (and is kept for a player who leaves and comes back to the same map within `RejoinMemoryMinutes`). A kill between humans of different teams moves `FormStep` x (1 - expected) from the victim to the killer, expected = 1 / (1 + 10 ^ ((victim - killer) / 400)) with counted rating + form. A capture adds 1.5 x `FormStep`, a return 0.5 x `FormStep`. Counted in every team mode, whether statistics are on or not. |
| Strength | `blend`: counted rating + form x `FormWeight` x min(1, minutes on the map / `FormFullMinutes`). `global`: counted rating. `map`: median + form. Bots: the rating at the `BotSkill` percentile of the accounts above. |
| Power | 2 ^ ((strength - median) / `SkillPerDouble`), times `AfkFactor` for a living human who did not move or shoot for `AfkSeconds` (the time since the last spawn or team change counts as moving; a dead player is never away). |
| Chance | Team weight = power sum ^ `SizeImpact`, Alpha's weight times the side factor of the map; chance = weight / sum of the weights. Teams: Alpha and Bravo, in Teammatch 2-4 (`TeammatchTeams`, auto = up to the highest team in use). |
| Side factor | With `UseMapBias` and at least 10 decided Alpha/Bravo matches on the map: p / (1 - p) with p = (Alpha wins + 5) / (decided matches + 10), p limited to 35-65%. |
| Imbalance | The largest distance of a team's chance from an even share, times teams / 2: 0.10 means 60:40 between two teams. `Threshold` and `Target` are compared as imbalance (Threshold - 50) / 100. |
| Cost of a change | 0.005 for a player on the server for less than 60 s, otherwise 0.01 dead or 0.03 alive; + 0.01 per 5 minutes in the team (at most 0.03); + 0.05 for a living player in survival. A swap adds both players and 0.01. When uneven numbers cannot be evened by free players, the count fix runs again with the protected players at a price: + 0.05 carries the team, + 0.10 moved recently, + 0.15 more while the way back is locked. Bots, excluded players, a player whose move is on its way and a living flag carrier are never taken; a flag carrier who alone can even the numbers changes team at his next death. |
| Top player | The player with the highest form of a team, when the form is at least 2 x `FormStep` and the player has been on the map for 2 minutes. Protected with `ProtectTop`. |
| Prediction | While the balance runs, the chance of Alpha is noted every 10 s of a two-team match with at least `MinPlayers` humans. At the end of a completed match with statistics on that Alpha or Bravo won (not a draw), with at least six notes: Brier score += (average chance - result)^2 and the match goes to one of ten bins by its average chance (`/balinfo`: matches and Alpha wins per bin). The line-up (the counted ratings of the players still on the server and their shares of the match in Alpha and Bravo, the median and the side factor) is written to `teambalance-history.log`; the last 400 matches are loaded at start. |
| Tuning | From 30 recorded matches on, and again every 10 matches, the pair of `SizeImpact` (1-3) and `SkillPerDouble` (200-1000) with the lowest Brier score on the recorded matches. `AutoTune = 1` uses it from 50 matches on. |

---

## Exports

Nothing is exported while the database is read-only. Names are converted from `[General] SourceCodepage` to UTF-8. The files never contain IP addresses, HWIDs, SteamIDs or e-mail addresses. Timestamps are `"yyyy-mm-ddThh:nn:ss"` (server time) or `null`.

### stats.json

Written every `[Export] ExportIntervalMinutes` (5) and on `/zs_export`, when `JSONExportEnabled` (1), to `JSONExportPath`.

| Group | Keys |
| :--- | :--- |
| Top level | `format` (2), `generator`, `generated_at`, `version`, `total_players` (accounts), `total_maps` |
| `server` | `online` (humans on the server), `map`, `mode` (DM, PM, TM, CTF, RM, INF, HTF), `peak_online`, `peak_online_date`, `total_matches` (counted matches), `rating_system` (`elo`, `mmr`, `glicko2` or `openskill`), `season` (running season id), `season_end` |
| `players[]` (best `JSONExportTopCount` (50) of the points ranking) | `rank`, `id`, `name`, `tier` (league or tier), `points`, `rating` (Rating index for the current mode), `kdr`, `kills`, `deaths`, `selfkills`, `assists`, `headshots` (head hits, not kills), `accuracy_pct`, `headshot_pct` (head hits / hits), `playtime_sec`, `max_killstreak`, `damage_dealt`, `damage_received`, `damage_ratio`, `first_bloods`, `first_damage`, `wins`, `loses`, `draws`, `caps`, `season_points`, `achievements` (count), `registered` (password set), `last_seen` |
| `players[]` distances | `longest_kill_px`, `longest_barret_px`, `avg_kill_dist_px` (whole pixels = meters x 14), `longest_kill_m`, `longest_barrett_m`, `avg_kill_dist_m` |
| `maps[]` (all maps, most played time first) | `id`, `map`, `plays` (counted matches), `kills`, `selfkills`, `playtime_sec` (seconds with statistics on), `caps`, `alpha_wins`, `bravo_wins`, `draws`, `avg_match_sec` (as `Avg Match`, 0 before the first measured match), `avg_players` (as `Avg Humans`), `fastest_cap_sec`, `votes_started`, `votes_won`, `voted_in`, `stayed_pct` (`null` before the first measured map end), `players_by_time` (ten numbers as `Over the match`, `null` for a tenth without data), `last_played` |
| `weapons[]` (weapons with kills, shots, hits or picks) | `name`, `kills`, `deaths`, `shots`, `hits`, `headshots` (head hits), `accuracy_pct`, `headshot_pct`, `damage`, `time_sec`, `damage_per_min`, `hits_per_kill`, `longest_kill_m`, `avg_kill_dist_m`, `avg_ttk_sec`, `picks`, `picks_alpha`, `picks_bravo`, `picks_charlie`, `picks_delta`, `vest_kills` (the same totals as `!topweapons`) |
| `seasons[]` (last three archived) | `id`, `start`, `end`, `top[]` (first three: `place`, `name`, `season_points`, `points`) |

### players.json

Written with the same timer when `FullExportEnabled` (0), to `FullExportPath`. Top level: `format` (2), `generated_at`, `total_players`, `players[]` with one object per account.

| Group | Keys |
| :--- | :--- |
| Identity and ranking | `id`, `name`, `rank` (0 if hidden), `tier`, `points`, `rating`, `league`, `registered`, `first_seen` (account creation), `last_seen` |
| Skill values | `skill_ffa`, `skill_team`, `skill_ctf`: value of `RankingSystem` for each family: Glicko-2 conservative value, OpenSkill ordinal, or MMR (with `mmr` and `elo`); start values when unrated. `mmr_ffa`, `mmr_team`, `mmr_ctf`: MMR of each family (the start value when unrated). |
| Combat | `kills`, `deaths`, `assists`, `selfkills`, `teamkills`, `shots` (max of shots and hits), `hits`, `hits_head`, `hits_body`, `hits_legs`, `damage_dealt`, `damage_received`, `best_streak`, `first_bloods`, `multi_kills` (only the 4th-kill medal), `knife_kills` (Combat Knife slot), `grenade_kills` (frag + cluster) |
| Distance and timing | `longest_kill_m`, `avg_kill_dist_m`, `avg_ttk_sec`, `longest_life_sec`, `traveled_km`, `best_life_distance_m` |
| Time and activity | `playtime_sec`, `alive_sec`, `spectator_sec`, `days_played`, `protection_days` |
| Matches and objectives | `wins`, `loses`, `draws`, `rounds_won`, `rounds_lost`, `caps`, `returns`, `grabs`, `flag_hold_sec`, `fastest_cap_sec` |
| Season | `season` (the season stored on the account, which can be an older one), `season_points` |
| Cover, bases, balance | `through_cover_kills` (Cover (live)), `through_cover_shot_kills` (Cover (shot)), `base_defense_kills`, `base_attack_kills`, `forced_suicides`, `suicides_under_fire`, `balance_moves`, `balance_volunteers` |
| Healing and kits | `healed_hp` (regen + kits), `regen_hp` (regenerating polygons only), `heal_kits` (kits that healed), `kits` (every kit picked up), `kit_pickups{}` (the kits picked up by kind: `medical`, `grenade`, `cluster`, `vest`, `berserker`, `predator`, `flamer`) |
| `achievements` | Names of the unlocked achievements. |
| `badges[]` | `season`, `place`. |
| `weapons{}` | Key = short weapon name in lower case (`socom`, `deagle`, `mp5`, `ak`, `aug`, `spas`, `ruger`, `m79`, `barrett`, `minimi`, `minigun`, `knife`, `saw`, `law`, `flamer`, `bow`, `flamebow`, `statgun`, `fists`, `nade`, `cluster`); only weapons with kills, deaths, shots or hits. Values: `kills`, `deaths`, `shots` (at least hits), `hits`, `headshots` (head hits), `damage`, `time_sec`, `reloads` (reloads started), `reloads_finished`, `killed_reloading`, `avg_reload_sec` (as `Avg reload` of `!wep`, 0 without a timed reload). The stored per-weapon values, without the 4.x larger-of rule. |
| `modes{}` | Key = `dm`, `pm`, `tm`, `ctf`, `rm`, `inf`, `htf` (modes with kills, deaths, wins or losses). Values: `kills`, `deaths`, `wins`, `loses`, `caps`, `time_sec`. |

### Webhooks

`[Webhook] Enabled`, `Url`, `Events` (`season,record`), `Format` (`json`, or `discord` for a text message of at most about 1900 characters). Posted with curl, not repeated on failure.

| Event | When | JSON keys |
| :--- | :--- | :--- |
| `export` | Every export run. | `event`, `generated_at`, `players` (accounts), `online`, `top[]` (first 10 of the points ranking: `rank`, `name`, `points`) |
| `match` | Every counted match. | `event`, `ended_at`, `map`, `mode`, `duration_sec`; team modes also `score` (Alpha, Bravo, Charlie, Delta) and `winner` (`alpha` ... `delta` or `draw`); `players[]`: up to 10 humans not spectating, most counted kills of the map first, with `name`, `team`, `kills` and `deaths` (counted this map) and `score` (scoreboard value) |
| `season` | A season was archived. | `event`, `id`, `start`, `end`, `top[]` (first 10: `place`, `name`, `season_points`, `points`, `kills`, `deaths`) |
| `record` | A new online peak that has not grown for 5 minutes. | `event`, `type` (`peak_online`), `players`, `date` |

### MySQL

`[MySQL] Engine = mirror`: every `MirrorIntervalSeconds` (60) - the players on the server always, the others when they played since the last run, everybody once an hour: table `zs_players` (`profile_id`, `name`, `points`, `rank_pos`, `rating`, `kills`, `deaths`, `assists`, `headshots`, `shots`, `hits`, `wins`, `loses`, `caps`, `playtime_sec`, `last_seen`, and with `FullJson = 1` the players.json object in `data`), `zs_maps` (`map_id`, `name`, `plays`, `kills`, `caps`, `playtime_sec`, `last_played`) and `zs_server` (`accounts`, `peak_online`, `total_matches`). Every row carries `server_id` and `updated_at`. The Shared switches (see the README) fill more columns: `zs_players.steam_id` (the SteamID, or for an account without Steam `H:` and a hash of the HWID of its computer), and for the accounts that played since the last run `shared_data` (the complete record) and `shared_at` (`SharedProfiles`, `SharedRankings`); `zs_maps.shared_data` and `shared_at` for the maps played since the last run (`SharedMaps`); `zs_server.shared_data` (the server record), `shared_sum` (every account added up) and `shared_at` (`SharedWeapons`, `SharedServer`). After every pass the mirror reads what the other servers wrote since the last time, and every quarter of an hour it notices the rows they deleted.

`[MySQL] Engine = mysql`: one database for every server (see the README). `zs_db_accounts` holds every account once: `id`, `steam`, `hwid_key` (for an account without Steam a hash of the HWID of its computer, which finds the account of that computer), `name`, `points`, `kills`, `deaths`, `playtime_sec`, `last_seen`, the complete record in `data` (binary), and `version`, `seq`, `deleted`, `merged_into`, `updated_by` (the `ServerID` that wrote it last), `updated_at`. `zs_db_maps` (`name`, `id`, `plays`, `kills`, `playtime_sec`, `data`), `zs_db_server` (the server record), `zs_db_seasons` (the archived seasons), `zs_db_meta` (the change counter, the next account and map numbers, the servers that joined) and `zs_db_jobs` (which server did the daily balance and the season change).

What the Shared switches change in the headers: a profile with numbers of other servers says `[<n> servers]` after the name (n counts this server too); the player rankings say `of All Servers` (`Top Ranking of All Servers [Page p/P]`, `Top by K/D of All Servers ...`, `Top Today of All Servers ...`); the map lists `Top Maps of All Servers`, `!mapstats` `[ Map Statistics: <map> - <n> servers ]` (`- other servers` for a map played only there); the weapons `All Weapons Breakdown: all servers`, `Weapon: <weapon> - all servers`, `Top Weapons by <metrics> - all servers`; the server `Server Statistics & Activity Analytics - all servers` and `Server Activity: Week by Hour - all servers`.

### Developer API

`ZS_API_Get_Player_Stat(SlotID, StatID)` (account of the player in the slot) and `ZS_API_Get_Profile_Stat(ProfileID, StatID)` (any account) return these values as `Double`; 0 when there is no value. When the engine is busy, the call returns the value it read last for the same arguments.

| StatID | Value in the code |
| ---: | :--- |
| 0 | Points |
| 1 | Kills |
| 2 | Deaths |
| 3 | Kills / deaths; kills when there are no deaths |
| 4 | Rating index for the current mode (`RatingMode`) |
| 5 | Position in the points ranking (0 = not ranked) |
| 6 | Play time (s) |
| 7 | Headshot kills, all weapons |
| 8 | Hits x 100 / shots, at most 100 (uses the stored shots only; 0 without shots) |
| 9 | Flag captures |
| 10 | Assists |
| 11 | Clutches won |
| 12 | Best kill streak |
| 13 | Damage dealt |
| 14 | Damage received |
| 15 | Prone kills |
| 16 | Jet flight time (s) |
| 17 | Camp kills |
| 18 | Bink recovery kills |
| 19 | Streaks that reached 5 |
| 20 | Streaks that reached 10 |
| 21 | Streaks that reached 15 |
| 22 | Streaks that reached 20 |
| 23 | Streaks that reached 25 |
| 24 | Shut down kills |
| 25 | Finisher kills |
| 26 | Fastest capture (s, 0 = none) |
| 27 | Escort kills |
| 28 | Flag juggles |
| 29 | Contested holds |
| 30 | Longest kill (m) |
| 31 | Match wins |
| 32 | Match losses |
| 33 | Protection days |
| 34 | Season points stored on the account |
| 35 | Glicko-2 rating - ConservativeFactor x RD, family of the current mode (start values when unrated) |
| 36 | OpenSkill mu - 3 x sigma, family of the current mode (start values when unrated) |
| 37 | Account number (`#id`) |
| 38 | 1 when the account has a password |
| 39 | MMR, family of the current mode (start value when unrated) |

Other functions: `ZS_Is_Ready` (1 after loading), `ZS_Get_Api_Version` (14), `ZS_API_Get_Player_Name(Slot)`, `ZS_API_Get_Player_Rank(Slot)` (points ranking position), `ZS_API_Get_Player_HUD(Slot)` (1 when `!hud` is on), `ZS_API_Get_Profile_Count` (accounts), `ZS_API_Get_Top_Player(Rank)` (name at that points ranking position), `ZS_API_Top_Player_Copy(Rank, Buf, Size)` (the same with the SteamID, for another library), `ZS_API_Get_Server_Peak` (online record).

---

## Counted but only in exports or the API

These values are stored or used but no in-game command prints them:

| Value | Where it is available |
| :--- | :--- |
| Headshot kills of all weapons together | API StatID 7 (commands show headshot kills only per weapon as `HS Lethality`, and per period as `HS`) |
| Accuracy from stored shots only | API StatID 8 |
| Glicko-2 and OpenSkill values of the families other than the current one | `players.json` `skill_*` (only when that system is the `RankingSystem`) |
| Captures, losses per game mode | `players.json` `modes{}` (`caps`, `loses`) |
| Scoreboard score and team scores of a match, match duration | `match` webhook |
| Per-weapon values without the 4.x larger-of rule | `players.json` `weapons{}` |
| Weapon picks of Charlie and Delta per weapon, as numbers for every team | `stats.json` `weapons[]` (`picks_alpha` ... `picks_delta`); `!wep` shows Charlie/Delta together |

These counters are stored with every account or map but are neither printed nor exported:

| Stored value | What is counted |
| :--- | :--- |
| `AlphaScore`, `BravoScore` | Captures made while on Alpha or Bravo. |
| `AlphaTeamScore`, `BravoTeamScore` | CTF captures of a teammate while on Alpha or Bravo. |
| `CharlieWins`, `DeltaWins` | Team match wins on Charlie or Delta (only used to decide whether a row of `!otherstats` is shown). |
| `CharlieLoses`, `DeltaLoses` | Team match losses on Charlie or Delta. |
| `RoundsAlphaWins` ... `RoundsDeltaLoses` (8 counters) | Survival round wins and losses per team. |
| `ShotsHitsByFriendlyHead/Body/Leg` | Friendly hits received, by zone. |
| `ShotsHitsSelfHead/Body/Leg` | Self hits, by zone. |
| `KnivesThrowsHitsByFriends`, `KnivesStabsByFriendly`, `ChainsawHurtsByFriendly`, `FlamethrowerHitsByFriendly`, `HandsHurtsByFriendly`, `NadeHurtsByFriendly`, `ClusterNadesHurtsByFriendly`, `M79HurtsByFriendly`, `M72LAWHurtsByFriendly`, `BowFlamedArrowsHurtsByFriendly`, `M2MGHitsByFriendly` | Friendly damage events received from each special weapon. |
| `BowFlamedArrowsShots` | Flamed Arrows shots. |
| HTF `TeamPointsScored`, `AlphaPointsScored`, `BravoPointsScored`, `AlphaTeamPointsScored`, `BravoTeamPointsScored` | HTF points of the own team (all members), and the carrier and team points split by Alpha and Bravo. |
| HTF `TimeWhenNotHaveFlag`, `TimeWhenTeamNotHaveFlag` | HTF seconds alive without the flag, and while the own team had no carrier. |
| Game mode draws | Draws per mode. |
| Glicko-2 deviation and volatility, OpenSkill mu and sigma | Only the combined values are shown. |
| Achievement unlock dates | Date and time of each unlock. |
| Name history: first-use date, spectator time per name | Kept for every stored name. |
| Season archive `Rating` | The Rating index of each archived account, for the mode of its main family (as for leagues). |
| Map area (`MinX`, `MinY`, `MaxX`, `MaxY`) | The extent of all position samples on the map. |
| Server daily records: unique players, sessions, player seconds, online peak, kills (366 days) | Only the new players of the last 7 days are used (`!server`). |
| Server hit-zone model | Positions of classified hits, used to estimate zones of other weapons. |
