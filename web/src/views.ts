import {
  fetchCatalog, fetchJson, genreRequired, genresOf, isPlainFeed, isSearchCatalog, loadManifest, resourceUrl, searchRequired, supports,
  type Addon, type CatalogDef, type Meta, type MetaPreview, type Video,
} from "./addons";
import { saveAddons, state } from "./app";
import { clear, copyText, h, srtToVtt, toast } from "./dom";
import { EXTERNAL_PLAYERS, externalLink, m3uFor, type ExternalId } from "./external";
import { describeStream, formatSize, sortStreams, type RawStream, type StreamItem } from "./streams";
import { isFavorite, progressKey, recentProgress, saveProgress, store, toggleFavorite } from "./store";
import Hls from "hls.js";

type Root = HTMLElement;
let token = 0;
/** A view stays valid while it is the latest one drawn: late answers of a page that was left are dropped. */
export const begin = (root: Root): number => { clear(root); return ++token; };
const alive = (t: number): boolean => t === token;
const spinner = (text = "Carico…") => h("div", { class: "spin" }, text);

const enc = encodeURIComponent;
const dec = (s: string) => { try { return decodeURIComponent(s); } catch { return s; } };

// ---------- cards and rails ----------
function card(meta: MetaPreview, extra?: { progress?: number }): HTMLElement {
  const link = h("a", { class: "card", href: `#/meta/${enc(meta.type)}/${enc(meta.id)}` });
  link.appendChild(meta.poster ? h("img", { class: "poster", src: meta.poster, alt: "", loading: "lazy", referrerpolicy: "no-referrer" }) : h("div", { class: "ph" }, meta.name));
  if (extra?.progress && extra.progress > 0) link.appendChild(h("div", { class: "bar-progress" }, h("i", { style: `width:${Math.min(100, Math.round(extra.progress * 100))}%` })));
  link.appendChild(h("div", { class: "name" }, meta.name));
  return link;
}

function rail(title: string, items: HTMLElement[], seeAll?: string): HTMLElement {
  const head = h("div", { class: "row-head" }, h("h2", {}, title), seeAll ? h("a", { href: seeAll }, "Vedi tutto") : null);
  return h("section", {}, head, h("div", { class: "rail" }, ...items));
}

const catalogTitle = (addon: Addon, catalog: CatalogDef) => `${catalog.name ?? catalog.id} · ${catalog.type} (${addon.manifest.name})`;

// ---------- Home ----------
export async function homeView(root: Root): Promise<void> {
  const t = begin(root);
  root.appendChild(h("h1", {}, "Home"));
  const resume = recentProgress(15);
  if (resume.length) root.appendChild(rail("Continua a guardare", resume.map((p) => card(p.meta, { progress: p.position / p.duration }))));
  const favorites = store.favorites();
  if (favorites.length) root.appendChild(rail("I tuoi preferiti", favorites.slice(0, 20).map((m) => card(m))));
  if (!state.addons.length) {
    root.appendChild(h("p", { class: "dim" }, "Nessun addon installato. ", h("a", { href: "#/addons", class: "btn primary" }, "Installa un addon")));
    return;
  }
  let rows = 0;
  state.addons.forEach((addon, ai) => {
    addon.manifest.catalogs.forEach((catalog, ci) => {
      if (!isPlainFeed(catalog) || searchRequired(catalog) || rows >= 14) return;
      rows += 1;
      const holder = h("div", {}, spinner(catalogTitle(addon, catalog)));
      root.appendChild(holder);
      fetchCatalog(addon, catalog).then((metas) => {
        if (!alive(t)) return;
        if (!metas.length) { holder.remove(); return; }
        holder.replaceWith(rail(catalogTitle(addon, catalog), metas.slice(0, 20).map((m) => card(m)), `#/catalog/${ai}/${ci}`));
      }).catch((error: Error) => { if (alive(t)) holder.replaceWith(h("p", { class: "dim small" }, `${catalogTitle(addon, catalog)}: ${error.message}`)); });
    });
  });
  if (rows === 0) root.appendChild(h("p", { class: "dim" }, "Gli addon installati non hanno cataloghi da mostrare nella Home. Prova «Scopri» o la ricerca."));
}

