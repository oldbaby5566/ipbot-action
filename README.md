# One IP Action

公开仓库：`oldbaby5566/ipbot-action`。这里保存 One IP 的 GitHub Actions 和公开构建产物；业务源码仍在 `ipbot-server`、`ipbot-web`。

## 发布流程

在本仓库执行（backend/web 保留同名转发入口）：

```sh
make deploy-server               # Server + Web；make deploy 同义
make deploy-web                  # 只更新 Web，不重启 Server
make deploy-server DRY_RUN=true  # 仓库预检与计划，不构建、不发布
```

1. 本地同时检查 Web 和 Rust；任一失败均不升级版本、提交或触发 Action。
2. 升级版本，提交并推送两个源码仓库，创建版本标签；携带精确源码 SHA 触发本仓库 `deploy.yml`。
3. Action 的 Web、Server job 并发构建。Web 复用 pnpm 缓存；Rust 在 Bookworm 容器内编译，复用 Cargo registry、git、target 缓存。当前生产目标为 `linux/amd64`，与原发布默认一致。
4. 汇总到本仓库的 `deploy-<server|web>-<version>` Release。Server 发布包含 `server-image.tar.gz`、`web.tar.gz`、`docker-compose.yml`、`checksums.txt`；Web 发布只有 Web 包和校验清单。产物保存在 Release，临时 Actions artifact 保留两天。
5. SSH 传递部署指令及校验清单的 SHA256。服务器从公开 Release 并发下载文件，先校验清单，再校验全部文件，通过后才载入镜像、切换 Web、检查健康状态。失败由本仓库部署器自动回滚。

镜像由编译后的 Rust 二进制和已校验字体构成，Web 包来自 `dist`，不上传源码目录、`.env`、SSH 密钥或数据目录。Release 内的镜像、Web 和 Compose **所有人都可下载**；服务器下载时无需 GitHub token。大文件不提交到 Git 历史。

## 首次配置

先提交并推送本仓库的 `main`，再提交 backend/web 中对应的发布流程修改。`Makefile` 与 `make/release.mk` 管理日常发布入口，`scripts/release.sh` 负责本地检查和 dispatch，`make/deploy.mk` 负责远端部署；部署契约测试也集中在本仓库。后端旧的 tag-trigger workflow 已移除，日常发布统一通过本仓库的 `workflow_dispatch`；本地发布器要求此目录干净，且 HEAD 等于已发布的 `origin/main`。

在本仓库设置：

| 位置 | 名称 | 用途 |
| --- | --- | --- |
| Repository secret | `GH_TOKEN` | 读取 `oldbaby5566/ipbot-server`、`oldbaby5566/ipbot-web`，供构建 job checkout 私有源码 |
| Environment `one-ip-prod` secrets | `DEPLOY_HOST`、`DEPLOY_PORT`、`DEPLOY_USER` | SSH 主机、端口（空值默认 22）、用户 |
| Environment `one-ip-prod` secrets | `DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS` | 部署私钥及已确认的服务器 host key |

本 workflow 使用自己的 `GITHUB_TOKEN` 创建 Release，需要允许 workflow 的 `contents: write` 权限；不需要给服务器配置仓库凭据。公开仓库的 workflow 运行日志也可见，勿主动输出源码或环境配置。

本机触发 Action 使用环境变量 `GH_TOKEN`，或 `gh auth token` / Git HTTPS credential helper 中的凭据，需要本仓库的 Actions write 权限。与构建 job 的源码读取 token 可以分别配置。[GitHub workflow dispatch 文档](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)

服务器继续使用 `/opt/one-ip`、本机 `.env`、`data` 和数据库网络，要求 Linux、Bash、curl、GNU tar/coreutils、Docker Compose v2。只更新 Web 前需先有支持独立 Web 挂载的 Server 部署。

## 检查与重试

