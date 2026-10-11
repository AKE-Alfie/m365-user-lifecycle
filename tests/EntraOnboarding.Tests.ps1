#Requires -Modules Pester
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global stubs stand in for Graph/Exchange cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror real cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs only')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs only')]
param()

BeforeAll {
    function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
    function global:Connect-MgGraph { param($TenantId, $ClientId, $CertificateThumbprint, $Scopes, [switch]$NoWelcome) }
    function global:Connect-ExchangeOnline { param($AppId, $CertificateThumbprint, $Organization, $ShowBanner) }
    function global:Get-EXOMailbox { param($Identity) }
    function global:Set-MailboxRegionalConfiguration { param($Identity, $TimeZone, $Language, [switch]$LocalizeDefaultFolderName) }
    function global:Add-MailboxPermission { param($Identity, $User, $AccessRights, $InheritanceType, $AutoMapping) }
    function global:Add-RecipientPermission { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Trustee, $AccessRights) }
    function global:Add-DistributionGroupMember { param($Identity, $Member, [switch]$BypassSecurityGroupManagerCheck) }

    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $RepoRoot 'src/EntraOnboarding.psm1') -Force
    $script:M = 'EntraOnboarding'
    $script:TemplatePath = Join-Path $RepoRoot 'config/role-templates.example.json'
    $script:HiresPath = Join-Path $RepoRoot 'examples/new-hires.example.csv'

    $script:Skus = @(
        [pscustomobject]@{ skuId = 'id-e3'; skuPartNumber = 'SPE_E3'; prepaidUnits = [pscustomobject]@{ enabled = 25 }; consumedUnits = 20 }
        [pscustomobject]@{ skuId = 'id-pbi'; skuPartNumber = 'POWER_BI_PRO'; prepaidUnits = [pscustomobject]@{ enabled = 5 }; consumedUnits = 5 }
        [pscustomobject]@{ skuId = 'id-f1'; skuPartNumber = 'SPE_F1'; prepaidUnits = [pscustomobject]@{ enabled = 10 }; consumedUnits = 2 }
    )
    function script:Register-OnboardMock {
        Mock -ModuleName $M Invoke-MgGraphRequest { throw 'Resource does not exist (404 NotFound)' } -ParameterFilter { $Method -eq 'GET' -and $Uri -match '/users/[^/]+\?\$select=id$' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'mgr-id'; displayName = 'Sam Lead' } } -ParameterFilter { $Method -eq 'GET' -and $Uri -match 'select=id,displayName$' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ value = $script:Skus } } -ParameterFilter { $Uri -like '*subscribedSkus*' }
        Mock -ModuleName $M Invoke-MgGraphRequest {
            $n = [uri]::UnescapeDataString($Uri) -replace ".*displayName eq '([^']+)'.*", '$1'
            [pscustomobject]@{ value = @([pscustomobject]@{ id = "grp-$n"; displayName = $n; groupTypes = @(if ($n -like 'Team*') { 'Unified' }); mailEnabled = ($n -like 'DL-*' -or $n -like 'Team*') }) }
        } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/groups?*' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'new-user-id'; userPrincipalName = ($Body | ConvertFrom-Json).userPrincipalName } } -ParameterFilter { $Method -eq 'POST' -and $Uri -match '/users$' }
        Mock -ModuleName $M Invoke-MgGraphRequest { } -ParameterFilter { $Method -in 'PUT', 'PATCH', 'DELETE' -or ($Method -eq 'POST' -and $Uri -notmatch '/users$') }
        Mock -ModuleName $M Get-EXOMailbox { [pscustomobject]@{ Identity = $Identity } }
        Mock -ModuleName $M Set-MailboxRegionalConfiguration { }
        Mock -ModuleName $M Add-MailboxPermission { }
        Mock -ModuleName $M Add-RecipientPermission { }
        Mock -ModuleName $M Add-DistributionGroupMember { }
    }
}

