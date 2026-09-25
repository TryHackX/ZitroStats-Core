program test_service;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, zs_util, zs_service;

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

function WaitResult(S: TServiceThread; Tag: LongInt; TimeoutMs: LongInt; out R: TServiceResult): Boolean;
var
  T0: Int64;
begin
  T0 := MonoMs;
  repeat
    if S.PollResult(R) and (R.Tag = Tag) then
      Exit(True);
    Sleep(5);
  until MonoMs - T0 > TimeoutMs;
  Result := False;
end;

var
  S: TServiceThread;
  Job: TServiceJob;
  R: TServiceResult;
  M: TMailSettings;
  Msg: AnsiString;
  Salt: AnsiString;
  i: LongInt;
  Found: Boolean;
begin
  S := TServiceThread.Create;

  Salt := HexToBytes('00112233445566778899aabbccddeeff');
  Job := NewServiceJob(svHash);
  Job.Tag := 7;
  Job.Password := 'secret123';
  Job.Salt := Salt;
  Job.Password2 := 'Other#Pass';
  Job.Salt2 := 'salt-two';
  Job.Iterations := 2000;
  Check('hash job accepted', S.Enqueue(Job));
  Check('hash result arrives', WaitResult(S, 7, 10000, R) and R.Ok);
  Check('hash matches PBKDF2', R.Hash = BytesToHex(Pbkdf2Sha256('secret123', Salt, 2000, 32)));
  Check('second hash matches', R.Hash2 = BytesToHex(Pbkdf2Sha256('Other#Pass', 'salt-two', 2000, 32)));

  { /changepass: the old password with the account's rounds, the new one with the settings' }
  Job := NewServiceJob(svHash);
  Job.Tag := 8;
  Job.Password := 'secret123';
  Job.Salt := Salt;
  Job.Password2 := 'Other#Pass';
  Job.Salt2 := 'salt-two';
  Job.Iterations := 2000;
  Job.Iterations2 := 3000;
  S.Enqueue(Job);
  Check('the second password takes its own rounds', WaitResult(S, 8, 10000, R) and R.Ok and
    (R.Hash = BytesToHex(Pbkdf2Sha256('secret123', Salt, 2000, 32))) and
    (R.Hash2 = BytesToHex(Pbkdf2Sha256('Other#Pass', 'salt-two', 3000, 32))));

  Job := NewServiceJob(svHash);
  Job.Iterations := 200000;
  Job.Password := 'x';
  for i := 1 to 3 do
    S.Enqueue(Job, 100);
  Check('hash queue limit', not S.Enqueue(Job, 2));

  Msg := BuildMailMessage('noreply@example.com', 'Zitro Stats', 'gracz@example.pl',
    'Kod: '#$C4#$B9#$E2#$80#$9A + #13#10 + 'Bcc: victim@example.com', 'Line one' + #10 + 'Line two');
  Check('mail headers', (Pos('From: Zitro Stats <noreply@example.com>'#13#10, Msg) = 1) and
    (Pos(#13#10'To: <gracz@example.pl>'#13#10, Msg) > 0));
  Check('header injection removed', Pos(#13#10'Bcc:', Msg) = 0);
  Check('non-ascii subject encoded', Pos('Subject: =?UTF-8?B?', Msg) > 0);
  Check('body uses CRLF', Pos('Line one'#13#10'Line two', Msg) > 0);
  Check('smtp host', (SmtpHost('smtps://user@smtp.gmail.com:465/x') = 'smtp.gmail.com') and
    (SmtpHost('smtp://[::1]:25') = '::1'));
  Check('mask email', MaskEmail('dominik@gmail.com') = 'd******@gmail.com');
  Check('curl config value quoted and escaped', CurlQuote('us er:p"a\ss'#9'x'#13#10) = '"us er:p\"a\\ss\tx"');

  M.Method := 'curl';
  M.CurlPath := 'curl';
  M.SmtpUrl := 'smtp://127.0.0.1:9';
  M.SmtpUser := 'user';
  M.SmtpPassword := 'pass';
  M.FromAddress := 'noreply@example.com';
  M.FromName := 'ZitroStats';
  M.TimeoutSeconds := 5;
  S.SetMailSettings(M);
  Job := NewServiceJob(svMail);
  Job.Tag := 9;
  Job.MailTo := 'someone@example.com';
  Job.Subject := 'Test';
  Job.Body := 'Hello';
  S.Enqueue(Job);
  Check('unreachable SMTP fails cleanly', WaitResult(S, 9, 60000, R) and not R.Ok and (R.Message <> ''));
  WriteLn('       curl said: ', R.Message, ' (', R.ElapsedMs, ' ms)');

  Job := NewServiceJob(svMail);
  Job.Tag := 10;
  Job.MailTo := 'bad address@example.com';
  S.Enqueue(Job);
  Check('invalid recipient rejected', WaitResult(S, 10, 5000, R) and not R.Ok);

  { Method = command without a template: the message names the setting of settings.ini }
  M.Method := 'command';
  M.CommandTemplate := '';
  S.SetMailSettings(M);
  Job := NewServiceJob(svMail);
  Job.Tag := 11;
  Job.MailTo := 'someone@example.com';
  Job.Subject := 'Test';
  Job.Body := 'Hello';
  S.Enqueue(Job);
  Check('an empty CommandTemplate is named as such', WaitResult(S, 11, 10000, R) and not R.Ok and
    (Pos('CommandTemplate', R.Message) > 0));

  { nobody reads the results for a while (1000 webhook answers wait): the answer of a hash, which
    a player waits for, is still kept }
  for i := 1 to 1000 do
  begin
    Job := NewServiceJob(svHttpPost);
    Job.Tag := 20000 + i;
    Job.Url := 'ftp://example.com/hook';
    S.Enqueue(Job);
  end;
  Job := NewServiceJob(svHash);
  Job.Tag := 77;
  Job.Password := 'pw77';
  Job.Salt := Salt;
  Job.Iterations := 100;
  S.Enqueue(Job);
  i := 0;
  while (S.PendingHashes > 0) and (i < 2000) do
  begin
    Sleep(5);
    Inc(i);
  end;
  Sleep(50);
  Found := False;
  while S.PollResult(R) do
    if (R.Tag = 77) and R.Ok then
      Found := True;
  Check('a hash answer is kept when the results are full', Found);

  S.Free;
  Check('stops with pending work', True);

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
