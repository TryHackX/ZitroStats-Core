program test_balance;

{ The team balance maths, including the thought experiments of the balance plan. }

{$mode objfpc}{$H+}

uses
  SysUtils, Math, zs_util, zs_balance;

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

function Near(A, B, Eps: Double): Boolean;
begin
  Result := Abs(A - B) <= Eps;
end;

var
  Params: TBalParams;

procedure ResetParams;
var
  t: LongInt;
begin
  Params.SizeImpact := 1.5;
  for t := 0 to BAL_MAX_TEAMS - 1 do
    Params.Bias[t] := 1;
end;

{ players by team and strength; with ProtectTop the strongest of every team (the first of equals)
  may not be moved }
function Build(const Teams: array of LongInt; const Strengths: array of Double; ProtectTop: Boolean): TBalCandArray;
var
  i, j: LongInt;
  Top: Boolean;
begin
  Result := nil;
  SetLength(Result, Length(Teams));
  for i := 0 to High(Teams) do
  begin
    Result[i].Id := i + 1;
    Result[i].Team := Teams[i];
    Result[i].Power := BalPower(Strengths[i], 1500, 400);
    Result[i].Cost := 0.01;
    Result[i].Counts := True;
    Top := True;
    for j := 0 to High(Teams) do
      if (j <> i) and (Teams[j] = Teams[i]) and
         ((Strengths[j] > Strengths[i]) or ((Strengths[j] = Strengths[i]) and (j < i))) then
        Top := False;
    Result[i].Movable := not (ProtectTop and Top);
  end;
end;

function Imb(const C: TBalCandArray; TeamCount: LongInt; out Ch: TBalTeamValues): Double;
begin
  Result := BalMatchImbalance(C, TeamCount, Params, Ch);
end;

var
  C: TBalCandArray;
  Ch, After: TBalTeamValues;
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
  Move: TBalMove;
  Found: Boolean;
  D, Best, V: Double;
  Teams: array of LongInt;
  Changed, Mask, i, k, T: LongInt;
  Recs: TBalRecordArray;
  R: TBalRecord;
  Seed: LongWord;
  FitSize, FitDouble, FitBrier: Double;
  Line: AnsiString;
  MixSeed: LongWord;
  Work: TBalCandArray;
  Distinct, Round1: LongInt;
  Key, Keys: AnsiString;
  AllFair, AllMoved, AllEven, KeptFixed, HalfOrLess, NewMates, SameMates: Boolean;
  Allowed: array[0..BAL_MAX_TEAMS - 1] of Boolean;
  T0: Int64;

function NextRandom: Double;
begin
  Seed := LongWord((Int64(Seed) * 1664525 + 1013904223) and $FFFFFFFF);
  Result := (Seed shr 8) / 16777216.0;
end;

