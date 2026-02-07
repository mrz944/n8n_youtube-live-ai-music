#!/bin/bash
# YouTube Live AI Music Stream - FFmpeg Streaming Script
# Runs on the HOST (not inside the n8n Docker container)
# Reads MP3 files from the queue and streams them to YouTube via RTMP

MUSIC_DIR="$HOME/.n8n/music-stream"
QUEUE_DIR="$MUSIC_DIR/queue"
PLAYING_DIR="$MUSIC_DIR/playing"
PLAYED_DIR="$MUSIC_DIR/played"
BG_IMG="$MUSIC_DIR/background.png"
STATE_FILE="$MUSIC_DIR/state.json"
LOG_FILE="$MUSIC_DIR/logs/ffmpeg.log"
PID_FILE="$MUSIC_DIR/stream.pid"

# Write our PID for monitoring
echo $$ > "$PID_FILE"

# Extract RTMP URL from state.json
get_rtmp_url() {
    if [ ! -f "$STATE_FILE" ]; then
        echo ""
        return
    fi
    local rtmp_url stream_key
    rtmp_url=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('rtmpUrl',''))" < "$STATE_FILE" 2>/dev/null)
    stream_key=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('streamKey',''))" < "$STATE_FILE" 2>/dev/null)
    if [ -n "$rtmp_url" ] && [ -n "$stream_key" ]; then
        echo "${rtmp_url}/${stream_key}"
    fi
}

# Check if stream should be active
is_active() {
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi
    local active
    active=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('isActive', False))" < "$STATE_FILE" 2>/dev/null)
    [ "$active" = "True" ]
}

# Ensure directories exist
mkdir -p "$QUEUE_DIR" "$PLAYING_DIR" "$PLAYED_DIR" "$MUSIC_DIR/logs"

echo "[$(date)] Stream script started (PID: $$)" >> "$LOG_FILE"

RTMP_URL=$(get_rtmp_url)
if [ -z "$RTMP_URL" ]; then
    echo "[$(date)] ERROR: No RTMP URL found in state.json. Start the stream via n8n webhook first." >> "$LOG_FILE"
    echo "ERROR: No RTMP URL found in state.json. Start the stream via n8n webhook first."
    rm -f "$PID_FILE"
    exit 1
fi

echo "[$(date)] RTMP URL: $RTMP_URL" >> "$LOG_FILE"

# Check for background image
if [ ! -f "$BG_IMG" ]; then
    echo "[$(date)] Creating default background image..." >> "$LOG_FILE"
    ffmpeg -f lavfi -i "color=c=0x1a1a2e:s=1280x720:d=1" -frames:v 1 "$BG_IMG" 2>/dev/null
fi

# Cleanup on exit
cleanup() {
    echo "[$(date)] Stream script stopping (PID: $$)" >> "$LOG_FILE"
    rm -f "$PID_FILE"
    # Move any file in playing back to queue
    for f in "$PLAYING_DIR"/*.mp3; do
        [ -f "$f" ] && mv "$f" "$QUEUE_DIR/"
    done
    exit 0
}
trap cleanup SIGTERM SIGINT

# Main streaming loop
while true; do
    # Check if stream is still active
    if ! is_active; then
        echo "[$(date)] Stream marked as inactive in state.json. Exiting." >> "$LOG_FILE"
        cleanup
    fi

    # Re-read RTMP URL in case it changed
    NEW_RTMP_URL=$(get_rtmp_url)
    if [ -n "$NEW_RTMP_URL" ]; then
        RTMP_URL="$NEW_RTMP_URL"
    fi

    # Get next song from queue (oldest first = FIFO)
    NEXT=$(ls -1 "$QUEUE_DIR"/*.mp3 2>/dev/null | sort | head -1)

    if [ -n "$NEXT" ]; then
        FILENAME=$(basename "$NEXT")
        echo "[$(date)] Playing: $FILENAME" >> "$LOG_FILE"

        # Move to playing directory
        mv "$NEXT" "$PLAYING_DIR/$FILENAME"

        # Stream with FFmpeg: static image + audio → RTMP
        ffmpeg -re -loop 1 -i "$BG_IMG" -i "$PLAYING_DIR/$FILENAME" \
            -c:v libx264 -preset ultrafast -tune stillimage \
            -c:a aac -b:a 192k -ar 44100 \
            -pix_fmt yuv420p -shortest \
            -f flv "$RTMP_URL" 2>> "$LOG_FILE"

        FFMPEG_EXIT=$?
        echo "[$(date)] FFmpeg exited with code: $FFMPEG_EXIT for $FILENAME" >> "$LOG_FILE"

        # Move to played directory
        mv "$PLAYING_DIR/$FILENAME" "$PLAYED_DIR/$FILENAME"
    else
        # Queue empty, wait and retry
        sleep 5
    fi
done
