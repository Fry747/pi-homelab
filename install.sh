#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_CONTAINERS="${REPO_ROOT}/containers"
DST_ROOT="/opt/containers"

# Wenn per sudo ausgeführt: auf den "echten" User zielen, sonst aktuellen User nehmen
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_GROUP="${SUDO_USER:-$USER}"

log() { echo -e "\n==> $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte mit sudo ausführen: sudo $0"
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker ist bereits installiert."
    return
  fi

  log "Installiere Docker (apt)..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

configure_user_access() {
  log "Konfiguriere Docker-Rechte für User: ${TARGET_USER}"
  groupadd -f docker
  usermod -aG docker "${TARGET_USER}" || true

  # Zielstruktur
  mkdir -p "${DST_ROOT}"
  chown -R "${TARGET_USER}:${TARGET_GROUP}" "${DST_ROOT}"
}

sync_stacks() {
  log "Synchronisiere Stacks aus ${SRC_CONTAINERS} nach ${DST_ROOT}"
  if [[ ! -d "${SRC_CONTAINERS}" ]]; then
    echo "Fehler: ${SRC_CONTAINERS} nicht gefunden."
    exit 1
  fi

  # rsync installieren falls nötig
  if ! command -v rsync >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y rsync
  fi

  # jeden Stack-Ordner (1 Level) kopieren
  find "${SRC_CONTAINERS}" -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d '' stackdir; do
    stackname="$(basename "${stackdir}")"
    dst="${DST_ROOT}/${stackname}"

    log "-> Stack: ${stackname}"
    mkdir -p "${dst}"

    # -a bewahrt Struktur und leere Ordner
    rsync -a --delete "${stackdir}/" "${dst}/"

    # .env automatisch aus .env.example ableiten, wenn .env fehlt
    if [[ -f "${dst}/.env.example" && ! -f "${dst}/.env" ]]; then
      cp "${dst}/.env.example" "${dst}/.env"
      log "   .env aus .env.example erzeugt (${stackname})"
    fi

    chown -R "${TARGET_USER}:${TARGET_GROUP}" "${dst}"
  done
}

optional_pihole_password_init() {
  # Wenn dns Stack existiert, PIHOLE_WEBPASSWORD setzen falls leer/fehlend
  local dns_dir="${DST_ROOT}/dns"
  local env_file="${dns_dir}/.env"
  if [[ -f "${env_file}" ]]; then
    if ! grep -q '^PIHOLE_WEBPASSWORD=' "${env_file}" || grep -q '^PIHOLE_WEBPASSWORD=$' "${env_file}"; then
      log "Setze zufälliges PIHOLE_WEBPASSWORD in ${env_file}"
      local pw
      pw="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
      # falls Key existiert, ersetzen, sonst anhängen
      if grep -q '^PIHOLE_WEBPASSWORD=' "${env_file}"; then
        sed -i "s/^PIHOLE_WEBPASSWORD=.*/PIHOLE_WEBPASSWORD=${pw}/" "${env_file}"
      else
        echo "PIHOLE_WEBPASSWORD=${pw}" >> "${env_file}"
      fi
      chown "${TARGET_USER}:${TARGET_GROUP}" "${env_file}"
      chmod 600 "${env_file}" || true
      log "Pi-hole Passwort (bitte notieren): ${pw}"
    fi
  fi
}

main() {
  require_root
  install_docker
  configure_user_access
  sync_stacks
  optional_pihole_password_init

  log "Fertig."
  echo "Hinweis: Damit 'docker' ohne sudo klappt, bitte einmal ab- und wieder anmelden (oder reboot)."
  echo "Stacks starten z.B.: cd /opt/containers/dns && docker compose up -d"
}

main "$@"
