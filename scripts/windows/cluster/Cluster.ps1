# Minikube cluster lifecycle: create/start/recreate the profile and enable addons.

function Invoke-Kube {
    & kubectl --context (Get-Cfg 'DEVKIT_PROFILE') @args
}

# Applies a YAML string. Goes through a UTF-8 temp file because Windows
# PowerShell 5.1 re-encodes text piped into native programs.
function Invoke-KubeApply {
    param([Parameter(Mandatory)] [string] $Yaml)
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $Yaml)
        $out = Invoke-Kube apply -f $tmp 2>&1
        if ($LASTEXITCODE -ne 0) { Stop-Devkit "kubectl apply failed: $($out -join ' ')" }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Replaces every ${DEVKIT_*} placeholder in a template with its config value.
# Other $VARS are left untouched. Unknown DEVKIT_ keys are an error.
function Get-RenderedTemplate {
    param([Parameter(Mandatory)] [string] $Path)
    $text = [IO.File]::ReadAllText($Path)
    $pattern = '\$\{(DEVKIT_[A-Z0-9_]+)\}'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        if (-not (Test-CfgDefined $m.Groups[1].Value)) {
            $relative = $Path.Substring((Get-DevkitRoot).Length).TrimStart('\', '/')
            Stop-Devkit "Template $relative uses `${$($m.Groups[1].Value)}, which is not defined in config\devkit.env"
        }
    }
    return [regex]::Replace($text, $pattern, { param($m) Get-Cfg $m.Groups[1].Value })
}

# Minikube home directory (same rules as minikube itself).
function Get-MinikubeDir {
    $home_ = $env:MINIKUBE_HOME
    if (-not $home_) { return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.minikube' }
    if ((Split-Path -Leaf $home_) -eq '.minikube') { return $home_ }
    return Join-Path $home_ '.minikube'
}

function Get-ProfileConfig {
    $file = Join-Path (Get-MinikubeDir) "profiles/$(Get-Cfg 'DEVKIT_PROFILE')/config.json"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
}

function Test-ClusterExists { $null -ne (Get-ProfileConfig) }

function Test-ClusterRunning {
    $status = (& minikube status -p (Get-Cfg 'DEVKIT_PROFILE') --format '{{.Host}}/{{.APIServer}}' 2>$null) -join ''
    return ($status.Trim() -eq 'Running/Running')
}

# Creates the cluster, starts it, or offers to recreate it when the driver
# or resources in config\devkit.env differ from the existing profile.
function Initialize-Cluster {
    $clusterProfile = Get-Cfg 'DEVKIT_PROFILE'
    $driver = Get-Cfg 'DEVKIT_DRIVER'; $cpus = [int] (Get-Cfg 'DEVKIT_CPUS')
    $mem = [int] (Get-Cfg 'DEVKIT_MEMORY_MB'); $disk = [int] (Get-Cfg 'DEVKIT_DISK_GB')

    Write-Step "Minikube cluster '$clusterProfile'"
    $current = Get-ProfileConfig
    if ($null -ne $current) {
        if ($current.Driver -ne $driver -or [int] $current.CPUs -ne $cpus -or [int] $current.Memory -ne $mem -or [int] $current.DiskSize -ne ($disk * 1024)) {
            Write-Warn "The existing cluster uses: $($current.Driver), $($current.CPUs) CPUs, $($current.Memory) MB RAM, $([int] ($current.DiskSize / 1024)) GB disk."
            Write-Info "Requested:                 $driver, $cpus CPUs, $mem MB RAM, $disk GB disk."
            if (Read-YesNo 'Recreate cluster to apply new resources? Data will be lost' 'N') {
                Stop-AllForwards
                Invoke-Native 'minikube' @('delete', '-p', $clusterProfile)
            } else {
                Write-Info 'Keeping the existing cluster and its current resources.'
            }
        }
    }

    if (Test-ClusterExists) {
        if (Test-ClusterRunning) {
            Write-Ok 'Cluster is running'
        } else {
            Write-Info 'Starting the existing cluster'
            & minikube start -p $clusterProfile
            if ($LASTEXITCODE -ne 0) { Stop-Devkit "minikube start failed. See: minikube logs -p $clusterProfile" }
        }
    } else {
        Write-Info "Creating the cluster ($driver, $cpus CPUs, $mem MB RAM, $disk GB disk)"
        & minikube start -p $clusterProfile "--driver=$driver" "--cpus=$cpus" "--memory=$mem" "--disk-size=${disk}g" "--kubernetes-version=$(Get-Cfg 'DEVKIT_KUBERNETES_VERSION')"
        if ($LASTEXITCODE -ne 0) { Stop-Devkit "minikube start failed. See: minikube logs -p $clusterProfile" }
    }

    # metrics-server feeds the HPA that KEDA drives and the Dashboard graphs.
    $addons = @('metrics-server')
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_DASHBOARD')) { $addons += 'dashboard' }
    foreach ($addon in $addons) {
        & minikube addons enable $addon -p $clusterProfile *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Devkit "Could not enable the $addon addon." }
        Write-Ok "Addon $addon enabled"
    }
}

function Stop-Cluster {
    if ((Test-ClusterExists) -and (Test-ClusterRunning)) {
        Invoke-Native 'minikube' @('stop', '-p', (Get-Cfg 'DEVKIT_PROFILE'))
    } else {
        Write-Info "Cluster '$(Get-Cfg 'DEVKIT_PROFILE')' is not running."
    }
}

function Remove-Cluster {
    if (Test-ClusterExists) {
        Invoke-Native 'minikube' @('delete', '-p', (Get-Cfg 'DEVKIT_PROFILE'))
    } else {
        Write-Info "Cluster '$(Get-Cfg 'DEVKIT_PROFILE')' does not exist."
    }
}
