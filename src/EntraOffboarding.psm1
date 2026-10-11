#Requires -Version 7.0
<#
    EntraOffboarding module
    Step-by-step, auditable employee offboarding for Entra ID / Microsoft 365.
    Every step honours -WhatIf / -Confirm and writes a row to a CSV audit log.
#>

Set-StrictMode -Version Latest

$script:LogFile = $null
$script:LogEntries = [System.Collections.Generic.List[object]]::new()

$script:DefaultConfig = [ordered]@{
    TenantId                 = $null
    LogFolder                = './logs'
    Steps                    = [ordered]@{
        DisableAccount         = $true
        RevokeSessions         = $true
        SetAutoReply           = $true
        ConvertToSharedMailbox = $true
        GrantManagerAccess     = $true
        HideFromGAL            = $true
        RemoveGroupMemberships = $true
        RemoveLicenses         = $true
    }
    AutoReply                = [ordered]@{
        InternalMessage  = '{DisplayName} is no longer with the company. Please contact {ManagerName} ({ManagerEmail}).'
        ExternalMessage  = 'Thank you for your email. {DisplayName} is no longer with the company. Please contact {ManagerEmail}.'
        ExternalAudience = 'All'
    }
    ManagerAccess            = [ordered]@{
        UseEntraManager = $true
        AccessRights    = 'FullAccess'
        AutoMapping     = $true
    }
    ExcludedGroupIds         = @()
    ExcludedGroupNamePatterns = @()
}

#region Helpers
function Write-OffboardLog {
    <#
    .SYNOPSIS
        Records one offboarding action to the in-memory log and the CSV audit file.
    .PARAMETER User
        UPN of the user being offboarded.
    .PARAMETER Action
        Step name, e.g. DisableAccount.
    .PARAMETER Target
        What the action applied to (user, group, SKU, mailbox).
    .PARAMETER Status
        Success, WhatIf, Skipped, Failed or Info.
    .PARAMETER Details
        Free-text detail or error message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = '',
        [Parameter(Mandatory)][ValidateSet('Success', 'WhatIf', 'Skipped', 'Failed', 'Info')][string]$Status,
        [string]$Details = ''
    )
    $entry = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        User      = $User
        Action    = $Action
        Target    = $Target
        Status    = $Status
        Details   = $Details
        Operator  = [Environment]::UserName
    }
    $script:LogEntries.Add($entry)
    if ($script:LogFile) {
        # Bypass ShouldProcess: the audit log must be written even during -WhatIf.
        $entry | Export-Csv -LiteralPath $script:LogFile -Append -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false
    }
    $msg = "[$Status] $Action $Target $Details".Trim()
    if ($Status -eq 'Failed') { Write-Warning $msg } else { Write-Verbose $msg }
}

function Set-OffboardLogFile {
    <#
    .SYNOPSIS
        Sets (and creates the folder for) the CSV audit log used by Write-OffboardLog.
    .PARAMETER Path
        Full path of the CSV file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Use as audit log') -or $WhatIfPreference) {
        $script:LogFile = $Path
    }
    $script:LogEntries.Clear()
}

function Get-OffboardLogEntry {
    <#
    .SYNOPSIS
        Returns the log entries recorded in this session.
    #>
    [CmdletBinding()]
    param()
    $script:LogEntries.ToArray()
}

function Get-OffboardStepStatus {
    # Internal: status to log when ShouldProcess returns $false.
    if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' }
}

function Expand-OffboardTemplate {
    <#
    .SYNOPSIS
        Replaces {Token} placeholders in a message template.
    .PARAMETER Template
        Text with {DisplayName}, {ManagerName}, {ManagerEmail}, {UserPrincipalName} tokens.
    .PARAMETER Values
        Hashtable of token values.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template, [Parameter(Mandatory)][hashtable]$Values)
    $out = $Template
    foreach ($k in $Values.Keys) { $out = $out.Replace("{$k}", [string]$Values[$k]) }
    $out
}
#endregion

