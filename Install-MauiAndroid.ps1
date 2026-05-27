<#
.SYNOPSIS
    Automated setup for building .NET MAUI Android apps on Windows WITHOUT an IDE.

.DESCRIPTION
    This script automates the manual guide at:
        https://github.com/Alex-stewart1/maui-android-setup-guide

    It will, end to end and unattended:
        1.  Install the .NET 10 SDK (via winget, with a direct-download fallback).
        2.  Install the .NET MAUI templates + workloads.
        3.  Install Microsoft OpenJDK 21 (downloaded directly from Microsoft).
        4.  Download the Android command-line tools (from Google / developer.android.com).
        5.  Lay them out with the REQUIRED cmdline-tools\latest\ nesting fix.
        6.  Accept the Android SDK licenses.
        7.  Install the required Android SDK components (platform-tools, build-tools, etc.).
        8.  Set the JAVA_HOME, ANDROID_HOME and PATH machine environment variables.
        9.  Verify the whole toolchain and (optionally) build a throwaway MAUI project.

    ANDROID PLATFORM SELECTION
    --------------------------
    By default the script interactively prompts you to choose an Android API level
    from a numbered menu. You can also pass -AndroidApiLevel directly to skip the
    prompt (e.g. -AndroidApiLevel 35).  Pass -SkipAndroidPlatform to install only
    the core SDK tools (platform-tools, emulator) without any API platform -- in
    this mode the validation build is automatically skipped.

    PRE-FLIGHT CONFLICT CHECK
    -------------------------
    Before doing anything, the script scans the machine for *pre-existing* Android
    and Microsoft/Java (OpenJDK "hotspot") installs and environment variables.
    If it finds any, it STOPS and reports an error, then offers you a single choice:

        "Reinstall clean"  ->  Removes existing Android references (incl. the
                               ANDROID_HOME / ANDROID_SDK_ROOT env vars and Android
                               entries from PATH), uninstalls detected
                               Microsoft OpenJDK ("...hotspot") builds and clears
                               JAVA_HOME, and then installs everything fresh to the
                               exact versions/paths specified in the guide.

    Everything it downloads goes into a single temp working folder which is deleted
    automatically when the script finishes (success OR failure) -- it cleans up
    after itself.

.PARAMETER ReinstallClean
    Skip the interactive prompt and go straight into a clean reinstall. Useful for
    fully unattended runs. Equivalent to choosing "Reinstall clean" at the prompt.

.PARAMETER Force
    Suppress the final "are you sure" confirmation before destructive actions.

.PARAMETER AndroidApiLevel
    Android API level number to install (e.g. 35, 34, 33).  When supplied the
    interactive platform-selection menu is skipped.  Mutually exclusive with
    -SkipAndroidPlatform.

.PARAMETER SkipAndroidPlatform
    Do NOT install any Android platform/API level.  Only the core tooling
    (platform-tools, emulator, build-tools) is installed and the validation
    build step is skipped automatically.

