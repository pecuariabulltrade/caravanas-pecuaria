// Prueba de la pestaña Sesiones del portal (index.html) con Supabase simulado.
// node manga-app/tools/test_portal.js
const path = require('path'); const http = require('http'); const fs = require('fs');
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const ROOT = path.join(__dirname, '..', '..');
let fallos = 0; const ok = (c, m) => { if (!c) { fallos++; console.log('FALLA:', m); } else console.log('ok:', m); };

const SES = [{ id: 'a1', inicio: '2026-10-22T13:00:00Z', fin: '2026-10-22T13:40:00Z', destino: 'EXPORTACION', categoria: 'VACA', propietario_id: 1, propietario: 'PEGSA', usuario: 'manga@x', tablet: 'Tab', padron_al: '2026-10-22T12:00:00Z', total: 3, verdes: 2, amarillas: 0, rojas: 1, borradas: 1, manuales: 1, lecturas: 3, recibido_en: '2026-10-22T13:41:00Z' }];
const LECT = [{ sesion_id: 'a1', orden: 1, caravana: '032000000000001', hora: '2026-10-22T13:01:00Z', color: 'verde', motivos: [], fuente: 'baston', propietario: 'PEGSA', categoria: 'VACA', estado: 'activa', dias: 143, borrada: false },
  { sesion_id: 'a1', orden: 2, caravana: '032000000000002', hora: '2026-10-22T13:02:00Z', color: 'rojo', motivos: ['Propietario: BULLTRADE'], fuente: 'manual', propietario: 'BULLTRADE', categoria: 'MACHO', estado: 'activa', dias: 10, borrada: false },
  { sesion_id: 'a1', orden: 3, caravana: '032000000000003', hora: '2026-10-22T13:03:00Z', color: 'verde', motivos: [], fuente: 'baston', propietario: 'PEGSA', categoria: 'VACA', estado: 'activa', dias: 100, borrada: true }];

const FAKE_SUPABASE = `
window.supabase = { createClient: () => {
  const tables = { v_sesiones_manga: ${JSON.stringify(SES)}, sesiones_manga_lecturas: ${JSON.stringify(LECT)}, propietarios: [{id:1,nombre:'PEGSA',activo:true,orden:1},{id:2,nombre:'BULLTRADE',activo:true,orden:2}], sincronizaciones: [], bloqueo_edicion: [{id:1,usuario:null}], v_resumen: [], caravanas: [], v_ingresos_cruce: [], v_egresos_cruce: [], sesiones_manga: ${JSON.stringify(SES)} };
  window.__queries = [];
  function builder(t){ const q = { t, filters: [], head:false };
    const self = new Proxy(q, { get(o, k) {
      if (k === 'then') return (res, rej) => { window.__queries.push({t, filters: o.filters}); let rows = (tables[t]||[]).slice(); rows = rows.filter(r => o.filters.every(f => f.op !== 'eq' || String(r[f.col]) === String(f.val))); return Promise.resolve(o.head ? { count: rows.length, error: null } : { data: rows, error: null }).then(res, rej); };
      if (k === 'select') return (cols, opt) => { if (opt && opt.head) o.head = true; return self; };
      if (['gte','lte','eq','ilike','in','order','limit','range','single'].includes(k)) return (col, val) => { o.filters.push({op:k,col,val}); return self; };
      return o[k];
    }});
    return self; }
  return { from: builder, rpc: async () => ({ data: null, error: null }),
    auth: { onAuthStateChange: cb => setTimeout(() => cb('SIGNED_IN', { user: { email: 'nico@x.com' } }), 0), signInWithPassword: async () => ({}), signOut: async () => ({}) } };
}};`;

(async () => {
  const server = http.createServer((req, res) => { const f = path.join(ROOT, req.url === '/' ? 'index.html' : req.url.split('?')[0]); if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(fs.readFileSync(f)); });
  await new Promise(r => server.listen(8767, r));
  const browser = await chromium.launch(); const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  page.on('pageerror', e => { fallos++; console.log('ERROR JS:', e.message); });
  await page.route('**/*', route => { const u = route.request().url();
    if (u.includes('supabase-js')) return route.fulfill({ status: 200, contentType: 'text/javascript', body: FAKE_SUPABASE });
    if (u.includes('xlsx') ) return route.fulfill({ status: 200, contentType: 'text/javascript', body: 'window.XLSX={utils:{book_new:()=>({}),json_to_sheet:r=>r,book_append_sheet:(wb,ws,n)=>{(wb.s=wb.s||{})[n]=ws}},writeFile:(wb,n)=>{window.__xlsx={wb,n}}}' });
    if (u.includes('jspdf')) return route.fulfill({ status: 200, contentType: 'text/javascript', body: '' });
    return route.continue(); });
  await page.goto('http://localhost:8767/');
  await page.waitForSelector('#t-inicio:not(.hidden)', { timeout: 10000 });
  ok(await page.isVisible('#nav button[data-t=sesiones]'), 'botón Sesiones en la barra');
  ok((await page.textContent('#nSes')) === '1', 'contador de sesiones de hoy');
  await page.click('#nav button[data-t=sesiones]');
  await page.waitForFunction(() => document.querySelectorAll('#sgTabla tr[data-ses]').length === 1, null, { timeout: 5000 });
  ok(true, 'lista una sesión');
  const fila = await page.textContent('#sgTabla tr[data-ses]');
  ok(fila.includes('Exportación') && fila.includes('PEGSA') && fila.includes('3'), 'fila con destino, propietario y total: ' + fila.replace(/\s+/g, ' ').trim());
  await page.click('#sgTabla tr[data-ses]');
  await page.waitForFunction(() => document.querySelectorAll('#sgTabla tr').length >= 5, null, { timeout: 5000 });
  const det = await page.textContent('#sgTabla');
  ok(det.includes('032000000000002') && det.includes('Propietario: BULLTRADE') && det.includes('a mano') && det.includes('(borrada)'), 'detalle con motivos, fuente y borrada');
  await page.selectOption('#sgDest', 'CONSUMO'); await page.click('#sgBuscar');
  await page.waitForFunction(() => document.querySelectorAll('#sgTabla tr[data-ses]').length === 0, null, { timeout: 5000 });
  ok(true, 'filtro por destino aplica');
  await page.selectOption('#sgDest', ''); await page.click('#sgBuscar');
  await page.waitForFunction(() => document.querySelectorAll('#sgTabla tr[data-ses]').length === 1, null, { timeout: 5000 });
  await page.click('#sgExcel'); await page.waitForTimeout(300);
  const x = await page.evaluate(() => window.__xlsx && { n: window.__xlsx.n, hojas: Object.keys(window.__xlsx.wb.s), lect: window.__xlsx.wb.s.Lecturas.length });
  ok(x && x.hojas.join() === 'Sesiones,Lecturas' && x.lect === 3, 'Excel con dos hojas: ' + JSON.stringify(x));
  await page.screenshot({ path: path.join(__dirname, 'captura_portal_sesiones.png') });
  await browser.close(); server.close();
  console.log(fallos ? `${fallos} fallas` : 'Pruebas del portal OK');
  process.exit(fallos ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
