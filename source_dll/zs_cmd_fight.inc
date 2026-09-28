{ zs_commands: !lastfight - what happened around the last deaths of the caller (zs_fight keeps the
  events, zs_engine_fight.inc records them) }

const
  { the timeline: time, event, player, weapon, damage, health, zone, distance, flight, speed; the
    dodge estimate (13 letters at most) ends the line. Every cell stays shorter than its column. }
  FIGHT_TL: array[0..9] of LongInt = (7, 16, 14, 9, 6, 4, 8, 7, 8, 7);
  { who hurt him: player, role, weapons, hits, damage, share, zones; then when }
  FIGHT_FOES: array[0..6] of LongInt = (19, 9, 16, 6, 7, 7, 12);
  { whom he hit: player, weapons, hits, damage, zones; then what came of it }
  FIGHT_DEALT: array[0..4] of LongInt = (18, 16, 6, 7, 12);
  FIGHT_ROWS = 12;       { lines of the timeline }
  FIGHT_FOE_ROWS = 5;    { lines of each table }

{ the weapons of a line of a table: "AK, Deagle", "AK, Deagle +1" }
function FightWeapons(const F: TLfFoe): AnsiString;
var
  k: LongInt;
begin
  Result := '';
  for k := 0 to Min(F.WeaponCount, 2) - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + LfWeaponShort(F.Weapons[k]);
  end;
  if F.WeaponCount > 2 then
    Result := Result + ' +' + IntToStr(F.WeaponCount - 2);
  Result := Copy(Result, 1, 15);
end;

{ "-2.41 s", or "-5.1 to -0.4 s" when the hits of a player took longer }
function FightWhen(const R: TLfRecord; First, Last: LongInt): AnsiString;
begin
  if Last - First < 6 then
    Result := LfSeconds(First - R.DeathTick, 2) + ' s'
  else
    Result := LfSeconds(First - R.DeathTick, 1) + ' to ' + LfSeconds(Last - R.DeathTick, 1) + ' s';
end;

{ the zone of the hit of a kill or of the hit that killed him: "head", "~body" }
function FightZone(Zone: LongInt; Est: Boolean): AnsiString;
begin
  if (Zone >= HZ_HEAD) and (Zone <= HZ_LEGS) then
    Result := LfZones(Ord(Zone = HZ_HEAD), Ord(Zone = HZ_BODY), Ord(Zone = HZ_LEGS), 0, Est, '')
  else
    Result := '-';
end;

{ a distance for the tables: far past any map it says nothing }
function FightMeters(const Ev: TLfEvent): AnsiString;
begin
  if Ev.Dist > 999 * PIXELS_PER_METER then
    Result := ''
  else
    Result := LfMeters(Ev.Dist, Ev.Flags and LFF_DIST_EST <> 0);
end;

{ the time a bullet flew, for the tables: "0.37 s", "~0.37 s" when worked out from the bullet }
function FightFlight(const Ev: TLfEvent): AnsiString;
begin
  Result := '';
  if Ev.Flight < 0 then
    Exit;
  Result := FloatStr(Min(Ev.Flight, 9.99), 2) + ' s';
  if Ev.Flags and LFF_DIST_EST <> 0 then
    Result := '~' + Result;
end;

{ A line of the timeline. The hits both ways have the same cells: where the shot came from, how long
  it flew, how fast the one who was hit moved (he or the one he hit) and whether that one could have
  dodged. A teammate is said with his name. }
procedure FightTimelineRow(E: TZSEngine; Slot: LongInt; const R: TLfRecord; const Ev: TLfEvent);
var
  T, What, Name, DmgText, HP, Zone, Speed, Last: AnsiString;
  Color: LongInt;