// ---------- Catalog ----------
export async function catalogView(root: Root, params: string[]): Promise<void> {
  const t = begin(root);
  const addon = state.addons[Number(params[0])];
  const catalog = addon?.manifest.catalogs[Number(params[1])];
  if (!addon || !catalog) { root.appendChild(h("p", { class: "err" }, "Catalogo non trovato.")); return; }
  root.appendChild(h("h1", {}, catalogTitle(addon, catalog)));
  const genres = genresOf(catalog);
  const needGenre = genreRequired(catalog);
  let genre = needGenre ? (genres[0] ?? "") : "";
  const grid = h("div", { class: "grid" });
  const more = h("button", { class: "btn" }, "Carica altri") as HTMLButtonElement;
  const status = h("div", {});
  let loaded = 0;
  async function load(reset: boolean): Promise<void> {
    if (reset) { clear(grid); loaded = 0; }
    more.disabled = true;
    clear(status);
    status.appendChild(spinner());
    try {
      const extra: Record<string, string> = {};
      if (genre) extra.genre = genre;
      if (loaded > 0) extra.skip = String(loaded);
      const metas = await fetchCatalog(addon!, catalog!, extra);
      if (!alive(t)) return;
      metas.forEach((m) => grid.appendChild(card(m)));
      loaded += metas.length;
      clear(status);
      if (!metas.length && loaded === 0) status.appendChild(h("p", { class: "dim" }, "Nessun titolo."));
      more.style.display = metas.length ? "" : "none";
    } catch (error) {
      if (alive(t)) { clear(status); status.appendChild(h("p", { class: "err" }, (error as Error).message)); }
    } finally { more.disabled = false; }
  }
  if (genres.length) {
    const select = h("select", { "aria-label": "Genere" }) as HTMLSelectElement;
    if (!needGenre) select.appendChild(h("option", { value: "" }, "Tutti i generi"));
    genres.forEach((g) => select.appendChild(h("option", { value: g }, g)));
    select.value = genre;
    select.addEventListener("change", () => { genre = select.value; void load(true); });
    root.appendChild(h("p", {}, select));
  }
  root.append(grid, status, h("p", {}, more));
  more.addEventListener("click", () => void load(false));
  await load(true);
}

// ---------- Search ----------
export async function searchView(root: Root, params: string[]): Promise<void> {
  const t = begin(root);
  const query = dec(params[0] ?? "").trim();
  root.appendChild(h("h1", {}, query ? `Risultati per «${query}»` : "Cerca"));
  if (!query) { root.appendChild(h("p", { class: "dim" }, "Scrivi un titolo nella barra in alto.")); return; }
  let any = false;
  const jobs: Promise<void>[] = [];
  state.addons.forEach((addon) => addon.manifest.catalogs.filter(isSearchCatalog).forEach((catalog) => {
    const holder = h("div", {}, spinner(catalogTitle(addon, catalog)));
    root.appendChild(holder);
    jobs.push(fetchCatalog(addon, catalog, { search: query }).then((metas) => {
      if (!alive(t)) return;
      if (!metas.length) { holder.remove(); return; }
      any = true;
      holder.replaceWith(rail(catalogTitle(addon, catalog), metas.slice(0, 30).map((m) => card(m))));
    }).catch((error: Error) => { if (alive(t)) holder.replaceWith(h("p", { class: "dim small" }, `${catalogTitle(addon, catalog)}: ${error.message}`)); }));
  }));
  if (!jobs.length) { root.appendChild(h("p", { class: "dim" }, "Nessun addon installato offre la ricerca.")); return; }
  await Promise.all(jobs);
  if (alive(t) && !any) root.appendChild(h("p", { class: "dim" }, "Nessun risultato."));
}

// ---------- Detail ----------
async function loadMeta(type: string, id: string): Promise<Meta | null> {
  for (const addon of state.addons) {
    if (!supports(addon.manifest, "meta", type, id)) continue;
    try {
      const data = await fetchJson<{ meta?: Meta }>(resourceUrl(addon, "meta", type, id));
      if (data.meta && data.meta.id) return data.meta;
    } catch { /* try the next addon */ }
  }
  return null;
}

const videoLabel = (v: Video) => `${v.episode != null ? `${v.episode}. ` : ""}${v.title ?? v.name ?? "Episodio"}`;

