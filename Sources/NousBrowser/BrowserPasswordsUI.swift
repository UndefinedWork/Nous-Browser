import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
@Observable
final class BrowserPasswordController {
    enum Mode { case importing, filling }
    let model: BrowserModel
    var isPresented = false
    var mode: Mode = .importing
    var isChoosingFile = false
    var isBusy = false
    var message: String?
    var accounts: [BrowserPasswordCredential] = []
    var website = ""
    @ObservationIgnored private var targetTabID: UUID?
    @ObservationIgnored private var target: BrowserPasswordAutofill.Candidate?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    init(model: BrowserModel) { self.model = model }

    var canFill: Bool {
        model.selectedTab?.passwordCandidate != nil && model.selectedTab?.errorDescription == nil
            && model.selectedTab?.isLoading == false
    }

    func presentImport() {
        guard !isBusy else { return }
        reset()
        mode = .importing
        isPresented = true
    }

    func presentFill() {
        guard !isBusy else { return }
        reset()
        mode = .filling
        targetTabID = model.selectedTabID
        target = model.selectedTab?.passwordCandidate
        website = target?.origin.serialized ?? ""
        if target == nil { message = L10n.string("This page has no supported secure sign-in form.") }
        isPresented = true
    }

    func dismiss() {
        reset()
        isPresented = false
    }

    func reset() {
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        expiry?.cancel()
        expiry = nil
        accounts.removeAll()
        target = nil
        targetTabID = nil
        website = ""
        message = nil
        isBusy = false
        isChoosingFile = false
    }

    func clearUnlockedAccounts() {
        // Authentication dialogs may temporarily take activation. Never retain
        // unlocked values after a completed operation loses activation.
        guard !isBusy else { return }
        accounts.removeAll()
        expiry?.cancel()
        expiry = nil
    }

    func dismissIfPageChanged() {
        guard isPresented, mode == .filling, validTarget() == nil else { return }
        dismiss()
    }

    private func validTarget() -> (BrowserTab, BrowserPasswordAutofill.Candidate)? {
        guard let id = targetTabID, model.selectedTabID == id,
              let tab = model.selectedTab, tab.errorDescription == nil, !tab.webView.isLoading, let expected = target,
              let live = tab.passwordCandidate, live.token == expected.token,
              live.origin == expected.origin,
              let url = tab.webView.url,
              BrowserPasswordAutofill.Origin(url: url) == expected.origin else { return nil }
        return (tab, expected)
    }

    func unlock() {
        guard !isBusy, let (_, candidate) = validTarget(),
              let origin = PasswordOrigin(url: candidate.frameURL) else {
            message = L10n.string("The page changed. Try again.")
            return
        }
        let operation = UUID()
        operationID = operation
        isBusy = true
        message = nil
        operationTask = Task { @MainActor in
            defer { if operationID == operation { operationTask = nil } }
            do {
                let matches = try await BrowserPasswordStore.shared.credentials(
                    for: origin, reason: L10n.format("Fill the saved password for %@", website))
                guard operationID == operation else { return }
                isBusy = false
                guard isPresented, NSApp.isActive, validTarget() != nil else {
                    message = L10n.string("The page changed. Try again.")
                    return
                }
                if matches.isEmpty {
                    message = L10n.string("No saved passwords for this website.")
                } else if matches.count == 1, let account = matches.first {
                    await fill(account)
                } else {
                    accounts = matches
                    expiry = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        accounts.removeAll()
                    }
                }
            } catch {
                guard operationID == operation else { return }
                isBusy = false
                if !Self.isCancellation(error) {
                    message = (error as? BrowserPasswordStoreError)?.errorDescription
                        ?? L10n.string("Could not access saved passwords.")
                }
            }
        }
    }

    func chooseAccount(_ credential: BrowserPasswordCredential) {
        guard !isBusy, accounts.contains(where: { $0.id == credential.id }) else { return }
        let operation = UUID()
        operationID = operation
        isBusy = true
        operationTask = Task { @MainActor in
            defer { if operationID == operation { operationTask = nil } }
            guard operationID == operation, !Task.isCancelled else { return }
            await fill(credential)
        }
    }

    private func fill(_ credential: BrowserPasswordCredential) async {
        guard !Task.isCancelled, let (tab, candidate) = validTarget(), NSApp.isActive,
              PasswordOrigin(url: candidate.frameURL) == credential.origin else {
            accounts.removeAll()
            isBusy = false
            message = L10n.string("The page changed. Try again.")
            return
        }
        isBusy = true
        accounts.removeAll()
        expiry?.cancel()
        let operation = operationID
        do {
            try Task.checkCancellation()
            _ = try await BrowserPasswordAutofill.fill(
                .init(username: credential.username, password: credential.password),
                in: tab.webView, expectedOrigin: candidate.origin, token: candidate.token)
            guard operationID == operation else { return }
            dismiss()
        } catch {
            guard operationID == operation else { return }
            isBusy = false
            message = L10n.string("The page changed. Try again.")
        }
    }

    func importFile(_ result: Result<URL, Error>) {
        guard isPresented, mode == .importing, !isBusy else { return }
        guard case let .success(url) = result else { return }
        let operation = UUID()
        operationID = operation
        isBusy = true
        message = nil
        operationTask = Task { @MainActor in
            defer { if operationID == operation { operationTask = nil } }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard file.isRegularFile == true else { throw BrowserPasswordStoreError.invalidCSV }
                guard (file.fileSize ?? 0) <= 10 * 1024 * 1024 else {
                    isBusy = false
                    message = L10n.string("The CSV file is too large.")
                    return
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 10 * 1024 * 1024 + 1) ?? Data()
                guard data.count <= 10 * 1024 * 1024 else {
                    isBusy = false
                    message = L10n.string("The CSV file is too large.")
                    return
                }
                let imported = try await BrowserPasswordStore.shared.importCSV(
                    data, reason: L10n.string("Import Passwords with Nous Browser"))
                guard operationID == operation else { return }
                isBusy = false
                message = L10n.format("Imported %ld, updated %ld, skipped %ld.",
                                      imported.imported, imported.updated, imported.skipped)
            } catch {
                guard operationID == operation else { return }
                isBusy = false
                if !Self.isCancellation(error) {
                    message = (error as? BrowserPasswordStoreError)?.errorDescription
                        ?? L10n.string("Could not import passwords.")
                }
            }
        }
    }

    func openApplePasswords() {
        let url = URL(fileURLWithPath: "/System/Applications/Passwords.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in self.message = L10n.string("Unable to open this app.") } }
        }
    }

    func openChromePasswords() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let url = URL(string: "chrome://password-manager/settings") else {
            message = L10n.string("Unable to open this app.")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in self.message = L10n.string("Unable to open this app.") } }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == LAError.errorDomain
            && [LAError.Code.userCancel.rawValue, LAError.Code.systemCancel.rawValue,
                LAError.Code.appCancel.rawValue].contains(error.code)
    }
}

