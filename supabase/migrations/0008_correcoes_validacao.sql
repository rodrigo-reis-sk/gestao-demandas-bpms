-- =============================================================================
-- Gestão de Demandas BP-MS — correções da validação de 23/10/2026
--
-- 1. Hierarquia (D49): estrutura ("2026-09 Setembro") DENTRO de uma demanda real é transparente —
--    as agendas abaixo dela pertencem à demanda. Caso real: Inovvati "2-Atendimento Folha" perdia 2 agendas
--    de set/2026 que viravam demandas soltas (também CG Telhas).
-- 2. Desempenho (D50): gravar_tarefas só recalcula se gravou algo e só nas listas afetadas; um recálculo por vez.
--    Antes, cada evento do webhook (até de lista não marcada) recalculava o banco inteiro e estourava o tempo.
-- 3. Agendas atrasadas (D51): agenda não concluída com data anterior a hoje vira "atrasada" nas telas e no
--    painel (separada de "agendada"). Calculado nas views, porque "hoje" muda sem nova sincronização.
-- =============================================================================

-- ---------------- 1 e 2. Hierarquia com recorte por lista ----------------
-- A assinatura muda (novo parâmetro p_listas): remove a antiga para não ficar ambígua.
drop function if exists public.recalcular_hierarquia(text);

create or replace function public.recalcular_hierarquia(p_origem text default 'clickup', p_listas text[] default null)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_qtd int;
begin
  -- Um recálculo por vez: rajadas de webhook esperam na fila em vez de disputar as mesmas linhas.
  perform pg_advisory_xact_lock(hashtext('recalcular_hierarquia'));
  with recursive
  -- estrutura: marcada pela tradução OU reconhecida aqui (linhas antigas, gravadas antes da marcação)
  est as (
    select t.id, t.id_externo, t.origem, t.tarefa_pai_id_externo, t.lista_id_externo, t.selecao, t.selecao_por,
           t.criada_na_origem, t.excluida_na_origem, public.normalizar_texto(t.nome) as nome_norm,
           (t.estrutura
            or public.normalizar_texto(t.status) = 'atendimento base'
            or public.normalizar_texto(t.nome) ~ '^[0-9]+ atendimento (da )?base$'
            or t.nome ~ '^\s*\d{4}-\d{2}\s+\S+\s*$') as estrutura
      from tarefas t
     where t.origem = p_origem
       and (p_listas is null or t.lista_id_externo = any(p_listas))   -- só as listas afetadas (mãe e filha ficam na mesma lista)
  ),
  base0 as (
    select e.id, e.id_externo, e.estrutura, e.lista_id_externo, e.selecao, e.selecao_por, e.criada_na_origem,
           e.excluida_na_origem, e.nome_norm, e.tarefa_pai_id_externo, p.id as pai_id
      from est e
      left join est p on p.id_externo = e.tarefa_pai_id_externo
  ),
  -- Sobe pelas estruturas até achar a primeira mãe que NÃO é estrutura (D49): a subtarefa de mês
  -- ("2026-09 Setembro") dentro de uma demanda real é transparente — as agendas abaixo dela são da demanda.
  sobe as (
    select b.id, b.pai_id as atual, 0 as passo from base0 b where b.pai_id is not null
    union all
    select s.id, p.pai_id, s.passo + 1
      from sobe s join base0 p on p.id = s.atual
     where p.estrutura and p.pai_id is not null and s.passo < 10
  ),
  pai_real as (
    select distinct on (s.id) s.id, s.atual as pai_real_id
      from sobe s join base0 p on p.id = s.atual
     where not p.estrutura
     order by s.id, s.passo
  ),
  base as (
    select b.*, pr.pai_real_id,
           (b.pai_id is not null and pr.pai_real_id is null) as so_estrutura_acima
      from base0 b left join pai_real pr on pr.id = b.id
  ),
  filhos as (
    select pai_real_id as id, count(*) as qtd from base where pai_real_id is not null and not estrutura group by pai_real_id
  ),
  -- raízes: não é estrutura e não tem nenhuma mãe "real" acima (só estruturas, ou mãe fora do banco)
  raizes as (
    select b.*, coalesce(f.qtd, 0) = 0 as folha
      from base b left join filhos f on f.id = b.id
     where not b.estrutura and b.pai_real_id is null
  ),
  -- Representante do grupo: o que o GESTOR já mexeu (selecao_por); senão o mais antigo (não excluído primeiro).
  -- Junção de folhas com o mesmo nome (D38/D41):
  --   • logo abaixo de uma estrutura → mesma lista + mesmo nome = uma demanda;
  --   • mãe ainda não está no banco → mesma mãe + mesmo nome = uma demanda (até a mãe chegar).
  raiz_final as (
    select r.id,
           case when r.folha and (r.so_estrutura_acima or (r.pai_id is null and r.tarefa_pai_id_externo is not null)) then
             first_value(r.id) over (
               partition by r.lista_id_externo, r.nome_norm,
                            case when r.so_estrutura_acima then '' else coalesce(r.tarefa_pai_id_externo, r.id_externo) end,
                            (r.folha and (r.so_estrutura_acima or (r.pai_id is null and r.tarefa_pai_id_externo is not null)))
               order by r.excluida_na_origem, (r.selecao_por is not null) desc,
                        r.criada_na_origem nulls last, r.id_externo)
           else r.id end as raiz
      from raizes r
  ),
  arvore as (
    select rf.id, rf.raiz from raiz_final rf
    union all
    select b.id, a.raiz from base b join arvore a on b.pai_real_id = a.id where not b.estrutura
  ),
  nivel_lista as (
    select b.id, 0 as nivel from base b where b.pai_id is null
    union all
    select b.id, n.nivel + 1 from base b join nivel_lista n on b.pai_id = n.id
  ),
  calc as (
    select t.id, n.nivel, a.raiz,
           coalesce(f.qtd, 0) = 0 as folha,
           e.estrutura,
           case when e.estrutura then 'estrutura'
                when a.raiz = t.id then 'demanda'
                when coalesce(f.qtd, 0) = 0 then 'agenda'
                else 'etapa' end as papel,
           case when public.normalizar_texto(t.status) like 'nao execut%' then 'nao_executada'
                when public.normalizar_texto(t.status) like 'conclu%' or t.status_tipo in ('closed', 'done') then 'realizada'
                else 'agendada' end as situacao
      from est e
      join tarefas t on t.id = e.id
      left join arvore a on a.id = t.id
      left join nivel_lista n on n.id = t.id
      left join filhos f on f.id = t.id
  )
  update tarefas t
     set estrutura = c.estrutura,
         nivel = c.nivel,
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
     and (t.estrutura, t.nivel, t.papel, t.demanda_tarefa_id, t.eh_folha, t.minutos_agenda, t.situacao_agenda, t.data_agenda)
         is distinct from
         (c.estrutura, c.nivel, c.papel, c.raiz, c.folha and c.papel <> 'estrutura',
          case when c.folha and c.papel <> 'estrutura' then coalesce(nullif(t.minutos_estimados, 0), t.minutos_periodo) end,
          case when c.folha and c.papel <> 'estrutura' then c.situacao end,
          coalesce(t.data_vencimento, t.data_inicio));
  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

