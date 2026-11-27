import CryptoKit
import DSL
import Foundation

/// Encoding generation of the disposable Documentation snapshot cache.
///
/// This is intentionally distinct from DocumentationImporterVersion. The
/// importer version describes semantic normalization, while this value
/// describes only the persisted transport representation.
public struct DocumentationSnapshotStorageVersion:
    RawRepresentable,
    Sendable,
    Hashable
{
    public static let current = Self(
        rawValue: 3
    )

    public let rawValue: Int

    public init(
        rawValue: Int
    ) {
        self.rawValue = rawValue
    }
}

public enum DocumentationSnapshotStorageError:
    Error,
    Equatable
{
    case unsupportedStorageFormat(Int)
    case invalidRepositoryOrigin(String)
    case invalidRepositoryRevisionKind(String)
    case invalidStructuredContentKind(String)
    case invalidStructuredContentInlineKind(String)
    case invalidStructuredContentListStyle(String)
    case invalidStructuredContentShape(String)
    case invalidSymbolProvenance(String)
    case importerVersionMismatch(
        expected: Int,
        actual: Int
    )
    case snapshotIdentityMismatch
}

/// Explicit codec for the disposable Documentation snapshot cache.
///
/// Semantic model types deliberately remain independent of Codable. The codec
/// translates through Documentation-owned storage records so the cache format
/// can evolve or be discarded without making synthesized enum encoding part of
/// the public semantic contract.
public enum DocumentationSnapshotCodec {
    public static func encode(
        _ snapshot: DocumentationSnapshot
    ) throws -> Data {
        let envelope = DocumentationSnapshotEnvelope(
            snapshot
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
        ]

        return try encoder.encode(
            envelope
        )
    }

    public static func decode(
        _ data: Data
    ) throws -> DocumentationSnapshot {
        let decoder = JSONDecoder()

        let header = try decoder.decode(
            DocumentationSnapshotEnvelopeHeader.self,
            from: data
        )

        guard
            header.storageFormatVersion
                == DocumentationSnapshotStorageVersion.current.rawValue
        else {
            throw DocumentationSnapshotStorageError
                .unsupportedStorageFormat(
                    header.storageFormatVersion
                )
        }

        let envelope = try decoder.decode(
            DocumentationSnapshotEnvelope.self,
            from: data
        )

        guard
            envelope.importerVersion
                == envelope.snapshot.identity.importerVersion
        else {
            throw DocumentationSnapshotStorageError
                .importerVersionMismatch(
                    expected: envelope.snapshot.identity.importerVersion,
                    actual: envelope.importerVersion
                )
        }

        let snapshot = try envelope.snapshot.semantic()

        guard
            envelope.importerVersion
                == snapshot.identity.importerVersion.rawValue
        else {
            throw DocumentationSnapshotStorageError
                .importerVersionMismatch(
                    expected: snapshot.identity.importerVersion.rawValue,
                    actual: envelope.importerVersion
                )
        }

        return snapshot
    }
}

