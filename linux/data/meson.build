substitutions = configuration_data()
substitutions.set('app-id', application_id)
substitutions.set('bindir', bindir)
substitutions.set('gettext-package', meson.project_name())
substitutions.set('version', meson.project_version())

desktop_file_in = configure_file(
  input: 'app.tablepro.TablePro.desktop.in.in',
  output: application_id + '.desktop.in',
  configuration: substitutions,
)

desktop_file = i18n.merge_file(
  input: desktop_file_in,
  output: application_id + '.desktop',
  type: 'desktop',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: get_option('datadir') / 'applications',
)

metainfo_file_in = configure_file(
  input: 'app.tablepro.TablePro.metainfo.xml.in.in',
  output: application_id + '.metainfo.xml.in',
  configuration: substitutions,
)

metainfo_file = i18n.merge_file(
  input: metainfo_file_in,
  output: application_id + '.metainfo.xml',
  type: 'xml',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

configure_file(
  input: 'app.tablepro.TablePro.service.in',
  output: application_id + '.service',
  configuration: substitutions,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services',
)

# The schema id and path follow the application ID, so a development
# build never reads or writes an installed release's settings.
schema_substitutions = configuration_data()
schema_substitutions.set('app-id', application_id)
schema_substitutions.set('schema-path', '/' + application_id.replace('.', '/') + '/')

schema_file = configure_file(
  input: 'app.tablepro.TablePro.gschema.xml.in',
  output: application_id + '.gschema.xml',
  configuration: schema_substitutions,
  install: true,
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

glib_compile_schemas = find_program('glib-compile-schemas')

# gnome.compile_schemas reads the source directory, which holds only the
# template. --strict makes an invalid schema fail the build.
compiled_schemas = custom_target(
  'gschemas.compiled',
  input: schema_file,
  output: 'gschemas.compiled',
  command: [glib_compile_schemas, '--strict', '--targetdir', meson.current_build_dir(), meson.current_build_dir()],
  build_by_default: true,
)
meson.add_devenv({'GSETTINGS_SCHEMA_DIR': meson.current_build_dir()})

install_data(
  'icons' / 'hicolor' / 'scalable' / 'apps' / application_id + '.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
  rename: application_id + '.svg',
)

install_data(
  'icons' / 'hicolor' / 'symbolic' / 'apps' / 'app.tablepro.TablePro-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps',
  rename: application_id + '-symbolic.svg',
)

install_man('tablepro.1')

# The .deb and .rpm ship the notices as their own license files.
# flatpak-builder installs only LICENSE, under <app id>/<module name>.
if get_option('flatpak')
  install_data(
    'licenses' / 'THIRD-PARTY-NOTICE.md',
    'licenses' / 'NOTICE',
    install_dir: get_option('datadir') / 'licenses' / application_id,
  )
endif

if get_option('flatpak') and get_option('kerberos')
  install_data(
    meson.project_source_root() / 'build-aux' / 'flatpak' / 'krb5.conf',
    install_dir: get_option('sysconfdir'),
  )
endif

desktop_file_validate = find_program('desktop-file-validate', required: false)
if desktop_file_validate.found()
  test(
    'validate-desktop',
    desktop_file_validate,
    args: [desktop_file],
    suite: 'data',
  )
endif

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test(
    'validate-appstream',
    appstreamcli,
    args: ['validate', '--no-net', '--explain', metainfo_file],
    suite: 'data',
  )
endif
