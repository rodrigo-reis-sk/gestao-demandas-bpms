-- Testes da fase 1 (sincronização). Rodados por rodar.sh depois de 99_testes.sql.
-- Cada bloco "do $$" levanta erro com 'FALHOU' se o resultado não for o esperado.
\set ON_ERROR_STOP 1

\echo '== S1 duração do Período'
do $$ begin
  if minutos_do_periodo('08h-10h') <> 120 or minutos_do_periodo('9h - 12h') <> 180
     or minutos_do_periodo('Feriado') is not null or minutos_do_periodo(null) is not null then
    raise exception 'FALHOU: minutos_do_periodo';
  end if;
  raise notice 'ok periodo';
end $$;

\echo '== S2 membros → consultores'
select gravar_membros('[
  {"usuario_id_externo":"222","nome":"Iago Proença","email":"Iago.Proenca@sankhya.com.br"},
  {"usuario_id_externo":"333","nome":"Cleber Nascimento","email":"cleber.nascimento@pectecnologia.com.br"},
  {"usuario_id_externo":"999","nome":"BPMS","email":"bpms@sankhya.com.br"},
  {"usuario_id_externo":"444","nome":"Pessoa Nova","email":"nova@sankhya.com.br"},
  {"usuario_id_externo":"555","nome":"Convidado sem email"}
]'::jsonb) as membros;
do $$ begin
  if (select id_externo from consultores where email='cleber.nascimento@pectecnologia.com.br') <> '333' then
    raise exception 'FALHOU: nao ligou Cleber pelo e-mail'; end if;
  if exists (select 1 from consultores where nome='BPMS') then
    raise exception 'FALHOU: conta compartilhada virou consultor'; end if;
  if not exists (select 1 from consultores where email='nova@sankhya.com.br' and not sincronizar) then
    raise exception 'FALHOU: membro novo nao entrou desmarcado'; end if;
  raise notice 'ok membros';
end $$;

\echo '== S3 listas descobertas'
select gravar_listas('[
  {"lista_id_externo":"L1","nome_lista":"Germipasto 32221 Avulso","pasta_id_externo":"P1","pasta_nome":"Germipasto","fap":"32221","tipo":"avulso","ativa":true},
  {"lista_id_externo":"L2","nome_lista":"BCM 31863 Avulso","pasta_id_externo":"P2","pasta_nome":"BCM","fap":"31863","tipo":"avulso","ativa":true},
  {"lista_id_externo":"L3","nome_lista":"Cliente Novo 40000 Avulso","pasta_id_externo":"P3","pasta_nome":"Cliente Novo","fap":"40000","tipo":"avulso","ativa":true},
  {"lista_id_externo":"L4","nome_lista":"Z-Antiga 11111 Avulso","pasta_id_externo":"P4","pasta_nome":"PRO-INFO","fap":"11111","tipo":"avulso","ativa":false},
  {"lista_id_externo":"L5","nome_lista":"Soldamaq 32222 Avulso","pasta_id_externo":"P5","pasta_nome":"SOLDAMAQ","fap":"32222","tipo":"avulso","ativa":true},
  {"lista_id_externo":"L6","nome_lista":"Planos","pasta_id_externo":"P6","pasta_nome":"3- Planos de Ação","tipo":"outro","ativa":true,"administrativa":true}
]'::jsonb) as listas;
select lista_id_externo, fap, situacao_sincronizacao, ativa, (select nome from clientes c where c.id=f.cliente_id) as cliente
  from clientes_faps f where lista_id_externo is not null order by 1;
do $$ begin
  if (select count(*) from clientes_faps where fap='31863') <> 1 then
    raise exception 'FALHOU: duplicou a FAP do seed em vez de ligar'; end if;
  if (select situacao_sincronizacao from clientes_faps where lista_id_externo='L3') <> 'a_analisar' then
    raise exception 'FALHOU: lista nova nao entrou a_analisar'; end if;
  if (select situacao_sincronizacao from clientes_faps where lista_id_externo='L4') <> 'nao_sincronizar' then
    raise exception 'FALHOU: lista encerrada deveria entrar nao_sincronizar'; end if;
  if (select c.nome from clientes_faps f join clientes c on c.id=f.cliente_id where lista_id_externo='L4') <> 'Pro-Info' then
    raise exception 'FALHOU: nao achou o cliente pela pasta com grafia diferente'; end if;
  if (select cliente_id from clientes_faps where lista_id_externo='L6') is not null then
    raise exception 'FALHOU: pasta administrativa ganhou cliente'; end if;
  raise notice 'ok listas';
