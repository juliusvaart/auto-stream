import os from 'os';
import http from 'http';
import path from 'path';
import fs from 'fs';
import { spawn, spawnSync } from 'child_process';
import { fileURLToPath } from 'url';

for (const bin of ['arecord', 'ffmpeg']) {
    if (spawnSync('which', [bin]).status !== 0) {
        process.stderr.write(`Missing required binary: ${bin}\n`);
        process.exit(1);
    }
}

import RoonApi from 'node-roon-api';
import RoonApiSettings from 'node-roon-api-settings';
import RoonApiStatus from 'node-roon-api-status';
import RoonApiAudioInput from 'node-roon-api-audioinput';
import RoonApiTransport from 'node-roon-api-transport';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const HTTP_PORT = parseInt(process.env.HTTP_PORT || '4567', 10);
const STREAM_DEV = process.env.STREAM_DEV;
const EXT_ID = process.env.ROON_EXTENSION_ID || 'com.recordplayer.autostream';
const EXT_NAME = process.env.ROON_DISPLAY_NAME || 'Record player';
const EXT_LINE2 = process.env.ROON_DISPLAY_LINE2 || 'Streaming live';
//const ARTWORK_PATH = path.join(__dirname, 'platenspeler.png');

const state = {
    core: null,
    session: null,
    arecord: null,          // single long-running capture process
    ffmpegProcs: new Set(), // one ffmpeg per active HTTP connection
    zoneId: null,   // raw value from settings (may be zone_id or output_id)
    zones: [],      // live zone list from subscribe_zones
    pendingStart: false,
    shouldStream: false,  // true between SIGUSR1 and SIGUSR2
    retryTimer: null,
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

// Resolve a stored zone/output ID to an actual zone_id using the live zone list.
function resolveZoneId(id) {
    if (!id) return null;
    const byZone = state.zones.find(z => z.zone_id === id);
    if (byZone) return byZone.zone_id;
    const byOutput = state.zones.find(z => z.outputs?.some(o => o.output_id === id));
    if (byOutput) return byOutput.zone_id;
    return null;
}

// Each HTTP connection gets its own fresh ffmpeg so Roon always receives a
// complete FLAC header — required because Roon probes the URL before playback.
const server = http.createServer((req, res) => {
    if (req.url === '/stream') {
        if (!state.arecord) {
            res.writeHead(503).end();
            return;
        }
        res.writeHead(200, {
            'Content-Type': 'audio/flac',
            'Cache-Control': 'no-cache',
            'Transfer-Encoding': 'chunked',
        });

        const ff = spawn('ffmpeg', [
            '-f', 's16le', '-ar', '44100', '-ac', '2', '-i', 'pipe:0',
            '-f', 'flac', '-compression_level', '0', '-',
        ]);
        state.ffmpegProcs.add(ff);
        ff.stderr.on('data', () => {});
        ff.stdout.on('data', (chunk) => { if (!res.writableEnded) res.write(chunk); });
        ff.on('exit', (code) => { log(`ffmpeg exited (${code})`); state.ffmpegProcs.delete(ff); });

        // Wire arecord → this ffmpeg
        state.arecord.stdout.on('data', onAudioData);
        function onAudioData(chunk) { if (!ff.stdin.destroyed) ff.stdin.write(chunk); }

        log(`Roon connected (${state.ffmpegProcs.size} active)`);
        req.on('close', () => {
            state.arecord?.stdout.removeListener('data', onAudioData);
            ff.stdin.end();
            ff.kill('SIGTERM');
            log(`Roon disconnected (${state.ffmpegProcs.size - 1} active)`);
        });
    // } else if (req.url === '/artwork.png' && fs.existsSync(ARTWORK_PATH)) {
    //     const stat = fs.statSync(ARTWORK_PATH);
    //     log(`Artwork requested (${stat.size} bytes)`);
    //     res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': stat.size });
    //     fs.createReadStream(ARTWORK_PATH).pipe(res);
    } else {
        res.writeHead(404).end();
    }
});

server.listen(HTTP_PORT, () => log(`Stream server on http://${localIp}:${HTTP_PORT}`));

function startAudio() {
    if (state.arecord) return;

    log(`Starting audio capture (${STREAM_DEV})`);

    state.arecord = spawn('arecord', [
        '-D', STREAM_DEV, '-f', 'S16_LE', '-c', '2', '-r', '44100', '-t', 'raw',
        '--buffer-size=524288', '--period-size=131072',
    ]);
    state.arecord.stderr.on('data', () => {});
    state.arecord.on('exit', (code) => { log(`arecord exited (${code})`); state.arecord = null; });
}

function stopAudio() {
    state.arecord?.kill('SIGTERM');
    state.arecord = null;
    for (const ff of state.ffmpegProcs) ff.kill('SIGTERM');
    state.ffmpegProcs.clear();
}

function startSession() {
    if (!state.core || !state.zoneId) {
        log(`Start requested but not ready (core=${!!state.core}, zone=${!!state.zoneId}) — will start once paired`);
        state.pendingStart = true;
        return;
    }
    if (state.session) { log('Session already active'); return; }

    const resolvedZoneId = resolveZoneId(state.zoneId);
    if (!resolvedZoneId) {
        log(`Cannot resolve zone ID "${state.zoneId}" — zone list: ${state.zones.map(z => z.zone_id).join(', ') || '(empty)'}`);
        state.pendingStart = true;
        return;
    }

    startAudio();

    const streamUrl = `http://${localIp}:${HTTP_PORT}/stream`;
    const artworkUrl = `http://${localIp}:${HTTP_PORT}/artwork.png`;

    log(`Beginning session → zone ${resolvedZoneId}`);

    state.session = state.core.services.RoonApiAudioInput.begin_session(
        { zone_id: resolvedZoneId, display_name: EXT_NAME, icon_url: artworkUrl },
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
                }, (msg) => {
                    const event = msg?.name ?? msg;
                    log(`Playback event: ${event}`);
                    if (['StoppedUser', 'EndedNaturally', 'MediaError', 'ZoneNotFound', 'ZoneLost'].includes(event)) {
                        state.session = null;
                        stopAudio();
                        if (event === 'StoppedUser') {
                            log('Stopped by user — waiting for next silence/audio cycle');
                            state.shouldStream = false;
                        } else if (state.shouldStream) {
                            log(`Session ended (${event}) — retrying in 5s`);
                            state.retryTimer = setTimeout(startSession, 5000);
                        }
                    }
                });

                log('Session active, playback started');
            } else if (['ZoneNotFound', 'ZoneLost', 'SessionEnded'].includes(msg)) {
                log(`Session ended: ${msg}`);
                state.session = null;
                stopAudio();
                if (state.shouldStream) {
                    log(`Retrying in 5s`);
                    state.retryTimer = setTimeout(startSession, 5000);
                }
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

process.on('SIGUSR1', () => { log('SIGUSR1 → start'); state.shouldStream = true; startSession(); });
process.on('SIGUSR2', () => { log('SIGUSR2 → stop'); state.shouldStream = false; state.pendingStart = false; clearTimeout(state.retryTimer); stopSession(); });
process.on('SIGTERM', () => { log('SIGTERM → cleanup'); stopSession(); server.close(); process.exit(0); });
process.on('SIGINT', () => { log('SIGINT → cleanup'); stopSession(); server.close(); process.exit(0); });
process.on('uncaughtException', (err) => { log(`CRASH uncaughtException: ${err.stack}`); stopSession(); process.exit(1); });
process.on('unhandledRejection', (reason) => { log(`CRASH unhandledRejection: ${reason}`); stopSession(); process.exit(1); });

let svcSettings, svcStatus;

const roon = new RoonApi({
    extension_id:    EXT_ID,
    display_name:    EXT_NAME,
    display_version: '1.0.0',
    publisher:       'Platenspeler',
    email:           'julius@vanderva.art',
    log_level:       'none',

    core_paired: (core) => {
        state.core = core;
        log(`Paired with: ${core.display_name}`);
        svcStatus.set_status('Connected — ready to stream', false);

        core.services.RoonApiTransport.subscribe_zones((response, msg) => {
            if (response === 'Subscribed') {
                state.zones = msg.zones || [];
                log(`Zones: ${state.zones.map(z => `${z.display_name} (${z.zone_id})`).join(', ')}`);
            } else if (response === 'Changed') {
                if (msg.zones_added)   state.zones.push(...msg.zones_added);
                if (msg.zones_removed) {
                    const removed = new Set(msg.zones_removed.map(z => z.zone_id));
                    state.zones = state.zones.filter(z => !removed.has(z.zone_id));
                }
                if (msg.zones_changed) {
                    for (const z of msg.zones_changed) {
                        const i = state.zones.findIndex(x => x.zone_id === z.zone_id);
                        if (i >= 0) state.zones[i] = z;
                    }
                }
            }
            if (state.pendingStart) {
                state.pendingStart = false;
                log('Resuming pending start after zone sync');
                startSession();
            }
        });
    },

    core_unpaired: (core) => {
        log(`Unpaired from: ${core.display_name}`);
        state.core = null;
        state.zones = [];
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
            const z = settings.values.zone;
            log(`Zone object: ${JSON.stringify(z)}`);
            state.zoneId = z?.zone_id ?? z?.output_id ?? z;
            log(`Zone set: ${state.zoneId}`);
        }
    },
});

const saved = roon.load_config('settings') || {};
if (saved.zone) {
    const z = saved.zone;
    state.zoneId = z?.zone_id ?? z?.output_id ?? z;
    log(`Restored zone: ${state.zoneId}`);
}

svcStatus = new RoonApiStatus(roon);

roon.init_services({
    provided_services: [svcSettings, svcStatus],
    required_services: [RoonApiAudioInput, RoonApiTransport],
});

log(`Starting Roon discovery (${EXT_ID})`);
roon.start_discovery();
