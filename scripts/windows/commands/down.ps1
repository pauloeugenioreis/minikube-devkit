# devkit down: stops the port-forwards and the cluster (data is kept).
# devkit destroy: deletes the cluster and all its data, then offers to
# uninstall everything devkit installed.

function Invoke-Down {
    param([string[]] $Arguments = @())
    if ($Arguments.Count -gt 0) { Write-Host 'Usage: .\devkit.ps1 down'; return }
    Write-Step 'Stopping minikube-devkit'
    Stop-AllForwards
    Stop-Cluster
    Write-Ok "Stopped. Your data is kept; run '.\devkit.ps1 up' to start again."
    return
}

function Invoke-Destroy {
    param([string[]] $Arguments = @())
    if ($Arguments.Count -gt 0) { Write-Host 'Usage: .\devkit.ps1 destroy [-Yes]'; return }
    Write-Step 'Destroying minikube-devkit'
    if (-not (Read-YesNo "Delete the '$(Get-Cfg 'DEVKIT_PROFILE')' cluster and ALL its data?" 'N')) { Stop-Devkit 'Aborted by user.' }
    Stop-AllForwards
    Remove-Cluster
    Write-Ok 'Cluster deleted. config\devkit.env was kept.'
    Write-Host ''
    if (Read-YesNo 'Also uninstall everything minikube-devkit installed?' 'N') { Invoke-UninstallAll }
    return
}
