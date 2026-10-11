#Requires -Version 7.0
<#
    EntraOnboarding module
    Creates new Microsoft 365 users from CSV/JSON using role templates: account, manager,
    licences, groups, mailbox settings and a welcome sheet. Honours -WhatIf / -Confirm and
    logs every action to CSV. Passwords are never written to logs or files.
#>

Set-StrictMode -Version Latest

$script:LogFile = $null
$script:LogEntries = [System.Collections.Generic.List[object]]::new()
$script:SkuCache = $null
$script:GroupCache = @{}
$script:Graph = 'https://graph.microsoft.com/v1.0'

#region Logging
function Write-OnboardLog {
    <#
    .SYNOPSIS
        Records one onboarding action (memory + CSV audit file).
    .PARAMETER User
        UPN being onboarded.
    .PARAMETER Action
        Step name.
    .PARAMETER Target
        What the action applied to.
    .PARAMETER Status
        Success, WhatIf, Skipped, Failed or Info.
    .PARAMETER Details
        Extra detail / error text. Never pass secrets here.
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
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); User = $User; Action = $Action
        Target = $Target; Status = $Status; Details = $Details; Operator = [Environment]::UserName
    }
    $script:LogEntries.Add($entry)
    if ($script:LogFile) {
        $entry | Export-Csv -LiteralPath $script:LogFile -Append -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false
    }
    $msg = "[$Status] $Action $Target $Details".Trim()
    if ($Status -eq 'Failed') { Write-Warning $msg } else { Write-Verbose $msg }
}

function Set-OnboardLogFile {
    <#
    .SYNOPSIS
        Sets the CSV audit log path (folder is created) and clears in-memory entries.
    .PARAMETER Path
        CSV path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null }
    if ($PSCmdlet.ShouldProcess($Path, 'Use as audit log') -or $WhatIfPreference) { $script:LogFile = $Path }
    $script:LogEntries.Clear()
    $script:SkuCache = $null
    $script:GroupCache = @{}
}

function Get-OnboardLogEntry {
    <#
    .SYNOPSIS
        Returns log entries recorded in this session.
    #>
    [CmdletBinding()]
    param()
    $script:LogEntries.ToArray()
}

function Get-OnboardStepStatus { if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' } }
#endregion

#region Input
function Import-OnboardRoleTemplate {
    <#
    .SYNOPSIS
        Loads and validates the role template JSON (Defaults + Roles).
    .PARAMETER Path
        Path to the JSON file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Path)
    try { $t = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw "Role template '$Path' is not valid JSON: $($_.Exception.Message)" }

    foreach ($k in 'Defaults', 'Roles') { if (-not $t.Contains($k)) { throw "Role template is missing '$k'" } }
    if (-not $t.Defaults.Contains('Domain') -or -not $t.Defaults.Domain) { throw 'Defaults.Domain is required' }
    if (-not $t.Defaults.Contains('UsageLocation')) { $t.Defaults.UsageLocation = $null }
    if ($t.Defaults.UsageLocation -and $t.Defaults.UsageLocation -notmatch '^[A-Z]{2}$') { throw 'Defaults.UsageLocation must be a 2-letter ISO country code' }
    if (-not $t.Defaults.Contains('PasswordLength')) { $t.Defaults.PasswordLength = 16 }
    if ($t.Defaults.PasswordLength -lt 12) { throw 'Defaults.PasswordLength must be at least 12' }
    if (-not $t.Defaults.Contains('ForceChangePasswordNextSignIn')) { $t.Defaults.ForceChangePasswordNextSignIn = $true }
    foreach ($name in @($t.Roles.Keys)) {
        $r = $t.Roles[$name]
        foreach ($k in 'Licenses', 'Groups', 'SharedMailboxes') {
            if (-not $r.Contains($k)) { $r[$k] = @() }
            $r[$k] = @($r[$k])
        }
    }
    $t
}

