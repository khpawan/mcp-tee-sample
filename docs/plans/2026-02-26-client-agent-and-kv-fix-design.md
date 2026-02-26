# Design: MCP Client Agent + Premium Key Vault Terminology Fix

Date: 2026-02-26

## Overview

Two changes to the `mcp-tee-sample` project:

1. **Client agent** (`src/agent.py`) — a bare MCP client that connects to the running server over HTTP and calls `attestation_status` to verify the TEE and secrets are live.
2. **Terminology fix** — replace all "mHSM" references with "Premium Key Vault (SKR)" in the README, `server.py` docstring, and `main.bicep` comments.

## Context

The server currently runs on `stdio` transport, which is the local subprocess model. In the actual deployed scenario (ACI confidential container), the server needs to expose an HTTP endpoint and clients connect to it over the network. This design switches the server to `streamable-http` and adds a matching client.

The infra (`main.bicep`) already uses `sku: 'premium'`, not a Managed HSM resource. The "mHSM" language in docs and comments is inaccurate — Premium Key Vault supports Secure Key Release (SKR) with HSM-backed keys, which is exactly what the key-release policy uses.

## Architecture

```
Developer laptop
  └── src/agent.py (bare MCP client)
        └── streamable-http → http://<host>:8080/mcp
              └── MCP Server (ACI confidential container)
                    └── attestation_status tool
```

## Components

### 1. `server.py` — transport switch

Change the entry point from:
```python
mcp.run(transport="stdio")
```
to:
```python
mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
```

Keep stdio available for local dev via an env var flag (`MCP_TRANSPORT=stdio`).

### 2. `Dockerfile` — expose port

Add `EXPOSE 8080` and update `CMD` to run the server directly (currently no CMD is set for HTTP mode).

### 3. `src/agent.py` — bare MCP client

- Accepts server URL as a positional CLI arg, defaults to `http://localhost:8080/mcp`
- Uses `mcp` SDK: `streamablehttp_client` + `ClientSession`
- Calls `attestation_status` tool
- Prints a formatted human-readable report:
  - Whether the server is reachable
  - `running_in_tee`: ✓ / ✗ with TEE type
  - `secrets_loaded`: per-key ✓ / ✗
  - Timestamp
- Exits with code 0 on success, 1 if TEE not detected or any secret missing

### 4. Terminology fix — three files

| File | Change |
|------|--------|
| `README.md` | "AKV mHSM" → "Azure Key Vault Premium (SKR)"; update security model table |
| `server.py` | Module docstring: "Azure Key Vault mHSM" → "Azure Key Vault Premium (SKR)" |
| `main.bicep` | Comment on `premium` SKU line: clarify it enables SKR, not mHSM |

## Data Flow

1. Agent opens HTTP connection to server `/mcp`
2. MCP handshake (initialize)
3. Agent calls `attestation_status` tool
4. Server responds with TEE detection flags and secrets status
5. Agent formats and prints report, exits with appropriate code

## Error Handling

- Connection refused / timeout → print clear error, exit 1
- Server reachable but `running_in_tee: false` → print warning (not error — valid for local dev)
- Any secret not loaded → print warning per missing secret

## Dependencies

`mcp` is already in `requirements.txt`. The streamable-http client is part of the same package — no new dependencies needed.

## Testing

Run locally without a TEE:
```bash
# Terminal 1
cd src && python server.py

# Terminal 2
python src/agent.py http://localhost:8080/mcp
```

Expected output when not in TEE:
```
MCP TEE Server — Attestation Report
=====================================
Server:        mcp-tee-server v1.0.0
TEE detected:  ✗  (none detected)
Secrets:
  GITHUB_TOKEN         ✗
  DB_CONNECTION_STRING ✗
  WEBHOOK_URL          ✗
Timestamp: 2026-02-26T...

⚠  Not running in a TEE — expected for local development.
```
