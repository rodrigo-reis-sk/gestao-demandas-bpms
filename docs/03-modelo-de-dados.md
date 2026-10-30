# 03 — Modelo de dados

Script: `supabase/migrations/0001_estrutura_inicial.sql` (rascunho v1, testado em Postgres 16
local com as regras de segurança simuladas). Dados iniciais: `supabase/seed.sql`.
Testes: `supabase/testes/`.

## Regra de nomes (D10)

Nenhuma tabela, coluna, view ou função leva nome de ferramenta externa. Pretendemos sair do
ClickUp um dia e seguir só com o nosso sistema.

- A ferramenta aparece só como **valor**: `origem = 'clickup'` (tarefas, tempo, histórico) e
  `sistema = 'clickup'` (contas de integração, sincronizações).
- O que vem de fora usa o sufixo **`_externo`**: `id_externo`, `nome_externo`,
  `lista_id_externo`, `usuario_id_externo`...
- O que aconteceu lá usa **`_na_origem`**: `criada_na_origem`, `excluida_na_origem`...
- No dia da saída, as mesmas tabelas recebem `origem = 'interno'`. Só as Edge Functions
  `clickup-*` e o `config/clickup.json` deixam de ser usados.

## Diagrama

```
                      usuarios_sistema ──< contas_integracao   (token no Vault, e-mail = login)
                             │
consultores ──< tarefas_responsaveis >── tarefas ──< registros_tempo
   │   │                                  │  │  └──< tarefas_historico   (quem alterou o quê)
   │   │                                  │  └──< sugestoes_agrupamento >──┐
   │   │                                  │ demanda_id                     │
   │   └────── consultor_responsavel ── demandas ──────────────────────────┘
   │                                     │  │  │  └──< demandas_historico
   └──< apontamentos_manuais ────────────┘  │  └── kanban_colunas
                                            │
clientes ──< clientes_faps (listas)  ───────┘ fap_id        chamado_id ── chamados ──< chamados_evidencias ──< chamados_anexos
   └──< links_portal ───────────────────────────────────────────────────────┘
```

## Tabelas

### Cadastros
| Tabela | Para quê | Pontos importantes |
|---|---|---|
| `usuarios_sistema` | Quem entra na gestão | Ligada ao Supabase Auth. Papel `admin`, `gestor` ou `consultor`. **E-mail = e-mail do ClickUp** |
| `contas_integracao` | Conexão de cada gestor com o ClickUp (P5) | `email_externo` tem de ser igual ao e-mail de login (gatilho recusa se não for). `segredo_id` aponta para o token criptografado no Supabase Vault — o token não fica na tabela. `usar_na_sincronizacao` marca a única conta usada pela varredura. Gestor só lê; quem grava é a Edge Function |
| `consultores` | Consultores e desenvolvedores | **`sincronizar`** = buscar as tarefas dele (R1.1); `sincronizar_desde` = quando foi marcado (dispara a carga de 90 dias). `id_externo` vem da lista de membros, ligado pelo e-mail |
| `clientes` | Parceiros | `parceiro_id_externo` = opção do dropdown Parceiro. `cor` = etiqueta do card |
| `clientes_faps` | **Todas** as listas descobertas (Avulso, projeto, outras) (P7) | `situacao_sincronizacao`: **a_analisar** (lista nova, não sincroniza), **sincronizar**, **nao_sincronizar**. Grava quem analisou e quando. `ativa = false` para "Z"/"Concluída". `cliente_id` e `fap` podem ficar vazios em lista fora do padrão |
| `responsavel_real_por_fap` | De-para da conta compartilhada "BPMS" para a pessoa real em cada FAP (D17) | Ex.: BPMS na FAP 32222 = Cleber Nascimento. "BPMS" **não** é cadastrado como consultor. O gatilho `resolver_responsavel_real()` troca pelo consultor real nos responsáveis e no tempo, e aprende o id da conta na 1ª sincronização |
| `configuracoes` | Parâmetros | Agrupamento (janela, limiares), sincronização, anexos |

