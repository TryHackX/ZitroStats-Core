program test_rank;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, zs_util, zs_rank;

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
  R: TRankList;
  Points: array of LongInt;
  Keys: array of Int64;
  Incl: array of Boolean;

function Verify(N: LongInt): Boolean;
var
  i, j, Better, Members: LongInt;
begin
  Result := False;
  Members := 0;
  for i := 0 to N - 1 do
  begin
    if not Incl[i] then
    begin
      if R.Contains(i) then
        Exit;
      Continue;
    end;
    Inc(Members);
    Better := 0;
    for j := 0 to N - 1 do
      if Incl[j] and (Keys[j] > Keys[i]) then
        Inc(Better);
    if (R.RankOf(i) <> Better + 1) or (R.At(Better + 1) <> i) then
      Exit;
  end;
  Result := Members = R.Count;
end;

var
  N, i, k, Step: LongInt;
  Ok: Boolean;
  T0: Int64;
  Nan: Double;
begin
  RandSeed := 777;
  N := 3000;
  SetLength(Points, N);
  SetLength(Keys, N);
  SetLength(Incl, N);
  for i := 0 to N - 1 do
  begin
    Points[i] := 900 + Random(300);
    Keys[i] := PointsKey(Points[i], i + 1);
    Incl[i] := Random(10) <> 0;
  end;
  R := TRankList.Create;
  R.Build(Keys, Incl, N);
  Check('build matches brute force', Verify(N));

  Ok := True;
  for Step := 1 to 30000 do
  begin
    i := Random(N);
    k := Random(20);
    if k = 0 then
    begin
      Incl[i] := False;
      R.Remove(i);
    end
    else
    begin
      Points[i] := Points[i] + Random(91) - 45;
      Keys[i] := PointsKey(Points[i], i + 1);
      Incl[i] := True;
      R.Update(i, Keys[i]);
    end;
    if (Step mod 3000 = 0) and not Verify(N) then
    begin
      Ok := False;
      WriteLn('       mismatch after step ', Step);
      Break;
    end;
  end;
  Check('30000 random updates, inserts and removals', Ok);

  Check('equal points: lower id first', PointsKey(1000, 5) > PointsKey(1000, 6));
  Check('points dominate id', PointsKey(1001, 900000) > PointsKey(1000, 1));
  Check('negative points order', PointsKey(-5, 1) < PointsKey(0, 2));
  Check('rating keys', RatingKey(25.37, 3) > RatingKey(25.36, 1));
  Check('unknown index', (R.RankOf(-1) = 0) and (R.RankOf(10 * N) = 0) and (R.At(0) = -1) and (R.At(N + 1) = -1));
  { a broken rating ranks last instead of raising (Round of a NaN) or landing anywhere }
  Nan := 0;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Nan := Nan / Nan;
  SetExceptionMask([exDenormalized, exUnderflow, exPrecision]);
  Check('a NaN rating ranks below every real one', (RatingKey(Nan, 1) < RatingKey(-9999999, 2)) and
    (RatingKey(Nan, 1) = RatingKey(-1e9, 1)) and (RatingKey(Infinity, 1) = RatingKey(1e9, 1)));

  N := 60000;
  SetLength(Points, N);
  SetLength(Keys, N);
  SetLength(Incl, N);
  for i := 0 to N - 1 do
  begin
    Points[i] := 1000 + Round((Random - Random) * 400);
    Keys[i] := PointsKey(Points[i], i + 1);
    Incl[i] := True;
  end;
  T0 := MicroNow;
  R.Build(Keys, Incl, N);
  WriteLn('       build 60000: ', (MicroNow - T0) div 1000, ' ms');
  T0 := MicroNow;
  for Step := 1 to 200000 do
  begin
    i := Random(N);
    Points[i] := Points[i] + Random(91) - 45;
    R.Update(i, PointsKey(Points[i], i + 1));
  end;
  WriteLn('       200000 updates on 60000 accounts: ', (MicroNow - T0) div 1000, ' ms');
  R.Free;

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
