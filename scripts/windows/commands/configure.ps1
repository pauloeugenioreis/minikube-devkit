# devkit configure: setup wizard. Asks for the driver, the minikube resources
# and the components to install, then saves the answers to config\devkit.env.
# Command-line flags pre-answer questions; with -Yes every remaining question
# takes its default, so the same flow works in CI.

# Every installable component, in prompt order.
$script:WizardComponents = @(
    [pscustomobject] @{ Id = 'dashboard'; Key = 'DEVKIT_INSTALL_DASHBOARD'; Label = 'Kubernetes Dashboard' }
    [pscustomobject] @{ Id = 'rabbitmq'; Key = 'DEVKIT_INSTALL_RABBITMQ'; Label = 'RabbitMQ' }
    [pscustomobject] @{ Id = 'mongodb'; Key = 'DEVKIT_INSTALL_MONGODB'; Label = 'MongoDB' }
    [pscustomobject] @{ Id = 'postgresql'; Key = 'DEVKIT_INSTALL_POSTGRESQL'; Label = 'PostgreSQL' }
    [pscustomobject] @{ Id = 'mysql'; Key = 'DEVKIT_INSTALL_MYSQL'; Label = 'MySQL' }
    [pscustomobject] @{ Id = 'redis'; Key = 'DEVKIT_INSTALL_REDIS'; Label = 'Redis' }
    [pscustomobject] @{ Id = 'keda'; Key = 'DEVKIT_INSTALL_KEDA'; Label = 'KEDA' }
)

$script:WizardFlagsHelp = @'
  -Driver NAME         Minikube driver (asked when omitted)  (--driver)
  -Cpus N              CPUs for the minikube node            (--cpus)
  -Memory MB           Memory for the minikube node, in MB   (--memory)
  -Disk GB             Disk size for the minikube node, in GB (--disk)
  -Services LIST       Comma-separated components to install, e.g. postgresql,redis,keda (--services)
                       (all | none | dashboard,rabbitmq,mongodb,postgresql,mysql,redis,keda)
  -Reconfigure         Ask every question again even if a previous setup was saved (--reconfigure)
'@

# Parses wizard flags into a hashtable; returns $null for --help.
function Read-WizardArgs {
    param([string[]] $Arguments, [string] $Usage)
    $opts = @{ Cpus = ''; Memory = ''; Disk = ''; Services = ''; Reconfigure = $false }
    $Arguments = Read-DriverOption $Arguments
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        $name = $arg.TrimStart('-').ToLowerInvariant()
        switch ($name) {
            { $_ -in 'cpus', 'memory', 'disk', 'services' } {
                if ($i + 1 -ge $Arguments.Count) { Stop-Devkit "$arg needs a value" }
                $i++
                $opts[(Get-Culture).TextInfo.ToTitleCase($name)] = $Arguments[$i]
            }
            'reconfigure' { $opts.Reconfigure = $true }
            { $_ -in 'h', 'help' } { Write-Host $Usage; return $null }
            default { Stop-Devkit "Unknown option: $arg" }
        }
    }
    $opts.Driver = $script:CliDriver
    return $opts
}

# Default resource: the configured value, capped at half of the host (never
# below the minimum).
function Get-WizardDefault {
    param([string] $Configured, [int] $HostValue, [int] $Minimum)
    $value = if (Test-Int $Configured) { [int] $Configured } else { $Minimum }
    $half = [Math]::Max([int] [Math]::Floor($HostValue / 2), $Minimum)
    return [Math]::Min($value, $half)
}

