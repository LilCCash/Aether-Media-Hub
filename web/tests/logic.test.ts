import { describe, expect, it } from "vitest";
import { baseUrl, catalogUrl, encodeExtra, genreRequired, isPlainFeed, isSearchCatalog, resourceUrl, supports, type Addon, type Manifest } from "../src/addons";
import { describeStream, formatSize, sortStreams } from "../src/streams";
import { externalLink, m3uFor } from "../src/external";
import { derive, verify } from "../src/auth";

const manifest: Manifest = {
  id: "x", name: "X", types: ["movie", "series"], idPrefixes: ["tt"],
  resources: ["catalog", { name: "stream", types: ["movie"], idPrefixes: ["tt"] }, { name: "meta", types: ["series"] }],
  catalogs: [
    { type: "movie", id: "top", extra: [{ name: "genre", options: ["Azione"] }, { name: "skip" }] },
    { type: "tv", id: "live", extra: [{ name: "genre", isRequired: true }] },
    { type: "movie", id: "search", extra: [{ name: "search", isRequired: true }] },
  ],
};
const addon: Addon = { url: "https://a.example/cfg", manifest };

describe("addons", () => {
  it("normalises the pasted address", () => {
    expect(baseUrl("https://a.example/cfg/manifest.json")).toBe("https://a.example/cfg");
    expect(baseUrl("stremio://a.example/cfg/manifest.json")).toBe("https://a.example/cfg");
    expect(baseUrl("  https://a.example/ ")).toBe("https://a.example");
    expect(baseUrl("ftp://a.example")).toBeNull();
    expect(baseUrl("not a url")).toBeNull();
    expect(baseUrl("")).toBeNull();
  });
  it("writes catalog and resource addresses as the protocol does", () => {
    expect(catalogUrl(addon, manifest.catalogs[0])).toBe("https://a.example/cfg/catalog/movie/top.json");
    expect(catalogUrl(addon, manifest.catalogs[0], { genre: "Azione e avventura", skip: "20" }))
      .toBe("https://a.example/cfg/catalog/movie/top/genre=Azione%20e%20avventura&skip=20.json");
    expect(resourceUrl(addon, "stream", "series", "tt1:1:2")).toBe("https://a.example/cfg/stream/series/tt1%3A1%3A2.json");
    expect(encodeExtra({ search: "toy story", genre: "" })).toBe("search=toy%20story");
  });
  it("knows what an addon supports", () => {
    expect(supports(manifest, "stream", "movie", "tt1")).toBe(true);
    expect(supports(manifest, "stream", "series", "tt1")).toBe(false);
    expect(supports(manifest, "stream", "movie", "kitsu:1")).toBe(false);
    expect(supports(manifest, "meta", "series", "tt9")).toBe(true);
    expect(supports(manifest, "subtitles", "movie", "tt1")).toBe(false);
  });
  it("tells feeds, searches and required genres apart", () => {
    expect(isPlainFeed(manifest.catalogs[0])).toBe(true);
    expect(isPlainFeed(manifest.catalogs[1])).toBe(false);
    expect(genreRequired(manifest.catalogs[1])).toBe(true);
    expect(isSearchCatalog(manifest.catalogs[2])).toBe(true);
    expect(isSearchCatalog(manifest.catalogs[0])).toBe(false);
  });
});

describe("streams", () => {
  it("reads quality, size and badges from the text of a source", () => {
    const item = describeStream({ url: "https://cdn.example/f.mp4", name: "Torrentio\n4K HDR", title: "Film.2023.2160p.HDR.HEVC.ITA.12.5 GB" }, "Torrentio");
    expect(item.quality).toBe(4);
    expect(item.badges).toEqual(expect.arrayContaining(["4K", "HEVC", "HDR", "ITA", "MP4"]));
    expect(formatSize(item.sizeBytes)).toBe("12.5 GB");
    expect(item.playback).toBe("yes");
  });
  it("says honestly what the browser will do", () => {
    expect(describeStream({ url: "https://x.example/a.mkv" }, "a").playback).toBe("maybe");
    expect(describeStream({ url: "http://x.example/a.mp4" }, "a").playback).toBe("no");
    expect(describeStream({ url: "https://x.example/a.mp4", behaviorHints: { notWebReady: true } }, "a").playback).toBe("maybe");
    const torrent = describeStream({ infoHash: "abc123" }, "a");
    expect(torrent.kind).toBe("torrent");
    expect(torrent.link).toBe("magnet:?xt=urn:btih:abc123");
    expect(torrent.playback).toBe("no");
  });
  it("puts what plays first, then the best picture", () => {
    const list = sortStreams([
      describeStream({ url: "https://x.example/a.mkv", name: "1080p" }, "a"),
      describeStream({ url: "https://x.example/b.mp4", name: "720p" }, "b"),
      describeStream({ url: "https://x.example/c.mp4", name: "1080p" }, "c"),
    ]);
    expect(list.map((i) => i.addon)).toEqual(["c", "b", "a"]);
  });
});

describe("external players", () => {
  const media = "https://cdn.example/a b.mp4?token=1&x=2";
  it("builds the address of each player", () => {
    expect(externalLink("vlc", media)).toBe(`vlc-x-callback://x-callback-url/stream?url=${encodeURIComponent(media)}`);
    expect(externalLink("infuse", media)).toContain("infuse://x-callback-url/play?url=");
    expect(externalLink("nplayer", "https://a.example/v.mp4")).toBe("nplayer-https://a.example/v.mp4");
    expect(externalLink("outplayer", "https://a.example/v.mp4")).toBe("outplayer://https://a.example/v.mp4");
    expect(externalLink("vlc-android", "https://a.example/v.mp4?x=1")).toBe("intent://a.example/v.mp4?x=1#Intent;scheme=https;package=org.videolan.vlc;type=video/*;end");
  });
  it("refuses what is not a web address", () => {
    expect(externalLink("vlc", "magnet:?xt=urn:btih:abc")).toBeNull();
    expect(externalLink("vlc", "nonsense")).toBeNull();
  });
  it("writes a playlist", () => {
    expect(m3uFor("Film\nX", "https://a.example/v.mp4")).toBe("#EXTM3U\n#EXTINF:-1,Film X\nhttps://a.example/v.mp4\n");
  });
});

describe("password", () => {
  it("accepts the right password and only that", async () => {
    const hash = await derive("giusta-1234", "sale", 1000);
    const config = { salt: "sale", hash, iterations: 1000 };
    expect(await verify("giusta-1234", config)).toBe(true);
    expect(await verify("sbagliata", config)).toBe(false);
    expect(await verify("", config)).toBe(false);
  });
});

describe("mixed content", () => {
  it("only blocks plain http when the page itself is https", () => {
    expect(describeStream({ url: "http://x.example/a.mp4" }, "a", true).playback).toBe("no");
    expect(describeStream({ url: "http://x.example/a.mp4" }, "a", false).playback).toBe("yes");
  });
});
