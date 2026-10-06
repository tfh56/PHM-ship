#!/usr/bin/env bash
# ============================================================================
#  manual_ops.sh — 人工逐条命令操作版（与 deploy.sh 同序列，读同一份 ship.conf）
# ----------------------------------------------------------------------------
#  每一步：打印【说明】+【命令】→ 回车执行；s=跳过，q=退出，c=仅复制不执行
#  适合：需要在每步检查输出、人工把关的教学/验收场景
# ============================================================================
set -uo pipefail
CONF_FILE=$(realpath -m $(dirname "$0"))/ship.conf
[[ -f "$CONF_FILE" ]] || { echo "✗ 缺 ship.conf"; exit 1; }
source "$CONF_FILE"

ES_HOST="https://localhost:${ES_PORT}"; ES_URL="$ES_HOST"; KB_API="https://localhost:${KB_PORT}"
[[ -z "$MY_IP" ]] && MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); MY_IP="${MY_IP:-127.0.0.1}"
[[ -z "$ES_VERSION" ]] && ES_VERSION="9.5.4"
[[ -z "$ES_PASSWORD" ]] && ES_PASSWORD=$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 32)
[[ -z "$INGEST_DIR" ]] && INGEST_DIR="$INSTALL_DIR/data/data-ingest"
PKG_DIR="$INSTALL_DIR/packages"; ES_DATA_DIR="$INSTALL_DIR/data/es"; LOG_DIR="$INSTALL_DIR/data/logs"
CONF_DIR="$INSTALL_DIR/conf"; RUN_DIR="$INSTALL_DIR/data/run"
ES_HOME="$INSTALL_DIR/elasticsearch-${ES_VERSION}"; KB_HOME="$INSTALL_DIR/kibana-${ES_VERSION}"
AGENT_STAGE="$AGENT_BASE/_staging"; AGENT_HOME="$AGENT_BASE/Elastic/Agent"
mkdir -p "$PKG_DIR" "$ES_DATA_DIR" "$LOG_DIR/es" "$LOG_DIR/kibana" "$LOG_DIR/fleet" "$RUN_DIR" "$INGEST_DIR" "$CONF_DIR" "$AGENT_BASE"

G='\033[0;32m'; B='\033[0;34m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
STEP=0
run_step(){  # run_step "说明" "命令"
  STEP=$((STEP+1))
  local desc=$1 cmd=$2 ans
  echo -e "\n${B}━━━ 步骤 $STEP ━━━${N}"
  echo -e "${C}说明：${N}$desc"
  echo "${C}命令：${N}${Y}$cmd${N}"
  read -rp "  [Enter=执行 | s=跳过 | c=复制不执行 | q=退出] " ans || ans=q
  case "${ans:-}" in
    q|Q) echo "已退出（进度记住步骤号，下次从本步骤继续）"; exit 0;;
    s|S) echo "  ↷ 跳过"; return 0;;
    c|C) echo "  已显示命令（复制上方黄色部分执行）"; return 0;;
  esac
  echo -e "  ${G}$ ${N}$cmd"
  eval "$cmd"
  local rc=$?
  (( rc == 0 )) && echo -e "  ${G}[✓ rc=0]${N}" || echo -e "  \033[0;31m[✗ rc=$rc —— 请检查输出再继续]${N}"
  return $rc
}

cat <<BANNER
${B}╔══════════════════════════════════════════════════════════════╗
║   船舶发动机诊断预测平台 · 人工逐条操作模式                     ║
║   配置：$CONF_FILE                                              ║
║   密码：$ES_PASSWORD（自动生成，全程复用）                      ║
║   IP：$MY_IP    版本：$ES_VERSION                               ║
╚══════════════════════════════════════════════════════════════╝${N}
BANNER

# ─────────── 一、环境与下载 ───────────
run_step "检查依赖（curl/jq/git/openssl 等）" \
  'for c in curl jq git tar openssl sudo python3; do command -v $c >/dev/null && echo "✓ $c" || echo "✗ 缺 $c"; done'
run_step "创建目录结构" \
  "mkdir -p $PKG_DIR $ES_DATA_DIR $LOG_DIR/es $LOG_DIR/kibana $RUN_DIR $INGEST_DIR $CONF_DIR"
run_step "下载 Elasticsearch（约 700MB，断点续传可用 curl -C -）" \
  "curl -fSL --retry 3 -C - -o $PKG_DIR/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
run_step "解压 Elasticsearch" \
  "tar -xzf $PKG_DIR/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz -C $INSTALL_DIR"
run_step "下载 Kibana" \
  "curl -fSL --retry 3 -C - -o $PKG_DIR/kibana-${ES_VERSION}-linux-x86_64.tar.gz https://artifacts.elastic.co/downloads/kibana/kibana-${ES_VERSION}-linux-x86_64.tar.gz"
