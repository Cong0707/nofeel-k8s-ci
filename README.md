# nofeel-k8s-ci

`nofeel-k8s-ci` 是 NoFeelCaptcha 的公开 CI 仓库。它只在手动触发时执行：构建
已经锁定的 `nofeel-k8s` 源码和组件，推送不可变 GHCR 镜像，然后通过 OVH 上的
固定部署入口更新 Kubernetes。

## 部署边界

仓库归 `Cong0707` 个人账号管理。生产工作流有以下固定边界：

- 触发器只有 `workflow_dispatch`，没有 `push`、`pull_request` 或定时任务。
- 源码版本来自 `config/nofeel-k8s.lock`，触发时不能通过输入参数替换。
- 只有提交到受保护 `main` 的锁定版本才会进入生产流程。
- GHCR 镜像使用 `ghcr.io/cong0707/*@sha256:...`，不使用 `latest`。
- OVH 只接受五行固定 manifest，不接受远程 Shell 命令、脚本或文件上传。
- SSH 使用现有 `root` 账户中的专用 forced-command 公钥，不创建额外 Linux 用户。
- GitHub Actions 不持有 kubeconfig、数据库密码、GHCR 拉取 token 或 NoFeel 运行时
  Secret。

GitHub 个人仓库没有原生的“只能点击 `workflow_dispatch`”角色。如果需要合作方
在 Actions 页面手动触发，最小可用权限是仓库 `Write`；必须同时保护 `main`、限制
生产 Environment 只接受 `main`，并设置 `ALLOWED_TRIGGER_ACTORS`。如果不希望给
任何人仓库写权限，则由仓库所有者手动触发工作流。

## 工作流

```text
锁定 commit
  -> checkout nofeel-k8s 与组件
  -> 验证 Kustomize 和构建输入
  -> 构建 server/browser-assets/runtime/frontend
  -> 推送 GHCR 并取得 digest
  -> 通过 root forced-command SSH 发送五行 manifest
  -> OVH 执行 state -> migration -> app rollout
```

生产服务器不会执行收到的脚本。服务器上的部署程序会从个人 CI 仓库受保护的
`main` 重新读取 `config/nofeel-k8s.lock`，确认 manifest 中的 commit 完全一致，
再从受限的 GitHub Deploy Key 取得源码并在本地生成临时 Kustomize overlay；部署
结束后删除生成目录。

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
`DEPLOY_SSH_PRIVATE_KEY`。这把 key 仅能调用固定部署协议，不能获得普通 root
Shell。

### 2. 在 OVH 安装固定部署入口

登录 `root@51.81.242.220` 后执行：

```bash
set -Eeuo pipefail
install -d -m 0700 /root/kubenetes
cd /root/kubenetes
if [[ ! -d nofeel-k8s-ci/.git ]]; then
  git clone https://github.com/Cong0707/nofeel-k8s-ci.git
fi
git -C nofeel-k8s-ci fetch origin main
git -C nofeel-k8s-ci checkout --force main
git -C nofeel-k8s-ci reset --hard origin/main
bash /root/kubenetes/nofeel-k8s-ci/server/install-nofeel-ci.sh
```

安装程序只放置 root-owned 固定脚本、`/run/nofeel-ci` 临时目录和 tmpfiles 配置，
不会创建系统用户或 sudoers 规则。

### 3. 把 CI 公钥加入 root 的 forced-command authorized_keys

仍在 OVH，将第 1 步输出的整行公钥放入变量。不要覆盖原有 root key：

```bash
CI_PUBLIC_KEY='ssh-ed25519 AAAA_REPLACE_ME nofeel-k8s-ci@github-actions'
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
printf 'restrict,no-user-rc,command="/usr/local/sbin/nofeel-ci-gateway" %s\n' \
  "$CI_PUBLIC_KEY" >> /root/.ssh/authorized_keys
```

这条 key 具备以下限制：无交互终端、无端口转发、无 Agent/X11 转发、无用户 rc、
无远程命令。现有 root 管理 key 不受影响。

### 4. 为服务器准备 `nofeel-k8s` 只读 Deploy Key

在 OVH 执行：

```bash
set -Eeuo pipefail
install -d -m 0700 /root/.ssh
if [[ ! -s /root/.ssh/nofeel-k8s-readonly ]]; then
  ssh-keygen -t ed25519 -a 100 -N '' \
    -C 'ovh-nofeel-k8s-readonly' \
    -f /root/.ssh/nofeel-k8s-readonly
fi
chmod 0600 /root/.ssh/nofeel-k8s-readonly
chmod 0644 /root/.ssh/nofeel-k8s-readonly.pub
cat /root/.ssh/nofeel-k8s-readonly.pub
```

