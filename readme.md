# Auto Stream from Raspberry Pi ADC to Airplay

Use [Owntone Server](https://github.com/owntone/owntone-server) to stream audio from a record player (or any audio source) to an Airplay device.

The script auto-detects when a record is playing and automatically starts streaming. After a configurable timeout (default 300s / 5min) the stream disconnects.

All config lives in a `.env` file — see `.env.example` for available options.

---

## Hardware

- Raspberry Pi 4/5
- [Hifiberry ADC Pro](https://www.hifiberry.com/shop/boards/hifiberry-dac-adc-pro/)
- Audio cable (mini-jack) to connect to the ADC port
- Optional: [3D printed case](https://www.thingiverse.com/thing:4753525)

---

## Initial Setup

1. **Install DietPi** — https://dietpi.com/
2. **Login as root**
3. **Configure hostname and audio card:**
   ```
   dietpi-config
   ```
4. **Clone this repo:**
   ```
   cd ~
   git clone git@github.com:juliusvaart/auto-stream.git
   ```

---

## Install Script

```
./install.sh
```

Follow the on-screen steps.

**To change the Airplay output device later:**
```
./install.sh --select-output
```

---

## Manual Install

### 1. Setup `.asoundrc` and alsamixer

Copy the contents of `~/auto-stream/asound.conf` to `~/.asoundrc`, then open alsamixer:

```
alsamixer
```

Set **PGA Gain Left** and **PGA Gain Right** to 12dB (value: 24).

### 2. Install Owntone and dependencies

```
wget -q -O - https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone.gpg \
  | sudo gpg --dearmor --output /usr/share/keyrings/owntone-archive-keyring.gpg
wget -q -O /etc/apt/sources.list.d/owntone.list \
  https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone-trixie.list
apt update
apt install git owntone alsa-utils sox bc curl jq
```

Access the Owntone web UI at: `http://HOSTNAME.local:3689`

### 3. Setup the FIFO pipe

```
mkdir -p /root/music/pipes/
mkfifo /root/music/pipes/platenspeler.fifo
```

> The FIFO filename is used as the "now playing" metadata title.

### 4. Configure Owntone music directory

Edit `/etc/owntone.conf` and update the `directories` setting under the `library {}` block:

```
directories = { "/root/music" }
```

### 5. Setup `.env`

```
cp ~/auto-stream/.env.example ~/auto-stream/.env
```

Edit `.env` and configure to your setup.

### 6. Test the script

```
~/auto-stream/owntone-auto-stream.sh
```

### 7. Setup systemd service

```
cp ~/auto-stream/auto-stream.service /etc/systemd/system/auto-stream.service
systemctl daemon-reload
systemctl enable auto-stream
systemctl start auto-stream
```

---

## Bonus: Album Artwork

Add square artwork (JPG) with the same base name as the FIFO file, placed in the same directory:

```
/root/music/pipes/platenspeler.fifo
/root/music/pipes/platenspeler.png
```

To enable SFTP for uploading artwork, switch the SSH server to OpenSSH:

```
dietpi-software
```
