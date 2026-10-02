---
paths:
  - "TableProTests/**/*"
  - "TableProUITests/**/*"
  - "Packages/*/Tests/**/*"
---

# Tests

- **Swift Testing, filtered by suite type name.** `-only-testing:TableProTests/<SuiteType>` matches the Swift type, not the file or the `@Suite` display name, and a filter that matches nothing still prints `TEST SUCCEEDED`.
- **No top-level `@Suite` without a trait in `TableProTests`.** A type's `@Test` functions are found without it, and each top-level `@Suite` costs the module compile time quadratically. `scripts/ci/check-test-suite-attributes.py` enforces it.
- **UI suites subclass `UITestCase`**, the only launch path that isolates storage; a bare `XCUIApplication()` or `: XCTestCase` under `TableProUITests/` fails a source-scanning test.
- **A test must not depend on the machine**: pin the locale it formats with, use a private `NSPasteboard(name:)`, stub the network, inject the clock.
- **A UI test that fails only on CI for a reason you cannot establish** goes into `.github/macos-ui-test-quarantine.txt` with the reason, rather than a guessed fix.
