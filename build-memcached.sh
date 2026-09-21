#!/bin/bash
set -e

# Usage: ./build-memcached.sh <version> [openssl-ver] [libevent-ver] [libseccomp-ver] [cyrus-sasl-ver] [arch]
# Example: ./build-memcached.sh 1.6.45 3.5.6 2.1.12-stable 2.5.5 2.1.28 x86_64
#
# 在 manylinux2014 (glibc 2.17) 容器内运行, 构建便携的 memcached:
# OpenSSL/libevent/libseccomp/cyrus-sasl 动态链接, 对应 .so 随包打进
# lib/ 目录, 二进制 rpath 设为 $ORIGIN/../lib —— 解压即用, 目标机器只需
# glibc >= 2.17, 无需安装任何依赖库。cyrus-sasl 的 PLAIN 机制插件位于
# 包内 lib/sasl2/, 由 sasl_defs.c 的 GETPATH 回调(见 patches/)按可执行
# 文件位置自动定位, 无需设置 SASL_PATH。
# 产出 memcached-<版本>-linux-glibc2.17-<架构>-openssl-<ssl版本>.tar.xz (+ .sha256),
# 包内顶层目录为纯版本名: memcached-<版本>/{bin,lib,include,share}。
#
# memcached 取官方发布包(memcached.org/files, 自带 configure, 无需 autotools);
# 不同版本通过第一个参数指定。sasl_defs.c 的便携改动见 patches/。
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
# libevent-devel: 基准工具 mc-crusher 的编译依赖 (memcached 用包内自编 libevent)
# perl-URI: 冒烟中 memcached-tool 的依赖 (URI::Escape)
# patchelf: 打包时把 rpath 改写为 $ORIGIN 相对路径;
#   x86_64 镜像预装 / vault 源可装, aarch64 两者皆无 → 源码编译兜底
yum install -y curl pkgconfig perl-core autoconf automake libtool gperf libevent-devel perl-URI patchelf || true
if ! command -v patchelf >/dev/null 2>&1; then
  log "源码编译 patchelf (仓库源无此包)"
  (
    cd /tmp
    download "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0.tar.gz"
    tar -xzf patchelf-0.18.0.tar.gz
    cd patchelf-0.18.0
    ./configure --prefix=/usr/local
    make -j"$NPROC"
    make install
  )
fi
command -v patchelf >/dev/null 2>&1 || { echo "错误: 需要 patchelf" >&2; exit 1; }
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

# ---------- 动态 OpenSSL ----------
if [ ! -f "$DEPS/openssl/lib/libssl.so" ]; then
  log "编译动态 OpenSSL $OS_VER"
  OPENSSL_URL="https://www.openssl.org/source/openssl-${OS_VER}.tar.gz"
  [ "${OS_VER%%.*}" = "3" ] && \
    OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OS_VER}/openssl-${OS_VER}.tar.gz"
  download "$OPENSSL_URL"
  tar -xzf "openssl-$OS_VER.tar.gz"
  cd "openssl-$OS_VER"
  ./Configure "linux-$ARCH" shared no-tests \
    --prefix="$DEPS/openssl" --openssldir="$DEPS/openssl" --libdir=lib
  make -j"$NPROC"
  make install_sw
  cd "$DEPS"
fi

# ---------- 动态 libevent ----------
if [ ! -f "$DEPS/libevent/lib/libevent.so" ]; then
  log "编译动态 libevent $LIBEVENT_VER"
  download "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz"
  tar -xzf "libevent-$LIBEVENT_VER.tar.gz"
  cd "libevent-$LIBEVENT_VER"
  ./configure --enable-shared --disable-static --prefix="$DEPS/libevent" --disable-openssl
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# ---------- 动态 libseccomp ----------
if [ ! -f "$DEPS/libseccomp/lib/libseccomp.so" ]; then
  log "编译动态 libseccomp $LIBSECCOMP_VER"
  download "https://github.com/seccomp/libseccomp/releases/download/v$LIBSECCOMP_VER/libseccomp-$LIBSECCOMP_VER.tar.gz"
  tar -xzf "libseccomp-$LIBSECCOMP_VER.tar.gz"
  cd "libseccomp-$LIBSECCOMP_VER"
  ./configure --enable-shared --disable-static --prefix="$DEPS/libseccomp"
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi
# libseccomp 动态链接时其内部符号不导出, 与 memcached 全局符号 'hash' 的
# 静态链接冲突问题不复存在 (历史上静态链接曾因此 segfault, 见 git log)。

# ---------- 动态 cyrus-sasl (PLAIN 作为插件, 随包分发) ----------
if [ ! -f "$DEPS/cyrus-sasl/lib/libsasl2.so" ]; then
  log "编译动态 cyrus-sasl $CYRUS_SASL_VER (PLAIN 插件)"
  download "https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-$CYRUS_SASL_VER/cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
  tar -xzf "cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
  cd "cyrus-sasl-$CYRUS_SASL_VER"
  # 只保留 PLAIN/ANONYMOUS 机制, 关闭其余插件, 去掉外部数据库依赖。
  # 动态库(PIC)下 cyrus-sasl 的静态插件表不生效, PLAIN 以插件形式安装到
  # $DEPS/cyrus-sasl/lib/sasl2/, 打包进包内 lib/sasl2/, 由 sasl_defs.c 的
  # GETPATH 回调 (patches/sasl_defs-plugin-path.patch) 按可执行文件位置定位。
  ./configure \
    --enable-shared \
    --disable-static \
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

