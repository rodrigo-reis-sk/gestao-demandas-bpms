-- =============================================================================
-- 0009 — Fase 3: formulário do consultor e triagem de chamados (D54–D60)
-- =============================================================================
-- 1. Chamados: consultor e gerente como pessoas do cadastro, status novos, pedido de
--    informação com link exclusivo (D59), ligação com a tarefa da origem.
-- 2. Evidências: marca se veio na abertura ou num complemento.
-- 3. Chave do link do formulário no Vault (D57) e limite de envios por IP (D60).
-- 4. Funções que a Edge Function "formulario" usa (só a chave de serviço chama).
-- 5. Funções da triagem (gestor logado).
-- 6. Gatilho: tarefa com "CH-00012" no nome liga ao chamado (D54).
-- 7. Bucket privado "evidencias" para os prints.
-- Nada aqui grava a partir do navegador anônimo: o formulário passa pela Edge Function.
-- =============================================================================

-- ---------------- 1. Chamados ----------------
alter table public.chamados add column if not exists consultor_id         uuid references public.consultores(id);
alter table public.chamados add column if not exists gerente_projetos_id  uuid references public.consultores(id);
alter table public.chamados add column if not exists tarefa_id            uuid references public.tarefas(id);
alter table public.chamados add column if not exists tarefa_ligada_em     timestamptz;
-- Pedido de informação (D59): pergunta do gestor e link exclusivo para o consultor complementar.
alter table public.chamados add column if not exists informacao_pedida     text;
alter table public.chamados add column if not exists informacao_pedida_em  timestamptz;
alter table public.chamados add column if not exists token_complemento     text unique;
alter table public.chamados add column if not exists complementado_em      timestamptz;

comment on column public.chamados.desenvolvedor_id is 'Quem constrói (obrigatório). D58';
comment on column public.chamados.consultor_id is 'Quem levanta as informações, valida com o cliente e entrega (opcional). D58';
comment on column public.chamados.token_complemento is 'Link complementar.html?c=<token>; só vale enquanto o chamado aguarda informação. D59';

-- Status da triagem (D54, D59):
--   novo → (aprovado →) tarefa_criada   |   novo → aguardando_informacao → novo   |   novo → recusado
-- "em_triagem" e "direcionado" ficam aceitos só por compatibilidade com a 0001 (não são mais usados).
alter table public.chamados drop constraint if exists chamados_status_check;
alter table public.chamados add constraint chamados_status_check check (status in (
  'novo', 'aguardando_informacao', 'aprovado', 'tarefa_criada', 'recusado', 'concluido',
  'em_triagem', 'direcionado'));

create index if not exists idx_chamados_tarefa on public.chamados (tarefa_id);

-- ---------------- 2. Evidências ----------------
alter table public.chamados_evidencias add column if not exists etapa text not null default 'abertura'
  check (etapa in ('abertura', 'complemento'));
alter table public.chamados_evidencias add column if not exists criado_em timestamptz not null default now();

-- ---------------- 3. Chave do formulário e limite por IP ----------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'chave_formulario') then
    perform vault.create_secret(replace(gen_random_uuid()::text, '-', ''),
                                'chave_formulario', 'Chave do link do formulário do consultor (D57)');
  end if;
end $$;

-- Cada envio (abertura ou complemento) deixa uma linha; serve só para o limite por IP (D60).
create table if not exists public.envios_por_ip (
  id         bigint generated always as identity primary key,
  ip         text not null,
  tipo       text not null,                    -- 'abertura' | 'complemento'
  criado_em  timestamptz not null default now()
);
create index if not exists idx_envios_ip on public.envios_por_ip (ip, criado_em);
alter table public.envios_por_ip enable row level security;
create policy gestor_le on public.envios_por_ip for select to authenticated using (public.eh_gestor());

insert into public.configuracoes (chave, valor, descricao) values
  ('formulario', '{"envios_por_hora_por_ip": 10, "max_arquivos": 30, "max_total_kb": 15360}',
   'Limites do formulário externo e do complemento (D60)')
on conflict (chave) do nothing;