function Import-OnboardNewHire {
    <#
    .SYNOPSIS
        Reads new hires from CSV or JSON and validates each record against the role templates.
    .PARAMETER Path
        Path to a CSV or JSON file. Required columns: FirstName, LastName, Role. Optional: ManagerUpn,
        StartDate, JobTitle, Department, UsageLocation, DisplayName, UserPrincipalName.
    .PARAMETER Template
        Hashtable from Import-OnboardRoleTemplate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Template
    )
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $rows = switch ($ext) {
        '.csv'  { @(Import-Csv -LiteralPath $Path) }
        '.json' { @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
        default { throw "Unsupported input type '$ext' (use .csv or .json)" }
    }
    $line = 0
    foreach ($r in $rows) {
        $line++
        $get = { param($n) if ($r.PSObject.Properties[$n] -and "$($r.$n)".Trim()) { "$($r.$n)".Trim() } else { $null } }
        foreach ($req in 'FirstName', 'LastName', 'Role') {
            if (-not (& $get $req)) { throw "Record $line is missing required field '$req'" }
        }
        $role = & $get 'Role'
        if (-not $Template.Roles.Contains($role)) { throw "Record $line uses unknown role '$role'. Known roles: $($Template.Roles.Keys -join ', ')" }
        $mgr = & $get 'ManagerUpn'
        if ($mgr -and $mgr -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "Record $line has an invalid ManagerUpn '$mgr'" }
        $start = & $get 'StartDate'
        if ($start) { try { $start = ([datetime]$start).ToString('yyyy-MM-dd') } catch { throw "Record $line has an invalid StartDate '$start'" } }
        [pscustomobject]@{
            FirstName         = & $get 'FirstName'
            LastName          = & $get 'LastName'
            DisplayName       = & $get 'DisplayName'
            UserPrincipalName = & $get 'UserPrincipalName'
            Role              = $role
            ManagerUpn        = $mgr
            StartDate         = $start
            JobTitle          = & $get 'JobTitle'
            Department        = & $get 'Department'
            UsageLocation     = & $get 'UsageLocation'
        }
    }
}
#endregion

#region Helpers
function ConvertTo-OnboardMailNickname {
    <#
    .SYNOPSIS
        Builds a safe mail nickname: lower-case, diacritics stripped, only a-z 0-9 . -
    .PARAMETER FirstName
        Given name.
    .PARAMETER LastName
        Surname.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FirstName, [Parameter(Mandatory)][string]$LastName)
    $raw = "$FirstName.$LastName".Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($c in $raw.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    $nick = ($sb.ToString().ToLowerInvariant() -replace '[^a-z0-9.\-]', '' -replace '\.{2,}', '.').Trim('.')
    if (-not $nick) { throw "Cannot build a nickname from '$FirstName $LastName'" }
    $nick
}

function Get-OnboardAvailableUpn {
    <#
    .SYNOPSIS
        Returns first.last@domain, or first.last2@domain etc. if the UPN is already taken.
    .PARAMETER MailNickname
        Base nickname.
    .PARAMETER Domain
        UPN suffix.
    .PARAMETER MaxAttempts
        Give up after this many collisions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MailNickname, [Parameter(Mandatory)][string]$Domain, [ValidateRange(1, 50)][int]$MaxAttempts = 20)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $suffix = if ($i -eq 1) { '' } else { "$i" }
        $upn = "$MailNickname$suffix@$Domain"
        try {
            Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/users/$([uri]::EscapeDataString($upn))?`$select=id" -OutputType PSObject -ErrorAction Stop | Out-Null
        }
        catch {
            if ("$($_.Exception.Message)" -match 'does not exist|NotFound|404') { return $upn }
            throw
        }
    }
    throw "No free UPN found for $MailNickname@$Domain after $MaxAttempts attempts"
}

function New-OnboardPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random password with upper, lower, digit and symbol.
    .PARAMETER Length
        Password length (12-128).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([ValidateRange(12, 128)][int]$Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*?-_=+')
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    # Fisher-Yates shuffle so the guaranteed characters are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    if ($PSCmdlet.ShouldProcess('password', 'Generate') -or $WhatIfPreference) { -join $chars }
}

function Resolve-OnboardSku {
    <#
    .SYNOPSIS
        Maps a SKU part number (e.g. SPE_E3) to its skuId and remaining seats, using /subscribedSkus.
    .PARAMETER SkuPartNumber
        SKU part number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SkuPartNumber)
    if (-not $script:SkuCache) {
        $script:SkuCache = @((Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/subscribedSkus?`$select=skuId,skuPartNumber,prepaidUnits,consumedUnits" -OutputType PSObject -ErrorAction Stop).value)
    }
    $sku = $script:SkuCache | Where-Object skuPartNumber -eq $SkuPartNumber | Select-Object -First 1
    if (-not $sku) { throw "SKU '$SkuPartNumber' is not subscribed in this tenant" }
    [pscustomobject]@{ SkuPartNumber = $SkuPartNumber; SkuId = $sku.skuId; Available = [int]$sku.prepaidUnits.enabled - [int]$sku.consumedUnits }
}

