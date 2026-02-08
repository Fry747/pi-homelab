#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# pi-homelab installer (minimal + dynamic containers scan)
#
# Usage (one-liner):
#   wget -qO- "https://raw.githubusercontent.com/<OWNER>/pi-homelab/main/install.sh" | sudo bash
#
# What it does:
# - Installs Docker + Docker Compose plugin (if missing)
# - Downloads repo as tarball (no git clone needed)
# - Installs to /opt/pi-homelab
# - Bootstraps .env from .env.example (per compose dir), without overwriting existing .env
# - Ensures bind-mount FILES exist (touch), directories already exist via .gitkeep in repo
# - Fixes ownership so you don't need sudo for day-to-day ops
# -----------------------------------------------------------------------------

# ====== CONFIG =============================================================
REPO_OWNER="${REPO_OWNER:-Fry747}"
REPO_NAME="${REPO_NAME:-pi-homelab}"
REPO_REF="${REPO_REF:-main}"             # branch/tag/commit
INSTALL_DIR="${INSTALL_DIR:-/opt/pi-homelab}"
# ============================================================================

# Determine the "real" user (so files aren't owned by root after sudo)
REAL_USER="${SUDO_USER:-${USER}}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
REAL_HOME="${REAL_HOME:-/home/$REAL_USER}"

log()  { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die()  { echo -e "\n[✗] $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root (e.g. via sudo)."
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_docker() {
  if need_cmd docker; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker (Debian/Raspberry Pi OS)..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable
EOF

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  log "Adding user '$REAL_USER' to docker group (so you can run docker without sudo)..."
  if getent group docker >/dev/null; then
    usermod -aG docker "$REAL_USER" || true
  fi
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin available."
    return
  fi

  warn "Docker Compose plugin not found via 'docker compose'. Installing docker-compose-plugin..."
  apt-get update -y
  apt-get install -y docker-compose-plugin
}

download_repo_tarball() {
  local tmpdir url
  tmpdir="$(mktemp -d)"
  url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_REF}"

  log "Downloading repo tarball: ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}"
  log "URL: ${url}"

  curl -fsSL "$url" -o "${tmpdir}/repo.tar.gz" || die "Failed to download tarball. Check REPO_OWNER/REPO_NAME/REPO_REF."

  log "Extracting..."
  tar -xzf "${tmpdir}/repo.tar.gz" -C "$tmpdir"

  # Tarball root folder name is usually "${REPO_NAME}-${REPO_REF}"
  # but for branches it can be "${REPO_NAME}-${REPO_REF}" reliably.
  local src_dir
  src_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [[ -n "${src_dir:-}" ]] || die "Could not find extracted repo directory in tarball."

  echo "$src_dir"
}

sync_to_install_dir() {
  local src_dir="$1"

  log "Installing to ${INSTALL_DIR}"
  mkdir -p "$INSTALL_DIR"

  # Use rsync if available, else fallback to cp -a
  if need_cmd rsync; then
    rsync -a --delete "${src_dir}/" "${INSTALL_DIR}/"
  else
    warn "rsync not found; using cp -a (may not delete removed files)."
    cp -a "${src_dir}/." "${INSTALL_DIR}/"
  fi
}

fix_ownership() {
  log "Setting ownership: ${REAL_USER}:${REAL_GROUP} -> ${INSTALL_DIR}"
  chown -R "${REAL_USER}:${REAL_GROUP}" "${INSTALL_DIR}"
}

bootstrap_env_files() {
  log "Bootstrapping .env from .env.example (without overwriting existing .env)"

  # Look for .env.example next to docker-compose.yml (or anywhere under containers/)
  while IFS= read -r -d '' env_example; do
    local dir env_file
    dir="$(dirname "$env_example")"
    env_file="${dir}/.env"

    if [[ -f "$env_file" ]]; then
      continue
    fi

    cp -n "$env_example" "$env_file"
    chown "${REAL_USER}:${REAL_GROUP}" "$env_file" || true
    chmod 600 "$env_file" || true

    log "Created: ${env_file} (from .env.example)"
  done < <(find "${INSTALL_DIR}/containers" -type f -name ".env.example" -print0 2>/dev/null || true)
}

# Ensure bind-mount FILES exist (directories should exist via .gitkeep in repo)
# This parses volume lines like:
#   - ./mosquitto/config/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
# and if the *left side* is a file path and doesn't exist -> touch it.
ensure_bind_mount_files() {
  log "Ensuring bind-mount FILES exist (touch missing files)."

  local compose
  while IFS= read -r -d '' compose; do
    local base_dir
    base_dir="$(dirname "$compose")"

    # Extract volume sources that look like relative paths starting with ./
    # This is intentionally conservative to avoid doing something surprising.
    while IFS= read -r src; do
      # normalize
      src="${src%%:*}"         # left of first colon
      src="${src#- }"          # strip leading '- '
      src="${src%\"}"; src="${src#\"}"
      src="${src%\'}"; src="${src#\'}"

      # Only handle relative bind mounts
      [[ "$src" == ./* ]] || continue

      local abs="${base_dir}/${src#./}"

      # If it ends with a slash, it's a dir (skip)
      [[ "$abs" == */ ]] && continue

      # If it's clearly a directory in repo, skip (it should exist already)
      if [[ -d "$abs" ]]; then
        continue
      fi

      # Heuristic: treat as "file" if it has a filename component
      # If parent dir missing (shouldn't happen with .gitkeep), create it.
      local parent
      parent="$(dirname "$abs")"
      mkdir -p "$parent"

      if [[ ! -e "$abs" ]]; then
        touch "$abs"
        chown "${REAL_USER}:${REAL_GROUP}" "$abs" || true
        chmod 644 "$abs" || true
        log "Touched missing file: ${abs}"
      fi
    done < <(
      # Grab lines containing "- ./something:" under volumes blocks (rough parse, good enough for homelab compose files)
      grep -RInh -- "$compose" -e '^[[:space:]]*-[[:space:]]*\./[^:]*:' \
        | sed -E 's/^[[:space:]]*-[[:space:]]*//'
    )
  done < <(find "${INSTALL_DIR}/containers" -type f \( -name "docker-compose.yml" -o -name "compose.yml" \) -print0 2>/dev/null || true)
}

print_next_steps() {
  cat <<EOF

===============================================================================
✅ Installation complete.

Repo installed to:
  ${INSTALL_DIR}

IMPORTANT:
- You were added to the 'docker' group (if Docker was installed).
  You may need to log out/in (or reboot) so group membership applies.

Next steps:
1) Go to a stack directory, review .env, then start:
   cd ${INSTALL_DIR}/containers/dns
   docker compose up -d

2) Check status:
   docker compose ps

3) View logs:
   docker compose logs -f

If you want to update later:
- re-run this installer (it will re-sync the repo contents)
- then run 'docker compose pull && docker compose up -d' per stack

===============================================================================
EOF
}

main() {
  require_root

  if [[ "$REPO_OWNER" == "<OWNER>" ]]; then
    die "Please set REPO_OWNER at the top of this script (or export REPO_OWNER=...)."
  fi

  install_docker
  ensure_compose

  local src_dir
  src_dir="$(download_repo_tarball)"

  sync_to_install_dir "$src_dir"
  fix_ownership

  bootstrap_env_files
  ensure_bind_mount_files

  print_next_steps
}

main "$@"
