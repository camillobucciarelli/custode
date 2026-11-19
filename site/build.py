#!/usr/bin/env python3
"""Builds the Custode website into a directory of static files. Standard library only.

Usage: python3 site/build.py [output dir]   (default: build/site)

The site is served from a Cloudflare R2 bucket, which has no directory indexes: every internal link is a
relative link to an explicit .html file. Conventions for content fragments are in site/README.md.
Checked by tool/release/download_check.sh; published by the `download` job of .github/workflows/release.yml.
"""
import html
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import quote

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
BASE = "https://custode.camillobucciarelli.dev/"
GITHUB = "https://github.com/camillobucciarelli/custode"
LANGS = {"en": "", "it": "it/"}  # language -> directory under the site root; English is the root and x-default
FONTS = ["Caprasimo-Regular.ttf", "Figtree-Regular.ttf", "Figtree-SemiBold.ttf", "Figtree-Bold.ttf", "OFL.txt"]

# The guide manifest: groups, order, and per language (title, one-line summary[, short label for the side index]).
# It drives the side index, the guides index page and the previous/next links. A guide is published only when
# content/<lang>/guides/<slug>.html exists in every language; until then it is skipped and never linked.
GUIDES = [
    {"en": "Getting started", "it": "Primi passi", "guides": [
        {"slug": "install",
         "en": ("Install Custode", "Download the app and start it on each platform."),
         "it": ("Installare Custode", "Scaricare l’app e avviarla su ogni piattaforma.")},
        {"slug": "first-vault",
         "en": ("Create your first vault", "A new file or a KeePass vault you already have."),
         "it": ("Creare il primo archivio", "Un file nuovo o un archivio KeePass che hai già.")},
        {"slug": "unlock-biometrics-key-file",
         "en": ("Unlock with biometrics or a key file", "Open the vault with fingerprint, face or a key file."),
         "it": ("Sbloccare con biometria o file chiave", "Aprire l’archivio con impronta, volto o un file chiave.")},
        {"slug": "import-from-another-manager",
         "en": ("Move from another manager", "Import a CSV file from Bitwarden, 1Password, LastPass, Chrome or Apple Passwords."),
         "it": ("Passare da un altro gestore", "Importare un file CSV da Bitwarden, 1Password, LastPass, Chrome o Apple Passwords.")},
    ]},
    {"en": "Sync", "it": "Sincronizzazione", "guides": [
        {"slug": "google-drive-sync",
         "en": ("Sync with Google Drive", "Connect the account, choose the file, resolve a conflict."),
         "it": ("Sincronizzare con Google Drive", "Collegare l’account, scegliere il file, risolvere un conflitto.")},
        {"slug": "resolve-sync-conflict",
         "en": ("Resolve a conflict", "Choose which version to keep when two devices changed the same vault."),
         "it": ("Risolvere un conflitto", "Scegliere quale versione tenere quando due dispositivi hanno modificato lo stesso archivio.")},
    ]},
    {"en": "Autofill", "it": "Compilazione automatica", "guides": [
        {"slug": "autofill-apple",
         "en": ("Autofill on iPhone, iPad and Mac", "Use Custode for system passwords.", "iPhone, iPad and Mac"),
         "it": ("Compilazione automatica su iPhone, iPad e Mac", "Usare Custode per le password di sistema.", "iPhone, iPad e Mac")},
        {"slug": "autofill-chrome-edge",
         "en": ("Autofill in Chrome and Edge", "Install the extension and connect it to the app on your computer.", "Chrome and Edge"),
         "it": ("Compilazione automatica in Chrome ed Edge", "Installare l’estensione e collegarla all’app sul computer.", "Chrome ed Edge")},
    ]},
    {"en": "Every day", "it": "Ogni giorno", "guides": [
        {"slug": "one-time-codes",
         "en": ("One-time codes", "Add the two-factor code to an entry by scanning the QR code or pasting the address."),
         "it": ("Codici monouso", "Aggiungere il codice a due fattori a una voce, inquadrando il QR o incollando l’indirizzo.")},
        {"slug": "vault-health",
         "en": ("Vault health", "See which entries need attention and how to fix them."),
         "it": ("Salute dell’archivio", "Vedere quali voci richiedono attenzione e come sistemarle.")},
        {"slug": "auto-lock-clipboard",
         "en": ("Auto-lock and clipboard", "Lock the vault after inactivity and clear the clipboard."),
         "it": ("Blocco automatico e appunti", "Bloccare l’archivio dopo l’inattività e svuotare gli appunti.")},
        {"slug": "backup-vault",
         "en": ("Back up your vault", "Keep a spare copy of the vault file."),
         "it": ("Copia di sicurezza dell’archivio", "Tenere una copia di riserva del file dell’archivio.")},
    ]},
]

