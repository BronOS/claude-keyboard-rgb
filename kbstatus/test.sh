#!/bin/bash
# Build core.swift + tests/main.swift into a throwaway binary and run it. Exit code 1 on any failure.
set -euo pipefail
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/kbstatus-tests"
xcrun swiftc -o "$out" core.swift tests/main.swift
"$out"
