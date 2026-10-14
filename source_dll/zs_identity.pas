unit zs_identity;

{ Player identity and optional passwords.

  Every account is bound by one key:
    - a Steam account by its SteamID. Steam proves the owner, so it needs no password;
    - an account without Steam by the HWID of the computer. The owner can protect it with a
      password: it then records statistics only after /login, or on a computer trusted after a
      login (its HWID and, with TrustDeviceSameIP, the same network).
  Names are free: anybody can play under any name, the account follows the SteamID or the HWID
  and keeps the names used. Steam accounts and computer accounts are never merged
  automatically; admins merge accounts with /zs_merge.

  Soldat confirms a SteamID a moment after the join: usually within milliseconds, sometimes after
  seconds, never for a player without Steam. Until then the player has no account and records no
  statistics (a kill between such a player and anybody else is not counted). With the SteamID the
  Steam account is used. When the confirmation fails, or does not come within
  SteamAuthWaitSeconds, the account of the computer is used; a confirmation that comes later
  still moves the player to the Steam account.

  Passwords are hashed with PBKDF2-SHA256 on the service thread and compared in constant time. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_fields, zs_db, zs_service;

const
  AUTH_REGISTER = 1;
  AUTH_LOGIN = 2;
  AUTH_CHANGEPASS = 3;
  AUTH_RESETPASS = 4;
  AUTH_ADMINSET = 5;
  AUTH_REMOVEPASS = 6;
  AUTH_MAIL_VERIFY = 11;
  AUTH_MAIL_RESET = 12;

type
  TSlotIdentity = record
    InUse: Boolean;
    Human: Boolean;
    Serial: LongWord;
    Name, Steam, Hwid, IP: AnsiString;
    JoinTime: Double;
    SteamDeadline: Double;   { > 0 while waiting for Steam: no account yet }
    ProfileId: LongInt;      { 0 = no account in this session }
    CreatedId: LongInt;      { account created for this session }
    StatsEnabled: Boolean;
    Locked: Boolean;         { registered account, not logged in }
    SpecByLogin: Boolean;    { we moved the player to the spectators until they log in }
    LockSince: Double;
    NextReminder: Double;
    GraceActionDone: Boolean;
    PendingTag: LongInt;
    PendingSalt: AnsiString;
    PendingIter: LongInt;    { the rounds the new password of the pending request is hashed with }
    MailTag: LongInt;
    NextAuthAt: Double;
    LoginTargetId: LongInt;
    ResetTargetId: LongInt;  { the account /forgotpass sent a code for in this session }
    CodeAttempts: LongInt;
    LoginFails: LongInt;     { wrong passwords typed in this session }
    CachedIndex: LongInt;
    CachedGen: LongWord;
  end;

  { wrong passwords from one source on one account: Key is 'H' + the HWID, 'N' + the network
    (IpPrefix), or 'P' + HWID + '|' + network for a computer of the account itself; 'C' counts
    the wrong reset codes of the account, from every session }
  TLoginFailRec = record
    ProfileId: LongInt;
    Key: AnsiString;
    Count: LongInt;
    Since: Double;
    LockUntil: Double;
  end;

  { the e-mails asked for today from one source: Key is 'H' + the HWID or 'N' + the network }
  TMailSourceRec = record
    Key: AnsiString;
    Count: LongInt;
  end;

  TIdentityHost = class
  public
    procedure Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt); virtual; abstract;
    procedure Audit(const Text: AnsiString); virtual; abstract;
    procedure ForceSpectator(Slot: LongInt); virtual; abstract;
    { put a player we moved to the spectators back into the game (the balance picks the team) }
    procedure ReturnToGame(Slot: LongInt); virtual; abstract;
    procedure KickPlayer(Slot: LongInt; const Reason: AnsiString); virtual; abstract;
    function SubmitJob(const Job: TServiceJob): Boolean; virtual; abstract;
    procedure SessionProfileChanged(Slot, OldProfileId, NewProfileId: LongInt); virtual; abstract;
  end;

  TAdminOp = record
    Tag: LongInt;
    ProfileId: LongInt;
    SaltHex: AnsiString;
    Iterations: LongInt;
  end;

  TIdentityManager = class
  private
    FDB: TStatsDB;
    FCfg: PZSConfig;
    FHost: TIdentityHost;
    FNextTag: LongInt;
    FSerial: LongWord;
    FAdminOps: array of TAdminOp;
    FFails: array of TLoginFailRec;
    FMailDay: LongInt;
    FMailToday: LongInt;
    FMailSources: array of TMailSourceRec;
    function NowT: Double; inline;
    function SecNow: Double;
    function NextTag: LongInt;
    procedure ResetSlot(Slot: LongInt);
    procedure Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt);
    function InUseByOther(Index, Slot: LongInt): Boolean;
    function PlayedElsewhere(ProfileId, Slot: LongInt): Boolean;
    function HwidAccount(Slot: LongInt; out Busy: Boolean; out Hint: LongInt): LongInt;
    function CreateFor(Slot: LongInt): LongInt;
    procedure FinalizeSlot(Slot: LongInt);
    procedure Unbind(Slot: LongInt; const Why: AnsiString);
    procedure Bind(Slot, Index: LongInt; Authenticated: Boolean);
    procedure UpdateIdentity(Slot, Index: LongInt);
    procedure MergeGhostInto(Slot, Index: LongInt);
    procedure AddTrustedDevice(Index: LongInt; const Hwid, IP: AnsiString);
    procedure DropTrustedDevices(Index: LongInt; const KeepHwid, KeepIP: AnsiString);
    function DeviceTrusted(const P: TPlayerProfile; const Hwid, IP: AnsiString): Boolean;
    function OwnComputer(const P: TPlayerProfile; const Hwid: AnsiString): Boolean;
    function SourceKeys(Slot: LongInt; const P: TPlayerProfile): TStringArray;
    function FailRecord(ProfileId: LongInt; const Key: AnsiString; Add: Boolean): LongInt;
    function LoginLockEnd(Slot, Index: LongInt): Double;
    function LoginLockMinutes(Slot, Index: LongInt): LongInt;
    function ValidPassword(const Pw, Name: AnsiString; out Msg: AnsiString): Boolean;
    function AuthThrottled(Slot: LongInt): Boolean;
    function SubmitHash(Slot, Op, ProfileId: LongInt; const Pw, Salt: AnsiString; Iter: LongInt;
      const Pw2, Salt2: AnsiString; Iter2: LongInt = 0): Boolean;
    function FindAccountArg(const Arg: AnsiString): LongInt;
    function MailAllowed(Slot, Index: LongInt; out Msg: AnsiString): Boolean;
    function MailsFromSource(Slot: LongInt; Add: Boolean): LongInt;
    function SendCodeMail(Slot, Index, Op: LongInt; const Address, Code: AnsiString): Boolean;
    procedure LoginSucceeded(Slot, Index: LongInt);
    procedure LoginFailed(Slot, Index: LongInt; const What: AnsiString);
    procedure CmdRegister(Slot: LongInt; const W: TStringArray);
    procedure CmdLogin(Slot: LongInt; const W: TStringArray);
    procedure CmdChangePass(Slot: LongInt; const W: TStringArray);
    procedure CmdSetEmail(Slot: LongInt; const W: TStringArray);
    procedure CmdVerifyEmail(Slot: LongInt; const W: TStringArray);
    procedure CmdForgotPass(Slot: LongInt; const W: TStringArray);
    procedure CmdResetPass(Slot: LongInt; const W: TStringArray);
    procedure CmdAccount(Slot: LongInt; const W: TStringArray);
    procedure CmdRemovePass(Slot: LongInt; const W: TStringArray);
  public
    Slots: array[1..MAX_PLAYERS] of TSlotIdentity;
    constructor Create(DB: TStatsDB; Cfg: PZSConfig; Host: TIdentityHost);
    procedure Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Human: Boolean);
    procedure SteamAuth(Slot: LongInt; const Steam: AnsiString);
    procedure SteamAuthFailed(Slot: LongInt);
    procedure Leave(Slot: LongInt);
    procedure Tick;
    function IsPending(Slot: LongInt): Boolean;
    function IsSteamSession(Slot: LongInt): Boolean;
    function ProfileIndex(Slot: LongInt): LongInt;
    function StatsIndex(Slot: LongInt): LongInt;
    function SlotOfProfile(ProfileId: LongInt): LongInt;
    function HandleCommand(Slot: LongInt; const Words: TStringArray; FromChat: Boolean): Boolean;
    procedure HandleServiceResult(const R: TServiceResult);
    function AdminSetPassword(Index: LongInt; const Password: AnsiString; out Msg: AnsiString): Boolean;
    procedure AdminUnregister(Index: LongInt);
  end;

