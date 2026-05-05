import os from 'os';
import http from 'http';
import path from 'path';
import fs from 'fs';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import RoonApi from 'node-roon-api';
import RoonApiSettings from 'node-roon-api-settings';
import RoonApiStatus from 'node-roon-api-status';
import RoonApiAudioInput from 'node-roon-api-audioinput';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const HTTP_PORT = parseInt(process.env.HTTP_PORT || '4567', 10);
const STREAM_DEV = process.env.STREAM_DEV;
const EXT_ID = process.env.ROON_EXTENSION_ID || 'com.platenspeler.autostream';
const EXT_NAME = process.env.ROON_DISPLAY_NAME || 'Platenspeler Auto-Stream';
const ARTWORK_PATH = path.join(__dirname, 'platenspeler.png');

const state = {
    core: null,
    session: null,
    arecord: null,
    ffmpeg: null,
    zoneId: null,
    clients: new Set(),
};

function log(msg) {
    const ts = new Date().toISOString().replace('T', ' ').replace(/\.\d+Z$/, '');
    process.stdout.write(`${ts} [roon] ${msg}\n`);
}

function getLocalIp() {
    for (const ifaces of Object.values(os.networkInterfaces())) {
        for (const iface of ifaces) {
            if (iface.family === 'IPv4' && !iface.internal) return iface.address;
        }
    }
    return '127.0.0.1';
}

const localIp = getLocalIp();

const server = http.createServer((req, res) => {
    if (req.url === '/stream') {
        res.writeHead(200, {
            'Content-Type': 'audio/mpeg',
            'Cache-Control': 'no-cache',
            'Transfer-Encoding': 'chunked',
        });
        state.clients.add(res);
        log(`Roon connected to stream (${state.clients.size} client(s))`);
        req.on('close', () => {
            state.clients.delete(res);
            log(`Roon disconnected (${state.clients.size} client(s) remaining)`);
        });
    } else if (req.url === '/artwork.png' && fs.existsSync(ARTWORK_PATH)) {
        res.writeHead(200, { 'Content-Type': 'image/png' });
        fs.createReadStream(ARTWORK_PATH).pipe(res);
    } else {
        res.writeHead(404).end();
    }
});

server.listen(HTTP_PORT, () => log(`Stream server on http://${localIp}:${HTTP_PORT}`));

function startAudio() {
    if (state.arecord) return;

    log(`Starting audio pipeline (${STREAM_DEV})`);

    state.arecord = spawn('arecord', [
        '-D', STREAM_DEV, '-f', 'S16_LE', '-c', '2', '-r', '44100', '-t', 'raw',
        '--buffer-size=524288', '--period-size=131072',
    ]);

    state.ffmpeg = spawn('ffmpeg', [
        '-f', 's16le', '-ar', '44100', '-ac', '2', '-i', 'pipe:0',
        '-f', 'mp3', '-b:a', '320k', '-',
    ]);

    state.arecord.stdout.pipe(state.ffmpeg.stdin);
    state.arecord.stderr.on('data', () => {});
    state.ffmpeg.stderr.on('data', () => {});

    state.ffmpeg.stdout.on('data', (chunk) => {
        for (const client of state.clients) {
            if (!client.writableEnded) client.write(chunk);
            else state.clients.delete(client);
        }
    });

    state.arecord.on('exit', (code) => { log(`arecord exited (${code})`); state.arecord = null; });
    state.ffmpeg.on('exit', (code) => { log(`ffmpeg exited (${code})`); state.ffmpeg = null; });
}

function stopAudio() {
    state.arecord?.kill('SIGTERM');
    state.ffmpeg?.kill('SIGTERM');
    state.arecord = null;
    state.ffmpeg = null;
    for (const client of state.clients) client.end();
    state.clients.clear();
}

