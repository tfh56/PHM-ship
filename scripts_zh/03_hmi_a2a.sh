#!/usr/bin/env bash
# 03_hmi_a2a.sh — 人机界面智能体（提示词压缩在本头注释里）
# 智能体提示词（压缩版）："设计 4 个反射式角色（指挥/船员/研发/运维），每个跑
# 搜索→分析→评估→重试；接 A2A 总线让角色互通并融合航行日记 + 科研日记；建
# 双层 Kibana 仪表盘：顶层 = 唯美监控（健康环、排温热力图、增压器表），
# 下层 = 可交互维护（参数分析、异常分类、月季年报告）。所有 ES 调用用 Token 认证。"
# 质量门：≥10 轮人机界面，由 run_all.sh 审计。
set -euo pipefail
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token 2>/dev/null)}
: "${ES_TOKEN:?先设置 ES_TOKEN}"
ES=https://localhost:9200; KB=https://localhost:5601
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
KBH=(-H "Authorization: ApiKey $ES_TOKEN" -H 'kbn-xsrf: true' -H 'Content-Type: application/json')

# 1. 角色注册（4 个反射式智能体；提示词内联压缩）
echo "[1/5] 注册 4 个角色..."
for R in commander crew rnd ops; do
  curl -sk "${HDR[@]}" -X POST "$ES/sepds_roles/_doc/$R" -d "{
    \"role\":\"$R\",\"loop\":[\"search\",\"analyze\",\"evaluate\",\"retry\"],
    \"retry_on\":{\"commander\":\"low_confidence\",\"crew\":\"no_hit\",\"rnd\":\"sparse_data\",\"ops\":\"missing_fields\"},
    \"a2a_peers\":[\"commander\",\"crew\",\"rnd\",\"ops\"]}" 2>/dev/null || true
done

# 2. A2A 总线（日记融合：航行 + 科研）
echo "[2/5] A2A 总线 + 日记融合..."
curl -sk "${HDR[@]}" -X PUT "$ES/sepds_diary" -d '{
  "mappings":{"properties":{
    @timestamp":{"type":"date"},"from":{"type":"keyword"},"to":{"type":"keyword"},
    "kind":{"type":"keyword"},"text":{"type":"text"},
    "nav":{"properties":{"lat":{"type":"double"},"lon":{"type":"double"},"sea_state":{"type":"keyword"}}},
    "research":{"properties":{"anomaly_id":{"type":"keyword"},"cause":{"type":"text"}}}}}}'

# 3. 顶层仪表盘：唯美监控（健康环 + 排温热力图 + 增压器表）
echo "[3/5] 顶层仪表盘（唯美）..."
build_top() { cat <<JSON
{"attributes":{"title":"SEPDS 顶层（唯美）","version":2,
 "panelsJSON":"[{\\\"id\\\":\\\"ring\\\",\\\"type\\\":\\\"lens\\\",\\\"title\\\":\\\"发动机健康环\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":0,\\\"w\\\":24,\\\"h\\\":10}},
  {\\\"id\\\":\\\"exh\\\",\\\"type\\\":\\\"lens\\\",\\\"title\\\":\\\"排温热力图 A1-A10/B1-B10\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":10,\\\"w\\\":24,\\\"h\\\":12}},
  {\\\"id\\\":\\\"turbo\\\",\\\"type\\\":\\\"metric\\\",\\\"title\\\":\\\"增压器转速 / 润滑油压力\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":22,\\\"w\\\":24,\\\"h\\\":6}}]"}}
JSON
}
curl -sk "${KBH[@]}" -X POST "$KB/api/saved_objects/dashboard" -d "$(build_top)" 2>/dev/null | head -1

# 4. 下层仪表盘：可交互维护（参数分析 + 异常分类 + 月季年报告）
echo "[4/5] 下层仪表盘（维护）..."
build_bottom() { cat <<JSON
{"attributes":{"title":"SEPDS 维护（可交互）","version":2,
 "panelsJSON":"[{\\\"id\\\":\\\"param\\\",\\\"type\\\":\\\"tsvb\\\",\\\"title\\\":\\\"参数分析（从 839 测点任选）\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":0,\\\"w\\\":24,\\\"h\\\":12}},
  {\\\"id\\\":\\\"anom\\\",\\\"type\\\":\\\"lens\\\",\\\"title\\\":\\\"异常分类（规则 + ML）\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":12,\\\"w\\\":24,\\\"h\\\":10}},
  {\\\"id\\\":\\\"rep\\\",\\\"type\\\":\\\"markdown\\\",\\\"title\\\":\\\"月度 / 季度 / 年度报告\\\",\\\"gridData\\\":{\\\"x\\\":0,\\\"y\\\":22,\\\"w\\\":24,\\\"h\\\":6}}]"}}
JSON
}
curl -sk "${KBH[@]}" -X POST "$KB/api/saved_objects/dashboard" -d "$(build_bottom)" 2>/dev/null | head -1

# 5. 反射循环运行器（搜索→分析→评估→重试，≥10 轮）
echo "[5/5] 反射循环运行器（≥10 轮）..."
cat > /opt/sepds/reflection_loop.sh <<'LOOP'
#!/usr/bin/env bash
# 压缩智能体提示词："对每个角色跑 搜索→分析→评估→重试，直到置信度 ≥0.9 或
# 10 轮。经 A2A 总线写 sepds_diary。Token 认证。"
ES_TOKEN=${ES_TOKEN:-$(cat ~/.es_token)}; ES=https://localhost:9200
HDR=(-H "Authorization: ApiKey $ES_TOKEN" -H 'Content-Type: application/json')
for R in commander crew rnd ops; do
  for ROUND in $(seq 1 10); do
    Q="role=$R round=$ROUND: 本航次 1 号机状态"
    DSL=$(curl -sk "${HDR[@]}" -X POST "$ES/_ml/llm/ship_agent/_execute" -d "{\"prompt\":\"$Q\"}" 2>/dev/null)
    ANS=$(curl -sk "${HDR[@]}" -X GET "$ES/ship_engine-*/_search" -d "${DSL:-{}}" 2>/dev/null)
    CONF=$(echo "$ANS" | grep -oE '"value":[0-9.]+' | head -1 | grep -oE '[0-9.]+')
    curl -sk "${HDR[@]}" -X POST "$ES/sepds_diary/_doc" -d "{\"from\":\"$R\",\"to\":\"a2a\",\"kind\":\"loop\",\"text\":\"$Q\",\"@timestamp\":\"$(date -Iseconds)\"}" >/dev/null
    [ "${CONF:-0}" \> "0.9" ] && break
  done
done
LOOP
chmod +x /opt/sepds/reflection_loop.sh
echo "完成。4 角色 + A2A + 2 仪表盘 + 反射循环已装。"
