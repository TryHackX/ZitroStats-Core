program test_fix_ws5b;

{ Audit fixes of 2026-10-06, accounts and passwords (WS5B): the three-way merges of the account
  security fields (Engine = mysql), the locks after wrong passwords, the reset codes, the e-mail
  limits, the times in UTC and the API for other scripts. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_config, zs_fields, zs_db, zs_service, zs_identity, zs_engine;

type
  TTestHost = class(TIdentityHost)
  public
    Messages: TStringList;
    Audits: TStringList;
    Jobs: array of TServiceJob;
    LastMail, LastSubject: AnsiString;
    Mails: LongInt;
    Spectated: LongInt;
    Kicked: LongInt;
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
end;

procedure TTestHost.KickPlayer(Slot: LongInt; const Reason: AnsiString);
begin
  Inc(Kicked);
end;

function TTestHost.SubmitJob(const Job: TServiceJob): Boolean;
begin
  Result := True;
  SetLength(Jobs, Length(Jobs) + 1);
  Jobs[High(Jobs)] := Job;
end;

procedure TTestHost.SessionProfileChanged(Slot, OldProfileId, NewProfileId: LongInt);
begin
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

{ a new server: an empty database, the default settings with quick hashes and e-mail on }
procedure Fresh;
begin
  if Id <> nil then
  begin
    Id.Free;
    Host.Free;
    DB.Free;
  end;
  SetConfigDefaults(Cfg);
  Cfg.PasswordIterations := 500;
  Cfg.MailEnabled := True;
  Cfg.MailFrom := 'noreply@example.com';
  DB := TStatsDB.Create;
  Host := TTestHost.Create;
  Id := TIdentityManager.Create(DB, @Cfg, Host);
  T := EncodeDate(2026, 9, 15) + EncodeTime(12, 0, 0, 0);
  DB.SetNow(T);
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
      begin
        Host.LastMail := J.Body;
        Host.LastSubject := J.Subject;
        Inc(Host.Mails);
      end;
    end;
    Id.HandleServiceResult(R);
  end;
end;

procedure Cmd(Slot: LongInt; const Text: AnsiString);
begin
  Id.HandleCommand(Slot, SplitWords(Text), False);
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

function ById(ProfileId: LongInt): PPlayerProfile;
begin
  if DB.IndexOfId(ProfileId) >= 0 then
    Result := DB.Profiles[DB.IndexOfId(ProfileId)]
  else
    Result := nil;
end;

{ a player joins without Steam and gets the account of the computer at once }
procedure JoinNow(Slot: LongInt; const Name, Hwid, IP: AnsiString);
begin
  Id.Join(Slot, Name, '', Hwid, IP, True);
  Id.SteamAuthFailed(Slot);
  Advance(3);
end;

{ a new account with a password, registered from Hwid / IP; the player leaves }
function Registered(Slot: LongInt; const Name, Hwid, IP, Pw: AnsiString): LongInt;
begin
  JoinNow(Slot, Name, Hwid, IP);
  Result := Id.Slots[Slot].ProfileId;
  Cmd(Slot, '/register ' + Pw + ' ' + Pw);
  RunJobs;
  Advance(3);
end;

function Device(const Hwid, Prefix: AnsiString; Expire, LastUsed: Double): TTrustedDevice;
begin
  Result.HWID := Hwid;
  Result.IPPrefix := Prefix;
  Result.Expire := Expire;
  Result.LastUsed := LastUsed;
end;

function HasDevice(const P: TPlayerProfile; const Hwid: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(P.TrustedDevices) do
    if P.TrustedDevices[k].HWID = Hwid then
      Exit(True);
end;

function NameAt(const P: TPlayerProfile; const Name: AnsiString): LongInt;
var
  k: LongInt;
begin
  Result := -1;
  for k := 0 to High(P.OtherNames) do
    if SameText(OtherDataToString(P.OtherNames[k]), Name) then
      Exit(k);
end;

procedure AddName(var P: TPlayerProfile; const Name: AnsiString; LastUsedDate: Double);
var
  n: LongInt;
begin
  n := Length(P.OtherNames);
  SetLength(P.OtherNames, n + 1);
  FillChar(P.OtherNames[n], SizeOf(TOtherData), 0);
  SetOtherDataString(P.OtherNames[n], Name);
  P.OtherNames[n].FirstUsedDate := LastUsedDate;
  P.OtherNames[n].LastUsedDate := LastUsedDate;
end;

{ ---------------- ZSI-12: the password merged as one ---------------- }

procedure TestPasswordMerge;
var
  PB, PR, P1: TPlayerProfile;
begin
  ClearProfile(PB);
  PB.ID := 7;
  PB.PassHash := 'H0';
  PB.PassSalt := 'S0';
  PB.PassIter := 100000;
  PB.PassSetTime := 100;
  { another server changed the password with other rounds, this one with the same rounds as before }
  PR := PB;
  PR.PassHash := 'H2';
  PR.PassSalt := 'S2';
  PR.PassIter := 200000;
  PR.PassSetTime := 102;
  P1 := PB;
  P1.PassHash := 'H1';
  P1.PassSalt := 'S1';
  P1.PassSetTime := 101;
  Merge3Profile(P1, PB, PR);
  Check('ZSI-12 a password changed here comes whole from here (hash, salt, rounds, date)',
    (P1.PassHash = 'H1') and (P1.PassSalt = 'S1') and (P1.PassIter = 100000) and (P1.PassSetTime = 101));
  P1 := PB;
  Merge3Profile(P1, PB, PR);
  Check('ZSI-12 a password changed only on another server comes whole from there',
    (P1.PassHash = 'H2') and (P1.PassSalt = 'S2') and (P1.PassIter = 200000) and (P1.PassSetTime = 102));
  { only the rounds differ here (an old record): still the whole password of this server }
  P1 := PB;
  P1.PassIter := 150000;
  Merge3Profile(P1, PB, PR);
  Check('ZSI-12 any of the four changed here keeps all four of this server',
    (P1.PassHash = 'H0') and (P1.PassSalt = 'S0') and (P1.PassIter = 150000) and (P1.PassSetTime = 100));
  { /removemypass here, nothing there: the password is gone everywhere }
  P1 := PB;
  P1.PassHash := '';
  P1.PassSalt := '';
  P1.PassIter := 0;
  P1.PassSetTime := 0;
  PR := PB;
  Merge3Profile(P1, PB, PR);
  Check('ZSI-12 a password removed here stays removed', (P1.PassHash = '') and (P1.PassSalt = '') and
    (P1.PassIter = 0) and (P1.PassSetTime = 0));
end;

{ ---------------- ZSI-01: trusted computers and names merged three ways ---------------- }

procedure TestTrustedMerge;
var
  PB, PR, P1: TPlayerProfile;
  k: LongInt;
  Ok: Boolean;
begin
  { the reviewer's t_merge3trusted: /changepass here keeps only this computer, the database is
    unchanged (Remote = Base) }
  ClearProfile(PB);
  PB.ID := 9;
  PB.PassHash := 'OLDHASH';
  PB.PassSetTime := 10;
  SetLength(PB.TrustedDevices, 2);
  PB.TrustedDevices[0] := Device('HWID-HOME', '1.2.3', 40, 10);
  PB.TrustedDevices[1] := Device('HWID-INTRUDER', '9.9.9', 45, 15);
  PR := PB;
  P1 := PB;
  P1.PassHash := 'NEWHASH';
  P1.PassSetTime := 20;
  P1.TrustedDevices := nil;
  SetLength(P1.TrustedDevices, 1);
  P1.TrustedDevices[0] := Device('HWID-HOME', '1.2.3', 50, 20);
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 a computer removed by /changepass does not come back from the database',
    (Length(P1.TrustedDevices) = 1) and HasDevice(P1, 'HWID-HOME') and not HasDevice(P1, 'HWID-INTRUDER') and
    (P1.PassHash = 'NEWHASH'));
  Check('ZSI-01 the computer kept here has the dates of this server', (Length(P1.TrustedDevices) = 1) and
    (P1.TrustedDevices[0].LastUsed = 20) and (P1.TrustedDevices[0].Expire = 50));
  Check('ZSI-01 the original records are not changed by the merge', (Length(PB.TrustedDevices) = 2) and
    (Length(PR.TrustedDevices) = 2));

  { the database removed one (another server), nothing changed here }
  P1 := PB;
  PR := PB;
  PR.TrustedDevices := nil;
  SetLength(PR.TrustedDevices, 1);
  PR.TrustedDevices[0] := PB.TrustedDevices[0];
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 a computer removed on another server stays removed', (Length(P1.TrustedDevices) = 1) and
    HasDevice(P1, 'HWID-HOME'));

  { added on both sides: both stay; /account untrust here clears everything }
  P1 := PB;
  P1.TrustedDevices := Copy(PB.TrustedDevices);
  SetLength(P1.TrustedDevices, 3);
  P1.TrustedDevices[2] := Device('HWID-LAPTOP', '5.5.5', 60, 30);
  PR := PB;
  PR.TrustedDevices := Copy(PB.TrustedDevices);
  SetLength(PR.TrustedDevices, 3);
  PR.TrustedDevices[2] := Device('HWID-WORK', '6.6.6', 61, 31);
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 computers added here and on another server both stay', (Length(P1.TrustedDevices) = 4) and
    HasDevice(P1, 'HWID-LAPTOP') and HasDevice(P1, 'HWID-WORK') and HasDevice(P1, 'HWID-INTRUDER'));
  P1 := PB;
  P1.TrustedDevices := nil;
  PR := PB;
  PR.TrustedDevices := Copy(PB.TrustedDevices);
  SetLength(PR.TrustedDevices, 3);
  PR.TrustedDevices[2] := Device('HWID-WORK', '6.6.6', 61, 31);
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 /account untrust here keeps only what another server added since',
    (Length(P1.TrustedDevices) = 1) and HasDevice(P1, 'HWID-WORK'));

  { the same computer on both sides keeps the later dates }
  P1 := PB;
  P1.TrustedDevices := Copy(PB.TrustedDevices);
  P1.TrustedDevices[0].Expire := 70;
  PR := PB;
  PR.TrustedDevices := Copy(PB.TrustedDevices);
  PR.TrustedDevices[0].LastUsed := 33;
  Merge3Profile(P1, PB, PR);
  Ok := False;
  for k := 0 to High(P1.TrustedDevices) do
    if P1.TrustedDevices[k].HWID = 'HWID-HOME' then
      Ok := (P1.TrustedDevices[k].Expire = 70) and (P1.TrustedDevices[k].LastUsed = 33);
  Check('ZSI-01 a computer on both sides keeps the later dates', Ok and (Length(P1.TrustedDevices) = 2));

  { two servers that each add computers: never more than MAX_TRUSTED_DEVICES, the oldest go }
  ClearProfile(PB);
  PB.ID := 9;
  P1 := PB;
  PR := PB;
  SetLength(P1.TrustedDevices, 5);
  SetLength(PR.TrustedDevices, 5);
  for k := 0 to 4 do
  begin
    P1.TrustedDevices[k] := Device('HW-A' + IntToStr(k), '1.1.1', 100, 10 + k * 2);
    PR.TrustedDevices[k] := Device('HW-B' + IntToStr(k), '2.2.2', 100, 11 + k * 2);
  end;
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 the merged list keeps at most 8 computers, the least recently added go',
    (Length(P1.TrustedDevices) = MAX_TRUSTED_DEVICES) and not HasDevice(P1, 'HW-A0') and not HasDevice(P1, 'HW-B0') and
    HasDevice(P1, 'HW-A1') and HasDevice(P1, 'HW-B4'));
