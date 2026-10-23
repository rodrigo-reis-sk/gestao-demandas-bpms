// Edge Function clickup-conectar — liga a conta do ClickUp do gestor logado (D11).
//
// Corpo (JSON), um dos dois:
//   { "codigo": "<code>" }            → retorno do login OAuth do ClickUp (caminho principal)
//   { "token_pessoal": "pk_..." }     → reserva: token pessoal do próprio gestor (se o OAuth
//                                       não for liberado no workspace; mantém a autoria por gestor)
//
// Passos: obtém o token → pergunta ao ClickUp de quem é (GET /user) → confere que o e-mail é
// o mesmo do login no sistema → grava o token no Vault e a conexão em contas_integracao.
// O navegador nunca recebe o token de volta.

import {
  bancoAdmin, CORS, ehGestor, mensagemDeErro, responder, rpc, usuarioDaRequisicao,
} from "../_compartilhado/base.ts";
import { ClienteClickUp, ErroClickUp, trocarCodigoPorToken } from "../_compartilhado/clickup-api.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });

  const banco = bancoAdmin();
  try {
    const usuario = await usuarioDaRequisicao(req, banco);
    if (!ehGestor(usuario)) return responder(401, { erro: "Faça login como gestor para conectar a conta." });

    const corpo = await req.json().catch(() => ({}));
    let token: string;
    let tipo: "oauth" | "token_pessoal";

    if (typeof corpo.codigo === "string" && corpo.codigo) {
      const clientId = Deno.env.get("CLICKUP_CLIENT_ID");
      const clientSecret = Deno.env.get("CLICKUP_CLIENT_SECRET");
      if (!clientId || !clientSecret) {
        return responder(400, { erro: "O app OAuth do ClickUp ainda não foi configurado no Supabase (CLICKUP_CLIENT_ID / CLICKUP_CLIENT_SECRET)." });
      }
      token = await trocarCodigoPorToken(clientId, clientSecret, corpo.codigo);
      tipo = "oauth";
    } else if (typeof corpo.token_pessoal === "string" && /^pk_\w+$/.test(corpo.token_pessoal.trim())) {
      token = corpo.token_pessoal.trim();
      tipo = "token_pessoal";
    } else {
      return responder(400, { erro: "Informe o código do OAuth ou um token pessoal (começa com pk_)." });
    }

    // De quem é a conta?
    let dono;
    try {
      dono = (await new ClienteClickUp(token).usuario()).user;
    } catch (e) {
      if (e instanceof ErroClickUp && e.status === 401) return responder(400, { erro: "O ClickUp recusou este token." });
      throw e;
    }
    if (!dono?.email) return responder(400, { erro: "O ClickUp não informou o e-mail da conta." });

    if (dono.email.trim().toLowerCase() !== usuario.email.trim().toLowerCase()) {
      return responder(400, {
        erro: `A conta do ClickUp é de ${dono.email}, mas você entrou no sistema como ${usuario.email}. ` +
          "Conecte a conta do ClickUp que usa o mesmo e-mail.",
      });
    }

    await rpc(banco, "salvar_conta_integracao", {
      p_usuario_id: usuario.id, p_sistema: "clickup", p_email_externo: dono.email,
      p_usuario_id_externo: String(dono.id), p_nome_externo: dono.username ?? null,
      p_tipo_autenticacao: tipo, p_token: token,
    });

    return responder(200, { ok: true, email: dono.email, nome: dono.username, tipo });
  } catch (e) {
    console.error(e);
    return responder(500, { erro: mensagemDeErro(e) });
  }
});
