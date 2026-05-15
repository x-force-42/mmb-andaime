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
JOURNAL_LOG="$LOG_DIR/journal.jsonl"
JOURNAL_LOCK="$LOG_DIR/.journal.lock"

mkdir -p "$STATE_DIR" "$LOG_DIR/workers"
[ -f "$JOURNAL_LOG" ] || : > "$JOURNAL_LOG"

# Cria inboxes + subdirs de lifecycle idempotente. Subdirs começam
# com "." para não competir com .lock/.gitkeep no top-level e para
# que find -name '.*' não as confunda com mensagens.
for d in master core cockpit aquarium; do
  mkdir -p "$INBOX_BASE/$d" \
           "$INBOX_BASE/$d/.processing" \
           "$INBOX_BASE/$d/.done" \
           "$INBOX_BASE/$d/.dead"
done

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$COMMD_LOG"
}

# Append JSONL no journal compartilhado. Eventos prefixados commd-*
# para o bridge (e log.sh consumers) ignorarem — bridge só lê
# event=pr-opened. Falha silenciosa se flock timeout: journaling
# nunca deve quebrar dispatch.
#
# Uso: journal <event> <dest> <basename> [key=val ...]
#   key=val: extras numéricos (ex.: exit_code=124, timeout_seconds=1200).
journal() {
  local event="$1" dest="$2" basename="$3"
  shift 3
  local ts json
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # pid = commd ($$). Worker pid vive no header de logs/workers/<dest>.log.
  json=$(printf '{"ts":"%s","event":"%s","dest":"%s","file":"%s","pid":%d' \
    "$ts" "$event" "$dest" "$basename" "$$")
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    json+=$(printf ',"%s":%s' "$key" "$val")
  done
  json+='}'
  (
    flock --timeout 5 9 || exit 0
    printf '%s\n' "$json" >> "$JOURNAL_LOG"
  ) 9>>"$JOURNAL_LOCK" || true
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
  journal commd-dispatch "$dest" "$basename"

  # Lock por destinatário; worker roda em background dentro do lock.
  # Outros eventos pra outros destinos seguem em paralelo.
  local lock="$STATE_DIR/worker-${dest}.lock"
  (
    flock 9

    # Claim: move pra .processing/ DENTRO do lock — assim duas mensagens
    # pro mesmo dest enfileiram corretamente, e crash entre dispatch e
    # fim do worker deixa o arquivo identificável em .processing/.
    # Se o arquivo já estiver lá (drain após crash), pula a mv.
    working_file="$file"
    if [[ "$file" != "$INBOX_BASE/$dest/.processing/"* ]]; then
      working_file="$INBOX_BASE/$dest/.processing/$basename"
      if ! mv "$file" "$working_file" 2>/dev/null; then
        log "claim FAILED dest=$dest file=$basename (source missing?)"
        exit 0
      fi
      journal commd-claim "$dest" "$basename"
    fi

    rc=0
    "$TOOLING_DIR/bin/worker.sh" "$dest" "$working_file" || rc=$?

    if [ "$rc" -eq 0 ]; then
      mv "$working_file" "$INBOX_BASE/$dest/.done/$basename" 2>/dev/null || true
      journal commd-done "$dest" "$basename"
      journal commd-worker-done "$dest" "$basename"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      mv "$working_file" "$INBOX_BASE/$dest/.dead/$basename" 2>/dev/null || true
      journal commd-dead "$dest" "$basename"
      journal commd-worker-timeout "$dest" "$basename" "timeout_seconds=$MMB_WORKER_TIMEOUT"
      log "worker TIMEOUT (rc=$rc) dest=$dest file=$basename"
    else
      mv "$working_file" "$INBOX_BASE/$dest/.dead/$basename" 2>/dev/null || true
      journal commd-dead "$dest" "$basename"
      journal commd-worker-exit "$dest" "$basename" "exit_code=$rc"
      log "worker exit-code=$rc dest=$dest file=$basename"
    fi
  ) 9>>"$lock" &
}

run_foreground() {
  # Pré-checks
  if ! command -v inotifywait >/dev/null 2>&1; then
    echo "ERRO: inotifywait não encontrado. Instale com: sudo apt install inotify-tools" >&2
    exit 1
  fi

  # Single-instance via flock em fd persistente no próprio pid file.
  # O lock vive no fd 200 enquanto o daemon roda; kernel libera no
  # fechamento do fd em qualquer morte (TERM/KILL/OOM/segfault). Isso
  # elimina:
  #   (a) stale pid file — importa quem segura o lock, não o conteúdo
  #   (b) pid recycling fooling-around — não dependemos de kill -0 pid
  #   (c) simultaneous start race — flock -n é atômico no kernel
  # `>>` abre sem truncar: protege o conteúdo caso outro daemon já
  # segure o lock e o nosso open chegue primeiro só pra falhar no flock.
  exec 200>>"$PID_FILE"
  if ! flock -n 200; then
    existing=$(cat "$PID_FILE" 2>/dev/null || echo "?")
    echo "ERRO: commd já está rodando (pid=$existing). Use 'commd.sh stop' antes." >&2
    exit 1
  fi
  # Lock adquirido: agora seguro sobrescrever o pid file com o nosso pid.
  echo $$ > "$PID_FILE"

  cleanup() {
    trap '' EXIT INT TERM  # re-entrancy: 2º sinal durante o handler
    log "shutdown..."
    # Mata workers em background (subshells com flock). Mensagens em
    # curso ficam em .processing/ e drain do próximo start retoma.
    # inotifywait não aparece em `jobs -p` (process substitution) —
    # morre via SIGPIPE quando o fd da read pipe fecha no exit.
    jobs -p | xargs -r kill 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 0
  }
  trap cleanup EXIT INT TERM

  log "================================================================"
  log "commd iniciado (pid=$$ mode=$MMB_MODE)"
  log "  watching: $INBOX_BASE/{master,core,cockpit,aquarium}/"
  log "  logs:     $LOG_DIR/workers/<dest>.log"
  log "================================================================"

  # Drain inicial: processa mensagens que estavam no inbox antes do
  # daemon subir. Duas fontes, nesta ordem:
  #   1) inbox/<dest>/.processing/* — claims órfãos de crash anterior.
  #   2) inbox/<dest>/*              — mensagens cruas nunca dispatchadas.
  # Listagem explícita por subdir (não depende do filtro -name '.*' p/
  # excluir os subdirs de lifecycle), maxdepth=1 em cada.
  log "drain inicial..."
  local count=0
  for d in master core cockpit aquarium; do
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      dispatch "$f"
      count=$((count + 1))
    done < <(find "$INBOX_BASE/$d/.processing" -maxdepth 1 -type f 2>/dev/null | sort)
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      dispatch "$f"
      count=$((count + 1))
    done < <(find "$INBOX_BASE/$d" -maxdepth 1 -type f 2>/dev/null | sort)
  done
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
