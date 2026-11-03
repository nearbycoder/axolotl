import SwiftUI
import AxolotlKit

/// Bridge between SwiftUI (toolbars, menus, completion lists) and the platform text view.
@MainActor
@Observable
final class EditorController {
    var completion: CompletionState?
    var suggestions: [String] = []
    var highlightedSuggestion = 0
    var selection = NSRange(location: 0, length: 0)
    var isFocused = false
    @ObservationIgnored weak var host: EditorHost?

    func perform(_ cmd: FormatCommand) { host?.perform(cmd) }
    func insert(_ text: String) { host?.insertText(text) }
    func focus() { host?.focusEditor() }
    func scroll(toMarkdownLocation location: Int) { host?.scrollTo(markdownLocation: location) }
    func flush() { host?.flushPendingSave() }
    func attach(_ files: [(data: Data, name: String, mime: String)]) { host?.attach(files) }

    func accept(_ suggestion: String) {
        guard let c = completion else { return }
        let replacement: String
        switch c.kind {
        case .tag: replacement = suggestion.contains(" ") ? "#\(suggestion)# " : "#\(suggestion) "
        case .wiki: replacement = "[[\(suggestion)]]"
        }
        host?.replace(c.range, with: replacement, selection: nil)
        completion = nil
        suggestions = []
    }

    func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlightedSuggestion = (highlightedSuggestion + delta + suggestions.count) % suggestions.count
    }
}

@MainActor
protocol EditorHost: AnyObject {
    func perform(_ cmd: FormatCommand)
    func insertText(_ text: String)
    func replace(_ range: NSRange, with string: String, selection: NSRange?)
    func focusEditor()
    func scrollTo(markdownLocation: Int)
    func flushPendingSave()
    func attach(_ files: [(data: Data, name: String, mime: String)])
}

struct EditorCallbacks {
    var onChange: (String) -> Void = { _ in }
    var onOpenURL: (String) -> Void = { _ in }
    var onOpenWiki: (String) -> Void = { _ in }
    var onTag: (String) -> Void = { _ in }
    var onOpenAttachment: (String) -> Void = { _ in }
    /// Stores pasted or dropped files and returns the Markdown to insert for each.
    var onAttachFiles: ([(data: Data, name: String, mime: String)]) -> [String] = { _ in [] }
    var suggestions: (CompletionState) -> [String] = { _ in [] }
    var image: (String) -> PlatformImage? = { _ in nil }
}

struct EditorConfig: Equatable {
    var style: EditorStyleKey
    var typewriter: Bool
    var spellCheck: Bool
    var lineWidth: CGFloat
    var imagesVersion: Int
}

/// Equatable summary of an `EditorStyle`, so SwiftUI updates only restyle when something changed.
struct EditorStyleKey: Equatable {
    var themeId: String
    var fontId: String
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var paragraphSpacing: CGFloat
    var dimMarkdown: Bool
    var hideMarkdown: Bool

    var style: EditorStyle {
        EditorStyle(theme: Theme.named(themeId), font: EditorFont.all.first { $0.id == fontId } ?? EditorFont.all[0],
                    fontSize: fontSize, lineHeight: lineHeight, paragraphSpacing: paragraphSpacing, dimMarkdown: dimMarkdown,
                    hideMarkdown: hideMarkdown)
    }
}

/// Platform-independent part of the editor coordinator.
@MainActor
class EditorCoordinatorBase: NSObject {
    let storage: NSTextStorage
    let storageDelegate: MarkdownStorageDelegate
    let layout: MarkdownLayoutManager
    let container: NSTextContainer
    let hider = MarkupHider()
    var noteId: String
    var lastMarkdown: String
    var config: EditorConfig
    var callbacks: EditorCallbacks
    let controller: EditorController
    private var saveTask: Task<Void, Never>?
    var isLoading = false

    init(noteId: String, markdown: String, config: EditorConfig, callbacks: EditorCallbacks, controller: EditorController) {
        let style = config.style.style
        storage = NSTextStorage()
        storageDelegate = MarkdownStorageDelegate(style: style)
        storage.delegate = storageDelegate
        layout = MarkdownLayoutManager(style: style)
        container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 6
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.delegate = hider
        self.noteId = noteId
        self.lastMarkdown = markdown
        self.config = config
        self.callbacks = callbacks
        self.controller = controller
        super.init()
        load(markdown)
    }

