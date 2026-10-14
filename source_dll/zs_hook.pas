unit zs_hook;

{ Two hooks in Soldat Server 2.8.2 ([Bridges] ServerHook), Windows and Linux.

  1. Inside CreateBullet - every bullet the server makes, as it makes it: the server's own fire
     (bots, the fast weapons of humans), the bullets of humans that arrive in packets, grenades,
     cluster grenades and their fragments, thrown knives, arrows, flames, the stationary gun. A
     bullet that is not made (no free slot, a human's own weapon the server only simulates) leaves
     the function before the hook's place. A script's bullet never comes here: ServerCreateBullet
     (Map.CreateBullet) is a copy of the code of CreateBullet in 2.8.2, not a call of it - so the
     slots of the table whose bullet the hook did not see are a script's (HookShadow).

     The hook does not sit at the start of the function, where Basic-Extended puts its own: it
     replaces two instructions right after the bullet's record is filled in (Active, style, owner,
     weapon, Initial, StartUpTime) - "imul eax,[ebp-78h],58h; mov dword [eax+...],0" - with a jump
     to a stub made here (pushad, pushfd, call ShotMade(ebp), popfd, popad, the two instructions, a
     jump back); neither instruction has a relative address. ShotMade reads the bullet from its
     record and the arguments of the call from the server's frame (the places the function's own
     prologue writes them to, checked byte for byte): Net, the weapon number, the owner.

  2. At the start of TSprite.HealthHit - every hit of a soldier with the part of his body the
     server chose for it (Where: the same number that picks the head, chest or legs modifier,
     after the server's own ping compensation), the shooter (Who) and the bullet (What). The
     script's OnDamage runs inside HealthHit, so ZS_Ev_Hit finds the hit of its victim here a
     moment later; Who and What tell that it is that hit.

  The stubs keep every register and the flags, align the stack, and call cdecl routines that copy
  raw bits only: no float goes through the FPU inside the server's code, no Int64, no record copy,
  nothing allocated, nothing can throw out of them. The game thread is the only one that runs the
  server's code and the only one that reads the ring and the tables (ZS_Frame, the exports), so
  there is no lock. }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

