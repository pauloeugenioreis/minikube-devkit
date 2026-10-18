# devkit examples: manages the KEDA examples.

function Invoke-Examples {
    param([string[]] $Arguments = @())
    $action = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    switch ($action) {
        'deploy' {
            Assert-ClusterRunning
            Publish-Examples -Rebuild:($Arguments -contains '-Rebuild' -or $Arguments -contains '--rebuild')
        }
        'remove' { Assert-ClusterRunning; Remove-Examples }
        'produce' {
            Assert-ClusterRunning
            $target = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
            $count = if ($Arguments.Count -gt 2) { $Arguments[2] } else { '50' }
            if ($target -notin 'rabbitmq', 'redis') { Stop-Devkit 'Usage: .\devkit.ps1 examples produce rabbitmq|redis [COUNT]' }
            if (-not (Test-Int $count)) { Stop-Devkit 'COUNT must be a whole number' }
            if (-not (Invoke-ExamplesProducer $target ([int] $count))) { $script:DevkitExitCode = 1; return }
            Write-Info "Watch it scale: kubectl --context $(Get-Cfg 'DEVKIT_PROFILE') -n $(Get-Cfg 'DEVKIT_EXAMPLES_NAMESPACE') get deploy -w"
        }
        default {
            Write-Host @'
Usage: .\devkit.ps1 examples <action>
  deploy [-Rebuild]           Build the worker image and apply the ScaledObjects
  remove                      Delete the examples namespace
  produce rabbitmq|redis [N]  Send N messages (default 50) and let KEDA scale the worker
'@
        }
    }
    return
}
