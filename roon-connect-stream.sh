#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/.env}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Missing config file: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

required_vars=(
    STREAM_DEV
    MONITOR_DEV
    THRESHOLD
    CHECK_INTERVAL
    SILENCE_TIMEOUT
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "Missing required variable in $CONFIG_FILE: $var" >&2
        exit 1
    fi
done

STREAM_ACTIVE=false
SILENCE_COUNT=0
ROON_HELPER_PID=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

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

start_stream() {
    if [ "$STREAM_ACTIVE" = "false" ]; then
        log "Starting stream..."
        kill -USR1 "$ROON_HELPER_PID"
        STREAM_ACTIVE=true
        SILENCE_COUNT=0
        log "✓ Stream started"
    fi
}

stop_stream() {
    if [ "$STREAM_ACTIVE" = "true" ]; then
        kill -USR2 "$ROON_HELPER_PID"
        log "✓ Stopped stream after ${SILENCE_COUNT}s of silence"
        STREAM_ACTIVE=false
        SILENCE_COUNT=0
    fi
}

start_roon_helper() {
    export STREAM_DEV HTTP_PORT ROON_EXTENSION_ID ROON_DISPLAY_NAME
    (cd "$SCRIPT_DIR" && node roon-stream-helper.mjs) &
    ROON_HELPER_PID=$!
    log "Started Roon helper (PID: $ROON_HELPER_PID)"
}

cleanup() {
    log "Shutting down..."
    stop_stream
    if [ -n "$ROON_HELPER_PID" ]; then
        kill "$ROON_HELPER_PID" 2>/dev/null
        wait "$ROON_HELPER_PID" 2>/dev/null
    fi
    rm -f /tmp/check.wav
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

log "=========================================="
log "Platenspeler Roon Connect Auto-Stream"
log "=========================================="
log "Source: $STREAM_DEV"
log "Monitor: $MONITOR_DEV (dsnoop)"
log "HTTP port: ${HTTP_PORT:-4567}"
log "Roon extension: ${ROON_DISPLAY_NAME:-Platenspeler Auto-Stream}"
log "Threshold: ${THRESHOLD}dB"
log "Check interval: ${CHECK_INTERVAL}s"
log "Stop after: ${SILENCE_TIMEOUT}s silence"
log "=========================================="

start_roon_helper
sleep 2

log "Testing monitor device..."
TEST_LEVEL=$(check_audio_level)
log "Initial level: ${TEST_LEVEL}dB"

while true; do
    if ! kill -0 "$ROON_HELPER_PID" 2>/dev/null; then
        log "WARNING: Roon helper died — restarting..."
        STREAM_ACTIVE=false
        start_roon_helper
        sleep 2
    fi

    DB_INT=$(check_audio_level)

    if [ "$STREAM_ACTIVE" = "true" ]; then
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
                log "Listening for audio..."
                continue
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
