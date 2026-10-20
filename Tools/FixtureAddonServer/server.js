#!/usr/bin/env node
// Controlled Stremio-protocol addon used by the UI tests. Zero dependencies (Node >= 18).
//
//   node server.js --port 7777 --video /path/to/sample.mp4 [--host 0.0.0.0]
//
// URLs inside the JSON (posters, streams, subtitles) are built from the Host header of each request, so an addon
// installed through http://127.0.0.1:7777 and one installed through the machine's LAN address both stay consistent.

// Endpoints (all JSON unless noted):
//   /manifest.json                       valid manifest (catalogs movie+series with search, meta, stream, subtitles)
//   /extra/manifest.json                 a second addon with types 'tv' and 'sports' (one catalog each, with genre options; search on the
//                                        TV catalog only), served under /extra/catalog/{type}/{id}[/{extra}].json
//   /bad/manifest.json                   JSON that is not a manifest (missing required fields)
//   /html/manifest.json                  an HTML page instead of JSON
//   /catalog/{type}/{id}[/{extra}].json  catalogs (search=…, skip=…)
//   /meta/{type}/{id}.json               movie and series metas (the series has two episodes)
//   /stream/{type}/{id}.json             playable MP4 sources, an MKV-only title, a torrent-only title
//   /subtitles/{type}/{id}.json          Italian SRT and English VTT
//   /media/sample.mp4                    the sample video, with HTTP Range support
//   /media/<file>                        any file of --media-dir (the CI "media matrix": MKV, HDR10, HLG, hev1, …), with Range support;
//                                        each one that exists is also listed as a title in the "Fixture Matrix" catalog
//   /subs/it.srt, /subs/en.vtt           subtitle files
//   /subs/missing.srt, /subs/garbage.srt a subtitle that answers 404 and one that is not a subtitle (the error paths); offered by "Broken Captions"
//   /nosubs/…, /opensubs/…               this same server as an addon without a `subtitles` resource, and as one posing as the official OpenSubtitles v3 id
//   /poster/{n}.png, /backdrop/{n}.png, /logo/{n}.png   generated portrait posters, 16:9 backdrops, wide RGBA logos
//   /tmdb/3/…, /tvdb/v4/…               stand-ins for the TMDB and TheTVDB APIs (metadata.js); tt9300001 is a bare movie searched as "Sparse"
//   tt9400001 / tt9400002 / tt9400003    "Torbox Cached Film", "Torbox Download Film", "Torbox Cached Series" (searched for as "Torbox"): a single torrent
//                                        source each, with the hashes the TorBox fixture (Tools/FixtureTorBoxServer) reports as cached / not cached
//   /__control/offline?on=1|0            make every addon endpoint answer 503 (tests the "addon offline" path)
//   /__control/media?on=0|1              make /media/* answer 503 (tests offline playback of a downloaded file)
//   /__control/requests                  JSON array of the paths requested so far (for assertions)
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const metadataFixture = require('./metadata');

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}
const PORT = parseInt(arg('port', '7777'), 10);
const VIDEO = arg('video', path.join(__dirname, 'sample.mp4'));
const HOST = arg('host', '127.0.0.1');
const MEDIA_DIR = arg('media-dir', '');
let BASE = `http://127.0.0.1:${PORT}`;   // rebound per request from the Host header

let offline = false;
let mediaOffline = false;
const requests = [];

