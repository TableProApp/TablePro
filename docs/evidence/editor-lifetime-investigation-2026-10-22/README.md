# Editor lifetime investigation, 2026-10-22

Related: [#1333](https://github.com/cozyGarage/BookiE/issues/1333). This investigation is incomplete and establishes no application-specific leak.

An initial isolated test launched the editor, dropped its controller, pumped the main context and checked weak references. The editor root was released, while the source view remained alive. Source review found strong view references captured by buffer callbacks and strong Find/Replace callback handles. Replacing these with weak references did not make the test pass. Keeping the test runtime alive separately did not make it pass either.

A control created a plain `sourceview5::View` without any BookiE editor component or application callbacks, dropped it, and waited five seconds for its weak reference to clear. That control also failed. Consequently, the editor test cannot presently distinguish application retention from the native toolkit lifecycle or test setup. Earlier descriptions of it as proof of an application-specific lifetime defect were too strong.

The unvalidated production callback changes were removed from the branch and preserved only as a local investigation patch. They are not proposed for merge. No test was weakened to accept retained widgets. Next steps are a realized-window disposal control and allocation tracing of repeated native-widget versus BookiE editor lifecycles.

Separately, an 18-cycle Xvfb scenario opened, queried and closed four editors per cycle, clicked the empty-state editor action and completed a final query. All functional checks passed. Process RSS grew from 165,268 KiB initially to 202,364 KiB finally. This supports continued investigation, but does not prove a leak or explain the native freeze. The source/binary identity matches the [six-cycle evidence](../tab-cycles-2026-10-22/manifest.json).

All interaction used isolated displays. No native desktop input or capture occurred. Raw control logs and the unvalidated patch remain local; they are not acceptance evidence for a fix.
