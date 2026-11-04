#!/bin/sh
# ============================================================
# CloudflareSpeedTest IPv4 定时测速 + 优选脚本（2026-11-03）
# 独立子脚本：由总调度 run.sh 调用，也可单独手动执行（不传 GitHub）
#
# 【池子构成】自建学习池 + baipiao.eu.org 细分 /24 段（每轮 20 条，共 6534 条）
#   段源（V4url.txt）支持订阅 URL 与本地直写 CIDR 段/纯 IP 混写（每行一个，# 为注释）
#   注意：cfst 对 IPv4 每条段只产出 1 个随机 IP，故入池段会先被脚本展开为
#   V4_IPS_PER_SEG 个段内随机 IP（真实随机种子、段内去重），补足候选量
#   - 前缀级自学习（滑动窗口）：最近 LEARN_WINDOW 份历史 best 的 IP 按 /24 前缀计数，
#     反复产出好 IP 的优质段强制入池（利用），过时段自动滑出紧跟 CF 变化；其余名额随机抽（探索），
#     且避开最近已探索段扩大覆盖；最近一轮上榜 IP 直接复测（连续性保障）
#   - HTTPing 目标 = cp.cloudflare.com/generate_204（captive portal 检测域，无 bot 防护基本不限流；www.cloudflare.com 有 WAF 会拦 Go 客户端，勿用）
#   - 下载目标 = 公共 CDN 大文件（testingcf.jsdelivr.net 9.1MB + cdnjs.cloudflare.com 3.6MB，
#     均为 CF 边缘接入、可 --resolve 强制 IP、无测速限流）；启动时 HEAD 预检，
#     任一不可用自动回退官方 speed.cloudflare.com/__down
#
# 【流程】
# 1. 构建池 pool.txt = 自建池（最近一轮 best 的上榜 IP，延迟<SELF_LAT，直接复测保连续性）
#    + 学习段（最近 LEARN_WINDOW 份历史 best 的 /24 前缀产出好 IP >=SELF_MIN 次的优质段，最多 LEARN_MAX）
#    + 随机段（从 6534 条中随机抽补足，避开最近已探索段扩大覆盖，每条段再展开 200 个段内随机 IP）
# 1a-2 段归一化（与 v6 同构，基准 /24）：细于 /24 原样保留；/20~/23 展开为
#    对应 /24 行（最多 16 条）参与去重与学习匹配；粗于 /20（/16 /13 等）
#    展开量过大（256~65536 条）跳过并记日志
# 2. HTTPing 延迟测速（-tl $SELF_LAT）：失败则等 429 解除后重扫；循环直到成功（上限 30 轮防死转）
# 3. 下载闸门：探测下载 URL，429 等到解除才开测
# 4. 下载实测两阶段：
#    4a 快筛：候选（最多 30 个）每个下载 1 次 x 1MB（echarts.min.js），按速度粗排
#    4b 精测：多样性筛选后前 10 名每个下载 DL_RUNS 次 x 9.1MB 取平均
#    任何一次撞 429 等 120 秒重试，单次样本重试上限 3 次，超限记 0 跳过
# 5. 排序：下载速度降序，取前 10 → 结果文件（文件名由 config.txt 的 V4_RESULT_FILE 决定，可配）
#    行格式：ip:443#ip-443-延迟ms-速度MB/s-地区（IPv4 不带方括号）
#    例：104.16.10.126:443#104.16.10.126-443-212ms-5.45MB/s-LAX
#    history/（结果归档，反哺自建学习池 + 段级学习）
#
# 【配置】全部参数已迁移至 /data/cfst/config.txt 统一维护
#   （v6/v4 独立配置段 + 三个总开关：GH_UPLOAD_ENABLE / V6_ENABLE / V4_ENABLE）
# 【参数速查】（数量类配额已与 v6 版对齐，统一见 config.txt）
#   每轮 20 段（每段展开 200 个随机 IP ≈ 4000 个段候选）/ 延迟候选取前 30 /
#   快筛 1MB x 1 次 / 精测 9.1MB x DL_RUNS 次
#   每轮下载流量上限 ≈ 30x1MB + 10x18.2MB ≈ 210MB（正常远低于此）
#   429 重试上限 3 次/样本；下载锁 = PID 存活检测（防叠跑）
# ============================================================
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

DIR=/data/cfst
V4DIR="$DIR/v4"
mkdir -p "$V4DIR"
cd "$DIR" || exit 1

# ---- 配置加载：所有参数统一在 /data/cfst/config.txt 维护 ----
CFG="$DIR/config.txt"
if [ ! -f "$CFG" ] || ! sh -n "$CFG" 2>/dev/null; then
    echo "[$(date '+%m-%d %H:%M:%S')]v4 退出：config.txt 缺失或语法错误，拒绝加载" >> "$V4DIR/run.log" 2>/dev/null
    exit 1
fi
. "$CFG"
# 总开关双保险：IPv4 未启用时静默退出
[ "$V4_ENABLE" = "1" ] || exit 0