-- Confere a chave do link. Chamada pela Edge Function.
create or replace function public.conferir_chave_formulario(p_chave text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select coalesce(p_chave, '') <> '' and p_chave = public.ler_segredo('chave_formulario')
$$;

-- Registra o envio e diz se o IP ainda está dentro do limite da última hora.
-- Quem passou do limite não grava linha nova (não "estica" o bloqueio).
create or replace function public.registrar_envio_ip(p_ip text, p_tipo text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  v_limite int := coalesce((select (valor->>'envios_por_hora_por_ip')::int from configuracoes where chave = 'formulario'), 10);
  v_qtd    int;
begin
  delete from envios_por_ip where criado_em < now() - interval '2 days';   -- limpeza
  select count(*) into v_qtd from envios_por_ip
   where ip = coalesce(p_ip, '?') and criado_em > now() - interval '1 hour';
  if v_qtd >= v_limite then return false; end if;
  insert into envios_por_ip (ip, tipo) values (coalesce(p_ip, '?'), p_tipo);
  return true;
end $$;

-- ---------------- 4. Funções do formulário (Edge Function) ----------------

-- Listas do formulário: clientes com lista marcada para sincronizar, consultores marcados (D58)
-- e gerentes de projetos.
create or replace function public.dados_formulario()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'gerente_id', c.gerente_projetos_id) order by c.nome)
        from clientes c
       where c.ativo and exists (select 1 from clientes_faps f
                                  where f.cliente_id = c.id and f.situacao_sincronizacao = 'sincronizar')), '[]'),
    'consultores', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome) order by p.nome)
        from consultores p where p.ativo and p.sincronizar), '[]'),
    'gerentes', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome) order by p.nome)
        from consultores p where p.ativo and p.papel = 'gerente_projetos'), '[]'))
$$;

-- Texto vazio → nulo; corta no tamanho máximo.
create or replace function public.texto_limpo(p text, p_max int default 4000)
returns text language sql immutable as $$
  select left(nullif(btrim(p), ''), p_max)
$$;

-- Grava o chamado do formulário com as evidências e os anexos (já enviados ao bucket).
-- p_dados = { id?, titulo, tipo, prioridade, descricao, cliente_id | cliente_informado, contato_nome,
--             contato_info, gerente_projetos_id, consultor_id, desenvolvedor_id, origem_solicitacao,
--             chamado_sankhya_aberto, ticket_sankhya, retorno_sankhya,
--             evidencias: [{ texto, anexos: [{ caminho, tipo, tamanho }] }] }
-- Devolve { id, codigo }.
create or replace function public.gravar_chamado(p_dados jsonb, p_ip text default null, p_canal text default 'formulario_consultor')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id        uuid := coalesce((p_dados->>'id')::uuid, gen_random_uuid());
  v_codigo    text;
  v_titulo    text := public.texto_limpo(p_dados->>'titulo', 140);
  v_cliente   uuid := (p_dados->>'cliente_id')::uuid;
  v_cli_txt   text := public.texto_limpo(p_dados->>'cliente_informado', 200);
  v_dev       uuid := (p_dados->>'desenvolvedor_id')::uuid;
  v_cons      uuid := (p_dados->>'consultor_id')::uuid;
  v_ger       uuid := (p_dados->>'gerente_projetos_id')::uuid;
  v_prior     text := lower(coalesce(public.texto_limpo(p_dados->>'prioridade', 20), 'media'));
  v_sankhya   boolean := coalesce((p_dados->>'chamado_sankhya_aberto')::boolean, false);
