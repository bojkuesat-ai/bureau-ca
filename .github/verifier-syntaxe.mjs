// Contrôle de syntaxe lancé par GitHub à chaque push (voir workflows/verification.yml).
// - chaque <script> des pages HTML est vérifié avec « node --check » ;
// - chaque fonction Edge (supabase/functions/*/index.ts) est lue par esbuild (syntaxe seulement).
// Une erreur de syntaxe = coche rouge sur le commit et mail à l'auteur du push.
import { readFileSync, writeFileSync, mkdtempSync, readdirSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGES = ["index.html", "caisse/index.html", "billets/index.html"];
const tmp = mkdtempSync(join(tmpdir(), "verif-"));
let erreurs = 0, controles = 0;

for (const page of PAGES) {
  if (!existsSync(page)) continue;
  const html = readFileSync(page, "utf8");
  const re = /<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi;
  let m, n = 0;
  while ((m = re.exec(html))) {
    const attrs = m[1] || "", code = m[2];
    if (/\ssrc=/i.test(attrs) || !code.trim()) continue;
    if (/type=["'](?!module|text\/javascript)/i.test(attrs)) continue;   // JSON, gabarits…
    const ligne = html.slice(0, m.index).split("\n").length;
    const f = join(tmp, `${page.replace(/\W/g, "_")}_${n++}${/type=["']module/i.test(attrs) ? ".mjs" : ".js"}`);
    writeFileSync(f, code);
    controles++;
    try { execFileSync("node", ["--check", f], { stdio: "pipe" }); }
    catch (e) {
      erreurs++;
      console.error(`::error file=${page},line=${ligne}::Erreur de syntaxe dans le script qui commence ligne ${ligne}`);
      console.error(String(e.stderr || e.message).replace(f, `${page} (script ligne ${ligne})`));
    }
  }
}

const esbuild = await import("esbuild");
const dossier = "supabase/functions";
for (const fn of existsSync(dossier) ? readdirSync(dossier) : []) {
  const f = join(dossier, fn, "index.ts");
  if (!existsSync(f)) continue;
  controles++;
  try { await esbuild.transform(readFileSync(f, "utf8"), { loader: "ts", sourcefile: f }); }
  catch (e) { erreurs++; console.error(`::error file=${f}::Erreur de syntaxe`); console.error(e.message); }
}

console.log(`${controles} script(s) contrôlé(s), ${erreurs} erreur(s).`);
process.exit(erreurs ? 1 : 0);
