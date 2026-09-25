program test_live;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, zs_types, zs_weapons, zs_live;

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

var
  L: TLiveTable;
  SX, SY: Single;
  i, T, Z, Correct, Total: LongInt;
  Model: array[0..2] of THitModelCell;
  Moved: Single;
begin
  RandSeed := 42;
  ResetWeaponDefs;
  for i := 1 to MAX_PLAYERS do
    LiveResetSlot(L, i);

  LiveNoteShot(L[1], 100, WEP_AK74, 0, 0);
  LiveNoteShot(L[1], 110, WEP_AK74, 500, 0);
  Check('newest plausible shot is used', LiveFindShot(L[1], WEP_AK74, 112, 560, 0, 0, 0, SX, SY) and (SX = 500));
  Check('older shot used when the newer one is too far', LiveFindShot(L[1], WEP_AK74, 112, -60, 0, 0, 0, SX, SY) and (SX = 0));
  Check('impossible distance is rejected', not LiveFindShot(L[1], WEP_AK74, 112, 5000, 0, 0, 0, SX, SY));
  Check('other weapons are ignored', not LiveFindShot(L[1], WEP_BARRETT, 112, 560, 0, 0, 0, SX, SY));
  LiveNoteShot(L[1], 200, WEP_THROWNKNIFE, 10, 10);
  Check('thrown knife matches the knife slot', LiveFindShot(L[1], WEP_KNIFE, 215, 150, 10, 0, 0, SX, SY) and (SX = 10));
  Check('shots older than the flight limit are ignored', not LiveFindShot(L[1], WEP_AK74, 110 + MAX_FLIGHT_TICKS + 5, 520, 0, 0, 0, SX, SY));
  for i := 1 to SHOT_RING + 16 do
    LiveNoteShot(L[2], 1000 + i, WEP_MP5, i * 10, 0);
  Check('ring keeps the newest shots', (L[2].ShotCount = SHOT_RING) and
    LiveFindShot(L[2], WEP_MP5, 1000 + SHOT_RING + 17, (SHOT_RING + 16) * 10, 0, 0, 0, SX, SY) and (SX = (SHOT_RING + 16) * 10));
  LiveNoteShot(L[7], 500, WEP_BARRETT, 0, 0);
  LiveNoteShot(L[7], 505, WEP_BARRETT, 1000, 0);
  Check('the direction of flight picks the right shot', LiveFindShot(L[7], WEP_BARRETT, 520, 500, 0, 50, 0, SX, SY) and (SX = 0));
  Check('without a velocity the newest plausible shot is used', LiveFindShot(L[7], WEP_BARRETT, 520, 500, 0, 0, 0, SX, SY) and (SX = 1000));
  LiveNoteShot(L[8], 600, WEP_M79, 300, 0);
  Check('arcing projectiles skip the direction check', LiveFindShot(L[8], WEP_M79, 640, 100, 0, 30, 0, SX, SY) and (SX = 300));
  LiveNoteShot(L[6], 300, WEP_FRAG, 50, 50);
  Check('cluster grenade kill matches a grenade throw', LiveFindShot(L[6], WEP_CLUSTER, 330, 150, 50, 0, 0, SX, SY) and (SX = 50));

  LiveSpawn(L, 3, 0, 100, 100);
  T := 0;
  for i := 1 to 100 do
  begin
    T := i * 12;
    LiveNoteSample(L[3], T, 100 + (i mod 2) * 5, 100, WEP_AK74, 30, 0, EF_A_ONGROUND or EF_A_ALIVE, 80);
  end;
  Check('small jitter counts as camping and inactivity', (LiveCampTicks(L[3], T) = T) and (LiveInactiveTicks(L[3], T) = T));
  Moved := LiveNoteSample(L[3], T + 12, 300, 100, WEP_AK74, 30, 0, EF_A_ONGROUND, 80);
  Check('moving resets camping and inactivity', (Round(Moved) = 200) and (LiveCampTicks(L[3], T + 12) = 0) and
    (LiveInactiveTicks(L[3], T + 12) = 0));
  Moved := LiveNoteSample(L[3], T + 24, 2000, 100, WEP_AK74, 30, 0, EF_A_ONGROUND, 80);
  Check('teleports do not count as travel', Moved = 0);
  LiveNoteShot(L[3], T + 400, WEP_AK74, 2000, 100);
  Check('shooting counts as activity', LiveInactiveTicks(L[3], T + 410) = 10);

  L[4].Pair[5].DamageThisLife := 70;
  L[4].Pair[5].FirstDamageTick := 50;
  L[4].Pair[5].LastDamageTick := 58;
  LiveLifeEnded(L, 5, 60);
  Check('damage ledger cleared when the victim dies', (L[4].Pair[5].DamageThisLife = 0) and (L[4].Pair[5].FirstDamageTick = 0) and not L[5].Alive);
  Check('the last hit on a life ends with it', L[4].Pair[5].LastDamageTick = 0);
  L[4].Pair[5].LastDamageTick := 70;
  LiveSpawn(L, 5, 80, 0, 0);
  Check('a new life starts without a last hit: a selfkill right after the spawn owes nobody',
    (L[4].Pair[5].LastDamageTick = 0) and L[5].Alive);

  { the server's kill at the end of a survival round is no death: the spree goes on in the next
    life, which still starts a new multi-kill chain; a real death ends the spree }
  LiveSpawn(L, 9, 1000, 0, 0);
  L[9].KillStreak := 4;
  L[9].KnifeKillsLife := 2;
  L[9].LastKillTick := 1500;
  L[9].MultiKillCount := 2;
  L[9].Flags := EF_A_FLAGGER or EF_A_ONGROUND or EF_A_ALIVE;
  LiveLifeEnded(L, 9, 1600, True);
  Check('a kill of the server keeps the spree, a dead player carries no flag', (L[9].KillStreak = 4) and
    (L[9].KnifeKillsLife = 2) and L[9].StreakCarry and not L[9].Alive and (L[9].Flags = 0));
  LiveSpawn(L, 9, 1700, 0, 0);
  Check('the next life goes on with the spree, not with the multi-kill chain', (L[9].KillStreak = 4) and
    (L[9].KnifeKillsLife = 2) and not L[9].StreakCarry and (L[9].LastKillTick = 0) and (L[9].MultiKillCount = 0));
  LiveLifeEnded(L, 9, 1800);
  LiveSpawn(L, 9, 1900, 0, 0);
  Check('a real death ends the spree', (L[9].KillStreak = 0) and (L[9].KnifeKillsLife = 0) and not L[9].StreakCarry);
  { the server respawns everybody for a new map before the script hears of the map }
  LiveSpawn(L, 10, 2000, 0, 0);
  LiveSpawn(L, 11, 1990, 0, 0);
  LiveResetMatch(L, 2000);
  Check('a new map keeps the lives begun with it and ends the others', L[10].Alive and not L[11].Alive and
    (L[10].LifeSeconds = 0));

  Check('posture', (PostureOf(EF_B_PRONE or EF_B_ONGROUND, True) = POSTURE_PRONE) and
    (PostureOf(EF_A_ONGROUND, False) = POSTURE_STAND) and (PostureOf(0, False) = POSTURE_AIR) and
    (PostureOf(EF_A_CROUCH or EF_A_ONGROUND, False) = POSTURE_CROUCH));

  FillChar(Model, SizeOf(Model), 0);
  Check('hit model needs samples', HitModelClassify(Model, 0, -30, HIT_MODEL_MIN_SAMPLES) = HZ_UNKNOWN);
  for i := 1 to 300 do
  begin
    HitModelLearn(Model[HZ_HEAD], RandG(0, 4), RandG(-32, 3));
    HitModelLearn(Model[HZ_BODY], RandG(0, 5), RandG(-14, 5));
    HitModelLearn(Model[HZ_LEGS], RandG(0, 5), RandG(6, 4));
  end;
  Correct := 0;
  Total := 0;
  for i := 1 to 300 do
  begin
    Z := Random(3);
    case Z of
      HZ_HEAD: if HitModelClassify(Model, RandG(0, 4), RandG(-32, 3), HIT_MODEL_MIN_SAMPLES) = Z then Inc(Correct);
      HZ_BODY: if HitModelClassify(Model, RandG(0, 5), RandG(-14, 5), HIT_MODEL_MIN_SAMPLES) = Z then Inc(Correct);
      HZ_LEGS: if HitModelClassify(Model, RandG(0, 5), RandG(6, 4), HIT_MODEL_MIN_SAMPLES) = Z then Inc(Correct);
    end;
    Inc(Total);
  end;
  WriteLn('       hit model accuracy on separated clusters: ', Correct * 100 div Total, '%');
  Check('hit model classifies learned clusters', Correct * 100 div Total >= 85);

  LiveResetSlot(L, 1);
  Check('reset clears shots', (L[1].ShotCount = 0) and not LiveFindShot(L[1], WEP_AK74, 112, 560, 0, 0, 0, SX, SY));

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
