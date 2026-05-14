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

# Auto-fechamento do pane: se estamos num pane tmux, mata em 8s
# pra dar tempo de Rick ver a URL do PR. Roda em background pra
# não bloquear o retorno do script.
if [ -n "${TMUX:-}" ]; then
  PANE_ID=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
  if [ -n "$PANE_ID" ]; then
    echo "Pane $PANE_ID vai fechar em 8s (Ctrl-C pra cancelar)."
    ( sleep 8 && tmux kill-pane -t "$PANE_ID" ) &
  fi
fi
