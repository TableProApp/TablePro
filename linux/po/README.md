# Translations

TablePro Linux uses [GNU gettext](https://www.gnu.org/software/gettext/) for
localisation. Source strings are wrapped at the call site with the `tr!`
macro defined in `crates/app/src/i18n.rs`; at runtime
`bindtextdomain("tablepro", …)` points gettext at the locale directory
shipped by the package (`/app/share/locale` under Flatpak,
`/usr/share/locale` for system installs, or `$TABLEPRO_LOCALEDIR` for
ad-hoc testing).

## Adding a new translation

1. Pick a locale code (e.g. `vi`, `de`, `pt_BR`).
2. Add it on its own line to [`LINGUAS`](LINGUAS).
3. Copy `tablepro.pot` to `xx.po` and translate the entries:

   ```sh
   msginit --locale=xx --input=po/tablepro.pot --output=po/xx.po
   ```

4. Compile and install (the package build does this automatically; for
   local testing):

   ```sh
   mkdir -p ~/.local/share/locale/xx/LC_MESSAGES
   msgfmt po/xx.po -o ~/.local/share/locale/xx/LC_MESSAGES/tablepro.mo
   TABLEPRO_LOCALEDIR=~/.local/share/locale cargo run -p tablepro
   ```

## Regenerating tablepro.pot

`tablepro.pot` is the master template. Regenerate it with
[`xtr`](https://crates.io/crates/xtr):

```sh
cargo install xtr
xtr --keyword=tr --output=po/tablepro.pot $(cat po/POTFILES.in)
```

Use `msgmerge` to fold new strings into existing translations:

```sh
for f in po/*.po; do msgmerge --update "$f" po/tablepro.pot; done
```

## Notes

- Only literal arguments to `tr!` are extracted. Avoid runtime
  composition; use a fixed template and pass it through `format!` after
  translation.
- Strings shipped before this i18n infrastructure landed are still in
  English-as-source. They need to be wrapped in `tr!` to participate in
  translation; this is being done incrementally.