# 将 config.txt 的 v4 配置映射到脚本内部变量
KEEP="$V4_KEEP"; TOPN="$V4_TOPN"; DL_TOPN="$V4_DL_TOPN"; FAST_TOPN="$V4_FAST_TOPN"
RESULT_FILE="$V4_RESULT_FILE"; [ -z "$RESULT_FILE" ] && RESULT_FILE="best_ip_v4.txt"
SEG_PICK="$V4_SEG_PICK"; LEARN_MAX="$V4_LEARN_MAX"; SELF_MIN="$V4_SELF_MIN"; SELF_LAT="$V4_SELF_LAT"
LEARN_WINDOW="$V4_LEARN_WINDOW"; [ -z "$LEARN_WINDOW" ] && LEARN_WINDOW=24
AVOID_KEEP="$V4_AVOID_KEEP"; [ -z "$AVOID_KEEP" ] && AVOID_KEEP=48
MAX_SCAN_ROUNDS="$V4_MAX_SCAN_ROUNDS"; LAT_URL="$V4_LAT_URL"; FAST_URL="$V4_FAST_URL"
DL_URL="$V4_DL_URL"; DL_MAXTIME="$V4_DL_MAXTIME"; DL_RETRY="$V4_DL_RETRY"; IP_PICK="$V4_IP_PICK"
DL_RUNS="$V4_DL_RUNS"; [ -z "$DL_RUNS" ] && DL_RUNS=2
WAIT_MAX="$V4_429_WAIT_MAX"; BACKOFF_ENABLE="$V4_BACKOFF_ENABLE"
BACKOFF_BASE="$V4_BACKOFF_BASE"; [ -z "$BACKOFF_BASE" ] && BACKOFF_BASE=120
BACKOFF_CAP="$V4_BACKOFF_CAP"; [ -z "$BACKOFF_CAP" ] && BACKOFF_CAP=600
IPS_PER_SEG="$V4_IPS_PER_SEG"; [ -z "$IPS_PER_SEG" ] && IPS_PER_SEG=5
LOCAL_IPS_PER_SEG="$V4_LOCAL_IPS_PER_SEG"; [ -z "$LOCAL_IPS_PER_SEG" ] && LOCAL_IPS_PER_SEG=20
LAT_TIMEOUT="$V4_LAT_TIMEOUT"; [ -z "$LAT_TIMEOUT" ] && LAT_TIMEOUT=1
LAT_THREAD="$V4_LAT_THREAD"; [ -z "$LAT_THREAD" ] && LAT_THREAD=32
DIV_SEG_MAX="$V4_DIV_SEG_MAX"; [ -z "$DIV_SEG_MAX" ] && DIV_SEG_MAX=2
DIV_COLO_MAX="$V4_DIV_COLO_MAX"; [ -z "$DIV_COLO_MAX" ] && DIV_COLO_MAX=3
COLO_PICK="$V4_COLO_PICK"; [ -z "$COLO_PICK" ] && COLO_PICK=3
# 学习复测每学习段最多复测的精确 IP 数（v4 复用 v6 定向值；config 无 V4_TGT_PER_IP 时默认 25）
TGT_PER_IP="${V4_TGT_PER_IP:-25}"; [ -z "$TGT_PER_IP" ] && TGT_PER_IP=25
SPEED_PASS="$V4_SPEED_PASS"; [ -z "$SPEED_PASS" ] && SPEED_PASS=8
SRC_CONNECT_TIMEOUT="${SRC_CONNECT_TIMEOUT:-8}"
SRC_FETCH_TIMEOUT="${SRC_FETCH_TIMEOUT:-30}"
SRC_RETRY="${SRC_RETRY:-2}"
PRECHECK_TIMEOUT="${PRECHECK_TIMEOUT:-12}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-15}"
DL_CONNECT_TIMEOUT="${DL_CONNECT_TIMEOUT:-5}"
LOG_KEEP_LINES="${LOG_KEEP_LINES:-500}"

LOG="$V4DIR/run.log"
START_TS=$(date +%s)

# ---- 0. 锁文件：PID 存活检测（进程活着本轮退出；死锁自动接管） ----
LOCK="$V4DIR/.run.lock"
if [ -f "$LOCK" ]; then
    OLD_PID=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null \
       && grep -q "cfst/run_v4.sh" "/proc/$OLD_PID/cmdline" 2>/dev/null; then
        exit 0   # 上一轮确实还在跑，本轮让位
    fi
    echo "[$(date '+%m-%d %H:%M:%S')] 锁残留（PID ${OLD_PID:-空} 已不存在或非本脚本），接管" >> "$LOG"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

# ---- 0.5 下载源预检：社区公共 CDN 任一不可用则整体回退官方 __down ----
FB_FAST="https://speed.cloudflare.com/__down?bytes=5242880"
FB_DL="https://speed.cloudflare.com/__down?bytes=10485760"
CODE_F=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout "$SRC_CONNECT_TIMEOUT" --max-time "$PRECHECK_TIMEOUT" -I "$FAST_URL" 2>/dev/null)
CODE_D=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout "$SRC_CONNECT_TIMEOUT" --max-time "$PRECHECK_TIMEOUT" -I "$DL_URL" 2>/dev/null)
if [ "$CODE_F" != "200" ] || [ "$CODE_D" != "200" ]; then
    echo "[$(date '+%m-%d %H:%M:%S')] 社区下载源预检失败（快筛 $CODE_F / 精测 $CODE_D），回退 speed.cloudflare.com/__down" >> "$LOG"
    FAST_URL="$FB_FAST"
    DL_URL="$FB_DL"
fi

# 429 探测：参数1 = URL；参数2 = 1 表示用 HEAD 探测（下载源专用，几乎零流量）
# 退避：BACKOFF_ENABLE=1 时重探间隔 120→240→480→600(封顶)秒，否则固定 120 秒
# 上限：累计等待 WAIT_MAX 秒仍未解除则返回 1（调用方放弃本轮）；解除返回 0
wait_429_clear() {
    WSTART=$(date +%s); WT=0
    while :; do
        if [ "$2" = "1" ]; then
            CODE=$(curl -k -I -o /dev/null -s -w "%{http_code}" --connect-timeout "$SRC_CONNECT_TIMEOUT" --max-time "$PROBE_TIMEOUT" "$1" 2>/dev/null)
        else
            CODE=$(curl -k -o /dev/null -s -w "%{http_code}" --connect-timeout "$SRC_CONNECT_TIMEOUT" --max-time "$PROBE_TIMEOUT" "$1" 2>/dev/null)
        fi
        [ "$CODE" != "429" ] && return 0
        WELAPSED=$(( $(date +%s) - WSTART ))
        if [ "$WELAPSED" -ge "$WAIT_MAX" ]; then
            echo "[$(date '+%m-%d %H:%M:%S')]  429 累计等待 ${WELAPSED}s 超过上限 ${WAIT_MAX}s，放弃本轮" >> "$LOG"
            return 1
        fi
        WT=$((WT + 1))
        if [ "$BACKOFF_ENABLE" = "1" ]; then
            case $WT in 1) SLP=$BACKOFF_BASE;; 2) SLP=$((BACKOFF_BASE*2));; 3) SLP=$((BACKOFF_BASE*4));; *) SLP=$BACKOFF_CAP;; esac
        else
            SLP=$BACKOFF_BASE
        fi
        echo "[$(date '+%m-%d %H:%M:%S')]  目标 $1 被 429 限流，等待 ${SLP}s 后重探（累计 ${WELAPSED}s/${WAIT_MAX}s）" >> "$LOG"
        sleep "$SLP"
    done
}

