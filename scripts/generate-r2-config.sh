#!/bin/sh
set -eu

: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
R2_REGION="${R2_REGION:-auto}"

case "$R2_ENDPOINT" in
  https://*|http://*) ;;
  *) echo "R2_ENDPOINT must start with http:// or https://" >&2; exit 1 ;;
esac

escape_swift_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

endpoint=$(escape_swift_string "$R2_ENDPOINT")
access_key=$(escape_swift_string "$R2_ACCESS_KEY_ID")
secret_key=$(escape_swift_string "$R2_SECRET_ACCESS_KEY")
bucket=$(escape_swift_string "$R2_BUCKET")
region=$(escape_swift_string "$R2_REGION")

mkdir -p App
umask 077
cat > App/Config.swift <<EOF
import Foundation

public struct R2Config {
    public static let endpoint = "$endpoint"
    public static let accessKeyId = "$access_key"
    public static let secretAccessKey = "$secret_key"
    public static let bucket = "$bucket"
    public static let region = "$region"
}
EOF
