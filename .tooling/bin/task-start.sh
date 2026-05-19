#!/usr/bin/env bash
# Cria worktree + branch isolada pra trabalhar numa task em um dos repos do MMB.
#
# Uso:
#   .tooling/bin/task-start.sh <repo> <task-id>
#
# Exemplos:
#   .tooling/bin/task-start.sh mmb-cockpit F0
#   .tooling/bin/task-start.sh mmb-aquarium V1
#   .tooling/bin/task-start.sh mmb-logger L1
#
# Resultado: worktree em <repo>/.worktrees/<id>-<slug> com branch
# task/<id>-<slug> baseada num master atualizado.

set -euo pipefail

REPO="${1:-}"
TASK_ID="${2:-}"

# Localiza a raiz do MMB (parente do .tooling/)
TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"

if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
  echo "Uso: $0 <repo> <task-id>"
  echo
  echo "Repos disponíveis:"
  for d in "$MMB_ROOT"/mmb-*; do
    [ -d "$d/.git" ] && echo "  - $(basename "$d")"
  done
  exit 1
fi

REPO_PATH="$MMB_ROOT/$REPO"

if [ ! -d "$REPO_PATH/.git" ]; then
  echo "ERRO: $REPO não é um repo git em $REPO_PATH."
  exit 1
fi

cd "$REPO_PATH"

# Localiza o brief da task (case-insensitive na id) em docs/tasks/
TASK_FILE=$(ls docs/tasks/${TASK_ID}-*.md 2>/dev/null | head -1 || true)
if [ -z "$TASK_FILE" ]; then
  echo "ERRO: task '$TASK_ID' não encontrada em $REPO/docs/tasks/."
  echo "Tasks disponíveis:"
  ls docs/tasks/[A-Z0-9]*.md 2>/dev/null | xargs -n1 basename | sed 's/^/  /' || echo "  (nenhuma)"
  exit 1
fi
SLUG=$(basename "$TASK_FILE" .md)

WORKTREE_PATH=".worktrees/${SLUG}"
BRANCH="task/${SLUG}"

# Detecta branch principal (main ou master)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git branch -r | grep -E 'origin/(main|master)$' | head -1 | sed 's|.*origin/||' | xargs || echo "main")
fi

# Atualiza branch principal se possível (sem falhar se offline)
echo "→ [$REPO] atualizando $DEFAULT_BRANCH local..."
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  git pull --ff-only 2>/dev/null || echo "  (pull falhou — seguindo com $DEFAULT_BRANCH local)"
else
  git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || echo "  (fetch falhou — seguindo com $DEFAULT_BRANCH local)"
fi

# Re-entrada: worktree já existe
if [ -d "$WORKTREE_PATH" ]; then
  echo
  echo "Worktree já existe: $REPO_PATH/$WORKTREE_PATH"
  echo "Branch: $BRANCH"
  echo
  echo "Pra continuar:"
  echo "  cd $REPO_PATH/$WORKTREE_PATH"
  echo "  claude"
  exit 0
fi

# Cria worktree + branch
echo "→ [$REPO] criando worktree $WORKTREE_PATH (branch $BRANCH)..."
git worktree add -b "$BRANCH" "$WORKTREE_PATH" "$DEFAULT_BRANCH"

echo
echo "✓ [$REPO] Worktree pronta: $REPO_PATH/$WORKTREE_PATH"
echo "✓ Branch: $BRANCH (a partir de $DEFAULT_BRANCH)"
echo
echo "Próximos passos:"
echo "  cd $REPO_PATH/$WORKTREE_PATH"
echo "  cat docs/tasks/${SLUG}.md     # leia o brief"
echo "  claude                          # inicia agente atômico"
echo
echo "Ao terminar (após PR mergeado):"
echo "  .tooling/bin/task-end.sh $REPO $TASK_ID"
