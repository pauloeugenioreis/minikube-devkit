# Access table: URLs and credentials of every installed component.

function Show-AccessTable {
    param([switch] $NoSecrets)

    $secret = { param($v) if ($NoSecrets) { '****' } else { $v } }.GetNewClosure()
    $specs = @{}
    foreach ($s in Get-ForwardSpecs) { $specs[$s.Name] = $s }
    $rows = New-Object System.Collections.ArrayList
    $notReady = @()

    $add = {
        param([string] $Label, [string] $Url, [string] $Login, [string] $Component, [string] $Forward = '')
        $ok = Test-ComponentReady $Component
        if ($ok -and $Forward) { $ok = Test-PortInUse (Get-ForwardPort $specs[$Forward]) }
        if (-not $ok) { $Url = 'NOT READY'; $Login = '-'; $script:AccessNotReady += $Component }
        [void] $rows.Add(@($Label, $Url, $Login))
    }
    $script:AccessNotReady = @()
    $port = { param($name) Get-ForwardPort $specs[$name] }
    # Lines of the "connect from outside Kubernetes" section (only components that answer).
    $hostRows = New-Object System.Collections.ArrayList
    $addHost = {
        param([string] $Label, [string] $Forward, [string] $Details, [string] $Component)
        $p = Get-ForwardPort $specs[$Forward]
        if ((Test-ComponentReady $Component) -and (Test-PortInUse $p)) { [void] $hostRows.Add(@($Label, "$p", $Details)) }
    }

    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_DASHBOARD')) {
        & $add 'Kubernetes Dashboard' "http://localhost:$(& $port 'dashboard')" '(no login)' 'dashboard' 'dashboard'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_RABBITMQ')) {
        $u = Get-Cfg 'DEVKIT_RABBITMQ_USER'; $p = & $secret (Get-Cfg 'DEVKIT_RABBITMQ_PASSWORD')
        & $add 'RabbitMQ Management' "http://localhost:$(& $port 'rabbitmq-mgmt')" "$u / $p" 'rabbitmq' 'rabbitmq-mgmt'
        & $add 'RabbitMQ AMQP' "amqp://${u}:$p@localhost:$(& $port 'rabbitmq-amqp')/" "$u / $p" 'rabbitmq' 'rabbitmq-amqp'
        & $addHost 'RabbitMQ' 'rabbitmq-amqp' "user $u  vhost /  (AMQP)" 'rabbitmq'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_MONGODB')) {
        $u = Get-Cfg 'DEVKIT_MONGODB_USER'; $p = & $secret (Get-Cfg 'DEVKIT_MONGODB_PASSWORD')
        & $add 'MongoDB' "mongodb://${u}:$p@localhost:$(& $port 'mongodb')/$(Get-Cfg 'DEVKIT_MONGODB_DATABASE')?authSource=admin" "$u / $p" 'mongodb' 'mongodb'
        & $addHost 'MongoDB' 'mongodb' "user $u  database $(Get-Cfg 'DEVKIT_MONGODB_DATABASE')  (authSource=admin)" 'mongodb'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_POSTGRESQL')) {
        $u = Get-Cfg 'DEVKIT_POSTGRESQL_USER'; $p = & $secret (Get-Cfg 'DEVKIT_POSTGRESQL_PASSWORD')
        & $add 'PostgreSQL' "postgresql://${u}:$p@localhost:$(& $port 'postgresql')/$(Get-Cfg 'DEVKIT_POSTGRESQL_DATABASE')" "$u / $p" 'postgresql' 'postgresql'
        & $addHost 'PostgreSQL' 'postgresql' "user $u  database $(Get-Cfg 'DEVKIT_POSTGRESQL_DATABASE')" 'postgresql'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_MYSQL')) {
        $u = Get-Cfg 'DEVKIT_MYSQL_USER'; $p = & $secret (Get-Cfg 'DEVKIT_MYSQL_PASSWORD'); $r = & $secret (Get-Cfg 'DEVKIT_MYSQL_ROOT_PASSWORD')
        & $add 'MySQL' "mysql://${u}:$p@localhost:$(& $port 'mysql')/$(Get-Cfg 'DEVKIT_MYSQL_DATABASE')" "$u / $p (root: $r)" 'mysql' 'mysql'
        & $addHost 'MySQL' 'mysql' "user $u  database $(Get-Cfg 'DEVKIT_MYSQL_DATABASE')  (or root)" 'mysql'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_REDIS')) {
        $p = & $secret (Get-Cfg 'DEVKIT_REDIS_PASSWORD')
        & $add 'Redis' "redis://:$p@localhost:$(& $port 'redis')" "password: $p" 'redis' 'redis'
        & $addHost 'Redis' 'redis' 'password only (no user)' 'redis'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_KEDA')) {
        & $add 'KEDA' 'namespace: keda (operator running)' '-' 'keda'
    }
    $notReady = $script:AccessNotReady

    if ($rows.Count -eq 0) { Write-Info 'No components are installed.'; return }

    $w = @(8, 14, 11)
    foreach ($row in $rows) {
        for ($i = 0; $i -lt 3; $i++) { if ($row[$i].Length -gt $w[$i]) { $w[$i] = $row[$i].Length } }
    }
    # Borders and padding add 10 columns; switch to a list when the table would wrap.
    $cols = 0
    try { $cols = $Host.UI.RawUI.WindowSize.Width } catch { $cols = 0 }
    if ($cols -gt 0 -and ($w[0] + $w[1] + $w[2] + 10) -gt $cols) {
        foreach ($row in $rows) {
            Write-Host ''
            Write-Host "  $($row[0])"
            Write-Host ('    {0,-13} {1}' -f 'URL:', $row[1])
            if ($row[2] -ne '-') { Write-Host ('    {0,-13} {1}' -f 'Credentials:', $row[2]) }
        }
    } else {
        $border = '+-' + ('-' * $w[0]) + '-+-' + ('-' * $w[1]) + '-+-' + ('-' * $w[2]) + '-+'
        $format = "| {0,-$($w[0])} | {1,-$($w[1])} | {2,-$($w[2])} |"
        Write-Host $border
        Write-Host ($format -f 'Resource', 'URL / Endpoint', 'Credentials')
        Write-Host $border
        foreach ($row in $rows) { Write-Host ($format -f $row[0], $row[1], $row[2]) }
        Write-Host $border
    }

    # Host, port, user and database of each data service, as asked by apps, IDEs
    # and database clients running on this machine.
    if ($hostRows.Count -gt 0) {
        $ns = Get-Cfg 'DEVKIT_NAMESPACE'
        Write-Host ''
        Write-Host 'Connect from outside Kubernetes'
        Write-Info 'Apps, IDEs and database clients on this machine use host "localhost" and:'
        foreach ($row in $hostRows) { Write-Host ('      {0,-11} port {1,-6} {2}' -f $row[0], $row[1], $row[2]) }
        Write-Info 'Passwords are in the table above. Ports listen on 127.0.0.1 only: other'
        Write-Info 'machines cannot connect. From a container on this machine use'
        Write-Info '"docker run --network host" (Linux) or host "host.docker.internal" (Docker Desktop).'
        Write-Info "Pods inside the cluster use <service>.${ns}:<port> (e.g. postgresql.${ns}:5432)."
    }

    if ($notReady.Count -gt 0) {
        Write-Host ''
        Write-Warn "Not ready: $($notReady -join ' '). Check the pods with: kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') get pods -A"
        Write-Info 'If the cluster is up but URLs do not answer, restart the port-forwards: .\devkit.ps1 forward start'
    }
}
