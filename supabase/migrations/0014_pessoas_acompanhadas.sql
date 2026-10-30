-- =============================================================================
-- 0014 — Só as pessoas acompanhadas entram nos painéis (D76, 30/10/2026)
-- =============================================================================
-- A marcação "Sincronizar" (na tela: "Acompanhar") da tela Consultores passa a querer dizer "pessoa que eu acompanho":
--   • agenda de pessoa NÃO marcada sai da conta (não aparece no Kanban/Horas e não soma na demanda);
--     agenda SEM responsável continua contando (não dá para saber de quem é);
--   • demanda só vai para o Kanban se o responsável dela for marcado ou se tiver pelo menos uma agenda
--     que conta ("acompanhada"); a tela Demandas continua listando tudo, com os totais das marcadas;
--   • tempo rastreado de pessoa não marcada sai das Horas;
--   • acesso de consultor só para pessoa marcada (senão ela veria o Kanban vazio).
-- A sincronização NÃO muda: continua trazendo tudo das listas marcadas (D32). Marcar alguém depois
-- faz as agendas dele aparecerem na hora, sem esperar a varredura.
-- As views mantêm as colunas na mesma ordem e ganham as novas no fim (create or replace).
-- =============================================================================

-- Agenda conta para a pessoa? (sem responsável conta; responsável fora do cadastro — nome da origem — não conta)
create or replace function public.pessoa_acompanhada(p_consultor uuid, p_tem_responsavel boolean)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select case when not p_tem_responsavel then true
              else coalesce((select sincronizar and ativo from consultores where id = p_consultor), false) end
$$;

-- ---------------- vw_agendas ----------------
-- Responsável mostrado: se a agenda tem mais de um, o acompanhado vem primeiro.
create or replace view public.vw_agendas
with (security_invoker = true) as
select a.id, a.demanda_tarefa_id as demanda_id, a.nome, a.status,
       case when a.situacao_agenda = 'agendada' and a.data_agenda is not null
             and (a.data_agenda at time zone 'America/Campo_Grande')::date < public.hoje_local()
            then 'atrasada' else a.situacao_agenda end as situacao_agenda,
       a.data_agenda,
       a.periodo, a.minutos_agenda, a.minutos_registrados, a.selecao, a.url, a.nivel,
       r.consultor_id, coalesce(co.nome, r.nome_externo) as consultor_nome,
       (d.selecao = 'sincronizar' and a.selecao <> 'nao_sincronizar' and not a.excluida_na_origem
        and (a.data_agenda is null or a.data_agenda >= public.data_corte())
        and public.pessoa_acompanhada(r.consultor_id, r.tem)) as incluida,
       (a.data_agenda is null or a.data_agenda >= public.data_corte()) as no_periodo,
       -- nova na 0014
       public.pessoa_acompanhada(r.consultor_id, r.tem) as consultor_acompanhado
  from public.tarefas a
  join public.tarefas d on d.id = a.demanda_tarefa_id
  left join lateral (
    select rr.consultor_id, rr.nome_externo, true as tem
      from public.tarefas_responsaveis rr
      left join public.consultores cc on cc.id = rr.consultor_id
     where rr.tarefa_id = a.id
     order by coalesce(cc.sincronizar and cc.ativo, false) desc, rr.consultor_id nulls last
     limit 1) r0 on true
  cross join lateral (select r0.consultor_id, r0.nome_externo, coalesce(r0.tem, false) as tem) r
  left join public.consultores co on co.id = r.consultor_id
 where a.eh_folha and not a.excluida_na_origem;

-- ---------------- vw_demandas ----------------
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
       h.primeira_agenda, h.ultima_agenda,
       coalesce(h.min_atrasados, 0) as minutos_atrasados,
       coalesce(h.qtd_atrasadas, 0) as qtd_atrasadas,
       -- novas na 0014
       exists (select 1 from public.tarefas_responsaveis rr join public.consultores co on co.id = rr.consultor_id
                where rr.tarefa_id = d.id and co.sincronizar and co.ativo) as responsavel_acompanhado,
       (coalesce(h.qtd_agendas, 0) > 0
        or exists (select 1 from public.tarefas_responsaveis rr join public.consultores co on co.id = rr.consultor_id
                    where rr.tarefa_id = d.id and co.sincronizar and co.ativo)) as acompanhada
  from public.tarefas d
  left join public.clientes c on c.id = d.cliente_id
  left join public.clientes_faps f on f.id = d.fap_id
  left join lateral (
    -- totais só das agendas que contam: consideradas, no período e de pessoa acompanhada (D76)
    select count(*) filter (where x.selecao <> 'nao_sincronizar') as qtd_agendas,
           sum(x.minutos_agenda) filter (where x.sit = 'realizada' and x.selecao <> 'nao_sincronizar') as min_realizados,
           sum(x.minutos_agenda) filter (where x.sit = 'agendada' and x.selecao <> 'nao_sincronizar') as min_agendados,
           sum(x.minutos_agenda) filter (where x.sit = 'atrasada' and x.selecao <> 'nao_sincronizar') as min_atrasados,
           count(*) filter (where x.sit = 'atrasada' and x.selecao <> 'nao_sincronizar') as qtd_atrasadas,
           min(x.data_agenda) as primeira_agenda, max(x.data_agenda) as ultima_agenda
      from (select a.*,
                   case when a.situacao_agenda = 'agendada' and a.data_agenda is not null
                         and (a.data_agenda at time zone 'America/Campo_Grande')::date < public.hoje_local()
                        then 'atrasada' else a.situacao_agenda end as sit
              from public.tarefas a
             where a.demanda_tarefa_id = d.id and a.eh_folha and not a.excluida_na_origem
               and (a.data_agenda is null or a.data_agenda >= public.data_corte())
               and (not exists (select 1 from public.tarefas_responsaveis rr where rr.tarefa_id = a.id)
                    or exists (select 1 from public.tarefas_responsaveis rr join public.consultores co on co.id = rr.consultor_id
                                where rr.tarefa_id = a.id and co.sincronizar and co.ativo))) x
  ) h on true
 where d.papel = 'demanda' and not d.excluida_na_origem
   -- Visibilidade (D42), sem mudança
   and (h.ultima_agenda >= public.data_corte()
        or (h.ultima_agenda is null and h.qtd_agendas > 0)
        or (coalesce(d.status_tipo, '') not in ('closed', 'done') and not d.eh_folha));

