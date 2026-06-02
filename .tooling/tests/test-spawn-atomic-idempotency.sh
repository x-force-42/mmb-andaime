#!/usr/bin/env bash
# Testes de idempotência do spawn-atomic.sh (H3b).
#
# Sob retry/reprocessamento (orq re-despachado pelo retry-budget do H3),
# spawn-atomic pode ser chamado de novo pra MESMA task. A guarda (chave =
# AGENT_ID <repo-short>-<task-id>, consultada via agents.sh status +
# cross-check do pane no tmux) decide:
#   C1  sem atômico vivo → procede o spawn normal (não bloqueia)
#   C2  atômico vivo + pane existe → reusa, exit 0, NÃO spawna de novo
#   C3  registry diz vivo mas pane sumiu (zumbi) → falha alto (exit 5)
#
# Hermético: stubs de agents.sh (via MMB_AGENTS_SH), tmux e gh (via PATH).
# Usa o target real mmb-cockpit só pra validação read-only do registry; a
# guarda sai (C2/C3) ou para no gh issue-view (C1) ANTES de qualquer
# escrita no repo real. Sem GitHub, sem tmux real, sem claude.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$TOOLING_DIR/bin/spawn-atomic.sh"

SANDBOX=$(mktemp -d /tmp/mmb-spawn-idem-XXXXXX)
mkdir -p "$SANDBOX/bin"
AGENTS_CALLS="$SANDBOX/agents-calls.txt"; : > "$AGENTS_CALLS"
TMUX_CALLS="$SANDBOX/tmux-calls.txt"; : > "$TMUX_CALLS"

# ── Stub agents.sh (via MMB_AGENTS_SH, não PATH — spawn chama por caminho) ──
cat > "$SANDBOX/agents-stub.sh" <<'STUB_EOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
echo "$cmd $*" >> "$MMB_TEST_AGENTS_CALLS"
case "$cmd" in
  status)
    id="${1:-}"
    case "${MMB_TEST_AGENT_EV:-none}" in
      none) exit 3 ;;   # não encontrado
      *)    printf '{"ts":"2026-06-02T00:00:00Z","ev":"spawn","id":"%s","parent":"cockpit","pane":"%%99","task":"T1"}\n' "$id" ;;
    esac
    ;;
  register) exit 0 ;;
  *)        exit 0 ;;
esac
STUB_EOF
chmod +x "$SANDBOX/agents-stub.sh"

# ── Stub tmux (PATH) ──────────────────────────────────────────────
cat > "$SANDBOX/bin/tmux" <<'STUB_EOF'
#!/usr/bin/env bash
echo "$*" >> "$MMB_TEST_TMUX_CALLS"
case "${1:-}" in
  has-session) exit 0 ;;
  list-panes)  [ "${MMB_TEST_PANE_EXISTS:-0}" = "1" ] && exit 0 || exit 1 ;;
  new-window|split-window) echo "%fakepane" ;;   # -P -F devolve pane-id
  *) exit 0 ;;
esac
STUB_EOF
chmod +x "$SANDBOX/bin/tmux"

# ── Stub gh (PATH) — só issue view importa (caminho C1) ───────────
cat > "$SANDBOX/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf '%s\ttask,project:mmb-cockpit,epic:test-epic\tTest title\n' "${MMB_TEST_ISSUE_STATE:-CLOSED}"
  exit 0
fi
exit 0
STUB_EOF
chmod +x "$SANDBOX/bin/gh"

export PATH="$SANDBOX/bin:$PATH"
export MMB_TEST_AGENTS_CALLS="$AGENTS_CALLS"
export MMB_TEST_TMUX_CALLS="$TMUX_CALLS"
export MMB_AGENTS_SH="$SANDBOX/agents-stub.sh"
export TMUX="fake-socket,1,0"               # força o caminho que de fato spawna
export MMB_GH_OWNER="${MMB_GH_OWNER:-x-force-42}"

failures=0; ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

