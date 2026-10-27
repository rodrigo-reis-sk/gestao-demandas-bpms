// Edge Function formulario — entrada de chamados sem login (fase 3, D54–D60).
// O navegador anônimo NUNCA grava no banco: tudo passa por aqui, com a chave de serviço.
//
// Ações (POST):
//   JSON      { acao: "dados", chave }                    → listas de clientes, consultores e gerentes
//   JSON      { acao: "dados_complemento", token }        → pergunta do gestor e o que já foi enviado
//   FormData  acao=abrir, chave, dados (JSON), site, a0, a1...       → grava o chamado
//   FormData  acao=complementar, token, dados (JSON), site, a0...    → acrescenta passos (D59)
//   JSON      { acao: "portal", token }                   → portal do cliente: chamados do cliente (D62, D63)
//   FormData  acao=abrir_portal, token, dados (JSON), site, a0...    → chamado aberto pelo cliente
//
// Proteções: chave do link (D57, Vault), campo-armadilha "site" (robô preenche → finge que gravou),
// limite de 10 envios por hora por IP (D60), conferência do tipo real dos arquivos e dos tamanhos.
// Os prints vão para o bucket privado "evidencias"; só o gestor logado vê (link temporário).

import { bancoAdmin, CORS, mensagemDeErro, responder, rpc, type Banco } from "../_compartilhado/base.ts";
import {
  caminhoNoBucket, conferirEvidencias, ErroFormulario, ipDaRequisicao, LIMITES,
} from "../_compartilhado/formulario-regras.ts";

const BUCKET = "evidencias";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });

  const banco = bancoAdmin();
  try {
    const tipo = req.headers.get("content-type") ?? "";
    if (tipo.includes("application/json")) {
      const corpo = await req.json().catch(() => ({}));
      if (corpo.acao === "dados") return await dados(banco, corpo.chave);
      if (corpo.acao === "dados_complemento") return await dadosComplemento(banco, corpo.token);
      if (corpo.acao === "portal") return await dadosPortal(banco, corpo.token);
      return responder(400, { erro: "Ação desconhecida." });
    }
    if (tipo.includes("multipart/form-data")) {
      const form = await req.formData();
      const acao = String(form.get("acao") ?? "");
      if (acao === "abrir") return await abrir(req, banco, form);
      if (acao === "complementar") return await complementar(req, banco, form);
      if (acao === "abrir_portal") return await abrirPortal(req, banco, form);
      return responder(400, { erro: "Ação desconhecida." });
    }
    return responder(400, { erro: "Formato não aceito." });
  } catch (e) {
    if (e instanceof ErroFormulario) return responder(e.status, { erro: e.message });
    console.error(e);
    // Erro de validação do banco ("Informe o título..."): 400 com a frase, sem o prefixo técnico
    const msg = mensagemDeErro(e);
    if (/^Banco \((gravar_chamado|gravar_complemento|gravar_chamado_portal)\): /.test(msg)) {
      return responder(400, { erro: msg.replace(/^Banco \([^)]*\): /, "") });
    }
    return responder(500, { erro: "Não foi possível registrar agora. Seu rascunho continua guardado; tente de novo em instantes." });
  }
});

async function chaveValida(banco: Banco, chave: unknown): Promise<boolean> {
  return typeof chave === "string" && chave.length > 0 &&
    await rpc<boolean>(banco, "conferir_chave_formulario", { p_chave: chave });
}

async function dados(banco: Banco, chave: unknown): Promise<Response> {
  if (!(await chaveValida(banco, chave))) {
    return responder(401, { erro: "Link do formulário inválido ou trocado. Peça o link atualizado ao gestor." });
  }
  return responder(200, await rpc(banco, "dados_formulario"));
}

async function dadosComplemento(banco: Banco, token: unknown): Promise<Response> {
  const d = typeof token === "string" && token ? await rpc(banco, "dados_complemento", { p_token: token }) : null;
  if (!d) return responder(410, { erro: "Este link de complemento não vale mais (o chamado já foi respondido ou decidido)." });
  return responder(200, d);
}

/** Lê o JSON do campo "dados" e confere o campo-armadilha e o limite por IP. */
async function conferirEnvio(req: Request, banco: Banco, form: FormData, tipo: string) {
  let dadosForm: Record<string, unknown>;
  try { dadosForm = JSON.parse(String(form.get("dados") ?? "{}")); } catch { throw new ErroFormulario(400, "Dados do formulário ilegíveis."); }
  const robo = String(form.get("site") ?? "").trim() !== "";
  if (!robo) {
    const ip = ipDaRequisicao(req);
    if (!(await rpc<boolean>(banco, "registrar_envio_ip", { p_ip: ip, p_tipo: tipo }))) {
      throw new ErroFormulario(429, "Muitos envios seguidos deste endereço. Espere uma hora e tente de novo.");
    }
  }
  return { dadosForm, robo };
}

async function limites(banco: Banco) {
  const { data } = await banco.from("configuracoes").select("valor").eq("chave", "formulario").maybeSingle();
  const v = (data?.valor ?? {}) as Record<string, number>;
  return {
    ...LIMITES,
    maxArquivos: v.max_arquivos ?? LIMITES.maxArquivos,
    maxTotalBytes: (v.max_total_kb ?? LIMITES.maxTotalBytes / 1024) * 1024,
  };
}

