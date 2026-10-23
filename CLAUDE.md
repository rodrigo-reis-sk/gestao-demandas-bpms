# CLAUDE.md — memória do projeto Gestão de Demandas BP-MS

Leia este arquivo inteiro antes de qualquer trabalho neste projeto.

## Quem e para quê

- Dono do projeto: **Rodrigo Reis** (rodrigo.reis@sankhya.com.br), gestor da equipe de
  desenvolvimento/personalizações BP-MS (Sankhya, unidade MS).
- Objetivo: gestão **simples** de consultores/desenvolvedores e de suas demandas, com
  integração ao ClickUp, kanban configurável e controle de horas.
- Prioridade de projeto: **manutenção e gestão simples**, **custo zero** (planos free).

## Como o Rodrigo quer trabalhar

- **Antes de desenvolver, entender e discutir.** Em pedido novo ou ambíguo: resumir o
  entendimento, propor opções e perguntar. Só codificar depois do "ok".
- Responder em **português do Brasil**, direto e com linguagem de negócio.
- Trabalhar **por fases** (ver `docs/06-fases.md`). Uma conversa por fase.
- Ao final de cada fase: atualizar `docs/06-fases.md` (checklist), `docs/07-decisoes.md`
  e as pendências em `docs/01-escopo.md`.

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
atrasadas) — pronta e testada, falta `db push`. Depois: kanban e painel de horas.

## Como mexer em algo de uma fase já entregue

Pode voltar a qualquer fase a qualquer momento. Banco: **nunca editar migração já aplicada** — criar a próxima
(`0004_...`). Telas e funções: editar o arquivo e publicar de novo. Registrar a decisão em `07-decisoes.md`
e a mudança no checklist da fase em `06-fases.md`.
Testes: `bash supabase/testes/rodar.sh` (precisa de Postgres 16 local; com Deno, testa também as funções).
