# Driver registry: which minikube drivers are offered on Windows.
#
# Every driver module (scripts\windows\deps\drivers\<driver>.ps1) is dot-sourced by
# devkit.ps1 at startup and registers a "driver_<name>" dependency, so helper
# function names must be unique across driver modules.

function Get-SupportedDrivers {
    $drivers = @(
        [pscustomobject] @{ Value = 'docker'; Description = 'Docker Desktop containers (recommended)' }
        [pscustomobject] @{ Value = 'hyperv'; Description = 'Hyper-V virtual machine (Windows Pro/Enterprise)' }
    )
    if ((Get-HostArch) -eq 'amd64') {
        $drivers += [pscustomobject] @{ Value = 'virtualbox'; Description = 'VirtualBox virtual machine' }
    }
    $drivers += [pscustomobject] @{ Value = 'podman'; Description = 'Podman containers (experimental)' }
    return $drivers
}

function Get-DriverModuleFiles {
    Get-ChildItem -LiteralPath (Join-Path (Get-DevkitRoot) 'scripts/windows/deps/drivers') -Filter '*.ps1' |
        Where-Object { $_.Name -ne 'drivers.ps1' } |
        ForEach-Object { $_.FullName }
}

# Fails for unsupported drivers and drivers without an implementation yet.
function Assert-DriverAvailable {
    param([Parameter(Mandatory)] [string] $Driver)
    $supported = @(Get-SupportedDrivers | ForEach-Object { $_.Value })
    if ($supported -notcontains $Driver) {
        Stop-Devkit "Driver '$Driver' is not supported on Windows. Supported: $($supported -join ', ')"
    }
    if (-not $script:Dependencies.Contains("driver_$Driver")) {
        Stop-Devkit "Driver '$Driver' is not implemented yet. Use -Driver docker."
    }
}

# Parses the -Driver/--driver option shared by several commands. Returns the
# remaining arguments and stores the driver with Set-Cfg.
function Read-DriverOption {
    param([string[]] $Arguments)
    $rest = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -match '^(--driver|-Driver)$') {
            if ($i + 1 -ge $Arguments.Count) { Stop-Devkit "$($Arguments[$i]) needs a value" }
            $i++
            [Environment]::SetEnvironmentVariable('DEVKIT_DRIVER', $null)
            Set-Cfg 'DEVKIT_DRIVER' $Arguments[$i]
            $script:CliDriver = $Arguments[$i]
        } else {
            $rest += $Arguments[$i]
        }
    }
    return , $rest
}

$script:CliDriver = ''

# ------------------------------------------------- helpers for driver modules ---

$script:ProgramFilesDir = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$script:VirtualizationHint = 'CPU virtualization (VT-x/AMD-V) is disabled; enable it in the BIOS/UEFI settings'

# True when hardware virtualization is usable (or a hypervisor already runs).
function Test-VirtualizationAvailable {
    try {
        if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { return $true }
        return [bool] (@(Get-CimInstance Win32_Processor -ErrorAction Stop)[0].VirtualizationFirmwareEnabled)
    } catch {
        return $true # Unknown: let the installer report it.
    }
}

function Test-WslReady {
    if (-not (Test-Command 'wsl.exe')) { return $false }
    & wsl.exe --status *> $null
    return ($LASTEXITCODE -eq 0)
}

# Enables WSL 2 when missing; exits with a pending reboot when Windows must restart.
function Initialize-Wsl {
    param([Parameter(Mandatory)] [string] $RequiredBy)
    if (Test-WslReady) { return }
    Write-Info "Enabling WSL 2 (required by $RequiredBy)"
    $code = Invoke-Elevated 'wsl.exe --install --no-distribution' 'enabling Windows features for WSL 2'
    if ($code -ne 0) { Stop-Devkit "Enabling WSL 2 failed (exit $code). Run 'wsl --install' manually." }
    if (-not (Test-WslReady)) {
        Exit-Pending 'reboot' 'WSL 2 was enabled and Windows must restart to finish the installation.'
    }
}

# True when the current logon token contains the group (by name or SID).
function Test-InGroupToken {
    param([Parameter(Mandatory)] [string] $Group)
    $groups = & whoami.exe /groups /fo csv 2>$null
    return [bool] ($groups | Select-String -SimpleMatch $Group)
}

# Size of a helper VM (Podman machine) that must hold the minikube node.
function Get-HelperVmMemoryMb { [int] (Get-Cfg 'DEVKIT_MEMORY_MB') + 2048 }
function Get-HelperVmDiskGb { [int] (Get-Cfg 'DEVKIT_DISK_GB') + 20 }
