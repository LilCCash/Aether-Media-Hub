// The Stremio addon protocol (https://github.com/Stremio/stremio-addon-sdk): a manifest and JSON resources at predictable addresses.
export interface ExtraDef { name: string; isRequired?: boolean; options?: string[] }
export interface CatalogDef { type: string; id: string; name?: string; extra?: ExtraDef[]; extraRequired?: string[]; extraSupported?: string[] }
export interface ResourceDef { name: string; types?: string[]; idPrefixes?: string[] }
export interface Manifest {
  id: string; name: string; version?: string; description?: string; logo?: string;
  resources: (string | ResourceDef)[]; types: string[]; idPrefixes?: string[]; catalogs: CatalogDef[];
  behaviorHints?: { configurable?: boolean; configurationRequired?: boolean };
}
/** An installed addon: `url` is its base address (without /manifest.json). */
export interface Addon { url: string; manifest: Manifest }

export interface MetaPreview { id: string; type: string; name: string; poster?: string; background?: string; logo?: string; description?: string; releaseInfo?: string; imdbRating?: string }
export interface Video { id: string; title?: string; name?: string; season?: number; episode?: number; number?: number; released?: string; thumbnail?: string; overview?: string }
export interface Meta extends MetaPreview { genres?: string[]; cast?: string[]; director?: string[]; runtime?: string; videos?: Video[]; year?: string }

/** The base address of an addon from what the viewer pasted (manifest address, stremio:// link, or the base itself). */
export function baseUrl(input: string): string | null {
  let text = input.trim();
  if (!text) return null;
  if (text.startsWith("stremio://")) text = "https://" + text.slice("stremio://".length);
  let url: URL;
  try { url = new URL(text); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  let path = url.pathname.replace(/\/manifest\.json$/i, "").replace(/\/+$/, "");
  return url.origin + path + (path === "" ? "" : "");
}

export const manifestUrl = (base: string): string => base + "/manifest.json";

/** `genre=Action&skip=20`, each value percent-encoded, as the protocol writes the extra properties. */
export function encodeExtra(extra: Record<string, string>): string {
  return Object.entries(extra).filter(([, v]) => v !== "" && v != null).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

export function catalogUrl(addon: Addon, catalog: CatalogDef, extra: Record<string, string> = {}): string {
  const tail = encodeExtra(extra);
  return `${addon.url}/catalog/${encodeURIComponent(catalog.type)}/${encodeURIComponent(catalog.id)}${tail ? "/" + tail : ""}.json`;
}

export function resourceUrl(addon: Addon, resource: string, type: string, id: string, extra: Record<string, string> = {}): string {
  const tail = encodeExtra(extra);
  return `${addon.url}/${resource}/${encodeURIComponent(type)}/${encodeURIComponent(id)}${tail ? "/" + tail : ""}.json`;
}

/** The resources of a manifest in one shape, each with the types and id prefixes it applies to. */
export function resources(manifest: Manifest): ResourceDef[] {
  return (manifest.resources ?? []).map((entry) => typeof entry === "string"
    ? { name: entry, types: manifest.types, idPrefixes: manifest.idPrefixes }
    : { name: entry.name, types: entry.types ?? manifest.types, idPrefixes: entry.idPrefixes ?? manifest.idPrefixes });
}

export function supports(manifest: Manifest, resource: string, type: string, id: string): boolean {
  return resources(manifest).some((r) => r.name === resource
    && (!r.types || r.types.includes(type))
    && (!r.idPrefixes || r.idPrefixes.length === 0 || r.idPrefixes.some((prefix) => id.startsWith(prefix))));
}

export function requiredExtras(catalog: CatalogDef): string[] {
  const fromList = (catalog.extra ?? []).filter((e) => e.isRequired).map((e) => e.name);
  return Array.from(new Set([...(catalog.extraRequired ?? []), ...fromList]));
}

export const isSearchCatalog = (catalog: CatalogDef): boolean => (catalog.extra ?? []).some((e) => e.name === "search") || (catalog.extraSupported ?? []).includes("search");
export const searchRequired = (catalog: CatalogDef): boolean => requiredExtras(catalog).includes("search");
/** A catalog that lists titles without being asked anything (no required extra): what the Home shows. */
export const isPlainFeed = (catalog: CatalogDef): boolean => requiredExtras(catalog).length === 0;
export const genresOf = (catalog: CatalogDef): string[] => (catalog.extra ?? []).find((e) => e.name === "genre")?.options ?? [];
export const genreRequired = (catalog: CatalogDef): boolean => requiredExtras(catalog).includes("genre");

export class AddonError extends Error {}

export async function fetchJson<T>(url: string, timeoutMs = 12000): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal, headers: { Accept: "application/json" } });
    if (!response.ok) throw new AddonError(`Risposta ${response.status} da ${new URL(url).host}`);
    return await response.json() as T;
  } catch (error) {
    if (error instanceof AddonError) throw error;
    if ((error as Error).name === "AbortError") throw new AddonError(`${new URL(url).host} non risponde`);
    throw new AddonError(`Impossibile leggere ${new URL(url).host} (se l'addon non permette l'accesso dal browser, è un blocco CORS)`);
  } finally {
    clearTimeout(timer);
  }
}

export async function loadManifest(input: string): Promise<Addon> {
  const base = baseUrl(input);
  if (!base) throw new AddonError("Indirizzo non valido: incolla il link del manifest dell'addon.");
  const manifest = await fetchJson<Manifest>(manifestUrl(base));
  if (!manifest || typeof manifest.id !== "string" || typeof manifest.name !== "string" || !Array.isArray(manifest.resources)) {
    throw new AddonError("Questo indirizzo non è un addon Stremio (manifest non valido).");
  }
  manifest.catalogs = Array.isArray(manifest.catalogs) ? manifest.catalogs : [];
  manifest.types = Array.isArray(manifest.types) ? manifest.types : [];
  return { url: base, manifest };
}

export async function fetchCatalog(addon: Addon, catalog: CatalogDef, extra: Record<string, string> = {}): Promise<MetaPreview[]> {
  const data = await fetchJson<{ metas?: MetaPreview[] }>(catalogUrl(addon, catalog, extra));
  return (data.metas ?? []).filter((m) => m && typeof m.id === "string" && typeof m.name === "string");
}

export const DEFAULT_ADDONS = ["https://v3-cinemeta.strem.io"];
