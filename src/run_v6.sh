#!/bin/sh
# ============================================================
# CloudflareSpeedTest IPv6 定时测速 + 优选脚本 v6（2026-11-03）
#
# 【池子构成】自建学习池 + baipiao.eu.org 细分 /48 段（每轮 20 条，每条展开 200 个段内随机 IP）
#   段源（V6url.txt）支持订阅 URL 与本地直写 CIDR 段/纯 IP 混写（每行一个，# 为注释）
#   - 前缀级自学习（滑动窗口）：最近 LEARN_WINDOW 份历史 best 的 IP 按 /48 前缀计数，
#     反复产出好 IP 的优质段强制入池（利用），过时段自动滑出紧跟 CF 变化；其余名额随机抽（探索），
#     且避开最近已探索段扩大覆盖；最近一轮上榜 IP 直接复测（连续性保障，驱动 /64 定向生成）
#   - 段展开：入池段由脚本生成 V6_IPS_PER_SEG 个段内随机 IPv6（候选量精确可控、
#     全段均匀采样），cfst 收到的池全部为裸 IP（/128 逐条原样测），不再用 cfst 随机游走
#   - HTTPing 目标 = cp.cloudflare.com/generate_204（captive portal 检测域，无 bot 防护基本不限流；www.cloudflare.com 有 WAF 会拦 Go 客户端，勿用）
#   - 下载目标 = 公共 CDN 大文件（cdn.jsdelivr.net 9.1MB + cdnjs.cloudflare.com 3.6MB，
#     均为 CF 边缘接入、可 --resolve 强制 IP、无测速限流）；启动时 HEAD 预检，
#     任一不可用自动回退官方 speed.cloudflare.com/__down
#
# 【流程】
# 1. 构建池 pool.txt = 自建池（最近一轮 best 的上榜 IP，延迟<SELF_LAT，直接复测保连续性）
#    + 学习段（最近 LEARN_WINDOW 份历史 best 的 /48 前缀产出好 IP >=SELF_MIN 次的优质段，最多 LEARN_MAX）
#    + 随机段（从合并段池随机抽补足，避开最近已探索段扩大覆盖）
#    → 学习段+随机段每条展开 V6_IPS_PER_SEG 个段内随机 IPv6（纯字符串随机，量可控）
#    最终 pool.txt = 展开的随机 IP + 自建池单 IP + 外部抽的纯 IP（全部裸 IP）
# 2. HTTPing 延迟测速两段式：t=1 粗扫（上限 SELF_LAT+60，只为缩小样本）→
#    幸存者 t=LAT_TRYS 次取平均 + 丢包上限 LAT_LOSS（上限 SELF_LAT）；失败则探 429，退避后重扫
# 3. 下载闸门：探测下载 URL，429 等到解除才开测
# 4. 下载实测两阶段：
#    4a 快筛：候选（DL_TOPN 个）每个下载 1 次 x 1MB（echarts.min.js），只做淘汰门槛：
#       低于本轮速度中位数 60% 的剔除，幸存者按 PICK_MODE 定序（lat=延迟优先 / speed=速度优先）
#    4b 精测：多样性筛选后前 FAST_TOPN 名每个下载 DL_RUNS 次 x 9.1MB 取平均；全样本失败的直接剔除
#    任何一次失败（429 / 超时 / 5xx）重试，单次样本重试上限 DL_RETRY 次
#    【v2】速度口径改为"稳态速度" = 下载量/(总耗时-首字节耗时)，剔除握手与慢启动，
#       修正原 speed_download 口径 15%~70% 的系统性低估
# 5. 排序：下载速度降序，取前 TOPN → 结果文件（文件名由 config.txt 的 V6_RESULT_FILE 决定，可配）
#    行格式：[ip]:443#ip-443-延迟ms-速度MB/s-地区
#    例：[2606:4700:57:641:561f:36e8:765e:ad62]:443#2606:4700:57:641:561f:36e8:765e:ad62-443-137ms-5.45MB/s-HK
#    history/（结果归档，反哺自建学习池 + 段级学习）
# 6. 结果只写本地：结果文件（TopN）+ history/ 归档
#    GitHub 上传统一由总调度 run.sh 在 v6/v4 都完成后执行（上传名 = V6_RESULT_FILE）
#    外部调用：raw.githubusercontent.com/meishero/cf-bestip/main/<V6_RESULT_FILE>
#             cdn.jsdelivr.net/gh/meishero/cf-bestip@main/<V6_RESULT_FILE>
#
# 【配置】全部参数已迁移至 /data/cfst/config.txt 统一维护
#   （v6/v4 独立配置段 + 三个总开关：GH_UPLOAD_ENABLE / V6_ENABLE / V4_ENABLE）
# 【参数速查】
#   每轮 20 段 x 200 IP/段 ≈ 4000 候选 / 延迟候选取前 DL_TOPN / 快筛 1MB x 1 次 / 精测 9.1MB x DL_RUNS 次
#   每轮下载流量 ≈ DL_TOPNx1MB + FAST_TOPNxDL_RUNSx9.1MB（轮末日志会打印实际值）
#   429 重试上限 3 次/样本；下载锁 = PID 存活检测（防叠跑）
# ============================================================
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

DIR=/data/cfst
V6DIR="$DIR/v6"   # v6 数据独立目录（池/锁/日志/结果/归档）
mkdir -p "$V6DIR"
cd "$DIR" || exit 1

# ---- 配置加载：所有参数统一在 /data/cfst/config.txt 维护 ----
CFG="$DIR/config.txt"
if [ ! -f "$CFG" ] || ! sh -n "$CFG" 2>/dev/null; then
    echo "[$(date '+%m-%d %H:%M:%S')]v6 退出：config.txt 缺失或语法错误，拒绝加载" >> "$V6DIR/run.log" 2>/dev/null
    exit 1
fi
. "$CFG"
# 总开关双保险：IPv6 未启用时静默退出
[ "$V6_ENABLE" = "1" ] || exit 0

# 将 config.txt 的 v6 配置映射到脚本内部变量
KEEP="$V6_KEEP"; TOPN="$V6_TOPN"; DL_TOPN="$V6_DL_TOPN"; FAST_TOPN="$V6_FAST_TOPN"
RESULT_FILE="$V6_RESULT_FILE"; [ -z "$RESULT_FILE" ] && RESULT_FILE="best_ip_v6.txt"
SEG_PICK="$V6_SEG_PICK"; LEARN_MAX="$V6_LEARN_MAX"; SELF_MIN="$V6_SELF_MIN"; SELF_LAT="$V6_SELF_LAT"
LEARN_WINDOW="$V6_LEARN_WINDOW"; [ -z "$LEARN_WINDOW" ] && LEARN_WINDOW=24
AVOID_KEEP="$V6_AVOID_KEEP"; [ -z "$AVOID_KEEP" ] && AVOID_KEEP=48
MAX_SCAN_ROUNDS="$V6_MAX_SCAN_ROUNDS"; LAT_URL="$V6_LAT_URL"; FAST_URL="$V6_FAST_URL"
DL_URL="$V6_DL_URL"; DL_MAXTIME="$V6_DL_MAXTIME"; DL_RETRY="$V6_DL_RETRY"; IP_PICK="$V6_IP_PICK"
DL_RUNS="$V6_DL_RUNS"; [ -z "$DL_RUNS" ] && DL_RUNS=2
WAIT_MAX="$V6_429_WAIT_MAX"; BACKOFF_ENABLE="$V6_BACKOFF_ENABLE"
BACKOFF_BASE="$V6_BACKOFF_BASE"; [ -z "$BACKOFF_BASE" ] && BACKOFF_BASE=120
BACKOFF_CAP="$V6_BACKOFF_CAP"; [ -z "$BACKOFF_CAP" ] && BACKOFF_CAP=600
LAT_TIMEOUT="$V6_LAT_TIMEOUT"; [ -z "$LAT_TIMEOUT" ] && LAT_TIMEOUT=1
IPS_PER_SEG="$V6_IPS_PER_SEG"; [ -z "$IPS_PER_SEG" ] && IPS_PER_SEG=200
LOCAL_IPS_PER_SEG="$V6_LOCAL_IPS_PER_SEG"; [ -z "$LOCAL_IPS_PER_SEG" ] && LOCAL_IPS_PER_SEG=20
LAT_THREAD="$V6_LAT_THREAD"; [ -z "$LAT_THREAD" ] && LAT_THREAD=32
DIV_SEG_MAX="$V6_DIV_SEG_MAX"; [ -z "$DIV_SEG_MAX" ] && DIV_SEG_MAX=2
DIV_COLO_MAX="$V6_DIV_COLO_MAX"; [ -z "$DIV_COLO_MAX" ] && DIV_COLO_MAX=3
COLO_PICK="$V6_COLO_PICK"; [ -z "$COLO_PICK" ] && COLO_PICK=3
TGT_PER_IP="$V6_TGT_PER_IP"; [ -z "$TGT_PER_IP" ] && TGT_PER_IP=25
TGT_MAX_PREFIX="$V6_TGT_MAX_PREFIX"; [ -z "$TGT_MAX_PREFIX" ] && TGT_MAX_PREFIX=16
SPEED_PASS="$V6_SPEED_PASS"; [ -z "$SPEED_PASS" ] && SPEED_PASS=8
LAT_TRYS="$V6_LAT_TRYS"; [ -z "$LAT_TRYS" ] && LAT_TRYS=4
LAT_LOSS="$V6_LAT_LOSS"; [ -z "$LAT_LOSS" ] && LAT_LOSS=0.2
PICK_MODE="$V6_PICK_MODE"; [ -z "$PICK_MODE" ] && PICK_MODE=lat
OOM_THREAD="$V6_OOM_THREAD"; [ -z "$OOM_THREAD" ] && OOM_THREAD=24
SRC_CONNECT_TIMEOUT="${SRC_CONNECT_TIMEOUT:-8}"
SRC_FETCH_TIMEOUT="${SRC_FETCH_TIMEOUT:-30}"
SRC_RETRY="${SRC_RETRY:-2}"
PRECHECK_TIMEOUT="${PRECHECK_TIMEOUT:-12}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-15}"
DL_CONNECT_TIMEOUT="${DL_CONNECT_TIMEOUT:-5}"
LOG_KEEP_LINES="${LOG_KEEP_LINES:-500}"

