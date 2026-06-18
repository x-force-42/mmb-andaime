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

# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"
mmb_targets_load || {
  echo "ERRO: registry de targets inválido. Abortando spawn-atomic." >&2
  exit 2
}

# Indireção testável do agents.sh (precedente: MMB_MSG_SH). Default = real.
AGENTS_SH="${MMB_AGENTS_SH:-$TOOLING_DIR/bin/agents.sh}"

# Valida que $REPO é target registrado. REPO_SHORT (= id) e REPO_PATH
# saem do registry — fonte única em vez de derivação por strip de prefixo.
REPO_SHORT="${REPO#mmb-}"
if ! mmb_target_exists "$REPO_SHORT" || [ "$(mmb_target_repo "$REPO_SHORT")" != "$REPO" ]; then
  _VALID=$(mmb_targets_list | tr ' ' '\n' | sed 's/^/mmb-/' | tr '\n' '|' | sed 's/|$//')
  echo "ERRO: repo '$REPO' não está registrado em targets.json (válidos: $_VALID)" >&2
  exit 2
fi
REPO_PATH=$(mmb_target_path "$REPO_SHORT")

if [ ! -d "$REPO_PATH/.git" ]; then
  echo "ERRO: '$REPO' está no registry mas $REPO_PATH/.git não existe." >&2
  exit 2
fi

# ── Idempotência (H3b) ────────────────────────────────────────────
# Sob retry/reprocessamento (ex.: orq re-despachado pelo retry-budget do
# H3), spawn-atomic pode ser chamado de novo pra MESMA task. Spawnar um
# 2º atômico VIVO na mesma worktree/branch é perigoso: dois claudes
# competindo, dois open-pr. A identidade estável é o AGENT_ID
# (<repo-short>-<task-id>), 1:1 com (branch task/<id>-*, worktree, registro).
#
# Política:
#   - vivo e consistente (registry=spawn + pane existe) → reusa, sai 0.
#   - registry diz vivo mas o pane sumiu (zumbi) → inconsistente → falha alto.
#   - sem atômico vivo (não-registrado / deregistered) → segue spawn normal.
# Roda só no contexto que de fato spawna (tmux disponível); o fallback
# sem-tmux não cria atômico vivo, então não precisa da guarda.
AGENT_ID="${REPO_SHORT}-${TASK_ID}"
PARENT_AGENT="$REPO_SHORT"

