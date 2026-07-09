<#
================================================================================
 Load-ReuseData.ps1 — MACAE reuse data loader for the RPSI private landing zone.

 Run this FROM the VM inside the VNet (vm-cm02avdd0007) after the Container Apps
 are deployed and images are built. It:
   * uploads agent-team configs to the backend,
   * uploads sample datasets to the REUSED Storage account (cross-RG, core RG),
   * builds the AI Search indexes on the REUSED Search service (cross-RG).

 Differences vs the stock selecting_team_config_and_data script:
   * No azd dependency; all values passed explicitly.
   * NO public-network toggling — the Storage/Search private endpoints are
     already reachable from the VM, and the "Deny Public Access" policy would
     block the toggle anyway. Controlled by -SkipNetworkToggle (default: on).
   * Storage and Search live in a DIFFERENT resource group (core-foundry RG).
   * Blob upload uses AAD (--auth-mode login); make sure the signed-in user (or
     the VM identity you az login with) has Storage Blob Data Contributor on the
     reused Storage account and Search Index Data Contributor on the Search svc.

 Prereqs on the VM:
   * az CLI + Python 3 installed; run from the repo root.
   * DNS: the VM's VNet must resolve the Storage/Search privatelink FQDNs to
     their private endpoints (10.22.144.132 blob, 10.22.144.133 search). If corp
     DNS returns NXDOMAIN, add hosts entries (see -PrintHostsHints).
   * The backend Container App must be reachable. Internal CAE FQDNs resolve to
     the environment static IP 10.22.144.170; add a hosts entry mapping the
     backend FQDN to 10.22.144.170 if corp DNS can't resolve *.azurecontainerapps.io.

 Example:
   ./Load-ReuseData.ps1 `
     -BackendUrl  https://ca-macae-be-rpsi-dev-weu-01.purplebay-8719396f.westeurope.azurecontainerapps.io `
     -StorageAccount stfoundryrpsidweu01 `
     -SearchService  srch-foundry-rpsi-dev-weu-01 `
     -CoreResourceGroup rg-core-foundry-rpsi-dev-weu-01 `
     -UseCase all
================================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BackendUrl,
    [Parameter(Mandatory = $true)] [string] $StorageAccount,
    [Parameter(Mandatory = $true)] [string] $SearchService,
    [Parameter(Mandatory = $true)] [string] $CoreResourceGroup,

    [ValidateSet('rfp', 'retail', 'hr', 'marketing', 'contract', 'all')]
    [string] $UseCase = 'all',

    # Default ON: never toggle public network access (Deny-Public policy + VNet reachability).
    [switch] $SkipNetworkToggle = $true,

    [switch] $PrintHostsHints
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

# ---- Container + index + dataset maps (mirror the stock naming) -------------
$containers = @{
    retailCustomer     = 'retail-dataset-customer'
    retailOrder        = 'retail-dataset-order'
    rfpSummary         = 'rfp-summary-dataset'
    rfpRisk            = 'rfp-risk-dataset'
    rfpCompliance      = 'rfp-compliance-dataset'
    contractSummary    = 'contract-summary-dataset'
    contractRisk       = 'contract-risk-dataset'
    contractCompliance = 'contract-compliance-dataset'
}
$indexes = @{
    retailCustomer     = 'macae-retail-customer-index'
    retailOrder        = 'macae-retail-order-index'
    rfpSummary         = 'macae-rfp-summary-index'
    rfpRisk            = 'macae-rfp-risk-index'
    rfpCompliance      = 'macae-rfp-compliance-index'
    contractSummary    = 'contract-summary-doc-index'
    contractRisk       = 'contract-risk-doc-index'
    contractCompliance = 'contract-compliance-doc-index'
}
$teamIds = @{
    hr       = '00000000-0000-0000-0000-000000000001'
    marketing= '00000000-0000-0000-0000-000000000002'
    retail   = '00000000-0000-0000-0000-000000000003'
    rfp      = '00000000-0000-0000-0000-000000000004'
    contract = '00000000-0000-0000-0000-000000000005'
}

if ($PrintHostsHints) {
    Write-Host "Add these to C:\Windows\System32\drivers\etc\hosts on the VM if corp DNS returns NXDOMAIN:" -ForegroundColor Yellow
    Write-Host "10.22.144.132 $StorageAccount.blob.core.windows.net"
    Write-Host "10.22.144.133 $SearchService.search.windows.net"
    Write-Host "10.22.144.170 <backend-container-app-fqdn>   # from az containerapp show ... ingress.fqdn"
    Pop-Location; return
}

# ---- Auth check ------------------------------------------------------------
try { az account show 1>$null 2>$null } catch { az login --identity 1>$null }
$userPrincipalId = az ad signed-in-user show --query id -o tsv 2>$null

# ---- Python bootstrap ------------------------------------------------------
# (Windows PowerShell 5.1 has no ternary operator, so use if/else.)
if (Get-Command python -ErrorAction SilentlyContinue) { $pythonCmd = 'python' } else { $pythonCmd = 'python3' }
$venvPath = 'infra/scripts/scriptenv'
if (-not (Test-Path $venvPath)) { & $pythonCmd -m venv $venvPath }
$activate = Join-Path $venvPath 'Scripts/Activate.ps1'
if (Test-Path $activate) { . $activate }
pip install --quiet -r infra/scripts/requirements.txt

if ($SkipNetworkToggle) {
    Write-Host "SkipNetworkToggle enabled — not touching Storage/Search public network access." -ForegroundColor Cyan
}

function Invoke-TeamConfig([string]$id) {
    Write-Host "Uploading team config $id ..." -ForegroundColor Green
    & $pythonCmd infra/scripts/upload_team_config.py $BackendUrl 'data/agent_teams' $userPrincipalId $id
    if ($LASTEXITCODE -ne 0) { Write-Warning "Team config $id upload failed." }
}
function Invoke-Upload([string]$container, [string]$src) {
    Write-Host "Uploading $src -> $container ..." -ForegroundColor Green
    az storage blob upload-batch --account-name $StorageAccount --destination $container `
        --source $src --auth-mode login --pattern "*" --overwrite --output none
    if ($LASTEXITCODE -ne 0) { throw "Blob upload failed for $container" }
}
function Invoke-Index([string]$container, [string]$index) {
    Write-Host "Indexing $container -> $index ..." -ForegroundColor Green
    & $pythonCmd infra/scripts/index_datasets.py $StorageAccount $container $SearchService $index
    if ($LASTEXITCODE -ne 0) { Write-Warning "Indexing failed for $index." }
}

