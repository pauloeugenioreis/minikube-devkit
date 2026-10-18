# Offline unit tests for the PowerShell implementation (no cluster, no network).
# Run: pwsh -File tests/unit/windows.ps1   (or .\devkit.ps1 test unit)
# Works on Windows PowerShell 5.1 and PowerShell 7 (also on Linux/macOS for CI).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach ($module in @('Common', 'Prompt', 'Pkg', 'State')) {
    Import-Module (Join-Path $root "scripts/windows/lib/$module.psm1") -Force -DisableNameChecking
}
Initialize-Devkit -Root $root
Import-DevkitConfig

$script:Passed = 0
$script:Failed = 0
function Pass { $script:Passed++ }
function Fail { param([string] $Message) $script:Failed++; Write-Host "  FAIL: $Message" }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -eq $Expected) { Pass } else { Fail "$Message (expected [$Expected], got [$Actual])" } }
function Assert-True { param([bool] $Condition, [string] $Message) if ($Condition) { Pass } else { Fail $Message } }
function Assert-Throws { param([scriptblock] $Block, [string] $Message) try { & $Block | Out-Null; Fail $Message } catch { Pass } }

# Dot-source the dependency and cluster modules like devkit.ps1 does.
. (Join-Path $root 'scripts/windows/deps/deps.ps1')
. (Join-Path $root 'scripts/windows/deps/core.ps1')
. (Join-Path $root 'scripts/windows/deps/drivers/drivers.ps1')
foreach ($driverModule in Get-DriverModuleFiles) { . $driverModule }
foreach ($m in @('Cluster', 'Components', 'Forward', 'Access', 'Examples')) { . (Join-Path $root "scripts/windows/cluster/$m.ps1") }

# ------------------------------------------------------- driver contract ---
foreach ($driver in @('docker', 'hyperv', 'virtualbox', 'podman')) {
    $id = "driver_$driver"
    Assert-True ($script:Dependencies.Contains($id)) "driver $driver is not registered"
    if ($script:Dependencies.Contains($id)) {
        # Configure may legitimately be empty (e.g. virtualbox).
        foreach ($block in @('Check', 'Install')) {
            $sb = $script:Dependencies[$id][$block]
            Assert-True ($null -ne $sb -and $sb.ToString().Trim() -ne '') "driver $driver has an empty $block block"
        }
    }
}
foreach ($id in $script:CoreDeps) {
    Assert-True ($script:Dependencies.Contains($id)) "$id is not registered"
    if ($script:Dependencies.Contains($id)) { Assert-True ($null -ne $script:Dependencies[$id].Update) "$id has no Update block" }
}

# --------------------------------------------------------------- versions ---
Assert-True (Test-VersionAtLeast 'v1.38.1' 'v1.34.0') 'v1.38.1 >= v1.34.0'
Assert-True (-not (Test-VersionAtLeast '1.9.0' '1.10.0')) '1.9.0 < 1.10.0'
Assert-True (Test-VersionAtLeast 'v3.20.1+gabc' 'v3.12.0') 'build suffix ignored'
Assert-True (-not (Test-VersionAtLeast '2.0' '2.0.1')) '2.0 < 2.0.1'
$r = New-VersionResult 'v1.38.1' 'v1.39.0'
Assert-Equal $r.Update 'v1.39.0' 'New-VersionResult flags an update'
$r = New-VersionResult 'v1.39.0' 'v1.39.0'
Assert-Equal $r.Update '' 'New-VersionResult: up to date'

