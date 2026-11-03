export type Child = Node | string | number | null | undefined | false;

// Every address that reaches the page from outside goes through this filter: web addresses, relative links, and the schemes of the players.
const ALLOWED = /^(https?:|#|\.\/|\/|blob:|vlc-x-callback:|infuse:|nplayer-https?:|outplayer:|intent:|magnet:)/i;
export const safeUrl = (value: string): string | null => (ALLOWED.test(value.trim()) ? value.trim() : null);

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, unknown> = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value == null || value === false) continue;
    if (key === "class") el.className = String(value);
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value as EventListener);
    else if (key === "href" || key === "src" || key === "poster") { const safe = safeUrl(String(value)); if (safe) el.setAttribute(key, safe); }
    else if (value === true) el.setAttribute(key, "");
    else el.setAttribute(key, String(value));
  }
  append(el, children);
  return el;
}

export function append(parent: Node, children: Child[]): void {
  for (const child of children) {
    if (child == null || child === false) continue;
    parent.appendChild(typeof child === "object" ? child : document.createTextNode(String(child)));
  }
}

export function clear(el: Element): void { while (el.firstChild) el.removeChild(el.firstChild); }

export async function copyText(text: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(text); return true; } catch { /* fall back below */ }
  const area = h("textarea", { style: "position:fixed;opacity:0" });
  area.value = text;
  document.body.appendChild(area);
  area.select();
  let ok = false;
  try { ok = document.execCommand("copy"); } catch { ok = false; }
  area.remove();
  return ok;
}

let toastTimer: number | undefined;
export function toast(message: string): void {
  let box = document.getElementById("toast");
  if (!box) { box = h("div", { id: "toast", role: "status" }); document.body.appendChild(box); }
  box.textContent = message;
  box.classList.add("show");
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => box!.classList.remove("show"), 2600);
}

export function srtToVtt(text: string): string {
  return "WEBVTT\n\n" + text.replace(/\r+/g, "").replace(/(\d{2}:\d{2}:\d{2}),(\d{3})/g, "$1.$2");
}
