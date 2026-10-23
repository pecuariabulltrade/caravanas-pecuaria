// Lector de Manga — lógica de la app (corre dentro del WebView de Android; window.Android es el puente nativo)
'use strict';

const CFG = {
  SUPABASE_URL: 'https://xqcipsnyvnozkvehpzsk.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_3KDY3ojS6VUHhQCUrfxKQg_JRUS7PMu',
  ESTADOS_PADRON: ['activa', 'salida', 'baja', 'anulada'],
  DEDUPE_MS: 3000,          // la balanza puede repetir la misma caravana varias veces seguidas
  ESPERA_BALANZA_MS: 15000
};

const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const hoyISO = () => { const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); };
const fmtTs = t => t ? new Date(t).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }) : '';
const fmtHora = t => t ? new Date(t).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }) : '';
const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }));

// ---------- puente nativo (con reemplazo para probar en un navegador) ----------
const A = window.Android || {
  version: () => 'web', deviceName: () => 'navegador', online: () => navigator.onLine,
  hasBluetoothPermission: () => true, requestBluetoothPermission: () => setTimeout(() => Manga.onPermission(true), 10),
  bluetoothEnabled: () => false, pairedDevices: () => '[]', connectBluetooth: () => Manga.onLog('(navegador) sin Bluetooth'),
  usbDevices: () => '[]', setUsbBaud: () => {}, connectUsb: () => Manga.onLog('(navegador) sin USB'),
  disconnect: () => {}, reconnect: () => {}, status: () => '{"connected":false,"via":"","device":"","error":""}',
  openBluetoothSettings: () => {}, vibrate: () => {}, beep: () => {}
};

// ---------- almacenamiento ----------
const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { toast('No se pudo guardar: ' + e.message, 4000); } },
  del(k) { try { localStorage.removeItem(k); } catch (e) {} }
};
let cfg = store.get('cfg', { email: '', password: '', modo: 'bluetooth', btAddress: '', btName: '', bastonAddress: '', bastonName: '', baud: 9600 });
// Qué equipo manda las caravanas según el modo: 'bluetooth' = balanza XR5000, 'baston' = bastón XRS2i directo, 'usb' = balanza por cable
const MODOS = { bluetooth: { nombre: 'Balanza XR5000', ayuda: 'Primero emparejá la balanza desde los ajustes Bluetooth de la tablet (en el XR5000: Bluetooth encendido y visible).' }, baston: { nombre: 'Bastón XRS2i', ayuda: 'Primero emparejá el bastón desde los ajustes Bluetooth de la tablet (en el XRS2i: Settings → Bluetooth en Manual; Advanced: Connect Mode Default y Output Default). El bastón se conecta a un solo equipo a la vez: si está conectado a la balanza, no puede estar conectado a la tablet.' }, usb: { nombre: 'Balanza XR5000 (cable)', ayuda: '' } };
function modoInfo() { return MODOS[cfg.modo] || MODOS.bluetooth; }
function direccionBt() { return cfg.modo === 'baston' ? cfg.bastonAddress : cfg.btAddress; }
function nombreBt() { return cfg.modo === 'baston' ? cfg.bastonName : cfg.btName; }
let padron = store.get('padron', null);        // {al, n, rows:{numero:[estado,propietario,categoria,fecha_alta,fecha_baja]}, props:[...]}
let sesion = store.get('sesion', null);        // sesión abierta
let pendientes = store.get('pendientes', []);  // sesiones cerradas sin enviar
let conn = { connected: false, via: '', device: '', error: '' };
let sufijos = null;                            // Map sufijo6 -> [numeros]
let logLines = [];
let ultima = { num: '', t: 0 };

function toast(m, ms = 2500) { const t = $('toast'); t.textContent = m; t.style.display = 'block'; clearTimeout(t._x); t._x = setTimeout(() => t.style.display = 'none', ms); }
function msg(el, kind, text) { $(el).innerHTML = `<div class="msg ${kind}">${esc(text)}</div>`; }
function show(id) { document.querySelectorAll('.screen').forEach(s => s.classList.toggle('on', s.id === 's-' + id)); }
function modal(html, botones) {
  const box = $('modalBox'); box.innerHTML = html + '<div class="row">' + botones.map((b, i) => `<button class="b ${b.cls || ''}" data-i="${i}">${esc(b.txt)}</button>`).join('') + '</div>';
  box.onclick = e => { const b = e.target.closest('button[data-i]'); if (!b) return; $('modal').classList.remove('on'); (botones[+b.dataset.i].fn || (() => {}))(); };
  $('modal').classList.add('on');
}
function confirmar(html, ok, txtOk = 'Sí', cls = 'd') { modal(html, [{ txt: 'No' }, { txt: txtOk, cls, fn: ok }]); }

