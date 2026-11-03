export interface RawStream {
  url?: string; ytId?: string; infoHash?: string; fileIdx?: number; externalUrl?: string;
  name?: string; title?: string; description?: string;
  behaviorHints?: { filename?: string; videoSize?: number; notWebReady?: boolean; bingeGroup?: string };
}
export type StreamKind = "url" | "torrent" | "youtube" | "external" | "unknown";
export interface StreamItem {
  raw: RawStream; addon: string; kind: StreamKind;
  label: string; detail: string; badges: string[];
  quality: number; sizeBytes: number; link?: string;
  /** What the browser is likely to do with it. */
  playback: "yes" | "maybe" | "no";
  note?: string;
}

const UNSUPPORTED_EXT = ["mkv", "avi", "wmv", "flv", "ts", "m2ts", "iso", "rmvb"];
const WEB_EXT = ["mp4", "m4v", "webm", "mov", "m3u8", "mp3", "m4a"];

export function extensionOf(raw: RawStream): string {
  const name = raw.behaviorHints?.filename ?? "";
  const fromName = /\.([A-Za-z0-9]{2,5})$/.exec(name)?.[1];
  if (fromName) return fromName.toLowerCase();
  if (!raw.url) return "";
  try { return (/\.([A-Za-z0-9]{2,5})$/.exec(new URL(raw.url).pathname)?.[1] ?? "").toLowerCase(); } catch { return ""; }
}

export function qualityOf(text: string): number {
  if (/\b(2160p|4k|uhd)\b/i.test(text)) return 4;
  if (/\b1080p\b/i.test(text)) return 3;
  if (/\b720p\b/i.test(text)) return 2;
  if (/\b(480p|576p)\b/i.test(text)) return 1;
  return 0;
}

export function sizeOf(text: string, hint?: number): number {
  if (hint && hint > 0) return hint;
  const match = /(\d+(?:[.,]\d+)?)\s?(GB|MB|TB)\b/i.exec(text);
  if (!match) return 0;
  const value = parseFloat(match[1].replace(",", "."));
  const unit = match[2].toUpperCase();
  return Math.round(value * (unit === "TB" ? 1e12 : unit === "GB" ? 1e9 : 1e6));
}

export function formatSize(bytes: number): string {
  if (bytes <= 0) return "";
  return bytes >= 1e9 ? `${(bytes / 1e9).toFixed(bytes >= 1e11 ? 0 : 1)} GB` : `${Math.round(bytes / 1e6)} MB`;
}

export function badgesOf(text: string, ext: string): string[] {
  const out: string[] = [];
  const q = qualityOf(text);
  if (q) out.push(["", "480p", "720p", "1080p", "4K"][q]);
  if (/\b(hevc|x265|h\.?265)\b/i.test(text)) out.push("HEVC");
  else if (/\b(x264|h\.?264|avc)\b/i.test(text)) out.push("H.264");
  else if (/\bav1\b/i.test(text)) out.push("AV1");
  if (/\b(dolby[ .-]?vision|dv)\b/i.test(text)) out.push("Dolby Vision");
  else if (/\bhdr10\+?\b|\bhdr\b/i.test(text)) out.push("HDR");
  if (/\b(atmos)\b/i.test(text)) out.push("Atmos");
  else if (/\b(dts[- ]?(hd|x)?|truehd)\b/i.test(text)) out.push("DTS/TrueHD");
  if (/\b(ita|italian)\b|🇮🇹/i.test(text)) out.push("ITA");
  if (ext) out.push(ext.toUpperCase());
  return Array.from(new Set(out));
}

/** `httpsPage`: the page itself is served over https, so the browser blocks plain-http media in it (mixed content). */
export function describeStream(raw: RawStream, addon: string, httpsPage = true): StreamItem {
  const text = [raw.name, raw.title, raw.description, raw.behaviorHints?.filename].filter(Boolean).join(" ");
  const ext = extensionOf(raw);
  let kind: StreamKind = "unknown";
  if (raw.url) kind = "url";
  else if (raw.infoHash) kind = "torrent";
  else if (raw.ytId) kind = "youtube";
  else if (raw.externalUrl) kind = "external";
  let playback: StreamItem["playback"] = "no";
  let note: string | undefined;
  let link: string | undefined;
  if (kind === "url") {
    link = raw.url;
    if (httpsPage && raw.url!.startsWith("http://")) { playback = "no"; note = "Indirizzo non cifrato (http): il browser lo blocca in una pagina https. Usa un lettore esterno."; }
    else if (raw.behaviorHints?.notWebReady) { playback = "maybe"; note = "L'addon dice che non è pronto per il web: può non partire."; }
    else if (UNSUPPORTED_EXT.includes(ext)) { playback = "maybe"; note = `Il formato ${ext.toUpperCase()} spesso non si riproduce nel browser: prova un lettore esterno.`; }
    else if (WEB_EXT.includes(ext) || ext === "") playback = "yes";
    else playback = "maybe";
  } else if (kind === "torrent" && raw.infoHash) {
    link = `magnet:?xt=urn:btih:${raw.infoHash}`;
    note = "Torrent: il browser non lo può riprodurre. Usa un addon configurato con TorBox o Real-Debrid, che restituisce un link diretto.";
  } else if (kind === "youtube") {
    link = `https://www.youtube.com/watch?v=${raw.ytId}`;
    note = "Video di YouTube: si apre sul sito.";
  } else if (kind === "external") {
    link = raw.externalUrl;
    note = "Si apre in una pagina esterna.";
  }
  const first = (raw.title ?? raw.description ?? "").split("\n")[0].trim();
  const label = (raw.name ?? "").replace(/\s+/g, " ").trim() || addon;
  return { raw, addon, kind, label, detail: first, badges: badgesOf(text, ext), quality: qualityOf(text), sizeBytes: sizeOf(text, raw.behaviorHints?.videoSize), link, playback, note };
}

/** Best first: what plays in the browser, then resolution, then size. */
export function sortStreams(items: StreamItem[]): StreamItem[] {
  const rank = { yes: 0, maybe: 1, no: 2 } as const;
  return [...items].sort((a, b) => rank[a.playback] - rank[b.playback] || b.quality - a.quality || b.sizeBytes - a.sizeBytes);
}