LOG="$V6DIR/run.log"
START_TS=$(date +%s)

# ---- 0. 锁文件：PID 存活检测（进程活着本轮退出；死锁自动接管） ----
LOCK="$V6DIR/.run.lock"
if [ -f "$LOCK" ]; then
    OLD_PID=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null \
       && grep -q "cfst/run_v6.sh" "/proc/$OLD_PID/cmdline" 2>/dev/null; then
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

# 单次下载（429 与网络失败都重试，上限 DL_RETRY 次）：参数1=URL 参数2=IP
# 【v2】输出"稳态速度"(B/s) = 下载量 / (总耗时 - 首字节耗时)：
#   curl 的 %{speed_download} 把 TCP/TLS 握手与首包等待都算进分母，实测系统性低估
#   15%（9MB 样本）~70%（1MB 快筛样本），会把"握手快"误当成"带宽高"；
#   减去 time_starttransfer 后比较的是纯传输阶段，更接近代理实际用起来的吞吐。
# 【v2】除 429 外的失败（000 超时 / 5xx / 连接被重置）也重试，不再当成 0 MB/s 样本——
#   原实现会把超时 IP 记 0 分写进榜单（历史上有 4 条 0.00MB/s 上榜）。
# 成功输出速度（B/s），重试超限输出空串；累计下载字节数写 .bytes 供轮末统计流量。
dl_once() {
    DU="$1"; DIP="$2"
    DH=$(echo "$DU" | sed -E 's|^https?://([^/]+)/.*|\1|')
    TRY=0
    while :; do
        RESP=$(curl -k -6 -o /dev/null -s \
               -w "%{http_code} %{size_download} %{time_starttransfer} %{time_total}" \
               --connect-timeout "$DL_CONNECT_TIMEOUT" --max-time $DL_MAXTIME \
               --resolve "$DH:443:[$DIP]" "$DU" 2>/dev/null)
        CODE=${RESP%% *}; REST1=${RESP#* }
        SIZE=${REST1%% *}; REST2=${REST1#* }
        TTFB=${REST2%% *}; TOT=${REST2##* }
        case "$CODE" in
            2*) ;;
            429)
                TRY=$((TRY + 1))
                if [ "$TRY" -gt "$DL_RETRY" ]; then
                    echo "[$(date '+%m-%d %H:%M:%S')]   下载 $DIP 连续 429 超过 $DL_RETRY 次重试，放弃该次样本" >> "$LOG"
                    echo ""
                    return 1
                fi
                if [ "$BACKOFF_ENABLE" = "1" ]; then
                    case $TRY in 1) SLP=$BACKOFF_BASE;; 2) SLP=$((BACKOFF_BASE*2));; *) SLP=$((BACKOFF_BASE*4));; esac
                else
                    SLP=$BACKOFF_BASE
                fi
                echo "[$(date '+%m-%d %H:%M:%S')]   下载 $DIP 撞 429 限流，等待 ${SLP}s 后重试（$TRY/$DL_RETRY）" >> "$LOG"
                sleep "$SLP"
                continue
                ;;
            *)
                TRY=$((TRY + 1))
                if [ "$TRY" -gt "$DL_RETRY" ]; then
                    echo "[$(date '+%m-%d %H:%M:%S')]   下载 $DIP 失败（HTTP ${CODE:-000}）超过 $DL_RETRY 次重试，放弃该次样本" >> "$LOG"
                    echo ""
                    return 1
                fi
                echo "[$(date '+%m-%d %H:%M:%S')]   下载 $DIP 失败（HTTP ${CODE:-000}），3s 后重试（$TRY/$DL_RETRY）" >> "$LOG"
                sleep 3
                continue
                ;;
        esac
        [ -n "$SIZE" ] && echo "$SIZE" >> "$V6DIR/.bytes"
        awk -v s="$SIZE" -v a="$TTFB" -v b="$TOT" 'BEGIN{d=b-a; if(d<0.2) d=b*0.2; printf "%.0f\n", (b>0 ? s/d : 0)}'
        return 0
    done
}

echo "[$(date '+%m-%d %H:%M:%S')]===== 开始 IPv6 测速（v6：段级学习/两阶段下载/Top10） =====" >> "$LOG"

# ---- 1. 构建测速池 pool.txt = 自建池 + 学习段 + 随机段 ----
SEGCNT=0; PICKED=0; LEARNED=0; SCNT=0; LOCALCNT=0
# 1a. 段源处理：按 $DIR/V6url.txt 逐行处理（# 与空行忽略），支持两类行：
#     - 本地直写：CIDR 段（如 2400:cb00:bbd1::/48）直接进段池；纯 IPv6 行直接进外部 IP 池
#     - 订阅地址（http/https）：curl 拉取后逐行自动分流：CIDR 段 → 段池；纯 IPv6 行 → 外部 IP 池
#     某个源失败/为空自动跳过；全部失败时仅剩自建池兜底
: > "$V6DIR/.seg.all"; : > "$V6DIR/.seg.local"; : > "$V6DIR/.ips.all"; rm -f "$V6DIR/.fetch.ok"
if [ -f "$DIR/V6url.txt" ]; then
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$DIR/V6url.txt" | while read SU; do
        [ -n "$SU" ] || continue
        # 本地直写行：CIDR 段 / 纯 IP 直接入池（不走网络，不受源拉取失败影响）
        if echo "$SU" | grep -qE '^[0-9a-fA-F:]+:/[0-9]+$'; then
            echo "$SU" >> "$V6DIR/.seg.local"
            continue
        fi
        if echo "$SU" | grep -qE '^[0-9a-fA-F:]+$' && echo "$SU" | grep -q ':' \
           && ! echo "$SU" | grep -qE '^:+$'; then
            echo "$SU" >> "$V6DIR/.ips.all"
            continue
        fi
        # 订阅地址：拉取（失败重试 SRC_RETRY 次，仍失败记日志跳过）
        r=0
        while [ "$r" -le "$SRC_RETRY" ]; do
            curl -s -k --connect-timeout "$SRC_CONNECT_TIMEOUT" --max-time "$SRC_FETCH_TIMEOUT" "$SU" > "$V6DIR/.fetch.raw" 2>/dev/null
            [ -s "$V6DIR/.fetch.raw" ] && break
            r=$((r + 1))
            [ "$r" -le "$SRC_RETRY" ] && sleep 2
        done
        if [ ! -s "$V6DIR/.fetch.raw" ]; then
            echo "[$(date '+%m-%d %H:%M:%S')]  订阅源拉取失败（重试 $SRC_RETRY 次后仍空）：$SU" >> "$LOG"
            continue
        fi
        touch "$V6DIR/.fetch.ok"
        # 段通道：CIDR 行
        grep -E '^[0-9a-fA-F:]+:/[0-9]+$' "$V6DIR/.fetch.raw" >> "$V6DIR/.seg.all" 2>/dev/null
        # IP 通道：纯 IPv6 行（不含 / 的 hex+冒号串，排除纯冒号）
        grep -E '^[0-9a-fA-F:]+$' "$V6DIR/.fetch.raw" 2>/dev/null \
            | grep ':' | grep -vE '^:+$' >> "$V6DIR/.ips.all"
    done
    rm -f "$V6DIR/.fetch.raw"