export async function metaView(root: Root, params: string[]): Promise<void> {
  const t = begin(root);
  const type = dec(params[0] ?? ""), id = dec(params[1] ?? "");
  root.appendChild(spinner());
  const meta = await loadMeta(type, id);
  if (!alive(t)) return;
  clear(root);
  if (!meta) { root.appendChild(h("p", { class: "err" }, "Non trovo i dettagli di questo titolo negli addon installati.")); return; }

  const fav = h("button", { class: "btn" }) as HTMLButtonElement;
  const paintFav = () => { fav.textContent = isFavorite(meta.id) ? "★ Nei preferiti" : "☆ Aggiungi ai preferiti"; };
  paintFav();
  fav.addEventListener("click", () => { toggleFavorite(meta); paintFav(); });

  const chips = h("div", { class: "chips" });
  [meta.releaseInfo ?? meta.year, meta.runtime, meta.imdbRating ? `IMDb ${meta.imdbRating}` : null, ...(meta.genres ?? [])].filter(Boolean).forEach((c) => chips.appendChild(h("span", { class: "chip" }, String(c))));
  root.appendChild(h("div", { class: "hero" },
    meta.poster ? h("img", { class: "poster", src: meta.poster, alt: "", referrerpolicy: "no-referrer" }) : h("div", { class: "ph" }, meta.name),
    h("div", {}, h("h1", {}, meta.name), chips, meta.description ? h("p", {}, meta.description) : null,
      meta.cast?.length ? h("p", { class: "dim small" }, "Cast: " + meta.cast.slice(0, 8).join(", ")) : null,
      meta.director?.length ? h("p", { class: "dim small" }, "Regia: " + meta.director.join(", ")) : null, h("p", {}, fav))));

  const streamsBox = h("section", {});
  const videos = (meta.videos ?? []).filter((v) => v.id);
  const isSeries = videos.length > 1 || meta.type === "series";
  if (!isSeries || !videos.length) {
    root.appendChild(streamsBox);
    void streamsSection(streamsBox, meta, meta.id, meta.name, t);
    return;
  }
  const bySeason = new Map<number, Video[]>();
  videos.forEach((v) => { const s = v.season ?? 1; bySeason.set(s, [...(bySeason.get(s) ?? []), v]); });
  const seasons = [...bySeason.keys()].sort((a, b) => (a === 0 ? 99 : a) - (b === 0 ? 99 : b));
  const last = recentProgress(200).filter((p) => p.meta.id === meta.id)[0];
  const lastSeason = last ? videos.find((v) => v.id === last.videoId)?.season : undefined;
  let season = lastSeason ?? seasons.find((s) => s !== 0) ?? seasons[0];
  const select = h("select", { "aria-label": "Stagione" }) as HTMLSelectElement;
  seasons.forEach((s) => select.appendChild(h("option", { value: String(s) }, s === 0 ? "Speciali" : `Stagione ${s}`)));
  select.value = String(season);
  const list = h("div", { class: "list" });
  const paint = () => {
    clear(list);
    [...(bySeason.get(season) ?? [])].sort((a, b) => (a.episode ?? a.number ?? 0) - (b.episode ?? b.number ?? 0)).forEach((video) => {
      const watched = store.progress()[progressKey(meta.id, video.id)];
      const button = h("button", { class: "ep" }, h("span", {}, videoLabel(video)), watched && watched.duration ? h("span", { class: "dim small" }, `${Math.round(100 * watched.position / watched.duration)}%`) : null);
      button.addEventListener("click", () => {
        list.querySelectorAll(".ep.on").forEach((e) => e.classList.remove("on"));
        button.classList.add("on");
        clear(streamsBox);
        void streamsSection(streamsBox, meta, video.id, `${meta.name} · ${videoLabel(video)}`, t);
        streamsBox.scrollIntoView({ behavior: "smooth", block: "start" });
      });
      list.appendChild(button);
    });
  };
  select.addEventListener("change", () => { season = Number(select.value); paint(); });
  paint();
  root.append(h("h2", {}, "Episodi"), h("p", {}, select), list, streamsBox);
  if (last && videos.some((v) => v.id === last.videoId)) {
    streamsBox.appendChild(h("p", { class: "dim small" }, "Ultimo episodio guardato: " + (last.title ?? last.videoId)));
  }
}

