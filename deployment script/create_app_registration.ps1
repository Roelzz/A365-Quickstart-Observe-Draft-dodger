<#
.SYNOPSIS
    Create the custom client App Registration that A365 will use for token exchange.

.DESCRIPTION
    Self-contained, idempotent. Creates (or reuses) an Entra app registration named
    "A365 Draft Dodger Client", adds API permissions for the Microsoft Agents 365
    platform + Microsoft Graph User.Read, creates a service principal, generates a
    client secret, and writes the resulting values into demo-tenant.config.json.

    The Agent 365 service principal audience is hardcoded:
      5a807f24-c9de-44ee-a3a7-329e88a00ffc — Microsoft Agents SDK service connection

    Run this once per tenant. Re-running with -Force overwrites the secret in
    demo-tenant.config.json (a new credential is appended; old ones remain valid).

.PARAMETER AppDisplayName
    Display name for the app registration. Default: "A365 Draft Dodger Client".

.PARAMETER SecretLifetimeYears
    Client secret lifetime in years. Default: 1.

.PARAMETER Force
    Overwrite the existing customClientAppId / clientSecret in demo-tenant.config.json.

.EXAMPLE
    pwsh -File ./create_app_registration.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppDisplayName = "A365 Draft Dodger Client",

    [Parameter(Mandatory = $false)]
    [int]$SecretLifetimeYears = 1,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Resolve project paths
$AgentFolder = (Get-Item "$PSScriptRoot\..").FullName
$tenantConfigPath = Join-Path $AgentFolder "deployment script/demo-tenant.config.json"
$tenantConfigExamplePath = Join-Path $AgentFolder "deployment script/demo-tenant.config.json.example"

