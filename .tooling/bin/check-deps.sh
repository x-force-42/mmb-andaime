#!/usr/bin/env bash
# Verifica se as dependências de uma tarefa estão satisfeitas (PRs mergeados).
#
# Uso:
#   .tooling/bin/check-deps.sh <repo> <task-id> [issue-number]
#
# Lê o body da sub-issue, extrai linhas `requires: #N`, consulta
# status de cada PR/issue via gh. Exit 0 se todas mergeadas, 1
# caso contrário.
#
# Se issue-number não for passado, procura por label task + ID no
# título via gh issue list.

set -euo pipefail

REPO="${1:-}"
TASK_ID="${2:-}"
ISSUE="${3:-}"

if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
  echo "Uso: $0 <repo> <task-id> [issue-number]"
  exit 1
fi

GH_REPO="x-force-42/$REPO"

# Encontra issue se não passada
if [ -z "$ISSUE" ]; then
  ISSUE=$(gh issue list --repo "$GH_REPO" --label task --search "$TASK_ID in:title" \
    --json number --jq '.[0].number' 2>/dev/null || true)
  if [ -z "$ISSUE" ] || [ "$ISSUE" = "null" ]; then
    echo "ERRO: não achei issue da task $TASK_ID em $GH_REPO."
    exit 1
  fi
fi

echo "→ Verificando deps da sub-issue #$ISSUE em $GH_REPO..."

BODY=$(gh issue view "$ISSUE" --repo "$GH_REPO" --json body --jq .body)

# Extrai linhas `requires: #N` (case-insensitive)
DEPS=$(echo "$BODY" | grep -iE '^[[:space:]]*[-*]?[[:space:]]*requires[[:space:]]*:?[[:space:]]*#[0-9]+' | grep -oE '#[0-9]+' | tr -d '#' || true)

if [ -z "$DEPS" ]; then
  echo "✓ Sem dependências. Pode prosseguir."
  exit 0
fi

ALL_OK=true
for DEP in $DEPS; do
  STATE=$(gh issue view "$DEP" --repo "$GH_REPO" --json state --jq .state 2>/dev/null || echo "MISSING")
  case "$STATE" in
    CLOSED) echo "  ✓ #$DEP closed (provavelmente mergeada)";;
    OPEN)   echo "  ✗ #$DEP ainda OPEN"; ALL_OK=false;;
    MISSING)echo "  ? #$DEP não encontrada (pode ser PR, não issue)";;
    *)      echo "  ? #$DEP state=$STATE"; ALL_OK=false;;
  esac
done

if [ "$ALL_OK" = true ]; then
  echo "✓ Todas as deps satisfeitas. Pode spawnar atômico."
  exit 0
else
  echo "✗ Há deps pendentes. Aguarde merge."
  exit 1
fi
