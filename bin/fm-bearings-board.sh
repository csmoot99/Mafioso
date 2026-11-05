#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# path       Print the stable board path for this home.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# A Captain's Call item MAY carry `images`, the screenshots the captain must see
# to decide: an array of up to 24 `{ "path", "alt", "caption"? }` objects, where `path`
# is an absolute local file (png, jpg, jpeg or webp, a regular file of at most
# 5 MB), `alt` is non-empty text, and `caption` is optional text. A card key that
# starts with `.` cannot carry images. build copies each file into
# $FM_HOME/.lavish/bearings-board-assets/<card-key>/<n>.<ext>, beside the stable
# board file where Lavish serves sibling files by relative path, replaces that
# whole folder on every build so no stale file survives, and injects only the
# relative `src` into the page data, never the local path. When ffmpeg is available,
# build also generates a 320-pixel-wide JPEG preview, top-cropped to at most 426
# pixels high, and adds its relative `thumbnail` when smaller than the original.
# Tiles load previews lazily; the lightbox opens the untouched original.
# Missing or failing ffmpeg keeps originals and prints one build note, without
# changing the payload or requiring image preparation. A bad `images` entry
# refuses before the existing board or its assets are touched.
#
# The payload MAY carry `reports`, the write-ups firstmate wrote for the captain,
# shown in the board's Reports tab: an array of up to 500 objects, each
# `{ "title", "repo", "date", "summary", "path" }`, where `title` is non-empty
# text, `repo` follows the same string-or-null marker as every other row, `date`
# is a real YYYY-MM-DD, `summary` is one line of text that may be empty, and
# `path` is an absolute path to a markdown report. build accepts only a regular
# file (never a symlink) named *.md, of at most 2 MB, that resolves inside
# "$FM_HOME/data/", and refuses anything else naming the report, before the
# existing board or its assets are touched. A report is untrusted text, so build
# renders it with bin/fm-bearings-md.pl into an inert HTML page (no script, no
# remote reference) at
# $FM_HOME/.lavish/bearings-board-assets/.reports/<n>.html, beside the board
# like a card image: Lavish's sandboxed frame cannot fetch a sibling file, so
# the board shows that page in an iframe instead. The whole assets folder is
# replaced on every build. Each page carries a Download link holding the report's
# original bytes, saved as <YYYY-MM-DD>-<title-slug>.md. Report metadata, relative
# `src` and plain-text search content (capped by bin/fm-bearings-md.pl --text)
# live in the generated .reports/index.js, never inline; only `reports_count`
# enters the page. That file delivers the index through a classic script callback
# because Lavish's opaque-origin sandbox cannot fetch sibling JSON without server
# CORS support. The page requests it on first opening
# Reports and shows loading until it arrives, independently of the other sections.
# Card and report authors keep the same fields and build command.
# A payload with no `reports`, or an empty
# list, builds exactly as before and the board shows no Reports tab.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# An Underway row MAY carry `progress`, which the Underway tab draws as progress
# bars: `{ "stage", "reached", "pct", "parts"? }`, where `reached` is the run
# stage reached (planning, building, validating, checks, ready, or reported for a
# finished scout), `stage` is that same value or one of the markers owner or
# stuck, `pct` is the whole-number fill (0-100) of the reached stage, and
# `parts`, when the feature has a recorded
# part list, is 1-40 ordered `{ "label", "state" }` objects whose state is
# merged, current or pending, in that order, with at most one current. The row
# then shows one bar for the parts merged out of the total and one bar per part:
# merged parts full, the current part filled to `pct`, later parts empty. A row
# with no `parts` shows its own stage bar only. A marker keeps the reached fill
# and its bar says in words that it waits on the owner or is stuck; such a row,
# like a row with no `progress`, also keeps its state pill. The values come from
# the bearings snapshot's in_flight `stage`, `reached` and `pct` and its `parts`
# rows (bin/fm-bearings-snapshot.sh owns their derivation), so the board is still
# built by this script with no model step, no worker message and no network call.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1
MAX_IMAGES=24
MAX_IMAGE_BYTES=5242880
ASSETS_DIR_NAME=bearings-board-assets
MAX_REPORTS=500
MAX_PARTS=40
MAX_REPORT_BYTES=2097152
REPORTS_DIR_NAME=.reports

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" --argjson max_images "$MAX_IMAGES" --argjson max_reports "$MAX_REPORTS" --argjson max_parts "$MAX_PARTS" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def valid_date: valid_filed and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def optional_images:
      (has("images") | not)
      or (.images
        | type == "array" and length <= $max_images
          and ([.[]
            | type == "object"
              and (.path | type == "string" and test("^/[^[:cntrl:]]+\\.(png|jpe?g|webp)$"; "i"))
              and (.alt | nonempty_string)
              and optional_string("caption")] | all));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and optional_images
      and (if has("images") then (.key | test("^[A-Za-z0-9_-]")) else true end)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def part_rank: {merged: 0, current: 1, pending: 2}[.state];
    def valid_parts:
      type == "array" and length >= 1 and length <= $max_parts
      and ([.[] | type == "object" and (.label | nonempty_string) and (.state | IN("merged", "current", "pending"))] | all)
      and ([.[] | part_rank] as $r | $r == ($r | sort))
      and ([.[] | select(.state == "current")] | length) <= 1;
    def optional_progress:
      (has("progress") | not)
      or (.progress
        | type == "object"
          and (.reached | IN("planning", "building", "validating", "checks", "ready", "reported"))
          and (.stage == .reached or (.stage | IN("owner", "stuck")))
          and (.pct | type == "number" and . >= 0 and . <= 100 and floor == .)
          and ((has("parts") | not) or (.parts | valid_parts)));
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string)
      and optional_progress;
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end);
    def report_item:
      type == "object" and repo_marker
      and (.title | nonempty_string)
      and (.date | valid_date)
      and (.summary | type == "string" and (test("[\\n\\r]") | not))
      and (.path | type == "string" and test("^[^[:cntrl:]]+$"));
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ((has("reports") | not)
      or (.reports | type == "array" and length <= $max_reports and ([.[] | report_item] | all)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

# --- Captain's Call screenshots -----------------------------------------------
# validate_payload owns the shape; these own the files. Every listed path must
# be an existing regular file within the size cap before anything is published.

validate_image_files() {  # <data.json>
  local path size
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$path" ] && [ -r "$path" ] || return 1
    size=$(wc -c < "$path") || return 1
    [ "$size" -le "$MAX_IMAGE_BYTES" ] || return 1
  done < <(jq -r '.captains_call[]? | .images[]?.path' "$1")
}

# The relative src a copied image is served under; one definition shared by the
# copy list and the rewrite so they cannot disagree.
# shellcheck disable=SC2016 # jq program text, not shell expansion
IMAGE_SRC_DEF='
  def image_src($key; $n): $dir + "/" + $key + "/" + ($n | tostring) + "." + (
    ascii_downcase | capture("\\.(?<ext>png|jpe?g|webp)$").ext);
'

# Copy every surviving card's images into <stage>, laid out as the served
# <card-key>/<n>.<ext>, and rewrite the payload so a card's `images` carry only
# the relative src, alt, caption and any generated thumbnail.
stage_images() {  # <payload.json> <stage-dir> <rewritten.json>
  local payload=$1 stage=$2 dest=$3 src path rel thumb noted=0
  local thumbs="$stage/thumbs.jsonl"
  : > "$thumbs"
  while IFS=$'\t' read -r src path; do
    rel=${src#*/}
    mkdir -p -- "$stage/${rel%/*}" && cp -- "$path" "$stage/$rel" || return 1
    thumb="${rel%.*}.thumb.jpg"
    # Tiles are at most 160 CSS pixels wide: 320px covers a 2x display.
    if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -nostdin -v error -threads 1 -i "$stage/$rel" \
      -vf "scale=320:-2,crop=iw:min(ih\,426):0:0" \
      -frames:v 1 -q:v 31 -threads 1 -y "$stage/$thumb" 2>/dev/null; then
      if [ "$(wc -c < "$stage/$thumb")" -lt "$(wc -c < "$stage/$rel")" ]; then
        jq -nc --arg src "$src" --arg thumbnail "$ASSETS_DIR_NAME/$thumb" \
          '{key:$src,value:$thumbnail}' >> "$thumbs" || return 1
      else
        rm -f -- "$stage/$thumb"
      fi
    else
      rm -f -- "$stage/$thumb"
      if [ "$noted" -eq 0 ]; then
        printf 'fm-bearings-board: thumbnails unavailable for some images; using originals\n' >&2
        noted=1
      fi
    fi
  done < <(jq -r --arg dir "$ASSETS_DIR_NAME" "$IMAGE_SRC_DEF"'
    .captains_call[]? | select(has("images")) | .key as $key
    | .images | to_entries[] | .key as $i | .value
    | [(.path | image_src($key; $i + 1)), .path] | @tsv' "$payload")
  jq --slurpfile thumbs "$thumbs" --arg dir "$ASSETS_DIR_NAME" "$IMAGE_SRC_DEF"'
    ($thumbs | from_entries) as $thumbnails | .captains_call |= map(if has("images")
      then .key as $key | .images |= (to_entries | map(
        .key as $i | .value
        | {src: (.path | image_src($key; $i + 1)), alt: .alt}
          + (if (.caption // "") != "" then {caption: .caption} else {} end)
          | . + (if $thumbnails[.src] then {thumbnail: $thumbnails[.src]} else {} end)))
      else . end)' "$payload" > "$dest" || return 1
  rm -f -- "$thumbs"
}

# --- Reports ------------------------------------------------------------------
# validate_payload owns the shape; these own the files. A report is untrusted
# text from a worker, so only a plain markdown file inside this home's data
# directory is ever read, and it is rendered, never copied raw, beside the board.

validate_report_files() {  # <data.json>
  local path root real size
  [ -n "$(jq -r '.reports[]? | .path' "$1" | head -1)" ] || return 0
  root=$(board_realpath "$FM_HOME/data") || fail "reports need the data directory, which does not exist: $FM_HOME/data"
  while IFS= read -r path; do
    case "$path" in /*) ;; *) fail "report path is not absolute: $path" ;; esac
    case "$path" in *.md) ;; *) fail "report path does not end in .md: $path" ;; esac
    [ ! -L "$path" ] || fail "report path is a symlink: $path"
    [ -f "$path" ] && [ -r "$path" ] || fail "report is not a readable regular file: $path"
    real=$(board_realpath "$path") || fail "cannot resolve the report path: $path"
    case "$real" in "$root"/*) ;; *) fail "report resolves outside $root: $path" ;; esac
    size=$(wc -c < "$path") || fail "cannot read the report: $path"
    [ "$size" -le "$MAX_REPORT_BYTES" ] || fail "report is larger than $MAX_REPORT_BYTES bytes: $path"
  done < <(jq -r '.reports[]? | .path' "$1")
}

# Render every report into <stage>/.reports/<n>.html, write title, repo, date,
# summary, relative src and plain-text search content to <stage>/.reports/index.js,
# and replace the payload's `reports` with `reports_count`.
stage_reports() {  # <payload.json> <stage-dir>; rewrites the payload in place
  local payload=$1 stage=$2 n=0 path name dir="$2/$REPORTS_DIR_NAME"
  while IFS=$'\t' read -r path name; do
    n=$((n + 1))
    mkdir -p -- "$dir" \
      && perl "$SCRIPT_DIR/fm-bearings-md.pl" "$path" "$name" > "$dir/$n.html" \
      && perl "$SCRIPT_DIR/fm-bearings-md.pl" --text "$path" | jq -Rs . >> "$dir/text.jsonl" || return 1
  done < <(jq -r '.reports[]? | [.path, (.date + "-" + ((.title | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")) | if . == "" then "report" else .[0:80] end) + ".md")] | @tsv' "$payload")
  [ "$n" -gt 0 ] || return 0
  jq --arg dir "$ASSETS_DIR_NAME/$REPORTS_DIR_NAME" --slurpfile texts "$dir/text.jsonl" '
    .reports |= (to_entries | map(.key as $i | .value
      | {title, repo, date, summary, text: $texts[$i], src: ($dir + "/" + ($i + 1 | tostring) + ".html")}))
  ' "$payload" > "$payload.r" || { rm -f -- "$payload.r"; return 1; }
  # Classic scripts work in Lavish's opaque-origin sandbox and offline file
  # copies; fetch(JSON) cannot read sibling assets without server CORS changes.
  { printf 'window.fmBearingsReports('; jq -c '.reports' "$payload.r" && printf ');\n'; } > "$dir/index.js" || return 1
  jq '.reports | length' "$payload.r" > "$dir/count" || return 1
  jq --argjson count "$(cat "$dir/count")" 'del(.reports) | .reports_count = $count' "$payload.r" > "$payload" || return 1
  rm -f -- "$dir/text.jsonl" "$dir/count" "$payload.r"
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
establish_board_session() {  # <board>
  local board=$1 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

command_build() {
  local data=${1-} board jsonfile tmp stage staged assets sid extracted effective owner version pre_reopen_owner
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  validate_image_files "$data" \
    || fail "a Captain's Call image is not a readable regular file of at most $MAX_IMAGE_BYTES bytes: $data"
  validate_report_files "$data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  stage=$(umask 077; mktemp -d "${board%/*}/.assets.XXXXXX") || fail "cannot stage the board images"
  staged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-staged.XXXXXX") || fail "cannot stage the board payload"
  if ! stage_images "$effective" "$stage" "$staged"; then
    rm -rf -- "$stage" "$staged" "$effective"
    fail "cannot copy the Captain's Call images beside the board"
  fi
  if ! stage_reports "$staged" "$stage"; then
    rm -rf -- "$stage" "$staged" "$effective"
    fail "cannot render the reports beside the board"
  fi
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert. The
  # payload goes to perl through a file rather than an environment string, so
  # injection does not depend on the kernel's per-string environment limit.
  jsonfile=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-json.XXXXXX") || { rm -rf -- "$stage" "$staged" "$effective"; fail "cannot stage the board data"; }
  if ! jq -c . "$staged" | sed 's/</\\u003c/g' > "$jsonfile"; then
    rm -rf -- "$stage" "$staged" "$effective" "$jsonfile"
    fail "cannot compact the board data"
  fi
  rm -f -- "$effective" "$staged"

  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || { rm -rf -- "$stage" "$jsonfile"; fail "cannot stage the board"; }
  if ! BOARD_JSON_FILE="$jsonfile" perl -pe 'BEGIN { open(my $fh, "<", $ENV{BOARD_JSON_FILE}) or die; local $/; $j = <$fh>; $j =~ s/\n\z// } s/^\Q'"$PLACEHOLDER"'\E$/$j/' "$TEMPLATE" > "$tmp"; then
    rm -rf -- "$tmp" "$stage" "$jsonfile"
    fail "cannot inject the board data"
  fi
  rm -f -- "$jsonfile"
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -rf -- "$tmp" "$stage"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -rf -- "$tmp" "$stage"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  # The whole assets folder is replaced, never merged, so a screenshot dropped
  # from a card cannot linger beside the board.
  assets="${board%/*}/$ASSETS_DIR_NAME"
  if ! { rm -rf -- "$assets" && mv -- "$stage" "$assets" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -rf -- "$tmp" "$stage"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
