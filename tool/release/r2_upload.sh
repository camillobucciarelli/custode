#!/bin/bash
# Uploads a file to the Cloudflare R2 bucket behind custode.camillobucciarelli.dev via its S3 API
# (curl's SigV4, no aws CLI). An existing object at the same key is replaced.
# The optional cache control is stored by R2 and honoured by the custom domain's edge cache.
# Usage: r2_upload.sh <file> <object key> <content type> [cache control]
set -euo pipefail
file=${1:?usage: r2_upload.sh <file> <key> <content type> [cache control]}
key=${2:?usage: r2_upload.sh <file> <key> <content type> [cache control]}
type=${3:?usage: r2_upload.sh <file> <key> <content type> [cache control]}
cache=${4:-}
: "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_ACCOUNT_ID:?}" "${R2_BUCKET:?}"

sha=$(sha256sum "$file" | cut -d ' ' -f 1)
# Credentials go through stdin (--config -), not argv, so they never show in the process list.
printf 'user = "%s:%s"\n' "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" |
  curl --config - --fail-with-body --silent --show-error \
    --retry 3 --max-time 1800 \
    --aws-sigv4 'aws:amz:auto:s3' \
    -H "x-amz-content-sha256: $sha" \
    -H "Content-Type: $type" \
    ${cache:+-H "Cache-Control: $cache"} \
    --upload-file "$file" \
    "https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET/$key"
echo "Uploaded $key ($sha)"
