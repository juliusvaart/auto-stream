#!/bin/bash

# Configuration
AIRPLAY_IP="192.168.1.187"
AIRPLAY_PORT="7000"
RAOP_PLAY="/root/libraop/build/raop_play-linux-aarch64"
ALSA_DEV="stream"  # Now uses dsnoop
MONITOR_DEV="monitor"
THRESHOLD=-40
CHECK_INTERVAL=2
SILENCE_TIMEOUT=10
VOLUME=45

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

        ffmpeg -hide_banner -loglevel error \
            -f alsa -i "$ALSA_DEV" \
            -ac 2 -ar 44100 \
            -fflags nobuffer -flags low_delay \
            -f s16le pipe:1 2>/dev/null | \
            "$RAOP_PLAY" -p "$AIRPLAY_PORT" -v $VOLUME "$AIRPLAY_IP" - &

        STREAM_PID=$!
        SILENCE_COUNT=0
        log "✓ Stream started (PID: $STREAM_PID)"
    fi
}

stop_stream() {
    if [ -n "$STREAM_PID" ]; then
        pkill -P $STREAM_PID 2>/dev/null
        kill $STREAM_PID 2>/dev/null
        killall ffmpeg 2>/dev/null
        killall raop_play-linux-aarch64 2>/dev/null
        wait $STREAM_PID 2>/dev/null
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
log "HiFiBerry to AirPlay Auto-Stream"
log "=========================================="
log "Source: $ALSA_DEV (dsnoop)"
log "Monitor: $MONITOR_DEV (dsnoop)"
log "Target: $AIRPLAY_IP:$AIRPLAY_PORT"
log "Volume: $VOLUME%"
log "Threshold: ${THRESHOLD}dB"
log "Check interval: ${CHECK_INTERVAL}s"
log "Stop after: ${SILENCE_TIMEOUT}s silence"
log "=========================================="

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
