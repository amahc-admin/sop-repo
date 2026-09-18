# Vendored PDF.js (v4.7.76)

Self-hosted copy of Mozilla's [PDF.js](https://github.com/mozilla/pdf.js)
"GENERIC" build, used by the SOP detail page (`documentEmbedHtml` in
`web/index.html`) to preview uploaded PDF documents inline on every
device -- including mobile, where a plain `<iframe src="the-pdf-url">`
doesn't render (there's no native PDF-in-iframe plugin on phones the
way there is on desktop Chrome).

Downloaded from the tagged GitHub release
`https://github.com/mozilla/pdf.js/releases/download/v4.7.76/pdfjs-4.7.76-dist.zip`
-- a pinned stable release, not Mozilla's live `mozilla.github.io/pdf.js`
site, which tracks the unstable dev branch and broke outright in testing
(a JS engine feature it required wasn't available yet in a very recent
Chromium build).

## What's here vs. the original zip

Only what the viewer needs at runtime is kept -- `build/`, `web/viewer.*`,
`web/images/`, `web/standard_fonts/`, and an `en-US`-only `web/locale/`
(this app has no other language). Left out: source maps (`*.map`,
debug-only) and `web/cmaps/` (only needed for certain embedded CJK
fonts, not expected in this app's content -- add it back from the same
release zip if a PDF ever needs it).

## Local patch

`web/viewer.mjs` has one intentional edit, marked
`Cave Handbook patch` inline: PDF.js's built-in `validateFileURL` only
allows a cross-origin `?file=` URL when the viewer itself is hosted at
`mozilla.github.io` (their own demo deployment) -- anywhere else, it
requires the file to be same-origin as the viewer, as an anti-open-proxy
guard. Since every SOP document lives in Supabase Storage (always
`https://ekavaiissbgxcyvtorjz.supabase.co`), a different origin from
wherever this app is hosted, that check is extended to also trust that
one specific origin -- not disabled outright.

## Upgrading

To pull a newer release: download that version's `-dist.zip` from its
GitHub release page, replace this folder's contents the same way
(trim source maps, `cmaps/`, and all locales but `en-US`), then
re-apply the patch above to the new `web/viewer.mjs` (search for
`HOSTED_VIEWER_ORIGINS`).
