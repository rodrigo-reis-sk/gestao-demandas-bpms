-- =============================================================================
-- 0011 — Fase 4: criar a tarefa na origem a partir da triagem (D65–D70)
-- =============================================================================
-- O botão "Aprovar e criar" da Triagem chama a Edge Function de criação, que usa o token do
-- gestor que clicou (D11/D19). Esta migração dá ao banco o que a função precisa:
--   1. Colunas da criação no chamado (situação, mensagem, quem pediu, lista escolhida) e marca
--      de print enviado em cada anexo (para "Reenviar prints" sem duplicar).
--   2. reservar_criacao_tarefa: confere tudo, aprova e TRAVA o chamado (clique duplo não cria duas tarefas).
--   3. registrar_criacao_tarefa / marcar_anexo_enviado: a função conta o que aconteceu.
--   4. Gatilho de ligação: além do código CH- no nome (D61), liga também pelo id da tarefa criada.
--   5. vw_chamados com a situação da criação e a lista sugerida (id).
-- O modo manual continua (D66): "Aprovar, crio à mão" segue usando triar_chamado('aprovar').
-- =============================================================================

-- ---------------- 1. Colunas ----------------
alter table public.chamados add column if not exists criacao_situacao    text
  check (criacao_situacao in ('criando', 'criada', 'erro'));
alter table public.chamados add column if not exists criacao_mensagem    text;          -- erro ou avisos da última tentativa
alter table public.chamados add column if not exists criacao_url         text;          -- link da tarefa criada
alter table public.chamados add column if not exists criacao_lista_id    uuid references public.clientes_faps(id);
alter table public.chamados add column if not exists criacao_por         uuid references auth.users(id);
alter table public.chamados add column if not exists criacao_iniciada_em timestamptz;
alter table public.chamados add column if not exists criacao_concluida_em timestamptz;

comment on column public.chamados.criacao_situacao is
  'Criação automática na origem (D65): criando (trava de 3 min) → criada | erro. Nulo = nunca tentou (modo manual).';

alter table public.chamados_anexos add column if not exists enviado_na_origem_em timestamptz;
comment on column public.chamados_anexos.enviado_na_origem_em is 'Print já anexado à tarefa criada na origem (D68).';

-- ---------------- 2. Dados para a criação ----------------
-- Tudo o que a Edge Function precisa para montar a tarefa, num JSON só. Uso interno (chave de serviço).
create or replace function public.dados_criacao_tarefa(p_chamado uuid)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', ch.id, 'codigo', ch.codigo, 'canal', ch.canal, 'titulo', ch.titulo, 'descricao', ch.descricao,
    'tipo', ch.tipo, 'prioridade', ch.prioridade, 'origem_solicitacao', ch.origem_solicitacao,
    'cliente', c.nome, 'parceiro_id_externo', c.parceiro_id_externo,
    'contato_nome', coalesce(ch.contato_nome, ch.solicitante_nome), 'contato_info', coalesce(ch.contato_info, ch.solicitante_email),
    'chamado_sankhya_aberto', ch.chamado_sankhya_aberto, 'ticket_sankhya', ch.ticket_sankhya, 'retorno_sankhya', ch.retorno_sankhya,
    'gerente', g.nome, 'criado_em', ch.criado_em,
    'tarefa_criada_id_externo', ch.tarefa_criada_id_externo,
    'lista', (select jsonb_build_object('id', f.id, 'id_externo', f.lista_id_externo, 'nome', f.nome_lista)
                from clientes_faps f where f.id = ch.criacao_lista_id),
    'desenvolvedor', (select jsonb_build_object('id', p.id, 'nome', p.nome, 'id_externo', p.id_externo) from consultores p where p.id = ch.desenvolvedor_id),
    'consultor', (select jsonb_build_object('id', p.id, 'nome', p.nome, 'id_externo', p.id_externo) from consultores p where p.id = ch.consultor_id),
    'pedido_por', (select u.nome from usuarios_sistema u where u.id = ch.criacao_por),
    'evidencias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ordem', e.ordem, 'texto', e.texto, 'etapa', e.etapa,
               'anexos', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', a.id, 'ordem', a.ordem, 'caminho', a.caminho_storage, 'tipo', a.tipo_arquivo,
                             'enviado', a.enviado_na_origem_em is not null) order by a.ordem)
                           from chamados_anexos a where a.evidencia_id = e.id), '[]'::jsonb)) order by e.ordem)
        from chamados_evidencias e where e.chamado_id = ch.id), '[]'::jsonb))
  from chamados ch
  left join clientes c on c.id = ch.cliente_id
  left join consultores g on g.id = ch.gerente_projetos_id
  where ch.id = p_chamado
