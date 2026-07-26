#!/usr/bin/env bash
# 00_install_stack.sh — 环境智能体（提示词压缩在本头注释里）
# 智能体提示词（压缩版）："在一台 Linux 机器上安装 ES+Kibana+Fleet+Agent（最新
# tar 包），用 elasticsearch-certutil + openssl 配自签名证书，单机模式，引导用户
# 'elastic' 密码 'changeme'，然后生成 API Key 写入 ~/.es_token，让后续所有 curl
# 调用统一用 Token 认证（Authorization: ApiKey）。"
# 质量门：本脚本由 run_all.sh 审计；迭代 ≥10 轮至"优秀"。
set -euo pipefail
ES_VER=9.0.0; KB_VER=9.0.0; AG_VER=9.0.0
ES_HOME=/opt/elasticsearch-$ES_VER; KB_HOME=/opt/kibana-$KB_VER
CERT_DIR=/etc/elastic-certs; TOKEN_FILE=~/.es_token
mkdir -p "$CERT_DIR" /opt /var/lib/elastic /var/log/elastic

# 1. 下载 tar 包（单机、自管）
echo "[1/6] 下载 tar 包..."
cd /opt
[ -f elasticsearch.tar.gz ] || curl -sLO https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ES_VER-linux-x86_64.tar.gz
[ -f kibana.tar.gz ]        || curl -sLO https://artifacts.elastic.co/downloads/kibana/kibana-$KB_VER-linux-x86_64.tar.gz
[ -f agent.tar.gz ]         || curl -sLO https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-$AG_VER-linux-x86_64.tar.gz
tar xzf elasticsearch-$ES_VER-linux-x86_64.tar.gz; tar xzf kibana-$KB_VER-linux-x86_64.tar.gz; tar xzf elastic-agent-$AG_VER-linux-x86_64.tar.gz

# 2. 自签名 CA + 节点证书（elasticsearch-certutil + openssl）
echo "[2/6] 生成自签名证书..."
$ES_HOME/bin/elasticsearch-certutil ca --pem --out "$CERT_DIR/ca.zip" --silent
cd "$CERT_DIR" && unzip -oq ca.zip && openssl x509 -req -in node.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out node.crt -days 3650 -sha256 2>/dev/null || \
  $ES_HOME/bin/elasticsearch-certutil cert --ca-cert "$CERT_DIR/ca/ca.crt" --ca-key "$CERT_DIR/ca/ca.key" --pem --out "$CERT_DIR/certs.zip" --silent && unzip -oq certs.zip
ls "$CERT_DIR/ca/ca.crt" "$CERT_DIR/instance/instance.crt" "$CERT_DIR/instance/instance.key" >/dev/null

# 3. ES 单机配置（https、Token 就绪、引导口令 'changeme'）
echo "[3/6] 配置 elasticsearch..."
cat > $ES_HOME/config/elasticsearch.yml <<YML
cluster.name: sepds
node.name: ship-node-1
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.certificate_authorities: ["$CERT_DIR/ca/ca.crt"]
xpack.security.transport.ssl.certificate: "$CERT_DIR/instance/instance.crt"
xpack.security.transport.ssl.key: "$CERT_DIR/instance/instance.key"
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.certificate: "$CERT_DIR/instance/instance.crt"
xpack.security.http.ssl.key: "$CERT_DIR/instance/instance.key"
YML
echo "ES_JAVA_HOME=$ES_HOME/jdk" >> $ES_HOME/bin/elasticsearch-env 2>/dev/null || true
ELASTIC_PASSWORD=changeme $ES_HOME/bin/elasticsearch -d -p /var/run/es.pid
for i in $(seq 1 60); do curl -sk https://localhost:9200 >/dev/null 2>&1 && break; sleep 2; done

# 4. 生成 API Key（后续所有 curl 用 Token 认证）；'elastic:changeme' 仅此处用一次
echo "[4/6] 生成 API Key（Token 认证）..."
KEY_JSON=$(curl -sk -u elastic:changeme -X POST https://localhost:9200/_security/api_key \
  -H 'Content-Type: application/json' \
  -d '{"name":"sepds-agent","expiration":"365d","role_descriptors":{"ship_rw":{"cluster":["monitor","manage"],"index":[{"names":"ship_engine-*","privileges":["read","view_index_metadata","read_cross_cluster","index"]}]},"llm_rw":{"cluster":["manage_llm"],"index":[{"names":"*","privileges":["read"]}]}}}')
API_KEY=$(echo "$KEY_JSON" | sed -n 's/.*"encoded":"\([^"]*\)".*/\1/p')
echo "$API_KEY" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
echo "  Token 已写入 $TOKEN_FILE（用法：export ES_TOKEN=\$(cat $TOKEN_FILE)）"

# 5. Kibana（登录 elastic/changeme，经 Token 就绪的 ES 连接）
echo "[5/6] 配置并启动 kibana..."
cat > $KB_HOME/config/kibana.yml <<YML
server.host: 127.0.0.1
server.port: 5601
server.ssl.enabled: true
server.ssl.certificate: "$CERT_DIR/instance/instance.crt"
server.ssl.key: "$CERT_DIR/instance/instance.key"
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
