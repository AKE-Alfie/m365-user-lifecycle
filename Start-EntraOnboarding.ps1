#Requires -Version 7.0

<#
.SYNOPSIS
    Onboards new hires into Microsoft 365 from a CSV or JSON file using role templates.

.DESCRIPTION
    For each new hire:
      1. Builds a unique UPN (first.last@domain, first.last2@... on collision, diacritics removed)
      2. Creates the Entra ID account with a random temporary password (change at first sign-in)
      3. Sets the manager
      4. Assigns licences from the role template (checks free seats first)
      5. Adds groups / Teams / distribution lists from the role template
      6. Waits for the mailbox, sets language + time zone, grants shared-mailbox access
      7. Writes a welcome sheet (HTML, no password) for the manager to hand over

    Use -WhatIf first. Every action is logged to CSV. Temporary passwords are returned
    only as SecureString in the output object and never written to disk or logs.

.PARAMETER InputPath
    CSV or JSON of new hires (FirstName, LastName, Role required).
.PARAMETER TemplatePath
    Role template JSON. Default: ./config/role-templates.json
.PARAMETER TenantId
    Tenant ID or domain (for connecting).
.PARAMETER ClientId
    App registration ID for app-only (certificate) auth.
.PARAMETER CertificateThumbprint
    Certificate thumbprint for app-only auth.
.PARAMETER OutputPath
    Folder for the CSV log and welcome sheets. Default: ./output
.PARAMETER SkipMailbox
    Skip mailbox configuration.
.PARAMETER MailboxTimeoutSeconds
    How long to wait for each mailbox to provision. Default 600.
.PARAMETER SkipConnect
    Reuse existing Graph / Exchange Online sessions.

.EXAMPLE
    ./Start-EntraOnboarding.ps1 -InputPath ./new-hires.csv -TemplatePath ./config/role-templates.json -WhatIf

.EXAMPLE
    $r = ./Start-EntraOnboarding.ps1 -InputPath ./new-hires.csv -TenantId contoso.onmicrosoft.com
    $r | ForEach-Object { "$($_.User): $($_.TemporaryPassword | ConvertFrom-SecureString -AsPlainText)" }

    Live run, then reveal the temporary passwords on screen to hand over securely.

.NOTES
    Author : Miguel
    License: MIT
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Delegated')]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InputPath,
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TemplatePath = (Join-Path $PSScriptRoot 'config/role-templates.json'),
    [string]$TenantId,
    [Parameter(Mandatory, ParameterSetName = 'App')][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ClientId,
    [Parameter(Mandatory, ParameterSetName = 'App')][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertificateThumbprint,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'output'),
    [switch]$SkipMailbox,
    [ValidateRange(0, 3600)][int]$MailboxTimeoutSeconds = 600,
    [switch]$SkipConnect
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/EntraOnboarding.psm1') -Force

$template = Import-OnboardRoleTemplate -Path $TemplatePath
$hires = @(Import-OnboardNewHire -Path $InputPath -Template $template)
$logPath = Join-Path $OutputPath ('Onboarding_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Set-OnboardLogFile -Path $logPath -WhatIf:$false

if (-not $SkipConnect) {
    if (-not $TenantId) { throw '-TenantId is required unless -SkipConnect is used.' }
    $graph = @{ TenantId = $TenantId; NoWelcome = $true }
    if ($PSCmdlet.ParameterSetName -eq 'App') { $graph.ClientId = $ClientId; $graph.CertificateThumbprint = $CertificateThumbprint }
    else { $graph.Scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'LicenseAssignment.ReadWrite.All', 'Organization.Read.All') }
    Connect-MgGraph @graph | Out-Null
    if (-not $SkipMailbox) {
        $exo = @{ ShowBanner = $false }
        if ($PSCmdlet.ParameterSetName -eq 'App') { $exo.AppId = $ClientId; $exo.CertificateThumbprint = $CertificateThumbprint; $exo.Organization = $TenantId }
        Connect-ExchangeOnline @exo
    }
}

foreach ($h in $hires) {
    $p = @{
        Hire = $h; Template = $template; OutputPath = $OutputPath; SkipMailbox = $SkipMailbox
        MailboxTimeoutSeconds = $MailboxTimeoutSeconds; WhatIf = $WhatIfPreference; Confirm = ($ConfirmPreference -eq 'Low')
    }
    $r = Invoke-EntraUserOnboarding @p
    $r | Add-Member -NotePropertyName LogPath -NotePropertyValue $logPath -PassThru |
        Select-Object User, Succeeded, Failed, TemporaryPassword, WelcomeSheet, LogPath, Actions
}
