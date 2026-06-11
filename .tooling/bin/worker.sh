#!/usr/bin/env bash
# Worker stateless do MMB — processa UMA mensagem do inbox e morre.
#
# Invocado por commd.sh quando uma nova mensagem aparece em
# .tooling/inbox/<dest>/. Cada worker é um processo curto:
#
#   1. Carrega profile do papel (master.md ou project-orchestrator.md)
#      como --append-system-prompt.
#   2. Anexa um "stateless rider" instruindo o agente sobre o
#      ciclo de vida de um worker.
#   3. Dispara `claude -p` com o user prompt apontando pra mensagem.
#   4. Output (stdout+stderr) vai pra .tooling/logs/workers/<dest>.log.
#
# Uso (manual ou via commd):
#   worker.sh <dest> <inbox-file>
#
#   <dest>        master | cockpit | aquarium | logger
#   <inbox-file>  caminho absoluto pra arquivo de mensagem
#
# Concorrência: commd serializa via flock por destinatário antes
# de invocar. Worker não toma lock próprio.

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/lib/heartbeat.sh"  # H4: liveness por PID (funções puras)

# Eager load: surface registry inválido antes de qualquer dispatch.
mmb_targets_load || {
  echo "ERRO: registry de targets inválido (ver stderr acima). Abortando." >&2
  exit 2
}

DEST="${1:-}"
INBOX_FILE="${2:-}"

if [ -z "$DEST" ] || [ -z "$INBOX_FILE" ]; then
  echo "Uso: $0 <dest> <inbox-file>" >&2
  exit 1
fi

if [ ! -f "$INBOX_FILE" ]; then
  echo "ERRO: inbox-file não existe: $INBOX_FILE" >&2
  exit 2
fi

# CWD e profile por papel.
# `master` é role (não target) e fica hardcoded. Targets de projeto vêm
# do registry declarativo em .tooling/targets.json — adicionar novo target
# = editar o JSON apenas. PR 1B: worker.sh é o primeiro consumidor.
case "$DEST" in
  master)
    CWD="$MMB_ROOT"
    # B2A v0.8+: worker-master usa profile dedicado, não o profile do
    # Mestre interativo. Stateless rider continua sendo apendado pra
    # reforçar que esta invocação é descartável (1 mensagem, morre).
    PROFILE="$TOOLING_DIR/profiles/master-worker.md"
    LAYER="master"
    ;;
  *)
    if ! mmb_target_exists "$DEST"; then
      echo "ERRO: dest inválido: $DEST (não é 'master' nem aparece em targets.json)" >&2
      exit 2
    fi
    CWD=$(mmb_target_path "$DEST")
    PROFILE="$TOOLING_DIR/profiles/$(mmb_target_field "$DEST" worker_profile)"
    LAYER=$(mmb_target_field "$DEST" agent_layer)
    ;;
esac

if [ ! -f "$PROFILE" ]; then
  echo "ERRO: profile não existe: $PROFILE" >&2
  exit 2
fi

# Log path por destino
LOG_DIR="$TOOLING_DIR/logs/workers"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${DEST}.log"

# ─── Heartbeat (B1.2 — andaime-fortification-v08) ────────────────
# Sub-processo de fundo atualiza mtime de state/heartbeat-<dest>.txt
# enquanto claude estiver produzindo output (log com mtime recente).
# Se claude pendurar (sem output novo por > MMB_HEARTBEAT_LOG_WINDOW
# segundos), heartbeat congela — commd watchdog detecta staleness >
# MMB_WATCHDOG_STALE_SECONDS (default 90s) e mata o worker, liberando
# o flock do dest. Sem isso, um worker travado segura todas as
# próximas mensagens daquele dest até o timeout duro (600s) expirar.
#
# Janela de log de 120s (Fix 2b do #4 — 2026-05-16): claude -p tem
# latência de finalização *pós-output* (cleanup interno, fim de
# stream) que pode passar de 60s em workers stateless. Com janela
# de 60s, o heartbeat congelava após o último token e o watchdog
# matava antes do processo retornar limpo — gerando eventos
# `kind=worker-watchdog-kill` no journal mesmo com trabalho útil
# já concluído. Janela de 120s cobre essa latência sem mascarar
# travamento real (watchdog ainda dispara aos 90s sobre o heartbeat).
#
# H4 (2c — IMPLEMENTADO): liveness por PID real da invocação, não só
# mtime do log. O subshell que dispara o `claude -p` (abaixo) grava o PID
# em state/heartbeat-<dest>.pid; heartbeat_tick consulta a lib pura
# mmb_heartbeat_alive (bin/lib/heartbeat.sh), que usa `kill -0` no PID
# como sinal PRIMÁRIO — claude vivo porém silencioso mantém o heartbeat
# fresco e o watchdog do commd não o mata. O mtime do log permanece como
# FALLBACK pra quando o PID não está disponível (race de startup etc.).
# Trade-off consciente: um worker travado-mas-vivo deixa de ser morto aos
# ~90s pelo watchdog; passa a ser limitado pelo timeout duro de
# MMB_WORKER_TIMEOUT (600s). É correto — "silencioso" != "travado", e o
# único sinal sólido de "travado vivo" seria progresso reportado, que é
# justamente a fonte do falso-positivo que o H4 elimina.
: "${MMB_HEARTBEAT_LOG_WINDOW:=120}"
HEARTBEAT_FILE="$TOOLING_DIR/state/heartbeat-${DEST}.txt"
mkdir -p "$TOOLING_DIR/state"
: > "$HEARTBEAT_FILE"