```sh
actionlint .github/workflows/deploy.yml
shellcheck scripts/*.sh
make deploy-test
```

这些检查不会连接生产服务器。若源码已推送而 dispatch 失败，可在本仓库 Actions 页面手动运行 `One IP Deploy`，填入同一版本、两个已发布源码 SHA 和当前 Action SHA。Release 已创建但下载失败时，检查原因后可仅重跑失败的 deploy job；如果已生成远端版本目录，须先确认并清理失败版本目录，或使用新版本发布。重新构建或完整重发需新版本，流程拒绝覆盖已有 Release 和远端版本目录。

## 手动执行与 Stage

以下命令都在本仓库执行；默认源码路径为 `BACKEND_DIR=../backend`、`WEB_DIR=../web`。手动 SSH/registry 执行方式保留在这里，backend/web 不再提供这些执行器。

| 参数 | 约定 |
| --- | --- |
| `DEPLOY_HOST` | 必填，SSH 主机或 `~/.ssh/config` 的别名；使用当前 SSH 配置，BatchMode，不接受交互密码 |
| `DEPLOY_DIR` | 远端目录，生产默认 `/opt/one-ip`；必须是绝对非根目录 |
| `DEPLOY_IMAGE` | Server / image-build 必填，完整版本标签或 `@sha256:...`；不接受 latest 或无版本标签。image-build 仅接受标签 |
| `DEPLOY_VERSION` | 必填、未使用过的发布目录名，1–64 位字母/数字/点/下划线/连字符；image-build 和 Server 部署必须使用相同版本 |
| `DEPLOY_TRANSFER` | `ssh`（手动默认）、`registry` 或 `release`（Action 使用） |
| `DEPLOY_RELEASE` / `DEPLOY_CHECKSUM` | release 模式必填：`deploy-<server|web>-<DEPLOY_VERSION>` 与可信的 `checksums.txt` SHA256，由发布 job 传递 |
| `DEPLOY_PLATFORM` | image-build 必填，显式选择目标 Linux 主机的 `linux/amd64` 或 `linux/arm64`；不按本机 Mac 架构猜测 |
| `DEPLOY_PORT` / `DEPLOY_NAME` | 默认 `27528` / `one-ip`；分别是服务器回环 HTTP 端口、Compose 项目及容器名，须与既有部署一致 |
| `WEB_DIR` / `PNPM` | 本地前端目录（默认 `../web`）与 pnpm 可执行文件（默认 `pnpm`） |
| `DRY_RUN=true` | 只打印本地与远端计划；不执行 pnpm、Docker、SSH，不创建临时包或改文件 |

先检查计划，以下主机名、仓库地址和版本是占位值，需替换成真实配置：

```sh
# 按目标 Linux 主机选择平台；下面仅以 amd64 为例
make image-build DRY_RUN=true DEPLOY_IMAGE=registry.example/ipbot:v1 \
  DEPLOY_VERSION=v1 DEPLOY_PLATFORM=linux/amd64
make publish-server DRY_RUN=true DEPLOY_HOST=your-ssh-alias \
  DEPLOY_IMAGE=registry.example/ipbot:v1 DEPLOY_VERSION=v1 DEPLOY_TRANSFER=registry
make publish-web DRY_RUN=true DEPLOY_HOST=your-ssh-alias DEPLOY_VERSION=web-v2
make deploy-test       # dry-run、参数校验与本地 mock 回滚测试，不访问远端
```

使用 `DEPLOY_TRANSFER=registry` 时，真实 Server 发布分两步：先移除 image-build 的 dry-run，构建本地镜像，再由操作者把该标签发布到自己的镜像仓库；`image-build` 不推送。它运行 Web production build，仅将 Cargo 配置、`src`、`sql`、后端 `deploy/docker/Dockerfile` 和 Web 产物复制进临时上下文，给 Web 写入 `one-web-revision.txt`，不包含 `.env` 或 `data`。`publish-server` 在远端拉取指定镜像、解析仓库 digest、提取镜像中的 `/opt/one-ip/web-dist`，要求其中版本标记与 `DEPLOY_VERSION` 一致，随后原子切换 `web/current` 并对 `ip` 服务执行 Compose up。运行环境固定引用解析出的 digest，不随标签后续变化。

