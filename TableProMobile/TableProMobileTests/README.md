# TableProMobileTests

Swift Testing tests for the iOS view models extracted in P1 #5 (PRs #1164, #1165, #1166).

## One-time Xcode setup

The test target is not in the Xcode project yet. To enable these tests:

1. Open `TableProMobile.xcodeproj` in Xcode
2. File → New → Target
3. iOS → Unit Testing Bundle
4. Product Name: `TableProMobileTests`
5. Target to Test: `TableProMobile`
6. Testing System: **Swift Testing**
7. Finish

Xcode will create a stub `TableProMobileTests.swift` that you can delete. Because the project uses synchronized file groups (Xcode 16+), the existing files in this folder will be picked up automatically once the target points at this directory.

If Xcode chose a different folder name when creating the target, drag-and-drop these files into the target in the navigator, or rename the test root group to match.

## Layout

- `Mocks/MockDatabaseDriver.swift` - in-memory `DatabaseDriver` and `SecureStore` stubs with scriptable results
- `DataBrowserViewModelTests.swift` - load lifecycle, pagination, sort/filter/search, delete, primary key extraction
- `ConnectionFormViewModelTests.swift` - hydration from existing connection, default port on type change, validation, credential hydration, file picker helpers
- `RowDetailViewModelTests.swift` - edit lifecycle, save with/without changes, primary key requirement, lazy cell load
