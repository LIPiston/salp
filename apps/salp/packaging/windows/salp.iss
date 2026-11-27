#ifndef SourceDir
  #error SourceDir must point to the verified Windows portable bundle
#endif
#ifndef OutputDir
  #error OutputDir must point to the package output directory
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{8E1D0C49-6E9C-42D1-BBD1-64BA5E6352FB}
AppName=salp nightly
AppVersion={#AppVersion}
AppPublisher=LIPiston
AppPublisherURL=https://github.com/LIPiston/salp
DefaultDirName={localappdata}\Programs\salp
DefaultGroupName=salp
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#SourceDir}\LICENSE
UninstallDisplayIcon={app}\salp.exe
OutputDir={#OutputDir}
OutputBaseFilename=salp-windows-x64-nightly-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\salp nightly"; Filename: "{app}\salp.exe"
Name: "{autodesktop}\salp nightly"; Filename: "{app}\salp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\salp.exe"; Description: "Launch salp"; Flags: nowait postinstall skipifsilent
