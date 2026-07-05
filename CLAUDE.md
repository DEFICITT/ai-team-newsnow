# CLAUDE.md

> 面向 AI 助手的项目速览。阅读本文件即可快速理解 NewsNow 的架构与开发约定。

## 项目简介

NewsNow 是一个**聚合实时热点新闻**的阅读型 Web 应用（`package.json` version `0.0.41`，MIT）。当前仓库为**仅支持中文的 demo 版本**，主打"优雅阅读实时与最热新闻"，支持 GitHub OAuth 登录与数据同步、自适应抓取间隔、PWA、MCP server。

作者：ourongxing。仓库主页见 `package.json#homepage`。

## 技术栈

- **前端**：React 19 + TanStack Router（文件路由）+ TanStack Query；Jotai + ahooks 状态；UnoCSS + Framer Motion + `@atlaskit/pragmatic-drag-and-drop`；overlayscrollbars。
- **服务端**：Nitro（经 `vite-plugin-with-nitro` 挂载）+ h3。Nitro preset 按部署环境切换。
- **数据库**：`db0` 抽象层，连接器随 preset 切换：better-sqlite3（本地/node）/ Cloudflare D1（CF_PAGES）/ bun-sqlite（BUN）；Vercel 需自配在线数据库。
- **抓取**：cheerio + fast-xml-parser + ofetch + iconv-lite。
- **认证**：GitHub OAuth + JWT（jose）。
- **工具链**：Vite 7、pnpm 10（`packageManager: pnpm@10.30.3`）、TypeScript 5.9、ESLint 9、Vitest 4、simple-git-hooks + lint-staged。
- **别名**：`~` → `src`，`@shared` → `shared`，`#` → `server`（见 `vite.config.ts` 与 `nitro.config.ts`）。

## 常用命令

```sh
pnpm dev        # 开发（先跑 presource 生成源文件，再起 vite）
pnpm build      # 构建（产物在 dist/output/public，server 在 dist/output/server）
pnpm start      # 运行构建产物：node --env-file .env.server dist/output/server/index.mjs
pnpm preview    # CF_PAGES=1 构建 + wrangler pages dev 本地预览
pnpm deploy     # CF_PAGES=1 构建 + wrangler pages deploy
pnpm typecheck  # tsc --noEmit（node + app 两个 project）
pnpm lint       # eslint
pnpm test       # vitest
```

`dev`/`build` 前会自动执行 `presource`（`scripts/favicon.ts` + `scripts/source.ts`）。

## 环境变量

参考 `example.env.server`，本地开发复制为 `.env.server`：

```env
G_CLIENT_ID=        # GitHub OAuth Client ID
G_CLIENT_SECRET=    # GitHub OAuth Client Secret
JWT_SECRET=         # JWT 密钥，通常与 Client Secret 相同
INIT_TABLE=true     # 首次运行建表，之后可关闭
ENABLE_CACHE=true   # 是否启用缓存
```

未配置 `JWT_SECRET`/`G_CLIENT_ID`/`G_CLIENT_SECRET` 时，服务端进入 `disabledLogin` 模式（见 `server/middleware/auth.ts`）：仅放行 `/api/s`、`/api/latest`、`/api/proxy`，其余接口返回 506。

## 目录结构

```
shared/            前后端共享代码
  pre-sources.ts   源定义（声明式，所有新闻源的元信息）+ genSources()
  sources.ts        由 sources.json 派生（构建期生成）
  sources.json      构建期生成（source.ts 产物，勿手改）
  updated-sources.ts 构建期生成（基于 git diff 计算自上次版本以来变更的源）
  pinyin.json       构建期生成（源名拼音，用于排序）
  metadata.ts       列（columns）定义与 metadata 装配
  consts.ts         TTL=30min、Interval=10min、版本号等常量
  types.ts          核心类型：SourceID / Source / Metadata / NewsItem...
  verify.ts         运行时校验工具
server/
  sources/          46 个新闻源抓取器（每文件一个 defineSource）
  getters.ts        用 glob:./sources/{*.ts,**/index.ts} 自动聚合所有抓取器
  api/              REST 接口（见下）
  database/         cache.ts（缓存表）、user.ts（用户表）
  middleware/auth.ts JWT 校验 + 登录开关
  utils/            fetch(myFetch)、crypto、date、rss2json、logger、base64
  glob.d.ts / types.ts 类型补充
src/
  routes/           TanStack 文件路由：__root.tsx / index.tsx / c.$column.tsx
  components/        column / header / footer / navbar / common
  hooks/             query、useLogin、useSync、useRefetch、usePWA、useSearch…
  atoms/             Jotai 状态（focusSourcesAtom、primitiveMetadataAtom）
  utils/ / styles/
tools/rollup-glob.ts rollup glob 插件，支撑 server/sources 的 glob 导入
scripts/            favicon.ts、source.ts（构建前代码生成）
patches/            pnpm 补丁（dayjs.patch）
test/               测试
```

