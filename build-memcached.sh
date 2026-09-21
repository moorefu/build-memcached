#!/bin/bash
set -e

# Usage: ./build-memcached.sh <version> [openssl-ver] [libevent-ver] [libseccomp-ver] [cyrus-sasl-ver] [arch]
# Example: ./build-memcached.sh 1.6.45 3.5.6 2.1.12-stable 2.5.5 2.1.28 x86_64
#
# 在 manylinux2014 (glibc 2.17) 容器内运行, 构建完全便携的 memcached:
# 除 glibc 外全部静态链入二进制 (OpenSSL/libevent/libseccomp/cyrus-sasl),
# cyrus-sasl 的 PLAIN 认证机制直接编入, 目标机器无需安装任何依赖。
# 产出 memcached-<版本>-linux-glibc2.17-<架构>-openssl-<ssl版本>.tar.xz (+ .sha256),
# 包内顶层目录为纯版本名: memcached-<版本>/{bin,include,share}。
#
# memcached 取官方发布包(memcached.org/files, 自带 configure, 无需 autotools);
# 不同版本通过第一个参数指定。sasl_defs.c 的两处便携改动见 patches/。
# 注: manylinux2014 镜像自带的 yum 源(vault)在 x86_64/aarch64 均可用, 无需换源。

VERSION="${1:?Usage: $0 <version> [openssl-ver] [libevent-ver] [libseccomp-ver] [cyrus-sasl-ver] [arch]}"
OS_VER="${2:-3.5.6}"
LIBEVENT_VER="${3:-2.1.12-stable}"
LIBSECCOMP_VER="${4:-2.5.5}"
CYRUS_SASL_VER="${5:-2.1.28}"
ARCH="${6:-$(uname -m)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS=/tmp/deps
NPROC=$(nproc)

log() { echo "==> $*"; }

# 源码包缓存: cache/ 已有则直接复用(便于离线/本地构建), CI 冷启动自动下载
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

# manylinux2014: 启用 devtoolset (新版 GCC, 仍以 glibc 2.17 为链接基线)
# enable 脚本引用未定义变量, 需临时关闭 nounset
for dts in /opt/rh/devtoolset-*/enable; do
  if [ -f "$dts" ]; then set +u; . "$dts"; set -u; break; fi
done

log "安装构建工具"
yum install -y curl pkgconfig perl-core autoconf automake libtool gperf
# OpenSSL 3.x 的 Configure 额外依赖 IPC::Cmd/Text::Template/Time::Piece(epel 提供);
# EPEL7 已 EOL, 源切到阿里云 epel-archive(含 x86_64/aarch64), 只动 epel 不动基础源。
if [ "${OS_VER%%.*}" = "3" ]; then
  yum install -y epel-release
  if [ -f /etc/yum.repos.d/epel.repo ]; then
    sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
           -e 's|^#baseurl=|baseurl=|' \
           -e 's|download.fedoraproject.org/pub/epel/7|mirrors.aliyun.com/epel-archive/7|g' \
           -e 's|dl.fedoraproject.org/pub/epel/7|mirrors.aliyun.com/epel-archive/7|g' \
           /etc/yum.repos.d/epel.repo || true
  fi
  yum install -y perl-devel perl-IPC-Cmd perl-Text-Template perl-Time-Piece || true
  # OpenSSL 3.5+ 要求 Text::Template >= 1.46, EPEL7 仓库只有 1.45,
  # 不满足时从 CPAN 镜像装单文件模块兜底
  if ! perl -MText::Template -e 'exit(($Text::Template::VERSION >= 1.46) ? 0 : 1)' 2>/dev/null; then
    log "安装 Text::Template >= 1.46 (CPAN 单文件模块)"
    (
      cd /tmp
      download "https://mirrors.aliyun.com/CPAN/authors/id/M/MJ/MJD/Text-Template-1.46.tar.gz"
      tar -xzf Text-Template-1.46.tar.gz
      install -D -m 644 Text-Template-1.46/lib/Text/Template.pm \
        /usr/share/perl5/vendor_perl/Text/Template.pm
    )
  fi
fi

mkdir -p "$DEPS"
cd "$DEPS"

