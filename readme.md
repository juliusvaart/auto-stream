# Auto stream from Raspberry Pi ADC to Airplay

Use [Owntone Server](https://github.com/owntone/owntone-server) from a recordplayer (or anything) to Airplay device.

The script auto-detects if a record is playing and automatically starts streaming. After X amount of seconds (default 300 / 5min) the stream disconnects.

All config is in a .env. In .env.example you can see what to configure.

## Buy

- Raspberry Pi 4/5
- [Hifiberry ADC pro](https://www.hifiberry.com/shop/boards/hifiberry-dac-adc-pro/)
- Audio cable to mini-jack to attach to ADC port
- A case is nice. [Like this 3D printed one](https://www.thingiverse.com/thing:4753525)

## Install DietPi

https://dietpi.com/

## Login as root

## Setup dietpi

- setup hostname & setup audio card in DietPi Config:

```dietpi-config```

## Clone this repo

```
cd ~
git clone git@github.com:juliusvaart/auto-stream.git
```


# Install Script

```
./install.sh
```

Follow the steps.

## Change Airplay device

```
./install.sh --select-output
```


# Manual Install

## Setup .asoundrc and alsamixer

Copy contents from ```~/auto-stream/asound.conf``` to ```~/.asoundrc```

```alsamixer```

Setup PGA Gain Left & Right to 12db (24)

## Install Owntone and other needed packages

```
wget -q -O - https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone.gpg | sudo gpg --dearmor --output /usr/share/keyrings/owntone-archive-keyring.gpg
wget -q -O /etc/apt/sources.list.d/owntone.list https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone-trixie.list
apt update
apt install git owntone alsa-utils sox bc curl jq
```

Access Owntone: http://HOSTNAME.local:3689

## Setup fifo

```
mkdir -p /root/music/pipes/
mkfifo /root/music/pipes/platenspeler.fifo
```

The fifo filename is used as now playing metadata.

## Setup Owntone music directory

Edit ```/etc/owntone.conf``` and under ```library {``` change ```directories = {``` to:

```directories = { "/root/music" }```

## Setup .env

Copy .env.example to .env and configure

## Test

```~/auto-stream/owntone-auto-stream.sh```

## Setup service

Add contents from auto-stream.service to ```/etc/systemd/system/auto-stream.service```

```
systemctl daemon-reload
systemctl enable auto-stream
systemctl start auto-stream
```

## BONUS!

Add square artwork (jpg) using the same name as the fifo and place in the same directory. Example:
/root/music/pipes/platenspeler.fifo
/root/music/pipes/platenspeler.png

Change SSH-server to OpenSSH to use SFTP run ```dietpi-software```
