cargo_options = [
  '--manifest-path', meson.project_source_root() / 'Cargo.toml',
  '--locked',
]

if profile == 'development'
  cargo_profile_dir = 'debug'
else
  cargo_options += ['--release']
  cargo_profile_dir = 'release'
endif

if not get_option('kerberos')
  cargo_options += ['--no-default-features']
endif

cargo_config = get_option('cargo_config')
if cargo_config != ''
  cargo_config = meson.project_source_root() / cargo_config
  if not fs.is_file(cargo_config)
    error('cargo_config names @0@, which is not a file'.format(cargo_config))
  endif
  # Cargo resolves the relative paths inside the file against the parent
  # of the file's directory, which for vendor/cargo-config.toml is the
  # source root vendor/ sits in.
  cargo_options += ['--config', cargo_config]
endif

cargo_built = cargo_target_dir / cargo_profile_dir

# The About dialog embeds the metainfo Meson installs, with its
# translations, rather than build.rs rendering the template untranslated.
app_env = cargo_env
app_env.set('TABLEPRO_METAINFO', metainfo_file.full_path())

cargo_build_command = ' '.join(
  [cargo.full_path(), 'build', '-p', 'tablepro', '-p', 'tablepro-ssh'] + cargo_options,
)

custom_target(
  'cargo-build',
  build_always_stale: true,
  build_by_default: true,
  console: true,
  output: ['tablepro', 'tablepro-askpass'],
  env: app_env,
  depends: metainfo_file,
  command: [
    'sh',
    '-c',
    cargo_build_command
    + ' && cp ' + cargo_built / 'tablepro' + ' @OUTPUT0@'
    + ' && cp ' + cargo_built / 'tablepro-askpass' + ' @OUTPUT1@',
  ],
  install: true,
  install_dir: [bindir, libexecdir],
)

# The workspace suite excludes the app, whose tests need a display and
# the GTK test accessibility backend.
test(
  'workspace',
  cargo,
  args: ['test'] + cargo_options + ['--workspace', '--exclude', 'tablepro'],
  env: cargo_env,
  suite: 'unit',
  is_parallel: false,
  timeout: 3600,
)

gtk_env = app_env
gtk_env.set('GSK_RENDERER', 'cairo')
gtk_env.set('GTK_A11Y', 'test')
# The key tests press real keys through XTEST, which only an X11 display
# hands to GDK.
gtk_env.set('GDK_BACKEND', 'x11')
# gnome.compile_schemas exports GSETTINGS_SCHEMA_DIR to devenv only, so
# the suite points at the build tree itself.
gtk_env.set('GSETTINGS_SCHEMA_DIR', meson.project_build_root() / 'data')

test(
  'app',
  cargo,
  args: ['test'] + cargo_options + ['-p', 'tablepro'],
  env: gtk_env,
  depends: [compiled_schemas, metainfo_file],
  suite: 'gtk',
  is_parallel: false,
  timeout: 3600,
)
