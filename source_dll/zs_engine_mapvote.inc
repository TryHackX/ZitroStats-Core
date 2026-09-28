{ zs_engine_mapvote.inc - the map vote (part of zs_engine)

  Players ask for a map with the commands (zs_cmd_mapvote.inc), with Soldat's vote menu and the
  server's /votemap (OnVoteMapStart: ZS_Ev_Vote kind 1; main.pas cancels Soldat's own vote) and vote
  with !v, F12 and /votemap <map> (the command, or OnVoteMap: kind 3). One vote runs at a time. It
  passes once [MapVote] VotePercent % of the players on the teams and the spectators (with
  CountSpectators = 0 only the spectators who started it or voted for it) voted for it, and fails
  after VoteSeconds. main.pas shows it to the clients as
  Soldat's own vote (ACT_VOTE_START: Game.StartVoteMap with a vote percent of 200, so that Soldat
  never lets it pass by itself while F12 still works), puts the percent back once that vote is over
  (ACT_VOTE_END) and changes the map (ACT_MAP_CHANGE). The maps come from the maps list main.pas
  sends (ZS_Ev_Map_List) and from the maps folder (zs_maps, read on a thread of its own). A vote
  counts VoteStarts on the map it started on, and VotesPassed there and VotedIn on the map it chose
  when it passes. }

{ "Also matching: a, b, c (+4 more)." - the other maps of the same kind of match, '' for none }
function MapOthersText(const Names: TStringArray; const S: TMapSearch): AnsiString;
var
  k, Shown, Rest: LongInt;
  Line, N: AnsiString;
begin
  Result := '';
  Line := '';
  Shown := 0;
  Rest := S.OtherCount;
  for k := 0 to High(S.Others) do
  begin
    N := Names[S.Others[k]];
    { the same map twice in the list is one map }
    if SameText(N, Names[S.Best]) then
    begin
      Dec(Rest);
      Continue;
    end;
    { the line stays short whatever the names are }
    if (Shown > 0) and (Length(Line) + Length(N) > 70) then
      Break;
    if Line <> '' then
      Line := Line + ', ';
    Line := Line + N;
    Inc(Shown);
    Dec(Rest);
  end;
  if Shown = 0 then
    Exit;
  Result := 'Also matching: ' + Line;
  if Rest > 0 then
    Result := Result + Format(' (+%d more)', [Rest]);
  Result := Result + '.';
end;

{ ---------------- helpers ---------------- }

{ "1 map", "7 maps" }
function CountOf(N: LongInt; const One, Many: AnsiString): AnsiString;
begin
  if N = 1 then
    Result := '1 ' + One
  else
    Result := IntToStr(N) + ' ' + Many;
end;

{ a player the vote counts: a human on a team, a spectator with CountSpectators = 1, and with 0 a
  spectator who started the vote or voted for it (a voter and a yes of that vote); every human
  may vote }
function TZSEngine.MvEligible(S: LongInt): Boolean;
begin
  Result := (S >= 1) and (S <= MAX_PLAYERS) and Live[S].Active and Live[S].Human and not Live[S].PendingKick and
    ((Live[S].Team <> TEAM_SPEC) or Cfg.MapVoteCountSpectators or MV.Voted[S]);
end;

procedure TZSEngine.MvCount(out Yes, Voters: LongInt);
var
  S: LongInt;
begin
  Yes := 0;
  Voters := 0;
  for S := 1 to MAX_PLAYERS do
    if MvEligible(S) then
    begin
      Inc(Voters);
      if MV.Voted[S] then
        Inc(Yes);
    end;
end;

{ VotePercent of the players who may vote, and never without a vote }
function TZSEngine.MvPasses(Yes, Voters: LongInt): Boolean;
begin
  Result := (Voters > 0) and (Yes > 0) and (Int64(Yes) * 100 >= Int64(Cfg.MapVotePercent) * Voters);
end;

function TZSEngine.MvCountText(Yes, Voters: LongInt): AnsiString;
begin
  Result := Format('%d/%d, %d%% needed', [Yes, Voters, Cfg.MapVotePercent]);
end;

