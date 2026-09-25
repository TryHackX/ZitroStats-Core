program bench_db;

{ How long the heavy paths take on a large ranking. Default 60000 accounts, "bench_db 20000" for
  a smaller run. Nothing here checks behaviour - it only prints timings, so the numbers can be
  compared before and after a change. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, zs_types, zs_util, zs_fileio, zs_store, zs_rank, zs_db;

var
  DB: TStatsDB;
  IO: TStoreIO;
  W: TStoreWriter;
  T0: Int64;

procedure Start;
begin
  T0 := MonoMs;
end;

procedure Done(const What: AnsiString);
begin
  WriteLn(Format('%-44s %6d ms', [What, MonoMs - T0]));
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

function WaitCommit(Tag: LongInt): Boolean;
var
  R: TStoreResult;
  Deadline: Int64;
begin
  Deadline := MonoMs + 120000;
  repeat
    while IO.PollResult(R) do
      if (R.Kind = sjSnapshotCommit) and (R.Tag = Tag) then
        Exit(R.Ok);
    Sleep(2);
  until MonoMs > Deadline;
  Result := False;
end;

var
  Dir, Name: AnsiString;
  Count, i, k, n, Hits: LongInt;
  St: TStoreState;
  Info: TStoreLoadInfo;
  Low: AnsiString;
begin
  Count := StrToIntDef(ParamStr(1), 60000);
  Dir := ExpandFileName('build' + PathDelim + 'test' + PathDelim + 'bench_tmp');
  CleanDir(Dir);
  WriteLn('ZitroStats benchmark, ', Count, ' accounts');

  DB := TStatsDB.Create;
  DB.SetNow(Now);
  Start;
  for i := 1 to Count do
  begin
    n := DB.CreateProfile('Player' + IntToStr(i), '', 'HWID' + IntToStr(i mod (Count div 2 + 1)),
      '10.' + IntToStr(i mod 250) + '.0.1', 1000);
    DB.Profiles[n]^.Points := 1000 + (i * 37) mod 2000;
    DB.Profiles[n]^.Kills := (i * 7) mod 5000;
    DB.Profiles[n]^.Deaths := (i * 5) mod 4000;
    DB.Profiles[n]^.Shots := 20000;
    DB.Profiles[n]^.ShotsHits := (i * 11) mod 9000;
    DB.Profiles[n]^.LastPlayedTime := DB.NowValue - (i mod 400);
    DB.RefreshRanks(n);
  end;
  Done('create accounts with live ranking');

  Start;
  DB.RebuildRanks;
  Done('rebuild every ranking list');

  Start;
  for i := 1 to 1000 do
    if DB.IndexOfId(1 + (i * 61) mod Count) < 0 then
      WriteLn('       lookup by id failed');
  Done('1000 lookups by id');

  Start;
  for i := 1 to 1000 do
    if Length(DB.IndexesOfName('Player' + IntToStr(1 + (i * 61) mod Count))) = 0 then
      WriteLn('       lookup by name failed');
  Done('1000 lookups by name');

  { the same work a fragment search does: every account, no allocation }
  Low := 'player4242';
  Start;
  Hits := 0;
  for k := 0 to DB.ProfileCount - 1 do
    if DB.Valid(k) then
    begin
      Name := DB.Profiles[k]^.ActiveName;
      if (Length(Name) >= Length(Low)) and SameText(Copy(Name, 1, Length(Low)), Low) then
        Inc(Hits);
    end;
  Done('full scan over all names');

  IO := TStoreIO.Create(Dir, 'bench.zsdb', 'bench.journal');
  W := TStoreWriter.Create(IO, 0);
  Start;
  DB.BeginSnapshot(W);
  while not DB.ContinueSnapshot(W, 512) do ;
  W.CommitSnapshot(1, '');
  if not WaitCommit(1) then
    WriteLn('       snapshot failed');
  Done('write the snapshot');

  Start;
  for i := 1 to Min(Count, 20000) do
  begin
    DB.Profiles[i - 1]^.Points := DB.Profiles[i - 1]^.Points + 1;
    DB.Touch(i - 1);
    DB.RefreshRanks(i - 1);
  end;
  DB.FlushJournal(W, True);
  while not IO.Idle do
    Sleep(2);
  Done('20000 point changes with journal');

  W.Free;
  IO.Free;
  DB.Free;

  Start;
  if StoreLoad(Dir, 'bench.zsdb', 'bench.journal', St, Info) <> slLoaded then
    WriteLn('       load failed');
  DB := TStatsDB.Create;
  DB.SetNow(Now);
  DB.TakeState(St);
  Done('read everything back');
  WriteLn(Format('%-44s %6d', ['accounts after the reload', DB.LiveProfiles]));
  WriteLn(Format('%-44s %6d', ['names starting with ' + Low, Hits]));
  DB.Free;
end.
