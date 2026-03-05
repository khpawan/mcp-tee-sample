#!/usr/bin/env python3
"""Encrypt a secret with the RSA public key from Azure Key Vault.

This script fetches the public portion of the envelope key from Key Vault
and RSA-OAEP encrypts the given secret. The output is a base64 string
that can be passed as an ENC_* environment variable to the container.

Prerequisites:
    pip install cryptography
    az login

Usage:
    python scripts/encrypt_secret.py \
        --vault-name mcp-tee-kv-xxxxx \
        --key-name mcp-envelope-key \
        --secret "ghp_xxxxxxxxxxxx"

    # Capture for deployment:
    ENC_TOKEN=$(python scripts/encrypt_secret.py \
        --vault-name mcp-tee-kv-xxxxx \
        --key-name mcp-envelope-key \
        --secret "ghp_xxxxxxxxxxxx")
"""

import argparse
import base64
import json
import subprocess
import sys

from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
from cryptography.hazmat.backends import default_backend


def base64url_decode(data: str) -> bytes:
    """Decode a base64url string (JWK format)."""
    rem = len(data) % 4
    if rem:
        data += "=" * (4 - rem)
    return base64.urlsafe_b64decode(data)


def main():
    parser = argparse.ArgumentParser(
        description="Encrypt a secret with the RSA public key from Azure Key Vault"
    )
    parser.add_argument("--vault-name", required=True, help="Key Vault name")
    parser.add_argument(
        "--key-name", default="mcp-envelope-key", help="Envelope key name in Key Vault"
    )
    parser.add_argument("--secret", required=True, help="Secret value to encrypt")
    args = parser.parse_args()

    # Fetch the public key JWK from Key Vault
    try:
        result = subprocess.run(
            [
                "az", "keyvault", "key", "show",
                "--vault-name", args.vault_name,
                "--name", args.key_name,
                "-o", "json",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"ERROR: Failed to fetch key from Key Vault: {e.stderr}", file=sys.stderr)
        sys.exit(1)

    key_data = json.loads(result.stdout)
    jwk = key_data["key"]

    if jwk.get("kty") not in ("RSA", "RSA-HSM"):
        print(f"ERROR: Key type must be RSA or RSA-HSM, got: {jwk.get('kty')}", file=sys.stderr)
        sys.exit(1)

    # Build RSA public key from JWK components
    n = int.from_bytes(base64url_decode(jwk["n"]), "big")
    e = int.from_bytes(base64url_decode(jwk["e"]), "big")
    public_key = RSAPublicNumbers(e, n).public_key(default_backend())

    # RSA-OAEP encrypt the secret (SHA-256 for both hash and MGF1)
    ciphertext = public_key.encrypt(
        args.secret.encode("utf-8"),
        rsa_padding.OAEP(
            mgf=rsa_padding.MGF1(algorithm=hashes.SHA256()),
            algorithm=hashes.SHA256(),
            label=None,
        ),
    )

    # Output base64-encoded ciphertext (ready for ENC_* env var)
    print(base64.b64encode(ciphertext).decode("ascii"))


if __name__ == "__main__":
    main()
