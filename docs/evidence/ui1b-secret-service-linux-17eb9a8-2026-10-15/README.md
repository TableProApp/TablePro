# UI-1b Secret Service checks on current Linux

Source: `17eb9a8754fad87fcbd25678ca484bcf810d3eae` (`fork/linux`).

Command: `bash scripts/test-secret-service.sh`.

The script completed successfully. It used a private D-Bus session, temporary home and keyring; it did not access the desktop keyring. The isolated keyring tier reported 14 tests executed successfully.

The run also passed focused checks for per-hop password selection, per-hop SSH key passphrases, refusal when a jump-hop passphrase is missing, saved-hop transport use, and bundle credential preservation/removal on rollback.

This is source-build/keyring evidence. It does not exercise the GTK SSH editor, installed package or native Wayland flow. Keep editing refused until the complete GTK editor path passes, as required by [issue #548](https://github.com/cozyGarage/BookiE/issues/548).
