// Opening a video in another player: each app has its own address scheme (the same ones the Aether iPhone app uses).
export type ExternalId = "vlc" | "infuse" | "nplayer" | "outplayer" | "vlc-android" | "mx-android";

export const EXTERNAL_PLAYERS: { id: ExternalId; title: string; platform: string }[] = [
  { id: "vlc", title: "VLC", platform: "iPhone, iPad, Mac" },
  { id: "infuse", title: "Infuse", platform: "iPhone, iPad, Apple TV, Mac" },
  { id: "nplayer", title: "nPlayer", platform: "iPhone, iPad" },
  { id: "outplayer", title: "Outplayer", platform: "iPhone, iPad" },
  { id: "vlc-android", title: "VLC", platform: "Android" },
  { id: "mx-android", title: "MX Player", platform: "Android" },
];

const encode = (text: string) => encodeURIComponent(text);

export function externalLink(id: ExternalId, media: string): string | null {
  let url: URL;
  try { url = new URL(media); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  const intent = (pkg: string) => `intent://${url.host}${url.pathname}${url.search}#Intent;scheme=${url.protocol.slice(0, -1)};package=${pkg};type=video/*;end`;
  switch (id) {
    case "vlc": return `vlc-x-callback://x-callback-url/stream?url=${encode(media)}`;
    case "infuse": return `infuse://x-callback-url/play?url=${encode(media)}`;
    case "nplayer": return `nplayer-${media}`;
    case "outplayer": return `outplayer://${media}`;
    case "vlc-android": return intent("org.videolan.vlc");
    case "mx-android": return intent("com.mxtech.videoplayer.ad");
  }
}

/** A playlist file for players on a computer (VLC, mpv, IINA…): the browser cannot open them by address. */
export function m3uFor(title: string, media: string): string {
  return `#EXTM3U\n#EXTINF:-1,${title.replace(/[\r\n]+/g, " ")}\n${media}\n`;
}
