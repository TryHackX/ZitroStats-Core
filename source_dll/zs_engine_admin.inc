{ zs_engine_admin.inc - commands, admin operations, HUD and the developer API (part of zs_engine) }

function FindProfileArg(DB: TStatsDB; const Arg: AnsiString): LongInt;
var
  C: TIntArray;
  k: LongInt;
begin
  Result := -1;
  if Arg = '' then
    Exit;
  if Arg[1] = '#' then
    Exit(DB.IndexOfId(StrToIntDef(Copy(Arg, 2, MaxInt), 0)));
  if StrToIntDef(Arg, 0) > 0 then
  begin
    Result := DB.IndexOfId(StrToIntDef(Arg, 0));
    if Result >= 0 then
      Exit;
  end;
  C := DB.IndexesOfName(Arg);
  for k := 0 to High(C) do
    if DB.Valid(C[k]) and ((Result < 0) or (DB.Profiles[C[k]]^.LastPlayedTime > DB.Profiles[Result]^.LastPlayedTime)) then
      Result := C[k];
end;

function AdminLabel(E: TZSEngine; Slot: LongInt): AnsiString;
begin
  if E.SlotValid(Slot) then
    Result := E.Live[Slot].Name
  else
    Result := 'console';
end;

function OpDescription(Kind: LongInt): AnsiString;
begin
  case Kind of
    OP_RESET_ALL_PLAYERS: Result := 'reset-all-players';
    OP_RESET_ALL_MAPS: Result := 'reset-all-maps';
    OP_RESET_PLAYER: Result := 'reset-player';
    OP_RESET_MAP: Result := 'reset-map';
    OP_RESET_SERVER: Result := 'reset-server';
    OP_REMOVE_OLDER: Result := 'remove-inactive';
    OP_RESTORE: Result := 'restore';
    OP_MERGE: Result := 'merge';
    OP_UNREGISTER: Result := 'unregister';
    OP_SETPASS: Result := 'set-password';
    else Result := 'operation';
  end;
end;

{ one audit.log line per admin command: who, from which address and what; passwords never }
function AdminCommandLine(E: TZSEngine; Slot, Src: LongInt; const W: TStringArray): AnsiString;
const
  SOURCES: array[0..2] of AnsiString = ('chat', 'command', 'console');
var
  Cmd, Who: AnsiString;
  k, Idx: LongInt;
begin
  Cmd := LowerCase(W[0]);
  if (Cmd <> '') and (Cmd[1] in ['/', '!']) then
    Delete(Cmd, 1, 1);
  if Src = SRC_CONSOLE then
    Who := 'console'
  else
  begin
    Who := Format('%s (IP %s', [E.Live[Slot].Name, E.Identity.Slots[Slot].IP]);
    Idx := E.Identity.ProfileIndex(Slot);
    if E.DB.Valid(Idx) then
      Who := Who + Format(', account #%d', [E.DB.Profiles[Idx]^.ID]);
    Who := Who + ')';
  end;
  Result := Format('admin command via %s by %s: /%s', [SOURCES[EnsureRange(Src, 0, 2)], Who, Cmd]);
  if IsSoldatAdminCommand(Cmd) then
    Result := Result + ' (Soldat)';
  for k := 1 to High(W) do
    if k >= AuditHiddenFrom(Cmd) then
    begin
      Result := Result + ' ***';
      Break;
    end
    else
      Result := Result + ' ' + W[k];
end;

procedure TZSEngine.EvCommand(var E: TZSEvent);
var
  S, Src, k: LongInt;
  W: TStringArray;
  Admin: Boolean;
  NowMs: Int64;
  Bare: AnsiString;
begin
  S := E.Slot;
  Src := E.I[0];
  Admin := (E.I[1] <> 0) or (Src = SRC_CONSOLE);
  W := SplitWords(E.S1);
  if Length(W) = 0 then
    Exit;
  { old spellings such as /zs-status or /zsstatus reach the same command }
  W[0] := NormalizeCommand(W[0]);
  try
    { a Soldat admin command: the server runs it, only the audit line is left to write }
    if E.I[2] <> 0 then
    begin
      if Src = SRC_CONSOLE then
        S := 0;
      if Admin and ((S = 0) or (SlotValid(S) and Live[S].Human)) then
        Audit(AdminCommandLine(Self, S, Src, W));
      { the server is about to read another weapons file: the reload times follow it }
      Bare := LowerCase(W[0]);
      if Copy(Bare, 1, 1) = '/' then
        Delete(Bare, 1, 1);
      if Admin and (Bare = 'loadwep') then
        NoteLoadWeapons(W);
      Exit;
    end;
    if Src = SRC_CONSOLE then
      S := 0
    else
    begin
      if not SlotValid(S) or not Live[S].Human then
        Exit;
      Live[S].Admin := Admin;
      NowMs := MonoMs;
      if NowMs - Extra[S].CmdWindowMs >= 1000 then
      begin
        Extra[S].CmdWindowMs := NowMs;
        Extra[S].CmdCount := 0;
      end;
      Inc(Extra[S].CmdCount);
      if Extra[S].CmdCount > Max(1, Cfg.CommandsPerSecond) then
      begin
        if Extra[S].CmdCount = Max(1, Cfg.CommandsPerSecond) + 1 then
          Say(S, 'Too many commands, slow down.', CLR_WARN);
        Exit;
      end;
    end;
    if (S > 0) and Identity.HandleCommand(S, W, Src = SRC_CHAT) then
      Exit;
    if Admin and IsAdminCommand(W[0]) then
      Audit(AdminCommandLine(Self, S, Src, W));
    if Admin and AdminCommand(S, W, Src) then
      Exit;
    ExecuteCommand(Self, S, W, Src, Admin);
  finally
    for k := 0 to High(W) do
      WipeString(W[k]);
  end;
end;

procedure TZSEngine.EvReloadConfig(var E: TZSEvent);
var
  NewCfg: TZSConfig;
  k: LongInt;
