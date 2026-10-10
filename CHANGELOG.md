# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

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
