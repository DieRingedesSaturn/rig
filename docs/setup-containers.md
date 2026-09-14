# setup-containers.sh

One component, two interchangeable backends. Installs **Podman** or **Docker** and picks between them from your configuration rather than from guesswork.

## Why one component

Docker and Podman both give you "run containers". Treating them as two separate components means `rig status` shows a permanent red mark for whichever one you deliberately did not install. Here they are two implementations of one capability, and exactly one is reported.

## Choosing a backend

Resolution order, highest priority first:

| # | Source | Example |
|---|--------|---------|
| 1 | `RIG_CONTAINER_ENGINE` | `podman` / `docker` — always wins |
| 2 | Sole installed backend | preserve the existing Podman or Docker installation |
| 3 | `RIG_PROFILE` | `desktop` → Podman, `vps` → Docker |
| 4 | OS default | Fedora/Arch → Podman, Debian/RHEL → Docker |

**A backend you configured explicitly is never overridden by detection.** In auto mode, a sole existing Podman installation is kept without installing Docker, and vice versa. Interactive runs ask when neither or both are installed.

`RIG_CONTAINER_MODE` selects `rootless` (default) or `rootful`.

If Docker rootless is selected without a usable systemd user session, Rig never changes security mode silently: an interactive run offers to keep Podman, use rootful Docker, or stop and repair the session; a non-interactive run fails with guidance.

### Configuration file

```bash
# ~/.config/rig/config
RIG_PROFILE="desktop"
RIG_CONTAINER_ENGINE="auto"
RIG_CONTAINER_MODE="rootless"
```

The file is parsed, never sourced. An environment variable of the same name overrides it for one-off runs:

```bash
RIG_CONTAINER_ENGINE=podman rig install containers
```

Suggested configurations:

```bash
# Fedora desktop
RIG_PROFILE="desktop"
RIG_CONTAINER_ENGINE="podman"
RIG_CONTAINER_MODE="rootless"
```

```bash
# Debian/Ubuntu VPS
RIG_PROFILE="vps"
RIG_CONTAINER_ENGINE="docker"
RIG_CONTAINER_MODE="rootless"
```

## Podman

On Fedora and Arch, Podman is a single package. It is daemonless, so there is no service to enable, start or restart, and an ordinary user runs containers rootless with no further setup.

| Step | Action |
|------|--------|
| 1 | `sudo dnf install -y podman` (or the distro equivalent) |
| 2 | Check the subordinate UID/GID range; allocate it only if missing or too small |
| 3 | Verify `podman info` reports `Host.Security.Rootless = true` |
| 4 | Report the compose situation (see below) |

On macOS, Podman runs containers inside a Linux VM, so a machine has to be created before anything works:

```bash
podman machine init
podman machine start
```

That downloads a large VM image, so the script installs the package and **prints these commands rather than running them**.

## Docker

Rootless and rootful Docker are genuinely different installations. They use different sockets, different storage directories, different config files and different systemd scopes:

| | Rootless | Rootful |
|---|----------|---------|
| Socket | `/run/user/$UID/docker.sock` | `/var/run/docker.sock` |
| State | `~/.local/share/docker` | `/var/lib/docker` |
| Config | `~/.config/docker/daemon.json` | `/etc/docker/daemon.json` |
| Service | `systemctl --user` | `systemctl` |

### Rootless (default)

| Step | Action |
|------|--------|
| 1 | Require a working `systemd --user` session |
| 2 | Install `uidmap` on Debian/RHEL so `newuidmap`/`newgidmap` exist (they ship in `shadow-utils` on Fedora/Arch) |
| 3 | Check the subordinate UID/GID range — Docker requires at least 65536 IDs; allocate only if missing |
| 4 | Install the Docker Engine packages |
| 5 | Install `docker-ce-rootless-extras` for `dockerd-rootless-setuptool.sh` |
| 6 | Disable the system-wide daemon if a previous rootful install enabled it |
| 7 | `dockerd-rootless-setuptool.sh install` |
| 8 | `systemctl --user enable --now docker` |
| 9 | `loginctl enable-linger` so the service survives logout and reboot — **essential on a headless VPS** |
| 10 | `docker context use rootless` |
| 11 | Write `~/.config/docker/daemon.json` |
| 12 | Verify with `docker info` |

