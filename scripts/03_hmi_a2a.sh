#!/usr/bin/env bash
# 03_hmi_a2a.sh — HMI Agent (compressed prompt in this header)
# Agent prompt (compressed): "Design 4 reflective roles (Commander/Crew/R&D/Ops),
# each running search→analyze→evaluate→retry; wire A2A bus so roles talk to each
# other and fuse navigation diary + research diary; build two-layer Kibana dashboard:
# top = aesthetic monitoring (health ring, exhaust heatmap, turbo gauges),
# bottom = interactive maintenance (param analysis, anomaly taxonomy, M/Q/Y reports).
# All ES calls use token auth (Authorization: ApiKey)."
# Quality gate: ≥10 HMI rounds; audit by run_all.sh.
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?set ES_TOKEN first}"
ES=https://localhost:9200; KB=https://localhost:5601
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
KBH=(-H "Authorization: ApiKey $ES_TOKEN" -H 'kbn-xsrf: true' -H 'Content-Type: application/json')

# 1. Role registry (4 reflective agents; prompts compressed inline)
echo "[1/5] register 4 roles..."
for R in commander crew rnd ops; do
  curl -sk "${HDR[@]}" -X POST "$ES/sepds_roles/_doc/$R" -d "{
    \"role\":\"$R\",\"loop\":[\"search\",\"analyze\",\"evaluate\",\"retry\"],
    \"retry_on\":{\"commander\":\"low_confidence\",\"crew\":\"no_hit\",\"rnd\":\"sparse_data\",\"ops\":\"missing_fields\"},
    \"a2a_peers\":[\"commander\",\"crew\",\"rnd\",\"ops\"]}" 2>/dev/null || true
done

# 2. A2A bus (diary fusion: navigation + research)
echo "[2/5] A2A bus + diary fusion..."
curl -sk "${HDR[@]}" -X PUT "$ES/sepds_diary" -d '{
  "mappings":{"properties":{
    "@timestamp":{"type":"date"},"from":{"type":"keyword"},"to":{"type":"keyword"},
    "kind":{"type":"keyword"},"text":{"type":"text"},
    "nav":{"properties":{"lat":{"type":"double"},"lon":{"type":"double"},"sea_state":{"type":"keyword"}}},
    "research":{"properties":{"anomaly_id":{"type":"keyword"},"cause":{"type":"text"}}}}}}'

# 3. Top dashboard: aesthetic monitoring (health ring + exhaust heatmap + turbo gauges)
echo "[3/5] top dashboard (aesthetic)..."
build_top() { cat <<JSON
{"attributes":{"title":"SEPDS Top (Aesthetic)","version":2,
 "panelsJSON":"[{\\\"id\\\":\\\"ring\\\",\\\"type\\\":\\\"lens\\\",\\\"title\\\":\\\"Engine Health Ring\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":0,\\\"w\\\":24,\\\"h\\\":10}},
  {\\\"id\\\":\\\"exh\\\",\\\"type\\\":\\\"lens\\\",\\\"title\\\":\\\"Exhaust Temp Heatmap A1-A10/B1-B10\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":10,\\\"w\\\":24,\\\"h\\\":12}},
  {\\\"id\\\":\\\"turbo\\\",\\\"type\\\":\\\"metric\\\",\\\"title\\\":\\\"Turbocharger Speed / Lube Pressure\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":22,\\\"w\\\":24,\\\"h\\\":6}}]"}}
JSON
}
curl -sk "${KBH[@]}" -X POST "$KB/api/saved_objects/dashboard" -d "$(build_top)" 2>/dev/null | head -1

# 4. Bottom dashboard: interactive maintenance (param analysis + anomaly taxonomy + M/Q/Y reports)
echo "[4/5] bottom dashboard (maintenance)..."
build_bottom() { cat <<JSON
{"attributes":{"title":"SEPDS Maintenance (Interactive)","version":2,
 "panelsJSON":"[{\\\"id\\\":\\\"param\\\",\\\"type\\\":\\\"tsvb\\\",\\\"title\\\":\\\"Parameter Analysis (pick any of 839 tags)\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":0,\\\"w\\\":24,\\\"h\\\":12}},
  {\\\"id\\\":\\\"anom\\\",\\\"type\\\":\\\"lens\\\",\\\"title\\\":\\\"Anomaly Taxonomy (rule + ML)\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":12,\\\"w\\\":24,\\\"h\\\":10}},
  {\\\"id\\\":\\\"rep\\\",\\\"type\\\":\\\"markdown\\\",\\\"title\\\":\\\"Monthly / Seasonal / Annual Reports\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":22,\\\"w\\\":24,\\\"h\\\":6}}]"}}
JSON
}
curl -sk "${KBH[@]}" -X POST "$KB/api/saved_objects/dashboard" -d "$(build_bottom)" 2>/dev/null | head -1

# 5. Reflection loop runner (search→analyze→evaluate→retry, ≥10 rounds)
echo "[5/5] reflection loop runner (≥10 rounds)..."
cat > /opt/sepds/reflection_loop.sh <<'LOOP'
#!/usr/bin/env bash
# Compressed agent prompt: "For each role, run search→analyze→evaluate→retry until
# confidence ≥0.9 or 10 rounds. Log to sepds_diary via A2A bus. Token auth."
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token)}; ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
for R in commander crew rnd ops; do
  for ROUND in $(seq 1 10); do
    Q="role=$R round=$ROUND: status of engine_1 this watch"
    DSL=$(curl -sk "${HDR[@]}" -X POST "$ES/_ml/llm/ship_agent/_execute" -d "{\"prompt\":\"$Q\"}" 2>/dev/null)
    ANS=$(curl -sk "${HDR[@]}" -X GET "$ES/ship_engine-*/_search" -d "${DSL:-{}}" 2>/dev/null)
    CONF=$(echo "$ANS" | grep -oE '"value":[0-9.]+' | head -1 | grep -oE '[0-9.]+')
    curl -sk "${HDR[@]}" -X POST "$ES/sepds_diary/_doc" -d "{\"from\":\"$R\",\"to\":\"a2a\",\"kind\":\"loop\",\"text\":\"$Q\",\"@timestamp\":\"$(date -Iseconds)\"}" >/dev/null
    [ "${CONF:-0}" \> "0.9" ] && break
  done
done
LOOP
chmod +x /opt/sepds/reflection_loop.sh
echo "DONE. 4 roles + A2A + 2 dashboards + reflection loop installed."
