cargo_options = [
  '--manifest-path', meson.project_source_root() / '..' / 'Cargo.toml',
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

# The About dialog embeds the metainfo Meson installs, with its
# translations, rather than build.rs rendering the template untranslated.
app_env = cargo_env
app_env.set('TABLEPRO_METAINFO', metainfo_file.full_path())

custom_target(
  'cargo-build',
  build_always_stale: true,
  build_by_default: true,
  console: true,
  output: ['tablepro', 'tablepro-askpass'],
  env: app_env,
  depends: metainfo_file,
  command: [
    find_program(meson.project_source_root() / 'build-aux' / 'cargo-build.sh'),
    cargo_built / 'tablepro', '@OUTPUT0@',
    cargo_built / 'tablepro-askpass', '@OUTPUT1@',
    '--',
    cargo, 'build', '-p', 'tablepro', '-p', 'tablepro-ssh',
  ] + cargo_options,
  install: true,
  install_dir: [bindir, libexecdir],
)

test_env = cargo_env
if profile != 'development'
  # With --release every test binary goes through the release profile's
  # fat LTO, which takes gigabytes and minutes per binary and runs a
  # package build out of memory. The installed binaries keep it.
  test_env.set('CARGO_PROFILE_RELEASE_LTO', 'off')
endif

# windows.yml tests tablepro-ffi, whose binaries each link every engine and filled a package builder's disk.
# tablepro-bindgen is the macOS build's generator, and uniffi's CLI changes the build dependencies'
# features, so the gtk suite then built DuckDB's C++ again.
workspace_packages = [
  '--workspace',
  '--exclude', 'tablepro',
  '--exclude', 'tablepro-ffi',
  '--exclude', 'tablepro-bindgen',
]

# nextest's ci profile kills a test that hangs and names it within
# minutes. Under cargo test a hung test holds the suite until Meson's
# timeout and names nothing. The package builders have no nextest.
nextest = find_program('cargo-nextest', required: false)
if nextest.found()
  workspace_args = ['nextest', 'run', '--profile', 'ci'] + cargo_options + workspace_packages
else
  workspace_args = ['test'] + cargo_options + workspace_packages
endif

# The workspace suite excludes the app, whose tests need a display and
# the GTK test accessibility backend. A package build compiles its tests in
# the release profile, DuckDB's C++ a second time among them, which took
# more than an hour on a 4-core builder with DuckDB 2.0.
test(
  'workspace',
  cargo,
  args: workspace_args,
  env: test_env,
  suite: 'unit',
  is_parallel: false,
  timeout: 7200,
)

# nextest runs no doc tests.
if nextest.found()
  test(
    'workspace-doc',
    cargo,
    args: ['test', '--doc'] + cargo_options + workspace_packages,
    env: test_env,
    suite: 'unit',
    is_parallel: false,
    timeout: 3600,
  )
endif

gtk_env = app_env
if profile != 'development'
  gtk_env.set('CARGO_PROFILE_RELEASE_LTO', 'off')
endif
# Tests never reach PostHog. The integration tests and the binary they
# start are not built with cfg(test), so they get no key from here.
gtk_env.set('TABLEPRO_POSTHOG_KEY', '')
gtk_env.set('GSK_RENDERER', 'cairo')
gtk_env.set('GTK_A11Y', 'test')
# The key tests press real keys through XTEST, which only an X11 display
# hands to GDK.
gtk_env.set('GDK_BACKEND', 'x11')
# meson devenv sets GSETTINGS_SCHEMA_DIR and meson test does not, so the
# suite points at the build tree itself.
gtk_env.set('GSETTINGS_SCHEMA_DIR', meson.project_build_root() / 'data')
# Inside Flatpak GLib sends notifications through the portal; the suite
# answers them with a freedesktop server of its own on its own bus.
gtk_env.set('GNOTIFICATION_BACKEND', 'freedesktop')

# A session bus of the suite's own, so its names and notifications never
# reach the desktop it runs on, and a build sandbox without a bus still
# has one. A build that skips the tests need not install dbus.
gtk_program = cargo
gtk_args = ['test'] + cargo_options + ['-p', 'tablepro']
dbus_run_session = find_program('dbus-run-session', required: false)
if dbus_run_session.found()
  gtk_program = dbus_run_session
  gtk_args = ['--', cargo.full_path()] + gtk_args
endif

test(
  'app',
  gtk_program,
  args: gtk_args,
  env: gtk_env,
  depends: [compiled_schemas, metainfo_file],
  suite: 'gtk',
  is_parallel: false,
  timeout: 3600,
)

# The code that measures and places things, again at the scale a 200%
# display gives GDK, so a size worked out in device pixels rather than
# logical ones fails here and not only on a HiDPI screen.
gtk_scale_env = gtk_env
gtk_scale_env.set('GDK_SCALE', '2')

test(
  'app-scale-2',
  gtk_program,
  args: gtk_args + [
    '--lib',
    '--',
    'ui::data_grid::',
    'ui::diagram::',
    'ui::editor::editor_view::',
    'ui::window_geometry::',
  ],
  env: gtk_scale_env,
  depends: [compiled_schemas, metainfo_file],
  suite: 'gtk',
  is_parallel: false,
  timeout: 3600,
)
