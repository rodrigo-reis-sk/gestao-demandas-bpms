-- Testes da migração 0008 (correções da validação de 23/10/2026).
\set ON_ERROR_STOP 1
select gravar_listas('[{"lista_id_externo":"LV","nome_lista":"Inovvati 32223 Avulso","pasta_id_externo":"PV",
  "pasta_nome":"INOVVATI - FC","fap":"32223","tipo":"avulso","ativa":true,"nome_cliente":"Inovvati","sigla_gerente":"FC"}]');
update clientes_faps set situacao_sincronizacao = 'sincronizar' where lista_id_externo = 'LV';

\echo '== N1 mês dentro de demanda real (D49)'
select gravar_tarefas('clickup', jsonb_build_array(
  '{"id_externo":"v1","nome":"2-Atendimento Folha","status":"em andamento","lista_id_externo":"LV"}'::jsonb,
  '{"id_externo":"v1a","nome":"Reoneração","status":"complete","status_tipo":"closed","lista_id_externo":"LV",
    "tarefa_pai_id_externo":"v1","minutos_estimados":240,"data_vencimento":"2026-05-20T12:00:00Z"}'::jsonb,
  '{"id_externo":"v1m","nome":"2026-09 Setembro","status":"em andamento","lista_id_externo":"LV","tarefa_pai_id_externo":"v1"}'::jsonb,
  '{"id_externo":"v1m1","nome":"Verificar pensão","status":"complete","status_tipo":"closed","lista_id_externo":"LV",
    "tarefa_pai_id_externo":"v1m","minutos_estimados":120,"data_vencimento":"2026-09-10T12:00:00Z"}'::jsonb,
  '{"id_externo":"v1m2","nome":"Chamado S-2026","status":"complete","status_tipo":"closed","lista_id_externo":"LV",
    "tarefa_pai_id_externo":"v1m","minutos_estimados":120,"data_vencimento":"2026-09-11T12:00:00Z"}'::jsonb));
do $$ begin
  if (select papel from tarefas where id_externo = 'v1m') <> 'estrutura' then raise exception 'FALHOU: mês deveria ser estrutura'; end if;
  if exists (select 1 from tarefas where id_externo in ('v1m1', 'v1m2') and papel <> 'agenda') then
    raise exception 'FALHOU: agenda dentro do mês virou demanda'; end if;
  if (select count(*) from tarefas a join tarefas d on d.id = a.demanda_tarefa_id
       where d.id_externo = 'v1' and a.eh_folha) <> 3 then raise exception 'FALHOU: demanda deveria ter 3 agendas'; end if;
  if (select minutos_realizados from vw_demandas where nome = '2-Atendimento Folha') <> 480 then
    raise exception 'FALHOU: realizadas deveriam ser 8h'; end if;
  raise notice 'ok mes dentro de demanda';
end $$;

\echo '== N2 mês direto na lista continua juntando repetidos (D38)'
select gravar_tarefas('clickup', jsonb_build_array(
  '{"id_externo":"vb","nome":"1-Atendimento Base","status":"atendimento base","lista_id_externo":"LV"}'::jsonb,
  '{"id_externo":"vbm","nome":"2026-10 Outubro","status":"em andamento","lista_id_externo":"LV","tarefa_pai_id_externo":"vb"}'::jsonb,
  '{"id_externo":"vb1","nome":"Ajustes DRE","status":"complete","status_tipo":"closed","lista_id_externo":"LV",
    "tarefa_pai_id_externo":"vbm","minutos_estimados":60,"data_vencimento":"2026-10-01T12:00:00Z"}'::jsonb,
  '{"id_externo":"vb2","nome":"Ajustes DRE","status":"complete","status_tipo":"closed","lista_id_externo":"LV",
    "tarefa_pai_id_externo":"vbm","minutos_estimados":60,"data_vencimento":"2026-10-02T12:00:00Z"}'::jsonb));
do $$ begin
  if (select count(distinct demanda_tarefa_id) from tarefas where id_externo in ('vb1', 'vb2')) <> 1 then
    raise exception 'FALHOU: repetidos abaixo de estrutura deveriam juntar'; end if;
  raise notice 'ok repetidos';
end $$;

\echo '== N3 lista não marcada não recalcula; recorte por lista (D50)'
do $$ declare r jsonb; begin
  r := gravar_tarefas('clickup', '[{"id_externo":"zz1","nome":"Outra","status":"aberto","lista_id_externo":"L_NAO_MARCADA"}]');
  if (r->>'ignoradas')::int <> 1 then raise exception 'FALHOU: deveria ignorar (%)', r; end if;
  if recalcular_hierarquia('clickup', array['LV']) <> 0 then raise exception 'FALHOU: recálculo da lista deveria estar em dia'; end if;
  raise notice 'ok recorte';
end $$;

\echo '== N4 agenda atrasada (D51)'
select gravar_tarefas('clickup', jsonb_build_array(
  '{"id_externo":"v2","nome":"Apoio financeiro","status":"em andamento","lista_id_externo":"LV"}'::jsonb,
  jsonb_build_object('id_externo','v2a','nome','Dia passado','status','não iniciado','lista_id_externo','LV',
    'tarefa_pai_id_externo','v2','minutos_estimados',240,'data_vencimento', (now() - interval '3 days')::text),
  jsonb_build_object('id_externo','v2b','nome','Dia futuro','status','não iniciado','lista_id_externo','LV',
    'tarefa_pai_id_externo','v2','minutos_estimados',120,'data_vencimento', (now() + interval '3 days')::text)));
do $$ begin
  if (select situacao_agenda from vw_agendas where nome = 'Dia passado') <> 'atrasada' then raise exception 'FALHOU: deveria ser atrasada'; end if;
  if (select situacao_agenda from vw_agendas where nome = 'Dia futuro') <> 'agendada' then raise exception 'FALHOU: deveria ser agendada'; end if;
  if (select minutos_atrasados || '/' || minutos_agendados || '/' || qtd_atrasadas from vw_demandas where nome = 'Apoio financeiro') <> '240/120/1' then
    raise exception 'FALHOU: horas da demanda'; end if;
  if (select sum(minutos_atrasados) from vw_horas_mes where cliente_nome = 'Inovvati') <> 240 then
    raise exception 'FALHOU: painel sem atrasadas'; end if;
  raise notice 'ok atrasadas';
end $$;
\echo '== FIM 0008'
