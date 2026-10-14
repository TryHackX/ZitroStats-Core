unit zs_mem;

{ The running server read directly ([Bridges] MemoryReads): the soldiers, the bullets and the
  particles of Soldat Server 2.8.2, on the game thread only.

  Nothing here writes to the server. Every raw read first checks that the address lies inside the
  server program's own data (its global tables), because try/except does not catch a bad read on
  Linux. The tables are found in the server's code, the way its own functions reach them:

  - the bullets: the code of TScriptActiveMapBullet.GetOwnerWeaponId (movzx eax,[eax+8]; imul eax,
    eax,88; movzx eax,[eax+Base]) gives the table and its record size;
  - the soldiers' positions and velocities (SpriteParts) and the bullets' (BulletParts): the getters
    of Player.X/Y, VelX/VelY and Map.Bullets[i].X/Y, VelX/VelY - each a "sub esp,4; movzx eax,
    [eax+FID]; mov eax,[eax*8+Table]" of its own;
  - a soldier's record (TSprite): the pointer every script player object carries (FSpritePtr, right
    after the class pointer), checked by the class name, the slot number in the record and an anchor
    of its skeleton.

  The places of the fields in a TSprite were read from the getters of the script players in both
  servers (Windows and Linux are built from one source with one compiler: the same layout). They
  are not taken on trust: once a second the script hands over the properties of one player and
  MemCheck compares them field by field; the first difference switches the reading off for good
  (the script reads the properties again) and says why. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