# 单次下载（带 429 重试，上限 DL_RETRY 次）：参数1=URL 参数2=IP
# host 从 URL 自动解析（快筛/精测可用不同 CDN 域名）
# 成功输出 speed_download，超限输出空值
dl_once() {
    DH=$(echo "$1" | sed -E 's|^https?://([^/]+)/.*|\1|')
    # IPv6 目标地址需方括号，IPv4 不需要
    if echo "$2" | grep -q ':'; then TGT="[$2]"; else TGT="$2"; fi
    TRY=0
    while :; do
        RESP=$(curl -k -o /dev/null -s -w "%{http_code} %{speed_download}" --connect-timeout "$DL_CONNECT_TIMEOUT" --max-time $DL_MAXTIME \
               --resolve "$DH:443:$TGT" "$1" 2>/dev/null)
        CODE=${RESP%% *}
        if [ "$CODE" != "429" ]; then
            echo "${RESP##* }"
            return 0
        fi
        TRY=$((TRY + 1))
        if [ "$TRY" -gt "$DL_RETRY" ]; then
            echo "[$(date '+%m-%d %H:%M:%S')]   下载 $2 连续 429 超过 $DL_RETRY 次重试，放弃该次样本" >> "$LOG"
            echo ""
            return 1
        fi
        if [ "$BACKOFF_ENABLE" = "1" ]; then
            case $TRY in 1) SLP=$BACKOFF_BASE;; 2) SLP=$((BACKOFF_BASE*2));; *) SLP=$((BACKOFF_BASE*4));; esac
        else
            SLP=$BACKOFF_BASE
        fi
        echo "[$(date '+%m-%d %H:%M:%S')]   下载 $2 撞 429 限流，等待 ${SLP}s 后重试（$TRY/$DL_RETRY）" >> "$LOG"
        sleep "$SLP"
    done
}

echo "[$(date '+%m-%d %H:%M:%S')]===== 开始 IPv4 测速（/24 段级学习/两阶段下载/Top10） =====" >> "$LOG"

# ---- 1. 构建测速池 pool.txt = 自建池 + 学习段 + 随机段 ----
SEGCNT=0; PICKED=0; LEARNED=0; SCNT=0; LOCALCNT=0
# 1a. 段源处理：按 $DIR/V4url.txt 逐行处理（# 与空行忽略），支持两类行：
#     - 本地直写：CIDR 段（如 172.64.229.0/24）直接进段池；纯 IPv4 行直接进外部 IP 池
#     - 订阅地址（http/https）：curl 拉取后逐行自动分流：CIDR 段 → 段池；纯 IPv4 行 → 外部 IP 池
#     某个源失败/为空自动跳过；全部失败时仅剩自建池兜底
: > "$V4DIR/.seg.all"; : > "$V4DIR/.seg.local"; : > "$V4DIR/.ips.all"; rm -f "$V4DIR/.fetch.ok"
if [ -f "$DIR/V4url.txt" ]; then
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$DIR/V4url.txt" | while read SU; do
        [ -n "$SU" ] || continue
        # 本地直写行：CIDR 段 / 纯 IP 直接入池（不走网络，不受源拉取失败影响）
        if echo "$SU" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            echo "$SU" >> "$V4DIR/.seg.local"
            continue
        fi
        if echo "$SU" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            echo "$SU" >> "$V4DIR/.ips.all"
            continue
        fi
        # 订阅地址：拉取（失败重试 SRC_RETRY 次，仍失败记日志跳过）
        r=0
        while [ "$r" -le "$SRC_RETRY" ]; do
            curl -s -k --connect-timeout "$SRC_CONNECT_TIMEOUT" --max-time "$SRC_FETCH_TIMEOUT" "$SU" > "$V4DIR/.fetch.raw" 2>/dev/null
            [ -s "$V4DIR/.fetch.raw" ] && break
            r=$((r + 1))
            [ "$r" -le "$SRC_RETRY" ] && sleep 2
        done
        if [ ! -s "$V4DIR/.fetch.raw" ]; then
            echo "[$(date '+%m-%d %H:%M:%S')]  订阅源拉取失败（重试 $SRC_RETRY 次后仍空）：$SU" >> "$LOG"
            continue
        fi
        touch "$V4DIR/.fetch.ok"
        # 段通道：CIDR 行
        grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]+$' "$V4DIR/.fetch.raw" >> "$V4DIR/.seg.all" 2>/dev/null
        # IP 通道：纯 IPv4 行
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$V4DIR/.fetch.raw" >> "$V4DIR/.ips.all" 2>/dev/null
    done
    rm -f "$V4DIR/.fetch.raw"