function NormalizeSteam(const S: AnsiString): AnsiString;
function IpPrefix(const IP: AnsiString): AnsiString;
function IsRegistered(const P: TPlayerProfile): Boolean;
{ the stored form of an e-mail code: keyed with the salt of the account's password (SaltHex) }
function CodeHash(ProfileId: LongInt; const SaltHex, Code: AnsiString): AnsiString;
function IsDisposableProfile(const P: TPlayerProfile): Boolean;

implementation

const
  DAY_SECONDS = 86400.0;
  MAX_CODE_ATTEMPTS = 5;
  MAX_FAIL_RECORDS = 4096;
  CODE_LENGTH = 12;
  CODE_HASH_TAG = 'k1:';
  COMMON_PASSWORDS: array[0..14] of AnsiString = ('123456', '1234567', '12345678', '123456789',
    'password', 'qwerty', 'qwerty123', 'soldat', 'soldat1', '111111', 'abc123', 'haslo',
    'haslo123', 'zaq12wsx', 'polska');

{ ---------------- helpers ---------------- }

function NormalizeSteam(const S: AnsiString): AnsiString;
var
  T: AnsiString;
  V: QWord;
  Code: LongInt;
  i: LongInt;
begin
  Result := '';
  T := Trim(S);
  if (T <> '') and (T[1] in ['S', 's']) then
    T := Copy(T, 2, MaxInt)
  else if (Length(T) > 6) and (Copy(T, 1, 5) = '[U:1:') and (T[Length(T)] = ']') then
    T := Copy(T, 6, Length(T) - 6);
  if (T = '') or (Length(T) > 19) then
    Exit;
  for i := 1 to Length(T) do
    if not (T[i] in ['0'..'9']) then
      Exit;
  Val(T, V, Code);
  if (Code <> 0) or (V = 0) then
    Exit;
  { 64-bit SteamIDs are stored as the account number, like ZitroStats 4 did }
  if V >= QWord(76561197960265728) then
    V := V - QWord(76561197960265728);
  if V = 0 then
    Exit;
  Result := 'S' + IntToStr(V);
end;

function IpPrefix(const IP: AnsiString): AnsiString;
var
  i, Groups: LongInt;
begin
  Result := Trim(IP);
  if Pos('.', Result) > 0 then
    Result := Copy(Result, 1, LastDelimiter('.', Result) - 1)
  else if Pos(':', Result) > 0 then
  begin
    Groups := 0;
    for i := 1 to Length(Result) do
      if Result[i] = ':' then
      begin
        Inc(Groups);
        if Groups = 4 then
          Exit(Copy(Result, 1, i - 1));
      end;
  end;
end;

function IsRegistered(const P: TPlayerProfile): Boolean;
begin
  Result := P.PassHash <> '';
end;

{ A code has CODE_LENGTH characters of 32 (60 bits) and its hash is keyed with the salt of the
  password: a copy of the record (Engine = mysql, a website) does not give the code away to a
  search within its lifetime. The tag marks hashes of this kind - the unkeyed hash of a code of
  5.6 is no code at all. }
function CodeHash(ProfileId: LongInt; const SaltHex, Code: AnsiString): AnsiString;
begin
  Result := CODE_HASH_TAG + BytesToHex(DigestToStr(HmacSha256(HexToBytes(SaltHex),
    IntToStr(ProfileId) + ':' + UpperCase(Trim(Code)))));
end;

function IsCodeHash(const H: AnsiString): Boolean;
begin
  Result := (Length(H) > Length(CODE_HASH_TAG)) and (Copy(H, 1, Length(CODE_HASH_TAG)) = CODE_HASH_TAG);
end;

function IsDisposableProfile(const P: TPlayerProfile): Boolean;
begin
  Result := (P.PassHash = '') and (P.Kills = 0) and (P.Deaths = 0) and (P.Shots = 0) and
    (P.FlagsScore = 0) and (P.FlagsGrab = 0) and (P.Wins + P.Loses + P.Draws = 0) and (P.TimePlayed < 60);
end;

{ ---------------- manager basics ---------------- }

constructor TIdentityManager.Create(DB: TStatsDB; Cfg: PZSConfig; Host: TIdentityHost);
var
  i: LongInt;
begin
  inherited Create;
  FDB := DB;
  FCfg := Cfg;
  FHost := Host;
  FNextTag := 1000;
  for i := 1 to MAX_PLAYERS do
    ResetSlot(i);
end;

function TIdentityManager.NowT: Double;
begin
  Result := FDB.NowValue;
end;

{ the security times of an account (locks, codes, trusted computers, the date of the password, the
  last e-mail) are kept in UTC: with Engine = mysql servers in other time zones read them too }
function TIdentityManager.SecNow: Double;
begin
  Result := LocalToUtc(FDB.NowValue);
end;

function TIdentityManager.NextTag: LongInt;
begin
  Inc(FNextTag);
  if FNextTag <= 0 then
    FNextTag := 1000;
  Result := FNextTag;
end;

procedure TIdentityManager.ResetSlot(Slot: LongInt);
begin
  Finalize(Slots[Slot]);
  FillChar(Slots[Slot], SizeOf(TSlotIdentity), 0);
  Slots[Slot].CachedIndex := -1;
end;

procedure TIdentityManager.Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt);
begin
  if (Slot >= 1) and (Slot <= MAX_PLAYERS) and Slots[Slot].InUse then
    FHost.Tell(Slot, Text, Color);
end;

function TIdentityManager.ProfileIndex(Slot: LongInt): LongInt;
var
  S: ^TSlotIdentity;
begin
  Result := -1;
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  S := @Slots[Slot];
  if not S^.InUse or (S^.ProfileId <= 0) then
    Exit;
  if (S^.CachedGen <> FDB.IndexGen) or not FDB.Valid(S^.CachedIndex) or
     (FDB.Profiles[S^.CachedIndex]^.ID <> S^.ProfileId) then
  begin
    S^.CachedIndex := FDB.IndexOfId(S^.ProfileId);
    S^.CachedGen := FDB.IndexGen;
  end;
  Result := S^.CachedIndex;
end;

function TIdentityManager.StatsIndex(Slot: LongInt): LongInt;
begin
  if (Slot >= 1) and (Slot <= MAX_PLAYERS) and Slots[Slot].StatsEnabled then
    Result := ProfileIndex(Slot)
  else
    Result := -1;
end;

function TIdentityManager.SlotOfProfile(ProfileId: LongInt): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  if ProfileId <= 0 then
    Exit;
  for k := 1 to MAX_PLAYERS do
    if Slots[k].InUse and (Slots[k].ProfileId = ProfileId) then
      Exit(k);
end;

function TIdentityManager.IsPending(Slot: LongInt): Boolean;
begin
  Result := (Slot >= 1) and (Slot <= MAX_PLAYERS) and Slots[Slot].InUse and (Slots[Slot].SteamDeadline > 0);
end;

function TIdentityManager.IsSteamSession(Slot: LongInt): Boolean;
begin
  Result := (Slot >= 1) and (Slot <= MAX_PLAYERS) and Slots[Slot].InUse and IsRealSteam(Slots[Slot].Steam);
end;

function TIdentityManager.InUseByOther(Index, Slot: LongInt): Boolean;
var
  k, Id: LongInt;
begin
  Result := False;
  if not FDB.Valid(Index) then
    Exit;
  Id := FDB.Profiles[Index]^.ID;
  for k := 1 to MAX_PLAYERS do
    if (k <> Slot) and Slots[k].InUse and ((Slots[k].ProfileId = Id) or (Slots[k].CreatedId = Id)) then
      Exit(True);
end;

{ another session plays the account with its statistics on (a locked session only waits for a
  login and may be one of several) }
function TIdentityManager.PlayedElsewhere(ProfileId, Slot: LongInt): Boolean;
var
  k: LongInt;
begin
  Result := False;
  if ProfileId <= 0 then
    Exit;
  for k := 1 to MAX_PLAYERS do
    if (k <> Slot) and Slots[k].InUse and (Slots[k].ProfileId = ProfileId) and not Slots[k].Locked then
      Exit(True);
end;

{ ---------------- resolution ---------------- }

{ The account of the computer: an account without Steam whose HWID this is, or a registered one
  that trusts this computer. Busy: that account is played by somebody else on the server. Hint: a
  registered account that knows this HWID but does not trust the computer now. }
function TIdentityManager.HwidAccount(Slot: LongInt; out Busy: Boolean; out Hint: LongInt): LongInt;
var
  C: TIntArray;
  k, i, Score, Best: LongInt;
  P: PPlayerProfile;
  S: ^TSlotIdentity;
begin
  Result := -1;
  Busy := False;
  Hint := -1;
  Best := 0;
  S := @Slots[Slot];
  C := FDB.IndexesOfHwid(S^.Hwid);
  for k := 0 to High(C) do
  begin
    i := C[k];
    if not FDB.Valid(i) then
      Continue;
    P := FDB.Profiles[i];
    if IsRealSteam(P^.ActiveSteam) then
      Continue;
    if SameText(P^.ActiveHWID, S^.Hwid) then
      Score := 2
    else if IsRegistered(P^) and DeviceTrusted(P^, S^.Hwid, S^.IP) then
      Score := 1
    else
    begin
      if IsRegistered(P^) then
        Hint := i;
      Continue;
    end;
    if InUseByOther(i, Slot) then
    begin
      Busy := True;
      Continue;
    end;
    if (Score > Best) or ((Score = Best) and (P^.LastPlayedTime > FDB.Profiles[Result]^.LastPlayedTime)) then
    begin
      Result := i;
      Best := Score;
    end;
  end;
  if Result >= 0 then
    Busy := False;
end;

function TIdentityManager.CreateFor(Slot: LongInt): LongInt;
begin
  Result := FDB.CreateProfile(Slots[Slot].Name, Slots[Slot].Steam, Slots[Slot].Hwid, Slots[Slot].IP,
    FCfg^.StartingPoints);
  FDB.Profiles[Result]^.DisplayHUD := FCfg^.HudDefaultOn;
  Slots[Slot].CreatedId := FDB.Profiles[Result]^.ID;
end;

procedure TIdentityManager.MergeGhostInto(Slot, Index: LongInt);
var
  Ghost: LongInt;
begin
  Ghost := FDB.IndexOfId(Slots[Slot].CreatedId);
  if FDB.Valid(Ghost) and (Ghost <> Index) and FDB.Valid(Index) then
  begin
    FDB.MergeProfile(Index, Ghost, FCfg^.StartingPoints);
    Slots[Slot].CreatedId := 0;
  end;
end;

procedure TIdentityManager.FinalizeSlot(Slot: LongInt);
var
  S: ^TSlotIdentity;
  Target, Hint, Ghost: LongInt;
  Busy: Boolean;
  P: PPlayerProfile;
begin
  S := @Slots[Slot];
  S^.SteamDeadline := 0;
  if IsRealSteam(S^.Steam) then
  begin
    Ghost := FDB.IndexOfId(S^.CreatedId);
    Target := FDB.IndexOfSteam(S^.Steam);
    if FDB.Valid(Target) and InUseByOther(Target, Slot) then
    begin
      Unbind(Slot, 'This Steam account is already playing here - statistics are off for this session.');
      Exit;
    end;
    if not FDB.Valid(Target) then
      Target := CreateFor(Slot);
    Bind(Slot, Target, True);
    { a computer account made while Steam was late is kept only when something was played on it }
    if FDB.Valid(Ghost) and (FDB.Profiles[Ghost]^.ID <> S^.ProfileId) and IsDisposableProfile(FDB.Profiles[Ghost]^) then
      FDB.DeleteProfile(Ghost);
    Exit;
  end;
  if S^.Hwid = '' then
  begin
    Unbind(Slot, 'Your game sent no computer ID - statistics are off for this session.');
    Exit;
  end;
  Target := HwidAccount(Slot, Busy, Hint);
  if Busy then
  begin
    Unbind(Slot, 'The account of this computer is already playing here - statistics are off for this session.');
    Exit;
  end;
  if not FDB.Valid(Target) then
  begin
    Target := CreateFor(Slot);
    if FDB.Valid(Hint) then
      Tell(Slot, Format('This computer was used by the registered account #%d. Yours? /login #%d <password>',
        [FDB.Profiles[Hint]^.ID, FDB.Profiles[Hint]^.ID]), CLR_HINT);
  end;
  P := FDB.Profiles[Target];
  Bind(Slot, Target, not IsRegistered(P^) or DeviceTrusted(P^, S^.Hwid, S^.IP));