begin
  T := PadL(LfSeconds(Ev.Tick - R.DeathTick, 2), 6);
  if Ev.Kind = LFE_NOTE then
  begin
    if Ev.Points <> 0 then
      What := 'points'
    else if Ev.Text = 'Assist' then
      What := 'assist'
    else
      What := 'feat';
    Row(E, Slot, [T, What, Ev.Text], FIGHT_TL, CLR_FEATS);
    Exit;
  end;
  if Ev.Flags and LFF_MATE <> 0 then
    Name := Copy(Ev.Text, 1, 6) + ' (mate)'
  else
    Name := Copy(Ev.Text, 1, 13);
  DmgText := '';
  HP := '';
  Zone := Copy(LfEventZones(Ev, ''), 1, 7);
  Speed := '';
  if Ev.Speed >= 0 then
    Speed := FloatStr(Min(Ev.Speed, 99), 0) + ' m/s';
  Last := '';
  case Ev.Kind of
    LFE_TAKEN:
      begin
        if Ev.Flags and LFF_SELF <> 0 then
          What := 'own hit'
        else if Ev.Flags and LFF_LETHAL <> 0 then
          What := 'killed you'
        else
          What := 'hit you';
        if Ev.Flags and LFF_LETHAL <> 0 then
          Color := CLR_BAD
        else
          Color := WHITE;
      end;
    LFE_DEALT:
      begin
        What := 'you hit';
        Color := CLR_COMBAT;
      end;
    else
      begin
        { a kill: the zone of the hit that did it }
        What := 'you killed';
        Zone := FightZone(Ev.LastZone, Ev.Flags and LFF_ZONE_EST <> 0);
        Color := CLR_GOOD;
      end;
  end;
  if Ev.Kind <> LFE_KILL then
  begin
    if Ev.Count > 99 then
      What := What + ' x99+'
    else if Ev.Count > 1 then
      What := What + ' x' + IntToStr(Ev.Count);
    DmgText := PadL(Dmg(Ev.Damage), 5);
    if Ev.Health > 0 then
      HP := PadL(FloatStr(Min(Ev.Health, 999), 0), 3);
    Last := LfDodge(Ev);
  end
  { a hit of his after his death shows by its time (+); the kill has no dodge to say }
  else if Ev.Flags and LFF_AFTER <> 0 then
    Last := 'after death';
  Row(E, Slot, [T, What, Name, Copy(LfWeaponShort(Ev.Weapon), 1, 8), DmgText, HP, Zone, FightMeters(Ev),
    FightFlight(Ev), Speed, Last], FIGHT_TL, Color);
end;

{ the record of a death, as the command shows it }
procedure FightReport(E: TZSEngine; Slot: LongInt; const R: TLfRecord; N, Have: LongInt);
var
  Foes: TLfFoes;
  nFoes, k, First, Lost, Won, WonAfter, Assists, AssistsAfter: LongInt;
  Lethal: ^TLfEvent;
  Total: Double;
  S, Name, Role: AnsiString;
  Sec: Int64;
  Mates: Boolean;