begin
  SetConfigDefaults(NewCfg);
  Warnings.Clear;
  if not LoadConfigFile(ScriptDir + 'settings.ini', NewCfg, Warnings) then
  begin
    NotifyAdmins('[ZitroStats] settings.ini could not be read, the old settings stay active.', CLR_BAD);
    Exit;
  end;
  NewCfg.ScriptDir := ScriptDir;
  Bal.RefDone := False;
  Bal.Dirty := True;
  if (ResolvePath(NewCfg.DataPath) <> ResolvePath(Cfg.DataPath)) or (NewCfg.SnapshotFile <> Cfg.SnapshotFile) or
     (NewCfg.JournalFile <> Cfg.JournalFile) then
  begin
    NotifyAdmins('[ZitroStats] data paths changed: restart the server to use them.', CLR_WARN);
    NewCfg.DataPath := Cfg.DataPath;
    NewCfg.SnapshotFile := Cfg.SnapshotFile;
    NewCfg.JournalFile := Cfg.JournalFile;
  end;
  Cfg := NewCfg;
  ApplyPalette(Cfg);
  ApplyConfig;
  SendIntegrityConfig;
  DB.RebuildRanks;
  if Service <> nil then
    Service.SetMailSettings(MailSettingsOf(Cfg));
  { the first five reach the admins in the game as well; NotifyAdmins also writes the console }
  for k := 0 to Warnings.Count - 1 do
    if k < 5 then
      NotifyAdmins('[ZitroStats] settings.ini: ' + Warnings[k], CLR_WARN)
    else
      WriteServer('[ZitroStats] settings.ini: ' + Warnings[k]);
  if Warnings.Count > 5 then
    NotifyAdmins(Format('[ZitroStats] Settings reloaded, %d lines of settings.ini were not used (the server console ' +
      'lists them all).', [Warnings.Count]), CLR_WARN)
  else if Warnings.Count > 0 then
    NotifyAdmins(Format('[ZitroStats] Settings reloaded, %d line(s) of settings.ini were not used (see above).',
      [Warnings.Count]), CLR_WARN)
  else
    NotifyAdmins('[ZitroStats] Settings reloaded.', CLR_GOOD);
end;

{ ---------------- score guard (see [Integrity] and main.pas) ---------------- }

{ what main.pas has to watch }
function TZSEngine.IntegrityFlags: LongInt;
begin
  Result := 0;
  if not Cfg.IntegrityEnabled then
    Exit;
  Result := IG_ENABLED;
  if Cfg.IntegrityFixJoinScore then
    Result := Result or IG_JOINSCORE;
  if Cfg.IntegrityVoidDoubleCaptures then
    Result := Result or IG_DOUBLECAP;
  if Cfg.IntegrityMinOpponents > 0 then
    Result := Result or IG_SOLO;
  if Cfg.IntegrityRespawnAfterMapChange then
    Result := Result or IG_RESPAWN;
  if Cfg.IntegrityProtectMapChange then
    Result := Result or IG_MAPCHANGE;
  if Cfg.IntegrityAnnounce then
    Result := Result or IG_ANNOUNCE;
end;

procedure TZSEngine.SendIntegrityConfig;
var
  A: TZSAction;
begin
  A := NewAction(ACT_INTEGRITY, 0, 0, '');
  A.P1 := IntegrityFlags;
  A.P2 := Cfg.IntegrityMinOpponents;
  EmitAction(A);
  { the settings of the map vote go to main.pas at the same moments (start, reload of the script or
    of the settings) }
  SendMapVoteConfig;
end;

{ main.pas took a point back, put players back on their feet or saved a map change }
procedure TZSEngine.EvIntegrity(var E: TZSEvent);
var
  Kind, Team, Value, S: LongInt;
  Who, Text: AnsiString;
begin
  Kind := E.I[0];
  Team := E.I[1];
  Value := E.I[2];
  S := E.Slot;
  Who := '';
  if SlotValid(S) then
    Who := Live[S].Name;
  case Kind of
    IGE_JOINSCORE:
      begin
        Text := Format('%s is back at %d: a join or a team change gave it the round', [TeamTitle(Team), Value]);
        if Who <> '' then
          Text := Text + ' (' + Who + ')';
      end;
    IGE_DOUBLECAP:
      Text := Format('capture of %s taken back: %s is back at %d (the round or the match was over)',
        [Who, TeamTitle(Team), Value]);
    IGE_SOLO:
      begin
        Text := Format('%s is back at %d: there was no opposing team', [TeamTitle(Team), Value]);
        if Who <> '' then
          Text := Text + ' (' + Who + ')';
      end;
    IGE_RESPAWN:
      Text := Format('%d player(s) were put back on their feet after the map change', [Value]);
    IGE_PAUSE:
      begin
        Text := 'pause refused while the map was changing';
        if Who <> '' then
          Text := Text + ' (' + Who + ')';
      end;
    IGE_MAPCHANGE:
      Text := 'the map change to ' + E.S1 + ' was lost (a pause) and was repeated';
    else
      Text := Format('score guard: kind %d, team %d, value %d', [Kind, Team, Value]);
  end;
  AppendLog('integrity.log', Text);
  if Kind in [IGE_JOINSCORE, IGE_DOUBLECAP, IGE_SOLO] then
  begin
    Inc(DB.Server.ScoreFixes);
    if E.I[3] <> 0 then
      Inc(DB.Server.VoidedCaptures);
    DB.TouchServer;
  end;
  if Kind = IGE_MAPCHANGE then
    WriteServer('[ZitroStats] ' + Text + '.');
end;

{ everything that changes many accounts gets a backup first; a single password does not }
function OpNeedsBackup(Kind: LongInt): Boolean;
begin
  Result := Kind <> OP_SETPASS;
end;

procedure TZSEngine.ClearPending;
begin
  { /zs_setpass keeps the new password here until it is confirmed }
  WipeString(Pending.Arg);
  Pending.Kind := OP_NONE;
  Pending.WaitingBackup := False;
end;

procedure TZSEngine.AskConfirmation(Slot, Kind: LongInt; const Arg: AnsiString; IntArg, IntArg2: LongInt; const What: AnsiString);
begin
  { after a damaged database only the restore is allowed, it is the way back to saving }
  if (FReadOnly or (Writer = nil)) and
     not ((Kind = OP_RESTORE) and FLoadFailed and (IO <> nil) and (IO.LockError = '')) then
  begin
    Say(Slot, 'The database is read-only (see the server console), this is disabled.', CLR_BAD);
    Exit;
  end;
  if Trim(Cfg.AdminConfirmPassword) = '' then
  begin
    Say(Slot, 'Set ConfirmPassword in the [Admin] section of settings.ini to allow this operation.', CLR_BAD);
    Exit;
  end;
  if Now < FYesLockUntil then
  begin
    Say(Slot, Format('/yes is locked for %d more min (a wrong password, or the password typed in chat).',
      [Trunc((FYesLockUntil - Now) * 1440) + 1]), CLR_BAD);
    Exit;
  end;
  if Pending.WaitingBackup then
  begin
    Say(Slot, 'Another operation is running, wait until it finishes.', CLR_WARN);
    Exit;
  end;
  Pending.Kind := Kind;
  Pending.AdminSlot := Slot;
  if Slot > 0 then
    Pending.AdminName := Live[Slot].Name
  else
    Pending.AdminName := 'console';
  Pending.Arg := Arg;
  Pending.IntArg := IntArg;
  Pending.IntArg2 := IntArg2;
  Pending.Expires := Now + Max(5, Cfg.AdminConfirmSeconds) / 86400;
  Pending.WaitingBackup := False;
  Say(Slot, 'This will ' + What + '.', CLR_WARN);
  Say(Slot, Format('Confirm with /yes <confirm password> within %d s, or /no.', [Max(5, Cfg.AdminConfirmSeconds)]), CLR_WARN);