把输出公钥添加到 `NoFeelCaptcha/nofeel-k8s`：

```text
Settings -> Deploy keys -> Add deploy key
Title: ovh-nofeel-k8s-readonly
Allow write access: 不勾选
```

完成 GitHub host key 的人工核对后，在 OVH 执行：

```bash
ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts
chmod 0600 /root/.ssh/known_hosts
if [[ ! -d /root/kubenetes/nofeel-k8s/.git ]]; then
  GIT_SSH_COMMAND='ssh -i /root/.ssh/nofeel-k8s-readonly -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' \
    git clone git@github.com:NoFeelCaptcha/nofeel-k8s.git /root/kubenetes/nofeel-k8s
fi
GIT_SSH_COMMAND='ssh -i /root/.ssh/nofeel-k8s-readonly -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' \
  git -C /root/kubenetes/nofeel-k8s fetch origin main
```

### 5. 在集群中创建 GHCR 拉取 Secret

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

### 6. 采集 OVH host key

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
| `DEPLOY_KNOWN_HOSTS` | 第 6 步核对后的完整 host key 行 |
| `NOFEEL_REPOSITORIES_TOKEN` | 可读取 `nofeel-k8s`、`nofeel-server`、`nofeel-browser`、`nofeel-frontend` 的 fine-grained PAT |
| `GHCR_WRITE_USERNAME` | `Cong0707` 的 GitHub 用户名 |
| `GHCR_WRITE_TOKEN` | 仅用于推送个人 GHCR 包的 `write:packages` token |

添加以下 Environment Variables：

| 名称 | 值 |
| --- | --- |
| `DEPLOY_HOST` | `51.81.242.220` |
| `DEPLOY_USER` | `root` |

在仓库级 `Settings -> Secrets and variables -> Actions -> Variables` 添加：

| 名称 | 值 |
| --- | --- |
| `ALLOWED_TRIGGER_ACTORS` | 允许手动触发的 GitHub 用户名，逗号分隔；例如 `Cong0707,partner-login` |

如果四个 NoFeel 仓库都是公开的，可以省略 `NOFEEL_REPOSITORIES_TOKEN`，但私有仓库
场景应保留它。GHCR token 只需 `write:packages`，不要赋予仓库写权限。

## `main` 与触发权限

在个人仓库设置中完成：

1. 为 `main` 创建 branch protection rule。
2. 禁止直接 push，要求 Pull Request。
3. 要求至少一名指定 reviewer，并要求 `CODEOWNERS` 审核
   `.github/workflows/**`、`server/**`、`config/**`。
4. `production` Environment 的 Deployment branches 设置为 `main`。
5. 按需启用 Required reviewers；启用后每次生产部署会等待指定审核。
6. Actions 的默认 `GITHUB_TOKEN` 权限设为只读；镜像推送使用上面的
   `GHCR_WRITE_TOKEN`。

合作方若需要在 Actions 页面点击 `Run workflow`，给其仓库 `Write` 权限，并只把
其账号加入 `ALLOWED_TRIGGER_ACTORS`。工作流仍只接受 `main`，并且只能构建
`config/nofeel-k8s.lock` 中已经提交的版本。更新源代码版本时，由仓库所有者提交
一个只修改 lock 文件的 Pull Request，审核通过后再触发部署。

## 首次无副作用测试

在管理员电脑执行：

```powershell
$Key = "$HOME\.ssh\nofeel-k8s-ci-deploy"
"version=0" | ssh -T -i $Key -o IdentitiesOnly=yes root@51.81.242.220
```

预期结果是 `unsupported release manifest version`，不会获得 Shell。以下命令也
必须失败：

```powershell
ssh -i $Key root@51.81.242.220 uname -a
ssh -i $Key -L 15432:127.0.0.1:5432 root@51.81.242.220
```

确认测试结果后，Actions -> `NoFeelCaptcha production deploy` -> `Run workflow`，
选择 `confirm_production=true`。workflow 不接受源码 ref 输入，回滚需要由仓库所有者
审核并修改 `config/nofeel-k8s.lock`。

## 撤销与轮换

立即撤销 CI SSH 入口：

```bash
sed -i '\|nofeel-ci-gateway|d' /root/.ssh/authorized_keys
```

轮换 CI key 时重新执行第 1、3、6 步并更新两个 GitHub Environment Secret。轮换
GitHub Deploy Key 时删除仓库旧 Deploy Key，再执行第 4 步。部署记录和入口日志可用
以下命令查看：

```bash
journalctl -t nofeel-ci-gateway
kubectl -n nofeel get deploy nofeel-api nofeel-worker nofeel-frontend
```