#region Config
function Import-OffboardConfig {
    <#
    .SYNOPSIS
        Loads the JSON config, merges it over safe defaults and validates it.
    .PARAMETER Path
        Path to the JSON config file. If omitted, defaults are returned.
    .EXAMPLE
        $cfg = Import-OffboardConfig -Path ./config/offboarding.config.json
    #>
    [CmdletBinding()]
    param([string]$Path)

    $cfg = $script:DefaultConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
    if (-not $Path) { return $cfg }

    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    try {
        $user = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Config file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    foreach ($key in $user.Keys) {
        if (-not $cfg.Contains($key)) { throw "Unknown config key '$key'. Valid keys: $($cfg.Keys -join ', ')" }
        if ($cfg[$key] -is [System.Collections.IDictionary] -and $user[$key] -is [System.Collections.IDictionary]) {
            foreach ($sub in $user[$key].Keys) {
                if (-not $cfg[$key].Contains($sub)) { throw "Unknown config key '$key.$sub'" }
                $cfg[$key][$sub] = $user[$key][$sub]
            }
        }
        else {
            $cfg[$key] = $user[$key]
        }
    }

    foreach ($step in @($cfg.Steps.Keys)) {
        if ($cfg.Steps[$step] -isnot [bool]) { throw "Steps.$step must be true or false" }
    }
    if ($cfg.ManagerAccess.AccessRights -notin 'FullAccess', 'ReadPermission') {
        throw 'ManagerAccess.AccessRights must be FullAccess or ReadPermission'
    }
    if ($cfg.AutoReply.ExternalAudience -notin 'None', 'Known', 'All') {
        throw 'AutoReply.ExternalAudience must be None, Known or All'
    }
    foreach ($id in @($cfg.ExcludedGroupIds)) {
        if ($id -notmatch '^[0-9a-fA-F-]{36}$') { throw "ExcludedGroupIds contains an invalid GUID: $id" }
    }
    $cfg
}
#endregion

#region Connection
function Connect-OffboardService {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph (and Exchange Online when mailbox steps are enabled).
    .PARAMETER TenantId
        Tenant ID or primary domain.
    .PARAMETER ClientId
        App registration ID for app-only auth (requires CertificateThumbprint).
    .PARAMETER CertificateThumbprint
        Certificate thumbprint for app-only auth.
    .PARAMETER Organization
        Exchange Online organization (e.g. contoso.onmicrosoft.com) - required for app-only Exchange auth.
    .PARAMETER SkipExchange
        Do not connect to Exchange Online.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Delegated')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
        [Parameter(Mandatory, ParameterSetName = 'App')][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ClientId,
        [Parameter(Mandatory, ParameterSetName = 'App')][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertificateThumbprint,
        [Parameter(ParameterSetName = 'App')][string]$Organization = $TenantId,
        [switch]$SkipExchange
    )
    $graph = @{ TenantId = $TenantId; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($PSCmdlet.ParameterSetName -eq 'App') {
        $graph.ClientId = $ClientId; $graph.CertificateThumbprint = $CertificateThumbprint
    }
    else {
        $graph.Scopes = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'LicenseAssignment.ReadWrite.All', 'Directory.Read.All')
    }
    Connect-MgGraph @graph | Out-Null

    if (-not $SkipExchange) {
        if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
            throw 'ExchangeOnlineManagement module not found. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
        }
        $exo = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($PSCmdlet.ParameterSetName -eq 'App') {
            $exo.AppId = $ClientId; $exo.CertificateThumbprint = $CertificateThumbprint; $exo.Organization = $Organization
        }
        Connect-ExchangeOnline @exo
    }
}
#endregion

#region Lookups
function Get-OffboardUser {
    <#
    .SYNOPSIS
        Gets the user (with licence assignment states) and their manager from Graph.
    .PARAMETER UserPrincipalName
        UPN or object ID of the user.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserPrincipalName)

    $select = 'id,displayName,userPrincipalName,mail,accountEnabled,assignedLicenses,licenseAssignmentStates,onPremisesSyncEnabled'
    $id = [uri]::EscapeDataString($UserPrincipalName)
    $user = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$id`?`$select=$select" -OutputType PSObject -ErrorAction Stop

    $manager = $null
    try {
        $manager = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$($user.id)/manager?`$select=id,displayName,userPrincipalName,mail" -OutputType PSObject -ErrorAction Stop
    }
    catch {
        Write-Verbose "No manager found for $UserPrincipalName"
    }
    [pscustomobject]@{ User = $user; Manager = $manager }
}

function Get-OffboardGroupMembership {
    <#
    .SYNOPSIS
        Returns the groups the user is a direct member of (with paging).
    .PARAMETER UserId
        Object ID of the user.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)
    $uri = "https://graph.microsoft.com/v1.0/users/$UserId/memberOf/microsoft.graph.group?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,onPremisesSyncEnabled,membershipRule&`$top=999"
    $all = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        foreach ($g in @($r.value)) { $all.Add($g) }
        $uri = if ($r.PSObject.Properties['@odata.nextLink']) { $r.'@odata.nextLink' } else { $null }
    }
    $all.ToArray()
}
#endregion

