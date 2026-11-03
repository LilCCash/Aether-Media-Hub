// End-to-end check of the built site against a fake addon, in a real browser:  node scripts/smoke.mjs <password>
import http from "node:http";
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");

const password = process.argv[2];
const MEDIA = "/tmp/aether-smoke.webm";
if (!fs.existsSync(MEDIA)) execFileSync("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=10:duration=40", "-f", "lavfi", "-i", "sine=frequency=440:duration=40", "-c:v", "libvpx", "-b:v", "200k", "-c:a", "libvorbis", MEDIA]);

const json = (res, body) => { res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" }); res.end(JSON.stringify(body)); };
let base = "";
const metas = [{ id: "tt1", type: "movie", name: "Film di prova", poster: "" }, { id: "tt2", type: "series", name: "Serie di prova" }];
const addon = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split("?")[0]);
  if (url === "/manifest.json") return json(res, { id: "test.addon", name: "Addon di prova", version: "1.0.0", types: ["movie", "series"], idPrefixes: ["tt"], resources: ["catalog", "meta", "stream", "subtitles"],
    catalogs: [{ type: "movie", id: "top", name: "Top", extra: [{ name: "genre", options: ["Azione"] }] }, { type: "series", id: "serie", name: "Serie" }, { type: "movie", id: "search", name: "Cerca", extra: [{ name: "search", isRequired: true }] }] });
  if (url.startsWith("/catalog/movie/search/")) return json(res, { metas: metas.filter((m) => m.type === "movie") });
  if (url.startsWith("/catalog/movie/")) return json(res, { metas: metas.filter((m) => m.type === "movie") });
  if (url.startsWith("/catalog/series/")) return json(res, { metas: metas.filter((m) => m.type === "series") });
  if (url === "/meta/movie/tt1.json") return json(res, { meta: { ...metas[0], description: "Una trama.", genres: ["Azione"], releaseInfo: "2024" } });
  if (url === "/meta/series/tt2.json") return json(res, { meta: { ...metas[1], videos: [{ id: "tt2:1:1", season: 1, episode: 1, title: "Pilota" }, { id: "tt2:1:2", season: 1, episode: 2, title: "Secondo" }, { id: "tt2:2:1", season: 2, episode: 1, title: "Ritorno" }] } });
  if (url.startsWith("/stream/")) return json(res, { streams: [
    { url: base + "/media/v.webm", name: "Prova 1080p", title: "Film.1080p.x264.ITA 1.2 GB" },
    { url: "https://cdn.example/a.mkv", name: "MKV 2160p", title: "Film 2160p HDR HEVC" },
    { infoHash: "0123456789abcdef0123456789abcdef01234567", name: "Torrent" }] });
  if (url.startsWith("/subtitles/")) return json(res, { subtitles: [{ url: base + "/s.srt", lang: "ita" }] });
  if (url === "/s.srt") { res.writeHead(200, { "Access-Control-Allow-Origin": "*" }); return res.end("1\n00:00:01,000 --> 00:00:03,000\nCiao\n"); }
  if (url === "/media/v.webm") {
    const size = fs.statSync(MEDIA).size; const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range ?? "");
    const start = range ? Number(range[1]) : 0; const end = range && range[2] ? Number(range[2]) : size - 1;
    res.writeHead(range ? 206 : 200, { "Content-Type": "video/webm", "Accept-Ranges": "bytes", "Content-Length": end - start + 1, "Access-Control-Allow-Origin": "*", ...(range ? { "Content-Range": `bytes ${start}-${end}/${size}` } : {}) });
    return fs.createReadStream(MEDIA, { start, end }).pipe(res);
  }
  res.writeHead(404, { "Access-Control-Allow-Origin": "*" }); res.end();
});
const site = http.createServer((req, res) => {
  const path = "dist" + (req.url === "/" ? "/index.html" : req.url.split("?")[0]);
  if (!fs.existsSync(path)) { res.writeHead(404); return res.end(); }
  const type = path.endsWith(".js") ? "text/javascript" : path.endsWith(".css") ? "text/css" : path.endsWith(".html") ? "text/html" : path.endsWith(".json") || path.endsWith(".webmanifest") ? "application/json" : "application/octet-stream";
  res.writeHead(200, { "Content-Type": type }); fs.createReadStream(path).pipe(res);
});
await new Promise((r) => addon.listen(0, "127.0.0.1", r)); await new Promise((r) => site.listen(0, "127.0.0.1", r));
base = `http://127.0.0.1:${addon.address().port}`;
const siteUrl = `http://127.0.0.1:${site.address().port}/`;

