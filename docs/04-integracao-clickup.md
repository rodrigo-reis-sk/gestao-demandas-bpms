# 04 — Integração com o ClickUp

Fonte: o pacote **"Lançar ClickUp BP-MS"** que já funciona hoje (cópia em
`referencia/clickup-lancar-legado/`) e a API pública v2 do ClickUp.
IDs de campos e opções: `config/clickup.json`.

## Como o ClickUp está organizado (PMO BP-MS)

```
Workspace
└── Espaço "PMO BP-MS" (90133723590)
    ├── Pasta <Parceiro>                     ← cliente
    │   └── Lista "<Parceiro> <FAP> Avulso"  ← FAP (ex.: Germipasto 32221 Avulso)
    │       └── 1-Atendimento Base
    │           └── 2026-10 Outubro          ← subtarefa do mês
    │               └── <tarefa do atendimento>   ← o que sincronizamos
    ├── 1-BP-MS, 2- Horas Cruzadas, 3- Planos de Ação   ← administrativas, ignorar
    └── Z...                                  ← encerradas, ignorar
```

- FAP: número de 4 a 6 dígitos no nome da lista. Número de FAP só aceita igualdade exata
  (lição do legado: aproximação de número já rodou na FAP errada).
- Um cliente pode ter mais de uma FAP ativa (ex.: Amidos 32699 e 30930). Nesse caso, quem
  cria a tarefa escolhe.
- Nomes divergentes entre pasta e lista (ex.: pasta "PRO-INFO", lista "Por-Info…"):
  usar a comparação tolerante do legado (`text_matching.py`).

## O que ler de cada tarefa

| Dado | De onde vem | Coluna em `tarefas` (com `origem = 'clickup'`) |
|---|---|---|
| id, custom_id, nome, status, url | campos nativos | `id_externo`, `codigo_externo`, `nome`, `status`, `url` |
| Lista, pasta, pai | `list`, `folder`, `parent` | `lista_id_externo`, `pasta_id_externo`, `tarefa_pai_id_externo`, `fap_id` |
| Cliente | dropdown **Parceiro**; se vazio, nome da pasta | `cliente_id` |
| FAP | nome da lista | `fap` |
| Responsáveis | `assignees[]` | `tarefas_responsaveis` |
| Criador | `creator` | `criada_por_id_externo`, `criada_por_nome` |
| Usuário cliente | campo texto | `usuario_cliente` |
| Detalhamento | campo texto (ou `description`) | `detalhamento` |
| Origem | dropdown (Whatsapp, E-mail, PMO, Service Desk, Sucesso do Cliente, Consultor) | `origem_solicitacao` |
| Período | dropdown "08h-10h" | `periodo` e `minutos_periodo` (10h − 08h = 120) |
| Datas | `start_date`, `due_date`, `date_created`, `date_updated`, `date_closed` (ms) | `data_inicio`, `data_vencimento`, `criada_na_origem`, `atualizada_na_origem`, `fechada_na_origem` |
| Tempo | `time_spent`, `time_estimate` (ms) | `minutos_registrados`, `minutos_estimados` |

Ignorar na sincronização as tarefas-estrutura: `1-Atendimento Base` e as subtarefas do mês
(nome no padrão `AAAA-MM Mês`).

## Endpoints usados (API v2)

| Uso | Endpoint | Observação |
|---|---|---|
| Membros (consultores) | `GET /team` | Traz `id`, `username`, `email`. Liga ao cadastro pelo e-mail |
| Tarefas alteradas por consultor | `GET /team/{team_id}/task` com `assignees[]`, `space_ids[]`, `date_updated_gt`, `include_closed=true`, `subtasks=true`, `page` | Uma busca para vários consultores. Paginado |
| Tarefa completa | `GET /task/{id}` | Usado pelo webhook |
| Tempo registrado | `GET /team/{team_id}/time_entries` com `start_date`, `end_date`, `assignee` | Gestores são admin (P5): a conta da sincronização enxerga o tempo de todos |
| Pastas e listas | `GET /space/{id}/folder`, `GET /folder/{id}/list`, `GET /space/{id}/list` | Descobrir clientes e FAPs |
| Webhook | `POST /team/{team_id}/webhook` | Eventos de tarefa e de tempo. Conferir a assinatura `X-Signature`. O `history_items[].user` diz **quem alterou** → `tarefas_historico` |
| Quem é o dono do token | `GET /user` | Confere o e-mail na conexão do gestor |
| OAuth | `GET https://app.clickup.com/api?client_id=…&redirect_uri=…` e `POST /oauth/token` | Conexão de cada gestor (D11) |
| Criar tarefa | `POST /list/{list_id}/task` | Mesma regra do legado (ver abaixo) |
| Anexar print | `POST /task/{id}/attachment` | Para levar as evidências do chamado à tarefa |

**Limite de chamadas:** depende do plano (o plano mais comum permite 100 por minuto por
token). Reaproveitar a lógica do legado: ler `X-RateLimit-Remaining` e
`X-RateLimit-Reset`, pausar antes de estourar e repetir com espera no HTTP 429. Também ter
um tempo máximo por chamada (o legado sofreu travamento de rede sem erro).

