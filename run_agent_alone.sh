set -xe
# ================== 变量 ==================
D=/mnt/d/tmp/exp/3/2/elastic
VER=9.5.4
PW=$(grep '^ES_PASSWORD=' $D/.credentials | cut -d= -f2-)
ES_URL=https://localhost:9200
AUTH="elastic:$PW"; CT='Content-Type: application/json'
CA=$D/elasticsearch-9.5.4/config/ship-ca.pem     # 若 ES 无 TLS 则改 http://localhost:9200 且删 ssl 段
AGENT_DIR=$HOME/ship-agents/elastic-agent-tarball
AGENT_YML=$D/standalone-agent.yml
ING=$D/data/data_ingest
mkdir -p $HOME/ship-agents $ING $D/packages

# ================== 1) 清残留 ==================
sudo systemctl stop elastic-agent 2>/dev/null || true
sudo rm -f /etc/systemd/system/elastic-agent.service
sudo systemctl daemon-reload
sudo rm -rf $HOME/ship-agents/Elastic/Agent

# ================== 2) 下载解包 ==================
TARBALL=$D/packages/elastic-agent-$VER-linux-x86_64.tar.gz
[[ -s $TARBALL ]] || curl -fSL --retry 3 -o $TARBALL \
  https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-$VER-linux-x86_64.tar.gz
rm -rf $AGENT_DIR
tar -xzf $TARBALL -C $HOME/ship-agents
mv $HOME/ship-agents/elastic-agent-$VER-linux-x86_64 $AGENT_DIR

# ================== 3) 生成 standalone 配置（filestream 双流）==================
cat > $AGENT_YML <<'EOF'
outputs:
  default:
    type: elasticsearch
    hosts: ["https://localhost:9200"]
    username: elastic
    password: "<PW_PLACEHOLDER>"
    ssl.certificate_authorities: ["/mnt/d/tmp/exp/3/2/elastic/elasticsearch-9.5.4/config/ship-ca.pem"]
    ssl.verification_mode: full        # 若 CA 是自签且没配 hostname 可改 "none"

inputs:
  - id: engine-filestream
    type: filestream
    use_output: default
    data_stream.namespace: default
    streams:
      - data_stream:
          type: logs
          dataset: ship.engine
        paths:
          - /mnt/d/tmp/exp/3/2/elastic/data/data_ingest/engine_*.txt
          - /mnt/d/tmp/exp/3/2/elastic/data/data_ingest/engine_*.jsonl
        parsers:
          - ndjson:
              overwrite_keys: true
              add_error_key: true

  - id: imu-filestream
    type: filestream
    use_output: default
    data_stream.namespace: default
    streams:
      - data_stream:
          type: logs
          dataset: ship.imu
        paths:
          - /mnt/d/tmp/exp/3/2/elastic/data/data_ingest/imu_*.txt
          - /mnt/d/tmp/exp/3/2/elastic/data/data_ingest/imu_*.log

logging.level: info
logging.to_files: true
logging.files:
  path: $HOME/ship-agents
  name: elastic-agent
  keepfiles: 2
  permissions: 0640
EOF
# 替换密码
sed -i "s|<PW_PLACEHOLDER>|$PW|g" $AGENT_YML

# ================== 4) 独立模式安装（--from 指向解包目录，跳过 enroll）==================
sudo $AGENT_DIR/elastic-agent install \
  --install-servers \
  --unprivileged --user onetech --group onetech --base-path $HOME/ship-agents \
  --non-interactive --force

# ================== 5) 挂上自定义配置并重启 ==================
sudo $HOME/ship-agents/Elastic/Agent/elastic-agent install --help >/dev/null 2>&1 || true
sudo cp $AGENT_YML $HOME/ship-agents/Elastic/Agent/elastic-agent.yml
sudo chown onetech:onetech $HOME/ship-agents/Elastic/Agent/elastic-agent.yml
sudo systemctl restart elastic-agent
sleep 10
sudo systemctl status elastic-agent --no-pager | head -15
sudo elastic-agent status

# ================== 6) 造测试数据 ==================
for i in $(seq 1 15); do
  echo "{\"name\":\"engine/no1_rpm\",\"value\":$((1000+i)),\"timestamp\":$(date +%s)}" >> $ING/engine_test.txt
done
for i in $(seq 1 20); do
  echo "\$GTIMU,2397,144353.9600,-0.0170,-0.0363,0.0125,0.0221,0.0136,1.0026,30.9*56" >> $ING/imu_test.txt
done
sleep 45

# ================== 7) 验证数据落库 ==================
curl -sk -u $AUTH "$ES_URL/logs-ship.engine-default/_count" | jq .count
curl -sk -u $AUTH "$ES_URL/logs-ship.imu-default/_count"    | jq .count
curl -sk -u $AUTH "$ES_URL/_data_stream/logs-ship.*" \
  | jq -c '.data_streams[]|{name, template, backing:.indices|length}'

# ================== 8) 建 ILM 策略（30 天热 + 30GB 滚动，7 天后删）==================
curl -sk -u $AUTH -H "$CT" -X PUT "$ES_URL/_ilm/policy/ship-logs-policy" -d @- <<EOF
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": { "max_primary_shard_size": "1mb", "max_age": "1h" },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "1d",
        "actions": {
          "set_priority": { "priority": 50 },
          "forcemerge": { "max_num_segments": 1 },
          "shrink": { "number_of_shards": 1 }
        }
      },
      "delete": {
        "min_age": "7d",
        "actions": { "delete": {} }
      }
    }
  }
}
EOF

# ================== 9) 建索引模板并绑定 ILM ==================
for DS in logs-ship.engine-default logs-ship.imu-default; do
  curl -sk -u $AUTH -H "$CT" -X PUT "$ES_URL/_index_template/$DS-template" -d @- <<EOF
{
  "index_patterns": ["$DS"],
  "data_stream": {},
  "priority": 200,
  "template": {
    "settings": {
      "index.lifecycle.name": "ship-logs-policy",
      "index.number_of_shards": 1,
      "index.number_of_replicas": 0
    },
    "mappings": {
      "properties": {
        "@timestamp":     { "type": "date" },
        "engine.value":   { "type": "float" },
        "engine.name":    { "type": "keyword" },
        "message":        { "type": "text" }
      }
    }
  }
}
EOF
done

# ================== 10) 把 ILM 应用到已存在的数据流 ==================
# (若数据流已存在，需 rollover 到新 backing index 才吃到新模板；直接 PUT settings 也可)
for DS in logs-ship.engine-default logs-ship.imu-default; do
  curl -sk -u $AUTH -H "$CT" -X PUT "$ES_URL/$DS/_settings" \
    -d '{"index":{"lifecycle":{"name":"ship-logs-policy"}}}' | jq .
done

# ================== 11) 验证 ILM 生效 ==================
curl -sk -u $AUTH "$ES_URL/logs-ship.engine-default/_ilm/explain" \
  | jq '.indices|to_entries[]|{index:.key, managed:.value.managed, phase:.value.phase, age:.value.age}'
curl -sk -u $AUTH "$ES_URL/_data_stream/logs-ship.*" \
  | jq -c '.data_streams[]|{name, ilm_policy:.ilm_policy, template:.template}'