$do = { param($u) $UseCase -eq 'all' -or $UseCase -eq $u }

if (& $do 'hr')        { Invoke-TeamConfig $teamIds.hr }
if (& $do 'marketing') { Invoke-TeamConfig $teamIds.marketing }

if (& $do 'rfp') {
    Invoke-TeamConfig $teamIds.rfp
    Invoke-Upload $containers.rfpSummary    'data/datasets/rfp/summary'
    Invoke-Upload $containers.rfpRisk       'data/datasets/rfp/risk'
    Invoke-Upload $containers.rfpCompliance 'data/datasets/rfp/compliance'
    Invoke-Index  $containers.rfpSummary    $indexes.rfpSummary
    Invoke-Index  $containers.rfpRisk       $indexes.rfpRisk
    Invoke-Index  $containers.rfpCompliance $indexes.rfpCompliance
}

if (& $do 'contract') {
    Invoke-TeamConfig $teamIds.contract
    Invoke-Upload $containers.contractSummary    'data/datasets/contract_compliance/summary'
    Invoke-Upload $containers.contractRisk       'data/datasets/contract_compliance/risk'
    Invoke-Upload $containers.contractCompliance 'data/datasets/contract_compliance/compliance'
    Invoke-Index  $containers.contractSummary    $indexes.contractSummary
    Invoke-Index  $containers.contractRisk       $indexes.contractRisk
    Invoke-Index  $containers.contractCompliance $indexes.contractCompliance
}

if (& $do 'retail') {
    Invoke-TeamConfig $teamIds.retail
    Invoke-Upload $containers.retailCustomer 'data/datasets/retail/customer'
    Invoke-Upload $containers.retailOrder    'data/datasets/retail/order'
    Invoke-Index  $containers.retailCustomer $indexes.retailCustomer
    Invoke-Index  $containers.retailOrder    $indexes.retailOrder
}

Write-Host "Reuse data load complete." -ForegroundColor Cyan
Pop-Location
