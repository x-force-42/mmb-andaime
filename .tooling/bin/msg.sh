#!/usr/bin/env bash
# Envia mensagem entre agentes do MMB via mailbox FS.
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
#
# O wakeup do destinatário é responsabilidade do commd.sh (daemon
# central que faz watch dos inboxes via inotifywait e dispatcha
# workers stateless). msg.sh NÃO sinaliza nada via tmux — apenas
# persiste o arquivo. Isso elimina a classe de bugs de "ping
# perdido" que afetou v0.1.
#
# Auto-detecção do 'from':
#   - Se env MMB_TAB está setado, usa esse valor.
#   - Senão, infere pela tab tmux atual.
#   - Fallback: 'unknown'.

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
echo "  Destinatário será acordado pelo commd.sh (daemon)."

# Sanity check: avisa se commd não está rodando (sem bloquear).
# commd.sh grava seu PID em state/commd.pid quando inicia.
COMMD_PID_FILE="$TOOLING_DIR/state/commd.pid"
if [ -f "$COMMD_PID_FILE" ]; then
  COMMD_PID=$(cat "$COMMD_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$COMMD_PID" ] && ! kill -0 "$COMMD_PID" 2>/dev/null; then
    echo "AVISO: commd.pid existe mas processo $COMMD_PID está morto." >&2
    echo "       Mensagem foi gravada mas ninguém vai processá-la até subir o daemon." >&2
    echo "       Suba com: /MMB/.tooling/bin/commd.sh start" >&2
  fi
else
  echo "AVISO: commd não parece estar rodando (state/commd.pid ausente)." >&2
  echo "       Suba com: /MMB/.tooling/bin/commd.sh start" >&2
fi
