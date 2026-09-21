#!/bin/bash
set -e

# Usage: ./build-memcached-win.sh <version> [arch]
# Example: ./build-memcached-win.sh 1.6.45 x86_64
#
# 在 MSYS2 的 MINGW64 环境运行 (依赖来自 msys2 系统包, 版本由 pacman 管理):
#   pacman -S --needed base-devel gcc gperf perl python zip curl \
#                     libevent libevent-devel libopenssl openssl-devel \
#                     libsasl libsasl-devel
#
# 说明: memcached 是纯 Unix 代码, mingw64 缺 sys/socket.h 等 POSIX 头,
# 原生移植需要大改(参考 jefyt/memcached-windows, 代价是不支持 SASL)。
# 本脚本用 MSYS 运行时工具链(CC=/usr/bin/gcc)构建, 源码零改动、SASL/TLS 全可用,
# 代价是 zip 内附带 msys-2.0.dll 等运行时 DLL(打包进 bin/, 解压即用)。
# 依赖库(libevent/openssl 3.x/cyrus-sasl)用 msys2 系统包版本, 不由参数控制。
#
# memcached 取官方发布包(memcached.org/files, 自带 configure)。
# 注意: msys2 的 autoconf 2.73 无法处理 memcached 的 configure.ac
# ("undefined or overquoted macro"), 发布包自带 configure 正好绕开 autotools。

VERSION="${1:?Usage: $0 <version> [arch]}"
ARCH="${2:-x86_64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "==> $*"; }

CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/cache}"
mkdir -p "$CACHE_DIR"
download() {
  local url="$1"
  local out="${2:-$(basename "$url")}"
  if [ -s "$CACHE_DIR/$out" ]; then
    echo "==> Cache hit: $CACHE_DIR/$out"
    cp "$CACHE_DIR/$out" "$out"
  else
    echo "==> Downloading $url"
    curl -fsSL "$url" -o "$CACHE_DIR/$out" && cp "$CACHE_DIR/$out" "$out"
  fi
}

log "构建 memcached $VERSION for Windows (MSYS2 运行时)"

# 前置检查
for cmd in curl tar patch make zip python ldd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "错误: 需要 $cmd (pacman -S 安装)"; exit 1; }
done

download "https://memcached.org/files/memcached-$VERSION.tar.gz"
rm -rf "memcached-$VERSION"
tar -xzf "memcached-$VERSION.tar.gz"
cd "memcached-$VERSION"

log "应用便携补丁 patches/sasl_defs-portable.patch"
patch -p1 --fuzz=3 < "$SCRIPT_DIR/patches/sasl_defs-portable.patch"

# 显式指向 MSYS gcc (MINGW64 环境下默认 gcc 是 mingw 编译器, 缺 POSIX 头)
./configure \
  CC=/usr/bin/gcc \
  --enable-tls \
  --enable-sasl \
  --enable-sasl-pwdb
make -j$(nproc)

log "验证"
./memcached.exe --version

# SASL PLAIN 功能测试 (python)
printf 'testuser:testpass\n' > /tmp/pwdb
MEMCACHED_SASL_PWDB=/tmp/pwdb ./memcached -S -p 11311 -U 0 -m 64 -v > /tmp/mc-win.log 2>&1 &
MC_PID=$!
trap 'kill $MC_PID 2>/dev/null || true' EXIT
sleep 2
python - <<'PYEOF'
import socket, struct, sys

HOST, PORT = '127.0.0.1', 11311

def send_pkt(s, opcode, key=b'', val=b''):
    total = len(key) + len(val)
    hdr = struct.pack('!BBHBBHIIQ', 0x80, opcode, len(key), 0, 0, 0, total, 0, 0)
    s.sendall(hdr + key + val)

def recv_pkt(s):
    hdr = b''
    while len(hdr) < 24:
        c = s.recv(24 - len(hdr))
        if not c: raise IOError('connection closed')
        hdr += c
    magic, op, keyl, extl, dtype, status, rest, opaque, cas = struct.unpack('!BBHBBHIIQ', hdr)
    body = b''
    while len(body) < rest:
        c = s.recv(rest - len(body))
        if not c: raise IOError('connection closed')
        body += c
    return status, body

s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x20)
status, body = recv_pkt(s)
if status != 0 or b'PLAIN' not in body.split():
    sys.exit('FAIL: PLAIN mechanism missing')
s.close()

s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x21, b'PLAIN', b'\x00testuser\x00testpass')
status, body = recv_pkt(s)
if status != 0:
    sys.exit('FAIL: PLAIN auth failed with correct password')
s.close()

s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x21, b'PLAIN', b'\x00testuser\x00wrongpass')
status, body = recv_pkt(s)
if status == 0:
    sys.exit('FAIL: wrong password was accepted')
s.close()
print('SASL PLAIN: all tests passed')
PYEOF
kill $MC_PID
trap - EXIT

# ---------- 打包 ----------
log "打包"
DIST="memcached-$VERSION-windows-$ARCH-msys2"
rm -rf "$DIST" "$DIST.zip" "$DIST.zip.sha256"
mkdir -p "$DIST/bin" "$DIST/include" "$DIST/share/doc" "$DIST/share/sasl2"
cp memcached.exe "$DIST/bin/"
# 打包 msys 运行时依赖 DLL 到 bin/ (exe 同目录自动加载), 解压即用
for dll in $(ldd memcached.exe | grep -oE '/usr/bin/[^ ]+\.dll' | sort -u); do
  cp "$dll" "$DIST/bin/"
done
# SASL 机制插件(可选; PLAIN 已内置于 msys libsasl2)
cp /usr/lib/sasl2/*.dll "$DIST/share/sasl2/" 2>/dev/null || true
cp COPYING "$DIST/share/doc/LICENSE"
cat > "$DIST/share/doc/README.txt" <<EOF
memcached $VERSION Windows 版 (x86_64, MSYS2 运行时)

标准前缀布局 (bin/include/share), 自带运行所需全部 DLL
(msys-2.0.dll 等位于 bin/), 解压即可运行, 无需安装 MSYS2。

用法:
  bin/memcached.exe -p 11211 -m 64

SASL 认证 (-S):
  echo testuser:testpass > pwdb.txt
  MEMCACHED_SASL_PWDB=pwdb.txt bin/memcached.exe -S
  (内置 PLAIN 机制; 如需 SCRAM/GSSAPI 等机制, 设置环境变量
   SASL_PATH 指向本包 share/sasl2 目录)

TLS: 完整支持 (openssl 3.x 随包提供)。

注意: 本构建基于 MSYS2 POSIX 兼容运行时, 性能低于原生 Linux 构建,
适合开发/测试/轻量场景; 生产环境建议使用 Linux 构建。

目录结构:
  bin/     memcached.exe 主程序 + msys 运行时 DLL
  include/ 占位 (memcached 无对外 API 头文件)
  share/   文档(doc), SASL 机制插件(sasl2, 可选)
EOF
zip -q -r "$DIST.zip" "$DIST"
sha256sum "$DIST.zip" > "$DIST.zip.sha256"

mv "$DIST.zip" "$DIST.zip.sha256" "$SCRIPT_DIR/"
log "完成: $SCRIPT_DIR/$DIST.zip"
