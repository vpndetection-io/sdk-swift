import Foundation
import OpenAPIRuntime

/// The licensed dataset downloads. Access is granted by contract, not self-serve.
///
/// Reached as ``VPNDetectionClient/database``; there is no reason to build one
/// directly.
public struct DatabaseAPI: Sendable {
    private let api: Client
    private let retries: Int

    init(api: Client, retries: Int) {
        self.api = api
        self.retries = retries
    }

    /// The datasets your organization is licensed to download.
    public func list() async throws -> [LicensedDataset] {
        try await withRetry(retries) {
            let output = try await api.listDatabases()
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return try ok.body.json.datasets.map(LicensedDataset.init)
        }
    }

    /// What is inside one dataset: schema, sample rows, row count, sizes.
    public func metadata(id: String) async throws -> DatasetMetadata {
        try await withRetry(retries) {
            let output = try await api.databaseMetadata(query: .init(id: id))
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return DatasetMetadata(try ok.body.json)
        }
    }

    /// The digests for one dataset file.
    ///
    /// Returns the whole set rather than one algorithm: which digests a dataset
    /// publishes is the API's choice, not ours, and they arrive nested under
    /// `checksums` rather than at the top level.
    public func checksums(id: String, format: DatasetFormat) async throws -> DatasetChecksums {
        try await withRetry(retries) {
            let output = try await api.databaseChecksum(
                query: .init(id: id, format: .init(format)),
            )
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return DatasetChecksums(try ok.body.json.checksums)
        }
    }

    /// Your organization's recent download attempts, newest first.
    public func downloads(limit: Int? = nil) async throws -> [Download] {
        try await withRetry(retries) {
            let output = try await api.listDownloads(query: .init(limit: limit))
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return try ok.body.json.downloads.map(Download.init)
        }
    }

    /// The time-limited URL for one dataset file.
    ///
    /// The API answers `302` to object storage. The URL is returned rather than
    /// the bytes so you decide how to transfer a file that routinely runs to
    /// gigabytes; the link authorizes the START of a transfer, so one already
    /// running is not interrupted when it lapses.
    ///
    /// The default transport refuses redirects outright. If you supplied your
    /// own and it follows them, this throws rather than handing back a URL,
    /// because by then the transport is holding the dataset.
    public func downloadURL(id: String, format: DatasetFormat) async throws -> URL {
        try await withRetry(retries) {
            let output = try await api.downloadDatabase(
                query: .init(id: id, format: .init(format)),
            )
            guard case .found(let found) = output else {
                throw unexpected(output)
            }
            guard let location = found.headers.location, let url = URL(string: location) else {
                throw VPNDetectionError(
                    kind: .serverError,
                    message: "the download redirect carried no usable Location header",
                    status: 302,
                )
            }
            return url
        }
    }
}

/// The formats a dataset is published in.
///
/// Not every dataset is built in every format: the `_provider` catalogs are
/// keyed by provider id rather than by IP range, so no MMDB exists for them.
public enum DatasetFormat: String, Sendable, Hashable, CaseIterable {
    case csvgz
    case mmdb
}

/// One dataset your organization holds a license for.
public struct LicensedDataset: Sendable, Hashable {
    public let id: String
    public let name: String
    public let summary: String?
    /// Licensed but no longer published. Talk to us.
    public let retired: Bool?
    /// What your license permits you to do with the data.
    public let redistribution: Redistribution
    public let starts: Date?
    public let expires: Date?
    /// False when the license has lapsed; downloads are refused.
    public let inTerm: Bool
    public let formats: [DatasetFormatSize]

    public enum Redistribution: String, Sendable, Hashable, CaseIterable {
        case evaluation
        case `internal`
        case redistribute
    }
}

/// The published size of one dataset in one format.
public struct DatasetFormatSize: Sendable, Hashable {
    public let format: DatasetFormat
    /// Size of the published file, or `nil` when it has not been published yet.
    public let bytes: Int?
}