fi
# 1a-2. 段归一化：以 /48 为基准
#   - 细于 /48（/52 /56 /64 等）：原样保留（覆盖 IP 少，cfst 段内随机取样自然变少）
#   - 粗于 /48 且 ≥ /44（/44 /45 /46 /47）：展开为对应的 /48 行（最多 16 条），与其他源自然去重
#   - 粗于 /44（/40 /36 /32 等）：展开量过大（256~65536 条），跳过并记日志
#   - 全部 tolower 后 sort -u 去重
if [ -s "$V6DIR/.seg.all" ]; then
    awk -F'/' '
    function h2d(s,   i,c,r) { r=0; for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; r=r*16+c} return r }
    function d2h(n,   r) { if(n==0) return "0"; r=""; while(n>0){r=substr("0123456789abcdef",n%16+1,1) r; n=int(n/16)} return r }
    {
        plen = $2 + 0; addr = $1
        if (plen >= 48) { print tolower(addr) "/" plen; next }
        if (plen < 44) { print "SKIP_COARSE " $0; next }
        # 展开 :: 为 8 组
        for (i=1;i<=8;i++) g[i]="0"
        p = index(addr, "::")
        if (p > 0) {
            left = substr(addr, 1, p-1); right = substr(addr, p+2)
            nl = split(left, L, ":"); nr = split(right, R, ":")
            for (i=1;i<=nl;i++) g[i] = tolower(L[i])
            for (i=1;i<=nr;i++) g[8-nr+i] = tolower(R[i])
        } else {
            m = split(addr, G, ":")
            for (i=1;i<=m;i++) g[i] = tolower(G[i])
        }
        vary = 48 - plen; cnt = 2 ^ vary
        b3 = h2d(g[3])
        for (k=0; k<cnt; k++) print g[1] ":" g[2] ":" d2h(b3+k) "::/48"
    }' "$V6DIR/.seg.all" 2>/dev/null \
      | grep -v '^SKIP_COARSE ' > "$V6DIR/.seg.norm"
    # 统计被跳过的粗段数量（进日志）
    SKIPN=$(awk -F'/' '$2+0<44' "$V6DIR/.seg.all" 2>/dev/null | grep -c . )
    [ -z "$SKIPN" ] && SKIPN=0
    mv "$V6DIR/.seg.norm" "$V6DIR/.seg.all" 2>/dev/null
    sort -u "$V6DIR/.seg.all" > "$V6DIR/.seg.all.u" && mv "$V6DIR/.seg.all.u" "$V6DIR/.seg.all"
    [ "$SKIPN" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  归一化：$SKIPN 条粗于 /44 的段（如 /36 /32）展开量过大已跳过" >> "$LOG"
fi
# 1a-2b. 本地优选段归一化（手写 CIDR 段 = 人工优选段，与订阅段同规则归一化）
#        归一化后单独展开、确定性进池（不参与随机抽段）
if [ -s "$V6DIR/.seg.local" ]; then
    awk -F'/' '
    function h2d(s,   i,c,r) { r=0; for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; r=r*16+c} return r }
    function d2h(n,   r) { if(n==0) return "0"; r=""; while(n>0){r=substr("0123456789abcdef",n%16+1,1) r; n=int(n/16)} return r }
    {
        plen = $2 + 0; addr = $1
        if (plen >= 48) { print tolower(addr) "/" plen; next }
        if (plen < 44) { next }
        for (i=1;i<=8;i++) g[i]="0"
        p = index(addr, "::")
        if (p > 0) {
            left = substr(addr, 1, p-1); right = substr(addr, p+2)
            nl = split(left, L, ":"); nr = split(right, R, ":")
            for (i=1;i<=nl;i++) g[i] = tolower(L[i])
            for (i=1;i<=nr;i++) g[8-nr+i] = tolower(R[i])
        } else {
            m = split(addr, G, ":")
            for (i=1;i<=m;i++) g[i] = tolower(G[i])
        }
        vary = 48 - plen; cnt = 2 ^ vary
        b3 = h2d(g[3])
        for (k=0; k<cnt; k++) print g[1] ":" g[2] ":" d2h(b3+k) "::/48"
    }' "$V6DIR/.seg.local" 2>/dev/null | sort -u > "$V6DIR/.seg.local.norm"
    LOCALCNT=$(grep -c . "$V6DIR/.seg.local.norm" 2>/dev/null); [ -z "$LOCALCNT" ] && LOCALCNT=0
    [ "$LOCALCNT" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  本地优选段：$LOCALCNT 段（确定性进池）" >> "$LOG"
fi
# 1a-3. 段源缓存兜底：订阅源全部失败时，用上次成功拉取的缓存兜底，保持探索面稳定
#       （订阅源成功则更新缓存 .seg.cache；失败且缓存存在则合并缓存段入池）
if [ -f "$V6DIR/.fetch.ok" ]; then
    cp "$V6DIR/.seg.all" "$V6DIR/.seg.cache" 2>/dev/null
elif [ -s "$V6DIR/.seg.cache" ]; then
    cat "$V6DIR/.seg.all" "$V6DIR/.seg.cache" 2>/dev/null | sort -u > "$V6DIR/.seg.all.u"
    mv "$V6DIR/.seg.all.u" "$V6DIR/.seg.all"
    echo "[$(date '+%m-%d %H:%M:%S')]  订阅源拉取失败，已用段源缓存兜底（缓存段并入池）" >> "$LOG"
fi
[ -s "$V6DIR/.seg.all" ] && SEGCNT=$(grep -c . "$V6DIR/.seg.all")
# 1b. 自建池：最近一轮 best 的上榜 IP（延迟<SELF_LAT）直接复测。
#     随机生成下 IP 不会跨轮重复，旧的"精确 IP 出现>=3 次"计数永远为 0（机制失效）；
#     连续性改为"上轮赢家直接回测"——已证明的好 IP 不丢失，同时驱动 1b-2 定向生成
#     best_*.txt 行格式：[ip]:443#ip-443-延迟ms-速度MB/s-地区
#     用 FS="[][#-]" 切分后：$2=ip、$6=延迟(ms)、$7=速度、$8=地区码
: > "$V6DIR/.p3"
LASTHIST=$(ls -t "$V6DIR"/history/best_*.txt 2>/dev/null | head -1)
[ -n "$LASTHIST" ] && \
awk -F'[][#-]' -v slat="$SELF_LAT" \
    '{ ip=$2; lat=$6; sub(/ms$/, "", lat); if (ip ~ /^[0-9a-f]*:/ && lat+0>0 && lat+0<slat) print ip }' \
    "$LASTHIST" > "$V6DIR/.p3" 2>/dev/null
[ -s "$V6DIR/.p3" ] && SCNT=$(grep -c . "$V6DIR/.p3")
# 1b-1. 前缀级段学习（滑动窗口）：只统计最近 LEARN_WINDOW 份历史（ls -t 时间倒序），
#       过时段自动滑出学习池、紧跟 CF 优选变化（不被历史累计次数软固化）。
#       按"轮次去重"——同一 /48 在同一轮最多计 1 次（避免单轮刷满 10 条污染学习）；
#       累计上榜轮次 >=SELF_MIN 的 /48 视为优质段 → 供 1c 强制入池。
#       按上榜轮次降序取 LEARN_MAX（确定性排序，取代哈希序 head）
#       WIN_FILES 供 1b-1 / 1b-2 共用（学习段统计与精确 IP 复测都只看窗口内历史）
: > "$V6DIR/.seg.learn.raw"
WIN_FILES=$(ls -t "$V6DIR"/history/best_*.txt 2>/dev/null | head -n "$LEARN_WINDOW")
[ -n "$WIN_FILES" ] && \
awk -F'[][#-]' -v smin="$SELF_MIN" -v slat="$SELF_LAT" '
function k48(ip,   p,nl,nr,L,R) {
    p = index(ip, "::")
    if (p > 0) { nl = split(substr(ip,1,p-1), L, ":"); nr = split(substr(ip,p+2), R, ":") }
    else { nl = split(ip, L, ":"); nr = 0 }
    return ((nl>=1)?tolower(L[1]):"0") ":" ((nl>=2)?tolower(L[2]):"0") ":" ((nl>=3)?tolower(L[3]):"0")
}
FNR==1 { fid++ }
{ ip=$2; lat=$6; sub(/ms$/, "", lat)
  if (ip ~ /^[0-9a-f]*:/ && lat+0>0 && lat+0<slat) {
      k = k48(ip)
      if (seen[k] != fid) { seen[k] = fid; cnt[k]++ }
  } }
END { for (k in cnt) if (cnt[k] >= smin) print cnt[k] " " k }' \
    $WIN_FILES > "$V6DIR/.seg.learn.raw" 2>/dev/null
sort -rn "$V6DIR/.seg.learn.raw" 2>/dev/null | head -n "$LEARN_MAX" | awk '{print $2}' > "$V6DIR/.seg.learn"
rm -f "$V6DIR/.seg.learn.raw"
# 1b-1s. 短期记忆（冷启动加速）：上轮 best 上榜 IP 的 /48 前缀直接并入学习段，
#        让"上轮赢家"下轮立刻复用，不等跨轮计数（长期学习需跨 SELF_MIN 轮才激活）；
#        短期记忆排前（优先），长期学习段补足到 LEARN_MAX
if [ -s "$V6DIR/.p3" ]; then
    awk '
    function k48(ip,   p,nl,nr,L,R) {
        p = index(ip, "::")
        if (p > 0) { nl = split(substr(ip,1,p-1), L, ":"); nr = split(substr(ip,p+2), R, ":") }
        else { nl = split(ip, L, ":"); nr = 0 }
        return ((nl>=1)?tolower(L[1]):"0") ":" ((nl>=2)?tolower(L[2]):"0") ":" ((nl>=3)?tolower(L[3]):"0")
    }
    { print k48($1) }' "$V6DIR/.p3" | sort -u > "$V6DIR/.seg.recent"
    cat "$V6DIR/.seg.recent" "$V6DIR/.seg.learn" 2>/dev/null \
        | awk '!seen[$0]++' | head -n "$LEARN_MAX" > "$V6DIR/.seg.learn.tmp"
    mv "$V6DIR/.seg.learn.tmp" "$V6DIR/.seg.learn"
    rm -f "$V6DIR/.seg.recent"
fi
# 1b-2. 学习段历史精确 IP 复测：命中学习段的 /48 里，历史上真实上榜过的 IP 直接复测
#      （已证明的地址比重新随机更稳，是"利用"的核心）；每个学习段最多 TGT_PER_IP 个
: > "$V6DIR/.learn.ips"
if [ -s "$V6DIR/.seg.learn" ]; then
    [ -n "$WIN_FILES" ] && \
    awk -F'[][#-]' -v slat="$SELF_LAT" -v maxper="$TGT_PER_IP" '
    function k48(ip,   p,nl,nr,L,R) {
        p = index(ip, "::")
        if (p > 0) { nl = split(substr(ip,1,p-1), L, ":"); nr = split(substr(ip,p+2), R, ":") }
        else { nl = split(ip, L, ":"); nr = 0 }
        return ((nl>=1)?tolower(L[1]):"0") ":" ((nl>=2)?tolower(L[2]):"0") ":" ((nl>=3)?tolower(L[3]):"0")
    }
    NR==FNR { lk[$1]=1; next }
    { ip=$2; lat=$6; sub(/ms$/, "", lat)
      if (ip ~ /^[0-9a-f]*:/ && lat+0>0 && lat+0<slat) {
          k = k48(ip)
          if ((k in lk) && !(ip in seen) && gotc[k] < maxper) { gotc[k]++; seen[ip]=1; print ip }
      } }
    ' "$V6DIR/.seg.learn" $WIN_FILES > "$V6DIR/.learn.ips" 2>/dev/null
fi
LIPCNT=$(grep -c . "$V6DIR/.learn.ips" 2>/dev/null); [ -z "$LIPCNT" ] && LIPCNT=0
[ "$LIPCNT" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  学习复测：$LIPCNT 个历史精确好 IP 直接入池" >> "$LOG"
# 1b-2. 学习定向：自建池每个历史好 IP 的 /64 邻域生成 TGT_PER_IP 个随机 IP。
#     历史 /48 学习段展开是全段随机，而好 IP 只落在特定 /64 里，全段随机大概率扫不到
#     好邻域；这里定点在好 IP 的 /64 内生成随机 IP（同 /64 同地区，命中率远高于全段）。
#     /64 去重后最多取 16 个（上限 16xN 个，量可控）；urandom+md5 种子
TGCNT=0
if [ "$TGT_PER_IP" -gt 0 ] && [ -s "$V6DIR/.p3" ]; then
    RSEED3=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEED3" ] && RSEED3="9f8e7d6c"
    awk -v n="$TGT_PER_IP" -v mxp="$TGT_MAX_PREFIX" -v hx="$RSEED3" '
    function pad4(s) { while (length(s) < 4) s = "0" s; return s }
    function h2d(s,   i,c,r) { r=0; for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; r=r*16+c} return r }
    function expand6(a,   p,nl,nr,i,out) {
        for (i=1;i<=8;i++) g[i]="0000"
        p = index(a, "::")
        if (p > 0) {
            nl = split(substr(a,1,p-1), L, ":"); nr = split(substr(a,p+2), R, ":")
            for (i=1;i<=nl;i++) g[i] = pad4(tolower(L[i]))
            for (i=1;i<=nr;i++) g[8-nr+i] = pad4(tolower(R[i]))
        } else {
            nl = split(a, L, ":")
            if (nl != 8) return ""
            for (i=1;i<=nl;i++) g[i] = pad4(tolower(L[i]))
        }
        out = ""
        for (i=1;i<=8;i++) out = out g[i]
        return (length(out) == 32) ? out : ""
    }
    { full = expand6($1); if (full == "") next; pref = substr(full, 1, 16); if (!(pref in seen)) { seen[pref] = 1; pl[++np] = pref } }
    END {
        srand(h2d(hx))
        lim = (np > mxp) ? mxp : np
        for (i = 1; i <= lim; i++)
            for (k = 1; k <= n; k++) {
                out = pl[i]
                for (j = 17; j <= 32; j++) out = out substr("0123456789abcdef", int(rand()*16)+1, 1)
                res = ""
                for (q = 1; q <= 8; q++) res = res substr(out, (q-1)*4+1, 4) (q < 8 ? ":" : "")
                print res
            }
    }' "$V6DIR/.p3" 2>/dev/null > "$V6DIR/.p3.tgt"
    TGCNT=$(grep -c . "$V6DIR/.p3.tgt" 2>/dev/null); [ -z "$TGCNT" ] && TGCNT=0
    [ "$TGCNT" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S')]  学习定向：$SCNT 个历史好 IP → $TGCNT 个 /64 邻域随机 IP 入池" >> "$LOG"
fi
# 1c. 段级学习：1b-1 的学习 key（/48 前3组）→ 与段池按"前3组 key"包含匹配 → 强制入池
#     匹配规则：池中的段（无论 /48 还是更细的 /52 /56 /64）只要落在学习 /48 范围内即命中
if [ "$SEGCNT" -gt 0 ] && [ -s "$V6DIR/.seg.learn" ]; then
    # 池侧：每条段 → "key 段原始行"（key = 前3组，:: 压缩展开）
    awk '
    {
        p = index($0, "/"); addr = substr($0, 1, p-1)
        k1="0"; k2="0"; k3="0"
        pp = index(addr, "::")
        if (pp > 0) {
            nl = split(substr(addr,1,pp-1), L, ":")
            k1=(nl>=1)?tolower(L[1]):"0"; k2=(nl>=2)?tolower(L[2]):"0"; k3=(nl>=3)?tolower(L[3]):"0"
        } else {
            m = split(addr, G, ":")
            k1=(m>=1)?tolower(G[1]):"0"; k2=(m>=2)?tolower(G[2]):"0"; k3=(m>=3)?tolower(G[3]):"0"
        }
        print k1":"k2":"k3" "$0
    }' "$V6DIR/.seg.all" > "$V6DIR/.seg.keyed"
    # key 匹配 → 命中的段原始行入 .seg.keep
    awk 'NR==FNR{lk[$1]=1;next} ($1 in lk){print $2}' \
        "$V6DIR/.seg.learn" "$V6DIR/.seg.keyed" 2>/dev/null | sort -u > "$V6DIR/.seg.keep"
    if [ -s "$V6DIR/.seg.keep" ]; then
        LEARNED=$(grep -c . "$V6DIR/.seg.keep")
        if [ "$LEARNED" -gt "$LEARN_MAX" ]; then
            head -n "$LEARN_MAX" "$V6DIR/.seg.keep" > "$V6DIR/.seg.keep.tmp"
            mv "$V6DIR/.seg.keep.tmp" "$V6DIR/.seg.keep"
            LEARNED=$LEARN_MAX
        fi
    fi
fi
# 1d. 随机抽段补足名额（排除已学习段 + 最近已探索段，扩大探索覆盖）
if [ "$SEGCNT" -gt 0 ]; then
    REMAIN=$((SEG_PICK - LEARNED))
    [ "$REMAIN" -lt 0 ] && REMAIN=0
    if [ "$REMAIN" -gt 0 ]; then
        # 先排除已学习段 → .seg.rest0
        if [ -s "$V6DIR/.seg.keep" ]; then
            grep -Fvxf "$V6DIR/.seg.keep" "$V6DIR/.seg.all" 2>/dev/null > "$V6DIR/.seg.rest0"
        else
            cp "$V6DIR/.seg.all" "$V6DIR/.seg.rest0" 2>/dev/null
        fi
        # 再排除最近 AVOID_KEEP 条已探索段（探索去重）；若排除后剩余不足 REMAIN，
        # 回退到仅排除学习段（允许重抽保量，避免段源不足导致抽样卡死）
        cp "$V6DIR/.seg.rest0" "$V6DIR/.seg.rest" 2>/dev/null
        if [ "$AVOID_KEEP" -gt 0 ] && [ -s "$V6DIR/.seg.avoid" ]; then
            grep -Fvxf "$V6DIR/.seg.avoid" "$V6DIR/.seg.rest0" 2>/dev/null > "$V6DIR/.seg.rest"
            RESTCNT=$(grep -c . "$V6DIR/.seg.rest" 2>/dev/null); [ -z "$RESTCNT" ] && RESTCNT=0
            [ "$RESTCNT" -lt "$REMAIN" ] && cp "$V6DIR/.seg.rest0" "$V6DIR/.seg.rest" 2>/dev/null
        fi
        # 随机抽样：urandom → md5 前8位 hex → h2d 转十进制做种子（busybox 的 srand
        # 对超 32 位整数不可靠、od 输出损坏，此组合已在路由器实测三次抽样互不相同）
        RSEED=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
        [ -z "$RSEED" ] && RSEED="1a2b3c4d"
        awk -v n="$REMAIN" -v hx="$RSEED" \
            'function h2d(s,  i,c,r){r=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;r=r*16+c}return r}
             BEGIN{srand(h2d(hx))}{print rand()"\t"$0}' "$V6DIR/.seg.rest" 2>/dev/null \
            | sort -k1,1n | head -n "$REMAIN" | cut -f2- > "$V6DIR/.seg.pick"
        PICKED=$(grep -c . "$V6DIR/.seg.pick" 2>/dev/null); [ -z "$PICKED" ] && PICKED=0
    fi
fi
SEGTOTAL=$((LEARNED + PICKED))
# 1d-3. 探索去重记录：本轮抽中的随机段追加进 .seg.avoid，保留最近 AVOID_KEEP 条
#       （滑动窗口，段被抽中后约停留 AVOID_KEEP/每轮随机段量 轮后重新可抽，扩大探索面）
if [ "$AVOID_KEEP" -gt 0 ] && [ -s "$V6DIR/.seg.pick" ]; then
    { cat "$V6DIR/.seg.avoid" "$V6DIR/.seg.pick" 2>/dev/null; } | tail -n "$AVOID_KEEP" > "$V6DIR/.seg.avoid.tmp"
    mv "$V6DIR/.seg.avoid.tmp" "$V6DIR/.seg.avoid"
fi
# 1d-2. 段展开：学习段+随机段每条生成 IPS_PER_SEG 个段内随机 IPv6
#     IPv6 是 128 位，awk 浮点精度不够不能转数字算术，改用纯字符串运算：
#     地址展开为 32 个 hex 字符 → 保留前 plen/4 个 → 其余逐位随机取 hex；
#     非 nibble 对齐掩码（如 /50）在过渡位保留高位、低位随机；/48 全段均匀采样；
#     段内去重；urandom+md5 种子（同 1d，规避 busybox srand 大数截断坑）
EXPCNT=0
# 订阅段展开：学习段 + 随机段，每条 IPS_PER_SEG 个段内随机 IP
if [ "$SEGTOTAL" -gt 0 ] && [ "$IPS_PER_SEG" -gt 0 ]; then
    RSEED=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEED" ] && RSEED="1a2b3c4d"
    cat "$V6DIR/.seg.keep" "$V6DIR/.seg.pick" 2>/dev/null \
        | grep -E '^[0-9a-fA-F:]+:/[0-9]+$' \
        | awk -v n="$IPS_PER_SEG" -v hx="$RSEED" '
    function pad4(s) { while (length(s) < 4) s = "0" s; return s }
    function h2d(s,   i,c,r) { r=0; for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; r=r*16+c} return r }
    function expand6(a,   p,nl,nr,i,out) {
        for (i=1;i<=8;i++) g[i]="0000"
        p = index(a, "::")
        if (p > 0) {
            nl = split(substr(a,1,p-1), L, ":"); nr = split(substr(a,p+2), R, ":")
            for (i=1;i<=nl;i++) g[i] = pad4(tolower(L[i]))
            for (i=1;i<=nr;i++) g[8-nr+i] = pad4(tolower(R[i]))
        } else {
            nl = split(a, L, ":")
            if (nl != 8) return ""
            for (i=1;i<=nl;i++) g[i] = pad4(tolower(L[i]))
        }
        out = ""
        for (i=1;i<=8;i++) out = out g[i]
        return (length(out) == 32) ? out : ""
    }
    BEGIN { srand(h2d(hx)) }
    {
        split($0, a, "/")
        plen = a[2] + 0
        full = expand6(a[1])
        if (full == "" || plen > 128 || plen < 48) next
        keep = int(plen / 4); part = plen % 4
        cnt = 0; tries = 0
        while (cnt < n && tries < n * 10) {
            tries++
            out = substr(full, 1, keep)
            for (j = keep + 1; j <= 32; j++) {
                d = int(rand() * 16)
                if (j == keep + 1 && part > 0) {
                    pow = 2 ^ part
                    d = int(h2d(substr(full, j, 1)) / pow) * pow + int(rand() * pow)
                }
                out = out substr("0123456789abcdef", d + 1, 1)
            }
            key = ""
            for (j = 1; j <= 8; j++) key = key substr(out, (j-1)*4+1, 4) ":"
            if (key in got) continue
            got[key] = 1; cnt++
            res = ""
            for (j = 1; j <= 8; j++) res = res substr(out, (j-1)*4+1, 4) (j < 8 ? ":" : "")
            print res
        }
    }' > "$V6DIR/.seg.exp" 2>/dev/null
    EXPCNT=$(grep -c . "$V6DIR/.seg.exp" 2>/dev/null); [ -z "$EXPCNT" ] && EXPCNT=0
fi
# 本地优选段展开：手写 CIDR 段（.seg.local.norm），每条 LOCAL_IPS_PER_SEG 个段内随机 IP。
# 手写段 = 人工优选段，无需像订阅段那样大量撒网；且确定性全进，段数多时靠独立配置控制总量
LEXPCNT=0
if [ "$LOCALCNT" -gt 0 ] && [ "$LOCAL_IPS_PER_SEG" -gt 0 ]; then
    RSEEDL=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEEDL" ] && RSEEDL="1a2b3c4d"
    cat "$V6DIR/.seg.local.norm" 2>/dev/null \
        | grep -E '^[0-9a-fA-F:]+:/[0-9]+$' \
        | awk -v n="$LOCAL_IPS_PER_SEG" -v hx="$RSEEDL" '
    function pad4(s) { while (length(s) < 4) s = "0" s; return s }
    function h2d(s,   i,c,r) { r=0; for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; r=r*16+c} return r }
    function expand6(a,   p,nl,nr,i,out) {
        for (i=1;i<=8;i++) g[i]="0000"
        p = index(a, "::")
        if (p > 0) {
            nl = split(substr(a,1,p-1), L, ":"); nr = split(substr(a,p+2), R, ":")
            for (i=1;i<=nl;i++) g[i] = pad4(tolower(L[i]))
            for (i=1;i<=nr;i++) g[8-nr+i] = pad4(tolower(R[i]))
        } else {
            nl = split(a, L, ":")
            if (nl != 8) return ""
            for (i=1;i<=nl;i++) g[i] = pad4(tolower(L[i]))
        }
        out = ""
        for (i=1;i<=8;i++) out = out g[i]
        return (length(out) == 32) ? out : ""
    }
    BEGIN { srand(h2d(hx)) }
    {
        split($0, a, "/")
        plen = a[2] + 0
        full = expand6(a[1])
        if (full == "" || plen > 128 || plen < 48) next
        keep = int(plen / 4); part = plen % 4
        cnt = 0; tries = 0
        while (cnt < n && tries < n * 10) {
            tries++
            out = substr(full, 1, keep)
            for (j = keep + 1; j <= 32; j++) {
                d = int(rand() * 16)
                if (j == keep + 1 && part > 0) {
                    pow = 2 ^ part
                    d = int(h2d(substr(full, j, 1)) / pow) * pow + int(rand() * pow)
                }
                out = out substr("0123456789abcdef", d + 1, 1)
            }
            key = ""
            for (j = 1; j <= 8; j++) key = key substr(out, (j-1)*4+1, 4) ":"
            if (key in got) continue
            got[key] = 1; cnt++
            res = ""
            for (j = 1; j <= 8; j++) res = res substr(out, (j-1)*4+1, 4) (j < 8 ? ":" : "")
            print res
        }
    }' > "$V6DIR/.seg.exp.local" 2>/dev/null
    LEXPCNT=$(grep -c . "$V6DIR/.seg.exp.local" 2>/dev/null); [ -z "$LEXPCNT" ] && LEXPCNT=0