struct BrowserPasswordsSheet: View {
    @Bindable var controller: BrowserPasswordController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "key.fill").font(.system(size: 22))
                Text(L10n.string(controller.mode == .importing ? "Import Passwords" : "Fill Password"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button { controller.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("Close"))
            }
            Text(L10n.string("Passwords stay in your Mac’s keychain. Your Mac verifies you before import and filling."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if controller.mode == .importing {
                Text(L10n.string("Export passwords from Apple Passwords or Chrome, then choose the CSV file here."))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.string("Open Apple Passwords"), systemImage: "key", action: controller.openApplePasswords)
                    Button(L10n.string("Open Chrome Password Manager"), systemImage: "globe", action: controller.openChromePasswords)
                }.controlSize(.small).disabled(controller.isBusy)
                Text(L10n.string("Exported CSV files contain readable passwords. Move the export to Trash after importing."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if !controller.website.isEmpty { Text(controller.website).font(.headline) }
                if !controller.accounts.isEmpty {
                    Text(L10n.string("Choose an Account")).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(controller.accounts, id: \.id) { account in
                                Button { controller.chooseAccount(account) } label: {
                                    HStack {
                                        Image(systemName: "person.crop.circle")
                                        Text(account.username.isEmpty ? account.title : account.username).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.right")
                                    }.padding(10).contentShape(Rectangle())
                                }.buttonStyle(.bordered)
                            }
                        }
                    }.frame(maxHeight: 180).scrollIndicators(.hidden)
                }
            }

            if controller.isBusy {
                HStack { ProgressView().controlSize(.small)
                    Text(L10n.string(controller.mode == .importing ? "Importing passwords…" : "Verifying with your Mac…"))
                }
            }
            if let message = controller.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if controller.mode == .filling {
                    Button(L10n.string("Import Passwords…")) { controller.presentImport() }
                        .disabled(controller.isBusy)
                }
                Spacer()
                Button(L10n.string(controller.isBusy ? "Cancel" : "Done"), action: controller.dismiss)
                    .keyboardShortcut(.cancelAction)
                if controller.mode == .importing {
                    Button(L10n.string("Choose CSV…")) { controller.isChoosingFile = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy)
                } else if controller.accounts.isEmpty && controller.canFill {
                    Button(L10n.string("Unlock and Fill"), systemImage: "lock.open", action: controller.unlock)
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy)
                }
            }
        }
        .padding(24).frame(width: 490)
        .fileImporter(isPresented: $controller.isChoosingFile, allowedContentTypes: [.commaSeparatedText], onCompletion: controller.importFile)
        .onDisappear { controller.reset() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            controller.clearUnlockedAccounts()
        }
        .onChange(of: controller.model.selectedTab?.passwordCandidate?.token) { _, _ in
            controller.clearUnlockedAccounts()
            controller.dismissIfPageChanged()
        }
    }
}
