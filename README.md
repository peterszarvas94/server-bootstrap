# Server Bootstrap

This repository contains scripts to bootstrap a new server.

A patched version of the [USGC Machine Report](https://github.com/usgraphics/usgc-machine-report/) is also included.

## Usage

```bash
chmod +x secure_server_bootstrap.sh
./secure_server_bootstrap.sh
```

All arguments are required, so the script is non-interactive. Use `--user=root`;
the script is intended for clean Ubuntu servers only. The new admin user must
not already exist. Tailscale is optional: use `--tailscale=false` to skip it,
or provide an auth key directly.
It disables password authentication for SSH and allows the new admin user to log in using root's existing authorized key.
It keeps the last-login information inside the machine report while disabling Ubuntu's standard MOTD and SSH/PAM's separate `Last login` line.

The script also repairs interrupted package configuration and preselects the
root disk for `grub-pc`, which avoids an interactive GRUB prompt on VPS images.

Create a Tailscale auth key here:
[Tailscale admin keys](https://login.tailscale.com/admin/settings/keys)

Example:

```bash
./secure_server_bootstrap.sh \
  --host=203.0.113.10 \
  --user=root \
  --new-user=peti \
  --hostname=server-1 \
  --tailscale=tskey-auth-your-key
```

To skip Tailscale setup:

```bash
./secure_server_bootstrap.sh \
  --host=203.0.113.10 \
  --user=root \
  --new-user=peti \
  --hostname=server-1 \
  --tailscale=false
```

The auth key is passed on the command line, so it may be visible in shell
history or process listings. Use an appropriately scoped, short-lived key.

## Apply MOTD Fix Once

For a server that was already bootstrapped, run this once from your local machine:

```bash
ssh peti@peterszarvas.hu 'sudo bash -s' <<'EOF'
set -eu

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

if grep -Eq '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so[[:space:]]+motd=/run/motd\.dynamic' /etc/pam.d/sshd; then
  sed -i -E '/^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so[[:space:]]+motd=\/run\/motd\.dynamic/ s/^/# Disabled by server bootstrap: /' /etc/pam.d/sshd
fi

if grep -Eq '^[[:space:]]*session[[:space:]]+.*pam_lastlog\.so' /etc/pam.d/sshd; then
  sed -i -E '/^[[:space:]]*session[[:space:]]+.*pam_lastlog\.so/ s/^/# Disabled by server bootstrap: /' /etc/pam.d/sshd
fi

install -d -m 755 /etc/ssh/sshd_config.d
printf '%s\n' 'PrintLastLog no' >/etc/ssh/sshd_config.d/98-no-last-login.conf
sshd -t
systemctl reload "$(systemctl is-active --quiet ssh && printf ssh || printf sshd)"
EOF
```

This does not modify `/home/peti/.machine_report.sh`; it will continue to run from `.bashrc` on interactive SSH sessions.

## License

MIT

Original license (BSD 3-Clause) also included for machine report.
