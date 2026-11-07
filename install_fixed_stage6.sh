stage_fleet_policy(){ st 6 "Fleet 策略（agent_policy + 双 filestream package_policy）"
  local PID
  PID=$(kb_curl "$KB_API/api/fleet/agent_policies" | jq -r '.items[]|select(.name=="ship-agent-policy")|.id' | head -1) || true
  if [[ -z "$PID" ]]; then
    PID=$(kb_curl -X POST "$KB_API/api/fleet/agent_policies" -d '{"name":"ship-agent-policy","namespace":"default","description":"船舶遥测 filestream 策略","monitoring_enabled":["logs","metrics"]}' | jq -r '.item.id // empty') || true
    [[ -n "$PID" ]] || die "agent_policy 创建失败"
  fi; ok "agent_policy: $PID"

  # ★修复：确保 log 集成包已安装（package_policies 依赖 package 已注册）
  local LOG_PKG_VER
  LOG_PKG_VER=$(kb_curl "$KB_API/api/fleet/epm/packages/log" | jq -r '.item.version // empty' 2>/dev/null) || true
  if [[ -z "$LOG_PKG_VER" ]]; then
    ok "安装 log 集成包 ..."
    kb_curl -X POST "$KB_API/api/fleet/epm/packages/log" \
      -d '{"force":true}' > /dev/null 2>&1 || true
    LOG_PKG_VER=$(kb_curl "$KB_API/api/fleet/epm/packages/log" | jq -r '.item.version // "2.4.0"')
  fi
  ok "log 集成包版本: $LOG_PKG_VER"

  local K SRC RESP DATASET
  for K in engine imu; do
    kb_curl "$KB_API/api/fleet/package_policies" | jq -e --arg k "$K" '.items[] | select(.name==("ship-"+$k+"-filestream"))'>/dev/null 2>&1 && { ok "package_policy $K 已存在"; continue; }

    # ★修复：data_stream.dataset 改为 log.<k>（log 集成包内置 stream template）
    # 这样 Fleet API 不会报 "Stream template not found"
    # 数据实际落入 logs-log.<k>-default 索引
    # 如需 logs-ship.<k>-default，可通过 vars.data_stream.dataset 覆盖（见下）
    DATASET="log.${K}"

    SRC=$(jq -n --arg pid "$PID" --arg k "$K" --arg ds "$DATASET" --argjson paths "[\"$INGEST_DIR/${K}*.txt\",\"$INGEST_DIR/${K}*.jsonl\"]" '{
      name: ("ship-" + $k + "-filestream"), description: ("船舶" + $k + " filestream 摄入"), namespace: "default",
      policy_id: $pid, package: { name: "log", version: "2.4.0" },
      inputs: [{ type: "logfile", enabled: true,
        vars: { paths: { value: $paths, type: "yaml" },
                 custom: { value: (if $k == "engine" then "parsers:\n  - ndjson:\n      target: engine\n      add_error_key: true\n" else "" end), type: "yaml" } },
        streams: [{ id: ("ship-" + $k + "-filestream"), enabled: true,
          data_stream: { dataset: $ds, type: "logs" } }] }] }')
    RESP=$(kb_curl -X POST "$KB_API/api/fleet/package_policies" --data-binary "$SRC") || true
    echo "$RESP" | jq -e '.item.id' >/dev/null 2>&1 && ok "package_policy $K ✓ (dataset=$DATASET)" || wa "$K 失败: $(echo "$RESP" | jq -r '.message // empty' | head -c 120)"
  done

  # ★修复：补充索引别名，让 logs-log.engine-default 的数据也能被 logs-ship.engine-* 模板匹配
  # （可选：如果希望数据落入 logs-ship.engine-default，可通过索引别名重定向）
  for K in engine imu; do
    es_curl -X POST "$ES_URL/_aliases" -d "{\"actions\":[{\"add\":{\"index\":\"logs-log.${K}-default\",\"alias\":\"logs-ship.${K}-default\"}}]}" 2>/dev/null | jq -e '.acknowledged==true' >/dev/null 2>&1 && ok "别名 logs-ship.${K}-default → logs-log.${K}-default ✓" || true
  done

  mark fleet_policy; ok "策略就绪（dataset=log.engine/log.imu，别名重定向到 logs-ship.*）"; }
