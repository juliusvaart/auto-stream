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
    FIFO_PATH
    STREAM_DEV
    MONITOR_DEV
    THRESHOLD
    CHECK_INTERVAL
    SILENCE_TIMEOUT
    OWNTONE_BASE_URL
    OUTPUT_NAME
    OWNTONE_STREAM_URI
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "Missing required variable in $CONFIG_FILE: $var" >&2
        exit 1
    fi
done

STREAM_PID=""
SILENCE_COUNT=0

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
    if [ -z "$STREAM_PID" ] || ! kill -0 $STREAM_PID 2>/dev/null; then
        log "Starting stream..."

        arecord -D "$STREAM_DEV" \
          -f S16_LE -c 2 -r 44100 -t raw \
          --buffer-size=524288 --period-size=131072 \
          > "$FIFO_PATH" &

        STREAM_PID=$!
        SILENCE_COUNT=0

        ID=$(curl -s "$OWNTONE_BASE_URL/api/outputs" \
            | jq -r --arg n "$OUTPUT_NAME" '.outputs[] | select(.name==$n) | .id' \
            | head -n1)

        #curl -s -X POST "$OWNTONE_BASE_URL/api/queue/items/add?clear=true&playback=start&uris=$OWNTONE_STREAM_URI" >/dev/null
        curl -s -X PUT "$OWNTONE_BASE_URL/api/outputs/set" --data "{\"outputs\":[\"$ID\"]}" >/dev/null

        if [ -n "${OWNTONE_VOLUME:-}" ]; then
            curl -s -X PUT "$OWNTONE_BASE_URL/api/player/volume?volume=$OWNTONE_VOLUME" >/dev/null
        fi

        log "✓ Stream started (PID: $STREAM_PID)"
    fi
}

stop_stream() {
    if [ -n "$STREAM_PID" ]; then
        kill $STREAM_PID 2>/dev/null
        wait $STREAM_PID 2>/dev/null

        curl -s -X POST "$OWNTONE_BASE_URL/api/player/stop" >/dev/null
        #curl -s -X PUT "$OWNTONE_BASE_URL/api/queue/clear" >/dev/null

        log "✓ Stopped stream after ${SILENCE_COUNT}s of silence"
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

log "=========================================="
log "HiFiBerry Auto-Stream"
log "=========================================="
log "Source: $STREAM_DEV"
log "Monitor: $MONITOR_DEV (dsnoop)"
log "FIFO: $FIFO_PATH"
log "Owntone API: $OWNTONE_BASE_URL"
log "Owntone output: $OUTPUT_NAME"
if [ -n "${OWNTONE_VOLUME:-}" ]; then
    log "Owntone volume: $OWNTONE_VOLUME"
else
    log "Owntone volume: (unchanged)"
fi
log "Owntone URI: $OWNTONE_STREAM_URI"
log "Threshold: ${THRESHOLD}dB"
log "Check interval: ${CHECK_INTERVAL}s"
log "Stop after: ${SILENCE_TIMEOUT}s silence"
log "=========================================="

mkdir -p "$(dirname "$FIFO_PATH")"
if [ ! -p "$FIFO_PATH" ]; then
    rm -f "$FIFO_PATH"
    mkfifo "$FIFO_PATH"
fi

# Test
log "Testing monitor device..."
TEST_LEVEL=$(check_audio_level)
log "Initial level: ${TEST_LEVEL}dB"

while true; do
    DB_INT=$(check_audio_level)

    if [ -n "$STREAM_PID" ] && kill -0 $STREAM_PID 2>/dev/null; then
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
