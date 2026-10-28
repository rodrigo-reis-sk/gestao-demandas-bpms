-- Testes da migração 0012 (horas por dia com tempo rastreado e leitura do consultor). Rodado por rodar.sh.
\set ON_ERROR_STOP 1

-- Duas demandas da Semalo: D1 com agenda do Iago (realizada) e do Cleber (futura); D2 só do Cleber.
do $$
declare
  v_cli   uuid := (select id from clientes where nome = 'Semalo');
  v_iago  uuid := (select id from consultores where email = 'iago.proenca@sankhya.com.br');
  v_cleb  uuid := (select id from consultores where nome = 'Cleber Nascimento');
begin
  insert into tarefas (id, origem, id_externo, nome, cliente_id, lista_id_externo, status, papel, eh_folha, demanda_tarefa_id, nivel, selecao)
  values ('d1000000-0000-0000-0000-000000000001', 'clickup', 'R-D1', 'Relatório de estoque', v_cli, 'LS', 'em andamento', 'demanda', false, 'd1000000-0000-0000-0000-000000000001', 1, 'sincronizar'),
         ('d2000000-0000-0000-0000-000000000002', 'clickup', 'R-D2', 'Integração bancária', v_cli, 'LS', 'em andamento', 'demanda', false, 'd2000000-0000-0000-0000-000000000002', 1, 'sincronizar');
  insert into tarefas (id, origem, id_externo, nome, cliente_id, lista_id_externo, status, papel, eh_folha, demanda_tarefa_id, nivel,
                       selecao, data_agenda, minutos_agenda, situacao_agenda)
  values ('a1000000-0000-0000-0000-000000000001', 'clickup', 'R-A1', 'Estoque dia 1', v_cli, 'LS', 'concluído', 'agenda', true, 'd1000000-0000-0000-0000-000000000001', 2,
          'sincronizar', '2026-10-05 12:00-04', 120, 'realizada'),
         ('a2000000-0000-0000-0000-000000000002', 'clickup', 'R-A2', 'Estoque dia 2', v_cli, 'LS', 'não iniciado', 'agenda', true, 'd1000000-0000-0000-0000-000000000001', 2,
          'sincronizar', now() + interval '20 days', 60, 'agendada'),
         ('a3000000-0000-0000-0000-000000000003', 'clickup', 'R-A3', 'Banco dia 1', v_cli, 'LS', 'concluído', 'agenda', true, 'd2000000-0000-0000-0000-000000000002', 2,
          'sincronizar', '2026-10-06 12:00-04', 240, 'realizada');
  insert into tarefas_responsaveis (tarefa_id, consultor_id, usuario_id_externo, nome_externo) values
    ('a1000000-0000-0000-0000-000000000001', v_iago, '222', 'Iago Proença'),
    ('a2000000-0000-0000-0000-000000000002', v_cleb, '333', 'Cleber Nascimento'),
    ('a3000000-0000-0000-0000-000000000003', v_cleb, '333', 'Cleber Nascimento');
  insert into registros_tempo (origem, id_externo, tarefa_id, usuario_id_externo, consultor_id, inicio, fim, minutos) values
    ('clickup', 'RT1', 'a1000000-0000-0000-0000-000000000001', '222', v_iago, '2026-10-05 09:00-04', '2026-10-05 10:30-04', 90),
    ('clickup', 'RT2', 'a3000000-0000-0000-0000-000000000003', '333', v_cleb, '2026-10-06 08:00-04', '2026-10-06 11:20-04', 200),
    ('clickup', 'RT3', 'd1000000-0000-0000-0000-000000000001', '222', v_iago, '2025-12-20 08:00-04', '2025-12-20 09:00-04', 60);  -- antes do corte
end $$;

