# Interactive prompts. Every prompt falls back to its default answer when the
# session is non-interactive (redirected input, -Yes, or DEVKIT_NONINTERACTIVE),
# so the same code path works in CI.

Set-StrictMode -Version 2.0

function Test-Interactive {
    if (Test-DevkitNonInteractive) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    try { return -not [Console]::IsInputRedirected } catch { return $true }
}

# Returns $true for "yes". Default is 'Y' or 'N'.
function Read-YesNo {
    param([Parameter(Mandatory)] [string] $Question, [ValidateSet('Y', 'N')] [string] $Default = 'Y')
    $hint = if ($Default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    if (-not (Test-Interactive)) {
        Write-Host "$Question ${hint}: $Default (default)"
        return ($Default -eq 'Y')
    }
    while ($true) {
        $answer = Read-Host "$Question $hint"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Host '  Please answer y or n.' }
        }
    }
}

# Returns the entered value. Validator is a script block that receives the
# value and returns $true, or writes its own message and returns $false.
function Read-Value {
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Default,
        [scriptblock] $Validator = $null
    )
    while ($true) {
        if (Test-Interactive) {
            $answer = Read-Host "  $Label [$Default]"
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        } else {
            $answer = $Default
        }
        $answer = $answer.Trim()
        if ($null -eq $Validator -or (& $Validator $answer)) { return $answer }
        if (-not (Test-Interactive)) { Stop-Devkit "Invalid value for ${Label}: $answer" }
    }
}

# Options are objects with Value and Description. Returns the selected Value.
function Read-Choice {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Default,
        [Parameter(Mandatory)] [object[]] $Options
    )
    $defaultIndex = 1
    for ($i = 0; $i -lt $Options.Count; $i++) {
        if ($Options[$i].Value -eq $Default) { $defaultIndex = $i + 1 }
    }
    if (-not (Test-Interactive)) {
        Write-Host "$Title $Default (default)"
        return $Default
    }

    Write-Host $Title
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $suffix = if ($i + 1 -eq $defaultIndex) { ' (default)' } else { '' }
        Write-Host ('  {0}) {1,-12} {2}{3}' -f ($i + 1), $Options[$i].Value, $Options[$i].Description, $suffix)
    }
    while ($true) {
        $answer = Read-Host "Choice [$defaultIndex]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "$defaultIndex" }
        $n = 0
        if ([int]::TryParse($answer.Trim(), [ref] $n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1].Value
        }
        Write-Host "  Please enter a number between 1 and $($Options.Count)."
    }
}

Export-ModuleMember -Function *
