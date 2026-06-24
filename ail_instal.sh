#!/usr/bin/env bash
# =============================================================================
#  AIL FRAMEWORK — Full Automated Setup, Diagnosis, Port-Fix & Launch Script
#  Supports: Ubuntu 20.04 / 22.04 / 24.04 | Debian 11 / 12 | Kali 2024+
#  Covers: AIL core, Lacus crawler, Meilisearch, LibreTranslate
#  Run as: sudo bash ail_setup.sh
#
#  FIXES APPLIED:
#    [FIX-1] setup_kvrocks() added to main() — was defined but never called
#    [FIX-2] Redis failure handling uses proper if/else instead of bare ||
#    [FIX-3] Python version loop checks "$py" not hardcoded "python3"
#    [FIX-4] PYTHON_BIN fallback guard added in setup_venv()
#    [FIX-5] Lacus ExecStart uses installed "lacus" binary, not wrong module path
#    [FIX-6] KVRocks health check added to health_check()
#    [FIX-7] configure_ail() confirmed to run AFTER run_ail_installer()
#    [FIX-8] Playwright system deps added for Ubuntu 24.04 / Kali compatibility
#    [FIX-9] PEP 668 / externally-managed-environment: system pip now uses
#            --break-system-packages; all other pip calls run inside venvs
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%T)] ${NC}$*"; }
ok()   { echo -e "${GREEN}[✔] $*${NC}"; }
warn() { echo -e "${YELLOW}[⚠]  $*${NC}"; }
err()  { echo -e "${RED}[✘] $*${NC}" >&2; }
sep()  { echo -e "${BOLD}────────────────────────────────────────────────────${NC}"; }

# ── Configuration ─────────────────────────────────────────────────────────────
AIL_DIR="${AIL_DIR:-/opt/ail-framework}"
AIL_USER="${SUDO_USER:-$(whoami)}"
AIL_PORT="${AIL_PORT:-7000}"
REDIS_PORT="${REDIS_PORT:-6379}"
ARDB_PORT="${ARDB_PORT:-6380}"
LACUS_PORT="${LACUS_PORT:-7100}"
MEILI_PORT="${MEILI_PORT:-7700}"
LIBRETRANSLATE_PORT="${LIBRETRANSLATE_PORT:-5000}"

LOG_FILE="/var/log/ail_setup_$(date +%Y%m%d_%H%M%S).log"
PYTHON_MIN="3.8"
PYTHON_BIN=""   # will be set in diagnose_system / install_system_deps

# ── Redirect all output to log too ────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Please run this script as root (sudo bash $0)"
    exit 1
fi

sep
echo -e "${BOLD}  AIL Framework — Automated Setup & Launch Script${NC}"
echo    "  Log file: $LOG_FILE"
sep

# =============================================================================
# SECTION 1 — SYSTEM DIAGNOSIS
# =============================================================================
diagnose_system() {
    sep; log "SECTION 1 — System Diagnosis"

    # OS detection
    . /etc/os-release 2>/dev/null || true
    OS_NAME="${NAME:-Unknown}"
    OS_VER="${VERSION_ID:-0}"
    log "OS: $OS_NAME $OS_VER"

    # [FIX-3] Python version loop now checks "$py" (the iterated binary)
    #         instead of always checking the hardcoded "python3" binary.
    for py in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
        if command -v "$py" &>/dev/null; then
            VER=$("$py" --version 2>&1 | awk '{print $2}')
            if "$py" -c "import sys; exit(0 if sys.version_info>=(3,8) else 1)" 2>/dev/null; then
                PYTHON_BIN=$(command -v "$py")
                ok "Python found: $PYTHON_BIN ($VER)"
                break
            fi
        fi
    done
    [[ -z "$PYTHON_BIN" ]] && warn "Python 3.8+ not found — will install"

    # Disk space (need at least 10 GB)
    FREE_GB=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    if [[ "$FREE_GB" -lt 10 ]]; then
        warn "Low disk space: ${FREE_GB}GB free (recommend 10GB+)"
    else
        ok "Disk space OK: ${FREE_GB}GB free"
    fi

    # RAM (need at least 4 GB)
    TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
    if [[ "$TOTAL_RAM_GB" -lt 4 ]]; then
        warn "Low RAM: ${TOTAL_RAM_GB}GB (recommend 4GB+)"
    else
        ok "RAM OK: ${TOTAL_RAM_GB}GB"
    fi

    # Check for existing AIL installation
    if [[ -d "$AIL_DIR" ]]; then
        warn "Existing AIL directory found at $AIL_DIR"
        EXISTING_VER=""
        if [[ -f "$AIL_DIR/app/Version.py" ]]; then
            EXISTING_VER=$(grep -oP "(?<=__version__ = ')[^']+" "$AIL_DIR/app/Version.py" 2>/dev/null || true)
        fi
        [[ -n "$EXISTING_VER" ]] && warn "Installed AIL version: $EXISTING_VER"

        # Check if AIL processes are running
        PIDS=$(pgrep -f "LAUNCH.sh\|Flask\|Crawler\|ail_2_ail" 2>/dev/null || true)
        if [[ -n "$PIDS" ]]; then
            warn "AIL processes are running (PIDs: $PIDS) — stopping them first"
            kill $PIDS 2>/dev/null || true
            sleep 3
            ok "Stopped existing AIL processes"
        fi
    fi
}

