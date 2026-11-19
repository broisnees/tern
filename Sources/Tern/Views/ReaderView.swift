import AppKit
import MailEngine
import SwiftUI
import WebKit

@MainActor
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.reader {
            case .empty:
                ContentUnavailableView {
                    Label("No message selected", systemImage: "envelope")
                } description: {
                    Text("Pick a message from the list to read it here.")
                }
            case .multiple(let count):
                ContentUnavailableView {
                    Label("\(count) messages selected", systemImage: "tray.full")
                } description: {
                    Text("Use the toolbar to archive, delete or mark them all at once.")
                }
            case .loading(let summary):
                VStack(spacing: 0) {
                    MessageHeader(summary: summary, parsed: nil)
                    Divider()
                    ProgressView("Downloading message…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .failed(let summary, let message):
                VStack(spacing: 0) {
                    MessageHeader(summary: summary, parsed: nil)
                    Divider()
                    ContentUnavailableView {
                        Label("Couldn't download this message", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { model.retryOpen() }
                    }
                }
            case .loaded(let summary, let parsed):
                MessageDetail(summary: summary, parsed: parsed)
            }
        }
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let ids = model.selectedMessageIDs
        let messages = model.selectedMessages
        let single = messages.count == 1 ? messages.first : nil
        let hasSelection = !messages.isEmpty

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.archive(ids) } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive (⌃⌘A or E)")
                .disabled(!hasSelection)
            Button { model.trash(ids) } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move to Trash (⌘⌫ or #)")
                .disabled(!hasSelection)
            Button { model.markSpam(ids) } label: { Label("Mark as spam", systemImage: "xmark.bin") }
                .help("Mark as spam (⇧⌘J)")
                .disabled(!hasSelection)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.toggleRead(ids) } label: {
                let unread = messages.contains { !$0.isSeen }
                Label(unread ? "Mark as read" : "Mark as unread", systemImage: unread ? "envelope.open" : "envelope.badge")
            }
            .help("Mark as read or unread (⇧⌘U or U)")
            .disabled(!hasSelection)
            Button { model.toggleFlag(ids) } label: {
                let starred = hasSelection && messages.allSatisfy(\.isFlagged)
                Label(starred ? "Remove star" : "Star", systemImage: starred ? "star.fill" : "star")
            }
            .help("Star (⇧⌘L or S)")
            .disabled(!hasSelection)
            Menu {
                MoveMenu(ids: ids, asSubmenu: false)
            } label: {
                Label("Move to folder", systemImage: "folder")
            }
            .help("Move to folder")
            .disabled(!hasSelection)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let single { openWindow(id: "compose", value: model.replyDraft(.reply, to: single)) }
            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply (⌘R or R)")
                .disabled(single == nil)
            Button {
                if let single { openWindow(id: "compose", value: model.replyDraft(.replyAll, to: single)) }
            } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
                .help("Reply all (⇧⌘R or A)")
                .disabled(single == nil)
            Button {
                if let single { openWindow(id: "compose", value: model.replyDraft(.forward, to: single)) }
            } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward (⇧⌘F or F)")
                .disabled(single == nil)
        }
    }
}

@MainActor
private struct MessageHeader: View {
    @Environment(AppModel.self) private var model
    let summary: MessageSummary
    let parsed: ParsedMessage?

    private var sender: EmailAddress? { parsed?.from.first ?? summary.from.first }

