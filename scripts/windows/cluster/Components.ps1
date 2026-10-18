# Deploys the data services from k8s\<component> templates and KEDA via Helm.

# Data services backed by k8s\<id>\, in deploy order.
$script:DataServices = @(
    [pscustomobject] @{ Id = 'rabbitmq'; Key = 'DEVKIT_INSTALL_RABBITMQ'; Label = 'RabbitMQ' }
    [pscustomobject] @{ Id = 'mongodb'; Key = 'DEVKIT_INSTALL_MONGODB'; Label = 'MongoDB' }
    [pscustomobject] @{ Id = 'postgresql'; Key = 'DEVKIT_INSTALL_POSTGRESQL'; Label = 'PostgreSQL' }
    [pscustomobject] @{ Id = 'mysql'; Key = 'DEVKIT_INSTALL_MYSQL'; Label = 'MySQL' }
    [pscustomobject] @{ Id = 'redis'; Key = 'DEVKIT_INSTALL_REDIS'; Label = 'Redis' }
)

# Creates/updates the <id>-credentials Secret and applies the manifest.
function Publish-Component {
    param([Parameter(Mandatory)] [string] $Id)
    $dir = Join-Path (Get-DevkitRoot) "k8s/$Id"
    $ns = Get-Cfg 'DEVKIT_NAMESPACE'
    $credentials = Join-Path $dir 'credentials.env'
    if (Test-Path -LiteralPath $credentials) {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, (Get-RenderedTemplate $credentials))
            $secretYaml = Invoke-Kube create secret generic "$Id-credentials" -n $ns "--from-env-file=$tmp" --dry-run=client -o yaml
            if ($LASTEXITCODE -ne 0) { Stop-Devkit "Could not render the $Id-credentials Secret." }
            Invoke-KubeApply (($secretYaml -join "`n") + "`n")
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    Invoke-KubeApply (Get-RenderedTemplate (Join-Path $dir 'manifest.yaml'))
}

function Publish-Components {
    Write-Step 'Data services'
    Invoke-KubeApply (Get-RenderedTemplate (Join-Path (Get-DevkitRoot) 'k8s/namespace.yaml'))

    # Apply everything first so images are pulled in parallel, then wait.
    $selected = @($script:DataServices | Where-Object { Test-True (Get-Cfg $_.Key) })
    foreach ($svc in $selected) {
        Publish-Component $svc.Id
        Write-Info "Applied $($svc.Label)"
    }
    if ($selected.Count -eq 0) { Write-Info 'No data services selected.'; return }

    $timeout = Get-Cfg 'DEVKIT_DEPLOY_TIMEOUT' '600'
    $ns = Get-Cfg 'DEVKIT_NAMESPACE'
    Write-Info "Waiting for the services to become ready (first run downloads images; up to ${timeout}s each)..."
    foreach ($svc in $selected) {
        Invoke-Kube rollout status "statefulset/$($svc.Id)" -n $ns "--timeout=${timeout}s" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$($svc.Label) is ready"
        } else {
            Write-Err "$($svc.Label) did not become ready. Check: kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') -n $ns describe pod $($svc.Id)-0"
        }
    }
}

function Publish-Keda {
    if (-not (Test-True (Get-Cfg 'DEVKIT_INSTALL_KEDA'))) { return }
    $version = Get-Cfg 'DEVKIT_KEDA_CHART_VERSION'
    Write-Step "KEDA $version"
    & helm repo add kedacore https://kedacore.github.io/charts --force-update *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Devkit 'Could not add the KEDA Helm repository.' }
    & helm repo update kedacore *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Devkit 'Could not update the KEDA Helm repository.' }
    & helm upgrade --install keda kedacore/keda `
        --kube-context (Get-Cfg 'DEVKIT_PROFILE') `
        --namespace keda --create-namespace `
        --version $version `
        --values (Join-Path (Get-DevkitRoot) 'helm/keda-values.yaml') `
        --wait --timeout "$(Get-Cfg 'DEVKIT_DEPLOY_TIMEOUT' '600')s" *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'KEDA is ready'
    } else {
        Write-Err "KEDA did not become ready. Check: kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') -n keda get pods"
    }
}

# True when the component's workload reports ready replicas.
function Test-ComponentReady {
    param([Parameter(Mandatory)] [string] $Id)
    switch ($Id) {
        'dashboard' { $ready = Invoke-Kube -n kubernetes-dashboard get deployment kubernetes-dashboard -o 'jsonpath={.status.readyReplicas}' 2>$null }
        'keda' { $ready = Invoke-Kube -n keda get deployment keda-operator -o 'jsonpath={.status.readyReplicas}' 2>$null }
        default { $ready = Invoke-Kube -n (Get-Cfg 'DEVKIT_NAMESPACE') get statefulset $Id -o 'jsonpath={.status.readyReplicas}' 2>$null }
    }
    $n = 0
    return ([int]::TryParse((($ready -join '').Trim()), [ref] $n) -and $n -ge 1)
}
