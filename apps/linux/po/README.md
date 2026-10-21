# Translations

BookiE uses [GNU gettext](https://www.gnu.org/software/gettext/) for
localisation. Source strings are wrapped at the call site with the `tr!`
macro defined in `apps/linux/app/src/i18n.rs`; at runtime
`bindtextdomain("bookie", …)` points gettext at the locale directory
shipped by the package (`/app/share/locale` under Flatpak,
`/usr/share/locale` for system installs, or `$TABLEPRO_LOCALEDIR` for
ad-hoc testing).

## Adding a new translation

1. Pick a locale code (e.g. `vi`, `de`, `pt_BR`).
2. Add it on its own line to [`LINGUAS`](LINGUAS).
3. Copy `bookie.pot` to `xx.po` and translate the entries:

   ```sh
   msginit --locale=xx --input=apps/linux/po/bookie.pot --output=apps/linux/po/xx.po
   ```

4. Compile and install (the package build does this automatically; for
   local testing):

   ```sh
   mkdir -p ~/.local/share/locale/xx/LC_MESSAGES
   msgfmt apps/linux/po/xx.po -o ~/.local/share/locale/xx/LC_MESSAGES/bookie.mo
   TABLEPRO_LOCALEDIR=~/.local/share/locale cargo run -p tablepro-app
   ```

## The template, bookie.pot

`bookie.pot` is not committed. It is generated from the `tr!` calls, so it can never be stale or conflict between pull requests. CI and the release workflow build it; every release attaches it as `bookie.pot`. Generate it locally using GNU gettext
with Rust support (the helper normalizes namespaced macro calls in temporary
copies so `xgettext` can extract them):

```sh
python3 scripts/update-translations.py
```

Use `msgmerge` to fold new strings into existing translations:

```sh
for f in apps/linux/po/*.po; do msgmerge --update "$f" apps/linux/po/bookie.pot; done
```

## Notes

- Only literal arguments to `tr!` are extracted. Avoid runtime
  composition; use a fixed template and pass it through `format!` after
  translation.
- Strings shipped before this i18n infrastructure landed are still in
  English-as-source. They need to be wrapped in `tr!` to participate in
  translation; this is being done incrementally.
