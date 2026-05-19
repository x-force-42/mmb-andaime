#!/usr/bin/env bash
# Envia mensagem entre agentes do MMB via mailbox FS.
#
# Uso:
#   msg.sh [--allow-offline] <to> <type> <subject-slug> <body-file> [thread]
#
#   <to>             master | core | cockpit | aquarium | logger
#   <type>           briefing | question | answer | status | error
#   <subject-slug>   kebab-case curto (vira parte do nome do arquivo)
#   <body-file>      caminho pra arquivo com o corpo da mensagem
#                    (use "-" pra ler de stdin)
#   [thread]         opcional — slug do épico/conversa pra correlação
#
# Flags:
#   --allow-offline  grava mesmo se commd não estiver rodando
#                    (default: falha com exit 12 — evita mensagem
#                    fantasma). Também via MMB_ALLOW_OFFLINE_ENQUEUE=1.
#
# Comportamento:
#   1. Verifica que commd está vivo (ou --allow-offline).
#   2. Lê o corpo da mensagem.
#   3. Cria arquivo em .tooling/inbox/<to>/<timestamp>_<from>_<type>_<subject>.md
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
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"
mmb_targets_load || {
  echo "ERRO: registry de targets inválido. Abortando msg.sh." >&2
  exit 2
}
_MMB_DESTS_PADDED=" $(mmb_dests_list) "

# Parsing de flags: --allow-offline em qualquer posição é extraído;
# o restante vira positional. Env MMB_ALLOW_OFFLINE_ENQUEUE=1 também
# liga o modo.
ALLOW_OFFLINE="${MMB_ALLOW_OFFLINE_ENQUEUE:-0}"
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --allow-offline) ALLOW_OFFLINE=1 ;;
    *)               POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

TO="${1:-}"
TYPE="${2:-}"
SUBJECT="${3:-}"
BODY_FILE="${4:-}"
THREAD="${5:-}"

if [ -z "$TO" ] || [ -z "$TYPE" ] || [ -z "$SUBJECT" ] || [ -z "$BODY_FILE" ]; then
  cat >&2 <<EOF
Uso: $0 [--allow-offline] <to> <type> <subject-slug> <body-file> [thread]

  to             : master | core | cockpit | aquarium | logger
  type           : briefing | question | answer | status | error
  subject        : kebab-case curto
  body           : caminho do arquivo (- pra stdin)
  thread         : opcional, correlaciona mensagens
  --allow-offline: grava mesmo sem commd vivo (default: exit 12).
                   também via MMB_ALLOW_OFFLINE_ENQUEUE=1.

Exemplo:
  msg.sh core briefing cleanup-scripts .tooling/intents/2026-05-14-cleanup/briefing-core.md cleanup-scripts
EOF
  exit 1
fi

# Validação dura de campos
case "$_MMB_DESTS_PADDED" in
  *" $TO "*) ;;
  *) echo "ERRO: 'to' inválido: $TO (válidos:$_MMB_DESTS_PADDED)" >&2; exit 2;;
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

# Commd-alive check ANTES da gravação. Mensagem fantasma (gravada
# sem ninguém pra processar) levava a dispatch atrasado/perdido na
# v0.3 — bloquear na origem evita a classe inteira.
COMMD_PID_FILE="$TOOLING_DIR/state/commd.pid"
commd_alive=0
if [ -f "$COMMD_PID_FILE" ]; then
  COMMD_PID=$(cat "$COMMD_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$COMMD_PID" ] && kill -0 "$COMMD_PID" 2>/dev/null; then
    commd_alive=1
  fi
fi
if [ "$commd_alive" -eq 0 ]; then
  if [ "$ALLOW_OFFLINE" = "1" ]; then
    echo "AVISO: commd não está rodando — gravando mensagem mesmo assim (--allow-offline)." >&2
    echo "       Mensagem fica pendente até o daemon subir e drainar." >&2
  else
    cat >&2 <<EOF
ERRO: commd não está rodando — mensagem NÃO gravada (evita enqueue fantasma).

       Suba o daemon antes:
         $TOOLING_DIR/bin/commd.sh fg

       Ou force enqueue offline (raro — só se você for subir commd em seguida):
         msg.sh --allow-offline ...
         (ou MMB_ALLOW_OFFLINE_ENQUEUE=1 msg.sh ...)
EOF
    exit 12
  fi
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