fi
# 1e. 外部 IP 抽样：IP 通道候选去重后随机抽 IP_PICK 条直接入池（cfst 按 /128 原样测）
IPCNT=0
if [ "$IP_PICK" -gt 0 ] && [ -s "$V6DIR/.ips.all" ]; then
    sort -u "$V6DIR/.ips.all" 2>/dev/null > "$V6DIR/.ips.u"
    RSEED=$(head -c 8 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -c1-8)
    [ -z "$RSEED" ] && RSEED="1a2b3c4d"
    awk -v n="$IP_PICK" -v hx="$RSEED" \
        'function h2d(s,  i,c,r){r=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;r=r*16+c}return r}
         BEGIN{srand(h2d(hx))}{print rand()"\t"$0}' "$V6DIR/.ips.u" 2>/dev/null \
        | sort -k1,1n | head -n "$IP_PICK" | cut -f2- > "$V6DIR/.ips.pick"
    IPCNT=$(grep -c . "$V6DIR/.ips.pick" 2>/dev/null); [ -z "$IPCNT" ] && IPCNT=0
    rm -f "$V6DIR/.ips.u"
fi
# 池组装：段展开生效时 pool = 展开随机 IP + 自建池 + 外部 IP（全部裸 IP，量精确可控）；
# 展开关闭（IPS_PER_SEG=0）或失败时回退旧行为：段 CIDR 原样交给 cfst 随机游走
if [ $((EXPCNT + LEXPCNT)) -gt 0 ]; then
    cat "$V6DIR/.seg.exp" "$V6DIR/.seg.exp.local" "$V6DIR/.learn.ips" "$V6DIR/.p3.tgt" "$V6DIR/.p3" "$V6DIR/.ips.pick" 2>/dev/null \
        | grep -E '^([0-9a-fA-F:]+:[0-9a-fA-F]*|[0-9a-fA-F:]+:/[0-9]+)$' \
        | sort -u > "$V6DIR/pool.txt"