### Kanban e demandas
| Tabela | Para quê | Pontos importantes |
|---|---|---|
| `kanban_colunas` | Colunas configuráveis | `tipo`: entrada, andamento, espera, concluida, cancelada. `limite_cards` opcional |
| `demandas` | O card do kanban | Código automático `DEM-0001`. `ordem_na_coluna` numérica para arrastar entre cards |
| `demandas_historico` | Quem moveu o quê e quando | Preenchido por gatilho ao criar/mover e pelas funções de agrupamento |
| `apontamentos_manuais` | Horas informadas pelo gestor | Em minutos, por consultor e data |

### Tarefas e tempo (repositório)
| Tabela | Para quê | Pontos importantes |
|---|---|---|
| `tarefas` | Repositório de tarefas | Chave própria (`id`) + `origem` e `id_externo` (únicos juntos). `situacao`: pendente, agrupada, ignorada. `excluida_na_origem` em vez de apagar. `criada_por_*` guarda a autoria. `nome_normalizado` sem acento para comparar |
| `tarefas_responsaveis` | Responsáveis da tarefa | Uma tarefa pode ter mais de um. Guarda o id externo mesmo quando a pessoa não é consultor cadastrado |
| `registros_tempo` | Tempo registrado | Por consultor, com início e fim. `origem` + `id_externo` |
| `tarefas_historico` | Quem alterou o quê na tarefa (P5) | Vem dos avisos do webhook (autor na origem) e das ações do sistema (usuário logado) |
| `sugestoes_agrupamento` | Sugestões do sistema | Pontuação 0–100 e motivos (ver doc 05) |
| `sincronizacoes` | Log das execuções | Qual conta foi usada, quantas tarefas leu/criou/alterou, listas novas, chamadas à API, erro |

### Chamados
| Tabela | Para quê | Pontos importantes |
|---|---|---|
| `chamados` | Formulário do consultor, portal do cliente, interno | Código `CH-00001`. `status` (0009): novo, aguardando_informacao, aprovado, tarefa_criada, recusado, concluido (em_triagem e direcionado só por compatibilidade). `desenvolvedor_id` (obrigatório) e `consultor_id` (opcional, D58), `gerente_projetos_id`. `tarefa_id` / `tarefa_criada_id_externo` ligam à tarefa com o código no nome (gatilho, D61). Pedido de informação: `informacao_pedida`, `token_complemento` (link, D59), `complementado_em` |
| `chamados_evidencias` | Passo a passo | `ordem` garante a sequência; `etapa` = abertura ou complemento (0009) |
| `envios_por_ip` | Limite do formulário externo (D60) | Uma linha por envio; só a última hora conta; limpa sozinha depois de 2 dias |
| `chamados_anexos` | Prints de cada passo | Arquivo no bucket privado `evidencias` |
| `links_portal` | Link exclusivo por cliente (P8, D62) | Token aleatório na URL, pode ser desativado ou expirar; `ultimo_acesso_em` e `criado_por` (0010) |

## Views (consultas prontas)

| View | Uso |
|---|---|
| `vw_horas_registradas_por_demanda` | Minutos registrados por demanda e consultor. Usa os registros de tempo; se a tarefa não tem, usa o tempo total da tarefa; se zero, usa a duração do Período (P1) |
| `vw_horas_manuais_por_demanda` | Minutos informados pelo gestor por demanda e consultor |
| `vw_horas_demanda` | Totais da demanda: registradas × manuais × estimadas |
| `vw_kanban_cards` | Tudo o que o card precisa em uma consulta |
| `vw_chamados` | Tela de triagem (0009) | Chamado com nomes de cliente, dev, consultor, gerente, quem triou, tarefa ligada, lista sugerida e contagem de passos/prints |
| `vw_pendencias_gestor` | Contadores do menu: listas a analisar, tarefas pendentes, "BPMS" em FAP sem pessoa definida, chamados novos |

## Funções

| Função | O que faz |
|---|---|
| `sugerir_agrupamento(tarefa_id)` | Pontua a tarefa contra as demandas abertas, grava as sugestões e agrupa sozinha quando é certo |
| `aceitar_sugestao(tarefa_id, demanda_id)` | Agrupa a tarefa na demanda e recusa as outras sugestões |
| `criar_demanda_da_tarefa(tarefa_id)` | Cria uma demanda nova a partir da tarefa, na coluna de entrada |
| `eh_gestor()` | Usada nas regras de segurança |

Fase 1 (migração `0002_sincronizacao.sql`). As de **gravação** só a chave de serviço (Edge Functions) executa:

