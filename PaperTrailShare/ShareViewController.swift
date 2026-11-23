import PaperTrailKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformViewController = UIViewController
#else
import AppKit
typealias PlatformViewController = NSViewController
#endif

/// Share → Paper Trail. Copies shared PDFs and images into the App Group's Incoming folder;
/// the app moves them to Needs Review the next time it runs. Nothing is sent anywhere else.
final class ShareViewController: PlatformViewController {
    private let model = ShareModel()

    #if os(iOS)
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in self?.finish() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        start()
    }
    #else
    override func loadView() {
        view = NSHostingView(rootView: ShareView(model: model) { [weak self] in self?.finish() })
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        start()
    }
    #endif

    private func start() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.save(providers) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
final class ShareModel {
    enum State: Equatable {
        case saving
        case saved(Int)
        case failed(String)
    }

    var state = State.saving

    func save(_ providers: [NSItemProvider]) async {
        guard let groupID = Bundle.main.object(forInfoDictionaryKey: SharedIncoming.appGroupInfoKey) as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            state = .failed(String(localized: "Paper Trail's shared folder is not available. Reinstall Paper Trail and try again."))
            return
        }
        let folder = SharedIncoming.folder(in: container)
        var saved = 0
        var problems: [String] = []
        for provider in providers {
            guard let type = Self.supportedType(of: provider) else { continue }
            do {
                try await Self.copy(provider, type: type, into: folder)
                saved += 1
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if saved > 0 {
            state = .saved(saved)
        } else if let problem = problems.first {
            state = .failed(String(localized: "Could not save the document: \(problem) Try again, or save it to the Paper Trail Inbox folder in Files."))
        } else {
            state = .failed(String(localized: "Paper Trail can only save PDFs and images."))
        }
    }

    /// PDF first, then the most specific image type, so the file keeps a useful extension.
    static func supportedType(of provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) { return UTType.pdf.identifier }
        return provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    static func copy(_ provider: NSItemProvider, type: String, into folder: URL) async throws {
        let name = provider.suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // The temporary file is deleted when this handler returns, so copy it now.
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    _ = try SharedIncoming.save(url, preferredName: name, into: folder)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareView: View {
    let model: ShareModel
    var done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .saving:
                ProgressView("Saving to Paper Trail…")
            case .saved(let count):
                Label(count == 1 ? "Saved to Paper Trail." : "\(count) documents saved to Paper Trail.", systemImage: "checkmark.circle")
                    .font(.headline)
                Text("Open Paper Trail to file it. It will be waiting in Needs Review.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.center)
            }
            if model.state != .saving {
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
