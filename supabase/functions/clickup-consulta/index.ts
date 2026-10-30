// Edge Function clickup-consulta — consultas AO VIVO no ClickUp, sem gravar nada no banco (desvio do escopo, 30/10/2026).
//
// Quem pode chamar: gestor logado. Usa o token do próprio gestor (D11/D19); sem conta conectada,
// a conta da sincronização (ou o token único, D12).
//
// Corpo (JSON):
//   { acao: "personalizacao", emails: ["a@b", ...], desde?: "AAAA-MM-DD", incluir_fechadas?: boolean }
//   Devolve as tarefas do espaço PMO BP-MS:
//     • grupo "personalizacao": etapa = "Personalização / Customização";
//     • grupo "revisar": das pessoas informadas, alteradas desde a data, com OUTRA etapa (ou vazia) —
//       são as que provavelmente deveriam estar em Personalização.
//   Tarefas-estrutura ("1-Atendimento Base", mês) ficam de fora.

import { bancoAdmin, CORS, ehGestor, mensagemDeErro, responder, rpc, usuarioDaRequisicao } from "../_compartilhado/base.ts";
import { ClienteClickUp, clienteDaSincronizacao, ErroClickUp } from "../_compartilhado/clickup-api.ts";
import { consultarPersonalizacao } from "../_compartilhado/clickup-consulta.ts";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });
  const banco = bancoAdmin();
  try {
    const usuario = await usuarioDaRequisicao(req, banco);
    if (!ehGestor(usuario)) return responder(401, { erro: "Acesso só para gestores." });
    const corpo = await req.json().catch(() => ({}));
    if (corpo.acao !== "personalizacao") return responder(400, { erro: "Ação desconhecida." });

    // token do gestor; senão o da sincronização
    const contas = await rpc<{ token: string }[]>(banco, "ler_token_usuario", { p_usuario_id: usuario.id, p_sistema: "clickup" });
    const api = contas?.length ? new ClienteClickUp(contas[0].token) : (await clienteDaSincronizacao(banco)).cliente;

    const emails: string[] = (Array.isArray(corpo.emails) ? corpo.emails : [])
      .map((e: unknown) => String(e).trim().toLowerCase()).filter((e: string) => EMAIL.test(e)).slice(0, 30);
    const desde = typeof corpo.desde === "string" && /^\d{4}-\d{2}-\d{2}$/.test(corpo.desde)
      ? new Date(corpo.desde + "T00:00:00-04:00") : new Date("2026-01-01T00:00:00-04:00");
    const incluirFechadas = !!corpo.incluir_fechadas;
    return responder(200, await consultarPersonalizacao(api, emails, desde, incluirFechadas));
  } catch (e) {
    console.error(e);
    const msg = e instanceof ErroClickUp && e.status === 401
      ? "O ClickUp recusou o token. Reconecte a sua conta em Meu perfil." : mensagemDeErro(e);
    return responder(500, { erro: msg });
  }
});
