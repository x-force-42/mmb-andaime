#!/usr/bin/env bash
# Abre PR no remoto (chamado pelo Agente Atômico ao terminar).
#
# Uso (rode de DENTRO da worktree):
#   .tooling/bin/open-pr.sh [--draft]
#
# Comportamento:
#   1. Valida invariantes (branch task/, working tree limpa, ao
#      menos 1 commit à frente do default branch).
#   2. git push origin HEAD.
#   3. gh pr create com:
#      - título derivado do último commit (Conventional Commits)
#      - body do template pr-body.md preenchido
#      - Closes #<sub-issue> se encontrar referência no body dos
#        commits ou no env GH_SUBISSUE.
#   4. Comenta na sub-issue avisando do PR.

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

DRAFT_FLAG=""
if [ "${1:-}" = "--draft" ]; then
  DRAFT_FLAG="--draft"
fi

TOPLEVEL=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
WORKTREE_NAME=$(basename "$TOPLEVEL")

# Invariantes
case "$BRANCH" in
  task/*) ;;
  *)
    echo "ERRO: branch atual ($BRANCH) não é task/<id>-<slug>."
    exit 1
    ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  echo "ERRO: working tree suja. Commit ou stash antes de abrir PR."
  git status --short
  exit 1
fi

DEFAULT_BRANCH=$(mmb_default_branch)
echo "→ default branch: $DEFAULT_BRANCH"

AHEAD=$(git rev-list --count "$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo 0)
if [ "$AHEAD" -lt 1 ]; then
  echo "ERRO: branch sem commits à frente de $DEFAULT_BRANCH. Nada pra PR."
  exit 1
fi

# Push
echo "→ git push origin $BRANCH..."
git push -u origin "$BRANCH"

# Descobre repo no GitHub
REMOTE_URL=$(git config --get remote.origin.url)
# git@github.com:x-force-42/mmb-core.git → x-force-42/mmb-core
GH_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+)\.git$|\1|')

# Título do PR: último commit não-merge na branch
PR_TITLE=$(git log "$DEFAULT_BRANCH..HEAD" --no-merges --pretty=format:'%s' | tail -1)
if [ -z "$PR_TITLE" ]; then
  PR_TITLE=$(git log -1 --pretty=format:'%s')
fi

# Body
TMP_BODY=$(mktemp)
COMMITS_LIST=$(git log "$DEFAULT_BRANCH..HEAD" --no-merges --pretty=format:'- %s')

# Tenta descobrir sub-issue
SUBISSUE="${GH_SUBISSUE:-}"
if [ -z "$SUBISSUE" ]; then
  SUBISSUE=$(git log "$DEFAULT_BRANCH..HEAD" --no-merges --pretty=format:'%B' \
    | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)
fi

{
  echo "## O que mudou"
  echo
  echo "$COMMITS_LIST"
  echo
  echo "## Origem"
  echo
  if [ -n "$SUBISSUE" ]; then
    echo "Closes #$SUBISSUE"
  else
    echo "_Sub-issue não detectada automaticamente. Adicione \`Closes #N\` se aplicável._"
  fi
  echo
  echo "---"
  echo "🤖 PR aberto via \`.tooling/bin/open-pr.sh\` pelo Agente Atômico (worktree: \`$WORKTREE_NAME\`)."
} > "$TMP_BODY"

echo "→ gh pr create (base: $DEFAULT_BRANCH)..."
PR_URL=$(gh pr create \
  --repo "$GH_REPO" \
  --title "$PR_TITLE" \
  --body-file "$TMP_BODY" \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH" \
  $DRAFT_FLAG)

rm -f "$TMP_BODY"

echo "✓ PR aberto: $PR_URL"

# Extrai número do PR da URL (https://github.com/org/repo/pull/N)
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || true)

# Notifica master via inbox — alimenta o logger (R3: pr-aberto → ciclo pr_aberto).
# Usa --allow-offline porque open-pr.sh roda no pane do atômico e o commd
# pode não estar visível neste contexto; a mensagem fica pendente e é
# drenada quando o daemon subir.
if [ -n "$PR_NUMBER" ] && [ -n "${MMB_GH_OWNER:-}" ]; then
  THREAD="${EPIC_SLUG:-${MMB_AGENT_ID:-}}"
  if [ -n "$THREAD" ]; then
    printf "PR aberto: %s\n" "$PR_URL" \
      | MMB_TAB="${MMB_TAB:-atomic}" MMB_ALLOW_OFFLINE_ENQUEUE=1 \
        "$TOOLING_DIR/bin/msg.sh" \
          master status "pr-aberto-${PR_NUMBER}" - "$THREAD" \
          2>/dev/null \
      && echo "✓ Status pr-aberto-${PR_NUMBER} enviado ao master" \
      || echo "  (msg.sh falhou; logger não vai registrar pr_aberto)"
  fi
fi

# Comenta na sub-issue se conhecida
if [ -n "$SUBISSUE" ]; then
  gh issue comment "$SUBISSUE" \
    --repo "$GH_REPO" \
    --body "PR aberto: $PR_URL" 2>/dev/null \
    && echo "✓ Comentário postado na sub-issue #$SUBISSUE" \
    || echo "  (falhou comentar na sub-issue; siga sem isso)"
fi

echo
echo "Agente Atômico terminou."

# Deregistra no agent registry (v0.1). MMB_AGENT_ID é setado pelo
# spawn-atomic.sh; se ausente, segue sem deregister.
if [ -n "${MMB_AGENT_ID:-}" ]; then
  "$TOOLING_DIR/bin/agents.sh" deregister "$MMB_AGENT_ID" "pr-opened" || true
fi

# Auto-fechamento do pane: usa MMB_PANE_ID (injetado pelo spawn-atomic.sh)
# em vez de `tmux display-message`, que retorna o pane FOCADO pelo client
# e pode matar a sessão do master se o usuário estiver com ela em foco.
if [ -n "${TMUX:-}" ]; then
  PANE_ID="${MMB_PANE_ID:-}"
  if [ -n "$PANE_ID" ]; then
    echo "Pane $PANE_ID vai fechar em 8s (Ctrl-C pra cancelar)."
    ( sleep 8 && tmux kill-pane -t "$PANE_ID" ) &
  fi
fi
