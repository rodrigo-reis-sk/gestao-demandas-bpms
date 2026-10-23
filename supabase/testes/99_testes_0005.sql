-- Testes da migração 0005 (junção de atendimentos repetidos, mães que faltam, corte pela data da agenda).
\set ON_ERROR_STOP 1
\echo '== J1 atendimentos repetidos no Atendimento Base viram uma demanda'
select gravar_tarefas('clickup', '[
 {"id_externo":"ib","nome":"1-Atendimento Base","status":"atendimento base","lista_id_externo":"LS","estrutura":true},
 {"id_externo":"r1","nome":"Automatizar os pedidos dos benefícios","status":"complete","status_tipo":"closed","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"ib","minutos_estimados":240,"data_vencimento":"2026-11-12T12:00:00Z","criada_na_origem":"2026-11-01T12:00:00Z"},
 {"id_externo":"r2","nome":"Automatizar os pedidos dos beneficios","status":"complete","status_tipo":"closed","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"ib","minutos_estimados":420,"data_vencimento":"2026-12-05T12:00:00Z","criada_na_origem":"2026-12-01T12:00:00Z"},
 {"id_externo":"r3","nome":"Atendimento solicitado pelo cliente","status":"não iniciado","lista_id_externo":"LS","tarefa_pai_id_externo":"ib","periodo":"08h-10h","data_vencimento":"2026-09-18T12:00:00Z"},
 {"id_externo":"r4","nome":"Atendimento solicitado pelo cliente","status":"não iniciado","lista_id_externo":"LS","tarefa_pai_id_externo":"ib","periodo":"08h-10h","data_vencimento":"2026-09-17T12:00:00Z"},
 {"id_externo":"r5","nome":"Automatizar os pedidos dos benefícios","status":"em andamento","lista_id_externo":"LS","tarefa_pai_id_externo":"ib"},
 {"id_externo":"r5a","nome":"Dia 1","status":"não iniciado","lista_id_externo":"LS","tarefa_pai_id_externo":"r5","minutos_estimados":60,"data_vencimento":"2026-12-10T12:00:00Z"},
 {"id_externo":"old1","nome":"Antigo de 2025","status":"complete","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"ib",
  "minutos_estimados":480,"data_vencimento":"2025-09-18T12:00:00Z","fechada_na_origem":"2025-09-19T12:00:00Z"}
]') as resultado;
select id_externo, papel, (select id_externo from tarefas r where r.id = t.demanda_tarefa_id) as demanda
  from tarefas t where id_externo in ('r1','r2','r3','r4','r5','r5a','old1') order by 1;
do $$
declare v record;
begin
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='r2') <> 'r1' then
    raise exception 'FALHOU: repetido (nome igual, sem acento) nao juntou no mais antigo'; end if;
  if (select papel from tarefas where id_externo='r2') <> 'agenda' then raise exception 'FALHOU: r2 deveria ser agenda'; end if;
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='r3') <> 'r4'
     and (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='r4') <> 'r3' then
    raise exception 'FALHOU: genericos nao juntaram'; end if;
  if (select papel from tarefas where id_externo='r5') <> 'demanda' then raise exception 'FALHOU: atendimento com subtarefas nao deveria juntar'; end if;
  select * into v from vw_demandas where id = (select id from tarefas where id_externo='r1');
  if v.qtd_agendas <> 2 or v.minutos_realizados <> 660 then raise exception 'FALHOU: demanda juntada %', row_to_json(v); end if;
  if exists (select 1 from vw_demandas where nome = 'Antigo de 2025') then raise exception 'FALHOU: demanda fechada em 2025 apareceu'; end if;
  raise notice 'ok juncao e corte';
end $$;

\echo '== J2 escolha do gestor fica no representante'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
update tarefas set selecao = 'nao_sincronizar' where id_externo = 'r1';   -- o gestor mexeu nesta
reset request.jwt.claim.sub;
-- chega um atendimento mais antigo com o mesmo nome: o escolhido continua sendo a demanda
select gravar_tarefas('clickup', '[{"id_externo":"r0","nome":"Automatizar os pedidos dos benefícios","status":"complete","status_tipo":"closed",
  "lista_id_externo":"LS","tarefa_pai_id_externo":"ib","minutos_estimados":60,"data_vencimento":"2026-10-01T12:00:00Z","criada_na_origem":"2026-10-01T12:00:00Z"}]');
do $$ begin
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='r0') <> 'r1' then
    raise exception 'FALHOU: representante escolhido mudou'; end if;
  raise notice 'ok representante estavel';
end $$;

\echo '== J3 mães que faltam'
select gravar_tarefas('clickup', '[{"id_externo":"c1","nome":"Agenda solta","lista_id_externo":"LS","tarefa_pai_id_externo":"pmae"},
                                    {"id_externo":"c2","nome":"Outra solta","lista_id_externo":"LS","tarefa_pai_id_externo":"p404"}]');
select * from pais_faltando('clickup', 10);
select gravar_tarefas('clickup', '[{"id_externo":"pmae","nome":"2-Evolução por área","status":"em andamento","lista_id_externo":"LX"}]') as mae;
select registrar_tarefas_ausentes('clickup', array['p404'], 'teste');
do $$ begin
  if not exists (select 1 from tarefas where id_externo = 'pmae') then raise exception 'FALHOU: mae em lista nao marcada nao entrou'; end if;
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='c1') <> 'pmae' then
    raise exception 'FALHOU: agenda nao subiu ate a mae'; end if;
  if exists (select 1 from pais_faltando('clickup', 10)) then raise exception 'FALHOU: ainda falta mae (p404 deveria estar em espera)'; end if;
  raise notice 'ok maes';
end $$;
\echo '== FIM 0005'
