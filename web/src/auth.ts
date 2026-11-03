// A password gate in front of the page. It is a polite lock, not a vault: the site is static, its files are public, and the page holds
// no secret (the viewer's addons live in the viewer's own browser). The password is checked against a salted PBKDF2 hash.
export interface AuthConfig { salt: string; hash: string; iterations: number }

const hex = (bytes: ArrayBuffer): string => Array.from(new Uint8Array(bytes)).map((b) => b.toString(16).padStart(2, "0")).join("");

export async function derive(password: string, salt: string, iterations: number): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new TextEncoder().encode(salt), iterations }, key, 256);
  return hex(bits);
}

export async function verify(password: string, config: AuthConfig): Promise<boolean> {
  if (!password) return false;
  return (await derive(password, config.salt, config.iterations)) === config.hash;
}
