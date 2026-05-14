#!/usr/bin/env bash
# Sobe sessão tmux com layout padrão do MMB (modelo v3):
#   - tab master    → Orquestrador Mestre na raiz /MMB/
#   - tab core      → Orquestrador de Projeto em mmb-core
#   - tab cockpit   → Orquestrador de Projeto em mmb-cockpit
#   - tab aquarium  → Orquestrador de Projeto em mmb-aquarium
#
# Cada sessão:
#   - Recebe MMB_TAB no env (pra msg.sh saber quem é remetente).
#   - É iniciada com flags da config.sh (modelo + effort +
#     --dangerously-skip-permissions por default).
#   - Recebe prompt que aponta pro profile correto E pro protocolo
#     de mensagens (protocol.md).
#
# Comunicação: Rick fala SÓ com a tab master. Mestre fala com orqs
# locais via .tooling/bin/msg.sh (mailbox em .tooling/inbox/).
#
# Uso:
#   .tooling/bin/up.sh
#
# Se a sessão já existe, anexa. Pra recriar do zero:
#   tmux kill-session -t mmb && .tooling/bin/up.sh

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"

# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

# Garante que diretórios de inbox existem (idempotente)
for d in master core cockpit aquarium; do
  mkdir -p "$TOOLING_DIR/inbox/$d"
done

SESSION="$MMB_TMUX_SESSION"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Sessão '$SESSION' já existe. Anexando..."
  exec tmux attach -t "$SESSION"
fi

MASTER_FLAGS=$(mmb_claude_flags master)
PROJECT_FLAGS=$(mmb_claude_flags project)

# Cria sessão começando na tab master
tmux new-session -d -s "$SESSION" -n master -c "$MMB_ROOT"

# MMB_TAB no env da tab master + prompt inicial
tmux send-keys -t "$SESSION:master" "export MMB_TAB=master" C-m

MASTER_PROMPT="Você é o Orquestrador Mestre do MMB. Leia nesta ordem ANTES de qualquer outra coisa: /MMB/CLAUDE.md, /MMB/.tooling/protocol.md, /MMB/.tooling/guardrails.md, /MMB/.tooling/profiles/master.md. Quando terminar de ler, cumprimente Rick em 1-2 linhas e pergunte em que pode ajudar. REGRAS DURAS que NUNCA viole: (1) Você nunca roda 'gh issue create' nem qualquer escrita no GitHub. Sua função é briefing+dispatch via msg.sh. (2) Antes de qualquer msg.sh briefing, você MOSTRA o briefing pro Rick e aguarda 'ok' explícito. (3) Você conversa com orq local APENAS via /MMB/.tooling/bin/msg.sh. (4) Antes de iniciar trabalho, liste pendências em /MMB/.tooling/inbox/master/ via ls."
tmux send-keys -t "$SESSION:master" \
  "claude $MASTER_FLAGS \"$MASTER_PROMPT\"" \
  C-m

# Tab por projeto
for project in mmb-core mmb-cockpit mmb-aquarium; do
  if [ -d "$MMB_ROOT/$project/.git" ]; then
    short="${project#mmb-}"
    tmux new-window -t "$SESSION" -n "$short" -c "$MMB_ROOT/$project"

    # MMB_TAB no env
    tmux send-keys -t "$SESSION:$short" "export MMB_TAB=$short" C-m

    PROMPT="Você é o Orquestrador de Projeto deste repo ($project). Leia nesta ordem ANTES de qualquer outra coisa: /MMB/.tooling/protocol.md, /MMB/.tooling/guardrails.md, /MMB/.tooling/profiles/project-orchestrator.md, ./CLAUDE.md. REGRAS DURAS que NUNCA viole: (1) Você NÃO conversa com Rick. Diretamente, nunca. (2) Antes de spawnar atômico, você SEMPRE cria a issue no GitHub primeiro e passa o # pro spawn-atomic.sh. (3) Toda mensagem MSG que aparecer no seu prompt deve ser acusada e processada — nunca ignorada. (4) Você manda status pro Mestre via msg.sh nos 3 marcos: issue-criada, pr-aberto, task-fechada. Primeira ação: liste mensagens em /MMB/.tooling/inbox/$short/ via ls, depois liste sub-issues abertas via 'gh issue list --repo $MMB_GH_OWNER/$project --label task --state open', reporte resumido e aguarde briefing via ping MSG."
    tmux send-keys -t "$SESSION:$short" \
      "claude $PROJECT_FLAGS \"$PROMPT\"" \
      C-m
  fi
done

tmux select-window -t "$SESSION:master"
exec tmux attach -t "$SESSION"
