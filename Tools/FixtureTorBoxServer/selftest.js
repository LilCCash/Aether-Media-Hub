#!/usr/bin/env node
// Checks that server.js behaves as documented in its header. Zero dependencies (Node >= 18).
//
//   node selftest.js
//
// It starts the fixture on a free port with a small generated file standing in for the video, runs the checks below
// and exits non-zero on the first group that fails. Nothing leaves the machine.
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const KEY = 'test-key';
const MOVIE = '1'.repeat(40);
const SERIES = '2'.repeat(40);
const SLOW = '3'.repeat(40);
const OTHER = 'ab'.repeat(20);
const VIDEO_BYTES = Buffer.from(Array.from({ length: 1000 }, (_, i) => i % 251));

let base = '';
let failed = 0;

async function api(method, route, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (options.auth !== false) headers.Authorization = 'Bearer ' + (options.key || KEY);
  const response = await fetch(base + '/v1/api' + route, { method, headers, body: options.body, redirect: 'manual' });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch (error) { /* not JSON */ }
  return { status: response.status, headers: response.headers, text, json };
}

function post(route, body, contentType) {
  return api('POST', route, { body, headers: { 'Content-Type': contentType } });
}

function checkCached(hashes, query) {
  return post('/torrents/checkcached?format=list&list_files=true' + (query || ''), JSON.stringify({ hashes }), 'application/json');
}

function create(hash, extra) {
  const magnet = `magnet:?xt=urn:btih:${hash}&tr=${encodeURIComponent('udp://t.example:80/announce')}`;
  const body = 'magnet=' + encodeURIComponent(magnet) + '&allow_zip=false' + (extra || '');
  return post('/torrents/createtorrent', body, 'application/x-www-form-urlencoded');
}

async function control(route) {
  const response = await fetch(base + '/__control/' + route);
  return { status: response.status, json: await response.json() };
}