const
  MEM_SLOTS = 32;
  { the keys in MemCheck's mask, in this order: left, right, up, crouch, fire, jetpack, grenade,
    change weapon, throw weapon, reload, prone, flag throw }
  MK_LEFT = 1;
  MK_RIGHT = 2;
  MK_UP = 4;
  MK_CROUCH = 8;
  MK_FIRE = 16;
  MK_JET = 32;
  MK_NADE = 64;
  MK_CHANGE = 128;
  MK_THROW = 256;
  MK_RELOAD = 512;
  MK_PRONE = 1024;
  MK_FLAGTHROW = 2048;
  { the record's Position: how the soldier stands }
  STANCE_STAND = 1;
  STANCE_CROUCH = 2;
  STANCE_PRONE = 4;

type
  TMemSoldier = record
    Active, Alive, Human, OnGround: Boolean;
    Team, Stance, Direction, Holded, Jets: LongInt;
    Health, Vest: Single;
    W, A, SW, SA, Gren: LongInt;
    Keys: LongInt;
    AimX, AimY: LongInt;
    X, Y, VX, VY: Single;
  end;

{ the server's code and data are looked at once (the first call); True when the tables are known }
function MemInit: Boolean;
{ what was found, for /zs_perf }
function MemInfo: AnsiString;
function MemTablesOk: Boolean;
{ the soldier of a slot, from the script's player object (Obj): 1 = bound (or already), 0 = not;
  X, Y are his Player.X, Player.Y (they must match the position table) }
function MemBind(Slot: LongInt; Obj: Pointer; X, Y: Single): LongInt;
function MemBound(Slot: LongInt): Boolean;
{ the reading is on: the tables are known, the soldiers bound and no check failed }
function MemReady: Boolean;
procedure MemSetWanted(On: Boolean);
function MemWanted: Boolean;
{ one soldier as his record has it now (False: not readable - the script reads the properties) }
function MemRead(Slot: LongInt; out S: TMemSoldier): Boolean;
{ a few fields alone, for the hot paths }
function MemAlive(Slot: LongInt; out Alive: Boolean): Boolean;
function MemStance(Slot: LongInt; out Stance: LongInt; out OnGround: Boolean): Boolean;
function MemPos(Slot: LongInt; out X, Y: Single): Boolean;
function MemHealth(Slot: LongInt; out H: Single): Boolean;
{ a point of his skeleton (1..25: 12 head, 9 neck, 7 chest, 5 and 6 hips, 3 and 4 knees, 1 and 2
  feet) and his eyes (3 px from the neck towards the head), within 80 px of his position }
function MemPoint(Slot, K: LongInt; out X, Y: Single): Boolean;
function MemEyes(Slot: LongInt; out X, Y: Single): Boolean;
{ a bullet's record: Active, Style, Owner, weapon number }
function MemBullet(B: LongInt; out Active, Style, Owner, W: LongInt): Boolean;
{ where and at which server tick bullet B was fired (Initial, StartUpTime) }
function MemBulletOrigin(B: LongInt; out X, Y: Single; out Tick: LongInt): Boolean;
{ its particle: where it is now and how fast it flies }
function MemBulletPos(B: LongInt; out X, Y, VX, VY: Single): Boolean;
{ the server's own tick counter (MainTickCounter), known once zs_hook found CreateBullet; -1 = not known }
function MemServerTick: LongInt;
procedure MemSetTickAddr(A: PtrUInt);
{ the bullet table's record 0 (0 = not known) and the soldiers' record 0 (0 = not bound, or the
  reading is off) }
procedure MemBulletBase(out Base: PtrUInt);
function MemSpriteBase: PtrUInt;
{ the check of one soldier against the properties of this tick (State: bit 0 alive, 1 on the
  ground, 2 prone, 3 flagger; Keys as above): 1 = the same, 0 = a difference (the reading is off),
  -1 = not checked }
function MemCheck(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys: LongInt; X, Y, Health, Vest: Single): LongInt;
function MemChecks: LongInt;
procedure MemOff(const Why: AnsiString);
function MemOffWhy: AnsiString;

{ ---- the binary itself, for zs_hook ---- }
{ the only place in the server's code where Sig begins (with $100 bytes in Mask = any byte): 0 when
  none or more than one }
function FindCode(const Sig: array of Word): PtrUInt;
{ the address lies in the server's executable code / writable data }
function ExeCode(A: PtrUInt): Boolean;
function ExeData(A: PtrUInt; Size: LongInt): Boolean;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils;

const
  ANY = $100;
  { TSprite of 2.8.2 (the getters of TScriptPlayer / TScriptActivePlayer in both servers) }
  SPRITE_STEP = $C218;
  SP_ACTIVE = 0;
  SP_DEAD = 1;
  SP_NUM = 4;
  SP_ONGROUND = 6;
  SP_DIRECTION = 10;
  SP_HEALTH = 16;
  SP_HOLDED = 20;
  SP_JETS = 40;
  SP_VEST = 84;
  SP_POSITION = 94;
  SP_SKELETON = 692;
  SP_VDAMP = 20860;
  VDAMP_BITS = $3F7E978D;
  SP_CONTROL = 49084;
  SP_GUN1 = 49104;
  SP_GUN2 = 49200;
  SP_GUN3 = 49296;
  SP_TEAM = 49560;
  SP_CONTROLMETHOD = 49561;
  { inside the control record: the keys of the mask, in the mask's order }
  KEY_OFF: array[0..11] of LongInt = (0, 1, 2, 3, 10, 11, 12, 13, 14, 15, 17, 18);
  CTL_AIMX = 4;
  CTL_AIMY = 6;
  { inside a gun record }
  GUN_AMMO = 1;
  GUN_NUM = 2;
  { the bullet record (from its start) }
  BL_STEP = 88;
  BL_ACTIVE = 0;
  BL_STYLE = 1;
  BL_OWNER = 4;
  BL_WEAPON = 5;
  BL_INITIAL = 48;
  BL_STARTUP = 56;
  BULLETS_MAX = 254;
  { a particle table: TVector2 per index; the velocities follow the positions }
  PARTICLE_STEP = 4480;
  CLASS_WANT = 'ActivePlayer';
  POINT_NEAR = 80;

type
  TRegion = record
    A, B: PtrUInt;
  end;

var
  Tried: Boolean = False;
  Tables: Boolean = False;
  Info: AnsiString = 'not looked at yet';
  DataRegions: array of TRegion;
  CodeRegions: array of TRegion;
  BulletBase: PtrUInt = 0;
  SpritePos: PtrUInt = 0;
  SpriteVel: PtrUInt = 0;
  BulletPos: PtrUInt = 0;
  BulletVel: PtrUInt = 0;
  SpriteBase: PtrUInt = 0;
  Bound: array[1..MEM_SLOTS] of Boolean;
  TickAddr: PtrUInt = 0;
  Wanted: Boolean = True;
  Dead: Boolean = False;
  DeadWhy: AnsiString = '';
  Checks: LongInt = 0;

{ ---------------- the server program's sections ---------------- }

procedure AddRegion(var R: array of TRegion; var N: LongInt; A, B: PtrUInt);
begin
  if (B <= A + 16) or (N > High(R)) then
    Exit;
  R[N].A := A;
  R[N].B := B;
  Inc(N);
end;

{$IFDEF WINDOWS}
procedure FindRegions;
var
  M, Nt, Sec: PtrUInt;
  Count, OptSize, i, nd, nc: LongInt;
  VSize, VAddr, Flags: LongWord;
  D, C: array[0..31] of TRegion;
begin
  nd := 0;
  nc := 0;
  M := PtrUInt(GetModuleHandle(nil));
  if (M <> 0) and (PWord(M)^ = $5A4D) then
  begin
    Nt := M + PtrUInt(PLongInt(M + $3C)^);
    if PLongWord(Nt)^ = $00004550 then
    begin
      Count := PWord(Nt + 6)^;
      OptSize := PWord(Nt + 20)^;
      Sec := Nt + 24 + PtrUInt(OptSize);
      for i := 0 to Count - 1 do
      begin
        VSize := PLongWord(Sec + 8)^;
        if VSize = 0 then
          VSize := PLongWord(Sec + 16)^;
        VAddr := PLongWord(Sec + 12)^;
        Flags := PLongWord(Sec + 36)^;
        if (Flags and $80000000) <> 0 then
          AddRegion(D, nd, M + VAddr, M + VAddr + (VSize and not LongWord(3)));
        if (Flags and $20000000) <> 0 then
          AddRegion(C, nc, M + VAddr, M + VAddr + VSize);
        Inc(Sec, 40);
      end;
    end;
  end;
  SetLength(DataRegions, nd);
  for i := 0 to nd - 1 do
    DataRegions[i] := D[i];
  SetLength(CodeRegions, nc);
  for i := 0 to nc - 1 do
    CodeRegions[i] := C[i];
end;
{$ELSE}
function HexVal(const S: AnsiString): PtrUInt;
var
  i: LongInt;
  Ch: AnsiChar;
begin
  Result := 0;
  for i := 1 to Length(S) do
  begin
    Ch := S[i];
    Result := Result shl 4;
    case Ch of
      '0'..'9': Result := Result or PtrUInt(Ord(Ch) - Ord('0'));
      'a'..'f': Result := Result or PtrUInt(Ord(Ch) - Ord('a') + 10);
      'A'..'F': Result := Result or PtrUInt(Ord(Ch) - Ord('A') + 10);
    end;
  end;
end;

{ /proc/self/maps: the exe's own mappings (rw = data, r-x = code) and the anonymous mapping right
  after its data (the bss) }
procedure FindRegions;
var
  F: TextFile;
  L, Exe, Path, Perm: AnsiString;
  p, q, i, nd, nc: LongInt;
  A, B, LastEnd: PtrUInt;
  Mine: Boolean;
  D, C: array[0..31] of TRegion;
begin
  nd := 0;
  nc := 0;
  Exe := fpReadLink('/proc/self/exe');
  if Exe <> '' then
  begin
    AssignFile(F, '/proc/self/maps');
    {$I-}
    Reset(F);
    {$I+}
    if IOResult = 0 then
    begin
      LastEnd := 0;
      try
        while not Eof(F) do
        begin
          ReadLn(F, L);
          p := Pos('-', L);
          q := Pos(' ', L);
          if (p = 0) or (q = 0) or (q < p) then
            Continue;
          A := HexVal(Copy(L, 1, p - 1));
          B := HexVal(Copy(L, p + 1, q - p - 1));
          Perm := Copy(L, q + 1, 4);
          Path := '';
          p := Pos('/', L);
          if p > 0 then
            Path := Trim(Copy(L, p, Length(L)));
          Mine := Path = Exe;
          if Length(Perm) >= 3 then
          begin
            if (Perm[1] = 'r') and (Perm[2] = 'w') then
            begin
              if Mine then
                AddRegion(D, nd, A, B)
              else if (Path = '') and (LastEnd <> 0) and (A = LastEnd) then
                AddRegion(D, nd, A, B);
            end;
            if Mine and (Perm[1] = 'r') and (Perm[3] = 'x') then
              AddRegion(C, nc, A, B);
          end;
          if Mine then
            LastEnd := B
          else
            LastEnd := 0;
        end;
      finally
        CloseFile(F);
      end;
    end;
  end;
  SetLength(DataRegions, nd);
  for i := 0 to nd - 1 do
    DataRegions[i] := D[i];
  SetLength(CodeRegions, nc);
  for i := 0 to nc - 1 do
    CodeRegions[i] := C[i];
end;
{$ENDIF}

function InRegions(const R: array of TRegion; A: PtrUInt; Size: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(R) do
    if (A >= R[k].A) and (A + PtrUInt(Size) <= R[k].B) then
    begin
      Result := True;
      Exit;
    end;
end;

function ExeData(A: PtrUInt; Size: LongInt): Boolean;
begin
  Result := InRegions(DataRegions, A, Size);
end;

function ExeCode(A: PtrUInt): Boolean;
begin
  Result := InRegions(CodeRegions, A, 1);
end;

function MatchAt(p: PByte; const Sig: array of Word): Boolean;
var
  j: LongInt;
begin
  Result := False;
  for j := 0 to High(Sig) do
    if Sig[j] <> ANY then
      if p[j] <> Byte(Sig[j]) then
        Exit;
  Result := True;
end;

function FindCode(const Sig: array of Word): PtrUInt;
var
  k, Found: LongInt;
  p, pEnd: PByte;
  Last: PtrUInt;
begin
  Result := 0;
  Found := 0;
  if Length(Sig) = 0 then
    Exit;
  for k := 0 to High(CodeRegions) do
  begin
    if CodeRegions[k].B - CodeRegions[k].A <= PtrUInt(Length(Sig)) then
      Continue;
    p := PByte(CodeRegions[k].A);
    Last := CodeRegions[k].B - PtrUInt(Length(Sig));
    pEnd := PByte(Last);
    while p <= pEnd do
    begin
      if (Sig[0] = ANY) or (p^ = Byte(Sig[0])) then
        if MatchAt(p, Sig) then
        begin
          Inc(Found);
          Result := PtrUInt(p);
        end;
      Inc(p);
    end;
  end;
  if Found <> 1 then
    Result := 0;
end;

{ every place where Sig begins, up to Max of them }
function FindAll(const Sig: array of Word; var Hits: array of PtrUInt): LongInt;
var
  k: LongInt;
  p, pEnd: PByte;
  Last: PtrUInt;
begin
  Result := 0;
  for k := 0 to High(CodeRegions) do
  begin
    if CodeRegions[k].B - CodeRegions[k].A <= PtrUInt(Length(Sig)) then
      Continue;
    p := PByte(CodeRegions[k].A);
    Last := CodeRegions[k].B - PtrUInt(Length(Sig));
    pEnd := PByte(Last);
    while p <= pEnd do
    begin
      if p^ = Byte(Sig[0]) then
        if MatchAt(p, Sig) then
        begin
          if Result <= High(Hits) then
            Hits[Result] := PtrUInt(p);
          Inc(Result);
        end;
      Inc(p);
    end;
  end;
end;

{ the two tables of a particle system read by the getters with FID at FidOff: positions and the
  velocities right after them }
function FindParticles(FidOff: Byte; Count: LongInt; out PosT, VelT: PtrUInt): Boolean;
const
  { sub esp,4; movzx eax,byte [eax+FID]; mov eax,[eax*8+disp32]; mov [esp],eax; fld dword [esp];
    add esp,4; ret }
  GETTER: array[0..21] of Word = ($83, $EC, $04, $0F, $B6, $40, ANY, $8B, $04, $C5, ANY, ANY, ANY, ANY,
    $89, $04, $24, $D9, $04, $24, $83, $C4);
var
  Sig: array[0..21] of Word;
  Hits: array[0..15] of PtrUInt;
  n, k, j: LongInt;
  D: array[0..15] of PtrUInt;
  Lo, Hi: PtrUInt;
begin
  Result := False;
  PosT := 0;
  VelT := 0;
  for k := 0 to High(GETTER) do
    Sig[k] := GETTER[k];
  Sig[6] := FidOff;
  n := FindAll(Sig, Hits);
  { X, Y, VelX, VelY }
  if n <> 4 then
    Exit;
  for k := 0 to 3 do
    D[k] := PLongWord(Hits[k] + 10)^;
  Lo := D[0];
  Hi := D[0];
  for k := 1 to 3 do
  begin
    if D[k] < Lo then
      Lo := D[k];
    if D[k] > Hi then
      Hi := D[k];
  end;
  { exactly Lo, Lo + 4, Lo + STEP, Lo + STEP + 4 }
  for k := 0 to 3 do
  begin
    j := 0;
    if (D[k] = Lo) or (D[k] = Lo + 4) or (D[k] = Lo + PARTICLE_STEP) or (D[k] = Lo + PARTICLE_STEP + 4) then
      j := 1;
    if j = 0 then
      Exit;
  end;
  if Hi <> Lo + PARTICLE_STEP + 4 then
    Exit;
  if not ExeData(Lo + 8, 8 * Count) or not ExeData(Lo + PARTICLE_STEP + 8, 8 * Count) then
    Exit;
  PosT := Lo;
  VelT := Lo + PARTICLE_STEP;
  Result := True;
end;

function MemInit: Boolean;
const
  { movzx eax,byte [eax+8]; imul eax,eax,stride; movzx eax,byte [eax+Base] }
  OWNERW: array[0..13] of Word = ($0F, $B6, $40, $08, $6B, $C0, ANY, $0F, $B6, $80, ANY, ANY, ANY, ANY);
var
  A: PtrUInt;
begin
  Result := Tables;
  if Tried then
    Exit;
  Tried := True;
  try
    FindRegions;
    if (Length(DataRegions) = 0) or (Length(CodeRegions) = 0) then
    begin
      Info := 'the server program''s sections were not found';
      Exit;
    end;
    A := FindCode(OWNERW);
    if (A = 0) or (PByte(A + 6)^ <> BL_STEP) then
    begin
      Info := 'the bullet table was not found';
      Exit;
    end;
    { Base is the weapon byte of bullet 0 }
    BulletBase := PLongWord(A + 10)^ - BL_WEAPON;
    if not ExeData(BulletBase + BL_STEP, BL_STEP * BULLETS_MAX) then
    begin
      Info := 'the bullet table lies outside the server''s data';
      Exit;
    end;
    if not FindParticles($10, MEM_SLOTS, SpritePos, SpriteVel) then
    begin
      Info := 'the soldiers'' positions were not found';
      Exit;
    end;
    if not FindParticles($08, BULLETS_MAX, BulletPos, BulletVel) then
    begin
      Info := 'the bullets'' positions were not found';
      Exit;
    end;
    Tables := True;
    Info := 'tables found (bullets $' + HexStr(BulletBase, 8) + ', soldiers'' positions $' + HexStr(SpritePos, 8) +
      ', bullets'' positions $' + HexStr(BulletPos, 8) + ')';
  except
    Info := 'error while reading the server''s code';
    Tables := False;
  end;
  Result := Tables;
end;

function MemTablesOk: Boolean;
begin
  Result := Tables;
end;

function MemInfo: AnsiString;
var
  k, n: LongInt;
begin
  n := 0;
  for k := 1 to MEM_SLOTS do
    if Bound[k] then
      Inc(n);
  if Dead then
    Result := 'off: ' + DeadWhy
  else if not Wanted then
    Result := 'off ([Bridges] MemoryReads = 0)'
  else if not Tables then
    Result := 'not available: ' + Info
  else
    Result := 'on, ' + IntToStr(n) + ' soldiers bound, ' + IntToStr(Checks) + ' checks passed';
end;

procedure MemSetWanted(On: Boolean);
begin
  Wanted := On;
end;

function MemWanted: Boolean;
begin
  Result := Wanted;
end;

function MemReady: Boolean;
begin
  Result := Wanted and Tables and not Dead and (SpriteBase <> 0);
end;

procedure MemOff(const Why: AnsiString);
begin
  if Dead then
    Exit;
  Dead := True;
  DeadWhy := Why;
end;

function MemOffWhy: AnsiString;
begin
  Result := DeadWhy;
end;

function MemChecks: LongInt;
begin
  Result := Checks;
end;

{ ---------------- the soldiers ---------------- }

function ClassNameIs(Obj: Pointer; const Want: AnsiString): Boolean;
var
  VMT, NameP: Pointer;
begin
  Result := False;
  if PtrUInt(Obj) <= $10000 then
    Exit;
  VMT := PPointer(Obj)^;
  if PtrUInt(VMT) <= $10000 then
    Exit;
  NameP := PPointer(PtrUInt(VMT) + 3 * SizeOf(Pointer))^;
  if PtrUInt(NameP) <= $10000 then
    Exit;
  Result := Pos(Want, PShortString(NameP)^) > 0;
end;

function Rec(Slot: LongInt): PtrUInt; inline;
begin
  Result := SpriteBase + PtrUInt(Slot) * SPRITE_STEP;
end;

{ a slot's record is there and is that slot's }
function RecOk(Slot: LongInt): Boolean;
begin
  Result := False;
  if (Slot < 1) or (Slot > MEM_SLOTS) or (SpriteBase = 0) then
    Exit;
  if not ExeData(Rec(Slot), SPRITE_STEP) then
    Exit;
  Result := PByte(Rec(Slot) + SP_NUM)^ = Slot;
end;

function Finite(Bits: LongWord): Boolean; inline;
begin
  Result := (Bits and $7F800000) <> $7F800000;
end;

function MemBind(Slot: LongInt; Obj: Pointer; X, Y: Single): LongInt;
var
  R, Base: PtrUInt;
  PX, PY: LongWord;
begin
  Result := 0;
  try
    if (Slot < 1) or (Slot > MEM_SLOTS) then
      Exit;
    if not MemInit then
      Exit;
    if Bound[Slot] then
    begin
      Result := 1;
      Exit;
    end;
    if not ClassNameIs(Obj, CLASS_WANT) then
      Exit;
    R := PPtrUInt(PtrUInt(Obj) + SizeOf(Pointer))^;
    if not ExeData(R, SPRITE_STEP) then
      Exit;
    if PByte(R + SP_NUM)^ <> Slot then
      Exit;
    { the skeleton's damping: the record is laid out as 2.8.2's }
    if PLongWord(R + SP_VDAMP)^ <> VDAMP_BITS then
    begin
      MemOff('the soldier record is not laid out as Soldat 2.8.2''s');
      Exit;
    end;
    { the position table has this soldier where the script sees him }
    PX := PLongWord(SpritePos + PtrUInt(Slot) * 8)^;
    PY := PLongWord(SpritePos + PtrUInt(Slot) * 8 + 4)^;
    if (PX <> PLongWord(@X)^) or (PY <> PLongWord(@Y)^) then
      Exit;
    Base := R - PtrUInt(Slot) * SPRITE_STEP;
    if SpriteBase = 0 then
      SpriteBase := Base
    else if Base <> SpriteBase then
    begin
      MemOff('two soldier records are not in one table');
      Exit;
    end;
    Bound[Slot] := True;
    Result := 1;
  except
    Result := 0;
  end;
end;

function MemBound(Slot: LongInt): Boolean;
begin
  Result := (Slot >= 1) and (Slot <= MEM_SLOTS) and Bound[Slot];
end;

function ReadyFor(Slot: LongInt): Boolean; inline;
begin
  Result := Wanted and Tables and not Dead and (Slot >= 1) and (Slot <= MEM_SLOTS) and Bound[Slot];
end;

function MemRead(Slot: LongInt; out S: TMemSoldier): Boolean;
var
  R, C: PtrUInt;
  k: LongInt;
  B: LongWord;
begin
  Result := False;
  FillChar(S, SizeOf(S), 0);
  try
    if not ReadyFor(Slot) then
      Exit;
    if not RecOk(Slot) then
      Exit;
    R := Rec(Slot);
    S.Active := PByte(R + SP_ACTIVE)^ <> 0;
    S.Alive := S.Active and (PByte(R + SP_DEAD)^ = 0);
    S.Human := S.Active and (PByte(R + SP_CONTROLMETHOD)^ = 1);
    S.OnGround := PByte(R + SP_ONGROUND)^ <> 0;
    S.Team := PByte(R + SP_TEAM)^;
    S.Stance := PByte(R + SP_POSITION)^;
    S.Direction := PShortInt(R + SP_DIRECTION)^;
    S.Holded := PByte(R + SP_HOLDED)^;
    S.Jets := PSmallInt(R + SP_JETS)^;
    PLongWord(@S.Health)^ := PLongWord(R + SP_HEALTH)^;
    PLongWord(@S.Vest)^ := PLongWord(R + SP_VEST)^;
    S.W := PByte(R + SP_GUN1 + GUN_NUM)^;
    S.A := PByte(R + SP_GUN1 + GUN_AMMO)^;
    S.SW := PByte(R + SP_GUN2 + GUN_NUM)^;
    S.SA := PByte(R + SP_GUN2 + GUN_AMMO)^;
    S.Gren := PByte(R + SP_GUN3 + GUN_AMMO)^;
    C := R + SP_CONTROL;
    S.Keys := 0;
    for k := 0 to 11 do
      if PByte(C + PtrUInt(KEY_OFF[k]))^ <> 0 then
        S.Keys := S.Keys or (1 shl k);
    S.AimX := PSmallInt(C + CTL_AIMX)^;
    S.AimY := PSmallInt(C + CTL_AIMY)^;
    B := PLongWord(SpritePos + PtrUInt(Slot) * 8)^;
    PLongWord(@S.X)^ := B;
    PLongWord(@S.Y)^ := PLongWord(SpritePos + PtrUInt(Slot) * 8 + 4)^;
    PLongWord(@S.VX)^ := PLongWord(SpriteVel + PtrUInt(Slot) * 8)^;
    PLongWord(@S.VY)^ := PLongWord(SpriteVel + PtrUInt(Slot) * 8 + 4)^;
    if not (Finite(B) and Finite(PLongWord(@S.Y)^) and Finite(PLongWord(@S.Health)^)) then
      Exit;
    Result := True;
  except
    Result := False;
  end;
end;

function MemAlive(Slot: LongInt; out Alive: Boolean): Boolean;
var
  R: PtrUInt;
begin
  Result := False;
  Alive := False;
  if not ReadyFor(Slot) then
    Exit;
  if not RecOk(Slot) then
    Exit;
  R := Rec(Slot);
  Alive := (PByte(R + SP_ACTIVE)^ <> 0) and (PByte(R + SP_DEAD)^ = 0);
  Result := True;
end;

function MemStance(Slot: LongInt; out Stance: LongInt; out OnGround: Boolean): Boolean;
var
  R: PtrUInt;
begin
  Result := False;
  Stance := 0;
  OnGround := False;
  if not ReadyFor(Slot) then
    Exit;
  if not RecOk(Slot) then
    Exit;
  R := Rec(Slot);
  Stance := PByte(R + SP_POSITION)^;
  OnGround := PByte(R + SP_ONGROUND)^ <> 0;
  Result := True;
end;

function MemPos(Slot: LongInt; out X, Y: Single): Boolean;
var
  BX, BY: LongWord;
begin
  Result := False;
  X := 0;
  Y := 0;
  if not ReadyFor(Slot) then
    Exit;
  BX := PLongWord(SpritePos + PtrUInt(Slot) * 8)^;
  BY := PLongWord(SpritePos + PtrUInt(Slot) * 8 + 4)^;
  if not (Finite(BX) and Finite(BY)) then
    Exit;
  PLongWord(@X)^ := BX;
  PLongWord(@Y)^ := BY;
  Result := True;
end;

function MemHealth(Slot: LongInt; out H: Single): Boolean;
var
  B: LongWord;
begin
  Result := False;
  H := 0;
  if not ReadyFor(Slot) then
    Exit;
  if not RecOk(Slot) then
    Exit;
  B := PLongWord(Rec(Slot) + SP_HEALTH)^;
  if not Finite(B) then
    Exit;
  PLongWord(@H)^ := B;
  Result := True;
end;

function MemPoint(Slot, K: LongInt; out X, Y: Single): Boolean;
var
  A: PtrUInt;
  BX, BY: LongWord;
  PX, PY: Single;
begin
  Result := False;
  X := 0;
  Y := 0;
  if (K < 1) or (K > 25) then
    Exit;
  if not ReadyFor(Slot) then
    Exit;
  if not RecOk(Slot) then
    Exit;
  A := Rec(Slot) + SP_SKELETON + PtrUInt((K - 1) * 8);
  BX := PLongWord(A)^;
  BY := PLongWord(A + 4)^;
  if not (Finite(BX) and Finite(BY)) then
    Exit;
  PLongWord(@X)^ := BX;
  PLongWord(@Y)^ := BY;
  if not MemPos(Slot, PX, PY) then
    Exit;
  Result := (Abs(X - PX) < POINT_NEAR) and (Abs(Y - PY) < POINT_NEAR);
end;

function MemEyes(Slot: LongInt; out X, Y: Single): Boolean;
var
  NX, NY, HX, HY, L: Single;
begin
  Result := False;
  X := 0;
  Y := 0;
  if not MemPoint(Slot, 9, NX, NY) then
    Exit;
  if not MemPoint(Slot, 12, HX, HY) then
    Exit;
  HX := HX - NX;
  HY := HY - NY;
  L := Sqrt(HX * HX + HY * HY);
  if L < 0.001 then
  begin
    HX := 0;
    HY := -1;
  end
  else
  begin
    HX := HX / L;
    HY := HY / L;
  end;
  X := NX + HX * 3;
  Y := NY + HY * 3;
  Result := True;
end;

{ ---------------- the bullets ---------------- }

function BulletRec(B: LongInt; out A: PtrUInt): Boolean; inline;
begin
  Result := False;
  A := 0;
  if not Tables or (B < 1) or (B > BULLETS_MAX) then
    Exit;
  A := BulletBase + PtrUInt(B) * BL_STEP;
  Result := ExeData(A, BL_STEP);
end;

function MemBullet(B: LongInt; out Active, Style, Owner, W: LongInt): Boolean;
var
  A: PtrUInt;
begin
  Result := False;
  Active := 0;
  Style := 0;
  Owner := 0;
  W := 0;
  try
    if not BulletRec(B, A) then
      Exit;
    Active := PByte(A + BL_ACTIVE)^;
    Style := PByte(A + BL_STYLE)^;
    Owner := PByte(A + BL_OWNER)^;
    W := PByte(A + BL_WEAPON)^;
    Result := Active <= 1;
  except
    Result := False;
  end;
end;

function MemBulletOrigin(B: LongInt; out X, Y: Single; out Tick: LongInt): Boolean;
var
  A: PtrUInt;
  BX, BY: LongWord;
begin
  Result := False;
  X := 0;
  Y := 0;
  Tick := 0;
  try
    if not BulletRec(B, A) then
      Exit;
    BX := PLongWord(A + BL_INITIAL)^;
    BY := PLongWord(A + BL_INITIAL + 4)^;
    if not (Finite(BX) and Finite(BY)) then
      Exit;
    PLongWord(@X)^ := BX;
    PLongWord(@Y)^ := BY;
    Tick := PLongInt(A + BL_STARTUP)^;
    Result := True;
  except
    Result := False;
  end;
end;

function MemBulletPos(B: LongInt; out X, Y, VX, VY: Single): Boolean;
var
  BX, BY: LongWord;
begin
  Result := False;
  X := 0;
  Y := 0;
  VX := 0;
  VY := 0;
  if not Tables or (B < 1) or (B > BULLETS_MAX) then
    Exit;
  BX := PLongWord(BulletPos + PtrUInt(B) * 8)^;
  BY := PLongWord(BulletPos + PtrUInt(B) * 8 + 4)^;
  if not (Finite(BX) and Finite(BY)) then
    Exit;
  PLongWord(@X)^ := BX;
  PLongWord(@Y)^ := BY;
  PLongWord(@VX)^ := PLongWord(BulletVel + PtrUInt(B) * 8)^;
  PLongWord(@VY)^ := PLongWord(BulletVel + PtrUInt(B) * 8 + 4)^;
  Result := True;
end;

procedure MemBulletBase(out Base: PtrUInt);
begin
  if Tables then
    Base := BulletBase
  else
    Base := 0;
end;

function MemSpriteBase: PtrUInt;
begin
  if Wanted and Tables and not Dead and (SpriteBase <> 0) and
     ExeData(SpriteBase + SPRITE_STEP, SPRITE_STEP * MEM_SLOTS) then
    Result := SpriteBase
  else
    Result := 0;
end;

procedure MemSetTickAddr(A: PtrUInt);
begin
  if (A <> 0) and ExeData(A, 4) then
    TickAddr := A;
end;

function MemServerTick: LongInt;
begin
  if TickAddr = 0 then
    Result := -1
  else
    Result := PLongInt(TickAddr)^;
end;

{ ---------------- the check ---------------- }

function MemCheck(Slot, State, W, A, SW, SA, Gren, Jets, Team, Keys: LongInt; X, Y, Health, Vest: Single): LongInt;
var
  S: TMemSoldier;
  St: LongInt;
  Bad: AnsiString;
begin
  Result := -1;
  try
    if not MemRead(Slot, S) then
      Exit;
    St := 0;
    if S.Alive then
      St := St or 1;
    if S.OnGround then
      St := St or 2;
    if S.Stance = STANCE_PRONE then
      St := St or 4;
    if (S.Holded > 0) and (S.Holded < 4) then
      St := St or 8;
    Bad := '';
    if St <> State then
      Bad := 'state ' + IntToStr(St) + ' / ' + IntToStr(State)
    else if S.Team <> Team then
      Bad := 'team'
    else if (S.W <> W) or (S.A <> A) then
      Bad := 'weapon'
    else if (S.SW <> SW) or (S.SA <> SA) then
      Bad := 'second weapon'
    else if S.Gren <> Gren then
      Bad := 'grenades'
    else if S.Jets <> Jets then
      Bad := 'jet fuel'
    else if S.Keys <> Keys then
      Bad := 'keys ' + IntToStr(S.Keys) + ' / ' + IntToStr(Keys)
    else if (PLongWord(@S.X)^ <> PLongWord(@X)^) or (PLongWord(@S.Y)^ <> PLongWord(@Y)^) then
      Bad := 'position'
    else if PLongWord(@S.Health)^ <> PLongWord(@Health)^ then
      Bad := 'health'
    else if PLongWord(@S.Vest)^ <> PLongWord(@Vest)^ then
      Bad := 'vest';
    if Bad <> '' then
    begin
      MemOff('soldier ' + IntToStr(Slot) + ': ' + Bad + ' differs from the script''s property');
      Result := 0;
      Exit;
    end;
    Inc(Checks);
    Result := 1;
  except
    Result := -1;
  end;
end;

end.