# PLAIN 机制插件必须存在 (动态模式下机制以插件形式提供, 文件名因平台而异)
ls "$DEPS/cyrus-sasl/lib/sasl2/"*plain* >/dev/null 2>&1 || {
  echo "错误: PLAIN 机制插件未生成 ($DEPS/cyrus-sasl/lib/sasl2/)" >&2
  exit 1
}
# 构建目录与包布局同构: GETPATH 回调按 <bin>/../lib/sasl2 定位插件,
# 源码目录在 $DEPS/memcached-<ver>/ 下, 建此链接让构建目录也能加载插件
mkdir -p "$DEPS/lib"
ln -sfn ../cyrus-sasl/lib/sasl2 "$DEPS/lib/sasl2"

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
# 插件路径补丁: SASL GETPATH 回调按可执行文件位置定位包内 lib/sasl2
log "应用插件路径补丁 patches/sasl_defs-plugin-path.patch"
patch -p1 --fuzz=3 < "$SCRIPT_DIR/patches/sasl_defs-plugin-path.patch"

# 链接期 rpath 指向 $DEPS 绝对路径, 构建目录即可直接运行测试;
# 打包时统一用 patchelf 改写为 $ORIGIN/../lib 相对路径保证便携。
# (直接在 LDFLAGS 写 $ORIGIN 会被 automake 的 make 二次展开吃掉, 故分两步)
./configure \
  --with-libevent="$DEPS/libevent" \
  --with-libssl="$DEPS/openssl" \
  --enable-seccomp \
  --enable-tls \
  --enable-sasl \
  --enable-sasl-pwdb \
  CPPFLAGS="-I$DEPS/libseccomp/include -I$DEPS/cyrus-sasl/include" \
  LDFLAGS="-L$DEPS/libseccomp/lib -L$DEPS/cyrus-sasl/lib \
    -Wl,-rpath,$DEPS/openssl/lib -Wl,-rpath,$DEPS/libevent/lib \
    -Wl,-rpath,$DEPS/libseccomp/lib -Wl,-rpath,$DEPS/cyrus-sasl/lib" \
  LIBS="-lpthread -ldl -lseccomp -lsasl2"
make -j"$NPROC"

# ---------- L0: 官方 testapp 冒烟 ----------
# 发布包自带纯 C 测试程序 testapp(56 个用例: 二进制协议全套 + 单元测试),
# 自拉起 memcached-debug 实例, 不依赖 perl; sizes 打印关键结构体大小。
# 注意: 不用 `make test` —— 它在 --enable-tls 下还会跑 perl TLS 套件(需
# IO::Socket::SSL), 超出 L0 定位且环境依赖重; TLS 由 L1 冒烟覆盖。
log "L0 官方冒烟 (testapp + sizes)"
make -j"$NPROC" testapp sizes
./sizes
./testapp

# ---------- 便携性验证 ----------
# 动态链接模式下: 非系统的库必须解析到 $DEPS (打包后即包内 lib/),
# 不允许解析到系统目录 (否则目标机器上会缺库), 也不允许有 not found。
# ldd 显示的 rpath 解析路径带 "bin/../" 中缀, 须 realpath 规范化后再比对。
check_ldd() {
  local bin="$1" prefix="$2" bad="" lib arrow path p
  while read -r lib arrow path _rest; do
    case "$lib" in linux-vdso*|ld-linux*) continue ;; esac
    if [ "$arrow" = "=>" ] && [ "$path" != "not" ]; then
      p="$(realpath -m "$path" 2>/dev/null || echo "$path")"
    else
      [ "$path" = "not" ] && bad="$bad
