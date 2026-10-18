# Shared helpers: logging, configuration, versions, downloads, privileges and
# host information. Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# Keep this file ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI.

Set-StrictMode -Version 2.0

$script:DevkitRoot = $null
$script:Config = @{}
$script:Verbose = $false
$script:NonInteractive = $false

# Exit code used when the user must log out/in or reboot before continuing.
$script:ExitPending = 10

# Symbols: Unicode on PowerShell 7, ASCII on Windows PowerShell 5.1 consoles.
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $script:SymOk = [string][char]0x2714; $script:SymWarn = '!'; $script:SymErr = [string][char]0x2716
} else {
    $script:SymOk = '+'; $script:SymWarn = '!'; $script:SymErr = 'x'
}

# ---------------------------------------------------------------- context ---

function Initialize-Devkit {
    param([Parameter(Mandatory)] [string] $Root)
    $script:DevkitRoot = $Root
    # TLS 1.2 is not enabled by default on older Windows PowerShell builds.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # The progress bar makes Invoke-WebRequest dramatically slower on 5.1.
    $global:ProgressPreference = 'SilentlyContinue'
}

function Get-DevkitRoot { $script:DevkitRoot }
function Get-DevkitStateDir { Join-Path $script:DevkitRoot '.devkit' }
function Get-ExitPendingCode { $script:ExitPending }

function Set-DevkitVerbose { param([bool] $Value) $script:Verbose = $Value }
function Set-DevkitNonInteractive { param([bool] $Value) $script:NonInteractive = $Value }
function Test-DevkitNonInteractive {
    $script:NonInteractive -or (Test-True (Get-Cfg 'DEVKIT_NONINTERACTIVE' 'false'))
}

function Test-IsWindowsHost {
    # $IsWindows only exists on PowerShell 6+; 5.1 always runs on Windows.
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool] $IsWindows
}

function Get-HostArch {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if (-not $arch -and -not (Test-IsWindowsHost)) { $arch = (uname -m) }
    switch -Regex ($arch) {
        '^(AMD64|x86_64)$' { return 'amd64' }
        '^(ARM64|aarch64)$' { return 'arm64' }
        default { throw "Unsupported CPU architecture: $arch" }
    }
}

function Get-HostOsName {
    if (Test-IsWindowsHost) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            return "$($os.Caption) (build $($os.BuildNumber))"
        } catch { return 'Windows' }
    }
    return [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
}

# ---------------------------------------------------------------- logging ---

function Write-Step  { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info  { param([string] $Message) Write-Host "    $Message" }
function Write-Ok    { param([string] $Message) Write-Host "  $script:SymOk " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn  { param([string] $Message) Write-Host "  $script:SymWarn " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Err   { param([string] $Message) Write-Host "  $script:SymErr " -ForegroundColor Red -NoNewline; Write-Host $Message }
function Write-DebugLine {
    param([string] $Message)
    if ($script:Verbose) { Write-Host "    $Message" -ForegroundColor DarkGray }
}

# Errors thrown by devkit carry this prefix so the entrypoint can print them
# without a stack trace.
function Stop-Devkit {
    param([Parameter(Mandatory)] [string] $Message)
    throw "DEVKIT: $Message"
}

# Runs an external command, echoing it in verbose mode; throws on failure.
function Invoke-Native {
    param([Parameter(Mandatory)] [string] $FilePath, [string[]] $Arguments = @())
    Write-DebugLine "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { Stop-Devkit "Command failed (exit $LASTEXITCODE): $FilePath $($Arguments -join ' ')" }
}

function Test-Command { param([string] $Name) [bool] (Get-Command $Name -ErrorAction SilentlyContinue) }

# ----------------------------------------------------------- configuration ---

function Get-ConfigFile { Join-Path $script:DevkitRoot 'config/devkit.env' }

function Import-DevkitConfig {
    $script:Config = @{}
    Import-ConfigFile (Get-ConfigFile)
}

function Import-ConfigFile {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        $key = if ($idx -gt 0) { $line.Substring(0, $idx) } else { '' }
        if ($key -notmatch '^DEVKIT_[A-Z0-9_]+$') {
            Write-Warn "Ignoring invalid line in $(Split-Path -Leaf $Path): $line"
            continue
        }
        $value = $line.Substring($idx + 1)
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $script:Config[$key] = $value
    }
}

# Environment variables win over the config files.
function Get-Cfg {
    param([Parameter(Mandatory)] [string] $Key, [string] $Default = '')
    $fromEnv = [Environment]::GetEnvironmentVariable($Key)
    if ($null -ne $fromEnv -and $fromEnv -ne '') { return $fromEnv }
    if ($script:Config.ContainsKey($Key)) { return $script:Config[$Key] }
    return $Default
}

function Set-Cfg {
    param([Parameter(Mandatory)] [string] $Key, [string] $Value)
    $script:Config[$Key] = $Value
}

# Persists KEY=value in config/devkit.env, updating the existing line in place
# (comments and order are preserved) or appending it when missing.
function Save-Cfg {
    param([Parameter(Mandatory)] [string] $Key, [string] $Value)
    $file = Get-ConfigFile
    $found = $false
    $lines = @()
    foreach ($line in Get-Content -LiteralPath $file) {
        if ($line.StartsWith("$Key=")) { $found = $true; $lines += "$Key=$Value" } else { $lines += $line }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    # LF and no BOM, matching .gitattributes and the Bash implementation.
    [IO.File]::WriteAllText($file, (($lines -join "`n") + "`n"))
    # The saved value is now authoritative for this run, even over an
    # environment variable with the same name.
    [Environment]::SetEnvironmentVariable($Key, $null)
    Set-Cfg $Key $Value
}

function Test-True { param([string] $Value) $Value -match '^(true|1|yes|y)$' }
function Test-Int  { param([string] $Value) $Value -match '^[0-9]+$' }

# ---------------------------------------------------------------- versions ---

function ConvertTo-CoreVersion {
    param([string] $Version)
    $v = $Version.Trim().TrimStart('v') -replace '[-+].*$', ''
    $parts = @($v.Split('.') | ForEach-Object { if ($_ -match '^[0-9]+$') { [int] $_ } else { 0 } })
    while ($parts.Count -lt 3) { $parts += 0 }
    return New-Object Version $parts[0], $parts[1], $parts[2]
}

# True when version A >= version B (ignores a leading "v" and -suffix/+build).
function Test-VersionAtLeast {
    param([string] $A, [string] $B)
    (ConvertTo-CoreVersion $A) -ge (ConvertTo-CoreVersion $B)
}

# --------------------------------------------------------------- downloads ---

function Save-Download {
    param([Parameter(Mandatory)] [string] $Url, [Parameter(Mandatory)] [string] $Destination)
    Write-DebugLine "download $Url"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 3) { Stop-Devkit "Download failed: $Url ($($_.Exception.Message))" }
            Start-Sleep -Seconds 2
        }
    }
}

