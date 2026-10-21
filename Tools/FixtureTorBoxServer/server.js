#!/usr/bin/env node
// TEST DOUBLE of the TorBox API, used by Aether's UI tests. Zero dependencies (Node >= 18).
//
//   node server.js --port 7778 [--host 0.0.0.0] --video /path/to/sample.mp4 [--download-seconds 6]
//
// This is NOT TorBox and it has never been compared with the real service. It is built only from the public
// documentation collected in docs/research/torbox-api.md and from the answers recorded in
// docs/research/api-probe-2026-10-20.md. Everything those documents do not say (exact detail texts, the status
// codes of the less common errors, the 422 shape for a missing parameter) is an assumption of this fixture and is
// marked "assumed" below. It only exists so the app's TorBox flow can be exercised without a real account.
//
// The only accepted API key is `test-key` (not a secret). The key is never echoed in an answer, never printed and
// never stored: the request log holds paths without query strings, so `requestdl?token=…` leaves no trace.
//
// ---- API (base path /v1/api; answers use the envelope {"success","error","detail","data"}) --------------------------
//   GET  /v1/api/user/me                   Bearer. Plan 2 (Pro), subscribed, premium_expires_at in the future, a fake e-mail
//                                          (so tests can prove the app never shows it). In mode plan_restricted: plan 0, Free.
//   POST /v1/api/torrents/checkcached      Bearer. JSON body {"hashes":[…]}; query format=list|object (default object) and
//   GET  /v1/api/torrents/checkcached      list_files=true|false. GET takes hash=H1,H2&hash=H3. At most 100 hashes (the
//                                          documented GET limit; the real POST limit is unknown) else 400 TOO_MANY_OPTIONS.
//                                          Cached, exactly: 1111…1111 (movie: Cached.Movie.2024.1080p.mkv, 1.2 GiB, plus a
//                                          small .nfo) and 2222…2222 (series: S01E01 and S01E02 as separate files). Every other
//                                          hash is simply absent from the answer, as in the real service. File entries carry
//                                          name and size only (no id: the ids come from mylist).
//   POST /v1/api/torrents/createtorrent    Bearer. Form (urlencoded or multipart): magnet, allow_zip, add_only_if_cached (cached hash: added; other: HTTP 409 DOWNLOAD_NOT_CACHED, assumed). A cached hash is added
//                                          at once ("Found Cached Torrent. Using Cached Torrent."). 3333…3333 is not cached
//                                          and downloads for --download-seconds (default 6). Any other hash is accepted and
//                                          stays "stalled (no seeds)" forever (it exercises the app's give-up path). Adding a
//                                          hash that is already in the account answers 400 DIFF_ISSUE (assumed detail text).
//                                          An unreadable magnet answers 400 BOZO_TORRENT (assumed).
//   GET  /v1/api/torrents/mylist           Bearer. id=N gives ONE object, otherwise a list (newest first; offset, limit).
//                                          bypass_cache is accepted and irrelevant. Unknown id: 404 ITEM_NOT_FOUND (status assumed).
//                                          Cached items are download_present + download_finished at once (state "cached").
//                                          3333…3333 is time based: progress 0.2 -> 1.0 over --download-seconds with
//                                          download_speed and eta, state "downloading", then "completed" and ready. File ids
//                                          are NOT the positions in the array (movie 12/13, series 31/32, slow 41, other 51).
//   GET  /v1/api/torrents/requestdl        token=test-key (query, no Authorization), torrent_id, file_id (default 0);
//                                          redirect=true answers 307 with Location. Returns {"data":"http://<host>/cdn/<name>.mp4"}
//                                          where <name> is the file's name without extension. A missing token is 422 (the
//                                          OpenAPI marks it required; shape assumed). A torrent that is not ready, or a
//                                          file id that does not exist, is 404 ITEM_NOT_FOUND (assumed).
//   GET  /                                 {"success":true,…} health check, no authentication.
//   Anything else under /v1/api (controltorrent included) answers 404 ENDPOINT_NOT_FOUND, but it IS recorded, so a test
//   can prove the app never calls it. Nothing in this server can delete, pause or change an item.
//
// ---- Authentication ----------------------------------------------------------------------------------------------
//   no Authorization header           -> 401 {"detail":"Not authenticated"}                      (probe 2026-10-20)
//   any other key (or mode bad_token) -> 403 {"success":false,"error":"AUTH_ERROR","detail":"An error occurred while verifying
//                                         your token. Please try again.","data":null}, with retry-after: 60 as the probe saw
//
// ---- CDN ---------------------------------------------------------------------------------------------------------
//   GET|HEAD /cdn/<name>.mp4               serves the --video file with HTTP Range support, but only for names that
//                                          requestdl handed out since the last reset (anything else: 404).
//
// ---- Control (never recorded) ------------------------------------------------------------------------------------
//   GET /__control/mode?name=normal|bad_token|rate_limit|plan_restricted|html_error|offline
//        normal            everything above
//        bad_token         every API call answers the 403 AUTH_ERROR above (key revoked)
//        rate_limit        every API call answers HTTP 429, Retry-After: 2, error RATE_LIMIT_EXCEEDED
//        plan_restricted   checkcached / createtorrent / mylist / requestdl answer 403 PLAN_RESTRICTED_FEATURE; user/me works
//        html_error        every API call answers an HTML error page with HTTP 200 (a gateway page instead of JSON)
//        offline           every API call has its connection reset (nothing answers); /cdn keeps working
//      GET /__control/mode without name returns the current mode.
//   GET /__control/reset      forgets the account's torrents, the issued CDN names and the request log; mode back to normal
//   GET /__control/requests   JSON array of the paths requested so far, WITHOUT query strings, in order (CDN and unknown
//                             paths included, /__control/* excluded)
//
// Options: --download-seconds N shortens or lengthens the simulated download of 3333…3333 (default 6).
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}
const PORT = parseInt(arg('port', '7778'), 10);
const HOST = arg('host', '127.0.0.1');
const VIDEO = arg('video', path.join(__dirname, 'sample.mp4'));
const parsedSeconds = parseFloat(arg('download-seconds', '6'));
const DOWNLOAD_SECONDS = Number.isFinite(parsedSeconds) && parsedSeconds > 0 ? parsedSeconds : 6;

