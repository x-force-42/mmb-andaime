#!/usr/bin/env bash
# Hook PreToolUse do Claude Code — bloqueia comandos destrutivos de PR
# em sessões atômicas (enforcement técnico dos guardrails A10 + A8).
#
# Bloqueia se MMB_AGENT_ID estiver setado E o comando contiver:
#   - `gh pr merge`               (qualquer flag: --squash, --auto, sem flags)
#   - `gh pr review ... --approve` (em qualquer ordem de args)
#
# Em sessões sem MMB_AGENT_ID (Mestre, Rick manual, worker-master)
# o hook é no-op transparente.
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
  # Só bloqueia em sessão atômica (MMB_AGENT_ID setado pelo spawn-atomic.sh).
  if [ -n "${MMB_AGENT_ID:-}" ]; then
    cat >&2 <<EOF
BLOCKED: Guardrails A10/A8 — atômico não mergeia nem aprova PR.

Padrão detectado:  $blocked
Comando completo:  $command
MMB_AGENT_ID:      $MMB_AGENT_ID

Só Mestre/Rick mergeia ou aprova. Sua única ação correta após
\`open-pr.sh\` é parar — o pane fecha em 8s sozinho.

Se o seu trabalho parece "pronto pra mergear", o sinal correto é
deixar o PR aberto pra revisão humana. Rick mergeia quando revisar.

Episódio que motivou esta barreira: logger PR #9 no épico
ux-refresh-v07 (2026-05-16), mergeado autonomamente ~56 min após
open-pr.sh, sem revisão humana. Já tinha A10 documentado no
profile; agora tem enforcement técnico.
EOF
    exit 2
  fi
fi

exit 0
