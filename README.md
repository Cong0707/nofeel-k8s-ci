# nofeel-k8s-ci

`nofeel-k8s-ci` 是 NoFeelCaptcha 的公开 CI 仓库。白名单用户通过一次性部署
Issue 触发，仓库所有者也可以从 Actions 页面直接 Trigger。两种入口都要求指定
`nofeel-k8s` 的完整 commit，构建该提交及其组件，推送不可变 GHCR 镜像，然后通过
OVH 已有的 SSH 与 `kubectl` 更新 Kubernetes。Issue 入口完成后会写入结果并自动关闭该 Issue。

## 部署边界

仓库归 `Cong0707` 个人账号管理。生产工作流有以下固定边界：

- 触发器只有新建 Issue 和 `workflow_dispatch`，没有 `push`、`pull_request`、
  评论或定时任务。
- 只有 `ALLOWED_TRIGGER_ACTORS` 中精确列出的 GitHub 用户名可以通过部署表单
  启动生产 job；其他账号创建的 Issue 会直接关闭。
- `workflow_dispatch` 只接受仓库所有者 `Cong0707`，并要求显式勾选生产确认。
- 授权门禁不使用 `production` Environment，也读取不到部署 Secret；只有门禁通过
  后的 job 才能使用生产 Environment。
- Issue 表单和 `workflow_dispatch` 都必须填写 40 位 `nofeel-k8s` commit。
- CI 会确认该 commit 属于 `nofeel-k8s` 受保护 `main` 的历史。
- GHCR 镜像使用 `ghcr.io/cong0707/*@sha256:...`，不使用 `latest`。
- Kustomize 清单在 GitHub Runner 临时目录中渲染，通过 SSH 标准输入交给 OVH 已有的
  `kubectl`，不在 OVH 安装 CI 程序、保存源码仓库或仓库 PAT。
- SSH 使用现有 `root` 账户中的专用公钥，不创建额外 Linux 用户；该 key 具备非交互
  root 命令权限，因此必须由个人仓库的分支保护和 `production` Environment 共同保护。
- GitHub Actions 不持有 kubeconfig、数据库密码、GHCR 拉取 token 或 NoFeel 运行时
  Secret。

合作方不需要成为仓库 Collaborator，也不需要 `Write` 权限。公开仓库允许其提交
部署 Issue，工作流再用 `ALLOWED_TRIGGER_ACTORS` 做大小写不敏感的完整用户名
匹配。Issue 只能选择完整 commit，不能选择源码分支或标签，每个新 Issue 只触发一次，重新打开
或评论都不会重新部署。

## 工作流

```text
打开并确认一次性部署 Issue，或由仓库所有者直接 Trigger
  -> 校验 ALLOWED_TRIGGER_ACTORS/Issue 表单或所有者身份
  -> 校验指定 commit 属于 nofeel-k8s/main
  -> checkout nofeel-k8s 与组件
  -> 验证 Kustomize 和构建输入
  -> 构建 server/browser-assets/runtime/frontend
  -> 推送 GHCR 并取得 digest
  -> Runner 渲染 state/migration/app 清单
  -> 通过 root SSH 调用 OVH 已有 kubectl 完成 rollout
```

生产服务器不保存 CI 脚本、NoFeel 源码或仓库 PAT。Runner 只发送渲染后的 Kubernetes
清单并执行固定的部署顺序；清单和 SSH 私钥均在 job 结束时从 Runner 临时目录删除。

## 一次性配置

以下命令按顺序执行。命令中的 `REPLACE_*` 只替换为你自己的值。私钥和 token
不要写入仓库、Issue、聊天记录或日志。

### 1. 生成 CI 专用 SSH key

在管理员电脑 PowerShell 执行：

```powershell
$Key = "$HOME\.ssh\nofeel-k8s-ci-deploy"
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
ssh-keygen -t ed25519 -a 100 -N "" -C "nofeel-k8s-ci@github-actions" -f $Key
Get-Content "$Key.pub"
Get-Content -Raw $Key | Set-Clipboard
```

公钥用于下一步；剪贴板中的完整私钥用于 GitHub Environment Secret
`DEPLOY_SSH_PRIVATE_KEY`。该私钥只保存在个人仓库的 `production` Environment，
但它具备执行非交互 root 命令的能力，因此必须启用主分支保护和 Environment 审核。

### 2. 把 CI 公钥加入 root 的 authorized_keys

登录 `root@51.81.242.220`，将第 1 步输出的整行公钥放入变量。不要覆盖原有 root key：

```bash
CI_PUBLIC_KEY='ssh-ed25519 AAAA_REPLACE_ME nofeel-k8s-ci@github-actions'
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
printf 'restrict,no-user-rc %s\n' "$CI_PUBLIC_KEY" >> /root/.ssh/authorized_keys
```

`restrict` 禁止 PTY、端口转发、Agent/X11 转发和用户 rc，但不会限制远程命令本身。
该 key 因此仍等同于非交互 root 部署权限，只能存放在个人仓库受保护的
`production` Environment 中。

OVH 不需要安装 GitHub Runner、CI gateway、部署 helper、额外 systemd 服务或软件包，
也不需要保存 NoFeel 仓库 PAT 和源码副本。工作流在 GitHub Runner 上完成构建与
Kustomize 渲染，再通过 SSH 标准输入交给 OVH 已有的 `/usr/bin/kubectl`。

### 3. 在集群中创建 GHCR 拉取 Secret

