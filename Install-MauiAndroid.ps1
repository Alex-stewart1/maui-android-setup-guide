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
        9.  Verify the whole toolchain and build a throwaway MAUI project to prove it works.

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

.NOTES
    *** MUST BE RUN FROM AN ELEVATED (Administrator) PowerShell PROMPT. ***
    Setting MACHINE-level environment variables and installing into
    "C:\Program Files" both require admin rights.

    Author : Generated for Alex-stewart1/maui-android-setup-guide
    Target : Windows 10/11 x64, PowerShell 5.1+ or PowerShell 7+
#>

[CmdletBinding()]
param(
    [switch]$ReinstallClean,
    [switch]$Force
)

# Stop on the first unhandled error so we never half-configure the machine.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  CONFIGURATION  -- the exact versions / paths the guide specifies.
#  Change these in ONE place if the guide is ever updated.
# ---------------------------------------------------------------------------
$Config = [ordered]@{
    # Where the Android SDK lives. Near the drive root to dodge path-length limits.
    AndroidSdkRoot   = 'C:\Program Files (x86)\Android\android-sdk'

    # Expected install root for Microsoft OpenJDK 21 ("hotspot" build).
    JdkInstallRoot   = 'C:\Program Files\Microsoft\jdk-21-hotspot'

    # Android API level / build-tools the guide installs.
    AndroidApiLevel  = 'android-35'
    BuildToolsVer    = '35.0.0'

    # The MAUI target framework moniker we build against to prove the setup works.
    MauiTfm          = 'net10.0-android'

    # --- Download sources -------------------------------------------------
    # Microsoft OpenJDK 21 (Windows x64 MSI). Microsoft publishes a stable
    # "latest" alias so we don't have to hard-code a patch version.
    JdkMsiUrl        = 'https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.msi'

    # Google Android command-line tools (Windows). The version in the URL is the
    # tools package revision, not the Android API; this is the current stable zip.
    CmdlineToolsUrl  = 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'

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
    Get-RemoteFile -Url $Config.JdkMsiUrl -OutFile $msi

    Write-Info "Running the MSI silently (msiexec /i ... /qn)..."
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "Microsoft OpenJDK MSI failed with exit code $($p.ExitCode)."
    }
    Write-Ok "Microsoft OpenJDK 21 installed."
}

# Resolve the real JDK folder. We prefer the guide's exact path, but if the MSI
# laid down a slightly different patch-versioned "jdk-21.x.x-hotspot" folder we
# locate it dynamically so JAVA_HOME is always correct.
function Resolve-JdkHome {
    if (Test-Path $Config.JdkInstallRoot) { return $Config.JdkInstallRoot }
    $found = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '(?i)jdk-21.*hotspot' } |
             Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "Could not locate the Microsoft OpenJDK 21 install folder."
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

    # Step 4: download the zip.
    $zip = Join-Path $WorkDir 'cmdline-tools.zip'
    Get-RemoteFile -Url $Config.CmdlineToolsUrl -OutFile $zip

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
    $packages = @(
        'platform-tools',
        'emulator',
        "platforms;$($Config.AndroidApiLevel)",
        "build-tools;$($Config.BuildToolsVer)"
    )
    Write-Info "Installing packages: $($packages -join ', ')"
    & $sdkManager --sdk_root="$($Config.AndroidSdkRoot)" $packages
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

    Install-AndroidCmdlineTools
    Install-AndroidSdkComponents -JavaHome $javaHome
    Set-EnvironmentVariables    -JavaHome $javaHome

    Test-Toolchain      -JavaHome $javaHome
    Build-SampleProject

    Write-Banner "SETUP COMPLETE"
    Write-Ok "Your machine is ready to build .NET MAUI Android apps without an IDE."
    Write-Host ""
    Write-Info "IMPORTANT: open a NEW terminal so the updated machine environment"
    Write-Info "variables (JAVA_HOME / ANDROID_HOME / PATH) are picked up. Then:"
    Write-Host ""
    Write-Host "    dotnet new maui -n MyApp"      -ForegroundColor White
    Write-Host "    cd MyApp"                       -ForegroundColor White
    Write-Host "    dotnet build -f $($Config.MauiTfm)" -ForegroundColor White
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