/// Filesystem-backed cache of immutable Documentation snapshots.
///
/// Storage paths are derived from a stable SHA-256 digest of semantic snapshot
/// identity. Repository origins are never used directly as filesystem path
/// components and Swift's process-randomized Hasher is deliberately avoided.
public struct DocumentationSnapshotStore:
    Sendable
{
    public let root: URL

    public init(
        root: URL
    ) {
        self.root = root
    }

    public func contains(
        _ identity: DocumentationSnapshotIdentity
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: fileURL(
                for: identity
            ).path
        )
    }

    public func load(
        _ identity: DocumentationSnapshotIdentity
    ) throws -> DocumentationSnapshot? {
        let url = fileURL(
            for: identity
        )

        guard
            FileManager.default.fileExists(
                atPath: url.path
            )
        else {
            return nil
        }

        let data = try Data(
            contentsOf: url
        )

        let snapshot = try DocumentationSnapshotCodec.decode(
            data
        )

        guard snapshot.identity == identity else {
            throw DocumentationSnapshotStorageError.snapshotIdentityMismatch
        }

        return snapshot
    }

    /// Loads every persisted immutable snapshot in deterministic file order.
    ///
    /// Corrupt or unsupported cache entries are surfaced to the caller rather
    /// than silently omitted. Repository refresh may still regenerate an
    /// individual disposable entry when that specific identity is requested.
    public func snapshots() throws -> [DocumentationSnapshot] {
        guard FileManager.default.fileExists(
            atPath: snapshotDirectory.path
        ) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: snapshotDirectory,
            includingPropertiesForKeys: nil,
            options: [
                .skipsHiddenFiles,
            ]
        )
            .filter {
                $0.pathExtension == "json"
            }
            .sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }

        return try urls.map { url in
            try DocumentationSnapshotCodec.decode(
                Data(
                    contentsOf: url
                )
            )
        }
    }

    public func catalog() throws -> DocumentationCatalog {
        .init(
            snapshots: try snapshots()
        )
    }

    public func save(
        _ snapshot: DocumentationSnapshot
    ) throws {
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )

        let data = try DocumentationSnapshotCodec.encode(
            snapshot
        )

        try data.write(
            to: fileURL(
                for: snapshot.identity
            ),
            options: .atomic
        )
    }

    @_spi(Testing) public func fileURL(
        for identity: DocumentationSnapshotIdentity
    ) -> URL {
        snapshotDirectory
            .appendingPathComponent(
                digest(
                    for: identity
                ) + ".json",
                isDirectory: false
            )
    }

    private var snapshotDirectory: URL {
        root.appendingPathComponent(
            "snapshots",
            isDirectory: true
        )
    }

    private func digest(
        for identity: DocumentationSnapshotIdentity
    ) -> String {
        let source = [
            identity.repositoryOrigin,
            identity.commit,
            identity.toolchain.rawValue,
            String(
                identity.importerVersion.rawValue
            ),
        ]
            .joined(
                separator: "\u{1F}"
            )

        return SHA256
            .hash(
                data: Data(
                    source.utf8
                )
            )
            .map {
                String(
                    format: "%02x",
                    $0
                )
            }
            .joined()
    }
}

private struct DocumentationSnapshotEnvelopeHeader:
    Codable
{
    let storageFormatVersion: Int
}

private struct DocumentationSnapshotEnvelope:
    Codable
{
    let storageFormatVersion: Int
    let importerVersion: Int
    let snapshot: DocumentationSnapshotRecord

    init(
        _ snapshot: DocumentationSnapshot
    ) {
        self.storageFormatVersion =
            DocumentationSnapshotStorageVersion.current.rawValue
        self.importerVersion = snapshot.identity.importerVersion.rawValue
        self.snapshot = .init(
            snapshot
        )
    }
}

private struct DocumentationSnapshotRecord:
    Codable
{
    let identity: DocumentationSnapshotIdentityRecord
    let repository: DocumentationRepositoryRecord
    let revision: DocumentationResolvedRevisionRecord
    let package: DocumentationPackageRecord
    let collection: DocumentationCollectionRecord

    init(
        _ snapshot: DocumentationSnapshot
    ) {
        self.identity = .init(
            snapshot.identity
        )
        self.repository = .init(
            snapshot.repository
        )
        self.revision = .init(
            snapshot.revision
        )
        self.package = .init(
            snapshot.package
        )
        self.collection = .init(
            snapshot.collection
        )
    }

    func semantic() throws -> DocumentationSnapshot {
        let identity = identity.semantic()
        let repository = try repository.semantic()
        let revision = try revision.semantic()

        guard
            identity.repositoryOrigin
                == repository.origin.absoluteString,
            identity.commit == revision.commit
        else {
            throw DocumentationSnapshotStorageError.snapshotIdentityMismatch
        }

        return .init(
            identity: identity,
            repository: repository,
            revision: revision,
            package: package.semantic(),
            collection: try collection.semantic()
        )
    }
}

private struct DocumentationSnapshotIdentityRecord:
    Codable
{
    let repositoryOrigin: String
    let commit: String
    let toolchain: String
    let importerVersion: Int

    init(
        _ identity: DocumentationSnapshotIdentity
    ) {
        self.repositoryOrigin = identity.repositoryOrigin
        self.commit = identity.commit
        self.toolchain = identity.toolchain.rawValue
        self.importerVersion = identity.importerVersion.rawValue
    }

    func semantic() -> DocumentationSnapshotIdentity {
        .init(
            repositoryOrigin: repositoryOrigin,
            commit: commit,
            toolchain: .init(
                rawValue: toolchain
            ),
            importerVersion: .init(
                rawValue: importerVersion
            )
        )
    }
}