end;

{ The words after /yes with one space between them, the way a confirm password with a space in it
  arrives; built in one piece, so no partial copy of the password stays behind in freed memory. }
function TypedPassword(const W: TStringArray): AnsiString;
var
  k, n, p: LongInt;
begin
  Result := '';
  n := 0;
  for k := 1 to High(W) do
  begin
    if k > 1 then
      Inc(n);
    Inc(n, Length(W[k]));
  end;
  SetLength(Result, n);
  p := 1;
  for k := 1 to High(W) do
  begin
    if k > 1 then
    begin
      Result[p] := ' ';
      Inc(p);
    end;
    if W[k] <> '' then
      Move(W[k][1], Result[p], Length(W[k]));
    Inc(p, Length(W[k]));
  end;
end;

procedure TZSEngine.Confirm(Slot: LongInt; const W: TStringArray; Source: LongInt);
var
  Cmd, Typed: AnsiString;
  Ok: Boolean;
begin
  Cmd := LowerCase(W[0]);
  if (Cmd <> '') and (Cmd[1] in ['/', '!']) then
    Delete(Cmd, 1, 1);
  { a password typed in public chat has been read by everybody on the server, whatever waited for
    it and whoever typed it: /yes is locked until the password is changed. An operation that was
    confirmed already and waits for its backup goes on. }
  if (Source = SRC_CHAT) and (Cmd = 'yes') and (Length(W) >= 2) then
  begin
    FYesLockUntil := Now + Max(1, Cfg.AdminConfirmLockMinutes) / 1440;
    if (Pending.Kind <> OP_NONE) and not Pending.WaitingBackup then
    begin
      if Pending.AdminSlot <> Slot then
        Say(Pending.AdminSlot, 'The operation waiting for /yes was cancelled: the confirm password was typed in chat.',
          CLR_BAD);
      ClearPending;
      Say(Slot, 'Never type the confirm password in chat! Operation cancelled, /yes locked. Change the password.', CLR_BAD);
    end
    else
      Say(Slot, 'Never type the confirm password in chat! /yes is locked. Change the password.', CLR_BAD);
    Audit('admin ' + AdminLabel(Self, Slot) + ': confirm password typed in public chat');
    Exit;
  end;
  if Pending.Kind = OP_NONE then
  begin
    Say(Slot, 'Nothing is waiting for confirmation.', CLR_WARN);
    Exit;
  end;
  if Pending.WaitingBackup then
  begin
    Say(Slot, 'The operation is already running.', CLR_WARN);
    Exit;
  end;
  if Pending.AdminSlot <> Slot then
  begin
    Say(Slot, 'Only the admin who started the operation can confirm it.', CLR_BAD);
    Exit;
  end;
  if Cmd = 'no' then
  begin
    ClearPending;
    Say(Slot, 'Cancelled.', CLR_GOOD);
    Exit;
  end;
  if Now > Pending.Expires then
  begin
    ClearPending;
    Say(Slot, 'The confirmation time is over, start again.', CLR_BAD);
    Exit;
  end;
  if Now < FYesLockUntil then
  begin
    Say(Slot, Format('/yes is locked for %d more min.', [Trunc((FYesLockUntil - Now) * 1440) + 1]), CLR_BAD);
    Exit;
  end;
  { /yes alone (a !yes in chat without a password among them) guessed nothing: it is no wrong
    password and locks nothing, the operation still waits }
  if Length(W) < 2 then
  begin
    Say(Slot, 'Confirm with the command /yes <confirm password> (never in chat), or /no.', CLR_WARN);
    Exit;
  end;
  { a password with a space in it arrives as several words }
  Typed := TypedPassword(W);
  Ok := ConstantTimeEquals(W[1], Cfg.AdminConfirmPassword) or ConstantTimeEquals(Typed, Cfg.AdminConfirmPassword);
  WipeString(Typed);
  if not Ok then
  begin
    FYesLockUntil := Now + Max(1, Cfg.AdminConfirmLockMinutes) / 1440;
    Audit(Format('admin %s: wrong confirm password for %s, /yes locked for %d min',
      [Pending.AdminName, OpDescription(Pending.Kind), Cfg.AdminConfirmLockMinutes]));
    ClearPending;
    Say(Slot, Format('Wrong password. /yes is locked for %d min.', [Max(1, Cfg.AdminConfirmLockMinutes)]), CLR_BAD);
    Exit;
  end;
  if DB.SnapshotActive then
  begin
    Say(Slot, 'A save is in progress, type /yes again in a few seconds.', CLR_WARN);
    Exit;
  end;
  if not OpNeedsBackup(Pending.Kind) or FReadOnly or (Writer = nil) then
  begin
    RunPendingOp;
    Exit;
  end;
  Pending.WaitingBackup := True;
  StartSnapshot(SNAP_PREOP, BackupFileName('before-' + OpDescription(Pending.Kind)));
  Say(Slot, 'Confirmed. Making a backup first...', CLR_GOOD);
end;

procedure TZSEngine.RunPendingOp;
var
  i, Idx, Src, Removed, Kept, Slot: LongInt;
  P: PPlayerProfile;
  Keep: TServerRecords;
  Cutoff: Double;
  What, Msg: AnsiString;
