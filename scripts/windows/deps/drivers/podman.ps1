# podman driver dependency (Windows). The minikube podman driver is
# experimental and needs a rootful "podman machine" (WSL 2 based) sized to
# hold the minikube node.
# With DEVKIT_PODMAN_VERSION=latest, updates from winget/Chocolatey are offered.

$script:PodmanDir = [IO.Path]::Combine($script:ProgramFilesDir, 'RedHat', 'Podman')

function Find-PodmanCli {
    if (Test-Command 'podman') { return $true }
    if (Test-Path -LiteralPath ([IO.Path]::Combine($script:PodmanDir, 'podman.exe'))) {
        Add-ToPath $script:PodmanDir
        return $true
    }
    return $false
}

# Returns the podman machine as an object (Name, State, Rootful, CPUs, Memory) or $null.
function Get-PodmanMachine {
    $json = (& podman machine inspect 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $m = @($json | ConvertFrom-Json)[0]
    return [pscustomobject] @{
        Name = $m.Name; State = $m.State; Rootful = [bool] $m.Rootful
        CPUs = [int] $m.Resources.CPUs; Memory = [int] $m.Resources.Memory
    }
}

function Test-PodmanMachineFits {
    param([object] $Machine)
    $Machine.Rootful -and $Machine.Memory -ge (Get-HelperVmMemoryMb) -and $Machine.CPUs -ge [int] (Get-Cfg 'DEVKIT_CPUS')
}

$script:PodmanUpdateChecked = $false
$script:PodmanUpdate = $null

Register-Dependency -Id 'driver_podman' -Label 'podman' `
    -Check {
        if (-not (Find-PodmanCli)) { return New-DepResult $false 'not installed' }
        $version = ((& podman version --format '{{.Client.Version}}' 2>$null) -join '').Trim()
        if ($version -and -not (Test-VersionAtLeast $version (Get-Cfg 'DEVKIT_PODMAN_MIN_VERSION'))) {
            return New-DepResult $false "$version is older than the required $(Get-Cfg 'DEVKIT_PODMAN_MIN_VERSION'); upgrade Podman" $true
        }
        $machine = Get-PodmanMachine
        if ($null -eq $machine) { return New-DepResult $false 'installed, but no podman machine exists' }
        if (-not (Test-PodmanMachineFits $machine)) { return New-DepResult $false 'the podman machine is not rootful or is smaller than the requested minikube node' }
        if ($machine.State -ne 'running') { return New-DepResult $false 'installed, but the podman machine is not running' }
        if ((Get-Cfg 'DEVKIT_PODMAN_VERSION' 'latest') -eq 'latest') {
            if (-not $script:PodmanUpdateChecked) {
                $script:PodmanUpdate = Get-PackageUpdate -WingetId 'RedHat.Podman' -ChocoId 'podman-cli'
                $script:PodmanUpdateChecked = $true
            }
            if ($script:PodmanUpdate) {
                return New-DepResult $true "ok ($version, update available: $($script:PodmanUpdate.Available))" `
                    -Current $version -Update $script:PodmanUpdate.Available
            }
        }
        return New-DepResult $true "ok ($version)"
    } `
    -Update {
        Update-DevkitPackage -Name 'Podman' -WingetId 'RedHat.Podman' -ChocoId 'podman-cli'
        $script:PodmanUpdateChecked = $false
    } `
    -Install {
        if (Find-PodmanCli) { return }
        Initialize-Wsl 'Podman'
        Install-DevkitPackage -Name 'Podman' -WingetId 'RedHat.Podman' -ChocoId 'podman-cli'
        Update-SessionPath
        if (-not (Find-PodmanCli)) { Stop-Devkit 'Podman was installed but the podman CLI was not found.' }
    } `
    -Configure {
        $cpus = Get-Cfg 'DEVKIT_CPUS'; $memory = Get-HelperVmMemoryMb; $disk = Get-HelperVmDiskGb
        $machine = Get-PodmanMachine
        if ($null -eq $machine) {
            Write-Info "Creating a rootful podman machine ($cpus CPUs, $memory MB RAM, $disk GB disk)"
            Invoke-Native 'podman' @('machine', 'init', '--cpus', "$cpus", '--memory', "$memory", '--disk-size', "$disk", '--rootful')
        } elseif (-not (Test-PodmanMachineFits $machine)) {
            if (-not (Read-YesNo "Reconfigure the podman machine to rootful, $cpus CPUs and $memory MB RAM? It will restart" 'Y')) {
                Stop-Devkit 'The podman machine must be rootful and large enough for the minikube node.'
            }
            if ($machine.State -eq 'running') { Invoke-Native 'podman' @('machine', 'stop') }
            Invoke-Native 'podman' @('machine', 'set', '--rootful', '--cpus', "$cpus", '--memory', "$memory")
        }
        $machine = Get-PodmanMachine
        if ($machine.State -ne 'running') { Invoke-Native 'podman' @('machine', 'start') }
    }
