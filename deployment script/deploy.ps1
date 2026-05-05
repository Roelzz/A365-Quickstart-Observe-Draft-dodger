<#
.SYNOPSIS
    Deploy a Python Agent Framework agent to Azure Container Apps.

.DESCRIPTION
    Self-contained deployment script. No external repo dependencies.
    Creates Resource Group, ACR, Container Apps Environment, and Container App.
    Reads .env for environment variables, saves deployment info to deployment.json.

.PARAMETER AgentName
    Lowercase agent name (no spaces). Used for resource naming.

.PARAMETER Location
    Azure region. Default: swedencentral (westeurope often has capacity issues).

.PARAMETER AgentFolder
    Path to agent project folder. Default: parent of scripts/ directory.

.PARAMETER ConfigPath
    Path to demo-tenant.config.json. Default: <AgentFolder>/demo-tenant.config.json

.EXAMPLE
    ./scripts/deploy.ps1 -AgentName "myagent" -Location "swedencentral"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AgentName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "swedencentral",

    [Parameter(Mandatory = $false)]
    [string]$AgentFolder,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

# Resolve agent folder (default: parent of scripts/)
if (-not $AgentFolder) {
    $AgentFolder = (Get-Item "$PSScriptRoot\..").FullName
}

# Resolve config path (default: demo-tenant.config.json in agent folder)
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $AgentFolder "demo-tenant.config.json"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Python Agent - Azure Container Apps" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Step 1: Load tenant config
Write-Host "[1/8] Loading tenant configuration..." -ForegroundColor Yellow
if (-not (Test-Path $ConfigPath)) {
    Write-Host "  ERROR: Config not found: $ConfigPath" -ForegroundColor Red
    Write-Host "  Copy demo-tenant.config.json.example and fill in values." -ForegroundColor Yellow
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$tenantId = $config.tenantId
$subscriptionId = $config.subscriptionId
Write-Host "  Tenant: $tenantId" -ForegroundColor Gray
Write-Host "  Subscription: $subscriptionId" -ForegroundColor Gray

# Step 2: Azure CLI auth
Write-Host "[2/8] Checking Azure CLI authentication..." -ForegroundColor Yellow
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account -or $account.tenantId -ne $tenantId) {
    az login --tenant $tenantId
}
az account set --subscription $subscriptionId
Write-Host "  OK Authenticated" -ForegroundColor Green

# Step 2.5: Register providers
Write-Host "[2.5/8] Registering Azure resource providers..." -ForegroundColor Yellow
$providers = @("Microsoft.App", "Microsoft.OperationalInsights", "Microsoft.ContainerRegistry")
foreach ($provider in $providers) {
    $status = az provider show --namespace $provider --query "registrationState" -o tsv 2>$null
    if ($status -ne "Registered") {
        Write-Host "  Registering $provider..." -ForegroundColor Gray
        az provider register --namespace $provider --wait --output none
    }
}
Write-Host "  OK Resource providers registered" -ForegroundColor Green

# Step 3: Resource names
$ResourceGroupName = "rg-agent365-$AgentName-$Location"
$envName = "cae-$AgentName"
$appName = "ca-$AgentName"

# Check existing deployment for ACR reuse
$deploymentInfoPath = Join-Path $AgentFolder "deployment.json"
$existingAcrName = $null
if (Test-Path $deploymentInfoPath) {
    $existingDeployment = Get-Content $deploymentInfoPath -Raw | ConvertFrom-Json
    if ($existingDeployment.containerRegistry) {
        $existingAcrName = $existingDeployment.containerRegistry
        $acrCheck = az acr show --name $existingAcrName --query "name" -o tsv 2>$null
        if ($acrCheck) { Write-Host "  Found existing deployment - reusing ACR" -ForegroundColor Cyan }
        else { $existingAcrName = $null }
    }
}

if ($existingAcrName) { $acrName = $existingAcrName }
else { $acrName = "acr$($AgentName -replace '[^a-zA-Z0-9]', '')$(Get-Random -Maximum 9999)" }

$imageName = "$($acrName.ToLower()).azurecr.io/${AgentName}:latest"

Write-Host "[3/8] Creating Resource Group..." -ForegroundColor Yellow
Write-Host "  Name: $ResourceGroupName" -ForegroundColor Gray
az group create --name $ResourceGroupName --location $Location --output none
Write-Host "  OK Resource Group ready" -ForegroundColor Green

# Step 4: ACR
Write-Host "[4/8] Setting up Azure Container Registry..." -ForegroundColor Yellow
Write-Host "  Name: $acrName" -ForegroundColor Gray
$acrExists = az acr show --name $acrName --query "name" -o tsv 2>$null
if (-not $acrExists) {
    az acr create --resource-group $ResourceGroupName --name $acrName --sku Basic --admin-enabled true --output none
    Write-Host "  OK Container Registry created" -ForegroundColor Green
} else {
    Write-Host "  OK Container Registry exists (reusing)" -ForegroundColor Green
}

$acrCreds = az acr credential show --name $acrName | ConvertFrom-Json
$acrPassword = $acrCreds.passwords[0].value