if [ -n "${TMUX:-}" ] && tmux has-session -t "$MMB_TMUX_SESSION" 2>/dev/null; then
  if _atomic_status=$("$AGENTS_SH" status "$AGENT_ID" 2>/dev/null); then
    _atomic_ev=$(printf '%s\n' "$_atomic_status" | head -1 \
      | grep -oE '"ev":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
    if [ "$_atomic_ev" = "spawn" ]; then
      _atomic_pane=$(printf '%s\n' "$_atomic_status" | head -1 \
        | grep -oE '"pane":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
      if [ -n "$_atomic_pane" ] && tmux list-panes -t "$_atomic_pane" >/dev/null 2>&1; then
        echo "↺ Atômico já vivo pra $AGENT_ID (pane $_atomic_pane)."
        echo "  Idempotente — reusando, sem spawnar de novo. Issue: #$ISSUE"
        exit 0
      fi
      echo "ERRO: registry marca '$AGENT_ID' como VIVO, mas o pane '${_atomic_pane:-?}' não existe (zumbi)." >&2
      echo "      Estado inconsistente — não vou spawnar em cima nem fingir sucesso." >&2
      echo "      Remedie e re-tente:" >&2
      echo "        $AGENTS_SH deregister $AGENT_ID stale-respawn" >&2
      echo "        .tooling/bin/task-abort.sh $REPO $TASK_ID   # se a worktree também estiver suja" >&2
      exit 5
    fi
  fi
fi

# Validação: issue existe e tem as labels esperadas.
# Usa o jq embutido no gh (--jq) em vez de jq externo — andaime
# fica self-contained em gh+git+tmux+claude.
# Owner GH per-target (PR 2B). Vem do registry; fallback para
# MMB_GH_OWNER global se entry com owner vazio.
TARGET_OWNER=$(mmb_target_owner "$REPO_SHORT")
GH_FULL="$TARGET_OWNER/$REPO"

echo "→ Validando issue #$ISSUE em $GH_FULL..."
if ! ISSUE_DATA=$(gh issue view "$ISSUE" --repo "$GH_FULL" \
    --json state,labels,title \
    --jq '[.state, ([.labels[].name] | join(",")), .title] | @tsv' 2>/dev/null); then
  echo "ERRO: issue #$ISSUE não existe (ou inacessível) em $GH_FULL." >&2
  echo "      Orq local precisa criar issue ANTES de spawnar atômico." >&2
  exit 3
fi

IFS=$'\t' read -r ISSUE_STATE LABELS TITLE <<< "$ISSUE_DATA"

# Extrai epic slug dos labels (ex: "task,project:mmb-aquarium,epic:mmb-logger-destilacao")
EPIC_SLUG=$(echo ",$LABELS," | grep -oP '(?<=,epic:)[^,]+' || true)

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

# Mitigação: asdf shim de `claude` pode ficar stale após npm install -g.
# Pane novo abre zsh fresh e tenta `claude` via PATH (shim), que dispara
# erro "No claude executable found for nodejs <ver>". Reshim defensivo
# garante shim atualizado antes do send-keys. Observado em 2026-05-15.
asdf reshim nodejs 2>/dev/null || true

ATOMIC_FLAGS=$(mmb_claude_flags atomic)

# AGENT_ID (<repo-short>-<task-id>) e PARENT_AGENT já computados na guarda
# de idempotência (H3b), logo após a validação do REPO.

PROMPT="Você é um Agente Atômico (id: $AGENT_ID). Leia /MMB/.tooling/profiles/atomic-agent.md antes de qualquer coisa. Sua tarefa: $TASK_ID (slug: $SLUG, repo: $REPO). Sua sub-issue é #$ISSUE em $GH_FULL — leia via: gh issue view $ISSUE --repo $GH_FULL. O body da issue é o prompt completo da sua execução. Antes de cada commit, rode: /MMB/.tooling/bin/agents.sh heartbeat $AGENT_ID. Quando terminar, abra PR via /MMB/.tooling/bin/open-pr.sh e encerre (o pane fecha sozinho)."

# Spawn no tmux
if [ -n "${TMUX:-}" ] && tmux has-session -t "$MMB_TMUX_SESSION" 2>/dev/null; then
  short="$REPO_SHORT"

  WINDOW_ID=$(tmux list-windows -t "$MMB_TMUX_SESSION" -F '#{window_index}:#{window_name}' \
    | grep ":$short\$" | head -1 | cut -d: -f1 || true)

  # Helper local: exporta MMB_TAB + MMB_AGENT_ID + MMB_PANE_ID antes do claude.
  # MMB_PANE_ID é passado explicitamente pra evitar que open-pr.sh use
  # `tmux display-message` — que retorna o pane FOCADO pelo client, não o
  # pane do script, e acabava matando a sessão do master quando o usuário
  # estava com a janela master em foco.
  _send_atomic_init() {
    local pane="$1"
    local pane_id="$2"
    tmux send-keys -t "$pane" "export MMB_TAB=$short MMB_AGENT_ID=$AGENT_ID GH_SUBISSUE=$ISSUE MMB_PANE_ID=$pane_id EPIC_SLUG=$EPIC_SLUG" C-m
    tmux send-keys -t "$pane" "claude $ATOMIC_FLAGS \"$PROMPT\"" C-m
  }

  if [ -z "$WINDOW_ID" ]; then
    echo "AVISO: window '$short' não encontrada na sessão tmux '$MMB_TMUX_SESSION'."
    echo "Fallback: criando nova window."
    # Captura o pane_id direto do new-window (-P -F). Evita o bug de tmux
    # parseando "." em nomes de window como separador de pane (TASK_ID
    # tipo "1.1" virava target "atomic-1.1" → window "atomic-1" pane "1").
    # Visto em 2026-05-25 (expense-web/api S0).
    NEW_PANE=$(tmux new-window -t "$MMB_TMUX_SESSION" -n "atomic-$TASK_ID" \
      -c "$WORKTREE" -P -F '#{pane_id}')
    _send_atomic_init "$NEW_PANE" "$NEW_PANE"
    "$TOOLING_DIR/bin/agents.sh" register \
      "$AGENT_ID" "$PARENT_AGENT" "$NEW_PANE" "$TASK_ID" "$EPIC_SLUG" "$MMB_MODEL_ATOMIC"
    echo "✓ Atômico spawnado em nova window 'atomic-$TASK_ID' (pane $NEW_PANE, id: $AGENT_ID)"
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

  # Captura o pane recém-criado (último pane da window).
  NEW_PANE=$(tmux list-panes -t "$MMB_TMUX_SESSION:$WINDOW_ID" \
    -F '#{pane_id}:#{pane_index}' | tail -1 | cut -d: -f1)
  _send_atomic_init "$MMB_TMUX_SESSION:$WINDOW_ID" "${NEW_PANE:-}"

  "$TOOLING_DIR/bin/agents.sh" register \
    "$AGENT_ID" "$PARENT_AGENT" "${NEW_PANE:-$MMB_TMUX_SESSION:$WINDOW_ID}" "$TASK_ID" "$EPIC_SLUG" "$MMB_MODEL_ATOMIC"

  echo "✓ Atômico spawnado como split na window '$short' (tab $WINDOW_ID, pane $NEW_PANE, id: $AGENT_ID)"
  echo "  Issue: #$ISSUE  Worktree: $WORKTREE"
  exit 0
fi

# Fallback: sem tmux disponível
echo
echo "Atômico pronto pra iniciar (tmux indisponível)."
echo "Em outra aba/terminal:"
echo "  cd $WORKTREE"
echo "  claude $ATOMIC_FLAGS \"$PROMPT\""
