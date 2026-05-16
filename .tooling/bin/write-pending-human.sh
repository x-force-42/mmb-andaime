#!/usr/bin/env bash
# write-pending-human.sh — cria entrada em state/pending-human/.
#
# Usado pelo worker-master pra escalar mensagens não-rotineiras pro
# Mestre interativo. Cada entrada vira um arquivo independente em
# state/pending-human/ — sem flock, sem corrupção (filesystem isola
# arquivos distintos). Hook on-prompt-submit lê o dir, prepende ao
# input do Rick, e move pra .processed/.
#
# Uso:
#   echo "body markdown" | write-pending-human.sh \
#     --from <core|cockpit|aquarium|logger> \
#     --type <status|question|error|answer> \
#     --subject <slug> \
#     --thread <slug> \
#     [--priority <normal|high|critical>] \
#     [--source-msg <basename>] \
#     [--no-tmux]                    # skip atualização do indicator
#
# Stdin: body markdown (será preservado depois do frontmatter)
# Stdout: caminho absoluto do arquivo criado (1 linha)
# Stderr: erros de validação
# Exit codes: 0 ok | 1 arg inválido | 2 escrita falhou

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$TOOLING_DIR/config.sh" ] && source "$TOOLING_DIR/config.sh" 2>/dev/null || true

STATE_DIR="${MMB_STATE_DIR:-$TOOLING_DIR/state}"
PENDING_DIR="${MMB_PENDING_HUMAN_DIR:-$STATE_DIR/pending-human}"

FROM=""
TYPE=""
SUBJECT=""
THREAD=""
PRIORITY="normal"
SOURCE_MSG=""
NO_TMUX=0

usage() {
  cat >&2 <<EOF
Uso: $0 --from X --type Y --subject Z --thread T [--priority P] [--source-msg M] [--no-tmux]
  body via stdin.
  --priority: normal (default) | high | critical
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)       FROM="$2"; shift 2 ;;
    --type)       TYPE="$2"; shift 2 ;;
    --subject)    SUBJECT="$2"; shift 2 ;;
    --thread)     THREAD="$2"; shift 2 ;;
    --priority)   PRIORITY="$2"; shift 2 ;;
    --source-msg) SOURCE_MSG="$2"; shift 2 ;;
    --no-tmux)    NO_TMUX=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERRO: arg desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

# Validações
missing=()
for v in FROM TYPE SUBJECT THREAD; do
  [ -z "${!v}" ] && missing+=("--${v,,}")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "ERRO: args obrigatórios ausentes: ${missing[*]}" >&2
  usage
  exit 1
fi

case "$FROM" in
  core|cockpit|aquarium|logger|master) ;;
  *) echo "ERRO: --from inválido: '$FROM' (core|cockpit|aquarium|logger|master)" >&2; exit 1 ;;
esac

case "$TYPE" in
  status|question|error|answer|briefing) ;;
  *) echo "ERRO: --type inválido: '$TYPE' (status|question|error|answer|briefing)" >&2; exit 1 ;;
esac

case "$PRIORITY" in
  normal|high|critical) ;;
  *) echo "ERRO: --priority inválido: '$PRIORITY' (normal|high|critical)" >&2; exit 1 ;;
esac

# Sanitiza subject pra nome de arquivo (kebab-case, sem caracteres
# problemáticos pra filesystem).
SUBJECT_SAFE=$(echo "$SUBJECT" | tr -c 'a-zA-Z0-9_-' '_' | sed 's/__*/_/g; s/^_//; s/_$//')
[ -z "$SUBJECT_SAFE" ] && SUBJECT_SAFE="unnamed"

# Timestamp com precisão de nanossegundos pra evitar colisão entre
# workers concorrentes. ISO 8601 com `-` em vez de `:` pra ser
# filesystem-friendly.
TS_FILE=$(date -u +%Y-%m-%dT%H-%M-%S-%9NZ)
TS_FRONT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$PENDING_DIR"
FILE="$PENDING_DIR/${TS_FILE}_${FROM}_${TYPE}_${SUBJECT_SAFE}.md"

# Sob o improvável colision na mesma nanossegundo, adiciona sufixo
# random e re-tenta uma vez. Bash redirect `>` overwrites por padrão;
# `set -C` (noclobber) faz `>` falhar se arquivo já existe.
if (set -C; : > "$FILE") 2>/dev/null; then
  : # ok, arquivo criado
else
  RAND=$(printf '%04x' $((RANDOM % 65536)))
  FILE="$PENDING_DIR/${TS_FILE}-${RAND}_${FROM}_${TYPE}_${SUBJECT_SAFE}.md"
  (set -C; : > "$FILE") 2>/dev/null || {
    echo "ERRO: falha ao criar $FILE (colisão dupla)" >&2
    exit 2
  }
fi

# Lê body do stdin (vazio é OK — frontmatter sozinho serve).
BODY=$(cat)

# Escreve conteúdo.
{
  echo "---"
  echo "created: $TS_FRONT"
  echo "from: $FROM"
  echo "type: $TYPE"
  echo "subject: $SUBJECT"
  echo "thread: $THREAD"
  echo "priority: $PRIORITY"
  [ -n "$SOURCE_MSG" ] && echo "source-msg: $SOURCE_MSG"
  echo "---"
  echo ""
  printf '%s' "$BODY"
  # Garante newline final
  [ -n "$BODY" ] && [ "${BODY: -1}" != $'\n' ] && echo ""
} > "$FILE"

# Atualiza indicador no tmux (status-bar da tab master fica visível).
# No-op se MMB_TMUX_SESSION vazio ou tmux não disponível.
if [ "$NO_TMUX" -eq 0 ] && command -v tmux >/dev/null 2>&1; then
  SESSION="${MMB_TMUX_SESSION:-}"
  if [ -n "$SESSION" ] && tmux has-session -t "$SESSION" 2>/dev/null; then
    # Se tab master não existe na sessão, no-op.
    if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "master"; then
      tmux set-window-option -t "${SESSION}:master" window-status-style "bg=red,fg=white" 2>/dev/null || true
      tmux set-window-option -t "${SESSION}:master" window-status-current-style "bg=red,fg=white" 2>/dev/null || true
    fi
  fi
fi

# Saída: caminho absoluto pra o caller usar.
echo "$FILE"
