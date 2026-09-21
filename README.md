# build-memcached — memcached 便携版构建工程

把 [memcached](https://memcached.org) 官方源码编译成**免依赖、解压即用**的二进制发布包：

- **Linux**：在 manylinux2014（glibc 2.17 基线）容器内构建，除 glibc 外全部静态链入
  （OpenSSL / libevent / libseccomp / cyrus-sasl），单二进制，CentOS/RHEL 7 及更新版本可直接运行，
  目标机器无需安装任何依赖库。
- **Windows**：基于 MSYS2 POSIX 运行时工具链构建，源码零改动，SASL/TLS 全可用，
  运行时 DLL（`msys-2.0.dll` 等）随包打进 `bin/`，无需安装 MSYS2。

SASL PLAIN 认证机制直接编入二进制并附带端到端功能测试；TLS（`--enable-tls`）与
seccomp 沙箱（`--enable-seccomp`，仅 Linux）完整支持。

## 构建产物

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Linux x86_64 | `memcached-<版本>-linux-glibc2.17-x86_64-openssl-<SSL版本>.tar.xz` | 单二进制，静态链接 |
| Linux aarch64 | `memcached-<版本>-linux-glibc2.17-aarch64-openssl-<SSL版本>.tar.xz` | 单二进制，静态链接 |
| Windows x86_64 | `memcached-<版本>-windows-x86_64-msys2.zip` | 附带 MSYS2 运行时 DLL |

每个压缩包均附带同名 `.sha256` 校验文件。包内顶层目录为纯版本名 `memcached-<版本>/`，
采用标准前缀布局：

```
memcached-<版本>/
├── bin/      memcached 主程序（Windows 版还包含运行时 DLL）、memcached-tool 管理脚本
├── include/  占位（memcached 无对外 API 头文件）
└── share/    文档、手册页、LICENSE（Windows 版另含可选 SASL 机制插件 sasl2/）
```

## 使用方法

### 基本启动

```bash
tar -xJf memcached-1.6.45-linux-glibc2.17-x86_64-openssl-3.5.6.tar.xz
cd memcached-1.6.45
./bin/memcached -u nobody -p 11211
```

Windows：

```powershell
Expand-Archive memcached-1.6.45-windows-x86_64-msys2.zip
cd memcached-1.6.45
bin\memcached.exe -p 11211 -m 64
```

### SASL 认证（PLAIN 机制已内置）

```bash
echo 'user:pass' > pwdb.txt
MEMCACHED_SASL_PWDB=./pwdb.txt ./bin/memcached -S -u nobody
```

PLAIN 机制已静态编入，无需系统 SASL 插件或 `/etc/sasl2/` 配置文件（见下方补丁说明）。
需要 SCRAM/GSSAPI 等其他机制时（仅 Windows 包提供机制插件），设置环境变量
`SASL_PATH` 指向包内 `share/sasl2` 目录。SASL 认证要求二进制协议客户端。

### TLS

完整支持，随包静态提供 OpenSSL（Linux）/ openssl 3.x（Windows）：

```bash
./bin/memcached -u nobody -Z -o ssl_chain_cert=server.pem -o ssl_key=server.key -p 11212
```

> Windows 构建基于 MSYS2 POSIX 兼容运行时，性能低于原生 Linux 构建，适合开发/测试/轻量场景；
> 生产环境建议使用 Linux 构建。

## 本地构建

### Linux（Docker）

```bash
docker run --rm -v "$(pwd)":/work -w /work \
  quay.io/pypa/manylinux2014_x86_64 \
  bash build-memcached.sh 1.6.45
```

参数依次为（均可省略，括号内为默认值）：

| 位置 | 参数 | 默认值 |
| --- | --- | --- |
| 1 | memcached 版本 | 必填 |
| 2 | OpenSSL 版本 | `3.5.6` |
| 3 | libevent 版本 | `2.1.12-stable` |
| 4 | libseccomp 版本 | `2.5.5` |
| 5 | cyrus-sasl 版本 | `2.1.28` |
| 6 | 目标架构 | `uname -m` |

依赖源码包会优先复用 `cache/` 目录（便于离线/本地构建），CI 冷启动时自动下载。

### Windows（MSYS2）

在 MSYS2 MINGW64 环境中安装依赖后运行：

```bash
pacman -S --needed base-devel gcc gperf perl perl-URI python zip curl \
  libevent libevent-devel libopenssl openssl-devel
bash build-memcached-win.sh 1.6.45 x86_64 [cyrus-sasl 版本, 默认 2.1.28]
```

cyrus-sasl 由脚本从源码静态编译（PLAIN 内置，不依赖 msys2 的 libsasl）；
libevent/openssl 使用 msys2 系统包版本，由 pacman 管理。

### 构建过程中的自动验证（三层）

两个构建脚本在打包前依次执行三层验证，前两层为**发布门禁**（失败即不发布）：

| 层级 | 内容 | 性质 |
| --- | --- | --- |
| L0 官方冒烟 | `make test`：发布包自带的纯 C 测试程序 `testapp`（二进制协议全套操作 + 部分单元测试），自拉起 `memcached-debug` 实例，不依赖 perl | 门禁 |
| L1 协议冒烟 | `smoke-test.sh` 起多组不同配置的实例，`smoke_test.py` 做协议级断言；Linux 附加 `ldd` 便携性检查（动态依赖只允许 glibc 家族）与静态库 `nm` PLAIN 检查 | 门禁 |
| L2 基准测试 | `benchmark.sh` 用官方压测工具 mc-crusher 跑 4 场景吞吐（get/set × 64B/1KB），结果写入 `benchmark-<平台>-<架构>.txt` 并拼入 Release 说明 | 记录 + 残废检测 |

L1 冒烟的实例分组：

| 实例配置 | 验证点 |
| --- | --- |
| 普通 `-m 64 -t 4` | ASCII 协议全套（set/get/add/replace/append/prepend/cas/incr/decr/touch/TTL/flush_all/stats）、大 value 边界（≈1MB 成功、超限拒绝）、二进制协议 set/get/delete、`memcached-tool` |
| 小内存 `-m 16` | LRU 逐出（灌数据后 `evictions > 0`） |
| TLS `-Z` | 自签证书启动，TLS 连接上 set/get/version |
| SASL `-S` | PLAIN 三断言：机制已编入、正确密码通过、错误密码拒绝 |
| 沙箱 `-o drop_privileges`（仅 Linux） | seccomp 下正常启动、读写正常、SIGTERM 可正常退出 |

L2 的吞吐数字来自共享 CI runner，波动较大，不作发布门槛；只设极宽的残废检测下限（10k ops/s），防止构建配置错误产出性能崩坏的二进制还照常发布。

> **Windows 包的 SASL 说明**：cyrus-sasl 从源码静态编译（同 Linux 构建），PLAIN 机制直接编入 `memcached.exe`，不依赖任何运行时 SASL 插件或 `SASL_PATH`，解压即用。历史上 Windows 构建曾依赖 MSYS2 系统 libsasl2（PLAIN 是插件 DLL），在无 MSYS2 环境的裸 Windows 上插件路径无法解析导致 `-S` 不可用；现构建脚本在打包后自动做**解压场景验证**（解包产物 + `SASL_PATH` 屏蔽系统插件路径再跑全套冒烟），防止此类问题回归。

## CI 发布（GitHub Actions）

`.github/workflows/build-memcached.yml` 支持两种触发方式：

- **手动触发**（workflow_dispatch）：在 Actions 页面运行，填写参数即可。
- **被其他工作流调用**（workflow_call）：作为可复用构建发布流程。

构建矩阵为 Linux x86_64 + Linux aarch64 + Windows x86_64，全部通过后自动创建
GitHub Release（tag 为 memcached 版本号）并上传全部产物与校验文件。
可通过 `make_latest` / `prerelease` 输入控制 Release 标记。

## 便携补丁说明

`patches/sasl_defs-portable.patch` 对 memcached 源码中 `sasl_defs.c` 做了两处改动，
让 `-S` 模式在"裸机"上开箱即用：

1. **找不到 SASL 配置文件不视为错误**：上游在 `/etc/sasl2/memcached.conf` 不存在时
   返回 `SASL_FAIL`，导致 `-S` 直接启动失败。该配置文件只用于逐机制调参，
   PLAIN 认证并不依赖它。
2. **不把主机名作为 SASL user_realm**：上游将 `gethostname()` 传给 `sasl_server_new`，
   cyrus-sasl 会给不含 `@` 的用户名追加 `@主机名`，导致 `MEMCACHED_SASL_PWDB` 里的
   裸用户名条目（如 `user:pass`）永远匹配不上。去掉 realm 后客户端用户名与 pwdb
   条目直接对应。

memcached 本身取官方发布包（`memcached.org/files`，自带 configure，无需 autotools）。

## 目录结构

```
.
├── .github/workflows/build-memcached.yml  # CI：多平台构建 + 三层验证 + 自动发布 Release
├── build-memcached.sh                     # Linux 构建脚本（manylinux2014 容器内运行）
├── build-memcached-win.sh                 # Windows 构建脚本（MSYS2 环境运行）
├── smoke-test.sh                          # L1 冒烟编排：起多配置实例调 smoke_test.py 断言
├── smoke_test.py                          # 协议冒烟客户端（ASCII/二进制/TLS/SASL，py2/3 兼容）
├── benchmark.sh                           # L2 基准：mc-crusher 四场景吞吐 + 结果文件
├── bench_sample.py                        # 基准采样：stats 计数器速率换算
├── patches/sasl_defs-portable.patch       # SASL 便携补丁
└── cache/                                 # 源码包缓存（git 忽略，离线构建用）
```