// ---------- Streams ----------
async function streamsSection(box: HTMLElement, meta: Meta, videoId: string, title: string, t: number): Promise<void> {
  box.appendChild(h("h2", {}, "Fonti"));
  const list = h("div", { class: "list" });
  const status = h("div", {}, spinner("Cerco le fonti negli addon…"));
  box.append(list, status);
  const items: StreamItem[] = [];
  const providers = state.addons.filter((a) => supports(a.manifest, "stream", meta.type, videoId));
  if (!providers.length) { clear(status); status.appendChild(h("p", { class: "dim" }, "Nessun addon installato offre fonti per questo titolo.")); return; }
  const errors: string[] = [];
  let pending = providers.length;
  const paint = () => {
    clear(list);
    sortStreams(items).forEach((item) => list.appendChild(streamRow(item, meta, videoId, title)));
  };
  providers.forEach((addon) => {
    fetchJson<{ streams?: RawStream[] }>(resourceUrl(addon, "stream", meta.type, videoId), 20000).then((data) => {
      if (!alive(t)) return;
      (data.streams ?? []).forEach((raw) => items.push(describeStream(raw, addon.manifest.name, location.protocol === "https:")));
      paint();
    }).catch((error: Error) => errors.push(`${addon.manifest.name}: ${error.message}`)).finally(() => {
      pending -= 1;
      if (!alive(t)) return;
      if (pending === 0) {
        clear(status);
        if (!items.length) status.appendChild(h("p", { class: "dim" }, "Nessuna fonte trovata."));
        errors.forEach((e) => status.appendChild(h("p", { class: "dim small" }, e)));
      } else { clear(status); status.appendChild(spinner(`Cerco le fonti… (${pending} addon in attesa)`)); }
    });
  });
}

function streamRow(item: StreamItem, meta: Meta, videoId: string, title: string): HTMLElement {
  const badges = h("div", { class: "chips" });
  item.badges.forEach((b, i) => badges.appendChild(h("span", { class: i === 0 && item.quality ? "chip q" : "chip" }, b)));
  const size = formatSize(item.sizeBytes);
  if (size) badges.appendChild(h("span", { class: "chip" }, size));
  const actions = h("div", { class: "actions" });
  if (item.kind === "url" && item.playback !== "no") {
    actions.appendChild(h("button", { class: item.playback === "yes" ? "btn primary" : "btn", onclick: () => startPlayback(item, meta, videoId, title) }, item.playback === "yes" ? "▶ Riproduci" : "▶ Prova nel browser"));
  }
  if (item.kind === "url" && item.link) {
    actions.appendChild(externalButton(item.link));
    actions.appendChild(h("button", { class: "btn", onclick: async () => toast((await copyText(item.link!)) ? "Link copiato" : "Copia non riuscita") }, "Copia il link"));
  } else if (item.link && item.kind === "torrent") {
    actions.appendChild(h("button", { class: "btn", onclick: async () => toast((await copyText(item.link!)) ? "Magnet copiato" : "Copia non riuscita") }, "Copia il magnet"));
  } else if (item.link) {
    actions.appendChild(h("a", { class: "btn", href: item.link, target: "_blank", rel: "noopener noreferrer" }, "Apri"));
  }
  return h("div", { class: "item" },
    h("div", { class: "top" }, h("div", {}, h("h3", {}, item.label), item.detail ? h("div", { class: "dim small" }, item.detail) : null), h("span", { class: "dim small" }, item.addon)),
    badges, item.note ? h("div", { class: "note" }, item.note) : null, actions);
}

