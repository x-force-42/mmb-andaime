# Hooks do andaime MMB

Hooks do **Claude Code CLI** que rodam em qualquer sessão Claude aberta
no diretório `/MMB/`. Implementam enforcement técnico dos guardrails
documentados em [`../guardrails.md`](../guardrails.md).

## Hooks disponíveis

### `block-pr-merge.sh` — enforcement de A10/A8

Bloqueia `gh pr merge` e `gh pr review --approve` em sessões atômicas
(detectadas pela presença de `MMB_AGENT_ID` no env). Sessões do Mestre,
do Rick (terminal manual) e do `worker-master` não têm `MMB_AGENT_ID`
setado — o hook é no-op transparente nelas.

**Configuração** (adicione em `.claude/settings.local.json` da raiz `/MMB/`):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/eliezer/llab/MMB/.tooling/hooks/block-pr-merge.sh"
          }
        ]
      }
    ]
  }
}
```

> **Path absoluto obrigatório**: hooks são executados pelo Claude Code
> com cwd indefinido — path relativo não funciona.

> `.claude/` está em `.gitignore` (settings são por-máquina). Cada dev
> precisa configurar localmente; este README é a fonte da verdade do
> formato.

**O que é bloqueado em sessão atômica:**

| Comando | Ação |
|---|---|
| `gh pr merge` (qualquer flag) | ❌ exit 2 |
| `gh pr merge --auto` | ❌ exit 2 |
| `gh pr merge --squash --delete-branch` | ❌ exit 2 |
| `gh pr review --approve` | ❌ exit 2 |
| `gh pr review 14 --approve --body X` | ❌ exit 2 |
| Aninhados (`;`, `&&`, `|`, `$()`, `\``) | ❌ exit 2 |

**O que continua liberado em sessão atômica:**

| Comando | Razão |
|---|---|
| `gh pr view` | leitura, debug normal |
| `gh pr list` | leitura, debug normal |
| `gh pr create` | atômico abre PR via `open-pr.sh` |
| `gh issue view` / `gh issue create` | leitura ou criação de issue (responsabilidade do orq, mas não destrutivo) |
| `gh pr review --comment` (sem `--approve`) | comment != approve |
| `git push` | atômico publica branch task/* |
| Qualquer comando não-`gh` | fora do escopo |

**Limitação conhecida:** se o atômico escreve um script com `gh pr merge`
dentro e roda `bash script.sh`, o hook vê só `bash script.sh` na tool call
e libera. Defesa-em-profundidade vs adversário determinado é fora de
escopo deste hook — guardrails A10/A8 no profile são a primeira linha;
este hook é a barreira contra erro acidental em chamada direta.

## Testes

```bash
bash .tooling/tests/test-hooks.sh
```

29 asserts cobrindo: bloqueios em sessão atômica, permissões em
sessão não-atômica, comandos neutros, robustez (JSON malformado,
stdin vazio, tool_name != Bash), anti-overmatching de similares.

## Como verificar se o hook está ativo

Numa sessão Claude Code com cwd em `/MMB/` ou subdir:

1. Verifique se o settings está sendo lido (Claude Code re-lê a cada
   sessão; se editou o JSON, abra nova sessão).
2. Setando `MMB_AGENT_ID=test`, peça pro agente rodar `gh pr merge 1`.
   Deve receber o erro `BLOCKED: Guardrails A10/A8 ...`.
3. Sem `MMB_AGENT_ID`, o mesmo comando passa (vai falhar no `gh` por
   PR inexistente, mas o hook não interfere).
