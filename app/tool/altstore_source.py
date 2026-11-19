#!/usr/bin/env python3
"""Write an AltStore / SideStore source for the release.

usage: altstore_source.py VERSION BUILD IPA_PATH > altstore-source.json
Add the source in SideStore/AltStore with:
  https://github.com/un4ckn0wl3z/streammkv/releases/latest/download/altstore-source.json
"""
import datetime
import json
import os
import sys

REPO = os.environ.get("GITHUB_REPOSITORY", "un4ckn0wl3z/streammkv")
version, build, ipa = sys.argv[1], sys.argv[2], sys.argv[3]
icon = f"https://raw.githubusercontent.com/{REPO}/main/app/assets/icon.png"
desc = ("Watch MKV movies from your Delos seedbox server: original quality playback with every "
        "audio track and subtitle (ASS, PGS, SRT), or server-side transcoding to save data. "
        "Watch progress syncs with the browser userscript and other devices.")
src = {
    "name": "Delos",
    "identifier": "dev.un4ckn0wl3z.streammkv.source",
    "subtitle": "Your seedbox, on your phone.",
    "description": desc,
    "iconURL": icon,
    "website": f"https://github.com/{REPO}",
    "tintColor": "#4A9EFF",
    "apps": [{
        "name": "Delos",
        "bundleIdentifier": "dev.un4ckn0wl3z.streammkv",
        "developerName": "un4ckn0wl3z",
        "subtitle": "Watch MKV from your seedbox",
        "localizedDescription": desc,
        "iconURL": icon,
        "tintColor": "#4A9EFF",
        "category": "entertainment",
        "screenshots": [],
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": f"Delos {version}. See https://github.com/{REPO}/releases/tag/v{version}",
            "downloadURL": f"https://github.com/{REPO}/releases/download/v{version}/streammkv-ios.ipa",
            "size": os.path.getsize(ipa),
            "minOSVersion": "13.0",
        }],
        "appPermissions": {
            "entitlements": [],
            "privacy": {"NSLocalNetworkUsageDescription": "Connect to your media server on the local network."},
        },
    }],
    "news": [],
}
json.dump(src, sys.stdout, indent=2)