# ---------- 静态 OpenSSL ----------
if [ ! -f "$DEPS/openssl/lib/libssl.a" ]; then
  log "编译静态 OpenSSL $OS_VER"
  OPENSSL_URL="https://www.openssl.org/source/openssl-${OS_VER}.tar.gz"
  [ "${OS_VER%%.*}" = "3" ] && \
    OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OS_VER}/openssl-${OS_VER}.tar.gz"
  download "$OPENSSL_URL"
  tar -xzf "openssl-$OS_VER.tar.gz"
  cd "openssl-$OS_VER"
  ./Configure "linux-$ARCH" no-shared no-tests \
    --prefix="$DEPS/openssl" --openssldir="$DEPS/openssl" --libdir=lib
  make -j"$NPROC"
  make install_sw
  cd "$DEPS"
fi

# ---------- 静态 libevent ----------
if [ ! -f "$DEPS/libevent/lib/libevent.a" ]; then
  log "编译静态 libevent $LIBEVENT_VER"
  download "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz"
  tar -xzf "libevent-$LIBEVENT_VER.tar.gz"
  cd "libevent-$LIBEVENT_VER"
  ./configure --disable-shared --enable-static --prefix="$DEPS/libevent" --disable-openssl
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# ---------- 静态 libseccomp ----------
if [ ! -f "$DEPS/libseccomp/lib/libseccomp.a" ]; then
  log "编译静态 libseccomp $LIBSECCOMP_VER"
  download "https://github.com/seccomp/libseccomp/releases/download/v$LIBSECCOMP_VER/libseccomp-$LIBSECCOMP_VER.tar.gz"
  tar -xzf "libseccomp-$LIBSECCOMP_VER.tar.gz"
  cd "libseccomp-$LIBSECCOMP_VER"
  ./configure --disable-shared --enable-static --prefix="$DEPS/libseccomp"
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# ---------- 静态 cyrus-sasl (PLAIN 机制编入库内) ----------
if [ ! -f "$DEPS/cyrus-sasl/lib/libsasl2.a" ]; then
  log "编译静态 cyrus-sasl $CYRUS_SASL_VER (PLAIN 机制内置)"
  download "https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-$CYRUS_SASL_VER/cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
  tar -xzf "cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
  cd "cyrus-sasl-$CYRUS_SASL_VER"
  # 注意: 不能加 --with-pic —— dlopen.c 里的静态插件表只在非 PIC 编译时生效(#ifndef PIC),
  # 而 devtoolset 默认非 PIE, 非 PIC 静态库可以正常链入可执行文件。
  # 只保留 PLAIN/ANONYMOUS 机制, 关闭其余插件, 去掉外部数据库依赖。
  ./configure \
    --enable-static \
    --disable-shared \
    --prefix="$DEPS/cyrus-sasl" \
    --disable-sample \
    --disable-cram \
    --disable-digest \
    --disable-scram \
    --disable-otp \
    --disable-staticdlopen \
    --with-dblib=none
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# 静态插件表是否真的包含 PLAIN
if ! nm "$DEPS/cyrus-sasl/lib/libsasl2.a" 2>/dev/null | grep -q 'plain_server_plug_init'; then
  echo "错误: PLAIN 机制未被编入静态 libsasl2.a" >&2
  exit 1
fi

# ---------- memcached ----------
log "编译 memcached $VERSION"
download "https://memcached.org/files/memcached-$VERSION.tar.gz"
rm -rf "memcached-$VERSION"
tar -xzf "memcached-$VERSION.tar.gz"
cd "memcached-$VERSION"

# 官方发布包自带 configure, 无需 autogen / autotools。
# 打便携补丁: sasl_defs.c 两处改动(无配置文件不致命 + 去掉 hostname realm)
log "应用便携补丁 patches/sasl_defs-portable.patch"
patch -p1 --fuzz=3 < "$SCRIPT_DIR/patches/sasl_defs-portable.patch"

./configure \
  --with-libevent="$DEPS/libevent" \
  --with-libssl="$DEPS/openssl" \
  --enable-seccomp \
  --enable-tls \
  --enable-sasl \
  --enable-sasl-pwdb \
  CPPFLAGS="-I$DEPS/libseccomp/include -I$DEPS/cyrus-sasl/include" \
  LDFLAGS="-L$DEPS/libseccomp/lib -L$DEPS/cyrus-sasl/lib" \
  LIBS="-lpthread -ldl"
make -j"$NPROC"

# ---------- 便携性验证 ----------
log "检查动态依赖 (只允许 glibc 家族)"
ldd memcached
BAD="$(ldd memcached | awk '{print $1}' \
  | grep -vE 'linux-vdso|ld-linux|^libc\.so|^libpthread|^libdl|^libm\.so|^librt\.so|^libresolv|^libgcc_s' || true)"
