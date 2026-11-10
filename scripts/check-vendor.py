#!/usr/bin/env python3
"""The sandbox's files under vendor/ are the sandbox's, byte for byte.

    scripts/check-vendor.py             the copies against VENDOR.txt
    scripts/check-vendor.py --upstream  and against GitHub at the pinned commit,
                                        and the pinned release against the newest

The first form needs no network and runs in every Verify (scripts/validate.sh
vendor): each file listed in VENDOR.txt must exist with the sha256 written
there, and nothing unlisted may sit beside them. The second runs on Verify's
schedule (the freshness job): it fetches every listed file from
raw.githubusercontent.com at the commit VENDOR.txt names, compares the bytes,
checks that the release tag still points at that commit, and reports when
the sandbox has released past the pinned version, which is a change for a
person to read, not to take on trust.

Standard library only.
"""
import hashlib
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor", "kubernetes-ai-agent-sandbox")
REPO = "heyvaldemar/kubernetes-ai-agent-sandbox"


def read_manifest():
    meta, files = {}, {}
    for line in open(os.path.join(VENDOR, "VENDOR.txt"), encoding="utf-8"):
        m = re.match(r"^# (Source|Release|Commit):\s+(\S+)", line)
        if m:
            meta[m.group(1).lower()] = m.group(2)
        elif line.strip() and not line.startswith("#"):
            path, digest = line.split()
            files[path] = digest
    return meta, files


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "check-vendor"})
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def semver(tag):
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
    return tuple(int(x) for x in m.groups()) if m else None


def main():
    upstream = "--upstream" in sys.argv[1:]
    meta, files = read_manifest()
    bad = []
    for path, digest in sorted(files.items()):
        full = os.path.join(VENDOR, path)
        if not os.path.isfile(full):
            bad.append("%s is listed in VENDOR.txt and missing" % path)
        elif sha256(open(full, "rb").read()) != digest:
            bad.append("%s differs from the copy VENDOR.txt records; vendor/ is never edited here" % path)
    for dirpath, _, names in os.walk(VENDOR):
        for name in names:
            rel = os.path.relpath(os.path.join(dirpath, name), VENDOR)
            if rel != "VENDOR.txt" and rel not in files:
                bad.append("%s sits in vendor/ and is not listed in VENDOR.txt" % rel)
    if upstream:
        commit, release = meta["commit"], meta["release"]
        for path, digest in sorted(files.items()):
            data = get("https://raw.githubusercontent.com/%s/%s/%s" % (REPO, commit, path))
            if sha256(data) != digest:
                bad.append("%s at %s upstream is not the copy recorded here" % (path, commit[:12]))
        tag = json.loads(get("https://api.github.com/repos/%s/commits/%s" % (REPO, release)))["sha"]
        if tag != commit:
            bad.append("the sandbox's %s now points at %s, not %s" % (release, tag[:12], commit[:12]))
        latest = json.loads(get("https://api.github.com/repos/%s/releases/latest" % REPO))["tag_name"]
        if semver(latest) and semver(release) and semver(latest) > semver(release):
            bad.append("the sandbox has released %s; this repository consumes %s (read the release, then copy it in)" % (latest, release))
        else:
            print("the sandbox's newest release is %s, the one consumed here" % latest)
    for b in bad:
        print("::error::vendor: %s" % b if os.environ.get("GITHUB_ACTIONS") else "vendor: %s" % b)
    if not bad:
        print("%d vendored files match VENDOR.txt%s" % (len(files), " and the sandbox at %s" % meta["commit"][:12] if upstream else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
