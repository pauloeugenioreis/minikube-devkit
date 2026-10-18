# devkit reset <service>: deletes a data service and its volume, then
# deploys it again from scratch (fresh database with the current config).

function Invoke-Reset {
    param([string[]] $Arguments = @())
    $svc = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    if ($svc -notin 'rabbitmq', 'mongodb', 'postgresql', 'mysql', 'redis') {
        Stop-Devkit 'Usage: .\devkit.ps1 reset rabbitmq|mongodb|postgresql|mysql|redis'
    }
    if (-not (Test-ComponentEnabled $svc)) { Stop-Devkit "$svc is not enabled in config\devkit.env (DEVKIT_INSTALL_$($svc.ToUpperInvariant()))." }
    Assert-ClusterRunning
    if (-not (Read-YesNo "Delete $svc and ALL its data, then recreate it?" 'N')) { Stop-Devkit 'Aborted by user.' }

    $ns = Get-Cfg 'DEVKIT_NAMESPACE'
    foreach ($forward in @($svc, "$svc-mgmt", "$svc-amqp")) { Stop-Forward $forward }
    Invoke-Kube -n $ns delete statefulset $svc --ignore-not-found --wait=true *> $null
    Invoke-Kube -n $ns delete pvc "data-$svc-0" --ignore-not-found --wait=true *> $null
    Write-Ok "Deleted $svc and its volume"

    Publish-Component $svc
    Write-Info "Waiting for $svc to become ready..."
    Invoke-Kube rollout status "statefulset/$svc" -n $ns "--timeout=$(Get-Cfg 'DEVKIT_DEPLOY_TIMEOUT' '600')s" *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Devkit "$svc did not become ready. Check: .\devkit.ps1 logs $svc" }
    Write-Ok "$svc is ready with a fresh volume"
    Start-AllForwards
    return
}
