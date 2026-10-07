# zocalo-sftp — website

This branch (`gh-pages`) is the static marketing site for [zocalo-sftp](https://github.com/wiesion/zocalo-sftp),
served from GitHub Pages at **zocalo-sftp.com**. It is an orphan branch: no shared history with `main`,
and the project source lives on `main`, never here.

## Preview locally

No build step. From this directory:

```bash
python3 -m http.server 8080
```

then open http://localhost:8080. (Direct `file://` also works; the server is only needed if you
want to test absolute-path behaviour exactly as Pages serves it.)

## GitHub Pages settings

Repository → Settings → Pages:

- **Source:** Deploy from a branch
- **Branch:** `gh-pages`, folder **`/ (root)`**
- **Custom domain:** `zocalo-sftp.com`
- **Enforce HTTPS:** on

After adding the custom domain, Pages generates the certificate automatically. The `CNAME` file at the
branch root already contains `zocalo-sftp.com`.

## Pushing

```bash
git push -u origin gh-pages
```

## Contents

- `index.html` — the whole site (single page)
- `imprint.html` — legal notice / contact / privacy. **Contains placeholders the maintainer must fill in**
  (name, address, email) before publishing.
- `404.html` — custom 404 page
- `css/site.css`, `js/site.js` — hand-rolled, no framework, no dependencies
- `assets/` — SVG logo, favicon, Open Graph image (PNG + SVG source). The how-it-works
  diagram is inline SVG in `index.html` (themable via CSS variables).
- `CNAME`, `.nojekyll`, `robots.txt`, `sitemap.xml` — Pages plumbing

The site sets no cookies, loads no third-party resources, and is fully usable with JavaScript disabled
(copy buttons, tabs and the theme toggle degrade gracefully).