{ a command of the map vote that answers on this server }
function TZSEngine.MvCmdOn(Bit: LongInt): Boolean;
begin
  Result := Cfg.MapVoteEnabled and (Cfg.MapVoteCommands and Bit <> 0);
end;

{ how a player votes; F12 works whatever the switches say }
function TZSEngine.MvVoteKeys: AnsiString;
begin
  if MvCmdOn(MVC_VOTE) then
    Result := '!v or F12'
  else
    Result := 'F12';
end;

procedure TZSEngine.MvAction(Kind, P1: LongInt; const Text: AnsiString);
var
  A: TZSAction;
begin
  A := NewAction(Kind, 0, 0, Text);
  A.P1 := P1;
  EmitAction(A);
end;

function TZSEngine.MapVoteCurrentMap: AnsiString;
begin
  Result := MV.CurMap;
  if Result = '' then
    Result := Match.MapName;
end;

function TZSEngine.MapVoteSecondsLeft: LongInt;
begin
  Result := 0;
  if MV.Active then
    Result := Max(0, (MV.StartTick + Cfg.MapVoteSeconds * TICKS_PER_SECOND - GameTick + TICKS_PER_SECOND - 1) div
      TICKS_PER_SECOND);
end;

function TZSEngine.MapVoteYesCount(out Voters: LongInt): LongInt;
begin
  MvCount(Result, Voters);
end;

{ the commands that start a vote, "!nextmap, !lastmap, !randommap or !map <part>" }
function TZSEngine.MapVoteStartHint: AnsiString;
var
  Parts: array[0..3] of AnsiString;
  n, k: LongInt;
begin
  n := 0;
  if MvCmdOn(MVC_NEXTMAP) then
  begin
    Parts[n] := '!nextmap';
    Inc(n);
  end;
  if MvCmdOn(MVC_LASTMAP) then
  begin
    Parts[n] := '!lastmap';
    Inc(n);
  end;
  if MvCmdOn(MVC_RANDOMMAP) then
  begin
    Parts[n] := '!randommap';
    Inc(n);
  end;
  if MvCmdOn(MVC_MAP) then
  begin
    Parts[n] := '!map <part>';
    Inc(n);
  end
  else if MvCmdOn(MVC_VOTEMAP) then
  begin
    Parts[n] := '!votemap <part>';
    Inc(n);
  end;
  Result := '';
  for k := 0 to n - 1 do
  begin
    if k > 0 then
    begin
      if k = n - 1 then
        Result := Result + ' or '
      else
        Result := Result + ', ';
    end;
    Result := Result + Parts[k];
  end;
end;

{ ---------------- the maps ---------------- }

function TZSEngine.MapVoteFolder: AnsiString;
begin
  if Trim(Cfg.MapVoteMapsFolder) <> '' then
    Result := ExcludeTrailingPathDelimiter(ExpandFileName(ResolvePath(Cfg.MapVoteMapsFolder)))
  else
    Result := DefaultMapsFolder(ScriptDir);
end;

procedure TZSEngine.MvScan(const Folder: AnsiString; NowMs: Int64);
begin
  if MapCat = nil then
    MapCat := TMapCatalog.Create;
  MapCat.RequestScan(Folder);
  MV.FolderAsked := Folder;
  if Cfg.MapVoteRescanMinutes > 0 then
    MV.NextScanMs := NowMs + Int64(Cfg.MapVoteRescanMinutes) * 60000
  else
    MV.NextScanMs := High(Int64);
end;

{ /zs_maps rescan: Asker hears how it went }
procedure TZSEngine.MapVoteRescan(Asker: LongInt);
begin
  MV.ScanAsker := Asker;
  MvScan(MapVoteFolder, MonoMs);
end;

{ the engine's timers: the maps folder is read at the start, every RescanMinutes and when its
  setting changes, and a finished scan is taken over }
procedure TZSEngine.MapVoteTimers(NowMs: Int64);
var
  D: TMapCatalogData;
  Folder: AnsiString;
  Added, Removed, Odd, k: LongInt;