Describe 'Input validation' {
    It 'loads the example role template' {
        $t = Import-OnboardRoleTemplate -Path $TemplatePath
        $t.Roles.Keys | Should -Contain 'Sales'
        $t.Roles.Frontline.SharedMailboxes.Count | Should -Be 0
    }
    It 'rejects a weak password length' {
        $p = Join-Path $TestDrive 't.json'
        '{ "Defaults": { "Domain": "x.example", "PasswordLength": 8 }, "Roles": {} }' | Set-Content $p
        { Import-OnboardRoleTemplate -Path $p } | Should -Throw '*at least 12*'
    }
    It 'reads new hires from CSV and normalises dates' {
        $h = @(Import-OnboardNewHire -Path $HiresPath -Template (Import-OnboardRoleTemplate -Path $TemplatePath))
        $h.Count | Should -Be 3
        $h[0].StartDate | Should -Be '2026-11-02'
    }
    It 'reads new hires from JSON' {
        $p = Join-Path $TestDrive 'h.json'
        '[{ "FirstName": "Lee", "LastName": "Wong", "Role": "Sales" }]' | Set-Content $p
        @(Import-OnboardNewHire -Path $p -Template (Import-OnboardRoleTemplate -Path $TemplatePath)).Count | Should -Be 1
    }
    It 'rejects unknown roles and missing fields' {
        $t = Import-OnboardRoleTemplate -Path $TemplatePath
        $p = Join-Path $TestDrive 'bad.csv'
        "FirstName,LastName,Role`nA,B,Pilot" | Set-Content $p
        { Import-OnboardNewHire -Path $p -Template $t } | Should -Throw '*unknown role*'
        "FirstName,LastName,Role`nA,,Sales" | Set-Content $p
        { Import-OnboardNewHire -Path $p -Template $t } | Should -Throw "*missing required field 'LastName'*"
    }
}

Describe 'Helpers' {
    It 'strips diacritics and symbols from nicknames' {
        ConvertTo-OnboardMailNickname -FirstName 'José' -LastName "Núñez-O'Brien" | Should -Be 'jose.nunez-obrien'
    }
    It 'generates strong unique passwords' {
        $a = New-OnboardPassword -Length 16
        $b = New-OnboardPassword -Length 16
        $a.Length | Should -Be 16
        $a | Should -Not -Be $b
        $a | Should -MatchExactly '[A-Z]'
        $a | Should -MatchExactly '[a-z]'
        $a | Should -Match '[0-9]'
        $a | Should -Match '[^A-Za-z0-9]'
    }
    It 'adds a number when the UPN is taken' {
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'exists' } } -ParameterFilter { $Uri -like '*ana.rivera%40*' }
        Mock -ModuleName $M Invoke-MgGraphRequest { throw 'Resource does not exist' } -ParameterFilter { $Uri -like '*ana.rivera2%40*' }
        Get-OnboardAvailableUpn -MailNickname 'ana.rivera' -Domain 'contoso.example' | Should -Be 'ana.rivera2@contoso.example'
    }
}

Describe 'Invoke-EntraUserOnboarding (live run, mocked)' {
    BeforeAll {
        Register-OnboardMock
        Set-OnboardLogFile -Path (Join-Path $TestDrive 'on.csv')
        $t = Import-OnboardRoleTemplate -Path $TemplatePath
        $h = @(Import-OnboardNewHire -Path $HiresPath -Template $t)
        $script:Sales = Invoke-EntraUserOnboarding -Hire $h[0] -Template $t -OutputPath $TestDrive -MailboxTimeoutSeconds 0 -Confirm:$false
        $script:Finance = Invoke-EntraUserOnboarding -Hire $h[1] -Template $t -OutputPath $TestDrive -MailboxTimeoutSeconds 0 -Confirm:$false
    }
    It 'creates the user with role defaults and a forced password change' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter {
            if ($Method -ne 'POST' -or $Uri -notmatch '/users$') { return $false }
            $b = $Body | ConvertFrom-Json
            $b.userPrincipalName -eq 'ana.rivera@contoso.com' -and $b.department -eq 'Sales' -and $b.usageLocation -eq 'US' -and
            $b.passwordProfile.forceChangePasswordNextSignIn -eq $true -and $Body -match '"employeeHireDate":\s*"2026-11-02T00:00:00Z"'
        }
        $Sales.Succeeded | Should -BeTrue
        $Sales.TemporaryPassword | Should -BeOfType [securestring]
    }
    It 'sets the manager, licence and groups (DLs via Exchange)' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'PUT' -and $Uri -like '*manager/$ref' }
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Uri -like '*assignLicense' -and $Body -match 'id-e3' }
        Should -Invoke -Scope Describe -ModuleName $M Add-DistributionGroupMember -Times 1 -Exactly -ParameterFilter { $Identity -eq 'grp-DL-Sales-All' }
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*grp-SG-Sales/members/$ref' }
    }
    It 'configures the mailbox and shared mailbox access' {
        Should -Invoke -Scope Describe -ModuleName $M Set-MailboxRegionalConfiguration -ParameterFilter { $TimeZone -eq 'Pacific Standard Time' }
        Should -Invoke -Scope Describe -ModuleName $M Add-MailboxPermission -ParameterFilter { $Identity -eq 'sales@contoso.com' -and $User -eq 'ana.rivera@contoso.com' }
        Should -Invoke -Scope Describe -ModuleName $M Add-RecipientPermission -ParameterFilter { $AccessRights -eq 'SendAs' }
    }
    It 'logs a failure when a licence has no free seats but finishes the other steps' {
        $Finance.Succeeded | Should -BeFalse
        ($Finance.Actions | Where-Object { $_.Target -eq 'POWER_BI_PRO' }).Status | Should -Be 'Failed'
        ($Finance.Actions | Where-Object { $_.Target -eq 'SPE_E3' }).Status | Should -Be 'Success'
        ($Finance.Actions | Where-Object Action -eq 'WelcomeSheet').Status | Should -Be 'Success'
        $Finance.User | Should -Be 'jose.nunez@contoso.com'
    }
    It 'writes a welcome sheet without the password' {
        $html = Get-Content $Sales.WelcomeSheet -Raw
        $html | Should -Match 'ana.rivera@contoso.com'
        $plain = $Sales.TemporaryPassword | ConvertFrom-SecureString -AsPlainText
        $html.Contains($plain) | Should -BeFalse
    }
    It 'never writes the password to the CSV log' {
        $csv = Get-Content (Join-Path $TestDrive 'on.csv') -Raw
        $csv.Contains(($Sales.TemporaryPassword | ConvertFrom-SecureString -AsPlainText)) | Should -BeFalse
    }
}

