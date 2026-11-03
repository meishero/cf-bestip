# CloudflareSpeedTest 优选系统 · 完整流程与逻辑说明

> 适用版本：2026-11-03 晚（含前缀级学习+短期记忆 / 三级多样性筛选 / 快筛按机场分组采样 / 机场分布观测 / 全参数配置化 / 48 线程 / 1MB 快筛 / status.txt）
> 部署位置：路由器 `/data/cfst/`（OpenWrt / busybox 1.25.1）
> 文件清单：`run.sh`（总调度）· `run_v6.sh` · `run_v4.sh` · `githubpush.sh` · `config.txt` · `V6url.txt` · `V4url.txt` · `cfst`（XIU2 二进制）

---

## 0. 系统总览

```
cron（17 0,6-23 * * *，系统 crontab 写死，不在 config.txt）
   └→ run.sh 总调度
        ├→ 校验 config.txt（sh -n，坏则退出）
        ├→ 主锁（防叠跑）
        ├→ timeout -t V6_TIMEUP sh run_v6.sh   → RC_V6
        ├→ timeout -t V4_TIMEUP sh run_v4.sh   → RC_V4
        └→ sh githubpush.sh $RC_V6 $RC_V4
             ├→ GH_UPLOAD_ENABLE=0 → 整体跳过
             ├→ 上传 best_ip_v6.txt（RC=0 且文件非空才传）
             ├→ 上传 best_ip_v4.txt
             └→ 上传 status.txt（每轮覆盖，健康状态一览）
```

三个顶级开关（config.txt 最上面）：`GH_UPLOAD_ENABLE` / `V6_ENABLE` / `V4_ENABLE`。
组合示例：只测 v4 不上传 = `GH_UPLOAD_ENABLE=0 + V6_ENABLE=0 + V4_ENABLE=1`。

---

## 1. run_v6.sh 逐步逻辑（v4 同构，差异单独标注）

### 0. 配置加载与锁
- `sh -n config.txt` 语法校验，**失败 → 记日志退出(1)**。
- `V6_ENABLE≠1` → **静默退出(0)**。
- 锁文件 `v6/.run.lock`：PID 存活 + `/proc/PID/cmdline` 校验。**进程活着 → 本轮退出**；死锁自动接管。
- 配置项：`V6_ENABLE`；写死：路径 `/data/cfst`、目录 `v6/`、锁文件名。

### 0.5 下载源预检
- HEAD 探测 `FAST_URL` 和 `DL_URL`，**任一非 200 → 整体回退**官方 `speed.cloudflare.com/__down`（5MB/10MB，写死）。
- 配置项：`V6_FAST_URL`、`V6_DL_URL`；写死：回退 URL、探测超时 6s/12s。

### 1a. 段源拉取与逐行分流（V6url.txt）
每行按顺序判定，**命中即停**：
1. `#` 开头 / 空行 → 忽略
2. v6 CIDR（`hex:/数字`）→ 直入段池 `.seg.all`（不走网络）
3. 纯 IPv6（含 `:` 的 hex 串，排除纯冒号）→ 直入外部 IP 池 `.ips.all`
4. 其余当订阅 URL → `curl`（8s 连接 / 30s 上限）拉取后，拉来的内容再走 2/3 的正则分流；**失败/为空静默跳过**
- 写死：curl 超时、正则；配置项：无（源列表本身在 V6url.txt）。

### 1a-2. 段归一化（基准 /48）
| 段掩码 | 分支 |
|---|---|
| ≥ /48（/48 /52 /56 /64…） | 原样保留（tolower + sort -u 去重） |
| /44~/47 | 展开为对齐的 /48 行（最多 16 条），参与后续去重/学习匹配 |
| < /44（/40 /36 /32…） | **跳过**，计数进日志 |
- 写死：/48 基准、/44 下限、16 条展开上限。

### 1b. 自建池（上轮赢家直接复测）
- 取**最近一轮** `history/best_*.txt` 的上榜 IP（延迟 < `SELF_LAT`）→ 入自建池 `.p3`（裸 IP，直接进池）。
- 随机生成下 IP 不会跨轮重复，旧的"精确 IP 计数 ≥SELF_MIN"永远为 0，已废弃；改为"上轮赢家直接回测"保连续性。
- 配置项：`V6_SELF_LAT=250`（SELF_MIN 已转用于 1b-1 学习段阈值）。

