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

## License

MIT

Original license (BSD 3-Clause) also included for machine report.
