import AppKit
import SwiftUI

struct TranscriptTextView: NSViewRepresentable {
  let text: String
  @Binding var isAutoFollow: Bool
  let scrollRequestID: Int
  let isCorrectionEnabled: Bool
  let onQueueCorrection: (String, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.contentView.postsBoundsChangedNotifications = true

    let textView = configuredTextView(font: Coordinator.transcriptFont, inset: NSSize(width: 18, height: 18))
    scrollView.documentView = textView
    context.coordinator.attach(scrollView: scrollView, textView: textView)
    context.coordinator.applyTextIfNeeded()

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.attach(scrollView: scrollView, textView: scrollView.documentView as? NSTextView)
    context.coordinator.applyTextIfNeeded()
    context.coordinator.handleScrollRequestIfNeeded()
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: TranscriptTextView
    weak var scrollView: NSScrollView?
    weak var textView: NSTextView?
    weak var observedClipView: NSClipView?
    weak var observedTextView: NSTextView?

    private var lastAppliedText = ""
    private var lastScrollRequestID = 0
    private var isProgrammaticScroll = false
    private let correctionPopover = NSPopover()

    init(parent: TranscriptTextView) {
      self.parent = parent
      self.lastScrollRequestID = parent.scrollRequestID
      super.init()
      correctionPopover.behavior = .transient
      correctionPopover.animates = true
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    static var transcriptFont: NSFont {
      let base = NSFont.systemFont(ofSize: 22, weight: .regular)
      if let roundedDescriptor = base.fontDescriptor.withDesign(.rounded),
         let roundedFont = NSFont(descriptor: roundedDescriptor, size: 22)
      {
        return roundedFont
      }

      return base
    }

    func attach(scrollView: NSScrollView?, textView: NSTextView?) {
      guard self.scrollView !== scrollView else {
        self.textView = textView
        return
      }

      if let oldClipView = observedClipView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: oldClipView
        )
      }

      if let oldTextView = observedTextView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSTextView.didChangeSelectionNotification,
          object: oldTextView
        )
      }

      self.scrollView = scrollView
      self.textView = textView
      self.observedClipView = scrollView?.contentView
      self.observedTextView = textView

      if let clipView = observedClipView {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(contentViewBoundsDidChange),
          name: NSView.boundsDidChangeNotification,
          object: clipView
        )
      }

      if let textView = observedTextView {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(textViewSelectionDidChange),
          name: NSTextView.didChangeSelectionNotification,
          object: textView
        )
      }
    }

    func applyTextIfNeeded() {
      guard let scrollView, let textView else {
        return
      }

      let textChanged = lastAppliedText != parent.text
      guard textChanged else {
        return
      }

      let preservedOrigin = scrollView.contentView.bounds.origin
      textView.string = parent.text
      textView.font = Self.transcriptFont
      textView.textColor = NSColor.labelColor
      textView.alignment = .left
      textView.layoutManager?.ensureLayout(for: textView.textContainer!)

      lastAppliedText = parent.text
      dismissCorrectionPopover(clearSelection: false)

      if parent.isAutoFollow {
        scrollToBottom()
      } else {
        scrollView.contentView.scroll(to: preservedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
    }

    func handleScrollRequestIfNeeded() {
      guard lastScrollRequestID != parent.scrollRequestID else {
        return
      }

      lastScrollRequestID = parent.scrollRequestID
      scrollToBottom()
    }

    @objc
    private func contentViewBoundsDidChange() {
      guard !isProgrammaticScroll, let scrollView else {
        return
      }

      let nearBottom = isNearBottom(in: scrollView)
      if nearBottom != parent.isAutoFollow {
        DispatchQueue.main.async {
          self.parent.isAutoFollow = nearBottom
        }
      }
    }

    @objc
    private func textViewSelectionDidChange() {
      presentCorrectionPopoverIfNeeded()
    }

    private func presentCorrectionPopoverIfNeeded() {
      guard let textView else {
        return
      }

      let range = textView.selectedRange()
      guard range.location != NSNotFound, range.length > 0 else {
        dismissCorrectionPopover(clearSelection: false)
        return
      }

      guard parent.isCorrectionEnabled else {
        dismissCorrectionPopover(clearSelection: false)
        return
      }

      let selectedText = (textView.string as NSString).substring(with: range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !selectedText.isEmpty else {
        dismissCorrectionPopover(clearSelection: false)
        return
      }

      let anchorRect = selectionRect(for: range, in: textView)
      let contentView = CorrectionPopoverView(
        selectedText: selectedText,
        onAdd: { [weak self] replacement in
          self?.queueCorrection(selectedText: selectedText, replacement: replacement)
        },
        onCancel: { [weak self] in
          self?.dismissCorrectionPopover(clearSelection: false)
        }
      )

      let hostingController = NSHostingController(rootView: contentView)
      correctionPopover.contentViewController = hostingController
      correctionPopover.contentSize = NSSize(width: 320, height: 132)

      if correctionPopover.isShown {
        correctionPopover.close()
      }

      correctionPopover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
    }

    private func queueCorrection(selectedText: String, replacement: String) {
      let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedReplacement.isEmpty, normalizedReplacement != selectedText else {
        return
      }

      parent.onQueueCorrection(selectedText, normalizedReplacement)
      dismissCorrectionPopover(clearSelection: true)
    }

    private func dismissCorrectionPopover(clearSelection: Bool) {
      if correctionPopover.isShown {
        correctionPopover.performClose(nil)
      }

      guard clearSelection, let textView else {
        return
      }

      textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func scrollToBottom() {
      guard let scrollView, let textView else {
        return
      }

      isProgrammaticScroll = true
      let range = NSRange(location: textView.string.utf16.count, length: 0)
      textView.scrollRangeToVisible(range)
      scrollView.reflectScrolledClipView(scrollView.contentView)

      DispatchQueue.main.async {
        self.isProgrammaticScroll = false
      }
    }

    private func isNearBottom(in scrollView: NSScrollView) -> Bool {
      guard let documentView = scrollView.documentView else {
        return true
      }

      let visibleRect = scrollView.contentView.documentVisibleRect
      let distanceFromBottom = documentView.frame.maxY - visibleRect.maxY
      return distanceFromBottom <= 36
    }
  }
}

struct SelectableTextBlockView: NSViewRepresentable {
  let text: String
  @Binding var measuredHeight: CGFloat
  let isCorrectionEnabled: Bool
  let onQueueCorrection: (String, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay

    let textView = configuredTextView(font: Coordinator.blockFont, inset: NSSize(width: 0, height: 0))
    textView.textContainerInset = NSSize(width: 0, height: 0)
    scrollView.documentView = textView
    context.coordinator.attach(scrollView: scrollView, textView: textView)
    context.coordinator.applyTextIfNeeded()

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.attach(scrollView: scrollView, textView: scrollView.documentView as? NSTextView)
    context.coordinator.applyTextIfNeeded()
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: SelectableTextBlockView
    weak var scrollView: NSScrollView?
    weak var textView: NSTextView?
    weak var observedTextView: NSTextView?

    private var lastAppliedText = ""
    private let correctionPopover = NSPopover()

    init(parent: SelectableTextBlockView) {
      self.parent = parent
      super.init()
      correctionPopover.behavior = .transient
      correctionPopover.animates = true
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    static var blockFont: NSFont {
      NSFont.systemFont(ofSize: 17, weight: .regular)
    }

    func attach(scrollView: NSScrollView?, textView: NSTextView?) {
      guard self.scrollView !== scrollView else {
        self.textView = textView
        return
      }

      if let oldTextView = observedTextView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSTextView.didChangeSelectionNotification,
          object: oldTextView
        )
      }

      self.scrollView = scrollView
      self.textView = textView
      self.observedTextView = textView

      if let textView = observedTextView {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(textViewSelectionDidChange),
          name: NSTextView.didChangeSelectionNotification,
          object: textView
        )
      }
    }

    func applyTextIfNeeded() {
      guard let textView else {
        return
      }

      let textChanged = lastAppliedText != parent.text
      guard textChanged else {
        return
      }

      textView.string = parent.text
      textView.font = Self.blockFont
      textView.textColor = NSColor.labelColor
      textView.alignment = .left
      textView.layoutManager?.ensureLayout(for: textView.textContainer!)

      lastAppliedText = parent.text
      updateMeasuredHeight()
      dismissCorrectionPopover(clearSelection: false)
    }

    @objc
    private func textViewSelectionDidChange() {
      presentCorrectionPopoverIfNeeded()
    }

    private func presentCorrectionPopoverIfNeeded() {
      guard let textView else {
        return
      }

      let range = textView.selectedRange()
      guard range.location != NSNotFound, range.length > 0 else {
        dismissCorrectionPopover(clearSelection: false)
        return
      }

      guard parent.isCorrectionEnabled else {
        dismissCorrectionPopover(clearSelection: false)
        return
      }

      let selectedText = (textView.string as NSString).substring(with: range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !selectedText.isEmpty else {
        dismissCorrectionPopover(clearSelection: false)
        return
      }

      let anchorRect = selectionRect(for: range, in: textView)
      let contentView = CorrectionPopoverView(
        selectedText: selectedText,
        onAdd: { [weak self] replacement in
          self?.queueCorrection(selectedText: selectedText, replacement: replacement)
        },
        onCancel: { [weak self] in
          self?.dismissCorrectionPopover(clearSelection: false)
        }
      )

      let hostingController = NSHostingController(rootView: contentView)
      correctionPopover.contentViewController = hostingController
      correctionPopover.contentSize = NSSize(width: 320, height: 132)

      if correctionPopover.isShown {
        correctionPopover.close()
      }

      correctionPopover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
    }

    private func queueCorrection(selectedText: String, replacement: String) {
      let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedReplacement.isEmpty, normalizedReplacement != selectedText else {
        return
      }

      parent.onQueueCorrection(selectedText, normalizedReplacement)
      dismissCorrectionPopover(clearSelection: true)
    }

    private func dismissCorrectionPopover(clearSelection: Bool) {
      if correctionPopover.isShown {
        correctionPopover.performClose(nil)
      }

      guard clearSelection, let textView else {
        return
      }

      textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func updateMeasuredHeight() {
      guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
        return
      }

      layoutManager.ensureLayout(for: textContainer)
      let usedRect = layoutManager.usedRect(for: textContainer)
      let height = max(48, ceil(usedRect.height + 4))

      if abs(parent.measuredHeight - height) > 1 {
        DispatchQueue.main.async {
          self.parent.measuredHeight = height
        }
      }
    }
  }
}

private struct CorrectionPopoverView: View {
  let selectedText: String
  let onAdd: (String) -> Void
  let onCancel: () -> Void

  @State private var replacement = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(selectedText)
        .font(.caption)
        .lineLimit(2)
        .foregroundStyle(.secondary)

      TextField("Replace with", text: $replacement)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          submit()
        }

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .buttonStyle(.borderless)
        Button("Add") {
          submit()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
    }
    .padding(14)
    .frame(width: 320)
  }

  private var canSubmit: Bool {
    let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmedReplacement.isEmpty && trimmedReplacement != selectedText
  }

  private func submit() {
    let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReplacement.isEmpty, trimmedReplacement != selectedText else {
      return
    }
    onAdd(trimmedReplacement)
  }
}