# ----------------------------------------------------------------- config ---
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("devkit-unit-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'config') -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $tmp 'config/devkit.env'), "# comment`nDEVKIT_A=plain`r`nDEVKIT_B=`"quoted value`"`nDEVKIT_C=x=y#z`nnot valid`n")
    Initialize-Devkit -Root $tmp
    Import-DevkitConfig 6>$null
    Assert-Equal (Get-Cfg 'DEVKIT_A') 'plain' 'config: CRLF is stripped'
    Assert-Equal (Get-Cfg 'DEVKIT_B') 'quoted value' 'config: quotes are removed'
    Assert-Equal (Get-Cfg 'DEVKIT_C') 'x=y#z' 'config: value keeps = and #'
    $env:DEVKIT_A = 'env'
    Assert-Equal (Get-Cfg 'DEVKIT_A') 'env' 'config: environment wins'
    Remove-Item Env:\DEVKIT_A

    Save-Cfg 'DEVKIT_A' 'p\a&ss=#1'
    Save-Cfg 'DEVKIT_NEW' 'new'
    $lines = @(Get-Content (Join-Path $tmp 'config/devkit.env'))
    Assert-Equal $lines[0] '# comment' 'Save-Cfg keeps comments'
    Assert-Equal $lines[1] 'DEVKIT_A=p\a&ss=#1' 'Save-Cfg updates in place'
    Assert-Equal $lines[-1] 'DEVKIT_NEW=new' 'Save-Cfg appends new keys'

    # State lists keep spaces and have no duplicates.
    Add-StateListItem 'INSTALLED_BINS' 'C:\Users\Jane Doe\bin\kubectl.exe'
    Add-StateListItem 'INSTALLED_BINS' 'C:\tools\helm.exe'
    Add-StateListItem 'INSTALLED_BINS' 'C:\Users\Jane Doe\bin\kubectl.exe'
    $items = @(Get-StateList 'INSTALLED_BINS')
    Assert-Equal $items.Count 2 'state list: no duplicates'
    Assert-Equal $items[0] 'C:\Users\Jane Doe\bin\kubectl.exe' 'state list: keeps spaces'
} finally {
    Initialize-Devkit -Root $root
    Import-DevkitConfig
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------- templates ---
$tpl = [IO.Path]::GetTempFileName()
try {
    Set-Cfg 'DEVKIT_T1' 'p&a\ss/${x}'
    Set-Cfg 'DEVKIT_T2' '*?[]$1'
    [IO.File]::WriteAllText($tpl, 'a=${DEVKIT_T1} b=${DEVKIT_T2}${DEVKIT_T1} keep=$HOME $(X) ${OTHER}')
    Assert-Equal (Get-RenderedTemplate $tpl) 'a=p&a\ss/${x} b=*?[]$1p&a\ss/${x} keep=$HOME $(X) ${OTHER}' 'Get-RenderedTemplate: literal values'
    [IO.File]::WriteAllText($tpl, 'x=${DEVKIT_UNDEFINED_KEY}')
    Assert-Throws { Get-RenderedTemplate $tpl } 'unknown placeholder must fail'
} finally {
    Remove-Item -LiteralPath $tpl -Force -ErrorAction SilentlyContinue
}

Set-Cfg 'DEVKIT_PRODUCER_NAME' 'test'; Set-Cfg 'DEVKIT_PRODUCER_MODE' 'redis-produce'; Set-Cfg 'DEVKIT_PRODUCER_COUNT' '1'
$templates = @(Get-ChildItem (Join-Path $root 'k8s') -Recurse -Include *.yaml, *.env) + @(Get-ChildItem (Join-Path $root 'examples/k8s') -Include *.yaml, *.env -Recurse)
foreach ($t in $templates) {
    try { [void] (Get-RenderedTemplate $t.FullName); Pass } catch { Fail "template does not render: $($t.Name)" }
}
foreach ($svc in $script:DataServices) {
    foreach ($f in @('manifest.yaml', 'credentials.env', 'shell.sh', 'smoke.sh')) {
        Assert-True (Test-Path (Join-Path $root "k8s/$($svc.Id)/$f")) "k8s/$($svc.Id)/$f is missing"
    }
}

# A bare -- passed to a PowerShell function is swallowed by the parser, so
# "kubectl exec pod -- sh -c" through Invoke-Kube must quote it.
$bare = Get-ChildItem (Join-Path $root 'scripts/windows') -Recurse -Include *.ps1, *.psm1 | Select-String -Pattern 'Invoke-Kube .* -- '
Assert-True (-not $bare) "unquoted -- passed to Invoke-Kube: $(@($bare) -join '; ')"

# Both implementations know the same components and drivers.
$bashServices = [regex]::Matches((Get-Content (Join-Path $root 'scripts/unix/cluster/components.sh') -Raw), "(?m)^(?:DATA_SERVICES=')?([a-z]+)\|DEVKIT_INSTALL_") | ForEach-Object { $_.Groups[1].Value }
Assert-Equal (($script:DataServices | ForEach-Object { $_.Id }) -join ',') (@($bashServices) -join ',') 'same data services in Bash and PowerShell'

Write-Host ''
Write-Host "  $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