const
  SHOT_RING = 1024;
  { what a bullet is for the statistics }
  SK_NONE = 0;      { a blow (fist, buttstock, knife stab), a cluster's fragment, a flame of lava }
  SK_SHOT = 1;      { a shot: bullets, pellets, M79, LAW, arrows, the stationary gun, flames, the saw }
  SK_THROW = 2;     { a grenade or a cluster grenade thrown }

type
  TShotRec = record
    Slot, Owner, W, Style, Kind: LongInt;
    { the server's tick of the bullet (its StartUpTime) }
    Tick: LongInt;
    { how the owner stood (TSprite.Position: 1, 2, 4; 0 = not known) and 1 = on the ground }
    Stance, Ground: LongInt;
    { raw bits of Initial (where it was made) and of its velocity }
    XB, YB, VXB, VYB: LongWord;
  end;

  { what the hook saw of the last bullet of a slot }
  TShadow = record
    Tick, Owner, W, Style, Kind, Stance, Ground: LongInt;
    XB, YB: LongWord;
  end;

  { the last HealthHit of a soldier (Seq 0 = none, or already taken) }
  THitRec = record
    Seq: LongInt;
    Who, Where, What: LongInt;
    AmountB: LongWord;
    { 1 = the hit pushed (Impact not zero): a blast, never a script's Player.Damage, which passes a
      zero vector with Where 1 and What 1 - as a blast of the bullet in slot 1 does }
    Push: LongInt;
  end;

{ the hooks in place: bit 1 CreateBullet, bit 2 HealthHit (also when they already were) }
function HookInstall: LongInt;
{ the place of the CreateBullet hook looked for, nothing patched: it also tells where the server
  keeps its tick (zs_mem), which the origin of a bullet needs without the hook too. HookWhy stays
  as it was. }
procedure HookLocateOnly;
{ both taken out (the server's bytes back), when they are still the ones made here }
procedure HookRemove;
{ still in place (checked every tick): False = the CreateBullet hook was taken out by something else }
function HookCheck: Boolean;
function HookInstalled: Boolean;
function HitHookInstalled: Boolean;
function HookNext(out S: TShotRec): Boolean;
{ the hook's record of the last bullet of slot B (False: none seen yet) }
function HookShadow(B: LongInt; out Sh: TShadow): Boolean;
{ the last HealthHit of soldier V; taken (it is given once) }
function HookTakeHit(V: LongInt; out H: THitRec): Boolean;
function HookInfo: AnsiString;
{ the two hooks in a line: in place, or why not }
function HookWhy: AnsiString;
function HookShots: LongInt;
{ the soldiers' table for the shooter's stance (0 = not known, or the reading is off) }
procedure HookSoldiers(Rec0: PtrUInt);

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils, zs_mem;

const
  ANY = $100;
  { CreateBullet from its 10th byte (a hook at the start replaces the first 9): the prologue that
    stores the arguments - sNum [ebp-70h], sOwner [ebp-84h], N, Net [ebp-80h], MustCreate
    [ebp-7Ch], Seed [ebp-74h] - and the copies of sPos and sVelocity }
  CB_TAIL: array[0..60] of Word = (
    $53, $56, $57, $89, $45, $FC, $89, $55, $F8,
    $88, $4D, $90,                               { mov [ebp-70h],cl        sNum }
    $8B, $45, $1C, $89, $85, $7C, $FF, $FF, $FF, { mov eax,[ebp+1Ch]; mov [ebp-84h],eax  sOwner }
    $8A, $45, $18, $88, $85, $74, $FF, $FF, $FF, { N }
    $8A, $45, $10, $88, $45, $80,                { mov al,[ebp+10h]; mov [ebp-80h],al  Net }
    $8A, $45, $0C, $88, $45, $84,                { MustCreate }
    $8B, $45, $08, $89, $45, $8C,                { Seed }
    $8B, $75, $FC, $8D, $7D, $EC, $B9, $08, $00, $00, $00, $F3, $A4); { sPos -> [ebp-14h] }
  CB_TAIL_AT = 9;
  { the place: StartUpTime := MainTickCounter, the two instructions replaced, "cmp [ebp-74h],-1" }
  SIG_MID: array[0..33] of Word = (
    $6B, $45, $88, $58,                          { imul eax,[ebp-78h],58h }
    $8B, $15, ANY, ANY, ANY, ANY,                { mov edx,[MainTickCounter] }
    $89, $90, ANY, ANY, ANY, ANY,                { mov [eax+StartUpTime],edx }
    $6B, $45, $88, $58,                          { imul eax,[ebp-78h],58h        - replaced }
    $C7, $80, ANY, ANY, ANY, ANY, $00, $00, $00, $00, { mov dword [eax+...],0  - replaced }
    $83, $7D, $8C, $FF);                         { cmp dword [ebp-74h],-1 }
  MID_PATCH_AT = 16;
  MID_PATCH = 14;
  { TSprite.HealthHit: push ebp; mov ebp,esp; sub esp,60h; ... Self, Who, Where, What stored,
    Impact copied }
  SIG_HH: array[0..36] of Word = ($55, $89, $E5, $83, $EC, $60, $53, $56, $57, $89, $45, $A0, $89, $55, $A4, $89,
    $4D, $AC, $8B, $45, $0C, $89, $45, $A8, $8B, $75, $08, $8D, $7D, $EC, $B9, $08, $00, $00, $00, $F3, $A4);
  HH_PATCH = 6;
  { the frame of CreateBullet }
  FR_INDEX = -$78;
  FR_NET = -$80;
  FR_VEL = -$1C;
  STUB_SIZE = 64;
  BULLET_STEP = 88;
  BL_STYLE = 1;
  BL_OWNER = 4;
  BL_WEAPON = 5;
  BL_INITIAL = 48;
  BL_STARTUP = 56;
  SPRITE_STEP = $C218;
  SP_NUM = 4;
  SP_ONGROUND = 6;
  SP_POSITION = 94;
  { styles and weapon numbers of the classification }
  ST_PLAIN = 1;
  ST_FRAG = 2;
  ST_SHOTGUN = 3;
  ST_M79 = 4;
  ST_FLAME = 5;
  ST_ARROW = 7;
  ST_FLAMEARROW = 8;
  ST_CLUSTERNADE = 9;
  ST_KNIFE = 11;
  ST_LAW = 12;
  ST_THROWNKNIFE = 13;
  ST_M2 = 14;
  WN_CHAINSAW = 12;

var
  { CreateBullet }
  Installed: Boolean = False;
  Failed: Boolean = False;
  Why: AnsiString = 'not installed';
  AddrCB: PtrUInt = 0;
  AddrPatch: PtrUInt = 0;
  Saved: array[0..MID_PATCH - 1] of Byte;
  Stub: PByte = nil;
  StubFor: PtrUInt = 0;
  BulletRec0: PtrUInt = 0;
  { HealthHit }
  HhInstalled: Boolean = False;
  HhFailed: Boolean = False;
  HhWhy: AnsiString = 'not installed';
  AddrHH: PtrUInt = 0;
  HhSaved: array[0..HH_PATCH - 1] of Byte;
  HhStub: PByte = nil;
  HhStubFor: PtrUInt = 0;
  { what the hooks saw }
  Ring: array[0..SHOT_RING - 1] of TShotRec;
  Head: LongInt = 0;
  Tail: LongInt = 0;
  Shadow: array[1..254] of TShadow;
  Hits: array[1..32] of THitRec;
  HitSeq: LongInt = 0;
  CntShots: LongInt = 0;
  CntOther: LongInt = 0;
  CntLost: LongInt = 0;
  CntHits: LongInt = 0;
  SoldierRec0: PtrUInt = 0;

{ ---------------- what the hooks do (inside the server's code) ---------------- }

procedure ShotMade(Frame: PtrUInt); cdecl;
var
  i, n, Style, W, Owner, Kind, Stance, Ground: LongInt;
  Rec, S: PtrUInt;
  Net: Byte;
  E: ^TShotRec;
begin
  try
    if BulletRec0 = 0 then
      Exit;
    i := PLongInt(Frame + PtrUInt(PtrInt(FR_INDEX)))^;
    if (i < 1) or (i > 254) then
      Exit;
    Rec := BulletRec0 + PtrUInt(i) * BULLET_STEP;
    Style := PByte(Rec + BL_STYLE)^;
    W := PByte(Rec + BL_WEAPON)^;
    Owner := PByte(Rec + BL_OWNER)^;
    Net := PByte(Frame + PtrUInt(PtrInt(FR_NET)))^;
    case Style of
      ST_PLAIN, ST_SHOTGUN, ST_M79, ST_ARROW, ST_FLAMEARROW, ST_LAW, ST_THROWNKNIFE, ST_M2:
        Kind := SK_SHOT;
      { a flame of the server's own (lava, a flame set alight again) is made with Net = 0 }
      ST_FLAME:
        if Net <> 0 then
          Kind := SK_SHOT
        else
          Kind := SK_NONE;
      ST_FRAG, ST_CLUSTERNADE:
        Kind := SK_THROW;
      { the saw cuts with knife-style bullets; a knife's stab is no shot }
      ST_KNIFE:
        if W = WN_CHAINSAW then
          Kind := SK_SHOT
        else
          Kind := SK_NONE;
    else
      Kind := SK_NONE;
    end;
    Stance := 0;
    Ground := 0;
    if (SoldierRec0 <> 0) and (Owner >= 1) and (Owner <= 32) then
    begin
      S := SoldierRec0 + PtrUInt(Owner) * SPRITE_STEP;
      Stance := PByte(S + SP_POSITION)^;
      if PByte(S + SP_ONGROUND)^ <> 0 then
        Ground := 1;
    end;
    Shadow[i].Tick := PLongInt(Rec + BL_STARTUP)^;
    Shadow[i].Owner := Owner;
    Shadow[i].W := W;
    Shadow[i].Style := Style;
    Shadow[i].Kind := Kind;
    Shadow[i].Stance := Stance;
    Shadow[i].Ground := Ground;
    Shadow[i].XB := PLongWord(Rec + BL_INITIAL)^;
    Shadow[i].YB := PLongWord(Rec + BL_INITIAL + 4)^;
    if (Kind = SK_NONE) or (Owner < 1) or (Owner > 32) then
    begin
      Inc(CntOther);
      Exit;
    end;
    Inc(CntShots);
    E := @Ring[Head];
    E^.Slot := i;
    E^.Owner := Owner;
    E^.W := W;
    E^.Style := Style;
    E^.Kind := Kind;
    E^.Tick := Shadow[i].Tick;
    E^.Stance := Stance;
    E^.Ground := Ground;
    E^.XB := Shadow[i].XB;
    E^.YB := Shadow[i].YB;
    E^.VXB := PLongWord(Frame + PtrUInt(PtrInt(FR_VEL)))^;
    E^.VYB := PLongWord(Frame + PtrUInt(PtrInt(FR_VEL)) + 4)^;
    n := (Head + 1) and (SHOT_RING - 1);
    if n = Tail then
    begin
      Tail := (Tail + 1) and (SHOT_RING - 1);
      Inc(CntLost);
    end;
    Head := n;
  except
  end;
end;

procedure HitMade(SelfPtr: PtrUInt; Who, Where, What: LongInt; AmountB: LongWord; ImpactPtr: PtrUInt); cdecl;
var
  V: LongInt;
begin
  try
    if not ExeData(SelfPtr, SP_POSITION + 1) then
      Exit;
    V := PByte(SelfPtr + SP_NUM)^;
    if (V < 1) or (V > 32) then
      Exit;
    Inc(HitSeq);
    if HitSeq <= 0 then
      HitSeq := 1;
    Hits[V].Seq := HitSeq;
    Hits[V].Who := Who;
    Hits[V].Where := Where;
    Hits[V].What := What;
    Hits[V].AmountB := AmountB;
    Hits[V].Push := 0;
    if ImpactPtr > $10000 then
      if (PLongWord(ImpactPtr)^ and $7FFFFFFF <> 0) or (PLongWord(ImpactPtr + 4)^ and $7FFFFFFF <> 0) then
        Hits[V].Push := 1;
    Inc(CntHits);
  except
  end;
end;

{ ---------------- code and memory ---------------- }

function NewStub: PByte;
begin
  {$IFDEF WINDOWS}
  Result := VirtualAlloc(nil, STUB_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  {$ELSE}
  Result := fpmmap(nil, 4096, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Pointer(Result) = MAP_FAILED then
    Result := nil;
  {$ENDIF}
end;

{ written: read and run only from now on }
function StubDone(P: PByte): Boolean;
{$IFDEF WINDOWS}
var
  Old: LongWord;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  Result := VirtualProtect(P, STUB_SIZE, PAGE_EXECUTE_READ, @Old);
  FlushInstructionCache(GetCurrentProcess, P, STUB_SIZE);
  {$ELSE}
  Result := fpmprotect(P, 4096, PROT_READ or PROT_EXEC) = 0;
  {$ENDIF}
end;

{ Bytes written over the server's code at Target }
function WriteCode(Target: PtrUInt; const Bytes: array of Byte): Boolean;
var
  k: LongInt;
  {$IFDEF WINDOWS}
  Old: LongWord;
  {$ENDIF}
begin
  Result := False;
  {$IFDEF WINDOWS}
  if not VirtualProtect(Pointer(Target), Length(Bytes), PAGE_EXECUTE_READWRITE, @Old) then
    Exit;
  {$ELSE}
  if fpmprotect(Pointer(Target and not PtrUInt($FFF)), $2000, PROT_READ or PROT_WRITE or PROT_EXEC) <> 0 then
    Exit;
  {$ENDIF}
  for k := 0 to High(Bytes) do
    PByte(Target + PtrUInt(k))^ := Bytes[k];
  {$IFDEF WINDOWS}
  VirtualProtect(Pointer(Target), Length(Bytes), Old, @Old);
  FlushInstructionCache(GetCurrentProcess, Pointer(Target), Length(Bytes));
  {$ELSE}
  { the server's code pages read and run only again }
  fpmprotect(Pointer(Target and not PtrUInt($FFF)), $2000, PROT_READ or PROT_EXEC);
  {$ENDIF}
  Result := True;
end;

{ the end of a function: the first "leave; ret Pops" within Span bytes (0 = not there) }
function FindRet(Start: PtrUInt; Pops: LongInt; Span: LongInt): PtrUInt;
var
  p: PByte;
  k: LongInt;
begin
  Result := 0;
  p := PByte(Start);
  for k := 0 to Span - 4 do
    if (p[k] = $C9) and (p[k + 1] = $C2) and (p[k + 2] = Byte(Pops)) and (p[k + 3] = 0) then
    begin
      Result := Start + PtrUInt(k) + 4;
      Exit;
    end;
end;

function BytesAt(A: PtrUInt; const B: array of Byte): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(B) do
    if PByte(A + PtrUInt(k))^ <> B[k] then
      Exit;
  Result := True;
end;

{ Size bytes at At: a jump to Target, the rest NOPs }
procedure JumpBytes(At, Target: PtrUInt; out P: array of Byte);
var
  k: LongInt;
begin
  P[0] := $E9;
  PLongInt(@P[1])^ := LongInt(Target) - LongInt(At + 5);
  for k := 5 to High(P) do
    P[k] := $90;
end;

function OurMidThere: Boolean;
var
  P: array[0..MID_PATCH - 1] of Byte;
begin
  Result := False;
  if (AddrPatch = 0) or (Stub = nil) then
    Exit;
  JumpBytes(AddrPatch, PtrUInt(Stub), P);
  Result := BytesAt(AddrPatch, P);
end;

function OurHhThere: Boolean;
var
  P: array[0..HH_PATCH - 1] of Byte;
begin
  Result := False;
  if (AddrHH = 0) or (HhStub = nil) then
    Exit;
  JumpBytes(AddrHH, PtrUInt(HhStub), P);
  Result := BytesAt(AddrHH, P);
end;

{ the start of a stub: pushad; pushfd; mov ebx,esp; and esp,-16; sub esp,Pad - the arguments go after it }
procedure StubHead(p: PByte; var k: LongInt; Pad: Byte);
begin
  p[k] := $60;
  p[k + 1] := $9C;
  p[k + 2] := $89;
  p[k + 3] := $E3;
  p[k + 4] := $83;
  p[k + 5] := $E4;
  p[k + 6] := $F0;
  p[k + 7] := $83;
  p[k + 8] := $EC;
  p[k + 9] := Pad;
  Inc(k, 10);
end;

{ call Target; mov esp,ebx; popfd; popad }
procedure StubCall(p: PByte; var k: LongInt; Target: PtrUInt);
begin
  p[k] := $E8;
  PLongInt(@p[k + 1])^ := LongInt(Target) - LongInt(PtrUInt(p) + PtrUInt(k) + 5);
  p[k + 5] := $89;
  p[k + 6] := $DC;
  p[k + 7] := $9D;
  p[k + 8] := $61;
  Inc(k, 9);
end;

procedure StubJump(p: PByte; var k: LongInt; Target: PtrUInt);
begin
  p[k] := $E9;
  PLongInt(@p[k + 1])^ := LongInt(Target) - LongInt(PtrUInt(p) + PtrUInt(k) + 5);
  Inc(k, 5);
end;

{ ---------------- CreateBullet ---------------- }

function LocateCB: Boolean;
var
  T, Sig, k: PtrUInt;
  Hits2, j: LongInt;
  p: PByte;
begin
  Result := AddrPatch <> 0;
  if Result then
    Exit;
  if not MemInit then
  begin
    Why := 'the server''s tables were not found (' + MemInfo + ')';
    Exit;
  end;
  T := FindCode(CB_TAIL);
  if T = 0 then
  begin
    Why := 'CreateBullet not found';
    Exit;
  end;
  AddrCB := T - CB_TAIL_AT;
  if not (ExeCode(AddrCB) and ExeCode(AddrCB + $900)) then
  begin
    Why := 'CreateBullet lies outside the server''s code';
    Exit;
  end;
  if FindRet(AddrCB, 24, $1000) = 0 then
  begin
    Why := 'CreateBullet does not end as expected';
    Exit;
  end;
  { the place, inside the function only, exactly once }
  Sig := 0;
  Hits2 := 0;
  p := PByte(AddrCB);
  for k := 0 to $800 do
  begin
    j := 0;
    while (j <= High(SIG_MID)) and ((SIG_MID[j] = ANY) or (p[k + PtrUInt(j)] = Byte(SIG_MID[j]))) do
      Inc(j);
    if j > High(SIG_MID) then
    begin
      Inc(Hits2);
      Sig := AddrCB + k;
    end;
  end;
  if Hits2 <> 1 then
  begin
    Why := 'the hook''s place in CreateBullet was not found';
    Exit;
  end;
  { the StartUpTime the code stores is the bullet table's own (record 0 + 56) }
  MemBulletBase(BulletRec0);
  if (BulletRec0 = 0) or (PLongWord(Sig + 12)^ <> LongWord(BulletRec0 + BL_STARTUP)) then
  begin
    Why := 'CreateBullet does not write the bullet table that was found';
    BulletRec0 := 0;
    Exit;
  end;
  MemSetTickAddr(PLongWord(Sig + 6)^);
  AddrPatch := Sig + MID_PATCH_AT;
  for k := 0 to MID_PATCH - 1 do
    Saved[k] := PByte(AddrPatch + k)^;
  Result := True;
end;

function MakeMidStub: Boolean;
var
  p: PByte;
  k, j: LongInt;
begin
  Result := False;
  if (Stub <> nil) and (StubFor = AddrPatch) then
  begin
    Result := True;
    Exit;
  end;
  p := NewStub;
  if p = nil then
  begin
    Why := 'no memory for the hook';
    Exit;
  end;
  k := 0;
  { 12 + push ebp = 16: the call is made from a 16-aligned stack }
  StubHead(p, k, 12);
  p[k] := $55;
  Inc(k);
  StubCall(p, k, PtrUInt(@ShotMade));
  for j := 0 to MID_PATCH - 1 do
    p[k + j] := Saved[j];
  Inc(k, MID_PATCH);
  StubJump(p, k, AddrPatch + MID_PATCH);
  if not StubDone(p) then
  begin
    Why := 'the hook''s code could not be made executable';
    Exit;
  end;
  Stub := p;
  StubFor := AddrPatch;
  Result := True;
end;

function InstallCB: Boolean;
var
  P: array[0..MID_PATCH - 1] of Byte;
begin
  Result := False;
  if Installed and OurMidThere then
  begin
    Result := True;
    Exit;
  end;
  Installed := False;
  if Failed then
    Exit;
  Failed := True;
  if not LocateCB then
    Exit;
  { the server's two instructions must still be there: nothing else patched this place }
  if not ((Saved[0] = $6B) and (Saved[1] = $45) and (Saved[2] = $88) and (Saved[3] = $58) and (Saved[4] = $C7) and
    (Saved[5] = $80)) then
  begin
    Why := 'the hook''s place holds other code';
    Exit;
  end;
  if not BytesAt(AddrPatch, Saved) then
  begin
    if OurMidThere then
    begin
      Installed := True;
      Failed := False;
      Why := 'in place';
      Result := True;
    end
    else
      Why := 'the hook''s place was changed by something else';
    Exit;
  end;
  if not MakeMidStub then
    Exit;
  JumpBytes(AddrPatch, PtrUInt(Stub), P);
  if not WriteCode(AddrPatch, P) then
  begin
    Why := 'CreateBullet could not be patched';
    Exit;
  end;
  Installed := True;
  Failed := False;
  Why := 'in place';
  Result := True;
end;

{ ---------------- HealthHit ---------------- }

function LocateHH: Boolean;
var
  A: PtrUInt;
  k: LongInt;
begin
  Result := AddrHH <> 0;
  if Result then
    Exit;
  if not MemInit then
  begin
    HhWhy := 'the server''s tables were not found (' + MemInfo + ')';
    Exit;
  end;
  A := FindCode(SIG_HH);
  if A = 0 then
  begin
    HhWhy := 'HealthHit not found';
    Exit;
  end;
  AddrHH := A;
  for k := 0 to HH_PATCH - 1 do
    HhSaved[k] := PByte(A + PtrUInt(k))^;
  Result := True;
end;

function MakeHhStub: Boolean;
var
  p: PByte;
  k, j: LongInt;
begin
  Result := False;
  if (HhStub <> nil) and (HhStubFor = AddrHH) then
  begin
    Result := True;
    Exit;
  end;
  p := NewStub;
  if p = nil then
  begin
    HhWhy := 'no memory for the hook';
    Exit;
  end;
  k := 0;
  { 8 + 6 arguments (24) = 32: the call is made from a 16-aligned stack. After pushad and pushfd
    (ebx): EAX = Self at +32, EDX = Who at +24, ECX = Where at +28, the caller's stack at +36: the
    return address, @Impact +40, What +44, Amount +48 }
  StubHead(p, k, 8);
  p[k] := $FF;
  p[k + 1] := $73;
  p[k + 2] := $28;   { push [ebx+40]  @Impact }
  p[k + 3] := $FF;
  p[k + 4] := $73;
  p[k + 5] := $30;   { push [ebx+48]  Amount }
  p[k + 6] := $FF;
  p[k + 7] := $73;
  p[k + 8] := $2C;   { push [ebx+44]  What }
  p[k + 9] := $FF;
  p[k + 10] := $73;
  p[k + 11] := $1C;  { push [ebx+28]  Where }
  p[k + 12] := $FF;
  p[k + 13] := $73;
  p[k + 14] := $18;  { push [ebx+24]  Who }
  p[k + 15] := $FF;
  p[k + 16] := $73;
  p[k + 17] := $20;  { push [ebx+32]  Self }
  Inc(k, 18);
  StubCall(p, k, PtrUInt(@HitMade));
  { push ebp; mov ebp,esp; sub esp,60h - then on in HealthHit }
  for j := 0 to HH_PATCH - 1 do
    p[k + j] := HhSaved[j];
  Inc(k, HH_PATCH);
  StubJump(p, k, AddrHH + HH_PATCH);
  if not StubDone(p) then
  begin
    HhWhy := 'the hook''s code could not be made executable';
    Exit;
  end;
  HhStub := p;
  HhStubFor := AddrHH;
  Result := True;
end;

function InstallHH: Boolean;
var
  P: array[0..HH_PATCH - 1] of Byte;
begin
  Result := False;
  if HhInstalled and OurHhThere then
  begin
    Result := True;
    Exit;
  end;
  HhInstalled := False;
  if HhFailed then
    Exit;
  HhFailed := True;
  if not LocateHH then
    Exit;
  if not ((HhSaved[0] = $55) and (HhSaved[1] = $89) and (HhSaved[2] = $E5) and (HhSaved[3] = $83) and
    (HhSaved[4] = $EC) and (HhSaved[5] = $60)) then
  begin
    HhWhy := 'the start of HealthHit holds other code';
    Exit;
  end;
  if not BytesAt(AddrHH, HhSaved) then
  begin
    if OurHhThere then
    begin
      HhInstalled := True;
      HhFailed := False;
      HhWhy := 'in place';
      Result := True;
    end
    else
      HhWhy := 'the start of HealthHit was changed by something else';
    Exit;
  end;
  if not MakeHhStub then
    Exit;
  JumpBytes(AddrHH, PtrUInt(HhStub), P);
  if not WriteCode(AddrHH, P) then
  begin
    HhWhy := 'HealthHit could not be patched';
    Exit;
  end;
  HhInstalled := True;
  HhFailed := False;
  HhWhy := 'in place';
  Result := True;
end;

{ ---------------- the interface ---------------- }

function HookInstall: LongInt;
begin
  Result := 0;
  try
    if InstallCB then
      Result := Result or 1;
  except
    Why := 'error while hooking';
  end;
  try
    if InstallHH then
      Result := Result or 2;
  except
    HhWhy := 'error while hooking';
  end;
end;

procedure HookLocateOnly;
var
  W: AnsiString;
begin
  W := Why;
  try
    LocateCB;
  except
  end;
  Why := W;
end;

procedure HookRemove;
var
  k: LongInt;
begin
  try
    if Installed and OurMidThere then
      WriteCode(AddrPatch, Saved);
  except
  end;
  try
    if HhInstalled and OurHhThere then
      WriteCode(AddrHH, HhSaved);
  except
  end;
  { the stubs stay: they are made again only for another place }
  Installed := False;
  HhInstalled := False;
  Why := 'not installed';
  HhWhy := 'not installed';
  Head := 0;
  Tail := 0;
  for k := 1 to 32 do
    Hits[k].Seq := 0;
end;

function HookCheck: Boolean;
begin
  Result := False;
  try
    if HhInstalled and not OurHhThere then
    begin
      HhInstalled := False;
      HhWhy := 'the hook was taken out by something else';
    end;
    if not Installed then
      Exit;
    Result := OurMidThere;
    if not Result then
    begin
      Installed := False;
      Why := 'the hook was taken out by something else';
    end;
  except
    Result := False;
  end;
end;

function HookInstalled: Boolean;
begin
  Result := Installed;
end;

function HitHookInstalled: Boolean;
begin
  Result := HhInstalled;
end;

function HookNext(out S: TShotRec): Boolean;
begin
  Result := False;
  if Head = Tail then
  begin
    FillChar(S, SizeOf(S), 0);
    Exit;
  end;
  S := Ring[Tail];
  Tail := (Tail + 1) and (SHOT_RING - 1);
  Result := True;
end;

function HookShadow(B: LongInt; out Sh: TShadow): Boolean;
begin
  Result := False;
  FillChar(Sh, SizeOf(Sh), 0);
  if (B < 1) or (B > 254) or not Installed then
    Exit;
  Sh := Shadow[B];
  Result := Sh.Owner <> 0;
end;

function HookTakeHit(V: LongInt; out H: THitRec): Boolean;
begin
  Result := False;
  FillChar(H, SizeOf(H), 0);
  if (V < 1) or (V > 32) or not HhInstalled then
    Exit;
  H := Hits[V];
  Hits[V].Seq := 0;
  Result := H.Seq <> 0;
end;

function HookShots: LongInt;
begin
  Result := CntShots;
end;

procedure HookSoldiers(Rec0: PtrUInt);
begin
  SoldierRec0 := Rec0;
end;

function HookWhy: AnsiString;
begin
  Result := 'CreateBullet ' + Why + ', HealthHit ' + HhWhy;
end;

function HookInfo: AnsiString;
begin
  Result := 'CreateBullet ' + Why;
  if Installed or (CntShots + CntOther > 0) then
    Result := Result + ' (shots and throws ' + IntToStr(CntShots) + ', other bullets ' + IntToStr(CntOther) +
      ', lost ' + IntToStr(CntLost) + ')';
  Result := Result + #10 + 'HealthHit ' + HhWhy;
  if HhInstalled or (CntHits > 0) then
    Result := Result + ' (hits ' + IntToStr(CntHits) + ')';
end;

var
  i: LongInt;

initialization
  for i := 1 to 254 do
  begin
    Shadow[i].Owner := 0;
    Shadow[i].Tick := 0;
  end;
  for i := 1 to 32 do
    Hits[i].Seq := 0;
end.
