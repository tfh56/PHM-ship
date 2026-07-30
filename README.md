# SEPDS — 船舶发动机预测诊断系统

> 零代码、提示词驱动的船舶发动机监测与诊断系统，基于 **Elastic Stack 9.4.4 + 本地大模型 (llama.cpp)**。
> 单机运行 · 自签名证书 · **Bearer Token 认证** · 小白上手。

[![ES](https://img.shields.io/badge/Elasticsearch-9.x-005571)] [![Kibana](https://img.shields.io/badge/Kibana-9.x-e8478a)] [![LLM](https://img.shields.io/badge/LLM-llama.cpp-00a86b)] [![License](https://img.shields.io/badge/License-MIT-yellow)]

| | |
|:--|:--|
| 📦 **安装** | `bash scripts_zh/00_install_stack.sh` → ES + Kibana + Fleet + Agent + 证书 |
| 📥 **摄入** | `bash scripts_zh/01_data_lake.sh` → 839 条 JSONL → 时序索引 + ILM |
| 🧠 **推理** | `bash scripts_zh/02_inference.sh` → llama.cpp + Text2DSL |
| 🖥️ **仪表盘** | `bash scripts_zh/03_hmi_a2a.sh && bash scripts_zh/04_label_refactor.sh` |
| 🚀 **一键** | `bash scripts_zh/run_all.sh`（扁平单遍）|

---

## 1. 这是什么？

SEPDS 把船艇发动机的 **839 个传感器读数**（JSONL：`{name, value, timestamp}`）变成 Elasticsearch 上的时序数据湖，然后让四个角色——**指挥 / 船员 / 研发 / 运维**——用自然语言提问。本地大模型写 ES 查询（Text2DSL），回答回流，以 `搜索 → 分析 → 评估 → 重试` 循环闭环。无云、无按次计费、操作者无需写代码。

| 层 | 技术栈 |
|---|---|
| **数据** | 滚动 `engine_{年月日-时分秒}.txt`（JSONL）→ `ship_engine-*` 索引 → ILM 分层（3 月热 / 12 月温 / 36 月冷）|
| **大脑** | `llama-server` + `nex-n2-mini`（ModelScope）跑 GPU → ES LLM agent + Text2DSL |
| **眼睛** | Kibana——上面监控 · 下层交互维护 |
| **纽带** | A2A 多智能体协议融合航行日记 + 科研日记 |

> 💡 **气泡提示** — 冗长内容折叠到 [§9 尾注](#9-尾注与内链)或链接到 `scripts_zh/` 下的文件。

---

## 2. 架构

```
        ┌──────────────────────────────────────────────────────────────┐
        │              船艇发动机（839 传感器，JSONL）                    │
        │   燃油 · 润滑 · 绕组 · 轴承 · 排温 · 增压器 · PMS              │
        └────────────────────────┬─────────────────────────────────────┘
                                 │ 滚动 engine_*.txt
                                 ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  Elastic Agent（Fleet 托管）──► ship_engine-* 时序索引          │
        │  ILM：3 月热 ──► 12 月温 ──► 36 月冷 ──► 删除                   │
        └────────────────────────┬─────────────────────────────────────┘
                                 │ Bearer Token（curl）
                                 ▼
        ┌──────────────────┐    ┌───────────────────┐
        │  llama-server    │◄──►│  ES LLM agent     │
        │  nex-n2-mini GPU │    │  Text2DSL         │
        └──────────────────┘    └────────┬──────────┘
                                         │ 自然语言 → DSL
                                         ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  4 个反射式角色（A2A 总线）                                      │
        │  指挥 ─► 船员 ─► 研发 ─► 运维                                   │
        │  搜索 → 分析 → 评估 → 重试                                      │
        └────────────────────────┬─────────────────────────────────────┘
                                 ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  Kibana 仪表盘                                                 │
        │  ▲ 上层：健康环 · 排温热力图 · 增压器表 · 燃油柜液位            │
        │  ▼ 下层：参数分析 · 异常分类 · 月季年报告                       │
        └──────────────────────────────────────────────────────────────┘
```

---

## 3. 快速开始（5 步）

> ℹ️ **前置条件**：Linux x86_64、16 GB 内存、显卡（≥8 GB）、root/sudo。

```bash
# 1. 克隆并进入
git clone https://openi.pcl.ac.cn/tfh56/PHM-ship.git && cd PHM-ship

# 2. 安装 ES + Kibana + Fleet + Agent + 自签名证书
bash scripts_zh/00_install_stack.sh
export ES_TOKEN=$(cat ~/.es_token)        # 后续所有 curl 用此 Bearer Token

# 3. 摄入 839 条传感器读数 → 时序数据湖 + ILM 分层
bash scripts_zh/01_data_lake.sh

# 4. 启动本地大模型 + 接 Text2DSL
bash scripts_zh/02_inference.sh

# 5. 建仪表盘 + 4 角色 + A2A 总线
bash scripts_zh/03_hmi_a2a.sh && bash scripts_zh/04_label_refactor.sh
```

> 🔗 **一键**：`bash scripts_zh/run_all.sh` 扁平单遍跑完 5 步。

打开 Kibana → `https://127.0.0.1:5601` → 登录 `elastic` / `changeme`。

---

## 4. 数据模拟规则

> ℹ️ 上传的 `engine-one-tune-name-value.txt` 是一次轮询的 839 条 JSONL 样本。`01_data_lake.sh` 从中模拟滚动轮询：

| 规则 | 细节 |
|---|---|
| **单一时间戳** | 一轮 839 变量共用同一 `date +%s` 时间戳 |
| **数值型 ±10%** | `value = 原值 × (0.9 + rand×0.2)`；若原值为整数（如 `700.0`），结果**舍入**为整数 |
| **逻辑型 10% 翻转** | `alarm_*` 标签：`P=0.1` 概率 0↔1 翻转 |

<details>
<summary><b>📖 点击展开 awk 模拟代码</b></summary>

```awk
# 一轮 = 839 变量，单一时间戳，数值型 ±10%（整数舍入），逻辑型 10% 翻转
awk -v ts="$(date +%s)" '{
  gsub(/\r/,"");                                  # 去掉 Windows 回车
  n=$0; sub(/.*"name": "/,"",n); sub(/".*/,"",n); # 提取 name
  v=$0; sub(/.*"value": /,"",v); sub(/[,}].*/,"",v); val=v+0;
  if (n ~ /alarm_/) {                             # 逻辑型：10% 翻转
    if (rand()<0.1) val=(val==0)?1:0;
    out=val;
  } else {                                        # 数值型：±10%
    nv=val*(0.9+rand()*0.2);
    if (val==int(val)) out=int(nv+0.5);           # 整数 → 舍入
    else out=sprintf("%.4f",nv);                  # 浮点 → 保留
  }
  printf "{\"name\":\"%s\",\"value\":%s,\"timestamp\":%s}\n",n,out,ts;
}' "$SAMPLE" > "$OUT"
```

</details>

---

## 5. 角色与 A2A

| 角色 | 重试触发 | 关注点 |
|---|---|---|
| 🎖️ **指挥** | 置信度低 | 总体状态、决策 |
| ⚓ **船员** | 无命中 | 值班、即时操作 |
| 🔬 **研发** | 数据稀疏 | 模式分析、模型调优 |
| 🔧 **运维** | 字段缺失 | 维护排程、报告 |

每个角色跑 `搜索 → 分析 → 评估 → 重试`，并向 A2A 日记总线（`sepds_diary` 索引）发帖，融合航行 + 科研条目。

---

## 6. 仪表盘

| 层 | 面板 |
|---|---|
| **▲ 顶层 — 唯美监控** | 健康环 · 排温热力图 · 增压器表 · 燃油柜液位 |
| **▼ 下层 — 可交互维护** | 参数分析 · 异常分类（规则 + ML）· 月季年报告 |

> 🔗 仪表盘 JSON 由 `scripts_zh/03_hmi_a2a.sh` 生成。自定义方法见 [§9.6](#9-尾注与内链)。

---

## 7. Text2DSL 示例

<details>
<summary><b>📖 点击展开 自然语言 → ES DSL 示例</b></summary>

| 自然语言 | ES DSL（针对 `ship_engine-*`）|
|---|---|
| "过去 24 小时 A7 缸平均排温" | `{"size":0,"query":{"bool":{"filter":[{"term":{"name":"engine_1_cylinder_a7_temperature"}},{"range":{"@timestamp":{"gte":"now-24h"}}}]}},"aggs":{"avg_v":{"avg":{"field":"value"}}}}` |
| "过去 1 小时润滑油压力最大值" | `{"size":0,"query":{"bool":{"filter":[{"wildcard":{"name":"*lubricating_oil_pressure*"}},{"range":{"@timestamp":{"gte":"now-1h"}}}]}},"aggs":{"max_v":{"max":{"field":"value"}}}}` |
| "过去 4 小时报警计数" | `{"size":0,"query":{"bool":{"filter":[{"term":{"group":"alarm"}},{"range":{"@timestamp":{"gte":"now-4h"}}}]}}}` |

</details>

---

## 8. 文件清单

```
download/
├── README.md                          ← 本文件（英文，git 首页）
├── README_zh.md                       ← 中文版（本文件）
├── software_copyright_source.txt      ← 软著英文（~800 行，自包含）
├── software_copyright_source_zh.txt   ← 软著中文
├── scripts/                           ← 英文脚本（6 个文件，≤600 行）
│   ├── 00_install_stack.sh
│   ├── 01_data_lake.sh
│   ├── 02_inference.sh
│   ├── 03_hmi_a2a.sh
│   ├── 04_label_refactor.sh
│   └── run_all.sh
└── scripts_zh/                        ← 中文脚本（6 个文件）
```

---

## 9. 尾注与内链

<details>
<summary><b>📖 点击展开尾注 [1]–[6]</b></summary>

**[1] 为什么单机？** 船就是一台机器。单机 ES 去掉集群闲聊，839 测点 × 36 月占盘 <50 GB，断航也能活。靠岸组舰队时再加节点。

**[2] 排障**：`curl -sk -H "Authorization: Bearer $ES_TOKEN" https://localhost:9200/_cluster/health?pretty` 必须返回 `status: green`。若为 yellow/red，查未分配分片：`.../_cat/shards?v`。

**[3] 提示词为什么放在脚本头注释里？** 5 个工作流智能体（环境、数据湖、推理、人机界面、标签重构）各有一段压缩提示词，放在对应脚本的头注释里，让仓库保持扁平、提示词与代码同行。

**[4] 测点分类**：839 测点 = 673 PMS 报警 + 120 发动机参数 + 24 发电机 + 22 油柜及杂项。完整清单在 `upload/engine-one-tune-name-value.txt`。摄入脚本按 `name` 字段自动派生 `group`。

**[5] 轮换 `changeme`**：`curl -sk -u elastic:changeme -X POST https://localhost:9200/_security/user/_password -d '{"password":"<new>"}'`——然后重新生成 Bearer Token。连岸 WiFi 前务必做。

**[6] 自定义仪表盘**：编辑 `scripts_zh/03_hmi_a2a.sh` 中 `build_dashboard()` 函数里的 JSON 块，然后 `curl -X POST .../_kbn/api/saved_objects/dashboard` 带 Bearer Token。Kibana → 堆栈管理 → 已保存对象 导入。

</details>

---

## 10. 许可证

MIT。见 `LICENSE`。839 测点样本 `upload/engine-one-tune-name-value.txt` 按原样提供，仅供评估。

---

> SEPDS · Elastic Stack 9.x · llama.cpp · nex-n2-mini · 单机 · Bearer Token 认证 · MIT
