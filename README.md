# MCP TEE Server — Azure Confidential Containers on ACI

> **⚠️ Disclaimer — Reference Only**
>
> This repository is a **personal project** shared as a companion to an OC3 2026 talk. It is provided "as-is" for **educational and reference purposes only**. It is **not** an official Microsoft product, is **not supported** by Microsoft, and carries **no warranty or SLA** of any kind. Use at your own risk. Opinions expressed here are the author's own and do not represent the views of Microsoft.

A reference implementation of an [MCP](https://spec.modelcontextprotocol.io/) server running inside a hardware-enforced Trusted Execution Environment (TEE) on Azure Container Instances with AMD SEV-SNP.

This sample accompanies the OC3 2025 talk: **"Securing AI's New Attack Surface: Why MCP Servers Need Trusted Execution Environments"**

## The Problem

An MCP server aggregates credentials for every tool it exposes — GitHub tokens, database passwords, webhook URLs, API keys. Traditional security controls (IAM, vaults, network perimeters, container isolation) all fail against a single threat: **a privileged user on the host can read process memory and extract every secret in plaintext.**

## The Solution

Run the MCP server inside a Confidential Container on ACI. The AMD SEV-SNP hardware encrypts all enclave memory — even root on the host cannot read it. An [SKR sidecar](https://github.com/microsoft/confidential-sidecar-containers) performs hardware attestation and releases an RSA private key that decrypts the server's secrets — only inside the TEE.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  HOST OS  (untrusted — root yields nothing)                    │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  TEE BOUNDARY  (AMD SEV-SNP, hardware-enforced)          │  │
│  │                                                          │  │
│  │  ┌────────────────────────┐  ┌────────────────────────┐  │  │
│  │  │  MCP Server            │  │  SKR Sidecar           │  │  │
│  │  │  (Python / FastMCP)    │  │  (Go, port 9000)       │  │  │
│  │  │                        │  │                        │  │  │
│  │  │  Tools:                │  │  /key/release          │  │  │
│  │  │   • github_search      │  │  /attest/raw           │  │  │
│  │  │   • query_database     │  │  /attest/maa           │  │  │
│  │  │   • send_notification  │  │                        │  │  │
│  │  │   • attestation_status │  │  AMD SEV-SNP quote     │  │  │
│  │  │                        │  │       ↕                │  │  │
│  │  │  Secrets (in-memory):  │  │  Azure MAA (validate)  │  │  │
│  │  │   • GITHUB_TOKEN     ◄─┼──┤       ↕                │  │  │
│  │  │   • DB_CONN_STRING   ◄─┼──┤  Key Vault (release)   │  │  │
│  │  │   • WEBHOOK_URL      ◄─┼──┤                        │  │  │
│  │  └────────────────────────┘  └────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

## How Secrets Work (Envelope Encryption)

Secrets are protected with **envelope encryption** using an RSA-HSM key in Azure Key Vault Premium:

```
┌─ At provisioning time (your workstation) ──────────────────────┐
│                                                                │
│  1. Create RSA-HSM key in Key Vault with a release policy      │
│     that binds the key to the container's CCE policy hash      │
│                                                                │
│  2. Encrypt each secret with the RSA public key (OAEP-SHA256)  │
│     python scripts/encrypt_secret.py --secret "ghp_xxx..."     │
│                                                                │
│  3. Pass encrypted blobs as ENC_* env vars to the container    │
│     (ciphertexts are safe to store — useless without the TEE)  │
│                                                                │
└────────────────────────────────────────────────────────────────┘

┌─ At runtime (inside the TEE) ──────────────────────────────────┐
│                                                                │
│  1. SKR sidecar generates AMD SEV-SNP hardware attestation     │
│     quote and sends it to Azure MAA for validation             │
│                                                                │
│  2. MAA returns a signed JWT with the CCE policy measurement   │
│                                                                │
│  3. Key Vault evaluates the release policy — if the JWT        │
│     measurement matches, the RSA private key is released       │
│                                                                │
│  4. MCP server decrypts ENC_* env vars with the private key    │
│     → plaintext secrets exist only in TEE-encrypted memory     │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

**Key properties:**
- Secrets never exist in plaintext outside the TEE
- The RSA private key only leaves Key Vault to a verified TEE
- Even Azure operators / host root cannot read enclave memory
- Changing the container image invalidates the CCE policy hash → key release fails

## Project Structure

```
mcp-tee-sample/
├── README.md                          # This file
├── Dockerfile                         # Container image for the MCP server
├── src/
│   ├── server.py                      # MCP server with 4 tools + envelope decryption
│   ├── agent.py                       # MCP client — verifies attestation remotely
│   └── requirements.txt               # Python dependencies
├── infra/
│   ├── main.bicep                     # ACI Confidential + KV + SKR sidecar + Identity
│   └── key-release-policy.json        # Key Vault release policy template
└── scripts/
    ├── deploy.sh                      # End-to-end deployment automation
    └── encrypt_secret.py              # Encrypt a secret with the KV public key
```

## Prerequisites

| Tool | Purpose |
|------|---------|
| Azure CLI (`az`) | Deploy resources, manage Key Vault |
| `az confcom` extension | Generate CCE security policies |
| Docker | Build container image, hash layers for policy |
| Python 3.10+ | Run the MCP server and encryption helper |
| `cryptography` (pip) | RSA encryption in `encrypt_secret.py` |

```bash
# Install prerequisites
az extension add --name confcom
pip install cryptography
```

## Quick Start

### Option A: Automated deployment

```bash
# Full deploy: build → CCE policy → infra → envelope key
./scripts/deploy.sh --acr-name <your-acr> --resource-group <your-rg>

# With secrets (interactive prompts):
./scripts/deploy.sh --acr-name <your-acr> --resource-group <your-rg> --provision-secrets
```

### Option B: Step-by-step

#### 1. Build and push the container image

```bash
docker build -t mcp-tee-server:latest .
az acr login --name <your-acr>
docker tag mcp-tee-server:latest <your-acr>.azurecr.io/mcp-tee-server:latest
docker push <your-acr>.azurecr.io/mcp-tee-server:latest
```

#### 2. Generate the CCE security policy

The policy cryptographically measures the container image, command, and environment:

```bash
# Generate from the Bicep template (includes SKR sidecar):
az confcom acipolicygen \
  --template-file infra/main.bicep \
  --print-policy > cce-policy.b64

# Compute the policy hash for the key-release policy:
HASH=$(cat cce-policy.b64 | base64 -d | sha256sum | cut -d' ' -f1)
echo "Policy hash: $HASH"
```

#### 3. Update the key-release policy

Edit `infra/key-release-policy.json` — replace the `x-ms-sevsnpvm-hostdata` hash with the one from step 2:

```json
{
  "claim": "x-ms-sevsnpvm-hostdata",
  "equals": "<paste-your-policy-hash-here>"
}
```

#### 4. Deploy infrastructure

```bash
az deployment group create \
  --resource-group <your-rg> \
  --template-file infra/main.bicep \
  --parameters \
    acrName=<your-acr> \
    imageTag=latest \
    ccePolicy=$(cat cce-policy.b64)
```

This creates: Key Vault Premium, Managed Identity, ACI Container Group (MCP server + SKR sidecar).

#### 5. Create the RSA-HSM envelope key

```bash
KV_NAME=$(az deployment group show -g <your-rg> -n main \
  --query "properties.outputs.keyVaultName.value" -o tsv)

az keyvault key create \
  --vault-name $KV_NAME \
  --name mcp-envelope-key \
  --kty RSA-HSM \
  --size 4096 \
  --exportable true \
  --policy @infra/key-release-policy.json
```

#### 6. Encrypt and provision secrets

```bash
# Encrypt each secret with the envelope key's public key:
ENC_TOKEN=$(python scripts/encrypt_secret.py \
  --vault-name $KV_NAME --secret "ghp_your_github_pat")

ENC_DB=$(python scripts/encrypt_secret.py \
  --vault-name $KV_NAME --secret "postgresql://user:pass@host/db")

ENC_HOOK=$(python scripts/encrypt_secret.py \
  --vault-name $KV_NAME --secret "https://hooks.slack.com/xxx")

# Redeploy with encrypted secrets:
az deployment group create \
  --resource-group <your-rg> \
  --template-file infra/main.bicep \
  --parameters \
    acrName=<your-acr> \
    imageTag=latest \
    ccePolicy=$(cat cce-policy.b64) \
    encGithubToken=$ENC_TOKEN \
    encDbConnectionString=$ENC_DB \
    encWebhookUrl=$ENC_HOOK
```

#### 7. Verify

```bash
# Check container logs:
az container logs -g <your-rg> -n mcp-tee-server
# Should show: "Envelope key released via SKR — decrypting secrets"
# Should show: "Decrypted GITHUB_TOKEN via envelope encryption"

# Check SKR sidecar:
az container logs -g <your-rg> -n mcp-tee-server -c skr-sidecar

# Test MCP endpoint:
python src/agent.py http://<aci-fqdn>:8080/mcp
```

## Local Development

For local testing without a TEE, set plain environment variables (the server falls back to them when SKR is unavailable):

```bash
export GITHUB_TOKEN=ghp_xxxx
export DB_CONNECTION_STRING=postgresql://user:pass@host:5432/db
export WEBHOOK_URL=https://hooks.slack.com/services/xxx

cd src && python server.py
```

The `attestation_status` tool will report `running_in_tee: false` and `secrets_source: env`.

### Verify attestation remotely

```bash
# Start the server locally:
cd src && python server.py

# In another terminal, run the agent:
python src/agent.py http://localhost:8080/mcp

# Against a deployed ACI container:
python src/agent.py http://<aci-fqdn>:8080/mcp
```

## Security Model

| Layer | Control | What it protects against |
|-------|---------|------------------------|
| Hardware | AMD SEV-SNP memory encryption | Privileged host access, physical memory dumps |
| Attestation | Azure MAA + CCE policy hash | Supply chain attacks, image tampering |
| Key Management | KV Premium RSA-HSM + release policy | Unauthorized key export, rogue containers |
| Envelope Encryption | RSA-OAEP encrypted env vars | Secrets in transit, config exposure |
| Application | Read-only SQL, input validation | Prompt injection, SQL injection |
| MCP Capability Model | Default-deny, confirmation gates | Unauthorized write actions |

## Capability Model

This server implements the [MCP Capability Model](https://pawankhandavilli.com/posts/mcp-is-a-capability-system-treat-it-like-one/):

- **Default-deny**: The database tool only accepts SELECT queries
- **Read/write separation**: `github_search_issues` and `query_database` are read-only; `send_notification` is a write action
- **Confirmation gate**: `send_notification` should always require explicit user confirmation in agent workflows
- **Audit trail**: All tool calls are logged with parameters (secrets redacted)
- **Attestation status**: The `attestation_status` tool provides runtime TEE and secret verification

## FAQ

**Q: Why RSA-HSM instead of oct-HSM (symmetric keys)?**
A: Azure Key Vault Premium only supports asymmetric keys (RSA-HSM, EC-HSM) for Secure Key Release. Symmetric `oct-HSM` keys require Azure Managed HSM, which is significantly more expensive. The envelope encryption pattern with RSA-HSM achieves the same goal.

**Q: What happens if the container image changes?**
A: The CCE policy hash changes, which breaks the key-release policy match. Key Vault refuses to release the private key. You must regenerate the CCE policy and update the key-release policy before redeploying.

**Q: Can I rotate the envelope key?**
A: Yes. Create a new RSA-HSM key with the same release policy, re-encrypt your secrets with the new public key, and redeploy the container with the new ciphertexts and key name.

**Q: What if I don't have Docker installed locally?**
A: Use `az acr build` to build in the cloud: `az acr build --registry <acr> --image mcp-tee-server:latest .`

## References

- [Azure Confidential Containers on ACI](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-confidential-overview)
- [Secure Key Release (SKR) with Confidential Containers](https://learn.microsoft.com/en-us/azure/confidential-computing/skr-flow-confidential-containers-azure-container-instance)
- [Microsoft Confidential Sidecar Containers (SKR)](https://github.com/microsoft/confidential-sidecar-containers)
- [Azure Attestation (MAA)](https://learn.microsoft.com/en-us/azure/attestation/overview)
- [CCE Policy Generation (confcom CLI)](https://learn.microsoft.com/en-us/azure/container-instances/confidential-containers-cce-policy)
- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP is a Capability System (Treat It Like One)](https://pawankhandavilli.com/posts/mcp-is-a-capability-system-treat-it-like-one/)
