#!/bin/bash
# Builds the website (site/build.py) and checks the result, so a broken page stops the publish before anything
# is uploaded to the R2 bucket. Checked: the same pages exist in every language; <html lang> matches the page's
# directory and the hreflang alternates point at pages that exist; every internal href/src resolves to a file in
# the output (never to a directory: R2 serves no directory index), anchors included; nothing but <a href> points
# at another host (no web fonts, scripts or images from third parties); each download link the workflow uploads
# a file for is there once per language, with the __VERSION__ placeholder the workflow replaces still in; and no
# HTML parser errors (xmllint's HTML4 parser, so HTML5 and SVG tags it does not know are not errors).
# Usage: download_check.sh [output dir]   (default: build/site)
set -euo pipefail
out=${1:-build/site}
command -v xmllint > /dev/null || { echo "xmllint not found"; exit 1; }
python3 "$(dirname "$0")/../../site/build.py" "$out"

python3 - "$out" << 'PY'
import re, sys
from html.parser import HTMLParser
from pathlib import Path

out = Path(sys.argv[1]).resolve()
BASE = "https://custode.camillobucciarelli.dev/"
# Published by the workflow next to the site, not by the build: the only internal links allowed to dangle.
DOWNLOADS = ["android/latest/Custode.apk", "windows/latest/Custode-windows.zip", "linux/latest/Custode-linux.zip",
             "android/__VERSION__/Custode-__VERSION__.apk", "windows/__VERSION__/Custode-__VERSION__-windows.zip",
             "linux/__VERSION__/Custode-__VERSION__-linux.zip"]
errors = []


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if "id" in attrs:
            self.ids.add(attrs["id"])


pages = {}
for file in sorted(out.rglob("*.html")):
    page = Page()
    page.feed(file.read_text(encoding="utf-8"))
    pages[file.relative_to(out).as_posix()] = page

english = {name for name in pages if not name.startswith("it/")}
italian = {name[3:] for name in pages if name.startswith("it/")}
for name in ["index.html", "download.html", "guides/index.html", "guides/google-drive-sync.html"]:
    if name not in english:
        errors.append(f"{name}: page missing")
for name in sorted(english ^ italian):
    errors.append(f"{name}: exists in one language only")

for name, page in pages.items():
    def error(message):
        errors.append(f"{name}: {message}")

    lang = "it" if name.startswith("it/") else "en"
    if [attrs.get("lang") for tag, attrs in page.tags if tag == "html"] != [lang]:
        error(f'no <html lang="{lang}">')
    alternates = sorted(attrs.get("hreflang", "") for tag, attrs in page.tags
                        if tag == "link" and attrs.get("rel") == "alternate")
    if alternates != ["en", "it", "x-default"]:
        error(f"hreflang alternates are {alternates}, expected en, it, x-default")
    for tag, attrs in page.tags:
        if tag == "link" and attrs.get("rel") in ("alternate", "canonical"):
            target = attrs.get("href", "")
            if not target.startswith(BASE) or (target[len(BASE):] or "index.html") not in pages:
                error(f"{attrs['rel']} {target} is not a page of this site")
            continue
        for key in ("href", "src", "srcset", "poster", "action"):
            url = attrs.get(key)
            if url is None or url.startswith(("data:", "mailto:")):
                continue
            if re.match(r"[a-z][a-z0-9+.-]*:|//", url):
                if (tag, key) != ("a", "href") or not url.startswith("https://"):
                    error(f"<{tag} {key}> loads {url}: third-party resources are not allowed")
                continue
            path, _, anchor = url.partition("#")
            target = (out / name).parent.joinpath(path).resolve() if path else out / name
            if out not in target.parents:
                error(f"{url} leaves the site")
                continue
            bucket_key = target.relative_to(out).as_posix()
            if bucket_key in DOWNLOADS:
                if "download" not in attrs:
                    error(f"{url} has no download attribute")
            elif not target.is_file():
                error(f"{url} does not resolve to a file")
            elif anchor and anchor not in pages[bucket_key].ids:
                error(f"{url}: no id=\"{anchor}\" in the target page")

for name in ["download.html", "it/download.html"]:
    if name not in pages:
        continue
    links = [(out / name).parent.joinpath(attrs["href"]).resolve() for tag, attrs in pages[name].tags
             if tag == "a" and "download" in attrs]
    for download in DOWNLOADS:  # once per language, as before
        count = links.count(out / download)
        if count != 1:
            errors.append(f"{name}: link {download} found {count} times, expected 1")
    if "Custode __VERSION__" not in (out / name).read_text(encoding="utf-8"):
        errors.append(f"{name}: no visible __VERSION__ placeholder")

for file in sorted(out.rglob("*")):
    if file.suffix not in (".html", ".css", ".js"):
        continue
    text = file.read_text(encoding="utf-8")
    name = file.relative_to(out).as_posix()
    for marker in ('"@/', '"~/', "@guide:", "@test:"):
        if marker in text:
            errors.append(f"{name}: unresolved {marker} left by the build")
    if file.suffix != ".html" and re.search(r"https?://(?!www\.w3\.org/)|@import", text):  # w3.org: the SVG namespace
        errors.append(f"{name}: refers to another host")
    if re.search(r"fonts\.googleapis\.com|gstatic", text):
        errors.append(f"{name}: loads Google Fonts")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"{len(pages)} pages, links and languages ok")
PY

ok=1
while IFS= read -r html; do
  errors=$(xmllint --html --noout "$html" 2>&1 | grep 'parser error' | grep -vE 'Tag [a-zA-Z0-9]+ invalid' || true)
  [ -z "$errors" ] || { echo "$html: $errors"; ok=0; }
done < <(find "$out" -name '*.html' | sort)
[ "$ok" = 1 ] || exit 1
echo "download ok"
