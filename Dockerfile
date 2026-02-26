# ─────────────────────────────────────────────────────────────────
# MCP TEE Server — Confidential Container Image
#
# Designed for Azure Container Instances with sku: Confidential
# (AMD SEV-SNP hardware-enforced memory isolation).
#
# Build:  docker build -t mcp-tee-server:latest .
# Push:   docker tag mcp-tee-server:latest <acr>.azurecr.io/mcp-tee-server:latest
#         docker push <acr>.azurecr.io/mcp-tee-server:latest
# ─────────────────────────────────────────────────────────────────

FROM python:3.12-slim AS base

# Prevent Python from writing .pyc files (no disk writes in enclave)
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies first (layer caching)
COPY src/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY src/server.py .

# Non-root user (defense in depth — even inside the TEE)
RUN useradd --create-home --shell /bin/bash mcpuser
USER mcpuser

# The MCP server runs on stdio transport by default.
# For SSE transport, override with: CMD ["python", "server.py", "--transport", "sse"]
ENTRYPOINT ["python", "server.py"]
