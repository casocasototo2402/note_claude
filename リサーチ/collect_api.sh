#!/usr/bin/env bash
# collect_api.sh - YouTube Data API v3 版の収集スクリプト
#
# youtube.com へ直接出られない環境（egressポリシー遮断）でも、
# www.googleapis.com に到達できればメタデータを収集できる。
#
#   条件: 直近6か月以内 / 再生数 >= 10,000 / チャンネル登録者数 < 10,000
#
# ★制約: 字幕は取得できない。
#   Data API の captions.download はチャンネル所有者のOAuth認証が必須のため、
#   他人の動画の字幕は原理的に取れない。代替として概要欄・タグ・上位コメントを集める。
#   字幕が必要な場合は collect.sh（yt-dlp版）を youtube.com に出られる環境で実行すること。
#
# 使い方:
#   export YOUTUBE_API_KEY=xxxxx
#   bash リサーチ/collect_api.sh

set -uo pipefail

WANT="${WANT:-10}"
MONTHS="${MONTHS:-6}"
MIN_VIEWS="${MIN_VIEWS:-10000}"
MAX_SUBS="${MAX_SUBS:-10000}"
MAX_PER_CHANNEL="${MAX_PER_CHANNEL:-2}"
PER_QUERY="${PER_QUERY:-50}"      # 1クエリの検索件数(API上限50)
COMMENTS="${COMMENTS:-20}"        # 1動画あたり取得する上位コメント数

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# リポジトリ直下の .env があれば読み込む（APIキーの置き場）。
# 既に環境変数で渡されている場合はそちらを優先する。
if [ -f "$ROOT/.env" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "$key" ] || continue
    if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
      export "$key=$val"
    fi
  done < "$ROOT/.env"
fi
OUT_DIR="$ROOT/data"
META_DIR="$OUT_DIR/meta"
API="https://www.googleapis.com/youtube/v3"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

log() { printf '\033[36m[api]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[api]\033[0m %s\n' "$*" >&2; }

# ------------------------------------------------------------ 事前チェック
preflight() {
  command -v jq   >/dev/null 2>&1 || { err "jq がありません"; exit 1; }
  command -v curl >/dev/null 2>&1 || { err "curl がありません"; exit 1; }

  if [ -z "${YOUTUBE_API_KEY:-}" ]; then
    err "環境変数 YOUTUBE_API_KEY が未設定です。"
    err "  取得: Google Cloud Console -> APIとサービス -> 認証情報 -> APIキー"
    err "        「YouTube Data API v3」を有効化しておくこと"
    err "  設定: export YOUTUBE_API_KEY=xxxxx"
    exit 1
  fi

  # キーの有効性を1リクエストで確認（quota消費1）
  local resp
  resp="$(curl -sS --max-time 30 "$API/videos?part=id&chart=mostPopular&maxResults=1&key=${YOUTUBE_API_KEY}")"
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    err "APIキーが使えません:"
    echo "$resp" | jq -r '.error.message, (.error.errors[0].reason // empty)' >&2
    exit 1
  fi
  log "APIキー有効"
}

# APIを叩いてエラーなら止める共通関数
api_get() {
  local path="$1"; shift
  local url="$API/$path&key=${YOUTUBE_API_KEY}"
  local resp
  resp="$(curl -sS --max-time 60 "$url")"
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    local reason
    reason="$(echo "$resp" | jq -r '.error.errors[0].reason // "unknown"')"
    err "APIエラー ($reason): $(echo "$resp" | jq -r '.error.message')"
    if [ "$reason" = "quotaExceeded" ]; then
      err "1日のquotaを使い切りました。翌日(太平洋時間0時リセット)に再実行してください。"
      exit 5
    fi
    return 1
  fi
  echo "$resp"
}

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

# 1行1IDのファイルを、カンマ区切り50件ずつの行に詰め直す（videos/channels APIの上限が50件）
batch50() {
  awk '{a[NR]=$0}
       END{for(i=1;i<=NR;i+=50){s="";
             for(j=i;j<i+50&&j<=NR;j++) s=s (s==""?"":",") a[j];
             print s}}' "$1"
}

