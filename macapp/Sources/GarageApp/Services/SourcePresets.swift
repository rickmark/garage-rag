import Foundation

/// One source registration: exactly what `garage add-source` takes.
struct SourceSpec: Hashable, Sendable {
    var slug: String
    var root: String
    var kind: String
    var corpusClass: String
    var trust: String
    var allowCloudEnrichment = false

    /// `garage add-source SLUG ROOT --kind ... --class ... --trust ...`.
    var addSourceArguments: [String] {
        var args = ["add-source", slug, root, "--kind", kind, "--class", corpusClass, "--trust", trust]
        if allowCloudEnrichment {
            args.append("--allow-cloud-enrichment")
        }
        return args
    }
}

/// The common local sources both the Status page's quick add and the Sources
/// page's preset menu offer, so the two cannot disagree on a slug or a title.
struct SourcePreset: Identifiable, Hashable, Sendable {
    let title: String
    let spec: SourceSpec

    var id: String { spec.slug }

    static let messages = SourcePreset(
        title: "Messages",
        spec: SourceSpec(slug: "apple-sms", root: "~/Library/Messages", kind: "sqlite", corpusClass: "communication", trust: "received")
    )
    static let mail = SourcePreset(
        title: "Apple Mail",
        spec: SourceSpec(slug: "apple-mail", root: "~/Library/Mail", kind: "maildir", corpusClass: "communication", trust: "received")
    )
    static let documents = SourcePreset(
        title: "Documents",
        spec: SourceSpec(slug: "documents", root: "~/Documents", kind: "filesystem", corpusClass: "document", trust: "authored")
    )
    static let downloads = SourcePreset(
        title: "Downloads",
        spec: SourceSpec(slug: "downloads", root: "~/Downloads", kind: "filesystem", corpusClass: "document", trust: "received")
    )
    static let desktop = SourcePreset(
        title: "Desktop",
        spec: SourceSpec(slug: "desktop", root: "~/Desktop", kind: "filesystem", corpusClass: "document", trust: "authored")
    )
    static let dropbox = SourcePreset(
        title: "Dropbox",
        spec: SourceSpec(slug: "dropbox", root: "~/Dropbox", kind: "filesystem", corpusClass: "document", trust: "authored")
    )

    /// Every preset, for the Sources page menu.
    static let all: [SourcePreset] = [messages, mail, documents, downloads, desktop, dropbox]

    /// The first-run quick-add set. Dropbox only when the folder exists; checked
    /// once per launch, not on every render of the Status page.
    static let quickAdd: [SourcePreset] = {
        var presets = [documents, messages]
        if FileManager.default.fileExists(atPath: (dropbox.spec.root as NSString).expandingTildeInPath) {
            presets.append(dropbox)
        }
        return presets
    }()
}

extension ModelPresetEntry {
    /// `garage register-model SLUG --provider ... [--dims N] [--model-ref REF]`.
    var registerModelArguments: [String] {
        var args = ["register-model", slug, "--provider", provider ?? "llama_xpc"]
        if effectiveDims > 0 {
            args += ["--dims", "\(effectiveDims)"]
        }
        if let ref = modelRef, !ref.isEmpty, ref != slug {
            args += ["--model-ref", ref]
        }
        return args
    }
}

extension AppState {
    @discardableResult
    func addSource(_ spec: SourceSpec) async -> Bool {
        await runGarage(spec.addSourceArguments)
    }

    @discardableResult
    func registerModel(preset: ModelPresetEntry) async -> Bool {
        await runGarage(preset.registerModelArguments)
    }
}