`publish-web` 使用版本目录 `web/releases/<DEPLOY_VERSION>`；release 模式从 GitHub 下载 Web 包，手动 ssh/registry 模式上传本地构建的 Web 和版本标记，再用同目录 symlink + GNU `mv -T` 原子切换。Server 和 Web 都检查回环地址的 `/readyz`、首页和 `one-web-revision.txt`；失败自动恢复旧 Web。Server 有旧 `deployments/current` 时沿用旧 manifest 和 release.env，并以旧运行镜像 ID 恢复容器；首次迁移若只有运行镜像，按当前 Compose 参数恢复旧镜像，不能自动还原未纳入管理的旧配置。首次 Server 发布没有旧容器或旧清单时，失败会移除新容器。失败版本与历史版本保留供排查，不自动删除；重复版本拒绝覆盖，重试需新版本或由操作者确认清理失败目录。部署目录锁带每次发布唯一 owner，远端退出和本地后续清理都只释放匹配 owner 的锁；SSH 中断留下锁时须先确认没有发布在运行，再人工处理。

Server 将 Compose 和不含凭据的镜像/名称/端口/ENV 参数存于 `deployments/<版本>`，成功后切换 `deployments/current`；不覆盖用户的 `.env` 或既有根目录 Compose 文件。必要时可用成功部署的版本清单检查运行状态：

```sh
# 在远端部署目录执行；项目名需与 DEPLOY_NAME 一致
cd /opt/one-ip
docker compose --project-directory "$PWD" --env-file .env \
  --env-file deployments/current/release.env -p one-ip \
  -f deployments/current/docker-compose.yml ps
```

远端需 Linux、Bash、GNU coreutils/tar、curl、Docker 和 Compose v2；SSH 用户需能写部署目录、操作 Docker。服务器先准备 `.env`、可供 uid/gid 10001 写入的 `data` 目录与现有 `db-networks` 网络，填好 PostgreSQL、Redis、`APP_PUBLIC_URL` 和可信入口配置。Action Make 发布命令不创建数据库、网络、TLS、DNS 或仓库凭据，也不读取本地密钥配置。数据库/schema 兼容、第三方数据授权和外部依赖需在真实发布前另行确认。

Compose 只将 HTTP 绑定到服务器回环地址，Web 只读挂载、data 保留在原目录。反向代理将域名转发到配置端口，并覆盖客户端传来的访客 IP 请求头。基础发布清单不启用额外的 DNS/STUN 公网端口；如需自建探针，另行审核并应用 `docker-compose.probes.yml`，不能把基础发布计划当作探针公网验收。

Stage 不继承生产主机、目录、镜像、版本、端口或构建平台：`deploy-stage` 必须显式设置 `DEPLOY_STAGE_HOST`、`DEPLOY_STAGE_DIR`、`DEPLOY_STAGE_IMAGE`、`DEPLOY_STAGE_VERSION`、`DEPLOY_STAGE_PORT`；`deploy-stage-web` 不要求镜像。项目/容器默认 `one-ip-stage`，可用 `DEPLOY_STAGE_NAME` 修改；远端目录需独立 `.env` 与相应服务配置，容器 ENV 为 stage。`image-build-stage` 使用前端 `build:stage`，还要求 stage 镜像、版本和 `DEPLOY_STAGE_PLATFORM`。未配置的 stage 目标直接失败。

`deploy-test` 只验证 dry-run、命令与 mock 文件切换/回滚契约；不会构建或推送生产镜像、连接部署主机，也不能代替数据库、镜像构建与公网发布验收。
