; Installateur Windows de Nothing Notes (Inno Setup 6, gratuit).
; Compilé automatiquement par GitHub Actions : voir .github/workflows/build.yml
;   iscc /DAppVersion=1.0.0 /DSourceDir=..\app\build\windows\x64\runner\Release installer\NothingNotes.iss
;
; - installation par utilisateur, sans droits administrateur ;
; - mise à jour : relancer simplement un installateur plus récent (même AppId) ;
; - désinstallation propre (menu Démarrer, Paramètres Windows > Applications),
;   avec le choix de conserver ou d'effacer les notes stockées sur ce PC.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\app\build\windows\x64\runner\Release"
#endif

#define AppName "Nothing Notes"
#define AppExe "NothingNotes.exe"
#define AppPublisher "Nothing Notes (logiciel libre)"
#define AppUrl "https://github.com/nabeiroriviereadriano-design/nothing-notes"

[Setup]
AppId={{31A48B5D-5FA8-463F-A099-EA73F26F88D7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={localappdata}\Programs\Nothing Notes
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=NothingNotes-Setup-{#AppVersion}
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Désinstaller {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// À la désinstallation : proposer d'effacer aussi les notes stockées sur ce PC.
// Les notes synchronisées restent disponibles sur le compte (serveur).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{userappdata}\NothingNotes');
    if DirExists(DataDir) then
    begin
      if UninstallSilent then
        exit;
      if MsgBox('Supprimer aussi les notes et réglages enregistrés sur ce PC ?' + #13#10 + #13#10 +
                'Les notes déjà synchronisées restent disponibles sur votre compte.' + #13#10 +
                'Choisissez « Non » pour les conserver (utile pour une réinstallation).',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(DataDir, True, True, True);
      end;
    end;
  end;
end;
