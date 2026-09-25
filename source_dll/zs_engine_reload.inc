{ zs_engine_reload.inc - reloads, read from the ammunition of the weapon in hand (part of zs_engine)

  Soldat tells a script nothing about reloading: there is no event and no counter. What the script
  sees is the ammunition of the weapon in hand. A magazine that drops to 0 is being reloaded (the
  game has no other state for it), and a jump from 0 to a full magazine is the end of the reload.
  The Spas-12 loads shell by shell, one about every 24 ticks. How long a reload takes comes from
  weapons.ini (weapons_realistic.ini in realistic mode, or the file of /loadwep).

  The ammunition of a human player is the one his game reports, a few ticks late and not every
  tick; the server also counts down on its own. So a reload that ends more than REFILL_EARLY
  ticks before its time is not believed at once: the late "empty" of the game may still follow,
  and then the same reload goes on. Such a reload counts as finished, but not in the times. }

const
  REFILL_EARLY = 15;        { ticks a refill may come before the time weapons.ini gives }
  CHANGE_TICKS = 24;        { a weapon change: the reload stands still until the swap }
  THROW_TICKS = 18;         { throwing the gun away }
  RESUME_TICKS = 16;        { the rest of the change animation before a resumed reload goes on }
  SPAS_SHELL_TICKS = 24;    { one shell of the Spas-12 }

  RC_DONE = 0;              { finished, its length known }
  RC_DONE_UNTIMED = 1;      { finished, its length unknown }
  RC_CUT = 2;               { broken off: the weapon was thrown away, or changed and not taken up again }
  RC_DEATH = 3;             { the player was killed }
  RC_QUIET = 4;             { ended by something that is nobody's doing: respawn, map, /loadwep }

{ how far the open reload of a slot got, per mille, at a tick }
function TZSEngine.ReloadMille(S, Tick: LongInt): LongInt;
begin
  if Extra[S].RlSpas then
    Result := EnsureRange(Extra[S].RlShellsDone * 1000 div Max(1, Extra[S].RlShellsNeeded), 0, 1000)
  else
    { in 64 bits: a reload whose end never came (an idle player) can stay open for hours }
    Result := EnsureRange(Int64(Max(0, Tick - Extra[S].RlStart)) * 1000 div Max(1, Extra[S].RlExpected), 0, 1000);
end;

{ the weapon statistics of the player on a slot, nil for a bot or while statistics are off }
function TZSEngine.ReloadStats(S, Weapon: LongInt; out Idx: LongInt): PWeaponStats;
var
  WS: LongInt;
begin
  Result := nil;
  Idx := -1;
  if not Live[S].Human or not StatsOn then
    Exit;
  WS := WepSlot(Weapon);
  Idx := Identity.StatsIndex(S);
  if (WS < 0) or not DB.Valid(Idx) then
    Exit;
  Result := @DB.Profiles[Idx]^.Weapons[WS];
end;

procedure TZSEngine.ReloadOpen(S, Weapon, Tick: LongInt; Manual: Boolean; RoundsLeft: LongInt);
var
  Idx: LongInt;
  St: PWeaponStats;
begin
  Extra[S].RlOpen := True;
  Extra[S].RlWeapon := Weapon;
  Extra[S].RlStart := Tick;
  Extra[S].RlExpected := Max(1, WeaponDefs[WepSlot(Weapon)].ReloadTime);
  Extra[S].RlEarly := False;
  Extra[S].RlResumed := False;
  Extra[S].RlSpas := Weapon = WEP_SPAS;
  Extra[S].RlShellsNeeded := 0;
  Extra[S].RlShellsDone := 0;
  St := ReloadStats(S, Weapon, Idx);
  if St = nil then
    Exit;
  Inc(St^.Reloads);
  if Manual then
  begin
    Inc(St^.ReloadsManual);
    Inc(St^.RoundsDropped, RoundsLeft);
  end;
  DB.Touch(Idx);
end;

{ the Spas-12 starts loading: the first shell is in, about one shell time after the start }
procedure TZSEngine.ReloadOpenSpas(S, Tick, Shells: LongInt);
begin
  ReloadOpen(S, WEP_SPAS, Tick - SPAS_SHELL_TICKS, Shells > 0, 0);
  Extra[S].RlShellsNeeded := Max(1, WeaponDefs[WepSlot(WEP_SPAS)].Ammo - Shells);
  Extra[S].RlExpected := Extra[S].RlShellsNeeded * SPAS_SHELL_TICKS;
end;

procedure TZSEngine.ReloadClose(S, How, Tick: LongInt);
var
  Idx, Mille: LongInt;
  Elapsed: Int64;
  St: PWeaponStats;
begin
  if not Extra[S].RlOpen then
    Exit;
  Extra[S].RlOpen := False;
  Extra[S].RlEarly := False;
  if How = RC_QUIET then
    Exit;
  St := ReloadStats(S, Extra[S].RlWeapon, Idx);
  if St = nil then
    Exit;
  Elapsed := Max(0, Tick - Extra[S].RlStart);
  Mille := ReloadMille(S, Tick);
  case How of
    RC_DONE, RC_DONE_UNTIMED:
      begin
        Inc(St^.ReloadsDone);
        Mille := 1000;
        if (How = RC_DONE) and not Extra[S].RlResumed then
        begin
          Inc(St^.ReloadTimed);
          Inc(St^.ReloadTicks, Elapsed);
          Inc(St^.ReloadNormTicks, Extra[S].RlExpected);
        end
        else
          Elapsed := Min(Elapsed, Int64(Extra[S].RlExpected));
      end;
    RC_CUT:
      begin
        Inc(St^.ReloadsCut);
        Mille := Min(Mille, 999);
      end;
    RC_DEATH:
      begin
        Inc(St^.ReloadDeaths);
        Mille := Min(Mille, 999);
        Inc(St^.ReloadDeathMille, Mille);
      end;
  end;
  Inc(St^.ReloadEnds);
  Inc(St^.ReloadDoneMille, Mille);
  Inc(St^.ReloadTicksAll, Elapsed);
  DB.Touch(Idx);
end;

{ A reload left by a weapon change (RlSaved) has not ended: when the weapon comes back empty the same
  reload goes on, and it ends once, finished or not. It is broken off only when it is clear that it
  does not go on - the weapon comes back loaded, the life ends, the player leaves - and it counts
  then, with how far it had got when it was left. }
procedure TZSEngine.ReloadDropSaved(S, WS: LongInt);
var
  Idx: LongInt;
  St: PWeaponStats;
begin
  if Extra[S].RlSaved[WS] > 0 then
  begin
    St := ReloadStats(S, SlotWeapon(WS), Idx);
    if St <> nil then
    begin
      Inc(St^.ReloadsCut);
      Inc(St^.ReloadEnds);
      Inc(St^.ReloadDoneMille, Min(Extra[S].RlSaved[WS] - 1, 999));
      Inc(St^.ReloadTicksAll, Extra[S].RlSavedTicks[WS]);
      DB.Touch(Idx);
    end;
  end;
  Extra[S].RlSaved[WS] := 0;
  Extra[S].RlSavedTicks[WS] := 0;
end;

{ respawn, leave, team change, map change, /loadwep: the reload under way ends without a verdict;
  one left by a weapon change was broken off by that change }
procedure TZSEngine.ReloadForget(S: LongInt);
var
  k: LongInt;
begin
  ReloadClose(S, RC_QUIET, GameTick);
  for k := 0 to High(Extra[S].RlSaved) do
    ReloadDropSaved(S, k);
end;

procedure TZSEngine.ReloadForgetAll;
var
  S: LongInt;
begin
  for S := 1 to MAX_PLAYERS do
    ReloadForget(S);
end;

{ An early refill that no late "empty" followed: the reload was done after all (its length is
  unknown). Once a second, from the tick of the game. }
procedure TZSEngine.ReloadDeadlines(Tick: LongInt);
var
  S: LongInt;
begin
  for S := 1 to MAX_PLAYERS do
    if Extra[S].RlOpen and Extra[S].RlEarly and (Tick >= Extra[S].RlEarlyUntil) then
      ReloadClose(S, RC_DONE_UNTIMED, Tick);
end;

{ The ammunition of the weapon in hand changed (ZS_Ev_Ammo). A drop is shots or the start of a
  reload, a rise the end of one (or a shell of the Spas-12). Only real shots are counted as shots:
  a reload with rounds left used to count those rounds as fired. }
procedure TZSEngine.EvAmmo(var E: TZSEvent);
var
  S, W, WS, Old, New, Mag, Interval, Shots: LongInt;
  Key: Boolean;
begin
  S := E.Slot;
  if not SlotValid(S) then
    Exit;
  W := E.I[0];
  Old := E.I[1];
  New := E.I[2];
  Key := E.I[3] and 1 <> 0;
  WS := WepSlot(W);
  if WS < 0 then
    Exit;
  Mag := WeaponDefs[WS].Ammo;
  Interval := Max(1, WeaponDefs[WS].FireInterval);
  Shots := 0;
  { 255 from a bullet the server let through with an empty magazine, or a weapon another script
    changed: neither shots nor a reload - for the flamethrower as much as for the guns }
  if (Old < 0) or (New < 0) or (Old > Mag) or (New > Mag) then
  else if not ReloadTracked(W) then
  begin
    if New < Old then
      Shots := Old - New;
  end
  else if New < Old then
  begin
    if W = WEP_SPAS then
    begin
      Shots := Old - New;
      { firing stops the loading }
      if Extra[S].RlOpen then
        ReloadClose(S, RC_CUT, E.Tick);
    end
    else if New = 0 then
    begin
      if Extra[S].RlOpen and Extra[S].RlEarly and (Extra[S].RlWeapon = W) and (Old = Mag) then
        { the late "empty" of the game after an early refill: the same reload goes on }
        Extra[S].RlEarly := False
      else
      begin
        if Extra[S].RlOpen then
          ReloadClose(S, RC_DONE_UNTIMED, E.Tick);
        if Old = 1 then
        begin
          { the last round, or the reload key on one round }
          if Key then
            ReloadOpen(S, W, E.Tick, True, 1)
          else
          begin
            Shots := 1;
            ReloadOpen(S, W, E.Tick, False, 0);
          end;
        end
        { a gun that fires more slowly than every 5 ticks is seen round by round: a drop of
          several rounds straight to 0 is the reload key }
        else if Interval > 5 then
          ReloadOpen(S, W, E.Tick, True, Old)
        { the minigun and the chainsaw are seen in batches: more than one batch at once is a reload }
        else if Key or (Old > 14 div Interval + 1) then
          ReloadOpen(S, W, E.Tick, True, Old)
        else
        begin
          Shots := Old;
          ReloadOpen(S, W, E.Tick, False, 0);
        end;
      end;
    end
    else
    begin
      Shots := Old - New;
      { firing after an early refill: that reload was done }
      if Extra[S].RlOpen and Extra[S].RlEarly and (Extra[S].RlWeapon = W) then
        ReloadClose(S, RC_DONE_UNTIMED, E.Tick);
    end;
  end
  else if New > Old then
  begin
    if W = WEP_SPAS then
    begin
      if not Extra[S].RlOpen or (Extra[S].RlWeapon <> W) then
      begin
        ReloadClose(S, RC_QUIET, E.Tick);
        ReloadOpenSpas(S, E.Tick, Old);
      end;
      Inc(Extra[S].RlShellsDone, New - Old);
      if New >= Mag then
        ReloadClose(S, RC_DONE, E.Tick);
    end
    else if Extra[S].RlOpen and (Extra[S].RlWeapon = W) and (Old = 0) then
    begin
      if New = Mag then
      begin
        if E.Tick - Extra[S].RlStart >= Extra[S].RlExpected - REFILL_EARLY then
          ReloadClose(S, RC_DONE, E.Tick)
        else
        begin
          Extra[S].RlEarly := True;
          Extra[S].RlEarlyUntil := Extra[S].RlStart + Extra[S].RlExpected - REFILL_EARLY;
        end;
      end
      else
      begin
        { refilled, and a few rounds fired before the script looked again }
        ReloadClose(S, RC_DONE_UNTIMED, E.Tick);
        Shots := Mag - New;
      end;
    end;
    { any other rise is another script at work, not a reload }
  end;
  if Shots > 0 then
  begin
    LiveNoteShot(Live[S], GameTick, W, E.F[0], E.F[1]);
    if Live[S].Human and StatsOn then
      CountShots(S, W, Shots);
  end;
end;

{ The weapon in hand changed. An open reload stops where it was (a weapon put away never counts
  down) and goes on when the player takes the weapon again - it is still the one reload that was
  started, and it ends once (ReloadDropSaved); a weapon taken with an empty magazine starts reloading
  at once. The change that follows a death is the gun the player drops. }
procedure TZSEngine.ReloadOnWeapon(S, OldW, NewW, NewAmmo, Tick: LongInt);
var
  WS, Pause, Saved: LongInt;
begin
  if Extra[S].RlDeathTick = Tick then
    Exit;
  if Extra[S].RlOpen then
  begin
    if Extra[S].RlWeapon = NewW then
      Exit;
    if NewW = WEP_NONE then
      Pause := THROW_TICKS
    else
      Pause := CHANGE_TICKS;
    WS := WepSlot(Extra[S].RlWeapon);
    if (WS >= 0) and not Extra[S].RlSpas and (NewW <> WEP_NONE) then
    begin
      { left, not ended: it counts when it is clear whether it goes on }
      ReloadDropSaved(S, WS);
      Extra[S].RlSaved[WS] := ReloadMille(S, Tick - Pause) + 1;
      Extra[S].RlSavedTicks[WS] := Max(0, Tick - Pause - Extra[S].RlStart);
      Extra[S].RlOpen := False;
      Extra[S].RlEarly := False;
    end
    else
      { thrown away, or the shell by shell loading of the Spas-12: that reload is over }
      ReloadClose(S, RC_CUT, Tick - Pause);
  end;
  WS := WepSlot(NewW);
  if (WS < 0) or not ReloadTracked(NewW) then
    Exit;
  if (NewAmmo <> 0) or (NewW = WEP_SPAS) then
  begin
    { the weapon came back loaded: the reload left on it did not go on }
    ReloadDropSaved(S, WS);
    Exit;
  end;
  Saved := Extra[S].RlSaved[WS];
  Extra[S].RlSaved[WS] := 0;
  Extra[S].RlSavedTicks[WS] := 0;
  if Saved > 0 then
  begin
    { the weapon comes back half reloaded: the same reload goes on after the change }
    Extra[S].RlOpen := True;
    Extra[S].RlWeapon := NewW;
    Extra[S].RlExpected := Max(1, WeaponDefs[WS].ReloadTime);
    Extra[S].RlStart := Tick + RESUME_TICKS - (Saved - 1) * Extra[S].RlExpected div 1000;
    Extra[S].RlEarly := False;
    Extra[S].RlResumed := True;
    Extra[S].RlSpas := False;
  end
  else
    { an empty gun picked up, or given by a script }
    ReloadOpen(S, NewW, Tick, False, 0);
end;

{ the player was killed: a reload under way ends there, unless the server killed the player
  itself (a team change in survival, the end of a round); one left by a weapon change was broken
  off by that change }
procedure TZSEngine.ReloadOnDeath(S, Tick: LongInt; Blame: Boolean);
var
  k: LongInt;
begin
  Extra[S].RlDeathTick := Tick;
  if Blame then
    ReloadClose(S, RC_DEATH, Tick)
  else
    ReloadClose(S, RC_QUIET, Tick);
  for k := 0 to High(Extra[S].RlSaved) do
    ReloadDropSaved(S, k);
end;

{ the weapons file of the mode being played, or the one /loadwep named }
procedure TZSEngine.LoadWeaponsForMode;
var
  Ini: AnsiString;
begin
  if WeaponsIniOverride <> '' then
    Ini := WeaponsIniOverride
  else if Match.Realistic then
    Ini := 'weapons_realistic.ini'
  else
    Ini := 'weapons.ini';
  ResetWeaponDefs;
  if FileExists(Ini) then
    LoadWeaponsIni(Ini);
end;

{ Realistic mode was switched while the script runs (ZS_Ev_Realistic). The server itself starts
  the game again for /realistic, but a script may set it too. }
procedure TZSEngine.EvRealistic(var E: TZSEvent);
begin
  if Match.Realistic = (E.I[0] <> 0) then
    Exit;
  Match.Realistic := E.I[0] <> 0;
  LoadWeaponsForMode;
  ReloadForgetAll;
end;

{ /loadwep [name]: the server reads the weapons file of the mode, or <name>.ini, and keeps it
  until it starts the game again. A Game.LoadWeap of another script is not seen here. }
procedure TZSEngine.NoteLoadWeapons(const W: TStringArray);
begin
  if Length(W) > 1 then
    WeaponsIniOverride := W[1] + '.ini'
  else
    WeaponsIniOverride := '';
  LoadWeaponsForMode;
  ReloadForgetAll;
end;