else
    cat "$V6DIR/.learn.ips" "$V6DIR/.p3.tgt" "$V6DIR/.seg.keep" "$V6DIR/.seg.pick" "$V6DIR/.seg.local.norm" "$V6DIR/.p3" "$V6DIR/.ips.pick" 2>/dev/null \
        | grep -E '^([0-9a-fA-F:]+:[0-9a-fA-F]*|[0-9a-fA-F:]+:/[0-9]+)$' \
        | sort -u > "$V6DIR/pool.txt"
fi
PCNT=$(grep -c . "$V6DIR/pool.txt" 2>/dev/null)
[ -z "$PCNT" ] && PCNT=0
echo "[$(date '+%m-%d %H:%M:%S')]池构建：细分段源 $SEGCNT 段（学习段 $LEARNED + 随机段 $PICKED = $SEGTOTAL）+ 本地优选段 $LOCALCNT 段 → 展开 $EXPCNT 个段内随机 IP + 本地段展开 $LEXPCNT 个 + 学习复测 $LIPCNT 个 + 定向 $TGCNT 个 + 自建池 $SCNT 条 + 外部IP $IPCNT 条 → pool.txt 共 $PCNT 行" >> "$LOG"
rm -f "$V6DIR/.seg.all" "$V6DIR/.seg.local" "$V6DIR/.seg.local.norm" "$V6DIR/.seg.learn" "$V6DIR/.seg.keep" "$V6DIR/.seg.rest" "$V6DIR/.seg.rest0" "$V6DIR/.seg.pick" "$V6DIR/.seg.exp" "$V6DIR/.seg.exp.local" "$V6DIR/.learn.ips" "$V6DIR/.p3" "$V6DIR/.p3.tgt" "$V6DIR/.seg.keyed" "$V6DIR/.ips.all" "$V6DIR/.ips.pick"

