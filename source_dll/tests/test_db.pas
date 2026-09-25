program test_db;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, zs_types, zs_util, zs_fields, zs_fileio, zs_store, zs_rank, zs_db, zs_engine, zs_shared, zs_mysql;

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

function WaitCommit(IO: TStoreIO; Tag: LongInt): Boolean;
var
  R: TStoreResult;
  T0: Int64;
begin
  T0 := MonoMs;
  repeat
    while IO.PollResult(R) do
    begin
      if R.Message <> '' then
        WriteLn('       io: ', R.Message);
      if (R.Kind = sjSnapshotCommit) and (R.Tag = Tag) then
        Exit(R.Ok);
    end;
    Sleep(2);
  until MonoMs - T0 > 30000;
  Result := False;
end;

function Contains(const A: TIntArray; V: LongInt): Boolean;
var
  i: LongInt;
begin
  Result := False;
  for i := 0 to High(A) do
    if A[i] = V then
      Exit(True);
end;

procedure CleanDir(const Dir: AnsiString);
var
  L: TStringList;
  i: LongInt;
begin
  EnsureDir(Dir);
  L := ListFiles(Dir, '*');
  for i := 0 to L.Count - 1 do
    DeleteFile(IncludeTrailingPathDelimiter(Dir) + L[i]);
  L.Free;
end;

function HasName(P: PPlayerProfile; const Name: AnsiString): Boolean;
var
  k: LongInt;
begin
  Result := False;
  for k := 0 to High(P^.OtherNames) do
    if SameText(OtherDataToString(P^.OtherNames[k]), Name) then
      Exit(True);
end;

var
  DB, DB2, DB3, DB4, DB5: TStatsDB;
  Eng: TZSEngine;
  c, d, e: LongInt;
  IO: TStoreIO;
  W: TStoreWriter;
  St: TStoreState;
  Info: TStoreLoadInfo;
  Dir, Dir3, Steam: AnsiString;
  i, n, a, b, Top, Deleted: LongInt;
  Ok, Srv: Boolean;
  Gen: LongWord;
  PIdx, MIdx, SIdx: TIntArray;
  Del: TSyncDeletedArray;
  P: PPlayerProfile;