private struct DocumentationRepositoryRecord:
    Codable
{
    let origin: String
    let revision: DocumentationRepositoryRevisionRecord

    init(
        _ repository: DocumentationRepository
    ) {
        self.origin = repository.origin.absoluteString
        self.revision = .init(
            repository.revision
        )
    }

    func semantic() throws -> DocumentationRepository {
        guard let origin = URL(
            string: origin
        ) else {
            throw DocumentationSnapshotStorageError
                .invalidRepositoryOrigin(
                    origin
                )
        }

        return .init(
            origin: origin,
            revision: try revision.semantic()
        )
    }
}

private struct DocumentationRepositoryRevisionRecord:
    Codable
{
    let kind: String
    let value: String

    init(
        _ revision: DocumentationRepositoryRevision
    ) {
        switch revision {
        case .branch(let value):
            self.kind = "branch"
            self.value = value

        case .tag(let value):
            self.kind = "tag"
            self.value = value

        case .commit(let value):
            self.kind = "commit"
            self.value = value

        case .reference(let value):
            self.kind = "reference"
            self.value = value
        }
    }

    func semantic() throws -> DocumentationRepositoryRevision {
        switch kind {
        case "branch":
            return .branch(
                value
            )

        case "tag":
            return .tag(
                value
            )

        case "commit":
            return .commit(
                value
            )

        case "reference":
            return .reference(
                value
            )

        default:
            throw DocumentationSnapshotStorageError
                .invalidRepositoryRevisionKind(
                    kind
                )
        }
    }
}

private struct DocumentationResolvedRevisionRecord:
    Codable
{
    let requested: DocumentationRepositoryRevisionRecord
    let commit: String

    init(
        _ revision: DocumentationResolvedRevision
    ) {
        self.requested = .init(
            revision.requested
        )
        self.commit = revision.commit
    }

    func semantic() throws -> DocumentationResolvedRevision {
        .init(
            requested: try requested.semantic(),
            commit: commit
        )
    }
}

private struct DocumentationPackageRecord:
    Codable
{
    let name: String
    let toolsVersion: String?
    let products: [DocumentationProductRecord]
    let targets: [DocumentationTargetRecord]
    let modules: [DocumentationModuleRecord]

    init(
        _ package: DocumentationPackage
    ) {
        self.name = package.name
        self.toolsVersion = package.toolsVersion
        self.products = package.products.map {
            .init(
                $0
            )
        }
        self.targets = package.targets.map {
            .init(
                $0
            )
        }
        self.modules = package.modules.map {
            .init(
                $0
            )
        }
    }

    func semantic() -> DocumentationPackage {
        .init(
            name: name,
            toolsVersion: toolsVersion,
            products: products.map {
                $0.semantic()
            },
            targets: targets.map {
                $0.semantic()
            },
            modules: modules.map {
                $0.semantic()
            }
        )
    }
}

private struct DocumentationProductRecord:
    Codable
{
    let name: String
    let kind: String
    let targets: [String]

    init(
        _ product: DocumentationProduct
    ) {
        self.name = product.name
        self.kind = product.kind.rawValue
        self.targets = product.targets.map(
            \.rawValue
        )
    }

    func semantic() -> DocumentationProduct {
        .init(
            name: name,
            kind: .init(
                rawValue: kind
            ),
            targets: targets.map {
                .init(
                    rawValue: $0
                )
            }
        )
    }
}

private struct DocumentationTargetRecord:
    Codable
{
    let identity: String
    let name: String
    let type: String
    let path: String?
    let module: String?

    init(
        _ target: DocumentationTarget
    ) {
        self.identity = target.identity.rawValue
        self.name = target.name
        self.type = target.type
        self.path = target.path
        self.module = target.module?.rawValue
    }

    func semantic() -> DocumentationTarget {
        .init(
            identity: .init(
                rawValue: identity
            ),
            name: name,
            type: type,
            path: path,
            module: module.map {
                .init(
                    rawValue: $0
                )
            }
        )
    }
}

private struct DocumentationModuleRecord:
    Codable
{
    let identity: String
    let name: String

    init(
        _ module: DocumentationModule
    ) {
        self.identity = module.identity.rawValue
        self.name = module.name
    }

    func semantic() -> DocumentationModule {
        .init(
            identity: .init(
                rawValue: identity
            ),
            name: name
        )
    }
}

