program test_util;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, DateUtils, zs_util;

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

procedure CheckEq(const Name, Got, Expected: string);
begin
  if Got = Expected then
    WriteLn('[ OK ] ', Name)
  else
  begin
    WriteLn('[FAIL] ', Name, ': got ', Got, ' expected ', Expected);
    Inc(Failures);
  end;
end;

var
  Idx: TStrIndex;
  R: TIntArray;
  Lo, Hi: Double;
  T0: Int64;
  Parts: TStringArray;
begin
  CheckEq('sha256("")', BytesToHex(DigestToStr(Sha256Str(''))),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  CheckEq('sha256("abc")', BytesToHex(DigestToStr(Sha256Str('abc'))),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  CheckEq('sha256(448 bits)', BytesToHex(DigestToStr(Sha256Str('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  CheckEq('hmac rfc4231 #2', BytesToHex(DigestToStr(HmacSha256('Jefe', 'what do ya want for nothing?'))),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
  CheckEq('pbkdf2 c=1', BytesToHex(Pbkdf2Sha256('password', 'salt', 1, 32)),
    '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
  CheckEq('pbkdf2 c=2', BytesToHex(Pbkdf2Sha256('password', 'salt', 2, 32)),
    'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
  CheckEq('pbkdf2 c=4096', BytesToHex(Pbkdf2Sha256('password', 'salt', 4096, 32)),
    'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
  T0 := MonoMs;
  Pbkdf2Sha256('password', 'saltsaltsaltsalt', 100000, 32);
  WriteLn('       pbkdf2 100000 iterations: ', MonoMs - T0, ' ms');

  CheckEq('crc32("123456789")', IntToHex(Crc32Str('123456789'), 8), 'CBF43926');
  Check('random bytes length', Length(SecureRandomBytes(16)) = 16);
  Check('random bytes differ', SecureRandomBytes(16) <> SecureRandomBytes(16));
  Check('code length', Length(RandomCode(8)) = 8);
  CheckEq('hex roundtrip', BytesToHex(HexToBytes('00ff10a5')), '00ff10a5');
  Check('const time eq', ConstantTimeEquals('abc', 'abc') and not ConstantTimeEquals('abc', 'abd'));

  Check('email ok', IsValidEmail('gracz.jeden+soldat@poczta.example.pl'));
  Check('email no tld', not IsValidEmail('a@localhost'));
  Check('email crlf', not IsValidEmail('a@b.pl'#13#10'Bcc: x@y.pl'));
  Check('email double dot', not IsValidEmail('a..b@c.pl'));
  Check('email space', not IsValidEmail('a b@c.pl'));
  Check('password chars', IsPrintableNoSpace('Abc!23') and not IsPrintableNoSpace('ab c'));

  { the Polish letters in UTF-8, written as bytes: the sources stay ASCII }
  CheckEq('cp1250 polish', CpToUtf8(#$A5#$B9#$C6#$E6#$CA#$EA#$A3#$B3#$D1#$F1#$D3#$F3#$8C#$9C#$8F#$9F#$AF#$BF, 1250),
    #$C4#$84#$C4#$85#$C4#$86#$C4#$87#$C4#$98#$C4#$99#$C5#$81#$C5#$82#$C5#$83#$C5#$84#$C3#$93#$C3#$B3#$C5#$9A#$C5#$9B +
    #$C5#$B9#$C5#$BA#$C5#$BB#$C5#$BC);
  CheckEq('utf-8 names pass', CpToUtf8('Za'#$C5#$BC#$C3#$B3#$C5#$82#$E2#$82#$AC'!'#$F0#$9F#$98#$80, 65001),
    'Za'#$C5#$BC#$C3#$B3#$C5#$82#$E2#$82#$AC'!'#$F0#$9F#$98#$80);
  CheckEq('broken utf-8 cannot break the JSON', CpToUtf8('a'#$C5'b'#$C0#$80'c'#$ED#$A0#$80'd'#$F5#$80#$80#$80#$1F'e'#$C5, 65001),
    'a?b??c???d????e?');
  CheckEq('json escape', JsonStr('a"b\c'#10), '"a\"b\\c\n"');
  CheckEq('json control characters', JsonStr(#1#31#127'/'), '"\u0001\u001F'#127'/"');
  CheckEq('float str', FloatStr(12.3456, 2), '12.35');
  CheckEq('float str of no number', FloatStr(NaN, 2) + ' ' + FloatStr(Infinity, 1), '0.00 0.0');
  CheckEq('float str negative', FloatStr(-0.25, 1), '-0.3');
  CheckEq('duration', FormatDuration(0) + '|' + FormatDuration(59) + '|' + FormatDuration(61) + '|' +
    FormatDuration(3661) + '|' + FormatDuration(90061) + '|' + FormatDuration(-5), '0s|59s|1m 1s|1h 1m 1s|1d 1h 1m|0s');
  CheckEq('short duration', FormatDurationShort(59) + '|' + FormatDurationShort(61) + '|' + FormatDurationShort(3661) +
    '|' + FormatDurationShort(90061) + '|' + FormatDurationShort(-1), '59s|1m 1s|1h 1m|1d 1h|0s');
  CheckEq('padding', '[' + PadR('ab', 4) + '][' + PadL('ab', 4) + '][' + PadR('abcdef', 3) + '][' + PadL('', 2) + ']',
    '[ab  ][  ab][abcdef][  ]');
  Check('safe division', (SafeDivD(1, 0) = 0) and (SafeDivD(6, 3) = 2) and (Ratio(5, 0) = 5));
  Check('day keys change at midnight', (DayKey(EncodeDate(2026, 3, 29) + EncodeTime(23, 59, 59, 0)) + 1 =
    DayKey(EncodeDate(2026, 3, 30) + EncodeTime(0, 0, 1, 0))) and
    (DayKey(EncodeDate(2026, 10, 25) + EncodeTime(2, 30, 0, 0)) = DayKey(EncodeDate(2026, 10, 25))));
  Check('empty input', (SplitWords('') = nil) and (RestAfterWords('', 2) = '') and (HexToBytes('abc') = '') and
    (SanitizeText(#1'a'#9'b', 0) = 'ab') and (SanitizeText('abcdef', 3) = 'abc') and not IsValidEmail('') and
    not IsPrintableNoSpace('') and (LowerAscii('') = '') and (CpToUtf8('', 65001) = '') and (JsonStr('') = '""'));
  Check('short e-mail rules', IsValidEmail('a@b.co') and not IsValidEmail('a@b.c') and not IsValidEmail('@b.com') and
    not IsValidEmail('a@-b.com') and not IsValidEmail('a@b..com'));

  Parts := SplitWords('  /register  abc   def ', 0);
  Check('split words', (Length(Parts) = 3) and (Parts[0] = '/register') and (Parts[2] = 'def'));
  Parts := SplitWords('!topby kills deaths 2', 2);
  Check('split max parts', (Length(Parts) = 2) and (Parts[1] = 'kills deaths 2'));
  CheckEq('rest after words', RestAfterWords('/search  Dom inik', 1), 'Dom inik');

  CheckEq('week key 2026-09-15', IntToStr(WeekKey(EncodeDate(2026, 9, 15))), '202638');
  CheckEq('week key 2021-01-03', IntToStr(WeekKey(EncodeDate(2021, 1, 3))), '202053');
  CheckEq('week keys around the new year', IntToStr(WeekKey(EncodeDate(2025, 12, 29))) + ' ' +
    IntToStr(WeekKey(EncodeDate(2026, 12, 31))) + ' ' + IntToStr(WeekKey(EncodeDate(2027, 1, 3))) + ' ' +
    IntToStr(WeekKey(EncodeDate(2027, 1, 4))), '202601 202653 202653 202701');
  CheckEq('month key', IntToStr(MonthKey(EncodeDate(2026, 9, 15))), '202609');
  Check('unix time is UTC', Abs(UnixNow - DateTimeToUnix(LocalTimeToUniversal(Now))) <= 2);

  WilsonInterval(58, 100, Lo, Hi);
  Check('wilson 58/100', (Lo > 0.48) and (Lo < 0.49) and (Hi > 0.67) and (Hi < 0.68));

  Idx := TStrIndex.Create(4);
  try
    Idx.Add('Dominik', 1);
    Idx.Add('dominik', 7);
    Idx.Add('DOMINIK', 7);
    Idx.Add('Other', 2);
    R := Idx.Find('DoMiNiK');
    Check('index multi find', (Length(R) = 2));
    Idx.Remove('dominik', 1);
    R := Idx.Find('dominik');
    Check('index remove', (Length(R) = 1) and (R[0] = 7));
    Check('index first', Idx.FindFirst('other') = 2);
    Check('index missing', Idx.FindFirst('nobody') = -1);
  finally
    Idx.Free;
  end;

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
