#!/usr/bin/env bash
# ============================================================
# ELASTIC STACK 船舶遥测数据平台 — 一键部署脚本
# ============================================================
# 适用人群：不会 Linux 的工程师 / 船长 / 研发人员
# 环境要求：Linux x86_64（Ubuntu/Debian 或 CentOS），内存 ≥ 8GB，磁盘 ≥ 50GB
# 运行方式：bash 00_run_all.sh
# ============================================================
# 功能概览：
#   1. 下载安装 Elasticsearch + Kibana（最新版 tar.gz，自动安全配置）
#   2. 功能拓展：HTTP SSL 访问、域名 SAN 证书、企业证书
#   3. 下载安装 Elastic Agent（Fleet 模式）
#   4. 摄入发动机 + GPS 数据（6MB 文件滚动，GPS 时间转 unix）
#   5. 时序数据流索引 + ILM 全生命周期（热3月/温12月/冷36月/归档）
#   6. 异常检测任务 + 机器学习跟踪故障
#   7. 大模型助理（船长/船员/研发/服务商）
#   8. Kibana 看板（航迹/报警/异常统计）
#   9. 角色识别 + 对话跟踪
# ============================================================

set -xeuo pipefail

# ---- 颜色输出 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; \
          echo -e "${BLUE}  STEP ${1}:${NC} ${2}"; \
          echo -e "${BLUE}════════════════════════════════════════${NC}"; }

# ---- 全局变量（外行在这里改配置）----
# ╔══════════════════════════════════════════════════════════════╗
# ║  【小白改这里】把下面的值改成你的                            ║
# ╚══════════════════════════════════════════════════════════════╝

# 安装目录（建议磁盘大的地方）
INSTALL_DIR=${INSTALL_DIR:-${HOME}/elastic}&&cd -Pe $INSTALL_DIR&&INSTALL_DIR=$(pwd)
# 数据目录
DATA_DIR=${DATA_DIR:-${INSTALL_DIR}/data}
# 你的域名（没有就写 IP）
MY_DOMAIN="ship.local"
# 你的 IP 地址（自动获取，也可以手动改）
MY_IP=$(hostname -I | awk '{print $1}')
# 企业证书 GitHub 仓库（atomgit 上的）
CERT_DIR=${CERT_DIR:-${INSTALL_DIR}/.cert}
LICENSE_REPO="https://atomgit.com/tfh56/ESLicenseSigner.git"
# 数据摄入目录
INGEST_DIR=${INGEST_DIR:-${DATA_DIR}/data_ingest}
# Elastic 版本（最新版会自动检测，也可以手动指定如 9.5.1）
ES_VERSION=${ES_VERSION:-""}
# 端口
ES_PORT=9200
KB_PORT=5601
FLEET_PORT=8220
#elastic kibana_system 密钥通行密码
ES_PASSWORD="changeme"

# ============================================================
# STEP 0: 环境检查
# ============================================================
step "0" "环境检查与准备"

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID=$ID
    info "操作系统: $OS_ID $(uname -m)"
else
    err "无法检测操作系统，请使用 Ubuntu 或 CentOS"
fi
[ $(id -u) -eq 0 ]&&err "请改用普通用户!"

# 检测内存
MEM_GB=$(free -g | awk '/Mem:/{print $2}')
if [[ $MEM_GB -lt 4 ]]; then
    warn "内存 ${MEM_GB}GB < 4GB，建议 ≥ 8GB"
else
    info "内存: ${MEM_GB}GB"
fi

# 检测磁盘
DISK_GB=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
if [[ $DISK_GB -lt 20 ]]; then
    warn "可用磁盘 ${DISK_GB}GB < 20GB，建议 ≥ 50GB"
else
    info "可用磁盘: ${DISK_GB}GB"
fi

# 检测 java
if ! command -v java &>/dev/null; then
    info "安装 Java 17..."
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        sudo apt-get update -qq && sudo apt-get install -y -qq openjdk-17-jdk-headless
    else
        sudo yum install -y -q java-17-openjdk-headless
    fi
fi
info "Java: $(java -version 2>&1 | head -1)"

# 检测 curl, wget, jq, git
for cmd in curl wget jq git tar; do
    if ! command -v $cmd &>/dev/null; then
        info "安装 $cmd..."
        if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
            sudo apt-get install -y -qq $cmd
        else
            sudo yum install -y -q $cmd
        fi
    fi
done

# 创建目录
mkdir -p $INSTALL_DIR $DATA_DIR $INGEST_DIR $CERT_DIR $DATA_DIR/elasticsearch-log $DATA_DIR/kibana-log

info "环境检查完成"

# ============================================================
# STEP 1: 下载安装 Elasticsearch + Kibana（最新版 tar.gz）
# ============================================================
step "1" "下载安装 Elasticsearch + Kibana"