#region Steps
function Disable-OffboardAccount {
    <#
    .SYNOPSIS
        Blocks sign-in (accountEnabled = false).
    .PARAMETER User
        User object from Get-OffboardUser.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User)
    $upn = $User.userPrincipalName
    if ($User.PSObject.Properties['onPremisesSyncEnabled'] -and $User.onPremisesSyncEnabled) {
        Write-OffboardLog -User $upn -Action DisableAccount -Target $upn -Status Skipped -Details 'Synced from on-prem AD; disable the account in Active Directory'
        return
    }
    if ($User.PSObject.Properties['accountEnabled'] -and -not $User.accountEnabled) {
        Write-OffboardLog -User $upn -Action DisableAccount -Target $upn -Status Skipped -Details 'Already disabled'
        return
    }
    if ($PSCmdlet.ShouldProcess($upn, 'Disable sign-in')) {
        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($User.id)" -Body (@{ accountEnabled = $false } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-OffboardLog -User $upn -Action DisableAccount -Target $upn -Status Success
    }
    else { Write-OffboardLog -User $upn -Action DisableAccount -Target $upn -Status (Get-OffboardStepStatus) }
}

function Revoke-OffboardSession {
    <#
    .SYNOPSIS
        Revokes all refresh tokens / sign-in sessions.
    .PARAMETER User
        User object from Get-OffboardUser.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User)
    $upn = $User.userPrincipalName
    if ($PSCmdlet.ShouldProcess($upn, 'Revoke sign-in sessions')) {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$($User.id)/revokeSignInSessions" -ErrorAction Stop | Out-Null
        Write-OffboardLog -User $upn -Action RevokeSessions -Target $upn -Status Success
    }
    else { Write-OffboardLog -User $upn -Action RevokeSessions -Target $upn -Status (Get-OffboardStepStatus) }
}

