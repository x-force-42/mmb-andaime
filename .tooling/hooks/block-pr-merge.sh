#!/usr/bin/env bash
# Hook PreToolUse do Claude Code — bloqueia comandos destrutivos de PR
# em sessões atômicas (enforcement técnico dos guardrails A10 + A8).
#
# Bloqueia se for sessão "automatizada" (worker stateless, atômico, orq
# spawnado) E o comando contiver:
#   - `gh pr merge`               (qualquer flag: --squash, --auto, sem flags)
#   - `gh pr review ... --approve` (em qualquer ordem de args)
#
# Convenção do MMB_AGENT_ID (setado por up.sh / worker.sh / spawn-atomic.sh):
#   unset     → Rick em terminal manual fora do tmux do andaime    → ALLOW
#   "master"  → Mestre INTERATIVO (setado por up.sh:79)             → ALLOW
#   "<dest>-<pid>"      → worker stateless (master-/logger-/...)    → BLOCK
#   "<repo>-<task-id>"  → atômico spawnado por spawn-atomic.sh      → BLOCK
#   qualquer outro valor                                            → BLOCK
#
# Mestre interativo é o ÚNICO contexto automatizado autorizado a
# mergear/aprovar. Worker-master também é "automatizado" mesmo rodando
# em nome do master — ele não revisa, só triá.
#
# Protocolo de hooks PreToolUse do Claude Code:
#   - stdin: JSON com {tool_name, tool_input, ...}
#   - exit 0: permite a tool call
#   - exit 2: deny; stderr é mostrado ao agente
#   - outros exits: tratados como erro do hook (caller decide)
#
# Configuração: ver .tooling/hooks/README.md.
#
# Limitação conhecida: se o atômico escreve um script com `gh pr merge`
# dentro e roda `bash script.sh`, o hook vê só `bash script.sh` e libera.
# Defesa-em-profundidade vs adversário determinado — fora de escopo.
# A guardrail principal é o profile (A10/A8 documentados); este hook é a
# barreira adicional pra erro acidental do atômico em chamada direta.

set -e

# Lê todo o stdin (JSON do Claude Code).
input=$(cat)

# Parse robusto: se jq falhar (stdin vazio, JSON malformado, etc),
# default pra exit 0 — o hook não pode ser ele mesmo um vetor de
# quebra. Falso negativo (não bloqueia algo que deveria) é melhor
# que false positive (trava agente legítimo) num hook universal.
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$tool_name" = "Bash" ] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
[ -n "$command" ] || exit 0

# Padrões proibidos.
#
# Prefixo `(^|[^a-zA-Z0-9_/])` evita matches em coisas como `mygh pr merge`
# ou `path/gh pr merge` (parte de outro identificador). Aceita início de
# linha, espaço, `;`, `&&`, `|`, `(`, ` `, etc.
PATTERN_MERGE='(^|[^a-zA-Z0-9_/])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
PATTERN_REVIEW='(^|[^a-zA-Z0-9_/])gh[[:space:]]+pr[[:space:]]+review([[:space:]]|$)'
PATTERN_APPROVE='(^|[^-])--approve([[:space:]]|=|$)'

blocked=""

if printf '%s' "$command" | grep -qE "$PATTERN_MERGE"; then
  blocked="gh pr merge"
elif printf '%s' "$command" | grep -qE "$PATTERN_REVIEW" \
  && printf '%s' "$command" | grep -qE "$PATTERN_APPROVE"; then
  blocked="gh pr review --approve"
fi

if [ -n "$blocked" ]; then
  # Bloqueia se MMB_AGENT_ID está setado E não é o Mestre interativo
  # (cuja convenção é MMB_AGENT_ID="master", setado por up.sh).
  agent_id="${MMB_AGENT_ID:-}"
  if [ -n "$agent_id" ] && [ "$agent_id" != "master" ]; then
    cat >&2 <<EOF
BLOCKED: Guardrails A10/A8 — só Mestre interativo mergeia/aprova PR.

Padrão detectado:  $blocked
Comando completo:  $command
MMB_AGENT_ID:      $agent_id

Esta sessão NÃO é o Mestre interativo (MMB_AGENT_ID != "master").
Sessões automatizadas (worker stateless, atômico, orq) não mergeiam
nem aprovam — só o Mestre interativo ou Rick (sem env do andaime).

Se você é atômico: sua única ação correta após \`open-pr.sh\` é
parar — o pane fecha em 8s sozinho.

Se você é worker-master: triagem manda escalar pra pending-human/
quando algo merece decisão; merge é decisão humana.

Episódio que motivou esta barreira: logger PR #9 no épico
ux-refresh-v07 (2026-05-16), mergeado autonomamente ~56 min após
open-pr.sh, sem revisão humana.
EOF
    exit 2
  fi
fi

exit 0
