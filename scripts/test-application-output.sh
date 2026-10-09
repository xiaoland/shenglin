#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"
mkdir -p local/ApplicationOutputChecks
swiftc -parse-as-library -o local/ApplicationOutputChecks/check \
    Shared/Protocol.swift Mac/ApplicationOutput.swift Mac/BrowserAdapter.swift Mac/ControlIPC.swift \
    scripts/test-application-output.swift
local/ApplicationOutputChecks/check
pnpm --dir BrowserExtension test
