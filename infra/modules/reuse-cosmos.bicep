// ============================================================================
// reuse-cosmos.bicep
// Creates the MACAE SQL database + container INSIDE an EXISTING Cosmos DB
// account that lives in a different resource group (the core landing-zone RG).
// No new Cosmos account is created — only data-plane child objects.
// Called from main_reuse.bicep with `scope: resourceGroup(<core-foundry-rg>)`.
// ============================================================================

@description('Required. Name of the EXISTING Cosmos DB account to reuse.')
param cosmosAccountName string

@description('Optional. Name of the SQL database to create. MACAE expects "macae".')
param databaseName string = 'macae'

@description('Optional. Name of the container to create. MACAE expects "memory".')
param containerName string = 'memory'

@description('Optional. Partition key path. MACAE uses "/session_id".')
param partitionKeyPath string = '/session_id'

// Reference the existing Cosmos DB account (in this module's target RG).
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosAccountName
}

// SQL database (child of the existing account).
resource sqlDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

// Container with the session-scoped partition key required by MACAE.
resource sqlContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: sqlDatabase
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          partitionKeyPath
        ]
        kind: 'Hash'
        version: 2
      }
    }
  }
}

@description('Name of the created SQL database.')
output databaseName string = sqlDatabase.name

@description('Name of the created container.')
output containerName string = sqlContainer.name
