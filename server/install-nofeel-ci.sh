#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || { echo 'run this installer as root' >&2; exit 1; }
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

/usr/bin/install -d -o root -g root -m 0700 /run/nofeel-ci
/usr/bin/install -d -o root -g root -m 0700 /root/.ssh
/usr/bin/install -d -o root -g root -m 0700 /root/.config/nofeel-ci
/usr/bin/touch /root/.ssh/authorized_keys
/usr/bin/chown root:root /root/.ssh/authorized_keys
/usr/bin/chmod 0600 /root/.ssh/authorized_keys
if [[ ! -e /root/.config/nofeel-ci/git-credentials ]]; then
  /usr/bin/install -o root -g root -m 0600 /dev/null /root/.config/nofeel-ci/git-credentials
fi
/usr/bin/install -o root -g root -m 0755 "${SCRIPT_DIR}/nofeel-ci-gateway" /usr/local/sbin/nofeel-ci-gateway
/usr/bin/install -o root -g root -m 0755 "${SCRIPT_DIR}/nofeel-ci-deploy" /usr/local/sbin/nofeel-ci-deploy

cat > /etc/tmpfiles.d/nofeel-ci.conf <<'EOF'
d /run/nofeel-ci 0700 root root -
EOF

echo 'Installed fixed NoFeel CI gateway for a forced-command key on root.'
echo 'Add one dedicated forced-command ssh-ed25519 public key to:'
echo '  /root/.ssh/authorized_keys'
