substitutions = configuration_data()
substitutions.set('app-id', application_id)
substitutions.set('bindir', bindir)
substitutions.set('gettext-package', meson.project_name())

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

install_data(
  'app.tablepro.TablePro.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

# depend_files is what ties the compiled schema to its source. Without
# it the schema is built once and never again, so a key added to the
# XML is missing at run time and the app aborts on first read.
compiled_schemas = gnome.compile_schemas(
  build_by_default: true,
  depend_files: files('app.tablepro.TablePro.gschema.xml'),
)

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

install_data(
  meson.project_source_root() / 'LICENSE',
  install_dir: get_option('datadir') / 'licenses' / application_id,
)

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

glib_compile_schemas = find_program('glib-compile-schemas', required: false)
if glib_compile_schemas.found()
  test(
    'validate-gschema',
    glib_compile_schemas,
    args: ['--strict', '--dry-run', meson.current_source_dir()],
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
