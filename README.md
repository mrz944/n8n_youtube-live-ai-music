# 🔊 Vibe Radio - 24/7 Chat Controlled Music Stream

Continuous AI-generated psychedelic rock streaming on YouTube Live. Viewers influence the mood and genre of upcoming songs through YouTube Live chat. An LLM (Claude on AWS Bedrock) analyzes chat messages and adjusts the music generation prompts accordingly. Each song features unique AI-generated cover artwork displayed during streaming.

## Architecture

```
+--- Docker Container (n8n) -----------------------------------+
|                                                               |
|  Chat Monitor         mood.json      Music Generator          |
|  (every 45s)         ----------->    (every 3 min)            |
|  Bedrock Claude                      Suno API -> MP3          |
|                                           |                   |
|  Stream Controller                        v                   |
|  (webhook)            /home/node/.n8n-files/music-stream/     |
|  YouTube Live API     queue/ <- MP3 files written here        |
|  Saves state.json     state.json, mood.json                   |
|                                                               |
+---------------------------+-----------------------------------+
                            | Volume: ~/.n8n-files:/home/node/.n8n-files
                            v
+--- Host (Mikrus VPS) ----------------------------------------+
|                                                               |
|  ~/.n8n-files/music-stream/                                   |
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

### 1. Music Generator (`z5u89ssBnW6Bq74G`) - 24 nodes

**Trigger:** Schedule every 3 minutes

**Flow:**
1. Count queue files via `Read/Write Files from Disk` (glob: `queue/*.mp3`)
2. Evaluate queue status in Code node (count items with binary data, set `needsGeneration`)
3. If fewer than 2 songs queued, generate new ones:
   - Read current mood via `Read/Write Files from Disk` (`mood.json`)
   - Parse mood binary data in Code node with fallback defaults (psychedelic rock style)
   - Build Suno V5 API request body from style description
   - POST to Suno API (`api.sunoapi.org`) to start generation (model V5, customMode, instrumental)
   - Poll task status for completion (30s wait + status check loop)
   - **Split Into Items** - Process ALL songs returned in `sunoData[]` array (Suno can return multiple variations)
   - **Generate Song ID** - Create unique filename with sanitized title: `song_<timestamp>_<trackId>_<Title>`
   - **Download Audio + Cover in parallel** - Fetch MP3 and cover image (JPG) from Suno response
   - **Save both files** to queue directory with matching basenames
   - Update state.json with song count and metadata

**New Features:**
- **Multi-song handling** - Saves ALL songs if Suno returns multiple variations (not just the first)
- **Cover images** - Downloads and saves cover art alongside each MP3
- **Readable filenames** - Includes song title: `song_1707329100_abc123_Vibe_Journey.mp3` and `.jpg`

**Note:** File operations use `Read/Write Files from Disk` nodes instead of `require('fs')` because the n8n task runner sandbox disallows the `fs` module.

**Credentials:** Suno API (HTTP Bearer Auth)

### 2. Stream Controller (`vO3TJ3FajfSHXICz`) - 17 nodes

**Trigger:** Webhook POST `/stream-control`

**Actions:**
- `{"action": "start"}` - Creates YouTube Live Broadcast + Stream with title "🔊 Vibe Radio - 24/7 Chat controlled music experience [Live]", binds them, saves RTMP info to state.json, transitions to live
- `{"action": "stop"}` - Ends YouTube broadcast, marks stream as inactive
- `{"action": "status"}` - Returns full system status (queue size, current mood, stream state)

**Stream Details:**
- **Title**: "🔊 Vibe Radio - 24/7 Chat controlled music experience [Live]"
- **Description**: "Vibe Radio is unique experience. Every song is played just once and mood of the stream is based on chat interaction."
- **Privacy**: Unlisted (can be changed to public in workflow)

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
6. Parse LLM's JSON response containing a rich style description, title, genre, and energy level
7. Validate and write to `mood.json` (atomic write)

The Music Generator reads `mood.json` on each generation cycle, so chat influence takes effect on the next song.

**mood.json format:**
```json
{
  "style": "A slow-tempo psychedelic rock track launches with swirling organs and gently-effected electric guitar, Warm, steady bass holds down a relaxed, syncopated drum groove, Fluid synth layers quietly float beneath, creating an enveloping, smooth sonic atmosphere throughout. 432 Hz",
  "title": "Vibe Journey",
  "genre": "psychedelic rock",
  "energy": "low"
}
```
The `style` field is passed directly to Suno V5 as the music generation prompt. Cover images are automatically generated by Suno alongside each track.

**Credentials:** Google OAuth2 API + AWS (Bedrock)

## Prerequisites

### 1. n8n Credentials

| Credential | Type | Purpose |
|------------|------|---------|
| Google OAuth2 API | `googleOAuth2Api` | YouTube Live Broadcast + Chat APIs |
| Suno API | `httpHeaderAuth` | Music generation via api.sunoapi.org (Header: `Authorization: Bearer <key>`) |
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
# Create directories (uses n8n-files volume mount)
mkdir -p ~/.n8n-files/music-stream/{queue,playing,played,scripts,logs}

# Install FFmpeg
sudo apt-get install -y ffmpeg

# Create background image for the video stream
ffmpeg -f lavfi -i "color=c=0x1a1a2e:s=1280x720:d=1" \
  -frames:v 1 ~/.n8n-files/music-stream/background.png

# Initialize state files
echo '{"style":"A slow-tempo psychedelic rock track launches with swirling organs and gently-effected electric guitar, Warm, steady bass holds down a relaxed, syncopated drum groove, Fluid synth layers quietly float beneath, creating an enveloping, smooth sonic atmosphere throughout. 432 Hz","title":"Vibe Journey","genre":"psychedelic rock","energy":"low"}' \
  > ~/.n8n-files/music-stream/mood.json
echo '{"broadcastId":null,"streamKey":null,"liveChatId":null,"isActive":false,"songsPlayed":0}' \
  > ~/.n8n-files/music-stream/state.json

# Copy the streaming script
cp stream.sh ~/.n8n-files/music-stream/scripts/stream.sh
chmod +x ~/.n8n-files/music-stream/scripts/stream.sh

# Set ownership for n8n container user (UID 1000:1000)
sudo chown -R 1000:1000 ~/.n8n-files
```

**Docker Volume Requirement**: The n8n container must have this volume mount:
```bash
-v ~/.n8n-files:/home/node/.n8n-files
```

This maps the host's `~/.n8n-files/music-stream/` to the container's `/home/node/.n8n-files/music-stream/`, allowing file nodes to access the music stream directory.

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
   nohup ~/.n8n-files/music-stream/scripts/stream.sh > /dev/null 2>&1 &
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
   kill $(cat ~/.n8n-files/music-stream/stream.pid)
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

The LLM considers all recent messages holistically rather than picking a single command. It outputs a rich, detailed style description that is passed directly to Suno V5 as the generation prompt. If no clear music preference is expressed, the style evolves subtly rather than staying identical.

## File Structure

### Project Files
```
youtube-live-ai-music/
+-- README.md                          # This file
+-- stream.sh                          # FFmpeg streaming script (copy to host)
+-- workflow-music-generator.json      # n8n workflow backup (updated: multi-song + covers)
+-- workflow-stream-controller.json    # n8n workflow backup (updated: new title/description)
+-- workflow-chat-monitor.json         # n8n workflow backup
```

### Runtime Directory Structure (on VPS)
```
~/.n8n-files/music-stream/
+-- queue/
|   +-- song_1707329100_abc123_Vibe_Journey.mp3
|   +-- song_1707329100_abc123_Vibe_Journey.jpg      ← Cover images
|   +-- song_1707329200_def456_Cosmic_Drift.mp3
|   +-- song_1707329200_def456_Cosmic_Drift.jpg
+-- playing/                                          ← Both MP3 and JPG move together
|   +-- (currently streaming files)
+-- played/                                           ← Both MP3 and JPG move together
|   +-- (already played songs with covers)
+-- scripts/
|   +-- stream.sh                                     ← FFmpeg streaming script
+-- logs/
|   +-- ffmpeg.log                                    ← Stream logs
+-- background.png                                     ← Fallback image (1280x720)
+-- state.json                                        ← Stream state and statistics
+-- mood.json                                         ← Current music style
```

**File Naming Convention:**
- MP3 and JPG files share the same basename
- Format: `song_<timestamp>_<trackId>_<SanitizedTitle>.ext`
- Titles are sanitized: special characters removed, spaces→underscores, max 50 chars
- Example: `song_1707329100_abc123_Vibe_Journey.mp3` and `.jpg`

## Troubleshooting

**FFmpeg can't connect to RTMP:**
- Verify state.json has valid rtmpUrl and streamKey
- Ensure the YouTube broadcast is in "testing" or "live" state
- Check network connectivity from the VPS

**No songs being generated:**
- Verify Suno API credentials are configured in n8n
- Check the Music Generator workflow execution logs
- Ensure /home/node/.n8n-files/music-stream/queue/ is writable inside the container

**Chat mood not changing:**
- Verify AWS Bedrock credentials and Claude model access
- Check Chat Monitor execution logs for API errors
- Ensure liveChatId is present in state.json (set after stream start)

**Gap between songs:**
- Each song is a separate FFmpeg invocation; 1-3 second gaps are normal
- YouTube handles brief RTMP interruptions gracefully

**Covers not displaying:**
- Check if `.jpg` files exist alongside `.mp3` files in queue/playing/played directories
- Verify file permissions: n8n container (UID 1000) must be able to write `.jpg` files
- Check FFmpeg logs: `tail -f ~/.n8n-files/music-stream/logs/ffmpeg.log`
- Look for "Using cover" vs "No cover found" messages in logs
- If cover download fails, stream will automatically fallback to `background.png`

**Only some songs have covers:**
- Normal! Covers are only generated for songs created after implementing this feature
- Old songs in `played/` directory will use `background.png` when replayed
- Over time, all songs in rotation will have covers

**Wrong cover displayed:**
- Verify filenames match: MP3 and JPG must have identical basenames
- Example: `song_123_Title.mp3` requires `song_123_Title.jpg`
- Check for orphaned cover files (`.jpg` without matching `.mp3`)

**Multiple songs not saving:**
- Check Music Generator workflow execution logs in n8n
- Verify "Split Into Items" node is processing all items from `sunoData[]` array
- Check `songsGenerated` counter in state.json (should increment correctly)