begin
  if v_titulo is null then raise exception 'Informe o título da demanda.'; end if;
  if v_dev is null or not exists (select 1 from consultores where id = v_dev and ativo) then
    raise exception 'Escolha o desenvolvedor na lista.'; end if;
  if v_cons is not null and not exists (select 1 from consultores where id = v_cons and ativo) then
    raise exception 'Consultor não encontrado.'; end if;
  if v_ger is not null and not exists (select 1 from consultores where id = v_ger and ativo) then
    raise exception 'Gerente não encontrado.'; end if;
  if v_cliente is not null and not exists (select 1 from clientes where id = v_cliente) then
    v_cliente := null; end if;
  if v_cliente is null and v_cli_txt is null then raise exception 'Informe o cliente.'; end if;
  if v_prior not in ('baixa', 'media', 'alta', 'urgente') then v_prior := 'media'; end if;
  -- gerente do cliente quando o formulário não informou (D28)
  if v_ger is null and v_cliente is not null then
    select gerente_projetos_id into v_ger from clientes where id = v_cliente;
  end if;

  insert into chamados (
    id, canal, cliente_id, cliente_informado, gerente_projetos, consultor_lider,
    gerente_projetos_id, consultor_id, desenvolvedor_id, desenvolvedor_indicado,
    contato_nome, contato_info, solicitante_nome,
    titulo, descricao, tipo, prioridade, origem_solicitacao,
    chamado_sankhya_aberto, ticket_sankhya, retorno_sankhya, ip_origem)
  values (
    v_id, p_canal, v_cliente, case when v_cliente is null then v_cli_txt end,
    (select nome from consultores where id = v_ger), (select nome from consultores where id = v_cons),
    v_ger, v_cons, v_dev, (select nome from consultores where id = v_dev),
    public.texto_limpo(p_dados->>'contato_nome', 200), public.texto_limpo(p_dados->>'contato_info', 200),
    (select nome from consultores where id = v_cons),
    v_titulo, public.texto_limpo(p_dados->>'descricao', 8000), public.texto_limpo(p_dados->>'tipo', 60), v_prior,
    public.texto_limpo(p_dados->>'origem_solicitacao', 200),
    v_sankhya,
    case when v_sankhya then public.texto_limpo(p_dados->>'ticket_sankhya', 60) end,
    case when v_sankhya then public.texto_limpo(p_dados->>'retorno_sankhya', 500) end,
    case when p_ip ~ '^[0-9a-fA-F:.]+$' then p_ip::inet end)
  returning codigo into v_codigo;

  perform public.gravar_evidencias(v_id, p_dados->'evidencias', 'abertura');
  return jsonb_build_object('id', v_id, 'codigo', v_codigo);
end $$;

-- Acrescenta passos (com anexos) ao fim das evidências do chamado. Passo vazio é ignorado.
create or replace function public.gravar_evidencias(p_chamado uuid, p_evidencias jsonb, p_etapa text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  e       jsonb;
  a       jsonb;
  v_ordem int := coalesce((select max(ordem) from chamados_evidencias where chamado_id = p_chamado), 0);
  v_ev    uuid;
  v_n     int;
  v_qtd   int := 0;
begin
  for e in select * from jsonb_array_elements(coalesce(p_evidencias, '[]'::jsonb)) loop
    if public.texto_limpo(e->>'texto') is null and jsonb_array_length(coalesce(e->'anexos', '[]')) = 0 then continue; end if;
    v_ordem := v_ordem + 1;
    insert into chamados_evidencias (chamado_id, ordem, texto, etapa)
    values (p_chamado, v_ordem, public.texto_limpo(e->>'texto', 8000), p_etapa) returning id into v_ev;
    v_n := 0;
    for a in select * from jsonb_array_elements(coalesce(e->'anexos', '[]'::jsonb)) loop
      v_n := v_n + 1;
      insert into chamados_anexos (evidencia_id, ordem, caminho_storage, tipo_arquivo, tamanho_bytes)
      values (v_ev, v_n, a->>'caminho', coalesce(a->>'tipo', 'application/octet-stream'), (a->>'tamanho')::int);
    end loop;
    v_qtd := v_qtd + 1;
  end loop;
  return v_qtd;
end $$;

-- O que a tela de complemento mostra (D59). Nulo se o link não vale (ou não vale mais).
create or replace function public.dados_complemento(p_token text)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', ch.id, 'codigo', ch.codigo, 'titulo', ch.titulo,
    'cliente', coalesce(c.nome, ch.cliente_informado),
    'pergunta', ch.informacao_pedida, 'pedida_em', ch.informacao_pedida_em,
    'evidencias', coalesce((select jsonb_agg(jsonb_build_object(
                     'ordem', e.ordem, 'texto', e.texto, 'etapa', e.etapa,
                     'anexos', (select count(*) from chamados_anexos a where a.evidencia_id = e.id)) order by e.ordem)
                   from chamados_evidencias e where e.chamado_id = ch.id), '[]'))
  from chamados ch left join clientes c on c.id = ch.cliente_id
  where coalesce(p_token, '') <> '' and ch.token_complemento = p_token and ch.status = 'aguardando_informacao'
$$;