function externalButton(link: string): HTMLElement {
  const settings = store.settings();
  const select = h("select", { "aria-label": "Lettore esterno" }) as HTMLSelectElement;
  EXTERNAL_PLAYERS.forEach((p) => select.appendChild(h("option", { value: p.id }, `${p.title} (${p.platform})`)));
  select.value = settings.external;
  const open = h("button", { class: "btn" }, "Apri nel lettore");
  open.addEventListener("click", () => {
    const id = select.value as ExternalId;
    const address = externalLink(id, link);
    if (!address) { toast("Questo link non si può aprire in un lettore esterno."); return; }
    store.setSettings({ ...store.settings(), external: id });
    window.location.href = address;
  });
  const playlist = h("button", { class: "btn" }, "Playlist (.m3u)");
  playlist.addEventListener("click", () => {
    const blob = new Blob([m3uFor("Aether Web", link)], { type: "audio/x-mpegurl" });
    const a = h("a", { href: URL.createObjectURL(blob), download: "aether.m3u" });
    document.body.appendChild(a); a.click(); a.remove();
  });
  return h("span", { class: "actions" }, select, open, playlist);
}

function startPlayback(item: StreamItem, meta: Meta, videoId: string, title: string): void {
  try {
    sessionStorage.setItem("aether.web.current", JSON.stringify({ meta: { id: meta.id, type: meta.type, name: meta.name, poster: meta.poster, releaseInfo: meta.releaseInfo }, videoId, title, url: item.link, label: item.label }));
  } catch { toast("Il browser non permette di aprire il player."); return; }
  window.location.hash = `#/play/${enc(meta.type)}/${enc(meta.id)}/${enc(videoId)}`;
}

// ---------- Player ----------
interface Current { meta: MetaPreview; videoId: string; title: string; url: string; label: string }

export async function playerView(root: Root, params: string[]): Promise<void> {
  const t = begin(root);
  let current: Current | null = null;
  try { current = JSON.parse(sessionStorage.getItem("aether.web.current") ?? "null") as Current | null; } catch { current = null; }
  const type = dec(params[0] ?? ""), videoId = dec(params[2] ?? "");
  if (!current || current.videoId !== videoId || !current.url) {
    root.appendChild(h("p", { class: "dim" }, "La sorgente non è più disponibile: torna alla scheda del titolo e sceglila di nuovo. ", h("a", { class: "btn", href: `#/meta/${enc(type)}/${enc(dec(params[1] ?? ""))}` }, "Torna al titolo")));
    return;
  }
  const now = current;
  root.appendChild(h("p", {}, h("a", { class: "btn", href: `#/meta/${enc(now.meta.type)}/${enc(now.meta.id)}` }, "← Indietro")));
  root.appendChild(h("h1", {}, now.title));
  const video = h("video", { class: "player", controls: true, playsinline: true, preload: "metadata", crossorigin: "anonymous" }) as HTMLVideoElement;
  const status = h("p", { class: "note" });
  root.appendChild(video);
  root.appendChild(status);
  let hls: Hls | null = null;
  const isHls = /\.m3u8(\?|$)/i.test(now.url);
  const failed = (message: string) => { status.textContent = message; };
  video.addEventListener("error", () => failed("Il browser non riesce a riprodurre questa sorgente (formato, codec o accesso non consentito). Prova un lettore esterno qui sotto."));
  if (isHls && Hls.isSupported()) {
    hls = new Hls();
    hls.on(Hls.Events.ERROR, (_event, data) => { if (data.fatal) failed("Flusso HLS non riproducibile dal browser. Prova un lettore esterno."); });
    hls.loadSource(now.url);
    hls.attachMedia(video);
  } else {
    video.src = now.url;
  }
  const resume = store.settings().autoResume ? store.progress()[progressKey(now.meta.id, now.videoId)] : undefined;
  video.addEventListener("loadedmetadata", () => {
    if (resume && resume.position > 20 && resume.position < video.duration - 30) video.currentTime = resume.position;
  }, { once: true });
  let lastSave = 0;
  const save = () => {
    if (!video.duration || !isFinite(video.duration)) return;
    saveProgress({ meta: now.meta, videoId: now.videoId, title: now.title, position: video.currentTime, duration: video.duration, at: Date.now() });
  };
  video.addEventListener("timeupdate", () => { if (Date.now() - lastSave > 5000) { lastSave = Date.now(); save(); } });
  video.addEventListener("pause", save);
  window.addEventListener("hashchange", () => { save(); hls?.destroy(); video.removeAttribute("src"); video.load(); }, { once: true });

  root.appendChild(h("div", { class: "actions", style: "margin-top:12px" }, externalButton(now.url),
    h("button", { class: "btn", onclick: async () => toast((await copyText(now.url)) ? "Link copiato" : "Copia non riuscita") }, "Copia il link")));

  // Subtitles from the addons that offer them (they need to allow the browser to read the file).
  const subs = h("div", { class: "actions", style: "margin-top:12px" });
  root.appendChild(subs);
  const providers = state.addons.filter((a) => supports(a.manifest, "subtitles", type, videoId));
  if (providers.length) {
    const found: { url: string; lang: string; from: string }[] = [];
    await Promise.allSettled(providers.map(async (addon) => {
      const data = await fetchJson<{ subtitles?: { url: string; lang: string }[] }>(resourceUrl(addon, "subtitles", type, videoId), 15000);
      (data.subtitles ?? []).forEach((s) => { if (s.url) found.push({ url: s.url, lang: s.lang ?? "?", from: addon.manifest.name }); });
    }));
    if (!alive(t)) return;
    const order = (lang: string) => (/^(ita|it)/i.test(lang) ? 0 : /^(eng|en)/i.test(lang) ? 1 : 2);
    found.sort((a, b) => order(a.lang) - order(b.lang));
    if (found.length) {
      const select = h("select", { "aria-label": "Sottotitoli" }) as HTMLSelectElement;
      select.appendChild(h("option", { value: "-1" }, "Sottotitoli: nessuno"));
      found.slice(0, 12).forEach((s, i) => select.appendChild(h("option", { value: String(i) }, `${s.lang} · ${s.from}`)));
      select.addEventListener("change", async () => {
        video.querySelectorAll("track").forEach((tr) => tr.remove());
        const index = Number(select.value);
        if (index < 0) return;
        try {
          const response = await fetch(found[index].url);
          if (!response.ok) throw new Error(String(response.status));
          const url = URL.createObjectURL(new Blob([srtToVtt(await response.text())], { type: "text/vtt" }));
          const track = h("track", { kind: "subtitles", label: found[index].lang, srclang: found[index].lang.slice(0, 2), src: url, default: true });
          video.appendChild(track);
          track.track.mode = "showing";
        } catch { toast("Questo sottotitolo non si può leggere dal browser."); select.value = "-1"; }
      });
      subs.appendChild(select);
    }
  }
}

