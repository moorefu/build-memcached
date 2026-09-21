#!/bin/bash
set -e

# Usage: smoke-test.sh <memcached-binary> <source-dir>
# <source-dir>: memcached 源码构建目录 (用于 scripts/memcached-tool)
#
# 冒烟测试编排: 起多组不同配置的实例, 逐一调用 smoke_test.py 做协议级断言。
# 任何一组失败即退出非零 (发布门禁)。Linux/Windows(MSYS2) 共用。
#   普通实例    -m 64 -t 4  → ASCII/二进制协议全套 + 大 value 边界 + memcached-tool
#   小内存实例  -m 16       → LRU 逐出
#   TLS 实例    -Z          → TLS 连接 set/get (自签证书, 需 openssl 命令)
#   SASL 实例   -S          → PLAIN 认证三断言
#   沙箱实例    -o drop_privileges (仅 Linux) → seccomp 下基本读写 + 可正常退出

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:?Usage: $0 <memcached-binary> <source-dir>}"
SRCDIR="${2:?Usage: $0 <memcached-binary> <source-dir>}"

log() { echo "==> $*"; }

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  PY="$(ls /opt/python/cp3*/bin/python3 2>/dev/null | head -1 || true)"
fi
[ -n "$PY" ] || { echo "错误: 找不到 python, 无法执行冒烟测试" >&2; exit 1; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;;
  *) IS_WIN=0 ;;
esac

P_MAIN=12311; P_EVICT=12312; P_TLS=12313; P_SASL=12314; P_SECC=12315
PIDS=()
LAST_PID=
# 证书/密码文件用 cwd 相对路径: 打包出的 memcached.exe(MSYS 程序)对 /tmp 等
# 绝对 MSYS 路径的解析依赖运行时挂载表, 解压即用的环境里不存在; 相对路径无歧义。
TLSREL=".mc-smoke-tls.$$"
PWDBREL=".mc-smoke-pwdb.$$"
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$PWD/$TLSREL" "$PWD/$PWDBREL"
}
trap cleanup EXIT

wait_port() {
  for _ in $(seq 1 50); do
    if "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $1), 1).close()" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  echo "错误: 端口 $1 的实例 10 秒内未就绪" >&2
  return 1
}

# start_mc <port> <memcached 额外参数...>
start_mc() {
  local port="$1"; shift
  log "启动实例 (端口 $port${*:+, 参数: $*})"
  # 输出重定向到日志文件: 既避免后台实例持有输出管道写端拖住外层管道
  # (如 | tail), 又在实例意外退出时能输出诊断信息
  local mclog="/tmp/mc-smoke-$port.log"
  rm -f "$mclog"
  if [ "$IS_WIN" = 1 ]; then
    "$BIN" -p "$port" -U 0 "$@" > "$mclog" 2>&1 &
  else
    "$BIN" -u root -p "$port" -U 0 "$@" > "$mclog" 2>&1 &
  fi
  LAST_PID=$!
  PIDS="$PIDS $LAST_PID"
  if ! wait_port "$port"; then
    echo "----- 实例日志 ($mclog) -----" >&2
    cat "$mclog" >&2 || true
    return 1
  fi
}

log "版本检查: $("$BIN" --version)"

# ---------- 普通实例: 协议全套 ----------
start_mc "$P_MAIN" -m 64 -t 4
log "冒烟: ASCII/二进制协议全套 + 大 value 边界"
"$PY" "$SCRIPT_DIR/smoke_test.py" text 127.0.0.1 "$P_MAIN"

# memcached-tool 需要 perl + URI::Escape 模块; 缺失时降级跳过(非核心验证)
if command -v perl >/dev/null 2>&1 && [ -f "$SRCDIR/scripts/memcached-tool" ]; then
  if perl -MURI::Escape -e 1 >/dev/null 2>&1; then
    log "冒烟: memcached-tool"
    perl "$SRCDIR/scripts/memcached-tool" "127.0.0.1:$P_MAIN" > /dev/null
  else
    log "跳过 memcached-tool (缺 perl URI::Escape 模块)"
  fi
fi

# ---------- 小内存实例: LRU 逐出 ----------
start_mc "$P_EVICT" -m 16
log "冒烟: LRU 逐出"
"$PY" "$SCRIPT_DIR/smoke_test.py" eviction 127.0.0.1 "$P_EVICT"

# ---------- TLS 实例 ----------
mkdir -p "$TLSREL"
OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || true)}"
[ -z "$OPENSSL_BIN" ] && OPENSSL_BIN="/tmp/deps/openssl/bin/openssl"
[ -x "$OPENSSL_BIN" ] || { echo "错误: 找不到 openssl 命令, 无法生成 TLS 测试证书" >&2; exit 1; }
# MSYS/GitBash 会把 "/CN=..." 误当 POSIX 路径转换成 Windows 路径, 精确排除该参数
MSYS2_ARG_CONV_EXCL='/CN=localhost' \
"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$TLSREL/key.pem" -out "$TLSREL/cert.pem" \
  -subj "/CN=localhost" >/dev/null 2>&1
start_mc "$P_TLS" -m 64 -Z -o "ssl_chain_cert=$TLSREL/cert.pem" -o "ssl_key=$TLSREL/key.pem"
log "冒烟: TLS"
"$PY" "$SCRIPT_DIR/smoke_test.py" tls 127.0.0.1 "$P_TLS"

# ---------- SASL 实例 ----------
printf 'testuser:testpass\n' > "$PWDBREL"
MEMCACHED_SASL_PWDB="$PWDBREL" start_mc "$P_SASL" -m 64 -S
log "冒烟: SASL PLAIN"
"$PY" "$SCRIPT_DIR/smoke_test.py" sasl 127.0.0.1 "$P_SASL"

# ---------- seccomp 沙箱实例 (仅 Linux) ----------
if [ "$IS_WIN" = 0 ]; then
  start_mc "$P_SECC" -m 64 -o drop_privileges
  log "冒烟: seccomp 沙箱 (drop_privileges)"
  "$PY" "$SCRIPT_DIR/smoke_test.py" basic 127.0.0.1 "$P_SECC"
  # 实例应能被 SIGTERM 正常终止 (exit_group 在 seccomp 白名单内)
  kill "$LAST_PID" 2>/dev/null || true
  for _ in $(seq 1 25); do
    kill -0 "$LAST_PID" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$LAST_PID" 2>/dev/null; then
    echo "错误: seccomp 实例收到 SIGTERM 后 5 秒内未退出" >&2
    exit 1
  fi
  log "seccomp 实例已正常退出"
fi

log "冒烟测试全部通过"
