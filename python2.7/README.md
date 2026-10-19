# python2.7

Debian 13 (trixie) 上的 Python 2.7.18。PGO + LTO，共享库，UCS-4，装在 `/usr/local`。

trixie 已经把 python2 删了，遗留代码还得跑。这个目录把源码编译、deb 打包、镜像分发串成一条离线可复现的流程，产物可以直接当基础镜像用。

## 构建

在 `python2.7/` 目录里执行，build context 就是本目录，Dockerfile 里的 `COPY caches` 也相对这里。

```bash
cd python2.7
docker build -f Dockerfile.deb -t python:2.7-deb .
```

产物是 scratch 镜像，里面只有一个 `/py27.deb`。scratch 没有 shell，`docker create` 随便给个参数：

```bash
docker create --name py27 python:2.7-deb /py27.deb
docker cp py27:/py27.deb ./py27.deb
docker rm py27
dpkg-deb -I py27.deb          # 看 Depends
```

一次全量构建含 PGO 训练和 LTO 链接，devbox 上 6 分钟出头。改过 `build.sh` 或 `patches/` 要加 `--no-cache`，否则拿到的是旧层。

apt 慢的话换源：

```bash
docker build -f Dockerfile.deb \
  --build-arg APT_MIRROR=mirrors.aliyun.com \
  -t python:2.7-deb .
```

Python 相关的全部来自 `caches/`，构建过程不访问 python.org 和 PyPI。缓存文件的来源和 sha256 在 [SOURCES.md](SOURCES.md)。

## 下游怎么用

三种方式，按场景挑。

**直接用运行时镜像**

镜像的 `ENTRYPOINT` 是 `/usr/local/bin/python2`，不加参数就进 REPL。

```bash
docker run --rm ghcr.io/<owner>/python:2.7 -V
docker run --rm ghcr.io/<owner>/python:2.7 -c 'import ssl; print(ssl.OPENSSL_VERSION)'
docker run --rm --entrypoint bash ghcr.io/<owner>/python:2.7
```

**把 deb 拷进自己的镜像**

```dockerfile
FROM debian:13-slim
COPY --from=ghcr.io/<owner>/python:2.7-deb /py27.deb /
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates /py27.deb \
 && rm -rf /var/lib/apt/lists/*
```

`apt-get update` 不能省。slim 镜像的 `/var/lib/apt/lists` 是空的，没有索引 apt 解析不了 deb 的 Depends，报的是 `libgdbm6t64 but it is not installable`，看着像包不存在。

`ca-certificates` 得点名：deb 只是 Recommends 它，而 `--no-install-recommends` 会跳过。少了 CA bundle，`ssl.create_default_context()` 直接 `CERTIFICATE_VERIFY_FAILED`。

**装到宿主机**

```bash
apt-get install ./py27.deb
```

## 装了什么

装在 `/usr/local`，不动 `/usr`，和系统 python3 并存。

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/python2.7`、`python2` | 解释器 |
| `/usr/local/bin/python2.7-config`、`python2-config` | 编译参数查询 |
| `/usr/local/bin/pip2`、`pip2.7` | pip 20.3.4 |
| `/usr/local/bin/virtualenv2`、`virtualenv-2.7` | virtualenv 20.15.1 |
| `/usr/local/bin/easy_install-2.7`、`2to3-2.7`、`idle2.7`、`pydoc2.7` | 其余脚本 |
| `/usr/local/lib/libpython2.7.so.1.0` | 共享库，装完 ldconfig 自动注册 |
| `/usr/local/include/python2.7` | 头文件 |
| `/usr/local/lib/python2.7/site-packages` | pip、setuptools 44.1.1、wheel 0.37.1、virtualenv |
| `/usr/local/lib/python2.7/lib-dynload` | 65 个扩展模块 |

命令名全部带版本号，不给 `python`、`pip`、`virtualenv` 这类裸名。`/usr/local/bin` 在 PATH 里排在 `/usr/bin` 前面，留个裸名会把系统的 python3 工具遮住。

virtualenv 自带 pip/setuptools/wheel 的 seed wheel，断网也能建环境：

```bash
virtualenv2 /opt/app-venv
/opt/app-venv/bin/pip install -r requirements.txt
```

`Depends` 由构建脚本从产物 ELF 的 NEEDED 反查得到，apt 会自动拉齐 libc6、libssl3t64、libdb5.3t64、libnsl2、libsqlite3-0、libreadline8t64、libncursesw6、libtcl8.6、libtk8.6、libbz2-1.0、libgdbm6t64、zlib1g 等。`Recommends` 是 `ca-certificates`。

版本号固定为 `2.7.18-1deb13local1`。装过旧版要先 `apt-get remove python2.7` 再装新版，版本号一样时直接覆盖会留下两套文件。dpkg 会拥有 `/usr/local` 下这些路径，机器上手工编译过 python2 的，装之前先清干净。

## 没编进去的模块

| 模块 | 原因 |
|---|---|
| `imageop` | 上游 setup.py 在 64 位平台主动禁用 |
| `_md5`、`_sha`、`_sha256`、`_sha512` | 由 `_hashlib` 走 OpenSSL 提供，`hashlib` 的六种算法都能用 |
| `_CF`、`_CG`、`_Launch`、`_Qt`、`_scproxy`、`autoGIL` | macOS 专属 |
| `_Win` | Windows 专属 |
| `sunaudiodev` | Solaris 专属 |
| `dl` | 要求 32 位 |
| `bsddb185` | 需要 Berkeley DB 1.85，trixie 没有 db1 |
| `timing`、`xx` | 上游注释掉的废弃模块和示例模块 |

`pwd`、`_weakref` 在 `sys.builtin_module_names` 里，是解释器内置，不需要单独的 `.so`。