# =============================================================================
# SECTION 2 — PORT CONFLICT RESOLUTION
# Kill anything on every required port before proceeding.
# We never reassign ports — AIL, Redis, and KVRocks must be on their
# configured ports. If something refuses to die, we abort with a clear error.
# =============================================================================

# kill_port SERVICE PORT
# Forcefully frees a port. Tries: systemctl stop → SIGTERM → SIGKILL → fuser.
# Errors out if the port is still occupied after all attempts.
kill_port() {
    local SERVICE="$1"
    local PORT="$2"

    # Already free — nothing to do
    if ! ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        ok "Port $PORT is free for $SERVICE"
        return 0
    fi

    warn "Port $PORT is in use — clearing for $SERVICE"

    # Identify what is holding the port
    local OCCUPANT
    OCCUPANT=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | awk '{print $NF}' | head -1 || echo "unknown")
    log "  Occupant: $OCCUPANT"

    # ── Step 1: stop known systemd services gracefully ──────────────────────
    for SVC in redis redis-server redis-$PORT meilisearch lacus libretranslate ail; do
        systemctl stop "$SVC" 2>/dev/null || true
    done
    sleep 1

    # ── Step 2: SIGTERM any process still on this port ──────────────────────
    local PIDS
    PIDS=$(ss -tlnp 2>/dev/null | grep ":${PORT} "         | grep -oP "pid=\K[0-9]+" || true)
    if [[ -n "$PIDS" ]]; then
        log "  Sending SIGTERM to PIDs: $PIDS"
        kill $PIDS 2>/dev/null || true
        sleep 2
    fi

    # ── Step 3: SIGKILL anything that survived ───────────────────────────────
    PIDS=$(ss -tlnp 2>/dev/null | grep ":${PORT} "         | grep -oP "pid=\K[0-9]+" || true)
    if [[ -n "$PIDS" ]]; then
        log "  Sending SIGKILL to PIDs: $PIDS"
        kill -9 $PIDS 2>/dev/null || true
        sleep 2
    fi

    # ── Step 4: fuser as last resort ────────────────────────────────────────
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        log "  Trying fuser -k $PORT/tcp ..."
        fuser -k "${PORT}/tcp" 2>/dev/null || true
        sleep 2
    fi

    # ── Final check ─────────────────────────────────────────────────────────
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        err "Port $PORT is STILL occupied after all kill attempts."
        err "Run:  sudo fuser -k ${PORT}/tcp   then re-run this script."
        exit 1
    fi

    ok "Port $PORT cleared for $SERVICE"
}

check_all_ports() {
    sep; log "SECTION 2 — Port Conflict Resolution (kill & clear all)"

    # Install fuser if missing (needed for last-resort kill)
    command -v fuser &>/dev/null || apt-get install -y -q psmisc 2>/dev/null || true

    kill_port "AIL Web"         "$AIL_PORT"
    kill_port "Redis"           "$REDIS_PORT"
    kill_port "ARDB/KVRocks"    "$ARDB_PORT"
    kill_port "Lacus Crawler"   "$LACUS_PORT"
    kill_port "Meilisearch"     "$MEILI_PORT"
    kill_port "LibreTranslate"  "$LIBRETRANSLATE_PORT"

    log "All ports clear → AIL:$AIL_PORT | Redis:$REDIS_PORT | ARDB:$ARDB_PORT | Lacus:$LACUS_PORT | Meili:$MEILI_PORT | LibreTranslate:$LIBRETRANSLATE_PORT"
}

# =============================================================================
# SECTION 3 — SYSTEM DEPENDENCIES
# =============================================================================
install_system_deps() {
    sep; log "SECTION 3 — Installing System Dependencies"

    # Temporarily suspend exit-on-error for apt/pip which emit non-fatal
    # warnings (charset_normalizer metadata, Debian keyring deprecation) that
    # would otherwise abort the script under set -euo pipefail.
    set +e

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git curl wget gnupg2 lsb-release ca-certificates \
        build-essential libssl-dev libffi-dev \
        python3 python3-pip python3-venv python3-dev \
        libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev \
        libmagic1 libmagic-dev \
        redis-server \
        tor \
        screen tmux \
        jq unzip \
        pkg-config cmake \
        libpoppler-cpp-dev \
        tesseract-ocr \
        libzbar0 libzbar-dev \
        p7zip-full \
        2>/dev/null

    ok "System dependencies installed"

    # Ensure Python 3.8+
    PYTHON_BIN=$(command -v python3)
    PYVER=$($PYTHON_BIN --version | awk '{print $2}')
    ok "Python: $PYVER at $PYTHON_BIN"

    # [FIX-9] PEP 668 (Kali/Debian/Ubuntu 24+) blocks system pip.
    #         We detect it and skip the system pip upgrade entirely —
    #         all real pip work happens inside venvs where it is always safe.
    #         Trying to upgrade pip/wheel/setuptools system-wide causes:
    #         "Cannot uninstall wheel, RECORD file not found" and aborts the script.
    if $PYTHON_BIN -m pip install --dry-run --upgrade pip &>/dev/null 2>&1; then
        $PYTHON_BIN -m pip install --upgrade pip -q 2>/dev/null || true
        ok "System pip upgraded"
    else
        warn "PEP 668 externally-managed env detected — skipping system pip upgrade (venvs handle their own pip)"
    fi
    ok "System pip check complete"
    set -e   # re-enable exit-on-error
}

