#!/usr/bin/env bash
# Configuração central do andaime MMB.
#
# Sourced por up.sh, spawn-atomic.sh, e qualquer outro script que
# precise spawnar sessões Claude.
#
# Override pontual: `MMB_MODEL_ATOMIC=claude-sonnet-4-6 .tooling/bin/spawn-atomic.sh ...`
# Override permanente: edite este arquivo e commite.

# ─── Modelos por camada ──────────────────────────────────────────
# Variáveis Claude CLI: --model <id> --effort <low|medium|high>
#
# Hoje: tudo no topo da pilha (Opus + effort high).
# Quando maturar: experimentar atômicos com modelo menor (Sonnet
# ou Haiku) — ver memória `feedback_model_per_layer.md`.

: "${MMB_MODEL_MASTER:=claude-opus-4-7}"
: "${MMB_EFFORT_MASTER:=high}"

: "${MMB_MODEL_PROJECT_ORCHESTRATOR:=claude-opus-4-7}"
: "${MMB_EFFORT_PROJECT_ORCHESTRATOR:=high}"

: "${MMB_MODEL_ATOMIC:=claude-opus-4-7}"
: "${MMB_EFFORT_ATOMIC:=high}"

# ─── Permissões ──────────────────────────────────────────────────
# Default: skip pra não interromper fluxo cross-repo. Confirmação
# acontece no PR (Rick revisa diff), não em cada tool call.
# Mitigado por: atômicos em worktree isolada + push só pra branch
# task/* + Rick é o único que mergeia.
#
# Override por sessão: MMB_SKIP_PERMS=false ...

: "${MMB_SKIP_PERMS:=true}"

# ─── Repositório no GitHub ───────────────────────────────────────
# Owner/org. Cada repo se chama `mmb-<algo>`.

: "${MMB_GH_OWNER:=x-force-42}"

# ─── tmux ────────────────────────────────────────────────────────
# Nome da sessão tmux principal e tipo de split pra atômicos.
#
# MMB_TMUX_SPLIT:
#   "-v"  → atômico embaixo do orquestrador (vertical, default)
#   "-h"  → atômico ao lado do orquestrador (horizontal)
#   "win" → nova window na mesma tab (modo antigo)

: "${MMB_TMUX_SESSION:=mmb}"
: "${MMB_TMUX_SPLIT:=-v}"

# ─── Helpers ─────────────────────────────────────────────────────
# Monta a string de flags pra passar pro `claude` CLI de uma
# camada específica. Uso interno dos scripts.
#
# Uso:
#   mmb_claude_flags master   → "--model claude-opus-4-7 --effort high --dangerously-skip-permissions"
#   mmb_claude_flags atomic   → "--model claude-opus-4-7 --effort high --dangerously-skip-permissions"

mmb_claude_flags() {
  local layer="$1"
  local model effort
  case "$layer" in
    master)
      model="$MMB_MODEL_MASTER"
      effort="$MMB_EFFORT_MASTER"
      ;;
    project)
      model="$MMB_MODEL_PROJECT_ORCHESTRATOR"
      effort="$MMB_EFFORT_PROJECT_ORCHESTRATOR"
      ;;
    atomic)
      model="$MMB_MODEL_ATOMIC"
      effort="$MMB_EFFORT_ATOMIC"
      ;;
    *)
      echo "mmb_claude_flags: layer desconhecida '$layer'" >&2
      return 1
      ;;
  esac

  local flags="--model $model"
  [ -n "$effort" ] && flags="$flags --effort $effort"
  [ "$MMB_SKIP_PERMS" = "true" ] && flags="$flags --dangerously-skip-permissions"
  echo "$flags"
}

# Detecta o default branch do repo atual (main ou master).
# Uso (dentro de um repo):
#   default_branch=$(mmb_default_branch)
mmb_default_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' \
    || git branch -r 2>/dev/null \
       | grep -E 'origin/(main|master)$' \
       | head -1 | sed 's|.*origin/||' | xargs \
    || echo "main"
}
