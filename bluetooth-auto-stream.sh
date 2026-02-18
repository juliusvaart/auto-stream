#!/bin/bash

# =========================
# HiFiBerry → Bluetooth Auto-Stream (aptX HD → AAC → auto)
# Requires: bluealsa (daemon) + libasound2-plugin-bluez + aplay + ffmpeg + sox + bc
# =========================

# Configuration
BT_MAC="00:13:EF:A0:08:32"          # <-- your headphones/speaker MAC
BT_SRV="org.bluealsa"
BT_PROFILE="a2dp"
CODEC_PRIMARY="aptx"
CODEC_FALLBACK="aac"

ALSA_DEV="stream"                   # your proven dsnoop capture PCM
MONITOR_DEV="monitor"               # your proven dsnoop monitor PCM

THRESHOLD=-50
CHECK_INTERVAL=2
SILENCE_TIMEOUT=10
VOLUME=100

# Prefer 48k for Bluetooth A2DP
RATE=48000
CHANNELS=2

STREAM_PID=""
SILENCE_COUNT=0
PIPELOG="/tmp/bt_stream.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- Audio level check (same as your AirPlay script) ---
check_audio_level() {
  arecord -D "$MONITOR_DEV" -f cd -d 1 /tmp/check.wav 2>/dev/null

  if [ ! -f /tmp/check.wav ]; then
    echo "-100"
    return
  fi

  FILE_SIZE=$(stat -c%s /tmp/check.wav 2>/dev/null)
  if [ "$FILE_SIZE" -lt 50000 ]; then
    rm -f /tmp/check.wav
    echo "-100"
    return
  fi

  STATS=$(sox /tmp/check.wav -n stat 2>&1)
  RMS=$(echo "$STATS" | grep "RMS.*amplitude" | awk '{print $3}')
  rm -f /tmp/check.wav

  if [ -z "$RMS" ] || [ "$(echo "$RMS > 0" | bc -l 2>/dev/null)" != "1" ]; then
    echo "-100"
    return
  fi

  DB=$(echo "20 * l($RMS) / l(10)" | bc -l 2>/dev/null)
  printf "%.0f" "$DB" 2>/dev/null || echo "-100"
}

# --- Bluetooth helpers ---
bt_connect() {
  command -v bluetoothctl >/dev/null 2>&1 || return 1
  bluetoothctl <<EOF >/dev/null 2>&1
power on
agent NoInputNoOutput
default-agent
trust $BT_MAC
connect $BT_MAC
EOF
  return 0
}

bt_disconnect() {
  command -v bluetoothctl >/dev/null 2>&1 || return 0
  bluetoothctl disconnect "$BT_MAC" >/dev/null 2>&1 || true
}

bt_pcm_exists() {
  # BlueALSA only lists PCMs for connected devices
  command -v bluealsa-aplay >/dev/null 2>&1 || return 1
  bluealsa-aplay -L 2>/dev/null | grep -q "DEV=${BT_MAC}"
}

