; QuestPact Sync installer (Inno Setup 6). Built by build.py, which passes AppVersion and AppIcon.
;
; Per-user install, no admin prompt. Besides the app it can:
;   - install/update the QuestPact addon into the WoW Forever folder (never overwriting PartnerData.lua)
;   - pre-fill the app's settings with the WoW and shared folders chosen here
;   - add the start-at-login entry the app's own checkbox uses
;
; Unattended:  QuestPact-Sync-Setup.exe /SILENT /WOWDIR="D:\WoW\_forever_" /SHAREDDIR="G:\My Drive\QuestPact"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppIcon
  #define AppIcon "..\build\questpact.ico"
#endif
#define AppName "QuestPact Sync"
#define AppExe "QuestPact Sync.exe"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"

[Setup]
AppId={{DED2EB0B-643D-4CDE-BDBA-EAB113F7EAD8}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Yva
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=QuestPact-Sync-Setup-{#AppVersion}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=force
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startup"; Description: "Start QuestPact Sync when I log in to Windows"; GroupDescription: "Background sync:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
; The addon lives in the game folder and keeps working without this app, so uninstall leaves it alone
Source: "..\..\addon\QuestPact\*"; Excludes: "PartnerData.lua"; DestDir: "{code:AddonDir}"; Flags: ignoreversion recursesubdirs uninsneveruninstall; Check: InstallAddon
; Placeholder only: the sync app owns this file once it has run, so never overwrite it
Source: "..\..\addon\QuestPact\PartnerData.lua"; DestDir: "{code:AddonDir}"; Flags: onlyifdoesntexist uninsneveruninstall; Check: InstallAddon

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Same value name the app's "Start when I log in" checkbox reads and writes
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExe}"" --minimized"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "Open {#AppName} now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM ""{#AppExe}"" /F"; Flags: runhidden; RunOnceId: "StopApp"

[Code]
var
  WowPage, SharedPage: TInputDirWizardPage;
  AddonCheck: TNewCheckBox;

function DetectWowDir(): String;
var
  Candidates: array of String;
  I: Integer;
begin
  Result := '';
  SetArrayLength(Candidates, 6);
  Candidates[0] := ExpandConstant('{commonpf32}') + '\World of Warcraft\_forever_';
  Candidates[1] := ExpandConstant('{commonpf64}') + '\World of Warcraft\_forever_';
  Candidates[2] := 'D:\World of Warcraft\_forever_';
  Candidates[3] := 'D:\Games\World of Warcraft\_forever_';
  Candidates[4] := 'E:\World of Warcraft\_forever_';
  Candidates[5] := ExpandConstant('{commonpf32}') + '\World of Warcraft\_classic_beta_';
  for I := 0 to GetArrayLength(Candidates) - 1 do
    if DirExists(Candidates[I] + '\WTF') then
    begin
      Result := Candidates[I];
      Exit;
    end;
end;

function DetectSharedDir(): String;
begin
  Result := '';
  if DirExists('G:\My Drive') then
    Result := 'G:\My Drive\QuestPact'
  else if DirExists(ExpandConstant('{%USERPROFILE}') + '\OneDrive') then
    Result := ExpandConstant('{%USERPROFILE}') + '\OneDrive\QuestPact';
end;

procedure InitializeWizard();
begin
  WowPage := CreateInputDirPage(wpSelectTasks,
    'World of Warcraft: Forever',
    'Where is WoW Forever installed?',
    'Select the _forever_ folder inside your World of Warcraft install (it contains the WTF and Interface folders).',
    False, '');
  WowPage.Add('');
  WowPage.Values[0] := ExpandConstant('{param:WOWDIR|' + DetectWowDir() + '}');

  AddonCheck := TNewCheckBox.Create(WowPage);
  AddonCheck.Parent := WowPage.Surface;
  AddonCheck.Top := WowPage.Edits[0].Top + WowPage.Edits[0].Height + ScaleY(16);
  AddonCheck.Width := WowPage.SurfaceWidth;
  AddonCheck.Height := ScaleY(17);
  AddonCheck.Caption := 'Install or update the QuestPact addon in this folder';
  AddonCheck.Checked := True;

  SharedPage := CreateInputDirPage(WowPage.ID,
    'Shared quest folder',
    'Where should quest progress be shared?',
    'Choose a folder both PCs can reach: a shared Google Drive, OneDrive or Dropbox folder, or a network share. ' +
    'Both of you should pick the same shared folder. You can change this later in the app.',
    False, 'QuestPact');
  SharedPage.Add('');
  SharedPage.Values[0] := ExpandConstant('{param:SHAREDDIR|' + DetectSharedDir() + '}');
end;

function InstallAddon(): Boolean;
begin
  Result := AddonCheck.Checked and (Trim(WowPage.Values[0]) <> '');
end;

function AddonDir(Param: String): String;
begin
  Result := AddBackslash(Trim(WowPage.Values[0])) + 'Interface\AddOns\QuestPact';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Dir: String;
begin
  Result := True;
  if (CurPageID = WowPage.ID) and AddonCheck.Checked then
  begin
    Dir := Trim(WowPage.Values[0]);
    if not DirExists(AddBackslash(Dir) + 'WTF') then
      Result := WizardSilent() or (MsgBox(
        'There is no WTF folder in:' + #13#10 + Dir + #13#10#13#10 +
        'This usually means it is not the _forever_ folder. Install the addon here anyway?',
        mbConfirmation, MB_YESNO) = IDYES);
  end;
end;

// Stop a running copy before files are replaced (it is a single exe, so this is quick and safe)
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM "{#AppExe}" /F', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

function JsonString(S: String): String;
begin
  StringChangeEx(S, '\', '\\', True);
  StringChangeEx(S, '"', '\"', True);
  Result := '"' + S + '"';
end;

// Pre-fill the app's settings on first install; an existing config is left untouched
procedure WriteAppConfig();
var
  ConfigDir, ConfigFile, Shared: String;
begin
  ConfigDir := ExpandConstant('{userappdata}\QuestPact');
  ConfigFile := ConfigDir + '\config.json';
  if FileExists(ConfigFile) then
    Exit;
  Shared := Trim(SharedPage.Values[0]);
  if Shared <> '' then
    ForceDirectories(Shared);
  ForceDirectories(ConfigDir);
  SaveStringToFile(ConfigFile,
    '{' + #13#10 +
    '  "wow_dir": ' + JsonString(Trim(WowPage.Values[0])) + ',' + #13#10 +
    '  "shared_dir": ' + JsonString(Shared) + ',' + #13#10 +
    '  "machine_name": ' + JsonString(GetComputerNameString()) + ',' + #13#10 +
    '  "poll_seconds": 10' + #13#10 +
    '}' + #13#10, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WriteAppConfig();
end;

// The app's own checkbox can create the startup entry too, so always clear it on uninstall
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, '{#RunKey}', '{#AppName}');
end;
