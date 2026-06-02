#!/usr/bin/env bash
# Testes de idempotência do .tooling/bin/create-task-issue.sh (H1).
#
# Garantia: reprocessar o MESMO briefing (drain do commd após crash, ou
# re-run do orq) NÃO cria issue duplicada. A âncora mmb-cycle-key é a
# chave única (épico × projeto × created); o wrapper procura issue
# existente com essa âncora antes de chamar gh issue create.
#
# Cobre:
#   1. primeira chamada cria a issue (stdout = número)
#   2. reprocesso do mesmo briefing devolve o MESMO número, sem duplicar
#   3. briefing com cycle-key diferente (created diferente) cria nova
#      issue — a guarda não bloqueia criação legítima
#
# Estratégia: stub STATEFUL de gh (mini-GitHub) que guarda as issues
# criadas em $MMB_TEST_GH_STATE e as devolve em `gh issue list`. Assim a
# 2ª invocação enxerga a 1ª, exatamente como o GitHub real.

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/create-task-issue.sh"

SANDBOX=$(mktemp -d /tmp/mmb-cti-idem-test-XXXXXX)
mkdir -p "$SANDBOX/bin"
GH_STATE="$SANDBOX/gh-state.json"
printf '[]' > "$GH_STATE"

# ── Stub stateful de gh ──────────────────────────────────────────
# Só implementa os dois subcomandos que create-task-issue.sh usa:
#   gh issue list  --json number,body  → array JSON do estado
#   gh issue create --body-file <f>    → append no estado + ecoa URL
cat > "$SANDBOX/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="${MMB_TEST_GH_STATE:?MMB_TEST_GH_STATE não setada}"
[ -f "$STATE" ] || printf '[]' > "$STATE"

sub="${1:-} ${2:-}"
case "$sub" in
  "issue list")
    cat "$STATE"
    ;;
  "issue create")
    shift 2
    body_file=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) body_file="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    python3 - "$STATE" "$body_file" <<'PY'
import sys, json
state, body_file = sys.argv[1], sys.argv[2]
with open(state) as f:
    data = json.load(f)
with open(body_file) as f:
    body = f.read()
n = len(data) + 101            # números "realistas" (101, 102, ...)
data.append({"number": n, "body": body})
with open(state, "w") as f:
    json.dump(data, f)
print(f"https://github.com/x-force-42/mmb-cockpit/issues/{n}")
PY
    ;;
  *)
    echo "[stub gh] subcomando não suportado: '$sub'" >&2
    exit 1
    ;;
esac
STUB_EOF
chmod +x "$SANDBOX/bin/gh"

export PATH="$SANDBOX/bin:$PATH"
export MMB_TEST_GH_STATE="$GH_STATE"
export MMB_GH_OWNER="${MMB_GH_OWNER:-x-force-42}"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Cria um briefing com frontmatter válido. $1=arquivo $2=created $3=subject
make_briefing() {
  cat > "$1" <<EOF
---
from: master
to: cockpit
type: briefing
subject: ${3:-add-foo}
thread: idem-epic
created: $2
---

# Briefing de teste

Implementar coisa X.
EOF
}

count_issues() {
  python3 -c 'import sys,json; print(len(json.load(open(sys.argv[1]))))' "$GH_STATE"
}

# ── bash -n ──────────────────────────────────────────────────────
echo "── bash -n ──"
bash -n "$SCRIPT" 2>/dev/null && pass "bash -n passa" || fail "bash -n falhou"

# ── 1. primeira chamada cria issue ───────────────────────────────
echo "── 1. primeira chamada cria a issue ──"
B1="$SANDBOX/brief1.md"
make_briefing "$B1" "2026-06-01T10:00:00Z" "add-foo"
set +e
OUT1=$(bash "$SCRIPT" mmb-cockpit "$B1" 2>/dev/null); RC1=$?
set -e
[ "$RC1" = "0" ] && pass "exit 0" || fail "exit=$RC1"
[ "$OUT1" = "101" ] && pass "stdout = número da issue (101)" || fail "stdout='$OUT1' (esperado 101)"
[ "$(count_issues)" = "1" ] && pass "1 issue no estado" || fail "estado tem $(count_issues)"

# ── 2. reprocesso do MESMO briefing é idempotente ────────────────
echo "── 2. reprocesso do mesmo briefing NÃO duplica ──"
set +e
OUT2=$(bash "$SCRIPT" mmb-cockpit "$B1" 2>/dev/null); RC2=$?
set -e
[ "$RC2" = "0" ] && pass "exit 0 (idempotente)" || fail "exit=$RC2"
[ "$OUT2" = "101" ] && pass "devolve o MESMO número (101)" || fail "stdout='$OUT2' (esperado 101)"
[ "$(count_issues)" = "1" ] && pass "AINDA 1 issue (sem duplicata)" || fail "DUPLICOU: $(count_issues) issues"

# ── 3. cycle-key diferente cria issue nova ───────────────────────
echo "── 3. created diferente → cycle-key diferente → cria nova ──"
B2="$SANDBOX/brief2.md"
make_briefing "$B2" "2026-06-01T11:30:00Z" "add-bar"
set +e
OUT3=$(bash "$SCRIPT" mmb-cockpit "$B2" 2>/dev/null); RC3=$?
set -e
[ "$RC3" = "0" ] && pass "exit 0" || fail "exit=$RC3"
[ "$OUT3" = "102" ] && pass "número novo (102)" || fail "stdout='$OUT3' (esperado 102)"
[ "$(count_issues)" = "2" ] && pass "2 issues (criação legítima não bloqueada)" || fail "estado tem $(count_issues)"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