.PARAMETER JdkMsiSource
    Override the source for the Microsoft OpenJDK MSI.
    Accepts EITHER a URL (https://...) OR a local file path (C:\Downloads\jdk.msi).
    When a local path is given the file is used directly -- no download occurs.
    Default: https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.msi

.PARAMETER CmdlineToolsSource
    Override the source for the Android command-line tools ZIP.
    Accepts EITHER a URL (https://...) OR a local file path (C:\Downloads\cmdline-tools.zip).
    When a local path is given the file is used directly -- no download occurs.
    Default: https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip

.NOTES
    OFFLINE / AIR-GAPPED INSTALLS
    ------------------------------
    To run this script on a machine with no internet access, pre-download the two
    installers on another machine and transfer them, then pass the local paths:

        .\Install-MauiAndroid.ps1 `
            -JdkMsiSource      "D:\Installers\microsoft-jdk-21-windows-x64.msi" `
            -CmdlineToolsSource "D:\Installers\commandlinetools-win-11076708_latest.zip"

    The script will copy/use the files in place rather than downloading them.
    (.NET 10 SDK still requires winget or an internet connection unless you
    pre-install it separately before running this script.)


    *** MUST BE RUN FROM AN ELEVATED (Administrator) PowerShell PROMPT. ***
    Setting MACHINE-level environment variables and installing into
    "C:\Program Files" both require admin rights.

    Author : Generated for Alex-stewart1/maui-android-setup-guide
    Target : Windows 10/11 x64, PowerShell 5.1+ or PowerShell 7+
#>

[CmdletBinding()]
param(
    [switch]$ReinstallClean,
    [switch]$Force,

    # Android platform selection (mutually exclusive).
    # 0 = "not specified; prompt the user interactively".
    [ValidateRange(0, 99)]
    [int]$AndroidApiLevel = 0,

    # Pass this switch to install only the core SDK tools with NO platform/API
    # level. The validation build step is automatically skipped in this mode.
    [switch]$SkipAndroidPlatform,

    # Source overrides for downloaded installers.
    # Each accepts either a URL (https://...) or a local file path (C:\path\to\file).
    # Leave empty to use the built-in default URLs.
    [string]$JdkMsiSource       = '',
    [string]$CmdlineToolsSource = ''
)

# Stop on the first unhandled error so we never half-configure the machine.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  CONFIGURATION  -- the exact versions / paths the guide specifies.
#  Change these in ONE place if the guide is ever updated.
# ---------------------------------------------------------------------------

# Apply source overrides (empty string = keep the built-in default URL).
$_DefaultJdkMsiSource       = 'https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.msi'
$_DefaultCmdlineToolsSource = 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'

$Config = [ordered]@{
    # Where the Android SDK lives. Near the drive root to dodge path-length limits.
    AndroidSdkRoot   = 'C:\Program Files (x86)\Android\android-sdk'

    # Expected install root for Microsoft OpenJDK 21 ("hotspot" build).
    JdkInstallRoot   = 'C:\Program Files\Microsoft\jdk-21-hotspot'

    # Android API level / build-tools -- resolved later after user prompt.
    # AndroidApiLevel and BuildToolsVer are populated in Resolve-AndroidPlatform.
    AndroidApiLevel  = ''
    BuildToolsVer    = ''

    # The MAUI target framework moniker we build against to prove the setup works.
    MauiTfm          = 'net10.0-android'

    # --- Installer sources ------------------------------------------------
    # Each may be a URL (https://...) or a local file path.
    # Overridable via -JdkMsiSource / -CmdlineToolsSource parameters.
    JdkMsiSource        = if ($JdkMsiSource)       { $JdkMsiSource }       else { $_DefaultJdkMsiSource }
    CmdlineToolsSource  = if ($CmdlineToolsSource) { $CmdlineToolsSource } else { $_DefaultCmdlineToolsSource }

    # .NET 10 SDK winget package id (preferred install path).
    DotNetWingetId   = 'Microsoft.DotNet.SDK.10'
}

# A single working directory for ALL downloads. Deleted on exit (see finally{}).
$WorkDir = Join-Path $env:TEMP ("maui-setup-" + [Guid]::NewGuid().ToString('N'))

# ===========================================================================
#  PRESENTATION HELPERS
#  These exist purely so the USER can clearly see, at every stage, exactly
#  what the script is about to do, is doing, and has done.
# ===========================================================================
function Write-Step    { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info    { param([string]$m) Write-Host "    $m"   -ForegroundColor Gray }
function Write-Ok      { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warnish { param([string]$m) Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Err     { param([string]$m) Write-Host "  [X]  $m" -ForegroundColor Red }

function Write-Banner {
    param([string]$Title)
    $line = '=' * 74
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ("  " + $Title) -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
}

# ===========================================================================
#  ANDROID PLATFORM CATALOGUE  (live -- queried from sdkmanager)
#
#  Calls "sdkmanager --list" against the already-installed cmdline-tools and
#  parses its output to discover every available platform and the best
#  matching build-tools version.  Returns an [ordered] hashtable keyed by
#  integer API level, highest first:
#
#      @{ 35 = @{ Label='Android 15 (API 35)'; BuildTools='35.0.0' }; ... }
#
#  This replaces the old hardcoded catalogue -- no manual updates needed when
#  Google ships a new API level.
# ===========================================================================
function Get-AndroidPlatformCatalogue {
    param([string]$JavaHome)

    Write-Step "Querying available Android platforms from sdkmanager..."

    $sdkManager = Join-Path $Config.AndroidSdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path $sdkManager)) {
        throw "sdkmanager not found at '$sdkManager'. Cannot query available platforms."
    }

    # sdkmanager needs JAVA_HOME in the environment to run at all.
    $env:JAVA_HOME    = $JavaHome
    $env:ANDROID_HOME = $Config.AndroidSdkRoot

    # Capture stdout; sdkmanager writes progress noise to stderr so we only
    # redirect stdout.  The "--list" flag does NOT require accepted licenses.
    Write-Info "Running: sdkmanager --list --sdk_root=`"$($Config.AndroidSdkRoot)`""
    $rawLines = & $sdkManager --list --sdk_root="$($Config.AndroidSdkRoot)" 2>$null

    if (-not $rawLines) {
        throw "sdkmanager --list produced no output. Check your network connection and that the JDK is working correctly."
    }

    # ---- Parse available platforms ----------------------------------------
    # We only want the "Available Packages" section (not "Installed Packages").
    # sdkmanager --list output looks like:
    #
    #   Available Packages:
    #     Path                              | Version | Description
    #     -------                           | ------- | -----------
    #     platforms;android-35              | 3       | Android SDK Platform 35
    #     build-tools;35.0.0               | 35.0.0  | Android SDK Build-Tools 35
    #     ...
    #
    # We collect ALL build-tools versions first, then match per API level.

    $inAvailable  = $false
    $platformApis = [System.Collections.Generic.List[int]]::new()
    $buildToolsVersions = [System.Collections.Generic.List[version]]::new()

    foreach ($line in $rawLines) {
        # Detect section headers.
        if ($line -match '(?i)available packages') { $inAvailable = $true;  continue }
        if ($line -match '(?i)installed packages') { $inAvailable = $false; continue }
        if ($line -match '(?i)installed updates')  { $inAvailable = $false; continue }

        if (-not $inAvailable) { continue }

        # Match "  platforms;android-NN  |  ..."
        if ($line -match '^\s+platforms;android-(\d+)\s*\|') {
            $api = [int]$Matches[1]
            if ($api -gt 0) { $platformApis.Add($api) }
            continue
        }

        # Match "  build-tools;X.Y.Z  |  ..."
        if ($line -match '^\s+build-tools;(\d+\.\d+\.\d+)\s*\|') {
            $ver = $null
            if ([version]::TryParse($Matches[1], [ref]$ver)) {
                $buildToolsVersions.Add($ver)
            }
        }
    }

    if ($platformApis.Count -eq 0) {
        throw "sdkmanager --list ran but no 'platforms;android-*' packages were found. " +
              "Check your internet connection -- sdkmanager needs to reach dl.google.com."
    }

    # Sort API levels highest first for the menu.
    $sortedApis = $platformApis | Sort-Object -Descending | Select-Object -Unique

    # For each API level, pick the highest available build-tools with the same
    # major version number (e.g. API 35 -> build-tools 35.x.x).  If no exact
    # major match exists, fall back to the overall highest available build-tools.
    $highestOverall = $buildToolsVersions | Sort-Object -Descending | Select-Object -First 1

    $catalogue = [ordered]@{}
    foreach ($api in $sortedApis) {
        $sameMajor = $buildToolsVersions |
                     Where-Object { $_.Major -eq $api } |
                     Sort-Object -Descending |
                     Select-Object -First 1

        $bt = if ($sameMajor) { $sameMajor } else { $highestOverall }
        $btStr = if ($bt) { $bt.ToString() } else { "$api.0.0" }

        $catalogue[$api] = [ordered]@{
            Label      = "API $api"   # enriched with Android name below
            BuildTools = $btStr
        }
    }

    # Enrich labels with known Android release names (purely cosmetic; the
    # catalogue remains fully functional for any unknown future API levels).
    $androidNames = @{
        36 = 'Android 16'
        35 = 'Android 15'
        34 = 'Android 14'
        33 = 'Android 13'
        32 = 'Android 12L'
        31 = 'Android 12'
        30 = 'Android 11'
        29 = 'Android 10'
        28 = 'Android 9 (Pie)'
        27 = 'Android 8.1 (Oreo)'
        26 = 'Android 8.0 (Oreo)'
    }
    foreach ($api in @($catalogue.Keys)) {
        $name = if ($androidNames.ContainsKey($api)) { $androidNames[$api] } else { "Android API $api" }
        $catalogue[$api].Label = "$name  (API $api)"
    }

    $highestApi = ($sortedApis | Select-Object -First 1)
    Write-Ok "Found $($catalogue.Count) available platform(s). Latest: API $highestApi."
    return $catalogue
}

# ===========================================================================
#  ANDROID PLATFORM SELECTION
#  Presents an interactive numbered menu when the user has not specified an
#  API level via -AndroidApiLevel or -SkipAndroidPlatform.
#  Receives the live catalogue from Get-AndroidPlatformCatalogue.
#  Populates $Config.AndroidApiLevel and $Config.BuildToolsVer.
# ===========================================================================
function Resolve-AndroidPlatform {
    param(
        # Ordered hashtable from Get-AndroidPlatformCatalogue.
        # Null/empty means -SkipAndroidPlatform was set -- skip everything.
        $Catalogue
    )

    # -SkipAndroidPlatform wins outright (Catalogue will be $null).
    if (-not $Catalogue -or $Catalogue.Count -eq 0) {
        Write-Step "Android platform: SKIPPED (-SkipAndroidPlatform specified)"
        Write-Warnish "No Android platform will be installed. The validation build step will be skipped."
        $Config.AndroidApiLevel = ''
        $Config.BuildToolsVer   = ''
        return
    }

    # -AndroidApiLevel supplied on the command line -- look it up in the live catalogue.
    if ($AndroidApiLevel -gt 0) {
        if ($Catalogue.Contains($AndroidApiLevel)) {
            $entry = $Catalogue[$AndroidApiLevel]
            Write-Step "Android platform: $($entry.Label)  build-tools $($entry.BuildTools)  (from -AndroidApiLevel parameter)"
            $Config.AndroidApiLevel = "android-$AndroidApiLevel"
            $Config.BuildToolsVer   = $entry.BuildTools
        } else {
            # Requested level not in the live list (e.g. very new or very old).
            # Trust the user and derive build-tools from the major version.
            Write-Warnish "API $AndroidApiLevel was not found in the sdkmanager package list."
            Write-Warnish "Proceeding anyway -- sdkmanager will error if the package truly does not exist."
            $Config.AndroidApiLevel = "android-$AndroidApiLevel"
            $Config.BuildToolsVer   = "$AndroidApiLevel.0.0"
        }
        return
    }

    # Interactive menu.
    Write-Banner "Android Platform Selection"
    Write-Host "  Available platforms (queried live from Google's SDK repository):" -ForegroundColor White
    Write-Host ""

    $keys = @($Catalogue.Keys)   # already sorted highest -> lowest

    for ($i = 0; $i -lt $keys.Count; $i++) {
        $api   = $keys[$i]
        $entry = $Catalogue[$api]
        # Mark the highest available API as recommended.
        $marker = if ($i -eq 0) { '  [latest]' } else { '' }
        Write-Host ("  [{0,2}]  {1}   (build-tools {2}){3}" -f ($i + 1), $entry.Label, $entry.BuildTools, $marker) -ForegroundColor White
    }
    Write-Host ""
    Write-Host ("  [{0,2}]  Skip -- do not install any Android platform" -f ($keys.Count + 1)) -ForegroundColor DarkGray
    Write-Host ""

    $maxChoice = $keys.Count + 1
    do {
        $raw = Read-Host "  Enter choice (1-$maxChoice)"
        $n   = 0
        $ok  = [int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $maxChoice
        if (-not $ok) { Write-Warnish "  Please enter a number between 1 and $maxChoice." }
    } while (-not $ok)

    if ($n -eq $maxChoice) {
        Write-Warnish "No Android platform selected. The validation build step will be skipped."
        $Config.AndroidApiLevel = ''
        $Config.BuildToolsVer   = ''
    } else {
        $api   = $keys[$n - 1]
        $entry = $Catalogue[$api]
        Write-Ok "Selected: $($entry.Label)  (build-tools $($entry.BuildTools))"
        $Config.AndroidApiLevel = "android-$api"
        $Config.BuildToolsVer   = $entry.BuildTools
    }
}

# ===========================================================================
#  ENVIRONMENT / GUARD HELPERS
# ===========================================================================

# Confirm we are running elevated. Almost everything below needs admin rights.
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Read a MACHINE-scoped environment variable directly from the registry-backed
# store (so we see the persisted value, not just this process's copy).
function Get-MachineEnv {
    param([string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, 'Machine')
}

# Set (or, with -Remove, delete) a MACHINE-scoped environment variable AND
# mirror it into the current process so later steps in THIS run see it too.
function Set-MachineEnv {
    param(
        [string]$Name,
        [string]$Value,
        [switch]$Remove
    )
    if ($Remove) {
        Write-Info "Removing machine environment variable '$Name'"
        [Environment]::SetEnvironmentVariable($Name, $null, 'Machine')
        Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Write-Info "Setting machine environment variable '$Name' = '$Value'"
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
        Set-Item "Env:$Name" $Value
    }
}

# Download a file with a visible progress indication and basic sanity check.
function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$OutFile
    )
    Write-Info "Downloading: $Url"
    Write-Info "        ->  $OutFile"
    # Use TLS 1.2 explicitly for older Windows PowerShell hosts.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $oldPref = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'   # huge speed-up for Invoke-WebRequest
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
    finally {
        $ProgressPreference = $oldPref
    }
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
        throw "Download failed or produced an empty file: $Url"
    }
    Write-Ok "Downloaded $([IO.Path]::GetFileName($OutFile)) ($([math]::Round((Get-Item $OutFile).Length/1MB,1)) MB)"
}

# ---------------------------------------------------------------------------
#  Resolve-FileSource
#  Accepts either a URL or a local filesystem path and ensures the file is
#  available at $DestPath inside the working directory.
#
#    URL   -> downloads to $DestPath (same as before)
#    Local -> validates the file exists and copies it to $DestPath so the
#             rest of the script always has a private working copy.
#
#  Returns the resolved local path (always == $DestPath).
# ---------------------------------------------------------------------------
function Resolve-FileSource {
    param(
        [string]$Source,    # URL or local path
        [string]$DestPath   # where to put the file inside $WorkDir
    )

    $isLocal = -not ($Source -match '(?i)^https?://')

    if ($isLocal) {
        # Normalise to an absolute path (handles relative paths like .\file.zip).
        $resolved = [IO.Path]::GetFullPath($Source)

        if (-not (Test-Path $resolved -PathType Leaf)) {
            throw "Local file not found: '$resolved'"
        }
        $sizeMb = [math]::Round((Get-Item $resolved).Length / 1MB, 1)
        Write-Info "Using local file : $resolved  ($sizeMb MB)"
        Write-Info "Copying       -> $DestPath"
        Copy-Item -Path $resolved -Destination $DestPath -Force
        Write-Ok  "Copied $([IO.Path]::GetFileName($DestPath)) from local path."
    }
    else {
        Get-RemoteFile -Url $Source -OutFile $DestPath
    }

    return $DestPath
}

# ===========================================================================
#  STEP 0 -- CONFLICT DETECTION
#  Scan for pre-existing Android + Microsoft/Java(hotspot) traces so we can
#  warn the user and offer a clean reinstall, exactly as requested.
# ===========================================================================
function Get-ExistingInstallReport {
    Write-Step "Scanning system for existing Android / Microsoft JDK installations..."

    $report = [ordered]@{
        AndroidEnvVars   = @()   # names of Android-related machine env vars found
        AndroidPaths     = @()   # PATH entries that reference Android
        AndroidFolders   = @()   # on-disk SDK folders found
        JavaHome         = $null # current JAVA_HOME value (if any)
        MicrosoftJdks    = @()   # detected Microsoft OpenJDK "hotspot" installs
        HasConflict      = $false
    }

    # ---- Android environment variables -----------------------------------
    foreach ($name in @('ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_NDK_HOME')) {
        $val = Get-MachineEnv $name
        if ($val) {
            $report.AndroidEnvVars += [pscustomobject]@{ Name = $name; Value = $val }
        }
    }

    # ---- Android references inside the machine PATH ----------------------
    $machinePath = (Get-MachineEnv 'Path')
    if ($machinePath) {
        foreach ($entry in ($machinePath -split ';' | Where-Object { $_ })) {
            if ($entry -match '(?i)android') { $report.AndroidPaths += $entry }
        }
    }

    # ---- Common on-disk Android SDK locations ----------------------------
    $candidateFolders = @(
        $Config.AndroidSdkRoot,
        "$env:LOCALAPPDATA\Android\Sdk",
        "C:\Android",
        "C:\Program Files\Android"
    ) | Select-Object -Unique
    foreach ($folder in $candidateFolders) {
        if (Test-Path $folder) { $report.AndroidFolders += $folder }
    }

    # ---- JAVA_HOME -------------------------------------------------------
    $report.JavaHome = Get-MachineEnv 'JAVA_HOME'

    # ---- Microsoft OpenJDK "...hotspot" installs -------------------------
    # Look both on disk and in the installed-programs registry, matching the
    # Microsoft build naming ("Microsoft" + "...hotspot").
    $msftJdkDir = 'C:\Program Files\Microsoft'
    if (Test-Path $msftJdkDir) {
        Get-ChildItem $msftJdkDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)jdk.*hotspot' } |
            ForEach-Object {
                $report.MicrosoftJdks += [pscustomobject]@{
                    Source = 'Folder'; Name = $_.Name; Path = $_.FullName; ProductCode = $null
                }
            }
    }
    # Registry uninstall keys (both 64- and 32-bit views).
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '(?i)microsoft.*(openjdk|jdk).*' -or $_.DisplayName -match '(?i)microsoft build of openjdk' } |
            ForEach-Object {
                $report.MicrosoftJdks += [pscustomobject]@{
                    Source      = 'Registry'
                    Name        = $_.DisplayName
                    Path        = $_.InstallLocation
                    ProductCode = $_.PSChildName   # the {GUID} used for msiexec /x
                }
            }
    }

    $report.HasConflict =
        ($report.AndroidEnvVars.Count -gt 0) -or
        ($report.AndroidPaths.Count   -gt 0) -or
        ($report.AndroidFolders.Count -gt 0) -or
        ($report.MicrosoftJdks.Count  -gt 0) -or
        ([bool]$report.JavaHome)

    return [pscustomobject]$report
}

# Pretty-print the conflict report so the user understands WHAT was found.
function Show-ConflictReport {
    param($Report)

    Write-Banner "EXISTING INSTALLATION DETECTED"
    Write-Err "The script found existing Android and/or Microsoft JDK artifacts."
    Write-Host ""

    if ($Report.AndroidEnvVars.Count) {
        Write-Warnish "Android environment variables:"
        $Report.AndroidEnvVars | ForEach-Object { Write-Host "        $($_.Name) = $($_.Value)" }
    }
    if ($Report.AndroidPaths.Count) {
        Write-Warnish "Android references inside PATH:"
        $Report.AndroidPaths | ForEach-Object { Write-Host "        $_" }
    }
    if ($Report.AndroidFolders.Count) {
        Write-Warnish "Android SDK folders on disk:"
        $Report.AndroidFolders | ForEach-Object { Write-Host "        $_" }
    }
    if ($Report.JavaHome) {
        Write-Warnish "JAVA_HOME is currently set to:"
        Write-Host "        $($Report.JavaHome)"
    }
    if ($Report.MicrosoftJdks.Count) {
        Write-Warnish "Microsoft OpenJDK (hotspot) installs:"
        $Report.MicrosoftJdks | ForEach-Object {
            Write-Host "        [$($_.Source)] $($_.Name)  $([string]$_.Path)"
        }
    }
    Write-Host ""
}

# ===========================================================================
#  CLEAN -- undo the things the conflict report found.
# ===========================================================================
function Invoke-CleanReinstallPurge {
    param($Report)

    Write-Banner "CLEAN: removing existing Android & Microsoft JDK artifacts"

    # 1) Remove Android-related machine environment variables -----------------
    foreach ($ev in $Report.AndroidEnvVars) {
        Set-MachineEnv -Name $ev.Name -Remove
    }

    # 2) Strip Android entries out of the machine PATH ------------------------
    $machinePath = Get-MachineEnv 'Path'
    if ($machinePath) {
        $kept = $machinePath -split ';' |
                Where-Object { $_ -and ($_ -notmatch '(?i)android') }
        $newPath = ($kept -join ';')
        Set-MachineEnv -Name 'Path' -Value $newPath
        Write-Ok "Removed Android references from PATH."
    }

    # 3) Uninstall detected Microsoft OpenJDK (hotspot) builds ----------------
    foreach ($jdk in ($Report.MicrosoftJdks | Where-Object { $_.Source -eq 'Registry' -and $_.ProductCode })) {
        Write-Info "Uninstalling '$($jdk.Name)' (msiexec /x $($jdk.ProductCode))"
        $p = Start-Process msiexec.exe -ArgumentList "/x $($jdk.ProductCode) /qn /norestart" -Wait -PassThru
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Ok "Uninstalled $($jdk.Name)."
        } else {
            Write-Warnish "msiexec returned exit code $($p.ExitCode) for $($jdk.Name) (continuing)."
        }
    }
    # Remove any leftover hotspot folders the uninstaller didn't clear.
    foreach ($jdk in ($Report.MicrosoftJdks | Where-Object { $_.Source -eq 'Folder' })) {
        if (Test-Path $jdk.Path) {
            Write-Info "Removing leftover folder $($jdk.Path)"
            Remove-Item $jdk.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 4) Clear JAVA_HOME ------------------------------------------------------
    if ($Report.JavaHome) {
        Set-MachineEnv -Name 'JAVA_HOME' -Remove
    }

    # 5) Remove the old Android SDK folder(s) on disk -------------------------
    foreach ($folder in $Report.AndroidFolders) {
        if (Test-Path $folder) {
            Write-Info "Removing Android SDK folder $folder"
            Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Ok "Clean complete. The machine is ready for a fresh install."
}

# ===========================================================================
#  INSTALL STEPS  (mirror the README, steps 1-10)
# ===========================================================================

# --- README Step 1: .NET 10 SDK -------------------------------------------
function Install-DotNet10 {
    Write-Step "[1/8] Installing the .NET 10 SDK"

    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $sdks = (& dotnet --list-sdks) 2>$null
        if ($sdks -match '^10\.') {
            Write-Ok ".NET 10 SDK already present."
            return
        }
    }

    # Preferred: winget (handles PATH + future updates cleanly).
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "Installing via winget ($($Config.DotNetWingetId))..."
        winget install --id $Config.DotNetWingetId --silent `
            --accept-package-agreements --accept-source-agreements
    }
    else {
        # Fallback: Microsoft's official dotnet-install.ps1 bootstrapper.
        Write-Warnish "winget not found -- using the official dotnet-install.ps1 fallback."
        $installer = Join-Path $WorkDir 'dotnet-install.ps1'
        Get-RemoteFile -Url 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
        & $installer -Channel 10.0 -InstallDir "$env:ProgramFiles\dotnet"
        $dotnetDir = "$env:ProgramFiles\dotnet"
        if (($env:Path -split ';') -notcontains $dotnetDir) {
            $env:Path = "$dotnetDir;$env:Path"
        }
    }
    Write-Ok ".NET 10 SDK installed."
}

# --- README Step 2: MAUI templates + workloads ----------------------------
function Install-MauiWorkload {
    Write-Step "[2/8] Installing .NET MAUI templates and workloads"
    Write-Info "dotnet new install Microsoft.Maui.Templates"
    & dotnet new install Microsoft.Maui.Templates 2>$null
    Write-Info "dotnet workload install maui"
    & dotnet workload install maui
    Write-Ok "MAUI workload installed."
}

# --- README Step 3: Microsoft OpenJDK 21 ----------------------------------
function Install-MicrosoftJdk21 {
    Write-Step "[3/8] Installing Microsoft OpenJDK 21 (hotspot)"

    if (Test-Path $Config.JdkInstallRoot) {
        Write-Ok "Microsoft OpenJDK already present at $($Config.JdkInstallRoot)."
        return
    }
    $msi = Join-Path $WorkDir 'microsoft-jdk-21.msi'
    Resolve-FileSource -Source $Config.JdkMsiSource -DestPath $msi | Out-Null

    Write-Info "Running the MSI silently (msiexec /i ... /qn)..."
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "Microsoft OpenJDK MSI failed with exit code $($p.ExitCode)."
    }
    Write-Ok "Microsoft OpenJDK 21 installed."
}

# Resolve the real JDK folder. We prefer the guide's exact path, but if the MSI
# laid down a patch-versioned "jdk-21.x.x-hotspot" folder (or a different major
# version if -JdkMsiSource was overridden) we locate it dynamically so JAVA_HOME
# is always correct.
function Resolve-JdkHome {
    if (Test-Path $Config.JdkInstallRoot) { return $Config.JdkInstallRoot }

    # Walk C:\Program Files\Microsoft and find ANY jdk-*-hotspot folder.
    $found = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '(?i)jdk-[\d.]+-hotspot' -and (Test-Path (Join-Path $_.FullName 'bin\java.exe')) } |
             Sort-Object Name -Descending |   # prefer highest version if multiple exist
             Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "Could not locate the Microsoft OpenJDK install folder under C:\Program Files\Microsoft."
}

