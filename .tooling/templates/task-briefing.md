# <título Conventional Commits — sem prefixo "Task X">

> **Body de sub-issue do GitHub.** Este arquivo serve como
> body literal de `gh issue create`. O atômico lê esta issue
> como **prompt direto de execução**. Escreva pensando que é
> um agente lendo, não um humano arquivando.
>
> Labels obrigatórias na criação: `task`, `project:<repo>`,
> `epic:<thread-slug>`.

## Contexto

<2-4 linhas: por que isso existe, qual o papel desta task no
épico maior. Link pro master-briefing se quiser.>

## Intenção

<o que esta task faz especificamente. Foco em comportamento
observável, não em código.>

## Escopo

### Dentro

- `<arquivo / módulo>`
- ...

### Fora

- <coisa adjacente que NÃO entra mesmo parecendo natural>
- ...

## Critério de pronto

Verificável pelo próprio atômico. Marca como checklist
acionável:

- [ ] <comportamento 1 observável>
- [ ] <comportamento 2 observável>
- [ ] Testes locais passam (`<comando>`)
- [ ] Lint clean (`<comando>`)
- [ ] Sem warnings novos
- [ ] Commit messages em Conventional Commits

## Contexto técnico

Arquivos relevantes:

- `<path>` — <por que importa>
- ...

Documentos relevantes:

- `<path>` — <por que importa>
- ...

## Implementação sugerida (hints — agente decide)

<2-5 parágrafos. Sugere abordagem sem amarrar. O atômico pode
divergir se tiver razão melhor — mas vai documentar isso no PR.>

```<linguagem>
// pseudo-código ilustrativo ou trecho de exemplo
```

## Testes a adicionar / atualizar

- `<path>` — <que comportamento cobrir>
- ...

## Dependências (cross-task)

- `requires: #<n>` — <título da issue de dep> *(deve estar
  mergeada antes desta começar)*

(ou: "sem dependências")

## Conflito potencial com (outras tarefas)

Outras sub-issues do mesmo épico que tocam arquivos em comum.

- #<n> — <título>

(ou: "nenhum")

## Definition of Done

- [ ] Todos os itens de "Critério de pronto" check.
- [ ] PR linkou `Closes #<este-issue>` no body (open-pr.sh
      faz automático).
- [ ] Sub-issue fecha automaticamente após PR mergeado.
- [ ] Sem mudanças fora do "Dentro" do escopo.

---

🤖 Issue criada pelo Orq de Projeto de `<repo>` a partir do
briefing em `.tooling/intents/<date>-<slug>/`. Atômico lê esta
issue como prompt; orq local pode refinar/comentar abaixo se
algo mudou desde a criação.
