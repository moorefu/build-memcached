#!/bin/bash
set -e

# Usage: benchmark.sh <memcached-binary> [结果文件]
#
# 用 mc-crusher (memcached 官方压测工具) 对构建产物做基准测试, 结果写入
# markdown 文件 (供 CI 上传 artifact / 拼入 Release 说明)。
#   - 需要系统 libevent 头文件 (Linux: yum install libevent-devel; MSYS2 已含)
#   - 工具获取/编译失败会直接失败退出: CI 环境这属于环境回归, 应当暴露
#   - 吞吐数字不作发布门槛, 仅设极宽的"残废检测"下限 (MIN_OPS),
#     防止构建配置错误产出性能崩坏的二进制还照常发布
# 结果为共享 runner 上的参考值, 波动大, 仅供版本间粗对比。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 转绝对路径: 后续会 cd 到工作目录编译 mc-crusher, 相对路径将失效
BIN="$(cd "$(dirname "${1:?Usage: $0 <memcached-binary> [结果文件]}")" && pwd)/$(basename "${1:?Usage: $0 <memcached-binary> [结果文件]}")"
PLATFORM="$(uname -s | cut -d_ -f1 | tr 'A-Z' 'a-z')"
ARCH="$(uname -m)"
OUT="${2:-$SCRIPT_DIR/benchmark-$PLATFORM-$ARCH.txt}"

CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/cache}"
WORK=/tmp/mc-bench
NPROC=$(nproc)
PORT=12321
DUR=10          # 每场景压测秒数
# 残废检测下限 (ops/s): 仅用于拦截"构建配置错误导致性能崩坏"(那类产物
# 只有百级 ops/s), 不作性能门槛。取 3000 为 Linux 正常吞吐(数万)的零头,
# 同时给 Windows MSYS 运行时(约 1 万上下, 共享 runner 波动大)留足余量
MIN_OPS=3000

log() { echo "==> $*" >&2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;;
  *) IS_WIN=0 ;;
esac

mkdir -p "$CACHE_DIR" "$WORK"
rm -rf "$WORK"/mc-crusher-master

# ---------- 获取并编译 mc-crusher ----------
download() {
  local url="$1" out="$2"
  if [ -s "$CACHE_DIR/$out" ]; then
    log "缓存命中: $CACHE_DIR/$out"
    cp "$CACHE_DIR/$out" "$out"
  else
    log "下载 $url"
    curl -fsSL "$url" -o "$CACHE_DIR/$out" && cp "$CACHE_DIR/$out" "$out"
  fi
}

log "获取 mc-crusher"
cd "$WORK"
download "https://codeload.github.com/memcached/mc-crusher/tar.gz/refs/heads/master" \
  "mc-crusher-master.tar.gz"
tar -xzf mc-crusher-master.tar.gz
cd mc-crusher-master
log "编译 mc-crusher"
if [ "$IS_WIN" = 1 ]; then
  # mc-crusher 是纯 Unix 代码, 须用 msys gcc (mingw gcc 缺 sys/socket.h 等 POSIX 头)
  PATH="/usr/bin:$PATH" make >/dev/null
else
  make >/dev/null
fi
[ -x ./mc-crusher ] || { echo "错误: mc-crusher 编译产物缺失" >&2; exit 1; }

# ---------- 启动被测实例 ----------
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  PY="$(ls /opt/python/cp3*/bin/python3 2>/dev/null | head -1 || true)"
fi
[ -n "$PY" ] || { echo "错误: 找不到 python, 无法采样" >&2; exit 1; }

MC_PID=
cleanup() { [ -z "$MC_PID" ] || kill "$MC_PID" 2>/dev/null || true; }
trap cleanup EXIT

log "启动被测实例 (端口 $PORT)"
if [ "$IS_WIN" = 1 ]; then
  "$BIN" -p "$PORT" -U 0 -m 512 -t 4 > /dev/null 2>&1 &
else
  "$BIN" -u root -p "$PORT" -U 0 -m 512 -t 4 > /dev/null 2>&1 &
