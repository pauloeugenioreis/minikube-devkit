# Core CLI dependencies required by every driver: minikube, kubectl, helm.
# Installed from their official release binaries (pinned in config/devkit.env)
# into %LOCALAPPDATA%\minikube-devkit\bin and verified with SHA-256.

$script:CoreDeps = @('core_minikube', 'core_kubectl', 'core_helm')

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

function Test-CoreTool {
    param([Parameter(Mandatory)] [string] $Tool, [Parameter(Mandatory)] [string] $MinVersion)
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if (-not $cmd) { return New-DepResult $false 'not installed' }
    $version = Get-CoreVersion $Tool
    if (-not $version) { return New-DepResult $false "installed at $($cmd.Source) but its version could not be read" }
    if (-not (Test-VersionAtLeast $version $MinVersion)) {
        return New-DepResult $false "$version is older than the required $MinVersion"
    }
    return New-DepResult $true "ok ($version)"
}

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

Register-Dependency -Id 'core_minikube' -Label 'minikube' `
    -Check { Test-CoreTool 'minikube' (Get-Cfg 'DEVKIT_MINIKUBE_MIN_VERSION') } `
    -Install {
        if ((Test-CoreTool 'minikube' (Get-Cfg 'DEVKIT_MINIKUBE_MIN_VERSION')).Ok) { return }
        $name = "minikube-$(Get-CoreOsName)-$(Get-HostArch)"
        if (Test-IsWindowsHost) { $name += '.exe' }
        Install-CoreBinary 'minikube' "https://storage.googleapis.com/minikube/releases/$(Get-Cfg 'DEVKIT_MINIKUBE_VERSION')/$name"
    }

Register-Dependency -Id 'core_kubectl' -Label 'kubectl' `
    -Check { Test-CoreTool 'kubectl' (Get-Cfg 'DEVKIT_KUBECTL_MIN_VERSION') } `
    -Install {
        if ((Test-CoreTool 'kubectl' (Get-Cfg 'DEVKIT_KUBECTL_MIN_VERSION')).Ok) { return }
        Install-CoreBinary 'kubectl' "https://dl.k8s.io/release/$(Get-Cfg 'DEVKIT_KUBECTL_VERSION')/bin/$(Get-CoreOsName)/$(Get-HostArch)/$(Get-ExeName 'kubectl')"
    }

Register-Dependency -Id 'core_helm' -Label 'helm' `
    -Check { Test-CoreTool 'helm' (Get-Cfg 'DEVKIT_HELM_MIN_VERSION') } `
    -Install {
        if ((Test-CoreTool 'helm' (Get-Cfg 'DEVKIT_HELM_MIN_VERSION')).Ok) { return }
        $platform = "$(Get-CoreOsName)-$(Get-HostArch)"
        $ext = if (Test-IsWindowsHost) { 'zip' } else { 'tar.gz' }
        $url = "https://get.helm.sh/helm-$(Get-Cfg 'DEVKIT_HELM_VERSION')-$platform.$ext"
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
