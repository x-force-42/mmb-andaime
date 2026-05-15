#!/usr/bin/env bash
# Wrapper foreground pro aquario-bridge.py.
#
# Garante venv isolado em .tooling/aquario-bridge/.venv/, instala deps
# (idempotente), executa o daemon Python com logs em
# .tooling/logs/aquario-bridge.log.
#
# Uso (manual ou via up.sh):
#   .tooling/bin/aquario-bridge.sh
#
# Mata com Ctrl-C — sem PID file (vida atrelada ao pane tmux).

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$TOOLING_DIR/aquario-bridge"
VENV_DIR="$BRIDGE_DIR/.venv"
REQS="$BRIDGE_DIR/requirements.txt"
LOG_DIR="$TOOLING_DIR/logs"
LOG="$LOG_DIR/aquario-bridge.log"

mkdir -p "$LOG_DIR"
touch "$LOG"

if [ ! -d "$VENV_DIR" ]; then
  echo "→ criando venv em $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

PY="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

# Install deps. -q quieto; idempotente (pip detecta versões já instaladas).
"$PIP" install -q -r "$REQS"

echo "→ aquario-bridge subindo (RELAY_URL=${RELAY_URL:-ws://localhost:8080/ws})"
echo "→ log: $LOG"
echo

# stdout+stderr → tela + log (tee). Não usar exec antes do pipe.
"$PY" "$TOOLING_DIR/bin/aquario-bridge.py" 2>&1 | tee -a "$LOG"
