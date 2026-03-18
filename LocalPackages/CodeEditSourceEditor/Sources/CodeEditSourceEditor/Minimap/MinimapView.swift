//
//  MinimapView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/10/25.
//

import AppKit
import CodeEditTextView

/// The minimap view displays a copy of editor contents as a series of small bubbles in place of text.
///
/// This view consists of the following subviews in order
/// ```
/// MinimapView
/// |-> separatorView: A small, grey, leading, separator that distinguishes the minimap from other content.
/// |-> documentVisibleView: Displays a rectangle that represents the portion of the minimap visible in the editor's
/// |                        visible rect. This is draggable and responds to the editor's height.
/// |-> scrollView: Container for the summary bubbles
/// |   |-> contentView: Target view for the summary bubble content
/// ```
///
/// To keep contents in sync with the text view, this view requires that its ``scrollView`` have the same vertical
/// content insets as the editor's content insets.
///
/// The minimap can be styled using an ``EditorTheme``. See ``setTheme(_:)`` for use and colors used by this view.
public class MinimapView: FlippedNSView {
    static let maxWidth: CGFloat = 140.0

    weak var textView: TextView?

    /// The container scrollview for the minimap contents.
    public let scrollView: ForwardingScrollView
    /// The view text lines are rendered into.
    public let contentView: MinimapContentView
    /// The box displaying the visible region on the minimap.
    public let documentVisibleView: NSView
    /// A small gray line on the left of the minimap distinguishing it from the editor.
    public let separatorView: NSView

    /// Responder for a drag gesture on the ``documentVisibleView``.
    var documentVisibleViewPanGesture: NSPanGestureRecognizer?
    var contentViewHeightConstraint: NSLayoutConstraint?

    /// The layout manager that uses the ``lineRenderer`` to render and layout lines.
    var layoutManager: TextLayoutManager?
    var selectionManager: TextSelectionManager?
    /// A custom line renderer that lays out lines of text as 2px tall and draws contents as small lines
    /// using ``MinimapLineFragmentView``
    let lineRenderer: MinimapLineRenderer

    // MARK: - Calculated Variables

    var minimapHeight: CGFloat {
        contentView.frame.height
    }

    var editorHeight: CGFloat {
        textView?.layoutManager.estimatedHeight() ?? 1.0
    }

    var editorToMinimapHeightRatio: CGFloat {
        minimapHeight / editorHeight
    }

    var editorToMinimapWidthRatio: CGFloat {
        3.0 / (textView?.font.charWidth ?? 3.0)
    }

    /// The height of the available container, less the scroll insets to reflect the visible height.
    var containerHeight: CGFloat {
        scrollView.visibleRect.height - scrollView.contentInsets.vertical
    }

    // MARK: - Init

    /// Creates a minimap view with the text view to track, and an initial theme.
    /// - Parameters:
    ///   - textView: The text view to match contents with.
    ///   - theme: The theme for the minimap to use.
    public init(textView: TextView, theme: EditorTheme) {
        self.textView = textView
        self.lineRenderer = MinimapLineRenderer(textView: textView)
        let isLightMode = (theme.background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.0) > 0.5

        self.scrollView = ForwardingScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.receiver = textView.enclosingScrollView

        self.contentView = MinimapContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        self.documentVisibleView = NSView()
        documentVisibleView.translatesAutoresizingMaskIntoConstraints = false
        documentVisibleView.wantsLayer = true
        documentVisibleView.layer?.backgroundColor = isLightMode
            ? NSColor.black.withAlphaComponent(0.065).cgColor
            : NSColor.white.withAlphaComponent(0.065).cgColor

        self.separatorView = NSView()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = isLightMode
            ? NSColor.black.withAlphaComponent(0.1).cgColor
            : NSColor.white.withAlphaComponent(0.1).cgColor

        super.init(frame: .zero)

        setUpPanGesture()

        addSubview(scrollView)
        addSubview(documentVisibleView)
        addSubview(separatorView)
        scrollView.documentView = contentView

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        setUpLayoutManager(textView: textView)
        setUpSelectionManager(textView: textView)

        setUpConstraints()
        setUpListeners()
    }

    /// Creates a pan gesture and attaches it to the ``documentVisibleView``.
    private func setUpPanGesture() {
        let documentVisibleViewPanGesture = NSPanGestureRecognizer(
            target: self,
            action: #selector(documentVisibleViewDragged(_:))
        )
        documentVisibleView.addGestureRecognizer(documentVisibleViewPanGesture)
        self.documentVisibleViewPanGesture = documentVisibleViewPanGesture
    }

    /// Create the layout manager, using text contents from the given textview.
    private func setUpLayoutManager(textView: TextView) {
        let layoutManager = TextLayoutManager(
            textStorage: textView.textStorage,
            lineHeightMultiplier: 1.0,
            wrapLines: textView.wrapLines,
            textView: contentView,
            delegate: self,
            renderDelegate: lineRenderer
        )
        textView.layoutManager.attachments.delegate = self
        self.layoutManager = layoutManager
        self.contentView.layoutManager = layoutManager
        (textView.textStorage.delegate as? MultiStorageDelegate)?.addDelegate(layoutManager)
    }

