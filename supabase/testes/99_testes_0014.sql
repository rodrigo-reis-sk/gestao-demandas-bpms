-- Testes da migração 0014 (só as pessoas acompanhadas entram nos painéis, D76). Rodado por rodar.sh.
\set ON_ERROR_STOP 1

-- Iago = marcado; "Pessoa Nova" = não marcada. D1: agendas do Iago, da Pessoa Nova, sem responsável e com os dois.
-- D2: só da Pessoa Nova (responsável também ela).
do $$
declare
  v_cli  uuid := (select id from clientes where nome = 'Semalo');
  v_iago uuid := (select id from consultores where email = 'iago.proenca@sankhya.com.br');
  v_nova uuid := (select id from consultores where email = 'nova@sankhya.com.br');
begin
  if (select sincronizar from consultores where id = v_nova) then raise exception 'cenário: Pessoa Nova deveria estar desmarcada'; end if;
  insert into tarefas (id, origem, id_externo, nome, cliente_id, lista_id_externo, status, papel, eh_folha, demanda_tarefa_id, nivel, selecao)
  values ('e1000000-0000-0000-0000-000000000001', 'clickup', 'P-D1', 'Demanda mista', v_cli, 'LS', 'em andamento', 'demanda', false, 'e1000000-0000-0000-0000-000000000001', 1, 'sincronizar'),
         ('e2000000-0000-0000-0000-000000000002', 'clickup', 'P-D2', 'Demanda só de não acompanhada', v_cli, 'LS', 'em andamento', 'demanda', false, 'e2000000-0000-0000-0000-000000000002', 1, 'sincronizar');
  insert into tarefas (id, origem, id_externo, nome, cliente_id, lista_id_externo, status, papel, eh_folha, demanda_tarefa_id, nivel,
                       selecao, data_agenda, minutos_agenda, situacao_agenda)
  values ('ea100000-0000-0000-0000-000000000001', 'clickup', 'P-A1', 'Iago', v_cli, 'LS', 'concluído', 'agenda', true, 'e1000000-0000-0000-0000-000000000001', 2, 'sincronizar', '2026-10-05 12:00-04', 120, 'realizada'),
         ('ea200000-0000-0000-0000-000000000002', 'clickup', 'P-A2', 'Nova', v_cli, 'LS', 'não iniciado', 'agenda', true, 'e1000000-0000-0000-0000-000000000001', 2, 'sincronizar', now() + interval '5 days', 240, 'agendada'),
         ('ea300000-0000-0000-0000-000000000003', 'clickup', 'P-A3', 'Sem responsável', v_cli, 'LS', 'concluído', 'agenda', true, 'e1000000-0000-0000-0000-000000000001', 2, 'sincronizar', '2026-10-06 12:00-04', 60, 'realizada'),
         ('ea400000-0000-0000-0000-000000000004', 'clickup', 'P-A4', 'Os dois', v_cli, 'LS', 'concluído', 'agenda', true, 'e1000000-0000-0000-0000-000000000001', 2, 'sincronizar', '2026-10-07 12:00-04', 30, 'realizada'),
         ('ea500000-0000-0000-0000-000000000005', 'clickup', 'P-A5', 'Nova sozinha', v_cli, 'LS', 'concluído', 'agenda', true, 'e2000000-0000-0000-0000-000000000002', 2, 'sincronizar', '2026-10-08 12:00-04', 90, 'realizada');
  insert into tarefas_responsaveis (tarefa_id, consultor_id, usuario_id_externo, nome_externo) values
    ('ea100000-0000-0000-0000-000000000001', v_iago, '222', 'Iago Proença'),
    ('ea200000-0000-0000-0000-000000000002', v_nova, '444', 'Pessoa Nova'),
    ('ea400000-0000-0000-0000-000000000004', v_nova, '444', 'Pessoa Nova'),
    ('ea400000-0000-0000-0000-000000000004', v_iago, '222', 'Iago Proença'),
    ('ea500000-0000-0000-0000-000000000005', v_nova, '444', 'Pessoa Nova'),
    ('e2000000-0000-0000-0000-000000000002', v_nova, '444', 'Pessoa Nova');
  insert into registros_tempo (origem, id_externo, tarefa_id, usuario_id_externo, consultor_id, inicio, fim, minutos) values
    ('clickup', 'PT1', 'ea500000-0000-0000-0000-000000000005', '444', v_nova, '2026-10-08 09:00-04', '2026-10-08 10:00-04', 60);
