# 🚢 船舶遥测数据平台 — 小白操作说明

## 这是什么？

一套在船上（或岸上机器）运行的数据平台，把发动机和 GPS 的采集数据自动收集、存储、分析异常、报警，并通过大模型助理回答你的问题。

---

## 📋 你需要准备什么

| 序号 | 准备项 | 说明 |
|---|---|---|
| 1 | 一台 linux或者Windows配置WSL机器 | 内存 ≥ 8GB，磁盘 ≥ 50GB |
| 2 | root/sudo 权限 | 安装软件用 |
| 3 | 网络连接 | 下载软件用（装好后可以离线） |
| 4 | 采集数据文件 | engine 和 imu 开头的 txt 文件 |

---

## 🚀 安装步骤（共 3 步）

### 第 1 步：把脚本放到服务器上

把 `PHM-ship` 文件夹拷机器上，比如放到 `/home/你的用户名/PHM-ship` 下。

### 第 2 步：运行安装脚本

打开终端（黑窗口），输入：

```bash
cd ~/PHM-ship
bash run_all.sh
```

然后等。大约 10-20 分钟（取决于网速）。屏幕上会不断滚动文字，**不用管**，只要最后没有红色的 `[✗]` 就行。

### 第 3 步：打开浏览器访问

安装完后，在浏览器输入：

```
https://服务器IP:5601
```

用户名：`elastic`  
密码：安装完会显示在终端最后几行（也会保存在 `PHM-ship/data/.credentials` 文件里）

---

## 📊 装好后能干什么

### 看数据

| 想看什么 | 在 Kibana 里怎么找 |
|---|---|
| 航迹 | Dashboard → 船舶航迹看板 |
| 报警 | Dashboard → 发动机报警看板 |
| 异常 | Dashboard → 异常检测看板 |
| 温度 | Dashboard → 发动机温度看板 |
| 燃油滑油 | Dashboard → 燃油滑油看板 |
| 转速 | Dashboard → 速度转速看板 |

### 问助理

安装包里有 4 个大模型助理：

| 助理 | 适合谁 | 能问什么 |
|---|---|---|
| 船长助理 | 船长 | "航迹怎么样？""有报警吗？""发动机正常吗？" |
| 船员助理 | 轮机船员 | "1号缸温度高怎么办？""滑油压力低什么意思？" |
| 研发助理 | 工程师 | "24小时异常统计""温度趋势""导出报告" |
| 服务商助理 | 维保商 | "下次保养什么时候？""哪些零件要换？" |

系统会自动识别你是哪种角色，不需要手动选择。

---

## 🔧 常见问题

### Q: 脚本跑到一半报错了

**A:** 看红色错误信息，常见原因：
1. 磁盘不够 → 清理空间或换大磁盘
2. 内存不够 → 在 `run_all.sh` 里把 `4g` 改成 `2g`
3. 网络不通 → 检查能不能上网

### Q: 访问不了 Kibana

**A:** 检查防火墙：
```bash
sudo ufw allow 5601/tcp   # Ubuntu
sudo firewall-cmd --add-port=5601/tcp --permanent && sudo firewall-cmd --reload  # CentOS
```

### Q: 想用域名访问

**A:** 在 `run_all.sh` 里改这一行：
```bash
MY_DOMAIN="你的域名.com"
```

### Q: 想换企业证书

**A:** 脚本自动从 `atomgit.com/tfh56/ESLienseSigner` 拉取了。如果想手动安装：
```bash
cd /opt/elastic/ESLienseSigner
bash install.sh --domain 你的域名 --ip 你的IP
```

### Q: 想改数据保留时间

**A:** 在 Kibana → Stack Management → Index Lifecycle Policies 里改 `ship-telemetry-policy`。

---

## 📁 目录说明