end;

procedure TestNameMerge;
var
  NDB: TStatsDB;
  Idx, Round: LongInt;
  PB, PR, P1: TPlayerProfile;
  T0: Double;
begin
  { the reviewer's t_merge3names: NameHistoryLimit 3, one new name each round, the database
    unchanged by other servers: the list stays at 3 - also without a limit given to the merge, as
    in the exchange thread of zs_sqldb }
  NDB := TStatsDB.Create;
  T0 := EncodeDate(2026, 9, 1);
  NDB.SetNow(T0);
  Idx := NDB.CreateProfile('Name0', '', 'HW-N', '1.1.1.1', 1000);
  NDB.NoteName(Idx, 'Name0', True, 0, 0, 3);
  for Round := 1 to 5 do
  begin
    PB := NDB.Profiles[Idx]^;
    UniqueProfileLists(PB);
    PR := PB;
    NDB.SetNow(T0 + Round);
    NDB.NoteName(Idx, 'Name' + IntToStr(Round), True, 0, 0, 3);
    Merge3Profile(NDB.Profiles[Idx]^, PB, PR);
  end;
  P1 := NDB.Profiles[Idx]^;
  Check('ZSI-01 a name forgotten by NameHistoryLimit does not come back from the database',
    (Length(P1.OtherNames) = 3) and (NameAt(P1, 'Name0') < 0) and (NameAt(P1, 'Name2') < 0) and
    (NameAt(P1, 'Name5') >= 0));
  NDB.Free;

  { a name forgotten here but used on another server since: it stays }
  ClearProfile(PB);
  PB.ID := 4;
  AddName(PB, 'Old', 10);
  AddName(PB, 'Mid', 11);
  PR := PB;
  PR.OtherNames := Copy(PB.OtherNames);
  PR.OtherNames[0].LastUsedDate := 15;
  P1 := PB;
  P1.OtherNames := Copy(PB.OtherNames);
  P1.OtherNames[0] := P1.OtherNames[1];
  SetLength(P1.OtherNames, 1);
  AddName(P1, 'New', 14);
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 a name dropped here but used on another server since stays', (NameAt(P1, 'Old') >= 0) and
    (NameAt(P1, 'Mid') >= 0) and (NameAt(P1, 'New') >= 0) and (Length(P1.OtherNames) = 3));
  { the same with a limit: the least recently used goes }
  P1 := PB;
  P1.OtherNames := Copy(PB.OtherNames);
  P1.OtherNames[0] := P1.OtherNames[1];
  SetLength(P1.OtherNames, 1);
  AddName(P1, 'New', 14);
  Merge3Profile(P1, PB, PR, 2);
  Check('ZSI-01 the merged names are cut to NameHistoryLimit, the least recently used go',
    (Length(P1.OtherNames) = 2) and (NameAt(P1, 'Old') >= 0) and (NameAt(P1, 'New') >= 0) and (NameAt(P1, 'Mid') < 0));
  { the first start with the database (Base empty): the names of both sides }
  ClearProfile(PB);
  ClearProfile(P1);
  ClearProfile(PR);
  AddName(P1, 'Here', 5);
  AddName(PR, 'There', 6);
  Merge3Profile(P1, PB, PR);
  Check('ZSI-01 with an empty base the names of both sides stay', (Length(P1.OtherNames) = 2) and
    (NameAt(P1, 'Here') >= 0) and (NameAt(P1, 'There') >= 0));
