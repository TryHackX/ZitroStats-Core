program test_geo;

{ zs_geo: a map file made here with known polygons and colliders, read back and cast rays at;
  every polygon type that matters (normal, only bullets, only players, no collision, one team's
  bullets), points inside polygons, colliders, broken and missing files, a name in another case.
  The maps of the game are compared with Basic-Extended's reader outside this test. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, zs_geo;

var
  Failures: LongInt = 0;
  Checks: LongInt = 0;

procedure Check(Cond: Boolean; const What: AnsiString);
begin
  Inc(Checks);
  if Cond then
    WriteLn('[ OK ] ', What)
  else
  begin
    WriteLn('[FAIL] ', What);
    Inc(Failures);
  end;
end;

type
  TTri = record
    X1, Y1, X2, Y2, X3, Y3: Single;
    T: Byte;
  end;

procedure PutInt(S: TStream; V: LongInt);
begin
  S.WriteBuffer(V, 4);
end;

procedure PutWord(S: TStream; V: Word);
begin
  S.WriteBuffer(V, 2);
end;

procedure PutByte(S: TStream; V: Byte);
begin
  S.WriteBuffer(V, 1);
end;

procedure PutSingle(S: TStream; V: Single);
begin
  S.WriteBuffer(V, 4);
end;

procedure PutZeros(S: TStream; N: LongInt);
var
  k: LongInt;
begin
  for k := 1 to N do
    PutByte(S, 0);
end;

{ a map file as the game writes it: header, polygons, one sector grid that lists every polygon in
  every cell, no scenery, no props, the colliders given (X, Y, R with the game's radius) }
procedure WriteMap(const Path: AnsiString; const Tris: array of TTri; const ColX, ColY, ColR: array of Single;
  SecDiv, SecNum: LongInt);
var
  S: TFileStream;
  i, c, Cells: LongInt;
begin
  S := TFileStream.Create(Path, fmCreate);
  try
    PutInt(S, 11);
    PutZeros(S, 1 + 38);
    PutZeros(S, 1 + 24);
    PutZeros(S, 20);
    PutInt(S, Length(Tris));
    for i := 0 to High(Tris) do
    begin
      PutSingle(S, Tris[i].X1);
      PutSingle(S, Tris[i].Y1);
      PutZeros(S, 20);
      PutSingle(S, Tris[i].X2);
      PutSingle(S, Tris[i].Y2);
      PutZeros(S, 20);
      PutSingle(S, Tris[i].X3);
      PutSingle(S, Tris[i].Y3);
      PutZeros(S, 20);
      PutZeros(S, 36);
      PutByte(S, Tris[i].T);
    end;
    PutInt(S, SecDiv);
    PutInt(S, SecNum);
    Cells := (2 * SecNum + 1) * (2 * SecNum + 1);
    for c := 0 to Cells - 1 do
    begin
      PutWord(S, Length(Tris));
      for i := 0 to High(Tris) do
        PutWord(S, i + 1);
    end;
    PutInt(S, 0);
    PutInt(S, 0);
    PutInt(S, Length(ColX));
    for i := 0 to High(ColX) do
    begin
      PutByte(S, 1);
      PutZeros(S, 3);
      PutSingle(S, ColX[i]);
      PutSingle(S, ColY[i]);
      PutSingle(S, ColR[i]);
    end;
  finally
    S.Free;
  end;
end;

function Tri(X1, Y1, X2, Y2, X3, Y3: Single; T: Byte): TTri;
begin
  Result.X1 := X1;
  Result.Y1 := Y1;
  Result.X2 := X2;
  Result.Y2 := Y2;
  Result.X3 := X3;
  Result.Y3 := Y3;
  Result.T := T;
end;

var
  Dir, P: AnsiString;
  G: TGeoMap;
  n: LongInt;
  Tris: array of TTri;
  F: TFileStream;
  B: Byte;
begin
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'geo_tmp') + PathDelim;
  ForceDirectories(Dir);
  SetLength(Tris, 5);
  { a normal wall, a floor only bullets hit, a floor only players hit, a decoration, a red bullet wall }
  Tris[0] := Tri(0, 0, 100, 0, 0, 100, 0);
  Tris[1] := Tri(200, 0, 300, 0, 200, 100, 1);
  Tris[2] := Tri(400, 0, 500, 0, 400, 100, 2);
  Tris[3] := Tri(600, 0, 700, 0, 600, 100, 3);
  Tris[4] := Tri(800, 0, 900, 0, 800, 100, 10);
  WriteMap(Dir + 'zs_Test.pms', Tris, [1200], [50], [17], 100, 10);

  G := TGeoMap.Create;
  try
    n := G.Load(Dir + 'zs_Test.pms');
    Check(n = 5, 'five polygons read');
    Check(G.Loaded and (G.Colliders = 1), 'one collider read');
    Check(G.Name = 'zs_Test', 'the map name');
    { the normal wall stops bullets and players }
    Check(G.Ray(-50, 20, 150, 20, GR_BULLET, 0), 'a bullet through a wall is stopped');
    Check(G.Ray(-50, 20, 150, 20, GR_PLAYER, 0), 'a player through a wall is stopped');
    Check(not G.Ray(-50, -20, 150, -20, GR_BULLET, 0), 'a ray above the wall is clear');
    Check(not G.Ray(150, 20, 190, 20, GR_BULLET, 0), 'a ray between two walls is clear');
    Check(G.Ray(10, 10, 20, 20, GR_BULLET, 0), 'a ray that starts inside a wall is stopped');
    { only bullets }
    Check(G.Ray(150, 20, 350, 20, GR_BULLET, 0), 'a bullets-only polygon stops a bullet');
    Check(not G.Ray(150, 20, 350, 20, GR_PLAYER, 0), 'a bullets-only polygon lets a player through');
    { only players }
    Check(not G.Ray(350, 20, 550, 20, GR_BULLET, 0), 'a players-only polygon lets a bullet through');
    Check(G.Ray(350, 20, 550, 20, GR_PLAYER, 0), 'a players-only polygon stops a player');
    { decoration }
    Check(not G.Ray(550, 20, 750, 20, GR_BULLET or GR_PLAYER, 0), 'a polygon without collision stops nothing');
    { the red team's bullets }
    Check(G.Ray(750, 20, 950, 20, GR_BULLET, 1), 'a red bullet polygon stops a red bullet');
    Check(not G.Ray(750, 20, 950, 20, GR_BULLET, 2), 'a red bullet polygon lets a blue bullet through');
    Check(not G.Ray(750, 20, 950, 20, GR_BULLET, 0), 'a red bullet polygon lets a teamless bullet through');
    { points }
    Check(G.PointSolid(10, 10, GR_BULLET, 0), 'a point inside a wall is solid');
    Check(not G.PointSolid(90, 90, GR_BULLET, 0), 'a point beside the wall is not');
    { the collider: radius 17 / 1.7 = 10 around (1200, 50) }
    Check(not G.Ray(1150, 55, 1250, 55, GR_BULLET, 0), 'a collider is not a polygon');
    Check(G.Ray(1150, 55, 1250, 55, GR_BULLET or GR_COLLIDER, 0), 'a ray through a collider hits it when asked');
    Check(not G.Ray(1150, 65, 1250, 65, GR_BULLET or GR_COLLIDER, 0), 'a ray 15 px from a collider misses it');
    Check(G.ColliderHit(1195, 40, 1205, 40), 'ColliderHit at the edge');
    Check(G.RaysCast > 0, 'the rays are counted');
    { the same file found by a name in another case }
    Check(GeoMapFile(Dir, 'ZS_TEST') <> '', 'the map file is found in any case');
    Check(GeoMapFile(Dir, '..\zs_Test') = '', 'a map name with a path is refused');
    n := G.Load(Dir + 'ZS_TEST.pms');
    Check(n = 5, 'loaded under another case');
    { missing and broken files }
    n := G.Load(Dir + 'nothing.pms');
    Check((n = GEO_NO_FILE) and not G.Loaded, 'a missing file');
    Check(not G.Ray(-50, 20, 150, 20, GR_BULLET, 0), 'no map: no ray is stopped');
    P := Dir + 'broken.pms';
    F := TFileStream.Create(P, fmCreate);
    try
      B := 7;
      F.WriteBuffer(B, 1);
    finally
      F.Free;
    end;
    n := G.Load(P);
    Check((n = GEO_BAD_FILE) and not G.Loaded, 'a broken file');
    { NaN and huge coordinates are refused }
    n := G.Load(Dir + 'zs_Test.pms');
    Check(not G.Ray(-1E9, 20, 150, 20, GR_BULLET, 0), 'a ray from far outside the world is ignored');
  finally
    G.Free;
  end;
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED (', Checks, ' checks)')
  else
  begin
    WriteLn(Failures, ' TEST(S) FAILED');
    Halt(1);
  end;
end.
