#!/bin/sh

usage() {
  cat <<'EOF'
Usage:
  sh scripts/refresh.sh [--beads-dir <path>] [--out <path>] [--no-bd-enrich] [--auto-export]

Behavior:
  - With --auto-export (and bd on PATH): runs `bd export` (never --all, so memories/infra
    stay excluded) into .beads/issues.jsonl first, so the snapshot reflects bd's real
    current state instead of whatever issues.jsonl happened to hold already. Off by
    default so existing callers/tests keep today's behavior unchanged.
  - Finds .beads/issues.jsonl by explicit --beads-dir or by walking up from cwd.
  - Writes a UTF-8 no-BOM orchestration-data.js snapshot to --out.
EOF
}

json_escape() {
  awk '
    BEGIN {
      RS = "\0";
      ORS = "";
      esc["\\"] = "\\\\";
      esc["\""] = "\\\"";
      esc["\b"] = "\\b";
      esc["\f"] = "\\f";
      esc["\n"] = "\\n";
      esc["\r"] = "\\r";
      esc["\t"] = "\\t";
      for (i = 0; i < 32; i++) {
        ch = sprintf("%c", i);
        if (!(ch in esc)) {
          esc[ch] = sprintf("\\u%04x", i);
        }
      }
    }
    {
      printf "\"";
      text = $0;
      n = length(text);
      i = 1;
      while (i <= n) {
        # U+2028/U+2029 matched as explicit UTF-8 byte triples: byte-oriented awks
        # (mawk, BWK) walk one byte at a time, so single-"char" table keys never fire.
        tri = substr(text, i, 3);
        if (tri == "\342\200\250") { printf "\\u2028"; i += 3; continue; }
        if (tri == "\342\200\251") { printf "\\u2029"; i += 3; continue; }
        ch = substr(text, i, 1);
        if (ch in esc) {
          printf "%s", esc[ch];
        } else {
          printf "%s", ch;
        }
        i++;
      }
      printf "\"";
    }
  '
}

read_raw_file() {
  awk '
    BEGIN { RS = "\0"; ORS = "" }
    {
      text = $0;
      # strip UTF-8 BOM via literal octal bytes: \xHH regex escapes are gawk-only
      if (substr(text, 1, 3) == "\357\273\277") {
        text = substr(text, 4);
      }
      printf "%s", text;
    }
  ' "$1"
}

sanitize_memory_value() {
  # Portable awk only: gensub()/IGNORECASE are gawk extensions (mawk/BWK lack them).
  # Case-insensitive matching is done on a tolower() shadow copy; RSTART/RLENGTH
  # positions on the shadow map 1:1 onto the original bytes.
  awk '
    function redact(text, pat,   low, out, cut, skip) {
      low = tolower(text);
      out = "";
      while (match(low, pat)) {
        cut = RSTART + RLENGTH - 1;
        out = out substr(text, 1, cut);
        text = substr(text, cut + 1);
        low = substr(low, cut + 1);
        if (match(text, /^[^"\047[:space:]]+/)) {
          skip = RLENGTH;
          out = out "***REDACTED***";
          text = substr(text, skip + 1);
          low = substr(low, skip + 1);
        }
      }
      return out text;
    }
    BEGIN {
      RS = "\0";
      ORS = "";
      # trailing suffix group catches SECRET_KEY / TOKEN_ID style compounds too
      kw = "(api[_-]?key|bearer|token|password|secret|credential|private[_-]?key|aws_secret_access_key)([_-][A-Za-z0-9_-]*)?";
    }
    {
      text = $0;
      text = redact(text, kw "[\"\047]?[[:space:]]*[:=][[:space:]]*[\"\047]?");
      text = redact(text, kw "[[:space:]]+[\"\047]?");
      if (length(text) > 2000) {
        text = substr(text, 1, 2000);
      }
      printf "%s", text;
    }
  '
}

resolve_dir() {
  cd "$1" 2>/dev/null && pwd -P
}

resolve_file() {
  path=$1
  case $path in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*)
      abs=$path
      ;;
    *)
      abs=$(pwd -P)/$path
      ;;
  esac
  dir=$(dirname "$abs")
  base=$(basename "$abs")
  if resolved=$(resolve_physical_dir "$dir" 2>/dev/null); then
    printf '%s/%s\n' "$resolved" "$base"
    return 0
  fi
  printf '%s/%s\n' "$dir" "$base"
}