const movies = [
  { id: 'tt9000001', name: 'Aether Fixture One', year: 2021, genres: ['Fixture', 'Drama'], runtime: '1 min', rating: '7.9' },
  { id: 'tt9000002', name: 'Aether Fixture Two', year: 2022, genres: ['Fixture', 'Comedy'], runtime: '1 min', rating: '6.4' },
  { id: 'tt9000003', name: 'Unsupported Format', year: 2020, genres: ['Fixture'], runtime: '90 min', rating: '5.0' },
  { id: 'tt9000004', name: 'Nothing To Watch', year: 2019, genres: ['Fixture'], runtime: '90 min', rating: '4.1' },
  // Subtitle scenarios, listed only when searched for: a title the addon has no subtitles for, and one whose subtitle files are unusable.
  { id: 'tt9000005', name: 'Silent Feature', year: 2018, genres: ['Fixture'], runtime: '1 min', rating: '5.5', hidden: true },
  { id: 'tt9000006', name: 'Broken Captions', year: 2017, genres: ['Fixture'], runtime: '1 min', rating: '5.1', hidden: true },
  // A bare meta (name only), listed only when searched for: what the TMDB / TheTVDB stand-ins (metadata.js) can fill in.
  { id: 'tt9300001', name: 'Sparse Fixture Movie', year: 2020, genres: [], runtime: '', rating: '', hidden: true, sparse: true },
  // TorBox scenarios (the stand-in for the service is Tools/FixtureTorBoxServer): each title has one torrent source, listed only when
  // searched for. Their names avoid the words other searches use.
  { id: 'tt9400001', name: 'Torbox Cached Film', year: 2024, genres: ['Torbox'], runtime: '1 min', rating: '6.0', hidden: true },
  { id: 'tt9400002', name: 'Torbox Download Film', year: 2024, genres: ['Torbox'], runtime: '1 min', rating: '6.0', hidden: true },
];
const series = [
  { id: 'tt9100001', name: 'Fixture Series', year: 2023, genres: ['Fixture', 'Sci-Fi'], rating: '8.2' },
  { id: 'tt9400003', name: 'Torbox Cached Series', year: 2024, genres: ['Torbox'], rating: '6.0', hidden: true },
];
const episodes = [
  { id: 'tt9100001:1:1', title: 'Pilot', season: 1, episode: 1 },
  { id: 'tt9100001:1:2', title: 'Second Light', season: 1, episode: 2 },
];

function metaPreview(item, type, index) {
  if (item.sparse) return { id: item.id, type, name: item.name };
  return {
    id: item.id, type, name: item.name, poster: `${BASE}/poster/${index}.png`,
    background: `${BASE}/backdrop/${index}.png`, logo: `${BASE}/logo/${index}.png`,
    releaseInfo: String(item.year), imdbRating: item.rating, genres: item.genres,
  };
}

function metaFull(item, type, index) {
  if (item.sparse) return metaPreview(item, type, index);
  const meta = {
    ...metaPreview(item, type, index),
    description: `${item.name} is a controlled fixture title used by Aether's automated tests.`,
    runtime: item.runtime, cast: ['Test Actor One', 'Test Actor Two'], director: ['Test Director'],
  };
  if (type === 'series') {
    // The episode ids carry the id of the series (tt9100001:1:2), whichever series it is.
    meta.videos = episodes.map((e) => ({ ...e, id: e.id.replace('tt9100001', item.id) })).map((e) => ({
      id: e.id, title: e.title, season: e.season, episode: e.episode,
      released: '2023-01-0' + e.episode + 'T00:00:00.000Z', thumbnail: `${BASE}/poster/${index}.png`,
    }));
  }
  return meta;
}

// Titles backed by real files in --media-dir; only the files that were generated are offered.
const MATRIX_ALL = [
  { id: 'tt9200001', file: 'h264.mkv', name: 'Matrix H264 MKV', year: 2024 },
  { id: 'tt9200002', file: 'hdr10.mp4', name: 'Matrix HDR10 MP4', year: 2024 },
  { id: 'tt9200003', file: 'hdr10.mkv', name: 'Matrix HDR10 MKV', year: 2024 },
  { id: 'tt9200004', file: 'hlg.mp4', name: 'Matrix HLG MP4', year: 2024 },
  { id: 'tt9200005', file: 'hdr10-hev1.mp4', name: 'Matrix HDR10 HEV1', year: 2024 },
  { id: 'tt9200006', file: 'sdr-hevc.mp4', name: 'Matrix SDR HEVC MP4', year: 2024 },
  { id: 'tt9200007', file: 'h264.avi', name: 'Matrix H264 AVI', year: 2024 },
];
const matrix = MATRIX_ALL
  .filter((m) => MEDIA_DIR && fs.existsSync(path.join(MEDIA_DIR, m.file)))
  .map((m) => ({ ...m, genres: ['Fixture', 'Matrix'], runtime: '8 sec', rating: '7.0' }));

const MIME = { '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mov': 'video/quicktime', '.mkv': 'video/x-matroska',
  '.webm': 'video/webm', '.avi': 'video/x-msvideo', '.ts': 'video/mp2t' };

