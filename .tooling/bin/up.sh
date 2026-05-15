#!/usr/bin/env bash
# Sobe sessão tmux com layout v0.3+ (workers stateless).
#
# Layout:
#   window 0 master   → Orq Mestre (Claude Code interativo, único vivo)
#   window 1 commd    → comm daemon (inotifywait + dispatch workers)
#   window 2 core     → tail -F logs/workers/core.log    (visualização)
#   window 3 cockpit  → tail -F logs/workers/cockpit.log
#   window 4 aquarium → tail -F logs/workers/aquarium.log
#   window 5 journal  → tail -F logs/journal.jsonl | jq  (opcional)
#
# Mudança crítica vs v0.1/v0.2: orq locais NÃO são mais sessões
# Claude interativas. Eles viram processos efêmeros (workers)
# disparados pelo commd quando msg.sh entrega uma mensagem.
# As tabs core/cockpit/aquarium agora são só janelas de observação.
#
# Uso:
#   .tooling/bin/up.sh           # modo normal (Opus+high)
#   MMB_MODE=fast .tooling/bin/up.sh   # smoke (Haiku+low)
#
# Se a sessão já existe, anexa. Pra recriar do zero:
#   tmux kill-session -t mmb && .tooling/bin/up.sh

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"

# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

# Diretórios essenciais (idempotente)
for d in master core cockpit aquarium; do
  mkdir -p "$TOOLING_DIR/inbox/$d"
done
mkdir -p "$TOOLING_DIR/state/heartbeats" \
         "$TOOLING_DIR/logs/workers"

# Toca os logs pra tail -F não reclamar de arquivo inexistente
for d in master core cockpit aquarium; do
  touch "$TOOLING_DIR/logs/workers/$d.log"
done
touch "$TOOLING_DIR/logs/commd.log"
touch "$TOOLING_DIR/logs/journal.jsonl"

SESSION="$MMB_TMUX_SESSION"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Sessão '$SESSION' já existe. Anexando..."
  exec tmux attach -t "$SESSION"
fi

MASTER_FLAGS=$(mmb_claude_flags master)

# ─── Window 0: master (Claude Code interativo) ──────────────────
tmux new-session -d -s "$SESSION" -n master -c "$MMB_ROOT"

# Registra o orq mestre no agent registry (v0.1)
"$TOOLING_DIR/bin/agents.sh" register master master "$SESSION:0.0" >/dev/null 2>&1 || true

# MMB_TAB no env da tab master + prompt inicial
tmux send-keys -t "$SESSION:master" \
  "export MMB_TAB=master MMB_AGENT_ID=master MMB_MODE=$MMB_MODE" C-m

MASTER_PROMPT="Você é o Orquestrador Mestre do MMB (modo $MMB_MODE). Leia nesta ordem ANTES de qualquer outra coisa: /MMB/CLAUDE.md, /MMB/.tooling/protocol.md, /MMB/.tooling/guardrails.md, /MMB/.tooling/profiles/master.md. Quando terminar de ler, cumprimente Rick em 1-2 linhas e pergunte em que pode ajudar. ARQUITETURA v0.3: orq locais (core/cockpit/aquarium) são WORKERS STATELESS — quando você roda msg.sh, o commd dispara um processo claude -p efêmero do papel correto e o output vai pra tab tmux correspondente. Você (Mestre) continua interativo. REGRAS DURAS: (1) nunca rode 'gh issue create'; orq local materializa. (2) antes de qualquer msg.sh briefing, mostre o briefing pro Rick e aguarde 'ok'. (3) toda comunicação com orq via /MMB/.tooling/bin/msg.sh. (4) antes de iniciar trabalho, liste pendências em /MMB/.tooling/inbox/master/ via ls."
tmux send-keys -t "$SESSION:master" \
  "claude $MASTER_FLAGS \"$MASTER_PROMPT\"" C-m

# ─── Window 1: commd (daemon) ───────────────────────────────────
tmux new-window -t "$SESSION" -n commd -c "$MMB_ROOT"
tmux send-keys -t "$SESSION:commd" \
  "export MMB_MODE=$MMB_MODE; $TOOLING_DIR/bin/commd.sh fg" C-m

# ─── Windows 2-4: tail -F dos workers ───────────────────────────
WINDOW_IDX=2
for project in mmb-core mmb-cockpit mmb-aquarium; do
  short="${project#mmb-}"
  if [ -d "$MMB_ROOT/$project/.git" ]; then
    tmux new-window -t "$SESSION" -n "$short" -c "$MMB_ROOT/$project"
    tmux send-keys -t "$SESSION:$short" \
      "tail -F $TOOLING_DIR/logs/workers/$short.log" C-m
    WINDOW_IDX=$((WINDOW_IDX + 1))
  fi
done

# ─── Window 5: journal (opcional, só se jq disponível) ──────────
if command -v jq >/dev/null 2>&1; then
  tmux new-window -t "$SESSION" -n journal -c "$MMB_ROOT"
  tmux send-keys -t "$SESSION:journal" \
    "tail -F $TOOLING_DIR/logs/journal.jsonl | jq -c '.'" C-m
fi

tmux select-window -t "$SESSION:master"
exec tmux attach -t "$SESSION"
