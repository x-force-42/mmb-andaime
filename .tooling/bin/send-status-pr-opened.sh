#!/usr/bin/env bash
# send-status-pr-opened.sh — wrapper obrigatório pra orq local emitir
# `status: pr-aberto-N` com schema do contrato v0.4+ cumprido.
#
# Substitui chamada manual de `msg.sh master status pr-aberto-N ...`
# pelo orq local após detectar PR aberto pelo atômico. Validação
# fail-fast no próprio script torna o contrato impossível de
# descumprir — diferente do reforço imperativo no profile, que
# foi ignorado em produção 2x (B1 reincidente).
#
# Uso:
#   send-status-pr-opened.sh <repo-short> <pr-number> <issue-number> <thread>
#     [--suite-status <verde|vermelha|pulada|ausente>]
#
#   <repo-short>: <id> de target registrado (mmb_targets_list)
#   <pr-number>:  número do PR (positivo)
#   <issue-number>: número da sub-issue que o PR fecha
#   <thread>:     slug do épico
#   --suite-status: opcional. Default: auto-detectado do PR body
#                   (grep "## Suíte verde"). Se ausente, declara
#                   "ausente" honestamente.
#
# Output stdout: nada (no caminho feliz, mesma convenção do msg.sh).
# Output stderr: diagnósticos + ack.
# Exit codes:
#   0  status emitido com sucesso
#   1  uso / arg inválido
#   2  contrato do schema violado (suite_status inválido)
#   3  gh CLI / msg.sh falhou

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"
mmb_targets_load || {
  echo "ERRO: registry de targets inválido. Abortando send-status-pr-opened." >&2
  exit 2
}

VALID_REPOS=$(mmb_targets_list)
VALID_SUITE_STATUS="verde vermelha pulada ausente"

usage() {
  cat >&2 <<EOF
Uso: $0 <repo-short> <pr-number> <issue-number> <thread> [--suite-status <s>]

  <repo-short>:    $VALID_REPOS
  <pr-number>:     número do PR (positivo)
  <issue-number>:  número da sub-issue que o PR fecha
  <thread>:        slug do épico
  --suite-status:  $VALID_SUITE_STATUS (default: auto-detect do PR body)

Wrapper obrigatório pra status:pr-aberto-N (schema v0.4+, contrato
em .tooling/protocol.md). Substitui chamada manual de msg.sh.
EOF
}

REPO_SHORT=""
PR_NUMBER=""
ISSUE_NUMBER=""
THREAD=""
SUITE_STATUS_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --suite-status)
      SUITE_STATUS_OVERRIDE="${2:-}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "ERRO: flag desconhecida: $1" >&2; usage; exit 1 ;;
    *)
      if [ -z "$REPO_SHORT" ]; then REPO_SHORT="$1"
      elif [ -z "$PR_NUMBER" ]; then PR_NUMBER="$1"
      elif [ -z "$ISSUE_NUMBER" ]; then ISSUE_NUMBER="$1"
      elif [ -z "$THREAD" ]; then THREAD="$1"
      else echo "ERRO: arg posicional extra: $1" >&2; usage; exit 1
      fi
      shift
      ;;
  esac
done

# ── Validações fail-fast ─────────────────────────────────────────

if [ -z "$REPO_SHORT" ] || [ -z "$PR_NUMBER" ] || [ -z "$ISSUE_NUMBER" ] || [ -z "$THREAD" ]; then
  echo "ERRO: faltam args obrigatórios." >&2
  usage; exit 1
fi

case " $VALID_REPOS " in
  *" $REPO_SHORT "*) ;;
  *) echo "ERRO: repo-short inválido '$REPO_SHORT' (use: $VALID_REPOS)" >&2; exit 1 ;;
esac

if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERRO: pr-number deve ser inteiro positivo (encontrado: '$PR_NUMBER')" >&2
  exit 1
fi

if ! [[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERRO: issue-number deve ser inteiro positivo (encontrado: '$ISSUE_NUMBER')" >&2
  exit 1
fi

if [ -z "$THREAD" ]; then
  echo "ERRO: thread (slug do épico) é obrigatória." >&2
  exit 1
fi

# Suite status: se override, validar valor; senão, auto-detect do PR body.
if [ -n "$SUITE_STATUS_OVERRIDE" ]; then
  case " $VALID_SUITE_STATUS " in
    *" $SUITE_STATUS_OVERRIDE "*) SUITE_STATUS="$SUITE_STATUS_OVERRIDE" ;;
    *) echo "ERRO: --suite-status inválido '$SUITE_STATUS_OVERRIDE' (use: $VALID_SUITE_STATUS)" >&2; exit 2 ;;
  esac
else
  # Auto-detect: lê body do PR via gh CLI, grep "## Suíte verde".
  # Se gh falhar (rede, auth, etc), declara "ausente" honestamente —
  # nunca presume "verde".
  REPO_FULL="mmb-${REPO_SHORT}"
  PR_BODY=$(gh pr view "$PR_NUMBER" --repo "$MMB_GH_OWNER/$REPO_FULL" --json body -q .body 2>/dev/null || echo "")
  if [ -z "$PR_BODY" ]; then
    SUITE_STATUS="ausente"
    echo "AVISO: não consegui ler body do PR #$PR_NUMBER (gh falhou ou PR vazio); declarando suite_status=ausente" >&2
  elif echo "$PR_BODY" | grep -q "## Suíte verde"; then
    SUITE_STATUS="verde"
  else
    SUITE_STATUS="ausente"
    echo "AVISO: PR #$PR_NUMBER sem '## Suíte verde' no body; declarando suite_status=ausente" >&2
  fi
fi

# ── Monta body conforme schema v0.4+ ─────────────────────────────

REPO_FULL="mmb-${REPO_SHORT}"
PR_URL="https://github.com/${MMB_GH_OWNER}/${REPO_FULL}/pull/${PR_NUMBER}"

# Body com campos obrigatórios na ordem do protocol.md
BODY=$(cat <<EOF
pr_url: $PR_URL
pr_number: $PR_NUMBER
issue_number: $ISSUE_NUMBER
suite_status: $SUITE_STATUS

PR #$PR_NUMBER aberto em $REPO_FULL fechando issue #$ISSUE_NUMBER.
EOF
)

# ── Chama msg.sh ─────────────────────────────────────────────────

echo "→ Emitindo status:pr-aberto-$PR_NUMBER pro master" >&2
echo "  repo:         $REPO_SHORT" >&2
echo "  pr_url:       $PR_URL" >&2
echo "  issue:        #$ISSUE_NUMBER" >&2
echo "  suite_status: $SUITE_STATUS" >&2
echo "  thread:       $THREAD" >&2

# msg.sh aceita body via stdin com '-'. Override via env pra teste.
MSG_SH="${MMB_MSG_SH:-$TOOLING_DIR/bin/msg.sh}"
if ! printf '%s\n' "$BODY" | "$MSG_SH" master status "pr-aberto-${PR_NUMBER}" - "$THREAD"; then
  echo "ERRO: msg.sh falhou ao emitir status." >&2
  exit 3
fi

# Worker-master vai tratar: suite_status=verde → rotina ✓; outros → escalação ⚠ + pending-human.
case "$SUITE_STATUS" in
  verde) echo "✓ status emitido (suite verde — rotina pro digest)" >&2 ;;
  *)     echo "⚠ status emitido (suite_status=$SUITE_STATUS — worker-master vai escalar)" >&2 ;;
esac

exit 0