run_step "解压 Kibana" \
  "tar -xzf $PKG_DIR/kibana-${ES_VERSION}-linux-x86_64.tar.gz -C $INSTALL_DIR"
run_step "下载 Elastic Agent" \
  "curl -fSL --retry 3 -C - -o $PKG_DIR/elastic-agent-${ES_VERSION}-linux-x86_64.tar.gz https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ES_VERSION}-linux-x86_64.tar.gz"
run_step "解压 Agent 到 $AGENT_STAGE" \
  "mkdir -p $AGENT_BASE && tar -xzf $PKG_DIR/elastic-agent-${ES_VERSION}-linux-x86_64.tar.gz -C $AGENT_BASE && rm -rf $AGENT_STAGE && mv $AGENT_BASE/elastic-agent-${ES_VERSION}-linux-x86_64 $AGENT_STAGE"

# ─────────── 二、证书与 ES ───────────
run_step "生成自签 CA（10 年）" \
  "rm -f $ES_HOME/config/ship-ca.p12 && $ES_HOME/bin/elasticsearch-certutil ca --ca-dn \"c=cn,o=cssrc,cn=ship-ca\" --days 3650 --out $ES_HOME/config/ship-ca.p12 --pass $ES_PASSWORD -s"
run_step "签发节点证书（SAN 含本机 IP）" \
  "rm $ES_HOME/config/ship-tran.p12 && $ES_HOME/bin/elasticsearch-certutil cert --name ship-node --dns \"localhost,local,${MY_IP}\" --ip \"127.0.0.1,${MY_IP}\" --days 1095 --out $ES_HOME/config/ship-tran.p12 --pass $ES_PASSWORD --ca $ES_HOME/config/ship-ca.p12 --ca-pass $ES_PASSWORD -s"
run_step "导出 PEM（Kibana/Agent 要用）" \
  "openssl pkcs12 -in $ES_HOME/config/ship-ca.p12 -passin pass:$ES_PASSWORD -nokeys -out $ES_HOME/config/ship-ca.pem && openssl pkcs12 -in $ES_HOME/config/ship-tran.p12 -passin pass:$ES_PASSWORD -nokeys -out $ES_HOME/config/ship-server.crt && openssl pkcs12 -in $ES_HOME/config/ship-tran.p12 -passin pass:$ES_PASSWORD -nocerts -nodes -out $ES_HOME/config/ship-server.key"
run_step "写 elasticsearch.yml（说明：写入后看一眼确认端口/路径）" \
  "printf 'cluster.name: ship-cluster\nnode.name: ship-node-1\npath.data: %s\npath.logs: %s/es\nnetwork.host: 0.0.0.0\nhttp.port: %s\ndiscovery.type: single-node\nxpack.security.enabled: true\nxpack.security.http.ssl.enabled: true\nxpack.security.http.ssl.keystore.path: ship-tran.p12\nxpack.security.http.ssl.certificate_authorities: [ship-ca.pem]\nxpack.security.transport.ssl.enabled: true\nxpack.security.transport.ssl.keystore.path: ship-tran.p12\n' $ES_DATA_DIR $LOG_DIR $ES_PORT > $ES_HOME/config/elasticsearch.yml && cat $ES_HOME/config/elasticsearch.yml"
run_step "写堆内存（外行按机器改：小机 700m 大机 2g）" \
  "printf -- '-Xms$ES_HEAP\n-Xmx$ES_HEAP\n' > $ES_HOME/config/jvm.options.d/ship.options"
run_step "写 keystore 三项（bootstrap 密码 + 两张证书密码）" \
  "printf '%s\n%s\n%s\n' $ES_PASSWORD $ES_PASSWORD $ES_PASSWORD | $ES_HOME/bin/elasticsearch-keystore add -x -f bootstrap.password xpack.security.http.ssl.keystore.secure_password xpack.security.transport.ssl.keystore.secure_password"
run_step "后台启动 ES（首次 1-2 分钟）" \
  "cd $ES_HOME && ./bin/elasticsearch -d -p $RUN_DIR/es.pid"
run_step "轮询等 ES 就绪（返回 200 即健康）" \
  "until curl -sk -u elastic:$ES_PASSWORD -o /dev/null -w '%{http_code}' $ES_URL/_cluster/health | grep -q 200; do echo -n .; sleep 3; done && echo ' ES ✓'"
run_step "改 kibana_system 密码（与本机同密码，省事）" \
  "curl -sk -u elastic:$ES_PASSWORD -X POST $ES_URL/_security/user/kibana_system/_password -H 'Content-Type: application/json' -d '{\"password\":\"$ES_PASSWORD\"}'"
run_step "保存凭据（600 权限）" \
  "printf 'ES_URL=%s\nES_PASSWORD=%s\nKIBANA_URL=https://localhost:%s\n' '$ES_URL' '$ES_PASSWORD' '$KB_PORT' > $INSTALL_DIR/.credentials && chmod 600 $INSTALL_DIR/.credentials && echo 凭据已存"

