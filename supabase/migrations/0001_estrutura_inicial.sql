-- =============================================================================
-- Gestão de Demandas BP-MS — estrutura inicial do banco (rascunho v1)
-- Banco: Supabase (Postgres 15+). Executar no SQL Editor do Supabase.
-- Documentação: docs/03-modelo-de-dados.md
--
-- Convenções: nomes em português, snake_case, sem acento.
-- NENHUMA tabela, coluna, view ou função leva nome de ferramenta externa (ClickUp etc.).
--   A ferramenta aparece só como valor: origem = 'clickup' / sistema = 'clickup'.
--   Dados vindos de fora usam o sufixo "_externo" (id_externo, nome_externo...).
--   Assim, se um dia sairmos do ClickUp, as mesmas tabelas recebem origem = 'interno'.
-- Datas sempre timestamptz (UTC no banco; a tela mostra em America/Cuiaba ou Campo_Grande).
-- Minutos como inteiro (evita arredondamento de horas).
-- =============================================================================

-- No Supabase as extensões ficam no schema "extensions" (já existe em todo projeto).
create schema if not exists extensions;
create extension if not exists pg_trgm  with schema extensions;   -- comparação de textos parecidos
create extension if not exists unaccent with schema extensions;   -- remover acentos na comparação

-- -----------------------------------------------------------------------------
-- Funções utilitárias
-- -----------------------------------------------------------------------------

-- unaccent() não é "immutable"; esta versão pode ser usada em colunas geradas e índices.
create or replace function public.normalizar_texto(t text)
returns text language sql immutable parallel safe as $$
  select trim(regexp_replace(lower(extensions.unaccent('extensions.unaccent', coalesce(t, ''))), '[^a-z0-9]+', ' ', 'g'))
$$;

-- Atualiza a coluna atualizado_em em todo UPDATE.
create or replace function public.tocar_atualizado_em()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

-- =============================================================================
-- 1. Cadastros
-- =============================================================================

-- Usuários que entram na tela de gestão (ligados ao Supabase Auth).
-- O e-mail de acesso deve ser o MESMO e-mail usado na ferramenta externa (ClickUp).
create table public.usuarios_sistema (
  id            uuid primary key references auth.users(id) on delete cascade,
  nome          text not null,
  email         text not null unique,
  papel         text not null default 'gestor' check (papel in ('admin', 'gestor', 'consultor')),
  consultor_id  uuid,                        -- preenchido quando papel = consultor
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

-- Conexão de cada gestor com a ferramenta externa (P5).
-- O token NÃO fica aqui: fica criptografado no Supabase Vault; guardamos só o id do segredo.
-- Quem grava é a Edge Function de conexão (OAuth), nunca o navegador.
create table public.contas_integracao (
  id                    uuid primary key default gen_random_uuid(),
  usuario_id            uuid not null references public.usuarios_sistema(id) on delete cascade,
  sistema               text not null default 'clickup',
  email_externo         text not null,       -- tem de ser igual ao e-mail de acesso (gatilho abaixo)
  usuario_id_externo    text,                -- id do usuário na ferramenta externa
  nome_externo          text,
  tipo_autenticacao     text not null default 'oauth' check (tipo_autenticacao in ('oauth', 'token_pessoal')),
  segredo_id            uuid,                -- id do segredo no Supabase Vault
  usar_na_sincronizacao boolean not null default false,  -- conta usada pela varredura agendada
  situacao              text not null default 'ativa' check (situacao in ('ativa', 'revogada', 'erro')),
  ultimo_erro           text,
  conectada_em          timestamptz not null default now(),
  ultimo_uso_em         timestamptz,
  unique (usuario_id, sistema)
);
-- Só uma conta ativa por sistema pode ser a "conta da sincronização".
create unique index uq_contas_integracao_sincronizacao on public.contas_integracao (sistema)
  where usar_na_sincronizacao and situacao = 'ativa';

-- Garante que a conta conectada é da mesma pessoa que fez login (mesmo e-mail).
create or replace function public.validar_email_conta_integracao()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from usuarios_sistema u
                 where u.id = new.usuario_id and lower(u.email) = lower(new.email_externo)) then
    raise exception 'O e-mail da conta % (%) é diferente do e-mail de acesso ao sistema.',
      new.sistema, new.email_externo;
  end if;
  return new;
end $$;
create trigger trg_contas_integracao_email before insert or update of email_externo, usuario_id
  on public.contas_integracao for each row execute function public.validar_email_conta_integracao();

