import MailEngine
import SwiftUI

@MainActor
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ProviderPreset?
    @State private var senderName = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var zohoRegion = ZohoRegion.us
    @State private var zohoOrganization = false

    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var imapSecurity = ConnectionSecurity.tls
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var smtpSecurity = ConnectionSecurity.tls
    @State private var username = ""
    @State private var showServers = false

    @State private var phase: Phase = .idle
    @State private var errorText: String?
    @State private var lookedUpEmail: String?

    enum Phase: Equatable {
        case idle, lookingUp, signingIn
    }

    var body: some View {
        VStack(spacing: 0) {
            if let provider {
                details(provider)
            } else {
                chooser
            }
        }
        .frame(width: 560)
        .interactiveDismissDisabled(phase != .idle)
    }

    // MARK: Step 1: pick a provider

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an email account")
                    .font(.title2.weight(.semibold))
                Text("Pick your provider. For anything else, choose Other and Tern finds the settings.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(ProviderPreset.all) { preset in
                    Button {
                        choose(preset)
                    } label: {
                        VStack(spacing: 8) {
                            Text(String(preset.name.prefix(1)))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(preset.id == "other" ? Theme.palette[7] : Theme.color(for: preset.id)))
                                .accessibilityHidden(true)
                            Text(preset.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(preset.domains.first ?? "Any IMAP account")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                }
            }
            Text("Outlook.com and Microsoft 365 need Microsoft sign-in, which Tern doesn't support yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }

    private func choose(_ preset: ProviderPreset) {
        provider = preset
        errorText = nil
        apply(preset)
        showServers = preset.id == "other"
    }

    private func apply(_ preset: ProviderPreset) {
        imapHost = preset.imapHost
        imapPort = preset.imapPort
        imapSecurity = preset.imapSecurity
        smtpHost = preset.smtpHost
        smtpPort = preset.smtpPort
        smtpSecurity = preset.smtpSecurity
        if preset.id == "zoho" { applyZohoHosts() }
    }

    private func applyZohoHosts() {
        let hosts = ProviderPreset.zohoHosts(region: zohoRegion, organization: zohoOrganization)
        imapHost = hosts.imap
        smtpHost = hosts.smtp
    }

    // MARK: Step 2: sign in

    private func details(_ preset: ProviderPreset) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Your name", text: $senderName, prompt: Text("Jane Appleseed"))
                    TextField("Email address", text: $email, prompt: Text("you@\(preset.domains.first ?? "example.com")"))
                        .textContentType(.username)
                        .onSubmit { emailCommitted() }
                    SecureField(preset.passwordHelpURL != nil ? "App password" : "Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Sign in to \(preset.name)")
                        .font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.passwordHelp)
                        if let url = preset.passwordHelpURL, let title = preset.passwordHelpLinkTitle {
                            Link(title, destination: url)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if preset.id == "zoho" {
                    Section {
                        Picker("Data center", selection: $zohoRegion) {
                            ForEach(ZohoRegion.allCases) { region in
                                Text(region.label).tag(region)
                            }
                        }
                        Toggle("This address uses my own domain", isOn: $zohoOrganization)
                    } footer: {
                        Text("Turn this on for Zoho Mail for organizations, where your address ends in your company's domain.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: zohoRegion) { _, _ in applyZohoHosts() }
                    .onChange(of: zohoOrganization) { _, _ in applyZohoHosts() }
                }

                Section {
                    DisclosureGroup("Server settings", isExpanded: $showServers) {
                        LabeledContent("Incoming (IMAP)") {
                            ServerFields(host: $imapHost, port: $imapPort, security: $imapSecurity)
                        }
                        LabeledContent("Outgoing (SMTP)") {
                            ServerFields(host: $smtpHost, port: $smtpPort, security: $smtpSecurity)
                        }
                        TextField("User name", text: $username, prompt: Text("Same as email address"))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(false)
            .frame(minHeight: 380)

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }

            HStack(spacing: 8) {
                Button("Back") {
                    provider = nil
                    errorText = nil
                }
                .disabled(phase != .idle)
                Spacer()
                if phase != .idle {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase == .lookingUp ? "Finding server settings…" : "Signing in…")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign in") { signIn(preset) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || phase != .idle)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        EmailAddress(address: trimmedEmail).isValid && !password.isEmpty
    }

    /// With "Other", typing a Gmail or iCloud address switches to the right preset.
    private func emailCommitted() {
        guard provider?.id == "other", let match = ProviderPreset.matching(email: trimmedEmail) else { return }
        choose(match)
        zohoRegion = ZohoRegion.guess(email: trimmedEmail)
        if match.id == "zoho" { applyZohoHosts() }
    }

    private func signIn(_ preset: ProviderPreset) {
        errorText = nil
        let address = trimmedEmail
        Task {
            if preset.id == "other" && (imapHost.isEmpty || smtpHost.isEmpty || lookedUpEmail != address) {
                if let match = ProviderPreset.matching(email: address) {
                    choose(match)
                } else {
                    phase = .lookingUp
                    let found = await Autoconfig.lookup(email: address) ?? Autoconfig.guess(email: address)
                    lookedUpEmail = address
                    imapHost = found.imap.host
                    imapPort = found.imap.port
                    imapSecurity = found.imap.security
                    smtpHost = found.smtp.host
                    smtpPort = found.smtp.port
                    smtpSecurity = found.smtp.security
                    if found.imap.username != address { username = found.imap.username }
                }
            }
            let chosen = provider ?? preset
            let login = username.trimmingCharacters(in: .whitespaces).isEmpty ? address : username.trimmingCharacters(in: .whitespaces)
            let account = AccountConfig(
                senderName: senderName.trimmingCharacters(in: .whitespacesAndNewlines),
                email: address,
                providerID: chosen.id,
                imap: ServerConfig(host: imapHost.trimmingCharacters(in: .whitespaces), port: imapPort, security: imapSecurity, username: login),
                smtp: ServerConfig(host: smtpHost.trimmingCharacters(in: .whitespaces), port: smtpPort, security: smtpSecurity, username: login)
            )
            if model.accounts.contains(where: { $0.email.lowercased() == address.lowercased() }) {
                errorText = "\(address) is already in Tern."
                phase = .idle
                return
            }
            phase = .signingIn
            do {
                try await model.verify(account, password: password)
                try model.addAccount(account, password: password)
                phase = .idle
                dismiss()
            } catch {
                phase = .idle
                showServers = true
                errorText = AppModel.describe(error)
            }
        }
    }
}

@MainActor
private struct ServerFields: View {
    @Binding var host: String
    @Binding var port: Int
    @Binding var security: ConnectionSecurity

    var body: some View {
        HStack(spacing: 6) {
            TextField("Server", text: $host, prompt: Text("mail.example.com"))
                .frame(minWidth: 150)
            TextField("Port", value: $port, format: .number.grouping(.never))
                .frame(width: 56)
            Picker("Security", selection: $security) {
                Text("SSL/TLS").tag(ConnectionSecurity.tls)
                Text("STARTTLS").tag(ConnectionSecurity.startTLS)
                Text("None").tag(ConnectionSecurity.none)
            }
            .labelsHidden()
            .fixedSize()
        }
        .labelsHidden()
    }
}
