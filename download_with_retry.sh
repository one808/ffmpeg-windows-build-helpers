#!/usr/bin/env bash
# download_with_retry.sh — 重试下载直到成功，用于 savannah/gmplib 等间歇性故障的源
#
# 用法:
#   ./download_with_retry.sh <url> <output_file> [max_retries] [base_delay]
#
# 默认每次间隔 10s 重试，指数退避，最多 18 次（总等待 ~3min），失败后输出原始错误。
set -euo pipefail

URL="${1:?用法: $0 <url> <output_file> [max_retries] [base_delay]}"
OUT="${2:?用法: $0 <url> <output_file> [max_retries] [base_delay]}"
MAX="${3:-18}"
BASE_DELAY="${4:-10}"

attempt=0
delay=$BASE_DELAY

echo "[retry] Downloading $URL"
echo "[retry] Output:   $OUT"
echo "[retry] Max:      $MAX, base delay: ${BASE_DELAY}s"

while [[ $attempt -lt $MAX ]]; do
  attempt=$((attempt + 1))
  echo -n "[$attempt/$MAX] ... "
  if wget -nv -O "$OUT" "$URL" 2>&1; then
    echo "OK"
    if [[ -s "$OUT" ]]; then
      echo "[success] Downloaded $(wc -c < "$OUT") bytes to $OUT"
      exit 0
    else
      echo "[warn] Empty file, retrying..."
    fi
  else
    echo "failed"
  fi

  if [[ $attempt -ge $MAX ]]; then
    break
  fi

  echo "  waiting ${delay}s before next attempt..."
  sleep "$delay"
  delay=$((delay * 2))
  [[ $delay -gt 30 ]] && delay=30
done

echo "[failed] Could not download after $MAX attempts." >&2
exit 1