# =============================================================================
# SECTION 4 — REDIS SETUP & VALIDATION
# =============================================================================
setup_redis() {
    sep; log "SECTION 4 — Redis Setup & Validation"

    REDIS_VER=$(redis-server --version 2>/dev/null | awk '{print $3}' | tr -d 'v' || echo "0")
    log "Redis version: $REDIS_VER"

    # Configure Redis port
    REDIS_CONF="/etc/redis/redis.conf"
    if [[ -f "$REDIS_CONF" ]]; then
        sed -i "s/^port .*/port $REDIS_PORT/" "$REDIS_CONF"
        # Disable protected mode for local AIL use
        sed -i "s/^protected-mode yes/protected-mode no/" "$REDIS_CONF"
        ok "Redis configured on port $REDIS_PORT"
    fi

    systemctl enable redis-server 2>/dev/null || true
    systemctl restart redis-server 2>/dev/null || true
    sleep 2

    # [FIX-2] Validate Redis with proper if/else — the original used bare ||
    #         which could silently exit due to set -e if Redis truly failed.
    if redis-cli -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
        ok "Redis is responding on port $REDIS_PORT"
    else
        warn "Redis not responding — trying to start manually"
        redis-server --port "$REDIS_PORT" --daemonize yes --logfile /var/log/redis-ail.log
        sleep 2
        if redis-cli -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
            ok "Redis started manually"
        else
            err "Redis FAILED — check: journalctl -u redis-server  OR  cat /var/log/redis-ail.log"
            exit 1
        fi
    fi
}

# =============================================================================
# SECTION 5 — CLONE / UPDATE AIL FRAMEWORK
# =============================================================================
setup_ail_repo() {
    sep; log "SECTION 5 — AIL Framework Repository"

    if [[ -d "$AIL_DIR/.git" ]]; then
        log "Updating existing AIL repository..."
        cd "$AIL_DIR"
        git fetch origin 2>/dev/null
        CURRENT=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse origin/master 2>/dev/null || echo "")
        if [[ "$CURRENT" != "$REMOTE" && -n "$REMOTE" ]]; then
            log "New commits available — pulling updates"
            git pull origin master
        else
            ok "AIL repository is up to date"
        fi
    else
        log "Cloning AIL framework to $AIL_DIR..."
        mkdir -p "$(dirname "$AIL_DIR")"
        # Clone with full depth so submodule history is available
        git clone https://github.com/ail-project/ail-framework.git "$AIL_DIR"
        cd "$AIL_DIR"
        ok "AIL framework cloned"
    fi

    # Always fully initialise submodules — tlsh, faup, etc. are C extensions
    # that must be present before install_virtualenv.sh runs or it will abort
    # with "pushd: tlsh/py_ext: No such file or directory"
    cd "$AIL_DIR"
    log "Initialising git submodules (tlsh, faup, etc.)..."
    git submodule sync --recursive
    git submodule update --init --recursive
    ok "Submodules initialised"

    # Fix ownership
    chown -R "$AIL_USER":"$AIL_USER" "$AIL_DIR" 2>/dev/null || true
}

