// Edge Function acessos — "Dar acesso", "Nova senha" e "Tirar acesso" na tela Consultores (D75).
// Sem SQL e sem o painel do Supabase: esta função cria/atualiza o login no Supabase Auth com a chave de serviço.
//
// Quem pode chamar: gestor logado. As REGRAS ficam no banco (migração 0013):
//   qualquer gestor dá acesso de consultor; acesso de gestor e mudanças em gestor só o admin;
//   o acesso do admin não muda por aqui; ninguém tira o próprio acesso.
//
// Corpo (JSON):
//   { acao: "dar_acesso", consultor_id, papel: "consultor" | "gestor" }  → cria (ou reativa) o login; devolve a senha temporária
//   { acao: "nova_senha", consultor_id }                                → nova senha temporária
//   { acao: "tirar_acesso", consultor_id }                              → desativa (não apaga)
// A senha temporária só aparece nesta resposta (não fica gravada em lugar nenhum além do Auth).
// No primeiro login a tela pede a senha nova (usuarios_sistema.trocar_senha).

import { bancoAdmin, CORS, ehGestor, mensagemDeErro, responder, rpc, usuarioDaRequisicao } from "../_compartilhado/base.ts";
import { gerarSenhaTemporaria } from "../_compartilhado/senha.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fraseDoBanco = (e: unknown) => mensagemDeErro(e).replace(/^Banco \([^)]*\): /, "");

interface Preparo { nome: string; email: string; papel: string; usuario_id: string | null }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });

  const banco = bancoAdmin();
  try {
    const usuario = await usuarioDaRequisicao(req, banco);
    if (!ehGestor(usuario)) return responder(401, { erro: "Acesso só para gestores." });
    const corpo = await req.json().catch(() => ({}));
    const consultorId = String(corpo.consultor_id ?? "");
    if (!UUID.test(consultorId)) return responder(400, { erro: "Pessoa não informada." });

    if (corpo.acao === "tirar_acesso") {
      try {
        const d = await rpc<Preparo>(banco, "tirar_acesso", { p_consultor: consultorId, p_por: usuario.id });
        return responder(200, { ok: true, nome: d.nome });
      } catch (e) {
        return responder(400, { erro: fraseDoBanco(e) });
      }
    }

    if (corpo.acao !== "dar_acesso" && corpo.acao !== "nova_senha") return responder(400, { erro: "Ação desconhecida." });
    const papel = corpo.acao === "dar_acesso" ? (corpo.papel === "gestor" ? "gestor" : "consultor") : null;

    let d: Preparo;
    try {
      d = await rpc<Preparo>(banco, "preparar_acesso", { p_consultor: consultorId, p_papel: papel, p_por: usuario.id });
    } catch (e) {
      return responder(400, { erro: fraseDoBanco(e) });
    }

    const senha = gerarSenhaTemporaria();
    let loginId = d.usuario_id;
    if (loginId) {
      const { error } = await banco.auth.admin.updateUserById(loginId, { password: senha, email_confirm: true });
      if (error) throw new Error(`Não foi possível trocar a senha: ${error.message}`);
    } else {
      // e-mail confirmado na hora: o plano Free envia poucos e-mails (D20), então não depende de e-mail
      const { data, error } = await banco.auth.admin.createUser({ email: d.email, password: senha, email_confirm: true });
      if (error || !data.user) throw new Error(`Não foi possível criar o login: ${error?.message ?? "sem resposta"}`);
      loginId = data.user.id;
    }
    await rpc(banco, "gravar_acesso", { p_usuario: loginId, p_consultor: consultorId, p_papel: d.papel, p_por: usuario.id });
    return responder(200, { ok: true, nome: d.nome, email: d.email, papel: d.papel, senha });
  } catch (e) {
    console.error(e);
    return responder(500, { erro: mensagemDeErro(e) });
  }
});
