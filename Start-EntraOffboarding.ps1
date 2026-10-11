#Requires -Version 7.0
<#
.SYNOPSIS
    Offboards one or more employees in Entra ID / Microsoft 365 with a full CSV audit trail.

.DESCRIPTION
    Runs these steps in a safe order (each can be switched off in the JSON config):

      1. DisableAccount          Block sign-in (accountEnabled = false)
      2. RevokeSessions          Revoke refresh tokens / sign-in sessions
      3. SetAutoReply            Out-of-office message pointing to the manager
      4. ConvertToSharedMailbox  Keep the mailbox without a licence
      5. GrantManagerAccess      FullAccess for the manager (from Entra) or -DelegateUpn
      6. HideFromGAL             Hide from the Global Address List
      7. RemoveGroupMemberships  Direct memberships (skips dynamic, on-prem synced, excluded)
      8. RemoveLicenses          Direct licences only (group-based ones are reported)

    The mailbox is converted and delegated BEFORE licences are removed so no mail is lost.
    A failing step is logged and the remaining steps still run.

    ALWAYS do a dry run first with -WhatIf. In -WhatIf mode, nothing is changed but every
    planned action is still written to the CSV log.

.PARAMETER UserPrincipalName
    One or more UPNs to offboard. Accepts pipeline input (e.g. from Import-Csv).
.PARAMETER ConfigPath
    Path to the JSON config. Defaults to ./config/offboarding.config.json if present, otherwise built-in defaults.
.PARAMETER DelegateUpn
    Give mailbox access to this person instead of the user's Entra manager.
.PARAMETER TenantId
    Overrides TenantId from the config.
.PARAMETER ClientId
    App registration ID for app-only (certificate) auth.
.PARAMETER CertificateThumbprint
    Certificate thumbprint for app-only auth.
.PARAMETER LogPath
    CSV audit log path. Default: <LogFolder>/Offboarding_<timestamp>.csv
.PARAMETER SkipConnect
    Reuse existing Connect-MgGraph / Connect-ExchangeOnline sessions.

.EXAMPLE
    ./Start-EntraOffboarding.ps1 -UserPrincipalName jdoe@contoso.com -WhatIf

    Dry run: shows and logs every action without changing anything.

.EXAMPLE
    ./Start-EntraOffboarding.ps1 -UserPrincipalName jdoe@contoso.com -DelegateUpn teamlead@contoso.com -ConfigPath ./config/contoso.json

.EXAMPLE
    Import-Csv ./leavers.csv | Select-Object -ExpandProperty UserPrincipalName | ./Start-EntraOffboarding.ps1 -Confirm

    Bulk offboarding with a confirmation prompt for every change.

.NOTES
    Author : Miguel
    License: MIT
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Delegated')]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string[]]$UserPrincipalName,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$DelegateUpn,

    [string]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'App')][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ClientId,
    [Parameter(Mandatory, ParameterSetName = 'App')][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertificateThumbprint,

    [string]$LogPath,

    [switch]$SkipConnect
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path $PSScriptRoot 'src/EntraOffboarding.psm1') -Force

    if (-not $ConfigPath) {
        $default = Join-Path $PSScriptRoot 'config/offboarding.config.json'
        if (Test-Path -LiteralPath $default) { $ConfigPath = $default }
    }
    $config = Import-OffboardConfig -Path $ConfigPath
    if ($TenantId) { $config.TenantId = $TenantId }

    if (-not $LogPath) {
        $folder = $config.LogFolder
        if (-not [System.IO.Path]::IsPathRooted($folder)) { $folder = Join-Path $PSScriptRoot $folder }
        $LogPath = Join-Path $folder ('Offboarding_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    Set-OffboardLogFile -Path $LogPath -WhatIf:$false

    if (-not $SkipConnect) {
        if (-not $config.TenantId) { throw 'TenantId is required (config file or -TenantId).' }
        $needsExchange = $config.Steps.SetAutoReply -or $config.Steps.ConvertToSharedMailbox -or
                         $config.Steps.GrantManagerAccess -or $config.Steps.HideFromGAL -or $config.Steps.RemoveGroupMemberships
        $connect = @{ TenantId = $config.TenantId; SkipExchange = (-not $needsExchange) }
        if ($PSCmdlet.ParameterSetName -eq 'App') { $connect.ClientId = $ClientId; $connect.CertificateThumbprint = $CertificateThumbprint }
        Connect-OffboardService @connect
    }
    $results = [System.Collections.Generic.List[object]]::new()
}

process {
    foreach ($upn in $UserPrincipalName) {
        $p = @{ UserPrincipalName = $upn; Config = $config; WhatIf = $WhatIfPreference; Confirm = ($ConfirmPreference -eq 'Low') }
        if ($DelegateUpn) { $p.DelegateUpn = $DelegateUpn }
        $r = Invoke-EntraUserOffboarding @p
        $results.Add($r)
        $r.Actions | Select-Object Timestamp, Action, Target, Status, Details | Format-Table -AutoSize | Out-String | Write-Verbose
    }
}

end {
    foreach ($r in $results) {
        [pscustomobject]@{
            User      = $r.User
            Succeeded = $r.Succeeded
            Failed    = $r.Failed
            Success   = @($r.Actions | Where-Object Status -eq 'Success').Count
            WhatIf    = @($r.Actions | Where-Object Status -eq 'WhatIf').Count
            Skipped   = @($r.Actions | Where-Object Status -eq 'Skipped').Count
            LogPath   = $LogPath
        }
    }
}