function Resolve-OnboardGroup {
    <#
    .SYNOPSIS
        Resolves a group by object ID or exact display name.
    .PARAMETER Group
        GUID or display name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Group)
    if ($script:GroupCache.ContainsKey($Group)) { return $script:GroupCache[$Group] }
    if ($Group -match '^[0-9a-fA-F-]{36}$') {
        $g = Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/groups/$Group`?`$select=id,displayName,groupTypes,mailEnabled" -OutputType PSObject -ErrorAction Stop
    }
    else {
        $filter = [uri]::EscapeDataString("displayName eq '$($Group.Replace("'", "''"))'")
        $found = @((Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/groups?`$filter=$filter&`$select=id,displayName,groupTypes,mailEnabled" -OutputType PSObject -ErrorAction Stop).value)
        if ($found.Count -eq 0) { throw "Group '$Group' not found" }
        if ($found.Count -gt 1) { throw "Group name '$Group' is ambiguous ($($found.Count) matches); use the object ID" }
        $g = $found[0]
    }
    $script:GroupCache[$Group] = $g
    $g
}
#endregion

#region Steps
function New-OnboardAccount {
    <#
    .SYNOPSIS
        Creates the Entra ID user.
    .PARAMETER Body
        Hashtable for POST /users (includes passwordProfile).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][hashtable]$Body)
    $upn = $Body.userPrincipalName
    if ($PSCmdlet.ShouldProcess($upn, 'Create user')) {
        $u = Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/users" -Body ($Body | ConvertTo-Json -Depth 5) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
        Write-OnboardLog -User $upn -Action CreateUser -Target $u.id -Status Success -Details "$($Body.displayName); $($Body.department)"
        return $u
    }
    Write-OnboardLog -User $upn -Action CreateUser -Target $upn -Status (Get-OnboardStepStatus) -Details $Body.displayName
    [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000000'; userPrincipalName = $upn; WhatIf = $true }
}

function Set-OnboardManager {
    <#
    .SYNOPSIS
        Sets the user's manager.
    .PARAMETER User
        Created user object.
    .PARAMETER ManagerUpn
        Manager UPN.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User, [Parameter(Mandatory)][string]$ManagerUpn)
    $upn = $User.userPrincipalName
    $mgr = Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/users/$([uri]::EscapeDataString($ManagerUpn))?`$select=id,displayName" -OutputType PSObject -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess($upn, "Set manager $ManagerUpn")) {
        $body = @{ '@odata.id' = "$script:Graph/users/$($mgr.id)" } | ConvertTo-Json
        Invoke-MgGraphRequest -Method PUT -Uri "$script:Graph/users/$($User.id)/manager/`$ref" -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-OnboardLog -User $upn -Action SetManager -Target $ManagerUpn -Status Success
    }
    else { Write-OnboardLog -User $upn -Action SetManager -Target $ManagerUpn -Status (Get-OnboardStepStatus) }
    $mgr
}

