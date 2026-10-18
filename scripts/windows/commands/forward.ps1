# devkit forward: manages the background port-forwards.

function Invoke-Forward {
    param([string[]] $Arguments = @())
    $action = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'status' }
    switch -Regex ($action) {
        '^start$' {
            if (-not ((Test-ClusterExists) -and (Test-ClusterRunning))) {
                Stop-Devkit "Cluster '$(Get-Cfg 'DEVKIT_PROFILE')' is not running. Start it with: .\devkit.ps1 up"
            }
            Start-AllForwards
            Show-ForwardStatus
        }
        '^stop$' { Stop-AllForwards; Write-Ok 'Port-forwards stopped' }
        '^restart$' { Stop-AllForwards; return (Invoke-Forward @('start')) }
        '^status$' { Show-ForwardStatus }
        '^(-h|--help|-Help)$' { Write-Host 'Usage: .\devkit.ps1 forward [start|stop|restart|status]' }
        default { Stop-Devkit "Unknown forward action: $action (use start, stop, restart or status)" }
    }
    return 0
}
