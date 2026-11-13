#!/bin/bash
# Checks the download page, hand-written HTML published as the R2 bucket's index.html: both languages, the
# __VERSION__ placeholder the workflow replaces, every download link the workflow uploads a file for, and no
# HTML parser errors (xmllint's HTML4 parser, so the HTML5 <main> is the one tag it may not know). A typo stops
# the publish before anything is uploaded. The versioned links are checked with the placeholder still in.
# Usage: download_check.sh [download.html]
set -euo pipefail
html=${1:-docs/download/index.html}
ok=1
grep -q '<html lang="en">' "$html" || { echo "$html: no <html lang=\"en\">"; ok=0; }
for lang in en it; do
  grep -q "<div lang=\"$lang\">" "$html" || { echo "$html: no <div lang=\"$lang\">"; ok=0; }
done
grep -q '__VERSION__' "$html" || { echo "$html: no __VERSION__ placeholder"; ok=0; }
for href in android/latest/Custode.apk windows/latest/Custode-windows.zip linux/latest/Custode-linux.zip \
  'android/__VERSION__/Custode-__VERSION__.apk' 'windows/__VERSION__/Custode-__VERSION__-windows.zip' \
  'linux/__VERSION__/Custode-__VERSION__-linux.zip'; do
  # Once per language.
  count=$(grep -cE "<a [^>]*href=\"$href\"" "$html" || true)
  [ "$count" = 2 ] || { echo "$html: link $href found $count times, expected 2"; ok=0; }
done
command -v xmllint > /dev/null || { echo "xmllint not found"; exit 1; }
errors=$(xmllint --html --noout "$html" 2>&1 | grep 'parser error' | grep -v 'Tag main invalid' || true)
[ -z "$errors" ] || { echo "$html: $errors"; ok=0; }
[ "$ok" = 1 ] || exit 1
echo "download ok"