if [ "$PCNT" -eq 0 ]; then
    echo "[$(date '+%m-%d %H:%M:%S')]池为空（细分段源失效且无历史），本轮退出，$RESULT_FILE 保留上次值" >> "$LOG"
    tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    exit 1
fi

# ---- 2. HTTPing 延迟测速（两段式）：先 t=1 剔死 IP，再对幸存者做 t=LAT_TRYS 次取平均 ----
# 【v2】原实现 -t 1：每个 IP 只探测 1 次，"平均延迟"就是单样本；同机场内 116/117/118ms
#   的排序全是噪声，而 -tl 250 的通过率高达 54%~88%，等于没筛。
#   两段式 = 第一段用 1 次探测快速缩小样本（4490→约 2400），第二段只对幸存者做 4 次探测，
#   总代价约为"全量 4 次"的 1/3，却能得到稳定的平均延迟。
#   第一段用放宽的上限（SELF_LAT+60），避免单次探测抖动把本可通过的 IP 误杀；
#   第二段用严格上限 + -tlr 丢包门槛（4 次里丢 1 次即 0.25 > 0.2，淘汰有丢包的 IP）。
# -p 0：只是"控制台显示条数"（不是端口探测间隔），0 = 不打印表格，CSV 照常写入。
# 内存兜底：路由器常驻进程（CrashCore 等）占 ~288MB，cfst 大规模启动时 Go runtime
# 可能 "out of memory allocating heap arena map" 崩溃；每轮扫描前先释放 page cache。
PASS1_LAT=$((SELF_LAT + 60))
ROUND=0
CNT=0
FATAL=0
OOMHIT=0
while :; do
    ROUND=$((ROUND + 1))
    sync 2>/dev/null; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    rm -f "$V6DIR/.lat.csv" "$V6DIR/.lat1.csv" "$V6DIR/.lat1.ips"
    # 第一段：粗糙延迟筛（t=1，只为缩小第二段样本量）
    "$DIR/cfst" -f "$V6DIR/pool.txt" -httping -n "$LAT_THREAD" -t "$LAT_TIMEOUT" -dd -p 0 \
        -url "$LAT_URL" -httping-code 204 -tl "$PASS1_LAT" -o "$V6DIR/.lat1.csv" \
        > "$V6DIR/cfst_run.log" 2>&1
    RC=$?
    # 启动期 OOM：Go runtime 拿不到堆内存时二进制会立刻带栈退出，此时轮转 30 次毫无意义
    if [ "$RC" -ne 0 ] && grep -q "out of memory" "$V6DIR/cfst_run.log" 2>/dev/null; then
        OOMHIT=$((OOMHIT + 1))
        echo "[$(date '+%m-%d %H:%M:%S')]cfst 启动期内存不足（heap arena map），第 $OOMHIT 次；并发 $LAT_THREAD → $OOM_THREAD 后重试" >> "$LOG"
        [ "$OOMHIT" -ge 2 ] && {
            echo "[$(date '+%m-%d %H:%M:%S')]内存不足连续 $OOMHIT 次，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
            tail -30 "$V6DIR/cfst_run.log" >> "$LOG" 2>/dev/null
            tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
            exit 1
        }
        LAT_THREAD="$OOM_THREAD"
        sleep 10
        continue
    fi
    awk -F, 'NR>1 && $1 ~ /^[0-9a-f]*:/ {print $1}' "$V6DIR/.lat1.csv" 2>/dev/null > "$V6DIR/.lat1.ips"
    P1CNT=$(grep -c . "$V6DIR/.lat1.ips" 2>/dev/null); [ -z "$P1CNT" ] && P1CNT=0
    # 第二段：幸存者复测（t=LAT_TRYS 次取平均 + 丢包上限 LAT_LOSS）
    if [ "$RC" -eq 0 ] && [ "$P1CNT" -gt 0 ]; then
        "$DIR/cfst" -f "$V6DIR/.lat1.ips" -httping -n "$LAT_THREAD" -t "$LAT_TRYS" -dd -p 0 \
            -url "$LAT_URL" -httping-code 204 -tl "$SELF_LAT" -tlr "$LAT_LOSS" -o "$V6DIR/.lat.csv" \
            >> "$V6DIR/cfst_run.log" 2>&1
        RC=$?
    fi
    CNT=$(awk -F, 'NR>1 && $1 ~ /^[0-9a-f]*:/ {n++} END{print n+0}' "$V6DIR/.lat.csv" 2>/dev/null)
    [ -z "$CNT" ] && CNT=0
    [ $RC -eq 0 ] && [ "$CNT" -gt 0 ] && break
    if [ "$ROUND" -ge "$MAX_SCAN_ROUNDS" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]延迟测速连续 $ROUND 轮失败，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
        tail -30 "$V6DIR/cfst_run.log" >> "$LOG" 2>/dev/null
        tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        exit 1
    fi
    echo "[$(date '+%m-%d %H:%M:%S')]第 $ROUND 轮延迟测速无结果（第一段 $P1CNT 个候选、退出码 $RC），探测 429 状态" >> "$LOG"
    if ! wait_429_clear "$LAT_URL"; then
        echo "[$(date '+%m-%d %H:%M:%S')]429 等待超限，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
        tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        exit 1
    fi
    FATAL=$((FATAL + 1))
    if [ "$FATAL" -ge 3 ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]端点无 429 仍连续 $FATAL 轮失败，疑似致命问题（二进制/段源/网络），放弃本轮" >> "$LOG"
        tail -30 "$V6DIR/cfst_run.log" >> "$LOG" 2>/dev/null
        tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        exit 1
    fi
    echo "[$(date '+%m-%d %H:%M:%S')]端点未被限流，开始第 $((ROUND + 1)) 轮重扫" >> "$LOG"
