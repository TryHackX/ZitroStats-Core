program test_identity;

{ zs_identity: Steam accounts by SteamID, computer accounts by HWID, the wait for Steam and the
  optional passwords of computer accounts. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, zs_types, zs_util, zs_config, zs_fields, zs_db, zs_service, zs_identity;

type
  TTestHost = class(TIdentityHost)
  public
    Messages: TStringList;
    Audits: TStringList;
    Jobs: array of TServiceJob;
    LastMail: AnsiString;
    Spectated: LongInt;
    Kicked: LongInt;
    Changes: LongInt;
    Returned: LongInt;
    RefuseJobs: Boolean;   { the service queue is full }
    constructor Create;
    destructor Destroy; override;
    procedure Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt); override;
    procedure Audit(const Text: AnsiString); override;
    procedure ForceSpectator(Slot: LongInt); override;
    procedure ReturnToGame(Slot: LongInt); override;
    procedure KickPlayer(Slot: LongInt; const Reason: AnsiString); override;
    function SubmitJob(const Job: TServiceJob): Boolean; override;
    procedure SessionProfileChanged(Slot, OldProfileId, NewProfileId: LongInt); override;
  end;

constructor TTestHost.Create;
begin
  inherited Create;
  Messages := TStringList.Create;
  Audits := TStringList.Create;
end;

destructor TTestHost.Destroy;
begin
  Messages.Free;
  Audits.Free;
  inherited Destroy;
end;

procedure TTestHost.Tell(Slot: LongInt; const Text: AnsiString; Color: LongInt);
begin
  Messages.Add(IntToStr(Slot) + ':' + Text);
end;

procedure TTestHost.Audit(const Text: AnsiString);
begin
  Audits.Add(Text);
end;

procedure TTestHost.ForceSpectator(Slot: LongInt);
begin
  Inc(Spectated);
end;

procedure TTestHost.ReturnToGame(Slot: LongInt);
begin
  Inc(Returned);
end;

procedure TTestHost.KickPlayer(Slot: LongInt; const Reason: AnsiString);
begin
  Inc(Kicked);
end;

function TTestHost.SubmitJob(const Job: TServiceJob): Boolean;
begin
  Result := not RefuseJobs;
  if not Result then
    Exit;
  SetLength(Jobs, Length(Jobs) + 1);
  Jobs[High(Jobs)] := Job;
end;

procedure TTestHost.SessionProfileChanged(Slot, OldProfileId, NewProfileId: LongInt);
begin
  Inc(Changes);
end;

var
  Failures: Integer = 0;
  Cfg: TZSConfig;
  DB: TStatsDB;
  Host: TTestHost;
  Id: TIdentityManager;
  Svc: TServiceThread;
  T: Double;

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

procedure Advance(Seconds: Double);
begin
  T := T + Seconds / 86400;
  DB.SetNow(T);
  Id.Tick;
end;

{ the hashes are made by the service thread itself; the mails only keep their text }
procedure RunJobs;
var
  J: TServiceJob;
  R: TServiceResult;
  k: LongInt;
  T0: Int64;
begin
  while Length(Host.Jobs) > 0 do
  begin
    J := Host.Jobs[0];
    for k := 1 to High(Host.Jobs) do
      Host.Jobs[k - 1] := Host.Jobs[k];
    SetLength(Host.Jobs, Length(Host.Jobs) - 1);
    if J.Kind = svHash then
    begin
      Svc.Enqueue(J);
      T0 := MonoMs;
      while not Svc.PollResult(R) do
      begin
        if MonoMs - T0 > 30000 then
        begin
          WriteLn('       no answer from the service thread');
          Exit;
        end;
        Sleep(1);
      end;
    end
    else
    begin
      R.Kind := J.Kind;
      R.Tag := J.Tag;
      R.Slot := J.Slot;
      R.ProfileId := J.ProfileId;
      R.Op := J.Op;
      R.Ok := True;
      R.Hash := '';
      R.Hash2 := '';
      R.Message := '';
      R.ElapsedMs := 0;
      if J.Kind = svMail then
        Host.LastMail := J.Body;
    end;
    Id.HandleServiceResult(R);
  end;
