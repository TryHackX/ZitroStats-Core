unit zs_rating;

{ Rating systems.
    ELO        points per kill with the ZitroStats 4 formula; the points !top ranks by.
    MMR        Heroes of the Storm style, one update per rated match; by default the leagues and the
               team balance go by it.
    Glicko-2   Glickman (2012), one rating period per rated match.
    OpenSkill  Weng-Lin Plackett-Luce as implemented by openskill.py, one update per rated match.
  MMR, Glicko-2 and OpenSkill are always kept, separately per mode family (FFA, team, CTF);
  [Ranking] RankingSystem says which of them !topskill and the skill values show (the MMR with elo),
  TierBy what the tiers follow (the points by default). The matches are rated in zs_rules (RateFFA,
  RateTeams). }

{$mode objfpc}{$H+}

interface

uses
  Math, zs_types;

const
  GLICKO_SCALE = 173.7178;

type
  TGlickoOpponent = record
    R, RD: Double;
    Score: Double; { 1 win, 0.5 draw, 0 loss }
  end;
  TGlickoOpponentArray = array of TGlickoOpponent;

  TSkillEntry = record
    Mu, Sigma: Double;
    Team: LongInt;   { index into the team rank array }
    Weight: Double;  { share of the match played for that team; 0 counts as a whole match }
  end;
  TSkillEntryArray = array of TSkillEntry;

function EloKillPoints(KillerPoints, VictimPoints, MaxGive, MinDivider, Divider, PowerDivider,
  MinGive: LongInt): LongInt;

procedure GlickoInit(out S: TGlickoState; R, RD, Vol: Double);
procedure Glicko2Update(var S: TGlickoState; const Opp: array of TGlickoOpponent; Count: LongInt; Tau: Double);
procedure Glicko2Decay(var S: TGlickoState; Periods: LongInt);
function GlickoConservative(const S: TGlickoState; K: Double): Double;
function GlickoExpected(R1, RD1, R2, RD2: Double): Double;

{ ---------------- MMR (Heroes of the Storm style) ---------------- }

procedure MmrInit(out S: TMmrState; R: Double);
{ the chance that a side rated Own beats a side rated Opp }
function MmrExpected(Own, Opp: Double): Double;
{ One finished match. Own and Opp are the average ratings of the two sides, so beating a strong
  line-up moves the rating more than beating a weak one, and a weak player on a strong team gains
  less. The first PlacementGames matches move faster, like the placement matches in HotS. }
procedure MmrUpdate(var S: TMmrState; OwnAvg, OppAvg, Score, K: Double; PlacementGames: LongInt);
{ the change MmrUpdate would make, without making it }
function MmrDelta(const S: TMmrState; OwnAvg, OppAvg, Score, K: Double; PlacementGames: LongInt): Double;

procedure OpenSkillInit(out S: TOpenSkillState; Mu, Sigma: Double);
procedure OpenSkillRate(var Players: array of TSkillEntry; Count: LongInt;
  const TeamRanks: array of LongInt; TeamCount: LongInt; Beta, Kappa, Tau: Double);
function OpenSkillOrdinal(const S: TOpenSkillState): Double;

implementation

{ a number and not infinity; the bit tests never raise, a comparison with a NaN may (Windows) }
function Finite(X: Double): Boolean; inline;
begin
  Result := not IsNan(X) and not IsInfinite(X);
end;

function EloKillPoints(KillerPoints, VictimPoints, MaxGive, MinDivider, Divider, PowerDivider,
  MinGive: LongInt): LongInt;
var
  PowerVal, D, V: Double;
begin
  if PowerDivider <= 0 then
    PowerDivider := 1000;
  if Divider <= 1 then
    Divider := 10;
  PowerVal := EnsureRange((Int64(KillerPoints) - VictimPoints) / PowerDivider, -20.0, 20.0);
  D := MinDivider + Power(Divider, PowerVal);
  { MaxGive is the most a kill pays: with MinimumPointDivider = 0 the divider drops below 1
    against a much stronger victim, and the formula alone would pay up to a million points }
  if D <= 1 then
    V := MaxGive
  else
    V := MaxGive / D;
  Result := Round(V);
  if Result < MinGive then
    Result := MinGive;
end;

{ ---------------- MMR ---------------- }

procedure MmrInit(out S: TMmrState; R: Double);
begin
  if R <= 0 then
    R := 1500;
  S.R := R;
  S.Games := 0;
end;

function MmrExpected(Own, Opp: Double): Double;
begin
  Result := 1 / (1 + Power(10, EnsureRange((Opp - Own) / 400, -8, 8)));
end;

function MmrDelta(const S: TMmrState; OwnAvg, OppAvg, Score, K: Double; PlacementGames: LongInt): Double;
var
  Step: Double;
begin
  Step := K;
  if S.Games < PlacementGames then
    Step := K * 2.5;
  Result := Step * (EnsureRange(Score, 0, 1) - MmrExpected(OwnAvg, OppAvg));
end;