begin
  Pending.WaitingBackup := False;
  Slot := Pending.AdminSlot;
  What := '';
  case Pending.Kind of
    OP_RESET_ALL_PLAYERS:
      begin
        for i := 0 to DB.ProfileCount - 1 do
        begin
          P := DB.Profiles[i];
          if P = nil then
            Continue;
          ResetProfileStats(P^);
          P^.Points := Cfg.StartingPoints;
          DB.InitRatings(P^);
          DB.Touch(i);
        end;
        { what every player did on every map ([Matrix]) goes with it }
        DB.PM.RemoveAll;
        DB.RebuildRanks;
        What := 'all player statistics were reset';
      end;
    OP_RESET_ALL_MAPS:
      begin
        for i := 0 to DB.MapCount - 1 do
        begin
          ResetMapStats(DB.Maps[i]);
          DB.TouchMap(i);
        end;
        DB.PM.RemoveAll;
        What := 'all map statistics were reset';
      end;
    OP_RESET_PLAYER:
      begin
        Idx := DB.IndexOfId(Pending.IntArg);
        if DB.Valid(Idx) then
        begin
          P := DB.Profiles[Idx];
          ResetProfileStats(P^);
          P^.Points := Cfg.StartingPoints;
          DB.InitRatings(P^);
          DB.Touch(Idx);
          DB.RefreshRanks(Idx);
          DB.PM.RemoveRecordsOf(P^.ID);
          What := Format('statistics of #%d %s were reset', [P^.ID, P^.ActiveName]);
        end;
      end;
    OP_RESET_MAP:
      begin
        Idx := DB.FindMap(Pending.Arg, False);
        if Idx >= 0 then
        begin
          ResetMapStats(DB.Maps[Idx]);
          DB.TouchMap(Idx);
          DB.PM.RemoveMap(DB.Maps[Idx].MapName);
          What := 'statistics of map ' + Pending.Arg + ' were reset';
        end;
      end;
    OP_RESET_SERVER:
      begin
        Keep := DB.Server;
        ClearServer(DB.Server);
        DB.Server.NextProfileID := Keep.NextProfileID;
        DB.Server.NextMapID := Keep.NextMapID;
        DB.Server.NextSeasonId := Keep.NextSeasonId;
        DB.Server.SeasonId := Keep.SeasonId;
        DB.Server.SeasonStart := Keep.SeasonStart;
        DB.Server.SeasonEnd := Keep.SeasonEnd;
        DB.Server.LastBalanceDay := Keep.LastBalanceDay;
        DB.Server.LastCheckpointsDay := Keep.LastCheckpointsDay;
        DB.Server.LastAutoBackup := Keep.LastAutoBackup;
        { the wait of the check points is bookkeeping of the balance, not a statistic }
        DB.Server.CheckWaitSince := Keep.CheckWaitSince;
        DB.Server.MatchupsFixed := True;
        DB.Server.MatchLengthsSplit := True;
        DB.Server.ScoresSplit := True;
        DB.Server.HitModel := Keep.HitModel;
        DB.TouchServer;
        What := 'server statistics were reset';
      end;
    OP_REMOVE_OLDER:
      begin
        Cutoff := Now - Pending.IntArg;
        Removed := 0;
        Kept := 0;
        DB.BeginBulkDelete;
        for i := 0 to DB.ProfileCount - 1 do
        begin
          P := DB.Profiles[i];
          if (P = nil) or (P^.LastPlayedTime <= 0) or (P^.LastPlayedTime >= Cutoff) then
            Continue;
          { old enough, but registered, protected by its protection days or playing right now }
          if (P^.ProtectionDays > 0) or IsRegistered(P^) or (Identity.SlotOfProfile(P^.ID) > 0) then
          begin
            Inc(Kept);
            Continue;
          end;
          DB.DeleteProfile(i);
          Inc(Removed);
        end;
        DB.EndBulkDelete;
        What := Format('%d accounts inactive for %d days were removed', [Removed, Pending.IntArg]);
        { the admin sees that the rest was kept on purpose, not overlooked }
        if Kept > 0 then
          What := What + Format(' (%d more kept: registered, with protection days or online)', [Kept]);
      end;
    OP_RESTORE:
      begin
        RestoreBackup(Pending.Arg, Slot);
        What := 'backup ' + Pending.Arg + ' restore started';
      end;
    OP_MERGE:
      begin
        Src := DB.IndexOfId(Pending.IntArg);
        Idx := DB.IndexOfId(Pending.IntArg2);
        if DB.Valid(Src) and DB.Valid(Idx) and (Src <> Idx) and (Identity.SlotOfProfile(Pending.IntArg) = 0) then
        begin
          DB.MergeProfile(Idx, Src, Cfg.StartingPoints);
          What := Format('account #%d was merged into #%d', [Pending.IntArg, Pending.IntArg2]);
        end
        else
          What := 'merge skipped: accounts missing or the source is online';
      end;
    OP_UNREGISTER:
      begin
        Idx := DB.IndexOfId(Pending.IntArg);
        if DB.Valid(Idx) then
        begin
          Identity.AdminUnregister(Idx);
          What := Format('registration of #%d was removed', [Pending.IntArg]);
        end;
      end;
    OP_SETPASS:
      begin
        Idx := DB.IndexOfId(Pending.IntArg);
        if DB.Valid(Idx) then
          { the hash is made on the service thread: the password counts once it is stored, and the
            admins hear it then (PollResults) }
          if Identity.AdminSetPassword(Idx, Pending.Arg, Msg) then
            What := Format('password of #%d %s is being set', [DB.Profiles[Idx]^.ID, DB.Profiles[Idx]^.ActiveName])
          else
          begin
            Say(Slot, Msg, CLR_BAD);
            What := Format('password of #%d was not changed (%s)', [Pending.IntArg, Msg]);
          end;
      end;
  end;
  if What = '' then
    What := OpDescription(Pending.Kind) + ': target not found';
  Audit('admin ' + Pending.AdminName + ': ' + What);
  NotifyAdmins('[ZitroStats] ' + What + '.', CLR_GOOD);
  if (Pending.Kind <> OP_RESTORE) and (Writer <> nil) then
    DB.FlushJournal(Writer, True);
  ClearPending;
end;

procedure TZSEngine.RestoreBackup(const FileName: AnsiString; AdminSlot: LongInt);
var
  St: TStoreState;
  Info: TStoreLoadInfo;
  Path: AnsiString;
  S: LongInt;
  Names, Steams, Hwids, IPs: array[1..MAX_PLAYERS] of AnsiString;
begin
  { also when the exchange never started (unreadable files): the next start reads the shared
    database again, and a restored file would only last until then }
  if (SqlState <> nil) or (Cfg.MySQLEngine = MYSQL_SHARED) then
  begin
    NotifyAdmins('[ZitroStats] Engine = mysql: the statistics live in the shared database, and a backup of this ' +
      'server''s files cannot take its place. Restore the database itself, or start with Engine = local first; ' +
      'damaged files: move them away and restart, the start reads the database.', CLR_BAD);
    Exit;
  end;
  Path := StorePath(BackupDir, ExtractFileName(FileName));
  if not StoreLoadFile(Path, St, Info) then
  begin
    NotifyAdmins('[ZitroStats] backup ' + Path + ' could not be read, nothing changed.', CLR_BAD);
    Exit;
  end;
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human then
    begin
      Names[S] := Identity.Slots[S].Name;
      Steams[S] := Identity.Slots[S].Steam;
      Hwids[S] := Identity.Slots[S].Hwid;
      IPs[S] := Identity.Slots[S].IP;
      Identity.Slots[S].InUse := False;
    end;
  DB.TakeState(St);
  for S := 1 to MAX_PLAYERS do
    if Live[S].Active and Live[S].Human then
    begin
      Identity.Join(S, Names[S], Steams[S], Hwids[S], IPs[S], True);
      { Steam answered long ago for these players: without a SteamID they use the computer account }
      Identity.SteamAuthFailed(S);
    end;
  { a restore is the way out of read-only after a damaged database }
  if FReadOnly and FLoadFailed and (IO <> nil) and (IO.LockError = '') then
  begin
    ArchiveDamagedFiles;
    if Writer = nil then
      Writer := TStoreWriter.Create(IO, FMaxGen);
    FReadOnly := False;
    FLoadFailed := False;
    LoadMessage := 'restored from backup ' + ExtractFileName(Path);
  end;
  if Match.Active then
    Match.MapIndex := DB.FindMap(Match.MapName, True);
  StartSnapshot(SNAP_RESTORED, '');
  NotifyAdmins(Format('[ZitroStats] restored %d accounts from %s, saving...', [DB.LiveProfiles, ExtractFileName(Path)]), CLR_GOOD);
