# setup-security.sh

Security baseline: SSH hardening with anti-lockout protection, unified firewall configuration (UFW / firewalld), and a listening-port audit against the declared policy.

## Safety Model (Anti-Lockout)

Hardening only proceeds when every precondition holds — otherwise the script exits **before** changing anything:

1. `RIG_ADMIN_USER` must be a non-root account that exists, has an unlocked password field (when `UsePAM` is off), belongs to `sudo`/`wheel`/`admin`, and — when running as root — passes `sudo -n -l -U <user>`.
2. The user must have at least one public key in the **effective** `AuthorizedKeysFile` (resolved via `sshd -T`, honoring `%u`/`%h`/`%%` tokens), with safe permissions on `$HOME`, `~/.ssh`, and the key file itself.
3. `AllowUsers`/`DenyUsers`/`AllowGroups`/`DenyGroups` must not exclude the admin user.
4. When `RIG_SSH_ACCESS=tailscale`, Tailscale must be installed **and** connected.

The candidate `sshd_config` is rendered into a temporary file and must pass `sshd -t` **before** the firewall is touched or the live config is replaced. If the post-install check or the service reload fails, the previous config is restored automatically. Policy is written to `~/.config/rig/config` only after every step succeeds.

## What Gets Configured

| Item | Description |
|------|-------------|
| SSH port | `Port` directive rendered into the global section (never inside `Match` blocks) |
| Root login | `PermitRootLogin` (`no` / `prohibit-password` / `yes`) |
| Password auth | `PasswordAuthentication` + `KbdInteractiveAuthentication no` |
| Public key auth | `PubkeyAuthentication` |
| Firewall | Backend auto-detected (`ufw` on Debian/Ubuntu, `firewalld` on Fedora/RHEL/Arch); default inbound `deny`, outbound `allow` |
| Public ports | `RIG_PUBLIC_TCP` / `RIG_PUBLIC_UDP` opened; ports removed from the config are reconciled away |
| Tailscale mode | SSH port bound to a dedicated `rig-tailscale` DROP zone (firewalld) or `in on tailscale0` (ufw) |
| Port audit | Compares `ss -lntup` listeners against declared policy + live firewall rules |

## Firewall Behavior

- **ufw**: `allow <port>/tcp`, interface-restricted rules via `in on tailscale0`, `default deny incoming` / `allow outgoing`.
- **firewalld**: permanent `--add-port` rules in the public zone; default broad `ssh`/`cockpit` services are removed so the declared port list is the real policy; Tailscale restriction uses a `rig-tailscale` zone bound to `tailscale0`.
- Reconciliation: ports dropped from `RIG_PUBLIC_TCP`/`RIG_PUBLIC_UDP` since the last run get their allow rules removed.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RIG_ADMIN_USER` | `$SUDO_USER` or `whoami` | Non-root admin used for lockout verification |
| `RIG_SSH_PORT` | current `Port` | SSH listening port |
| `RIG_SSH_ROOT_LOGIN` | `no` | `PermitRootLogin` value |
| `RIG_SSH_PASSWORD_AUTH` | `no` | `PasswordAuthentication` value |
| `RIG_SSH_PUBKEY_AUTH` | `yes` | `PubkeyAuthentication` value |
| `RIG_SSH_ACCESS` | `public` | `public` or `tailscale` (SSH limited to tailscale0) |
| `RIG_FIREWALL` | `auto` | `auto` / `ufw` / `firewalld` / `none` |
| `RIG_FIREWALL_DEFAULT_IN` | `deny` | Inbound default policy |
| `RIG_FIREWALL_DEFAULT_OUT` | `allow` | Outbound default policy (`deny` is rejected on firewalld) |
| `RIG_PUBLIC_TCP` | SSH port | Comma-separated public TCP ports |
| `RIG_PUBLIC_UDP` | _(empty)_ | Comma-separated public UDP ports |
| `RIG_CHECK_LISTENING_PORTS` | `yes` | Run the listening-port audit |
| `RIG_WARN_UNDECLARED_PORTS` | `yes` | Warn on listeners exposed without a declared rule |

## Files Modified

| File | Description |
|------|-------------|
| `/etc/ssh/sshd_config` | Backed up to `~/.local/share/rig/backups/system/` before every change |
| `~/.config/rig/config` | Persisted policy, written only on full success |

## Re-run Behavior

Idempotent: existing rules are skipped, undeclared ports are reconciled, and `sshd_config` is re-rendered + re-preflighted each run. `--yes` / `--non-interactive` skips the interactive policy prompt.

The interactive prompt covers: SSH access scope, `PermitRootLogin`, `PasswordAuthentication`, `PubkeyAuthentication`, SSH port, and extra public TCP ports. If the anti-lockout guard reports `PubkeyAuthentication is 'no'`, the live sshd config disables key login — find it with `sudo grep -rni pubkeyauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/`, enable it, verify a key login in a new session, then re-run to disable password auth.

## Dependencies

- `sudo` required; read-only audit paths use `sudo -n` and never prompt.
- `sshd -t` for preflight (creates `/run/sshd` on Debian-family systems when missing).
- `ss` for the listening-port audit (`sudo -n ss -lntup` with unprivileged fallback).