begin
  Mates := False;
  Header(E, Slot, Format('[ Last Fight %d/%d: %s ]', [N, Have, E.Live[Slot].Name]), LINE_W);
  Sec := Max(Int64(0), Round((Now - R.When) * 86400));
  if Sec < 5 then
    S := 'Died just now'
  else
    S := 'Died ' + FormatDurationShort(Sec) + ' ago';
  S := S + FormatDateTime(' (hh:nn:ss)', R.When);
  if R.MapName <> '' then
    S := S + ' on ' + R.MapName;
  if (R.LifeTick > 0) and (R.DeathTick >= R.LifeTick) then
    S := S + ', ' + FormatDurationShort((R.DeathTick - R.LifeTick) div TICKS_PER_SECOND) + ' into the life';
  Out(E, Slot, S, CLR_ACTIVITY);

  { who killed him, with what, and the hit that did it }
  Lethal := nil;
  for k := 0 to R.Count - 1 do
    if (R.Events[k].Kind = LFE_TAKEN) and (R.Events[k].Flags and LFF_LETHAL <> 0) then
      Lethal := @R.Events[k];
  Name := R.KillerName;
  if R.KillerFlags and LFF_BOT <> 0 then
    Name := Name + ' (bot)';
  case R.Kind of
    LFD_SELF:
      S := 'You killed yourself with ' + LfWeaponLong(R.KillerWeapon);
    LFD_WORLD:
      S := 'You died without a weapon hit: a fall, a deadly part of the map, the kill command or a script';
    LFD_TEAM:
      S := 'Killed by your teammate ' + Name + ' with ' + LfWeaponLong(R.KillerWeapon);
    LFD_LEFT:
      if R.KillerName = '' then
        S := 'Killed by a player who left the server, with ' + LfWeaponLong(R.KillerWeapon)
      else
        S := 'Killed by ' + Name + ', who left the server, with ' + LfWeaponLong(R.KillerWeapon);
    else
      S := 'Killed by ' + Name + ' with ' + LfWeaponLong(R.KillerWeapon);
  end;
  if R.KillerFlags and LFF_AFTER <> 0 then
    S := S + ' - after his own death';
  Out(E, Slot, S, CLR_BAD);
  if Lethal <> nil then
  begin
    { the pellets or bullets of one shot are one line: their hits and zones together }
    if Lethal^.Count > 1 then
    begin
      S := Format('The shot that killed you: %d hits, %s dmg', [Lethal^.Count, Dmg(Lethal^.Damage)]);
      if LfEventZones(Lethal^, ' ') <> '-' then
        S := S + ' (' + LfEventZones(Lethal^, ' ') + ')';
    end
    else
    begin
      S := 'The hit that killed you: ' + Dmg(Lethal^.Damage) + ' dmg';
      if (Lethal^.LastZone >= HZ_HEAD) and (Lethal^.LastZone <= HZ_LEGS) then
        S := S + ' to the ' + FightZone(Lethal^.LastZone, Lethal^.Flags and LFF_ZONE_EST <> 0);
    end;
    if FightMeters(Lethal^) <> '' then
      S := S + ' from ' + FightMeters(Lethal^);
    if Lethal^.Health > 0 then
      S := S + ', you had ' + FloatStr(Min(Lethal^.Health, 9999), 0) + ' HP';
    if Lethal^.Flags and LFF_VEST <> 0 then
      S := S + ' and a vest';
    Out(E, Slot, S, CLR_BAD);
  end;
  if not R.Closed then
    Out(E, Slot, 'The seconds after this death are still being recorded (a bullet may still hit).', CLR_HINT);

  { the timeline: the last FIGHT_ROWS events }
  Section(E, Slot, Format('Timeline (seconds from the death, %d s before to %d s after)',
    [E.Cfg.LastFightBeforeSeconds, E.Cfg.LastFightAfterSeconds]), LINE_W);
  if R.Count = 0 then
    Out(E, Slot, 'Nothing was recorded in these seconds.', CLR_HINT)
  else
  begin
    Row(E, Slot, ['  Time', 'Event', 'Player', 'Weapon', '  Dmg', ' HP', 'Zone', 'Dist', 'Flight', 'Speed',
      'Dodge (est.)'], FIGHT_TL, CLR_SUBHEADER);
    First := Max(0, R.Count - FIGHT_ROWS);
    if First + R.Missed > 0 then
      Out(E, Slot, Format('... %d earlier events of these seconds are not shown', [First + R.Missed]), CLR_HINT);
    for k := First to R.Count - 1 do
    begin
      FightTimelineRow(E, Slot, R, R.Events[k]);
      if (R.Events[k].Kind <> LFE_NOTE) and (R.Events[k].Flags and LFF_MATE <> 0) then
        Mates := True;
    end;
  end;

  { everybody who hurt him, most damage first }
  nFoes := LfFoes(R, False, Foes);
  Section(E, Slot, 'Who hurt you', LINE_W);
  if nFoes = 0 then
    Out(E, Slot, 'Nobody hit you in these seconds.', CLR_HINT)
  else
  begin
    Total := 0;
    for k := 0 to nFoes - 1 do
      Total := Total + Foes[k].Damage;
    Row(E, Slot, ['Player', 'Role', 'Weapon', 'Hits', '  Dmg', 'Share', 'Zones', 'When'], FIGHT_FOES, CLR_SUBHEADER);
    for k := 0 to Min(nFoes, FIGHT_FOE_ROWS) - 1 do
    begin
      if Foes[k].Flags and LFF_SELF <> 0 then
        Role := 'yourself'
      else if (R.Kind in [LFD_ENEMY, LFD_TEAM, LFD_LEFT]) and (R.KillerName <> '') and (Foes[k].Slot = R.Killer) and
        (Foes[k].Name = R.KillerName) then
        Role := 'killer'
      else if (Foes[k].Slot >= 1) and (Foes[k].Slot <= MAX_PLAYERS) and
        (R.Assists and (LongWord(1) shl (Foes[k].Slot - 1)) <> 0) then
        Role := 'assist'
      else if Foes[k].Flags and LFF_MATE <> 0 then
        Role := 'teammate'
      else if Foes[k].Flags and LFF_BOT <> 0 then
        Role := 'bot'
      else
        Role := '';
      Row(E, Slot, [Copy(Foes[k].Name, 1, 18), Role, FightWeapons(Foes[k]), PadL(Num(Foes[k].Hits), 4),
        PadL(Dmg(Foes[k].Damage), 5), PadL(FloatStr(SafeDivD(Foes[k].Damage * 100, Total), 0) + '%', 5),
        Copy(LfZones(Foes[k].Zones[0], Foes[k].Zones[1], Foes[k].Zones[2], Foes[k].Zones[3], Foes[k].ZoneEst, ' '), 1, 11),
        FightWhen(R, Foes[k].First, Foes[k].Last)], FIGHT_FOES, WHITE);
    end;
    if nFoes > FIGHT_FOE_ROWS then
      Out(E, Slot, Format('... and %d more', [nFoes - FIGHT_FOE_ROWS]), CLR_HINT);
  end;

  { whom he hit and killed }
  nFoes := LfFoes(R, True, Foes);
  Section(E, Slot, 'What you dealt', LINE_W);
  if nFoes = 0 then
    Out(E, Slot, 'You hit nobody in these seconds.', CLR_HINT)
  else
  begin
    Row(E, Slot, ['Player', 'Weapon', 'Hits', '  Dmg', 'Zones', 'Result'], FIGHT_DEALT, CLR_SUBHEADER);
    for k := 0 to Min(nFoes, FIGHT_FOE_ROWS) - 1 do
    begin
      S := '';
      if Foes[k].Killed then
      begin
        if (Foes[k].KillFlags and LFF_AFTER <> 0) and (Foes[k].KillTick >= R.DeathTick) then
          S := 'killed ' + LfSeconds(Foes[k].KillTick - R.DeathTick, 2) + ' s after your death'
        else
          S := 'killed at ' + LfSeconds(Foes[k].KillTick - R.DeathTick, 2) + ' s';
        if Foes[k].KillFlags and LFF_MATE <> 0 then
          S := S + ', teammate';
      end;
      Row(E, Slot, [Copy(Foes[k].Name, 1, 17), FightWeapons(Foes[k]), PadL(Num(Foes[k].Hits), 4),
        PadL(Dmg(Foes[k].Damage), 5),
        Copy(LfZones(Foes[k].Zones[0], Foes[k].Zones[1], Foes[k].Zones[2], Foes[k].Zones[3], Foes[k].ZoneEst, ' '), 1, 11),
        S], FIGHT_DEALT, CLR_COMBAT);
    end;
    if nFoes > FIGHT_FOE_ROWS then
      Out(E, Slot, Format('... and %d more', [nFoes - FIGHT_FOE_ROWS]), CLR_HINT);
  end;

  { the points and assists of these seconds, from what the HUD said }
  Lost := 0;
  Won := 0;
  WonAfter := 0;
  Assists := 0;
  AssistsAfter := 0;
  for k := 0 to R.Count - 1 do
    if R.Events[k].Kind = LFE_NOTE then
    begin
      if (R.Events[k].Points < 0) and (R.Events[k].Tick >= R.DeathTick) then
        Inc(Lost, -R.Events[k].Points)
      else if R.Events[k].Points > 0 then
      begin
        Inc(Won, R.Events[k].Points);
        if R.Events[k].Tick > R.DeathTick then
          Inc(WonAfter, R.Events[k].Points);
      end;
      if R.Events[k].Text = 'Assist' then
      begin
        Inc(Assists);
        if R.Events[k].Tick > R.DeathTick then
          Inc(AssistsAfter);
      end;
    end;
  if not R.StatsOn then
    S := 'Points: none - the statistics did not count then (too few players).'
  else
  begin
    if Lost > 0 then
      S := 'Points: -' + Num(Lost) + ' for the death'
    else
      S := 'Points: nothing lost for the death';
    if Won > 0 then
    begin
      S := S + ', +' + Num(Won) + ' won';
      if WonAfter > 0 then
        S := S + ' (+' + Num(WonAfter) + ' after it)';
    end;
    if Assists > 0 then
    begin
      S := S + '; assists: ' + Num(Assists);
      if AssistsAfter > 0 then
        S := S + ' (' + Num(AssistsAfter) + ' after it)';
    end;
  end;
  Out(E, Slot, S, CLR_MATCHES);
  { what the columns of the timeline mean, and what of them is estimated }
  Out(E, Slot, 'Time: s from your death (+ = after it)  HP: health before the hit  Zone: ~ = a guess, ? = not told',
    CLR_HINT);
  S := 'Dist: from where the shot was fired to the hit  Flight: time in the air';
  if Mates then
    S := S + '  (mate) = a teammate';
  Out(E, Slot, S, CLR_HINT);
  Out(E, Slot, '~ = worked out from the bullet at the hit (nobody saw the shot, e.g. a bot''s): within a few m',
    CLR_HINT);
  Out(E, Slot, Format('Speed: of the one who was hit  Dodge (est.): under %s s of flight no, to %s s hard, then maybe',
    [FloatStr(LF_REACT_SECONDS, 2), FloatStr(LF_HARD_SECONDS, 1)]), CLR_HINT);
  Out(E, Slot, 'No flight or dodge for blasts, flames, blades, thrown knives; no ~ for Spas  (still) = stood still',
    CLR_HINT);
  Footer(E, Slot, LINE_W);
