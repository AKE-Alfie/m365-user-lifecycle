@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @()
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('7.0') }
    }
}