### 1b-1. 前缀级段学习
- 遍历**所有** `history/best_*.txt`，每个 IP 归到 /48（v6）/ /24（v4）前缀并计数；
  累计上榜**轮次**（同一段一轮最多计 1 次，防单轮刷满污染）≥ `SELF_MIN` 的段 → 优质段，按轮次降序取 `LEARN_MAX`。
- 段可跨轮重复命中，是唯一稳定的学习单位；v6 用前 3 组 key 包含匹配（兼容 /52 /56 /64），v4 用 `x.y.z.0/24` 全字匹配。
- 配置项：`V6_SELF_MIN=2`、`V6_LEARN_MAX=8`。

### 1b-1s. 短期记忆（冷启动加速）
- 上轮 best 上榜 IP 的前缀（v6 /48、v4 /24）直接并入学习段，让上轮赢家下轮立刻复用，不等跨轮计数。
- 短期记忆排前（优先），长期学习段补足到 `LEARN_MAX`。

### 1b-2. 学习定向（v6 独有，v4 无）
- 自建池每个好 IP → 展开 32 位 hex → 取前 16 位 = **/64 前缀**，去重后最多 16 个。
- 每个前缀生成 `TGT_PER_IP` 个随机 IP（后 4 组随机），入池 `.p3.tgt`。
- 原理：/48 学习段展开是全段随机，好 IP 的优质邻域在特定 /64 里，定点生成命中率远高于全段随机。
- 分支：`TGT_PER_IP=0` 或自建池空 → 跳过。
- 配置项：`V6_TGT_PER_IP=25`；写死：/64 粒度、16 个上限。
- v4 为什么没有：/24 全段只有 254 个地址，`IPS_PER_SEG=200` 已近穷举，定向无意义。

### 1c. 段级学习
- 1b-1 的学习 key → 与段池按 key 包含匹配（`::` 压缩按 0 补）。
- 段池每条段算同样的 key，**key 匹配 → 该段强制入池**（`.seg.keep`，含 /52 /56 /64 落在学习 /48 内的）。
- **超过 `LEARN_MAX` 条 → 只取前 N 条**（防历史好段挤占探索名额）。
- 配置项：`V6_LEARN_MAX=8`。

### 1d. 随机抽段
- 名额 = `SEG_PICK - LEARNED`；**≤0 → 跳过本轮抽段**。
- 排除已学习段后，随机抽样（urandom→md5 前 8 位 hex→h2d 做 srand 种子；busybox srand 大数截断坑的规避方案）。
- 配置项：`V6_SEG_PICK=20`；写死：`head -c 8 /dev/urandom`、种子兜底值 `1a2b3c4d`。

### 1d-2. 段展开（脚本自生成随机 IP，替代 cfst 随机游走）
- 学习段+随机段（均已归一化为 /48 或更细）每条生成 `IPS_PER_SEG` 个段内随机 IPv6：
  **纯字符串运算**（IPv6 128 位超 awk 浮点精度，不能转数字）——地址展开 32 个 hex 字符 → 保留前 `掩码/4` 位 → 其余逐位随机；非 nibble 对齐掩码（如 /50）在过渡位保留高位+低位随机；段内去重。
- 分支：`IPS_PER_SEG=0` → **关闭展开，回退旧行为**（整段 CIDR 交给 cfst 随机游走）。
- 配置项：`V6_IPS_PER_SEG=200`。

### 1e. 外部 IP 抽样
- `.ips.all` 去重后随机抽 `IP_PICK` 条（同 urandom 种子方案）。
- 分支：`IP_PICK=0` 或无外部 IP → 跳过。
- 配置项：`V6_IP_PICK=100`。

### 池组装
- 展开生效：`pool.txt = 段展开 IP + 定向 IP + 自建池 + 外部 IP`（全裸 IP，cfst 逐条原样测）。
- 展开关闭/失败：回退 `学习段 + 随机段(CIDR) + 自建池 + 外部 IP`。
- **池为空 → 记日志退出(1)**（保留上次结果文件）。

### 2. HTTPing 延迟测速（循环）
- cfst 命令：`-httping -n $LAT_THREAD -t $LAT_TIMEOUT -dd -p 10 -url $LAT_URL -httping-code 204 -tl $SELF_LAT`
- 循环分支：
  | 情况 | 动作 |
  |---|---|
  | 成功且有候选 | break 进入快筛 |
  | 失败且轮数 ≥ `MAX_SCAN_ROUNDS` | **放弃本轮 exit 1** |
  | 失败，端点 429 | `wait_429_clear` 退避等待后重扫 |
  | 失败，端点无 429，累计 ≥3 轮 | **判致命问题 exit 1** |