done
echo "[$(date '+%m-%d %H:%M:%S')]延迟测速完成（第 $ROUND 轮，两段式 t=1→t=$LAT_TRYS、丢包≤$LAT_LOSS）：粗筛幸存 $P1CNT 个 → 精测延迟 $CNT 个候选（<$SELF_LAT ms），取前 $DL_TOPN 名进入快筛" >> "$LOG"
rm -f "$V6DIR/.lat1.csv" "$V6DIR/.lat1.ips"
# cfst 的进度条用 \r 覆写、没有换行，两段式会让 cfst_run.log 涨到 ~100KB/轮；
# 这里只保留最后 20KB（含第二段结果表尾部），减少 UBI 闪存写入（日志仍留在 /data，重启不丢）
tail -c 20000 "$V6DIR/cfst_run.log" > "$V6DIR/.c.tmp" 2>/dev/null && mv "$V6DIR/.c.tmp" "$V6DIR/cfst_run.log"

# ---- 3. 下载闸门 + 4a 快筛：每个候选 1 次 x 1MB（只做淘汰门槛，不参与定序） ----
if ! wait_429_clear "$DL_URL" 1; then
    echo "[$(date '+%m-%d %H:%M:%S')]下载源 429 等待超限，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
    tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    exit 1
fi
FASTTMP="$V6DIR/.fast.tmp"
: > "$FASTTMP"
: > "$V6DIR/.bytes"   # 流量计数从快筛开始（含快筛 + 精测 + 重试），轮末统计后删除
N=0
# 快筛候选按机场（colo）分组采样：从全部延迟候选里，每个机场取延迟最低的 COLO_PICK 个，
# 强制每个机场都有代表进快筛（防单一机场延迟优势霸榜，实测曾出现 30 个快筛候选 100% 同机场）；
# 不足 DL_TOPN 时按延迟顺位回填；COLO_PICK=0 时退化为纯延迟顺位（延迟最优优先）
FAST_SEL="$V6DIR/.fast.sel.lat"
if [ "$COLO_PICK" -gt 0 ]; then
    awk -F, 'NR>1 && $1 ~ /^[0-9a-f]*:/ {print $1"|"$5"|"$7}' "$V6DIR/.lat.csv" \
        | awk -F'|' -v cp="$COLO_PICK" -v tn="$DL_TOPN" '
        {
            if (picked >= tn) next
            if (colocnt[$3] < cp) { colocnt[$3]++; print $0; picked++ }
            else { rest[++nr] = $0 }
        }
        END { for (i = 1; i <= nr && picked < tn; i++) { print rest[i]; picked++ } }
        ' > "$FAST_SEL"
else
    awk -F, 'NR>1 && $1 ~ /^[0-9a-f]*:/ {print $1"|"$5"|"$7}' "$V6DIR/.lat.csv" \
        | head -n "$DL_TOPN" > "$FAST_SEL"
fi
for entry in $(cat "$FAST_SEL" 2>/dev/null | grep .); do
    N=$((N + 1))
    ip="${entry%%|*}"; rest="${entry#*|}"; lat="${rest%%|*}"; colo="${rest##*|}"
    S1=$(dl_once "$FAST_URL" "$ip")
    if [ -z "$S1" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]   快筛 [$N/$DL_TOPN] $ip：下载失败（延迟 ${lat}ms ${colo}），剔除" >> "$LOG"
        continue
    fi
    S1I=$(awk -v v="$S1" 'BEGIN{printf "%.0f", v+0}')
    MB=$(awk -v v="$S1I" 'BEGIN{printf "%.2f", v/1048576}')
    echo "[$(date '+%m-%d %H:%M:%S')]   快筛 [$N/$DL_TOPN] $ip：${MB} MB/s（延迟 ${lat}ms ${colo}）" >> "$LOG"
    # 竖线连接为单个 token（busybox 的 for/命令替换按空白分词，字段内不能有空格）
    echo "$S1I|$lat|$ip|$colo" >> "$FASTTMP"
done
rm -f "$V6DIR/.lat.csv" "$FAST_SEL"
FCNT=$(grep -c . "$FASTTMP" 2>/dev/null); [ -z "$FCNT" ] && FCNT=0

# ---- 4a-2. 淘汰赛：快筛只做门槛、不参与定序 ----
# 依据（实测 9 轮配对统计）：1MB 快筛与 9.1MB 精测的 Spearman 相关性仅 0.42~0.94（均值 0.71），
#   且系统性低估 2.4~4 倍；用它排前 N 名等于让噪声决定谁进精测——多轮里"快筛第 1 名"
#   在精测中掉到第 7~12 名。故改为：以本轮快筛速度中位数的 60% 为门槛剔除废物样本（
#   50% 太松，实测常常一个都砍不掉；60% 能稳定砍掉明显掉队的），
#   幸存者再按 PICK_MODE 定序（默认 lat=延迟优先，配合下面的机场配额与 /48 配额取多样性）。
# 幸存不足 FAST_TOPN 时按速度补足，保证精测名单数量。
MED=0; FLOOR=0
if [ "$FCNT" -gt 0 ]; then
    MED=$(awk -F'|' '{print $1}' "$FASTTMP" | sort -n \
          | awk '{a[NR]=$1} END{if(NR==0)print 0; else if(NR%2)print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}')
    [ -z "$MED" ] && MED=0
    FLOOR=$((MED * 6 / 10))
fi
awk -F'|' -v f="$FLOOR" '($1 + 0) >= f' "$FASTTMP" 2>/dev/null > "$FASTTMP.pass"
KCNT=$(grep -c . "$FASTTMP.pass" 2>/dev/null); [ -z "$KCNT" ] && KCNT=0
if [ "$KCNT" -lt "$FAST_TOPN" ]; then
    sort -t"|" -rn "$FASTTMP" 2>/dev/null | head -n "$FAST_TOPN" > "$FASTTMP.pass"
    KCNT=$(grep -c . "$FASTTMP.pass" 2>/dev/null); [ -z "$KCNT" ] && KCNT=0
