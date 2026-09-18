# [<img src="https://s3.vpndetection.io/vpndetection-public/brand/mark.svg" alt="VPNDetection" width="24"/>](https://vpndetection.io/) VPNDetection Swift Client Library

[![Swift](https://img.shields.io/badge/swift-6.1%2B-F05138.svg)](https://swift.org)
[![license](https://img.shields.io/github/license/vpndetection-io/sdk-swift)](LICENSE)

The official Swift client library for the [VPNDetection](https://vpndetection.io) API.

The library helps you query VPNDetection's APIs for anonymity detection including VPNs, residential proxies, Tor nodes, hosting servers, CDNs, relays and more.

## Getting Started

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vpndetection-io/sdk-swift.git", from: "4.3.0"),
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

### Your own address

```swift
let result = try await client.myIP()
print(result.ip)   // the address we saw this call come from
```

Same answer `lookup` would give for that address, and the same cost against your allowance. It is deliberately not cached: which address you are is the whole question, and a machine that moves between networks would otherwise be told where it used to be.

### Your plan and usage

```swift
let acct = try await client.myEntitlement()
print(acct.plan.key)          // max
print(acct.usage.requests)    // 580
print(acct.usage.windowEnd)   // when the allowance resets
```

Usage counts against the anniversary of your subscription, not the calendar month and not the billing period, and it is the same number a lookup is gated on. `hardLimit` is `nil` on an uncapped plan, which is not the same as zero.

### Batch lookup

Look up many addresses at once. Bogons and cached answers are handled locally, and everything else goes to the batch endpoint in chunks of up to 1000 addresses, in parallel:

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

Results are keyed by address, in the order you first listed each one, so duplicates in your list collapse into a single entry and one address failing never loses the rest: it carries its error as its value, with the status the API would have given that address on its own. `results["8.8.8.8"]` gets one back on its own, and `results.keys` is the order you passed in.

How many chunks are in flight at once, how many times a failed chunk is retried, and how long each attempt at a chunk may take, are configurable per call:

```swift
let results = try await client.lookupBatch(manyIps, options: .init(concurrency: 4, retries: 4, timeout: .seconds(10)))
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

Each attempt is abandoned after 30 seconds by default (`timeout` on the options), which fails as a retryable `network` error. One call can set its own, longer or shorter - `lookup`, `myIP`, `myEntitlement`, a batch, every `oauth` method, and from 4.3.0 every `client.database` call but the transfers:

```swift
let result = try await client.lookup("45.83.91.1", timeout: .seconds(5))
let databases = try await client.database.list(timeout: .seconds(5))
```

### Database downloads

If your key carries the `db.download` scope, the licensed databases are available through `client.database`. `download` fetches one to a file, streaming it straight to disk so that nothing bigger than a chunk is ever held in memory:

```swift
let databases = try await client.database.list()

let written = try await client.database.download(
    "vpn_ip_extended_v1", format: .mmdb,
    to: URL(fileURLWithPath: "vpn_ip_extended_v1.mmdb"),
)
print("\(written) bytes")
```

Or take the time-limited link and run the transfer yourself, or take a small database as bytes:

```swift
let url = try await client.database.downloadURL(id: "vpn_ip_extended_v1", format: .mmdb)
let bytes = try await client.database.downloadBytes("cdn_ip_v1", format: .csvgz)
```

`downloadBytes` holds the whole file in memory, and the catalog runs from `cdn_ip_v1` at 10 KB to `resproxy_ip_90d_v1` at 1.79 GB, so use `download` for anything you have not measured.

From 4.3.0, `list`, `metadata`, `checksums`, `downloads` and `downloadURL` each take a `timeout` bounding each attempt at that one call in place of the client's:

```swift
let checksums = try await client.database.checksums(id: "vpn_ip_extended_v1", format: .mmdb, timeout: .seconds(5))
```

The transfers deliberately take none, so there is nothing to pass and a call that tries does not compile rather than accepting the option and quietly doing nothing with it: a dataset runs to gigabytes and minutes, so any bound that suits a JSON call would abandon a healthy download. `downloadURL` does take one, because minting the link is an ordinary API request - it bounds that request, not whatever you do with the link afterwards.

### Sign in with OAuth (device flow)

A program running on the person's own machine can let them sign in with a browser and pick one of their API keys, instead of asking them to paste it:

```swift
let client = VPNDetectionClient()

let device = try await client.oauth.deviceAuthorization(
    clientID: "your-client-id", scope: "account.read apikeys.read apikeys.reveal",
)
print("Open \(device.verificationURI) and enter \(device.userCode)")

let token = try await client.oauth.pollDeviceToken(device, clientID: "your-client-id")
guard let apikey = token.apikey else {
    fatalError("no API key came back: none was picked, or it can't be shown again")
}
let keyed = VPNDetectionClient(apiKey: apikey)
```

A denied sign-in throws `OauthError.accessDenied` and a code that ran out `OauthError.expiredToken`. Client IDs are issued on request from support@vpndetection.io, and `client.oauth.revoke(refreshToken, clientID: "your-client-id")` signs the machine out again.

### Absent is not false

Only `ip` and `isVpn` come back on every plan. The rest are `Optional`, where `nil` means "not in your plan" rather than "checked, and no".

```swift
result.isHosting ?? false   // when you only want the flag
result.isHosting == nil     // when "not in my plan" has to be told apart
```

### Supplying your own transport

By default the library talks to the API over [AsyncHTTPClient](https://github.com/swift-server/async-http-client), configured to refuse redirects. Anything conforming to `ClientTransport` can take its place. To use `URLSession` on an Apple platform, add [swift-openapi-urlsession](https://github.com/apple/swift-openapi-urlsession) to your own package and hand its transport in:

```swift
import OpenAPIURLSession

let client = VPNDetectionClient(options: .init(transport: URLSessionTransport()))
```

One thing to know if you do: the download endpoint answers `302`, and the library follows that redirect itself as a second request rather than letting the transport do it, so a transport that follows redirects would read a whole database into memory before the library ever saw the link. Configure yours not to. The library refuses such a response rather than reading it, but the transfer has already started by then.

## Other Libraries

There are official VPNDetection client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/vpndetection-io for more.

## About VPNDetection

VPN Detection API: Accurate anonymity detection identifying VPNs, residential proxies, hosting servers, Tor nodes, CDNs, relays and more.

[<img src="https://s3.vpndetection.io/vpndetection-public/brand/mark.svg" alt="VPNDetection" width="96"/>](https://vpndetection.io/)

## License

This project is licensed under the [MIT License](LICENSE).
