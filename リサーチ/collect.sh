#!/usr/bin/env bash
# collect.sh - 「登録者が少ないのに再生が伸びている」AI系YouTube動画を収集する
#
#   条件: 直近6か月以内 / 再生数 >= 10,000 / チャンネル登録者数 < 10,000
#   出力: data/videos.json      抽出した動画のメタデータ
#         data/subs/<id>.txt    各動画の字幕(プレーンテキスト化)
#         data/subs/<id>.vtt    各動画の字幕(元データ)
#         リサーチ/videos.md    一覧表(リサーチ.md の第1章にそのまま使える)
#
# 使い方:
#   bash リサーチ/collect.sh              # デフォルト10本
#   WANT=15 bash リサーチ/collect.sh      # 15本ほしいとき
#   PER_QUERY=80 bash リサーチ/collect.sh # 1クエリあたりの検索件数を増やす

set -uo pipefail

# ---------------------------------------------------------------- 設定
WANT="${WANT:-10}"               # 最終的に採用する本数
PER_QUERY="${PER_QUERY:-50}"     # 1クエリあたりの検索件数
MONTHS="${MONTHS:-6}"            # 何か月前までを対象にするか
MIN_VIEWS="${MIN_VIEWS:-10000}"  # 再生数の下限
MAX_SUBS="${MAX_SUBS:-10000}"    # 登録者数の上限
MAX_PER_CHANNEL="${MAX_PER_CHANNEL:-2}"  # 同一チャンネルからの採用上限
SUB_LANGS="${SUB_LANGS:-ja,en}"  # 取得する字幕の言語

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/data"
SUB_DIR="$OUT_DIR/subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 検索クエリ。AI関連を日本語・英語の両面から広めに拾う。
QUERIES=(
  "AI 使い方"
  "生成AI 仕事"
  "Claude Code"
  "AIエージェント 自動化"
  "ChatGPT 活用"
  "AI 画像生成"
  "AI 副業"
  "AI 個人開発"
  "AI agent build"
  "Claude Code workflow"
)

log() { printf '\033[36m[collect]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[collect]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------- 依存関係の用意
ensure_deps() {
  if ! command -v jq >/dev/null 2>&1; then
    log "jq が無いのでインストールします"
    if command -v apt-get >/dev/null 2>&1; then
      (sudo -n apt-get update -qq && sudo -n apt-get install -y -qq jq) 2>/dev/null \
        || (apt-get update -qq && apt-get install -y -qq jq)
    elif command -v brew >/dev/null 2>&1; then
      brew install jq
    else
      err "jq を自動インストールできません。手動で入れてください。"; exit 1
    fi
  fi

  if ! command -v yt-dlp >/dev/null 2>&1; then
    log "yt-dlp が無いのでインストールします"
    if command -v pipx >/dev/null 2>&1; then
      pipx install yt-dlp
    elif command -v pip3 >/dev/null 2>&1; then
      pip3 install -U yt-dlp || pip3 install --break-system-packages -U yt-dlp
    elif command -v brew >/dev/null 2>&1; then
      brew install yt-dlp
    else
      err "yt-dlp を自動インストールできません。手動で入れてください。"; exit 1
    fi
  fi

  command -v yt-dlp >/dev/null 2>&1 || { err "yt-dlp が使えません"; exit 1; }
  command -v jq     >/dev/null 2>&1 || { err "jq が使えません"; exit 1; }
  log "yt-dlp $(yt-dlp --version) / jq $(jq --version)"
}

# ------------------------------------------------------------ 疎通チェック
# youtube.com に到達できない環境（社内プロキシ・egressポリシー）では
# 以降が全滅するので、ここで理由を明示して止める。
preflight() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://www.youtube.com/ 2>/dev/null)"
  if [ "$code" = "000" ] || [ -z "$code" ]; then
    err "youtube.com に到達できません（プロキシ/ネットワークポリシーによる遮断の可能性）。"
    if [ -n "${HTTPS_PROXY:-}" ]; then
      err "プロキシの状態: curl -sS \"\$HTTPS_PROXY/__agentproxy/status\""
    fi
    err "YouTube へ出られるネットワークで実行してください。"
    exit 2
  fi
  log "youtube.com 到達OK (HTTP $code)"
}

# ------------------------------------------------------- 1) 候補IDの洗い出し
search_candidates() {
  : > "$WORK/ids.txt"
  for q in "${QUERIES[@]}"; do
    log "検索: $q"
    # ytsearchdate = 新しい順。flat-playlist なので1クエリ1リクエストで速い。
    yt-dlp --flat-playlist --no-warnings --ignore-errors \
           --print "%(id)s" \
           "ytsearchdate${PER_QUERY}:${q}" 2>>"$WORK/search.err" >> "$WORK/ids.txt"
  done
  sort -u "$WORK/ids.txt" | grep -E '^[A-Za-z0-9_-]{11}$' > "$WORK/ids.uniq" || true
  log "候補動画: $(wc -l < "$WORK/ids.uniq") 本"
  if [ ! -s "$WORK/ids.uniq" ]; then
    err "検索結果が0件でした。search.err を確認してください:"
    tail -20 "$WORK/search.err" >&2 || true
    exit 3
  fi
}