# ─────────── 三、Kibana ───────────
run_step "拷证书给 Kibana" \
  "cp -f $ES_HOME/config/ship-server.{crt,key} $ES_HOME/config/ship-ca.pem $KB_HOME/config/"
run_step "写 kibana.yml" \
  "printf 'server.port: %s\nserver.host: \"0.0.0.0\"\nserver.publicBaseUrl: \"https://%s:%s\"\nserver.ssl.enabled: true\nserver.ssl.certificate: config/ship-server.crt\nserver.ssl.key: config/ship-server.key\ni18n.locale: \"zh-CN\"\nelasticsearch.hosts: [\"%s\"]\nelasticsearch.username: kibana_system\nelasticsearch.password: \"%s\"\nelasticsearch.ssl.verificationMode: full\nelasticsearch.ssl.certificateAuthorities: [\"config/ship-ca.pem\"]\n' $KB_PORT $MY_IP $KB_PORT $ES_URL $ES_PASSWORD > $KB_HOME/config/kibana.yml && cat $KB_HOME/config/kibana.yml"
run_step "后台启动 Kibana（首次优化数分钟）" \
  "cd $KB_HOME && nohup ./bin/kibana > $LOG_DIR/kibana/kibana.out 2>&1 < /dev/null & echo \$! > $RUN_DIR/kibana.pid"
run_step "轮询等 Kibana 就绪" \
  "until curl -sk -o /dev/null https://localhost:$KB_PORT/api/status; do echo -n .; sleep 5; done && echo ' Kibana ✓'"

# ─────────── 四、Agent（独立模式）───────────
run_step "写 Agent 配置 elastic-agent.yml（双 filestream）" \
  "printf 'outputs:\n  default:\n    type: elasticsearch\n    hosts: [\"%s\"]\n    username: elastic\n    password: \"%s\"\n    ssl.verification_mode: none\ninputs:\n  - id: engine-filestream\n    type: filestream\n    use_output: default\n    data_stream.namespace: default\n    streams:\n      - data_stream: { type: logs, dataset: ship.engine }\n        paths: [\"%s/engine_*.txt\", \"%s/engine_*.jsonl\"]\n        parsers:\n          - ndjson: { target: engine, add_error_key: true }\n        prospector.scanner.check_interval: 5s\n        prospector.scanner.fingerprint.enabled: true\n        close.on_state_change.inactive: 2m\n        ignore_older: 24h\n        clean_inactive: 72h\n        clean_removed: true\n        tags: [ship500, engine]\n  - id: imu-filestream\n    type: filestream\n    use_output: default\n    data_stream.namespace: default\n    streams:\n      - data_stream: { type: logs, dataset: ship.imu }\n        paths: [\"%s/imu_*.txt\", \"%s/imu_*.log\"]\n' $ES_URL $ES_PASSWORD $INGEST_DIR $INGEST_DIR $INGEST_DIR $INGEST_DIR > $CONF_DIR/elastic-agent.yml && cat $CONF_DIR/elastic-agent.yml"
run_step "安装 Agent 为系统服务（无特权，当前用户跑）" \
  "sudo $AGENT_STAGE/elastic-agent install --install-servers --unprivileged --user \$(id -un) --group \$(id -gn) --base-path $AGENT_BASE --non-interactive --force"
run_step "挂配置+重启服务" \
  "sudo cp $CONF_DIR/elastic-agent.yml $AGENT_HOME/elastic-agent.yml && sudo systemctl restart elastic-agent && sleep 10 && sudo systemctl status elastic-agent --no-pager | head -8"
run_step "自检：造 15 条测试数据" \
  "for i in \$(seq 1 15); do echo '{\"name\":\"engine/selftest_rpm\",\"value\":'\$((1000+i))',\"timestamp\":'\$(date +%s)'}' >> $INGEST_DIR/engine_selftest.txt; done; for i in \$(seq 1 15); do echo '\$GTIMU,2397,144353.9600,-0.0170,-0.0363,0.0125,0.0221,0.0136,1.0026,30.9*56' >> $INGEST_DIR/imu_selftest.txt; done"
run_step "等 30 秒后查数据流计数（engine 应 >0）" \
  "sleep 30 && curl -sk -u elastic:$ES_PASSWORD $ES_URL/logs-ship.engine-default/_count && curl -sk -u elastic:$ES_PASSWORD $ES_URL/logs-ship.imu-default/_count"
run_step "（可选）把真实数据文件拷进数据目录" \
  "echo 把 engine_*.txt / imu_*.txt 拷贝到 $INGEST_DIR/（此处不自动执行）"

echo -e "\n${G}人工部署完成。下一步（管线/ML/看板）建议直接跑 deploy.sh 补齐自动化部分。${N}"
