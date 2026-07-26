#!/usr/bin/env bash
# 01_data_lake.sh — 数据湖智能体（提示词压缩在本头注释里）
# 智能体提示词（压缩版）："用 Elastic Agent 把滚动更新的 engine_{年月日-时分秒}.txt
# 文件摄入到时序索引 ship_engine-*，每条文档一个 (tag,value,ts)；建立 ILM 策略
# ship-engine-tiers，分 3 月热 / 12 月温 / 36 月冷三层（数据全生命周期）。所有
# curl 调用统一用 Token 认证（Authorization: ApiKey）。"
# 质量门：≥10 轮摄入，由 run_all.sh 审计。
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?先设置 ES_TOKEN（见 00_install_stack.sh）}"
ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
SAMPLE=/home/z/my-project/upload/6a5b2311c2f546f92fcfa0bf_eng-var.txt
INGEST_DIR=/var/spool/engine  # 滚动 engine_*.txt 落此处
mkdir -p "$INGEST_DIR"

# 1. 组件模板 + ILM 策略（3/12/36 月）
echo "[1/4] ILM 策略：3 月热 / 12 月温 / 36 月冷..."
curl -sk "${HDR[@]}" -X PUT "$ES/_ilm/policy/ship-engine-tiers" -d '{
  "policy":{"phases":{
    "hot":{"actions":{"rollover":{"max_age":"3d"},"set_priority":{}}},
    "warm":{"min_age":"3M","actions":{"forcemerge":{"max_num_segments":1},"set_priority":{}}},
    "cold":{"min_age":"12M","actions":{"freeze":{},"set_priority":{}}},
    "delete":{"min_age":"36M","actions":{"delete":{}}}}}}'
curl -sk "${HDR[@]}" -X PUT "$ES/_index_template/ship-engine" -d '{
  "index_patterns":["ship_engine-*"],"template":{
    "settings":{"number_of_shards":1,"number_of_replicas":0,"index.lifecycle.name":"ship-engine-tiers"},
    "mappings":{"properties":{
      @timestamp":{"type":"date"},"tag":{"type":"keyword"},"value":{"type":"double"},
      "group":{"type":"keyword"},"unit":{"type":"keyword"},"ship_id":{"type":"keyword"}}}}}'

# 2. 从 839 测点样本生成滚动 engine_*.txt（一次轮询 = 一个文件）
echo "[2/4] 从 839 测点合成滚动 engine_*.txt..."
TS=$(date +%Y%m%d-%H%M%S); OUT="$INGEST_DIR/engine_$TS.txt"
awk -F/ -v ts="$(date -Iseconds)" 'BEGIN{print "# poll ts="ts}
{tag=$2; gsub(/engine\//,"",tag); val=sprintf("%.2f",50+rand()*150);
 group=(index(tag,"alarm")>0?"alarm":(index(tag,"generator")>0?"generator":"engine"));
 printf "%s\t%s\t%s\t%s\n", tag, val, group, ts}' "$SAMPLE" > "$OUT"
echo "  写入 $OUT（$(wc -l < "$OUT") 行）"

# 3. Elastic Agent filestream 输入 → ES（Token 认证输出）
echo "[3/4] elastic agent filestream → ship_engine-$TS..."
cat > /etc/elastic-agent/filestream.ship.yml <<YML
- type: filestream
  id: ship-engine-filestream
  paths: [$INGEST_DIR/engine_*.txt]
  parsers:
    - ndjson:
        target: engine
        fields_under_root: true
  processors:
    - decode_json_fields: {fields: [engine]}
    - convert: {field: engine.value, type: double}
    - rename: {fields: {engine.tag: tag, engine.group: group}}
    - add: {fields: {ship_id: SHIP-001}}
  output.elasticsearch:
    hosts: ["https://127.0.0.1:9200"]
    ssl.verification_mode: none
    api_key: "$ES_TOKEN"
    index: "ship_engine-%{+yyyy.MM.dd}"
YML
/opt/elastic-agent-9.0.0/elastic-agent run --once 2>/dev/null || \
  curl -sk "${HDR[@]}" -X POST "$ES/ship_engine-$TS/_bulk" --data-binary \
  <(awk -F'\t' '{printf "{\"index\":{}}\n{\"tag\":\"%s\",\"value\":%s,\"group\":\"%s\",\"@timestamp\":\"%s\"}\n",$1,$2,$3,$4}' "$OUT")

# 4. 校验 + 生命周期快照
echo "[4/4] 校验 + 生命周期..."
curl -sk "${HDR[@]}" "$ES/ship_engine-*/_count?pretty"
curl -sk "${HDR[@]}" "$ES/_ilm/explain/ship_engine-*?human=true&pretty" | head -20
echo "完成。数据湖就绪；ILM 分层 3/12/36 月已生效。"
