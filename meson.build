project('bookie', version: '0.1.6-dev', meson_version: '>=1.4', license: 'AGPL-3.0-or-later')

gnome = import('gnome')
subdir('data')
install_data('data/com.tablepro.linux.gschema.xml', install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')
python = find_program('python3')
dependency('glib-2.0', version: '>=2.88')
dependency('gio-2.0', version: '>=2.88')
dependency('gtk4', version: '>=4.22')
dependency('libadwaita-1', version: '>=1.9')
dependency('gtksourceview-5', version: '>=5.18')
dependency('sqlite3', version: '>=3.46')
if get_option('kerberos')
  dependency('mit-krb5-gssapi')
endif

profile = get_option('profile')
application_id = 'com.tablepro.linux'
if profile == 'development'
  application_id += '.Devel'
endif
cargo_env = environment()
cargo_env.set('CARGO_TARGET_DIR', meson.project_build_root() / 'cargo-target')
cargo_env.set('TABLEPRO_APP_ID', application_id)
cargo_env.set('TABLEPRO_PROFILE', profile)
cargo_env.set('TABLEPRO_VERSION', meson.project_version())
cargo_env.set('TABLEPRO_LOCALEDIR', get_option('prefix') / get_option('localedir'))

custom_target('cargo-build',
  build_always_stale: true,
  build_by_default: true,
  console: true,
  output: ['bookie', 'bookie-agentd', 'tablepro-askpass'],
  env: cargo_env,
  command: [find_program('python3'), files('scripts/meson-cargo-build.py'),
    meson.project_source_root(), profile, get_option('kerberos').to_string(), '@OUTPUT0@', '@OUTPUT1@', '@OUTPUT2@'],
  install: true,
  install_dir: [get_option('bindir'), get_option('bindir'), get_option('bindir')],
)
install_symlink('tablepro', pointing_to: 'bookie', install_dir: get_option('bindir'))
install_symlink('tablepro-agentd', pointing_to: 'bookie-agentd', install_dir: get_option('bindir'))
desktop_file = configure_file(
  input: 'flatpak/com.tablepro.linux.desktop',
  output: application_id + '.desktop',
  command: [python, files('scripts/configure-app-id.py'), '@INPUT@', '@OUTPUT@', application_id],
  install: true,
  install_dir: get_option('datadir') / 'applications',
)
metainfo_file = configure_file(
  input: 'flatpak/com.tablepro.linux.metainfo.xml',
  output: application_id + '.metainfo.xml',
  command: [python, files('scripts/configure-app-id.py'), '@INPUT@', '@OUTPUT@', application_id],
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)
install_data(
  'flatpak/icons/scalable/com.tablepro.linux.svg',
  rename: application_id + '.svg',
  install_dir: get_option('datadir') / 'icons/hicolor/scalable/apps',
)
install_data('LICENSE.md', install_dir: get_option('datadir') / 'licenses/bookie')
install_data('packaging/policy.example.toml', install_dir: get_option('datadir') / 'doc/bookie')
meson.add_devenv(cargo_env)
gnome.post_install(glib_compile_schemas: true, gtk_update_icon_cache: true, update_desktop_database: true)
