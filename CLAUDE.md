# CLAUDE.md — memória do projeto Gestão de Demandas BP-MS

Leia este arquivo inteiro antes de qualquer trabalho neste projeto.

> **IDIOMA: responda SEMPRE em português do Brasil** — toda mensagem, do começo ao fim, inclusive
> frases curtas entre uma ação e outra ("vou ler o arquivo..."), perguntas, listas de tarefas,
> comentários no código, commits e documentação. Nunca misturar inglês na conversa.

## Quem e para quê

- Dono do projeto: **Rodrigo Reis** (rodrigo.reis@sankhya.com.br), gestor da equipe de
  desenvolvimento/personalizações BP-MS (Sankhya, unidade MS).
- Objetivo: gestão **simples** de consultores/desenvolvedores e de suas demandas, com
  integração ao ClickUp, kanban configurável e controle de horas.
- Prioridade de projeto: **manutenção e gestão simples**, **custo zero** (planos free).

## Como o Rodrigo quer trabalhar

- **Antes de desenvolver, entender e discutir.** Em pedido novo ou ambíguo: resumir o
  entendimento, propor opções e perguntar. Só codificar depois do "ok".
- **Sempre responder em português do Brasil**, direto e com linguagem de negócio — vale para
  respostas, resumos, perguntas, listas de tarefas, comentários no código, mensagens de commit
  e documentação. Mesmo que o pedido, um arquivo ou uma ferramenta venha em inglês, a resposta
  é em português (termos técnicos sem tradução consagrada podem ficar em inglês).
- Trabalhar **por fases** (ver `docs/06-fases.md`). Uma conversa por fase.
- Ao final de cada fase: atualizar `docs/06-fases.md` (checklist), `docs/07-decisoes.md`
  e as pendências em `docs/01-escopo.md`.
- **Publicação:** o Rodrigo publica (Supabase e `git push`). Sempre que algo ficar pronto para publicar, passar
  **na própria conversa** os comandos prontos para copiar (PowerShell, na pasta do projeto), na ordem certa:
  `db push` → `functions deploy <função>` → `git add` / `git commit` / `git push` (o push publica as telas no Pages,
  então vai por último), e dizer o que conferir depois (seção de testes do `docs/08-implantacao.md`).

## Mapa da documentação

| Arquivo | Quando ler |
|---|---|
| `docs/01-escopo.md` | Sempre. Requisitos, fora de escopo e **pendências em aberto** |
| `docs/02-arquitetura.md` | Antes de mexer em infraestrutura, hospedagem ou segurança |
| `docs/03-modelo-de-dados.md` | Antes de mexer no banco ou em telas que leem dados |
| `docs/04-integracao-clickup.md` | Antes de mexer na sincronização ou na criação de tarefas |
| `docs/05-agrupamento-de-tarefas.md` | Antes de mexer no repositório ou nas sugestões |
| `docs/06-fases.md` | Para saber onde estamos |
| `docs/07-decisoes.md` | Para não rediscutir o que já foi decidido |
| `docs/08-implantacao.md` | Para publicar no Supabase / GitHub Pages e validar o piloto |

## Fatos do ClickUp que não podem ser esquecidos

(Detalhes em `docs/04-integracao-clickup.md` e `config/clickup.json`.)

- Espaço **PMO BP-MS** (id `90133723590`). Uma **pasta por parceiro (cliente)**.
- Listas no padrão **`<Parceiro> <FAP> Avulso`** (ex.: `Germipasto 32221 Avulso`).
  Lista ou pasta com nome começando em **"Z"** = encerrada. Nome com "Concluída" = encerrada.
- Pastas administrativas ignoradas: `1-BP-MS`, `2- Horas Cruzadas`, `3- Planos de Ação`.
- Hierarquia da demanda avulsa: `1-Atendimento Base` → subtarefa do mês `AAAA-MM Mês`
  → **tarefa do atendimento** (é essa que importa para nós).
- Campos personalizados relevantes: Parceiro, Usuário cliente, Detalhamento, Origem,
  Período (dropdown "08h-10h"), Etapa, Módulo, Agenda, Apontamento, Experience.
- Status usados: `backlog base` (sem data), status padrão da lista (com data),
  `em andamento`, `não executado`.
- Limite da API: tratar HTTP 429 lendo `X-RateLimit-Remaining` / `X-RateLimit-Reset`
  (o pacote legado já faz isso em `referencia/clickup-lancar-legado/motores/clickup_sync/clickup_client.py`).
- O consultor que atende a mesma demanda em vários dias gera **várias tarefas** (uma por
  dia). Por isso existe o repositório com agrupamento.
- Existe uma conta compartilhada **"BPMS"** que representa pessoas diferentes por FAP
  (ex.: Soldamaq → Cleber Nascimento). Ela **não** é cadastrada como consultor: fica só no
  de-para `responsavel_real_por_fap`, e um gatilho troca pelo consultor real (D17).

## Regras técnicas

- Banco: **Supabase (Postgres)**, plano Free. Nomes de tabelas e colunas em português,
  `snake_case`, sem acento.
- **Nenhum nome de tabela, coluna, view ou função com nome de ferramenta externa** (ClickUp
  etc.) — pretendemos sair do ClickUp um dia (D10). A ferramenta aparece só como valor
  (`origem = 'clickup'`, `sistema = 'clickup'`); dados de fora usam `_externo` / `_na_origem`.
  O nome "clickup" só é aceito nas Edge Functions de integração (`clickup-*`) e em `config/clickup.json`.
