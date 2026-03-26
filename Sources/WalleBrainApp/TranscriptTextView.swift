import AppKit
import SwiftUI

struct TranscriptTextView: NSViewRepresentable {
  let text: String
  @Binding var isAutoFollow: Bool
  let scrollRequestID: Int

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

    let textView = NSTextView(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.usesFindBar = false
    textView.allowsUndo = false
    textView.textContainerInset = NSSize(width: 18, height: 18)
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

    private var lastAppliedText = ""
    private var lastScrollRequestID = 0
    private var isProgrammaticScroll = false

    init(parent: TranscriptTextView) {
      self.parent = parent
      self.lastScrollRequestID = parent.scrollRequestID
    }

    deinit {
      if let clipView = observedClipView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: clipView
        )
      }
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

      self.scrollView = scrollView
      self.textView = textView
      self.observedClipView = scrollView?.contentView

      if let clipView = observedClipView {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(contentViewBoundsDidChange),
          name: NSView.boundsDidChangeNotification,
          object: clipView
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

    private static var transcriptFont: NSFont {
      let base = NSFont.systemFont(ofSize: 22, weight: .regular)
      if let roundedDescriptor = base.fontDescriptor.withDesign(.rounded),
         let roundedFont = NSFont(descriptor: roundedDescriptor, size: 22)
      {
        return roundedFont
      }

      return base
    }
  }
}