private struct DocumentationCollectionRecord:
    Codable
{
    let identity: String
    let title: String
    let content: DocumentationContentRecord
    let symbols: [DocumentationSymbolRecord]
    let relationships: [DocumentationRelationshipRecord]

    init(
        _ collection: DocumentationCollection
    ) {
        self.identity = collection.identity.rawValue
        self.title = collection.title
        self.content = .init(
            collection.content
        )
        self.symbols = collection.symbols.map {
            .init(
                $0
            )
        }
        self.relationships = collection.relationships.map {
            .init(
                $0
            )
        }
    }

    func semantic() throws -> DocumentationCollection {
        .init(
            identity: .init(
                rawValue: identity
            ),
            title: title,
            content: try content.semantic(),
            symbols: try symbols.map {
                try $0.semantic()
            },
            relationships: try relationships.map {
                try $0.semantic()
            }
        )
    }
}

private struct DocumentationContentRecord:
    Codable
{
    let authoredMarkup: String?
    let structuredContent: DocumentationStructuredContentRecord

    init(
        _ content: DocumentationContent
    ) {
        self.authoredMarkup = content.authoredMarkup
        self.structuredContent = .init(
            content.structuredContent
        )
    }

    func semantic() throws -> DocumentationContent {
        .init(
            authoredMarkup: authoredMarkup,
            structuredContent: try structuredContent.semantic()
        )
    }
}

private struct DocumentationSymbolRecord:
    Codable
{
    let identity: String
    let name: String
    let path: [String]
    let kind: String
    let module: String?
    let declaration: DocumentationDeclarationRecord?
    let content: DocumentationContentRecord
    let source: DocumentationSourceReferenceRecord?
    let provenance: String

    init(
        _ symbol: DocumentationSymbol
    ) {
        self.identity = symbol.identity.rawValue
        self.name = symbol.name
        self.path = symbol.path
        self.kind = symbol.kind.rawValue
        self.module = symbol.module?.rawValue
        self.declaration = symbol.declaration.map {
            .init(
                $0
            )
        }
        self.content = .init(
            symbol.content
        )
        self.source = symbol.source.map {
            .init(
                $0
            )
        }
        self.provenance = symbol.provenance.rawValue
    }

    func semantic() throws -> DocumentationSymbol {
        guard let provenance = DocumentationSymbolProvenance(
            rawValue: provenance
        ) else {
            throw DocumentationSnapshotStorageError
                .invalidSymbolProvenance(
                    provenance
                )
        }

        return .init(
            identity: .init(
                rawValue: identity
            ),
            name: name,
            path: path,
            kind: .init(
                rawValue: kind
            ),
            module: module.map {
                .init(
                    rawValue: $0
                )
            },
            declaration: try declaration?.semantic(),
            content: try content.semantic(),
            source: source?.semantic(),
            provenance: provenance
        )
    }
}

private struct DocumentationDeclarationRecord:
    Codable
{
    let fragments: [DocumentationDeclarationFragmentRecord]

    init(
        _ declaration: DocumentationDeclaration
    ) {
        self.fragments = declaration.fragments.map {
            .init(
                $0
            )
        }
    }

    func semantic() throws -> DocumentationDeclaration {
        .init(
            fragments: try fragments.map {
                try $0.semantic()
            }
        )
    }
}

private struct DocumentationDeclarationFragmentRecord:
    Codable
{
    let kind: String
    let spelling: String
    let referencedSymbol: String?

    init(
        _ fragment: DocumentationDeclaration.Fragment
    ) {
        self.kind = fragment.kind.rawValue
        self.spelling = fragment.spelling
        self.referencedSymbol = fragment.referencedSymbol?.rawValue
    }

    func semantic() throws -> DocumentationDeclaration.Fragment {
        .init(
            kind: .init(
                rawValue: kind
            ),
            spelling: spelling,
            referencedSymbol: referencedSymbol.map {
                .init(
                    rawValue: $0
                )
            }
        )
    }
}

private struct DocumentationSourceReferenceRecord:
    Codable
{
    let uri: String
    let line: Int?
    let character: Int?

    init(
        _ source: DocumentationSourceReference
    ) {
        self.uri = source.uri
        self.line = source.line
        self.character = source.character
    }

    func semantic() -> DocumentationSourceReference {
        .init(
            uri: uri,
            line: line,
            character: character
        )
    }
}