## 核心架构

### 1. 新闻源系统（可插拔，类型驱动）

- 在 `shared/pre-sources.ts` 的 `originSources` 中声明源：`name` / `color` / `home` / `column`（归属列）/ `type`（`hottest` | `realtime`）/ `interval` / 可选 `sub`（子源）/ `redirect`（重定向到另一源）/ `disable`。
- **`SourceID` 是从 `originSources` 类型推导的字面量联合类型**（`shared/types.ts`），加新源即获得编译期校验与全项目类型提示——这是项目最精巧之处。
- 刷新间隔档位（`pre-sources.ts` 内 `Time`）：`Test` 1ms / `Realtime` 2min / `Fast` 5min / `Default` 10min / `Common` 30min / `Slow` 1h。
- 每个抓取器位于 `server/sources/<id>.ts`，导出 `defineSource(async () => NewsItem[])`，通过 `glob:` 在 `server/getters.ts` 自动注册。复杂源可用目录 + `index.ts`。
- 抓取器示例见 `server/sources/ithome.ts`：用 `myFetch` 取 HTML → cheerio 解析 → 过滤广告 → `parseRelativeDate` 解析时间 → 按时间倒序。

### 2. 构建期代码生成（`scripts/source.ts`，`presource` 阶段）

- 读取 `genSources()` 生成 `shared/sources.json`（前端也用）。
- 用 `@napi-rs/pinyin` 生成 `shared/pinyin.json`（源名拼音，用于中文排序）。
- 通过 **git diff**（对比上一个版本 tag 与 HEAD 之间 `server/sources/` 的变更）生成 `shared/updated-sources.ts`，驱动首页"更新"列。
- 这些文件是产物，**勿手动修改**；改源定义请改 `pre-sources.ts`，改抓取请改 `server/sources/*.ts`。

### 3. 缓存与刷新策略（`server/api/s/index.ts`，关键设计）

两层时间窗，目的：省资源 + 防 IP 封禁：

- **interval（刷新间隔）**：`now - cache.updated < sources[id].interval` → 直接返回缓存（源本身更新慢，期间多半没新内容）。
- **TTL（30min，`shared/consts.ts`）**：`interval ≤ now < TTL` 内，即便有新内容也复用旧缓存；只有请求带 `latest` 参数**且**（服务器禁用登录 `disabledLogin` **或** 用户已登录）才强制拉新。
- 抓取失败时优雅降级，返回旧缓存。
- `server/api/s/entire.post.ts`：批量取多个源的缓存（一次请求），前端首屏用。
- Cloudflare Worker 的 `Date.now()` 在整个运行期不更新——代码中已按此假设处理。

### 4. API 一览

| 路径 | 作用 |
|---|---|
| `GET /api/s?id=&latest=` | 取某源数据（核心，含上述缓存逻辑） |
| `POST /api/s/entire` | 批量取缓存（body: `{ sources: SourceID[] }`） |
| `GET /api/latest` | 最新更新（用于"更新"列） |
| `GET /api/enable-login` | 查询是否启用登录 |
| `POST /api/login` | 登录入口 |
| `GET /api/oauth/github` | GitHub OAuth 回调 |
| `GET /api/me` | 当前用户信息（需 JWT） |
| `POST /api/me/sync` | 同步用户"关注"列表（需 JWT） |

`server/middleware/auth.ts` 对 `/api/*` 统一处理：未配置密钥 → `disabledLogin`；`/api/me` 必须带合法 Bearer JWT，否则 401；`/api/s` 带 token 则尝试解析用户但不强制。

### 5. 前端结构

- 路由：`src/routes/index.tsx`（首页，根据 `focusSourcesAtom` 决定显示 "focus" 或 "hottest" 列）、`c.$column.tsx`（动态列）。
- 数据获取：TanStack Query + `src/hooks/query.ts`；`useRefetch` 处理刷新；`useSync` 处理登录态同步。
- 状态：Jotai atoms（`src/atoms/`）；`primitiveMetadataAtom` 持有各列源列表。
- **自动导入**：`vite.config.ts` 用 `unimport` 自动导入 `src/hooks`、`src/utils`、`src/atoms`、`shared/{consts,metadata,sources,...}.ts`、`react`、`jotai` 等——代码中可直接用 `useAtomValue`/`defineSource`/`defineEventHandler`/`getQuery` 等而无需 import。`imports.app.d.ts` 为生成类型声明。

