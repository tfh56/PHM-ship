# Ship Telemetry Data Platform – Layman Operation Manual

## What Is This?

A data platform running on shipboard or shore\-side servers\. It automatically collects, stores, and analyzes engine and GPS acquisition data, triggers anomaly alerts, and answers user queries via an LLM assistant\.

---

## Prerequisites

|No\.|Item|Description|
|---|---|---|
|1|Linux Server|RAM ≥ 8GB, Disk ≥ 50GB|
|2|root/sudo Privileges|Required for software installation|
|3|Network Access|For downloading software \(offline operation supported post\-installation\)|
|4|Raw Data Files|TXT files prefixed with `engine` and `imu`|

---

## Installation Procedure \(3 Steps Total\)

### Step 1: Transfer Scripts to Server

Copy the entire `elk_stack` folder to your server, e\.g\., under `/home/YourUsername/`\.

### Step 2: Execute Installation Script

Open terminal and run the following commands:

```bash
cd ~/elk_stack
bash run_all.sh
```

Wait for the process to complete \(10–20 minutes depending on network speed\)\. Ignore scrolling logs; installation succeeds if no red `[✗]` error tags appear in the final output\.

### Step 3: Access via Web Browser

After installation completes, enter the following address in your browser:

```Plain Text
https://ServerIP:5601
```

- Username: `elastic`

- Password: Displayed in the last lines of terminal output, also stored in `/data/elastic/.credentials` \(keep confidential\)

---

## Platform Capabilities After Deployment

### Data Visualization Dashboard

|Target Data|Navigation Path in Kibana|
|---|---|
|Ship Track|Dashboard → Vessel Track Dashboard|
|Alarms|Dashboard → Engine Alarm Dashboard|
|Anomalies|Dashboard → Anomaly Detection Dashboard|
|Temperature Metrics|Dashboard → Engine Temperature Dashboard|
|Fuel \& Lube Oil Data|Dashboard → Fuel \& Lube Oil Dashboard|
|Rotational Speed|Dashboard → Speed \& RPM Dashboard|

### LLM Assistant Modules

Four built\-in LLM assistants with role\-adaptive automatic identification \(no manual role switching required\):

|Assistant Role|Target User Group|Supported Queries|
|---|---|---|
|Captain Assistant|Ship Captain|"How is the navigation track?", "Any active alarms?", "Is the engine operating normally?"|
|Crew Engineer Assistant|Marine Engineering Crew|"How to resolve high temperature on Cylinder 1?", "What does low lube oil pressure indicate?"|
|R\&D Engineer Assistant|Technical Engineers|"24\-hour anomaly statistics", "Temperature trend analysis", "Export analytical reports"|
|Service Provider Assistant|Maintenance Vendors|"Next scheduled maintenance date", "Spare parts requiring replacement"|

---

## Troubleshooting Guide

### Q: Script fails mid\-execution

**A:** Review red error logs for root causes:

1. Insufficient disk storage – Free up disk space or upgrade storage hardware

2. Insufficient memory – Modify memory allocation parameter from `4g` to `2g` inside `run_all.sh`

3. Network disconnection – Verify internet connectivity

### Q: Unable to access Kibana web UI

**A:** Configure firewall port forwarding with corresponding commands:

```bash
# Ubuntu
sudo ufw allow 5601/tcp

# CentOS
sudo firewall-cmd --add-port=5601/tcp --permanent && sudo firewall-cmd --reload
```

### Q: Access platform via custom domain name

**A:** Edit the following line in `run_all.sh`:

```bash
MY_DOMAIN="your-domain.com"
```

### Q: Replace default SSL certificate with enterprise certificate

**A:** The script automatically pulls certificate tools from `atomgit.com/tfh56/ESLienseSigner`\. Manual installation command:

```bash
cd /opt/elastic/ESLienseSigner
bash install.sh --domain your-domain --ip ServerIP
```

### Q: Adjust data retention period

**A:** Navigate to Kibana → Stack Management → Index Lifecycle Policies, edit the policy named `ship-telemetry-policy`\.

---

## Directory Structure Reference

|Path|Content Description|
|---|---|
|`/opt/elastic/`|Main software installation directory|
|`/data/elastic/`|Persistent data and log storage|
|`/data/elastic/.credentials`|Login credential file \(strict confidentiality required\)|
|`/data/ship_ingest/`|Raw data ingestion directory|
|`/data/elastic/snapshots/`|System snapshot backup storage|
|`/data/elastic/certs/`|SSL certificate storage directory|