# Verify az CLI is signed in
Write-Host "Checking az CLI session..." -ForegroundColor Cyan
$account = az account show --output json | ConvertFrom-Json
if (-not $account) {
    Write-Host "ERROR: az CLI not signed in. Run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "  Signed in as: $($account.user.name)" -ForegroundColor Gray
Write-Host "  Tenant:       $($account.tenantId)" -ForegroundColor Gray
Write-Host "  Subscription: $($account.name) ($($account.id))" -ForegroundColor Gray

# Audience IDs A365 needs (resourceAppId values)
$msGraphAppId       = "00000003-0000-0000-c000-000000000000"   # Microsoft Graph
$userReadScopeId    = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"   # User.Read (delegated)
$a365ResourceAppId  = "5a807f24-c9de-44ee-a3a7-329e88a00ffc"   # Agent 365 service connection scope

# Look for existing app
Write-Host ""
Write-Host "Looking for existing app registration named '$AppDisplayName'..." -ForegroundColor Cyan
$existing = az ad app list --display-name $AppDisplayName --output json | ConvertFrom-Json
if ($existing -and $existing.Length -gt 0) {
    $appId = $existing[0].appId
    $objectId = $existing[0].id
    Write-Host "  Found existing: appId=$appId" -ForegroundColor Yellow
    if (-not $Force) {
        Write-Host "  Reusing it. (Pass -Force to rotate the secret.)" -ForegroundColor Gray
    }
} else {
    Write-Host "Creating new app registration..." -ForegroundColor Cyan
    $created = az ad app create `
        --display-name $AppDisplayName `
        --sign-in-audience AzureADMyOrg `
        --output json | ConvertFrom-Json
    $appId = $created.appId
    $objectId = $created.id
    Write-Host "  Created: appId=$appId" -ForegroundColor Green
}

# Ensure service principal exists
Write-Host ""
Write-Host "Ensuring service principal exists..." -ForegroundColor Cyan
$sp = az ad sp list --filter "appId eq '$appId'" --output json | ConvertFrom-Json
if (-not $sp -or $sp.Length -eq 0) {
    az ad sp create --id $appId --output none
    Write-Host "  Service principal created." -ForegroundColor Green
} else {
    Write-Host "  Service principal already exists." -ForegroundColor Gray
}

# Add API permissions
Write-Host ""
Write-Host "Configuring API permissions..." -ForegroundColor Cyan
Write-Host "  Microsoft Graph: User.Read (delegated)" -ForegroundColor Gray
az ad app permission add `
    --id $appId `
    --api $msGraphAppId `
    --api-permissions "$userReadScopeId=Scope" `
    --output none 2>$null

Write-Host "  Agent 365 service connection: .default" -ForegroundColor Gray
# Find the .default scope ID for the A365 resource
$a365Sp = az ad sp show --id $a365ResourceAppId --output json 2>$null | ConvertFrom-Json
if ($a365Sp) {
    $defaultScope = $a365Sp.oauth2PermissionScopes | Where-Object { $_.value -eq "user_impersonation" -or $_.value -eq ".default" } | Select-Object -First 1
    if ($defaultScope) {
        az ad app permission add `
            --id $appId `
            --api $a365ResourceAppId `
            --api-permissions "$($defaultScope.id)=Scope" `
            --output none 2>$null
        Write-Host "    Added scope: $($defaultScope.value) ($($defaultScope.id))" -ForegroundColor Gray
    } else {
        Write-Host "    WARNING: Could not auto-discover a delegated scope on the A365 resource SP." -ForegroundColor Yellow
        Write-Host "    Manually grant 'user_impersonation' or '.default' on $a365ResourceAppId in the Entra portal." -ForegroundColor Yellow
    }
} else {
    Write-Host "    WARNING: Agent 365 resource SP ($a365ResourceAppId) not found in this tenant." -ForegroundColor Yellow
    Write-Host "    A365 must be provisioned in your tenant first." -ForegroundColor Yellow
}

# Admin consent
Write-Host ""
Write-Host "Granting admin consent (you may be prompted to sign in)..." -ForegroundColor Cyan
try {
    az ad app permission admin-consent --id $appId --output none
    Write-Host "  Admin consent granted." -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Admin consent failed (may need tenant admin role)." -ForegroundColor Yellow
    Write-Host "  Manually grant in Entra portal: App registrations > $AppDisplayName > API permissions > Grant admin consent." -ForegroundColor Yellow
}

# Generate client secret
Write-Host ""
Write-Host "Generating client secret (lifetime: $SecretLifetimeYears year(s))..." -ForegroundColor Cyan
$secretJson = az ad app credential reset `
    --id $appId `
    --append `
    --display-name "draft-dodger-$(Get-Date -Format 'yyyyMMdd')" `
    --years $SecretLifetimeYears `
    --output json | ConvertFrom-Json
$clientSecret = $secretJson.password
Write-Host "  Client secret created. (Shown only once — captured below.)" -ForegroundColor Green

# Update demo-tenant.config.json
Write-Host ""
Write-Host "Writing demo-tenant.config.json..." -ForegroundColor Cyan

if (Test-Path $tenantConfigPath) {
    $cfg = Get-Content $tenantConfigPath -Raw | ConvertFrom-Json
    if ($cfg.customClientAppId -and -not $Force) {
        Write-Host "  customClientAppId already set ($($cfg.customClientAppId)). Pass -Force to overwrite." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "===== APP REGISTRATION VALUES =====" -ForegroundColor Magenta
        Write-Host "appId:        $appId" -ForegroundColor White
        Write-Host "clientSecret: $clientSecret" -ForegroundColor White
        Write-Host "tenantId:     $($account.tenantId)" -ForegroundColor White
        exit 0
    }
} else {
    if (-not (Test-Path $tenantConfigExamplePath)) {
        Write-Host "ERROR: $tenantConfigExamplePath not found. Cannot scaffold demo-tenant.config.json." -ForegroundColor Red
        exit 1
    }
    Copy-Item $tenantConfigExamplePath $tenantConfigPath
    $cfg = Get-Content $tenantConfigPath -Raw | ConvertFrom-Json
}

$cfg.tenantId = $account.tenantId
$cfg.tenantName = ($account.user.name -split '@')[1]
$cfg.adminUserPrincipalName = $account.user.name
$cfg.subscriptionId = $account.id
$cfg.subscriptionName = $account.name
$cfg.customClientAppId = $appId
$cfg | ConvertTo-Json -Depth 8 | Set-Content $tenantConfigPath -Encoding UTF8

Write-Host "  Wrote $tenantConfigPath" -ForegroundColor Green
Write-Host ""
Write-Host "===== APP REGISTRATION VALUES =====" -ForegroundColor Magenta
Write-Host "appId:        $appId" -ForegroundColor White
Write-Host "clientSecret: $clientSecret" -ForegroundColor White
Write-Host "tenantId:     $($account.tenantId)" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Add the client secret to .env:" -ForegroundColor Gray
Write-Host "       CLIENT_SECRET=$clientSecret" -ForegroundColor Gray
Write-Host "       CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$clientSecret" -ForegroundColor Gray
Write-Host "  2. Continue with Phase 2A step 4 (initialize_a365_config.ps1)" -ForegroundColor Gray
