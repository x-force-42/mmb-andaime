#!/usr/bin/env bash
# smoke — canário do andaime MMB.
#
# Modos:
#   light      — sandbox isolado, mock claude, valida C1-C6 (rápido)
#   medium     — sandbox isolado, falhas controladas e recovery
#   stress     — sandbox isolado, volume e concorrência (demorado)
#   bridge     — unit test das regexes do aquario-bridge (sem sandbox)
#   hardening  — light + medium + bridge (CI / validação pré-push)
#   comm       — canal ponta-a-ponta (requer commd vivo + claude real)
#   aquario    — canal + bridge WS (requer bridge + relay)
#
# Uso:
#   smoke.sh [light|medium|stress|hardening|comm|aquario]
#   smoke.sh         # alias pra 'comm'
#
# Os modos light/medium/stress/hardening criam um sandbox temporário
# em /tmp/mmb-smoke-XXXXXX com cópias dos scripts e um mock do `claude`
# CLI — não tocam o andaime real (inbox/state/logs reais).
#
# Verde light/medium → pipeline + hardening (C1-C6) OK.
# Vermelho → diagnóstico no log do sandbox (mensagem indica o path).
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

cmd_aquario() {
  echo "================================================================"
  echo " SMOKE — modo: aquario | RELAY_URL: ${RELAY_URL:-ws://localhost:8080/ws}"
  echo "================================================================"

  # Precisa do venv do bridge pro cliente Python escutar o relay
  local venv_py="$TOOLING_DIR/aquario-bridge/.venv/bin/python"
  if [ ! -x "$venv_py" ]; then
    echo "FAIL: venv do bridge não existe ($venv_py)"
    echo "       Suba o bridge ao menos uma vez pra criar:"
    echo "       $TOOLING_DIR/bin/aquario-bridge.sh"
    exit 2
  fi
  echo "✓ venv bridge presente"

  # Precisa do bridge vivo
  if ! pgrep -f 'aquario-bridge\.py' >/dev/null; then
    echo "FAIL: aquario-bridge.py não está rodando."
    echo "       Suba via $TOOLING_DIR/bin/aquario-bridge.sh"
    echo "       (ou abra a tab 'bridge' do tmux: tmux select-window -t mmb:bridge)"
    exit 2
  fi
  echo "✓ bridge vivo"

  # Cliente WS Python efêmero: conecta, escuta, sai quando vê born
  local listener_log
  listener_log=$(mktemp)
  local listener_pid
  "$venv_py" - <<'PYEOF' > "$listener_log" 2>&1 &
import asyncio, json, os, sys
import websockets

URL = os.environ.get("RELAY_URL", "ws://localhost:8080/ws")

async def main():
    try:
        async with websockets.connect(URL) as ws:
            print(f"listener: connected to {URL}", flush=True)
            while True:
                raw = await asyncio.wait_for(ws.recv(), timeout=60)
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                print(f"got: {raw}", flush=True)
                if (msg.get("type") == "event"
                    and msg.get("kind") == "born"
                    and (msg.get("name") or "").startswith("[W] worker-")):
                    print("MATCH: worker born", flush=True)
                    return
    except asyncio.TimeoutError:
        print("FAIL: timeout 60s sem 'born'", flush=True)
        sys.exit(1)
    except Exception as e:
        print(f"FAIL: {type(e).__name__}: {e}", flush=True)
        sys.exit(2)

asyncio.run(main())
PYEOF
  listener_pid=$!
  echo "✓ listener Python rodando (pid=$listener_pid)"

  # Dá um sopro pro listener conectar antes de gerar evento
  sleep 2

  # Dispara um briefing trivial (reuso smoke comm body)
  local ts thread brief intent_dir
  ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  thread="smoke-aquario-$ts"
  intent_dir="$TOOLING_DIR/intents/${ts}-smoke-aquario"
  mkdir -p "$intent_dir"
  brief="$intent_dir/master-briefing.md"
  cat > "$brief" <<EOF
# Smoke aquario briefing — $ts

> Briefing canônico do smoke aquario. Não é trabalho real.
> Você (worker stateless) só precisa NASCER (que já fez ao ser invocado)
> e MANDAR UM STATUS curto pro master pra terminar com exit 0.

## O que fazer

\`\`\`bash
echo "smoke aquario ok | worker=\$MMB_AGENT_ID | ts=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
  | /MMB/.tooling/bin/msg.sh master status smoke-aquario-ok - $thread
\`\`\`

Depois saia.
EOF
  echo "✓ briefing gerado: $brief"

  echo "→ dispatching..."
  MMB_TAB=master "$TOOLING_DIR/bin/msg.sh" core briefing smoke-aquario "$brief" "$thread" \
    || { echo "FAIL: msg.sh"; kill "$listener_pid" 2>/dev/null; exit 2; }

  # Aguarda o listener (foi pra background); timeout do listener é 60s
  echo "→ aguardando listener (timeout 60s no Python)..."
  if wait "$listener_pid"; then
    echo "================================================================"
    echo " SMOKE AQUARIO PASS"
    echo "================================================================"
    tail -5 "$listener_log" | sed 's/^/  /'
    rm -f "$listener_log"
    return 0
  else
    echo "================================================================"
    echo " SMOKE AQUARIO FAIL"
    echo "================================================================"
    echo "Listener output:"
    cat "$listener_log" | sed 's/^/  /'
    rm -f "$listener_log"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────
# HARDENING SUITE — smoke tests da mensageria com sandbox isolado.
#
# Categorias (subcomandos light/medium/stress/hardening):
#   - cada categoria cria um sandbox temporário em /tmp/mmb-smoke-XXX/
#   - cópias de commd.sh/worker.sh/msg.sh/config.sh rodam contra esse
#     sandbox, com PATH apontando pra um mock do `claude` CLI
#   - nada toca o andaime real (inbox/state/logs reais)
#
# Layout do sandbox (deliberadamente difere do spec original que
# pedia "$SANDBOX/bin/": worker.sh deriva CWD via
# $(dirname TOOLING_DIR)/mmb-<dest>, então TOOLING_DIR precisa estar
# DENTRO de um dir que também contenha stubs mmb-*; senão o `cd`
# do worker falha e o happy path não passa):
#
#   $SANDBOX/
#     tooling/                 ← TOOLING_DIR efetivo
#       bin/{commd,worker,msg}.sh
#       config.sh
#       profiles/{master,project-orchestrator}.md   ← stubs
#       inbox/<dest>/{,.processing,.done,.dead}/
#       state/                 ← commd.pid + worker-*.lock
#       logs/journal.jsonl + workers/<dest>.log
#     mock-bin/claude          ← mock controlado por $SANDBOX/mock-ctrl
#     mmb-core, mmb-cockpit, mmb-aquarium   ← stubs para CWD
#     tmp/                     ← body files dos testes
# ──────────────────────────────────────────────────────────────────

SANDBOX=""
_SANDBOX_TOOLING=""
_SANDBOX_COMMD_PID=""
_SANDBOX_PARASITE_PID=""

_pass() { echo "  ✓ $1"; }
_fail() { echo "  FAIL: $1"; exit 1; }

_assert() {
  local msg="$1" expr="$2"
  if eval "$expr"; then
    _pass "$msg"
  else
    _fail "$msg"
  fi
}

# _wait_for_file <path> <timeout_s>
# Poll a cada 1s até existir, ou timeout. 0=achou, 1=timeout.
_wait_for_file() {
  local path="$1" timeout_s="${2:-10}"
  local i=0
  while (( i < timeout_s )); do
    [[ -e "$path" ]] && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

# _count_files <dir1> [dir2 ...]
# Soma arquivos regulares NÃO ocultos no top-level de cada dir.
# Dirs ausentes contam 0.
_count_files() {
  local total=0 d c
  for d in "$@"; do
    if [[ -d "$d" ]]; then
      c=$(find "$d" -maxdepth 1 -type f -not -name '.*' 2>/dev/null | wc -l)
      total=$((total + c))
    fi
  done
  echo "$total"
}

# _check_journal_events <sandbox_tooling_dir> <event1> [event2 ...]
# Valida que todos os eventos listados aparecem em logs/journal.jsonl.
# Usa jq se disponível, senão python3.
_check_journal_events() {
  local sb="$1"; shift
  local jpath="$sb/logs/journal.jsonl"
  if [[ ! -f "$jpath" ]]; then
    _fail "journal não encontrado: $jpath"
  fi
  if command -v jq >/dev/null 2>&1; then
    local e
    for e in "$@"; do
      if jq -r '.event' "$jpath" 2>/dev/null | grep -qx "$e"; then
        _pass "journal: $e"
      else
        _fail "journal: evento '$e' ausente"
      fi
    done
  else
    if ! python3 - "$jpath" "$@" <<'PYEOF'
import json, sys
path = sys.argv[1]
needed = sys.argv[2:]
got = set()
with open(path) as f:
    for line in f:
        try:
            got.add(json.loads(line.strip()).get("event", ""))
        except Exception:
            pass
missing = [e for e in needed if e not in got]
if missing:
    for e in missing:
        print(f"  FAIL: journal: evento '{e}' ausente")
    sys.exit(1)
for e in needed:
    print(f"  ✓ journal: {e}")
PYEOF
    then
      exit 1
    fi
  fi
}

# Cria $SANDBOX/mock-bin/claude. Comportamento:
#   $SANDBOX/mock-ctrl ausente → echo $MOCK_CLAUDE_OUTPUT; exit $MOCK_CLAUDE_EXIT
#   $SANDBOX/mock-ctrl presente → sleep 999 (simula worker pendurado)
_mock_claude_install() {
  cat > "$SANDBOX/mock-bin/claude" <<'EOF'
#!/usr/bin/env bash
# Mock do `claude` CLI usado pelos smoke tests.
if [[ -f "${SANDBOX:-/nonexistent}/mock-ctrl" ]]; then
  sleep 999
fi
echo "${MOCK_CLAUDE_OUTPUT:-mock claude: ok}"
exit "${MOCK_CLAUDE_EXIT:-0}"
EOF
  chmod +x "$SANDBOX/mock-bin/claude"
}

_sandbox_setup() {
  # Se já temos um sandbox vivo de uma categoria anterior, derruba primeiro.
  if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then
    _sandbox_teardown
  fi

  bash -n "$TOOLING_DIR/bin/commd.sh"
  bash -n "$TOOLING_DIR/bin/worker.sh"
  bash -n "$TOOLING_DIR/bin/msg.sh"

  SANDBOX=$(mktemp -d /tmp/mmb-smoke-XXXXXX)
  export SANDBOX
  _SANDBOX_TOOLING="$SANDBOX/tooling"
  _SANDBOX_COMMD_PID=""
  _SANDBOX_PARASITE_PID=""

  mkdir -p \
    "$_SANDBOX_TOOLING/bin" \
    "$_SANDBOX_TOOLING/profiles" \
    "$_SANDBOX_TOOLING/state" \
    "$_SANDBOX_TOOLING/logs/workers" \
    "$SANDBOX/mock-bin" \
    "$SANDBOX/tmp" \
    "$SANDBOX/mmb-core" \
    "$SANDBOX/mmb-cockpit" \
    "$SANDBOX/mmb-aquarium"

  local d
  for d in master core cockpit aquarium; do
    mkdir -p "$_SANDBOX_TOOLING/inbox/$d/.processing" \
             "$_SANDBOX_TOOLING/inbox/$d/.done" \
             "$_SANDBOX_TOOLING/inbox/$d/.dead"
  done

  cp "$TOOLING_DIR/bin/commd.sh"  "$_SANDBOX_TOOLING/bin/"
  cp "$TOOLING_DIR/bin/worker.sh" "$_SANDBOX_TOOLING/bin/"
  cp "$TOOLING_DIR/bin/msg.sh"    "$_SANDBOX_TOOLING/bin/"
  chmod +x "$_SANDBOX_TOOLING/bin/"*.sh
  cp "$TOOLING_DIR/config.sh" "$_SANDBOX_TOOLING/"

  echo "# stub" > "$_SANDBOX_TOOLING/profiles/master.md"
  echo "# stub" > "$_SANDBOX_TOOLING/profiles/project-orchestrator.md"

  : > "$_SANDBOX_TOOLING/logs/journal.jsonl"

  _mock_claude_install
}

_sandbox_teardown() {
  if [[ -n "${_SANDBOX_COMMD_PID:-}" ]]; then
    kill "$_SANDBOX_COMMD_PID" 2>/dev/null || true
  fi
  if [[ -n "${_SANDBOX_PARASITE_PID:-}" ]]; then
    kill "$_SANDBOX_PARASITE_PID" 2>/dev/null || true
  fi
  if [[ -n "${_SANDBOX_TOOLING:-}" ]] && [[ -f "$_SANDBOX_TOOLING/state/commd.pid" ]]; then
    kill "$(cat "$_SANDBOX_TOOLING/state/commd.pid")" 2>/dev/null || true
  fi
  if [[ -n "${SANDBOX:-}" ]]; then
    pkill -f "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
  SANDBOX=""
  _SANDBOX_TOOLING=""
  _SANDBOX_COMMD_PID=""
  _SANDBOX_PARASITE_PID=""
}

# Sobe commd em background dentro do sandbox. Garante PATH com mock,
# MMB_MODE=fast, e exporta SANDBOX para o mock reconhecer.
# Polla até o pid file conter o PID do daemon recém-iniciado (não um
# valor stale escrito antes do start, como em M5/M6) e o processo vivo.
_sandbox_start_commd() {
  export SANDBOX
  PATH="$SANDBOX/mock-bin:$PATH" \
  MMB_MODE=fast \
  "$_SANDBOX_TOOLING/bin/commd.sh" fg >> "$_SANDBOX_TOOLING/logs/commd.log" 2>&1 &
  _SANDBOX_COMMD_PID=$!
  local i=0 pid=""
  while (( i < 5 )); do
    if [[ -f "$_SANDBOX_TOOLING/state/commd.pid" ]]; then
      pid=$(cat "$_SANDBOX_TOOLING/state/commd.pid" 2>/dev/null || echo "")
      if [[ "$pid" == "$_SANDBOX_COMMD_PID" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 1
    i=$((i+1))
  done
  _fail "commd não inicializou em 5s (pid_file=$pid expected=$_SANDBOX_COMMD_PID; log: $_SANDBOX_TOOLING/logs/commd.log)"
}

# _sandbox_send_msg <to> <subject> <body_content>
# Escolhe MMB_TAB automaticamente para nunca colidir com 'to' (guardrail
# do msg.sh: from != to).
_sandbox_send_msg() {
  local to="$1" subject="$2" body_content="$3"
  local from="master"
  [[ "$to" == "master" ]] && from="core"
  echo "$body_content" > "$SANDBOX/tmp/${subject}.md"
  MMB_TAB="$from" "$_SANDBOX_TOOLING/bin/msg.sh" "$to" briefing "$subject" \
    "$SANDBOX/tmp/${subject}.md" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# cmd_light: L1-L5
# ──────────────────────────────────────────────────────────────────
cmd_light() {
  echo "================================================================"
  echo " SMOKE — light (sandbox isolado, validação C1-C6)"
  echo "================================================================"

  _sandbox_setup
  trap '_sandbox_teardown' EXIT

  local inbox_core="$_SANDBOX_TOOLING/inbox/core"

  # ─── L1: daemon lifecycle ─────────────────────────
  echo
  echo "── L1: daemon lifecycle ──"
  _sandbox_start_commd
  local status_out
  status_out=$("$_SANDBOX_TOOLING/bin/commd.sh" status 2>&1 || true)
  if echo "$status_out" | grep -q "RUNNING"; then
    _pass "commd status RUNNING"
  else
    _fail "commd status sem RUNNING: $status_out"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  if [[ -f "$_SANDBOX_TOOLING/state/commd.pid" ]]; then
    _fail "pid file não foi removido após stop"
  fi
  _pass "stop removeu pid file"
  if kill -0 "$_SANDBOX_COMMD_PID" 2>/dev/null; then
    _fail "commd ainda vivo após stop (pid=$_SANDBOX_COMMD_PID)"
  fi
  _pass "processo morto após stop"
  _SANDBOX_COMMD_PID=""

  # ─── L2: msg.sh recusa sem commd ──────────────────
  echo
  echo "── L2: msg.sh recusa sem commd ──"
  echo "corpo de teste l2" > "$SANDBOX/tmp/body-l2.md"
  set +e
  MMB_TAB=master "$_SANDBOX_TOOLING/bin/msg.sh" core briefing test-l2 \
    "$SANDBOX/tmp/body-l2.md" >/dev/null 2>&1
  local l2_rc=$?
  set -e
  if [[ "$l2_rc" -eq 12 ]]; then
    _pass "msg.sh exit 12 sem commd"
  else
    _fail "msg.sh exit esperado 12, foi $l2_rc"
  fi
  local count
  count=$(_count_files "$inbox_core" "$inbox_core/.processing" \
                       "$inbox_core/.done" "$inbox_core/.dead")
  if [[ "$count" -eq 0 ]]; then
    _pass "inbox/core vazio (msg.sh recusou)"
  else
    _fail "inbox/core tem $count arquivos (esperado 0)"
  fi

  # ─── L3: msg.sh --allow-offline grava ─────────────
  echo
  echo "── L3: msg.sh --allow-offline grava ──"
  echo "corpo de teste l3" > "$SANDBOX/tmp/body-l3.md"
  set +e
  MMB_TAB=master "$_SANDBOX_TOOLING/bin/msg.sh" --allow-offline core briefing \
    test-l3 "$SANDBOX/tmp/body-l3.md" >/dev/null 2>"$SANDBOX/tmp/l3-stderr.txt"
  local l3_rc=$?
  set -e
  if [[ "$l3_rc" -eq 0 ]]; then
    _pass "msg.sh --allow-offline exit 0"
  else
    _fail "msg.sh --allow-offline exit esperado 0, foi $l3_rc"
  fi
  count=$(_count_files "$inbox_core")
  if [[ "$count" -ge 1 ]]; then
    _pass "inbox/core gravou arquivo offline (count=$count)"
  else
    _fail "inbox/core sem arquivo após --allow-offline"
  fi
  if grep -q "AVISO" "$SANDBOX/tmp/l3-stderr.txt"; then
    _pass "msg.sh emitiu AVISO no stderr"
  else
    _fail "msg.sh stderr não contém 'AVISO'"
  fi

  # Limpa o arquivo offline antes de L4 — senão o drain do próximo
  # commd vai processá-lo e poluir as contagens do happy path.
  rm -f "$inbox_core"/*.md 2>/dev/null || true

  # ─── L4: fluxo feliz completo ─────────────────────
  echo
  echo "── L4: fluxo feliz completo ──"
  export MMB_WORKER_TIMEOUT=10
  _sandbox_start_commd
  _sandbox_send_msg core "test-l4" "mensagem smoke L4"
  local i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  if [[ "$(_count_files "$inbox_core")" -ne 0 ]]; then
    _fail "inbox/core top-level não vazio"
  fi
  _pass "top-level vazio"
  if [[ "$(_count_files "$inbox_core/.processing")" -ne 0 ]]; then
    _fail ".processing não vazio"
  fi
  _pass ".processing vazio"
  if [[ "$(_count_files "$inbox_core/.dead")" -ne 0 ]]; then
    _fail ".dead não vazio"
  fi
  _pass ".dead vazio"
  local done_c
  done_c=$(_count_files "$inbox_core/.done")
  if [[ "$done_c" -eq 1 ]]; then
    _pass ".done = 1"
  else
    _fail ".done count esperado 1, foi $done_c"
  fi
  _check_journal_events "$_SANDBOX_TOOLING" commd-dispatch commd-claim commd-done
  unset MMB_WORKER_TIMEOUT

  # ─── L5: segunda instância recusada ────────────────
  echo
  echo "── L5: segunda instância recusada ──"
  set +e
  timeout 5 "$_SANDBOX_TOOLING/bin/commd.sh" fg \
    >> "$_SANDBOX_TOOLING/logs/commd2.log" 2>&1
  local second_rc=$?
  set -e
  if [[ "$second_rc" -ne 0 ]]; then
    _pass "segunda instância exit não-zero (rc=$second_rc)"
  else
    _fail "segunda instância exit 0 (esperado falha)"
  fi
  if grep -q "já está rodando" "$_SANDBOX_TOOLING/logs/commd2.log" \
     || grep -q "already running" "$_SANDBOX_TOOLING/logs/commd2.log"; then
    _pass "log indica instância já ativa"
  else
    _fail "log não contém indicativo de instância já ativa"
  fi

  # ─── L6: MMB_COMMD_POLL_INTERVAL=0 escape hatch ────
  # Garante que desabilitar o safety net preserva o comportamento
  # antigo: log indica "poll: desabilitado" e happy path passa.
  echo
  echo "── L6: MMB_COMMD_POLL_INTERVAL=0 escape hatch ──"
  # L4 deixou commd vivo; precisa parar pra subir um novo c/ poll=0
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  rm -f "$inbox_core"/.done/*.md "$inbox_core"/.dead/*.md \
        "$inbox_core"/.processing/*.md 2>/dev/null || true
  : > "$_SANDBOX_TOOLING/logs/commd.log"
  export MMB_WORKER_TIMEOUT=10 MMB_COMMD_POLL_INTERVAL=0
  _sandbox_start_commd
  if grep -q "poll: desabilitado" "$_SANDBOX_TOOLING/logs/commd.log"; then
    _pass "log indica 'poll: desabilitado'"
  else
    _fail "commd.log não contém 'poll: desabilitado'"
  fi
  _sandbox_send_msg core "test-l6" "happy path com poll=0"
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  done_c=$(_count_files "$inbox_core/.done")
  if [[ "$done_c" -eq 1 ]]; then
    _pass "happy path com poll=0 (.done=1)"
  else
    _fail "happy path quebrou: .done=$done_c"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT MMB_COMMD_POLL_INTERVAL

  echo
  echo "=== LIGHT PASS ==="

  _sandbox_teardown
  trap - EXIT
}

# ──────────────────────────────────────────────────────────────────
# cmd_medium: M1-M6
# ──────────────────────────────────────────────────────────────────
cmd_medium() {
  echo "================================================================"
  echo " SMOKE — medium (sandbox isolado, falhas controladas)"
  echo "================================================================"

  _sandbox_setup
  trap '_sandbox_teardown' EXIT

  local inbox_core="$_SANDBOX_TOOLING/inbox/core"
  local i

  # ─── M1: timeout do worker ────────────────────────
  echo
  echo "── M1: timeout do worker ──"
  touch "$SANDBOX/mock-ctrl"
  export MMB_WORKER_TIMEOUT=3
  _sandbox_start_commd
  _sandbox_send_msg core "test-m1" "mensagem smoke M1"
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.dead")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  local dead_c
  dead_c=$(_count_files "$inbox_core/.dead")
  if [[ "$dead_c" -eq 1 ]]; then
    _pass ".dead = 1 (timeout)"
  else
    _fail ".dead count esperado 1, foi $dead_c"
  fi
  if [[ "$(_count_files "$inbox_core/.done")" -eq 0 ]]; then
    _pass ".done vazio"
  else
    _fail ".done não vazio após timeout"
  fi
  _check_journal_events "$_SANDBOX_TOOLING" commd-dead commd-worker-timeout

  # ─── M2: recovery após timeout ────────────────────
  echo
  echo "── M2: recovery após timeout ──"
  rm -f "$SANDBOX/mock-ctrl"
  export MMB_WORKER_TIMEOUT=10
  _sandbox_send_msg core "test-m2" "mensagem smoke M2"
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  local done_c2
  done_c2=$(_count_files "$inbox_core/.done")
  if [[ "$done_c2" -ge 1 ]]; then
    _pass ".done = $done_c2 (recovery após timeout)"
  else
    _fail ".done esperado >=1, foi $done_c2"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT

  # Reset entre testes pra contagens ficarem limpas
  rm -f "$inbox_core"/.done/*.md "$inbox_core"/.dead/*.md \
        "$inbox_core"/.processing/*.md 2>/dev/null || true
  : > "$_SANDBOX_TOOLING/logs/journal.jsonl"

  # ─── M3: drain de órfão em .processing ────────────
  echo
  echo "── M3: drain de órfão em .processing ──"
  local ts orphan
  ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  orphan="$inbox_core/.processing/${ts}_master_briefing_test-m3.md"
  cat > "$orphan" <<EOF
---
from: master
to: core
type: briefing
subject: test-m3
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

mensagem órfã injetada em .processing para teste de drain
EOF
  export MMB_WORKER_TIMEOUT=10
  _sandbox_start_commd
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  local done_c3
  done_c3=$(_count_files "$inbox_core/.done")
  if [[ "$done_c3" -eq 1 ]]; then
    _pass "drain processou órfão (.done=1)"
  else
    _fail "drain falhou: .done count=$done_c3"
  fi
  if [[ "$(_count_files "$inbox_core/.processing")" -eq 0 ]]; then
    _pass ".processing vazio após drain"
  else
    _fail ".processing não vazio após drain"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT

  rm -f "$inbox_core"/.done/*.md "$inbox_core"/.dead/*.md \
        "$inbox_core"/.processing/*.md 2>/dev/null || true
  : > "$_SANDBOX_TOOLING/logs/journal.jsonl"

  # ─── M4: SIGTERM durante worker em voo ────────────
  echo
  echo "── M4: SIGTERM durante worker em voo ──"
  touch "$SANDBOX/mock-ctrl"
  export MMB_WORKER_TIMEOUT=120
  _sandbox_start_commd
  _sandbox_send_msg core "test-m4" "mensagem smoke M4"
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.processing")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  if [[ "$(_count_files "$inbox_core/.processing")" -lt 1 ]]; then
    _fail "arquivo não chegou em .processing"
  fi
  _pass "arquivo em .processing"
  local commd_pid
  commd_pid=$(cat "$_SANDBOX_TOOLING/state/commd.pid")
  kill "$commd_pid"
  i=0
  while (( i < 10 )); do
    if ! kill -0 "$commd_pid" 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  if kill -0 "$commd_pid" 2>/dev/null; then
    _fail "commd não morreu após SIGTERM"
  fi
  _pass "commd morreu após SIGTERM"
  if [[ -f "$_SANDBOX_TOOLING/state/commd.pid" ]]; then
    _fail "pid file não foi removido"
  fi
  _pass "pid file removido"
  if [[ "$(_count_files "$inbox_core/.processing")" -lt 1 ]]; then
    _fail ".processing vazio (mensagem perdida?)"
  fi
  _pass "mensagem permanece em .processing"
  pkill -f "$SANDBOX" 2>/dev/null || true
  sleep 1
  rm -f "$SANDBOX/mock-ctrl"
  export MMB_WORKER_TIMEOUT=10
  _SANDBOX_COMMD_PID=""
  _sandbox_start_commd
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge 1 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  local done_c4
  done_c4=$(_count_files "$inbox_core/.done")
  if [[ "$done_c4" -eq 1 ]]; then
    _pass "drain retomou mensagem após restart (.done=1)"
  else
    _fail ".done esperado 1, foi $done_c4"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT

  # ─── M5: stale pid file com PID morto ─────────────
  echo
  echo "── M5: stale pid file com PID morto ──"
  echo "999999" > "$_SANDBOX_TOOLING/state/commd.pid"
  _sandbox_start_commd
  local new_pid
  new_pid=$(cat "$_SANDBOX_TOOLING/state/commd.pid")
  if [[ "$new_pid" == "999999" ]]; then
    _fail "pid file ainda contém PID stale"
  fi
  _pass "pid file atualizado para novo PID ($new_pid)"
  if kill -0 "$new_pid" 2>/dev/null; then
    _pass "novo commd vivo"
  else
    _fail "novo commd não vivo (pid=$new_pid)"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""

  # ─── M6: pid file com PID vivo mas lock livre ────
  echo
  echo "── M6: pid file com PID vivo mas lock livre ──"
  sleep 9999 &
  _SANDBOX_PARASITE_PID=$!
  echo "$_SANDBOX_PARASITE_PID" > "$_SANDBOX_TOOLING/state/commd.pid"
  _sandbox_start_commd
  new_pid=$(cat "$_SANDBOX_TOOLING/state/commd.pid")
  if [[ "$new_pid" == "$_SANDBOX_PARASITE_PID" ]]; then
    _fail "pid file ainda é do parasita"
  fi
  _pass "pid file atualizado, parasita ignorado (new_pid=$new_pid)"
  if kill -0 "$new_pid" 2>/dev/null; then
    _pass "novo commd vivo"
  else
    _fail "novo commd não vivo (pid=$new_pid)"
  fi
  if kill -0 "$_SANDBOX_PARASITE_PID" 2>/dev/null; then
    _pass "parasita ainda vivo (irrelevante p/ lock)"
  else
    _fail "parasita morreu (não deveria)"
  fi
  kill "$_SANDBOX_PARASITE_PID" 2>/dev/null || true
  _SANDBOX_PARASITE_PID=""
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""

  # ─── M7: commd-poll-recovered em runtime ──────────
  # Pausa inotifywait via SIGSTOP, escreve N msgs direto no top-level,
  # aguarda 2× poll interval, retoma inotifywait. Safety net por poll
  # tem que recuperar todas as msgs sem double-claim.
  echo
  echo "── M7: commd-poll-recovered em runtime ──"
  for d in master core cockpit aquarium; do
    rm -f "$_SANDBOX_TOOLING/inbox/$d"/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.done/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.dead/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.processing/*.md 2>/dev/null || true
  done
  : > "$_SANDBOX_TOOLING/logs/journal.jsonl"

  export MMB_WORKER_TIMEOUT=10 MMB_COMMD_POLL_INTERVAL=3
  _sandbox_start_commd
  sleep 1  # deixa commd entrar no read loop

  local commd_pid inotify_pid
  commd_pid=$(cat "$_SANDBOX_TOOLING/state/commd.pid")
  inotify_pid=$(pgrep -P "$commd_pid" inotifywait | head -1)
  if [[ -z "$inotify_pid" ]]; then
    _fail "inotifywait não encontrado (commd_pid=$commd_pid)"
  fi
  _pass "inotifywait localizado (pid=$inotify_pid)"

  kill -STOP "$inotify_pid"
  _pass "inotifywait STOP"

  # Escreve 5 msgs direto no top-level (bypass msg.sh — formato compatível
  # com dispatch: non-dotfile, frontmatter pro worker stub não interfere).
  local ts
  ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  for i in $(seq 1 5); do
    cat > "$inbox_core/${ts}_test_status_m7-${i}.md" <<MSGEOF
---
from: master
to: core
type: status
subject: m7-${i}
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

m7 test ${i}
MSGEOF
  done
  local topl_before
  topl_before=$(_count_files "$inbox_core")
  if [[ "$topl_before" -eq 5 ]]; then
    _pass "5 msgs no top-level (inotify bloqueado)"
  else
    _fail "top-level=$topl_before esperado 5 (inotify pode ter escapado)"
  fi

  # Espera 2× POLL_INTERVAL (6s) + folga
  sleep 8

  kill -CONT "$inotify_pid"
  _pass "inotifywait CONT"

  # Aguarda workers terminarem
  i=0
  while (( i < 20 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge 5 ]]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done

  if [[ "$(_count_files "$inbox_core")" -eq 0 ]]; then
    _pass "top-level zerado"
  else
    _fail "top-level=$(_count_files "$inbox_core") esperado 0"
  fi
  local done_m7
  done_m7=$(_count_files "$inbox_core/.done")
  if [[ "$done_m7" -eq 5 ]]; then
    _pass ".done=5"
  else
    _fail ".done=$done_m7 esperado 5"
  fi

  local jpath="$_SANDBOX_TOOLING/logs/journal.jsonl"
  local poll_count claim_dups
  poll_count=$(python3 -c "
import json
n=0
for L in open('$jpath'):
  try:
    if json.loads(L).get('event')=='commd-poll-recovered': n+=1
  except: pass
print(n)
")
  if [[ "$poll_count" -ge 5 ]]; then
    _pass "commd-poll-recovered count=$poll_count (>=5)"
  else
    _fail "commd-poll-recovered count=$poll_count esperado >=5"
  fi
  claim_dups=$(python3 -c "
import json, collections
c=collections.Counter()
for L in open('$jpath'):
  try:
    e=json.loads(L)
    if e.get('event')=='commd-claim': c[e['file']]+=1
  except: pass
print(sum(1 for v in c.values() if v>1))
")
  if [[ "$claim_dups" -eq 0 ]]; then
    _pass "zero double-claim"
  else
    _fail "double-claim count=$claim_dups"
  fi

  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT MMB_COMMD_POLL_INTERVAL

  echo
  echo "=== MEDIUM PASS ==="

  _sandbox_teardown
  trap - EXIT
}

# ──────────────────────────────────────────────────────────────────
# cmd_stress: S1 + S6 (S2-S5 ficam como TODO)
# ──────────────────────────────────────────────────────────────────
cmd_stress() {
  echo "================================================================"
  echo " SMOKE — stress (sandbox isolado, volume e concorrência)"
  echo "================================================================"

  _sandbox_setup
  trap '_sandbox_teardown' EXIT

  local inbox_core="$_SANDBOX_TOOLING/inbox/core"
  local i elapsed

  # ─── S1: volume sequencial ─────────────────────────
  echo
  echo "── S1: volume sequencial (100 msgs) ──"
  export MMB_WORKER_TIMEOUT=10
  _sandbox_start_commd
  local n=100
  for ((i=1; i<=n; i++)); do
    _sandbox_send_msg core "seq-$(printf '%03d' $i)" "mensagem stress S1 número $i"
  done
  elapsed=0
  while (( elapsed < 120 )); do
    if [[ "$(_count_files "$inbox_core/.done")" -ge "$n" ]]; then
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  local s1_done s1_dead
  s1_done=$(_count_files "$inbox_core/.done")
  s1_dead=$(_count_files "$inbox_core/.dead")
  if [[ "$s1_done" -eq "$n" ]]; then
    _pass "$n mensagens em .done (${elapsed}s)"
  else
    _fail ".done esperado $n, foi $s1_done"
  fi
  if [[ "$s1_dead" -eq 0 ]]; then
    _pass ".dead vazio"
  else
    _fail ".dead = $s1_dead (esperado 0)"
  fi
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""

  # ─── S6: concorrência de produtores ────────────────
  echo
  echo "── S6: concorrência de produtores (20 msgs em paralelo) ──"
  local d
  for d in master core cockpit aquarium; do
    rm -f "$_SANDBOX_TOOLING/inbox/$d"/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.done/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.dead/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.processing/*.md 2>/dev/null || true
  done
  : > "$_SANDBOX_TOOLING/logs/journal.jsonl"

  export MMB_WORKER_TIMEOUT=10
  _sandbox_start_commd
  local pids=()
  for i in $(seq 1 20); do
    local dest
    dest=$(echo "master core cockpit aquarium" | tr ' ' '\n' \
           | sed -n "$((( (i-1) % 4 ) + 1))p")
    _sandbox_send_msg "$dest" "conc-$(printf '%02d' $i)" "mensagem concorrente $i" &
    pids+=("$!")
  done
  local p
  for p in "${pids[@]}"; do
    wait "$p" 2>/dev/null || true
  done

  # Freeze commd para contagem race-free: as 4 chamadas find separadas
  # senão pegam o mesmo arquivo em estados diferentes durante mv
  # top-level → .processing → .done. Parar commd suspende renames;
  # mensagens em voo ficam em .processing/ e o drain do restart retoma.
  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  i=0
  while (( i < 5 )); do
    if [[ ! -f "$_SANDBOX_TOOLING/state/commd.pid" ]] \
       && ! kill -0 "$_SANDBOX_COMMD_PID" 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  sleep 1
  _SANDBOX_COMMD_PID=""

  local total=0 idir c
  for d in master core cockpit aquarium; do
    idir="$_SANDBOX_TOOLING/inbox/$d"
    c=$(_count_files "$idir" "$idir/.processing" "$idir/.done" "$idir/.dead")
    total=$((total + c))
  done
  if [[ "$total" -eq 20 ]]; then
    _pass "20 mensagens gravadas (total=$total)"
  else
    _fail "total esperado 20, foi $total"
  fi
  local dups
  dups=$(find "$_SANDBOX_TOOLING/inbox" -name '*.md' -not -name '.*' 2>/dev/null \
         | sort | uniq -d | wc -l)
  if [[ "$dups" -eq 0 ]]; then
    _pass "sem colisão de paths"
  else
    _fail "colisões detectadas: $dups"
  fi

  # Restart commd → drain retoma o que ficou em .processing/
  _sandbox_start_commd

  elapsed=0
  while (( elapsed < 60 )); do
    local term_c=0
    for d in master core cockpit aquarium; do
      idir="$_SANDBOX_TOOLING/inbox/$d"
      c=$(_count_files "$idir/.done" "$idir/.dead")
      term_c=$((term_c + c))
    done
    if [[ "$term_c" -ge 20 ]]; then
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  local terminal=0 dead_total=0 dc
  for d in master core cockpit aquarium; do
    idir="$_SANDBOX_TOOLING/inbox/$d"
    c=$(_count_files "$idir/.done" "$idir/.dead")
    dc=$(_count_files "$idir/.dead")
    terminal=$((terminal + c))
    dead_total=$((dead_total + dc))
  done
  if [[ "$terminal" -eq 20 ]]; then
    _pass "20 em estado terminal (${elapsed}s)"
  else
    _fail "terminal esperado 20, foi $terminal"
  fi
  if [[ "$dead_total" -eq 0 ]]; then
    _pass "sem .dead (todos sucessos)"
  else
    _fail ".dead total=$dead_total (esperado 0)"
  fi

  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT

  # ─── S7: burst paralelo com poll ativo ────────────
  # 50 msgs em paralelo pra core, MMB_COMMD_POLL_INTERVAL=3. Valida
  # que com inotify normal + poll safety net, ninguém é duplicado e
  # tudo chega em estado terminal. poll-recovered>0 é informativo
  # (depende de inotify dropar evento), não obrigatório.
  echo
  echo "── S7: burst paralelo com poll ativo (50 msgs) ──"
  for d in master core cockpit aquarium; do
    rm -f "$_SANDBOX_TOOLING/inbox/$d"/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.done/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.dead/*.md \
          "$_SANDBOX_TOOLING/inbox/$d"/.processing/*.md 2>/dev/null || true
  done
  : > "$_SANDBOX_TOOLING/logs/journal.jsonl"

  export MMB_WORKER_TIMEOUT=10 MMB_COMMD_POLL_INTERVAL=3
  _sandbox_start_commd

  local s7_total=50
  local s7_pids=()
  for i in $(seq 1 "$s7_total"); do
    _sandbox_send_msg core "burst-$(printf '%03d' $i)" "burst s7 msg $i" &
    s7_pids+=("$!")
  done
  for p in "${s7_pids[@]}"; do
    wait "$p" 2>/dev/null || true
  done

  elapsed=0
  while (( elapsed < 120 )); do
    local s7_term
    s7_term=$(_count_files "$inbox_core/.done" "$inbox_core/.dead")
    if [[ "$s7_term" -ge "$s7_total" ]]; then
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if [[ "$(_count_files "$inbox_core")" -eq 0 ]]; then
    _pass "top-level zerado"
  else
    _fail "top-level=$(_count_files "$inbox_core") esperado 0 (elapsed=${elapsed}s)"
  fi
  local s7_done s7_dead
  s7_done=$(_count_files "$inbox_core/.done")
  s7_dead=$(_count_files "$inbox_core/.dead")
  if [[ $((s7_done + s7_dead)) -eq "$s7_total" ]]; then
    _pass "done+dead=$s7_total (done=$s7_done dead=$s7_dead)"
  else
    _fail "done+dead=$((s7_done+s7_dead)) esperado $s7_total"
  fi

  local jpath="$_SANDBOX_TOOLING/logs/journal.jsonl"
  local claim_total claim_dups poll_count
  claim_total=$(python3 -c "
import json
n=0
for L in open('$jpath'):
  try:
    if json.loads(L).get('event')=='commd-claim': n+=1
  except: pass
print(n)
")
  claim_dups=$(python3 -c "
import json, collections
c=collections.Counter()
for L in open('$jpath'):
  try:
    e=json.loads(L)
    if e.get('event')=='commd-claim': c[e['file']]+=1
  except: pass
print(sum(1 for v in c.values() if v>1))
")
  poll_count=$(python3 -c "
import json
n=0
for L in open('$jpath'):
  try:
    if json.loads(L).get('event')=='commd-poll-recovered': n+=1
  except: pass
print(n)
")
  if [[ "$claim_total" -eq "$s7_total" ]]; then
    _pass "commd-claim total=$s7_total"
  else
    _fail "commd-claim total=$claim_total esperado $s7_total"
  fi
  if [[ "$claim_dups" -eq 0 ]]; then
    _pass "zero double-claim"
  else
    _fail "double-claim count=$claim_dups"
  fi
  # poll-recovered é informativo: depende de inotify ter dropado eventos
  echo "  (info) commd-poll-recovered=$poll_count (não obrigatório >0)"

  "$_SANDBOX_TOOLING/bin/commd.sh" stop >/dev/null 2>&1 || true
  sleep 1
  _SANDBOX_COMMD_PID=""
  unset MMB_WORKER_TIMEOUT MMB_COMMD_POLL_INTERVAL

  # TODO S2: volume distribuído com validação de paralelismo
  # TODO S3: mistura success/error/timeout por nome de arquivo
  # TODO S4: restart no meio do volume (stop + drain + continuação)
  # TODO S5: start/stop repetido N ciclos sem pid órfão

  echo
  echo "=== STRESS PASS ==="

  _sandbox_teardown
  trap - EXIT
}

# ──────────────────────────────────────────────────────────────────
# cmd_bridge: B1 — unit test inline das regexes do aquario-bridge.
# Sem sandbox, sem venv: stub do módulo websockets antes de importar
# o aquario-bridge.py via importlib. Instancia Bridge com uma fake
# queue e injeta as 3 strings reais que worker.sh emite.
# ──────────────────────────────────────────────────────────────────
cmd_bridge() {
  echo "================================================================"
  echo " SMOKE — bridge (unit test das regexes do aquario-bridge)"
  echo "================================================================"

  python3 - "$TOOLING_DIR/bin/aquario-bridge.py" <<'PYEOF'
import sys, types, importlib.util
sys.dont_write_bytecode = True  # evita __pycache__/ ao lado do bridge

bridge_path = sys.argv[1]

# Stub do módulo websockets — bridge faz `import websockets` no topo,
# mas Bridge.__init__ não usa, então tipos vazios bastam.
ws = types.ModuleType("websockets")
ws_ex = types.ModuleType("websockets.exceptions")
class _CC(Exception): pass
ws_ex.ConnectionClosed = _CC
ws.exceptions = ws_ex
sys.modules["websockets"] = ws
sys.modules["websockets.exceptions"] = ws_ex

spec = importlib.util.spec_from_file_location("ab", bridge_path)
ab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ab)

events = []
class FakeQueue:
    def put_nowait(self, item):
        events.append(item)

bridge = ab.Bridge(FakeQueue())

# Cada cenário precisa do header de pid antes da linha terminal:
# Bridge.on_worker_log_line() só emite 'born' ao parsear pid header,
# e _finish_worker() faz FIFO pop por dest.
cases = [
    ("core",     "[ts] worker core pid=11111"),
    ("core",     "[ts] worker core DONE"),
    ("cockpit",  "[ts] worker cockpit pid=22222"),
    ("cockpit",  "[ts] worker cockpit TIMEOUT after 120s"),
    ("aquarium", "[ts] worker aquarium pid=33333"),
    ("aquarium", "[ts] worker aquarium EXIT=2"),
]
for dest, line in cases:
    bridge.on_worker_log_line(dest, line)

expected = [
    ("born",          "worker-core-11111"),
    ("died_happy",    "worker-core-11111"),
    ("born",          "worker-cockpit-22222"),
    ("died_defeated", "worker-cockpit-22222"),
    ("born",          "worker-aquarium-33333"),
    ("died_defeated", "worker-aquarium-33333"),
]

fails = []
for i, (kind, wid) in enumerate(expected):
    if i >= len(events):
        fails.append(f"event #{i} ausente (esperado kind={kind} id={wid})")
        continue
    e = events[i]
    if e.get("kind") != kind:
        fails.append(f"event #{i}: kind={e.get('kind')!r} esperado {kind!r}")
    if e.get("id") != wid:
        fails.append(f"event #{i}: id={e.get('id')!r} esperado {wid!r}")

if fails:
    for f in fails:
        print(f"  FAIL: {f}")
    sys.exit(1)

print("  ✓ DONE → died_happy")
print("  ✓ TIMEOUT after Ns → died_defeated")
print("  ✓ EXIT=N → died_defeated")
print(f"  ✓ 6/6 eventos emitidos com kind+id corretos")
PYEOF

  echo
  echo "=== BRIDGE PASS ==="
}

cmd_hardening() {
  echo "=== HARDENING: light + medium + bridge ==="
  cmd_light
  cmd_medium
  cmd_bridge
  echo "=== HARDENING PASS ==="
}

case "$MODE" in
  light)           cmd_light ;;
  medium)          cmd_medium ;;
  stress)          cmd_stress ;;
  bridge)          cmd_bridge ;;
  hardening)       cmd_hardening ;;
  comm|"")         cmd_comm ;;
  aquario)         cmd_aquario ;;
  *)
    echo "Uso: $0 [light|medium|stress|bridge|hardening|comm|aquario]" >&2
    echo "  light      — sandbox isolado, mock claude, validação C1-C6 (rápido)" >&2
    echo "  medium     — sandbox isolado, falhas controladas e recovery" >&2
    echo "  stress     — sandbox isolado, volume e concorrência (demorado)" >&2
    echo "  bridge     — unit test das regexes do aquario-bridge (sem sandbox)" >&2
    echo "  hardening  — light + medium + bridge (CI/validação pré-push)" >&2
    echo "  comm       — canal ponta-a-ponta (requer commd vivo + claude real)" >&2
    echo "  aquario    — canal + bridge WS (requer bridge + relay)" >&2
    exit 1
    ;;
esac