- 退避策略（`wait_429_clear`）：间隔 120→240→480→600(封顶) 秒（`BACKOFF_ENABLE=1`，否则固定 120）；**累计等待 ≥ `429_WAIT_MAX` → 放弃本轮**。
- 配置项：`V6_LAT_THREAD=32`、`V6_LAT_TIMEOUT=1`、`V6_LAT_URL`、`V6_SELF_LAT=250`（-tl 门槛）、`V6_MAX_SCAN_ROUNDS=30`、`V6_BACKOFF_ENABLE=1`、`V6_429_WAIT_MAX=1200`；写死：`-httping-code 204`、`-dd`（禁下载测速）、`-p 10`。

### 3. 下载闸门 + 4a 快筛
- 闸门：HEAD 探测 `DL_URL`，429 则 `wait_429_clear`，超限 → **放弃本轮**。
- 快筛候选抽取（按机场分组采样）：从**全部**延迟候选里，每个机场（colo）取延迟最低的 `COLO_PICK` 个，
  强制每个机场都有代表进快筛（防单一机场延迟优势霸榜，实测曾出现 30 个快筛候选 100% 同机场）；
  不足 `DL_TOPN` 时按延迟顺位回填；`COLO_PICK=0` 退化为纯延迟顺位（"延迟最优优先"，牺牲机场多样性）。
- 快筛：入选候选逐个（串行）下载 `FAST_URL` 1 次，curl `--resolve` 强制 IP，`--max-time $DL_MAXTIME`。
- 每个 IP 撞 429：等 120/240/480 秒重试，超过 `DL_RETRY=3` 次 → **该样本记 0 分跳过**。
- 配置项：`V6_DL_TOPN=30`、`V6_COLO_PICK=3`、`V6_FAST_URL`、`V6_DL_MAXTIME=10`、`V6_DL_RETRY=3`、`V6_BACKOFF_ENABLE`。

### 4a-2. 多样性筛选（快筛 → 精测的入选名单）
- 从快筛速度榜选 `FAST_TOPN` 个进入精测，约束：**同一 /48 最多 `DIV_SEG_MAX` 条、同地区（机场码）最多 `DIV_COLO_MAX` 条**。
- 三级筛选：① 严格约束直选（同段≤`DIV_SEG_MAX`、同地区≤`DIV_COLO_MAX`）
  ② 不足时放宽一档回填（同段≤3、同地区≤5）  ③ 仍不足按速度顺位无条件回填（保证数量）。
  注意 awk 必须 `-F"|"`：FASTTMP 是竖线分隔无空格，缺了它 $3/$4 全空、筛选退化成纯速度序
  （上线首日实际发生并已修复的 bug）。
- 配置项：`V6_FAST_TOPN=10`、`V6_DIV_SEG_MAX=2`、`V6_DIV_COLO_MAX=3`。

### 4b. 精测
- 入选名单逐个下载 `DL_URL`（9.1MB）2 次取平均；429 处理同快筛。
- 配置项：`V6_DL_URL`、`V6_DL_MAXTIME`、`V6_DL_RETRY`。

### 5. 排序输出 + 归档
- 精测速度降序取前 `TOPN` → `v6/best_ip_v6.txt`；首行 `# updated: 时间戳`，行格式 `[ip]:443#ip-443-延迟ms-速度MB/s-地区`。
- 归档 `history/best_时间戳.txt`，**超过 `KEEP` 份删最旧**。
- 日志记完成行（最优 IP/延迟/速度/候选数/上榜数；速度 ≥8MB/s 附加"达标"标注——8 这个标准写死）。
- 配置项：`V6_TOPN=10`、`V6_KEEP=48`；写死：8MB/s 达标线、日志瘦身 500 行。

---

## 2. run_v4.sh 与 v6 的全部差异

| 项 | v6 | v4 |
|---|---|---|
| 归一化基准 | /48（粗于 /44 跳过） | /24（粗于 /20 跳过；/20~/23 展开，`int(第三段/q)*q` 容错未对齐写法） |
| 段展开目标格式 | 随机 IPv6（字符串运算） | 随机 IPv4（数字运算，/24 避开 .0/.255） |
| 学习定向 1b-2 | 有（/64 邻域） | 无（/24 空间太小，展开已近穷举） |
| 学习 key | 前 3 组 hex（包含匹配） | `x.y.z.0/24` 全字匹配（grep -Fxf） |
| 多样性段键 | /48（前 3 组） | /24（前三段） |
| 结果行格式 | `[ip]:443#...`（带方括号） | `ip:443#...`（无方括号） |
| cfst 池形态 | 全裸 IP（/128 逐条） | 全裸 IP（/32 逐条） |
| SELF_LAT | 250 | 300（v4 直连延迟普遍 205~227ms，250 会零候选） |
| 历史解析字段 | FS=`[][#-]`，$6=延迟 | FS=`[-#]`，$4=延迟 |

