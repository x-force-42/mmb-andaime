# <título do PR — Conventional Commits>

Closes #<sub-issue-number>

> Body do PR. O script `.tooling/bin/open-pr.sh` preenche os
> placeholders automaticamente a partir dos commits da branch
> e da sub-issue linkada.

## Contexto

Parte do épico **#<epic-number> — <slug do épico>**.

## O que mudou

<resumo conciso do diff. 2-5 bullets. Não duplica commit messages.>

- <ponto principal 1>
- <ponto principal 2>
- ...

## Por que mudou

<1-2 parágrafos. Conecta com a intenção do épico. O "porquê"
deve sobreviver ao churn de código.>

## Como testei

- [ ] Testes locais (`<comando>`) passam.
- [ ] Lint clean (`<comando>`).
- [ ] (se aplicável) Smoke test manual: `<o que foi feito>`.

## Notas pro revisor

<qualquer ponto que merece atenção: trade-off feito, decisão
não-óbvia, área frágil, escopo deliberadamente reduzido.>

## Checklist de pronto

- [ ] Critério de pronto da sub-issue todo check.
- [ ] Sem mudanças fora do escopo "Dentro" da sub-issue.
- [ ] Hooks rodaram (sem `--no-verify`).
- [ ] Branch alinhada com `master` (rebaseada se necessário).

---

🤖 Aberto via `.tooling/bin/open-pr.sh` pelo Agente Atômico.