---

## Daily Operation Commands

### Service Start / Stop

```bash
# Start Elasticsearch
sudo -u elastic /opt/elastic/elasticsearch-*/bin/elasticsearch -d -p /data/elastic/es.pid

# Start Kibana
sudo -u elastic /opt/elastic/kibana-*/bin/kibana &

# Stop Elasticsearch
kill $(cat /data/elastic/es.pid)

# Stop Kibana
kill $(cat /data/elastic/kibana.pid)
```

### Data Query Commands

```bash
# List all data streams
curl -sk -u elastic:YourPassword https://localhost:9200/_data_stream

# List all indices
curl -sk -u elastic:YourPassword https://localhost:9200/_cat/indices?v

# Query engine temperature anomaly detection results
curl -sk -u elastic:YourPassword "https://localhost:9200/_ml/anomaly_detectors/ship-engine-temperature-anomaly/results"

# Fetch latest 10 engine telemetry records (sorted by timestamp descending)
curl -sk -u elastic:YourPassword "https://localhost:9200/logs-ship-engine-default/_search?size=10&sort=@timestamp:desc"
```

### Import New Raw Data

```bash
# Import engine data JSON file
export ES_URL="https://localhost:9200"
export ES_USER="elastic"
export ES_PASS="YourPassword"
export ENGINE_FILE="/path/to/new_engine_data.json"
python3 /opt/elastic/ingest_data.py

# Convert raw IMU TXT data to standard ingestion format
python3 /opt/elastic/convert_imu.py /path/to/imu_raw.txt /data/ship_ingest/imu
```

---

## LLM Integration Guide \(GLM Series\)

### Connect Local LLM Service via llama\.cpp \(Qwen3 Example\)

```bash
# Install llama.cpp (skip if already deployed)
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp && make -j

# Download Qwen3 GGUF model
huggingface-cli download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf --local-dir ./models

# Launch local LLM inference service
./llama-server -m models/qwen3-8b-q4_k_m.gguf --port 8080 --ctx-size 8192
```

### MCP Connector Configuration for Elasticsearch

Add the following JSON configuration to Elasticsearch settings:

```json
{
  "mcp_server": {
    "url": "http://localhost:8080",
    "model": "qwen3-8b",
    "context_index": "ship-assistant-contexts"
  }
}
```

### GLM Prompt Storage Path

Predefined role prompts are stored in `/opt/elastic/glm_prompts.json` and editable on demand\.

---

## Advanced Extension Operations

### Regenerate SSL Certificate for New Domain/IP

```bash
# Navigate to certificate directory
cd /data/elastic/certs

# Generate SAN configuration file with updated domain & IP
cat > san.cnf << 'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[req_distinguished_name]
CN = new-domain.com
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = new-domain.com
DNS.2 = *.new-domain.com
IP.1 = NewServerIP
EOF

# Generate CSR and private key
openssl req -new -keyout ship.key -out ship.csr -config san.cnf -nodes

# Issue signed certificate valid for 365 days
openssl x509 -req -in ship.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ship.crt -days 365 -extensions v3_req -extfile san.cnf

# Export PKCS12 certificate bundle
openssl pkcs12 -export -in ship.crt -inkey ship.key -out /opt/elastic/elasticsearch-*/config/certs/ship.p12 -passout pass:ShipCert@2026 -chain -CAfile ca.crt

# Restart Elasticsearch to apply new certificate
kill $(cat /data/elastic/es.pid) && sleep 5
sudo -u elastic /opt/elastic/elasticsearch-*/bin/elasticsearch -d -p /data/elastic/es.pid
```

### Install Enterprise Certificate via ESLienseSigner

```bash
# Pull certificate signing tool repository
git clone https://atomgit.com/tfh56/ESLienseSigner.git /opt/elastic/ESLienseSigner

# Execute enterprise certificate installation script
cd /opt/elastic/ESLienseSigner
bash install.sh \
  --domain ship.yourcompany.com \
  --ip ServerIP \
  --es-home /opt/elastic/elasticsearch-* \
  --cert-dir /data/elastic/certs

# Restart Elasticsearch service
kill $(cat /data/elastic/es.pid) && sleep 5
sudo -u elastic /opt/elastic/elasticsearch-*/bin/elasticsearch -d -p /data/elastic/es.pid
```

