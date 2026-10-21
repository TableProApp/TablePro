xgettext = find_program('xgettext', required: false)

if xgettext.found()
  xgettext_version = run_command(xgettext, '--version', check: false).stdout().split('\n')[0].split(' ')[-1]
  if xgettext_version.version_compare('< 1.0')
    warning(
      'xgettext @0@ predates 1.0, the first that reads a call through a path such as crate::i18n::gettext. Generating the POT needs 1.0 or newer.'.format(
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
    # msgmerge copies these references into the committed .po files, where
    # line numbers would make every edit above a string count as a change.
    '--add-location=file',
    '--add-comments=Translators:',
    '--package-name=' + meson.project_name(),
    '--package-version=' + meson.project_version(),
    '--msgid-bugs-address=https://github.com/TableProApp/TablePro/issues',
    '--directory=' + meson.project_source_root(),
  ],
)

# The build compiles each catalogue without --check. gettext 0.26 and
# newer also check the {name} placeholders of every rust-format entry.
msgfmt = find_program('msgfmt', required: false)
if msgfmt.found()
  fs = import('fs')
  foreach line : fs.read('LINGUAS').split('\n')
    foreach lang : line.split('#')[0].split()
      test(
        'po-' + lang,
        msgfmt,
        args: ['--check', '--output-file=/dev/null', meson.current_source_dir() / lang + '.po'],
        suite: 'po',
      )
    endforeach
  endforeach
endif
