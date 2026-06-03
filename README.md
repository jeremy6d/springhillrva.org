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

1. Create a form at [formspree.io](https://formspree.io).
2. Set `formspree_endpoint` in `_config.yml` to your form URL (e.g. `https://formspree.io/f/xxxxxxxx`).

## Deployment

Pushes to `main` deploy via GitHub Actions. Add a `CNAME` in the repo for `www.springhillrva.org` and point DNS at GitHub Pages.
