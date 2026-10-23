-- =============================================================================
-- Gestão de Demandas BP-MS — hierarquia robusta (23/10/2026), depois da 2ª comparação (Inovvati)
--
-- O que estava errado: os atendimentos repetidos do "1-Atendimento Base" continuavam um por dia.
-- Causas (todas tratadas aqui, para não depender de uma só):
--   a) a tarefa "1-Atendimento Base" não estava no banco (a sincronização antiga descartava
--      estruturas e a busca de tarefas-mãe só roda depois que as funções são publicadas);
--   b) linhas gravadas antes da marcação de estrutura ficavam com estrutura = false;
--   c) a junção só acontecia quando a mãe-estrutura já estava no banco.
-- Agora (D41):
--   • estrutura é reconhecida também no banco (status "atendimento base", nome "N-Atendimento (da)
--     Base", subtarefa do mês "AAAA-MM Mês"), além da marcação da tradução;
--   • folhas com o mesmo nome se juntam numa demanda: abaixo de estrutura → por lista + nome;
--     com a mãe ainda fora do banco → por mãe + nome (quando a mãe chegar, a regra se ajusta sozinha).
-- Visibilidade (D42): atendimento solto ou demanda fechada só aparecem com agenda a partir do corte.
-- =============================================================================

create or replace function public.recalcular_hierarquia(p_origem text default 'clickup')
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_qtd int;
begin
  with recursive
  -- estrutura: marcada pela tradução OU reconhecida aqui (linhas antigas, gravadas antes da marcação)
  est as (
    select t.id, t.id_externo, t.origem, t.tarefa_pai_id_externo, t.lista_id_externo, t.selecao,
           t.criada_na_origem, t.excluida_na_origem, public.normalizar_texto(t.nome) as nome_norm,
           (t.estrutura
            or public.normalizar_texto(t.status) = 'atendimento base'
            or public.normalizar_texto(t.nome) ~ '^[0-9]+ atendimento (da )?base$'
            or t.nome ~ '^\s*\d{4}-\d{2}\s+\S+\s*$') as estrutura
      from tarefas t
     where t.origem = p_origem
  ),
  base as (
    select e.id, e.id_externo, e.estrutura, e.lista_id_externo, e.selecao, e.criada_na_origem,
           e.excluida_na_origem, e.nome_norm, e.tarefa_pai_id_externo,
           p.id as pai_id, coalesce(p.estrutura, false) as pai_estrutura
      from est e
      left join est p on p.id_externo = e.tarefa_pai_id_externo
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
  -- Representante do grupo: o que o gestor já escolheu; senão o mais antigo (não excluído primeiro).
  -- Junção de folhas com o mesmo nome (D38/D41):
  --   • logo abaixo de uma estrutura → mesma lista + mesmo nome = uma demanda;
  --   • mãe ainda não está no banco → mesma mãe + mesmo nome = uma demanda (até a mãe chegar).
  raiz_final as (
    select r.id,
           case when r.folha and (r.pai_estrutura or (r.pai_id is null and r.tarefa_pai_id_externo is not null)) then
             first_value(r.id) over (
               partition by r.lista_id_externo, r.nome_norm,
                            case when r.pai_estrutura then '' else coalesce(r.tarefa_pai_id_externo, r.id_externo) end,
                            (r.folha and (r.pai_estrutura or (r.pai_id is null and r.tarefa_pai_id_externo is not null)))
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
   -- Visibilidade (D42): aparece se tem agenda a partir do corte; sem nenhuma agenda no período,
   -- só aparece se for uma demanda ABERTA com subtarefas (projeto em curso). Demanda fechada, ou
   -- atendimento solto (a própria agenda), com data antes do corte some — mesmo que o status tenha
   -- sido mexido em 2026.
   and (h.ultima_agenda >= public.data_corte()
        or (h.ultima_agenda is null and h.qtd_agendas > 0)                       -- agendas ainda sem data
        or (coalesce(d.status_tipo, '') not in ('closed', 'done') and not d.eh_folha));

-- refaz a hierarquia com a regra nova
select public.recalcular_hierarquia('clickup');
