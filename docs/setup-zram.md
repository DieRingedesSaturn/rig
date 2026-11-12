# setup-zram.sh

Compressed zram swap through `systemd-zram-generator`, plus an optional disk-backed swapfile. Existing disk swap is left alone unless you explicitly ask for a swapfile, so it keeps acting as the fallback when zram fills up.

## Behavior

| Item | Default | Notes |
|------|---------|-------|
| zram | enabled | Package `systemd-zram-generator` on Debian/Ubuntu, `zram-generator` on Fedora/RHEL/Arch |
| zram size | `auto` | RAM/3, capped at 1024 MiB; a literal MiB value can be used instead |
| Compression | `zstd` | `zstd`, `lz4`, `lzo`, `lzo-rle`, `deflate` or `842` |
| Swap priority | 100 | zram is preferred over disk swap |
| sysctl tuning | enabled | `vm.swappiness=100`, `vm.page-cluster=0` |
| Swapfile | disabled | Optional `/swapfile` (default 1024 MiB) with a marked `/etc/fstab` entry |

The generator is distro-neutral: it reads `/etc/systemd/zram-generator.conf`, creates `zram0`, and generates `systemd-zram-setup@zram0.service` plus `dev-zram0.swap`. Rig starts both units and verifies that `/dev/zram0` actually appears in `/proc/swaps`.

Changing the size or compression algorithm rebuilds `zram0`. The active swap unit is stopped first, so pages are swapped back into RAM before the device is reset.

## Files

| File | Purpose |
|------|---------|
| `/etc/systemd/zram-generator.conf` | Managed zram0 definition (rig marker in the first line) |
| `/etc/sysctl.d/99-rig-zram.conf` | `vm.swappiness` / `vm.page-cluster` tuning |
| `/swapfile` | Optional swapfile, only when enabled |
| `/etc/fstab` | Marked swap entry, only when the swapfile is enabled |

Every write is preceded by a timestamped backup in `~/.local/share/rig/backups/system`. If an unmanaged `zram-generator.conf` or sysctl drop-in already exists, rig backs it up and warns before replacing it. An existing unmanaged `/swapfile` fstab entry is never modified.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RIG_ZRAM_ENABLE` | `yes` | `yes` / `no` |
| `RIG_ZRAM_SIZE` | `auto` | `auto` or MiB (1-1048576) |
| `RIG_ZRAM_COMPRESSION` | `zstd` | Compression algorithm |
| `RIG_SWAPFILE_ENABLE` | `no` | Create and manage a swapfile |
| `RIG_SWAPFILE_SIZE` | `1024` | Swapfile size in MiB |

## Uninstall

`uninstall.sh --components zram` stops `dev-zram0.swap` and the setup unit, resets `zram0`, removes the two managed config files, restores `/etc/fstab`, and deletes the managed swapfile. The `zram-generator` package is kept.