end $$;

\echo '== P1 agendas e demandas: só pessoa acompanhada conta'
do $$
declare d record;
begin
  if (select incluida from vw_agendas where nome = 'Nova') then raise exception 'FALHOU: agenda de não acompanhada incluída'; end if;
  if not (select incluida from vw_agendas where nome = 'Sem responsável') then raise exception 'FALHOU: sem responsável deveria contar'; end if;
  if (select consultor_nome || '/' || incluida::text from vw_agendas where nome = 'Os dois') <> 'Iago Proença/true' then
    raise exception 'FALHOU: com dois responsáveis vale o acompanhado'; end if;
  select * into d from vw_demandas where id = 'e1000000-0000-0000-0000-000000000001';
  if d.minutos_realizados <> 210 or d.minutos_agendados <> 0 or d.qtd_agendas <> 3 or not d.acompanhada or d.responsavel_acompanhado then
    raise exception 'FALHOU: totais da demanda mista %', row_to_json(d); end if;
  select * into d from vw_demandas where id = 'e2000000-0000-0000-0000-000000000002';
  if d.acompanhada or d.minutos_realizados <> 0 then raise exception 'FALHOU: demanda só de não acompanhada %', row_to_json(d); end if;
  raise notice 'ok agendas e demandas';
end $$;

\echo '== P2 horas: sem a pessoa não acompanhada, nem o tempo rastreado dela'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$ begin
  if exists (select 1 from vw_horas_dia where consultor_nome = 'Pessoa Nova') then raise exception 'FALHOU: horas da Pessoa Nova'; end if;
  if (select sum(minutos_realizados) from vw_horas_dia where demanda_nome = 'Demanda mista') <> 210 then raise exception 'FALHOU: horas da demanda mista'; end if;
  raise notice 'ok horas';
end $$;
reset role;

\echo '== P3 marcar a pessoa: aparece na hora, sem sincronizar de novo'
update consultores set sincronizar = true where email = 'nova@sankhya.com.br';
set role authenticated;
do $$ begin
  if not (select acompanhada from vw_demandas where id = 'e2000000-0000-0000-0000-000000000002') then raise exception 'FALHOU: demanda não apareceu'; end if;
  if (select sum(minutos_rastreados) from vw_horas_dia where consultor_nome = 'Pessoa Nova') <> 60 then raise exception 'FALHOU: rastreado não apareceu'; end if;
  raise notice 'ok marcar';
end $$;
reset role;
reset request.jwt.claim.sub;
update consultores set sincronizar = false where email = 'nova@sankhya.com.br';

\echo '== P4 acesso de consultor só para pessoa marcada'
do $$ begin
  begin perform preparar_acesso((select id from consultores where email = 'nova@sankhya.com.br'), 'consultor', '00000000-0000-0000-0000-000000000001');
        raise exception 'FALHOU: deu acesso a pessoa não marcada';
  exception when raise_exception then if sqlerrm not like 'Marque Pessoa Nova em "Acompanhar"%' then raise; end if; end;
  raise notice 'ok acesso so marcado';
end $$;

-- limpeza
delete from registros_tempo where id_externo = 'PT1';
delete from tarefas_responsaveis where tarefa_id in (select id from tarefas where id_externo like 'P-%');
delete from tarefas where id_externo like 'P-%';
\echo '== FIM 0014'