# --- README Steps 4-7: download + lay out the Android command-line tools ---
# Implements the critical cmdline-tools\latest\ nesting fix from Step 7.
function Install-AndroidCmdlineTools {
    Write-Step "[4/8] Installing Android command-line tools (with latest\ nesting fix)"

    $sdkRoot      = $Config.AndroidSdkRoot
    $cmdlineRoot  = Join-Path $sdkRoot 'cmdline-tools'
    $latestDir    = Join-Path $cmdlineRoot 'latest'

    # Step 5: create the SDK directory.
    if (-not (Test-Path $sdkRoot)) {
        Write-Info "Creating SDK directory: $sdkRoot"
        New-Item -ItemType Directory -Path $sdkRoot -Force | Out-Null
    }

    if (Test-Path (Join-Path $latestDir 'bin\sdkmanager.bat')) {
        Write-Ok "Android command-line tools already laid out at $latestDir."
        return
    }

    # Step 4: obtain the zip (download or copy from local path).
    $zip = Join-Path $WorkDir 'cmdline-tools.zip'
    Resolve-FileSource -Source $Config.CmdlineToolsSource -DestPath $zip | Out-Null

    # Step 6: extract to a staging folder first so we control the final layout.
    $stage = Join-Path $WorkDir 'cmdline-extract'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Write-Info "Extracting command-line tools..."
    Expand-Archive -Path $zip -DestinationPath $stage -Force

    # Step 7: Google ships these as cmdline-tools\(bin|lib|source.properties).
    # MAUI needs them under cmdline-tools\latest\. Move the inner folder into place.
    $extractedInner = Join-Path $stage 'cmdline-tools'   # what Google's zip contains
    if (-not (Test-Path $extractedInner)) {
        throw "Unexpected archive layout: '$extractedInner' not found."
    }
    if (-not (Test-Path $cmdlineRoot)) {
        New-Item -ItemType Directory -Path $cmdlineRoot -Force | Out-Null
    }
    if (Test-Path $latestDir) { Remove-Item $latestDir -Recurse -Force }
    Write-Info "Applying nesting fix -> $latestDir"
    Move-Item -Path $extractedInner -Destination $latestDir -Force

    if (-not (Test-Path (Join-Path $latestDir 'bin\sdkmanager.bat'))) {
        throw "sdkmanager not found after layout fix. Expected at $latestDir\bin."
    }
    Write-Ok "Command-line tools installed at $latestDir (correct nesting)."
}

