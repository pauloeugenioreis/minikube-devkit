# minikube-devkit entrypoint for Windows (Windows PowerShell 5.1 or PowerShell 7+).
# Linux and macOS users: run ./devkit.sh instead.
#
# Arguments are parsed manually (no param block) so the CLI matches devkit.sh:
#   .\devkit.ps1 <command> [command options] [-Yes|--yes|-y] [-VerboseLog|--verbose|-v]

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DevkitVersion = '0.1.0'
$DevkitRoot = $PSScriptRoot

foreach ($module in @('Common', 'Prompt', 'Pkg', 'State')) {
    Import-Module (Join-Path $DevkitRoot "scripts/windows/lib/$module.psm1") -Force -DisableNameChecking
}
Initialize-Devkit -Root $DevkitRoot

function Show-Usage {
    Write-Host @"
minikube-devkit $DevkitVersion

Usage: .\devkit.ps1 <command> [options]

Commands:
  up                 Run the setup wizard, install prerequisites and start the environment
  configure          Run the setup wizard only (saves answers to config\devkit.env)
  info               Show URLs and credentials (-NoSecrets hides passwords)
  forward ACTION     Manage port-forwards: start | stop | restart | status
  down               Stop port-forwards and the cluster (data is kept)
  destroy            Delete the cluster and all its data
  doctor             Check prerequisites, resources, ports and network (read-only)
  install-prereqs    Install and configure everything the selected driver needs
  version            Print the devkit version
  help               Show this help

Global options:
  -Yes, -y, --yes        Non-interactive: accept the default answer for every prompt
  -VerboseLog, --verbose Print the commands being executed

Run '.\devkit.ps1 <command> -Help' for command options (e.g. -Driver, -Cpus).

Environment variables named like the keys in config\devkit.env override them.
"@
}

# Returns @{ Command; Rest } after applying global options.
function Read-CliArgs {
    param([object[]] $CliArgs)
    $command = ''
    $rest = @()
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
        $arg = [string] $CliArgs[$i]
        if ($arg -match '^(-y|--yes|-Yes)$') { Set-DevkitNonInteractive $true }
        elseif ($arg -match '^(-v|--verbose|-VerboseLog)$') { Set-DevkitVerbose $true }
        elseif (-not $command) { $command = $arg }
        else { $rest += $arg }
    }
    if (-not $command) { $command = 'help' }
    return @{ Command = $command; Rest = $rest }
}

# Everything below runs in script scope on purpose: dependency modules are
# dot-sourced here so their functions stay visible to the script blocks they
# register (dot-sourcing inside a function would scope them to that function).
try {
    $cli = Read-CliArgs $args
    if (-not (Test-IsWindowsHost) -and -not $env:DEVKIT_ALLOW_NON_WINDOWS) {
        Stop-Devkit 'devkit.ps1 targets Windows. On Linux and macOS run ./devkit.sh instead.'
    }
    Import-DevkitConfig

    $code = 0
    switch ($cli.Command) {
        { $_ -in 'help', '-h', '--help', '-Help' } { Show-Usage; exit 0 }
        { $_ -in 'version', '--version' } { Write-Host "minikube-devkit $DevkitVersion"; exit 0 }
        { $_ -in 'up', 'configure', 'info', 'forward', 'down', 'destroy', 'doctor', 'install-prereqs' } { break }
        default { Write-Err "Unknown command: $($cli.Command)"; Show-Usage; exit 1 }
    }

    . (Join-Path $DevkitRoot 'scripts/windows/deps/deps.ps1')
    . (Join-Path $DevkitRoot 'scripts/windows/deps/core.ps1')
    . (Join-Path $DevkitRoot 'scripts/windows/deps/drivers/drivers.ps1')
    foreach ($driverModule in Get-DriverModuleFiles) { . $driverModule }
    foreach ($clusterModule in @('Cluster', 'Components', 'Forward', 'Access')) {
        . (Join-Path $DevkitRoot "scripts/windows/cluster/$clusterModule.ps1")
    }
    foreach ($commandName in @('doctor', 'install-prereqs', 'configure', 'up', 'info', 'forward', 'down')) {
        . (Join-Path $DevkitRoot "scripts/windows/commands/$commandName.ps1")
    }
    Initialize-CorePath

    switch ($cli.Command) {
        'up' { $code = Invoke-Up $cli.Rest }
        'configure' { $code = Invoke-Configure $cli.Rest }
        'info' { $code = Invoke-Info $cli.Rest }
        'forward' { $code = Invoke-Forward $cli.Rest }
        'down' { $code = Invoke-Down $cli.Rest }
        'destroy' { $code = Invoke-Destroy $cli.Rest }
        'doctor' { $code = Invoke-Doctor $cli.Rest }
        'install-prereqs' { $code = Invoke-InstallPrereqs $cli.Rest }
    }
    exit ([int] (@($code)[-1]))
} catch {
    $message = $_.Exception.Message
    if ($message.StartsWith('DEVKIT: ')) {
        Write-Err $message.Substring(8)
    } else {
        Write-Err "Unexpected error: $message"
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}
