{ zs_commands: the map vote - !v (!vote), !nextmap, !lastmap (!votelast, !votelastmap), !randommap,
  !map, !votemap, /votemap, !maps, !allmaps, !searchmap and the admins' /zs_mapvote and /zs_maps.
  The vote runs in the engine (zs_engine_mapvote.inc). A command [MapVote] switched off gets no
  answer, so another script may answer it; /map and /nextmap stay the server's admin commands. }

const
  MAPVOTE_COMMANDS = ' v vote nextmap lastmap votelast votelastmap randommap map votemap maps allmaps ' +
    'searchmap zs_mapvote zs_maps ';
  { 5 columns of 20 like !zitro; a longer name takes two of them (CmdGrid) }
  MAPS_COLS = 5;
  MAPS_PER_PAGE = 60;
  { the names of a problem list of /zs_maps }
  MAPS_PROBLEMS_SHOWN = 40;

{ "1 map", "2 maps" }
function MapCount(N: LongInt): AnsiString;
begin
  if N = 1 then
    Result := '1 map'
  else
    Result := IntToStr(N) + ' maps';
end;

function IsMapVoteCommand(const Cmd: AnsiString): Boolean;
begin
  Result := (Cmd <> '') and (Pos(' ' + Cmd + ' ', MAPVOTE_COMMANDS) > 0);
end;

{ the [MapVote] switch of a command; /votemap (also F12 and the vote menu) has one of its own }
function MapVoteSwitchOf(const Cmd: AnsiString; Source: LongInt): LongInt;
begin
  if (Cmd = 'v') or (Cmd = 'vote') then
    Result := MVC_VOTE
  else if Cmd = 'nextmap' then
    Result := MVC_NEXTMAP
  else if (Cmd = 'lastmap') or (Cmd = 'votelast') or (Cmd = 'votelastmap') then
    Result := MVC_LASTMAP
  else if Cmd = 'randommap' then
    Result := MVC_RANDOMMAP
  else if Cmd = 'map' then
    Result := MVC_MAP
  else if Cmd = 'votemap' then
  begin
    if Source = SRC_CHAT then
      Result := MVC_VOTEMAP
    else
      Result := MVC_SLASHVOTEMAP;
  end
  else if Cmd = 'maps' then
    Result := MVC_MAPS
  else if Cmd = 'allmaps' then
    Result := MVC_ALLMAPS
  else if Cmd = 'searchmap' then
    Result := MVC_SEARCHMAP
  else
    Result := 0;
end;

function MvOn(E: TZSEngine; Bit: LongInt): Boolean;
begin
  Result := E.Cfg.MapVoteEnabled and (Bit <> 0) and (E.Cfg.MapVoteCommands and Bit <> 0);
end;

function MvKeys(E: TZSEngine): AnsiString;
begin
  if MvOn(E, MVC_VOTE) then
    Result := '!v or F12'
  else
    Result := 'F12';
end;

{ !zitro: the commands of the map vote this server answers }
function MapVoteHelpItems(E: TZSEngine): TStringArray;
var
  Items: TStringArray;
  n: LongInt;

  procedure Add(Bit: LongInt; const S: AnsiString);
  begin
    if not MvOn(E, Bit) then
      Exit;
    SetLength(Items, n + 1);
    Items[n] := S;
    Inc(n);
  end;

begin
  Items := nil;
  n := 0;
  Add(MVC_VOTE, '!v');
  Add(MVC_NEXTMAP, '!nextmap');
  Add(MVC_LASTMAP, '!lastmap');
  Add(MVC_RANDOMMAP, '!randommap');
  Add(MVC_MAP, '!map [map]');
  Add(MVC_VOTEMAP, '!votemap map*');
  Add(MVC_SLASHVOTEMAP, '/votemap map*');
  Add(MVC_MAPS, '!maps [pg|map]');
  Add(MVC_ALLMAPS, '!allmaps [pg|map]');
  Add(MVC_SEARCHMAP, '!searchmap t* [pg]');
  Result := Items;
end;

{ !zitro: the line of the legend about the map vote }
function MapVoteLegend(E: TZSEngine): AnsiString;
begin
  Result := MvKeys(E) + ' = yes to the running map vote';
  if MvOn(E, MVC_MAP) then
    Result := Result + '  !map alone = the current, next and last map';
end;

{ !map alone: the map being played, the next one of the list and the one before, and the vote }
procedure CmdMapNow(E: TZSEngine; Slot: LongInt);
var
  Line, Next, Last: AnsiString;
  Yes, Voters, Left: LongInt;
begin
  Line := E.MapVoteCurrentMap;
  if Line = '' then
    Line := '-';
  Line := 'Now: ' + Line;
  if (E.Match.TimeLimit > 0) and (E.Match.TotalSeconds > 0) then
  begin
    Left := Max(0, E.Match.TimeLeft);
    Line := Line + Format(' (%d:%.2d left)', [Left div 60, Left mod 60]);
  end;
  Next := E.MapVoteNextMap;
  if Next = '' then
    Next := '-';
  Last := E.MapVoteLastMap;
  if Last = '' then
    Last := '-';
  Next := 'Next: ' + Next + '  Last: ' + Last;
  { long names: two lines rather than one wider than the tables }
  if Length(Line) + 2 + Length(Next) <= LINE_W then
    Out(E, Slot, Line + '  ' + Next, CLR_HINT)
  else
  begin
    Out(E, Slot, Line, CLR_HINT);
    Out(E, Slot, Next, CLR_HINT);
  end;
  if E.MV.Active then
  begin
    Yes := E.MapVoteYesCount(Voters);
    Out(E, Slot, Format('Vote: %s, %d s left, %d/%d (%d%% needed) - %s to vote', [E.MV.Target, E.MapVoteSecondsLeft,
      Yes, Voters, E.Cfg.MapVotePercent, MvKeys(E)]), CLR_GOOD);
  end;
end;

{ the text of a map asked for: without the spaces around it and a ".pms" at the end }
function MapQuery(const Text: AnsiString): AnsiString;
begin
  Result := Trim(Text);
  if SameText(ExtractFileExt(Result), '.pms') then
    Result := Trim(Copy(Result, 1, Length(Result) - 4));
end;

{ the index in Names of the map a text asks for, picked as the vote picks it (the whole name, its
  beginning, the beginning of a word, any part; the shorter name first, then the order of Names),
  -1 = none. When nothing matches as typed, a space stands for the "_" of a name. }
function FindMapIn(const Names: TStringArray; const T: AnsiString): LongInt;
var
  S: TMapSearch;
begin
  S := SearchNames(Names, LowerCase(T), 0);
  if (S.Best < 0) and (Pos(' ', T) > 0) then
    S := SearchNames(Names, LowerCase(StringReplace(T, ' ', '_', [rfReplaceAll])), 0);
  Result := S.Best;
end;

{ the parts of a legend two spaces apart, as many to a line as LINE_W takes; an empty part is left
  out }
procedure OutParts(E: TZSEngine; Slot: LongInt; const Parts: array of AnsiString; Color: LongInt);
var
  k: LongInt;
  Line: AnsiString;
begin
  Line := '';
  for k := 0 to High(Parts) do
    if Parts[k] <> '' then
    begin
      if (Line <> '') and (Length(Line) + 2 + Length(Parts[k]) > LINE_W) then
      begin
        Out(E, Slot, Line, Color);
        Line := '';
      end;
      if Line <> '' then
        Line := Line + '  ';
      Line := Line + Parts[k];
    end;
  if Line <> '' then
    Out(E, Slot, Line, Color);
end;

{ !maps [page|map]: the maps list of the server, the map being played in brackets; with a map (its
  name or a part of it) the page that has it, the map marked > <. Below it the next and the last map
  and the command that starts a vote. }
procedure ListMapsList(E: TZSEngine; Slot, Page: LongInt; const Query: AnsiString);
var
  Names, Items: TStringArray;
  n, k, Pages, First, Last, Asked: LongInt;
  T, Cur, Name, Next, Prev, Hint: AnsiString;
  CurShown: Boolean;
begin
  if not E.MV.ListKnown then
  begin
    Out(E, Slot, 'The maps list is not known yet, try again in a moment.', CLR_WARN);
    Exit;
  end;
  { an empty line of the list is no map }
  Names := nil;
  Items := nil;
  SetLength(Names, Length(E.MV.List));
  n := 0;
  for k := 0 to High(E.MV.List) do
    if E.MV.List[k] <> '' then
    begin
      Names[n] := E.MV.List[k];
      Inc(n);
    end;
  SetLength(Names, n);
  if n = 0 then
  begin
    Out(E, Slot, 'The maps list of the server is empty.', CLR_WARN);
    Exit;
  end;
  Asked := -1;
  T := MapQuery(Query);
  if T <> '' then
  begin
    Asked := FindMapIn(Names, T);
    if Asked < 0 then
    begin
      Hint := '.';
      if MvOn(E, MVC_SEARCHMAP) then
        Hint := ' - try !searchmap.'
      else if MvOn(E, MVC_ALLMAPS) then
        Hint := ' - try !allmaps.';
      Out(E, Slot, Format('No map of the maps list matches "%s"%s', [Copy(T, 1, 30), Hint]), CLR_WARN);
      Exit;
    end;
    Page := Asked div MAPS_PER_PAGE + 1;
  end;
  Pages := PageCount(n, MAPS_PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * MAPS_PER_PAGE;
  Last := Min(n, First + MAPS_PER_PAGE) - 1;
  Cur := E.MapVoteCurrentMap;
  CurShown := False;
  SetLength(Items, Last - First + 1);
  for k := First to Last do
  begin
    Name := Names[k];
    if SameText(Name, Cur) then
    begin
      Name := '[' + Name + ']';
      CurShown := True;
    end;
    if k = Asked then
      Name := '>' + Name + '<';
    Items[k - First] := Name;
  end;
  Header(E, Slot, Format('Maps list: %s [Page %d/%d]', [MapCount(n), Page, Pages]), LINE_W);
  CmdGrid(E, Slot, Items, MAPS_COLS, LINE_W div MAPS_COLS, WHITE);
  Next := E.MapVoteNextMap;
  Prev := E.MapVoteLastMap;
  Hint := '';
  if MvOn(E, MVC_MAP) then
    Hint := '!map <part> starts a vote'
  else if MvOn(E, MVC_VOTEMAP) then
    Hint := '!votemap <part> starts a vote';
  OutParts(E, Slot, [IfText(CurShown, '[ ] = the map being played'), IfText(Asked >= 0, '> < = the map you asked for'),
    IfText(Next <> '', 'Next: ' + Next), IfText(Prev <> '', 'Last: ' + Prev), Hint], CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'maps');
  Remember(E, Slot, QK_MAPS, '', Page, Pages);
end;

{ !allmaps [page|map]: every map of the maps folder (with FilterByGameStyle those of the style
  played), * = not in the maps list; with a map (its name or a part of it) the page that has it, the
  map marked > < }
procedure ListAllMaps(E: TZSEngine; Slot: LongInt; const Query: AnsiString; Page: LongInt);
var
  Names, Items: TStringArray;
  n, k, Pages, First, Last, Marked, Asked: LongInt;
  T, Cur, Title, Name: AnsiString;
  CurShown: Boolean;
begin
  if not E.MV.FilesKnown then
  begin
    Out(E, Slot, 'The maps folder has not been read yet, try again in a moment.', CLR_WARN);
    Exit;
  end;
  if not E.MV.Files.Found or (E.MV.Files.Error <> '') then
  begin
    Out(E, Slot, 'The maps folder of the server could not be read.', CLR_WARN);
    Exit;
  end;
  { the maps shown, in the order of the folder (by name) }
  Names := nil;
  Items := nil;
  SetLength(Names, Length(E.MV.Files.Maps));
  n := 0;
  for k := 0 to High(E.MV.Files.Maps) do
    if not E.Cfg.MapVoteFilterByStyle or MapFitsStyle(E.MV.Files.Maps[k].Name, E.Match.GameStyle) then
    begin
      Names[n] := E.MV.Files.Maps[k].Name;
      Inc(n);
    end;
  SetLength(Names, n);
  if n = 0 then
  begin
    if E.Cfg.MapVoteFilterByStyle then
      Out(E, Slot, 'The maps folder has no maps of this game mode.', CLR_WARN)
    else
      Out(E, Slot, 'The maps folder has no maps.', CLR_WARN);
    Exit;
  end;
  Asked := -1;
  T := MapQuery(Query);
  if T <> '' then
  begin
    Asked := FindMapIn(Names, T);
    if Asked < 0 then
    begin
      if E.Cfg.MapVoteFilterByStyle then
        Out(E, Slot, Format('No map of this game mode matches "%s".', [Copy(T, 1, 30)]), CLR_WARN)
      else
        Out(E, Slot, Format('No map of the server matches "%s".', [Copy(T, 1, 30)]), CLR_WARN);
      Exit;
    end;
    Page := Asked div MAPS_PER_PAGE + 1;
  end;
  Pages := PageCount(n, MAPS_PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * MAPS_PER_PAGE;
  Last := Min(n, First + MAPS_PER_PAGE) - 1;
  Cur := E.MapVoteCurrentMap;
  Marked := 0;
  CurShown := False;
  SetLength(Items, Last - First + 1);
  for k := First to Last do
  begin
    Name := Names[k];
    if E.MV.ListKnown and (FindInList(E.MV.List, E.MV.ListOrder, Name) < 0) then
    begin
      Name := Name + '*';
      Inc(Marked);
    end;
    if SameText(Names[k], Cur) then
    begin
      Name := '[' + Name + ']';
      CurShown := True;
    end;
    if k = Asked then
      Name := '>' + Name + '<';
    Items[k - First] := Name;
  end;
  if E.Cfg.MapVoteFilterByStyle then
    Title := Format('Maps of this game mode: %d [Page %d/%d]', [n, Page, Pages])
  else
    Title := Format('All maps of the server: %d [Page %d/%d]', [n, Page, Pages]);
  Header(E, Slot, Title, LINE_W);
  CmdGrid(E, Slot, Items, MAPS_COLS, LINE_W div MAPS_COLS, WHITE);
  Title := '';
  if Marked > 0 then
  begin
    if E.Cfg.MapVoteAllowAnyMap then
      Title := '* = not in the maps list, can be voted too'
    else
      Title := '* = not in the maps list, cannot be voted';
  end;
  OutParts(E, Slot, [Title, IfText(CurShown, '[ ] = the map being played'),
    IfText(Asked >= 0, '> < = the map you asked for')], CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'maps');
  Remember(E, Slot, QK_ALLMAPS, '', Page, Pages);
end;

{ !searchmap <part> [page]: the maps of the maps list and of the maps folder whose name holds the
  text, in the order of the search of the vote (MapVoteFind): the maps list first, then the maps
  only the folder has, and in each the whole name, its beginning, the beginning of a word, any
  part, the shorter name first, then the order of the list or the folder - so the first one is the
  map !map <part> would pick. A space may stand for the "_" of a name, as in the vote. }
procedure ListSearchMaps(E: TZSEngine; Slot: LongInt; const Query: AnsiString; Page: LongInt);
const
  { the maps of the folder come after every map of the list }
  FOLDER_RANK = 1000000;
var
  Names, Items: TStringArray;
  Found, Keys: TIntArray;
  n, nList, m, k, j, R, Key, Pass, Pages, First, Last, Marked: LongInt;
  T, Low, Shown, Cur, Name, Legend: AnsiString;
  InFolder, CurShown: Boolean;
begin
  T := Trim(Query);
  if SameText(ExtractFileExt(T), '.pms') then
    T := Trim(Copy(T, 1, Length(T) - 4));
  if T = '' then
  begin
    Out(E, Slot, 'Usage: !searchmap <part of a map name> [page]', CLR_WARN);
    Exit;
  end;
  { a long text would push the title out of the frame }
  Shown := Copy(T, 1, 30);
  InFolder := E.MV.FilesKnown and E.MV.Files.Found and (E.MV.Files.Error = '');
  if not E.MV.ListKnown and not InFolder then
  begin
    Out(E, Slot, 'The maps of the server are not known yet, try again in a moment.', CLR_WARN);
    Exit;
  end;
  { every map of the list once (an empty line is no map), then the maps of the folder the list
    does not have }
  Names := nil;
  SetLength(Names, Length(E.MV.List) + Length(E.MV.Files.Maps));
  n := 0;
  if E.MV.ListKnown then
    for k := 0 to High(E.MV.List) do
      if (E.MV.List[k] <> '') and (FindInList(E.MV.List, E.MV.ListOrder, E.MV.List[k]) = k) then
      begin
        Names[n] := E.MV.List[k];
        Inc(n);
      end;
  nList := n;
  if InFolder then
    for k := 0 to High(E.MV.Files.Maps) do
      if FindInList(E.MV.List, E.MV.ListOrder, E.MV.Files.Maps[k].Name) < 0 then
      begin
        Names[n] := E.MV.Files.Maps[k].Name;
        Inc(n);
      end;
  Found := nil;
  Keys := nil;
  SetLength(Found, n);
  SetLength(Keys, n);
  m := 0;
  for Pass := 1 to 2 do
  begin
    if Pass = 1 then
      Low := LowerCase(T)
    else if Pos(' ', T) > 0 then
      Low := LowerCase(StringReplace(T, ' ', '_', [rfReplaceAll]))
    else
      Break;
    for k := 0 to n - 1 do
    begin
      R := MapMatchRank(Names[k], Low);
      if R < 0 then
        Continue;
      Key := R;
      if k >= nList then
        Inc(Key, FOLDER_RANK);
      { the closest first; equal ones keep the order of the list or the folder }
      j := m;
      while (j > 0) and (Keys[j - 1] > Key) do
      begin
        Found[j] := Found[j - 1];
        Keys[j] := Keys[j - 1];
        Dec(j);
      end;
      Found[j] := k;
      Keys[j] := Key;
      Inc(m);
    end;
    if m > 0 then
      Break;
  end;
  if m = 0 then
  begin
    Out(E, Slot, Format('No map of the server matches "%s".', [Shown]), CLR_WARN);
    Exit;
  end;
  Pages := PageCount(m, MAPS_PER_PAGE);
  Page := EnsureRange(Page, 1, Pages);
  First := (Page - 1) * MAPS_PER_PAGE;
  Last := Min(m, First + MAPS_PER_PAGE) - 1;
  Cur := E.MapVoteCurrentMap;
  Marked := 0;
  CurShown := False;
  Items := nil;
  SetLength(Items, Last - First + 1);
  for j := First to Last do
  begin
    Name := Names[Found[j]];
    { a map only the folder has; without a maps list nobody can tell }
    if (Found[j] >= nList) and E.MV.ListKnown then
    begin
      Name := Name + '*';
      Inc(Marked);
    end;
    if SameText(Names[Found[j]], Cur) then
    begin
      Name := '[' + Name + ']';
      CurShown := True;
    end;
    Items[j - First] := Name;
  end;
  Header(E, Slot, Format('Map search "%s": %s [Page %d/%d]', [Shown, MapCount(m), Page, Pages]), LINE_W);
  CmdGrid(E, Slot, Items, MAPS_COLS, LINE_W div MAPS_COLS, WHITE);
  Legend := '';
  if Marked > 0 then
  begin
    if E.Cfg.MapVoteAllowAnyMap then
      Legend := '* = not in the maps list, can be voted too  '
    else
      Legend := '* = not in the maps list, cannot be voted  ';
  end;
  if CurShown then
    Legend := Legend + '[ ] = the map being played';
  if Trim(Legend) <> '' then
    Out(E, Slot, Trim(Legend), CLR_HINT);
  PageHint(E, Slot, Page, Pages, 'maps');
  Remember(E, Slot, QK_SEARCHMAP, T, Page, Pages);
end;

{ /zs_mapvote [cancel]: the settings and the state of the map vote }
procedure CmdMapVoteState(E: TZSEngine; Slot: LongInt; const Arg: AnsiString);
var
  Yes, Voters: LongInt;
  S, Who: AnsiString;
begin
  if SameText(Arg, 'cancel') then
  begin
    { everybody in the game hears it; the console only this line }
    if not E.MapVoteCancel then
      Out(E, Slot, 'No map vote is running.', CLR_WARN)
    else if Slot <= 0 then
      Out(E, Slot, '[Map vote] The vote was cancelled.', CLR_GOOD);
    Exit;
  end;
  if Arg <> '' then
  begin
    Out(E, Slot, 'Usage: /zs_mapvote [cancel]', CLR_WARN);
    Exit;
  end;
  if not E.Cfg.MapVoteEnabled then
    Out(E, Slot, '[Map vote] off ([MapVote] Enabled = 0): the server''s own map vote works as usual.', CLR_WARN)
  else
  begin
    { CountSpectators = 0: a spectator who starts the vote or votes for it counts for that vote }
    if E.Cfg.MapVoteCountSpectators then
      Who := 'the players'
    else
      Who := 'the players on the teams and voting spectators';
    Out(E, Slot, Format('[Map vote] on: passes with %d%% of %s, fails after %d s', [E.Cfg.MapVotePercent, Who,
      E.Cfg.MapVoteSeconds]), CLR_HINT);
    Out(E, Slot, Format('[Map vote] none in the first %d s of a map or with less than %d s left, a starter waits %d s',
      [E.Cfg.MapVoteBlockAfterChange, E.Cfg.MapVoteMinTimeLeft, E.Cfg.MapVoteStarterCooldown]), CLR_HINT);
    Out(E, Slot, Format('[Map vote] at least %d player(s), maps outside the list: %s, vote percent put back: %d',
      [E.Cfg.MapVoteMinPlayers, BoolToStr(E.Cfg.MapVoteAllowAnyMap, 'yes', 'no'), E.Cfg.MapVoteRestorePercent]),
      CLR_HINT);
  end;
  if E.MV.Active then
  begin
    Yes := E.MapVoteYesCount(Voters);
    S := 'just now';
    if E.GameTick - E.MV.StartTick >= TICKS_PER_SECOND then
      S := Format('%d s ago', [(E.GameTick - E.MV.StartTick) div TICKS_PER_SECOND]);
    Out(E, Slot, Format('[Map vote] running: %s, %d s left, %d/%d', [E.MV.Target, E.MapVoteSecondsLeft, Yes, Voters]),
      CLR_GOOD);
    Out(E, Slot, Format('[Map vote] asked by %s %s - /zs_mapvote cancel ends it.', [E.MV.StarterName, S]), CLR_HINT);
  end
  else if E.MV.LastTarget <> '' then
    Out(E, Slot, Format('[Map vote] none running; the last one: %s, %s %s ago.', [E.MV.LastTarget, E.MV.LastResult,
      FormatDurationShort((E.GameTick - E.MV.LastEndTick) div TICKS_PER_SECOND)]), CLR_HINT)
  else
    Out(E, Slot, '[Map vote] no vote since the library started.', CLR_HINT);
  if E.MV.ListKnown then
  begin
    S := E.MapVoteNextMap;
    if S = '' then
      S := '-';
    S := Format('%s, next %s', [MapCount(Length(E.MV.List)), S]);
  end
  else
    S := 'not known yet';
  Out(E, Slot, '[Map vote] maps list: ' + S, CLR_HINT);
  if E.MV.FilesKnown and E.MV.Files.Found then
    Out(E, Slot, Format('[Map vote] maps folder: %s (/zs_maps)', [MapCount(Length(E.MV.Files.Maps))]), CLR_HINT)
  else
    Out(E, Slot, '[Map vote] maps folder: not read (/zs_maps)', CLR_HINT);
end;

{ /zs_maps [rescan]: the maps folder, the files Linux may not load, the maps of the list without a
  file }
procedure CmdMapsState(E: TZSEngine; Slot: LongInt; const Arg: AnsiString);
var
  Odd, NoFile, WrongCase: TStringArray;
  k, i, nOdd, nNo, nWrong: LongInt;
  S, Name: AnsiString;

  procedure Note(var List: TStringArray; var Count: LongInt; const Item: AnsiString);
  begin
    if Count < MAPS_PROBLEMS_SHOWN then
    begin
      SetLength(List, Count + 1);
      List[Count] := Item;
    end;
    Inc(Count);
  end;

  procedure Show(const List: TStringArray; Count: LongInt);
  begin
    WrapList(E, Slot, '  ', List, CLR_WARN);
    if Count > Length(List) then
      Out(E, Slot, Format('  ... and %d more', [Count - Length(List)]), CLR_WARN);
  end;

begin
  if SameText(Arg, 'rescan') then
  begin
    E.MapVoteRescan(Slot);
    Out(E, Slot, '[Maps] Reading the maps folder; you hear when it is done.', CLR_HINT);
    Exit;
  end;
  if Arg <> '' then
  begin
    Out(E, Slot, 'Usage: /zs_maps [rescan]', CLR_WARN);
    Exit;
  end;
  Out(E, Slot, '[Maps] folder: ' + E.MapVoteFolder, CLR_HINT);
  if not E.MV.FilesKnown then
    Out(E, Slot, '[Maps] The folder has not been read yet (/zs_maps rescan reads it now).', CLR_WARN)
  else if E.MV.Files.Error <> '' then
    Out(E, Slot, '[Maps] The folder could not be read: ' + E.MV.Files.Error, CLR_BAD)
  else if not E.MV.Files.Found then
    Out(E, Slot, '[Maps] The folder was not found: set [MapVote] MapsFolder in settings.ini, then /zs_reload.', CLR_BAD)
  else
  begin
    S := Format('[Maps] %s, read at %s in %d ms', [MapCount(Length(E.MV.Files.Maps)), FormatDateTime('hh:nn:ss',
      E.MV.Files.ScanTime), E.MV.Files.ScanMs]);
    if not E.Cfg.MapVoteEnabled then
      S := S + ', read again on /zs_maps rescan'
    else if E.Cfg.MapVoteRescanMinutes > 0 then
      S := S + Format(', read again every %d min', [E.Cfg.MapVoteRescanMinutes])
    else
      S := S + ', read again on /zs_maps rescan';
    Out(E, Slot, S, CLR_HINT);
    Odd := nil;
    nOdd := 0;
    for k := 0 to High(E.MV.Files.Maps) do
      if E.MV.Files.Maps[k].OddExt then
        Note(Odd, nOdd, E.MV.Files.Maps[k].Name + E.MV.Files.Maps[k].Ext);
    if nOdd > 0 then
    begin
      Out(E, Slot, Format('[Maps] %d file(s) not ending in ".pms" - Linux looks for ".pms" and may not load them:',
        [nOdd]), CLR_WARN);
      Show(Odd, nOdd);
    end;
  end;
  if not E.MV.ListKnown then
  begin
    Out(E, Slot, '[Maps] The maps list is not known yet.', CLR_WARN);
    Exit;
  end;
  Out(E, Slot, Format('[Maps] maps list: %s', [MapCount(Length(E.MV.List))]), CLR_HINT);
  if not E.MV.FilesKnown or not E.MV.Files.Found or (E.MV.Files.Error <> '') then
    Exit;
  { the list against the files; a map twice in the list is looked at once }
  NoFile := nil;
  WrongCase := nil;
  nNo := 0;
  nWrong := 0;
  for k := 0 to High(E.MV.List) do
  begin
    Name := E.MV.List[k];
    if (Name = '') or (FindInList(E.MV.List, E.MV.ListOrder, Name) <> k) then
      Continue;
    i := FindCatalog(E.MV.Files.Maps, Name);
    if i < 0 then
      Note(NoFile, nNo, Name)
    else if E.MV.Files.Maps[i].Name <> Name then
      Note(WrongCase, nWrong, Name + ' (file ' + E.MV.Files.Maps[i].Name + E.MV.Files.Maps[i].Ext + ')');
  end;
  if nNo > 0 then
  begin
    Out(E, Slot, Format('[Maps] %d map(s) of the list have no file in the folder:', [nNo]), CLR_WARN);
    Show(NoFile, nNo);
  end;
  if nWrong > 0 then
  begin
    Out(E, Slot, Format('[Maps] %d map(s) of the list differ from their file in case (Linux needs the same case):',
      [nWrong]), CLR_WARN);
    Show(WrongCase, nWrong);
  end;
  if nNo + nWrong = 0 then
    Out(E, Slot, '[Maps] Every map of the list has its file.', CLR_GOOD);
end;

{ the commands of the map vote; one [MapVote] switched off gets no answer }
procedure CmdMapVote(E: TZSEngine; Slot: LongInt; const Cmd, Rest: AnsiString; Source: LongInt; Admin: Boolean);
var
  Target, Why, Others: AnsiString;
  Words: TStringArray;
begin
  if (Cmd = 'zs_mapvote') or (Cmd = 'zs_maps') then
  begin
    if not Admin then
      Out(E, Slot, 'This command is for admins.', CLR_BAD)
    else if Cmd = 'zs_mapvote' then
      CmdMapVoteState(E, Slot, Rest)
    else
      CmdMapsState(E, Slot, Rest);
    Exit;
  end;
  if not MvOn(E, MapVoteSwitchOf(Cmd, Source)) then
    Exit;
  { !maps and !allmaps: a number is a page, anything else a map - the page that has it }
  if Cmd = 'maps' then
  begin
    if (Rest = '') or (StrToIntDef(Rest, -1) > 0) then
      ListMapsList(E, Slot, Max(1, StrToIntDef(Rest, 1)), '')
    else
      ListMapsList(E, Slot, 1, Rest);
  end
  else if Cmd = 'allmaps' then
  begin
    if (Rest = '') or (StrToIntDef(Rest, -1) > 0) then
      ListAllMaps(E, Slot, '', Max(1, StrToIntDef(Rest, 1)))
    else
      ListAllMaps(E, Slot, Rest, 1);
  end
  else if Cmd = 'searchmap' then
  begin
    { a number after the text is the page: !searchmap ctf 2 }
    Words := SplitWords(Rest);
    if (Length(Words) > 1) and AllDigits(Words[High(Words)]) then
      ListSearchMaps(E, Slot, Copy(Rest, 1, Length(Rest) - Length(Words[High(Words)])),
        Max(1, StrToIntDef(Words[High(Words)], 1)))
    else
      ListSearchMaps(E, Slot, Rest, 1);
  end
  else if (Cmd = 'map') and (Rest = '') then
    CmdMapNow(E, Slot)
  else if (Slot < 1) or (Slot > MAX_PLAYERS) then
    Out(E, Slot, 'The map vote is for players on the server.', CLR_WARN)
  else if (Cmd = 'v') or (Cmd = 'vote') then
    E.MapVoteYes(Slot)
  else if Cmd = 'nextmap' then
  begin
    Target := E.MapVoteNextMap;
    if not E.MV.ListKnown then
      Out(E, Slot, 'The maps list is not known yet, try again in a moment.', CLR_WARN)
    else if Target = '' then
      Out(E, Slot, 'The maps list of the server is empty.', CLR_WARN)
    else
      E.MapVoteRequest(Slot, Target);
  end
  else if (Cmd = 'lastmap') or (Cmd = 'votelast') or (Cmd = 'votelastmap') then
  begin
    Target := E.MapVoteLastMap;
    if Target = '' then
      Out(E, Slot, 'No map was played before this one yet.', CLR_WARN)
    else
      E.MapVoteRequest(Slot, Target);
  end
  else if Cmd = 'randommap' then
  begin
    Target := E.MapVoteRandomMap(Why);
    if Target = '' then
      Out(E, Slot, Why, CLR_WARN)
    else
      E.MapVoteRequest(Slot, Target);
  end
  { !map <part>, !votemap <part>, /votemap <part> }
  else if Rest = '' then
  begin
    if Source = SRC_CHAT then
      Out(E, Slot, 'Usage: !' + Cmd + ' <map name or a part of it>', CLR_WARN)
    else
      Out(E, Slot, 'Usage: /' + Cmd + ' <map name or a part of it>', CLR_WARN);
  end
  else if E.MV.Active and SameText(Rest, E.MV.Target) then
    E.MapVoteYes(Slot)
  else if (Source <> SRC_CHAT) and E.MapVoteLate(Slot, Rest) then
  begin
    { F12 after the vote ended: MapVoteLate told the player }
  end
  else if E.MapVoteFind(Rest, Target, Why, Others) then
  begin
    if (E.MapVoteRequest(Slot, Target) = MVR_STARTED) and (Others <> '') then
      Out(E, Slot, Others, CLR_HINT);
  end
  else
    Out(E, Slot, Why, CLR_WARN);
end;
