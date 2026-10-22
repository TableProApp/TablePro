# Editor callback lifetime, 2026-10-22

Related: [#1333](https://github.com/cozyGarage/BookiE/issues/1333). Earlier allocation measurements are in [the lifetime investigation](../editor-lifetime-investigation-2026-10-22/README.md).

## Controlled reproduction

Plain GTK TextView and GtkSourceView controls retained native references under the default input method in the isolated X11 environment. Button and Entry controls released normally. Clearing window focus did not change this. With the process-local simple input method, all controls released. Selecting the simple input method on each TextView through its widget property also made those controls release. The environment used GTK 4.24.1, GtkSourceView 5.22.0 and libadwaita 1.10.0.

The regression selects the simple input method only on its fixture views and first requires a plain native SourceView to release. Under that controlled setup, the unfixed editor root released but its source view remained alive after dropping the component. After the callback correction, the root, view and buffer all release. Both runs used the same test, with no process-global input-method override. This isolates application retention from the separate native input-method behaviour.

## Cause and candidate

Buffer callbacks captured their owning source view, while the view owned the buffer. The completion refresh closure also captured the view strongly. Find/Replace callbacks retained handles containing their own search context, and the search entry callback captured its own entry.

Cursor and changed handlers now use their buffer argument. Completion refresh keeps a weak view reference. Find/Replace signal handles keep weak references and upgrade them only for the duration of an action. The component retains ownership while it is alive. Production input-method selection is unchanged; there is no forced widget disposal.

The narrow failing-before regression reported `editor view remains alive`; the corrected test passed. Full preflight, application all-target Clippy and all 105 registered GTK widget tests passed. All 718 app unit tests also passed. Matched optimized measurements follow below. No native desktop performance or complete freeze resolution is claimed.

## Diagnostic input-method comparison

Using the previously recorded optimized binary, six editor cycles passed with process-local `GTK_IM_MODULE=simple`: 57.16 MB peak tracked heap, 261.55 MB peak RSS including Heaptrack overhead and 47.67 MB outstanding at graceful exit. The default-input-method run left 49.29 MB outstanding. The diagnostic setting therefore explains part of the observed retention, but is not a product fix and does not replace multilingual input support. GTK documents the setting in [Running and debugging GTK applications](https://gnome.pages.gitlab.gnome.org/gtk/gtk4/running.html).

Raw traces, native control scripts and failing/passing logs remain in the persistent local `bookie-test` profiling directory. All interaction used isolated Xvfb. No native desktop input or capture occurred.


## Matched optimized measurements

Baseline source: `09a600d5fa078dc9c0984a4aa6d6e59f29034469`. Candidate source: `1bf138230` (the callback fix). Binary identities, all ten run outcomes, raw-artifact hashes and per-cycle direct samples are in [paired-measurements.json](paired-measurements.json). All scenarios passed. The same six cycles close 24 editors and finish with a successful query and graceful quit.

### Small query buffers

| Measurement | Baseline | Candidate |
| --- | ---: | ---: |
| Default input method, peak tracked heap | 58.64 MB | 58.34 MB |
| Default input method, outstanding tracked memory at exit | 49.34 MB | 48.74 MB |
| Default input method, final direct RSS | 188.32 MiB | 198.45 MiB |
| Default input method, direct CPU seconds | 6.91 | 6.86 |
| Simple input method, peak tracked heap | 57.15 MB | 54.38 MB |
| Simple input method, outstanding tracked memory at exit | 47.69 MB | 44.16 MB |
| Simple input method, final direct RSS | 187.36 MiB | 179.61 MiB |
| Simple input method, direct CPU seconds | 12.49 | 9.23 |

The default-input-method pair did not demonstrate a consistent RSS improvement: candidate final RSS was higher despite slightly lower tracked heap. Record that result rather than treating object release as proof of overall RSS reduction. The process-local simple-input-method diagnostic separates the native control retention from the application callbacks; it is not a recommended product setting.

### Large editor contents

Each editor executed its small query, then received 1,040,009 bytes of comment-heavy SQL text before closing. The final reopened editor received the same text after its final query. This measures editor-content retention, not execution of a megabyte query or SQL file loading. These direct runs use the simple input method and contain no Heaptrack overhead.

| Measurement | Baseline | Candidate |
| --- | ---: | ---: |
| Initial RSS | 167.32 MiB | 163.30 MiB |
| RSS after the first four editors closed | 225.47 MiB | 216.31 MiB |
| RSS after the final four editors closed | 347.84 MiB | 223.91 MiB |
| Final RSS with the reopened editor | 352.99 MiB | 227.62 MiB |
| Process high-water RSS | 355.43 MiB | 229.38 MiB |
| CPU seconds between initial and final samples | 34.41 | 28.09 |
| Elapsed seconds between those samples | 58.69 | 52.40 |

This larger-text diagnostic supports the callback-retention fix. Each case is one sequential run on a shared host, without statistical repetition or a native Wayland session. The small/default-input-method result limits broader performance claims. Native desktop, actual file-open performance and large-result streaming remain separate acceptance work.

The exact large-text interaction is preserved in [large-editor-cycles.py](large-editor-cycles.py). Run it from the repository root inside a private D-Bus/Xvfb session, with `GTK_IM_MODULE=simple`, `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon`, `GDK_BACKEND=x11`, `GSK_RENDERER=cairo`, `GTK_A11Y=atspi` and `TABLEPRO_GTK_ARTIFACT_DIR` pointing to an empty artifact directory. Pass the optimized binary as its only argument. The fixture creates a disposable database and profile. The helper uses actual pointer input only on that isolated display.
