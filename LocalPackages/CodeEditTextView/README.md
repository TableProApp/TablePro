<p align="center">
  <img src="https://github.com/CodeEditApp/CodeEditTextView/blob/main/.github/CodeEditTextView-Icon-128@2x.png?raw=true" height="128">
  <h1 align="center">CodeEditTextView</h1>
</p>


<p align="center">
  <a aria-label="Follow CodeEdit on Twitter" href="https://twitter.com/CodeEditApp" target="_blank">
    <img alt="" src="https://img.shields.io/badge/Follow%20@CodeEditApp-black.svg?style=for-the-badge&logo=Twitter">
  </a>
  <a aria-label="Join the community on Discord" href="https://discord.gg/vChUXVf9Em" target="_blank">
    <img alt="" src="https://img.shields.io/badge/Join%20the%20community-black.svg?style=for-the-badge&logo=Discord">
  </a>
  <a aria-label="Read the Documentation" href="https://codeeditapp.github.io/CodeEditSourceEditor/documentation/codeeditsourceeditor/" target="_blank">
    <img alt="" src="https://img.shields.io/badge/Documentation-black.svg?style=for-the-badge&logo=readthedocs&logoColor=blue">
  </a>
</p>

A text editor specialized for displaying and editing code documents. Features include basic text editing, extremely fast initial layout, support for handling large documents, customization options for code documents.

![GitHub release](https://img.shields.io/github/v/release/CodeEditApp/CodeEditTextView?color=orange&label=latest%20release&sort=semver&style=flat-square)
![Github Tests](https://img.shields.io/github/actions/workflow/status/CodeEditApp/CodeEditTextView/CI-push.yml?branch=main&label=tests&style=flat-square)
![GitHub Repo stars](https://img.shields.io/github/stars/CodeEditApp/CodeEditTextView?style=flat-square)
![GitHub forks](https://img.shields.io/github/forks/CodeEditApp/CodeEditTextView?style=flat-square)
[![Discord Badge](https://img.shields.io/discord/951544472238444645?color=5865F2&label=Discord&logo=discord&logoColor=white&style=flat-square)](https://discord.gg/vChUXVf9Em)

> [!IMPORTANT]
> This package contains a text view suitable for replacing `NSTextView` in some, ***specific*** cases. If you want a text view that can handle things like: right-to-left text, custom layout elements, or feature parity with the system text view, consider using [STTextView](https://github.com/krzyzanowskim/STTextView) or [NSTextView](https://developer.apple.com/documentation/appkit/nstextview). The ``TextView`` exported by this library is designed to lay out documents made up of lines of text. It also does not attempt to reason about the contents of the document. If you're looking to edit *source code* (indentation, syntax highlighting) consider using the parent library [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor).

## Documentation

This package is fully documented [here](https://codeeditapp.github.io/CodeEditTextView/documentation/codeedittextview/).

## Usage

This package exports a primary `TextView` class. The `TextView` class is an `NSView` subclass that can be embedded in a scroll view or used standalone. It parses and renders lines of a document and handles mouse and keyboard events for text editing. It also renders styled strings for use cases like syntax highlighting.

```swift
import CodeEditTextView
import AppKit

/// # ViewController
/// 
/// An example view controller for displaying a text view embedded in a scroll view.
class ViewController: NSViewController, TextViewDelegate {
    private var scrollView: NSScrollView!
    private var textView: TextView!
    
    var text: String = "func helloWorld() {\n\tprint(\"hello world\")\n}"
    var font: NSFont!
    var textColor: NSColor!
    
    override func loadView() {
		textView = TextView(
            string: text,
            font: font,
            textColor: textColor,
            lineHeightMultiplier: 1.0,
            wrapLines: true,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            delegate: self
        )
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView
        self.view = scrollView
		NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        textView.updateFrameIfNeeded()
    }
}
```

## License

Licensed under the [MIT license](https://github.com/CodeEditApp/CodeEdit/blob/main/LICENSE.md).

## Dependencies

Special thanks to [Matt Massicotte](https://twitter.com/mattie) for the great work he's done!

| Package     | Source                                               | Author                                        |
| :---------- | :--------------------------------------------------- | :-------------------------------------------- |
| `TextStory` | [GitHub](https://github.com/ChimeHQ/TextStory) | [Matt Massicotte](https://twitter.com/mattie) |
| `swift-collections` | [GitHub](https://github.com/apple/swift-collections.git) | [Apple](https://github.com/apple) |

## Related Repositories

<table>
  <tr>
    <td align="center">
      <a href="https://github.com/CodeEditApp/CodeEdit">
        <img src="https://github.com/CodeEditApp/CodeEdit/blob/main/.github/CodeEdit-Icon-128@2x.png?raw=true" height="128">
        <p>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;CodeEdit&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</p>
      </a>
    </td>
    <td align="center">
      <a href="https://github.com/CodeEditApp/CodeEditSourceEditor">
        <img src="https://github.com/CodeEditApp/CodeEditTextView/blob/main/.github/CodeEditSourceEditor-Icon-128@2x.png?raw=true" height="128">
      </a>
      <p><a href="https://github.com/CodeEditApp/CodeEditSourceEditor">CodeEditSourceEditor</a></p>
    </td>
    <td align="center">
      <a href="https://github.com/CodeEditApp/CodeEditKit">
        <img src="https://user-images.githubusercontent.com/806104/193877051-c60d255d-0b6a-408c-bb21-6fabc5e0e60c.png" height="128">
        <p>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;CodeEditKit&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</p>
      </a>
    </td>
    <td align="center">
      <a href="https://github.com/CodeEditApp/CodeEditLanguages">
        <img src="https://user-images.githubusercontent.com/806104/201497920-d6aace8d-f0dc-49f6-bcd7-6a3b64cc384c.png" height="128">
        <p>CodeEditLanguages</p>
      </a>
    </td>
    <td align="center">
      <a href="https://github.com/CodeEditApp/CodeEditCLI">
        <img src="https://user-images.githubusercontent.com/806104/205848006-f2654778-21f1-4f97-b292-32849cc1eff6.png" height="128">
        <p>&nbsp;&nbsp;&nbsp;&nbsp;CodeEdit&nbsp;CLI&nbsp;&nbsp;&nbsp;&nbsp;</p>
      </a>
    </td>
  </tr>
</table>
