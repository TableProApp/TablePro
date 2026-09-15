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

# `tr!` is the crate's own gettext macro; the glib preset covers the
# C and GLib keywords the preset already knows about.
i18n.gettext(
  meson.project_name(),
  preset: 'glib',
  args: [
    '--keyword=tr',
    '--keyword=tr:1',
    '--from-code=UTF-8',
    '--add-comments=Translators:',
    '--package-name=' + meson.project_name(),
    '--package-version=' + meson.project_version(),
    '--msgid-bugs-address=https://github.com/TableProApp/TablePro/issues',
    '--directory=' + meson.project_source_root(),
  ],
)
