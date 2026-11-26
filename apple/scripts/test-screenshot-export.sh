#!/usr/bin/env bash
# Reject invalid exports before replacing the last complete store set.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc "$here/export-screenshots.swift" -o "$tmp/export"
cat > "$tmp/image.swift" <<'SWIFT'
import AppKit
import ImageIO
import UniformTypeIdentifiers
let width = Int(CommandLine.arguments[1])!
let height = Int(CommandLine.arguments[2])!
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[3]) as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
assert(CGImageDestinationFinalize(destination))
SWIFT
xcrun swiftc "$tmp/image.swift" -o "$tmp/image"
mkdir "$tmp/attachments" "$tmp/output"
printf 'last complete set' > "$tmp/output/old.png"
"$tmp/image" 1206 2622 "$tmp/attachments/image.png"
manifest() {
    jq -n --arg name "$1" --arg file "${2:-image.png}" \
        '[{attachments:[{suggestedHumanReadableName:$name,exportedFileName:$file,isAssociatedWithFailure:false}]}]' \
        > "$tmp/attachments/manifest.json"
}
reject() {
    if "$tmp/export" ios "$tmp/attachments" "$tmp/output" > "$tmp/log" 2>&1; then
        echo "unexpectedly accepted: $*" >&2; exit 1
    fi
    test "$(cat "$tmp/output/old.png")" = 'last complete set'
}
printf '[]' > "$tmp/attachments/manifest.json"
reject 'empty export'
manifest store-01-profiles.png ../image.png
reject 'path traversal'
manifest store-01-profiles.png
jq '.[0].attachments as $items | .[0].attachments = [range(11) | $items[]]' "$tmp/attachments/manifest.json" > "$tmp/many.json"
mv "$tmp/many.json" "$tmp/attachments/manifest.json"
reject 'too many screenshots'
manifest store-01-profiles.png
jq '.[0].attachments += .[0].attachments' "$tmp/attachments/manifest.json" > "$tmp/duplicate.json"
mv "$tmp/duplicate.json" "$tmp/attachments/manifest.json"
reject 'duplicate screenshot names'
manifest store-01-profiles.png
"$tmp/image" 100 100 "$tmp/attachments/image.png"
reject 'wrong dimensions'
"$tmp/image" 1206 2622 "$tmp/attachments/image.png"
manifest store-01-profiles.png
jq '.[0].attachments[0].isAssociatedWithFailure = true' "$tmp/attachments/manifest.json" > "$tmp/failure.json"
mv "$tmp/failure.json" "$tmp/attachments/manifest.json"
reject 'failure attachment'
manifest store-01-profiles.png
"$tmp/export" ios "$tmp/attachments" "$tmp/output"
test ! -e "$tmp/output/old.png"
test -f "$tmp/output/01-profiles.png"
sips -g hasAlpha "$tmp/output/01-profiles.png" | grep -q 'hasAlpha: no'
# Replacing an existing nonempty directory uses an atomic exchange.
"$tmp/export" ios "$tmp/attachments" "$tmp/output"
test -f "$tmp/output/01-profiles.png"
echo 'screenshot export tests passed'
