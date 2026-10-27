-- =============================================================================
-- 0010 — Fase 3: portal do cliente (D16, D56, D62–D64)
-- =============================================================================
-- Link exclusivo por cliente (links_portal, já existe desde a 0001): portal.html?t=<token>.
-- O cliente abre chamado (mesmo editor de passos do formulário) e acompanha TODOS os chamados
-- do cliente (D62) numa situação simplificada (D63). Quando a triagem pede informação num chamado
-- do portal, o cliente responde no próprio portal ou pelo link separado (D64).
-- Como na 0009, o navegador anônimo não grava nada: passa pela Edge Function "formulario".
-- =============================================================================

alter table public.links_portal add column if not exists ultimo_acesso_em timestamptz;
alter table public.links_portal add column if not exists criado_por uuid references auth.users(id);

-- Link vale: ativo, dentro da validade e de cliente ativo. Devolve a linha do link ou nada.
create or replace function public.link_portal_valido(p_token text)
returns public.links_portal language sql stable security definer set search_path = public, extensions as $$
  select l.* from links_portal l join clientes c on c.id = l.cliente_id
   where coalesce(p_token, '') <> '' and l.token = p_token and l.ativo and c.ativo
     and (l.expira_em is null or l.expira_em > now())
$$;

-- Situação que o cliente vê (D63). Termos de negócio, sem o status interno.
--   recebido · informacao · atendimento · concluido · nao_aprovado
create or replace function public.situacao_para_cliente(p_status text, p_canal text, p_tarefa_status text, p_tarefa_status_tipo text)
returns text language sql immutable as $$
  select case
    when p_status = 'recusado' then 'nao_aprovado'
    when p_status = 'concluido' then 'concluido'
    when p_status = 'tarefa_criada' then
      case when public.normalizar_texto(coalesce(p_tarefa_status, '')) like 'conclu%'
                or p_tarefa_status_tipo in ('closed', 'done') then 'concluido' else 'atendimento' end
    -- o pedido de informação só aparece para o cliente nos chamados que ele mesmo abriu (D64);
    -- nos abertos pelo consultor a pergunta é para o consultor
    when p_status = 'aguardando_informacao' and p_canal = 'portal_cliente' then 'informacao'
    else 'recebido'
  end
$$;