其余流程、分支、退避、两阶段下载完全同构。

---

## 3. githubpush.sh 逻辑

1. config 校验；`GH_UPLOAD_ENABLE≠1` → **整体跳过**。
2. v6 分支：`RC=99`（开关关闭）→ 跳过；`RC=0` 且文件非空 → 上传；否则记"失败/无结果"。v4 同理。
3. `gh_put` 流程：
   - **去重**：除首行时间戳外的内容 md5 与 `.push_v6/v4.md5` 比对，一致 → 跳过提交（减 commit 噪音）；
   - GET 取现有文件 sha → PUT Contents API；
   - **双通道**：直连 api.github.com 失败（网络层）→ 自动改走 `http://127.0.0.1:GH_PROXY_PORT` 重试一次；
   - 成功后 purge `purge.jsdelivr.net`（响应含 `"status": "finished"` 判定成功）。
4. **status.txt**（每轮必传，不去重）：两栈最后一条关键日志（测速完成/放弃原因，含**机场分布**）+ 退出码 + 本轮上传结果 → 仓库 `status.txt`，打开 raw 链接即可知道系统健康状态和多样性是否生效。

---

## 4. 配置项总表（config.txt，v6/v4 同名同义，前缀区分）

| 分组 | 配置项 | v6 值 | v4 值 | 说明 |
|---|---|---|---|---|
| 开关 | GH_UPLOAD_ENABLE | 1 | — | 是否上传 GitHub |
| 开关 | V6/V4_ENABLE | 1 | 1 | 各栈测速总开关 |
| GitHub | GH_REPO / GH_TOKEN / GH_PROXY_PORT | — | — | 仓库 / token / 代理端口 |
| GitHub | GH_CONNECT_TIMEOUT / GH_MAXTIME / GH_PURGE_TIMEOUT | 6 / 25 / 15 | 同 | API 连接/请求/purge 超时(秒) |
| 通用 | SRC_CONNECT_TIMEOUT / SRC_FETCH_TIMEOUT | 8 / 30 | 同 | 段源连接/整体超时(秒) |
| 通用 | PRECHECK_TIMEOUT / PROBE_TIMEOUT / DL_CONNECT_TIMEOUT | 12 / 15 / 5 | 同 | 预检/429探测/下载连接超时(秒) |
| 通用 | LOG_KEEP_LINES | 500 | 同 | 日志瘦身保留行数 |
| 结果筛选 | TOPN | 10 | 10 | 最终上榜条数 |
| 结果筛选 | DL_TOPN | 30 | 30 | 延迟榜进快筛名额 |
| 结果筛选 | FAST_TOPN | 10 | 10 | 快筛进精测名额 |
| 结果筛选 | COLO_PICK | 3 | 3 | 快筛每机场（colo）最多入选数（0=关分组采样） |
| 结果筛选 | DIV_SEG_MAX | 2 | 2 | 同 /48(v6)//24(v4) 上榜上限 |
| 结果筛选 | DIV_COLO_MAX | 3 | 3 | 同地区上榜上限 |
| 池构建 | SEG_PICK | 20 | 20 | 每轮入池段总数 |
| 池构建 | LEARN_MAX | 8 | 8 | 学习段封顶 |
| 池构建 | IPS_PER_SEG | 200 | 200 | 每段展开随机 IP 数（0=关闭） |
| 池构建 | TGT_PER_IP | 25 | （无） | 好 IP /64 邻域定向数（v4 无此项） |
| 池构建 | TGT_MAX_PREFIX | 16 | （无） | 定向 /64 前缀数量上限（v4 无此项） |
| 池构建 | IP_PICK | 100 | 100 | 外部纯 IP 抽样配额 |
| 池构建 | SELF_MIN / SELF_LAT | 2 / 250 | 2 / 300 | 学习段阈值（前缀上榜轮次）/ 复测与学习延迟上限（LAT 是两栈唯一数值差异） |
| 稳定性 | KEEP | 48 | 48 | 历史归档份数 |
| 稳定性 | MAX_SCAN_ROUNDS | 30 | 30 | 延迟测速最大重扫轮数 |
| 稳定性 | BACKOFF_ENABLE | 1 | 1 | 429 指数退避开关 |
| 稳定性 | BACKOFF_BASE / BACKOFF_CAP | 120 / 600 | 同 | 退避基础间隔/封顶(秒) |
| 稳定性 | 429_WAIT_MAX | 1200 | 1200 | 429 累计等待上限(秒) |
| 稳定性 | TIMEUP | 2400 | 2400 | 单轮总超时(秒)，留 429 退避余量 |
| 测速参数 | LAT_THREAD | 48 | 48 | cfst 并发线程（提速 ~1/3，最高建议 64） |
| 测速参数 | LAT_TIMEOUT | 1 | 1 | 延迟测速单 IP 超时(秒) |
| 测速参数 | DL_MAXTIME | 10 | 10 | 单次下载限时(秒) |
| 测速参数 | DL_RETRY | 3 | 3 | 下载 429 重试上限 |
| 测速参数 | SPEED_PASS | 8 | 8 | 达标速度阈值 MB/s（仅日志标注） |
| 测速目标 | LAT_URL | cp.cloudflare.com/generate_204 | 同 | 勿用 www.cloudflare.com（WAF） |
| 测速目标 | FAST_URL | cdnjs echarts 1MB | 同 | 快筛源（只做粗排，1MB 省 2/3 流量） |
| 测速目标 | DL_URL | testingcf.jsdelivr typescript 9.1MB | 同 | 勿用 cdn.jsdelivr.net 主域（已迁 Fastly） |

