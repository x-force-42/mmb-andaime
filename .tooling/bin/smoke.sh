#!/usr/bin/env bash
# smoke — canário do andaime MMB.
#
# Valida que o pipeline de comunicação funciona ponta-a-ponta
# (master → msg.sh → commd → worker → status de volta).
#
# Uso:
#   smoke.sh comm    # só testa o canal — sem GitHub, sem atômico
#   smoke.sh         # alias pra 'comm'
#
# O smoke 'comm' é deliberadamente mínimo: assume que MMB_MODE=fast
# e o tmux/commd já estão de pé. Manda um briefing trivial pro orq
# core e espera ele responder via status em < 90 segundos.
#
# Verde   → comm funciona. Pode investir em testar fluxos maiores.
# Vermelho → diagnóstico nos logs (logs/commd.log, logs/workers/core.log).

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

MODE="${1:-comm}"

cmd_comm() {
  echo "================================================================"
  echo " SMOKE — modo: comm | MMB_MODE: $MMB_MODE | model: $MMB_MODEL_PROJECT_ORCHESTRATOR"
  echo "================================================================"

  # Pré-checks
  if [ ! -f "$TOOLING_DIR/state/commd.pid" ]; then
    echo "FAIL: commd.pid ausente. Suba o daemon antes:"
    echo "       MMB_MODE=$MMB_MODE $TOOLING_DIR/bin/commd.sh fg"
    echo "       (ou abra a tab 'commd' do tmux com $TOOLING_DIR/bin/up.sh)"
    exit 2
  fi
  local commd_pid
  commd_pid=$(cat "$TOOLING_DIR/state/commd.pid")
  if ! kill -0 "$commd_pid" 2>/dev/null; then
    echo "FAIL: pid file aponta pra processo morto ($commd_pid). Reinicie commd."
    exit 2
  fi
  echo "✓ commd vivo (pid=$commd_pid)"

  # Gera briefing trivial
  local ts
  ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  local thread="smoke-$ts"
  local intent_dir="$TOOLING_DIR/intents/${ts}-smoke"
  mkdir -p "$intent_dir"
  local brief="$intent_dir/master-briefing.md"

  cat > "$brief" <<EOF
# Smoke briefing — $ts

> Briefing canônico do smoke test do andaime. **Não é trabalho real.**

## Intenção

Testar que o pipeline msg.sh → commd → worker está vivo. Você (orq
core) NÃO deve criar issue no GitHub, NÃO deve spawnar atômico,
NÃO deve tocar nenhum repo de produção.

## O que fazer

1. Confirme que você é o worker do papel 'core' rodando stateless.
2. Mande de volta UM status pro master via:

   \`\`\`bash
   echo "smoke comm OK | worker=\$MMB_AGENT_ID | mode=\$MMB_MODE | ts=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
     | /MMB/.tooling/bin/msg.sh master status smoke-comm-ok - $thread
   \`\`\`

3. Saia. Não faça mais nada.

## Critério de pronto

- Arquivo aparece em \`/MMB/.tooling/inbox/master/\` com type=status
  e subject=smoke-comm-ok dentro de 90s do dispatch.

## Thread

$thread
EOF

  echo "✓ briefing gerado: $brief"

  # Tamanho atual do inbox/master pra detectar mensagem nova
  local before
  before=$(find "$TOOLING_DIR/inbox/master" -type f -not -name '.*' 2>/dev/null | wc -l)

  # Dispatch via msg.sh (simula o master rodando)
  echo "→ dispatching briefing pra core..."
  MMB_TAB=master "$TOOLING_DIR/bin/msg.sh" core briefing smoke-comm "$brief" "$thread" \
    || { echo "FAIL: msg.sh retornou erro"; exit 2; }

  # Espera resposta no inbox/master/ — poll a cada 2s, timeout 90s
  echo "→ aguardando status de volta (timeout 90s)..."
  local timeout=90
  local elapsed=0
  local found=""
  while [ "$elapsed" -lt "$timeout" ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    found=$(find "$TOOLING_DIR/inbox/master" -type f -name "*smoke-comm-ok*" \
              -not -name '.*' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      break
    fi
    printf "  [%2ds] aguardando...\r" "$elapsed"
  done
  echo

  if [ -z "$found" ]; then
    echo "FAIL: nenhum status com 'smoke-comm-ok' apareceu em ${timeout}s."
    echo
    echo "Diagnóstico:"
    echo "  - commd.log (últimas 30 linhas):"
    tail -30 "$TOOLING_DIR/logs/commd.log" 2>/dev/null | sed 's/^/    /'
    echo "  - workers/core.log (últimas 50 linhas):"
    tail -50 "$TOOLING_DIR/logs/workers/core.log" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi

  echo "================================================================"
  echo " SMOKE PASS  — tempo: ${elapsed}s"
  echo "================================================================"
  echo "Resposta:"
  cat "$found" | sed 's/^/  /'
}

case "$MODE" in
  comm|"") cmd_comm ;;
  *)
    echo "Uso: $0 [comm]" >&2
    echo "Por enquanto só 'comm' é implementado. 'full' vem depois." >&2
    exit 1
    ;;
esac