function Get-SelectedComponents {
    $ids = @($script:WizardComponents | Where-Object { Test-True (Get-Cfg $_.Key) } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { return 'none' }
    return $ids -join ', '
}

function Set-WizardServices {
    param([Parameter(Mandatory)] [string] $Services)
    $valid = @($script:WizardComponents | ForEach-Object { $_.Id })
    switch ($Services) {
        'all' { $wanted = $valid }
        'none' { $wanted = @() }
        default { $wanted = @($Services -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    }
    foreach ($id in $wanted) {
        if ($valid -notcontains $id) { Stop-Devkit "Unknown component '$id'. Valid: $($valid -join ' ')" }
    }
    foreach ($c in $script:WizardComponents) {
        Set-Cfg $c.Key ([string] ($wanted -contains $c.Id)).ToLowerInvariant()
    }
}

function Show-WizardSummary {
    Write-Step 'Summary'
    Write-Info "Driver:     $(Get-Cfg 'DEVKIT_DRIVER')"
    Write-Info "Resources:  $(Get-Cfg 'DEVKIT_CPUS') CPUs, $(Get-Cfg 'DEVKIT_MEMORY_MB') MB RAM, $(Get-Cfg 'DEVKIT_DISK_GB') GB disk"
    Write-Info "Components: $(Get-SelectedComponents)"
}

# Saves the wizard answers to config\devkit.env, touching only changed keys.
function Save-WizardAnswers {
    $keys = @('DEVKIT_DRIVER', 'DEVKIT_CPUS', 'DEVKIT_MEMORY_MB', 'DEVKIT_DISK_GB') + @($script:WizardComponents | ForEach-Object { $_.Key })
    $saved = @{}
    foreach ($line in Get-Content -LiteralPath (Get-ConfigFile)) {
        $idx = $line.IndexOf('=')
        if ($idx -gt 0) { $saved[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
    }
    foreach ($key in $keys) {
        $current = Get-Cfg $key
        if (-not $saved.ContainsKey($key) -or $saved[$key] -ne $current) { Save-Cfg $key $current }
    }
    Set-State 'WIZARD_COMPLETED' '1'
}

# Values typed by the user are written with Set-Cfg; an environment variable
# with the same name would otherwise keep winning in Get-Cfg.
function Set-WizardValue {
    param([string] $Key, [string] $Value)
    [Environment]::SetEnvironmentVariable($Key, $null)
    Set-Cfg $Key $Value
}

# Runs the wizard; the chosen values end up in the config and devkit.env.
function Invoke-Wizard {
    param([Parameter(Mandatory)] [hashtable] $Options)

    $hostCpus = Get-HostCpus
    $hostMem = Get-HostMemoryMb
    $minikubeHome = if ($env:MINIKUBE_HOME) { $env:MINIKUBE_HOME } else { [Environment]::GetFolderPath('UserProfile') }
    $hostDisk = Get-FreeDiskGb $minikubeHome
    $minCpus = [int] (Get-Cfg 'DEVKIT_MIN_CPUS'); $minMem = [int] (Get-Cfg 'DEVKIT_MIN_MEMORY_MB'); $minDisk = [int] (Get-Cfg 'DEVKIT_MIN_DISK_GB')
    if ($hostCpus -lt $minCpus) { Stop-Devkit "This machine has $hostCpus CPU(s); minikube-devkit needs at least $minCpus." }
    if ($hostMem -lt $minMem) { Stop-Devkit "This machine has $hostMem MB RAM; minikube-devkit needs at least $minMem MB." }
    $supported = @(Get-SupportedDrivers | ForEach-Object { $_.Value })

    Write-Step 'minikube-devkit setup'

    $anyFlag = $Options.Driver -or $Options.Cpus -or $Options.Memory -or $Options.Disk -or $Options.Services
    if (-not $Options.Reconfigure -and (Get-State 'WIZARD_COMPLETED') -eq '1' -and -not $anyFlag) {
        Show-WizardSummary
        Write-Host ''
        if (Read-YesNo 'Use saved configuration?' 'Y') {
            if ($supported -notcontains (Get-Cfg 'DEVKIT_DRIVER')) {
                Stop-Devkit "Saved driver '$(Get-Cfg 'DEVKIT_DRIVER')' is not supported on this machine. Run with -Reconfigure."
            }
            return
        }
        Write-Host ''
    }

    # Driver
    if ($Options.Driver) {
        if ($supported -notcontains $Options.Driver) { Stop-Devkit "Driver '$($Options.Driver)' is not supported on Windows. Supported: $($supported -join ', ')" }
        Set-WizardValue 'DEVKIT_DRIVER' $Options.Driver
    } else {
        $default = Get-Cfg 'DEVKIT_DRIVER' 'docker'
        if ($supported -notcontains $default) { $default = 'docker' }
        Set-WizardValue 'DEVKIT_DRIVER' (Read-Choice 'Select Minikube driver:' $default (Get-SupportedDrivers))
    }

    # Resources
    Write-Host ''
    Write-Host "Minikube resources (host: $hostCpus CPUs, $hostMem MB RAM, $hostDisk GB free disk)"
    $cpuDefault = if ($Options.Cpus) { $Options.Cpus } else { Get-WizardDefault -Configured (Get-Cfg 'DEVKIT_CPUS') -HostValue $hostCpus -Minimum $minCpus }
    Set-WizardValue 'DEVKIT_CPUS' (Read-Value 'CPUs' "$cpuDefault" {
            param($v)
            if (-not (Test-Int $v)) { Write-Host '    Please enter a whole number.'; return $false }
            if ([int] $v -lt $minCpus) { Write-Host "    Minimum is $minCpus CPUs."; return $false }
            if ([int] $v -gt $hostCpus) { Write-Host "    This machine has only $hostCpus CPUs."; return $false }
            return $true
        }.GetNewClosure())

    $memDefault = Get-WizardDefault -Configured (Get-Cfg 'DEVKIT_MEMORY_MB') -HostValue $hostMem -Minimum $minMem
    $memDefault = [Math]::Max([int] ([Math]::Floor($memDefault / 256) * 256), $minMem)
    $memFlag = $Options.Memory
    while ($true) {
        $initial = if ($memFlag) { $memFlag } else { "$memDefault" }
        $mem = Read-Value 'Memory (MB)' $initial {
            param($v)
            if (-not (Test-Int $v)) { Write-Host '    Please enter a whole number of MB (e.g. 8192).'; return $false }
            if ([int] $v -lt $minMem) { Write-Host "    Minimum is $minMem MB."; return $false }
            if ([int] $v -gt $hostMem) { Write-Host "    This machine has only $hostMem MB."; return $false }
            return $true
        }.GetNewClosure()
        if ([int] $mem -le [int] ($hostMem * 3 / 4)) { break }
        if (-not (Test-Interactive)) { Write-Warn "$mem MB is more than 75% of this machine's memory."; break }
        if (Read-YesNo "    $mem MB is more than 75% of this machine's memory and may slow it down. Continue?" 'N') { break }
        $memFlag = ''
    }
    Set-WizardValue 'DEVKIT_MEMORY_MB' $mem

    $diskDefault = if ($Options.Disk) { $Options.Disk } else { [Math]::Min([int] (Get-Cfg 'DEVKIT_DISK_GB' "$minDisk"), $hostDisk) }
    Set-WizardValue 'DEVKIT_DISK_GB' (Read-Value 'Disk size (GB)' "$diskDefault" {
            param($v)
            if (-not (Test-Int $v)) { Write-Host '    Please enter a whole number of GB.'; return $false }
            if ([int] $v -lt $minDisk) { Write-Host "    Minimum is $minDisk GB."; return $false }
            if ([int] $v -gt $hostDisk) { Write-Host "    Only $hostDisk GB are free."; return $false }
            return $true
        }.GetNewClosure())

    # Components
    Write-Host ''
    if ($Options.Services) {
        Set-WizardServices $Options.Services
    } else {
        foreach ($c in $script:WizardComponents) {
            $default = if (Test-True (Get-Cfg $c.Key)) { 'Y' } else { 'N' }
            $answer = Read-YesNo ('Install {0,-21}' -f "$($c.Label)?") $default
            Set-WizardValue $c.Key ([string] $answer).ToLowerInvariant()
        }
    }

    Show-WizardSummary
    Write-Host ''
    if (-not (Read-YesNo 'Proceed?' 'Y')) { Stop-Devkit 'Aborted by user. Nothing was changed.' }
    Save-WizardAnswers
}

function Invoke-Configure {
    param([string[]] $Arguments = @())
    $usage = "Usage: .\devkit.ps1 configure [options]`n`nOptions:`n$script:WizardFlagsHelp"
    $opts = Read-WizardArgs $Arguments $usage
    if ($null -eq $opts) { return 0 }
    Invoke-Wizard $opts
    Write-Host ''
    Write-Ok 'Configuration saved to config\devkit.env'
    return 0
}
