// ============================================================================
// CKM Reuse Template — deploys ONLY new resources into the existing RG.
// Reuses existing landing-zone infra (VNet, CAE, Foundry, Search, Cosmos,
// SQL server, Storage, identity). Creates: backend + frontend Container Apps,
// SQL database, Cosmos DB + container, and RBAC role assignments.
// ============================================================================
targetScope = 'resourceGroup'

@description('Azure region for new resources.')
param location string = 'westeurope'

@description('Tags applied to new resources.')
param tags object = {}

@description('Set false to skip RBAC role assignments (needs UAA on core RG). Run them separately if false.')
param deployRbac bool = false

// ---------- Existing networking ----------
@description('Resource group of the core foundry/network resources.')
param coreResourceGroupName string = 'rg-core-foundry-rpsi-dev-weu-01'

@description('Resource group of the shared resources (SQL, KV).')
param sharedResourceGroupName string = 'rg-gen-shared-rpsi-dev-weu-01'

@description('Existing Container Apps Environment name (internal, snet-cae).')
param containerAppEnvironmentName string = 'cae-foundry-rpsi-dev-weu-01'

// ---------- Existing AI / data services ----------
param aiFoundryAccountName string = 'aif-foundry-rpsi-dev-weu-01'
param aiFoundryProjectName string = 'DigitalManufacturing'
param aiSearchName string = 'srch-foundry-rpsi-dev-weu-01'
param cosmosAccountName string = 'cosmos-foundry-rpsi-dev-weu-01'
param sqlServerName string = 'sql-cm02dbsd0005'
param storageAccountName string = 'stfoundryrpsidweu01'
param backendUserAssignedIdentityName string = 'uai-aci-pull-digitalmfg-rpsi-dev-weu-01'

// ---------- New resource names ----------
param backendContainerAppName string = 'ca-digitalmfg-be-rpsi-dev-weu-01'
param frontendContainerAppName string = 'ca-digitalmfg-fe-rpsi-dev-weu-01'
param sqlDatabaseName string = 'sqldb-digitalmfg-rpsi-dev-weu-01'
param cosmosDatabaseName string = 'db_conversation_history'
param cosmosContainerName string = 'conversations'

// ---------- Models / config ----------
param gptModelName string = 'gpt-5-mini'
param azureAiAgentApiVersion string = '2025-05-01'
param aiSearchIndexName string = 'call_transcripts_index'

// ---------- Post-deploy data-load config (consumed by scripts via outputs) ----------
@description('Embedding model deployment name on the reused Foundry account.')
param embeddingModel string = 'text-embedding-3-large'

@description('Content Understanding API version.')
param azureContentUnderstandingApiVersion string = '2025-11-01'

@description('Solution name used to name agents and CU analyzers.')
param solutionName string = 'digitalmfg'

@description('Sample data use case: IT_helpdesk or telecom.')
param usecase string = 'IT_helpdesk'

@description('Blob container/file system used for knowledge-base data.')
param storageContainerName string = 'data'

// ---------- Container images ----------
param backendImage string = 'kmcontainerreg.azurecr.io/km-api:latest_afv2_2026-03-10_1326'
param frontendImage string = 'kmcontainerreg.azurecr.io/km-app:latest_afv2_2026-03-10_1326'

var reactAppLayoutConfig = '''{"appConfig":{"THREE_COLUMN":{"DASHBOARD":50,"CHAT":33,"CHATHISTORY":17},"TWO_COLUMN":{"DASHBOARD_CHAT":{"DASHBOARD":65,"CHAT":35},"CHAT_CHATHISTORY":{"CHAT":80,"CHATHISTORY":20}}}}'''

// ============================================================================
// EXISTING references (no creation)
// ============================================================================
resource cae 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppEnvironmentName
  scope: resourceGroup(coreResourceGroupName)
}

resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: backendUserAssignedIdentityName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aiFoundryAccountName
  scope: resourceGroup(coreResourceGroupName)
}

var projEndpoint = 'https://${aiFoundryAccountName}.services.ai.azure.com/api/projects/${aiFoundryProjectName}'

// ============================================================================
// NEW: SQL database on existing server (shared RG) via module
// ============================================================================
module sqlDb 'modules/reuse-sqldb.bicep' = {
  name: 'deploy-sqldb'
  scope: resourceGroup(sharedResourceGroupName)
  params: {
    sqlServerName: sqlServerName
    sqlDatabaseName: sqlDatabaseName
    location: location
    tags: tags
  }
}

// ============================================================================
// NEW: Cosmos database + container on existing account (core RG) via module
// ============================================================================
module cosmosDb 'modules/reuse-cosmos.bicep' = {
  name: 'deploy-cosmos'
  scope: resourceGroup(coreResourceGroupName)
  params: {
    cosmosAccountName: cosmosAccountName
    cosmosDatabaseName: cosmosDatabaseName
    cosmosContainerName: cosmosContainerName
  }
}

// ============================================================================
// NEW: RBAC for backend identity on reused services (core RG) via module
// ============================================================================
module rbac 'modules/reuse-rbac.bicep' = if (deployRbac) {
  name: 'deploy-rbac'
  scope: resourceGroup(coreResourceGroupName)
  params: {
    foundryAccountName: aiFoundryAccountName
    searchName: aiSearchName
    storageAccountName: storageAccountName
    principalId: backendIdentity.properties.principalId
  }
}

