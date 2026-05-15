#!/usr/bin/env bash
# Configuração central do andaime MMB.
#
# Sourced por up.sh, spawn-atomic.sh, e qualquer outro script que
# precise spawnar sessões Claude.
#
# Override pontual: `MMB_MODEL_ATOMIC=claude-sonnet-4-6 .tooling/bin/spawn-atomic.sh ...`
# Override permanente: edite este arquivo e commite.

# ─── Modo de operação ────────────────────────────────────────────
# MMB_MODE controla o perfil global do andaime.
#
#   normal → Opus + effort high em todas as camadas. Produção.
#   fast   → Haiku + effort low em todas as camadas. Smoke test,
#            iteração de desenvolvimento do próprio andaime.
#
# Override por sessão: `MMB_MODE=fast .tooling/bin/up.sh`.
# Defaults individuais ainda podem ser sobrescritos depois (env
# var específica vence MMB_MODE).

: "${MMB_MODE:=normal}"

case "$MMB_MODE" in
  fast)
    # Smoke / iteração rápida de método. Haiku tudo, effort low.
    _mmb_default_model="claude-haiku-4-5-20251001"
    _mmb_default_effort="low"
    : "${MMB_HEARTBEAT_TIMEOUT_DEFAULT:=60}"
    ;;
  balanced)
    # Trabalho real. Master pesado (decisão cross-repo), workers/atomic
    # leves (rotina executiva). Default por camada definido logo abaixo.
    # _mmb_default_* não usado em balanced — cada camada vem com modelo
    # explícito; ainda definimos por compatibilidade com helpers que leem.
    _mmb_default_model="claude-sonnet-4-6"
    _mmb_default_effort="high"
    : "${MMB_HEARTBEAT_TIMEOUT_DEFAULT:=600}"
    ;;
  normal)
    # Produção tradicional. Opus em todas as camadas. Qualidade > tudo.
    _mmb_default_model="claude-opus-4-7"
    _mmb_default_effort="high"
    : "${MMB_HEARTBEAT_TIMEOUT_DEFAULT:=600}"
    ;;
  *)
    echo "config.sh: MMB_MODE inválido '$MMB_MODE' (use normal|fast|balanced)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# ─── Modelos por camada ──────────────────────────────────────────
# Variáveis Claude CLI: --model <id> --effort <low|medium|high|xhigh|max>
#
# Defaults vêm do MMB_MODE. Override pontual:
#   MMB_MODEL_ATOMIC=claude-sonnet-4-6 .tooling/bin/spawn-atomic.sh ...

# Modo balanced sobrescreve por camada (master pesado, restante leve).
# Outros modos: cada camada herda os defaults uniformes acima.
if [ "$MMB_MODE" = "balanced" ]; then
  : "${MMB_MODEL_MASTER:=claude-opus-4-7}"
  : "${MMB_EFFORT_MASTER:=high}"
  : "${MMB_MODEL_PROJECT_ORCHESTRATOR:=claude-sonnet-4-6}"
  : "${MMB_EFFORT_PROJECT_ORCHESTRATOR:=medium}"
  : "${MMB_MODEL_ATOMIC:=claude-sonnet-4-6}"
  : "${MMB_EFFORT_ATOMIC:=high}"
else
  : "${MMB_MODEL_MASTER:=$_mmb_default_model}"
  : "${MMB_EFFORT_MASTER:=$_mmb_default_effort}"
  : "${MMB_MODEL_PROJECT_ORCHESTRATOR:=$_mmb_default_model}"
  : "${MMB_EFFORT_PROJECT_ORCHESTRATOR:=$_mmb_default_effort}"
  : "${MMB_MODEL_ATOMIC:=$_mmb_default_model}"
  : "${MMB_EFFORT_ATOMIC:=$_mmb_default_effort}"
fi

unset _mmb_default_model _mmb_default_effort

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

# ─── Supervision ─────────────────────────────────────────────────
# Threshold (segundos) sem heartbeat antes do orq considerar um
# filho zumbi. Configurável via env: MMB_HEARTBEAT_TIMEOUT=300 ...
#
# 10 min é margem larga (normal); 1 min (fast). Default deriva do
# MMB_MODE — sobrescritível.

: "${MMB_HEARTBEAT_TIMEOUT:=${MMB_HEARTBEAT_TIMEOUT_DEFAULT:-600}}"

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
