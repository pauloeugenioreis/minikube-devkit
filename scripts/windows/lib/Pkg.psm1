# Package manager abstraction for Windows: winget first, Chocolatey as fallback.

Set-StrictMode -Version 2.0

function Get-PackageManager {
    if (Test-Command 'winget') { return 'winget' }
    if (Test-Command 'choco') { return 'choco' }
    return 'none'
}

# Installs a package. Ids are given per manager because they differ.
function Install-DevkitPackage {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $WingetId = '',
        [string] $ChocoId = ''
    )
    $manager = Get-PackageManager
    if ($manager -eq 'winget' -and $WingetId) {
        Write-Info "Installing $Name with winget ($WingetId)"
        Write-DebugLine "> winget install -e --id $WingetId"
        & winget install -e --id $WingetId --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
        if ($LASTEXITCODE -eq 0) { Add-StateListItem 'INSTALLED_PKGS' "winget:$WingetId"; return }
        # Non-zero codes that mean "already installed" / "no newer version".
        if (@(-1978335135, -1978335189) -contains $LASTEXITCODE) { return }
        Write-Warn "winget failed with exit code $LASTEXITCODE"
        if (-not ((Test-Command 'choco') -and $ChocoId)) { Stop-Devkit "Could not install $Name." }
        $manager = 'choco'
    }
    if ($manager -eq 'choco' -and $ChocoId) {
        Write-Info "Installing $Name with Chocolatey ($ChocoId)"
        $code = Invoke-Elevated "choco install $ChocoId -y --no-progress" "Chocolatey installs system-wide"
        if ($code -ne 0) { Stop-Devkit "Chocolatey failed to install $Name (exit $code)." }
        Add-StateListItem 'INSTALLED_PKGS' "choco:$ChocoId"
        return
    }
    Stop-Devkit "Neither winget nor Chocolatey is available to install $Name. Install App Installer from the Microsoft Store (winget) and retry."
}

# Uninstalls a "manager:id" entry recorded by Install-DevkitPackage.
function Remove-DevkitPackage {
    param([Parameter(Mandatory)] [string] $Entry)
    $manager, $id = $Entry -split ':', 2
    switch ($manager) {
        'winget' {
            & winget uninstall -e --id $id --silent --disable-interactivity --accept-source-agreements
            return ($LASTEXITCODE -eq 0)
        }
        'choco' { return ((Invoke-Elevated "choco uninstall $id -y" "Chocolatey uninstalls system-wide") -eq 0) }
        default { Write-Warn "Unknown package manager '$manager' for $id; skipping."; return $false }
    }
}

# Removes a directory from the user PATH (registry) and the session PATH.
function Remove-FromUserPath {
    param([Parameter(Mandatory)] [string] $Directory)
    $env:PATH = (@($env:PATH -split [regex]::Escape([IO.Path]::PathSeparator) | Where-Object { $_ -and $_ -ne $Directory })) -join [IO.Path]::PathSeparator
    if (-not (Test-IsWindowsHost)) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { return }
    $kept = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $Directory })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
}

# Re-reads PATH from the registry so freshly installed tools are visible.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $current = @($env:PATH -split ';' | Where-Object { $_ })
    $merged = @($current)
    foreach ($entry in (@($machine -split ';') + @($user -split ';'))) {
        if ($entry -and ($merged -notcontains $entry)) { $merged += $entry }
    }
    $env:PATH = $merged -join ';'
}

# Returns @{ Current; Available } when winget (or Chocolatey) offers a newer
# version of an installed package, or $null when it is up to date or not
# managed by them.
function Get-PackageUpdate {
    param([string] $WingetId = '', [string] $ChocoId = '')
    if ($WingetId -and (Test-Command 'winget')) {
        $lines = & winget list -e --id $WingetId --upgrade-available --accept-source-agreements --disable-interactivity 2>$null
        if ($LASTEXITCODE -eq 0) {
            # Row layout: Name  Id  Version  Available  Source
            $row = @($lines | Where-Object { $_ -match [regex]::Escape($WingetId) }) | Select-Object -First 1
            if ($row) {
                $tokens = @(($row -split '\s+') | Where-Object { $_ })
                $idx = [Array]::IndexOf($tokens, $WingetId)
                if ($idx -ge 0 -and $tokens.Count -gt $idx + 2) {
                    return [pscustomobject] @{ Current = $tokens[$idx + 1]; Available = $tokens[$idx + 2] }
                }
            }
        }
    }
    if ($ChocoId -and (Test-Command 'choco')) {
        foreach ($line in (& choco outdated -r 2>$null)) {
            $parts = $line -split '\|'
            if ($parts.Count -ge 3 -and $parts[0] -eq $ChocoId) {
                return [pscustomobject] @{ Current = $parts[1]; Available = $parts[2] }
            }
        }
    }
    return $null
}

# Upgrades a package with the manager that has it (winget first, then Chocolatey).
function Update-DevkitPackage {
    param([Parameter(Mandatory)] [string] $Name, [string] $WingetId = '', [string] $ChocoId = '')
    if ($WingetId -and (Test-Command 'winget')) {
        Write-Info "Upgrading $Name with winget ($WingetId)"
        & winget upgrade -e --id $WingetId --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
        if (@(0, -1978335189) -contains $LASTEXITCODE) { Update-SessionPath; return }
        Write-Warn "winget upgrade failed with exit code $LASTEXITCODE"
    }
    if ($ChocoId -and (Test-Command 'choco')) {
        $code = Invoke-Elevated "choco upgrade $ChocoId -y --no-progress" 'Chocolatey upgrades system-wide'
        if ($code -eq 0) { Update-SessionPath; return }
    }
    Stop-Devkit "Could not upgrade $Name."
}

Export-ModuleMember -Function *
