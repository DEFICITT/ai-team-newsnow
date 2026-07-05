# NewsNow 部署说明

本文档记录 ai-team-newsnow（fork）在腾讯云服务器上的实际部署方案，基于 `custom` 分支自建镜像 + Caddy 自动 HTTPS。可作为重新部署或迁移时的参考。

## 部署场景

- **服务器**：腾讯云 CVM（CentOS），公网 IP `<服务器公网 IP>`
- **域名**：`ai-team.site`（腾讯云购买，DNSPod 解析）
- **分支**：`custom`（fork 定制分支，后期会改新闻源 + 上 CI/CD）
- **目标**：HTTPS + GitHub OAuth 登录

## 选型决策（选择的路线）

| 决策点 | 选择 | 原因 |
|---|---|---|
| 镜像来源 | 自建（`build: .`） | 后期要改 custom 分支新闻源，官方镜像 `ghcr.io/ourongxing/newsnow:latest` 不含定制 |
| HTTPS | Caddy 自动 Let's Encrypt | 免费 + 自动续期，不用买证书，也不用腾讯云免费 SSL（要手动续） |
| 部署方式 | Docker Compose（newsnow + caddy） | 一条命令启停，配置随仓库版本管理 |
| 代码拉取 | Gitee 中转 | 国内服务器直 clone GitHub 超时 |
| OAuth callback | 仅生产 `https://ai-team.site/api/oauth/github` | 本地登录不可用（回调到生产），但本地浏览新闻正常 |

## 架构

```
浏览器 / GitHub OAuth 回调
  → ai-team.site:443  (Caddy: 自动 Let's Encrypt + 反代)
  → newsnow:4444      (NewsNow 容器: 自建镜像)
```

## 部署文件（已提交到 custom 分支）

- `docker-compose.prod.yml` — newsnow（自建）+ caddy，敏感配置从 `.env` 读
- `Caddyfile` — Caddy 反代 + 自动 HTTPS

## 完整部署步骤

### 1. 准备 GitHub OAuth App

GitHub → Settings → Developer settings → OAuth Apps → New OAuth App：

| 字段 | 值 |
|---|---|
| Application name | `NewsNow` |
| Homepage URL | `https://ai-team.site` |
| Authorization callback URL | `https://ai-team.site/api/oauth/github` |

注册后拿到 **Client ID**，点 Generate client secret 拿 **Client Secret**（只显示一次，立刻保存）。

### 2. 服务器装 Docker

```bash
curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
systemctl enable --now docker
```

### 3. 配 Docker 镜像加速（国内必须，否则拉 caddy / node 镜像超时）

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.m.daocloud.io"
  ]
}
EOF
systemctl daemon-reload
systemctl restart docker
```

> 第一个是腾讯云内网源（服务器在腾讯云时最快），第二个公共备选。

### 4. 拉取代码（Gitee 中转）

国内服务器直 clone GitHub 会超时。先在 Gitee 导入 fork：
- 打开 https://gitee.com/projects/import/url
- 仓库地址填 `https://github.com/DEFICITT/ai-team-newsnow`
- 导入后在 Gitee 仓库网页**切换到 custom 分支**，点"强制同步"确保拿到最新

服务器上 clone：
```bash
git clone -b custom https://gitee.com/ancient-or-modern/ai-team-newsnow.git
cd ai-team-newsnow
```

### 5. 配 .env

```bash
cp example.env.server .env
nano .env   # 没装就 yum install -y nano，或用 vi
```

填三个值（其余行不动）：
```
G_CLIENT_ID=<你的 Client ID>
G_CLIENT_SECRET=<你的 Client Secret>
JWT_SECRET=<openssl rand -hex 32 生成的 64 位 hex 串>
```

> `.env` 已被 `.gitignore` 忽略，不会进仓库。

### 6. 腾讯云安全组放行 80 + 443

控制台 → CVM → 安全组 → 入站规则加 TCP **80** 和 **443**。
- 80：Caddy 申请证书用（HTTP-01 验证）
- 443：HTTPS 访问

### 7. 配 DNS A 记录

控制台 → DNS 解析 DNSPod → `ai-team.site` → 添加记录：

| 字段 | 值 |
|---|---|
| 主机记录 | `@` |
| 记录类型 | `A` |
| 记录值 | `<服务器公网 IP>` |
| TTL | 600 |