resolve_physical_dir() {
  dir=$1
  case $dir in
    [A-Za-z]:/*|[A-Za-z]:\\*)
      printf '%s\n' "$dir"
      return 0
      ;;
  esac
  if resolved=$(readlink -f -- "$dir" 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi
  if resolved=$(realpath -- "$dir" 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi
  resolve_dir "$dir"
}

ensure_no_symlink_chain() {
  path=$1
  if [ -L "$path" ]; then
    printf '%s\n' "error: refusing to write through symlink: $path" >&2
    exit 1
  fi

  parent=$(dirname "$path")
  while [ -n "$parent" ] && [ "$parent" != "/" ] && [ "$parent" != "." ]; do
    if [ -L "$parent" ]; then
      printf '%s\n' "error: refusing to write through symlink parent: $parent" >&2
      exit 1
    fi
    next=$(dirname "$parent")
    if [ "$next" = "$parent" ]; then
      break
    fi
    parent=$next
  done
}

find_issues_in_dir() {
  dir=$1
  if [ -f "$dir/issues.jsonl" ]; then
    printf '%s\n' "$dir/issues.jsonl"
    return 0
  fi
  if [ -f "$dir/.beads/issues.jsonl" ]; then
    printf '%s\n' "$dir/.beads/issues.jsonl"
    return 0
  fi
  return 1
}

find_issues_upward() {
  dir=$(pwd -P) || return 1
  while :; do
    if [ -f "$dir/.beads/issues.jsonl" ]; then
      printf '%s\n' "$dir/.beads/issues.jsonl"
      return 0
    fi
    parent=$(dirname "$dir")
    if [ "$parent" = "$dir" ]; then
      return 1
    fi
    dir=$parent
  done
}

find_project_dir_upward() {
  dir=$(pwd -P) || return 1
  while :; do
    if [ -d "$dir/.beads" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    parent=$(dirname "$dir")
    if [ "$parent" = "$dir" ]; then
      return 1
    fi
    dir=$parent
  done
}

# Mirrors find_issues_in_dir's dual meaning for --beads-dir (either the .beads
# folder itself, or a project root containing .beads) so auto-export writes to
# the same place a later read would look for it. issues.jsonl may not exist
# yet (that's the point of exporting), so this can't disambiguate by checking
# for the file the way find_issues_in_dir does. Sets RESOLVED_BEADS_DIR and
# RESOLVED_PROJECT_DIR directly (no subshell / command substitution) rather
# than returning a combined string to split — a Windows path here can contain
# spaces, which a naive "beads_dir project_dir" split would corrupt.
resolve_beads_export_target() {
  dir=$1
  base=$(basename "$dir")
  if [ "$base" = ".beads" ]; then
    RESOLVED_BEADS_DIR=$dir
    RESOLVED_PROJECT_DIR=$(dirname "$dir")
    return 0
  fi
  if [ -d "$dir/.beads" ]; then
    RESOLVED_BEADS_DIR="$dir/.beads"
    RESOLVED_PROJECT_DIR=$dir
    return 0
  fi
  # Neither: fall back to treating the given dir as the beads dir directly,
  # matching find_issues_in_dir's "direct" precedence.
  RESOLVED_BEADS_DIR=$dir
  RESOLVED_PROJECT_DIR=$dir
}

do_auto_export() {
  if ! command -v bd >/dev/null 2>&1; then
    printf '%s\n' 'warning: --auto-export requested but bd is not on PATH; using issues.jsonl as-is' >&2
    return 0
  fi
  if [ -n "$BEADS_DIR" ]; then
    beads_dir_abs=$(resolve_dir "$BEADS_DIR") || beads_dir_abs=
    if [ -n "$beads_dir_abs" ]; then
      resolve_beads_export_target "$beads_dir_abs"
      beads_dir=$RESOLVED_BEADS_DIR
      project_dir=$RESOLVED_PROJECT_DIR
    else
      beads_dir=
      project_dir=
    fi
  else
    project_dir=$(find_project_dir_upward) || project_dir=
    if [ -n "$project_dir" ]; then
      beads_dir="$project_dir/.beads"
    else
      beads_dir=
    fi
  fi
  if [ -z "$beads_dir" ]; then
    printf '%s\n' 'warning: --auto-export requested but no .beads directory was found; using issues.jsonl as-is' >&2
    return 0
  fi
  # Never --all: that also pulls in bd remember memories, which routinely hold
  # agent-context notes never meant to leave the machine. -C scopes bd's own DB
  # discovery to the resolved project dir instead of the ambient cwd, so an
  # explicit --beads-dir for a different project exports THAT project's data,
  # not whatever bd would find walking up from wherever this script runs.
  if ! bd -C "$project_dir" export -o "$beads_dir/issues.jsonl" 2>/dev/null; then
    printf '%s\n' 'warning: bd export failed; using issues.jsonl as-is' >&2
  fi
}

BEADS_DIR=
OUT=./orchestration-data.js
NO_BD_ENRICH=0
AUTO_EXPORT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --beads-dir|-BeadsDir)
      if [ $# -lt 2 ]; then
        usage >&2
        printf '%s\n' 'error: --beads-dir requires a value' >&2
        exit 1
      fi
      BEADS_DIR=$2
      shift 2
      ;;
    --out|-Out)
      if [ $# -lt 2 ]; then
        usage >&2
        printf '%s\n' 'error: --out requires a value' >&2
        exit 1
      fi
      OUT=$2
      shift 2
      ;;
    --no-bd-enrich|-NoBdEnrich)
      NO_BD_ENRICH=1
      shift
      ;;
    --auto-export|-AutoExport)
      AUTO_EXPORT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf '%s\n' "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$AUTO_EXPORT" -eq 1 ]; then
  do_auto_export
fi

if [ -n "$BEADS_DIR" ]; then
  beads_abs=$(resolve_dir "$BEADS_DIR") || {
    usage >&2
    printf '%s\n' 'error: could not resolve --beads-dir' >&2
    exit 1
  }
  issues_path=$(find_issues_in_dir "$beads_abs") || {
    usage >&2
    printf '%s\n' 'error: could not find .beads/issues.jsonl' >&2
    exit 1
  }
else
  issues_path=$(find_issues_upward) || {
    usage >&2
    printf '%s\n' 'error: could not find .beads/issues.jsonl' >&2
    exit 1
  }
fi

out_path=$(resolve_file "$OUT") || {
  usage >&2
  printf '%s\n' 'error: could not resolve --out' >&2
  exit 1
}
# randomized temp suffix: defeats pre-planting a symlink at a predictable name
temp_rand=$(awk 'BEGIN { srand(); printf "%06d", int(rand() * 1000000) }')
temp_path=$out_path.$$.$temp_rand.tmp

ensure_no_symlink_chain "$out_path"
ensure_no_symlink_chain "$temp_path"

case $out_path in
  */.git|*/.git/*|.git|.git/*)
    usage >&2
    printf '%s\n' 'error: refusing to write inside a .git directory' >&2
    exit 1
    ;;
esac

case $temp_path in
  */.git|*/.git/*|.git|.git/*)
    usage >&2
    printf '%s\n' 'error: refusing to write inside a .git directory' >&2
    exit 1
    ;;
esac

out_dir=$(dirname "$out_path")
if [ ! -d "$out_dir" ]; then
  mkdir -p "$out_dir" || exit 1
fi

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_json=$(printf '%s' "$issues_path" | json_escape)
generated_json=$(printf '%s' "$generated_at" | json_escape)
issues_jsonl_json=$(read_raw_file "$issues_path" | json_escape)

orchestrator_json=
if [ "$NO_BD_ENRICH" -eq 0 ] && command -v bd >/dev/null 2>&1; then
  printf '%s\n' 'warning: bd memory enrichment is included in this publishable snapshot; use --no-bd-enrich to disable it' >&2
  if memories_output=$(bd memories 2>/dev/null); then
    keys=$(printf '%s\n' "$memories_output" | awk '/^  [^[:space:]]/ { sub(/^  /, ""); print }')
    if [ -n "$keys" ]; then
      first_pair=1
      orchestrator_json=
      while IFS= read -r key; do
        case "$key" in
          orchestrator-lock*|handoff*|attempts-*)
            value=$(bd recall "$key" 2>/dev/null) || continue
            safe_value=$(printf '%s' "$value" | sanitize_memory_value)
            encoded_key=$(printf '%s' "$key" | json_escape)
            encoded_value=$(printf '%s' "$safe_value" | json_escape)
            pair=$encoded_key:$encoded_value
            if [ $first_pair -eq 1 ]; then
              orchestrator_json=$pair
              first_pair=0
            else
              orchestrator_json=$orchestrator_json,$pair
            fi
            ;;
        esac
      done <<EOF
$keys
EOF
      if [ -n "$orchestrator_json" ]; then
        orchestrator_json="{$orchestrator_json}"
      fi
    fi
  fi
fi

snapshot='window.BMC_SNAPSHOT = {"generated_at":'"$generated_json"',"source":'"$source_json"',"issues_jsonl":'"$issues_jsonl_json"
if [ -n "$orchestrator_json" ]; then
  snapshot=$snapshot',"orchestrator":'"$orchestrator_json"
fi
snapshot=$snapshot'};'

meta_path=$(dirname "$out_path")/orchestration.meta.json
output_text=$snapshot
if [ -f "$meta_path" ]; then
  meta_text=$(read_raw_file "$meta_path" | json_escape)
  output_text=$output_text"
window.BMC_META_JSON = $meta_text;"
fi

# TOCTOU guard: re-verify no symlink appeared since the up-front check, then
# create with noclobber (O_EXCL semantics) so a pre-planted file/symlink at the
# randomized temp path makes the write fail instead of following it.
ensure_no_symlink_chain "$temp_path"
if [ -e "$temp_path" ]; then
  printf '%s\n' "error: temp path already exists: $temp_path" >&2
  exit 1
fi
(
  set -C
  printf '%s' "$output_text" > "$temp_path"
) || {
  rm -f -- "$temp_path"
  exit 1
}
mv -f -- "$temp_path" "$out_path"