if [ -n "$BAD" ]; then
  echo "错误: 存在 glibc 之外的动态依赖, 产物不便携: $BAD" >&2
  exit 1
fi

log "SASL PLAIN 认证功能测试"
PY="$(command -v python3 || command -v python2 || true)"
if [ -z "$PY" ]; then
  PY="$(ls /opt/python/cp3*/bin/python3 2>/dev/null | head -1 || true)"
fi
if [ -z "$PY" ]; then
  echo "错误: 容器内找不到 python, 无法执行 SASL 功能测试" >&2
  exit 1
fi
cat > /tmp/sasl_test.py <<'EOF'
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

# 1) list mechanisms: statically built-in PLAIN must be present
s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x20)
status, body = recv_pkt(s)
if status != 0:
    sys.exit('FAIL: list mechanisms failed, status=%d' % status)
print('mechanisms:', body.split())
if b'PLAIN' not in body.split():
    sys.exit('FAIL: PLAIN mechanism missing')
s.close()

# 2) correct credentials must authenticate
s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x21, b'PLAIN', b'\x00testuser\x00testpass')
status, body = recv_pkt(s)
print('auth(correct password) status =', status)
if status != 0:
    sys.exit('FAIL: PLAIN auth failed with correct password, status=%d' % status)
s.close()

# 3) wrong credentials must be rejected
s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x21, b'PLAIN', b'\x00testuser\x00wrongpass')
status, body = recv_pkt(s)
print('auth(wrong password) status =', status)
if status == 0:
    sys.exit('FAIL: wrong password was accepted')
s.close()
print('SASL PLAIN: all tests passed')
EOF
printf 'testuser:testpass\n' > /tmp/memcached-sasl-pwdb
MEMCACHED_SASL_PWDB=/tmp/memcached-sasl-pwdb ./memcached -S -u root -p 11311 -U 0 -m 64 -v &
MC_PID=$!
trap 'kill $MC_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if (exec 3<>/dev/tcp/127.0.0.1/11311) 2>/dev/null; then break; fi
  sleep 0.2
done
"$PY" /tmp/sasl_test.py
kill $MC_PID
trap - EXIT

# ---------- 打包 ----------
# 包内顶层目录用纯版本名 memcached-<version>, 压缩包文件名保留平台/依赖版本后缀
log "打包"
DIST="memcached-$VERSION-linux-glibc2.17-$ARCH-openssl-$OS_VER"
INNER="memcached-$VERSION"
rm -rf "$INNER" "$DIST.tar.xz" "$DIST.tar.xz.sha256"
mkdir -p "$INNER/bin" "$INNER/include" "$INNER/share/doc" "$INNER/share/man/man1"
cp memcached "$INNER/bin/"
cp scripts/memcached-tool "$INNER/bin/"
cp COPYING "$INNER/share/doc/LICENSE"
cp doc/memcached.1 "$INNER/share/man/man1/"
cat > "$INNER/share/doc/README.txt" <<EOF
memcached $VERSION 便携版 (Linux $ARCH, glibc >= 2.17)

标准前缀布局 (bin/include/share), 单二进制, 解压即用, 目标系统无需安装任何依赖库。
以下库已静态编译进 memcached 二进制:
  - OpenSSL $OS_VER           (TLS 支持, --enable-tls)
  - libevent $LIBEVENT_VER
  - libseccomp $LIBSECCOMP_VER (seccomp 沙箱)
  - cyrus-sasl $CYRUS_SASL_VER (SASL 认证, PLAIN 机制已内置, 无需系统 SASL 插件)
唯一的动态依赖是 glibc 本身 (CentOS/RHEL 7 及更新版本均可直接运行)。

基本用法:
  ./bin/memcached -u nobody -p 11211

SASL 认证 (-S, 二进制协议客户端):
  echo 'user:pass' > pwdb.txt
  MEMCACHED_SASL_PWDB=./pwdb.txt ./bin/memcached -S -u nobody

目录结构:
  bin/     memcached 主程序, memcached-tool 管理脚本(perl, 可选)
  include/ 占位 (memcached 无对外 API 头文件)
  share/   文档(doc), 手册页(man), LICENSE
EOF
tar -cJf "$DIST.tar.xz" "$INNER"
sha256sum "$DIST.tar.xz" > "$DIST.tar.xz.sha256"

# 输出移到工程根目录
mv "$DIST.tar.xz" "$DIST.tar.xz.sha256" "$SCRIPT_DIR/"
log "完成: $SCRIPT_DIR/$DIST.tar.xz"
