// Writes src/auth-config.json for a password:   node scripts/set-password.mjs "la password"
import { webcrypto, randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
const password = process.argv[2];
if (!password || password.length < 8) { console.error("Serve una password di almeno 8 caratteri."); process.exit(1); }
const salt = randomBytes(16).toString("hex");
const iterations = 210000;
const key = await webcrypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
const bits = await webcrypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new TextEncoder().encode(salt), iterations }, key, 256);
const hash = Array.from(new Uint8Array(bits)).map((b) => b.toString(16).padStart(2, "0")).join("");
writeFileSync(new URL("../src/auth-config.json", import.meta.url), JSON.stringify({ salt, hash, iterations }, null, 2) + "\n");
console.log("src/auth-config.json aggiornato.");
