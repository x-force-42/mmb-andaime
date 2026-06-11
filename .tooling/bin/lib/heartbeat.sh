#!/usr/bin/env bash
# Liveness do worker stateless por PID real da invocação Claude (H4).
#
# Funções puras (sem efeito colateral além de um `touch` explícito sobre
# o arquivo passado). Extraídas pra testabilidade em isolamento — testes
# em .tooling/tests/test-heartbeat.sh sourceiam este arquivo e exercitam
# cada função.
#
# Não roda nada quando sourceado. Self-test rápido:
#   bash .tooling/bin/lib/heartbeat.sh --self-test
#
# ── CONTEXTO (H4 — débito 2c) ─────────────────────────────────────
# Antes do H4 o heartbeat do worker dependia SÓ do mtime do log: claude
# vivo porém silencioso (cleanup pós-output, tool call longo, qualquer
# silêncio > MMB_HEARTBEAT_LOG_WINDOW) congelava o heartbeat e o watchdog
# do commd matava um worker que estava vivo — gerando worker-watchdog-kill
# sobre trabalho útil. O H4 usa o PID real da invocação como sinal
# PRIMÁRIO de liveness; o mtime do log vira FALLBACK pra quando o PID
# não está disponível (ex.: race de startup, ou caller sem PID).
#
# ── NOTA SOBRE O PID ──────────────────────────────────────────────
# O PID gravado pelo worker.sh pode ser o PID do processo `timeout` que
# envelopa o `claude -p`, NÃO necessariamente o PID do `claude` direto.
# Pro H4 isso é aceitável e correto: o contrato é "existe uma invocação
# Claude em andamento?", e o `timeout` vive EXATAMENTE enquanto o comando
# protegido (claude) vive — ele sai assim que o claude sai (ou quando o
# próprio timeout dispara o kill). Logo `kill -0 <pid>` responde fielmente
# à pergunta de liveness da invocação, seja o pid do timeout ou do claude.
#
# ── API ───────────────────────────────────────────────────────────
#   mmb_heartbeat_alive <pid_file> <log_file> <window_seconds>
#     Exit 0 se o worker deve ser considerado VIVO (heartbeat a refrescar);
#     1 caso contrário. Não imprime nada. Regra (ordem importa):
#       1. <pid_file> existe com PID inteiro positivo e `kill -0` responde
#          → 0 (VIVO, mesmo sem output recente — PID VENCE mtime stale).
#       2. <pid_file> existe com PID positivo que NÃO responde a kill -0
#          → 1 (MORTO — NÃO cai no fallback; PID presente é autoritativo).
#       3. <pid_file> ausente, vazio ou com conteúdo não-numérico → FALLBACK:
#          vivo (0) sse <log_file> existe e (now - mtime) < window_seconds
#          (= comportamento pré-H4, compatível).
#
#   mmb_heartbeat_tick_once <pid_file> <log_file> <window_seconds> <hb_file>
#     Toca <hb_file> (atualiza o mtime que o watchdog do commd consome)
#     sse mmb_heartbeat_alive. SEMPRE retorna 0 — seguro de chamar dentro
#     do loop de fundo do worker mesmo sob `set -e`.

mmb_heartbeat_alive() {
  local pid_file="${1:-}" log_file="${2:-}" window="${3:-120}"
  local pid

  # (1)+(2) Sinal primário: PID real da invocação. Presente e válido é
  # autoritativo — vivo OU morto, não cai no fallback.
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      if kill -0 "$pid" 2>/dev/null; then
        return 0   # VIVO — vence mtime stale (critério central do H4)
      fi
      return 1     # PID presente mas morto → NÃO mantém heartbeat
    fi
    # pid_file existe mas vazio/lixo/0 → cai no fallback abaixo (seguro).
  fi

  # (3) Fallback pré-H4: heurística por mtime do log.
  if [ -f "$log_file" ]; then
    local now log_mod
    now=$(date +%s)
    log_mod=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
    if [ "$((now - log_mod))" -lt "$window" ]; then
      return 0
    fi
  fi
  return 1
}

mmb_heartbeat_tick_once() {
  local pid_file="${1:-}" log_file="${2:-}" window="${3:-120}" hb_file="${4:-}"
  if mmb_heartbeat_alive "$pid_file" "$log_file" "$window"; then
    [ -n "$hb_file" ] && touch "$hb_file" 2>/dev/null || true
  fi
  return 0
}

# ── self-test (só quando invocado direto com --self-test) ─────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = "--self-test" ]; then
    set -u
    _st_tmp=$(mktemp -d)
    _st_fail=0
    _ok()   { printf '  ✓ %s\n' "$1"; }
    _bad()  { printf '  ✗ %s\n' "$1"; _st_fail=1; }

    # processo vivo de longa duração
    sleep 60 & _alive=$!
    # processo já morto
    ( exit 0 ) & _dead=$!; wait "$_dead" 2>/dev/null || true

    log="$_st_tmp/log"; pidf="$_st_tmp/pid"

    # PID vivo + log ausente → vivo
    rm -f "$log"; echo "$_alive" > "$pidf"
    mmb_heartbeat_alive "$pidf" "$log" 120 && _ok "PID vivo + log ausente → vivo" || _bad "PID vivo + log ausente"
    # PID vivo + log stale → vivo (PID vence mtime)
    : > "$log"; touch -d "600 seconds ago" "$log"
    mmb_heartbeat_alive "$pidf" "$log" 120 && _ok "PID vivo + log stale → vivo" || _bad "PID vivo + log stale"
    # PID morto + log fresco → morto (PID autoritativo, não cai no fallback)
    echo "$_dead" > "$pidf"; : > "$log"
    mmb_heartbeat_alive "$pidf" "$log" 120 && _bad "PID morto + log fresco devia ser morto" || _ok "PID morto + log fresco → morto"
    # sem PID + log fresco → fallback vivo
    rm -f "$pidf"; : > "$log"
    mmb_heartbeat_alive "$pidf" "$log" 120 && _ok "sem PID + log fresco → fallback vivo" || _bad "sem PID + log fresco"
    # sem PID + log stale → fallback morto
    touch -d "600 seconds ago" "$log"
    mmb_heartbeat_alive "$pidf" "$log" 120 && _bad "sem PID + log stale devia ser morto" || _ok "sem PID + log stale → fallback morto"
    # pid vazio → fallback
    : > "$pidf"; : > "$log"
    mmb_heartbeat_alive "$pidf" "$log" 120 && _ok "pid vazio + log fresco → fallback vivo" || _bad "pid vazio fallback"

    kill "$_alive" 2>/dev/null || true
    rm -rf "$_st_tmp"
    [ "$_st_fail" = 0 ] && { echo "ok"; exit 0; } || { echo "FALHOU"; exit 1; }
  else
    cat >&2 <<EOF
Este arquivo é um lib de funções pra ser sourceado por worker.sh.
Pra rodar self-test:
  bash $0 --self-test
EOF
    exit 1
  fi
fi
