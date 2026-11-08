# SSH Icinga2 NRPE Manager

An interactive Bash utility that scans an IPv4 range for SSH services and runs the
[Icinga2 NRPE Universal Bootstrap Kit](https://github.com/Michdo93/Icinga2-NRPE-Universal-Bootstrap-Kit)
on the selected devices: it logs in, downloads the kit's `install.sh` on the device and runs
it as root. It works like [ssh-dns-manager](https://github.com/Michdo93/ssh-dns-manager) and
[ssh-hostname-manager](https://github.com/Michdo93/ssh-hostname-manager): range → scan →
confirm each device → user name → up to three login attempts.

## Requirements

- Bash 4 or newer, OpenSSH client (`ssh`), `timeout`, `xargs`, `base64` (Linux, WSL, macOS with coreutils).
- Targets: Debian-based Linux (Ubuntu, Debian, Kali, DietPi, Raspberry Pi OS) with an SSH server
  (e.g. [ssh-bootstrap-kit](https://github.com/Michdo93/ssh-bootstrap-kit)) and Internet access
  (GitHub and the package mirrors).
- A remote account that is root or may use `sudo`. The sudo password is typed into the remote
  prompt; root login is not required.

## Run

```bash
chmod +x deploy-nrpe.sh
./deploy-nrpe.sh
```

1. **NRPE settings.** Answer the setup questions once for all devices (recommended) or let the
   wizard of the kit ask on every device.
   - Icinga2 master/satellite address(es), comma separated (IPv4/IPv6, CIDR or host names) →
     `allowed_hosts`
   - standard checks (load, disk, swap, users, processes), SSH check, port discovery, service
     discovery, `nagios-plugins-contrib`, command arguments (`dont_blame_nrpe`)
   - Port and service discovery runs **on each device**, so every host gets the checks for
     what actually runs there.
2. **Range.** First and last IPv4 address, e.g. `192.168.0.1` and `192.168.0.254`.
3. **Scan.** The range is probed for an SSH server on TCP 22 (32 parallel probes, no ping
   needed, no host keys stored while scanning).
4. **Per device.** Confirm, enter the SSH user name and log in (up to three attempts; after
   that the next device follows). The kit's output is shown live; `sudo` asks for the password
   in the same terminal.

At the end the tool lists the configured and the failed devices. Each device also gets
`/etc/nagios/icinga2-services.conf.example` with matching `object Service` definitions
(`check_command = "nrpe"`, `vars.nrpe_command = …`).

Yes accepts `y`, `Y`, `yes`, `Yes`; No accepts `n`, `N`, `no`, `No`; Enter takes the default.

## Options (environment)

| Variable | Default | Meaning |
|---|---|---|
| `SSH_PORT` | `22` | SSH port for scan and login |
| `CONNECT_TIMEOUT` | `4` | seconds per connection attempt |
| `SCAN_PARALLEL` | `32` | parallel probes while scanning |
| `INSTALLER_URL` | kit's `install.sh` on GitHub (`main`) | other installer, e.g. a fork |
| `NRPE_BOOTSTRAP_URL` | – | other `nrpe-bootstrap.py` (passed to the installer) |

```bash
SSH_PORT=2222 ./deploy-nrpe.sh
```

## How it works

The remote part is a short POSIX-sh script. It is sent base64-encoded **as the remote
command** of `ssh -tt` – not on stdin. The remote terminal therefore stays connected to your
keyboard (sudo password, wizard questions), and the script text is never echoed back. The
script checks for Linux/apt and privileges, downloads the installer with `wget` or `curl`
(installs `wget` if neither exists) and runs it with `sudo`. A hidden result marker tells the
local side whether the installer succeeded.

## Limits

- IPv4 ranges only, at most 65,536 addresses per run.
- Linux targets with a POSIX shell; Windows and macOS are skipped.
- Host key checking: new keys are accepted on first login (`accept-new`) and stored in
  `~/.ssh/known_hosts`; a changed key stops the login for that device.

## License

MIT License. Feel free to use and modify.