-- Consultores / desenvolvedores. "sincronizar" escolhe quem é buscado na origem (R1.1).
create table public.consultores (
  id                uuid primary key default gen_random_uuid(),
  nome              text not null,
  email             text unique,
  id_externo        text unique,             -- id do usuário na ferramenta externa
  nome_externo      text,                    -- nome como aparece lá (pode divergir)
  papel             text not null default 'consultor'
                    check (papel in ('consultor', 'desenvolvedor', 'gerente_projetos')),
  sincronizar       boolean not null default false,
  ativo             boolean not null default true,
  cor               text,                    -- cor do avatar no card (#RRGGBB)
  observacao        text,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now()
);
create trigger trg_consultores_atualizado before update on public.consultores
  for each row execute function public.tocar_atualizado_em();

alter table public.usuarios_sistema
  add constraint usuarios_sistema_consultor_fk foreign key (consultor_id) references public.consultores(id);

-- Clientes = "parceiros" (no ClickUp: uma pasta por parceiro no espaço PMO BP-MS).
create table public.clientes (
  id                   uuid primary key default gen_random_uuid(),
  nome                 text not null unique,     -- nome curto, igual ao dropdown "Parceiro"
  razao_social         text,
  parceiro_id_externo  text,                     -- opção do dropdown Parceiro na origem
  pasta_id_externo     text,                     -- pasta do cliente na origem
  cor                  text,                     -- etiqueta do card
  ativo                boolean not null default true,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
create trigger trg_clientes_atualizado before update on public.clientes
  for each row execute function public.tocar_atualizado_em();

-- FAPs / listas de trabalho de cada cliente (no ClickUp: as listas do espaço).
-- A sincronização descobre TODAS as listas; cada uma entra como "a_analisar" e só
-- tem tarefas buscadas depois que o gestor marca "sincronizar" (P7).
create table public.clientes_faps (
  id                      uuid primary key default gen_random_uuid(),
  cliente_id              uuid references public.clientes(id) on delete cascade,  -- nulo = cliente não identificado
  fap                     text,                  -- número da FAP (ex.: 32221); nulo se a lista não tiver
  nome_lista              text,
  pasta_nome              text,
  lista_id_externo        text unique,
  pasta_id_externo        text,
  tipo                    text not null default 'avulso' check (tipo in ('avulso', 'projeto', 'outro')),
  ativa                   boolean not null default true,   -- false = lista/pasta com "Z" ou "Concluída"
  situacao_sincronizacao  text not null default 'a_analisar'
                          check (situacao_sincronizacao in ('a_analisar', 'sincronizar', 'nao_sincronizar')),
  analisada_por           uuid references auth.users(id),
  analisada_em            timestamptz,
  observacao              text,
  descoberta_em           timestamptz not null default now(),
  atualizado_em           timestamptz not null default now()
);
create index idx_faps_cliente on public.clientes_faps (cliente_id, fap);
create index idx_faps_a_analisar on public.clientes_faps (descoberta_em) where situacao_sincronizacao = 'a_analisar';
create trigger trg_faps_atualizado before update on public.clientes_faps
  for each row execute function public.tocar_atualizado_em();

-- Registra quem analisou a lista quando a situação muda.
create or replace function public.registrar_analise_lista()
returns trigger language plpgsql as $$
begin
  if new.situacao_sincronizacao is distinct from old.situacao_sincronizacao then
    new.analisada_por := auth.uid();
    new.analisada_em  := now();
  end if;
  return new;
end $$;
create trigger trg_faps_analise before update of situacao_sincronizacao on public.clientes_faps
  for each row execute function public.registrar_analise_lista();

-- De-para: quem é a pessoa real por trás de uma conta compartilhada ("BPMS") em cada FAP.
-- A conta compartilhada NÃO é cadastrada como consultor: fica só aqui, pelo nome na origem.
-- Ex.: tarefa da FAP 32222 com responsável "BPMS" → horas e card vão para o Cleber Nascimento.
-- A troca é feita pelo gatilho resolver_responsavel_real() (seção 3).
create table public.responsavel_real_por_fap (
  id                  uuid primary key default gen_random_uuid(),
  nome_externo        text not null,             -- nome da conta compartilhada na origem (ex.: BPMS)
  usuario_id_externo  text,                      -- preenchido sozinho na 1ª sincronização
  fap                 text not null,
  consultor_id        uuid not null references public.consultores(id),
  observacao          text,
  unique (nome_externo, fap)
);

-- Parâmetros gerais (janela de agrupamento, limiares, intervalo de sincronização...).
create table public.configuracoes (
  chave          text primary key,
  valor          jsonb not null,
  descricao      text,
  atualizado_em  timestamptz not null default now()
);

-- =============================================================================
-- 2. Kanban e demandas
-- =============================================================================

create table public.kanban_colunas (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  ordem        int  not null,
  cor          text,
  limite_cards int,                                 -- limite de trabalho em andamento (opcional)
  tipo         text not null default 'andamento'
               check (tipo in ('entrada', 'andamento', 'espera', 'concluida', 'cancelada')),
  ativa        boolean not null default true,
  criado_em    timestamptz not null default now()
);

create sequence public.seq_demanda_codigo start 1;

create table public.demandas (
  id                       uuid primary key default gen_random_uuid(),
  codigo                   text not null unique
                           default 'DEM-' || lpad(nextval('public.seq_demanda_codigo')::text, 4, '0'),
  titulo                   text not null,
  descricao                text,
  cliente_id               uuid references public.clientes(id),
  fap_id                   uuid references public.clientes_faps(id),
  consultor_responsavel_id uuid references public.consultores(id),
  coluna_id                uuid references public.kanban_colunas(id),
  ordem_na_coluna          numeric not null default 0,   -- numeric permite inserir entre dois cards
  tipo                     text,                         -- Personalização, Ajuste, Relatório...
  prioridade               text not null default 'media'
                           check (prioridade in ('baixa', 'media', 'alta', 'urgente')),
  origem_solicitacao       text,                         -- Whatsapp, E-mail, PMO, Service Desk...
  ticket_sankhya           text,
  minutos_estimados        int check (minutos_estimados >= 0),
  data_prevista            date,
  chamado_id               uuid,                         -- FK criada depois de chamados
  criado_por               uuid references auth.users(id),
  criado_em                timestamptz not null default now(),
  atualizado_em            timestamptz not null default now(),
  encerrado_em             timestamptz
);
create index idx_demandas_coluna on public.demandas (coluna_id, ordem_na_coluna);
create index idx_demandas_cliente on public.demandas (cliente_id);
create index idx_demandas_consultor on public.demandas (consultor_responsavel_id);
create index idx_demandas_titulo_trgm on public.demandas using gin (public.normalizar_texto(titulo) extensions.gin_trgm_ops);
create trigger trg_demandas_atualizado before update on public.demandas
  for each row execute function public.tocar_atualizado_em();

-- Histórico de movimentação no kanban (quem moveu, de onde, para onde).
create table public.demandas_historico (
  id            bigint generated always as identity primary key,
  demanda_id    uuid not null references public.demandas(id) on delete cascade,
  evento        text not null,          -- movida, criada, agrupou_tarefa, desagrupou_tarefa, editada
  de_coluna_id  uuid references public.kanban_colunas(id),
  para_coluna_id uuid references public.kanban_colunas(id),
  detalhes      jsonb,
  usuario_id    uuid references auth.users(id),
  criado_em     timestamptz not null default now()
);
create index idx_demandas_historico on public.demandas_historico (demanda_id, criado_em);

create or replace function public.registrar_movimento_demanda()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'INSERT' then
    insert into demandas_historico (demanda_id, evento, para_coluna_id, usuario_id)
    values (new.id, 'criada', new.coluna_id, auth.uid());
  elsif new.coluna_id is distinct from old.coluna_id then
    insert into demandas_historico (demanda_id, evento, de_coluna_id, para_coluna_id, usuario_id)
    values (new.id, 'movida', old.coluna_id, new.coluna_id, auth.uid());
  end if;
  return new;
end $$;
create trigger trg_demandas_historico after insert or update of coluna_id on public.demandas
  for each row execute function public.registrar_movimento_demanda();

-- Horas informadas pelo gestor (R4.2).
create table public.apontamentos_manuais (
  id            uuid primary key default gen_random_uuid(),
  demanda_id    uuid not null references public.demandas(id) on delete cascade,
  consultor_id  uuid not null references public.consultores(id),
  data          date not null,
  minutos       int  not null check (minutos > 0 and minutos <= 24 * 60),
  observacao    text,
  criado_por    uuid references auth.users(id),
  criado_em     timestamptz not null default now()
);
create index idx_apontamentos_demanda on public.apontamentos_manuais (demanda_id);

-- =============================================================================
-- 3. Tarefas e tempo registrado (repositório)
-- Hoje vêm do ClickUp (origem = 'clickup'). No futuro, podem nascer no próprio sistema
-- (origem = 'interno') sem mudar a estrutura.
-- =============================================================================

create table public.tarefas (
  id                     uuid primary key default gen_random_uuid(),
  origem                 text not null default 'clickup' check (origem in ('clickup', 'interno')),
  id_externo             text,                 -- id da tarefa na origem
  codigo_externo         text,                 -- código personalizado na origem (custom_id)
  nome                   text not null,
  nome_normalizado       text generated always as (public.normalizar_texto(nome)) stored,
  detalhamento           text,                 -- campo "Detalhamento" ou descrição
  status                 text,
  status_tipo            text,                 -- open / custom / closed / done
  url                    text,
  lista_id_externo       text,
  lista_nome             text,
  pasta_id_externo       text,
  pasta_nome             text,
  tarefa_pai_id_externo  text,                 -- subtarefa do mês, por exemplo
  fap_id                 uuid references public.clientes_faps(id),
  cliente_id             uuid references public.clientes(id),
  fap                    text,                 -- extraída do nome da lista
  usuario_cliente        text,                 -- campo "Usuário cliente"
  origem_solicitacao     text,                 -- campo "Origem" (Whatsapp, E-mail, PMO...)
  periodo                text,                 -- campo "Período" (ex.: 08h-10h)
  minutos_periodo        int,                  -- duração calculada a partir do Período
  data_inicio            timestamptz,
  data_vencimento        timestamptz,
  criada_na_origem       timestamptz,
  atualizada_na_origem   timestamptz,
  fechada_na_origem      timestamptz,
  minutos_registrados    int not null default 0,   -- tempo total da tarefa na origem (time_spent)
  minutos_estimados      int,                      -- time_estimate
  campos_personalizados  jsonb,                    -- só id/nome/valor dos campos
  -- Autoria (P5)
  criada_por_id_externo  text,                     -- quem criou na origem
  criada_por_nome        text,
  criada_por_usuario_id  uuid references auth.users(id),  -- quando foi criada pelo sistema
  -- Repositório
  demanda_id             uuid references public.demandas(id) on delete set null,
  situacao               text not null default 'pendente'
                         check (situacao in ('pendente', 'agrupada', 'ignorada')),
  agrupada_por           text check (agrupada_por in ('manual', 'automatico', 'criada_pelo_sistema')),
  agrupada_em            timestamptz,
  excluida_na_origem     boolean not null default false,
  ultima_sincronizacao   timestamptz not null default now(),
  dados_origem           jsonb,                    -- resposta da API (para depuração)
  criado_em              timestamptz not null default now(),
  unique (origem, id_externo)
);
create index idx_tarefas_situacao on public.tarefas (situacao) where not excluida_na_origem;
create index idx_tarefas_demanda on public.tarefas (demanda_id);
create index idx_tarefas_cliente on public.tarefas (cliente_id, criada_na_origem);
create index idx_tarefas_nome_trgm on public.tarefas using gin (nome_normalizado extensions.gin_trgm_ops);

-- Responsáveis da tarefa. Uma tarefa pode ter mais de um.
create table public.tarefas_responsaveis (
  id                  bigint generated always as identity primary key,
  tarefa_id           uuid not null references public.tarefas(id) on delete cascade,
  usuario_id_externo  text,                 -- id do responsável na origem
  nome_externo        text,
  consultor_id        uuid references public.consultores(id),
  check (usuario_id_externo is not null or consultor_id is not null),
  unique (tarefa_id, usuario_id_externo)
);
create index idx_resp_consultor on public.tarefas_responsaveis (consultor_id);

-- Registros de tempo (no ClickUp: time entries).
create table public.registros_tempo (
  id                   uuid primary key default gen_random_uuid(),
  origem               text not null default 'clickup' check (origem in ('clickup', 'interno')),
  id_externo           text,
  tarefa_id            uuid references public.tarefas(id) on delete cascade,
  usuario_id_externo   text,
  consultor_id         uuid references public.consultores(id),
  inicio               timestamptz not null,
  fim                  timestamptz,
  minutos              int not null check (minutos >= 0),
  descricao            text,
  faturavel            boolean,
  excluido_na_origem   boolean not null default false,
  ultima_sincronizacao timestamptz not null default now(),
  unique (origem, id_externo)
);
create index idx_tempo_tarefa on public.registros_tempo (tarefa_id);
create index idx_tempo_consultor on public.registros_tempo (consultor_id, inicio);

-- Conta compartilhada ("BPMS"): troca pelo consultor real conforme a FAP da tarefa.
-- Vale para responsáveis e para registros de tempo. Sem de-para para a FAP, o consultor
-- fica vazio e a pendência aparece em vw_pendencias_gestor.responsaveis_sem_pessoa.
create or replace function public.resolver_responsavel_real()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_fap   text;
  v_nome  text;
  v_dp    responsavel_real_por_fap%rowtype;
begin
  if new.consultor_id is not null then
    return new;
  end if;
  select fap into v_fap from tarefas where id = new.tarefa_id;
  if tg_table_name = 'tarefas_responsaveis' then
    v_nome := new.nome_externo;
  end if;
  select * into v_dp from responsavel_real_por_fap d
   where d.fap = v_fap
     and (d.usuario_id_externo = new.usuario_id_externo
          or (v_nome is not null and normalizar_texto(d.nome_externo) = normalizar_texto(v_nome)))
   limit 1;
  if found then
    new.consultor_id := v_dp.consultor_id;
    -- aprende o id da conta compartilhada para as próximas vezes (inclusive no tempo)
    if v_dp.usuario_id_externo is null and new.usuario_id_externo is not null then
      update responsavel_real_por_fap set usuario_id_externo = new.usuario_id_externo
       where normalizar_texto(nome_externo) = normalizar_texto(v_dp.nome_externo) and usuario_id_externo is null;
    end if;
  end if;
  return new;
end $$;
create trigger trg_resp_responsavel_real before insert or update on public.tarefas_responsaveis
  for each row execute function public.resolver_responsavel_real();
create trigger trg_tempo_responsavel_real before insert or update on public.registros_tempo
  for each row execute function public.resolver_responsavel_real();

-- Quem alterou o quê na tarefa (P5): vem dos avisos do webhook e das ações do sistema.
create table public.tarefas_historico (
  id                 bigint generated always as identity primary key,
  tarefa_id          uuid not null references public.tarefas(id) on delete cascade,
  origem             text not null default 'clickup' check (origem in ('clickup', 'interno')),
  id_externo         text,                 -- id do item de histórico na origem (evita duplicar)
  evento             text not null,        -- criada, status, responsavel, nome, datas, tempo, excluida...
  campo              text,
  valor_anterior     text,
  valor_novo         text,
  autor_id_externo   text,                 -- quem fez na origem
  autor_nome         text,
  autor_usuario_id   uuid references auth.users(id),   -- quando foi feito pelo sistema
  ocorrido_em        timestamptz not null default now(),
  unique (origem, id_externo)
);
create index idx_tarefas_historico on public.tarefas_historico (tarefa_id, ocorrido_em);

-- Sugestões de agrupamento geradas pelo sistema (R2.3).
create table public.sugestoes_agrupamento (
  id           uuid primary key default gen_random_uuid(),
  tarefa_id    uuid not null references public.tarefas(id) on delete cascade,
  demanda_id   uuid not null references public.demandas(id) on delete cascade,
  pontuacao    int  not null check (pontuacao between 0 and 100),
  motivos      jsonb not null,          -- [{"regra":"mesmo_ticket","pontos":60}, ...]
  status       text not null default 'pendente' check (status in ('pendente', 'aceita', 'recusada')),
  decidido_por uuid references auth.users(id),
  decidido_em  timestamptz,
  criado_em    timestamptz not null default now(),
  unique (tarefa_id, demanda_id)
);
create index idx_sugestoes_pendentes on public.sugestoes_agrupamento (tarefa_id) where status = 'pendente';

-- Log de cada execução da sincronização.
create table public.sincronizacoes (
  id                   bigint generated always as identity primary key,
  sistema              text not null default 'clickup',
  tipo                 text not null check (tipo in ('webhook', 'periodica', 'carga_inicial', 'manual')),
  conta_integracao_id  uuid references public.contas_integracao(id) on delete set null,  -- token usado
  iniciado_em          timestamptz not null default now(),
  finalizado_em        timestamptz,
  sucesso              boolean,
  tarefas_lidas        int default 0,
  tarefas_novas        int default 0,
  tarefas_alteradas    int default 0,
  registros_tempo      int default 0,
  listas_novas         int default 0,          -- listas descobertas (entram "a_analisar")
  chamadas_api         int default 0,
  mensagem             text,
  parametros           jsonb
);

-- =============================================================================
-- 4. Chamados (formulário do consultor, portal do cliente, triagem)
-- =============================================================================

create sequence public.seq_chamado_codigo start 1;

create table public.chamados (
  id                       uuid primary key default gen_random_uuid(),
  codigo                   text not null unique
                           default 'CH-' || lpad(nextval('public.seq_chamado_codigo')::text, 5, '0'),
  canal                    text not null check (canal in ('formulario_consultor', 'portal_cliente', 'interno')),
  -- Quem pediu
  cliente_id               uuid references public.clientes(id),
  cliente_informado        text,                 -- texto digitado (antes de ligar ao cadastro)
  gerente_projetos         text,
  consultor_lider          text,
  contato_nome             text,
  contato_info             text,                 -- e-mail / telefone
  solicitante_nome         text,
  solicitante_email        text,
  -- O que pediu
  titulo                   text not null,
  descricao                text,
  tipo                     text,
  prioridade               text not null default 'media'
                           check (prioridade in ('baixa', 'media', 'alta', 'urgente')),
  origem_solicitacao       text,
  desenvolvedor_indicado   text,                 -- obrigatório no formulário do consultor
  desenvolvedor_id         uuid references public.consultores(id),
  -- Sankhya
  chamado_sankhya_aberto   boolean not null default false,
  ticket_sankhya           text,
  retorno_sankhya          text,
  -- Triagem
  status                   text not null default 'novo'
                           check (status in ('novo', 'em_triagem', 'direcionado', 'tarefa_criada', 'recusado', 'concluido')),
  decisao_observacao       text,
  demanda_id               uuid references public.demandas(id),
  tarefa_criada_id_externo text,                 -- id da tarefa criada na origem a partir do chamado
  triado_por               uuid references auth.users(id),
  triado_em                timestamptz,
  -- Controle
  link_portal_id           uuid,
  ip_origem                inet,
  criado_em                timestamptz not null default now(),
  atualizado_em            timestamptz not null default now()
);
create index idx_chamados_status on public.chamados (status, criado_em);
create trigger trg_chamados_atualizado before update on public.chamados
  for each row execute function public.tocar_atualizado_em();

alter table public.demandas
  add constraint demandas_chamado_fk foreign key (chamado_id) references public.chamados(id);

-- Evidências em passos, com prints na sequência (passo 1 → texto → prints...).
create table public.chamados_evidencias (
  id          uuid primary key default gen_random_uuid(),
  chamado_id  uuid not null references public.chamados(id) on delete cascade,
  ordem       int  not null,
  texto       text,
  unique (chamado_id, ordem)
);

create table public.chamados_anexos (
  id             uuid primary key default gen_random_uuid(),
  evidencia_id   uuid not null references public.chamados_evidencias(id) on delete cascade,
  ordem          int  not null,
  caminho_storage text not null,             -- bucket "evidencias"
  tipo_arquivo   text not null,              -- image/png, application/pdf...
  tamanho_bytes  int,
  criado_em      timestamptz not null default now()
);

-- Link do portal por cliente (R5.2). O token vai na URL: /portal.html?t=<token>
create table public.links_portal (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  token       text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  descricao   text,
  ativo       boolean not null default true,
  expira_em   timestamptz,
  criado_em   timestamptz not null default now()
);
alter table public.chamados
  add constraint chamados_link_portal_fk foreign key (link_portal_id) references public.links_portal(id);

-- =============================================================================
-- 5. Views de horas, do kanban e de pendências
-- =============================================================================

-- Tempo registrado nas tarefas, por demanda e consultor.
-- Regra (P1): usa os registros de tempo; se a tarefa não tem nenhum, usa o tempo total
-- da tarefa; se também for zero, usa a duração do campo Período.
create or replace view public.vw_horas_registradas_por_demanda
with (security_invoker = true) as
with por_tarefa as (
  select t.demanda_id, t.id as tarefa_id,
         r.consultor_id,
         sum(r.minutos) as minutos,
         'registro_tempo'::text as fonte
  from public.tarefas t
  join public.registros_tempo r on r.tarefa_id = t.id and not r.excluido_na_origem
  where t.demanda_id is not null and not t.excluida_na_origem
  group by t.demanda_id, t.id, r.consultor_id
  union all
  select t.demanda_id, t.id,
         (select rr.consultor_id from public.tarefas_responsaveis rr
           where rr.tarefa_id = t.id and rr.consultor_id is not null limit 1),
         case when t.minutos_registrados > 0 then t.minutos_registrados else coalesce(t.minutos_periodo, 0) end,
         case when t.minutos_registrados > 0 then 'tempo_tarefa' else 'periodo' end
  from public.tarefas t
  where t.demanda_id is not null and not t.excluida_na_origem
    and not exists (select 1 from public.registros_tempo r
                    where r.tarefa_id = t.id and not r.excluido_na_origem)
)
select demanda_id, consultor_id, sum(minutos)::int as minutos_registrados,
       count(distinct tarefa_id) as tarefas
from por_tarefa
group by demanda_id, consultor_id;

create or replace view public.vw_horas_manuais_por_demanda
with (security_invoker = true) as
select demanda_id, consultor_id, sum(minutos)::int as minutos_manuais
from public.apontamentos_manuais
group by demanda_id, consultor_id;

-- Totais por demanda: registradas × manuais × estimadas.
create or replace view public.vw_horas_demanda
with (security_invoker = true) as
select d.id as demanda_id, d.codigo,
       coalesce((select sum(minutos_registrados) from public.vw_horas_registradas_por_demanda c where c.demanda_id = d.id), 0)::int as minutos_registrados,
       coalesce((select sum(minutos_manuais) from public.vw_horas_manuais_por_demanda m where m.demanda_id = d.id), 0)::int as minutos_manuais,
       d.minutos_estimados
from public.demandas d;

-- Tudo o que o card do kanban precisa em uma consulta.
create or replace view public.vw_kanban_cards
with (security_invoker = true) as
select d.id, d.codigo, d.titulo, d.coluna_id, d.ordem_na_coluna, d.prioridade, d.tipo,
       d.ticket_sankhya, d.data_prevista, d.atualizado_em,
       c.id as cliente_id, c.nome as cliente_nome, c.cor as cliente_cor,
       f.fap,
       co.id as consultor_id, co.nome as consultor_nome, co.cor as consultor_cor,
       (select count(*) from public.tarefas t where t.demanda_id = d.id and not t.excluida_na_origem) as qtd_tarefas,
       h.minutos_registrados, h.minutos_manuais, h.minutos_estimados
from public.demandas d
left join public.clientes c on c.id = d.cliente_id
left join public.clientes_faps f on f.id = d.fap_id
left join public.consultores co on co.id = d.consultor_responsavel_id
left join public.vw_horas_demanda h on h.demanda_id = d.id;

-- Contadores do menu: o que está esperando decisão do gestor.
create or replace view public.vw_pendencias_gestor
with (security_invoker = true) as
select
  (select count(*) from public.clientes_faps where situacao_sincronizacao = 'a_analisar') as listas_a_analisar,
  (select count(*) from public.tarefas where situacao = 'pendente' and not excluida_na_origem) as tarefas_pendentes,
  -- conta compartilhada ("BPMS") em FAP sem pessoa definida no de-para
  (select count(distinct (normalizar_texto(r.nome_externo), t.fap))
     from public.tarefas_responsaveis r join public.tarefas t on t.id = r.tarefa_id
    where r.consultor_id is null and not t.excluida_na_origem
      and normalizar_texto(r.nome_externo) in (select normalizar_texto(nome_externo) from public.responsavel_real_por_fap)
  ) as responsaveis_sem_pessoa,
  (select count(*) from public.chamados where status = 'novo') as chamados_novos;

-- =============================================================================
-- 6. Sugestão de agrupamento (ver docs/05-agrupamento-de-tarefas.md)
-- =============================================================================

-- Calcula as sugestões de uma tarefa contra as demandas abertas e grava em
-- sugestoes_agrupamento. Se a melhor pontuação passar do limiar automático e for a
-- única acima dele, agrupa sozinha. Retorna a quantidade de sugestões gravadas.
create or replace function public.sugerir_agrupamento(p_tarefa_id uuid)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tarefa        tarefas%rowtype;
  v_janela_dias   int := coalesce((select (valor->>'janela_dias')::int from configuracoes where chave = 'agrupamento'), 5);
  v_limiar_sug    int := coalesce((select (valor->>'limiar_sugestao')::int from configuracoes where chave = 'agrupamento'), 40);
  v_limiar_auto   int := coalesce((select (valor->>'limiar_automatico')::int from configuracoes where chave = 'agrupamento'), 85);
  v_qtd           int := 0;
  v_melhor        record;
  v_acima_auto    int;
begin
  if auth.uid() is not null and not public.eh_gestor() then
    raise exception 'Somente gestores podem agrupar tarefas.';
  end if;
  select * into v_tarefa from tarefas where id = p_tarefa_id;
  if not found or v_tarefa.situacao <> 'pendente' then
    return 0;
  end if;

  -- Regra 0: o código da demanda (DEM-0001) no nome ou no detalhamento = vínculo certo.
  for v_melhor in
    select d.id from demandas d
    where d.encerrado_em is null
      and (v_tarefa.nome ~* ('\m' || d.codigo || '\M') or coalesce(v_tarefa.detalhamento, '') ~* ('\m' || d.codigo || '\M'))
    limit 1
  loop
    update tarefas set demanda_id = v_melhor.id, situacao = 'agrupada',
           agrupada_por = 'automatico', agrupada_em = now()
     where id = p_tarefa_id;
    insert into demandas_historico (demanda_id, evento, detalhes)
    values (v_melhor.id, 'agrupou_tarefa', jsonb_build_object('tarefa_id', p_tarefa_id, 'regra', 'codigo_demanda'));
    return 1;
  end loop;

  with candidatas as (
    select d.id as demanda_id,
           -- mesmo ticket Sankhya citado no nome/detalhamento
           case when d.ticket_sankhya is not null and length(d.ticket_sankhya) >= 4
                 and (v_tarefa.nome || ' ' || coalesce(v_tarefa.detalhamento, '')) ~ ('\m' || d.ticket_sankhya || '\M')
                then 60 else 0 end as p_ticket,
           case when d.cliente_id = v_tarefa.cliente_id then 15 else 0 end as p_cliente,
           -- mesmo consultor: em outra tarefa da demanda ou como responsável da demanda
           case when exists (
                  select 1 from tarefas_responsaveis r1
                  join tarefas t2 on t2.demanda_id = d.id
                  join tarefas_responsaveis r2 on r2.tarefa_id = t2.id
                  where r1.tarefa_id = v_tarefa.id
                    and (r1.consultor_id = r2.consultor_id or r1.usuario_id_externo = r2.usuario_id_externo))
                  or exists (
                  select 1 from tarefas_responsaveis r1
                  where r1.tarefa_id = v_tarefa.id and r1.consultor_id = d.consultor_responsavel_id)
                then 10 else 0 end as p_consultor,
           -- maior semelhança entre o nome da tarefa e o título da demanda ou de suas tarefas
           greatest(
             similarity(v_tarefa.nome_normalizado, normalizar_texto(d.titulo)),
             coalesce((select max(similarity(v_tarefa.nome_normalizado, t3.nome_normalizado))
                       from tarefas t3 where t3.demanda_id = d.id), 0)
           ) as semelhanca,
           case when v_tarefa.usuario_cliente is not null and exists (
                  select 1 from tarefas t4 where t4.demanda_id = d.id
                  and normalizar_texto(t4.usuario_cliente) = normalizar_texto(v_tarefa.usuario_cliente))
                then 5 else 0 end as p_usuario,
           -- última atividade da demanda dentro da janela
           case when exists (
                  select 1 from tarefas t5 where t5.demanda_id = d.id
                  and abs(extract(epoch from (coalesce(t5.data_vencimento, t5.criada_na_origem)
                        - coalesce(v_tarefa.data_vencimento, v_tarefa.criada_na_origem)))) <= v_janela_dias * 86400)
                  or abs(extract(epoch from (d.atualizado_em - coalesce(v_tarefa.criada_na_origem, now())))) <= v_janela_dias * 86400
                then 5 else 0 end as p_janela
    from demandas d
    where d.encerrado_em is null
      and (d.cliente_id is null or v_tarefa.cliente_id is null or d.cliente_id = v_tarefa.cliente_id)
  ), pontuadas as (
    select demanda_id,
           least(100, p_ticket + p_cliente + p_consultor + p_usuario + p_janela
                      + round(semelhanca * 40)::int) as pontuacao,
           jsonb_strip_nulls(jsonb_build_array(
             case when p_ticket > 0 then jsonb_build_object('regra', 'mesmo_ticket_sankhya', 'pontos', p_ticket) end,
             case when p_cliente > 0 then jsonb_build_object('regra', 'mesmo_cliente', 'pontos', p_cliente) end,
             case when p_consultor > 0 then jsonb_build_object('regra', 'mesmo_consultor', 'pontos', p_consultor) end,
             case when p_usuario > 0 then jsonb_build_object('regra', 'mesmo_usuario_cliente', 'pontos', p_usuario) end,
             case when p_janela > 0 then jsonb_build_object('regra', 'dentro_da_janela', 'pontos', p_janela) end,
             jsonb_build_object('regra', 'titulo_parecido', 'pontos', round(semelhanca * 40)::int,
                                'semelhanca', round(semelhanca::numeric, 2))
           )) as motivos
    from candidatas
  )
  insert into sugestoes_agrupamento (tarefa_id, demanda_id, pontuacao, motivos)
  select p_tarefa_id, demanda_id, pontuacao,
         (select coalesce(jsonb_agg(m), '[]'::jsonb) from jsonb_array_elements(motivos) m where m <> 'null'::jsonb)
  from pontuadas
  where pontuacao >= v_limiar_sug
  order by pontuacao desc
  limit 5
  on conflict (tarefa_id, demanda_id) do update
     set pontuacao = excluded.pontuacao, motivos = excluded.motivos
     where sugestoes_agrupamento.status = 'pendente';
  get diagnostics v_qtd = row_count;

  -- Agrupamento automático: só se uma única sugestão passar do limiar automático.
  select count(*) into v_acima_auto from sugestoes_agrupamento
   where tarefa_id = p_tarefa_id and status = 'pendente' and pontuacao >= v_limiar_auto;
  if v_acima_auto = 1 then
    select demanda_id into v_melhor from sugestoes_agrupamento
     where tarefa_id = p_tarefa_id and status = 'pendente' and pontuacao >= v_limiar_auto;
    perform aceitar_sugestao(p_tarefa_id, v_melhor.demanda_id, 'automatico');
  end if;

  return v_qtd;
end $$;

-- Aceita uma sugestão (ou agrupa manualmente): liga a tarefa à demanda e fecha as demais sugestões.
create or replace function public.aceitar_sugestao(p_tarefa_id uuid, p_demanda_id uuid, p_modo text default 'manual')
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is not null and not public.eh_gestor() then
    raise exception 'Somente gestores podem agrupar tarefas.';
  end if;
  update tarefas
     set demanda_id = p_demanda_id, situacao = 'agrupada', agrupada_por = p_modo, agrupada_em = now()
   where id = p_tarefa_id;
  update sugestoes_agrupamento
     set status = case when demanda_id = p_demanda_id then 'aceita' else 'recusada' end,
         decidido_por = auth.uid(), decidido_em = now()
   where tarefa_id = p_tarefa_id and status = 'pendente';
  insert into demandas_historico (demanda_id, evento, detalhes, usuario_id)
  values (p_demanda_id, 'agrupou_tarefa', jsonb_build_object('tarefa_id', p_tarefa_id, 'modo', p_modo), auth.uid());
end $$;

-- Cria uma demanda nova a partir de uma tarefa do repositório.
create or replace function public.criar_demanda_da_tarefa(p_tarefa_id uuid, p_coluna_id uuid default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_t       tarefas%rowtype;
  v_id      uuid;
  v_coluna  uuid := coalesce(p_coluna_id,
                     (select id from kanban_colunas where tipo = 'entrada' and ativa order by ordem limit 1));
begin
  if auth.uid() is not null and not public.eh_gestor() then
    raise exception 'Somente gestores podem agrupar tarefas.';
  end if;
  select * into v_t from tarefas where id = p_tarefa_id;
  insert into demandas (titulo, descricao, cliente_id, fap_id, consultor_responsavel_id,
                        origem_solicitacao, coluna_id, criado_por)
  values (v_t.nome, v_t.detalhamento, v_t.cliente_id,
          coalesce(v_t.fap_id, (select id from clientes_faps where lista_id_externo = v_t.lista_id_externo)),
          (select consultor_id from tarefas_responsaveis
            where tarefa_id = p_tarefa_id and consultor_id is not null limit 1),
          v_t.origem_solicitacao, v_coluna, auth.uid())
  returning id into v_id;
  perform aceitar_sugestao(p_tarefa_id, v_id, 'manual');
  return v_id;
end $$;

-- =============================================================================
-- 7. Segurança (RLS)
-- =============================================================================
-- Gestores (admin/gestor ativos) leem e escrevem tudo, exceto contas_integracao (só leitura:
--   quem grava é a Edge Function de conexão).
-- Consultor: lê as demandas em que é responsável (fase 4).
-- Anônimo (formulário/portal): não acessa tabela nenhuma; grava pela Edge Function.

create or replace function public.eh_gestor()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from usuarios_sistema
                 where id = auth.uid() and ativo and papel in ('admin', 'gestor'))
$$;

create or replace function public.consultor_do_usuario()
returns uuid language sql stable security definer set search_path = public, extensions as $$
  select consultor_id from usuarios_sistema where id = auth.uid() and ativo
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'usuarios_sistema', 'consultores', 'clientes', 'clientes_faps', 'responsavel_real_por_fap',
    'configuracoes', 'kanban_colunas', 'demandas', 'demandas_historico', 'apontamentos_manuais',
    'tarefas', 'tarefas_responsaveis', 'registros_tempo', 'tarefas_historico',
    'sugestoes_agrupamento', 'sincronizacoes', 'chamados', 'chamados_evidencias',
    'chamados_anexos', 'links_portal']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy gestor_tudo on public.%I for all to authenticated using (public.eh_gestor()) with check (public.eh_gestor())', t);
  end loop;
end $$;

-- Contas de integração: gestor só lê (o token nem está aqui). Gravação só pela Edge Function.
alter table public.contas_integracao enable row level security;
create policy gestor_le_contas on public.contas_integracao for select to authenticated
  using (public.eh_gestor() or usuario_id = auth.uid());

-- Consultor logado: lê o próprio cadastro, as colunas e as demandas dele.
create policy consultor_le_colunas on public.kanban_colunas for select to authenticated
  using (public.consultor_do_usuario() is not null);
create policy consultor_le_demandas on public.demandas for select to authenticated
  using (consultor_responsavel_id = public.consultor_do_usuario());
create policy usuario_le_a_si on public.usuarios_sistema for select to authenticated
  using (id = auth.uid());

-- As funções de agrupamento rodam como dono do banco: só gestores podem chamá-las.
revoke execute on function public.sugerir_agrupamento(uuid) from public, anon;
revoke execute on function public.aceitar_sugestao(uuid, uuid, text) from public, anon;
revoke execute on function public.criar_demanda_da_tarefa(uuid, uuid) from public, anon;
