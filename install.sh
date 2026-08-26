#!/usr/bin/env bash
# =====================================================================
# template-generator — one-click installer
#
# Deploys the template builder (Web UI + Ansible backend) to this
# server and registers it as a systemd service.
#
# Usage:
#   # copy the project to the target server, then:
#   ./install.sh                     # defaults: port 8080, token changeme
#   ./install.sh --port 8443 --token MySecret --bind 0.0.0.0
#
# Flags:
#   --port PORT        listen port            (default: 8080)
#   --token TOKEN      API token for the UI   (default: changeme)
#   --bind ADDR        bind address           (default: 0.0.0.0)
#   --install-dir DIR  deploy location        (default: /opt/template-generator)
#   --unit-name NAME   systemd unit name      (default: template-generator)
#   --no-firewall      do not touch firewall rules
#   --skip-packages    skip OS package install (assume deps present)
#   -h, --help
#
# Re-running the installer = upgrade: code is refreshed, your
# config/, cache/, output/ and build history are preserved.
# =====================================================================
set -euo pipefail

# ---------------------------------------------------------------- config
PORT=8080
TOKEN="changeme"
BIND="0.0.0.0"
INSTALL_DIR="/opt/template-generator"
UNIT_NAME="template-generator"
FIREWALL=1
SKIP_PKGS=0

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)          PORT="$2"; shift 2 ;;
        --token)         TOKEN="$2"; shift 2 ;;
        --bind)          BIND="$2"; shift 2 ;;
        --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
        --unit-name)     UNIT_NAME="$2"; shift 2 ;;
        --no-firewall)   FIREWALL=0; shift ;;
        --skip-packages) SKIP_PKGS=1; shift ;;
        -h|--help)       sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
command -v rsync >/dev/null 2>&1 || die "rsync is required (it will be installed by this script on supported distros)"
[[ -f "$SRC/server/app.py" ]] || die "installer must be run from inside the template-generator project"

UPGRADE=0
[[ -d "$INSTALL_DIR/server" ]] && UPGRADE=1

# ------------------------------------------------------------ OS detect
. /etc/os-release
FAMILY=""
case "${ID:-}:${ID_LIKE:-}" in
    *rhel*|*rocky*|*alma*|*centos*|*fedora*) FAMILY=rpm ;;
    *debian*|*ubuntu*)                       FAMILY=deb ;;
esac
[[ -n "$FAMILY" ]] || die "unsupported OS: $ID (supported: RHEL-family and Debian-family)"
log "detected OS: $PRETTY_NAME (${FAMILY} family)"

# ------------------------------------------------------- package install
if [[ $SKIP_PKGS == 1 ]]; then
    warn "--skip-packages: assuming prerequisites are already installed"
else
    log "installing system packages..."
    if [[ $FAMILY == rpm ]]; then
        # EL9 provides 'libguestfs-tools'; EL10+ renamed it to 'guestfs-tools'.
        base="curl rsync qemu-img ansible-core python3 python3-pip"
        dnf -y install $base libguestfs-tools qemu-kvm >/dev/null 2>&1 \
            || dnf -y install $base guestfs-tools qemu-kvm >/dev/null 2>&1 \
            || dnf -y install $base
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null
        apt-get -y install curl rsync qemu-utils libguestfs-tools \
            qemu-system-x86 ansible-core python3 python3-venv python3-pip >/dev/null \
            || apt-get -y install curl rsync qemu-utils \
               ansible-core python3 python3-venv python3-pip >/dev/null
    fi
    for c in curl qemu-img virt-customize virt-sysprep virt-resize python3; do
        command -v "$c" >/dev/null 2>&1 || die "install failed: '$c' still missing — check your distro mirrors"
    done
    info "system prerequisites OK"
fi

# -------------------------------------------------------------- deploy
log "deploying project to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
EXCLUDES=(--exclude '.git' --exclude 'venv' --exclude '.venv'
          --exclude 'server/logs' --exclude 'server/data.db'
          --exclude 'server/work' --exclude '__pycache__' --exclude '*.pyc'
          --exclude '*.qcow2' --exclude '*.img' --exclude '*.raw' --exclude '*.iso')
if [[ $UPGRADE == 1 ]]; then
    info "upgrade mode — preserving config/, cache/, output/ and history"
    EXCLUDES+=(--exclude 'config' --exclude 'cache' --exclude 'output')
fi
rsync -a --quiet "${EXCLUDES[@]}" "$SRC/" "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR"/{cache,output,server/logs,server/work}
chmod 755 "$INSTALL_DIR"/build.sh "$INSTALL_DIR"/run-server.sh 2>/dev/null || true

# ------------------------------------------------------------ python venv
VENV="$INSTALL_DIR/venv"
if [[ ! -x "$VENV/bin/python" ]]; then
    log "creating python virtualenv"
    python3 -m venv "$VENV"
fi
log "installing python dependencies (fastapi, uvicorn, pyyaml)"
"$VENV/bin/pip" install --quiet --upgrade pip >/dev/null
"$VENV/bin/pip" install --quiet fastapi uvicorn pyyaml

# ansible fallback: if the distro package was unavailable, install in venv
if ! command -v ansible-playbook >/dev/null 2>&1; then
    warn "ansible-playbook not found on system — installing ansible-core into venv"
    "$VENV/bin/pip" install --quiet ansible-core
fi

# --------------------------------------------------------- systemd unit
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}.service"
log "writing systemd unit: $UNIT_FILE"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=template-generator web UI (KVM template builder)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
Environment=TG_TOKEN=$TOKEN
Environment=PATH=$VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$VENV/bin/python -m uvicorn server.app:app --host $BIND --port $PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

log "enabling and starting ${UNIT_NAME}.service"
systemctl daemon-reload
systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
systemctl restart "$UNIT_NAME"
sleep 2
if ! systemctl is-active --quiet "$UNIT_NAME"; then
    warn "service failed to start — journal tail:"
    journalctl -u "$UNIT_NAME" --no-pager -n 12 | tail -12
    die "service not active"
fi

# -------------------------------------------------------------- firewall
if [[ $FIREWALL == 1 ]]; then
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1
        info "firewalld: opened port $PORT/tcp"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "$PORT/tcp" >/dev/null 2>&1
        info "ufw: opened port $PORT/tcp"
    fi
fi

# -------------------------------------------------------------- warnings
[[ -e /dev/kvm ]] || warn "no /dev/kvm — builds will run under TCG emulation (slower, still works)"
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    warn "SELinux is Enforcing — if virt-customize fails, see README troubleshooting"
fi

# -------------------------------------------------------------- summary
cat <<EOF

=====================================================================
 ✅ template-generator installed
---------------------------------------------------------------------
 Web UI     : http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT
 API token  : $TOKEN
 Install dir: $INSTALL_DIR
 Service    : systemctl status $UNIT_NAME
 Upgrade    : re-run this installer to update (config/data preserved)
---------------------------------------------------------------------
 Quick check:
   curl -H 'X-Token: $TOKEN' http://localhost:$PORT/api/catalog
 Logs:
   journalctl -fu $UNIT_NAME
=====================================================================
EOF
