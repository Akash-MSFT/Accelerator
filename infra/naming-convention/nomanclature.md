# Naming Convention

| Resource Type | Purpose / Use | Name |
|---|---|---|
| Container Apps Environment | Managed serverless compute boundary that hosts the frontend and backend container apps | `cae-digitalmfg-rpsi-dev-weu-01` |
| Container App — Frontend | Hosts the React web UI (chat + dashboard) the end user interacts with | `ca-digitalmfg-fe-rpsi-dev-weu-01` |
| Container App — Backend | Hosts the FastAPI API; runs chat orchestration, SQL queries, and agent calls | `ca-digitalmfg-be-rpsi-dev-weu-01` |
| Azure AI Foundry (AI Services) | AI hub hosting the OpenAI models + Content Understanding; runs the agents | `aif-digitalmfg-rpsi-dev-weu-01` |
| AI Foundry Project | Agent workspace holding the conversation/title agents and AI Search connection | `proj-digitalmfg-rpsi-dev-weu-01` |
| OpenAI Model — gpt-4o-mini | LLM that interprets prompts, writes SQL, and generates answers/charts | `oai-digitalmfg-rpsi-dev-weu-01` |
| OpenAI Model — text-embedding-3-small | Generates vector embeddings of call transcripts for semantic search | `oai-digitalmfg-rpsi-dev-weu-01` |
| Azure AI Search | Indexes transcripts; powers semantic/RAG search and cited summaries | `srch-digitalmfg-rpsi-dev-weu-01` |
| Azure SQL Server | Logical SQL server (Entra ID-only auth, no passwords) | `sql-cm02dbsd0007` |
| Azure SQL Database | Structured store of analyzed data (topics, sentiment, key phrases) for metrics & charts | `sqldb-digitalmfg-rpsi-dev-weu-01` |
| Azure Cosmos DB | Stores chat history for conversation context and follow-ups | `cosmos-digitalmfg-rpsi-dev-weu-01` |
| Storage Account | Landing zone for raw call transcripts before processing (data ingestion) | `stdigitalmfgrpsidweu01` |
| Managed Identity — Deployment | Used during provisioning and role assignments | `umi-digitalmfg-deployment-rpsi-dev-weu-01` |
| Managed Identity — Backend | Backend access SQL, Search, Storage & Foundry securely without secrets | `umi-digitalmfg-backend-rpsi-dev-weu-01` |
| Azure Container Registry (public, Microsoft-hosted) | Source of the prebuilt frontend/backend container images | `acr-digitalmfg-rpsi-dev-weu-01` |
