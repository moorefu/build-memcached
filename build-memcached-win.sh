#!/bin/bash
set -e

# Usage: ./build-memcached-win.sh <version> [arch] [cyrus-sasl-ver]
# Example: ./build-memcached-win.sh 1.6.45 x86_64 2.1.28
#
# 在 MSYS2 的 MINGW64 环境运行 (依赖来自 msys2 系统包, 版本由 pacman 管理):
#   pacman -S --needed base-devel gcc gperf perl perl-URI python zip curl \
#                     libevent libevent-devel libopenssl openssl-devel
#
# 说明: memcached 是纯 Unix 代码, mingw64 缺 sys/socket.h 等 POSIX 头,
# 原生移植需要大改(参考 jefyt/memcached-windows, 代价是不支持 SASL)。
# 本脚本用 MSYS 运行时工具链(CC=/usr/bin/gcc)构建, 源码零改动、SASL/TLS 全可用,
# 代价是 zip 内附带 msys-2.0.dll 等运行时 DLL(打包进 bin/, 解压即用)。
#
# cyrus-sasl 从源码静态编译(同 Linux 构建): PLAIN 机制直接编入 libsasl2.a,
# 不用 msys2 系统 libsasl2 —— 系统版的 PLAIN 是插件 DLL(msys-plain-3.dll),
# 插件路径靠 msys 运行时挂载表解析, 裸 Windows 解压场景解析不到,
# -S 模式机制列表为空。其余依赖(libevent/openssl)仍用 msys2 系统包版本。
# 打包后自动做"解压场景验证": 解包产物 + SASL_PATH 屏蔽系统插件路径再测 SASL。
#
# memcached 取官方发布包(memcached.org/files, 自带 configure)。
# 注意: msys2 的 autoconf 2.73 无法处理 memcached 的 configure.ac
# ("undefined or overquoted macro"), 发布包自带 configure 正好绕开 autotools。

VERSION="${1:?Usage: $0 <version> [arch] [cyrus-sasl-ver]}"
ARCH="${2:-x86_64}"
CYRUS_SASL_VER="${3:-2.1.28}"

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
for cmd in curl tar patch make zip python ldd nm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "错误: 需要 $cmd (pacman -S 安装)"; exit 1; }
done

# ---------- 静态 cyrus-sasl (PLAIN 机制编入库内, 同 Linux 构建) ----------
DEPS=/tmp/deps
mkdir -p "$DEPS"
if [ ! -f "$DEPS/cyrus-sasl/lib/libsasl2.a" ]; then
  log "编译静态 cyrus-sasl $CYRUS_SASL_VER (PLAIN 机制内置)"
  cd "$DEPS"
  download "https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-$CYRUS_SASL_VER/cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
  rm -rf "cyrus-sasl-$CYRUS_SASL_VER"
  tar -xzf "cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
  cd "cyrus-sasl-$CYRUS_SASL_VER"
  # 与 Linux 构建同款配置: 只保留 PLAIN/ANONYMOUS, 去外部数据库与 openssl 依赖。
  # --disable-staticdlopen: 静态库模式下不再 dlopen 外部插件;
  # 不加 --with-pic —— 静态插件表只在非 PIC 编译时生效(#ifndef PIC)。
  # CFLAGS=-std=gnu99: 2.1.28 的 md5.c 是 K&R 空参数原型, gcc14+ 默认
  # C23 语义把 () 当 (void) 导致 "too many arguments" 编译错误。
  # --host/--build=x86_64-pc-msys: 自带 config.guess 把 MSYS 环境误判为
  # mingw64, host_os 变成 mingw32 后会命中 WINDOWS 条件走 windlopen.c
  # (MSVCRT API, msys 下编译不过); 显式指定 msys 走 dlopen.c。
  CFLAGS="-std=gnu99 -O2 -g" ./configure \
    --host=x86_64-pc-msys \
    --build=x86_64-pc-msys \
    CC=/usr/bin/gcc \
    --enable-static \
    --disable-shared \
    --prefix="$DEPS/cyrus-sasl" \
    --disable-sample \
    --disable-cram \
    --disable-digest \
    --disable-scram \
    --disable-otp \
    --disable-gssapi \
    --disable-staticdlopen \
    --with-dblib=none \
    --without-openssl
  make -j$(nproc)
  make install
  cd "$SCRIPT_DIR"
fi

# 静态插件表必须真的包含 PLAIN (用前缀匹配: 不同平台宏展开的符号为
# plain_server_plug_init / plain_server_pluginit 两种形态)
if ! nm "$DEPS/cyrus-sasl/lib/libsasl2.a" 2>/dev/null | grep -q 'plain_server_plug'; then
  echo "错误: PLAIN 机制未被编入静态 libsasl2.a" >&2
  exit 1
fi

download "https://memcached.org/files/memcached-$VERSION.tar.gz"
rm -rf "memcached-$VERSION"
tar -xzf "memcached-$VERSION.tar.gz"
cd "memcached-$VERSION"

