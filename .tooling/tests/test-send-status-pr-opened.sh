#!/usr/bin/env bash
# Testes do .tooling/bin/send-status-pr-opened.sh (B1.1).
#
# Wrapper obrigatório que substitui chamada manual de msg.sh pra
# status:pr-aberto-N. Critério de aceite: contrato impossível de
# descumprir, mesmo se o claude do worker tentar improvisar.
#
# Cobre:
#   1. happy path (suite verde via override) — body bate schema
#   2. validações fail-fast: repo inválido, pr-number não-positivo,
#      issue-number não-positivo, suite-status inválido, args faltando
#   3. auto-detect de suite_status via gh stub (verde / ausente)
#   4. estado compartilhado: msg.sh é chamado e gera entry no inbox
#   5. fail-loud se gh CLI indisponível (cai pra ausente, não verde)

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/send-status-pr-opened.sh"

SANDBOX=$(mktemp -d /tmp/mmb-send-status-test-XXXXXX)
mkdir -p "$SANDBOX/bin" "$SANDBOX/inbox/master"
INBOX="$SANDBOX/inbox/master"

# Stub do msg.sh: captura args + grava entry no inbox falso, sem
# tocar tmux nem o inbox real.
cat > "$SANDBOX/bin/msg.sh" <<'STUB_EOF'
#!/usr/bin/env bash
# stub de msg.sh pros testes
INBOX_DIR="${MMB_TEST_INBOX:-/tmp}"
TO="$1" TYPE="$2" SUBJECT="$3" BODY_FILE="$4" THREAD="${5:-}"
TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
FILE="$INBOX_DIR/${TS}_X_${TYPE}_${SUBJECT}.md"
{
  echo "---"
  echo "from: cockpit"
  echo "to: $TO"
  echo "type: $TYPE"
  echo "subject: $SUBJECT"
  echo "thread: $THREAD"
  echo "---"
  if [ "$BODY_FILE" = "-" ]; then cat; else cat "$BODY_FILE"; fi
} > "$FILE"
echo "[stub] msg.sh: gravou $FILE" >&2
STUB_EOF
chmod +x "$SANDBOX/bin/msg.sh"

# Stub do gh CLI: comportamento controlado por env MMB_TEST_GH_BODY.
cat > "$SANDBOX/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
# stub de gh pros testes — só implementa "pr view ... --json body -q .body"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  # MMB_TEST_GH_BODY controla o retorno:
  #   "verde" → body com ## Suíte verde
  #   "vermelha" → body sem
  #   "fail" → exit != 0 (simula gh quebrado)
  #   default → vazio
  case "${MMB_TEST_GH_BODY:-empty}" in
    verde) echo "## Suíte verde\n\nlinha1\nlinha2" ;;
    vermelha) echo "## algumas coisas\n\nsem suite info" ;;
    fail) exit 1 ;;
    *) echo "" ;;
  esac
fi
STUB_EOF
chmod +x "$SANDBOX/bin/gh"

# Substitui PATH para stubs serem encontrados antes do gh real.
# Mantém binários do sistema (ls, cat, etc) disponíveis.
export PATH="$SANDBOX/bin:$PATH"
export MMB_TEST_INBOX="$INBOX"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run() {
  # Wrapper resolve TOOLING_DIR via BASH_SOURCE — força msg.sh stub
  # via MMB_MSG_SH env override (PATH não funciona pq script chama
  # msg.sh por caminho absoluto).
  MMB_GH_OWNER="${MMB_GH_OWNER:-x-force-42}" \
  MMB_MSG_SH="$SANDBOX/bin/msg.sh" \
    bash "$SCRIPT" "$@"
}

