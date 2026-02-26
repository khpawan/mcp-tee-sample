# MCP TEE Server — Azure Confidential Containers on ACI

A reference implementation of an MCP server running inside a hardware-enforced Trusted Execution Environment (TEE) on Azure Container Instances with AMD SEV-SNP.

This sample accompanies the OC3 2025 talk: **"Securing AI's New Attack Surface: Why MCP Servers Need Trusted Execution Environments"**

## The Problem

An MCP server aggregates credentials for every tool it exposes — GitHub tokens, database passwords, webhook URLs, API keys. Traditional security controls (IAM, vaults, network perimeters, container isolation) all fail against a single threat: **a privileged user on the host can read process memory and extract every secret in plaintext.**

## The Solution

Run the MCP server inside a Confidential Container on ACI. The AMD SEV-SNP hardware encrypts all enclave memory — even root on the host cannot read it. Azure Attestation (MAA) provides cryptographic proof of what code is running, and Key Vault's key-release policy ensures secrets are only released to verified, unmodified containers.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  HOST OS  (untrusted — root yields nothing)         │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  TEE BOUNDARY (AMD SEV-SNP, hw-enforced)    │    │
│  │                                             │    │
│  │  ┌─────────────────────────────────────┐    │    │
│  │  │  MCP Server (Python / FastMCP)      │    │    │
│  │  │                                     │    │    │
│  │  │  Tools:                             │    │    │
│  │  │   • github_search_issues            │    │    │
│  │  │   • query_database (read-only)      │    │    │
│  │  │   • send_notification (write)       │    │    │
│  │  │   • attestation_status              │    │    │
│  │  │                                     │    │    │
│  │  │  Secrets (in-memory only):          │    │    │
│  │  │   • GITHUB_TOKEN                    │    │    │
│  │  │   • DB_CONNECTION_STRING            │    │    │
│  │  │   • WEBHOOK_URL                     │    │    │
│  │  └─────────────────────────────────────┘    │    │
│  │                                             │    │
│  │  Attestation Sidecar ──► Azure MAA          │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
└─────────────────────────────────────────────────────┘
                        │
                        ▼
              Azure Key Vault Premium (SKR)
              Key-release policy binds
              secrets to CCE policy hash
```

## Attestation Flow

1. **ACI starts the container** inside an AMD SEV-SNP hardware boundary
2. **Attestation sidecar** generates a hardware quote (measurement of running code)
3. **Azure MAA** validates the quote against AMD root certificates
4. **Signed JWT** returned with code measurement + platform claims
5. **Key Vault Premium (SKR)** evaluates the key-release policy — checks the JWT measurement matches the expected CCE policy hash
6. **Secrets released** only to verified code — host compromise yields cryptographically nothing

## Project Structure

```
mcp-tee-sample/
├── README.md                          # This file
├── Dockerfile                         # Container image for the MCP server
├── src/
│   ├── server.py                      # MCP server with 3 tools + attestation status
│   ├── agent.py                       # Bare MCP client — verifies attestation remotely
│   └── requirements.txt               # Python dependencies
├── infra/
│   ├── main.bicep                     # ACI Confidential + AKV + Managed Identity
│   └── key-release-policy.json        # AKV mHSM key-release policy template
└── scripts/
    └── deploy.sh                      # Build, generate CCE policy, and deploy
```

## Prerequisites

- Azure CLI (`az`) with the `confcom` extension
- Docker
- An Azure subscription with access to Confidential Container SKUs
- An Azure Container Registry (ACR)

```bash
# Install the confcom extension
az extension add --name confcom

# Verify it's available
az confcom --help
```

## Deployment

### 1. Build and push the image

```bash
docker build -t mcp-tee-server:latest .
az acr login --name <your-acr>
docker tag mcp-tee-server:latest <your-acr>.azurecr.io/mcp-tee-server:latest
docker push <your-acr>.azurecr.io/mcp-tee-server:latest
```

### 2. Generate the CCE security policy

```bash
az confcom acipolicy gen \
  --image <your-acr>.azurecr.io/mcp-tee-server:latest \
  --print-policy > cce-policy.txt
```

### 3. Update the key-release policy

Compute the policy hash and update `infra/key-release-policy.json`:

```bash
cat cce-policy.txt | base64 -d | sha256sum
# Replace <REPLACE_WITH_CCE_POLICY_HASH> in key-release-policy.json
```

### 4. Deploy

```bash
az deployment group create \
  --resource-group <your-rg> \
  --template-file infra/main.bicep \
  --parameters \
    acrName=<your-acr> \
    imageTag=latest \
    ccePolicy=$(cat cce-policy.txt)
```

### 5. Populate secrets

```bash
az keyvault secret set --vault-name <kv-name> --name github-token --value <your-github-pat>
az keyvault secret set --vault-name <kv-name> --name db-connection-string --value <your-connstr>
az keyvault secret set --vault-name <kv-name> --name webhook-url --value <your-webhook-url>
```

### Or use the deploy script

```bash
./scripts/deploy.sh --acr-name <your-acr> --resource-group <your-rg>
```

## Local Development

For local testing without a TEE (secrets loaded from environment variables):

```bash
export GITHUB_TOKEN=ghp_xxxx
export DB_CONNECTION_STRING=postgresql://user:pass@host:5432/db
export WEBHOOK_URL=https://hooks.slack.com/services/xxx

cd src && python server.py
```

The `attestation_status` tool will report `running_in_tee: false` when not in a confidential container.

### Verify attestation remotely

```bash
# In one terminal — start the server
cd src && python server.py

# In another terminal — run the agent
python src/agent.py http://localhost:8080/mcp

# Against a deployed ACI container:
python src/agent.py http://<aci-fqdn>:8080/mcp
```

## Security Model

| Layer | Control | What it protects against |
|-------|---------|------------------------|
| Hardware | AMD SEV-SNP memory encryption | Privileged host access, memory dumps |
| Attestation | Azure MAA + CCE policy | Supply chain attacks, image tampering |
| Key Management | Key Vault Premium SKR policy | Unauthorized secret access |
| Application | Read-only SQL, input validation | Prompt injection, tool misuse |
| Capability Model | Default-deny, confirmation gates | Unauthorized write actions |

## Capability Model

This server implements the MCP Capability Model:

- **Default-deny**: The database tool only accepts SELECT queries
- **Read/write separation**: `github_search_issues` and `query_database` are read-only; `send_notification` is a write action
- **Confirmation gate**: `send_notification` should always require explicit user confirmation in agent workflows
- **Audit trail**: All tool calls are logged with parameters (secrets redacted)
- **Attestation status**: The `attestation_status` tool provides runtime verification

## References

- [Azure Confidential Containers on ACI](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-confidential-overview)
- [Azure Attestation (MAA)](https://learn.microsoft.com/en-us/azure/attestation/overview)
- [confcom CLI](https://learn.microsoft.com/en-us/azure/container-instances/confidential-containers-cce-policy)
- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP is a Capability System (Treat It Like One)](https://pawankhandavilli.com/posts/mcp-is-a-capability-system-treat-it-like-one/)
