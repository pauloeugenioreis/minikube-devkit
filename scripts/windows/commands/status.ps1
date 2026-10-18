# devkit status: cluster, workloads, KEDA ScaledObjects and port-forwards.

function Invoke-Status {
    param([string[]] $Arguments = @())
    if ($Arguments.Count -gt 0) { Write-Host 'Usage: .\devkit.ps1 status'; return }
    $clusterProfile = Get-Cfg 'DEVKIT_PROFILE'
    Write-Step "Cluster '$clusterProfile'"
    if (-not (Test-ClusterExists)) { Write-Info 'Not created. Run: .\devkit.ps1 up'; return }
    & minikube status -p $clusterProfile 2>$null | ForEach-Object { Write-Host "    $_" }
    if (-not (Test-ClusterRunning)) { return }

    foreach ($ns in @((Get-Cfg 'DEVKIT_NAMESPACE'), 'keda', (Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE'), 'kubernetes-dashboard')) {
        Invoke-Kube get namespace $ns *> $null
        if ($LASTEXITCODE -ne 0) { continue }
        Write-Step "Namespace $ns"
        Invoke-Kube -n $ns get pods 2>$null | ForEach-Object { Write-Host "    $_" }
    }
    Invoke-Kube get namespace (Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE') *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Step 'KEDA ScaledObjects'
        Invoke-Kube -n (Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE') get scaledobjects 2>$null | ForEach-Object { Write-Host "    $_" }
    }
    Write-Step 'Volumes'
    Invoke-Kube -n (Get-Cfg 'DEVKIT_NAMESPACE') get pvc 2>$null | ForEach-Object { Write-Host "    $_" }
    Write-Step 'Port-forwards'
    Show-ForwardStatus
    return
}
