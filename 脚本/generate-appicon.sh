#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appicon_dir="$root_dir/Mac版本/Codevoke/Assets.xcassets/AppIcon.appiconset"
source_png="${1:-$appicon_dir/icon_512x512@2x.png}"

if [[ ! -d "$appicon_dir" ]]; then
  printf 'AppIcon directory not found: %s\n' "$appicon_dir" >&2
  exit 1
fi

if [[ ! -f "$source_png" ]]; then
  printf 'Source PNG not found: %s\n' "$source_png" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/acode-appicon.XXXXXX")"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/acode-appicon-backup.XXXXXX")"
source_copy="$work_dir/source.png"
cp "$source_png" "$source_copy"
find "$appicon_dir" -maxdepth 1 -type f \( -name '*.png' -o -name 'Contents.json' \) -exec cp {} "$backup_dir" \;

restore_on_error() {
  cp "$backup_dir"/* "$appicon_dir"/ 2>/dev/null || true
  printf 'Generation failed. Restored previous AppIcon files from %s\n' "$backup_dir" >&2
}

cleanup() {
  rm -rf "$work_dir"
}

trap restore_on_error ERR
trap cleanup EXIT

swift_source="$work_dir/GenerateAppIcon.swift"
cat > "$swift_source" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
import ImageIO

struct IconSpec {
    let filename: String
    let pixels: Int
}

enum IconError: Error, CustomStringConvertible {
    case invalidImage(String)
    case renderFailed(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .invalidImage(let path): "Invalid source image: \(path)"
        case .renderFailed(let name): "Failed to render \(name)"
        case .writeFailed(let name): "Failed to write \(name)"
        }
    }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: GenerateAppIcon <source.png> <output-dir>\n".utf8))
    exit(64)
}

let sourceURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2], isDirectory: true)

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    throw IconError.invalidImage(sourceURL.path)
}

let specs = [
    IconSpec(filename: "icon_16x16.png", pixels: 16),
    IconSpec(filename: "icon_16x16@2x.png", pixels: 32),
    IconSpec(filename: "icon_32x32.png", pixels: 32),
    IconSpec(filename: "icon_32x32@2x.png", pixels: 64),
    IconSpec(filename: "icon_128x128.png", pixels: 128),
    IconSpec(filename: "icon_128x128@2x.png", pixels: 256),
    IconSpec(filename: "icon_256x256.png", pixels: 256),
    IconSpec(filename: "icon_256x256@2x.png", pixels: 512),
    IconSpec(filename: "icon_512x512.png", pixels: 512),
    IconSpec(filename: "icon_512x512@2x.png", pixels: 1024)
]

func renderIcon(size: Int, filename: String) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.renderFailed(filename)
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(rect)
    context.interpolationQuality = .high
    context.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(size) * 0.205, cornerHeight: CGFloat(size) * 0.205, transform: nil))
    context.clip()
    context.draw(image, in: rect)

    guard let outputImage = context.makeImage() else {
        throw IconError.renderFailed(filename)
    }

    let destinationURL = outputURL.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw IconError.writeFailed(filename)
    }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.writeFailed(filename)
    }
}

for spec in specs {
    try renderIcon(size: spec.pixels, filename: spec.filename)
}
SWIFT

swift "$swift_source" "$source_copy" "$appicon_dir"

cat > "$appicon_dir/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

python3 -m json.tool "$appicon_dir/Contents.json" >/dev/null

for filename in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png; do
  if [[ ! -s "$appicon_dir/$filename" ]]; then
    printf 'Generated file is missing or empty: %s\n' "$filename" >&2
    exit 1
  fi
done

trap - ERR
printf 'Generated AppIcon files in %s\nBackup of previous files: %s\n' "$appicon_dir" "$backup_dir"
