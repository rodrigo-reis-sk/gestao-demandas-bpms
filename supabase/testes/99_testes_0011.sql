-- Testes da migração 0011 (criação da tarefa na origem a partir da triagem). Rodado por rodar.sh.
\set ON_ERROR_STOP 1

-- Chamado novo da Semalo: dev Iago (tem usuário na origem), consultor André (ainda sem usuário na origem).
do $$
declare v_cli uuid := (select id from clientes where nome = 'Semalo');
begin
  perform gravar_chamado(jsonb_build_object(
    'id', '55555555-5555-5555-5555-555555555555', 'titulo', 'Relatório de comissão', 'cliente_id', v_cli,
    'desenvolvedor_id', (select id from consultores where email = 'iago.proenca@sankhya.com.br'),
    'contato_nome', 'Maria (financeiro)',
    'evidencias', jsonb_build_array(
      jsonb_build_object('texto', 'Abrir a tela', 'anexos', jsonb_build_array(
        jsonb_build_object('caminho', '55555555-5555-5555-5555-555555555555/1-1.jpg', 'tipo', 'image/jpeg', 'tamanho', 100),
        jsonb_build_object('caminho', '55555555-5555-5555-5555-555555555555/1-2.png', 'tipo', 'image/png', 'tamanho', 100))),
      jsonb_build_object('texto', 'Conferir o total'))), null);
end $$;

\echo '== C1 validações da reserva'
do $$
declare
  v_ch   uuid := '55555555-5555-5555-5555-555555555555';
  v_ges  uuid := '00000000-0000-0000-0000-000000000001';
  v_iago uuid := (select id from consultores where email = 'iago.proenca@sankhya.com.br');
  v_andre uuid := (select id from consultores where email = 'andre.acunha@sankhya.com.br');
  v_ls   uuid := (select id from clientes_faps where lista_id_externo = 'LS');
  v_l1   uuid := (select id from clientes_faps where lista_id_externo = 'L1');
  v_nao  uuid := (select f.id from clientes_faps f join clientes c on c.id = f.cliente_id
                   where c.nome = 'Semalo' and f.situacao_sincronizacao = 'a_analisar' limit 1);
begin
  -- não gestor
  begin perform reservar_criacao_tarefa(v_ch, '00000000-0000-0000-0000-000000000002', v_ls, v_iago);
        raise exception 'FALHOU: consultor reservou';
  exception when raise_exception then if sqlerrm not like 'Só gestores%' then raise; end if; end;
  -- lista de outro cliente
  begin perform reservar_criacao_tarefa(v_ch, v_ges, v_l1, v_iago); raise exception 'FALHOU: lista de outro cliente';
  exception when raise_exception then if sqlerrm not like 'Escolha uma lista do cliente%' then raise; end if; end;
  -- lista não marcada
  begin perform reservar_criacao_tarefa(v_ch, v_ges, v_nao, v_iago); raise exception 'FALHOU: lista não marcada';
  exception when raise_exception then if sqlerrm not like '%não está marcada para sincronizar%' then raise; end if; end;
  -- consultor sem usuário na origem
  begin perform reservar_criacao_tarefa(v_ch, v_ges, v_ls, v_iago, v_andre); raise exception 'FALHOU: consultor sem id externo';
  exception when raise_exception then if sqlerrm not like '%não tem usuário ligado na origem%' then raise; end if; end;
  if (select status from chamados where id = v_ch) <> 'novo' or (select criacao_situacao from chamados where id = v_ch) is not null then
    raise exception 'FALHOU: validação mexeu no chamado'; end if;
  raise notice 'ok validacoes';
end $$;

\echo '== C2 reserva aprova, trava e devolve os dados'
do $$
declare
  v_ch uuid := '55555555-5555-5555-5555-555555555555';
  d jsonb;