const checks = []; const check = (name, ok, extra = "") => { checks.push(ok); console.log(`${ok ? "OK  " : "FAIL"} ${name}${extra ? " — " + extra : ""}`); };
const browser = await chromium.launch(); const page = await browser.newPage(); const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
try {
  await page.goto(siteUrl);
  check("la pagina chiede la password", await page.locator("input[type=password]").count() === 1);
  await page.fill("input[type=password]", "sbagliata"); await page.click("button[type=submit]");
  await page.waitForSelector("text=Password errata", { timeout: 15000 }); check("password sbagliata respinta", true);
  await page.fill("input[type=password]", password); await page.click("button[type=submit]");
  await page.waitForSelector("header.bar", { timeout: 15000 }); check("password giusta: entra", true);
  await page.goto(siteUrl + "#/addons");
  await page.fill("input[type=text]", base + "/manifest.json"); await page.click("text=Installa");
  await page.waitForSelector("text=Addon di prova", { timeout: 10000 }); check("installa un addon dal manifest", true);
  await page.goto(siteUrl + "#/"); await page.waitForSelector("text=Film di prova", { timeout: 10000 }); check("la Home mostra il catalogo dell'addon", true);
  await page.click("a.card:has-text('Film di prova')"); await page.waitForSelector("text=Una trama.", { timeout: 10000 }); check("scheda del film", true);
  await page.waitForSelector("text=Prova 1080p", { timeout: 10000 });
  check("fonti: MKV segnalato e torrent senza riproduzione", (await page.locator("text=spesso non si riproduce").count()) === 1 && (await page.locator("text=Copia il magnet").count()) === 1);
  await page.click("button:has-text('Riproduci')"); await page.waitForSelector("video.player", { timeout: 10000 });
  await page.waitForFunction(() => { const v = document.querySelector("video"); return v && v.readyState >= 2 && v.duration > 1; }, null, { timeout: 15000 });
  check("il video parte nel browser", true);
  await page.waitForSelector("select[aria-label=Sottotitoli]", { timeout: 10000 }); check("sottotitoli dell'addon elencati", true);
  check("lettore esterno e copia link sul player", (await page.locator("button:has-text('Apri nel lettore')").count()) === 1 && (await page.locator("button:has-text('Copia il link')").count()) === 1);
  await page.evaluate(() => { const v = document.querySelector("video"); v.currentTime = 30; });
  await page.waitForTimeout(6500); await page.goBack();
  await page.goto(siteUrl + "#/"); await page.waitForSelector("text=Continua a guardare", { timeout: 10000 }); check("«Continua a guardare» dopo la riproduzione", true);
  await page.fill("input[type=search]", "film"); await page.press("input[type=search]", "Enter");
  await page.waitForSelector("text=Risultati per", { timeout: 10000 }); await page.waitForSelector("a.card:has-text('Film di prova')", { timeout: 10000 }); check("ricerca", true);
  await page.goto(siteUrl + "#/meta/series/tt2"); await page.waitForSelector("button.ep", { timeout: 10000 });
  check("serie: stagioni ed episodi", (await page.locator("button.ep").count()) === 2);
  await page.click("button.ep:has-text('Secondo')"); await page.waitForSelector("text=Prova 1080p", { timeout: 10000 }); check("fonti dell'episodio", true);
  await page.click("button:has-text('preferiti')"); await page.goto(siteUrl + "#/library"); await page.waitForSelector("a.card:has-text('Serie di prova')"); check("preferiti nella libreria", true);
  await page.reload(); await page.waitForSelector("header.bar", { timeout: 10000 }); check("dopo il ricaricamento resta sbloccata", true);
} catch (error) { check("percorso completo", false, String(error).split("\n")[0]); }
check("nessun errore JavaScript", errors.length === 0, errors.join(" | "));
await browser.close(); addon.close(); site.close();
process.exit(checks.every(Boolean) ? 0 : 1);