end;

function TZSEngine.AdminCommand(Slot: LongInt; const W: TStringArray; Source: LongInt): Boolean;
var
  Cmd, Arg, Why, Who: AnsiString;
  Idx, Days, k, Src, Dst: LongInt;
  L: TStringList;
begin
  Result := True;
  Cmd := LowerCase(W[0]);
  if (Cmd <> '') and (Cmd[1] in ['/', '!']) then
    Delete(Cmd, 1, 1);
  if Length(W) > 1 then
    Arg := W[1]
  else
    Arg := '';

  if (Cmd = 'yes') or (Cmd = 'no') then
    Confirm(Slot, W, Source)
  else if (Cmd = 'zs_save') or (Cmd = 'zs_sync') then
  begin
    if (Writer <> nil) and not FReadOnly then
    begin
      { the changes go to the IO thread; the mark behind them says when they are on the disk }
      DB.FlushJournal(Writer, True);
      SaveAsker := Slot;
      SaveFailed := False;
      IO.Enqueue(NewJob(sjNotify, 0, TAG_SAVE));
      Say(Slot, '[ZitroStats] Writing the changes...', CLR_HINT);
    end
    else
      Say(Slot, '[ZitroStats] The database is read-only, nothing is written.', CLR_BAD);
  end
  else if Cmd = 'zs_backup' then
  begin
    if (Writer = nil) or FReadOnly then
      Say(Slot, '[ZitroStats] The database is read-only, no backup can be written.', CLR_BAD)
    else if SnapshotBusy then
      Say(Slot, '[ZitroStats] A save is already running, try again in a moment.', CLR_WARN)
    else
    begin
      BackupAsker := Slot;
      StartSnapshot(SNAP_MANUAL, BackupFileName('manual'));
      Say(Slot, '[ZitroStats] Writing a backup; you hear when it is done.', CLR_HINT);
    end;
  end
  else if Cmd = 'zs_backups' then
  begin
    L := ListBackups(BackupDir);
    try
      if L.Count = 0 then
        Say(Slot, 'No backups in ' + BackupDir, CLR_WARN)
      else if L.Count > 10 then
        { the names start with the date, so the list ends with the newest }
        Say(Slot, Format('%d backups in %s, the newest 10:', [L.Count, BackupDir]), CLR_HINT);
      for k := Max(0, L.Count - 10) to L.Count - 1 do
        Say(Slot, Format('%s  %d KB', [L[k], FileSizeOf(StorePath(BackupDir, L[k])) div 1024]), CLR_HINT);
    finally
      L.Free;
    end;
  end
  else if Cmd = 'zs_restore' then
  begin
    { refused before the confirmation and the backup that comes with it (RestoreBackup says why) }
    if SqlState <> nil then
      Say(Slot, '[ZitroStats] Engine = mysql: the statistics live in the shared database, and a backup of this ' +
        'server''s files cannot take its place. Restore the database itself, or start with Engine = local first.', CLR_BAD)
    else if (Arg = '') or not FileExists(StorePath(BackupDir, ExtractFileName(Arg))) then
      Say(Slot, 'Usage: /zs_restore <file from /zs_backups>', CLR_WARN)
    else
      AskConfirmation(Slot, OP_RESTORE, ExtractFileName(Arg), 0, 0, 'replace ALL statistics with backup ' + ExtractFileName(Arg));
  end
  else if Cmd = 'resetallplayersstats' then
    AskConfirmation(Slot, OP_RESET_ALL_PLAYERS, '', 0, 0, 'reset the statistics of ALL players')
  else if Cmd = 'resetallmapsstats' then
    AskConfirmation(Slot, OP_RESET_ALL_MAPS, '', 0, 0, 'reset the statistics of ALL maps')
  else if Cmd = 'resetserverstats' then
    AskConfirmation(Slot, OP_RESET_SERVER, '', 0, 0, 'reset the server statistics')
  else if Cmd = 'resetplayerstats' then
  begin
    Idx := FindProfileArg(DB, Trim(RestAfterWords(JoinWords(W), 1)));
    if DB.Valid(Idx) then
      AskConfirmation(Slot, OP_RESET_PLAYER, '', DB.Profiles[Idx]^.ID, 0,
        Format('reset the statistics of #%d %s', [DB.Profiles[Idx]^.ID, DB.Profiles[Idx]^.ActiveName]))
    else
      Say(Slot, 'Usage: /resetplayerstats <#id|name>', CLR_WARN);
  end
  else if Cmd = 'resetmapstats' then
  begin
    Arg := Trim(RestAfterWords(JoinWords(W), 1));
    if (Arg = '') and Match.Active then
      Arg := Match.MapName;
    if DB.FindMap(Arg, False) >= 0 then
      AskConfirmation(Slot, OP_RESET_MAP, Arg, 0, 0, 'reset the statistics of map ' + Arg)
    else
      Say(Slot, 'Usage: /resetmapstats <map>', CLR_WARN);
  end
  else if Cmd = 'removeolderthan' then
  begin
    Days := StrToIntDef(Arg, 0);
    if Days < 30 then
      Say(Slot, 'Usage: /removeolderthan <days, at least 30>', CLR_WARN)
    else
      AskConfirmation(Slot, OP_REMOVE_OLDER, '', Days, 0,
        Format('delete unregistered accounts not seen for %d days', [Days]));
  end
  else if Cmd = 'zs_merge' then
  begin
    if Length(W) >= 3 then
    begin
      Src := FindProfileArg(DB, W[1]);
      Dst := FindProfileArg(DB, W[2]);
    end
    else
    begin
      Src := -1;
      Dst := -1;
    end;
    if DB.Valid(Src) and DB.Valid(Dst) and (Src <> Dst) then
      AskConfirmation(Slot, OP_MERGE, '', DB.Profiles[Src]^.ID, DB.Profiles[Dst]^.ID,
        Format('merge #%d %s into #%d %s', [DB.Profiles[Src]^.ID, DB.Profiles[Src]^.ActiveName,
          DB.Profiles[Dst]^.ID, DB.Profiles[Dst]^.ActiveName]))
    else
      Say(Slot, 'Usage: /zs_merge <#from> <#into>', CLR_WARN);
  end
  else if Cmd = 'zs_unregister' then
  begin
    Idx := FindProfileArg(DB, Arg);
    if DB.Valid(Idx) and IsRegistered(DB.Profiles[Idx]^) then
      AskConfirmation(Slot, OP_UNREGISTER, '', DB.Profiles[Idx]^.ID, 0,
        Format('remove the password and e-mail of #%d %s', [DB.Profiles[Idx]^.ID, DB.Profiles[Idx]^.ActiveName]))
    else
      Say(Slot, 'Usage: /zs_unregister <#id> (registered accounts only)', CLR_WARN);
  end
  else if Cmd = 'zs_setpass' then
  begin
    if Source = SRC_CHAT then
      Say(Slot, 'Use /zs_setpass, never in chat.', CLR_BAD)
    else if Length(W) = 3 then
    begin
      Idx := FindProfileArg(DB, W[1]);
      if not DB.Valid(Idx) then
        Say(Slot, 'No such account.', CLR_BAD)
      else
        AskConfirmation(Slot, OP_SETPASS, W[2], DB.Profiles[Idx]^.ID, 0,
          Format('set a new password for #%d %s', [DB.Profiles[Idx]^.ID, DB.Profiles[Idx]^.ActiveName]));
    end
    else
      Say(Slot, 'Usage: /zs_setpass <#id> <password>', CLR_WARN);
  end
  else if Cmd = 'zs_reload' then
    PushEvent(NewEvent(zeReloadConfig))
  { team balance: /bal [on|off], /mix, /swap, /move, /balexclude, /balinfo }
  else if (Cmd = 'bal') and (Source <> SRC_CHAT) then
  begin
    Audit(AdminCommandLine(Self, Slot, Source, W));
    if SameText(Arg, 'off') then
      BalSetPaused(Slot, True)
    else if SameText(Arg, 'on') then
      BalSetPaused(Slot, False)
    else if Arg = '' then
      BalAdminCheck(Slot)
    else
      Say(Slot, 'Usage: /bal (a change now), /bal off, /bal on', CLR_WARN);
  end
  else if Cmd = 'balinfo' then
    CmdBalanceInfo(Self, Slot)
  else if Cmd = 'mix' then
    BalMix(Slot)
  else if Cmd = 'swap' then
  begin
    if Length(W) <> 3 then
      Say(Slot, 'Usage: /swap <player> <player> (slot, #id or a part of the name; a name with a space: its slot)',
        CLR_WARN)
    else
    begin
      Src := ResolvePlayerSlot(Self, W[1], Why);
      if Src = 0 then
        Say(Slot, '[Balance] ' + Why, CLR_WARN)
      else
      begin
        Dst := ResolvePlayerSlot(Self, W[2], Why);
        if Dst = 0 then
          Say(Slot, '[Balance] ' + Why, CLR_WARN)
        else
          BalSwap(Slot, Src, Dst);
      end;
    end;
  end
  else if Cmd = 'move' then
  begin
    if Length(W) < 3 then
      Say(Slot, 'Usage: /move <player> <alpha|bravo|charlie|delta|spec>', CLR_WARN)
    else if TeamFromText(W[High(W)]) <= 0 then
      Say(Slot, Format('[Balance] "%s" is no team: alpha, bravo, charlie, delta or spec (1-5).', [W[High(W)]]), CLR_WARN)
    else
    begin
      Who := Trim(Copy(RestAfterWords(JoinWords(W), 1), 1, Length(RestAfterWords(JoinWords(W), 1)) - Length(W[High(W)])));
      Src := ResolvePlayerSlot(Self, Who, Why);
      if Src = 0 then
        Say(Slot, '[Balance] ' + Why, CLR_WARN)
      else
        BalMoveTo(Slot, Src, TeamFromText(W[High(W)]));
    end;
  end
  else if Cmd = 'balexclude' then
  begin
    if Arg = '' then
      Say(Slot, 'Usage: /balexclude <player>', CLR_WARN)
    else
    begin
      Src := ResolvePlayerSlot(Self, Trim(RestAfterWords(JoinWords(W), 1)), Why);
      if Src = 0 then
        Say(Slot, '[Balance] ' + Why, CLR_WARN)
      else
        BalToggleExclude(Slot, Src);
    end;
  end
  else if (Cmd = 'zs_status') and (Arg = '') then
  begin
    { with a player name the command is the account audit in zs_commands }
    Say(Slot, Format('[ZitroStats %s] %d accounts, %d maps, %d online, read-only: %s', [ZS_VERSION_STR, DB.LiveProfiles,
      DB.MapCount, HumansOnline, BoolToStr(FReadOnly, 'YES', 'no')]), CLR_HINT);
    if Writer <> nil then
      Say(Slot, Format('journal gen %d, %d KB since snapshot, IO queue %d KB, dropped events %d',
        [Int64(Writer.Generation), Writer.JournalBytes div 1024, IO.PendingBytes div 1024, FEventsDropped]), CLR_HINT);
    if (DB.Server.ScoreFixes > 0) or (DB.Server.VoidedCaptures > 0) then
      Say(Slot, Format('score guard: %d point(s) taken back, %d capture(s) of them (integrity.log)',
        [DB.Server.ScoreFixes, DB.Server.VoidedCaptures]), CLR_HINT);
    if LoadMessage <> '' then
      Say(Slot, 'load: ' + LoadMessage, CLR_WARN);
    if SqlState <> nil then
      Say(Slot, SqlStatusText(Self), CLR_HINT);
  end
  else
    Result := False;