\echo '== H1 horas por dia: agendas e tempo rastreado na mesma linha (gestor)'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare r record;
begin
  select * into r from vw_horas_dia where demanda_nome = 'Relatório de estoque' and consultor_nome = 'Iago Proença';
  if r.dia <> '2026-10-05' or r.mes <> '2026-10-01' or r.minutos_realizados <> 120 or r.minutos_rastreados <> 90
     or r.cliente_nome <> 'Semalo' then
    raise exception 'FALHOU: linha do Iago %', row_to_json(r); end if;
  if (select sum(minutos_agendados) from vw_horas_dia where demanda_nome = 'Relatório de estoque' and consultor_nome = 'Cleber Nascimento') <> 60 then
    raise exception 'FALHOU: agendada do Cleber'; end if;
  if (select minutos_rastreados from vw_horas_dia where demanda_nome = 'Integração bancária') <> 200 then
    raise exception 'FALHOU: rastreado do Cleber'; end if;
  if exists (select 1 from vw_horas_dia where dia < '2026-01-01') then raise exception 'FALHOU: tempo antes do corte'; end if;
  raise notice 'ok horas por dia';
end $$;
reset role;

\echo '== H2 consultor logado: só as demandas dele e só as horas dele, sem gravar'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';   -- Iago, papel consultor
set role authenticated;
do $$
declare n int;
begin
  if not eh_consultor() or eh_gestor() then raise exception 'FALHOU: papel do Iago'; end if;
  if not exists (select 1 from vw_demandas where nome = 'Relatório de estoque') then raise exception 'FALHOU: Iago não vê a demanda dele'; end if;
  if exists (select 1 from vw_demandas where nome = 'Integração bancária') then raise exception 'FALHOU: Iago vê demanda de outro'; end if;
  -- enxerga as agendas da demanda dele (inclusive a do colega), para acompanhar o andamento
  if (select count(*) from vw_agendas where demanda_id = 'd1000000-0000-0000-0000-000000000001') <> 2 then
    raise exception 'FALHOU: agendas da demanda do Iago'; end if;
  -- horas: só as dele
  if exists (select 1 from vw_horas_dia where consultor_nome is distinct from 'Iago Proença') then raise exception 'FALHOU: horas de outro consultor'; end if;
  if (select sum(minutos_rastreados) from vw_horas_dia) <> 90 then raise exception 'FALHOU: rastreado do Iago'; end if;
  if exists (select 1 from registros_tempo where consultor_id is distinct from consultor_do_usuario()) then raise exception 'FALHOU: tempo de outro'; end if;
  -- não grava nada
  update tarefas set nome = 'x' where id = 'd1000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FALHOU: consultor alterou tarefa'; end if;
  begin
    insert into registros_tempo (origem, tarefa_id, inicio, minutos) values ('interno', 'd1000000-0000-0000-0000-000000000001', now(), 10);
    raise exception 'FALHOU: consultor gravou tempo';
  exception when insufficient_privilege then null; end;
  -- triagem e chamados continuam só do gestor
  if exists (select 1 from chamados) then raise exception 'FALHOU: consultor vê chamados'; end if;
  raise notice 'ok consultor';
end $$;
reset role;

\echo '== H3 consultor desativado não vê nada'
update usuarios_sistema set ativo = false where id = '00000000-0000-0000-0000-000000000002';
set role authenticated;
do $$ begin
  if exists (select 1 from vw_demandas) or exists (select 1 from vw_horas_dia) then raise exception 'FALHOU: desativado ainda vê'; end if;
  raise notice 'ok desativado';
end $$;
reset role;
update usuarios_sistema set ativo = true where id = '00000000-0000-0000-0000-000000000002';
reset request.jwt.claim.sub;

-- limpeza: não interferir nos testes seguintes
delete from registros_tempo where id_externo in ('RT1', 'RT2', 'RT3');
delete from tarefas_responsaveis where tarefa_id in ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 'a3000000-0000-0000-0000-000000000003');
delete from tarefas where id_externo in ('R-A1', 'R-A2', 'R-A3', 'R-D1', 'R-D2');
\echo '== FIM 0012'