const API_KEY = 'test-key';
const MODES = ['normal', 'bad_token', 'rate_limit', 'plan_restricted', 'html_error', 'offline'];
const PREMIUM_EXPIRES_AT = new Date(Date.now() + 400 * 24 * 3600 * 1000).toISOString();

const HASH_MOVIE = '1'.repeat(40);
const HASH_SERIES = '2'.repeat(40);
const HASH_SLOW = '3'.repeat(40);
const MAX_HASHES = 100;

const MKV = 'video/x-matroska';
const GIB = 1024 * 1024 * 1024;

// What the fixture "knows". kind: ready = cached on TorBox, timed = downloads for DOWNLOAD_SECONDS, stalled = never finishes.
const CATALOG = {
  [HASH_MOVIE]: {
    kind: 'ready', name: 'Cached.Movie.2024.1080p',
    files: [
      { id: 12, name: 'Cached.Movie.2024.1080p/Cached.Movie.2024.1080p.mkv', size: Math.round(1.2 * GIB), mimetype: MKV },
      { id: 13, name: 'Cached.Movie.2024.1080p/Cached.Movie.2024.1080p.nfo', size: 2048, mimetype: 'text/plain' },
    ],
  },
  [HASH_SERIES]: {
    kind: 'ready', name: 'Cached.Series.S01.1080p',
    // E01 is the larger file on purpose: picking "the largest video" would answer the wrong episode.
    files: [
      { id: 31, name: 'Cached.Series.S01.1080p/Cached.Series.S01E01.1080p.mkv', size: 900000000, mimetype: MKV },
      { id: 32, name: 'Cached.Series.S01.1080p/Cached.Series.S01E02.1080p.mkv', size: 850000000, mimetype: MKV },
    ],
  },
  [HASH_SLOW]: {
    kind: 'timed', name: 'Slow.Download.2024.720p',
    files: [
      { id: 41, name: 'Slow.Download.2024.720p/Slow.Download.2024.720p.mkv', size: 700000000, mimetype: MKV },
    ],
  },
};