reset_inbox() {
  rm -f "$INBOX"/*.md 2>/dev/null || true
}

# Helper: pega último arquivo gerado no inbox.
last_inbox_file() {
  ls -t "$INBOX"/*.md 2>/dev/null | head -1
}

# ── 1. bash -n + happy path ──────────────────────────────────────

section_lint() {
  echo "── bash -n ──"
  bash -n "$SCRIPT" 2>/dev/null && pass "bash -n passa" || fail "bash -n falhou"
}

section_happy_path_verde() {
  echo "── happy path: --suite-status verde ──"
  reset_inbox
  local out rc
  set +e
  out=$(run cockpit 42 17 ex-thread --suite-status verde 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"

  local file
  file=$(last_inbox_file)
  [ -n "$file" ] && pass "msg.sh chamado (entry gerada no inbox)" || { fail "msg.sh não chamou"; return; }

  grep -q "subject: pr-aberto-42" "$file" && pass "subject pr-aberto-42" || fail "subject errado"
  grep -q "thread: ex-thread" "$file" && pass "thread preservada" || fail "thread errada"
  grep -q "pr_url: https://github.com/x-force-42/mmb-cockpit/pull/42" "$file" && pass "pr_url completo" || fail "pr_url errado"
  grep -q "pr_number: 42" "$file" && pass "pr_number presente" || fail "pr_number faltou"
  grep -q "issue_number: 17" "$file" && pass "issue_number presente" || fail "issue_number faltou"
  grep -q "suite_status: verde" "$file" && pass "suite_status verde explícito" || fail "suite_status errado"
}

# ── 2. Validações fail-fast ─────────────────────────────────────

section_validation_failures() {
  echo "── validações fail-fast ──"
  local rc

  # repo inválido
  set +e; run banana 1 1 t --suite-status verde >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: repo inválido" || fail "repo inválido: exit=$rc"

  # pr-number 0
  set +e; run cockpit 0 1 t --suite-status verde >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: pr-number=0" || fail "pr=0: exit=$rc"

  # pr-number negativo
  set +e; run cockpit -- -1 1 t --suite-status verde >/dev/null 2>&1; rc=$?; set -e
  # (-- pra parar parsing de flags antes do -1)
  [ "$rc" = "1" ] && pass "exit 1: pr-number negativo" || fail "pr negativo: exit=$rc"

  # pr-number não-numérico
  set +e; run cockpit abc 1 t --suite-status verde >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: pr-number não-numérico" || fail "pr não-num: exit=$rc"

  # issue-number 0
  set +e; run cockpit 1 0 t --suite-status verde >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: issue-number=0" || fail "issue=0: exit=$rc"

  # suite-status inválido
  set +e; run cockpit 1 1 t --suite-status amarelo >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "2" ] && pass "exit 2: suite-status inválido" || fail "suite-status inválido: exit=$rc"

  # args faltando
  set +e; run cockpit >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: args faltando" || fail "args faltando: exit=$rc"

  # arg posicional extra
  set +e; run cockpit 1 1 t extra --suite-status verde >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: arg posicional extra" || fail "arg extra: exit=$rc"

  # flag desconhecida
  set +e; run --inventada cockpit 1 1 t >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] && pass "exit 1: flag desconhecida" || fail "flag desconhecida: exit=$rc"
}

# ── 3. Auto-detect de suite_status via gh stub ──────────────────

section_auto_detect_verde() {
  echo "── auto-detect: gh body com '## Suíte verde' → verde ──"
  reset_inbox
  MMB_TEST_GH_BODY=verde run cockpit 100 50 t-verde >/dev/null 2>&1
  local file=$(last_inbox_file)
  grep -q "suite_status: verde" "$file" && pass "auto-detect=verde" || fail "auto-detect falhou"
}

section_auto_detect_ausente_body_sem_suite() {
  echo "── auto-detect: gh body sem '## Suíte verde' → ausente ──"
  reset_inbox
  MMB_TEST_GH_BODY=vermelha run cockpit 101 51 t-vermelha >/dev/null 2>&1
  local file=$(last_inbox_file)
  grep -q "suite_status: ausente" "$file" && pass "auto-detect=ausente (body sem marker)" || fail "auto-detect falhou"
}

section_auto_detect_ausente_gh_falhou() {
  echo "── auto-detect: gh falha → ausente (honesto, não 'verde') ──"
  reset_inbox
  MMB_TEST_GH_BODY=fail run cockpit 102 52 t-fail >/dev/null 2>&1
  local file=$(last_inbox_file)
  grep -q "suite_status: ausente" "$file" && pass "gh-fail → ausente honestamente" || fail "gh-fail vazou 'verde'"
}

# ── 4. Override de suite_status manda ────────────────────────────

section_override_wins_over_auto_detect() {
  echo "── --suite-status sobrescreve auto-detect ──"
  reset_inbox
  # Mesmo com gh dizendo verde, override pulada deve vencer.
  MMB_TEST_GH_BODY=verde run cockpit 200 60 t --suite-status pulada >/dev/null 2>&1
  local file=$(last_inbox_file)
  grep -q "suite_status: pulada" "$file" && pass "override vence auto-detect" || fail "auto-detect vazou"
}

# ── Runner ───────────────────────────────────────────────────────

section_lint
section_happy_path_verde
section_validation_failures
section_auto_detect_verde
section_auto_detect_ausente_body_sem_suite
section_auto_detect_ausente_gh_falhou
section_override_wins_over_auto_detect

echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