const manifest = {
  id: 'org.aether.fixture', version: '1.0.0', name: 'Aether Fixture',
  description: 'Controlled addon for automated tests',
  resources: ['catalog', 'meta', 'stream', 'subtitles'],
  types: ['movie', 'series'], idPrefixes: ['tt'],
  catalogs: [
    { type: 'movie', id: 'fixture-movies', name: 'Fixture Movies', extra: [{ name: 'search' }, { name: 'skip' }] },
    { type: 'series', id: 'fixture-series', name: 'Fixture Series', extra: [{ name: 'search' }, { name: 'skip' }] },
    ...(matrix.length ? [{ type: 'movie', id: 'fixture-matrix', name: 'Fixture Matrix', extra: [{ name: 'search' }, { name: 'skip' }] }] : []),
  ],
  behaviorHints: { configurable: false },
};

// Variants of this server under /<name>/…: the same addon without a `subtitles` resource, and one posing as the official
// OpenSubtitles v3 id (tests of the "recommended addon" entry and of the "no subtitles addon installed" state).
const variantManifests = {
  nosubs: { ...manifest, resources: ['catalog', 'meta', 'stream'] },
  opensubs: {
    id: 'org.stremio.opensubtitlesv3', version: '1.0.0', name: 'OpenSubtitles v3 (fixture)',
    description: 'Stands in for the official OpenSubtitles v3 addon in automated tests',
    resources: ['subtitles'], types: ['movie', 'series'], idPrefixes: ['tt'], catalogs: [],
  },
};

// A second, tiny addon (live TV and sports) that proves content types appear and disappear with the installed addons.
// `extra-tv` declares optional `genre` and `search`, so a search can carry the genre too (and the server honours it);
// `extra-sports` is browse-only (no search). One channel has neither a year nor a genre, to exercise the
// "hidden because the data is missing" counts of the local filters.
const extraManifest = {
  id: 'org.aether.fixture.extra', version: '1.0.0', name: 'Aether Fixture Extra',
  description: 'Second controlled addon: live TV and sports catalogs',
  resources: ['catalog'],
  types: ['tv', 'sports'],
  catalogs: [
    { type: 'tv', id: 'extra-tv', name: 'Fixture Canali',
      extra: [{ name: 'genre', options: ['News', 'Kids'] }, { name: 'search' }, { name: 'skip' }] },
    { type: 'sports', id: 'extra-sports', name: 'Fixture Sport',
      extra: [{ name: 'genre', options: ['Calcio', 'Tennis'] }, { name: 'skip' }] },
  ],
  behaviorHints: { configurable: false },
};
const extraItems = {
  'extra-tv': [
    { id: 'fxtv-news', name: 'Fixture News Live', year: 2020, genres: ['News'] },
    { id: 'fxtv-kids', name: 'Fixture Kids Channel', year: 2018, genres: ['Kids'] },
    { id: 'fxtv-night', name: 'Fixture Night Channel', year: null, genres: [] },
  ],
  'extra-sports': [
    { id: 'fxsp-derby', name: 'Fixture Derby Highlights', year: 2024, genres: ['Calcio'] },
    { id: 'fxsp-final', name: 'Fixture Open Final', year: 2024, genres: ['Tennis'] },
  ],
};

function extraPreview(item, type, index) {
  const meta = { id: item.id, type, name: item.name, poster: `${BASE}/poster/${index}.png`, genres: item.genres };
  if (item.year) meta.releaseInfo = String(item.year);
  return meta;
}

