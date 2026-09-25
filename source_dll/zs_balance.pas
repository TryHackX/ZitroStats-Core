unit zs_balance;

{ Team balance: how strong a team is and which change of players makes a match even.

  Every player has a strength on the MMR scale. A player's power doubles for every SkillPerDouble
  points above the median of the server, a team's power is the sum of its players' powers, and the
  chance of a team is its power raised to SizeImpact against the other teams, with the side
  advantage of the map as a factor. The number of players therefore counts by itself: five average
  players against four have 58% with SizeImpact 1.5.

  The imbalance of a match is the largest distance of a team's chance from an even share, scaled so
  that 0.10 always means 60:40 between two teams (and 30% against 25% among four). Moves and swaps
  are judged by the imbalance they leave behind plus what they cost the players who change team.

  Nothing here knows the engine: the functions take plain arrays, so the tests can check them and
  the engine only has to say who plays where and how strong they are. }

{$mode objfpc}{$H+}

interface

uses
  Math;

const
  BAL_MAX_TEAMS = 4;

  BM_NONE = 0;
  BM_MOVE = 1;
  BM_SWAP = 2;

  { a swap moves two players, so it has to be clearly better than a single move }
  BAL_SWAP_PENALTY = 0.01;

type
  TBalTeamValues = array[0..BAL_MAX_TEAMS - 1] of Double;
  TBalTeamCounts = array[0..BAL_MAX_TEAMS - 1] of LongInt;

  TBalParams = record
    SizeImpact: Double;
    Bias: TBalTeamValues;         { factor on each team's power ^ SizeImpact; 1 = no side advantage }
  end;

  TBalCand = record
    Id: LongInt;                  { the caller's key, the player slot }
    Team: LongInt;                { team index 0..TeamCount-1 }
    Power: Double;                { what the player adds to the team }
    Movable: Boolean;
    Cost: Double;                 { imbalance points a change of this player costs }
    Counts: Boolean;              { counts for the player numbers (bots may not) }
    Soft: Double;                 { extra cost when only a protection that gives way to uneven
                                    numbers keeps the player; -1 = never moved }
  end;
  TBalCandArray = array of TBalCand;

  TBalMove = record
    Kind: LongInt;                { BM_NONE, BM_MOVE, BM_SWAP }
    A, B: LongInt;                { candidate indexes; B only for a swap }
    ToTeam: LongInt;              { team index A moves to (a swap sends A to B's team) }
    Before, After: Double;        { imbalance before and after }
    Score: Double;
  end;

  { one finished match of two teams, kept to measure and tune the predictions }
  TBalRecord = record
    Median: Double;
    Bias: Double;                 { side factor of Alpha that was used }
    AlphaWon: Boolean;
    Strength: array of Double;
    Team: array of LongInt;       { 0 = Alpha, 1 = Bravo }
    Weight: array of Double;      { share of the match the player spent on that team }
  end;
  TBalRecordArray = array of TBalRecord;

function BalPower(Strength, Median, SkillPerDouble: Double): Double;
procedure BalChances(const Powers: TBalTeamValues; TeamCount: LongInt; const P: TBalParams; out Chances: TBalTeamValues);
function BalImbalance(const Chances: TBalTeamValues; TeamCount: LongInt): Double;
function BalFavored(const Chances: TBalTeamValues; TeamCount: LongInt): LongInt;
function BalSpread(const Counts: TBalTeamCounts; TeamCount: LongInt): LongInt;
procedure BalTotals(const Cands: TBalCandArray; TeamCount: LongInt; out Powers: TBalTeamValues; out Counts: TBalTeamCounts);
function BalMatchImbalance(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  out Chances: TBalTeamValues): Double;

{ The best single move or swap. CountFix: the teams differ by more than MaxSpread players and only a
  move from a largest to a smallest team counts, whatever it does to the chances. Otherwise a change
  has to lower the imbalance by MinGain (or leave it below Target), may not hand the advantage to
  another team beyond Target and may not leave the teams more than MaxSpread players apart. }
function BalBestChange(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread: LongInt; Target, MinGain: Double; CountFix, AllowSwaps: Boolean; out Move: TBalMove): Boolean;

{ The count fix when BalBestChange finds no free player to move: a player with Soft >= 0 may go as
  well, at Soft on top of the cost, so the cheapest protection gives way first. Soft < 0 never moves. }
function BalBestCountFix(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread: LongInt; out Move: TBalMove): Boolean;

{ The team a !switch of Cands[Me] goes to: of the teams in Allowed, the one with the smallest
  imbalance that keeps the numbers within MaxSpread or brings them closer; -1 when there is none.
  D1 and Spread1 are the imbalance and the spread after the switch. }
function BalBestSwitch(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams; Me: LongInt;
  const Allowed: array of Boolean; MaxSpread: LongInt; out D1: Double; out Spread1: LongInt): LongInt;

{ A switch helps when the chances even out by half of MinGain, when they get within Target from
  above it, or when the numbers get closer without making the chances worse than allowed. }
function BalSwitchHelpful(D0, D1: Double; Spread0, Spread1: LongInt; Target, MinGain: Double): Boolean;

{ The team a joining player with JoinPower should take: the smallest imbalance among the teams that
  keep the numbers within MaxSpread (or, if none does, the smallest team). After[t] is the imbalance
  with the player in team t, 9 for a team that would break the spread. Ties go to fewer players,
  then to Prefer when it is one of them. }
function BalBestJoin(const Powers: TBalTeamValues; const Counts: TBalTeamCounts; TeamCount: LongInt;
  const P: TBalParams; JoinPower: Double; JoinCounts: Boolean; MaxSpread, Prefer: LongInt;
  out After: TBalTeamValues): LongInt;

{ Rearranges the movable players for the smallest imbalance. Teams[i] is the team of Cands[i] on
  entry and the new team on exit. ChangeCost is added for every player away from the team they had,
  so with a cost most players stay; Fresh starts from a snake draft by power instead (a new split).
  Returns the number of players whose team changed. }
function BalRearrange(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread: LongInt; ChangeCost: Double; Fresh: Boolean; var Teams: array of LongInt): LongInt;

{ New teams for /mix and MapStart = mix. Tries line-ups dealt at random (and the draft by
  strength), evens each one out the way BalRearrange does, and picks one at random among those
  close to the fairest found - within 4 points of imbalance, and never beyond Target unless no
  line-up gets there. So every mix is fair, and two mixes in a row give different teams. The
  same teams under other names are one line-up: of its names, the ones that move the fewest
  players are used, so a mix never sends everybody across to play with the same mates.
  Teams[i] is the team of Cands[i] on entry and the new team on exit; Seed drives the chance
  (the tests give a fixed one). Returns how many players change team. }
function BalMixTeams(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread, Tries: LongInt; Target: Double; var Seed: LongWord; var Teams: array of LongInt): LongInt;

{ the chance of Alpha in a recorded match with the given settings }
function BalRecordChance(const R: TBalRecord; SizeImpact, SkillPerDouble: Double): Double;
{ mean squared error of the predictions, 0.25 is a coin flip }
function BalBrier(const Recs: TBalRecordArray; Count: LongInt; SizeImpact, SkillPerDouble: Double): Double;
{ the settings from a small grid that predicted the recorded matches best }
procedure BalFit(const Recs: TBalRecordArray; Count: LongInt; out SizeImpact, SkillPerDouble, Brier: Double);
{ a record as one line of teambalance-history.log and back }
function BalRecordText(const R: TBalRecord): AnsiString;
function BalParseRecord(const Line: AnsiString; out R: TBalRecord): Boolean;

{ inverse of the standard normal distribution (Acklam), used to put points on the MMR scale }
function NormalQuantile(P: Double): Double;

implementation

uses
  SysUtils;

function BalPower(Strength, Median, SkillPerDouble: Double): Double;
begin
  if SkillPerDouble <= 0 then
    SkillPerDouble := 400;
  Result := Power(2, EnsureRange((Strength - Median) / SkillPerDouble, -8.0, 8.0));
end;

procedure BalChances(const Powers: TBalTeamValues; TeamCount: LongInt; const P: TBalParams; out Chances: TBalTeamValues);
var
  G: TBalTeamValues;
  Sum, K: Double;
  t: LongInt;
begin
  K := P.SizeImpact;
  if K <= 0 then
    K := 1.5;
  Sum := 0;
  for t := 0 to BAL_MAX_TEAMS - 1 do
  begin
    G[t] := 0;
    Chances[t] := 0;
  end;
  for t := 0 to TeamCount - 1 do
  begin
    if Powers[t] > 0 then
      G[t] := Max(0.0, P.Bias[t]) * Power(Powers[t], K);
    Sum := Sum + G[t];
  end;
  for t := 0 to TeamCount - 1 do
    if Sum > 0 then
      Chances[t] := G[t] / Sum
    else
      Chances[t] := 1 / Max(1, TeamCount);
end;

function BalImbalance(const Chances: TBalTeamValues; TeamCount: LongInt): Double;
var
  t: LongInt;
  Even: Double;
begin
  Result := 0;
  if TeamCount < 2 then
    Exit;
  Even := 1 / TeamCount;
  for t := 0 to TeamCount - 1 do
    Result := Max(Result, Abs(Chances[t] - Even));
  Result := Result * TeamCount / 2;
end;

function BalFavored(const Chances: TBalTeamValues; TeamCount: LongInt): LongInt;
var
  t: LongInt;
begin
  Result := 0;
  for t := 1 to TeamCount - 1 do
    if Chances[t] > Chances[Result] then
      Result := t;
end;

function BalSpread(const Counts: TBalTeamCounts; TeamCount: LongInt): LongInt;
var
  t, Lo, Hi: LongInt;
begin
  Lo := MaxInt;
  Hi := 0;
  for t := 0 to TeamCount - 1 do
  begin
    Lo := Min(Lo, Counts[t]);
    Hi := Max(Hi, Counts[t]);
  end;
  if Lo = MaxInt then
    Result := 0
  else
    Result := Hi - Lo;
end;

procedure BalTotals(const Cands: TBalCandArray; TeamCount: LongInt; out Powers: TBalTeamValues; out Counts: TBalTeamCounts);
var
  i, t: LongInt;
begin
  for t := 0 to BAL_MAX_TEAMS - 1 do
  begin
    Powers[t] := 0;
    Counts[t] := 0;
  end;
  for i := 0 to High(Cands) do
  begin
    t := Cands[i].Team;
    if (t < 0) or (t >= TeamCount) then
      Continue;
    Powers[t] := Powers[t] + Cands[i].Power;
    if Cands[i].Counts then
      Inc(Counts[t]);
  end;
end;

function BalMatchImbalance(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  out Chances: TBalTeamValues): Double;
var
  Pow: TBalTeamValues;
  Cnt: TBalTeamCounts;
begin
  BalTotals(Cands, TeamCount, Pow, Cnt);
  BalChances(Pow, TeamCount, P, Chances);
  Result := BalImbalance(Chances, TeamCount);
end;

function BalBestChange(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread: LongInt; Target, MinGain: Double; CountFix, AllowSwaps: Boolean; out Move: TBalMove): Boolean;
var
  Pow, Pow2, Ch: TBalTeamValues;
  Cnt, Cnt2: TBalTeamCounts;
  D0, D1, Score: Double;
  Fav0, Fav1, Spread0, Spread1, i, j, t, a, b, Lo, Hi: LongInt;

  function Acceptable: Boolean;
  begin
    if CountFix then
      Result := Spread1 < Spread0
    else
      Result := (Spread1 <= Max(MaxSpread, 0)) and
        ((D1 <= D0 - MinGain) or ((D1 <= Target) and (D1 < D0 - 1e-9))) and
        not ((Fav1 <> Fav0) and (D1 > Target));
  end;

  procedure Take(Kind, IA, IB, ToTeam: LongInt; Cost: Double);
  begin
    Score := D1 + Cost;
    if (Move.Kind = BM_NONE) or (Score < Move.Score - 1e-12) then
    begin
      Move.Kind := Kind;
      Move.A := IA;
      Move.B := IB;
      Move.ToTeam := ToTeam;
      Move.After := D1;
      Move.Score := Score;
    end;
  end;

begin
  Move.Kind := BM_NONE;
  Move.A := -1;
  Move.B := -1;
  Move.ToTeam := -1;
  Move.Score := 0;
  Move.After := 0;
  Result := False;
  if TeamCount < 2 then
    Exit;
  BalTotals(Cands, TeamCount, Pow, Cnt);
  BalChances(Pow, TeamCount, P, Ch);
  D0 := BalImbalance(Ch, TeamCount);
  Fav0 := BalFavored(Ch, TeamCount);
  Spread0 := BalSpread(Cnt, TeamCount);
  Move.Before := D0;
  Lo := MaxInt;
  Hi := 0;
  for t := 0 to TeamCount - 1 do
  begin
    Lo := Min(Lo, Cnt[t]);
    Hi := Max(Hi, Cnt[t]);
  end;

  for i := 0 to High(Cands) do
  begin
    if not Cands[i].Movable then
      Continue;
    a := Cands[i].Team;
    if (a < 0) or (a >= TeamCount) then
      Continue;
    for t := 0 to TeamCount - 1 do
    begin
      if t = a then
        Continue;
      if CountFix and ((Cnt[a] <> Hi) or (Cnt[t] <> Lo)) then
        Continue;
      Pow2 := Pow;
      Cnt2 := Cnt;
      Pow2[a] := Max(0.0, Pow2[a] - Cands[i].Power);
      Pow2[t] := Pow2[t] + Cands[i].Power;
      if Cands[i].Counts then
      begin
        Dec(Cnt2[a]);
        Inc(Cnt2[t]);
      end;
      BalChances(Pow2, TeamCount, P, Ch);
      D1 := BalImbalance(Ch, TeamCount);
      Fav1 := BalFavored(Ch, TeamCount);
      Spread1 := BalSpread(Cnt2, TeamCount);
      if Acceptable then
        Take(BM_MOVE, i, -1, t, Cands[i].Cost);
    end;
  end;

  if AllowSwaps and not CountFix then
    for i := 0 to High(Cands) do
    begin
      if not Cands[i].Movable then
        Continue;
      a := Cands[i].Team;
      if (a < 0) or (a >= TeamCount) then
        Continue;
      for j := i + 1 to High(Cands) do
      begin
        b := Cands[j].Team;
        if not Cands[j].Movable or (b = a) or (b < 0) or (b >= TeamCount) then
          Continue;
        Pow2 := Pow;
        Cnt2 := Cnt;
        Pow2[a] := Max(0.0, Pow2[a] - Cands[i].Power + Cands[j].Power);
        Pow2[b] := Max(0.0, Pow2[b] - Cands[j].Power + Cands[i].Power);
        if Cands[i].Counts <> Cands[j].Counts then
        begin
          if Cands[i].Counts then
          begin
            Dec(Cnt2[a]);
            Inc(Cnt2[b]);
          end
          else
          begin
            Inc(Cnt2[a]);
            Dec(Cnt2[b]);
          end;
        end;
        BalChances(Pow2, TeamCount, P, Ch);
        D1 := BalImbalance(Ch, TeamCount);
        Fav1 := BalFavored(Ch, TeamCount);
        Spread1 := BalSpread(Cnt2, TeamCount);
        if Acceptable then
          Take(BM_SWAP, i, j, b, Cands[i].Cost + Cands[j].Cost + BAL_SWAP_PENALTY);
      end;
    end;
  Result := Move.Kind <> BM_NONE;
end;

function BalBestCountFix(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread: LongInt; out Move: TBalMove): Boolean;
var
  Work: TBalCandArray;
  i: LongInt;
begin
  Work := Copy(Cands);
  for i := 0 to High(Work) do
  begin
    Work[i].Movable := Work[i].Soft >= 0;
    if Work[i].Movable then
      Work[i].Cost := Work[i].Cost + Work[i].Soft;
  end;
  Result := BalBestChange(Work, TeamCount, P, MaxSpread, 0, 0, True, False, Move);
end;

function BalBestSwitch(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams; Me: LongInt;
  const Allowed: array of Boolean; MaxSpread: LongInt; out D1: Double; out Spread1: LongInt): LongInt;
var
  Work: TBalCandArray;
  Pow, Ch: TBalTeamValues;
  Cnt: TBalTeamCounts;
  t, Spread0, S1: LongInt;
  D: Double;
begin
  Result := -1;
  D1 := 9;
  BalTotals(Cands, TeamCount, Pow, Cnt);
  Spread0 := BalSpread(Cnt, TeamCount);
  Spread1 := Spread0;
  if (Me < 0) or (Me > High(Cands)) then
    Exit;
  Work := Copy(Cands);
  for t := 0 to TeamCount - 1 do
  begin
    if (t = Cands[Me].Team) or (t > High(Allowed)) or not Allowed[t] then
      Continue;
    Work[Me].Team := t;
    BalTotals(Work, TeamCount, Pow, Cnt);
    S1 := BalSpread(Cnt, TeamCount);
    D := BalMatchImbalance(Work, TeamCount, P, Ch);
    if ((S1 <= MaxSpread) or (S1 < Spread0)) and (D < D1) then
    begin
      D1 := D;
      Spread1 := S1;
      Result := t;
    end;
  end;
end;

function BalSwitchHelpful(D0, D1: Double; Spread0, Spread1: LongInt; Target, MinGain: Double): Boolean;
begin
  Result := (D1 <= D0 - MinGain / 2) or ((D0 > Target) and (D1 <= Target) and (D1 < D0 - 1e-9)) or
    ((Spread1 < Spread0) and (D1 <= Max(D0, Target) + 1e-9));
end;

function BalBestJoin(const Powers: TBalTeamValues; const Counts: TBalTeamCounts; TeamCount: LongInt;
  const P: TBalParams; JoinPower: Double; JoinCounts: Boolean; MaxSpread, Prefer: LongInt;
  out After: TBalTeamValues): LongInt;
var
  Pow2, Ch: TBalTeamValues;
  Cnt2: TBalTeamCounts;
  t, Lo: LongInt;
  Allowed: array[0..BAL_MAX_TEAMS - 1] of Boolean;
  Any: Boolean;

  function Better(A, B: LongInt): Boolean;
  begin
    if Abs(After[A] - After[B]) > 1e-9 then
      Exit(After[A] < After[B]);
    if Counts[A] <> Counts[B] then
      Exit(Counts[A] < Counts[B]);
    Result := (A = Prefer) and (B <> Prefer);
  end;

begin
  Result := 0;
  for t := 0 to BAL_MAX_TEAMS - 1 do
  begin
    After[t] := 9;
    Allowed[t] := False;
  end;
  if TeamCount < 1 then
    Exit;
  Lo := MaxInt;
  for t := 0 to TeamCount - 1 do
    Lo := Min(Lo, Counts[t]);
  Any := False;
  for t := 0 to TeamCount - 1 do
  begin
    Pow2 := Powers;
    Cnt2 := Counts;
    Pow2[t] := Pow2[t] + JoinPower;
    if JoinCounts then
      Inc(Cnt2[t]);
    BalChances(Pow2, TeamCount, P, Ch);
    After[t] := BalImbalance(Ch, TeamCount);
    Allowed[t] := BalSpread(Cnt2, TeamCount) <= Max(MaxSpread, 0);
    Any := Any or Allowed[t];
  end;
  { when every team breaks the spread, only the smallest teams are left to choose from }
  if not Any then
    for t := 0 to TeamCount - 1 do
      Allowed[t] := Counts[t] = Lo;
  Result := -1;
  for t := 0 to TeamCount - 1 do
  begin
    if not Allowed[t] then
    begin
      After[t] := 9;
      Continue;
    end;
    if (Result < 0) or Better(t, Result) then
      Result := t;
  end;
  if Result < 0 then
    Result := 0;
end;

function BalRearrange(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread: LongInt; ChangeCost: Double; Fresh: Boolean; var Teams: array of LongInt): LongInt;
const
  MAX_STEPS = 64;
var
  Orig, Order: array of LongInt;
  Work: TBalCandArray;
  i, j, k, t, n, Step, BestI, BestJ, BestT, Tmp: LongInt;
  Obj, BestObj, V: Double;
  Pow, Ch: TBalTeamValues;
  Cnt: TBalTeamCounts;
  Changed: Boolean;

  function Objective: Double;
  var
    m, Moved: LongInt;
  begin
    BalTotals(Work, TeamCount, Pow, Cnt);
    BalChances(Pow, TeamCount, P, Ch);
    Moved := 0;
    for m := 0 to n - 1 do
      if Work[m].Team <> Orig[m] then
        Inc(Moved);
    Result := BalImbalance(Ch, TeamCount) + ChangeCost * Moved;
    { numbers beyond the limit are never a good split }
    if BalSpread(Cnt, TeamCount) > Max(MaxSpread, 0) then
      Result := Result + 10 * BalSpread(Cnt, TeamCount);
  end;

begin
  Result := 0;
  n := Length(Cands);
  if (n = 0) or (TeamCount < 2) then
    Exit;
  SetLength(Work, n);
  SetLength(Orig, n);
  for i := 0 to n - 1 do
  begin
    Work[i] := Cands[i];
    Work[i].Team := Teams[i];
    Orig[i] := Teams[i];
  end;

  if Fresh then
  begin
    { snake draft by power: A B B A A B ... among the movable players, the others stay }
    SetLength(Order, 0);
    for i := 0 to n - 1 do
      if Work[i].Movable then
      begin
        SetLength(Order, Length(Order) + 1);
        Order[High(Order)] := i;
      end;
    for i := 1 to High(Order) do
    begin
      Tmp := Order[i];
      j := i - 1;
      while (j >= 0) and (Work[Order[j]].Power < Work[Tmp].Power) do
      begin
        Order[j + 1] := Order[j];
        Dec(j);
      end;
      Order[j + 1] := Tmp;
    end;
    for k := 0 to High(Order) do
    begin
      t := k mod (2 * TeamCount);
      if t >= TeamCount then
        t := 2 * TeamCount - 1 - t;
      Work[Order[k]].Team := t;
    end;
  end;

  Obj := Objective;
  for Step := 1 to MAX_STEPS do
  begin
    BestObj := Obj;
    BestI := -1;
    BestJ := -1;
    BestT := -1;
    for i := 0 to n - 1 do
    begin
      if not Work[i].Movable then
        Continue;
      Tmp := Work[i].Team;
      for t := 0 to TeamCount - 1 do
      begin
        if t = Tmp then
          Continue;
        Work[i].Team := t;
        V := Objective;
        if V < BestObj - 1e-9 then
        begin
          BestObj := V;
          BestI := i;
          BestJ := -1;
          BestT := t;
        end;
      end;
      Work[i].Team := Tmp;
      for j := i + 1 to n - 1 do
      begin
        if not Work[j].Movable or (Work[j].Team = Work[i].Team) then
          Continue;
        Work[i].Team := Work[j].Team;
        Work[j].Team := Tmp;
        V := Objective;
        if V < BestObj - 1e-9 then
        begin
          BestObj := V;
          BestI := i;
          BestJ := j;
          BestT := -1;
        end;
        Work[j].Team := Work[i].Team;
        Work[i].Team := Tmp;
      end;
    end;
    if BestI < 0 then
      Break;
    if BestJ >= 0 then
    begin
      Tmp := Work[BestI].Team;
      Work[BestI].Team := Work[BestJ].Team;
      Work[BestJ].Team := Tmp;
    end
    else
      Work[BestI].Team := BestT;
    Obj := BestObj;
  end;

  for i := 0 to n - 1 do
  begin
    Changed := Work[i].Team <> Teams[i];
    Teams[i] := Work[i].Team;
    if Changed then
      Inc(Result);
  end;
end;

function BalNextRandom(var Seed: LongWord): LongWord;
begin
  { xorshift32: plenty for dealing teams, and repeatable in the tests }
  if Seed = 0 then
    Seed := $9E3779B9;
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed;
end;

type
  { an order of the team names: team t of a line-up is called Perm[t] }
  TBalPerm = array[0..BAL_MAX_TEAMS - 1] of LongInt;
  TBalPermArray = array of TBalPerm;

{ every order of TeamCount names (2, 6 or 24) }
procedure BalLabelOrders(TeamCount: LongInt; out Perms: TBalPermArray);
var
  Code, Total, t, x, c: LongInt;
  Perm: TBalPerm;
  Used: array[0..BAL_MAX_TEAMS - 1] of Boolean;
  Ok: Boolean;
begin
  Perms := nil;
  Total := 1;
  for t := 1 to TeamCount do
    Total := Total * TeamCount;
  for Code := 0 to Total - 1 do
  begin
    for t := 0 to BAL_MAX_TEAMS - 1 do
    begin
      Used[t] := False;
      Perm[t] := t;
    end;
    c := Code;
    Ok := True;
    for t := 0 to TeamCount - 1 do
    begin
      x := c mod TeamCount;
      c := c div TeamCount;
      if Used[x] then
        Ok := False;
      Used[x] := True;
      Perm[t] := x;
    end;
    if Ok then
    begin
      SetLength(Perms, Length(Perms) + 1);
      Perms[High(Perms)] := Perm;
    end;
  end;
end;

function BalRelabel(const Perm: TBalPerm; TeamCount, Team: LongInt): LongInt;
begin
  if (Team >= 0) and (Team < TeamCount) then
    Result := Perm[Team]
  else
    Result := Team;
end;

function BalMixTeams(const Cands: TBalCandArray; TeamCount: LongInt; const P: TBalParams;
  MaxSpread, Tries: LongInt; Target: Double; var Seed: LongWord; var Teams: array of LongInt): LongInt;
var
  n, Q, i, j, t, k, Tmp, Pick, Eligible, Lowest, Use: LongInt;
  Lines: array of array of LongInt;
  Score: array of Double;
  Moved: array of LongInt;
  Order: array of LongInt;
  Perms: TBalPermArray;
  PScore: array of array of Double;
  PMoved: array of array of LongInt;
  Work: TBalCandArray;
  Cnt: TBalTeamCounts;
  Pow, Ch: TBalTeamValues;
  BestD, Limit: Double;
  AnyMoved, Fits, Found: Boolean;
begin
  Result := 0;
  n := Length(Cands);
  if (n = 0) or (TeamCount < 2) or (TeamCount > BAL_MAX_TEAMS) then
    Exit;
  if Tries < 1 then
    Tries := 1;
  BalLabelOrders(TeamCount, Perms);
  Lines := nil;
  Score := nil;
  Moved := nil;
  PScore := nil;
  PMoved := nil;
  SetLength(Lines, Tries + 1);
  SetLength(Score, Tries + 1);
  SetLength(Moved, Tries + 1);
  SetLength(PScore, Tries + 1, Length(Perms));
  SetLength(PMoved, Tries + 1, Length(Perms));
  for Q := 0 to Tries do
  begin
    SetLength(Lines[Q], n);
    for i := 0 to n - 1 do
      Lines[Q][i] := Teams[i];
    if Q = 0 then
      { the draft by strength, the fairest start that is known }
      BalRearrange(Cands, TeamCount, P, MaxSpread, 0, True, Lines[Q])
    else
    begin
      { deal the movable players in a random order, each to a team with the fewest players so far }
      Order := nil;
      for i := 0 to n - 1 do
        if Cands[i].Movable then
        begin
          SetLength(Order, Length(Order) + 1);
          Order[High(Order)] := i;
        end;
      for i := High(Order) downto 1 do
      begin
        j := BalNextRandom(Seed) mod LongWord(i + 1);
        Tmp := Order[i];
        Order[i] := Order[j];
        Order[j] := Tmp;
      end;
      for t := 0 to BAL_MAX_TEAMS - 1 do
        Cnt[t] := 0;
      for i := 0 to n - 1 do
        if not Cands[i].Movable and Cands[i].Counts and (Teams[i] >= 0) and (Teams[i] < TeamCount) then
          Inc(Cnt[Teams[i]]);
      for i := 0 to High(Order) do
      begin
        Lowest := MaxInt;
        for t := 0 to TeamCount - 1 do
          if Cnt[t] < Lowest then
            Lowest := Cnt[t];
        { a random team among the smallest ones }
        repeat
          t := BalNextRandom(Seed) mod LongWord(TeamCount);
        until Cnt[t] = Lowest;
        Lines[Q][Order[i]] := t;
        if Cands[Order[i]].Counts then
          Inc(Cnt[t]);
      end;
      BalRearrange(Cands, TeamCount, P, MaxSpread, 0, False, Lines[Q]);
    end;
    { the same teams under every order of the names that keeps the players who may not move
      where they are; a team bias (the map, the score) can make the names matter }
    for k := 0 to High(Perms) do
    begin
      PScore[Q][k] := -1;
      PMoved[Q][k] := MaxInt;
      Fits := True;
      for i := 0 to n - 1 do
        if not Cands[i].Movable and (BalRelabel(Perms[k], TeamCount, Lines[Q][i]) <> Teams[i]) then
          Fits := False;
      if not Fits then
        Continue;
      Work := Copy(Cands);
      for i := 0 to n - 1 do
        Work[i].Team := BalRelabel(Perms[k], TeamCount, Lines[Q][i]);
      PScore[Q][k] := BalMatchImbalance(Work, TeamCount, P, Ch);
      BalTotals(Work, TeamCount, Pow, Cnt);
      if BalSpread(Cnt, TeamCount) > Max(MaxSpread, 0) then
        PScore[Q][k] := PScore[Q][k] + 10;
      PMoved[Q][k] := 0;
      for i := 0 to n - 1 do
        if Work[i].Team <> Teams[i] then
          Inc(PMoved[Q][k]);
    end;
  end;

  Found := False;
  BestD := 0;
  for Q := 0 to Tries do
    for k := 0 to High(Perms) do
      if (PScore[Q][k] >= 0) and (not Found or (PScore[Q][k] < BestD)) then
      begin
        BestD := PScore[Q][k];
        Found := True;
      end;
  if not Found then
    Exit;
  { within 4 points of imbalance of the fairest line-up, and never beyond Target unless no
    line-up gets there }
  if BestD <= Target then
    Limit := Min(Target, BestD + 0.04)
  else
    Limit := BestD + 0.01;
  { each line-up under the names that move the fewest players and keep it within the limit }
  for Q := 0 to Tries do
  begin
    Score[Q] := 1e9;
    Moved[Q] := MaxInt;
    Use := -1;
    for k := 0 to High(Perms) do
      if (PScore[Q][k] >= 0) and (PScore[Q][k] <= Limit + 1e-9) then
        if (Use < 0) or (PMoved[Q][k] < PMoved[Q][Use]) or
           ((PMoved[Q][k] = PMoved[Q][Use]) and (PScore[Q][k] < PScore[Q][Use])) then
          Use := k;
    if Use >= 0 then
    begin
      Score[Q] := PScore[Q][Use];
      Moved[Q] := PMoved[Q][Use];
      for i := 0 to n - 1 do
        Lines[Q][i] := BalRelabel(Perms[Use], TeamCount, Lines[Q][i]);
    end;
  end;
  { a line-up that changes something is preferred; the current one only when nothing else is fair }
  AnyMoved := False;
  for Q := 0 to Tries do
    if (Score[Q] <= Limit + 1e-9) and (Moved[Q] > 0) then
      AnyMoved := True;
  Eligible := 0;
  for Q := 0 to Tries do
    if (Score[Q] <= Limit + 1e-9) and ((Moved[Q] > 0) or not AnyMoved) then
      Inc(Eligible);
  Pick := BalNextRandom(Seed) mod LongWord(Max(1, Eligible));
  for Q := 0 to Tries do
    if (Score[Q] <= Limit + 1e-9) and ((Moved[Q] > 0) or not AnyMoved) then
    begin
      if Pick = 0 then
      begin
        for i := 0 to n - 1 do
          Teams[i] := Lines[Q][i];
        Result := Moved[Q];
        Exit;
      end;
      Dec(Pick);
    end;
end;

{ ---------------- measuring the predictions ---------------- }

function BalRecordChance(const R: TBalRecord; SizeImpact, SkillPerDouble: Double): Double;
var
  Pow, Ch: TBalTeamValues;
  P: TBalParams;
  i: LongInt;
begin
  Pow[0] := 0;
  Pow[1] := 0;
  Pow[2] := 0;
  Pow[3] := 0;
  for i := 0 to High(R.Strength) do
    if (R.Team[i] = 0) or (R.Team[i] = 1) then
      Pow[R.Team[i]] := Pow[R.Team[i]] + R.Weight[i] * BalPower(R.Strength[i], R.Median, SkillPerDouble);
  P.SizeImpact := SizeImpact;
  P.Bias[0] := R.Bias;
  P.Bias[1] := 1;
  P.Bias[2] := 1;
  P.Bias[3] := 1;
  BalChances(Pow, 2, P, Ch);
  Result := Ch[0];
end;

function BalBrier(const Recs: TBalRecordArray; Count: LongInt; SizeImpact, SkillPerDouble: Double): Double;
var
  k: LongInt;
  C, O: Double;
begin
  Result := 0.25;
  if Count <= 0 then
    Exit;
  Result := 0;
  for k := 0 to Count - 1 do
  begin
    C := BalRecordChance(Recs[k], SizeImpact, SkillPerDouble);
    if Recs[k].AlphaWon then
      O := 1
    else
      O := 0;
    Result := Result + Sqr(C - O);
  end;
  Result := Result / Count;
end;

procedure BalFit(const Recs: TBalRecordArray; Count: LongInt; out SizeImpact, SkillPerDouble, Brier: Double);
const
  SIZES: array[0..6] of Double = (1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0);
  DOUBLES: array[0..6] of Double = (200, 300, 400, 500, 600, 800, 1000);
var
  i, j: LongInt;
  B: Double;
begin
  SizeImpact := 1.5;
  SkillPerDouble := 400;
  Brier := BalBrier(Recs, Count, SizeImpact, SkillPerDouble);
  for i := 0 to High(SIZES) do
    for j := 0 to High(DOUBLES) do
    begin
      B := BalBrier(Recs, Count, SIZES[i], DOUBLES[j]);
      if B < Brier - 1e-12 then
      begin
        Brier := B;
        SizeImpact := SIZES[i];
        SkillPerDouble := DOUBLES[j];
      end;
    end;
end;

function Num(V: Double; Decimals: LongInt): AnsiString;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FloatToStrF(V, ffFixed, 15, Decimals, FS);
end;

function ParseNum(const S: AnsiString; out V: Double): Boolean;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := TryStrToFloat(S, V, FS) and not IsNan(V) and not IsInfinite(V);
end;

function BalRecordText(const R: TBalRecord): AnsiString;
var
  i: LongInt;
begin
  if R.AlphaWon then
    Result := 'v1 A '
  else
    Result := 'v1 B ';
  Result := Result + Num(R.Median, 1) + ' ' + Num(R.Bias, 4);
  for i := 0 to High(R.Strength) do
    Result := Result + ' ' + IntToStr(R.Team[i]) + ':' + Num(R.Strength[i], 1) + ':' + Num(R.Weight[i], 3);
end;

function BalParseRecord(const Line: AnsiString; out R: TBalRecord): Boolean;
var
  Parts: array of AnsiString;
  S, Item: AnsiString;
  p, k, n, c1, c2: LongInt;
  V, W: Double;
  T: LongInt;
begin
  Result := False;
  R.Strength := nil;
  R.Team := nil;
  R.Weight := nil;
  S := Trim(Line);
  { log lines start with the date and time }
  p := Pos('v1 ', S);
  if p = 0 then
    Exit;
  S := Copy(S, p, MaxInt);
  Parts := nil;
  while S <> '' do
  begin
    p := Pos(' ', S);
    if p = 0 then
      p := Length(S) + 1;
    Item := Copy(S, 1, p - 1);
    Delete(S, 1, p);
    S := TrimLeft(S);
    if Item <> '' then
    begin
      SetLength(Parts, Length(Parts) + 1);
      Parts[High(Parts)] := Item;
    end;
  end;
  if (Length(Parts) < 6) or (Parts[0] <> 'v1') then
    Exit;
  R.AlphaWon := Parts[1] = 'A';
  if not (R.AlphaWon or (Parts[1] = 'B')) then
    Exit;
  if not ParseNum(Parts[2], R.Median) or not ParseNum(Parts[3], R.Bias) then
    Exit;
  { a broken line must not poison the fit: a side factor is always between 0.1 and 10 }
  R.Bias := EnsureRange(R.Bias, 0.1, 10);
  n := 0;
  for k := 4 to High(Parts) do
  begin
    Item := Parts[k];
    c1 := Pos(':', Item);
    if c1 = 0 then
      Exit;
    c2 := Pos(':', Copy(Item, c1 + 1, MaxInt));
    if c2 = 0 then
      Exit;
    c2 := c1 + c2;
    T := StrToIntDef(Copy(Item, 1, c1 - 1), -1);
    if (T < 0) or (T > 1) then
      Exit;
    if not ParseNum(Copy(Item, c1 + 1, c2 - c1 - 1), V) or not ParseNum(Copy(Item, c2 + 1, MaxInt), W) then
      Exit;
    SetLength(R.Strength, n + 1);
    SetLength(R.Team, n + 1);
    SetLength(R.Weight, n + 1);
    R.Strength[n] := V;
    R.Team[n] := T;
    R.Weight[n] := EnsureRange(W, 0.0, 1.0);
    Inc(n);
  end;
  Result := n >= 2;
end;

function NormalQuantile(P: Double): Double;
const
  A: array[1..6] of Double = (-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
    1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00);
  B: array[1..5] of Double = (-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
    6.680131188771972e+01, -1.328068155288572e+01);
  C: array[1..6] of Double = (-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
    -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00);
  D: array[1..4] of Double = (7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
    3.754408661907416e+00);
  PLOW = 0.02425;
var
  Q, R: Double;
begin
  P := EnsureRange(P, 1e-9, 1 - 1e-9);
  if P < PLOW then
  begin
    Q := Sqrt(-2 * Ln(P));
    Result := (((((C[1] * Q + C[2]) * Q + C[3]) * Q + C[4]) * Q + C[5]) * Q + C[6]) /
      ((((D[1] * Q + D[2]) * Q + D[3]) * Q + D[4]) * Q + 1);
  end
  else if P <= 1 - PLOW then
  begin
    Q := P - 0.5;
    R := Q * Q;
    Result := (((((A[1] * R + A[2]) * R + A[3]) * R + A[4]) * R + A[5]) * R + A[6]) * Q /
      (((((B[1] * R + B[2]) * R + B[3]) * R + B[4]) * R + B[5]) * R + 1);
  end
  else
  begin
    Q := Sqrt(-2 * Ln(1 - P));
    Result := -(((((C[1] * Q + C[2]) * Q + C[3]) * Q + C[4]) * Q + C[5]) * Q + C[6]) /
      ((((D[1] * Q + D[2]) * Q + D[3]) * Q + D[4]) * Q + 1);
  end;
end;

end.