@MainActor
private func configuredTextView(font: NSFont, inset: NSSize) -> NSTextView {
  let textView = NSTextView(frame: .zero)
  textView.isEditable = false
  textView.isSelectable = true
  textView.drawsBackground = false
  textView.isRichText = false
  textView.importsGraphics = false
  textView.usesFindBar = false
  textView.allowsUndo = false
  textView.textContainerInset = inset
  textView.minSize = .zero
  textView.maxSize = NSSize(
    width: CGFloat.greatestFiniteMagnitude,
    height: CGFloat.greatestFiniteMagnitude
  )
  textView.isVerticallyResizable = true
  textView.isHorizontallyResizable = false
  textView.autoresizingMask = [.width]
  textView.textContainer?.containerSize = NSSize(
    width: 0,
    height: CGFloat.greatestFiniteMagnitude
  )
  textView.textContainer?.widthTracksTextView = true
  textView.font = font
  return textView
}

@MainActor
private func selectionRect(for range: NSRange, in textView: NSTextView) -> NSRect {
  guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
    return NSRect(x: 0, y: 0, width: 1, height: 1)
  }

  let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
  var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
  rect.origin.x += textView.textContainerInset.width
  rect.origin.y += textView.textContainerInset.height

  if rect.isEmpty {
    return NSRect(x: 0, y: 0, width: 1, height: 1)
  }

  rect.size.width = max(rect.size.width, 1)
  rect.size.height = max(rect.size.height, 1)
  return rect
}