function definitionFor(hash) {
  if (CATALOG[hash]) return CATALOG[hash];
  const label = 'Unknown.Torrent.' + hash.slice(0, 8);
  return { kind: 'stalled', name: label, files: [{ id: 51, name: label + '/' + label + '.mkv', size: 500000000, mimetype: MKV }] };
}

const state = { mode: 'normal', requests: [], torrents: [], nextId: 101, issued: new Set() };

function resetState() {
  state.mode = 'normal';
  state.requests.length = 0;
  state.torrents.length = 0;
  state.nextId = 101;
  state.issued.clear();
}

// ---- helpers ------------------------------------------------------------------------------------------------------
function rateHeaders(remaining) {
  return {
    'x-ratelimit-limit': '300',
    'x-ratelimit-remaining': String(remaining),
    'x-ratelimit-reset': (Date.now() / 1000 + 60).toFixed(1),
  };
}

function sendJSON(res, status, body, headers) {
  const data = JSON.stringify(body);
  res.writeHead(status, Object.assign({
    'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(data),
  }, headers || {}));
  res.end(data);
}

function sendApi(res, status, body, headers) {
  sendJSON(res, status, body, Object.assign(rateHeaders(299), headers || {}));
}

function ok(data, detail) {
  return { success: true, error: null, detail, data };
}

function failure(code, detail) {
  return { success: false, error: code, detail, data: null };
}

const HTML_PAGE = '<!doctype html><html><head><title>502 Bad Gateway</title></head>'
  + '<body><center><h1>502 Bad Gateway</h1></center><hr><center>fixture gateway</center></body></html>';

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let exceeded = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) { exceeded = true; return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (exceeded) reject(Object.assign(new Error('body too large'), { status: 413 }));
      else resolve(Buffer.concat(chunks));
    });
    req.on('error', reject);
  });
}

function parseForm(body, contentType) {
  const type = String(contentType || '').toLowerCase();
  if (type.startsWith('multipart/form-data')) return parseMultipart(body, String(contentType));
  return Object.fromEntries(new URLSearchParams(body.toString('utf8')));
}

// Text fields only (a `file` part is ignored: the app adds magnets).
function parseMultipart(body, contentType) {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
  if (!match) return {};
  const delimiter = '--' + (match[1] || match[2]).trim();
  const fields = {};
  for (const part of body.toString('utf8').split(delimiter)) {
    const split = part.indexOf('\r\n\r\n');
    if (split < 0) continue;
    const headers = part.slice(0, split);
    const name = /name="([^"]*)"/i.exec(headers);
    if (!name || /filename=/i.test(headers)) continue;
    fields[name[1]] = part.slice(split + 4).replace(/\r\n$/, '');
  }
  return fields;
}

function base32ToHex(text) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const ch of text.toUpperCase()) {
    const index = alphabet.indexOf(ch);
    if (index < 0) return null;
    bits += index.toString(2).padStart(5, '0');
  }
  let hex = '';
  for (let i = 0; i + 8 <= bits.length; i += 8) hex += parseInt(bits.slice(i, i + 8), 2).toString(16).padStart(2, '0');
  return hex.length === 40 ? hex : null;
}

function hashFromMagnet(magnet) {
  const q = magnet.indexOf('?');
  if (!/^magnet:/i.test(magnet) || q < 0) return null;
  for (const xt of new URLSearchParams(magnet.slice(q + 1)).getAll('xt')) {
    const m = /^urn:btih:([A-Za-z0-9]+)$/i.exec(xt);
    if (!m) continue;
    if (/^[0-9a-f]{40}$/i.test(m[1])) return m[1].toLowerCase();
    if (/^[A-Z2-7]{32}$/i.test(m[1])) return base32ToHex(m[1]);
  }
  return null;
}

function origin(req) {
  const host = String(req.headers.host || '');
  return 'http://' + (/^[A-Za-z0-9.\-:\[\]]+$/.test(host) ? host : `127.0.0.1:${PORT}`);
}

