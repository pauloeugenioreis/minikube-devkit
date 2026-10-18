# Background port-forwards. Each forward runs "kubectl port-forward" in a
# restart loop (pods restart, connections drop) inside a hidden PowerShell
# process. PID and local port are kept in .devkit\forwards\<name>.{pid,port};
# output goes to log\port-forward-<name>.log.

function Get-ForwardDir { Join-Path (Get-DevkitStateDir) 'forwards' }

function Get-ForwardSpecs {
    $ns = Get-Cfg 'DEVKIT_NAMESPACE'
    @(
        [pscustomobject] @{ Name = 'dashboard'; Component = 'dashboard'; Namespace = 'kubernetes-dashboard'; Service = 'kubernetes-dashboard'; Remote = 80; PortKey = 'DEVKIT_PORT_DASHBOARD' }
        [pscustomobject] @{ Name = 'rabbitmq-mgmt'; Component = 'rabbitmq'; Namespace = $ns; Service = 'rabbitmq'; Remote = 15672; PortKey = 'DEVKIT_PORT_RABBITMQ_MGMT' }
        [pscustomobject] @{ Name = 'rabbitmq-amqp'; Component = 'rabbitmq'; Namespace = $ns; Service = 'rabbitmq'; Remote = 5672; PortKey = 'DEVKIT_PORT_RABBITMQ_AMQP' }
        [pscustomobject] @{ Name = 'mongodb'; Component = 'mongodb'; Namespace = $ns; Service = 'mongodb'; Remote = 27017; PortKey = 'DEVKIT_PORT_MONGODB' }
        [pscustomobject] @{ Name = 'postgresql'; Component = 'postgresql'; Namespace = $ns; Service = 'postgresql'; Remote = 5432; PortKey = 'DEVKIT_PORT_POSTGRESQL' }
        [pscustomobject] @{ Name = 'mysql'; Component = 'mysql'; Namespace = $ns; Service = 'mysql'; Remote = 3306; PortKey = 'DEVKIT_PORT_MYSQL' }
        [pscustomobject] @{ Name = 'redis'; Component = 'redis'; Namespace = $ns; Service = 'redis'; Remote = 6379; PortKey = 'DEVKIT_PORT_REDIS' }
    )
}

function Test-ComponentEnabled {
    param([Parameter(Mandatory)] [string] $Component)
    Test-True (Get-Cfg "DEVKIT_INSTALL_$($Component.ToUpperInvariant())")
}

function Read-ForwardFile {
    param([string] $Name, [string] $Extension)
    $file = Join-Path (Get-ForwardDir) "$Name.$Extension"
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw).Trim() }
    return ''
}

function Test-ForwardRunning {
    param([Parameter(Mandatory)] [string] $Name)
    $forwardPid = Read-ForwardFile $Name 'pid'
    return ($forwardPid -and (Get-Process -Id ([int] $forwardPid) -ErrorAction SilentlyContinue))
}

# Local port actually used (may differ from the configured one when busy).
function Get-ForwardPort {
    param([Parameter(Mandatory)] [object] $Spec)
    $port = Read-ForwardFile $Spec.Name 'port'
    if ($port) { return [int] $port }
    return [int] (Get-Cfg $Spec.PortKey)
}

function Start-Forward {
    param([Parameter(Mandatory)] [object] $Spec)
    $dir = Get-ForwardDir
    $logDir = Get-DevkitLogDir
    foreach ($d in @($dir, $logDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if (Test-ForwardRunning $Spec.Name) { return }

    $port = [int] (Get-Cfg $Spec.PortKey)
    $try = $port
    while (Test-PortInUse $try) {
        $try++
        if ($try -gt $port + 50) { Write-Err "No free local port near $port for $($Spec.Name)."; return }
    }
    if ($try -ne $port) { Write-Warn "Port $port is in use; $($Spec.Name) will use $try instead." }

    $log = Join-Path $logDir "port-forward-$($Spec.Name).log"
    $loop = @"
while (`$true) {
    & kubectl --context '$(Get-Cfg 'DEVKIT_PROFILE')' -n '$($Spec.Namespace)' port-forward --address 127.0.0.1 'svc/$($Spec.Service)' '${try}:$($Spec.Remote)' *>> '$log'
    Start-Sleep -Seconds 2
}
"@
    # -EncodedCommand avoids Start-Process argument quoting issues on 5.1.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loop))
    $startArgs = @{
        FilePath = (Get-Process -Id $PID).Path
        ArgumentList = @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        PassThru = $true
    }
    if (Test-IsWindowsHost) { $startArgs.WindowStyle = 'Hidden' }
    else { $startArgs.RedirectStandardOutput = [IO.Path]::Combine($logDir, "port-forward-$($Spec.Name).out") }
    $proc = Start-Process @startArgs
    [IO.File]::WriteAllText((Join-Path $dir "$($Spec.Name).pid"), "$($proc.Id)")
    [IO.File]::WriteAllText((Join-Path $dir "$($Spec.Name).port"), "$try")

    if (-not (Wait-Until 20 { Test-PortInUse $try }.GetNewClosure())) {
        Write-Warn "Port-forward for $($Spec.Name) is not answering yet (see log\port-forward-$($Spec.Name).log)."
    }
}

function Get-ChildProcessIds {
    param([int] $ParentId)
    if (Test-IsWindowsHost) {
        return @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentId" -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId })
    }
    return @((& pgrep -P $ParentId 2>$null) | Where-Object { $_ } | ForEach-Object { [int] $_ })
}

function Stop-Forward {
    param([Parameter(Mandatory)] [string] $Name)
    $forwardPid = Read-ForwardFile $Name 'pid'
    if ($forwardPid -and (Get-Process -Id ([int] $forwardPid) -ErrorAction SilentlyContinue)) {
        # Kill the restart loop first, then the kubectl it spawned.
        $children = Get-ChildProcessIds ([int] $forwardPid)
        Stop-Process -Id ([int] $forwardPid) -Force -ErrorAction SilentlyContinue
        foreach ($child in $children) { Stop-Process -Id $child -Force -ErrorAction SilentlyContinue }
    }
    foreach ($ext in @('pid', 'port')) {
        Remove-Item -LiteralPath (Join-Path (Get-ForwardDir) "$Name.$ext") -Force -ErrorAction SilentlyContinue
    }
}

function Start-AllForwards {
    foreach ($spec in Get-ForwardSpecs) {
        if (Test-ComponentEnabled $spec.Component) { Start-Forward $spec }
    }
}

function Stop-AllForwards {
    foreach ($spec in Get-ForwardSpecs) { Stop-Forward $spec.Name }
}

function Show-ForwardStatus {
    foreach ($spec in Get-ForwardSpecs) {
        if (-not (Test-ComponentEnabled $spec.Component)) { continue }
        $port = Get-ForwardPort $spec
        if ((Test-ForwardRunning $spec.Name) -and (Test-PortInUse $port)) {
            Write-Ok ('{0,-16} localhost:{1} -> {2}/{3}:{4}' -f $spec.Name, $port, $spec.Namespace, $spec.Service, $spec.Remote)
        } else {
            Write-Err ('{0,-16} not running' -f $spec.Name)
        }
    }
}
