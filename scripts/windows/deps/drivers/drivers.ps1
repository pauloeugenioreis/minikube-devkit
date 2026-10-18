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
