-- =============================================================================
-- Gestão de Demandas BP-MS — ajustes depois da 1ª sincronização real (23/10/2026)
--
-- 1. Listas: tipo "interno" (pastas administrativas), sugestão de sincronizar para listas
--    Avulso de cliente ativo (D27), gerente de projetos do cliente pela sigla da pasta (D28).
-- 2. Regras automáticas na descoberta: pasta administrativa e lista/pasta encerrada entram
--    (e, se ninguém decidiu ainda, passam) para "nao_sincronizar".
-- 3. Limpeza: tarefas-estrutura ("1-Atendimento da Base" e subtarefa do mês) que entraram
--    no repositório viram "ignorada".
-- =============================================================================

-- ---------------- 1. Estrutura ----------------
alter table public.clientes_faps drop constraint if exists clientes_faps_tipo_check;
alter table public.clientes_faps add constraint clientes_faps_tipo_check
  check (tipo in ('avulso', 'projeto', 'interno', 'outro'));

-- Sugestão do sistema para listas ainda "a_analisar" (o gestor confirma em lote).
alter table public.clientes_faps add column if not exists sugerida boolean not null default false;
-- Sigla do gerente de projetos tirada do nome da pasta ("GERMIPASTO - FC" → FC).
alter table public.clientes_faps add column if not exists sigla_gerente text;

-- Gerente de projetos responsável pelo cliente (consultor com papel gerente_projetos).
alter table public.clientes add column if not exists gerente_projetos_id uuid references public.consultores(id);

-- De-para sigla → gerente (e-mail do cadastro de consultores). Editável em configuracoes.
insert into public.configuracoes (chave, valor, descricao) values
  ('gerentes_por_sigla', '{"FC": "filipe.capulo@sankhya.com.br", "ED": "elson.duarte@sankhya.com.br"}',
   'Sigla no fim do nome da pasta do cliente → e-mail do gerente de projetos')
on conflict (chave) do nothing;

-- Quem decidiu a lista: só registra quando é uma pessoa (a regra automática não conta como decisão).
create or replace function public.registrar_analise_lista()
returns trigger language plpgsql as $$
begin
  if new.situacao_sincronizacao is distinct from old.situacao_sincronizacao and auth.uid() is not null then
    new.analisada_por := auth.uid();
    new.analisada_em  := now();
  end if;
  return new;
end $$;

-- ---------------- 2. Descoberta de listas (substitui a versão da 0002) ----------------
-- p_listas: [{lista_id_externo, nome_lista, pasta_id_externo, pasta_nome, fap, tipo, ativa,
--             administrativa, nome_cliente, sigla_gerente}]
-- Regras para lista NOVA:
--   • pasta administrativa → tipo "interno", "nao_sincronizar";
--   • encerrada (Z / Concluída) → "nao_sincronizar";
--   • senão "a_analisar"; se for Avulso, ativa e com cliente identificado → sugerida (D27).
-- Lista JÁ CONHECIDA que ainda está "a_analisar" e nunca foi decidida por ninguém segue as
-- mesmas regras (assim a correção vale para o que já tinha sido descoberto).
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

-- O contador do menu passa a mostrar também quantas estão sugeridas.
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
  -- coluna nova vai no fim (o Postgres não deixa reordenar colunas de view)
  (select count(*) from public.clientes_faps where situacao_sincronizacao = 'a_analisar' and sugerida) as listas_sugeridas;

-- ---------------- 3. Limpeza das tarefas-estrutura que entraram ----------------
-- "1-Atendimento da Base" / "1-Atendimento Base" (status "atendimento base") e a subtarefa
-- do mês ("2026-10 Outubro") não são atendimentos: saem do repositório.
with estrutura as (
  select id from public.tarefas
   where origem = 'clickup'
     and (lower(coalesce(status, '')) = 'atendimento base'
          or public.normalizar_texto(nome) ~ '^[0-9]+ atendimento (da )?base$'
          or nome ~ '^\s*\d{4}-\d{2}\s+\S+\s*$')
)
update public.tarefas t
   set situacao = 'ignorada',
       demanda_id = case when t.agrupada_por = 'automatico' then null else t.demanda_id end,
       agrupada_por = case when t.agrupada_por = 'automatico' then null else t.agrupada_por end
  from estrutura e
 where t.id = e.id and (t.situacao = 'pendente' or t.agrupada_por = 'automatico');

delete from public.sugestoes_agrupamento s
 using public.tarefas t
 where s.tarefa_id = t.id and t.situacao = 'ignorada' and s.status = 'pendente';
