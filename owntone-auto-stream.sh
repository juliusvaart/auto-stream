#!/bin/bash

# Configuration
FIFO_PATH="/root/music/pipes/platenspeler.fifo"
MONITOR_DEV="monitor"
THRESHOLD=-40
CHECK_INTERVAL=2
SILENCE_TIMEOUT=10

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

        arecord -D stream \
          -f S16_LE -c 2 -r 44100 -t raw \
          --buffer-size=524288 --period-size=131072 \
          > "$FIFO_PATH" &

        STREAM_PID=$!
        SILENCE_COUNT=0

        OUTPUT_NAME="mini-i_Pro3_474"
        ID=$(curl -s http://localhost:3689/api/outputs \
            | jq -r --arg n "$OUTPUT_NAME" '.outputs[] | select(.name==$n) | .id' \
            | head -n1)

        curl -X PUT "http://localhost:3689/api/outputs/set" --data "{\"outputs\":[\"$ID\"]}"
        curl -X PUT "http://localhost:3689/api/player/volume?volume=50"
        curl -X POST "http://localhost:3689/api/queue/items/add?clear=true&playback=start&uris=library:track:1"

        log "✓ Stream started (PID: $STREAM_PID)"
    fi
}

stop_stream() {
    if [ -n "$STREAM_PID" ]; then
        kill $STREAM_PID 2>/dev/null
        wait $STREAM_PID 2>/dev/null

        curl -X POST "http://localhost:3689/api/player/stop"
        curl -X PUT "http://localhost:3689/api/queue/clear"

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
log "Source: stream"
log "Monitor: $MONITOR_DEV (dsnoop)"
log "FIFO: $FIFO_PATH"
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