end;

{ ---------------- HUD and welcome ---------------- }

procedure TZSEngine.RefreshHud(Slot: LongInt; Force: Boolean);
var
  Idx, k, n: LongInt;
  Text, Ev: AnsiString;
  A: TZSAction;
begin
  Idx := Identity.ProfileIndex(Slot);
  if not Cfg.HudEnabled or not DB.Valid(Idx) or not DB.Profiles[Idx]^.DisplayHUD or (Live[Slot].Team = TEAM_SPEC) then
  begin
    if Extra[Slot].HudText <> '' then
    begin
      A := NewAction(ACT_BIGTEXT, Slot, Cfg.HudColor, ' ');
      A.P1 := Cfg.HudLayer;
      A.P2 := Cfg.HudX;
      A.P3 := Cfg.HudY;
      A.F1 := Cfg.HudScale;
      A.F2 := 1;
      EmitAction(A);
      Extra[Slot].HudText := '';
    end;
    Extra[Slot].HudEvents := nil;
    Extra[Slot].HudUntil := nil;
    Exit;
  end;
  { the notes on one line: each stays [HUD] EventSeconds from the refresh that first shows it (a
    refresh a second; half a second of slack keeps a late or early tick from adding or taking one) }
  FitHudUntil(Extra[Slot]);
  Ev := '';
  n := 0;
  for k := 0 to High(Extra[Slot].HudEvents) do
  begin
    if Extra[Slot].HudUntil[k] = 0 then
      Extra[Slot].HudUntil[k] := GameTick + Max(1, Cfg.HudEventSeconds) * TICKS_PER_SECOND - TICKS_PER_SECOND div 2
    else if GameTick >= Extra[Slot].HudUntil[k] then
      Continue;
    Ev := Ev + '  ' + Extra[Slot].HudEvents[k];
    Extra[Slot].HudEvents[n] := Extra[Slot].HudEvents[k];
    Extra[Slot].HudUntil[n] := Extra[Slot].HudUntil[k];
    Inc(n);
  end;
  SetLength(Extra[Slot].HudEvents, n);
  SetLength(Extra[Slot].HudUntil, n);
  if Identity.Slots[Slot].Locked then
    Text := 'Not logged in - stats are not saved'
  else
    Text := Format('Rank: %d/%d  Points: %d%s', [PlayerRank(Idx), DB.Ranks[RANK_POINTS].Count, DB.Profiles[Idx]^.Points, Ev]);
  if Force or (Text <> Extra[Slot].HudText) or
     (GameTick - Extra[Slot].HudSentTick >= Max(1, Cfg.HudRefreshSeconds) * TICKS_PER_SECOND) then
  begin
    A := NewAction(ACT_BIGTEXT, Slot, Cfg.HudColor, Text);
    A.P1 := Cfg.HudLayer;
    A.P2 := Cfg.HudX;
    A.P3 := Cfg.HudY;
    A.F1 := Cfg.HudScale;
    A.F2 := (Max(1, Cfg.HudRefreshSeconds) + 3) * TICKS_PER_SECOND;
    EmitAction(A);
    Extra[Slot].HudText := Text;
    Extra[Slot].HudSentTick := GameTick;
  end;
