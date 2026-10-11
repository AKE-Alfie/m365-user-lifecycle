#Requires -Modules Pester
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global stubs stand in for Graph/Exchange cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror real cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs only')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs only')]
param()

BeforeAll {
    # Stubs so the module can be tested without Microsoft.Graph / ExchangeOnlineManagement or a tenant.
    function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
    function global:Connect-MgGraph { param($TenantId, $ClientId, $CertificateThumbprint, $Scopes, [switch]$NoWelcome) }
    function global:Connect-ExchangeOnline { param($AppId, $CertificateThumbprint, $Organization, $ShowBanner) }
    function global:Set-Mailbox { param($Identity, $Type, $HiddenFromAddressListsEnabled) }
    function global:Set-MailboxAutoReplyConfiguration { param($Identity, $AutoReplyState, $InternalMessage, $ExternalMessage, $ExternalAudience) }
    function global:Add-MailboxPermission { param($Identity, $User, $AccessRights, $InheritanceType, $AutoMapping) }
    function global:Remove-DistributionGroupMember { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Member, [switch]$BypassSecurityGroupManagerCheck) }

    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $RepoRoot 'src/EntraOffboarding.psm1') -Force
    $script:M = 'EntraOffboarding'

    $script:FakeUser = [pscustomobject]@{
        id = '11111111-1111-1111-1111-111111111111'; displayName = 'Jordan Doe'; userPrincipalName = 'jdoe@contoso.example'
        mail = 'jdoe@contoso.example'; accountEnabled = $true; onPremisesSyncEnabled = $null
        assignedLicenses = @([pscustomobject]@{ skuId = 'sku-e3' }, [pscustomobject]@{ skuId = 'sku-visio' })
        licenseAssignmentStates = @(
            [pscustomobject]@{ skuId = 'sku-e3'; assignedByGroup = $null }
            [pscustomobject]@{ skuId = 'sku-visio'; assignedByGroup = '99999999-9999-9999-9999-999999999999' }
        )
    }
    $script:FakeManager = [pscustomobject]@{ id = 'mgr'; displayName = 'Sam Lead'; userPrincipalName = 'slead@contoso.example'; mail = 'slead@contoso.example' }
    $script:FakeGroups = @(
        [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000001'; displayName = 'SG-Finance'; groupTypes = @(); mailEnabled = $false; securityEnabled = $true; onPremisesSyncEnabled = $null }
        [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000002'; displayName = 'Team Sales'; groupTypes = @('Unified'); mailEnabled = $true; securityEnabled = $false; onPremisesSyncEnabled = $null }
        [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000003'; displayName = 'DL-AllStaff'; groupTypes = @(); mailEnabled = $true; securityEnabled = $false; onPremisesSyncEnabled = $null }
        [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000004'; displayName = 'Dyn-Sales-Users'; groupTypes = @('DynamicMembership'); mailEnabled = $false; securityEnabled = $true; onPremisesSyncEnabled = $null }
        [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000005'; displayName = 'SG-Retention-Hold'; groupTypes = @(); mailEnabled = $false; securityEnabled = $true; onPremisesSyncEnabled = $null }
        [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000006'; displayName = 'AD-VPN-Users'; groupTypes = @(); mailEnabled = $false; securityEnabled = $true; onPremisesSyncEnabled = $true }
    )

    function script:Register-GraphMock {
        Mock -ModuleName $M Invoke-MgGraphRequest { $script:FakeUser } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/users/jdoe*' }
        Mock -ModuleName $M Invoke-MgGraphRequest { $script:FakeManager } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/manager*' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ value = $script:FakeGroups } } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/memberOf/*' }
        Mock -ModuleName $M Invoke-MgGraphRequest { } -ParameterFilter { $Method -ne 'GET' }
        Mock -ModuleName $M Set-Mailbox { }
        Mock -ModuleName $M Set-MailboxAutoReplyConfiguration { }
        Mock -ModuleName $M Add-MailboxPermission { }
        Mock -ModuleName $M Remove-DistributionGroupMember { }
    }
}

Describe 'Import-OffboardConfig' {
    It 'returns safe defaults with no path' {
        $c = Import-OffboardConfig
        $c.Steps.DisableAccount | Should -BeTrue
        $c.ManagerAccess.AccessRights | Should -Be 'FullAccess'
    }
    It 'loads and merges the example config' {
        $c = Import-OffboardConfig -Path (Join-Path $RepoRoot 'config/offboarding.config.example.json')
        $c.TenantId | Should -Be 'contoso.onmicrosoft.com'
        $c.ExcludedGroupNamePatterns | Should -Contain 'SG-Retention-*'
    }
    It 'rejects unknown keys' {
        $p = Join-Path $TestDrive 'bad.json'
        '{ "Stepz": {} }' | Set-Content $p
        { Import-OffboardConfig -Path $p } | Should -Throw '*Unknown config key*'
    }
    It 'rejects non-boolean step values' {
        $p = Join-Path $TestDrive 'bad2.json'
        '{ "Steps": { "DisableAccount": "yes" } }' | Set-Content $p
        { Import-OffboardConfig -Path $p } | Should -Throw '*true or false*'
    }
    It 'rejects invalid JSON' {
        $p = Join-Path $TestDrive 'bad3.json'
        '{ not json' | Set-Content $p
        { Import-OffboardConfig -Path $p } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Expand-OffboardTemplate' {
    It 'replaces tokens' {
        Expand-OffboardTemplate -Template 'Contact {ManagerName} at {ManagerEmail}' -Values @{ ManagerName = 'Sam'; ManagerEmail = 's@x.example' } |
            Should -Be 'Contact Sam at s@x.example'
    }
}

Describe 'Invoke-EntraUserOffboarding (live run, mocked)' {
    BeforeAll {
        Register-GraphMock
        Set-OffboardLogFile -Path (Join-Path $TestDrive 'live.csv')
        $cfg = Import-OffboardConfig -Path (Join-Path $RepoRoot 'config/offboarding.config.example.json')
        $script:Result = Invoke-EntraUserOffboarding -UserPrincipalName 'jdoe@contoso.example' -Config $cfg -Confirm:$false
    }

    It 'completes without failures' {
        $Result.Succeeded | Should -BeTrue
        $Result.Failed | Should -Be 0
    }
    It 'disables the account and revokes sessions via Graph' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Body -match '"accountEnabled":\s*false' }
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*revokeSignInSessions' }
    }
    It 'converts the mailbox, sets auto-reply and grants the Entra manager access' {
        Should -Invoke -Scope Describe -ModuleName $M Set-Mailbox -Times 1 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        Should -Invoke -Scope Describe -ModuleName $M Set-MailboxAutoReplyConfiguration -Times 1 -Exactly -ParameterFilter { $InternalMessage -like '*Jordan Doe*Sam Lead*' }
        Should -Invoke -Scope Describe -ModuleName $M Add-MailboxPermission -Times 1 -Exactly -ParameterFilter { $User -eq 'slead@contoso.example' -and $AccessRights -eq 'FullAccess' }
    }
    It 'removes cloud groups via Graph and DLs via Exchange, skipping dynamic, synced and excluded groups' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Should -Invoke -Scope Describe -ModuleName $M Remove-DistributionGroupMember -Times 1 -Exactly
        $skipped = $Result.Actions | Where-Object { $_.Action -eq 'RemoveGroupMembership' -and $_.Status -eq 'Skipped' }
        @($skipped).Count | Should -Be 3
    }
    It 'removes only directly-assigned licences' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*assignLicense' -and $Body -match 'sku-e3' -and $Body -notmatch 'sku-visio' }
        ($Result.Actions | Where-Object { $_.Target -eq 'sku-visio' }).Status | Should -Be 'Skipped'
    }
    It 'converts the mailbox before removing licences' {
        $a = @($Result.Actions.Action)
        [array]::IndexOf($a, 'ConvertToSharedMailbox') | Should -BeLessThan ([array]::IndexOf($a, 'RemoveLicense'))
    }
    It 'writes every action to the CSV log' {
        $rows = Import-Csv (Join-Path $TestDrive 'live.csv')
        $rows.Count | Should -Be $Result.Actions.Count
        $rows[0].PSObject.Properties.Name | Should -Be @('Timestamp', 'User', 'Action', 'Target', 'Status', 'Details', 'Operator')
    }
}

Describe 'Invoke-EntraUserOffboarding -WhatIf' {
    BeforeAll {
        Register-GraphMock
        Set-OffboardLogFile -Path (Join-Path $TestDrive 'whatif.csv')
        $script:Result = Invoke-EntraUserOffboarding -UserPrincipalName 'jdoe@contoso.example' -Config (Import-OffboardConfig) -WhatIf
    }
    It 'makes no changes' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Method -ne 'GET' }
        Should -Invoke -Scope Describe -ModuleName $M Set-Mailbox -Times 0
        Should -Invoke -Scope Describe -ModuleName $M Set-MailboxAutoReplyConfiguration -Times 0
        Should -Invoke -Scope Describe -ModuleName $M Add-MailboxPermission -Times 0
        Should -Invoke -Scope Describe -ModuleName $M Remove-DistributionGroupMember -Times 0
    }
    It 'still logs the planned actions as WhatIf' {
        @($Result.Actions | Where-Object Status -eq 'WhatIf').Count | Should -BeGreaterThan 5
        Test-Path (Join-Path $TestDrive 'whatif.csv') | Should -BeTrue
    }
}

