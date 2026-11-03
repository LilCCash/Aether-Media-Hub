import type { Addon, MetaPreview } from "./addons";
import type { ExternalId } from "./external";

// Everything is kept in this browser (localStorage). Reads and writes are wrapped: private windows and blocked storage must not break the page.
function read<T>(key: string, fallback: T): T {
  try { const raw = localStorage.getItem(key); return raw ? JSON.parse(raw) as T : fallback; } catch { return fallback; }
}
function write(key: string, value: unknown): void {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ }
}

export interface Progress { meta: MetaPreview; videoId: string; title?: string; position: number; duration: number; at: number }
export interface Settings { external: ExternalId; autoResume: boolean }

export const store = {
  addons: () => read<Addon[] | null>("aether.web.addons", null),
  setAddons: (list: Addon[]) => write("aether.web.addons", list),
  favorites: () => read<MetaPreview[]>("aether.web.favorites", []),
  setFavorites: (list: MetaPreview[]) => write("aether.web.favorites", list),
  progress: () => read<Record<string, Progress>>("aether.web.progress", {}),
  setProgress: (map: Record<string, Progress>) => write("aether.web.progress", map),
  settings: () => ({ external: "vlc", autoResume: true, ...read<Partial<Settings>>("aether.web.settings", {}) }) as Settings,
  setSettings: (s: Settings) => write("aether.web.settings", s),
};

export const progressKey = (metaId: string, videoId: string) => `${metaId}|${videoId}`;

export function saveProgress(entry: Progress): void {
  const map = store.progress();
  map[progressKey(entry.meta.id, entry.videoId)] = entry;
  // Keep the 200 most recent.
  const keys = Object.keys(map).sort((a, b) => map[b].at - map[a].at);
  for (const key of keys.slice(200)) delete map[key];
  store.setProgress(map);
}

export function recentProgress(limit = 20): Progress[] {
  return Object.values(store.progress())
    .filter((p) => p.duration > 0 && p.position / p.duration < 0.95 && p.position > 20)
    .sort((a, b) => b.at - a.at).slice(0, limit);
}

export function toggleFavorite(meta: MetaPreview): boolean {
  const list = store.favorites();
  const index = list.findIndex((m) => m.id === meta.id);
  if (index >= 0) { list.splice(index, 1); store.setFavorites(list); return false; }
  list.unshift({ id: meta.id, type: meta.type, name: meta.name, poster: meta.poster, releaseInfo: meta.releaseInfo });
  store.setFavorites(list);
  return true;
}
export const isFavorite = (id: string) => store.favorites().some((m) => m.id === id);
