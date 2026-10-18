# devkit logs <component> [-f]: shows recent logs of a component.

function Get-LogsTarget {
    param([string] $Component)
    switch ($Component) {
        { $_ -in 'rabbitmq', 'mongodb', 'postgresql', 'mysql', 'redis' } { return @((Get-Cfg 'DEVKIT_NAMESPACE'), "statefulset/$Component") }
        'keda' { return @('keda', 'deployment/keda-operator') }
        'dashboard' { return @('kubernetes-dashboard', 'deployment/kubernetes-dashboard') }
        { $_ -in 'rabbitmq-worker', 'redis-worker' } { return @((Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE'), "deployment/$Component") }
    }
    return $null
}

function Invoke-Logs {
    param([string[]] $Arguments = @())
    $component = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    $target = Get-LogsTarget $component
    if ($null -eq $target) {
        Stop-Devkit 'Usage: .\devkit.ps1 logs <component> [-f]  (components: rabbitmq mongodb postgresql mysql redis keda dashboard rabbitmq-worker redis-worker)'
    }
    Assert-ClusterRunning
    $replicas = (Invoke-Kube -n $target[0] get $target[1] -o 'jsonpath={.status.replicas}' 2>$null) -join ''
    if ($replicas.Trim() -eq '0') {
        Write-Info "$component is scaled to zero right now, so there are no logs (KEDA starts it when there is work)."
        return
    }
    $kubeArgs = @('-n', $target[0], 'logs', $target[1], '--tail=200', '--all-containers')
    if ($Arguments -contains '-f' -or $Arguments -contains '--follow') { $kubeArgs += '-f' }
    Invoke-Kube @kubeArgs
    return
}
