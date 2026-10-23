-- =============================================================================
-- Gestão de Demandas BP-MS — ajustes da hierarquia depois da comparação com o ClickUp (23/10/2026)
--
-- 1. Atendimentos repetidos dentro de "1-Atendimento Base": subtarefas FOLHA com o mesmo nome
--    na mesma lista, logo abaixo de uma estrutura, viram UMA demanda com várias agendas (D38).
-- 2. Tarefa-mãe que não veio na varredura (não foi alterada desde o corte) é buscada à parte:
--    `pais_faltando` diz quais faltam; `gravar_tarefas` aceita a mãe de uma tarefa que já está
--    no banco, mesmo que ela não tenha mudado (D39).
-- 3. Corte pela DATA DA AGENDA: só agendas a partir de 01/01/2026 entram nas horas; demanda
--    fechada antes do corte e sem agenda depois dele some das telas (D40).
-- =============================================================================

-- Data de corte (configuracoes.sincronizacao.carga_desde), no fuso do MS.
create or replace function public.data_corte()
returns timestamptz language sql stable security definer set search_path = public, extensions as $$
  select (coalesce((select valor->>'carga_desde' from configuracoes where chave = 'sincronizacao'), '2026-01-01')
          || 'T00:00:00-04:00')::timestamptz
$$;

-- ---------------- 1. Hierarquia com junção dos atendimentos repetidos ----------------
create or replace function public.recalcular_hierarquia(p_origem text default 'clickup')
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_qtd int;
begin
  with recursive
  base as (
    select t.id, t.id_externo, t.estrutura, t.lista_id_externo, t.selecao, t.criada_na_origem,
           t.excluida_na_origem, public.normalizar_texto(t.nome) as nome_norm,
           p.id as pai_id, coalesce(p.estrutura, false) as pai_estrutura
      from tarefas t
      left join tarefas p on p.origem = t.origem and p.id_externo = t.tarefa_pai_id_externo
     where t.origem = p_origem
  ),
  filhos as (
    select pai_id as id, count(*) as qtd from base where pai_id is not null and not estrutura group by pai_id
  ),
  -- raízes: não é estrutura e (sem mãe no banco ou mãe é estrutura)
  raizes as (
    select b.*, coalesce(f.qtd, 0) = 0 as folha
      from base b left join filhos f on f.id = b.id
     where not b.estrutura and (b.pai_id is null or b.pai_estrutura)
  ),
  -- atendimentos avulsos (folha logo abaixo de estrutura) com o mesmo nome na mesma lista → uma demanda.
  -- Representante: o que o gestor já escolheu; senão o mais antigo (não excluído primeiro).
  raiz_final as (
    select r.id,
           case when r.folha and r.pai_estrutura then
             first_value(r.id) over (partition by r.lista_id_externo, r.nome_norm, (r.folha and r.pai_estrutura)
                                     order by r.excluida_na_origem, (r.selecao <> 'a_analisar') desc,
                                              r.criada_na_origem nulls last, r.id_externo)
           else r.id end as raiz
      from raizes r
  ),
  arvore as (
    select rf.id, rf.raiz from raiz_final rf
    union all
    select b.id, a.raiz from base b join arvore a on b.pai_id = a.id where not b.estrutura
  ),
  nivel_lista as (
    select b.id, 0 as nivel from base b where b.pai_id is null
    union all
    select b.id, n.nivel + 1 from base b join nivel_lista n on b.pai_id = n.id
  ),
  calc as (
    select t.id, n.nivel, a.raiz,
           coalesce(f.qtd, 0) = 0 as folha,
           case when t.estrutura then 'estrutura'
                when a.raiz = t.id then 'demanda'
                when coalesce(f.qtd, 0) = 0 then 'agenda'
                else 'etapa' end as papel,
           case when public.normalizar_texto(t.status) like 'nao execut%' then 'nao_executada'
                when public.normalizar_texto(t.status) like 'conclu%' or t.status_tipo in ('closed', 'done') then 'realizada'
                else 'agendada' end as situacao
      from tarefas t
      left join arvore a on a.id = t.id
      left join nivel_lista n on n.id = t.id
      left join filhos f on f.id = t.id
     where t.origem = p_origem
  )
  update tarefas t
     set nivel = c.nivel,
         papel = c.papel,
         demanda_tarefa_id = c.raiz,
         eh_folha = c.folha and c.papel <> 'estrutura',
         data_agenda = coalesce(t.data_vencimento, t.data_inicio),
         minutos_agenda = case when c.folha and c.papel <> 'estrutura'
                               then coalesce(nullif(t.minutos_estimados, 0), t.minutos_periodo) end,
         situacao_agenda = case when c.folha and c.papel <> 'estrutura' then c.situacao end,
         selecao = case when c.papel = 'estrutura' then 'nao_sincronizar' else t.selecao end
    from calc c
   where c.id = t.id
     and (t.nivel, t.papel, t.demanda_tarefa_id, t.eh_folha, t.minutos_agenda, t.situacao_agenda, t.data_agenda)
         is distinct from
         (c.nivel, c.papel, c.raiz, c.folha and c.papel <> 'estrutura',
          case when c.folha and c.papel <> 'estrutura' then coalesce(nullif(t.minutos_estimados, 0), t.minutos_periodo) end,
          case when c.folha and c.papel <> 'estrutura' then c.situacao end,
          coalesce(t.data_vencimento, t.data_inicio));
  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

