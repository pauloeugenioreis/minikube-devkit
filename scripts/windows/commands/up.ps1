# devkit up: wizard -> prerequisites -> (cluster and components).

# With the docker driver the node cannot be larger than what Docker Desktop's
# VM (WSL 2 or Hyper-V) can use. When the request does not fit, offer to
# shrink it to the largest size that does.
function Resize-ToDockerLimits {
    if ((Get-Cfg 'DEVKIT_DRIVER') -ne 'docker') { return }
    $info = (& docker info --format '{{.NCPU}} {{.MemTotal}}' 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or $info -notmatch '^(\d+) (\d+)$') { return }
    $dockerCpus = [int] $Matches[1]
    $dockerMemMb = [int] ([long] $Matches[2] / 1MB)
    # Leave room for the Docker VM itself and round down to 256 MB.
    $fitMemMb = [int] ([Math]::Floor(($dockerMemMb - 512) / 256) * 256)
    $minCpus = [int] (Get-Cfg 'DEVKIT_MIN_CPUS'); $minMem = [int] (Get-Cfg 'DEVKIT_MIN_MEMORY_MB')
    $hint = 'Raise the WSL 2 limits in %UserProfile%\.wslconfig (or Docker Desktop settings) and retry.'

    if ([int] (Get-Cfg 'DEVKIT_CPUS') -gt $dockerCpus) {
        Write-Warn "Docker can use only $dockerCpus CPUs, but $(Get-Cfg 'DEVKIT_CPUS') were requested."
        if ($dockerCpus -lt $minCpus) { Stop-Devkit "Docker needs at least $minCpus CPUs. $hint" }
        if (-not (Read-YesNo "Use $dockerCpus CPUs instead?" 'Y')) { Stop-Devkit $hint }
        Save-Cfg 'DEVKIT_CPUS' "$dockerCpus"
    }
    if ([int] (Get-Cfg 'DEVKIT_MEMORY_MB') -gt $fitMemMb) {
        Write-Warn "Docker can use only $dockerMemMb MB, but $(Get-Cfg 'DEVKIT_MEMORY_MB') MB were requested."
        if ($fitMemMb -lt $minMem) { Stop-Devkit "Docker needs at least $($minMem + 512) MB. $hint" }
        if (-not (Read-YesNo "Use $fitMemMb MB instead?" 'Y')) { Stop-Devkit $hint }
        Save-Cfg 'DEVKIT_MEMORY_MB' "$fitMemMb"
    }
}

function Invoke-Up {
    param([string[]] $Arguments = @())
    $usage = "Usage: .\devkit.ps1 up [options]`n`nRuns the setup wizard, installs missing prerequisites and starts the environment.`n`nOptions:`n$script:WizardFlagsHelp"
    $opts = Read-WizardArgs $Arguments $usage
    if ($null -eq $opts) { return 0 }

    Resume-State
    Invoke-Wizard $opts
    $driver = Get-Cfg 'DEVKIT_DRIVER'
    Assert-DriverAvailable $driver

    Install-Dependencies ($script:CoreDeps + "driver_$driver")
    Resize-ToDockerLimits

    Write-Host ''
    Write-Ok "Prerequisites ready for: $driver, $(Get-Cfg 'DEVKIT_CPUS') CPUs, $(Get-Cfg 'DEVKIT_MEMORY_MB') MB RAM, $(Get-Cfg 'DEVKIT_DISK_GB') GB disk."
    Write-Warn 'Cluster and component provisioning is not implemented yet (next phase).'
    return 0
}
