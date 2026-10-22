# Editor lifetime investigation, 2026-10-22

Related: [#1333](https://github.com/cozyGarage/BookiE/issues/1333). This investigation is incomplete and establishes no application-specific leak.

An initial isolated test launched the editor, dropped its controller, pumped the main context and checked weak references. The editor root was released, while the source view remained alive. Source review found strong view references captured by buffer callbacks and strong Find/Replace callback handles. Replacing these with weak references did not make the test pass. Keeping the test runtime alive separately did not make it pass either.

A control created a plain `sourceview5::View` without any BookiE editor component or application callbacks, dropped it, and waited five seconds for its weak reference to clear. That control also failed. Consequently, the editor test cannot presently distinguish application retention from the native toolkit lifecycle or test setup. Earlier descriptions of it as proof of an application-specific lifetime defect were too strong.

The unvalidated production callback changes were removed from the branch and preserved only as a local investigation patch. They are not proposed for merge. No test was weakened to accept retained widgets. Next steps are a realized-window disposal control and allocation tracing of repeated native-widget versus BookiE editor lifecycles.

Separately, an 18-cycle Xvfb scenario opened, queried and closed four editors per cycle, clicked the empty-state editor action and completed a final query. All functional checks passed. Process RSS grew from 165,268 KiB initially to 202,364 KiB finally. This supports continued investigation, but does not prove a leak or explain the native freeze. The source/binary identity matches the [six-cycle evidence](../tab-cycles-2026-10-22/manifest.json).

All interaction used isolated displays. No native desktop input or capture occurred. Raw control logs and the unvalidated patch remain local; they are not acceptance evidence for a fix.

## Realized-window control

A further control created a plain GTK TextView and a plain GtkSourceView in turn, placed each in an 800-by-600 window, presented it on an isolated 1280-by-1024 Xvfb display, pumped the main context, detached the child, destroyed the window and dropped the strong local references. After another second of main-context processing, weak upgrades still succeeded for both controls. Neither control used BookiE editor callbacks.

This strengthens the limitation of the current lifetime test: even a realized native widget fails its expected release assertion. It does not establish a GTK defect, because the test environment and native lifecycle assumptions remain unverified. No disposal workaround or application change is justified by this test alone. The experimental control is preserved locally, not registered as a passing contract or proposed as a product fix.


## Allocation tracing of editor cycles

The optimized binary identified in the six-cycle manifest was traced with `heaptrack --record-only`. Both a one-cycle control (four editor opens, queries and closes) and six cycles (24 editors) passed the same empty-state reopen and final-query checks, then quit gracefully. The comparison and artifact hashes are in [heaptrack-comparison.json](heaptrack-comparison.json).

| Measurement | One cycle | Six cycles |
| --- | ---: | ---: |
| Peak tracked heap | 53.60 MB | 58.67 MB |
| Peak RSS including profiler overhead | 258.43 MB | 268.48 MB |
| Outstanding tracked allocations at exit | 44.39 MB | 49.29 MB |
| Allocation calls | 5,265,108 | 22,581,160 |
| Instrumented runtime | 13.39 s | 47.68 s |

The additional five cycles left about 4.90 MB more tracked memory outstanding at exit. This supports further retention investigation, but does not identify an application leak. Heaptrack labels all outstanding allocations as leaked, including native libraries and process-lifetime caches. The largest six-cycle outstanding allocation group was 25.14 MB from an unresolved allocator with Mesa Gallium frames. Many allocation calls came from GLib/D-Bus accessibility traffic. The automated accessibility workload and profiler overhead therefore prevent interpreting these figures as ordinary user CPU cost or native desktop RSS.

The initial tracing attempt failed before application interaction because AT-SPI selected a broker requiring a systemd service unavailable on the private session bus. Repeating with the existing harness setting `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon` passed. No product code changed to accommodate the setup. Raw traces, reports, exact scripts and failure logs remain under the persistent local `bookie-test/tab-cycle-heaptrack*` directories. Next: compare longer runs and attribute retained application allocations separately from rendering and accessibility caches before proposing a lifetime fix.


### Longer-run follow-up

The same optimized binary completed 18 cycles, with 72 editors opened, queried and closed, successful empty-state reopening, a final query and graceful quit. Heaptrack recorded 70.02 MB peak heap, 279.64 MB peak instrumented RSS and 60.31 MB outstanding at exit over 115.19 seconds. This is 11.02 MB more outstanding memory than six cycles. Retention did not plateau within these runs. Attribution remains unproven; a matched query workload reusing one editor is the next control. This source predates later branding and file-open changes; it is not a profile of the current Linux tip.


### Reusing one editor

A six-cycle control reused one editor for the same 25 queries and retained the same per-cycle idle allowance. It omitted tab open/close actions and empty-state pointer clicks. It passed and quit gracefully. Peak tracked heap was 49.30 MB, peak instrumented RSS 246.03 MB and outstanding allocations at exit 43.80 MB. Compared with 24 editor lifecycles, outstanding memory was 5.49 MB lower. This points toward tab lifecycle work for further investigation, but does not isolate one retaining object or remove the accessibility-action difference between the workloads.

A separate Python/GObject control reproduced the native weak-reference observation without Rust or BookiE: realized GTK TextView and GtkSourceView objects still upgraded after detaching, destroying the window, dropping local references, garbage collection and two seconds of main-context processing. This rules out treating the earlier Rust weak-reference test as application-specific evidence; lifecycle and test assumptions remain to be established. Its result and exact script remain in the persistent local `bookie-test/native-widget-python-control` directory. No production lifetime change is justified by these controls alone.
