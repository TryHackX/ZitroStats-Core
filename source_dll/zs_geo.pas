unit zs_geo;

{ The map's walls in the library ([Bridges] MapGeometry): the polygons and colliders of the map file
  (maps/<map>.pms), read when a map starts, and rays against them - the same rules the server uses
  for its own rays (polygon types that stop players, bullets, flags or one team only).

  The engine thread owns the map: it loads it in BeginMatch, before any event of the new map, and
  casts every ray of the statistics (Cover (live), Cover (shot)) itself, so nothing waits for the
  script any more and nothing else touches these arrays. The format and the ray tests follow the
  map reader of Basic-Extended (be_map), which was checked against Map.RayCast on the maps of the
  game. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  Classes, SysUtils;

const
  { what a ray asks for: the polygons that stop players, flags, bullets; the colliders too }
  GR_PLAYER = 1;
  GR_FLAG = 2;
  GR_BULLET = 4;
  GR_COLLIDER = 8;

  { MapLoad: the file is not there / not a map / an error while reading }
  GEO_NO_FILE = -1;
  GEO_BAD_FILE = -2;
  GEO_ERROR = -3;

type
  TGeoPoly = record
    X, Y: array[1..3] of Single;
    MinX, MinY, MaxX, MaxY: Single;
    T: Byte;
  end;

  TGeoMap = class
  private
    FPolys: array of TGeoPoly;
    FPolyN: LongInt;
    FSecDiv: LongInt;
    FSecNum: LongInt;
    FSecSide: LongInt;
    FSecStart, FSecLen: array of LongInt;
    FSecPolys: array of Word;
    FStamp: array of LongWord;
    FStampNow: LongWord;
    FColX, FColY, FColR: array of Single;
    FColN: LongInt;
    FLoaded: Boolean;
    FName: AnsiString;
    FRays: Int64;
    procedure NextStamp;
    function PointIn(PX, PY: Single; w: LongInt): Boolean;
    function LineIn(AX, AY, BX, BY: Single; w: LongInt): Boolean;
    function SegTouchesBox(AX, AY, BX, BY: Single; w: LongInt): Boolean;
  public
    { Path: the map file; its name is matched without regard to case (maps copied from Windows to a
      Linux server keep their spelling). The polygons on success, else GEO_*. }
    function Load(const Path: AnsiString): LongInt;
    procedure Clear;
    { True when the segment hits a polygon of a kind Flags names (Team: the team of the one asking,
      1..4, for the polygons of one team; 0 = none of those stops it), or a collider with
      GR_COLLIDER. False when no map is loaded. }
    function Ray(AX, AY, BX, BY: Single; Flags, Team: LongInt): Boolean;
    function PointSolid(X, Y: Single; Flags, Team: LongInt): Boolean;
    function ColliderHit(AX, AY, BX, BY: Single): Boolean;
    property Loaded: Boolean read FLoaded;
    property Polys: LongInt read FPolyN;
    property Colliders: LongInt read FColN;
    property Name: AnsiString read FName;
    { the rays cast since the map was loaded (shown by /zs_perf) }
    property RaysCast: Int64 read FRays;
  end;

{ the file of a map in Folder (with its trailing delimiter): <Folder><Map>.pms, any case }
function GeoMapFile(const Folder, Map: AnsiString): AnsiString;

implementation

const
  MAX_POLYS = 5000;
  MAX_SECTOR = 25;
  COORD_LIMIT = 1000000;
  PT_ONLY_BULLETS = 1;
  PT_ONLY_PLAYER = 2;
  PT_DOESNT = 3;
  PT_RED_BULLETS = 10;
  PT_RED_PLAYER = 11;
  PT_BLUE_BULLETS = 12;
  PT_BLUE_PLAYER = 13;
  PT_YELLOW_BULLETS = 14;
  PT_YELLOW_PLAYER = 15;
  PT_GREEN_BULLETS = 16;
  PT_GREEN_PLAYER = 17;
  PT_ONLY_FLAGGERS = 21;
  PT_NOT_FLAGGERS = 22;
  PT_NON_FLAGGER_COLLIDES = 23;
  PT_BACKGROUND = 24;
  PT_BACKGROUND_TRANSITION = 25;

type
  TReader = record
    D: array of Byte;
    P: LongInt;
    Bad: Boolean;
  end;

function FMin(A, B: Single): Single; inline;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

function FMax(A, B: Single): Single; inline;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

procedure Take(var R: TReader; Dest: Pointer; N: LongInt);
begin
  if R.Bad or (R.P + N > Length(R.D)) then
  begin
    R.Bad := True;
    FillChar(Dest^, N, 0);
    Exit;
  end;
  Move(R.D[R.P], Dest^, N);
  Inc(R.P, N);
end;

procedure Skip(var R: TReader; N: LongInt);
begin
  if R.Bad or (R.P + N > Length(R.D)) then
    R.Bad := True
  else
    Inc(R.P, N);
end;

function TakeInt(var R: TReader): LongInt;
begin
  Result := 0;
  Take(R, @Result, 4);
end;

function TakeWord(var R: TReader): Word;
begin
  Result := 0;
  Take(R, @Result, 2);
end;

function TakeByte(var R: TReader): Byte;
begin
  Result := 0;
  Take(R, @Result, 1);
end;

function TakeSingle(var R: TReader): Single;
begin
  Result := 0;
  Take(R, @Result, 4);
end;

function FindFileAnyCase(const Path: AnsiString): AnsiString;
var
  Dir, Name: AnsiString;
  SR: TSearchRec;
begin
  Result := '';
  if Path = '' then
    Exit;
  if FileExists(Path) then
  begin
    Result := Path;
    Exit;
  end;
  Dir := ExtractFilePath(Path);
  Name := ExtractFileName(Path);
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
        if CompareText(SR.Name, Name) = 0 then
        begin
          Result := Dir + SR.Name;
          Break;
        end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function GeoMapFile(const Folder, Map: AnsiString): AnsiString;
begin
  Result := '';
  if (Map = '') or (Pos('/', Map) > 0) or (Pos('\', Map) > 0) or (Pos('..', Map) > 0) then
    Exit;
  Result := FindFileAnyCase(Folder + Map + '.pms');
end;

procedure TGeoMap.Clear;
begin
  FLoaded := False;
  FName := '';
  FPolyN := 0;
  FSecDiv := 0;
  FSecNum := 0;
  FSecSide := 0;
  SetLength(FPolys, 0);
  SetLength(FSecStart, 0);
  SetLength(FSecLen, 0);
  SetLength(FSecPolys, 0);
  SetLength(FStamp, 0);
  SetLength(FColX, 0);
  SetLength(FColY, 0);
  SetLength(FColR, 0);
  FColN := 0;
  FRays := 0;
end;

function TGeoMap.Load(const Path: AnsiString): LongInt;
var
  R: TReader;
  FS: TFileStream;
  FileName: AnsiString;
  n, i, j, k, m, Cells, Total: LongInt;
begin
  Clear;
  Result := GEO_NO_FILE;
  FileName := FindFileAnyCase(Path);
  if FileName = '' then
    Exit;
  R.P := 0;
  R.Bad := False;
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(R.D, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(R.D[0], FS.Size);
    finally
      FS.Free;
    end;
  except
    Result := GEO_ERROR;
    Exit;
  end;
  Result := GEO_BAD_FILE;
  { the header: version, description (1 + 38), texture (1 + 24), colours and the rest (20) }
  TakeInt(R);
  Skip(R, 1 + 38);
  Skip(R, 1 + 24);
  Skip(R, 20);
  n := TakeInt(R);
  if R.Bad or (n < 0) or (n > MAX_POLYS) then
    Exit;
  SetLength(FPolys, n + 1);
  for i := 1 to n do
  begin
    for j := 1 to 3 do
    begin
      FPolys[i].X[j] := TakeSingle(R);
      FPolys[i].Y[j] := TakeSingle(R);
      Skip(R, 20);
    end;
    Skip(R, 36);
    FPolys[i].T := TakeByte(R);
    FPolys[i].MinX := FMin(FPolys[i].X[1], FMin(FPolys[i].X[2], FPolys[i].X[3]));
    FPolys[i].MaxX := FMax(FPolys[i].X[1], FMax(FPolys[i].X[2], FPolys[i].X[3]));
    FPolys[i].MinY := FMin(FPolys[i].Y[1], FMin(FPolys[i].Y[2], FPolys[i].Y[3]));
    FPolys[i].MaxY := FMax(FPolys[i].Y[1], FMax(FPolys[i].Y[2], FPolys[i].Y[3]));
  end;
  FSecDiv := TakeInt(R);
  FSecNum := TakeInt(R);
  if R.Bad or (FSecNum < 0) or (FSecNum > MAX_SECTOR) or (FSecDiv <= 0) then
    Exit;
  FSecSide := 2 * FSecNum + 1;
  Cells := FSecSide * FSecSide;
  SetLength(FSecStart, Cells);
  SetLength(FSecLen, Cells);
  SetLength(FSecPolys, 1024);
  Total := 0;
  for k := 0 to Cells - 1 do
  begin
    m := TakeWord(R);
    if R.Bad or (m > MAX_POLYS) then
      Exit;
    FSecStart[k] := Total;
    FSecLen[k] := m;
    if Total + m > Length(FSecPolys) then
      SetLength(FSecPolys, (Total + m) * 2);
    for j := 0 to m - 1 do
      FSecPolys[Total + j] := TakeWord(R);
    if R.Bad then
      Exit;
    Inc(Total, m);
  end;
  SetLength(FSecPolys, Total);
  SetLength(FStamp, n + 1);
  for i := 0 to n do
    FStamp[i] := 0;
  FStampNow := 0;
  FPolyN := n;
  FLoaded := True;
  FName := ChangeFileExt(ExtractFileName(FileName), '');
  Result := n;
  { the scenery (44 bytes each) and the props (55), then the colliders: active, 3 bytes, x, y, radius;
    a frag grenade explodes on a collider at radius / 1.7, the size the server tests them with }
  m := TakeInt(R);
  if R.Bad or (m < 0) or (m > 500) then
    Exit;
  Skip(R, m * 44);
  m := TakeInt(R);
  if R.Bad or (m < 0) or (m > 500) then
    Exit;
  Skip(R, m * 55);
  m := TakeInt(R);
  if R.Bad or (m < 0) or (m > 128) then
    Exit;
  SetLength(FColX, m);
  SetLength(FColY, m);
  SetLength(FColR, m);
  k := 0;
  for i := 0 to m - 1 do
  begin
    j := TakeByte(R);
    Skip(R, 3);
    FColX[k] := TakeSingle(R);
    FColY[k] := TakeSingle(R);
    FColR[k] := TakeSingle(R) / 1.7;
    if R.Bad then
      Break;
    if (j <> 0) and (FColR[k] > 0) then
      Inc(k);
  end;
  FColN := k;
end;

function TGeoMap.ColliderHit(AX, AY, BX, BY: Single): Boolean;
var
  i: LongInt;
  DX, DY, L2, T, PX, PY: Single;
begin
  Result := False;
  DX := BX - AX;
  DY := BY - AY;
  L2 := DX * DX + DY * DY;
  for i := 0 to FColN - 1 do
  begin
    if L2 > 0.0001 then
    begin
      T := ((FColX[i] - AX) * DX + (FColY[i] - AY) * DY) / L2;
      if T < 0 then
        T := 0
      else if T > 1 then
        T := 1;
    end
    else
      T := 0;
    PX := AX + DX * T - FColX[i];
    PY := AY + DY * T - FColY[i];
    if PX * PX + PY * PY <= FColR[i] * FColR[i] then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

{ does a polygon of type T stop what Flags asks about (for a member of Team) }
function Blocks(T: Byte; Flags, Team: LongInt): Boolean;
var
  NP, NB, Fl: Boolean;
begin
  NP := (Flags and GR_PLAYER) = 0;
  NB := (Flags and GR_BULLET) = 0;
  Fl := (Flags and GR_FLAG) <> 0;
  Result := True;
  case T of
    PT_RED_BULLETS: Result := (Team = 1) and not NB;
    PT_RED_PLAYER: Result := (Team = 1) and not NP;
    PT_BLUE_BULLETS: Result := (Team = 2) and not NB;
    PT_BLUE_PLAYER: Result := (Team = 2) and not NP;
    PT_YELLOW_BULLETS: Result := (Team = 3) and not NB;
    PT_YELLOW_PLAYER: Result := (Team = 3) and not NP;
    PT_GREEN_BULLETS: Result := (Team = 4) and not NB;
    PT_GREEN_PLAYER: Result := (Team = 4) and not NP;
    PT_ONLY_FLAGGERS: Result := Fl and not NP;
    PT_NOT_FLAGGERS: Result := not (Fl or NP);
    PT_NON_FLAGGER_COLLIDES: Result := Fl and not NP and not NB;
    PT_ONLY_BULLETS: Result := not NB;
    PT_ONLY_PLAYER: Result := not NP;
    PT_DOESNT, PT_BACKGROUND, PT_BACKGROUND_TRANSITION: Result := False;
  end;
end;

function TGeoMap.PointIn(PX, PY: Single; w: LongInt): Boolean;
var
  APX, APY: Single;
  PAB, PAC: Boolean;
begin
  Result := False;
  with FPolys[w] do
  begin
    APX := PX - X[1];
    APY := PY - Y[1];
    PAB := (X[2] - X[1]) * APY - (Y[2] - Y[1]) * APX > 0;
    PAC := (X[3] - X[1]) * APY - (Y[3] - Y[1]) * APX > 0;
    if PAC = PAB then
      Exit;
    if ((X[3] - X[2]) * (PY - Y[2]) - (Y[3] - Y[2]) * (PX - X[2]) > 0) <> PAB then
      Exit;
  end;
  Result := True;
end;

function TGeoMap.LineIn(AX, AY, BX, BY: Single; w: LongInt): Boolean;
var
  i, j: LongInt;
  PX, PY, QX, QY, AK, AM, BK, BM, VX, VY: Single;
begin
  Result := False;
  for i := 1 to 3 do
  begin
    if i = 3 then
      j := 1
    else
      j := i + 1;
    PX := FPolys[w].X[i];
    PY := FPolys[w].Y[i];
    QX := FPolys[w].X[j];
    QY := FPolys[w].Y[j];
    if (BX <> AX) or (QX <> PX) then
    begin
      if BX = AX then
      begin
        BK := (QY - PY) / (QX - PX);
        BM := PY - BK * PX;
        VX := AX;
        VY := BK * VX + BM;
        if (VX > FMin(PX, QX)) and (VX < FMax(PX, QX)) and (VY > FMin(AY, BY)) and (VY < FMax(AY, BY)) then
        begin
          Result := True;
          Exit;
        end;
      end
      else if QX = PX then
      begin
        AK := (BY - AY) / (BX - AX);
        AM := AY - AK * AX;
        VX := PX;
        VY := AK * VX + AM;
        if (VY > FMin(PY, QY)) and (VY < FMax(PY, QY)) and (VX > FMin(AX, BX)) and (VX < FMax(AX, BX)) then
        begin
          Result := True;
          Exit;
        end;
      end
      else
      begin
        AK := (BY - AY) / (BX - AX);
        BK := (QY - PY) / (QX - PX);
        if AK <> BK then
        begin
          AM := AY - AK * AX;
          BM := PY - BK * PX;
          VX := (BM - AM) / (AK - BK);
          VY := AK * VX + AM;
          if (VX > FMin(PX, QX)) and (VX < FMax(PX, QX)) and (VX > FMin(AX, BX)) and (VX < FMax(AX, BX)) then
          begin
            Result := True;
            Exit;
          end;
        end;
      end;
    end;
  end;
end;

function TGeoMap.SegTouchesBox(AX, AY, BX, BY: Single; w: LongInt): Boolean;
var
  T0, T1, DX, DY, P, Q, R: Single;
  k: LongInt;
begin
  Result := False;
  T0 := 0;
  T1 := 1;
  DX := BX - AX;
  DY := BY - AY;
  for k := 0 to 3 do
  begin
    case k of
      0:
        begin
          P := -DX;
          Q := AX - (FPolys[w].MinX - 0.5);
        end;
      1:
        begin
          P := DX;
          Q := (FPolys[w].MaxX + 0.5) - AX;
        end;
      2:
        begin
          P := -DY;
          Q := AY - (FPolys[w].MinY - 0.5);
        end;
    else
      begin
        P := DY;
        Q := (FPolys[w].MaxY + 0.5) - AY;
      end;
    end;
    if P = 0 then
    begin
      if Q < 0 then
        Exit;
    end
    else
    begin
      R := Q / P;
      if P < 0 then
      begin
        if R > T1 then
          Exit;
        if R > T0 then
          T0 := R;
      end
      else
      begin
        if R < T0 then
          Exit;
        if R < T1 then
          T1 := R;
      end;
    end;
  end;
  Result := True;
end;

function Sane(V: Single): Boolean; inline;
begin
  Result := (V = V) and (V > -COORD_LIMIT) and (V < COORD_LIMIT);
end;

procedure TGeoMap.NextStamp;
var
  i: LongInt;
begin
  Inc(FStampNow);
  if FStampNow = 0 then
  begin
    for i := 0 to High(FStamp) do
      FStamp[i] := 0;
    FStampNow := 1;
  end;
end;

function TGeoMap.Ray(AX, AY, BX, BY: Single; Flags, Team: LongInt): Boolean;
var
  i, j, X0, Y0, X1, Y1, c, p, w: LongInt;
begin
  Result := False;
  if not FLoaded then
    Exit;
  if not (Sane(AX) and Sane(AY) and Sane(BX) and Sane(BY)) then
    Exit;
  Inc(FRays);
  X0 := Round(FMin(AX, BX) / FSecDiv);
  Y0 := Round(FMin(AY, BY) / FSecDiv);
  X1 := Round(FMax(AX, BX) / FSecDiv);
  Y1 := Round(FMax(AY, BY) / FSecDiv);
  if not ((X0 > FSecNum) or (X1 < -FSecNum) or (Y0 > FSecNum) or (Y1 < -FSecNum)) then
  begin
    if X0 < -FSecNum then
      X0 := -FSecNum;
    if Y0 < -FSecNum then
      Y0 := -FSecNum;
    if X1 > FSecNum then
      X1 := FSecNum;
    if Y1 > FSecNum then
      Y1 := FSecNum;
    NextStamp;
    for i := X0 to X1 do
      for j := Y0 to Y1 do
      begin
        c := (i + FSecNum) * FSecSide + (j + FSecNum);
        for p := FSecStart[c] to FSecStart[c] + FSecLen[c] - 1 do
        begin
          w := FSecPolys[p];
          if (w < 1) or (w > FPolyN) then
            Continue;
          if FStamp[w] = FStampNow then
            Continue;
          FStamp[w] := FStampNow;
          if not Blocks(FPolys[w].T, Flags, Team) then
            Continue;
          if not SegTouchesBox(AX, AY, BX, BY, w) then
            Continue;
          if PointIn(AX, AY, w) or LineIn(AX, AY, BX, BY, w) then
          begin
            Result := True;
            Exit;
          end;
        end;
      end;
  end;
  if (Flags and GR_COLLIDER) <> 0 then
    if FColN > 0 then
      Result := ColliderHit(AX, AY, BX, BY);
end;

function TGeoMap.PointSolid(X, Y: Single; Flags, Team: LongInt): Boolean;
var
  c, p, w, i, j: LongInt;
begin
  Result := False;
  if not FLoaded then
    Exit;
  if not (Sane(X) and Sane(Y)) then
    Exit;
  i := Round(X / FSecDiv);
  j := Round(Y / FSecDiv);
  if (i < -FSecNum) or (i > FSecNum) or (j < -FSecNum) or (j > FSecNum) then
    Exit;
  c := (i + FSecNum) * FSecSide + (j + FSecNum);
  for p := FSecStart[c] to FSecStart[c] + FSecLen[c] - 1 do
  begin
    w := FSecPolys[p];
    if (w < 1) or (w > FPolyN) then
      Continue;
    if not Blocks(FPolys[w].T, Flags, Team) then
      Continue;
    if (X < FPolys[w].MinX) or (X > FPolys[w].MaxX) or (Y < FPolys[w].MinY) or (Y > FPolys[w].MaxY) then
      Continue;
    if PointIn(X, Y, w) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

end.
