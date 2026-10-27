-- Testes da migração 0009 (formulário do consultor, triagem e ligação CH- ↔ tarefa). Rodado por rodar.sh.
\set ON_ERROR_STOP 1
update consultores set sincronizar = true where email in ('iago.proenca@sankhya.com.br', 'andre.acunha@sankhya.com.br');
update clientes_faps set situacao_sincronizacao = 'sincronizar' where lista_id_externo = 'LS';   -- Semalo 28371 Avulso

\echo '== F1 chave do formulário no Vault'
do $$ begin
  if not conferir_chave_formulario(ler_segredo('chave_formulario')) then raise exception 'FALHOU: chave certa recusada'; end if;
  if conferir_chave_formulario('errada') or conferir_chave_formulario(null) or conferir_chave_formulario('') then
    raise exception 'FALHOU: chave errada aceita'; end if;
  raise notice 'ok chave do formulario';
end $$;

\echo '== F2 listas do formulário: só clientes com lista marcada e consultores marcados'
do $$
declare d jsonb := dados_formulario();
begin
  if not exists (select 1 from jsonb_array_elements(d->'clientes') x where x->>'nome' = 'Semalo') then
    raise exception 'FALHOU: Semalo (lista marcada) deveria aparecer: %', d->'clientes'; end if;
  if exists (select 1 from jsonb_array_elements(d->'clientes') x where x->>'nome' = 'Agrosalles') then
    raise exception 'FALHOU: cliente sem lista marcada apareceu'; end if;
  if jsonb_array_length(d->'consultores') <> (select count(*) from consultores where ativo and sincronizar) or jsonb_array_length(d->'consultores') < 2 then raise exception 'FALHOU: consultores marcados = %', d->'consultores'; end if;
  if not exists (select 1 from jsonb_array_elements(d->'gerentes') x where x->>'nome' = 'Elson Afonso Duarte') then
    raise exception 'FALHOU: gerente faltando'; end if;
  raise notice 'ok listas do formulario';
end $$;

\echo '== F3 limite de envios por IP (10 por hora)'
do $$
declare i int; v boolean;
begin
  for i in 1..10 loop
    if not registrar_envio_ip('10.0.0.9', 'abertura') then raise exception 'FALHOU: bloqueou cedo (%)', i; end if;
  end loop;
  if registrar_envio_ip('10.0.0.9', 'abertura') then raise exception 'FALHOU: 11º envio passou'; end if;
  if not registrar_envio_ip('10.0.0.10', 'abertura') then raise exception 'FALHOU: outro IP bloqueado'; end if;
  update envios_por_ip set criado_em = now() - interval '61 minutes' where ip = '10.0.0.9';
  if not registrar_envio_ip('10.0.0.9', 'abertura') then raise exception 'FALHOU: nao liberou depois de 1 hora'; end if;
  raise notice 'ok limite por ip';
end $$;

\echo '== F4 gravar chamado com passos e anexos'
do $$
declare r jsonb; v_dev uuid; v_cons uuid; v_cli uuid;
begin
  select id into v_dev from consultores where email = 'andre.acunha@sankhya.com.br';
  select id into v_cons from consultores where email = 'iago.proenca@sankhya.com.br';
  select id into v_cli from clientes where nome = 'Semalo';
  update clientes set gerente_projetos_id = (select id from consultores where email = 'filipe.capulo@sankhya.com.br') where id = v_cli;
  r := gravar_chamado(jsonb_build_object(
    'id', '11111111-1111-1111-1111-111111111111',
    'titulo', '  Ajuste DANFE  ', 'prioridade', 'Alta', 'tipo', 'Ajuste / correção',
    'cliente_id', v_cli, 'desenvolvedor_id', v_dev, 'consultor_id', v_cons,
    'chamado_sankhya_aberto', false, 'ticket_sankhya', '999',
    'evidencias', jsonb_build_array(
       jsonb_build_object('texto', 'Abrir a nota', 'anexos', jsonb_build_array(
          jsonb_build_object('caminho', '11111111-1111-1111-1111-111111111111/1-1.jpg', 'tipo', 'image/jpeg', 'tamanho', 1000),
          jsonb_build_object('caminho', '11111111-1111-1111-1111-111111111111/1-2.jpg', 'tipo', 'image/jpeg', 'tamanho', 2000))),
       jsonb_build_object('texto', '   ', 'anexos', '[]'::jsonb),
       jsonb_build_object('texto', 'Clicar em imprimir'))), '200.1.2.3');
  if r->>'codigo' !~ '^CH-\d{5}$' then raise exception 'FALHOU: codigo %', r; end if;
  if not exists (select 1 from chamados where id = '11111111-1111-1111-1111-111111111111'
                   and titulo = 'Ajuste DANFE' and prioridade = 'alta' and status = 'novo'
                   and desenvolvedor_id = v_dev and consultor_id = v_cons and ticket_sankhya is null
                   and gerente_projetos_id is not null and ip_origem = '200.1.2.3'::inet) then
    raise exception 'FALHOU: chamado gravado errado'; end if;
  if (select count(*) from chamados_evidencias where chamado_id = '11111111-1111-1111-1111-111111111111') <> 2 then
    raise exception 'FALHOU: passo vazio deveria ser ignorado'; end if;
  if (select string_agg(a.caminho_storage, ',' order by e.ordem, a.ordem) from chamados_evidencias e
        join chamados_anexos a on a.evidencia_id = e.id where e.chamado_id = '11111111-1111-1111-1111-111111111111')
     <> '11111111-1111-1111-1111-111111111111/1-1.jpg,11111111-1111-1111-1111-111111111111/1-2.jpg' then
    raise exception 'FALHOU: anexos fora de ordem'; end if;
  if (select chamados_novos from vw_pendencias_gestor) <> 1 then raise exception 'FALHOU: contador da triagem'; end if;
  raise notice 'ok gravar chamado';