# PID da invocação Claude (H4). Escrito pelo subshell que dispara o
# `claude -p`. Pode ser o PID do `timeout` que envelopa o claude — vide
# nota em bin/lib/heartbeat.sh; aceitável porque o timeout vive enquanto
# o claude vive. O rm -f de partida neutraliza um .pid remanescente de
# uma invocação anterior morta a kill (cujo heartbeat_tick também já
# morreu), pra que o nosso heartbeat_tick nunca leia um PID stale.
CLAUDE_PID_FILE="$TOOLING_DIR/state/heartbeat-${DEST}.pid"
rm -f "$CLAUDE_PID_FILE"

heartbeat_tick() {
  while sleep 15; do
    # Parent worker.sh já saiu (ex.: morto pelo watchdog via SIGTERM)?
    # Limpe os arquivos de estado e encerre. Belt-and-suspenders pro caso
    # de kill: sob `pkill -f worker.sh` o próprio heartbeat_tick costuma
    # morrer junto (mesmo argv), mas se sobreviver ele faz o cleanup que
    # o trap EXIT do pai não rodou.
    if ! kill -0 $$ 2>/dev/null; then
      rm -f "$HEARTBEAT_FILE" "$CLAUDE_PID_FILE"
      exit 0
    fi
    # H4: liveness por PID (primário) com fallback pro mtime do log.
    mmb_heartbeat_tick_once "$CLAUDE_PID_FILE" "$LOG" "$MMB_HEARTBEAT_LOG_WINDOW" "$HEARTBEAT_FILE"
  done
}

heartbeat_tick &
HEARTBEAT_PID=$!

cleanup_heartbeat() {
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  rm -f "$HEARTBEAT_FILE" "$CLAUDE_PID_FILE"
}

# ─── Agent registry pro worker stateless (logger-model-tracking) ──
# Workers stateless ficam registrados durante a invocação pra que
# o mmb-logger possa capturar o `model` resolvido do agente naquele
# ciclo. ID inclui PID pra evitar colisão com o orq vivo (master
# interativo registrado por up.sh) e entre invocações concorrentes
# de destinos diferentes. spawn + deregister em pares; consumidor
# (mmb-logger) trata como evento efêmero.
WORKER_AGENT_ID="${DEST}-w-$$"
case "$LAYER" in
  master)  MODEL_ID="$MMB_MODEL_MASTER" ;;
  project) MODEL_ID="$MMB_MODEL_PROJECT_ORCHESTRATOR" ;;
  *)       MODEL_ID="" ;;
esac
"$TOOLING_DIR/bin/agents.sh" register \
  "$WORKER_AGENT_ID" commd commd "" "" "$MODEL_ID" >/dev/null 2>&1 || true

cleanup_worker() {
  cleanup_heartbeat
  "$TOOLING_DIR/bin/agents.sh" deregister \
    "$WORKER_AGENT_ID" worker-end >/dev/null 2>&1 || true
}
trap cleanup_worker EXIT

# Flags do claude conforme camada
CLAUDE_FLAGS=$(mmb_claude_flags "$LAYER")

