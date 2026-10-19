# Python 2.7 构建源码缓存

构建 `python2.7_2.7.18-1deb13local1` 所需的离线源码缓存。构建过程不访问以下任一来源。

## 清单与校验

| 文件 | 来源 | sha256 |
|---|---|---|
| Python-2.7.18.tgz | https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tgz（经 https://mirrors.huaweicloud.com/python/2.7.18/ 镜像获取，字节一致：17539408 B） | `da3080e3b488f648a3d7a4560ddee895284c3380b11d6de75edb986526b9a814` |
| pip-20.3.4-py2.py3-none-any.whl | https://pypi.org/pypi/pip/20.3.4/json 所列官方分发文件 | `217ae5161a0e08c0fb873858806e3478c9775caffce5168b50ec885e358c199d` |
| setuptools-44.1.1-py2.py3-none-any.whl | https://pypi.org/pypi/setuptools/44.1.1/json 所列官方分发文件 | `27a714c09253134e60a6fa68130f78c7037e5562c4f21f8f318f2ae900d152d5` |
| wheel-0.37.1-py2.py3-none-any.whl | https://pypi.org/pypi/wheel/0.37.1/json 所列官方分发文件 | `4bdcd7d840138086126cd09254dc6195fb4fc6f01c050a1d7236f2630db1d22a` |
| get-pip-2.7.py | https://bootstrap.pypa.io/pip/2.7/get-pip.py（Python 2 专用引导脚本，内嵌 pip 20.3.4） | `40ee07eac6674b8d60fce2bbabc148cf0e2f1408c167683f110fd608b8d6f416` |
| virtualenv-20.15.1-py2.py3-none-any.whl | PyPI virtualenv 20.15.1（最后支持 Python 2.7 的版本） | `b30aefac647e86af6d82bfc944c556f8f1a9c90427b2fb4e3bfbf338cb82becf` |
| distlib-0.4.4-py2.py3-none-any.whl | PyPI distlib 0.4.4 | `cf09d55b1e85a89576b036aeb71550bfd68320f3f21761ca329eadadad918638` |
| filelock-3.2.1-py2.py3-none-any.whl | PyPI filelock 3.2.1 | `7f07b08d731907441ff40d0c5b81f9512cd968842e0b6264c8bd18a8ce877760` |
| platformdirs-2.0.2-py2.py3-none-any.whl | PyPI platformdirs 2.0.2（<3 约束下的可用版本） | `0b9547541f599d3d242078ae60b927b3e453f0ad52f58b4d4bc3be86aed3ec41` |
| six-1.17.0-py2.py3-none-any.whl | PyPI six 1.17.0 | `4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274` |
| pathlib2-2.3.7.post1-py2.py3-none-any.whl | PyPI pathlib2 2.3.7.post1 | `5266a0fd000452f1b3467d782f079a4343c63aaa119221fbdc4e39577489ca5b` |
| scandir-1.10.0.tar.gz | PyPI scandir 1.10.0 sdist（PyPI 无 Linux cp27 wheel，构建时编译） | `4d4631f6062e658e9007ab3149a9b914f3548cb38bfb021c64f39a025ce578ae` |
| importlib_metadata-2.1.3-py2.py3-none-any.whl | PyPI importlib-metadata 2.1.3（最后支持 py2.7） | `52e65a0856f9ba7ea8f2c4ced253fb6c88d1a8c352cb1e916cff4eb17d5a693d` |
| importlib_resources-3.3.1-py2.py3-none-any.whl | PyPI importlib-resources 3.3.1 | `42068585cc5e8c2bf0a17449817401102a5125cbfbb26bb0f43cde1568f6f2df` |
| zipp-1.2.0-py2.py3-none-any.whl | PyPI zipp 1.2.0（最后支持 py2.7） | `e0d9e63797e483a30d27e09fffd308c59a700d365ec34e93cc100844168bf921` |
| configparser-4.0.2-py2.py3-none-any.whl | PyPI configparser 4.0.2 | `254c1d9c79f60c45dfde850850883d5aaa7f19a23f13561243a050d5a7c3fe4c` |
| contextlib2-0.6.0.post1-py2.py3-none-any.whl | PyPI contextlib2 0.6.0.post1 | `3355078a159fbb44ee60ea80abd0d87b80b78c248643b49aa6d94673b413609b` |
| singledispatch-3.7.0-py2.py3-none-any.whl | PyPI singledispatch 3.7.0 | `bc77afa97c8a22596d6d4fc20f1b7bdd2b86edc2a65a4262bdd7cc3cc19aa989` |
| typing-3.10.0.0-py2-none-any.whl | PyPI typing 3.10.0.0 | `c7219ef20c5fbf413b4567092adfc46fa6203cb8454eda33c3fc1afe1398a308` |

## 版本依据

- pip 20.3.4 / setuptools 44.1.1 / wheel 0.37.1：三者均为最后支持 Python 2.7 的版本（PyPI 元数据 `requires_python: >=2.7,!=3.0.*-!=3.4.*`）。
- `_bsddb` 不再 vendor：trixie 自带 `libdb5.3-dev`（5.3.28+dfsg2-9）和运行时包 `libdb5.3t64`，构建镜像里 apt 装前者，`_bsddb` 动态链接系统 `libdb-5.3.so`，deb 的 Depends 由构建脚本自动加上 `libdb5.3t64`。
- get-pip-2.7.py：离线构建实际用缓存的 pip wheel 引导（解压 wheel 后 `pip install --root`），脚本只是备用——缓存的 wheel 损坏而环境又能联网时，可以用它重新拉齐三件套。
- virtualenv 20.15.1：最后一个声明 `requires_python >=2.7` 的版本（20.16.0 起要求 >=3.6）。依赖集合由 pip 20.3.4 在 Python 2.7 下解析得出，包含经 pathlib2 引入的 scandir。scandir 的 cp27 Linux wheel 官方没有，缓存里放 sdist，构建时用 gcc 编译。

## 更新方法

替换文件后重跑 `sha256sum *` 更新本表。任何文件变更须同步核对来源 URL 仍然有效。