# Interface strings of the shared layout and the generated guide pages.
T = {
    "en": {
        "skip": "Skip to content", "nav": "Main", "features": ("Features", "features"), "security": ("Security", "security"),
        "guides": "Guides", "download": "Download", "language": "Language",
        "tagline": "Open source password manager in the KeePass format. Developed by Camillo Bucciarelli.",
        "footer": "Footer", "licence": "AGPL-3.0 licence", "coffee": "Buy me a coffee",
        "home": ("Custode: open source password manager for KeePass files",
                 "Custode keeps your vault in the open KeePass .kdbx format, on your own devices. No account, no server of ours, no telemetry."),
        "download_page": ("Download Custode",
                          "Download Custode for Android, Windows and Linux, ask for test access on iPhone, iPad and Mac, and get the extension for Chrome and Edge."),
        "guides_page": ("Guides", "Step-by-step instructions, written for people who use the app, not for those who develop it."),
        "more_soon": "More guides are on the way.",
        "prev_next": "Previous and next guide", "prev": "Previous", "next": "Next",
        "issue": ("Something does not add up?", "Open an issue on GitHub"),
        "test_subject": "Custode test access: {}",
        "test_body": "Hello, I would like to join the Custode test.\n\nPlatform: {}\nApple ID or Google account email to invite: \n",
    },
    "it": {
        "skip": "Vai al contenuto", "nav": "Principale", "features": ("Funzioni", "funzioni"), "security": ("Sicurezza", "sicurezza"),
        "guides": "Guide", "download": "Scarica", "language": "Lingua",
        "tagline": "Gestore di password open source nel formato KeePass. Sviluppato da Camillo Bucciarelli.",
        "footer": "Piè di pagina", "licence": "Licenza AGPL-3.0", "coffee": "Offrimi un caffè",
        "home": ("Custode: gestore di password open source nel formato KeePass",
                 "Custode conserva il tuo archivio nel formato aperto KeePass .kdbx, sui tuoi dispositivi. Nessun account, nessun server nostro, nessuna telemetria."),
        "download_page": ("Scarica Custode",
                          "Scarica Custode per Android, Windows e Linux, chiedi l’accesso al test su iPhone, iPad e Mac e installa l’estensione per Chrome ed Edge."),
        "guides_page": ("Guide", "Istruzioni passo per passo, scritte per chi usa l’app e non per chi la sviluppa."),
        "more_soon": "Altre guide sono in arrivo.",
        "prev_next": "Guida precedente e successiva", "prev": "Precedente", "next": "Successiva",
        "issue": ("Qualcosa non torna?", "Apri una segnalazione su GitHub"),
        "test_subject": "Accesso al test di Custode: {}",
        "test_body": "Ciao, vorrei partecipare al test di Custode.\n\nPiattaforma: {}\nEmail dell’ID Apple o dell’account Google da invitare: \n",
    },
}
LANG_NAMES = {"it": "Italiano", "en": "English"}  # the order of the selector, as in the design
TEST_PLATFORMS = {"android": "Android (Google Play)", "ios": "iPhone / iPad (TestFlight)", "mac": "Mac (TestFlight)"}

LAYOUT = """<!DOCTYPE html>
<html lang="{lang}"{root_home}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="canonical" href="{url}">
{alternates}
<meta property="og:type" content="website">
<meta property="og:site_name" content="Custode">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{url}">
<link rel="icon" type="image/svg+xml" href="{favicon}">
<link rel="stylesheet" href="{root}assets/site.css">
<script src="{root}assets/site.js"></script>
</head>
<body>
<a class="skip-link" href="#main">{skip}</a>
<header class="site-header">
<div class="wrap">
<a class="brand" href="{home}index.html">{logo}Custode</a>
<nav class="site-nav" aria-label="{nav}">
<a href="{home}index.html#{features_id}">{features}</a>
<a href="{home}index.html#{security_id}">{security}</a>
<a href="{home}guides/index.html"{guides_current}>{guides}</a>
<a href="{github}">GitHub</a>
{lang_links}
<select class="lang-select" aria-label="{language}" autocomplete="off" hidden>{lang_options}</select>
<a class="btn btn-primary btn-sm" href="{home}download.html"{download_current}>{download}</a>
</nav>
</div>
</header>
<main id="main">
{body}
</main>
<footer class="site-footer">
<div class="wrap">
<div class="about"><span class="name">Custode</span><span class="small">{tagline}</span></div>
<nav aria-label="{footer}">
<a href="{home}guides/index.html">{guides}</a>
<a href="{home}download.html">{download}</a>
<a href="{github}">GitHub</a>
<a href="{github}/blob/main/PRIVACY.md">Privacy</a>
<a href="{github}/blob/main/SECURITY.md">{security}</a>
<a href="{github}/blob/main/LICENSE">{licence}</a>
<a href="https://buymeacoffee.com/camillobucciarelli">{coffee}</a>
</nav>
</div>
</footer>
</body>
</html>
"""