begin
  if not FReady then
    Exit;
  if Cfg.MapVoteEnabled then
  begin
    Folder := MapVoteFolder;
    if (Folder <> MV.FolderAsked) or (NowMs >= MV.NextScanMs) then
      MvScan(Folder, NowMs);
  end;
  if (MapCat = nil) or not MapCat.TakeResult(D) then
    Exit;
  CatalogDiff(MV.Files.Maps, D.Maps, Added, Removed);
  Odd := 0;
  for k := 0 to High(D.Maps) do
    if D.Maps[k].OddExt then
      Inc(Odd);
  MV.Files := D;
  MV.FilesKnown := True;
  { the first scan goes to the console, without the path, which /zs_maps shows }
  if not MV.ScanReported then
  begin
    MV.ScanReported := True;
    if D.Error <> '' then
      WriteServer('[ZitroStats] map vote: the maps folder could not be read (/zs_maps): ' + Copy(D.Error, 1, 40))
    else if not D.Found then
      WriteServer('[ZitroStats] map vote: the maps folder was not found, only the maps list can be voted (/zs_maps)')
    else if Odd > 0 then
      WriteServer(Format('[ZitroStats] map vote: %d maps in the maps folder, %d not ending in ".pms" (/zs_maps)',
        [Length(D.Maps), Odd]))
    else
      WriteServer(Format('[ZitroStats] map vote: %d maps in the maps folder', [Length(D.Maps)]));
  end;
  if MV.ScanAsker >= 0 then
  begin
    if D.Error <> '' then
      Say(MV.ScanAsker, '[Maps] The maps folder could not be read: ' + D.Error, CLR_BAD)
    else if not D.Found then
      Say(MV.ScanAsker, '[Maps] The maps folder was not found: ' + D.Folder, CLR_BAD)
    else
      Say(MV.ScanAsker, Format('[Maps] %d maps in the folder (%d new, %d gone), read in %d ms.', [Length(D.Maps), Added,
        Removed, D.ScanMs]), CLR_GOOD);
    MV.ScanAsker := -1;
  end;
end;

{ the maps list of the server: at the start of the script, after every map change, after /addmap,
  /delmap and /loadlist, and when the check of main.pas sees another list }
procedure TZSEngine.EvMapList(var E: TZSEvent);
var
  Line: AnsiString;
