<#
.SYNOPSIS
Installs the Custode Chrome/Edge native messaging host for the current Windows user.

.PARAMETER Browser
Browser to register. Supported values: Chrome, Edge. Default: Chrome.

.PARAMETER ExtensionId
Extension ID copied from chrome://extensions or edge://extensions. Defaults to
the published Custode Chrome extension ID.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidatePattern('^[a-p]{32}$')]
    [string]$ExtensionId = 'ogjmlkogmogijgpflnjifiobdmnmommh',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Chrome', 'Edge')]
    [string]$Browser = 'Chrome'
)

$ErrorActionPreference = 'Stop'

$HostName = 'dev.camillobucciarelli.keyvault_native_host'
$NativeHostExeName = 'keyvault_native_host.exe'
$BrowserRegistryRoot = if ($Browser -eq 'Edge') { 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts' } else { 'HKCU:\Software\Google\Chrome\NativeMessagingHosts' }
$BrowserTemplateDir = if ($Browser -eq 'Edge') { 'edge' } else { 'chrome' }
$RegistryPath = Join-Path $BrowserRegistryRoot $HostName

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[Custode native host] $Message"
}

try {
    if ($ExtensionId -cnotmatch '^[a-p]{32}$') {
        throw "Invalid extension ID '$ExtensionId'. Expected 32 lowercase characters from a to p."
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is not set. Run this script from a normal Windows user session.'
    }
    if (-not [System.IO.Path]::IsPathRooted($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA must be an absolute path.'
    }

    $InstallDir = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KeyVault\NativeMessagingHosts'))
    $ManifestPath = Join-Path $InstallDir "$HostName.json"
    $LauncherPath = Join-Path $InstallDir 'keyvault_native_host.cmd'
    $LauncherScriptPath = Join-Path $InstallDir 'keyvault_native_host.ps1'
    $InstalledNativeHostExe = Join-Path $InstallDir $NativeHostExeName

    $ScriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        $ScriptPath = $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'Unable to determine script path.'
    }

    $ScriptDir = Split-Path -Parent $ScriptPath
    $TemplatePath = Join-Path $ScriptDir "manifests\$BrowserTemplateDir\$HostName.json"
    if ($Browser -eq 'Edge' -and -not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        # Chrome and Edge use the same manifest schema. Release bundles only need
        # the Chrome template because the production UI registers Chrome only.
        $TemplatePath = Join-Path $ScriptDir "manifests\chrome\$HostName.json"
    }
    $PackagedNativeHostExe = Join-Path $ScriptDir $NativeHostExeName

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "$Browser manifest template not found: $TemplatePath"
    }

    Write-Step "Installing for $Browser extension ID: $ExtensionId"
    Write-Step "Creating install directory: $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $HostPath = $null
    if (Test-Path -LiteralPath $PackagedNativeHostExe -PathType Leaf) {
        if ((Get-Item -LiteralPath $PackagedNativeHostExe).Length -le 0) {
            throw "Compiled native host is empty: $PackagedNativeHostExe"
        }

        $SourceExeFullPath = [System.IO.Path]::GetFullPath($PackagedNativeHostExe)
        $InstalledExeFullPath = [System.IO.Path]::GetFullPath($InstalledNativeHostExe)
        if ([StringComparer]::OrdinalIgnoreCase.Equals($SourceExeFullPath, $InstalledExeFullPath)) {
            Write-Step "Compiled native host already in install directory: $InstalledNativeHostExe"
        }
        else {
            Copy-Item -LiteralPath $PackagedNativeHostExe -Destination $InstalledNativeHostExe -Force
            Write-Step "Copied compiled native host: $InstalledNativeHostExe"
        }
        $HostPath = $InstalledNativeHostExe
    }
    else {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..'))
        $NativeHostDart = Join-Path $RepoRoot 'tool\native_host.dart'
        $PubspecPath = Join-Path $RepoRoot 'pubspec.yaml'
        if (-not (Test-Path -LiteralPath $PubspecPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $NativeHostDart -PathType Leaf)) {
            throw "Compiled native host not found: $PackagedNativeHostExe. Dart/FVM fallback is available only from the source tree."
        }

        Write-Step 'No compiled native host found in source tree; installing Dart/FVM development launcher.'

        $EscapedNativeHostDart = $NativeHostDart.Replace("'", "''")
        $EscapedRepoRoot = $RepoRoot.Replace("'", "''")
        $LauncherScriptContent = @'
$ErrorActionPreference = 'Stop'

function Write-LauncherError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("[Custode native host] $Message")
}

