#!/usr/bin/env bash
# One command from a fresh clone to a playable native build:
#
#   ./tools/setup.sh
#
#   1. fetch the game data (a WoW 1.12.1 client's Data folder, from archive.org — not committed)
#   2. build the game (`cargo build --release -p warcraft-survivors`)
#
# Each step is re-runnable and skips what is already done.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tools/fetch-data.sh
cargo build --release -p warcraft-survivors

echo
echo "All set. Start the game:"
echo "  WOW_DATA=wow-data/Data ./target/release/warcraft-survivors"