private struct DocumentationRelationshipRecord:
    Codable
{
    struct SourceOrigin:
        Codable
    {
        let symbol: String
        let displayName: String

        init(
            _ origin: DocumentationRelationship.SourceOrigin
        ) {
            self.symbol = origin.symbol.rawValue
            self.displayName = origin.displayName
        }

        func semantic() -> DocumentationRelationship.SourceOrigin {
            .init(
                symbol: .init(
                    rawValue: symbol
                ),
                displayName: displayName
            )
        }
    }

    let source: String
    let target: String
    let kind: String
    let targetFallback: String?
    let sourceOrigin: SourceOrigin?

    init(
        _ relationship: DocumentationRelationship
    ) {
        self.source = relationship.source.rawValue
        self.target = relationship.target.rawValue
        self.kind = relationship.kind.rawValue
        self.targetFallback = relationship.targetFallback
        self.sourceOrigin = relationship.sourceOrigin.map {
            .init(
                $0
            )
        }
    }

    func semantic() throws -> DocumentationRelationship {
        .init(
            source: .init(
                rawValue: source
            ),
            target: .init(
                rawValue: target
            ),
            kind: .init(
                rawValue: kind
            ),
            targetFallback: targetFallback,
            sourceOrigin: sourceOrigin?.semantic()
        )
    }
}