-- ---------------- vw_horas_dia: tempo rastreado só de pessoa acompanhada ----------------
create or replace view public.vw_horas_dia
with (security_invoker = true) as
with agendas as (
  select (a.data_agenda at time zone 'America/Campo_Grande')::date as dia,
         a.consultor_id, a.consultor_nome, a.demanda_id,
         coalesce(sum(a.minutos_agenda) filter (where a.situacao_agenda = 'realizada'), 0) as realizados,
         coalesce(sum(a.minutos_agenda) filter (where a.situacao_agenda = 'agendada'), 0)  as agendados,
         coalesce(sum(a.minutos_agenda) filter (where a.situacao_agenda = 'atrasada'), 0)  as atrasados,
         0::bigint as rastreados,
         count(*) as agendas
    from public.vw_agendas a
   where a.incluida and a.data_agenda is not null and a.situacao_agenda <> 'nao_executada'
   group by 1, 2, 3, 4
),
tempo as (
  select (r.inicio at time zone 'America/Campo_Grande')::date as dia,
         r.consultor_id, co.nome as consultor_nome, coalesce(t.demanda_tarefa_id, t.id) as demanda_id,
         0::bigint, 0::bigint, 0::bigint, sum(r.minutos)::bigint, 0::bigint
    from public.registros_tempo r
    join public.tarefas t on t.id = r.tarefa_id
    left join public.consultores co on co.id = r.consultor_id
   where not r.excluido_na_origem and not t.excluida_na_origem
     and t.selecao is distinct from 'nao_sincronizar'
     and r.inicio >= public.data_corte()
     and coalesce(co.sincronizar and co.ativo, false)                  -- D76: só pessoa acompanhada
   group by 1, 2, 3, 4
)
select x.dia, date_trunc('month', x.dia)::date as mes,
       x.consultor_id, x.consultor_nome,
       x.demanda_id, d.nome as demanda_nome, d.status as demanda_status, d.url as demanda_url,
       d.cliente_id, d.cliente_nome, d.sigla_gerente,
       sum(x.realizados)::int as minutos_realizados,
       sum(x.agendados)::int  as minutos_agendados,
       sum(x.atrasados)::int  as minutos_atrasados,
       sum(x.rastreados)::int as minutos_rastreados,
       sum(x.agendas)::int    as agendas
  from (select * from agendas union all select * from tempo) x
  join public.vw_demandas d on d.id = x.demanda_id and d.selecao = 'sincronizar'
 where public.eh_gestor() or x.consultor_id = public.consultor_do_usuario()
 group by x.dia, x.consultor_id, x.consultor_nome, x.demanda_id, d.nome, d.status, d.url,
          d.cliente_id, d.cliente_nome, d.sigla_gerente;

-- ---------------- Acesso de consultor só para pessoa marcada ----------------
-- Mesma função da 0013, com uma regra a mais (antes de devolver os dados).
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
  if v_papel = 'consultor' and not v_cons.sincronizar then
    raise exception 'Marque % em "Acompanhar" (tela Consultores) antes de dar acesso: só as pessoas marcadas aparecem no Kanban e nas Horas.', v_cons.nome; end if;

  return jsonb_build_object(
    'nome', v_cons.nome, 'email', lower(btrim(v_cons.email)), 'papel', v_papel,
    'usuario_id', coalesce(v_atual.id, (select id from auth.users where lower(email) = lower(btrim(v_cons.email)) limit 1)));
end $$;

revoke execute on function public.pessoa_acompanhada(uuid, boolean) from public, anon;
grant execute on function public.pessoa_acompanhada(uuid, boolean) to authenticated, service_role;
grant select on public.vw_agendas, public.vw_demandas, public.vw_horas_dia to authenticated;