$lib NOT_FOUND"
      continue
    fi
    case "$lib" in
      libc.so*|libpthread*|libdl*|libm.so*|librt*|libresolv*|libgcc_s*) continue ;;
    esac
    case "$p" in
      "$prefix"/*) continue ;;
      *) bad="$bad
$lib -> $p" ;;
    esac
  done < <(ldd "$bin")
  if [ -n "$bad" ]; then
    echo "错误: $bin 存在系统目录依赖或缺失的动态库:" >&2
    echo "$bad" >&2
    return 1
  fi
}

log "检查动态依赖 (系统库只允许 glibc 家族, 其余必须来自包内)"
ldd memcached
check_ldd "$PWD/memcached" "$DEPS"

# ---------- L1: 冒烟测试 ----------
# 多配置实例(普通/小内存逐出/TLS/SASL/seccomp)的协议级断言, 详见 smoke-test.sh
log "L1 冒烟测试 (协议/TLS/SASL/逐出/seccomp)"
bash "$SCRIPT_DIR/smoke-test.sh" "$PWD/memcached" "$PWD"

# ---------- L2: 基准测试 ----------
# mc-crusher 四场景吞吐, 结果写入 benchmark-<平台>-<架构>.txt (非门禁, 含残废检测)
log "L2 基准测试 (mc-crusher)"
bash "$SCRIPT_DIR/benchmark.sh" "$PWD/memcached"

# ---------- 打包 ----------
# 包内顶层目录用纯版本名 memcached-<version>, 压缩包文件名保留平台/依赖版本后缀
log "打包"
DIST="memcached-$VERSION-linux-glibc2.17-$ARCH-openssl-$OS_VER"
INNER="memcached-$VERSION"
rm -rf "$INNER" "$DIST.tar.xz" "$DIST.tar.xz.sha256"
mkdir -p "$INNER/bin" "$INNER/lib/sasl2" "$INNER/include" "$INNER/share/doc" "$INNER/share/man/man1"
cp memcached "$INNER/bin/"
cp scripts/memcached-tool "$INNER/bin/"

# 依赖 .so 打进包内 lib/ (cp -P 保留 soname 符号链接链)
for libdir in "$DEPS/openssl/lib" "$DEPS/libevent/lib" \
              "$DEPS/libseccomp/lib" "$DEPS/cyrus-sasl/lib"; do
  cp -P "$libdir"/*.so.* "$INNER/lib/" 2>/dev/null || true
done
cp -P "$DEPS/cyrus-sasl/lib/sasl2/"*.so* "$INNER/lib/sasl2/" 2>/dev/null || true

# rpath 改写为相对路径: 主程序 $ORIGIN/../lib (bin -> lib),
# 包内 .so 自身 $ORIGIN (lib 内互找, 如 libssl 找 libcrypto)
patchelf --set-rpath '$ORIGIN/../lib' "$INNER/bin/memcached"
for so in "$INNER/lib/"*.so.* "$INNER/lib/sasl2/"*.so*; do
  [ -f "$so" ] && patchelf --set-rpath '$ORIGIN' "$so"
done

cp COPYING "$INNER/share/doc/LICENSE"
cp doc/memcached.1 "$INNER/share/man/man1/"
cat > "$INNER/share/doc/README.txt" <<EOF
memcached $VERSION 便携版 (Linux $ARCH, glibc >= 2.17)

标准前缀布局 (bin/lib/include/share), 解压即用, 目标系统只需 glibc >= 2.17,
无需安装任何依赖库。依赖库以动态链接方式随包分发 (位于 lib/), 二进制 rpath
指向包内目录 (\$ORIGIN 相对路径, 不依赖系统安装):
  - OpenSSL $OS_VER           (TLS 支持, --enable-tls)
  - libevent $LIBEVENT_VER
  - libseccomp $LIBSECCOMP_VER (seccomp 沙箱)
  - cyrus-sasl $CYRUS_SASL_VER (SASL 认证, PLAIN 机制插件在 lib/sasl2/,
    由程序按自身位置自动定位, 无需设置 SASL_PATH)

基本用法:
  ./bin/memcached -u nobody -p 11211

SASL 认证 (-S, 二进制协议客户端):
  echo 'user:pass' > pwdb.txt
  MEMCACHED_SASL_PWDB=./pwdb.txt ./bin/memcached -S -u nobody

目录结构:
  bin/     memcached 主程序, memcached-tool 管理脚本(perl, 可选)
  lib/     依赖库 .so 与 SASL 机制插件 (sasl2/)
  include/ 占位 (memcached 无对外 API 头文件)
  share/   文档(doc), 手册页(man), LICENSE
EOF
tar -cJf "$DIST.tar.xz" "$INNER"
sha256sum "$DIST.tar.xz" > "$DIST.tar.xz.sha256"

# ---------- 解压场景验证 ----------
# 解包产物到临时目录再跑全套冒烟: rpath 应让 bin/memcached 找到包内 lib/,
# SASL 插件应从包内 lib/sasl2 加载 —— 用 SASL_PATH 屏蔽系统插件路径,
# 防止构建环境的系统库/插件掩盖便携性问题。同时断言 ldd 无系统目录依赖。
log "解压场景验证 (rpath + 屏蔽系统 SASL 插件路径)"
VERIFY=".mc-verify-unpack.$$"
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
tar -xJf "$DIST.tar.xz" -C "$VERIFY"
check_ldd "$PWD/$VERIFY/$INNER/bin/memcached" "$PWD/$VERIFY/$INNER/lib" || {
  rm -rf "$VERIFY"; exit 1
}
( cd "$VERIFY/$INNER" && SASL_PATH=/nonexistent \
    bash "$SCRIPT_DIR/smoke-test.sh" "$PWD/bin/memcached" "$PWD" )
rm -rf "$VERIFY"

# 输出移到工程根目录
mv "$DIST.tar.xz" "$DIST.tar.xz.sha256" "$SCRIPT_DIR/"
log "完成: $SCRIPT_DIR/$DIST.tar.xz"