该 Secret 只存在 Kubernetes，不进入 GitHub：

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
read -r -p 'GHCR username: ' GHCR_USER
read -r -s -p 'GHCR read:packages token: ' GHCR_TOKEN
echo
kubectl -n nofeel create secret docker-registry nofeel-ghcr \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_USER}" \
  --docker-password="${GHCR_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset GHCR_USER GHCR_TOKEN
kubectl -n nofeel get secret nofeel-ghcr
```

### 4. 采集 OVH host key

在管理员电脑执行并人工核对指纹：

```powershell
ssh-keyscan -t ed25519 51.81.242.220 | Set-Content -Encoding ascii "$HOME\.ssh\nofeel-ovh-known-hosts"
ssh-keygen -lf "$HOME\.ssh\nofeel-ovh-known-hosts"
Get-Content -Raw "$HOME\.ssh\nofeel-ovh-known-hosts" | Set-Clipboard
```

剪贴板内容用于 `DEPLOY_KNOWN_HOSTS`。如果 OVH 的公网 IP 发生变化，应重新核对
并更新该 Secret。

## GitHub Environment 配置

在个人仓库的 `Settings -> Environments -> production` 创建 Environment。添加以下
Secrets：

| 名称 | 内容 |
| --- | --- |
| `DEPLOY_SSH_PRIVATE_KEY` | 第 1 步生成的完整 CI 私钥 |
| `DEPLOY_KNOWN_HOSTS` | 第 4 步核对后的完整 host key 行 |
| `NOFEEL_REPOSITORIES_TOKEN` | 可读取 `nofeel-k8s`、`nofeel-server`、`nofeel-browser`、`nofeel-widget`、`nofeel-frontend` 的 fine-grained PAT |

添加以下 Environment Variables：

| 名称 | 值 |
| --- | --- |
| `DEPLOY_HOST` | `51.81.242.220` |
| `DEPLOY_USER` | `root` |

在仓库级 `Settings -> Secrets and variables -> Actions -> Variables` 添加：

| 名称 | 值 |
| --- | --- |
| `ALLOWED_TRIGGER_ACTORS` | 允许创建部署 Issue 的完整 GitHub 用户名，逗号分隔；例如 `Cong0707,partner-login` |

如果这些 NoFeel 仓库都是公开的，可以省略 `NOFEEL_REPOSITORIES_TOKEN`；私有仓库
场景下该 token 仅由 GitHub Runner 读取，不写入 OVH。个人 GHCR 推送使用 workflow
内置 `GITHUB_TOKEN`，无需另建 GHCR 写入 token。

## `main` 与合作方触发权限

在个人仓库设置中完成：

1. 为 `main` 创建 branch protection rule。
2. 禁止直接 push，要求 Pull Request。
3. 要求至少一名指定 reviewer，并要求 `CODEOWNERS` 审核
   `.github/workflows/**` 和 `scripts/**`。
4. `production` Environment 的 Deployment branches 设置为 `main`。
5. 按需启用 Required reviewers；启用后每次生产部署会等待指定审核。
6. 将允许触发的账号写入仓库变量 `ALLOWED_TRIGGER_ACTORS`，无需将其添加为
   Collaborator。
7. Workflow 的授权 job 只有 `issues: write`；部署 job 只有 `contents: read` 与
   `packages: write`，并单独挂载 `production` Environment。

合作方使用仓库的 `New issue -> Production deployment` 表单，勾选确认后提交。
符合白名单和固定表单的 Issue 会启动一次部署；成功、失败或取消后，工作流会回复
运行结果并关闭 Issue。不在白名单中的账号创建 Issue 时只会执行关闭操作，不会进入
构建 job，也不会读取任何生产 Secret。

授权新账号只需将其完整 GitHub 用户名追加到 `ALLOWED_TRIGGER_ACTORS`，以英文逗号
分隔。撤销时从变量中删除用户名即可，不涉及仓库成员权限。部署新版本前先完成对应
Pull Request 审查，合并后再在部署 Issue 或 Actions 表单中填写目标 commit。

仓库所有者也可以在 `Actions -> NoFeelCaptcha production deploy -> Run workflow`
中直接运行，填写 `source_commit`、勾选 `confirm_production` 后提交。该入口不使用合作方白名单，只校验
GitHub 事件中的真实 sender 必须是 `Cong0707`。

## 首次无副作用测试

在管理员电脑执行：

```powershell
$Key = "$HOME\.ssh\nofeel-k8s-ci-deploy"
ssh -T -i $Key -o IdentitiesOnly=yes root@51.81.242.220 \
  "export KUBECONFIG=/etc/kubernetes/admin.conf; kubectl -n nofeel get deployment nofeel-api nofeel-worker nofeel-frontend"
```

预期结果是只读显示三个 Deployment。该 key 可以执行非交互 root 命令；以下转发
命令必须失败：

```powershell
ssh -i $Key -L 15432:127.0.0.1:5432 root@51.81.242.220
```

确认测试结果后，可以提交 `Production deployment` Issue，或由仓库所有者在 Actions
中直接 Trigger，并填写目标 commit。回滚时选择之前已验证的 commit，随后重新触发。

## 撤销与轮换

立即撤销 CI SSH 入口时，按 key 注释删除对应行：

```bash
sed -i '/nofeel-k8s-ci@github-actions/d' /root/.ssh/authorized_keys
```

轮换 CI key 时重新执行第 1、2、4 步并更新两个 GitHub Environment Secret。轮换
源码读取 token 时只更新 GitHub Environment Secret。部署记录和集群状态可用以下
位置查看：

```bash
kubectl -n nofeel get deploy nofeel-api nofeel-worker nofeel-frontend
```
