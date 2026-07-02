targetScope = 'resourceGroup'
param sqlServerName string
param sqlDatabaseName string
param location string
param tags object = {}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' existing = { name: sqlServerName }

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  name: sqlDatabaseName
  parent: sqlServer
  location: location
  tags: tags
  sku: { name: 'GP_S_Gen5_2', tier: 'GeneralPurpose' }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368
  }
}

output name string = sqlDatabase.name
