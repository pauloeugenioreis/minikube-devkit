# Docker driver dependency (Windows): Docker Desktop on the WSL 2 backend.
#
# Install:   enables WSL 2 (reboot may be required), then installs Docker
#            Desktop with winget (Chocolatey as fallback).
# Configure: makes sure the user is in docker-users (re-login may be
#            required), starts Docker Desktop and waits for the engine.

$script:ProgramFilesDir = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$script:DockerDesktopDir = [IO.Path]::Combine($script:ProgramFilesDir, 'Docker', 'Docker')
$script:DockerDesktopExe = [IO.Path]::Combine($script:DockerDesktopDir, 'Docker Desktop.exe')

# Exposes the Docker CLI shipped inside Docker Desktop when it is not on PATH.
function Find-DockerCli {
    if (Test-Command 'docker') { return $true }
    $bin = Join-Path $script:DockerDesktopDir 'resources\bin'
    if (Test-Path -LiteralPath (Join-Path $bin 'docker.exe')) {
        Add-ToPath $bin
        return $true
    }
    return $false
}

function Test-VirtualizationAvailable {
    try {
        if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { return $true }
        return [bool] (@(Get-CimInstance Win32_Processor -ErrorAction Stop)[0].VirtualizationFirmwareEnabled)
    } catch {
        return $true # Unknown: let the installer report it.
    }
}

function Test-WslReady {
    if (-not (Test-Command 'wsl.exe')) { return $false }
    & wsl.exe --status *> $null
    return ($LASTEXITCODE -eq 0)
}

# Membership as seen by the current logon token (what the Docker pipe checks).
function Test-InDockerUsersToken {
    $groups = & whoami.exe /groups /fo csv 2>$null
    return [bool] ($groups | Select-String -SimpleMatch 'docker-users')
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

Register-Dependency -Id 'driver_docker' -Label 'docker' `
    -Check {
        if (-not (Find-DockerCli)) {
            if (-not (Test-VirtualizationAvailable)) {
                return New-DepResult $false 'not installed, and CPU virtualization (VT-x/AMD-V) is disabled in BIOS/UEFI; enable it first' $true
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
        return New-DepResult $true "ok (server $version)"
    } `
    -Install {
        if (Find-DockerCli) { return }

        if (-not (Test-WslReady)) {
            Write-Info 'Enabling WSL 2 (required by Docker Desktop)'
            $code = Invoke-Elevated 'wsl.exe --install --no-distribution' 'enabling Windows features for WSL 2'
            if ($code -ne 0) { Stop-Devkit "Enabling WSL 2 failed (exit $code). Run 'wsl --install' manually." }
            if (-not (Test-WslReady)) {
                Exit-Pending 'reboot' 'WSL 2 was enabled and Windows must restart to finish the installation.'
            }
        }

        Install-DevkitPackage -Name 'Docker Desktop' -WingetId 'Docker.DockerDesktop' -ChocoId 'docker-desktop'
        Update-SessionPath
        if (-not (Find-DockerCli)) { Stop-Devkit 'Docker Desktop was installed but the docker CLI was not found.' }
    } `
    -Configure {
        if (Test-DockerEngine) { return }

        # The Docker engine pipe only accepts members of docker-users (and
        # elevated administrators).
        if ((Test-DockerUsersGroupExists) -and -not (Test-InDockerUsersToken)) {
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