end;

procedure TZSEngine.WelcomePlayer(Slot: LongInt);
var
  Idx: LongInt;
  Text: AnsiString;
begin
  if Identity.IsPending(Slot) or (Live[Slot].Team = TEAM_SPEC) then
    Exit;
  Extra[Slot].Welcomed := True;
  Idx := Identity.ProfileIndex(Slot);
  if not Cfg.WelcomeEnabled or not DB.Valid(Idx) or Identity.Slots[Slot].Locked then
    Exit;
  Text := Format('Welcome %s! Rank %d/%d, %d points.', [Live[Slot].Name, PlayerRank(Idx), DB.Ranks[RANK_POINTS].Count,
    DB.Profiles[Idx]^.Points]);
  if Cfg.WelcomeBroadcast then
    Broadcast(Text, CLR_GOOD)
  else
    Say(Slot, Text, CLR_GOOD);
  { passwords are offered only to players without Steam }
  if not Identity.IsSteamSession(Slot) and not IsRegistered(DB.Profiles[Idx]^) then
    Say(Slot, 'Your stats belong to this computer. Protect them with a password: /register', CLR_HINT);
end;

{ ---------------- developer API (game thread) ---------------- }

function ProfileStatValue(Engine: TZSEngine; const P: TPlayerProfile; Index, StatId: LongInt): Double;
var
  s, HS: LongInt;
begin
  case StatId of
    0: Result := P.Points;
    1: Result := P.Kills;
    2: Result := P.Deaths;
    3: if P.Deaths > 0 then Result := P.Kills / P.Deaths else Result := P.Kills;
    4: Result := PerformanceRating(P, Engine.Match.GameStyle, Engine.Match.Survival, Engine.Match.FriendlyFire, Engine.Cfg.RatingMode);
    5: Result := Engine.PlayerRank(Index);
    6: Result := P.TimePlayed;
    7:
      begin
        HS := 0;
        for s := 0 to WSLOT_COUNT - 1 do
          Inc(HS, P.Weapons[s].HSKills);
        Result := HS;
      end;
    8: if P.Shots > 0 then Result := Min(100.0, P.ShotsHits * 100.0 / P.Shots) else Result := 0;
    9: Result := P.FlagsScore;
    10: Result := P.Assist;
    11: Result := P.ClutchesWon;
    12: Result := P.MaxKillStreak;
    13: Result := P.DamageDealt;
    14: Result := P.DamageReceived;
    15: Result := P.ProneKills;
    16: Result := P.JetFlyTimeSeconds;
    17: Result := P.CampKills;
    18: Result := P.BinkRecoveryKills;
    19: Result := P.SpreeKills;
    20: Result := P.RampageKills;
    21: Result := P.DominatingSpreeKills;
    22: Result := P.UnstoppableKills;
    23: Result := P.GodlikeKills;
    24: Result := P.ShutDownKills;
    25: Result := P.FinisherKills;
    26: Result := P.FastestCapSeconds;
    27: Result := P.CarrierEscortKills;
    28: Result := P.FlagJuggles;
    29: Result := P.ContestedHolds;
    30: Result := P.LongestKillDistance;
    31: Result := P.Wins;
    32: Result := P.Loses;
    33: Result := P.ProtectionDays;
    34: Result := P.SeasonPoints;
    35: Result := GlickoConservative(P.Glicko[Engine.CurrentFamily], Engine.Cfg.GlickoConservative);
    36: Result := OpenSkillOrdinal(P.OpenSkill[Engine.CurrentFamily]);
    37: Result := P.ID;
    38: Result := Ord(IsRegistered(P));
    39: Result := P.Mmr[Engine.CurrentFamily].R;
    else Result := 0;
  end;
end;

{ The game thread asks these while the engine thread may hold the state lock (an event batch or a
  piece of a snapshot). Waiting there would stop the whole server, so a reader tries the lock
  once and otherwise answers with the value it read last. }
const
  API_CACHE_SIZE = 128;
  API_PLAYER_STAT = 1;
  API_PROFILE_STAT = 2;
  API_PLAYER_RANK = 3;
  API_PLAYER_NAME = 4;
  API_TOP_PLAYER = 5;
  API_PROFILE_COUNT = 6;
  API_SERVER_PEAK = 7;
  API_PLAYER_HUD = 8;

