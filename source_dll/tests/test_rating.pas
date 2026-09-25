program test_rating;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, zs_types, zs_rating;

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

function Finite(X: Double): Boolean;
begin
  Result := not IsNan(X) and not IsInfinite(X);
end;

var
  S, S2: TGlickoState;
  Opp: array[0..2] of TGlickoOpponent;
  P: array[0..3] of TSkillEntry;
  Ranks: array[0..3] of LongInt;
  Nan, Gain25, Sigma25: Double;
  M: TMmrState;
begin
  { ZitroStats 4 kill points }
  Check('elo equal points', EloKillPoints(1000, 1000, 45, 1, 10, 1000, 1) = 22);
  Check('elo stronger killer', EloKillPoints(2000, 1000, 45, 1, 10, 1000, 1) = 4);
  Check('elo weaker killer', EloKillPoints(1000, 2000, 45, 1, 10, 1000, 1) = 41);
  Check('elo minimum', EloKillPoints(9000, 0, 45, 1, 10, 1000, 1) = 1);
  Check('elo no overflow with divider 0', EloKillPoints(0, 90000, 45, 0, 10, 1000, 1) > 0);
  { MinimumPointDivider = 0 lets the divider fall below 1: MaxPointGive stays the most a kill pays }
  Check('elo with divider 0 never pays more than MaxPointGive', (EloKillPoints(0, 90000, 45, 0, 10, 1000, 1) = 45) and
    (EloKillPoints(1000, 2000, 45, 0, 10, 1000, 1) = 45) and (EloKillPoints(1000, 1000, 45, 0, 10, 1000, 1) = 45) and
    (EloKillPoints(2000, 1000, 45, 0, 10, 1000, 1) = 4));
  Check('elo far apart at the ends of the range', (EloKillPoints(High(LongInt), Low(LongInt), 45, 1, 10, 1000, 1) = 1) and
    (EloKillPoints(Low(LongInt), High(LongInt), 45, 1, 10, 1000, 1) = 45));

  { Glickman's worked example }
  GlickoInit(S, 1500, 200, 0.06);
  Opp[0].R := 1400; Opp[0].RD := 30; Opp[0].Score := 1;
  Opp[1].R := 1550; Opp[1].RD := 100; Opp[1].Score := 0;
  Opp[2].R := 1700; Opp[2].RD := 300; Opp[2].Score := 0;
  Glicko2Update(S, Opp, 3, 0.5);
  WriteLn(Format('       glicko-2 example: r=%.2f rd=%.2f vol=%.5f', [S.R, S.RD, S.Vol]));
  Check('glicko-2 paper example', Near(S.R, 1464.06, 0.05) and Near(S.RD, 151.52, 0.05) and Near(S.Vol, 0.05999, 0.00001));
  GlickoInit(S, 1500, 60, 0.06);
  Glicko2Decay(S, 30);
  Check('glicko-2 inactivity raises RD', S.RD > 60);
  Check('glicko expected score symmetric', Near(GlickoExpected(1600, 80, 1500, 80) + GlickoExpected(1500, 80, 1600, 80), 1, 1e-9));

  { openskill.py: 1v1 with default ratings and no dynamics }
  P[0].Mu := 25; P[0].Sigma := 25 / 3; P[0].Team := 0;
  P[1].Mu := 25; P[1].Sigma := 25 / 3; P[1].Team := 1;
  Ranks[0] := 0;
  Ranks[1] := 1;
  OpenSkillRate(P, 2, Ranks, 2, 25 / 6, 0.0001, 0);
  WriteLn(Format('       openskill 1v1: winner %.5f/%.5f loser %.5f/%.5f', [P[0].Mu, P[0].Sigma, P[1].Mu, P[1].Sigma]));
  Check('openskill 1v1 winner', Near(P[0].Mu, 27.63523, 0.0001) and Near(P[0].Sigma, 8.06551, 0.0001));
  Check('openskill 1v1 loser', Near(P[1].Mu, 22.36477, 0.0001) and Near(P[1].Sigma, 8.06551, 0.0001));

  P[0].Mu := 25; P[0].Sigma := 25 / 3; P[0].Team := 0;
  P[1].Mu := 25; P[1].Sigma := 25 / 3; P[1].Team := 1;
  Ranks[0] := 0;
  Ranks[1] := 0;
  OpenSkillRate(P, 2, Ranks, 2, 25 / 6, 0.0001, 0);
  Check('openskill draw keeps mu, lowers sigma', Near(P[0].Mu, 25, 1e-9) and Near(P[1].Mu, 25, 1e-9) and (P[0].Sigma < 25 / 3));

  P[0].Mu := 25; P[0].Sigma := 25 / 3; P[0].Team := 0;
  P[1].Mu := 25; P[1].Sigma := 25 / 3; P[1].Team := 0;
  P[2].Mu := 25; P[2].Sigma := 25 / 3; P[2].Team := 1;
  P[3].Mu := 25; P[3].Sigma := 25 / 3; P[3].Team := 1;
  Ranks[0] := 0;
  Ranks[1] := 1;
  OpenSkillRate(P, 4, Ranks, 2, 25 / 6, 0.0001, 25 / 300);
  Check('openskill 2v2 symmetric', Near(P[0].Mu, P[1].Mu, 1e-9) and Near(P[0].Mu - 25, 25 - P[2].Mu, 1e-9) and (P[0].Mu > 25));
  Check('openskill ordinal', Near(25 - 3 * (25 / 3), 0, 1e-9));
  Gain25 := P[0].Mu - 25;
  Sigma25 := P[0].Sigma;

  { very high skill values: the exponent of a team's strength would overflow; the update does not
    depend on where the scale starts }
  P[0].Mu := 10025; P[0].Sigma := 25 / 3; P[0].Team := 0;
  P[1].Mu := 10025; P[1].Sigma := 25 / 3; P[1].Team := 0;
  P[2].Mu := 10025; P[2].Sigma := 25 / 3; P[2].Team := 1;
  P[3].Mu := 10025; P[3].Sigma := 25 / 3; P[3].Team := 1;
  Ranks[0] := 0;
  Ranks[1] := 1;
  OpenSkillRate(P, 4, Ranks, 2, 25 / 6, 0.0001, 25 / 300);
  Check('openskill with a very high mu stays finite and moves as much as at 25',
    Finite(P[0].Mu) and Finite(P[0].Sigma) and Near(P[0].Mu - 10025, Gain25, 1e-6) and
    Near(10025 - P[2].Mu, Gain25, 1e-6) and Near(P[0].Sigma, Sigma25, 1e-9));

  { a broken rating does not spread: a NaN opponent is left out, a NaN state starts again }
  Nan := 0;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Nan := Nan / Nan;
  SetExceptionMask([exDenormalized, exUnderflow, exPrecision]);
  GlickoInit(S, 1500, 200, 0.06);
  GlickoInit(S2, 1500, 200, 0.06);
  Opp[0].R := 1400; Opp[0].RD := 30; Opp[0].Score := 1;
  Opp[1].R := Nan; Opp[1].RD := 100; Opp[1].Score := 0;
  Opp[2].R := 1700; Opp[2].RD := Nan; Opp[2].Score := 0;
  Glicko2Update(S, Opp, 3, 0.5);
  Glicko2Update(S2, Opp, 1, 0.5);
  Check('glicko-2: an opponent with a NaN rating says nothing', Finite(S.R) and Finite(S.RD) and Finite(S.Vol) and
    Near(S.R, S2.R, 1e-9) and Near(S.RD, S2.RD, 1e-9) and (S.Games = 1));
  S.R := Nan;
  S.RD := Nan;
  S.Vol := Nan;
  Glicko2Update(S, Opp, 1, 0.5);
  Check('glicko-2: a NaN state starts again from the defaults', Finite(S.R) and Finite(S.RD) and Finite(S.Vol) and
    (S.R > 1500));
  S.RD := Nan;
  Glicko2Decay(S, 10);
  Check('glicko-2: a NaN deviation decays to the largest one', S.RD = 350);
  GlickoInit(S, 1500, 60, Nan);
  Glicko2Decay(S, 30);
  Check('glicko-2: a NaN volatility decays like the default one', Finite(S.RD) and (S.RD > 60) and (S.RD < 350));
  M.R := Nan;
  M.Games := 3;
  MmrUpdate(M, 1500, 1500, 1, 24, 0);
  Check('mmr: a NaN rating starts again from 1500', Finite(M.R) and Near(M.R, 1512, 1e-9) and (M.Games = 1));

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
