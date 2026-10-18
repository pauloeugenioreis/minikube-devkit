# devkit uninstall: removes what minikube-devkit itself installed, as recorded
# in .devkit\state (binaries, packages, PATH entries), plus the KEDA Helm
# repository, the minikube cache (only when no other minikube profile exists),
# and devkit's own state and logs. Tools that were already installed before
# devkit are never touched.

function Get-OtherMinikubeProfiles {
    $dir = Join-Path (Get-MinikubeDir) 'profiles'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -ne (Get-Cfg 'DEVKIT_PROFILE') } | ForEach-Object { $_.Name })
}

function Test-KedaHelmRepo {
    if (-not (Test-Command 'helm')) { return $false }
    return [bool] (& helm repo list 2>$null | Select-String -Pattern '^kedacore')
}

function Show-UninstallPlan {
    Write-Step 'minikube-devkit will remove'
    foreach ($item in @(Get-StateList 'INSTALLED_BINS')) { Write-Info "- binary   $item" }
    foreach ($item in @(Get-StateList 'INSTALLED_PKGS')) { $m, $id = $item -split ':', 2; Write-Info "- package  $id ($m)" }
    foreach ($item in @(Get-StateList 'INSTALLED_PATHS')) { Write-Info "- PATH     $item" }
    if (Test-KedaHelmRepo) { Write-Info '- helm repo kedacore' }
    $others = @(Get-OtherMinikubeProfiles)
    if ($others.Count -eq 0) {
        Write-Info "- minikube cache and configuration ($(Get-MinikubeDir))"
    } else {
        Write-Info "  (keeping $(Get-MinikubeDir): other minikube profiles exist: $($others -join ', '))"
    }
    Write-Info '- devkit state (.devkit\) and logs (log\)'
}

function Invoke-UninstallAll {
    Show-UninstallPlan
    Write-Host ''
    if (-not (Read-YesNo 'Uninstall all of the above?' 'N')) { Write-Info 'Nothing was uninstalled.'; return }

    Stop-AllForwards
    # Use the tools before removing them.
    if (Test-KedaHelmRepo) {
        & helm repo remove kedacore *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Removed helm repo kedacore' }
    }
    if (@(Get-OtherMinikubeProfiles).Count -eq 0 -and (Test-Command 'minikube')) {
        & minikube delete --all --purge *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Removed the minikube cache ($(Get-MinikubeDir))" }
    }

    foreach ($item in @(Get-StateList 'INSTALLED_BINS')) {
        if (-not (Test-Path -LiteralPath $item)) { continue }
        Remove-Item -LiteralPath $item -Force
        Write-Ok "Removed $item"
    }
    foreach ($item in @(Get-StateList 'INSTALLED_PKGS')) {
        $id = ($item -split ':', 2)[1]
        if (Remove-DevkitPackage $item) { Write-Ok "Removed package $id" } else { Write-Warn "Could not remove $id" }
    }
    foreach ($item in @(Get-StateList 'INSTALLED_PATHS')) {
        Remove-FromUserPath $item
        Write-Ok "Removed $item from your user PATH"
    }

    $stateDir = Get-DevkitStateDir
    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }
    Get-ChildItem -LiteralPath (Get-DevkitLogDir) -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Recurse -Force
    Write-Ok 'Removed devkit state and logs'

    Write-Host ''
    Write-Info 'Not reverted: Windows features (WSL 2, Hyper-V), group memberships (docker-users, Hyper-V Administrators) and config\devkit.env.'
}

function Invoke-Uninstall {
    param([string[]] $Arguments = @())
    if ($Arguments.Count -gt 0) { Write-Host 'Usage: .\devkit.ps1 uninstall [-Yes]'; return }
    if (Test-ClusterExists) {
        Stop-Devkit "Cluster '$(Get-Cfg 'DEVKIT_PROFILE')' still exists. Run '.\devkit.ps1 destroy' first (it can uninstall too)."
    }
    Invoke-UninstallAll
    return
}
