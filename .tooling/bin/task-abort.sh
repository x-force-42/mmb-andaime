#!/usr/bin/env bash
# Aborta uma task em andamento (worktree existe, mas PR não foi
# mergeado nem aberto). Limpa worktree + branch SEM checar se
# está mergeado.
#
# Uso:
#   .tooling/bin/task-abort.sh <repo> <task-id>
#
# Casos típicos:
#   - Teste de fogo do método; quer descartar tudo.
#   - Atômico travou ou foi abortado manualmente.
#   - Direção mudou; retomar depois com nova worktree.
#
# Difere do task-end.sh: aquele EXIGE que a branch esteja mergeada
# em main/master. Este é destrutivo por design.

set -euo pipefail

REPO="${1:-}"
TASK_ID="${2:-}"

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"

if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
  echo "Uso: $0 <repo> <task-id>"
  echo
  echo "Aborta worktree e branch da task — destrutivo, NÃO checa merge."
  echo "Pra cleanup pós-merge, use task-end.sh."
  exit 1
fi

REPO_PATH="$MMB_ROOT/$REPO"
if [ ! -d "$REPO_PATH/.git" ]; then
  echo "ERRO: $REPO não é um repo git em $REPO_PATH."
  exit 1
fi

cd "$REPO_PATH"

# Acha o slug. Tenta primeiro docs/tasks/, fallback pra branch existente.
TASK_FILE=$(ls "docs/tasks/${TASK_ID}-"*.md 2>/dev/null | head -1 || true)
if [ -n "$TASK_FILE" ]; then
  SLUG=$(basename "$TASK_FILE" .md)
else
  # Procura branch task/<task-id>-*
  BRANCH_GUESS=$(git branch --list "task/${TASK_ID}-*" 2>/dev/null | head -1 | sed 's|^[* +]*||' || true)
  if [ -n "$BRANCH_GUESS" ]; then
    SLUG="${BRANCH_GUESS#task/}"
  else
    echo "ERRO: não achei task '$TASK_ID' nem como brief nem como branch."
    echo "Branches task/* existentes:"
    git branch --list "task/*" | sed 's/^/  /'
    exit 1
  fi
fi

WORKTREE_PATH=".worktrees/${SLUG}"
BRANCH="task/${SLUG}"

echo "→ [$REPO] abortando task $TASK_ID (slug: $SLUG)"
echo "  worktree: $WORKTREE_PATH"
echo "  branch:   $BRANCH"
echo

# Remove worktree (force — descarta mudanças não-commitadas)
if [ -d "$WORKTREE_PATH" ]; then
  git worktree remove --force "$WORKTREE_PATH"
  echo "✓ Worktree removida: $WORKTREE_PATH"
fi

# Apaga branch (force — pode não estar mergeada)
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git branch -D "$BRANCH"
  echo "✓ Branch apagada: $BRANCH"
fi

git worktree prune

# Deregistra atômico se houver (v0.1). agent-id = <repo-short>-<task-id>.
REPO_SHORT="${REPO#mmb-}"
AGENT_ID="${REPO_SHORT}-${TASK_ID}"
if [ -f "$TOOLING_DIR/state/heartbeats/$AGENT_ID.alive" ]; then
  "$TOOLING_DIR/bin/agents.sh" deregister "$AGENT_ID" "aborted" || true
fi

echo "✓ [$REPO] Aborto concluído pra task $TASK_ID."
