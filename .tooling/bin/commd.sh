#!/usr/bin/env bash
# commd — comm daemon central do MMB.
#
# Roda foreground. Monitora .tooling/inbox/ via inotifywait;
# pra cada novo arquivo de mensagem, dispatcha um worker stateless
# (worker.sh <dest> <file>) em background, serializando por
# destinatário via flock.
#
# Uso:
#   commd.sh           # roda foreground (default — pra tmux pane)
#   commd.sh status    # mostra estado (pid vivo? workers ativos?)
#   commd.sh stop      # mata daemon pelo pid file
#
# Concorrência:
#   - 2 mensagens pro mesmo destino → workers serializados (flock).
#   - 2 mensagens pra destinos diferentes → workers paralelos.
#
# Estado:
#   - state/commd.pid       — PID do daemon vivo (atualizado no start)
#   - state/worker-<dest>.lock — flock file por destinatário
#   - logs/commd.log        — log do daemon (dispatch + erros)
#   - logs/workers/<dest>.log — output dos workers (claude -p)

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

STATE_DIR="$TOOLING_DIR/state"
LOG_DIR="$TOOLING_DIR/logs"
INBOX_BASE="$TOOLING_DIR/inbox"
PID_FILE="$STATE_DIR/commd.pid"
COMMD_LOG="$LOG_DIR/commd.log"

mkdir -p "$STATE_DIR" "$LOG_DIR/workers"

# Cria inboxes idempotente
for d in master core cockpit aquarium; do
  mkdir -p "$INBOX_BASE/$d"
done

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$COMMD_LOG"
}

cmd_status() {
  if [ ! -f "$PID_FILE" ]; then
    echo "commd: STOPPED (no pid file)"
    return 1
  fi
  local pid
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "commd: RUNNING (pid=$pid)"
    echo "Workers ativos:"
    pgrep -af 'worker\.sh' | grep -v "$0" || echo "  (nenhum)"
    return 0
  else
    echo "commd: STALE (pid=$pid não existe; removendo pid file)"
    rm -f "$PID_FILE"
    return 1
  fi
}

cmd_stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "commd: sem pid file. Nada pra matar."
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "commd: matando pid=$pid"
    kill "$pid"
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

dispatch() {
  local file="$1"
  local rel="${file#$INBOX_BASE/}"
  local dest="${rel%%/*}"
  local basename
  basename=$(basename "$file")

  # Filtros
  case "$dest" in
    master|core|cockpit|aquarium) ;;
    *) log "skip: dest desconhecido em '$file' (dest=$dest)"; return ;;
  esac
  # Arquivos ocultos = infra (.lock, .gitkeep, etc)
  case "$basename" in
    .*) return ;;
  esac
  # Só processa arquivos (não diretórios)
  [ -f "$file" ] || return

  log "dispatch: dest=$dest file=$basename"

  # Lock por destinatário; worker roda em background dentro do lock.
  # Outros eventos pra outros destinos seguem em paralelo.
  local lock="$STATE_DIR/worker-${dest}.lock"
  (
    flock 9
    "$TOOLING_DIR/bin/worker.sh" "$dest" "$file" \
      || log "worker exit-code=$? dest=$dest file=$basename"
  ) 9>>"$lock" &
}

run_foreground() {
  # Pré-checks
  if ! command -v inotifywait >/dev/null 2>&1; then
    echo "ERRO: inotifywait não encontrado. Instale com: sudo apt install inotify-tools" >&2
    exit 1
  fi

  # Pid file + cleanup
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "ERRO: commd já está rodando (pid=$old_pid). Use 'commd.sh stop' antes." >&2
      exit 1
    fi
    rm -f "$PID_FILE"
  fi
  echo $$ > "$PID_FILE"

  cleanup() {
    log "shutdown: limpando pid file"
    rm -f "$PID_FILE"
  }
  trap cleanup EXIT INT TERM

  log "================================================================"
  log "commd iniciado (pid=$$ mode=$MMB_MODE)"
  log "  watching: $INBOX_BASE/{master,core,cockpit,aquarium}/"
  log "  logs:     $LOG_DIR/workers/<dest>.log"
  log "================================================================"

  # Drain inicial: processa mensagens que estavam no inbox antes do
  # daemon subir (sessão crashou, mensagem cold, etc).
  log "drain inicial..."
  local count=0
  while IFS= read -r f; do
    dispatch "$f"
    count=$((count + 1))
  done < <(find "$INBOX_BASE" -type f -not -name '.*' 2>/dev/null | sort)
  log "drain: $count mensagem(ns) re-dispatchadas"

  # Loop principal: novo arquivo → dispatch.
  # -m: monitor (loop infinito); -e: eventos; --format '%w%f': path completo
  # Lê uma linha por evento.
  while IFS= read -r path; do
    dispatch "$path"
  done < <(
    inotifywait -m -q \
      -e create,moved_to \
      --format '%w%f' \
      "$INBOX_BASE"/master \
      "$INBOX_BASE"/core \
      "$INBOX_BASE"/cockpit \
      "$INBOX_BASE"/aquarium
  )
}

case "${1:-fg}" in
  fg|run|start) run_foreground ;;
  status)       cmd_status ;;
  stop)         cmd_stop ;;
  *)
    echo "Uso: $0 [fg|status|stop]" >&2
    exit 1
    ;;
esac
