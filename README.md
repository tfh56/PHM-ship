# PHM-Ship · 船舶发动机诊断预测平台

[![OpenI](https://openi.pcl.ac.cn/tfh56/PHM-ship.svg)](https://openi.pcl.ac.cn/tfh56/PHM-ship)
![License](https://img.shields.io/badge/license-TBD-blue) <!-- ASSET: license badge，确定 License 后换链接 -->

> 面向船舶发动机健康管理（PHM）的单机一键部署包：**Elasticsearch + Kibana + Elastic Agent**
> 从裸机到"数据落库 → 管线清洗 → 异常检测 → 告警"全链路自动化，支持断点续跑与人工逐条验收两种模式。

<!-- ASSET: 系统架构图（数据流：engine_*.txt / imu_*.txt → Agent → pipeline → data stream → ML/看板），建议 1600×900 PNG，放 docs/assets/architecture.png -->
![系统架构](docs/assets/architecture.png)

---

## ✨ 特性

- 🚀 **一键部署**：`install.sh` 十阶段状态机，失败后重跑自动跳过已完成阶段（`--redo N` 强制重跑）
- 🎓 **教学模式**：`install-and-study.sh` 逐条命令人工确认执行，适合课堂演示与验收
- 🔐 **全程 TLS**：自签 CA + 节点证书，HTTP/Transport/Fleet 三层加密，凭据落盘 `600` 权限
- 📥 **双格式摄入**：发动机 JSONL 模拟量 + NMEA（`$GTIMU` / `$GPFPD`）惯导数据，GPS 周+秒内自动转 UTC **[CITE-1]**
- 🔀 **路由管线**：`ship-router` 按报文类型分流 `engine-telemetry` / `imu-nmea`，含回放自检
- 🧠 **ML 异常检测**：按通道 mean 检测器 + Watcher 阈值告警，开箱即用
- ♻️ **可重入**：`.deploy_state` 记录进度，随时中断/续跑/指定重跑

## 📋 系统要求

| 项目 | 要求 |
|---|---|
| OS | Ubuntu 20.04+ / Debian / RHEL 系（WSL2 可用，Agent 目录须在 ext4 分区） |
| 内存 | ≥ 8G（不足请保持 `ES_HEAP=700m`） |
| 磁盘 | ≥ 20G（安装包约 2G + 数据） |
| 用户 | **禁止 root**（ES 拒绝以 root 运行） |
| 依赖 | curl、jq、git、tar、openssl、sudo、python3（脚本会尝试自动安装缺失项） |

## 🚀 快速开始
$./install.sh
