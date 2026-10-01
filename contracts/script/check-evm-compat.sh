#!/usr/bin/env bash
# Verifies no post-London opcodes (PUSH0 / TLOAD / TSTORE / MCOPY) appear in any instruction stream.
# Uses solc's own assembly listing, which separates executable code from data sections (a raw byte
# scan gives false positives on constants such as ERC-7201 storage slots).
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
for c in DmdSwapFactory DmdSwapPair DmdSwapRouter DmdNameResolver DmdNameRouter WDMD UpgradeableBeacon TimelockController ERC1967Proxy BeaconProxy; do
  n=$(forge inspect "$c" assembly 2>/dev/null | grep -ciE '\b(PUSH0|TSTORE|TLOAD|MCOPY)\b' || true)
  printf '%-22s post-London instructions: %s\n' "$c" "$n"
  [ "$n" = "0" ] || status=1
done
exit $status