fi
if [ "$PICK_MODE" = "speed" ]; then
    sort -t"|" -rn "$FASTTMP.pass" 2>/dev/null > "$FASTTMP.s"
else
    # 注意：本机 busybox v1.25 的 sort 不支持 -k 键（实测 -k2,2n 静默无效、顺序不变），
    # 这里把延迟换到第 1 字段，用 sort -n 按整行首个数字排序，再换回来。
    awk -F'|' '{print $2"|"$1"|"$3"|"$4}' "$FASTTMP.pass" 2>/dev/null \
        | sort -t"|" -n \
        | awk -F'|' '{print $2"|"$1"|"$3"|"$4}' > "$FASTTMP.s" 2>/dev/null
fi
mv "$FASTTMP.s" "$FASTTMP" 2>/dev/null; rm -f "$FASTTMP.pass"
echo "[$(date '+%m-%d %H:%M:%S')]快筛淘汰：$FCNT 个有效样本，中位数 $(awk -v v="$MED" 'BEGIN{printf "%.2f", v/1048576}') MB/s，门槛 $(awk -v v="$FLOOR" 'BEGIN{printf "%.2f", v/1048576}') MB/s → 幸存 $KCNT 个，按 ${PICK_MODE} 定序" >> "$LOG"

# ---- 4b. 精测：多样性筛选后前 FAST_TOPN 名每个 DL_RUNS 次 x 9.1MB 取平均 ----
# 4a-2. 多样性筛选（三级）：同一 /48 最多 DIV_SEG_MAX 条、同地区最多 DIV_COLO_MAX 条
#       ① 严格约束直选  ② 不足时放宽一档回填（同/48≤3、同地区≤5）
#       ③ 仍不足时按速度顺位无条件回填（候选地区高度集中时保证名单数量）
FSEL="$V6DIR/.fast.sel"
# 注意 -F"|"：FASTTMP 行为 speed|lat|ip|colo 竖线分隔（无空格），缺了它 $3/$4 全为空，
# 筛选会退化成"全部同 key"→ 恒触顶 → 纯速度序（上线首日实际发生的 bug）
awk -F"|" -v sm="$DIV_SEG_MAX" -v cm="$DIV_COLO_MAX" -v tn="$FAST_TOPN" '
function key48(ip,   p,nl,nr,L,R) {
    p = index(ip, "::")
    if (p > 0) { nl = split(substr(ip,1,p-1), L, ":"); nr = split(substr(ip,p+2), R, ":") }
    else { nl = split(ip, L, ":"); nr = 0 }
    return ((nl>=1)?tolower(L[1]):"0") ":" ((nl>=2)?tolower(L[2]):"0") ":" ((nl>=3)?tolower(L[3]):"0")
}
{
    if (picked < tn) {
        k = key48($3); c = $4
        if (!((k in sc) && sc[k] >= sm) && !((c in cc) && cc[c] >= cm)) {
            sc[k]++; cc[c]++; s2[k]++; c2[c]++; print; picked++; next
        }
    }
    rest[++nr] = $0; rkey[nr] = key48($3); rcolo[nr] = $4
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
echo "[$(date '+%m-%d %H:%M:%S')]快筛完成：$FCNT 个候选，多样性筛选（同/48≤$DIV_SEG_MAX、同地区≤$DIV_COLO_MAX）后 $FSELC 个进入精测（${DL_RUNS}次x9.1MB）" >> "$LOG"
if [ "$FSELC" -eq 0 ]; then
    echo "[$(date '+%m-%d %H:%M:%S')]无候选进入精测（快筛全失败），放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
    tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    exit 1
fi
RANKED="$V6DIR/.ranked.tmp"
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
            FAILNOTE="${FAILNOTE}样本${RUN}失败跳过"
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
    # 【v2】全样本失败（AVG=0）的候选不写榜：原实现会把 0.00MB/s 的 IP 排进结果文件
    if [ "$AVG" -le 0 ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]   精测 [$M/$FAST_TOPN] $ip：全部样本失败$FAILNOTE，剔除不写榜" >> "$LOG"
        continue
    fi
    echo "[$(date '+%m-%d %H:%M:%S')]   精测 [$M/$FAST_TOPN] $ip：${MB} MB/s（延迟 ${lat}ms ${colo}）$FAILNOTE" >> "$LOG"
    echo "$AVG $lat $ip $colo" >> "$RANKED"
done
rm -f "$FASTTMP" "$FSEL"
RCNT0=$(grep -c . "$RANKED" 2>/dev/null); [ -z "$RCNT0" ] && RCNT0=0
if [ "$RCNT0" -eq 0 ]; then
    echo "[$(date '+%m-%d %H:%M:%S')]精测无任何有效结果，放弃本轮，$RESULT_FILE 保留上次值" >> "$LOG"
    tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    exit 1
fi

# ---- 5. 排序（速度降序）→ TopN → 结果文件（$RESULT_FILE）+ 归档 ----
sort -rn "$RANKED" 2>/dev/null > "$RANKED.s" && mv "$RANKED.s" "$RANKED"

# 行格式：[ip]:443#ip-443-延迟ms-速度MB/s-地区
# 首行为生成时间戳（# 开头，外部消费方按行解析时跳过 # 注释行即可）
{
    echo "# updated: $(date '+%Y-%m-%d %H:%M:%S')"
    head -$TOPN "$RANKED" | while read sp lat ip colo; do
        mb=$(awk -v v="$sp" 'BEGIN{printf "%.2f", v/1048576}')
        echo "[$ip]:443#$ip-443-${lat}ms-${mb}MB/s-$colo"
    done
} > "$V6DIR/$RESULT_FILE"
rm -f "$RANKED"

RANKCNT=$(grep -vc '^#' "$V6DIR/$RESULT_FILE" 2>/dev/null)
[ -z "$RANKCNT" ] && RANKCNT=0

# 第 1 名信息（用于完成日志）；跳过首行时间戳注释
FIRST=$(grep -v '^#' "$V6DIR/$RESULT_FILE" 2>/dev/null | head -1)
if [ -n "$FIRST" ]; then
    BESTIP=$(echo "$FIRST" | awk -F'[][#-]' '{print $2}')
    BESTLAT=$(echo "$FIRST" | awk -F'[][#-]' '{lat=$6; sub(/ms$/, "", lat); print lat}')
    BESTMB=$(echo "$FIRST" | awk -F'[][#-]' '{mb=$7; sub(/MB\/s$/, "", mb); print mb}')
    BESTCOLO=$(echo "$FIRST" | awk -F'[][#-]' '{print $8}')
fi

STAMP=$(date "+%Y%m%d_%H%M%S")
mkdir -p "$V6DIR/history"
cp "$V6DIR/$RESULT_FILE" "$V6DIR/history/best_$STAMP.txt"
ls -t "$V6DIR"/history/best_*.txt 2>/dev/null | tail -n +$((KEEP + 1)) | while read f; do rm -f "$f"; done

NOTE=""
awk -v m="$BESTMB" -v sp="$SPEED_PASS" 'BEGIN{exit !(m+0 >= sp)}' && NOTE="（达到 ${SPEED_PASS}MB/s 标准）"
DUR=$(( $(date +%s) - START_TS ))
# 上榜机场分布（观测多样性是否生效）：如 "MAA×3 LAX×3 HKG×2 BOM×2 "
COLO_DIST=$(grep -v '^#' "$V6DIR/$RESULT_FILE" 2>/dev/null | grep -oE '\-[A-Z]{3}$' | sort | uniq -c | awk '{printf "%s×%s ", substr($2,2), $1}')
# 本轮下载流量（快筛+精测实际消耗，用于观察每轮成本；DL_RUNS/FAST_TOPN 调整后看这里）
DLMB=$(awk '{s+=$1} END{printf "%.0f", s/1048576}' "$V6DIR/.bytes" 2>/dev/null)
[ -z "$DLMB" ] && DLMB=0
rm -f "$V6DIR/.bytes"
echo "[$(date '+%m-%d %H:%M:%S')]测速完成（耗时 ${DUR}s）：最优 $BESTIP（${BESTCOLO} 延迟 ${BESTLAT}ms 实测 ${BESTMB}MB/s）$NOTE，粗筛幸存 $P1CNT 个，延迟候选 $CNT 个，快筛 $N 个，精测 $M 个，上榜 $RANKCNT 个，下载流量 ${DLMB}MB，机场分布 ${COLO_DIST}" >> "$LOG"

# ---- 6. 日志瘦身 ----
tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