| Função | O que faz |
|---|---|
| `gravar_membros(membros)` | Liga membros da origem aos consultores pelo e-mail; pessoa nova entra desmarcada (D24); conta compartilhada só aprende o id |
| `gravar_listas(listas)` | Atualiza `clientes_faps`; liga FAP do seed pelo número exato; lista nova "a_analisar" (encerrada → "nao_sincronizar", D18); acha o cliente pelo nome da pasta (tolerante) |
| `gravar_tarefas(origem, tarefas)` | Grava/atualiza tarefas e responsáveis. Tarefa **nova** só entra com consultor **e** lista marcados. Roda `sugerir_agrupamento` nas novas |
| `gravar_registros_tempo(origem, início, fim, usuários, registros)` | Grava o tempo; o que sumiu da origem na janela vira `excluido_na_origem` |
| `gravar_historico_tarefa(origem, tarefa, itens)` | "Quem alterou o quê" (D13), sem duplicar |
| `marcar_tarefa_excluida(origem, id)` | Tarefa apagada na origem: marca, não apaga (D8) |
| `filtros_sincronizacao()` / `inicio_busca_tarefas(sistema)` | Ids de consultores e listas a buscar; desde quando buscar (90 dias quando há marcação nova, D22) |
| `salvar_conta_integracao(...)`, `ler_token_sincronizacao`, `ler_token_usuario`, `registrar_uso_conta` | Token de cada gestor no Vault; a 1ª conta vira a da sincronização |
| `salvar_segredo` / `ler_segredo` / `conferir_chave_agendamento` | Segredos no Vault (webhook, chave do agendamento) |
| `agendar_sincronizacao(url)` / `disparar_sincronizacao(tipo)` | `pg_cron` + `pg_net` chamando a Edge Function |
| `minutos_do_periodo(texto)`, `cliente_por_nome(texto)` | Utilitárias ("08h-10h" → 120; nome de pasta → cliente) |

Chamadas pela **tela** (gestor logado): `definir_conta_sincronizacao(conta)` e `desconectar_conta(conta)` (apaga o token do Vault).

## Quais tarefas entram (P7)

Uma tarefa só é buscada quando **o consultor** está com `sincronizar = true` **e a lista**
está com `situacao_sincronizacao = 'sincronizar'`. Lista nova descoberta entra como
`a_analisar` e aparece no topo da tela "Listas" e no contador do menu até o gestor decidir.

## Segurança (RLS)

- Todas as tabelas com RLS ligado.
- Gestor ativo: lê e grava tudo, menos `contas_integracao` (só leitura).
- Consultor logado: vê as colunas e as demandas em que é responsável.
- Anônimo: nada. Formulário e portal gravam pela Edge Function com a chave de serviço.
- As funções de agrupamento recusam usuário logado que não seja gestor.

## Testes feitos no rascunho v1 (22/10/2026)

Rodados em Postgres 16 local, com `auth.uid()` e os papéis do Supabase simulados
(`supabase/testes/rodar.sh`):
- migração e seed executam sem erro; o seed pode rodar duas vezes sem duplicar;
- as 31 FAPs do seed entram como "a analisar"; ao marcar uma, grava quem analisou;
- conexão com e-mail igual ao login é aceita; com e-mail diferente é recusada;
- gestor lê `contas_integracao` mas não consegue alterar; consultor não vê;
- tarefa do "dia 2" com título parecido gerou sugestão de 64 pontos para a demanda certa;
- tarefa com o código `DEM-0001` e tarefa citando o ticket Sankhya foram agrupadas sozinhas;
- tarefa de outro cliente e assunto não gerou sugestão;
- a mesma tarefa externa não entra duas vezes;
- o card mostrou cliente, consultor, 2 tarefas, 105 min registrados e 60 min manuais;
- "BPMS" na FAP 32222 virou Cleber Nascimento (responsável e tempo); "BPMS" em FAP sem de-para
  ficou sem consultor e apareceu no contador de pendências;
- consultor não consegue agrupar; anônimo não acessa nenhuma tabela.

## Testes da fase 1 (22/10/2026)

