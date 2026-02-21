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
MONITOR_PID=""
MONITOR_FIFO="/tmp/owntone-monitor-$$.fifo"
MONITOR_LOG="${MONITOR_LOG_PATH:-/tmp/owntone-monitor.log}"
STREAM_LOG="${STREAM_LOG_PATH:-/tmp/owntone-stream.log}"
SILENCE_COUNT=0
SILENCE_START_TS=""
NO_LEVEL_WARN_TS=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

get_owntone_state() {
    curl -s "$OWNTONE_BASE_URL/api/player" \
        | jq -r '.state // .playback_state // .player.state // empty'
}

is_owntone_playing() {
    local state
    state=$(get_owntone_state)
    [ "$state" = "play" ] || [ "$state" = "playing" ]
}

ensure_owntone_playing() {
    local retries="${OWNTONE_PLAY_RETRIES:-5}"
    local retry_delay="${OWNTONE_PLAY_RETRY_DELAY:-1}"
    local attempt=1
    local state=""

    while [ "$attempt" -le "$retries" ]; do
        if is_owntone_playing; then
            return 0
        fi

        state=$(get_owntone_state)
        log "OwnTone not playing yet (state: ${state:-unknown}), attempt ${attempt}/${retries}"
        curl -s -X POST "$OWNTONE_BASE_URL/api/queue/items/add?clear=true&playback=start&uris=$OWNTONE_STREAM_URI" >/dev/null
        sleep "$retry_delay"
        attempt=$((attempt + 1))
    done

    state=$(get_owntone_state)
    log "OwnTone still not playing after ${retries} attempts (state: ${state:-unknown})"
    return 1
}

start_monitor() {
    local sample_duration="${AUDIO_SAMPLE_DURATION:-$CHECK_INTERVAL}"
    local chunk_frames

    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        return
    fi

    rm -f "$MONITOR_FIFO"
    mkfifo "$MONITOR_FIFO"
    chunk_frames=$(awk -v d="$sample_duration" 'BEGIN { v=int(d*44100); if (v < 1) v=1; print v }')
    echo "$(date '+%Y-%m-%d %H:%M:%S') monitor start: dev=$MONITOR_DEV sample_duration=${sample_duration}s chunk_frames=$chunk_frames" >> "$MONITOR_LOG"

    log "Starting monitor process..."
    (
        arecord -q -D "$MONITOR_DEV" -f S16_LE -c 2 -r 44100 -t raw --buffer-size=131072 --period-size=32768 2>>"$MONITOR_LOG" \
            | perl -e '
                use strict;
                use warnings;
                my $chunk_frames = $ARGV[0];
                my $chunk_bytes = $chunk_frames * 4; # 2 channels x 16-bit
                while (read(STDIN, my $buf, $chunk_bytes)) {
                    my @s = unpack("s<*", $buf);
                    my $n = scalar @s;
                    next if $n == 0;
                    my $sum = 0;
                    $sum += $_ * $_ for @s;
                    my $rms = sqrt($sum / $n) / 32768.0;
                    my $db = $rms > 0 ? int((20 * log($rms) / log(10)) + 0.5) : -100;
                    print "$db\n";
                }
            ' "$chunk_frames"
    ) > "$MONITOR_FIFO" &

    MONITOR_PID=$!
    exec 3<"$MONITOR_FIFO"
}

