"""
MCP TEE Agent — Attestation Verifier

A bare MCP client that connects to the MCP TEE server over streamable-http,
calls the attestation_status tool, and prints a formatted report.

Exit codes:
  0 — server is running in a TEE and all secrets are loaded
  1 — not in TEE or one or more secrets are missing
"""

import asyncio
import json
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

DEFAULT_SERVER_URL = "http://localhost:8080/mcp"


async def run(server_url: str) -> int:
    """Connect to the MCP server, call attestation_status, print report."""
    print(f"Connecting to: {server_url}")
    print()

    async with streamablehttp_client(server_url) as (read_stream, write_stream, _):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()

            result = await session.call_tool("attestation_status", arguments={})

    # Parse the JSON payload from the first content block
    if not result.content or not hasattr(result.content[0], "text"):
        print("ERROR: Unexpected response format from attestation_status tool.")
        return 1
    try:
        data = json.loads(result.content[0].text)
    except json.JSONDecodeError as e:
        print(f"ERROR: Could not parse attestation_status response: {e}")
        return 1

    server_name = data.get("server", "unknown")
    version = data.get("version", "unknown")
    running_in_tee = data.get("running_in_tee", False)
    tee_type = data.get("tee_type", "unknown")
    secrets_loaded: dict = data.get("secrets_loaded", {})
    timestamp = data.get("timestamp", "unknown")

    CHECK = "\u2713"
    CROSS = "\u2717"

    tee_indicator = CHECK if running_in_tee else CROSS

    print("MCP TEE Server \u2014 Attestation Report")
    print("=" * 45)
    print(f"Server:        {server_name} v{version}")
    print(f"TEE detected:  {tee_indicator}  ({tee_type})")
    print("Secrets:")
    for secret_name, loaded in secrets_loaded.items():
        indicator = CHECK if loaded else CROSS
        print(f"  {secret_name:<26}{indicator}")
    print(f"Timestamp:     {timestamp}")
    print()

    # Determine outcome
    missing_secrets = [name for name, loaded in secrets_loaded.items() if not loaded]
    fully_attested = running_in_tee and not missing_secrets

    if not running_in_tee:
        print("WARNING  Not running in a TEE \u2014 expected for local development.")
    if missing_secrets:
        print(f"WARNING  Missing secrets: {', '.join(missing_secrets)}")
    if fully_attested:
        print("OK  Server is attested and all secrets are loaded.")

    return 0 if fully_attested else 1


def main() -> None:
    server_url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SERVER_URL
    _CONNECT_ERRORS = (ConnectionRefusedError, OSError, httpx.ConnectError)
    try:
        exit_code = asyncio.run(run(server_url))
    except _CONNECT_ERRORS as e:
        print(f"ERROR: could not connect to {server_url} — {e}")
        exit_code = 1
    except BaseException as e:
        # The MCP library wraps connection errors in an ExceptionGroup; unwrap it.
        causes = (
            e.exceptions
            if isinstance(e, BaseExceptionGroup)
            else [e]
        )
        conn_causes = [c for c in causes if isinstance(c, _CONNECT_ERRORS)]
        if conn_causes:
            print(f"ERROR: could not connect to {server_url} — {conn_causes[0]}")
            exit_code = 1
        else:
            raise
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
