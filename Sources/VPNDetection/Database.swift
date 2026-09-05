import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Where a streaming ``DatabaseAPI/download(_:format:to:)`` puts each chunk as
/// it arrives.
public typealias DownloadSink = (ArraySlice<UInt8>) async throws -> Void

/// The licensed dataset downloads. Access is granted by contract, not self-serve.
///
/// Reached as ``VPNDetectionClient/database``; there is no reason to build one
/// directly.
public struct DatabaseAPI: Sendable {
    private let api: Client
    private let transport: any ClientTransport
    private let retries: Int

    init(api: Client, transport: any ClientTransport, retries: Int) {
        self.api = api
        self.transport = transport
        self.retries = retries
    }

    /// The dataset families your organization is licensed to download.
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

    /// Download one dataset file, streaming it to `fileURL`. Returns the number
    /// of bytes written.
    ///
    /// The bytes go to a neighboring `.part` file that is renamed on completion,
    /// so a transfer that dies half way leaves nothing that reads as a whole
    /// dataset. Nothing is held in memory beyond a single chunk, whatever the
    /// dataset weighs.
    ///
    /// A failure DURING the transfer surfaces as the underlying error rather
    /// than a ``VPNDetectionError``: a reset socket and a full disk are
    /// different problems, and flattening both into one kind hides the one you
    /// can do something about.
    @discardableResult
    public func download(_ id: String, format: DatasetFormat, to fileURL: URL) async throws -> Int64 {
        let manager = FileManager.default
        let partial = fileURL.appendingPathExtension("part")
        guard manager.createFile(atPath: partial.path, contents: nil) else {
            throw VPNDetectionError(
                kind: .network, message: "could not create \(partial.path) to download into",
            )
        }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            let written = try await download(id, format: format) { chunk in
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            if manager.fileExists(atPath: fileURL.path) {
                try manager.removeItem(at: fileURL)
            }
            try manager.moveItem(at: partial, to: fileURL)
            return written
        } catch {
            try? handle.close()
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    /// Download one dataset file, handing each chunk to `sink` as it arrives.
    /// Returns the number of bytes handed over.
    ///
    /// The counterpart to the file overload when the bytes are going somewhere
    /// else: a parser, an archive, another socket. The sink is awaited, so
    /// back pressure is real and a slow sink slows the transfer rather than
    /// queueing behind it.
    @discardableResult
    public func download(
        _ id: String, format: DatasetFormat, to sink: DownloadSink,
    ) async throws -> Int64 {
        let body = try await datasetFile(id, format)
        var written: Int64 = 0
        for try await chunk in body {
            try await sink(chunk)
            written += Int64(chunk.count)
        }
        return written
    }

    /// Download one dataset file and hand back its bytes.
    ///
    /// **This holds the entire file in memory**, and the catalog spans five
    /// orders of magnitude: `cdn_ip_v1` is 10 KB while `resproxy_ip_90d_v1` is
    /// 1.79 GB of csv.gz, which will cost you that much resident memory and can
    /// fail outright. Reach for this at the small end, where the bytes are going
    /// straight into a parser; use ``download(_:format:to:)`` for anything you
    /// have not measured.
    public func downloadBytes(_ id: String, format: DatasetFormat) async throws -> Data {
        var data = Data()
        _ = try await download(id, format: format) { chunk in
            data.append(contentsOf: chunk)
        }
        return data
    }

    // Follows the 302 as a SECOND request straight to the transport, bypassing
    // the middleware chain that presents the API key: the presigned URL
    // authorizes itself, so forwarding the credential would hand it to a host
    // that has no business holding it.
    //
    // The body is returned unread. AsyncHTTPClient's deadline covers only the
    // time to the response head, so a multi-gigabyte transfer is not racing the
    // transport's request timeout.
    private func datasetFile(_ id: String, _ format: DatasetFormat) async throws -> HTTPBody {
        let url = try await downloadURL(id: id, format: format)
        let (origin, path) = try split(url)
        return try await withRetry(retries) {
            let (response, body) = try await transport.send(
                HTTPRequest(method: .get, scheme: nil, authority: nil, path: path),
                body: nil,
                baseURL: origin,
                operationID: "downloadDatasetFile",
            )
            let status = Int(response.status.code)
            guard (200..<300).contains(status) else {
                // Left unread: the status is what separates a lapsed link from a
                // refused one, and nothing bounds the size of an error body.
                throw VPNDetectionError.from(
                    status: status,
                    headers: response.headerFields,
                    body: [],
                    fallback: "object storage refused the download link with status \(status)",
                )
            }
            guard let body else {
                throw VPNDetectionError(
                    kind: .serverError, message: "object storage answered with no body",
                    status: status,
                )
            }
            return body
        }
    }
}

// A transport is handed a base URL and a path, so the presigned URL has to come
// apart into the two. The query carries the signature and cannot be dropped.
private func split(_ url: URL) throws -> (origin: URL, path: String) {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw VPNDetectionError(kind: .serverError, message: "unreadable download URL")
    }
    let path = components.percentEncodedPath
    let query = components.percentEncodedQuery
    components.percentEncodedPath = ""
    components.percentEncodedQuery = nil
    components.fragment = nil
    guard let origin = components.url else {
        throw VPNDetectionError(kind: .serverError, message: "unreadable download URL")
    }
    return (origin, query.map { "\(path)?\($0)" } ?? path)
}

/// The formats a dataset is published in.
///
/// Not every dataset is built in every format: the `_provider` catalogs are
/// keyed by provider id rather than by IP range, so no MMDB exists for them.
public enum DatasetFormat: String, Sendable, Hashable, CaseIterable {
    case csvgz
    case mmdb
}

/// One dataset FAMILY your organization holds a license for.
///
/// A license is held against the family, while a download names a version, so
/// the ids the download and checksum methods take come from ``versions`` rather
/// than from this type.
public struct LicensedDataset: Sendable, Hashable {
    /// The dataset family, e.g. `vpn_ip`. What the license is held against.
    public let base: String
    public let name: String
    public let summary: String?
    /// What your license permits you to do with the data.
    public let license_type: LicenseType
    public let starts: Date?
    /// `nil` when the license does not expire.
    public let expires: Date?
    /// False when the license has lapsed; downloads are refused.
    public let inTerm: Bool
    public let standing: Standing
    /// Every published version of this family.
    public let versions: [LicensedVersion]

