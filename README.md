# Platenspeler Auto-Stream

Detects audio from a record player via ALSA, streams it to Roon via the AudioInput API, and uses SongRec (Shazam) to identify tracks and update now-playing metadata automatically.

## How it works

1. `roon-connect-stream.sh` monitors the audio level on the ALSA monitor device
2. When audio is detected above threshold it sends `SIGUSR1` to `roon-stream-helper.mjs`, which starts a Roon AudioInput session and begins streaming
3. When silence persists for `SILENCE_TIMEOUT` seconds it sends `SIGUSR2` to stop the session
4. Every 30 seconds during playback, SongRec identifies the track and updates Roon's now-playing info (artist, title, cover art)

## System packages

```bash
# Audio capture and processing
sudo apt install -y alsa-utils sox ffmpeg bc

# SongRec (Shazam-based song recognition)
apt install rustup libasound2-dev gcc build-essential libc6-dev pkg-config libglib2.0-dev libsoup-3.0-dev libavcodec-dev libavformat-dev libavutil-dev libswresample-dev -y
rustup default stable
cargo install songrec --no-default-features -F ffmpeg

# Add Cargo to PATH
echo 'export PATH="$HOME/.cargo/bin:$PATH"' | tee -a ~/.profile ~/.bashrc
source ~/.bashrc

# Node.js (v18+ required)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs
```

## Node.js dependencies

```bash
cd /root/auto-stream
npm install
```

Dependencies (defined in `package.json`):

| Package | Source |
|---|---|
| `node-roon-api` | `github:roonlabs/node-roon-api` |
| `node-roon-api-audioinput` | `github:roonlabs/node-roon-api-audioinput` |
| `node-roon-api-settings` | `github:roonlabs/node-roon-api-settings` |
| `node-roon-api-status` | `github:roonlabs/node-roon-api-status` |
| `node-roon-api-transport` | `github:roonlabs/node-roon-api-transport` |

## ALSA configuration

Copy `asound.conf` to `/etc/asound.conf`. It sets up a `dsnoop` device so that both the stream and the audio level monitor can read from the same hardware capture device simultaneously.

```bash
sudo cp asound.conf /etc/asound.conf
```

The relevant ALSA device names used in `.env`:

| Device | Purpose |
|---|---|
| `stream` | Main capture device fed to Roon (via ffmpeg → FLAC) |
| `monitor` | Level-monitoring device used by the shell script |

## Configuration

Create `/root/auto-stream/.env`:

```bash
# ALSA devices (as defined in asound.conf)
STREAM_DEV=stream
MONITOR_DEV=monitor

# Audio detection
THRESHOLD=-40          # dB level above which audio is considered playing
CHECK_INTERVAL=5       # seconds between level checks
SILENCE_TIMEOUT=120    # seconds of silence before stopping the stream

# Roon
HTTP_PORT=4567
ROON_EXTENSION_ID=com.recordplayer.autostream
ROON_DISPLAY_NAME=Record player

# Logging (set to true to see per-tick level readings and recognition polling)
VERBOSE=false
```

## Systemd service

```bash
sudo cp auto-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable auto-stream
sudo systemctl start auto-stream
```

View logs:

```bash
journalctl -u auto-stream -f
```

## File layout

```
/root/auto-stream/
├── .env                      # Runtime configuration (not in repo)
├── asound.conf               # Copy to /etc/asound.conf
├── auto-stream.service       # Copy to /etc/systemd/system/
├── roon-connect-stream.sh    # Main shell loop (audio detection)
├── roon-stream-helper.mjs    # Node.js Roon + HTTP stream server
├── platenspeler.png          # Fallback artwork
└── package.json
```

## Authorising the extension in Roon

After starting the service, open Roon → **Settings → Extensions** and enable **Record player**. Then set the target zone in the extension settings.
