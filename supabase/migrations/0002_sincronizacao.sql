-- =============================================================================
-- Gestão de Demandas BP-MS — fase 1: suporte à sincronização
-- Executar depois de 0001_estrutura_inicial.sql (o "supabase db push" já faz na ordem).
--
-- O que esta migração traz:
--   1. Pequenos ajustes de estrutura (quando o consultor passou a sincronizar).
--   2. Cofre de segredos (Supabase Vault): tokens das contas, segredo do webhook,
--      chave do agendamento. Nada disso fica em tabela comum.
--   3. Funções de gravação usadas pelas Edge Functions de integração. Recebem dados já
--      "traduzidos" (genéricos, sem formato da ferramenta externa) e gravam no banco.
--   4. Funções que o gestor chama pela tela (conta da sincronização, desconectar).
--   5. Agendamento com pg_cron + pg_net.
--
-- Regra D10: nenhum nome aqui cita a ferramenta externa. Ela aparece só como valor
-- (p_origem / p_sistema = 'clickup').
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Extensões do agendamento (existem no Supabase; no teste local podem faltar)
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1. Ajustes de estrutura
-- -----------------------------------------------------------------------------

-- Quando o gestor marca "sincronizar" num consultor, guardamos o momento. A próxima
-- varredura percebe e busca o histórico dele (carga de 90 dias), e não só as alterações.
alter table public.consultores add column if not exists sincronizar_desde timestamptz;

create or replace function public.registrar_inicio_sincronizacao_consultor()
returns trigger language plpgsql as $$
begin
  if new.sincronizar and (tg_op = 'INSERT' or not coalesce(old.sincronizar, false)) then
    new.sincronizar_desde := now();
  end if;
  return new;
end $$;
drop trigger if exists trg_consultores_sincronizar on public.consultores;
create trigger trg_consultores_sincronizar before insert or update of sincronizar on public.consultores
  for each row execute function public.registrar_inicio_sincronizacao_consultor();

-- Parâmetros novos da sincronização. Se a chave já existe, os valores atuais ganham.
insert into public.configuracoes (chave, valor, descricao) values
  ('sincronizacao',
   '{"intervalo_minutos": 20, "carga_inicial_dias": 90, "janela_tempo_dias": 14,
     "espaco_id": "90133723590", "funcao": "clickup-sync", "url_funcoes": null}',
   'Varredura periódica da ferramenta externa')
on conflict (chave) do update set valor = excluded.valor || public.configuracoes.valor;

-- Duração do campo Período: '08h-10h' → 120 minutos. Outros textos (Feriado, Vários...) → nulo.
create or replace function public.minutos_do_periodo(p_periodo text)
returns int language sql immutable parallel safe as $$
  select case
    when p_periodo ~ '^\s*\d{1,2}h\s*-\s*\d{1,2}h\s*$' then
      nullif(greatest(0,
        ((regexp_match(p_periodo, '-\s*(\d{1,2})h'))[1]::int
         - (regexp_match(p_periodo, '^\s*(\d{1,2})h'))[1]::int) * 60), 0)
  end
$$;

-- Acha o cliente pelo nome (pasta ou parceiro), tolerando diferenças de grafia
-- ("PRO-INFO" × "Pro-Info"). Igualdade normalizada primeiro; senão, o mais parecido.
create or replace function public.cliente_por_nome(p_texto text)
returns uuid language sql stable security definer set search_path = public, extensions as $$
  select id from (
    select c.id, 1.0::real as nota from public.clientes c
     where public.normalizar_texto(c.nome) = public.normalizar_texto(p_texto)
    union all
    select c.id, similarity(public.normalizar_texto(c.nome), public.normalizar_texto(p_texto))
      from public.clientes c
     where similarity(public.normalizar_texto(c.nome), public.normalizar_texto(p_texto)) >= 0.5
  ) x
  where coalesce(trim(p_texto), '') <> ''
  order by nota desc
  limit 1
$$;

-- -----------------------------------------------------------------------------
-- 2. Cofre de segredos (Supabase Vault)
-- Só a chave de serviço (Edge Functions) chama estas funções. Ver o "revoke" no fim.
-- -----------------------------------------------------------------------------

-- Grava ou troca um segredo pelo nome. Devolve o id no Vault.
create or replace function public.salvar_segredo(p_nome text, p_valor text, p_descricao text default '')
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    v_id := vault.create_secret(p_valor, p_nome, p_descricao);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
  return v_id;