    var style: EditorStyle { storageDelegate.style }

    /// The current text as a Foundation string, cheap to match against.
    func snapshot() -> NSString { MarkdownStorageDelegate.snapshot(storage) }

    func load(_ markdown: String) {
        isLoading = true
        hider.revealed = NSRange(location: NSNotFound, length: 0)
        storageDelegate.suspended = true
        storage.setAttributedString(EditorDocument.attributed(from: markdown, style: style, image: callbacks.image))
        storageDelegate.suspended = false
        storageDelegate.rehighlight(storage)
        lastMarkdown = markdown
        isLoading = false
    }

    var markdown: String { EditorDocument.markdown(from: storage) }

    /// Called by subclasses after the user changed the text.
    func userDidEdit() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        let md = markdown
        guard md != lastMarkdown else { return }
        lastMarkdown = md
        callbacks.onChange(md)
    }

    /// Applies a change made elsewhere (sync, another window) without resetting the caret.
    /// Returns the adjusted selection.
    func applyExternal(_ markdown: String, selection: NSRange) -> NSRange {
        let incoming = EditorDocument.attributed(from: markdown, style: style, image: callbacks.image)
        lastMarkdown = markdown
        guard let edit = TextMerge.singleEdit(from: storage.string, to: incoming.string) else { return selection }
        let replacementLength = (edit.replacement as NSString).length
        let replacement = incoming.attributedSubstring(from: NSRange(location: edit.range.location, length: replacementLength))
        isLoading = true
        storage.replaceCharacters(in: edit.range, with: replacement)
        isLoading = false
        let delta = replacementLength - edit.range.length
        var sel = selection
        if sel.location >= NSMaxRange(edit.range) {
            sel.location += delta
        } else if sel.location > edit.range.location {
            sel = NSRange(location: edit.range.location + replacementLength, length: 0)
        }
        sel.location = min(sel.location, storage.length)
        sel.length = min(sel.length, storage.length - sel.location)
        return sel
    }

    func updateCompletion(selection: NSRange) {
        controller.selection = selection
        let state = selection.length == 0 ? Formatter.completion(text: snapshot(), caret: selection.location) : nil
        if state != controller.completion {
            controller.completion = state
            controller.suggestions = state.map(callbacks.suggestions) ?? []
            controller.highlightedSuggestion = 0
            completionChanged()
        }
    }

    /// Hook for subclasses (iOS swaps the keyboard bar).
    func completionChanged() {}

    /// Shows Markdown syntax only on the paragraph(s) holding the caret while editing.
    func updateReveal(selection: NSRange, focused: Bool) {
        let text = snapshot()
        var next = NSRange(location: NSNotFound, length: 0)
        if focused, selection.location != NSNotFound, selection.location <= text.length {
            next = text.paragraphRange(for: NSRange(location: selection.location, length: min(selection.length, text.length - selection.location)))
            if next.length == 0 { next = NSRange(location: selection.location, length: 0) }
        }
        let old = hider.revealed
        guard old.location != next.location || old.length != next.length else { return }
        hider.revealed = next
        for r in [old, next] where r.location != NSNotFound {
            let clamped = NSIntersectionRange(r, NSRange(location: 0, length: storage.length))
            guard clamped.length > 0 else { continue }
            layout.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
            layout.invalidateDisplay(forCharacterRange: clamped)
        }
    }

    /// Body attributes for typing on an empty line, so the caret isn't sized like the heading above.
    func typingAttributes(at selection: NSRange) -> [NSAttributedString.Key: Any]? {
        let text = snapshot()
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let para = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let content = text.substring(with: para).trimmingCharacters(in: .newlines)
        guard content.isEmpty else { return nil }
        return [.font: style.bodyFont, .foregroundColor: style.theme.textColor, .paragraphStyle: MarkdownHighlighter.paragraphStyle(style)]
    }

    func storageLocation(forMarkdown location: Int) -> Int {
        var shift = 0
        storage.enumerateAttribute(.axAttachmentSource, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let src = value as? String else { return }
            let mdLocation = range.location + shift
            if mdLocation >= location { stop.pointee = true; return }
            shift += (src as NSString).length - range.length
        }
        return max(0, min(storage.length, location - shift))
    }

    func refreshImages() {
        var changed = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let a = value as? ImageAttachment, let img = callbacks.image(a.attachmentId), a.image !== img else { return }
            a.image = img
            layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            changed = true
        }
        if changed { layout.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length)) }
    }

    func applyConfig(_ new: EditorConfig) -> Bool {
        let old = config
        config = new
        if old.style != new.style {
            let s = new.style.style
            layout.style = s
            storageDelegate.style = s
            storageDelegate.rehighlight(storage)
        }
        if old.imagesVersion != new.imagesVersion { refreshImages() }
        return old != new
    }

    /// Handles a tap or click at a character index. Returns true when consumed.
    func activate(at index: Int, commandKey: Bool) -> Bool {
        guard index >= 0, index < storage.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        if attrs[.axTodo] != nil, let edit = Formatter.toggleTodo(text: snapshot(), at: index) {
            replaceKeepingSelection(edit.range, with: edit.replacement)
            Haptics.tap()
            return true
        }
        if let url = attrs[.axLink] as? String { callbacks.onOpenURL(url); return true }
        if let target = attrs[.axWiki] as? String { callbacks.onOpenWiki(target); return true }
        if let file = attrs[.axFile] as? String { callbacks.onOpenAttachment(file); return true }
        if let a = attrs[.attachment] as? ImageAttachment, commandKey { callbacks.onOpenAttachment(a.attachmentId); return true }
        if let tag = attrs[.axTag] as? String, commandKey { callbacks.onTag(tag); return true }
        return false
    }

    /// Whether a point should be handled by `activate` instead of moving the caret.
    func isInteractive(at index: Int) -> Bool {
        guard index >= 0, index < storage.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        return attrs[.axTodo] != nil || attrs[.axLink] != nil || attrs[.axWiki] != nil || attrs[.axFile] != nil
    }

    func replaceKeepingSelection(_ range: NSRange, with string: String) {
        fatalError("subclass")
    }
}