fi
MC_PID=$!
READY=0
for _ in $(seq 1 50); do
  if "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 1).close()" 2>/dev/null; then READY=1; break; fi
  # 若探测到端口却不是本进程 (端口被残留实例占用), 本进程已退出 -> 校验存活
  if ! kill -0 "$MC_PID" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ "$READY" != 1 ] || ! kill -0 "$MC_PID" 2>/dev/null; then
  echo "错误: 被测实例未就绪 (端口 $PORT 可能被残留实例占用, 进程可能已退出)" >&2
  exit 1
fi

# 场景配置: get 场景先用同 key 前缀的 set 灌满数据保证全命中
make_conf() { # <文件> <send> <key_prefix> [value_size]
  local f="$WORK/$1" prefix="$3" extra=""
  [ "$2" = ascii_set ] && extra=",value_size=${4:-64}"
  echo "send=$2,recv=blind_read,conns=4,thread=2,key_prefix=$prefix,key_count=100000,key_prealloc=1$extra" > "$f"
}
make_conf warm64.conf  ascii_set bg 64
make_conf get64.conf   ascii_get bg
make_conf set64.conf   ascii_set bs 64
make_conf warm1k.conf  ascii_set kg 1024
make_conf get1k.conf   ascii_get kg
make_conf set1k.conf   ascii_set ks 1024

# run_scenario <显示名> <conf> <stats计数器> <预热conf|空>
run_scenario() {
  local name="$1" conf="$2" stat="$3" warm="$4"
  if [ -n "$warm" ]; then
    log "预热 $name"
    ./mc-crusher --conf "$WORK/$warm" --port "$PORT" --timeout 8 >/dev/null 2>&1 || true
  fi
  log "场景 $name (${DUR}s)"
  "$PY" "$SCRIPT_DIR/bench_sample.py" "$PORT" "$DUR" "$stat" > "$WORK/rate.tmp" &
  local sampler=$!
  ./mc-crusher --conf "$WORK/$conf" --port "$PORT" --timeout "$DUR" >/dev/null 2>&1
  wait "$sampler"
  local rate
  rate=$(cat "$WORK/rate.tmp")
  echo "$name: $rate ops/s" >&2
  echo "$rate"
}

RESULTS=""
MIN_SEEN=

add_result() { # <显示名> <速率>
  RESULTS="$RESULTS
| $1 | $2 |"
  if [ -z "$MIN_SEEN" ] || [ "$2" -lt "$MIN_SEEN" ]; then MIN_SEEN=$2; fi
}

add_result "get 64B (预热全命中)" "$(run_scenario "get64"  get64.conf  cmd_get  warm64.conf)"
add_result "set 64B"              "$(run_scenario "set64"  set64.conf  cmd_set  '')"
add_result "get 1KB (预热全命中)"  "$(run_scenario "get1k"  get1k.conf  cmd_get  warm1k.conf)"
add_result "set 1KB"              "$(run_scenario "set1k"  set1k.conf  cmd_set  '')"

kill "$MC_PID" 2>/dev/null || true
MC_PID=

# ---------- 输出结果 ----------
log "写入 $OUT"
{
  echo "### $PLATFORM-$ARCH"
  echo
  echo "- 压测: mc-crusher, 每场景 ${DUR}s, conns=4/thread=2, value 64B/1KB, nproc=$NPROC"
  echo "- 数字来自共享 CI runner, 波动较大, 仅供版本间粗对比, 不是严格基准"
  echo
  echo "| 场景 | 吞吐 (ops/s) |"
  echo "| --- | --- |"
  echo "$RESULTS"
} > "$OUT"
cat "$OUT"

if [ "$MIN_SEEN" -lt "$MIN_OPS" ]; then
  echo "错误: 最低吞吐 ${MIN_SEEN} ops/s 低于残废检测下限 ${MIN_OPS} ops/s, 构建产物疑似异常" >&2
  exit 1
fi

log "基准测试完成 (最低 ${MIN_SEEN} ops/s)"