-- Tudo o que o portal mostra. Nulo se o link não vale. Registra o último acesso.
create or replace function public.dados_portal(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_link links_portal;
begin
  v_link := public.link_portal_valido(p_token);
  if v_link.id is null then return null; end if;
  update links_portal set ultimo_acesso_em = now() where id = v_link.id;
  return jsonb_build_object(
    'cliente', (select nome from clientes where id = v_link.cliente_id),
    'chamados', coalesce((
      select jsonb_agg(x order by x->>'criado_em' desc) from (
        select jsonb_build_object(
          'codigo', ch.codigo, 'titulo', ch.titulo, 'canal', ch.canal,
          'situacao', s.situacao,
          'prioridade', ch.prioridade,
          'solicitante', coalesce(ch.solicitante_nome, ch.consultor_lider),
          'criado_em', ch.criado_em, 'atualizado_em', greatest(ch.atualizado_em, t.atualizada_na_origem),
          'motivo', case when s.situacao = 'nao_aprovado' then ch.decisao_observacao end,
          'pergunta', case when s.situacao = 'informacao' then ch.informacao_pedida end,
          'token_complemento', case when s.situacao = 'informacao' then ch.token_complemento end,
          'passos', (select count(*) from chamados_evidencias e where e.chamado_id = ch.id),
          'prints', (select count(*) from chamados_evidencias e join chamados_anexos a on a.evidencia_id = e.id
                      where e.chamado_id = ch.id)) as x
          from chamados ch
          left join tarefas t on t.id = ch.tarefa_id
          cross join lateral (select public.situacao_para_cliente(ch.status, ch.canal, t.status, t.status_tipo) as situacao) s
         where ch.cliente_id = v_link.cliente_id
      ) q), '[]'));
end $$;

-- Chamado aberto pelo cliente no portal. Cliente e link vêm do token; desenvolvedor fica para a triagem.
-- p_dados = { id?, titulo, descricao, prioridade, solicitante_nome, solicitante_email, evidencias: [...] }
create or replace function public.gravar_chamado_portal(p_token text, p_dados jsonb, p_ip text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_link   links_portal;
  v_id     uuid := coalesce((p_dados->>'id')::uuid, gen_random_uuid());
  v_codigo text;
  v_titulo text := public.texto_limpo(p_dados->>'titulo', 140);
  v_nome   text := public.texto_limpo(p_dados->>'solicitante_nome', 200);
  v_contato text := public.texto_limpo(p_dados->>'solicitante_email', 200);
  v_prior  text := lower(coalesce(public.texto_limpo(p_dados->>'prioridade', 20), 'media'));
begin
  v_link := public.link_portal_valido(p_token);
  if v_link.id is null then raise exception 'Este link do portal não vale mais.'; end if;
  if v_titulo is null then raise exception 'Informe o título do chamado.'; end if;
  if v_nome is null then raise exception 'Informe o seu nome.'; end if;
  if v_contato is null then raise exception 'Informe o seu e-mail ou telefone.'; end if;
  if v_prior not in ('baixa', 'media', 'alta', 'urgente') then v_prior := 'media'; end if;

  insert into chamados (id, canal, cliente_id, link_portal_id, solicitante_nome, solicitante_email,
                        contato_nome, contato_info, gerente_projetos_id, gerente_projetos,
                        titulo, descricao, prioridade, origem_solicitacao, ip_origem)
  select v_id, 'portal_cliente', v_link.cliente_id, v_link.id, v_nome, v_contato,
         v_nome, v_contato, c.gerente_projetos_id, g.nome,
         v_titulo, public.texto_limpo(p_dados->>'descricao', 8000), v_prior, 'Portal do cliente',
         case when p_ip ~ '^[0-9a-fA-F:.]+$' then p_ip::inet end
    from clientes c left join consultores g on g.id = c.gerente_projetos_id
   where c.id = v_link.cliente_id
  returning codigo into v_codigo;

  perform public.gravar_evidencias(v_id, p_dados->'evidencias', 'abertura');
  return jsonb_build_object('id', v_id, 'codigo', v_codigo);
end $$;

-- Na triagem: de onde veio o chamado e se o cliente vê o motivo / a pergunta (D63, D64).
create or replace view public.vw_chamados
with (security_invoker = true) as
select ch.id, ch.codigo, ch.canal, ch.status, ch.titulo, ch.descricao, ch.tipo, ch.prioridade,
       ch.origem_solicitacao, ch.chamado_sankhya_aberto, ch.ticket_sankhya, ch.retorno_sankhya,
       ch.cliente_id, coalesce(c.nome, ch.cliente_informado) as cliente_nome, (ch.cliente_id is null) as cliente_digitado,
       ch.contato_nome, ch.contato_info,
       ch.gerente_projetos_id, g.nome as gerente_nome,
       ch.consultor_id, co.nome as consultor_nome,
       ch.desenvolvedor_id, coalesce(d.nome, ch.desenvolvedor_indicado) as desenvolvedor_nome,
       ch.decisao_observacao, ch.informacao_pedida, ch.informacao_pedida_em, ch.token_complemento,
       ch.complementado_em, ch.triado_em, u.nome as triado_por_nome,
       ch.tarefa_id, ch.tarefa_criada_id_externo, t.nome as tarefa_nome, t.url as tarefa_url, t.status as tarefa_status,
       ch.tarefa_ligada_em,
       (select f.nome_lista from clientes_faps f
         where f.cliente_id = ch.cliente_id and f.situacao_sincronizacao = 'sincronizar'
         order by (f.tipo = 'avulso') desc, f.ativa desc, f.descoberta_em desc limit 1) as lista_sugerida,
       (select count(*) from chamados_evidencias e where e.chamado_id = ch.id) as passos,
       (select count(*) from chamados_evidencias e join chamados_anexos a on a.evidencia_id = e.id
         where e.chamado_id = ch.id) as anexos,
       ch.criado_em, ch.atualizado_em,
       -- novas na 0010 (no fim, para o "create or replace" aceitar)
       ch.solicitante_nome, ch.solicitante_email, ch.link_portal_id,
       public.situacao_para_cliente(ch.status, ch.canal, t.status, t.status_tipo) as situacao_cliente,
       exists (select 1 from links_portal l where l.cliente_id = ch.cliente_id and l.ativo
                 and (l.expira_em is null or l.expira_em > now())) as cliente_tem_portal
from public.chamados ch
left join public.clientes c     on c.id = ch.cliente_id
left join public.consultores g  on g.id = ch.gerente_projetos_id
left join public.consultores co on co.id = ch.consultor_id
left join public.consultores d  on d.id = ch.desenvolvedor_id
left join public.usuarios_sistema u on u.id = ch.triado_por
left join public.tarefas t      on t.id = ch.tarefa_id;

-- Links do portal para a triagem (gestor): cliente, situação e último acesso.
create or replace view public.vw_links_portal
with (security_invoker = true) as
select l.id, l.cliente_id, c.nome as cliente_nome, l.token, l.descricao, l.ativo, l.expira_em,
       (l.ativo and (l.expira_em is null or l.expira_em > now()) and c.ativo) as valendo,
       l.ultimo_acesso_em, l.criado_em,
       (select count(*) from chamados ch where ch.link_portal_id = l.id) as chamados_abertos
from public.links_portal l
join public.clientes c on c.id = l.cliente_id;

-- quem criou o link (gravado sozinho)
create or replace function public.marcar_criador_link()
returns trigger language plpgsql as $$
begin
  new.criado_por := coalesce(new.criado_por, auth.uid());
  return new;
end $$;
drop trigger if exists trg_links_portal_criador on public.links_portal;
create trigger trg_links_portal_criador before insert on public.links_portal
  for each row execute function public.marcar_criador_link();

-- ---------------- Permissões ----------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.link_portal_valido(text)', 'public.dados_portal(text)',
    'public.gravar_chamado_portal(text, jsonb, text)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on public.vw_chamados, public.vw_links_portal to authenticated;