#if os(iOS)
import UIKit

final class AxTextView: UITextView {
    var interactive: ((CGPoint) -> Bool)?
    var onPasteImages: (([(data: Data, name: String, mime: String)]) -> Void)?
    var onShiftTab: (() -> Void)?
    var maxLineWidth: CGFloat = 720
    weak var ownTap: UITapGestureRecognizer?
    let placeholderLabel = UILabel()

    func updatePlaceholder() { placeholderLabel.isHidden = !textStorage.string.isEmpty }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g !== ownTap, g is UITapGestureRecognizer, let interactive, interactive(g.location(in: self)) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) && UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.hasImages, !pb.hasStrings, let images = pb.images, !images.isEmpty {
            let files = images.compactMap { img -> (data: Data, name: String, mime: String)? in
                guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
                return (data, "Image.jpg", "image/jpeg")
            }
            onPasteImages?(files)
            return
        }
        super.paste(sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(shiftTab))]
    }

    @objc private func shiftTab() { onShiftTab?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontal = max(20, (bounds.width - maxLineWidth) / 2)
        if abs(textContainerInset.left - horizontal) > 0.5 {
            textContainerInset = UIEdgeInsets(top: textContainerInset.top, left: horizontal, bottom: textContainerInset.bottom, right: horizontal)
        }
        if placeholderLabel.superview == nil { addSubview(placeholderLabel) }
        placeholderLabel.sizeToFit()
        placeholderLabel.frame.origin = CGPoint(x: textContainerInset.left + textContainer.lineFragmentPadding, y: textContainerInset.top)
    }
}

extension UITextView {
    func invalidatePlaceholder() { (self as? AxTextView)?.updatePlaceholder() }
}

