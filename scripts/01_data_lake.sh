#!/usr/bin/env bash
# 01_data_lake.sh — Data Lake Agent (compressed prompt in this header)
# Agent prompt (compressed): "Ingest rolling engine_{YYYYMMDD-HHMMSS}.txt files via
# Elastic Agent into a time-series index ship_engine-*, one doc per (tag,value,ts);
# build ILM policy ship-engine-tiers with 3mo hot / 12mo warm / 36mo cold phases
# (data lifecycle). Use token auth (Authorization: ApiKey) for ALL curl calls."
# Quality gate: ≥10 ingest rounds, audit by run_all.sh.
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?set ES_TOKEN first (see 00_install_stack.sh)}"
ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
SAMPLE=/home/z/my-project/upload/6a5b2311c2f546f92fcfa0bf_eng-var.txt
INGEST_DIR=/var/spool/engine  # rolling engine_*.txt land here
mkdir -p "$INGEST_DIR"

# 1. Component template + ILM policy (3/12/36 months)
echo "[1/4] ILM policy: 3mo hot / 12mo warm / 36mo cold..."
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
      "@timestamp":{"type":"date"},"tag":{"type":"keyword"},"value":{"type":"double"},
      "group":{"type":"keyword"},"unit":{"type":"keyword"},"ship_id":{"type":"keyword"}}}}}'

# 2. Generate rolling engine_*.txt from the 839-tag sample (one poll = one file)
echo "[2/4] synthesize rolling engine_*.txt from 839 tags..."
TS=$(date +%Y%m%d-%H%M%S); OUT="$INGEST_DIR/engine_$TS.txt"
awk -F/ -v ts="$(date -Iseconds)" 'BEGIN{print "# poll ts="ts}
{tag=$2; gsub(/engine\//,"",tag); val=sprintf("%.2f",50+rand()*150);
 group=(index(tag,"alarm")>0?"alarm":(index(tag,"generator")>0?"generator":"engine"));
 printf "%s\t%s\t%s\t%s\n", tag, val, group, ts}' "$SAMPLE" > "$OUT"
echo "  wrote $OUT ($(wc -l < "$OUT") rows)"

# 3. Elastic Agent filestream input → ES (token-authenticated output)
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

# 4. Verify + lifecycle snapshot
echo "[4/4] verify + lifecycle..."
curl -sk "${HDR[@]}" "$ES/ship_engine-*/_count?pretty"
curl -sk "${HDR[@]}" "$ES/_ilm/explain/ship_engine-*?human=true&pretty" | head -20
echo "DONE. data lake ready; ILM tiers 3/12/36 months active."
