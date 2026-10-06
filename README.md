# 船舶智能监控平台 · ES Stack 一键部署（外行可用版）

## 这是什么
一个 bash 脚本，帮你从零搭起一套船舶发动机 + GPS 监控平台：
- 下载安装 Elasticsearch + Kibana（自动安全）
- HTTPS + 域名证书 + 企业 license
- Elastic Agent + Fleet 集中管理
- 摄入发动机/IMU 数据，6MB 自动滚动
- 数据生命周期（热温冷冻）+ 快照 + 降采样
- 异常检测 + ML 故障跟踪 + F1 优化
- 四角色数字助理（船长/船员/研发/机务）
- Kibana 看板（航迹/报警/异常）
- A2A 联通 Hermes，智能体自进化

## 5 步上手（外行也能用）

### 第 1 步：把整个目录传到服务器
```
scp -r ship_es_stack/ user@server:~/
```

### 第 2 步：登录服务器，进入目录
```
ssh user@server
cd ~/ship_es_stack
```

### 第 3 步：给脚本加执行权限
```
chmod +x ship_es_stack.sh scripts/*.py scripts/*.sh
```

### 第 4 步：运行脚本
```
./ship_es_stack.sh
```

### 第 5 步：按菜单数字回车
```
1  → 安装 ES + Kibana
2  → 配 HTTPS
3  → 装 enterprise license
4  → 配 Fleet + Agent
5  → 摄入示例数据
6  → 配 ILM 分层
7  → 异常检测 + ML
8  → 数字助理 + 看板
9  → A2A + Hermes
10 → 用 bun 运行 Kibana（实验性，自动回退到 node）
a  → 一键全跑（1-9）
s  → 看状态
q  → 退出
```

## 文件说明

```
ship_es_stack/
├── ship_es_stack.sh          ← 主脚本（菜单驱动）
├── README.md                 ← 本文件
├── conf/                     ← ES/Kibana/ML 配置 JSON
│   ├── engine_template.json     发动机数据索引模板
│   ├── imu_template.json        IMU 数据索引模板
│   ├── ilm_policy.json          热温冷冻生命周期
│   ├── slm_policy.json          自动快照策略
│   ├── filestream_input.json    Fleet filestream 输入
│   ├── ml_anomaly.json          异常检测任务
│   ├── ml_classifier.json       故障分类（F1 优化）
│   ├── watcher_alert.json       告警规则
│   ├── events_template.json     事件索引模板
│   ├── assistant_connector.json 数字助理连接器
│   ├── evolution_template.json  自进化记录模板
│   ├── track_dashboard.ndjson   航迹看板
│   ├── alerts_dashboard.ndjson  报警看板
│   └── anomaly_dashboard.ndjson 异常看板
├── scripts/                  ← 辅助脚本
│   ├── imu_gps_to_unix.py       IMU GPS 时间 → Unix
│   └── roll_sensor.sh           6MB 滚动守护
├── glm_prompts/              ← GLM 智能体提示词（每模块一份）
│   ├── m1_install.md
│   ├── m2_https_san.md
│   ├── m3_license.md
│   ├── m4_fleet.md
│   ├── m5_filestream.md
│   ├── m6_ilm.md
│   ├── m7_anomaly_ml.md
│   ├── m8_assistant.md
│   ├── m9_a2a.md
│   └── m10_bun.md              用 bun 运行 Kibana 的提示词
└── logs/                     ← 运行日志
```

## 常用环境变量（可选）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ES_VER` | 8.15.0 | ES/Kibana/Agent 版本 |
| `DOMAIN` | ship.local | HTTPS 域名 |
| `HOT_MONTHS` | 3 | 热阶段月数 |
| `WARM_MONTHS` | 12 | 温阶段月数 |
| `COLD_MONTHS` | 36 | 冷阶段月数 |
| `ROLL_MAX_MB` | 6 | 单文件最大 MB |
| `UPLOAD_DIR` | /home/z/my-project/upload | 示例数据目录 |

示例：
```
DOMAIN=ship.yard.com HOT_MONTHS=6 ./ship_es_stack.sh
```

## 遇到问题怎么办

1. **看日志**：`logs/ship_es_*.log`
2. **看状态**：菜单选 `s`
3. **找 GLM 智能体**：每个模块运行结束会打印一段 GLM 提示词，复制贴给智能体即可

## 数据格式说明

### 示例数据自动探测
模块 5 会自动在 `$UPLOAD_DIR`（默认 `/home/z/my-project/upload`）下查找：
- `*engine_*.txt` → 发动机数据（取修改时间最新的一份）
- `*imu_*.txt` → IMU 数据（取修改时间最新的一份）

无论上传会话 ID 前缀如何变化（如 `6aa31644..._engine_...`），都能自动识别。

### 发动机数据（engine_*.txt）
每行一个 JSON：
```json
{"name": "engine/engine_1_speed", "value": 0.0, "timestamp": 1765814676.93}
```
- `name`：变量名（100+ 个，含温度/压力/液位/告警）
- `value`：数值
- `timestamp`：Unix 秒

### IMU 数据（imu_*.txt）
NMEA 报文：
```
$GTIMU,2397,144353.9600,-0.0170,-0.0363,0.0125,0.0221,0.0136,1.0026,30.9*56
$GPFPD,2397,144353.9800,20.503,0.891,-1.294,34.75627488,119.45087031,4.61,...
```
脚本会自动把 `144353.9600`（HHMMSS.SS UTC）转成 Unix 时间戳（如 `1765896233.96` → `2025-12-16T14:43:53Z`）。

## 安全提示

- `.es_pass` 文件保存了 elastic 密码，权限已设 600，**不要外传**
- 生产环境请用真正的 CA 签发证书，不要用脚本里的自签
- 企业 license 签名工具（ESLienseSigner）来自第三方，请评估合规风险

## 模块 10：用 bun 运行 Kibana（实验性）

### 这是什么
Kibana 官方用 Node.js 运行。Bun 是一个更快的 JavaScript 运行时（启动快 2-3 倍，内存占用低 30%）。
本模块尝试用 bun 启动 Kibana，**失败会自动回退到官方 node**，不影响使用。

### 怎么用
```
./ship_es_stack.sh
# 选 10
```

### 脚本做了什么
1. 自动安装 bun（如未安装）
2. 停掉当前 Kibana（无论 node 还是 bun 启动的）
3. 用 `bun --bun src/cli/cli.js serve` 启动
4. 等待 90 秒检测 `/api/status` 是否 200
5. 成功 → 显示 bun 运行中；失败 → 自动用 Kibana 自带 node 回退
6. 状态查看（菜单 s）会显示 Kibana 是 `bun` 还是 `node` 运行

### 已知限制
| 组件 | 兼容性 |
|------|--------|
| 主进程 | ⚠️ 部分 |
| Optimizer | ❌ 多数失败 |
| Native modules | ❌ 需 rebuild |
| Saved Objects | ✅ 兼容 |
| Reporting | ❌ 不兼容 |

### 推荐用法
- **开发/测试**：用 bun 加速冷启动
- **生产**：继续用官方 node
- 遇到问题看 `glm_prompts/m10_bun.md`，里面有贴给智能体的提示词模板

### 手动回退
```bash
pkill -f 'bun.*cli.js'
/path/to/kibana/bin/kibana --allow-root
```
