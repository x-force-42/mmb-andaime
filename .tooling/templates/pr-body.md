# <título do PR — Conventional Commits>

> Body do PR. O script `.tooling/bin/open-pr.sh` preenche os
> placeholders automaticamente a partir dos commits da branch
> e da sub-issue linkada.

## O que mudou

<lista de commits gerada pelo script — uma linha `- <subject>` por commit>

## Suíte verde

<output literal do test runner (Pytest / Vitest / npm test), capturado
pelo atômico antes de chamar open-pr.sh via:

  npm test 2>&1 | tee /tmp/suite.txt
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "vermelha"; exit 1; }
  MMB_SUITE_OUTPUT=/tmp/suite.txt /MMB/.tooling/bin/open-pr.sh

Truncado em 4KB pelo body builder; nota de truncamento aparece se
exceder. Guardrail A11 (`open-pr.sh` valida antes do push).>

## Origem

Closes #<sub-issue-number>

---

🤖 PR aberto via `.tooling/bin/open-pr.sh` pelo Agente Atômico (worktree: `<id>-<slug>`).
