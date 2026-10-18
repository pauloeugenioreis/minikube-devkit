# devkit info: prints URLs and credentials of the installed components.

function Invoke-Info {
    param([string[]] $Arguments = @())
    $noSecrets = $false
    foreach ($arg in $Arguments) {
        switch -Regex ($arg) {
            '^(--no-secrets|-NoSecrets)$' { $noSecrets = $true }
            '^(-h|--help|-Help)$' { Write-Host 'Usage: .\devkit.ps1 info [-NoSecrets]'; return 0 }
            default { Stop-Devkit "Unknown option for info: $arg" }
        }
    }
    if (-not ((Test-ClusterExists) -and (Test-ClusterRunning))) {
        Stop-Devkit "Cluster '$(Get-Cfg 'DEVKIT_PROFILE')' is not running. Start it with: .\devkit.ps1 up"
    }
    Write-Host ''
    Show-AccessTable -NoSecrets:$noSecrets
    return 0
}
