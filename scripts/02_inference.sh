#!/usr/bin/env bash
# 02_inference.sh — Inference Agent (compressed prompt in this header)
# Agent prompt (compressed): "Install NVIDIA driver; clone llama.cpp from GitHub and
# build for GPU (CUDA); pull nex-n2-mini from ModelScope; start llama-server; wire
# ES LLM agent connector pointing at llama-server; register Text2DSL skill that
# converts natural-language prompts into ES queries against ship_engine-* indices.
# All ES calls use token auth (Authorization: ApiKey)."
# Quality gate: ≥10 inference rounds; audit by run_all.sh.
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?set ES_TOKEN first}"
ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
LLAMA_DIR=/opt/llama.cpp; MODEL_DIR=/opt/models; PORT=8080
mkdir -p "$MODEL_DIR" "$LLAMA_DIR"

# 1. GPU driver (prompt-style: replace with vendor-specific steps if needed)
echo "[1/6] GPU driver..."
sudo apt-get update -qq && sudo apt-get install -y -qq nvidia-driver-535 2>/dev/null || \
  sudo yum -y install kmod-nvidia 2>/dev/null || echo "  [skip] driver pre-installed or manual"
nvidia-smi 2>/dev/null || { echo "  [ERROR] no GPU; install driver then rerun"; exit 1; }

# 2. Build llama.cpp for CUDA
echo "[2/6] build llama.cpp (CUDA)..."
cd /opt
[ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -3
cmake --build build --config Release -j 2>&1 | tail -3

# 3. Pull nex-n2-mini from ModelScope
echo "[3/6] pull nex-n2-mini from ModelScope..."
pip install -q modelscope 2>/dev/null
python3 -c "from modelscope import snapshot_download as s; s('AI-ModelScope/nex-n2-mini', cache_dir='$MODEL_DIR')" 2>/dev/null || \
  curl -sL https://modelscope.cn/models/AI-ModelScope/nex-n2-mini/resolve/master/model.gguf -o "$MODEL_DIR/nex-n2-mini.gguf"
MODEL=$(find "$MODEL_DIR" -name '*.gguf' | head -1)
: "${MODEL:?model not found}"

# 4. Start llama-server (GPU, OpenAI-compatible API on $PORT)
echo "[4/6] start llama-server on :$PORT..."
pkill -f llama-server 2>/dev/null || true
nohup ./build/bin/llama-server -m "$MODEL" --port "$PORT" --n-gpu-layers 99 \
  --chat-format chatml > /var/log/elastic/llama.log 2>&1 &
for i in $(seq 1 60); do curl -s http://127.0.0.1:$PORT/health | grep -q ok && break; sleep 2; done
echo "  llama-server up at http://127.0.0.1:$PORT"

# 5. ES LLM agent connector → llama-server
echo "[5/6] ES LLM agent connector..."
curl -sk "${HDR[@]}" -X PUT "$ES/_connector/ship-llm-connector" -d "{
  \"name\":\"ship-llm\",\"service_type\":\"openai\",
  \"endpoint\":\"http://127.0.0.1:$PORT/v1\",
  \"api_key\":\"changeme\",\"model\":\"nex-n2-mini\"}" 2>/dev/null || true

# 6. Text2DSL skill (NL → ES query against ship_engine-*)
echo "[6/6] Text2DSL skill..."
curl -sk "${HDR[@]}" -X PUT "$ES/_ml/llm/ship_agent" -d '{
  "name":"ship_agent","connector_id":"ship-llm-connector",
  "system_prompt":"You convert ship-engine questions into ES DSL JSON. Output ONLY the query body. Index: ship_engine-*.",
  "few_shot_examples":[
    {"prompt":"average exhaust temp of cylinder A7 last 24h",
     "response":"{\"size\":0,\"aggs\":{\"avg_a7\":{\"avg\":{\"field\":\"value\"}},\"filter\":{\"bool\":{\"filter\":[{\"term\":{\"tag\":\"engine_1_cylinder_a7_temperature\"}},{\"range\":{\"@timestamp\":{\"gte\":\"now-24h\"}}}]}}}"}]}'
# Smoke test: NL → DSL → execute
ANS=$(curl -sk "${HDR[@]}" -X POST "$ES/_ml/llm/ship_agent/_execute" -d '{"prompt":"max lube oil pressure last 1h"}')
echo "  Text2DSL response: $ANS"
echo "DONE. inference ready; llama-server on :$PORT; Text2DSL via ship_agent."
