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
#   .tooling/bin/up.sh                       # normal (Opus tudo)
#   MMB_MODE=fast .tooling/bin/up.sh         # smoke (Haiku tudo)
#   MMB_MODE=balanced .tooling/bin/up.sh     # trabalho real (Opus master, Sonnet workers/atomic)
#   .tooling/bin/up.sh --no-master-claude    # window master fica vazia (zsh) — quando o Master
#                                              é uma sessão Claude externa a esta tmux
#
# Se a sessão já existe, anexa. Pra recriar do zero:
#   tmux kill-session -t mmb && .tooling/bin/up.sh

set -euo pipefail

NO_MASTER_CLAUDE=0
for arg in "$@"; do
  case "$arg" in
    --no-master-claude) NO_MASTER_CLAUDE=1 ;;
    *) echo "flag desconhecida: $arg" >&2; exit 2 ;;
  esac
done

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

if [ "$NO_MASTER_CLAUDE" -eq 1 ]; then
  # Master vive em sessão Claude externa a este tmux. A window 'master'
  # fica como zsh limpo — útil pra você inspecionar inboxes/intents
  # manualmente sem competir com outro Claude pelo papel.
  tmux send-keys -t "$SESSION:master" \
    "echo 'master window: no Claude (use external Claude Code session). MMB_MODE=$MMB_MODE'" C-m
else
  MASTER_PROMPT="Você é o Orquestrador Mestre do MMB (modo $MMB_MODE). Leia nesta ordem ANTES de qualquer outra coisa: /MMB/CLAUDE.md, /MMB/.tooling/protocol.md, /MMB/.tooling/guardrails.md, /MMB/.tooling/profiles/master.md. Quando terminar de ler, cumprimente Rick em 1-2 linhas e pergunte em que pode ajudar. ARQUITETURA v0.3: orq locais (core/cockpit/aquarium) são WORKERS STATELESS — quando você roda msg.sh, o commd dispara um processo claude -p efêmero do papel correto e o output vai pra tab tmux correspondente. Você (Mestre) continua interativo. REGRAS DURAS: (1) nunca rode 'gh issue create'; orq local materializa. (2) antes de qualquer msg.sh briefing, mostre o briefing pro Rick e aguarde 'ok'. (3) toda comunicação com orq via /MMB/.tooling/bin/msg.sh. (4) antes de iniciar trabalho, liste pendências em /MMB/.tooling/inbox/master/ via ls."
  tmux send-keys -t "$SESSION:master" \
    "claude $MASTER_FLAGS \"$MASTER_PROMPT\"" C-m
fi

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

# ─── Windows 6-7: aquário (relay+dev) + bridge — só fora do modo fast
# Smoke (MMB_MODE=fast) não precisa de visualização viva.
if [ "$MMB_MODE" != "fast" ] && [ -d "$MMB_ROOT/mmb-aquarium" ]; then
  # Window aquario: build estático (dist/) + relay WS + vite preview.
  # ATENÇÃO: NÃO usa dev mode (HMR ao vivo) porque agentes podem estar
  # editando src/ do mmb-aquarium em worktrees, e o ambiente runtime
  # precisa estar congelado pra observação estável.
  tmux new-window -t "$SESSION" -n aquario -c "$MMB_ROOT/mmb-aquarium"
  tmux send-keys -t "$SESSION:aquario" \
    "npm run relay & npm run preview -- --port 4174 --host 127.0.0.1" C-m

  # Window cockpit-ui: build estático + vite preview (mesma estratégia).
  tmux new-window -t "$SESSION" -n cockpit-ui -c "$MMB_ROOT/mmb-cockpit"
  tmux send-keys -t "$SESSION:cockpit-ui" \
    "npm run preview -- --port 4173 --host 127.0.0.1" C-m

  # Window bridge: python daemon que conecta no relay como publisher.
  tmux new-window -t "$SESSION" -n bridge -c "$MMB_ROOT"
  tmux send-keys -t "$SESSION:bridge" \
    "$TOOLING_DIR/bin/aquario-bridge.sh" C-m
fi

# ─── Window logger: mmb-logger watch + serve — só fora do modo fast
if [ "$MMB_MODE" != "fast" ] && [ -d "$MMB_ROOT/mmb-logger" ]; then
  tmux new-window -t "$SESSION" -n logger -c "$MMB_ROOT/mmb-logger"
  # Fase 3+ removeu o comando `watch` (era ingest_once/runner.py legado).
  # Reconcile é one-shot; pra atualizar a DB com o estado atual, rodamos
  # uma reconcile inicial e depois só `serve` em foreground.
  tmux send-keys -t "$SESSION:logger" \
    "uv run mmb-logger init-db && uv run mmb-logger reconcile && uv run mmb-logger serve" C-m
fi

tmux select-window -t "$SESSION:master"
exec tmux attach -t "$SESSION"