private struct DocumentationStructuredContentRecord:
    Codable
{
    let kind: String
    let children: [DocumentationStructuredContentRecord]?
    let inline: [DocumentationStructuredContentInlineRecord]?
    let language: String?
    let source: String?
    let listStyle: String?
    let role: String?
    let title: [DocumentationStructuredContentInlineRecord]?
    let level: Int?
    let anchor: String?
    let asset: String?
    let alt: String?
    let listing: String?
    let target: String?
    let key: String?
    /// An image's external URL (an asset image stores `asset`).
    let url: String?
    /// A note's or note use's occurrence numbers.
    let pointers: [Int]?
    let locators: [ReferenceLocator]?

    init(
        kind: String,
        children: [DocumentationStructuredContentRecord]? = nil,
        inline: [DocumentationStructuredContentInlineRecord]? = nil,
        language: String? = nil,
        source: String? = nil,
        listStyle: String? = nil,
        role: String? = nil,
        title: [DocumentationStructuredContentInlineRecord]? = nil,
        level: Int? = nil,
        anchor: String? = nil,
        asset: String? = nil,
        alt: String? = nil,
        listing: String? = nil,
        target: String? = nil,
        key: String? = nil,
        url: String? = nil,
        pointers: [Int]? = nil,
        locators: [ReferenceLocator]? = nil
    ) {
        self.kind = kind
        self.children = children
        self.inline = inline
        self.language = language
        self.source = source
        self.listStyle = listStyle
        self.role = role
        self.title = title
        self.level = level
        self.anchor = anchor
        self.asset = asset
        self.alt = alt
        self.listing = listing
        self.target = target
        self.key = key
        self.url = url
        self.pointers = pointers
        self.locators = locators
    }

    init(
        _ content: StructuredContent
    ) {
        switch content {
        case .collection(let children):
            self.init(
                kind: "collection",
                children: children.map {
                    .init(
                        $0
                    )
                }
            )

        case .paragraph(let inline):
            self.init(
                kind: "paragraph",
                inline: inline.map {
                    .init(
                        $0
                    )
                }
            )

        case .code(let language, let source):
            self.init(
                kind: "code",
                language: language,
                source: source
            )

        case .quote(let content, let attribution):
            self.init(
                kind: "quote",
                children: [
                    .init(
                        content
                    ),
                ],
                title: attribution?.map {
                    .init(
                        $0
                    )
                }
            )

        case .list(let style, let items):
            let listStyle: String

            switch style {
            case .unordered:
                listStyle = "unordered"

            case .ordered:
                listStyle = "ordered"
            }

            self.init(
                kind: "list",
                children: items.map {
                    .init(
                        $0
                    )
                },
                listStyle: listStyle
            )

        case .group(let role, let title, let content):
            self.init(
                kind: "group",
                children: [
                    .init(
                        content
                    ),
                ],
                role: role?.rawValue,
                title: title?.map {
                    .init(
                        $0
                    )
                }
            )

        case .table(let header, let rows):
            // Header row first; each row is a collection of its cells.
            self.init(
                kind: "table",
                children: ([header] + rows).map {
                    .init(
                        .collection(
                            $0
                        )
                    )
                }
            )

        case .heading(let level, let anchor, let content):
            self.init(
                kind: "heading",
                inline: content.map {
                    .init(
                        $0
                    )
                },
                level: level,
                anchor: anchor?.rawValue
            )

        case .image(let source, let alt):
            switch source {
            case .asset(let asset):
                self.init(
                    kind: "image",
                    asset: asset.rawValue,
                    alt: alt
                )

            case .external(let url):
                self.init(
                    kind: "image",
                    alt: alt,
                    url: url
                )
            }

        case .figure(let anchor, let content, let caption):
            self.init(
                kind: "figure",
                children: [
                    .init(
                        content
                    ),
                ],
                title: caption?.map {
                    .init(
                        $0
                    )
                },
                anchor: anchor?.rawValue
            )

        case .verse(let lines):
            self.init(
                kind: "verse",
                children: lines.map { line in
                    .init(
                        kind: "line",
                        inline: line.map {
                            .init(
                                $0
                            )
                        }
                    )
                }
            )

        case .rule:
            self.init(
                kind: "rule"
            )

        case .definitions(let definitions):
            self.init(
                kind: "definitions",
                children: definitions.map {
                    .init(
                        kind: "definition",
                        children: [
                            .init(
                                $0.description
                            ),
                        ],
                        title: $0.term.map {
                            .init(
                                $0
                            )
                        }
                    )
                }
            )

        case .listing(let listing):
            let name: String

            switch listing {
            case .bibliography:
                name = "bibliography"

            case .footnotes:
                name = "footnotes"

            case .contents:
                name = "contents"
            }

            self.init(
                kind: "listing",
                listing: name
            )

        case .notes(let notes):
            self.init(
                kind: "notes",
                children: notes.map { note in
                    .init(
                        kind: "note",
                        children: [.init(note.content)] + note.uses.map {
                            .init(
                                kind: "use",
                                pointers: $0.pointers,
                                locators: $0.locators
                            )
                        },
                        anchor: note.anchor.rawValue,
                        pointers: note.pointers
                    )
                }
            )

        case .native(let target, let key, let fallback):
            self.init(
                kind: "native",
                children: [
                    .init(
                        fallback
                    ),
                ],
                target: target.rawValue,
                key: key.rawValue
            )
        }
    }

    func semantic() throws -> StructuredContent {
        switch kind {
        case "collection":
            return .collection(
                try (children ?? []).map {
                    try $0.semantic()
                }
            )

        case "paragraph":
            return .paragraph(
                try (inline ?? []).map {
                    try $0.semantic()
                }
            )

        case "code":
            guard let source else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "code requires source"
                    )
            }

            return .code(
                language: language,
                source: source
            )

        case "quote":
            guard
                let children,
                children.count == 1,
                let content = children.first
            else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "quote requires exactly one child"
                    )
            }

            return .quote(
                try content.semantic(),
                attribution: try title?.map {
                    try $0.semantic()
                }
            )

        case "list":
            guard let listStyle else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "list requires style"
                    )
            }

            let style: StructuredContent.ListStyle

            switch listStyle {
            case "unordered":
                style = .unordered

            case "ordered":
                style = .ordered

            default:
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentListStyle(
                        listStyle
                    )
            }

            return .list(
                style: style,
                items: try (children ?? []).map {
                    try $0.semantic()
                }
            )

        case "group":
            guard
                let children,
                children.count == 1,
                let content = children.first
            else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "group requires exactly one child"
                    )
            }

            return .group(
                role: role.map {
                    StructuredContent.Role(
                        rawValue: $0
                    )
                },
                title: try title?.map {
                    try $0.semantic()
                },
                content: try content.semantic()
            )

        case "table":
            let rows = try (children ?? []).map { row -> [StructuredContent] in
                guard case .collection(let cells) = try row.semantic() else {
                    throw DocumentationSnapshotStorageError
                        .invalidStructuredContentShape(
                            "table rows must be collections"
                        )
                }

                return cells
            }

            guard let header = rows.first else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "table requires a header row"
                    )
            }

            return .table(
                header: header,
                rows: Array(
                    rows.dropFirst()
                )
            )

        case "heading":
            guard let level else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "heading requires level"
                    )
            }

            return .heading(
                level: level,
                anchor: anchor.map {
                    StructuredContent.AnchorKey(
                        rawValue: $0
                    )
                },
                content: try (inline ?? []).map {
                    try $0.semantic()
                }
            )

        case "image":
            guard let alt else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "image requires alt"
                    )
            }

            switch (asset, url) {
            case (let asset?, nil):
                return .image(
                    source: .asset(
                        StructuredContent.AssetKey(
                            rawValue: asset
                        )
                    ),
                    alt: alt
                )

            case (nil, let url?):
                return .image(
                    source: .external(
                        url
                    ),
                    alt: alt
                )

            default:
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "image requires either asset or url"
                    )
            }

        case "figure":
            guard
                let children,
                children.count == 1,
                let content = children.first
            else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "figure requires exactly one child"
                    )
            }

            return .figure(
                anchor: anchor.map {
                    StructuredContent.AnchorKey(
                        rawValue: $0
                    )
                },
                content: try content.semantic(),
                caption: try title?.map {
                    try $0.semantic()
                }
            )

        case "verse":
            return .verse(
                try (children ?? []).map { line in
                    guard line.kind == "line" else {
                        throw DocumentationSnapshotStorageError
                            .invalidStructuredContentShape(
                                "verse children must be lines"
                            )
                    }

                    return try (line.inline ?? []).map {
                        try $0.semantic()
                    }
                }
            )

        case "rule":
            return .rule

        case "definitions":
            return .definitions(
                try (children ?? []).map { definition in
                    guard
                        definition.kind == "definition",
                        let description = definition.children?.first,
                        definition.children?.count == 1
                    else {
                        throw DocumentationSnapshotStorageError
                            .invalidStructuredContentShape(
                                "definition requires exactly one description"
                            )
                    }

                    return StructuredContent.Definition(
                        term: try (definition.title ?? []).map {
                            try $0.semantic()
                        },
                        description: try description.semantic()
                    )
                }
            )

        case "listing":
            switch listing {
            case "bibliography":
                return .listing(
                    .bibliography
                )

            case "footnotes":
                return .listing(
                    .footnotes
                )

            case "contents":
                return .listing(
                    .contents
                )

            default:
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "listing requires bibliography, footnotes or contents"
                    )
            }

        case "notes":
            return .notes(
                try (children ?? []).map { note in
                    guard
                        note.kind == "note",
                        let anchor = note.anchor,
                        let pointers = note.pointers,
                        let content = note.children?.first
                    else {
                        throw DocumentationSnapshotStorageError
                            .invalidStructuredContentShape(
                                "note requires anchor, pointers and content"
                            )
                    }

                    return StructuredContent.Note(
                        anchor: .init(rawValue: anchor),
                        pointers: pointers,
                        content: try content.semantic(),
                        uses: try (note.children ?? []).dropFirst().map { use in
                            guard
                                use.kind == "use",
                                let pointers = use.pointers,
                                let locators = use.locators
                            else {
                                throw DocumentationSnapshotStorageError
                                    .invalidStructuredContentShape(
                                        "note use requires pointers and locators"
                                    )
                            }

                            return .init(pointers: pointers, locators: locators)
                        }
                    )
                }
            )

        case "native":
            guard
                let target,
                let key,
                let children,
                children.count == 1,
                let fallback = children.first
            else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "native requires target, key and exactly one fallback"
                    )
            }

            return .native(
                target: StructuredContent.NativeTarget(
                    rawValue: target
                ),
                key: StructuredContent.NativeKey(
                    rawValue: key
                ),
                fallback: try fallback.semantic()
            )

        default:
            throw DocumentationSnapshotStorageError
                .invalidStructuredContentKind(
                    kind
                )
        }
    }
}

