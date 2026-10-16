#!/bin/sh
# Ubuntu/Linux: bash bot.sh start|record|stop|status|logs
# start defaults to LIVE SNDK / lighter-rh. stop does NOT close positions.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
LOG_DIR="$ROOT/logs"
PID_FILE="$LOG_DIR/bot.pid"
LOG_FILE="$LOG_DIR/background.log"

die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
用法（Ubuntu/Linux）：
  bash bot.sh start                 后台实盘：SNDK / lighter-rh
  bash bot.sh record                后台仅采集，不下单
  bash bot.sh start SYMBOL HEDGE    指定交易组合
  bash bot.sh record SYMBOL HEDGE   指定采集组合，不下单
  bash bot.sh status               查看进程状态
  bash bot.sh logs                 跟踪日志，Ctrl+C 只退出日志
  bash bot.sh stop                 正常停止，不会自动平仓
  bash bot.sh help                 查看帮助

start/record 可省略 SYMBOL 和 HEDGE，默认 SNDK / lighter-rh。
HEDGE 支持 lighter、lighter-rh、tradexyz。
使用项目中的 config.yaml 和 .env；已导出的环境变量优先于 .env。
Python 查找顺序：.venv/bin/python、venv/bin/python、PATH 中的 python3。
固定使用 --no-dashboard，日志追加到 logs/background.log。
SSH 断开后继续运行；服务器重启或程序退出后不会自动重启。
HELP
}

ACTION=${1:-help}
case "$ACTION" in
    help|-h|--help) usage; exit 0 ;;
    start|record|stop|status|logs) ;;
    *) usage; exit 2 ;;
esac
[ "$(uname -s)" = Linux ] || die '此脚本用于 Ubuntu/Linux 服务器。'

if [ "$ACTION" = logs ]; then
    [ -f "$LOG_FILE" ] || die "尚无日志：$LOG_FILE"
    exec tail -n 50 -F "$LOG_FILE"
fi

command -v flock >/dev/null 2>&1 || die '缺少 flock，请安装 Ubuntu 的 util-linux 包。'
mkdir -p "$LOG_DIR"
# Serialize management commands. The bot must not inherit this control lock.
exec 9>"$LOG_DIR/.bot-control.lock"
flock -n 9 || die '另一个启动/停止命令正在执行，请稍后重试。'
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)

process_start() {
    # After removing PID and comm, starttime (field 22) becomes field 20.
    # comm can contain spaces or parentheses; match through the final ') '.
    awk '{sub(/^.*\) /, ""); if ($1 == "Z" || $1 == "X") exit 1; print $20}' \
        "/proc/$1/stat" 2>/dev/null
}

is_bot() {
    executable=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
    case "${executable##*/}" in python*|pypy*) ;; *) return 1 ;; esac
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' '\n' <"/proc/$1/cmdline" | grep -Fxq -- "$ROOT/main.py" && return 0
    [ "$(readlink "/proc/$1/cwd" 2>/dev/null)" = "$ROOT" ] || return 1
    tr '\000' '\n' <"/proc/$1/cmdline" | grep -Exq '(\./)?main\.py'
}

managed_alive() {
    [ -f "$PID_FILE" ] || return 1
    read -r PID START BOOT <"$PID_FILE" || return 1
    case "$PID" in ''|*[!0-9]*) return 1 ;; esac
    [ "$PID" -gt 1 ] || return 1
    [ "$BOOT" = "$BOOT_ID" ] || return 1
    [ "$(process_start "$PID")" = "$START" ] || return 1
    is_bot "$PID"
}

