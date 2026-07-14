# FSLab Installer Suite

Cross-distro post-install toolkit for FSLab development environments. Replaces
the previous snap-only `post_install_fslab.sh` with a resilient, idempotent,
logged, and locked suite of bash scripts that work on **Arch-family**,
**Fedora/RHEL-family**, and **Ubuntu/Debian-family**.

## What gets installed

| Tool | Source | Notes |
|------|--------|-------|
| **NVM + Node.js LTS** | nvm-sh (GitHub) | Pin to v0.40.3, persisted in `~/.bashrc` and `~/.zshrc` |
| **VS Code** | Microsoft repo (`.deb` / `.rpm` / AUR `visual-studio-code-bin`) | Microsoft build — full Marketplace access |
| **Insomnia** | Kong/insomnia GitHub Releases | `.deb` / `.rpm` — original APT repo was deprecated |
| **JetBrains Toolbox** | JetBrains API + direct download fallback | Then install DataGrip via the Toolbox UI |
| **Docker CE** | Official Docker repo (per-distro) | With `docker-compose-plugin` and `docker-buildx-plugin` |

FSLab post-install additionally configures:

- Git global (`init.defaultBranch=main`, `pull.rebase=false`, `core.editor`, aliases) — interactive for `user.name` / `user.email` if not set
- NPM globals: `pm2`, `typescript`, `ts-node`, `nodemon`, `eslint`, `prettier`, `yo`, `rimraf`, `npm-check-updates`, `tsx`
- 15 VS Code extensions (ESLint, Prettier, GitLens, Docker, Remote-SSH, Remote-Containers, Jest, Playwright, YAML, …)
- Workspace directories: `~/fslab/{projects,tools,docs,scripts,configs,downloads}`
- SSH ed25519 key (with `~/.ssh/config` for GitHub/GitLab)

## Files

```
fslab-installer/
├── install-arch.sh            # Arch Linux + derivatives (Manjaro, BigLinux, Endeavour, Garuda, CachyOS, Arcolinux, Artix)
├── install-fedora.sh          # Fedora 42+ and RHEL-family (CentOS Stream, AlmaLinux, Rocky)
├── install-ubuntu-debian.sh   # Ubuntu / Debian + derivatives (Mint, Pop!_OS, Zorin, Elementary)
├── post_install_fslab.sh      # Entry point — detects OS, dispatches to installer, runs FSLab post-install
└── README.md                  # This file
```

## Quick start

```bash
# 1. Make all scripts executable
chmod +x install-*.sh post_install_fslab.sh

# 2. Run the unified entry point (recommended)
./post_install_fslab.sh

# Or run the per-OS installer directly
./install-arch.sh            # on Arch-family
./install-fedora.sh          # on Fedora/RHEL
./install-ubuntu-debian.sh   # on Ubuntu/Debian
```

## Resilience features

Every script in the suite implements:

1. **`set -Eeuo pipefail` + `trap ERR`** — failures show the line number and
   offending command, never fail silently.
2. **Idempotency** — re-running the script skips already-installed components
   (NVM, VS Code, Docker, Insomnia, Toolbox). Safe to re-run after a failure.
3. **Single sudo authentication** — one password prompt at the start; a
   background keepalive refreshes the cache every 60s so long operations
   (AUR builds, Docker pulls) never time out.
4. **Lock file** in `/tmp/fslab-*.lock` — prevents two concurrent runs from
   corrupting each other.
5. **Per-run tmp directory** — `mktemp -d` creates a unique scratch dir,
   cleaned up via `trap … EXIT` regardless of exit code.
6. **Logging to `~/.local/share/fslab/logs/`** — every run produces a
   timestamped log file with `tee` (parallel stdout + file).
7. **Internet check** before doing anything destructive — two-endpoint
   fallback (`launchpad.net` / `archlinux.org` / `fedoraproject.org` →
   `google.com`).
8. **Color auto-detection** — colors are disabled automatically when stderr
   is not a TTY, so logs stay clean.
9. **Architecture detection** — `x86_64` / `aarch64` / `armhf` honored per
   repo.
10. **Cascading fallbacks** — each component tries its primary source first
    (pacman → AUR → manual; apt repo → GitHub Releases → fixed URL).
11. **Size validation** on downloads — refuses to install files smaller
    than 5 MB (broken downloads).
12. **Repo validation** — verifies the Docker repo is actually reachable
    for the detected `distro+codename` before attempting `apt install`.

## Bug fixes vs. the original scripts