function intParam(value, fallback) {
  if (value === null || value === undefined || !/^-?\d+$/.test(String(value).trim())) return fallback;
  return parseInt(String(value).trim(), 10);
}

// ---- the simulated account ----------------------------------------------------------------------------------------
function progressOf(torrent, now) {
  if (torrent.kind === 'ready') {
    return { ready: true, progress: 1, state: 'cached', speed: 0, eta: 0 };
  }
  if (torrent.kind === 'timed') {
    const elapsed = (now - torrent.createdAt) / 1000;
    if (elapsed >= DOWNLOAD_SECONDS) return { ready: true, progress: 1, state: 'completed', speed: 0, eta: 0 };
    const progress = Math.round((0.2 + 0.8 * (elapsed / DOWNLOAD_SECONDS)) * 1000) / 1000;
    return { ready: false, progress, state: 'downloading', speed: 15000000, eta: Math.max(1, Math.ceil(DOWNLOAD_SECONDS - elapsed)) };
  }
  return { ready: false, progress: 0, state: 'stalled (no seeds)', speed: 0, eta: 0 };
}

function isReady(torrent, now) {
  return progressOf(torrent, now).ready;
}

function view(torrent, now) {
  const p = progressOf(torrent, now);
  const stamp = new Date(torrent.createdAt).toISOString();
  const files = torrent.files.map((file) => ({
    id: file.id,
    name: file.name,
    short_name: file.name.split('/').pop(),
    size: file.size,
    mimetype: file.mimetype,
    md5: null,
    s3_path: 'fixture/' + torrent.id + '/' + file.id,
    zipped: false,
    infected: false,
    opensubtitles_hash: null,
  }));
  return {
    id: torrent.id,
    hash: torrent.hash,
    name: torrent.name,
    size: torrent.files.reduce((sum, file) => sum + file.size, 0),
    magnet: 'magnet:?xt=urn:btih:' + torrent.hash,
    progress: p.progress,
    download_state: p.state,
    download_speed: p.speed,
    upload_speed: 0,
    eta: p.eta,
    seeds: p.ready ? 0 : (torrent.kind === 'stalled' ? 0 : 12),
    peers: p.ready ? 0 : (torrent.kind === 'stalled' ? 0 : 3),
    ratio: 0,
    availability: torrent.kind === 'stalled' ? 0 : 1,
    active: !p.ready,
    download_finished: p.ready,
    download_present: p.ready,
    cached: torrent.kind === 'ready',
    torrent_file: false,
    created_at: stamp,
    updated_at: new Date(now).toISOString(),
    expires_at: null,
    inactive_check: 0,
    server: 1,
    auth_id: 'fixture-auth',
    files,
  };
}

// ---- endpoint handlers --------------------------------------------------------------------------------------------
function handleUserMe(req, res, url) {
  const free = state.mode === 'plan_restricted';
  const user = {
    id: 4242,
    created_at: '2024-01-01T00:00:00Z',
    updated_at: '2024-01-01T00:00:00Z',
    email: 'fixture.user@example.com',
    plan: free ? 0 : 2,
    total_downloaded: 0,
    is_subscribed: !free,
    premium_expires_at: free ? null : PREMIUM_EXPIRES_AT,
    cooldown_until: null,
    auth_id: 'fixture-auth',
  };
  if (url.searchParams.get('settings') === 'true') user.settings = {};
  sendApi(res, 200, ok(user, 'Fetched user data.'));
}

