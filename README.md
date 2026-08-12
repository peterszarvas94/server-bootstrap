# Server Bootstrap

Non-interactive bootstrap script for a clean Ubuntu server. It creates an
admin user, installs common tools, configures SSH and UFW, optionally installs
Tailscale, and installs the machine report shown on interactive login.

## Requirements

- A clean Ubuntu server
- SSH access as `root`
- Root's `/root/.ssh/authorized_keys` must exist
- The new admin username must not already exist

The script is not intended for already configured or partially configured
servers.

## Usage

```bash
chmod +x secure_server_bootstrap.sh
./secure_server_bootstrap.sh \
  --host=203.0.113.10 \
  --user=root \
  --new-user=peti \
  --hostname=server-1 \
  --tailscale=tskey-auth-your-key
```

Required options:

- `--host=HOST`: server IP or DNS name
- `--user=root`: SSH user; must be `root`
- `--new-user=USERNAME`: admin user to create
- `--hostname=NAME`: hostname to assign to the server
- `--tailscale=false|AUTH_KEY`: skip Tailscale or connect using an auth key

Optional:

- `--ssh-port=PORT`: SSH port, defaults to `22`
- `--help`: show usage

Create a Tailscale auth key at:
<https://login.tailscale.com/admin/settings/keys>

The auth key is passed on the command line and may appear in shell history or
process listings. Use a short-lived, appropriately scoped key.

## What It Configures

- Disables root SSH login and password authentication
- Creates the admin user with root's authorized SSH key
- Enables passwordless sudo and Docker access for the admin user
- Installs Docker, Compose, UFW, Fail2ban, Git, curl, mise, and `lastlog2`
- Sets the system hostname
- Installs the machine report at `/usr/local/bin/machine_report.sh` and in the admin user's home directory
- Removes Ubuntu's standard MOTD and separate SSH `Last login` output
- Allows incoming TCP ports `22`, `80`, and `443`
- If Tailscale is enabled, allows SSH through `tailscale0` as well

## SSH Host Keys

The script removes stale local `known_hosts` entries for the supplied host and
hostname before connecting. A newly generated server host key is accepted on
the first connection.

## License

MIT. The included machine report retains its original BSD 3-Clause license.
