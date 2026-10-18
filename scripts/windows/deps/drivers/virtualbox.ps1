# virtualbox driver dependency (Windows amd64).
# With DEVKIT_VIRTUALBOX_VERSION=latest, updates from winget/Chocolatey are offered.

$script:VirtualBoxDir = [IO.Path]::Combine($script:ProgramFilesDir, 'Oracle', 'VirtualBox')

# Exposes VBoxManage when the installer did not add it to PATH.
function Find-VBoxManage {
    if (Test-Command 'VBoxManage') { return $true }
    if (Test-Path -LiteralPath ([IO.Path]::Combine($script:VirtualBoxDir, 'VBoxManage.exe'))) {
        Add-ToPath $script:VirtualBoxDir
        return $true
    }
    return $false
}

$script:VBoxUpdateChecked = $false
$script:VBoxUpdate = $null

Register-Dependency -Id 'driver_virtualbox' -Label 'virtualbox' `
    -Check {
        if (-not (Test-VirtualizationAvailable)) { return New-DepResult $false $script:VirtualizationHint $true }
        if (-not (Find-VBoxManage)) { return New-DepResult $false 'not installed' }
        $version = ((& VBoxManage --version 2>$null) | Select-Object -Last 1)
        if (-not $version -or $version -notmatch '^[0-9]') { return New-DepResult $false 'installed, but VBoxManage is not working; reinstall VirtualBox' }
        if (-not (Test-VersionAtLeast $version (Get-Cfg 'DEVKIT_VIRTUALBOX_MIN_VERSION'))) {
            return New-DepResult $false "$version is older than the required $(Get-Cfg 'DEVKIT_VIRTUALBOX_MIN_VERSION'); upgrade VirtualBox" $true
        }
        $note = ''
        try {
            # VirtualBox runs on top of Hyper-V when it is enabled, which is much slower.
            if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { $note = '; Hyper-V is active, VMs will be slower' }
        } catch { $note = '' }
        $version = $version -replace 'r.*$', ''
        if ((Get-Cfg 'DEVKIT_VIRTUALBOX_VERSION' 'latest') -eq 'latest') {
            if (-not $script:VBoxUpdateChecked) {
                $script:VBoxUpdate = Get-PackageUpdate -WingetId 'Oracle.VirtualBox' -ChocoId 'virtualbox'
                $script:VBoxUpdateChecked = $true
            }
            if ($script:VBoxUpdate) {
                return New-DepResult $true "ok ($version, update available: $($script:VBoxUpdate.Available)$note)" `
                    -Current $version -Update $script:VBoxUpdate.Available
            }
        }
        return New-DepResult $true "ok ($version$note)"
    } `
    -Update {
        Update-DevkitPackage -Name 'VirtualBox' -WingetId 'Oracle.VirtualBox' -ChocoId 'virtualbox'
        $script:VBoxUpdateChecked = $false
    } `
    -Install {
        if (Find-VBoxManage) { return }
        Install-DevkitPackage -Name 'VirtualBox' -WingetId 'Oracle.VirtualBox' -ChocoId 'virtualbox'
        Update-SessionPath
        if (-not (Find-VBoxManage)) { Stop-Devkit 'VirtualBox was installed but VBoxManage was not found.' }
    }