Describe 'Invoke-EntraUserOnboarding -WhatIf' {
    It 'makes no changes but logs the plan' {
        Register-OnboardMock
        Set-OnboardLogFile -Path (Join-Path $TestDrive 'wi.csv')
        $t = Import-OnboardRoleTemplate -Path $TemplatePath
        $h = @(Import-OnboardNewHire -Path $HiresPath -Template $t)[2]
        $r = Invoke-EntraUserOnboarding -Hire $h -Template $t -OutputPath $TestDrive -WhatIf
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -Times 0 -ParameterFilter { $Method -ne 'GET' }
        Should -Invoke -ModuleName $M Add-DistributionGroupMember -Times 0
        Should -Invoke -ModuleName $M Set-MailboxRegionalConfiguration -Times 0
        @($r.Actions | Where-Object Status -eq 'WhatIf').Count | Should -BeGreaterThan 3
        $r.TemporaryPassword | Should -BeNullOrEmpty
    }
}

Describe 'Start-EntraOnboarding.ps1 (entry script)' {
    It 'runs a WhatIf dry run from CSV end to end' {
        function global:Invoke-MgGraphRequest {
            param($Method, $Uri, $Body, $ContentType, $OutputType)
            if ($Method -ne 'GET') { throw 'Write attempted during WhatIf' }
            if ($Uri -like '*subscribedSkus*') { return [pscustomobject]@{ value = @([pscustomobject]@{ skuId = 'x'; skuPartNumber = 'SPE_E3'; prepaidUnits = [pscustomobject]@{ enabled = 9 }; consumedUnits = 1 }, [pscustomobject]@{ skuId = 'y'; skuPartNumber = 'POWER_BI_PRO'; prepaidUnits = [pscustomobject]@{ enabled = 9 }; consumedUnits = 1 }, [pscustomobject]@{ skuId = 'z'; skuPartNumber = 'SPE_F1'; prepaidUnits = [pscustomobject]@{ enabled = 9 }; consumedUnits = 1 }) } }
            if ($Uri -like '*/groups?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g'; displayName = 'G'; groupTypes = @(); mailEnabled = $false }) } }
            if ($Uri -match 'select=id$') { throw 'Resource does not exist' }
            [pscustomobject]@{ id = 'm'; displayName = 'Manager' }
        }
        $out = Join-Path $TestDrive 'script'
        $r = @(& (Join-Path $RepoRoot 'Start-EntraOnboarding.ps1') -InputPath $HiresPath -TemplatePath $TemplatePath -SkipConnect -OutputPath $out -WhatIf)
        $r.Count | Should -Be 3
        $r.Failed | Should -Not -Contain 1
        Test-Path $r[0].LogPath | Should -BeTrue
    }
}
