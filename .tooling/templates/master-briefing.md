# Master Briefing — <título da intenção>

> **Artefato local.** Mora em `.tooling/intents/<YYYY-MM-DD>-<slug>/master-briefing.md`.
> **Não vira issue no GitHub.** Sub-issues são criadas pelos
> orquestradores locais a partir dos child briefings (ou deste
> mesmo, em caso single-repo).

## Status

- Criado em: `<YYYY-MM-DD>`
- Mestre: `<sessão Claude que produziu>`
- Status: 🎯 ativo / ⏳ em execução / ✅ fechado / ❌ abortado
- Thread (slug): `<kebab-case>`

## Intenção (literal do Rick)

> <copiar o que Rick falou, palavra por palavra, na conversa>

## Tradução do Mestre

<reformulação técnica do que a intenção significa em termos
do ecossistema MMB. Por que faz sentido. Qual o ganho.>

## Tipo

- [ ] Single-repo (1 briefing serve a 1 orq local)
- [ ] Cross-repo (briefings filhos em `briefings/<repo>-<slug>.md`)

## Contexto cross-repo (preencher se cross-repo)

O que cada repo é hoje, e o que está em jogo nesta intenção:

- **mmb-core** — <papel + o que muda aqui>
- **mmb-cockpit** — <papel + o que muda aqui>
- **mmb-aquarium** — <papel + o que muda aqui>

## Contratos compartilhados (preencher se cross-repo)

Campos, nomes, formatos que múltiplos repos vão consumir.
Devem ser estáveis ao longo do épico:

| Contrato | Forma | Quem produz | Quem consome |
|---|---|---|---|
| `<nome>` | `<tipo / shape>` | <repo> | <repos> |

## Decomposição em tarefas

| ID | Projeto | Tarefa | Depende de |
|---|---|---|---|
| 1.1 | mmb-core | <título curto> | — |
| 1.2 | mmb-core | <título curto> | 1.1 |
| 2.1 | mmb-cockpit | <título curto> | 1.1 |

(Pra single-repo, costuma ser só `1.1`.)

## Grafo de dependências

```
<ascii art ou texto da ordem crítica, se houver>
```

## Estimativa grossa

<algo entre "1 hora" e "1 sprint">

## Decisões em aberto

**Idealmente vazio.** Se tem decisão aberta, briefing ainda
NÃO pode ser disparado — discovery não terminou.

- [ ] <decisão pendente>

## Checklist de issues (preenche após dispatch)

> Mestre atualiza conforme orqs locais criam issues e mandam status.

- [ ] core #<n> — 1.1: <título>
- [ ] cockpit #<n> — 2.1: <título>
- (etc)

## Nota narrativa final (preenchida no fechamento)

Quando todos os status de `task-fechada` chegaram:

- O que mudou de fato.
- Decisões interessantes tomadas no caminho.
- Sinais de alerta pra próximas intenções.
- Tempo real vs estimativa.