# ------------------------------------------------------- 1) 検索して候補IDを集める
# search.list は1回あたりquota 100単位と高いので、1クエリ1ページに抑える。
search_candidates() {
  local after
  after="$(date -u -d "${MONTHS} months ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-"${MONTHS}"m +%Y-%m-%dT%H:%M:%SZ)"
  log "検索対象: $after 以降"
  : > "$WORK/ids.txt"

  for q in "${QUERIES[@]}"; do
    log "検索: $q"
    # order=viewCount で「その期間に再生が伸びたもの」を優先的に拾う
    api_get "search?part=id&type=video&maxResults=${PER_QUERY}&order=viewCount&relevanceLanguage=ja&publishedAfter=${after}&q=$(urlenc "$q")" \
      | jq -r '.items[]?.id.videoId // empty' >> "$WORK/ids.txt"
  done

  sort -u "$WORK/ids.txt" | grep -E '^[A-Za-z0-9_-]{11}$' > "$WORK/ids.uniq" || true
  log "候補動画: $(wc -l < "$WORK/ids.uniq") 本"
  [ -s "$WORK/ids.uniq" ] || { err "検索結果が0件でした"; exit 3; }
}

# ------------------------------- 2) 動画の詳細を50件ずつまとめて取得(quota 1/回)
fetch_videos() {
  : > "$WORK/videos.jsonl"
  local batch n=0
  while read -r batch; do
    n=$((n+1))
    log "動画詳細 バッチ$n"
    api_get "videos?part=snippet,statistics,contentDetails&maxResults=50&id=${batch}" \
      | jq -c '.items[]? | {
          id,
          title:        .snippet.title,
          channel:      .snippet.channelTitle,
          channel_id:   .snippet.channelId,
          published_at: .snippet.publishedAt,
          views:        (.statistics.viewCount // "0" | tonumber),
          likes:        (.statistics.likeCount // "0" | tonumber),
          comments:     (.statistics.commentCount // "0" | tonumber),
          duration:     .contentDetails.duration,
          tags:         (.snippet.tags // []),
          description:  (.snippet.description // "")
        }' >> "$WORK/videos.jsonl"
  done < <(batch50 "$WORK/ids.uniq")
  log "詳細取得: $(wc -l < "$WORK/videos.jsonl") 本"
}

# ------------------------- 3) チャンネルの登録者数を50件ずつまとめて取得(quota 1/回)
fetch_channels() {
  jq -r '.channel_id' "$WORK/videos.jsonl" | sort -u > "$WORK/cids.txt"
  log "対象チャンネル: $(wc -l < "$WORK/cids.txt") 件"
  : > "$WORK/channels.jsonl"
  local batch n=0
  while read -r batch; do
    n=$((n+1))
    log "チャンネル詳細 バッチ$n"
    api_get "channels?part=statistics,snippet&maxResults=50&id=${batch}" \
      | jq -c '.items[]? | {
          channel_id:  .id,
          subscribers: (if .statistics.hiddenSubscriberCount == true then null
                        else (.statistics.subscriberCount // "0" | tonumber) end),
          channel_videos: (.statistics.videoCount // "0" | tonumber),
          channel_views:  (.statistics.viewCount // "0" | tonumber)
        }' >> "$WORK/channels.jsonl"
  done < <(batch50 "$WORK/cids.txt")
}

# ------------------------------------------- 4) 結合して条件で絞り、登録者比で選抜
select_top() {
  mkdir -p "$OUT_DIR"
  local cutoff
  cutoff="$(date -u -d "${MONTHS} months ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v-"${MONTHS}"m +%Y-%m-%dT%H:%M:%SZ)"

  jq -s --slurpfile chans <(jq -s '.' "$WORK/channels.jsonl") \
        --arg cutoff "$cutoff" \
        --argjson minv "$MIN_VIEWS" --argjson maxs "$MAX_SUBS" \
        --argjson want "$WANT" --argjson perch "$MAX_PER_CHANNEL" '
      ($chans[0] | map({key: .channel_id, value: .}) | from_entries) as $cmap
    | map(. + ($cmap[.channel_id] // {subscribers: null}))
      # 登録者数非公開のチャンネルは「1万未満」を確認できないので除外する
    | map(select(.subscribers != null and .subscribers > 0 and .subscribers < $maxs))
    | map(select(.views >= $minv))
    | map(select(.published_at >= $cutoff))
    | map(. + {ratio: (.views / .subscribers),
               url: ("https://www.youtube.com/watch?v=" + .id)})
    | sort_by(-.ratio)
    | reduce .[] as $v ({seen:{}, out:[]};
        if (.out|length) >= $want then .
        elif ((.seen[$v.channel_id] // 0) >= $perch) then .
        else .seen[$v.channel_id] = ((.seen[$v.channel_id] // 0) + 1) | .out += [$v] end)
    | .out
  ' "$WORK/videos.jsonl" > "$OUT_DIR/videos.json"

  local got; got="$(jq 'length' "$OUT_DIR/videos.json")"
  log "採用: $got 本 -> data/videos.json"
  [ "$got" -gt 0 ] || { err "条件に合う動画が0本でした。閾値かクエリを見直してください。"; exit 4; }
}

# --------------------------- 5) 上位コメントを取得（字幕の代わりの「刺さった理由」材料）
fetch_comments() {
  mkdir -p "$META_DIR"
  while read -r id; do
    log "コメント取得: $id"
    api_get "commentThreads?part=snippet&order=relevance&textFormat=plainText&maxResults=${COMMENTS}&videoId=${id}" \
      | jq '[.items[]?.snippet.topLevelComment.snippet
             | {author: .authorDisplayName, likes: .likeCount, text: .textOriginal}]' \
      > "$META_DIR/${id}.comments.json" 2>/dev/null \
      || echo '[]' > "$META_DIR/${id}.comments.json"   # コメント欄オフの動画はここに来る
  done < <(jq -r '.[].id' "$OUT_DIR/videos.json")

  # 動画ごとに「タイトル・概要欄・タグ・上位コメント」を1枚のテキストにまとめる
  while read -r id; do
    {
      jq -r --arg id "$id" '.[] | select(.id == $id) |
        "# " + .title,
        "channel: " + .channel + " / subscribers: " + (.subscribers|tostring) +
        " / views: " + (.views|tostring) + " / ratio: " + (.ratio|floor|tostring) + "x",
        "url: " + .url,
        "",
        "## tags",
        (.tags | join(", ")),
        "",
        "## description",
        .description' "$OUT_DIR/videos.json"
      echo; echo "## top comments"
      jq -r '.[] | "- (\(.likes)) \(.text)"' "$META_DIR/${id}.comments.json"
    } > "$META_DIR/${id}.txt"
  done < <(jq -r '.[].id' "$OUT_DIR/videos.json")
  log "メタ情報 -> data/meta/*.txt"
}

# ------------------------------------------------------------- 6) 一覧表の出力
write_table() {
  local md="$ROOT/リサーチ/videos.md"
  {
    echo "# 収集結果一覧（YouTube Data API v3）"
    echo
    echo "- 収集日時: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- 条件: 直近${MONTHS}か月 / 再生 >= ${MIN_VIEWS} / 登録者 < ${MAX_SUBS}"
    echo "- 注記: 字幕はAPIでは取得不可。概要欄・タグ・上位コメントで代替。"
    echo
    echo "| # | タイトル | チャンネル | 登録者数 | 再生数 | 登録者比 | 投稿日 | URL |"
    echo "|---|---|---|---|---|---|---|---|"
    jq -r 'to_entries[] | .key as $i | .value |
      "| \($i + 1) | \(.title) | \(.channel) | \(.subscribers) | \(.views) | \(.ratio|floor)倍 | \(.published_at[0:10]) | \(.url) |"
    ' "$OUT_DIR/videos.json"
  } > "$md"
  log "一覧表 -> リサーチ/videos.md"
}

main() {
  preflight
  search_candidates
  fetch_videos
  fetch_channels
  select_top
  fetch_comments
  write_table
  log "完了。data/meta/*.txt を読んで リサーチ/リサーチ.md にまとめてください。"
}

main "$@"
