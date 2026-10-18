# Core CLI dependencies required by every driver: minikube, kubectl, helm.
# Installed from their official release binaries into
# %LOCALAPPDATA%\minikube-devkit\bin and verified with SHA-256.
# DEVKIT_<TOOL>_VERSION is "latest" (resolved online on each run) or an exact
# version such as v1.38.1. When an older copy is installed, devkit offers to
# replace it.

$script:CoreDeps = @('core_minikube', 'core_kubectl', 'core_helm')
$script:CoreLatest = @{}

function Get-CoreBinDir {
    if (Test-IsWindowsHost) { return Join-Path $env:LOCALAPPDATA 'minikube-devkit\bin' }
    return (Get-Cfg 'DEVKIT_BIN_DIR' '/usr/local/bin')
}

function Get-ExeName {
    param([string] $Tool)
    if (Test-IsWindowsHost) { return "$Tool.exe" }
    return $Tool
}

# Appends the devkit bin dir to PATH for this run so tools installed by a
# previous run are found even in terminals opened before the install.
function Initialize-CorePath { Add-ToPath (Get-CoreBinDir) }

# ---------------------------------------------------------------- versions ---

function Get-CoreVersion {
    param([Parameter(Mandatory)] [string] $Tool)
    try {
        switch ($Tool) {
            'minikube' { $out = & minikube version --short 2>$null }
            'kubectl' { $out = (& kubectl version --client 2>$null | Select-String '^Client Version:') -replace '^Client Version:\s*', '' }
            'helm' { $out = (& helm version --short 2>$null) -replace '\+.*$', '' }
        }
    } catch { return '' }
    if ($null -eq $out) { return '' }
    return (@($out)[0]).ToString().Trim()
}

# Downloads a small text document. Some servers answer with a binary content
# type, in which case Invoke-WebRequest returns bytes instead of a string.
function Get-WebText {
    param([Parameter(Mandatory)] [string] $Url)
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return ([string] $content).Trim()
}

# Newest released version of a core tool, or '' when offline.
function Get-CoreLatestVersion {
    param([Parameter(Mandatory)] [string] $Tool)
    try {
        switch ($Tool) {
            'minikube' { return [string] (@(Get-WebText 'https://storage.googleapis.com/minikube/releases.json' | ConvertFrom-Json)[0].name) }
            'kubectl' { return Get-WebText 'https://dl.k8s.io/release/stable.txt' }
            'helm' { return Get-WebText 'https://get.helm.sh/helm-latest-version' }
        }
    } catch { return '' }
    return ''
}

# Version devkit should install: the configured exact version, or the
# resolved "latest" ('' when offline). Cached for the rest of the run.
function Get-CoreTargetVersion {
    param([Parameter(Mandatory)] [string] $Tool)
    $configured = Get-Cfg "DEVKIT_$($Tool.ToUpperInvariant())_VERSION" 'latest'
    if ($configured -ne 'latest') { return $configured }
    if (-not $script:CoreLatest.ContainsKey($Tool)) { $script:CoreLatest[$Tool] = Get-CoreLatestVersion $Tool }
    return $script:CoreLatest[$Tool]
}

# Ready when installed and >= MinVersion; flags a newer target as an update.
function Test-CoreTool {
    param([Parameter(Mandatory)] [string] $Tool, [Parameter(Mandatory)] [string] $MinVersion)
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if (-not $cmd) { return New-DepResult $false 'not installed' }
    $version = Get-CoreVersion $Tool
    if (-not $version) { return New-DepResult $false "installed at $($cmd.Source) but its version could not be read" }
    if (-not (Test-VersionAtLeast $version $MinVersion)) {
        return New-DepResult $false "$version is older than the required $MinVersion" -Current $version
    }
    return New-VersionResult $version (Get-CoreTargetVersion $Tool)
}

# -------------------------------------------------------- remove old copy ---

# Package ids per manager: winget, Chocolatey, Scoop.
function Get-CorePackageIds {
    param([Parameter(Mandatory)] [string] $Tool)
    switch ($Tool) {
        'minikube' { return @{ Winget = 'Kubernetes.minikube'; Choco = 'minikube'; Scoop = 'minikube' } }
        'kubectl' { return @{ Winget = 'Kubernetes.kubectl'; Choco = 'kubernetes-cli'; Scoop = 'kubectl' } }
        'helm' { return @{ Winget = 'Helm.Helm'; Choco = 'kubernetes-helm'; Scoop = 'helm' } }
    }
}

# Removes the copy of the tool found on PATH (unless it is devkit's own),
# using the package manager that installed it when there is one.
function Remove-CoreOldCopy {
    param([Parameter(Mandatory)] [string] $Tool)
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return }
    $path = $cmd.Source
    $ours = Join-Path (Get-CoreBinDir) (Get-ExeName $Tool)
    if ($path -eq $ours) { return }
    $ids = Get-CorePackageIds $Tool
    $chocoRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { 'C:\ProgramData\chocolatey' }
    $wingetLinks = if ($env:LOCALAPPDATA) { [IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'WinGet') } else { '' }

    if ($path.StartsWith($chocoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Info "Removing the Chocolatey copy of $Tool ($($ids.Choco))"
        $code = Invoke-Elevated "choco uninstall $($ids.Choco) -y" 'Chocolatey uninstalls system-wide'
        if ($code -ne 0) { Stop-Devkit "choco uninstall $($ids.Choco) failed (exit $code)." }
    } elseif ($path -match '[\\/]scoop[\\/]') {
        Write-Info "Removing the Scoop copy of $Tool"
        & scoop uninstall $ids.Scoop
        if ($LASTEXITCODE -ne 0) { Stop-Devkit "scoop uninstall $($ids.Scoop) failed." }
    } elseif ($wingetLinks -and $path.StartsWith($wingetLinks, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Info "Removing the winget copy of $Tool ($($ids.Winget))"
        & winget uninstall -e --id $ids.Winget --silent --disable-interactivity
        if ($LASTEXITCODE -ne 0) { Stop-Devkit "winget uninstall $($ids.Winget) failed." }
    } elseif ($path -match '[\\/]Docker[\\/]') {
        # Bundled with Docker Desktop: never delete it; devkit's copy goes first on PATH.
        Write-Info "Keeping the copy bundled with Docker Desktop ($path); devkit's copy takes precedence on PATH."
    } else {
        Write-Info "Removing $path"
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        } catch {
            $code = Invoke-Elevated "Remove-Item -LiteralPath '$path' -Force" "removing $path"
            if ($code -ne 0) { Stop-Devkit "Could not remove $path." }
        }
    }
}