function Set-OffboardAutoReply {
    <#
    .SYNOPSIS
        Enables an out-of-office auto-reply on the mailbox (Exchange Online).
    .PARAMETER User
        User object.
    .PARAMETER InternalMessage
        Message for internal senders.
    .PARAMETER ExternalMessage
        Message for external senders.
    .PARAMETER ExternalAudience
        None, Known or All.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object]$User,
        [Parameter(Mandatory)][string]$InternalMessage,
        [string]$ExternalMessage = $InternalMessage,
        [ValidateSet('None', 'Known', 'All')][string]$ExternalAudience = 'All'
    )
    $upn = $User.userPrincipalName
    if ($PSCmdlet.ShouldProcess($upn, 'Enable auto-reply')) {
        Set-MailboxAutoReplyConfiguration -Identity $upn -AutoReplyState Enabled -InternalMessage $InternalMessage `
            -ExternalMessage $ExternalMessage -ExternalAudience $ExternalAudience -ErrorAction Stop
        Write-OffboardLog -User $upn -Action SetAutoReply -Target $upn -Status Success -Details "ExternalAudience=$ExternalAudience"
    }
    else { Write-OffboardLog -User $upn -Action SetAutoReply -Target $upn -Status (Get-OffboardStepStatus) }
}

function ConvertTo-OffboardSharedMailbox {
    <#
    .SYNOPSIS
        Converts the user mailbox to a shared mailbox so the licence can be removed without losing mail.
    .PARAMETER User
        User object.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User)
    $upn = $User.userPrincipalName
    if ($PSCmdlet.ShouldProcess($upn, 'Convert mailbox to Shared')) {
        Set-Mailbox -Identity $upn -Type Shared -ErrorAction Stop
        Write-OffboardLog -User $upn -Action ConvertToSharedMailbox -Target $upn -Status Success
    }
    else { Write-OffboardLog -User $upn -Action ConvertToSharedMailbox -Target $upn -Status (Get-OffboardStepStatus) }
}

function Grant-OffboardManagerAccess {
    <#
    .SYNOPSIS
        Gives the manager (or a delegate) access to the mailbox.
    .PARAMETER User
        User object.
    .PARAMETER DelegateUpn
        UPN of the person receiving access.
    .PARAMETER AccessRights
        FullAccess or ReadPermission.
    .PARAMETER AutoMapping
        Auto-add the mailbox to the delegate's Outlook.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object]$User,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DelegateUpn,
        [ValidateSet('FullAccess', 'ReadPermission')][string]$AccessRights = 'FullAccess',
        [bool]$AutoMapping = $true
    )
    $upn = $User.userPrincipalName
    if ($PSCmdlet.ShouldProcess($upn, "Grant $AccessRights to $DelegateUpn")) {
        Add-MailboxPermission -Identity $upn -User $DelegateUpn -AccessRights $AccessRights -InheritanceType All -AutoMapping $AutoMapping -ErrorAction Stop | Out-Null
        Write-OffboardLog -User $upn -Action GrantManagerAccess -Target $DelegateUpn -Status Success -Details $AccessRights
    }
    else { Write-OffboardLog -User $upn -Action GrantManagerAccess -Target $DelegateUpn -Status (Get-OffboardStepStatus) -Details $AccessRights }
}

function Hide-OffboardFromGAL {
    <#
    .SYNOPSIS
        Hides the mailbox from the Global Address List.
    .PARAMETER User
        User object.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User)
    $upn = $User.userPrincipalName
    if ($PSCmdlet.ShouldProcess($upn, 'Hide from address lists')) {
        Set-Mailbox -Identity $upn -HiddenFromAddressListsEnabled $true -ErrorAction Stop
        Write-OffboardLog -User $upn -Action HideFromGAL -Target $upn -Status Success
    }
    else { Write-OffboardLog -User $upn -Action HideFromGAL -Target $upn -Status (Get-OffboardStepStatus) }
}

function Remove-OffboardGroupMembership {
    <#
    .SYNOPSIS
        Removes the user from every direct group membership it safely can.
    .DESCRIPTION
        Skips dynamic groups (membership is rule-based), groups synced from on-prem AD,
        and anything in the exclusion lists. Distribution lists and mail-enabled security
        groups are removed through Exchange Online; everything else through Graph.
        Each group is handled independently so one failure does not stop the rest.
    .PARAMETER User
        User object.
    .PARAMETER ExcludedGroupId
        Group object IDs to leave untouched.
    .PARAMETER ExcludedGroupNamePattern
        Wildcard patterns of group display names to leave untouched.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object]$User,
        [string[]]$ExcludedGroupId = @(),
        [string[]]$ExcludedGroupNamePattern = @()
    )
    $upn = $User.userPrincipalName
    $groups = @(Get-OffboardGroupMembership -UserId $User.id)
    if (-not $groups) {
        Write-OffboardLog -User $upn -Action RemoveGroupMembership -Status Info -Details 'No direct group memberships'
        return
    }
    foreach ($g in $groups) {
        $name = "$($g.displayName) ($($g.id))"
        $types = @($g.groupTypes)
        $isDynamic = $types -contains 'DynamicMembership'
        $isUnified = $types -contains 'Unified'
        $excluded = ($g.id -in $ExcludedGroupId) -or [bool]($ExcludedGroupNamePattern | Where-Object { $g.displayName -like $_ })

        if ($excluded)  { Write-OffboardLog -User $upn -Action RemoveGroupMembership -Target $name -Status Skipped -Details 'Excluded by config'; continue }
        if ($isDynamic) { Write-OffboardLog -User $upn -Action RemoveGroupMembership -Target $name -Status Skipped -Details 'Dynamic group (rule-based)'; continue }
        if ($g.PSObject.Properties['onPremisesSyncEnabled'] -and $g.onPremisesSyncEnabled) {
            Write-OffboardLog -User $upn -Action RemoveGroupMembership -Target $name -Status Skipped -Details 'Synced from on-prem AD; remove in Active Directory'; continue
        }

        $viaExchange = $g.mailEnabled -and -not $isUnified
        if ($PSCmdlet.ShouldProcess($name, "Remove $upn")) {
            try {
                if ($viaExchange) {
                    Remove-DistributionGroupMember -Identity $g.id -Member $upn -BypassSecurityGroupManagerCheck -Confirm:$false -ErrorAction Stop
                }
                else {
                    Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members/$($User.id)/`$ref" -ErrorAction Stop | Out-Null
                }
                Write-OffboardLog -User $upn -Action RemoveGroupMembership -Target $name -Status Success -Details $(if ($viaExchange) { 'Exchange' } else { 'Graph' })
            }
            catch {
                Write-OffboardLog -User $upn -Action RemoveGroupMembership -Target $name -Status Failed -Details $_.Exception.Message
            }
        }
        else { Write-OffboardLog -User $upn -Action RemoveGroupMembership -Target $name -Status (Get-OffboardStepStatus) }
    }
}

