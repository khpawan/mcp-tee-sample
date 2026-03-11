#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# deploy.sh — Build, generate policy, and deploy the MCP TEE server
#
# Deploys an MCP server inside an Azure Confidential Container (ACI)
# with AMD SEV-SNP and an SKR sidecar for hardware-attested secret
# decryption via envelope encryption.
#
# Prerequisites:
#   - Azure CLI (az) with the confcom extension
#   - Docker (for building / hashing the image)
#   - Python 3 + cryptography (pip install cryptography)
#   - An Azure Container Registry (ACR)
#   - A resource group for the deployment
#
# Usage:
#   # Full deploy (build → policy → infra → envelope key):
#   ./scripts/deploy.sh \
#     --acr-name <your-acr> \
#     --resource-group <your-rg>
#
#   # Provision secrets after deploy:
#   ./scripts/deploy.sh \
#     --acr-name <your-acr> \
#     --resource-group <your-rg> \
#     --provision-secrets
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Pre-flight: Ensure Azure CLI is authenticated ────────────────
if ! az account show &>/dev/null; then
  echo "ERROR: Not logged into Azure CLI. Run 'az login' first."
  exit 1
fi

# ── Parse Arguments ──────────────────────────────────────────────
ACR_NAME=""
RESOURCE_GROUP=""
IMAGE_TAG="latest"
PROVISION_SECRETS=false
ENVELOPE_KEY_NAME="mcp-envelope-key"

while [[ $# -gt 0 ]]; do
  case $1 in
    --acr-name)           ACR_NAME="$2";           shift 2 ;;
    --resource-group)     RESOURCE_GROUP="$2";      shift 2 ;;
    --image-tag)          IMAGE_TAG="$2";           shift 2 ;;
    --provision-secrets)  PROVISION_SECRETS=true;    shift ;;
    --envelope-key-name)  ENVELOPE_KEY_NAME="$2";   shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$ACR_NAME" || -z "$RESOURCE_GROUP" ]]; then
  echo "Usage: $0 --acr-name <acr> --resource-group <rg> [--image-tag <tag>] [--provision-secrets]"
  exit 1
fi

IMAGE="${ACR_NAME}.azurecr.io/mcp-tee-server:${IMAGE_TAG}"

echo "═══════════════════════════════════════════════════════════"
echo "  MCP TEE Server — Confidential Container Deployment"
echo "═══════════════════════════════════════════════════════════"
echo "  ACR:            ${ACR_NAME}"
echo "  Resource Group: ${RESOURCE_GROUP}"
echo "  Image:          ${IMAGE}"
echo "  Envelope Key:   ${ENVELOPE_KEY_NAME}"
echo "═══════════════════════════════════════════════════════════"

# ── Step 1: Build and Push the Container Image ──────────────────
echo ""
echo "▶ Step 1: Building container image..."
docker build -t "mcp-tee-server:${IMAGE_TAG}" .

echo "▶ Pushing to ACR..."
az acr login --name "${ACR_NAME}"
docker tag "mcp-tee-server:${IMAGE_TAG}" "${IMAGE}"
docker push "${IMAGE}"
echo "✓ Image pushed: ${IMAGE}"

# ── Step 2: Generate CCE Security Policy ────────────────────────
echo ""
echo "▶ Step 2: Generating CCE security policy..."
echo "  (This computes the expected container image measurement)"

az extension add --name confcom 2>/dev/null || true

CCE_POLICY=$(az confcom acipolicygen \
  --template-file infra/main.bicep \
  --print-policy 2>/dev/null)

echo "✓ CCE policy generated (${#CCE_POLICY} chars, base64-encoded)"

# Compute the policy hash and update key-release-policy.json
POLICY_HASH=$(echo -n "${CCE_POLICY}" | base64 -d | sha256sum | cut -d' ' -f1)
echo "✓ Policy hash: ${POLICY_HASH}"

POLICY_FILE="infra/key-release-policy.json"
if [[ -f "${POLICY_FILE}" ]]; then
  # Update the hostdata hash (replace any existing hex hash or the placeholder)
  # Update the hash (portable across macOS and Linux)
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' -E "s/\"equals\": \"([a-f0-9]{64}|<REPLACE_WITH_CCE_POLICY_HASH>)\"/\"equals\": \"${POLICY_HASH}\"/" "${POLICY_FILE}"
  else
    sed -i -E "s/\"equals\": \"([a-f0-9]{64}|<REPLACE_WITH_CCE_POLICY_HASH>)\"/\"equals\": \"${POLICY_HASH}\"/" "${POLICY_FILE}"
  fi
  echo "✓ Updated ${POLICY_FILE} with policy hash"
fi

# ── Step 3: Deploy Infrastructure ───────────────────────────────
echo ""
echo "▶ Step 3: Deploying Bicep template (KV + Identity + ACI + SKR sidecar)..."
DEPLOY_OUTPUT=$(az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file infra/main.bicep \
  --parameters \
    acrName="${ACR_NAME}" \
    imageTag="${IMAGE_TAG}" \
    ccePolicy="${CCE_POLICY}" \
    envelopeKeyName="${ENVELOPE_KEY_NAME}" \
  --query "properties.outputs" \
  -o json)

