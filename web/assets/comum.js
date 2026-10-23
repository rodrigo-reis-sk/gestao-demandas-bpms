// Código comum às telas de gestão: conexão com o Supabase, login, menu e utilidades.
// Usa só a chave PÚBLICA (anon). O que cada um pode ver/alterar é decidido pelo RLS no banco.
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";

const cfg = window.CONFIG || {};
export const sb = createClient(cfg.supabaseUrl, cfg.supabaseChavePublica);
export const CONFIG = cfg;

/** Escapa texto para montar HTML com segurança (nomes vêm de fora). */
export function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export const $ = (seletor, raiz = document) => raiz.querySelector(seletor);

/** Data/hora no fuso do MS. */
export function dataHora(v) {
  if (!v) return "—";
  return new Date(v).toLocaleString("pt-BR", { timeZone: "America/Campo_Grande", dateStyle: "short", timeStyle: "short" });
}

/** "há 5 min", "há 2 h"... */
export function haQuanto(v) {
  if (!v) return "nunca";
  const min = Math.round((Date.now() - new Date(v).getTime()) / 60000);
  if (min < 1) return "agora";
  if (min < 60) return `há ${min} min`;
  if (min < 48 * 60) return `há ${Math.round(min / 60)} h`;
  return `há ${Math.round(min / 1440)} dias`;
}

/** Mensagem rápida no canto da tela. tipo: "ok" | "erro" | "" */
export function aviso(msg, tipo = "") {
  let caixa = $("#aviso");
  if (!caixa) { caixa = document.createElement("div"); caixa.id = "aviso"; document.body.append(caixa); }
  const d = document.createElement("div");
  d.className = tipo;
  d.textContent = msg;
  caixa.append(d);
  setTimeout(() => d.remove(), tipo === "erro" ? 9000 : 4500);
}

/** Chama uma Edge Function com o login atual. Devolve o JSON ou lança erro com a mensagem. */
export async function chamarFuncao(nome, corpo = {}) {
  const { data, error } = await sb.functions.invoke(nome, { body: corpo });
  if (error) {
    let msg = error.message;
    try { msg = (await error.context.json()).erro || msg; } catch { /* sem corpo */ }
    throw new Error(msg);
  }
  return data;
}

/**
 * Garante login de gestor. Sem login → vai para login.html.
 * Devolve { sessao, usuario } (usuario = linha de usuarios_sistema).
 */
export async function exigirLogin() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    location.href = "login.html?volta=" + encodeURIComponent(location.pathname.split("/").pop() + location.search);
    throw new Error("sem login");
  }
  const { data: usuario } = await sb.from("usuarios_sistema").select("*").eq("id", session.user.id).maybeSingle();
  if (!usuario || !usuario.ativo || !["admin", "gestor"].includes(usuario.papel)) {
    document.body.innerHTML = `<main><div class="cartao"><h1>Acesso não liberado</h1>
      <p>Você entrou como <b>${esc(session.user.email)}</b>, mas este e-mail ainda não está cadastrado como gestor.
      Peça ao administrador para liberar o acesso.</p><button id="sair">Sair</button></div></main>`;
    $("#sair").onclick = sair;
    throw new Error("sem acesso");
  }
  return { sessao: session, usuario };
}

export async function sair() {
  await sb.auth.signOut();
  location.href = "login.html";
}

const PAGINAS = [
  ["index.html", "Início"],
  ["listas.html", "Listas"],
  ["consultores.html", "Consultores"],
  ["sincronizacoes.html", "Log"],
  ["perfil.html", "Meu perfil"],
];

/** Monta o menu do topo, com o contador de listas a analisar. */
export async function montarMenu(usuario) {
  const atual = location.pathname.split("/").pop() || "index.html";
  const topo = document.createElement("nav");
  topo.className = "topo";
  topo.innerHTML = `<span class="marca">Gestão BP-MS</span>` +
    PAGINAS.map(([href, nome]) => `<a href="${href}" class="${href === atual ? "ativo" : ""}" data-pagina="${href}">${nome}</a>`).join("") +
    `<span class="direita">${esc(usuario.nome)} <button class="pequeno" id="botao-sair">Sair</button></span>`;
  document.body.prepend(topo);
  $("#botao-sair").onclick = sair;
  await atualizarContadores();
}

export async function atualizarContadores() {
  const { data } = await sb.from("vw_pendencias_gestor").select("*").maybeSingle();
  const link = $('a[data-pagina="listas.html"]');
  if (!link) return data;
  link.querySelector(".contador")?.remove();
  if (data?.listas_a_analisar) link.insertAdjacentHTML("beforeend", `<span class="contador" title="Listas a analisar">${data.listas_a_analisar}</span>`);
  return data;
}

/** Pede uma sincronização agora (o resultado aparece no log). */
export async function sincronizarAgora(tipo = "manual") {
  const r = await chamarFuncao("clickup-sync", { tipo });
  aviso(r.mensagem || "Sincronização iniciada.", "ok");
  return r;
}
