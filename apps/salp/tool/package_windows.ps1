# Build an installer from the same verified portable bundle, then install,
# launch and uninstall it in an isolated directory on the Windows runner.
[CmdletBinding()]
param([string]$WorkRoot = (Join-Path $PSScriptRoot '../../../.ci/native'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$Compiler = "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe"
if (!(Test-Path $Compiler)) { throw 'Inno Setup 6 is required' }
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Version = ((Select-String -Path "$AppRoot/pubspec.yaml" -Pattern '^version: (.+)').Matches.Groups[1].Value -split '\+')[0]
& $Compiler "/DSourceDir=$WorkRoot/salp-windows-x64" "/DOutputDir=$WorkRoot" "/DAppVersion=$Version" "$AppRoot/packaging/windows/salp.iss"
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed' }
$Installer = "$WorkRoot/salp-windows-x64-nightly-setup.exe"
$Destination = Join-Path $env:RUNNER_TEMP ('salp-install-' + [guid]::NewGuid())
$Install = Start-Process -FilePath $Installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$Destination`"") -Wait -PassThru
if ($Install.ExitCode -ne 0) { throw "Installer failed: $($Install.ExitCode)" }
try {
    & python "$PSScriptRoot/verify_windows.py" $Destination
    if ($LASTEXITCODE -ne 0) { throw 'Installed application failed verification' }
} finally {
    $Uninstall = Start-Process -FilePath "$Destination/unins000.exe" -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    if ($Uninstall.ExitCode -ne 0) { throw "Uninstaller failed: $($Uninstall.ExitCode)" }
}
if (Test-Path "$Destination/salp.exe") { throw 'Uninstaller left the application executable behind' }
Get-FileHash $Installer -Algorithm SHA256 | Format-List