# The checksum file may contain "hash" or "hash  filename".
function Assert-Sha256 {
    param([Parameter(Mandatory)] [string] $File, [Parameter(Mandatory)] [string] $ChecksumUrl)
    $sumFile = [IO.Path]::GetTempFileName()
    try {
        Save-Download $ChecksumUrl $sumFile
        $expected = ((Get-Content -LiteralPath $sumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    } finally {
        Remove-Item -LiteralPath $sumFile -Force -ErrorAction SilentlyContinue
    }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        Stop-Devkit "Checksum mismatch for $(Split-Path -Leaf $File) (expected $expected, got $actual)"
    }
}

function New-TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("devkit-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

# ------------------------------------------------------------- privileges ---

function Test-IsAdmin {
    if (-not (Test-IsWindowsHost)) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs a PowerShell command as administrator (one UAC prompt) and returns its
# exit code. Runs in-process when the session is already elevated.
function Invoke-Elevated {
    param([Parameter(Mandatory)] [string] $Command, [string] $Reason = '')
    if ($Reason) { Write-Info "Administrator rights needed: $Reason" }
    Write-DebugLine "(admin) $Command"
    if (Test-IsAdmin) {
        $global:LASTEXITCODE = 0
        & ([scriptblock]::Create($Command))
        return $LASTEXITCODE
    }
    $shell = (Get-Process -Id $PID).Path
    $wrapped = "$Command; exit `$LASTEXITCODE"
    $proc = Start-Process -FilePath $shell -Verb RunAs -Wait -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $wrapped)
    return $proc.ExitCode
}

# ---------------------------------------------------------------- waiting ---

# Polls the script block every 3 seconds until it returns $true or times out.
function Wait-Until {
    param([Parameter(Mandatory)] [int] $TimeoutSeconds, [Parameter(Mandatory)] [scriptblock] $Condition)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (& $Condition)) {
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 3
    }
    return $true
}

# -------------------------------------------------------------- host info ---

function Get-HostCpus { [Environment]::ProcessorCount }

function Get-HostMemoryMb {
    if (Test-IsWindowsHost) {
        return [int] ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    }
    $line = Get-Content /proc/meminfo | Where-Object { $_ -match '^MemTotal:' } | Select-Object -First 1
    return [int] ([long] ($line -replace '[^0-9]', '') / 1024)
}

# Free disk space (GB) on the drive that holds PATH.
function Get-FreeDiskGb {
    param([Parameter(Mandatory)] [string] $Path)
    while (-not (Test-Path -LiteralPath $Path)) { $Path = Split-Path -Parent $Path }
    $drive = (Get-Item -LiteralPath $Path).PSDrive
    return [int] ($drive.Free / 1GB)
}

# True when something is listening on 127.0.0.1:PORT.
function Test-PortInUse {
    param([Parameter(Mandatory)] [int] $Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        return ($task.Wait(500) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# True when the URL answers HTTPS (any HTTP status counts as reachable).
function Test-UrlReachable {
    param([Parameter(Mandatory)] [string] $Url)
    try {
        Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $response = $null
        if ($_.Exception.PSObject.Properties['Response']) { $response = $_.Exception.Response }
        return ($null -ne $response)
    }
}

# ------------------------------------------------------------------- PATH ---

# Adds a directory to the current session PATH and, optionally, the user PATH.
function Add-ToPath {
    param([Parameter(Mandatory)] [string] $Directory, [switch] $Persist, [switch] $Prepend)
    $sep = [IO.Path]::PathSeparator
    $entries = @($env:PATH -split [regex]::Escape($sep) | Where-Object { $_ -and ($_.TrimEnd('\', '/') -ne $Directory.TrimEnd('\', '/')) })
    if ($Prepend) { $entries = @($Directory) + $entries } else { $entries += $Directory }
    $env:PATH = $entries -join $sep

    if ($Persist -and (Test-IsWindowsHost)) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $userEntries = @()
        if ($userPath) { $userEntries = @($userPath -split ';' | Where-Object { $_ }) }
        if ($userEntries -notcontains $Directory) {
            [Environment]::SetEnvironmentVariable('Path', (@($Directory) + $userEntries) -join ';', 'User')
            Write-Info "Added $Directory to your user PATH (new terminals will pick it up)."
        }
    }
}

Export-ModuleMember -Function *
