-- Simula o mínimo do Supabase: schema auth, auth.uid(), papéis anon/authenticated/service_role,
-- Vault (cofre de segredos), pg_cron e pg_net. Só para teste local — o Supabase já tem tudo isso.
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);
alter table auth.users add column if not exists last_sign_in_at timestamptz;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role bypassrls; end if;
end $$;
create schema if not exists extensions;
grant usage on schema public, auth, extensions to anon, authenticated, service_role;

-- Vault simulado (no Supabase o segredo fica criptografado; aqui é texto puro)
create schema if not exists vault;
create table if not exists vault.secrets (
  id uuid primary key default gen_random_uuid(), name text unique, description text, secret text);
create or replace view vault.decrypted_secrets as
  select id, name, description, secret, secret as decrypted_secret from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '')
returns uuid language sql as $$
  insert into vault.secrets (name, description, secret) values (new_name, new_description, new_secret) returning id $$;
create or replace function vault.update_secret(secret_id uuid, new_secret text default null)
returns void language sql as $$
  update vault.secrets set secret = coalesce(new_secret, secret) where id = secret_id $$;

-- pg_cron simulado
create schema if not exists cron;
create table if not exists cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid $$;
create or replace function cron.unschedule(job_id bigint) returns boolean language sql as $$
  delete from cron.job where jobid = job_id returning true $$;

-- pg_net simulado: guarda a chamada numa tabela em vez de fazer HTTP
create schema if not exists net;
create table if not exists net.chamadas (id bigserial primary key, url text, body jsonb, headers jsonb);
create or replace function net.http_post(url text, body jsonb default '{}', headers jsonb default '{}',
                                         timeout_milliseconds int default 5000)
returns bigint language sql as $$
  insert into net.chamadas (url, body, headers) values (url, body, headers) returning id $$;

-- Privilégios padrão como no Supabase: toda função nova em public nasce executável por
-- anon/authenticated/service_role (por isso as migrações fazem "revoke" nas funções internas).
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to service_role;
grant usage on schema public to service_role;

-- Storage simulado (buckets e objetos), só o necessário para a migração 0009
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
