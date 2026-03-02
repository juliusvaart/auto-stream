#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
err()  { echo -e "${RED}[error]${NC} $1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "Must be run as root — log in as root first"
[ -n "${SUDO_USER:-}" ]  && err "Must be run as root directly, not via sudo"

OWNTONE_BASE_URL="http://localhost:3689"
ENV_FILE="$SCRIPT_DIR/.env"

# ── --select-output mode ──────────────────────────────────────────────────────

if [ "${1:-}" = "--select-output" ]; then
    [ -f "$ENV_FILE" ] || err "No .env found at $ENV_FILE — run install first"

    log "Waiting for OwnTone API..."
    for i in $(seq 1 30); do
        if curl -sf "$OWNTONE_BASE_URL/api/config" >/dev/null 2>&1; then break; fi
        [ "$i" -eq 30 ] && err "OwnTone API not responding"
        sleep 1
    done

    SELECTED_OUTPUT=""
    mapfile -t names < <(curl -s "$OWNTONE_BASE_URL/api/outputs" 2>/dev/null \
        | jq -r '.outputs[] | select(.type == "airplay") | .name' 2>/dev/null)

    [ "${#names[@]}" -eq 0 ] && err "No Airplay outputs found"

    echo ""
    echo -e "${CYAN}Available Airplay outputs:${NC}"
    for i in "${!names[@]}"; do echo "  $((i+1))) ${names[$i]}"; done
    echo ""

    while true; do
        read -rp "Select Airplay output [1-${#names[@]}]: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#names[@]}" ]; then
            SELECTED_OUTPUT="${names[$((sel-1))]}"; break
        fi
        echo "Invalid selection, try again"
    done

    if grep -q '^OUTPUT_NAME=' "$ENV_FILE"; then
        sed -i "s|^OUTPUT_NAME=.*|OUTPUT_NAME=$SELECTED_OUTPUT|" "$ENV_FILE"
    else
        echo "OUTPUT_NAME=$SELECTED_OUTPUT" >> "$ENV_FILE"
    fi

    log "OUTPUT_NAME set to: $SELECTED_OUTPUT"
    systemctl restart auto-stream 2>/dev/null && log "auto-stream restarted" || true
    exit 0
fi
FIFO_DIR="/root/music/pipes"
FIFO_PATH="$FIFO_DIR/platenspeler.fifo"
OWNTONE_CONF="/etc/owntone.conf"

# ── OwnTone repo ──────────────────────────────────────────────────────────────

log "Adding OwnTone apt repository..."
wget -q -O - https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone.gpg \
    | gpg --dearmor --output /usr/share/keyrings/owntone-archive-keyring.gpg
wget -q -O /etc/apt/sources.list.d/owntone.list \
    https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone-trixie.list

# ── Packages ──────────────────────────────────────────────────────────────────

log "Installing packages..."
apt-get update -q
apt-get install -y git owntone alsa-utils sox bc curl jq

# ── ALSA ──────────────────────────────────────────────────────────────────────

log "Configuring ALSA..."
cp "$SCRIPT_DIR/asound.conf" /root/.asoundrc

# ── PGA Gain ──────────────────────────────────────────────────────────────────

log "Setting HiFiBerry ADC PGA gain..."
echo ""
echo -e "${CYAN}PGA Gain sets the ADC input level. 12dB (value 24) is recommended for record players.${NC}"
read -rp "PGA Gain value [default: 24 = 12dB]: " PGA_INPUT
PGA_GAIN="${PGA_INPUT:-24}"

if amixer -c 0 set 'PGA Gain Left' "$PGA_GAIN" >/dev/null 2>&1; then
    amixer -c 0 set 'PGA Gain Right' "$PGA_GAIN" >/dev/null 2>&1
    alsactl store 2>/dev/null || true
    log "PGA Gain set to $PGA_GAIN and saved"
else
    warn "Could not set PGA Gain — is the HiFiBerry ADC audio card configured?"
    warn "You can set it manually later: amixer -c 0 set 'PGA Gain Left' 24"
fi

# ── FIFO pipes ────────────────────────────────────────────────────────────────

log "Creating FIFO pipes in $FIFO_DIR..."
mkdir -p "$FIFO_DIR"
[ ! -p "$FIFO_PATH" ]            && mkfifo "$FIFO_PATH"
[ ! -p "${FIFO_PATH}.metadata" ] && mkfifo "${FIFO_PATH}.metadata"

if [ -f "$SCRIPT_DIR/platenspeler.png" ]; then
    cp "$SCRIPT_DIR/platenspeler.png" "$FIFO_DIR/platenspeler.png"
fi

# ── OwnTone config ────────────────────────────────────────────────────────────

log "Configuring OwnTone music directory..."
if grep -q 'directories = {' "$OWNTONE_CONF"; then
    sed -i 's|directories = {[^}]*}|directories = { "/root/music" }|' "$OWNTONE_CONF"
else
    warn "Could not find 'directories' in $OWNTONE_CONF — add it manually:"
    warn '  directories = { "/root/music" }'
fi

# ── systemd service ───────────────────────────────────────────────────────────

log "Installing auto-stream service..."
sed "s|ExecStart=.*|ExecStart=$SCRIPT_DIR/owntone-auto-stream.sh|" \
    "$SCRIPT_DIR/auto-stream.service" \
    > /etc/systemd/system/auto-stream.service

systemctl daemon-reload
systemctl enable auto-stream

