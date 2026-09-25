unit zs_rank;

{ Always-current ranking: profile indices kept sorted by a 64-bit key, highest first.
  A key change moves one entry past the neighbours it overtakes, so a kill costs a binary
  search and a short memmove instead of a re-sort of every account. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

type
  TRankList = class
  private
    FOrder: array of LongInt;
    FCount: LongInt;
    FPos: array of LongInt;
    FKey: array of Int64;
    procedure EnsureIndex(Index: LongInt);
    function KeyAt(Position: LongInt): Int64; inline;
    procedure SortRange(L, R: LongInt);
  public
    procedure Clear;
    procedure Build(const Keys: array of Int64; const Included: array of Boolean; Count: LongInt);
    procedure Update(Index: LongInt; NewKey: Int64);
    procedure Remove(Index: LongInt);
    function Contains(Index: LongInt): Boolean;
    function RankOf(Index: LongInt): LongInt;
    function At(Rank: LongInt): LongInt;
    function KeyOf(Index: LongInt): Int64;
    property Count: LongInt read FCount;
  end;

function PointsKey(Points, Id: LongInt): Int64;
function RatingKey(Rating: Double; Id: LongInt): Int64;

implementation

uses
  Math;

function PointsKey(Points, Id: LongInt): Int64;
begin
  { equal points: the older account (lower id) ranks higher }
  Result := Int64(Points) * 4294967296 + (High(LongInt) - Int64(Id));
end;

function RatingKey(Rating: Double; Id: LongInt): Int64;
begin
  { a broken rating (NaN) ranks last: Round would raise on it (Windows) or give any number }
  if IsNan(Rating) then
    Rating := -1e7
  else if Rating > 1e7 then
    Rating := 1e7
  else if Rating < -1e7 then
    Rating := -1e7;
  Result := Round(Rating * 100) * 4294967296 + (High(LongInt) - Int64(Id));
end;

procedure TRankList.Clear;
begin
  FOrder := nil;
  FPos := nil;
  FKey := nil;
  FCount := 0;
end;

procedure TRankList.EnsureIndex(Index: LongInt);
var
  OldLen, NewLen, i: LongInt;
begin
  OldLen := Length(FPos);
  if Index < OldLen then
    Exit;
  NewLen := OldLen * 2;
  if NewLen <= Index then
    NewLen := Index + 1024;
  SetLength(FPos, NewLen);
  SetLength(FKey, NewLen);
  for i := OldLen to NewLen - 1 do
    FPos[i] := -1;
end;

function TRankList.KeyAt(Position: LongInt): Int64;
begin
  Result := FKey[FOrder[Position]];
end;

procedure TRankList.SortRange(L, R: LongInt);
var
  i, j, T: LongInt;
  Pivot: Int64;
begin
  while R - L > 16 do
  begin
    Pivot := FKey[FOrder[(L + R) shr 1]];
    i := L;
    j := R;
    repeat
      while FKey[FOrder[i]] > Pivot do
        Inc(i);
      while FKey[FOrder[j]] < Pivot do
        Dec(j);
      if i <= j then
      begin
        T := FOrder[i];
        FOrder[i] := FOrder[j];
        FOrder[j] := T;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    { recurse into the smaller part to keep the stack shallow }
    if j - L < R - i then
    begin
      SortRange(L, j);
      L := i;
    end
    else
    begin
      SortRange(i, R);
      R := j;
    end;
  end;
  for i := L + 1 to R do
  begin
    T := FOrder[i];
    Pivot := FKey[T];
    j := i - 1;
    while (j >= L) and (FKey[FOrder[j]] < Pivot) do
    begin
      FOrder[j + 1] := FOrder[j];
      Dec(j);
    end;
    FOrder[j + 1] := T;
  end;
end;

procedure TRankList.Build(const Keys: array of Int64; const Included: array of Boolean; Count: LongInt);
var
  i, n: LongInt;
begin
  Clear;
  if Count <= 0 then
    Exit;
  EnsureIndex(Count - 1);
  SetLength(FOrder, Count + 1024);
  n := 0;
  for i := 0 to Count - 1 do
  begin
    FKey[i] := Keys[i];
    if Included[i] then
    begin
      FOrder[n] := i;
      Inc(n);
    end;
  end;
  FCount := n;
  if n > 1 then
    SortRange(0, n - 1);
  for i := 0 to n - 1 do
    FPos[FOrder[i]] := i;
end;

procedure TRankList.Update(Index: LongInt; NewKey: Int64);
var
  P0, P1, Lo, Hi, Mid, q: LongInt;
begin
  if Index < 0 then
    Exit;
  EnsureIndex(Index);
  P0 := FPos[Index];

  if P0 < 0 then
  begin
    { insert before the first entry with a lower key }
    Lo := 0;
    Hi := FCount;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) shr 1;
      if KeyAt(Mid) < NewKey then
        Hi := Mid
      else
        Lo := Mid + 1;
    end;
    if FCount >= Length(FOrder) then
      SetLength(FOrder, Length(FOrder) * 2 + 1024);
    if Lo < FCount then
      Move(FOrder[Lo], FOrder[Lo + 1], (FCount - Lo) * SizeOf(LongInt));
    FOrder[Lo] := Index;
    FKey[Index] := NewKey;
    Inc(FCount);
    for q := Lo to FCount - 1 do
      FPos[FOrder[q]] := q;
    Exit;
  end;

  if NewKey = FKey[Index] then
    Exit;
  if NewKey > FKey[Index] then
  begin
    { moving up: first position above P0 whose key is lower than the new key }
    Lo := 0;
    Hi := P0;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) shr 1;
      if KeyAt(Mid) < NewKey then
        Hi := Mid
      else
        Lo := Mid + 1;
    end;
    P1 := Lo;
    if P1 < P0 then
    begin
      Move(FOrder[P1], FOrder[P1 + 1], (P0 - P1) * SizeOf(LongInt));
      for q := P1 + 1 to P0 do
        FPos[FOrder[q]] := q;
      FOrder[P1] := Index;
      FPos[Index] := P1;
    end;
  end
  else
  begin
    { moving down: last position below P0 whose key is still higher than the new key }
    Lo := P0;
    Hi := FCount - 1;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi + 1) shr 1;
      if KeyAt(Mid) > NewKey then
        Lo := Mid
      else
        Hi := Mid - 1;
    end;
    P1 := Lo;
    if P1 > P0 then
    begin
      Move(FOrder[P0 + 1], FOrder[P0], (P1 - P0) * SizeOf(LongInt));
      for q := P0 to P1 - 1 do
        FPos[FOrder[q]] := q;
      FOrder[P1] := Index;
      FPos[Index] := P1;
    end;
  end;
  FKey[Index] := NewKey;
