#!/usr/bin/env bash
# Spawna um Agente Atômico.
#
#   1. Valida pré-requisitos (issue existe, labels corretas,
#      task-id casa com branch existente OU brief local).
#   2. Cria worktree + branch via task-start.sh.
#   3. Abre split-pane vertical (default) na tab tmux do projeto.
#      Atômico fica embaixo do orquestrador. Configurável em
#      config.sh via MMB_TMUX_SPLIT.
#   4. Inicia `claude` na worktree com prompt apontando pro
#      profile atomic-agent.md + a sub-issue do GitHub.
#
# Uso:
#   .tooling/bin/spawn-atomic.sh <repo> <task-id> <issue-number>
#
# **issue-number é OBRIGATÓRIO** (v3) — orq local cria issue
# ANTES e passa o número. Não fazemos mais autodescoberta
# silenciosa porque mascarava bugs (atômico spawnava sem
# brief sólido).

set -euo pipefail

REPO="${1:-}"
TASK_ID="${2:-}"
ISSUE="${3:-}"

if [ -z "$REPO" ] || [ -z "$TASK_ID" ] || [ -z "$ISSUE" ]; then
  cat >&2 <<EOF
Uso: $0 <repo> <task-id> <issue-number>

Todos os 3 argumentos são obrigatórios.

Fluxo esperado:
  1. Orq local cria issue:
     gh issue create --repo \$MMB_GH_OWNER/<repo> \\
       --title "..." --label "task,project:<repo>,epic:<slug>" \\
       --body-file <briefing-path>
  2. Anote o número que voltou.
  3. spawn-atomic.sh <repo> <task-id> <numero>
EOF
  exit 1
fi

# Validação básica do issue#
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "ERRO: issue-number '$ISSUE' não é um número." >&2
  exit 2
fi

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"
REPO_PATH="$MMB_ROOT/$REPO"

# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

if [ ! -d "$REPO_PATH/.git" ]; then
  echo "ERRO: '$REPO' não é um repo git em $REPO_PATH." >&2
  exit 2
fi

# Validação: issue existe e tem as labels esperadas.
# Usa o jq embutido no gh (--jq) em vez de jq externo — andaime
# fica self-contained em gh+git+tmux+claude.
echo "→ Validando issue #$ISSUE em $MMB_GH_OWNER/$REPO..."
if ! ISSUE_DATA=$(gh issue view "$ISSUE" --repo "$MMB_GH_OWNER/$REPO" \
    --json state,labels,title \
    --jq '[.state, ([.labels[].name] | join(",")), .title] | @tsv' 2>/dev/null); then
  echo "ERRO: issue #$ISSUE não existe (ou inacessível) em $MMB_GH_OWNER/$REPO." >&2
  echo "      Orq local precisa criar issue ANTES de spawnar atômico." >&2
  exit 3
fi

IFS=$'\t' read -r ISSUE_STATE LABELS TITLE <<< "$ISSUE_DATA"

if [ "$ISSUE_STATE" != "OPEN" ]; then
  echo "ERRO: issue #$ISSUE está '$ISSUE_STATE', não OPEN. Não posso spawnar atômico." >&2
  exit 3
fi

if ! echo ",$LABELS," | grep -q ',task,'; then
  echo "AVISO: issue #$ISSUE não tem label 'task'. Labels atuais: $LABELS" >&2
  echo "       Prosseguindo, mas recomendado o orq local revisar." >&2
fi
if ! echo ",$LABELS," | grep -q ",project:$REPO,"; then
  echo "AVISO: issue #$ISSUE não tem label 'project:$REPO'. Labels atuais: $LABELS" >&2
fi

echo "  ✓ Issue #$ISSUE OPEN, $TITLE"

# Garante worktree pronta
"$TOOLING_DIR/bin/task-start.sh" "$REPO" "$TASK_ID"

# Descobre slug (igual antes)
TASK_FILE=$(ls "$REPO_PATH/docs/tasks/${TASK_ID}-"*.md 2>/dev/null | head -1 || true)
if [ -z "$TASK_FILE" ]; then
  BRANCH_NAME=$(cd "$REPO_PATH" && git branch --list "task/${TASK_ID}-*" | head -1 | sed 's|^[* +]*||' || true)
  if [ -z "$BRANCH_NAME" ]; then
    echo "ERRO: não consegui descobrir slug pra task $TASK_ID após task-start.sh" >&2
    exit 4
  fi
  SLUG="${BRANCH_NAME#task/}"
else
  SLUG=$(basename "$TASK_FILE" .md)
fi
WORKTREE="$REPO_PATH/.worktrees/$SLUG"

ATOMIC_FLAGS=$(mmb_claude_flags atomic)

PROMPT="Você é um Agente Atômico. Leia /MMB/.tooling/profiles/atomic-agent.md antes de qualquer coisa. Sua tarefa: $TASK_ID (slug: $SLUG, repo: $REPO). Sua sub-issue é #$ISSUE em $MMB_GH_OWNER/$REPO — leia via: gh issue view $ISSUE --repo $MMB_GH_OWNER/$REPO. O body da issue é o prompt completo da sua execução. Quando terminar, abra PR via /MMB/.tooling/bin/open-pr.sh e encerre (o pane fecha sozinho)."

# Spawn no tmux
if [ -n "${TMUX:-}" ] && tmux has-session -t "$MMB_TMUX_SESSION" 2>/dev/null; then
  short="${REPO#mmb-}"

  WINDOW_ID=$(tmux list-windows -t "$MMB_TMUX_SESSION" -F '#{window_index}:#{window_name}' \
    | grep ":$short\$" | head -1 | cut -d: -f1 || true)

  if [ -z "$WINDOW_ID" ]; then
    echo "AVISO: window '$short' não encontrada na sessão tmux '$MMB_TMUX_SESSION'."
    echo "Fallback: criando nova window."
    tmux new-window -t "$MMB_TMUX_SESSION" -n "atomic-$TASK_ID" -c "$WORKTREE"
    tmux send-keys -t "$MMB_TMUX_SESSION:atomic-$TASK_ID" "claude $ATOMIC_FLAGS \"$PROMPT\"" C-m
    echo "✓ Atômico spawnado em nova window 'atomic-$TASK_ID'"
    exit 0
  fi

  case "$MMB_TMUX_SPLIT" in
    -v|-h)
      tmux split-window "$MMB_TMUX_SPLIT" -t "$MMB_TMUX_SESSION:$WINDOW_ID" -c "$WORKTREE"
      ;;
    win)
      tmux new-window -t "$MMB_TMUX_SESSION" -n "atomic-$TASK_ID" -c "$WORKTREE"
      ;;
    *)
      echo "AVISO: MMB_TMUX_SPLIT='$MMB_TMUX_SPLIT' inválido; usando -v"
      tmux split-window -v -t "$MMB_TMUX_SESSION:$WINDOW_ID" -c "$WORKTREE"
      ;;
  esac

  tmux send-keys -t "$MMB_TMUX_SESSION:$WINDOW_ID" "claude $ATOMIC_FLAGS \"$PROMPT\"" C-m

  echo "✓ Atômico spawnado como split na window '$short' (tab $WINDOW_ID)"
  echo "  Issue: #$ISSUE  Worktree: $WORKTREE"
  exit 0
fi

# Fallback: sem tmux disponível
echo
echo "Atômico pronto pra iniciar (tmux indisponível)."
echo "Em outra aba/terminal:"
echo "  cd $WORKTREE"
echo "  claude $ATOMIC_FLAGS \"$PROMPT\""
