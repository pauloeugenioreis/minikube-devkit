# devkit doctor: read-only diagnostics. Never installs or changes anything.

function Get-DoctorPorts {
    $ports = @()
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_DASHBOARD')) { $ports += , @('Kubernetes Dashboard', (Get-Cfg 'DEVKIT_PORT_DASHBOARD')) }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_RABBITMQ')) {
        $ports += , @('RabbitMQ Management', (Get-Cfg 'DEVKIT_PORT_RABBITMQ_MGMT'))
        $ports += , @('RabbitMQ AMQP', (Get-Cfg 'DEVKIT_PORT_RABBITMQ_AMQP'))
    }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_MONGODB')) { $ports += , @('MongoDB', (Get-Cfg 'DEVKIT_PORT_MONGODB')) }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_POSTGRESQL')) { $ports += , @('PostgreSQL', (Get-Cfg 'DEVKIT_PORT_POSTGRESQL')) }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_MYSQL')) { $ports += , @('MySQL', (Get-Cfg 'DEVKIT_PORT_MYSQL')) }
    if (Test-True (Get-Cfg 'DEVKIT_INSTALL_REDIS')) { $ports += , @('Redis', (Get-Cfg 'DEVKIT_PORT_REDIS')) }
    return , $ports
}

function Invoke-Doctor {
    param([string[]] $Arguments = @())

    $Arguments = Read-DriverOption $Arguments
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        switch ($Arguments[$i]) {
            { $_ -in '-h', '--help', '-Help' } { Write-Host 'Usage: .\devkit.ps1 doctor [-Driver NAME]'; return 0 }
            default { Stop-Devkit "Unknown option for doctor: $($Arguments[$i])" }
        }
    }

    $errors = 0
    $warnings = 0
    $driver = Get-Cfg 'DEVKIT_DRIVER' 'docker'
    Assert-DriverAvailable $driver

    $cpus = Get-HostCpus
    $memoryMb = Get-HostMemoryMb
    $minikubeHome = if ($env:MINIKUBE_HOME) { $env:MINIKUBE_HOME } else { [Environment]::GetFolderPath('UserProfile') }
    $diskGb = Get-FreeDiskGb $minikubeHome

    Write-Step 'System'
    Write-Info "OS:        $(Get-HostOsName) ($(Get-HostArch))"
    Write-Info "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Info "CPUs:      $cpus"
    Write-Info "Memory:    $memoryMb MB"
    Write-Info "Free disk: $diskGb GB ($minikubeHome)"
    Write-Info "Driver:    $driver"
    if (Test-IsAdmin) {
        Write-Warn 'Running as administrator. Prefer a regular session; devkit asks for elevation only when needed.'
        $warnings++
    }

    Write-Step 'Prerequisites'
    $missing = Show-DepReport ($script:CoreDeps + "driver_$driver")
    if ($missing.Count -gt 0) {
        $errors++
        Write-Info "Run '.\devkit.ps1 install-prereqs' to install or fix them."
    }

    $reqCpus = Get-Cfg 'DEVKIT_CPUS'; $reqMem = Get-Cfg 'DEVKIT_MEMORY_MB'; $reqDisk = Get-Cfg 'DEVKIT_DISK_GB'
    foreach ($pair in @(@('DEVKIT_CPUS', $reqCpus), @('DEVKIT_MEMORY_MB', $reqMem), @('DEVKIT_DISK_GB', $reqDisk))) {
        if (-not (Test-Int $pair[1])) { Stop-Devkit "$($pair[0]) must be a whole number (got '$($pair[1])')" }
    }
    $reqCpus = [int] $reqCpus; $reqMem = [int] $reqMem; $reqDisk = [int] $reqDisk

    Write-Step "Resources (requested: $reqCpus CPUs, $reqMem MB RAM, $reqDisk GB disk)"
    $before = $errors
    if ($reqCpus -lt [int] (Get-Cfg 'DEVKIT_MIN_CPUS')) { Write-Err "CPUs below the minimum of $(Get-Cfg 'DEVKIT_MIN_CPUS')"; $errors++ }
    if ($reqCpus -gt $cpus) { Write-Err "Requested $reqCpus CPUs but the host has $cpus"; $errors++ }
    if ($reqMem -lt [int] (Get-Cfg 'DEVKIT_MIN_MEMORY_MB')) { Write-Err "Memory below the minimum of $(Get-Cfg 'DEVKIT_MIN_MEMORY_MB') MB"; $errors++ }
    if ($reqMem -gt $memoryMb) {
        Write-Err "Requested $reqMem MB but the host has $memoryMb MB"; $errors++
    } elseif ($reqMem -gt [int] ($memoryMb * 3 / 4)) {
        Write-Warn 'Requested memory is more than 75% of the host memory'; $warnings++
    }
    if ($reqDisk -lt [int] (Get-Cfg 'DEVKIT_MIN_DISK_GB')) { Write-Err "Disk below the minimum of $(Get-Cfg 'DEVKIT_MIN_DISK_GB') GB"; $errors++ }
    if ($reqDisk -gt $diskGb) { Write-Err "Requested $reqDisk GB disk but only $diskGb GB are free"; $errors++ }

    # With the docker driver the node is limited by what Docker Desktop's VM
    # (WSL 2 or Hyper-V) can use.
    if ($driver -eq 'docker' -and (Test-Command 'docker')) {
        $info = (& docker info --format '{{.NCPU}} {{.MemTotal}}' 2>$null) -join ''
        if ($LASTEXITCODE -eq 0 -and $info -match '^(\d+) (\d+)$') {
            $dockerCpus = [int] $Matches[1]
            $dockerMemMb = [int] ([long] $Matches[2] / 1MB)
            Write-Info "Docker can use $dockerCpus CPUs and $dockerMemMb MB RAM"
            if ($reqCpus -gt $dockerCpus) { Write-Err "Docker only has $dockerCpus CPUs available; raise the WSL 2 limits in %UserProfile%\.wslconfig or Docker Desktop settings"; $errors++ }
            if ($reqMem -gt $dockerMemMb) { Write-Err "Docker only has $dockerMemMb MB RAM available; raise the WSL 2 limits in %UserProfile%\.wslconfig or Docker Desktop settings"; $errors++ }
        }
    }
    if ($errors -eq $before) { Write-Ok 'Resources look fine' }

    Write-Step 'Local ports'
    foreach ($entry in (Get-DoctorPorts)) {
        $line = '{0,-22} {1}' -f $entry[0], $entry[1]
        if (Test-PortInUse ([int] $entry[1])) { Write-Warn "$line is already in use"; $warnings++ }
        else { Write-Ok "$line is free" }
    }

    Write-Step 'Network'
    foreach ($url in @('https://storage.googleapis.com', 'https://dl.k8s.io', 'https://get.helm.sh', 'https://registry-1.docker.io/v2/')) {
        if (Test-UrlReachable $url) { Write-Ok $url } else { Write-Err "$url is not reachable"; $errors++ }
    }

    Write-Host ''
    if ($errors -gt 0) {
        Write-Err "$errors problem(s), $warnings warning(s)."
        return 1
    }
    Write-Ok "No problems found ($warnings warning(s))."
    return 0
}