| 路径 | 内容 |
|---|---|
| `/opt/elastic/` | 软件安装目录 |
| `/data/elastic/` | 数据和日志 |
| `/data/elastic/.credentials` | 登录密码（保密！） |
| `/data/ship_ingest/` | 原始数据摄入目录 |
| `/data/elastic/snapshots/` | 快照备份 |
| `/data/elastic/certs/` | SSL 证书 |

---

## 🔄 日常操作命令

### 启动/停止服务

```bash
# 启动 Elasticsearch
sudo -u elastic /opt/elastic/elasticsearch-*/bin/elasticsearch -d -p /data/elastic/es.pid

# 启动 Kibana
sudo -u elastic /opt/elastic/kibana-*/bin/kibana &

# 停止 Elasticsearch
kill $(cat /data/elastic/es.pid)

# 停止 Kibana
kill $(cat /data/elastic/kibana.pid)
```

### 查看数据

```bash
# 查看数据流列表
curl -sk -u elastic:你的密码 https://localhost:9200/_data_stream

# 查看索引列表
curl -sk -u elastic:你的密码 https://localhost:9200/_cat/indices?v

# 查看异常检测结果
curl -sk -u elastic:你的密码 "https://localhost:9200/_ml/anomaly_detectors/ship-engine-temperature-anomaly/results"

# 查看最新 10 条发动机数据
curl -sk -u elastic:你的密码 "https://localhost:9200/logs-ship-engine-default/_search?size=10&sort=@timestamp:desc"
```

### 摄入新数据

```bash
# 摄入新的发动机数据文件
export ES_URL="https://localhost:9200"
export ES_USER="elastic"
export ES_PASS="你的密码"
export ENGINE_FILE="/path/to/new_engine_data.json"
python3 /opt/elastic/ingest_data.py

# 转换新的 IMU 数据
python3 /opt/elastic/convert_imu.py /path/to/imu_raw.txt /data/ship_ingest/imu
```

---

## 🤖 接入 GLM 大模型

### 连接 llama.cpp（Qwen3）

```bash
# 安装 llama.cpp（如果还没有）
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp && make -j

# 下载 Qwen3 模型（举例）
huggingface-cli download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf --local-dir ./models

# 启动 llama.cpp 服务
./llama-server -m models/qwen3-8b-q4_k_m.gguf --port 8080 --ctx-size 8192
```

### MCP 连接配置

在 Elasticsearch 配置中添加 MCP connector：

```json
{
  "mcp_server": {
    "url": "http://localhost:8080",
    "model": "qwen3-8b",
    "context_index": "ship-assistant-contexts"
  }
}
```

### GLM 提示语（已内置 4 个角色）

提示语配置在 `/opt/elastic/glm_prompts.json`，可以根据需要修改。

---

## 📐 功能拓展命令

### 更换 HTTP SSL 访问地址

```bash
# 生成新证书（含新域名/IP）
cd /data/elastic/certs

# 编辑 san.cnf，添加新域名
cat > san.cnf << 'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[req_distinguished_name]
CN = 新域名.com
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = 新域名.com
DNS.2 = *.新域名.com
IP.1 = 新IP地址
EOF

# 重新生成证书
openssl req -new -keyout ship.key -out ship.csr -config san.cnf -nodes
openssl x509 -req -in ship.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ship.crt -days 365 -extensions v3_req -extfile san.cnf

# 转 PKCS12
openssl pkcs12 -export -in ship.crt -inkey ship.key -out /opt/elastic/elasticsearch-*/config/certs/ship.p12 -passout pass:ShipCert@2026 -chain -CAfile ca.crt

# 重启 ES
kill $(cat /data/elastic/es.pid) && sleep 5
sudo -u elastic /opt/elastic/elasticsearch-*/bin/elasticsearch -d -p /data/elastic/es.pid
```

### 安装企业证书（atomgit tfh56/ESLienseSigner）

