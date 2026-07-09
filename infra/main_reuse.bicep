// ============================================================================
// main_reuse.bicep
// MACAE (Multi-Agent Custom Automation Engine) — REUSE deployment for the
// RPSI private AI landing zone.
//
// Deploys ONLY the app layer (3 Container Apps) into an EXISTING private
// Container Apps Environment, reusing existing AI Foundry, AI Search,
// Cosmos DB, Storage and a User-Assigned Identity. No new networking, DNS,
// monitoring, Foundry, Search, Cosmos account or Storage account are created.
//
// Deploy with (two-pass RBAC pattern):
//   az deployment group create -g rg-gen-digitalmfg-rpsi-dev-weu-01 \
//     -n macae-reuse --template-file infra/main_reuse.bicep \
//     --parameters @infra/main_reuse.parameters.json deployRbac=false
//   az deployment group create -g rg-gen-digitalmfg-rpsi-dev-weu-01 \
//     -n macae-reuse-rbac --template-file infra/main_reuse.bicep \
//     --parameters @infra/main_reuse.parameters.json deployRbac=true
// ============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// General
// ---------------------------------------------------------------------------
@description('Azure region for the new app-layer resources. West Europe for RPSI.')
param location string = 'westeurope'

@description('Tags applied to created resources.')
param tags object = {
  application: 'macae'
  environment: 'dev'
  landingzone: 'rpsi'
}

@description('Second pass toggle. false = create apps only; true = also assign RBAC on reused resources.')
param deployRbac bool = false

// ---------------------------------------------------------------------------
// Container App names (explicit RPSI naming)
// ---------------------------------------------------------------------------
param backendContainerAppName string = 'ca-macae-be-rpsi-dev-weu-01'
param mcpContainerAppName string = 'ca-macae-mcp-rpsi-dev-weu-01'
param frontendContainerAppName string = 'ca-macae-fe-rpsi-dev-weu-01'

// ---------------------------------------------------------------------------
// Reused Container Apps Environment (in the CORE landing-zone RG)
// ---------------------------------------------------------------------------
@description('Resource ID of the EXISTING internal Container Apps Environment to reuse.')
param managedEnvironmentResourceId string = resourceId(
  'rg-core-foundry-rpsi-dev-weu-01',
  'Microsoft.App/managedEnvironments',
  'cae-foundry-rpsi-dev-weu-01'
)

@description('Default domain of the EXISTING Container Apps Environment (used to build internal FQDNs for CORS).')
param managedEnvironmentDefaultDomain string = 'purplebay-8719396f.westeurope.azurecontainerapps.io'

// ---------------------------------------------------------------------------
// Reused User-Assigned Identity (in the DEPLOY RG rg-gen-digitalmfg)
// ---------------------------------------------------------------------------
@description('Name of the EXISTING User-Assigned Identity used for ACR pull + data-plane auth.')
param userAssignedIdentityName string = 'uai-aci-pull-digitalmfg-rpsi-dev-weu-01'

@description('Client (application) ID of the reused UAI.')
param userAssignedIdentityClientId string = '38ab20d0-2349-4503-b63a-4152af0b90ed'

@description('Principal (object) ID of the reused UAI (for RBAC assignments).')
param userAssignedIdentityPrincipalId string = '5729970b-6f81-4dd9-996b-4f433369aaab'

// ---------------------------------------------------------------------------
// Container images (built into the existing ACR)
// ---------------------------------------------------------------------------
param acrLoginServer string = 'acrdigitalmfgrpsidweu01.azurecr.io'
param backendImage string = 'macae-backend:reuse-1'
param mcpImage string = 'macae-mcp:reuse-1'
param frontendImage string = 'macae-frontend:reuse-1'

// ---------------------------------------------------------------------------
// Reused AI Foundry (in the CORE RG)
// ---------------------------------------------------------------------------
param coreResourceGroupName string = 'rg-core-foundry-rpsi-dev-weu-01'
param aiFoundryName string = 'aif-foundry-rpsi-dev-weu-01'
param aiFoundryProjectName string = 'DigitalManufacturing'

