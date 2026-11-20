[Setup]
AppName=iPhone Webcam PC
AppVersion=1.0
DefaultDirName={autopf}\iPhoneWebcam
DefaultGroupName=iPhone Webcam PC
OutputDir=C:\iPhoneWebcam_Zestaw
OutputBaseFilename=iPhoneWebcam_Full_Setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ShowLanguageDialog=yes
SetupIconFile=C:\iPhoneWebcam_Zestaw\camera.ico
UninstallDisplayIcon={app}\iPhoneWebcam.exe

[Languages]
Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
polish.GroupShortcuts=Skróty:
polish.GroupComponents=Wymagane środowisko i sterowniki:
polish.TaskDesktop=Utwórz skrót na pulpicie
polish.TaskOBS=Zainstaluj OBS Studio i automatycznie zarejestruj OBS Virtual Camera
polish.TaskPython=Zainstaluj Python 3.12 oraz biblioteki (av, pyvirtualcam, numpy)
polish.TaskiTunes=Zainstaluj Apple iTunes (sterowniki połączenia USB z iPhone)
polish.TaskSideloadly=Zainstaluj Sideloadly (narzędzie do wgrywania aplikacji IPA)
polish.StatusOBS=Krok 1/5: Pobieranie i instalowanie OBS Studio...
polish.StatusRegOBS=Krok 2/5: Rejestrowanie sterownika OBS Virtual Camera w systemie...
polish.StatusPython=Krok 3/5: Instalowanie Pythona 3.12...
polish.StatusPip=Krok 3/5: Instalowanie bibliotek Pythona (av, pyvirtualcam, numpy)...
polish.StatusiTunes=Krok 4/5: Pobieranie i instalowanie sterowników USB Apple iTunes...
polish.StatusSideloadly=Krok 5/5: Pobieranie i instalowanie Sideloadly...
polish.IconFolder=Folder z plikami (IPA i skrypt Python)
polish.IconReadme=Instrukcja obsługi
polish.RunReadme=Otwórz instrukcję obsługi
polish.RunApp=Uruchom iPhone Webcam PC

english.GroupShortcuts=Shortcuts:
english.GroupComponents=Required environment and drivers:
english.TaskDesktop=Create a desktop shortcut
english.TaskOBS=Install OBS Studio and automatically register OBS Virtual Camera
english.TaskPython=Install Python 3.12 and libraries (av, pyvirtualcam, numpy)
english.TaskiTunes=Install Apple iTunes (iPhone USB connection drivers)
english.TaskSideloadly=Install Sideloadly (tool to sideload IPA app to iPhone)
english.StatusOBS=Step 1/5: Downloading and installing OBS Studio...
english.StatusRegOBS=Step 2/5: Registering OBS Virtual Camera driver in Windows...
english.StatusPython=Step 3/5: Installing Python 3.12...
english.StatusPip=Step 3/5: Installing Python libraries (av, pyvirtualcam, numpy)...
english.StatusiTunes=Step 4/5: Downloading and installing Apple iTunes USB drivers...
english.StatusSideloadly=Step 5/5: Downloading and installing Sideloadly...
english.IconFolder=Application Folder (IPA & Python source)
english.IconReadme=User Manual
english.RunReadme=Open User Manual
english.RunApp=Launch iPhone Webcam PC

[Tasks]
Name: "desktopicon"; Description: "{cm:TaskDesktop}"; GroupDescription: "{cm:GroupShortcuts}"
Name: "install_obs"; Description: "{cm:TaskOBS}"; GroupDescription: "{cm:GroupComponents}"
Name: "install_python"; Description: "{cm:TaskPython}"; GroupDescription: "{cm:GroupComponents}"
Name: "install_itunes"; Description: "{cm:TaskiTunes}"; GroupDescription: "{cm:GroupComponents}"
Name: "install_sideloadly"; Description: "{cm:TaskSideloadly}"; GroupDescription: "{cm:GroupComponents}"

[Files]
Source: "C:\iPhoneWebcam_Zestaw\iPhoneWebcam.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\iPhoneWebcam_Zestaw\receiver.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\iPhoneWebcam_Zestaw\iPhoneWebcam.ipa"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\iPhoneWebcam_Zestaw\README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\iPhone Webcam PC"; Filename: "{app}\iPhoneWebcam.exe"
Name: "{group}\{cm:IconFolder}"; Filename: "{app}"
Name: "{group}\{cm:IconReadme}"; Filename: "{app}\README.txt"
Name: "{autodesktop}\iPhone Webcam PC"; Filename: "{app}\iPhoneWebcam.exe"; Tasks: desktopicon

[Run]
Filename: "winget"; Parameters: "install -e --id OBSProject.OBSStudio --accept-package-agreements --accept-source-agreements"; StatusMsg: "{cm:StatusOBS}"; Tasks: install_obs; Flags: waituntilterminated
Filename: "regsvr32.exe"; Parameters: "/s ""{commonpf64}\obs-studio\bin\64bit\obs-virtualcam-module64.dll"""; StatusMsg: "{cm:StatusRegOBS}"; Tasks: install_obs; Flags: waituntilterminated
Filename: "winget"; Parameters: "install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements"; StatusMsg: "{cm:StatusPython}"; Tasks: install_python; Flags: waituntilterminated
Filename: "py"; Parameters: "-3.12 -m pip install av pyvirtualcam numpy"; StatusMsg: "{cm:StatusPip}"; Tasks: install_python; Flags: waituntilterminated
Filename: "winget"; Parameters: "install -e --id Apple.iTunes --accept-package-agreements --accept-source-agreements"; StatusMsg: "{cm:StatusiTunes}"; Tasks: install_itunes; Flags: waituntilterminated
Filename: "winget"; Parameters: "install -e --id Sideloadly.Sideloadly --accept-package-agreements --accept-source-agreements"; StatusMsg: "{cm:StatusSideloadly}"; Tasks: install_sideloadly; Flags: waituntilterminated
Filename: "{app}\README.txt"; Description: "{cm:RunReadme}"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\iPhoneWebcam.exe"; Description: "{cm:RunApp}"; Flags: nowait postinstall skipifsilent unchecked
