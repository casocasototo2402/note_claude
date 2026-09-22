#!/usr/bin/env bash
# validate.sh - videos.json が収集条件を満たしているか検証する
#
#   bash リサーチ/validate.sh                      # data/videos.json を検証
#   bash リサーチ/validate.sh data/sample/videos.json
set -uo pipefail

FILE="${1:-data/videos.json}"
MONTHS="${MONTHS:-6}"
MIN_VIEWS="${MIN_VIEWS:-10000}"
MAX_SUBS="${MAX_SUBS:-10000}"
WANT="${WANT:-10}"

[ -f "$FILE" ] || { echo "ファイルがありません: $FILE" >&2; exit 1; }
jq -e 'type == "array"' "$FILE" >/dev/null || { echo "配列ではありません: $FILE" >&2; exit 1; }

cutoff="$(date -u -d "${MONTHS} months ago" +%Y%m%d 2>/dev/null || date -u -v-"${MONTHS}"m +%Y%m%d)"
echo "検証: $FILE"
echo "条件: 投稿日 >= $cutoff / 再生 >= $MIN_VIEWS / 登録者 < $MAX_SUBS / $WANT 本"
echo

# サンプルデータを実データとして検証しようとしたら警告する
if jq -e 'any(.[]; ._sample == true)' "$FILE" >/dev/null 2>&1; then
  echo "⚠  警告: このファイルはサンプルデータです（_sample: true）。分析結果には使えません。"
  echo
fi

jq -r --arg cutoff "$cutoff" --argjson minv "$MIN_VIEWS" --argjson maxs "$MAX_SUBS" --argjson want "$WANT" '
  def chk($v):
    [ (if ($v.upload_date // "") < $cutoff then "投稿日が古い(\($v.upload_date // "不明"))" else empty end),
      (if ($v.views // 0) < $minv then "再生数不足(\($v.views // 0))" else empty end),
      (if ($v.subscribers // 0) >= $maxs then "登録者過多(\($v.subscribers // 0))" else empty end),
      (if ($v.subscribers // 0) <= 0 then "登録者数が不正" else empty end)
    ];
  ( [ .[] | select((chk(.) | length) > 0) ] ) as $bad
| ( [ .[] | .channel_id // .channel ] | group_by(.) | map(select(length > 2)) ) as $dup
| "本数: \(length) 本 " + (if length == $want then "OK" else "(期待 \($want) 本)" end),
  "条件違反: \($bad | length) 本" ,
  ( $bad[] | "  ✗ \(.id): \(chk(.) | join(", "))" ),
  "同一チャンネル3本以上: \($dup | length) 件",
  ( $dup[] | "  ✗ \(.[0]) が \(length) 本" ),
  "",
  "登録者比の分布:",
  ( "  最大 \([.[].ratio] | max | floor)倍 / 中央 \(([.[].ratio] | sort | .[length/2|floor]) | floor)倍 / 最小 \([.[].ratio] | min | floor)倍" ),
  "",
  ( if ($bad | length) == 0 and ($dup | length) == 0 then "✅ 全件が条件を満たしています" else "❌ 条件違反があります" end )
' "$FILE"

# 違反があれば終了コード1を返す（他スクリプトから条件分岐できるように）
violations="$(jq --arg cutoff "$cutoff" --argjson minv "$MIN_VIEWS" --argjson maxs "$MAX_SUBS" '
  [ .[] | select(((.upload_date // "") < $cutoff)
                 or ((.views // 0) < $minv)
                 or ((.subscribers // 0) >= $maxs)
                 or ((.subscribers // 0) <= 0)) ] | length
' "$FILE")"
dups="$(jq '[ .[] | .channel_id // .channel ] | group_by(.) | map(select(length > 2)) | length' "$FILE")"
[ "$violations" -eq 0 ] && [ "$dups" -eq 0 ]
