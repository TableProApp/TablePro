# Published AppImage resource check

Follow-up for [issue 1325](https://github.com/cozyGarage/BookiE/issues/1325). Downloaded the public linux-v0.2.0 AppImage and verified its published SHA256SUMS entry before extraction. The [result](result.json) pins both package and bundled library hashes.

The image contains no filesystem language-specification payload. Its bundled GtkSourceView is 5.22.0. With LD_LIBRARY_PATH pointed at the extracted usr/lib, fresh language/style managers restricted to resource:///org/gnome/gtksourceview/language-specs/ and resource:///org/gnome/gtksourceview/styles/ resolve SQL, Adwaita and Adwaita-dark. The process memory map confirms the bundled library was loaded. No host language or style search path was permitted.

This verifies embedded-resource availability in the actual published package, not editor keyword pixels or theme rendering. The Python GI metadata comes from the desktop. A clean-container launch of the actual AppImage editor remains unverified, so the issue remains open. No data-copy workaround is justified by this result.
