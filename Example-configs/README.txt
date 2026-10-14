ZitroStats 5.7 - example settings
=================================

Ready settings for the usual kinds of server. Each file is the whole settings.ini of ZitroStats
with the values that kind of server should have: every changed value has a line "; EXAMPLE: ..."
above it that says what was changed and why, and the rest is settings.ini as it comes. The
server never reads this folder; a file counts only once it is copied over settings.ini.


The files
---------

deathmatch.ini
    Plain deathmatch with respawns. No team balance (deathmatch has no teams), !randommap and
    !allmaps leave out the ctf_, inf_ and htf_ maps, and the kill streak levels start at 5 kills
    and go to 50, as kills come fast with respawns.

deathmatch-survival-realistic.ini
    Realistic survival deathmatch on RSCS maps - the author's own server. No team balance, a
    match ended by a map vote still gives wins, losses and ratings (CountAbortedMatches = 1),
    BinkDamage 15 for the 65 health of realistic mode, and the built-in streak levels, which
    start at 3 kills.

ctf.ini
    Capture the Flag with respawns: settings.ini as it comes, with !randommap and !allmaps kept
    to the ctf_ maps.

ctf-survival-realistic.ini
    Realistic survival Capture the Flag on RSCS maps: the team balance and the whole score guard,
    a match ended by a map vote still counts, BinkDamage 15, the built-in streak levels.

teammatch.ini
    Teammatch with respawns: the team balance, the maps without ctf_, inf_ or htf_ in front,
    streak levels from 5 to 50.

infiltration.ini
    Infiltration with respawns: !randommap and !allmaps kept to the inf_ maps.

hold-the-flag.ini
    Hold the Flag with respawns: !randommap and !allmaps kept to the htf_ maps.

pointmatch.ini, rambomatch.ini
    Pointmatch and Rambomatch: no team balance, the maps without ctf_, inf_ or htf_ in front,
    streak levels from 5 to 50.

several-servers-mysql.ini
    Several servers sharing one live MySQL or MariaDB database (Engine = mysql): one account,
    one ranking and one password on every server. The game settings are settings.ini as it
    comes.

website-mirror.ini
    A copy of the statistics in MySQL or MariaDB for a website (Engine = mirror); the files stay
    the statistics. The game settings are settings.ini as it comes.


What each file changes
----------------------

file                               Balance  Filter  Streaks  Aborted  Bink  Engine
(settings.ini as it comes)         1        0       3-30     0        35    local
deathmatch.ini                     0        1       5-50     0        35    local
deathmatch-survival-realistic.ini  0        0       3-30     1        15    local
ctf.ini                            1        1       3-30     0        35    local
ctf-survival-realistic.ini         1        0       3-30     1        15    local
teammatch.ini                      1        1       5-50     0        35    local
infiltration.ini                   1        1       3-30     0        35    local
hold-the-flag.ini                  1        1       3-30     0        35    local
pointmatch.ini                     0        1       5-50     0        35    local
rambomatch.ini                     0        1       5-50     0        35    local
several-servers-mysql.ini          1        0       3-30     0        35    mysql
website-mirror.ini                 1        0       3-30     0        35    mirror

Balance = [Balance] Enabled, Filter = [MapVote] FilterByGameStyle, Streaks = the kills of the
first and the last level of [Sprees], Aborted = [Matches] CountAbortedMatches, Bink =
[Mechanics] BinkDamage, Engine = [MySQL] Engine (the two MySQL files also have Password =
CHANGE_ME, a placeholder for yours).


How to use one
--------------

1. The game mode itself is set in the server's soldat.ini, not here: GameStyle (0 deathmatch,
   1 pointmatch, 2 teammatch, 3 CTF, 4 rambomatch, 5 infiltration, 6 hold the flag),
   Survival_Mode and Realistic_Mode. An example only fits ZitroStats to that mode.
2. Keep a copy of your own scripts/ZitroStats-Core/settings.ini, for example as
   settings.ini.bak. What you changed in it before (texts, colours, tiers) has to be changed
   in the new file again.
3. Copy the example over settings.ini: the file must be called settings.ini and stay next to
   main.pas.
4. Fill in what is yours (below).
5. Type /zs_reload in the game or in the server console. The admins hear "Settings reloaded.";
   a line of settings.ini that could not be used is named in the console ("settings.ini: ...").
   Engine = mysql is taken at the next start: restart the server for several-servers-mysql.ini.


What you still fill in
----------------------

[Admin] ConfirmPassword
    Every example leaves it empty. Resets, restores, merges, /zs_unregister, /zs_setpass and
    /removeolderthan are confirmed with /yes <ConfirmPassword> and are refused while it is
    empty. A password only the admins know - not the server's admin password.

[Messages] ContactText and InfoBroadcastText
    The answer of !contact, and the line repeated every InfoBroadcastMinutes.

[Mail]
    Only for e-mail codes (/setemail, /forgotpass): Enabled = 1, SmtpUrl, SmtpUser,
    SmtpPassword, FromAddress (a valid address, or e-mail stays off) and ServerName. The limits
    (MaxPerDay of an account, MaxPerDayServer, MaxPerDaySource) are set already.

[Webhook]
    Only for posts to a website or to Discord: Enabled = 1, Url, Events and Format (discord for
    a Discord webhook).

[MySQL] of several-servers-mysql.ini and website-mirror.ini
    Host (the machine of the database; 127.0.0.1 is this machine), Port, Database, User,
    Password (CHANGE_ME is only a placeholder) and ServerID (every server its own number). The
    database must exist and the user may create and alter tables in it; README.md, "MySQL /
    MariaDB", says more.

[MapVote] MapsFolder
    Only when !allmaps finds no maps: the folder of the maps, when it is not the server's own.

Never publish a settings.ini with your passwords in it.


A game mode on several servers
------------------------------

Take the example of the game mode and copy the whole [MySQL] section of several-servers-mysql.ini
over the one in it (website-mirror.ini the same way for a website copy). Give every server its
own ServerID, and keep StartingPoints, [Inactivity] and [Seasons] the same on every server of
the database.


Why these values
----------------

- The team balance acts only in Teammatch, CTF, Infiltration and Hold the Flag, so the examples
  without teams switch it off. A server that also plays team modes sets it back to 1.

- FilterByGameStyle keeps !randommap and !allmaps to the maps of the mode being played, by the
  start of their names (ctf_, inf_, htf_; the other names for deathmatch, pointmatch, teammatch
  and rambomatch). A map named in a vote still works. The RSCS examples leave it at 0: RSCS maps
  are played in deathmatch and in CTF, and the filter would hide them in one of the two. Leave
  it at 0 whenever your map names do not say the mode.

- Kill streak levels ([Sprees]): with respawns in deathmatch, pointmatch, rambomatch and
  teammatch kills come fast, so the levels start at 5 kills and go to 50 (Rampage at 10 and
  Godlike at 25, the same as the achievements of those names). In survival and in the objective
  modes a life holds fewer kills, so the built-in levels (3 to 30) stay.

- CountAbortedMatches = 1 on the RSCS examples: when maps change by votes a lot, most matches
  end before their limit, and such a match would give nobody a win, a loss or a rating (kills,
  damage and time always count). Turn it on on any server where that is so.

- Realistic mode gives 65 health instead of 150. MaxHealthRealistic says so already and the
  assists follow it; BinkDamage is a number of damage points, so the realistic examples lower it
  from 35 to 15, about the same share of the health.

- The score guard ([Integrity]) stays on everywhere: it acts only where the mode has team
  points, captures or survival rounds to take back, and ProtectMapChange keeps /pause from
  throwing a map change away in every mode.