### Rootful

Classic system-wide daemon: install the packages, add your user to the `docker` group, write `/etc/docker/daemon.json`, enable the system service.

## Compose

The script does **not** alias `docker` to `podman`. They are separate tools with separate storage, and `docker compose` and `podman compose` are not the same implementation — `podman compose` delegates to an external provider.

- **Docker** — `docker-compose-plugin` is installed, so `docker compose` works.
- **Podman** — `podman compose` needs a provider. The script reports which package to install rather than choosing one for you.

Keep your compose files portable and use whichever CLI matches the backend on that machine.

## Registry mirrors

Mirrors are opt-in and never applied to a file that already exists.

| Backend | File |
|---------|------|
| Podman | `~/.config/containers/registries.conf` |
| Rootless Docker | `~/.config/docker/daemon.json` |
| Rootful Docker | `/etc/docker/daemon.json` |

```bash
PODMAN_REGISTRY_MIRRORS="https://mirror.example.com" ./setup-containers.sh
DOCKER_MIRROR="https://mirror.example.com" ./setup-containers.sh
```

For Docker, `daemon.json` is **merged**, not replaced: unknown keys are preserved when `python3` is available, otherwise an existing file is left untouched. `default-address-pools` is only written in rootful mode — rootless uses slirp4netns and has no bridge to allocate from.

## Status reporting

`status.sh` reports exactly one backend — the configured one:

```
✔     Containers               Podman 5.8.4 (rootless) configured
```

or, on a machine configured for Docker:

```
✔     Containers               Docker 29.1.2 (rootless) configured
```

Rootless/rootful is taken from `podman info`'s `Host.Security.Rootless` and from `docker info` respectively, not guessed from group membership.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RIG_CONTAINER_ENGINE` | `auto` | `auto`, `podman` or `docker` |
| `RIG_CONTAINER_MODE` | `rootless` | `rootless` or `rootful` |
| `RIG_PROFILE` | _(empty)_ | `desktop` or `vps` |
| `PODMAN_REGISTRY_MIRRORS` | _(empty)_ | Comma-separated mirrors for Podman |
| `DOCKER_MIRROR` | _(empty)_ | Comma-separated mirrors for Docker |
| `DOCKER_LOG_SIZE` | `20m` | Max size per log file |
| `DOCKER_LOG_FILES` | `3` | Max number of log files |

## Update

`rig update containers` resolves the same way and updates only what is installed:

| Backend | Action |
|---------|--------|
| Podman | upgrade the `podman` package (daemonless — nothing to restart) |
| Rootless Docker | upgrade the engine packages including `docker-ce-rootless-extras`, then `systemctl --user restart docker` |
| Rootful Docker | upgrade the engine packages, then `systemctl restart docker` |

## Uninstall

Images and volumes are user data and are **never removed by default**.

| Backend | Removed | Kept |
|---------|---------|------|
| Podman | `podman` package | `~/.local/share/containers`, `~/.config/containers/` |
| Rootless Docker | user service, engine packages | `~/.local/share/docker`, `~/.config/docker/` |
| Rootful Docker | system service, engine packages, `/etc/docker/` | `/var/lib/docker` |

Use `--remove-docker-data` to also delete the image/volume store.

## Dependencies

- `sudo` on Linux for package installation and `usermod`/`loginctl`
- Network access to `get.docker.com` when installing Docker

## Notes

- `setup-containers.sh` never overwrites an existing `daemon.json` or `registries.conf`.
- On macOS, Docker means Docker Desktop; rootless mode does not exist there, so the Podman backend is the sane choice.