# --- README Steps 8-9: accept licenses + install SDK components ------------
# Done together because sdkmanager needs JAVA_HOME pointing at the JDK.
function Install-AndroidSdkComponents {
    param([string]$JavaHome)

    Write-Step "[5/8] Accepting licenses and installing Android SDK components"

    $sdkManager = Join-Path $Config.AndroidSdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path $sdkManager)) { throw "sdkmanager not found at $sdkManager." }

    # sdkmanager is a Java program -- make sure it can find the JDK for THIS call.
    $env:JAVA_HOME    = $JavaHome
    $env:ANDROID_HOME = $Config.AndroidSdkRoot

    # Step 8: accept all licenses. We pipe a stream of "y" so it is non-interactive.
    Write-Info "Accepting Android SDK licenses (automatic 'y')..."
    $yes = ("y`n" * 100)
    $yes | & $sdkManager --sdk_root="$($Config.AndroidSdkRoot)" --licenses | Out-Null
    Write-Ok "Licenses accepted."

    # Step 9: install the required components from the guide.
    # Core packages are always installed; the platform + build-tools are only
    # added when the user chose an API level (AndroidApiLevel is non-empty).
    $packages = [System.Collections.Generic.List[string]]@(
        'platform-tools',
        'emulator'
    )

    if ($Config.AndroidApiLevel) {
        $packages.Add("platforms;$($Config.AndroidApiLevel)")
        $packages.Add("build-tools;$($Config.BuildToolsVer)")
        Write-Info "Platform packages: $($Config.AndroidApiLevel)  build-tools $($Config.BuildToolsVer)"
    } else {
        Write-Warnish "No Android platform selected -- skipping platforms and build-tools packages."
    }

    Write-Info "Installing packages: $($packages -join ', ')"
    & $sdkManager --sdk_root="$($Config.AndroidSdkRoot)" @packages
    Write-Ok "Android SDK components installed."
}

