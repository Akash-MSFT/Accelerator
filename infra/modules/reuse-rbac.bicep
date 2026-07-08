// ============================================================================
// reuse-rbac.bicep
// Assigns the data-plane roles the MACAE backend needs onto EXISTING reused
// resources (AI Foundry, AI Search, Storage) that live in the core RG.
// Called from main_reuse.bicep with `scope: resourceGroup(<core-foundry-rg>)`
// and gated by the `deployRbac` param (two-pass deploy pattern).
//
// NOTE: the Cosmos DB data-plane role (Built-in Data Contributor) is assigned
// separately via `az cosmosdb sql role assignment create` because it is a
// Cosmos-specific SQL role, not an Azure RBAC role.
// ============================================================================

@description('Required. Principal (object) ID of the backend User-Assigned Identity.')
param identityPrincipalId string

@description('Required. Name of the EXISTING AI Foundry (Cognitive Services) account.')
param aiFoundryName string

@description('Required. Name of the EXISTING AI Search service.')
param searchServiceName string

@description('Required. Name of the EXISTING Storage account.')
param storageAccountName string

// ---- Built-in role definition IDs ------------------------------------------
var roleIds = {
  foundryUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d' // Azure AI Foundry User
  azureAiDeveloper: '64702f94-c441-49e6-a78b-ef80e0188fee' // Azure AI Developer
  cognitiveServicesOpenAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7' // Search Index Data Contributor
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
}

// ---- Existing resources (in this module's target RG) -----------------------
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-12-01' existing = {
  name: aiFoundryName
}

resource searchService 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchServiceName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// ---- Foundry role assignments ----------------------------------------------
resource raFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry.id, identityPrincipalId, roleIds.foundryUser)
  scope: aiFoundry
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.foundryUser)
    principalType: 'ServicePrincipal'
  }
}

resource raAzureAiDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry.id, identityPrincipalId, roleIds.azureAiDeveloper)
  scope: aiFoundry
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.azureAiDeveloper)
    principalType: 'ServicePrincipal'
  }
}

resource raOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry.id, identityPrincipalId, roleIds.cognitiveServicesOpenAiUser)
  scope: aiFoundry
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAiUser)
    principalType: 'ServicePrincipal'
  }
}

// ---- Search role assignments -----------------------------------------------
resource raSearchIndexDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, identityPrincipalId, roleIds.searchIndexDataContributor)
  scope: searchService
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchIndexDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource raSearchServiceContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, identityPrincipalId, roleIds.searchServiceContributor)
  scope: searchService
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchServiceContributor)
    principalType: 'ServicePrincipal'
  }
}

// ---- Storage role assignment -----------------------------------------------
resource raStorageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, identityPrincipalId, roleIds.storageBlobDataContributor)
  scope: storageAccount
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}