## Criar tarefa a partir do sistema (fase 4)

Reproduzir `criar_demanda_padrao()` do legado
(`referencia/clickup-lancar-legado/motores/clickup_tasks/lancar_tarefas_clickup.py`):

1. Escolher a FAP (lista Avulso ativa do cliente).
2. Garantir que o responsável enxerga a pasta (o legado libera "Apenas exibição" pela
   API v3 se precisar).
3. Encontrar ou criar `1-Atendimento Base`.
4. Encontrar ou criar a subtarefa do mês (`2026-10 Outubro`; com data de vencimento, usa o
   mês do vencimento).
5. Criar a tarefa com Etapa e Módulo "Atendimento Avulso", Agenda "Remoto", Apontamento
   "OS Experience", Usuário cliente, Detalhamento, Parceiro, Origem, Período e responsável.
   Sem data → status `backlog base`.
6. **Novo:** colocar o código da demanda no nome (`DEM-0042 · título`) e anexar os prints.
7. Criar com o token **do gestor que clicou** (D11). Gravar `tarefa_criada_id_externo` no chamado. Quando a tarefa voltar pela sincronização, a
   regra 0 do agrupamento a liga à demanda.

## Descoberta e seleção de listas (P7 / D14)

1. A varredura lê todas as pastas e listas do espaço PMO BP-MS e grava em `clientes_faps`
   (cliente pelo nome da pasta, FAP e tipo pelo nome da lista, `ativa` pelo "Z"/"Concluída").
2. Lista que ainda não existia entra como **a_analisar** e conta em `sincronizacoes.listas_novas`.
3. O gestor marca na tela "Listas": **sincronizar** ou **não sincronizar**.
4. A busca de tarefas usa `list_ids[]` só das listas marcadas e `assignees[]` só dos
   consultores marcados. Pastas administrativas também aparecem para análise (nada é escondido).

## Contas e token (P5 / D11–D13)

- Legado: token pessoal de cada pessoa, no cofre do Windows (keyring
  `sankhya_experience_sync` / `CLICKUP_TOKEN`).
- Novo sistema: **cada gestor conecta a própria conta** em "Meu perfil → Conectar ao ClickUp":
  1. o sistema abre o login do ClickUp (OAuth) e o gestor autoriza;
  2. a Edge Function `clickup-conectar` troca o código pelo token e chama `GET /user`;
  3. se o e-mail da conta for diferente do e-mail de login, recusa (o banco também recusa);
  4. grava o token no **Supabase Vault** e a linha em `contas_integracao` (sem o token).
- Criar tarefa / anexar print: usa o token de quem clicou → o ClickUp mostra o gestor como criador.
- Varredura e webhook: usam a conta com `usar_na_sincronizacao = true` (uma só, de um admin).
- Segredos do app OAuth: `CLICKUP_CLIENT_ID` e `CLICKUP_CLIENT_SECRET`, só nos segredos do Supabase.
- **Reserva (D19)**: se o OAuth não for liberado, cada gestor pode conectar com o próprio token pessoal (`pk_`) na mesma tela;
  fica no Vault como `token_pessoal` e mantém a autoria.
- **Plano B (D12)**, última reserva: `CLICKUP_TOKEN` único nos segredos; o autor
  fica no nosso histórico e na descrição da tarefa.

## Como foi implementado (fase 1)

- Código: `supabase/functions/` — `clickup-conectar`, `clickup-sync`, `clickup-webhook` e a pasta
  `_compartilhado/` (`clickup-api.ts` = chamadas com limite de cota e tempo máximo; `clickup-traducao.ts` =
  conversão do formato do ClickUp para o formato genérico do banco; `base.ts` = acesso ao banco e login).
- O banco recebe dados **já traduzidos** pelas funções `gravar_membros`, `gravar_listas`, `gravar_tarefas`,
  `gravar_registros_tempo`, `gravar_historico_tarefa` e `marcar_tarefa_excluida` (migração 0002). A regra
  "consultor **e** lista marcados" fica no banco (`gravar_tarefas`), valendo para varredura e webhook.
- Autenticação: token pessoal (`pk_`) vai puro no cabeçalho `Authorization`; token OAuth vai como `Bearer`.
- Webhook: registrado pela tela (Meu perfil). O segredo devolvido pelo ClickUp vai para o Vault
  (`webhook_clickup`); a assinatura `X-Signature` é HMAC SHA-256 em hexadecimal do corpo bruto.
- Varredura: `GET /team/{id}/task` com `assignees[]`, `list_ids[]`, `date_updated_gt`, `include_closed`,
  `subtasks`, paginado (trava de 100 páginas). Tempo: `GET /team/{id}/time_entries` em pedaços de 30 dias.
- Tarefas de estrutura ignoradas: `1-Atendimento Base` e o padrão `AAAA-MM Mês`.
