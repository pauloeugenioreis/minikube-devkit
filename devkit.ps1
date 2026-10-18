# minikube-devkit entrypoint for Windows (Windows PowerShell 5.1 or PowerShell 7+).
# Linux and macOS users: run ./devkit.sh instead.
#
# Arguments are parsed manually (no param block) so the CLI matches devkit.sh:
#   .\devkit.ps1 <command> [-Yes|--yes|-y] [-Driver|--driver NAME] [-VerboseLog|--verbose|-v]

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DevkitVersion = '0.1.0'
$DevkitRoot = $PSScriptRoot

foreach ($module in @('Common', 'Prompt', 'Pkg', 'State')) {
    Import-Module (Join-Path $DevkitRoot "scripts/lib/$module.psm1") -Force -DisableNameChecking
}
Initialize-Devkit -Root $DevkitRoot

function Show-Usage {
    Write-Host @"
minikube-devkit $DevkitVersion

Usage: .\devkit.ps1 <command> [options]

Commands:
  doctor             Check prerequisites, resources, ports and network (read-only)
  install-prereqs    Install and configure everything the selected driver needs
  version            Print the devkit version
  help               Show this help

Global options:
  -Yes, -y, --yes        Non-interactive: accept the default answer for every prompt
  -VerboseLog, --verbose Print the commands being executed
  -Driver NAME           Minikube driver to use (default: $(Get-Cfg 'DEVKIT_DRIVER' 'docker'))

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
        elseif ($arg -match '^(--driver|-Driver)$') {
            if ($i + 1 -ge $CliArgs.Count) { Stop-Devkit "$arg needs a value" }
            $i++
            $env:DEVKIT_DRIVER = [string] $CliArgs[$i]
        }
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
        { $_ -in 'doctor', 'install-prereqs' } { break }
        default { Write-Err "Unknown command: $($cli.Command)"; Show-Usage; exit 1 }
    }

    . (Join-Path $DevkitRoot 'scripts/deps/deps.ps1')
    . (Join-Path $DevkitRoot 'scripts/deps/core.ps1')
    . (Join-Path $DevkitRoot 'scripts/deps/drivers/drivers.ps1')
    . (Get-DriverModule (Get-Cfg 'DEVKIT_DRIVER' 'docker'))
    . (Join-Path $DevkitRoot 'scripts/commands/doctor.ps1')
    . (Join-Path $DevkitRoot 'scripts/commands/install-prereqs.ps1')
    Initialize-CorePath

    switch ($cli.Command) {
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