- Toda tabela com **RLS ligado**. Formulários externos e portal do cliente **nunca** gravam
  direto no banco: passam por uma Edge Function que valida e grava com a chave de serviço.
- **Segredos** (tokens ClickUp, chaves Supabase, segredo do webhook, client secret do OAuth)
  só em `.env` local (fora do git), nos segredos do Supabase ou no Supabase Vault. Nunca em
  código, nunca em `config/`, nunca em coluna de tabela comum.
- **Conta ClickUp por gestor** (D11): login no sistema com o mesmo e-mail do ClickUp; cada
  gestor conecta a própria conta (OAuth), token no Vault. Criação de tarefa usa o token de
  quem clicou. Varredura usa a "conta da sincronização". Plano B: token único (D12).
- **Listas** (D14, D27): toda lista descoberta entra como `a_analisar` (com regras automáticas) e não
  sincroniza até o gestor marcar. Entra **tudo** das listas marcadas, desde 01/01/2026 (D32, D33).
- **Demanda e agenda** (D30): tarefa = demanda, subtarefa folha = agenda; a demanda é o ancestral mais alto
  que não é estrutura. Horas da agenda = estimativa, senão Período menos almoço (D34). O gestor escolhe as
  demandas que entram nos painéis (`tarefas.selecao`, D35). Kanban espelha o status do ClickUp (D36).
- O ClickUp é a fonte da verdade das **tarefas e do tempo registrado**. O nosso sistema é a
  fonte da verdade das **demandas, do kanban, dos agrupamentos e das horas manuais**.
- Tarefa apagada no ClickUp: marcar `excluida_na_origem = true`, nunca apagar a linha.
- Código simples e comentado em português. Preferir menos dependências.

## Estado atual

Fase 1 **no ar** desde 23/10/2026: Supabase `bucicoxjvokbsnynsmfh`, funções publicadas, telas em
https://rodrigo-reis-sk.github.io/gestao-demandas-bpms/ (repositório público `rodrigo-reis-sk/gestao-demandas-bpms`).
Conexão ao ClickUp por **token pessoal de cada gestor** (D19; o Rodrigo não tem permissão para criar app OAuth).
E-mail do Rodrigo no ClickUp e no login: `reis.c.rodrigo@gmail.com`. Falta: confirmar agendamento e webhook,
validar o piloto (checklist em `docs/08-implantacao.md` §9). Decisões D18, D20–D24 aprovadas em 23/10/2026 (P12).
Depois do no-ar: identidade visual "Grafite + lima" com tema claro/escuro/automático (D26 — toda tela nova usa
`assets/estilo.css` + `assets/tema.js`, ver `web/README.md`); migração 0003 com regras de listas, tela Listas por
pasta, gerente FC/ED e correção da tarefa-estrutura "1-Atendimento da Base" (D27–D29).
Fase 2 replanejada (D30–D51): migrações 0004–0007 no ar, sincronização reiniciada e carga completa (23/10/2026).
Validação contra o ClickUp gerou a migração 0008 (D49 mês dentro de demanda, D50 recálculo por lista, D51 agendas
atrasadas) — no ar e conferida. Kanban (`kanban.html`, D52) e painel de horas (`horas.html`, D53) feitos;
conferência adiada (segue em paralelo). Fase 2 encerrada em 26/10/2026.
Fase 3 decidida (D54–D57): formulário do consultor com link com chave + triagem (aprovar = criar no ClickUp à mão
com `CH-xxxxx` no nome; a sincronização liga), contador no menu; portal do cliente na sequência.
Fase 3, parte 1 **no ar** em 26/10/2026 (D58–D61, commit `ad97a51`): migração 0009, Edge Function `formulario`, telas
`formulario.html`, `complementar.html` e `triagem.html` (`assets/evidencias.js` = base das telas sem login). Testes do §10 com o Rodrigo.
Portal do cliente (D62–D64) **pronto e testado localmente** em 26/10/2026, falta publicar (`08-implantacao.md` §11): migração 0010,
ações do portal na função `formulario`, `portal.html` e links do portal na Triagem.
Fase 4 decidida (D65–D74). Item 1 (criar no ClickUp, `08-implantacao.md` §12):
migração 0011, Edge Function `clickup-criar` (regra do legado em `_compartilhado/clickup-criacao.ts`), Triagem com
"Aprovar e criar no ClickUp", "Aprovar, crio à mão" e "Reenviar prints" — **publicado** em 28/10/2026 (testes do §12 com o Rodrigo).
Relatório no painel de Horas (D73) e visão do consultor = Kanban + Horas com RLS (D74) **prontos e testados localmente** em 28/10/2026,
falta publicar (`08-implantacao.md` §13): migração 0012 (`vw_horas_dia`, leitura do consultor), `horas.html`, `comum.js` e `kanban.html`.
Prioridade do Rodrigo: **acelerar o MVP** com **bom gerenciamento das demandas**, sem amarrar nada novo ao ClickUp (D10).

## Como mexer em algo de uma fase já entregue

Pode voltar a qualquer fase a qualquer momento. Banco: **nunca editar migração já aplicada** — criar a próxima
(`0004_...`). Telas e funções: editar o arquivo e publicar de novo. Registrar a decisão em `07-decisoes.md`
e a mudança no checklist da fase em `06-fases.md`.
Testes: `bash supabase/testes/rodar.sh` (precisa de Postgres 16 local; com Deno, testa também as funções).