OUT=""; RC=0
run() {
  : > "$AGENTS_CALLS"; : > "$TMUX_CALLS"
  OUT=$(bash "$SCRIPT" mmb-cockpit T1 42 2>&1); RC=$?
}
agents_called()   { grep -q "$1" "$AGENTS_CALLS"; }
tmux_called()     { grep -q "$1" "$TMUX_CALLS"; }

echo "── bash -n ──"
bash -n "$SCRIPT" 2>/dev/null && pass "spawn-atomic.sh: bash -n passa" || fail "bash -n falhou"

# ── C1: sem atômico vivo → procede (não bloqueia) ─────────────────
echo "── C1: sem atômico vivo → spawn procede ──"
export MMB_TEST_AGENT_EV=none MMB_TEST_PANE_EXISTS=0 MMB_TEST_ISSUE_STATE=CLOSED
run
# Com agents status=não-encontrado, a guarda não dispara; o script segue
# e para no gh issue-view (CLOSED → exit 3). Isso prova que a guarda
# deixou passar (1ª execução procede normalmente).
[ "$RC" = "3" ] && pass "C1: passou da guarda (parou no issue-view, rc=3)" || fail "C1: rc=$RC (esperado 3)"
printf '%s' "$OUT" | grep -q "Validando issue" && pass "C1: chegou no issue-view (procedeu)" || fail "C1: não chegou no issue-view"
printf '%s' "$OUT" | grep -q "já vivo" && fail "C1: reusou indevidamente" || pass "C1: não reusou"
printf '%s' "$OUT" | grep -q "zumbi" && fail "C1: marcou zumbi indevidamente" || pass "C1: não marcou zumbi"
agents_called "register" && fail "C1: registrou sem spawnar" || pass "C1: register não chamado (parou antes)"

# ── C2: atômico vivo + pane existe → reusa (exit 0) ───────────────
echo "── C2: vivo consistente → reusa, sem duplicar ──"
export MMB_TEST_AGENT_EV=live MMB_TEST_PANE_EXISTS=1 MMB_TEST_ISSUE_STATE=CLOSED
run
[ "$RC" = "0" ] && pass "C2: exit 0 (reuso controlado)" || fail "C2: rc=$RC (esperado 0)"
printf '%s' "$OUT" | grep -q "já vivo" && pass "C2: reportou reuso ('já vivo')" || fail "C2: não reportou reuso"
agents_called "status cockpit-T1" && pass "C2: consultou agents status cockpit-T1" || fail "C2: não consultou status"
agents_called "register" && fail "C2: registrou duplicata" || pass "C2: register NÃO chamado (sem duplicata)"
tmux_called "list-panes" && pass "C2: cross-check do pane feito" || fail "C2: não checou pane"
{ tmux_called "new-window" || tmux_called "split-window"; } && fail "C2: spawnou 2º atômico" || pass "C2: NÃO spawnou de novo"

# ── C3: registry diz vivo mas pane sumiu → falha alto (exit 5) ────
echo "── C3: zumbi (vivo no registry, pane sumiu) → falha alto ──"
export MMB_TEST_AGENT_EV=live MMB_TEST_PANE_EXISTS=0 MMB_TEST_ISSUE_STATE=CLOSED
run
[ "$RC" = "5" ] && pass "C3: exit 5 (falha explícita)" || fail "C3: rc=$RC (esperado 5)"
printf '%s' "$OUT" | grep -q "zumbi" && pass "C3: reportou estado zumbi" || fail "C3: não reportou zumbi"
printf '%s' "$OUT" | grep -q "deregister" && pass "C3: deu remediação (deregister)" || fail "C3: sem remediação"
agents_called "register" && fail "C3: registrou apesar do zumbi" || pass "C3: register NÃO chamado"
{ tmux_called "new-window" || tmux_called "split-window"; } && fail "C3: spawnou sobre zumbi" || pass "C3: NÃO spawnou (falhou alto)"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