-- Grava o complemento: novos passos, o link deixa de valer e o chamado volta para "novo" (D59).
create or replace function public.gravar_complemento(p_token text, p_evidencias jsonb, p_resposta text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ch chamados%rowtype;
  v_ev jsonb := coalesce(p_evidencias, '[]'::jsonb);
begin
  select * into v_ch from chamados
   where coalesce(p_token, '') <> '' and token_complemento = p_token and status = 'aguardando_informacao'
   for update;
  if v_ch.id is null then raise exception 'Este link de complemento não vale mais.'; end if;
  -- a resposta escrita vira o primeiro passo do complemento
  if public.texto_limpo(p_resposta) is not null then
    v_ev := jsonb_build_array(jsonb_build_object('texto', 'Resposta: ' || public.texto_limpo(p_resposta), 'anexos', '[]'::jsonb)) || v_ev;
  end if;
  if public.gravar_evidencias(v_ch.id, v_ev, 'complemento') = 0 then
    raise exception 'Escreva a resposta ou acrescente um passo.'; end if;
  update chamados set status = 'novo', token_complemento = null, complementado_em = now() where id = v_ch.id;
  return jsonb_build_object('id', v_ch.id, 'codigo', v_ch.codigo);
end $$;

-- ---------------- 5. Triagem (gestor logado) ----------------

-- Link do formulário para o gestor copiar. p_trocar = true gera uma chave nova (o link antigo para de valer).
create or replace function public.chave_formulario(p_trocar boolean default false)
returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.eh_gestor() then raise exception 'Só gestores.'; end if;
  if p_trocar then
    perform public.salvar_segredo('chave_formulario', replace(gen_random_uuid()::text, '-', ''),
                                  'Chave do link do formulário do consultor (D57)');
  end if;
  return public.ler_segredo('chave_formulario');
end $$;

-- Decisão da triagem. p_acao:
--   'aprovar'  → guarda desenvolvedor/consultor e fica "aprovado" até a tarefa com o código chegar da origem
--   'recusar'  → "recusado" com o motivo (p_texto)
--   'pedir_informacao' → "aguardando_informacao" com a pergunta (p_texto); devolve o token do link
--   'reabrir'  → volta para "novo"
--   'responsaveis' → só troca desenvolvedor/consultor
-- Devolve a linha atualizada (jsonb).
create or replace function public.triar_chamado(
  p_id uuid, p_acao text, p_texto text default null,
  p_desenvolvedor uuid default null, p_consultor uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ch chamados%rowtype;
begin
  if not public.eh_gestor() then raise exception 'Só gestores fazem a triagem.'; end if;
  select * into v_ch from chamados where id = p_id for update;
  if v_ch.id is null then raise exception 'Chamado não encontrado.'; end if;

  if p_acao in ('aprovar', 'responsaveis') then
    update chamados set
      desenvolvedor_id = coalesce(p_desenvolvedor, desenvolvedor_id),
      desenvolvedor_indicado = coalesce((select nome from consultores where id = p_desenvolvedor), desenvolvedor_indicado),
      consultor_id = case when p_acao = 'responsaveis' or p_consultor is not null then p_consultor else consultor_id end,
      status = case when p_acao = 'aprovar' and status in ('novo', 'aguardando_informacao', 'em_triagem') then 'aprovado' else status end,
      token_complemento = case when p_acao = 'aprovar' then null else token_complemento end,
      decisao_observacao = coalesce(public.texto_limpo(p_texto), decisao_observacao),
      triado_por = auth.uid(), triado_em = now()
    where id = p_id;
    if p_acao = 'aprovar' and (select desenvolvedor_id from chamados where id = p_id) is null then
      raise exception 'Escolha o desenvolvedor antes de aprovar.'; end if;
  elsif p_acao = 'recusar' then
    if public.texto_limpo(p_texto) is null then raise exception 'Escreva o motivo da recusa.'; end if;
    update chamados set status = 'recusado', decisao_observacao = public.texto_limpo(p_texto),
           token_complemento = null, triado_por = auth.uid(), triado_em = now()
     where id = p_id;
  elsif p_acao = 'pedir_informacao' then
    if public.texto_limpo(p_texto) is null then raise exception 'Escreva o que falta no chamado.'; end if;
    if v_ch.status in ('tarefa_criada', 'concluido') then raise exception 'O chamado já virou tarefa.'; end if;
    update chamados set status = 'aguardando_informacao', informacao_pedida = public.texto_limpo(p_texto),
           informacao_pedida_em = now(),
           token_complemento = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
           triado_por = auth.uid(), triado_em = now()
     where id = p_id;
  elsif p_acao = 'reabrir' then
    if v_ch.status in ('tarefa_criada', 'concluido') then raise exception 'O chamado já virou tarefa.'; end if;
    update chamados set status = 'novo', token_complemento = null, triado_por = auth.uid(), triado_em = now()
     where id = p_id;
  else
    raise exception 'Ação desconhecida: %', p_acao;
  end if;

  return (select to_jsonb(c) from chamados c where c.id = p_id);
end $$;

-- Tudo o que a tela de triagem lista, numa consulta (RLS: só gestor vê chamados).
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
       -- lista sugerida para criar a tarefa: a lista avulsa marcada do cliente (a mais recente)
       (select f.nome_lista from clientes_faps f
         where f.cliente_id = ch.cliente_id and f.situacao_sincronizacao = 'sincronizar'
         order by (f.tipo = 'avulso') desc, f.ativa desc, f.descoberta_em desc limit 1) as lista_sugerida,
       (select count(*) from chamados_evidencias e where e.chamado_id = ch.id) as passos,
       (select count(*) from chamados_evidencias e join chamados_anexos a on a.evidencia_id = e.id
         where e.chamado_id = ch.id) as anexos,
       ch.criado_em, ch.atualizado_em
from public.chamados ch
left join public.clientes c     on c.id = ch.cliente_id
left join public.consultores g  on g.id = ch.gerente_projetos_id
left join public.consultores co on co.id = ch.consultor_id
left join public.consultores d  on d.id = ch.desenvolvedor_id
left join public.usuarios_sistema u on u.id = ch.triado_por
left join public.tarefas t      on t.id = ch.tarefa_id;

-- ---------------- 6. Ligação tarefa ↔ chamado pelo código no nome (D54) ----------------
-- A tarefa criada à mão na origem com "CH-00012 - ..." no nome liga ao chamado CH-00012.
-- Vale a primeira tarefa que chegar com o código; chamado recusado não liga.
create or replace function public.ligar_tarefa_ao_chamado()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_codigo text;
begin
  if new.excluida_na_origem then return new; end if;
  v_codigo := upper(substring(new.nome from '(?i)\mCH-?\s?(\d{5,})\M'));
  if v_codigo is null then return new; end if;
  update chamados set
         tarefa_id = new.id, tarefa_criada_id_externo = new.id_externo, tarefa_ligada_em = now(),
         status = 'tarefa_criada', token_complemento = null
   where codigo = 'CH-' || v_codigo
     and tarefa_id is null
     and status not in ('recusado', 'concluido');
  return new;
end $$;

drop trigger if exists trg_tarefas_liga_chamado on public.tarefas;
create trigger trg_tarefas_liga_chamado after insert or update of nome, excluida_na_origem on public.tarefas
  for each row execute function public.ligar_tarefa_ao_chamado();

-- Tarefas que já estão no banco com o código (caso o chamado tenha sido criado antes da migração).
update public.tarefas set nome = nome where nome ~* '\mCH-?\s?\d{5,}\M' and not excluida_na_origem;

-- ---------------- 7. Bucket privado dos prints ----------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidencias', 'evidencias', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf'])
on conflict (id) do nothing;

-- Gestor logado lê os prints (a tela de triagem gera links temporários). Gravação só pela Edge Function.
drop policy if exists gestor_le_evidencias on storage.objects;
create policy gestor_le_evidencias on storage.objects for select to authenticated
  using (bucket_id = 'evidencias' and public.eh_gestor());

-- ---------------- Permissões ----------------
do $$
declare f text;
begin
  -- só a chave de serviço (Edge Function "formulario")
  foreach f in array array[
    'public.conferir_chave_formulario(text)', 'public.registrar_envio_ip(text, text)',
    'public.dados_formulario()', 'public.gravar_chamado(jsonb, text, text)',
    'public.gravar_evidencias(uuid, jsonb, text)', 'public.dados_complemento(text)',
    'public.gravar_complemento(text, jsonb, text)', 'public.ligar_tarefa_ao_chamado()']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- gestor logado (a função confere eh_gestor por dentro)
  foreach f in array array['public.chave_formulario(boolean)',
                           'public.triar_chamado(uuid, text, text, uuid, uuid)']
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
grant select on public.vw_chamados to authenticated;
