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

    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_DASHBOARD')) {
        & $add 'Kubernetes Dashboard' "http://localhost:$(& $port 'dashboard')" '(no login)' 'dashboard' 'dashboard'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_RABBITMQ')) {
        $u = Get-Cfg 'DEVKIT_RABBITMQ_USER'; $p = & $secret (Get-Cfg 'DEVKIT_RABBITMQ_PASSWORD')
        & $add 'RabbitMQ Management' "http://localhost:$(& $port 'rabbitmq-mgmt')" "$u / $p" 'rabbitmq' 'rabbitmq-mgmt'
        & $add 'RabbitMQ AMQP' "amqp://${u}:$p@localhost:$(& $port 'rabbitmq-amqp')/" "$u / $p" 'rabbitmq' 'rabbitmq-amqp'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_MONGODB')) {
        $u = Get-Cfg 'DEVKIT_MONGODB_USER'; $p = & $secret (Get-Cfg 'DEVKIT_MONGODB_PASSWORD')
        & $add 'MongoDB' "mongodb://${u}:$p@localhost:$(& $port 'mongodb')/$(Get-Cfg 'DEVKIT_MONGODB_DATABASE')?authSource=admin" "$u / $p" 'mongodb' 'mongodb'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_POSTGRESQL')) {
        $u = Get-Cfg 'DEVKIT_POSTGRESQL_USER'; $p = & $secret (Get-Cfg 'DEVKIT_POSTGRESQL_PASSWORD')
        & $add 'PostgreSQL' "postgresql://${u}:$p@localhost:$(& $port 'postgresql')/$(Get-Cfg 'DEVKIT_POSTGRESQL_DATABASE')" "$u / $p" 'postgresql' 'postgresql'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_MYSQL')) {
        $u = Get-Cfg 'DEVKIT_MYSQL_USER'; $p = & $secret (Get-Cfg 'DEVKIT_MYSQL_PASSWORD'); $r = & $secret (Get-Cfg 'DEVKIT_MYSQL_ROOT_PASSWORD')
        & $add 'MySQL' "mysql://${u}:$p@localhost:$(& $port 'mysql')/$(Get-Cfg 'DEVKIT_MYSQL_DATABASE')" "$u / $p (root: $r)" 'mysql' 'mysql'
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_REDIS')) {
        $p = & $secret (Get-Cfg 'DEVKIT_REDIS_PASSWORD')
        & $add 'Redis' "redis://:$p@localhost:$(& $port 'redis')" "password: $p" 'redis' 'redis'
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

    if ($notReady.Count -gt 0) {
        Write-Host ''
        Write-Warn "Not ready: $($notReady -join ' '). Check the pods with: kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') get pods -A"
        Write-Info 'If the cluster is up but URLs do not answer, restart the port-forwards: .\devkit.ps1 forward start'
    }
}
