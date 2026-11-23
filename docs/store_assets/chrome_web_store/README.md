# Chrome Web Store graphic assets

Listing graphics for **Custode Browser Autofill**. Everything here is generated;
do not edit the PNGs by hand.

## Files

| File | Size | Use |
| --- | --- | --- |
| `store-icon-128.png` | 128x128 RGBA | Store icon. Byte copy of `assets/logo/app_icon_family/ext-128.png`, which also ships in the ZIP as `icons/icon-128.png`: 96 px peach rounded tile, 16 px transparent padding per side. |
| `icon-128-alt.png` | 128x128 RGBA | Alternative store icon, not wired: the round mark alone at 112 px on a transparent canvas. |
| `promo-small-a-orange.png` | 440x280 RGB | Small promo tile, orange field, app icon only, no text. |
| `promo-small-b-dark.png` | 440x280 RGB | Small promo tile, dark brown field, mark plus "Custode / Browser Autofill". |
| `promo-small-c-peach.png` | 440x280 RGB | Small promo tile, peach to orange gradient, app icon plus "Custode". |
| `promo-marquee-a-orange.png` | 1400x560 RGB | Marquee promo tile, same design as small A. |
| `promo-marquee-b-dark.png` | 1400x560 RGB | Marquee promo tile, same design as small B. |
| `promo-marquee-c-peach.png` | 1400x560 RGB | Marquee promo tile, same design as small C. |
| `review-sheet.png` | 1500x1680 RGB | Contact sheet for picking a variant. Not a listing asset. |

Pick one variant (A, B or C) and upload its small tile and its marquee together.
Text is set in the fonts the app bundles: Caprasimo for the wordmark, Figtree
SemiBold for the sub-line (`assets/fonts/`, OFL).

## Regenerate

```bash
python3 tool/build_chrome_web_store_assets.py
```

Needs Python 3 with Pillow, nothing else. The script draws the mark with the
painter in `tool/build_app_icon_family.py` and copies `store-icon-128.png` from
`assets/logo/app_icon_family/ext-128.png`, so regenerate the icon family first
if the icon itself changed.

## Where each file goes

Chrome Web Store Developer Dashboard > the item > **Store listing** tab >
**Graphic assets**:

| Dashboard field | Required size | File |
| --- | --- | --- |
| Store icon | 128x128 | `store-icon-128.png` |
| Screenshots | 1280x800 | `desktop/browser_extension/store_assets/screenshots/` |
| Small promo tile | 440x280 | one `promo-small-*.png` |
| Marquee promo tile | 1400x560 | the matching `promo-marquee-*.png` |

Promo tiles, screenshots and the store icon field are uploaded by hand in the
dashboard and take effect once the listing change is reviewed. The icons inside
the extension ZIP (`desktop/browser_extension/icons/`) only reach users with a
new extension release.
