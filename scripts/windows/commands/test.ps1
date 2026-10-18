# devkit test smoke|keda|unit|all
#   smoke  every installed component answers: authenticated checks inside the
#          pods (k8s\<service>\smoke.sh), port-forwards, Dashboard, RabbitMQ
#          API, KEDA metrics API and the example ScaledObjects
#   keda   sends messages and checks the example workers scale 0 -> N -> 0
#   unit   offline tests of the scripts themselves (no cluster needed)

$script:TestFailed = 0

function Write-TestOk { param([string] $Message) Write-Ok $Message }
function Write-TestFail { param([string] $Message) Write-Err $Message; $script:TestFailed++ }

# Expects HTTP 200; -BasicAuth takes "user:password" (development credentials).
function Test-HttpOk {
    param([string] $Name, [string] $Url, [string] $BasicAuth = '')
    try {
        $params = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = 10; ErrorAction = 'Stop' }
        if ($BasicAuth) {
            $params.Headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BasicAuth)) }
        }
        $code = (Invoke-WebRequest @params).StatusCode
    } catch { $code = 'error' }
    if ($code -eq 200) { Write-TestOk "$Name answers on $Url" } else { Write-TestFail "${Name}: HTTP $code from $Url" }
}

function Invoke-SmokeTests {
    Write-Step 'Smoke tests'
    Assert-ClusterRunning
    $ns = Get-Cfg 'DEVKIT_NAMESPACE'
    foreach ($svc in $script:DataServices) {
        if (-not (Test-True (Get-Cfg $svc.Key))) { continue }
        if (-not (Test-ComponentReady $svc.Id)) { Write-TestFail "$($svc.Label): pod is not ready"; continue }
        $command = ([IO.File]::ReadAllText((Join-Path (Get-DevkitRoot) "k8s/$($svc.Id)/smoke.sh"))).Trim()
        # '--' must be quoted: a bare -- is consumed by PowerShell when calling a function.
        Invoke-Kube -n $ns exec "$($svc.Id)-0" '--' sh -c $command *> $null
        if ($LASTEXITCODE -eq 0) { Write-TestOk "$($svc.Label): authenticated check passed" }
        else { Write-TestFail "$($svc.Label): authenticated check failed (see .\devkit.ps1 logs $($svc.Id))" }
    }
    foreach ($spec in Get-ForwardSpecs) {
        if (-not (Test-ComponentEnabled $spec.Component)) { continue }
        $port = Get-ForwardPort $spec
        if (Test-PortInUse $port) { Write-TestOk "port-forward $($spec.Name) on localhost:$port" }
        else { Write-TestFail "port-forward $($spec.Name): nothing listening on localhost:$port (.\devkit.ps1 forward start)" }
    }
    $specs = @{}
    foreach ($s in Get-ForwardSpecs) { $specs[$s.Name] = $s }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_DASHBOARD')) {
        Test-HttpOk 'Kubernetes Dashboard' "http://localhost:$(Get-ForwardPort $specs['dashboard'])/"
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_RABBITMQ')) {
        Test-HttpOk -Name 'RabbitMQ Management API' -Url "http://localhost:$(Get-ForwardPort $specs['rabbitmq-mgmt'])/api/overview" `
            -BasicAuth "$(Get-Cfg 'DEVKIT_RABBITMQ_USER'):$(Get-Cfg 'DEVKIT_RABBITMQ_PASSWORD')"
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_KEDA')) {
        if (Test-ComponentReady 'keda') { Write-TestOk 'KEDA operator is ready' } else { Write-TestFail 'KEDA operator is not ready' }
        $available = (Invoke-Kube get apiservice v1beta1.external.metrics.k8s.io -o 'jsonpath={.status.conditions[?(@.type=="Available")].status}' 2>$null) -join ''
        if ($available -eq 'True') { Write-TestOk 'KEDA external metrics API is available' } else { Write-TestFail 'KEDA external metrics API is not available' }
        $examplesNs = Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE'
        foreach ($name in @('rabbitmq-worker', 'redis-worker', 'cron-demo')) {
            if ($name -eq 'rabbitmq-worker' -and -not (Test-ComponentEnabled 'rabbitmq')) { continue }
            if ($name -eq 'redis-worker' -and -not (Test-ComponentEnabled 'redis')) { continue }
            $ready = (Invoke-Kube -n $examplesNs get scaledobject $name -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>$null) -join ''
            if ($ready -eq 'True') { Write-TestOk "ScaledObject $name is ready" }
            else { Write-TestFail "ScaledObject $name is not ready (kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') -n $examplesNs describe scaledobject $name)" }
        }
    }
}

# Waits until the replica count matches; returns the last count seen and whether it matched.
function Wait-Replicas {
    param([string] $Deployment, [ValidateSet('ge', 'eq')] [string] $Compare, [int] $Want, [int] $TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $n = Get-ExamplesReplicas $Deployment
        if (($Compare -eq 'ge' -and $n -ge $Want) -or ($Compare -eq 'eq' -and $n -eq $Want)) { return @{ Ok = $true; Count = $n } }
        if ((Get-Date) -ge $deadline) { return @{ Ok = $false; Count = $n } }
        Start-Sleep -Seconds 5
    }
}

function Invoke-KedaTests {
    Write-Step 'KEDA autoscaling (0 -> N -> 0)'
    Assert-ClusterRunning
    if (-not (Test-True (Get-Cfg 'DEVKIT_INSTALL_KEDA'))) { Write-TestFail 'KEDA is not enabled in config\devkit.env'; return }
    foreach ($target in @('rabbitmq', 'redis')) {
        if (-not (Test-ComponentEnabled $target)) { Write-Info "$target not installed; skipping its example."; continue }
        $deploy = "$target-worker"
        Write-Info "${deploy}: waiting for it to be at 0 replicas"
        if (-not (Wait-Replicas $deploy 'eq' 0 300).Ok) { Write-TestFail "$deploy did not start at 0 replicas"; continue }
        $start = Get-Date
        if (-not (Invoke-ExamplesProducer $target 50)) { Write-TestFail "${target}: producer failed"; continue }
        $out = Wait-Replicas $deploy 'ge' 1 120
        if (-not $out.Ok) { Write-TestFail "$deploy did not scale out within 120s"; continue }
        Write-TestOk "$deploy scaled out to $($out.Count) replica(s) in $([int] ((Get-Date) - $start).TotalSeconds)s"
        Start-Sleep -Seconds 10
        Write-Info "${deploy}: $(Get-ExamplesReplicas $deploy) replica(s) working through the backlog"
        $start = Get-Date
        if ((Wait-Replicas $deploy 'eq' 0 300).Ok) { Write-TestOk "$deploy scaled back to 0 in $([int] ((Get-Date) - $start).TotalSeconds)s" }
        else { Write-TestFail "$deploy did not scale back to 0 within 300s" }
    }
}

function Invoke-UnitTests {
    Write-Step 'Unit tests (PowerShell)'
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoProfile -File (Join-Path (Get-DevkitRoot) 'tests/unit/windows.ps1')
    if ($LASTEXITCODE -eq 0) { Write-TestOk 'unit tests passed' } else { Write-TestFail 'unit tests failed' }
}

function Invoke-Test {
    param([string[]] $Arguments = @())
    $script:TestFailed = 0
    $suite = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    switch ($suite) {
        'smoke' { Invoke-SmokeTests }
        'keda' { Invoke-KedaTests }
        'unit' { Invoke-UnitTests }
        'all' { Invoke-UnitTests; Invoke-SmokeTests; Invoke-KedaTests }
        default { Write-Host 'Usage: .\devkit.ps1 test smoke|keda|unit|all'; return }
    }
    Write-Host ''
    if ($script:TestFailed -gt 0) { Write-Err "$($script:TestFailed) check(s) failed."; $script:DevkitExitCode = 1; return }
    Write-Ok 'All checks passed.'
    return
}
