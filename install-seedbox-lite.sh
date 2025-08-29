#!/usr/bin/env bash
set -euo pipefail

# === Config ===
APP_DIR="/opt/seedbox-lite"
REPO_URL="https://github.com/hotheadhacker/seedbox-lite.git"
BACKEND_PORT="${BACKEND_PORT:-3001}"
FRONTEND_PORT="${FRONTEND_PORT:-5174}"
ACCESS_PASSWORD="${ACCESS_PASSWORD:-}"
SETUP_SYSTEMD="${SETUP_SYSTEMD:-yes}"   # set to "no" to skip systemd unit
BRANCH="${BRANCH:-main}"

# === Helpers ===
log() { echo -e "\033[1;32m[seedbox-lite]\033[0m $*"; }
err() { echo -e "\033[1;31m[seedbox-lite]\033[0m $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root (use sudo)."
    exit 1
  fi
}

rand_pw() {
  (tr -dc 'A-Za-z0-9!@#%^_+=' </dev/urandom | head -c 24) || true
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps_apt() {
  log "Updating APT and installing dependencies..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release git ufw || true

  if ! have_cmd docker; then
    log "Installing Docker Engine + Compose plugin from Docker repo..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
$(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi

  if have_cmd docker-compose && ! have_cmd docker\ compose; then
    log "docker-compose v1 detected. Modern 'docker compose' plugin also installed; script will use it."
  fi
}

ensure_docker() {
  if ! have_cmd docker; then
    # Try APT path (Debian/Ubuntu). For others, bail out with instructions.
    if [ -f /etc/debian_version ]; then
      install_deps_apt
    else
      err "Non-Debian system detected. Please install Docker and the Compose plugin, then re-run."
      exit 1
    fi
  fi
}

git_clone_or_update() {
  if [[ -d "$APP_DIR/.git" ]]; then
    log "Repo exists at $APP_DIR, pulling latest..."
    git -C "$APP_DIR" fetch --all --prune
    git -C "$APP_DIR" checkout "$BRANCH"
    git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
  else
    log "Cloning $REPO_URL to $APP_DIR..."
    mkdir -p "$APP_DIR"
    git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
  fi
}

prepare_env() {
  cd "$APP_DIR"
  # Choose which .env template to copy; the repo provides .env.example
  # (The README documents BACKEND_PORT, FRONTEND_PORT, ACCESS_PASSWORD, etc.)
  if [[ ! -f .env ]]; then
    cp .env.example .env 2>/dev/null || true
    # If example isn't available, create minimal .env
    if [[ ! -f .env ]]; then
      cat > .env <<EOF
NODE_ENV=production
SERVER_PORT=${BACKEND_PORT}
SERVER_HOST=0.0.0.0
ACCESS_PASSWORD=
FRONTEND_URL=http://localhost:${FRONTEND_PORT}
VITE_API_BASE_URL=http://localhost:${BACKEND_PORT}
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}
EOF
    fi
  fi

  # Inject password and ports if not present
  if [[ -z "${ACCESS_PASSWORD}" ]]; then
    ACCESS_PASSWORD="$(rand_pw)"
    log "Generated ACCESS_PASSWORD: ${ACCESS_PASSWORD}"
  else
    log "Using provided ACCESS_PASSWORD (hidden)."
  fi

  # Safely update .env key/values
  sed -i -E "s|^(\s*ACCESS_PASSWORD\s*=\s*).*|\1${ACCESS_PASSWORD}|" .env
  sed -i -E "s|^(\s*SERVER_PORT\s*=\s*).*|\1${BACKEND_PORT}|" .env
  sed -i -E "s|^(\s*BACKEND_PORT\s*=\s*).*|\1${BACKEND_PORT}|" .env
  sed -i -E "s|^(\s*FRONTEND_PORT\s*=\s*).*|\1${FRONTEND_PORT}|" .env
  sed -i -E "s|^(\s*VITE_API_BASE_URL\s*=\s*).*|\1http://localhost:${BACKEND_PORT}|" .env
  sed -i -E "s|^(\s*FRONTEND_URL\s*=\s*).*|\1http://localhost:${FRONTEND_PORT}|" .env
}

open_firewall() {
  if have_cmd ufw; then
    if ufw status | grep -q "Status: active"; then
      log "UFW active: allowing ${FRONTEND_PORT}/tcp and ${BACKEND_PORT}/tcp"
      ufw allow "${FRONTEND_PORT}/tcp" || true
      ufw allow "${BACKEND_PORT}/tcp" || true
    fi
  fi
}

compose_cmd() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif have_cmd docker-compose; then
    echo "docker-compose"
  else
    err "No Compose frontend found."
    exit 1
  fi
}

start_stack() {
  local DCMD
  DCMD="$(compose_cmd)"
  log "Starting SeedBox Lite with ${DCMD}..."
  cd "$APP_DIR"
  $DCMD pull
  $DCMD up -d
  $DCMD ps
}

create_systemd() {
  [[ "$SETUP_SYSTEMD" == "yes" ]] || { log "Skipping systemd setup."; return; }

  local DCMD BIN
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    DCMD="/usr/bin/docker compose"
  elif have_cmd docker-compose; then
    DCMD="/usr/bin/docker-compose"
  else
    err "Skipping systemd: docker compose not found."
    return
  fi

  cat >/etc/systemd/system/seedbox-lite.service <<EOF
[Unit]
Description=SeedBox Lite (Docker Compose)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${APP_DIR}
RemainAfterExit=true
ExecStart=${DCMD} up -d
ExecStop=${DCMD} down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable seedbox-lite.service
  log "Enabled systemd service: seedbox-lite.service"
}

print_summary() {
  cat <<EOF

=============================================
 SeedBox Lite is up!
---------------------------------------------
 Frontend:        http://<your-server-ip>:${FRONTEND_PORT}
 Backend API:     http://<your-server-ip>:${BACKEND_PORT}
 Login password:  ${ACCESS_PASSWORD}

 To manage:
   cd ${APP_DIR}
   $(compose_cmd) logs -f
   $(compose_cmd) restart
   $(compose_cmd) down

 Systemd (if enabled):
   systemctl status seedbox-lite
   systemctl restart seedbox-lite

Tip: Reverse proxy (nginx/Traefik) can sit in front; see repo docs.
=============================================
EOF
}

main() {
  require_root
  ensure_docker
  git_clone_or_update
  prepare_env
  open_firewall
  start_stack
  create_systemd
  print_summary
}

main "$@"