async function handleCheckCached(req, res, url) {
  let hashes = [];
  if (req.method === 'POST') {
    let body;
    try {
      body = await readBody(req, 1 << 20);
    } catch (error) {
      return sendApi(res, error.status || 400, failure('TOO_MUCH_DATA', 'The request body is too large.'));
    }
    let parsed;
    try {
      parsed = JSON.parse(body.toString('utf8'));
    } catch (error) {
      return sendApi(res, 422, { detail: [{ loc: ['body'], msg: 'JSON decode error', type: 'value_error.jsondecode' }] });
    }
    const raw = parsed && parsed.hashes;
    if (Array.isArray(raw)) hashes = raw.map(String);
    else if (typeof raw === 'string') hashes = raw.split(',');
  } else {
    for (const value of url.searchParams.getAll('hash')) hashes.push(...value.split(','));
  }
  hashes = hashes.map((hash) => hash.trim().toLowerCase()).filter((hash) => hash.length > 0);
  if (hashes.length === 0) {
    return sendApi(res, 400, failure('MISSING_REQUIRED_OPTION', 'No hashes were given.'));
  }
  if (hashes.length > MAX_HASHES) {
    return sendApi(res, 400, failure('TOO_MANY_OPTIONS', `At most ${MAX_HASHES} hashes per request.`));
  }
  const withFiles = url.searchParams.get('list_files') === 'true';
  const asList = url.searchParams.get('format') === 'list';
  const found = [];
  const seen = new Set();
  for (const hash of hashes) {
    const known = CATALOG[hash];
    if (!known || known.kind !== 'ready' || seen.has(hash)) continue;
    seen.add(hash);
    const item = { name: known.name, size: known.files.reduce((sum, file) => sum + file.size, 0), hash };
    if (withFiles) item.files = known.files.map((file) => ({ name: file.name, size: file.size }));
    found.push(item);
  }
  let data;
  if (asList) {
    data = found;
  } else {
    data = {};
    for (const item of found) data[item.hash] = item;
  }
  const detail = found.length > 0 ? 'Found cached torrents.' : 'No cached torrents were found.';
  return sendApi(res, 200, ok(data, detail));
}

async function handleCreateTorrent(req, res) {
  let body;
  try {
    body = await readBody(req, 1 << 20);
  } catch (error) {
    return sendApi(res, error.status || 400, failure('TOO_MUCH_DATA', 'The request body is too large.'));
  }
  const form = parseForm(body, req.headers['content-type']);
  const magnet = typeof form.magnet === 'string' ? form.magnet.trim() : '';
  if (!magnet) {
    return sendApi(res, 400, failure('MISSING_REQUIRED_OPTION', 'Missing required option: magnet.'));
  }
  const hash = hashFromMagnet(magnet);
  if (!hash) {
    return sendApi(res, 400, failure('BOZO_TORRENT', 'The magnet link could not be read.'));
  }
  if (state.torrents.some((torrent) => torrent.hash === hash)) {
    return sendApi(res, 400, failure('DIFF_ISSUE', 'This torrent is already in your account or queued.'));
  }
  const definition = definitionFor(hash);
  // add_only_if_cached=true (what the Nuvio app sends): add the torrent only when it is cached, never start a download,
  // otherwise refuse with HTTP 409. Assumed shape of the refusal; the real error code is not documented.
  if (String(form.add_only_if_cached).toLowerCase() === 'true' && definition.kind !== 'ready') {
    return sendApi(res, 409, failure('DOWNLOAD_NOT_CACHED', 'The torrent is not cached.'));
  }
  const torrent = {
    id: state.nextId++, hash, kind: definition.kind, name: definition.name, files: definition.files, createdAt: Date.now(),
  };
  state.torrents.push(torrent);
  const detail = definition.kind === 'ready' ? 'Found Cached Torrent. Using Cached Torrent.' : 'Torrent added.';
  return sendApi(res, 200, ok({ torrent_id: torrent.id, hash, auth_id: 'fixture-auth' }, detail));
}

function handleMyList(req, res, url) {
  const now = Date.now();
  const rawId = url.searchParams.get('id');
  if (rawId !== null) {
    const torrent = state.torrents.find((entry) => String(entry.id) === rawId.trim());
    if (!torrent) return sendApi(res, 404, failure('ITEM_NOT_FOUND', 'Item not found.'));
    return sendApi(res, 200, ok(view(torrent, now), 'Fetched torrent.'));
  }
  const offset = Math.max(0, intParam(url.searchParams.get('offset'), 0));
  const limit = Math.max(1, intParam(url.searchParams.get('limit'), 1000));
  const list = state.torrents.slice().reverse().slice(offset, offset + limit).map((torrent) => view(torrent, now));
  return sendApi(res, 200, ok(list, 'Fetched torrent list.'));
}