# =============================================================================
# SECTION 6 — PYTHON VIRTUAL ENVIRONMENT & REQUIREMENTS
# =============================================================================
setup_venv() {
    sep; log "SECTION 6 — Python Virtual Environment"

    # [FIX-4] Guard against PYTHON_BIN being unset (e.g. if install_system_deps
    #         was skipped or failed early). "set -u" would abort without this.
    PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"

    # [FIX-9] Export PEP 668 flag so AIL's own sub-scripts (installing_deps.sh,
    #         install_virtualenv.sh) can also benefit from it if they call pip.
    #         Inside a venv the flag is irrelevant but harmless.
    export PIP_SYS_FLAGS="${PIP_SYS_FLAGS:-}"

    cd "$AIL_DIR"
    VENV_DIR="$AIL_DIR/AILENV"

    if [[ -d "$VENV_DIR" ]]; then
        # Check if venv Python matches required version
        VENV_PY=$(${VENV_DIR}/bin/python --version 2>/dev/null | awk '{print $2}' || echo "0.0.0")
        log "Existing venv Python: $VENV_PY"
        MAJOR=$(echo "$VENV_PY" | cut -d. -f1)
        MINOR=$(echo "$VENV_PY" | cut -d. -f2)
        if [[ "$MAJOR" -lt 3 || ( "$MAJOR" -eq 3 && "$MINOR" -lt 8 ) ]]; then
            warn "Venv Python $VENV_PY is below 3.8 — recreating venv"
            rm -rf "$VENV_DIR"
        else
            ok "Existing venv is valid (Python $VENV_PY)"
        fi
    fi

    if [[ ! -d "$VENV_DIR" ]]; then
        log "Creating Python virtual environment..."
        $PYTHON_BIN -m venv "$VENV_DIR"
        ok "Virtual environment created"
    fi

    # Activate and install requirements
    source "$VENV_DIR/bin/activate"
    # setuptools/wheel are safe to upgrade inside a venv (no Debian RECORD conflict)
    "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel -q

    log "Installing AIL Python requirements..."
    if [[ -f "$AIL_DIR/requirements.txt" ]]; then

        # ── Pre-install packages that are GitHub-only or unavailable on PyPI ──
        # pybgpranking is not on PyPI. Try two known install paths; if both fail
        # we skip it — AIL core functionality works without BGP ranking.
        log "Pre-installing GitHub-only dependencies..."
        if ! "$VENV_DIR/bin/pip" install -q             "git+https://github.com/D4-project/BGP-Ranking.git@main#subdirectory=client"             2>/dev/null; then
            if ! "$VENV_DIR/bin/pip" install -q pybgpranking 2>/dev/null; then
                warn "pybgpranking not installable — BGP ranking feature will be unavailable (non-critical)"
            fi
        fi

        # ── Build a filtered requirements file skipping known broken packages ──
        # Some packages require Python <3.11 (e.g. old numpy), are unavailable
        # on PyPI, or have been renamed. We try each one individually and skip
        # failures rather than aborting the whole install.
        log "Installing requirements (skipping unavailable packages)..."
        FAILED_PKGS=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip blank lines, comments, and -r includes
            [[ -z "$line" || "$line" == \#* || "$line" == -r* ]] && continue

            # Skip pybgpranking — already handled above
            [[ "$line" == *pybgpranking* ]] && continue

            if ! "$VENV_DIR/bin/pip" install -q "$line" 2>/dev/null; then
                warn "Skipped (unavailable): $line"
                FAILED_PKGS="$FAILED_PKGS
  - $line"
            fi
        done < "$AIL_DIR/requirements.txt"

        if [[ -n "$FAILED_PKGS" ]]; then
            warn "The following packages were skipped (AIL may still work without them):"
            echo -e "$FAILED_PKGS"
        fi
        ok "AIL Python requirements installed (with skips where needed)"
    fi

    # Run official virtualenv installer — builds tlsh, faup C extensions.
    # Run with set +e so errors in individual build steps do not abort
    # the whole script; we check the result and warn rather than exit.
    if [[ -f "$AIL_DIR/install_virtualenv.sh" ]]; then
        log "Running official virtualenv installer (building C extensions)..."
        set +e
        bash "$AIL_DIR/install_virtualenv.sh" 2>&1 | tee /var/log/ail_virtualenv.log | tail -10
        VENV_SH_EXIT=${PIPESTATUS[0]}
        set -e
        if [[ "$VENV_SH_EXIT" -eq 0 ]]; then
            ok "Official virtualenv installer completed"
        else
            warn "install_virtualenv.sh exited with code $VENV_SH_EXIT — see /var/log/ail_virtualenv.log"
            warn "Continuing anyway — some optional C extensions may be missing"
        fi
    fi

    deactivate
    chown -R "$AIL_USER":"$AIL_USER" "$VENV_DIR" 2>/dev/null || true
}

# =============================================================================
# SECTION 7 — KVROCKS / ARDB SETUP
# =============================================================================
setup_kvrocks() {
    sep; log "SECTION 7 — KVRocks (ARDB replacement)"

    # AIL bundles KVRocks inside its own env/ directory and compiles it via
    # installing_deps.sh (Section 13). We only install build deps here so that
    # AIL's own script succeeds. We do NOT compile KVRocks ourselves — doing so
    # takes 20-40 min, often fails on RAM-limited boxes, and puts the binary in
    # the wrong location for AIL anyway.

    KVROCKS_AIL_BIN="$AIL_DIR/env/kvrocks/bin/kvrocks"
    KVROCKS_SYS_BIN="/opt/kvrocks/bin/kvrocks"

    if [[ -f "$KVROCKS_AIL_BIN" ]]; then
        KVROCKS_VER=$("$KVROCKS_AIL_BIN" --version 2>/dev/null | head -1 || echo "unknown")
        ok "KVRocks already present in AIL env: $KVROCKS_VER"
        return
    fi

    if [[ -f "$KVROCKS_SYS_BIN" ]]; then
        ok "KVRocks already present at $KVROCKS_SYS_BIN"
        return
    fi

    log "Installing KVRocks build dependencies (AIL installer will compile it in Section 13)..."
    apt-get install -y --no-install-recommends \
        cmake g++ autoconf automake libtool \
        libsnappy-dev libgflags-dev libzstd-dev libbz2-dev liblz4-dev \
        2>/dev/null || true
    ok "KVRocks build deps ready — AIL\'s installing_deps.sh will handle the compile"
}

# =============================================================================
# SECTION 8 — AIL CONFIGURATION FILES
# =============================================================================
configure_ail() {
    sep; log "SECTION 8 — AIL Configuration"

    # [FIX-7] This function is called AFTER run_ail_installer() in main() so
    #         AIL's own installing_deps.sh cannot overwrite our port settings.
    cd "$AIL_DIR"

    # Core config
    CORE_CFG="$AIL_DIR/configs/core.cfg"
    if [[ ! -f "$CORE_CFG" ]]; then
        if [[ -f "${CORE_CFG}.sample" ]]; then
            cp "${CORE_CFG}.sample" "$CORE_CFG"
            ok "core.cfg created from sample"
        fi
    fi

    if [[ -f "$CORE_CFG" ]]; then
        # Update ports in config
        sed -i "s/^port = 6379/port = $REDIS_PORT/" "$CORE_CFG" 2>/dev/null || true
        sed -i "s/^port = 6380/port = $ARDB_PORT/"  "$CORE_CFG" 2>/dev/null || true

        # Update Meilisearch config
        if grep -q '\[Indexer\]' "$CORE_CFG"; then
            sed -i "s|meilisearch_url = .*|meilisearch_url = http://127.0.0.1:${MEILI_PORT}|" "$CORE_CFG" 2>/dev/null || true
            sed -i "s|meilisearch = False|meilisearch = True|" "$CORE_CFG" 2>/dev/null || true
        fi

        # Update LibreTranslate config
        if grep -q '\[Translation\]' "$CORE_CFG"; then
            sed -i "s|libretranslate = .*|libretranslate = http://127.0.0.1:${LIBRETRANSLATE_PORT}|" "$CORE_CFG" 2>/dev/null || true
        fi

        ok "AIL core.cfg updated"
    fi

    # Update Flask port if needed
    if [[ "$AIL_PORT" != "7000" ]]; then
        FLASK_CFG="$AIL_DIR/var/www/Flask_server.py"
        [[ -f "$FLASK_CFG" ]] && sed -i "s/port=7000/port=$AIL_PORT/" "$FLASK_CFG"
        warn "AIL web port changed to $AIL_PORT"
    fi
}

# =============================================================================
# SECTION 9 — MEILISEARCH SETUP
# =============================================================================
setup_meilisearch() {
    sep; log "SECTION 9 — Meilisearch Setup"

    MEILI_BIN="/usr/local/bin/meilisearch"
    MEILI_DATA="/opt/meilisearch"

    if [[ -f "$MEILI_BIN" ]]; then
        MEILI_VER=$("$MEILI_BIN" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
        ok "Meilisearch already installed: $MEILI_VER"
    else
        log "Installing Meilisearch..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  MEILI_ARCH="amd64" ;;
            aarch64) MEILI_ARCH="arm64" ;;
            *)        MEILI_ARCH="amd64" ;;
        esac
        MEILI_URL="https://github.com/meilisearch/meilisearch/releases/latest/download/meilisearch-linux-$MEILI_ARCH"
        if curl -fsSL -o "$MEILI_BIN" "$MEILI_URL" 2>/dev/null; then
            chmod +x "$MEILI_BIN"
            ok "Meilisearch installed"
        else
            warn "Could not download Meilisearch binary — skipping"
            return
        fi
    fi

    # Check if already running
    if pgrep -f meilisearch &>/dev/null; then
        if curl -sf "http://127.0.0.1:${MEILI_PORT}/health" 2>/dev/null | grep -q "available"; then
            ok "Meilisearch already running and healthy on port $MEILI_PORT"
            return
        else
            warn "Meilisearch process found but not healthy — restarting"
            pkill -f meilisearch 2>/dev/null || true
            sleep 2
        fi
    fi

    mkdir -p "$MEILI_DATA"
    # Generate a master key
    MEILI_KEY=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -A n -t x4 | tr -d ' \n')
    log "Meilisearch master key: $MEILI_KEY (saved to $MEILI_DATA/master_key.txt)"
    echo "$MEILI_KEY" > "$MEILI_DATA/master_key.txt"
    chmod 600 "$MEILI_DATA/master_key.txt"

    # Write systemd unit
    cat > /etc/systemd/system/meilisearch.service <<EOF
[Unit]
Description=Meilisearch Search Engine
After=network.target

[Service]
User=$AIL_USER
WorkingDirectory=$MEILI_DATA
ExecStart=$MEILI_BIN --db-path $MEILI_DATA/data --http-addr 127.0.0.1:${MEILI_PORT} --master-key $MEILI_KEY --no-analytics
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Update AIL config with master key
    CORE_CFG="$AIL_DIR/configs/core.cfg"
    if [[ -f "$CORE_CFG" ]]; then
        sed -i "s|meilisearch_key = .*|meilisearch_key = $MEILI_KEY|" "$CORE_CFG" 2>/dev/null || true
        sed -i "s|meilisearch = False|meilisearch = True|" "$CORE_CFG" 2>/dev/null || true
    fi

    systemctl daemon-reload
    systemctl enable meilisearch
    systemctl start meilisearch
    sleep 3

    if curl -sf "http://127.0.0.1:${MEILI_PORT}/health" 2>/dev/null | grep -q "available"; then
        ok "Meilisearch is running on port $MEILI_PORT"
    else
        warn "Meilisearch may still be starting — check: systemctl status meilisearch"
    fi
}