end $$;

\echo '== F5 validações do chamado'
do $$
declare v_dev uuid := (select id from consultores where email = 'andre.acunha@sankhya.com.br');
begin
  begin perform gravar_chamado(jsonb_build_object('titulo', 'x', 'cliente_informado', 'Novo cliente'));
        raise exception 'FALHOU: aceitou sem desenvolvedor';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  begin perform gravar_chamado(jsonb_build_object('titulo', ' ', 'desenvolvedor_id', v_dev, 'cliente_informado', 'X'));
        raise exception 'FALHOU: aceitou sem titulo';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  begin perform gravar_chamado(jsonb_build_object('titulo', 'x', 'desenvolvedor_id', v_dev));
        raise exception 'FALHOU: aceitou sem cliente';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  -- cliente digitado (fora da lista) é aceito
  perform gravar_chamado(jsonb_build_object('id', '22222222-2222-2222-2222-222222222222', 'titulo', 'Relatório novo',
          'desenvolvedor_id', v_dev, 'cliente_informado', 'Cliente Novo Ltda', 'prioridade', 'qualquer'));
  if not exists (select 1 from vw_chamados where id = '22222222-2222-2222-2222-222222222222'
                   and cliente_nome = 'Cliente Novo Ltda' and cliente_digitado and prioridade = 'media') then
    raise exception 'FALHOU: cliente digitado'; end if;
  raise notice 'ok validacoes';
end $$;

\echo '== F6 permissões: anônimo e logado não chamam as funções do formulário'
set role anon;
do $$ begin
  begin perform dados_formulario(); raise exception 'FALHOU: anon leu dados_formulario';
  exception when insufficient_privilege then null; end;
  begin perform gravar_chamado('{}'::jsonb); raise exception 'FALHOU: anon gravou chamado';
  exception when insufficient_privilege then null; end;
  begin perform chave_formulario(); raise exception 'FALHOU: anon leu a chave';
  exception when insufficient_privilege then null; end;
  raise notice 'ok anon bloqueado';
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';   -- consultor, não gestor
do $$ begin
  begin perform gravar_chamado('{}'::jsonb); raise exception 'FALHOU: logado gravou direto';
  exception when insufficient_privilege then null; end;
  begin perform chave_formulario(); raise exception 'FALHOU: consultor leu a chave';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  if exists (select 1 from vw_chamados) then raise exception 'FALHOU: consultor viu chamados'; end if;
  raise notice 'ok consultor bloqueado';
end $$;
reset role;

\echo '== F7 triagem: pedir informação → complemento → volta para novo'
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';   -- gestor
do $$
declare r jsonb; v_chave text;
begin
  v_chave := chave_formulario();
  if v_chave is null or chave_formulario(true) = v_chave then raise exception 'FALHOU: trocar chave'; end if;
  begin perform triar_chamado('11111111-1111-1111-1111-111111111111', 'pedir_informacao', ' ');
        raise exception 'FALHOU: pediu informacao sem texto';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  r := triar_chamado('11111111-1111-1111-1111-111111111111', 'pedir_informacao', 'Qual o número da nota?');
  if r->>'status' <> 'aguardando_informacao' or coalesce(r->>'token_complemento', '') = '' then
    raise exception 'FALHOU: pedir informacao %', r; end if;
  if (select chamados_novos from vw_pendencias_gestor) <> 1 then raise exception 'FALHOU: contador com aguardando'; end if;
  raise notice 'ok pedir informacao';
end $$;
reset role;
reset request.jwt.claim.sub;
do $$
declare v_token text := (select token_complemento from chamados where id = '11111111-1111-1111-1111-111111111111');
        d jsonb;