end;

procedure TRankList.Remove(Index: LongInt);
var
  P, q: LongInt;
begin
  if (Index < 0) or (Index >= Length(FPos)) then
    Exit;
  P := FPos[Index];
  if P < 0 then
    Exit;
  if P < FCount - 1 then
    Move(FOrder[P + 1], FOrder[P], (FCount - 1 - P) * SizeOf(LongInt));
  Dec(FCount);
  for q := P to FCount - 1 do
    FPos[FOrder[q]] := q;
  FPos[Index] := -1;
end;

function TRankList.Contains(Index: LongInt): Boolean;
begin
  Result := (Index >= 0) and (Index < Length(FPos)) and (FPos[Index] >= 0);
end;

function TRankList.RankOf(Index: LongInt): LongInt;
begin
  if Contains(Index) then
    Result := FPos[Index] + 1
  else
    Result := 0;
end;

function TRankList.At(Rank: LongInt): LongInt;
begin
  if (Rank >= 1) and (Rank <= FCount) then
    Result := FOrder[Rank - 1]
  else
    Result := -1;
end;

function TRankList.KeyOf(Index: LongInt): Int64;
begin
  if (Index >= 0) and (Index < Length(FKey)) then
    Result := FKey[Index]
  else
    Result := 0;
end;

end.
