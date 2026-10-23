-- Testes da migração 0007 (tela única: padrão "sincronizar" e FAP do cadastro pelo número).
\set ON_ERROR_STOP 1
\echo '== M1 Guatos: lista de projeto liga à FAP do cadastro'
select gravar_listas('[{"lista_id_externo":"LG","nome_lista":"Guatos 32363 P2 (Contabilidade e Contratos)","pasta_id_externo":"PG",
  "pasta_nome":"GUATOS - ED","fap":"32363","tipo":"projeto","ativa":true,"nome_cliente":"Guatos","sigla_gerente":"ED"}]');
do $$ begin
  if (select count(*) from clientes_faps where fap = '32363') <> 1 then raise exception 'FALHOU: duplicou a FAP 32363'; end if;
  if (select lista_id_externo || '/' || tipo from clientes_faps where fap = '32363') <> 'LG/projeto' then
    raise exception 'FALHOU: lista de projeto nao ligou a FAP do cadastro'; end if;
  raise notice 'ok guatos';
end $$;
\echo '== M2 demanda nova já conta'
update clientes_faps set situacao_sincronizacao = 'sincronizar' where lista_id_externo = 'LG';
select gravar_tarefas('clickup', '[{"id_externo":"g1","nome":"Contratos","status":"em andamento","lista_id_externo":"LG"},
  {"id_externo":"g1a","nome":"Dia 1","status":"concluído","status_tipo":"closed","lista_id_externo":"LG","tarefa_pai_id_externo":"g1",
   "minutos_estimados":480,"data_vencimento":"2026-10-01T12:00:00Z"}]');
do $$ begin
  if (select selecao from tarefas where id_externo = 'g1') <> 'sincronizar' then raise exception 'FALHOU: demanda nova deveria contar'; end if;
  if not exists (select 1 from vw_horas_mes where minutos_realizados = 480 and cliente_nome = 'Guatos') then
    raise exception 'FALHOU: horas da Guatos fora do painel'; end if;
  raise notice 'ok padrao sincronizar';
end $$;
\echo '== M3 reiniciar a sincronização'
\i ../manutencao/reiniciar_sincronizacao.sql
do $$ begin
  if exists (select 1 from tarefas where origem = 'clickup') then raise exception 'FALHOU: sobrou tarefa'; end if;
  if exists (select 1 from clientes_faps where situacao_sincronizacao <> 'a_analisar' or carregada_em is not null) then
    raise exception 'FALHOU: lista nao voltou para a analisar'; end if;
  if not exists (select 1 from clientes where nome = 'Guatos') then raise exception 'FALHOU: apagou cliente'; end if;
  raise notice 'ok reinicio';
end $$;
\echo '== FIM 0007'
