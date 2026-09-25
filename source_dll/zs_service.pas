unit zs_service;

{ Service thread for work that must never run on the game or engine thread: password hashing
  (PBKDF2, about 0.1 s per hash), e-mail delivery and HTTP calls through external programs.
  Programs are started without a shell and every argument is passed separately, so player
  supplied values can neither inject options nor commands. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, process, base64, zs_util, zs_crash;

type
  TServiceJobKind = (svHash, svMail, svHttpPost, svStop);

  TServiceJob = record
    Kind: TServiceJobKind;
    Tag: LongInt;
    Slot: LongInt;
    ProfileId: LongInt;
    Op: LongInt;
    Password, Password2: AnsiString;
    Salt, Salt2: AnsiString;
    Iterations: LongInt;
    MailTo, Subject, Body: AnsiString;
    Url, Payload: AnsiString;
    { the rounds of Password2 (a new password takes the rounds of the settings, the old one is
      checked with the account's own); 0 = Iterations }
    Iterations2: LongInt;
  end;

  TServiceResult = record
    Kind: TServiceJobKind;
    Tag, Slot, ProfileId, Op: LongInt;
    Ok: Boolean;
    Hash, Hash2: AnsiString;
    Message: AnsiString;
    ElapsedMs: LongInt;
  end;

  TMailSettings = record
    Method: AnsiString;
    CurlPath: AnsiString;
    SmtpUrl, SmtpUser, SmtpPassword: AnsiString;
    FromAddress, FromName: AnsiString;
    SendmailPath: AnsiString;
    CommandTemplate: AnsiString;
    TimeoutSeconds: LongInt;
  end;

  TServiceThread = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FJobs: array of TServiceJob;
    FJobCount: LongInt;
    FResults: array of TServiceResult;
    FResultCount: LongInt;
    FMail: TMailSettings;
    FPendingHashes: LongInt;
    FAbort: Boolean;
    procedure Post(const R: TServiceResult);
    procedure DoHash(var Job: TServiceJob);
    procedure DoMail(const Job: TServiceJob);
    procedure DoHttpPost(const Job: TServiceJob);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetMailSettings(const M: TMailSettings);
    function Enqueue(const Job: TServiceJob; MaxPendingHashes: LongInt = 16): Boolean;
    function PollResult(out R: TServiceResult): Boolean;
    function PendingHashes: LongInt;
    procedure StopAndWait;
  end;

function NewServiceJob(Kind: TServiceJobKind): TServiceJob;
function RunProgram(const Exe: AnsiString; const Args: array of AnsiString; const StdIn: AnsiString;
  TimeoutMs: LongInt; Abort: PBoolean; out Output: AnsiString; out ExitCode: LongInt): Boolean;
function BuildMailMessage(const FromAddr, FromName, ToAddr, Subject, Body: AnsiString): AnsiString;
function SmtpHost(const Url: AnsiString): AnsiString;
function MaskEmail(const Email: AnsiString): AnsiString;
procedure WipeString(var S: AnsiString);
{ a value for a curl config file (--config): quoted, with backslashes and quotes escaped }
function CurlQuote(const S: AnsiString): AnsiString;

implementation

function NewServiceJob(Kind: TServiceJobKind): TServiceJob;
begin
  Result.Kind := Kind;
  Result.Tag := 0;
  Result.Slot := 0;
  Result.ProfileId := 0;
  Result.Op := 0;
  Result.Iterations := 0;
  Result.Iterations2 := 0;
  Result.Password := '';
  Result.Password2 := '';
  Result.Salt := '';
  Result.Salt2 := '';
  Result.MailTo := '';
  Result.Subject := '';
  Result.Body := '';
  Result.Url := '';
  Result.Payload := '';
end;

procedure WipeString(var S: AnsiString);
begin
  if Length(S) > 0 then
  begin
    UniqueString(S);
    FillChar(S[1], Length(S), 0);
  end;
  S := '';
end;

function StripCRLF(const S: AnsiString): AnsiString;
var
  i: LongInt;
begin
  Result := S;
  for i := Length(Result) downto 1 do
    if Result[i] in [#0, #10, #13] then
      Delete(Result, i, 1);
end;

function EncodeHeaderText(const S: AnsiString): AnsiString;
var
  i: LongInt;
begin
  for i := 1 to Length(S) do
    if (Ord(S[i]) < 32) or (Ord(S[i]) > 126) then
      Exit('=?UTF-8?B?' + EncodeStringBase64(S) + '?=');
  Result := S;
end;

function RfcDate(UTC: TDateTime): AnsiString;
const
  DayNames: array[1..7] of AnsiString = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MonthNames: array[1..12] of AnsiString = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug',
    'Sep', 'Oct', 'Nov', 'Dec');
var
  Y, M, D, H, N, S, MS: Word;
begin
  DecodeDate(UTC, Y, M, D);
  DecodeTime(UTC, H, N, S, MS);
  Result := Format('%s, %.2d %s %d %.2d:%.2d:%.2d +0000', [DayNames[DayOfWeek(UTC)], D, MonthNames[M], Y, H, N, S]);
end;

function BuildMailMessage(const FromAddr, FromName, ToAddr, Subject, Body: AnsiString): AnsiString;
var
  B, FromLine: AnsiString;
begin
  B := StringReplace(Body, #13#10, #10, [rfReplaceAll]);
  B := StringReplace(B, #13, #10, [rfReplaceAll]);
  B := StringReplace(B, #10, #13#10, [rfReplaceAll]);
  if StripCRLF(FromName) <> '' then
    FromLine := EncodeHeaderText(StripCRLF(FromName)) + ' <' + StripCRLF(FromAddr) + '>'
  else
    FromLine := '<' + StripCRLF(FromAddr) + '>';
  Result :=
    'From: ' + FromLine + #13#10 +
    'To: <' + StripCRLF(ToAddr) + '>' + #13#10 +
    'Subject: ' + EncodeHeaderText(StripCRLF(Subject)) + #13#10 +
    'Date: ' + RfcDate(Now + GetLocalTimeOffset / 1440) + #13#10 +
    'Message-ID: <' + BytesToHex(SecureRandomBytes(12)) + '@zitrostats>' + #13#10 +
    'MIME-Version: 1.0' + #13#10 +
    'Content-Type: text/plain; charset=UTF-8' + #13#10 +
    'Content-Transfer-Encoding: 8bit' + #13#10 +
    #13#10 + B + #13#10;
end;

function SmtpHost(const Url: AnsiString): AnsiString;
var
  S: AnsiString;
  P: LongInt;
begin
  S := Trim(Url);
  P := Pos('://', S);
  if P > 0 then
    Delete(S, 1, P + 2);
  P := Pos('/', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  P := Pos('@', S);
  if P > 0 then
    Delete(S, 1, P);
  if (S <> '') and (S[1] = '[') then
  begin
    P := Pos(']', S);
    if P > 0 then
      S := Copy(S, 2, P - 2);
  end
  else
  begin
    P := Pos(':', S);
    if P > 0 then
      S := Copy(S, 1, P - 1);
  end;
  Result := S;
end;

function MaskEmail(const Email: AnsiString): AnsiString;
var
  At: LongInt;
begin
  At := Pos('@', Email);
  if At <= 1 then
    Exit('***');
  Result := Email[1] + StringOfChar('*', At - 2) + Copy(Email, At, MaxInt);
end;

{ a value for a curl config file: in double quotes, the backslash and the quote escaped, no line
  breaks }
function CurlQuote(const S: AnsiString): AnsiString;
var
  i: LongInt;
begin
  Result := '"';
  for i := 1 to Length(S) do
    case S[i] of
      '\', '"': Result := Result + '\' + S[i];
      #9: Result := Result + '\t';
      #10, #13: ;
    else
      Result := Result + S[i];
    end;
  Result := Result + '"';
end;

function TempFileName(const Kind, Ext: AnsiString): AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'zs-' + Kind + '-' +
    BytesToHex(SecureRandomBytes(8)) + Ext;
end;

{ the files for curl hold the mail password: on Linux only the server's user may read them }
function WriteTemp(const Path, Data: AnsiString): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  try
    F := TFileStream.Create(Path, fmCreate, &600);
    try
      if Data <> '' then
        F.WriteBuffer(Data[1], Length(Data));
      Result := True;
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

procedure DeleteSecret(const Path: AnsiString; Size: LongInt);
var
  Z: AnsiString;
begin
  if (Path = '') or not FileExists(Path) then
    Exit;
  if Size > 0 then
  begin
    SetLength(Z, Size);
    FillChar(Z[1], Size, 0);
    WriteTemp(Path, Z);
  end;
  DeleteFile(Path);
end;

function RunProgram(const Exe: AnsiString; const Args: array of AnsiString; const StdIn: AnsiString;
  TimeoutMs: LongInt; Abort: PBoolean; out Output: AnsiString; out ExitCode: LongInt): Boolean;
var
  P: TProcess;
  i, n, OldLen: LongInt;
  T0: Int64;
  Buf: array[0..4095] of Byte;

  procedure Drain;
  begin
    while P.Output.NumBytesAvailable > 0 do
    begin
      n := P.Output.Read(Buf, SizeOf(Buf));
      if n <= 0 then
        Break;
      if Length(Output) < 8192 then
      begin
        OldLen := Length(Output);
        SetLength(Output, OldLen + n);
        Move(Buf, Output[OldLen + 1], n);
      end;
    end;
  end;

begin
  Result := False;
  Output := '';
  ExitCode := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do
      P.Parameters.Add(Args[i]);
    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    P.ShowWindow := swoHide;
    try
      P.Execute;
    except
      on E: Exception do
      begin
        Output := 'cannot start ' + Exe + ': ' + E.Message;
        Exit;
      end;
    end;
    try
      if StdIn <> '' then
        P.Input.WriteBuffer(StdIn[1], Length(StdIn));
    except
    end;
    P.CloseInput;
    T0 := MonoMs;
    while P.Running do
    begin
      Drain;
      if (MonoMs - T0 > TimeoutMs) or ((Abort <> nil) and Abort^) then
      begin
        P.Terminate(255);
        Output := Trim(Output + ' (timed out)');
        Exit;
      end;
      Sleep(20);
    end;
    Drain;
    ExitCode := P.ExitStatus;
    Result := True;
  finally
    P.Free;
  end;
end;

{ ---------------- thread ---------------- }

constructor TServiceThread.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
  FMail.Method := 'curl';
  FMail.CurlPath := 'curl';
  FMail.TimeoutSeconds := 30;
  Start;
end;

destructor TServiceThread.Destroy;
begin
  StopAndWait;
  inherited Destroy;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
end;

procedure TServiceThread.StopAndWait;
begin
  if Finished then
    Exit;
  FAbort := True;
  Enqueue(NewServiceJob(svStop));
  WaitFor;
end;

procedure TServiceThread.SetMailSettings(const M: TMailSettings);
begin
  EnterCriticalSection(FLock);
  FMail := M;
  LeaveCriticalSection(FLock);
end;

function TServiceThread.Enqueue(const Job: TServiceJob; MaxPendingHashes: LongInt): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := not ((Job.Kind = svHash) and (FPendingHashes >= MaxPendingHashes));
    if not Result then
      Exit;
    if FJobCount >= Length(FJobs) then
      SetLength(FJobs, Length(FJobs) * 2 + 8);
    FJobs[FJobCount] := Job;
    Inc(FJobCount);
    if Job.Kind = svHash then
      Inc(FPendingHashes);
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
end;

function TServiceThread.PollResult(out R: TServiceResult): Boolean;
var
  i: LongInt;
begin
  EnterCriticalSection(FLock);
  try
    Result := FResultCount > 0;
    if not Result then
      Exit;
    R := FResults[0];
    for i := 1 to FResultCount - 1 do
      FResults[i - 1] := FResults[i];
    Dec(FResultCount);
    FResults[FResultCount].Hash := '';
    FResults[FResultCount].Hash2 := '';
    FResults[FResultCount].Message := '';
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TServiceThread.PendingHashes: LongInt;
begin
  EnterCriticalSection(FLock);
  Result := FPendingHashes;
  LeaveCriticalSection(FLock);
end;

procedure TServiceThread.Post(const R: TServiceResult);
begin
  EnterCriticalSection(FLock);
  try
    { a player waits for the answer of a hash (/login, /register): without it the session says
      "previous request is still running" until the player leaves. So only mails and webhooks are
      dropped when nobody reads the results; hashes are few (Enqueue takes at most
      MaxPendingHashes at a time, from the thread that reads the results). }
    if (FResultCount >= 1000) and (R.Kind <> svHash) then
      Exit;
    if FResultCount >= Length(FResults) then
      SetLength(FResults, Length(FResults) * 2 + 8);
    FResults[FResultCount] := R;
    Inc(FResultCount);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function ResultFor(const Job: TServiceJob): TServiceResult;
begin
  Result.Kind := Job.Kind;
  Result.Tag := Job.Tag;
  Result.Slot := Job.Slot;
  Result.ProfileId := Job.ProfileId;
  Result.Op := Job.Op;
  Result.Ok := False;
  Result.Hash := '';
  Result.Hash2 := '';
  Result.Message := '';
  Result.ElapsedMs := 0;
end;

procedure TServiceThread.DoHash(var Job: TServiceJob);
var
  R: TServiceResult;
  T0: Int64;
begin
  R := ResultFor(Job);
  T0 := MonoMs;
  if Job.Iterations > 0 then
  begin
    R.Hash := BytesToHex(Pbkdf2Sha256(Job.Password, Job.Salt, Job.Iterations, 32));
    if Job.Password2 <> '' then
    begin
      if Job.Iterations2 > 0 then
        R.Hash2 := BytesToHex(Pbkdf2Sha256(Job.Password2, Job.Salt2, Job.Iterations2, 32))
      else
        R.Hash2 := BytesToHex(Pbkdf2Sha256(Job.Password2, Job.Salt2, Job.Iterations, 32));
    end;
    R.Ok := True;
  end;
  WipeString(Job.Password);
  WipeString(Job.Password2);
  R.ElapsedMs := MonoMs - T0;
  EnterCriticalSection(FLock);
  Dec(FPendingHashes);
  LeaveCriticalSection(FLock);
  Post(R);
end;

procedure TServiceThread.DoMail(const Job: TServiceJob);
var
  R: TServiceResult;
  M: TMailSettings;
  Msg, MsgFile, NetrcFile, Netrc, Output, Method, Exe, Url: AnsiString;
  Args, Parts: array of AnsiString;
  i, n, ExitCode, TimeoutMs: LongInt;
  Started: Boolean;
  T0: Int64;

  procedure AddArg(const A: AnsiString);
  begin
    n := Length(Args);
    SetLength(Args, n + 1);
    Args[n] := A;
  end;

begin
  R := ResultFor(Job);
  T0 := MonoMs;
  EnterCriticalSection(FLock);
  M := FMail;
  LeaveCriticalSection(FLock);
  if M.TimeoutSeconds <= 0 then
    M.TimeoutSeconds := 30;
  TimeoutMs := (M.TimeoutSeconds + 5) * 1000;
  if not IsValidEmail(Job.MailTo) or not IsValidEmail(M.FromAddress) then
  begin
    R.Message := 'invalid sender or recipient address';
    Post(R);
    Exit;
  end;

  Msg := BuildMailMessage(M.FromAddress, M.FromName, Job.MailTo, Job.Subject, Job.Body);
  Method := LowerCase(Trim(M.Method));
  MsgFile := '';
  NetrcFile := '';
  Netrc := '';
  Started := False;
  try
    if Method = 'sendmail' then
      Started := RunProgram(M.SendmailPath, ['-t', '-i'], Msg, TimeoutMs, @FAbort, Output, ExitCode)
    else
    begin
      MsgFile := TempFileName('mail', '.eml');
      if not WriteTemp(MsgFile, Msg) then
      begin
        R.Message := 'cannot write temporary message file';
        Post(R);
        Exit;
      end;
      if Method = 'command' then
      begin
        { the template is split into arguments before substitution }
        Parts := SplitWords(M.CommandTemplate);
        if Length(Parts) = 0 then
        begin
          R.Message := '[Mail] CommandTemplate is empty';
          Post(R);
          Exit;
        end;
        Exe := Parts[0];
        for i := 1 to High(Parts) do
          AddArg(StringReplace(StringReplace(StringReplace(StringReplace(Parts[i],
            '{to}', Job.MailTo, [rfReplaceAll]),
            '{from}', M.FromAddress, [rfReplaceAll]),
            '{subject}', StripCRLF(Job.Subject), [rfReplaceAll]),
            '{file}', MsgFile, [rfReplaceAll]));
        Started := RunProgram(Exe, Args, '', TimeoutMs, @FAbort, Output, ExitCode);
      end
      else
      begin
        Url := Trim(M.SmtpUrl);
        AddArg('--silent');
        AddArg('--show-error');
        AddArg('--url');
        AddArg(Url);
        if LowerCase(Copy(Url, 1, 7)) = 'smtp://' then
          AddArg('--ssl-reqd');
        AddArg('--mail-from');
        AddArg(M.FromAddress);
        AddArg('--mail-rcpt');
        AddArg(Job.MailTo);
        AddArg('--upload-file');
        AddArg(MsgFile);
        AddArg('--max-time');
        AddArg(IntToStr(M.TimeoutSeconds));
        if M.SmtpUser <> '' then
        begin
          { credentials go through a temporary file, never the visible command line (on Linux
            every user of the machine can read the command lines of running programs) }
          if (Pos(' ', M.SmtpPassword) = 0) and (Pos(#9, M.SmtpPassword) = 0) and
             (Pos(' ', M.SmtpUser) = 0) and (Pos(#9, M.SmtpUser) = 0) then
          begin
            Netrc := 'machine ' + SmtpHost(Url) + ' login ' + M.SmtpUser + ' password ' + M.SmtpPassword + LineEnding;
            NetrcFile := TempFileName('netrc', '.txt');
            if WriteTemp(NetrcFile, Netrc) then
            begin
              AddArg('--netrc-file');
              AddArg(NetrcFile);
            end;
          end
          else
          begin
            { a name or password with a space does not fit a netrc file: a curl config file takes
              it quoted }
            Netrc := 'user = ' + CurlQuote(M.SmtpUser + ':' + M.SmtpPassword) + LineEnding;
            NetrcFile := TempFileName('curl', '.txt');
            if WriteTemp(NetrcFile, Netrc) then
            begin
              AddArg('--config');
              AddArg(NetrcFile);
            end;
          end;
        end;
        Started := RunProgram(M.CurlPath, Args, '', TimeoutMs, @FAbort, Output, ExitCode);
      end;
    end;
    R.Ok := Started and (ExitCode = 0);
    if R.Ok then
      R.Message := 'sent'
    else
    begin
      R.Message := Trim(StripCRLF(Copy(Output, 1, 200)));
      if R.Message = '' then
        R.Message := 'mail program exited with code ' + IntToStr(ExitCode);
    end;
  finally
    if MsgFile <> '' then
      DeleteFile(MsgFile);
    DeleteSecret(NetrcFile, Length(Netrc));
    WipeString(Netrc);
    for i := 0 to High(Args) do
      if Pos(':', Args[i]) > 0 then
        WipeString(Args[i]);
  end;
  R.ElapsedMs := MonoMs - T0;
  Post(R);
end;

procedure TServiceThread.DoHttpPost(const Job: TServiceJob);
var
  R: TServiceResult;
  M: TMailSettings;
  BodyFile, Output: AnsiString;
  ExitCode: LongInt;
  Started: Boolean;
  T0: Int64;
begin
  R := ResultFor(Job);
  T0 := MonoMs;
  EnterCriticalSection(FLock);
  M := FMail;
  LeaveCriticalSection(FLock);
  if (LowerCase(Copy(Job.Url, 1, 8)) <> 'https://') and (LowerCase(Copy(Job.Url, 1, 7)) <> 'http://') then
  begin
    R.Message := 'unsupported URL';
    Post(R);
    Exit;
  end;
  BodyFile := TempFileName('post', '.json');
  try
    if not WriteTemp(BodyFile, Job.Payload) then
    begin
      R.Message := 'cannot write temporary file';
      Post(R);
      Exit;
    end;
    Started := RunProgram(M.CurlPath, ['--silent', '--show-error', '--fail', '--max-time', '15',
      '-H', 'Content-Type: application/json', '--data-binary', '@' + BodyFile, Job.Url],
      '', 20000, @FAbort, Output, ExitCode);
    R.Ok := Started and (ExitCode = 0);
    if not R.Ok then
      R.Message := Trim(StripCRLF(Copy(Output, 1, 200)));
  finally
    DeleteFile(BodyFile);
  end;
  R.ElapsedMs := MonoMs - T0;
  Post(R);
end;

procedure TServiceThread.Execute;
var
  Batch: array of TServiceJob;
  Count, i: LongInt;
  Stop: Boolean;
  R: TServiceResult;
begin
  GuardWorkerThread;
  CrashThread(CT_SERVICE);
  Stop := False;
  repeat
    EnterCriticalSection(FLock);
    Batch := FJobs;
    Count := FJobCount;
    FJobs := nil;
    FJobCount := 0;
    LeaveCriticalSection(FLock);
    if Count = 0 then
    begin
      if Terminated then
        Break;
      RTLEventWaitFor(FWake, 500);
      Continue;
    end;
    for i := 0 to Count - 1 do
    begin
      try
        case Batch[i].Kind of
          svHash: DoHash(Batch[i]);
          svMail:
            if not FAbort then
              DoMail(Batch[i]);
          svHttpPost:
            if not FAbort then
              DoHttpPost(Batch[i]);
          svStop: Stop := True;
        end;
      except
        on E: Exception do
        begin
          if Batch[i].Kind = svHash then
          begin
            EnterCriticalSection(FLock);
            Dec(FPendingHashes);
            LeaveCriticalSection(FLock);
            { the player waits for this answer: without it the account stays busy for the session }
            R := ResultFor(Batch[i]);
            R.Ok := False;
            Post(R);
          end;
          WipeString(Batch[i].Password);
          WipeString(Batch[i].Password2);
        end;
      end;
    end;
    Batch := nil;
  until Stop;
end;

end.
