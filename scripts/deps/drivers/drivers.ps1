# Driver registry: which minikube drivers are offered on Windows and how to
# load their dependency module.

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

# Dot-sources the driver module; fails for drivers without an implementation yet.
# Call it from the script scope:  . (Get-DriverModule $driver)
function Get-DriverModule {
    param([Parameter(Mandatory)] [string] $Driver)
    $supported = @(Get-SupportedDrivers | ForEach-Object { $_.Value })
    if ($supported -notcontains $Driver) {
        Stop-Devkit "Driver '$Driver' is not supported on Windows. Supported: $($supported -join ', ')"
    }
    $file = Join-Path (Get-DevkitRoot) "scripts/deps/drivers/$Driver.ps1"
    if (-not (Test-Path -LiteralPath $file)) { Stop-Devkit "Driver '$Driver' is not implemented yet. Use -Driver docker." }
    return $file
}
