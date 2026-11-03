#!/bin/sh
# ============================================================
# GitHub 结果上传子脚本（2026-11-03）
# 由总调度 run.sh 在两个栈都完成后调用，也可手动单独执行：
#   sh githubpush.sh [v6退出码] [v4退出码]
#   - 退出码为 0 才上传对应栈的结果；99 = 该栈已被开关关闭
#   - 不带参数调用时视为两个栈都成功，仅检查结果文件是否存在
# 上传目标仓库与 token 均从 /data/cfst/config.txt 读取
# 通道策略：先直连 api.github.com，网络层失败自动改走
#           config.txt 中 GH_PROXY_PORT 指定的本机代理重试
# 上传失败只记日志，不影响本地结果
# 外部调用：raw.githubusercontent.com/<GH_REPO>/main/<V6_RESULT_FILE>
#           raw.githubusercontent.com/<GH_REPO>/main/<V4_RESULT_FILE>
# ============================================================
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

DIR=/data/cfst
cd "$DIR" || exit 1
LOG="$DIR/run.log"

# 配置加载（含语法校验，无配置或配置损坏直接退出）
if [ ! -f "$DIR/config.txt" ] || ! sh -n "$DIR/config.txt" 2>/dev/null; then
    echo "[$(date '+%m-%d %H:%M:%S')]GH push 退出：config.txt 缺失或语法错误" >> "$LOG"
    exit 1
fi
. "$DIR/config.txt"

# 顶级开关：未开启上传时静默跳过
if [ "$GH_UPLOAD_ENABLE" != "1" ]; then
    echo "[$(date '+%m-%d %H:%M:%S')]GH 上传已关闭（GH_UPLOAD_ENABLE=0），跳过" >> "$LOG"
    exit 0
fi

V6RC="${1:-0}"          # v6 子脚本退出码（总调度传入；99=已关闭）
V4RC="${2:-0}"          # v4 子脚本退出码（99=已关闭）
PROXY_PORT="$GH_PROXY_PORT"
GH_CONNECT_TIMEOUT="${GH_CONNECT_TIMEOUT:-6}"
GH_MAXTIME="${GH_MAXTIME:-25}"
GH_PURGE_TIMEOUT="${GH_PURGE_TIMEOUT:-15}"
STATUS_FILE="${STATUS_FILE:-status.txt}"
GH_RESP="$DIR/.gh_resp"

# GitHub API 请求封装：直连 → 失败走代理，各试一次
# 用法：gh_req <curl 参数...>；副作用全局变量：GH_CODE=HTTP码，GH_VIA=direct|proxy，响应体在 $GH_RESP
gh_req() {
    for GH_VIA in direct proxy; do
        if [ "$GH_VIA" = "proxy" ]; then
            PX="-x http://127.0.0.1:$PROXY_PORT"
        else
            PX=""
        fi
        GH_CODE=$(curl -sk $PX --connect-timeout "$GH_CONNECT_TIMEOUT" --max-time "$GH_MAXTIME" -H "Authorization: Bearer $GH_TOKEN" \
                  -o "$GH_RESP" -w '%{http_code}' "$@" 2>/dev/null)
        [ "$?" -eq 0 ] && [ "$GH_CODE" != "000" ] && return 0
    done
    return 1
}