procedure MmrUpdate(var S: TMmrState; OwnAvg, OppAvg, Score, K: Double; PlacementGames: LongInt);
begin
  if IsNan(S.R) or (S.R <= 0) then
    MmrInit(S, 1500);
  S.R := S.R + MmrDelta(S, OwnAvg, OppAvg, Score, K, PlacementGames);
  if S.R < 100 then
    S.R := 100;
  Inc(S.Games);
end;

{ ---------------- Glicko-2 ---------------- }

procedure GlickoInit(out S: TGlickoState; R, RD, Vol: Double);
begin
  S.R := R;
  S.RD := RD;
  S.Vol := Vol;
  S.LastUpdate := 0;
  S.Games := 0;
end;

function GFunc(Phi: Double): Double; inline;
begin
  Result := 1 / Sqrt(1 + 3 * Phi * Phi / (Pi * Pi));
end;

procedure Glicko2Update(var S: TGlickoState; const Opp: array of TGlickoOpponent; Count: LongInt; Tau: Double);
var
  Mu, Phi, Sigma, V, DeltaSum, Delta, G, E, A0, A, B, C, FA, FB, FC, K, PhiStar, NewPhi, NewR: Double;
  i, Iter: LongInt;

  function F(X: Double): Double;
  var
    EX: Double;
  begin
    EX := Exp(X);
    Result := EX * (Delta * Delta - Phi * Phi - V - EX) / (2 * Sqr(Phi * Phi + V + EX)) - (X - A0) / (Tau * Tau);
  end;

begin
  { a broken state starts again from the defaults instead of spreading to every opponent }
  if not Finite(S.R) then
    S.R := 1500;
  if not Finite(S.RD) or (S.RD <= 0) then
    S.RD := 350;
  if not Finite(S.Vol) or (S.Vol <= 0) then
    S.Vol := 0.06;
  if not Finite(Tau) or (Tau <= 0) then
    Tau := 0.5;
  Mu := (S.R - 1500) / GLICKO_SCALE;
  Phi := S.RD / GLICKO_SCALE;
  Sigma := S.Vol;
  if Count <= 0 then
  begin
    S.RD := Min(350, Sqrt(Phi * Phi + Sigma * Sigma) * GLICKO_SCALE);
    Exit;
  end;

  V := 0;
  DeltaSum := 0;
  for i := 0 to Count - 1 do
  begin
    { an opponent with a broken rating says nothing about this one }
    if not Finite(Opp[i].R) or not Finite(Opp[i].RD) or not Finite(Opp[i].Score) then
      Continue;
    G := GFunc(Opp[i].RD / GLICKO_SCALE);
    E := 1 / (1 + Exp(EnsureRange(-G * (Mu - (Opp[i].R - 1500) / GLICKO_SCALE), -700.0, 700.0)));
    V := V + G * G * E * (1 - E);
    DeltaSum := DeltaSum + G * (Opp[i].Score - E);
  end;
  if V < 1e-12 then
    Exit;
  V := 1 / V;
  Delta := V * DeltaSum;

  { new volatility, Illinois variant of regula falsi (step 5 of the paper) }
  A0 := Ln(Sigma * Sigma);
  A := A0;
  if Delta * Delta > Phi * Phi + V then
    B := Ln(Delta * Delta - Phi * Phi - V)
  else
  begin
    K := 1;
    while (F(A0 - K * Tau) < 0) and (K < 100) do
      K := K + 1;
    B := A0 - K * Tau;
  end;
  FA := F(A);
  FB := F(B);
  Iter := 0;
  while (Abs(B - A) > 1e-6) and (Iter < 100) do
  begin
    { a flat stretch has no secant: the bracket found so far is the answer }
    if FB = FA then
      Break;
    C := A + (A - B) * FA / (FB - FA);
    FC := F(C);
    if FC * FB <= 0 then
    begin
      A := B;
      FA := FB;
    end
    else
      FA := FA / 2;
    B := C;
    FB := FC;
    Inc(Iter);
  end;
  Sigma := Exp(A / 2);

  PhiStar := Sqrt(Phi * Phi + Sigma * Sigma);
  NewPhi := 1 / Sqrt(1 / (PhiStar * PhiStar) + 1 / V);
  NewR := GLICKO_SCALE * (Mu + NewPhi * NewPhi * DeltaSum) + 1500;
  { where the floating point unit gives NaN instead of an error (Linux), a degenerate step leaves
    the rating as it was }
  if not Finite(NewR) or not Finite(NewPhi) or not Finite(Sigma) then
    Exit;
  S.R := NewR;
  S.RD := EnsureRange(GLICKO_SCALE * NewPhi, 30, 350);
  S.Vol := EnsureRange(Sigma, 0.001, 1.0);
  Inc(S.Games);
end;

procedure Glicko2Decay(var S: TGlickoState; Periods: LongInt);
var
  Phi, Vol: Double;
begin
  if Periods <= 0 then
    Exit;
  { a broken deviation is as unsure as a new account; a broken volatility grows like the default }
  if not Finite(S.RD) or (S.RD <= 0) then
  begin
    S.RD := 350;
    Exit;
  end;
  Vol := S.Vol;
  if not Finite(Vol) or (Vol <= 0) then
    Vol := 0.06;
  Phi := S.RD / GLICKO_SCALE;
  S.RD := Min(350, Sqrt(Phi * Phi + Periods * Vol * Vol) * GLICKO_SCALE);
