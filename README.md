# nofeel-k8s-ci

`nofeel-k8s-ci` 是 NoFeelCaptcha 生产部署自动化仓库。它是公开仓库，但生产
workflow **只允许手动触发**，不监听 `push`、`pull_request` 或定时事件。

一次手动运行会完成：

1. 按 `nofeel-k8s` 的 `config/components.lock.yaml` 固定 server、browser、
   frontend commit。
2. 构建 server、browser assets、runtime 和 frontend 四个镜像。
3. 把三个运行时镜像推送到 GHCR，并只使用不可变的 `@sha256` digest。
4. 生成临时生产 Kustomize overlay，注入 GHCR 镜像和拉取 Secret。
5. 通过固定 SSH host key 连接 OVH 控制面，按 `state -> migrate -> app`
   顺序更新。
6. 等待数据库/Redis 就绪、迁移 Job 完成和 API/Worker/Frontend 滚动更新。
7. 失败时自动恢复已经开始更新的应用 Deployment，最后清理远端临时包和凭据。

## 触发方式

打开 GitHub Actions 的 **NoFeelCaptcha production deploy**，点击
**Run workflow**：

- `nofeel_ref`：默认 `main`，也可以填一个已经审核过的 commit 进行回滚。
- `confirm_production`：必须手动勾选 `true`，否则 workflow 立即失败。

建议给 workflow 配置 `production` Environment，并启用 Required reviewers。公开
仓库不会因此公开下面列出的 Secret。

## 一次性配置

### GitHub Environment

在仓库 `Settings -> Environments -> production` 中配置：

| 名称 | 类型 | 用途 |
|---|---|---|
| `DEPLOY_SSH_PRIVATE_KEY` | Secret | 仅允许连接 OVH 的部署私钥 |
| `DEPLOY_KNOWN_HOSTS` | Secret | OVH SSH 公钥的完整 known_hosts 行 |
| `GHCR_PULL_USERNAME` | Secret | 集群拉取 GHCR 的只读账号 |
| `GHCR_PULL_TOKEN` | Secret | 集群拉取 GHCR 的只读 token |
| `NOFEEL_COMPONENTS_TOKEN` | Secret | 读取锁定的组件仓库；组件公开时可省略 |
| `GHCR_WRITE_USERNAME` | Secret，可选 | 推送 GHCR 的账号；默认使用 workflow actor |
| `GHCR_WRITE_TOKEN` | Secret，可选 | 推送 GHCR 的 token；默认使用带 `packages: write` 的 `GITHUB_TOKEN` |

仓库变量：

| 名称 | 推荐值 |
|---|---|
| `DEPLOY_HOST` | `51.81.242.220` |
| `DEPLOY_USER` | `root` |

`GHCR_WRITE_TOKEN` 至少需要 `write:packages`；`GHCR_PULL_TOKEN` 只需要
`read:packages`。不要复用部署 SSH 私钥作为任何 GitHub token。

### SSH known_hosts

在受信任的管理员机器上核对 OVH 指纹后，把完整输出作为
`DEPLOY_KNOWN_HOSTS` Secret。不要让 workflow 运行时执行无校验的
`ssh-keyscan`。

### GHCR 包

workflow 使用以下命名：

```text
ghcr.io/nofeelcaptcha/nofeel-server
ghcr.io/nofeelcaptcha/nofeel-runtime
ghcr.io/nofeelcaptcha/nofeel-frontend
```

可以将包设为 public，使集群不依赖拉取凭据；当前 workflow 仍会创建
`nofeel/nofeel-ghcr`，因此设为 private 也能工作。GHCR token 不会写进镜像、
Kustomize 或 GitHub Step Summary。

## 部署边界

- GitHub runner 不直接访问 Kubernetes API；只通过 OVH 的 SSH 入口执行
  `/etc/kubernetes/admin.conf` 对应的 `kubectl`。
- workflow 不重新生成 `nofeel-secrets`，不删除 PostgreSQL/Redis PVC，不改变
  数据库密码、Bootstrap Token 或签名密钥。
- migration Job 会按现有部署惯例删除后重建；应用迁移必须保持幂等。
- `state` 层只做声明式 reconcile，数据库和 Redis 数据仍由现有 PGO/Rook
  资源管理。
- API、Worker、Frontend 使用 `maxSurge: 0`、`maxUnavailable: 1`，适配目前
  只有 OVH/BWG 两个可调度节点且启用了强制反亲和的拓扑。
- 生产域名、Nginx、PowerDNS、证书和 WAF 不由此 workflow 改动。

## 回滚

优先在 Actions 中重新手动运行，填写已验证的旧 `nofeel-k8s` commit，并勾选
`confirm_production`。Kubernetes Deployment 也保留有限 revision history；
workflow 失败时会自动对已开始更新的应用执行 `rollout undo`。

## 安全约束

- workflow 文件没有自动触发器。
- 所有第三方 action 使用完整 commit SHA 固定版本。
- 镜像禁止 `latest`，部署只接受 GHCR `@sha256`。
- 公共仓库不保存私钥、token、kubeconfig、数据库连接串或 Secret 值。
- 组件通过锁定 commit checkout，构建前检查工作树干净并校验 commit 一致。