gh_put() {  # 参数1 = 本地文件 参数2 = 仓库内路径 参数3 = 提交说明 参数4 = 去重标记文件
    [ -s "$1" ] || { echo "[$(date '+%m-%d %H:%M:%S')]GH 上传跳过：$1 不存在或为空" >> "$LOG"; return 1; }
    # 去重：比较除首行时间戳外的内容哈希，与上次成功上传一致则跳过提交（减少 commit 噪音）
    MD5NOW=$(tail -n +2 "$1" 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ -n "$MD5NOW" ] && [ -f "$4" ] && [ "$(cat "$4" 2>/dev/null)" = "$MD5NOW" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')]GH 上传跳过：$2 内容未变" >> "$LOG"
        return 0
    fi
    API="https://api.github.com/repos/$GH_REPO/contents/$2"
    CONTENT=$(base64 "$1" 2>/dev/null | tr -d '\n')
    [ -n "$CONTENT" ] || return 1
    # 取现有文件 sha（请求失败或文件不存在则为空 = 按新建处理）
    SHA=""
    if gh_req "$API"; then
        SHA=$(awk -F'"' '/"sha"/{print $4; exit}' "$GH_RESP" 2>/dev/null)
    fi
    if [ -n "$SHA" ]; then
        BODY="{\"message\":\"$3\",\"content\":\"$CONTENT\",\"sha\":\"$SHA\"}"
    else
        BODY="{\"message\":\"$3\",\"content\":\"$CONTENT\"}"
    fi
    gh_req -X PUT -d "$BODY" "$API"
    rm -f "$GH_RESP"
    case "$GH_CODE" in
        200|201)
            echo "[$(date '+%m-%d %H:%M:%S')]GH 上传成功：$2（$GH_CODE，$GH_VIA）" >> "$LOG"
            [ -n "$MD5NOW" ] && [ -n "$4" ] && echo "$MD5NOW" > "$4"
            # 刷新 jsDelivr CDN 缓存，保证镜像地址也能尽快读到最新内容（失败仅记日志）
            # 响应形如 {"status":"finished","paths":{...}}，按 finished 判定成功
            JPURGE=$(curl -sk --connect-timeout "$GH_CONNECT_TIMEOUT" --max-time "$GH_PURGE_TIMEOUT" "https://purge.jsdelivr.net/gh/$GH_REPO@main/$2" 2>/dev/null)
            case "$JPURGE" in
                *'"status": "finished"'*|*'"status":"finished"'*) echo "[$(date '+%m-%d %H:%M:%S')]jsDelivr 缓存已刷新：$2" >> "$LOG" ;;
                *) echo "[$(date '+%m-%d %H:%M:%S')]jsDelivr 缓存刷新失败（不影响结果，raw 地址为权威源）" >> "$LOG" ;;
            esac
            return 0 ;;
        *) echo "[$(date '+%m-%d %H:%M:%S')]GH 上传失败：$2（$GH_CODE），不影响本地结果" >> "$LOG"; return 1 ;;
    esac
}

UPNOTE=""
# ---- v6 结果上传 ----
if [ "$V6RC" = "99" ]; then
    UPNOTE="${UPNOTE}v6✗(已关闭)"
elif [ "$V6RC" = "0" ] && [ -s "$DIR/v6/$V6_RESULT_FILE" ]; then
    gh_put "$DIR/v6/$V6_RESULT_FILE" "$V6_RESULT_FILE" "cfst v6 bestip top$V6_TOPN $(date '+%m-%d %H:%M')" "$DIR/.push_v6.md5" && UPNOTE="${UPNOTE}v6✓"
else
    UPNOTE="${UPNOTE}v6✗(失败/无结果)"
fi
# ---- v4 结果上传 ----
if [ "$V4RC" = "99" ]; then
    UPNOTE="${UPNOTE} v4✗(已关闭)"
elif [ "$V4RC" = "0" ] && [ -s "$DIR/v4/$V4_RESULT_FILE" ]; then
    gh_put "$DIR/v4/$V4_RESULT_FILE" "$V4_RESULT_FILE" "cfst v4 bestip top$V4_TOPN $(date '+%m-%d %H:%M')" "$DIR/.push_v4.md5" && UPNOTE="${UPNOTE} v4✓"
else
    UPNOTE="${UPNOTE} v4✗(失败/无结果)"
fi

# ---- 状态文件上传：一次往返即可掌握整套系统健康状态 ----
# 内容 = 两栈各自的"测速完成/放弃原因"+"池构建摘要（学习段/学习复测是否生效）"+ 本轮上传结果
ST_V6=$(grep -E '测速完成|放弃本轮|延迟测速连续|池为空' "$DIR/v6/run.log" 2>/dev/null | tail -1)
ST_V4=$(grep -E '测速完成|放弃本轮|延迟测速连续|池为空' "$DIR/v4/run.log" 2>/dev/null | tail -1)
PB_V6=$(grep -E '池构建' "$DIR/v6/run.log" 2>/dev/null | tail -1 | sed 's/^\[[^]]*\]//')
PB_V4=$(grep -E '池构建' "$DIR/v4/run.log" 2>/dev/null | tail -1 | sed 's/^\[[^]]*\]//')
{
    echo "# updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "v6(rc=${V6RC}): ${ST_V6:-本轮无关键日志}"
    echo "   ${PB_V6:-无池构建记录}"
    echo "v4(rc=${V4RC}): ${ST_V4:-本轮无关键日志}"
    echo "   ${PB_V4:-无池构建记录}"
    echo "gh: $UPNOTE"
} > "$DIR/.status.txt"
gh_put "$DIR/.status.txt" "$STATUS_FILE" "cfst status $(date '+%m-%d %H:%M')" "" \
    && UPNOTE="${UPNOTE} status✓"

echo "[$(date '+%m-%d %H:%M:%S')]GH push 完成（$UPNOTE）" >> "$LOG"
exit 0
