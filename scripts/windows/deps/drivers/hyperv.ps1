# hyperv driver dependency (Windows Pro/Enterprise/Education).
#
# Install:   enables the Hyper-V feature (Windows must restart).
# Configure: makes sure the Hyper-V service runs and the user belongs to
#            "Hyper-V Administrators" (re-login required), which minikube
#            needs to manage VMs without an elevated terminal.

# Well-known SID of the built-in "Hyper-V Administrators" group (the name is localized).
$script:HyperVAdminsSid = 'S-1-5-32-578'

function Test-HyperVEditionSupported {
    try {
        return ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption -notmatch 'Home')
    } catch {
        return $true
    }
}

function Test-HyperVEnabled {
    return [bool] (Get-Service -Name 'vmms' -ErrorAction SilentlyContinue)
}

function Test-InHyperVAdminsGroup {
    try {
        $members = @(Get-LocalGroupMember -SID $script:HyperVAdminsSid -ErrorAction Stop)
        return [bool] ($members | Where-Object { $_.Name -eq "$env:USERDOMAIN\$env:USERNAME" })
    } catch {
        return $false
    }
}

Register-Dependency -Id 'driver_hyperv' -Label 'hyperv' `
    -Check {
        if (-not (Test-HyperVEditionSupported)) {
            return New-DepResult $false 'Hyper-V is not available on Windows Home; use the docker driver' $true
        }
        if (-not (Test-VirtualizationAvailable)) { return New-DepResult $false $script:VirtualizationHint $true }
        if (-not (Test-HyperVEnabled)) { return New-DepResult $false 'the Hyper-V feature is not enabled' }
        if ((Get-Service -Name 'vmms').Status -ne 'Running') { return New-DepResult $false 'enabled, but the Hyper-V service (vmms) is not running' }
        if (-not ((Test-IsAdmin) -or (Test-InGroupToken $script:HyperVAdminsSid))) {
            return New-DepResult $false "enabled, but the current user is not in 'Hyper-V Administrators'"
        }
        return New-DepResult $true 'ok'
    } `
    -Install {
        if (Test-HyperVEnabled) { return }
        Write-Info 'Enabling the Hyper-V feature'
        $code = Invoke-Elevated 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null' 'enabling Hyper-V'
        if ($code -ne 0) { Stop-Devkit "Enabling Hyper-V failed (exit $code)." }
        Exit-Pending 'reboot' 'Hyper-V was enabled and Windows must restart to finish the installation.'
    } `
    -Configure {
        if ((Get-Service -Name 'vmms').Status -ne 'Running') {
            $code = Invoke-Elevated 'Start-Service vmms' 'starting the Hyper-V service'
            if ($code -ne 0) { Stop-Devkit "Could not start the Hyper-V service (exit $code)." }
        }
        if ((Test-IsAdmin) -or (Test-InGroupToken $script:HyperVAdminsSid)) { return }
        if (-not (Test-InHyperVAdminsGroup)) {
            $code = Invoke-Elevated "Add-LocalGroupMember -SID '$script:HyperVAdminsSid' -Member '$env:USERDOMAIN\$env:USERNAME'" "adding your user to 'Hyper-V Administrators'"
            if ($code -ne 0) { Stop-Devkit "Could not add $env:USERNAME to 'Hyper-V Administrators' (exit $code)." }
        }
        Exit-Pending 'relogin' "User $env:USERNAME is in 'Hyper-V Administrators', which only takes effect after signing in again."
    }
