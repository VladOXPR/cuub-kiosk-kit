#!/usr/bin/env bash
# See README.md.
exec bash "$(cd "$(dirname "$0")" && pwd)/scripts/reset-to-relink.sh" "$@"
