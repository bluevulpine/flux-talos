#!/usr/bin/env python3
"""Find dependencies whose upstream has moved, been archived or deprecated its image.

Why: Renovate can only bump the name it already tracks. When a project moves (Jellyseerr's repo
became seerr-team/seerr and the image moved to ghcr.io/seerr-team/seerr), the old name either
goes quiet or, worse, keeps getting tags (2026-10-13: `2.7.3-deprecated`, `latest` re-pointed),
so neither Renovate's update lookup nor its `abandonmentThreshold` notices. Jellyseerr sat on
2.7.3 for months and surfaced only as a Tracearr sync failure.

What it checks, per container image, OCI Helm chart and `datasource=github-*` annotation:
  - source GitHub repo renamed or transferred (the API answers with a different full_name)
  - source GitHub repo archived, or gone (404)
  - Docker Hub repository archived, or a recent tag named *deprecated* / *eol*
The source repo comes from the image's `org.opencontainers.image.source` label (Helm charts:
Chart.yaml `sources`/`home`), so monorepo builds (home-operations/containers) resolve correctly.

Scope: kubernetes/ and talos/. bootstrap/helmfile.d is not scanned; its charts repeat
kubernetes/ ones. Images with no source label get the Docker Hub checks only.

Accepted findings go in .github/upstream-moved-ignore.yaml with the reason they are fine.
Writes a Markdown report to --report and `findings=N` / `errors=N` to $GITHUB_OUTPUT. A check
that could not complete (rate limit, 5xx, network error) is an error, never a clean result:
the workflow must not close the issue on a run that could not see everything.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

FIRST_PARTY = ("gitea.derekjacobs.dev/",)  # our own Drone builds; Flux image automation owns them
MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
DEPRECATED_TAG = re.compile(r"(?i)(deprecat|\beol\b|end-of-life|moved)")
GITHUB_URL = re.compile(r"github\.com[/:]([\w.-]+)/([\w.-]+?)(?:\.git)?(?:[/#?]|$)")
UA = "flux-talos-upstream-moved"


class Http:
    def __init__(self, github_token: str | None):
        self.github_token = github_token
        self.registry_tokens: dict[tuple[str, str], str] = {}
        self.errors: list[str] = []

    def error(self, what: str) -> None:
        self.errors.append(what)

    def get(self, url: str, headers: dict[str, str] | None = None) -> tuple[int, bytes, dict]:
        req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.read(), {k.lower(): v for k, v in r.headers.items()}
        except urllib.error.HTTPError as e:
            return e.code, e.read(), {k.lower(): v for k, v in e.headers.items()}
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            # Status 0 = no answer; callers treat it like any other unexpected status.
            return 0, str(e).encode(), {}

    def github_repo(self, owner: str, repo: str) -> tuple[int, dict]:
        h = {"Accept": "application/vnd.github+json"}
        if self.github_token:
            h["Authorization"] = f"Bearer {self.github_token}"
        # urllib follows the 301 GitHub sends for a renamed repo, so full_name is the new name.
        status, body, _ = self.get(f"https://api.github.com/repos/{owner}/{repo}", h)
        return status, (load_json(body) or {} if status == 200 else {})

    def registry(self, host: str, name: str, path: str, accept: str | None = None) -> tuple[int, bytes]:
        api = "registry-1.docker.io" if host == "docker.io" else host
        url = f"https://{api}/v2/{name}/{path}"
        headers = {"Accept": accept} if accept else {}
        key = (host, name)
        if key in self.registry_tokens:
            headers["Authorization"] = f"Bearer {self.registry_tokens[key]}"
        status, body, resp_headers = self.get(url, headers)
        if status == 401 and key not in self.registry_tokens:
            token = self._anonymous_token(resp_headers.get("www-authenticate", ""))
            if token:
                self.registry_tokens[key] = token
                return self.registry(host, name, path, accept)
        return status, body

    def _anonymous_token(self, challenge: str) -> str | None:
        params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        if "realm" not in params:
            return None
        query = "&".join(f"{k}={params[k]}" for k in ("service", "scope") if k in params)
        status, body, _ = self.get(f"{params['realm']}?{query}")
        if status != 200:
            return None
        data = json.loads(body)
        return data.get("token") or data.get("access_token")


def load_json(body: bytes):
    try:
        return json.loads(body)
    except ValueError:
        return None


# ---------------------------------------------------------------- dependency discovery

def split_ref(ref: str) -> tuple[str, str, str]:
    """'ghcr.io/a/b:1.0@sha256:x' -> ('ghcr.io', 'a/b', 'sha256:x'); bare names are Docker Hub."""
    ref = ref.removeprefix("oci://")
    digest = ""
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    tag = ""
    last = ref.rsplit("/", 1)[-1]
    if ":" in last:
        ref, tag = ref.rsplit(":", 1)
    first = ref.split("/", 1)[0]
    if "/" in ref and ("." in first or ":" in first or first == "localhost"):
        host, name = ref.split("/", 1)
    else:
        host, name = "docker.io", ref
    if host == "docker.io" and "/" not in name:
        name = f"library/{name}"
    return host, name, digest or tag


def walk(node, found: dict[str, dict], where: str) -> None:
    if isinstance(node, dict):
        repo, tag = node.get("repository"), node.get("tag")
        if isinstance(repo, str) and isinstance(tag, (str, int, float)) and "$" not in repo:
            add(found, f"{repo}:{tag}", "image", where)
        img = node.get("image")
        if isinstance(img, str) and ("/" in img or ":" in img) and "$" not in img:
            add(found, img, "image", where)
        for v in node.values():
            walk(v, found, where)
    elif isinstance(node, list):
        for v in node:
            walk(v, found, where)


def add(found: dict[str, dict], ref: str, kind: str, where: str) -> None:
    ref = ref.strip()
    if not ref or ref.startswith(FIRST_PARTY):
        return
    host, name, version = split_ref(ref)
    key = f"{host}/{name}"
    entry = found.setdefault(key, {"host": host, "name": name, "version": version, "kind": kind, "files": set()})
    entry["files"].add(where)


def discover(root: Path) -> tuple[dict[str, dict], dict[str, set[str]]]:
    images: dict[str, dict] = {}
    github_deps: dict[str, set[str]] = {}
    annotation = re.compile(r"datasource=github-(?:releases|tags)\s+depName=([\w.-]+/[\w.-]+)")
    for path in sorted(list(root.glob("kubernetes/**/*.yaml")) + list(root.glob("talos/**/*.yaml"))):
        if ".sops." in path.name:
            continue
        rel = str(path.relative_to(root))
        text = path.read_text(errors="replace")
        for m in annotation.finditer(text):
            github_deps.setdefault(m.group(1), set()).add(rel)
        try:
            docs = list(yaml.safe_load_all(text))
        except yaml.YAMLError:
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            if doc.get("kind") == "OCIRepository":
                spec = doc.get("spec") or {}
                url, ref = spec.get("url", ""), (spec.get("ref") or {})
                version = ref.get("tag") or ref.get("digest") or ref.get("semver", "")
                if url.startswith("oci://") and "$" not in url:
                    add(images, f"{url}:{version}" if ref.get("tag") else url, "chart", rel)
                continue
            walk(doc, images, rel)
    return images, github_deps


# ---------------------------------------------------------------- source resolution

def source_url(http: Http, dep: dict) -> str | None:
    host, name, version = dep["host"], dep["name"], dep["version"] or "latest"
    status, body = http.registry(host, name, f"manifests/{version}", MANIFEST_TYPES)
    if status in (404, 401, 403):  # tag gone or private: no source to follow, not a scan error
        return None
    manifest = load_json(body) if status == 200 else None
    if not isinstance(manifest, dict):
        http.error(f"`{host}/{name}`: manifest lookup answered {status}")
        return None
    annotations = manifest.get("annotations") or {}
    if "manifests" in manifest:  # index: take linux/amd64, else the first entry
        entries = manifest["manifests"]
        pick = next((m for m in entries if (m.get("platform") or {}).get("architecture") == "amd64"), entries[0] if entries else None)
        if not pick:
            return annotations.get("org.opencontainers.image.source")
        status, body = http.registry(host, name, f"manifests/{pick['digest']}", MANIFEST_TYPES)
        if status != 200:
            return annotations.get("org.opencontainers.image.source")
        manifest = load_json(body) or {}
        annotations = {**annotations, **(manifest.get("annotations") or {})}
    if src := annotations.get("org.opencontainers.image.source"):
        return src
    config = manifest.get("config") or {}
    if not config.get("digest"):
        return None
    status, body = http.registry(host, name, f"blobs/{config['digest']}")
    if status != 200:
        return None
    blob = load_json(body)
    if not isinstance(blob, dict):
        return None
    if "helm.config" in config.get("mediaType", ""):  # Helm chart: Chart.yaml metadata
        for url in (blob.get("sources") or []) + [blob.get("home") or ""]:
            if GITHUB_URL.search(url or ""):
                return url
        return None
    labels = (blob.get("config") or {}).get("Labels") or {}
    return labels.get("org.opencontainers.image.source") or labels.get("org.label-schema.vcs-url")


def github_of(url: str | None) -> str | None:
    m = GITHUB_URL.search(url or "")
    return f"{m.group(1)}/{m.group(2)}" if m else None


# ---------------------------------------------------------------- checks

def check_github(http: Http, repo: str, cache: dict) -> list[str]:
    if repo not in cache:
        owner, name = repo.split("/", 1)
        status, data = http.github_repo(owner, name)
        problems = []
        if status == 404:
            problems.append(f"source repo `{repo}` not found (deleted or private)")
        elif status != 200 or "full_name" not in data:
            http.error(f"GitHub `{repo}`: answered {status}")
        else:
            if data["full_name"].lower() != repo.lower():
                problems.append(f"source repo `{repo}` now answers as `{data['full_name']}` (renamed or transferred)")
            if data.get("archived"):
                problems.append(f"source repo `{data['full_name']}` is archived")
        cache[repo] = problems
    return cache[repo]


def check_dockerhub(http: Http, name: str) -> list[str]:
    status, body, _ = http.get(f"https://hub.docker.com/v2/repositories/{name}/")
    repo = load_json(body) if status == 200 else None
    if status == 404:
        return []
    if not isinstance(repo, dict):
        http.error(f"Docker Hub `{name}`: answered {status}")
        return []
    problems = []
    if repo.get("status_description") == "archived":
        problems.append(f"Docker Hub repository `{name}` is archived")
    status, body, _ = http.get(f"https://hub.docker.com/v2/repositories/{name}/tags?page_size=25&ordering=last_updated")
    tags = load_json(body) if status == 200 else None
    if not isinstance(tags, dict):
        http.error(f"Docker Hub `{name}` tags: answered {status}")
    else:
        flagged = [t["name"] for t in tags.get("results", []) if DEPRECATED_TAG.search(t["name"])]
        if flagged:
            problems.append(f"recent tags look like a deprecation notice: `{'`, `'.join(flagged[:3])}`")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    ap.add_argument("--root", default=".", type=Path)
    ap.add_argument("--ignore", default=".github/upstream-moved-ignore.yaml", type=Path)
    ap.add_argument("--report", default="upstream-moved.md", type=Path)
    args = ap.parse_args()

    ignore_file = args.root / args.ignore
    ignored = {e["name"] for e in (yaml.safe_load(ignore_file.read_text()) or [])} if ignore_file.exists() else set()
    http = Http(os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN"))
    images, github_deps = discover(args.root)
    gh_cache: dict[str, list[str]] = {}
    findings: list[tuple[str, list[str], set[str]]] = []
    unresolved: list[str] = []

    for key, dep in sorted(images.items()):
        if key in ignored:
            continue
        problems = check_dockerhub(http, dep["name"]) if dep["host"] == "docker.io" else []
        # Official images carry no source label; skipping them also saves Docker Hub pulls
        # (each manifest GET counts against the anonymous pull limit, ~35 per run otherwise).
        official = bool(re.match(r"^(docker/)?library/", dep["name"]))
        repo = None if official else github_of(source_url(http, dep))
        if repo:
            problems += check_github(http, repo, gh_cache)
        elif not official:
            unresolved.append(key)
        if problems:
            findings.append((key, problems, dep["files"]))
        print(f"{'FLAG' if problems else 'ok  '} {key} -> {repo or '?'}", file=sys.stderr)

    for repo, files in sorted(github_deps.items()):
        if repo in ignored:
            continue
        if problems := check_github(http, repo, gh_cache):
            findings.append((repo, problems, files))

    lines = [
        "<!-- generated by scripts/upstream-moved.py; edits are overwritten -->",
        f"Scanned {len(images)} images/charts and {len(github_deps)} GitHub-tracked dependencies.",
        "",
    ]
    if findings:
        lines += [
            "These dependencies' upstream looks moved, archived or deprecated. Renovate will not",
            "propose the move itself: migrate the reference (a `replacementName` rule in",
            "`.renovate/overrides.json5` makes Renovate open the PR), or add the name to",
            "`.github/upstream-moved-ignore.yaml` with the reason it is fine. A \"renamed\" repo",
            "can be stale metadata: if the image already lives under the new owner, ignore it.",
            "",
        ]
        for key, problems, files in findings:
            lines.append(f"- [ ] **`{key}`** ({', '.join(f'`{f}`' for f in sorted(files)[:3])})")
            lines += [f"  - {p}" for p in problems]
    else:
        lines.append("No moved, archived or deprecated upstreams found.")
    if http.errors:
        lines += [
            "",
            f"**{len(http.errors)} checks could not complete** (rate limit, server or network error);",
            "this list may be incomplete:",
            "",
            *[f"- {e}" for e in http.errors[:30]],
        ]
    if unresolved:
        lines += [
            "",
            "<details><summary>No GitHub source found for these (not checked beyond Docker Hub)</summary>",
            "",
            *[f"- `{u}`" for u in unresolved],
            "",
            "</details>",
        ]
    args.report.write_text("\n".join(lines) + "\n")
    print(f"findings={len(findings)} errors={len(http.errors)} unresolved={len(unresolved)}", file=sys.stderr)
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as f:
            f.write(f"findings={len(findings)}\nerrors={len(http.errors)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
