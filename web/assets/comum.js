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
  ["demandas.html", "Demandas"],
  ["consultores.html", "Consultores"],
  ["sincronizacoes.html", "Log"],
  ["perfil.html", "Meu perfil"],
];

/** Logo + nome do sistema (usado no menu e no login). */
export function marcaHtml() {
  return `<a class="marca" href="index.html"><img src="assets/logo.svg" width="30" height="30" alt="">
    <span class="marca-nome">Demandas<small>BP-MS</small></span></a>`;
}

/** Monta o menu do topo, com o contador de listas a analisar e o seletor de tema. */
export async function montarMenu(usuario) {
  const atual = location.pathname.split("/").pop() || "index.html";
  const topo = document.createElement("nav");
  topo.className = "topo";
  topo.innerHTML = marcaHtml() +
    PAGINAS.map(([href, nome]) => `<a href="${href}" class="pagina ${href === atual ? "ativo" : ""}" data-pagina="${href}">${nome}</a>`).join("") +
    `<span class="direita"><span class="nome-usuario">${esc(usuario.nome)}</span><span id="lugar-tema"></span>
      <button class="pequeno" id="botao-sair">Sair</button></span>`;
  document.body.prepend(topo);
  if (window.criarSeletorTema) $("#lugar-tema").replaceWith(window.criarSeletorTema());
  $("#botao-sair").onclick = sair;
  await atualizarContadores();
}

export async function atualizarContadores() {
  const { data } = await sb.from("vw_pendencias_gestor").select("*").maybeSingle();
  const contador = (pagina, qtd, titulo) => {
    const link = $(`a[data-pagina="${pagina}"]`);
    if (!link) return;
    link.querySelector(".contador")?.remove();
    if (qtd) link.insertAdjacentHTML("beforeend", `<span class="contador" title="${titulo}">${qtd > 999 ? "999+" : qtd}</span>`);
  };
  contador("demandas.html", data?.listas_a_analisar, "Listas do ClickUp a analisar");
  return data;
}

/**
 * Busca TODAS as linhas de uma consulta, de 1000 em 1000 (o Supabase devolve no máximo 1000 por vez).
 *   const linhas = await buscarTudo(() => sb.from("vw_demandas").select("*").order("id"));
 */
export async function buscarTudo(montarConsulta, tamanho = 1000) {
  const todas = [];
  for (let de = 0; ; de += tamanho) {
    const { data, error } = await montarConsulta().range(de, de + tamanho - 1);
    if (error) throw new Error(error.message);
    todas.push(...(data ?? []));
    if (!data || data.length < tamanho) return todas;
  }
}

/** Minutos → "52h", "7h30", "—". */
export function horas(min) {
  if (!min) return "0h";
  const h = Math.floor(min / 60), m = Math.round(min % 60);
  return m ? `${h}h${String(m).padStart(2, "0")}` : `${h}h`;
}

/** Pede uma sincronização agora (o resultado aparece no log). */
export async function sincronizarAgora(tipo = "manual") {
  const r = await chamarFuncao("clickup-sync", { tipo });
  aviso(r.mensagem || "Sincronização iniciada.", "ok");
  return r;
}

// ---------------------------------------------------------------- ordenação das listagens
/**
 * Controle de ordenação por coluna, reaproveitado pelas telas.
 *   const ord = criarOrdenacao("consultores", { campo: "nome", dir: 1 }, redesenhar);
 *   ord.th("nome", "Nome")          → <th> clicável com ▲/▼
 *   ord.aplicar(lista, valores)     → lista ordenada; valores = { campo: (item) => valor }
 * A escolha fica guardada neste navegador (por tela).
 */
export function criarOrdenacao(tela, padrao, aoMudar) {
  const chave = "gestao-bpms-ordem-" + tela;
  let estado = padrao;
  try { estado = JSON.parse(localStorage.getItem(chave)) || padrao; } catch { /* sem armazenamento */ }
  const comparar = (a, b) => {
    if (a === b) return 0;
    if (a === null || a === undefined || a === "") return 1;   // vazios sempre no fim
    if (b === null || b === undefined || b === "") return -1;
    if (typeof a === "number" && typeof b === "number") return a - b;
    if (typeof a === "boolean") return (a ? 0 : 1) - (b ? 0 : 1); // "sim" primeiro
    return String(a).localeCompare(String(b), "pt-BR", { numeric: true, sensitivity: "base" });
  };
  const ord = {
    get estado() { return estado; },
    definir(campo, dir) {
      estado = { campo, dir: dir ?? (estado.campo === campo ? -estado.dir : 1) };
      try { localStorage.setItem(chave, JSON.stringify(estado)); } catch { /* ignora */ }
      aoMudar();
    },
    th(campo, rotulo, classe = "") {
      const ativo = estado.campo === campo;
      const seta = ativo ? (estado.dir === 1 ? "▲" : "▼") : "";
      return `<th class="${classe}" aria-sort="${ativo ? (estado.dir === 1 ? "ascending" : "descending") : "none"}">
        <button type="button" class="th-ordem" data-ordem="${campo}">${rotulo}<span class="seta">${seta}</span></button></th>`;
    },
    aplicar(lista, valores) {
      const pegar = valores[estado.campo];
      if (!pegar) return lista;
      return [...lista].sort((a, b) => {
        const va = pegar(a), vb = pegar(b);
        const vazioA = va === null || va === undefined || va === "", vazioB = vb === null || vb === undefined || vb === "";
        if (vazioA || vazioB) return comparar(va, vb);              // vazios no fim nos dois sentidos
        return comparar(va, vb) * estado.dir;
      });
    },
    /** Liga os cliques dos cabeçalhos dentro de um elemento. */
    ligar(raiz) {
      raiz.addEventListener("click", (ev) => {
        const b = ev.target.closest("button.th-ordem");
        if (b) ord.definir(b.dataset.ordem);
      });
    },
  };
  return ord;
}
