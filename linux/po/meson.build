xgettext = find_program('xgettext', required: false)

if xgettext.found()
  xgettext_version = run_command(xgettext, '--version', check: false).stdout().split('\n')[0].split(' ')[-1]
  if xgettext_version.version_compare('< 0.24')
    warning(
      'xgettext @0@ predates 0.24, which taught xgettext to read Rust. Regenerating the POT needs 0.24 or newer.'.format(
        xgettext_version,
      ),
    )
  endif
endif

# The app calls gettextrs directly, plus the `_f` wrappers in
# crates/app/src/i18n.rs that translate and then fill `{name}`
# placeholders. xgettext knows the plain names already; the wrappers
# have to be named, with the argument that carries the msgid. A
# context argument is `1c`, a plural is the second number.
i18n.gettext(
  meson.project_name(),
  preset: 'glib',
  args: [
    '--keyword=gettext_f',
    '--keyword=ngettext_f:1,2',
    '--keyword=pgettext_f:1c,2',
    '--from-code=UTF-8',
    '--add-comments=Translators:',
    '--package-name=' + meson.project_name(),
    '--package-version=' + meson.project_version(),
    '--msgid-bugs-address=https://github.com/TableProApp/TablePro/issues',
    '--directory=' + meson.project_source_root(),
  ],
)
