-- =============================================================================
-- 0012 — Fase 4: relatório de horas e visão do consultor (D71, D72, ajustadas em 28/10/2026)
-- =============================================================================
-- 1. vw_horas_dia: horas por DIA × consultor × demanda (com cliente e gerente), juntando
--      • as horas das agendas (realizadas, agendadas, atrasadas — D34, D51) e
--      • o tempo RASTREADO (registros de tempo, cronômetro da origem).
--    É a fonte do painel de Horas (período de/até, comparação e CSV). Genérica: no dia em que as
--    tarefas e o tempo nascerem no próprio sistema (origem = 'interno'), a view continua igual (D10).
--    Consultor logado só enxerga as linhas dele; gestor enxerga tudo.
-- 2. Consultor logado (papel 'consultor', ligado ao cadastro em usuarios_sistema.consultor_id):
--    LÊ as demandas em que é responsável ou tem agenda (com todas as agendas delas), clientes,
--    listas, nomes dos consultores e o próprio tempo rastreado. Não grava nada (sem política de escrita).
-- =============================================================================

-- ---------------- 1. Horas por dia ----------------
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
  -- tempo rastreado na tarefa (agenda, etapa ou a própria demanda) vai para a demanda dela
  select (r.inicio at time zone 'America/Campo_Grande')::date as dia,
         r.consultor_id, co.nome as consultor_nome, coalesce(t.demanda_tarefa_id, t.id) as demanda_id,
         0::bigint, 0::bigint, 0::bigint, sum(r.minutos)::bigint, 0::bigint
    from public.registros_tempo r
    join public.tarefas t on t.id = r.tarefa_id
    left join public.consultores co on co.id = r.consultor_id
   where not r.excluido_na_origem and not t.excluida_na_origem
     and t.selecao is distinct from 'nao_sincronizar'
     and r.inicio >= public.data_corte()
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

comment on view public.vw_horas_dia is
  'Horas por dia × consultor × demanda: agendas (realizadas/agendadas/atrasadas) e tempo rastreado. Painel de Horas e CSV (D71).';

-- ---------------- 2. Leitura do consultor (D72) ----------------
-- É consultor (papel 'consultor', ativo e ligado ao cadastro)?
create or replace function public.eh_consultor()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from usuarios_sistema
                 where id = auth.uid() and ativo and papel = 'consultor' and consultor_id is not null)
$$;

-- Demandas que o consultor logado enxerga: é responsável pela demanda ou por qualquer tarefa abaixo dela.
create or replace function public.demandas_do_consultor()
returns setof uuid language sql stable security definer set search_path = public, extensions as $$
  select distinct coalesce(t.demanda_tarefa_id, t.id)
    from tarefas t join tarefas_responsaveis r on r.tarefa_id = t.id
   where public.eh_consultor() and r.consultor_id = public.consultor_do_usuario()
     and not t.excluida_na_origem
$$;

drop policy if exists consultor_le on public.tarefas;
create policy consultor_le on public.tarefas for select to authenticated
  using (public.eh_consultor() and coalesce(demanda_tarefa_id, id) in (select public.demandas_do_consultor()));

-- responsáveis das tarefas que ele enxerga (a política da tabela tarefas vale aqui dentro)
drop policy if exists consultor_le on public.tarefas_responsaveis;
create policy consultor_le on public.tarefas_responsaveis for select to authenticated
  using (public.eh_consultor() and tarefa_id in (select id from public.tarefas));

-- nomes para os filtros e cartões
drop policy if exists consultor_le on public.consultores;
create policy consultor_le on public.consultores for select to authenticated using (public.eh_consultor());
drop policy if exists consultor_le on public.clientes;
create policy consultor_le on public.clientes for select to authenticated using (public.eh_consultor());
drop policy if exists consultor_le on public.clientes_faps;
create policy consultor_le on public.clientes_faps for select to authenticated using (public.eh_consultor());

-- só o próprio tempo rastreado
drop policy if exists consultor_le on public.registros_tempo;
create policy consultor_le on public.registros_tempo for select to authenticated
  using (public.eh_consultor() and consultor_id = public.consultor_do_usuario());

-- ---------------- Permissões ----------------
grant execute on function public.eh_consultor() to authenticated;
grant execute on function public.demandas_do_consultor() to authenticated;
grant select on public.vw_horas_dia to authenticated;
