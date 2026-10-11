#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/payload-history.sh [options]

Summarize and inspect commits that modify the scripting-addition payload / patterns.

Options:
  --since <date>     Forwarded to `git log --since` (e.g. "2025-01-01")
  --until <date>     Forwarded to `git log --until`
  --grep <regex>     Filter commit subjects (default targets payload/OSAX/pattern/Dock/OS names)
  --all              Disable subject filtering
  --show <rev>       Show the patch for a specific revision (scoped to relevant files)
  --files <paths>    Comma-separated override file list
  -h, --help         Show this help

Examples:
  bash scripts/payload-history.sh
  bash scripts/payload-history.sh --grep 'Tahoe|26\\.'
  bash scripts/payload-history.sh --show af508b9
EOF
}

since=""
until=""
grep_re='(payload|scripting[- ]addition|osax|pattern|offset|Dock|Tahoe|Sequoia|Sonoma|Ventura|Monterey|Big Sur)'
filter=1
show_rev=""

default_files=(
  src/osax/payload.m
  src/osax/arm64_payload.m
  src/osax/x64_payload.m
  src/osax/loader.m
  src/sa.m
  CHANGELOG.md
)
files=("${default_files[@]}")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) since="${2:-}"; shift 2 ;;
    --until) until="${2:-}"; shift 2 ;;
    --grep) grep_re="${2:-}"; shift 2 ;;
    --all) filter=0; shift ;;
    --show) show_rev="${2:-}"; shift 2 ;;
    --files)
      IFS=',' read -r -a files <<< "${2:-}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

git_args=(--date=short --pretty=format:'%h %ad %s')
[[ -n "$since" ]] && git_args+=(--since="$since")
[[ -n "$until" ]] && git_args+=(--until="$until")

if [[ -n "$show_rev" ]]; then
  exec git show "$show_rev" --patch -- "${files[@]}"
fi

if [[ "$filter" -eq 1 ]]; then
  git log "${git_args[@]}" -- "${files[@]}" | grep -E -i -- "$grep_re" || true
else
  git log "${git_args[@]}" -- "${files[@]}"
fi