function Add-OnboardLicense {
    <#
    .SYNOPSIS
        Assigns licences by SKU part number, checking seat availability first.
    .PARAMETER User
        Created user object.
    .PARAMETER SkuPartNumber
        SKU part numbers from the role template.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User, [string[]]$SkuPartNumber = @())
    $upn = $User.userPrincipalName
    foreach ($part in $SkuPartNumber) {
        try {
            $sku = Resolve-OnboardSku -SkuPartNumber $part
            if ($sku.Available -lt 1) { throw "No free seats for $part (buy more or free one up)" }
            if ($PSCmdlet.ShouldProcess($upn, "Assign licence $part")) {
                $body = @{ addLicenses = @(@{ skuId = $sku.SkuId; disabledPlans = @() }); removeLicenses = @() } | ConvertTo-Json -Depth 4
                Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/users/$($User.id)/assignLicense" -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                $cached = $script:SkuCache | Where-Object skuPartNumber -eq $part | Select-Object -First 1
                $cached.consumedUnits = [int]$cached.consumedUnits + 1
                Write-OnboardLog -User $upn -Action AssignLicense -Target $part -Status Success -Details "$($sku.Available - 1) seat(s) left"
            }
            else { Write-OnboardLog -User $upn -Action AssignLicense -Target $part -Status (Get-OnboardStepStatus) -Details "$($sku.Available) seat(s) available" }
        }
        catch { Write-OnboardLog -User $upn -Action AssignLicense -Target $part -Status Failed -Details $_.Exception.Message }
    }
}

