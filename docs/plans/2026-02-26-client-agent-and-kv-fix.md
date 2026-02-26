# MCP Client Agent + Premium KV Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a bare MCP client agent that connects to the server over HTTP and calls `attestation_status`, switch the server to streamable-http transport, and fix all "mHSM" references to "Premium Key Vault (SKR)".

**Architecture:** The server switches from stdio to `streamable-http` (env-var switchable for local dev). A new `src/agent.py` uses the `mcp` SDK's `streamablehttp_client` to connect, call `attestation_status`, and print a formatted report. All doc/comment references to mHSM are updated to accurately reflect Premium Key Vault SKR.

**Tech Stack:** Python 3.12, `mcp>=1.0.0` (already installed, includes client), `uvicorn` (already installed), FastMCP

---

### Task 1: Switch server.py to streamable-http transport

**Files:**
- Modify: `src/server.py:252-260`

**Step 1: Update the entry point block**

Replace the current entry point at the bottom of `src/server.py`:

```python
# ── Entry Point ─────────────────────────────────────────────────
if __name__ == "__main__":
    secrets = _check_secrets()
    logger.info("Starting MCP TEE Server")
    logger.info("Secrets loaded: %s", json.dumps(secrets))
    logger.info(
        "TEE environment: /dev/sev-guest=%s",
        os.path.exists("/dev/sev-guest"),
    )
    mcp.run(transport="stdio")
```

With:

```python
# ── Entry Point ─────────────────────────────────────────────────
if __name__ == "__main__":
    secrets = _check_secrets()
    logger.info("Starting MCP TEE Server")
    logger.info("Secrets loaded: %s", json.dumps(secrets))
    logger.info(
        "TEE environment: /dev/sev-guest=%s",
        os.path.exists("/dev/sev-guest"),
    )
    transport = os.environ.get("MCP_TRANSPORT", "streamable-http")
    if transport == "stdio":
        mcp.run(transport="stdio")
    else:
        mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
```

**Step 2: Verify the server starts in HTTP mode**

```bash
cd /Users/pawankhandavilli/Documents/OC3/mcp-tee-sample/src
python server.py
```

Expected output (last line): `Uvicorn running on http://0.0.0.0:8080`

Ctrl-C to stop.

**Step 3: Verify stdio mode still works**

```bash
MCP_TRANSPORT=stdio python server.py
```

Expected: server starts without uvicorn (no port binding output), then waits on stdin. Ctrl-C to stop.

**Step 4: Commit**

```bash
cd /Users/pawankhandavilli/Documents/OC3/mcp-tee-sample
git add src/server.py
git commit -m "feat: switch server to streamable-http transport (stdio via MCP_TRANSPORT env var)"
```

---

### Task 2: Update Dockerfile for HTTP transport

**Files:**
- Modify: `Dockerfile`

**Step 1: Update the Dockerfile**

Replace the current bottom section of `Dockerfile`:

```dockerfile
# The MCP server runs on stdio transport by default.
# For SSE transport, override with: CMD ["python", "server.py", "--transport", "sse"]
ENTRYPOINT ["python", "server.py"]
```

With:

```dockerfile
# The MCP server runs on streamable-http transport (port 8080) by default.
# For local stdio dev: set MCP_TRANSPORT=stdio
EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
```

**Step 2: Build to verify no errors**

```bash
docker build -t mcp-tee-server:test .
```

Expected: build completes with no errors.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: expose port 8080 for streamable-http transport"
```

---

### Task 3: Create src/agent.py

**Files:**
- Create: `src/agent.py`

**Step 1: Create the agent**

```python
"""
MCP TEE Agent — Attestation Verifier

A bare MCP client that connects to the MCP TEE server over HTTP
and calls the attestation_status tool to verify the server is
running inside a hardware TEE with all secrets loaded.

Usage:
    python agent.py [SERVER_URL]

    SERVER_URL defaults to http://localhost:8080/mcp

Examples:
    python agent.py
    python agent.py http://my-aci-container.azurecontainer.io:8080/mcp
"""

import asyncio
import sys
from datetime import datetime

from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession


SERVER_URL_DEFAULT = "http://localhost:8080/mcp"

CHECK = "\u2713"   # ✓
CROSS = "\u2717"   # ✗


def _fmt_bool(value: bool) -> str:
    return f"{CHECK}" if value else f"{CROSS}"


async def verify_attestation(server_url: str) -> bool:
    """
    Connect to the MCP server, call attestation_status, print report.
    Returns True if TEE is detected and all secrets are loaded.
    """
    print(f"\nConnecting to: {server_url}")

    try:
        async with streamablehttp_client(server_url) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()

                result = await session.call_tool("attestation_status", arguments={})

                if not result.content:
                    print("ERROR: Empty response from attestation_status tool.")
                    return False

                # FastMCP returns tool results as TextContent with JSON string
                import json
                raw = result.content[0].text
                data = json.loads(raw)

    except ConnectionRefusedError:
        print(f"ERROR: Connection refused — is the server running at {server_url}?")
        return False
    except Exception as e:
        print(f"ERROR: {type(e).__name__}: {e}")
        return False

    running_in_tee = data.get("running_in_tee", False)
    tee_type = data.get("tee_type", "unknown")
    secrets = data.get("secrets_loaded", {})
    server = data.get("server", "unknown")
    version = data.get("version", "?")
    timestamp = data.get("timestamp", datetime.utcnow().isoformat())

    all_secrets_loaded = all(secrets.values())
    success = running_in_tee and all_secrets_loaded

    print()
    print("MCP TEE Server — Attestation Report")
    print("=" * 45)
    print(f"Server:        {server} v{version}")
    print(f"TEE detected:  {_fmt_bool(running_in_tee)}  ({tee_type})")
    print(f"Secrets:")
    for name, loaded in secrets.items():
        print(f"  {name:<25} {_fmt_bool(loaded)}")
    print(f"Timestamp:     {timestamp}")
    print()

    if not running_in_tee:
        print("WARNING  Not running in a TEE — expected for local development.")
    if not all_secrets_loaded:
        missing = [k for k, v in secrets.items() if not v]
        print(f"WARNING  Missing secrets: {', '.join(missing)}")
    if success:
        print("OK  Server is attested and all secrets are loaded.")

    return success


