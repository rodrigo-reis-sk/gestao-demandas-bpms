-- Testes da migração 0006 (hierarquia robusta). Rodado por rodar.sh.
\set ON_ERROR_STOP 1
\echo '== K1 mãe "1-Atendimento Base" ainda fora do banco: repetidos já se juntam pela mãe'
select gravar_tarefas('clickup', '[
 {"id_externo":"z1","nome":"Ajustes no dashboard de Metas Orçamentárias","status":"concluído","status_tipo":"closed","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"baseNova","minutos_estimados":120,"data_vencimento":"2026-03-01T12:00:00Z","criada_na_origem":"2026-03-01T12:00:00Z"},
 {"id_externo":"z2","nome":"Ajustes no dashboard de Metas Orcamentarias","status":"concluído","status_tipo":"closed","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"baseNova","minutos_estimados":180,"data_vencimento":"2026-03-05T12:00:00Z","criada_na_origem":"2026-03-05T12:00:00Z"},
 {"id_externo":"z3","nome":"Atualizar situação do e-social","status":"não iniciado","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"baseNova","periodo":"08h-12h","data_vencimento":"2026-11-10T12:00:00Z"}
]');
do $$ begin
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='z2') <> 'z1' then
    raise exception 'FALHOU: sem a mae no banco, repetidos nao se juntaram'; end if;
  if (select papel from tarefas where id_externo='z3') <> 'demanda' then raise exception 'FALHOU: z3 deveria ser demanda propria'; end if;
  raise notice 'ok juncao sem a mae';
end $$;

\echo '== K2 a mãe chega gravada sem a marca de estrutura (versão antiga): o banco reconhece'
select gravar_tarefas('clickup', '[{"id_externo":"baseNova","nome":"1-Atendimento Base","status":"atendimento base","lista_id_externo":"LS"}]');
do $$ begin
  if (select estrutura::text || '/' || papel from tarefas where id_externo='baseNova') <> 'true/estrutura' then
    raise exception 'FALHOU: base nao reconhecida como estrutura'; end if;
  if (select r.id_externo from tarefas t join tarefas r on r.id = t.demanda_tarefa_id where t.id_externo='z2') <> 'z1' then
    raise exception 'FALHOU: juncao perdida quando a mae chegou'; end if;
  if (select qtd_agendas || '/' || minutos_realizados from vw_demandas where id = (select id from tarefas where id_externo='z1')) <> '2/300' then
    raise exception 'FALHOU: demanda juntada deveria ter 2 agendas e 5h'; end if;
  raise notice 'ok estrutura reconhecida no banco';
end $$;

\echo '== K3 visibilidade'
select gravar_tarefas('clickup', '[
 {"id_externo":"velho_aberto","nome":"Automatizar a geração dos eventos para a fila do eSocial","status":"não iniciado","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"baseNova","minutos_estimados":240,"data_vencimento":"2025-08-18T12:00:00Z"},
 {"id_externo":"velho_mexido","nome":"Fechado em 2025 mexido em 2026","status":"complete","status_tipo":"closed","lista_id_externo":"LS",
  "tarefa_pai_id_externo":"baseNova","minutos_estimados":240,"data_vencimento":"2025-09-15T12:00:00Z","fechada_na_origem":"2026-02-01T12:00:00Z"},
 {"id_externo":"proj_velho","nome":"Revitalização da Contabilidade","status":"em andamento","lista_id_externo":"LS"},
 {"id_externo":"proj_velho_a","nome":"Dia 1","status":"concluído","status_tipo":"closed","lista_id_externo":"LS","tarefa_pai_id_externo":"proj_velho",
  "minutos_estimados":480,"data_vencimento":"2025-07-21T12:00:00Z"}
]');
do $$ begin
  if exists (select 1 from vw_demandas where nome in ('Automatizar a geração dos eventos para a fila do eSocial', 'Fechado em 2025 mexido em 2026')) then
    raise exception 'FALHOU: atendimento solto de 2025 apareceu'; end if;
  if not exists (select 1 from vw_demandas where nome = 'Revitalização da Contabilidade' and minutos_realizados = 0) then
    raise exception 'FALHOU: projeto aberto deveria aparecer (sem horas de 2025)'; end if;
  raise notice 'ok visibilidade';
end $$;
\echo '== FIM 0006'