begin
  update consultores set id_externo = '555' where email = 'andre.acunha@sankhya.com.br';
  d := reservar_criacao_tarefa(v_ch, '00000000-0000-0000-0000-000000000001',
         (select id from clientes_faps where lista_id_externo = 'LS'),
         (select id from consultores where email = 'iago.proenca@sankhya.com.br'),
         (select id from consultores where email = 'andre.acunha@sankhya.com.br'));
  if d->'lista'->>'id_externo' <> 'LS' or d->'desenvolvedor'->>'id_externo' <> '222' or d->'consultor'->>'id_externo' <> '555'
     or d->>'parceiro_id_externo' <> '0a128c94-0f50-442c-a1d5-5b74a4b15222' or d->>'contato_nome' <> 'Maria (financeiro)'
     or jsonb_array_length(d->'evidencias') <> 2 or jsonb_array_length(d->'evidencias'->0->'anexos') <> 2
     or (d->'evidencias'->0->'anexos'->0->>'enviado')::boolean or d->>'pedido_por' is null then
    raise exception 'FALHOU: dados da criação %', d; end if;
  if (select status || '/' || criacao_situacao from chamados where id = v_ch) <> 'aprovado/criando' then
    raise exception 'FALHOU: status depois da reserva'; end if;
  -- clique duplo: segunda reserva recusada
  begin perform reservar_criacao_tarefa(v_ch, '00000000-0000-0000-0000-000000000001',
          (select id from clientes_faps where lista_id_externo = 'LS'), (select id from consultores where email = 'iago.proenca@sankhya.com.br'));
        raise exception 'FALHOU: reserva dupla';
  exception when raise_exception then if sqlerrm not like 'Já existe uma criação em andamento%' then raise; end if; end;
  -- trava vence em 3 minutos (função caiu no meio): pode tentar de novo
  update chamados set criacao_iniciada_em = now() - interval '4 minutes' where id = v_ch;
  perform reservar_criacao_tarefa(v_ch, '00000000-0000-0000-0000-000000000001',
          (select id from clientes_faps where lista_id_externo = 'LS'), (select id from consultores where email = 'iago.proenca@sankhya.com.br'),
          (select id from consultores where email = 'andre.acunha@sankhya.com.br'));
  raise notice 'ok reserva e trava';
end $$;

\echo '== C3 resultado: tarefa criada, prints e ligação pelo id'
do $$
declare v_ch uuid := '55555555-5555-5555-5555-555555555555';
begin
  perform registrar_criacao_tarefa(v_ch, 'criada', 'T-NOVA', 'https://app.clickup.com/t/T-NOVA', null);
  perform marcar_anexo_enviado((select a.id from chamados_anexos a join chamados_evidencias e on e.id = a.evidencia_id
                                 where e.chamado_id = v_ch and a.ordem = 1 and e.ordem = 1));
  if (select anexos_pendentes from vw_chamados where id = v_ch) <> 1 then raise exception 'FALHOU: anexos pendentes'; end if;
  -- erro depois: o id da tarefa continua gravado (nunca cria de novo)
  perform registrar_criacao_tarefa(v_ch, 'erro', null, null, 'Tarefa criada, mas 1 print não subiu');
  if (select tarefa_criada_id_externo from chamados where id = v_ch) <> 'T-NOVA' then raise exception 'FALHOU: perdeu o id'; end if;
  begin perform reservar_criacao_tarefa(v_ch, '00000000-0000-0000-0000-000000000001',
          (select id from clientes_faps where lista_id_externo = 'LS'), (select id from consultores where email = 'iago.proenca@sankhya.com.br'));
        raise exception 'FALHOU: reservou chamado que já tem tarefa';
  exception when raise_exception then if sqlerrm not like 'Este chamado já tem tarefa%' then raise; end if; end;
  -- a tarefa chega da origem com o nome trocado (sem o código): liga pelo id
  insert into tarefas (origem, id_externo, nome, lista_id_externo) values ('clickup', 'T-NOVA', 'Comissão (renomeada)', 'LS');
  if (select status from chamados where id = v_ch) <> 'tarefa_criada'
     or (select tarefa_id from chamados where id = v_ch) <> (select id from tarefas where id_externo = 'T-NOVA') then
    raise exception 'FALHOU: ligação pelo id'; end if;
  -- registrar de novo depois da ligação não desfaz o status
  perform registrar_criacao_tarefa(v_ch, 'criada', 'T-NOVA', null, 'ok');
  if (select status from chamados where id = v_ch) <> 'tarefa_criada' then raise exception 'FALHOU: status desfeito'; end if;
  raise notice 'ok resultado e ligacao';
end $$;

\echo '== C4 view para o gestor'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$ begin
  if not exists (select 1 from vw_chamados where id = '55555555-5555-5555-5555-555555555555'
                   and criacao_situacao = 'criada' and criacao_lista_nome = 'Semalo 28371 Avulso'
                   and criacao_por_nome is not null and criacao_url like 'https://%') then
    raise exception 'FALHOU: vw_chamados da criação'; end if;
  if (select lista_sugerida_id from vw_chamados where id = '55555555-5555-5555-5555-555555555555')
     <> (select id from clientes_faps where lista_id_externo = 'LS') then raise exception 'FALHOU: lista_sugerida_id'; end if;
  raise notice 'ok view';
end $$;

\echo '== C5 permissões: navegador não chama as funções da criação'
do $$ begin
  begin perform reservar_criacao_tarefa(gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid());
        raise exception 'FALHOU: authenticated chamou reservar';
  exception when insufficient_privilege then null; end;
  begin perform registrar_criacao_tarefa(gen_random_uuid(), 'criada'); raise exception 'FALHOU: authenticated chamou registrar';
  exception when insufficient_privilege then null; end;
  raise notice 'ok permissoes';
end $$;
reset role;
reset request.jwt.claim.sub;
update consultores set id_externo = null where email = 'andre.acunha@sankhya.com.br';
\echo '== FIM 0011'
