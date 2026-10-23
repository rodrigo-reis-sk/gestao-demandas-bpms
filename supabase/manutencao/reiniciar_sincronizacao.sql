-- =============================================================================
-- REINICIAR A SINCRONIZAÇÃO (rodar à mão no SQL Editor do Supabase, só quando decidido)
--
-- Apaga TODAS as tarefas/agendas vindas do ClickUp (com responsáveis, histórico e tempo) e
-- devolve TODAS as listas para "a analisar" (as regras automáticas reaplicam na próxima varredura:
-- internas e encerradas viram "não sincronizar", Avulso de cliente conhecido vira "sugerida").
-- NÃO apaga: clientes, consultores, contas conectadas, configurações, log.
-- Exceção consciente à D8 (nunca apagar tarefa): pedido do Rodrigo em 23/10/2026 para refazer do zero.
-- =============================================================================
begin;

-- o que vai sair (confira antes do commit)
select 'tarefas' as o_que, count(*) from public.tarefas where origem = 'clickup'
union all select 'registros de tempo', count(*) from public.registros_tempo where origem = 'clickup'
union all select 'listas marcadas', count(*) from public.clientes_faps where situacao_sincronizacao <> 'a_analisar';

delete from public.sugestoes_agrupamento
 where tarefa_id in (select id from public.tarefas where origem = 'clickup');
delete from public.registros_tempo where origem = 'clickup';
update public.tarefas set demanda_tarefa_id = null where origem = 'clickup';   -- evita ordem de exclusão
delete from public.tarefas where origem = 'clickup';                          -- responsáveis e histórico vão junto
delete from public.tarefas_ausentes where origem = 'clickup';

update public.clientes_faps
   set situacao_sincronizacao = 'a_analisar', analisada_por = null, analisada_em = null,
       carregada_em = null, sugerida = false, observacao = null;

commit;
-- Depois: Log → Sincronizar agora (descobre de novo e aplica as regras), escolha as listas na tela Demandas
-- e clique em Sincronizar agora até sumir "Carga em andamento".