    public enum LicenseType: String, Sendable, Hashable, CaseIterable {
        case evaluation
        case standard
        case redistribute
    }

    /// Where the organization stands on this family.
    public enum Standing: String, Sendable, Hashable, CaseIterable {
        /// A term that has ended.
        case expired
        /// A live grant.
        case licensed
        /// Published, but never bought.
        case unlicensed
    }
}

/// One published version of a licensed family.
public struct LicensedVersion: Sendable, Hashable {
    /// The versioned dataset id, e.g. `vpn_ip_v1`. This is what a download takes.
    public let id: String
    public let version: Int
    public let summary: String?
    public let formats: [DatasetFormatSize]
    /// The formats an evaluation sample is published in, if any.
    public let sampleFormats: [DatasetFormat]
}

/// The published size of one dataset in one format.
public struct DatasetFormatSize: Sendable, Hashable {
    public let format: DatasetFormat
    /// Size of the published file, or `nil` when it has not been published yet.
    public let bytes: Int64?
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
    public let entries: Int64
    /// Columns, keyed by format.
    public let schema: [String: [DatasetColumn]]
    /// A few real rows, keyed by format.
    public let sample: [String: [[String: JSONValue]]]
    /// Bytes per format.
    public let size: [String: Int64]
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
    public let bytes: Int64?
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
        self.base = wire.base
        self.name = wire.name
        self.summary = wire.summary
        self.license_type = LicenseType(wire.license_type)
        self.starts = wire.starts
        self.expires = wire.expires
        self.inTerm = wire.inTerm
        self.standing = Standing(wire.standing)
        self.versions = wire.versions.map(LicensedVersion.init)
    }
}

extension LicensedDataset.Standing {
    init(_ wire: Components.Schemas.LicensedDataset.StandingPayload) {
        switch wire {
        case .expired: self = .expired
        case .licensed: self = .licensed
        case .unlicensed: self = .unlicensed
        }
    }
}

extension LicensedVersion {
    init(_ wire: Components.Schemas.LicensedVersion) {
        self.id = wire.id
        self.version = wire.version
        self.summary = wire.summary
        self.formats = wire.formats.map(DatasetFormatSize.init)
        self.sampleFormats = (wire.sampleFormats ?? []).map(DatasetFormat.init)
    }
}

extension DatasetFormat {
    init(_ wire: Components.Schemas.LicensedVersion.SampleFormatsPayloadPayload) {
        switch wire {
        case .csvgz: self = .csvgz
        case .mmdb: self = .mmdb
        }
    }
}

extension LicensedDataset.LicenseType {
    init(_ wire: Components.Schemas.LicensedDataset.LicenseTypePayload) {
        switch wire {
        case .evaluation: self = .evaluation
        case .standard: self = .standard
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
        self.bytes = wire.bytes.map(Int64.init)
    }
}

extension DatasetMetadata {
    init(_ wire: Components.Schemas.DatasetMetadata) {
        self.id = wire.id
        self.updateFreq = wire.updateFreq
        self.updated = wire.updated
        self.entries = Int64(wire.entries)
        self.schema = wire.schema.additionalProperties.mapValues { $0.map(DatasetColumn.init) }
        self.sample = (wire.sample?.additionalProperties ?? [:]).mapValues { rows in
            rows.map { $0.value.mapValues(JSONValue.init) }
        }
        self.size = (wire.size?.additionalProperties ?? [:]).mapValues(Int64.init)
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
        self.bytes = wire.bytes.map(Int64.init)
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