-- ---------------- 2. Tarefas-mãe que faltam ----------------
-- Mães já tentadas e não encontradas (sem acesso, apagadas, em lista não marcada): não tenta de novo por 1 dia.
create table if not exists public.tarefas_ausentes (
  origem      text not null default 'clickup',
  id_externo  text not null,
  tentada_em  timestamptz not null default now(),
  motivo      text,
  primary key (origem, id_externo)
);
alter table public.tarefas_ausentes enable row level security;
drop policy if exists gestor_tudo on public.tarefas_ausentes;
create policy gestor_tudo on public.tarefas_ausentes for all to authenticated
  using (public.eh_gestor()) with check (public.eh_gestor());

create or replace function public.pais_faltando(p_origem text default 'clickup', p_limite int default 100)
returns setof text language sql stable security definer set search_path = public, extensions as $$
  select distinct t.tarefa_pai_id_externo
    from tarefas t
   where t.origem = p_origem and t.tarefa_pai_id_externo is not null
     and not exists (select 1 from tarefas p where p.origem = t.origem and p.id_externo = t.tarefa_pai_id_externo)
     and not exists (select 1 from tarefas_ausentes a where a.origem = t.origem and a.id_externo = t.tarefa_pai_id_externo
                       and a.tentada_em > now() - interval '1 day')
   limit p_limite
$$;

create or replace function public.registrar_tarefas_ausentes(p_origem text, p_ids text[], p_motivo text)
returns void language sql security definer set search_path = public, extensions as $$
  insert into tarefas_ausentes (origem, id_externo, motivo)
  select p_origem, unnest(p_ids), p_motivo
  on conflict (origem, id_externo) do update set tentada_em = now(), motivo = excluded.motivo
$$;

-- gravar_tarefas: igual à 0004, mas aceita também a MÃE de uma tarefa que já está no banco.
create or replace function public.gravar_tarefas(p_origem text, p_tarefas jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  t          jsonb;
  v_existe   tarefas%rowtype;
  v_lista    clientes_faps%rowtype;
  v_id       uuid;
  v_fap      text;
  v_lidas    int := 0;
  v_novas    int := 0;
  v_alter    int := 0;
  v_ignor    int := 0;
begin
  for t in select * from jsonb_array_elements(coalesce(p_tarefas, '[]'::jsonb)) loop
    v_lidas := v_lidas + 1;
    select * into v_existe from tarefas where origem = p_origem and id_externo = t->>'id_externo';
    select * into v_lista  from clientes_faps where lista_id_externo = t->>'lista_id_externo';
    v_fap := coalesce(v_lista.fap, t->>'fap');

    -- entra se a lista está marcada OU se é a mãe de uma tarefa que já está no banco (D39)
    if v_existe.id is null and coalesce(v_lista.situacao_sincronizacao, '') <> 'sincronizar'
       and not exists (select 1 from tarefas c where c.origem = p_origem and c.tarefa_pai_id_externo = t->>'id_externo') then
      v_ignor := v_ignor + 1;
      continue;
    end if;

    insert into tarefas (
      origem, id_externo, codigo_externo, nome, detalhamento, status, status_tipo, url,
      lista_id_externo, lista_nome, pasta_id_externo, pasta_nome, tarefa_pai_id_externo,
      fap_id, cliente_id, fap, usuario_cliente, origem_solicitacao, periodo, minutos_periodo,
      data_inicio, data_vencimento, criada_na_origem, atualizada_na_origem, fechada_na_origem,
      minutos_registrados, minutos_estimados, campos_personalizados,
      criada_por_id_externo, criada_por_nome, excluida_na_origem, ultima_sincronizacao, dados_origem,
      estrutura, etapa, agenda_tipo)
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
      t->>'criada_por_id_externo', t->>'criada_por_nome', false, now(), t->'dados_origem',
      coalesce((t->>'estrutura')::boolean, false), t->>'etapa', t->>'agenda_tipo')
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
      excluida_na_origem = false, ultima_sincronizacao = now(), dados_origem = excluded.dados_origem,
      estrutura = excluded.estrutura, etapa = excluded.etapa, agenda_tipo = excluded.agenda_tipo
    returning id into v_id;

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
    elsif v_existe.atualizada_na_origem is distinct from (t->>'atualizada_na_origem')::timestamptz
       or v_existe.excluida_na_origem then
      v_alter := v_alter + 1;
    end if;
  end loop;

  perform public.recalcular_hierarquia(p_origem);

  return jsonb_build_object('lidas', v_lidas, 'novas', v_novas, 'alteradas', v_alter, 'ignoradas', v_ignor);