end;

function GlickoConservative(const S: TGlickoState; K: Double): Double;
begin
  Result := S.R - K * S.RD;
end;

function GlickoExpected(R1, RD1, R2, RD2: Double): Double;
var
  G: Double;
begin
  G := GFunc(Sqrt(Sqr(RD1 / GLICKO_SCALE) + Sqr(RD2 / GLICKO_SCALE)));
  Result := 1 / (1 + Exp(-G * (R1 - R2) / GLICKO_SCALE));
end;

{ ---------------- OpenSkill Plackett-Luce ---------------- }

procedure OpenSkillInit(out S: TOpenSkillState; Mu, Sigma: Double);
begin
  S.Mu := Mu;
  S.Sigma := Sigma;
  S.Games := 0;
end;

function EntryWeight(const E: TSkillEntry): Double;
begin
  Result := E.Weight;
  if IsNan(Result) or (Result <= 0) or (Result > 1) then
    Result := 1;
end;

{ Partial play: a player counts for a team by the share of the match played for it, and the update
  of that player shrinks by the same share. }
procedure OpenSkillRate(var Players: array of TSkillEntry; Count: LongInt;
  const TeamRanks: array of LongInt; TeamCount: LongInt; Beta, Kappa, Tau: Double);
var
  TeamMu, TeamSigma2, ExpMu, SumQ, Omega, Delta: array of Double;
  RankCount: array of LongInt;
  C, Quot, Ratio, W, Top: Double;
  i, q, j, t: LongInt;
begin
  if (Count <= 0) or (TeamCount < 2) then
    Exit;
  SetLength(TeamMu, TeamCount);
  SetLength(TeamSigma2, TeamCount);
  SetLength(ExpMu, TeamCount);
  SetLength(SumQ, TeamCount);
  SetLength(Omega, TeamCount);
  SetLength(Delta, TeamCount);
  SetLength(RankCount, TeamCount);

  for j := 0 to Count - 1 do
  begin
    W := EntryWeight(Players[j]);
    { additive dynamics: uncertainty grows a little before every game }
    Players[j].Sigma := Sqrt(Sqr(Players[j].Sigma) + W * Tau * Tau);
    t := Players[j].Team;
    if (t < 0) or (t >= TeamCount) then
      Continue;
    TeamMu[t] := TeamMu[t] + W * Players[j].Mu;
    TeamSigma2[t] := TeamSigma2[t] + W * Sqr(Players[j].Sigma);
  end;

  C := 0;
  for i := 0 to TeamCount - 1 do
    C := C + TeamSigma2[i] + Beta * Beta;
  C := Sqrt(C);
  if C <= 0 then
    Exit;
  { only the ratios of these numbers count, so they are taken relative to the largest: the plain
    exponent of a team of many strong players overflows }
  Top := TeamMu[0] / C;
  for i := 1 to TeamCount - 1 do
    Top := Max(Top, TeamMu[i] / C);
  for i := 0 to TeamCount - 1 do
    ExpMu[i] := Exp(TeamMu[i] / C - Top);

  for q := 0 to TeamCount - 1 do
    for i := 0 to TeamCount - 1 do
    begin
      if TeamRanks[i] >= TeamRanks[q] then
        SumQ[q] := SumQ[q] + ExpMu[i];
      if TeamRanks[i] = TeamRanks[q] then
        Inc(RankCount[q]);
    end;

  for i := 0 to TeamCount - 1 do
  begin
    for q := 0 to TeamCount - 1 do
      if (TeamRanks[q] <= TeamRanks[i]) and (SumQ[q] > 0) then
      begin
        Quot := ExpMu[i] / SumQ[q];
        Delta[i] := Delta[i] + Quot * (1 - Quot) / RankCount[q];
        if q = i then
          Omega[i] := Omega[i] + (1 - Quot) / RankCount[q]
        else
          Omega[i] := Omega[i] - Quot / RankCount[q];
      end;
    Omega[i] := Omega[i] * TeamSigma2[i] / C;
    Delta[i] := Delta[i] * TeamSigma2[i] / (C * C) * (Sqrt(TeamSigma2[i]) / C);
  end;

  for j := 0 to Count - 1 do
  begin
    t := Players[j].Team;
    if (t < 0) or (t >= TeamCount) or (TeamSigma2[t] <= 0) then
      Continue;
    W := EntryWeight(Players[j]);
    Ratio := Sqr(Players[j].Sigma) / TeamSigma2[t];
    Players[j].Mu := Players[j].Mu + W * Ratio * Omega[t];
    Players[j].Sigma := Players[j].Sigma * Sqrt(Max(1 - W * Ratio * Delta[t], Kappa));
  end;
end;

function OpenSkillOrdinal(const S: TOpenSkillState): Double;
begin
  Result := S.Mu - 3 * S.Sigma;
end;

end.
