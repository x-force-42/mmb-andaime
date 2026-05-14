#!/usr/bin/env bash
# Diário de bordo compartilhado do andaime MMB (v0.2).
#
# Append-only de eventos estruturados em .tooling/logs/journal.jsonl.
# Filosofia: erro estruturado vai aqui, não em prosa solta. Master
# agrega ao fechar épico via review-cycle.sh.
#
# Uso:
#   log.sh <sev> <event> "<msg>" [--epic X] [--task Y] [--resolves <id>]
#
#   sev:        warn | error | critical
#   event:      kebab-case curto (ex: jq-missing, hook-failed)
#   msg:        descrição livre, 1-2 linhas
#   --epic:     slug do épico em curso (default: env MMB_EPIC ou "-")
#   --task:     task-id (default: env MMB_TASK ou "-")
#   --resolves: id de evento anterior que este resolve
#
# Saída em stdout: o `id` gerado (formato `e-YYYY-MM-DD-NNN`).
#
# Schema do journal (v1):
#   {"ts":"<ISO8601>","agent":"<id>","epic":"<slug>","task":"<id>",
#    "sev":"<warn|error|critical>","event":"<kebab>","msg":"<str>",
#    "id":"<e-...>", "resolves":"<e-...>"}

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

LOGS_DIR="$TOOLING_DIR/logs"
JOURNAL="$LOGS_DIR/journal.jsonl"
LOCK="$LOGS_DIR/.journal.lock"

mkdir -p "$LOGS_DIR"
[ -f "$JOURNAL" ] || : > "$JOURNAL"

# ── Args ──────────────────────────────────────────────────────────

SEV="${1:-}"
EVENT="${2:-}"
MSG="${3:-}"
shift 3 2>/dev/null || true

EPIC="${MMB_EPIC:--}"
TASK="${MMB_TASK:--}"
RESOLVES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)     EPIC="$2"; shift 2 ;;
    --task)     TASK="$2"; shift 2 ;;
    --resolves) RESOLVES="$2"; shift 2 ;;
    *)
      echo "log.sh: argumento desconhecido '$1'" >&2
      exit 2
      ;;
  esac
done

if [ -z "$SEV" ] || [ -z "$EVENT" ] || [ -z "$MSG" ]; then
  cat >&2 <<EOF
Uso: $0 <sev> <event> "<msg>" [--epic X] [--task Y] [--resolves <id>]

  sev:    warn | error | critical
  event:  kebab-case (ex: jq-missing)
  msg:    descrição (1-2 linhas)
EOF
  exit 2
fi

case "$SEV" in
  warn|error|critical) ;;
  *) echo "log.sh: sev inválido '$SEV' (use warn|error|critical)" >&2; exit 2 ;;
esac

if ! [[ "$EVENT" =~ ^[a-z0-9][a-z0-9-]{0,60}[a-z0-9]$ ]]; then
  echo "log.sh: event inválido '$EVENT' (use kebab-case, 2-62 chars)" >&2
  exit 2
fi

# ── Agent ID ──────────────────────────────────────────────────────

AGENT="${MMB_AGENT_ID:-unknown}"

# ── ID gerado: e-YYYY-MM-DD-NNN ───────────────────────────────────

TODAY=$(date -u +%Y-%m-%d)
# Conta eventos do dia já no journal pra gerar o próximo ordinal.
# Subshell `(grep ... || true)` neutraliza o exit 1 de "no match"
# antes que `set -o pipefail` mate o pipeline.
COUNT=$( (grep "\"id\":\"e-$TODAY-" "$JOURNAL" 2>/dev/null || true) | wc -l | tr -d ' ')
ORDINAL=$(printf '%03d' "$((COUNT + 1))")
ID="e-$TODAY-$ORDINAL"

# ── Escape de string pra JSON ─────────────────────────────────────

_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Monta JSON
JSON=$(printf '{"ts":"%s","agent":"%s","epic":"%s","task":"%s","sev":"%s","event":"%s","msg":"%s","id":"%s"' \
  "$TS" \
  "$(_json_str "$AGENT")" \
  "$(_json_str "$EPIC")" \
  "$(_json_str "$TASK")" \
  "$SEV" \
  "$EVENT" \
  "$(_json_str "$MSG")" \
  "$ID")
[ -n "$RESOLVES" ] && JSON+=$(printf ',"resolves":"%s"' "$(_json_str "$RESOLVES")")
JSON+='}'

# Append com flock
(
  flock --timeout 5 9 || {
    echo "log.sh: timeout adquirindo lock em $LOCK" >&2
    exit 11
  }
  printf '%s\n' "$JSON" >> "$JOURNAL"
) 9>>"$LOCK"

# Emite o ID gerado (útil pra chamar --resolves depois)
printf '%s\n' "$ID"