---

## 5. 写死的数据清单（改代码才能改）

| 类别 | 内容 |
|---|---|
| 路径 | `/data/cfst`、`v6/`、`v4/`、`history/`、锁文件 `.run.lock`、`.push_*.md5`、`.gh_resp`、`.status.txt` |
| cron | `17 0,6-23 * * *`（系统 crontab，不在 config） |
| cfst 固定参数 | `-httping -dd -p 10 -httping-code 204`；延迟门槛走 `-tl $SELF_LAT`（可配） |
| 归一化基准 | v6=/48、下限 /44；v4=/24、下限 /20（算法常数，改需同步脚本） |
| 定向学习 | /64 粒度（/64 前缀上限 TGT_MAX_PREFIX 可配） |
| 随机种子 | `head -c 8 /dev/urandom \| md5sum \| cut -c1-8`，兜底值 `1a2b3c4d` / `9f8e7d6c` / `4d3c2b1a` |
| 回退下载源 | `speed.cloudflare.com/__down`（5MB/10MB，预检失败时官方兜底） |
| 展开细节 | v6 保留前 `掩码/4` 位 hex；v4 /24 避开 .0/.255、粗段全段随机 |
| 测量次数 | 快筛每候选 1 次、精测每候选 2 次取平均（方法论，改需同步脚本循环） |
| busybox 适配 | `timeout -t`（GNU 语法会 127 假跑！）、sort 无 -o/-k1,1n、无 od/cksum、scp 不可用（cat 管道）、srand 大数截断 |
| cfst 机制 | 一条 v4 段只产 1 个随机 IP；v6 游走每条 /48 ≈ 数百个且偏向段头（现已被脚本展开替代） |

---

## 6. 数据流向图

```
V6url.txt ──分流──> .seg.all(段) / .ips.all(纯IP)
                        │ 1a-2 归一化(/48)
                        ▼
history/ ──上轮best──> .p3 自建池(复测+定向)
       └─前缀计数≥SELF_MIN─> .seg.learn(学习段) ─┐
                  │ 1b-2        │ 1c key匹配           │1d 随机抽段
                  ▼             ▼                      ▼
              .p3.tgt      (key命中段)            .seg.pick
                  └───────┬──────┴──────────┬──────────┘
                          ▼   1d-2 段展开     ▼
                    pool.txt = 展开IP + 定向IP + 自建池 + 外部IP抽的IP
                          ▼
              cfst HTTPing(-tl SELF_LAT) → .lat.csv
                          ▼
              快筛(前DL_TOPN, 1MB) → 三级多样性筛选 → 精测(前FAST_TOPN, 9.1MB x2)
                          ▼
              best_ip_v6.txt (TopN) + history/ 归档
                          ▼ (run.sh 统一调度)
              githubpush.sh → best_ip_v6/v4.txt + status.txt → GitHub/jsDelivr
```
