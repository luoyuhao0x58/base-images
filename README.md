# base-images

构建用的基础镜像集合。

| 目录 | 内容 |
|---|---|
| [`python2.7/`](python2.7/) | Debian 13 上的 Python 2.7.18 |

镜像推在 `ghcr.io/<owner>/python`：

| tag | 内容 |
|---|---|
| `2.7-deb` | 只含 `/py27.deb` 的 scratch 镜像，给下游 `COPY --from` |
| `2.7` | 装好 Python 2.7 的运行时镜像 |

构建方式、产物内容和已知限制写在各自的 README 里。

构建由 GitHub Actions 触发：push 到 `main` 且改动落在某个运行时目录时，只重建那个运行时。