`supabase/testes/99_testes_fase1.sql`, `funcoes.test.ts` e `99_testes_traducao.sql` (também por `rodar.sh`):
- "08h-10h" = 120 min; membros ligados pelo e-mail; "BPMS" não vira consultor; pessoa nova entra desmarcada;
- listas: FAP do seed ligada sem duplicar; lista nova "a_analisar"; encerrada "nao_sincronizar"; "PRO-INFO" achou "Pro-Info"; pasta administrativa sem cliente;
- carga completa na 1ª vez e ao marcar consultor novo; incremental depois;
- tarefa nova só entra com consultor e lista marcados; "BPMS" na FAP 32222 virou Cleber; atualizar não desfaz o agrupamento; responsável que saiu é removido;
- tempo apagado na origem é marcado; tempo de tarefa fora do banco não entra;
- histórico sem duplicar; tarefa apagada marcada;
- token no Vault; e-mail diferente recusado; 2ª conta não toma a sincronização; gestor troca a conta; consultor não troca; desconectar apaga o token;
- usuário logado não executa funções internas nem lê token; a chave de serviço executa;
- agendamento sem duplicar; chamada do pg_cron leva a chave certa;
- tradução de uma tarefa no formato da API (dropdown por índice e por id, campo Detalhamento, Período) grava certo no banco;
- cliente da API espera no HTTP 429, repete no 500, pagina com trava e manda o token pessoal sem "Bearer".

## Migração 0003 (23/10/2026)

- `clientes_faps.tipo` aceita **interno** (listas de pastas administrativas); novas colunas `sugerida`
  (sugestão de sincronizar, D27) e `sigla_gerente` (FC/ED, D28).
- `clientes.gerente_projetos_id` → consultor gerente de projetos, preenchido pela sigla da pasta
  (`configuracoes.gerentes_por_sigla`).
- `gravar_listas` reescrita com as regras automáticas (só enquanto ninguém decidiu a lista);
  `registrar_analise_lista` só registra decisão de pessoa (não da regra automática).
- `vw_pendencias_gestor` ganhou `listas_sugeridas` (última coluna).
- Tarefas-estrutura que tinham entrado foram marcadas "ignorada" (D29).

## Migração 0004 — demandas e agendas (23/10/2026)

- `tarefas`: `estrutura`, `etapa`, `agenda_tipo`, `nivel`, **`papel`** (demanda / etapa / agenda / estrutura),
  **`demanda_tarefa_id`** (a tarefa-demanda), `eh_folha`, `data_agenda`, **`minutos_agenda`**,
  **`situacao_agenda`** (realizada / agendada / nao_executada), **`selecao`** (escolha do gestor) + quem/quando.
- `recalcular_hierarquia()` roda no fim de cada `gravar_tarefas`.
- `clientes_faps.carregada_em`: lista já carregada desde a data de corte (`configuracoes.sincronizacao.carga_desde`).
- Views: **`vw_demandas`** (demanda + cliente/lista/gerente + realizadas/agendadas/planejadas),
  **`vw_agendas`** (folhas, com consultor e se está incluída), **`vw_horas_mes`** (mês × consultor × cliente).
  Nas views, agenda "agendada" com data anterior a hoje aparece como **`atrasada`** (D51) e soma em `minutos_atrasados`.
  Estrutura dentro de demanda real é transparente para a hierarquia (D49).
- `minutos_do_periodo` desconta o almoço (12h-14h) quando o período cobre o almoço inteiro.

## Migração 0009 — chamados (26/10/2026, fase 3)

- Formulário (só a chave de serviço chama, pela Edge Function `formulario`): `conferir_chave_formulario`, `registrar_envio_ip`,
  `dados_formulario` (clientes com lista marcada, consultores marcados, gerentes), `gravar_chamado`, `gravar_evidencias`,
  `dados_complemento`, `gravar_complemento`.
- Triagem (gestor logado): `chave_formulario(p_trocar)` devolve (ou troca) a chave do link; `triar_chamado(id, acao, texto,
  desenvolvedor, consultor)` com as ações aprovar, responsaveis, recusar, pedir_informacao e reabrir.
- Gatilho `trg_tarefas_liga_chamado` em `tarefas` (D61). Chave `chave_formulario` no Vault. Bucket privado `evidencias`
  (5 MB por arquivo, imagens e PDF) com leitura só para gestor.
