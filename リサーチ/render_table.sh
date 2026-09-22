#!/usr/bin/env bash
# render_table.sh - videos.json から リサーチ.md 第1章の表を生成する
#
#   bash リサーチ/render_table.sh                       > /tmp/t.md
#   bash リサーチ/render_table.sh data/sample/videos.json
set -uo pipefail
FILE="${1:-data/videos.json}"
[ -f "$FILE" ] || { echo "ファイルがありません: $FILE" >&2; exit 1; }

if jq -e 'any(.[]; ._sample == true)' "$FILE" >/dev/null 2>&1; then
  echo "> ⚠ **以下はサンプルデータです。実在の動画ではありません。**"
  echo
fi

echo "| # | タイトル | チャンネル | 登録者数 | 再生数 | 登録者比 | 投稿日 | URL |"
echo "|---|---|---|---|---|---|---|---|"
jq -r 'to_entries[] | .key as $i | .value |
  "| \($i + 1) | \(.title) | \(.channel) | \(.subscribers) | \(.views) | \(.ratio|floor)倍 | \(.upload_date[0:4])-\(.upload_date[4:6])-\(.upload_date[6:8]) | \(.url) |"
' "$FILE"
