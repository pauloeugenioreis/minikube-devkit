# PSScriptAnalyzer settings used locally and in CI:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # A CLI writes to the console on purpose.
        'PSAvoidUsingWriteHost',
        # Internal helpers, not public cmdlets.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        'PSAvoidUsingPositionalParameters',
        # Parameters used inside closures/script blocks are not detected.
        'PSReviewUnusedParameter'
    )
}