end;

procedure TIdentityManager.Unbind(Slot: LongInt; const Why: AnsiString);
var
  S: ^TSlotIdentity;
  OldId: LongInt;
begin
  S := @Slots[Slot];
  OldId := S^.ProfileId;
  S^.ProfileId := 0;
  S^.CachedIndex := -1;
  S^.StatsEnabled := False;
  S^.Locked := False;
  if OldId <> 0 then
    FHost.SessionProfileChanged(Slot, OldId, 0);
  if Why <> '' then
    Tell(Slot, Why, CLR_WARN);
end;

procedure TIdentityManager.Bind(Slot, Index: LongInt; Authenticated: Boolean);
var
  S: ^TSlotIdentity;
  OldId: LongInt;
begin
  S := @Slots[Slot];
  OldId := S^.ProfileId;
  S^.ProfileId := FDB.Profiles[Index]^.ID;
  S^.CachedIndex := Index;
  S^.CachedGen := FDB.IndexGen;
  S^.Locked := IsRegistered(FDB.Profiles[Index]^) and not Authenticated;
  S^.StatsEnabled := not S^.Locked;
  if S^.Locked then
  begin
    if OldId <> S^.ProfileId then
    begin
      S^.LockSince := NowT;
      S^.NextReminder := NowT;
      S^.GraceActionDone := False;
    end;
  end
  else
    UpdateIdentity(Slot, Index);
  if OldId <> S^.ProfileId then
    FHost.SessionProfileChanged(Slot, OldId, S^.ProfileId);
end;

procedure TIdentityManager.UpdateIdentity(Slot, Index: LongInt);
var
  S: ^TSlotIdentity;
  P: PPlayerProfile;
  NewVisit: Boolean;
begin
  S := @Slots[Slot];
  P := FDB.Profiles[Index];
  NewVisit := (P^.ID <> S^.CreatedId) and ((P^.LastPlayedTime <= 0) or
    ((NowT - P^.LastPlayedTime) * 1440 >= Max(1, FCfg^.VisitCooldownMinutes)));
  { a Steam account keeps the HWID and IP of the last session only as information }
  FDB.SetActiveIdentity(Index, S^.Name, S^.Hwid, S^.IP);
  FDB.NoteName(Index, S^.Name, NewVisit, 0, 0, FCfg^.NameHistoryLimit);
  P^.LastPlayedTime := NowT;
  FDB.Touch(Index);
end;

{ ---------------- session events ---------------- }

procedure TIdentityManager.Join(Slot: LongInt; const Name, Steam, Hwid, IP: AnsiString; Human: Boolean);
var
  S: ^TSlotIdentity;
begin
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  if Slots[Slot].InUse then
    Leave(Slot);
  ResetSlot(Slot);
  S := @Slots[Slot];
  Inc(FSerial);
  S^.Serial := FSerial;
  S^.InUse := True;
  S^.Human := Human;
  S^.Name := Copy(Trim(Name), 1, 24);
  S^.Steam := NormalizeSteam(Steam);
  S^.Hwid := Copy(Trim(Hwid), 1, MAX_STRING_LEN - 1);
  S^.IP := Copy(Trim(IP), 1, MAX_STRING_LEN - 1);
  S^.JoinTime := NowT;
  if not Human then
    Exit;
  { a SteamID given at the join is already confirmed by Steam }
  if (S^.Steam <> '') or (FCfg^.SteamAuthWaitSeconds <= 0) then
    FinalizeSlot(Slot)
  else
    S^.SteamDeadline := NowT + FCfg^.SteamAuthWaitSeconds / DAY_SECONDS;
end;

procedure TIdentityManager.SteamAuth(Slot: LongInt; const Steam: AnsiString);
var
  N: AnsiString;
begin
  if (Slot < 1) or (Slot > MAX_PLAYERS) or not Slots[Slot].InUse or not Slots[Slot].Human then
    Exit;
  N := NormalizeSteam(Steam);
  if N = '' then
  begin
    SteamAuthFailed(Slot);
    Exit;
  end;
  if SameText(N, Slots[Slot].Steam) and (Slots[Slot].SteamDeadline = 0) and (Slots[Slot].ProfileId > 0) then
    Exit;
  Slots[Slot].Steam := N;
  FinalizeSlot(Slot);
end;

{ Steam refused the player or has no SteamID for the session: no need to wait any longer }
procedure TIdentityManager.SteamAuthFailed(Slot: LongInt);
begin
  if IsPending(Slot) and Slots[Slot].Human then
    FinalizeSlot(Slot);
end;

procedure TIdentityManager.Leave(Slot: LongInt);
var
  Idx, Ghost: LongInt;
begin
  if (Slot < 1) or (Slot > MAX_PLAYERS) or not Slots[Slot].InUse then
    Exit;
  Idx := ProfileIndex(Slot);
  if FDB.Valid(Idx) and Slots[Slot].StatsEnabled then
  begin
    FDB.Profiles[Idx]^.LastPlayedTime := NowT;
    FDB.Touch(Idx);
  end;
  { nothing worth keeping from an account created for this short visit }
  Ghost := FDB.IndexOfId(Slots[Slot].CreatedId);
  if FDB.Valid(Ghost) and IsDisposableProfile(FDB.Profiles[Ghost]^) then
    FDB.DeleteProfile(Ghost);
  ResetSlot(Slot);
end;

procedure TIdentityManager.Tick;
var
  Slot: LongInt;
  S: ^TSlotIdentity;
  Act: AnsiString;
  Idx: LongInt;
  LockEnd: Double;
begin
  for Slot := 1 to MAX_PLAYERS do
  begin
    S := @Slots[Slot];
    if not S^.InUse or not S^.Human then
      Continue;
    if S^.SteamDeadline > 0 then
    begin
      if NowT < S^.SteamDeadline then
        Continue;
      FinalizeSlot(Slot);
    end
    else if (S^.ProfileId > 0) and (ProfileIndex(Slot) < 0) then
      FinalizeSlot(Slot); { the account was removed while the player was online }
    if not S^.Locked then
      Continue;
    Idx := ProfileIndex(Slot);
    if (FCfg^.LoginReminderSeconds > 0) and (NowT >= S^.NextReminder) and FDB.Valid(Idx) then
    begin
      Tell(Slot, Format('Account #%d of this computer is password protected.', [FDB.Profiles[Idx]^.ID]), CLR_WARN);
      Tell(Slot, 'Log in: /login <password> - stats are not saved until then.', CLR_WARN);
      S^.NextReminder := NowT + FCfg^.LoginReminderSeconds / DAY_SECONDS;
    end;
    { a player who cannot log in because of somebody else's wrong passwords is neither moved nor
      kicked: the countdown starts again when the lock ends }
    if not S^.GraceActionDone and (NowT - S^.LockSince >= FCfg^.LoginGraceSeconds / DAY_SECONDS) and
       FDB.Valid(Idx) and (S^.LoginFails < Max(1, FCfg^.LoginMaxAttempts)) then
    begin
      LockEnd := LoginLockEnd(Slot, Idx);
      if LockEnd > SecNow then
        S^.LockSince := NowT + (LockEnd - SecNow);
    end;
    if not S^.GraceActionDone and (NowT - S^.LockSince >= FCfg^.LoginGraceSeconds / DAY_SECONDS) then
    begin
      S^.GraceActionDone := True;
      Act := LowerCase(Trim(FCfg^.UnauthenticatedAction));
      if Act = 'spectator' then
      begin
        S^.SpecByLogin := True;
        Tell(Slot, 'Spectators until you log in: /login <password>', CLR_WARN);
        FHost.ForceSpectator(Slot);
      end
      else if Act = 'kick' then
        FHost.KickPlayer(Slot, 'Log in to use this registered account');
    end;
  end;
end;

{ ---------------- account helpers ---------------- }

procedure TIdentityManager.AddTrustedDevice(Index: LongInt; const Hwid, IP: AnsiString);
var
  P: PPlayerProfile;
  k, j, n, Oldest: LongInt;
  Prefix: AnsiString;
begin
  if (Hwid = '') or (FCfg^.TrustedDeviceDays <= 0) or not FCfg^.TrustedDevicesEnabled or
     not FDB.Valid(Index) then
    Exit;
  { the owner wants a password on every computer }
  if FDB.Profiles[Index]^.NoTrustedDevices then
    Exit;
  P := FDB.Profiles[Index];
  Prefix := IpPrefix(IP);
  FDB.BeginIdentityChange(Index);
  for k := High(P^.TrustedDevices) downto 0 do
    if (P^.TrustedDevices[k].Expire < SecNow) or
       (SameText(P^.TrustedDevices[k].HWID, Hwid) and (P^.TrustedDevices[k].IPPrefix = Prefix)) then
    begin
      for j := k to High(P^.TrustedDevices) - 1 do
        P^.TrustedDevices[j] := P^.TrustedDevices[j + 1];
      SetLength(P^.TrustedDevices, Length(P^.TrustedDevices) - 1);
    end;
  if Length(P^.TrustedDevices) >= MAX_TRUSTED_DEVICES then
  begin
    Oldest := 0;
    for k := 1 to High(P^.TrustedDevices) do
      if P^.TrustedDevices[k].LastUsed < P^.TrustedDevices[Oldest].LastUsed then
        Oldest := k;
    for j := Oldest to High(P^.TrustedDevices) - 1 do
      P^.TrustedDevices[j] := P^.TrustedDevices[j + 1];
    SetLength(P^.TrustedDevices, Length(P^.TrustedDevices) - 1);
  end;
  n := Length(P^.TrustedDevices);
  SetLength(P^.TrustedDevices, n + 1);
  P^.TrustedDevices[n].HWID := Hwid;
  P^.TrustedDevices[n].IPPrefix := Prefix;
  P^.TrustedDevices[n].Expire := SecNow + FCfg^.TrustedDeviceDays;
  P^.TrustedDevices[n].LastUsed := SecNow;
  FDB.EndIdentityChange(Index);
  FDB.Touch(Index);
end;

{ forgets every trusted computer; KeepHwid (if given) is trusted again right away }
procedure TIdentityManager.DropTrustedDevices(Index: LongInt; const KeepHwid, KeepIP: AnsiString);
begin
  if not FDB.Valid(Index) then
    Exit;
  FDB.BeginIdentityChange(Index);
  FDB.Profiles[Index]^.TrustedDevices := nil;
  FDB.EndIdentityChange(Index);
  if KeepHwid <> '' then
    AddTrustedDevice(Index, KeepHwid, KeepIP);
  FDB.Touch(Index);
end;