end $$;
-- de novo: não duplica nada
select gravar_listas('[{"lista_id_externo":"L3","nome_lista":"Cliente Novo 40000 Avulso","pasta_nome":"Cliente Novo","fap":"40000","tipo":"avulso","ativa":true}]') as listas_de_novo;

\echo '== S4 filtros e início da busca'
update clientes_faps set situacao_sincronizacao='sincronizar' where lista_id_externo='L5';
update consultores set sincronizar=true where email='cleber.nascimento@pectecnologia.com.br';
select filtros_sincronizacao();
select * from inicio_busca_tarefas('clickup');
do $$ begin
  if not (select carga_completa from inicio_busca_tarefas('clickup')) then
    raise exception 'FALHOU: sem sincronizacao anterior deveria ser carga completa'; end if;
end $$;
-- (comandos separados: cada um tem o seu "agora")
insert into sincronizacoes (tipo, sucesso) values ('periodica', true);
do $$ begin
  if (select carga_completa from inicio_busca_tarefas('clickup')) then
    raise exception 'FALHOU: depois de sincronizar deveria ser incremental'; end if;
end $$;
update consultores set sincronizar=true where email='nova@sankhya.com.br';
do $$ begin
  if not (select carga_completa from inicio_busca_tarefas('clickup')) then
    raise exception 'FALHOU: consultor marcado agora deveria pedir carga completa'; end if;
  raise notice 'ok inicio da busca';
end $$;
update consultores set sincronizar=false where email='nova@sankhya.com.br';

\echo '== S5 tarefas'
select gravar_tarefas('clickup', '[
  {"id_externo":"n1","nome":"Novo relatorio de estoque","lista_id_externo":"L1","status":"em andamento",
   "periodo":"09h-12h","parceiro_id_externo":"65c6af23-8e9d-4e75-a802-6e97de4f9530",
   "criada_na_origem":"2026-10-20T12:00:00Z","atualizada_na_origem":"2026-10-20T12:00:00Z",
   "responsaveis":[{"usuario_id_externo":"222","nome_externo":"Iago Proença"}]},
  {"id_externo":"n2","nome":"De consultor nao marcado","lista_id_externo":"L1",
   "responsaveis":[{"usuario_id_externo":"444","nome_externo":"Pessoa Nova"}]},
  {"id_externo":"n3","nome":"Lista ainda a analisar","lista_id_externo":"L3",
   "responsaveis":[{"usuario_id_externo":"222","nome_externo":"Iago Proença"}]},
  {"id_externo":"n4","nome":"Atendimento pela conta BPMS","lista_id_externo":"L5",
   "responsaveis":[{"usuario_id_externo":"999","nome_externo":"BPMS"}]},
  {"id_externo":"t2","nome":"Continuacao DEM-0001 relatorio (renomeada)","lista_id_externo":"L1",
   "atualizada_na_origem":"2026-10-21T10:00:00Z",
   "responsaveis":[{"usuario_id_externo":"222","nome_externo":"Iago Proença"}]}
]'::jsonb) as resultado;
do $$
declare r jsonb;
begin
  if not exists (select 1 from tarefas where id_externo='n1' and minutos_periodo=180 and situacao='pendente'
                   and cliente_id=(select id from clientes where nome='Germipasto') and fap='32221') then
    raise exception 'FALHOU: n1 nao entrou como esperado'; end if;
  if exists (select 1 from tarefas where id_externo in ('n2','n3')) then
    raise exception 'FALHOU: entrou tarefa de consultor ou lista nao marcados'; end if;
  if (select c.nome from tarefas t join tarefas_responsaveis r on r.tarefa_id=t.id join consultores c on c.id=r.consultor_id
       where t.id_externo='n4') <> 'Cleber Nascimento' then
    raise exception 'FALHOU: conta BPMS nao virou o Cleber'; end if;
  if (select nome from tarefas where id_externo='t2') not like '%(renomeada)' then
    raise exception 'FALHOU: tarefa existente nao foi atualizada'; end if;
  if (select situacao from tarefas where id_externo='t2') <> 'agrupada' then
    raise exception 'FALHOU: atualizacao apagou o agrupamento'; end if;
  -- responsável que saiu é removido
  r := gravar_tarefas('clickup', '[{"id_externo":"n1","nome":"Novo relatorio de estoque","lista_id_externo":"L1",
        "atualizada_na_origem":"2026-10-22T12:00:00Z","responsaveis":[{"usuario_id_externo":"333","nome_externo":"Cleber"}]}]');
  if (r->>'alteradas')::int <> 1 or (r->>'novas')::int <> 0 then raise exception 'FALHOU: contagem %', r; end if;
  if exists (select 1 from tarefas_responsaveis rr join tarefas t on t.id=rr.tarefa_id
              where t.id_externo='n1' and rr.usuario_id_externo='222') then
    raise exception 'FALHOU: responsavel antigo ficou'; end if;
  raise notice 'ok tarefas';
