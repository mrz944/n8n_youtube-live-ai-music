# YouTube Live AI Music Stream

Continuous AI-generated music playing on a YouTube Live stream. Viewers influence the mood and genre of upcoming songs through YouTube Live chat. An LLM (Claude on AWS Bedrock) analyzes chat messages and adjusts the music generation prompts accordingly.

## Architecture

```
+--- Docker Container (n8n) -----------------------------------+
|                                                               |
|  Chat Monitor         mood.json      Music Generator          |
|  (every 45s)         ----------->    (every 3 min)            |
|  Bedrock Claude                      Suno API -> MP3          |
|                                           |                   |
|  Stream Controller                        v                   |
|  (webhook)            /home/node/.n8n/music-stream/           |
|  YouTube Live API     queue/ <- MP3 files written here        |
|  Saves state.json     state.json, mood.json                   |
|                                                               |
+---------------------------+-----------------------------------+
                            | Volume: ~/.n8n:/home/node/.n8n
                            v
+--- Host (Mikrus VPS) ----------------------------------------+
|                                                               |
|  ~/.n8n/music-stream/                                         |
|  +-- queue/        <- FFmpeg reads MP3s from here             |
|  +-- playing/      <- Currently streaming                     |
|  +-- played/       <- Already played                          |
|  +-- state.json    <- RTMP key, broadcast ID                  |
|  +-- mood.json     <- Current mood from chat analysis         |
|  +-- scripts/                                                 |
|      +-- stream.sh <- FFmpeg loop (runs on HOST)              |
|                                                               |
|  FFmpeg: queue/*.mp3 -> RTMP -> YouTube Live                  |
|                                                               |
+---------------------------------------------------------------+
```

## Workflows

### 1. Music Generator (`z5u89ssBnW6Bq74G`) - 14 nodes

**Trigger:** Schedule every 3 minutes

**Flow:**
1. Check queue size (count MP3 files in queue directory)
2. If fewer than 2 songs queued, generate a new one:
   - Read current mood from `mood.json`
   - Craft a descriptive prompt from mood data (genre, energy, tempo)
   - POST to Suno API to start generation
   - Poll for completion (90s wait + status check loop)
   - Download the generated MP3
   - Save to queue directory
   - Update statistics in `state.json`

**Credentials:** Suno API (HTTP Header Auth)

### 2. Stream Controller (`vO3TJ3FajfSHXICz`) - 17 nodes

**Trigger:** Webhook POST `/stream-control`

**Actions:**
- `{"action": "start"}` - Creates YouTube Live Broadcast + Stream, binds them, saves RTMP info to state.json, transitions to live
- `{"action": "stop"}` - Ends YouTube broadcast, marks stream as inactive
- `{"action": "status"}` - Returns full system status (queue size, current mood, stream state)

**Note:** After starting, you must manually run `stream.sh` on the host to begin FFmpeg streaming. The n8n container cannot start processes on the host.

**Credentials:** Google OAuth2 API (YouTube Data API v3)

### 3. Chat Monitor (`9rAeeRlcMVWoryaE`) - 11 nodes

**Trigger:** Schedule every 45 seconds

**Flow:**
1. Read stream state; exit early if no active stream
2. GET YouTube Live Chat messages via API
3. Save pagination token for next poll
4. Filter and format messages (last 20 meaningful messages)
5. Feed to Claude on AWS Bedrock via Basic LLM Chain
6. Parse LLM's JSON response (mood, genre, energy, tempo, description)
7. Validate and write to `mood.json` (atomic write)

The Music Generator reads `mood.json` on each generation cycle, so chat influence takes effect on the next song.

**Credentials:** Google OAuth2 API + AWS (Bedrock)

## Prerequisites

### 1. n8n Credentials

| Credential | Type | Purpose |
|------------|------|---------|
| Google OAuth2 API | `googleOAuth2Api` | YouTube Live Broadcast + Chat APIs |
| Suno API | `httpHeaderAuth` | Music generation (Header: `Authorization: Bearer <key>`) |
| AWS | `aws` | Bedrock Claude access |

**Google OAuth2 setup:**
- Google Cloud project with YouTube Data API v3 enabled
- OAuth2 credentials (Web application)
- Scopes: `youtube`, `youtube.force-ssl`