def main() -> None:
    server_url = sys.argv[1] if len(sys.argv) > 1 else SERVER_URL_DEFAULT
    ok = asyncio.run(verify_attestation(server_url))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
```

**Step 2: Start the server in one terminal**

```bash
cd /Users/pawankhandavilli/Documents/OC3/mcp-tee-sample/src
python server.py
```

**Step 3: Run the agent in a second terminal**

```bash
cd /Users/pawankhandavilli/Documents/OC3/mcp-tee-sample
python src/agent.py
```

Expected output:
```
Connecting to: http://localhost:8080/mcp

MCP TEE Server — Attestation Report
=============================================
Server:        mcp-tee-server v1.0.0
TEE detected:  ✗  (none detected)
Secrets:
  GITHUB_TOKEN              ✗
  DB_CONNECTION_STRING      ✗
  WEBHOOK_URL               ✗
Timestamp:     2026-02-26T...

WARNING  Not running in a TEE — expected for local development.
WARNING  Missing secrets: GITHUB_TOKEN, DB_CONNECTION_STRING, WEBHOOK_URL
```

Exit code should be 1 (not fully attested locally — correct behavior).

**Step 4: Test with a fake secret to confirm ✓ rendering**

```bash
GITHUB_TOKEN=fake python src/agent.py
```

Expected: `GITHUB_TOKEN` shows `✓`, others still `✗`.

**Step 5: Commit**

```bash
git add src/agent.py
git commit -m "feat: add bare MCP client agent for attestation verification"
```

---

### Task 4: Fix terminology — README.md

**Files:**
- Modify: `README.md`

**Step 1: Apply the following replacements throughout README.md**

| Find | Replace |
|------|---------|
| `Azure Key Vault (mHSM)` | `Azure Key Vault Premium (SKR)` |
| `AKV mHSM` | `Key Vault Premium (SKR)` |
| `Key Vault mHSM` | `Key Vault Premium (SKR)` |
| `AKV mHSM key-release policy` | `Key Vault Premium Secure Key Release (SKR) policy` |
| `mHSM` (standalone) | `Key Vault Premium (SKR)` |

Also update the architecture diagram label:
```
              Azure Key Vault (mHSM)
```
→
```
              Azure Key Vault Premium (SKR)
```

And update the security model table row:
```
| Key Management | AKV mHSM key-release policy | Unauthorized secret access |
```
→
```
| Key Management | Key Vault Premium SKR policy | Unauthorized secret access |
```

Also update the attestation flow step 5:
```
5. **Key Vault mHSM** evaluates the key-release policy
```
→
```
5. **Key Vault Premium (SKR)** evaluates the key-release policy
```

**Step 2: Add `src/agent.py` to the project structure section**

Find:
```
└── scripts/
    └── deploy.sh                      # Build, generate CCE policy, and deploy
```

Replace with:
```
├── scripts/
│   └── deploy.sh                      # Build, generate CCE policy, and deploy
└── src/
    ├── server.py                      # MCP server with 3 tools + attestation status
    ├── agent.py                       # Bare MCP client — verifies attestation remotely
    └── requirements.txt               # Python dependencies
```

(Note: the existing structure section already has `src/` — just add `agent.py` to it.)

**Step 3: Add agent usage to Local Development section**

After the existing local dev block, add:

```markdown
### Verify attestation remotely

```bash
# In one terminal — start the server
cd src && python server.py

# In another terminal — run the agent
python src/agent.py http://localhost:8080/mcp

# Against a deployed ACI container:
python src/agent.py http://<aci-fqdn>:8080/mcp
```
```

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: replace mHSM with Premium Key Vault (SKR), document agent usage"
```

---

### Task 5: Fix terminology — server.py and main.bicep

**Files:**
- Modify: `src/server.py:13-16`
- Modify: `infra/main.bicep:51-52`

**Step 1: Update server.py module docstring**

Find in the module docstring (lines 13-16):
```python
All secrets are fetched at startup via Azure Key Vault mHSM with a
key-release policy bound to this container's attestation measurement.
```

Replace with:
```python
All secrets are fetched at startup via Azure Key Vault Premium (SKR) with a
Secure Key Release policy bound to this container's attestation measurement.
```

**Step 2: Update main.bicep comment**

Find (line ~51-52):
```bicep
// ── Key Vault (for secret storage with key-release policy) ──────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
```

And find the inline comment on the SKU line:
```bicep
      name: 'premium' // Required for mHSM-backed keys and key-release policies
```

Replace with:
```bicep
      name: 'premium' // Required for HSM-backed keys and Secure Key Release (SKR) policies
```

**Step 3: Commit**

```bash
git add src/server.py infra/main.bicep
git commit -m "docs: fix mHSM references in server.py and main.bicep"
```

---

### Task 6: Push to GitHub

**Step 1: Push all commits**

```bash
git push origin main
```

Expected: all 5 new commits pushed to `https://github.com/khpawan/mcp-tee-sample`.

**Step 2: Verify on GitHub**

```bash
gh repo view khpawan/mcp-tee-sample --web
```

Confirm `src/agent.py` is visible and README renders correctly.
