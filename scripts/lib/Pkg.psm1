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
        # Non-zero codes that mean "already installed" / "no newer version".
        if (@(0, -1978335135, -1978335189) -contains $LASTEXITCODE) { return }
        Write-Warn "winget failed with exit code $LASTEXITCODE"
        if (-not ((Test-Command 'choco') -and $ChocoId)) { Stop-Devkit "Could not install $Name." }
        $manager = 'choco'
    }
    if ($manager -eq 'choco' -and $ChocoId) {
        Write-Info "Installing $Name with Chocolatey ($ChocoId)"
        $code = Invoke-Elevated "choco install $ChocoId -y --no-progress" "Chocolatey installs system-wide"
        if ($code -ne 0) { Stop-Devkit "Chocolatey failed to install $Name (exit $code)." }
        return
    }
    Stop-Devkit "Neither winget nor Chocolatey is available to install $Name. Install App Installer from the Microsoft Store (winget) and retry."
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

Export-ModuleMember -Function *
