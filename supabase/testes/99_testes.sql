-- Testes do rascunho do banco. Rodados por rodar.sh depois da migração e do seed (duas vezes).
\set ON_ERROR_STOP 1
grant select, insert, update, delete on all tables in schema public to authenticated;
-- execute nas funções: concedido pelos privilégios padrão (00_supabase_simulado.sql), como no Supabase
grant usage on schema extensions to authenticated;
-- Usuários
insert into auth.users values ('00000000-0000-0000-0000-000000000001','rodrigo.reis@sankhya.com.br'),
                              ('00000000-0000-0000-0000-000000000002','iago.proenca@sankhya.com.br');
insert into usuarios_sistema (id,nome,email,papel) values
 ('00000000-0000-0000-0000-000000000001','Rodrigo Reis','rodrigo.reis@sankhya.com.br','gestor');
insert into usuarios_sistema (id,nome,email,papel,consultor_id)
 select '00000000-0000-0000-0000-000000000002','Iago','iago.proenca@sankhya.com.br','consultor', id from consultores where email='iago.proenca@sankhya.com.br';

\echo '== T1 conta de integracao com e-mail igual: aceita'
insert into contas_integracao (usuario_id, email_externo, usuario_id_externo, usar_na_sincronizacao)
values ('00000000-0000-0000-0000-000000000001','Rodrigo.Reis@sankhya.com.br','111', true);
\echo '== T2 conta com e-mail diferente: deve recusar'
do $$ begin
  insert into contas_integracao (usuario_id, email_externo) values ('00000000-0000-0000-0000-000000000002','outro@x.com');
  raise exception 'FALHOU: aceitou e-mail diferente';
exception when raise_exception then
  if sqlerrm like 'FALHOU%' then raise; end if; raise notice 'ok recusou: %', sqlerrm;
end $$;

\echo '== T3 listas: seed entrou como a_analisar'
select situacao_sincronizacao, count(*) from clientes_faps group by 1;
-- consultor sincronizado
update consultores set id_externo='222', sincronizar=true where email='iago.proenca@sankhya.com.br';
-- gestor marca a lista Germipasto como sincronizar (simula auth.uid)
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
update clientes_faps set situacao_sincronizacao='sincronizar', lista_id_externo='L1'
 where fap='32221';
select fap, situacao_sincronizacao, analisada_por is not null as registrou_quem from clientes_faps where fap='32221';
select * from vw_pendencias_gestor;
reset request.jwt.claim.sub;

\echo '== T4 tarefas e agrupamento'
insert into demandas (titulo, cliente_id, consultor_responsavel_id, ticket_sankhya, coluna_id)
select 'Ajuste relatorio de comissao vendedores', c.id, co.id, '987654', k.id
from clientes c, consultores co, kanban_colunas k
where c.nome='Germipasto' and co.email='iago.proenca@sankhya.com.br' and k.tipo='entrada';

insert into tarefas (id, id_externo, nome, cliente_id, lista_id_externo, criada_na_origem, minutos_registrados, periodo, minutos_periodo, criada_por_id_externo, criada_por_nome)
select v.id::uuid, v.ext, v.nome, c.id, 'L1', now(), v.min, '08h-10h', 120, '222', 'Iago'
from clientes c, (values
 ('10000000-0000-0000-0000-000000000001','t1','Ajuste relatorio comissao vendedores dia 2',0),
 ('10000000-0000-0000-0000-000000000002','t2','Continuacao DEM-0001 relatorio',60),
 ('10000000-0000-0000-0000-000000000003','t3','Erro ticket 987654 na nota',0)
) v(id,ext,nome,min) where c.nome='Germipasto';
insert into tarefas (id, id_externo, nome, cliente_id) select '10000000-0000-0000-0000-000000000004','t4','Instalar impressora fiscal', id from clientes where nome='Brasol';
insert into tarefas_responsaveis (tarefa_id, usuario_id_externo, consultor_id)
select t.id, '222', c.id from tarefas t, consultores c where c.email='iago.proenca@sankhya.com.br';

