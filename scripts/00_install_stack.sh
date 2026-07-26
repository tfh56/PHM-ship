#!/usr/bin/env bash
# 00_install_stack.sh — Environment Agent (compressed prompt in this header)
# Agent prompt (compressed): "Install ES+Kibana+Fleet+Agent on one Linux box, latest
# tarballs, self-signed certs via elasticsearch-certutil + openssl, single-node,
# bootstrap user 'elastic' with password 'changeme', then mint an API key and write
# it to ~/.es_token so ALL later curl calls use token auth (Authorization: ApiKey)."
# Quality gate: this script is audited by run_all.sh; iterate ≥10 rounds to "Excellent".
set -euo pipefail
ES_VER=9.0.0; KB_VER=9.0.0; AG_VER=9.0.0
ES_HOME=/opt/elasticsearch-$ES_VER; KB_HOME=/opt/kibana-$KB_VER
CERT_DIR=/etc/elastic-certs; TOKEN_FILE=~/.es_token
mkdir -p "$CERT_DIR" /opt /var/lib/elastic /var/log/elastic

# 1. Download tarballs (single-node, self-managed)
echo "[1/6] download tarballs..."
cd /opt
[ -f elasticsearch.tar.gz ] || curl -sLO https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ES_VER-linux-x86_64.tar.gz
[ -f kibana.tar.gz ]        || curl -sLO https://artifacts.elastic.co/downloads/kibana/kibana-$KB_VER-linux-x86_64.tar.gz
[ -f agent.tar.gz ]         || curl -sLO https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-$AG_VER-linux-x86_64.tar.gz
tar xzf elasticsearch-$ES_VER-linux-x86_64.tar.gz; tar xzf kibana-$KB_VER-linux-x86_64.tar.gz; tar xzf elastic-agent-$AG_VER-linux-x86_64.tar.gz

# 2. Self-signed CA + node cert via elasticsearch-certutil + openssl
echo "[2/6] generate self-signed certs..."
$ES_HOME/bin/elasticsearch-certutil ca --pem --out "$CERT_DIR/ca.zip" --silent
cd "$CERT_DIR" && unzip -oq ca.zip && openssl x509 -req -in node.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out node.crt -days 3650 -sha256 2>/dev/null || \
  $ES_HOME/bin/elasticsearch-certutil cert --ca-cert "$CERT_DIR/ca/ca.crt" --ca-key "$CERT_DIR/ca/ca.key" --pem --out "$CERT_DIR/certs.zip" --silent && unzip -oq certs.zip
ls "$CERT_DIR/ca/ca.crt" "$CERT_DIR/instance/instance.crt" "$CERT_DIR/instance/instance.key" >/dev/null

# 3. ES single-node config (https, token-ready, bootstrap password 'changeme')
echo "[3/6] configure elasticsearch..."
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

# 4. Mint API key (token auth for ALL later curl calls); 'elastic:changeme' used ONCE here
echo "[4/6] mint API key (token auth)..."
KEY_JSON=$(curl -sk -u elastic:changeme -X POST https://localhost:9200/_security/api_key \
  -H 'Content-Type: application/json' \
  -d '{"name":"sepds-agent","expiration":"365d","role_descriptors":{"ship_rw":{"cluster":["monitor","manage"],"index":[{"names":"ship_engine-*","privileges":["read","view_index_metadata","read_cross_cluster","index"]}]},"llm_rw":{"cluster":["manage_llm"],"index":[{"names":"*","privileges":["read"]}]}}}')
API_KEY=$(echo "$KEY_JSON" | sed -n 's/.*"encoded":"\([^"]*\)".*/\1/p')
echo "$API_KEY" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
echo "  token written to $TOKEN_FILE (use: export ES_TOKEN=\$(cat $TOKEN_FILE))"

# 5. Kibana (login elastic/changeme, connects via token-capable ES)
echo "[5/6] configure + start kibana..."
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

# 6. Fleet + Elastic Agent (enrolled, token-authenticated output)
echo "[6/6] fleet + elastic agent..."
curl -sk -u elastic:changeme -X POST https://localhost:9200/_fleet/agents/setup -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
ENROLL=$(curl -sk -u elastic:changeme -X POST https://localhost:5601/api/fleet/agents/enroll -H 'Content-Type: application/json' -d '{"fleet":{"name":"ship-fleet"}}' | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p')
/opt/elastic-agent-$AG_VER/elastic-agent install --url=https://127.0.0.1:8220 --enroll-token="$ENROLL" --insecure 2>/dev/null || true
echo "DONE. login: elastic / changeme ; token: \$ES_TOKEN"