/// Keyboard accessory with formatting buttons, or tag / link suggestions while completing.
final class FormatBar: UIInputView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    var onCommand: ((FormatCommand) -> Void)?
    var onSuggestion: ((String) -> Void)?
    var onAttach: (() -> Void)?
    var onDismiss: (() -> Void)?
    var tint: UIColor = .systemRed { didSet { stack.arrangedSubviews.forEach { $0.tintColor = tint } } }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        showFormatting()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(symbol: String? = nil, title: String? = nil, action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        if let symbol { cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)) }
        if let title { cfg.title = title }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.tintColor = tint
        return b
    }

    func showFormatting() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items: [(String, FormatCommand)] = [
            ("number", .heading(1)), ("bold", .bold), ("italic", .italic), ("strikethrough", .strike), ("highlighter", .highlight),
            ("checklist", .todo), ("list.bullet", .bulletList), ("list.number", .numberedList), ("text.quote", .quote),
            ("chevron.left.forwardslash.chevron.right", .code), ("curlybraces", .codeBlock), ("link", .link),
            ("text.badge.plus", .wikiLink), ("tag", .tag), ("tablecells", .table), ("minus", .rule),
            ("increase.indent", .indent), ("decrease.indent", .outdent),
        ]
        let menu = UIMenu(children: (1...6).map { level in
            UIAction(title: "Heading \(level)") { [weak self] _ in self?.onCommand?(.heading(level)) }
        })
        for (symbol, cmd) in items {
            let b = button(symbol: symbol) { [weak self] in self?.onCommand?(cmd) }
            if case .heading = cmd { b.menu = menu }
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(button(symbol: "paperclip") { [weak self] in self?.onAttach?() })
        stack.addArrangedSubview(button(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.onDismiss?() })
    }

    func showSuggestions(_ items: [String], prefix: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if items.isEmpty { return showFormatting() }
        for item in items.prefix(12) {
            let b = button(title: prefix + item) { [weak self] in self?.onSuggestion?(item) }
            stack.addArrangedSubview(b)
        }
        scroll.setContentOffset(.zero, animated: false)
    }
}

