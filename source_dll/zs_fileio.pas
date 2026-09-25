unit zs_fileio;

{ File helpers with explicit durability. Atomic writes go through a temporary file that is
  flushed to disk before it replaces the target, so a crash leaves the old or the new file,
  never a torn one. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

function EnsureDir(const Dir: AnsiString): Boolean;
function FileSizeOf(const Path: AnsiString): Int64;
function ReadWholeFile(const Path: AnsiString; out Data: AnsiString;
  MaxSize: Int64 = 1024 * 1024 * 1024): Boolean;
function SyncHandle(Handle: THandle): Boolean;
function ReplaceFile(const Src, Dst: AnsiString): Boolean;
function WriteFileAtomic(const Path, Data: AnsiString; Sync: Boolean = True): Boolean;
function AppendToFile(const Path, Data: AnsiString): Boolean;
function CopyFileDurable(const Src, Dst: AnsiString): Boolean;
function ListFiles(const Dir, Mask: AnsiString): TStringList;

implementation

uses
  {$IFDEF WINDOWS}Windows{$ELSE}BaseUnix, Unix{$ENDIF};

{$IFDEF WINDOWS}
const
  MOVEFILE_WRITE_THROUGH = $00000008;
{$ENDIF}

function EnsureDir(const Dir: AnsiString): Boolean;
begin
  if (Dir = '') or DirectoryExists(Dir) then
    Exit(True);
  Result := ForceDirectories(Dir);
end;

function FileSizeOf(const Path: AnsiString): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if SysUtils.FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    SysUtils.FindClose(SR);
  end;
end;

function ReadWholeFile(const Path: AnsiString; out Data: AnsiString; MaxSize: Int64): Boolean;
var
  F: TFileStream;
  Size: Int64;
begin
  Data := '';
  Result := False;
  if not FileExists(Path) then
    Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Size := F.Size;
      if (Size < 0) or (Size > MaxSize) then
        Exit;
      SetLength(Data, Size);
      if Size > 0 then
        F.ReadBuffer(Data[1], Size);
      Result := True;
    finally
      F.Free;
    end;
  except
    Data := '';
    Result := False;
  end;
end;

function SyncHandle(Handle: THandle): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := Windows.FlushFileBuffers(Handle);
  {$ELSE}
  Result := fpfsync(Handle) = 0;
  {$ENDIF}
end;

{$IFNDEF WINDOWS}
procedure SyncDir(const Dir: AnsiString);
var
  Fd: LongInt;
begin
  if Dir = '' then
    Exit;
  Fd := fpOpen(Dir, O_RDONLY);
  if Fd >= 0 then
  begin
    fpfsync(Fd);
    fpClose(Fd);
  end;
end;
{$ENDIF}

function ReplaceFile(const Src, Dst: AnsiString): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := MoveFileExA(PAnsiChar(Src), PAnsiChar(Dst), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH);
  {$ELSE}
  Result := fpRename(Src, Dst) = 0;
  if Result then
    SyncDir(ExtractFileDir(Dst));
  {$ENDIF}
end;

function WriteFileAtomic(const Path, Data: AnsiString; Sync: Boolean): Boolean;
var
  Tmp: AnsiString;
  F: TFileStream;
begin
  Result := False;
  Tmp := Path + '.tmp';
  try
    EnsureDir(ExtractFileDir(Path));
    F := TFileStream.Create(Tmp, fmCreate);
    try
      if Data <> '' then
        F.WriteBuffer(Data[1], Length(Data));
      if Sync then
        SyncHandle(F.Handle);
    finally
      F.Free;
    end;
    Result := ReplaceFile(Tmp, Path);
  except
    Result := False;
  end;
  if not Result then
    SysUtils.DeleteFile(Tmp);
end;

function AppendToFile(const Path, Data: AnsiString): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  try
    EnsureDir(ExtractFileDir(Path));
    if FileExists(Path) then
      F := TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite)
    else
      F := TFileStream.Create(Path, fmCreate);
    try
      F.Seek(0, soEnd);
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

function CopyFileDurable(const Src, Dst: AnsiString): Boolean;
var
  FIn, FOut: TFileStream;
  Tmp: AnsiString;
begin
  Result := False;
  Tmp := Dst + '.tmp';
  try
    EnsureDir(ExtractFileDir(Dst));
    FIn := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      FOut := TFileStream.Create(Tmp, fmCreate);
      try
        if FIn.Size > 0 then
          FOut.CopyFrom(FIn, FIn.Size);
        SyncHandle(FOut.Handle);
      finally
        FOut.Free;
      end;
    finally
      FIn.Free;
    end;
    Result := ReplaceFile(Tmp, Dst);
  except
    Result := False;
  end;
  if not Result then
    SysUtils.DeleteFile(Tmp);
end;

function ListFiles(const Dir, Mask: AnsiString): TStringList;
var
  SR: TSearchRec;
begin
  Result := TStringList.Create;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(Dir) + Mask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then
        Result.Add(SR.Name);
    until SysUtils.FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
  Result.Sort;
end;

end.
