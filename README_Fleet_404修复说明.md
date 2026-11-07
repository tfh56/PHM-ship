# Fleet package_policy 404 诊断与修复说明

## 一、错误现象

```bash
POST https://localhost:5601/api/fleet/package_policies
{
  "name": "ship-engine-filestream",
  "package": {"name": "log", "version": "2.4.0"},
  "inputs": [{
    "type": "logfile",
    "streams": [{
      "data_stream": {"dataset": "ship.engine", "type": "logs"}
    }]
  }]
}

# 响应
{"statusCode":404,"error":"Not Found",
 "message":"Stream template not found, unable to find dataset ship.engine"}
```

## 二、根因分析

### 直接原因

Fleet 的 `log` 集成包（v2.4.0）在创建 `package_policy` 时，会校验 `data_stream.dataset` 是否匹配包内预置的 **stream template**。`log` 包内置的 stream template 只接受 `log.*` 格式的 dataset（如 `log.auth`、`log.system` 等），自定义的 `ship.engine` 不在列表中，因此返回 404。

### 深层原因

脚本第 205 行已通过 ES API 创建了 `logs-ship.engine-*` 的 **索引模板**（index template），但索引模板与 Fleet 的 **stream template** 是两个不同层级：

| 层级 | 作用 | 创建方式 |
|------|------|---------|
| ES 索引模板 | 匹配索引名模式，定义 mapping/settings | `PUT _index_template` |
| Fleet stream template | 校验 package_policy 的 dataset 合法性 | 集成包内置，不可自定义 |

脚本只建了索引模板，没有 stream template，导致 Fleet API 层面就拒绝了。

## 三、修复方案

### 方案 A（已采用）：dataset 改为 `log.<k>` + 索引别名重定向

**核心思路**：让 Fleet API 通过校验（用 `log.engine`），数据实际落入 `logs-log.engine-default` 索引，再通过 ES 别名重定向到 `logs-ship.engine-default`。

**修改点（install.sh 第6阶段 `stage_fleet_policy`）**：

1. **确保 log 集成包已安装**（新增）
```bash
LOG_PKG_VER=$(kb_curl "$KB_API/api/fleet/epm/packages/log" | jq -r '.item.version // empty')
if [[ -z "$LOG_PKG_VER" ]]; then
  kb_curl -X POST "$KB_API/api/fleet/epm/packages/log" -d '{"force":true}'
fi
```

2. **dataset 从 `ship.engine` 改为 `log.engine`**
```bash
DATASET="log.${K}"   # 原来是 "ship.${K}"
```

3. **索引别名重定向**（新增）
```bash
es_curl -X POST "$ES_URL/_aliases" -d '{
  "actions":[{"add":{
    "index":"logs-log.engine-default",
    "alias":"logs-ship.engine-default"
  }}]
}'
```

### 方案 B（备选）：跳过 Fleet，用 Agent 独立模式

脚本第 8 阶段（`stage_agent`）已用独立模式配置 filestream，直接写入 `elastic-agent.yml`，不依赖 Fleet package_policy。可跳过第 6 阶段：

```bash
bash install.sh --redo 8   # 直接重跑第8阶段
```

## 四、修复后的数据流

```
engine*.jsonl
    ↓ elastic-agent filestream (ndjson parser)
    ↓ data_stream.dataset = log.engine
    ↓
ES 索引: logs-log.engine-default
    ↓ 别名重定向
    ↓
别名: logs-ship.engine-default  ← 第5阶段建的索引模板仍生效
    ↓
Kibana Index Pattern / ML / 告警
```

## 五、验证方法

修复后重跑第 6 阶段：

```bash
bash install.sh --redo 6
```

预期输出：
```
[+] agent_policy: <uuid>
[+] log 集成包版本: 2.4.0
[+] package_policy engine ✓ (dataset=log.engine)
[+] package_policy imu ✓ (dataset=log.imu)
[+] 别名 logs-ship.engine-default → logs-log.engine-default ✓
[+] 策略就绪（dataset=log.engine/log.imu，别名重定向到 logs-ship.*）
```

验证数据流：
```bash
# 检查 package_policy 已创建
curl -sk -u elastic:changeme \
  https://localhost:5601/api/fleet/package_policies | jq '.items[].name'
# 应返回: ship-engine-filestream, ship-imu-filestream

# 检查别名
curl -sk -u elastic:changeme \
  https://localhost:9200/_alias/logs-ship.engine-default | jq .
# 应返回 logs-log.engine-default 的别名映射
```

## 六、文件清单

| 文件 | 说明 |
|------|------|
| `install_fixed.sh` | 修复后的完整部署脚本（替换原 install.sh） |
| `install_fixed_stage6.sh` | 仅第6阶段修复函数（供对照） |
| `README_Fleet_404修复说明.md` | 本说明文档 |