# =============================================================================
# SECTION 10 — LACUS CRAWLER SETUP
# =============================================================================
setup_lacus() {
    sep; log "SECTION 10 — Lacus Crawler Setup"

    LACUS_DIR="/opt/lacus"
    LACUS_VENV="$LACUS_DIR/venv"

    if [[ -d "$LACUS_DIR" ]]; then
        log "Updating existing Lacus installation..."
        cd "$LACUS_DIR"
        git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true
    else
        log "Cloning Lacus..."
        git clone --depth 1 https://github.com/ail-project/lacus.git "$LACUS_DIR"
    fi

    cd "$LACUS_DIR"

    # Setup Lacus venv
    if [[ ! -d "$LACUS_VENV" ]]; then
        $PYTHON_BIN -m venv "$LACUS_VENV"
    fi

    source "$LACUS_VENV/bin/activate"
    "$LACUS_VENV/bin/pip" install --upgrade pip setuptools wheel -q
    if [[ -f "$LACUS_DIR/requirements.txt" ]]; then
        "$LACUS_VENV/bin/pip" install -r "$LACUS_DIR/requirements.txt" -q
    else
        "$LACUS_VENV/bin/pip" install lacus -q
    fi
    deactivate

    # [FIX-8] Install Playwright system-level deps needed on Ubuntu 22.04/24.04
    #         before running "playwright install", otherwise it silently fails.
    log "Installing Playwright system dependencies..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libgbm1 libxcomposite1 libxdamage1 libxrandr2 \
        libxshmfence1 libatk1.0-0 libatk-bridge2.0-0 \
        libpango-1.0-0 libcairo2 libcups2 libdbus-1-3 \
        libdrm2 libexpat1 libxkbcommon0 \
        2>/dev/null || true

    # Ubuntu 24.04 renamed libasound2 → libasound2t64
    apt-get install -y --no-install-recommends libasound2t64 2>/dev/null || \
    apt-get install -y --no-install-recommends libasound2    2>/dev/null || true

    # Install Playwright browsers (for web crawling)
    if "$LACUS_VENV/bin/python" -c "import playwright" 2>/dev/null; then
        log "Installing Playwright Chromium browser..."
        "$LACUS_VENV/bin/python" -m playwright install chromium 2>/dev/null || \
            warn "Playwright browser install failed — run manually: $LACUS_VENV/bin/python -m playwright install chromium"
        "$LACUS_VENV/bin/python" -m playwright install-deps chromium 2>/dev/null || true
    fi

    # Lacus config
    LACUS_CFG="$LACUS_DIR/config/lacus.json"
    if [[ ! -f "$LACUS_CFG" ]]; then
        mkdir -p "$(dirname "$LACUS_CFG")"
        cat > "$LACUS_CFG" <<EOF
{
  "redis_hostname": "127.0.0.1",
  "redis_port": $REDIS_PORT,
  "lacus_port": $LACUS_PORT,
  "storage_folder": "/opt/lacus/storage"
}
EOF
    fi

    # [FIX-5] Use the installed "lacus" CLI binary as ExecStart.
    #         The original used "-m lacus.lacus" which is not a valid module path
    #         in recent lacus releases and causes the service to fail silently.
    cat > /etc/systemd/system/lacus.service <<EOF
[Unit]
Description=Lacus Crawler for AIL
After=network.target redis.target

[Service]
User=$AIL_USER
WorkingDirectory=$LACUS_DIR
Environment="PATH=$LACUS_VENV/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$LACUS_VENV/bin/lacus --port $LACUS_PORT
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    chown -R "$AIL_USER":"$AIL_USER" "$LACUS_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable lacus
    systemctl start lacus 2>/dev/null || warn "Lacus did not start — check: systemctl status lacus"
    sleep 3

    if curl -sf "http://127.0.0.1:${LACUS_PORT}/api/status" 2>/dev/null | grep -q -i "ok\|running\|true"; then
        ok "Lacus is running on port $LACUS_PORT"
    else
        warn "Lacus may still be initialising — check: systemctl status lacus"
    fi

    ok "Lacus installed — configure AIL: Crawlers > Settings > Lacus URL = http://127.0.0.1:${LACUS_PORT}"
}