begin
  MV.List := SplitMapList(E.S1);
  MV.ListOrder := ListOrderOf(MV.List);
  MV.ListCurrent := E.I[1];
  MV.ListReason := E.I[2];
  MV.ListTick := GameTick;
  MV.ListKnown := True;
  if E.I[2] <> MAPLIST_START then
    Exit;
  { the script started: in the middle of a map, which no vote has to wait for; the vote of the
    script that ran before is gone with it (Soldat's vote, the vote percent it kept) }
  MV.MapStartTick := GameTick - Cfg.MapVoteBlockAfterChange * TICKS_PER_SECOND - 1;
  MV.ChangingUntil := 0;
  if MV.Active then
    MvFinish('cancelled', Format('The script was loaded again: the vote for %s is over.', [MV.Target]), CLR_WARN);
  { a /recompile (or a reload) while people play: the admins in the game hear that it worked }
  if HumansOnline > 0 then
  begin
    if FScriptKept then
      Line := Format('ZitroStats %s: script compiled and running (library kept its data: %s, %s)',
        [ZS_VERSION_STR, CountOf(DB.LiveProfiles, 'account', 'accounts'), CountOf(DB.MapCount, 'map', 'maps')])
    else
      Line := Format('ZitroStats %s: script compiled and running, loaded %s, %s in %d ms',
        [ZS_VERSION_STR, CountOf(DB.LiveProfiles, 'account', 'accounts'), CountOf(DB.MapCount, 'map', 'maps'),
         FLoadMs]);
    NotifyAdmins(Line, CLR_GOOD);
  end;
  FScriptKept := False;
end;

function TZSEngine.MapVoteNextMap: AnsiString;
var
  n, i: LongInt;
begin
  { the way Soldat picks it (Game.NextMap): the entry after CurrentMapId, the first after the last }
  Result := '';
  n := Length(MV.List);
  if not MV.ListKnown or (n = 0) then
    Exit;
  i := MV.ListCurrent + 1;
  if (i < 0) or (i >= n) then
    i := 0;
  Result := MV.List[i];
end;

function TZSEngine.MapVoteLastMap: AnsiString;
var
  k, Best: LongInt;
  Cur: AnsiString;
begin
  Result := MV.PrevMap;
  if Result <> '' then
    Exit;
  { no map change seen since the library started: the map the statistics saw running last (loaded,
    or played before LastLoadedTime was kept) }
  Cur := MapVoteCurrentMap;
  Best := -1;
  for k := 0 to DB.MapCount - 1 do
    if (Max(DB.Maps[k].LastLoadedTime, DB.Maps[k].LastPlayedTime) > 0) and not SameText(DB.Maps[k].MapName, Cur) and
       ((Best < 0) or (Max(DB.Maps[k].LastLoadedTime, DB.Maps[k].LastPlayedTime) >
        Max(DB.Maps[Best].LastLoadedTime, DB.Maps[Best].LastPlayedTime))) then
      Best := k;
  if Best >= 0 then
    Result := DB.Maps[Best].MapName;
end;

function TZSEngine.MapVoteRandomMap(out Why: AnsiString): AnsiString;
var
  Pool: TStringArray;
  n, k, Count: LongInt;
  Cur, Name: AnsiString;
  FromFolder: Boolean;
begin
  Result := '';
  Why := '';
  Cur := MapVoteCurrentMap;
  { AllowAnyMap: every map of the folder (a map of the list without a file could not load);
    otherwise the maps list }
  FromFolder := Cfg.MapVoteAllowAnyMap and MV.FilesKnown and (Length(MV.Files.Maps) > 0);
  if not FromFolder and not MV.ListKnown then
  begin
    Why := 'The maps of the server are not known yet, try again in a moment.';
    Exit;
  end;
  if FromFolder then
    Count := Length(MV.Files.Maps)
  else
    Count := Length(MV.List);
  Pool := nil;
  SetLength(Pool, Count);
  n := 0;
  for k := 0 to Count - 1 do
  begin
    if FromFolder then
      Name := MV.Files.Maps[k].Name
    else
      Name := MV.List[k];
    if (Name = '') or SameText(Name, Cur) then
      Continue;
    if Cfg.MapVoteFilterByStyle and not MapFitsStyle(Name, Match.GameStyle) then
      Continue;
    Pool[n] := Name;
    Inc(n);
  end;
  if n = 0 then
  begin
    if Cfg.MapVoteFilterByStyle then
      Why := 'There is no other map of this game mode to pick.'
    else
      Why := 'There is no other map to pick.';
    Exit;
  end;
  Result := Pool[RandomIndex(n)];
end;

function TZSEngine.MapVoteFind(const Text: AnsiString; out Target, Why, Others: AnsiString): Boolean;
var
  T, Low: AnsiString;
  Pass, k, n: LongInt;
  S: TMapSearch;
  Outside: TStringArray;
  FromFolder: Boolean;
begin
  Result := False;
  Target := '';
  Why := '';
  Others := '';
  T := Trim(Text);
  if SameText(ExtractFileExt(T), '.pms') then
    T := Trim(Copy(T, 1, Length(T) - 4));
  if T = '' then
  begin
    Why := 'Which map? Give its name or a part of it.';
    Exit;
  end;
  if not MV.ListKnown and not MV.FilesKnown then
  begin
    Why := 'The maps of the server are not known yet, try again in a moment.';
    Exit;
  end;
  { the maps of the folder that are not in the list come second }
  Outside := nil;
  SetLength(Outside, Length(MV.Files.Maps));
  n := 0;
  for k := 0 to High(MV.Files.Maps) do
    if FindInList(MV.List, MV.ListOrder, MV.Files.Maps[k].Name) < 0 then
    begin
      Outside[n] := MV.Files.Maps[k].Name;
      Inc(n);
    end;
  SetLength(Outside, n);
  for Pass := 1 to 2 do
  begin
    { a space may stand for the "_" of a name: "!map ctf ash" }
    if Pass = 1 then
      Low := LowerCase(T)
    else if Pos(' ', T) > 0 then
      Low := LowerCase(StringReplace(T, ' ', '_', [rfReplaceAll]))
    else
      Break;
    FromFolder := False;
    S := SearchNames(MV.List, Low, MV_OTHERS_SHOWN);
    if S.Best < 0 then
    begin
      S := SearchNames(Outside, Low, MV_OTHERS_SHOWN);
      FromFolder := True;
    end;
    if S.Best < 0 then
      Continue;
    if FromFolder then
    begin
      if not Cfg.MapVoteAllowAnyMap then
      begin
        Why := Outside[S.Best] + ' is not in the maps list (only those maps can be voted).';
        Exit;
      end;
      Target := Outside[S.Best];
      Others := MapOthersText(Outside, S);
    end
    else
    begin
      Target := MV.List[S.Best];
      Others := MapOthersText(MV.List, S);
    end;
    Exit(True);
  end;
  Why := Format('No map matches "%s"', [Copy(T, 1, 30)]);
  if MvCmdOn(MVC_MAPS) and MvCmdOn(MVC_ALLMAPS) then
    Why := Why + ' - see !maps or !allmaps.'
  else if MvCmdOn(MVC_MAPS) then
    Why := Why + ' - see !maps.'
  else if MvCmdOn(MVC_ALLMAPS) then
    Why := Why + ' - see !allmaps.'
  else
    Why := Why + '.';
end;

{ ---------------- the vote ---------------- }

function TZSEngine.MvStarterKey(Slot: LongInt): LongInt;
var
  Idx: LongInt;
begin
  Idx := Identity.ProfileIndex(Slot);
  if DB.Valid(Idx) then
    Result := DB.Profiles[Idx]^.ID
  else
    Result := -Slot;
end;

{ the ticks the starter Key still has to wait }
function TZSEngine.MvCooldownLeft(Key: LongInt): LongInt;
var
  k: LongInt;
begin
  Result := 0;
  for k := 0 to High(MV.Starters) do
    if MV.Starters[k].Key = Key then
      Exit(Max(0, MV.Starters[k].UntilTick - GameTick));
end;

procedure TZSEngine.MvNoteStarter(Key: LongInt);
var
  k, n: LongInt;
begin
  { the waits that are over go }
  n := 0;
  for k := 0 to High(MV.Starters) do
    if (MV.Starters[k].UntilTick > GameTick) and (MV.Starters[k].Key <> Key) then
    begin
      MV.Starters[n] := MV.Starters[k];
      Inc(n);
    end;
  SetLength(MV.Starters, n + 1);
  MV.Starters[n].Key := Key;
  MV.Starters[n].UntilTick := GameTick + Cfg.MapVoteStarterCooldown * TICKS_PER_SECOND;
end;

procedure TZSEngine.SendMapVoteConfig;
var
  A: TZSAction;
begin
  A := NewAction(ACT_MAPVOTE, 0, 0, '');
  if Cfg.MapVoteEnabled then
    A.P1 := MV_ENABLED;
  A.P2 := Cfg.MapVoteRestorePercent;
  EmitAction(A);
end;

{ the vote is over: Outcome for /zs_mapvote and a late F12, Line for everybody }
procedure TZSEngine.MvFinish(const Outcome, Line: AnsiString; Color: LongInt);
begin
  MV.Active := False;
  MV.LastTarget := MV.Target;
  MV.LastResult := Outcome;
  MV.LastEndTick := GameTick;
  if MV.Shown then
    MvAction(ACT_VOTE_END, Cfg.MapVoteRestorePercent, '');
  MV.Shown := False;
  FillChar(MV.Voted, SizeOf(MV.Voted), 0);
  if Line <> '' then
    Broadcast(Line, Color);
end;

procedure TZSEngine.MvPass(const Line: AnsiString);
var
  M: LongInt;
  Next: AnsiString;
begin
  M := Match.MapIndex;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    Inc(DB.Maps[M].VotesPassed);
    DB.TouchMap(M);
  end;
  M := DB.FindMap(MV.Target, True);
  if M >= 0 then
  begin
    Inc(DB.Maps[M].VotedIn);
    DB.TouchMap(M);
  end;
  MV.ChangeTarget := MV.Target;
  MV.ChangeDue := GameTick + MV_CHANGE_WAIT_TICKS;
  { the next map of the list goes with Map.NextMap: the list goes on after it instead of coming
    back to it }
  Next := MapVoteNextMap;
  MvAction(ACT_MAP_CHANGE, Ord((Next <> '') and (Next = MV.Target)), MV.Target);
  MvFinish('passed', Line, CLR_GOOD);
end;

procedure TZSEngine.MvStart(Slot: LongInt; const Target: AnsiString; Key: LongInt);
var
  M, Yes, Voters: LongInt;
begin
  MV.Active := True;
  MV.Target := Target;
  MV.StarterName := Live[Slot].Name;
  MV.StartTick := GameTick;
  MV.Shown := False;
  FillChar(MV.Voted, SizeOf(MV.Voted), 0);
  { who asks for a map votes for it }
  MV.Voted[Slot] := True;
  MvNoteStarter(Key);
  M := Match.MapIndex;
  if (M >= 0) and (M < DB.MapCount) then
  begin
    Inc(DB.Maps[M].VoteStarts);
    DB.TouchMap(M);
  end;
  MvCount(Yes, Voters);
  if MvPasses(Yes, Voters) then
  begin
    { nobody else to ask: the clients never see a vote }
    MvPass(Format('%s wants %s: the vote passed at once (%d/%d).', [MV.StarterName, Target, Yes, Voters]));
    Exit;
  end;
  MV.Shown := True;
  MV.SoldatUntil := GameTick + MV_SOLDAT_VOTE_TICKS;
  MvAction(ACT_VOTE_START, 0, Target);
  Broadcast(Format('%s wants %s: %s to vote, %d s, %d%% needed (%d/%d).', [MV.StarterName, Target, MvVoteKeys,
    Cfg.MapVoteSeconds, Cfg.MapVotePercent, Yes, Voters]), CLR_GOOD);
end;

{ what a vote with no vote running gets: a late F12 for the vote that just ended, or how to start one }
procedure TZSEngine.MvSayNoVote(Slot: LongInt);
var
  Hint: AnsiString;
begin
  if (MV.LastTarget <> '') and (GameTick < MV.SoldatUntil) then
    Say(Slot, Format('The vote for %s is over (%s).', [MV.LastTarget, MV.LastResult]), CLR_WARN)
  else
  begin
    Hint := MapVoteStartHint;
    if Hint <> '' then
      Say(Slot, 'No map vote is running. Start one with ' + Hint + '.', CLR_WARN)
    else
      Say(Slot, 'No map vote is running.', CLR_WARN);
  end;
end;

{ F12 and the vote menu send /votemap <map>: the map of a vote of ours that ended while Soldat's vote
  still shows it on the clients gets a late vote, never a new vote }
function TZSEngine.MapVoteLate(Slot: LongInt; const Text: AnsiString): Boolean;
begin
  Result := not MV.Active and (MV.LastTarget <> '') and (GameTick < MV.SoldatUntil) and
    SameText(Trim(Text), MV.LastTarget);
  if Result then
    Say(Slot, Format('The vote for %s is over (%s).', [MV.LastTarget, MV.LastResult]), CLR_WARN);
end;

procedure TZSEngine.MapVoteYes(Slot: LongInt);
var
  Yes, Voters: LongInt;
begin
  if not SlotValid(Slot) or not Live[Slot].Human then
    Exit;
  if not MV.Active then
  begin
    MvSayNoVote(Slot);
    Exit;
  end;
  { a player the server is kicking counts for nothing }
  if Live[Slot].PendingKick then
    Exit;
  MvCount(Yes, Voters);
  if MV.Voted[Slot] then
  begin
    Say(Slot, Format('You voted for %s already (%s, %d s left).', [MV.Target, MvCountText(Yes, Voters),
      MapVoteSecondsLeft]), CLR_WARN);
    Exit;
  end;
  { a spectator who votes joins the voters of this vote with CountSpectators = 0 }
  MV.Voted[Slot] := True;
  MvCount(Yes, Voters);
  Broadcast(Format('%s voted for %s (%s).', [Live[Slot].Name, MV.Target, MvCountText(Yes, Voters)]), CLR_HINT);
  if MvPasses(Yes, Voters) then
    MvPass(Format('%s won the vote (%d/%d).', [MV.Target, Yes, Voters]));
end;

{ Slot asks for a vote for Target (as the maps list or the folder writes it). A vote for the map of
  the vote that runs is a yes vote. }
function TZSEngine.MapVoteRequest(Slot: LongInt; const Target: AnsiString): LongInt;
var
  Yes, Voters, Left, Key: LongInt;
  Spec: AnsiString;
begin
  Result := MVR_REFUSED;
  if not Cfg.MapVoteEnabled or not SlotValid(Slot) or not Live[Slot].Human or (Trim(Target) = '') then
    Exit;
  if MV.Active then
  begin
    if SameText(Target, MV.Target) then
    begin
      MapVoteYes(Slot);
      Exit(MVR_VOTED);
    end;
    Say(Slot, Format('A vote for %s is running (%d s left): %s to vote for it.', [MV.Target, MapVoteSecondsLeft,
      MvVoteKeys]), CLR_WARN);
    Exit;
  end;
  if (MV.ChangeTarget <> '') or (GameTick < MV.ChangingUntil) then
  begin
    Say(Slot, 'The map is changing, wait a moment.', CLR_WARN);
    Exit;
  end;
  if SameText(Target, MapVoteCurrentMap) then
  begin
    Say(Slot, Target + ' is the map being played.', CLR_WARN);
    Exit;
  end;
  if FindInList(MV.List, MV.ListOrder, Target) < 0 then
  begin
    if not MV.FilesKnown or (FindCatalog(MV.Files.Maps, Target) < 0) then
    begin
      Say(Slot, Target + ' is not a map of this server.', CLR_WARN);
      Exit;
    end;
    if not Cfg.MapVoteAllowAnyMap then
    begin
      Say(Slot, Target + ' is not in the maps list (only those maps can be voted).', CLR_WARN);
      Exit;
    end;
  end;
  { a player the server is kicking counts for nothing }
  if Live[Slot].PendingKick then
    Exit;
  Left := MV.MapStartTick + Cfg.MapVoteBlockAfterChange * TICKS_PER_SECOND - GameTick;
  if Left > 0 then
  begin
    Say(Slot, Format('No map vote in the first %d s of a map (%d s left).', [Cfg.MapVoteBlockAfterChange,
      (Left + TICKS_PER_SECOND - 1) div TICKS_PER_SECOND]), CLR_WARN);
    Exit;
  end;
  { Game.TimeLeft is known from the first second of the map on; without a time limit it says nothing }
  if (Match.TimeLimit > 0) and (Match.TotalSeconds > 0) and (Match.TimeLeft < Cfg.MapVoteMinTimeLeft) then
  begin
    Say(Slot, Format('Only %d s of the map are left: a map vote needs %d s.', [Max(0, Match.TimeLeft),
      Cfg.MapVoteMinTimeLeft]), CLR_WARN);
    Exit;
  end;
  Left := MV.KickVoteUntil - GameTick;
  if Left > 0 then
  begin
    Say(Slot, Format('A kick vote is running: try again in %d s.', [(Left + TICKS_PER_SECOND - 1) div
      TICKS_PER_SECOND]), CLR_WARN);
    Exit;
  end;
  Key := MvStarterKey(Slot);
  Left := MvCooldownLeft(Key);
  if Left > 0 then
  begin
    Say(Slot, Format('Wait %d s before you start another map vote.', [(Left + TICKS_PER_SECOND - 1) div
      TICKS_PER_SECOND]), CLR_WARN);
    Exit;
  end;
  MvCount(Yes, Voters);
  { a spectator who starts the vote is one of its voters (CountSpectators = 0) }
  Spec := '';
  if not MvEligible(Slot) then
  begin
    Inc(Voters);
    Spec := ': the players on the teams and you';
  end;
  if Voters < Cfg.MapVoteMinPlayers then
  begin
    if Spec <> '' then
      Say(Slot, Format('A map vote needs %d players (%d now%s).', [Cfg.MapVoteMinPlayers, Voters, Spec]), CLR_WARN)
    else if Cfg.MapVoteCountSpectators then
      Say(Slot, Format('A map vote needs %d players (%d now).', [Cfg.MapVoteMinPlayers, Voters]), CLR_WARN)
    else
      Say(Slot, Format('A map vote needs %d players on the teams (%d now).', [Cfg.MapVoteMinPlayers, Voters]),
        CLR_WARN);
    Exit;
  end;
  MvStart(Slot, Target, Key);
  Result := MVR_STARTED;
end;

function TZSEngine.MapVoteCancel: Boolean;
begin
  Result := MV.Active;
  if Result then
    MvFinish('cancelled by an admin', Format('An admin cancelled the vote for %s.', [MV.Target]), CLR_WARN);
end;

{ Soldat's vote of the clients: the vote menu and the server's /votemap asked for a map of the maps
  list (kind 1, Soldat's own vote was cancelled), F12 or /votemap <map> voted for the vote that
  shows (kind 3) }
procedure TZSEngine.MapVoteSoldat(Slot, Kind: LongInt; const Map: AnsiString);
var
  Name: AnsiString;
  Idx: LongInt;
begin
  if not SlotValid(Slot) or not Live[Slot].Human then
    Exit;
  Name := Trim(Map);
  if Kind = 3 then
  begin
    if MV.Active and SameText(Name, MV.Target) then
      MapVoteYes(Slot)
    else
      MvSayNoVote(Slot);
    Exit;
  end;
  Idx := FindInList(MV.List, MV.ListOrder, Name);
  if Idx >= 0 then
    Name := MV.List[Idx];
  if Name <> '' then
    MapVoteRequest(Slot, Name);
end;

{ once a second (EvTick): the time of the vote, players who left, a change that did not come }
procedure TZSEngine.MapVoteSecond;
var
  Yes, Voters: LongInt;
begin
  if MV.Active then
  begin
    MvCount(Yes, Voters);
    if not Cfg.MapVoteEnabled then
      MvFinish('cancelled', Format('The map vote was switched off: the vote for %s is over.', [MV.Target]), CLR_WARN)
    else if Voters = 0 then
      MvFinish('ended', Format('The vote for %s ended: nobody is left to vote.', [MV.Target]), CLR_WARN)
    else if MvPasses(Yes, Voters) then
      MvPass(Format('%s won the vote (%d/%d).', [MV.Target, Yes, Voters]))
    else if GameTick - MV.StartTick >= Cfg.MapVoteSeconds * TICKS_PER_SECOND then
      MvFinish('failed', Format('The vote for %s failed (%s).', [MV.Target, MvCountText(Yes, Voters)]), CLR_BAD);
  end;
  if (MV.ChangeTarget <> '') and (GameTick > MV.ChangeDue) then
  begin
    Broadcast(Format('The server could not change the map to %s.', [MV.ChangeTarget]), CLR_BAD);
    NotifyAdmins(Format('[ZitroStats] map vote: the map did not change to %s.', [MV.ChangeTarget]), CLR_WARN);
    NotifyAdmins(Format('[ZitroStats] Is its file there (/zs_maps)? On Linux the server looks for exactly "%s.pms".',
      [MV.ChangeTarget]), CLR_WARN);
    MV.ChangeTarget := '';
  end;
end;

{ the server announced a map change: whatever vote runs is over, and no new one starts before the
  new map (or before the change is given up) }
procedure TZSEngine.MapVoteOnMapBefore;
begin
  MV.ChangingUntil := GameTick + MV_CHANGING_TICKS;
  MV.ChangeTarget := '';
  if MV.Active then
    MvFinish('cancelled', Format('The map is changing: the vote for %s is over.', [MV.Target]), CLR_WARN);
end;

procedure TZSEngine.MapVoteOnMapAfter(const NewMap: AnsiString);
begin
  MV.ChangingUntil := 0;
  MV.ChangeTarget := '';
  { a script that starts sends the map it finds, the one already played: no change }
  if (MV.CurMap <> '') and not SameText(MV.CurMap, NewMap) then
    MV.PrevMap := MV.CurMap;
  MV.CurMap := NewMap;
  MV.MapStartTick := GameTick;
end;
