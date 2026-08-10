# Server Bootstrap

This repository contains scripts to bootstrap a new server.

A patched version of the [USGC Machine Report](https://github.com/usgraphics/usgc-machine-report/) is also included.

## Usage

```bash
chmod +x secure_server_bootstrap.sh
./secure_server_bootstrap.sh
```

The script will prompt for server IP/hostname, and new admin username.
It will disable password authentication for SSH, and only allow the new admin user to login via SSH key.
It keeps the login machine report while disabling Ubuntu's standard MOTD and the `Last login` line.

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
