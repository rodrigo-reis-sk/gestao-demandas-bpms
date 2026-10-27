// Edge Function clickup-criar — botão "Aprovar e criar no ClickUp" da Triagem (fase 4, D65–D70).
//
// Quem pode chamar: gestor logado. A tarefa sai com o TOKEN DE QUEM CLICOU (D11/D19): no ClickUp,
// o criador é o gestor. Sem conta conectada, usa o token único dos segredos (CLICKUP_TOKEN, D12), se houver;
// senão recusa e a tela oferece o modo manual ("Aprovar, crio à mão", D66).
//
// Corpo (JSON):
//   { acao: "criar", chamado_id, lista_id, desenvolvedor_id, consultor_id?, vencimento? ("AAAA-MM-DD"),
//     estimativa_horas?, link_triagem? }
//   { acao: "reenviar_prints", chamado_id }    → anexa os prints que faltaram numa tarefa já criada
//
// A regra de criação (legado) está em _compartilhado/clickup-criacao.ts. O banco:
//   • reservar_criacao_tarefa → confere, aprova e trava o chamado (clique duplo não cria duas tarefas);
//   • registrar_criacao_tarefa → guarda o id da tarefa assim que ela nasce e o resultado final;
//   • gravar_tarefas → a tarefa entra no banco na hora e o gatilho liga ao chamado (D61; também pelo id).

import {
  type Banco, bancoAdmin, CORS, ehGestor, mensagemDeErro, responder, rpc, usuarioDaRequisicao,
} from "../_compartilhado/base.ts";
import { ClienteClickUp, ErroClickUp } from "../_compartilhado/clickup-api.ts";
import { criarTarefaDoChamado, type DadosChamado, enviarPrints, type Ganchos } from "../_compartilhado/clickup-criacao.ts";
import { traduzirTarefa } from "../_compartilhado/clickup-traducao.ts";

const BUCKET = "evidencias";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });

  const banco = bancoAdmin();
  try {
    const usuario = await usuarioDaRequisicao(req, banco);
    if (!ehGestor(usuario)) return responder(401, { erro: "Acesso só para gestores." });
    const corpo = await req.json().catch(() => ({}));
    if (!UUID.test(String(corpo.chamado_id ?? ""))) return responder(400, { erro: "Chamado não informado." });

    const conexao = await clienteDoGestor(banco, usuario.id);
    if (!conexao) {
      return responder(412, { erro: "Conecte a sua conta do ClickUp em Meu perfil (ou use \"Aprovar, crio à mão\")." });
    }
    if (corpo.acao === "criar") return await criar(banco, usuario.id, conexao, corpo);
    if (corpo.acao === "reenviar_prints") return await reenviar(banco, conexao, corpo.chamado_id);
    return responder(400, { erro: "Ação desconhecida." });
  } catch (e) {
    console.error(e);
    return responder(500, { erro: mensagemDeErro(e) });
  }
});

interface Conexao { api: ClienteClickUp; contaId: string | null; reserva: boolean }

/** Token do gestor que clicou (Vault); senão o token único dos segredos (plano B, D12). */
async function clienteDoGestor(banco: Banco, usuarioId: string): Promise<Conexao | null> {
  const contas = await rpc<{ conta_id: string; token: string }[]>(banco, "ler_token_usuario", {
    p_usuario_id: usuarioId, p_sistema: "clickup",
  });
  if (contas?.length) return { api: new ClienteClickUp(contas[0].token), contaId: contas[0].conta_id, reserva: false };
  const unico = Deno.env.get("CLICKUP_TOKEN");
  return unico ? { api: new ClienteClickUp(unico), contaId: null, reserva: true } : null;
}

/** Erro do banco ("Escolha uma lista do cliente.") sem o prefixo técnico. */
const fraseDoBanco = (e: unknown) => mensagemDeErro(e).replace(/^Banco \([^)]*\): /, "");

function ganchos(banco: Banco, chamadoId: string, aoCriar?: (t: any) => Promise<void>): Ganchos {
  return {
    async baixar(caminho) {
      const { data, error } = await banco.storage.from(BUCKET).download(caminho);
      if (error || !data) throw new Error(`print não encontrado no armazenamento (${error?.message ?? caminho})`);
      return data;
    },
    async anexoEnviado(anexoId) {
      await rpc(banco, "marcar_anexo_enviado", { p_anexo: anexoId });
    },
    tarefaCriada: aoCriar,
  };
}

/** Tarefa recusada pelo token (401): a conta do gestor fica em "erro" e a mensagem pede para reconectar. */
async function tratarTokenRecusado(banco: Banco, conexao: Conexao, e: unknown): Promise<string> {
  let msg = mensagemDeErro(e);
  if (e instanceof ErroClickUp && e.status === 401) {
    msg = "O ClickUp recusou o seu token. Reconecte a sua conta em Meu perfil. " + msg;
    if (conexao.contaId) await rpc(banco, "registrar_uso_conta", { p_conta_id: conexao.contaId, p_erro: msg }).catch(() => {});
  }
  return msg;
}

