# 06 — Fases

Marque `[x]` ao concluir. Cada fase termina com algo usável.

## Fase 0 — Definição ✅ (22/10/2026)
- [x] Escopo, arquitetura, modelo de dados, integração e regras de agrupamento documentados
- [x] Rascunho do banco (`0001_estrutura_inicial.sql`) e dados iniciais (`seed.sql`) testados localmente
- [x] Referências organizadas (pacote legado, configuração do ClickUp, protótipo do formulário)
- [x] Responder as pendências P1–P8 (`01-escopo.md`)
- [x] Regra de nomes sem referência ao ClickUp (D10) e banco ajustado (rascunho v1, retestado)

## Fase 1 — Banco e sincronização 🔧 (código pronto em 22/10/2026; falta implantar e validar)
Objetivo: as tarefas dos consultores escolhidos aparecem no banco e se atualizam sozinhas.
Legenda: `[x]` feito · `[~]` código pronto e testado localmente, falta publicar no Supabase/GitHub.
Roteiro de implantação: `docs/08-implantacao.md`.
- [~] Criar o projeto no Supabase Free (feito: `bucicoxjvokbsnynsmfh`, conferido); executar migração e seed (`db push --include-seed`)
- [~] Tela de login (Supabase Auth, e-mail e senha — D20), com o mesmo e-mail do ClickUp (`web/login.html`)
- [x] **Testar o app OAuth do ClickUp (P9)** → sem permissão para criar app; seguimos com token pessoal de cada gestor (D19)
- [~] Edge Function `clickup-conectar` + botão "Conectar ao ClickUp" (token no Vault, e-mail = login) (`web/perfil.html`)
- [~] Escolher a conta da sincronização (Meu perfil → "Usar esta"; a 1ª conta conectada já vira a da sincronização)
- [~] Edge Function `clickup-sync`: membros → consultores (por e-mail), pastas/listas → `clientes_faps` (novas como "a analisar"), tarefas alteradas só de consultor **e** lista marcados, registros de tempo
- [~] Agendar com `pg_cron` a cada 20 min (`agendar_sincronizacao`); carga de 90 dias automática na 1ª vez e quando marcar consultor/lista novos (D22)
- [~] Edge Function `clickup-webhook` + registro do webhook pela tela; grava quem alterou em `tarefas_historico`
- [~] Telas mínimas: **consultores**, **listas** (a analisar no topo, contador no menu), **log da sincronização** e **início**
- [x] Migração `0002_sincronizacao.sql` + testes (`rodar.sh`: banco, tradução do ClickUp e cliente da API)
- [ ] Validar com o piloto: 5 consultores, ~50 tarefas (checklist em `08-implantacao.md`, seção 9)

## Fase 2 — Repositório, kanban e horas
- [ ] **Repositório**: lista de pendentes com sugestões, aceitar / nova demanda / agrupar em / ignorar / desfazer
- [ ] **Kanban**: colunas configuráveis, arrastar cards, filtros por consultor e cliente
- [ ] **Card**: etiqueta do cliente, avatar do consultor, código, título, nº de tarefas, horas registradas × manuais, ticket Sankhya, prioridade
- [ ] **Detalhe da demanda**: tarefas agrupadas (com link para a origem), histórico, lançamento de horas manuais
- [ ] Ajustar pesos do agrupamento com dados reais

## Fase 3 — Formulário do consultor, portal do cliente e triagem
- [ ] Migrar o protótipo (`referencia/prototipos/formulario-demandas.html`) para `web/formulario.html`, gravando pela Edge Function `formulario`
- [ ] Evidências em passos com prints em sequência; compressão das imagens; rascunho salvo no navegador
- [ ] Portal do cliente com link exclusivo (`links_portal`) e acompanhamento do status
- [ ] Tela de **triagem**: direcionar a um desenvolvedor (cria a demanda) ou enviar ao ClickUp
- [ ] Aviso de chamado novo (e-mail ou notificação)

## Fase 4 — Criar no ClickUp e relatórios
- [ ] Edge Function `clickup-criar` com a regra do legado + código da demanda no nome + prints anexados
- [ ] Relatório de horas por consultor, cliente e período (ClickUp × manual)
- [ ] Visão do consultor (somente leitura das demandas dele), se P3 confirmar
