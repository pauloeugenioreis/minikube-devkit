# Docker driver dependency (Windows): Docker Desktop on the WSL 2 backend.
#
# Install:   enables WSL 2 (reboot may be required), then installs Docker
#            Desktop with winget (Chocolatey as fallback).
# Configure: makes sure the user is in docker-users (re-login may be
#            required), starts Docker Desktop and waits for the engine.
# Update:    with DEVKIT_DOCKER_VERSION=latest, offers Docker Desktop updates
#            published to winget/Chocolatey.

$script:DockerDesktopDir = [IO.Path]::Combine($script:ProgramFilesDir, 'Docker', 'Docker')
$script:DockerDesktopExe = [IO.Path]::Combine($script:DockerDesktopDir, 'Docker Desktop.exe')

# Exposes the Docker CLI shipped inside Docker Desktop when it is not on PATH.
function Find-DockerCli {
    if (Test-Command 'docker') { return $true }
    $bin = [IO.Path]::Combine($script:DockerDesktopDir, 'resources', 'bin')
    if (Test-Path -LiteralPath ([IO.Path]::Combine($bin, 'docker.exe'))) {
        Add-ToPath $bin
        return $true
    }
    return $false
}

function Test-DockerUsersGroupExists {
    & net.exe localgroup docker-users *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-InDockerUsersGroup {
    $members = & net.exe localgroup docker-users 2>$null
    return [bool] ($members | Where-Object { $_.Trim() -eq $env:USERNAME -or $_.Trim() -eq "$env:USERDOMAIN\$env:USERNAME" })
}

function Test-DockerEngine {
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

$script:DockerUpdateChecked = $false
$script:DockerUpdate = $null

Register-Dependency -Id 'driver_docker' -Label 'docker' `
    -Check {
        if (-not (Find-DockerCli)) {
            if (-not (Test-VirtualizationAvailable)) {
                return New-DepResult $false "not installed, and $script:VirtualizationHint" $true
            }
            return New-DepResult $false 'not installed'
        }
        $versionText = (& docker --version 2>$null) -join ' '
        if ($versionText -match 'podman') {
            return New-DepResult $false "'docker' is the Podman CLI; use -Driver podman" $true
        }
        $output = (& docker info 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            if ($output -match 'Access is denied|permission denied') {
                return New-DepResult $false 'installed, but the current user cannot access the Docker engine'
            }
            return New-DepResult $false 'installed, but the Docker engine is not running'
        }
        $version = ((& docker version --format '{{.Server.Version}}' 2>$null) -join '').Trim()
        if ($version -and -not (Test-VersionAtLeast $version (Get-Cfg 'DEVKIT_DOCKER_MIN_VERSION'))) {
            return New-DepResult $false "server $version is older than the required $(Get-Cfg 'DEVKIT_DOCKER_MIN_VERSION'); upgrade Docker Desktop" $true
        }
        if (-not $version) { $version = 'unknown' }
        if ((Get-Cfg 'DEVKIT_DOCKER_VERSION' 'latest') -eq 'latest') {
            if (-not $script:DockerUpdateChecked) {
                $script:DockerUpdate = Get-PackageUpdate -WingetId 'Docker.DockerDesktop' -ChocoId 'docker-desktop'
                $script:DockerUpdateChecked = $true
            }
            if ($script:DockerUpdate) {
                $current = "Docker Desktop $($script:DockerUpdate.Current)"
                return New-DepResult $true "ok (server $version, update available: Docker Desktop $($script:DockerUpdate.Available))" `
                    -Current $current -Update $script:DockerUpdate.Available
            }
        }
        return New-DepResult $true "ok (server $version)"
    } `
    -Update {
        Update-DevkitPackage -Name 'Docker Desktop' -WingetId 'Docker.DockerDesktop' -ChocoId 'docker-desktop'
        $script:DockerUpdateChecked = $false
    } `
    -Install {
        if (Find-DockerCli) { return }

        Initialize-Wsl 'Docker Desktop'

        Install-DevkitPackage -Name 'Docker Desktop' -WingetId 'Docker.DockerDesktop' -ChocoId 'docker-desktop'
        Update-SessionPath
        if (-not (Find-DockerCli)) { Stop-Devkit 'Docker Desktop was installed but the docker CLI was not found.' }
    } `
    -Configure {
        if (Test-DockerEngine) { return }

        # The Docker engine pipe only accepts members of docker-users (and
        # elevated administrators).
        if ((Test-DockerUsersGroupExists) -and -not (Test-InGroupToken 'docker-users')) {
            if (-not (Test-InDockerUsersGroup)) {
                $code = Invoke-Elevated "net.exe localgroup docker-users `"$env:USERDOMAIN\$env:USERNAME`" /add" 'adding your user to the docker-users group'
                if ($code -ne 0) { Stop-Devkit "Could not add $env:USERNAME to docker-users (exit $code)." }
            }
            Exit-Pending 'relogin' "User $env:USERNAME is in the 'docker-users' group, which only takes effect after signing in again."
        }

        if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath $script:DockerDesktopExe)) { Stop-Devkit "Docker Desktop not found at $script:DockerDesktopExe" }
            Write-Info 'Starting Docker Desktop'
            Write-Info 'On the first launch, accept the Docker Desktop terms in the window that opens.'
            Start-Process -FilePath $script:DockerDesktopExe | Out-Null
        }

        $timeout = [int] (Get-Cfg 'DEVKIT_DOCKER_START_TIMEOUT' '180')
        Write-Info "Waiting up to ${timeout}s for the Docker engine..."
        if (-not (Wait-Until $timeout { Test-DockerEngine })) {
            Stop-Devkit 'The Docker engine did not become ready. Open Docker Desktop, check for errors and retry.'
        }
    }