function slugOf(file) {
  const base = file.name.split('/').pop().replace(/\.[^.]+$/, '');
  return base.replace(/[^A-Za-z0-9._-]/g, '_');
}

function handleRequestDl(req, res, url) {
  const torrentId = intParam(url.searchParams.get('torrent_id'), null);
  if (torrentId === null) {
    return sendApi(res, 422, { detail: [{ loc: ['query', 'torrent_id'], msg: 'Field required', type: 'missing' }] });
  }
  const fileId = intParam(url.searchParams.get('file_id'), 0);
  const torrent = state.torrents.find((entry) => entry.id === torrentId);
  if (!torrent) return sendApi(res, 404, failure('ITEM_NOT_FOUND', 'Item not found.'));
  if (!isReady(torrent, Date.now())) {
    return sendApi(res, 404, failure('ITEM_NOT_FOUND', 'The files of this torrent are not available yet.'));
  }
  const file = torrent.files.find((entry) => entry.id === fileId);
  if (!file) return sendApi(res, 404, failure('ITEM_NOT_FOUND', 'File not found.'));
  const name = slugOf(file) + '.mp4';
  state.issued.add(name);
  const link = origin(req) + '/cdn/' + name;
  if (url.searchParams.get('redirect') === 'true') {
    res.writeHead(307, Object.assign({ Location: link, 'Content-Length': '0' }, rateHeaders(299)));
    return res.end();
  }
  return sendApi(res, 200, ok(link, 'Requested download link.'));
}

// table of the documented endpoints: methods, authentication style, and whether plan_restricted blocks it
const ENDPOINTS = {
  '/user/me': { methods: ['GET'], auth: 'bearer', restricted: false, handler: handleUserMe },
  '/torrents/checkcached': { methods: ['GET', 'POST'], auth: 'bearer', restricted: true, handler: handleCheckCached },
  '/torrents/createtorrent': { methods: ['POST'], auth: 'bearer', restricted: true, handler: handleCreateTorrent },
  '/torrents/mylist': { methods: ['GET'], auth: 'bearer', restricted: true, handler: handleMyList },
  '/torrents/requestdl': { methods: ['GET'], auth: 'query', restricted: true, handler: handleRequestDl },
};

const AUTH_FAILED = failure('AUTH_ERROR', 'An error occurred while verifying your token. Please try again.');

async function handleApi(req, res, url, route) {
  const mode = state.mode;
  if (mode === 'offline') { req.socket.destroy(); return; }
  if (mode === 'html_error') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(HTML_PAGE) });
    return res.end(HTML_PAGE);
  }
  if (mode === 'rate_limit') {
    return sendJSON(res, 429, failure('RATE_LIMIT_EXCEEDED', 'Too many requests. Please slow down.'),
      Object.assign(rateHeaders(0), { 'Retry-After': '2' }));
  }

  const endpoint = ENDPOINTS[route];
  if (!endpoint) return sendApi(res, 404, failure('ENDPOINT_NOT_FOUND', 'Endpoint not found.'));
  if (!endpoint.methods.includes(req.method)) return sendApi(res, 405, { detail: 'Method Not Allowed' }, { Allow: endpoint.methods.join(', ') });

  let keyAccepted;
  if (endpoint.auth === 'query') {
    const token = url.searchParams.get('token');
    if (token === null) {
      return sendApi(res, 422, { detail: [{ loc: ['query', 'token'], msg: 'Field required', type: 'missing' }] });
    }
    keyAccepted = token === API_KEY;
  } else {
    const header = req.headers.authorization;
    if (!header) return sendApi(res, 401, { detail: 'Not authenticated' });
    const match = /^bearer\s+(.+)$/i.exec(header.trim());
    keyAccepted = match !== null && match[1].trim() === API_KEY;
  }
  if (!keyAccepted || mode === 'bad_token') {
    return sendApi(res, 403, AUTH_FAILED, { 'Retry-After': '60' });
  }
  if (mode === 'plan_restricted' && endpoint.restricted) {
    return sendApi(res, 403, failure('PLAN_RESTRICTED_FEATURE', 'This feature is not available on your plan.'));
  }
  return endpoint.handler(req, res, url);
}

