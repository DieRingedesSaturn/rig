# setup-security.sh

Security baseline: SSH hardening with anti-lockout protection, unified firewall configuration (UFW / firewalld), and a listening-port audit against the declared policy.

## Safety Model (Anti-Lockout)

When restricting root or password login, the admin checks below must pass before firewall or SSH configuration changes. Tailscale connectivity and rejection of an all-authentication-disabled policy apply to every run:

1. `RIG_ADMIN_USER` must be a non-root account that exists, has an unlocked password field (when `UsePAM` is off), belongs to `sudo`/`wheel`/`admin`, and passes a sudo privilege query, including when invoked by a normal user.
2. The user must have at least one public key in the **effective** `AuthorizedKeysFile` (resolved via `sshd -T`, honoring `%u`/`%h`/`%%` tokens), with safe permissions on `$HOME`, `~/.ssh`, and the key file itself.
3. `AllowUsers`/`DenyUsers`/`AllowGroups`/`DenyGroups` must not exclude the admin user.
4. When `RIG_SSH_ACCESS=tailscale`, Tailscale must be installed **and** connected.
5. The candidate must allow the verified admin key through `PubkeyAuthentication`, `AuthenticationMethods`, and the applicable `Match` context. Disabling both password and public-key authentication is rejected.

The candidate is syntax-checked with `sshd -t` and resolved for the admin with `sshd -T -f candidate -C ...` **before** firewall changes. The context uses `SSH_CONNECTION` when available, otherwise localhost; from a local console, set `RIG_SSH_TEST_CONTEXT` to the intended remote connection parameters. This validates configuration, not possession of the private key or successful network login: keep the current session until a new login succeeds.

Current and target SSH ports are protected during the transition. Old rules are withdrawn only after the new SSH listener is verified. Any later failure restores the SSH configuration/service state and firewall snapshot; incomplete rollback is reported explicitly. Policy is staged and atomically saved only after every step succeeds.

## What Gets Configured

| Item | Description |
|------|-------------|
| SSH port | `Port` directive rendered into the global section (never inside `Match` blocks) |
| Root login | `PermitRootLogin` (`no` / `prohibit-password` / `yes`) |
| Password auth | `PasswordAuthentication` + `KbdInteractiveAuthentication no` |
| Public key auth | `PubkeyAuthentication` |
| Firewall | Backend auto-detected (`ufw` on Debian/Ubuntu/Arch, `firewalld` on Fedora/RHEL); default inbound `deny`, outbound `allow` |
| Public ports | `RIG_PUBLIC_TCP` / `RIG_PUBLIC_UDP` opened; ports removed from the config are reconciled away |
| Tailscale mode | SSH port bound to a dedicated `rig-tailscale` DROP zone (firewalld) or `in on tailscale0` (ufw) |
| Port audit | Compares `ss -lntup` listeners against declared policy + live firewall rules |

## Firewall Behavior

- **ufw**: `allow <port>/tcp`, interface-restricted rules via `in on tailscale0`, `default deny incoming` / `allow outgoing`.
- **firewalld**: permanent `--add-port` rules in the public zone; default broad `ssh`/`cockpit` services are removed so the declared port list is the real policy; Tailscale restriction uses a `rig-tailscale` zone bound to `tailscale0`.
- Reconciliation: ports dropped from `RIG_PUBLIC_TCP`/`RIG_PUBLIC_UDP` since the last run get their allow rules removed.
- A stopped firewalld is configured with `firewall-offline-cmd` before startup. Public port rules always name `--zone=public`; a running daemon switches its default zone only after prepared rules are loaded. Other interface/source-bound zones (except the dedicated Tailscale and container zones) require manual policy review and cause preflight refusal.
- Firewall snapshots are kept under `~/.local/share/rig/backups/system/firewall-security.*`. For firewalld, runtime and permanent state are captured separately. Package installations are not uninstalled during rollback.

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
| `RIG_SSH_TEST_CONTEXT` | current SSH connection / localhost | Optional `host=...,addr=...,laddr=...,lport=...` context; Rig supplies `user` |

## Files Modified

| File | Description |
|------|-------------|
| `/etc/ssh/sshd_config` | Backed up to `~/.local/share/rig/backups/system/` before every change |
| `~/.config/rig/config` | Persisted policy, written only on full success |

## Re-run Behavior

Idempotent: existing rules are skipped, undeclared ports are reconciled, and `sshd_config` is re-rendered + re-preflighted each run. `--yes` / `--non-interactive` skips the interactive policy prompt.

The interactive prompt covers SSH scope, authentication modes, port, and extra public TCP ports. A rejected key-login check refers to the candidate's effective admin context: inspect applicable `Match` rules and authentication restrictions before retrying.

## Dependencies

- `sudo` required; read-only audit paths use `sudo -n` and never prompt.
- `sshd -t` for preflight (creates `/run/sshd` on Debian-family systems when missing).
- `ss` (or `lsof` on macOS) to verify the new SSH listener; the audit uses `sudo -n ss -lntup` with an unprivileged fallback and supports `*:port` listeners.
- `ssh-keygen` validates key file contents; `firewall-offline-cmd` prepares stopped firewalld instances.
