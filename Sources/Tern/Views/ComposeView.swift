import MailEngine
import SwiftUI
import UniformTypeIdentifiers

enum ComposeField: Hashable {
    case to, cc, bcc, subject, body
}

@MainActor
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ComposeDraft
    @State private var showCcBcc: Bool
    @State private var isSending = false
    @State private var errorText: String?
    @State private var showFileImporter = false
    @State private var confirmDiscard = false
    @FocusState private var focus: ComposeField?

    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
        _showCcBcc = State(initialValue: draft.showsCcBcc)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.accounts.count > 1 {
                FieldRow(label: "From") {
                    Picker("From", selection: $draft.accountID) {
                        ForEach(model.accounts) { account in
                            Text(account.senderName.isEmpty ? account.email : "\(account.senderName) <\(account.email)>")
                                .tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
            }
            RecipientField(label: "To", text: $draft.to, focus: $focus, field: .to) {
                if !showCcBcc {
                    Button("Cc/Bcc") {
                        showCcBcc = true
                        focus = .cc
                    }
                    .buttonStyle(.borderless)
                    .help("Add Cc and Bcc recipients")
                }
            }
            if showCcBcc {
                RecipientField(label: "Cc", text: $draft.cc, focus: $focus, field: .cc) { EmptyView() }
                RecipientField(label: "Bcc", text: $draft.bcc, focus: $focus, field: .bcc) { EmptyView() }
            }
            FieldRow(label: "Subject") {
                TextField("Subject", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focus, equals: .subject)
                    .onSubmit { focus = .body }
            }
            Divider()
            TextEditor(text: $draft.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .focused($focus, equals: .body)
                .accessibilityLabel("Message")
            if !draft.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.attachments, id: \.self) { url in
                            ComposeAttachmentChip(url: url) {
                                draft.attachments.removeAll { $0 == url }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if draft.isEmpty && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        dismiss()
                    } else {
                        confirmDiscard = true
                    }
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .help("Discard this message")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Attach files", systemImage: "paperclip")
                }
                .help("Attach files. You can also drag files onto this window.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: send) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Sending")
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending)
                .help("Send (⌘↩)")
            }
        }
        .confirmationDialog("Discard this message?", isPresented: $confirmDiscard) {
            Button("Discard message", role: .destructive) { dismiss() }
        } message: {
            Text("What you wrote won't be saved.")
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                draft.attachments += urls.filter { !draft.attachments.contains($0) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            draft.attachments += files.filter { !draft.attachments.contains($0) }
            return !files.isEmpty
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            if draft.accountID == nil { draft.accountID = model.accounts.first?.id }
            focus = draft.to.isEmpty ? .to : .body
        }
    }

    private func send() {
        guard !isSending else { return }
        errorText = nil
        isSending = true
        let toSend = draft
        Task {
            do {
                try await model.send(toSend)
                dismiss()
            } catch {
                errorText = "Not sent. \(AppModel.describe(error))"
            }
            isSending = false
        }
    }
}

@MainActor
private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
            content
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }
}

@MainActor
private struct RecipientField<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let label: String
    @Binding var text: String
    var focus: FocusState<ComposeField?>.Binding
    let field: ComposeField
    @ViewBuilder var trailing: Trailing

    /// What is being typed after the last comma.
    private var currentToken: String {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        return pieces.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private var suggestions: [EmailAddress] {
        guard focus.wrappedValue == field else { return [] }
        let token = currentToken
        guard token.count >= 1, !token.contains(">") else { return [] }
        let matches = model.contactSuggestions(matching: token)
        if matches.count == 1, matches[0].address.lowercased() == token.lowercased() { return [] }
        return matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldRow(label: label) {
                TextField(label, text: $text)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused(focus, equals: field)
                    .onSubmit {
                        if let first = suggestions.first { accept(first) }
                    }
                trailing
            }
            let current = suggestions
            if !current.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(current, id: \.address) { address in
                        Button {
                            accept(address)
                        } label: {
                            HStack(spacing: 8) {
                                Avatar(address: address, size: 20)
                                Text(address.name ?? address.address)
                                if address.name != nil {
                                    Text(address.address)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Press Return to use the first suggestion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .padding(.leading, 68)
                .padding(.bottom, 6)
            }
            Divider()
        }
    }

    private func accept(_ address: EmailAddress) {
        var pieces = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if pieces.isEmpty { pieces = [""] }
        pieces[pieces.count - 1] = " " + address.editableValue
        text = pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }
}

@MainActor
private struct ComposeAttachmentChip: View {
    let url: URL
    var remove: () -> Void

    private var sizeText: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
        .frame(maxWidth: 240, alignment: .leading)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