type
  TApiCacheEntry = record
    Key: Int64;
    Value: Double;
    Text: AnsiString;
  end;

var
  ApiCache: array[0..API_CACHE_SIZE - 1] of TApiCacheEntry;   { read and written by the game thread only }

function ApiKey(Kind, A, B: LongInt): Int64;
begin
  Result := (Int64(Kind) shl 56) xor (Int64(LongWord(A)) shl 24) xor Int64(LongWord(B));
end;

function ApiCacheSlot(Key: Int64): LongInt;
begin
  Result := LongInt((Key xor (Key shr 32)) and (API_CACHE_SIZE - 1));
end;

procedure ApiCachePut(Key: Int64; Value: Double; const Text: AnsiString);
var
  i: LongInt;
begin
  i := ApiCacheSlot(Key);
  ApiCache[i].Key := Key;
  ApiCache[i].Value := Value;
  ApiCache[i].Text := Text;
end;

procedure ApiCacheGet(Key: Int64; out Value: Double; out Text: AnsiString);
var
  i: LongInt;
begin
  i := ApiCacheSlot(Key);
  if ApiCache[i].Key = Key then
  begin
    Value := ApiCache[i].Value;
    Text := ApiCache[i].Text;
  end
  else
  begin
    Value := 0;
    Text := '';
  end;
end;

{ no retries and no yielding: on a server with one CPU every yield could hand the engine thread
  a whole time slice }
function TZSEngine.ApiTryLock: Boolean;
begin
  Result := TryEnterCriticalSection(StateLock) <> 0;
end;

function TZSEngine.ApiPlayerStat(Slot, StatId: LongInt): Double;
var
  Idx: LongInt;
  Key: Int64;
  Txt: AnsiString;
begin
  Result := 0;
  if not FReady then
    Exit;
  Key := ApiKey(API_PLAYER_STAT, Slot, StatId);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, Result, Txt);
    Exit;
  end;
  try
    Idx := Identity.ProfileIndex(Slot);
    if DB.Valid(Idx) then
      Result := ProfileStatValue(Self, DB.Profiles[Idx]^, Idx, StatId);
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, Result, '');
end;

function TZSEngine.ApiProfileStat(ProfileId, StatId: LongInt): Double;
var
  Idx: LongInt;
  Key: Int64;
  Txt: AnsiString;
begin
  Result := 0;
  if not FReady then
    Exit;
  Key := ApiKey(API_PROFILE_STAT, ProfileId, StatId);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, Result, Txt);
    Exit;
  end;
  try
    Idx := DB.IndexOfId(ProfileId);
    if DB.Valid(Idx) then
      Result := ProfileStatValue(Self, DB.Profiles[Idx]^, Idx, StatId);
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, Result, '');
end;

function TZSEngine.ApiPlayerRank(Slot: LongInt): LongInt;
var
  Key: Int64;
  V: Double;
  Txt: AnsiString;
begin
  Result := 0;
  if not FReady then
    Exit;
  Key := ApiKey(API_PLAYER_RANK, Slot, 0);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, V, Txt);
    Exit(Round(V));
  end;
  try
    Result := PlayerRank(Identity.ProfileIndex(Slot));
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, Result, '');
end;

function TZSEngine.ApiPlayerName(Slot: LongInt): AnsiString;
var
  Key: Int64;
  V: Double;
begin
  Result := '';
  Key := ApiKey(API_PLAYER_NAME, Slot, 0);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, V, Result);
    Exit;
  end;
  try
    if SlotValid(Slot) then
      Result := Live[Slot].Name;
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, 0, Result);
end;

function TZSEngine.ApiTopPlayer(Rank: LongInt): AnsiString;
var
  Idx: LongInt;
  Key: Int64;
  V: Double;
begin
  Result := '';
  if not FReady then
    Exit;
  Key := ApiKey(API_TOP_PLAYER, Rank, 0);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, V, Result);
    Exit;
  end;
  try
    Idx := DB.Ranks[RANK_POINTS].At(Rank);
    if DB.Valid(Idx) then
      Result := DB.Profiles[Idx]^.ActiveName;
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, 0, Result);
end;

{ the same for another library on a thread of its own (AntiFake): it waits for the statistics
  instead of taking an older answer, and adds the SteamID after a tab }
function TZSEngine.ApiTopPlayerWait(Rank: LongInt): AnsiString;
var
  Idx: LongInt;
begin
  Result := '';
  if not FReady then
    Exit;
  EnterCriticalSection(StateLock);
  try
    if (Rank < 1) or (Rank > DB.Ranks[RANK_POINTS].Count) then
      Exit;
    Idx := DB.Ranks[RANK_POINTS].At(Rank);
    if DB.Valid(Idx) then
      Result := DB.Profiles[Idx]^.ActiveName + #9 + DB.Profiles[Idx]^.ActiveSteam;
  finally
    LeaveCriticalSection(StateLock);
  end;
end;

function TZSEngine.ApiProfileCount: LongInt;
var
  Key: Int64;
  V: Double;
  Txt: AnsiString;
begin
  Result := 0;
  if not FReady then
    Exit;
  Key := ApiKey(API_PROFILE_COUNT, 0, 0);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, V, Txt);
    Exit(Round(V));
  end;
  try
    Result := DB.LiveProfiles;
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, Result, '');
end;

function TZSEngine.ApiServerPeak: LongInt;
var
  Key: Int64;
  V: Double;
  Txt: AnsiString;
begin
  Result := 0;
  if not FReady then
    Exit;
  Key := ApiKey(API_SERVER_PEAK, 0, 0);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, V, Txt);
    Exit(Round(V));
  end;
  try
    Result := DB.Server.PeakOnlineCount;
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, Result, '');
end;

function TZSEngine.ApiPlayerHud(Slot: LongInt): Boolean;
var
  Idx: LongInt;
  Key: Int64;
  V: Double;
  Txt: AnsiString;
begin
  Result := False;
  if not FReady then
    Exit;
  Key := ApiKey(API_PLAYER_HUD, Slot, 0);
  if not ApiTryLock then
  begin
    ApiCacheGet(Key, V, Txt);
    Exit(V <> 0);
  end;
  try
    { with [HUD] Enabled = 0 nobody sees the HUD, whatever the account says }
    Idx := Identity.ProfileIndex(Slot);
    Result := Cfg.HudEnabled and DB.Valid(Idx) and DB.Profiles[Idx]^.DisplayHUD;
  finally
    LeaveCriticalSection(StateLock);
  end;
  ApiCachePut(Key, Ord(Result), '');
end;