-- gravar_tarefas: igual à 0005, mas recalcula só as listas que gravou (D50).
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
  v_listas   text[] := '{}';
  v_ids      text[] := '{}';
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

    v_ids := v_ids || (t->>'id_externo');

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

  -- Recalcula só se gravou algo, e só nas listas afetadas (D50). Evento de lista não marcada não recalcula nada.
  -- listas das tarefas gravadas + das filhas e mães delas (a mãe pode estar em outra lista, D39)
  if cardinality(v_ids) > 0 then
    select coalesce(array_agg(distinct l), '{}') into v_listas from (
      select g.lista_id_externo as l from tarefas g where g.origem = p_origem and g.id_externo = any(v_ids)
      union select c.lista_id_externo from tarefas c where c.origem = p_origem and c.tarefa_pai_id_externo = any(v_ids)
      union select m.lista_id_externo from tarefas g join tarefas m on m.origem = g.origem and m.id_externo = g.tarefa_pai_id_externo
             where g.origem = p_origem and g.id_externo = any(v_ids)
    ) x where l is not null;
  end if;
  if cardinality(v_listas) > 0 then
    perform public.recalcular_hierarquia(p_origem, v_listas);
  end if;

  return jsonb_build_object('lidas', v_lidas, 'novas', v_novas, 'alteradas', v_alter, 'ignoradas', v_ignor);
end $$;

-- ---------------- 3. Agendas atrasadas (D51) ----------------
-- "Hoje" no fuso da equipe (MS). Agenda de hoje ainda é agendada; de ontem para trás, atrasada.
create or replace function public.hoje_local()
returns date language sql stable as $$ select (now() at time zone 'America/Campo_Grande')::date $$;

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
       coalesce(h.min_agendados, 0) as minutos_agendados,       -- só hoje em diante (ou sem data)
       h.primeira_agenda, h.ultima_agenda,
       coalesce(h.min_atrasados, 0) as minutos_atrasados,       -- data passada e não concluída (D51)
       coalesce(h.qtd_atrasadas, 0) as qtd_atrasadas
  from public.tarefas d
  left join public.clientes c on c.id = d.cliente_id
  left join public.clientes_faps f on f.id = d.fap_id
  left join lateral (
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
               and (a.data_agenda is null or a.data_agenda >= public.data_corte())) x
  ) h on true
 where d.papel = 'demanda' and not d.excluida_na_origem
   -- Visibilidade (D42), sem mudança
   and (h.ultima_agenda >= public.data_corte()
        or (h.ultima_agenda is null and h.qtd_agendas > 0)
        or (coalesce(d.status_tipo, '') not in ('closed', 'done') and not d.eh_folha));

create or replace view public.vw_horas_mes
with (security_invoker = true) as
select date_trunc('month', a.data_agenda at time zone 'America/Campo_Grande')::date as mes,
       a.consultor_id, a.consultor_nome, d.cliente_id, d.cliente_nome,
       sum(a.minutos_agenda) filter (where a.situacao_agenda = 'realizada')::int as minutos_realizados,
       sum(a.minutos_agenda) filter (where a.situacao_agenda = 'agendada')::int as minutos_agendados,
       count(*) as agendas,
       sum(a.minutos_agenda) filter (where a.situacao_agenda = 'atrasada')::int as minutos_atrasados
  from public.vw_agendas a
  join public.vw_demandas d on d.id = a.demanda_id
 where a.incluida and a.data_agenda is not null and a.situacao_agenda <> 'nao_executada'
 group by 1, 2, 3, 4, 5;

-- ---------------- Permissões ----------------
revoke execute on function public.recalcular_hierarquia(text, text[]) from public, anon, authenticated;
grant execute on function public.recalcular_hierarquia(text, text[]) to service_role;
revoke execute on function public.gravar_tarefas(text, jsonb) from public, anon, authenticated;
grant execute on function public.gravar_tarefas(text, jsonb) to service_role;

-- refaz a hierarquia com a regra nova (banco inteiro)
select public.recalcular_hierarquia('clickup');