### `install-fedora.sh`
- **Critical:** the original `trap '… $RED … $NC …' ERR` was registered
  *before* the color variables were defined, so the trap silently produced
  empty colors. Fixed by defining colors first, then registering the trap.
- Added `pipefail` to `set -e` (was missing).
- Added sudo keepalive (was missing — long DNF operations would re-prompt).
- Added internet check (was missing).
- Added support for RHEL-family distros via `ID_LIKE=rhel` (CentOS Stream,
  AlmaLinux, Rocky).
- Added DNF5 detection (Fedora 41+ ships `dnf5`).
- Insomnia now downloads to per-run tmp dir (was `/tmp/insomnia.rpm`,
  prone to collisions).
- Download size validation before installing RPM.

### `install-ubuntu-debian.sh`
- Added `pipefail` to `set -e` (was missing — pipelines could mask failures).
- Added ERR trap with line number (was missing).
- Added sudo keepalive (was missing).
- Added internet check (was missing).
- Added handling for Debian `sid` / `trixie` / `forky` (no dedicated Docker
  repo — falls back to `bookworm`).
- Added size validation on Insomnia download.
- Added size validation on JetBrains Toolbox download.
- Idempotency hardened for NVM shell-persistence (no duplicate `# NVM`
  blocks on re-run).
- Final summary now includes Toolbox status (was always claimed installed).

### `install-arch.sh`
- Added ERR trap with line number (was only EXIT trap).
- Added lock file (was missing).
- Added architecture detection (was missing).
- Added size validation on JetBrains Toolbox download.
- Added detection of Artix (no systemd) — skips `systemctl` calls and prints
  the correct `rc-service` instructions.
- NVM version bumped to `v0.40.3`.
- Insomnia no longer relies solely on AUR — `pacman_or_aur` wrapper tries
  the official repo first.
- Idempotency hardened for NVM shell-persistence.

### `post_install_fslab.sh`
- **Complete rewrite** — the original was a 26-line snap-based script with
  no error handling, no OS detection, no idempotency, and installed the
  wrong NVM version (`0.40.4` doesn't exist; the latest is `0.40.3`).
- New version is a cross-distro **dispatcher + post-install customizer**
  that works on all three OS families.
- All apps are installed via the OS-appropriate installer (no Snap, no
  Flatpak — consistent with the other three scripts).
- Adds FSLab-specific post-install: Git config, NPM globals, VS Code
  extensions, workspace dirs, SSH key generation.

## Logs

Every run produces a timestamped log file under:

```
~/.local/share/fslab/logs/
├── install-arch-YYYYMMDD-HHMMSS.log
├── install-fedora-YYYYMMDD-HHMMSS.log
├── install-ubuntu-debian-YYYYMMDD-HHMMSS.log
└── post-install-fslab-YYYYMMDD-HHMMSS.log
```

The path of the log file is printed at the end of every run.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FSLAB_WORKSPACE` | `$HOME/fslab` | Where to create the workspace directory tree |

Example:

```bash
FSLAB_WORKSPACE=/opt/fslab ./post_install_fslab.sh
```

## Tested distros

The installers have been written to handle the following distro IDs and
`ID_LIKE` values. If your distro isn't listed, the script will print a clear
error rather than running on the wrong package manager.

| Family | Distros |
|--------|---------|
| Arch | `arch`, `manjaro`, `biglinux`, `endeavouros`, `garuda`, `cachyos`, `arcolinux`, `artix` |
| Fedora/RHEL | `fedora` (42+), `rhel` (9+), `centos`, `almalinux`, `rocky` |
| Ubuntu/Debian | `ubuntu` (20.04+), `debian` (11+), `linuxmint`, `pop`, `zorin`, `elementary` |

## Troubleshooting

### "Outra instância deste script já está rodando (PID xxx)"
Either wait for the other run to finish, or remove the lock file:
```bash
rm /tmp/fslab-install-*.lock /tmp/fslab-post-install.lock
```

### Docker permission denied after install
The `docker` group membership only takes effect after a fresh login:
```bash
# Quick test without logout (NOT recommended for daily use):
newgrp docker
docker run --rm hello-world
```

### VS Code not in PATH after install
The Microsoft repo installs to `/usr/bin/code` (Linux). If `command -v code`
fails after install, run:
```bash
hash -r
source ~/.bashrc
```

### JetBrains Toolbox didn't install
The API endpoint sometimes rate-limits. Re-run the script (idempotent —
will retry the download). Or install manually from
https://www.jetbrains.com/toolbox-app/ and place the binary at
`~/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox`.

### Re-running after a partial failure
All four scripts are **idempotent** — re-running is safe and will skip
already-completed steps. Just run the same command again.
