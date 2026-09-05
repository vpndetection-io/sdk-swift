import Crypto
import Foundation
import Testing
import VPNDetection

/// The licensed-download half, which only the max key can reach: it is the tier
/// holding dataset licenses, and `db.download` is a scope the other three keys do
/// not carry.
///
/// The transfer is budgeted before it starts. `metadata` publishes a size per
/// format, and that size is checked against the ceiling below FIRST, so a
/// mistaken dataset id can never quietly pull one of the gigabyte datasets
/// through CI.
@Suite("Staging database downloads")
struct DatabaseTests {
    /// The max organization licenses `cdn_ip` for license_type, and at ~10 KB
    /// it is the only dataset small enough to move in CI.
    static let datasetId = "cdn_ip_v1"
    static let format = DatasetFormat.csvgz
    /// 8 MiB against a ~10 KB dataset. Three orders of magnitude of headroom, so
    /// tripping it means the suite is pointed somewhere unintended, which is
    /// exactly when a transfer must not go ahead.
    static let ceiling = 8 * 1024 * 1024
    /// A real catalogue id the max organization holds no license for.
    static let unlicensedId = "hosting_ip_v1"

    @Test("the licensed catalogue answers the family shape", Tier.max.needsKey)
    func catalogueAnswersTheFamilyShape() async throws {
        let client = clientFor(.max, transport: RecordingTransport(key: Tier.max.key))

        let datasets = try await client.database.list()

        #expect(datasets.isEmpty == false, "the max organization licenses nothing")
        for dataset in datasets {
            #expect(dataset.base.isEmpty == false)
            #expect(dataset.name.isEmpty == false)
            // The point of the family shape: a license covers the family, and
            // these are the ids the download and checksum methods take. Before
            // the spec was corrected this list did not exist, so `list` could
            // not tell a caller what to download.
            #expect(dataset.versions.isEmpty == false, "\(dataset.base) carries no versions")
            for version in dataset.versions {
                #expect(version.id.isEmpty == false, "\(dataset.base) has a version with no id")
                #expect(version.version > 0)
            }
        }
        let ids = datasets.flatMap { $0.versions.map(\.id) }
        print("licensed: \(ids.joined(separator: ", "))")
    }

    @Test("a dataset the organization does not license is refused cleanly", Tier.max.needsKey)
    func anUnlicensedDatasetIsRefused() async throws {
        let transport = RecordingTransport(key: Tier.max.key)
        let client = clientFor(.max, transport: transport)

        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.database.downloadURL(id: Self.unlicensedId, format: Self.format)
        }

        let error = try #require(
            failure,
            "\(Self.unlicensedId) is now licensed here, so point this at one that is not",
        )
        #expect(error.kind == .forbidden)
        #expect(error.status == 403)
        #expect(error.isRetryable == false, "a license refusal is not worth retrying")
        // The API says which refusal this is (`{"rc":"NOT_LICENSED"}`). Falling
        // back to the status means the client never read the envelope.
        #expect(
            error.message.hasPrefix("request failed with status") == false,
            "the message is the client fallback, so the response body went unread",
        )
        #expect(await transport.facts.count == 1, "a 4xx must not be retried")
    }

    @Test("download streams a real dataset to disk intact", Tier.max.needsKey)
    func downloadStreamsTheDatasetIntact() async throws {
        let transfer = try await Transfers.shared.transfer()

        #expect(transfer.written > 0, "nothing was transferred")
        let landed = try Data(contentsOf: transfer.file)
        #expect(landed.count == transfer.written, "the file is not the length the method reported")
        #expect(
            FileManager.default.fileExists(atPath: transfer.file.path + ".part") == false,
            "the .part file outlived a successful transfer",
        )
        #expect([UInt8](landed.prefix(2)) == [0x1f, 0x8b], "the payload is not gzip")

        let published = try #require(
            transfer.checksums.sha256, "checksums must unwrap past the envelope",
        )
        #expect(published.count == 64)
        #expect(sha256(landed) == published, "the bytes are not the published file")

        // The presigned URL authorizes itself, so the second request must carry
        // no credential.
        let toStorage = transfer.facts.filter { $0.origin != staging.absoluteString }
        #expect(toStorage.isEmpty == false, "object storage was never reached, so no 302 was followed")
        for fact in toStorage {
            #expect(fact.carriedKey == false, "the API key was sent to object storage")
        }
    }

    @Test("downloadBytes agrees with the streamed copy", Tier.max.needsKey)
    func downloadBytesAgreesWithTheFile() async throws {
        let transfer = try await Transfers.shared.transfer()

        let bytes = try await transfer.client.database.downloadBytes(
            Self.datasetId, format: Self.format,
        )

        #expect(bytes.count == transfer.written, "the in-memory copy is a different length")
        #expect(sha256(bytes) == transfer.checksums.sha256, "the in-memory copy is not the file")
    }
}

/// One transfer for the whole run, so the two tests share a download rather than
/// pulling the dataset twice each.
actor Transfers {
    static let shared = Transfers()

    private var pending: Task<Transfer, any Error>?

    func transfer() async throws -> Transfer {
        if let pending {
            return try await pending.value
        }
        let task = Task { try await downloadOnce() }
        pending = task
        return try await task.value
    }
}

struct Transfer: Sendable {
    let client: VPNDetectionClient
    let file: URL
    let written: Int
    let checksums: DatasetChecksums
    let facts: [RecordingTransport.Fact]
}

private func downloadOnce() async throws -> Transfer {
    let transport = RecordingTransport(key: Tier.max.key)
    let client = clientFor(.max, transport: transport)

    let metadata = try await client.database.metadata(id: DatabaseTests.datasetId)
    #expect(metadata.id == DatabaseTests.datasetId)
    let size = try #require(
        metadata.size[DatabaseTests.format.rawValue],
        "\(DatabaseTests.datasetId) publishes no \(DatabaseTests.format.rawValue) size to check",
    )
    try #require(
        size > 0 && size <= DatabaseTests.ceiling,
        "\(DatabaseTests.datasetId) is \(size) bytes, past the \(DatabaseTests.ceiling) ceiling",
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vpndetection-integration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(DatabaseTests.datasetId).csv.gz")

    let written = try await client.database.download(
        DatabaseTests.datasetId, format: DatabaseTests.format, to: file,
    )
    // Read after the transfer, so a rebuild between the two calls shows up as a
    // digest mismatch rather than passing against a digest of nothing.
    let checksums = try await client.database.checksums(
        id: DatabaseTests.datasetId, format: DatabaseTests.format,
    )
    print("\(DatabaseTests.datasetId): \(written) bytes, metadata says \(size)")

    return Transfer(
        client: client,
        file: file,
        written: written,
        checksums: checksums,
        facts: await transport.facts,
    )
}

private func sha256(_ bytes: some DataProtocol) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