end;

{ !lastfight [1-3]: the caller's own deaths since he joined, 1 = the last one }
procedure CmdLastFight(E: TZSEngine; Slot: LongInt; const Arg: AnsiString);
var
  F: PLfSlot;
  P: PLfRecord;
  R: TLfRecord;
  N, Have: LongInt;
begin
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
  begin
    Out(E, Slot, '!lastfight is for players on the server: it shows their own last deaths.', CLR_WARN);
    Exit;
  end;
  if not E.Cfg.LastFightEnabled then
  begin
    Out(E, Slot, '!lastfight is switched off on this server.', CLR_WARN);
    Exit;
  end;
  N := 1;
  if Trim(Arg) <> '' then
    if AllDigits(Trim(Arg)) then
      N := StrToIntDef(Trim(Arg), 0)
    else
      N := 0;
  if (N < 1) or (N > LF_DEATHS) then
  begin
    Out(E, Slot, Format('Usage: !lastfight [1-%d]  (1 = your last death, %d = the oldest one kept)',
      [LF_DEATHS, LF_DEATHS]), CLR_WARN);
    Exit;
  end;
  F := @E.Extra[Slot].Fight;
  Have := LfRecords(F^);
  if Have = 0 then
  begin
    Out(E, Slot, Format('No death of yours is recorded yet: !lastfight shows your last %d deaths since you joined.',
      [LF_DEATHS]), CLR_HINT);
    Exit;
  end;
  if N > Have then
  begin
    if Have = 1 then
      Out(E, Slot, 'Only your last death is recorded so far: !lastfight 1.', CLR_WARN)
    else
      Out(E, Slot, Format('Only %d deaths of yours are recorded so far: !lastfight 1 to !lastfight %d.', [Have, Have]),
        CLR_WARN);
    Exit;
  end;
  P := LfRecordAt(F^, N);
  if P = nil then
    Exit;
  R := P^;
  { a death whose seconds after it still run: what is there so far }
  if not R.Closed then
    LfCollect(F^, R, LfWindowEnd(R, E.Live[Slot].SpawnTick, E.GameTick));
  FightReport(E, Slot, R, N, Have);
end;