struct MarkdownEditor: UIViewRepresentable {
    let noteId: String
    let markdown: String
    let config: EditorConfig
    let controller: EditorController
    let callbacks: EditorCallbacks
    var onAttachRequest: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(noteId: noteId, markdown: markdown, config: config, callbacks: callbacks, controller: controller)
    }

    func makeUIView(context: Context) -> AxTextView {
        let c = context.coordinator
        let tv = AxTextView(frame: .zero, textContainer: c.container)
        c.textView = tv
        tv.delegate = c
        tv.allowsEditingTextAttributes = false
        tv.isFindInteractionEnabled = true
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 120, right: 16)
        tv.adjustsFontForContentSizeCategory = false
        tv.interactive = { [weak c] p in c?.isInteractive(point: p) ?? false }
        tv.onPasteImages = { [weak c] files in c?.attach(files) }
        tv.onShiftTab = { [weak c] in c?.perform(.outdent) }
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = c
        tv.addGestureRecognizer(tap)
        tv.ownTap = tap
        tv.addInteraction(UIDropInteraction(delegate: c))
        let bar = FormatBar()
        bar.onCommand = { [weak c] cmd in c?.perform(cmd) }
        bar.onSuggestion = { [weak c] s in c?.controller.accept(s) }
        bar.onAttach = onAttachRequest
        bar.onDismiss = { [weak tv] in tv?.resignFirstResponder() }
        tv.inputAccessoryView = bar
        c.bar = bar
        controller.host = c
        c.applyAppearance()
        return tv
    }

    func updateUIView(_ tv: AxTextView, context: Context) {
        let c = context.coordinator
        c.callbacks = callbacks
        controller.host = c
        if c.noteId != noteId {
            c.flushPendingSave()
            c.noteId = noteId
            c.load(markdown)
            tv.selectedRange = NSRange(location: 0, length: 0)
            tv.setContentOffset(CGPoint(x: 0, y: -tv.adjustedContentInset.top), animated: false)
            tv.undoManager?.removeAllActions()
        } else if markdown != c.lastMarkdown && markdown != c.markdown {
            tv.selectedRange = c.applyExternal(markdown, selection: tv.selectedRange)
            tv.undoManager?.removeAllActions()
        }
        tv.updatePlaceholder()
        if c.applyConfig(config) { c.applyAppearance() }
        if let bar = c.bar { bar.onAttach = onAttachRequest }
    }

    static func dismantleUIView(_ tv: AxTextView, coordinator: Coordinator) {
        coordinator.flushPendingSave()
    }

    @MainActor
    final class Coordinator: EditorCoordinatorBase, UITextViewDelegate, UIGestureRecognizerDelegate, EditorHost, UIDropInteractionDelegate {
        weak var textView: AxTextView?
        weak var bar: FormatBar?

        func applyAppearance() {
            guard let tv = textView else { return }
            let theme = style.theme
            tv.backgroundColor = theme.backgroundColor
            tv.tintColor = theme.accentColor
            tv.maxLineWidth = config.lineWidth
            tv.spellCheckingType = config.spellCheck ? .yes : .no
            tv.autocorrectionType = config.spellCheck ? .default : .no
            tv.keyboardAppearance = theme.isDark ? .dark : .default
            tv.typingAttributes = [.font: style.bodyFont, .foregroundColor: theme.textColor]
            tv.placeholderLabel.text = "Start writing…"
            tv.placeholderLabel.font = style.bodyFont
            tv.placeholderLabel.textColor = theme.secondaryColor.withAlpha(0.7)
            tv.updatePlaceholder()
            bar?.tint = theme.accentColor
            tv.setNeedsLayout()
            if config.typewriter {
                tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: tv.bounds.height / 2, right: 0)
            } else {
                tv.contentInset = .zero
            }
        }

        // MARK: EditorHost

        func perform(_ cmd: FormatCommand) {
            guard let tv = textView else { return }
            guard let edit = Formatter.edit(for: cmd, text: snapshot(), selection: tv.selectedRange) else { return }
            replace(edit.range, with: edit.replacement, selection: edit.selection)
        }

        func insertText(_ text: String) {
            guard let tv = textView else { return }
            replace(tv.selectedRange, with: text, selection: nil)
        }

        func replace(_ range: NSRange, with string: String, selection: NSRange?) {
            guard let tv = textView,
                  let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
                  let end = tv.position(from: start, offset: range.length),
                  let textRange = tv.textRange(from: start, to: end) else { return }
            tv.replace(textRange, withText: string)
            if let selection, selection.location != NSNotFound, NSMaxRange(selection) <= storage.length { tv.selectedRange = selection }
            userDidEdit()
            updateCompletion(selection: tv.selectedRange)
        }

        override func replaceKeepingSelection(_ range: NSRange, with string: String) {
            guard let tv = textView else { return }
            let sel = tv.selectedRange
            replace(range, with: string, selection: sel)
        }

        func focusEditor() { textView?.becomeFirstResponder() }

        func scrollTo(markdownLocation: Int) {
            guard let tv = textView else { return }
            let loc = storageLocation(forMarkdown: markdownLocation)
            let glyph = layout.glyphIndexForCharacter(at: loc)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            tv.setContentOffset(CGPoint(x: 0, y: max(-tv.adjustedContentInset.top, rect.minY + tv.textContainerInset.top - 12)), animated: true)
            tv.selectedRange = NSRange(location: loc, length: 0)
        }

        // MARK: Attachments

        func attach(_ files: [(data: Data, name: String, mime: String)]) {
            let snippets = callbacks.onAttachFiles(files)
            guard !snippets.isEmpty, let tv = textView else { return }
            let sel = tv.selectedRange
            let ns = snapshot()
            let needsLeadingNewline = sel.location > 0 && ns.character(at: sel.location - 1) != 10
            let insertion = (needsLeadingNewline ? "\n" : "") + snippets.joined(separator: "\n") + "\n"
            replace(sel, with: insertion, selection: nil)
            // The plain-text insert becomes inline images once reloaded from Markdown.
            flushPendingSave()
            let caretMarkdown = lastMarkdown
            let caret = tv.selectedRange
            load(caretMarkdown)
            tv.selectedRange = NSRange(location: min(storage.length, caret.location - (insertion as NSString).length + snippets.count + (needsLeadingNewline ? 2 : 1)), length: 0)
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: ["public.image", "public.data"])
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            for item in session.items {
                let provider = item.itemProvider
                let type = provider.registeredTypeIdentifiers.first ?? "public.data"
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data else { return }
                    let name = provider.suggestedName ?? "Attachment"
                    let mime = UTTypeHelper.mime(forTypeIdentifier: type)
                    Task { @MainActor [weak self] in self?.attach([(data, name + UTTypeHelper.ext(forTypeIdentifier: type, name: name), mime)]) }
                }
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            userDidEdit()
            updateCompletion(selection: textView.selectedRange)
            updateReveal(selection: textView.selectedRange, focused: textView.isFirstResponder)
            textView.invalidatePlaceholder()
            typewriterScroll()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isLoading else { return }
            updateCompletion(selection: textView.selectedRange)
            updateReveal(selection: textView.selectedRange, focused: textView.isFirstResponder)
            if let attrs = typingAttributes(at: textView.selectedRange) { textView.typingAttributes = attrs }
            typewriterScroll()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            controller.isFocused = true
            updateReveal(selection: textView.selectedRange, focused: true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            controller.isFocused = false
            updateReveal(selection: textView.selectedRange, focused: false)
            flushPendingSave()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let ns = snapshot()
            if text == "\n", let edit = Formatter.newlineEdit(text: ns, selection: range) {
                replace(edit.range, with: edit.replacement, selection: edit.selection)
                return false
            }
            if text == "\t", range.length == 0, MarkdownSyntax.listItem.firstMatch(in: ns as String, range: ns.lineRange(for: range)) != nil {
                perform(.indent)
                return false
            }
            return true
        }

        override func completionChanged() {
            guard let bar else { return }
            if let c = controller.completion, !controller.suggestions.isEmpty {
                bar.showSuggestions(controller.suggestions, prefix: c.kind == .tag ? "#" : "")
            } else {
                bar.showFormatting()
            }
        }

        private func typewriterScroll() {
            guard config.typewriter, let tv = textView, let end = tv.selectedTextRange?.end else { return }
            let caret = tv.caretRect(for: end)
            let target = caret.midY - tv.bounds.height * 0.4
            if abs(tv.contentOffset.y - target) > 2 {
                tv.setContentOffset(CGPoint(x: 0, y: max(-tv.adjustedContentInset.top, target)), animated: true)
            }
        }

        // MARK: Taps

        private func characterIndex(at point: CGPoint) -> Int? {
            guard let tv = textView else { return nil }
            let p = CGPoint(x: point.x - tv.textContainerInset.left, y: point.y - tv.textContainerInset.top)
            var fraction: CGFloat = 0
            let index = layout.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -4, dy: -4)
            return rect.contains(p) ? index : nil
        }

        func isInteractive(point: CGPoint) -> Bool {
            guard let i = characterIndex(at: point) else { return false }
            return isInteractive(at: i)
        }

        private var wasEditingAtTouch = false

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            wasEditingAtTouch = textView?.isFirstResponder ?? false
            return true
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let i = characterIndex(at: g.location(in: textView)) else { return }
            if activate(at: i, commandKey: true), !wasEditingAtTouch {
                // Toggling a todo or following a link should not pop up the keyboard.
                DispatchQueue.main.async { [weak self] in self?.textView?.resignFirstResponder() }
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

#if os(macOS)
import AppKit

final class AxNSTextView: NSTextView {
    weak var coordinator: MarkdownEditor.Coordinator?
    var maxLineWidth: CGFloat = 720

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let c = coordinator, let i = c.characterIndex(at: point) {
            if c.activate(at: i, commandKey: event.modifierFlags.contains(.command)) { return }
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.updateReveal(selection: selectedRange(), focused: true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.updateReveal(selection: selectedRange(), focused: false) }
        return ok
    }

    override func paste(_ sender: Any?) {
        if coordinator?.pasteFiles(from: NSPasteboard.general) == true { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if coordinator?.pasteFiles(from: sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    func updateInsets() {
        let horizontal = max(24, (bounds.width - maxLineWidth) / 2)
        let vertical: CGFloat = 28
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: vertical)
        }
    }
}

struct MarkdownEditor: NSViewRepresentable {
    let noteId: String
    let markdown: String
    let config: EditorConfig
    let controller: EditorController
    let callbacks: EditorCallbacks
    var onAttachRequest: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(noteId: noteId, markdown: markdown, config: config, callbacks: callbacks, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = AxNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: c.container)
        tv.coordinator = c
        c.textView = tv
        tv.delegate = c
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        c.container.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        scroll.drawsBackground = true
        c.scrollView = scroll
        controller.host = c
        c.applyAppearance()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.textView else { return }
        c.callbacks = callbacks
        controller.host = c
        if c.noteId != noteId {
            c.flushPendingSave()
            c.noteId = noteId
            c.load(markdown)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.scroll(.zero)
            tv.undoManager?.removeAllActions()
        } else if markdown != c.lastMarkdown && markdown != c.markdown {
            tv.setSelectedRange(c.applyExternal(markdown, selection: tv.selectedRange()))
            tv.undoManager?.removeAllActions()
        }
        if c.applyConfig(config) { c.applyAppearance() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.flushPendingSave()
    }

    @MainActor
    final class Coordinator: EditorCoordinatorBase, NSTextViewDelegate, EditorHost {
        weak var textView: AxNSTextView?
        weak var scrollView: NSScrollView?

        func applyAppearance() {
            guard let tv = textView else { return }
            let theme = style.theme
            tv.backgroundColor = theme.backgroundColor
            scrollView?.backgroundColor = theme.backgroundColor
            tv.insertionPointColor = theme.accentColor
            tv.selectedTextAttributes = [.backgroundColor: theme.accentColor.withAlpha(0.22)]
            tv.isContinuousSpellCheckingEnabled = config.spellCheck
            tv.isGrammarCheckingEnabled = false
            tv.typingAttributes = [.font: style.bodyFont, .foregroundColor: theme.textColor]
            tv.setValue(NSAttributedString(string: "Start writing…", attributes: [.font: style.bodyFont, .foregroundColor: theme.secondaryColor.withAlpha(0.7)]),
                        forKey: "placeholderAttributedString")
            tv.maxLineWidth = config.lineWidth
            tv.textContainerInset = .zero
            tv.updateInsets()
            if let scroll = scrollView {
                scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: config.typewriter ? scroll.bounds.height / 2 : 0, right: 0)
            }
            tv.needsDisplay = true
        }

        func characterIndex(at point: NSPoint) -> Int? {
            guard let tv = textView else { return nil }
            let origin = tv.textContainerOrigin
            let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            var fraction: CGFloat = 0
            let index = layout.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            guard index < storage.length else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -3, dy: -3)
            return rect.contains(p) ? index : nil
        }

        func pasteFiles(from pb: NSPasteboard) -> Bool {
            var files: [(data: Data, name: String, mime: String)] = []
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                for url in urls {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    files.append((data, url.lastPathComponent, UTTypeHelper.mime(forExtension: url.pathExtension)))
                }
            } else if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb), let data = image.pngData() {
                files.append((data, "Image.png", "image/png"))
            }
            guard !files.isEmpty else { return false }
            attach(files)
            return true
        }

        func attach(_ files: [(data: Data, name: String, mime: String)]) {
            let snippets = callbacks.onAttachFiles(files)
            guard !snippets.isEmpty, let tv = textView else { return }
            let sel = tv.selectedRange()
            let ns = snapshot()
            let needsLeadingNewline = sel.location > 0 && ns.character(at: sel.location - 1) != 10
            let insertion = (needsLeadingNewline ? "\n" : "") + snippets.joined(separator: "\n") + "\n"
            replace(sel, with: insertion, selection: nil)
            flushPendingSave()
            let caret = tv.selectedRange()
            load(lastMarkdown)
            let newCaret = caret.location - (insertion as NSString).length + snippets.count + (needsLeadingNewline ? 2 : 1)
            tv.setSelectedRange(NSRange(location: max(0, min(storage.length, newCaret)), length: 0))
        }

        // MARK: EditorHost

        func perform(_ cmd: FormatCommand) {
            guard let tv = textView else { return }
            guard let edit = Formatter.edit(for: cmd, text: snapshot(), selection: tv.selectedRange()) else { return }
            replace(edit.range, with: edit.replacement, selection: edit.selection)
        }

        func insertText(_ text: String) {
            guard let tv = textView else { return }
            replace(tv.selectedRange(), with: text, selection: nil)
        }

        func replace(_ range: NSRange, with string: String, selection: NSRange?) {
            guard let tv = textView, NSMaxRange(range) <= storage.length else { return }
            if tv.shouldChangeText(in: range, replacementString: string) {
                storage.replaceCharacters(in: range, with: string)
                tv.didChangeText()
            }
            if let selection, selection.location != NSNotFound, NSMaxRange(selection) <= storage.length {
                tv.setSelectedRange(selection)
            } else if selection == nil {
                tv.setSelectedRange(NSRange(location: min(storage.length, range.location + (string as NSString).length), length: 0))
            }
            updateCompletion(selection: tv.selectedRange())
        }

        override func replaceKeepingSelection(_ range: NSRange, with string: String) {
            guard let tv = textView else { return }
            replace(range, with: string, selection: tv.selectedRange())
        }

        func focusEditor() {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
        }

        func scrollTo(markdownLocation: Int) {
            guard let tv = textView else { return }
            let loc = storageLocation(forMarkdown: markdownLocation)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: loc)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            tv.scroll(NSPoint(x: 0, y: max(0, rect.minY + tv.textContainerOrigin.y - 16)))
            focusEditor()
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            userDidEdit()
            if let tv = textView {
                updateCompletion(selection: tv.selectedRange())
                updateReveal(selection: tv.selectedRange(), focused: true)
            }
            typewriterScroll()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading, let tv = textView else { return }
            updateCompletion(selection: tv.selectedRange())
            updateReveal(selection: tv.selectedRange(), focused: tv.window?.firstResponder === tv)
            if let attrs = typingAttributes(at: tv.selectedRange()) { tv.typingAttributes = attrs }
        }

        func textDidBeginEditing(_ notification: Notification) { controller.isFocused = true }

        func textDidEndEditing(_ notification: Notification) {
            controller.isFocused = false
            flushPendingSave()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if controller.completion != nil, !controller.suggestions.isEmpty {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): controller.moveSuggestion(-1); return true
                case #selector(NSResponder.moveDown(_:)): controller.moveSuggestion(1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    controller.accept(controller.suggestions[min(controller.highlightedSuggestion, controller.suggestions.count - 1)])
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    controller.completion = nil
                    controller.suggestions = []
                    return true
                default: break
                }
            }
            let ns = snapshot()
            let sel = textView.selectedRange()
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let edit = Formatter.newlineEdit(text: ns, selection: sel) {
                    replace(edit.range, with: edit.replacement, selection: edit.selection)
                    return true
                }
            case #selector(NSResponder.insertTab(_:)):
                if MarkdownSyntax.listItem.firstMatch(in: ns as String, range: ns.lineRange(for: sel)) != nil || sel.length > 0 {
                    perform(.indent); return true
                }
            case #selector(NSResponder.insertBacktab(_:)):
                perform(.outdent); return true
            default: break
            }
            return false
        }

        private func typewriterScroll() {
            guard config.typewriter, let tv = textView, let scroll = scrollView else { return }
            let glyph = layout.glyphIndexForCharacter(at: min(tv.selectedRange().location, max(0, storage.length - 1)))
            guard storage.length > 0 else { return }
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let target = rect.midY + tv.textContainerOrigin.y - scroll.contentView.bounds.height * 0.4
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, target)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
#endif

enum UTTypeHelper {
    static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "pdf": return "application/pdf"
        case "txt", "md", "markdown": return "text/plain"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    static func mime(forTypeIdentifier type: String) -> String {
        switch type {
        case "public.png": return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "public.heic": return "image/heic"
        case "com.compuserve.gif": return "image/gif"
        case "com.adobe.pdf": return "application/pdf"
        default: return type.contains("image") ? "image/jpeg" : "application/octet-stream"
        }
    }

    static func ext(forTypeIdentifier type: String, name: String) -> String {
        if name.contains(".") { return "" }
        switch type {
        case "public.png": return ".png"
        case "public.jpeg": return ".jpg"
        case "public.heic": return ".heic"
        case "com.compuserve.gif": return ".gif"
        case "com.adobe.pdf": return ".pdf"
        default: return ""
        }
    }
}