fi
# 1a-2. 段归一化：以 /24 为基准（与 v6 的 /48 归一化逻辑一致）
#   - 细于 /24（/25 /26 ... /32）：原样保留（覆盖 IP 少，cfst 段内随机取样自然变少）
#   - 粗于 /24 且 >= /20（/20 /21 /22 /23）：展开为对应的 /24 行（最多 16 条），与其他源自然去重
#   - 粗于 /20（/16 /13 /8 等）：展开量过大（256~65536 条），跳过并记日志
#   - 展开时按对齐网络地址计算（int(第三段/q)*q），容错源里未对齐的写法；sort -u 去重
if [ -s "$V4DIR/.seg.all" ]; then
    awk -F'/' '
    {
        plen = $2 + 0; addr = $1
        if (plen >= 24) { print addr "/" plen; next }
        if (plen < 20) { next }
        split(addr, o, ".")
        q = 2 ^ (24 - plen)
        s3 = int(o[3] / q) * q
        for (k = 0; k < q; k++) printf "%s.%s.%d.0/24\n", o[1], o[2], s3 + k
    }' "$V4DIR/.seg.all" 2>/dev/null > "$V4DIR/.seg.norm"
    # 统计被跳过的粗段数量（进日志）
    SKIPN=$(awk -F'/' '$2+0<20' "$V4DIR/.seg.all" 2>/dev/null | grep -c .)
    [ -z "$SKIPN" ] && SKIPN=0
    mv "$V4DIR/.seg.norm" "$V4DIR/.seg.all" 2>/dev/null
    sort -u "$V4DIR/.seg.all" > "$V4DIR/.seg.all.u" && mv "$V4DIR/.seg.all.u" "$V4DIR/.seg.all"
    [ "$SKIPN" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  归一化：$SKIPN 条粗于 /20 的段（如 /16 /13）展开量过大已跳过" >> "$LOG"
fi
# 1a-2b. 本地优选段归一化（手写 CIDR 段 = 人工优选段，与订阅段同规则归一化）
#        归一化后单独展开、确定性进池（不参与随机抽段）
if [ -s "$V4DIR/.seg.local" ]; then
    awk -F'/' '
    {
        plen = $2 + 0; addr = $1
        if (plen >= 24) { print addr "/" plen; next }
        if (plen < 20) { next }
        split(addr, o, ".")
        q = 2 ^ (24 - plen)
        s3 = int(o[3] / q) * q
        for (k = 0; k < q; k++) printf "%s.%s.%d.0/24\n", o[1], o[2], s3 + k
    }' "$V4DIR/.seg.local" 2>/dev/null | sort -u > "$V4DIR/.seg.local.norm"
    LOCALCNT=$(grep -c . "$V4DIR/.seg.local.norm" 2>/dev/null); [ -z "$LOCALCNT" ] && LOCALCNT=0
    [ "$LOCALCNT" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  本地优选段：$LOCALCNT 段（确定性进池）" >> "$LOG"
fi
# 1a-3. 段源缓存兜底：订阅源全部失败时，用上次成功拉取的缓存兜底，保持探索面稳定
#       （订阅源成功则更新缓存 .seg.cache；失败且缓存存在则合并缓存段入池）
if [ -f "$V4DIR/.fetch.ok" ]; then
    cp "$V4DIR/.seg.all" "$V4DIR/.seg.cache" 2>/dev/null
elif [ -s "$V4DIR/.seg.cache" ]; then
    cat "$V4DIR/.seg.all" "$V4DIR/.seg.cache" 2>/dev/null | sort -u > "$V4DIR/.seg.all.u"
    mv "$V4DIR/.seg.all.u" "$V4DIR/.seg.all"
    echo "[$(date '+%m-%d %H:%M:%S')]  订阅源拉取失败，已用段源缓存兜底（缓存段并入池）" >> "$LOG"
fi
[ -s "$V4DIR/.seg.all" ] && SEGCNT=$(grep -c . "$V4DIR/.seg.all")
# 1b. 自建池：最近一轮 best 的上榜 IP（延迟<SELF_LAT）直接复测。
#     随机生成下 IP 不会跨轮重复，旧的"精确 IP 出现>=3 次"计数永远为 0（机制失效）；
#     连续性改为"上轮赢家直接回测"——已证明的好 IP 不丢失
#     best_*.txt 行格式：ip:443#ip-443-延迟ms-速度MB/s-地区（IPv4 无方括号）
#     用 FS="[-#]" 切分后：$2=ip、$4=延迟(ms)、$5=速度、$6=地区码
: > "$V4DIR/.p3"
LASTHIST=$(ls -t "$V4DIR"/history/best_*.txt 2>/dev/null | head -1)
[ -n "$LASTHIST" ] && \
awk -F'[-#]' -v slat="$SELF_LAT" \
    '{ ip=$2; lat=$4; sub(/ms$/, "", lat); if (ip ~ /^[0-9]+\./ && lat+0>0 && lat+0<slat) print ip }' \
    "$LASTHIST" > "$V4DIR/.p3" 2>/dev/null
[ -s "$V4DIR/.p3" ] && SCNT=$(grep -c . "$V4DIR/.p3")
# 1b-1. 前缀级段学习（滑动窗口）：只统计最近 LEARN_WINDOW 份历史（ls -t 时间倒序），
#       过时段自动滑出学习池、紧跟 CF 优选变化（不被历史累计次数软固化）。
#       按"轮次去重"——同一 /24 在同一轮最多计 1 次（避免单轮刷满污染学习）；
#       累计上榜轮次 >=SELF_MIN 的 /24 视为优质段 → 供 1c 强制入池。
#       按上榜轮次降序取 LEARN_MAX（确定性排序，取代哈希序 head）
#       WIN_FILES 供 1b-1 / 1b-2 共用（学习段统计与精确 IP 复测都只看窗口内历史）
: > "$V4DIR/.seg.learn.raw"
WIN_FILES=$(ls -t "$V4DIR"/history/best_*.txt 2>/dev/null | head -n "$LEARN_WINDOW")
[ -n "$WIN_FILES" ] && \
awk -F'[-#]' -v smin="$SELF_MIN" -v slat="$SELF_LAT" '
FNR==1 { fid++ }
{ ip=$2; lat=$4; sub(/ms$/, "", lat)
  if (ip ~ /^[0-9]+\./ && lat+0>0 && lat+0<slat) {
      split(ip, o, "."); k = o[1] "." o[2] "." o[3] ".0/24"
      if (seen[k] != fid) { seen[k] = fid; cnt[k]++ }
  } }
END { for (k in cnt) if (cnt[k] >= smin) print cnt[k] " " k }' \
    $WIN_FILES > "$V4DIR/.seg.learn.raw" 2>/dev/null
sort -rn "$V4DIR/.seg.learn.raw" 2>/dev/null | head -n "$LEARN_MAX" | awk '{print $2}' > "$V4DIR/.seg.learn"
rm -f "$V4DIR/.seg.learn.raw"
# 1b-1s. 短期记忆（冷启动加速）：上轮 best 上榜 IP 的 /24 前缀直接并入学习段，
#        让"上轮赢家"下轮立刻复用，不等跨轮计数；短期记忆排前（优先），长期学习段补足到 LEARN_MAX
if [ -s "$V4DIR/.p3" ]; then
    awk '{ split($1, o, "."); print o[1] "." o[2] "." o[3] ".0/24" }' "$V4DIR/.p3" | sort -u > "$V4DIR/.seg.recent"
    cat "$V4DIR/.seg.recent" "$V4DIR/.seg.learn" 2>/dev/null \
        | awk '!seen[$0]++' | head -n "$LEARN_MAX" > "$V4DIR/.seg.learn.tmp"
    mv "$V4DIR/.seg.learn.tmp" "$V4DIR/.seg.learn"
    rm -f "$V4DIR/.seg.recent"
fi
# 1b-2. 学习段历史精确 IP 复测：命中学习段的 /24 里，历史上真实上榜过的 IP 直接复测
#      （已证明的地址比重新随机更稳）；每个学习段最多 TGT_PER_IP 个
: > "$V4DIR/.learn.ips"
if [ -s "$V4DIR/.seg.learn" ]; then
    [ -n "$WIN_FILES" ] && \
    awk -F'[-#]' -v slat="$SELF_LAT" -v maxper="$TGT_PER_IP" '
    NR==FNR { lk[$1]=1; next }
    { ip=$2; lat=$4; sub(/ms$/, "", lat)
      if (ip ~ /^[0-9]+\./ && lat+0>0 && lat+0<slat) {
          split(ip, o, "."); k = o[1] "." o[2] "." o[3] ".0/24"
          if ((k in lk) && !(ip in seen) && gotc[k] < maxper) { gotc[k]++; seen[ip]=1; print ip }
      } }
    ' "$V4DIR/.seg.learn" $WIN_FILES > "$V4DIR/.learn.ips" 2>/dev/null
fi
LIPCNT=$(grep -c . "$V4DIR/.learn.ips" 2>/dev/null); [ -z "$LIPCNT" ] && LIPCNT=0
[ "$LIPCNT" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  学习复测：$LIPCNT 个历史精确好 IP 直接入池" >> "$LOG"
# 1c. 段级学习：1b-1 的学习 key（x.y.z.0/24）→ 与细分段池全字匹配 → 强制入池
#     注意：grep -f 空文件会匹配全部行，必须先确保模式文件非空
if [ "$SEGCNT" -gt 0 ] && [ -s "$V4DIR/.seg.learn" ]; then
    if [ -s "$V4DIR/.seg.learn" ]; then
        grep -Fxf "$V4DIR/.seg.learn" "$V4DIR/.seg.all" 2>/dev/null > "$V4DIR/.seg.keep"
        if [ -s "$V4DIR/.seg.keep" ]; then
            LEARNED=$(grep -c . "$V4DIR/.seg.keep")
            if [ "$LEARNED" -gt "$LEARN_MAX" ]; then
                head -n "$LEARN_MAX" "$V4DIR/.seg.keep" > "$V4DIR/.seg.keep.tmp"
                mv "$V4DIR/.seg.keep.tmp" "$V4DIR/.seg.keep"
                LEARNED=$LEARN_MAX
            fi
        fi
    fi
fi
# 1d. 随机抽段补足名额（排除已学习段 + 最近已探索段，扩大探索覆盖）
if [ "$SEGCNT" -gt 0 ]; then
    REMAIN=$((SEG_PICK - LEARNED))
    [ "$REMAIN" -lt 0 ] && REMAIN=0
    if [ "$REMAIN" -gt 0 ]; then
        # 先排除已学习段 → .seg.rest0
        if [ -s "$V4DIR/.seg.keep" ]; then
            grep -Fvxf "$V4DIR/.seg.keep" "$V4DIR/.seg.all" 2>/dev/null > "$V4DIR/.seg.rest0"
        else
            cp "$V4DIR/.seg.all" "$V4DIR/.seg.rest0" 2>/dev/null
        fi
        # 再排除最近 AVOID_KEEP 条已探索段（探索去重）；若排除后剩余不足 REMAIN，
        # 回退到仅排除学习段（允许重抽保量，避免段源不足导致抽样卡死）
        cp "$V4DIR/.seg.rest0" "$V4DIR/.seg.rest" 2>/dev/null
        if [ "$AVOID_KEEP" -gt 0 ] && [ -s "$V4DIR/.seg.avoid" ]; then
            grep -Fvxf "$V4DIR/.seg.avoid" "$V4DIR/.seg.rest0" 2>/dev/null > "$V4DIR/.seg.rest"
            RESTCNT=$(grep -c . "$V4DIR/.seg.rest" 2>/dev/null); [ -z "$RESTCNT" ] && RESTCNT=0
            [ "$RESTCNT" -lt "$REMAIN" ] && cp "$V4DIR/.seg.rest0" "$V4DIR/.seg.rest" 2>/dev/null
        fi
        awk -v n="$REMAIN" 'BEGIN{srand()}{print rand()"\t"$0}' "$V4DIR/.seg.rest" 2>/dev/null \
            | sort -k1,1n | head -n "$REMAIN" | cut -f2- > "$V4DIR/.seg.pick"
        PICKED=$(grep -c . "$V4DIR/.seg.pick" 2>/dev/null); [ -z "$PICKED" ] && PICKED=0
    fi
fi
SEGTOTAL=$((LEARNED + PICKED))
# 1d-3. 探索去重记录：本轮抽中的随机段追加进 .seg.avoid，保留最近 AVOID_KEEP 条
#       （滑动窗口，段被抽中后约停留 AVOID_KEEP/每轮随机段量 轮后重新可抽，扩大探索面）
if [ "$AVOID_KEEP" -gt 0 ] && [ -s "$V4DIR/.seg.pick" ]; then
    { cat "$V4DIR/.seg.avoid" "$V4DIR/.seg.pick" 2>/dev/null; } | tail -n "$AVOID_KEEP" > "$V4DIR/.seg.avoid.tmp"
    mv "$V4DIR/.seg.avoid.tmp" "$V4DIR/.seg.avoid"
fi
# 1d-2. 段展开为随机 IP：cfst 的 IPv4 算法对每条段只产出 1 个随机 IP（/24 恰好 1 个），
#       这里把每条入池段（学习段+随机段，均已被归一化为 /24 或更细）预先展开为
#       IPS_PER_SEG 个段内随机 IP（urandom 真随机种子、段内去重、避开 .0/.255），
#       让每条段贡献多个候选；粗于 /24 的段（正常已被归一化展开，此处兜底）在全段范围随机
EXPCNT=0
# 订阅段展开：学习段 + 随机段，每条 IPS_PER_SEG 个段内随机 IP
cat "$V4DIR/.seg.keep" "$V4DIR/.seg.pick" 2>/dev/null \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' | sort -u > "$V4DIR/.seg.exp.in"
if [ "$IPS_PER_SEG" -gt 0 ] && [ -s "$V4DIR/.seg.exp.in" ]; then
    RSEED2=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEED2" ] && RSEED2="4d3c2b1a"
    awk -v n="$IPS_PER_SEG" -v hx="$RSEED2" '
    function h2d(s,  i,c,r){r=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;r=r*16+c}return r}
    function emit(key) { printf "%d.%d.%d.%d\n", int(key/16777216)%256, int(key/65536)%256, int(key/256)%256, key%256 }
    BEGIN{srand(h2d(hx))}
    {
        split($0, a, "/")
        plen = a[2] + 0
        if (plen >= 32) { print a[1]; next }   # /32 原样保留
        split(a[1], o, ".")
        size = 2 ^ (32 - plen)
        base = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
        base = int(base / size) * size          # 对齐网络地址（容错未对齐写法）
        if (plen == 24) { lo = 1; hi = 254 }    # /24 避开网络地址 .0 与广播 .255
        else if (plen > 24) { lo = 0; hi = size - 1 }
        else { lo = 0; hi = size - 1 }          # 粗段兜底：全段随机
        cnt = 0; seen = 0
        while (cnt < n && seen < n * 10) {
            seen++
            key = base + int(rand() * (hi - lo + 1)) + lo
            if ((NR "." key) in got) continue
            got[NR "." key] = 1; cnt++
            emit(key)
        }
    }' "$V4DIR/.seg.exp.in" 2>/dev/null > "$V4DIR/.seg.exp"
    EXPCNT=$(grep -c . "$V4DIR/.seg.exp" 2>/dev/null); [ -z "$EXPCNT" ] && EXPCNT=0
fi
# 本地优选段展开：手写 CIDR 段（.seg.local.norm），每条 LOCAL_IPS_PER_SEG 个段内随机 IP。
# 手写段 = 人工优选段，无需大量撒网；/24 单段天然封顶 254，但多条叠加仍靠此值控制总量
LEXPCNT=0
cat "$V4DIR/.seg.local.norm" 2>/dev/null \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' | sort -u > "$V4DIR/.seg.exp.in.local"
if [ "$LOCAL_IPS_PER_SEG" -gt 0 ] && [ -s "$V4DIR/.seg.exp.in.local" ]; then
    RSEEDL=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEEDL" ] && RSEEDL="4d3c2b1a"
    awk -v n="$LOCAL_IPS_PER_SEG" -v hx="$RSEEDL" '
    function h2d(s,  i,c,r){r=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;r=r*16+c}return r}
    function emit(key) { printf "%d.%d.%d.%d\n", int(key/16777216)%256, int(key/65536)%256, int(key/256)%256, key%256 }
    BEGIN{srand(h2d(hx))}
    {
        split($0, a, "/")
        plen = a[2] + 0
        if (plen >= 32) { print a[1]; next }   # /32 原样保留
        split(a[1], o, ".")
        size = 2 ^ (32 - plen)
        base = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
        base = int(base / size) * size          # 对齐网络地址（容错未对齐写法）
        if (plen == 24) { lo = 1; hi = 254 }    # /24 避开网络地址 .0 与广播 .255
        else if (plen > 24) { lo = 0; hi = size - 1 }
        else { lo = 0; hi = size - 1 }          # 粗段兜底：全段随机
        cnt = 0; seen = 0
        while (cnt < n && seen < n * 10) {
            seen++
            key = base + int(rand() * (hi - lo + 1)) + lo
            if ((NR "." key) in got) continue
            got[NR "." key] = 1; cnt++
            emit(key)
        }
    }' "$V4DIR/.seg.exp.in.local" 2>/dev/null > "$V4DIR/.seg.exp.local"
    LEXPCNT=$(grep -c . "$V4DIR/.seg.exp.local" 2>/dev/null); [ -z "$LEXPCNT" ] && LEXPCNT=0
fi
# 1e. 外部 IP 抽样：IP 通道候选去重后随机抽 IP_PICK 条直接入池（cfst 按 /32 原样测）
IPCNT=0
if [ "$IP_PICK" -gt 0 ] && [ -s "$V4DIR/.ips.all" ]; then
    sort -u "$V4DIR/.ips.all" 2>/dev/null > "$V4DIR/.ips.u"
    RSEED=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEED" ] && RSEED="1a2b3c4d"
    awk -v n="$IP_PICK" -v hx="$RSEED" \
        'function h2d(s,  i,c,r){r=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;r=r*16+c}return r}
         BEGIN{srand(h2d(hx))}{print rand()"\t"$0}' "$V4DIR/.ips.u" 2>/dev/null \
        | sort -k1,1n | head -n "$IP_PICK" | cut -f2- > "$V4DIR/.ips.pick"
    IPCNT=$(grep -c . "$V4DIR/.ips.pick" 2>/dev/null); [ -z "$IPCNT" ] && IPCNT=0
    rm -f "$V4DIR/.ips.u"
fi
cat "$V4DIR/.seg.exp" "$V4DIR/.seg.exp.local" "$V4DIR/.learn.ips" "$V4DIR/.p3" "$V4DIR/.ips.pick" 2>/dev/null \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | sort -u > "$V4DIR/pool.txt"
PCNT=$(grep -c . "$V4DIR/pool.txt" 2>/dev/null)
[ -z "$PCNT" ] && PCNT=0
echo "[$(date '+%m-%d %H:%M:%S')]池构建：细分段源 $SEGCNT 段（学习段 $LEARNED + 随机段 $PICKED = $SEGTOTAL）+ 本地优选段 $LOCALCNT 段 → 展开 $EXPCNT 个段内随机 IP + 本地段展开 $LEXPCNT 个 + 学习复测 $LIPCNT 个 + 自建池 $SCNT 条 + 外部IP $IPCNT 条 → pool.txt 共 $PCNT 行" >> "$LOG"
rm -f "$V4DIR/.seg.all" "$V4DIR/.seg.local" "$V4DIR/.seg.local.norm" "$V4DIR/.seg.learn" "$V4DIR/.seg.keep" "$V4DIR/.seg.rest" "$V4DIR/.seg.rest0" "$V4DIR/.seg.pick" "$V4DIR/.seg.exp.in" "$V4DIR/.seg.exp" "$V4DIR/.seg.exp.in.local" "$V4DIR/.seg.exp.local" "$V4DIR/.learn.ips" "$V4DIR/.p3" "$V4DIR/.ips.all" "$V4DIR/.ips.pick"

if [ "$PCNT" -eq 0 ]; then
    echo "[$(date '+%m-%d %H:%M:%S')]池为空（细分段源失效且无历史），本轮退出，$RESULT_FILE 保留上次值" >> "$LOG"
    tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    exit 1
fi

# ---- 2. HTTPing 延迟测速：429 则退避等待后重扫；非 429 连续失败 3 轮判致命退出 ----
# 内存兜底：路由器常驻进程（CrashCore 等）占 ~288MB，cfst 大规模启动时 Go runtime
# 可能 "out of memory allocating heap arena map" 崩溃；先释放 page cache 腾出物理内存
sync 2>/dev/null; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
ROUND=0
CNT=0
FATAL=0
while :; do
    ROUND=$((ROUND + 1))
    rm -f "$V4DIR/.lat.csv"
    "$DIR/cfst" -f "$V4DIR/pool.txt" -httping -n "$LAT_THREAD" -t "$LAT_TIMEOUT" -dd -p 10 -url "$LAT_URL" -httping-code 204 -tl "$SELF_LAT" -o "$V4DIR/.lat.csv" > "$V4DIR/cfst_run.log" 2>&1
    RC=$?
    CNT=$(awk -F, 'NR>1 && $1 ~ /^[0-9]+\./ {n++} END{print n+0}' "$V4DIR/.lat.csv" 2>/dev/null)
    [ -z "$CNT" ] && CNT=0
    [ $RC -eq 0 ] && [ "$CNT" -gt 0 ] && break
    if [ "$ROUND" -ge "$MAX_SCAN_ROUNDS" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]延迟测速连续 $ROUND 轮失败，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
        tail -30 "$V4DIR/cfst_run.log" >> "$LOG" 2>/dev/null
        tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        exit 1
    fi
    echo "[$(date '+%m-%d %H:%M:%S')]第 $ROUND 轮延迟测速无结果（退出码 $RC），探测 429 状态" >> "$LOG"
    if ! wait_429_clear "$LAT_URL"; then
        echo "[$(date '+%m-%d %H:%M:%S')]429 等待超限，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
        tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        exit 1
    fi
    FATAL=$((FATAL + 1))
    if [ "$FATAL" -ge 3 ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]端点无 429 仍连续 $FATAL 轮失败，疑似致命问题（二进制/段源/网络），放弃本轮" >> "$LOG"
        tail -30 "$V4DIR/cfst_run.log" >> "$LOG" 2>/dev/null
        tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        exit 1
    fi
    echo "[$(date '+%m-%d %H:%M:%S')]端点未被限流，开始第 $((ROUND + 1)) 轮重扫" >> "$LOG"
done
echo "[$(date '+%m-%d %H:%M:%S')]延迟测速完成（第 $ROUND 轮）：$CNT 个候选（<250ms），取前 $DL_TOPN 名进入快筛" >> "$LOG"

# ---- 3. 下载闸门 + 4a 快筛：每个候选 1 次 x 5MB ----
if ! wait_429_clear "$DL_URL" 1; then
    echo "[$(date '+%m-%d %H:%M:%S')]下载源 429 等待超限，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
    tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    exit 1
fi
FASTTMP="$V4DIR/.fast.tmp"
: > "$FASTTMP"
N=0
# 快筛候选按机场（colo）分组采样（同 v6）：每个机场取延迟最低的 COLO_PICK 个进快筛，
# 强制每个机场都有代表；不足 DL_TOPN 时按延迟顺位回填；COLO_PICK=0 退化为纯延迟顺位
FAST_SEL="$V4DIR/.fast.sel.lat"
if [ "$COLO_PICK" -gt 0 ]; then
    awk -F, 'NR>1 && $1 ~ /^[0-9]+\./ {print $1"|"$5"|"$7}' "$V4DIR/.lat.csv" \
        | awk -F'|' -v cp="$COLO_PICK" -v tn="$DL_TOPN" '
        {
            if (picked >= tn) next
            if (colocnt[$3] < cp) { colocnt[$3]++; print $0; picked++ }
            else { rest[++nr] = $0 }
        }
        END { for (i = 1; i <= nr && picked < tn; i++) { print rest[i]; picked++ } }
        ' > "$FAST_SEL"
else
    awk -F, 'NR>1 && $1 ~ /^[0-9]+\./ {print $1"|"$5"|"$7}' "$V4DIR/.lat.csv" \
        | head -n "$DL_TOPN" > "$FAST_SEL"
fi
for entry in $(cat "$FAST_SEL" 2>/dev/null | grep .); do
    N=$((N + 1))
    ip="${entry%%|*}"; rest="${entry#*|}"; lat="${rest%%|*}"; colo="${rest##*|}"
    S1=$(dl_once "$FAST_URL" "$ip")
    S1I=$(awk -v v="${S1:-0}" 'BEGIN{printf "%.0f", v+0}')
    MB=$(awk -v v="$S1I" 'BEGIN{printf "%.2f", v/1048576}')
    NOTE=""
    [ -z "$S1" ] && NOTE="（429超限跳过，记0）"
    echo "[$(date '+%m-%d %H:%M:%S')]   快筛 [$N/$DL_TOPN] $ip：${MB} MB/s（延迟 ${lat}ms ${colo}）$NOTE" >> "$LOG"
    # 竖线连接为单个 token（busybox 的 for/命令替换按空白分词，字段内不能有空格）
    echo "$S1I|$lat|$ip|$colo" >> "$FASTTMP"
done
rm -f "$V4DIR/.lat.csv" "$FAST_SEL"
# 快筛排序：速度降序（busybox sort 不支持 -o 和 -k 逗号键，用 -rn + 临时文件写回）
sort -t"|" -rn "$FASTTMP" 2>/dev/null > "$FASTTMP.s" && mv "$FASTTMP.s" "$FASTTMP"
FCNT=$(grep -c . "$FASTTMP" 2>/dev/null); [ -z "$FCNT" ] && FCNT=0

# ---- 4b. 精测：多样性筛选后前 FAST_TOPN 名每个 DL_RUNS 次 x 9.1MB 取平均 ----
# 4a-2. 多样性筛选（三级，与 v6 同构，键为 /24 = 前三段）：同一 /24 最多 DIV_SEG_MAX 条、
#       同地区最多 DIV_COLO_MAX 条
#       ① 严格约束直选  ② 不足时放宽一档回填（同/24≤3、同地区≤5）
#       ③ 仍不足时按速度顺位无条件回填（候选地区高度集中时保证名单数量）
FSEL="$V4DIR/.fast.sel"
# 注意 -F"|"：FASTTMP 行为 speed|lat|ip|colo 竖线分隔（无空格），缺了它 $3/$4 全为空，
# 筛选会退化成"全部同 key"→ 恒触顶 → 纯速度序（上线首日实际发生的 bug）
awk -F"|" -v sm="$DIV_SEG_MAX" -v cm="$DIV_COLO_MAX" -v tn="$FAST_TOPN" '
function key24(ip,   n,a) { n = split(ip, a, "."); return a[1] "." a[2] "." a[3] }
{
    if (picked < tn) {
        k = key24($3); c = $4
        if (!((k in sc) && sc[k] >= sm) && !((c in cc) && cc[c] >= cm)) {
            sc[k]++; cc[c]++; s2[k]++; c2[c]++; print; picked++; next
        }
    }
    rest[++nr] = $0; rkey[nr] = key24($3); rcolo[nr] = $4
}
END {
    sm2 = sm + 1; cm2 = cm + 2
    for (i = 1; i <= nr && picked < tn; i++)
        if (!((rkey[i] in s2) && s2[rkey[i]] >= sm2) && !((rcolo[i] in c2) && c2[rcolo[i]] >= cm2)) {
            s2[rkey[i]]++; c2[rcolo[i]]++; print rest[i]; picked++; taken[i] = 1
        }
    for (i = 1; i <= nr && picked < tn; i++)
        if (!(i in taken)) { print rest[i]; picked++ }
}
' "$FASTTMP" > "$FSEL" 2>/dev/null
FSELC=$(grep -c . "$FSEL" 2>/dev/null); [ -z "$FSELC" ] && FSELC=0
echo "[$(date '+%m-%d %H:%M:%S')]快筛完成：$FCNT 个候选，多样性筛选（同/24≤$DIV_SEG_MAX、同地区≤$DIV_COLO_MAX）后 $FSELC 个进入精测（${DL_RUNS}次x10MB）" >> "$LOG"
RANKED="$V4DIR/.ranked.tmp"
: > "$RANKED"
M=0
for entry in $(cat "$FSEL" | grep .); do
    M=$((M + 1))
    rest="${entry#*|}"; lat="${rest%%|*}"; rest2="${rest#*|}"
    ip="${rest2%%|*}"; colo="${rest2##*|}"
    SUM=0; NS=0; FAILNOTE=""
    RUN=1
    while [ "$RUN" -le "$DL_RUNS" ]; do
        S=$(dl_once "$DL_URL" "$ip")
        if [ -z "$S" ]; then
            [ -n "$FAILNOTE" ] && FAILNOTE="$FAILNOTE "
            FAILNOTE="${FAILNOTE}样本${RUN}超限跳过"
        else
            SVAL=${S%%.*}
            [ -z "$SVAL" ] && SVAL=0
            SUM=$((SUM + SVAL)); NS=$((NS + 1))
        fi
        RUN=$((RUN + 1))
    done
    if [ "$NS" -gt 0 ]; then AVG=$((SUM / NS)); else AVG=0; fi
    MB=$(awk -v v="$AVG" 'BEGIN{printf "%.2f", v/1048576}')
    [ -n "$FAILNOTE" ] && FAILNOTE="（$FAILNOTE）"
    echo "[$(date '+%m-%d %H:%M:%S')]   精测 [$M/$FAST_TOPN] $ip：${MB} MB/s（延迟 ${lat}ms ${colo}）$FAILNOTE" >> "$LOG"
    echo "$AVG $lat $ip $colo" >> "$RANKED"
done
rm -f "$FASTTMP" "$FSEL"

# ---- 5. 排序（速度降序）→ TopN → 结果文件（$RESULT_FILE）+ 归档 ----
sort -rn "$RANKED" 2>/dev/null > "$RANKED.s" && mv "$RANKED.s" "$RANKED"

# 行格式：ip:443#ip-443-延迟ms-速度MB/s-地区（IPv4 不带方括号）
# 首行为生成时间戳（# 开头，外部消费方按行解析时跳过 # 注释行即可）
{
    echo "# updated: $(date '+%Y-%m-%d %H:%M:%S')"
    head -$TOPN "$RANKED" | while read sp lat ip colo; do
        mb=$(awk -v v="$sp" 'BEGIN{printf "%.2f", v/1048576}')
        echo "$ip:443#$ip-443-${lat}ms-${mb}MB/s-$colo"
    done
} > "$V4DIR/$RESULT_FILE"
rm -f "$RANKED"

RANKCNT=$(grep -vc '^#' "$V4DIR/$RESULT_FILE" 2>/dev/null)
[ -z "$RANKCNT" ] && RANKCNT=0

# 第 1 名信息（用于完成日志）；跳过首行时间戳注释
FIRST=$(grep -v '^#' "$V4DIR/$RESULT_FILE" 2>/dev/null | head -1)
if [ -n "$FIRST" ]; then
    BESTIP=$(echo "$FIRST" | awk -F'[-#]' '{print $2}')
    BESTLAT=$(echo "$FIRST" | awk -F'[-#]' '{lat=$4; sub(/ms$/, "", lat); print lat}')
    BESTMB=$(echo "$FIRST" | awk -F'[-#]' '{mb=$5; sub(/MB\/s$/, "", mb); print mb}')
    BESTCOLO=$(echo "$FIRST" | awk -F'[-#]' '{print $6}')
fi

STAMP=$(date "+%Y%m%d_%H%M%S")
mkdir -p "$V4DIR/history"
cp "$V4DIR/$RESULT_FILE" "$V4DIR/history/best_$STAMP.txt"
ls -t "$V4DIR"/history/best_*.txt 2>/dev/null | tail -n +$((KEEP + 1)) | while read f; do rm -f "$f"; done

NOTE=""
awk -v m="$BESTMB" -v sp="$SPEED_PASS" 'BEGIN{exit !(m+0 >= sp)}' && NOTE="（达到 ${SPEED_PASS}MB/s 标准）"
DUR=$(( $(date +%s) - START_TS ))
# 上榜机场分布（观测多样性是否生效）：如 "LAX×3 SEA×3 LHR×3 PDX×1 "
COLO_DIST=$(grep -v '^#' "$V4DIR/$RESULT_FILE" 2>/dev/null | grep -oE '\-[A-Z]{3}$' | sort | uniq -c | awk '{printf "%s×%s ", substr($2,2), $1}')
echo "[$(date '+%m-%d %H:%M:%S')]测速完成（耗时 ${DUR}s）：最优 $BESTIP（${BESTCOLO} 延迟 ${BESTLAT}ms 实测 ${BESTMB}MB/s）$NOTE，候选 $CNT 个，快筛 $N 个，精测 $M 个，上榜 $RANKCNT 个，机场分布 ${COLO_DIST}" >> "$LOG"

# ---- 6. 日志瘦身 ----
tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
