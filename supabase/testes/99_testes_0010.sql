-- Testes da migração 0010 (portal do cliente). Rodado por rodar.sh depois de 99_testes_0009.sql.
\set ON_ERROR_STOP 1

\echo '== P1 link do portal: válido, desativado e vencido'
insert into links_portal (id, cliente_id, token, descricao)
select '33333333-3333-3333-3333-333333333333', id, 'tok-semalo', 'Key users' from clientes where nome = 'Semalo';
insert into links_portal (cliente_id, token, ativo) select id, 'tok-desligado', false from clientes where nome = 'Semalo';
insert into links_portal (cliente_id, token, expira_em) select id, 'tok-vencido', now() - interval '1 day' from clientes where nome = 'Semalo';
do $$ begin
  if (link_portal_valido('tok-semalo')).id is null then raise exception 'FALHOU: link valido recusado'; end if;
  if (link_portal_valido('tok-desligado')).id is not null or (link_portal_valido('tok-vencido')).id is not null
     or (link_portal_valido('')).id is not null or (link_portal_valido(null)).id is not null then
    raise exception 'FALHOU: link invalido aceito'; end if;
  if dados_portal('tok-vencido') is not null then raise exception 'FALHOU: portal abriu com link vencido'; end if;
  raise notice 'ok links';
end $$;

\echo '== P2 situação para o cliente'
do $$ begin
  if situacao_para_cliente('novo', 'portal_cliente', null, null) <> 'recebido'
     or situacao_para_cliente('aprovado', 'portal_cliente', null, null) <> 'recebido'
     or situacao_para_cliente('aguardando_informacao', 'portal_cliente', null, null) <> 'informacao'
     or situacao_para_cliente('aguardando_informacao', 'formulario_consultor', null, null) <> 'recebido'
     or situacao_para_cliente('tarefa_criada', 'portal_cliente', 'em andamento', 'custom') <> 'atendimento'
     or situacao_para_cliente('tarefa_criada', 'portal_cliente', 'Concluído', 'closed') <> 'concluido'
     or situacao_para_cliente('tarefa_criada', 'formulario_consultor', 'validado', 'done') <> 'concluido'
     or situacao_para_cliente('recusado', 'portal_cliente', null, null) <> 'nao_aprovado' then
    raise exception 'FALHOU: situacao para o cliente'; end if;
  raise notice 'ok situacao';
end $$;

\echo '== P3 chamado aberto pelo portal'
do $$
declare r jsonb;
begin
  begin perform gravar_chamado_portal('tok-desligado', '{"titulo":"x","solicitante_nome":"Ana","solicitante_email":"a@b"}');
        raise exception 'FALHOU: gravou com link desligado';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  begin perform gravar_chamado_portal('tok-semalo', '{"titulo":"x","solicitante_nome":" "}');
        raise exception 'FALHOU: gravou sem nome';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  r := gravar_chamado_portal('tok-semalo', jsonb_build_object(
         'id', '44444444-4444-4444-4444-444444444444', 'titulo', 'Erro na nota de devolução', 'prioridade', 'urgente',
         'solicitante_nome', 'Ana Key User', 'solicitante_email', 'ana@semalo.com.br',
         'cliente_id', (select id from clientes where nome = 'Germipasto'),        -- tentativa de trocar o cliente: ignorada
         'evidencias', jsonb_build_array(jsonb_build_object('texto', 'Abrir a devolução'))), '187.10.0.1');
  if not exists (select 1 from chamados where id = '44444444-4444-4444-4444-444444444444'
                   and canal = 'portal_cliente' and cliente_id = (select id from clientes where nome = 'Semalo')
                   and link_portal_id = '33333333-3333-3333-3333-333333333333' and desenvolvedor_id is null
                   and prioridade = 'urgente' and status = 'novo' and gerente_projetos_id is not null) then
    raise exception 'FALHOU: chamado do portal'; end if;
  raise notice 'ok chamado do portal %', r->>'codigo';