    private var recipientsLine: String {
        let own = Set(model.accounts.map { $0.email.lowercased() })
        func names(_ list: [EmailAddress]) -> String {
            list.map { own.contains($0.address.lowercased()) ? "me" : ($0.name ?? $0.address) }.joined(separator: ", ")
        }
        let to = parsed?.to ?? summary.to
        let cc = parsed?.cc ?? summary.cc
        var line = "To: " + (to.isEmpty ? "undisclosed recipients" : names(to))
        if !cc.isEmpty { line += "   Cc: " + names(cc) }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(parsed.map { $0.subject.isEmpty ? "(no subject)" : $0.subject } ?? summary.subjectDisplay)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Avatar(address: sender, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(sender?.name ?? sender?.address ?? "(no sender)")
                            .fontWeight(.semibold)
                        if sender?.name != nil, let address = sender?.address {
                            Text(address)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .textSelection(.enabled)
                    Text(recipientsLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Text(DateText.full(summary.date))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct MessageDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.loadRemoteImages) private var alwaysLoadImages = false
    let summary: MessageSummary
    let parsed: ParsedMessage

    private var html: String? { parsed.htmlWithInlineImages() }
    private var allowRemote: Bool { alwaysLoadImages || model.remoteImagesAllowed.contains(summary.id) }

    var body: some View {
        VStack(spacing: 0) {
            MessageHeader(summary: summary, parsed: parsed)
            if !parsed.visibleAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(parsed.visibleAttachments) { attachment in
                            AttachmentChip(attachment: attachment)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 14)
            }
            if let html, !allowRemote, MessageHTML.hasRemoteContent(html) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text("Images from the web are hidden. Loading them can tell the sender you opened this email.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Load images") { model.remoteImagesAllowed.insert(summary.id) }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(.bar)
            }
            Divider()
            MessageWebView(
                document: html.map { MessageHTML.document(html: $0, allowRemote: allowRemote) }
                    ?? MessageHTML.plainDocument(parsed.plainText),
                contentKey: "\(summary.id)|\(allowRemote)",
                isHTML: html != nil,
                onMailto: { url in
                    if let draft = ContentView.draft(fromMailto: url, model: model) {
                        openWindow(id: "compose", value: draft)
                    }
                }
            )
            .background(html != nil ? Color.white : Color.clear)
        }
    }
}

@MainActor
private struct AttachmentChip: View {
    @Environment(AppModel.self) private var model
    let attachment: MailAttachment

    var body: some View {
        Button {
            model.open(attachment)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: attachment.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(attachment.sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open \(attachment.filename)")
        .contextMenu {
            Button("Open") { model.open(attachment) }
            Button("Save As…") { model.save(attachment) }
        }
    }
}

enum MessageHTML {
    private static let remotePattern = try? NSRegularExpression(
        pattern: #"(src|background|srcset)\s*=\s*["']?\s*(https?:)?//|url\(\s*["']?\s*(https?:)?//"#,
        options: [.caseInsensitive]
    )

    static func hasRemoteContent(_ html: String) -> Bool {
        guard let remotePattern else { return false }
        return remotePattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    /// Wraps an email's HTML with a content security policy: never scripts, frames or forms,
    /// and no network loads unless the person allowed images.
    static func document(html: String, allowRemote: Bool) -> String {
        let csp = allowRemote
            ? "default-src 'none'; img-src * data: blob:; style-src * 'unsafe-inline'; font-src * data:; media-src *"
            : "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:"
        let head = """
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <style>
          html { background: #ffffff; color: #1d1d1f; }
          body { margin: 20px 24px 40px; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; overflow-wrap: anywhere; }
          img { max-width: 100%; }
          blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid #d2d2d7; color: #515154; }
        </style>
        """
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            var copy = html
            copy.insert(contentsOf: head, at: range.upperBound)
            return copy
        }
        if let range = html.range(of: "<html", options: .caseInsensitive),
           let close = html[range.upperBound...].firstIndex(of: ">") {
            var copy = html
            copy.insert(contentsOf: "<head>\(head)</head>", at: html.index(after: close))
            return copy
        }
        return "<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"
    }

    static func plainDocument(_ text: String) -> String {
        let body = HTMLText.plainTextToHTML(text)
        return """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; }
          body { margin: 20px 24px 40px; font: 14px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; background: transparent; }
          pre { white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; margin: 0; max-width: 72ch; }
          a { color: #0f766e; }
          @media (prefers-color-scheme: dark) { body { color: #f5f5f7; } a { color: #5eead4; } }
        </style>
        </head><body><pre>\(body)</pre></body></html>
        """
    }
}

/// WKWebView with JavaScript off, a throwaway data store, and links opened in the browser.
struct MessageWebView: NSViewRepresentable {
    let document: String
    let contentKey: String
    let isHTML: Bool
    var onMailto: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMailto = onMailto
        // Plain-text mail shows the window background through the page.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) || webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(isHTML, forKey: "drawsBackground")
        }
        guard context.coordinator.loadedKey != contentKey else { return }
        context.coordinator.loadedKey = contentKey
        webView.loadHTMLString(document, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedKey: String?
        var onMailto: ((URL) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .other && url.scheme == "about" { return .allow }
            if navigationAction.navigationType == .linkActivated { openExternally(url) }
            return .cancel
        }

        // target="_blank" links
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        private func openExternally(_ url: URL) {
            switch url.scheme?.lowercased() {
            case "mailto":
                onMailto?(url)
            case "http", "https":
                NSWorkspace.shared.open(url)
            default:
                break
            }
        }
    }
}
