import "./styles.css";
import authConfig from "./auth-config.json";
import { verify, type AuthConfig } from "./auth";
import { initAddons } from "./app";
import { clear, h } from "./dom";
import { addonsView, catalogView, homeView, libraryView, metaView, playerView, searchView, settingsView } from "./views";

const config = authConfig as AuthConfig;
const UNLOCK_KEY = "aether.web.unlocked";
const root = document.getElementById("app")!;

const isUnlocked = (): boolean => { try { return localStorage.getItem(UNLOCK_KEY) === config.hash; } catch { return false; } };
const lock = (): void => { try { localStorage.removeItem(UNLOCK_KEY); } catch { /* ignore */ } location.hash = "#/"; location.reload(); };

function gate(): void {
  clear(root);
  const input = h("input", { type: "password", placeholder: "Password", autocomplete: "current-password", "aria-label": "Password" }) as HTMLInputElement;
  const message = h("p", { class: "err small" });
  const button = h("button", { class: "btn primary", type: "submit" }, "Entra") as HTMLButtonElement;
  const form = h("form", { class: "gate" }, h("h1", {}, h("span", { class: "brand" }, "Aether ", h("span", {}, "Web"))), h("p", { class: "dim small" }, "Accesso riservato."), input, button, message);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    button.disabled = true; message.textContent = "";
    const ok = await verify(input.value, config).catch(() => false);
    if (ok) { try { localStorage.setItem(UNLOCK_KEY, config.hash); } catch { /* ignore */ } void start(); return; }
    message.textContent = "Password errata.";
    button.disabled = false; input.select();
  });
  root.appendChild(form);
  input.focus();
}

const TABS: [string, string, string][] = [["#/", "Home", "home"], ["#/library", "Libreria", "library"], ["#/addons", "Addon", "addons"], ["#/settings", "Impostazioni", "settings"]];

async function start(): Promise<void> {
  clear(root);
  await initAddons();
  const nav = h("nav", { class: "tabs" });
  const search = h("input", { type: "search", placeholder: "Cerca film e serie", "aria-label": "Cerca", enterkeyhint: "search" }) as HTMLInputElement;
  const form = h("form", { class: "search" }, search, h("button", { class: "btn", type: "submit" }, "Cerca"));
  form.addEventListener("submit", (event) => { event.preventDefault(); const q = search.value.trim(); if (q) location.hash = `#/search/${encodeURIComponent(q)}`; });
  root.appendChild(h("header", { class: "bar" }, h("a", { class: "brand", href: "#/" }, "Aether ", h("span", {}, "Web")), nav, form));
  const main = h("main", {});
  root.appendChild(main);

  async function route(): Promise<void> {
    const parts = location.hash.replace(/^#\/?/, "").split("/");
    const [name, ...params] = parts;
    clear(nav);
    TABS.forEach(([href, label, key]) => nav.appendChild(h("a", { href, class: (name || "home") === key ? "on" : "" }, label)));
    window.scrollTo(0, 0);
    switch (name) {
      case "": case "home": return homeView(main);
      case "catalog": return catalogView(main, params);
      case "search": return searchView(main, params);
      case "meta": return metaView(main, params);
      case "play": return playerView(main, params);
      case "library": return libraryView(main);
      case "addons": return addonsView(main);
      case "settings": return settingsView(main, lock);
      default: return homeView(main);
    }
  }
  window.addEventListener("hashchange", () => void route());
  await route();
}

if (import.meta.env.PROD && "serviceWorker" in navigator) {
  window.addEventListener("load", () => { navigator.serviceWorker.register("./sw.js").catch(() => undefined); });
}
if (isUnlocked()) void start(); else gate();