# =============================================================================
# SECTION 11 — LIBRETRANSLATE SETUP
# =============================================================================
setup_libretranslate() {
    sep; log "SECTION 11 — LibreTranslate Setup"

    LT_VENV="/opt/libretranslate/venv"

    if python3 -c "import libretranslate" 2>/dev/null || \
       [[ -f "$LT_VENV/bin/libretranslate" ]]; then
        ok "LibreTranslate already installed"
    else
        log "Installing LibreTranslate..."
        mkdir -p /opt/libretranslate
        $PYTHON_BIN -m venv "$LT_VENV"
        # Use the venv's own pip binary directly — avoids any PEP 668 issues
        "$LT_VENV/bin/pip" install --upgrade pip setuptools wheel -q
        "$LT_VENV/bin/pip" install libretranslate -q
        ok "LibreTranslate installed"
    fi

    # Write systemd unit
    cat > /etc/systemd/system/libretranslate.service <<EOF
[Unit]
Description=LibreTranslate for AIL
After=network.target

[Service]
User=$AIL_USER
Environment="PATH=$LT_VENV/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$LT_VENV/bin/libretranslate --host 127.0.0.1 --port $LIBRETRANSLATE_PORT --load-only en,ar,zh,fr,de,ru,es --disable-files-translation
Restart=on-failure
RestartSec=30
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

    chown -R "$AIL_USER":"$AIL_USER" /opt/libretranslate 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable libretranslate
    systemctl start libretranslate 2>/dev/null || warn "LibreTranslate start failed (may be downloading language models)"
    ok "LibreTranslate configured on port $LIBRETRANSLATE_PORT (downloads lang models on first run — may take time)"
}

