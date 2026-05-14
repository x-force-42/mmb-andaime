#!/usr/bin/env bash
# Envia mensagem entre sessões Claude via mailbox FS + ping tmux.
#
# Uso:
#   msg.sh <to> <type> <subject-slug> <body-file> [thread]
#
#   <to>             master | core | cockpit | aquarium
#   <type>           briefing | question | answer | status | error
#   <subject-slug>   kebab-case curto (vira parte do nome do arquivo)
#   <body-file>      caminho pra arquivo com o corpo da mensagem
#                    (use "-" pra ler de stdin)
#   [thread]         opcional — slug do épico/conversa pra correlação
#
# Comportamento:
#   1. Lê o corpo da mensagem.
#   2. Cria arquivo em .tooling/inbox/<to>/<timestamp>_<from>_<type>_<subject>.md
#      com frontmatter (from/to/type/subject/thread/created).
#   3. Envia ping curto via tmux send-keys pra tab do destinatário:
#      "📨 [from→to] <type>: <subject>"
#      "   → <path-do-arquivo>"
#
# Auto-detecção do 'from':
#   - Se env MMB_TAB está setado, usa esse valor.
#   - Senão, infere pela tab tmux atual.
#
# Convenções:
#   - Nome de arquivo: ordenável por timestamp natural.
#   - Ping sempre tem prefixo 📨 — profiles instruem agentes a
#     reconhecer esse marcador.

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

TO="${1:-}"
TYPE="${2:-}"
SUBJECT="${3:-}"
BODY_FILE="${4:-}"
THREAD="${5:-}"

if [ -z "$TO" ] || [ -z "$TYPE" ] || [ -z "$SUBJECT" ] || [ -z "$BODY_FILE" ]; then
  cat >&2 <<EOF
Uso: $0 <to> <type> <subject-slug> <body-file> [thread]

  to       : master | core | cockpit | aquarium
  type     : briefing | question | answer | status | error
  subject  : kebab-case curto
  body     : caminho do arquivo (- pra stdin)
  thread   : opcional, correlaciona mensagens

Exemplo:
  msg.sh core briefing cleanup-scripts .tooling/intents/2026-05-14-cleanup/briefing-core.md cleanup-scripts
EOF
  exit 1
fi

# Validação dura de campos
case "$TO" in
  master|core|cockpit|aquarium) ;;
  *) echo "ERRO: 'to' inválido: $TO (use master|core|cockpit|aquarium)" >&2; exit 2;;
esac

case "$TYPE" in
  briefing|question|answer|status|error) ;;
  *) echo "ERRO: 'type' inválido: $TYPE (use briefing|question|answer|status|error)" >&2; exit 2;;
esac

# subject deve ser kebab-case (a-z, 0-9, hífens; tamanho razoável)
if ! [[ "$SUBJECT" =~ ^[a-z0-9][a-z0-9-]{0,60}[a-z0-9]$ ]]; then
  echo "ERRO: 'subject' inválido: '$SUBJECT'" >&2
  echo "       Use kebab-case (a-z, 0-9, hífens), 2-62 chars." >&2
  echo "       Bom: 'pr-aberto-3', 'cleanup-scripts', 'rename-field'" >&2
  echo "       Ruim: 'PR aberto!', 'pr_aberto', 'x', 'a-'" >&2
  exit 2
fi

# Detecta 'from'
FROM="${MMB_TAB:-}"
if [ -z "$FROM" ] && [ -n "${TMUX:-}" ]; then
  WINDOW_NAME=$(tmux display-message -p '#{window_name}' 2>/dev/null || echo "")
  case "$WINDOW_NAME" in
    master) FROM="master";;
    core)   FROM="core";;
    cockpit) FROM="cockpit";;
    aquarium) FROM="aquarium";;
    *) FROM="unknown";;
  esac
fi
[ -z "$FROM" ] && FROM="unknown"

