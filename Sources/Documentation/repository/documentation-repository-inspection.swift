import Executable

@_spi(Testing) public struct DocumentationRepositoryInspection:
    Sendable
{
    @_spi(Testing) public let manifest: SwiftPackageManifest
    @_spi(Testing) public let symbolGraphs: SwiftSymbolGraphDump

    @_spi(Testing) public init(
        manifest: SwiftPackageManifest,
        symbolGraphs: SwiftSymbolGraphDump
    ) {
        self.manifest = manifest
        self.symbolGraphs = symbolGraphs
    }
}

@_spi(Testing) public enum DocumentationRepositoryInspector {
    @_spi(Testing) public static func inspect(
        _ materialization: DocumentationMaterialization,
        minimumAccessLevel: SwiftSymbolGraphAccessLevel = .public
    ) async throws -> DocumentationRepositoryInspection {
        let manifest = try await Package.manifest(
            at: materialization.checkoutRoot
        )

        let symbolGraphs = try await Package.symbolGraphs(
            at: materialization.checkoutRoot,
            minimumAccessLevel: minimumAccessLevel
        )

        return .init(
            manifest: manifest,
            symbolGraphs: symbolGraphs
        )
    }
}