function streamsFor(id) {
  const m = matrix.find((entry) => entry.id === id);
  if (m) {
    return [{ name: 'Matrix source', title: `${m.name} ${m.file}`, url: `${BASE}/media/${m.file}`, behaviorHints: { filename: m.file } }];
  }
  const sub = [
    { id: 'it', url: `${BASE}/subs/it.srt`, lang: 'ita' },
    { id: 'en', url: `${BASE}/subs/en.vtt`, lang: 'eng' },
  ];
  if (id === 'tt9000003') {
    return [
      { name: 'Fixture DASH', title: 'Unsupported.Format.2020.2160p.HEVC.mpd', url: `${BASE}/media/unsupported.mpd` },
      { name: 'Fixture Torrent', title: 'Unsupported.Format.2020.1080p.torrent', infoHash: '0123456789abcdef0123456789abcdef01234567' },
    ];
  }
  if (id === 'tt9000004') return [];
  // TorBox scenarios: one torrent each, with the hash the TorBox fixture reports as cached (1…1: a movie; 2…2: a season pack with
  // S01E01 and S01E02) or as not cached (3…3: it downloads for a few seconds once the user confirms). No trackers: nothing is contacted.
  if (id === 'tt9400001') {
    return [{ name: 'Torbox Cached 1080p', title: 'Cached.Movie.2024.1080p.mkv', infoHash: '1'.repeat(40),
      behaviorHints: { bingeGroup: 'torbox-cached', filename: 'Cached.Movie.2024.1080p.mkv' } }];
  }
  if (id === 'tt9400002') {
    return [{ name: 'Torbox Download 720p', title: 'Slow.Download.2024.720p.mkv', infoHash: '3'.repeat(40),
      behaviorHints: { bingeGroup: 'torbox-download', filename: 'Slow.Download.2024.720p.mkv' } }];
  }
  if (id === 'tt9400003') {
    return [{ name: 'Torbox Cached Pack 1080p', title: 'Cached.Series.S01.1080p', infoHash: '2'.repeat(40),
      behaviorHints: { bingeGroup: 'torbox-series' } }];
  }
  // The subtitle-scenario titles carry no subtitles inside the stream: only the addon's `subtitles` resource decides.
  if (id === 'tt9000005' || id === 'tt9000006') {
    return [{ name: 'Fixture 720p', title: `${id} 720p MP4 H.264`, url: `${BASE}/media/sample.mp4?q=720`,
      behaviorHints: { bingeGroup: 'fixture-720p', filename: 'sample.mp4' } }];
  }
  return [
    { name: 'Fixture 1080p', title: `${id} 1080p MP4 H.264`, url: `${BASE}/media/sample.mp4?q=1080`, subtitles: sub,
      behaviorHints: { bingeGroup: 'fixture-1080p', filename: 'sample.mp4' } },
    { name: 'Fixture 720p', title: `${id} 720p MP4 H.264`, url: `${BASE}/media/sample.mp4?q=720`,
      behaviorHints: { bingeGroup: 'fixture-720p', filename: 'sample.mp4' } },
  ];
}

function send(res, status, body, type = 'application/json') {
  const data = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': type, 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache',
    'Content-Length': Buffer.byteLength(data),
  });
  res.end(data);
}