KV_NAME=$(echo "${DEPLOY_OUTPUT}" | jq -r '.keyVaultName.value')
SERVER_FQDN=$(echo "${DEPLOY_OUTPUT}" | jq -r '.serverFqdn.value')
echo "✓ Deployed — Key Vault: ${KV_NAME}, FQDN: ${SERVER_FQDN}"

# ── Step 4: Create the RSA-HSM Envelope Key ─────────────────────
echo ""
echo "▶ Step 4: Creating RSA-HSM envelope key with release policy..."

# Check if key already exists
if az keyvault key show --vault-name "${KV_NAME}" --name "${ENVELOPE_KEY_NAME}" &>/dev/null; then
  echo "✓ Envelope key '${ENVELOPE_KEY_NAME}' already exists — skipping creation"
else
  az keyvault key create \
    --vault-name "${KV_NAME}" \
    --name "${ENVELOPE_KEY_NAME}" \
    --kty RSA-HSM \
    --size 4096 \
    --exportable true \
    --policy "${POLICY_FILE}" \
    --ops encrypt decrypt \
    -o table
  echo "✓ Envelope key '${ENVELOPE_KEY_NAME}' created"
fi

# ── Step 5 (optional): Encrypt and provision secrets ─────────────
if [[ "${PROVISION_SECRETS}" == "true" ]]; then
  echo ""
  echo "▶ Step 5: Encrypting and provisioning secrets..."
  echo "  Enter each secret when prompted (leave blank to skip)."
  echo ""

  read -rsp "  GitHub token (PAT): " GITHUB_TOKEN; echo
  read -rsp "  DB connection string: " DB_CONN; echo
  read -rsp "  Webhook URL: " WEBHOOK; echo

  ENC_GITHUB_TOKEN=""
  ENC_DB_CONN=""
  ENC_WEBHOOK=""

  if [[ -n "${GITHUB_TOKEN}" ]]; then
    ENC_GITHUB_TOKEN=$(echo -n "${GITHUB_TOKEN}" | python3 scripts/encrypt_secret.py \
      --vault-name "${KV_NAME}" --key-name "${ENVELOPE_KEY_NAME}" \
      --secret -)
    echo "  ✓ Encrypted GITHUB_TOKEN"
  fi
  if [[ -n "${DB_CONN}" ]]; then
    ENC_DB_CONN=$(echo -n "${DB_CONN}" | python3 scripts/encrypt_secret.py \
      --vault-name "${KV_NAME}" --key-name "${ENVELOPE_KEY_NAME}" \
      --secret -)
    echo "  ✓ Encrypted DB_CONNECTION_STRING"
  fi
  if [[ -n "${WEBHOOK}" ]]; then
    ENC_WEBHOOK=$(echo -n "${WEBHOOK}" | python3 scripts/encrypt_secret.py \
      --vault-name "${KV_NAME}" --key-name "${ENVELOPE_KEY_NAME}" \
      --secret -)
    echo "  ✓ Encrypted WEBHOOK_URL"
  fi

  echo ""
  echo "▶ Redeploying with encrypted secrets..."
  az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --template-file infra/main.bicep \
    --parameters \
      acrName="${ACR_NAME}" \
      imageTag="${IMAGE_TAG}" \
      ccePolicy="${CCE_POLICY}" \
      envelopeKeyName="${ENVELOPE_KEY_NAME}" \
      encGithubToken="${ENC_GITHUB_TOKEN}" \
      encDbConnectionString="${ENC_DB_CONN}" \
      encWebhookUrl="${ENC_WEBHOOK}" \
    --output table
  echo "✓ Redeployed with encrypted secrets"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ✓ Deployment complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Server endpoint: http://${SERVER_FQDN:-<pending>}:8080/mcp"
echo "Key Vault:       ${KV_NAME}"
echo ""
echo "To provision secrets later:"
echo "  # Encrypt each secret with the envelope key:"
echo "  ENC=\$(python3 scripts/encrypt_secret.py \\"
echo "    --vault-name ${KV_NAME} --secret '<value>')"
echo ""
echo "  # Redeploy with encrypted values:"
echo "  az deployment group create -g ${RESOURCE_GROUP} \\"
echo "    -f infra/main.bicep --parameters \\"
echo "    acrName=${ACR_NAME} ccePolicy=<policy> \\"
echo "    encGithubToken=\$ENC_TOKEN encDbConnectionString=\$ENC_DB \\"
echo "    encWebhookUrl=\$ENC_HOOK"
echo ""
echo "Verify:"
echo "  az container logs -g ${RESOURCE_GROUP} -n mcp-tee-server"
echo "  az container logs -g ${RESOURCE_GROUP} -n mcp-tee-server -c skr-sidecar"
echo ""