log "应用便携补丁 patches/sasl_defs-portable.patch"
patch -p1 --fuzz=3 < "$SCRIPT_DIR/patches/sasl_defs-portable.patch"

# 显式指向 MSYS gcc (MINGW64 环境下默认 gcc 是 mingw 编译器, 缺 POSIX 头)。
# SASL 用静态库全路径: msys ld 对 -lsasl2 优先命中系统 libsasl2.dll.a(动态),
# 只有传 .a 全路径才能强制静态链接, 产物才不依赖 msys-sasl2-3.dll 与插件。
./configure \
  CC=/usr/bin/gcc \
  --enable-tls \
  --enable-sasl \
  --enable-sasl-pwdb \
  CPPFLAGS="-I$DEPS/cyrus-sasl/include" \
  LIBS="$DEPS/cyrus-sasl/lib/libsasl2.a"
make -j$(nproc)

# ---------- L0: 官方 testapp 冒烟 ----------
# 同 Linux: 显式只跑纯 C 的 testapp/sizes, 绕开 make test 追加的 perl TLS 套件
log "L0 官方冒烟 (testapp + sizes)"
make -j$(nproc) testapp sizes
./sizes.exe
./testapp.exe

log "验证"
./memcached.exe --version

# ---------- L1: 冒烟测试 ----------
# 多配置实例(普通/小内存逐出/TLS/SASL)的协议级断言; seccomp 仅 Linux, 自动跳过
log "L1 冒烟测试 (协议/TLS/SASL/逐出)"
bash "$SCRIPT_DIR/smoke-test.sh" "$PWD/memcached.exe" "$PWD"

# ---------- L2: 基准测试 ----------
log "L2 基准测试 (mc-crusher)"
bash "$SCRIPT_DIR/benchmark.sh" "$PWD/memcached.exe"

# ---------- 打包 ----------
# 包内顶层目录用纯版本名 memcached-<version>, zip 文件名保留平台后缀
log "打包"
DIST="memcached-$VERSION-windows-$ARCH-msys2"
INNER="memcached-$VERSION"
rm -rf "$INNER" "$DIST.zip" "$DIST.zip.sha256"
mkdir -p "$INNER/bin" "$INNER/include" "$INNER/share/doc"
cp memcached.exe "$INNER/bin/"
# 打包 msys 运行时依赖 DLL 到 bin/ (exe 同目录自动加载), 解压即用
# (静态 sasl 后不再依赖 msys-sasl2-3.dll, ldd 不会收集到它)
for dll in $(ldd memcached.exe | grep -oE '/usr/bin/[^ ]+\.dll' | sort -u); do
  cp "$dll" "$INNER/bin/"
done
cp COPYING "$INNER/share/doc/LICENSE"
cat > "$INNER/share/doc/README.txt" <<EOF
memcached $VERSION Windows 版 (x86_64, MSYS2 运行时)

标准前缀布局 (bin/include/share), 自带运行所需全部 DLL
(msys-2.0.dll 等位于 bin/), 解压即可运行, 无需安装 MSYS2。

用法:
  bin/memcached.exe -p 11211 -m 64

SASL 认证 (-S):
  echo testuser:testpass > pwdb.txt
  MEMCACHED_SASL_PWDB=pwdb.txt bin/memcached.exe -S
  (PLAIN 机制已静态编入, 无需系统 SASL 插件与 SASL_PATH)

TLS: 完整支持 (openssl 3.x 随包提供)。

注意: 本构建基于 MSYS2 POSIX 兼容运行时, 性能低于原生 Linux 构建,
适合开发/测试/轻量场景; 生产环境建议使用 Linux 构建。

目录结构:
  bin/     memcached.exe 主程序 + msys 运行时 DLL
  include/ 占位 (memcached 无对外 API 头文件)
  share/   文档(doc), LICENSE
EOF
zip -q -r "$DIST.zip" "$INNER"
sha256sum "$DIST.zip" > "$DIST.zip.sha256"

# ---------- 解压场景验证 ----------
# 把产物解包到临时目录, 用 SASL_PATH 指向不存在目录以屏蔽构建环境的
# 系统插件路径, 模拟裸 Windows "解压即用": SASL 只能靠静态内置的 PLAIN 工作,
# 从而防止构建环境的系统插件再次掩盖插件路径类缺陷。其余冒烟组顺带复测。
log "解压场景验证 (屏蔽系统 SASL 插件路径)"
VERIFY=/tmp/mc-verify-unpack
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
unzip -q "$DIST.zip" -d "$VERIFY"
( cd "$VERIFY/$INNER" && SASL_PATH=/nonexistent \
    bash "$SCRIPT_DIR/smoke-test.sh" "$PWD/bin/memcached.exe" "$PWD" )
rm -rf "$VERIFY"

mv "$DIST.zip" "$DIST.zip.sha256" "$SCRIPT_DIR/"
log "完成: $SCRIPT_DIR/$DIST.zip"
