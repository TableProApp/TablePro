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

cargo_built = cargo_target_dir / cargo_profile_dir

cargo_build_command = ' '.join(
  [cargo.full_path(), 'build', '-p', 'tablepro', '-p', 'tablepro-ssh'] + cargo_options,
)

custom_target(
  'cargo-build',
  build_always_stale: true,
  build_by_default: true,
  console: true,
  output: ['tablepro', 'tablepro-askpass'],
  env: cargo_env,
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

gtk_env = cargo_env
gtk_env.set('GSK_RENDERER', 'cairo')
gtk_env.set('GTK_A11Y', 'test')

test(
  'app',
  cargo,
  args: ['test'] + cargo_options + ['-p', 'tablepro'],
  env: gtk_env,
  suite: 'gtk',
  is_parallel: false,
  timeout: 3600,
)
