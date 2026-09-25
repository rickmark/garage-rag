import Foundation

extension AppState {
    /// Lists facts via the gRPC server, optionally searched and filtered.
    func listFacts(
        query: String? = nil,
        source: String? = nil,
        factClass: String? = nil,
        corpusClass: String? = nil,
        documentID: Int64? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> FactListPage {
        let response = try await grpc.listFacts(
            query: query,
            source: source,
            factClass: factClass,
            corpusClass: corpusClass,
            documentID: documentID,
            limit: limit,
            offset: offset
        )
        return FactListPage(response: response)
    }
}
