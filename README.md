# BitNet Server 🧠🚀

## Description

The BitNet Server project provides a ready-to-use, self-contained Docker container that runs a Microsoft BitNet model and exposes it via llama-server, offering an OpenAI API–compatible service.

## What is Microsoft BitNet?

BitNet is Microsoft’s experimental family of 1-bit Large Language Models (LLMs). Unlike traditional FP16/INT8 models, BitNet uses 1.58-bit quantization with lookup tables (LUT). This makes it possible to:

- Run larger models on CPUs without requiring expensive GPUs.
- Achieve faster inference thanks to lower precision arithmetic.
- Dramatically reduce memory footprint, while keeping useful accuracy.

This is especially important for developers who want to run LLMs locally on CPUs with limited hardware but still demand competitive speed and efficiency.

## Why is this project special?

As modern infrastructure increasingly depends on LLMs as foundational building blocks, running them efficiently on existing hardware is crucial.

This container:

- Compiles BitNet + llama.cpp with aggressive optimizations, targeting your CPU for maximum performance.
- Loads the entire model into RAM by default (instead of mmap), reducing latency and ensuring stable performance.
- Provides a drop-in OpenAI-compatible API – no code changes required in clients already using chat/completions.

## Assumptions

- Optimizations are ON by default.
- The image is designed for long-running workloads where spending more build time for higher runtime efficiency makes sense.
- Optimizations include `-O3`, `LTO`, `OpenMP`, `OpenBLAS`, native ISA flags, and full in-memory model loading.

You can disable optimizations at build time with:

```bash
docker build -t bitnet-server --build-arg OPTIMIZE=false .
```

## How to Run the Model

### 1. Build the image
```bash
git clone https://github.com/<yourname>/bitnet-server.git
cd bitnet-server

# Build with defaults (optimized)
docker build -t bitnet-server .
```

### 2. Run with Docker
```bash
docker run -it --rm \
  -p 8088:8080 \
  --cap-add IPC_LOCK \
  --ulimit memlock=-1:-1 \
  bitnet-server
```

- Exposes the API on `http://localhost:8088/v1/`
- Uses the baked-in BitNet model (defaults to Microsoft’s 1.58-bit GGUF).

### 3. Run with Docker Compose
```bash
docker compose up
```

This will:

- Detect CPU count at runtime and configure threads automatically.
- Apply all runtime optimizations (`--no-mmap --mlock`).

## How to Use

Once the container is running, you can interact with it exactly like the OpenAI API.

### Example: Chat request via curl
```bash
curl -s http://localhost:8088/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bitnet",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello! How are you?"}
    ],
    "max_tokens": 128
  }'
```

### Example Response
```json
{
  "id": "chatcmpl-local-bitnet",
  "object": "chat.completion",
  "created": 1723900112,
  "model": "bitnet-b1.58-2b-4t",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! I'm doing great, thank you. How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 14,
    "total_tokens": 24
  }
}
```

## Running Other Models

You can run other models by specifying the `MODEL_URL` build argument during the Docker build process. For example, to run the Llama3 8B model, use the following command:

```bash
docker build -t bitnet-server:llama3-i2s \
  --build-arg MODEL_URL="https://huggingface.co/eugenehp/Llama3-8B-1.58-100B-tokens-GGUF/resolve/main/ggml-model-i2_s.gguf"
```

### What is the Llama3 8B Model?

The Llama3 8B model is a state-of-the-art large language model designed for efficient inference and high accuracy. It features:

- **8 Billion Parameters**: Provides robust capabilities for natural language understanding and generation.
- **1.58-bit Quantization**: Optimized for running on CPUs, leveraging lower precision arithmetic to reduce memory usage and improve speed.
- **GGUF Format**: Ensures compatibility with llama.cpp and efficient memory management.

This model is ideal for developers looking to deploy advanced AI capabilities on hardware with limited resources.

### Important Note on Model Format

The model must be in GGUF format and specifically targeting BitNet 1-bit quantization. This is because:

- **GGUF Format**: Ensures compatibility with llama.cpp and efficient loading into memory.
- **BitNet 1-bit Quantization**: Optimizes the model for lower precision arithmetic, enabling faster inference and reduced memory usage while maintaining useful accuracy.

Using models that do not meet these requirements may result in incompatibility or suboptimal performance.
