# Auto stream from Raspberry Pi ADC to Airplay / Bluetooth

## Buy

- Raspberry Pi 4/5
- Hifiberry ADC pro
- Audio cable to mini-jack to attach to ADC port

## Install DietPi

https://dietpi.com/

## Login as root

## Setup dietpi

- setup hostname
- setup audio card

```dietpi-config```

## Clone this repo

```
cd ~
git clone git@github.com:juliusvaart/auto-stream.git
```

## Setup .asoundrc and alsamixer

Copy contents from ```~/auto-stream/asound.conf``` to ```~/.asoundrc```

```alsamixer```

Setup PGA Gain Left & Right to 12db (24)

## Install Owntone and other needed packages

```
wget -q -O - https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone.gpg | sudo gpg --dearmor --output /usr/share/keyrings/owntone-archive-keyring.gpg
wget -q -O /etc/apt/sources.list.d/owntone.list https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone-trixie.list
apt update
apt install owntone alsa-utils sox bc curl jq
```

Access Owntone: http://HOSTNAME.local:3689

## Setup fifo

```
mkdir -p /root/music/pipes/
mkfifo /root/music/pipes/platenspeler.fifo
```

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