begin
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'db_tmp');
  CleanDir(Dir);

  DB := TStatsDB.Create;
  DB.SetNow(EncodeDate(2026, 9, 15));
  for i := 1 to 2000 do
  begin
    if i mod 3 = 0 then
      Steam := 'S' + IntToStr(100000 + i)
    else
      Steam := '';
    n := DB.CreateProfile('Player' + IntToStr(i), Steam, 'HWID' + IntToStr(i mod 1500), '10.0.0.' + IntToStr(i mod 250), 1000);
    DB.Profiles[n]^.Points := 1000 + (i * 37) mod 900;
    DB.RefreshRanks(n);
  end;
  Ok := True;
  for i := 0 to 1999 do
    if DB.Profiles[i]^.ID <> i + 1 then
      Ok := False;
  Check('ids are assigned in order', Ok and (DB.Server.NextProfileID = 2001));
  Check('steam lookup', DB.IndexOfSteam('S100003') = 2);
  Check('hwid lookup returns every owner', (Length(DB.IndexesOfHwid('HWID5')) = 2) and Contains(DB.IndexesOfHwid('HWID5'), 4) and Contains(DB.IndexesOfHwid('hwid5'), 1504));
  Check('name lookup ignores case', (Length(DB.IndexesOfName('player7')) = 1) and (DB.IndexesOfName('PLAYER7')[0] = 6));
  Check('id lookup', (DB.IndexOfId(1234) = 1233) and (DB.IndexOfId(0) = -1) and (DB.IndexOfId(99999) = -1));

  Top := DB.Ranks[RANK_POINTS].At(1);
  Ok := True;
  for i := 0 to DB.ProfileCount - 1 do
    if DB.Profiles[i]^.Points > DB.Profiles[Top]^.Points then
      Ok := False;
  Check('rank 1 has the most points', Ok and (DB.Ranks[RANK_POINTS].Count = 2000));

  for i := 1 to 5 do
  begin
    DB.SetNow(EncodeDate(2026, 9, 15) + i);
    DB.NoteName(0, 'Alias' + IntToStr(i), True, 0, 0, 3);
  end;
  Check('name history limit keeps the most recent', (Length(DB.Profiles[0]^.OtherNames) = 3) and
    HasName(DB.Profiles[0], 'Alias5') and not HasName(DB.Profiles[0], 'Player1'));
  Check('Steam accounts are found by SteamID only', (DB.IndexOfSteam('S100003') = 2) and not Contains(DB.IndexesOfHwid('HWID3'), 2));

  a := DB.IndexOfId(10);
  b := DB.IndexOfId(11);
  DB.Profiles[a]^.Kills := 40;
  DB.Profiles[b]^.Kills := 2;
  DB.MergeProfile(b, a, 1000);
  Check('merge moves stats and names', (DB.Profiles[b]^.Kills = 42) and not Contains(DB.IndexesOfHwid('HWID10'), a) and
    Contains(DB.IndexesOfHwid('HWID11'), b) and HasName(DB.Profiles[b], 'Player10'));
  Check('merged profile is gone', (DB.IndexOfId(10) = -1) and (DB.Profiles[a] = nil) and (DB.Holes = 1) and
    (DB.LiveProfiles = 1999) and (DB.Ranks[RANK_POINTS].Count = 1999));

  Check('map lookup and creation', (DB.FindMap('ctf_Ash', True) = 0) and (DB.FindMap('CTF_ash', False) = 0) and
    (DB.FindMap('ctf_Run', False) = -1) and (DB.Maps[0].ID = 1) and (DB.Server.NextMapID = 2));
  { a map saved before the match lengths were split: a sum that mixes matches of 5.0 (not counted)
    with two of an early 5.1 build }
  DB.Maps[0].MatchDurationSum := 3000;
  DB.Maps[0].MatchDurationCount := 2;
  DB.Maps[0].ActiveMapPlays := 5;
  DB.TouchMap(0);

  IO := TStoreIO.Create(Dir, 'zitrostats.zsdb', 'zitrostats.journal');
  W := TStoreWriter.Create(IO, 0);
  DB.BeginSnapshot(W);
  n := 0;
  while not DB.ContinueSnapshot(W, 128) do
  begin
    Inc(n);
    if n = 3 then
    begin
      { changes while the snapshot is being written }
      DB.Profiles[b]^.Kills := 777;
      DB.Touch(b);
      DB.FlushJournal(W, False);
    end;
  end;
  W.CommitSnapshot(1, '');
  Check('snapshot written in pieces', WaitCommit(IO, 1) and (n > 10));
  DB.Profiles[1]^.Deaths := 55;
  DB.Touch(1);
  DB.DeleteProfile(DB.IndexOfId(20));
  DB.FlushJournal(W, True);
  while not IO.Idle do
    Sleep(2);
  Gen := W.Generation;
  W.Free;
  IO.Free;

  DB2 := TStatsDB.Create;
  DB2.SetNow(DB.NowValue);
  Check('store loads', StoreLoad(Dir, 'zitrostats.zsdb', 'zitrostats.journal', St, Info) = slLoaded);
  DB2.TakeState(St);
  Check('same live profiles after reload', (DB2.LiveProfiles = DB.LiveProfiles) and (DB2.LiveProfiles = 1998));
  n := DB2.IndexOfId(11);
  Check('journal changes applied', (n >= 0) and (DB2.Profiles[n]^.Kills = 777) and (DB2.Profiles[DB2.IndexOfId(2)]^.Deaths = 55) and
    (DB2.IndexOfId(20) = -1) and (DB2.IndexOfSteam('S100003') = DB2.IndexOfId(3)));
  Check('ranking rebuilt on load', (DB2.Ranks[RANK_POINTS].Count = 1998) and
    (DB2.Profiles[DB2.Ranks[RANK_POINTS].At(1)]^.ID = DB.Profiles[DB.Ranks[RANK_POINTS].At(1)]^.ID));
  Check('counters restored', (DB2.Server.NextProfileID = 2001) and (DB2.MapCount = 1));
  Check('match lengths saved before 5.1 are set aside once', (DB2.Maps[0].MatchDurationBase = 3000) and
    (DB2.Maps[0].MatchDurationSum = 3000) and (DB2.Maps[0].MatchDurationCount = 0) and DB2.Server.MatchLengthsSplit);
  WriteLn('       generation ', Gen, ', journal records ', Info.JournalRecords);

  Deleted := 0;
  for i := 500 to 799 do
    if DB2.IndexOfId(i) >= 0 then
    begin
      DB2.DeleteProfile(DB2.IndexOfId(i));
      Inc(Deleted);
    end;
  Gen := DB2.IndexGen;
  Check('compaction runs when enough holes', DB2.CompactIfNeeded(False) and (DB2.Holes = 0) and (DB2.IndexGen <> Gen));
  n := DB2.IndexOfSteam('S100012');
  Check('lookups valid after compaction', (n >= 0) and (DB2.Profiles[n]^.ActiveSteam = 'S100012') and
    (DB2.Profiles[DB2.IndexOfId(1500)]^.ID = 1500) and (DB2.LiveProfiles = 1998 - Deleted) and
    (DB2.Ranks[RANK_POINTS].Count = DB2.LiveProfiles));

  Deleted := 0;
  DB2.BeginBulkDelete;
  for i := 1000 to 1199 do
    if DB2.IndexOfId(i) >= 0 then
    begin
      DB2.DeleteProfile(DB2.IndexOfId(i));
      Inc(Deleted);
    end;
  Check('bulk delete leaves the ranking to the rebuild', (Deleted > 0) and (DB2.Ranks[RANK_POINTS].Count > DB2.LiveProfiles));
  DB2.EndBulkDelete;
  Check('bulk delete rebuilds the ranking once', (DB2.Ranks[RANK_POINTS].Count = DB2.LiveProfiles) and
    (DB2.IndexOfId(1000) = -1) and DB2.Valid(DB2.Ranks[RANK_POINTS].At(1)));

  DB2.Free;
  DB.Free;

  { Engine = mysql: the accounts waiting for the shared database are kept by their place in the
    list, and a compaction moves them }
  Dir3 := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'db_tmp3');
  CleanDir(Dir3);
  DB3 := TStatsDB.Create;
  DB3.SetNow(EncodeDate(2026, 9, 20));
  DB3.SyncOn := True;
  for i := 1 to 600 do
    DB3.CreateProfile('Sync' + IntToStr(i), '', 'SHW' + IntToStr(i), '10.1.0.1', 1000);
  { two accounts as the import of 4.x left them: damage only on the weapons, the Barrett record
    only as a total; and one of 5.x, whose total holds more than its weapons }
  P := DB3.Profiles[DB3.IndexOfId(5)];
  P^.Weapons[3].Damage := 500;
  P^.Weapons[8].Damage := 200;
  P^.DamageDealt := 100;
  P^.Weapons[3].DamageReceived := 50;
  P^.LongestBarrettDistance := 80;
  P := DB3.Profiles[DB3.IndexOfId(7)];
  P^.Weapons[3].Damage := 300;
  P^.DamageDealt := 1000;
  P^.DamageReceived := 20;
  DB3.TakeSyncWork(PIdx, MIdx, Srv, SIdx, Del);
  for i := 0 to High(PIdx) do
    DB3.Profiles[PIdx[i]]^.SyncDirty := False;
  for i := 1 to 300 do
    DB3.DeleteProfile(DB3.IndexOfId(i * 2));
  DB3.TakeSyncWork(PIdx, MIdx, Srv, SIdx, Del);
  Check('removed accounts go to the shared database', Length(Del) = 300);
  n := DB3.IndexOfId(501);
  DB3.Profiles[n]^.Kills := 5;
  DB3.Touch(n);
  DB3.Touch(DB3.IndexOfId(599));
  IO := TStoreIO.Create(Dir3, 'zitrostats.zsdb', 'zitrostats.journal');
  W := TStoreWriter.Create(IO, 0);
  DB3.FlushJournal(W, True);
  Check('compaction while accounts wait for the shared database', DB3.CompactIfNeeded(False) and (DB3.Holes = 0));
  DB3.TakeSyncWork(PIdx, MIdx, Srv, SIdx, Del);
  Check('the waiting accounts are still the same ones', (Length(PIdx) = 2) and DB3.Valid(PIdx[0]) and
    DB3.Valid(PIdx[1]) and (DB3.Profiles[PIdx[0]]^.ID = 501) and (DB3.Profiles[PIdx[1]]^.ID = 599) and
    (DB3.Profiles[PIdx[0]]^.Kills = 5));

  DB3.BeginSnapshot(W);
  while not DB3.ContinueSnapshot(W, 100) do ;
  W.CommitSnapshot(5, '');
  Check('snapshot for the journal checks', WaitCommit(IO, 5));
  { the shared database gives account #3 the number of account #1, which was just removed }
  DB3.DeleteProfile(DB3.IndexOfId(1));
  DB3.ChangeProfileId(DB3.IndexOfId(3), 1);
  DB3.FlushJournal(W, True);
  while not IO.Idle do
    Sleep(2);
  W.Free;
  IO.Free;
  DB3.Free;

  DB4 := TStatsDB.Create;
  DB4.SetNow(EncodeDate(2026, 9, 21));
  Check('store with the reused number loads', StoreLoad(Dir3, 'zitrostats.zsdb', 'zitrostats.journal', St, Info) = slLoaded);
  DB4.TakeState(St);
  n := DB4.IndexOfId(1);
  Check('a number removed and given again in one interval ends with its new account',
    DB4.Valid(n) and (DB4.Profiles[n]^.ActiveName = 'Sync3') and (DB4.IndexOfId(3) = -1) and (DB4.LiveProfiles = 299));
  n := DB4.IndexOfId(5);
  Check('4.x damage totals are taken from the weapons on load', DB4.Valid(n) and
    (Abs(DB4.Profiles[n]^.DamageDealt - 700) < 0.001) and (Abs(DB4.Profiles[n]^.DamageReceived - 50) < 0.001) and
    (Abs(DB4.Profiles[n]^.Weapons[8].LongestKill - 80) < 0.001) and DB4.Profiles[n]^.Dirty);
  n := DB4.IndexOfId(7);
  Check('totals of 5.x are left alone', DB4.Valid(n) and (Abs(DB4.Profiles[n]^.DamageDealt - 1000) < 0.001) and
    (Abs(DB4.Profiles[n]^.DamageReceived - 20) < 0.001) and not DB4.Profiles[n]^.Dirty);
  DB4.Free;

  { the MySQL copy (Engine = mirror): the name of an account on the other servers is one account of
    this server. Two accounts of one computer here - a registered one, and one without a password
    after its owner logged in there again - share the computer: it goes to one of them only. }
  DB5 := TStatsDB.Create;
  DB5.SetNow(EncodeDate(2026, 9, 22));
  a := DB5.CreateProfile('Owner', '', 'HWPAIR', '10.2.0.1', 1000);
  b := DB5.CreateProfile('Guest', '', 'hwpair', '10.2.0.2', 1000);
  DB5.Profiles[a]^.PassHash := 'hash';
  Check('two accounts of one computer: the computer goes to the one without a password',
    (SharedIdentityOf(DB5, a) = '') and (SharedIdentityOf(DB5, b) <> '') and
    (SharedIdentityOf(DB5, b) = SharedIdentity(DB5.Profiles[a]^)));
  c := DB5.CreateProfile('Alone', '', 'HWALONE', '10.2.0.3', 1000);
  DB5.Profiles[c]^.PassHash := 'hash';
  Check('the only account of a computer keeps it, with a password too',
    (SharedIdentityOf(DB5, c) <> '') and (SharedIdentityOf(DB5, c) = SharedIdentity(DB5.Profiles[c]^)));
  d := DB5.CreateProfile('Twin', '', 'HWTWIN', '', 1000);
  e := DB5.CreateProfile('Twin2', '', 'HWTWIN', '', 1000);
  Check('of two without a password the older one keeps the computer',
    (SharedIdentityOf(DB5, d) <> '') and (SharedIdentityOf(DB5, e) = ''));
  n := DB5.CreateProfile('Steamer', 'S4242', 'HWPAIR', '', 1000);
  Check('a Steam account is its SteamID, whatever computer it plays on', SharedIdentityOf(DB5, n) = 'S4242');
  DB5.Free;
  { the whole record of an account that did not play (the daily balance changed its points, or a
    reset) goes along in the whole pass of the hour, not only after its next game }
  Check('a whole pass sends the record of an account that did not play', MirrorRecordDue(True, False, Now - 30, Now - 1 / 24));
  Check('a pass in between sends it only after a game', not MirrorRecordDue(False, False, Now - 30, Now - 1 / 24) and
    MirrorRecordDue(False, False, Now - 1 / 1440, Now - 1 / 24) and MirrorRecordDue(False, True, Now - 30, Now - 1 / 24));
  { settings.ini reloaded from Engine = mysql to mirror: the exchange with the shared database goes
    on until the next start, and the copy waits for that start instead of running next to it }
  Eng := TZSEngine.Create(Dir);
  Eng.Cfg.MySQLEnabled := True;
  Check('Engine = mirror: the copy runs', MirrorOn(Eng));
  Eng.SqlState := TObject.Create;
  Check('the copy does not run next to an exchange with a shared database', not MirrorOn(Eng));
  Eng.SqlState.Free;
  Eng.SqlState := nil;
  Eng.Free;

  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Failures);
end.