// ============================================================================
// NEW: Backend Container App (internal ingress)
// ============================================================================
resource backendContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendContainerAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${backendIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
        traffic: [{ latestRevision: true, weight: 100 }]
      }
    }
    template: {
      containers: [
        {
          image: backendImage
          name: 'km-api'
          resources: { cpu: json('1.0'), memory: '2.0Gi' }
          env: [
            { name: 'REACT_APP_LAYOUT_CONFIG', value: reactAppLayoutConfig }
            { name: 'AGENT_NAME_CONVERSATION', value: '' }
            { name: 'AGENT_NAME_TITLE', value: '' }
            { name: 'API_APP_NAME', value: backendContainerAppName }
            { name: 'AI_FOUNDRY_RESOURCE_ID', value: foundry.id }
            { name: 'AZURE_AI_AGENT_ENDPOINT', value: projEndpoint }
            { name: 'AZURE_AI_AGENT_API_VERSION', value: azureAiAgentApiVersion }
            { name: 'AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME', value: gptModelName }
            { name: 'USE_CHAT_HISTORY_ENABLED', value: 'True' }
            { name: 'AZURE_COSMOSDB_ACCOUNT', value: cosmosAccountName }
            { name: 'AZURE_COSMOSDB_CONVERSATIONS_CONTAINER', value: cosmosContainerName }
            { name: 'AZURE_COSMOSDB_DATABASE', value: cosmosDatabaseName }
            { name: 'AZURE_COSMOSDB_ENABLE_FEEDBACK', value: 'True' }
            { name: 'SQLDB_DATABASE', value: sqlDatabaseName }
            { name: 'SQLDB_SERVER', value: '${sqlServerName}${environment().suffixes.sqlServerHostname}' }
            { name: 'SQLDB_USER_MID', value: backendIdentity.properties.clientId }
            { name: 'AZURE_AI_SEARCH_ENDPOINT', value: 'https://${aiSearchName}.search.windows.net' }
            { name: 'AZURE_AI_SEARCH_INDEX', value: aiSearchIndexName }
            { name: 'AZURE_AI_SEARCH_CONNECTION_NAME', value: aiSearchName }
            { name: 'USE_AI_PROJECT_CLIENT', value: 'True' }
            { name: 'DISPLAY_CHART_DEFAULT', value: 'False' }
            { name: 'APP_ENV', value: 'Prod' }
            { name: 'AZURE_CLIENT_ID', value: backendIdentity.properties.clientId }
            { name: 'AZURE_BASIC_LOGGING_LEVEL', value: 'INFO' }
            { name: 'AZURE_PACKAGE_LOGGING_LEVEL', value: 'WARNING' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// ============================================================================
// NEW: Frontend Container App (internal ingress)
// ============================================================================
resource frontendContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: frontendContainerAppName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
        traffic: [{ latestRevision: true, weight: 100 }]
      }
    }
    template: {
      containers: [
        {
          image: frontendImage
          name: 'km-app'
          resources: { cpu: json('1.0'), memory: '2.0Gi' }
          env: [
            { name: 'APP_API_BASE_URL', value: 'https://${backendContainerApp.properties.configuration.ingress.fqdn}' }
            { name: 'BACKEND_API_HOST', value: '' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// ============================================================================
// NEW: RBAC handled by modules/reuse-rbac.bicep (core RG)
// ============================================================================

// ============================================================================
// Outputs
// ============================================================================
output RESOURCE_GROUP_NAME string = resourceGroup().name
output API_APP_NAME string = backendContainerAppName
output WEB_APP_NAME string = frontendContainerAppName
output API_APP_URL string = 'https://${backendContainerApp.properties.configuration.ingress.fqdn}'
output WEB_APP_URL string = 'https://${frontendContainerApp.properties.configuration.ingress.fqdn}'
output SQLDB_SERVER string = '${sqlServerName}${environment().suffixes.sqlServerHostname}'
output SQLDB_DATABASE string = sqlDatabaseName
output AZURE_AI_AGENT_ENDPOINT string = projEndpoint
output AI_FOUNDRY_RESOURCE_ID string = foundry.id
output AZURE_AI_SEARCH_CONNECTION_NAME string = aiSearchName
output AZURE_AI_SEARCH_INDEX string = aiSearchIndexName

// ---- Additional outputs consumed by post-deploy data-load scripts ----
output STORAGE_ACCOUNT_NAME string = storageAccountName
output STORAGE_CONTAINER_NAME string = storageContainerName
output AZURE_AI_SEARCH_NAME string = aiSearchName
output AZURE_AI_SEARCH_ENDPOINT string = 'https://${aiSearchName}.search.windows.net'
output AZURE_OPENAI_ENDPOINT string = 'https://${aiFoundryAccountName}.openai.azure.com/'
output AZURE_OPENAI_CU_ENDPOINT string = 'https://${aiFoundryAccountName}.services.ai.azure.com/'
output AZURE_CONTENT_UNDERSTANDING_API_VERSION string = azureContentUnderstandingApiVersion
output AZURE_ENV_EMBEDDING_MODEL_NAME string = embeddingModel
output AZURE_ENV_GPT_MODEL_NAME string = gptModelName
output AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME string = gptModelName
output BACKEND_USER_MID string = backendIdentity.properties.clientId
output BACKEND_USER_MID_NAME string = backendUserAssignedIdentityName
output SOLUTION_NAME string = solutionName
output USE_CASE string = usecase
