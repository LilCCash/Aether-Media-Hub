#!/usr/bin/env python3
"""Publishes an Aether IPA to the rolling "devbuilds" release and adds it to the SideStore/AltStore source.

Run by the Build IPA workflow (GH_TOKEN, GH_REPO, SHA in the environment; the IPA is Aether-unsigned.ipa in the current folder).
The source is the release asset `source.json`; every build keeps its own asset `Aether-devbuild-<build>.ipa`.
"""
import json, os, plistlib, shutil, subprocess, sys, tempfile, zipfile
from datetime import datetime, timezone

TAG = "devbuilds"
IPA = sys.argv[1] if len(sys.argv) > 1 else "Aether-unsigned.ipa"
repo = os.environ["GH_REPO"]
sha = os.environ.get("SHA", "")
note = os.environ.get("NOTE", "")


def gh(*args, check=True):
    return subprocess.run(["gh", *args], check=check, capture_output=True, text=True)


with zipfile.ZipFile(IPA) as z:
    info = plistlib.loads(z.read("Payload/Aether.app/Info.plist"))
bundle_id = info["CFBundleIdentifier"]
marketing = info["CFBundleShortVersionString"]
build = str(info["CFBundleVersion"])
min_os = info.get("MinimumOSVersion", "17.0")
size = os.path.getsize(IPA)

work = tempfile.mkdtemp()
asset = os.path.join(work, f"Aether-devbuild-{build}.ipa")
shutil.copyfile(IPA, asset)

if os.environ.get("RESET_SOURCE") == "true":
    # Starts the source over: the release (and its tag) go, the next upload creates them again.
    gh("release", "delete", TAG, "--cleanup-tag", "--yes", check=False)

if gh("release", "view", TAG, check=False).returncode != 0:
    gh("release", "create", TAG, "--prerelease", "--title", "Aether devbuilds (SideStore)", "--target", sha or "main",
       "--notes", "Build di sviluppo non firmate per SideStore. Aggiungi la source: "
                  f"https://github.com/{repo}/releases/download/{TAG}/source.json")
gh("release", "upload", TAG, asset, "--clobber")

base = f"https://github.com/{repo}/releases/download/{TAG}"
source_path = os.path.join(work, "source.json")
gh("release", "download", TAG, "-p", "source.json", "-D", work, "--clobber", check=False)
try:
    with open(source_path) as handle:
        source = json.load(handle)
except Exception:
    source = {}

icon = f"https://raw.githubusercontent.com/{repo}/{sha or 'main'}/App/Aether/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
version = {
    # SideStore checks this against the version inside the IPA, so it is the real one; the build number tells the builds apart.
    "version": marketing,
    "buildVersion": build,
    "date": now,
    "downloadURL": f"{base}/Aether-devbuild-{build}.ipa",
    "size": size,
    "minOSVersion": str(min_os),
    "localizedDescription": f"devbuild · build {build}" + (f" · commit {sha[:7]}" if sha else "") + (f"\n{note}" if note else ""),
}

app = (source.get("apps") or [{}])[0]
versions = [v for v in app.get("versions", []) if str(v.get("buildVersion")) != build]
versions.append(version)
versions.sort(key=lambda v: int(str(v.get("buildVersion", "0")) or 0), reverse=True)
app.update({
    "name": "Aether",
    "bundleIdentifier": bundle_id,
    "developerName": "Aether",
    "subtitle": "Media hub",
    "localizedDescription": "Build di sviluppo di Aether, una per ogni compilazione: il numero di build è nella descrizione di ogni versione.",
    "iconURL": app.get("iconURL") or icon,
    "tintColor": "7C5CFF",
    "category": "entertainment",
    "screenshotURLs": [],
    "versions": versions,
    # Old readers look at these fields of the app instead of the list.
    "version": versions[0]["version"],
    "versionDate": versions[0]["date"],
    "downloadURL": versions[0]["downloadURL"],
    "size": versions[0]["size"],
    "versionDescription": versions[0]["localizedDescription"],
})
source.update({
    "name": "Aether",
    "identifier": f"{bundle_id}.devbuilds",
    "subtitle": "Tutte le build di Aether",
    "description": "Le build non firmate di Aether, con il numero di build.",
    "iconURL": app["iconURL"],
    "website": f"https://github.com/{repo}",
    "sourceURL": f"{base}/source.json",
    "apps": [app],
    "news": source.get("news", []),
})
with open(source_path, "w") as handle:
    json.dump(source, handle, indent=2, ensure_ascii=False)
gh("release", "upload", TAG, source_path, "--clobber")
print(f"Source: {base}/source.json — {len(versions)} build, ultima {build}")
