#!/usr/bin/env bash
# Cleanup após uma task ser mergeada (FF, merge tradicional ou squash).
#
# Uso:
#   .tooling/bin/task-end.sh <repo> <task-id>
#
# Detecção de default branch: usa origin/HEAD se disponível, senão
# main/master por fallback. Detecção de squash-merge: compara o
# patch-id da branch (aplicada sobre merge-base) com os patch-ids
# do default branch via `git cherry`.
#
# Pra abortar uma task que NÃO foi mergeada (descartar trabalho):
# use task-abort.sh em vez deste.

set -euo pipefail

REPO="${1:-}"
TASK_ID="${2:-}"

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"

# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"
mmb_targets_load || {
  echo "ERRO: registry de targets inválido. Abortando task-end." >&2
  exit 2
}

if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
  echo "Uso: $0 <repo> <task-id>"
  exit 1
fi

# Resolve REPO_PATH via registry (suporta local_path absoluto para target
# externo fora de MMB_ROOT). Fallback retro-compat para repos não-registrados.
REPO_SHORT="${REPO#mmb-}"
if mmb_target_exists "$REPO_SHORT" && [ "$(mmb_target_repo "$REPO_SHORT")" = "$REPO" ]; then
  REPO_PATH=$(mmb_target_path "$REPO_SHORT")
else
  REPO_PATH="$MMB_ROOT/$REPO"
fi

if [ ! -d "$REPO_PATH/.git" ]; then
  echo "ERRO: $REPO não é um repo git em $REPO_PATH."
  exit 1
fi

cd "$REPO_PATH"

TASK_FILE=$(ls docs/tasks/${TASK_ID}-*.md 2>/dev/null | head -1 || true)
if [ -z "$TASK_FILE" ]; then
  # Fallback: descobre slug pela branch existente
  BRANCH_GUESS=$(git branch --list "task/${TASK_ID}-*" | head -1 | sed 's|^[* +]*||' || true)
  if [ -z "$BRANCH_GUESS" ]; then
    echo "ERRO: task '$TASK_ID' não encontrada em $REPO/docs/tasks/ nem como branch."
    exit 1
  fi
  SLUG="${BRANCH_GUESS#task/}"
else
  SLUG=$(basename "$TASK_FILE" .md)
fi

WORKTREE_PATH=".worktrees/${SLUG}"
BRANCH="task/${SLUG}"

DEFAULT_BRANCH=$(mmb_default_branch)
echo "→ [$REPO] default branch: $DEFAULT_BRANCH"

# Confere mergeada (FF/merge tradicional ou squash).
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  if git merge-base --is-ancestor "$BRANCH" "$DEFAULT_BRANCH"; then
    : # mergeada via FF/merge tradicional
  else
    MERGE_BASE=$(git merge-base "$DEFAULT_BRANCH" "$BRANCH")
    BRANCH_TREE=$(git rev-parse "${BRANCH}^{tree}")
    SQUASH_CANDIDATE=$(git commit-tree -m "_" -p "$MERGE_BASE" "$BRANCH_TREE")
    if git cherry "$DEFAULT_BRANCH" "$SQUASH_CANDIDATE" | grep -q "^- "; then
      : # mergeada via squash (patch-id equivalente em $DEFAULT_BRANCH)
    else
      echo "ERRO: branch $BRANCH não está mergeada em $DEFAULT_BRANCH."
      echo "Mergeie o PR primeiro, ou use task-abort.sh pra descartar."
      exit 1
    fi
  fi
fi

# Remove worktree
if [ -d "$WORKTREE_PATH" ]; then
  git worktree remove "$WORKTREE_PATH"
  echo "✓ [$REPO] Worktree removida: $WORKTREE_PATH"
fi

# Apaga branch local
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git branch -D "$BRANCH"
  echo "✓ [$REPO] Branch apagada: $BRANCH"
fi

git worktree prune

# Limpa o brief de task local se for untracked (artefato runtime).
# Tracked = preservado (commitado deliberadamente pelo PR).
mmb_delete_orphan_task_file "$TASK_FILE" "$REPO"

# Deregistra atômico + remove heartbeat órfão (helper em config.sh).
REPO_SHORT="${REPO#mmb-}"
mmb_remove_orphan_heartbeat "${REPO_SHORT}-${TASK_ID}" "merged"

echo "✓ [$REPO] Cleanup concluído pra task $TASK_ID."
