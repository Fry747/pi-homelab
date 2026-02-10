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
# - Generates secrets (Pi-hole / InfluxDB / Grafana) ONLY if values are missing/empty/CHANGEME*
# - Prints generated secrets at the end (only those newly generated)
# - Fixes ownership so you don't need sudo for day-to-day ops
# -----------------------------------------------------------------------------

# ====== CONFIG =============================================================
REPO_OWNER="${REPO_OWNER:-fry747}"
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

# -----------------------------------------------------------------------------
# Secret generation helpers
# -----------------------------------------------------------------------------
# We'll remember newly generated secrets and print them at the end.
declare -A GENERATED_SECRETS

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
# If we generated a new value, remember it in GENERATED_SECRETS.
set_env_if_empty_or_changeme() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local origin="$4"   # label for output, e.g. "dns/PIHOLE_WEBPASSWORD"

  # If key missing -> append
  if ! grep -qE "^${key}=" "$env_file"; then
    echo "${key}=${value}" >> "$env_file"
    GENERATED_SECRETS["$origin"]="$value"
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
    GENERATED_SECRETS["$origin"]="$value"
  fi
}

# Apply secret generation per known stack envs
generate_stack_secrets() {
  local env_file="$1"
  local dir
  dir="$(dirname "$env_file")"

  # DNS stack (.env located in containers/dns/.env)
  if [[ "$dir" == *"/containers/dns" ]]; then
    set_env_if_empty_or_changeme "$env_file" "PIHOLE_WEBPASSWORD" "$(gen_password)" "dns/PIHOLE_WEBPASSWORD"
  fi

  # Monitoring stack (.env located in containers/monitoring/.env)
  if [[ "$dir" == *"/containers/monitoring" ]]; then
    # Keep sane defaults if missing/changeme
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_USERNAME" "admin" "monitoring/INFLUXDB_USERNAME"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_PASSWORD" "$(gen_password)" "monitoring/INFLUXDB_PASSWORD"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_ORG" "pi-homelab" "monitoring/INFLUXDB_ORG"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_BUCKET" "homeassistant" "monitoring/INFLUXDB_BUCKET"
    set_env_if_empty_or_changeme "$env_file" "INFLUXDB_ADMIN_TOKEN" "$(gen_token)" "monitoring/INFLUXDB_ADMIN_TOKEN"

    set_env_if_empty_or_changeme "$env_file" "GRAFANA_ADMIN_USER" "admin" "monitoring/GRAFANA_ADMIN_USER"
    set_env_if_empty_or_changeme "$env_file" "GRAFANA_ADMIN_PASSWORD" "$(gen_password)" "monitoring/GRAFANA_ADMIN_PASSWORD"
  fi
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

  echo -e "\n[+] Downloading repo tarball: ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}" >&2
  echo -e "[+] URL: ${url}" >&2

  curl -fsSL "$url" -o "${tmpdir}/repo.tar.gz" || die "Failed to download tarball. Check REPO_OWNER/REPO_NAME/REPO_REF."

  echo -e "\n[+] Extracting..." >&2
  tar -xzf "${tmpdir}/repo.tar.gz" -C "$tmpdir"

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
    log "DEBUG src_dir='$src_dir'"
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

    # Do not overwrite existing .env
    if [[ ! -f "$env_file" ]]; then
      cp -n "$env_example" "$env_file"
      chown "${REAL_USER}:${REAL_GROUP}" "$env_file" || true
      chmod 600 "$env_file" || true
      log "Created: ${env_file} (from .env.example)"
    fi

    # Always ensure secrets are set if missing/empty/CHANGEME*
    if [[ -f "$env_file" ]]; then
      generate_stack_secrets "$env_file"
    fi
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

      # If it's clearly a directory in repo, skip
      if [[ -d "$abs" ]]; then
        continue
      fi

      # Create parent dir if missing (shouldn't happen with .gitkeep, but safe)
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

print_generated_secrets() {
  if [[ "${#GENERATED_SECRETS[@]}" -eq 0 ]]; then
    log "No new secrets generated (existing values were kept)."
    return
  fi

  cat <<EOF

===============================================================================
🔐 Newly generated secrets (saved into the respective .env files)

IMPORTANT:
- Store these somewhere safe (password manager).
- They are already written to the .env files with permissions 600.
- Anyone with access to ${INSTALL_DIR} can potentially read them.

EOF

  # Stable-ish order (nice to read)
  local keys=(
    "dns/PIHOLE_WEBPASSWORD"
    "monitoring/INFLUXDB_USERNAME"
    "monitoring/INFLUXDB_PASSWORD"
    "monitoring/INFLUXDB_ORG"
    "monitoring/INFLUXDB_BUCKET"
    "monitoring/INFLUXDB_ADMIN_TOKEN"
    "monitoring/GRAFANA_ADMIN_USER"
    "monitoring/GRAFANA_ADMIN_PASSWORD"
  )

  for k in "${keys[@]}"; do
    if [[ -n "${GENERATED_SECRETS[$k]:-}" ]]; then
      printf "  %-35s %s\n" "${k}:" "${GENERATED_SECRETS[$k]}"
    fi
  done

  cat <<EOF
===============================================================================

EOF
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

  # Print secrets AFTER env bootstrap & any modifications
  print_generated_secrets
  print_next_steps
}

main "$@"
