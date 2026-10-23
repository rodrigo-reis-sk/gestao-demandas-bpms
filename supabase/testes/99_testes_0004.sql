-- Testes da migração 0004 (demandas e agendas pela hierarquia). Rodado por rodar.sh.
\set ON_ERROR_STOP 1
\echo '== H1 horas do Período com almoço'
do $$ begin
  if minutos_do_periodo('08h-18h') <> 480 or minutos_do_periodo('14h-18h') <> 240
     or minutos_do_periodo('08h-12h') <> 240 or minutos_do_periodo('08h-10h') <> 120 then
    raise exception 'FALHOU: periodo com almoco'; end if;
  raise notice 'ok periodo com almoco';
end $$;

\echo '== H2 hierarquia'
insert into clientes_faps (cliente_id, fap, nome_lista, pasta_nome, lista_id_externo, tipo, situacao_sincronizacao)
select id, '28371', 'Semalo 28371 Avulso', 'SEMALO - FC', 'LS', 'avulso', 'sincronizar' from clientes where nome = 'Semalo';
insert into clientes_faps (fap, nome_lista, lista_id_externo, tipo, situacao_sincronizacao)
values ('99998', 'Outra 99998 Avulso', 'LX', 'avulso', 'nao_sincronizar');

select gravar_tarefas('clickup', '[
 {"id_externo":"b1","nome":"1-Atendimento Base","status":"atendimento base","lista_id_externo":"LS","estrutura":true},
 {"id_externo":"m1","nome":"2026-10 Outubro","status":"em andamento","lista_id_externo":"LS","tarefa_pai_id_externo":"b1","estrutura":true},
 {"id_externo":"a1","nome":"Ajuste na nota","status":"concluído","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"m1",
  "periodo":"08h-18h","data_vencimento":"2026-10-10T12:00:00Z","responsaveis":[{"usuario_id_externo":"222","nome_externo":"Iago"}]},
 {"id_externo":"a2","nome":"Relatório de giro","status":"em andamento","lista_id_externo":"LS","tarefa_pai_id_externo":"m1"},
 {"id_externo":"a2s1","nome":"Dia 1","status":"concluído","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"a2",
  "minutos_estimados":240,"periodo":"08h-18h","data_vencimento":"2026-10-01T12:00:00Z","responsaveis":[{"usuario_id_externo":"222"}]},
 {"id_externo":"a2s2","nome":"Dia 2","status":"não executado","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"a2",
  "periodo":"08h-12h","data_vencimento":"2026-10-02T12:00:00Z"},
 {"id_externo":"a2s3","nome":"Dia 3","status":"não iniciado","lista_id_externo":"LS","tarefa_pai_id_externo":"a2",
  "periodo":"14h-18h","data_vencimento":"2026-11-03T12:00:00Z"},
 {"id_externo":"d1","nome":"Controle de Pesagens","status":"em validação","lista_id_externo":"LS","minutos_estimados":9000,"etapa":"Atendimento avulso","agenda_tipo":"Planejamento"},
 {"id_externo":"s1","nome":"Customização tela","status":"em andamento","lista_id_externo":"LS","tarefa_pai_id_externo":"d1"},
 {"id_externo":"s1a","nome":"Tela - dia 1","status":"concluído","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"s1","minutos_estimados":480,"data_vencimento":"2026-08-27T12:00:00Z"},
 {"id_externo":"s2","nome":"Portaria","status":"concluído","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"d1","minutos_estimados":240,"data_vencimento":"2026-08-24T12:00:00Z"},
 {"id_externo":"x1","nome":"Fora","lista_id_externo":"LX"}
]') as resultado;
select id_externo, papel, nivel, eh_folha, minutos_agenda, situacao_agenda,
       (select id_externo from tarefas r where r.id = t.demanda_tarefa_id) as demanda, selecao
  from tarefas t where id_externo in ('b1','m1','a1','a2','a2s1','a2s2','a2s3','d1','s1','s1a','s2') order by id_externo;
do $$
declare v record;
begin
  if exists (select 1 from tarefas where id_externo = 'x1') then raise exception 'FALHOU: entrou lista nao marcada'; end if;
  if (select papel||'/'||selecao from tarefas where id_externo='b1') <> 'estrutura/nao_sincronizar' then raise exception 'FALHOU: estrutura'; end if;
  if (select papel||'/'||eh_folha||'/'||minutos_agenda||'/'||situacao_agenda from tarefas where id_externo='a1') <> 'demanda/true/480/realizada' then
    raise exception 'FALHOU: atendimento sem subtarefas deveria ser demanda e a propria agenda'; end if;
  if (select papel from tarefas where id_externo='a2') <> 'demanda' then raise exception 'FALHOU: a2 demanda'; end if;
  if (select minutos_agenda from tarefas where id_externo='a2s1') <> 240 then raise exception 'FALHOU: estimativa antes do periodo'; end if;
  if (select situacao_agenda from tarefas where id_externo='a2s2') <> 'nao_executada' then raise exception 'FALHOU: nao executada'; end if;
  if (select papel from tarefas where id_externo='s1') <> 'etapa' then raise exception 'FALHOU: nivel do meio = etapa'; end if;
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='s1a') <> 'd1' then
    raise exception 'FALHOU: agenda deveria subir ate a demanda d1'; end if;
  select * into v from vw_demandas where nome = 'Relatório de giro';
  if v.minutos_realizados <> 240 or v.minutos_agendados <> 240 or v.qtd_agendas <> 3 then
    raise exception 'FALHOU: horas da demanda %', row_to_json(v); end if;
  select * into v from vw_demandas where nome = 'Controle de Pesagens';
  if v.minutos_realizados <> 720 or v.minutos_planejados <> 9000 or v.etapa <> 'Atendimento avulso' or v.cliente_nome <> 'Semalo' then
    raise exception 'FALHOU: Controle de Pesagens %', row_to_json(v); end if;
  if (select demandas_a_analisar from vw_pendencias_gestor) < 3 then raise exception 'FALHOU: contador de demandas'; end if;
  raise notice 'ok hierarquia e horas';
end $$;

\echo '== H3 seleção'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
update tarefas set selecao = 'sincronizar' where id_externo in ('a2', 'd1');
update tarefas set selecao = 'nao_sincronizar' where id_externo = 's2';
reset request.jwt.claim.sub;
select * from vw_horas_mes order by mes;
do $$ begin
  if (select selecao_por from tarefas where id_externo='a2') is null then raise exception 'FALHOU: nao registrou quem escolheu'; end if;
  if exists (select 1 from vw_agendas where incluida and demanda_id = (select id from tarefas where id_externo='a1')) then
    raise exception 'FALHOU: agenda de demanda nao escolhida entrou'; end if;
  if (select minutos_realizados from vw_demandas where nome='Controle de Pesagens') <> 480 then
    raise exception 'FALHOU: agenda marcada nao_sincronizar continuou somando'; end if;
  if (select sum(minutos_realizados) from vw_horas_mes) <> 720 then
    raise exception 'FALHOU: painel por mes (esperado 240 + 480 realizados)'; end if;
  raise notice 'ok selecao';
end $$;

\echo '== H4 carga por lista'
select * from listas_para_sincronizar() where lista_id_externo = 'LS';
select marcar_listas_carregadas(array['LS']);
update clientes_faps set situacao_sincronizacao = 'nao_sincronizar' where lista_id_externo = 'LS';
update clientes_faps set situacao_sincronizacao = 'sincronizar' where lista_id_externo = 'LS';
do $$ begin
  if (select carregada_em from clientes_faps where lista_id_externo = 'LS') is not null then
    raise exception 'FALHOU: lista desmarcada e marcada de novo deveria recarregar'; end if;
  raise notice 'ok carga por lista';
end $$;
\echo '== FIM 0004'