// ---------- Library ----------
export async function libraryView(root: Root): Promise<void> {
  begin(root);
  root.appendChild(h("h1", {}, "Libreria"));
  const favorites = store.favorites();
  root.appendChild(h("h2", {}, "Preferiti"));
  root.appendChild(favorites.length ? h("div", { class: "grid" }, ...favorites.map((m) => card(m))) : h("p", { class: "dim" }, "Nessun preferito: aggiungili dalla scheda di un titolo."));
  const history = recentProgress(60);
  root.appendChild(h("h2", {}, "Cronologia"));
  if (!history.length) { root.appendChild(h("p", { class: "dim" }, "Niente ancora.")); return; }
  const clearButton = h("button", { class: "btn danger", onclick: () => { if (confirm("Cancellare la cronologia?")) { store.setProgress({}); void libraryView(root); } } }, "Cancella la cronologia");
  root.appendChild(h("div", { class: "grid" }, ...history.map((p) => card(p.meta, { progress: p.position / p.duration }))));
  root.appendChild(h("p", {}, clearButton));
}

// ---------- Addons ----------
export async function addonsView(root: Root): Promise<void> {
  begin(root);
  root.appendChild(h("h1", {}, "Addon"));
  const input = h("input", { type: "text", placeholder: "Incolla il link del manifest (https://…/manifest.json)", style: "flex:1;min-width:220px", autocapitalize: "off", autocomplete: "off" }) as HTMLInputElement;
  const message = h("p", { class: "dim small" });
  const install = h("button", { class: "btn primary" }, "Installa") as HTMLButtonElement;
  const run = async () => {
    install.disabled = true; message.textContent = "Leggo il manifest…"; message.className = "dim small";
    try {
      const addon = await loadManifest(input.value);
      if (state.addons.some((a) => a.url === addon.url)) { message.textContent = "Questo addon è già installato."; return; }
      state.addons.push(addon); saveAddons(); input.value = "";
      toast(`Installato: ${addon.manifest.name}`);
      void addonsView(root);
    } catch (error) { message.className = "err small"; message.textContent = (error as Error).message; } finally { install.disabled = false; }
  };
  install.addEventListener("click", run);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") void run(); });
  root.append(h("div", { class: "actions" }, input, install), message);
  root.appendChild(h("p", { class: "dim small" }, "Gli addon sono servizi di terze parti che scegli tu. Alcuni vanno configurati sul loro sito (per esempio con TorBox o Real-Debrid) prima di copiare il link del manifest. Un addon che non permette l'accesso dal browser (CORS) non funziona qui."));

  const list = h("div", { class: "list" });
  state.addons.forEach((addon, index) => {
    const m = addon.manifest;
    const move = (delta: number) => { const j = index + delta; if (j < 0 || j >= state.addons.length) return; [state.addons[index], state.addons[j]] = [state.addons[j], state.addons[index]]; saveAddons(); void addonsView(root); };
    const res = [...new Set(m.resources.map((r) => (typeof r === "string" ? r : r.name)))];
    list.appendChild(h("div", { class: "item" },
      h("div", { class: "top" }, h("div", {}, h("h3", {}, `${m.name}${m.version ? " " + m.version : ""}`), m.description ? h("div", { class: "dim small" }, m.description) : null),
        h("span", { class: "dim small" }, `${m.catalogs.length} cataloghi`)),
      h("div", { class: "chips" }, ...res.map((r) => h("span", { class: "chip" }, r))),
      h("div", { class: "dim small" }, addon.url.replace(/\/[A-Za-z0-9_%-]{24,}.*$/, "/…")),
      h("div", { class: "actions" },
        h("button", { class: "btn", onclick: () => move(-1) }, "↑"), h("button", { class: "btn", onclick: () => move(1) }, "↓"),
        m.behaviorHints?.configurable ? h("a", { class: "btn", href: addon.url + "/configure", target: "_blank", rel: "noopener noreferrer" }, "Configura") : null,
        h("button", { class: "btn danger", onclick: () => { if (confirm(`Rimuovere «${m.name}»?`)) { state.addons.splice(index, 1); saveAddons(); void addonsView(root); } } }, "Rimuovi"))));
  });
  root.appendChild(list);
}