end $$;

create or replace function public.ler_segredo(p_nome text)
returns text language sql stable security definer set search_path = public, extensions as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_nome limit 1
$$;

-- Chave que o agendamento (pg_cron) manda para a Edge Function. Gerada aqui, sem passo manual.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'chave_agendamento') then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
                                'chave_agendamento', 'Autoriza o pg_cron a chamar a sincronização');
  end if;
end $$;

create or replace function public.conferir_chave_agendamento(p_chave text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select coalesce(p_chave, '') <> '' and p_chave = public.ler_segredo('chave_agendamento')
$$;

-- -----------------------------------------------------------------------------
-- 3. Contas de integração (D11): token de cada gestor no Vault
-- -----------------------------------------------------------------------------

-- Chamada pela Edge Function de conexão depois de conferir o e-mail.
-- A primeira conta conectada vira a "conta da sincronização" se ainda não houver uma.
create or replace function public.salvar_conta_integracao(
  p_usuario_id uuid, p_sistema text, p_email_externo text, p_usuario_id_externo text,
  p_nome_externo text, p_tipo_autenticacao text, p_token text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_segredo uuid;
  v_id      uuid;
begin
  if coalesce(p_token, '') = '' then
    raise exception 'Token vazio.';
  end if;
  v_segredo := public.salvar_segredo('conta_' || p_sistema || '_' || p_usuario_id::text, p_token,
                                     'Token da conta ' || p_sistema || ' de ' || p_email_externo);
  insert into contas_integracao (usuario_id, sistema, email_externo, usuario_id_externo, nome_externo,
                                 tipo_autenticacao, segredo_id, situacao, ultimo_erro, conectada_em)
  values (p_usuario_id, p_sistema, p_email_externo, p_usuario_id_externo, p_nome_externo,
          p_tipo_autenticacao, v_segredo, 'ativa', null, now())
  on conflict (usuario_id, sistema) do update
     set email_externo = excluded.email_externo, usuario_id_externo = excluded.usuario_id_externo,
         nome_externo = excluded.nome_externo, tipo_autenticacao = excluded.tipo_autenticacao,
         segredo_id = excluded.segredo_id, situacao = 'ativa', ultimo_erro = null, conectada_em = now()
  returning id into v_id;

  if not exists (select 1 from contas_integracao
                  where sistema = p_sistema and usar_na_sincronizacao and situacao = 'ativa') then
    update contas_integracao set usar_na_sincronizacao = true where id = v_id;
  end if;
  return v_id;
end $$;

-- Token da conta da sincronização (varredura e webhook). Sem conta ativa → nada (plano B: token único).
create or replace function public.ler_token_sincronizacao(p_sistema text)
returns table (conta_id uuid, token text, tipo_autenticacao text)
language sql stable security definer set search_path = public, extensions as $$
  select c.id, s.decrypted_secret, c.tipo_autenticacao
    from contas_integracao c join vault.decrypted_secrets s on s.id = c.segredo_id
   where c.sistema = p_sistema and c.usar_na_sincronizacao and c.situacao = 'ativa'
   limit 1
$$;

-- Token do gestor que clicou (fase 4: criar tarefa com a autoria certa).
create or replace function public.ler_token_usuario(p_usuario_id uuid, p_sistema text)
returns table (conta_id uuid, token text, tipo_autenticacao text)
language sql stable security definer set search_path = public, extensions as $$
  select c.id, s.decrypted_secret, c.tipo_autenticacao
    from contas_integracao c join vault.decrypted_secrets s on s.id = c.segredo_id
   where c.usuario_id = p_usuario_id and c.sistema = p_sistema and c.situacao = 'ativa'
   limit 1
$$;

-- Marca uso da conta; com erro (ex.: token recusado), a conta fica em "erro" e para de ser usada.
create or replace function public.registrar_uso_conta(p_conta_id uuid, p_erro text default null)
returns void language sql security definer set search_path = public, extensions as $$
  update contas_integracao
     set ultimo_uso_em = now(),
         situacao = case when p_erro is null then situacao else 'erro' end,
         ultimo_erro = p_erro
   where id = p_conta_id
$$;

-- Tela: o gestor escolhe qual conta conectada faz a varredura.
create or replace function public.definir_conta_sincronizacao(p_conta_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_sistema text;
begin
  if not public.eh_gestor() then
    raise exception 'Somente gestores podem escolher a conta da sincronização.';
  end if;
  select sistema into v_sistema from contas_integracao where id = p_conta_id and situacao = 'ativa';
  if v_sistema is null then
    raise exception 'A conta escolhida não está ativa.';
  end if;
  update contas_integracao set usar_na_sincronizacao = false
   where sistema = v_sistema and id <> p_conta_id and usar_na_sincronizacao;
  update contas_integracao set usar_na_sincronizacao = true where id = p_conta_id;
end $$;

-- Tela: o gestor desconecta a própria conta (admin pode desconectar qualquer uma).
-- O token é apagado do Vault.
create or replace function public.desconectar_conta(p_conta_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_conta contas_integracao%rowtype;
begin
  select * into v_conta from contas_integracao where id = p_conta_id;
  if v_conta.id is null then
    raise exception 'Conta não encontrada.';
  end if;
  if v_conta.usuario_id <> auth.uid()
     and not exists (select 1 from usuarios_sistema where id = auth.uid() and ativo and papel = 'admin') then
    raise exception 'Você só pode desconectar a sua própria conta.';
  end if;
  update contas_integracao
     set situacao = 'revogada', usar_na_sincronizacao = false, segredo_id = null
   where id = p_conta_id;
  if v_conta.segredo_id is not null then
    delete from vault.secrets where id = v_conta.segredo_id;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Funções de gravação (chamadas pelas Edge Functions de integração)
-- -----------------------------------------------------------------------------

-- O que buscar na origem: ids dos consultores marcados (e das contas compartilhadas
-- ligadas a eles pelo de-para, D17) e ids das listas marcadas (D14).
create or replace function public.filtros_sincronizacao()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'usuarios', coalesce((
      select jsonb_agg(distinct x.id) from (
        select c.id_externo as id from consultores c
         where c.sincronizar and c.ativo and c.id_externo is not null
        union
        select d.usuario_id_externo from responsavel_real_por_fap d
          join consultores c on c.id = d.consultor_id
         where c.sincronizar and c.ativo and d.usuario_id_externo is not null
      ) x), '[]'::jsonb),
    'listas', coalesce((
      select jsonb_agg(lista_id_externo order by lista_id_externo) from clientes_faps
       where situacao_sincronizacao = 'sincronizar' and lista_id_externo is not null), '[]'::jsonb)
  )
$$;

-- A partir de quando buscar tarefas alteradas.
--   • nunca sincronizou, ou o gestor marcou lista/consultor novo desde a última vez
--     → carga completa (carga_inicial_dias para trás);
--   • senão → desde o início da última varredura com sucesso, com 10 min de folga.
create or replace function public.inicio_busca_tarefas(p_sistema text)
returns table (desde timestamptz, carga_completa boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_ultima timestamptz;
  v_dias   int := coalesce((select (valor->>'carga_inicial_dias')::int from configuracoes where chave = 'sincronizacao'), 90);
begin
  select max(iniciado_em) into v_ultima from sincronizacoes
   where sistema = p_sistema and sucesso and tipo in ('periodica', 'carga_inicial', 'manual');
  if v_ultima is null
     or exists (select 1 from clientes_faps
                 where situacao_sincronizacao = 'sincronizar' and analisada_em > v_ultima)
     or exists (select 1 from consultores
                 where sincronizar and ativo and sincronizar_desde > v_ultima) then
    return query select now() - make_interval(days => v_dias), true;
  else
    return query select v_ultima - interval '10 minutes', false;
  end if;
end $$;

-- Membros da origem → consultores (liga pelo e-mail).
-- p_membros: [{usuario_id_externo, nome, email}]
-- • e-mail já cadastrado: grava o id e o nome na origem;
-- • conta compartilhada do de-para (ex.: "BPMS"): só aprende o id, NÃO vira consultor (D17);
-- • e-mail novo: entra como consultor com sincronizar = false (o gestor decide).
create or replace function public.gravar_membros(p_membros jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  m          jsonb;
  v_id       text;
  v_email    text;
  v_vinc     int := 0;
  v_novos    int := 0;
  v_compart  int := 0;
begin
  for m in select * from jsonb_array_elements(coalesce(p_membros, '[]'::jsonb)) loop
    v_id    := m->>'usuario_id_externo';
    v_email := lower(nullif(trim(m->>'email'), ''));
    if v_id is null then continue; end if;

    if exists (select 1 from responsavel_real_por_fap
                where public.normalizar_texto(nome_externo) = public.normalizar_texto(m->>'nome')) then
      update responsavel_real_por_fap set usuario_id_externo = v_id
       where public.normalizar_texto(nome_externo) = public.normalizar_texto(m->>'nome')
         and usuario_id_externo is distinct from v_id;
      v_compart := v_compart + 1;
      continue;
    end if;
    if v_email is null then continue; end if;

    if exists (select 1 from consultores where lower(email) = v_email) then
      -- se outro cadastro tinha este id (troca de e-mail), libera antes
      update consultores set id_externo = null where id_externo = v_id and lower(email) <> v_email;
      update consultores set id_externo = v_id, nome_externo = m->>'nome'
       where lower(email) = v_email
         and (id_externo is distinct from v_id or nome_externo is distinct from m->>'nome');
      v_vinc := v_vinc + 1;
    else
      update consultores set id_externo = null where id_externo = v_id;
      insert into consultores (nome, nome_externo, email, id_externo, sincronizar, observacao)
      values (coalesce(m->>'nome', v_email), m->>'nome', v_email, v_id, false, 'Criado pela sincronização de membros');
      v_novos := v_novos + 1;
    end if;
  end loop;
  return jsonb_build_object('vinculados', v_vinc, 'novos', v_novos, 'contas_compartilhadas', v_compart);
end $$;

-- Pastas/listas da origem → clientes_faps (D14).
-- p_listas: [{lista_id_externo, nome_lista, pasta_id_externo, pasta_nome, fap, tipo, ativa,
--             administrativa, nome_cliente}]
-- • lista conhecida: atualiza nomes, pasta e se está ativa (a decisão do gestor não muda);
-- • FAP do seed ainda sem lista: liga pela igualdade EXATA do número (lição do legado);
-- • lista nova: entra "a_analisar". Exceção: lista já encerrada (Z / Concluída) entra
--   como "nao_sincronizar", para não lotar a fila do gestor com o histórico (D18).
create or replace function public.gravar_listas(p_listas jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  l          jsonb;
  v_f        clientes_faps%rowtype;
  v_cliente  uuid;
  v_ativa    boolean;
  v_tipo     text;
  v_novas    int := 0;
  v_ligadas  int := 0;
  v_atual    int := 0;
begin
  for l in select * from jsonb_array_elements(coalesce(p_listas, '[]'::jsonb)) loop
    v_ativa := coalesce((l->>'ativa')::boolean, true);
    v_tipo  := coalesce(l->>'tipo', 'outro');
    v_cliente := null;
    if not coalesce((l->>'administrativa')::boolean, false) then
      v_cliente := coalesce(public.cliente_por_nome(l->>'pasta_nome'), public.cliente_por_nome(l->>'nome_cliente'));
    end if;

    select * into v_f from clientes_faps where lista_id_externo = l->>'lista_id_externo';
    if v_f.id is null and l->>'fap' is not null then
      select * into v_f from clientes_faps
       where lista_id_externo is null and fap = l->>'fap' and tipo = v_tipo
       order by (cliente_id = v_cliente) desc nulls last
       limit 1;
      if v_f.id is not null then v_ligadas := v_ligadas + 1; end if;
    elsif v_f.id is not null then
      v_atual := v_atual + 1;
    end if;

    if v_f.id is not null then
      update clientes_faps
         set lista_id_externo = l->>'lista_id_externo', nome_lista = l->>'nome_lista',
             pasta_id_externo = l->>'pasta_id_externo', pasta_nome = l->>'pasta_nome',
             fap = coalesce(l->>'fap', fap), tipo = v_tipo, ativa = v_ativa,
             cliente_id = coalesce(cliente_id, v_cliente)
       where id = v_f.id
         and (lista_id_externo is distinct from l->>'lista_id_externo' or nome_lista is distinct from l->>'nome_lista'
              or pasta_id_externo is distinct from l->>'pasta_id_externo' or pasta_nome is distinct from l->>'pasta_nome'
              or fap is distinct from coalesce(l->>'fap', fap) or tipo is distinct from v_tipo
              or ativa is distinct from v_ativa or (cliente_id is null and v_cliente is not null));
    else
      insert into clientes_faps (cliente_id, fap, nome_lista, pasta_nome, lista_id_externo, pasta_id_externo,
                                 tipo, ativa, situacao_sincronizacao, observacao)
      values (v_cliente, l->>'fap', l->>'nome_lista', l->>'pasta_nome', l->>'lista_id_externo', l->>'pasta_id_externo',
              v_tipo, v_ativa,
              case when v_ativa then 'a_analisar' else 'nao_sincronizar' end,
              case when v_ativa then null else 'Encerrada na origem: marcada como não sincronizar automaticamente' end);
      if v_ativa then v_novas := v_novas + 1; end if;
    end if;

    -- guarda a pasta no cadastro do cliente (ajuda a criar tarefas na fase 4)
    if v_cliente is not null and l->>'pasta_id_externo' is not null then
      update clientes set pasta_id_externo = l->>'pasta_id_externo'
       where id = v_cliente and pasta_id_externo is null;
    end if;
  end loop;
  return jsonb_build_object('novas_a_analisar', v_novas, 'ligadas_ao_cadastro', v_ligadas, 'conhecidas', v_atual);
end $$;

-- Tarefas da origem → tarefas + tarefas_responsaveis.
-- p_tarefas: [{id_externo, codigo_externo, nome, detalhamento, status, status_tipo, url,
--              lista_id_externo, lista_nome, pasta_id_externo, pasta_nome, tarefa_pai_id_externo,
--              fap, parceiro_id_externo, parceiro_nome, usuario_cliente, origem_solicitacao, periodo,
--              data_inicio, data_vencimento, criada_na_origem, atualizada_na_origem, fechada_na_origem,
--              minutos_registrados, minutos_estimados, campos_personalizados,
--              criada_por_id_externo, criada_por_nome, responsaveis: [{usuario_id_externo, nome_externo}],
--              dados_origem}]
-- Regra D14: tarefa NOVA só entra se a lista estiver marcada E algum responsável for um
-- consultor marcado (ou a conta compartilhada ligada a um consultor marcado naquela FAP).
-- Tarefa que já está no banco é sempre atualizada.
-- Tarefa nova passa pela sugestão de agrupamento (entra no repositório como pendente).
create or replace function public.gravar_tarefas(p_origem text, p_tarefas jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  t          jsonb;
  v_existe   tarefas%rowtype;
  v_lista    clientes_faps%rowtype;
  v_id       uuid;
  v_fap      text;
  v_entra    boolean;
  v_novas_ids uuid[] := '{}';
  v_lidas    int := 0;
  v_novas    int := 0;
  v_alter    int := 0;
  v_ignor    int := 0;
  v_sug      int := 0;
begin
  for t in select * from jsonb_array_elements(coalesce(p_tarefas, '[]'::jsonb)) loop
    v_lidas := v_lidas + 1;
    select * into v_existe from tarefas where origem = p_origem and id_externo = t->>'id_externo';
    select * into v_lista  from clientes_faps where lista_id_externo = t->>'lista_id_externo';
    v_fap := coalesce(v_lista.fap, t->>'fap');

    if v_existe.id is null then
      v_entra := coalesce(v_lista.situacao_sincronizacao = 'sincronizar', false) and exists (
        select 1 from jsonb_array_elements(coalesce(t->'responsaveis', '[]'::jsonb)) r
         where exists (select 1 from consultores c
                        where c.sincronizar and c.ativo and c.id_externo = r->>'usuario_id_externo')
            or exists (select 1 from responsavel_real_por_fap d join consultores c on c.id = d.consultor_id
                        where c.sincronizar and c.ativo and d.fap = v_fap
                          and (d.usuario_id_externo = r->>'usuario_id_externo'
                               or public.normalizar_texto(d.nome_externo) = public.normalizar_texto(r->>'nome_externo'))));
      if not v_entra then
        v_ignor := v_ignor + 1;
        continue;
      end if;
    end if;

    insert into tarefas (
      origem, id_externo, codigo_externo, nome, detalhamento, status, status_tipo, url,
      lista_id_externo, lista_nome, pasta_id_externo, pasta_nome, tarefa_pai_id_externo,
      fap_id, cliente_id, fap, usuario_cliente, origem_solicitacao, periodo, minutos_periodo,
      data_inicio, data_vencimento, criada_na_origem, atualizada_na_origem, fechada_na_origem,
      minutos_registrados, minutos_estimados, campos_personalizados,
      criada_por_id_externo, criada_por_nome, excluida_na_origem, ultima_sincronizacao, dados_origem)
    values (
      p_origem, t->>'id_externo', t->>'codigo_externo', coalesce(nullif(t->>'nome', ''), '(sem nome)'),
      t->>'detalhamento', t->>'status', t->>'status_tipo', t->>'url',
      t->>'lista_id_externo', t->>'lista_nome', t->>'pasta_id_externo', t->>'pasta_nome', t->>'tarefa_pai_id_externo',
      v_lista.id,
      coalesce((select id from clientes where parceiro_id_externo = t->>'parceiro_id_externo' limit 1),
               public.cliente_por_nome(t->>'parceiro_nome'), v_lista.cliente_id),
      v_fap, t->>'usuario_cliente', t->>'origem_solicitacao', t->>'periodo', public.minutos_do_periodo(t->>'periodo'),
      (t->>'data_inicio')::timestamptz, (t->>'data_vencimento')::timestamptz,
      (t->>'criada_na_origem')::timestamptz, (t->>'atualizada_na_origem')::timestamptz,
      (t->>'fechada_na_origem')::timestamptz,
      coalesce((t->>'minutos_registrados')::int, 0), (t->>'minutos_estimados')::int, t->'campos_personalizados',
      t->>'criada_por_id_externo', t->>'criada_por_nome', false, now(), t->'dados_origem')
    on conflict (origem, id_externo) do update set
      codigo_externo = excluded.codigo_externo, nome = excluded.nome, detalhamento = excluded.detalhamento,
      status = excluded.status, status_tipo = excluded.status_tipo, url = excluded.url,
      lista_id_externo = excluded.lista_id_externo, lista_nome = excluded.lista_nome,
      pasta_id_externo = excluded.pasta_id_externo, pasta_nome = excluded.pasta_nome,
      tarefa_pai_id_externo = excluded.tarefa_pai_id_externo,
      fap_id = coalesce(excluded.fap_id, tarefas.fap_id),
      cliente_id = coalesce(excluded.cliente_id, tarefas.cliente_id),
      fap = coalesce(excluded.fap, tarefas.fap),
      usuario_cliente = excluded.usuario_cliente, origem_solicitacao = excluded.origem_solicitacao,
      periodo = excluded.periodo, minutos_periodo = excluded.minutos_periodo,
      data_inicio = excluded.data_inicio, data_vencimento = excluded.data_vencimento,
      criada_na_origem = excluded.criada_na_origem, atualizada_na_origem = excluded.atualizada_na_origem,
      fechada_na_origem = excluded.fechada_na_origem,
      minutos_registrados = excluded.minutos_registrados, minutos_estimados = excluded.minutos_estimados,
      campos_personalizados = excluded.campos_personalizados,
      criada_por_id_externo = excluded.criada_por_id_externo, criada_por_nome = excluded.criada_por_nome,
      excluida_na_origem = false, ultima_sincronizacao = now(), dados_origem = excluded.dados_origem
    returning id into v_id;

    -- Responsáveis: remove quem saiu, grava quem está. A conta compartilhada é trocada
    -- pelo consultor real no gatilho resolver_responsavel_real() (D17).
    delete from tarefas_responsaveis
     where tarefa_id = v_id and usuario_id_externo is not null
       and usuario_id_externo <> all (array(
             select r->>'usuario_id_externo' from jsonb_array_elements(coalesce(t->'responsaveis', '[]'::jsonb)) r));
    insert into tarefas_responsaveis (tarefa_id, usuario_id_externo, nome_externo, consultor_id)
    select v_id, r->>'usuario_id_externo', r->>'nome_externo',
           (select c.id from consultores c where c.id_externo = r->>'usuario_id_externo')
      from jsonb_array_elements(coalesce(t->'responsaveis', '[]'::jsonb)) r
     where r->>'usuario_id_externo' is not null
    on conflict (tarefa_id, usuario_id_externo) do update
       set nome_externo = excluded.nome_externo, consultor_id = excluded.consultor_id;

    if v_existe.id is null then
      v_novas := v_novas + 1;
      v_novas_ids := v_novas_ids || v_id;
    elsif v_existe.atualizada_na_origem is distinct from (t->>'atualizada_na_origem')::timestamptz
       or v_existe.excluida_na_origem then
      v_alter := v_alter + 1;
    end if;
  end loop;

  -- Sugestões só depois de tudo gravado (uma tarefa nova pode ajudar a outra).
  -- Erro numa sugestão não derruba a sincronização.
  foreach v_id in array v_novas_ids loop
    begin
      v_sug := v_sug + coalesce(public.sugerir_agrupamento(v_id), 0);
    exception when others then
      raise warning 'Sugestão de agrupamento falhou para a tarefa %: %', v_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('lidas', v_lidas, 'novas', v_novas, 'alteradas', v_alter,
                            'ignoradas', v_ignor, 'sugestoes', v_sug, 'novas_ids', to_jsonb(v_novas_ids));
end $$;

-- Registros de tempo da origem → registros_tempo.
-- p_registros: [{id_externo, tarefa_id_externo, usuario_id_externo, inicio, fim, minutos, descricao, faturavel}]
-- Só grava tempo de tarefa que já está no banco. Registro que sumiu da origem dentro da
-- janela consultada (mesmos usuários, mesmo período) é marcado como excluído (D8).
create or replace function public.gravar_registros_tempo(
  p_origem text, p_inicio timestamptz, p_fim timestamptz, p_usuarios text[], p_registros jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  r          jsonb;
  v_tarefa   uuid;
  v_ids      text[] := '{}';
  v_gravados int := 0;
  v_ignor    int := 0;
  v_excl     int := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p_registros, '[]'::jsonb)) loop
    select id into v_tarefa from tarefas where origem = p_origem and id_externo = r->>'tarefa_id_externo';
    if v_tarefa is null then
      v_ignor := v_ignor + 1;
      continue;
    end if;
    insert into registros_tempo (origem, id_externo, tarefa_id, usuario_id_externo, consultor_id,
                                 inicio, fim, minutos, descricao, faturavel, excluido_na_origem, ultima_sincronizacao)
    values (p_origem, r->>'id_externo', v_tarefa, r->>'usuario_id_externo',
            (select c.id from consultores c where c.id_externo = r->>'usuario_id_externo'),
            (r->>'inicio')::timestamptz, (r->>'fim')::timestamptz, greatest(0, coalesce((r->>'minutos')::int, 0)),
            r->>'descricao', (r->>'faturavel')::boolean, false, now())
    on conflict (origem, id_externo) do update set
      tarefa_id = excluded.tarefa_id, usuario_id_externo = excluded.usuario_id_externo,
      consultor_id = excluded.consultor_id, inicio = excluded.inicio, fim = excluded.fim,
      minutos = excluded.minutos, descricao = excluded.descricao, faturavel = excluded.faturavel,
      excluido_na_origem = false, ultima_sincronizacao = now();
    v_ids := v_ids || (r->>'id_externo');
    v_gravados := v_gravados + 1;
  end loop;

  update registros_tempo set excluido_na_origem = true, ultima_sincronizacao = now()
   where origem = p_origem and not excluido_na_origem
     and inicio >= p_inicio and inicio < p_fim
     and usuario_id_externo = any (coalesce(p_usuarios, '{}'))
     and id_externo <> all (v_ids);
  get diagnostics v_excl = row_count;

  return jsonb_build_object('gravados', v_gravados, 'ignorados', v_ignor, 'excluidos', v_excl);
end $$;

-- Tarefa apagada na origem: marca, nunca apaga (D8).
create or replace function public.marcar_tarefa_excluida(p_origem text, p_id_externo text,
  p_autor_id_externo text default null, p_autor_nome text default null)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  update tarefas set excluida_na_origem = true, ultima_sincronizacao = now()
   where origem = p_origem and id_externo = p_id_externo and not excluida_na_origem
  returning id into v_id;
  if v_id is null then
    return false;
  end if;
  insert into tarefas_historico (tarefa_id, origem, evento, autor_id_externo, autor_nome)
  values (v_id, p_origem, 'excluida', p_autor_id_externo, p_autor_nome);
  return true;
end $$;

-- "Quem alterou o quê" (D13), a partir dos avisos do webhook.
-- p_itens: [{id_externo, evento, campo, valor_anterior, valor_novo, autor_id_externo, autor_nome, ocorrido_em}]
create or replace function public.gravar_historico_tarefa(p_origem text, p_tarefa_id_externo text, p_itens jsonb)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tarefa uuid;
  v_qtd    int;
begin
  select id into v_tarefa from tarefas where origem = p_origem and id_externo = p_tarefa_id_externo;
  if v_tarefa is null then
    return 0;
  end if;
  insert into tarefas_historico (tarefa_id, origem, id_externo, evento, campo, valor_anterior, valor_novo,
                                 autor_id_externo, autor_nome, ocorrido_em)
  select v_tarefa, p_origem, i->>'id_externo', coalesce(i->>'evento', 'alterada'), i->>'campo',
         left(i->>'valor_anterior', 2000), left(i->>'valor_novo', 2000),
         i->>'autor_id_externo', i->>'autor_nome', coalesce((i->>'ocorrido_em')::timestamptz, now())
    from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) i
  on conflict (origem, id_externo) do nothing;
  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

-- -----------------------------------------------------------------------------
-- 5. Agendamento (pg_cron chama a Edge Function de sincronização a cada N minutos)
-- -----------------------------------------------------------------------------

-- Faz a chamada HTTP (assíncrona, pelo pg_net). Também serve para disparar na mão:
--   select public.disparar_sincronizacao('manual');
create or replace function public.disparar_sincronizacao(p_tipo text default 'periodica')
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := (select valor from configuracoes where chave = 'sincronizacao');
  v_id  bigint;
begin
  if v_cfg->>'url_funcoes' is null then
    raise exception 'Agendamento não configurado: rode select public.agendar_sincronizacao(''https://<projeto>.supabase.co'');';
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 10000)'
     into v_id
    using (v_cfg->>'url_funcoes') || '/functions/v1/' || (v_cfg->>'funcao'),
          jsonb_build_object('tipo', p_tipo),
          jsonb_build_object('Content-Type', 'application/json',
                             'x-chave-agendamento', public.ler_segredo('chave_agendamento'));
  return v_id;
end $$;

-- Configura (ou refaz) o agendamento. Rodar uma vez no SQL Editor depois do deploy:
--   select public.agendar_sincronizacao('https://<projeto>.supabase.co');
create or replace function public.agendar_sincronizacao(p_url_base text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_min  int;
  v_expr text;
begin
  update configuracoes set valor = valor || jsonb_build_object('url_funcoes', rtrim(p_url_base, '/'))
   where chave = 'sincronizacao';
  v_min := coalesce((select (valor->>'intervalo_minutos')::int from configuracoes where chave = 'sincronizacao'), 20);
  v_expr := '*/' || v_min || ' * * * *';
  execute 'select cron.unschedule(jobid) from cron.job where jobname = ''sincronizacao-periodica''';
  execute 'select cron.schedule(''sincronizacao-periodica'', $1, ''select public.disparar_sincronizacao(''''periodica'''')'')'
    using v_expr;
  -- limpeza mensal do log (mantém 90 dias)
  execute 'select cron.unschedule(jobid) from cron.job where jobname = ''limpar-log-sincronizacao''';
  execute 'select cron.schedule(''limpar-log-sincronizacao'', ''15 3 * * 0'',
           ''delete from public.sincronizacoes where iniciado_em < now() - interval ''''90 days'''''')';
  return 'Agendado: ' || v_expr;
end $$;

-- -----------------------------------------------------------------------------
-- 6. Permissões
-- Funções internas: só a chave de serviço (Edge Functions). Funções de tela: gestor logado.
-- -----------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.salvar_segredo(text, text, text)',
    'public.ler_segredo(text)',
    'public.conferir_chave_agendamento(text)',
    'public.salvar_conta_integracao(uuid, text, text, text, text, text, text)',
    'public.ler_token_sincronizacao(text)',
    'public.ler_token_usuario(uuid, text)',
    'public.registrar_uso_conta(uuid, text)',
    'public.filtros_sincronizacao()',
    'public.inicio_busca_tarefas(text)',
    'public.gravar_membros(jsonb)',
    'public.gravar_listas(jsonb)',
    'public.gravar_tarefas(text, jsonb)',
    'public.gravar_registros_tempo(text, timestamptz, timestamptz, text[], jsonb)',
    'public.marcar_tarefa_excluida(text, text, text, text)',
    'public.gravar_historico_tarefa(text, text, jsonb)',
    'public.disparar_sincronizacao(text)',
    'public.agendar_sincronizacao(text)',
    'public.cliente_por_nome(text)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

revoke execute on function public.definir_conta_sincronizacao(uuid) from public, anon;
revoke execute on function public.desconectar_conta(uuid) from public, anon;
grant execute on function public.definir_conta_sincronizacao(uuid) to authenticated;
grant execute on function public.desconectar_conta(uuid) to authenticated;
