# Persistent run state, used to resume after steps that need a re-login or a
# reboot (e.g. enabling WSL 2, joining docker-users). Stored in .devkit/state
# using the same KEY=value format as the Bash implementation.

Set-StrictMode -Version 2.0

function Get-StateFile { Join-Path (Get-DevkitStateDir) 'state' }

function Read-StateLines {
    $file = Get-StateFile
    if (Test-Path -LiteralPath $file) { return @(Get-Content -LiteralPath $file) }
    return @()
}

function Get-State {
    param([Parameter(Mandatory)] [string] $Key)
    $match = Read-StateLines | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1
    if ($match) { return $match.Substring($Key.Length + 1) }
    return ''
}

function Set-State {
    param([Parameter(Mandatory)] [string] $Key, [string] $Value)
    $dir = Get-DevkitStateDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $lines = @(Read-StateLines | Where-Object { $_ -notlike "$Key=*" }) + "$Key=$Value"
    [IO.File]::WriteAllText((Get-StateFile), (($lines -join "`n") + "`n"))
}

function Remove-State {
    param([Parameter(Mandatory)] [string] $Key)
    $file = Get-StateFile
    if (-not (Test-Path -LiteralPath $file)) { return }
    $lines = @(Read-StateLines | Where-Object { $_ -notlike "$Key=*" })
    [IO.File]::WriteAllText($file, (($lines -join "`n") + "`n"))
}

# Reports a pending action left by a previous run and clears it; the checks
# that follow are idempotent and detect whether it was really completed.
function Resume-State {
    $action = Get-State 'PENDING_ACTION'
    if (-not $action) { return }
    Write-Step 'Resuming previous setup'
    Write-Info "The last run required a ${action}: $(Get-State 'PENDING_REASON')"
    Remove-State 'PENDING_ACTION'
    Remove-State 'PENDING_REASON'
}

# Records the pending action, prints instructions and exits with the pending code.
function Exit-Pending {
    param([Parameter(Mandatory)] [ValidateSet('relogin', 'reboot')] [string] $Action, [Parameter(Mandatory)] [string] $Reason)
    Set-State 'PENDING_ACTION' $Action
    Set-State 'PENDING_REASON' $Reason
    Write-Host ''
    Write-Warn $Reason
    if ($Action -eq 'reboot') {
        Write-Info 'Restart Windows, then run the same command again to continue.'
    } else {
        Write-Info 'Sign out of Windows and back in, then run the same command again to continue.'
    }
    exit (Get-ExitPendingCode)
}

# ------------------------------------------------- what devkit installed ---
# "|"-separated lists (paths may contain spaces), so "uninstall" only removes
# what devkit itself added:
#   INSTALLED_PKGS   manager:package entries (winget:Docker.DockerDesktop, choco:...)
#   INSTALLED_BINS   binaries copied into the devkit bin directory
#   INSTALLED_PATHS  directories devkit added to the user PATH

function Get-StateList {
    param([Parameter(Mandatory)] [string] $Key)
    $value = Get-State $Key
    if (-not $value) { return @() }
    return @($value -split '\|' | Where-Object { $_ })
}

function Add-StateListItem {
    param([Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] [string] $Item)
    $items = Get-StateList $Key
    if ($items -contains $Item) { return }
    Set-State $Key ((@($items) + $Item) -join '|')
}

function Clear-AllState {
    $file = Get-StateFile
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

Export-ModuleMember -Function *