end;

procedure Cmd(Slot: LongInt; const Text: AnsiString; FromChat: Boolean = False);
begin
  Id.HandleCommand(Slot, SplitWords(Text), FromChat);
end;

function Said(Slot: LongInt; const Part: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to Host.Messages.Count - 1 do
    if (Copy(Host.Messages[k], 1, Length(IntToStr(Slot)) + 1) = IntToStr(Slot) + ':') and
       (Pos(Part, Host.Messages[k]) > 0) then
      Exit(True);
end;

function ExtractCode(const Body: AnsiString): AnsiString;
var
  L: TStringList;
  k: LongInt;
begin
  Result := '';
  L := TStringList.Create;
  L.Text := Body;
  for k := 0 to L.Count - 1 do
    if (Copy(L[k], 1, 4) = '    ') and (Length(Trim(L[k])) = 8) then
      Result := Trim(L[k]);
  L.Free;
end;

function Prof(Slot: LongInt): PPlayerProfile;
begin
  if Id.ProfileIndex(Slot) >= 0 then
    Result := DB.Profiles[Id.ProfileIndex(Slot)]
  else
    Result := nil;
end;

function ById(ProfileId: LongInt): PPlayerProfile;
begin
  if DB.IndexOfId(ProfileId) >= 0 then
    Result := DB.Profiles[DB.IndexOfId(ProfileId)]
  else
    Result := nil;
end;

var
  AliceId, AliceSteamId, BobId, DaveId, GhostId, EveId, FinnId, Live, k: LongInt;
  Code, Hash0: AnsiString;
  WR: TServiceResult;
begin
  SetConfigDefaults(Cfg);
  Cfg.PasswordIterations := 500;
  Cfg.MailEnabled := True;
  Cfg.MailFrom := 'noreply@example.com';
  Cfg.UnauthenticatedAction := 'spectator';
  Svc := TServiceThread.Create;
  DB := TStatsDB.Create;
  Host := TTestHost.Create;
  Id := TIdentityManager.Create(DB, @Cfg, Host);
  T := EncodeDate(2026, 9, 15) + EncodeTime(12, 0, 0, 0);
  DB.SetNow(T);

  Check('steam id formats', (NormalizeSteam('S123') = 'S123') and (NormalizeSteam('123') = 'S123') and
    (NormalizeSteam('[U:1:123]') = 'S123') and (NormalizeSteam('76561197960265851') = 'S123') and
    (NormalizeSteam('0') = '') and (NormalizeSteam('abc') = '') and (NormalizeSteam('S0') = ''));
  Check('ip ranges', (IpPrefix('1.2.3.4') = '1.2.3') and (IpPrefix('2001:db8:1:2:3::1') = '2001:db8:1:2'));

  { no SteamID at the join: no account and no statistics until Steam answers }
  Id.Join(1, 'Alice', '', 'HW-A', '1.2.3.4', True);
  Check('waiting for Steam: no account yet', Id.IsPending(1) and (Id.Slots[1].ProfileId = 0) and
    (Id.StatsIndex(1) = -1) and (DB.LiveProfiles = 0));
  Advance(9);
  AliceId := Id.Slots[1].ProfileId;
  Check('no Steam answer: the account of the computer', not Id.IsPending(1) and (AliceId > 0) and
    (Id.StatsIndex(1) >= 0) and (Prof(1)^.ActiveHWID = 'HW-A') and (Prof(1)^.ActiveSteam = ''));
  Prof(1)^.Kills := 5;
  Prof(1)^.TimePlayed := 120;
  Id.Leave(1);

  { Steam refuses the session: the computer account at once }
  Id.Join(2, 'Alice2', '', 'HW-A', '1.2.3.4', True);
  Id.SteamAuthFailed(2);
  Check('failed Steam check: computer account at once', (Id.Slots[2].ProfileId = AliceId) and not Id.IsPending(2));
  Check('names are free, the history grows', (Prof(2)^.ActiveName = 'Alice2') and (Length(Prof(2)^.OtherNames) = 2));
  Id.Leave(2);

  { Steam confirms within the wait: a Steam account, separate from the computer account }
  Live := DB.LiveProfiles;
  Id.Join(3, 'Alice', '', 'HW-A', '1.2.3.4', True);
  Advance(1);
  Id.SteamAuth(3, '76561197960266283');
  AliceSteamId := Id.Slots[3].ProfileId;
  Check('Steam account, never merged with the computer account', (AliceSteamId <> AliceId) and
    (Prof(3)^.ActiveSteam = 'S555') and (Prof(3)^.Kills = 0) and (ById(AliceId)^.Kills = 5) and
    (DB.LiveProfiles = Live + 1));
  Prof(3)^.Kills := 1;
  Id.Leave(3);

  Id.Join(4, 'Whoever', 'S555', 'HW-OTHER', '9.9.9.9', True);
  Check('Steam account follows the SteamID on any computer and under any name',
    (Id.Slots[4].ProfileId = AliceSteamId) and not Id.IsPending(4) and (Prof(4)^.ActiveName = 'Whoever'));
  Id.Leave(4);

  Id.Join(5, 'Alice', '', 'HW-A', '1.2.3.4', True);
  Advance(9);
  Check('the same computer without Steam: the computer account, not the Steam one', Id.Slots[5].ProfileId = AliceId);
  Id.Leave(5);

  { the same name on another computer: another account }
  Id.Join(6, 'Alice', '', 'HW-B', '5.6.7.8', True);
  Advance(9);
  BobId := Id.Slots[6].ProfileId;
  Check('names do not pick accounts', (BobId > 0) and (BobId <> AliceId) and (BobId <> AliceSteamId));
  Prof(6)^.Kills := 7;
  Prof(6)^.TimePlayed := 300;

  { a second game on the same computer }
  Host.Messages.Clear;
  Id.Join(7, 'Twin', '', 'HW-B', '5.6.7.8', True);
  Advance(9);
  Check('a computer account is not shared by two sessions', (Id.Slots[7].ProfileId = 0) and
    (Id.StatsIndex(7) = -1) and Said(7, 'already playing'));
  Id.Leave(7);
  Id.Leave(6);

  { Steam answers after the wait: the player moves to the Steam account }
  Id.Join(8, 'Dave', 'S888', 'HW-X', '4.4.4.4', True);
  DaveId := Id.Slots[8].ProfileId;
  Prof(8)^.Kills := 10;
  Prof(8)^.TimePlayed := 500;
  Id.Leave(8);
  Id.Join(9, 'Dave', '', 'HW-D', '4.4.4.5', True);
  Advance(9);
  GhostId := Id.Slots[9].ProfileId;
  Check('late Steam: the computer account first', (GhostId > 0) and (GhostId <> DaveId));
  Id.SteamAuth(9, 'S888');
  Check('late Steam: moved to the Steam account, the unused computer account removed',
    (Id.Slots[9].ProfileId = DaveId) and (ById(GhostId) = nil) and (Prof(9)^.Kills = 10));
  Host.Messages.Clear;
  Cmd(9, '/register secretpw1 secretpw1');
  Check('Steam players need no password', (Length(Host.Jobs) = 0) and Said(9, 'Steam'));
  Id.Leave(9);

  { a password for a computer account }
  Id.Join(10, 'Bob', '', 'HW-B', '5.6.7.8', True);
  Advance(9);
  Check('back on the computer account', Id.Slots[10].ProfileId = BobId);
  Host.Messages.Clear;
  Cmd(10, '/register secretpw1 secretpw1');
  RunJobs;
  Check('register', (ById(BobId)^.PassHash <> '') and (Length(ById(BobId)^.TrustedDevices) = 1) and Said(10, 'Registered'));
  Advance(3);
  Cmd(10, '/register secretpw1 secretpw1');
  Check('register twice refused', Said(10, 'Already registered'));
  Id.Leave(10);

  { the same HWID from another network (for example a copied HWID): locked until /login }
  Host.Messages.Clear;
  Id.Join(11, 'Mallory', '', 'HW-B', '7.7.7.7', True);
  Advance(9);
  Check('registered computer account locked on another network', (Id.Slots[11].ProfileId = BobId) and
    Id.Slots[11].Locked and (Id.StatsIndex(11) = -1));
  Check('login reminder', Said(11, 'password protected'));
  Cmd(11, '/login wrongpass');
  RunJobs;
  Check('wrong password counted', (ById(BobId)^.LoginFailCount = 1) and Said(11, '(1/5)'));
  Advance(61);
  Check('grace action applied', Host.Spectated = 1);
  Id.Leave(11);

  { the owner on a new computer: an own account there, and /login #id moves the session }
  Id.Join(12, 'Bob', '', 'HW-NEW', '5.6.7.8', True);
  Advance(9);
  GhostId := Id.Slots[12].ProfileId;
  Check('a new computer gets its own account', (GhostId > 0) and (GhostId <> BobId) and not Id.Slots[12].Locked);
  Prof(12)^.Kills := 3;
  Advance(3);
  Cmd(12, Format('/login #%d secretpw1', [BobId]));
  RunJobs;
  Check('login from a new computer', (Id.Slots[12].ProfileId = BobId) and not Id.Slots[12].Locked and
    (ById(GhostId) = nil) and (ById(BobId)^.Kills = 10) and (Length(ById(BobId)^.TrustedDevices) = 2));
  Id.Leave(12);

  Id.Join(13, 'Bob', '', 'HW-NEW', '5.6.7.9', True);
  Advance(9);
  Check('a trusted computer finds the account without a login', (Id.Slots[13].ProfileId = BobId) and
    not Id.Slots[13].Locked);
  Id.Leave(13);

  Id.Join(14, 'Bob', '', 'HW-B', '5.6.7.8', True);
  Advance(9);
  Check('the first computer still works', (Id.Slots[14].ProfileId = BobId) and not Id.Slots[14].Locked);
  SetLength(Host.Jobs, 0);
  Host.Messages.Clear;
  Cmd(14, '!login secretpw1', True);
  Check('password in public chat refused', (Length(Host.Jobs) = 0) and Said(14, 'Never type passwords'));
  Id.Leave(14);

  { lock after failures, password change, e-mail }
  Host.Messages.Clear;
  Id.Join(15, 'Bob', '', 'HW-B', '8.8.8.8', True);
  Advance(9);
  Check('locked again from another network', Id.Slots[15].Locked);
  for k := 1 to 5 do
  begin
    Advance(3);
    Cmd(15, '/login bad' + IntToStr(k) + 'xx');
    RunJobs;
  end;
  Check('account locked after 5 failures', (ById(BobId)^.LoginLockUntil > T) and Said(15, 'locked'));
  Advance(3);
  Cmd(15, '/login secretpw1');
  Check('locked account refuses even the right password', (Length(Host.Jobs) = 0) and Said(15, 'Too many failed'));
  Advance(16 * 60);
  Cmd(15, '/login secretpw1');
  RunJobs;
  Check('login after the lock expires', not Id.Slots[15].Locked);

  Advance(3);
  Hash0 := ById(BobId)^.PassHash;
  Cmd(15, '/changepass wrongold newpass22 newpass22');
  RunJobs;
  Check('change password needs the old one', (ById(BobId)^.PassHash = Hash0) and Said(15, 'current password is wrong'));
  Advance(3);
  Cmd(15, '/changepass secretpw1 newpass22 newpass22');
  RunJobs;
  Check('password changed, other computers dropped', (ById(BobId)^.PassHash <> Hash0) and
    (Length(ById(BobId)^.TrustedDevices) = 1));

  Advance(3);
  Cmd(15, '/setemail bob@example.com');
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Check('verification mail with a code', (Length(Code) = 8) and (ById(BobId)^.EmailPending = 'bob@example.com'));
  Cmd(15, '/verifyemail WRONG123');
  Check('wrong code rejected', not ById(BobId)^.EmailVerified and Said(15, 'Wrong code'));
  Cmd(15, '/verifyemail ' + LowerCase(Code));
  Check('e-mail verified', ById(BobId)^.EmailVerified and (ById(BobId)^.Email = 'bob@example.com'));
  Id.Leave(15);

  { password reset from yet another computer }
  Host.Messages.Clear;
  Id.Join(16, 'Bob', '', 'HW-R', '3.3.3.3', True);
  Advance(9);
  Cmd(16, Format('/forgotpass #%d', [BobId]));
  Check('mail interval respected', Said(16, 'Please wait'));
  Advance(11 * 60);
  Cmd(16, Format('/forgotpass #%d', [BobId]));
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Check('reset mail sent without showing the address', (Length(Code) = 8) and Said(16, 'reset code was sent') and
    not Said(16, '@example.com'));
  Advance(3);
  Cmd(16, '/resetpass ' + Code + ' resetpw99 resetpw99');
  RunJobs;
  Check('reset logs the player in on this computer', (Id.Slots[16].ProfileId = BobId) and not Id.Slots[16].Locked and
    (ById(BobId)^.ResetCodeHash = '') and Said(16, 'has been reset'));
  Advance(3);
  Hash0 := ById(BobId)^.PassHash;
  Cmd(16, '/resetpass ' + Code + ' again777 again777');
  Check('reset code works once', (Length(Host.Jobs) = 0) and (ById(BobId)^.PassHash = Hash0) and Said(16, '/forgotpass'));
  Id.Leave(16);

  { the owner can ask for the password on every computer }
  Host.Messages.Clear;
  Id.Join(24, 'Bob', '', 'HW-R', '3.3.3.3', True);
  Advance(9);
  Check('a trusted computer needs no password', not Id.Slots[24].Locked);
  Cmd(24, '/account trust off');
  Check('trusting off clears the list',
    ById(BobId)^.NoTrustedDevices and (Length(ById(BobId)^.TrustedDevices) = 0) and Said(24, 'every computer'));
  Id.Leave(24);
  Id.Join(25, 'Bob', '', 'HW-R', '3.3.3.3', True);
  Advance(9);
  Check('the same computer now asks for the password', Id.Slots[25].Locked);
  Cmd(25, '/login resetpw99');
  RunJobs;
  Check('login still works with trusting off',
    not Id.Slots[25].Locked and (Length(ById(BobId)^.TrustedDevices) = 0));
  Cmd(25, '/account trust on');
  Check('trusting on again remembers this computer',
    not ById(BobId)^.NoTrustedDevices and (Length(ById(BobId)^.TrustedDevices) = 1));
  Cfg.AllowTrustChoice := False;
  Cmd(25, '/account trust off');
  Check('the server can forbid the choice',
    not ById(BobId)^.NoTrustedDevices and Said(25, 'server admin'));
  Cfg.AllowTrustChoice := True;
  Id.Leave(25);

  { /removemypass: off by default, then the password really goes away }
  Host.Messages.Clear;
  Id.Join(22, 'Bob', '', 'HW-R', '3.3.3.3', True);
  Advance(9);
  Cmd(22, Format('/login #%d resetpw99', [BobId]));
  RunJobs;
  Check('logged in for the password removal',
    (Id.Slots[22].ProfileId = BobId) and not Id.Slots[22].Locked);
  Advance(3);
  Cmd(22, '/removemypass resetpw99');
  Check('removing the password is refused while the setting is off',
    (Length(Host.Jobs) = 0) and (ById(BobId)^.PassHash <> '') and Said(22, 'cannot be removed'));
  Cfg.AllowPasswordRemoval := True;
  Advance(3);
  Cmd(22, '/removemypass wrongpass1');
  RunJobs;
  Check('a wrong password keeps the account protected',
    (ById(BobId)^.PassHash <> '') and Said(22, 'password is wrong'));
  Advance(3);
  Cmd(22, '/removemypass resetpw99');
  RunJobs;
  Check('the password is gone and nothing is trusted any more',
    (ById(BobId)^.PassHash = '') and (ById(BobId)^.PassSalt = '') and
    (Length(ById(BobId)^.TrustedDevices) = 0) and Said(22, 'Password removed'));
  Id.Leave(22);
  Host.Messages.Clear;
  Id.Join(23, 'Bob', '', 'HW-R', '9.9.9.9', True);
  Advance(9);
  Check('the account is open again after the removal', not Id.Slots[23].Locked and (Id.StatsIndex(23) >= 0));
  { put the password back, the checks below expect a registered account }
  Advance(3);
  Cmd(23, '/register resetpw99 resetpw99');
  RunJobs;
  Check('the account can be protected again', ById(BobId)^.PassHash <> '');
  Id.Leave(23);
  Cfg.AllowPasswordRemoval := False;

  { two sessions log in to one account at the same moment: the password is checked on another
    thread, so both requests pass the first check; only one of them gets the account }
  Host.Messages.Clear;
  Id.Join(26, 'Bob', '', 'HW-R', '6.1.1.1', True);
  Advance(9);
  Id.Join(27, 'Bob2', '', 'HW-Q', '6.2.2.2', True);
  Advance(9);
  Check('one session locked on the account, one on its own', Id.Slots[26].Locked and
    (Id.Slots[26].ProfileId = BobId) and not Id.Slots[27].Locked and (Id.Slots[27].ProfileId <> BobId));
  { failed logins far apart do not add up to a lock }
  for k := 1 to 4 do
  begin
    Advance(3);
    Cmd(27, Format('/login #%d wrong%dxx', [BobId, k]));
    RunJobs;
  end;
  Advance(20 * 60);
  Cmd(27, Format('/login #%d wrong5xx', [BobId]));
  RunJobs;
  Check('failures older than the lock time do not count', (ById(BobId)^.LoginFailCount = 1) and
    (ById(BobId)^.LoginLockUntil < T));
  Advance(3);
  Cmd(26, '/login resetpw99');
  Cmd(27, Format('/login #%d resetpw99', [BobId]));
  RunJobs;
  Check('only one of two logins at once gets the account', not Id.Slots[26].Locked and
    (Id.Slots[26].ProfileId = BobId) and (Id.Slots[27].ProfileId <> BobId) and Said(27, 'already playing'));
  Id.Leave(27);

  { the service queue refuses the mail: nothing is claimed and nothing counts }
  Advance(11 * 60);
  Host.Messages.Clear;
  k := ById(BobId)^.MailSentToday;
  Host.RefuseJobs := True;
  Cmd(26, '/setemail other@example.com');
  Host.RefuseJobs := False;
  Check('a refused mail is not reported as sent', Said(26, 'busy') and not Said(26, 'Code sent') and
    (ById(BobId)^.EmailPending = '') and (ById(BobId)^.MailSentToday = k));
  Id.Leave(26);

  Id.Join(17, 'Bot', '', '', '', False);
  Check('bots get no account', (Id.ProfileIndex(17) = -1) and (Id.StatsIndex(17) = -1));
  Id.Leave(17);

  Host.Messages.Clear;
  Id.Join(18, 'NoId', '', '', '2.2.2.2', True);
  Advance(9);
  Check('no HWID and no Steam: statistics off', (Id.Slots[18].ProfileId = 0) and Said(18, 'no computer ID'));
  Id.Leave(18);

  Host.Messages.Clear;
  Id.Join(19, 'Carol', '', 'HW-C', '1.2.3.4', True);
  Advance(9);
  Cmd(19, '/register 123456 123456');
  Cmd(19, '/register abc abc');
  Cmd(19, '/register goodpass1 goodpass2');
  Check('password rules', Said(19, 'too easy') and Said(19, 'must have') and Said(19, 'do not match') and
    (Length(Host.Jobs) = 0));
  Id.Leave(19);

  Id.Join(20, 'Bob', '', 'HW-R', '6.6.6.6', True);
  Advance(9);
  Check('locked before unregister', Id.Slots[20].Locked);
  Id.AdminUnregister(DB.IndexOfId(BobId));
  Check('unregister unlocks sessions', not Id.Slots[20].Locked and (ById(BobId)^.PassHash = '') and
    not ById(BobId)^.EmailVerified);
  Id.Leave(20);

  Live := DB.LiveProfiles;
  Id.Join(21, 'Visitor', '', 'HW-V', '1.1.1.1', True);
  Advance(9);
  Id.Leave(21);
  Check('an empty short visit leaves no account', DB.LiveProfiles = Live);

  { the rounds of the password hash change in the settings: /changepass checks the old password
    with the account's rounds, hashes the new one with the new rounds and stores those }
  Id.Join(28, 'Eve', '', 'HW-E', '7.1.1.1', True);
  Advance(9);
  EveId := Id.Slots[28].ProfileId;
  Cmd(28, '/register evepass1 evepass1');
  RunJobs;
  Check('register stores the rounds of its hash', (EveId > 0) and (ById(EveId)^.PassIter = 500));
  Cfg.PasswordIterations := 700;
  Advance(3);
  Host.Messages.Clear;
  Cmd(28, '/changepass evepass1 evepass22 evepass22');
  RunJobs;
  Check('the password changed with other rounds in the settings', Said(28, 'Password changed') and
    (ById(EveId)^.PassIter = 700));
  Id.Leave(28);
  Id.Join(29, 'Eve', '', 'HW-E2', '7.2.2.2', True);
  Advance(9);
  Host.Messages.Clear;
  Cmd(29, Format('/login #%d evepass22', [EveId]));
  RunJobs;
  Check('the new password logs in after the rounds changed', (Id.Slots[29].ProfileId = EveId) and
    not Id.Slots[29].Locked and Said(29, 'Logged in'));
  Id.Leave(29);

  { settings reloaded while a hash is made: the account keeps the rounds its hash was made with }
  Id.Join(30, 'Finn', '', 'HW-F', '7.3.3.3', True);
  Advance(9);
  FinnId := Id.Slots[30].ProfileId;
  Cfg.PasswordIterations := 600;
  Cmd(30, '/register finnpass1 finnpass1');
  Cfg.PasswordIterations := 800;
  RunJobs;
  Check('register keeps the rounds its hash was made with', (FinnId > 0) and (ById(FinnId)^.PassIter = 600));
  Id.Leave(30);
  Id.Join(30, 'Finn', '', 'HW-F2', '7.3.3.9', True);
  Advance(9);
  Cmd(30, Format('/login #%d finnpass1', [FinnId]));
  RunJobs;
  Check('and its password logs in', (Id.Slots[30].ProfileId = FinnId) and not Id.Slots[30].Locked);
  Id.Leave(30);

  { without trusted computers the registration promises no days without a password }
  Cfg.TrustedDevicesEnabled := False;
  Id.Join(31, 'Gil', '', 'HW-G', '7.4.4.4', True);
  Advance(9);
  Host.Messages.Clear;
  Cmd(31, '/register gilpass1 gilpass1');
  RunJobs;
  Check('register without trusted computers says the password is needed every time', Said(31, 'Registered') and
    not Said(31, 'stays logged in') and Said(31, 'every time'));
  Id.Leave(31);
  Cfg.TrustedDevicesEnabled := True;

  { the service thread answers the webhooks too: one that did not arrive reaches the console }
  Host.Messages.Clear;
  WR.Kind := svHttpPost;
  WR.Tag := 0;
  WR.Slot := 0;
  WR.ProfileId := 0;
  WR.Op := 0;
  WR.Ok := False;
  WR.Hash := '';
  WR.Hash2 := '';
  WR.Message := 'curl: (22) The requested URL returned error: 404';
  WR.ElapsedMs := 0;
  Id.HandleServiceResult(WR);
  Check('a webhook that did not arrive is written to the console', Said(0, 'webhook not delivered') and
    Said(0, 'error: 404'));

  Id.Free;
  Host.Free;
  DB.Free;
  Svc.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