begin
  d := dados_complemento(v_token);
  if d->>'pergunta' <> 'Qual o número da nota?' or jsonb_array_length(d->'evidencias') <> 2 then
    raise exception 'FALHOU: dados do complemento %', d; end if;
  if dados_complemento('errado') is not null or dados_complemento(null) is not null then
    raise exception 'FALHOU: token errado'; end if;
  begin perform gravar_complemento(v_token, '[]'::jsonb, '  '); raise exception 'FALHOU: complemento vazio';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  perform gravar_complemento(v_token, jsonb_build_array(jsonb_build_object('texto', 'Print da nota',
          'anexos', jsonb_build_array(jsonb_build_object('caminho', 'x/c1.jpg', 'tipo', 'image/jpeg')))), 'Nota 123456');
  if (select string_agg(ordem || ':' || etapa || ':' || coalesce(texto, ''), '|' order by ordem) from chamados_evidencias
        where chamado_id = '11111111-1111-1111-1111-111111111111')
     <> '1:abertura:Abrir a nota|2:abertura:Clicar em imprimir|3:complemento:Resposta: Nota 123456|4:complemento:Print da nota' then
    raise exception 'FALHOU: passos do complemento'; end if;
  if not exists (select 1 from chamados where id = '11111111-1111-1111-1111-111111111111'
                   and status = 'novo' and token_complemento is null and complementado_em is not null) then
    raise exception 'FALHOU: chamado nao voltou para novo'; end if;
  if dados_complemento(v_token) is not null then raise exception 'FALHOU: link continuou valendo'; end if;
  raise notice 'ok complemento';
end $$;

\echo '== F8 aprovar, recusar e reabrir'
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
do $$
declare r jsonb; v_dev uuid := (select id from consultores where email = 'iago.proenca@sankhya.com.br');
begin
  r := triar_chamado('11111111-1111-1111-1111-111111111111', 'aprovar', null, v_dev, null);
  if r->>'status' <> 'aprovado' or (r->>'desenvolvedor_id')::uuid <> v_dev or r->>'consultor_id' is null then
    raise exception 'FALHOU: aprovar %', r; end if;
  begin perform triar_chamado('22222222-2222-2222-2222-222222222222', 'recusar', '');
        raise exception 'FALHOU: recusou sem motivo';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  r := triar_chamado('22222222-2222-2222-2222-222222222222', 'recusar', 'Fora do escopo');
  if r->>'status' <> 'recusado' then raise exception 'FALHOU: recusar'; end if;
  if (select triado_por_nome from vw_chamados where id = '22222222-2222-2222-2222-222222222222') <> 'Rodrigo Reis' then
    raise exception 'FALHOU: quem triou'; end if;
  if (select lista_sugerida from vw_chamados where id = '11111111-1111-1111-1111-111111111111') <> 'Semalo 28371 Avulso' then
    raise exception 'FALHOU: lista sugerida'; end if;
  raise notice 'ok aprovar e recusar';
end $$;
reset role;
reset request.jwt.claim.sub;

\echo '== F9 tarefa com CH-xxxxx no nome liga ao chamado'
do $$
declare v_cod text := (select codigo from chamados where id = '11111111-1111-1111-1111-111111111111');
        v_rec text := (select codigo from chamados where id = '22222222-2222-2222-2222-222222222222');
begin
  perform gravar_tarefas('clickup', jsonb_build_array(
    jsonb_build_object('id_externo', 'ch1', 'nome', lower(v_cod) || ' - Ajuste DANFE', 'status', 'não iniciado',
                       'lista_id_externo', 'LS', 'url', 'https://app.clickup.com/t/ch1'),
    jsonb_build_object('id_externo', 'ch2', 'nome', v_cod || ' - agenda repetida', 'status', 'não iniciado',
                       'lista_id_externo', 'LS', 'tarefa_pai_id_externo', 'ch1'),
    jsonb_build_object('id_externo', 'ch3', 'nome', v_rec || ' - recusado', 'status', 'não iniciado',
                       'lista_id_externo', 'LS')));
  if not exists (select 1 from vw_chamados where id = '11111111-1111-1111-1111-111111111111'
                   and status = 'tarefa_criada' and tarefa_criada_id_externo = 'ch1'
                   and tarefa_url = 'https://app.clickup.com/t/ch1') then
    raise exception 'FALHOU: ligacao %', (select to_jsonb(c) from vw_chamados c where id = '11111111-1111-1111-1111-111111111111'); end if;
  if (select status from chamados where id = '22222222-2222-2222-2222-222222222222') <> 'recusado' then
    raise exception 'FALHOU: recusado foi ligado'; end if;
  -- renomear a tarefa não troca a ligação; outra tarefa com o mesmo código também não
  update tarefas set nome = 'Ajuste DANFE (sem código)' where id_externo = 'ch1';
  if (select tarefa_criada_id_externo from chamados where id = '11111111-1111-1111-1111-111111111111') <> 'ch1' then
    raise exception 'FALHOU: ligacao trocou'; end if;
  raise notice 'ok ligacao CH';
end $$;

\echo '== F10 complemento depois da tarefa: bloqueado'
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
do $$ begin
  begin perform triar_chamado('11111111-1111-1111-1111-111111111111', 'pedir_informacao', 'mais?');
        raise exception 'FALHOU: pediu informacao de chamado com tarefa';
  exception when others then if sqlerrm like 'FALHOU%' then raise; end if; end;
  raise notice 'ok bloqueio depois da tarefa';
end $$;
reset role;
reset request.jwt.claim.sub;

\echo '== F11 bucket privado'
do $$ begin
  if not exists (select 1 from storage.buckets where id = 'evidencias' and not public) then
    raise exception 'FALHOU: bucket evidencias'; end if;
  raise notice 'ok bucket';
end $$;
