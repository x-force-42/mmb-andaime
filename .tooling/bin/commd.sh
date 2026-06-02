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
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"

# Eager load do registry de targets (.tooling/targets.json). Aborta o
# commd antes de criar inboxes / iniciar inotify se o registry estiver
# inválido — falha cedo, log claro, em vez de comportamento esquisito
# mais tarde.
mmb_targets_load || {
  echo "ERRO: registry de targets inválido (ver stderr acima). Abortando commd." >&2
  exit 2
}

# Cache da lista de dests com padding pra word-match em case (hot path
# do dispatch). Atualiza só no startup do commd; mudanças em targets.json
# durante execução exigem restart.
_MMB_COMMD_DESTS_PADDED=" $(mmb_dests_list) "

# Paths globais. Em modo teste (_MMB_TEST_MODE=1), preserve qualquer
# valor já setado pelo caller — permite sandbox hermético sem tocar
# state/logs/inbox/journal reais. Em modo produção, sempre re-deriva
# de TOOLING_DIR (defensivo contra env leaks).
if [ "${_MMB_TEST_MODE:-0}" = "1" ]; then
  STATE_DIR="${STATE_DIR:-$TOOLING_DIR/state}"
  LOG_DIR="${LOG_DIR:-$TOOLING_DIR/logs}"
  INBOX_BASE="${INBOX_BASE:-$TOOLING_DIR/inbox}"
  PID_FILE="${PID_FILE:-$STATE_DIR/commd.pid}"
  COMMD_LOG="${COMMD_LOG:-$LOG_DIR/commd.log}"
  JOURNAL_LOG="${JOURNAL_LOG:-$LOG_DIR/journal.jsonl}"
  JOURNAL_LOCK="${JOURNAL_LOCK:-$LOG_DIR/.journal.lock}"
else
  STATE_DIR="$TOOLING_DIR/state"
  LOG_DIR="$TOOLING_DIR/logs"
  INBOX_BASE="$TOOLING_DIR/inbox"
  PID_FILE="$STATE_DIR/commd.pid"
  COMMD_LOG="$LOG_DIR/commd.log"
  JOURNAL_LOG="$LOG_DIR/journal.jsonl"
  JOURNAL_LOCK="$LOG_DIR/.journal.lock"
fi

mkdir -p "$STATE_DIR" "$LOG_DIR/workers"
[ -f "$JOURNAL_LOG" ] || : > "$JOURNAL_LOG"

# Cria inboxes + subdirs de lifecycle idempotente. Subdirs começam
# com "." para não competir com .lock/.gitkeep no top-level e para
# que find -name '.*' não as confunda com mensagens.
for d in $(mmb_dests_list); do
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
#   key=val: extras. Auto-detecta numérico vs string e quota
#   apropriadamente pra produzir JSON válido. Strings com aspas são
#   escapadas. Ex.:
#     journal commd-worker-timeout cockpit msg.md timeout_seconds=600
#       → ..."timeout_seconds":600
#     journal commd-worker-timeout cockpit msg.md sev=error epic=ux-refresh-v07
#       → ..."sev":"error","epic":"ux-refresh-v07"
journal() {
  local event="$1" dest="$2" basename="$3"
  shift 3
  local ts json
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # pid = commd ($$). Worker pid vive no header de logs/workers/<dest>.log.
  json=$(printf '{"ts":"%s","event":"%s","dest":"%s","file":"%s","pid":%d' \
    "$ts" "$event" "$dest" "$basename" "$$")
  local kv key val val_esc
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    if [[ "$val" =~ ^-?[0-9]+$ ]] || [[ "$val" =~ ^-?[0-9]+\.[0-9]+$ ]]; then
      json+=$(printf ',"%s":%s' "$key" "$val")
    else
      # String: escape aspas + backslashes pra JSON válido.
      val_esc="${val//\\/\\\\}"
      val_esc="${val_esc//\"/\\\"}"
      json+=$(printf ',"%s":"%s"' "$key" "$val_esc")
    fi
  done
  json+='}'
  (
    flock --timeout 5 9 || exit 0
    printf '%s\n' "$json" >> "$JOURNAL_LOG"
  ) 9>>"$JOURNAL_LOCK" || true
}