### 6. 列（columns）体系

`shared/metadata.ts` 定义 9 个列：国内 / 国际 / 科技 / 财经 / 体育（普通列）+ 关注 / 最热 / 实时 / 更新（固定列 `fixedColumnIds`）。`hottest`/`realtime` 列的源列表由 `getSortedSourceIds` 按 `type` 过滤后拼音排序自动生成。

## 部署

`nitro.config.ts` 按环境变量切换 preset + 数据库连接器：

| 环境 | preset | 数据库 |
|---|---|---|
| 默认 | `node-server` | better-sqlite3 |
| `CF_PAGES=1` | `cloudflare-pages` | Cloudflare D1（`bindingName: NEWSNOW_DB`，需在 `wrangler.toml` 配 `database_id/name`，参考 `example.wrangler.toml`） |
| `VERCEL` | `vercel-edge` | 需自配在线数据库 |
| `BUN` | `bun` | bun-sqlite |

- Cloudflare Pages：构建命令 `pnpm run build`，输出目录 `dist/output/public`。
- Docker：`docker compose up`（见 `docker-compose.yml` / `docker-compose.local.yml`）。
- MCP server：README 中给出 `newsnow-mcp-server` 配置，`BASE_URL` 指向本实例域名。

## 开发约定与注意事项

- **Node ≥ 20**，包管理器固定 pnpm 10。
- 改源定义改 `shared/pre-sources.ts`；加抓取器在 `server/sources/` 新建 `<id>.ts` 并 `export default defineSource(...)`——`getters.ts` 会自动收录，无需手动注册。
- `shared/sources.json` / `sources.ts` / `pinyin.json` / `updated-sources.ts` 是构建产物，不要手改。
- `db0` 的 D1 与 sqlite 返回结构不同（D1 `.all()` 包一层 `results`），`server/database/cache.ts#getEntire` 已做兼容处理，新增数据库相关代码需注意。
- 提交前 `simple-git-hooks` 会跑 `lint-staged`（`eslint --fix`）。
- dayjs 通过 `patches/dayjs.patch` 打补丁（`pnpm.patchedDependencies`）。
- `pnpm.overrides`/`resolutions` 锁定了 h3-nightly、nitro-go、vite、react 等版本，升级依赖时需留意。

## Git 工作流（fork 定制）

本仓库 fork 自 `ourongxing/newsnow`，采用 **main 跟踪上游 + custom 分支定制** 模式。

### Remotes

| remote | 仓库 | 用途 |
|---|---|---|
| `origin` | `DEFICITT/ai-team-newsnow` | 你的 fork，推送代码 |
| `upstream` | `ourongxing/newsnow` | 原项目，拉取更新 |

### 分支

- `main`：**仅用于同步上游**，保持与 `upstream/main` 一致，**不在此直接开发**。
- `custom`：**定制开发分支**，所有自己的修改都在此提交（当前默认分支）。

### 常用操作

```bash
# 首次推送 custom 到你的 fork（设置追踪）
git push -u origin custom

# 日常提交
git add -A && git commit -m "..."
git push

# 同步上游更新（原项目有新内容时）
git checkout main
git fetch upstream            # 国内拉 GitHub 可能慢，失败见下方提示
git merge upstream/main
git checkout custom
git merge main                # 把上游更新合进定制分支，解冲突后继续
git push origin custom
```

### 注意

- 国内拉 `upstream`（GitHub）可能超时，可走 Gitee 中转或浅克隆 `--depth=1`。
- 给原项目提 PR 是另一套流程：从 `main` 切 feature 分支 → 推到 `origin` → 在 GitHub 向 `upstream` 发 PR，**不要用 custom 分支提 PR**。

## 关键文件速查

| 想了解 | 看这里 |
|---|---|
| 源定义与刷新间隔 | `shared/pre-sources.ts` |
| 源类型推导 | `shared/types.ts` |
| 缓存/刷新核心逻辑 | `server/api/s/index.ts` |
| 抓取器自动注册 | `server/getters.ts` |
| 抓取器写法范例 | `server/sources/ithome.ts` |
| 登录/鉴权 | `server/middleware/auth.ts`、`server/api/oauth/github.ts` |
| 数据库表结构 | `server/database/cache.ts`、`server/database/user.ts` |
| 列与元数据 | `shared/metadata.ts` |
| 构建期生成 | `scripts/source.ts` |
| 部署/preset | `nitro.config.ts` |
| 别名/自动导入/插件 | `vite.config.ts` |