other_bot() {
    for proc in /proc/[0-9]*; do
        candidate=${proc##*/}
        if is_bot "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

case "$ACTION" in
    status)
        if managed_alive; then
            printf '进程运行中，PID：%s\n日志：%s\n' "$PID" "$LOG_FILE"
            printf '%s\n' '进程存活不代表正在交易；初始化、HALTED 或错误状态请查日志。'
        elif other=$(other_bot); then
            printf '发现其他启动方式运行的项目进程：%s。请在原终端或管理器操作。\n' "$other"
        else
            printf '%s\n' '未运行。已有交易所仓位不会自动平仓。'
        fi
        ;;
    stop)
        if ! managed_alive; then
            if other=$(other_bot); then
                die "进程 $other 与本脚本记录不匹配，未发送信号。请在原终端或管理器中停止。"
            fi
            printf '%s\n' '后台实例未运行，无需停止。'
            exit 0
        fi
        printf '正在请求 PID %s 正常退出；不会自动平仓。\n' "$PID"
        # Verify PID identity again immediately before signaling.
        managed_alive || die '进程身份已变化，未发送信号，请重新查看状态。'
        kill -TERM "$PID" || die '停止信号发送失败，请检查进程状态。'
        remaining=60
        while managed_alive; do
            [ "$remaining" -gt 0 ] || die '等待 60 秒后进程仍在运行。未强制终止，请检查日志，不要重复启动。'
            sleep 1
            remaining=$((remaining - 1))
        done
        rm -f -- "$PID_FILE"
        printf '%s\n' '后台实例已停止，请核对交易所剩余持仓。'
        ;;
    start|record)
        [ "$#" -le 3 ] || die '用法：bash bot.sh start|record [SYMBOL] [HEDGE]'
        if managed_alive; then
            printf '已经运行，PID：%s。未重复启动；切换模式需要先 stop。\n' "$PID"
            exit 0
        fi
        if other=$(other_bot); then
            die "本项目已有进程 $other。请先停止原来的前台/tmux/nohup 实例，避免重复交易。"
        fi
        SYMBOL=${2:-SNDK}
        HEDGE=${3:-lighter-rh}
        [ -n "$SYMBOL" ] || die 'SYMBOL 不能为空。'
        case "$HEDGE" in lighter|lighter-rh|tradexyz) ;; *) die 'HEDGE 必须为 lighter、lighter-rh 或 tradexyz。' ;; esac
        [ -f "$ROOT/config.yaml" ] || die "找不到 $ROOT/config.yaml，请先配置。"
        if [ -x "$ROOT/.venv/bin/python" ]; then
            PYTHON="$ROOT/.venv/bin/python"
        elif [ -x "$ROOT/venv/bin/python" ]; then
            PYTHON="$ROOT/venv/bin/python"
        else
            PYTHON=$(command -v python3) || die '找不到 python3。'
        fi
        command -v nohup >/dev/null 2>&1 || die '找不到 nohup。'
        # Held by the child for its lifetime, including if this launcher exits
        # before it can save the PID. Close in parent; never explicitly unlock.
        exec 8>"$LOG_DIR/.bot-instance.lock"
        flock -n 8 || die '已有后台实例持有运行锁，未启动新进程。'
        cd "$ROOT"
        set -- "$PYTHON" -u "$ROOT/main.py" --symbol "$SYMBOL" --hedge "$HEDGE" \
            --config "$ROOT/config.yaml" --env-file "$ROOT/.env" --no-dashboard
        if [ "$ACTION" = record ]; then
            set -- "$@" --record-only
            MODE=RECORD-ONLY
        else
            MODE=LIVE
            printf '%s\n' '启动实盘：满足条件将发送真实订单。'
        fi
        printf '\n--- %s %s %s / %s ---\n' "$(date '+%F %T')" "$MODE" "$SYMBOL" "$HEDGE" >>"$LOG_FILE"
        nohup "$@" </dev/null >>"$LOG_FILE" 2>&1 9>&- &
        PID=$!
        START=$(process_start "$PID") || die "启动进程已退出，请查看 $LOG_FILE"
        printf '%s %s %s\n' "$PID" "$START" "$BOOT_ID" >"$PID_FILE.tmp"
        mv -f -- "$PID_FILE.tmp" "$PID_FILE"
        exec 8>&-
        sleep 2
        if ! managed_alive; then
            die "启动后进程已退出，请用 bash bot.sh logs 查看原因。日志：$LOG_FILE"
        fi
        printf '后台进程已启动：%s，%s / %s，PID %s\n' "$MODE" "$SYMBOL" "$HEDGE" "$PID"
        printf '日志：%s\n' "$LOG_FILE"
        printf '%s\n' '初始化是否成功请查看日志。可以断开 SSH；服务器重启后需重新启动。'
        ;;
esac