// ---- tiny PNG generator (gradient poster, 2:3) -----------------------------------------------------------
const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}
// Wide backdrops (16:9) are what real catalogs return in `background`; they overflow a narrow container when
// an image is laid out with "fill", which is exactly the layout bug the UI tests guard against.
function backdrop(n) {
  const w = 640, h = 360;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  const hue = (n * 41) % 360;
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const o = y * (w * 3 + 1) + 1 + x * 3;
      raw[o] = Math.round(30 + 100 * Math.abs(Math.sin((hue / 360 + x / w) * Math.PI)));
      raw[o + 1] = Math.round(40 + 80 * (y / h));
      raw[o + 2] = Math.round(70 + 120 * Math.abs(Math.cos((hue / 180 + y / h) * Math.PI)));
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(w, 0); header.writeUInt32BE(h, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Wide transparent title logo (RGBA), like the `logo` Cinemeta returns.
function logo() {
  const w = 480, h = 120;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const o = y * (w * 4 + 1) + 1 + x * 4;
      const inside = y > 30 && y < 90 && x > 20 && x < w - 20;
      raw[o] = 255; raw[o + 1] = 255; raw[o + 2] = 255; raw[o + 3] = inside ? 230 : 0;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(w, 0); header.writeUInt32BE(h, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

function poster(n) {
  const w = 120, h = 180;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  const hue = (n * 67) % 360;
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const t = y / h;
      const o = y * (w * 3 + 1) + 1 + x * 3;
      raw[o] = Math.round(40 + 120 * Math.abs(Math.sin((hue / 360 + t) * Math.PI)));
      raw[o + 1] = Math.round(30 + 90 * t);
      raw[o + 2] = Math.round(80 + 140 * (1 - t) * Math.abs(Math.cos((hue / 180) * Math.PI)));
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(w, 0); header.writeUInt32BE(h, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---- media with Range support --------------------------------------------------------------------------------
function serveMediaFile(req, res, file, type) {
  const size = fs.statSync(file).size;
  const range = req.headers.range;
  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    let start = m && m[1] ? parseInt(m[1], 10) : 0;
    let end = m && m[2] ? Math.min(parseInt(m[2], 10), size - 1) : size - 1;
    if (m && !m[1] && m[2]) { start = Math.max(0, size - parseInt(m[2], 10)); end = size - 1; }   // suffix range: the last N bytes
    if (start > end || start >= size) { res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end(); }
    res.writeHead(206, { 'Content-Type': type, 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1,
      'Content-Range': `bytes ${start}-${end}/${size}` });
    return fs.createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(200, { 'Content-Type': type, 'Accept-Ranges': 'bytes', 'Content-Length': size });
  return fs.createReadStream(file).pipe(res);
}

function serveMatrixFile(req, res, name) {
  if (!MEDIA_DIR || !/^[A-Za-z0-9._-]+$/.test(name)) return send(res, 404, { error: 'not here' });
  const file = path.join(MEDIA_DIR, name);
  if (!fs.existsSync(file)) return send(res, 404, { error: 'not here' });
  return serveMediaFile(req, res, file, MIME[path.extname(name).toLowerCase()] || 'application/octet-stream');
}

function serveVideo(req, res) {
  if (!fs.existsSync(VIDEO)) return send(res, 404, { error: 'sample video missing' });
  const size = fs.statSync(VIDEO).size;
  const range = req.headers.range;
  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    const start = m && m[1] ? parseInt(m[1], 10) : 0;
    const end = m && m[2] ? Math.min(parseInt(m[2], 10), size - 1) : size - 1;
    res.writeHead(206, {
      'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1,
      'Content-Range': `bytes ${start}-${end}/${size}`,
    });
    fs.createReadStream(VIDEO, { start, end }).pipe(res);
  } else {
    res.writeHead(200, { 'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes', 'Content-Length': size });
    fs.createReadStream(VIDEO).pipe(res);
  }
}

const SRT = '1\n00:00:00,500 --> 00:00:30,000\nCiao dal sottotitolo di prova\n\n2\n00:00:30,500 --> 00:02:00,000\nSecondo sottotitolo italiano\n';
const VTT = 'WEBVTT\n\n00:00.500 --> 00:30.000\nHello from the test subtitle\n\n00:30.500 --> 02:00.000\nSecond English subtitle\n';

function decodeExtra(segment) {
  const extra = {};
  for (const pair of segment.split('&')) {
    const [k, v = ''] = pair.split('=');
    if (k) extra[decodeURIComponent(k)] = decodeURIComponent(v);
  }
  return extra;
}

const server = http.createServer((req, res) => {
  BASE = `http://${req.headers.host || `127.0.0.1:${PORT}`}`;
  const url = new URL(req.url, BASE);
  const rawPath = decodeURIComponent(url.pathname);
  const variantMatch = /^\/(nosubs|opensubs)(\/.*)$/.exec(rawPath);
  const variant = variantMatch ? variantMatch[1] : null;
  const p = variantMatch ? variantMatch[2] : rawPath;
  if (!p.startsWith('/__control/')) requests.push(p);

  if (p === '/__control/offline') { offline = url.searchParams.get('on') === '1'; return send(res, 200, { offline }); }
  if (p === '/__control/media') { mediaOffline = url.searchParams.get('on') === '0'; return send(res, 200, { mediaOffline }); }
  if (p === '/__control/requests') return send(res, 200, requests);
  if (p === '/__control/reset') { requests.length = 0; offline = false; mediaOffline = false; return send(res, 200, { ok: true }); }

  if (metadataFixture.handle(req, res, p, url, BASE, { send, poster })) return;
  if (p.startsWith('/poster/')) return send(res, 200, poster(parseInt(p.split('/')[2], 10) || 0), 'image/png');
  if (p.startsWith('/backdrop/')) return send(res, 200, backdrop(parseInt(p.split('/')[2], 10) || 0), 'image/png');
  if (p.startsWith('/logo/')) return send(res, 200, logo(), 'image/png');
  if (p === '/subs/it.srt') return send(res, 200, SRT, 'application/x-subrip');
  if (p === '/subs/en.vtt') return send(res, 200, VTT, 'text/vtt');
  if (p === '/subs/missing.srt') { res.writeHead(404); return res.end('no such subtitle'); }
  if (p === '/subs/garbage.srt') return send(res, 200, 'This is not a subtitle file.\n', 'text/plain');
  if (p.startsWith('/media/') && mediaOffline) { res.writeHead(503); return res.end('media offline'); }
  if (p === '/media/sample.mp4') return serveVideo(req, res);
  if (p.startsWith('/media/')) return serveMatrixFile(req, res, p.slice('/media/'.length));

  if (offline) { res.writeHead(503); return res.end('offline'); }

  if (p === '/bad/manifest.json') return send(res, 200, { id: 'org.bad', version: 'not-semver-but-ok' });
  if (p === '/html/manifest.json') return send(res, 200, '<html><body>Not an addon</body></html>', 'text/html');
  if (p === '/manifest.json') return send(res, 200, variant ? variantManifests[variant] : manifest);
  if (p === '/extra/manifest.json') return send(res, 200, extraManifest);
  if (p.startsWith('/extra/catalog/')) {
    const [, , type, id, extraSegment] = p.replace(/\.json$/, '').split('/').filter(Boolean);
    const list = extraItems[id];
    if (!list) return send(res, 200, { metas: [] });
    const extra = extraSegment ? decodeExtra(extraSegment) : {};
    if (extra.skip && parseInt(extra.skip, 10) > 0) return send(res, 200, { metas: [] });
    let items = list;
    if (extra.search) {
      const q = extra.search.toLowerCase();
      items = items.filter((item) => item.name.toLowerCase().includes(q));
    }
    if (extra.genre) items = items.filter((item) => item.genres.includes(extra.genre));
    const offset = id === 'extra-sports' ? 30 : 20;
    return send(res, 200, { metas: items.map((item, i) => extraPreview(item, type, offset + i + 1)) });
  }
  if (p.startsWith('/extra/')) return send(res, 404, { error: 'unknown route', path: p });

  const parts = p.replace(/\.json$/, '').split('/').filter(Boolean);
  const [resource, type, id, extraSegment] = parts;

  if (resource === 'catalog') {
    const list = id === 'fixture-matrix' ? matrix : (type === 'movie' ? movies : series);
    const extra = extraSegment ? decodeExtra(extraSegment) : {};
    if (extra.skip && parseInt(extra.skip, 10) > 0) return send(res, 200, { metas: [] });
    const visible = list.filter((item) => !item.hidden || extra.search);
    let items = visible.map((item, i) => metaPreview(item, type, i + 1 + (type === 'series' ? 10 : 0)));
    if (extra.search) {
      const q = extra.search.toLowerCase();
      items = items.filter((m) => m.name.toLowerCase().includes(q));
    }
    return send(res, 200, { metas: items });
  }
  if (resource === 'meta') {
    const list = type === 'movie' ? movies.concat(matrix) : series;
    const index = list.findIndex((m) => m.id === id);
    if (index < 0) return send(res, 200, { meta: null });
    return send(res, 200, { meta: metaFull(list[index], type, index + 1 + (type === 'series' ? 10 : 0)) });
  }
  if (resource === 'stream') {
    const baseId = id.split(':')[0];
    return send(res, 200, { streams: streamsFor(baseId) });
  }
  if (resource === 'subtitles') {
    // Subtitle scenarios: nothing at all for one title, files that cannot be used for the other.
    if (id === 'tt9000005') return send(res, 200, { subtitles: [] });
    if (id === 'tt9000006') {
      return send(res, 200, { subtitles: [
        { id: 'missing', url: `${BASE}/subs/missing.srt`, lang: 'ita' },
        { id: 'garbage', url: `${BASE}/subs/garbage.srt`, lang: 'eng' },
      ] });
    }
    return send(res, 200, { subtitles: [
      { id: 'it-addon', url: `${BASE}/subs/it.srt`, lang: 'ita' },
      { id: 'en-addon', url: `${BASE}/subs/en.vtt`, lang: 'eng' },
    ] });
  }
  return send(res, 404, { error: 'unknown route', path: p });
});

server.listen(PORT, HOST, () => console.log(`Aether fixture addon listening on ${HOST}:${PORT}`));