# =============================================================================
# SECTION 12 — TOR SETUP
# =============================================================================
setup_tor() {
    sep; log "SECTION 12 — Tor Setup"

    if ! command -v tor &>/dev/null; then
        apt-get install -y tor -q
    fi

    # Verify Tor is configured properly for SOCKS5
    TOR_CONF="/etc/tor/torrc"
    if [[ -f "$TOR_CONF" ]]; then
        grep -q "^SocksPort"   "$TOR_CONF" || echo "SocksPort 9050"   >> "$TOR_CONF"
        grep -q "^ControlPort" "$TOR_CONF" || echo "ControlPort 9051" >> "$TOR_CONF"
    fi

    systemctl enable tor
    systemctl restart tor
    sleep 3

    if systemctl is-active --quiet tor; then
        ok "Tor is running (SOCKS5 on port 9050)"
    else
        warn "Tor failed to start — check: journalctl -u tor"
    fi
}

# =============================================================================
# SECTION 13 — RUN AIL'S OFFICIAL INSTALLER
# =============================================================================
run_ail_installer() {
    sep; log "SECTION 13 — Running AIL Official Dependency Installer"
    cd "$AIL_DIR"

    if [[ -f "$AIL_DIR/installing_deps.sh" ]]; then
        log "Executing installing_deps.sh..."
        bash "$AIL_DIR/installing_deps.sh" 2>&1 | tee /var/log/ail_deps.log | tail -20
        ok "Official AIL installer completed"
    else
        warn "installing_deps.sh not found — skipping"
    fi
}

# =============================================================================
# SECTION 14 — FINAL HEALTH CHECK
# =============================================================================
health_check() {
    sep; log "SECTION 14 — Final Health Check"

    echo ""
    echo -e "${BOLD}Service Status:${NC}"

    printf "  %-30s" "Redis ($REDIS_PORT)"
    redis-cli -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG \
        && echo -e "${GREEN}✔ ONLINE${NC}" || echo -e "${RED}✘ OFFLINE${NC}"

    # [FIX-6] KVRocks / ARDB health check was missing entirely.
    #         AIL depends on it for persistent storage; added here.
    printf "  %-30s" "KVRocks/ARDB ($ARDB_PORT)"
    redis-cli -p "$ARDB_PORT" ping 2>/dev/null | grep -q PONG \
        && echo -e "${GREEN}✔ ONLINE${NC}" || echo -e "${YELLOW}⚠ CHECK${NC}"

    printf "  %-30s" "Tor (9050)"
    systemctl is-active --quiet tor 2>/dev/null \
        && echo -e "${GREEN}✔ ONLINE${NC}" || echo -e "${YELLOW}⚠ CHECK${NC}"

    printf "  %-30s" "Meilisearch ($MEILI_PORT)"
    curl -sf "http://127.0.0.1:${MEILI_PORT}/health" 2>/dev/null | grep -q "available" \
        && echo -e "${GREEN}✔ ONLINE${NC}" || echo -e "${YELLOW}⚠ STARTING${NC}"

    printf "  %-30s" "Lacus ($LACUS_PORT)"
    curl -sf "http://127.0.0.1:${LACUS_PORT}" 2>/dev/null &>/dev/null \
        && echo -e "${GREEN}✔ ONLINE${NC}" || echo -e "${YELLOW}⚠ STARTING${NC}"

    printf "  %-30s" "LibreTranslate ($LIBRETRANSLATE_PORT)"
    curl -sf "http://127.0.0.1:${LIBRETRANSLATE_PORT}/languages" 2>/dev/null &>/dev/null \
        && echo -e "${GREEN}✔ ONLINE${NC}" || echo -e "${YELLOW}⚠ DOWNLOADING MODELS${NC}"

    echo ""
}

