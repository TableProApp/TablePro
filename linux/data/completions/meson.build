# The built binary prints each script, so it always matches the binary's
# commands. Flatpak exports no completions, and its users type
# `flatpak run app.tablepro.TablePro`, which a tablepro completion does not
# match. The directories are the ones bash-completion, zsh and fish read on
# Fedora; debian/rules moves the zsh one to Debian's vendor-completions.
if not get_option('flatpak')
  completions = {
    'bash': ['tablepro', get_option('datadir') / 'bash-completion' / 'completions'],
    'zsh': ['_tablepro', get_option('datadir') / 'zsh' / 'site-functions'],
    'fish': ['tablepro.fish', get_option('datadir') / 'fish' / 'vendor_completions.d'],
  }
  foreach shell, place : completions
    custom_target(
      'completion-' + shell,
      output: place[0],
      command: [tablepro_binaries[0], 'completion', shell],
      capture: true,
      install: true,
      install_dir: place[1],
    )
  endforeach
endif