function Remove-OffboardLicense {
    <#
    .SYNOPSIS
        Removes directly-assigned licences. Group-based licences are reported, not removed.
    .PARAMETER User
        User object (must include assignedLicenses / licenseAssignmentStates).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User)
    $upn = $User.userPrincipalName

    $direct = @()
    $inherited = @()
    if ($User.PSObject.Properties['licenseAssignmentStates'] -and $User.licenseAssignmentStates) {
        foreach ($s in @($User.licenseAssignmentStates)) {
            if ($s.assignedByGroup) { $inherited += $s.skuId } else { $direct += $s.skuId }
        }
    }
    elseif ($User.PSObject.Properties['assignedLicenses']) {
        $direct = @($User.assignedLicenses | ForEach-Object { $_.skuId })
    }
    $direct = @($direct | Select-Object -Unique)
    $inherited = @($inherited | Select-Object -Unique | Where-Object { $_ -notin $direct })

    foreach ($sku in $inherited) {
        Write-OffboardLog -User $upn -Action RemoveLicense -Target $sku -Status Skipped -Details 'Assigned by group; removed when group membership is removed'
    }
    if (-not $direct) {
        Write-OffboardLog -User $upn -Action RemoveLicense -Status Info -Details 'No directly assigned licences'
        return
    }
    if ($PSCmdlet.ShouldProcess($upn, "Remove licence(s) $($direct -join ', ')")) {
        $body = @{ addLicenses = @(); removeLicenses = $direct } | ConvertTo-Json -Depth 3
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$($User.id)/assignLicense" -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
        foreach ($sku in $direct) { Write-OffboardLog -User $upn -Action RemoveLicense -Target $sku -Status Success }
    }
    else { foreach ($sku in $direct) { Write-OffboardLog -User $upn -Action RemoveLicense -Target $sku -Status (Get-OffboardStepStatus) } }
}
#endregion

