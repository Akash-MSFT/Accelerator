targetScope = 'resourceGroup'
param cosmosAccountName string
param cosmosDatabaseName string
param cosmosContainerName string

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = { name: cosmosAccountName }

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  name: cosmosDatabaseName
  parent: cosmos
  properties: { resource: { id: cosmosDatabaseName } }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  name: cosmosContainerName
  parent: cosmosDb
  properties: {
    resource: {
      id: cosmosContainerName
      partitionKey: { paths: ['/userId'], kind: 'Hash' }
    }
  }
}

output databaseName string = cosmosDb.name
output containerName string = cosmosContainer.name