/// What is inside one dataset.
///
/// Poll this to decide whether today's build is worth fetching: it carries
/// `updated` and `entries` without downloading anything.
public struct DatasetMetadata: Sendable, Hashable {
    public let id: String
    /// How often a new build is published.
    public let updateFreq: String?
    /// The build date, as `YYYY-MM-DD`.
    public let updated: String
    /// Row count in the current build.
    public let entries: Int
    /// Columns, keyed by format.
    public let schema: [String: [DatasetColumn]]
    /// A few real rows, keyed by format.
    public let sample: [String: [[String: JSONValue]]]
    /// Bytes per format.
    public let size: [String: Int]
}

/// One column of a dataset, as published.
public struct DatasetColumn: Sendable, Hashable {
    public let name: String
    public let type: String
    public let description: String?
}

/// One download attempt by your organization.
public struct Download: Sendable, Hashable {
    public let datasetId: String
    public let format: String
    public let outcome: Outcome
    public let bytes: Int?
    public let created: Date

    public enum Outcome: String, Sendable, Hashable, CaseIterable {
        case ok
        case unauthorized
        case denied
        case expired
        case unknown
        case unavailable
    }
}

/// The digests published alongside one dataset file. Which ones are present
/// varies by dataset, so all four are optional.
public struct DatasetChecksums: Sendable, Hashable {
    public let md5: String?
    public let sha1: String?
    public let sha256: String?
    public let sha512: String?
}

private func unexpected(_ output: some Sendable) -> VPNDetectionError {
    VPNDetectionError(kind: .serverError, message: "unexpected response: \(output)")
}

// Exhaustive rather than a two-way test, so a format added to the spec is a
// compile error here instead of silently arriving as csvgz.
extension Operations.DownloadDatabase.Input.Query.FormatPayload {
    init(_ format: DatasetFormat) {
        switch format {
        case .csvgz: self = .csvgz
        case .mmdb: self = .mmdb
        }
    }
}

extension Operations.DatabaseChecksum.Input.Query.FormatPayload {
    init(_ format: DatasetFormat) {
        switch format {
        case .csvgz: self = .csvgz
        case .mmdb: self = .mmdb
        }
    }
}

extension LicensedDataset {
    init(_ wire: Components.Schemas.LicensedDataset) {
        self.id = wire.id
        self.name = wire.name
        self.summary = wire.summary
        self.retired = wire.retired
        self.redistribution = Redistribution(wire.redistribution)
        self.starts = wire.starts
        self.expires = wire.expires
        self.inTerm = wire.inTerm
        self.formats = wire.formats.map(DatasetFormatSize.init)
    }
}

extension LicensedDataset.Redistribution {
    init(_ wire: Components.Schemas.LicensedDataset.RedistributionPayload) {
        switch wire {
        case .evaluation: self = .evaluation
        case ._internal: self = .internal
        case .redistribute: self = .redistribute
        }
    }
}

extension DatasetFormatSize {
    init(_ wire: Components.Schemas.DatasetFormatSize) {
        self.format =
            switch wire.format {
            case .csvgz: .csvgz
            case .mmdb: .mmdb
            }
        self.bytes = wire.bytes
    }
}

extension DatasetMetadata {
    init(_ wire: Components.Schemas.DatasetMetadata) {
        self.id = wire.id
        self.updateFreq = wire.updateFreq
        self.updated = wire.updated
        self.entries = wire.entries
        self.schema = wire.schema.additionalProperties.mapValues { $0.map(DatasetColumn.init) }
        self.sample = (wire.sample?.additionalProperties ?? [:]).mapValues { rows in
            rows.map { $0.value.mapValues(JSONValue.init) }
        }
        self.size = wire.size?.additionalProperties ?? [:]
    }
}

extension DatasetColumn {
    init(_ wire: Components.Schemas.DatasetMetadataColumn) {
        self.name = wire.name
        self.type = wire._type
        self.description = wire.description
    }
}

extension Download {
    init(_ wire: Components.Schemas.Download) {
        self.datasetId = wire.datasetId
        self.format = wire.format
        self.outcome = Outcome(rawValue: wire.outcome.rawValue) ?? .unknown
        self.bytes = wire.bytes
        self.created = wire.created
    }
}

extension DatasetChecksums {
    init(_ wire: Operations.DatabaseChecksum.Output.Ok.Body.JsonPayload.ChecksumsPayload) {
        self.md5 = wire.md5
        self.sha1 = wire.sha1
        self.sha256 = wire.sha256
        self.sha512 = wire.sha512
    }
}
