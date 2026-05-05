<#
.SYNOPSIS
    Initialize a365.config.json for Agent 365 CLI. Self-contained, no external dependencies.

.DESCRIPTION
    Creates a365.config.json in the agent folder using values from demo-tenant.config.json
    and deployment.json. For use with pre-deployed Container Apps (needDeployment=false).

.PARAMETER AgentName
    Lowercase agent name (no spaces). Default: derived from folder name.

.PARAMETER AgentDisplayName
    Friendly display name. Default: derived from AgentName.

.PARAMETER Location
    Azure region. Default: westeurope (a365 CLI location, not Container Apps location).

.PARAMETER Force
    Overwrite existing a365.config.json.

.EXAMPLE
    ./scripts/initialize_a365_config.ps1 -AgentName "myagent" -AgentDisplayName "My Agent"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AgentName,

    [Parameter(Mandatory = $false)]
    [string]$AgentDisplayName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "westeurope",

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Resolve paths
$AgentFolder = (Get-Item "$PSScriptRoot\..").FullName
$configPath = Join-Path $AgentFolder "a365.config.json"
$demoConfigPath = Join-Path $AgentFolder "demo-tenant.config.json"
$deploymentPath = Join-Path $AgentFolder "deployment.json"

# Check existing config
if ((Test-Path $configPath) -and -not $Force) {
    Write-Host "ERROR: a365.config.json already exists. Use -Force to overwrite." -ForegroundColor Red
    exit 1
}

# Load demo tenant config
if (-not (Test-Path $demoConfigPath)) {
    Write-Host "ERROR: demo-tenant.config.json not found." -ForegroundColor Red
    Write-Host "  Copy demo-tenant.config.json.example and fill in values." -ForegroundColor Yellow
    exit 1
}
$demoConfig = Get-Content $demoConfigPath -Raw | ConvertFrom-Json

# Validate required fields
if (-not $demoConfig.tenantId) { Write-Host "ERROR: tenantId missing from demo-tenant.config.json" -ForegroundColor Red; exit 1 }
if (-not $demoConfig.subscriptionId) { Write-Host "ERROR: subscriptionId missing" -ForegroundColor Red; exit 1 }
if (-not $demoConfig.customClientAppId) { Write-Host "ERROR: customClientAppId missing" -ForegroundColor Red; exit 1 }

# Defaults
if (-not $AgentName) {
    $AgentName = (Split-Path $AgentFolder -Leaf).ToLower() -replace '[^a-z0-9]', ''
}
if (-not $AgentDisplayName) {
    $AgentDisplayName = "$AgentName Agent"
    # Basic prettification
    $AgentDisplayName = $AgentDisplayName -replace 'a365', 'A365 '
    $AgentDisplayName = $AgentDisplayName -replace 'python', 'Python '
    $AgentDisplayName = $AgentDisplayName -replace 'demo', 'Demo '
    $AgentDisplayName = ($AgentDisplayName -replace '\s+', ' ').Trim()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  A365 Configuration Initialization" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Tenant ID: $($demoConfig.tenantId)" -ForegroundColor Green
Write-Host "  Subscription: $($demoConfig.subscriptionId)" -ForegroundColor Green
Write-Host "  Client App ID: $($demoConfig.customClientAppId)" -ForegroundColor Green

# Load deployment info for endpoint
$messagingEndpoint = ""
$resourceGroup = "rg-agent365-$AgentName-$Location"
if (Test-Path $deploymentPath) {
    $deployment = Get-Content $deploymentPath -Raw | ConvertFrom-Json
    if ($deployment.endpoint) {
        $messagingEndpoint = $deployment.endpoint
        Write-Host "  Endpoint (from deployment.json): $messagingEndpoint" -ForegroundColor Cyan
    }
    if ($deployment.resourceGroup) {
        $resourceGroup = $deployment.resourceGroup
    }
}

if (-not $messagingEndpoint) {
    Write-Host "  WARNING: No deployment.json found. Run deploy.ps1 first, then re-run this script." -ForegroundColor Yellow
    Write-Host "  Setting placeholder endpoint." -ForegroundColor Yellow
    $messagingEndpoint = "https://<YOUR_CONTAINER_APP_FQDN>/api/messages"
}

# Build tenant domain from admin UPN
$tenantDomain = $demoConfig.adminUserPrincipalName.Split('@')[1]
$agentUpn = "$AgentName@$tenantDomain"

# Create config
$a365Config = @{
    tenantId                  = $demoConfig.tenantId
    subscriptionId            = $demoConfig.subscriptionId
    resourceGroup             = $resourceGroup
    location                  = $Location
    environment               = "prod"
    needDeployment            = $false
    messagingEndpoint         = $messagingEndpoint
    clientAppId               = $demoConfig.customClientAppId
    agentIdentityDisplayName  = "$AgentDisplayName Identity"
    agentBlueprintDisplayName = $AgentDisplayName
    agentUserPrincipalName    = $agentUpn
    agentUserDisplayName      = $AgentDisplayName
    managerEmail              = $demoConfig.adminUserPrincipalName
    agentUserUsageLocation    = "US"
    deploymentProjectPath     = "."
    agentDescription          = "$AgentName - Agent 365 Agent"
}

$a365Config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Force

Write-Host ""
Write-Host "  OK Configuration saved to: $configPath" -ForegroundColor Green
Write-Host ""
Write-Host "  Agent Name: $AgentName" -ForegroundColor White
Write-Host "  Display Name: $AgentDisplayName" -ForegroundColor White
Write-Host "  Agent UPN: $agentUpn" -ForegroundColor White
Write-Host "  Resource Group: $resourceGroup" -ForegroundColor White
Write-Host "  needDeployment: false (Container Apps)" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. cd $(Split-Path $configPath -Parent)" -ForegroundColor Gray
Write-Host "  2. a365 setup all --skip-infrastructure --verbose" -ForegroundColor Gray
Write-Host "  3. Update container with CLIENT_ID/SECRET/TENANT_ID from a365 output" -ForegroundColor Gray
Write-Host "  4. a365 publish --verbose" -ForegroundColor Gray
Write-Host ""