#region Orchestrator
function Invoke-EntraUserOffboarding {
    <#
    .SYNOPSIS
        Runs the full offboarding sequence for one user.
    .DESCRIPTION
        Order matters: the mailbox is converted to Shared and delegated BEFORE licences
        are removed, so no mail is lost. A failing step is logged and the run continues
        with the remaining steps; the returned object lists every action.
    .PARAMETER UserPrincipalName
        UPN of the departing user.
    .PARAMETER Config
        Hashtable from Import-OffboardConfig.
    .PARAMETER DelegateUpn
        Who receives mailbox access. Defaults to the user's Entra manager when
        ManagerAccess.UseEntraManager is true.
    .EXAMPLE
        Invoke-EntraUserOffboarding -UserPrincipalName jdoe@contoso.com -Config (Import-OffboardConfig) -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$UserPrincipalName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$DelegateUpn
    )

    $upn = $UserPrincipalName
    Write-OffboardLog -User $upn -Action Start -Status Info -Details $(if ($WhatIfPreference) { 'WhatIf mode - no changes will be made' } else { 'Live run' })

    try {
        $lookup = Get-OffboardUser -UserPrincipalName $upn
    }
    catch {
        Write-OffboardLog -User $upn -Action LookupUser -Status Failed -Details $_.Exception.Message
        return [pscustomobject]@{ User = $upn; Succeeded = $false; Failed = 1; Actions = @(Get-OffboardLogEntry | Where-Object User -eq $upn) }
    }
    $user = $lookup.User
    $manager = $lookup.Manager
    Write-OffboardLog -User $upn -Action LookupUser -Target $user.id -Status Info -Details "Manager: $(if ($manager) { $manager.userPrincipalName } else { 'none' })"

    if (-not $DelegateUpn -and $Config.ManagerAccess.UseEntraManager -and $manager) {
        $DelegateUpn = $manager.userPrincipalName
    }
    $tokens = @{
        DisplayName       = $user.displayName
        UserPrincipalName = $user.userPrincipalName
        ManagerName       = if ($manager) { $manager.displayName } else { 'our team' }
        ManagerEmail      = if ($DelegateUpn) { $DelegateUpn } elseif ($manager) { $manager.mail } else { '' }
    }

    $steps = [ordered]@{
        DisableAccount         = { Disable-OffboardAccount -User $user }
        RevokeSessions         = { Revoke-OffboardSession -User $user }
        SetAutoReply           = {
            Set-OffboardAutoReply -User $user -InternalMessage (Expand-OffboardTemplate $Config.AutoReply.InternalMessage $tokens) `
                -ExternalMessage (Expand-OffboardTemplate $Config.AutoReply.ExternalMessage $tokens) -ExternalAudience $Config.AutoReply.ExternalAudience
        }
        ConvertToSharedMailbox = { ConvertTo-OffboardSharedMailbox -User $user }
        GrantManagerAccess     = {
            if ($DelegateUpn) {
                Grant-OffboardManagerAccess -User $user -DelegateUpn $DelegateUpn -AccessRights $Config.ManagerAccess.AccessRights -AutoMapping ([bool]$Config.ManagerAccess.AutoMapping)
            }
            else { Write-OffboardLog -User $upn -Action GrantManagerAccess -Status Skipped -Details 'No manager found and no -DelegateUpn given' }
        }
        HideFromGAL            = { Hide-OffboardFromGAL -User $user }
        RemoveGroupMemberships = { Remove-OffboardGroupMembership -User $user -ExcludedGroupId @($Config.ExcludedGroupIds) -ExcludedGroupNamePattern @($Config.ExcludedGroupNamePatterns) }
        RemoveLicenses         = { Remove-OffboardLicense -User $user }
    }

    foreach ($name in $steps.Keys) {
        if (-not $Config.Steps[$name]) {
            Write-OffboardLog -User $upn -Action $name -Status Skipped -Details 'Disabled in config'
            continue
        }
        try { & $steps[$name] }
        catch { Write-OffboardLog -User $upn -Action $name -Status Failed -Details $_.Exception.Message }
    }

    $actions = @(Get-OffboardLogEntry | Where-Object User -eq $upn)
    $failed = @($actions | Where-Object Status -eq 'Failed').Count
    Write-OffboardLog -User $upn -Action Finish -Status Info -Details "$failed failed step(s)"
    [pscustomobject]@{
        User      = $upn
        Succeeded = ($failed -eq 0)
        Failed    = $failed
        Actions   = @(Get-OffboardLogEntry | Where-Object User -eq $upn)
    }
}
#endregion

Export-ModuleMember -Function Write-OffboardLog, Set-OffboardLogFile, Get-OffboardLogEntry, Expand-OffboardTemplate,
    Import-OffboardConfig, Connect-OffboardService, Get-OffboardUser, Get-OffboardGroupMembership,
    Disable-OffboardAccount, Revoke-OffboardSession, Set-OffboardAutoReply, ConvertTo-OffboardSharedMailbox,
    Grant-OffboardManagerAccess, Hide-OffboardFromGAL, Remove-OffboardGroupMembership, Remove-OffboardLicense,
    Invoke-EntraUserOffboarding