# ── Start OwnTone ─────────────────────────────────────────────────────────────

log "Starting OwnTone..."
systemctl restart owntone

# Wait for OwnTone API to be ready
log "Waiting for OwnTone API..."
for i in $(seq 1 30); do
    if curl -sf "$OWNTONE_BASE_URL/api/config" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "OwnTone API not responding — skipping Airplay selection"
    fi
    sleep 1
done

# ── Select Airplay output ─────────────────────────────────────────────────────

SELECTED_OUTPUT=""

select_airplay_output() {
    local raw
    raw=$(curl -s "$OWNTONE_BASE_URL/api/outputs" 2>/dev/null)

    local names
    mapfile -t names < <(echo "$raw" | jq -r '.outputs[] | select(.type == "airplay") | .name' 2>/dev/null)

    if [ "${#names[@]}" -eq 0 ]; then
        warn "No Airplay outputs found. Set OUTPUT_NAME in $ENV_FILE after adding Airplay devices."
        return
    fi

    echo ""
    echo -e "${CYAN}Available Airplay outputs:${NC}"
    for i in "${!names[@]}"; do
        echo "  $((i+1))) ${names[$i]}"
    done
    echo ""

    local selection
    while true; do
        read -rp "Select Airplay output [1-${#names[@]}]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && \
           [ "$selection" -ge 1 ] && [ "$selection" -le "${#names[@]}" ]; then
            SELECTED_OUTPUT="${names[$((selection-1))]}"
            break
        fi
        echo "Invalid selection, try again"
    done
}

select_airplay_output

# ── Auto-detect OWNTONE_STREAM_URI ────────────────────────────────────────────

STREAM_URI=""

log "Waiting for OwnTone library scan..."
sleep 8

STREAM_URI=$(curl -s "$OWNTONE_BASE_URL/api/search?type=tracks&expression=path+starts+with+%27$(python3 -c "import urllib.parse; print(urllib.parse.quote('$FIFO_DIR'))" 2>/dev/null || echo "$FIFO_DIR")%27" 2>/dev/null \
    | jq -r '.tracks.items[0].uri // empty' 2>/dev/null || true)

if [ -z "$STREAM_URI" ]; then
    # Fallback: try listing all tracks and match by path
    STREAM_URI=$(curl -s "$OWNTONE_BASE_URL/api/library/tracks" 2>/dev/null \
        | jq -r --arg p "$FIFO_PATH" '.items[] | select(.path == $p) | .uri // empty' 2>/dev/null | head -n1 || true)
fi

if [ -n "$STREAM_URI" ]; then
    log "Found stream URI: $STREAM_URI"
else
    warn "Could not auto-detect stream URI. After OwnTone scans the library,"
    warn "find it in the OwnTone UI and set OWNTONE_STREAM_URI in $ENV_FILE"
    STREAM_URI="library:track:1"
fi

# ── Write .env ────────────────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
    log "Creating $ENV_FILE..."
    cat > "$ENV_FILE" << EOF
FIFO_PATH=$FIFO_PATH
STREAM_DEV=stream
MONITOR_DEV=monitor
THRESHOLD=-50
CHECK_INTERVAL=5
SILENCE_TIMEOUT=300
OWNTONE_BASE_URL=$OWNTONE_BASE_URL
OUTPUT_NAME=${SELECTED_OUTPUT:-change_me}
OWNTONE_STREAM_URI=$STREAM_URI
# OWNTONE_VOLUME=50
EOF
else
    # Update OUTPUT_NAME and OWNTONE_STREAM_URI in existing .env
    if [ -n "$SELECTED_OUTPUT" ]; then
        if grep -q '^OUTPUT_NAME=' "$ENV_FILE"; then
            sed -i "s|^OUTPUT_NAME=.*|OUTPUT_NAME=$SELECTED_OUTPUT|" "$ENV_FILE"
        else
            echo "OUTPUT_NAME=$SELECTED_OUTPUT" >> "$ENV_FILE"
        fi
    fi
    if [ -n "$STREAM_URI" ] && [ "$STREAM_URI" != "library:track:1" ]; then
        if grep -q '^OWNTONE_STREAM_URI=' "$ENV_FILE"; then
            sed -i "s|^OWNTONE_STREAM_URI=.*|OWNTONE_STREAM_URI=$STREAM_URI|" "$ENV_FILE"
        else
            echo "OWNTONE_STREAM_URI=$STREAM_URI" >> "$ENV_FILE"
        fi
    fi
fi

# ── Start auto-stream ─────────────────────────────────────────────────────────

ENV_READY=true
if grep -q 'change_me\|library:track:1' "$ENV_FILE" 2>/dev/null; then
    ENV_READY=false
fi

if $ENV_READY; then
    systemctl start auto-stream
    STREAM_STATUS="$(systemctl is-active auto-stream)"
else
    STREAM_STATUS="not started (review $ENV_FILE)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════"
log "Install complete"
echo "══════════════════════════════════════════"
echo ""
echo "  OwnTone UI:  http://$(hostname).local:3689"
echo "  OwnTone API: http://$(hostname).local:3689/api"
echo ""
echo "  owntone:     $(systemctl is-active owntone)"
echo "  auto-stream: $STREAM_STATUS"
echo ""

if ! $ENV_READY; then
    warn "Review $ENV_FILE — then start the service:"
    echo "  systemctl start auto-stream"
    echo ""
fi
