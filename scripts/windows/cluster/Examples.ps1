# KEDA examples (examples\): a worker image built inside the cluster and
# ScaledObjects for RabbitMQ, Redis and cron. Deployed whenever KEDA is
# installed, even if RabbitMQ or Redis are not (those ScaledObjects then just
# report not ready until the service exists).

function Get-ExamplesDir { Join-Path (Get-DevkitRoot) 'examples' }

function Assert-ClusterRunning {
    if (-not ((Test-ClusterExists) -and (Test-ClusterRunning))) {
        Stop-Devkit "Cluster '$(Get-Cfg 'DEVKIT_PROFILE')' is not running. Start it with: .\devkit.ps1 up"
    }
}

function Test-ExamplesImage {
    $image = Get-Cfg 'DEVKIT_EXAMPLES_IMAGE'
    $list = & minikube image ls -p (Get-Cfg 'DEVKIT_PROFILE') 2>$null
    return [bool] ($list | Where-Object { $_.Trim().EndsWith($image) })
}

function Build-ExamplesImage {
    param([switch] $Force)
    $image = Get-Cfg 'DEVKIT_EXAMPLES_IMAGE'
    if (-not $Force -and (Test-ExamplesImage)) { Write-Ok "Worker image $image is present"; return }
    Write-Info "Building the worker image $image inside the cluster"
    & minikube image build -p (Get-Cfg 'DEVKIT_PROFILE') -t $image (Join-Path (Get-ExamplesDir) 'worker') *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Devkit 'Building the worker image failed. Retry with: .\devkit.ps1 examples deploy -Rebuild' }
    Write-Ok "Worker image $image built"
}

function Publish-Examples {
    param([switch] $Rebuild)
    if (-not (Test-True (Get-Cfg 'DEVKIT_INSTALL_KEDA'))) { Write-Info 'KEDA is not installed; skipping the KEDA examples.'; return }
    $ns = Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE'
    $dir = Join-Path (Get-ExamplesDir) 'k8s'
    Write-Step "KEDA examples (namespace $ns)"
    Build-ExamplesImage -Force:$Rebuild

    Invoke-KubeApply (Get-RenderedTemplate (Join-Path $dir 'namespace.yaml'))
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, (Get-RenderedTemplate (Join-Path $dir 'credentials.env')))
        $secretYaml = Invoke-Kube create secret generic examples-credentials -n $ns "--from-env-file=$tmp" --dry-run=client -o yaml
        if ($LASTEXITCODE -ne 0) { Stop-Devkit 'Could not render the examples-credentials Secret.' }
        Invoke-KubeApply (($secretYaml -join "`n") + "`n")
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    foreach ($manifest in @('rabbitmq', 'redis', 'cron')) {
        Invoke-KubeApply (Get-RenderedTemplate (Join-Path $dir "$manifest.yaml"))
        Write-Ok "Applied $manifest example"
    }
    # KEDA's RabbitMQ scaler needs the queue to exist: declare it once.
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_RABBITMQ')) { [void] (Invoke-ExamplesProducer 'rabbitmq' 0 'rabbitmq-declare-queue') }
}

function Remove-Examples {
    Invoke-Kube delete namespace (Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE') --ignore-not-found --wait=true *> $null
    Write-Ok "Removed the KEDA examples (namespace $(Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE'))"
}

# Runs the producer Job and waits for it; returns $true on success.
function Invoke-ExamplesProducer {
    param([Parameter(Mandatory)] [ValidateSet('rabbitmq', 'redis')] [string] $Target, [int] $Count = 50, [string] $Name = '')
    if (-not $Name) { $Name = "produce-$Target-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
    $ns = Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE'
    Set-Cfg 'DEVKIT_PRODUCER_NAME' $Name
    Set-Cfg 'DEVKIT_PRODUCER_MODE' "$Target-produce"
    Set-Cfg 'DEVKIT_PRODUCER_COUNT' "$Count"
    Invoke-Kube delete job $Name -n $ns --ignore-not-found *> $null
    Invoke-KubeApply (Get-RenderedTemplate (Join-Path (Get-ExamplesDir) 'k8s/producer-job.yaml'))
    Invoke-Kube wait --for=condition=complete "job/$Name" -n $ns --timeout=180s *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Producer sent $Count messages to $Target"
        return $true
    }
    Write-Err "Producer job $Name did not complete. Check: kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') -n $ns logs job/$Name"
    return $false
}

function Get-ExamplesReplicas {
    param([Parameter(Mandatory)] [string] $Deployment)
    $n = (Invoke-Kube -n (Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE') get deployment $Deployment -o 'jsonpath={.status.replicas}' 2>$null) -join ''
    $value = 0
    [void] [int]::TryParse($n.Trim(), [ref] $value)
    return $value
}
