-- Testes da migração 0013 (acessos pela tela Consultores). Rodado por rodar.sh.
\set ON_ERROR_STOP 1

-- Cenário: 0001 = Rodrigo (gestor), 0002 = Iago (consultor), 0003 = admin de teste ligado ao cadastro.
insert into auth.users (id, email, last_sign_in_at) values
  ('00000000-0000-0000-0000-000000000003', 'admin.teste@sankhya.com.br', now() - interval '1 day');
insert into consultores (id, nome, email) values
  ('c0000000-0000-0000-0000-000000000003', 'Admin Teste', 'admin.teste@sankhya.com.br'),
  ('c0000000-0000-0000-0000-000000000001', 'Rodrigo Reis', 'Rodrigo.Reis@sankhya.com.br'),
  ('c0000000-0000-0000-0000-000000000009', 'Sem E-mail', null);
insert into usuarios_sistema (id, nome, email, papel, consultor_id) values
  ('00000000-0000-0000-0000-000000000003', 'Admin Teste', 'admin.teste@sankhya.com.br', 'admin', 'c0000000-0000-0000-0000-000000000003');

\echo '== A1 regras de quem dá acesso'
do $$
declare
  v_ges   uuid := '00000000-0000-0000-0000-000000000001';
  v_adm   uuid := '00000000-0000-0000-0000-000000000003';
  v_andre uuid := (select id from consultores where email = 'andre.acunha@sankhya.com.br');
  d jsonb;
begin
  d := preparar_acesso(v_andre, 'consultor', v_ges);
  if d->>'email' <> 'andre.acunha@sankhya.com.br' or d->>'papel' <> 'consultor' or d->>'usuario_id' is not null then
    raise exception 'FALHOU: preparar consultor %', d; end if;
  begin perform preparar_acesso(v_andre, 'gestor', v_ges); raise exception 'FALHOU: gestor deu acesso de gestor';
  exception when raise_exception then if sqlerrm not like 'Só o admin dá acesso de gestor%' then raise; end if; end;
  if preparar_acesso(v_andre, 'gestor', v_adm)->>'papel' <> 'gestor' then raise exception 'FALHOU: admin dá gestor'; end if;
  begin perform preparar_acesso(v_andre, 'consultor', '00000000-0000-0000-0000-000000000002'); raise exception 'FALHOU: consultor deu acesso';
  exception when raise_exception then if sqlerrm not like 'Só gestores%' then raise; end if; end;
  begin perform preparar_acesso('c0000000-0000-0000-0000-000000000009', 'consultor', v_ges); raise exception 'FALHOU: sem e-mail';
  exception when raise_exception then if sqlerrm not like '%não tem e-mail%' then raise; end if; end;
  begin perform preparar_acesso('c0000000-0000-0000-0000-000000000003', null, v_ges); raise exception 'FALHOU: gestor mexeu no admin';
  exception when raise_exception then if sqlerrm not like 'O acesso do admin%' then raise; end if; end;
  -- admin troca a própria senha
  if preparar_acesso('c0000000-0000-0000-0000-000000000003', null, v_adm)->>'papel' <> 'admin' then raise exception 'FALHOU: admin própria senha'; end if;
  -- "Nova senha" de quem ainda não tem acesso
  begin perform preparar_acesso(v_andre, null, v_ges); raise exception 'FALHOU: nova senha sem acesso';
  exception when raise_exception then if sqlerrm not like '%ainda não tem acesso%' then raise; end if; end;
  -- login antigo pelo e-mail (acesso criado no SQL, sem consultor_id): é achado
  if (preparar_acesso((select id from consultores where email = 'iago.proenca@sankhya.com.br'), null, v_ges)->>'usuario_id')::uuid
     <> '00000000-0000-0000-0000-000000000002' then raise exception 'FALHOU: achar login do Iago'; end if;
  raise notice 'ok regras';
end $$;

\echo '== A2 gravar, situação, gestor x admin, tirar e senha trocada'
do $$
declare
  v_ges   uuid := '00000000-0000-0000-0000-000000000001';
  v_adm   uuid := '00000000-0000-0000-0000-000000000003';
  v_andre uuid := (select id from consultores where email = 'andre.acunha@sankhya.com.br');
  v_login uuid := '00000000-0000-0000-0000-0000000000a1';