@description('Foundry AI project endpoint used by the Agent SDK.')
param aiFoundryProjectEndpoint string = 'https://aif-foundry-rpsi-dev-weu-01.services.ai.azure.com/api/projects/DigitalManufacturing'

@description('Azure OpenAI endpoint of the reused Foundry account.')
param azureOpenAiEndpoint string = 'https://aif-foundry-rpsi-dev-weu-01.openai.azure.com/'

// ---------------------------------------------------------------------------
// Model deployment names (existing deployments on the reused Foundry).
// CONFIRM these against the live Foundry deployments before deploying.
// ---------------------------------------------------------------------------
@description('Primary chat model deployment name.')
param openAiModelDeploymentName string = 'gpt-5-mini'

@description('Deployment used for RAI / secondary generation.')
param openAiRaiDeploymentName string = 'gpt-5-chat'

@description('Reasoning model deployment name.')
param reasoningModelDeploymentName string = 'gpt-5-mini'

@description('JSON array of models the app should surface in the UI.')
param supportedModels string = '["gpt-5-mini","gpt-5-chat","gpt-5.5"]'

param azureOpenaiApiVersion string = '2025-01-01-preview'
param azureAiAgentApiVersion string = '2025-05-01'

// ---------------------------------------------------------------------------
// Reused Cosmos DB (account in CORE RG; DB/container created by this deploy)
// ---------------------------------------------------------------------------
param cosmosAccountName string = 'cosmos-foundry-rpsi-dev-weu-01'
param cosmosDatabaseName string = 'macae'
param cosmosContainerName string = 'memory'
param cosmosEndpoint string = 'https://cosmos-foundry-rpsi-dev-weu-01.documents.azure.com:443/'

// ---------------------------------------------------------------------------
// Reused AI Search (in CORE RG)
// ---------------------------------------------------------------------------
param searchServiceName string = 'srch-foundry-rpsi-dev-weu-01'
param searchEndpoint string = 'https://srch-foundry-rpsi-dev-weu-01.search.windows.net'
param aiSearchConnectionName string = 'srchfoundryrpsidevweuz7toiu'

// ---------------------------------------------------------------------------
// Reused Storage (in CORE RG)
// ---------------------------------------------------------------------------
param storageAccountName string = 'stfoundryrpsidweu01'
param storageBlobUrl string = 'https://stfoundryrpsidweu01.blob.core.windows.net/'

// ---------------------------------------------------------------------------
// Private-DNS /etc/hosts workaround (corp DNS returns NXDOMAIN for privatelink)
// Injected into the BACKEND container at startup via entrypoint.sh.
// One "IP host" pair per line.
// ---------------------------------------------------------------------------
param extraHosts string = '''10.22.144.134 cosmos-foundry-rpsi-dev-weu-01.documents.azure.com
10.22.144.135 cosmos-foundry-rpsi-dev-weu-01-westeurope.documents.azure.com
10.22.144.138 aif-foundry-rpsi-dev-weu-01.services.ai.azure.com
10.22.144.137 aif-foundry-rpsi-dev-weu-01.openai.azure.com
10.22.144.136 aif-foundry-rpsi-dev-weu-01.cognitiveservices.azure.com
10.22.144.133 srch-foundry-rpsi-dev-weu-01.search.windows.net
10.22.144.132 stfoundryrpsidweu01.blob.core.windows.net'''

// ===========================================================================
// Existing resources
// ===========================================================================
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: userAssignedIdentityName
}

// Computed FQDNs for CORS (avoids circular dependency on ingress output).
// Apps use external ingress on the INTERNAL environment (matches the working CKM
// deployment): the env has no public IP, so this stays private to the VNet but
// is reachable at the non-".internal" FQDN via the env load balancer 10.22.144.170.
var frontendInternalFqdn = '${frontendContainerAppName}.${managedEnvironmentDefaultDomain}'
var frontendOrigin = 'https://${frontendInternalFqdn}'

