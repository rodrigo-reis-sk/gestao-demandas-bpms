-- =============================================================================
-- 0013 — Acessos pela tela Consultores, sem SQL (D75, 28/10/2026)
-- =============================================================================
-- "Dar acesso", "Nova senha" e "Tirar acesso" na tela Consultores. Quem cria o login no Supabase Auth é a
-- Edge Function "acessos" (chave de serviço); estas funções guardam as REGRAS:
--   • qualquer gestor dá acesso de CONSULTOR; acesso de GESTOR só o admin;
--   • só o admin mexe no acesso de um gestor; o acesso do admin não muda por aqui;
--   • ninguém tira o próprio acesso;
--   • senha temporária → trocar_senha = true; a tela pede a senha nova no primeiro login.
-- O e-mail do login é o do cadastro de Consultores (o mesmo do ClickUp, D11).
-- =============================================================================

alter table public.usuarios_sistema add column if not exists trocar_senha boolean not null default false;
alter table public.usuarios_sistema add column if not exists acesso_por   uuid references auth.users(id);
alter table public.usuarios_sistema add column if not exists acesso_em    timestamptz;
comment on column public.usuarios_sistema.trocar_senha is 'Senha temporária: a tela pede a senha nova no próximo login (D75).';

-- Usuário do sistema ligado ao consultor (pelo cadastro ou, nos acessos antigos, pelo e-mail).
create or replace function public.usuario_do_consultor(p_consultor uuid)
returns public.usuarios_sistema language sql stable security definer set search_path = public, extensions as $$
  select u.* from usuarios_sistema u join consultores c on c.id = p_consultor
   where u.consultor_id = c.id or (u.consultor_id is null and lower(u.email) = lower(c.email))
   order by (u.consultor_id = c.id) desc nulls last limit 1
$$;

-- Tela Consultores: situação do acesso de cada pessoa (gestor logado).
create or replace function public.situacao_acessos()
returns table (consultor_id uuid, usuario_id uuid, papel text, ativo boolean, trocar_senha boolean, ultimo_login timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not public.eh_gestor() then raise exception 'Só gestores.'; end if;
  return query
    select c.id, u.id, u.papel, u.ativo, u.trocar_senha, au.last_sign_in_at
      from consultores c
      cross join lateral (select * from public.usuario_do_consultor(c.id)) u
      left join auth.users au on au.id = u.id
     where u.id is not null;
end $$;

-- Confere as regras antes de criar/alterar o login. p_papel nulo = mantém o papel atual (Nova senha).
-- Devolve { nome, email, papel, usuario_id (login que já existe no Auth, ou nulo) }.
create or replace function public.preparar_acesso(p_consultor uuid, p_papel text, p_por uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_por   usuarios_sistema%rowtype;
  v_cons  consultores%rowtype;
  v_atual usuarios_sistema%rowtype;
  v_papel text;
begin
  select * into v_por from usuarios_sistema where id = p_por and ativo and papel in ('admin', 'gestor');
  if v_por.id is null then raise exception 'Só gestores dão acesso.'; end if;
  select * into v_cons from consultores where id = p_consultor;
  if v_cons.id is null then raise exception 'Pessoa não encontrada no cadastro.'; end if;
  if not v_cons.ativo then raise exception '% está inativo no cadastro.', v_cons.nome; end if;
  if coalesce(btrim(v_cons.email), '') = '' then
    raise exception '% não tem e-mail no cadastro (o login usa o e-mail do ClickUp).', v_cons.nome; end if;

  v_atual := public.usuario_do_consultor(p_consultor);
  -- a própria pessoa: pode gerar senha nova, mas não muda o próprio tipo de acesso
  if v_atual.id = p_por then
    if p_papel is not null and p_papel <> v_atual.papel then raise exception 'Você não muda o próprio tipo de acesso.'; end if;
    return jsonb_build_object('nome', v_cons.nome, 'email', lower(btrim(v_cons.email)), 'papel', v_atual.papel, 'usuario_id', v_atual.id);
  end if;
  if v_atual.papel = 'admin' then
    raise exception 'O acesso do admin não é alterado por aqui.'; end if;
  if v_atual.papel = 'gestor' and v_por.papel <> 'admin' then
    raise exception 'Só o admin altera o acesso de um gestor.'; end if;

  v_papel := coalesce(p_papel, v_atual.papel);
  if v_papel is null then raise exception '% ainda não tem acesso.', v_cons.nome; end if;
  if v_papel not in ('consultor', 'gestor', 'admin') then raise exception 'Tipo de acesso inválido: %', v_papel; end if;
  if v_papel = 'gestor' and v_por.papel <> 'admin' then raise exception 'Só o admin dá acesso de gestor.'; end if;

  return jsonb_build_object(
    'nome', v_cons.nome, 'email', lower(btrim(v_cons.email)), 'papel', v_papel,
    'usuario_id', coalesce(v_atual.id, (select id from auth.users where lower(email) = lower(btrim(v_cons.email)) limit 1)));
end $$;

-- Grava o acesso depois que a Edge Function criou (ou trocou a senha do) login no Auth.
create or replace function public.gravar_acesso(p_usuario uuid, p_consultor uuid, p_papel text, p_por uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cons consultores%rowtype;
begin
  select * into v_cons from consultores where id = p_consultor;
  insert into usuarios_sistema (id, nome, email, papel, consultor_id, ativo, trocar_senha, acesso_por, acesso_em)
  values (p_usuario, v_cons.nome, lower(btrim(v_cons.email)), p_papel, v_cons.id, true, true, p_por, now())
  on conflict (id) do update set
    papel = excluded.papel, consultor_id = excluded.consultor_id, ativo = true, trocar_senha = true,
    acesso_por = excluded.acesso_por, acesso_em = excluded.acesso_em;
end $$;

-- Tirar acesso: desativa (não apaga). O banco para de mostrar dados na hora (RLS confere "ativo").
create or replace function public.tirar_acesso(p_consultor uuid, p_por uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_dados jsonb := public.preparar_acesso(p_consultor, null, p_por);   -- mesmas regras de quem pode
  v_id    uuid := (v_dados->>'usuario_id')::uuid;
begin
  if v_id = p_por then raise exception 'Você não pode tirar o próprio acesso.'; end if;
  update usuarios_sistema set ativo = false, acesso_por = p_por, acesso_em = now() where id = v_id;
  return v_dados;
end $$;

-- A pessoa logada trocou a senha temporária.
create or replace function public.senha_trocada()
returns void language sql security definer set search_path = public, extensions as $$
  update usuarios_sistema set trocar_senha = false where id = auth.uid()
$$;

-- ---------------- Permissões ----------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.usuario_do_consultor(uuid)', 'public.preparar_acesso(uuid, text, uuid)',
    'public.gravar_acesso(uuid, uuid, text, uuid)', 'public.tirar_acesso(uuid, uuid)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['public.situacao_acessos()', 'public.senha_trocada()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
