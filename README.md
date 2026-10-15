# One IP Action

公开仓库：`oldbaby5566/ipbot-action`。业务源码分别保存在 `ipbot-server` 和 `ipbot-web`。生产架构为 `ipbot.net` 的 Cloudflare Pages 静态前端直接请求 `api.ipbot.net` 的 Docker API，两个组件分别发布。

## 生产环境 Secrets

在 GitHub 仓库 Settings → Environments 中使用已有环境 `prod`，配置下方表格列出的必要 Secrets。Pages 项目、分支和 SSH 端口已有 workflow 默认值；Server 地址和 SSH 用户名通过 Secrets 配置，无需添加 GitHub Variables。

在 [My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建自定义 Cloudflare Token。只发布 Pages 时，授予 `Account / Cloudflare Pages / Edit` 即可，Account Resources 只选 Pages 所属账户。只有另行初始化 DNS、Origin CA 或主机 SSL 规则时，才按操作需要添加 `Zone / Zone / Read`、`Zone / DNS / Edit`、`Zone / SSL and Certificates / Edit`、`Zone / Config Rules / Edit`，Zone Resources 只选 `ipbot.net`，日常 Pages 发布不需要这些额外权限。Token 只显示一次，不应提交到仓库。

账户 ID 可在域名 Overview 的 API 区域复制，也可在 Cloudflare 后台搜索 `Copy account ID`；不要混用 Zone ID。正式切换主域 DNS 前，应先完成成功的 production Pages 部署，并确认新 API 接受生产前端的凭证 CORS。

## 发布入口

在本仓库执行；backend/web 保留同名转发入口：

发布、构建与 SSH 配置直接由 `Makefile` 和 `make/*.mk` 调用 Git、Cargo、pnpm、Docker、curl 等原生命令，不依赖额外的 `.sh` 脚本。GitHub workflow 的 Server 构建与 SSH 配置分别调用 `make build-server` 和 `make configure-ssh`。

```sh
make deploy-server               # 仅 API Server；make deploy 同义
make deploy-web                  # 仅 Cloudflare Pages Web
make deploy-server DRY_RUN=true  # 仓库预检与计划，不构建、不发布
make deploy-web DRY_RUN=true
```

`deploy-server` 只检查、升级、提交和推送 Backend，创建 `deploy-server-<version>` 源码标签，然后携带精确 Backend SHA 触发 `deploy.yml`。不读取、检查或升级 Web 仓库。

`deploy-web` 只检查、升级、提交和推送 Web，创建 `v<version>` 源码标签，然后携带精确 Web SHA 触发同一 workflow。不读取、检查或升级 Backend 仓库。Web 在 runner 安装依赖、构建 `dist`，随后通过 `wrangler pages deploy dist` 直接上传 Pages，不发布 GitHub Web 压缩包，不执行 SSH 或重启 Server。

本地发布入口保留各自的发布检查：Server 使用 Cargo fmt、Clippy 和 tests；Web 使用 install、typecheck、lint、test、build。检查失败时不提交或 dispatch。

Action 仓库必须干净，且 HEAD 等于已发布的 `origin/main`。本地发布器只检查所选源码仓库和 Action 仓库的状态，要求源码分支不落后于 origin。`DRY_RUN=true` 仍会读取 Git 状态和 fetch 仓库信息，但不执行检查、版本修改、提交、push、tag 或 dispatch。

## GitHub 配置

| 位置 | 名称 | 用途 |
| --- | --- | --- |
| Environment `prod` secret（也可用 Repository secret） | `GH_TOKEN` | checkout 所选的私有源码仓库；应有 `ipbot-server` / `ipbot-web` 的只读权限 |
| Environment `prod` secret | `DEPLOY_HOST` | 直连源站的服务器 IP 或域名，不使用 Cloudflare 代理地址 |
| Environment `prod` secret | `DEPLOY_USER` | SSH 登录用户名 |
| Environment `prod` secrets | `DEPLOY_SSH_KEY`、`DEPLOY_KNOWN_HOSTS` | Server 部署私钥和已确认的 host key |
| Environment `prod` secret | `CLOUDFLARE_ACCOUNT_ID` | Pages 所在账户 ID，必须提供 |
| Environment `prod` secret | `CLOUDFLARE_API_TOKEN` | 指定账户的 `Account / Cloudflare Pages / Edit` token |

Web、Server 构建和 Server 部署统一使用 GitHub Environment `prod`。Pages 项目固定为 `ipbot`，生产分支固定为 `main`，无需配置 GitHub Variables。Server 地址和 SSH 用户名必须配置为 `prod` Secrets `DEPLOY_HOST`、`DEPLOY_USER`；SSH 端口默认 `22`。

账户 ID 和 token 没有默认值；workflow 不查找或猜测账户，也不创建项目、修改 DNS、自定义域名或证书。先在正确账户建立 Direct Upload 项目并上传前端，准备 API 域名、TLS 与后端允许的前端 Origin；正式切换时协调 API 发布与 Pages 接管 `ipbot.net`。新 Server 不再托管旧主站，若需要过渡，可临时挂载现有 Web 目录并显式设置 `WEB_DIST_DIR`，切换完成后再使用 API-only Compose。前端生产构建使用 `VITE_API_BASE_URL=https://api.ipbot.net/api`。

默认 workflow 权限为 `contents: read`，仅 Server 的 Release job 使用 `contents: write`。Web 使用 Wrangler CLI 直接上传，不向 GitHub Deployment API 写入，不要求 `deployments: write`。Server 与 Web 使用独立 concurrency group，互不等待对方的构建或发布。

本机 dispatch 使用 `GH_TOKEN`、`gh auth token` 或 Git HTTPS credential helper，需要 Action 仓库的 Actions write 权限；它可以与 checkout 私有源码的 token 分开配置。公开仓库的 workflow 日志和 Server Release 产物均公开，不能将业务环境文件、凭据或数据库内容放入产物。

参考：[Cloudflare Direct Upload CI](https://developers.cloudflare.com/pages/how-to/use-direct-upload-with-continuous-integration/)、[Wrangler Pages 命令](https://developers.cloudflare.com/workers/wrangler/commands/pages/)、[GitHub workflow dispatch](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)。

## Server 产物与部署

Server job 只 checkout Action 和 Backend。在 Bookworm 容器编译 Rust，复用 Cargo registry、git、target 和字体缓存，再将二进制与校验过的字体打包为 `linux/amd64` 运行镜像，不安装 pnpm、不构建或打包 Web。

公开 Release `deploy-server-<version>` 只包含 `server-image.tar.gz`、`docker-compose.yml` 和 `checksums.txt`。SSH 仅传部署指令及清单 SHA256；服务器从 Release 下载，校验清单与全部产物后加载镜像、执行 Compose、检查回环 `/readyz`，成功后切换 `deployments/current`。失败时沿用之前的 manifest、release.env 和镜像 ID 恢复 Server；失败与历史版本目录保留用于排查，不自动覆盖。

Server 不提取 Web、不切换 `web/current`，也不检查首页或 Web revision。Compose 不再挂载 `./web`，并显式设置 `WEB_DIST_DIR: ""`，覆盖旧 `.env` 里的静态目录值。旧 Web 目录不由发布脚本删除。API 只绑定回环 HTTP 端口，由 Nginx 的 `api.ipbot.net` 入口转发；`APP_PUBLIC_URL` 仍表示受信任的前端 Origin `https://ipbot.net`，不是 API 域名。

服务器保留 `/opt/one-ip/.env`、`data` 和数据库网络，需 Linux、Bash、curl、GNU coreutils、Docker Compose v2。首次发布前准备可由 uid/gid 10001 写入的 `data` 目录、PostgreSQL／Redis 配置与现有数据库网络；本发布器不创建数据库、网络、DNS 或 TLS。基础清单不开放额外探针端口，DNS／STUN 使用独立的 `docker-compose.probes.yml`。

远端清单保存在 `deployments/<version>`，排查时可使用：

```sh
cd /opt/one-ip
docker compose --project-directory "$PWD" --env-file .env \
  --env-file deployments/current/release.env -p one-ip \
  -f deployments/current/docker-compose.yml ps
```

目录锁只由对应发布的 owner 释放；SSH 中断遗留锁时，先确认没有发布正在运行，再人工处理。首次从非托管容器迁移且没有旧 manifest 时，只能以当前 Compose 配置恢复旧镜像，不能恢复未纳入管理的旧配置。

## 手动执行器

以下命令直接执行发布，不进行源码提交或 workflow dispatch。源码目录默认 `BACKEND_DIR=../backend`、`WEB_DIR=../web`。

```sh
# 本地只构建 API 镜像，不推送；按目标主机选择平台
make image-build DEPLOY_IMAGE=registry.example/ipbot:v1 \
  DEPLOY_VERSION=v1 DEPLOY_PLATFORM=linux/amd64

# 已将镜像推送到自己的 registry 后，只更新 Server
make publish-server DEPLOY_HOST=your-ssh-alias DEPLOY_TRANSFER=registry \
  DEPLOY_IMAGE=registry.example/ipbot:v1 DEPLOY_VERSION=v1

# 账户与 token 通过环境变量提供；只上传 Pages
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export CLOUDFLARE_API_TOKEN=your-pages-edit-token
make publish-web DEPLOY_VERSION=web-v2
```

`publish-web` 运行本地 Web build 后用 `pnpm dlx wrangler@4 pages deploy dist` 上传。需要先安装该 Web 的依赖；凭据只通过环境变量传递。`DRY_RUN=true` 只打印计划，不调用 pnpm、Wrangler、Docker 或 SSH，Pages dry-run 仍要求账户 ID 和版本，生产项目与分支使用默认值；Stage 参数仍须显式提供。

Server 的 `DEPLOY_TRANSFER` 支持 `ssh`（默认，构建镜像并经 SSH 传输）、`registry`（拉取指定镜像）和 `release`（Action 使用）。镜像要求版本标签或 `@sha256:...`，拒绝 latest；`image-build` 仅接受标签。`DEPLOY_DIR` 默认 `/opt/one-ip`，`DEPLOY_PORT` 默认 `27528`，`DEPLOY_NAME` 默认 `one-ip`。release 模式还要求 `DEPLOY_RELEASE=deploy-server-<version>` 和可信的 `DEPLOY_CHECKSUM`。不覆盖远端 `.env` 或根目录旧 Compose。

## Stage

Server Stage 不继承生产主机、目录、镜像、版本、端口或构建平台。`deploy-stage` 必须显式提供 `DEPLOY_STAGE_HOST`、`DEPLOY_STAGE_DIR`、`DEPLOY_STAGE_IMAGE`、`DEPLOY_STAGE_VERSION` 和 `DEPLOY_STAGE_PORT`；`image-build-stage` 还要求 `DEPLOY_STAGE_PLATFORM`。项目／容器默认 `one-ip-stage`，远端目录使用独立 `.env`，ENV 为 stage。

`deploy-stage-web` 不连接服务器，必须显式提供 `DEPLOY_STAGE_VERSION`、`CLOUDFLARE_STAGE_ACCOUNT_ID`、`CLOUDFLARE_STAGE_API_TOKEN`、`CLOUDFLARE_STAGE_PAGES_PROJECT` 和 `CLOUDFLARE_STAGE_PAGES_BRANCH` 和 `DEPLOY_STAGE_API_BASE_URL`。它使用 `build:stage`，通过 target-specific override 将 `DEPLOY_STAGE_API_BASE_URL` 导出为 `VITE_API_BASE_URL`，不会继承调用命令中的生产 API 地址。例如设置 `DEPLOY_STAGE_API_BASE_URL=https://your-stage-api.example/api`；该 API 的 `APP_PUBLIC_URL` 必须允许确切 Stage 前端 Origin。Pages preview 域名不会自动获得生产 Cookie 或调用生产 API 的授权。缺少 Stage 设置时直接失败，不回退生产账户或项目。

若源码已推送而 dispatch 失败，可手动重试 `One IP Deploy`，只填写所选 target 的源码 SHA、版本和当前 Action SHA。Server Release 和远端版本目录不覆盖，重新构建使用新版本；Pages 的历史部署与回滚由对应 Pages 项目管理。
