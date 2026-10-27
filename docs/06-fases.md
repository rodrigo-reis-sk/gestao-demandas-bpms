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
- [ ] Validar com o piloto: listas do piloto (checklist em `08-implantacao.md`, seção 9) — **adiado em 23/10/2026**: a sincronização está funcionando; os testes restantes seguem em paralelo à fase 2

## Fase 2 — Demandas, agendas, kanban e painel de horas (replanejada em 23/10/2026, D30–D37)
- [x] Hierarquia Tarefa = demanda / Subtarefa = agenda, calculada no banco (migração 0004)
- [x] Sincronização de tudo das listas marcadas, carga desde 01/01/2026 por lista
- [x] Horas por agenda (estimativa → Período com almoço); realizadas × agendadas × planejadas
- [x] Tela **Demandas**: Cliente → Lista → Demanda → Agendas, escolha Sincronizar/Não (em lote por lista) e "não contar" por agenda
- [x] Ajustes após comparação com o ClickUp (Inovvati): junção de repetidos, mães que faltam, corte pela data da agenda (migração 0005, D38–D40)
- [x] Hierarquia robusta + visibilidade (migração 0006, D41–D42)
- [x] Tela única Demandas (listas + demandas + agendas), padrão "conta", FAP pelo número, script de reinício (migração 0007, D43–D46)
- [x] Botão "↻ Sincronizar" por demanda e "Considera no gerenciamento" Sim/Não (D48) — função publicada em 23/10/2026
- [x] Publicar, reiniciar a sincronização e validar com dados reais — publicado, reiniciado e carga completa (50 listas) em 23/10/2026.
  Conferência de 3 demandas contra o ClickUp (23/10/2026):
  - Soldamaq "Demandas Marketing": **bate** (38h realizadas = estimativa; 44h rastreadas = ClickUp).
  - Semalo "Demandas do financeiro": **bate** (as 5 agendas de 2026 estão no banco; 4h realizadas, 16h agendadas).
  - Inovvati "2-Atendimento Folha": **não bate** — faltam 2 agendas de set/2026 (4h) que estão dentro de uma subtarefa de mês
    ("2026-09 Setembro") **abaixo de uma demanda real**; o banco as trata como demandas soltas. Mesmo caso em CG Telhas (4 demandas soltas no total).
    Somando as 2, bate com o ClickUp (50h estimadas, 6h rastreadas).
  - Webhook: rajada de eventos (~220 em 30 min) com ~30% de falhas por tempo esgotado (`gravar_tarefas` recalcula a hierarquia inteira
    a cada evento, até de lista não marcada). Nada se perdeu: a varredura recupera as das listas marcadas.
  - Correção pronta e testada: migração 0008 (D49 hierarquia, D50 recálculo por lista, D51 agendas **atrasadas**) e tela Demandas — falta aplicar e publicar. Motivo do D51: 332 agendas com data já passada (1.567h) contam como agendadas, contra 40 futuras (222h); 108 sem data.
- [x] Correções da validação: migração 0008 + tela Demandas com "atrasadas" (D49–D51) — no ar em 23/10/2026. Conferido: Inovvati "2-Atendimento Folha" com 8 agendas (11h realizadas, 12h atrasadas), nenhuma demanda solta, webhook sem falhas (42 eventos, 1,7 s em média)
- [~] **Kanban** espelhando o status do ClickUp, filtros por consultor, cliente e gerente (`web/kanban.html`, D52) — publicado; conferência do Rodrigo **adiada em 26/10/2026**, segue em paralelo à fase 3
- [~] **Painel de horas** por consultor × cliente × mês desde 01/01/2026 (`web/horas.html`, `vw_horas_mes`, D53), realizadas × agendadas × atrasadas — publicado; conferência **adiada em 26/10/2026**, segue em paralelo
- Adiados em 26/10/2026 (fazer só se precisar): horas manuais por demanda (R4.2) e repositório/agrupamento para exceções (D37)

## Fase 3 — Formulário do consultor, triagem e portal do cliente (decisões D54–D61, 26/10/2026)
Ordem (D56): primeiro formulário + triagem; depois o portal.
Legenda: `[~]` código pronto e testado localmente (`rodar.sh` + telas no navegador com o servidor simulado), falta publicar.
- [~] Migração `0009_chamados.sql`: desenvolvedor + consultor + gerente no chamado (D58), status `aguardando_informacao` e `aprovado`,
  link de complemento (D59), chave do formulário no Vault (D57), limite por IP (D60), bucket privado `evidencias`, `vw_chamados` + testes (`99_testes_0009.sql`)
- [~] Edge Function `formulario`: valida a chave do link (D57), limite por IP, campo-armadilha, confere o tipo real dos arquivos, grava chamado + evidências + prints (bucket privado `evidencias`); testes em `formulario.test.ts`
- [~] Protótipo migrado para `web/formulario.html` (listas de clientes/consultores/gerentes vindas da função; gerente sugerido pelo cliente; consultor lembrado no navegador)
- [~] Evidências em passos com prints em sequência (escolher, arrastar ou Ctrl+V); compressão para ~300 KB; rascunho salvo no navegador com os prints (R5.4) — `web/assets/evidencias.js`
- [~] Tela de **triagem** (`web/triagem.html`): ver o chamado e os prints (link temporário), escolher desenvolvedor e consultor, aprovar (nome `CH-xxxxx - Título` para copiar e lista sugerida), recusar com motivo, pedir informação (link para copiar), voltar para novo; link do formulário com "Trocar chave"
- [~] **Complemento** (`web/complementar.html`, D59): o consultor responde e acrescenta passos; o chamado volta para "novo"
- [~] Tarefa com `CH-xxxxx` no nome liga ao chamado: gatilho no banco, vale para a varredura e o webhook (D54, D61)
- [~] Contador de chamados novos no menu "Triagem" e no Início (D55)
- [ ] Publicar: `db push` (0009), `functions deploy formulario`, `git push`; roteiro e testes em `08-implantacao.md` §10
- [ ] Portal do cliente com link exclusivo (`links_portal`): abrir chamado e acompanhar o status (D56) — reaproveita `evidencias.js` e a função `formulario`

## Fase 4 — Criar no ClickUp e relatórios
- [ ] Edge Function `clickup-criar` com a regra do legado + código da demanda no nome + prints anexados
- [ ] Relatório de horas por consultor, cliente e período (ClickUp × manual)
- [ ] Visão do consultor (somente leitura das demandas dele), se P3 confirmar
