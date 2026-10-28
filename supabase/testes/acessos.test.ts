// Testes da senha temporária dos acessos (D75). Uso: deno test supabase/testes/acessos.test.ts
import { ok as assert } from "node:assert";
import { gerarSenhaTemporaria } from "../functions/_compartilhado/senha.ts";

Deno.test("senha temporária: formato, sem caracteres ambíguos e sem repetir", () => {
  const vistas = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const s = gerarSenhaTemporaria();
    assert(/^[a-zA-Z2-9]{4}-[a-zA-Z2-9]{4}-[a-zA-Z2-9]{4}$/.test(s), s);
    assert(!/[01OIl]/.test(s), `ambíguo: ${s}`);
    vistas.add(s);
  }
  assert(vistas.size === 200, "senhas repetidas");
});
