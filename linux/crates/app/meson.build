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

# One build of the tests serves every cargo suite, so they share one
# build environment: a variable a build script or option_env! reads, set
# differently, would rebuild the crate. The suites differ only at run time.
test_env = app_env
if profile != 'development'
  # With --release every test binary goes through the release profile's
  # fat LTO, which takes gigabytes and minutes per binary and runs a
  # package build out of memory. With its one codegen unit LLVM spends 16
  # minutes on the app crate's unit tests at over 7 GB, beside the
  # library's rustc and the test links, which ran a 16 GB arm64 builder
  # out of memory. Cargo's release default of 16 compiles the crate three
  # times as fast. The installed binaries keep both.
  test_env.set('CARGO_PROFILE_RELEASE_LTO', 'off')
  test_env.set('CARGO_PROFILE_RELEASE_CODEGEN_UNITS', '16')
endif
# Tests never reach PostHog. The integration tests and the binary they
# start are not built with cfg(test), so they get no key from here.
test_env.set('TABLEPRO_POSTHOG_KEY', '')

# windows.yml tests tablepro-ffi, whose binaries each link every engine and filled a package builder's disk.
# tablepro-bindgen is the macOS build's generator, and uniffi's CLI changes the build dependencies'
# features, so the gtk suite then built DuckDB's C++ again.
# Each suite selects all of these packages: Cargo unifies features over the selected packages, and the app's
# own selection built 244 crates again on a package builder. A target runner picks each suite's tests instead.
test_packages = [
  '--workspace',
  '--exclude', 'tablepro-ffi',
  '--exclude', 'tablepro-bindgen',
]

# A test's timeout runs from the start of its command, and a package build
# compiles the tests in the release profile: more than an hour on a
# builder, against minutes for the run. meson test and ninja test first
# build a test's depends, with no timeout.
cargo_tests = custom_target(
  'cargo-tests',
  build_always_stale: true,
  build_by_default: false,
  console: true,
  output: 'cargo-tests.stamp',
  env: test_env,
  depends: metainfo_file,
  command: [
    find_program(meson.project_source_root() / 'build-aux' / 'cargo-test-build.sh'),
    '@OUTPUT@',
    '--',
    cargo, 'test', '--no-run',
  ] + cargo_options + test_packages,
)

# The host's own triple, since a triple's runner takes precedence over a
# cfg() one, and --config over the environment.
host_triple = ''
foreach line : run_command(meson.get_compiler('rust').cmd_array(), '-vV', check: true).stdout().split('\n')
  if line.startswith('host: ')
    host_triple = line.substring(6).strip()
  endif
endforeach
if host_triple == ''
  error('rustc -vV names no host')
endif
test_runner = meson.project_source_root() / 'build-aux' / 'cargo-test-runner.sh'
skip_app = ['--config', 'target.@0@.runner = ["@1@", "skip", "tablepro"]'.format(host_triple, test_runner)]
only_app = ['--config', 'target.@0@.runner = ["@1@", "only", "tablepro"]'.format(host_triple, test_runner)]

# nextest's ci profile kills a test that hangs and names it within
# minutes. Under cargo test a hung test holds the suite until Meson's
# timeout and names nothing. The package builders have no nextest.
nextest = find_program('cargo-nextest', required: false)
if nextest.found()
  workspace_args = ['nextest', 'run', '--profile', 'ci'] + cargo_options + test_packages + ['-E', 'not package(tablepro)']
else
  workspace_args = skip_app + ['test'] + cargo_options + test_packages
endif

# The workspace suite leaves out the app, whose tests need a display and
# the GTK test accessibility backend.
test(
  'workspace',
  cargo,
  args: workspace_args,
  env: test_env,
  depends: cargo_tests,
  suite: 'unit',
  is_parallel: false,
  timeout: 7200,
)

# nextest runs no doc tests.
if nextest.found()
  test(
    'workspace-doc',
    cargo,
    args: skip_app + ['test', '--doc'] + cargo_options + test_packages,
    env: test_env,
    depends: cargo_tests,
    suite: 'unit',
    is_parallel: false,
    timeout: 3600,
  )
endif

gtk_env = test_env
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
gtk_args = only_app + ['test'] + cargo_options + test_packages
dbus_run_session = find_program('dbus-run-session', required: false)
if dbus_run_session.found()
  gtk_program = dbus_run_session
  gtk_args = ['--', cargo.full_path()] + gtk_args
endif

# The workspace suite runs the doc tests, of which the app has none.
test(
  'app',
  gtk_program,
  args: gtk_args + ['--lib', '--bins', '--tests'],
  env: gtk_env,
  depends: [compiled_schemas, metainfo_file, cargo_tests],
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
  depends: [compiled_schemas, metainfo_file, cargo_tests],
  suite: 'gtk',
  is_parallel: false,
  timeout: 3600,
)