# Stateless rider — apendado ao profile. Sobrescreve premissas de
# "sessão viva" pra reduzir confusão do agente sobre o que ele é.
STATELESS_RIDER=$(cat <<'EOF'

---

# WORKER STATELESS (v0.3+) — override de modo

Você está rodando como worker invocado pelo commd. **Atenção:**

1. **Esta invocação processa UMA mensagem do inbox e morre.** Não
   há próximo turn pra você — quando seu output termina, o processo
   acaba.
2. **Você NÃO tem polling.** Seções de "polling-on-every-turn" e
   "supervision tick" no profile pertencem ao modo antigo (sessão
   viva). Ignore.
3. **Você NÃO tem heartbeat.** Agent registry / heartbeats são pra
   atômicos, não pra você.
4. **Memória entre invocações vive fora de você:**
   - GitHub (issues, PRs, comments)
   - `/MMB/.tooling/inbox/<dest>/` (mensagens passadas — leia se
     contexto histórico for relevante)
   - `/MMB/.tooling/intents/<date>-<slug>/` (briefings + status)
   - `/MMB/.tooling/logs/journal.jsonl` (eventos estruturados)
5. **Não tente "esperar" por algo** (resposta de outro agente,
   timer, etc.). Faça o que dá pra fazer agora e saia.
6. **Quando terminar, escreva 2-5 linhas de resumo via stdout.**
   Vai pro log de worker (`logs/workers/<dest>.log`) e o Rick lê
   no tmux pane.
7. **Conversa com outros agentes ainda é via `msg.sh`** — só lembre
   que o destinatário também é um worker stateless (ou o Mestre
   interativo).
EOF
)

# Monta o append-system-prompt completo (profile + rider).
# claude --append-system-prompt aceita string única.
APPEND_PROMPT="$(cat "$PROFILE")
$STATELESS_RIDER"

# User prompt — direto ao ponto.
USER_PROMPT=$(cat <<EOF
Mensagem nova no seu inbox: $INBOX_FILE

Leia o arquivo (frontmatter + body), identifique o type, e
processe conforme seu papel. Quando terminar, escreva 2-5 linhas
de resumo do que fez.

CWD: $(pwd)
Worker ID: $DEST-$$
EOF
)

# Cabeçalho no log pra delimitar invocações
{
  echo
  echo "================================================================"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] worker $DEST pid=$$"
  echo "  msg:    $INBOX_FILE"
  echo "  model:  $(echo "$CLAUDE_FLAGS" | grep -oE 'claude-[a-z0-9-]+' || echo "?")"
  echo "  cwd:    $CWD"
  echo "================================================================"
} >> "$LOG"

# Dispara claude -p. Output append no log. cwd via subshell.
# Envelopado em `timeout`: claude pendurado segura o flock do dest no
# commd e bloqueia todas as próximas mensagens. SIGTERM com grace de
# 30s, depois SIGKILL. Exit 124 (TERM bem-sucedido) ou 137 (após KILL)
# significam timeout — logamos diferente pro bridge/jq classificar.
(
  cd "$CWD"
  # MMB_TAB pra que msg.sh (se chamado de dentro) saiba o remetente
  export MMB_TAB="$DEST"
  export MMB_AGENT_ID="$DEST-$$"
  # H4: dispara em background pra capturar o PID da invocação e gravá-lo
  # pro heartbeat_tick consultar via `kill -0`. $! é o PID do `timeout`
  # (envelope) — vive enquanto o claude vive, então responde fielmente
  # "invocação em andamento?" (ver bin/lib/heartbeat.sh). O `wait` no fim
  # preserva o exit code (124/137 de timeout, ou o rc do claude) — exit
  # code do subshell idêntico ao comportamento pré-H4.
  # shellcheck disable=SC2086
  timeout --signal=TERM --kill-after=30s "${MMB_WORKER_TIMEOUT}s" \
    claude -p "$USER_PROMPT" \
      $CLAUDE_FLAGS \
      --append-system-prompt "$APPEND_PROMPT" \
      --output-format text \
      2>&1 &
  _claude_pid=$!
  # Falha de escrita do .pid degrada pro fallback (mtime), não mata o worker.
  echo "$_claude_pid" > "$CLAUDE_PID_FILE" 2>/dev/null || true
  wait "$_claude_pid"
) >> "$LOG" || {
  EXIT=$?
  if [ "$EXIT" = "124" ] || [ "$EXIT" = "137" ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] worker $DEST TIMEOUT after ${MMB_WORKER_TIMEOUT}s" >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] worker $DEST EXIT=$EXIT" >> "$LOG"
  fi
  exit $EXIT
}

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] worker $DEST DONE" >> "$LOG"