# Guardrail: from != to (auto-mensagem)
if [ "$FROM" = "$TO" ]; then
  echo "ERRO: from == to ('$FROM'). Sessão não pode mandar mensagem pra si mesma." >&2
  echo "       Verifique MMB_TAB ou se a window tmux está nomeada corretamente." >&2
  exit 2
fi

# Aviso (não bloqueante): briefings sem thread perdem rastreio de épico
if [ "$TYPE" = "briefing" ] && [ -z "$THREAD" ]; then
  echo "AVISO: briefing sem 'thread' — agregação por épico vai ficar manual." >&2
fi

# Lê body
if [ "$BODY_FILE" = "-" ]; then
  BODY_CONTENT=$(cat)
else
  if [ ! -f "$BODY_FILE" ]; then
    echo "ERRO: body-file não existe: $BODY_FILE" >&2
    exit 2
  fi
  BODY_CONTENT=$(cat "$BODY_FILE")
fi

# Body não vazio
if [ -z "$(echo "$BODY_CONTENT" | tr -d '[:space:]')" ]; then
  echo "ERRO: body está vazio ou só whitespace. Mensagem sem conteúdo é inútil." >&2
  exit 2
fi

# Monta arquivo
INBOX_DIR="$TOOLING_DIR/inbox/$TO"
mkdir -p "$INBOX_DIR"

TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
FILENAME="${TS}_${FROM}_${TYPE}_${SUBJECT}.md"
TARGET="$INBOX_DIR/$FILENAME"

# Lock por inbox de destino. Serializa writes concorrentes (múltiplos
# remetentes paralelos) sem bloquear leitores. Lock file começa com
# "." pra ficar invisível ao polling (que ignora arquivos ocultos).
LOCK="$INBOX_DIR/.lock"
(
  flock --timeout 5 9 || {
    echo "ERRO: timeout adquirindo lock em $LOCK" >&2
    echo "       Algum outro msg.sh travou? Verifique processos." >&2
    exit 11
  }
  {
    echo "---"
    echo "from: $FROM"
    echo "to: $TO"
    echo "type: $TYPE"
    echo "subject: $SUBJECT"
    [ -n "$THREAD" ] && echo "thread: $THREAD"
    echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
    echo
    echo "$BODY_CONTENT"
  } > "$TARGET"
) 9>>"$LOCK"

echo "✓ Mensagem gravada: $TARGET"

# Envia ping via tmux se possível
if [ -n "${TMUX:-}" ] && tmux has-session -t "$MMB_TMUX_SESSION" 2>/dev/null; then
  # Sempre envia pro window 0 do destinatário (orquestrador, não atômico)
  TARGET_TAB="$TO"

  # Ping curto, ASCII-safe (nada que precise quoting)
  PING_LINE_1="MSG [$FROM->$TO] $TYPE: $SUBJECT"
  PING_LINE_2="  inbox: $TARGET"

  # Encontra o índice da window por nome
  WINDOW_IDX=$(tmux list-windows -t "$MMB_TMUX_SESSION" -F '#{window_index}:#{window_name}' \
    | grep ":$TARGET_TAB\$" | head -1 | cut -d: -f1 || true)

  if [ -n "$WINDOW_IDX" ]; then
    # Manda no pane 0 (orquestrador). Atômicos vivem em panes >0.
    tmux send-keys -t "$MMB_TMUX_SESSION:$WINDOW_IDX.0" "" C-m
    tmux send-keys -t "$MMB_TMUX_SESSION:$WINDOW_IDX.0" "$PING_LINE_1" C-m
    tmux send-keys -t "$MMB_TMUX_SESSION:$WINDOW_IDX.0" "$PING_LINE_2" C-m
    echo "✓ Ping enviado pra mmb:$WINDOW_IDX.0 (window '$TARGET_TAB')"
  else
    echo "AVISO: window '$TARGET_TAB' não encontrada na sessão '$MMB_TMUX_SESSION'."
    echo "       Mensagem foi gravada mas destinatário não foi notificado via ping."
  fi
else
  echo "AVISO: tmux indisponível. Mensagem gravada, sem ping. Destinatário leria via:"
  echo "       ls $INBOX_DIR/"
fi
