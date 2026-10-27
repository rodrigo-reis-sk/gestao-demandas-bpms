// Testes das regras do formulário externo (sem banco). Rodado por rodar.sh quando há Deno.
import { deepStrictEqual as assertEquals, ok as assert, rejects } from "node:assert";

/** Confere que a promessa falha com ErroFormulario e com o trecho de mensagem esperado. */
async function assertRejects(fn: () => Promise<unknown>, _classe: unknown, trecho: string) {
  await rejects(fn, (e: Error) => e instanceof ErroFormulario && e.message.includes(trecho));
}
import {
  caminhoNoBucket, conferirEvidencias, ErroFormulario, ipDaRequisicao, tipoPelosBytes,
} from "../functions/_compartilhado/formulario-regras.ts";

const JPG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]);
const PDF = new TextEncoder().encode("%PDF-1.7 ...");
const EXE = new TextEncoder().encode("MZ\x90\x00 programa");
const arq = (b: Uint8Array, nome: string, tipo = "image/png") => new File([b as BlobPart], nome, { type: tipo });

Deno.test("tipo real do arquivo pelos bytes", () => {
  assertEquals(tipoPelosBytes(JPG), "image/jpeg");
  assertEquals(tipoPelosBytes(PNG), "image/png");
  assertEquals(tipoPelosBytes(PDF), "application/pdf");
  assertEquals(tipoPelosBytes(new TextEncoder().encode("RIFF1234WEBPVP8 ")), "image/webp");
  assertEquals(tipoPelosBytes(EXE), null);
});

Deno.test("IP de quem chamou", () => {
  assertEquals(ipDaRequisicao(new Request("http://x", { headers: { "x-forwarded-for": "200.1.2.3, 10.0.0.1" } })), "200.1.2.3");
  assertEquals(ipDaRequisicao(new Request("http://x", { headers: { "x-forwarded-for": "<script>" } })), "desconhecido");
  assertEquals(ipDaRequisicao(new Request("http://x")), "desconhecido");
});

Deno.test("passos e arquivos: ordem, passo vazio e arquivo citado sem envio", async () => {
  const f = new FormData();
  f.append("a0", arq(JPG, "um.png"));        // tipo declarado errado: vale o dos bytes
  f.append("a1", arq(PDF, "dois.pdf", "application/pdf"));
  const r = await conferirEvidencias([
    { texto: "Abrir a tela", arquivos: ["a0", "a1", "a9"] },
    { texto: "   ", arquivos: [] },
    { texto: "", arquivos: ["a0"] },          // mesmo arquivo de novo: passo fica vazio e sai
    { texto: "Fim" },
  ], f);
  assertEquals(r.passos.map((p) => [p.texto, p.arquivos]), [["Abrir a tela", ["a0", "a1"]], ["Fim", []]]);
  assertEquals(r.arquivos.get("a0")?.tipo, "image/jpeg");
  assertEquals(r.arquivos.get("a1")?.tipo, "application/pdf");
});

Deno.test("recusa arquivo que não é imagem nem PDF, grande demais ou acima do total", async () => {
  const f = new FormData();
  f.append("a0", arq(EXE, "virus.png"));
  await assertRejects(() => conferirEvidencias([{ texto: "x", arquivos: ["a0"] }], f), ErroFormulario, "não é imagem");

  const g = new FormData();
  g.append("a0", arq(new Uint8Array(2000).fill(0xff), "grande.jpg"));
  const limites = { maxArquivos: 30, maxArquivoBytes: 1000, maxTotalBytes: 5000, maxPassos: 40 };
  await assertRejects(() => conferirEvidencias([{ texto: "x", arquivos: ["a0"] }], g, limites), ErroFormulario, "passa de");

  const h = new FormData();
  for (let i = 0; i < 3; i++) h.append("a" + i, arq(JPG, i + ".jpg"));
  await assertRejects(() => conferirEvidencias([{ texto: "x", arquivos: ["a0", "a1", "a2"] }], h,
    { ...limites, maxArquivos: 2 }), ErroFormulario, "No máximo 2 arquivos");
});

Deno.test("caminho no bucket", () => {
  assertEquals(caminhoNoBucket("abc", "", 1, 2, "image/jpeg"), "abc/01-02.jpg");
  assert(caminhoNoBucket("abc", "c20261026-", 3, 1, "application/pdf").endsWith("/c20261026-03-01.pdf"));
});
