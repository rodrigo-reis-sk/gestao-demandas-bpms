# 01 — Escopo

Última revisão: 22/10/2026 (código da fase 1 pronto; implantação pendente).

## Problema

A gestão das demandas de desenvolvimento/personalização está espalhada no ClickUp. Uma mesma
demanda atendida em vários dias aparece como várias tarefas, o que dificulta saber:
quantas demandas reais existem, quem está com o quê, em que etapa e quantas horas cada uma
consumiu.

## Usuários

| Perfil | O que faz |
|---|---|
| Gestores (Rodrigo e outros) | Acesso total. Configura consultores e colunas, agrupa tarefas, move cards, informa horas, faz a triagem dos chamados, cria tarefas no ClickUp |
| Consultor / desenvolvedor | Ver as próprias demandas, só leitura (fase 4). Abrir demanda pelo formulário externo |
| Cliente | Abrir chamado pelo portal (link) e acompanhar o status |

## Requisitos

### R1 — Integração com o ClickUp
- R1.1 Buscar tarefas **por consultor**. Ter um cadastro de consultores com a opção
  "sincronizar sim/não" para escolher quem entra.
- R1.1b Buscar **todas as listas** do espaço e permitir marcar quais sincronizam. Lista nova
  entra como "a analisar" (não sincroniza) e fica destacada até o gestor decidir.
  Uma tarefa entra se o consultor **e** a lista estiverem marcados.
- R1.2 Quando uma tarefa já integrada muda no ClickUp (título, status, datas, responsável,
  tempo, campos), atualizar no sistema.
- R1.3 Trazer o tempo registrado no ClickUp por tarefa e por consultor.
- R1.4 Criar tarefas novas no ClickUp a partir do sistema (alocar demanda a um consultor).
  Seguir a mesma regra do "Lançar ClickUp" (lista Avulso do parceiro → subtarefa do mês).
- R1.5 **Autoria**: cada gestor conecta a própria conta do ClickUp (mesmo e-mail do login);
  a tarefa criada pelo sistema sai com a conta de quem criou. Alterações feitas direto no
  ClickUp registram quem alterou.

### R2 — Repositório de tarefas
- R2.1 Toda tarefa sincronizada entra no repositório como **pendente de classificação**.
- R2.2 O gestor agrupa a tarefa numa demanda existente, cria uma demanda nova a partir dela
  ou ignora a tarefa.
- R2.3 O sistema **sugere** o agrupamento com uma pontuação e os motivos
  (ver `05-agrupamento-de-tarefas.md`), e agrupa sozinho quando o vínculo é certo.
- R2.4 Uma tarefa pode ser desagrupada ou movida para outra demanda.

### R3 — Kanban
- R3.1 Colunas **configuráveis** (nome, ordem, cor, limite de cards, tipo).
- R3.2 Cada card = uma demanda. Mover entre colunas e reordenar.
- R3.3 Card mostra, de forma fácil de identificar: **cliente** (etiqueta colorida),
  **consultor** (iniciais/foto), título, código, nº de tarefas agrupadas, horas
  (ClickUp × manual), ticket Sankhya, prioridade.
- R3.4 Filtros/visões: geral, por consultor, por cliente.

### R4 — Horas
- R4.1 Tempo ClickUp: soma do tempo das tarefas agrupadas, por consultor e por dia.
- R4.2 Tempo manual: o gestor lança data, consultor, horas e observação por demanda.
- R4.3 Mostrar os dois totais lado a lado e a diferença. Opcional: horas estimadas.

### R5 — Entrada de demandas
- R5.1 **Formulário externo** (link aberto) para consultor abrir demanda com os campos:
  gerente de projetos, consultor líder, cliente, contato do cliente, nº ticket Sankhya,
  desenvolvedor (obrigatório), evidências (passo a passo com prints na sequência),
  já abriu chamado na Sankhya?, origem da demanda, prints.
- R5.2 **Portal do cliente**: link para o cliente abrir chamado e acompanhar.
- R5.3 **Triagem**: todo chamado entra como "novo". O gestor decide entre
  (a) direcionar a um desenvolvedor → vira demanda no kanban, ou
  (b) criar tarefa no ClickUp → a tarefa volta pela sincronização já ligada à demanda.
- R5.4 O rascunho do formulário não pode se perder se a pessoa fechar a tela.

### R6 — Simplicidade e custo
- Planos gratuitos (Supabase Free, hospedagem estática free).
- Manutenção por uma pessoa, sem servidor próprio para cuidar.

## Fora de escopo (por enquanto)

- Faturamento, OS ou integração com o Sankhya Experience (o pacote legado já cuida disso).
- App mobile nativo (a tela web deve funcionar no celular).
- Relatórios avançados / BI (só os totais de horas na fase 4).

## Pendências respondidas (22/10/2026)

| # | Pergunta | Resposta |
|---|---|---|
| P1 | Tempo no controle nativo ou pelo campo Período? | Ler os dois: o tempo nativo e, se vazio, calcular pelo Período (D9) |
| P2 | Mover card muda o status no ClickUp? | Não. O sistema só envia tarefas novas ao ClickUp (D3) |
| P3 | Quem usa o sistema? | Gestores com acesso total. Consultor vê só o que é dele, em leitura, na fase 4 (D15) |
| P4 | Volume | ~10 consultores e ~150 tarefas/mês. **Piloto: 5 consultores e ~50 tarefas** |
| P5 | Token do ClickUp | Gestores são admin. Cada gestor usa a própria conta, ligada pelo mesmo e-mail, para saber quem criou/alterou (D11, D12, D13) |
| P6 | Supabase ou Firebase? | Supabase Free (D1) |
| P7 | Quais listas sincronizar? | Buscar todas e parametrizar. Lista nova entra desmarcada, como "a analisar" (D14) |
| P8 | Portal com login? | Link exclusivo por cliente, com opção de desativar (D16) |
| P9 | App OAuth do ClickUp? | 22/10/2026: a tela *Settings → Apps* da conta do Rodrigo não mostra "Criar aplicativo" (só dono/admin do **workspace** cria). Seguimos com o **token pessoal de cada gestor (D19)**. OAuth fica opcional: se o dono do workspace criar o app, basta preencher o Client ID |
| P11 | Repositório público ou privado? | Público, por ora (Rodrigo, 22/10/2026). Telas no GitHub Pages (D25). Atenção: `seed.sql` tem e-mails da equipe e a lista de clientes |

## Pendências em aberto

| # | Pergunta | Impacto | Como resolver |
|---|---|---|---|
| P10 | A equipe ainda atribui tarefas novas à conta compartilhada "BPMS" ou é só histórico (FAPs do Cleber)? | Se for só histórico, orientar a equipe a atribuir direto à pessoa; o de-para (D17) continua para o histórico | Sem urgência — avaliar numa release futura |
| P12 | As decisões propostas na fase 1 (D18, D20–D24) estão ok? | Ajustes pequenos de comportamento | Revisar `07-decisoes.md` antes da validação do piloto |