- Testes: `supabase/testes/99_testes_0009.sql` (chave, listas, limite por IP, gravação, validações, permissões, complemento,
  aprovar/recusar, ligação pelo código, bucket).

## Migração 0014 — só pessoas acompanhadas nos painéis (30/10/2026, D76)

- `pessoa_acompanhada(consultor, tem_responsavel)`: sem responsável → conta; senão só consultor marcado (`sincronizar`) e ativo.
- `vw_agendas`: `incluida` passa a exigir pessoa acompanhada; nova coluna `consultor_acompanhado`; com dois responsáveis mostra o marcado.
- `vw_demandas`: totais só das agendas que contam; novas colunas `responsavel_acompanhado` e `acompanhada` (o Kanban filtra por ela).
- `vw_horas_dia`: tempo rastreado só de pessoa acompanhada. `preparar_acesso`: acesso de consultor só para pessoa marcada.
- Testes: `supabase/testes/99_testes_0014.sql`.

## Migração 0013 — acessos pela tela Consultores (28/10/2026, D75)

- `usuarios_sistema`: `trocar_senha` (senha temporária → a tela pede a nova), `acesso_por`, `acesso_em`.
- `situacao_acessos()` (gestor): acesso de cada pessoa do cadastro, com o último login (`auth.users.last_sign_in_at`).
- Só a chave de serviço (Edge Function `acessos`): `usuario_do_consultor`, `preparar_acesso` (regras de quem pode), `gravar_acesso`,
  `tirar_acesso`. A pessoa logada: `senha_trocada()`.
- Testes: `supabase/testes/99_testes_0013.sql`.

## Migração 0012 — relatório de horas e leitura do consultor (28/10/2026, fase 4)

- `vw_horas_dia`: dia, mês, consultor, demanda (nome, status, link), cliente, gerente; minutos realizados, agendados, atrasados
  (agendas consideradas, D34/D51) e **rastreados** (`registros_tempo` da tarefa → demanda da tarefa, desde o corte). Consultor logado
  só vê as linhas dele (D73).
- `eh_consultor()`, `demandas_do_consultor()` e políticas `consultor_le` (só leitura) em `tarefas`, `tarefas_responsaveis`,
  `consultores`, `clientes`, `clientes_faps` e `registros_tempo` (só o próprio) (D74).
- Testes: `supabase/testes/99_testes_0012.sql`.

## Migração 0011 — criação da tarefa pela triagem (26/10/2026, fase 4)

- `chamados`: `criacao_situacao` (criando → criada | erro), `criacao_mensagem` (erro ou avisos), `criacao_url`, `criacao_lista_id`,
  `criacao_por`, `criacao_iniciada_em`, `criacao_concluida_em` (D65, D70). `chamados_anexos.enviado_na_origem_em` (D69).
- Funções só da chave de serviço: `dados_criacao_tarefa`, `reservar_criacao_tarefa` (confere, aprova e trava 3 min),
  `registrar_criacao_tarefa` (o id da tarefa nunca é apagado), `marcar_anexo_enviado`.
- Gatilho `ligar_tarefa_ao_chamado`: código `CH-` no nome **ou** id igual a `tarefa_criada_id_externo`.
- `vw_chamados` ganhou `lista_sugerida_id`, as colunas `criacao_*`, `criacao_lista_nome`, `criacao_por_nome` e `anexos_pendentes`.
- Testes: `supabase/testes/99_testes_0011.sql`.

## Migração 0010 — portal do cliente (26/10/2026, fase 3)

- `link_portal_valido(token)`: link ativo, dentro da validade, de cliente ativo.
- `situacao_para_cliente(status, canal, status da tarefa, tipo do status)`: recebido · informacao · atendimento · concluido · nao_aprovado (D63).
- `dados_portal(token)`: nome do cliente e todos os chamados dele (D62), com motivo da recusa e, nos chamados do portal que aguardam
  informação, a pergunta e o token do complemento (D64). Grava o último acesso.
- `gravar_chamado_portal(token, dados, ip)`: chamado `portal_cliente` com cliente e link tirados do token (o navegador não escolhe o cliente).
- `vw_chamados` ganhou `solicitante_nome`, `solicitante_email`, `link_portal_id`, `situacao_cliente`, `cliente_tem_portal`; nova `vw_links_portal`.
- Testes: `supabase/testes/99_testes_0010.sql`.
