/* xlsx-mini — écriture de fichiers Excel (.xlsx) sans librairie extérieure.
   Remplace la librairie « xlsx » 0.18.5 (failles connues) pour les seuls usages
   de la Caisse : utils.aoa_to_sheet, utils.json_to_sheet, utils.book_new,
   utils.book_append_sheet, writeFile, et la largeur des colonnes ws["!cols"].
   Écrit des fichiers lisibles par Excel, LibreOffice et Numbers. */
const enc = new TextEncoder();
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(b) { let c = 0xffffffff; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function zip(fichiers) {
  const parts = [], centre = []; let off = 0;
  for (const [nom, txt] of fichiers) {
    const n = enc.encode(nom), d = enc.encode(txt), c = crc32(d);
    const h = new DataView(new ArrayBuffer(30)); h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true); h.setUint32(14, c, true); h.setUint32(18, d.length, true); h.setUint32(22, d.length, true); h.setUint16(26, n.length, true);
    parts.push(new Uint8Array(h.buffer), n, d);
    const z = new DataView(new ArrayBuffer(46)); z.setUint32(0, 0x02014b50, true); z.setUint16(4, 20, true); z.setUint16(6, 20, true); z.setUint16(8, 0x0800, true); z.setUint32(16, c, true); z.setUint32(20, d.length, true); z.setUint32(24, d.length, true); z.setUint16(28, n.length, true); z.setUint32(42, off, true);
    centre.push(new Uint8Array(z.buffer), n); off += 30 + n.length + d.length;
  }
  const tc = centre.reduce((a, b) => a + b.length, 0);
  const f = new DataView(new ArrayBuffer(22)); f.setUint32(0, 0x06054b50, true); f.setUint16(8, fichiers.length, true); f.setUint16(10, fichiers.length, true); f.setUint32(12, tc, true); f.setUint32(16, off, true);
  return new Blob([...parts, ...centre, new Uint8Array(f.buffer)], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
}
const x = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f￾￿]/g, "");
const col = (n) => { let s = ""; n++; while (n) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); } return s; };
function cellule(v, ref) {
  if (v === null || v === undefined || v === "") return "";
  if (typeof v === "number" && isFinite(v)) return `<c r="${ref}"><v>${v}</v></c>`;
  if (typeof v === "boolean") return `<c r="${ref}" t="b"><v>${v ? 1 : 0}</v></c>`;
  if (v instanceof Date) v = isNaN(v) ? "" : v.toISOString().slice(0, 10);
  if (typeof v === "object") { try { v = JSON.stringify(v); } catch (_) { v = String(v); } }
  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${x(String(v).slice(0, 32767))}</t></is></c>`;
}
function feuilleXml(ws) {
  const rows = ws.__lignes || [];
  const cols = Array.isArray(ws["!cols"]) && ws["!cols"].length
    ? "<cols>" + ws["!cols"].map((c, i) => c && (c.wch || c.width) ? `<col min="${i + 1}" max="${i + 1}" width="${Number(c.wch || c.width) + 1}" customWidth="1"/>` : "").join("") + "</cols>" : "";
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">${cols}<sheetData>`
    + rows.map((r, ri) => `<row r="${ri + 1}">` + (r || []).map((v, ci) => cellule(v, col(ci) + (ri + 1))).join("") + `</row>`).join("")
    + `</sheetData></worksheet>`;
}
export const utils = {
  aoa_to_sheet(aoa) { return { __lignes: (aoa || []).map((r) => Array.isArray(r) ? r.slice() : [r]) }; },
  json_to_sheet(liste) {
    const l = Array.isArray(liste) ? liste : [];
    const entetes = [];
    for (const o of l) for (const k of Object.keys(o || {})) if (!entetes.includes(k)) entetes.push(k);
    return { __lignes: [entetes].concat(l.map((o) => entetes.map((k) => (o || {})[k]))) };
  },
  book_new() { return { SheetNames: [], Sheets: {} }; },
  book_append_sheet(wb, ws, nom) {
    let n = String(nom || "Feuille" + (wb.SheetNames.length + 1)).replace(/[\\/?*[\]:]/g, " ").slice(0, 31) || "Feuille";
    let base = n, k = 2; while (wb.SheetNames.includes(n)) n = (base.slice(0, 28) + " " + k++);
    wb.SheetNames.push(n); wb.Sheets[n] = ws;
  },
};
export function write(wb) {
  const noms = wb.SheetNames;
  const f = [
    ["[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>`
      + noms.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("") + `</Types>`],
    ["_rels/.rels", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`],
    ["xl/workbook.xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>`
      + noms.map((n, i) => `<sheet name="${x(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("") + `</sheets></workbook>`],
    ["xl/_rels/workbook.xml.rels", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
      + noms.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("") + `</Relationships>`],
  ];
  noms.forEach((n, i) => f.push([`xl/worksheets/sheet${i + 1}.xml`, feuilleXml(wb.Sheets[n])]));
  return zip(f);
}
export function writeFile(wb, nom) {
  const blob = write(wb), u = URL.createObjectURL(blob), a = document.createElement("a");
  a.href = u; a.download = String(nom || "export.xlsx"); document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(u), 4000);
}
export default { utils, write, writeFile };
