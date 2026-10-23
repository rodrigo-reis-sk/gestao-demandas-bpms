# 06 — Fases

Marque `[x]` ao concluir. Cada fase termina com algo usável.

## Fase 0 — Definição ✅ (22/10/2026)
- [x] Escopo, arquitetura, modelo de dados, integração e regras de agrupamento documentados
- [x] Rascunho do banco (`0001_estrutura_inicial.sql`) e dados iniciais (`seed.sql`) testados localmente
- [x] Referências organizadas (pacote legado, configuração do ClickUp, protótipo do formulário)
- [x] Responder as pendências P1–P8 (`01-escopo.md`)
- [x] Regra de nomes sem referência ao ClickUp (D10) e banco ajustado (rascunho v1, retestado)

## Fase 1 — Banco e sincronização 🔧 (no ar em 23/10/2026; falta validar o piloto)
Objetivo: as tarefas dos consultores escolhidos aparecem no banco e se atualizam sozinhas.
Legenda: `[x]` feito · `[~]` código pronto e testado localmente, falta publicar no Supabase/GitHub.
Roteiro de implantação: `docs/08-implantacao.md`. Telas: https://rodrigo-reis-sk.github.io/gestao-demandas-bpms/ (repositório público, D25).
- [x] Criar o projeto no Supabase Free (`bucicoxjvokbsnynsmfh`); executar migração e seed
- [x] Tela de login (Supabase Auth, e-mail e senha — D20), com o mesmo e-mail do ClickUp (`web/login.html`)
- [x] **Testar o app OAuth do ClickUp (P9)** → sem permissão para criar app; seguimos com token pessoal de cada gestor (D19)
- [x] Edge Function `clickup-conectar` + botão "Conectar ao ClickUp" (token no Vault, e-mail = login) (`web/perfil.html`)
- [~] Escolher a conta da sincronização (Meu perfil → "Usar esta"; a 1ª conta conectada já vira a da sincronização)
- [x] Edge Function `clickup-sync`: membros → consultores (por e-mail), pastas/listas → `clientes_faps` (novas como "a analisar"), tarefas alteradas só de consultor **e** lista marcados, registros de tempo
- [~] Agendar com `pg_cron` a cada 20 min (`agendar_sincronizacao`); carga de 90 dias automática na 1ª vez e quando marcar consultor/lista novos (D22)
- [~] Edge Function `clickup-webhook` + registro do webhook pela tela; grava quem alterou em `tarefas_historico`
- [x] Telas mínimas: **consultores**, **listas** (a analisar no topo, contador no menu), **log da sincronização** e **início**
- [x] Migração `0002_sincronizacao.sql` + testes (`rodar.sh`: banco, tradução do ClickUp e cliente da API)
- [x] Ajustes da 1ª sincronização real: regras de listas, tela Listas por pasta, gerente FC/ED, tarefa-estrutura (migração 0003, D27–D29)
- [x] Decisões D18, D20–D24 aprovadas (P12) e checklist do piloto revisado para as regras da fase 2 (23/10/2026)
- [ ] Validar com o piloto: listas do piloto (checklist em `08-implantacao.md`, seção 9)

## Fase 2 — Demandas, agendas, kanban e painel de horas (replanejada em 23/10/2026, D30–D37)
- [x] Hierarquia Tarefa = demanda / Subtarefa = agenda, calculada no banco (migração 0004)
- [x] Sincronização de tudo das listas marcadas, carga desde 01/01/2026 por lista
- [x] Horas por agenda (estimativa → Período com almoço); realizadas × agendadas × planejadas
- [x] Tela **Demandas**: Cliente → Lista → Demanda → Agendas, escolha Sincronizar/Não (em lote por lista) e "não contar" por agenda
- [x] Ajustes após comparação com o ClickUp (Inovvati): junção de repetidos, mães que faltam, corte pela data da agenda (migração 0005, D38–D40)
- [x] Hierarquia robusta + visibilidade (migração 0006, D41–D42)
- [x] Tela única Demandas (listas + demandas + agendas), padrão "conta", FAP pelo número, script de reinício (migração 0007, D43–D46)
- [~] Botão "↻ Sincronizar" por demanda e "Considera no gerenciamento" Sim/Não (D48) — falta publicar a função `clickup-sync`
- [ ] Publicar, reiniciar a sincronização e validar com dados reais (carga completa, conferir horas de 3 demandas contra o ClickUp)
- [ ] **Kanban** espelhando o status do ClickUp, filtros por consultor, cliente e gerente
- [ ] **Painel de horas** por consultor × cliente × mês desde 01/01/2026 (`vw_horas_mes`), realizadas × agendadas
- [ ] Horas manuais por demanda (R4.2), se ainda fizer sentido
- [ ] Repositório/agrupamento só para exceções (D37), se aparecerem

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