$$;

-- Confere, aprova e trava o chamado para a criação. Chamada pela Edge Function com o id de quem clicou.
-- Erros com frase de negócio (a tela mostra como veio).
create or replace function public.reservar_criacao_tarefa(
  p_chamado uuid, p_usuario uuid, p_lista uuid, p_desenvolvedor uuid, p_consultor uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ch    chamados%rowtype;
  v_lista clientes_faps%rowtype;
  v_dev   consultores%rowtype;
  v_cons  consultores%rowtype;
begin
  if not exists (select 1 from usuarios_sistema where id = p_usuario and ativo and papel in ('admin', 'gestor')) then
    raise exception 'Só gestores criam tarefas.'; end if;

  select * into v_ch from chamados where id = p_chamado for update;
  if v_ch.id is null then raise exception 'Chamado não encontrado.'; end if;
  if v_ch.tarefa_id is not null or v_ch.tarefa_criada_id_externo is not null then
    raise exception 'Este chamado já tem tarefa criada.'; end if;
  if v_ch.status = 'recusado' then raise exception 'Chamado recusado: volte para novo antes de aprovar.'; end if;
  if v_ch.status not in ('novo', 'aguardando_informacao', 'aprovado', 'em_triagem') then
    raise exception 'Este chamado não está aberto para aprovação.'; end if;
  if v_ch.criacao_situacao = 'criando' and v_ch.criacao_iniciada_em > now() - interval '3 minutes' then
    raise exception 'Já existe uma criação em andamento para este chamado. Aguarde e atualize a tela.'; end if;
  if v_ch.cliente_id is null then
    raise exception 'Cliente digitado fora da lista: crie a tarefa à mão ("Aprovar, crio à mão").'; end if;

  select * into v_lista from clientes_faps where id = p_lista;
  if v_lista.id is null or v_lista.cliente_id is distinct from v_ch.cliente_id then
    raise exception 'Escolha uma lista do cliente.'; end if;
  if not v_lista.ativa then raise exception 'A lista % está encerrada.', v_lista.nome_lista; end if;
  if v_lista.situacao_sincronizacao <> 'sincronizar' then
    raise exception 'A lista % não está marcada para sincronizar: a tarefa não voltaria para o sistema. Marque a lista em Demandas.',
      v_lista.nome_lista; end if;

  select * into v_dev from consultores where id = coalesce(p_desenvolvedor, v_ch.desenvolvedor_id) and ativo;
  if v_dev.id is null then raise exception 'Escolha o desenvolvedor antes de aprovar.'; end if;
  if v_dev.id_externo is null then
    raise exception '% ainda não tem usuário ligado na origem (rode a sincronização ou confira o e-mail no cadastro).', v_dev.nome; end if;
  if p_consultor is not null then
    select * into v_cons from consultores where id = p_consultor and ativo;
    if v_cons.id is null then raise exception 'Consultor não encontrado.'; end if;
    if v_cons.id_externo is null then
      raise exception '% ainda não tem usuário ligado na origem (rode a sincronização ou confira o e-mail no cadastro).', v_cons.nome; end if;
  end if;

  update chamados set
    desenvolvedor_id = v_dev.id, desenvolvedor_indicado = v_dev.nome,
    consultor_id = p_consultor,
    status = 'aprovado', token_complemento = null,
    triado_por = p_usuario, triado_em = now(),
    criacao_situacao = 'criando', criacao_mensagem = null, criacao_lista_id = v_lista.id,
    criacao_por = p_usuario, criacao_iniciada_em = now(), criacao_concluida_em = null
  where id = p_chamado;

  return public.dados_criacao_tarefa(p_chamado);
end $$;

-- ---------------- 3. Resultado ----------------
-- p_situacao: 'criada' (com ou sem avisos em p_mensagem) | 'erro' (p_mensagem = o que deu errado).
-- O id da tarefa, depois de gravado, nunca é apagado (evita criar duas vezes).
create or replace function public.registrar_criacao_tarefa(
  p_chamado uuid, p_situacao text, p_id_externo text default null, p_url text default null, p_mensagem text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_situacao not in ('criada', 'erro') then raise exception 'Situação inválida: %', p_situacao; end if;
  update chamados set
    criacao_situacao = p_situacao,
    criacao_mensagem = public.texto_limpo(p_mensagem, 2000),
    tarefa_criada_id_externo = coalesce(tarefa_criada_id_externo, p_id_externo),
    criacao_url = coalesce(p_url, criacao_url),
    criacao_concluida_em = now()
  where id = p_chamado;
end $$;

-- Print anexado à tarefa: não é enviado de novo no "Reenviar prints".
create or replace function public.marcar_anexo_enviado(p_anexo uuid)
returns void language sql security definer set search_path = public, extensions as $$
  update chamados_anexos set enviado_na_origem_em = now() where id = p_anexo
$$;

-- ---------------- 4. Ligação tarefa ↔ chamado ----------------
-- D61 continua (código CH- no nome) e ganha a ligação pelo id da tarefa criada pelo sistema (D65):
-- se alguém renomear a tarefa antes de ela chegar, ela liga do mesmo jeito.
create or replace function public.ligar_tarefa_ao_chamado()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_codigo text;
begin
  if new.excluida_na_origem then return new; end if;
  v_codigo := upper(substring(new.nome from '(?i)\mCH-?\s?(\d{5,})\M'));
  update chamados set
         tarefa_id = new.id, tarefa_criada_id_externo = new.id_externo, tarefa_ligada_em = now(),
         status = 'tarefa_criada', token_complemento = null
   where tarefa_id is null
     and status not in ('recusado', 'concluido')
     and ((v_codigo is not null and codigo = 'CH-' || v_codigo)
          or (new.id_externo is not null and tarefa_criada_id_externo = new.id_externo));
  return new;
end $$;

-- ---------------- 5. View da triagem ----------------
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
       (select f.nome_lista from clientes_faps f
         where f.cliente_id = ch.cliente_id and f.situacao_sincronizacao = 'sincronizar'
         order by (f.tipo = 'avulso') desc, f.ativa desc, f.descoberta_em desc limit 1) as lista_sugerida,
       (select count(*) from chamados_evidencias e where e.chamado_id = ch.id) as passos,
       (select count(*) from chamados_evidencias e join chamados_anexos a on a.evidencia_id = e.id
         where e.chamado_id = ch.id) as anexos,
       ch.criado_em, ch.atualizado_em,
       ch.solicitante_nome, ch.solicitante_email, ch.link_portal_id,
       public.situacao_para_cliente(ch.status, ch.canal, t.status, t.status_tipo) as situacao_cliente,
       exists (select 1 from links_portal l where l.cliente_id = ch.cliente_id and l.ativo
                 and (l.expira_em is null or l.expira_em > now())) as cliente_tem_portal,
       -- novas na 0011 (no fim, para o "create or replace" aceitar)
       (select f.id from clientes_faps f
         where f.cliente_id = ch.cliente_id and f.situacao_sincronizacao = 'sincronizar' and f.ativa
         order by (f.tipo = 'avulso') desc, f.descoberta_em desc limit 1) as lista_sugerida_id,
       ch.criacao_situacao, ch.criacao_mensagem, ch.criacao_url, ch.criacao_iniciada_em, ch.criacao_concluida_em,
       cl.nome_lista as criacao_lista_nome, cp.nome as criacao_por_nome,
       (select count(*) from chamados_evidencias e join chamados_anexos a on a.evidencia_id = e.id
         where e.chamado_id = ch.id and a.enviado_na_origem_em is null) as anexos_pendentes
from public.chamados ch
left join public.clientes c     on c.id = ch.cliente_id
left join public.consultores g  on g.id = ch.gerente_projetos_id
left join public.consultores co on co.id = ch.consultor_id
left join public.consultores d  on d.id = ch.desenvolvedor_id
left join public.usuarios_sistema u on u.id = ch.triado_por
left join public.tarefas t      on t.id = ch.tarefa_id
left join public.clientes_faps cl on cl.id = ch.criacao_lista_id
left join public.usuarios_sistema cp on cp.id = ch.criacao_por;

-- ---------------- Permissões ----------------
do $$
declare f text;
begin
  -- só a chave de serviço (Edge Function de criação)
  foreach f in array array[
    'public.dados_criacao_tarefa(uuid)', 'public.reservar_criacao_tarefa(uuid, uuid, uuid, uuid, uuid)',
    'public.registrar_criacao_tarefa(uuid, text, text, text, text)', 'public.marcar_anexo_enviado(uuid)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on public.vw_chamados to authenticated;
