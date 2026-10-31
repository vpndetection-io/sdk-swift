# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

## 4.10.3 - 2026-10-31

### Fixes

- Read each batch entry on its own, so one it cannot read fails only its address ([`b76d72a`](https://github.com/vpndetection-io/sdk-swift/commit/b76d72a710a751966f34eed788c28bc08a72e634))
- Refuse a per-call retries below zero before anything answers ([`7b163e0`](https://github.com/vpndetection-io/sdk-swift/commit/7b163e012658631b16d572bbc9d1d7f7b3c73439))

## 4.10.2 - 2026-10-27

### Fixes

- Read dates as RFC 3339 alone, and an empty license type as unreadable ([`2b95065`](https://github.com/vpndetection-io/sdk-swift/commit/2b9506582c576266f0872700e6c0a70b8442c6ba))

## 4.10.1 - 2026-10-26

### Fixes

- Re-pin the spec to 2026.10.25: Retry-After on myip's 429 ([`30bcac4`](https://github.com/vpndetection-io/sdk-swift/commit/30bcac4d4f86c583617a5471529cc7e17023e689))

## 4.10.0 - 2026-10-25

### Features

- Add oauth.register, for RFC 7591 dynamic client registration ([`5239c61`](https://github.com/vpndetection-io/sdk-swift/commit/5239c6164cd1082c4fd6a6cbc100e0837eecb35c))

## 4.9.0 - 2026-10-20

### Features

- Re-pin the spec to 2026.10.20: open on databases and downloads ([`fc6f259`](https://github.com/vpndetection-io/sdk-swift/commit/fc6f25908408438ac4c53d70f7b3c638e9705c50))
- Add location and asn to lookup results, a bogon's included ([`07eb748`](https://github.com/vpndetection-io/sdk-swift/commit/07eb7484f16f100364c8de12fdda9478ba562c11))

## 4.8.1 - 2026-10-19

### Fixes

- Trim the API key, and refuse one holding a control character ([`2755365`](https://github.com/vpndetection-io/sdk-swift/commit/275536558714f6d9c5f96bec9093fcfd548e5895))
- Read Retry-After strictly, and an unreadable 2xx as a retried server error ([`86eec82`](https://github.com/vpndetection-io/sdk-swift/commit/86eec82f9d632938960a344130cae1a43e3b1410))

## 4.8.0 - 2026-10-19

### Features

- Re-pin the spec to 2026.10.19: num_ports and num_proxies in the pubproxy detail ([`0a428df`](https://github.com/vpndetection-io/sdk-swift/commit/0a428df6d93892d912b80bda320fb2b2e01bc3a7))

## 4.7.0 - 2026-10-18

### Features

- Re-pin the spec to 2026.10.18: isPubproxy and the pubproxy detail ([`8f99fb7`](https://github.com/vpndetection-io/sdk-swift/commit/8f99fb7cc5750efe6e0a3ea2081e17df7fa88ea3))

## 4.6.0 - 2026-10-17

### Features

- Re-pin the spec to 2026.10.16: dynamic client registration ([`ab57bfc`](https://github.com/vpndetection-io/sdk-swift/commit/ab57bfc94106f1e57abba5f7423ebb575c05c0cc))

## 4.5.2 - 2026-10-16

### Fixes

- Re-pin the spec to 2026.10.15: descriptions in US spelling ([`596be5c`](https://github.com/vpndetection-io/sdk-swift/commit/596be5cabdf1462ed424c72f08cbfe77a6ab4ba9))

## 4.5.1 - 2026-10-10

### Fixes

- Re-pin the spec to 2026.10.09: rotating a key needs apikeys.reveal ([`34f173b`](https://github.com/vpndetection-io/sdk-swift/commit/34f173b035fd11f041425021bf64c18d18dbaad8))

## 4.5.0 - 2026-10-05

### Features

- Add the authorization code sign-in, with PKCE ([`7e2a4ca`](https://github.com/vpndetection-io/sdk-swift/commit/7e2a4ca43ef050de660868aaaccdf77f91012573))

### Fixes

- End the device poll's wait at the code's expiry, and never crash on its interval ([`9991cbb`](https://github.com/vpndetection-io/sdk-swift/commit/9991cbb45472196e4d95fbbdae3a8aeebbedcc67))
- Refuse an impossible poll timeout before the first wait ([`a67db7e`](https://github.com/vpndetection-io/sdk-swift/commit/a67db7e5054b3955a2ecd320818df20558452098))
- Wait out a Retry-After past 2^31 - 1 ms on the backoff ([`74d63e9`](https://github.com/vpndetection-io/sdk-swift/commit/74d63e907e83fee488f8523e553a39ca0ae93915))

## 4.4.3 - 2026-10-04

### Fixes

- Re-pin the spec to 2026.10.03: metadata needs no license ([`d0a2d7d`](https://github.com/vpndetection-io/sdk-swift/commit/d0a2d7d7e8079f83bdd6da3129bce68c594934fd))

## 4.4.2 - 2026-10-02

### Fixes

- Share one request per address across lookups and batches ([`9687c4d`](https://github.com/vpndetection-io/sdk-swift/commit/9687c4d14eba71c4367bba114cfbf01b51172352))
- Refuse an impossible per-call timeout before a bogon or cached answer ([`d88be7f`](https://github.com/vpndetection-io/sdk-swift/commit/d88be7fecfe9369b9f6559e72a06fa069fd53efc))

## 4.4.1 - 2026-09-30

### Fixes

- Judge an IPv4-mapped address as the IPv4 address it carries ([`faa9353`](https://github.com/vpndetection-io/sdk-swift/commit/faa9353f5c82a9a6d50414c18ad5686a65ffc0ad))
- Recognize 26 more reserved ranges as bogons, as the API does ([`5bdaede`](https://github.com/vpndetection-io/sdk-swift/commit/5bdaede26814a052ca63962b372e6776e8ce691b))
- Refuse an IPv6 address with a second :: run rather than reading it as one ([`45f12dd`](https://github.com/vpndetection-io/sdk-swift/commit/45f12ddc1d88754b09e5f9c41e46c6b3dc5ff7be))

## 4.4.0 - 2026-09-27

### Features

- Re-pin the spec to 2026.09.26, adding clientIdMetadataDocumentSupported ([`9a007e0`](https://github.com/vpndetection-io/sdk-swift/commit/9a007e0d2600c87d0d6ae5e02b40032c1ecc8dbf))

## 4.3.2 - 2026-09-22

### Fixes

- Re-pin the spec to 2026.09.21 ([`b6ae15f`](https://github.com/vpndetection-io/sdk-swift/commit/b6ae15fbab538f9b4bdd18f957efde5995698348))