# Extrai 'thread:' do frontmatter da mensagem (usado como 'epic' nos
# eventos sev:error). Frontmatter é YAML simples entre ---/---; thread
# é uma chave opcional. Retorna string vazia se ausente.
extract_thread() {
  local file="$1"
  [ -f "$file" ] || { echo ""; return; }
  awk '
    BEGIN { in_fm = 0 }
    /^---[[:space:]]*$/ { in_fm = !in_fm; next }
    in_fm && /^thread:/ {
      sub(/^thread:[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$file" 2>/dev/null
}

# Gera um id único pra correlacionar eventos sev:error com resolutions
# futuras (review-cycle.sh casa por id). Timestamp + dest + suffix random.
error_id() {
  local dest="$1" kind="$2"
  printf '%s-%s-%s-%d' "$(date -u +%Y%m%dT%H%M%SZ)" "$dest" "$kind" "$RANDOM"
}

# Move uma mensagem entre subdirs de lifecycle com ESTADO HONESTO (H2).
# Em falha de mv (disco cheio, dir removido, permissão), NÃO mente: emite
# commd-move-failed (sev=error) e retorna 1. O arquivo permanece em
# .processing/ — reconcile_processing_once o recupera no próximo poll, e
# o caller NÃO deve emitir commd-done/commd-dead pra essa transição.
# Uso: move_msg <src> <dest_dir> <dest> <basename> <target_label>
move_msg() {
  local src="$1" dest_dir="$2" dest="$3" basename="$4" target_label="$5"
  if mv "$src" "$dest_dir/$basename" 2>/dev/null; then
    return 0
  fi
  journal commd-move-failed "$dest" "$basename" \
    "sev=error" "kind=move-failed" "target=$target_label"
  log "MOVE FAILED dest=$dest file=$basename target=$target_label (fica em .processing/)"
  return 1
}

# Finaliza o dispatch após o worker retornar: move a mensagem pro subdir
# de lifecycle correto conforme o rc e journaliza. Extraído de dispatch()
# (H2) pra ser testável isoladamente. Estado honesto: commd-done/-dead só
# saem se a transição real (mv) teve sucesso; senão, commd-move-failed. Os
# eventos de verdade sobre o worker (commd-worker-timeout/-exit) saem
# sempre — independem de onde o arquivo foi parar.
# Uso: finalize_dispatch <rc> <working_file> <dest> <basename>
finalize_dispatch() {
  local rc="$1" working_file="$2" dest="$3" basename="$4"
  local thread err_id err_kind
  if [ "$rc" -eq 0 ]; then
    if move_msg "$working_file" "$INBOX_BASE/$dest/.done" "$dest" "$basename" "done"; then
      journal commd-done "$dest" "$basename"
      journal commd-worker-done "$dest" "$basename"
    fi
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    # Captura thread/epic ANTES de mover o arquivo pra .dead/ (caminho muda).
    thread=$(extract_thread "$working_file")
    err_id=$(error_id "$dest" "worker-timeout")
    move_msg "$working_file" "$INBOX_BASE/$dest/.dead" "$dest" "$basename" "dead" \
      && journal commd-dead "$dest" "$basename"
    journal commd-worker-timeout "$dest" "$basename" \
      "sev=error" "kind=worker-timeout" "epic=$thread" "id=$err_id" \
      "timeout_seconds=$MMB_WORKER_TIMEOUT"
    log "worker TIMEOUT (rc=$rc) dest=$dest file=$basename"
  else
    # Distingue watchdog-kill (SIGTERM via pkill, rc=143) de outros exits.
    thread=$(extract_thread "$working_file")
    if [ "$rc" -eq 143 ]; then
      err_kind="worker-watchdog-kill"
    else
      err_kind="worker-exit"
    fi
    err_id=$(error_id "$dest" "$err_kind")
    move_msg "$working_file" "$INBOX_BASE/$dest/.dead" "$dest" "$basename" "dead" \
      && journal commd-dead "$dest" "$basename"
    journal commd-worker-exit "$dest" "$basename" \
      "sev=error" "kind=$err_kind" "epic=$thread" "id=$err_id" \
      "exit_code=$rc"
    log "worker exit-code=$rc kind=$err_kind dest=$dest file=$basename"
  fi
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
  # Normaliza path: WSL2/inotifywait às vezes corrompe leading-slash.
  # Variantes observadas em produção:
  #   "//home/..." — slash duplicado (Bug A original, fix em 804b59a)
  #   "home/..."   — leading slash dropado (Bug A v2, observado em smoke comm)
  # Sem normalizar, ${file#$INBOX_BASE/} falha e a mensagem é descartada
  # com "dest desconhecido" (dest=home). Idempotência via poll salva da
  # perda, mas o caminho rápido fica quebrado.
  [[ "$file" != /* ]] && file="/$file"
  while [[ "$file" == *"//"* ]]; do
    file="${file//\/\///}"
  done
  local rel="${file#$INBOX_BASE/}"
  local dest="${rel%%/*}"
  local basename
  basename=$(basename "$file")

  # Filtros — lista de dests vem do registry (cache _MMB_COMMD_DESTS_PADDED).
  case "$_MMB_COMMD_DESTS_PADDED" in
    *" $dest "*) ;;
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

    # B2A v0.8+: master agora é dispatchado normalmente. worker.sh
    # carrega profile master-worker.md (stateless de triagem) e
    # processa a mensagem — rotina vai pro digest, escala vai pro
    # pending-human/. Removida a entrega-direta-sem-worker antiga.

    rc=0
    "$TOOLING_DIR/bin/worker.sh" "$dest" "$working_file" || rc=$?

    # Move pro subdir de lifecycle + journaliza (estado honesto, H2).
    finalize_dispatch "$rc" "$working_file" "$dest" "$basename"
  ) 9>>"$lock" &
}

# Reconciliação periódica: safety net pra eventos de inotify perdidos
# (WSL2 sob burst). Varre apenas top-level dos 4 inboxes — nunca toca
# .processing/, .done/, .dead/ por causa do -maxdepth 1. Mensagens
# encontradas são re-dispatchadas; a claim atômica via mv-no-flock
# dentro de `dispatch` garante idempotência se inotify e poll baterem
# no mesmo arquivo.
reconcile_once() {
  local d f basename
  for d in $(mmb_dests_list); do
    while IFS= read -r -d '' f; do
      basename=$(basename "$f")
      case "$basename" in .*) continue ;; esac
      log "poll: orphan recovered dest=$d file=$basename"
      journal commd-poll-recovered "$d" "$basename"
      dispatch "$f"
    done < <(find "$INBOX_BASE/$d" -maxdepth 1 -type f -print0 2>/dev/null)
  done
}

# Sweep de órfãos frios em .processing/ (H2). Recupera mensagens presas
# em .processing/ que nenhum worker está processando — casos: (a) commd
# morreu entre o claim (mv→.processing) e o fim do worker; (b) um move
# pra .done/.dead falhou (move_msg deixou o arquivo em .processing/).
# Diferente do drain de startup, roda no poll periódico (não exige
# restart pra recuperar).
#
# Salvaguardas pra NUNCA tocar trabalho em-voo:
#   1. Pula o dest inteiro se o heartbeat estiver fresco (worker vivo) —
#      mesmo sinal que o watchdog usa.
#   2. Só considera arquivos mais velhos que MMB_WORKER_TIMEOUT + grace.
#      Acima desse teto, nenhum worker legítimo ainda estaria rodando (o
#      timeout duro do claude + kill-after já teriam disparado). Isso
#      separa o timescale do sweep (>~1320s) do watchdog (90s): eles não
#      competem pelo mesmo arquivo.
# Re-despacha via dispatch(); a claim idempotente (arquivo já em
# .processing/) garante que dispatch não re-move nem duplica.
: "${MMB_PROCESSING_SWEEP_GRACE:=120}"
reconcile_processing_once() {
  local d f basename now age f_mod hb hb_mod hb_age min_age
  now=$(date +%s)
  min_age=$((MMB_WORKER_TIMEOUT + MMB_PROCESSING_SWEEP_GRACE))
  for d in $(mmb_dests_list); do
    # Worker vivo pro dest? heartbeat fresco → não mexe em .processing/.
    hb="$STATE_DIR/heartbeat-${d}.txt"
    if [ -f "$hb" ]; then
      hb_mod=$(stat -c %Y "$hb" 2>/dev/null || echo 0)
      hb_age=$((now - hb_mod))
      [ "$hb_age" -lt "$MMB_WATCHDOG_STALE_SECONDS" ] && continue
    fi
    while IFS= read -r -d '' f; do
      basename=$(basename "$f")
      case "$basename" in .*) continue ;; esac
      f_mod=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
      age=$((now - f_mod))
      [ "$age" -lt "$min_age" ] && continue   # jovem demais — pode ter worker vivo
      log "sweep: órfão frio em .processing/ dest=$d file=$basename (idade=${age}s)"
      journal commd-processing-recovered "$d" "$basename" "age_seconds=$age"
      dispatch "$f"
    done < <(find "$INBOX_BASE/$d/.processing" -maxdepth 1 -type f -print0 2>/dev/null)
  done
}

# Watchdog (B1.2): mata workers cujo heartbeat ficou stale.
#
# worker.sh atualiza mtime de state/heartbeat-<dest>.txt enquanto claude
# produz output. Se mtime > MMB_WATCHDOG_STALE_SECONDS (default 90s),
# claude pendurou em loop interno ou tool call sem progresso. Matar libera
# o flock do dest pra próximas mensagens, sem precisar esperar o timeout
# duro do claude -p (600s) expirar.
#
# kill é via pkill -f no worker.sh — SIGTERM propaga pra `timeout` e
# `claude -p`. Worker.sh sai com rc!=0; o bloco de dispatch move pra
# .dead/ e journaliza.
: "${MMB_WATCHDOG_STALE_SECONDS:=90}"
watchdog_check() {
  local now=$(date +%s)
  local d hb hb_mod hb_age
  for d in $(mmb_dests_list); do
    hb="$STATE_DIR/heartbeat-${d}.txt"
    [ -f "$hb" ] || continue
    hb_mod=$(stat -c %Y "$hb" 2>/dev/null || echo "$now")
    hb_age=$((now - hb_mod))
    if [ "$hb_age" -gt "$MMB_WATCHDOG_STALE_SECONDS" ]; then
      log "watchdog: dest=$d heartbeat stale (${hb_age}s > ${MMB_WATCHDOG_STALE_SECONDS}s) — killing worker"
      # Em modo teste, NÃO chama pkill — workers reais não devem ser
      # atingidos por uma execução de teste. O evento e o cleanup
      # ainda são emitidos, suficientes pra verificação.
      if [ "${_MMB_TEST_MODE:-0}" != "1" ]; then
        pkill -TERM -f "worker\.sh ${d} " 2>/dev/null || true
      fi
      # Evento sev:error com id correlacionável. epic="" pois watchdog não
      # conhece a thread aqui (mensagem em .processing/ pode ter ido); o
      # commd-worker-exit subsequente carrega o epic real.
      local wd_id
      wd_id=$(error_id "$d" "watchdog-stale")
      journal commd-watchdog-kill "$d" "(watchdog)" \
        "sev=error" "kind=watchdog-stale" "id=$wd_id" "stale_seconds=$hb_age"
      # Trap de cleanup do worker remove o arquivo; defensivo se trap falhar:
      rm -f "$hb"
    fi
  done
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
    trap '' EXIT INT TERM HUP ERR  # re-entrancy: 2º sinal/erro durante o handler
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

  # ─── Instrumentação de traps (diagnóstico spontaneous-shutdown) ──
  # Cada handler captura `$?` na PRIMEIRA linha — qualquer comando antes
  # corromperia o valor. Loga origem + rc + linha; cmd é pista auxiliar
  # ($BASH_COMMAND no EXIT trap tipicamente aponta pro próprio exit).
  # Signal handlers chamam cleanup (que limpa traps e exit 0). ERR só
  # loga: deixa set -e propagar até EXIT, que então chama cleanup.
  on_signal() {
    local rc=$?
    local sig="$1"
    log "signal trapped: $sig rc=$rc line=${BASH_LINENO[0]} cmd='$BASH_COMMAND'"
    cleanup
  }
  on_err() {
    local rc=$?
    log "ERR trapped: rc=$rc line=${BASH_LINENO[0]} cmd='$BASH_COMMAND'"
  }
  on_exit() {
    local rc=$?
    log "EXIT trapped: rc=$rc cmd='$BASH_COMMAND'"
    cleanup
  }
  trap 'on_signal HUP'  HUP
  trap 'on_signal INT'  INT
  trap 'on_signal TERM' TERM
  trap on_err  ERR
  trap on_exit EXIT

  log "================================================================"
  log "commd iniciado (pid=$$ mode=$MMB_MODE)"
  local _watching_csv
  _watching_csv=$(mmb_dests_list | tr ' ' ',')
  log "  watching: $INBOX_BASE/{$_watching_csv}/"
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
  for d in $(mmb_dests_list); do
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
  #
  # Safety net: se MMB_COMMD_POLL_INTERVAL>0, usa `read -t` pra alternar
  # entre receber eventos do inotify e rodar reconcile_once a cada
  # intervalo. Em WSL2 sob burst, inotify perde eventos — o poll varre
  # top-level dos inboxes pra recuperar órfãos. Se =0, mantém
  # comportamento antigo (read bloqueante, só inotify).
  local poll_interval="${MMB_COMMD_POLL_INTERVAL:-30}"
  if [ "$poll_interval" -gt 0 ]; then
    log "poll: reconciliação periódica a cada ${poll_interval}s"
  else
    log "poll: desabilitado (MMB_COMMD_POLL_INTERVAL=0)"
  fi

  # Monta os paths de inbox/<dest>/ dinamicamente a partir do registry.
  # `mmb_dests_list` já inclui `master` como role fixa.
  local INOTIFY_PATHS=()
  local _d
  for _d in $(mmb_dests_list); do
    INOTIFY_PATHS+=("$INBOX_BASE/$_d")
  done

  local path="" rc=0
  while :; do
    if [ "$poll_interval" -gt 0 ]; then
      rc=0
      IFS= read -r -t "$poll_interval" path || rc=$?
    else
      rc=0
      IFS= read -r path || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      [ -n "$path" ] && dispatch "$path"
    elif [ "$rc" -gt 128 ]; then
      # Timeout do read -t → safety net.
      reconcile_once
      watchdog_check
      reconcile_processing_once
    else
      # EOF: pipe do inotifywait fechou (processo morreu / SIGPIPE).
      log "inotifywait pipe fechou (rc=$rc); reconciliação final e saída"
      reconcile_once
      break
    fi
  done < <(
    inotifywait -m -q \
      -e create,moved_to \
      --format '%w%f' \
      "${INOTIFY_PATHS[@]}"
  )
}

# Guard: dispatch só roda quando commd.sh é invocado direto, não quando
# sourceado (ex.: pelos testes em .tooling/tests/test-commd-journal.sh).
# Sem isso, sourcing dispararia run_foreground e o teste nunca retornaria.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-fg}" in
    fg|run|start) run_foreground ;;
    status)       cmd_status ;;
    stop)         cmd_stop ;;
    *)
      echo "Uso: $0 [fg|status|stop]" >&2
      exit 1
      ;;
  esac
fi
