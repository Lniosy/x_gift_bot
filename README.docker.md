# XGift Docker 部署

本仓库是 [mizorewww/x_gift_bot](https://github.com/mizorewww/x_gift_bot) 的 Docker 打包版本，只增加了 `Dockerfile`、`docker-compose.yml`、`.env.example`、`.dockerignore` 和 GHCR 构建工作流，**程序代码未做修改**。功能说明、配置向导细节请阅读原项目 [README.md](README.md)。

> 原作者：**[mizorewww](https://github.com/mizorewww)** — 原项目 <https://github.com/mizorewww/x_gift_bot>。感谢原作者的开源工作。

## ⚠️ 风险提示

- 本程序需要使用你的 **X 登录 Cookie**（`auth_token`、`ct0`）以及 **付款用的银行卡信息**，并以你的账号身份自动下单付款。
- 自动化操作可能违反 X 的服务条款，**X 账号可能被限制或封禁，银行卡可能被拒付或风控**。
- 请自行评估风险，**使用后果自负**。作者与打包者不对任何账号、资金损失负责。
- 不要把真实的 Cookie、卡号、密码写进 `.env`、`docker-compose.yml` 或提交到任何仓库；敏感信息只通过配置向导写入加密保管库。

## 镜像构成

- 多阶段构建：`golang:1.27-alpine` 编译（`go-sqlite3` 需要 cgo，构建标签 `with_quic,with_utls`），运行于 `alpine`。
- 前端产物已随仓库提交在 `internal/site/assets` 并通过 `go:embed` 嵌入二进制，镜像构建无需 Node.js。
- 镜像内包含两个程序：`xgift-web`（网站，默认命令）和 `xgift`（命令行/配置向导）。
- 以非 root 用户 `10001:10001` 运行，容器只读根文件系统。

## 端口与数据卷

| 项目 | 容器内 | 宿主机 | 说明 |
|---|---|---|---|
| 网站端口 | `127.0.0.1:8787` | `127.0.0.1:8787` | 上游程序**只允许监听回环地址**，所以 compose 使用 `network_mode: host`，端口只在本机可访问，需要反向代理（Caddy）对外提供 HTTPS |
| 数据目录 | `/var/lib/xgift` | `./data` | `vault.db`（加密保管库）、`site.db`、锁文件 |
| 密钥目录 | `/etc/xgift` | `./secrets` | `vault-password`、`admin-password`、可选 `turnstile-secret`；web 容器内只读挂载 |
| Caddy（可选） | 80 / 443 | 80 / 443 | `--profile caddy` 启用，配置模板为 `deploy/Caddyfile` |

> 由于使用 host 网络，本方案适用于 **Linux 服务器**（Docker Desktop for macOS/Windows 的 host 网络行为不同）。

## 快速开始

### 1. 获取代码并准备目录

```sh
git clone https://github.com/Lniosy/x_gift_bot.git
cd x_gift_bot
mkdir -p data secrets
sudo chown -R 10001:10001 data secrets
sudo chmod 700 data secrets
```

### 2. 配置 `.env`

```sh
cp .env.example .env
```

主要字段（`.env` 中只放路径和开关，**不放任何真实凭据**）：

| 字段 | 说明 |
|---|---|
| `XGIFT_ORIGIN` | 站点完整域名，必须 `https://` 开头 |
| `XGIFT_LISTEN` | 只能是回环地址，默认 `127.0.0.1:8787` |
| `XGIFT_DATA_DIR` | 容器内数据目录，保持 `/var/lib/xgift` |
| `XGIFT_PASSWORD_FILE` | 保管库密码文件，默认 `/etc/xgift/vault-password` |
| `XGIFT_ADMIN_PASSWORD_FILE` | 后台密码文件，默认 `/etc/xgift/admin-password` |
| `XGIFT_PAYMENTS_ENABLED` | `true` 开放充值，`false` 暂停（建议先保持 `false`） |
| `XGIFT_TURNSTILE_SITE_KEY` / `XGIFT_TURNSTILE_SECRET_FILE` | 可选的 Cloudflare Turnstile，两项同时填或同时留空 |
| `TZ` | 容器时区 |
| `XGIFT_IMAGE` | 可选，使用预构建镜像，如 `ghcr.io/lniosy/x_gift_bot:latest` |
| `CADDYFILE` | 可选，Caddy 配置文件路径 |

### 3. 运行配置向导（首次）

```sh
docker compose build          # 或配置 XGIFT_IMAGE 后 docker compose pull
docker compose run --rm xgift-cli setup
```

- 询问「密码文件保存路径」时输入 **`/etc/xgift/vault-password`**（与 `.env` 一致）。**务必备份此文件，丢失后保管库无法恢复。**
- 其余步骤（X Cookie、支付卡、代理、Stripe 公钥、目录、站点域名）按向导提示填写；监听地址保持 `127.0.0.1:8787`。
- 向导会把后台密码写到 `data/admin-password`，并生成 `data/site.env`（容器部署使用 `.env`，可忽略 `site.env`）。把后台密码移动到密钥目录：

```sh
sudo mv data/admin-password secrets/admin-password
sudo chown 10001:10001 secrets/admin-password && sudo chmod 600 secrets/admin-password
docker compose run --rm xgift-cli status     # 所有记录显示 verified 即成功
```

### 4. 启动网站

```sh
docker compose up -d
docker compose ps
docker compose logs -f xgift
curl http://127.0.0.1:8787/healthz          # 在服务器本机执行
```

### 5. HTTPS 反向代理

宿主机已有 Caddy/Nginx 时，直接反代到 `127.0.0.1:8787` 即可。也可以使用 compose 自带的 Caddy：

```sh
mkdir -p caddy && cp deploy/Caddyfile caddy/Caddyfile
# 编辑 caddy/Caddyfile，把 xp.example.com 换成你的域名；不用 Cloudflare 时删除 @cloudflare 相关段
# 在 .env 中设置 CADDYFILE=./caddy/Caddyfile
docker compose --profile caddy up -d
```

然后访问 `https://你的域名/admin`（用户名 `admin`，密码见 `secrets/admin-password`）。

## 使用 GHCR 预构建镜像

GitHub Actions 会在推送 `main` 分支或 `v*` 标签时构建 `linux/amd64` 与 `linux/arm64` 镜像并推送到 GHCR：

```sh
docker pull ghcr.io/lniosy/x_gift_bot:latest
```

在 `.env` 中设置 `XGIFT_IMAGE=ghcr.io/lniosy/x_gift_bot:latest`，然后：

```sh
docker compose pull
docker compose up -d
```

## 日常维护

```sh
docker compose run --rm xgift-cli status        # 检查加密记录
docker compose run --rm xgift-cli check         # 测试代理连通 x.com
docker compose run --rm xgift-cli cards list    # 查看卡池（只显示尾号）
docker compose restart xgift                    # 修改 .env 后重启
```

升级：备份 `data/` 和 `secrets/` 后执行 `git pull && docker compose build && docker compose up -d`（或 `docker compose pull && docker compose up -d`）。

## 许可证

原项目采用 [MIT License](LICENSE)，Copyright © mizorewww。本 Docker 打包同样以 MIT 许可发布，并保留原作者的版权声明。
