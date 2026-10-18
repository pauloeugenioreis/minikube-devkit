# devkit shell <service>: opens the service's client inside its pod, already
# authenticated (psql, mysql, mongosh, redis-cli; a shell for RabbitMQ).

function Invoke-Shell {
    param([string[]] $Arguments = @())
    $svc = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    if ($svc -notin 'rabbitmq', 'mongodb', 'postgresql', 'mysql', 'redis') {
        Stop-Devkit 'Usage: .\devkit.ps1 shell rabbitmq|mongodb|postgresql|mysql|redis'
    }
    Assert-ClusterRunning
    if (-not (Test-ComponentReady $svc)) { Stop-Devkit "$svc is not ready. Check: .\devkit.ps1 status" }
    if (-not (Test-Interactive)) { Stop-Devkit 'devkit shell needs an interactive terminal.' }
    $command = ([IO.File]::ReadAllText((Join-Path (Get-DevkitRoot) "k8s/$svc/shell.sh"))).Trim()
    # '--' must be quoted: a bare -- is consumed by PowerShell when calling a function.
    Invoke-Kube -n (Get-Cfg 'DEVKIT_NAMESPACE') exec -it "$svc-0" '--' sh -c $command
    return
}