private struct DocumentationStructuredContentInlineRecord:
    Codable
{
    let kind: String
    let text: String?
    let children: [DocumentationStructuredContentInlineRecord]?
    let target: String?
    let anchor: String?
    let key: String?
    let locators: [ReferenceLocator]?
    let blocks: [DocumentationStructuredContentRecord]?
    let number: Int?

    init(
        kind: String,
        text: String? = nil,
        children: [DocumentationStructuredContentInlineRecord]? = nil,
        target: String? = nil,
        anchor: String? = nil,
        key: String? = nil,
        locators: [ReferenceLocator]? = nil,
        blocks: [DocumentationStructuredContentRecord]? = nil,
        number: Int? = nil
    ) {
        self.kind = kind
        self.text = text
        self.children = children
        self.target = target
        self.anchor = anchor
        self.key = key
        self.locators = locators
        self.blocks = blocks
        self.number = number
    }

    init(
        _ inline: StructuredContent.Inline
    ) {
        switch inline {
        case .text(let text):
            self.init(
                kind: "text",
                text: text
            )

        case .code(let text):
            self.init(
                kind: "code",
                text: text
            )

        case .emphasis(let children):
            self.init(
                kind: "emphasis",
                children: children.map {
                    .init(
                        $0
                    )
                }
            )

        case .strong(let children):
            self.init(
                kind: "strong",
                children: children.map {
                    .init(
                        $0
                    )
                }
            )

        case .link(let target, let children):
            let content = children.map {
                DocumentationStructuredContentInlineRecord(
                    $0
                )
            }

            switch target {
            case .page(let page, let anchor):
                self.init(
                    kind: "link",
                    text: page.rawValue,
                    children: content,
                    target: "page",
                    anchor: anchor?.rawValue
                )

            case .anchor(let anchor):
                self.init(
                    kind: "link",
                    children: content,
                    target: "anchor",
                    anchor: anchor.rawValue
                )

            case .asset(let asset):
                self.init(
                    kind: "link",
                    text: asset.rawValue,
                    children: content,
                    target: "asset"
                )

            case .external(let url):
                self.init(
                    kind: "link",
                    text: url,
                    children: content,
                    target: "external"
                )
            }

        case .citation(let key, let locators):
            self.init(
                kind: "citation",
                key: key.rawValue,
                locators: locators
            )

        case .footnote(let content):
            self.init(
                kind: "footnote",
                blocks: [
                    .init(
                        content
                    ),
                ]
            )

        case .noteReference(let number, let anchor):
            self.init(
                kind: "noteReference",
                anchor: anchor.rawValue,
                number: number
            )
        }
    }

    func semantic() throws -> StructuredContent.Inline {
        switch kind {
        case "text":
            guard let text else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "text inline requires text"
                    )
            }

            return .text(
                text
            )

        case "code":
            guard let text else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "code inline requires text"
                    )
            }

            return .code(
                text
            )

        case "emphasis":
            return .emphasis(
                try (children ?? []).map {
                    try $0.semantic()
                }
            )

        case "strong":
            return .strong(
                try (children ?? []).map {
                    try $0.semantic()
                }
            )

        case "link":
            let content = try (children ?? []).map {
                try $0.semantic()
            }

            return .link(
                target: try linkTarget(),
                content: content
            )

        case "citation":
            guard let key else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "citation requires key"
                    )
            }

            return .citation(
                key: StructuredContent.CitationKey(
                    rawValue: key
                ),
                locators: locators ?? []
            )

        case "footnote":
            guard
                let blocks,
                blocks.count == 1,
                let content = blocks.first
            else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "footnote requires exactly one block"
                    )
            }

            return .footnote(
                try content.semantic()
            )

        case "noteReference":
            guard let number, let anchor else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "note reference requires number and anchor"
                    )
            }

            return .noteReference(
                number: number,
                anchor: .init(rawValue: anchor)
            )

        default:
            throw DocumentationSnapshotStorageError
                .invalidStructuredContentInlineKind(
                    kind
                )
        }
    }

    private func linkTarget() throws -> StructuredContent.LinkTarget {
        switch target {
        case "page":
            guard let text else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "page link requires a page"
                    )
            }

            return .page(
                StructuredContent.PageKey(
                    rawValue: text
                ),
                anchor: anchor.map {
                    StructuredContent.AnchorKey(
                        rawValue: $0
                    )
                }
            )

        case "anchor":
            guard let anchor else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "anchor link requires an anchor"
                    )
            }

            return .anchor(
                StructuredContent.AnchorKey(
                    rawValue: anchor
                )
            )

        case "asset":
            guard let text else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "asset link requires an asset"
                    )
            }

            return .asset(
                StructuredContent.AssetKey(
                    rawValue: text
                )
            )

        case "external":
            guard let text else {
                throw DocumentationSnapshotStorageError
                    .invalidStructuredContentShape(
                        "external link requires a URL"
                    )
            }

            return .external(
                text
            )

        default:
            throw DocumentationSnapshotStorageError
                .invalidStructuredContentShape(
                    "link requires page, anchor, asset or external target"
                )
        }
    }
}
