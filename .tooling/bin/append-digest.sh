#!/usr/bin/env bash
# append-digest.sh — append entry no digest diário do worker-master.
#
# Usado pelo worker-master pra registrar TODA mensagem processada
# (rotina e escalada). Cria state/digest-<YYYY-MM-DD>.md (UTC) se
# não existir, com header. Adquire flock antes do append — workers
# concorrentes não intercalam linhas.
#
# Uso:
#   append-digest.sh \
#     --from <core|cockpit|aquarium|logger> \
#     --type <status|question|error|...> \
#     --subject <slug> \
#     --thread <slug> \
#     --glyph <✓|⚠> \
#     --action "descrição curta do que foi feito"
#
# Stdout: nenhuma saída no caminho feliz.
# Stderr: erros de validação.
# Exit codes: 0 ok | 1 arg inválido | 2 flock timeout / write falhou

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$TOOLING_DIR/config.sh" ] && source "$TOOLING_DIR/config.sh" 2>/dev/null || true

STATE_DIR="${MMB_STATE_DIR:-$TOOLING_DIR/state}"
mkdir -p "$STATE_DIR"

FROM=""
TYPE=""
SUBJECT=""
THREAD=""
GLYPH=""
ACTION=""

usage() {
  cat >&2 <<EOF
Uso: $0 --from X --type Y --subject Z --thread T --glyph G --action "descrição"
  glyph: ✓ (rotina) ou ⚠ (escalada)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)    FROM="$2";    shift 2 ;;
    --type)    TYPE="$2";    shift 2 ;;
    --subject) SUBJECT="$2"; shift 2 ;;
    --thread)  THREAD="$2";  shift 2 ;;
    --glyph)   GLYPH="$2";   shift 2 ;;
    --action)  ACTION="$2";  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "ERRO: arg desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

# Obrigatórios
missing=()
for v in FROM TYPE SUBJECT THREAD GLYPH ACTION; do
  [ -z "${!v}" ] && missing+=("--${v,,}")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "ERRO: args obrigatórios ausentes: ${missing[*]}" >&2
  usage
  exit 1
fi

# Glyph: aceita os dois símbolos canônicos + "+" (alternativa ASCII se
# encoding falhar em algum ambiente).
case "$GLYPH" in
  "✓"|"⚠"|"+"|"!") ;;
  *) echo "ERRO: --glyph inválido: '$GLYPH' (use ✓ ou ⚠)" >&2; exit 1 ;;
esac

# Caminho do digest do dia (UTC pra consistência com briefings/logs).
TODAY=$(date -u +%Y-%m-%d)
DIGEST="$STATE_DIR/digest-${TODAY}.md"
DIGEST_LOCK="$STATE_DIR/.digest.lock"

TIME=$(date -u +%H:%M:%S)

# Append com flock. Timeout 5s — se commd estiver superloaded e o lock
# ficar mais que isso, melhor falhar e registrar do que travar o worker.
(
  flock --timeout 5 9 || {
    echo "ERRO: flock timeout em $DIGEST_LOCK" >&2
    exit 2
  }

  # Cria header se arquivo está vazio/não-existe.
  if [ ! -s "$DIGEST" ]; then
    {
      echo "# Digest — $TODAY"
      echo ""
    } >> "$DIGEST"
  fi

  {
    echo "## ${TIME} · ${FROM} · ${TYPE}:${SUBJECT} · thread=${THREAD}"
    echo "${GLYPH} ${ACTION}"
    echo ""
  } >> "$DIGEST"
) 9>>"$DIGEST_LOCK"
