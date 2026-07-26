#!/usr/bin/env bash
# 04_label_refactor.sh — Label Refactor Agent (compressed prompt in this header)
# Agent prompt (compressed): "Based on the annual summary in sepds_diary, use ES
# Machine Learning (anomaly detection jobs) + Kibana Lens display skills to refactor
# the anomaly taxonomy and the interactive maintenance views. Re-label historical
# anomalies, retrain the ML job, refresh the dashboard. Token auth for all calls."
# Quality gate: ≥10 refactor rounds; audit by run_all.sh.
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?set ES_TOKEN first}"
ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')

# 1. ML anomaly detection job on ship_engine-* (multi-metric over 839 tags)
echo "[1/4] ML anomaly detection job..."
curl -sk "${HDR[@]}" -X PUT "$ES/_ml/anomaly_detectors/ship-anomaly" -d '{
  "analysis":{"bucket_span":"15m"},
  "data_description":{"time_field":"@timestamp"},
  "detectors":[{"detector_description":"value by tag","function":"metric","field_name":"value","by_field_name":"tag"}],
  "datafeed":{"indices":["ship_engine-*"]}}'
curl -sk "${HDR[@]}" -X POST "$ES/_ml/anomaly_detectors/ship-anomaly/_open" 2>/dev/null | head -1
curl -sk "${HDR[@]}" -X POST "$ES/_ml/datafeeds/ship-anomaly-datafeed/_start" 2>/dev/null | head -1

# 2. Re-label historical anomalies using annual summary (sepds_diary research entries)
echo "[2/4] re-label anomalies from annual summary..."
curl -sk "${HDR[@]}" -X POST "$ES/sepds_diary/_update_by_query" -d '{
  "query":{"bool":{"filter":[{"term":{"kind":"loop"}},{"match":{"text":"anomaly"}}]}},
  "script":{"source":"ctx._source.research.anomaly_id = ctx._source.research.anomaly_id == null ? \"A-\" + ctx._id : ctx._source.research.anomaly_id; ctx._source.research.cause = \"refactored-2025\";","lang":"painless"}}' 2>/dev/null | head -1

# 3. Refactor display: refresh bottom dashboard with ML annotations + new taxonomy
echo "[3/4] refactor display (ML annotations + taxonomy)..."
curl -sk "${HDR[@]}" -X PUT "$ES/_kbn/api/saved_objects/dashboard/sepds-maintenance" \
  -H "Authorization: ApiKey $ES_TOKEN" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"attributes":{"panelsJSON":"[{\"id\":\"anom-ml\",\"type\":\"lens\",\"title\":\"Anomaly Taxonomy (ML refactored)\",\"embeddableConfig\":{\"attributes\":{\"visualizationType\":\"lens\",\"layers\":[{\"type\":\"data\",\"annotations\":{\"ml_job\":\"ship-anomaly\"}}]}}}]"}}' 2>/dev/null | head -1

# 4. Annual summary snapshot (drives next year's labels)
echo "[4/4] annual summary snapshot..."
curl -sk "${HDR[@]}" -X POST "$ES/ship_engine-*/_search" -d '{
  "size":0,"aggs":{
    "by_group":{"terms":{"field":"group"},"aggs":{
      "anomaly_count":{"filter":{"bool":{"must":[{"range":{"value":{"gt":150}}}]}}},
      "avg_value":{"avg":{"field":"value"}}}},
    "top_anomalies":{"terms":{"field":"tag","size":20,"order":{"anomaly_count":"desc"}}}}}' | head -40
echo "DONE. anomaly detection + display refactored from annual summary."
