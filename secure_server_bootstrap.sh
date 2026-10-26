#!/usr/bin/env bash
set -euo pipefail

# One-shot server hardening bootstrap.
# Run from your local machine against a clean Ubuntu server. It connects as
# root, creates an admin user using root's authorized_keys, then hardens SSH
# and the firewall.

HOST=""
SSH_USER=""
ADMIN_USER=""
SSH_PORT="22"
TARGET_HOSTNAME=""
TAILSCALE_SETUP=""
TAILSCALE_AUTH_KEY=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MACHINE_REPORT_SCRIPT_PATH="$SCRIPT_DIR/machine_report.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./secure_server_bootstrap.sh --host=HOST --user=root
                              --new-user=USERNAME --hostname=HOSTNAME
                              --tailscale=false|AUTH_KEY [--ssh-port=PORT]

Examples:
  ./secure_server_bootstrap.sh --host=203.0.113.10 --user=root \
    --new-user=peti --hostname=server-1 --tailscale=false
  ./secure_server_bootstrap.sh --host=203.0.113.10 --user=root \
    --new-user=peti --hostname=server-1 --tailscale=tskey-auth-...
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --host=*)
      HOST="${arg#*=}"
      ;;
    --user=*)
      SSH_USER="${arg#*=}"
      ;;
    --new-user=*)
      ADMIN_USER="${arg#*=}"
      ;;
    --hostname=*)
      TARGET_HOSTNAME="${arg#*=}"
      ;;
    --ssh-port=*)
      SSH_PORT="${arg#*=}"
      ;;
    --tailscale=false|--tailscale=0|--tailscale=no)
      TAILSCALE_SETUP="no"
      TAILSCALE_AUTH_KEY=""
      ;;
    --tailscale=*)
      TAILSCALE_SETUP="yes"
      TAILSCALE_AUTH_KEY="${arg#*=}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HOST" ] || [ -z "$SSH_USER" ] || [ -z "$ADMIN_USER" ] || [ -z "$TARGET_HOSTNAME" ] || [ -z "$TAILSCALE_SETUP" ]; then
  echo "Required arguments: --host, --user, --new-user, --hostname, and --tailscale." >&2
  usage >&2
  exit 1
fi

if [ "$SSH_USER" != "root" ]; then
  echo "--user must be root. This script only supports clean servers." >&2
  exit 1
fi

if [ "$TAILSCALE_SETUP" = "yes" ] && [ -z "$TAILSCALE_AUTH_KEY" ]; then
  echo "--tailscale requires an auth key or false." >&2
  exit 1
fi