Describe 'Error handling' {
    It 'continues after a failing step and reports it' {
        Register-GraphMock
        Mock -ModuleName $M Set-Mailbox { throw 'Mailbox not found' } -ParameterFilter { $Type -eq 'Shared' }
        Set-OffboardLogFile -Path (Join-Path $TestDrive 'err.csv')
        $r = Invoke-EntraUserOffboarding -UserPrincipalName 'jdoe@contoso.example' -Config (Import-OffboardConfig) -Confirm:$false
        $r.Succeeded | Should -BeFalse
        ($r.Actions | Where-Object { $_.Action -eq 'ConvertToSharedMailbox' }).Status | Should -Be 'Failed'
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Uri -like '*assignLicense' }
    }
    It 'stops cleanly if the user cannot be found' {
        Mock -ModuleName $M Invoke-MgGraphRequest { throw 'Resource does not exist' } -ParameterFilter { $Method -eq 'GET' }
        Set-OffboardLogFile -Path (Join-Path $TestDrive 'nf.csv')
        $r = Invoke-EntraUserOffboarding -UserPrincipalName 'ghost@contoso.example' -Config (Import-OffboardConfig) -Confirm:$false
        $r.Succeeded | Should -BeFalse
        ($r.Actions | Where-Object Action -eq 'LookupUser').Status | Should -Be 'Failed'
    }
    It 'skips disabling accounts synced from on-prem AD' {
        Mock -ModuleName $M Invoke-MgGraphRequest { }
        Set-OffboardLogFile -Path (Join-Path $TestDrive 'sync.csv')
        $u = $FakeUser.PSObject.Copy(); $u.onPremisesSyncEnabled = $true
        Disable-OffboardAccount -User $u -Confirm:$false
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -Times 0
        (Get-OffboardLogEntry)[-1].Status | Should -Be 'Skipped'
    }
    It 'validates the UPN format' {
        { Invoke-EntraUserOffboarding -UserPrincipalName 'not-an-email' -Config (Import-OffboardConfig) } | Should -Throw
    }
}

Describe 'Start-EntraOffboarding.ps1 (entry script)' {
    It 'runs a WhatIf dry run end to end and writes the log' {
        # The script re-imports the module with -Force, so use the global stubs with fake data.
        $global:EOFake = @{ User = $FakeUser; Manager = $FakeManager; Groups = $FakeGroups }
        function global:Invoke-MgGraphRequest {
            param($Method, $Uri, $Body, $ContentType, $OutputType)
            if ($Method -ne 'GET') { throw 'Write attempted during WhatIf' }
            if ($Uri -like '*/manager*') { return $global:EOFake.Manager }
            if ($Uri -like '*/memberOf/*') { return [pscustomobject]@{ value = $global:EOFake.Groups } }
            $global:EOFake.User
        }
        $log = Join-Path $TestDrive 'script.csv'
        $r = & (Join-Path $RepoRoot 'Start-EntraOffboarding.ps1') -UserPrincipalName 'jdoe@contoso.example' -SkipConnect -LogPath $log -WhatIf
        $r.Failed | Should -Be 0
        $r.WhatIf | Should -BeGreaterThan 5
        (Import-Csv $log | Where-Object Status -eq 'WhatIf').Count | Should -Be $r.WhatIf
    }
}