### Fleet Agent Policy Configuration

Navigate to Kibana → Fleet → Agent Policies and complete the following steps:

1. Click "Create agent policy"

2. Name policy `ship-engine-monitoring`

3. Add required integrations:

    - Custom Logs \(engine JSONL telemetry logs\)

    - Custom Logs \(IMU \& GPS raw logs\)

    - System \(server host monitoring\)

4. Configure log file paths:

    - Engine logs: `/data/ship_ingest/engine_*.json`

    - IMU logs: `/data/ship_ingest/imu_*.txt`

5. Save policy and assign to target Fleet Agents

### Alarm Rule Configuration

Navigate to Kibana → Stack Management → Rules and Connectors:

1. Create new alert rule

2. Trigger condition: `anomaly_score > 75` from detector `ship-engine-temperature-anomaly`

3. Notification delivery channels: Webhook / Email / SMS

4. Execution frequency: Check every 5 minutes

---

## Full Predefined GLM Role Prompts

### Captain Assistant Prompt

```Plain Text
You are a dedicated vessel captain assistant. You can retrieve navigation track, speed and heading data and provide professional navigation recommendations.
All vessel operational data is fetched from Elasticsearch. Keep replies concise and industry-standard.
- For track queries: Retrieve data stream logs-ship-imu-default, return latitude, longitude and vessel speed.
- For alarm queries: Fetch latest records with category=alarm from logs-ship-engine-default.
- For engine status queries: Pull real-time temperature, pressure and RPM metrics from logs-ship-engine-default.

Sample Dialogue:
User: How is the current navigation track?
Assistant: Querying track data from the last 30 minutes... Current heading XXX°, speed XX knots, Position: N XX.XX°, E XXX.XX°.
User: Are there any recent alarms?
Assistant: X alarms triggered within past 24 hours, including X temperature alarms and X pressure alarms. The most critical alert is...
```

### Marine Engineer Crew Assistant Prompt

```Plain Text
You are an engineering crew assistant for marine machinery operators. Explain alarm root causes, standard operating procedures and maintainer log guidance. Use plain language with minimal complex technical jargon.
- When asked about alarm definitions: Explain failure causes and step-by-step resolution workflows.
- When asked about troubleshooting: List actionable operational steps.
- When requesting daily alarm overview: Output complete daily alarm inventory.

Sample Dialogue:
User: How do I resolve high temperature on Cylinder 1?
Assistant: Elevated Cylinder 1 temperature potential causes & countermeasures:
1. Verify cooling water flow rate
2. Inspect fuel injector for leakage
3. Reduce engine load and monitor temperature fluctuations
If temperature exceeds alarm threshold, immediately lower vessel speed and notify chief engineer.
```

### R\&D Engineer Assistant Prompt

```Plain Text
You are a ship R&D engineering assistant responsible for data analysis, anomaly statistics and trend reporting. Utilize professional technical terminology and suggest visualization charts when applicable.
- Statistical requests: Run Elasticsearch aggregation queries for quantitative metrics.
- Trend analysis requests: Fetch time-series data and machine learning anomaly detection results.
- Report export requests: Generate standardized Markdown analytical reports.

Supported internal tools:
- search_es: Query Elasticsearch raw data
- get_anomaly_stats: Aggregate full anomaly statistics
- get_trend: Extract time-series trend datasets
- export_report: Generate downloadable analysis reports
```

### Maintenance Service Provider Assistant Prompt

```Plain Text
You are a vessel maintenance service assistant delivering maintenance scheduling, remote fault diagnosis and spare part recommendations based on full equipment runtime telemetry data.
- Maintenance inquiries: Cross-reference historical service logs and real-time equipment operating status.
- Spare part inquiries: Recommend replacement components by matching anomaly detection outputs.
- Remote diagnosis requests: Pull live real-time data and historical fault records from Elasticsearch.

Supported internal tools:
- get_maintenance_history: Retrieve complete service maintenance logs
- get_parts_list: Generate matched spare part replacement list
- schedule_maintenance: Create optimized maintenance work plans
```

> （注：部分内容可能由 AI 生成）