end $$;

\echo '== S6 registros de tempo'
select gravar_registros_tempo('clickup', '2026-10-01', '2026-10-31', array['222','333'], '[
  {"id_externo":"te1","tarefa_id_externo":"n1","usuario_id_externo":"333","inicio":"2026-10-20T12:00:00Z","fim":"2026-10-20T13:30:00Z","minutos":90},
  {"id_externo":"te2","tarefa_id_externo":"n1","usuario_id_externo":"333","inicio":"2026-10-21T12:00:00Z","minutos":30},
  {"id_externo":"te3","tarefa_id_externo":"fora","usuario_id_externo":"333","inicio":"2026-10-21T12:00:00Z","minutos":30}
]') as tempo;
select gravar_registros_tempo('clickup', '2026-10-01', '2026-10-31', array['222','333'], '[
  {"id_externo":"te1","tarefa_id_externo":"n1","usuario_id_externo":"333","inicio":"2026-10-20T12:00:00Z","minutos":90}
]') as tempo_de_novo;
do $$ begin
  if (select excluido_na_origem from registros_tempo where id_externo='te2') is not true then
    raise exception 'FALHOU: registro sumido nao foi marcado excluido'; end if;
  if (select c.nome from registros_tempo r join consultores c on c.id=r.consultor_id where r.id_externo='te1') <> 'Cleber Nascimento' then
    raise exception 'FALHOU: tempo sem consultor'; end if;
  if exists (select 1 from registros_tempo where id_externo='te3') then
    raise exception 'FALHOU: gravou tempo de tarefa fora do banco'; end if;
  raise notice 'ok tempo';
end $$;

\echo '== S7 exclusão e histórico'
select gravar_historico_tarefa('clickup', 'n1', '[{"id_externo":"h1","evento":"status","campo":"status","valor_anterior":"backlog base","valor_novo":"em andamento","autor_id_externo":"222","autor_nome":"Iago"}]') as hist;
select gravar_historico_tarefa('clickup', 'n1', '[{"id_externo":"h1","evento":"status"}]') as hist_repetido;
select marcar_tarefa_excluida('clickup', 'n4', '222', 'Iago') as excluiu;
do $$ begin
  if (select count(*) from tarefas_historico h join tarefas t on t.id=h.tarefa_id where t.id_externo='n1') <> 1 then
    raise exception 'FALHOU: historico duplicado ou ausente'; end if;
  if not (select excluida_na_origem from tarefas where id_externo='n4') then
    raise exception 'FALHOU: nao marcou excluida'; end if;
  raise notice 'ok historico/exclusao';
end $$;

