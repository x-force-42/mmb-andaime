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
#   mmb_build_pr_body <subissue> <commits-list> <worktree-name>
#     Imprime no stdout o body do PR com `Closes #<subissue>` embutido.
#     <subissue> deve ter passado por mmb_validate_subissue_format.
#     <commits-list> = lista markdown de commits (uma linha por commit,
#       prefixada com "- ").
#     <worktree-name> = basename da worktree (ex: "1-1-blocos-progresso"),
#       aparece no rodapé pra rastreio.

# Guarda: evita execução acidental quando o caller não passa --self-test.
# Permite `source` limpo sem side-effects.

mmb_validate_subissue_format() {
  local v="${1:-}"
  [[ "$v" =~ ^[1-9][0-9]*$ ]]
}

mmb_build_pr_body() {
  local subissue="$1"
  local commits_list="$2"
  local worktree_name="$3"
  cat <<EOF
## O que mudou

$commits_list

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
    mmb_validate_subissue_format 42 && echo "  ✓ accepts 42" || { echo "  ✗ rejected 42"; exit 1; }
    mmb_validate_subissue_format "" && { echo "  ✗ accepted empty"; exit 1; } || echo "  ✓ rejects empty"
    body=$(mmb_build_pr_body 42 "- feat: x" "wt-name")
    echo "$body" | grep -q "Closes #42" && echo "  ✓ body contains Closes #42" || { echo "  ✗ body missing Closes"; exit 1; }
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