// ---------- Supabase (REST, sin librerías) ----------
let token = null;   // {access_token, exp}
async function login() {
  if (!cfg.email || !cfg.password) throw new Error('Falta cargar el usuario en Configuración');
  const r = await fetch(`${CFG.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: CFG.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: cfg.email, password: cfg.password })
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error_description || j.msg || j.message || 'Usuario o contraseña incorrectos');
  token = { access_token: j.access_token, exp: Date.now() + (j.expires_in || 3600) * 1000 - 60000 };
  return token;
}
async function auth() { if (!token || Date.now() > token.exp) await login(); return token.access_token; }
async function api(path, opts = {}) {
  const t = await auth();
  const r = await fetch(`${CFG.SUPABASE_URL}/rest/v1/${path}`, Object.assign({ headers: { apikey: CFG.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' } }, opts));
  const txt = await r.text();
  let j = null; try { j = txt ? JSON.parse(txt) : null; } catch (e) { j = txt; }
  if (!r.ok) throw new Error((j && (j.message || j.hint || j.error)) || ('Error ' + r.status));
  return j;
}
async function descargarPadron(onProgreso) {
  const props = await api('propietarios?select=id,nombre,activo,orden&order=orden');
  const rows = {}; let n = 0, offset = 0;
  const cols = 'numero,estado,propietario,categoria,fecha_alta,fecha_baja';
  for (;;) {
    const page = await api(`v_caravanas?select=${cols}&estado=in.(${CFG.ESTADOS_PADRON.join(',')})&order=numero&limit=1000&offset=${offset}`);
    for (const r of page) { rows[r.numero] = [r.estado, r.propietario || '', r.categoria || '', r.fecha_alta || '', r.fecha_baja || '']; n++; }
    if (onProgreso) onProgreso(n);
    if (page.length < 1000) break;
    offset += 1000;
  }
  if (!n) throw new Error('El padrón vino vacío');
  padron = { al: new Date().toISOString(), n, rows, props: props.filter(p => p.activo !== false).map(p => ({ id: p.id, nombre: p.nombre })) };
  store.set('padron', padron);
  sufijos = null;
  return padron;
}
function fila(numero) {
  const r = padron && padron.rows[numero];
  return r ? { estado: r[0], propietario: r[1], categoria: r[2], fecha_alta: r[3], fecha_baja: r[4] } : null;
}
function indiceSufijos() {
  if (sufijos || !padron) return;
  sufijos = new Map();
  for (const num of Object.keys(padron.rows)) { const k = num.slice(-6); if (!sufijos.has(k)) sufijos.set(k, []); sufijos.get(k).push(num); }
}
function buscarManual(txt) {
  const t = Reglas.normalizarManual(txt);
  if (!padron || t.length < 6) return [];
  if (padron.rows[t]) return [t];
  if (t.length === 6) { indiceSufijos(); return (sufijos.get(t) || []).slice(); }
  return Object.keys(padron.rows).filter(n => n.endsWith(t));
}
async function enviarSesion(s) {
  const lect = s.lecturas.map(l => ({ orden: l.orden, caravana: l.caravana, hora: l.hora, color: l.color, motivos: l.motivos, fuente: l.fuente, propietario: l.propietario, categoria: l.categoria, estado: l.estado, dias: l.dias, borrada: !!l.borrada, borrada_en: l.borrada_en || null }));
  const c = contar(s);
  const ses = { id: s.id, inicio: s.inicio, fin: s.fin, destino: s.destino, categoria: s.categoria, propietario_id: s.propietario_id, propietario: s.propietario, usuario: cfg.email, tablet: A.deviceName(), padron_al: s.padron_al, version_app: A.version(), total: c.total, verdes: c.verdes, amarillas: c.amarillas, rojas: c.rojas, borradas: c.borradas };
  return api('rpc/recibir_sesion_manga', { method: 'POST', body: JSON.stringify({ p_sesion: ses, p_lecturas: lect }) });
}
async function enviarPendientes() {
  let ok = 0, err = null;
  for (const s of pendientes.slice()) {
    try { await enviarSesion(s); pendientes = pendientes.filter(x => x.id !== s.id); store.set('pendientes', pendientes); ok++; }
    catch (e) { err = e; }
  }
  return { ok, err, quedan: pendientes.length };
}

// ---------- sesión ----------
function contar(s) {
  const c = { total: 0, verdes: 0, amarillas: 0, rojas: 0, borradas: 0 };
  for (const l of s.lecturas) { if (l.borrada) { c.borradas++; continue; } c.total++; if (l.color === 'verde') c.verdes++; else if (l.color === 'amarillo') c.amarillas++; else c.rojas++; }
  return c;
}
function guardarSesion() { if (sesion) store.set('sesion', sesion); else store.del('sesion'); }
function procesar(numero, fuente) {
  if (!sesion) return;
  const ahora = Date.now();
  if (fuente === 'baston' && numero === ultima.num && ahora - ultima.t < CFG.DEDUPE_MS) { ultima.t = ahora; return; }
  ultima = { num: numero, t: ahora };
  const f = fila(numero);
  const yaLeida = sesion.lecturas.some(l => !l.borrada && l.caravana === numero);
  const r = Reglas.evaluar(f, sesion, yaLeida, hoyISO());
  const l = { orden: sesion.lecturas.length + 1, caravana: numero, hora: new Date().toISOString(), color: r.color, motivos: r.motivos, fuente,
    propietario: r.propietario, categoria: r.categoria, estado: r.estado, dias: r.dias, borrada: false };
  sesion.lecturas.push(l);
  guardarSesion();
  mostrarLectura(l);
  if (r.color === 'rojo') { A.beep('rojo'); A.vibrate(700); }
  else if (r.color === 'amarillo') { A.beep('amarillo'); A.vibrate(250); }
  else A.beep('verde');
}
function mostrarLectura(l) {
  const s = $('s-read'); s.classList.remove('c-verde', 'c-amarillo', 'c-rojo'); s.classList.add('c-' + l.color);
  $('rdEsperando').classList.add('hidden'); $('rdBox').classList.remove('hidden');
  $('rdNum').textContent = l.caravana;
  $('rdBig').textContent = l.color === 'verde' ? 'OK' : l.color === 'amarillo' ? 'NO ESTÁ' : 'NO';
  $('rdElegir').classList.add('hidden');
  const det = [];
  if (l.propietario) det.push(l.propietario);
  if (l.categoria) det.push(l.categoria);
  if (l.dias != null) det.push(l.dias + ' días en SENASA');
  if (l.estado && l.estado !== 'activa') det.push('estado: ' + l.estado);
  $('rdDet').textContent = det.join(' · ');
  $('rdMot').textContent = l.motivos.join(' — ');
  $('rdFuente').textContent = (l.fuente === 'manual' ? 'Cargada a mano · ' : '') + fmtHora(l.hora);
  pintarContadores();
}
function pintarContadores() {
  const c = sesion ? contar(sesion) : { total: 0, verdes: 0, amarillas: 0, rojas: 0 };
  $('cT').textContent = c.total; $('cV').textContent = c.verdes; $('cA').textContent = c.amarillas; $('cR').textContent = c.rojas;
  $('mT').textContent = c.total; $('mV').textContent = c.verdes; $('mA').textContent = c.amarillas; $('mR').textContent = c.rojas;
  if (sesion) $('rdSes').textContent = `${sesion.destino === 'EXPORTACION' ? 'Exportación' : 'Consumo'} · ${sesion.categoria} · ${sesion.propietario}`;
}
function abrirLectura() {
  if (sesion && sesion.modo === 'manual') return abrirManual();
  show('read'); pintarContadores(); pintarConn();
  const ult = sesion.lecturas.filter(l => !l.borrada).slice(-1)[0];
  if (ult) mostrarLectura(ult); else { $('s-read').classList.remove('c-verde', 'c-amarillo', 'c-rojo'); $('rdEsperando').classList.remove('hidden'); $('rdBox').classList.add('hidden'); }
}

// ---------- conexión con la balanza ----------
function pintarConn() {
  const eq = cfg.modo === 'baston' ? 'Bastón' : 'Balanza';
  const t = conn.connected ? `${eq}: ${conn.via === 'usb' ? 'USB' : 'Bluetooth'} ✓` : (conn.error ? `${eq}: sin conexión` : `${eq}: —`);
  const cls = 'pill ' + (conn.connected ? 'ok' : 'bad');
  ['homeConn', 'rdConn', 'dgConn'].forEach(id => { $(id).textContent = t; $(id).className = cls; $(id).title = conn.error || conn.device; });
}
function conectarBalanza() {
  if (cfg.modo === 'usb') { A.setUsbBaud(+cfg.baud || 9600); A.connectUsb(); return true; }
  if (!direccionBt()) { Manga.onLog(`No hay ${cfg.modo === 'baston' ? 'bastón' : 'balanza'} Bluetooth elegido en Configuración`); return false; }
  if (!A.hasBluetoothPermission()) { A.requestBluetoothPermission(); return true; }
  A.connectBluetooth(direccionBt()); return true;
}
function esperarConexion(ms) {
  return new Promise(res => { const t0 = Date.now(); const iv = setInterval(() => { if (conn.connected || Date.now() - t0 > ms) { clearInterval(iv); res(conn.connected); } }, 300); });
}

// Lo que llama Android
window.Manga = {
  onLine(line) {
    addLog('< ' + line);
    const num = Reglas.extraerCaravana(line);
    if (num) return procesar(num, 'baston');
    const parcial = Reglas.extraerParcial(line);
    if (parcial && sesion) procesarParcial(parcial);
  },
  onStatus(st) { conn = st || conn; pintarConn(); },
  onLog(t) { addLog(t); },
  onPermission(ok) { if (ok && cfg.modo !== 'usb' && direccionBt()) A.connectBluetooth(direccionBt()); else if (!ok) toast('Sin permiso de Bluetooth no se puede conectar el lector', 4000); },
  onResume() { try { conn = JSON.parse(A.status()); } catch (e) {} pintarConn(); if (sesion && !conn.connected && cfg.modo !== 'usb') A.reconnect(); }
};
function addLog(t) { logLines.push(new Date().toLocaleTimeString('es-AR') + ' ' + t); if (logLines.length > 300) logLines.shift(); if ($('s-diag').classList.contains('on')) pintarLog(); }
function pintarLog() { const el = $('dgLog'); el.textContent = logLines.join('\n'); el.scrollTop = el.scrollHeight; }

// ---------- pantallas ----------
function irHome() {
  show('home');
  $('homeInfo').innerHTML = (padron ? `Padrón: ${padron.n.toLocaleString('es-AR')} caravanas, actualizado el ${fmtTs(padron.al)}` : 'Todavía no se descargó el padrón') +
    `<br>Versión ${esc(A.version())} · ${esc(cfg.modo === 'usb' ? 'balanza por cable USB' : (nombreBt() ? modoInfo().nombre + ' (' + nombreBt() + ')' : modoInfo().nombre + ' sin elegir'))}`;
  $('homePend').innerHTML = pendientes.length ? `<div class="msg warn">${pendientes.length} sesión(es) cerrada(s) pendiente(s) de envío. <button class="b" id="homeEnviar">Reenviar ahora</button></div>` : '';
  if (pendientes.length) $('homeEnviar').onclick = async () => { try { const r = await enviarPendientes(); toast(r.ok ? `Enviadas ${r.ok}` : ('No se pudo enviar: ' + (r.err && r.err.message))); } catch (e) { toast(e.message); } irHome(); };
  $('homeAbierta').innerHTML = sesion ? `<div class="msg warn">Hay una sesión abierta (${esc(sesion.destino)} · ${esc(sesion.categoria)} · ${esc(sesion.propietario)}, ${contar(sesion).total} lecturas). <button class="b" id="homeSeguir">Continuar</button> <button class="b" id="homeDescartar">Descartar</button></div>` : '';
  if (sesion) {
    $('homeSeguir').onclick = () => { if (sesion.modo !== 'manual') conectarBalanza(); abrirLectura(); };
    $('homeDescartar').onclick = () => confirmar('<h2>¿Descartar la sesión abierta?</h2><p>Se pierden sus lecturas; no se envía al portal.</p>', () => { sesion = null; guardarSesion(); irHome(); }, 'Descartar');
  }
  pintarConn();
}
$('btnIniciar').onclick = () => { if (!cfg.email) { show('setup'); pintarSetup(); return; } sinBalanza = false; chequeo(); };
$('btnSinConexion').onclick = () => { if (!cfg.email) { show('setup'); pintarSetup(); return; } sinBalanza = true; chequeo(); };
$('homeCfg').onclick = () => { show('setup'); pintarSetup(); };

// --- chequeo ---
function ck(i, estado, txt) { const el = $('ck' + i); el.className = 'ic ' + estado; el.textContent = estado === 'ok' ? '✓' : estado === 'bad' ? '✗' : estado === 'warn' ? '!' : estado === 'run' ? '…' : i; $('ck' + i + 't').textContent = txt || ''; }
async function chequeo() {
  show('check'); $('ckContinuar').disabled = true; $('ckContinuar').textContent = 'Continuar';
  [1, 2, 3, 4].forEach(i => ck(i, '', ''));
  // 1. lector (balanza o bastón)
  let bal = false;
  $('ck1h').textContent = sinBalanza ? 'Lector de caravanas' : modoInfo().nombre;
  if (sinBalanza) ck(1, 'ok', 'Sin lector: las caravanas se cargan a mano');
  else {
    ck(1, 'run', 'Conectando…');
    if (conn.connected) bal = true;
    else if (conectarBalanza()) bal = await esperarConexion(CFG.ESPERA_BALANZA_MS);
    ck(1, bal ? 'ok' : 'bad', bal ? `Conectado por ${conn.via === 'usb' ? 'cable USB' : 'Bluetooth'} (${conn.device})` : (conn.error || `No se pudo conectar. Revisá que ${cfg.modo === 'baston' ? 'el bastón esté encendido, emparejado y no conectado a la balanza' : 'la balanza esté encendida y emparejada'}.`));
  }
  // 2. internet
  ck(2, 'run', 'Comprobando…');
  let online = false; try { online = !!A.online(); } catch (e) { online = navigator.onLine; }
  ck(2, online ? 'ok' : 'warn', online ? 'Hay conexión' : 'Sin internet: se usa la última copia del padrón');
  // 3. padrón
  let padOk = false;
  if (online) {
    ck(3, 'run', 'Descargando el padrón…');
    try { await descargarPadron(n => ck(3, 'run', `Descargando el padrón… ${n.toLocaleString('es-AR')}`)); padOk = true; ck(3, 'ok', `Padrón actualizado al ${fmtTs(padron.al)} (${padron.n.toLocaleString('es-AR')} caravanas)`); }
    catch (e) { if (padron) { padOk = true; ck(3, 'warn', `No se pudo actualizar (${e.message}). Se usa la copia del ${fmtTs(padron.al)}`); } else ck(3, 'bad', 'No se pudo descargar el padrón: ' + e.message); }
  } else if (padron) { padOk = true; ck(3, 'warn', `Copia guardada del ${fmtTs(padron.al)} (${padron.n.toLocaleString('es-AR')} caravanas)`); }
  else ck(3, 'bad', 'No hay padrón guardado: hace falta internet la primera vez');
  // 4. pendientes
  if (!pendientes.length) ck(4, 'ok', 'No hay sesiones pendientes');
  else if (!online) ck(4, 'warn', `${pendientes.length} pendiente(s); se envían cuando haya internet`);
  else { ck(4, 'run', 'Enviando…'); const r = await enviarPendientes(); ck(4, r.quedan ? 'warn' : 'ok', r.quedan ? `Quedan ${r.quedan} sin enviar: ${r.err && r.err.message}` : `Enviadas ${r.ok}`); }
  $('ckContinuar').disabled = !padOk;
  $('ckContinuar').textContent = sinBalanza ? 'Continuar (carga a mano)' : bal ? 'Continuar' : 'Seguir solo con carga manual';
}
$('ckReintentar').onclick = chequeo;
$('ckVolver').onclick = irHome;
$('ckContinuar').onclick = () => pintarSelect();

// --- selección ---
let sel = { destino: '', categoria: '', propietario: '', propietario_id: null };
let sinBalanza = false;   // sesión 'Trabajar sin conexión': todo a mano
function pintarSelect() {
  sel = { destino: '', categoria: '', propietario: '', propietario_id: null };
  $('selProp').innerHTML = (padron.props || []).map(p => `<button class="b" data-v="${esc(p.nombre)}" data-id="${p.id}">${esc(p.nombre)}</button>`).join('');
  document.querySelectorAll('#selDestino .b, #selCat .b, #selProp .b').forEach(b => b.classList.remove('sel'));
  $('selEmpezar').disabled = true;
  show('select');
}
function elegir(grupo, e) {
  const b = e.target.closest('button'); if (!b) return;
  $(grupo).querySelectorAll('.b').forEach(x => x.classList.toggle('sel', x === b));
  if (grupo === 'selDestino') sel.destino = b.dataset.v; else if (grupo === 'selCat') sel.categoria = b.dataset.v; else { sel.propietario = b.dataset.v; sel.propietario_id = +b.dataset.id; }
  $('selEmpezar').disabled = !(sel.destino && sel.categoria && sel.propietario);
}
['selDestino', 'selCat', 'selProp'].forEach(g => $(g).onclick = e => elegir(g, e));
$('selVolver').onclick = irHome;
$('selEmpezar').onclick = () => {
  sesion = { id: uuid(), inicio: new Date().toISOString(), fin: null, destino: sel.destino, categoria: sel.categoria, propietario: sel.propietario, propietario_id: sel.propietario_id, padron_al: padron.al, modo: sinBalanza ? 'manual' : 'balanza', lecturas: [] };
  guardarSesion(); ultima = { num: '', t: 0 };
  abrirLectura();
};

// --- lectura ---
$('rdManual').onclick = abrirManual;
$('rdLista').onclick = () => { lsF = ''; pintarLista(); show('list'); };
$('rdCerrar').onclick = () => { pintarCierre(); show('close'); };
function descartarSesion() {
  const n = sesion ? contar(sesion).total : 0;
  confirmar(`<h2>¿Descartar esta sesión?</h2><p>Se vuelve al inicio sin guardar ni enviar nada al portal${n ? ` (se pierden ${n} lecturas)` : ''}.</p>`, () => { sesion = null; guardarSesion(); toast('Sesión descartada'); irHome(); }, 'Descartar');
}
$('rdDescartar').onclick = descartarSesion;

// Dígitos parciales que vienen de la balanza (tecleados en el IDE): se buscan por terminación como en la carga a mano
function procesarParcial(dig) {
  const r = buscarManual(dig);
  if (r.length === 1) return procesar(r[0], 'manual');
  if (!r.length) {
    // no hay ninguna que termine así: se registra tal cual como "no está en el padrón" (amarillo)
    return procesar(dig, 'manual');
  }
  const propSes = sesion.propietario;
  r.sort((a, b) => ((fila(b).propietario === propSes) - (fila(a).propietario === propSes)) || a.localeCompare(b));
  A.beep('amarillo');
  if (sesion.modo === 'manual') { mn = dig; pintarManual(); buscarYProcesar(); return; }
  const box = $('rdElegir');
  box.innerHTML = `<div class="msg warn" style="font-size:18px">${r.length} caravanas terminan en ${esc(dig)}. Tocá la correcta:</div><div class="lista">` +
    r.slice(0, 30).map(n => { const f = fila(n); return `<button class="b it" data-n="${n}" style="width:100%;justify-content:flex-start;text-align:left"><span class="n">${n}</span><span class="d">${esc(f.propietario)} · ${esc(f.categoria)} · ${esc(f.estado)}</span></button>`; }).join('') +
    `</div><button class="b" id="rdElegirCancelar" style="margin-top:8px">Cancelar</button>`;
  box.classList.remove('hidden');
  $('rdEsperando').classList.add('hidden'); $('rdBox').classList.add('hidden');
  $('s-read').classList.remove('c-verde', 'c-amarillo', 'c-rojo');
  box.onclick = e => { const c = e.target.closest('#rdElegirCancelar'); if (c) { box.classList.add('hidden'); abrirLectura(); return; } const b = e.target.closest('button[data-n]'); if (!b) return; box.classList.add('hidden'); procesar(b.dataset.n, 'manual'); };
}

// "No guardar esta caravana": quita la última lectura (solo mientras no se haya leído la siguiente)
function noGuardarUltima() {
  if (!sesion || !sesion.lecturas.length) return;
  const ult = sesion.lecturas[sesion.lecturas.length - 1];
  if (ult.borrada) return toast('La última lectura ya está borrada');
  sesion.lecturas.pop(); guardarSesion();
  ultima = { num: '', t: 0 };
  toast(`${ult.caravana} no se guardó`);
  abrirLectura();
}
$('rdNoGuardar').onclick = noGuardarUltima;
$('mnNoGuardar').onclick = noGuardarUltima;

// --- manual ---
let mn = '';
function pintarManual() { $('mnDisp').innerHTML = mn ? esc(mn) : '&nbsp;'; }
const COLOR_FONDO = { verde: 'var(--verde)', amarillo: 'var(--amarillo)', rojo: 'var(--rojo)' };
function pintarBanner(l) {
  const b = $('mnBanner');
  if (!l) { b.classList.add('hidden'); return; }
  b.classList.remove('hidden'); b.style.background = COLOR_FONDO[l.color];
  $('mnBNum').textContent = l.caravana;
  $('mnBBig').textContent = l.color === 'verde' ? 'OK' : l.color === 'amarillo' ? 'NO ESTÁ' : 'NO';
  const det = []; if (l.propietario) det.push(l.propietario); if (l.categoria) det.push(l.categoria); if (l.dias != null) det.push(l.dias + ' días en SENASA'); if (l.estado && l.estado !== 'activa') det.push('estado: ' + l.estado);
  $('mnBDet').textContent = det.join(' · '); $('mnBMot').textContent = l.motivos.join(' — ');
}
function abrirManual() {
  const manual = sesion && sesion.modo === 'manual';
  mn = ''; pintarManual(); $('mnRes').innerHTML = ''; pintarContadores();
  $('mnTitulo').textContent = manual ? `Sin conexión · ${sesion.destino === 'EXPORTACION' ? 'Exportación' : 'Consumo'} · ${sesion.categoria} · ${sesion.propietario}` : 'Ingresar a mano';
  $('mnVolver').classList.toggle('hidden', manual); $('mnBottom').classList.toggle('hidden', !manual);
  pintarBanner(manual ? sesion.lecturas.filter(l => !l.borrada).slice(-1)[0] : null);
  show('manual');
}
function despuesDeManual(numero) {
  procesar(numero, 'manual'); mn = '';
  if (sesion.modo === 'manual') { pintarManual(); $('mnRes').innerHTML = ''; pintarContadores(); pintarBanner(sesion.lecturas.slice(-1)[0]); }
  else abrirLectura();
}
document.querySelector('.pad').onclick = e => {
  const b = e.target.closest('button'); if (!b) return; const k = b.dataset.k;
  if (k === 'C') mn = mn.slice(0, -1);
  else if (k === 'OK') return buscarYProcesar();
  else if (mn.length < 15) mn += k;
  pintarManual();
};
function buscarYProcesar() {
  if (mn.length < 6) return toast('Tipeá por lo menos 6 dígitos');
  const r = buscarManual(mn);
  if (r.length === 1) return despuesDeManual(r[0]);
  if (!r.length) {
    // no está en el padrón: se registra igual (rojo) si tiene 15 dígitos; si no, aviso
    if (mn.length === 15) return despuesDeManual(mn);
    $('mnRes').innerHTML = `<div class="msg err">Ninguna caravana del padrón termina en ${esc(mn)}. Si tenés el número completo (15 dígitos), tipealo para registrarla igual.</div>`; return;
  }
  const propSes = sesion.propietario;
  r.sort((a, b) => ((fila(b).propietario === propSes) - (fila(a).propietario === propSes)) || a.localeCompare(b));
  $('mnRes').innerHTML = `<div class="msg warn">${r.length} caravanas terminan en ${esc(mn)}. Tocá la correcta:</div><div class="lista">` +
    r.slice(0, 30).map(n => { const f = fila(n); return `<button class="b it" data-n="${n}" style="width:100%;justify-content:flex-start;text-align:left"><span class="n">${n}</span><span class="d">${esc(f.propietario)} · ${esc(f.categoria)} · ${esc(f.estado)}</span></button>`; }).join('') + '</div>';
  $('mnRes').onclick = e => { const b = e.target.closest('button[data-n]'); if (!b) return; despuesDeManual(b.dataset.n); };
}
$('mnVolver').onclick = () => { show('read'); pintarContadores(); pintarConn(); };
$('mnLista').onclick = () => { lsF = ''; pintarLista(); show('list'); };
$('mnCerrar').onclick = () => { pintarCierre(); show('close'); };
$('mnDescartar').onclick = descartarSesion;

// --- listado ---
let lsF = '';
$('lsFiltro').onclick = e => { const b = e.target.closest('button'); if (!b) return; lsF = b.dataset.f; $('lsFiltro').querySelectorAll('.b').forEach(x => x.classList.toggle('sel', x === b)); pintarLista(); };
function pintarLista() {
  const rows = sesion.lecturas.slice().reverse().filter(l => lsF === '' ? !l.borrada : lsF === 'borrada' ? l.borrada : (!l.borrada && l.color === lsF));
  $('lsBox').innerHTML = rows.length ? rows.map(l => `<div class="it ${l.color} ${l.borrada ? 'borrada' : ''}"><span class="n">${l.caravana}</span><span class="d">${fmtHora(l.hora)} · ${esc(l.propietario || '—')} · ${esc(l.categoria || '—')}${l.dias != null ? ' · ' + l.dias + ' d' : ''}${l.fuente === 'manual' ? ' · a mano' : ''}${l.motivos.length ? '<br>' + esc(l.motivos.join(' — ')) : ''}</span>${l.borrada ? '' : `<button class="b" data-del="${l.orden}">Borrar</button>`}</div>`).join('') : '<p class="muted">No hay lecturas.</p>';
}
$('lsBox').onclick = e => {
  const b = e.target.closest('button[data-del]'); if (!b) return;
  const l = sesion.lecturas.find(x => x.orden === +b.dataset.del); if (!l) return;
  confirmar(`<h2>¿Borrar ${l.caravana} de la sesión?</h2><p>Queda registrada como borrada en el portal.</p>`, () => { l.borrada = true; l.borrada_en = new Date().toISOString(); guardarSesion(); pintarLista(); pintarContadores(); }, 'Borrar');
};
$('lsVolver').onclick = abrirLectura;

// --- cierre ---
function pintarCierre() {
  const c = contar(sesion);
  $('clResumen').innerHTML = `<h2>${esc(sesion.destino === 'EXPORTACION' ? 'Exportación' : 'Consumo')} · ${esc(sesion.categoria)} · ${esc(sesion.propietario)}</h2>
    <p>Inicio ${fmtTs(sesion.inicio)}</p>
    <div class="cnt" style="font-size:20px"><span class="t">Total ${c.total}</span><span class="v">Verdes ${c.verdes}</span><span class="a">Amarillas ${c.amarillas}</span><span class="r">Rojas ${c.rojas}</span></div>
    <p class="muted">${c.borradas} borrada(s). Una vez cerrada, la sesión no se puede editar.</p>`;
  $('clMsg').innerHTML = '';
}
$('clVolver').onclick = abrirLectura;
$('clConfirmar').onclick = () => confirmar('<h2>¿Cerrar la sesión y enviarla al portal?</h2>', cerrarSesion, 'Cerrar y enviar', 'p');
async function cerrarSesion() {
  sesion.fin = new Date().toISOString();
  const s = sesion; sesion = null; guardarSesion();
  pendientes.push(s); store.set('pendientes', pendientes);
  $('clConfirmar').disabled = true;
  msg('clMsg', 'warn', 'Enviando al portal…');
  const r = await enviarPendientes();
  $('clConfirmar').disabled = false;
  if (!pendientes.some(x => x.id === s.id)) { msg('clMsg', 'ok', 'Sesión enviada al portal.'); setTimeout(irHome, 1500); }
  else { msg('clMsg', 'warn', 'No se pudo enviar ahora (' + (r.err ? r.err.message : 'sin internet') + '). Quedó pendiente: se envía sola cuando haya conexión.'); setTimeout(irHome, 3500); }
}

// --- configuración ---
let editarUsuario = false;
function pintarSetup() {
  const guardado = !!(cfg.email && cfg.password) && !editarUsuario;
  $('cfgUserOk').classList.toggle('hidden', !guardado); $('cfgUserForm').classList.toggle('hidden', guardado);
  $('cfgUserOkTxt').textContent = 'Usuario guardado: ' + (cfg.email || '');
  $('cfgEmail').value = guardado ? '' : (cfg.email || ''); $('cfgPass').value = '';
  $('cfgModo').value = cfg.modo || 'bluetooth'; $('cfgBaud').value = String(cfg.baud || 9600);
  $('cfgMsg').innerHTML = ''; $('cfgBalMsg').innerHTML = '';
  pintarModo();
  $('cfgInfo').textContent = `Versión ${A.version()} · ${A.deviceName()}` + (padron ? ` · padrón del ${fmtTs(padron.al)} (${padron.n} caravanas)` : '');
}
function pintarModo() { const m = $('cfgModo').value, usb = m === 'usb'; $('cfgBtBox').classList.toggle('hidden', usb); $('cfgUsbBox').classList.toggle('hidden', !usb); $('cfgBtLabel').firstChild.textContent = (m === 'baston' ? 'Bastón emparejado ' : 'Balanza emparejada '); $('cfgBtAyuda').textContent = (MODOS[m] || MODOS.bluetooth).ayuda; if (usb) pintarUsb(); else pintarBt(); }
function pintarBt() {
  if (!A.hasBluetoothPermission()) { A.requestBluetoothPermission(); }
  let devs = []; try { devs = JSON.parse(A.pairedDevices()); } catch (e) {}
  const s = $('cfgBt');
  const actual = $('cfgModo').value === 'baston' ? cfg.bastonAddress : cfg.btAddress;
  s.innerHTML = '<option value="">— elegir —</option>' + devs.map(d => `<option value="${esc(d.address)}" ${d.address === actual ? 'selected' : ''}>${esc(d.name || d.address)}</option>`).join('');
  if (!devs.length) s.innerHTML += '<option value="" disabled>No hay equipos emparejados</option>';
  if (!A.bluetoothEnabled()) $('cfgBalMsg').innerHTML = '<div class="msg warn">El Bluetooth de la tablet está apagado.</div>';
}
function pintarUsb() { let d = []; try { d = JSON.parse(A.usbDevices()); } catch (e) {} $('cfgUsbInfo').textContent = d.length ? 'Detectado: ' + d.map(x => x.name).join(', ') : 'No se detecta ningún adaptador serie por USB (conectá el cable y volvé a abrir esta pantalla).'; }
$('cfgBtRefrescar').onclick = pintarBt;
$('cfgBtAjustes').onclick = () => A.openBluetoothSettings();
$('cfgBt').onchange = () => { const o = $('cfgBt').selectedOptions[0]; if ($('cfgModo').value === 'baston') { cfg.bastonAddress = o.value; cfg.bastonName = o.value ? o.textContent : ''; } else { cfg.btAddress = o.value; cfg.btName = o.value ? o.textContent : ''; } store.set('cfg', cfg); };
$('cfgBaud').onchange = () => { cfg.baud = +$('cfgBaud').value; store.set('cfg', cfg); };
$('cfgModo').addEventListener('change', () => { cfg.modo = $('cfgModo').value; store.set('cfg', cfg); A.disconnect(); pintarModo(); });
$('cfgProbar').onclick = async () => {
  cfg.email = $('cfgEmail').value.trim(); cfg.password = $('cfgPass').value; token = null;
  msg('cfgMsg', 'warn', 'Probando…');
  try { await login(); store.set('cfg', cfg); editarUsuario = false; pintarSetup(); toast('Usuario correcto. Quedó guardado en la tablet.', 3000); }
  catch (e) { msg('cfgMsg', 'err', 'No se pudo ingresar: ' + e.message); }
};
$('cfgCambiarUser').onclick = () => { editarUsuario = true; pintarSetup(); };
$('cfgProbarBalanza').onclick = async () => {
  cfg.modo = $('cfgModo').value; store.set('cfg', cfg);
  msg('cfgBalMsg', 'warn', 'Conectando…');
  if (!conectarBalanza()) return msg('cfgBalMsg', 'err', `Elegí ${cfg.modo === 'baston' ? 'el bastón' : 'la balanza'} en la lista de equipos emparejados`);
  const ok = await esperarConexion(CFG.ESPERA_BALANZA_MS);
  if (ok) msg('cfgBalMsg', 'ok', `Conectado (${conn.device}). ${cfg.modo === 'baston' ? 'Leé una caravana con el bastón' : 'Registrá un peso en la balanza'} y mirá en Diagnóstico si llega la caravana.`);
  else msg('cfgBalMsg', 'err', 'No se pudo conectar: ' + (conn.error || 'sin respuesta'));
};
$('cfgDiag').onclick = () => { pintarLog(); show('diag'); };
$('cfgBorrarPadron').onclick = () => confirmar('<h2>¿Borrar el padrón guardado en la tablet?</h2><p>Se vuelve a descargar en el próximo chequeo con internet.</p>', () => { padron = null; sufijos = null; store.del('padron'); toast('Padrón borrado'); pintarSetup(); }, 'Borrar');
$('setupVolver').onclick = irHome;

// --- diagnóstico ---
$('dgVolver').onclick = () => { show('setup'); pintarSetup(); };
$('dgConectar').onclick = () => { if (!conectarBalanza()) toast('Elegí el lector en Configuración'); };
$('dgDesconectar').onclick = () => A.disconnect();
$('dgLimpiar').onclick = () => { logLines = []; pintarLog(); };
$('dgSimBtn').onclick = () => { const v = $('dgSim').value; if (!v) return; addLog('(simulada) ' + v); const num = Reglas.extraerCaravana(v); addLog(num ? '  → caravana ' + num + (fila(num) ? ' (en el padrón)' : ' (NO está en el padrón)') : '  → no se encontró un número de 15 dígitos'); if (num && sesion) { procesar(num, 'baston'); toast('Lectura simulada registrada en la sesión abierta'); } $('dgSim').value = ''; };

// --- arranque ---
try { conn = JSON.parse(A.status()); } catch (e) {}
document.addEventListener('contextmenu', e => e.preventDefault());
if (!cfg.email) { show('setup'); pintarSetup(); } else irHome();
