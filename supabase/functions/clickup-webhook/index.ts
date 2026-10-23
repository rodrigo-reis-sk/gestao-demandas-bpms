// Edge Function clickup-webhook — recebe os avisos do ClickUp na hora (D4).
//
// 1. Confere a assinatura X-Signature (HMAC SHA-256 do corpo, com o segredo do webhook no Vault).
// 2. Responde 200 logo (o ClickUp não espera) e continua em segundo plano:
//    • tarefa apagada → marca excluida_na_origem (D8);
//    • demais eventos → busca a tarefa completa e grava (tarefa nova só entra se consultor
//      e lista estiverem marcados — a regra está em gravar_tarefas);
//    • grava "quem alterou o quê" em tarefas_historico (D13).
// Esta função não exige login do Supabase (verify_jwt = false em config.toml): a segurança é a assinatura.

import { type Banco, bancoAdmin, emSegundoPlano, mensagemDeErro, responder, rpc } from "../_compartilhado/base.ts";
import { clienteDaSincronizacao, ErroClickUp } from "../_compartilhado/clickup-api.ts";
import { traduzirHistorico, traduzirTarefa } from "../_compartilhado/clickup-traducao.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });
  const banco = bancoAdmin();
  const corpoBruto = await req.text();

  const segredo = await rpc<string | null>(banco, "ler_segredo", { p_nome: "webhook_clickup" }).catch(() => null);
  if (!segredo) return responder(503, { erro: "Webhook ainda não registrado." });
  if (!(await assinaturaValida(segredo, corpoBruto, req.headers.get("X-Signature")))) {
    return responder(401, { erro: "Assinatura inválida." });
  }

  let aviso: any;
  try {
    aviso = JSON.parse(corpoBruto);
  } catch {
    return responder(400, { erro: "Corpo inválido." });
  }
  if (!aviso?.task_id) return responder(200, { ok: true, ignorado: "sem tarefa" });

  await emSegundoPlano(processar(banco, aviso));
  return responder(200, { ok: true });
});

async function assinaturaValida(segredo: string, corpo: string, recebida: string | null): Promise<boolean> {
  if (!recebida) return false;
  const chave = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(segredo), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const assinatura = new Uint8Array(await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(corpo)));
  const esperada = Array.from(assinatura, (b) => b.toString(16).padStart(2, "0")).join("");
  // comparação em tempo constante
  const a = esperada, b = recebida.trim().toLowerCase();
  if (a.length !== b.length) return false;
  let dif = 0;
  for (let i = 0; i < a.length; i++) dif |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return dif === 0;
}

async function processar(banco: Banco, aviso: any) {
  const inicio = new Date().toISOString();
  const idTarefa = String(aviso.task_id);
  const autor = aviso.history_items?.[0]?.user;
  const resumo = { tarefas_lidas: 0, tarefas_novas: 0, tarefas_alteradas: 0 };
  let chamadas = 0;
  let contaId: string | null = null;
  let mensagem = `${aviso.event} ${idTarefa}`;
  let sucesso = true;

  try {
    if (aviso.event === "taskDeleted") {
      const marcou = await rpc<boolean>(banco, "marcar_tarefa_excluida", {
        p_origem: "clickup", p_id_externo: idTarefa,
        p_autor_id_externo: autor?.id ? String(autor.id) : null, p_autor_nome: autor?.username ?? null,
      });
      mensagem += marcou ? " · marcada como excluída" : " · não estava no banco";
    } else {
      const conexao = await clienteDaSincronizacao(banco);
      contaId = conexao.contaId;
      let tarefa: any = null;
      try {
        tarefa = await conexao.cliente.tarefa(idTarefa);
      } catch (e) {
        // sem acesso / não existe mais → trata como apagada
        if (e instanceof ErroClickUp && (e.status === 404 || e.status === 403)) tarefa = null;
        else throw e;
      } finally {
        chamadas = conexao.cliente.chamadas;
      }

      if (!tarefa) {
        await rpc(banco, "marcar_tarefa_excluida", { p_origem: "clickup", p_id_externo: idTarefa });
        mensagem += " · não encontrada na origem";
      } else {
        const r = await rpc<any>(banco, "gravar_tarefas", { p_origem: "clickup", p_tarefas: [traduzirTarefa(tarefa)] });
        Object.assign(resumo, { tarefas_lidas: r.lidas, tarefas_novas: r.novas, tarefas_alteradas: r.alteradas });
        mensagem += r.ignoradas ? " · fora do filtro (lista não marcada)" : r.novas ? " · nova" : " · atualizada";
      }
    }

    const qtd = await rpc<number>(banco, "gravar_historico_tarefa", {
      p_origem: "clickup", p_tarefa_id_externo: idTarefa, p_itens: traduzirHistorico(aviso.history_items),
    });
    if (qtd) mensagem += ` · ${qtd} item(ns) de histórico`;
    if (contaId) await rpc(banco, "registrar_uso_conta", { p_conta_id: contaId });
  } catch (e) {
    console.error(e);
    sucesso = false;
    mensagem += " · ERRO: " + mensagemDeErro(e);
  }

  await banco.from("sincronizacoes").insert({
    sistema: "clickup", tipo: "webhook", iniciado_em: inicio, finalizado_em: new Date().toISOString(),
    sucesso, chamadas_api: chamadas, mensagem: mensagem.slice(0, 2000), ...resumo,
    parametros: { evento: aviso.event, tarefa: idTarefa, autor: autor?.username ?? null },
  });
}
