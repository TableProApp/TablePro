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

tablepro_binaries = custom_target(
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

# One build of the tests serves both cargo tests, so they share one build
# environment: a variable a build script or option_env! reads, set
# differently, would rebuild the crate. The tests differ only at run time.
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
# features, so the tests then built DuckDB's C++ again.
# Both tests select the same packages: Cargo unifies features over the selected packages, and a
# selection of the app alone built 244 crates again on a package builder.
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
test_program = cargo
test_args = ['test'] + cargo_options + test_packages
dbus_run_session = find_program('dbus-run-session', required: false)
if dbus_run_session.found()
  test_program = dbus_run_session
  test_args = ['--', cargo.full_path()] + test_args
endif

# The app's tests need a display, the GTK test accessibility backend and a
# bus; the core's run the same under them. cargo test runs the app's
# library tests in one process, which they need: under nextest's process
# per test, windows on the shared display take each other's focus. A hung
# test holds the suite until its timeout. The runs took 3 to 5 minutes on
# the GitHub runners, and COPR's aarch64 builders are about 4.5 times as slow.
test(
  'workspace',
  test_program,
  args: test_args,
  env: gtk_env,
  depends: [compiled_schemas, metainfo_file, cargo_tests],
  suite: 'cargo',
  is_parallel: false,
  timeout: 3600,
)

# The code that measures and places things, again at the scale a 200%
# display gives GDK, so a size worked out in device pixels rather than
# logical ones fails here and not only on a HiDPI screen. Only the app has
# ui modules. The run took under 30 seconds on the GitHub runners.
gtk_scale_env = gtk_env
gtk_scale_env.set('GDK_SCALE', '2')

test(
  'app-scale-2',
  test_program,
  args: test_args + [
    '--lib',
    '--',
    'ui::data_grid::',
    'ui::diagram::',
    'ui::editor::editor_view::',
    'ui::window_geometry::',
  ],
  env: gtk_scale_env,
  depends: [compiled_schemas, metainfo_file, cargo_tests],
  suite: 'cargo',
  is_parallel: false,
  timeout: 600,
)