bt_wait_for_pcm() {
  local timeout_s="${1:-20}"
  local waited=0
  while [ $waited -lt $timeout_s ]; do
    bt_pcm_exists && return 0
    bt_connect
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

bt_pcm() {
  local codec="$1"
  if [ -n "$codec" ]; then
    echo "bluealsa:DEV=${BT_MAC},PROFILE=${BT_PROFILE},SRV=${BT_SRV},CODEC=${codec},VOL=${VOLUME}"
  else
    # auto/default codec (usually SBC)
    echo "bluealsa:DEV=${BT_MAC},PROFILE=${BT_PROFILE},SRV=${BT_SRV},VOL=${VOLUME}"
  fi
}

codec_available() {
  local wanted="$1"
  bluealsa-aplay -L 2>/dev/null | grep -i -q "A2DP.*(${wanted})"
}

choose_bt_pcm() {
  # Prefer aptX HD if it is shown, else AAC, else auto
  if codec_available "$CODEC_PRIMARY"; then
    echo "$(bt_pcm "$CODEC_PRIMARY")"
    return
  fi
  if codec_available "$CODEC_FALLBACK"; then
    echo "$(bt_pcm "$CODEC_FALLBACK")"
    return
  fi
  echo "$(bt_pcm "")"
}

start_stream() {
  if [ -n "$STREAM_PID" ] && kill -0 "$STREAM_PID" 2>/dev/null; then
    return
  fi

  log "Starting Bluetooth stream..."

  if ! bt_wait_for_pcm 20; then
    log "✗ Bluetooth PCM not available (device not connected / A2DP not active)."
    return
  fi

  BT_PCM="$(choose_bt_pcm)"
  log "Bluetooth PCM: $BT_PCM"

  : > "$PIPELOG"

  # Start pipeline in its own process group; log any aplay/bluealsa errors
  setsid bash -c "
    set -o pipefail
    ffmpeg -hide_banner -loglevel error \
      -f alsa -i '${ALSA_DEV}' \
      -ac ${CHANNELS} -ar ${RATE} \
      -fflags nobuffer -flags low_delay \
      -f s16le pipe:1 2>>'${PIPELOG}' | \
    aplay -q -D '${BT_PCM}' -f S16_LE -c ${CHANNELS} -r ${RATE} 2>>'${PIPELOG}'
  " >>"$PIPELOG" 2>&1 &

  STREAM_PID=$!
  SILENCE_COUNT=0
  log "✓ Stream started (PGID leader PID: $STREAM_PID)"

  # If it dies immediately, print why
  sleep 0.5
  if ! kill -0 "$STREAM_PID" 2>/dev/null; then
    log "✗ Stream exited immediately. Last log lines:"
    tail -n 30 "$PIPELOG" | while IFS= read -r line; do log "  $line"; done
    STREAM_PID=""
  fi
}

stop_stream() {
  if [ -n "$STREAM_PID" ]; then
    kill -- -"$STREAM_PID" 2>/dev/null || true
    wait "$STREAM_PID" 2>/dev/null || true
    bt_disconnect
    log "✓ Stopped stream + disconnected Bluetooth after ${SILENCE_COUNT}s of silence"
    STREAM_PID=""
    SILENCE_COUNT=0
  fi
}

cleanup() {
  log "Shutting down..."
  stop_stream
  rm -f /tmp/check.wav
  exit 0
}

trap cleanup SIGTERM SIGINT EXIT

log "===================================================="
log "HiFiBerry → Bluetooth Auto-Stream (aptX HD → AAC → auto)"
log "===================================================="
log "Source:     $ALSA_DEV (dsnoop)"
log "Monitor:    $MONITOR_DEV (dsnoop)"
log "Target:     $BT_MAC (A2DP)"
log "Rate:       ${RATE} Hz"
log "Volume:     $VOLUME%"
log "Threshold:  ${THRESHOLD}dB"
log "Interval:   ${CHECK_INTERVAL}s"
log "Stop after: ${SILENCE_TIMEOUT}s silence"
log "===================================================="

log "Testing monitor device..."
TEST_LEVEL=$(check_audio_level)
log "Initial level: ${TEST_LEVEL}dB"

while true; do
  DB_INT=$(check_audio_level)

  if [ -n "$STREAM_PID" ] && kill -0 "$STREAM_PID" 2>/dev/null; then
    log "Streaming - Level: ${DB_INT}dB"

    if [ "$DB_INT" -gt "$THRESHOLD" ]; then
      if [ $SILENCE_COUNT -gt 0 ]; then
        log "Audio resumed"
      fi
      SILENCE_COUNT=0
    else
      ((SILENCE_COUNT += CHECK_INTERVAL))
      log "Silence: ${SILENCE_COUNT}s / ${SILENCE_TIMEOUT}s"

      if [ $SILENCE_COUNT -ge $SILENCE_TIMEOUT ]; then
        stop_stream
      fi
    fi
  else
    log "Idle - Level: ${DB_INT}dB"

    if [ "$DB_INT" -gt "$THRESHOLD" ]; then
      log "Audio detected → starting"
      start_stream
    fi

    SILENCE_COUNT=0
  fi

  sleep $CHECK_INTERVAL
done