// ---------- Settings ----------
export async function settingsView(root: Root, lock: () => void): Promise<void> {
  begin(root);
  root.appendChild(h("h1", {}, "Impostazioni"));
  const settings = store.settings();
  const external = h("select", { "aria-label": "Lettore esterno predefinito" }) as HTMLSelectElement;
  EXTERNAL_PLAYERS.forEach((p) => external.appendChild(h("option", { value: p.id }, `${p.title} (${p.platform})`)));
  external.value = settings.external;
  external.addEventListener("change", () => store.setSettings({ ...store.settings(), external: external.value as ExternalId }));
  const resume = h("input", { type: "checkbox" }) as HTMLInputElement;
  resume.checked = settings.autoResume;
  resume.addEventListener("change", () => store.setSettings({ ...store.settings(), autoResume: resume.checked }));
  root.append(
    h("div", { class: "item" }, h("h3", {}, "Lettore esterno predefinito"), h("p", { class: "dim small" }, "Quello proposto per primo accanto a ogni fonte."), external),
    h("div", { class: "item", style: "margin-top:8px" }, h("label", {}, resume, " Riprendi da dove ero")),
    h("div", { class: "item", style: "margin-top:8px" }, h("h3", {}, "Dati"), h("p", { class: "dim small" }, "Addon, preferiti e cronologia stanno solo in questo browser. Nessun dato lascia il tuo dispositivo, tranne le richieste agli addon che installi."),
      h("div", { class: "actions" },
        h("button", { class: "btn", onclick: lock }, "Blocca (esci)"),
        h("button", { class: "btn danger", onclick: () => { if (confirm("Cancellare addon, preferiti e cronologia di questo browser?")) { ["addons", "favorites", "progress", "settings"].forEach((k) => localStorage.removeItem("aether.web." + k)); location.reload(); } } }, "Cancella tutti i dati"))),
    h("p", { class: "dim small" }, "Aether Web · versione semplificata: addon, cataloghi, riproduzione e lettori esterni. MKV, DTS e molti HEVC non si riproducono nel browser: usa un lettore esterno."));
}