# Step 5: Build and push
Write-Host "[5/8] Building and pushing Docker image..." -ForegroundColor Yellow
Push-Location $AgentFolder
az acr login --name $acrName
Write-Host "  Building image (this may take 2-3 minutes)..." -ForegroundColor Gray
az acr build --registry $acrName --image "${AgentName}:latest" . --platform linux/amd64
Pop-Location
Write-Host "  OK Image pushed to ACR" -ForegroundColor Green

# Step 6: Container Apps Environment
Write-Host "[6/8] Creating Container Apps Environment..." -ForegroundColor Yellow
Write-Host "  Name: $envName" -ForegroundColor Gray
$envResult = az containerapp env create --name $envName --resource-group $ResourceGroupName --location $Location --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Start-Sleep -Seconds 10
    az containerapp env create --name $envName --resource-group $ResourceGroupName --location $Location --output json 2>&1
}
$envCheck = az containerapp env show --name $envName --resource-group $ResourceGroupName --query "name" -o tsv 2>$null
if (-not $envCheck) { Write-Error "Failed to create Container Apps Environment"; exit 1 }
Write-Host "  OK Environment created" -ForegroundColor Green

# Step 7: Deploy Container App
Write-Host "[7/8] Deploying Container App..." -ForegroundColor Yellow
$envFilePath = Join-Path $AgentFolder ".env"
$envVars = @()
if (Test-Path $envFilePath) {
    Get-Content $envFilePath | ForEach-Object {
        if ($_ -match '^([^#][^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($key -and $value) { $envVars += "$key=$value" }
        }
    }
}
# Force correct values for deployment
$envVars = $envVars | Where-Object { $_ -notmatch '^PORT=' }
$envVars += "PORT=3978"
$envVars = $envVars | Where-Object { $_ -notmatch '^BEARER_TOKEN=' }
$envVars = $envVars | Where-Object { $_ -notmatch 'ALT_BLUEPRINT' }
$envVars = $envVars | Where-Object { $_ -notmatch '^TOOLS_MODE=' }
$envVars = $envVars | Where-Object { $_ -notmatch '^MOCK_MCP_SERVER_URL=' }
$envVars = $envVars | Where-Object { $_ -notmatch '^AUTH_HANDLER_NAME=' }
$envVars += "AUTH_HANDLER_NAME=AGENTIC"

$appExists = az containerapp show --name $appName --resource-group $ResourceGroupName 2>$null
if ($appExists) {
    Write-Host "  Updating existing app: $appName" -ForegroundColor Gray
    az containerapp update --name $appName --resource-group $ResourceGroupName --image $imageName --output none
    Write-Host "  Setting $($envVars.Count) environment variables..." -ForegroundColor Gray
    az containerapp update --name $appName --resource-group $ResourceGroupName --set-env-vars $envVars --output none
} else {
    Write-Host "  Creating new app: $appName" -ForegroundColor Gray
    az containerapp create `
        --name $appName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --image $imageName `
        --target-port 3978 `
        --ingress external `
        --registry-server "$($acrName.ToLower()).azurecr.io" `
        --registry-username $acrName `
        --registry-password $acrPassword `
        --cpu 0.5 `
        --memory 1Gi `
        --min-replicas 1 `
        --max-replicas 3 `
        --env-vars $envVars `
        --output none
}
Write-Host "  OK Container App deployed" -ForegroundColor Green

$appInfo = az containerapp show --name $appName --resource-group $ResourceGroupName | ConvertFrom-Json
$fqdn = $appInfo.properties.configuration.ingress.fqdn
$endpoint = "https://$fqdn/api/messages"
$healthUrl = "https://$fqdn/api/health"

# Step 8: Validate
Write-Host "[8/8] Validating deployment..." -ForegroundColor Yellow
$healthCheckPassed = $false
for ($i = 1; $i -le 6; $i++) {
    Start-Sleep -Seconds 10
    Write-Host "  Health check attempt $i of 6..." -ForegroundColor Gray
    try {
        $healthResponse = Invoke-RestMethod -Uri $healthUrl -Method GET -TimeoutSec 15 -ErrorAction Stop
        if ($healthResponse.status -eq "ok") {
            $healthCheckPassed = $true
            Write-Host "  OK Health check passed!" -ForegroundColor Green
            break
        }
    } catch {
        if ($i -eq 6) { Write-Host "  WARNING: Health check failed after 6 attempts" -ForegroundColor Yellow }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Resource Group:     $ResourceGroupName" -ForegroundColor White
Write-Host "  Container Registry: $acrName" -ForegroundColor White
Write-Host "  Container App:      $appName" -ForegroundColor White
Write-Host "  Endpoint:           $endpoint" -ForegroundColor Green
Write-Host "  Health:             $healthUrl" -ForegroundColor Green
Write-Host ""

# Save deployment info
$deploymentInfo = @{
    resourceGroup     = $ResourceGroupName
    containerRegistry = $acrName
    containerApp      = $appName
    endpoint          = $endpoint
    fqdn              = $fqdn
    healthUrl         = $healthUrl
    healthCheckPassed = $healthCheckPassed
    location          = $Location
    deployedAt        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}
$deploymentInfo | ConvertTo-Json | Set-Content $deploymentInfoPath
Write-Host "  Deployment info saved to: $deploymentInfoPath" -ForegroundColor Gray
Write-Host ""