# ---------------------------------------------------------------- install ---

# Warns when an older copy earlier on PATH shadows the one just installed.
function Assert-CoreResolves {
    param([Parameter(Mandatory)] [string] $Tool)
    $expected = Join-Path (Get-CoreBinDir) (Get-ExeName $Tool)
    $resolved = (Get-Command $Tool -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($resolved -ne $expected) {
        Write-Warn "'$Tool' resolves to $resolved, not $expected."
        Write-Info "Remove or upgrade that copy, or put $(Get-CoreBinDir) first on PATH."
    }
}

function Install-CoreFile {
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Tool)
    $binDir = Get-CoreBinDir
    if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
    $target = Join-Path $binDir (Get-ExeName $Tool)
    Copy-Item -LiteralPath $Source -Destination $target -Force
    if (-not (Test-IsWindowsHost)) { & chmod 0755 $target }
    Add-ToPath $binDir -Persist -Prepend
    Assert-CoreResolves $Tool
}

function Get-CoreOsName {
    if (Test-IsWindowsHost) { return 'windows' }
    if ($IsMacOS) { return 'darwin' }
    return 'linux'
}

# Downloads a single binary that has a matching .sha256 file.
function Install-CoreBinary {
    param([Parameter(Mandatory)] [string] $Tool, [Parameter(Mandatory)] [string] $Url)
    $tmp = New-TempDir
    try {
        $file = Join-Path $tmp (Get-ExeName $Tool)
        Write-Info "Downloading $Url"
        Save-Download $Url $file
        Assert-Sha256 $file "$Url.sha256"
        Install-CoreFile $file $Tool
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-CoreVersion {
    param([Parameter(Mandatory)] [string] $Tool, [string] $Version)
    if (-not $Version) {
        Stop-Devkit "Could not resolve the latest $Tool version (offline?). Set DEVKIT_$($Tool.ToUpperInvariant())_VERSION to an exact version in config\devkit.env."
    }
    $os = Get-CoreOsName; $arch = Get-HostArch
    switch ($Tool) {
        'minikube' {
            $name = "minikube-$os-$arch"
            if (Test-IsWindowsHost) { $name += '.exe' }
            Install-CoreBinary 'minikube' "https://storage.googleapis.com/minikube/releases/$Version/$name"
        }
        'kubectl' {
            Install-CoreBinary 'kubectl' "https://dl.k8s.io/release/$Version/bin/$os/$arch/$(Get-ExeName 'kubectl')"
        }
        'helm' {
            $platform = "$os-$arch"
            $ext = if (Test-IsWindowsHost) { 'zip' } else { 'tar.gz' }
            $url = "https://get.helm.sh/helm-$Version-$platform.$ext"
            $tmp = New-TempDir
            try {
                $archive = Join-Path $tmp "helm.$ext"
                Write-Info "Downloading $url"
                Save-Download $url $archive
                Assert-Sha256 $archive "$url.sha256sum"
                if ($ext -eq 'zip') { Expand-Archive -LiteralPath $archive -DestinationPath $tmp -Force }
                else { & tar -xzf $archive -C $tmp }
                Install-CoreFile (Join-Path (Join-Path $tmp $platform) (Get-ExeName 'helm')) 'helm'
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Registers a core tool: install when missing or below the minimum (the old
# copy is removed first); update replaces an older but usable copy.
# The blocks are built from text (not GetNewClosure) so they keep resolving
# the script-scope functions above.
function Register-CoreTool {
    param([Parameter(Mandatory)] [ValidateSet('minikube', 'kubectl', 'helm')] [string] $Tool)
    $min = "(Get-Cfg 'DEVKIT_$($Tool.ToUpperInvariant())_MIN_VERSION')"
    Register-Dependency -Id "core_$Tool" -Label $Tool `
        -Check ([scriptblock]::Create("Test-CoreTool '$Tool' $min")) `
        -Install ([scriptblock]::Create(@"
if ((Test-CoreTool '$Tool' $min).Ok) { return }
if (Get-Command '$Tool' -ErrorAction SilentlyContinue) { Remove-CoreOldCopy '$Tool' }
Install-CoreVersion '$Tool' (Get-CoreTargetVersion '$Tool')
"@)) `
        -Update ([scriptblock]::Create(@"
Remove-CoreOldCopy '$Tool'
Install-CoreVersion '$Tool' (Get-CoreTargetVersion '$Tool')
"@))
}

foreach ($coreTool in @('minikube', 'kubectl', 'helm')) { Register-CoreTool $coreTool }
