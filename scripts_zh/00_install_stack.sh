#!/usr/bin/env bash
# 00_install_stack.sh — 环境智能体
# 提示词（压缩）："在一台 Linux 机器上安装 ES+Kibana+Fleet+Agent（最新 tar 包），
# 用 elasticsearch-certutil + openssl 配自签名证书，单机运行，
# 用户elastic的密码是changeme。然后生成Token写入~/.es_token，让后续
# curl统一用Bearer Token认证头。"
set -euo pipefail
ELASTIC_ROOT=/mnt/e/ci/elastic; ES_VER=9.4.4; KB_VER=9.4.4; AG_VER=9.4.4
ES_HOME=~/elasticsearch-$ES_VER; KB_HOME=/mnt/e/ci//kibana-$KB_VER
CERT_DIR=${ELASTIC_ROOT}/elastic-certs; TOKEN_FILE=~/.es_token
mkdir -p "$CERT_DIR" "$ELASTIC_ROOT" ${ELASTIC_ROOT}/lib/elastic ${ELASTIC_ROOT}/log/elastic

# 1. 下载 tar 包（单机、自管）
echo "[1/6] 下载 tar 包..."
cd ${ELASTIC_ROOT}/resource
[ -f es.tar.gz ] || curl -sLO https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ES_VER-linux-x86_64.tar.gz
[ -f kb.tar.gz ] || curl -sLO https://artifacts.elastic.co/downloads/kibana/kibana-$KB_VER-linux-x86_64.tar.gz
[ -f ag.tar.gz ] || curl -sLO https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-$AG_VER-linux-x86_64.tar.gz
cd ..; tar xzf elasticsearch-$ES_VER-linux-x86_64.tar.gz; tar xzf kibana-$KB_VER-linux-x86_64.tar.gz; tar xzf elastic-agent-$AG_VER-linux-x86_64.tar.gz

# 2. 自签名 CA + 节点证书（elasticsearch-certutil + openssl）
echo "[2/6] 生成自签名证书..."
$ES_HOME/bin/elasticsearch-certutil ca --pem --out "$CERT_DIR/ca.zip" --silent
cd "$CERT_DIR" && unzip -oq ca.zip
$ES_HOME/bin/elasticsearch-certutil cert --ca-cert ca/ca.crt  ... ter":["all"],"index":[{"names":"ship_engine-*","privileges":["read","write","index","view_index_metadata","read_cross_cluster"]}]}}}')
API_KEY=$(echo "$KEY_JSON" | sed -n 's/.*"encoded":"\([^"]*\)".*/\1/p')
echo "$API_KEY" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
echo "  Token 已写入 $TOKEN_FILE（export ES_TOKEN=\$(cat $TOKEN_FILE)）"

# 5. Kibana（登录 elastic/changeme，经 Token 就绪的 ES 连接）
echo "[5/6] 配置并启动 kibana..."
cat > $KB_HOME/config/kibana.yml <<YML
server.host: 127.0.0.1
server.port: 5601
server.ssl.enabled: true
server.ssl.certificate: $CERT_DIR/instance/ship-node.crt
server.ssl.key: $CERT_DIR/instance/ship-node.key
elasticsearch.hosts: ["https://127.0.0.1:9200"]
elasticsearch.username: elastic
elasticsearch.password: changeme
YML
nohup $KB_HOME/bin/kibana > /var/log/elastic/kibana.log 2>&1 &

# 6. Fleet + Elastic Agent（注册，Token 认证输出）
echo "[6/6] fleet + elastic agent..."
curl -sk -u elastic:changeme -X POST https://localhost:9200/_fleet/agents/setup -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
ENROLL=$(curl -sk -u elastic:changeme -X POST https://localhost:5601/api/fleet/agents/enroll -H 'Content-Type: application/json' -d '{"fleet":{"name":"ship-fleet"}}' | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p')
/opt/elastic-agent-$AG_VER/elastic-agent install --url=https://127.0.0.1:8220 --enroll-token="$ENROLL" --insecure 2>/dev/null || true
echo "完成。登录：elastic / changeme ；Token：\$ES_TOKEN"