async function criar(banco: Banco, usuarioId: string, conexao: Conexao, corpo: any): Promise<Response> {
  const vencimento = typeof corpo.vencimento === "string" && /^\d{4}-\d{2}-\d{2}$/.test(corpo.vencimento) ? corpo.vencimento : null;
  const horas = Number(corpo.estimativa_horas);
  if (corpo.estimativa_horas != null && corpo.estimativa_horas !== "" && !(horas > 0 && horas <= 500)) {
    return responder(400, { erro: "Estimativa de horas inválida (de 0,5 a 500)." });
  }
  const link = typeof corpo.link_triagem === "string" && /^https:\/\/[^\s)]{1,300}$/.test(corpo.link_triagem) ? corpo.link_triagem : null;

  let dados: DadosChamado;
  try {
    dados = await rpc<DadosChamado>(banco, "reservar_criacao_tarefa", {
      p_chamado: corpo.chamado_id, p_usuario: usuarioId, p_lista: UUID.test(String(corpo.lista_id ?? "")) ? corpo.lista_id : null,
      p_desenvolvedor: UUID.test(String(corpo.desenvolvedor_id ?? "")) ? corpo.desenvolvedor_id : null,
      p_consultor: UUID.test(String(corpo.consultor_id ?? "")) ? corpo.consultor_id : null,
    });
  } catch (e) {
    return responder(400, { erro: fraseDoBanco(e) });
  }

  let criada: any = null;
  try {
    const r = await criarTarefaDoChamado(conexao.api, dados, {
      vencimento, estimativaMinutos: horas > 0 ? horas * 60 : null, linkTriagem: link,
    }, ganchos(banco, dados.id, async (t) => {
      // guarda o id assim que a tarefa nasce: se algo falhar depois, nunca cria outra
      criada = t;
      await rpc(banco, "registrar_criacao_tarefa", { p_chamado: dados.id, p_situacao: "criada", p_id_externo: String(t.id), p_url: t.url ?? null });
    }));
    const avisos = [...r.avisos];
    if (conexao.reserva) avisos.push("Criada com o token único (sua conta do ClickUp não está conectada).");

    // traz para o banco já (a mãe e a base também, para a hierarquia); o webhook faria o mesmo em segundos
    const ligada = await gravarNoBanco(banco, conexao.api, [r.baseId, r.mesId, String(r.tarefa.id)], dados.id, avisos);
    await rpc(banco, "registrar_criacao_tarefa", {
      p_chamado: dados.id, p_situacao: "criada", p_id_externo: String(r.tarefa.id), p_url: r.tarefa.url ?? null,
      p_mensagem: avisos.join(" · ") || null,
    });
    if (conexao.contaId) await rpc(banco, "registrar_uso_conta", { p_conta_id: conexao.contaId });
    return responder(200, {
      ok: true, nome: r.tarefa.name, url: r.tarefa.url ?? null, ligada, avisos,
      prints_enviados: r.printsEnviados, prints_pendentes: r.printsPendentes,
    });
  } catch (e) {
    console.error(e);
    const msg = await tratarTokenRecusado(banco, conexao, e);
    await rpc(banco, "registrar_criacao_tarefa", {
      p_chamado: dados.id, p_situacao: "erro", p_id_externo: criada ? String(criada.id) : null, p_url: criada?.url ?? null,
      p_mensagem: criada ? `A tarefa foi criada, mas: ${msg}` : msg,
    }).catch(() => {});
    if (criada) return responder(200, { ok: true, nome: criada.name, url: criada.url ?? null, ligada: false, avisos: [msg] });
    return responder(400, { erro: `Não foi possível criar a tarefa: ${msg}` });
  }
}

/** Busca as tarefas na origem, grava no banco (o gatilho liga ao chamado) e diz se o chamado ficou ligado. */
async function gravarNoBanco(banco: Banco, api: ClienteClickUp, ids: string[], chamadoId: string, avisos: string[]): Promise<boolean> {
  try {
    const tarefas = [];
    for (const id of ids) {
      const t = await api.tarefa(id);
      tarefas.push(traduzirTarefa(t));
    }
    await rpc(banco, "gravar_tarefas", { p_origem: "clickup", p_tarefas: tarefas });
  } catch (e) {
    console.error(e);
    avisos.push("A tarefa ainda não entrou no sistema; a sincronização traz em instantes.");
  }
  const { data } = await banco.from("chamados").select("status").eq("id", chamadoId).maybeSingle();
  return data?.status === "tarefa_criada";
}

async function reenviar(banco: Banco, conexao: Conexao, chamadoId: string): Promise<Response> {
  const dados = await rpc<DadosChamado | null>(banco, "dados_criacao_tarefa", { p_chamado: chamadoId });
  if (!dados) return responder(404, { erro: "Chamado não encontrado." });
  if (!dados.tarefa_criada_id_externo) return responder(400, { erro: "Este chamado ainda não tem tarefa criada pelo sistema." });
  try {
    const r = await enviarPrints(conexao.api, dados.tarefa_criada_id_externo, dados, ganchos(banco, chamadoId));
    const avisos = [...r.erros.map((x) => `Print com erro: ${x}`)];
    if (r.pendentes) avisos.push(`${r.pendentes} print(s) não anexado(s): tente de novo.`);
    await rpc(banco, "registrar_criacao_tarefa", {
      p_chamado: chamadoId, p_situacao: "criada", p_mensagem: avisos.join(" · ") || null,
    });
    return responder(200, { ok: true, prints_enviados: r.enviados, prints_pendentes: r.pendentes, avisos });
  } catch (e) {
    const msg = await tratarTokenRecusado(banco, conexao, e);
    return responder(400, { erro: `Não foi possível reenviar os prints: ${msg}` });
  }
}
