# Dependency runner. Each dependency registers four script blocks:
#
#   Label      human readable name
#   Check      returns New-DepResult (Ok, Status, Unfixable)
#   Install    installs the dependency (no-op when already installed)
#   Configure  configures/starts it; may call Exit-Pending
#   Update     optional: replaces an older but usable version. Check signals
#              it by returning Ok with Update set to the new version.
#
# Every block must be idempotent so a run can be repeated or resumed.

$script:Dependencies = [ordered] @{}

function Register-Dependency {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [scriptblock] $Check,
        [scriptblock] $Install = { },
        [scriptblock] $Configure = { },
        [scriptblock] $Update = $null
    )
    $script:Dependencies[$Id] = @{ Id = $Id; Label = $Label; Check = $Check; Install = $Install; Configure = $Configure; Update = $Update }
}

function New-DepResult {
    param([bool] $Ok, [string] $Status, [bool] $Unfixable = $false, [string] $Current = '', [string] $Update = '')
    [pscustomobject] @{ Ok = $Ok; Status = $Status; Unfixable = $Unfixable; Current = $Current; Update = $Update }
}

# Ok result for an installed version, flagging a newer one when available.
function New-VersionResult {
    param([string] $Current, [string] $Latest, [string] $Prefix = '')
    if ($Latest -and -not (Test-VersionAtLeast $Current $Latest)) {
        return New-DepResult $true "ok ($Prefix$Current, update available: $Latest)" -Current $Current -Update $Latest
    }
    return New-DepResult $true "ok ($Prefix$Current)" -Current $Current
}

function Get-Dependency {
    param([Parameter(Mandatory)] [string] $Id)
    if (-not $script:Dependencies.Contains($Id)) { Stop-Devkit "Unknown dependency: $Id" }
    $script:Dependencies[$Id]
}

function Invoke-DepCheck {
    param([Parameter(Mandatory)] [string] $Id)
    $result = & (Get-Dependency $Id).Check
    # Guard against script blocks that leak extra pipeline output.
    @($result)[-1]
}

# Prints the status of each dependency and returns the IDs that are not ready.
function Show-DepReport {
    param([Parameter(Mandatory)] [string[]] $Ids)
    $missing = @()
    foreach ($id in $Ids) {
        $dep = Get-Dependency $id
        $result = Invoke-DepCheck $id
        $line = '{0,-16} {1}' -f $dep.Label, $result.Status
        if ($result.Ok) { Write-Ok $line } else { Write-Err $line; $missing += $id }
    }
    return , $missing
}

# Checks everything, asks for consent once, then installs and configures
# what is missing and verifies the result.
function Install-Dependencies {
    param([Parameter(Mandatory)] [string[]] $Ids)

    Write-Step 'Checking prerequisites'
    $missing = Show-DepReport $Ids
    if ($missing.Count -gt 0) { Install-MissingDependencies $missing }
    Update-Dependencies $Ids
}

function Install-MissingDependencies {
    param([Parameter(Mandatory)] [string[]] $Missing)

    $unfixable = @()
    foreach ($id in $missing) {
        $result = Invoke-DepCheck $id
        if ($result.Unfixable) { $unfixable += "    - $((Get-Dependency $id).Label): $($result.Status)" }
    }
    if ($unfixable.Count -gt 0) {
        Stop-Devkit ("These problems cannot be fixed automatically:`n" + ($unfixable -join "`n"))
    }

    Write-Step 'The following will be installed or configured'
    foreach ($id in $missing) {
        Write-Info "- $((Get-Dependency $id).Label) ($((Invoke-DepCheck $id).Status))"
    }
    Write-Host ''
    if (-not (Read-YesNo 'Proceed?' 'Y')) { Stop-Devkit 'Aborted by user.' }

    foreach ($id in $missing) {
        $dep = Get-Dependency $id
        Write-Step "Setting up $($dep.Label)"
        & $dep.Install | Out-Null
        & $dep.Configure | Out-Null
        $result = Invoke-DepCheck $id
        if (-not $result.Ok) { Stop-Devkit "$($dep.Label) is still not ready: $($result.Status)" }
        Write-Ok "$($dep.Label): $($result.Status)"
    }
}

# Asks, per dependency, whether to update an older installed version.
function Update-Dependencies {
    param([Parameter(Mandatory)] [string[]] $Ids)
    foreach ($id in $Ids) {
        $dep = Get-Dependency $id
        if ($null -eq $dep.Update) { continue }
        $result = Invoke-DepCheck $id
        if (-not $result.Ok -or -not $result.Update) { continue }
        Write-Host ''
        if (Read-YesNo "Update $($dep.Label) $($result.Current) to the latest $($result.Update)?" 'Y') {
            Write-Step "Updating $($dep.Label) to $($result.Update)"
            & $dep.Update | Out-Null
            & $dep.Configure | Out-Null
            $after = Invoke-DepCheck $id
            if (-not $after.Ok) { Stop-Devkit "$($dep.Label) is not ready after the update: $($after.Status)" }
            Write-Ok "$($dep.Label): $($after.Status)"
        } else {
            Write-Info "Keeping $($dep.Label) $($result.Current)."
        }
    }
}
