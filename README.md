# SEPDS — 船舶发动机预测诊断系统

> 零代码、提示词驱动的船舶发动机监测与诊断系统，基于 **Elastic Stack 9.x + 本地大模型 (llama.cpp)**。单机模式、自签名证书、Token 认证。中专学生也能上手。

[![ES](https://img.shields.io/badge/Elasticsearch-9.x-005571)] [![Kibana](https://img.shields.io/badge/Kibana-9.x-e8478a)] [![LLM](https://img.shields.io/badge/LLM-llama.cpp-00a86b)] [![License](https://img.shields.io/badge/License-MIT-yellow)]

---

## 1. 这是什么？ <sub>ℹ️ 气泡提示：30 秒读完</sub>

SEPDS 把船艇发动机的 839 个传感器测点（燃油柜液位、绕组温度、轴承温度、排温、增压器转速、PMS 报警……）变成 Elasticsearch 上的**时序数据湖**，然后让四个角色——**指挥 / 船员 / 研发 / 运维**——用自然语言提问，由本地大模型写 ES 查询（Text2DSL）回答，并以"搜索→分析→评估→重试"的生产循环闭环。无云、无按次计费、操作者无需写代码。

- **数据**：滚动更新的 `engine_{年月日-时分秒}.txt` 文件 → 时序索引 → ILM 分层（3 月热 / 12 月温 / 36 月冷）。
- **大脑**：本地 `llama-server` 运行 `nex-n2-mini`（ModelScope）模型，配 ES LLM agent + Text2DSL。
- **眼睛**：Kibana 仪表盘——顶层唯美监控，下层可交互维护（参数分析、异常分类、月季年报告）。
- **纽带**：A2A 多智能体协议贯穿四角色，融合航行日记 + 科研日记，支持跨域沟通与总结。

<sub>💡 提示：本 README 中所有"冗长"内容都折叠到尾注（§9）或链接到 `scripts/` 下的文件。README 刻意控制在 500 行以内。</sub>

---

## 2. 架构 <sub>ℹ️ 一屏一瞥</sub>

```
        ┌──────────────────────────────────────────────────────────────┐
        │                    船艇发动机（839 测点）                      │
        │   燃油 · 润滑 · 绕组 · 轴承 · 排温 · 增压器 · PMS              │
        └────────────────────────┬─────────────────────────────────────┘
                                 │ 滚动 txt 文件
                                 ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  Elastic Agent（Fleet 托管） ──► engine_{ts}.txt 摄入          │
        └────────────────────────┬─────────────────────────────────────┘
                                 ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  Elasticsearch 9.x（单机、自签名证书、Token 认证）             │
        │   索引：ship_engine-*   ·   ILM：3 月热 / 12 月温 / 36 月冷    │
        └───────┬───────────────────────────────┬──────────────────────┘
                │                               │
                ▼                               ▼
   ┌────────────────────────┐        ┌──────────────────────────────┐
   │  Kibana 仪表盘          │        │  llama-server（GPU）         │
   │  顶层：唯美监控          │◄──────►│  模型：nex-n2-mini           │
   │  下层：可交互维护        │  A2A   │  技能：Text2DSL → ES 查询    │
   └────────────────────────┘        └──────────────────────────────┘
                ▲                               ▲
                │                               │
   ┌────────────┴───────────────────────────────┴────────────┐
   │  角色：指挥 · 船员 · 研发 · 运维                          │
   │  循环：搜索 → 分析 → 评估 → 重试                          │
   └──────────────────────────────────────────────────────────┘
```

<sub>ℹ️ 尾注 [1]（§9）解释为什么单机够用。</sub>

---

## 3. 快速开始 <sub>ℹ️ 5 步，复制即用</sub>

> 前置：一台带 NVIDIA 显卡的 Linux 机器，16 GB 内存，50 GB 空闲磁盘，root 权限。把 `<TOKEN>` 替换为第 2 步生成的 API Key。

```bash
# 1. 克隆并进入
git clone https://atomgit.com/your-org/sepds.git && cd sepds

# 2. 安装 ES + Kibana + Fleet + Agent，自签名证书，引导用户 'elastic' 密码 'changeme'
#    然后生成 API Key 写入 ~/.es_token
bash scripts/00_install_stack.sh
export ES_TOKEN=$(cat ~/.es_token)          # 后续所有 curl 调用统一用 Token 认证

# 3. 摄入 839 测点样本 + 设置 ILM 分层（3/12/36 月）
bash scripts/01_data_lake.sh

# 4. 编译 GPU 版 llama.cpp，拉取 nex-n2-mini，启动 llama-server，接 ES LLM agent + Text2DSL
bash scripts/02_inference.sh

# 5. 起四个角色、A2A 总线、双层仪表盘
bash scripts/03_hmi_a2a.sh && bash scripts/04_label_refactor.sh
```

打开 Kibana → `https://localhost:5601` → 登录 `elastic / changeme` → 仪表盘 → **SEPDS 顶层**（唯美）与 **SEPDS 维护**（可交互）。

<sub>💡 提示：`bash scripts/run_all.sh` 顺序执行 2–5 步，日志在 `logs/`。排障见 §9 尾注 [2]。</sub>

---

## 4. 文件布局 <sub>ℹ️ 东西放在哪</sub>

```
sepds/
├── README.md                  ← 你在这里（英文）
├── README_zh.md               ← 中文版（本文件）
├── software_copyright_source.txt      ← 软著源程序（英文，800 行）
├── software_copyright_source_zh.txt   ← 软著源程序（中文，800 行）
├── upload/
│   └── eng-var.txt             ← 839 个传感器测点（标签字典）
├── scripts/                   ← 英文脚本（合计 ≤300 行）
│   ├── 00_install_stack.sh    ← ES + Kibana + Fleet + Agent + 证书 + Token
│   ├── 01_data_lake.sh        ← 摄入 engine_*.txt + ILM 3/12/36
│   ├── 02_inference.sh        ← 显卡驱动 + llama.cpp + Text2DSL
│   ├── 03_hmi_a2a.sh          ← 四角色 + A2A + 仪表盘
│   ├── 04_label_refactor.sh    ← ES 发现/展示重构
│   └── run_all.sh              ← 编排器
├── scripts_zh/                 ← 中文脚本（合计 ≤300 行）
│   └── ...（同结构，中文注释）
├── prompts/                   ← 智能体提示词（压缩进脚本头注释；见 §9 [3]）
└── docs/
    ├── ARCHITECTURE.md        ← 深度架构（§2 链接）
    ├── ROLES.md               ← 角色规格（§6 链接）
    └── TROUBLESHOOTING.md     ← 排障（§9 [2] 链接）
```

<sub>ℹ️ `prompts/` 目录在仓库里刻意留空——智能体提示词被压缩进对应脚本的头注释（原因见 §9 尾注 [3]）。</sub>

---

## 5. 839 个测点 <sub>ℹ️ 监测什么</sub>

上传的 `eng-var.txt` 是一次轮询采集的 839 个测点样本：

| 分组 | 数量 | 示例 |
|---|---:|---|
| **PMS 报警** | 673 | `alarm_pms_cabin_fan_fault_1`、`alarm_pms_fuel_transfer_pump_running_2` |
| **发动机参数** | 120 | `engine_1_cylinder_a_freshwater_temperature`、`engine_1_turbocharger_lubricating_oil_inlet_pressure` |
| **发电机** | 24 | `generator_1_u_winding_temperature`、`generator_2_v_winding_temperature` |
| **油柜及杂项** | 22 | `no1_fuel_tank_left_level`、`lubricating_oil_tank_level`、`seawater_pressure` |

每个标签成为 `ship_engine-*` 索引中的一个字段。滚动文件 `engine_{YYYYMMDD-HHMMSS}.txt` 由 Elastic Agent 每个轮询周期拾取并按 `@timestamp` 索引。

<sub>ℹ️ §9 尾注 [4] 列出完整标签分类。839 行原文在 `upload/eng-var.txt`。</sub>

---

## 6. 角色与工作流 <sub>ℹ️ 谁做什么</sub>

四个角色，每个都是反射式智能体（搜索→分析→评估→重试）：

| 角色 | 提问 | 获得 | 重试条件 |
|---|---|---|---|
| **指挥** | "本航次 1 号机状态？" | 顶层仪表盘快照 + 风险分 | 置信度低 |
| **船员** | "为什么 A7 缸排温在升？" | Text2DSL 查询 + 异常类 + 原因 | 无命中 |
| **研发** | "近 3 月与去年同期对比" | 聚合报告 + 科研日记条目 | 数据稀疏 |
| **运维** | "生成月度维护报告" | 模板报告 + 工单建议 | 字段缺失 |

**A2A 总线**：角色之间互相对话（如 船员→研发："把这条异常模式记下来研究"）。总线把**航行日记**（船位、天气、海况）与**科研日记**（异常学习）融合，让上下文跨域流通。

<sub>ℹ️ 角色深度规格：见 `docs/ROLES.md`（已链接）。智能体提示词压缩在 `scripts/03_hmi_a2a.sh` 头注释里。</sub>

---

## 7. 关键 curl 命令 <sub>ℹ️ Token 认证，非 Basic 认证</sub>

> 所有 ES 调用统一用 **Token 认证**（`Authorization: ApiKey <TOKEN>`）。`elastic:changeme` 这个 Basic 凭证**只在安装时生成 Token 用一次**。

```bash
# 健康检查（Token 认证）
curl -sk -H "Authorization: ApiKey $ES_TOKEN" https://localhost:9200/_cluster/health?pretty

# 搜索某个测点（Token 认证）
curl -sk -H "Authorization: ApiKey $ES_TOKEN" \
  -X GET "https://localhost:9200/ship_engine-*/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"tag":"engine_1_cylinder_a7_temperature"}},"size":5}'

# 通过 LLM agent 做 Text2DSL（Token 认证）
curl -sk -H "Authorization: ApiKey $ES_TOKEN" \
  -X POST "https://localhost:9200/_ml/llm/ship_agent/_execute" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"过去 24 小时 A7 缸平均排温"}'

# ILM 策略（Token 认证）
curl -sk -H "Authorization: ApiKey $ES_TOKEN" \
  -X GET "https://localhost:9200/_ilm/policy/ship-engine-tiers?pretty"
```

<sub>💡 提示：`changeme` 是 Kibana 与 `elastic` 超级用户的引导登录口令。生产环境请轮换（见 §9 [5]）。</sub>

---

## 8. 仪表盘 <sub>ℹ️ 两层</sub>

**顶层——唯美监控**（`SEPDS 顶层`）：
- 全船发动机健康环（绿/黄/红），按子系统着色。
- 实时排温热力图（A1–A10、B1–B10 缸）。
- 增压器转速表、润滑油压力趋势。

**下层——可交互维护**（`SEPDS 维护`）：
- 参数分析：从 839 个测点中任选 → 时序 + 统计 + 异常标记。
- 异常分类：规则 + ML 双轨（规则标签来自 `alarm_*` 测点）。
- 报告：月度 / 季度 / 年度，模板化，可导出。

<sub>ℹ️ 仪表盘 JSON 由 `scripts/03_hmi_a2a.sh` 生成。自定义方法见 §9 [6]。</sub>

---

## 9. 尾注与内链

<sub>[1] **为什么单机？** 船就是一台机器。单机 ES 去掉集群闲聊，839 测点 × 36 月占盘 <50 GB，断航也能活。靠岸组舰队时再加节点。</sub>

<sub>[2] **排障**：`curl -sk -H "Authorization: ApiKey $ES_TOKEN" https://localhost:9200/_cluster/health?pretty` 必须返回 `status: green`。若为 yellow/red，查未分配分片：`.../_cat/shards?v`。完整指南：`docs/TROUBLESHOOTING.md`。</sub>

<sub>[3] **提示词为什么放在脚本头注释里？** 6 个工作流智能体（环境、数据湖、推理、人机界面、标签重构、任务）各有一段提示词。我们把它们压缩进对应脚本的头注释，让仓库保持扁平、提示词与代码同行。质量智能体与注意智能体仅内部使用，不随仓库输出（见 §9 [7]）。</sub>

<sub>[4] **标签分类**：839 测点 = 673 PMS 报警 + 120 发动机参数 + 24 发电机 + 22 油柜及杂项。完整清单在 `upload/eng-var.txt`。摄入脚本按标签路径自动派生字段名。</sub>

<sub>[5] **轮换 `changeme`**：`curl -sk -u elastic:changeme -X POST https://localhost:9200/_security/user/_password -d '{"password":"<new>"}'`——然后重新生成 API Key。连岸 WiFi 前务必做。</sub>

<sub>[6] **自定义仪表盘**：编辑 `scripts/03_hmi_a2a.sh` 中的 `build_dashboard()` 函数里的 JSON 块，然后 `curl -X POST .../_kbn/api/saved_objects/dashboard` 带 Token。Kibana → 堆栈管理 → 已保存对象 导入。</sub>

<sub>[7] **质量与注意智能体——仅内部**：质量智能体（智能体间交接审计 + 流水线循环 + 软著一致性）与注意智能体（即本 §9 区域）只在运行时存在，不作为仓库文件输出。其逻辑分别嵌入为 `run_all.sh` 中的审计钩子，以及本 README 的尾注层。每层流水线迭代 ≥10 轮，直到质量评分达"优秀"。</sub>

<sub>[8] **软件著作权（软著）**：源程序文件 `software_copyright_source.txt`（英文）与 `software_copyright_source_zh.txt`（中文）各 800 行，自包含节选，用于著作权登记。它们合并所有脚本并内联配置与压缩后的智能体提示词。</sub>

---

## 10. 许可证

MIT。见 `LICENSE`。839 测点字典 `upload/eng-var.txt` 按原样提供，仅供评估。

---

<sub>SEPDS · Elastic Stack 9.x · llama.cpp · nex-n2-mini · 单机 · Token 认证 · MIT</sub>