if [[ ! "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Usernames may contain only lowercase letters, digits, underscores, and hyphens." >&2
  exit 1
fi

if [[ ! "$TARGET_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
  echo "Invalid hostname: $TARGET_HOSTNAME" >&2
  exit 1
fi

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
  echo "Invalid SSH port: $SSH_PORT" >&2
  exit 1
fi

if [ ! -f "$MACHINE_REPORT_SCRIPT_PATH" ]; then
  echo "Machine report script not found at: $MACHINE_REPORT_SCRIPT_PATH" >&2
  exit 1
fi

MACHINE_REPORT_SCRIPT_B64="$(base64 -w 0 "$MACHINE_REPORT_SCRIPT_PATH")"
TAILSCALE_AUTH_KEY_B64="$(printf '%s' "$TAILSCALE_AUTH_KEY" | base64 -w 0)"

echo "[1/6] Connecting as root on $HOST:$SSH_PORT..."

SSH_OPTIONS=(-o StrictHostKeyChecking=accept-new -o ControlMaster=no -o ControlPath=none)
ADMIN_SSH_OPTIONS=("${SSH_OPTIONS[@]}" -o BatchMode=yes -o PreferredAuthentications=publickey -o ConnectTimeout=10)

verify_admin_login() {
  if ! ssh "${ADMIN_SSH_OPTIONS[@]}" -p "$SSH_PORT" "$ADMIN_USER@$HOST" 'sudo -n true'; then
    echo "ERROR: Admin key login or passwordless sudo failed. Stopping without reboot." >&2
    return 1
  fi
}

remove_known_hosts_entries() {
  for ssh_host in "$HOST" "$TARGET_HOSTNAME"; do
    ssh-keygen -q -R "$ssh_host" >/dev/null 2>&1 || true
    ssh-keygen -q -R "[$ssh_host]:$SSH_PORT" >/dev/null 2>&1 || true
  done
}

# Remove stale keys after a rebuild or IP reassignment. SSH still verifies a
# newly received key after these entries are removed.
remove_known_hosts_entries

ssh "${SSH_OPTIONS[@]}" -p "$SSH_PORT" "$SSH_USER@$HOST" \
  ADMIN_USER="$ADMIN_USER" \
  SSH_PORT="$SSH_PORT" \
  TARGET_HOSTNAME="$TARGET_HOSTNAME" \
  TAILSCALE_SETUP="$TAILSCALE_SETUP" \
  TAILSCALE_AUTH_KEY_B64="$TAILSCALE_AUTH_KEY_B64" \
  MACHINE_REPORT_SCRIPT_B64="$MACHINE_REPORT_SCRIPT_B64" \
  'bash -s' <<'EOF'
set -euo pipefail

echo "[Preflight] Checking SSH prerequisites..."

# Detect the active SSH service. Checking the unit directly also works when
# systemd does not include the unit in `list-units` output.
if systemctl is-active --quiet ssh; then
  SSH_SERVICE="ssh"
elif systemctl is-active --quiet sshd; then
  SSH_SERVICE="sshd"
else
  echo "ERROR: SSH service is not running" >&2
  exit 1
fi

# Require a usable public key, not just an existing (possibly empty) file.
if [ ! -s /root/.ssh/authorized_keys ] || ! ssh-keygen -l -f /root/.ssh/authorized_keys >/dev/null 2>&1; then
  echo "ERROR: /root/.ssh/authorized_keys must contain a valid public key" >&2
  echo "Cannot copy SSH keys to the new admin user. Aborting." >&2
  exit 1
fi

if id -u "$ADMIN_USER" >/dev/null 2>&1; then
  echo "ERROR: User '$ADMIN_USER' already exists. This script only supports clean servers." >&2
  exit 1
fi

# Ensure /run/sshd exists (required for SSH privilege separation)
mkdir -p /run/sshd
chmod 755 /run/sshd

echo "[Preflight] SSH service detected: $SSH_SERVICE"
echo "[Preflight] All checks passed, proceeding with bootstrap..."

echo "[Hostname] Setting hostname to $TARGET_HOSTNAME..."
hostnamectl set-hostname "$TARGET_HOSTNAME"

export DEBIAN_FRONTEND=noninteractive
apt-get update

# Some VPS images leave grub-pc unpacked but unconfigured. Preselect the
# device containing / so dpkg can finish without an interactive boot-device
# prompt.
ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
ROOT_DISK=""
if command -v lsblk >/dev/null 2>&1; then
  while read -r parent; do
    ROOT_DISK="/dev/$parent"
    break
  done < <(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null)
fi
if [ -z "$ROOT_DISK" ] && [[ "$ROOT_SOURCE" == /dev/* ]]; then
  ROOT_DISK="$ROOT_SOURCE"
fi
if [ -n "$ROOT_DISK" ] && command -v debconf-set-selections >/dev/null 2>&1; then
  printf '%s\n' \
    "grub-pc grub-pc/install_devices multiselect $ROOT_DISK" \
    'grub-pc grub-pc/install_devices_empty boolean false' | debconf-set-selections
fi
dpkg --configure -a || apt-get -f install -y
apt-get -f install -y
apt-get -y upgrade
packages=(sudo ufw fail2ban curl git)
if command -v docker >/dev/null 2>&1; then
  echo "[Docker] Already installed ($(docker --version)). Skipping docker.io."
else
  echo "[Docker] Installing Docker Engine..."
  packages+=(docker.io)
fi
if docker compose version >/dev/null 2>&1; then
  echo "[Docker] Docker Compose is already available. Skipping docker-compose-v2."
else
  echo "[Docker] Installing Docker Compose..."
  packages+=(docker-compose-v2)
fi
apt-get install -y "${packages[@]}"
# lastlog2 is packaged from Ubuntu 25.04. On 24.04 apt-cache show still
# succeeds because another package mentions the name, but there is no
# installable candidate.
lastlog2_candidate="$(apt-cache policy lastlog2 2>/dev/null | awk '/^  Candidate:/ { print $2; exit }')"
if [ -n "$lastlog2_candidate" ] && [ "$lastlog2_candidate" != "(none)" ]; then
  apt-get install -y lastlog2
else
  echo "[Packages] lastlog2 has no installable candidate. Skipping."
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed." >&2
  exit 1
fi
systemctl enable --now docker

if [ "$TAILSCALE_SETUP" = "yes" ]; then
  echo "[Tailscale] Installing and configuring Tailscale..."
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled
  if ! tailscale ip -4 >/dev/null 2>&1; then
    TAILSCALE_AUTH_KEY="$(printf '%s' "$TAILSCALE_AUTH_KEY_B64" | base64 -d)"
    tailscale up --auth-key="$TAILSCALE_AUTH_KEY"
    unset TAILSCALE_AUTH_KEY
  fi
  echo "[Tailscale] Connected with address: $(tailscale ip -4)"
fi

if ! command -v mise >/dev/null 2>&1; then
  curl https://mise.run | sh
  if [ -x /root/.local/bin/mise ]; then
    install -m 0755 /root/.local/bin/mise /usr/local/bin/mise
  fi
fi

useradd -m -s /bin/bash "$ADMIN_USER"

usermod -aG sudo "$ADMIN_USER"
usermod -aG docker "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/99-$ADMIN_USER-nopasswd
chmod 440 /etc/sudoers.d/99-$ADMIN_USER-nopasswd
visudo -cf /etc/sudoers >/dev/null

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
touch "/home/$ADMIN_USER/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"

# Copy root's authorized_keys (already checked for a valid public key).
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

echo "[MOTD] Removing Ubuntu's standard login messages..."
for motd_script in \
  00-header \
  10-help-text \
  50-landscape-sysinfo \
  50-motd-news \
  80-esm \
  88-esm-announce \
  85-fwupd \
  90-updates-available \
  91-contract-ua \
  95-hwe-eol \
  98-reboot-required
do
  if [ -f "/etc/update-motd.d/$motd_script" ]; then
    chmod a-x "/etc/update-motd.d/$motd_script"
  fi
done

# The empty dynamic MOTD file otherwise produces one blank line before .bashrc.
if grep -Eq '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so[[:space:]]+motd=/run/motd\.dynamic' /etc/pam.d/sshd; then
  sed -i -E '/^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so[[:space:]]+motd=\/run\/motd\.dynamic/ s/^/# Disabled by server bootstrap: /' /etc/pam.d/sshd
fi

# Do not print SSH/PAM's separate "Last login" line. The machine report still
# displays the last-login data inside its own report when available.
if grep -Eq '^[[:space:]]*session[[:space:]]+.*pam_lastlog\.so' /etc/pam.d/sshd; then
  sed -i -E '/^[[:space:]]*session[[:space:]]+.*pam_lastlog\.so/ s/^/# Disabled by server bootstrap: /' /etc/pam.d/sshd
fi

EOF

echo "[2/6] Verifying fresh admin key login before disabling root/password access..."
verify_admin_login

echo "[3/6] Applying SSH hardening and firewall rules as the verified admin..."
ssh "${ADMIN_SSH_OPTIONS[@]}" -p "$SSH_PORT" "$ADMIN_USER@$HOST" \
  "sudo -n env SSH_PORT=$SSH_PORT TAILSCALE_SETUP=$TAILSCALE_SETUP bash -s" <<'EOF'
set -euo pipefail
if systemctl is-active --quiet ssh; then
  SSH_SERVICE=ssh
elif systemctl is-active --quiet sshd; then
  SSH_SERVICE=sshd
else
  echo "ERROR: SSH service is not running" >&2
  exit 1
fi

echo "[SSH] Hardening SSH configuration..."
install -d -m 755 /etc/ssh/sshd_config.d
# sshd keeps the first value it reads, and drop-ins load in name order, so
# 00- wins over image files such as 50-cloud-init.conf.
cat >/etc/ssh/sshd_config.d/00-hardening.conf <<SSHCONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
PrintLastLog no
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

# Reload SSH service (using detected service name). Package installation may
# have stopped the service after the preflight check, so start it if needed.
echo "[SSH] Reloading SSH service..."
systemctl reload-or-restart "$SSH_SERVICE"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
if [ "$TAILSCALE_SETUP" = "yes" ]; then
  ufw allow in on tailscale0 to any port "$SSH_PORT" proto tcp
fi
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl enable --now fail2ban

EOF

echo "[4/6] Verifying admin access with hardened SSH and firewall before reboot..."
verify_admin_login
ssh "${ADMIN_SSH_OPTIONS[@]}" -p "$SSH_PORT" "$ADMIN_USER@$HOST" 'sudo -n reboot'

echo "[5/6] Server is rebooting to apply all changes..."
echo "Waiting 30 seconds for server to restart..."
sleep 30

# Package upgrades or a rebuilt image may have generated a new host key.
remove_known_hosts_entries

echo "[6/6] Verifying SSH access after reboot..."
verify_admin_login

echo "Verifying root SSH is blocked..."
if ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" root@"$HOST" "whoami" >/dev/null 2>&1; then
  echo "WARNING: root SSH still appears enabled. Check /etc/ssh/sshd_config.d/00-hardening.conf" >&2
else
  echo "Root SSH is blocked (expected)."
fi

echo "Bootstrap complete! Server is secured and ready."
echo "You can now use: ssh -p $SSH_PORT $ADMIN_USER@$HOST"