// ===========================================================================
// MCP Container App (internal ingress, :9000) — created first
// ===========================================================================
resource mcpContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: mcpContainerAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentResourceId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        // Internal ingress: only the frontend (same environment) calls the MCP
        // server. Internal FQDN (*.internal.*) resolves to the env LB 10.22.144.170
        // for app-to-app; an external FQDN would resolve to a public IP that is
        // unreachable from inside this internal-only environment.
        external: false
        targetPort: 9000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acrLoginServer
          identity: userAssignedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp'
          image: '${acrLoginServer}/${mcpImage}'
          resources: {
            cpu: json('2.0')
            memory: '4.0Gi'
          }
          env: [
            { name: 'HOST', value: '0.0.0.0' }
            { name: 'PORT', value: '9000' }
            { name: 'DEBUG', value: 'false' }
            { name: 'SERVER_NAME', value: 'MacaeMcpServer' }
            { name: 'ENABLE_AUTH', value: 'false' }
            { name: 'TENANT_ID', value: tenant().tenantId }
            { name: 'CLIENT_ID', value: userAssignedIdentityClientId }
            { name: 'JWKS_URI', value: 'https://login.microsoftonline.com/${tenant().tenantId}/discovery/v2.0/keys' }
            { name: 'ISSUER', value: 'https://sts.windows.net/${tenant().tenantId}/' }
            { name: 'AUDIENCE', value: 'api://${userAssignedIdentityClientId}' }
            { name: 'DATASET_PATH', value: './datasets' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ===========================================================================
// Backend Container App (internal ingress, :8000)
// ===========================================================================
resource backendContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendContainerAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentResourceId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        // Internal ingress: the backend is only called by the frontend (same
        // environment) and, for the one-time data load, from the in-VNet VM.
        // Internal FQDN resolves to the env LB 10.22.144.170 for app-to-app and
        // is reachable from peered VNets via that same private IP. (An external
        // FQDN resolves to a public IP that the frontend container cannot reach
        // from inside this internal-only environment -> httpx ConnectError.)
        external: false
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
        corsPolicy: {
          allowedOrigins: [
            frontendOrigin
          ]
          allowedMethods: [
            'GET'
            'POST'
            'PUT'
            'DELETE'
            'OPTIONS'
          ]
        }
      }
      registries: [
        {
          server: acrLoginServer
          identity: userAssignedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'backend'
          image: '${acrLoginServer}/${backendImage}'
          resources: {
            cpu: json('2.0')
            memory: '4.0Gi'
          }
          env: [
            { name: 'COSMOSDB_ENDPOINT', value: cosmosEndpoint }
            { name: 'COSMOSDB_DATABASE', value: cosmosDatabaseName }
            { name: 'COSMOSDB_CONTAINER', value: cosmosContainerName }
            { name: 'AZURE_OPENAI_ENDPOINT', value: azureOpenAiEndpoint }
            { name: 'AZURE_OPENAI_MODEL_NAME', value: openAiModelDeploymentName }
            { name: 'AZURE_OPENAI_DEPLOYMENT_NAME', value: openAiModelDeploymentName }
            { name: 'AZURE_OPENAI_RAI_DEPLOYMENT_NAME', value: openAiRaiDeploymentName }
            { name: 'AZURE_OPENAI_API_VERSION', value: azureOpenaiApiVersion }
            { name: 'AZURE_AI_SUBSCRIPTION_ID', value: subscription().subscriptionId }
            { name: 'AZURE_AI_RESOURCE_GROUP', value: coreResourceGroupName }
            { name: 'AZURE_AI_PROJECT_NAME', value: aiFoundryProjectName }
            // Monitoring disabled: app requires these keys to be PRESENT (empty string is accepted).
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: '' }
            { name: 'APPLICATIONINSIGHTS_INSTRUMENTATION_KEY', value: '' }
            { name: 'FRONTEND_SITE_NAME', value: frontendOrigin }
            { name: 'AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME', value: openAiModelDeploymentName }
            { name: 'APP_ENV', value: 'Prod' }
            { name: 'AZURE_AI_SEARCH_CONNECTION_NAME', value: aiSearchConnectionName }
            { name: 'AZURE_AI_SEARCH_ENDPOINT', value: searchEndpoint }
            { name: 'AZURE_COGNITIVE_SERVICES', value: 'https://cognitiveservices.azure.com/.default' }
            { name: 'REASONING_MODEL_NAME', value: reasoningModelDeploymentName }
            { name: 'MCP_SERVER_ENDPOINT', value: 'https://${mcpContainerApp.properties.configuration.ingress.fqdn}/mcp' }
            { name: 'MCP_SERVER_NAME', value: 'MacaeMcpServer' }
            { name: 'MCP_SERVER_DESCRIPTION', value: 'MCP server with greeting, HR, and planning tools' }
            { name: 'AZURE_TENANT_ID', value: tenant().tenantId }
            { name: 'AZURE_CLIENT_ID', value: userAssignedIdentityClientId }
            { name: 'SUPPORTED_MODELS', value: supportedModels }
            { name: 'AZURE_STORAGE_BLOB_URL', value: storageBlobUrl }
            { name: 'AZURE_AI_PROJECT_ENDPOINT', value: aiFoundryProjectEndpoint }
            { name: 'AZURE_AI_AGENT_ENDPOINT', value: aiFoundryProjectEndpoint }
            { name: 'AZURE_AI_AGENT_API_VERSION', value: azureAiAgentApiVersion }
            {
              name: 'AZURE_AI_AGENT_PROJECT_CONNECTION_STRING'
              value: '${aiFoundryName}.services.ai.azure.com;${subscription().subscriptionId};${coreResourceGroupName};${aiFoundryProjectName}'
            }
            { name: 'AZURE_BASIC_LOGGING_LEVEL', value: 'INFO' }
            { name: 'AZURE_PACKAGE_LOGGING_LEVEL', value: 'WARNING' }
            { name: 'AZURE_LOGGING_PACKAGES', value: '' }
            // Private-DNS workaround: consumed by entrypoint.sh to patch /etc/hosts
            { name: 'EXTRA_HOSTS', value: extraHosts }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ===========================================================================
// Frontend Container App (internal ingress, :3000)
// ===========================================================================
resource frontendContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: frontendContainerAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentResourceId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acrLoginServer
          identity: userAssignedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'frontend'
          image: '${acrLoginServer}/${frontendImage}'
          resources: {
            cpu: json('1.0')
            memory: '2.0Gi'
          }
          env: [
            { name: 'WEBSITES_PORT', value: '3000' }
            { name: 'BACKEND_API_URL', value: 'https://${backendContainerApp.properties.configuration.ingress.fqdn}' }
            { name: 'AUTH_ENABLED', value: 'false' }
            { name: 'PROXY_API_REQUESTS', value: 'true' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ===========================================================================
// Cross-RG data-plane objects: Cosmos DB + container on reused account
// ===========================================================================
module cosmos 'modules/reuse-cosmos.bicep' = {
  name: 'macae-reuse-cosmos'
  scope: resourceGroup(coreResourceGroupName)
  params: {
    cosmosAccountName: cosmosAccountName
    databaseName: cosmosDatabaseName
    containerName: cosmosContainerName
    partitionKeyPath: '/session_id'
  }
}

// ===========================================================================
// Cross-RG RBAC (second pass only)
// ===========================================================================
module rbac 'modules/reuse-rbac.bicep' = if (deployRbac) {
  name: 'macae-reuse-rbac'
  scope: resourceGroup(coreResourceGroupName)
  params: {
    identityPrincipalId: userAssignedIdentityPrincipalId
    aiFoundryName: aiFoundryName
    searchServiceName: searchServiceName
    storageAccountName: storageAccountName
  }
}

// ===========================================================================
// Outputs
// ===========================================================================
@description('Internal FQDN of the frontend (open from a VM inside the VNet).')
output frontendUrl string = 'https://${frontendContainerApp.properties.configuration.ingress.fqdn}'

@description('Internal FQDN of the backend API.')
output backendUrl string = 'https://${backendContainerApp.properties.configuration.ingress.fqdn}'

@description('Internal MCP endpoint used by the backend.')
output mcpEndpoint string = 'https://${mcpContainerApp.properties.configuration.ingress.fqdn}/mcp'

@description('Cosmos database created for MACAE.')
output cosmosDatabase string = cosmos.outputs.databaseName