```bash
# 拉取工具
git clone https://atomgit.com/tfh56/ESLienseSigner.git /opt/elastic/ESLienseSigner

# 安装企业证书
cd /opt/elastic/ESLienseSigner
bash install.sh \
  --domain ship.yourcompany.com \
  --ip 你的IP \
  --es-home /opt/elastic/elasticsearch-* \
  --cert-dir /data/elastic/certs

# 重启 ES
kill $(cat /data/elastic/es.pid) && sleep 5
sudo -u elastic /opt/elastic/elasticsearch-*/bin/elasticsearch -d -p /data/elastic/es.pid
```

### 配置 Fleet Agent 策略

在 Kibana → Fleet → Agent Policies 里创建策略：

1. 点击 "Create agent policy"
2. 命名 `ship-engine-monitoring`
3. 添加集成：
   - Custom Logs（发动机 JSONL 日志）
   - Custom Logs（IMU GPS 日志）
   - System（系统监控）
4. 配置日志路径：
   - 发动机: `/data/ship_ingest/engine_*.json`
   - IMU: `/data/ship_ingest/imu_*.txt`
5. 保存并分配给 Agent

### 配置报警规则

在 Kibana → Stack Management → Rules and Connectors：

1. 创建新规则
2. 条件：`当 ship-engine-temperature-anomaly 的 anomaly_score > 75`
3. 动作：发送到 webhook / 邮件 / 短信
4. 频率：每 5 分钟检查一次

---

## 🧠 GLM 提示语合集

以下是内置的 4 个角色助理的 GLM 提示语，可直接用于 MCP 连接：

### 船长助理提示语

```
你是船舶船长助理。你能查看航迹、航速、航向数据，提供航行建议。
当前船舶数据从Elasticsearch获取。回复简洁专业。

当被问到航迹时，查询 logs-ship-imu-default 数据流，返回经纬度和航速。
当被问到报警时，查询 logs-ship-engine-default 中 category=alarm 的最新记录。
当被问到发动机状态时，查询 logs-ship-engine-default 最新温度、压力、转速数据。

示例对话：
用户：当前航迹怎么样？
助手：正在查询最近30分钟的航迹数据... 当前航向 XXX°，航速 XX 节，位置：北纬XX.XX°，东经XXX.XX°。
用户：最近有报警吗？
助手：过去24小时有 X 条报警，其中：温度报警 X 条，压力报警 X 条。最严重的是...
```

### 船员助理提示语

```
你是船舶轮机船员助理。帮助船员理解报警内容、操作设备、记录值班日志。
回复要通俗易懂，避免专业术语。

当船员问"XX报警什么意思"时，解释报警原因和处置方法。
当船员问"XX怎么办"时，给出操作步骤。
当船员问"今天有什么报警"时，列出今天的报警清单。

示例：
用户：1号缸温度高怎么办？
助手：1号缸温度偏高，可能原因和处置：
1. 检查冷却水流量是否正常
2. 检查喷油器是否漏油
3. 降低负荷观察温度变化
如果温度超过报警值，建议立即降速并联系轮机长。
```

### 研发助理提示语

```
你是船舶研发工程师助理。提供数据分析、异常统计、趋势报告。
使用专业术语，输出图表建议。

当被要求统计时，查询 Elasticsearch 聚合数据。
当被要求趋势分析时，查询时序数据和 ML 异常检测结果。
当被要求导出报告时，生成 Markdown 格式报告。

工具：
- search_es：查询 ES 数据
- get_anomaly_stats：获取异常统计
- get_trend：获取趋势数据
- export_report：导出分析报告
```

### 服务商助理提示语

```
你是船舶服务商助理。提供维保建议、远程诊断、备件推荐。
基于设备运行数据给出建议。

当被问到保养时，查询历史维护记录和当前设备状态。
当被问到备件时，根据异常检测推荐备件。
当被要求远程诊断时，连接 ES 查看实时数据和异常。

工具：
- get_maintenance_history：维保历史
- get_parts_list：备件推荐
- schedule_maintenance：安排维保计划
```
