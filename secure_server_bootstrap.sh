#!/usr/bin/env bash
set -euo pipefail

# One-shot server hardening bootstrap.
# Run from your local machine. It connects as root (password prompt via SSH),
# creates an admin user using the existing root authorized_keys, then hardens
# SSH + firewall.

HOST="${HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
ADMIN_USER="${ADMIN_USER:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MACHINE_REPORT_SCRIPT_PATH="$SCRIPT_DIR/machine_report.sh"

if [ -z "$HOST" ]; then
  read -r -p "Server host (IP or DNS): " HOST
fi

if [ -z "$ADMIN_USER" ]; then
  read -r -p "New admin username: " ADMIN_USER
fi

if [ -z "$HOST" ]; then
  echo "Host is required." >&2
  exit 1
fi

if [ -z "$ADMIN_USER" ]; then
  echo "Admin username is required." >&2
  exit 1
fi

if [ ! -f "$MACHINE_REPORT_SCRIPT_PATH" ]; then
  echo "Machine report script not found at: $MACHINE_REPORT_SCRIPT_PATH" >&2
  exit 1
fi

MACHINE_REPORT_SCRIPT_B64="$(base64 -w 0 "$MACHINE_REPORT_SCRIPT_PATH")"

echo "[1/4] Connecting as root on $HOST:$SSH_PORT (you may be asked for root password)..."

ssh -p "$SSH_PORT" root@"$HOST" \
  ADMIN_USER="$ADMIN_USER" \
  SSH_PORT="$SSH_PORT" \
  MACHINE_REPORT_SCRIPT_B64="$MACHINE_REPORT_SCRIPT_B64" \
  'bash -s' <<'EOF'
set -euo pipefail

echo "[Preflight] Checking SSH prerequisites..."

# Verify SSH service is running
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
  echo "ERROR: SSH service is not running" >&2
  exit 1
fi

# Check for root's authorized_keys before making any changes
if [ ! -f /root/.ssh/authorized_keys ]; then
  echo "ERROR: /root/.ssh/authorized_keys does not exist" >&2
  echo "Cannot copy SSH keys to new admin user. Aborting." >&2
  exit 1
fi

# Ensure /run/sshd exists (required for SSH privilege separation)
mkdir -p /run/sshd
chmod 755 /run/sshd

# Detect SSH service name
if systemctl list-units --type=service | grep -q 'sshd.service'; then
  SSH_SERVICE="sshd"
elif systemctl list-units --type=service | grep -q 'ssh.service'; then
  SSH_SERVICE="ssh"
else
  echo "ERROR: Cannot detect SSH service name (tried 'ssh' and 'sshd')" >&2
  exit 1
fi

echo "[Preflight] SSH service detected: $SSH_SERVICE"
echo "[Preflight] All checks passed, proceeding with bootstrap..."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y sudo ufw fail2ban docker.io docker-compose-v2 curl git
systemctl enable --now docker

if ! command -v mise >/dev/null 2>&1; then
  curl https://mise.run | sh
  if [ -x /root/.local/bin/mise ]; then
    install -m 0755 /root/.local/bin/mise /usr/local/bin/mise
  fi
fi

if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$ADMIN_USER"
fi

usermod -aG sudo "$ADMIN_USER"
usermod -aG docker "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/99-$ADMIN_USER-nopasswd
chmod 440 /etc/sudoers.d/99-$ADMIN_USER-nopasswd
visudo -cf /etc/sudoers >/dev/null

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
touch "/home/$ADMIN_USER/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"

# Copy root's authorized_keys (already verified it exists in preflight)
cat /root/.ssh/authorized_keys >> "/home/$ADMIN_USER/.ssh/authorized_keys"
sort -u "/home/$ADMIN_USER/.ssh/authorized_keys" -o "/home/$ADMIN_USER/.ssh/authorized_keys"

echo "[Machine Report] Installing login machine report..."
MACHINE_REPORT_TMP="$(mktemp /tmp/machine_report.XXXXXX.sh)"
printf '%s' "$MACHINE_REPORT_SCRIPT_B64" | base64 -d >"$MACHINE_REPORT_TMP"

# Fix invalid zfs detection check in upstream script.
sed -i 's/if \[ "$(command -v zfs)" \] && \[ "$(grep -q "zfs" \/proc\/mounts)" \]; then/if command -v zfs >\/dev\/null 2>\&1 \&\& grep -q "zfs" \/proc\/mounts; then/' "$MACHINE_REPORT_TMP"

install -m 0755 "$MACHINE_REPORT_TMP" /usr/local/bin/machine_report.sh
install -m 0755 "$MACHINE_REPORT_TMP" "/home/$ADMIN_USER/.machine_report.sh"
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.machine_report.sh"
rm -f "$MACHINE_REPORT_TMP"

BASHRC="/home/$ADMIN_USER/.bashrc"
touch "$BASHRC"
chown "$ADMIN_USER:$ADMIN_USER" "$BASHRC"

if ! grep -q "machine_report.sh" "$BASHRC"; then
  cat >>"$BASHRC" <<'BASHRC_SNIPPET'

# Machine report on interactive shell startup
if [[ $- == *i* ]] && [ -x "$HOME/.machine_report.sh" ]; then
  "$HOME/.machine_report.sh"
fi
BASHRC_SNIPPET
fi

echo "[SSH] Hardening SSH configuration..."
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-hardening.conf <<SSHCONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
SSHCONF

# Ensure /run/sshd exists before testing config
mkdir -p /run/sshd
chmod 755 /run/sshd

# Test SSH configuration
echo "[SSH] Testing SSH configuration..."
if ! sshd -t 2>/dev/null; then
  echo "ERROR: SSH configuration test failed" >&2
  sshd -t
  exit 1
fi

# Reload SSH service (using detected service name)
echo "[SSH] Reloading SSH service..."
systemctl reload "$SSH_SERVICE"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl enable --now fail2ban

echo "[Bootstrap] Server bootstrap complete. Rebooting in 5 seconds..."
sleep 5
reboot
EOF

echo "[2/4] Server is rebooting to apply all changes..."
echo "Waiting 30 seconds for server to restart..."
sleep 30

echo "[3/4] Verifying SSH access as '$ADMIN_USER'..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$SSH_PORT" "$ADMIN_USER@$HOST" "whoami" >/dev/null 2>&1; then
  echo "Failed to verify SSH login for $ADMIN_USER. Check key/agent and try: ssh -p $SSH_PORT $ADMIN_USER@$HOST" >&2
  exit 1
fi

echo "[4/4] Verifying root SSH is blocked..."
if ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" root@"$HOST" "whoami" >/dev/null 2>&1; then
  echo "WARNING: root SSH still appears enabled. Check /etc/ssh/sshd_config.d/99-hardening.conf" >&2
else
  echo "Root SSH is blocked (expected)."
fi

echo "[5/5] Done."
echo "Bootstrap complete! Server is secured and ready."
echo "You can now use: ssh -p $SSH_PORT $ADMIN_USER@$HOST"