def fragment(lang, name):
    return SITE / "content" / lang / f"{name}.html"


def published_guides():
    """Manifest groups reduced to the guides whose fragment exists; a guide in one language only is an error."""
    groups = []
    for group in GUIDES:
        guides = []
        for guide in group["guides"]:
            have = [lang for lang in LANGS if fragment(lang, f"guides/{guide['slug']}").exists()]
            if have and len(have) != len(LANGS):
                sys.exit(f"guide {guide['slug']}: fragment exists for {have} only; write it in every language")
            if have:
                guides.append(guide)
        if guides:
            groups.append({**group, "guides": guides})
    return groups


def main(out):
    # Refuse to wipe a directory that is not a previous build of this site.
    if out.exists() and any(out.iterdir()) and not (out / "assets" / "site.css").exists():
        sys.exit(f"{out} exists and is not a site build; not overwriting it")
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(SITE / "assets", out / "assets", ignore=shutil.ignore_patterns(".*"))
    # ponytail: the app's own TTF files are served as they are (one copy of the fonts in the repository);
    # subset them to WOFF2 at build time if page weight ever matters (about 215 kB for the four files).
    for font in FONTS:
        (out / "assets" / "fonts").mkdir(exist_ok=True)
        shutil.copy(REPO / "assets" / "fonts" / font, out / "assets" / "fonts" / font)

    mark = (REPO / "assets" / "logo" / "custode-mark-color.svg").read_text(encoding="utf-8")
    logo = re.sub(r">\s+<", "><", mark.strip())
    favicon = "data:image/svg+xml," + quote(logo, safe="/:=' ")
    sized = 'width="40" height="40" aria-hidden="true"'
    logo = logo.replace('width="1024" height="1024"', sized)
    assert sized in logo, "custode-mark-color.svg no longer has the width/height this script replaces"
    # The contact address is published in PRIVACY.md; read it there so the site never drifts from the policy.
    contact = re.search(r"\*\*Contact:\*\*\s*(\S+@\S+)", (REPO / "PRIVACY.md").read_text(encoding="utf-8")).group(1)

    groups = published_guides()
    all_slugs = {guide["slug"] for group in GUIDES for guide in group["guides"]}
    flat = [guide for group in groups for guide in group["guides"]]
    live = {guide["slug"] for guide in flat}

    def page(lang, path, title, description, body, current=None):
        """Writes one page. `path` is relative to the language root, e.g. guides/index.html."""
        t = T[lang]
        home = "../" * path.count("/")                     # to the language root
        root = "../" * (LANGS[lang] + path).count("/")     # to the site root

        def absolute(l):
            return BASE + LANGS[l] + ("" if (l, path) == ("en", "index.html") else path)

        def guide_link(match):
            slug = match.group(1)
            if slug not in all_slugs:
                sys.exit(f"{lang}/{path}: @guide:{slug} is not in the manifest")
            return home + (f"guides/{slug}.html" if slug in live else "guides/index.html")

        def test_link(match):
            platform = TEST_PLATFORMS[match.group(1)]
            return html.escape(f"mailto:{contact}?subject={quote(t['test_subject'].format(platform))}"
                               f"&body={quote(t['test_body'].format(platform))}")

        body = re.sub(r"@guide:([a-z0-9-]+)", guide_link, body)
        body = re.sub(r"@test:([a-z]+)", test_link, body)
        body = body.replace('"@/', '"' + home).replace('"~/', '"' + root)
        others = [l for l in LANGS if l != lang]
        text = LAYOUT.format(
            lang=lang, root=root, home=home, body=body, logo=logo, favicon=html.escape(favicon), github=GITHUB,
            root_home=" data-root-home" if (lang, path) == ("en", "index.html") else "",
            title=html.escape(title), description=html.escape(description), url=absolute(lang),
            alternates="\n".join(f'<link rel="alternate" hreflang="{code}" href="{absolute(l)}">'
                                 for code, l in [*((l, l) for l in LANGS), ("x-default", "en")]),
            lang_links="\n".join(f'<a class="lang-link" href="{root}{LANGS[l]}{path}" lang="{l}" hreflang="{l}">{LANG_NAMES[l]}</a>'
                                 for l in others),
            lang_options="".join(
                f'<option value="{"" if l == lang else root + LANGS[l] + path}" lang="{l}"{" selected" if l == lang else ""}>{name}</option>'
                for l, name in LANG_NAMES.items()),
            guides_current=f' aria-current="{current[1]}"' if current and current[0] == "guides" else "",
            download_current=' aria-current="page"' if current and current[0] == "download" else "",
            features=t["features"][0], features_id=t["features"][1], security=t["security"][0], security_id=t["security"][1],
            **{key: t[key] for key in ("skip", "nav", "guides", "download", "language", "tagline", "footer", "licence", "coffee")},
        )
        target = out / LANGS[lang] / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def guide_page(lang, slug, crumb, title, article):
        """The two-column guides layout: side index + article. `slug` is None on the guides index."""
        t = T[lang]
        def item(guide):
            here = ' aria-current="page"' if guide["slug"] == slug else ""
            return f'<a href="{guide["slug"]}.html"{here}>{guide[lang][-1] if len(guide[lang]) > 2 else guide[lang][0]}</a>'

        index = "".join(f'<div><p>{group[lang]}</p>{"".join(item(guide) for guide in group["guides"])}</div>' for group in groups)
        return (f'<div class="wrap guide">\n<nav class="guide-index" aria-label="{t["guides"]}">{index}</nav>\n'
                f'<article class="guide-article">\n{crumb}<h1>{title}</h1>\n{article}</article>\n</div>')

    for lang in LANGS:
        t = T[lang]
        page(lang, "index.html", *t["home"], fragment(lang, "home").read_text(encoding="utf-8"))
        title, description = t["download_page"]
        page(lang, "download.html", title, description,
             fragment(lang, "download").read_text(encoding="utf-8"), current=("download", "page"))

        title, description = t["guides_page"]
        listing = "".join(
            f'<h2>{group[lang]}</h2>\n<ul class="link-list rich">\n' + "".join(
                f'<li><a href="{guide["slug"]}.html"><span><span class="title">{guide[lang][0]}</span>'
                f'<span class="summary">{guide[lang][1]}</span></span></a></li>\n' for guide in group["guides"]) + "</ul>\n"
            for group in groups)
        soon = f' {t["more_soon"]}' if live != all_slugs else ""
        page(lang, "guides/index.html", f"{title} · Custode", description,
             guide_page(lang, None, "", title, f'<p class="lead">{description}{soon}</p>\n{listing}'), current=("guides", "page"))

        for group in groups:
            for guide in group["guides"]:
                slug, (title, summary) = guide["slug"], guide[lang][:2]
                at = flat.index(guide)
                links = [f'<a class="{cls}" href="{other["slug"]}.html"><span>{t[cls]}</span><strong>{other[lang][0]}</strong></a>'
                         for cls, other in (("prev", flat[at - 1] if at else None), ("next", flat[at + 1] if at + 1 < len(flat) else None))
                         if other]
                article = fragment(lang, f"guides/{slug}").read_text(encoding="utf-8")
                if links:
                    article += f'<nav class="prev-next" aria-label="{t["prev_next"]}">{"".join(links)}</nav>\n'
                article += f'<p class="small">{t["issue"][0]} <a href="{GITHUB}/issues">{t["issue"][1]}</a>.</p>\n'
                crumb = f'<p class="small"><a href="index.html">{t["guides"]}</a> · {group[lang]}</p>\n'
                page(lang, f"guides/{slug}.html", f"{title} · Custode", summary,
                     guide_page(lang, slug, crumb, title, article), current=("guides", "true"))

    print(f"Built {sum(1 for _ in out.rglob('*.html'))} pages, {len(live)} of {len(all_slugs)} guides, in {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "build" / "site"))