end $$;

-- ---------------- 3. Corte pela data da agenda ----------------
create or replace view public.vw_agendas
with (security_invoker = true) as
select a.id, a.demanda_tarefa_id as demanda_id, a.nome, a.status, a.situacao_agenda, a.data_agenda,
       a.periodo, a.minutos_agenda, a.minutos_registrados, a.selecao, a.url, a.nivel,
       r.consultor_id, coalesce(co.nome, r.nome_externo) as consultor_nome,
       (d.selecao = 'sincronizar' and a.selecao <> 'nao_sincronizar' and not a.excluida_na_origem
        and (a.data_agenda is null or a.data_agenda >= public.data_corte())) as incluida,
       (a.data_agenda is null or a.data_agenda >= public.data_corte()) as no_periodo
  from public.tarefas a
  join public.tarefas d on d.id = a.demanda_tarefa_id
  left join lateral (select rr.consultor_id, rr.nome_externo from public.tarefas_responsaveis rr
                      where rr.tarefa_id = a.id order by rr.consultor_id nulls last limit 1) r on true
  left join public.consultores co on co.id = r.consultor_id
 where a.eh_folha and not a.excluida_na_origem;

create or replace view public.vw_demandas
with (security_invoker = true) as
select d.id, d.nome, d.status, d.status_tipo, d.etapa, d.agenda_tipo, d.detalhamento, d.url, d.selecao,
       d.data_inicio, d.data_vencimento, d.criada_na_origem, d.atualizada_na_origem, d.fechada_na_origem,
       d.minutos_estimados as minutos_planejados,
       d.cliente_id, c.nome as cliente_nome, d.fap_id, f.fap, f.nome_lista, f.pasta_nome, f.sigla_gerente,
       (select coalesce(co.nome, rr.nome_externo) from public.tarefas_responsaveis rr
          left join public.consultores co on co.id = rr.consultor_id
         where rr.tarefa_id = d.id order by rr.id limit 1) as responsavel_nome,
       coalesce(h.qtd_agendas, 0) as qtd_agendas,
       coalesce(h.min_realizados, 0) as minutos_realizados,
       coalesce(h.min_agendados, 0) as minutos_agendados,
       h.primeira_agenda, h.ultima_agenda
  from public.tarefas d
  left join public.clientes c on c.id = d.cliente_id
  left join public.clientes_faps f on f.id = d.fap_id
  left join lateral (
    select count(*) filter (where a.selecao <> 'nao_sincronizar') as qtd_agendas,
           sum(a.minutos_agenda) filter (where a.situacao_agenda = 'realizada' and a.selecao <> 'nao_sincronizar') as min_realizados,
           sum(a.minutos_agenda) filter (where a.situacao_agenda = 'agendada' and a.selecao <> 'nao_sincronizar') as min_agendados,
           min(a.data_agenda) as primeira_agenda, max(a.data_agenda) as ultima_agenda
      from public.tarefas a
     where a.demanda_tarefa_id = d.id and a.eh_folha and not a.excluida_na_origem
       and (a.data_agenda is null or a.data_agenda >= public.data_corte())
  ) h on true
 where d.papel = 'demanda' and not d.excluida_na_origem
   -- some a demanda fechada antes do corte e sem agenda depois dele
   and (coalesce(d.status_tipo, '') not in ('closed', 'done')
        or d.fechada_na_origem >= public.data_corte()
        or h.ultima_agenda >= public.data_corte());

-- contador "demandas a analisar" segue a mesma visibilidade
create or replace view public.vw_pendencias_gestor
with (security_invoker = true) as
select
  (select count(*) from public.clientes_faps where situacao_sincronizacao = 'a_analisar') as listas_a_analisar,
  (select count(*) from public.tarefas where situacao = 'pendente' and not excluida_na_origem) as tarefas_pendentes,
  (select count(distinct (normalizar_texto(r.nome_externo), t.fap))
     from public.tarefas_responsaveis r join public.tarefas t on t.id = r.tarefa_id
    where r.consultor_id is null and not t.excluida_na_origem
      and normalizar_texto(r.nome_externo) in (select normalizar_texto(nome_externo) from public.responsavel_real_por_fap)
  ) as responsaveis_sem_pessoa,
  (select count(*) from public.chamados where status = 'novo') as chamados_novos,
  (select count(*) from public.clientes_faps where situacao_sincronizacao = 'a_analisar' and sugerida) as listas_sugeridas,
  (select count(*) from public.vw_demandas where selecao = 'a_analisar') as demandas_a_analisar;

-- ---------------- Permissões ----------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.recalcular_hierarquia(text)', 'public.gravar_tarefas(text, jsonb)',
    'public.pais_faltando(text, integer)', 'public.registrar_tarefas_ausentes(text, text[], text)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- refaz a hierarquia com a regra nova
select public.recalcular_hierarquia('clickup');