// ---- CDN with Range support ---------------------------------------------------------------------------------------
function serveCdn(req, res, pathname) {
  const match = /^\/cdn\/([A-Za-z0-9._-]+\.mp4)$/.exec(pathname);
  if (!match || !state.issued.has(match[1])) {
    return sendJSON(res, 404, failure('ITEM_NOT_FOUND', 'Unknown or expired link.'));
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return sendJSON(res, 405, { detail: 'Method Not Allowed' }, { Allow: 'GET, HEAD' });
  }
  let size;
  try {
    size = fs.statSync(VIDEO).size;
  } catch (error) {
    return sendJSON(res, 404, failure('ITEM_NOT_FOUND', 'The fixture video is missing (use --video).'));
  }
  const base = { 'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
  let start = 0;
  let end = size - 1;
  let partial = false;
  const header = req.headers.range;
  if (header) {
    const range = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
    if (range && (range[1] !== '' || range[2] !== '')) {
      if (range[1] === '') {
        const suffix = parseInt(range[2], 10);
        if (suffix === 0) { res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end(); }
        start = Math.max(0, size - suffix);
      } else {
        start = parseInt(range[1], 10);
        if (range[2] !== '') end = Math.min(parseInt(range[2], 10), size - 1);
      }
      if (start >= size || start > end) { res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end(); }
      partial = true;
    }
  }
  const length = end - start + 1;
  if (partial) {
    res.writeHead(206, Object.assign({ 'Content-Length': length, 'Content-Range': `bytes ${start}-${end}/${size}` }, base));
  } else {
    res.writeHead(200, Object.assign({ 'Content-Length': length }, base));
  }
  if (req.method === 'HEAD' || length === 0) return res.end();
  const stream = fs.createReadStream(VIDEO, { start, end });
  res.on('close', () => stream.destroy());
  stream.on('error', () => res.destroy());
  stream.pipe(res);
}

// ---- control ------------------------------------------------------------------------------------------------------
function handleControl(req, res, pathname, url) {
  if (pathname === '/__control/mode') {
    const name = url.searchParams.get('name');
    if (name === null) return sendJSON(res, 200, { ok: true, mode: state.mode });
    if (!MODES.includes(name)) return sendJSON(res, 400, { ok: false, error: 'unknown mode', modes: MODES });
    state.mode = name;
    return sendJSON(res, 200, { ok: true, mode: state.mode });
  }
  if (pathname === '/__control/reset') {
    resetState();
    return sendJSON(res, 200, { ok: true });
  }
  if (pathname === '/__control/requests') return sendJSON(res, 200, state.requests);
  return sendJSON(res, 404, { ok: false, error: 'unknown control path' });
}

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, 'http://fixture.invalid');
  } catch (error) {
    return sendJSON(res, 400, failure('INVALID_INPUT', 'Malformed request.'));
  }
  let pathname = url.pathname;
  try {
    pathname = decodeURIComponent(pathname);
  } catch (error) {
    // keep the raw path
  }
  if (pathname.startsWith('/__control/')) return handleControl(req, res, pathname, url);

  state.requests.push(pathname);
  if (pathname.startsWith('/cdn/')) return serveCdn(req, res, pathname);
  if (pathname === '/') return sendJSON(res, 200, ok(null, 'Aether TorBox fixture (not the real service).'));
  if (pathname.startsWith('/v1/api/')) {
    handleApi(req, res, url, pathname.slice('/v1/api'.length)).catch(() => {
      if (!res.headersSent) sendApi(res, 500, failure('UNKNOWN_ERROR', 'Fixture error.'));
      else res.destroy();
    });
    return undefined;
  }
  return sendJSON(res, 404, failure('ENDPOINT_NOT_FOUND', 'Endpoint not found.'));
});

server.listen(PORT, HOST, () => console.log(`Aether TorBox fixture listening on ${HOST}:${PORT}`));
