# Base image with Python 3.11
FROM python:3.11-slim

# Security - run as non-root user
RUN groupadd -r vllm && useradd -r -g vllm vllm

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install vLLM in CPU mode
# NOTE: For GPU production use:
# pip install vllm (without --extra-index-url)
RUN pip install --no-cache-dir \
    vllm==0.4.1 \
    prometheus-client==0.20.0 \
    fastapi==0.110.0 \
    uvicorn==0.29.0

# Copy app files
COPY . .

# Set environment variables
ENV MODEL_NAME="facebook/opt-125m" \
    MAX_MODEL_LEN="512" \
    DTYPE="float32" \
    PORT="8000" \
    HOST="0.0.0.0"

# Pre-download model during build
# This avoids slow startup in production
RUN python -c "from transformers import AutoTokenizer; \
    AutoTokenizer.from_pretrained('facebook/opt-125m')"

# Switch to non-root user
USER vllm

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Start vLLM server
CMD ["python", "-m", "vllm.entrypoints.openai.api_server", \
     "--model", "facebook/opt-125m", \
     "--dtype", "float32", \
     "--max-model-len", "512", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--worker-use-ray"]