select sugerir_agrupamento('10000000-0000-0000-0000-000000000001') as sug_t1;
select t.id_externo, s.pontuacao, s.status from sugestoes_agrupamento s join tarefas t on t.id=s.tarefa_id;
select sugerir_agrupamento('10000000-0000-0000-0000-000000000002') as sug_t2;
select sugerir_agrupamento('10000000-0000-0000-0000-000000000003') as sug_t3;
select sugerir_agrupamento('10000000-0000-0000-0000-000000000004') as sug_t4;
select id_externo, situacao, agrupada_por from tarefas order by id_externo;

\echo '== T5 duplicidade da origem: mesma tarefa externa não entra duas vezes'
do $$ begin
  insert into tarefas (id_externo, nome) values ('t1','dup');
  raise exception 'FALHOU';
exception when unique_violation then raise notice 'ok bloqueou duplicada'; end $$;

\echo '== T6 card e horas'
insert into registros_tempo (id_externo, tarefa_id, usuario_id_externo, consultor_id, inicio, minutos)
select 'r1','10000000-0000-0000-0000-000000000003','222', id, now(), 45 from consultores where email='iago.proenca@sankhya.com.br';
insert into apontamentos_manuais (demanda_id, consultor_id, data, minutos)
select d.id, d.consultor_responsavel_id, current_date, 60 from demandas d;
select codigo, cliente_nome, consultor_nome, qtd_tarefas, minutos_registrados, minutos_manuais from vw_kanban_cards;

\echo '== T7 RLS'
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
select 'gestor ve demandas' as t, count(*) from demandas;
select 'gestor ve contas' as t, count(*) from contas_integracao;
do $$ begin
  update contas_integracao set usar_na_sincronizacao=false;
  if found then raise exception 'FALHOU: gestor alterou conta'; end if;
  raise notice 'ok gestor nao altera contas_integracao';
end $$;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';
select 'consultor ve demandas dele' as t, count(*) from demandas;
select 'consultor ve tarefas' as t, count(*) from tarefas;
select 'consultor ve contas' as t, count(*) from contas_integracao;
do $$ begin
  perform aceitar_sugestao('10000000-0000-0000-0000-000000000004', (select id from demandas limit 1));
  raise exception 'FALHOU';
exception when raise_exception then
  if sqlerrm like 'FALHOU%' then raise; end if; raise notice 'ok consultor nao agrupa: %', sqlerrm;
end $$;
reset role;
set role anon;
do $$ begin perform 1 from tarefas; raise exception 'FALHOU';
exception when insufficient_privilege then raise notice 'ok anonimo sem acesso'; end $$;
reset role;
\echo '== T8 conta compartilhada BPMS'
insert into tarefas (id, id_externo, nome, fap) values
 ('20000000-0000-0000-0000-000000000001','b1','Atendimento Soldamaq','32222'),
 ('20000000-0000-0000-0000-000000000002','b2','Atendimento FAP sem de-para','99999');
insert into tarefas_responsaveis (tarefa_id, usuario_id_externo, nome_externo) values
 ('20000000-0000-0000-0000-000000000001','999','BPMS'),
 ('20000000-0000-0000-0000-000000000002','999','BPMS');
insert into registros_tempo (id_externo, tarefa_id, usuario_id_externo, inicio, minutos)
values ('rb1','20000000-0000-0000-0000-000000000001','999', now(), 30);
select t.id_externo, t.fap, c.nome as consultor from tarefas_responsaveis r
  join tarefas t on t.id=r.tarefa_id left join consultores c on c.id=r.consultor_id
 where r.nome_externo='BPMS' order by 1;
select 'tempo do BPMS foi para' as t, c.nome from registros_tempo r join consultores c on c.id=r.consultor_id where r.id_externo='rb1';
select 'id aprendido' as t, count(*) from responsavel_real_por_fap where usuario_id_externo='999';
select responsaveis_sem_pessoa from vw_pendencias_gestor;
\echo '== FIM'