end $$;

\echo '== P4 o portal mostra todos os chamados do cliente, com situação simplificada'
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
select triar_chamado('44444444-4444-4444-4444-444444444444', 'pedir_informacao', 'Qual o número da nota?') is not null as pediu;
reset role;
reset request.jwt.claim.sub;
do $$
declare d jsonb := dados_portal('tok-semalo');
        x jsonb;
begin
  if d->>'cliente' <> 'Semalo' then raise exception 'FALHOU: cliente %', d->>'cliente'; end if;
  -- CH do consultor (0009, já com tarefa) e o do portal; nenhum de outro cliente
  if jsonb_array_length(d->'chamados') <> 2 then raise exception 'FALHOU: chamados do portal %', d->'chamados'; end if;
  select c into x from jsonb_array_elements(d->'chamados') c where c->>'canal' = 'portal_cliente';
  if x->>'situacao' <> 'informacao' or x->>'pergunta' <> 'Qual o número da nota?' or coalesce(x->>'token_complemento', '') = '' then
    raise exception 'FALHOU: pedido de informacao no portal %', x; end if;
  select c into x from jsonb_array_elements(d->'chamados') c where c->>'canal' = 'formulario_consultor';
  if x->>'situacao' <> 'atendimento' or x ? 'token_complemento' and x->>'token_complemento' is not null then
    raise exception 'FALHOU: chamado do consultor no portal %', x; end if;
  if (select ultimo_acesso_em from links_portal where token = 'tok-semalo') is null then
    raise exception 'FALHOU: ultimo acesso'; end if;
  raise notice 'ok portal lista';
end $$;

\echo '== P5 resposta pelo portal (mesmo complemento) e recusa com motivo visível'
do $$
declare v_tok text := (select token_complemento from chamados where id = '44444444-4444-4444-4444-444444444444');
begin
  perform gravar_complemento(v_tok, '[]'::jsonb, 'Nota 98765');
  if (select status from chamados where id = '44444444-4444-4444-4444-444444444444') <> 'novo' then
    raise exception 'FALHOU: resposta pelo portal'; end if;
  raise notice 'ok resposta';
end $$;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
select triar_chamado('44444444-4444-4444-4444-444444444444', 'recusar', 'Já é atendido pelo padrão do sistema') is not null as recusou;
do $$ begin
  if not exists (select 1 from vw_chamados where id = '44444444-4444-4444-4444-444444444444'
                   and situacao_cliente = 'nao_aprovado' and cliente_tem_portal and solicitante_nome = 'Ana Key User') then
    raise exception 'FALHOU: vw_chamados do portal'; end if;
  if (select chamados_abertos from vw_links_portal where token = 'tok-semalo') <> 1 then raise exception 'FALHOU: vw_links_portal'; end if;
  raise notice 'ok triagem do portal';
end $$;
reset role;
reset request.jwt.claim.sub;
do $$
declare x jsonb;
begin
  select c into x from jsonb_array_elements(dados_portal('tok-semalo')->'chamados') c where c->>'canal' = 'portal_cliente';
  if x->>'situacao' <> 'nao_aprovado' or x->>'motivo' <> 'Já é atendido pelo padrão do sistema' then
    raise exception 'FALHOU: motivo no portal %', x; end if;
  raise notice 'ok motivo visivel';
end $$;

\echo '== P6 permissões'
set role anon;
do $$ begin
  begin perform dados_portal('tok-semalo'); raise exception 'FALHOU: anon chamou dados_portal';
  exception when insufficient_privilege then null; end;
  begin perform gravar_chamado_portal('tok-semalo', '{}'); raise exception 'FALHOU: anon gravou pelo portal';
  exception when insufficient_privilege then null; end;
  raise notice 'ok anon bloqueado';
end $$;
reset role;
\echo '== FIM 0010'