# --------------------------------------- 2) 1本ずつ詳細を取り条件でふるいにかける
# flat-playlist では登録者数が取れないため、ここで個別に -J する。
fetch_details() {
  local cutoff total i=0 kept=0
  cutoff="$(date -u -d "${MONTHS} months ago" +%Y%m%d 2>/dev/null \
            || date -u -v-"${MONTHS}"m +%Y%m%d)"
  total="$(wc -l < "$WORK/ids.uniq")"
  log "詳細取得 (投稿日 >= $cutoff / 再生 >= $MIN_VIEWS / 登録者 < $MAX_SUBS)"
  : > "$WORK/hits.jsonl"

  while read -r id; do
    i=$((i+1))
    printf '\r[collect] %d/%d 判定中 (該当 %d)   ' "$i" "$total" "$kept" >&2
    yt-dlp -J --skip-download --no-warnings --ignore-errors \
           --sleep-requests 1 \
           "https://www.youtube.com/watch?v=${id}" 2>>"$WORK/detail.err" \
    | jq -c --arg cutoff "$cutoff" \
           --argjson minv "$MIN_VIEWS" \
           --argjson maxs "$MAX_SUBS" '
        select(.upload_date != null and .upload_date >= $cutoff)
      | select((.view_count // 0) >= $minv)
      | select(.channel_follower_count != null and .channel_follower_count > 0
               and .channel_follower_count < $maxs)
      | {
          id, title,
          channel:        (.channel // .uploader),
          channel_id:     (.channel_id // .uploader_id),
          channel_url:    (.channel_url // .uploader_url),
          subscribers:    .channel_follower_count,
          views:          .view_count,
          likes:          (.like_count // 0),
          comments:       (.comment_count // 0),
          upload_date:    .upload_date,
          duration:       (.duration // 0),
          url:            ("https://www.youtube.com/watch?v=" + .id),
          ratio:          ((.view_count // 0) / .channel_follower_count),
          description:    ((.description // "")[0:400])
        }' >> "$WORK/hits.jsonl" 2>/dev/null
    kept="$(wc -l < "$WORK/hits.jsonl")"
  done < "$WORK/ids.uniq"
  printf '\n' >&2
  log "条件該当: $kept 本"
  [ "$kept" -gt 0 ] || { err "条件に合う動画が0本でした。閾値かクエリを見直してください。"; exit 4; }
}

# ---------------------------- 3) 登録者比(再生/登録者)の高い順に、偏らないよう選抜
select_top() {
  jq -s --argjson want "$WANT" --argjson perch "$MAX_PER_CHANNEL" '
      sort_by(-.ratio)
    | reduce .[] as $v ({seen:{}, out:[]};
        if (.out | length) >= $want then .
        elif ((.seen[$v.channel_id // $v.channel] // 0) >= $perch) then .
        else .seen[$v.channel_id // $v.channel] = ((.seen[$v.channel_id // $v.channel] // 0) + 1)
             | .out += [$v]
        end)
    | .out
  ' "$WORK/hits.jsonl" > "$OUT_DIR/videos.json"
  log "採用: $(jq 'length' "$OUT_DIR/videos.json") 本 -> data/videos.json"
}

# ------------------------------------------------------------ 4) 字幕の取得
fetch_subs() {
  mkdir -p "$SUB_DIR"
  local n=0
  while read -r id; do
    n=$((n+1))
    log "字幕取得 ($n): $id"
    yt-dlp --skip-download --no-warnings --ignore-errors \
           --write-subs --write-auto-subs \
           --sub-langs "$SUB_LANGS" --sub-format "vtt" \
           --sleep-requests 1 \
           -o "$SUB_DIR/%(id)s.%(ext)s" \
           "https://www.youtube.com/watch?v=${id}" 2>>"$WORK/subs.err"

    # VTT -> プレーンテキスト（タイムコード・装飾タグ・重複行を落とす）
    local vtt
    vtt="$(ls "$SUB_DIR/${id}".*.vtt 2>/dev/null | head -1)"
    if [ -n "$vtt" ]; then
      sed -e '1,/^$/d' \
          -e '/-->/d' -e '/^WEBVTT/d' -e '/^Kind:/d' -e '/^Language:/d' \
          -e '/^NOTE/d' -e '/^[0-9]\+$/d' \
          -e 's/<[^>]*>//g' -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' \
          "$vtt" \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | awk 'NF && $0 != prev { print; prev = $0 }' \
      > "$SUB_DIR/${id}.txt"
      log "  -> ${id}.txt ($(wc -l < "$SUB_DIR/${id}.txt") 行)"
    else
      err "  字幕なし: $id"
      : > "$SUB_DIR/${id}.txt"
    fi
  done < <(jq -r '.[].id' "$OUT_DIR/videos.json")
}

# ------------------------------------------------- 5) 一覧表(Markdown)の書き出し
write_table() {
  local md="$ROOT/リサーチ/videos.md"
  {
    echo "# 収集結果一覧"
    echo
    echo "- 収集日時: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- 条件: 直近${MONTHS}か月 / 再生 >= $(printf "%'d" "$MIN_VIEWS") / 登録者 < $(printf "%'d" "$MAX_SUBS")"
    echo
    echo "| # | タイトル | チャンネル | 登録者数 | 再生数 | 登録者比 | 投稿日 | URL |"
    echo "|---|---|---|---|---|---|---|---|"
    jq -r 'to_entries[] | .key as $i | .value |
      "| \($i + 1) | \(.title) | \(.channel) | \(.subscribers) | \(.views) | \(.ratio | floor)倍 | \(.upload_date[0:4])-\(.upload_date[4:6])-\(.upload_date[6:8]) | \(.url) |"
    ' "$OUT_DIR/videos.json"
  } > "$md"
  log "一覧表 -> リサーチ/videos.md"
}

# ------------------------------------------------------------------ main
main() {
  ensure_deps
  preflight
  mkdir -p "$OUT_DIR" "$SUB_DIR"
  search_candidates
  fetch_details
  select_top
  fetch_subs
  write_table
  log "完了。data/subs/*.txt を読んで リサーチ/リサーチ.md にまとめてください。"
}

main "$@"
