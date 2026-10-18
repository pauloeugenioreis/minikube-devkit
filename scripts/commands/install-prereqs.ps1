# devkit install-prereqs: installs and configures everything the selected
# driver needs (core CLIs + driver runtime).

function Invoke-InstallPrereqs {
    param([string[]] $Arguments = @())

    foreach ($arg in $Arguments) {
        if ($arg -in '-h', '--help', '-Help') { Write-Host 'Usage: .\devkit.ps1 install-prereqs [-Driver NAME] [-Yes]'; return 0 }
        Stop-Devkit "Unknown option for install-prereqs: $arg"
    }

    $driver = Get-Cfg 'DEVKIT_DRIVER' 'docker'
    Resume-State

    Install-Dependencies ($script:CoreDeps + "driver_$driver")
    Write-Host ''
    Write-Ok "All prerequisites for the '$driver' driver are ready."
    return 0
}