function TIdentityManager.DeviceTrusted(const P: TPlayerProfile; const Hwid, IP: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  if (Hwid = '') or not FCfg^.TrustedDevicesEnabled or P.NoTrustedDevices then
    Exit;
  { a computer trusted before the password was set or changed is not trusted any more (LastUsed is
    the moment it was added; every new password keeps only the current computer, added with the
    same time), whatever a merge of the database brings back }
  for k := 0 to High(P.TrustedDevices) do
    if SameText(P.TrustedDevices[k].HWID, Hwid) and (P.TrustedDevices[k].Expire >= SecNow) and
       (P.TrustedDevices[k].LastUsed >= P.PassSetTime) and
       (not FCfg^.TrustDeviceSameIP or (P.TrustedDevices[k].IPPrefix = IpPrefix(IP))) then
      Exit(True);
end;

{ a computer of the account itself: the one it was last played on, or one it trusts (on any network) }
function TIdentityManager.OwnComputer(const P: TPlayerProfile; const Hwid: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  if Hwid = '' then
    Exit;
  if SameText(P.ActiveHWID, Hwid) then
    Exit(True);
  for k := 0 to High(P.TrustedDevices) do
    if SameText(P.TrustedDevices[k].HWID, Hwid) and (P.TrustedDevices[k].Expire >= SecNow) and
       (P.TrustedDevices[k].LastUsed >= P.PassSetTime) then
      Exit(True);
end;

{ The sources wrong passwords on account P are counted for, each on its own: the computer and the
  network of the session. A computer of the account itself counts as itself on this network only,
  so neither somebody else in the same network nor a copy of its HWID elsewhere locks the owner. }
function TIdentityManager.SourceKeys(Slot: LongInt; const P: TPlayerProfile): TStringArray;
var
  S: ^TSlotIdentity;
  Net: AnsiString;
  n: LongInt;
begin
  S := @Slots[Slot];
  Net := IpPrefix(S^.IP);
  SetLength(Result, 2);
  n := 0;
  if OwnComputer(P, S^.Hwid) then
  begin
    Result[0] := 'P' + UpperCase(S^.Hwid) + '|' + Net;
    n := 1;
  end
  else
  begin
    if S^.Hwid <> '' then
    begin
      Result[n] := 'H' + UpperCase(S^.Hwid);
      Inc(n);
    end;
    if Net <> '' then
    begin
      Result[n] := 'N' + Net;
      Inc(n);
    end;
  end;
  if n = 0 then
  begin
    Result[0] := 'X';
    n := 1;
  end;
  SetLength(Result, n);
end;

{ the record of a source on an account, -1 when there is none (Add: a new one); records nobody
  needs any more go first, and the table never holds more than a few thousand }
function TIdentityManager.FailRecord(ProfileId: LongInt; const Key: AnsiString; Add: Boolean): LongInt;
var
  k, n, Oldest: LongInt;
  Window: Double;
begin
  for k := 0 to High(FFails) do
    if (FFails[k].ProfileId = ProfileId) and (FFails[k].Key = Key) then
      Exit(k);
  Result := -1;
  if not Add then
    Exit;
  Window := Max(Max(1, FCfg^.LoginLockMinutes), Max(1, FCfg^.MailCodeMinutes)) / 1440;
  n := 0;
  for k := 0 to High(FFails) do
    if (FFails[k].LockUntil > SecNow) or (SecNow - FFails[k].Since <= Window) then
    begin
      FFails[n] := FFails[k];
      Inc(n);
    end;
  SetLength(FFails, n);
  if n >= MAX_FAIL_RECORDS then
  begin
    Oldest := 0;
    for k := 1 to High(FFails) do
      if FFails[k].Since < FFails[Oldest].Since then
        Oldest := k;
    FFails[Oldest] := FFails[High(FFails)];
    SetLength(FFails, High(FFails));
  end;
  Result := Length(FFails);
  SetLength(FFails, Result + 1);
  FFails[Result].ProfileId := ProfileId;
  FFails[Result].Key := Key;
  FFails[Result].Count := 0;
  FFails[Result].Since := SecNow;
  FFails[Result].LockUntil := 0;
end;

{ the end (UTC) of what stops this session from trying a password on the account at Index: a lock
  of its own source, or the lock of the whole account after many wrong passwords from everywhere;
  a time that has passed means no lock }
function TIdentityManager.LoginLockEnd(Slot, Index: LongInt): Double;
var
  P: PPlayerProfile;
  Keys: TStringArray;
  i, k: LongInt;
begin
  P := FDB.Profiles[Index];
  Result := P^.LoginLockUntil;
  Keys := SourceKeys(Slot, P^);
  for i := 0 to High(Keys) do
  begin
    k := FailRecord(P^.ID, Keys[i], False);
    if (k >= 0) and (FFails[k].LockUntil > Result) then
      Result := FFails[k].LockUntil;
  end;
end;

{ minutes until this session may try a password on the account at Index again (0 = now) }
function TIdentityManager.LoginLockMinutes(Slot, Index: LongInt): LongInt;
var
  LockEnd: Double;
begin
  LockEnd := LoginLockEnd(Slot, Index);
  if LockEnd > SecNow then
    Result := Trunc((LockEnd - SecNow) * 1440) + 1
  else
    Result := 0;
end;

function TIdentityManager.ValidPassword(const Pw, Name: AnsiString; out Msg: AnsiString): Boolean;
var
  MinLen, MaxLen, i: LongInt;
  AllSame: Boolean;
begin
  Result := False;
  MinLen := Max(4, FCfg^.MinPasswordLength);
  MaxLen := Min(20, Max(MinLen, FCfg^.MaxPasswordLength));
  if (Length(Pw) < MinLen) or (Length(Pw) > MaxLen) then
  begin
    Msg := Format('The password must have %d-%d characters.', [MinLen, MaxLen]);
    Exit;
  end;
  if not IsPrintableNoSpace(Pw) then
  begin
    Msg := 'Use letters, digits and symbols only (no spaces, no accents).';
    Exit;
  end;
  if SameText(Pw, Name) then
  begin
    Msg := 'The password cannot be your name.';
    Exit;
  end;
  AllSame := True;
  for i := 2 to Length(Pw) do
    if Pw[i] <> Pw[1] then
      AllSame := False;
  for i := 0 to High(COMMON_PASSWORDS) do
    if LowerCase(Pw) = COMMON_PASSWORDS[i] then
      AllSame := True;
  if AllSame then
  begin
    Msg := 'This password is too easy to guess.';
    Exit;
  end;
  Result := True;
end;

function TIdentityManager.AuthThrottled(Slot: LongInt): Boolean;
var
  S: ^TSlotIdentity;
begin
  S := @Slots[Slot];
  Result := True;
  if S^.PendingTag <> 0 then
  begin
    Tell(Slot, 'Please wait, your previous request is still running.', CLR_WARN);
    Exit;
  end;
  if NowT < S^.NextAuthAt then
  begin
    Tell(Slot, 'Please wait a moment before trying again.', CLR_WARN);
    Exit;
  end;
  S^.NextAuthAt := NowT + 2 / DAY_SECONDS;
  Result := False;
end;

{ Iter: the rounds of Pw; Iter2 those of Pw2 (0 = Iter) }
function TIdentityManager.SubmitHash(Slot, Op, ProfileId: LongInt; const Pw, Salt: AnsiString; Iter: LongInt;
  const Pw2, Salt2: AnsiString; Iter2: LongInt): Boolean;
var
  Job: TServiceJob;
begin
  Job := NewServiceJob(svHash);
  Job.Tag := NextTag;
  Job.Slot := Slot;
  Job.ProfileId := ProfileId;
  Job.Op := Op;
  Job.Password := Pw;
  Job.Salt := Salt;
  Job.Password2 := Pw2;
  Job.Salt2 := Salt2;
  Job.Iterations := Max(1, Iter);
  if Iter2 > 0 then
    Job.Iterations2 := Iter2;
  Result := FHost.SubmitJob(Job);
  if (Slot >= 1) and (Slot <= MAX_PLAYERS) then
  begin
    if Result then
      Slots[Slot].PendingTag := Job.Tag
    else
      Tell(Slot, 'The server is busy, please try again in a few seconds.', CLR_WARN);
  end;
  WipeString(Job.Password);
  WipeString(Job.Password2);
end;

{ #id, or by name the registered computer account seen most recently }
function TIdentityManager.FindAccountArg(const Arg: AnsiString): LongInt;
var
  C: TIntArray;
  k: LongInt;
  P: PPlayerProfile;
begin
  Result := -1;
  if (Length(Arg) > 1) and (Arg[1] = '#') then
    Exit(FDB.IndexOfId(StrToIntDef(Copy(Arg, 2, MaxInt), 0)));
  C := FDB.IndexesOfName(Arg);
  for k := 0 to High(C) do
    if FDB.Valid(C[k]) then
    begin
      P := FDB.Profiles[C[k]];
      if IsRegistered(P^) and not IsRealSteam(P^.ActiveSteam) and
         ((Result < 0) or (P^.LastPlayedTime > FDB.Profiles[Result]^.LastPlayedTime)) then
        Result := C[k];
    end;
end;

function TIdentityManager.MailAllowed(Slot, Index: LongInt; out Msg: AnsiString): Boolean;
var
  P: PPlayerProfile;
  Today, WaitMin: LongInt;
begin
  Result := False;
  P := FDB.Profiles[Index];
  Today := DayKey(NowT);
  if P^.MailDayKey <> Today then
  begin
    P^.MailDayKey := Today;
    P^.MailSentToday := 0;
  end;
  if P^.MailSentToday >= Max(1, FCfg^.MailMaxPerDay) then
  begin
    Msg := 'The e-mail limit for today is reached. Try again tomorrow.';
    Exit;
  end;
  if (P^.MailLastSent > 0) and ((SecNow - P^.MailLastSent) * 1440 < FCfg^.MailMinIntervalMinutes) then
  begin
    WaitMin := Trunc(FCfg^.MailMinIntervalMinutes - (SecNow - P^.MailLastSent) * 1440) + 1;
    Msg := Format('Please wait %d min before requesting another e-mail.', [WaitMin]);
    Exit;
  end;
  { the limits of the account are not enough: an account is easy to make. The server sends at most
    MaxPerDayServer a day, and one computer or network asks for at most MaxPerDaySource }
  if FMailDay <> Today then
  begin
    FMailDay := Today;
    FMailToday := 0;
    FMailSources := nil;
  end;
  if FMailToday >= Max(1, FCfg^.MailMaxPerDayServer) then
  begin
    Msg := 'The server has sent all its e-mails for today. Try again tomorrow.';
    Exit;
  end;
  if MailsFromSource(Slot, False) >= Max(1, FCfg^.MailMaxPerDaySource) then
  begin
    Msg := 'Too many e-mails were asked for from your computer today. Try again tomorrow.';
    Exit;
  end;
  Result := True;
end;

{ the e-mails asked for today from the computer and from the network of a session, the larger of
  the two; Add counts one more for both }
function TIdentityManager.MailsFromSource(Slot: LongInt; Add: Boolean): LongInt;
var
  Keys: array[0..1] of AnsiString;
  i, k, n: LongInt;
begin
  Result := 0;
  Keys[0] := '';
  Keys[1] := '';
  if Slots[Slot].Hwid <> '' then
    Keys[0] := 'H' + UpperCase(Slots[Slot].Hwid);
  if IpPrefix(Slots[Slot].IP) <> '' then
    Keys[1] := 'N' + IpPrefix(Slots[Slot].IP);
  for i := 0 to 1 do
  begin
    if Keys[i] = '' then
      Continue;
    k := -1;
    for n := 0 to High(FMailSources) do
      if FMailSources[n].Key = Keys[i] then
      begin
        k := n;
        Break;
      end;
    if (k < 0) and Add then
    begin
      k := Length(FMailSources);
      SetLength(FMailSources, k + 1);
      FMailSources[k].Key := Keys[i];
      FMailSources[k].Count := 0;
    end;
    if k < 0 then
      Continue;
    if Add then
      Inc(FMailSources[k].Count);
    Result := Max(Result, FMailSources[k].Count);
  end;
end;

{ False when the service queue refused the mail: nothing was sent and nothing counts against the
  limits of the account }
function TIdentityManager.SendCodeMail(Slot, Index, Op: LongInt; const Address, Code: AnsiString): Boolean;
var
  P: PPlayerProfile;
  Job: TServiceJob;
  Server: AnsiString;
begin
  P := FDB.Profiles[Index];
  Server := CpToUtf8(FCfg^.MailServerName, FCfg^.SourceCodepage);
  Job := NewServiceJob(svMail);
  Job.Tag := NextTag;
  Job.Slot := Slot;
  Job.ProfileId := P^.ID;
  Job.Op := Op;
  Job.MailTo := Address;
  if Op = AUTH_MAIL_VERIFY then
  begin
    Job.Subject := Server + ': e-mail verification';
    { no name of a player in the text: anybody can choose any name (the account number is enough) }
    Job.Body := 'Hello,' + LineEnding + LineEnding +
      'the e-mail verification code for account #' + IntToStr(P^.ID) + ' is:' + LineEnding + LineEnding +
      '    ' + Code + LineEnding + LineEnding +
      'Type in game: /verifyemail ' + Code + LineEnding +
      'The code is valid for ' + IntToStr(FCfg^.MailCodeMinutes) + ' minutes.' + LineEnding + LineEnding +
      'If you did not ask for this, ignore this message.' + LineEnding;
  end
  else
  begin
    Job.Subject := Server + ': password reset';
    Job.Body := 'Hello,' + LineEnding + LineEnding +
      'the password reset code for account #' + IntToStr(P^.ID) + ' is:' + LineEnding + LineEnding +
      '    ' + Code + LineEnding + LineEnding +
      'Type in game: /resetpass ' + Code + ' <new password> <new password>' + LineEnding +
      'The code is valid for ' + IntToStr(FCfg^.MailCodeMinutes) + ' minutes.' + LineEnding + LineEnding +
      'If you did not ask for this, your account is safe: ignore this message.' + LineEnding;
  end;
  Result := FHost.SubmitJob(Job);
  if not Result then
  begin
    Tell(Slot, 'The server is busy, please try again later.', CLR_WARN);
    Exit;
  end;
  Slots[Slot].MailTag := Job.Tag;
  P^.MailLastSent := SecNow;
  Inc(P^.MailSentToday);
  FDB.Touch(Index);
  Inc(FMailToday);
  MailsFromSource(Slot, True);
  if FMailToday = Max(1, FCfg^.MailMaxPerDayServer) then
    FHost.Audit(Format('mail: the limit of the server for today is reached ([Mail] MaxPerDayServer = %d)',
      [FMailToday]));
end;

procedure TIdentityManager.LoginSucceeded(Slot, Index: LongInt);
var
  S: ^TSlotIdentity;
  P: PPlayerProfile;
  Keys: TStringArray;
  i, k: LongInt;
begin
  S := @Slots[Slot];
  P := FDB.Profiles[Index];
  P^.LoginFailCount := 0;
  P^.LoginLockUntil := 0;
  { the wrong passwords of this source are forgotten too }
  Keys := SourceKeys(Slot, P^);
  for i := 0 to High(Keys) do
  begin
    k := FailRecord(P^.ID, Keys[i], False);
    if k >= 0 then
    begin
      FFails[k].Count := 0;
      FFails[k].LockUntil := 0;
    end;
  end;
  S^.LoginFails := 0;
  { two sessions may have asked at the same time, and the password is checked on another thread:
    the account is played by one of them only }
  if PlayedElsewhere(P^.ID, Slot) then
  begin
    FDB.Touch(Index);
    S^.LoginTargetId := 0;
    Tell(Slot, 'That account is already playing on this server.', CLR_BAD);
    Exit;
  end;
  AddTrustedDevice(Index, S^.Hwid, S^.IP);
  { the account made for this session on a new computer belongs to the same player }
  MergeGhostInto(Slot, Index);
  S^.LoginTargetId := 0;
  S^.CodeAttempts := 0;
  FDB.Touch(Index);
  Bind(Slot, Index, True);
  FHost.Audit(Format('account #%d (%s): login from %s', [P^.ID, P^.ActiveName, S^.IP]));
  Tell(Slot, 'Logged in as ' + P^.ActiveName + '. Your stats are saved.', CLR_GOOD);
  { a player we parked on the spectators goes back to the game, to the team the balance wants }
  if S^.SpecByLogin then
  begin
    S^.SpecByLogin := False;
    if FCfg^.LoginReturnToGame then
      FHost.ReturnToGame(Slot);
  end;
end;

{ A wrong password locks the source it came from after LoginMaxAttempts (its computer or its
  network, SourceKeys), never the owner somewhere else; the account itself is locked for everybody
  only after LoginMaxAttemptsAccount wrong passwords from all sources together. }
procedure TIdentityManager.LoginFailed(Slot, Index: LongInt; const What: AnsiString);
var
  P: PPlayerProfile;
  Limit, Shown, i, k: LongInt;
  Keys: TStringArray;
  SourceLocked: Boolean;
begin
  P := FDB.Profiles[Index];
  Limit := Max(1, FCfg^.LoginMaxAttempts);
  Inc(Slots[Slot].LoginFails);
  Keys := SourceKeys(Slot, P^);
  Shown := 0;
  SourceLocked := False;
  for i := 0 to High(Keys) do
  begin
    k := FailRecord(P^.ID, Keys[i], True);
    if (FFails[k].Count > 0) and (SecNow - FFails[k].Since > Max(1, FCfg^.LoginLockMinutes) / 1440) then
      FFails[k].Count := 0;
    if FFails[k].Count = 0 then
      FFails[k].Since := SecNow;
    Inc(FFails[k].Count);
    if FFails[k].Count >= Limit then
    begin
      FFails[k].Count := 0;
      FFails[k].LockUntil := SecNow + Max(1, FCfg^.LoginLockMinutes) / 1440;
      SourceLocked := True;
    end
    else if FFails[k].Count > Shown then
      Shown := FFails[k].Count;
  end;
  { failures count within the lock time: a password mistyped weeks ago does not add up to a lock }
  if (P^.LoginFailCount > 0) and (SecNow - P^.LoginFailSince > Max(1, FCfg^.LoginLockMinutes) / 1440) then
    P^.LoginFailCount := 0;
  if P^.LoginFailCount = 0 then
    P^.LoginFailSince := SecNow;
  Inc(P^.LoginFailCount);
  if P^.LoginFailCount >= Max(Limit, FCfg^.LoginMaxAttemptsAccount) then
  begin
    P^.LoginFailCount := 0;
    P^.LoginLockUntil := SecNow + Max(1, FCfg^.LoginLockMinutes) / 1440;
    Tell(Slot, Format('%s The account is locked for %d min.', [What, Max(1, FCfg^.LoginLockMinutes)]), CLR_BAD);
    FHost.Audit(Format('account #%d (%s): locked after failed logins, last from %s',
      [P^.ID, P^.ActiveName, Slots[Slot].IP]));
  end
  else if SourceLocked then
  begin
    Tell(Slot, Format('%s Logins to this account from here are locked for %d min.',
      [What, Max(1, FCfg^.LoginLockMinutes)]), CLR_BAD);
    FHost.Audit(Format('account #%d: logins from %s locked after failed attempts', [P^.ID, Slots[Slot].IP]));
  end
  else
    Tell(Slot, Format('%s (%d/%d)', [What, Shown, Limit]), CLR_BAD);
  FDB.Touch(Index);
end;

{ ---------------- commands ---------------- }

function TIdentityManager.HandleCommand(Slot: LongInt; const Words: TStringArray; FromChat: Boolean): Boolean;
var
  Cmd: AnsiString;
begin
  Result := False;
  if (Length(Words) = 0) or (Slot < 1) or (Slot > MAX_PLAYERS) or not Slots[Slot].InUse then
    Exit;
  Cmd := LowerCase(Words[0]);
  if (Cmd <> '') and (Cmd[1] in ['/', '!']) then
    Delete(Cmd, 1, 1);
  if (Cmd <> 'register') and (Cmd <> 'login') and (Cmd <> 'changepass') and (Cmd <> 'setemail') and
     (Cmd <> 'verifyemail') and (Cmd <> 'forgotpass') and (Cmd <> 'resetpass') and (Cmd <> 'account') and
     (Cmd <> 'removemypass') then
    Exit;
  Result := True;
  if not Slots[Slot].Human then
    Exit;
  if FromChat and ((Cmd = 'register') or (Cmd = 'login') or (Cmd = 'changepass') or (Cmd = 'resetpass') or
     (Cmd = 'removemypass')) then
  begin
    Tell(Slot, 'Never type passwords in chat - everyone can read it!', CLR_BAD);
    Tell(Slot, 'Use /' + Cmd + ' instead: slash commands are private.', CLR_BAD);
    if Length(Words) > 1 then
      Tell(Slot, 'If you just typed your real password, change it now.', CLR_BAD);
    Exit;
  end;
  if IsPending(Slot) then
  begin
    Tell(Slot, 'Your account is still being checked, try again in a few seconds.', CLR_WARN);
    Exit;
  end;
  if Cmd = 'account' then
  begin
    CmdAccount(Slot, Words);
    Exit;
  end;
  if IsSteamSession(Slot) then
  begin
    Tell(Slot, 'You play through Steam: Steam protects your account, no password is needed.', CLR_HINT);
    Exit;
  end;
  if Cmd = 'removemypass' then
    CmdRemovePass(Slot, Words)
  else if Cmd = 'register' then
    CmdRegister(Slot, Words)
  else if Cmd = 'login' then
    CmdLogin(Slot, Words)
  else if Cmd = 'changepass' then
    CmdChangePass(Slot, Words)
  else if Cmd = 'setemail' then
    CmdSetEmail(Slot, Words)
  else if Cmd = 'verifyemail' then
    CmdVerifyEmail(Slot, Words)
  else if Cmd = 'forgotpass' then
    CmdForgotPass(Slot, Words)
  else
    CmdResetPass(Slot, Words);
end;

procedure TIdentityManager.CmdRegister(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Idx: LongInt;
  Msg, Salt: AnsiString;
begin
  S := @Slots[Slot];
  Idx := ProfileIndex(Slot);
  if not FDB.Valid(Idx) then
  begin
    Tell(Slot, 'Statistics are off for this session, there is no account to register.', CLR_BAD);
    Exit;
  end;
  if S^.Locked then
  begin
    Tell(Slot, 'This account is already registered. Log in: /login <password>', CLR_WARN);
    Exit;
  end;
  if IsRegistered(FDB.Profiles[Idx]^) then
  begin
    Tell(Slot, 'Already registered. Change it: /changepass <old> <new> <new>', CLR_WARN);
    Exit;
  end;
  if Length(W) <> 3 then
  begin
    Tell(Slot, 'Usage: /register <password> <repeat password>', CLR_HINT);
    Exit;
  end;
  if W[1] <> W[2] then
  begin
    Tell(Slot, 'The passwords do not match.', CLR_BAD);
    Exit;
  end;
  if not ValidPassword(W[1], FDB.Profiles[Idx]^.ActiveName, Msg) then
  begin
    Tell(Slot, Msg, CLR_BAD);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  Salt := SecureRandomBytes(16);
  S^.PendingSalt := BytesToHex(Salt);
  { the account keeps the rounds its hash was made with, whatever the settings say by the answer }
  S^.PendingIter := Max(1, FCfg^.PasswordIterations);
  if SubmitHash(Slot, AUTH_REGISTER, FDB.Profiles[Idx]^.ID, W[1], Salt, S^.PendingIter, '', '') then
    Tell(Slot, 'Securing your password...', CLR_HINT);
end;

procedure TIdentityManager.CmdLogin(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Target, Cur, Mins: LongInt;
  Pw: AnsiString;
  P: PPlayerProfile;
begin
  S := @Slots[Slot];
  if (Length(W) < 2) or (Length(W) > 3) then
  begin
    Tell(Slot, 'Usage: /login <password>  or  /login <#id|name> <password>', CLR_HINT);
    Exit;
  end;
  Cur := ProfileIndex(Slot);
  if Length(W) = 3 then
  begin
    Target := FindAccountArg(W[1]);
    Pw := W[2];
  end
  else
  begin
    Pw := W[1];
    if S^.Locked then
      Target := Cur
    else if S^.LoginTargetId > 0 then
      Target := FDB.IndexOfId(S^.LoginTargetId)
    else
      Target := -1;
  end;
  if not FDB.Valid(Target) or not IsRegistered(FDB.Profiles[Target]^) then
  begin
    Tell(Slot, 'No registered account found. Try /login <#id> <password>', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Target];
  if IsRealSteam(P^.ActiveSteam) then
  begin
    Tell(Slot, 'That is a Steam account: it is played only through Steam.', CLR_BAD);
    Exit;
  end;
  if (Target = Cur) and not S^.Locked then
  begin
    Tell(Slot, 'You are already logged in.', CLR_GOOD);
    Exit;
  end;
  { every other session is checked: the first one found may be a locked one while another
    already plays the account }
  if PlayedElsewhere(P^.ID, Slot) then
  begin
    Tell(Slot, 'That account is already playing on this server.', CLR_BAD);
    Exit;
  end;
  Mins := LoginLockMinutes(Slot, Target);
  if Mins > 0 then
  begin
    Tell(Slot, Format('Too many failed attempts. Try again in %d min.', [Mins]), CLR_BAD);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  S^.LoginTargetId := P^.ID;
  SubmitHash(Slot, AUTH_LOGIN, P^.ID, Pw, HexToBytes(P^.PassSalt), P^.PassIter, '', '');
end;

procedure TIdentityManager.CmdChangePass(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Idx: LongInt;
  P: PPlayerProfile;
  Msg, Salt2: AnsiString;
begin
  S := @Slots[Slot];
  if Length(W) <> 4 then
  begin
    Tell(Slot, 'Usage: /changepass <old password> <new password> <new password>', CLR_HINT);
    Exit;
  end;
  Idx := ProfileIndex(Slot);
  if not FDB.Valid(Idx) or S^.Locked or not IsRegistered(FDB.Profiles[Idx]^) then
  begin
    Tell(Slot, 'Log in to a registered account first.', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Idx];
  if W[2] <> W[3] then
  begin
    Tell(Slot, 'The new passwords do not match.', CLR_BAD);
    Exit;
  end;
  if W[1] = W[2] then
  begin
    Tell(Slot, 'The new password must be different.', CLR_BAD);
    Exit;
  end;
  if not ValidPassword(W[2], P^.ActiveName, Msg) then
  begin
    Tell(Slot, Msg, CLR_BAD);
    Exit;
  end;
  if LoginLockMinutes(Slot, Idx) > 0 then
  begin
    Tell(Slot, 'Too many failed attempts. Try again later.', CLR_BAD);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  Salt2 := SecureRandomBytes(16);
  S^.PendingSalt := BytesToHex(Salt2);
  { the old password is checked with the rounds of the account, the new one is hashed with those
    of the settings - and stored with them }
  S^.PendingIter := Max(1, FCfg^.PasswordIterations);
  SubmitHash(Slot, AUTH_CHANGEPASS, P^.ID, W[1], HexToBytes(P^.PassSalt), P^.PassIter, W[2], Salt2, S^.PendingIter);
end;

{ /removemypass <password>: the account stops asking for a password at all }
procedure TIdentityManager.CmdRemovePass(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Idx: LongInt;
  P: PPlayerProfile;
begin
  S := @Slots[Slot];
  if not FCfg^.AllowPasswordRemoval then
  begin
    Tell(Slot, 'This server keeps account passwords: they cannot be removed.', CLR_WARN);
    Exit;
  end;
  if Length(W) <> 2 then
  begin
    Tell(Slot, 'Usage: /removemypass <password>', CLR_HINT);
    Exit;
  end;
  Idx := ProfileIndex(Slot);
  if not FDB.Valid(Idx) or S^.Locked or not IsRegistered(FDB.Profiles[Idx]^) then
  begin
    Tell(Slot, 'Log in to a registered account first.', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Idx];
  if LoginLockMinutes(Slot, Idx) > 0 then
  begin
    Tell(Slot, 'Too many failed attempts. Try again later.', CLR_BAD);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  SubmitHash(Slot, AUTH_REMOVEPASS, P^.ID, W[1], HexToBytes(P^.PassSalt), P^.PassIter, '', '');
end;

procedure TIdentityManager.CmdSetEmail(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Idx: LongInt;
  P: PPlayerProfile;
  Addr, Code, Msg: AnsiString;
  Sent: Boolean;
begin
  S := @Slots[Slot];
  if not FCfg^.MailEnabled then
  begin
    Tell(Slot, 'E-mail is not configured on this server.', CLR_BAD);
    Exit;
  end;
  if Length(W) <> 2 then
  begin
    Tell(Slot, 'Usage: /setemail <address>', CLR_HINT);
    Exit;
  end;
  Idx := ProfileIndex(Slot);
  if not FDB.Valid(Idx) or S^.Locked or not IsRegistered(FDB.Profiles[Idx]^) then
  begin
    Tell(Slot, 'Register first: /register <password> <password>', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Idx];
  Addr := Trim(W[1]);
  if (Length(Addr) > 64) or not IsValidEmail(Addr) then
  begin
    Tell(Slot, 'This e-mail address is not valid.', CLR_BAD);
    Exit;
  end;
  if not MailAllowed(Slot, Idx, Msg) then
  begin
    Tell(Slot, Msg, CLR_WARN);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  Code := RandomCode(CODE_LENGTH);
  Sent := SendCodeMail(Slot, Idx, AUTH_MAIL_VERIFY, Addr, Code);
  if Sent then
  begin
    P^.EmailPending := Addr;
    P^.EmailCodeHash := CodeHash(P^.ID, P^.PassSalt, Code);
    P^.EmailCodeExpire := SecNow + Max(1, FCfg^.MailCodeMinutes) / 1440;
    S^.CodeAttempts := 0;
  end;
  WipeString(Code);
  if Sent then
    Tell(Slot, 'Code sent to ' + MaskEmail(Addr) + '. Type /verifyemail <code>', CLR_GOOD);
end;

procedure TIdentityManager.CmdVerifyEmail(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Idx: LongInt;
  P: PPlayerProfile;
begin
  S := @Slots[Slot];
  if Length(W) <> 2 then
  begin
    Tell(Slot, 'Usage: /verifyemail <code>', CLR_HINT);
    Exit;
  end;
  Idx := ProfileIndex(Slot);
  if not FDB.Valid(Idx) or S^.Locked or not IsRegistered(FDB.Profiles[Idx]^) then
  begin
    Tell(Slot, 'Log in to a registered account first.', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Idx];
  if (P^.EmailPending = '') or (P^.EmailCodeHash = '') then
  begin
    Tell(Slot, 'No e-mail is waiting for verification. Use /setemail <address>', CLR_WARN);
    Exit;
  end;
  if (P^.EmailCodeExpire < SecNow) or not IsCodeHash(P^.EmailCodeHash) or
     (S^.CodeAttempts >= MAX_CODE_ATTEMPTS) then
  begin
    P^.EmailCodeHash := '';
    P^.EmailCodeExpire := 0;
    FDB.Touch(Idx);
    Tell(Slot, 'The code is no longer valid. Request a new one: /setemail <address>', CLR_BAD);
    Exit;
  end;
  if not ConstantTimeEquals(CodeHash(P^.ID, P^.PassSalt, W[1]), P^.EmailCodeHash) then
  begin
    Inc(S^.CodeAttempts);
    { the fifth wrong code ends the code }
    if S^.CodeAttempts >= MAX_CODE_ATTEMPTS then
    begin
      P^.EmailCodeHash := '';
      P^.EmailCodeExpire := 0;
      FDB.Touch(Idx);
      Tell(Slot, 'Wrong code. The code is no longer valid. Request a new one: /setemail <address>', CLR_BAD);
    end
    else
      Tell(Slot, Format('Wrong code (%d/%d).', [S^.CodeAttempts, MAX_CODE_ATTEMPTS]), CLR_BAD);
    Exit;
  end;
  P^.Email := P^.EmailPending;
  P^.EmailVerified := True;
  P^.EmailPending := '';
  P^.EmailCodeHash := '';
  P^.EmailCodeExpire := 0;
  FDB.Touch(Idx);
  FHost.Audit(Format('account #%d (%s): e-mail verified', [P^.ID, P^.ActiveName]));
  Tell(Slot, 'E-mail verified. You can recover your password with /forgotpass.', CLR_GOOD);
end;

procedure TIdentityManager.CmdForgotPass(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Target, Cur, k: LongInt;
  P: PPlayerProfile;
  Code, Msg: AnsiString;
  Sent: Boolean;
begin
  S := @Slots[Slot];
  if not FCfg^.MailEnabled then
  begin
    Tell(Slot, 'Password recovery by e-mail is not available here. Ask an admin.', CLR_BAD);
    Exit;
  end;
  if Length(W) > 2 then
  begin
    Tell(Slot, 'Usage: /forgotpass  or  /forgotpass <#id|name>', CLR_HINT);
    Exit;
  end;
  Cur := ProfileIndex(Slot);
  if Length(W) = 2 then
    Target := FindAccountArg(W[1])
  else if FDB.Valid(Cur) and IsRegistered(FDB.Profiles[Cur]^) then
    Target := Cur
  else
    Target := -1;
  if not FDB.Valid(Target) or not IsRegistered(FDB.Profiles[Target]^) or IsRealSteam(FDB.Profiles[Target]^.ActiveSteam) then
  begin
    Tell(Slot, 'No registered account found. Usage: /forgotpass <#id>', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Target];
  if not P^.EmailVerified or (P^.Email = '') then
  begin
    Tell(Slot, 'This account has no verified e-mail. Ask an admin for help.', CLR_BAD);
    Exit;
  end;
  if not MailAllowed(Slot, Target, Msg) then
  begin
    Tell(Slot, Msg, CLR_WARN);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  Code := RandomCode(CODE_LENGTH);
  { a code that never left the server does not replace one that may be on its way }
  Sent := SendCodeMail(Slot, Target, AUTH_MAIL_RESET, P^.Email, Code);
  if Sent then
  begin
    P^.ResetCodeHash := CodeHash(P^.ID, P^.PassSalt, Code);
    P^.ResetCodeExpire := SecNow + Max(1, FCfg^.MailCodeMinutes) / 1440;
    S^.LoginTargetId := P^.ID;
    S^.ResetTargetId := P^.ID;
    { a new code gets five tries of its own }
    k := FailRecord(P^.ID, 'C', False);
    if k >= 0 then
    begin
      FFails[k].Count := 0;
      FFails[k].Since := SecNow;
    end;
  end;
  WipeString(Code);
  if not Sent then
    Exit;
  FHost.Audit(Format('account #%d (%s): password reset requested from %s', [P^.ID, P^.ActiveName, S^.IP]));
  Tell(Slot, 'A reset code was sent to the e-mail address of this account.', CLR_GOOD);
  Tell(Slot, 'Then type: /resetpass <code> <new password> <new password>', CLR_HINT);
end;

procedure TIdentityManager.CmdResetPass(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Target, k: LongInt;
  P: PPlayerProfile;
  Msg, Salt: AnsiString;
begin
  S := @Slots[Slot];
  if Length(W) <> 4 then
  begin
    Tell(Slot, 'Usage: /resetpass <code> <new password> <new password>', CLR_HINT);
    Exit;
  end;
  { the account this session asked a code for - /login #id does not choose it - or, for a session
    waiting for /login on a registered account, that account }
  Target := FDB.IndexOfId(S^.ResetTargetId);
  if not FDB.Valid(Target) and S^.Locked then
    Target := ProfileIndex(Slot);
  if not FDB.Valid(Target) or not IsRegistered(FDB.Profiles[Target]^) then
  begin
    Tell(Slot, 'Request a code first: /forgotpass', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Target];
  if not IsCodeHash(P^.ResetCodeHash) or (P^.ResetCodeExpire < SecNow) then
  begin
    P^.ResetCodeHash := '';
    P^.ResetCodeExpire := 0;
    FDB.Touch(Target);
    Tell(Slot, 'No valid reset code. Request a new one: /forgotpass', CLR_BAD);
    Exit;
  end;
  if not ConstantTimeEquals(CodeHash(P^.ID, P^.PassSalt, W[1]), P^.ResetCodeHash) then
  begin
    { wrong codes count on the account, from every session and every join: the fifth ends the code }
    k := FailRecord(P^.ID, 'C', True);
    Inc(FFails[k].Count);
    if FFails[k].Count >= MAX_CODE_ATTEMPTS then
    begin
      FFails[k].Count := 0;
      P^.ResetCodeHash := '';
      P^.ResetCodeExpire := 0;
      FDB.Touch(Target);
      FHost.Audit(Format('account #%d: password reset code ended after %d wrong codes, the last from %s',
        [P^.ID, MAX_CODE_ATTEMPTS, S^.IP]));
      Tell(Slot, 'Wrong code. The code is no longer valid. Request a new one: /forgotpass', CLR_BAD);
    end
    else
      Tell(Slot, Format('Wrong code (%d/%d).', [FFails[k].Count, MAX_CODE_ATTEMPTS]), CLR_BAD);
    Exit;
  end;
  if W[2] <> W[3] then
  begin
    Tell(Slot, 'The new passwords do not match.', CLR_BAD);
    Exit;
  end;
  if not ValidPassword(W[2], P^.ActiveName, Msg) then
  begin
    Tell(Slot, Msg, CLR_BAD);
    Exit;
  end;
  if AuthThrottled(Slot) then
    Exit;
  Salt := SecureRandomBytes(16);
  S^.PendingSalt := BytesToHex(Salt);
  S^.PendingIter := Max(1, FCfg^.PasswordIterations);
  SubmitHash(Slot, AUTH_RESETPASS, P^.ID, W[2], Salt, S^.PendingIter, '', '');
end;

procedure TIdentityManager.CmdAccount(Slot: LongInt; const W: TStringArray);
var
  S: ^TSlotIdentity;
  Idx, k, Trusted: LongInt;
  P: PPlayerProfile;
  Mail: AnsiString;
begin
  S := @Slots[Slot];
  Idx := ProfileIndex(Slot);
  if not FDB.Valid(Idx) then
  begin
    Tell(Slot, 'Statistics are off for this session.', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Idx];
  if IsRealSteam(P^.ActiveSteam) then
  begin
    Tell(Slot, Format('Account #%d %s: Steam account, protected by Steam.', [P^.ID, P^.ActiveName]), CLR_GOOD);
    Exit;
  end;
  if not IsRegistered(P^) then
  begin
    Tell(Slot, Format('Account #%d %s belongs to this computer and has no password.', [P^.ID, P^.ActiveName]), CLR_HINT);
    Tell(Slot, 'Protect it with a password: /register <password> <password>', CLR_HINT);
    Exit;
  end;
  if S^.Locked then
  begin
    Tell(Slot, Format('Account #%d %s is registered - you are not logged in.', [P^.ID, P^.ActiveName]), CLR_WARN);
    Exit;
  end;
  if (Length(W) = 2) and SameText(W[1], 'untrust') then
  begin
    DropTrustedDevices(Idx, '', '');
    Tell(Slot, 'All computers will have to log in again.', CLR_GOOD);
    Exit;
  end;
  { the owner decides whether this account may skip the password on a known computer }
  if (Length(W) >= 2) and SameText(W[1], 'trust') then
  begin
    if not FCfg^.TrustedDevicesEnabled then
    begin
      Tell(Slot, 'This server never remembers computers: the password is always needed.', CLR_HINT);
      Exit;
    end;
    if not FCfg^.AllowTrustChoice then
    begin
      Tell(Slot, 'Only the server admin can change that here.', CLR_WARN);
      Exit;
    end;
    if Length(W) < 3 then
    begin
      Tell(Slot, 'Usage: /account trust on   (skip the password on a computer you logged in from)', CLR_HINT);
      Tell(Slot, '       /account trust off  (ask for the password every time, on every computer)', CLR_HINT);
      Exit;
    end;
    if SameText(W[2], 'off') then
    begin
      P^.NoTrustedDevices := True;
      DropTrustedDevices(Idx, '', '');
      FDB.Touch(Idx);
      FHost.Audit(Format('account #%d (%s): trusted computers turned off', [P^.ID, P^.ActiveName]));
      Tell(Slot, 'Done: this account always asks for the password, on every computer.', CLR_GOOD);
    end
    else if SameText(W[2], 'on') then
    begin
      P^.NoTrustedDevices := False;
      AddTrustedDevice(Idx, S^.Hwid, S^.IP);
      FDB.Touch(Idx);
      FHost.Audit(Format('account #%d (%s): trusted computers turned on', [P^.ID, P^.ActiveName]));
      if DeviceTrusted(P^, S^.Hwid, S^.IP) then
        Tell(Slot, Format('Done: this computer stays trusted for %d day(s).', [FCfg^.TrustedDeviceDays]), CLR_GOOD)
      else
        Tell(Slot, 'Done, but this server remembers no computer: the password is needed every time.', CLR_HINT);
    end
    else
      Tell(Slot, 'Usage: /account trust on | /account trust off', CLR_HINT);
    Exit;
  end;
  Trusted := 0;
  for k := 0 to High(P^.TrustedDevices) do
    if (P^.TrustedDevices[k].Expire >= SecNow) and (P^.TrustedDevices[k].LastUsed >= P^.PassSetTime) then
      Inc(Trusted);
  if P^.Email = '' then
    Mail := 'no e-mail'
  else
    Mail := MaskEmail(P^.Email);
  Tell(Slot, Format('Account #%d %s: registered, %s, %d trusted computer(s).', [P^.ID, P^.ActiveName, Mail, Trusted]), CLR_GOOD);
  if not FCfg^.TrustedDevicesEnabled then
    Tell(Slot, 'This server never remembers computers: the password is needed every time.', CLR_HINT)
  else if P^.NoTrustedDevices then
    Tell(Slot, 'Trusted computers: off for this account (the password is needed every time).', CLR_HINT)
  else
    Tell(Slot, Format('Trusted computers: on, %d day(s), same network required: %s.',
      [FCfg^.TrustedDeviceDays, BoolToStr(FCfg^.TrustDeviceSameIP, 'yes', 'no')]), CLR_HINT);
  if FCfg^.TrustedDevicesEnabled and FCfg^.AllowTrustChoice then
    Tell(Slot, '/changepass  /setemail  /account untrust  /account trust on|off', CLR_HINT)
  else
    Tell(Slot, '/changepass  /setemail  /account untrust', CLR_HINT);
end;

{ ---------------- service results ---------------- }

procedure TIdentityManager.HandleServiceResult(const R: TServiceResult);
var
  Slot, Idx, k, Iter: LongInt;
  S: ^TSlotIdentity;
  P: PPlayerProfile;
  SaltHex, Why: AnsiString;
  Op: TAdminOp;
  Found: Boolean;
begin
  if R.Kind = svMail then
  begin
    Slot := R.Slot;
    if (Slot >= 1) and (Slot <= MAX_PLAYERS) and Slots[Slot].InUse and (Slots[Slot].MailTag = R.Tag) then
    begin
      Slots[Slot].MailTag := 0;
      if not R.Ok then
        Tell(Slot, 'Sending the e-mail failed. Try again later.', CLR_BAD);
    end;
    if not R.Ok then
      FHost.Audit('mail: delivery failed: ' + R.Message);
    Exit;
  end;
  { the service thread answers every webhook too: the console says when one did not arrive }
  if R.Kind = svHttpPost then
  begin
    if not R.Ok then
    begin
      Why := R.Message;
      if Why = '' then
        Why := 'curl ended with an error';
      FHost.Tell(0, '[ZitroStats] webhook not delivered: ' + Why, CLR_BAD);
    end;
    Exit;
  end;
  if R.Kind <> svHash then
    Exit;

  if R.Op = AUTH_ADMINSET then
  begin
    Found := False;
    for k := 0 to High(FAdminOps) do
      if FAdminOps[k].Tag = R.Tag then
      begin
        Op := FAdminOps[k];
        FAdminOps[k] := FAdminOps[High(FAdminOps)];
        SetLength(FAdminOps, Length(FAdminOps) - 1);
        Found := True;
        Break;
      end;
    Idx := FDB.IndexOfId(R.ProfileId);
    if Found and R.Ok and FDB.Valid(Idx) then
    begin
      P := FDB.Profiles[Idx];
      FDB.BeginIdentityChange(Idx);
      P^.PassHash := R.Hash;
      P^.PassSalt := Op.SaltHex;
      P^.PassIter := Op.Iterations;
      P^.PassSetTime := SecNow;
      P^.TrustedDevices := nil;
      P^.LoginFailCount := 0;
      P^.LoginLockUntil := 0;
      FDB.EndIdentityChange(Idx);
      FDB.Touch(Idx);
      FHost.Audit(Format('account #%d (%s): password set by an admin', [P^.ID, P^.ActiveName]));
    end;
    Exit;
  end;

  Slot := R.Slot;
  if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Exit;
  S := @Slots[Slot];
  if not S^.InUse or (S^.PendingTag <> R.Tag) then
    Exit; { the player left, or the request belongs to an earlier session }
  S^.PendingTag := 0;
  SaltHex := S^.PendingSalt;
  S^.PendingSalt := '';
  Iter := Max(1, S^.PendingIter);
  S^.PendingIter := 0;
  Idx := FDB.IndexOfId(R.ProfileId);
  if not R.Ok or not FDB.Valid(Idx) then
  begin
    Tell(Slot, 'The account changed meanwhile, please try again.', CLR_BAD);
    Exit;
  end;
  P := FDB.Profiles[Idx];
  case R.Op of
    AUTH_REGISTER:
      begin
        if IsRegistered(P^) or (ProfileIndex(Slot) <> Idx) or S^.Locked then
          Exit;
        FDB.BeginIdentityChange(Idx);
        P^.PassHash := R.Hash;
        P^.PassSalt := SaltHex;
        P^.PassIter := Iter;
        P^.PassSetTime := SecNow;
        P^.LoginFailCount := 0;
        P^.LoginLockUntil := 0;
        FDB.EndIdentityChange(Idx);
        AddTrustedDevice(Idx, S^.Hwid, S^.IP);
        FDB.Touch(Idx);
        FHost.Audit(Format('account #%d (%s): registered from %s', [P^.ID, P^.ActiveName, S^.IP]));
        { the computer is remembered only when the server and the account allow it }
        if DeviceTrusted(P^, S^.Hwid, S^.IP) then
          Tell(Slot, Format('Registered! This computer stays logged in for %d days.', [FCfg^.TrustedDeviceDays]), CLR_GOOD)
        else
          Tell(Slot, 'Registered! Log in with /login <password> every time you join.', CLR_GOOD);
        if FCfg^.MailEnabled then
          Tell(Slot, 'Add an e-mail for password recovery: /setemail <address>', CLR_HINT);
      end;
    AUTH_LOGIN:
      begin
        if not IsRegistered(P^) then
          Exit;
        if ConstantTimeEquals(R.Hash, P^.PassHash) then
          LoginSucceeded(Slot, Idx)
        else
          LoginFailed(Slot, Idx, 'Wrong password.');
      end;
    AUTH_CHANGEPASS:
      begin
        if not IsRegistered(P^) or (ProfileIndex(Slot) <> Idx) or S^.Locked then
          Exit;
        if not ConstantTimeEquals(R.Hash, P^.PassHash) then
        begin
          LoginFailed(Slot, Idx, 'The current password is wrong.');
          Exit;
        end;
        P^.PassHash := R.Hash2;
        P^.PassSalt := SaltHex;
        P^.PassSetTime := SecNow;
        { the rounds the new hash was made with (the settings' at the request) }
        P^.PassIter := Iter;
        DropTrustedDevices(Idx, S^.Hwid, S^.IP);
        FDB.Touch(Idx);
        FHost.Audit(Format('account #%d (%s): password changed from %s', [P^.ID, P^.ActiveName, S^.IP]));
        Tell(Slot, 'Password changed. Other computers must log in again.', CLR_GOOD);
      end;
    AUTH_REMOVEPASS:
      begin
        if not IsRegistered(P^) or (ProfileIndex(Slot) <> Idx) or S^.Locked then
          Exit;
        if not ConstantTimeEquals(R.Hash, P^.PassHash) then
        begin
          LoginFailed(Slot, Idx, 'The password is wrong.');
          Exit;
        end;
        P^.PassHash := '';
        P^.PassSalt := '';
        P^.PassIter := 0;
        P^.PassSetTime := 0;
        P^.ResetCodeHash := '';
        P^.ResetCodeExpire := 0;
        DropTrustedDevices(Idx, '', '');
        FDB.Touch(Idx);
        FHost.Audit(Format('account #%d (%s): password removed from %s', [P^.ID, P^.ActiveName, S^.IP]));
        Tell(Slot, 'Password removed. Anyone on this computer now plays on this account.', CLR_WARN);
        Tell(Slot, 'Protect it again any time with /register <password> <password>.', CLR_HINT);
      end;
    AUTH_RESETPASS:
      begin
        if not IsRegistered(P^) then
          Exit;
        P^.PassHash := R.Hash;
        P^.PassSalt := SaltHex;
        P^.PassIter := Iter;
        P^.PassSetTime := SecNow;
        DropTrustedDevices(Idx, '', '');
        P^.ResetCodeHash := '';
        P^.ResetCodeExpire := 0;
        FDB.Touch(Idx);
        FHost.Audit(Format('account #%d (%s): password reset by e-mail code from %s', [P^.ID, P^.ActiveName, S^.IP]));
        Tell(Slot, 'Your password has been reset.', CLR_GOOD);
        LoginSucceeded(Slot, Idx);
      end;
  end;
end;

{ ---------------- admin ---------------- }

function TIdentityManager.AdminSetPassword(Index: LongInt; const Password: AnsiString; out Msg: AnsiString): Boolean;
var
  Salt: AnsiString;
  n: LongInt;
begin
  Result := False;
  if not FDB.Valid(Index) then
  begin
    Msg := 'No such account.';
    Exit;
  end;
  if IsRealSteam(FDB.Profiles[Index]^.ActiveSteam) then
  begin
    Msg := 'Steam accounts have no password.';
    Exit;
  end;
  if not ValidPassword(Password, FDB.Profiles[Index]^.ActiveName, Msg) then
    Exit;
  Salt := SecureRandomBytes(16);
  if not SubmitHash(0, AUTH_ADMINSET, FDB.Profiles[Index]^.ID, Password, Salt, FCfg^.PasswordIterations, '', '') then
  begin
    Msg := 'The service thread is busy, try again.';
    Exit;
  end;
  n := Length(FAdminOps);
  SetLength(FAdminOps, n + 1);
  FAdminOps[n].Tag := FNextTag;
  FAdminOps[n].ProfileId := FDB.Profiles[Index]^.ID;
  FAdminOps[n].SaltHex := BytesToHex(Salt);
  FAdminOps[n].Iterations := Max(1, FCfg^.PasswordIterations);
  Msg := Format('Setting the password of #%d...', [FDB.Profiles[Index]^.ID]);
  Result := True;
end;

procedure TIdentityManager.AdminUnregister(Index: LongInt);
var
  P: PPlayerProfile;
  k: LongInt;
begin
  if not FDB.Valid(Index) then
    Exit;
  P := FDB.Profiles[Index];
  FDB.BeginIdentityChange(Index);
  P^.PassHash := '';
  P^.PassSalt := '';
  P^.PassIter := 0;
  P^.PassSetTime := 0;
  P^.Email := '';
  P^.EmailVerified := False;
  P^.EmailPending := '';
  P^.EmailCodeHash := '';
  P^.EmailCodeExpire := 0;
  P^.ResetCodeHash := '';
  P^.ResetCodeExpire := 0;
  P^.LoginFailCount := 0;
  P^.LoginLockUntil := 0;
  P^.TrustedDevices := nil;
  FDB.EndIdentityChange(Index);
  FDB.Touch(Index);
  for k := 1 to MAX_PLAYERS do
    if Slots[k].InUse and (Slots[k].ProfileId = P^.ID) and Slots[k].Locked then
      Bind(k, Index, True);
  FHost.Audit(Format('account #%d (%s): registration removed by an admin', [P^.ID, P^.ActiveName]));
end;

end.
