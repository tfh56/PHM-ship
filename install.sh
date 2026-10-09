#/!/usr/bin/env bash
# ============================================================================
#  deploy.sh — 船舶发动机诊断预测平台 · 可重入一键部署（读 ship.conf）
# ----------------------------------------------------------------------------
#  特性：断点续跑（状态文件 .deploy_state 记录已完成阶段，重跑自动跳过）
#  用法：bash deploy.sh            # 从首个未完成阶段继续
#        bash deploy.sh --redo 5   # 强制重跑第 5 阶段
#        bash deploy.sh --list     # 查看各阶段状态
#  阶段：1 环境检查  2 安装包  3 证书+ES  4 Kibana  5 管线+模板
#        6 Fleet 策略  7 Fleet Server  8 Agent 摄入  9 ML+告警  10 总览
# ============================================================================
set -Eeuo pipefail
CONF_FILE=$(realpath -m $(dirname $0))/ship.conf
[[ -f "$CONF_FILE" ]] || { echo "✗ 缺配置文件 ship.conf（与 deploy.sh 同目录）"; exit 1; }
# shellcheck source=ship.conf
source "$CONF_FILE"

ES_URL="https://localhost:${ES_PORT}"
KB_API="https://localhost:${KB_PORT}"
[[ -z "$MY_IP" ]] && MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); MY_IP="${MY_IP:-127.0.0.1}"
[[ -z "$ES_VERSION" ]] && ES_VERSION=$(curl -fsSL --max-time 15 https://api.github.com/repos/elastic/elasticsearch/releases/latest 2>/dev/null | jq -r '.tag_name' | sed 's/^v//' || true)
[[ "$ES_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ES_VERSION="9.5.4"
[[ -z "$INGEST_DIR" ]] && INGEST_DIR="$INSTALL_DIR/data/data-ingest"
PKG_DIR="$INSTALL_DIR/packages"; DATA_DIR="$INSTALL_DIR/data"; ES_DATA_DIR="$DATA_DIR/es"
LOG_DIR="$DATA_DIR/logs"; CONF_DIR="$INSTALL_DIR/conf"; RUN_DIR="$DATA_DIR/run"
ES_HOME="$INSTALL_DIR/elasticsearch-${ES_VERSION}"; KB_HOME="$INSTALL_DIR/kibana-${ES_VERSION}"
AGENT_STAGE="$AGENT_BASE/_staging"; AGENT_HOME="$AGENT_BASE/Elastic/Agent"
CRED_FILE="$INSTALL_DIR/.credentials"; STATE_FILE="$INSTALL_DIR/.deploy_state"
mkdir -p "$PKG_DIR" "$ES_DATA_DIR" "$LOG_DIR/es" "$LOG_DIR/kibana" "$LOG_DIR/fleet" "$RUN_DIR" "$INGEST_DIR" "$CONF_DIR" "$AGENT_BASE"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; N='\033[0m'
ok(){ echo -e "${G}[✓]${N} $*"; }
no(){ echo -e "${R}[✗]${N} $*" >&2; }
wa(){ echo -e "${Y}[!]${N} $*"; }
st(){ echo -e "\n${B}===== [阶段 $1] $2 =====${N}"; }
die(){ no "$*"; exit 1; }
es_curl(){ curl -sk -u "elastic:${ES_PASSWORD}" -H 'Content-Type: application/json' "$@"; }
kb_curl(){ curl -sk -u "elastic:${ES_PASSWORD}" -H 'Content-Type: application/json' -H 'kbn-xsrf: true' "$@"; }
es(){ es_curl "$@"; }
wait_http(){ local url=$1 secs=$2; local d=$((SECONDS+secs));
  while (( SECONDS < d )); do curl -sk -u "elastic:${ES_PASSWORD}" -o /dev/null --connect-timeout 3 --max-time 8 "$url" && return 0; echo -n "."; sleep 3; done; echo; return 1; }
rnd_pw(){ openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 32; }
[[ -z "$ES_PASSWORD" ]] && ES_PASSWORD=$(rnd_pw)

# ---- 可重入状态机 ----
STAGES="env install es kibana pipelines fleet_policy fleet_server agent ml done"
mark(){ echo "$1=ok" >> "$STATE_FILE"; }
done_yet(){ grep -q "^$1=ok" "$STATE_FILE" 2>/dev/null; }
show_list(){ echo "阶段进度（$STATE_FILE）：";
  local i=1 s
  for s in $STAGES; do
    if done_yet "$s"; then echo -e "  $i) $s  ${G}已完成${N}"
    else echo -e "  $i) $s  ${Y}未完成${N}"; fi; ((i++)); done; }

# ---- 阶段实现 ----
stage_env(){ st 1 "环境检查"
  [[ $(id -u) -eq 0 ]] && die "不要用 root 跑（ES 拒绝 root）"
  local miss=()
  for c in curl jq git tar openssl sudo python3; do command -v $c >/dev/null || miss+=($c); done
  ((${#miss[@]}==0)) || { sudo apt-get install -y -q "${miss[@]}" 2>/dev/null || sudo dnf install -y -q "${miss[@]}" || die "缺依赖：${miss[*]}"; }
  free -g 2>/dev/null | awk '/^Mem:/{if($2<8) print "  [!] 内存不足 8G，建议 ES_HEAP=700m"}'
  mark env; ok "环境就绪（IP=$MY_IP 版本=$ES_VERSION）"; }

stage_install(){ st 2 "下载安装包（幂等）"
  local TARS=("elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz" "kibana-${ES_VERSION}-linux-x86_64.tar.gz" "elastic-agent-${ES_VERSION}-linux-x86_64.tar.gz")
  local URLS=("elasticsearch" "kibana" "beats/elastic-agent")
  local i d
  for i in 0 1 2; do
    d=""
    case $i in 0) d="$ES_HOME";; 1) d="$KB_HOME";; 2) d="$AGENT_STAGE";; esac
    [[ -d $d && -x $d/bin/* || -d $d && -f $d/package.yaml ]] && { ok "$(basename $d) 已存在"; continue; }
    if [[ ! -f "$PKG_DIR/${TARS[$i]}" ]] || ! gzip -t "$PKG_DIR/${TARS[$i]}" 2>/dev/null; then
      rm -f "$PKG_DIR/${TARS[$i]}"
      ok "下载 ${TARS[$i]} ..."
      curl -fSL --retry 3 -o "$PKG_DIR/${TARS[$i]}" "https://artifacts.elastic.co/downloads/${URLS[$i]}/${TARS[$i]}" || die "下载失败"
    fi
    case $i in
      0|1) tar -xzf "$PKG_DIR/${TARS[$i]}" -C "$INSTALL_DIR" || die "解压失败";;
      2)   [[ -d "$AGENT_STAGE" ]] || { tar -xzf "$PKG_DIR/${TARS[$i]}" -C "$AGENT_BASE"; mv "$AGENT_BASE/elastic-agent-${ES_VERSION}-linux-x86_64" "$AGENT_STAGE"; };;
    esac
  done
  mark install; ok "安装包就绪"; }

stage_es(){ st 3 "证书 + 启动 Elasticsearch"
  if curl -sk -u "elastic:${ES_PASSWORD}" -o /dev/null "$ES_URL/_cluster/health"; then ok "ES 已在运行"; mark es; return 0; fi
  local CA="$ES_HOME/config/ship-ca.p12" TR="$ES_HOME/config/ship-tran.p12"
  [[ -s $CA && -s $TR ]] || {
    ok "生成自签 CA 与节点证书 ..."
    "$ES_HOME/bin/elasticsearch-certutil" ca   --ca-dn "c=cn,o=cssrc,cn=ship-ca" --days 3650 --out "$CA" --pass "$ES_PASSWORD" -s || die "CA 失败"
    "$ES_HOME/bin/elasticsearch-certutil" cert --name "ship-node" --dns "localhost,local,localdomain,*.local,${MY_IP}" --ip "127.0.0.1,${MY_IP}" \
      --days 1095 --out "$TR" --pass "$ES_PASSWORD" --ca "$CA" --ca-pass "$ES_PASSWORD" -s || die "节点证书失败"; }
  openssl pkcs12 -in "$CA" -passin "pass:$ES_PASSWORD" -nokeys -out "$ES_HOME/config/ship-ca.pem" >/dev/null 2>&1 || true
  openssl pkcs12 -in "$TR" -passin "pass:$ES_PASSWORD" -nokeys -out "$ES_HOME/config/ship-server.crt" >/dev/null 2>&1 || true
  openssl pkcs12 -in "$TR" -passin "pass:$ES_PASSWORD" -nocerts -nodes -out "$ES_HOME/config/ship-server.key" >/dev/null 2>&1 || true
  cat > "$ES_HOME/config/elasticsearch.yml" <<EOF
cluster.name: ship-cluster
node.name: ship-node-1
path.data: ${ES_DATA_DIR}
path.logs: ${LOG_DIR}/es
network.host: 0.0.0.0
http.port: ${ES_PORT}
discovery.type: single-node
xpack.security.enabled: true
xpack.security.enrollment.enabled: true
xpack.ml.enabled: true
xpack.security.http.ssl:
  enabled: true
  keystore.path: ship-tran.p12
  certificate_authorities: [ship-ca.pem]
xpack.security.transport.ssl:
  enabled: true
  keystore.path: ship-tran.p12
  certificate_authorities: [ship-ca.pem]
EOF
  mkdir -p "$ES_HOME/config/jvm.options.d"
  printf -- "-Xms%s\n-Xmx%s\n" "$ES_HEAP" "$ES_HEAP" > "$ES_HOME/config/jvm.options.d/ship.options"
  local KS="$ES_HOME/bin/elasticsearch-keystore"
  printf '%s' "$ES_PASSWORD" | "$KS" add -x -f 'bootstrap.password' || die "keystore 失败"
  printf '%s' "$ES_PASSWORD" | "$KS" add -x -f 'xpack.security.http.ssl.keystore.secure_password' || true
  printf '%s' "$ES_PASSWORD" | "$KS" add -x -f 'xpack.security.transport.ssl.keystore.secure_password' || true
  ok "启动 ES（首次 1-2 分钟）..."
  (cd "$ES_HOME" && ./bin/elasticsearch -d -p "$RUN_DIR/es.pid") || die "ES 启动失败"
  wait_http "$ES_URL/_cluster/health" 600 || die "ES 未就绪（日志 $LOG_DIR/es）"
  local code; code=$(curl -sk -o /dev/null -w '%{http_code}' -u "elastic:${ES_PASSWORD}" "$ES_URL/_security/_authenticate")
  [[ "$code" == 200 ]] || die "ES 认证失败（$code）"
  curl -sk -u "elastic:${ES_PASSWORD}" -X POST "$ES_URL/_security/user/kibana_system/_password" -H 'Content-Type: application/json' -d "{\"password\":\"$ES_PASSWORD\"}" >/dev/null || wa "kibana_system 改密未成功"
  { echo "ES_URL=$ES_URL"; echo "ES_PASSWORD=$ES_PASSWORD"; echo "KIBANA_URL=https://localhost:$KB_PORT"; } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  mark es; ok "ES 就绪（凭据 → $CRED_FILE）"; }

stage_kibana(){ st 4 "启动 Kibana"
  if curl -sk -o /dev/null "https://localhost:${KB_PORT}/api/status"; then ok "Kibana 已在运行"; mark kibana; return 0; fi
  cp -f "$ES_HOME/config/ship-server.crt" "$KB_HOME/config/"; cp -f "$ES_HOME/config/ship-server.key" "$KB_HOME/config/"; cp -f "$ES_HOME/config/ship-ca.pem" "$KB_HOME/config/"
  cat > "$KB_HOME/config/kibana.yml" <<EOF
server.port: ${KB_PORT}
server.host: "0.0.0.0"
server.publicBaseUrl: "https://${MY_IP}:${KB_PORT}"
server.ssl.enabled: true
server.ssl.certificate: config/ship-server.crt
server.ssl.key: config/ship-server.key
i18n.locale: "zh-CN"
elasticsearch.hosts: ["${ES_URL}"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${ES_PASSWORD}"
elasticsearch.ssl.verificationMode: full
elasticsearch.ssl.certificateAuthorities: ["config/ship-ca.pem"]
EOF
  (cd "$KB_HOME" && nohup ./bin/kibana > "$LOG_DIR/kibana/kibana.out" 2>&1 </dev/null & echo $! > "$RUN_DIR/kibana.pid")
  wait_http "https://localhost:${KB_PORT}/api/status" 1800 || die "Kibana 未就绪（$LOG_DIR/kibana/kibana.out）"
  mark kibana; ok "Kibana 就绪：https://${MY_IP}:${KB_PORT}"; }

# （阶段 5-9 的函数体见下方追加——保持文件可读性，此处先声明）

stage_pipelines(){ st 5 "数据管线（engine/imu 三条 pipeline + 回放自检）"
  local W; W=$(mktemp -d)
  cat > "$W/engine.painless" <<'P'
if (ctx.engine != null && ctx.engine.timestamp != null) {
  ctx['channel'] = ctx.engine.name;
  try { ctx['value'] = Double.parseDouble(String.valueOf(ctx.engine.value)); } catch (Exception e) {}
  double ts = Double.parseDouble(String.valueOf(ctx.engine.timestamp));
  ctx['@timestamp'] = Instant.ofEpochMilli(Math.round(ts * 1000.0)).toString();
  ctx.remove('engine');
}
P
  cat > "$W/imu_time.painless" <<'P'
long wk = 0L; double sow = 0D; String st = null;
if (ctx.gps != null && ctx.gps.week != null) {
  wk = ((Number) ctx.gps.week).longValue(); sow = ((Number) ctx.gps.sow).doubleValue(); st = "gps";
} else if (ctx.imu != null && ctx.imu.week != null) {
  wk = ((Number) ctx.imu.week).longValue(); sow = ((Number) ctx.imu.sow).doubleValue(); st = "imu";
}
if (st != null) {
  long ms = (315964800L + wk * 604800L) * 1000L + Math.round(sow * 1000.0) - __LEAP__;
  ctx['@timestamp']  = Instant.ofEpochMilli(ms).toString();
  ctx['sensor_type'] = st;
}
P
  sed "s/__LEAP__/$((GPS_LEAP_SECONDS * 1000))/" "$W/imu_time.painless" > "$W/imu_time.final"
  local G1 G2
  G1='[$]GTIMU,%{INT:imu.week:int},%{NUMBER:imu.sow:double},%{NUMBER:imu.gyro_x:double},%{NUMBER:imu.gyro_y:double},%{NUMBER:imu.gyro_z:double},%{NUMBER:imu.acc_x:double},%{NUMBER:imu.acc_y:double},%{NUMBER:imu.acc_z:double},%{NUMBER:imu.temp_c:double}[*]%{DATA:imu.checksum}'
  G2='[$]GPFPD,%{INT:gps.week:int},%{NUMBER:gps.sow:double},%{NUMBER:gps.heading:double},%{NUMBER:gps.pitch:double},%{NUMBER:gps.roll:double},%{NUMBER:gps.lat:double},%{NUMBER:gps.lon:double},%{NUMBER:gps.alt:double},%{NUMBER:gps.ve:double},%{NUMBER:gps.vn:double},%{NUMBER:gps.vu:double},%{NUMBER:gps.baseline:double},%{INT:gps.nsats:int},%{INT:gps.nsats2:int},%{INT:gps.status:int}[*]%{DATA:gps.checksum}'
  jq -n --rawfile s "$W/engine.painless" '{description:"engine jsonl -> channel/value/@timestamp",processors:[{script:{lang:"painless",source:$s}}]}' > "$W/p1.json"
  jq -n --rawfile t "$W/imu_time.final" --arg g "$G1" --arg p "$G2" '{description:"NMEA -> imu/gps, week+sow -> @timestamp",processors:[{grok:{field:"message",patterns:[$g],ignore_failure:true}},{grok:{field:"message",patterns:[$p],ignore_failure:true}},{script:{lang:"painless",source:$t}},{remove:{field:"message",ignore_missing:true,if:"ctx.sensor_type != null"}}]}' > "$W/p2.json"
  jq -n '{description:"router: engine->engine-telemetry / imu->imu-nmea",processors:[{pipeline:{name:"engine-telemetry",if:"ctx.engine != null",ignore_failure:true}},{pipeline:{name:"imu-nmea",if:"ctx.engine == null && ctx.message != null",ignore_failure:true}}]}' > "$W/p3.json"
  local f n
  for f in p1 p2 p3; do
    case $f in p1) n=engine-telemetry;; p2) n=imu-nmea;; p3) n=ship-router;; esac
    es_curl -X PUT "$ES_URL/_ingest/pipeline/$n" --data-binary @"$W/$f.json" | jq -e '.acknowledged==true' >/dev/null || { rm -rf "$W"; die "pipeline $n 创建失败"; }
    ok "pipeline $n ✓"; done
  # 回放自检
  local RESP1 RESP2
  RESP1=$(es_curl -X POST "$ES_URL/_ingest/pipeline/ship-router/_simulate" -d '{"docs":[{"_source":{"engine":{"name":"engine/no1_rpm","value":1024,"timestamp":1765842315.1}}}]}')
  echo "$RESP1" | jq -e '.docs[0].doc._source["@timestamp"] != null' >/dev/null || { rm -rf "$W"; die "engine 回放失败：$RESP1"; }
  ok "回放 engine 分支 ✓ $(echo "$RESP1" | jq -c '.docs[0].doc._source|{channel,value}')"
  RESP2=$(es_curl -X POST "$ES_URL/_ingest/pipeline/ship-router/_simulate" -d '{"docs":[{"_source":{"message":"$GTIMU,2397,144353.9600,-0.0170,-0.0363,0.0125,0.0221,0.0136,1.0026,30.9*56"}}]}')
  echo "$RESP2" | jq -e '.docs[0].doc._source["@timestamp"] != null' >/dev/null || { rm -rf "$W"; die "imu 回放失败：$RESP2"; }
  ok "回放 imu 分支 ✓ $(echo "$RESP2" | jq -c '.docs[0].doc._source|{sensor_type}')"
  rm -rf "$W"
  # 索引模板（logs-ship.* 双 pattern + default_pipeline=ship-router）
  local T
  for T in engine imu; do
    [[ -f "$CONF_DIR/${T}_tpl.json" ]] || jq -n --arg t "$T" '{
      index_patterns: [("ship-" + $t + "-metrics*"), ("logs-ship." + $t + "-*")],
      data_stream: {},
      template: { settings: { "index.default_pipeline": "ship-router" },
        mappings: { properties: {
          "@timestamp": {type:"date"}, channel: {type:"keyword"}, sensor_type: {type:"keyword"},
          value: {type:"double"},
          imu: {properties:{week:{type:"integer"},sow:{type:"double"},gyro_x:{type:"double"},gyro_y:{type:"double"},gyro_z:{type:"double"},acc_x:{type:"double"},acc_y:{type:"double"},acc_z:{type:"double"},temp_c:{type:"double"}}},
          gps: {properties:{week:{type:"integer"},sow:{type:"double"},heading:{type:"double"},pitch:{type:"double"},roll:{type:"double"},lat:{type:"double"},lon:{type:"double"},alt:{type:"double"}}} } } } }' > "$CONF_DIR/${T}_tpl.json"
    es_curl -X PUT "$ES_URL/_index_template/ship_${T}_tpl" --data-binary @"$CONF_DIR/${T}_tpl.json" | jq -e '.acknowledged==true' >/dev/null || wa "模板 $T PUT 失败"
    es_curl -X PUT "$ES_URL/_data_stream/ship-${T}-metrics" >/dev/null 2>&1 || true
  done
  mark pipelines; ok "管线+模板就绪（logs-ship.engine/imu-default → ship-router）"; }

stage_fleet_policy(){ st 6 "Fleet 策略（agent_policy + 双 filestream package_policy）"
  local PID
  PID=$(kb_curl "$KB_API/api/fleet/agent_policies?perPage=200" | jq -r '.items[]|select(.name=="ship-agent-policy")|.id' | head -1) || true
  if [[ -z "$PID" ]]; then
    PID=$(kb_curl -X POST "$KB_API/api/fleet/agent_policies" -d '{"name":"ship-agent-policy","namespace":"default","description":"船舶遥测 filestream 策略","monitoring_enabled":["logs","metrics"]}' | jq -r '.item.id // empty') || true
    [[ -n "$PID" ]] || die "agent_policy 创建失败"
  fi; ok "agent_policy: $PID"
  local K SRC RESP
  for K in engine imu; do
    kb_curl "$KB_API/api/fleet/package_policies" | jq -e --arg k "$K" '.items[] | select(.name==("ship-"+$k+"-filestream"))'>&/dev/null&&{ ok "package_policy $K 已存在"; continue; }
    SRC=$(jq -n --arg pid "$PID" --arg k "$K" --argjson paths "[\"$INGEST_DIR/${K}*.txt\",\"$INGEST_DIR/${K}*.jsonl\"]" '{
      name: ("ship-" + $k + "-filestream"), description: ("船舶" + $k + " filestream 摄入"), namespace: "default",
      policy_id: $pid, package: { name: "log", version: "2.4.0" },
      inputs: [{ type: "logfile", enabled: true,
        vars: { paths: { value: $paths, type: "yaml" },
                 custom: { value: (if $k == "engine" then "parsers:\n  - ndjson:\n      target: engine\n      add_error_key: true\n" else "" end), type: "yaml" } },
        streams: [{ id: ("ship-" + $k + "-filestream"), enabled: true,
          data_stream: { dataset: ("ship." + $k), type: "logs" } }] }] }')
    RESP=$(kb_curl -X POST "$KB_API/api/fleet/package_policies" --data-binary "$SRC") || true
    echo "$RESP" | jq -e '.item.id' >/dev/null 2>&1 && ok "package_policy $K ✓" || wa "$K 失败: $(echo "$RESP" | jq -r '.message // empty' | head -c 120)"
  done
  mark fleet_policy; ok "策略就绪"; }

stage_fleet_server(){ st 7 "Fleet Server（官方 install，systemd 服务）"
  if curl -sk -o /dev/null --connect-timeout 3 "https://localhost:${FLEET_PORT}/api/fleet/health"; then ok "Fleet Server 已在运行"; mark fleet_server; return 0; fi
  local TOKEN
  $ES_HOME/bin/elasticsearch-service-tokens delete -s elastic/fleet-server fleet-server-token>/dev/null
  TOKEN=$("$ES_HOME/bin/elasticsearch-service-tokens" create elastic/fleet-server fleet-server-token 2>/dev/null | awk '/^SERVICE_TOKEN/{print $NF}') || true
  [[ -n "$TOKEN" ]] || die "service token 创建失败"
  cp -f "$ES_HOME/config/ship-server.crt" "$AGENT_STAGE/" 2>/dev/null || true
  cp -f "$ES_HOME/config/ship-server.key" "$AGENT_STAGE/" 2>/dev/null || true
  local MODE
  if [[ -f "$AGENT_STAGE/ship-server.crt" ]]; then
    MODE="--fleet-server-cert=$AGENT_STAGE/ship-server.crt --fleet-server-cert-key=$AGENT_STAGE/ship-server.key"
  else MODE="--fleet-server-insecure-http"; wa "无证书 → 明文模式（内网可用）"; fi
  ok "执行官方 install（需 sudo，注册系统服务）..."
  if sudo "$AGENT_STAGE/elastic-agent" install \
      --fleet-server-es="$ES_URL" --fleet-server-service-token="$TOKEN" \
      --fleet-server-port="$FLEET_PORT" --fleet-server-es-insecure $MODE \
      --non-interactive --force 2>&1 | tail -12; then
    wait_http "https://localhost:${FLEET_PORT}/api/fleet/health" 300 && { mark fleet_server; ok "Fleet Server 就绪 :$FLEET_PORT"; return 0; }
  fi
  wa "install 失败（无 systemd？详见上方输出）——本阶段标记未完成，可重跑"; return 1; }

stage_agent(){ st 8 "数据摄入 Agent（独立模式，官方 install）"
  local YML="$CONF_DIR/elastic-agent.yml"
  cat > "$YML" <<EOF
outputs:
  default:
    type: elasticsearch
    hosts: ["${ES_URL}"]
    username: elastic
    password: "${ES_PASSWORD}"
    ssl.verification_mode: none
inputs:
  - id: engine-filestream
    type: filestream
    use_output: default
    data_stream.namespace: default
    streams:
      - data_stream: { type: logs, dataset: ship.engine }
        paths: ["${INGEST_DIR}/${ENGINE_PREFIX}*.txt", "${INGEST_DIR}/${ENGINE_PREFIX}*.jsonl"]
        parsers:
          - ndjson: { target: engine, add_error_key: true }
  - id: imu-filestream
    type: filestream
    use_output: default
    data_stream.namespace: default
    streams:
      - data_stream: { type: logs, dataset: ship.imu }
        paths: ["${INGEST_DIR}/${IMU_PREFIX}*.txt", "${INGEST_DIR}/${IMU_PREFIX}*.log"]
EOF
  ok "安装 Agent（systemd 服务，无特权模式）..."
  sudo "$AGENT_STAGE/elastic-agent" install \
    --install-servers --unprivileged --user "$(id -un)" --group "$(id -gn)" \
    --base-path "$AGENT_BASE" --non-interactive --force 2>&1 | tail -6 || die "Agent install 失败"
  sudo cp "$YML" "$AGENT_HOME/elastic-agent.yml"
  sudo chown "$(id -un):$(id -gn)" "$AGENT_HOME/elastic-agent.yml"
  sudo systemctl restart elastic-agent; sleep 12
  # 验证数据链
  local i N1=0
  for i in $(seq 1 15); do
    echo "{\"name\":\"engine/selftest_rpm\",\"value\":$((1000+i)),\"timestamp\":$(date +%s)}" >> "$INGEST_DIR/${ENGINE_PREFIX}selftest.txt"
    echo '$GTIMU,2397,144353.9600,-0.0170,-0.0363,0.0125,0.0221,0.0136,1.0026,30.9*56' >> "$INGEST_DIR/${IMU_PREFIX}selftest.txt"
  done
  for i in $(seq 1 6); do
    N1=$(es_curl "$ES_URL/logs-ship.engine-default/_count" | jq -r '.count // 0' 2>/dev/null) || N1=0
    (( N1 > 0 )) && break; sleep 10; done
  (( N1 > 0 )) || { wa "数据未落库——检查：sudo systemctl status elastic-agent；日志 $AGENT_HOME"; return 1; }
  mark agent; ok "数据链通：logs-ship.engine-default docs=$N1"; }

stage_ml(){ st 9 "ML 异常检测 + 告警"
  es_curl -X PUT "$ES_URL/_ml/anomaly_detectors/ship_engine_anomaly" -d '{
    "description": "发动机模拟量通道异常检测",
    "analysis": { "bucket_span": "15m",
      "detectors": [{ "function": "mean", "field_name": "value", "by_field_name": "channel" }],
      "data_description": { "time_field": "@timestamp" } },
    "datafeed_config": { "datafeed_id": "datafeed-ship_engine_anomaly",
      "indices": ["ship-engine-metrics*", "logs-ship.engine-*"],
      "query": { "bool": { "must_not": [ { "prefix": { "channel": "engine/alarm_" } } ] } } } }' >/dev/null 2>&1 || wa "ML 创建失败（可后补）"
  es_curl -X POST "$ES_URL/_ml/anomaly_detectors/ship_engine_anomaly/_open"  >/dev/null 2>&1 || true
  es_curl -X POST "$ES_URL/_ml/anomaly_detectors/ship_engine_anomaly/_start" -d '{}' >/dev/null 2>&1 || true
  ok "ML 异常检测已启动（Kibana→Machine Learning→Anomaly Detection）"
  es_curl -X PUT "$ES_URL/_watcher/watch/ship-engine-anomaly-alert" -d '{
    "trigger": { "schedule": { "interval": "5m" } },
    "input": { "search": { "request": { "indices": ["ship-engine-metrics*", "logs-ship.engine-*"],
      "body": { "size": 0, "query": { "bool": { "filter": [ {"range": {"@timestamp": {"gte": "now-15m"}}} ] } },
        "aggs": { "max_anom": { "max": { "field": "ml.anomaly_score" } } } } } } },
    "condition": { "compare": { "ctx.payload.aggregations.max_anom.value": { "gt": 75 } } },
    "actions": { "log": { "logging": { "text": "船舶发动机异常分数 {{ctx.payload.aggregations.max_anom.value}} 超阈值 75" } } } }' >/dev/null 2>&1 || wa "Watcher 失败（需 X-Pack 许可）"
  ok "告警 Watcher 已配置"; mark ml; }

stage_done(){ st 10 "部署完成总览"
  echo "  Kibana:   https://${MY_IP}:${KB_PORT}  （elastic / 密码见 $CRED_FILE）"
  echo "  数据入口: $INGEST_DIR（${ENGINE_PREFIX}*.txt=JSONL ｜ ${IMU_PREFIX}*.txt=NMEA）"
  echo "  数据流:   logs-ship.engine-default / logs-ship.imu-default"
  echo "  Agent:    sudo systemctl status elastic-agent"
  echo "  ML:       Kibana → Machine Learning → ship_engine_anomaly"
  echo "  续跑/重跑: bash deploy.sh --list 看进度；--redo N 重跑某阶段"
  mark done; }

# ---- main ----
main(){
  case "${1:--run}" in
    --list) show_list; exit 0;;
    --redo) grep -v "^$2=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" || true; shift 2;;
  esac
  show_list
  local order=(stage_env stage_install stage_es stage_kibana stage_pipelines stage_fleet_policy stage_agent stage_ml stage_done)
  local names=(env install es kibana pipelines fleet_policy agent ml done)
  local i
  for i in "${!order[@]}"; do
    if done_yet "${names[$i]}"; then wa "阶段 $((i+1)) ${names[$i]} 已完成，跳过"; continue; fi
    ${order[$i]} || { no "阶段 $((i+1)) ${names[$i]} 失败——修复后重跑 bash deploy.sh（已完成阶段自动跳过）"; exit 1; }
  done
}
main "$@"
