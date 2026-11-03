import { DEFAULT_ADDONS, loadManifest, type Addon } from "./addons";
import { store } from "./store";

export const state: { addons: Addon[] } = { addons: [] };

/** The installed addons, or the first-run set (Cinemeta) when none was ever saved. */
export async function initAddons(): Promise<void> {
  const saved = store.addons();
  if (saved) { state.addons = saved; return; }
  const loaded: Addon[] = [];
  for (const url of DEFAULT_ADDONS) { try { loaded.push(await loadManifest(url)); } catch { /* offline at first start: none yet */ } }
  state.addons = loaded;
  if (loaded.length) store.setAddons(loaded);
}

export const saveAddons = (): void => store.setAddons(state.addons);