async function group(name, body) {
  try {
    await body();
    console.log('ok   ' + name);
  } catch (error) {
    failed += 1;
    console.log('FAIL ' + name + '\n     ' + String(error && error.message).split('\n').join('\n     '));
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const video = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'torbox-fixture-')), 'sample.mp4');
  fs.writeFileSync(video, VIDEO_BYTES);
  const port = 20000 + Math.floor(Math.random() * 20000);
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js'), '--port', String(port), '--video', video,
    '--download-seconds', '1.5'], { stdio: ['ignore', 'pipe', 'inherit'] });
  base = `http://127.0.0.1:${port}`;
  try {
    for (let attempt = 0; attempt < 50; attempt++) {
      try { await fetch(base + '/'); break; } catch (error) { await sleep(100); }
    }

    await group('authentication', async () => {
      const none = await api('GET', '/user/me', { auth: false });
      assert.strictEqual(none.status, 401);
      assert.deepStrictEqual(none.json, { detail: 'Not authenticated' });
      const wrong = await api('GET', '/user/me', { key: 'something-else' });
      assert.strictEqual(wrong.status, 403);
      assert.deepStrictEqual(wrong.json, { success: false, error: 'AUTH_ERROR',
        detail: 'An error occurred while verifying your token. Please try again.', data: null });
      assert.strictEqual(wrong.headers.get('retry-after'), '60');
      const noToken = await fetch(base + '/v1/api/torrents/requestdl?torrent_id=1');
      assert.strictEqual(noToken.status, 422);
      const badToken = await fetch(base + '/v1/api/torrents/requestdl?token=nope&torrent_id=1&file_id=0');
      assert.strictEqual(badToken.status, 403);
    });

    await group('user/me never leaks the key and describes a Pro plan', async () => {
      const me = await api('GET', '/user/me?settings=false');
      assert.strictEqual(me.status, 200);
      assert.strictEqual(me.json.success, true);
      assert.strictEqual(me.json.data.plan, 2);
      assert.strictEqual(me.json.data.is_subscribed, true);
      assert.ok(Date.parse(me.json.data.premium_expires_at) > Date.now());
      assert.ok(!me.text.includes(KEY));
      assert.ok(me.headers.get('x-ratelimit-limit'));
    });

    await group('checkcached reports exactly the two cached hashes (POST and GET, list and object)', async () => {
      const posted = await checkCached([MOVIE.toUpperCase(), SERIES, SLOW, OTHER]);
      assert.strictEqual(posted.status, 200);
      assert.deepStrictEqual(posted.json.data.map((item) => item.hash).sort(), [MOVIE, SERIES]);
      const movie = posted.json.data.find((item) => item.hash === MOVIE);
      assert.strictEqual(movie.files.length, 2);
      const video = movie.files.find((file) => file.name.endsWith('.mkv'));
      assert.strictEqual(video.name, 'Cached.Movie.2024.1080p/Cached.Movie.2024.1080p.mkv');
      assert.ok(video.size > 1.19 * 1024 ** 3 && video.size < 1.21 * 1024 ** 3);
      assert.ok(movie.files.every((file) => file.id === undefined), 'checkcached carries no file ids');
      const series = posted.json.data.find((item) => item.hash === SERIES);
      assert.deepStrictEqual(series.files.map((file) => file.name.match(/S01E0\d/)[0]), ['S01E01', 'S01E02']);

      const noFiles = await post('/torrents/checkcached?format=list', JSON.stringify({ hashes: [MOVIE] }), 'application/json');
      assert.strictEqual(noFiles.json.data[0].files, undefined);

      const got = await api('GET', `/torrents/checkcached?format=list&list_files=true&hash=${MOVIE},${SLOW}&hash=${SERIES}`);
      assert.deepStrictEqual(got.json.data.map((item) => item.hash).sort(), [MOVIE, SERIES]);

      const object = await post('/torrents/checkcached', JSON.stringify({ hashes: [MOVIE, OTHER] }), 'application/json');
      assert.deepStrictEqual(Object.keys(object.json.data), [MOVIE]);

      const none = await checkCached([OTHER]);
      assert.deepStrictEqual(none.json.data, []);
      assert.strictEqual(none.json.success, true);

      const many = await checkCached(Array.from({ length: 101 }, (_, i) => String(i).padStart(40, '0')));
      assert.strictEqual(many.status, 400);
      assert.strictEqual(many.json.error, 'TOO_MANY_OPTIONS');
      const exactly = await checkCached(Array.from({ length: 100 }, (_, i) => String(i).padStart(40, '0')));
      assert.strictEqual(exactly.status, 200);
    });

    await group('a cached movie is ready at once; requestdl and the CDN with Range', async () => {
      const added = await create(MOVIE);
      assert.strictEqual(added.status, 200);
      assert.strictEqual(added.json.detail, 'Found Cached Torrent. Using Cached Torrent.');
      const id = added.json.data.torrent_id;
      assert.ok(Number.isInteger(id));
      const item = (await api('GET', `/torrents/mylist?id=${id}&bypass_cache=true`)).json.data;
      assert.ok(!Array.isArray(item), 'id gives one object');
      assert.strictEqual(item.download_present, true);
      assert.strictEqual(item.download_finished, true);
      assert.strictEqual(item.hash, MOVIE);
      const mkv = item.files.find((file) => file.short_name.endsWith('.mkv'));
      assert.ok(item.files.indexOf(mkv) !== mkv.id, 'file ids are not array positions');

      const list = await api('GET', '/torrents/mylist?bypass_cache=true&offset=0&limit=1000');
      assert.ok(Array.isArray(list.json.data));
      assert.strictEqual(list.json.data.length, 1);

      const link = await fetch(`${base}/v1/api/torrents/requestdl?token=${KEY}&torrent_id=${id}&file_id=${mkv.id}`);
      const linkText = await link.text();
      assert.strictEqual(link.status, 200);
      assert.ok(!linkText.includes(KEY), 'the answer never echoes the key');
      const url = JSON.parse(linkText).data;
      assert.ok(url.startsWith(base + '/cdn/') && url.endsWith('.mp4'), url);
      assert.ok(url.includes('Cached.Movie.2024.1080p'));

      const whole = await fetch(url);
      assert.strictEqual(whole.status, 200);
      assert.strictEqual(whole.headers.get('accept-ranges'), 'bytes');
      assert.deepStrictEqual(Buffer.from(await whole.arrayBuffer()), VIDEO_BYTES);
      const part = await fetch(url, { headers: { Range: 'bytes=10-19' } });
      assert.strictEqual(part.status, 206);
      assert.strictEqual(part.headers.get('content-range'), 'bytes 10-19/1000');
      assert.deepStrictEqual(Buffer.from(await part.arrayBuffer()), VIDEO_BYTES.subarray(10, 20));
      const open = await fetch(url, { headers: { Range: 'bytes=990-' } });
      assert.strictEqual(open.headers.get('content-range'), 'bytes 990-999/1000');
      const suffix = await fetch(url, { headers: { Range: 'bytes=-5' } });
      assert.strictEqual(suffix.headers.get('content-range'), 'bytes 995-999/1000');
      const beyond = await fetch(url, { headers: { Range: 'bytes=5000-' } });
      assert.strictEqual(beyond.status, 416);
      const head = await fetch(url, { method: 'HEAD' });
      assert.strictEqual(head.headers.get('content-length'), '1000');
      const unknown = await fetch(base + '/cdn/Never.Issued.mp4');
      assert.strictEqual(unknown.status, 404);

      const redirect = await fetch(`${base}/v1/api/torrents/requestdl?token=${KEY}&torrent_id=${id}&file_id=${mkv.id}&redirect=true`, { redirect: 'manual' });
      assert.strictEqual(redirect.status, 307);
      assert.strictEqual(redirect.headers.get('location'), url);

      const missingFile = await fetch(`${base}/v1/api/torrents/requestdl?token=${KEY}&torrent_id=${id}&file_id=999`);
      assert.strictEqual(missingFile.status, 404);
      assert.strictEqual((await missingFile.json()).error, 'ITEM_NOT_FOUND');
    });

    await group('adding the same hash twice is DIFF_ISSUE, bad magnets are refused', async () => {
      const again = await create(MOVIE);
      assert.strictEqual(again.status, 400);
      assert.strictEqual(again.json.error, 'DIFF_ISSUE');
      const bad = await post('/torrents/createtorrent', 'magnet=' + encodeURIComponent('magnet:?xt=urn:btih:nothex'),
        'application/x-www-form-urlencoded');
      assert.strictEqual(bad.json.error, 'BOZO_TORRENT');
      const missing = await post('/torrents/createtorrent', 'allow_zip=false', 'application/x-www-form-urlencoded');
      assert.strictEqual(missing.json.error, 'MISSING_REQUIRED_OPTION');
      const boundary = 'XBOUNDARYX';
      const multipart = `--${boundary}\r\nContent-Disposition: form-data; name="magnet"\r\n\r\nmagnet:?xt=urn:btih:${'cd'.repeat(20)}\r\n`
        + `--${boundary}\r\nContent-Disposition: form-data; name="allow_zip"\r\n\r\nfalse\r\n--${boundary}--\r\n`;
      const viaMultipart = await post('/torrents/createtorrent', multipart, `multipart/form-data; boundary=${boundary}`);
      assert.strictEqual(viaMultipart.status, 200, viaMultipart.text);
      // 32 character base32 spelling of the series hash 2222…: the same torrent as SERIES in hex
      const base32 = 'EIRCEIRCEIRCEIRCEIRCEIRCEIRCEIRC';
      const viaBase32 = await create(base32);
      assert.strictEqual(viaBase32.json.data.hash, SERIES);
    });

    await group('a not cached torrent downloads over time, then finishes', async () => {
      const added = await create(SLOW);
      assert.strictEqual(added.status, 200);
      assert.notStrictEqual(added.json.detail, 'Found Cached Torrent. Using Cached Torrent.');
      const id = added.json.data.torrent_id;
      const first = (await api('GET', `/torrents/mylist?id=${id}&bypass_cache=true`)).json.data;
      assert.strictEqual(first.download_present, false);
      assert.strictEqual(first.download_finished, false);
      assert.ok(first.progress >= 0.2 && first.progress < 1, String(first.progress));
      assert.ok(first.download_speed > 0 && first.eta > 0);
      const early = await fetch(`${base}/v1/api/torrents/requestdl?token=${KEY}&torrent_id=${id}&file_id=41`);
      assert.strictEqual(early.status, 404, 'no link before the download is complete');
      await sleep(900);
      const middle = (await api('GET', `/torrents/mylist?id=${id}`)).json.data;
      assert.ok(middle.progress > first.progress && middle.progress < 1, `${first.progress} -> ${middle.progress}`);
      await sleep(900);
      const done = (await api('GET', `/torrents/mylist?id=${id}`)).json.data;
      assert.strictEqual(done.progress, 1);
      assert.strictEqual(done.download_present, true);
      assert.strictEqual(done.download_finished, true);
      const link = await fetch(`${base}/v1/api/torrents/requestdl?token=${KEY}&torrent_id=${id}&file_id=41`);
      assert.strictEqual(link.status, 200);
    });

    await group('any other hash is accepted and stays stalled', async () => {
      const added = await create(OTHER);
      assert.strictEqual(added.status, 200);
      await sleep(1700);
      const item = (await api('GET', `/torrents/mylist?id=${added.json.data.torrent_id}`)).json.data;
      assert.strictEqual(item.download_state, 'stalled (no seeds)');
      assert.strictEqual(item.download_finished, false);
      const missing = await api('GET', '/torrents/mylist?id=424242');
      assert.strictEqual(missing.status, 404);
      assert.strictEqual(missing.json.error, 'ITEM_NOT_FOUND');
    });

    await group('failure modes', async () => {
      assert.strictEqual((await control('mode?name=nonsense')).status, 400);
      assert.strictEqual((await control('mode?name=bad_token')).json.mode, 'bad_token');
      const revoked = await api('GET', '/user/me');
      assert.strictEqual(revoked.status, 403);
      assert.strictEqual(revoked.json.error, 'AUTH_ERROR');

      await control('mode?name=rate_limit');
      const limited = await api('GET', '/torrents/mylist');
      assert.strictEqual(limited.status, 429);
      assert.strictEqual(limited.headers.get('retry-after'), '2');
      assert.strictEqual(limited.json.error, 'RATE_LIMIT_EXCEEDED');

      await control('mode?name=plan_restricted');
      const restricted = await create(MOVIE);
      assert.strictEqual(restricted.status, 403);
      assert.strictEqual(restricted.json.error, 'PLAN_RESTRICTED_FEATURE');
      const free = (await api('GET', '/user/me')).json.data;
      assert.strictEqual(free.plan, 0);

      await control('mode?name=html_error');
      const html = await api('GET', '/user/me');
      assert.strictEqual(html.status, 200);
      assert.ok(html.headers.get('content-type').startsWith('text/html'));
      assert.strictEqual(html.json, null);

      await control('mode?name=offline');
      let reset = false;
      try { await api('GET', '/user/me'); } catch (error) { reset = true; }
      assert.ok(reset, 'the connection must be dropped');
      assert.strictEqual((await control('mode')).json.mode, 'offline');

      await control('mode?name=normal');
      assert.strictEqual((await api('GET', '/user/me')).status, 200);
    });

    await group('requests are recorded without query strings; nothing can delete', async () => {
      await api('POST', '/torrents/controltorrent', { body: '{"operation":"delete"}', headers: { 'Content-Type': 'application/json' } });
      const unknown = await api('GET', '/torrents/controltorrent');
      assert.strictEqual(unknown.status, 404);
      assert.strictEqual(unknown.json.error, 'ENDPOINT_NOT_FOUND');
      const wrongMethod = await api('POST', '/user/me');
      assert.strictEqual(wrongMethod.status, 405);
      const paths = await (await fetch(base + '/__control/requests')).json();
      assert.ok(paths.includes('/v1/api/torrents/mylist'));
      assert.ok(paths.includes('/v1/api/torrents/requestdl'));
      assert.ok(paths.some((entry) => entry.startsWith('/cdn/')));
      assert.ok(paths.includes('/v1/api/torrents/controltorrent'), 'unknown endpoints are recorded too');
      assert.ok(paths.every((entry) => !entry.includes('?') && !entry.includes(KEY)), 'no query strings, no key');
      assert.ok(paths.every((entry) => !entry.startsWith('/__control')));
    });

    await group('reset forgets the account, the CDN names and the log', async () => {
      assert.strictEqual((await control('reset')).status, 200);
      assert.deepStrictEqual(await (await fetch(base + '/__control/requests')).json(), []);
      const list = await api('GET', '/torrents/mylist');
      assert.deepStrictEqual(list.json.data, []);
      const added = await create(MOVIE);
      assert.strictEqual(added.status, 200, 'the hash can be added again after a reset');
      assert.strictEqual((await control('mode')).json.mode, 'normal');
    });
  } finally {
    child.kill();
    fs.rmSync(path.dirname(video), { recursive: true, force: true });
  }
  if (failed > 0) {
    console.log(`${failed} group(s) failed`);
    process.exit(1);
  }
  console.log('all groups passed');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