**AWS IAM requirements:**
- IAM user/role with `bedrock:InvokeModel` permission
- Claude model access enabled in your AWS region (e.g., us-east-1)

### 2. Host Setup (Mikrus VPS)

```bash
# Create directories (uses existing n8n volume mount)
mkdir -p ~/.n8n/music-stream/{queue,playing,played,scripts,logs}

# Install FFmpeg
sudo apt-get install -y ffmpeg

# Create background image for the video stream
ffmpeg -f lavfi -i "color=c=0x1a1a2e:s=1280x720:d=1" \
  -frames:v 1 ~/.n8n/music-stream/background.png

# Initialize state files
echo '{"mood":"chill electronic","genre":"lofi","energy":"medium","tempo":90,"description":"Relaxing lofi beats"}' \
  > ~/.n8n/music-stream/mood.json
echo '{"broadcastId":null,"streamKey":null,"liveChatId":null,"isActive":false,"songsPlayed":0}' \
  > ~/.n8n/music-stream/state.json

# Copy the streaming script
cp stream.sh ~/.n8n/music-stream/scripts/stream.sh
chmod +x ~/.n8n/music-stream/scripts/stream.sh
```

No Docker container changes needed - uses the existing `~/.n8n` volume mount.

## Usage

### Starting a Stream

1. **Activate the Music Generator workflow** in n8n - it will start pre-generating songs
2. **Wait for 2+ songs** to appear in the queue (check via status endpoint)
3. **Start the broadcast** via webhook:
   ```bash
   curl -X POST https://your-n8n-domain/webhook/stream-control \
     -H "Content-Type: application/json" \
     -d '{"action": "start"}'
   ```
4. **Start FFmpeg on the host:**
   ```bash
   nohup ~/.n8n/music-stream/scripts/stream.sh > /dev/null 2>&1 &
   ```
5. **Activate the Chat Monitor workflow** in n8n

### Checking Status

```bash
curl -X POST https://your-n8n-domain/webhook/stream-control \
  -H "Content-Type: application/json" \
  -d '{"action": "status"}'
```

### Stopping a Stream

1. **Stop FFmpeg on the host:**
   ```bash
   kill $(cat ~/.n8n/music-stream/stream.pid)
   ```
2. **End the broadcast:**
   ```bash
   curl -X POST https://your-n8n-domain/webhook/stream-control \
     -H "Content-Type: application/json" \
     -d '{"action": "stop"}'
   ```
3. **Deactivate** Chat Monitor and Music Generator workflows in n8n

## Chat Interaction

Viewers can influence the music by posting messages in the YouTube Live chat. The Chat Monitor polls every 45 seconds and feeds messages to Claude, which interprets the overall vibe. Examples:

- "play some jazz" -> switches to jazz genre
- "more energy!" -> increases energy level and tempo
- "chill vibes please" -> switches to relaxed lofi
- "dubstep time" -> switches to dubstep with high energy
- "something tropical" -> tropical house mood

The LLM considers all recent messages holistically rather than picking a single command. If no clear music preference is expressed, the current mood continues unchanged.

## File Structure

```
youtube-live-ai-music/
+-- README.md                          # This file
+-- stream.sh                          # FFmpeg streaming script (copy to host)
+-- workflow-music-generator.json      # n8n workflow backup
+-- workflow-stream-controller.json    # n8n workflow backup
+-- workflow-chat-monitor.json         # n8n workflow backup
```

## Troubleshooting

**FFmpeg can't connect to RTMP:**
- Verify state.json has valid rtmpUrl and streamKey
- Ensure the YouTube broadcast is in "testing" or "live" state
- Check network connectivity from the VPS

**No songs being generated:**
- Verify Suno API credentials are configured in n8n
- Check the Music Generator workflow execution logs
- Ensure /home/node/.n8n/music-stream/queue/ is writable inside the container

**Chat mood not changing:**
- Verify AWS Bedrock credentials and Claude model access
- Check Chat Monitor execution logs for API errors
- Ensure liveChatId is present in state.json (set after stream start)

**Gap between songs:**
- Each song is a separate FFmpeg invocation; 1-3 second gaps are normal
- YouTube handles brief RTMP interruptions gracefully