/** Envia os arquivos ao bucket e devolve as evidências no formato do banco. Em erro, apaga o que subiu. */
async function subirArquivos(banco: Banco, chamadoId: string, prefixo: string, form: FormData, evidencias: unknown) {
  const { passos, arquivos } = await conferirEvidencias(evidencias, form, await limites(banco));
  const enviados: string[] = [];
  const saida = [];
  try {
    for (const [i, p] of passos.entries()) {
      const anexos = [];
      for (const [j, campo] of p.arquivos.entries()) {
        const a = arquivos.get(campo)!;
        const caminho = caminhoNoBucket(chamadoId, prefixo, i + 1, j + 1, a.tipo);
        const { error } = await banco.storage.from(BUCKET).upload(caminho, a.bytes, { contentType: a.tipo, upsert: false });
        if (error) throw new Error(`Não foi possível guardar o print: ${error.message}`);
        enviados.push(caminho);
        anexos.push({ caminho, tipo: a.tipo, tamanho: a.tamanho });
      }
      saida.push({ texto: p.texto, anexos });
    }
  } catch (e) {
    await apagar(banco, enviados);
    throw e;
  }
  return { evidencias: saida, enviados };
}

async function apagar(banco: Banco, caminhos: string[]) {
  if (caminhos.length) await banco.storage.from(BUCKET).remove(caminhos).catch(() => {});
}

async function abrir(req: Request, banco: Banco, form: FormData): Promise<Response> {
  if (!(await chaveValida(banco, form.get("chave")))) {
    return responder(401, { erro: "Link do formulário inválido ou trocado. Peça o link atualizado ao gestor." });
  }
  const { dadosForm, robo } = await conferirEnvio(req, banco, form, "abertura");
  if (robo) return responder(200, { ok: true, codigo: null });   // não avisa o robô

  const id = crypto.randomUUID();
  const { evidencias, enviados } = await subirArquivos(banco, id, "", form, dadosForm.evidencias);
  try {
    const r = await rpc<{ id: string; codigo: string }>(banco, "gravar_chamado", {
      p_dados: { ...dadosForm, id, evidencias }, p_ip: ipDaRequisicao(req), p_canal: "formulario_consultor",
    });
    return responder(200, { ok: true, codigo: r.codigo });
  } catch (e) {
    await apagar(banco, enviados);
    throw e;
  }
}

async function complementar(req: Request, banco: Banco, form: FormData): Promise<Response> {
  const token = String(form.get("token") ?? "");
  const atual = token ? await rpc<{ id: string } | null>(banco, "dados_complemento", { p_token: token }) : null;
  if (!atual) return responder(410, { erro: "Este link de complemento não vale mais." });
  const { dadosForm, robo } = await conferirEnvio(req, banco, form, "complemento");
  if (robo) return responder(200, { ok: true, codigo: null });

  // prefixo com data e hora: não colide com os arquivos da abertura nem de outro complemento
  const prefixo = "c" + new Date().toISOString().replace(/\D/g, "").slice(0, 14) + "-";
  const { evidencias, enviados } = await subirArquivos(banco, atual.id, prefixo, form, dadosForm.evidencias);
  try {
    const r = await rpc<{ codigo: string }>(banco, "gravar_complemento", {
      p_token: token, p_evidencias: evidencias, p_resposta: typeof dadosForm.resposta === "string" ? dadosForm.resposta : null,
    });
    return responder(200, { ok: true, codigo: r.codigo });
  } catch (e) {
    await apagar(banco, enviados);
    throw e;
  }
}

// ------------------------------------------------------------------ portal do cliente (D16, D62–D64)
const LINK_PORTAL_INVALIDO = "Este link do portal não vale mais. Peça um link novo à equipe BP-MS.";

async function dadosPortal(banco: Banco, token: unknown): Promise<Response> {
  const d = typeof token === "string" && token ? await rpc(banco, "dados_portal", { p_token: token }) : null;
  if (!d) return responder(410, { erro: LINK_PORTAL_INVALIDO });
  return responder(200, d);
}

async function abrirPortal(req: Request, banco: Banco, form: FormData): Promise<Response> {
  const token = String(form.get("token") ?? "");
  const link = token ? await rpc<{ id: string | null } | null>(banco, "link_portal_valido", { p_token: token }) : null;
  if (!link?.id) return responder(410, { erro: LINK_PORTAL_INVALIDO });
  const { dadosForm, robo } = await conferirEnvio(req, banco, form, "portal");
  if (robo) return responder(200, { ok: true, codigo: null });

  const id = crypto.randomUUID();
  const { evidencias, enviados } = await subirArquivos(banco, id, "", form, dadosForm.evidencias);
  try {
    const r = await rpc<{ codigo: string }>(banco, "gravar_chamado_portal", {
      p_token: token, p_dados: { ...dadosForm, id, evidencias }, p_ip: ipDaRequisicao(req),
    });
    return responder(200, { ok: true, codigo: r.codigo });
  } catch (e) {
    await apagar(banco, enviados);
    throw e;
  }
}
