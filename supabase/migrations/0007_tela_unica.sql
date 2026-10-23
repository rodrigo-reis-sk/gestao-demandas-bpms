-- =============================================================================
-- Gestão de Demandas BP-MS — tela única e padrão "sincronizar" (23/10/2026)
--
-- 1. Demanda nova de lista marcada já entra como SINCRONIZAR (D44): o gestor só desmarca exceções.
-- 2. Descoberta de listas: a FAP do cadastro liga à lista do ClickUp só pelo número (D43).
--    Caso real: "Guatos 32363 P2" (projeto) não ligava à FAP 32363 do cadastro (marcada como avulso).
-- 3. Lista "do cadastro" que já tem a lista real ligada a outra linha: some (evita duplicidade).
-- =============================================================================

alter table public.tarefas alter column selecao set default 'sincronizar';

-- Com o padrão "sincronizar", o representante de um grupo de atendimentos repetidos passa a ser
-- o que o gestor mexeu (selecao_por), e não mais "o que saiu de a_analisar".
create or replace function public.recalcular_hierarquia(p_origem text default 'clickup')
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_qtd int;
begin
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
  ),
  base as (
    select e.id, e.id_externo, e.estrutura, e.lista_id_externo, e.selecao, e.selecao_por, e.criada_na_origem,
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
  -- Representante do grupo: o que o GESTOR já mexeu (selecao_por); senão o mais antigo (não excluído primeiro).
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
               order by r.excluida_na_origem, (r.selecao_por is not null) desc,
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

create or replace function public.gravar_listas(p_listas jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  l          jsonb;
  v_f        clientes_faps%rowtype;
  v_cliente  uuid;
  v_ativa    boolean;
  v_admin    boolean;
  v_tipo     text;
  v_situacao text;
  v_obs      text;
  v_sugerida boolean;
  v_gerente  uuid;
  v_novas    int := 0;
  v_ligadas  int := 0;
  v_atual    int := 0;
  v_mapa     jsonb := coalesce((select valor from configuracoes where chave = 'gerentes_por_sigla'), '{}');
begin
  for l in select * from jsonb_array_elements(coalesce(p_listas, '[]'::jsonb)) loop
    v_ativa := coalesce((l->>'ativa')::boolean, true);
    v_admin := coalesce((l->>'administrativa')::boolean, false);
    v_tipo  := case when v_admin then 'interno' else coalesce(l->>'tipo', 'outro') end;
    v_cliente := null;
    if not v_admin then
      v_cliente := coalesce(public.cliente_por_nome(l->>'nome_cliente'), public.cliente_por_nome(l->>'pasta_nome'));
    end if;

    -- regra automática (só vale enquanto ninguém decidiu)
    v_situacao := case when v_admin or not v_ativa then 'nao_sincronizar' else 'a_analisar' end;
    v_obs := case when v_admin then 'Pasta administrativa: não sincronizar (automático)'
                  when not v_ativa then 'Encerrada na origem: não sincronizar (automático)' end;
    v_sugerida := v_situacao = 'a_analisar' and v_tipo = 'avulso' and v_cliente is not null;

    select * into v_f from clientes_faps where lista_id_externo = l->>'lista_id_externo';
    if v_f.id is null and l->>'fap' is not null then
      select * into v_f from clientes_faps
       -- FAP do cadastro: só o número precisa bater (o tipo do cadastro era um palpite: "Guatos 32363 P2"
       -- é projeto, mas o cadastro dizia avulso e a lista ficava sem ligar — D43)
       where lista_id_externo is null and fap = l->>'fap'
       order by (cliente_id = v_cliente) desc nulls last, (tipo = v_tipo) desc
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
             sigla_gerente = l->>'sigla_gerente',
             cliente_id = coalesce(cliente_id, v_cliente),
             -- ainda sem decisão do gestor: aplica a regra automática
             situacao_sincronizacao = case when analisada_em is null and situacao_sincronizacao = 'a_analisar'
                                           then v_situacao else situacao_sincronizacao end,
             observacao = case when analisada_em is null and situacao_sincronizacao = 'a_analisar' and v_obs is not null
                               then v_obs else observacao end,
             sugerida = v_sugerida or (sugerida and situacao_sincronizacao = 'a_analisar')
       where id = v_f.id;
    else
      insert into clientes_faps (cliente_id, fap, nome_lista, pasta_nome, lista_id_externo, pasta_id_externo,
                                 tipo, ativa, situacao_sincronizacao, observacao, sugerida, sigla_gerente)
      values (v_cliente, l->>'fap', l->>'nome_lista', l->>'pasta_nome', l->>'lista_id_externo', l->>'pasta_id_externo',
              v_tipo, v_ativa, v_situacao, v_obs, v_sugerida, l->>'sigla_gerente');
      if v_situacao = 'a_analisar' then v_novas := v_novas + 1; end if;
    end if;

    if v_cliente is not null then
      -- pasta no cadastro do cliente (ajuda a criar tarefas na fase 4)
      if l->>'pasta_id_externo' is not null then
        update clientes set pasta_id_externo = l->>'pasta_id_externo'
         where id = v_cliente and pasta_id_externo is null;
      end if;
      -- gerente de projetos pela sigla da pasta (D28); não sobrescreve o que o gestor definiu
      if l->>'sigla_gerente' is not null and v_mapa ? (l->>'sigla_gerente') then
        select id into v_gerente from consultores where lower(email) = lower(v_mapa->>(l->>'sigla_gerente'));
        if v_gerente is not null then
          update clientes set gerente_projetos_id = v_gerente where id = v_cliente and gerente_projetos_id is null;
        end if;
      end if;
    end if;
  end loop;
  return jsonb_build_object('novas_a_analisar', v_novas, 'ligadas_ao_cadastro', v_ligadas, 'conhecidas', v_atual);
end $$;

revoke execute on function public.gravar_listas(jsonb) from public, anon, authenticated;
grant execute on function public.gravar_listas(jsonb) to service_role;

-- FAP do cadastro sem lista, quando a mesma FAP já tem lista real: remove a linha de reserva.
delete from public.clientes_faps r
 where r.lista_id_externo is null
   and exists (select 1 from public.clientes_faps f where f.fap = r.fap and f.lista_id_externo is not null);

select public.recalcular_hierarquia('clickup');