    /// Set up a selection manager for drawing selections in the minimap.
    /// Requires ``layoutManager`` to not be `nil`.
    private func setUpSelectionManager(textView: TextView) {
        guard let layoutManager = layoutManager else {
            assertionFailure("No layout manager setup for the minimap.")
            return
        }
        self.selectionManager = TextSelectionManager(
            layoutManager: layoutManager,
            textStorage: textView.textStorage,
            textView: textView,
            delegate: self
        )
        selectionManager?.insertionPointColor = .clear
        contentView.textView = textView
        contentView.selectionManager = selectionManager
    }

    // MARK: - Constraints

    private func setUpConstraints() {
        let contentViewHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: 1.0)
        self.contentViewHeightConstraint = contentViewHeightConstraint
        NSLayoutConstraint.activate([
            // Constrain to all sides
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Scrolling, but match width
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentViewHeightConstraint,

            // Y position set manually
            documentVisibleView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            documentVisibleView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Separator on leading side
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: 1.0)
        ])
    }

    // MARK: - Scroll listeners

    /// Set up listeners for relevant frame and selection updates.
    private func setUpListeners() {
        guard let editorScrollView = textView?.enclosingScrollView else { return }
        // Need to listen to:
        // - ScrollView offset changed
        // - ScrollView frame changed
        // and update the document visible box to match.
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: editorScrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            // Scroll changed
            self?.updateDocumentVisibleViewPosition()
        }

        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: editorScrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            // Frame changed
            self?.updateContentViewHeight()
            self?.updateDocumentVisibleViewPosition()
        }

        NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView?.selectionManager,
            queue: .main
        ) { [weak self] _ in
            self?.selectionManager?.setSelectedRanges(
                self?.textView?.selectionManager.textSelections.map(\.range) ?? []
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override public var visibleRect: NSRect {
        var rect = scrollView.documentVisibleRect
        rect.origin.y += scrollView.contentInsets.top
        rect.size.height -= scrollView.contentInsets.vertical
        return rect.pixelAligned
    }

    override public func resetCursorRects() {
        // Don't use an iBeam in this view
        addCursorRect(bounds, cursor: .arrow)
    }

    override public func layout() {
        super.layout()
        updateContentViewHeight()
        updateDocumentVisibleViewPosition()
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let point = superview?.convert(point, to: self) else { return nil }
        // For performance, don't hitTest the layout fragment views, but make sure the `documentVisibleView` is
        // hittable.
        if documentVisibleView.frame.contains(point) {
            return documentVisibleView
        } else if visibleRect.contains(point) {
            return self
        } else {
            return super.hitTest(point)
        }
    }

    // Eat mouse events so we don't pass them on to the text view. Leads to some odd behavior otherwise.

    override public func mouseDown(with event: NSEvent) { }
    override public func mouseDragged(with event: NSEvent) { }

    /// Sets the content view height, matching the text view's overscroll setting as well as the layout manager's
    /// cached height.
    func updateContentViewHeight() {
        guard let estimatedContentHeight = layoutManager?.estimatedHeight(),
              let editorEstimatedHeight = textView?.layoutManager.estimatedHeight(),
              let contentViewHeightConstraint else {
            return
        }
        let overscrollAmount = textView?.overscrollAmount ?? 0.0
        let overscroll = containerHeight * overscrollAmount * (estimatedContentHeight / editorEstimatedHeight)
        let height = estimatedContentHeight + overscroll

        // This seems odd, but this reduces layout passes drastically
        let newFrame = CGRect(
            origin: contentView.frame.origin,
            size: CGSize(width: contentView.frame.width, height: height)
        ).pixelAligned

        // Only update a frame if needed
        if contentViewHeightConstraint.constant != newFrame.height
            && height.isFinite
            && height < (textView?.frame.height ?? 0.0) {
            contentViewHeightConstraint.constant = newFrame.height
            contentViewHeightConstraint.isActive = true
            updateConstraints()
        }
    }

    /// Updates the minimap to reflect a new theme.
    ///
    /// Colors used:
    /// - ``documentVisibleView``'s background color = `theme.text` with `0.05` alpha.
    /// - The minimap's background color = `theme.background`.
    ///
    /// - Parameter theme: The selected theme.
    public func setTheme(_ theme: EditorTheme) {
        let isLightMode = theme.background.brightnessComponent > 0.5
        documentVisibleView.layer?.backgroundColor = isLightMode
            ? NSColor.black.withAlphaComponent(0.065).cgColor
            : NSColor.white.withAlphaComponent(0.065).cgColor
        separatorView.layer?.backgroundColor = isLightMode
            ? NSColor.black.withAlphaComponent(0.1).cgColor
            : NSColor.white.withAlphaComponent(0.1).cgColor
        layer?.backgroundColor = theme.background.cgColor
    }
}
