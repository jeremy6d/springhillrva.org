# Springhill RVA

Neighborhood news site for Springhill, Richmond VA — built with [Jekyll](https://jekyllrb.com/) and deployed to GitHub Pages.

## Local development

```bash
bundle install
bundle exec jekyll serve
```

Open http://localhost:4000

## WordPress import

Content was imported from a WordPress WXR export:

```bash
ruby _scripts/import.rb _data/springhillrvaorg.WordPress.2026-02-16.xml
```

Images are fetched from the Internet Archive when the live `springhillrva.org` host no longer serves uploads.

## Contact form (Formspree)

The contact page posts to Formspree (`formspree_endpoint` in `_config.yml`). Field names: `name`, `email`, `phone`, `address`, `message`.

## Deployment

Pushes to `main` deploy via GitHub Actions.

**One-time setup:** In the repo on GitHub, open **Settings → Pages** and set **Build and deployment → Source** to **GitHub Actions**. Without that, `configure-pages` fails with `Get Pages site failed` / `Not Found`.

The repo `CNAME` is `www.springhillrva.org`; point DNS for `www` (and optionally the apex domain) at GitHub Pages.
