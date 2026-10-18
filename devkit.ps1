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
  status             Show the cluster, pods, KEDA ScaledObjects and port-forwards
  info               Show URLs and credentials (-NoSecrets hides passwords)
  forward ACTION     Manage port-forwards: start | stop | restart | status
  logs NAME [-f]     Show logs of a component (e.g. postgresql, keda, redis-worker)
  shell NAME         Open the client of a service (psql, mysql, mongosh, redis-cli)
  reset NAME         Recreate a data service with an empty volume
  examples ACTION    KEDA examples: deploy | remove | produce rabbitmq|redis [N]
  test SUITE         Run tests: smoke | keda | unit | all
  down               Stop port-forwards and the cluster (data is kept)
  destroy            Delete the cluster and all its data (optionally uninstall too)
  uninstall          Remove everything minikube-devkit installed (after destroy)
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

    # Commands are called as plain statements (not "$x = Invoke-..."): capturing
    # their output would hide native output such as "minikube start" and take
    # the terminal away from interactive commands ("devkit shell"). They report
    # failure through $script:DevkitExitCode instead of a return value.
    $script:DevkitExitCode = 0
    switch ($cli.Command) {
        { $_ -in 'help', '-h', '--help', '-Help' } { Show-Usage; exit 0 }
        { $_ -in 'version', '--version' } { Write-Host "minikube-devkit $DevkitVersion"; exit 0 }
        { $_ -in 'up', 'configure', 'status', 'info', 'forward', 'logs', 'shell', 'reset', 'examples', 'test', 'down', 'destroy', 'uninstall', 'doctor', 'install-prereqs' } { break }
        default { Write-Err "Unknown command: $($cli.Command)"; Show-Usage; exit 1 }
    }

    . (Join-Path $DevkitRoot 'scripts/windows/deps/deps.ps1')
    . (Join-Path $DevkitRoot 'scripts/windows/deps/core.ps1')
    . (Join-Path $DevkitRoot 'scripts/windows/deps/drivers/drivers.ps1')
    foreach ($driverModule in Get-DriverModuleFiles) { . $driverModule }
    foreach ($clusterModule in @('Cluster', 'Components', 'Forward', 'Access', 'Examples')) {
        . (Join-Path $DevkitRoot "scripts/windows/cluster/$clusterModule.ps1")
    }
    foreach ($commandName in @('doctor', 'install-prereqs', 'configure', 'up', 'status', 'info', 'forward', 'logs', 'shell', 'reset', 'examples', 'test', 'down', 'uninstall')) {
        . (Join-Path $DevkitRoot "scripts/windows/commands/$commandName.ps1")
    }
    Initialize-CorePath

    switch ($cli.Command) {
        'up' { Invoke-Up $cli.Rest }
        'configure' { Invoke-Configure $cli.Rest }
        'status' { Invoke-Status $cli.Rest }
        'info' { Invoke-Info $cli.Rest }
        'logs' { Invoke-Logs $cli.Rest }
        'shell' { Invoke-Shell $cli.Rest }
        'reset' { Invoke-Reset $cli.Rest }
        'examples' { Invoke-Examples $cli.Rest }
        'test' { Invoke-Test $cli.Rest }
        'forward' { Invoke-Forward $cli.Rest }
        'down' { Invoke-Down $cli.Rest }
        'destroy' { Invoke-Destroy $cli.Rest }
        'uninstall' { Invoke-Uninstall $cli.Rest }
        'doctor' { Invoke-Doctor $cli.Rest }
        'install-prereqs' { Invoke-InstallPrereqs $cli.Rest }
    }
    exit $script:DevkitExitCode
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
