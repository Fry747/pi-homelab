#!/usr/bin/env bash
set -euo pipefail
cd / || true

# -----------------------------------------------------------------------------
# pi-homelab installer (minimal + dynamic containers scan)
#
# Usage from a reviewed checkout:
#   sudo env REPO_REF=<reviewed-commit> bash install.sh
#
# What it does:
# - Installs Docker + Docker Compose plugin (if missing)
# - Downloads repo as tarball (no git clone needed)
# - Installs to a new directory (/opt/pi-homelab by default)
# - Bootstraps private .env files and generates credentials for supported stacks
# - Gives the invoking user ownership of the new files
# -----------------------------------------------------------------------------

# ====== CONFIG =============================================================
REPO_OWNER="${REPO_OWNER:-fry747}"
REPO_NAME="${REPO_NAME:-pi-homelab}"
REPO_REF="${REPO_REF:-main}"             # branch/tag/commit
INSTALL_DIR="${INSTALL_DIR:-/opt/pi-homelab}"
# ============================================================================

# Determine the "real" user (so files aren't owned by root after sudo)
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

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

# -----------------------------------------------------------------------------
# Secret generation helpers
# -----------------------------------------------------------------------------
# Generate a decent password (URL/ENV-safe enough)
gen_password() {
  if need_cmd openssl; then
    openssl rand -base64 24 | tr -d '\n' | tr '/+=' 'aZ9'
  else
    head -c 24 /dev/urandom | base64 | tr -d '\n' | tr '/+=' 'aZ9'
  fi
}

# Generate a long token (suitable for InfluxDB initial admin token)
gen_token() {
  if need_cmd openssl; then
    openssl rand -base64 48 | tr -d '\n' | tr '/+=' '___'
  else
    head -c 48 /dev/urandom | base64 | tr -d '\n' | tr '/+=' '___'
  fi
}

# Set KEY=VALUE in an env file if:
# - KEY is missing OR
# - current value is empty OR
# - current value starts with "CHANGEME"
set_env_if_empty_or_changeme() {
  local env_file="$1"
  local key="$2"
  local value="$3"

  # If key missing -> append
  if ! grep -qE "^${key}=" "$env_file"; then
    echo "${key}=${value}" >> "$env_file"
    return 0
  fi

  # Extract current value
  local cur
  cur="$(grep -E "^${key}=" "$env_file" | head -n1 | cut -d= -f2- || true)"
  # Strip surrounding quotes (if any)
  cur="${cur%\"}"; cur="${cur#\"}"
  cur="${cur%\'}"; cur="${cur#\'}"

  if [[ -z "${cur}" || "${cur}" == CHANGEME* ]]; then
    # Replace line
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  fi
}

# Apply secret generation per known stack envs
generate_stack_secrets() {
  local env_file="$1"
  local dir
  dir="$(dirname "$env_file")"

  # DNS stack (.env located in containers/dns/.env)
  if [[ "$dir" == *"/containers/dns" ]]; then
    set_env_if_empty_or_changeme "$env_file" "PIHOLE_WEBPASSWORD" "$(gen_password)"
  fi

  # Monitoring stack (.env located in containers/monitoring/.env)
  if [[ "$dir" == *"/containers/monitoring" ]]; then
    # Keep sane defaults if missing/changeme
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_USERNAME" "admin"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_PASSWORD" "$(gen_password)"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_ORG" "pi-homelab"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_BUCKET" "homeassistant"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_ADMIN_TOKEN" "$(gen_token)"

    set_env_if_empty_or_changeme "$env_file" "GRAFANA_ADMIN_USER" "admin"
    set_env_if_empty_or_changeme "$env_file" "GRAFANA_ADMIN_PASSWORD" "$(gen_password)"
  fi
}

install_docker() {
  if need_cmd docker; then
    log "Docker already installed."
    return
  fi

  export DEBIAN_FRONTEND=noninteractive

  log "Installing Docker (Debian/Raspberry Pi OS)..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
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
  local tmpdir="$1"
  local url
  url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_REF}"

  echo -e "\n[+] Downloading repo tarball: ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}" >&2
  echo -e "[+] URL: ${url}" >&2

  curl -fsSL "$url" -o "${tmpdir}/repo.tar.gz" || die "Failed to download tarball. Check REPO_OWNER/REPO_NAME/REPO_REF."

  echo -e "\n[+] Extracting..." >&2
  tar -xzf "${tmpdir}/repo.tar.gz" -C "$tmpdir" || die "Failed to extract the installation archive."

  local src_dir
  src_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [[ -n "$src_dir" && -d "$src_dir/containers" ]] || die "Installation archive is missing the containers directory."

  echo "$src_dir"
}

copy_to_new_install_dir() {
  local src_dir="$1"

  log "Installing to ${INSTALL_DIR}"
  mkdir -p -- "$(dirname -- "$INSTALL_DIR")"
  mkdir -- "$INSTALL_DIR" || die "Installation requires a new target directory."
  cp -a -- "${src_dir}/." "${INSTALL_DIR}/"
}

fix_ownership() {
  log "Setting ownership: ${REAL_USER}:${REAL_GROUP} -> ${INSTALL_DIR}"
  chown -R "${REAL_USER}:${REAL_GROUP}" "${INSTALL_DIR}"
}

bootstrap_env_files() {
  log "Creating private .env files from .env.example"

  # Look for .env.example next to docker-compose.yml (or anywhere under containers/)
  while IFS= read -r -d '' env_example; do
    local dir env_file
    dir="$(dirname "$env_example")"
    env_file="${dir}/.env"

    [[ ! -e "$env_file" && ! -L "$env_file" ]] || die "Unexpected .env in installation archive."
    install -m 0600 -- "$env_example" "$env_file"
    generate_stack_secrets "$env_file"
    log "Created: ${env_file} (from .env.example)"
  done < <(find "${INSTALL_DIR}/containers" -type f -name ".env.example" -print0)
}

print_next_steps() {
  cat <<EOF

===============================================================================
✅ Installation complete.

Repo installed to:
  ${INSTALL_DIR}

IMPORTANT:
- Generated credentials are stored in the relevant .env files (mode 600).
- Run Docker with the privileges of your own administrator account.

Next steps:
1) Go to a stack directory, review .env, then start:
   cd ${INSTALL_DIR}/containers/dns
   sudo docker compose up -d

2) Check status:
   sudo docker compose ps

3) View logs:
   sudo docker compose logs -f

For updates, see docs/gitops.md in the repository.

===============================================================================
EOF
}

main() {
  require_root
  [[ ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] \
    || die "Target already exists: $INSTALL_DIR. See docs/gitops.md for updates."

  if [[ "$REPO_OWNER" == "<OWNER>" ]]; then
    die "Please set REPO_OWNER at the top of this script (or export REPO_OWNER=...)."
  fi

  install_docker
  ensure_compose

  local src_dir
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$WORK_DIR"' EXIT
  src_dir="$(download_repo_tarball "$WORK_DIR")" || exit 1

  copy_to_new_install_dir "$src_dir"
  bootstrap_env_files
  fix_ownership
  print_next_steps
}

main "$@"