function Add-OnboardGroupMembership {
    <#
    .SYNOPSIS
        Adds the user to groups. Distribution lists / mail-enabled security groups go through Exchange Online.
    .PARAMETER User
        Created user object.
    .PARAMETER Group
        Group IDs or display names.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][object]$User, [string[]]$Group = @())
    $upn = $User.userPrincipalName
    foreach ($name in $Group) {
        try {
            $g = Resolve-OnboardGroup -Group $name
            $viaExchange = $g.mailEnabled -and (@($g.groupTypes) -notcontains 'Unified')
            if ($PSCmdlet.ShouldProcess($g.displayName, "Add $upn")) {
                if ($viaExchange) {
                    Add-DistributionGroupMember -Identity $g.id -Member $upn -BypassSecurityGroupManagerCheck -ErrorAction Stop
                }
                else {
                    $body = @{ '@odata.id' = "$script:Graph/directoryObjects/$($User.id)" } | ConvertTo-Json
                    Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/groups/$($g.id)/members/`$ref" -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                }
                Write-OnboardLog -User $upn -Action AddGroup -Target $g.displayName -Status Success -Details $(if ($viaExchange) { 'Exchange' } else { 'Graph' })
            }
            else { Write-OnboardLog -User $upn -Action AddGroup -Target $g.displayName -Status (Get-OnboardStepStatus) }
        }
        catch { Write-OnboardLog -User $upn -Action AddGroup -Target $name -Status Failed -Details $_.Exception.Message }
    }
}

function Wait-OnboardMailbox {
    <#
    .SYNOPSIS
        Waits for Exchange Online to provision the mailbox after licensing.
    .PARAMETER UserPrincipalName
        UPN.
    .PARAMETER TimeoutSeconds
        Give up after this long.
    .PARAMETER PollSeconds
        Poll interval.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$UserPrincipalName, [ValidateRange(0, 3600)][int]$TimeoutSeconds = 600, [ValidateRange(1, 300)][int]$PollSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Get-EXOMailbox -Identity $UserPrincipalName -ErrorAction SilentlyContinue) { return $true }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    $false
}

function Set-OnboardMailbox {
    <#
    .SYNOPSIS
        Sets mailbox language/time zone and grants access to the role's shared mailboxes.
    .PARAMETER User
        Created user object.
    .PARAMETER TimeZone
        Windows time zone name, e.g. 'Pacific Standard Time'.
    .PARAMETER Language
        Culture, e.g. en-US.
    .PARAMETER SharedMailbox
        Shared mailboxes to grant FullAccess + SendAs on.
    .PARAMETER TimeoutSeconds
        How long to wait for mailbox provisioning.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object]$User,
        [string]$TimeZone,
        [string]$Language,
        [string[]]$SharedMailbox = @(),
        [int]$TimeoutSeconds = 600
    )
    $upn = $User.userPrincipalName
    if (-not $WhatIfPreference) {
        if (-not (Wait-OnboardMailbox -UserPrincipalName $upn -TimeoutSeconds $TimeoutSeconds)) {
            Write-OnboardLog -User $upn -Action MailboxSetup -Status Failed -Details "Mailbox not provisioned within ${TimeoutSeconds}s; re-run with -Step MailboxSetup later"
            return
        }
    }
    if ($TimeZone -or $Language) {
        if ($PSCmdlet.ShouldProcess($upn, "Set mailbox regional settings ($Language, $TimeZone)")) {
            $p = @{ Identity = $upn; ErrorAction = 'Stop' }
            if ($TimeZone) { $p.TimeZone = $TimeZone }
            if ($Language) { $p.Language = $Language; $p.LocalizeDefaultFolderName = $true }
            Set-MailboxRegionalConfiguration @p
            Write-OnboardLog -User $upn -Action MailboxRegional -Target $upn -Status Success -Details "$Language; $TimeZone"
        }
        else { Write-OnboardLog -User $upn -Action MailboxRegional -Target $upn -Status (Get-OnboardStepStatus) -Details "$Language; $TimeZone" }
    }
    foreach ($mbx in $SharedMailbox) {
        try {
            if ($PSCmdlet.ShouldProcess($mbx, "Grant FullAccess + SendAs to $upn")) {
                Add-MailboxPermission -Identity $mbx -User $upn -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null
                Add-RecipientPermission -Identity $mbx -Trustee $upn -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
                Write-OnboardLog -User $upn -Action SharedMailboxAccess -Target $mbx -Status Success -Details 'FullAccess, SendAs'
            }
            else { Write-OnboardLog -User $upn -Action SharedMailboxAccess -Target $mbx -Status (Get-OnboardStepStatus) }
        }
        catch { Write-OnboardLog -User $upn -Action SharedMailboxAccess -Target $mbx -Status Failed -Details $_.Exception.Message }
    }
}

function New-OnboardWelcomeSheet {
    <#
    .SYNOPSIS
        Writes a welcome sheet (HTML) for the manager/new hire. Contains NO password.
    .PARAMETER Hire
        New-hire record.
    .PARAMETER UserPrincipalName
        Final UPN.
    .PARAMETER Role
        Role template hashtable.
    .PARAMETER Defaults
        Template defaults.
    .PARAMETER ManagerName
        Manager display name.
    .PARAMETER OutputPath
        Folder for welcome sheets.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Hire,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Role,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults,
        [string]$ManagerName,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $e = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $company = if ($Defaults.Contains('CompanyName')) { $Defaults.CompanyName } else { '' }
    $name = if ($Hire.DisplayName) { $Hire.DisplayName } else { "$($Hire.FirstName) $($Hire.LastName)" }
    $groups = ($Role.Groups | ForEach-Object { "<li>$(& $e $_)</li>" }) -join ''
    $shared = ($Role.SharedMailboxes | ForEach-Object { "<li>$(& $e $_)</li>" }) -join ''
    if (-not $shared) { $shared = '<li>None</li>' }
    $html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Welcome $(& $e $name)</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:720px;margin:32px auto;color:#1f2933}h1{color:#0b3d91}
table{border-collapse:collapse}td{padding:4px 12px 4px 0}.note{background:#fff4e0;padding:10px 14px;border-radius:6px}</style></head><body>
<h1>Welcome to $(& $e $company), $(& $e $Hire.FirstName)!</h1>
<table>
<tr><td><b>Sign-in / email</b></td><td>$(& $e $UserPrincipalName)</td></tr>
<tr><td><b>Start date</b></td><td>$(& $e $Hire.StartDate)</td></tr>
<tr><td><b>Role</b></td><td>$(& $e $Hire.Role)</td></tr>
<tr><td><b>Manager</b></td><td>$(& $e $ManagerName)</td></tr>
</table>
<h3>Your first day</h3>
<ol><li>Go to <b>https://www.office.com</b> and sign in with the address above.</li>
<li>Use the temporary password your manager gives you. You will be asked to choose a new one.</li>
<li>Set up the <b>Microsoft Authenticator</b> app when prompted (multi-factor authentication).</li>
<li>Open Outlook and Teams. Shared mailboxes below appear in Outlook automatically.</li></ol>
<h3>Access set up for you</h3><p>Groups / teams:</p><ul>$groups</ul><p>Shared mailboxes:</p><ul>$shared</ul>
<p class="note">For security this sheet does not contain your password. Never share your password with anyone, including IT.</p>
</body></html>
"@
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false -Confirm:$false | Out-Null }
    $file = Join-Path $OutputPath ("Welcome_{0}.html" -f ($UserPrincipalName -replace '[^a-zA-Z0-9.@-]', '_'))
    # The welcome sheet holds no secrets, so it is also produced in -WhatIf mode as a preview.
    Set-Content -LiteralPath $file -Value $html -Encoding utf8 -WhatIf:$false -Confirm:$false
    Write-OnboardLog -User $UserPrincipalName -Action WelcomeSheet -Target $file -Status $(if ($WhatIfPreference) { 'WhatIf' } else { 'Success' }) -Details 'Preview written'
    $file
}
#endregion

#region Orchestrator
function Invoke-EntraUserOnboarding {
    <#
    .SYNOPSIS
        Onboards one new hire: account, manager, licences, groups, mailbox, welcome sheet.
    .PARAMETER Hire
        Record from Import-OnboardNewHire.
    .PARAMETER Template
        Hashtable from Import-OnboardRoleTemplate.
    .PARAMETER OutputPath
        Folder for welcome sheets.
    .PARAMETER SkipMailbox
        Skip mailbox setup (e.g. when Exchange Online is not connected).
    .PARAMETER MailboxTimeoutSeconds
        How long to wait for mailbox provisioning.
    .OUTPUTS
        PSCustomObject with User, Succeeded, TemporaryPassword (SecureString), WelcomeSheet, Actions.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object]$Hire,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Template,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$SkipMailbox,
        [ValidateRange(0, 3600)][int]$MailboxTimeoutSeconds = 600
    )
    $d = $Template.Defaults
    $role = $Template.Roles[$Hire.Role]
    $label = "$($Hire.FirstName) $($Hire.LastName)"
    $mark = $script:LogEntries.Count

    try {
        $nick = ConvertTo-OnboardMailNickname -FirstName $Hire.FirstName -LastName $Hire.LastName
        $upn = if ($Hire.UserPrincipalName) { $Hire.UserPrincipalName } else { Get-OnboardAvailableUpn -MailNickname $nick -Domain $d.Domain }
        $nick = ($upn -split '@')[0]
    }
    catch {
        Write-OnboardLog -User $label -Action ResolveUpn -Status Failed -Details $_.Exception.Message
        return [pscustomobject]@{ User = $label; Succeeded = $false; Failed = 1; TemporaryPassword = $null; WelcomeSheet = $null; Actions = @($script:LogEntries.ToArray() | Select-Object -Skip $mark) }
    }
    Write-OnboardLog -User $upn -Action Start -Status Info -Details "Role=$($Hire.Role) $(if ($WhatIfPreference) { '(WhatIf)' })"

    $password = New-OnboardPassword -Length $d.PasswordLength -WhatIf:$false
    $body = @{
        accountEnabled    = $true
        displayName       = if ($Hire.DisplayName) { $Hire.DisplayName } else { $label }
        givenName         = $Hire.FirstName
        surname           = $Hire.LastName
        mailNickname      = $nick
        userPrincipalName = $upn
        usageLocation     = if ($Hire.UsageLocation) { $Hire.UsageLocation } else { $d.UsageLocation }
        department        = if ($Hire.Department) { $Hire.Department } elseif ($role.Contains('Department')) { $role.Department } else { $null }
        jobTitle          = if ($Hire.JobTitle) { $Hire.JobTitle } elseif ($role.Contains('JobTitle')) { $role.JobTitle } else { $null }
        companyName       = if ($d.Contains('CompanyName')) { $d.CompanyName } else { $null }
        passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = [bool]$d.ForceChangePasswordNextSignIn }
    }
    if ($Hire.StartDate) { $body.employeeHireDate = "$($Hire.StartDate)T00:00:00Z" }
    foreach ($k in @($body.Keys)) { if ($null -eq $body[$k]) { $body.Remove($k) } }

    try { $user = New-OnboardAccount -Body $body }
    catch {
        Write-OnboardLog -User $upn -Action CreateUser -Status Failed -Details $_.Exception.Message
        return [pscustomobject]@{ User = $upn; Succeeded = $false; Failed = 1; TemporaryPassword = $null; WelcomeSheet = $null; Actions = @($script:LogEntries.ToArray() | Select-Object -Skip $mark) }
    }
    finally { $body.passwordProfile.password = $null }

    $managerName = ''
    if ($Hire.ManagerUpn) {
        try { $managerName = (Set-OnboardManager -User $user -ManagerUpn $Hire.ManagerUpn).displayName }
        catch { Write-OnboardLog -User $upn -Action SetManager -Target $Hire.ManagerUpn -Status Failed -Details $_.Exception.Message }
    }
    Add-OnboardLicense -User $user -SkuPartNumber $role.Licenses
    Add-OnboardGroupMembership -User $user -Group $role.Groups
    if ($SkipMailbox) { Write-OnboardLog -User $upn -Action MailboxSetup -Status Skipped -Details '-SkipMailbox' }
    else {
        try {
            $tz = if ($d.Contains('MailboxTimeZone')) { $d.MailboxTimeZone } else { $null }
            $lang = if ($d.Contains('MailboxLanguage')) { $d.MailboxLanguage } else { $null }
            Set-OnboardMailbox -User $user -TimeZone $tz -Language $lang -SharedMailbox $role.SharedMailboxes -TimeoutSeconds $MailboxTimeoutSeconds
        }
        catch { Write-OnboardLog -User $upn -Action MailboxSetup -Status Failed -Details $_.Exception.Message }
    }
    $sheet = $null
    try { $sheet = New-OnboardWelcomeSheet -Hire $Hire -UserPrincipalName $upn -Role $role -Defaults $d -ManagerName $managerName -OutputPath $OutputPath }
    catch { Write-OnboardLog -User $upn -Action WelcomeSheet -Status Failed -Details $_.Exception.Message }

    $actions = @($script:LogEntries.ToArray() | Select-Object -Skip $mark)
    $failed = @($actions | Where-Object Status -eq 'Failed').Count
    $secure = $null
    if (-not $WhatIfPreference) {
        $secure = [securestring]::new()
        foreach ($c in $password.ToCharArray()) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
    }
    $password = $null
    [pscustomobject]@{
        User              = $upn
        Succeeded         = ($failed -eq 0)
        Failed            = $failed
        TemporaryPassword = $secure
        WelcomeSheet      = $sheet
        Actions           = $actions
    }
}
#endregion

Export-ModuleMember -Function Write-OnboardLog, Set-OnboardLogFile, Get-OnboardLogEntry, Import-OnboardRoleTemplate, Import-OnboardNewHire,
    ConvertTo-OnboardMailNickname, Get-OnboardAvailableUpn, New-OnboardPassword, Resolve-OnboardSku, Resolve-OnboardGroup,
    New-OnboardAccount, Set-OnboardManager, Add-OnboardLicense, Add-OnboardGroupMembership, Wait-OnboardMailbox,
    Set-OnboardMailbox, New-OnboardWelcomeSheet, Invoke-EntraUserOnboarding