end;

procedure TestTrustAfterPasswordChange;
var
  BobId, k: LongInt;
  Intruder: TTrustedDevice;
  Idx: LongInt;
begin
  Fresh;
  BobId := Registered(1, 'Bob', 'HW-HOME', '1.2.3.4', 'secretpw1');
  Id.Leave(1);
  { somebody who learnt the password logs in from their own computer: it becomes trusted }
  JoinNow(2, 'Mal', 'HW-INTRUDER', '9.9.9.9');
  Cmd(2, Format('/login #%d secretpw1', [BobId]));
  RunJobs;
  Check('ZSI-01 setup: the intruder''s computer is trusted after /login #id', (Id.Slots[2].ProfileId = BobId) and
    not Id.Slots[2].Locked and HasDevice(ById(BobId)^, 'HW-INTRUDER'));
  Id.Leave(2);
  Idx := DB.IndexOfId(BobId);
  Intruder.HWID := '';
  for k := 0 to High(ById(BobId)^.TrustedDevices) do
    if ById(BobId)^.TrustedDevices[k].HWID = 'HW-INTRUDER' then
      Intruder := ById(BobId)^.TrustedDevices[k];
  { the owner changes the password at home a minute later }
  Advance(60);
  JoinNow(3, 'Bob', 'HW-HOME', '1.2.3.4');
  Check('ZSI-01 setup: the owner is on the account at home', (Id.Slots[3].ProfileId = BobId) and not Id.Slots[3].Locked);
  Cmd(3, '/changepass secretpw1 newpass22 newpass22');
  RunJobs;
  Check('ZSI-01 setup: /changepass keeps only the current computer', (Length(ById(BobId)^.TrustedDevices) = 1) and
    HasDevice(ById(BobId)^, 'HW-HOME'));
  Id.Leave(3);
  { a database exchange of 5.6 (or another server's old record) brings the intruder back }
  DB.BeginIdentityChange(Idx);
  k := Length(DB.Profiles[Idx]^.TrustedDevices);
  SetLength(DB.Profiles[Idx]^.TrustedDevices, k + 1);
  DB.Profiles[Idx]^.TrustedDevices[k] := Intruder;
  DB.EndIdentityChange(Idx);
  Advance(60);
  Host.Messages.Clear;
  JoinNow(4, 'Mal', 'HW-INTRUDER', '9.9.9.9');
  Check('ZSI-01 a computer trusted before the password change is not trusted any more',
    (Id.Slots[4].ProfileId <> BobId) or Id.Slots[4].Locked);
  Check('ZSI-01 and the player is told to log in to that account', Said(4, Format('#%d', [BobId])));
  Id.Leave(4);
  JoinNow(5, 'Bob', 'HW-HOME', '1.2.3.9');
  Check('ZSI-01 the computer of the password change stays trusted', (Id.Slots[5].ProfileId = BobId) and
    not Id.Slots[5].Locked);
  Id.Leave(5);
end;

{ ---------------- ZSI-09: the security times in UTC ---------------- }

procedure TestUtcTimes;
var
  BobId: LongInt;
  U: Double;
  P: PPlayerProfile;
begin
  Check('ZSI-09 local time to UTC and back', SameValue(UtcToLocal(LocalToUtc(T)), T, 1e-9) and
    SameValue(LocalToUtc(T), T + GetLocalTimeOffset / 1440, 1e-9) and (UtcToLocal(0) = 0));
  Fresh;
  BobId := Registered(1, 'Bob', 'HW-B', '5.6.7.8', 'secretpw1');
  P := ById(BobId);
  U := LocalToUtc(T - 3 / 86400);
  Check('ZSI-09 the date of the password is UTC', SameValue(P^.PassSetTime, U, 1e-9));
  Check('ZSI-09 the trusted computer has its dates in UTC', (Length(P^.TrustedDevices) = 1) and
    SameValue(P^.TrustedDevices[0].LastUsed, U, 1e-9) and SameValue(P^.TrustedDevices[0].Expire, U + 30, 1e-9));
  Id.Leave(1);
  { a lock another server wrote (UTC, 10 minutes from now) holds here, whatever the time zone }
  P^.LoginLockUntil := LocalToUtc(T) + 10 / 1440;
  JoinNow(2, 'Bob', 'HW-B', '9.9.9.9');
  Host.Messages.Clear;
  Cmd(2, '/login secretpw1');
  Check('ZSI-09 a lock in UTC is honoured', (Length(Host.Jobs) = 0) and Said(2, 'Try again in 10 min'));
  P^.LoginLockUntil := LocalToUtc(T) - 1 / 1440;
  Advance(3);
  Cmd(2, '/login secretpw1');
  RunJobs;
  Check('ZSI-09 a lock that ended in UTC lets the owner in', not Id.Slots[2].Locked);
  { the e-mail codes and the time of the last mail }
  Advance(3);
  Cmd(2, '/setemail bob@example.com');
  RunJobs;
  Check('ZSI-09 the e-mail code expires in UTC and the last mail is UTC',
    SameValue(P^.EmailCodeExpire, LocalToUtc(T) + Cfg.MailCodeMinutes / 1440, 1e-9) and
    SameValue(P^.MailLastSent, LocalToUtc(T), 1e-9));
  Id.Leave(2);
end;

{ ---------------- ZSI-02: wrong passwords lock their source, not the owner ---------------- }

procedure TestLockPerSource;
var
  BobId, k, n: LongInt;
begin
  Fresh;
  Cfg.UnauthenticatedAction := 'kick';
  BobId := Registered(1, 'Bob', 'HW-B', '5.6.7.8', 'secretpw1');
  Id.Leave(1);
  { the owner plays from a new network: his computer, not trusted there }
  JoinNow(2, 'Bob', 'HW-B', '9.9.9.9');
  Check('ZSI-02 setup: the owner waits for /login on a new network', (Id.Slots[2].ProfileId = BobId) and Id.Slots[2].Locked);
  { a stranger tries 5 wrong passwords on the account (the reviewer's t_lockout) }
  JoinNow(3, 'Eve', 'HW-E', '7.7.7.7');
  for k := 1 to 5 do
  begin
    Advance(3);
    Cmd(3, Format('/login #%d wrong%dxx', [BobId, k]));
    RunJobs;
  end;
  Check('ZSI-02 the stranger is locked after 5 wrong passwords', Said(3, 'locked for 15 min'));
  Advance(3);
  Host.Messages.Clear;
  Cmd(3, Format('/login #%d secretpw1', [BobId]));
  Check('ZSI-02 the stranger''s computer gets no more tries', (Length(Host.Jobs) = 0) and Said(3, 'Too many failed'));
  Check('ZSI-02 the account itself is not locked by one source', ById(BobId)^.LoginLockUntil < LocalToUtc(T));
  { another computer in the stranger's network, and the stranger's computer elsewhere }
  JoinNow(4, 'Eve2', 'HW-E2', '7.7.7.200');
  Host.Messages.Clear;
  Cmd(4, Format('/login #%d wrong9xx', [BobId]));
  Check('ZSI-02 the lock holds for the stranger''s network', (Length(Host.Jobs) = 0) and Said(4, 'Too many failed'));
  Id.Leave(3);
  JoinNow(3, 'Eve', 'HW-E', '8.8.4.4');
  Host.Messages.Clear;
  Cmd(3, Format('/login #%d wrong9xx', [BobId]));
  Check('ZSI-02 the lock holds for the stranger''s computer on another network', (Length(Host.Jobs) = 0) and
    Said(3, 'Too many failed'));
  { the owner, from another source, logs in with the right password }
  Advance(3);
  Host.Messages.Clear;
  Cmd(2, '/login secretpw1');
  RunJobs;
  Check('ZSI-02 an attacker''s 5 wrong passwords do not lock the owner on another network',
    (Id.Slots[2].ProfileId = BobId) and not Id.Slots[2].Locked and Said(2, 'Logged in'));
  Check('ZSI-02 the owner is not kicked', Host.Kicked = 0);
  Id.Leave(2);
  Id.Leave(3);
  Id.Leave(4);

  { somebody else in the owner's own network does not lock the owner's computer either }
  JoinNow(5, 'Bob', 'HW-B', '9.9.9.9');
  Check('ZSI-02 setup: the owner''s new network is trusted now', not Id.Slots[5].Locked);
  Id.Leave(5);
  JoinNow(6, 'Bob', 'HW-B', '6.6.6.6');
  JoinNow(7, 'Neighbour', 'HW-N', '6.6.6.7');
  for k := 1 to 5 do
  begin
    Advance(3);
    Cmd(7, Format('/login #%d bad%dxxx', [BobId, k]));
    RunJobs;
  end;
  Advance(3);
  Host.Messages.Clear;
  Cmd(6, '/login secretpw1');
  RunJobs;
  Check('ZSI-02 wrong passwords from the same network do not lock the owner''s computer', not Id.Slots[6].Locked and
    Said(6, 'Logged in'));
  Id.Leave(6);
  Id.Leave(7);

  { many networks together: the account is locked for everybody, the owner is neither kicked nor
    moved while it lasts, and the countdown starts again when it ends }
  Fresh;
  Cfg.UnauthenticatedAction := 'kick';
  BobId := Registered(1, 'Bob', 'HW-B', '5.6.7.8', 'secretpw1');
  Id.Leave(1);
  for n := 0 to 3 do
  begin
    JoinNow(10 + n, 'X' + IntToStr(n), 'HW-X' + IntToStr(n), Format('10.0.%d.1', [n]));
    for k := 1 to 5 do
    begin
      Advance(3);
      Cmd(10 + n, Format('/login #%d bad%d%dxx', [BobId, n, k]));
      RunJobs;
    end;
    Id.Leave(10 + n);
  end;
  Check('ZSI-02 20 wrong passwords from four networks lock the account',
    (ById(BobId)^.LoginLockUntil > LocalToUtc(T)) and Said(13, 'The account is locked'));
  JoinNow(2, 'Bob', 'HW-B', '9.9.9.9');
  Host.Messages.Clear;
  Cmd(2, '/login secretpw1');
  Check('ZSI-02 the account lock holds for the owner too', (Length(Host.Jobs) = 0) and Said(2, 'Too many failed'));
  Advance(61);
  for k := 1 to 58 do
    Advance(15);
  Check('ZSI-02 the owner is not kicked while others locked the account', Host.Kicked = 0);
  Advance(61);
  Check('ZSI-02 the countdown runs again once that lock is over', Host.Kicked = 1);
  Id.Leave(2);

  { the owner's own wrong passwords still lead to the action }
  JoinNow(3, 'Bob', 'HW-B', '9.9.9.9');
  for k := 1 to 5 do
  begin
    Advance(3);
    Cmd(3, Format('/login mine%dxx', [k]));
    RunJobs;
  end;
  Advance(61);
  Check('ZSI-02 a player locked by his own wrong passwords gets the action', Host.Kicked = 2);
  Id.Leave(3);
end;

{ the code of the last mail: the indented line of letters and digits }
function ExtractCode(const Body: AnsiString): AnsiString;
var
  L: TStringList;
  k: LongInt;
begin
  Result := '';
  L := TStringList.Create;
  L.Text := Body;
  for k := 0 to L.Count - 1 do
    if (Copy(L[k], 1, 4) = '    ') and (Length(Trim(L[k])) >= 8) then
      Result := Trim(L[k]);
  L.Free;
end;

{ ---------------- ZSI-05: the reset code belongs to /forgotpass, five wrong codes end it ---------------- }

procedure TestResetCodes;
var
  BobId, k: LongInt;
  Code, Hash0: AnsiString;
begin
  Fresh;
  Cfg.MailMaxPerDay := 10;
  BobId := Registered(1, 'Bob', 'HW-B', '5.6.7.8', 'secretpw1');
  Cmd(1, '/setemail bob@example.com');
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Cmd(1, '/verifyemail ' + Code);
  Check('ZSI-05 setup: a verified e-mail', ById(BobId)^.EmailVerified);
  { the e-mail code: the fifth wrong code ends it (5.6 ended it only at the sixth try) }
  Advance(11 * 60);
  Cmd(1, '/setemail bob2@example.com');
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Host.Messages.Clear;
  for k := 1 to 5 do
    Cmd(1, '/verifyemail WRONG' + IntToStr(k) + 'XYZ');
  Check('ZSI-05 the fifth wrong e-mail code ends the code', (ById(BobId)^.EmailCodeHash = '') and
    Said(1, 'no longer valid'));
  Id.Leave(1);

  { a stranger who only tried /login #id cannot use a reset code somebody else asked for }
  Advance(11 * 60);
  JoinNow(2, 'Eve', 'HW-E', '7.7.7.7');
  JoinNow(3, 'Bob', 'HW-R', '3.3.3.3');
  Cmd(3, Format('/forgotpass #%d', [BobId]));
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Check('ZSI-05 setup: a reset code was sent', (Code <> '') and (ById(BobId)^.ResetCodeHash <> ''));
  Advance(3);
  Cmd(2, Format('/login #%d wrongpass1', [BobId]));
  RunJobs;
  Advance(3);
  Host.Messages.Clear;
  Hash0 := ById(BobId)^.PassHash;
  Cmd(2, '/resetpass ' + Code + ' evepass99 evepass99');
  RunJobs;
  Check('ZSI-05 /login #id does not make /resetpass work in that session', (ById(BobId)^.PassHash = Hash0) and
    Said(2, 'Request a code first') and (Id.Slots[2].ProfileId <> BobId));

  { wrong codes add up over sessions: three in the session that asked, two on the account's own
    computer (a session waiting for /login), and the code is gone }
  for k := 1 to 3 do
    Cmd(3, '/resetpass BADCODE' + IntToStr(k) + ' newpass11 newpass11');
  Check('ZSI-05 the wrong codes are counted', Said(3, 'Wrong code (3/5)'));
  JoinNow(4, 'Bob', 'HW-B', '8.8.8.8');
  Check('ZSI-05 setup: a session on the account''s computer waits for /login', Id.Slots[4].Locked and
    (Id.Slots[4].ProfileId = BobId));
  Host.Messages.Clear;
  Cmd(4, '/resetpass BADCODE4 newpass11 newpass11');
  Check('ZSI-05 the count goes on in another session', Said(4, 'Wrong code (4/5)'));
  Cmd(4, '/resetpass BADCODE5 newpass11 newpass11');
  Check('ZSI-05 the fifth wrong code ends the reset code of the account', (ById(BobId)^.ResetCodeHash = '') and
    Said(4, 'no longer valid'));
  Host.Messages.Clear;
  Cmd(3, '/resetpass ' + Code + ' newpass11 newpass11');
  RunJobs;
  Check('ZSI-05 the right code is useless after that', (ById(BobId)^.PassHash = Hash0) and
    Said(3, 'No valid reset code'));
  Id.Leave(4);

  { a new code has five tries of its own and works in the session that asked for it }
  Advance(11 * 60);
  Cmd(3, Format('/forgotpass #%d', [BobId]));
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Host.Messages.Clear;
  Cmd(3, '/resetpass BADCODE6 newpass11 newpass11');
  Check('ZSI-05 a new code starts counting again', Said(3, 'Wrong code (1/5)'));
  Advance(3);
  Cmd(3, '/resetpass ' + Code + ' newpass11 newpass11');
  RunJobs;
  Check('ZSI-05 the right code works in the session that asked', (ById(BobId)^.PassHash <> Hash0) and
    (Id.Slots[3].ProfileId = BobId) and not Id.Slots[3].Locked);
  Id.Leave(3);
  Id.Leave(2);

  { /login #id followed by /login <password> still uses the account chosen by /login #id }
  JoinNow(5, 'Bob', 'HW-Z', '4.4.4.4');
  Cmd(5, Format('/login #%d wrongpass2', [BobId]));
  RunJobs;
  Advance(3);
  Cmd(5, '/login newpass11');
  RunJobs;
  Check('ZSI-05 /login <password> after /login #id still logs in to that account', (Id.Slots[5].ProfileId = BobId) and
    not Id.Slots[5].Locked);
  Id.Leave(5);
end;

{ ---------------- ZSD-02: the e-mail codes and their hashes ---------------- }

procedure TestCodeHashes;
var
  BobId, k: LongInt;
  Code, Salt, Old: AnsiString;
  P: PPlayerProfile;
  Ok: Boolean;
begin
  Salt := BytesToHex(SecureRandomBytes(16));
  Check('ZSD-02 the code hash is keyed with the salt of the account', (CodeHash(5, Salt, 'ABCDEFGHJKMN') <>
    CodeHash(5, BytesToHex(SecureRandomBytes(16)), 'ABCDEFGHJKMN')) and (CodeHash(5, Salt, 'ABCDEFGHJKMN') <>
    CodeHash(6, Salt, 'ABCDEFGHJKMN')));
  Check('ZSD-02 a code is read without regard to case and spaces', CodeHash(5, Salt, ' abcdefghjkmn ') =
    CodeHash(5, Salt, 'ABCDEFGHJKMN'));
  Fresh;
  Cfg.MailMaxPerDay := 10;
  BobId := Registered(1, 'Bob', 'HW-B', '5.6.7.8', 'secretpw1');
  P := ById(BobId);
  Cmd(1, '/setemail bob@example.com');
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Ok := Length(Code) = 12;
  for k := 1 to Length(Code) do
    if Pos(Code[k], 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789') = 0 then
      Ok := False;
  Check('ZSD-02 an e-mail code has 12 characters (60 bits)', Ok);
  Check('ZSD-02 the stored code is the keyed hash, not the plain SHA-256 of 5.6',
    (P^.EmailCodeHash = CodeHash(BobId, P^.PassSalt, Code)) and (Pos(Code, P^.EmailCodeHash) = 0) and
    (P^.EmailCodeHash <> BytesToHex(DigestToStr(Sha256Str(IntToStr(BobId) + ':' + Code)))));
  Cmd(1, '/verifyemail ' + Code);
  Check('ZSD-02 the code verifies the e-mail', P^.EmailVerified);
  Id.Leave(1);
  { a reset code still pending from 5.6 (unkeyed hash of an 8-character code) is no code any more }
  Old := 'ABCD2345';
  P^.ResetCodeHash := BytesToHex(DigestToStr(Sha256Str(IntToStr(BobId) + ':' + Old)));
  P^.ResetCodeExpire := LocalToUtc(T) + 10 / 1440;
  JoinNow(2, 'Bob', 'HW-B', '9.9.9.9');
  Host.Messages.Clear;
  Cmd(2, '/resetpass ' + Old + ' newpass11 newpass11');
  RunJobs;
  Check('ZSD-02 a code of 5.6 is not accepted after the update', Said(2, 'No valid reset code') and
    (P^.ResetCodeHash = '') and Id.Slots[2].Locked);
  { a new code works }
  Advance(11 * 60);
  Cmd(2, '/forgotpass');
  RunJobs;
  Code := ExtractCode(Host.LastMail);
  Advance(3);
  Cmd(2, '/resetpass ' + LowerCase(Code) + ' newpass11 newpass11');
  RunJobs;
  Check('ZSD-02 a new code resets the password', not Id.Slots[2].Locked and (P^.ResetCodeHash = ''));
  Id.Leave(2);
end;

{ ---------------- ZSI-08: e-mail limits of the server and of a source, no name in the text ---------------- }

procedure TestMailLimits;
var
  AId, k: LongInt;
  M: TMailSettings;
  S2: TServiceThread;
  Job: TServiceJob;
  R: TServiceResult;
  Order: AnsiString;
  T0: Int64;
begin
  Fresh;
  AId := Registered(1, 'Zzyzx', 'HW-M1', '5.5.5.1', 'mailpass1');
  Cmd(1, '/setemail zz@example.com');
  RunJobs;
  Check('ZSI-08 the mail names the account by its number, not by a player name',
    (Pos(Format('account #%d', [AId]), Host.LastMail) > 0) and (Pos('Zzyzx', Host.LastMail) = 0) and
    (Pos('Zzyzx', Host.LastSubject) = 0));
  Id.Leave(1);

  { the server: at most MaxPerDayServer a day, whatever the accounts }
  Fresh;
  Cfg.MailMaxPerDayServer := 2;
  for k := 1 to 3 do
  begin
    Registered(k, 'Spam' + IntToStr(k), 'HW-S' + IntToStr(k), Format('%d.1.1.1', [20 + k]), 'spampass1');
    Host.Messages.Clear;
    Cmd(k, '/setemail victim@example.com');
    RunJobs;
  end;
  Check('ZSI-08 the server sends at most MaxPerDayServer e-mails a day', (Host.Mails = 2) and
    Said(3, 'all its e-mails for today'));
  Check('ZSI-08 the console hears when the limit of the server is reached',
    Pos('MaxPerDayServer = 2', Host.Audits.Text) > 0);
  Advance(86400);
  Host.Messages.Clear;
  Cmd(3, '/setemail victim@example.com');
  RunJobs;
  Check('ZSI-08 the next day the server sends again', (Host.Mails = 3) and Said(3, 'Code sent'));
  for k := 1 to 3 do
    Id.Leave(k);

  { one network with new computers (a new account each): at most MaxPerDaySource }
  Fresh;
  Cfg.MailMaxPerDaySource := 2;
  for k := 1 to 3 do
  begin
    Registered(k, 'Net' + IntToStr(k), 'HW-NET' + IntToStr(k), Format('7.7.7.%d', [k]), 'netpass11');
    Host.Messages.Clear;
    Cmd(k, '/setemail victim@example.com');
    RunJobs;
  end;
  Check('ZSI-08 one network asks for at most MaxPerDaySource e-mails a day', (Host.Mails = 2) and
    Said(3, 'from your computer today'));
  Registered(4, 'Else', 'HW-ELSE', '8.8.8.8', 'elsepass1');
  Host.Messages.Clear;
  Cmd(4, '/setemail else@example.com');
  RunJobs;
  Check('ZSI-08 another network is not affected', (Host.Mails = 3) and Said(4, 'Code sent'));
  for k := 1 to 4 do
    Id.Leave(k);

  { the service thread: a password hash does not wait for the mails queued before it }
  S2 := TServiceThread.Create;
  M.Method := 'command';
  {$IFDEF WINDOWS}
  M.CommandTemplate := 'ping -n 3 127.0.0.1';
  {$ELSE}
  M.CommandTemplate := 'sleep 2';
  {$ENDIF}
  M.CurlPath := 'curl';
  M.SmtpUrl := '';
  M.SmtpUser := '';
  M.SmtpPassword := '';
  M.FromAddress := 'noreply@example.com';
  M.FromName := 'ZitroStats';
  M.SendmailPath := '';
  M.TimeoutSeconds := 30;
  S2.SetMailSettings(M);
  for k := 1 to 2 do
  begin
    Job := NewServiceJob(svMail);
    Job.Tag := k;
    Job.MailTo := 'someone@example.com';
    Job.Subject := 'Test';
    Job.Body := 'Hello';
    S2.Enqueue(Job);
  end;
  Job := NewServiceJob(svHash);
  Job.Tag := 3;
  Job.Password := 'pw';
  Job.Salt := 'salt';
  Job.Iterations := 100;
  S2.Enqueue(Job);
  Order := '';
  T0 := MonoMs;
  while (Length(Order) < 3) and (MonoMs - T0 < 30000) do
  begin
    if S2.PollResult(R) then
      Order := Order + IntToStr(R.Tag)
    else
      Sleep(5);
  end;
  WriteLn('       results in the order ', Order);
  Check('ZSI-08 a password hash does not wait behind the mails', (Length(Order) = 3) and
    (Pos('3', Order) < Pos('2', Order)));
  S2.Free;
end;

{ ---------------- ZSI-06: the API gives nothing of an account to a session not logged in ---------------- }

var
  Engine: TZSEngine;
  Pushed: LongInt;

procedure DeleteTree(const Dir: AnsiString);
var
  SR: TSearchRec;
  P: AnsiString;
begin
  if not DirectoryExists(Dir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure Push(Ev: TZSEvent);
begin
  Engine.PushEvent(Ev);
  Inc(Pushed);
end;

function WaitProcessed: Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  while Engine.Processed < Pushed do
  begin
    if MonoMs - T0 > 20000 then
      Exit(False);
    Sleep(5);
  end;
  Sleep(150);
  Result := True;
end;

procedure EngineJoin(Slot: LongInt; const Name, Hwid, IP: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeJoin);
  Ev.Slot := Slot;
  Ev.S1 := Name;
  Ev.S3 := Hwid;
  Ev.S4 := IP;
  Ev.I[0] := TEAM_ALPHA;
  Ev.I[1] := 1;
  Push(Ev);
end;

procedure EngineLeave(Slot: LongInt);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeLeave);
  Ev.Slot := Slot;
  Push(Ev);
end;

procedure EngineCmd(Slot: LongInt; const Text: AnsiString);
var
  Ev: TZSEvent;
begin
  Ev := NewEvent(zeCommand);
  Ev.Slot := Slot;
  Ev.S1 := Text;
  Ev.I[0] := SRC_COMMAND;
  Push(Ev);
end;

function EngineRegistered(AccountId: LongInt): Boolean;
var
  Idx: LongInt;
begin
  EnterCriticalSection(Engine.StateLock);
  try
    Idx := Engine.DB.IndexOfId(AccountId);
    Result := Engine.DB.Valid(Idx) and (Engine.DB.Profiles[Idx]^.PassHash <> '');
  finally
    LeaveCriticalSection(Engine.StateLock);
  end;
end;

procedure TestApiLocked;
var
  Root, Dir0: AnsiString;
  Ev: TZSEvent;
  AccountId: LongInt;
  T0: Int64;
  Ready: Boolean;
begin
  Dir0 := GetCurrentDir;
  Root := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'ws5b_engine_tmp');
  DeleteTree(Root);
  ForceDirectories(Root + PathDelim + 'script');
  SetCurrentDir(Root);
  Engine := TZSEngine.Create(Root + PathDelim + 'script');
  Engine.Start;
  T0 := MonoMs;
  while not Engine.IsReady and (MonoMs - T0 < 20000) do
    Sleep(5);
  Check('ZSI-06 setup: engine ready', Engine.IsReady);
  EnterCriticalSection(Engine.StateLock);
  Engine.Cfg.SteamAuthWaitSeconds := 0;
  Engine.Cfg.PasswordIterations := 10000;
  LeaveCriticalSection(Engine.StateLock);
  Pushed := 0;
  Ev := NewEvent(zeMapAfter);
  Ev.S1 := 'ctf_Ash';
  Ev.I[0] := GS_CTF;
  Ev.I[1] := 10;
  Push(Ev);
  EngineJoin(1, 'Owner', 'HW-API', '10.1.1.1');
  WaitProcessed;
  AccountId := Round(Engine.ApiPlayerStat(1, 37));
  Check('ZSI-06 setup: the account number of a player on his account', AccountId > 0);
  EngineCmd(1, '/register apipass1 apipass1');
  WaitProcessed;
  T0 := MonoMs;
  Ready := False;
  while not Ready and (MonoMs - T0 < 20000) do
  begin
    Ready := EngineRegistered(AccountId);
    Sleep(20);
  end;
  Check('ZSI-06 setup: the account is registered', Ready);
  EngineLeave(1);
  { the same computer from another network (or a copied HWID): the account, not logged in }
  EngineJoin(2, 'Copy', 'HW-API', '10.9.9.9');
  WaitProcessed;
  Check('ZSI-06 setup: the session waits for /login', Engine.Identity.Slots[2].Locked and
    (Engine.Identity.Slots[2].ProfileId = AccountId));
  Check('ZSI-06 a session not logged in gets no statistic of the account',
    (Engine.ApiPlayerStat(2, 37) = 0) and (Engine.ApiPlayerStat(2, 1) = 0));
  Check('ZSI-06 a session not logged in gets no rank', Engine.ApiPlayerRank(2) = 0);
  Check('ZSI-06 the account by its number still answers', Round(Engine.ApiProfileStat(AccountId, 37)) = AccountId);
  EngineCmd(2, '/login apipass1');
  WaitProcessed;
  T0 := MonoMs;
  while (Engine.ApiPlayerStat(2, 37) = 0) and (MonoMs - T0 < 20000) do
    Sleep(20);
  Check('ZSI-06 after /login the API gives the account again', Round(Engine.ApiPlayerStat(2, 37)) = AccountId);
  Engine.Free;
  SetCurrentDir(Dir0);
  DeleteTree(Root);
end;

begin
  Svc := TServiceThread.Create;
  Id := nil;
  TestPasswordMerge;
  TestTrustedMerge;
  TestNameMerge;
  TestTrustAfterPasswordChange;
  TestUtcTimes;
  TestLockPerSource;
  TestResetCodes;
  TestCodeHashes;
  TestMailLimits;
  TestApiLocked;
  if Id <> nil then
  begin
    Id.Free;
    Host.Free;
    DB.Free;
  end;
  Svc.Free;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
