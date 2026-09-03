#!/bin/bash

# Refreshes the pinned OpenAPI spec from the published one.
#
# Sources/VPNDetection/openapi.yaml is what the build plugin reads, so a build
# stays reproducible and offline and the diff shows exactly which spec version
# produced the client. Run this deliberately, then commit the spec change
# alongside whatever it changed in the hand-written layer, so a reviewer sees
# both.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC_URL="${SPEC_URL:-https://s3.vpndetection.io/vpndetection-public/openapi/openapi.yaml}"

curl -fsS "$SPEC_URL" -o Sources/VPNDetection/openapi.yaml
echo "Sources/VPNDetection/openapi.yaml <- ${SPEC_URL}"
grep -m1 '^  version:' Sources/VPNDetection/openapi.yaml
