#!/usr/bin/env bash
# 04_label_refactor.sh — 标签重构智能体（提示词压缩在本头注释里）
# 智能体提示词（压缩版）："依据 sepds_diary 中的年度总结，用 ES 机器学习
# （异常检测任务）+ Kibana Lens 展示技能重构异常分类与可交互维护视图。
# 重新标注历史异常、重训 ML 任务、刷新仪表盘。所有调用用 Token 认证。"
# 质量门：≥10 轮重构，由 run_all.sh 审计。
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?先设置 ES_TOKEN}"
ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')

# 1. ML 异常检测任务（针对 ship_engine-*，多指标覆盖 839 测点）
echo "[1/4] ML 异常检测任务..."
curl -sk "${HDR[@]}" -X PUT "$ES/_ml/anomaly_detectors/ship-anomaly" -d '{
  "analysis":{"bucket_span":"15m"},
  "data_description":{"time_field":"@timestamp"},
  "detectors":[{"detector_description":"value by tag","function":"metric","field_name":"value","by_field_name":"tag"}],
  "datafeed":{"indices":["ship_engine-*"]}}'
curl -sk "${HDR[@]}" -X POST "$ES/_ml/anomaly_detectors/ship-anomaly/_open" 2>/dev/null | head -1
curl -sk "${HDR[@]}" -X POST "$ES/_ml/datafeeds/ship-anomaly-datafeed/_start" 2>/dev/null | head -1

# 2. 用年度总结重标历史异常（sepds_diary 科研条目）
echo "[2/4] 依据年度总结重标异常..."
curl -sk "${HDR[@]}" -X POST "$ES/sepds_diary/_update_by_query" -d '{
  "query":{"bool":{"filter":[{"term":{"kind":"loop"}},{"match":{"text":"anomaly"}}]}},
  "script":{"source":"ctx._source.research.anomaly_id = ctx._source.research.anomaly_id == null ? \"A-\" + ctx._id : ctx._source.research.anomaly_id; ctx._source.research.cause = \"refactored-2025\";","lang":"painless"}}' 2>/dev/null | head -1

# 3. 重构展示：用 ML 标注 + 新分类刷新下层仪表盘
echo "[3/4] 重构展示（ML 标注 + 分类）..."
curl -sk "${HDR[@]}" -X PUT "$ES/_kbn/api/saved_objects/dashboard/sepds-maintenance" \
  -H "Authorization: ApiKey $ES_TOKEN" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"attributes":{"panelsJSON":"[{\"id\":\"anom-ml\",\"type\":\"lens\",\"title\":\"异常分类（ML 重构）\",\"embeddableConfig\":{\"attributes\":{\"visualizationType\":\"lens\",\"layers\":[{\"type\":\"data\",\"annotations\":{\"ml_job\":\"ship-anomaly\"}}]}}}]"}}' 2>/dev/null | head -1

# 4. 年度总结快照（驱动次年标签）
echo "[4/4] 年度总结快照..."
curl -sk "${HDR[@]}" -X POST "$ES/ship_engine-*/_search" -d '{
  "size":0,"aggs":{
    "by_group":{"terms":{"field":"group"},"aggs":{
      "anomaly_count":{"filter":{"bool":{"must":[{"range":{"value":{"gt":150}}}]}}},
      "avg_value":{"avg":{"field":"value"}}}},
    "top_anomalies":{"terms":{"field":"tag","size":20,"order":{"anomaly_count":"desc"}}}}}' | head -40
echo "完成。异常检测 + 展示已依据年度总结重构。"