stop_monitor() {
    if [ -n "$MONITOR_PID" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') monitor stop: pid=$MONITOR_PID" >> "$MONITOR_LOG"
    fi

    exec 3<&- 2>/dev/null

    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null
        MONITOR_PID=""
    fi

    rm -f "$MONITOR_FIFO"
}

start_stream() {
    if [ -z "$STREAM_PID" ] || ! kill -0 $STREAM_PID 2>/dev/null; then
        log "Starting stream..."

        arecord -q -D "$STREAM_DEV" \
          -f S16_LE -c 2 -r 44100 -t raw \
          --buffer-size=524288 --period-size=131072 \
          > "$FIFO_PATH" 2>>"$STREAM_LOG" &

        STREAM_PID=$!
        sleep 0.2
        if ! kill -0 "$STREAM_PID" 2>/dev/null; then
            log "Stream capture failed to stay running (device/FIFO/permissions issue)"
            if [ -f "$STREAM_LOG" ]; then
                log "Stream error: $(tail -n1 "$STREAM_LOG")"
            fi
            STREAM_PID=""
            return 1
        fi

        SILENCE_COUNT=0
        SILENCE_START_TS=""

        ID=$(curl -s "$OWNTONE_BASE_URL/api/outputs" \
            | jq -r --arg n "$OUTPUT_NAME" '.outputs[] | select(.name==$n) | .id' \
            | head -n1)

        if [ -z "$ID" ] || [ "$ID" = "null" ]; then
            log "Owntone output not found: $OUTPUT_NAME"
            return 1
        fi

        curl -s -X PUT "$OWNTONE_BASE_URL/api/outputs/set" --data "{\"outputs\":[\"$ID\"]}" >/dev/null
        if ! ensure_owntone_playing; then
            log "Owntone failed to enter playing state"
            return 1
        fi

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

        log "✓ Stopped stream after ${SILENCE_COUNT}s of silence"
        STREAM_PID=""
        SILENCE_COUNT=0
        SILENCE_START_TS=""
    fi
}

cleanup() {
    log "Shutting down..."
    stop_stream
    stop_monitor
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

log "=========================================="
log "On audio input, auto stream to Airplay device"
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
log "Sample duration: ${AUDIO_SAMPLE_DURATION:-$CHECK_INTERVAL}s"
log "Stop after: ${SILENCE_TIMEOUT}s silence"
log "=========================================="

mkdir -p "$(dirname "$FIFO_PATH")"
if [ ! -p "$FIFO_PATH" ]; then
    rm -f "$FIFO_PATH"
    mkfifo "$FIFO_PATH"
fi

start_monitor
log "Testing monitor device..."
if read -r -t 2 TEST_LEVEL <&3; then
    log "Initial level: ${TEST_LEVEL}dB"
else
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        log "No initial monitor level received within 2s (monitor alive, waiting for audio)"
    else
        log "No initial monitor level received within 2s (monitor exited)"
        if [ -f "$MONITOR_LOG" ]; then
            log "Monitor error: $(tail -n1 "$MONITOR_LOG")"
        fi
    fi
fi

while true; do
    if ! read -r -t "$CHECK_INTERVAL" DB_INT <&3; then
        if [ -n "$MONITOR_PID" ] && ! kill -0 "$MONITOR_PID" 2>/dev/null; then
            log "Monitor process stopped, restarting..."
            stop_monitor
            start_monitor
            sleep "${MONITOR_RESTART_DELAY:-1}"
            continue
        fi

        NOW_TS=$(date +%s)
        if [ $((NOW_TS - NO_LEVEL_WARN_TS)) -ge 10 ]; then
            log "Monitor alive but no level sample yet; treating as silence"
            NO_LEVEL_WARN_TS=$NOW_TS
        fi
        DB_INT=-100
    fi

    if [ -n "$STREAM_PID" ] && kill -0 $STREAM_PID 2>/dev/null; then
        log "Streaming - Level: ${DB_INT}dB"

        if [ "$DB_INT" -gt "$THRESHOLD" ]; then
            if [ $SILENCE_COUNT -gt 0 ]; then
                log "Audio resumed"
            fi
            SILENCE_COUNT=0
            SILENCE_START_TS=""
        else
            if [ -z "$SILENCE_START_TS" ]; then
                SILENCE_START_TS=$(date +%s.%N)
            fi

            SILENCE_COUNT=$(awk -v start="$SILENCE_START_TS" -v now="$(date +%s.%N)" 'BEGIN {printf "%.0f", (now - start)}')
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
        SILENCE_START_TS=""
    fi
done