try {
    $NativeHostDart = '__NATIVE_HOST_DART__'
    $RepoRoot = '__REPO_ROOT__'

    function Start-DartHostIfPresent {
        param([string]$DartExe)
        if ([string]::IsNullOrWhiteSpace($DartExe)) {
            return
        }
        if (-not (Test-Path -LiteralPath $DartExe -PathType Leaf)) {
            return
        }

        & $DartExe $NativeHostDart
        exit $LASTEXITCODE
    }

    if (-not (Test-Path -LiteralPath $NativeHostDart -PathType Leaf)) {
        Write-LauncherError "Dart native host entry point not found: $NativeHostDart"
        exit 127
    }

    if (Test-Path -LiteralPath $RepoRoot -PathType Container) {
        Set-Location -LiteralPath $RepoRoot
    }

    # Development fallback. Keep stdout pristine for Native Messaging frames.
    Start-DartHostIfPresent (Join-Path $RepoRoot '.fvm\flutter_sdk\bin\dart.exe')

    $DartFromPath = Get-Command 'dart.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $DartFromPath) {
        Start-DartHostIfPresent $DartFromPath.Source
    }

    $FvmFromPath = Get-Command 'fvm' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $FvmFromPath) {
        $FvmWorks = $false
        try {
            & $FvmFromPath.Source dart --version *> $null
            $FvmWorks = ($LASTEXITCODE -eq 0)
        }
        catch {
            $FvmWorks = $false
        }
        if ($FvmWorks) {
            & $FvmFromPath.Source dart $NativeHostDart
            exit $LASTEXITCODE
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Start-DartHostIfPresent (Join-Path $env:USERPROFILE 'fvm\versions\stable\bin\dart.exe')
        Start-DartHostIfPresent (Join-Path $env:USERPROFILE '.fvm\versions\stable\bin\dart.exe')
    }

    Write-LauncherError 'Dart runtime not found. Build the native host with tool\build_native_host.sh or install Dart/Flutter/FVM.'
    exit 127
}
catch {
    Write-LauncherError "launcher_error $($_.Exception.Message)"
    exit 127
}
'@
        $LauncherScriptContent = $LauncherScriptContent.Replace('__NATIVE_HOST_DART__', $EscapedNativeHostDart)
        $LauncherScriptContent = $LauncherScriptContent.Replace('__REPO_ROOT__', $EscapedRepoRoot)
        $Utf8WithBom = New-Object System.Text.UTF8Encoding -ArgumentList $true
        [System.IO.File]::WriteAllText($LauncherScriptPath, $LauncherScriptContent, $Utf8WithBom)

        $LauncherContent = @"
@echo off
setlocal
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0keyvault_native_host.ps1"
exit /b %ERRORLEVEL%
"@
        Set-Content -LiteralPath $LauncherPath -Value $LauncherContent -Encoding ASCII -Force
        Write-Step "Wrote launcher: $LauncherPath"
        Write-Step "Wrote launcher script: $LauncherScriptPath"
        $HostPath = $LauncherPath
    }

    $AllowedOrigin = "chrome-extension://$ExtensionId/"
    $AllowedOriginUri = [System.Uri]$AllowedOrigin
    if (-not $AllowedOriginUri.IsAbsoluteUri -or
        $AllowedOriginUri.Scheme -cne 'chrome-extension' -or
        $AllowedOriginUri.Host -cne $ExtensionId -or
        $AllowedOriginUri.AbsolutePath -cne '/') {
        throw 'Generated allowed origin failed validation.'
    }

    $ManifestObject = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ManifestObject.name -cne $HostName -or $ManifestObject.type -cne 'stdio') {
        throw 'Manifest template has an unexpected name or type.'
    }
    $ManifestObject.path = $HostPath
    $ManifestObject.allowed_origins = @($AllowedOrigin)
    $Manifest = $ManifestObject | ConvertTo-Json -Depth 8
    $ManifestCheck = $Manifest | ConvertFrom-Json
    $CheckedAllowedOrigins = @($ManifestCheck.allowed_origins)
    if ($ManifestCheck.name -cne $HostName -or
        $ManifestCheck.type -cne 'stdio' -or
        $ManifestCheck.path -cne $HostPath -or
        $CheckedAllowedOrigins.Count -ne 1 -or
        $CheckedAllowedOrigins[0] -cne $AllowedOrigin) {
        throw 'Generated manifest failed path or allowed_origins validation.'
    }
    $Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ManifestPath, $Manifest, $Utf8NoBom)
    Write-Step "Wrote manifest: $ManifestPath"

    New-Item -Path $RegistryPath -Force | Out-Null
    Set-Item -Path $RegistryPath -Value $ManifestPath
    Write-Step "Registered HKCU $Browser native messaging host: $RegistryPath"

    Write-Host ''
    Write-Host "Custode $Browser native messaging host installed successfully."
    Write-Host "Manifest: $ManifestPath"
    Write-Host "Host: $HostPath"
    Write-Host "Restart $Browser before testing the extension."
}
catch {
    Write-Error "Failed to install Custode $Browser native messaging host. $($_.Exception.Message)"
    exit 1
}