# --- README Step 10: persist JAVA_HOME, ANDROID_HOME and PATH --------------
function Set-EnvironmentVariables {
    param([string]$JavaHome)

    Write-Step "[6/8] Configuring machine environment variables"

    Set-MachineEnv -Name 'JAVA_HOME'    -Value $JavaHome
    Set-MachineEnv -Name 'ANDROID_HOME' -Value $Config.AndroidSdkRoot

    # The PATH additions specified by the guide (Step 10).
    $additions = @(
        '%ANDROID_HOME%\cmdline-tools\latest\bin',
        '%ANDROID_HOME%\platform-tools',
        '%ANDROID_HOME%\emulator',
        '%JAVA_HOME%\bin'
    )

    # Read the *current* (post-clean) machine PATH and append anything missing,
    # preserving the %VAR% tokens so the entries stay portable.
    $current = (Get-MachineEnv 'Path')
    $parts   = @()
    if ($current) { $parts = $current -split ';' | Where-Object { $_ } }

    foreach ($add in $additions) {
        if ($parts -notcontains $add) {
            $parts += $add
            Write-Info "PATH += $add"
        }
    }
    $newPath = ($parts -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')

    # Also reflect into this process so the verification/build step works now.
    $env:Path = "$($JavaHome)\bin;$($Config.AndroidSdkRoot)\platform-tools;$($Config.AndroidSdkRoot)\cmdline-tools\latest\bin;$($Config.AndroidSdkRoot)\emulator;$env:Path"

    Write-Ok "Environment variables configured (JAVA_HOME, ANDROID_HOME, PATH)."
}

# ===========================================================================
#  VERIFY  (README Steps 11-12)
# ===========================================================================
function Test-Toolchain {
    param([string]$JavaHome)

    Write-Step "[7/8] Verifying the toolchain"

    Write-Info "java -version:"
    & "$JavaHome\bin\java.exe" -version
    Write-Info "sdkmanager --version:"
    & (Join-Path $Config.AndroidSdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat') --version
    Write-Info "dotnet workload list:"
    & dotnet workload list
    Write-Ok "Verification commands completed."
}

function Build-SampleProject {
    Write-Step "[8/8] Building a throwaway MAUI project to prove the setup works"

    $proj = Join-Path $WorkDir 'MauiTestApp'
    Write-Info "dotnet new maui -n MauiTestApp"
    & dotnet new maui -n MauiTestApp -o $proj
    Write-Info "dotnet build -f $($Config.MauiTfm)"
    Push-Location $proj
    try {
        & dotnet build -f $Config.MauiTfm
        Write-Ok "Sample MAUI Android build succeeded -- your environment works!"
    }
    finally {
        Pop-Location
    }
    # The project lives inside $WorkDir, so it is removed by the cleanup below.
}

# ===========================================================================
#  MAIN
# ===========================================================================
try {
    Write-Banner ".NET 10 + .NET MAUI Android Setup (No IDE)"
    Write-Host "  Based on github.com/Alex-stewart1/maui-android-setup-guide" -ForegroundColor DarkGray
    Write-Host ""
    Write-Info "This script will install the .NET 10 SDK, MAUI workloads, Microsoft"
    Write-Info "OpenJDK 21 and the Android command-line tools, configure your"
    Write-Info "environment variables, and verify everything with a test build."
    Write-Info "All downloads go to a temp folder that is deleted when it finishes."

    # Show effective installer sources so the user can confirm what will be used.
    Write-Host ""
    $jdkLabel  = if ($Config.JdkMsiSource -match '(?i)^https?://')        { 'URL   ' } else { 'LOCAL ' }
    $ctLabel   = if ($Config.CmdlineToolsSource -match '(?i)^https?://') { 'URL   ' } else { 'LOCAL ' }
    Write-Info "JDK MSI source         [$jdkLabel]: $($Config.JdkMsiSource)"
    Write-Info "Cmdline-tools source   [$ctLabel]: $($Config.CmdlineToolsSource)"
    if ($JdkMsiSource)       { Write-Warnish "(JDK source overridden via -JdkMsiSource parameter)" }
    if ($CmdlineToolsSource) { Write-Warnish "(Cmdline-tools source overridden via -CmdlineToolsSource parameter)" }

    # Validate any local paths NOW -- fail fast before we touch the machine.
    foreach ($check in @(
        @{ Param = '-JdkMsiSource';       Source = $Config.JdkMsiSource       },
        @{ Param = '-CmdlineToolsSource'; Source = $Config.CmdlineToolsSource }
    )) {
        $src = $check.Source
        if ($src -notmatch '(?i)^https?://') {
            $abs = [IO.Path]::GetFullPath($src)
            if (-not (Test-Path $abs -PathType Leaf)) {
                Write-Err "$($check.Param) points to a local path that does not exist:"
                Write-Err "  $abs"
                exit 1
            }
            Write-Ok "$($check.Param) local file verified: $abs"
        }
    }

    # --- Guard: mutually exclusive platform switches ----------------------
    if ($SkipAndroidPlatform -and $AndroidApiLevel -gt 0) {
        Write-Err "-SkipAndroidPlatform and -AndroidApiLevel cannot be used together."
        exit 1
    }

    # --- Guard: must be elevated ------------------------------------------
    if (-not (Test-IsAdmin)) {
        Write-Err "This script must be run from an ELEVATED (Administrator) PowerShell prompt."
        Write-Info "Right-click PowerShell -> 'Run as administrator', then re-run this script."
        exit 1
    }

    # --- Create the working directory now so every step can use it --------
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    Write-Info "Working directory: $WorkDir"

    # --- STEP 0: conflict detection ---------------------------------------
    $report = Get-ExistingInstallReport

    if ($report.HasConflict) {
        Show-ConflictReport -Report $report

        $doClean = $ReinstallClean
        if (-not $doClean) {
            # Offer the user the single "Reinstall clean" choice requested.
            Write-Host "  How would you like to proceed?" -ForegroundColor White
            Write-Host "    [R] Reinstall clean  - remove the items above, then install fresh"
            Write-Host "    [Q] Quit             - change nothing and exit"
            Write-Host ""
            $choice = Read-Host "  Enter choice (R/Q)"
            $doClean = ($choice -match '^(r|R)')
        }

        if (-not $doClean) {
            Write-Warnish "No changes made. Exiting at your request."
            exit 0
        }

        if (-not $Force) {
            Write-Host ""
            Write-Warnish "CLEAN REINSTALL will DELETE the Android SDK folder(s), remove the"
            Write-Warnish "Android env vars / PATH entries, and UNINSTALL the Microsoft JDK"
            Write-Warnish "shown above. This cannot be undone."
            $confirm = Read-Host "  Type 'YES' to continue"
            if ($confirm -ne 'YES') {
                Write-Warnish "Confirmation not given. Exiting without changes."
                exit 0
            }
        }

        Invoke-CleanReinstallPurge -Report $report
    }
    else {
        Write-Ok "No conflicting Android or Microsoft JDK installations found. Proceeding with a fresh install."
    }

    # --- The install pipeline (README steps 1-12) -------------------------
    Install-DotNet10
    Install-MauiWorkload
    Install-MicrosoftJdk21

    $javaHome = Resolve-JdkHome
    Write-Info "Resolved JAVA_HOME -> $javaHome"

    # cmdline-tools must be installed before we can query sdkmanager.
    Install-AndroidCmdlineTools

    # --- Query the live platform list and let the user choose ------------
    # sdkmanager is now available so we can get real, up-to-date options.
    if ($SkipAndroidPlatform) {
        Resolve-AndroidPlatform -Catalogue $null
    } else {
        $catalogue = Get-AndroidPlatformCatalogue -JavaHome $javaHome
        Resolve-AndroidPlatform -Catalogue $catalogue
    }

    Install-AndroidSdkComponents -JavaHome $javaHome
    Set-EnvironmentVariables    -JavaHome $javaHome

    Test-Toolchain -JavaHome $javaHome

    # Only build the sample project when a platform was actually installed.
    if ($Config.AndroidApiLevel) {
        Build-SampleProject
    } else {
        Write-Step "[8/8] Validation build SKIPPED (no Android platform installed)"
        Write-Warnish "Install an Android platform (e.g. -AndroidApiLevel 35) and re-run to validate."
    }

    Write-Banner "SETUP COMPLETE"
    Write-Ok "Your machine is ready to build .NET MAUI Android apps without an IDE."
    Write-Host ""
    Write-Info "IMPORTANT: open a NEW terminal so the updated machine environment"
    Write-Info "variables (JAVA_HOME / ANDROID_HOME / PATH) are picked up. Then:"
    Write-Host ""
    Write-Host "    dotnet new maui -n MyApp"      -ForegroundColor White
    Write-Host "    cd MyApp"                       -ForegroundColor White
    if ($Config.AndroidApiLevel) {
        Write-Host "    dotnet build -f $($Config.MauiTfm)" -ForegroundColor White
    } else {
        Write-Host "    # Install an Android platform first, e.g.:" -ForegroundColor DarkGray
        Write-Host "    #   sdkmanager 'platforms;android-35' 'build-tools;35.0.0'" -ForegroundColor DarkGray
        Write-Host "    dotnet build -f net10.0-android" -ForegroundColor White
    }
    Write-Host ""
}
catch {
    Write-Err "Setup failed: $($_.Exception.Message)"
    Write-Info "No further changes will be made. See the error above for details."
    exit 1
}
finally {
    # ---- SELF CLEANUP: always remove the temp working directory ----------
    if (Test-Path $WorkDir) {
        Write-Step "Cleaning up temporary files"
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed temporary working directory."
    }
}