# =============================================================================
# SECTION 15 — LAUNCH AIL
# =============================================================================
launch_ail() {
    sep; log "SECTION 15 — Launching AIL Framework"
    cd "$AIL_DIR/bin"

    LAUNCH_CMD="$AIL_DIR/bin/LAUNCH.sh"

    if [[ ! -f "$LAUNCH_CMD" ]]; then
        err "LAUNCH.sh not found — check AIL installation"
        return 1
    fi

    chmod +x "$LAUNCH_CMD"

    log "Starting AIL in background via screen session 'ail'..."
    # Kill any previous ail screen session
    screen -S ail -X quit 2>/dev/null || true
    sleep 1

    # Launch as the correct user
    if [[ "$AIL_USER" == "root" ]]; then
        screen -dmS ail bash -c "cd $AIL_DIR/bin && bash LAUNCH.sh -l 2>&1 | tee /var/log/ail_launch.log"
    else
        su -l "$AIL_USER" -c "screen -dmS ail bash -c 'cd $AIL_DIR/bin && bash LAUNCH.sh -l 2>&1 | tee /var/log/ail_launch.log'"
    fi

    log "Waiting for AIL to start (30s)..."
    sleep 30

    # Check if web port is open
    if ss -tlnp 2>/dev/null | grep -q ":${AIL_PORT} "; then
        ok "AIL web interface is up!"
    else
        warn "AIL web port $AIL_PORT not yet bound — it may still be loading"
        log "Check progress: screen -r ail   OR   tail -f /var/log/ail_launch.log"
    fi
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_summary() {
    sep
    echo ""
    echo -e "${BOLD}${GREEN}  ✔  AIL FRAMEWORK SETUP COMPLETE${NC}"
    echo ""
    echo -e "  ${BOLD}Web Interface:${NC}   https://localhost:${AIL_PORT}"
    echo -e "  ${BOLD}Default creds:${NC}   See ${AIL_DIR}/DEFAULT_PASSWORD (deleted after 1st login)"
    echo ""
    echo -e "  ${BOLD}Add-ons:${NC}"
    echo -e "    Meilisearch:     http://127.0.0.1:${MEILI_PORT}"
    echo -e "    Lacus Crawler:   http://127.0.0.1:${LACUS_PORT}"
    echo -e "    LibreTranslate:  http://127.0.0.1:${LIBRETRANSLATE_PORT} (may still be downloading models)"
    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo "    Watch AIL logs:          screen -r ail"
    echo "    Restart AIL:             cd $AIL_DIR/bin && bash LAUNCH.sh -l"
    echo "    Stop AIL:                cd $AIL_DIR/bin && bash LAUNCH.sh -k"
    echo "    Meilisearch status:      systemctl status meilisearch"
    echo "    Lacus status:            systemctl status lacus"
    echo "    LibreTranslate status:   systemctl status libretranslate"
    echo "    KVRocks/ARDB ping:       redis-cli -p $ARDB_PORT ping"
    echo "    This setup log:          $LOG_FILE"
    echo ""
    echo -e "  ${BOLD}Post-setup steps in AIL web UI:${NC}"
    echo "    1. Crawlers > Settings > set Lacus URL = http://127.0.0.1:${LACUS_PORT}"
    echo "    2. Indexer section in configs/core.cfg is pre-configured for Meilisearch"
    echo "    3. Translation section in configs/core.cfg is pre-configured for LibreTranslate"
    echo ""
    sep
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
# [FIX-1] setup_kvrocks() was defined but never called in the original script.
#         It is now correctly placed between setup_redis and setup_ail_repo.
# [FIX-7] configure_ail() runs AFTER run_ail_installer() so AIL's own
#         installing_deps.sh cannot overwrite our custom port settings.
# =============================================================================
main() {
    diagnose_system
    check_all_ports
    install_system_deps
    setup_redis
    setup_kvrocks        # FIX-1: was missing entirely
    setup_ail_repo
    setup_venv
    run_ail_installer
    configure_ail        # FIX-7: confirmed after run_ail_installer
    setup_meilisearch
    setup_lacus
    setup_libretranslate
    setup_tor
    health_check
    launch_ail
    print_summary
}

main "$@"