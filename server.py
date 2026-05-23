from fastapi import FastAPI
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, generate_latest
from starlette.responses import Response
from pydantic import BaseModel
from typing import Optional, List
import time
import uuid
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM

app = FastAPI(title="Mal vLLM Inference Server")

# ── Prometheus metrics ──────────────────────────────
REQUEST_COUNT = Counter(
    'vllm_request_success_total',
    'Total successful requests'
)
REQUEST_LATENCY = Histogram(
    'vllm_time_to_first_token_seconds',
    'Time to first token in seconds'
)
QUEUE_DEPTH = Counter(
    'vllm_num_requests_waiting',
    'Number of requests waiting'
)

# ── Load model ──────────────────────────────────────
print("⏳ Loading facebook/opt-125m model...")
MODEL_NAME = "facebook/opt-125m"
tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
model = AutoModelForCausalLM.from_pretrained(
    MODEL_NAME,
    torch_dtype=torch.float32
)
model.eval()
print("✅ Model loaded and ready!")

# ── Request/Response models ─────────────────────────
class CompletionRequest(BaseModel):
    model: str = "facebook/opt-125m"
    prompt: str
    max_tokens: Optional[int] = 50
    temperature: Optional[float] = 0.7
    stream: Optional[bool] = False

class CompletionChoice(BaseModel):
    text: str
    index: int
    finish_reason: str

class CompletionResponse(BaseModel):
    id: str
    object: str
    created: int
    model: str
    choices: List[CompletionChoice]

# ── Endpoints ───────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "healthy", "model": MODEL_NAME}

@app.get("/metrics")
async def metrics():
    return Response(
        content=generate_latest(),
        media_type="text/plain"
    )

@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{
            "id": MODEL_NAME,
            "object": "model",
            "owned_by": "mal-ai"
        }]
    }

@app.post("/v1/completions")
async def completions(request: CompletionRequest):
    start_time = time.time()

    # Tokenize input
    inputs = tokenizer(
        request.prompt,
        return_tensors="pt",
        truncation=True,
        max_length=512
    )

    # Generate response
    with torch.no_grad():
        outputs = model.generate(
            inputs.input_ids,
            max_new_tokens=request.max_tokens,
            temperature=request.temperature,
            do_sample=True,
            pad_token_id=tokenizer.eos_token_id
        )

    # Decode output
    generated = tokenizer.decode(
        outputs[0][inputs.input_ids.shape[1]:],
        skip_special_tokens=True
    )

    # Track metrics
    latency = time.time() - start_time
    REQUEST_COUNT.inc()
    REQUEST_LATENCY.observe(latency)

    return CompletionResponse(
        id=f"cmpl-{uuid.uuid4().hex[:8]}",
        object="text_completion",
        created=int(time.time()),
        model=request.model,
        choices=[CompletionChoice(
            text=generated,
            index=0,
            finish_reason="stop"
        )]
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)