\echo '== S8 contas e Vault'
-- conta do Rodrigo (T1 criou sem token): a Edge Function grava o token
select salvar_conta_integracao('00000000-0000-0000-0000-000000000001','clickup','rodrigo.reis@sankhya.com.br','111','Rodrigo Reis','oauth','tok_rodrigo') is not null as salvou;
select conta_id is not null as tem_conta, token from ler_token_sincronizacao('clickup');
do $$ begin
  perform salvar_conta_integracao('00000000-0000-0000-0000-000000000002','clickup','outro@x.com','9','X','oauth','tok');
  raise exception 'FALHOU: aceitou e-mail diferente';
exception when raise_exception then
  if sqlerrm like 'FALHOU%' then raise; end if; raise notice 'ok recusou e-mail diferente';
end $$;
-- segunda conta (consultor Iago também conectou): não toma a sincronização
select salvar_conta_integracao('00000000-0000-0000-0000-000000000002','clickup','iago.proenca@sankhya.com.br','222','Iago','token_pessoal','pk_iago') is not null as salvou_iago;
do $$ begin
  if (select token from ler_token_sincronizacao('clickup')) <> 'tok_rodrigo' then
    raise exception 'FALHOU: conta da sincronizacao mudou sozinha'; end if;
  if (select token from ler_token_usuario('00000000-0000-0000-0000-000000000002','clickup')) <> 'pk_iago' then
    raise exception 'FALHOU: token do usuario'; end if;
  raise notice 'ok contas';
end $$;

\echo '== S9 permissões das funções'
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
do $$ begin
  perform gravar_tarefas('clickup', '[]');
  raise exception 'FALHOU: usuario logado chamou funcao interna';
exception when insufficient_privilege then raise notice 'ok gestor nao chama funcao interna'; end $$;
do $$ begin
  perform * from ler_token_sincronizacao('clickup');
  raise exception 'FALHOU: usuario logado leu token';
exception when insufficient_privilege then raise notice 'ok token protegido'; end $$;
-- gestor escolhe a conta do Iago para a sincronização
select definir_conta_sincronizacao((select id from contas_integracao where usuario_id='00000000-0000-0000-0000-000000000002'));
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';
do $$ begin
  perform definir_conta_sincronizacao((select id from contas_integracao limit 1));
  raise exception 'FALHOU: consultor escolheu conta';
exception when raise_exception then
  if sqlerrm like 'FALHOU%' then raise; end if; raise notice 'ok consultor nao escolhe conta';
end $$;
-- cada um desconecta a própria conta
select desconectar_conta((select id from contas_integracao where usuario_id='00000000-0000-0000-0000-000000000002'));
reset role;
reset request.jwt.claim.sub;
do $$ begin
  if exists (select 1 from ler_token_sincronizacao('clickup')) then
    raise exception 'FALHOU: conta desconectada continua na sincronizacao'; end if;
  if exists (select 1 from vault.secrets where name like 'conta_clickup_00000000-0000-0000-0000-000000000002') then
    raise exception 'FALHOU: token nao saiu do Vault'; end if;
  raise notice 'ok desconectar';
end $$;
set role service_role;
select (gravar_tarefas('clickup', '[]')->>'lidas') as service_role_chama;
reset role;

\echo '== S10 agendamento'
select agendar_sincronizacao('https://exemplo.supabase.co/');
select agendar_sincronizacao('https://exemplo.supabase.co');
select jobname, schedule, command from cron.job order by jobname;
select disparar_sincronizacao('periodica');
do $$ begin
  if (select count(*) from cron.job) <> 2 then raise exception 'FALHOU: agendamento duplicado'; end if;
  if not exists (select 1 from net.chamadas
                  where url = 'https://exemplo.supabase.co/functions/v1/clickup-sync'
                    and conferir_chave_agendamento(headers->>'x-chave-agendamento')) then
    raise exception 'FALHOU: chamada sem a chave'; end if;
  if conferir_chave_agendamento('errada') or conferir_chave_agendamento(null) then
    raise exception 'FALHOU: aceitou chave errada'; end if;
  raise notice 'ok agendamento';
end $$;
\echo '== FIM FASE 1'
