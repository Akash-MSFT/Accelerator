# Knowledge Transfer (KT) Session - complete solution walkthrough By Deepak Sharma
## Conversation Knowledge Mining (CKM) Solution Accelerator

> **Audience:** Customer Engineering Team / Development Team inheriting the solution  
> **Purpose:** End-to-end walkthrough of the accelerator architecture, data ingestion pipeline, and extensibility patterns  
> **Date:** 2026-07-13

---

## Table of Contents

1. [Solution Overview](#1-solution-overview)
2. [Architecture Deep Dive](#2-architecture-deep-dive)
3. [Data Ingestion Pipeline – Step by Step](#3-data-ingestion-pipeline--step-by-step)
4. [Code Reference Map](#4-code-reference-map)
5. [Extending the Solution – Add a New Blob Storage Source](#5-extending-the-solution--add-a-new-blob-storage-source)
6. [Extending the Solution – Add Cosmos DB as a New Data Store](#6-extending-the-solution--add-cosmos-db-as-a-new-data-store)
7. [Configuration Reference](#7-configuration-reference)
8. [Security & Identity Model](#8-security--identity-model)
9. [FAQ & Common Troubleshooting](#9-faq--common-troubleshooting)
10. [Adding a New Blob Source – Full Setup Checklist](#10-adding-a-new-blob-source--full-setup-checklist)
11. [RAG Pipeline Metadata – What Is Tracked and What Is Not](#11-rag-pipeline-metadata--what-is-tracked-and-what-is-not)
12. [History Routes – Chat History API Deep Dive](#12-history-routes--chat-history-api-deep-dive)

---

## 1. Solution Overview

The **Conversation Knowledge Mining (CKM) Solution Accelerator** is a pre-built, end-to-end Azure solution that:

- Ingests raw **call transcripts** (JSON) and/or **audio files** from Azure Data Lake Storage Gen2
- Enriches them using **Azure AI Content Understanding** (CU) to extract sentiment, topics, summaries, key phrases, complaints
- Generates **vector embeddings** using Azure OpenAI (`text-embedding-3-small`) and indexes them into **Azure AI Search**
- Stores structured analytical data in **Azure SQL Database**
- Provides a **conversational AI interface** backed by Azure AI Foundry agents that can query both SQL (structured) and AI Search (unstructured)
- Persists **chat history** in **Azure Cosmos DB**
- Surfaces everything through a **React front-end** hosted on Azure App Service

**Two industry use cases ship out-of-the-box:**
- `telecom` – telecom call center transcripts
- `IT_helpdesk` – IT helpdesk call recordings

---

## 2. Architecture Deep Dive

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         DATA INGESTION PLANE                             │
│                                                                          │
│  Raw Files (JSON/Audio)                                                  │
│       │                                                                  │
│       ▼                                                                  │
│  Azure Data Lake Storage Gen2 (ADLS)                                     │
│  ├── Container: data/                                                    │
│  │   ├── call_transcripts/   ← sample & custom text transcripts         │
│  │   ├── custom_transcripts/ ← custom JSON transcripts                  │
│  │   └── custom_audiodata/   ← custom audio files                       │
│       │                                                                  │
│       ▼                                                                  │
│  Azure AI Content Understanding (CU)                                     │
│  ├── Analyzer: ckm_analyzer_json (text)                                  │
│  └── Analyzer: ckm_analyzer_audio (audio)                               │
│       │                                                                  │
│       ├──► Azure AI Search Index (call_transcripts_index)                │
│       │    └── Vector embeddings (text-embedding-3-small, 1536 dims)     │
│       │                                                                  │
│       └──► Azure SQL Database                                            │
│            ├── Table: processed_data                                     │
│            ├── Table: km_processed_data                                  │
│            └── Table: processed_data_key_phrases                         │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                         QUERY / RUNTIME PLANE                            │
│                                                                          │
│  React Frontend (App Service)                                            │
│       │                                                                  │
│       ▼                                                                  │
│  FastAPI Backend (App Service)                                           │
│  ├── /api/*        ← chat, charts, filters                               │
│  └── /history/*    ← Cosmos DB conversation history                     │
│       │                                                                  │
│       ▼                                                                  │
│  Azure AI Foundry Agent (Orchestrator)                                   │
│  ├── Tool: get_sql_response → Azure SQL Database                        │
│  └── Tool: Azure AI Search → call_transcripts_index                     │
│       │                                                                  │
│       ▼                                                                  │
│  Azure Cosmos DB  ← chat history persistence                             │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Data Ingestion Pipeline – Step by Step

The ingestion pipeline is a **sequential 5-step process** orchestrated by shell scripts. Understanding each step is critical before any customization.

---

### Step 0 – Infrastructure Provisioning (One-Time Setup)

**What happens:**  
Bicep templates deploy all Azure resources (ADLS, SQL, AI Foundry, AI Search, App Service, Cosmos DB, etc.) via `azd up` or `az deployment`.

**Key files:**
- `infra/main.bicep` – master orchestration template; defines all resource modules and wires parameters
- `infra/modules/dependencies.bicep` – Azure OpenAI deployments (GPT-4o-mini, text-embedding-3-small)
- `infra/modules/ai-services.bicep` – AI Foundry Hub, AI Search, Content Understanding
- `infra/modules/web-sites.bicep` – App Service Plan & Web App
- `azure.yaml` – `azd` configuration mapping services to source directories

**Key parameters in `infra/main.bicep` (lines 1–100):**

```bicep
param solutionName string = 'kmgen'  // Prefix for all resources
param location string                 // Primary Azure region
param aiServiceLocation string        // AI Foundry region (separate due to quota)
param usecase string                  // 'telecom' or 'IT_helpdesk'
param gptModelName string = 'gpt-4o-mini'
param embeddingModel string = 'text-embedding-3-small'
```

---

### Step 1 – Upload Raw Data to ADLS (copy_kb_files.sh)

**What happens:**  
Sample transcripts (ZIP files) are extracted and uploaded to ADLS Gen2 under the `data/call_transcripts/` path.

**Script:** `infra/scripts/copy_kb_files.sh`

**Logic (lines 1–80):**
```bash
# Determines ZIP files based on usecase:
if [ "$usecase" = "telecom" ]; then
  zipFileName1="infra/data/telecom/call_transcripts.zip"
  zipFileName2="infra/data/telecom/audio_data.zip"
elif [ "$usecase" = "IT_helpdesk" ]; then
  zipFileName1="infra/data/IT_helpdesk/call_transcripts.zip"
fi

# Uploads extracted files to:
# ADLS container: data/
# Directory: call_transcripts/
az storage fs directory upload \
  --account-name $storageAccountName \
  --file-system $containerName \
  --source call_transcripts \
  --destination call_transcripts \
  --auth-mode login \
  --recursive
```

**ADLS container structure after this step:**
```
data/
└── call_transcripts/
    ├── telecom_call_2024-01-15 10_30_00.json
    ├── telecom_call_2024-01-15 11_00_00.json
    └── ...
```

---

### Step 2 – Create Azure AI Search Index (01_create_search_index.py)

**What happens:**  
Creates (or recreates) the Azure AI Search index `call_transcripts_index` with vector search and semantic search capabilities.

**Script:** `infra/scripts/index_scripts/01_create_search_index.py`

**Index schema (lines 44–80):**
```python
INDEX_NAME = "call_transcripts_index"

fields = [
    SearchField(name="id",          type=SearchFieldDataType.String, key=True),
    SearchField(name="chunk_id",    type=SearchFieldDataType.String),
    SearchField(name="content",     type=SearchFieldDataType.String),
    SearchField(name="sourceurl",   type=SearchFieldDataType.String),
    SearchField(
        name="contentVector",
        type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
        vector_search_dimensions=1536,          # text-embedding-3-small dimensions
        vector_search_profile_name="myHnswProfile"
    )
]
```

**Vector search uses HNSW algorithm + Azure OpenAI vectorizer** – at query time, the index auto-vectorizes the query using the same embedding model, so no client-side embedding is needed for search queries.

---

### Step 3 – Create Content Understanding Analyzer (02_create_cu_template_text.py)

**What happens:**  
Registers a custom AI Content Understanding analyzer named `ckm_analyzer_json` that defines exactly what fields to extract from each transcript.

**Script:** `infra/scripts/index_scripts/02_create_cu_template_text.py`

**Analyzer definition file:** `infra/data/ckm_analyzer_config_json.json`

```json
{
  "baseAnalyzerId": "prebuilt-document",
  "fieldSchema": {
    "fields": {
      "content":    { "type": "string", "method": "generate",  "description": "Full text of the conversation" },
      "summary":    { "type": "string", "method": "generate",  "description": "Summarize the conversation" },
      "satisfied":  { "type": "string", "method": "classify",  "enum": ["Yes", "No"] },
      "sentiment":  { "type": "string", "method": "classify",  "enum": ["Positive", "Neutral", "Negative"] },
      "topic":      { "type": "string", "method": "generate",  "description": "Primary topic in 6 words or less" },
      "keyPhrases": { "type": "string", "method": "generate",  "description": "Top 10 key phrases" },
      "complaint":  { "type": "string", "method": "generate",  "description": "Primary complaint in 3 words" }
    }
  }
}
```

> **Important:** This analyzer config is what drives all the AI enrichment. If you add a new field (e.g., `language`, `agent_id`, `call_duration`), you modify this JSON file and recreate the analyzer.

---

### Step 4 – Process Transcripts: Enrich + Index + Store (03_cu_process_data_text.py)

This is the **core ingestion script**. It ties everything together.

**Script:** `infra/scripts/index_scripts/03_cu_process_data_text.py`

**High-level flow:**

```
ADLS (call_transcripts/) → CU Analyzer → Extracted Fields
                                         ├──► SQL: processed_data table
                                         ├──► SQL: processed_data_key_phrases table
                                         └──► Chunking → Embeddings → AI Search Index
```

**Detailed walkthrough:**

#### 4a. Connect to ADLS Gen2 (lines 82–92)
```python
account_url = f"https://{STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
credential = AzureCliCredential(process_timeout=30)
service_client = DataLakeServiceClient(account_url, credential=credential, api_version='2023-01-03')
file_system_client = service_client.get_file_system_client("data")          # container name
directory_name = 'call_transcripts'
paths = list(file_system_client.get_paths(path=directory_name))             # list all files
```

**This is the key extension point for new blob sources** – `paths` is a list of `PathProperties` objects. Changing where files are listed from is where you hook in a new source.

#### 4b. Create SQL Tables (lines ~295–315)
```python
def create_tables():
    cursor.execute('DROP TABLE IF EXISTS processed_data')
    cursor.execute("""CREATE TABLE processed_data (
        ConversationId varchar(255) NOT NULL PRIMARY KEY,
        EndTime varchar(255),  StartTime varchar(255),
        Content varchar(max),  summary varchar(3000),
        satisfied varchar(255), sentiment varchar(255),
        topic varchar(255),    key_phrases nvarchar(max),
        complaint varchar(255), mined_topic varchar(255)
    );""")
    cursor.execute('DROP TABLE IF EXISTS processed_data_key_phrases ...')
```

> **Note:** `create_tables()` is called at script startup and drops + recreates the tables every run (full refresh). If you need incremental ingestion, this function must be modified to check for existing records.

#### 4c. Per-File Processing Loop (lines ~325–450)
```python
async def process_files():
    for path in paths:
        # 1. Download file from ADLS
        file_client = file_system_client.get_file_client(path.name)
        data = file_client.download_file().readall()

        # 2. Send to Content Understanding analyzer
        response = cu_client.begin_analyze(ANALYZER_ID, file_location="", file_data=data)
        result = cu_client.poll_result(response)

        # 3. Extract enriched fields from CU result
        fields = result['result']['contents'][0]['fields']
        content    = get_field_value(fields, 'content')
        summary    = get_field_value(fields, 'summary')
        satisfied  = get_field_value(fields, 'satisfied')
        sentiment  = get_field_value(fields, 'sentiment')
        topic      = get_field_value(fields, 'topic')
        key_phrases= get_field_value(fields, 'keyPhrases')
        complaint  = get_field_value(fields, 'complaint')

        # 4. Chunk content + generate embeddings → push to AI Search
        search_docs = await prepare_search_doc(content, conversation_id, path.name, embeddings_client)
        search_client.upload_documents(documents=search_docs)

        # 5. Batch insert into SQL
        processed_records.append({...})
    
    generate_sql_insert_script(df, 'processed_data', columns, 'insert_processed_data.sql')
```

#### 4d. Chunking & Embedding Logic – Deep Dive

**File:** `infra/scripts/index_scripts/03_cu_process_data_text.py`

This is the sub-pipeline that converts raw transcript text into what actually lives in Azure AI Search. It runs inside `process_files()` for every transcript and has three sequential stages.

---

##### Stage 1 – Text Cleaning (lines ~225–232)

Before chunking, the full transcript text is normalised to remove noise that would waste tokens:

```python
def clean_spaces_with_regex(text):
    cleaned_text = re.sub(r'\s+', ' ', text)    # collapse multiple spaces/newlines → single space
    cleaned_text = re.sub(r'\.{2,}', '.', cleaned_text)  # "......" → "."
    return cleaned_text
```

This runs at the top of `chunk_data()` on every piece of content before splitting.

---

##### Stage 2 – Chunking (lines ~235–260)

```python
def chunk_data(text, tokens_per_chunk=1024):
    text = clean_spaces_with_regex(text)
    sentences = text.split('. ')          # split on sentence boundary
    chunks, current_chunk, current_count = [], '', 0

    for sentence in sentences:
        tokens = sentence.split()         # whitespace-based token count (approximation)
        if current_count + len(tokens) <= tokens_per_chunk:
            current_chunk += ('. ' if current_chunk else '') + sentence
            current_count += len(tokens)
        else:
            chunks.append(current_chunk)  # flush current chunk
            current_chunk = sentence
            current_count = len(tokens)

    if current_chunk:
        chunks.append(current_chunk)      # flush final chunk
    return chunks
```

**Key design decisions to understand:**

| Decision | What it means | Implication |
|---|---|---|
| Split on `'. '` (period + space) | Sentence-level boundary | A sentence is never split mid-way; chunks are semantically coherent |
| `tokens_per_chunk=1024` | Hard-coded constant | `text-embedding-3-small` supports up to 8191 tokens; 1024 is conservative to keep chunks focused. Change this constant to tune recall vs. precision in search |
| Token count = `len(sentence.split())` | Whitespace split, NOT a tokenizer | This is an approximation — one "word" ≠ one OpenAI token. Actual token consumption may be ~20–30% higher for languages with subword tokenisation. For CJK text this would undercount significantly |
| No chunk overlap | Adjacent chunks share no text | Pros: no duplicate embeddings, smaller index. Cons: a concept that spans a sentence boundary across two chunks may be missed by either |

**Example — a 3000-word transcript would produce ~3 chunks:**
```
Chunk 1: abc123_01  (words 1–1024)
Chunk 2: abc123_02  (words 1025–2048)
Chunk 3: abc123_03  (words 2049–3000)
```

---

##### Stage 3 – Embedding Generation & Search Document Assembly (lines ~263–285)

```python
async def prepare_search_doc(content, document_id, path_name, embeddings_client):
    chunks = chunk_data(content)
    docs = []
    for idx, chunk in enumerate(chunks, 1):
        chunk_id = f"{document_id}_{str(idx).zfill(2)}"   # e.g. "abc123_01"

        try:
            v_contentVector = await get_embeddings_async(chunk, embeddings_client)
        except Exception:
            await asyncio.sleep(30)   # one retry after 30s (rate-limit backoff)
            try:
                v_contentVector = await get_embeddings_async(chunk, embeddings_client)
            except Exception:
                v_contentVector = []  # empty vector — chunk still indexed but won't surface in vector search

        docs.append({
            "id":            chunk_id,
            "chunk_id":      chunk_id,
            "content":       chunk,
            "sourceurl":     path_name.split('/')[-1],  # filename only, no full path
            "contentVector": v_contentVector             # 1536-float array
        })
    return docs
```

**`get_embeddings_async` (lines ~215–222):**
```python
async def get_embeddings_async(text: str, embeddings_client):
    resp = await embeddings_client.embeddings.create(
        model=EMBEDDING_MODEL,   # "text-embedding-3-small"
        input=text
    )
    return resp.data[0].embedding   # list of 1536 floats
```

**Embeddings client setup (lines ~207–213) — note the endpoint derivation:**
```python
# Embeddings are called via the AI Foundry endpoint, NOT a standalone OpenAI endpoint
embeddings_base_url = f"https://{urlparse(AI_PROJECT_ENDPOINT).netloc}/openai/v1/"

embeddings_client = AsyncOpenAI(
    base_url=embeddings_base_url,
    api_key=embeddings_token_provider(),   # Bearer token from AzureCliCredential
)
```

> The client is created **once per ingestion run** (not per file) and reused across all files for connection efficiency. It is explicitly closed at the end via `await embeddings_client.close()`.

---

##### Stage 4 – Batch Upload to Azure AI Search (inside `process_files()`)

Docs are not pushed to AI Search one file at a time. They are batched every 10 files:

```python
docs.extend(await prepare_search_doc(...))
counter += 1

if docs != [] and counter % 10 == 0:   # flush every 10 files
    search_client.upload_documents(documents=docs)
    docs = []

# Final flush after loop ends
if docs:
    search_client.upload_documents(documents=docs)
```

**Why batch every 10 files?** Each `upload_documents` call is an HTTP request to AI Search. Batching reduces round-trips and stays within the AI Search [batch size limit of 1000 documents per request](https://learn.microsoft.com/azure/search/search-howto-indexing-azure-blob-storage). For large transcripts with many chunks, 10 files could still produce hundreds of documents per batch.

---

##### End-to-End Flow for One Transcript

```
Raw transcript JSON (e.g., 2000 words)
        │
        ▼
  clean_spaces_with_regex()
        │ removes noise
        ▼
  chunk_data(tokens_per_chunk=1024)
        │ produces 2 chunks
        ▼
  for each chunk:
    get_embeddings_async()  ──► AsyncOpenAI → AI Foundry → text-embedding-3-small
        │ returns [1536 floats]
        ▼
    build doc: { id, chunk_id, content, sourceurl, contentVector }
        │
        ▼
  accumulated in docs[]
        │ (every 10 files)
        ▼
  search_client.upload_documents()  ──► Azure AI Search: call_transcripts_index
```

---

##### What to Change for Common Extension Scenarios

| Scenario | What to modify |
|---|---|
| Increase chunk size for longer context models | Change `tokens_per_chunk=1024` constant in `chunk_data()` |
| Add chunk overlap (sliding window) | Rewrite `chunk_data()` to carry the last N sentences into the next chunk |
| Use a proper tokenizer instead of whitespace split | Replace `len(sentence.split())` with `len(tiktoken.encode(sentence))` using `tiktoken` |
| Add more metadata fields to each search document | Add keys to the `docs.append({...})` dict in `prepare_search_doc()` AND add matching `SearchField` entries in `01_create_search_index.py` |
| Switch embedding model | Change `EMBEDDING_MODEL` arg and update `vector_search_dimensions` in `01_create_search_index.py` to match the new model's output size |
| Handle embedding failures more gracefully | Replace the `v_contentVector = []` fallback with a skip + error log to `ingestion_log` table |

---

### Step 5 – Create AI Foundry Agents (01_create_agents.py)

**What happens:**  
Creates two AI Foundry agents with pre-configured tools and instructions:

1. **Conversation Agent** (`KM-ConversationAgent-{solutionName}`) – The main chat agent that can query both SQL and AI Search
2. **Title Agent** (`KM-TitleAgent-{solutionName}`) – Generates conversation titles
3. **TopicMining Agent** (`KM-TopicMiningAgent-{solutionName}`) – Mines topics from transcripts  
4. **TopicMapping Agent** (`KM-TopicMappingAgent-{solutionName}`) – Maps topics to canonical categories

**Script:** `infra/scripts/agent_scripts/01_create_agents.py`

The Conversation Agent system prompt defines SQL tables it can query (lines 15–70 of `01_create_agents.py`):

```python
conversation_agent_instruction = '''
    Tool Priority:
    - Always use the SQL tool first for quantified queries.
      - Tables available:
        1. km_processed_data:    ConversationId, EndTime, StartTime, Content, summary, satisfied, sentiment, topic, keyphrases, complaint
        2. processed_data_key_phrases: ConversationId, key_phrase, sentiment
    - Use Azure AI Search for summaries and transcript insights.
    - ALWAYS include citation markers from search results.
'''
```

**Key insight:** The agent is wired to Azure AI Search via a connection registered in AI Foundry. The connection name is passed as `--azure_ai_search_connection_name`.

---

### Step 6 – Runtime: Backend API & Chat Flow

**Entry point:** `src/api/app.py`

**API routes:**
- `GET  /api/fetchChartData` – fetches dashboard KPIs from SQL
- `POST /api/fetchChartDataWithFilters` – filtered KPI queries
- `GET  /api/fetchFilterData` – filter dropdown values from SQL
- `POST /api/conversation` – main chat endpoint (streaming)
- `GET  /history/list` – Cosmos DB conversation list
- `POST /history/read` – retrieve conversation messages

**Chat flow (`src/api/services/chat_service.py`):**
```
User Message
    │
    ▼
ChatService.chat()
    │
    ├── Retrieve/create thread from TTLCache (1-hour expiry)
    │
    ├── FoundryAgent.run(user_message)
    │       │
    │       ├── Tool call: get_sql_response(sql_query) → SQLTool → Azure SQL
    │       └── Tool call: Azure AI Search → call_transcripts_index
    │
    └── Stream response back to frontend
```

**CosmosDB history (`src/api/services/history_service.py`):**  
Chat history is **optional** (controlled by `USE_CHAT_HISTORY_ENABLED=true` env var).  
`CosmosConversationClient` in `src/api/common/database/cosmosdb_service.py` manages all CRUD for conversations and messages.

---

## 4. Code Reference Map

| Concern | File | Key Lines |
|---|---|---|
| ADLS connection | `infra/scripts/index_scripts/03_cu_process_data_text.py` | 82–92 |
| File listing from ADLS | `infra/scripts/index_scripts/03_cu_process_data_text.py` | 88–89 |
| CU analyzer registration | `infra/scripts/index_scripts/02_create_cu_template_text.py` | 30–50 |
| CU analyzer config (field schema) | `infra/data/ckm_analyzer_config_json.json` | entire file |
| Audio analyzer config | `infra/data/ckm_analyzer_config_audio.json` | entire file |
| AI Search index schema | `infra/scripts/index_scripts/01_create_search_index.py` | 44–100 |
| Chunking logic | `infra/scripts/index_scripts/03_cu_process_data_text.py` | ~235–260 |
| Embedding generation | `infra/scripts/index_scripts/03_cu_process_data_text.py` | ~215–233 |
| SQL table creation | `infra/scripts/index_scripts/03_cu_process_data_text.py` | ~295–315 |
| SQL batch insert helper | `infra/scripts/index_scripts/03_cu_process_data_text.py` | ~120–200 |
| Custom data ingestion | `infra/scripts/index_scripts/04_cu_process_custom_data.py` | entire file |
| App configuration (env vars) | `src/api/common/config/config.py` | 1–45 |
| SQL runtime service | `src/api/common/database/sqldb_service.py` | entire file |
| Cosmos DB service | `src/api/common/database/cosmosdb_service.py` | entire file |
| Chat service / agent orchestration | `src/api/services/chat_service.py` | 1–120 |
| History service | `src/api/services/history_service.py` | 1–80 |
| API routes | `src/api/api/api_routes.py` | entire file |
| Agent creation script | `infra/scripts/agent_scripts/01_create_agents.py` | entire file |
| Infra: main template | `infra/main.bicep` | 1–100 |
| Data upload script | `infra/scripts/copy_kb_files.sh` | entire file |
| Sample data ingestion orchestrator | `infra/scripts/process_sample_data.sh` | entire file |
| Custom data ingestion orchestrator | `infra/scripts/process_custom_data.sh` | entire file |

---

## 5. Extending the Solution – Add a New Blob Storage Source

**Scenario:** The customer has a new blob storage container (e.g., from a different call center system, a new region, or a third-party upload) and wants those transcripts to be ingested into the same CKM pipeline.

### Prerequisites
- The new blob container must be in **Azure Data Lake Storage Gen2** format (hierarchical namespace enabled), OR you convert a flat Blob Storage account to ADLS Gen2. The ingestion scripts use the `DataLakeServiceClient` API.
- Files must be in the **same JSON format** as the existing transcripts, OR you update the CU analyzer config to handle the new format.

---

## Extending the Solution – Add a New ADLS Source
Step-wise guide to help you add a new ADLS data source 

#### Step A – Identify the New Storage Account & Container

```bash
# Example: new storage account
NEW_STORAGE_ACCOUNT="newcallrecordings"
NEW_CONTAINER="call-data"
NEW_DIRECTORY="transcripts"
```

#### Step B – Assign RBAC Roles

The pipeline uses `AzureCliCredential`. Grant the executing identity (your user or service principal) the required roles on the **new** storage account:

```bash
# Get current user's object ID
USER_ID=$(az ad signed-in-user show --query id -o tsv)

# Storage Blob Data Reader – read files
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee $USER_ID \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/$NEW_STORAGE_ACCOUNT"

# Storage File Data SMB Share Reader (if using file shares)
az role assignment create \
  --role "Storage File Data Privileged Reader" \
  --assignee $USER_ID \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/$NEW_STORAGE_ACCOUNT"
```

Also ensure the **backend managed identity** (`backendUserMid`) has these roles if the ingestion runs as an automated service.

#### Step C – Update the Ingestion Script to Read from the New Source

Open `infra/scripts/index_scripts/03_cu_process_data_text.py`.

**Current code (lines 82–89):**
```python
account_url = f"https://{STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
credential = AzureCliCredential(process_timeout=30)
service_client = DataLakeServiceClient(account_url, credential=credential, api_version='2023-01-03')
file_system_client = service_client.get_file_system_client(FILE_SYSTEM_CLIENT_NAME)  # "data"
directory_name = DIRECTORY  # 'call_transcripts'
paths = list(file_system_client.get_paths(path=directory_name))
```

**Option 1: Add second source to existing script (recommended for same SQL/Search target)**

```python
# Original source
account_url = f"https://{STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
credential = AzureCliCredential(process_timeout=30)
service_client = DataLakeServiceClient(account_url, credential=credential, api_version='2023-01-03')
file_system_client = service_client.get_file_system_client("data")
paths_original = list(file_system_client.get_paths(path='call_transcripts'))

# NEW: second storage account source
NEW_STORAGE_ACCOUNT_NAME = os.environ.get("NEW_STORAGE_ACCOUNT_NAME", "")
new_account_url = f"https://{NEW_STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
new_service_client = DataLakeServiceClient(new_account_url, credential=credential, api_version='2023-01-03')
new_file_system_client = new_service_client.get_file_system_client("call-data")
paths_new = list(new_file_system_client.get_paths(path='transcripts'))

# Merge both path lists
paths = paths_original + paths_new
```

> The rest of the processing loop (`process_files()`) iterates over `paths` unchanged. Each path object has a `.name` attribute used to download the file. Ensure both `file_system_client` and `new_file_system_client` are accessible inside the loop.

**Option 2: Create a separate ingestion script for the new source**

Copy `04_cu_process_custom_data.py` (the template for custom data) and change:
```python
# In your new script (e.g., 05_process_new_source.py)
STORAGE_ACCOUNT_NAME = args.new_storage_account_name  # new arg
FILE_SYSTEM_CLIENT_NAME = "call-data"                  # new container
DIRECTORY = 'transcripts'                              # new directory

account_url = f"https://{STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
# ... rest is identical
```

#### Step D – Update the Shell Orchestrator

In `infra/scripts/process_sample_data.sh` (or create a new `process_new_source.sh`), add the call to the new script:

```bash
# After existing index script calls, add:
python3 $pythonScriptPath/05_process_new_source.py \
  --search_endpoint "$search_endpoint" \
  --ai_project_endpoint "$aiAgentEndpoint" \
  --deployment_model "$deploymentModel" \
  --embedding_model "$embeddingModel" \
  --storage_account_name "$newStorageAccountName" \  # <-- NEW
  --sql_server "$sqlServerName.database.windows.net" \
  --sql_database "$sqlDatabaseName" \
  --cu_endpoint "$cuEndpoint" \
  --cu_api_version "$cuApiVersion" \
  --usecase "$usecase" \
  --solution_name "$solutionName"
```

#### Step E – Handle Network Access (VNet / Private Endpoints)

If the new storage account has a private endpoint or VNet integration, you need to:

1. Add the subnet of the ingestion runner (or the App Service) to the storage account's **network allow list**:
```bash
az storage account network-rule add \
  --resource-group <RG> \
  --account-name $NEW_STORAGE_ACCOUNT \
  --subnet <SUBNET_RESOURCE_ID>
```

2. Or temporarily enable public access (mirroring the pattern in `process_sample_data.sh`):
```bash
az storage account update \
  --name $NEW_STORAGE_ACCOUNT \
  --resource-group <RG> \
  --public-network-access Enabled \
  --default-action Allow
```

#### Step F – Update Bicep for Persistent Role Assignments (Optional)

If this new storage account is permanent, add a role assignment in `infra/main.bicep` or `infra/modules/role-assignment.bicep`:

```bicep
resource newStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(newStorageAccount.id, backendManagedIdentity.id, storageBlobDataReaderRoleId)
  scope: newStorageAccount
  properties: {
    principalId: backendManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}
```

---

## 6. Extending the Solution – Add Cosmos DB as a New Data Store

**Two distinct use cases for Cosmos DB in this solution:**

| Use Case | Current State | Extension Scenario |
|---|---|---|
| **Chat History** | Already implemented via `CosmosConversationClient` | Enable / reconfigure an existing feature |
| **Analytical / Processed Data** | Currently in SQL only | New: store processed transcript data in Cosmos DB for flexible querying |

---

### Use Case A – Enable / Reconfigure Chat History (Cosmos DB)

This is already fully coded. The feature is gated by an environment variable.

#### Step A1 – Verify or Provision the Cosmos DB Account

In `infra/main.bicep`, Cosmos DB is provisioned if `USE_CHAT_HISTORY_ENABLED` is true. Verify:

```bash
az cosmosdb show \
  --name <COSMOS_ACCOUNT_NAME> \
  --resource-group <RG> \
  --query "{ endpoint: documentEndpoint, kind: kind }"
```

Required structure:
- **Database:** e.g., `chat_history`
- **Container:** e.g., `conversations` (partition key: `/userId`)

#### Step A2 – Set Environment Variables

In the App Service application settings (or `.env` for local dev):

```bash
USE_CHAT_HISTORY_ENABLED=true
AZURE_COSMOSDB_ACCOUNT=<cosmos-account-name>          # just the name, no URL
AZURE_COSMOSDB_DATABASE=chat_history
AZURE_COSMOSDB_CONVERSATIONS_CONTAINER=conversations
AZURE_COSMOSDB_ENABLE_FEEDBACK=false                  # set true to enable thumbs up/down
```

**Code reference:** `src/api/common/config/config.py` (lines 33–39):
```python
self.use_chat_history_enabled = os.getenv("USE_CHAT_HISTORY_ENABLED", "false").strip().lower() == "true"
self.azure_cosmosdb_database = os.getenv("AZURE_COSMOSDB_DATABASE")
self.azure_cosmosdb_account = os.getenv("AZURE_COSMOSDB_ACCOUNT")
self.azure_cosmosdb_conversations_container = os.getenv("AZURE_COSMOSDB_CONVERSATIONS_CONTAINER")
```

#### Step A3 – Assign RBAC to Backend Managed Identity

```bash
COSMOS_ACCOUNT_ID=$(az cosmosdb show \
  --name <COSMOS_ACCOUNT_NAME> \
  --resource-group <RG> \
  --query id -o tsv)

BACKEND_MID_PRINCIPAL_ID=$(az identity show \
  --name <BACKEND_MANAGED_IDENTITY_NAME> \
  --resource-group <RG> \
  --query principalId -o tsv)

# Cosmos DB Built-in Data Contributor
az cosmosdb sql role assignment create \
  --account-name <COSMOS_ACCOUNT_NAME> \
  --resource-group <RG> \
  --role-definition-id "00000000-0000-0000-0000-000000000002" \
  --principal-id $BACKEND_MID_PRINCIPAL_ID \
  --scope "/"
```

#### Step A4 – How the CosmosDB Client is Initialized

**Code reference:** `src/api/services/history_service.py` (lines 37–55):

```python
def init_cosmosdb_client(self):
    if not self.chat_history_enabled:
        return None  # gracefully skips if disabled

    cosmos_endpoint = f"https://{self.azure_cosmosdb_account}.documents.azure.com:443/"
    return CosmosConversationClient(
        cosmosdb_endpoint=cosmos_endpoint,
        credential=build_async_azure_credential(client_id=self.azure_client_id),
        database_name=self.azure_cosmosdb_database,
        container_name=self.azure_cosmosdb_conversations_container,
        enable_message_feedback=self.azure_cosmosdb_enable_feedback,
    )
```

**Code reference:** `src/api/common/database/cosmosdb_service.py` – full CRUD operations:
- `create_conversation()` – called on first chat message
- `upsert_conversation()` – updates conversation metadata
- `get_conversations(user_id, limit)` – fetches conversation list
- `get_messages(user_id, conversation_id)` – retrieves all messages in a thread
- `create_message()` – appends a message to a conversation

---

### Use Case B – Store Processed Transcript Data in Cosmos DB (New Extension)

**Scenario:** You want enriched transcript data (currently in SQL) to also be available in Cosmos DB for flexible document queries, real-time streaming, or multi-region distribution.

#### Step B1 – Create a New Cosmos DB Container

Via Azure Portal or CLI:
```bash
az cosmosdb sql container create \
  --account-name <COSMOS_ACCOUNT_NAME> \
  --resource-group <RG> \
  --database-name ckm_analytics \
  --name processed_transcripts \
  --partition-key-path "/topic"         # partition by topic for even distribution
  --throughput 400
```

Suggested document schema (mirrors `processed_data` SQL table):
```json
{
  "id": "conversation_id_here",
  "ConversationId": "...",
  "StartTime": "2024-01-15T10:30:00",
  "EndTime":   "2024-01-15T10:45:00",
  "Content":   "Full transcript text...",
  "summary":   "Customer called about billing...",
  "satisfied": "Yes",
  "sentiment": "Positive",
  "topic":     "billing inquiry",
  "keyPhrases": ["billing", "account", "payment"],
  "complaint": "late charge",
  "minedTopic": "financial_dispute",
  "_ts": 1705312200
}
```

#### Step B2 – Create a Cosmos DB Writer Service

Create a new file `infra/scripts/index_scripts/cosmos_writer.py`:

```python
from azure.cosmos import CosmosClient
from azure.identity import AzureCliCredential

COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"]   # https://<account>.documents.azure.com:443/
COSMOS_DATABASE = "ckm_analytics"
COSMOS_CONTAINER = "processed_transcripts"

credential = AzureCliCredential(process_timeout=30)
cosmos_client = CosmosClient(COSMOS_ENDPOINT, credential=credential)
database = cosmos_client.get_database_client(COSMOS_DATABASE)
container = database.get_container_client(COSMOS_CONTAINER)

def upsert_transcript(record: dict):
    """
    Upsert a processed transcript record into Cosmos DB.
    Maps the SQL processed_data schema to a Cosmos DB document.
    """
    document = {
        "id": record["ConversationId"],         # Cosmos DB document ID
        **record                                 # spread all fields
    }
    container.upsert_item(document)
    print(f"Upserted conversation: {record['ConversationId']}")
```

#### Step B3 – Integrate into the Ingestion Loop

In `infra/scripts/index_scripts/03_cu_process_data_text.py`, inside `process_files()`, after building `processed_records`, add a Cosmos DB write:

```python
# Existing SQL insert:
generate_sql_insert_script(df, 'processed_data', columns, 'insert_processed_data.sql')

# NEW: Cosmos DB upsert
from cosmos_writer import upsert_transcript
for record in processed_records:
    upsert_transcript(record)
```

#### Step B4 – Add Cosmos DB as a Runtime Query Tool for the Agent (Optional)

If you want the Foundry agent to query Cosmos DB at runtime (instead of or in addition to SQL), you need to:

1. **Create a new Azure Function** or **custom tool** that wraps Cosmos DB queries
2. **Register the tool** in the agent definition in `infra/scripts/agent_scripts/01_create_agents.py`

Example custom tool addition:
```python
# In 01_create_agents.py, add to the agent's tool list:
from azure.ai.projects.models import FunctionTool

cosmos_tool_def = FunctionTool(
    name="get_cosmos_transcript",
    description="Query processed transcript data from Cosmos DB by topic or time range",
    parameters={
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Cosmos DB SQL API query string"}
        },
        "required": ["query"]
    }
)
```

Then implement the function handler in `src/api/common/database/` and wire it into `chat_service.py`.

#### Step B5 – Update App Configuration

Add Cosmos DB analytics connection to App Service environment variables:

```bash
AZURE_COSMOSDB_ANALYTICS_ACCOUNT=<analytics-cosmos-account>
AZURE_COSMOSDB_ANALYTICS_DATABASE=ckm_analytics
AZURE_COSMOSDB_ANALYTICS_CONTAINER=processed_transcripts
```

Add to `src/api/common/config/config.py`:
```python
# Analytics Cosmos DB (new extension)
self.azure_cosmosdb_analytics_account = os.getenv("AZURE_COSMOSDB_ANALYTICS_ACCOUNT")
self.azure_cosmosdb_analytics_database = os.getenv("AZURE_COSMOSDB_ANALYTICS_DATABASE")
self.azure_cosmosdb_analytics_container = os.getenv("AZURE_COSMOSDB_ANALYTICS_CONTAINER")
```

---

## 7. Configuration Reference

### Environment Variables (Backend App Service)

| Variable | Purpose | Required |
|---|---|---|
| `SQLDB_SERVER` | Azure SQL Server FQDN (e.g., `xyz.database.windows.net`) | Yes |
| `SQLDB_DATABASE` | SQL database name | Yes |
| `SQLDB_USER_MID` | Managed Identity Client ID for SQL auth | Yes |
| `AZURE_AI_SEARCH_ENDPOINT` | Azure AI Search service URL | Yes |
| `AZURE_AI_SEARCH_INDEX` | Index name (default: `call_transcripts_index`) | Yes |
| `AZURE_AI_SEARCH_CONNECTION_NAME` | AI Foundry connection name for Search | Yes |
| `AZURE_AI_AGENT_ENDPOINT` | AI Foundry project endpoint | Yes |
| `AZURE_AI_AGENT_API_VERSION` | API version (default: `2025-05-01`) | No |
| `AGENT_NAME_CONVERSATION` | Conversation agent name | Yes |
| `AGENT_NAME_TITLE` | Title generation agent name | Yes |
| `SOLUTION_NAME` | Solution name suffix for agent naming | Yes |
| `AZURE_CLIENT_ID` | Backend Managed Identity Client ID | Yes |
| `USE_CHAT_HISTORY_ENABLED` | Enable Cosmos DB chat history | No |
| `AZURE_COSMOSDB_ACCOUNT` | Cosmos DB account name | If history enabled |
| `AZURE_COSMOSDB_DATABASE` | Cosmos DB database name | If history enabled |
| `AZURE_COSMOSDB_CONVERSATIONS_CONTAINER` | Cosmos DB container name | If history enabled |
| `APPINSIGHTS_CONNECTION_STRING` | Application Insights telemetry | No |

### Ingestion Script Parameters

**`03_cu_process_data_text.py` / `04_cu_process_custom_data.py`:**

| Parameter | Description |
|---|---|
| `--search_endpoint` | Azure AI Search service URL |
| `--ai_project_endpoint` | AI Foundry project endpoint |
| `--deployment_model` | GPT model deployment name |
| `--embedding_model` | Embedding model name |
| `--storage_account_name` | ADLS Gen2 account name |
| `--sql_server` | SQL server FQDN |
| `--sql_database` | SQL database name |
| `--cu_endpoint` | Content Understanding endpoint |
| `--cu_api_version` | CU API version |
| `--usecase` | `telecom` or `IT_helpdesk` |
| `--solution_name` | Solution name for agent naming |

---

## 8. Security & Identity Model

All Azure service authentication uses **passwordless / Managed Identity** via `azure-identity`. No secrets or keys are stored in code.

### Authentication Credentials Used

| Context | Credential Class | Scope |
|---|---|---|
| Ingestion scripts (local/CI) | `AzureCliCredential` | `az login` session |
| Backend App Service | `ManagedIdentityCredential` (via `AZURE_CLIENT_ID`) | User-Assigned Managed Identity |
| SQL Database | Token-based via `https://database.windows.net/.default` | ODBC `SQL_COPT_SS_ACCESS_TOKEN` |
| ADLS Gen2 | `AzureCliCredential` / Managed Identity | `https://storage.azure.com/.default` |
| AI Foundry / OpenAI | Token via `https://ai.azure.com/.default` | Bearer token |
| Content Understanding | Token via `https://cognitiveservices.azure.com/.default` | Bearer token |
| Cosmos DB | `ManagedIdentityCredential` | Cosmos DB SQL Role |

**Code reference:** `src/api/helpers/azure_credential_utils.py` – `get_azure_credential_async()` and `build_async_azure_credential()` handle both local dev (CLI) and production (Managed Identity) transparently.

### Role Assignments (Minimum Required)

| Identity | Resource | Role |
|---|---|---|
| Backend MI | Azure SQL DB | `db_datareader`, `db_datawriter` (SQL level) |
| Backend MI | Azure AI Search | `Search Index Data Reader` |
| Backend MI | AI Foundry | `Azure AI Developer` |
| Backend MI | Cosmos DB | `Cosmos DB Built-in Data Contributor` |
| Backend MI | ADLS Gen2 | `Storage Blob Data Reader` |
| Ingestion User/SP | ADLS Gen2 | `Storage Blob Data Contributor` |
| Ingestion User/SP | Azure AI Search | `Search Index Data Contributor` |
| Ingestion User/SP | AI Foundry | `Azure AI Developer` |

---

## 9. FAQ & Common Troubleshooting

**Q: Why are transcripts not appearing in the dashboard after ingestion?**  
A: The ingestion scripts `DROP TABLE IF EXISTS` and recreate tables on every run. If the script fails mid-way, the tables may be empty. Check script logs in `infra/scripts/index_scripts/sql_files/` for generated SQL files. Also verify that `adjust_processed_data_dates()` in `src/api/common/database/sqldb_service.py` ran — it adjusts `StartTime`/`EndTime` to be relative to today so dashboard date filters work.

**Q: The agent says "I cannot find any data" for SQL queries, but data exists in the table.**  
A: Check that the agent instruction references the correct table name. After ingestion, data is in `km_processed_data` (not `processed_data` — there's a view/copy step). Verify in the agent's system prompt in `01_create_agents.py`.

**Q: How do I add a new extracted field (e.g., `language`, `agent_name`) to the pipeline?**  
A: 
1. Edit `infra/data/ckm_analyzer_config_json.json` – add the new field to `fieldSchema.fields`
2. Re-run `02_create_cu_template_text.py` to recreate the analyzer
3. Edit `create_tables()` in `03_cu_process_data_text.py` to add the column to `processed_data`
4. Edit `get_field_value(fields, 'newFieldName')` calls in `process_files()` to extract the new field
5. Update the agent's system prompt in `01_create_agents.py` to reflect the new column
6. Re-run the full ingestion pipeline

**Q: Can we run the ingestion incrementally (only new files)?**  
A: Not out of the box. The current design does a full refresh (`DROP TABLE` + recreate). To support incremental ingestion:
- Remove the `create_tables()` call (or guard it with an existence check)
- Track processed files (e.g., using a state file, SQL table, or ADLS metadata)
- Filter `paths` to only include unprocessed files before the loop

**Q: How do I add a new use case beyond `telecom` and `IT_helpdesk`?**  
A:
1. Create a new folder under `infra/data/<new_usecase>/` with sample `call_transcripts.zip`
2. Add the new use case to the `@allowed` list in `infra/main.bicep`
3. Add the conditional path in `03_cu_process_data_text.py` for `SAMPLE_IMPORT_FILE`
4. Add to `copy_kb_files.sh` to handle the new ZIP file name
5. Redeploy/run ingestion with `--usecase new_usecase`

**Q: What if the new blob storage is flat Blob (not ADLS Gen2 hierarchical namespace)?**  
A: The current code uses `DataLakeServiceClient` which requires ADLS Gen2. To use flat Blob Storage, replace with `BlobServiceClient` from `azure-storage-blob`:

```python
# Replace DataLakeServiceClient with BlobServiceClient
from azure.storage.blob import BlobServiceClient

blob_service_client = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
    credential=credential
)
container_client = blob_service_client.get_container_client("call-transcripts")
paths = list(container_client.list_blobs())

# In the loop, download differs:
blob_client = container_client.get_blob_client(blob.name)
data = blob_client.download_blob().readall()
```

**Q: How is the Cosmos DB for chat history different from the Cosmos DB for analytics?**  
A: The existing `CosmosConversationClient` (in `src/api/common/database/cosmosdb_service.py`) is exclusively for chat history – storing `conversation` and `message` documents keyed by `userId`. It is completely separate from the analytical transcript data in SQL. If you add a second Cosmos DB for analytics, treat it as an independent data store with its own client class.

**Q: How does the vector search work at query time?**  
A: The Azure AI Search index is configured with an `AzureOpenAIVectorizer` (see `01_create_search_index.py`, lines 60–80). At query time, the search service automatically calls the OpenAI embedding endpoint to vectorize the user's question, then performs an HNSW approximate nearest-neighbor search against stored `contentVector` embeddings. The agent's `AzureAISearchTool` sends a natural language query; Azure AI Search handles all vectorization internally.

---

*Document generated for KT session on 2026-07-10. Code references are based on the current state of the `main` branch of `microsoft/Conversation-Knowledge-Mining-Solution-Accelerator`.*

---

## 10. Adding a New Blob Source – Full Setup Checklist

> **Anticipated customer question:** "We have another service / call center platform that stores transcripts in its own storage account. What do we need to do to plug that into CKM?"

This section gives the complete, prioritized checklist. Every item below has a blocking dependency on the ones above it.

---

### 10.1 Pre-Flight: Storage Account Type

The ingestion scripts use `azure-storage-file-datalake` (`DataLakeServiceClient`), which requires **ADLS Gen2** (hierarchical namespace enabled). Flat Blob Storage uses a different SDK.

```bash
# Check whether the target account has hierarchical namespace
az storage account show \
  --name <NEW_STORAGE_ACCOUNT> \
  --resource-group <RG> \
  --query "isHnsEnabled"
# Must return: true
```

If it returns `false`, either:
- Enable hierarchical namespace (requires account recreation – data must be migrated), OR
- Switch the ingestion code from `DataLakeServiceClient` to `BlobServiceClient` (see FAQ section).

---

### 10.2 Network Access

The ingestion script runs from either the developer's machine (local `az login`) or a CI/CD runner. The new storage account must be reachable from that network.

| Scenario | Action |
|---|---|
| New storage has public network access enabled | Nothing extra needed |
| New storage has selected virtual networks only | Add the ingestion runner's IP or subnet to the storage firewall allow-list |
| New storage has private endpoint only | Ingestion must run from within the same VNet, or a peered VNet with DNS resolution |
| New storage has no public access and no private endpoint configured | Provision a private endpoint in the same VNet as the solution |

**Temporary enable for one-off ingestion runs** (mirrors the pattern in `infra/scripts/process_sample_data.sh`):
```bash
az storage account update \
  --name <NEW_STORAGE_ACCOUNT> \
  --resource-group <RG> \
  --public-network-access Enabled \
  --default-action Allow
# ... run ingestion ...
# Restore afterward
az storage account update \
  --name <NEW_STORAGE_ACCOUNT> \
  --resource-group <RG> \
  --public-network-access Disabled
```

---

### 10.3 RBAC – Ingestion Identity (who runs the script)

Grant the identity that runs the script access to the **new** storage account. This is the currently signed-in user for local runs, or the service principal / managed identity for CI/CD.

```bash
# Ingestion-time identity (user running az login)
IDENTITY_ID=$(az ad signed-in-user show --query id -o tsv)

# Required: read blob content
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee $IDENTITY_ID \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/<NEW_STORAGE_ACCOUNT>"
```

> The existing `run_create_index_scripts.sh` already handles RBAC assignment for the primary storage account (look for `Foundry User role assignment` and `SQL role assignment` sections). Apply the same pattern for the new account.

---

### 10.4 RBAC – Backend Managed Identity (runtime, optional)

The **App Service backend** does not directly read from ADLS at runtime – it reads from SQL and AI Search. However if you plan to serve raw transcript files or implement streaming download from the new storage at runtime, grant the backend managed identity read access too:

```bash
BACKEND_MID_PRINCIPAL_ID=$(az identity show \
  --name <BACKEND_MANAGED_IDENTITY_NAME> \
  --resource-group <RG> \
  --query principalId -o tsv)

az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee $BACKEND_MID_PRINCIPAL_ID \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/<NEW_STORAGE_ACCOUNT>"
```

---

### 10.5 File Format Verification

The CU analyzer `ckm_analyzer_json` was trained on a specific JSON transcript schema. Open a sample file from the new source and confirm it matches:

**Expected format** (used by `telecom` use case):
```json
{
  "conversationId": "abc123",
  "startTime": "2024-01-15T10:30:00",
  "transcript": [
    { "speaker": "Agent",    "text": "Thank you for calling..." },
    { "speaker": "Customer", "text": "I have a billing issue..." }
  ]
}
```

If the format differs:
1. Edit `infra/data/ckm_analyzer_config_json.json` to adjust field extraction instructions
2. Re-run `02_create_cu_template_text.py` to recreate the analyzer before ingesting the new source

---

### 10.6 Code Change – Hook the New Source into the Ingestion Script

**File to edit:** `infra/scripts/index_scripts/03_cu_process_data_text.py` (lines 82–89)

**Recommended pattern** – add a second `DataLakeServiceClient` and merge the path lists:

```python
# --- Existing primary source ---
credential = AzureCliCredential(process_timeout=30)
account_url = f"https://{STORAGE_ACCOUNT_NAME}.dfs.core.windows.net"
service_client = DataLakeServiceClient(account_url, credential=credential, api_version='2023-01-03')
file_system_client = service_client.get_file_system_client("data")
paths_primary = list(file_system_client.get_paths(path='call_transcripts'))

# --- NEW secondary source ---
NEW_ACCOUNT = os.environ["NEW_STORAGE_ACCOUNT_NAME"]
new_account_url = f"https://{NEW_ACCOUNT}.dfs.core.windows.net"
new_svc = DataLakeServiceClient(new_account_url, credential=credential, api_version='2023-01-03')
new_fs = new_svc.get_file_system_client("<new-container-name>")
paths_secondary = list(new_fs.get_paths(path='<new-directory-name>'))

# Merge – the processing loop works on this combined list unchanged
paths = paths_primary + paths_secondary
```

**Important:** The download call inside `process_files()` uses `file_system_client`:
```python
file_client = file_system_client.get_file_client(path.name)  # ← uses primary client
```

You need to carry the correct client alongside each path. The cleanest way is to store tuples:
```python
paths = [(file_system_client, p) for p in paths_primary] + \
        [(new_fs, p)             for p in paths_secondary]

# In the loop:
for fs_client, path in paths:
    file_client = fs_client.get_file_client(path.name)
    data = file_client.download_file().readall()
    ...
```

---

### 10.7 ConversationId Derivation (Critical)

The current code derives `ConversationId` from the **filename**:

```python
# From 03_cu_process_data_text.py, inside process_files()
file_name = path.name.split('/')[-1].replace("%3A", "_")
conversation_id = file_name.split('convo_', 1)[1].split('_')[0]
```

If the new source uses a different filename convention, this logic will fail silently (the `except` block skips the file). Verify your new files match the naming pattern, or add a conditional branch:

```python
try:
    conversation_id = file_name.split('convo_', 1)[1].split('_')[0]
except IndexError:
    # Fallback for new source with different naming: use full stem as ID
    conversation_id = file_name.replace(".json", "").replace(".txt", "")
```

---

### 10.8 SQL Schema – No Changes Required (with caveat)

The SQL tables (`processed_data`, `km_processed_data`, `processed_data_key_phrases`) do not need changes to accept records from the new source. `ConversationId` is the primary key, so as long as IDs are unique across both sources, records will coexist in the same tables.

**Caveat – source tracking:** There is currently **no column to record which storage account a transcript came from**. If you need to filter by source system later, add a `source_account` column:

```sql
ALTER TABLE processed_data ADD source_account varchar(100);
ALTER TABLE km_processed_data ADD source_account varchar(100);
```

And populate it in the ingestion script:
```python
processed_records.append({
    ...,
    'source_account': NEW_ACCOUNT   # tag which storage account it came from
})
```

---

### 10.9 AI Search Index – No Changes Required (with caveat)

Same as SQL: the index accepts documents from any source, and `id` (chunk_id) uniqueness ensures no collisions as long as `ConversationId` values are unique across sources.

**Caveat – `sourceurl` field:** Currently `sourceurl` stores **only the filename** (`path.name.split('/')[-1]`), not the full ADLS path or account name. Agent citations will show just the filename, with no indication of which system it came from. To fix, update `prepare_search_doc()`:

```python
# Current (03_cu_process_data_text.py, ~line 284):
"sourceurl": path_name.split('/')[-1],

# Extended: include storage account prefix for traceability
"sourceurl": f"{STORAGE_ACCOUNT_NAME}/{path_name.split('/')[-1]}",
```

This requires no index schema change since `sourceurl` is already a `String` field.

---

### 10.10 Shell Orchestrator – Update or Create a New Script

**Option A – extend the existing orchestrator** (`infra/scripts/process_sample_data.sh`):  
Pass the new storage account name as an additional argument and thread it through to the Python script.

**Option B – create a dedicated script** for the new source (cleaner for separate scheduling):  
Copy `infra/scripts/process_custom_data.sh` and change the `storageAccountName` parameter and any path references.

---

### 10.11 Infrastructure (Bicep) – Persistent Role Assignment

For production environments where the new storage account is permanent and managed by the same Bicep deployment, add the role assignment in `infra/modules/role-assignment.bicep`:

```bicep
param newStorageAccountId string  // resource ID of the new storage account
param backendManagedIdentityPrincipalId string

var storageBlobDataReaderRoleId = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource newStorageBlobReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(newStorageAccountId, backendManagedIdentityPrincipalId, 'StorageBlobDataReader')
  scope: resourceId('Microsoft.Storage/storageAccounts', split(newStorageAccountId, '/')[8])
  properties: {
    principalId: backendManagedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}
```

---

### 10.12 Complete Checklist Summary

```
[ ] 1. Confirm storage account has ADLS Gen2 hierarchical namespace enabled
[ ] 2. Open network access from the ingestion runner to the new account
[ ] 3. Assign "Storage Blob Data Reader" to the ingestion identity
[ ] 4. Assign "Storage Blob Data Reader" to the backend managed identity (if runtime access needed)
[ ] 5. Verify file format matches the CU analyzer schema (or update the analyzer)
[ ] 6. Edit 03_cu_process_data_text.py to add second DataLakeServiceClient + merge paths
[ ] 7. Fix ConversationId derivation if filename convention differs
[ ] 8. Add source_account column to SQL tables if source tracking is needed
[ ] 9. Optionally update sourceurl in AI Search for citation traceability
[ ] 10. Update or create shell orchestrator script
[ ] 11. Add Bicep role assignment for permanent infrastructure
[ ] 12. Re-run full ingestion pipeline and verify record counts in SQL + AI Search
```

---

## 11. RAG Pipeline Metadata – What Is Tracked and What Is Not

> **Anticipated customer question:** "Do you maintain any metadata for the RAG pipeline? Things like which file was processed, when it was processed, how many chunks were created?"

Understanding what metadata exists (and what doesn't) is critical before building on top of this solution. This section maps exactly what is stored, where, and what gaps exist.

---

### 11.1 What IS Stored – Azure AI Search Index

**Index name:** `call_transcripts_index`  
**Schema** (defined in `infra/scripts/index_scripts/01_create_search_index.py`, lines 44–80):

| Field | Type | Content | Notes |
|---|---|---|---|
| `id` | String (key) | `{ConversationId}_{chunkNumber}` e.g. `abc123_01` | Unique per chunk |
| `chunk_id` | String | Same as `id` | Redundant; used by semantic config |
| `content` | String | Raw text of the chunk (~1024 tokens) | The searchable content |
| `sourceurl` | String | **Filename only**, e.g. `telecom_call_2024-01-15.json` | No path, no account name |
| `contentVector` | Float32[] | 1536-dimension embedding | Used for vector/hybrid search |

**What is NOT in the index:**
- Full ADLS path or storage account name
- Ingestion timestamp (when this chunk was indexed)
- Total chunk count for the parent document
- Processing status (success/fail/retry)
- Source system identifier
- Raw file size or byte offset
- CU analyzer version used

---

### 11.2 What IS Stored – Azure SQL Database

**Table: `processed_data`** (staging table, full transcript scope)

| Column | Type | Content |
|---|---|---|
| `ConversationId` | varchar(255) PK | Derived from filename; unique per transcript |
| `StartTime` | varchar(255) | Timestamp parsed from filename |
| `EndTime` | varchar(255) | `StartTime + Duration` (from CU) |
| `Content` | varchar(max) | Full transcript text |
| `summary` | varchar(3000) | AI-generated summary (from CU) |
| `satisfied` | varchar(255) | `Yes` / `No` (from CU classifier) |
| `sentiment` | varchar(255) | `Positive` / `Neutral` / `Negative` (from CU) |
| `topic` | varchar(255) | Raw topic from CU (6 words or less) |
| `key_phrases` | nvarchar(max) | Comma-separated key phrases from CU |
| `complaint` | varchar(255) | Primary complaint from CU (3 words) |
| `mined_topic` | varchar(255) | Canonical topic after TopicMining agent mapping |

**Table: `km_processed_data`** (the table the Conversation Agent actually queries):  
A copy of `processed_data` with `mined_topic` promoted to `topic` and `key_phrases` renamed to `keyphrases`. Created at the end of the ingestion run.

**Table: `processed_data_key_phrases`** (key phrases exploded to rows):

| Column | Content |
|---|---|
| `ConversationId` | Links back to `processed_data` |
| `key_phrase` | Individual key phrase |
| `sentiment` | Sentiment of the parent conversation |
| `topic` | Mined topic of the parent conversation |
| `StartTime` | From parent conversation |

**Table: `km_mined_topics`** (canonical topic registry):

| Column | Content |
|---|---|
| `label` | Topic label (e.g., "billing inquiry") |
| `description` | AI-generated description of the topic |

---

### 11.3 What IS Stored – Azure Cosmos DB (Chat History only)

Cosmos DB in this solution is **exclusively used for the chat UI session history**. It has no relationship to the RAG pipeline or transcript data.

| Document Type | Key Fields |
|---|---|
| `conversation` | `id`, `userId`, `title`, `createdAt`, `updatedAt` |
| `message` | `id`, `conversationId`, `role`, `content`, `createdAt`, `feedback` |

Defined in `src/api/common/database/cosmosdb_service.py`.

---

### 11.4 What Is NOT Tracked – The Critical Gaps

These gaps directly impact operability and extensibility decisions:

| Missing Metadata | Impact | How to Add |
|---|---|---|
| **Ingestion tracking table** – no record of which files have been processed | Every run is a full rebuild; incremental ingestion is impossible without custom tracking | Create a SQL table `ingestion_log (file_path, storage_account, processed_at, status, chunk_count, error_msg)` and write to it inside `process_files()` |
| **Ingestion timestamp** – no record of when a file was processed | Cannot answer "when was this data last refreshed?" | Add `ingested_at datetime` column to `processed_data` and `km_processed_data` |
| **Chunk count per transcript** – not stored anywhere | Cannot verify completeness; a truncated ingestion produces no warning | Count `docs` per conversation during `prepare_search_doc()` and store in the ingestion log |
| **Source system identifier** – `sourceurl` in AI Search stores filename only | Cannot filter search results by source; citations show filename with no system context | Add `source_account` field to the AI Search index and populate it during ingestion |
| **CU analyzer version** – not recorded | If the analyzer is updated and re-ingested, you cannot tell which records used which version | Add `analyzer_version` column to `processed_data` |
| **Processing error log** – failed files are silently skipped | `except: pass` in the loop (line ~380 of `03_cu_process_data_text.py`) means no visibility into failures | Replace bare `except` with structured error capture into the ingestion log table |
| **Deduplication check** – no guard against reprocessing the same file | In AI Search, the `upsert` by `id` prevents duplicates. In SQL, the `ConversationId` primary key blocks duplicate rows. But if a file is renamed, it gets a new `ConversationId` and creates a second record | Add a content hash to the ingestion log and skip files whose hash already exists |

---

### 11.5 Recommended Metadata Extension for Production

If the customer needs a production-grade pipeline, the minimal addition is an **ingestion log table**. Add this to `03_cu_process_data_text.py`:

**SQL table (add to `create_tables()` or a separate setup script):**
```sql
CREATE TABLE IF NOT EXISTS ingestion_log (
    id              INT IDENTITY(1,1) PRIMARY KEY,
    file_path       NVARCHAR(1000),          -- full ADLS path
    storage_account VARCHAR(100),            -- source storage account name
    conversation_id VARCHAR(255),            -- derived ConversationId
    processed_at    DATETIME2 DEFAULT GETUTCDATE(),
    status          VARCHAR(20),             -- 'success' | 'failed' | 'skipped'
    chunk_count     INT,
    error_message   NVARCHAR(MAX)
);
```

**Write to it inside `process_files()` in `03_cu_process_data_text.py`:**
```python
for path in paths:
    try:
        # ... existing processing logic ...
        chunk_count = len(await prepare_search_doc(...))
        cursor.execute(
            "INSERT INTO ingestion_log (file_path, storage_account, conversation_id, status, chunk_count) VALUES (?,?,?,?,?)",
            (path.name, STORAGE_ACCOUNT_NAME, conversation_id, 'success', chunk_count)
        )
    except Exception as e:
        cursor.execute(
            "INSERT INTO ingestion_log (file_path, storage_account, status, error_message) VALUES (?,?,?,?)",
            (path.name, STORAGE_ACCOUNT_NAME, 'failed', str(e))
        )
    conn.commit()
```

This table then powers:
- Incremental ingestion (filter `paths` to exclude files already in `ingestion_log` with `status='success'`)
- Operational dashboards (how many files processed, failure rates)
- Debugging (which exact files failed and why)

---

### 11.6 RAG Metadata State Summary

```
WHAT EXISTS TODAY                   WHERE
────────────────────────────────────────────────────────
Conversation-level analytics        SQL: processed_data, km_processed_data
Exploded key phrases                SQL: processed_data_key_phrases
Canonical topic registry            SQL: km_mined_topics
Chunk-level text + vectors          Azure AI Search: call_transcripts_index
Chat session history                Cosmos DB: conversations container

WHAT IS MISSING                     IMPACT
────────────────────────────────────────────────────────
Ingestion tracking / status log     Cannot do incremental ingestion
Processing timestamp                Cannot tell when data was last refreshed
Source system identifier            Citations don't show which system a transcript came from
Chunk count per document            Cannot verify completeness
CU analyzer version per record      Cannot audit which version produced which data
Error log for failed files          Silent failures during ingestion
```

---

## 12. History Routes – Chat History API Deep Dive

**File:** `src/api/api/history_routes.py`

This module implements the FastAPI router that exposes the chat history layer backed by Azure Cosmos DB. It is mounted under the `/history` prefix in `src/api/app.py`. Understanding it is important if the customer wants to disable, extend, or replace the history feature.

---

### 12.1 Architecture Context

```
React Frontend
      │  POST /history/update, GET /history/list, etc.
      ▼
FastAPI (history_routes.py router)
      │
      ▼
HistoryService  (src/api/services/history_service.py)
      │
      ▼
CosmosConversationClient  (src/api/common/database/cosmosdb_service.py)
      │
      ▼
Azure Cosmos DB  ←  gated by USE_CHAT_HISTORY_ENABLED env var
```

The router itself contains **no Cosmos DB logic** — it delegates everything to `HistoryService`. Its responsibility is HTTP contract validation, OpenTelemetry span management, and Application Insights event tracking.

---

### 12.2 Endpoint Inventory

| Method | Path | Purpose | Required Body Fields |
|---|---|---|---|
| `POST` | `/history/update` | Upsert a conversation record (title, messages) | `conversation_id` |
| `POST` | `/history/message_feedback` | Store thumbs-up/down feedback on a message | `message_id`, `message_feedback` |
| `DELETE` | `/history/delete` | Delete a single conversation and all its messages | `conversation_id` |
| `GET` | `/history/list` | Paginated list of user's conversations | `?offset=0&limit=25` query params |
| `POST` | `/history/read` | Retrieve all messages of a conversation | `conversation_id` |
| `POST` | `/history/rename` | Rename a conversation's title | `conversation_id`, `title` |
| `DELETE` | `/history/delete_all` | Delete all conversations for the current user | none |
| `POST` | `/history/clear` | Delete all messages from a conversation (keeps the container) | `conversation_id` |
| `GET` | `/history/ensure` | Health check — verifies Cosmos DB is reachable and configured | none |

---

### 12.3 Authentication Pattern

Every endpoint calls `get_authenticated_user_details(request_headers=request.headers)` first and extracts `user_principal_id`. All Cosmos DB queries are scoped to this user ID — a user can only read/write their own conversations. There is no admin override in this layer.

```python
authenticated_user = get_authenticated_user_details(request_headers=request.headers)
user_id = authenticated_user["user_principal_id"]
```

**Defined in:** `src/api/auth/auth_utils.py`. Reads the `X-MS-CLIENT-PRINCIPAL-ID` header injected by Azure App Service Easy Auth. In local development, this header must be spoofed or bypassed.

---

### 12.4 Observability Pattern

Every endpoint follows an identical three-layer observability pattern:

```python
# 1. Structured logging (goes to Application Insights via the OpenTelemetry exporter)
logger.info("POST /history/update called: conversation_id=%s", conversation_id)

# 2. Custom Application Insights event (queryable via KQL in Log Analytics)
track_event_if_configured("ConversationUpdated", {
    "user_id": user_id,
    "conversation_id": conversation_id,
    "title": update_response["title"]
})

# 3. OpenTelemetry span enrichment (distributed tracing correlation)
span = trace.get_current_span()
if span and conversation_id:
    span.set_attribute("conversation_id", conversation_id)
```

The custom events named above (`ConversationUpdated`, `ConversationDeleted`, etc.) can be queried directly in Azure Monitor with:

```kql
customEvents
| where name in ("ConversationUpdated", "ConversationDeleted", "AllConversationsDeleted")
| extend user_id = tostring(customDimensions["user_id"])
| summarize count() by name, bin(timestamp, 1h)
```

---

### 12.5 The `/delete_all` Idle-Connection Retry Pattern

This is the only endpoint with non-trivial defensive logic worth explaining to the customer:

```python
conversations = await history_service.get_conversations(user_id, offset=0, limit=None)
if not conversations:
    logger.info("delete_all: initial get_conversations returned empty; retrying once...")
    conversations = await history_service.get_conversations(user_id, offset=0, limit=None)
```

**Why this exists:** After the web page sits idle for >10 minutes, the first call to Cosmos DB from this long-lived App Service process can fail with a transient connection-reset or token-expiry error. `get_conversations` swallows that exception and returns `[]`. Without the retry, "Clear all chat history" would immediately return 404 — even when conversations exist — because the empty list is indistinguishable from "no conversations found."

Single-conversation delete (`/history/delete`) is unaffected because it doesn't pre-list conversations before acting.

**Also note:** `/delete_all` re-raises `HTTPException` explicitly before the generic `except Exception` handler. This ensures a 404 ("no conversations found") surfaces correctly to the frontend instead of being masked as a 500.

---

### 12.6 `/history/ensure` – Startup Health Check

```python
@router.get("/history/ensure")
async def ensure_cosmos():
    success, err = await history_service.ensure_cosmos()
    ...
    if "Invalid credentials" in cosmos_exception:
        return JSONResponse(content={"error": "Invalid credentials"}, status_code=401)
    elif "Invalid CosmosDB database name" in cosmos_exception or "Invalid CosmosDB container name" in cosmos_exception:
        return JSONResponse(content={"error": "Invalid CosmosDB configuration"}, status_code=422)
    else:
        return JSONResponse(content={"error": "CosmosDB is not configured or not working"}, status_code=500)
```

The frontend calls this endpoint on page load to decide whether to show the history panel. Three distinct failure modes are surfaced with distinct HTTP status codes so the UI can display the right error message:

| Status | Meaning |
|---|---|
| `200` | Cosmos DB is reachable and correctly configured |
| `401` | Credentials are wrong (Managed Identity not assigned to Cosmos DB) |
| `422` | DB or container name env vars are incorrect |
| `500` | Cosmos DB is unreachable (network, firewall, endpoint wrong) |

---

### 12.7 Disabling or Replacing Chat History

**To disable completely:**
Set `USE_CHAT_HISTORY_ENABLED=false` in the App Service environment. `chat_service.py` checks this flag before calling any history endpoints; the frontend hides the history panel.

**To replace Cosmos DB with a different store (e.g., Azure SQL):**

1. Implement the same interface as `CosmosConversationClient` in a new class (e.g., `SqlConversationClient`)
2. `HistoryService` (`src/api/services/history_service.py`) instantiates `CosmosConversationClient` — swap that import
3. The router (`history_routes.py`) requires zero changes since it delegates entirely to `HistoryService`
4. Update Bicep to provision the new store and assign the App Service Managed Identity the required roles

**Required interface methods** (from `src/api/common/database/cosmosdb_service.py`):

| Method | Returns |
|---|---|
| `ensure()` | `(bool, str \| None)` |
| `create_conversation(user_id, title)` | conversation dict |
| `upsert_conversation(conversation)` | conversation dict |
| `delete_conversation(user_id, conversation_id)` | bool |
| `get_conversations(user_id, sort_order, offset, limit)` | list |
| `get_conversation(user_id, conversation_id)` | conversation dict or None |
| `create_message(...)` | message dict |
| `update_message(...)` | message dict |
| `update_message_feedback(user_id, message_id, feedback)` | message dict or None |
| `get_messages(user_id, conversation_id)` | list |
| `delete_messages(user_id, conversation_id)` | bool |

---

*Document was crafted for KT session on 2026-07-10. Code references are based on the current state of the `main` branch of `microsoft/Conversation-Knowledge-Mining-Solution-Accelerator`.*

---
