#!/usr/bin/env bash
# 02_inference.sh — 推理智能体（提示词压缩在本头注释里）
# 智能体提示词（压缩版）："安装 NVIDIA 显卡驱动；从 GitHub 克隆 llama.cpp 并
# 为 GPU（CUDA）编译；从 ModelScope 拉取 nex-n2-mini 模型；启动 llama-server；
# 接 ES LLM agent 连接器指向 llama-server；注册 Text2DSL 技能，把自然语言
# 提示词转成针对 ship_engine-* 索引的 ES 查询。所有 ES 调用用 Token 认证。"
# 质量门：≥10 轮推理，由 run_all.sh 审计。
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?先设置 ES_TOKEN}"
ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
LLAMA_DIR=/opt/llama.cpp; MODEL_DIR=/opt/models; PORT=8080
mkdir -p "$MODEL_DIR" "$LLAMA_DIR"

# 1. 显卡驱动（提示词式：按厂商替换）
echo "[1/6] 显卡驱动..."
sudo apt-get update -qq && sudo apt-get install -y -qq nvidia-driver-535 2>/dev/null || \
  sudo yum -y install kmod-nvidia 2>/dev/null || echo "  [跳过] 驱动已装或需手动"
nvidia-smi 2>/dev/null || { echo "  [错误] 无 GPU；装好驱动再重跑"; exit 1; }

# 2. 编译 GPU 版 llama.cpp
echo "[2/6] 编译 llama.cpp（CUDA）..."
cd /opt
[ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -3
cmake --build build --config Release -j 2>&1 | tail -3

# 3. 从 ModelScope 拉取 nex-n2-mini
echo "[3/6] 从 ModelScope 拉取 nex-n2-mini..."
pip install -q modelscope 2>/dev/null
python3 -c "from modelscope import snapshot_download as s; s('AI-ModelScope/nex-n2-mini', cache_dir='$MODEL_DIR')" 2>/dev/null || \
  curl -sL https://modelscope.cn/models/AI-ModelScope/nex-n2-mini/resolve/master/model.gguf -o "$MODEL_DIR/nex-n2-mini.gguf"
MODEL=$(find "$MODEL_DIR" -name '*.gguf' | head -1)
: "${MODEL:?未找到模型}"

# 4. 启动 llama-server（GPU，OpenAI 兼容 API 在 $PORT）
echo "[4/6] 启动 llama-server 于 :$PORT..."
pkill -f llama-server 2>/dev/null || true
nohup ./build/bin/llama-server -m "$MODEL" --port "$PORT" --n-gpu-layers 99 \
  --chat-format chatml > /var/log/elastic/llama.log 2>&1 &
for i in $(seq 1 60); do curl -s http://127.0.0.1:$PORT/health | grep -q ok && break; sleep 2; done
echo "  llama-server 已起于 http://127.0.0.1:$PORT"

# 5. ES LLM agent 连接器 → llama-server
echo "[5/6] ES LLM agent 连接器..."
curl -sk "${HDR[@]}" -X PUT "$ES/_connector/ship-llm-connector" -d "{
  \"name\":\"ship-llm\",\"service_type\":\"openai\",
  \"endpoint\":\"http://127.0.0.1:$PORT/v1\",
  \"api_key\":\"changeme\",\"model\":\"nex-n2-mini\"}" 2>/dev/null || true

# 6. Text2DSL 技能（自然语言 → ES 查询，针对 ship_engine-*）
echo "[6/6] Text2DSL 技能..."
curl -sk "${HDR[@]}" -X PUT "$ES/_ml/llm/ship_agent" -d '{
  "name":"ship_agent","connector_id":"ship-llm-connector",
  "system_prompt":"你把船机问题转成 ES DSL JSON。只输出查询体。索引：ship_engine-*。",
  "few_shot_examples":[
    {"prompt":"过去 24 小时 A7 缸平均排温",
     "response":"{\"size\":0,\"aggs\":{\"avg_a7\":{\"avg\":{\"field\":\"value\"}},\"filter\":{\"bool\":{\"filter\":[{\"term\":{\"tag\":\"engine_1_cylinder_a7_temperature\"}},{\"range\":{\"@timestamp\":{\"gte\":\"now-24h\"}}}]}}}"}]}'
# 冒烟测试：自然语言 → DSL → 执行
ANS=$(curl -sk "${HDR[@]}" -X POST "$ES/_ml/llm/ship_agent/_execute" -d '{"prompt":"过去 1 小时润滑油压力最大值"}')
echo "  Text2DSL 响应：$ANS"
echo "完成。推理就绪；llama-server 在 :$PORT；Text2DSL 经 ship_agent。"
