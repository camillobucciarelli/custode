# Custode website

Source of https://custode.camillobucciarelli.dev/. Static, no dependencies: `build.py` (Python 3 standard
library) renders the fragments in `content/` into the shared layout.

```bash
python3 site/build.py                 # -> build/site (git-ignored)
bash tool/release/download_check.sh   # builds, then checks links, languages, third-party requests, HTML
python3 -m http.server 4173 --directory build/site
```

Published by the `download` job of `.github/workflows/release.yml`, which replaces `__VERSION__` in the built
HTML and uploads every file to the R2 bucket at its relative key.

## Rules

- **Every internal link names a `.html` file** (`it/index.html`, never `it/`): R2 serves no directory index.
- **All links are relative**, so the site also works from a local static server. In a fragment write
  `"@/download.html"` (relative to the language root), `"~/assets/img/x.png"` (relative to the site root) and
  `"@guide:<slug>"`; `build.py` turns them into the right relative path for each page.
- **No third-party requests**: no web fonts, scripts, images or analytics from another host. Fonts are the app's
  own files in `assets/fonts/`, copied at build time (do not duplicate them here). Outbound `<a href>` is fine.
- **No inline styles.** One stylesheet, `assets/site.css`, with the colours as custom properties for light and
  dark. No emoji, no exclamation marks, sentence case, verbs on buttons.
- English is the root (`index.html`, x-default), Italian lives under `it/`. Paths and guide slugs are identical
  in both languages, so the language selector maps page to page. Labels of the app's interface stay in English
  in both languages.

## Layout

```
build.py                  layout, interface strings (T), guide manifest (GUIDES)
assets/site.css site.js   the only stylesheet and script
assets/img/               screenshots, already downscaled
content/<lang>/home.html download.html guides/<slug>.html
```

## Adding a guide

The manifest `GUIDES` in `build.py` already lists every planned guide (group, order, title and one-line summary
per language). A guide goes live when its fragment exists:

1. Write `content/en/guides/<slug>.html` and `content/it/guides/<slug>.html`. Both, or the build stops.
2. Run `bash tool/release/download_check.sh`.

Nothing else: the side index, the guides index, previous/next, and every `@guide:<slug>` link on the home and
download pages pick it up. Until then `@guide:<slug>` points at the guides index.

`build.py` adds around the fragment: the breadcrumb, the `<h1>` (the manifest title), previous/next and the
closing "open an issue" line. The `<title>` and meta description come from the manifest too. A fragment is
therefore only the body of the article, and never contains an `<h1>`:

```html
<p class="lead">One or two sentences: what the reader gets.</p>
<p class="pills"><span class="pill">All platforms</span><span class="pill">5 minutes</span></p>

<div class="callout">
<p><strong>Before you start</strong></p>
<p>What the reader needs.</p>
</div>

<h2>Section title</h2>
<ol class="steps">
<li><p>What to do, as a title</p><p>The detail. Name controls with <span class="chip">Sync now</span>.</p></li>
</ol>

<figure class="shot">
<img class="phone" src="~/assets/img/iphone-sync.png" width="660" height="1434" loading="lazy" alt="What the screenshot shows">
<figcaption>One line.</figcaption>
</figure>

<dl class="facts">
<div><dt>Keep local</dt><dd>What it does.</dd></div>
</dl>

<div class="callout callout-warn">
<p><strong>Short warning.</strong> The rest of it.</p>
</div>
```

| Class | Element | Use |
| --- | --- | --- |
| `lead` | `<p>` | Opening paragraph, larger and muted. |
| `pills` > `pill` | `<p>` > `<span>` | Platform and time needed, under the lead. |
| `callout` | `<div>` of `<p>` | Green note: prerequisites, tips. `<strong>` for its title. |
| `callout callout-warn` | `<div>` of `<p>` | Orange note with a warning icon: privacy, data loss, limits. |
| `steps` | `<ol>` | Numbered steps (numbers come from CSS). In each `<li>` the first `<p>` is the step title, the following ones the detail. |
| `chip` | `<span>` | A label exactly as the app shows it: button, tab, section title. |
| `facts` | `<dl>` of `<div><dt><dd>` | Term on the left, explanation on the right: options, settings. |
| `shot` | `<figure>` | Screenshot on a green panel, with `<figcaption>`. Image class `phone` (660 px wide sources) or `desktop`. |
| (none) | `<h2>`, `<h3>`, `<p>`, `<ul>`, `<code>` | Plain prose. `<code>` for file names and extensions. |

Images: always `width`, `height`, `loading="lazy"` and an `alt` that says what is on the screen. Look at the
image before describing it. Screenshots available: `iphone-vault`, `iphone-sync`, `iphone-health`,
`iphone-generator`, `iphone-unlock`, `mac-vault` (all `.png`). Add new ones downscaled (phone 660 px wide,
desktop 1600 px).

Check every step against the app's code before writing it: the guide describes what the app does today.