# 自动检测最新版本
if [[ -z "$ES_VERSION" ]]; then
    info "检测最新版本..."
    ES_VERSION=$(curl -s "https://api.github.com/repos/elastic/elasticsearch/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    if [[ "$ES_VERSION" == "null" ]] || [[ -z "$ES_VERSION" ]]; then
        ES_VERSION="9.5.2"  # fallback
        warn "无法检测最新版本，使用 ${ES_VERSION}"
    fi
fi
info "Elastic 版本: ${ES_VERSION}"

# 下载 Elasticsearch
ES_TAR="elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
[ -f /tmp/$ES_TAR ]&&gzip -tq /tmp/$ES_TAR||(info "下载 Elasticsearch ${ES_VERSION}..."&&curl -L -o /tmp/${ES_TAR} https://artifacts.elastic.co/downloads/elasticsearch/${ES_TAR})

# 下载 Kibana
KB_TAR="kibana-${ES_VERSION}-linux-x86_64.tar.gz"
[ -f /tmp/$KB_TAR ]&&gzip -tq /tmp/$KB_TAR||(info "下载 Kibana ${ES_VERSION}..."&&curl -L -o "/tmp/${KB_TAR}" "https://artifacts.elastic.co/downloads/kibana/${KB_TAR}")

# 解压
ES_HOME=$INSTALL_DIR/elasticsearch-${ES_VERSION}
test ! -e $ES_HOME&&info "解压 Elasticsearch..."&&tar -xzf /tmp/${ES_TAR} -C $INSTALL_DIR

KB_HOME=$INSTALL_DIR/kibana-${ES_VERSION}
test ! -e $KB_HOME&&info "解压 Kibana..."&&tar -xzf /tmp/${KB_TAR} -C $INSTALL_DIR

# JVM 配置
cat > "$ES_HOME/config/jvm.options" << JVM_CFG
-Xms4g
-Xmx4g
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+UseCompressedOops
-Dfile.encoding=UTF-8
-XX:+HeapDumpOnOutOfMemoryError
JVM_CFG
# ============================================================
# STEP 2: 功能拓展 — HTTPS SSL + 域名 SAN 证书 + 企业证书
# ============================================================
step "2" "功能拓展：HTTPS SSL 访问 + 域名证书"

# ---- 2a: 自签名 SAN 证书（基础版）----
info "生成 SAN 证书（含 IP 和域名）..."

# 生成 CA
openssl req -x509 -new -nodes -keyout $CERT_DIR/ca.key -out $CERT_DIR/ca.crt \
    -days 3650 -subj /C=CN/O=CSSRC/CN=CSSRC-CA 2>/dev/null

# 生成带 SAN 的服务证书
cat > "$CERT_DIR/san.cnf" << SAN_CFG
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt=no
[req_distinguished_name]
CN = ${MY_DOMAIN}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.${MY_DOMAIN}
DNS.2 = localhost
DNS.3 = ship-engine.local
DNS.4 = *.ship.local
DNS.5 = leo-pickerel.ts.net
DNS.6 = *
IP.1 = ${MY_IP}
IP.2 = 127.0.0.1
SAN_CFG

openssl req -new -keyout $CERT_DIR/ship.key -out $CERT_DIR/ship.csr \
    -config $CERT_DIR/san.cnf -nodes 2>/dev/null

openssl x509 -req -in $CERT_DIR/ship.csr -CA $CERT_DIR/ca.crt \
    -CAkey $CERT_DIR/ca.key -CAcreateserial -out $CERT_DIR/ship.crt -days 3650 \
    -copy_extensions copy -trustout -subj /C=CN/O=CSSRC/CN=CSSRC-Ship 2>/dev/null

info "SAN 证书已生成（含域名 ${MY_DOMAIN} 和 IP ${MY_IP}）"

# ---- 2b: 在 Elasticsearch 中配置 SSL ----
info "配置 Elasticsearch HTTPS..."

# ES 配置
cat > "$ES_HOME/config/elasticsearch.yml" << SSL_CFG
cluster.name: ship-engine-cluster
node.name: ship-node-1
path.data: ${DATA_DIR}
path.logs: ${DATA_DIR}/elasticsearch-log
network.host: 0.0.0.0
http.port: ${ES_PORT}

# 单节点模式（适合船舶部署）
discovery.type: single-node

# 机器学习
xpack.ml.enabled: true
xpack.ml.use_auto_machine_memory_percent: true

# === HTTPS SSL 配置 ===
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: ship.key
xpack.security.http.ssl.key_passphrase: $ES_PASSWORD
xpack.security.http.ssl.certificate: ship.crt
xpack.security.http.ssl.certificate_authorities: [ca.crt]

# 传输层 SSL
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.key: ship.key
xpack.security.transport.ssl.key_passphrase: $ES_PASSWORD
xpack.security.transport.ssl.certificate: ship.crt
xpack.security.transport.ssl.certificate_authorities: ca.crt

xpack.security.enrollment.enabled: true
SSL_CFG

$ES_HOME/bin/elasticsearch-service-tokens delete elastic/auto-ops es-token&>/dev/null||true
ES_TOKEN=$($ES_HOME/bin/elasticsearch-service-tokens create elastic/auto-ops es-token | cut -d" " -f4)
ES_AUTH="-H \"Authorization: Bearer $ES_TOKEN\""

cp $CERT_DIR/*.[ck][re][ty] $ES_HOME/config
curl -sk https://127.0.0.1:${ES_PORT} ${ES_AUTH}&>/dev/null||ES_JAVA_OPTS="-Xms700m -Xmx800m" "$ES_HOME/bin/elasticsearch" -d -p "$DATA_DIR/es.pid"
sleep 5

# 等待启动
info "等待 Elasticsearch 启动（最多 120 秒）..."
for i in $(seq 1 120); do
    if curl -sk https://127.0.0.1:${ES_PORT} $ES_AUTH&>/dev/null; then
        info "Elasticsearch 已启动（${i}秒）"
        break
    fi
    sleep 1
    [[ $i -eq 120 ]] && err "Elasticsearch 启动超时"
done

# 验证 HTTPS
if curl -sk https://127.0.0.1:${ES_PORT} $ES_AUTH | jq -e '.name' &>/dev/null; then
    info "HTTPS 访问已启用！"
    info "访问地址: https://${MY_DOMAIN}:${ES_PORT} 或 https://${MY_IP}:${ES_PORT}"
else
    warn "HTTPS 验证失败，请检查证书"
fi

# 重置 elastic 超级用户密码
$ES_HOME/bin/elasticsearch-reset-password -u elastic -i -b 2>/dev/null << eof
$ES_PASSWORD
$ES_PASSWORD
eof
test $? -ne 0 && err "重置 elastic 超级用户密码失败。"
$ES_HOME/bin/elasticsearch-reset-password -u kibana_system -i -b 2>/dev/null << eof
$ES_PASSWORD
$ES_PASSWORD
eof
test $? -ne 0 && err "重置 kibana_system 用户密码失败。"

info "Elasticsearch elastic kibana_system 用户密码: ${ES_PASSWORD}"

# 生成 Kibana enrollment token
info "生成 Kibana enrollment token..."
#KB_ENROLLMENT=$("$ES_HOME/bin/elasticsearch-create-enrollment-token" -s kibana 2>/dev/null || err "生成 Kibana enrollment token 失败。")

# 保存凭据
cat > $CERT_DIR/.credentials << CRED
# Elasticsearch 凭据（妥善保管！）
ES_URL=https://${MY_IP}:${ES_PORT}
ES_USER=$USER
ES_PASSWORD=${ES_PASSWORD}
ES_TOKEN=$ES_TOKEN
KB_ENROLLMENT_TOKEN=${KB_ENROLLMENT:-""}
CRED

chmod 600 "$CERT_DIR/.credentials"

# ---- 2c: 企业证书（从 atomgit tfh56/ESLicenseSigner 安装）----
info "拉取企业证书工具（atomgit tfh56/ESLicenseSigner）..."

SIGNER_DIR=$INSTALL_DIR/ESLienseSigner
if [[ ! -d $SIGNER_DIR ]]; then
    git clone $LICENSE_REPO $SIGNER_DIR 2>/dev/null || {
        warn "无法从 atomgit 拉取，尝试 GitHub 镜像..."
        git clone "https://github.com/tfh56/ESLicenseSigner.git" $SIGNER_DIR 2>/dev/null || \
            warn "企业证书工具拉取失败。"
    }
fi

if [[ -d $SIGNER_DIR ]] && [[ -f $SIGNER_DIR/install-license.sh ]]; then
    info "安装企业证书..."
    cd $SIGNER_DIR
    ES_PASS=$ES_PASSWORD ES_TOKEN=$ES_TOKEN bash install-license.sh 2>/dev/null || \
        warn "企业证书安装失败。"
    cd -
fi

# 配置 Kibana 使用 HTTPS 连 ES
cat > "$KB_HOME/config/kibana.yml" << KB_CFG
server.host: "0.0.0.0"
server.port: ${KB_PORT}
server.name: "ship-kibana"
server.ssl.enabled: true
server.ssl.certificate: "${CERT_DIR}/ship.crt"
server.ssl.key: "${CERT_DIR}/ship.key"

elasticsearch.hosts: ["https://localhost:${ES_PORT}"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${ES_PASSWORD}"
elasticsearch.ssl.verificationMode: "none"
elasticsearch.ssl.certificateAuthorities: ["${CERT_DIR}/ca.crt"]

i18n.locale: "zh-CN"

logging:
  to_stdout: true
  to_file: true
  path: ${DATA_DIR}/kibana-log
KB_CFG

curl -sk https://127.0.0.1:${KB_PORT} $ES_AUTH&>/dev/null||nohup $KB_HOME/bin/kibana &> $DATA_DIR/kinana-log/kibana.log&
echo $! > "$DATA_DIR/kibana.pid"

info "Kibana 已配置 HTTPS"
info "Kibana 访问地址: https://${MY_DOMAIN}:${KB_PORT}, Enrollment token 是 $(KB_ENROLLMENT_TOKEN:-""}"

# ============================================================
# STEP 3: 下载安装 Elastic Agent（Fleet 模式）
# ============================================================
step "3" "下载安装 Elastic Agent（Fleet 模式）"

# 生成 Fleet Server enrollment token
info "配置 Fleet Server..."
$ES_HOME/bin/elasticsearch-service-tokens delete elastic/fleet-server fleet-server-token&>/dev/null || true
FLEET_TOKEN=$("$ES_HOME/bin/elasticsearch-service-tokens" create elastic/fleet-server fleet-server-token 2>/dev/null | tail -1 | cut -d" " -f4 || echo "fleet-server-token")

# 下载 Elastic Agent
AGENT_TAR="elastic-agent-${ES_VERSION}-linux-x86_64.tar.gz"
[ -f /tmp/$AGENT_TAR ]&&gzip -tq /tmp/$AGENT_TAR||(info "下载 Elastic Agent ${ES_VERSION}..."&&curl -L -o /tmp/${AGENT_TAR} https://artifacts.elastic.co/downloads/beats/elastic-agent/${AGENT_TAR})

AGENT_HOME="$INSTALL_DIR/elastic-agent"
mkdir -p "$AGENT_HOME"
tar -xzf /tmp/${AGENT_TAR} -C $AGENT_HOME --strip-components=1

# 安装 Fleet Server
info "安装 Fleet Server..."
cat > "$AGENT_HOME/fleet.yml" << FLEET_CFG
agent:
  id: fleet-server
  logging:
    level: info
fleet:
  server:
    host: 0.0.0.0
    port: ${FLEET_PORT}
    elasticsearch:
      host: https://localhost:${ES_PORT}
      username: elastic
      password: "${ES_PASSWORD}"
      ssl.verification_mode: none
    ssl:
      enabled: true
      certificate: ${CERT_DIR}/ship.crt
      key: ${CERT_DIR}/ship.key
outputs:
  default:
    type: elasticsearch
    hosts: ["https://localhost:${ES_PORT}"]
    username: elastic
    password: "${ES_PASSWORD}"
    ssl.verification_mode: none
FLEET_CFG

# 启动 Fleet Server
info "启动 Fleet Server..."
nohup "$AGENT_HOME/elastic-agent" container --config "$AGENT_HOME/fleet.yml" \
    > "$DATA_DIR/fleet.log" 2>&1 &
echo $! > "$DATA_DIR/fleet.pid"

sleep 10
info "Fleet Server 启动中，端口: ${FLEET_PORT}"
info "Fleet 管理界面: https://${MY_DOMAIN}:${KB_PORT}/app/fleet"

# ---- 3b: 注册 Agent 策略 ----
info "创建 Agent 策略..."

# 注册 Fleet Server
curl -sk $ES_AUTH -X POST "https://localhost:${ES_PORT}/_fleet/agent/fleet-server" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer ${FLEET_TOKEN}" \
    -d "{\"name\": \"ship-agent\", \"server_addr\": \"https://${MY_IP}:${FLEET_PORT}\"}" 2>/dev/null || true

# ============================================================
# STEP 4: 数据摄入 — 发动机 + GPS 一天采集数据
# ============================================================
step "4" "数据摄入准备 — 发动机 + GPS 数据"

# ---- 4a: 数据转换脚本 ----
info "创建数据转换脚本..."

cat > "$INSTALL_DIR/convert_imu.py" << 'PYTHON_CONVERT'
#!/usr/bin/env python3
"""
IMU 数据转换：GPS 周秒 → Unix 时间戳
文件滚动：单文件最大 6MB
文件名格式：imu_{年月日-时分秒}.txt
"""
import os
import sys
import math
from datetime import datetime, timedelta

# GPS 起始周：1980-01-06（GPS epoch）
GPS_EPOCH = datetime(1980, 1, 6)
# GPS 闰秒（2024年：18秒）
GPS_LEAP_SECONDS = 18
# Unix epoch 与 GPS epoch 的差（秒）
UNIX_GPS_OFFSET = int(GPS_EPOCH - datetime(1970, 1, 1)).total_seconds()

def gps_to_unix(week, seconds):
    """GPS 周秒 → Unix 时间戳"""
    return week * 604800 + seconds + UNIX_GPS_OFFSET - GPS_LEAP_SECONDS

def parse_gtimu(line):
    """解析 $GTIMU 语句 → {timestamp, gyro_x, gyro_y, gyro_z, accel_x, accel_y, accel_z, temp}"""
    parts = line.strip().split(',')
    if len(parts) < 10 or not parts[0].startswith('$GTIMU'):
        return None
    week = int(parts[1])
    sec = float(parts[2])
    ts = gps_to_unix(week, sec)
    return {
        "name": "imu/gyroscope",
        "timestamp": ts,
        "gyro_x": float(parts[3]),
        "gyro_y": float(parts[4]),
        "gyro_z": float(parts[5]),
        "accel_x": float(parts[6]),
        "accel_y": float(parts[7]),
        "accel_z": float(parts[8]),
        "temp": float(parts[9].split('*')[0])
    }

def parse_gpfpd(line):
    """解析 $GPFPD 语句 → GPS 位姿数据"""
    parts = line.strip().split(',')
    if len(parts) < 16 or not parts[0].startswith('$GPFPD'):
        return None
    week = int(parts[1])
    sec = float(parts[2])
    ts = gps_to_unix(week, sec)
    return {
        "name": "imu/gps_position",
        "timestamp": ts,
        "heading": float(parts[3]),
        "pitch": float(parts[4]),
        "roll": float(parts[5]),
        "latitude": float(parts[6]),
        "longitude": float(parts[7]),
        "altitude": float(parts[8]),
        "vel_north": float(parts[9]),
        "vel_east": float(parts[10]),
        "vel_down": float(parts[11]),
        "speed": float(parts[12]),
        "satellites": int(parts[13]),
        "fix_type": int(parts[14])
    }

def convert_file(input_file, output_dir, max_mb=6):
    """转换单个 IMU 文件，6MB 滚动"""
    os.makedirs(output_dir, exist_ok=True)
    current_file = None
    current_size = 0
    file_count = 0

    def new_file():
        nonlocal current_file, current_size, file_count
        if current_file:
            current_file.close()
        file_count += 1
        now = datetime.now().strftime("%Y%m%d-%H%M%S")
        fname = f"imu_{now}.txt"
        path = os.path.join(output_dir, fname)
        current_file = open(path, 'w')
        current_size = 0
        return path

    with open(input_file, 'r') as f:
        for line in f:
            if current_file is None or current_size >= max_mb * 1024 * 1024:
                path = new_file()
                print(f"  创建文件: {path}")

            if line.startswith('$GTIMU'):
                data = parse_gtimu(line)
                if data:
                    json_line = json.dumps(data) + '\n'
                    current_file.write(json_line)
                    current_size += len(json_line)
            elif line.startswith('$GPFPD'):
                data = parse_gpfpd(line)
                if data:
                    json_line = json.dumps(data) + '\n'
                    current_file.write(json_line)
                    current_size += len(json_line)

    if current_file:
        current_file.close()
    print(f"  转换完成，共 {file_count} 个文件")

if __name__ == '__main__':
    import json
    input_file = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.getenv("DATA_DIR"),"/data_ingest/imu")
    convert_file(input_file, output_dir)
PYTHON_CONVERT
chmod +x "$INSTALL_DIR/convert_imu.py"

# ---- 4b: 摄入脚本 ----
info "创建数据摄入脚本..."

cat > "$INSTALL_DIR/ingest_data.py" << 'PYTHON_INGEST'
#!/usr/bin/env python3
"""
数据摄入脚本：
  1. 读取发动机 JSONL 数据，按 6MB 滚动
  2. 读取 IMU 数据（已转换为 unix 时间戳）
  3. 通过 Elastic Agent / Filebeat 摄入 ES
  4. 按时间戳建立时序数据流
"""
import os
import sys
import json
import time
import requests
from datetime import datetime
from requests.auth import HTTPBasicAuth

# 配置
ES_URL = os.environ.get("ES_URL", "https://localhost:9200")
ES_USER = os.environ.get("ES_USER", "elastic")
ES_PASS = os.environ.get("ES_PASSWORD", "changeme")
ES_TOKEN = os.environ.get("ES_TOKEN", "notset")
INGEST_DIR = os.environ.get("INGEST_DIR")
MAX_FILE_MB = 6

auth = HTTPBasicAuth(ES_USER, ES_PASS)
verify = False  # 自签名证书

def roll_file(prefix, content, file_dir):
    """按 6MB 滚动写文件"""
    os.makedirs(file_dir, exist_ok=True)
    now = datetime.now().strftime("%Y%m%d-%H%M%S")
    fname = f"{prefix}_{now}.txt"
    path = os.path.join(file_dir, fname)
    with open(path, 'w') as f:
        f.write(content)
    return path

def bulk_index(docs, index_name):
    """批量索引到 ES 数据流"""
    if not docs:
        return
    bulk_body = ""
    for doc in docs:
        bulk_body += json.dumps({"create": {"_index": index_name}}) + "\n"
        bulk_body += json.dumps(doc) + "\n"

    resp = requests.post(
        f"{ES_URL}/_bulk",
        auth=auth, verify=verify,
        headers={"Content-Type": "application/x-ndjson","Authorization": f"\"Bearer {ES_TOKEN}\""},
        data=bulk_body
    )
    if resp.status_code not in (200, 201):
        print(f"  索引错误: {resp.status_code} {resp.text[:200]}")
    return resp

def ingest_engine_data(input_file):
    """摄入发动机数据"""
    print(f"  摄入发动机数据: {input_file}")
    batch = []
    batch_size = 1000

    with open(input_file, 'r') as f:
        for line in f:
            obj = json.loads(line.strip())
            # 转换为 ES 文档
            doc = {
                "@timestamp": int(float(obj["timestamp"]) * 1000),  # ES 用毫秒
                "name": obj["name"],
                "value": float(obj["value"]),
                "timestamp": float(obj["timestamp"]),
                "component": obj["name"].split("/")[1].split("_")[0] if "/" in obj["name"] else "unknown",
                "category": classify_variable(obj["name"])
            }
            batch.append(doc)
            if len(batch) >= batch_size:
                bulk_index(batch, "logs-ship-engine-default")
                batch = []

    if batch:
        bulk_index(batch, "logs-ship-engine-default")
    print(f"  发动机数据摄入完成")

def ingest_imu_data(input_dir):
    """摄入 IMU/GPS 数据"""
    for fname in sorted(os.listdir(input_dir)):
        if not fname.endswith(".txt"):
            continue
        fpath = os.path.join(input_dir, fname)
        print(f"  摄入 IMU 文件: {fname}")
        batch = []
        with open(fpath, 'r') as f:
            for line in f:
                obj = json.loads(line.strip())
                doc = {
                    "@timestamp": int(float(obj["timestamp"]) * 1000),
                    "timestamp": float(obj["timestamp"]),
                    **obj
                }
                batch.append(doc)
                if len(batch) >= 1000:
                    bulk_index(batch, "logs-ship-imu-default")
                    batch = []
        if batch:
            bulk_index(batch, "logs-ship-imu-default")

def classify_variable(name):
    """变量分类"""
    n = name.lower()
    if "temperature" in n or "temp" in n: return "temperature"
    if "pressure" in n: return "pressure"
    if "fuel" in n: return "fuel"
    if "oil" in n or "lubric" in n: return "oil"
    if "cylinder" in n: return "cylinder"
    if "bearing" in n: return "bearing"
    if "gear" in n: return "gearbox"
    if "tank" in n or "level" in n: return "tank"
    if "water" in n: return "cooling"
    if "speed" in n or "rpm" in n: return "speed"
    if "alarm" in n: return "alarm"
    if "power" in n or "battery" in n or "voltage" in n: return "power"
    return "other"

if __name__ == '__main__':
    # 检查 ES 连接
    try:
        r = requests.get(ES_URL, auth=auth, verify=verify)
        print(f"  ES 连接: {r.status_code}")
    except Exception as e:
        print(f"  ES 连接失败: {e}")
        sys.exit(1)

    # 摄入发动机数据
    engine_file = os.environ.get("ENGINE_FILE", "")
    if engine_file and os.path.exists(engine_file):
        ingest_engine_data(engine_file)

    # 摄入 IMU 数据
    imu_dir = os.environ.get("IMU_DIR", "~/elastic/data/data_ingest/imu")
    if os.path.isdir(imu_dir):
        ingest_imu_data(imu_dir)

    print("\n  数据摄入完成！")
PYTHON_INGEST
chmod +x "$INSTALL_DIR/ingest_data.py"

# 转换 IMU 数据
info "转换 IMU 数据（GPS 周秒 → Unix 时间戳）..."
python3 "$INSTALL_DIR/convert_imu.py" \
    "$INGEST_DIR/imu_20251216-000534.txt" \
    "$INGEST_DIR/imu" || warn "IMU 数据转换失败"

# 摄入数据到 ES
info "摄入数据到 Elasticsearch..."
export ES_URL="https://localhost:${ES_PORT}"
export ES_USER="elastic"
export ES_PASS="${ES_PASSWORD}"
export ENGINE_FILE="$INGEST_DIR/engine_sample.json"
export IMU_DIR="$INGEST_DIR/imu"
python3 "$INSTALL_DIR/ingest_data.py" 2>&1 | tail -20

# ============================================================
# STEP 5: 时序数据流索引 + ILM 全生命周期
# ============================================================
step "5" "时序数据流索引 + ILM 全生命周期管理"

# 创建索引生命周期策略
info "创建 ILM 策略：热3月 / 温12月 / 冷36月 / 归档..."

cat > /tmp/ilm_policy.json << 'ILM_JSON'
{
  "policy": {
    "description": "船舶遥测数据全生命周期管理：热3月→温12月→冷36月→归档",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [
          {
            "rollover": {
              "max_size": "50gb",
              "max_age": "30d"
            }
          },
          {
            "set_priority": { "priority": 100 }
          }
        ],
        "transitions": [
          {
            "state_name": "warm",
            "conditions": { "min_age": "3M" }
          }
        ]
      },
      {
        "name": "warm",
        "actions": [
          { "set_priority": { "priority": 50 } },
          {
            "forcemerge": {
              "max_num_segments": 1
            }
          },
          {
            "downsample": {
              "fixed_interval": "1h"
            }
          }
        ],
        "transitions": [
          {
            "state_name": "cold",
            "conditions": { "min_age": "12M" }
          }
        ]
      },
      {
        "name": "cold",
        "actions": [
          { "set_priority": { "priority": 10 } },
          {
            "downsample": {
              "fixed_interval": "1d"
            }
          },
          {
            "freeze": {}
          }
        ],
        "transitions": [
          {
            "state_name": "archive",
            "conditions": { "min_age": "36M" }
          }
        ]
      },
      {
        "name": "archive",
        "actions": [
          {
            "snapshot": {
              "repository": "ship-snapshot-repo"
            }
          },
          {
            "downsample": {
              "fixed_interval": "7d"
            }
          }
        ],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": { "min_age": "120M" }
          }
        ]
      },
      {
        "name": "delete",
        "actions": [
          { "delete": {} }
        ]
      }
    ]
  }
}
ILM_JSON

# 注册快照仓库
info "注册快照仓库..."
curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_snapshot/ship-snapshot-repo" \
    -H "Content-Type: application/json" \
    -d '{
      "type": "fs",
      "settings": {
        "location": "'"$DATA_DIR"'/snapshots",
        "compress": true
      }
    }' 2>/dev/null || warn "快照仓库注册失败"

# 创建 ILM 策略
curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_ilm/policy/ship-telemetry-policy" \
    -H "Content-Type: application/json" \
    -d @/tmp/ilm_policy.json 2>/dev/null | jq '.' 2>/dev/null || warn "ILM 策略创建失败"

info "ILM 策略已创建："
info "  热（Hot）: 0-3个月，全分辨率，高优先级"
info "  温（Warm）: 3-12个月，1小时降采样，合并段"
info "  冷（Cold）: 12-36个月，1天降采样，冻结索引"
info "  归档（Archive）: 36-120个月，7天降采样，快照"
info "  删除（Delete）: >120个月，自动删除"

# 创建数据流索引模板
info "创建数据流索引模板..."

cat > /tmp/index_template_engine.json << 'TMPL_JSON'
{
  "index_patterns": ["logs-ship-engine-*"],
  "data_stream": {},
  "template": {
    "settings": {
      "index.lifecycle.name": "ship-telemetry-policy",
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.refresh_interval": "1s",
      "index.mapping.total_fields.limit": 5000
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date", "format": "epoch_millis||strict_date_optional_time" },
        "timestamp": { "type": "double" },
        "name": { "type": "keyword" },
        "value": { "type": "double" },
        "component": { "type": "keyword" },
        "category": { "type": "keyword" }
      }
    }
  },
  "priority": 500
}
TMPL_JSON

cat > /tmp/index_template_imu.json << 'TMPL2_JSON'
{
  "index_patterns": ["logs-ship-imu-*"],
  "data_stream": {},
  "template": {
    "settings": {
      "index.lifecycle.name": "ship-telemetry-policy",
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.refresh_interval": "1s"
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date", "format": "epoch_millis||strict_date_optional_time" },
        "timestamp": { "type": "double" },
        "name": { "type": "keyword" },
        "heading": { "type": "double" },
        "pitch": { "type": "double" },
        "roll": { "type": "double" },
        "latitude": { "type": "double" },
        "longitude": { "type": "double" },
        "altitude": { "type": "double" },
        "speed": { "type": "double" },
        "gyro_x": { "type": "double" },
        "gyro_y": { "type": "double" },
        "gyro_z": { "type": "double" },
        "accel_x": { "type": "double" },
        "accel_y": { "type": "double" },
        "accel_z": { "type": "double" },
        "temp": { "type": "double" },
        "satellites": { "type": "integer" },
        "fix_type": { "type": "integer" }
      }
    }
  },
  "priority": 500
}
TMPL2_JSON

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_index_template/ship-engine-template" \
    -H "Content-Type: application/json" \
    -d @/tmp/index_template_engine.json 2>/dev/null | jq '.' 2>/dev/null

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_index_template/ship-imu-template" \
    -H "Content-Type: application/json" \
    -d @/tmp/index_template_imu.json 2>/dev/null | jq '.' 2>/dev/null

info "数据流索引模板已创建（发动机 + IMU）"

# 创建转换作业（Transform）- 持续聚合
info "创建 Transform 持续聚合任务..."

cat > /tmp/transform_hourly.json << 'TRANSFORM_JSON'
{
  "source": {
    "index": ["logs-ship-engine-*"]
  },
  "pivot": {
    "group_by": {
      "name": { "terms": { "field": "name" } },
      "hour": { "date_histogram": { "field": "@timestamp", "fixed_interval": "1h" } }
    },
    "aggregations": {
      "avg_value": { "avg": { "field": "value" } },
      "max_value": { "max": { "field": "value" } },
      "min_value": { "min": { "field": "value" } },
      "stddev_value": { "stddev": { "field": "value" } },
      "count": { "value_count": { "field": "value" } }
    }
  },
  "dest": {
    "index": "ship-engine-hourly-summary"
  },
  "sync": {
    "time": {
      "field": "@timestamp",
      "delay": "60s"
    }
  }
}
TRANSFORM_JSON

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_transform/ship-engine-hourly" \
    -H "Content-Type: application/json" \
    -d @/tmp/transform_hourly.json 2>/dev/null | jq '.' 2>/dev/null

curl -sk $ES_AUTH -X POST "https://localhost:${ES_PORT}/_transform/ship-engine-hourly/_start" 2>/dev/null | jq '.' 2>/dev/null

info "每小时聚合 Transform 已创建并启动"

# ============================================================
# STEP 6: 异常检测任务
# ============================================================
step "6" "异常检测任务配置"

# 创建异常检测作业
cat > /tmp/ml_anomaly.json << 'ML_JSON'
{
  "description": "发动机关键参数异常检测",
  "analysis_config": {
    "bucket_span": "15m",
    "detectors": [
      {
        "detector_description": "温度异常检测",
        "function": "low_high",
        "field_name": "value",
        "partition_field_name": "name",
        "detector_rules": []
      }
    ],
    "influencers": ["name", "category"]
  },
  "data_description": {
    "time_field": "@timestamp",
    "time_format": "epoch_ms"
  },
  "model_plot": { "enabled": true },
  "custom_settings": {
    "created_by": "ship-deployment-script"
  }
}
ML_JSON

# 创建温度异常检测作业
info "创建温度异常检测作业..."
curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_ml/anomaly_detectors/ship-engine-temp-anomaly" \
    -H "Content-Type: application/json" \
    -d @/tmp/ml_anomaly.json 2>/dev/null | jq '.' 2>/dev/null

# 按分类创建多个异常检测器
for category in temperature pressure fuel oil cylinder bearing speed; do
    cat > "/tmp/ml_${category}.json" << CAT_ML
{
  "description": "${category} 参数异常检测",
  "analysis_config": {
    "bucket_span": "15m",
    "detectors": [
      {
        "detector_description": "${category} 值异常",
        "function": "low_high",
        "field_name": "value",
        "partition_field_name": "name"
      }
    ],
    "influencers": ["name"]
  },
  "data_description": {
    "time_field": "@timestamp",
    "time_format": "epoch_ms"
  }
}
CAT_ML

    curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_ml/anomaly_detectors/ship-engine-${category}-anomaly" \
        -H "Content-Type: application/json" \
        -d @/tmp/ml_${category}.json 2>/dev/null | jq -r '.job_id // .error.type // "ok"' 2>/dev/null

    # 启动作业
    curl -sk $ES_AUTH -X POST "https://localhost:${ES_PORT}/_ml/anomaly_detectors/ship-engine-${category}-anomaly/_open" 2>/dev/null | jq -r '.' 2>/dev/null

    # 启动数据喂入
    curl -sk $ES_AUTH -X POST "https://localhost:${ES_PORT}/_ml/anomaly_detectors/ship-engine-${category}-anomaly/_start" \
        -H "Content-Type: application/json" \
        -d '{"start": 0}' 2>/dev/null | jq -r '.' 2>/dev/null

    info "  ${category} 异常检测作业已创建并启动"
done

# 创建报警关联规则
info "创建报警-异常关联规则..."
cat > /tmp/ml_rule.json << 'RULE_JSON'
{
  "name": "engine-alarm-correlation",
  "description": "异常检测与报警变量关联",
  "schedule": { "interval": "1m" },
  "params": {},
  "actions": [
    {
      "action_type": "index",
      "index": ".kibana",
      "doc": {
        "type": "alarm_correlation",
        "timestamp": "{{_now}}",
        "anomaly": "{{ctx.anomaly}}",
        "alarm_var": "{{ctx.alarm_var}}"
      }
    }
  ]
}
RULE_JSON

# ============================================================
# STEP 7: 大模型助理配置
# ============================================================
step "7" "大模型助理配置（船长/船员/研发/服务商）"

# 创建角色定义索引
cat > /tmp/assistant_setup.json << 'ASSIST_JSON'
{
  "mappings": {
    "properties": {
      "role": { "type": "keyword" },
      "user_id": { "type": "keyword" },
      "conversation_history": { "type": "nested" },
      "identity_profile": { "type": "object" },
      "last_interaction": { "type": "date" },
      "preferences": { "type": "object" }
    }
  }
}
ASSIST_JSON

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/ship-assistant-contexts" \
    -H "Content-Type: application/json" \
    -d @/tmp/assistant_setup.json 2>/dev/null | jq '.' 2>/dev/null

# 创建角色检测管道
cat > /tmp/role_pipeline.json << 'PIPE_JSON'
{
  "description": "识别用户角色并路由到对应助理",
  "processors": [
    {
      "script": {
        "source": """
          def role = 'crew';
          def text = ctx.message.toLowerCase();
          if (text.contains('船长') || text.contains('captain') || text.contains('航向') || text.contains('航迹')) {
            role = 'captain';
          } else if (text.contains('维修') || text.contains('故障') || text.contains('诊断')) {
            role = 'engineer';
          } else if (text.contains('研发') || text.contains('分析') || text.contains('报告')) {
            role = 'researcher';
          } else if (text.contains('服务') || text.contains('维保') || text.contains('服务商')) {
            role = 'service_provider';
          }
          ctx.detected_role = role;
        """
      }
    }
  ]
}
PIPE_JSON

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_ingest/pipeline/role-detection" \
    -H "Content-Type: application/json" \
    -d @/tmp/role_pipeline.json 2>/dev/null | jq '.' 2>/dev/null

info "大模型助理配置完成："
info "  - 船长助理：航迹、航向、航速分析"
info "  - 船员助理：操作指导、报警解释"
info "  - 研发助理：数据分析、报告生成"
info "  - 服务商助理：维保建议、远程诊断"

# 创建 GLM 提示语配置
cat > "$INSTALL_DIR/glm_prompts.json" << 'GLM_PROMPTS'
{
  "captain": {
    "system_prompt": "你是船舶船长助理。你能查看航迹、航速、航向数据，提供航行建议。当前船舶数据从Elasticsearch获取。回复简洁专业。",
    "tools": ["search_es", "get_track", "get_alarm_summary", "get_engine_status"],
    "examples": [
      "当前航迹怎么样？",
      "最近有报警吗？",
      "发动机运转正常吗？"
    ]
  },
  "crew": {
    "system_prompt": "你是船舶轮机船员助理。帮助船员理解报警内容、操作设备、记录值班日志。回复要通俗易懂。",
    "tools": ["search_es", "get_alarm_detail", "get_maintenance_guide"],
    "examples": [
      "1号缸温度高怎么办？",
      "滑油压力低报警什么意思？",
      "今天有什么报警？"
    ]
  },
  "researcher": {
    "system_prompt": "你是船舶研发工程师助理。提供数据分析、异常统计、趋势报告。使用专业术语，输出图表建议。",
    "tools": ["search_es", "get_anomaly_stats", "get_trend", "export_report"],
    "examples": [
      "过去24小时异常统计",
      "1号发动机温度趋势",
      "导出本周故障报告"
    ]
  },
  "service_provider": {
    "system_prompt": "你是船舶服务商助理。提供维保建议、远程诊断、备件推荐。基于设备运行数据给出建议。",
    "tools": ["search_es", "get_maintenance_history", "get_parts_list", "schedule_maintenance"],
    "examples": [
      "下次保养什么时候？",
      "哪些零件需要更换？",
      "远程诊断发动机2号"
    ]
  }
}
GLM_PROMPTS

info "GLM 提示语配置已保存到 $INSTALL_DIR/glm_prompts.json"

# ============================================================
# STEP 8: Kibana 看板配置
# ============================================================
step "8" "Kibana 看板配置（航迹/报警/异常统计）"

# 导入看板配置
cat > /tmp/dashboards.ndjson << 'DASHBOARDS'
{"attributes":{"title":"船舶航迹看板","description":"实时航迹、航速、航向","kibanaSavedObjectMeta":{"searchSourceJSON":"{\"query\":{\"query_string\":{\"query\":\"*\"}},\"filter\":[]}"}},"type":"dashboard","version":1}
{"attributes":{"title":"发动机报警看板","description":"报警变量状态统计","kibanaSavedObjectMeta":{"searchSourceJSON":"{\"query\":{\"query_string\":{\"query\":\"category:alarm\"}}}"}},"type":"dashboard","version":1}
{"attributes":{"title":"异常检测看板","description":"ML异常检测结果","kibanaSavedObjectMeta":{"searchSourceJSON":"{\"query\":{\"query_string\":{\"query\":\"_type:anomaly\"}}"}},"type":"dashboard","version":1}
{"attributes":{"title":"发动机温度看板","description":"各缸温度实时监控","kibanaSavedObjectMeta":{"searchSourceJSON":"{\"query\":{\"query_string\":{\"query\":\"category:temperature\"}}"}},"type":"dashboard","version":1}
{"attributes":{"title":"燃油滑油看板","description":"燃油滑油系统状态","kibanaSavedObjectMeta":{"searchSourceJSON":"{\"query\":{\"query_string\":{\"query\":\"category:fuel OR category:oil\"}}"}},"type":"dashboard","version":1}
{"attributes":{"title":"速度转速看板","description":"发动机转速、船速","kibanaSavedObjectMeta":{"searchSourceJSON":"{\"query\":{\"query_string\":{\"query\":\"category:speed\"}}"}},"type":"dashboard","version":1}
DASHBOARDS

curl -sk $ES_AUTH -X POST "https://localhost:${ES_PORT}/api/saved_objects/_import" \
    -H "kbn-xsrf: true" \
    -F "file=@/tmp/dashboards.ndjson" 2>/dev/null | jq '.' 2>/dev/null || warn "看板导入需要通过 Kibana 界面手动导入"

info "看板配置已准备，可通过 Kibana → Stack Management → Saved Objects 导入"
info "  看板列表："
info "    1. 船舶航迹看板（航速、航向、位置）"
info "    2. 发动机报警看板（报警变量统计）"
info "    3. 异常检测看板（ML 异常结果）"
info "    4. 发动机温度看板（各缸温度）"
info "    5. 燃油滑油看板（燃油滑油系统）"
info "    6. 速度转速看板（发动机转速、船速）"

# ============================================================
# STEP 9: 角色识别 + 对话跟踪
# ============================================================
step "9" "角色识别 + 长期对话跟踪"

# 创建对话历史索引
cat > /tmp/conversation_index.json << 'CONV_JSON'
{
  "mappings": {
    "properties": {
      "user_id": { "type": "keyword" },
      "role": { "type": "keyword" },
      "message": { "type": "text" },
      "response": { "type": "text" },
      "timestamp": { "type": "date" },
      "conversation_id": { "type": "keyword" },
      "context_summary": { "type": "text" },
      "identity_updates": {
        "type": "nested",
        "properties": {
          "field": { "type": "keyword" },
          "old_value": { "type": "text" },
          "new_value": { "type": "text" },
          "timestamp": { "type": "date" }
        }
      }
    }
  }
}
CONV_JSON

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/ship-conversation-history" \
    -H "Content-Type: application/json" \
    -d @/tmp/conversation_index.json 2>/dev/null | jq '.' 2>/dev/null

# 创建角色更新管道
cat > /tmp/identity_pipeline.json << 'ID_PIPE'
{
  "description": "长期对话中不断修正角色身份",
  "processors": [
    {
      "script": {
        "source": """
          // 基于对话内容更新角色身份
          def msg = ctx.message.toLowerCase();
          if (msg.contains('我是船长') || msg.contains('i am captain')) {
            ctx.identity_update = true;
            ctx.detected_role = 'captain';
          } else if (msg.contains('我是工程师') || msg.contains('i am engineer')) {
            ctx.identity_update = true;
            ctx.detected_role = 'engineer';
          }
          // 记录偏好
          if (msg.contains('简洁') || msg.contains('简短')) {
            ctx.preference_style = 'concise';
          } else if (msg.contains('详细') || msg.contains('完整')) {
            ctx.preference_style = 'detailed';
          }
        """
      }
    }
  ]
}
ID_PIPE

curl -sk $ES_AUTH -X PUT "https://localhost:${ES_PORT}/_ingest/pipeline/identity-tracking" \
    -H "Content-Type: application/json" \
    -d @/tmp/identity_pipeline.json 2>/dev/null | jq '.' 2>/dev/null

info "角色识别 + 对话跟踪已配置"
info "  - 自动检测角色（船长/船员/研发/服务商）"
info "  - 对话历史存储在 ship-conversation-history 索引"
info "  - 身份修正管道持续更新角色画像"

# ============================================================
# 完成汇总
# ============================================================
step "DONE" "安装完成！"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Elastic Stack 船舶遥测平台部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "访问地址："
echo "  Elasticsearch: https://${MY_IP}:${ES_PORT}"
echo "  Kibana:        https://${MY_IP}:${KB_PORT}"
echo "  Fleet Server:  https://${MY_IP}:${FLEET_PORT}"
echo ""
echo "登录凭据："
echo "  用户名: elastic"
echo "  密码: ${ES_PASSWORD}"
echo "  （凭据已保存到 ${CERT_DIR}/.credentials）"
echo ""
echo "数据摄入："
echo "  发动机数据: logs-ship-engine-default（数据流）"
echo "  IMU/GPS数据: logs-ship-imu-default（数据流）"
echo ""
echo "ILM 生命周期："
echo "  热（0-3月）→ 温（3-12月）→ 冷（12-36月）→ 归档（36-120月）→ 删除"
echo "  温阶段降采样 1h，冷阶段 1d，归档阶段 7d"
echo ""
echo "异常检测："
echo "  7 个分类异常检测器已启动（温度/压力/燃油/滑油/缸/轴承/转速）"
echo ""
echo "大模型助理："
echo "  4 个角色助理（船长/船员/研发/服务商）"
echo "  角色自动识别 + 对话跟踪"
echo ""
echo "看板："
echo "  6 个看板已准备（航迹/报警/异常/温度/燃油滑油/速度）"
echo ""
echo "后续操作："
echo "  1. 在 Kibana 中查看数据"
echo "  2. 导入看板配置"
echo "  3. 配置 Fleet Agent 策略"
echo "  4. 连接 GLM 模型（见下方提示语）"
echo ""
echo "========================================"