begin
  insert into auth.users (id, email) values (v_login, 'andre.acunha@sankhya.com.br');   -- a Edge Function cria no Auth
  perform gravar_acesso(v_login, v_andre, 'consultor', v_ges);
  if not exists (select 1 from usuarios_sistema where id = v_login and papel = 'consultor' and consultor_id = v_andre
                   and ativo and trocar_senha and acesso_por = v_ges) then raise exception 'FALHOU: gravar acesso'; end if;
  -- admin promove a gestor; depois o gestor comum não mexe mais nele
  perform gravar_acesso(v_login, v_andre, (preparar_acesso(v_andre, 'gestor', v_adm)->>'papel'), v_adm);
  begin perform preparar_acesso(v_andre, null, v_ges); raise exception 'FALHOU: gestor mexeu em gestor';
  exception when raise_exception then if sqlerrm not like 'Só o admin altera%' then raise; end if; end;
  begin perform tirar_acesso(v_andre, v_ges); raise exception 'FALHOU: gestor tirou gestor';
  exception when raise_exception then if sqlerrm not like 'Só o admin altera%' then raise; end if; end;
  perform tirar_acesso(v_andre, v_adm);
  if (select ativo from usuarios_sistema where id = v_login) then raise exception 'FALHOU: tirar acesso'; end if;
  -- ninguém tira o próprio acesso (Rodrigo achado pelo e-mail, sem diferença de maiúsculas)
  begin perform tirar_acesso('c0000000-0000-0000-0000-000000000001', v_ges); raise exception 'FALHOU: tirou o próprio';
  exception when raise_exception then if sqlerrm not like 'Você não pode tirar o próprio acesso%' then raise; end if; end;
  -- reativar = dar acesso de novo (volta ativo, com senha temporária)
  perform gravar_acesso(v_login, v_andre, 'gestor', v_adm);
  if not (select ativo and trocar_senha from usuarios_sistema where id = v_login) then raise exception 'FALHOU: reativar'; end if;
  raise notice 'ok gravar e tirar';
end $$;

set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
set role authenticated;
select senha_trocada();
reset role;
do $$ begin
  if (select trocar_senha from usuarios_sistema where id = '00000000-0000-0000-0000-0000000000a1') then raise exception 'FALHOU: senha trocada'; end if;
  raise notice 'ok senha trocada';
end $$;

\echo '== A3 situação na tela (gestor) e permissões'
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$ begin
  if not exists (select 1 from situacao_acessos() s join consultores c on c.id = s.consultor_id
                  where c.email = 'iago.proenca@sankhya.com.br' and s.papel = 'consultor' and s.ativo) then
    raise exception 'FALHOU: situação do Iago'; end if;
  if not exists (select 1 from situacao_acessos() where consultor_id = 'c0000000-0000-0000-0000-000000000003' and ultimo_login is not null) then
    raise exception 'FALHOU: último login'; end if;
  if exists (select 1 from situacao_acessos() where consultor_id = 'c0000000-0000-0000-0000-000000000009') then
    raise exception 'FALHOU: sem acesso apareceu'; end if;
  begin perform preparar_acesso(gen_random_uuid(), 'consultor', gen_random_uuid()); raise exception 'FALHOU: navegador chamou preparar';
  exception when insufficient_privilege then null; end;
  begin perform gravar_acesso(gen_random_uuid(), gen_random_uuid(), 'admin', gen_random_uuid()); raise exception 'FALHOU: navegador gravou acesso';
  exception when insufficient_privilege then null; end;
  raise notice 'ok situacao e permissoes';
end $$;
reset role;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';   -- consultor não vê a situação
set role authenticated;
do $$ begin
  begin perform situacao_acessos(); raise exception 'FALHOU: consultor viu acessos';
  exception when raise_exception then if sqlerrm not like 'Só gestores%' then raise; end if; end;
  raise notice 'ok consultor bloqueado';
end $$;
reset role;
reset request.jwt.claim.sub;

-- limpeza
delete from usuarios_sistema where id in ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1');
delete from auth.users where id in ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1');
delete from consultores where id in ('c0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000009');
\echo '== FIM 0013'
