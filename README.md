# [<img src="https://s3.vpndetection.io/vpndetection-public/brand/mark.svg" alt="VPNDetection" width="24"/>](https://vpndetection.io/) VPNDetection Swift Client Library

[![Swift](https://img.shields.io/badge/swift-6.1%2B-F05138.svg)](https://swift.org)
[![license](https://img.shields.io/github/license/vpndetection-io/sdk-swift)](LICENSE)

The official Swift client library for the [VPNDetection](https://vpndetection.io) API.

The library helps you query VPNDetection's APIs for anonymity detection including VPNs, residential proxies, Tor nodes, hosting servers, CDNs, relays and more.

## Getting Started

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vpndetection-io/sdk-swift.git", from: "1.0.0"),
]
```

and the library to your target. The repository ends in `sdk-swift`, which is the package name SwiftPM derives, but the library it exposes is `VPNDetection`:

```swift
.target(
    name: "YourTarget",
    dependencies: [.product(name: "VPNDetection", package: "sdk-swift")],
)
```

Requires Swift 6.1 or newer, and macOS 13, iOS 16, tvOS 16, watchOS 9 or visionOS 1 on Apple platforms. Linux is supported on any distribution the Swift toolchain runs on.

## Usage

**No API key needed to start.** The free tier answers `ip` and `is_vpn`, and allows 1000 requests per day per source address.

```swift
import VPNDetection

let client = VPNDetectionClient()

let result = try await client.lookup("45.83.91.1")
print(result.isVpn)   // true
```

### With an API key

An API key raises your quota, and raises your features on a paid plan. Create one in the [console](https://app.vpndetection.io), then pass it in:

```swift
let client = VPNDetectionClient(apiKey: ProcessInfo.processInfo.environment["VPNDETECTION_API_KEY"]!)

let result = try await client.lookup("45.83.91.1")
print(result.isVpn)             // true
print(result.vpn?.provider)     // Optional("mullvad")
print(result.isHosting)         // Optional(true)
print(result.hosting?.provider)
```

Every setting has a default, and `VPNDetectionClient.Options` is where you change one:

```swift
let client = VPNDetectionClient(options: .init(apiKey: key, concurrency: 32, retries: 4))
```

### Absent is not false

Only `ip` and `isVpn` come back on every plan. Each remaining flag is an `Optional`, and `nil` means "not in your plan" rather than "checked, and no":

```swift
result.isHosting            // nil on the free tier, false or true on a plan that includes it
result.isHosting ?? false   // when you only care whether the address is flagged
result.isHosting == nil     // when you need to tell "not in your plan" from a real answer
```

A detail object that is present but empty means the flag above it is false; a populated one always carries every one of its keys.

### Batch lookup

You can do batch lookups with a list, which parallelizes requests for you efficiently:

```swift
let results = try await client.lookupBatch(["45.83.91.1", "8.8.8.8", "1.1.1.1"])

for (ip, outcome) in results {
    switch outcome {
    case .success(let result):
        print("\(ip): \(result.isVpn)")
    case .failure(let error):
        print("\(ip): \(error)")
    }
}
```

Results are keyed by address, so duplicates in your list collapse into a single request and one address failing never loses the rest. `results["8.8.8.8"]` gets one back on its own, and `results.keys` is the order you passed in.

Concurrency and other variables are configurable per-call:

```swift
let results = try await client.lookupBatch(manyIps, options: .init(concurrency: 32, retries: 4))
```

### Caching

Answers are cached by default, so repeat lookups of the same address are free:

```swift
let client = VPNDetectionClient()

let result = try await client.lookup("45.83.91.1")
print(result.isVpn)    // true, API request

let result2 = try await client.lookup("45.83.91.1")
print(result2.isVpn)   // true, no API request, result was cached
```

You can change the default cache variables (max size, TTL, etc) on initialization, or even disable it:

```swift
let client = VPNDetectionClient(options: .init(cache: .init(maxEntries: 50_000, ttl: .seconds(6 * 3600))))
let clientNoCache = VPNDetectionClient(options: .init(cache: nil))
```

### Private and reserved addresses

Private, loopback, link-local, documentation and multicast addresses (and their IPv6 equivalents, including the 6to4 and Teredo ranges) can never be VPN or proxy infrastructure. The library answers them locally, so they cost no request and no quota:

```swift
let result = try await client.lookup("192.168.1.1")
result.isBogon   // true, this answer was computed rather than served
result.isVpn     // false
```

The check is available on the client, which is handy when your inputs are addresses anyway:

```swift
client.isBogon("10.0.0.1")   // true
client.isBogon("8.8.8.8")    // false
```

It is also a free function, if you want it without a client:

```swift
import VPNDetection

isBogon("10.0.0.1")   // true
```

### Errors

Failures throw a `VPNDetectionError` carrying a `kind` and an `isRetryable` flag:

```swift
do {
    _ = try await client.lookup("1.1.1.1")
} catch let error as VPNDetectionError {
    print(error.kind, error.isRetryable)
}
```

`kind` is one of `badRequest`, `unauthorized`, `forbidden`, `rateLimited`, `quotaExceeded`, `serverError` or `network`.

Note that `rateLimited` and `quotaExceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is when the API faces extreme traffic bursts and so retrying later works; but a spent quota needs your allowance raised or the window to roll over. The library retries rate limits for you, but not if your quota is exceeded.

### Database downloads

If your key carries the `db.download` scope, the licensed datasets are available through `client.database`. `download` fetches one to a file, streaming it straight to disk so that nothing bigger than a chunk is ever held in memory:

```swift
let datasets = try await client.database.list()

let written = try await client.database.download(
    "vpn_ip_extended_v1", format: .mmdb,
    to: URL(fileURLWithPath: "vpn_ip_extended_v1.mmdb"),
)
print("\(written) bytes")
```

Or take the time-limited link and run the transfer yourself, or take a small dataset as bytes:

```swift
let url = try await client.database.downloadURL(id: "vpn_ip_extended_v1", format: .mmdb)
let bytes = try await client.database.downloadBytes("cdn_ip_v1", format: .csvgz)
```

`downloadBytes` holds the whole file in memory, and the catalog runs from `cdn_ip_v1` at 10 KB to `resproxy_ip_90d_v1` at 1.79 GB, so use `download` for anything you have not measured.

### Supplying your own transport

By default the library talks to the API over [AsyncHTTPClient](https://github.com/swift-server/async-http-client), configured to refuse redirects. Anything conforming to `ClientTransport` can take its place. To use `URLSession` on an Apple platform, add [swift-openapi-urlsession](https://github.com/apple/swift-openapi-urlsession) to your own package and hand its transport in:

```swift
import OpenAPIURLSession

let client = VPNDetectionClient(options: .init(transport: URLSessionTransport()))
```

One thing to know if you do: the download endpoint answers `302`, and the library follows that redirect itself as a second request rather than letting the transport do it, so a transport that follows redirects would read a whole dataset into memory before the library ever saw the link. Configure yours not to. The library refuses such a response rather than reading it, but the transfer has already started by then.

## Other Libraries

There are official VPNDetection client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/vpndetection-io for more.

## About VPNDetection

VPN Detection API: Accurate anonymity detection identifying VPNs, residential proxies, hosting servers, Tor nodes, CDNs, relays and more.

[<img src="https://s3.vpndetection.io/vpndetection-public/brand/mark.svg" alt="VPNDetection" width="96"/>](https://vpndetection.io/)

## License

This project is licensed under the [MIT License](LICENSE).
