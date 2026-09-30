# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

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
