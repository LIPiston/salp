# Windows x64 only; dependencies and build output remain project-local.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VcpkgRoot,
    [string]$WorkRoot = (Join-Path $PSScriptRoot '../../../.ci/native')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)" }
}
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$VcpkgRoot = (Resolve-Path $VcpkgRoot).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$Install = Join-Path $WorkRoot 'install'
$Packages = Join-Path $WorkRoot 'vcpkg_installed'
$Triplet = 'x64-windows-release'
$Manifest = Join-Path $AppRoot 'native/windows'
New-Item -ItemType Directory -Force $WorkRoot, $Install | Out-Null
$Revision = (& git -C $VcpkgRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $Revision -ne '7281d8d64321f945f296e696d8561f68c8186c67') {
    throw 'vcpkg checkout does not match native/windows/vcpkg.json baseline'
}
Invoke-Checked (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') @('-disableMetrics')
Invoke-Checked (Join-Path $VcpkgRoot 'vcpkg.exe') @(
    'install', "--x-manifest-root=$Manifest", "--x-install-root=$Packages",
    "--triplet=$Triplet", "--overlay-triplets=$Manifest/triplets",
    '--clean-after-build', '--disable-metrics'
)
$Prefix = Join-Path $Packages $Triplet
Invoke-Checked 'cmake' @(
    '-S', "$AppRoot/native", '-B', "$WorkRoot/bridge", '-A', 'x64',
    "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot/scripts/buildsystems/vcpkg.cmake",
    '-DVCPKG_MANIFEST_MODE=OFF', "-DVCPKG_TARGET_TRIPLET=$Triplet",
    "-DVCPKG_OVERLAY_TRIPLETS=$Manifest/triplets",
    "-DVCPKG_INSTALLED_DIR=$Packages", "-DFreeRDP_DIR=$Prefix/share/freerdp",
    "-DWinPR_DIR=$Prefix/share/winpr3", "-DCMAKE_INSTALL_PREFIX=$Install"
)
Invoke-Checked 'cmake' @('--build', "$WorkRoot/bridge", '--config', 'Release', '--parallel', '2')
Invoke-Checked 'cmake' @('--install', "$WorkRoot/bridge", '--config', 'Release')
Copy-Item "$Prefix/bin/*.dll" "$Install/bin" -Force
Get-ChildItem "$Prefix/share" -Directory | ForEach-Object {
    $Copyright = Join-Path $_.FullName 'copyright'
    if (Test-Path $Copyright) {
        $Destination = Join-Path "$Install/licenses" $_.Name
        New-Item -ItemType Directory -Force $Destination | Out-Null
        Copy-Item $Copyright $Destination -Force
    }
}
# App-local VC runtime: a portable archive must not require Visual Studio.
$VsWhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$VsRoot = (& $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (!$VsRoot) { throw 'Visual Studio C++ toolchain not found' }
$Runtime = Get-ChildItem "$VsRoot/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT" -Directory |
    Sort-Object FullName -Descending | Select-Object -First 1
if (!$Runtime) { throw 'App-local MSVC runtime not found' }
Copy-Item "$($Runtime.FullName)/*.dll" "$Install/bin" -Force
$env:SALP_WINDOWS_DEPS = $Install
$env:PATH = "$Install/bin;$env:PATH"
Push-Location $AppRoot
try {
    Invoke-Checked 'flutter' @('pub', 'get', '--enforce-lockfile')
    Invoke-Checked 'flutter' @('analyze', '--no-pub')
    Invoke-Checked 'flutter' @('test', '--no-pub', '--reporter', 'expanded')
    $PreviousDataDir = $env:SALP_DATA_DIR
    $env:SALP_DATA_DIR = Join-Path $WorkRoot ('test-vault-' + [guid]::NewGuid())
    try {
        Invoke-Checked 'flutter' @('test', '-d', 'windows', 'integration_test/windows_flow_test.dart')
    } finally {
        $env:SALP_DATA_DIR = $PreviousDataDir
    }
    # Re-resolve plugins for the production entry after integration_test.
    Invoke-Checked 'flutter' @('build', 'windows', '--release')
} finally { Pop-Location }
$Bundle = "$AppRoot/build/windows/x64/runner/Release"
$Portable = "$WorkRoot/salp-windows-x64"
if (Test-Path $Portable) { Remove-Item $Portable -Recurse -Force }
Copy-Item $Bundle $Portable -Recurse
Get-ChildItem $Portable -File | Where-Object { $_.Extension -in '.pdb', '.lib', '.exp' } | Remove-Item
Copy-Item "$Install/licenses", "$Install/sources" $Portable -Recurse
Copy-Item "$AppRoot/THIRD-PARTY.md", "$AppRoot/../../LICENSE" $Portable
# Preserve exact source and patches for this development build, including GPL app.
Invoke-Checked 'git' @('-C', "$AppRoot/../..", 'archive', '--format=zip', "--output=$Portable/sources/salp.zip", 'HEAD', 'apps/salp', 'LICENSE', '.github/workflows/windows.yml')
@{
    captured_at = [DateTime]::UtcNow.ToString('o')
    commit = (& git -C $AppRoot rev-parse HEAD).Trim()
    flutter = (& flutter --version --machine | ConvertFrom-Json)
    vcpkg = $Revision
    packages = (Get-Content "$Packages/vcpkg/status" -Raw)
    native_install_bytes = (Get-ChildItem $Install -File -Recurse | Measure-Object Length -Sum).Sum
    bundle_bytes = (Get-ChildItem $Portable -File -Recurse | Measure-Object Length -Sum).Sum
} | ConvertTo-Json -Depth 8 | Set-Content "$Portable/build-info.json" -Encoding utf8
Invoke-Checked 'python' @("$PSScriptRoot/verify_windows.py", $Portable)
$Zip = "$WorkRoot/salp-windows-x64.zip"
Compress-Archive "$Portable/*" $Zip -Force
Get-FileHash $Zip -Algorithm SHA256 | Format-List