begin
  ResetParams;

  { ---- the model ---- }
  Check('400 points above the median is twice the power', Near(BalPower(1900, 1500, 400), 2, 1e-9));
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1], [1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500], False);
  D := Imb(C, 2, Ch);
  WriteLn(Format('       5 against 4 average players: %.1f%%', [Ch[0] * 100]));
  Check('five average players against four have 58%', Near(Ch[0], 0.5829, 0.001) and Near(D, 0.0829, 0.001));
  Pow[0] := 3; Pow[1] := 1; Pow[2] := 1; Pow[3] := 1;
  BalChances(Pow, 4, Params, Ch);
  D := BalImbalance(Ch, 4);
  Check('four teams: the imbalance is scaled like two teams', Near(D, (Ch[0] - 0.25) * 2, 1e-9) and (Ch[0] > 0.5));
  Pow[0] := 1; Pow[1] := 1;
  Params.Bias[0] := 1.5;
  BalChances(Pow, 2, Params, Ch);
  Check('the side advantage of a map is a factor', Near(Ch[0], 0.6, 1e-9));
  ResetParams;

  { ---- the leader: 2200 and four players of 1500 against five of 1500 ---- }
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], [2200, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500], True);
  D := Imb(C, 2, Ch);
  WriteLn(Format('       leader line-up: Alpha %.1f%%', [Ch[0] * 100]));
  Check('the leader makes Alpha the favourite (64%)', Near(Ch[0], 0.64, 0.01));
  Found := BalBestChange(C, 2, Params, 1, 0.05, 0.04, False, True, Move);
  Check('leader protected, one player apart at most: no fair change exists', not Found);
  Found := BalBestChange(C, 2, Params, 2, 0.05, 0.04, False, True, Move);
  Check('two players apart allowed: one Alpha player goes to Bravo, about 52%',
    Found and (Move.Kind = BM_MOVE) and (C[Move.A].Team = 0) and (Move.A <> 0) and (Move.ToTeam = 1) and
    Near(Move.After, 0.02, 0.02));
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], [2200, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500], False);
  Found := BalBestChange(C, 2, Params, 1, 0.05, 0.04, False, True, Move);
  Check('without protection a swap of the leader would overshoot, so it is not taken',
    not Found or (Move.Kind <> BM_SWAP) or ((Move.A <> 0) and (Move.B <> 0)));

  { ---- two players left: 6 against 4 of equal strength ---- }
  C := Build([0, 0, 0, 0, 0, 0, 1, 1, 1, 1], [1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500], True);
  D := Imb(C, 2, Ch);
  WriteLn(Format('       6 against 4: Alpha %.1f%%', [Ch[0] * 100]));
  Found := BalBestChange(C, 2, Params, 1, 0.05, 0.04, True, False, Move);
  Check('six against four: one Alpha player moves and the match is even',
    Found and (Move.Kind = BM_MOVE) and (C[Move.A].Team = 0) and Near(Move.After, 0, 1e-9));

  { ---- a strong pack: three good players together ---- }
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], [1900, 1850, 1800, 1400, 1350, 1550, 1520, 1500, 1480, 1450], True);
  D := Imb(C, 2, Ch);
  Found := BalBestChange(C, 2, Params, 1, 0.05, 0.04, False, True, Move);
  WriteLn(Format('       pack: Alpha %.1f%%, change %d -> imbalance %.3f', [Ch[0] * 100, Move.Kind, Move.After]));
  Check('a strong pack is broken up by a swap that keeps the numbers',
    Found and (Move.Kind = BM_SWAP) and (Move.After < D - 0.04));

  { ---- even teams: nothing to do ---- }
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], [1600, 1550, 1500, 1450, 1400, 1610, 1540, 1500, 1460, 1390], True);
  D := Imb(C, 2, Ch);
  Found := BalBestChange(C, 2, Params, 1, 0.05, 0.04, False, True, Move);
  Check('even teams stay as they are', (D < 0.05) and not Found);

  { ---- three against one and every Alpha player protected: the numbers are fixed anyway, by the
    cheapest protection that gives way; a hard one (Soft < 0) never does ---- }
  C := Build([0, 0, 0, 1], [1500, 1500, 1500, 1500], False);
  for i := 0 to 3 do
    C[i].Movable := False;
  C[0].Soft := -1;      { carries a flag }
  C[1].Soft := 0.25;    { moved a moment ago, the way back locked }
  C[2].Soft := 0.05;    { carries the team }
  Found := BalBestChange(C, 2, Params, 1, 0.05, 0, True, False, Move);
  Check('three against one, nobody free: the plain count fix finds nobody', not Found);
  Found := BalBestCountFix(C, 2, Params, 1, Move);
  Check('the second run takes the cheapest protection', Found and (Move.Kind = BM_MOVE) and (Move.A = 2) and
    (Move.ToTeam = 1));
  C[2].Soft := -1;
  Found := BalBestCountFix(C, 2, Params, 1, Move);
  Check('then the dearer one', Found and (Move.A = 1) and (Move.ToTeam = 1));
  C[1].Soft := -1;
  Found := BalBestCountFix(C, 2, Params, 1, Move);
  Check('never a player with Soft < 0', not Found);
  C := Build([0, 0, 0, 1], [1500, 1500, 1500, 1500], False);
  for i := 0 to 2 do
    C[i].Movable := False;
  C[0].Soft := 0.05;
  C[0].Cost := 0.30;
  C[1].Soft := -1;
  C[2].Soft := 0.10;
  Found := BalBestCountFix(C, 2, Params, 1, Move);
  Check('the price of a protection comes on top of what the move costs', Found and (Move.A = 2));

  { ---- !switch: to the team that evens the match, never to one that is not allowed ---- }
  C := Build([0, 0, 0, 1], [1500, 1500, 1500, 1500], False);
  D := Imb(C, 2, Ch);
  BalTotals(C, 2, Pow, Cnt);
  Allowed[0] := True;
  Allowed[1] := True;
  T := BalBestSwitch(C, 2, Params, 0, Allowed, 1, V, k);
  Check('three against one: a switch goes to the small team and evens the numbers', (T = 1) and (k = 0) and
    BalSwitchHelpful(D, V, BalSpread(Cnt, 2), k, 0.05, 0.04));
  Allowed[1] := False;
  T := BalBestSwitch(C, 2, Params, 0, Allowed, 1, V, k);
  Check('a locked team is no choice', T = -1);
  C := Build([0, 0, 1, 1], [1500, 1500, 1500, 1500], False);
  Allowed[1] := True;
  T := BalBestSwitch(C, 2, Params, 0, Allowed, 1, V, k);
  Check('two against two: a switch would break the numbers', T = -1);

  { ---- joins ---- }
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1], [1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500], False);
  BalTotals(C, 2, Pow, Cnt);
  T := BalBestJoin(Pow, Cnt, 2, Params, 1, True, 1, 0, After);
  Check('a new player goes to the smaller team', (T = 1) and (After[0] = 9));
  Pow[1] := Pow[1] + 1;
  Inc(Cnt[1]);
  T := BalBestJoin(Pow, Cnt, 2, Params, 1, True, 1, 0, After);
  k := BalBestJoin(Pow, Cnt, 2, Params, 1, True, 1, 1, After);
  Check('the next player in the same tick sees the first one; equal choices keep the team asked for',
    (T = 0) and (k = 1));
  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], [1900, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500], False);
  BalTotals(C, 2, Pow, Cnt);
  T := BalBestJoin(Pow, Cnt, 2, Params, 1, True, 1, 0, After);
  Check('equal numbers: the new player goes to the weaker team', (T = 1) and (After[1] < After[0]));
  C := Build([0, 0, 1, 1, 2, 2, 3], [1500, 1500, 1500, 1500, 1500, 1500, 1500], False);
  BalTotals(C, 4, Pow, Cnt);
  T := BalBestJoin(Pow, Cnt, 4, Params, 1, True, 1, 0, After);
  Check('teammatch with four teams: 2/2/2/1 gets the new player in the fourth team', T = 3);
  Cnt[0] := 5; Cnt[1] := 3;
  Pow[0] := 5; Pow[1] := 3;
  T := BalBestJoin(Pow, Cnt, 2, Params, 1, True, 1, 0, After);
  Check('numbers already too far apart: only the smallest team is offered', T = 1);

  { ---- a new split: three against three with a pro ---- }
  C := Build([0, 0, 0, 1, 1, 1], [2000, 1600, 1550, 1500, 1400, 1300], False);
  SetLength(Teams, 6);
  for i := 0 to 5 do
    Teams[i] := C[i].Team;
  Changed := BalRearrange(C, 2, Params, 1, 0, True, Teams);
  for i := 0 to 5 do
    C[i].Team := Teams[i];
  V := Imb(C, 2, Ch);
  { every split of six players into three and three }
  Best := 9;
  for Mask := 0 to 63 do
  begin
    k := 0;
    for i := 0 to 5 do
      if Mask and (1 shl i) <> 0 then
        Inc(k);
    if k <> 3 then
      Continue;
    for i := 0 to 5 do
      if Mask and (1 shl i) <> 0 then
        C[i].Team := 0
      else
        C[i].Team := 1;
    Best := Min(Best, Imb(C, 2, Ch));
  end;
  WriteLn(Format('       new split: imbalance %.4f, best possible %.4f, %d moved', [V, Best, Changed]));
  Check('a new split finds the best of all splits', Near(V, Best, 1e-9));
  Check('the pro plays with the two weakest', (Teams[0] = Teams[4]) and (Teams[0] = Teams[5]));

  C := Build([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], [1600, 1550, 1500, 1450, 1400, 1610, 1540, 1500, 1460, 1390], False);
  SetLength(Teams, 10);
  for i := 0 to 9 do
    Teams[i] := C[i].Team;
  Changed := BalRearrange(C, 2, Params, 1, 0.02, False, Teams);
  Check('fixing even teams with a cost per change moves nobody', Changed = 0);

  { ---- a mix: fair every time, never the same line-up, different from mix to mix ---- }
  C := Build([0, 0, 0, 0, 1, 1, 1, 1], [1900, 1700, 1500, 1300, 1850, 1650, 1450, 1350], False);
  C[7].Movable := False;
  SetLength(Teams, 8);
  MixSeed := 777;
  Distinct := 0;
  Keys := '';
  AllFair := True;
  AllMoved := True;
  AllEven := True;
  KeptFixed := True;
  for Round1 := 1 to 20 do
  begin
    for i := 0 to 7 do
      Teams[i] := C[i].Team;
    Changed := BalMixTeams(C, 2, Params, 1, 40, 0.05, MixSeed, Teams);
    Work := Copy(C);
    for i := 0 to 7 do
      Work[i].Team := Teams[i];
    V := Imb(Work, 2, Ch);
    BalTotals(Work, 2, Pow, Cnt);
    if V > 0.05 + 1e-9 then
      AllFair := False;
    if Changed = 0 then
      AllMoved := False;
    if Cnt[0] <> Cnt[1] then
      AllEven := False;
    if Teams[7] <> C[7].Team then
      KeptFixed := False;
    Key := '';
    for i := 0 to 7 do
      if Teams[i] = Teams[7] then
        Key := Key + 'A'
      else
        Key := Key + 'B';
    if Pos(Key + '|', Keys) = 0 then
    begin
      Inc(Distinct);
      Keys := Keys + Key + '|';
    end;
  end;
  WriteLn(Format('       mix: %d different line-ups in 20 mixes', [Distinct]));
  Check('a mix is always fair (within Target)', AllFair);
  Check('a mix always changes the teams', AllMoved);
  Check('a mix keeps the numbers even', AllEven);
  Check('a player who may not move stays', KeptFixed);
  Check('mixes differ from one another', Distinct >= 3);
  MixSeed := 99;
  for i := 0 to 7 do
    Teams[i] := C[i].Team;
  BalMixTeams(C, 2, Params, 1, 40, 0.05, MixSeed, Teams);
  Key := '';
  for i := 0 to 7 do
    Key := Key + IntToStr(Teams[i]);
  MixSeed := 99;
  for i := 0 to 7 do
    Teams[i] := C[i].Team;
  BalMixTeams(C, 2, Params, 1, 40, 0.05, MixSeed, Teams);
  Line := '';
  for i := 0 to 7 do
    Line := Line + IntToStr(Teams[i]);
  Check('the same seed gives the same mix', Key = Line);

  { ---- nobody pinned: the same teams under the other names are no new mix ---- }
  ResetParams;
  C := Build([0, 0, 0, 0, 1, 1, 1, 1], [1900, 1700, 1500, 1300, 1850, 1650, 1450, 1350], False);
  SetLength(Teams, 8);
  MixSeed := 4242;
  HalfOrLess := True;
  NewMates := True;
  for Round1 := 1 to 40 do
  begin
    for i := 0 to 7 do
      Teams[i] := C[i].Team;
    Changed := BalMixTeams(C, 2, Params, 1, 40, 0.05, MixSeed, Teams);
    if Changed > 4 then
      HalfOrLess := False;
    { the mates of the first player before and after }
    SameMates := True;
    for i := 1 to 7 do
      if (Teams[i] = Teams[0]) <> (C[i].Team = C[0].Team) then
        SameMates := False;
    if SameMates then
      NewMates := False;
  end;
  Check('a mix without pinned players moves at most half of them', HalfOrLess);
  Check('a mix never gives the same teams under the other names', NewMates);

  { ---- predictions, the fit and the history file ---- }
  Seed := 12345;
  SetLength(Recs, 1500);
  for k := 0 to High(Recs) do
  begin
    R.Median := 1500;
    R.Bias := 1;
    SetLength(R.Strength, 8);
    SetLength(R.Team, 8);
    SetLength(R.Weight, 8);
    for i := 0 to 7 do
    begin
      R.Strength[i] := 1500 + (NextRandom - 0.5) * 900;
      R.Team[i] := i mod 2;
      R.Weight[i] := 1;
    end;
    { the true world: a double of power every 200 points }
    R.AlphaWon := NextRandom < BalRecordChance(R, 1.5, 200);
    Recs[k] := R;
    Recs[k].Strength := Copy(R.Strength);
    Recs[k].Team := Copy(R.Team);
    Recs[k].Weight := Copy(R.Weight);
  end;
  BalFit(Recs, Length(Recs), FitSize, FitDouble, FitBrier);
  WriteLn(Format('       fit: SizeImpact %.2f, SkillPerDouble %.0f, Brier %.4f (defaults %.4f)',
    [FitSize, FitDouble, FitBrier, BalBrier(Recs, Length(Recs), 1.5, 400)]));
  Check('the fit finds the steeper power curve', (FitDouble <= 300) and (FitBrier <= BalBrier(Recs, Length(Recs), 1.5, 400)));
  Line := '2026-09-17 12:00:00  ' + BalRecordText(Recs[0]);
  Check('a history line reads back', BalParseRecord(Line, R) and (R.AlphaWon = Recs[0].AlphaWon) and
    (Length(R.Strength) = 8) and Near(R.Strength[3], Recs[0].Strength[3], 0.06) and (R.Team[3] = 1));
  Check('a broken history line is skipped', not BalParseRecord('v1 A 1500 x 0:1500', R) and
    not BalParseRecord('nonsense', R));
  Check('normal quantile', Near(NormalQuantile(0.975), 1.95996, 1e-4) and Near(NormalQuantile(0.5), 0, 1e-9) and
    Near(NormalQuantile(0.01), -2.32635, 1e-4));

  { ---- what the engine thread spends: a mix of a full server, a fit of the whole history ---- }
  Seed := 777;
  SetLength(C, 32);
  SetLength(Teams, 32);
  for i := 0 to 31 do
  begin
    C[i].Id := i + 1;
    C[i].Team := i mod 2;
    C[i].Power := BalPower(1200 + NextRandom * 700, 1500, 400);
    C[i].Cost := 0.01;
    C[i].Counts := True;
    C[i].Movable := True;
    C[i].Soft := 0;
    Teams[i] := C[i].Team;
  end;
  MixSeed := 4711;
  T0 := MicroNow;
  Changed := BalMixTeams(C, 2, Params, 1, 40, 0.05, MixSeed, Teams);
  T0 := MicroNow - T0;
  Work := Copy(C);
  for i := 0 to 31 do
    Work[i].Team := Teams[i];
  V := Imb(Work, 2, Ch);
  BalTotals(Work, 2, Pow, Cnt);
  WriteLn(Format('       mix of 32 players (40 line-ups): %.1f ms, %d change team, imbalance %.3f', [T0 / 1000, Changed, V]));
  Check('a mix of a full server is fair and keeps the numbers', (V <= 0.05 + 1e-9) and (Cnt[0] = Cnt[1]));
  T0 := MicroNow;
  BalFit(Recs, 400, FitSize, FitDouble, FitBrier);
  WriteLn(Format('       fit of a full history (400 matches): %.1f ms', [(MicroNow - T0) / 1000]));

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
