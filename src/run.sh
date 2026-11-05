#!/bin/sh
# ============================================================
# CloudflareSpeedTest 双栈总调度（2026-11-03）
# cron 定时入口。职责：
#   1. 加载 config.txt（所有开关与参数统一在此文件维护）
#   2. 按 V6_ENABLE / V4_ENABLE 开关决定是否执行对应栈的测速子脚本
#   3. 两个栈都处理完后调用 githubpush.sh 统一上传（其内部校验
#      GH_UPLOAD_ENABLE 开关，关闭则静默跳过）
#
# 【文件布局】
#   /data/cfst/run.sh          本脚本（总调度，日志 run.log）
#   /data/cfst/config.txt      统一配置（开关/参数/token，600 权限）
#   /data/cfst/githubpush.sh   GitHub 上传独立子脚本
#   /data/cfst/run_v6.sh       IPv6 子脚本（独立可跑，只写本地结果）
#   /data/cfst/run_v4.sh       IPv4 子脚本（独立可跑，只写本地结果）
#   /data/cfst/v6/             IPv6 数据独立目录（池/锁/日志/history，不含结果文件）
#   /data/cfst/v4/             IPv4 数据独立目录（同上）
#   /data/cfst/<RESULT_FILE>   两栈合并的结果文件（v6 先写并带头部，v4 追加；每轮开始清空）
#
# 【退出码约定】子脚本退出码：0=成功 1=失败 99=该栈被开关关闭（不上传）
# 【注意】本机 busybox v1.25.1 的 timeout 只支持 -t 秒 语法（GNU 的
#   `timeout SECS PROG` 会把 SECS 当命令名，报 127 秒退——15:17 前所有
#   cron 轮次均因此失败，勿改回）
# ============================================================
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

DIR=/data/cfst
cd "$DIR" || exit 1

LOG="$DIR/run.log"
START_TS=$(date +%s)

# ---- 0. 配置加载（含语法校验：配置被改坏时拒绝启动而非带病运行） ----
if [ ! -f "$DIR/config.txt" ] || ! sh -n "$DIR/config.txt" 2>/dev/null; then
    echo "[$(date '+%m-%d %H:%M:%S')]总调度退出：config.txt 缺失或语法错误" >> "$LOG"
    exit 1
fi
. "$DIR/config.txt"
LOG_KEEP_LINES="${LOG_KEEP_LINES:-500}"
RESULT_FILE="${RESULT_FILE:-best_ip_dianxin.txt}"

# 每轮开始清空合并结果文件：v6 会重新写入（截断+头部），v4 追加自己的条目。
# 这样两栈任意组合都只保留"本轮"的结果，不会残留上一轮的内容。
rm -f "$DIR/$RESULT_FILE"

# ---- 0.5 总调度锁（防止总流程重入；子脚本另有各自锁） ----
LOCK="$DIR/.master.lock"
if [ -f "$LOCK" ]; then
    OLD_PID=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null \
       && grep -q "cfst/run.sh" "/proc/$OLD_PID/cmdline" 2>/dev/null; then
        exit 0   # 上一轮总调度还在跑，本轮让位
    fi
    echo "[$(date '+%m-%d %H:%M:%S')]总调度锁残留（PID ${OLD_PID:-空} 已不存在或非本脚本），接管" >> "$LOG"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

echo "[$(date '+%m-%d %H:%M:%S')]===== 总调度开始（v6 开关 $V6_ENABLE / v4 开关 $V4_ENABLE / GitHub 上传 $GH_UPLOAD_ENABLE） =====" >> "$LOG"

# ---- 1. IPv6 测速（受 V6_ENABLE 开关控制；timeout 防止单轮无限挂起） ----
if [ "$V6_ENABLE" = "1" ]; then
    timeout -t "$V6_TIMEUP" sh "$DIR/run_v6.sh"
    V6RC=$?
    [ "$V6RC" = "124" ] && echo "[$(date '+%m-%d %H:%M:%S')]v6 子脚本超过 ${V6_TIMEUP}s 被 timeout 强制结束" >> "$LOG"
    echo "[$(date '+%m-%d %H:%M:%S')]v6 子脚本结束（退出码 $V6RC）" >> "$LOG"
else
    V6RC=99
    echo "[$(date '+%m-%d %H:%M:%S')]v6 已关闭（V6_ENABLE=0），跳过" >> "$LOG"
fi

# ---- 2. IPv4 测速（受 V4_ENABLE 开关控制；timeout 防止单轮无限挂起） ----
if [ "$V4_ENABLE" = "1" ]; then
    timeout -t "$V4_TIMEUP" sh "$DIR/run_v4.sh"
    V4RC=$?
    [ "$V4RC" = "124" ] && echo "[$(date '+%m-%d %H:%M:%S')]v4 子脚本超过 ${V4_TIMEUP}s 被 timeout 强制结束" >> "$LOG"
    echo "[$(date '+%m-%d %H:%M:%S')]v4 子脚本结束（退出码 $V4RC）" >> "$LOG"
else
    V4RC=99
    echo "[$(date '+%m-%d %H:%M:%S')]v4 已关闭（V4_ENABLE=0），跳过" >> "$LOG"
fi

# ---- 3. 统一上传 GitHub（独立子脚本，内部校验 GH_UPLOAD_ENABLE 与退出码） ----
sh "$DIR/githubpush.sh" "$V6RC" "$V4RC"

DUR=$(( $(date +%s) - START_TS ))
echo "[$(date '+%m-%d %H:%M:%S')]总调度完成（耗时 ${DUR}s，v6 退出码 $V6RC / v4 退出码 $V4RC）" >> "$LOG"

# ---- 4. 日志瘦身 ----
tail -"$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
