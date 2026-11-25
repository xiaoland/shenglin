#!/bin/sh
set -eu
cd "$(dirname "$0")"
output=../../local/metadata-check
mkdir -p "$output"
cat > "$output/main.swift" <<'SWIFT'
import Foundation
let found = methodReport("NSObject", selectors: ["description", "definitelyMissingSelectorForProbe"])
assert(found[0] == "NSObject: 类存在")
assert(!found[1].contains("未找到"))
assert(found[2].contains("未找到"))
assert(methodReport("DefinitelyMissingClassForProbe", selectors: ["init"]).first?.contains("类不存在") == true)
assert(experimentCommand(Data("secret ping 104".utf8), token: "secret", now: 100) == "ping")
for text in ["wrong duck 104", "secret duck 99", "secret duck 111", "secret duck inf", "secret duck nan", "secret duck 104 extra", "secret unknown 104"] {
    assert(experimentCommand(Data(text.utf8), token: "secret", now: 100) == nil)
}
print("类缺失、方法缺失与方法签名分支检查通过；未扫描或调用私有库。")
SWIFT
xcrun swiftc Scan.swift "$output/main.swift" -o "$output/check"
"$output/check"
xcodebuild -project MetadataProbe.xcodeproj -scheme MetadataProbe -sdk iphoneos -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO build > "$output/build.log" 2>&1
tail -3 "$output/build.log"
