# devkit up: wizard -> prerequisites -> cluster -> components -> port-forwards.

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
    if ($null -eq $opts) { return }

    Resume-State
    Invoke-Wizard $opts
    $driver = Get-Cfg 'DEVKIT_DRIVER'
    Assert-DriverAvailable $driver

    Install-Dependencies ($script:CoreDeps + "driver_$driver")
    Resize-ToDockerLimits

    Initialize-Cluster
    Publish-Components
    Publish-Keda
    Publish-Examples

    Write-Step 'Port-forwards'
    Start-AllForwards
    Write-Ok 'Port-forwards running in background'

    Write-Host ''
    Write-Host "$(Get-SymbolOk) minikube-devkit is ready!" -ForegroundColor Green
    Write-Host ''
    Show-AccessTable
    Write-Host ''
    Write-Info 'Port-forwards run in background. Manage with: .\devkit.ps1 forward [start|stop|status]'
    Write-Info 'Show this again anytime:  .\devkit.ps1 info'
    Write-Info 'Stop everything:          .\devkit.ps1 down'
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_KEDA')) {
        Write-Info 'See KEDA autoscale:       .\devkit.ps1 examples produce rabbitmq 50  (or: .\devkit.ps1 test keda)'
    }
    return
}