function startSession() {
    if (!state.core) { log('Cannot start: no Roon core paired'); return; }
    if (!state.zoneId) { log('Cannot start: no zone configured — open Roon → Settings → Extensions'); return; }
    if (state.session) { log('Session already active'); return; }

    startAudio();

    const streamUrl = `http://${localIp}:${HTTP_PORT}/stream`;
    const artworkUrl = `http://${localIp}:${HTTP_PORT}/artwork.png`;

    log(`Beginning session → zone ${state.zoneId}`);

    state.session = state.core.services.RoonApiAudioInput.begin_session(
        { zone_id: state.zoneId, display_name: EXT_NAME, icon_url: artworkUrl },
        (msg, body) => {
            if (msg === 'SessionBegan') {
                state.core.services.RoonApiAudioInput.update_transport_controls({
                    session_id: body.session_id,
                    controls: { is_previous_allowed: false, is_next_allowed: false },
                }, () => {});

                state.core.services.RoonApiAudioInput.play({
                    session_id: body.session_id,
                    type: 'channel',
                    slot: 'play',
                    media_url: streamUrl,
                    info: {
                        is_seek_allowed: false,
                        is_pause_allowed: false,
                        one_line:   { line1: EXT_NAME },
                        two_line:   { line1: EXT_NAME, line2: 'Live' },
                        three_line: { line1: EXT_NAME, line2: 'Live', line3: '' },
                    },
                }, (m) => {
                    log(`Playback event: ${m}`);
                    if (['StoppedUser', 'EndedNaturally', 'MediaError', 'ZoneNotFound', 'ZoneLost'].includes(m)) {
                        state.session = null;
                        stopAudio();
                    }
                });

                log('Session active, playback started');
            } else if (['ZoneNotFound', 'ZoneLost', 'SessionEnded'].includes(msg)) {
                log(`Session ended: ${msg}`);
                state.session = null;
                stopAudio();
            }
        }
    );
}

function stopSession() {
    if (state.session) {
        log('Ending session');
        state.session.end_session(() => {});
        state.session = null;
    }
    stopAudio();
}

process.on('SIGUSR1', () => { log('SIGUSR1 → start'); startSession(); });
process.on('SIGUSR2', () => { log('SIGUSR2 → stop'); stopSession(); });
process.on('SIGTERM', () => { log('SIGTERM → cleanup'); stopSession(); server.close(); process.exit(0); });
process.on('SIGINT', () => { log('SIGINT → cleanup'); stopSession(); server.close(); process.exit(0); });

let svcSettings, svcStatus;

const roon = new RoonApi({
    extension_id:    EXT_ID,
    display_name:    EXT_NAME,
    display_version: '1.0.0',
    publisher:       'Platenspeler',
    email:           'contact@avecsans.studio',
    log_level:       'none',

    core_paired: (core) => {
        state.core = core;
        log(`Paired with: ${core.display_name}`);
        svcStatus.set_status('Connected — ready to stream', false);
    },

    core_unpaired: (core) => {
        log(`Unpaired from: ${core.display_name}`);
        state.core = null;
        state.session = null;
        stopAudio();
    },
});

const settingsSchema = (vals) => ({
    values: vals,
    layout: [{
        type: 'zone',
        title: 'Zone',
        subtitle: 'Roon zone to stream to when a record is detected',
        setting: 'zone',
    }],
    has_error: !vals.zone,
});

svcSettings = new RoonApiSettings(roon, {
    get_settings: (cb) => cb(settingsSchema(roon.load_config('settings') || {})),
    save_settings: (req, isDryRun, settings) => {
        const layout = settingsSchema(settings.values);
        req.send_complete(layout.has_error ? 'NotValid' : 'Success', { settings: layout });
        if (!isDryRun && !layout.has_error) {
            roon.save_config('settings', settings.values);
            state.zoneId = settings.values.zone?.zone_id;
            log(`Zone set: ${state.zoneId}`);
        }
    },
});

const saved = roon.load_config('settings') || {};
if (saved.zone?.zone_id) {
    state.zoneId = saved.zone.zone_id;
    log(`Restored zone: ${state.zoneId}`);
}

svcStatus = new RoonApiStatus(roon);

roon.init_services({
    provided_services: [svcSettings, svcStatus],
    required_services: [RoonApiAudioInput],
});

log(`Starting Roon discovery (${EXT_ID})`);
roon.start_discovery();
