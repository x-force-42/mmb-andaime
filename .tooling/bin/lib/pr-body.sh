#!/usr/bin/env bash
# Funções de construção do body do PR aberto pelo atômico via open-pr.sh.
#
# Funções puras (sem efeito colateral além de stdout). Extraídas pra
# testabilidade em isolamento — testes em .tooling/tests/test-pr-body.sh
# sourceiam este arquivo e exercitam cada função.
#
# Não roda nada quando sourceado. Pode rodar self-test se invocado direto:
#   bash .tooling/bin/lib/pr-body.sh --self-test
#
# ── API ──────────────────────────────────────────────────────────
#   mmb_validate_subissue_format <value>
#     Exit 0 se <value> é número inteiro positivo (1+); 1 caso contrário.
#     Não imprime nada — caller decide a mensagem de erro.
#
#   mmb_validate_suite_output <file>
#     Exit 0 se <file> existe, não-vazio, e >= MMB_SUITE_MIN_BYTES (default
#     100); != 0 caso contrário (1=arg vazio, 2=arquivo ausente, 3=vazio,
#     4=abaixo do mínimo). Não imprime — caller decide mensagem.
#     Threshold é anti-gaming (`echo > /tmp/x` cria arquivo mas inútil).
#
#   mmb_build_pr_body <subissue> <commits-list> <worktree-name> <suite-output-file>
#     Imprime no stdout o body do PR com:
#       - `## O que mudou` (commits-list)
#       - `## Suíte verde` (conteúdo de suite-output-file, em bloco code-fenced)
#       - `Closes #<subissue>` em `## Origem`
#     <suite-output-file> deve ter passado por mmb_validate_suite_output.

: "${MMB_SUITE_MIN_BYTES:=100}"

mmb_validate_subissue_format() {
  local v="${1:-}"
  [[ "$v" =~ ^[1-9][0-9]*$ ]]
}

mmb_validate_suite_output() {
  local f="${1:-}"
  [ -n "$f" ] || return 1
  [ -f "$f" ] || return 2
  [ -s "$f" ] || return 3
  local size
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  [ "$size" -ge "${MMB_SUITE_MIN_BYTES:-100}" ] || return 4
}

mmb_build_pr_body() {
  local subissue="$1"
  local commits_list="$2"
  local worktree_name="$3"
  local suite_output_file="$4"

  # Trunca em ~4KB pra não inflar o body além do limite de PR do GitHub
  # (65536 chars). Suíte muito grande: revisor pede full no comment.
  local suite_content suite_size suite_note=""
  suite_content=$(head -c 4096 "$suite_output_file" 2>/dev/null)
  suite_size=$(stat -c %s "$suite_output_file" 2>/dev/null || echo 0)
  if [ "$suite_size" -gt 4096 ]; then
    suite_note=$'\n\n*(truncado em 4KB — original tem '"$suite_size"$' bytes; peça full no comment se necessário)*'
  fi

  cat <<EOF
## O que mudou

$commits_list

## Suíte verde

\`\`\`
$suite_content
\`\`\`$suite_note

## Origem

Closes #$subissue

---
🤖 PR aberto via \`.tooling/bin/open-pr.sh\` pelo Agente Atômico (worktree: \`$worktree_name\`).
EOF
}

# Self-test mínimo se chamado direto. Não roda quando sourceado.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--self-test" ]; then
    echo "self-test pr-body.sh"

    # subissue
    mmb_validate_subissue_format 42 && echo "  ✓ accepts 42" || { echo "  ✗ rejected 42"; exit 1; }
    mmb_validate_subissue_format "" && { echo "  ✗ accepted empty"; exit 1; } || echo "  ✓ rejects empty"
    mmb_validate_subissue_format "abc" && { echo "  ✗ accepted abc"; exit 1; } || echo "  ✓ rejects abc"

    # suite output validation
    mmb_validate_suite_output "" && { echo "  ✗ accepted empty arg"; exit 1; } || echo "  ✓ rejects empty arg"
    mmb_validate_suite_output "/nonexistent" && { echo "  ✗ accepted missing"; exit 1; } || echo "  ✓ rejects missing file"

    tf=$(mktemp)
    : > "$tf"
    mmb_validate_suite_output "$tf" && { echo "  ✗ accepted empty file"; rm "$tf"; exit 1; } || echo "  ✓ rejects empty file"

    echo "tiny" > "$tf"
    mmb_validate_suite_output "$tf" && { echo "  ✗ accepted <100 bytes"; rm "$tf"; exit 1; } || echo "  ✓ rejects <100 bytes"

    # 200 chars of plausible test output
    printf "PASSED tests/test_a.py::test_one\nPASSED tests/test_a.py::test_two\nPASSED tests/test_a.py::test_three\nPASSED tests/test_a.py::test_four\n=== 4 passed in 0.42s ===\n" > "$tf"
    mmb_validate_suite_output "$tf" && echo "  ✓ accepts valid (>100 bytes)" || { echo "  ✗ rejected valid"; rm "$tf"; exit 1; }

    # body shape
    body=$(mmb_build_pr_body 42 "- feat: x" "wt-name" "$tf")
    echo "$body" | grep -q "Closes #42" && echo "  ✓ body contains Closes #42" || { echo "  ✗ body missing Closes"; rm "$tf"; exit 1; }
    echo "$body" | grep -q "## Suíte verde" && echo "  ✓ body contains 'Suíte verde' section" || { echo "  ✗ body missing Suíte verde"; rm "$tf"; exit 1; }
    echo "$body" | grep -q "PASSED tests" && echo "  ✓ body embeds suite output" || { echo "  ✗ body missing suite output"; rm "$tf"; exit 1; }

    # truncation
    yes "PASS" | head -c 5000 > "$tf"
    body=$(mmb_build_pr_body 42 "- feat: x" "wt-name" "$tf")
    if [ "$(printf '%s' "$body" | wc -c)" -lt 6000 ]; then
      echo "  ✓ body truncates large suite output"
    else
      echo "  ✗ body did not truncate"; rm "$tf"; exit 1
    fi
    echo "$body" | grep -q "truncado em 4KB" && echo "  ✓ body has truncation note" || { echo "  ✗ no truncation note"; rm "$tf"; exit 1; }

    rm "$tf"
    echo "ok"
  else
    cat >&2 <<EOF
Este arquivo é um lib de funções pra ser sourceado por open-pr.sh.
Pra rodar self-test:
  bash $0 --self-test
EOF
    exit 1
  fi
fi