验证生效：
```bash
dig ai-team.site +short   # 应返回 <服务器公网 IP>
```

### 8. 启动

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

首次构建几分钟（`pnpm install` + `pnpm build`）。Caddy 启动后自动申请证书：
```bash
docker logs caddy   # 找 "certificate obtained successfully"
```

### 9. 验证

```bash
curl https://ai-team.site/api/enable-login
# 期望: {"enable":true,"url":"https://github.com/login/oauth/authorize?client_id=..."}
```

浏览器开 `https://ai-team.site`，点登录按钮 → 跳 GitHub 授权 → 跳回来 = 全流程打通。

## 日常更新

改 custom 分支代码后，更新服务器：
```bash
# 先去 Gitee 仓库网页点"强制同步"（让 Gitee 拉取 GitHub 最新 custom）
git pull
docker compose -f docker-compose.prod.yml up -d --build
```

## 常见问题（踩坑记录）

### Docker 拉镜像超时（registry-1.docker.io）
国内访问 Docker Hub 慢。配镜像加速（第 3 步）。腾讯云服务器用 `mirror.ccs.tencentyun.com`（内网，最快）。

### Gitee clone 的代码是旧的 / 缺 docker-compose.prod.yml
Gitee 镜像不同步 GitHub 最新提交。解决：
- Gitee 仓库网页点"强制同步"，再服务器 `git pull`
- 或加 GitHub remote 直接 fetch（数据量小，可能能成功）：
  ```bash
  git remote add github https://github.com/DEFICITT/ai-team-newsnow.git
  git fetch github custom
  git checkout -B custom github/custom
  ```

### Caddy 证书申请失败：no valid A records
域名 DNS 没配 A 记录。去 DNSPod 加 A 记录指向服务器 IP（第 7 步），`dig` 确认返回 IP 后 `docker restart caddy`。

### 本地 .env.server 改了不生效（506 disabledLogin）
`pnpm dev` 只在启动时读环境变量。改 `.env.server` 后必须重启 dev server：Ctrl+C 后重新 `pnpm dev`。

### 本地填 JWT_SECRET 时 PowerShell 报错
PowerShell 不认 bash 语法（`JWT=$(openssl ...)`）。用 Node 一行代替：
```powershell
node -e 'const fs=require("fs"),c=require("crypto");const j=c.randomBytes(32).toString("hex");fs.writeFileSync(".env.server",fs.readFileSync(".env.server","utf8").replace(/^JWT_SECRET=.*/m,"JWT_SECRET="+j));console.log("done")'
```

### GitHub OAuth Secret 泄露
立刻去 OAuth App → Generate a new client secret（旧的自动失效）→ 更新服务器 `.env` 和本地 `.env.server` → 重启容器 / dev server。新 Secret 不要贴到任何对话/聊天里。

## 后续 CI/CD 演进方向

当前为手动部署。后期 CI/CD 路线（后期再做）：

1. **镜像仓库**：腾讯云 TCR 个人版（免费、国内拉取快），比 GHCR 更适合腾讯云服务器
2. **GitHub Actions**：监听 `custom` 分支 push → 用项目 `Dockerfile` 构建镜像 → 推到 TCR（打 `latest` 和 `commit-sha` tag）
3. **服务器自动更新**：Watchtower 容器监听 TCR 新镜像自动拉取重启；或 GitHub Actions 跑完后 SSH 触发 `docker compose pull && up -d`
4. **改造 compose**：`docker-compose.prod.yml` 的 `build: .` 换成 `image: <TCR地址>/newsnow:latest`，服务器不再需要源码，Gitee 中转也可退役

## 关键信息速查

| 项 | 值 |
|---|---|
| 服务器公网 IP | `<服务器公网 IP>` |
| 域名 | `ai-team.site` |
| NewsNow 容器端口 | `4444` |
| Caddy 端口 | `80`, `443` |
| OAuth callback | `https://ai-team.site/api/oauth/github` |
| GitHub Client ID | `Ov23liyZSVDIJTjYXQlf` |
| Gitee 镜像地址 | `https://gitee.com/ancient-or-modern/ai-team-newsnow.git` |
| 数据卷 | `newsnow_data`（挂载到 `/usr/app/.data`） |
| 启动命令 | `docker compose -f docker-compose.prod.yml up -d --build` |
| 日志查看 | `docker logs caddy` / `docker logs newsnow` |
