import Foundation
import SwiftUI
import proto_garage_proto_swift

/// Represents a single search result item returned by the gRPC Search endpoint.
public struct SearchResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let rank: Int
    public let title: String
    public let uri: String
    public let corpusClass: String
    public let trustTier: String
    public let matchedBy: String
    public let score: Float
    public let headingPath: String
    public let authors: [String]
    public let text: String
    public let snippet: String

    public init(
        id: String? = nil,
        rank: Int,
        title: String,
        uri: String,
        corpusClass: String = "document",
        trustTier: String = "authored",
        matchedBy: String = "hybrid",
        score: Float = 0.0,
        headingPath: String = "",
        authors: [String] = [],
        text: String = "",
        snippet: String = ""
    ) {
        self.id = id ?? "\(rank)_\(uri)_\(score)"
        self.rank = rank
        self.title = title.isEmpty ? "(untitled)" : title
        self.uri = uri
        self.corpusClass = corpusClass
        self.trustTier = trustTier
        self.matchedBy = matchedBy
        self.score = score
        self.headingPath = headingPath
        self.authors = authors
        self.text = text
        self.snippet = snippet
    }

    public init(hit: Garage_SearchHit) {
        self.init(
            id: "\(hit.rank)_\(hit.uri)_\(hit.score)",
            rank: Int(hit.rank),
            title: hit.title,
            uri: hit.uri,
            corpusClass: hit.corpusClass,
            trustTier: hit.trustTier,
            matchedBy: hit.matchedBy,
            score: hit.score,
            headingPath: hit.headingPath,
            authors: hit.authors,
            text: hit.text,
            snippet: hit.snippet
        )
    }

    public var displayTitle: String {
        if !title.isEmpty && title != "(untitled)" {
            return title
        }
        if !headingPath.isEmpty {
            return headingPath
        }
        if !uri.isEmpty {
            return (uri as NSString).lastPathComponent
        }
        return "(untitled)"
    }

    public var authorsList: String {
        authors.isEmpty ? "" : authors.joined(separator: ", ")
    }
}
