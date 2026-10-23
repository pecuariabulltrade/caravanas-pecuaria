// Prueba de la interfaz en un navegador sin cabeza (simula Android y Supabase).
// node manga-app/tools/test_ui.js
const path = require('path');
const http = require('http');
const fs = require('fs');
const { chromium } = require('/opt/npm-tools/node_modules/playwright');

const WWW = path.join(__dirname, '..', 'app', 'src', 'main', 'assets', 'www');
const server = http.createServer((req, res) => {
  const f = path.join(WWW, req.url === '/' ? 'index.html' : req.url.split('?')[0]);
  if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'Content-Type': f.endsWith('.js') ? 'text/javascript' : 'text/html' });
  res.end(fs.readFileSync(f));
});

const padron = [
  { numero: '032000000000001', estado: 'activa', propietario: 'PEGSA', categoria: 'VACA', fecha_alta: '2026-06-01', fecha_baja: null },
  { numero: '032000000000002', estado: 'activa', propietario: 'BULLTRADE', categoria: 'MACHO', fecha_alta: '2026-06-01', fecha_baja: null },
  { numero: '032000000000003', estado: 'activa', propietario: 'PEGSA', categoria: 'HEMBRA', fecha_alta: '2026-10-01', fecha_baja: null },
  { numero: '032000000000004', estado: 'baja', propietario: 'PEGSA', categoria: 'VACA', fecha_alta: '2026-01-01', fecha_baja: '2026-09-01' },
  { numero: '032000001000001', estado: 'activa', propietario: 'DARWASH', categoria: 'VACA', fecha_alta: '2026-05-01', fecha_baja: null },
  { numero: '032000000200001', estado: 'activa', propietario: 'PEGSA', categoria: 'VACA', fecha_alta: '2026-05-01', fecha_baja: null }
];
let rpcBody = null, logins = 0;
let fallos = 0; const ok = (c, m) => { if (!c) { fallos++; console.log('FALLA:', m); } else console.log('ok:', m); };

(async () => {
  await new Promise(r => server.listen(8765, r));
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.on('pageerror', e => { fallos++; console.log('ERROR JS:', e.message); });
  page.on('console', m => { if (m.type() === 'error') console.log('console.error:', m.text()); });
  // Android simulado
  await page.addInitScript(() => {
    window.__st = { connected: false, via: '', device: '', error: '' };
    window.__beeps = [];
    window.Android = {
      version: () => '1.0.0-test', deviceName: () => 'Tablet Prueba', online: () => true,
      hasBluetoothPermission: () => true, requestBluetoothPermission: () => setTimeout(() => Manga.onPermission(true), 5),
      bluetoothEnabled: () => true, pairedDevices: () => JSON.stringify([{ name: 'XR5000 1234', address: 'AA:BB' }, { name: 'XRS2i 777', address: 'CC:DD' }]),
      __lastBt: null,
      connectBluetooth: (a) => { window.Android.__lastBt = a; setTimeout(() => { window.__st = { connected: true, via: 'bluetooth', device: a === 'CC:DD' ? 'XRS2i 777' : 'XR5000 1234', error: '' }; Manga.onStatus(window.__st); }, 200); },
      usbDevices: () => '[]', setUsbBaud: () => {}, connectUsb: () => {}, disconnect: () => {}, reconnect: () => {},
      status: () => JSON.stringify(window.__st), openBluetoothSettings: () => {},
      vibrate: () => {}, beep: (k) => window.__beeps.push(k)
    };
  });
  // Supabase simulado
  await page.route('https://xqcipsnyvnozkvehpzsk.supabase.co/**', async route => {
    const url = route.request().url(); const m = route.request().method();
    if (url.includes('/auth/v1/token')) { logins++; const b = JSON.parse(route.request().postData()); if (b.password !== 'secreta') return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error_description: 'Invalid login credentials' }) }); return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: 'tok', expires_in: 3600 }) }); }
    if (url.includes('/rest/v1/propietarios')) return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ id: 1, nombre: 'PEGSA', activo: true, orden: 1 }, { id: 2, nombre: 'BULLTRADE', activo: true, orden: 2 }, { id: 3, nombre: 'DARWASH', activo: true, orden: 3 }]) });
    if (url.includes('/rest/v1/v_caravanas')) { const off = +(url.match(/offset=(\d+)/) || [0, 0])[1]; return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(off ? [] : padron) }); }
    if (url.includes('/rest/v1/rpc/recibir_sesion_manga') && m === 'POST') { rpcBody = JSON.parse(route.request().postData()); return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: rpcBody.p_sesion.id, lecturas: rpcBody.p_lecturas.length }) }); }
    return route.fulfill({ status: 404, body: '{}' });
  });

  await page.goto('http://localhost:8765/');
  ok(await page.isVisible('#s-setup'), 'arranca en configuración (primera vez)');
  await page.fill('#cfgEmail', 'manga@pecuariabulltrade.com'); await page.fill('#cfgPass', 'mala');
  await page.click('#cfgProbar'); await page.waitForSelector('#cfgMsg .msg.err');
  ok(true, 'contraseña incorrecta avisa');
  await page.fill('#cfgPass', 'secreta'); await page.click('#cfgProbar'); await page.waitForSelector('#cfgUserOk:not(.hidden)');
  ok(!(await page.isVisible('#cfgEmail')) && (await page.textContent('#cfgUserOkTxt')).includes('manga@'), 'usuario guardado queda oculto');
  await page.click('#cfgCambiarUser'); ok(await page.isVisible('#cfgEmail') && (await page.inputValue('#cfgPass')) === '', 'Cambiar usuario muestra el formulario sin contraseña');
  await page.fill('#cfgEmail', 'manga@pecuariabulltrade.com'); await page.fill('#cfgPass', 'secreta'); await page.click('#cfgProbar'); await page.waitForSelector('#cfgUserOk:not(.hidden)');
  await page.selectOption('#cfgBt', 'AA:BB');
  await page.click('#setupVolver');
  ok(await page.isVisible('#s-home'), 'vuelve a inicio');

  await page.click('#btnIniciar');
  await page.waitForFunction(() => !document.getElementById('ckContinuar').disabled, null, { timeout: 20000 });
  const ck = await page.evaluate(() => [1, 2, 3, 4].map(i => document.getElementById('ck' + i).className));
  ok(ck.every(c => c.includes('ok')), 'chequeo: los 4 puntos en OK ' + ck);
  ok((await page.textContent('#ck3t')).includes('6 caravanas'), 'padrón descargado');
  await page.click('#ckContinuar');
  ok(await page.isVisible('#s-select'), 'pantalla de selección');
  await page.click('#selDestino [data-v=EXPORTACION]'); await page.click('#selCat [data-v=VACA]');
  ok(await page.isDisabled('#selEmpezar'), 'no deja empezar sin propietario');
  await page.click('#selProp [data-v=PEGSA]');
  await page.click('#selEmpezar');
  ok(await page.isVisible('#s-read'), 'pantalla de lectura');

  const linea = async (l) => { await page.evaluate(l => Manga.onLine(l), l); await page.waitForTimeout(50); };
  const color = () => page.evaluate(() => document.getElementById('s-read').className.replace('screen on ', ''));
  await linea('032000000000001,412.5'); ok(await color() === 'c-verde', 'vaca PEGSA 143 días → verde');
  await linea('032000000000001,412.5'); ok((await page.textContent('#cT')) === '1', 'misma caravana seguida no se duplica');
  await linea('032 000000000002, 380'); ok(await color() === 'c-rojo' && (await page.textContent('#rdMot')).includes('BULLTRADE'), 'macho BULLTRADE → rojo con motivos');
  await linea('032000000000003'); ok(await color() === 'c-rojo' && (await page.textContent('#rdMot')).includes('faltan'), 'hembra 21 días exportación → rojo');
  await linea('032000000000004'); ok(await color() === 'c-rojo' && (await page.textContent('#rdMot')).includes('Dada de baja'), 'baja → rojo');
  await linea('032000000000099'); ok(await color() === 'c-amarillo' && (await page.textContent('#rdMot')).includes('No está') && (await page.textContent('#rdBig')) === 'NO ESTÁ', 'no está en el padrón = amarillo');
  await linea('123.4'); ok((await page.textContent('#cT')) === '5', 'una línea sin caravana no registra');
  await page.evaluate(() => { window.__t0 = Date.now(); });
  await page.waitForTimeout(100);
  // repetida: simulamos que pasaron más de 3 s cambiando el reloj de la última lectura
  await page.evaluate(() => { /* fuerza repetida */ });
  await linea('032000000000002'); // distinta de la última (099) → no es dedupe; ya leída → aviso REPETIDA, color rojo por propietario
  ok(await color() === 'c-rojo' && (await page.textContent('#rdMot')).includes('REPETIDA'), 'repetida se marca junto con los otros motivos');
  let cnt = await page.evaluate(() => ['cT', 'cV', 'cA', 'cR'].map(i => +document.getElementById(i).textContent));
  ok(cnt.join() === '6,1,1,4', 'contadores ' + cnt.join());
  ok(await page.evaluate(() => window.__beeps.filter(b => b === 'rojo').length) === 4, 'beeps rojos');
  // no guardar la última
  await page.click('#rdNoGuardar');
  cnt = await page.evaluate(() => ['cT', 'cV', 'cA', 'cR'].map(i => +document.getElementById(i).textContent));
  ok(cnt.join() === '5,1,1,3' && (await page.textContent('#rdNum')) === '032000000000099', 'No guardar quita la última y muestra la anterior ' + cnt.join());
  await linea('032000000000002'); // ahora ya no es repetida de la quitada… sigue existiendo la 002 anterior → REPETIDA igual
  ok((await page.textContent('#cT')) === '6', 'vuelve a leer y se registra');
  // dígitos parciales tecleados en la balanza
  await linea('200001'); ok(await color() === 'c-verde' && (await page.textContent('#rdNum')) === '032000000200001' && (await page.textContent('#rdFuente')).includes('a mano'), 'parcial único desde la balanza → se resuelve y marca a mano');
  await linea('000001'); ok(await page.isVisible('#rdElegir') && (await page.evaluate(() => document.querySelectorAll('#rdElegir button[data-n]').length)) === 2, 'parcial ambiguo desde la balanza muestra opciones');
  await page.click('#rdElegirCancelar'); ok(!(await page.isVisible('#rdElegir')) && (await page.textContent('#cT')) === '7', 'cancelar no registra');
  await linea('000001'); await page.click('#rdElegir button[data-n="032000001000001"]');
  ok(await color() === 'c-rojo' && (await page.textContent('#rdMot')).includes('DARWASH') && (await page.textContent('#cT')) === '8', 'elegida de la lista se registra');
  await page.click('#rdNoGuardar'); await page.click('#rdNoGuardar');
  ok((await page.textContent('#cT')) === '6', 'dos No guardar seguidos quitan las dos últimas');

  // manual
  await page.click('#rdManual'); ok(await page.isVisible('#s-manual') && await page.isVisible('#mnDescartar') && await page.isVisible('#mnVolver'), 'teclado manual con Descartar sesión y Volver');
  for (const k of '200001') await page.click(`.pad [data-k="${k}"]`);
  await page.click('.pad [data-k=OK]');
  ok(await page.isVisible('#s-read') && await color() === 'c-verde' && (await page.textContent('#rdFuente')).includes('a mano'), 'manual 6 dígitos único → verde y marcada a mano');
  await page.click('#rdManual');
  for (const k of '000001') await page.click(`.pad [data-k="${k}"]`);
  await page.click('.pad [data-k=OK]');
  const n = await page.evaluate(() => document.querySelectorAll('#mnRes button[data-n]').length);
  ok(n === 2, 'sufijo ambiguo muestra 2 opciones (' + n + ')');
  const primero = await page.evaluate(() => document.querySelector('#mnRes button[data-n]').dataset.n);
  ok(primero === '032000000000001', 'primero la del propietario de la sesión');
  await page.click('#mnRes button[data-n="032000001000001"]');
  ok(await color() === 'c-rojo' && (await page.textContent('#rdMot')).includes('DARWASH'), 'elegida de la lista → rojo DARWASH');
  await page.click('#rdManual');
  for (const k of '999999') await page.click(`.pad [data-k="${k}"]`);
  await page.click('.pad [data-k=OK]');
  ok((await page.textContent('#mnRes')).includes('Ninguna'), 'sufijo inexistente avisa');
  await page.click('#mnVolver');
  await linea('032000000000004'); // la baja → rojo, para que el listado tenga 6 rojas como antes

  // listado y borrado
  await page.click('#rdLista');
  let items = await page.evaluate(() => document.querySelectorAll('#lsBox .it').length);
  ok(items === 9, 'listado con 9 lecturas (' + items + ')');
  await page.click('#lsFiltro [data-f=rojo]');
  items = await page.evaluate(() => document.querySelectorAll('#lsBox .it').length);
  ok(items === 6, 'filtro rojas = 6 (' + items + ')');
  await page.click('#lsBox button[data-del]'); await page.click('#modalBox button[data-i="1"]');
  items = await page.evaluate(() => document.querySelectorAll('#lsBox .it').length);
  ok(items === 5, 'borrada una roja → 5');
  await page.click('#lsFiltro [data-f=borrada]');
  ok(await page.evaluate(() => document.querySelectorAll('#lsBox .it.borrada').length) === 1, 'filtro borradas muestra 1');
  await page.click('#lsVolver');
  ok((await page.textContent('#cT')) === '8', 'contador descontó la borrada');

  // persistencia: recargar y continuar
  await page.reload();
  ok(await page.isVisible('#s-home') && (await page.textContent('#homeAbierta')).includes('8 lecturas'), 'sesión abierta sobrevive al reinicio');
  await page.click('#homeSeguir'); ok(await page.isVisible('#s-read') && (await page.textContent('#cT')) === '8', 'continúa la sesión');

  // cierre y envío
  await page.click('#rdCerrar'); ok(await page.isVisible('#s-close') && (await page.textContent('#clResumen')).includes('Total 8'), 'resumen de cierre');
  await page.click('#clConfirmar'); await page.click('#modalBox button[data-i="1"]');
  await page.waitForSelector('#clMsg .msg.ok', { timeout: 5000 });
  ok(rpcBody && rpcBody.p_sesion.total === 8 && rpcBody.p_sesion.rojas === 5 && rpcBody.p_sesion.amarillas === 1 && rpcBody.p_sesion.borradas === 1 && rpcBody.p_lecturas.length === 9, 'RPC con totales correctos ' + JSON.stringify(rpcBody && rpcBody.p_sesion));
  ok(rpcBody.p_lecturas.filter(l => l.borrada).length === 1 && rpcBody.p_lecturas.filter(l => l.fuente === 'manual').length === 2, 'lecturas con borrada y fuente manual');
  ok(rpcBody.p_sesion.destino === 'EXPORTACION' && rpcBody.p_sesion.propietario_id === 1 && rpcBody.p_sesion.fin, 'cabecera de sesión');
  await page.waitForSelector('#s-home.on', { timeout: 5000 });
  ok(!(await page.textContent('#homePend')).includes('pendiente'), 'sin pendientes tras enviar');

  // envío sin internet → queda pendiente y se reenvía
  await page.unroute('https://xqcipsnyvnozkvehpzsk.supabase.co/**');
  await page.route('https://xqcipsnyvnozkvehpzsk.supabase.co/**', r => r.abort());
  await page.click('#btnIniciar');
  await page.waitForFunction(() => !document.getElementById('ckContinuar').disabled, null, { timeout: 20000 });
  ok((await page.textContent('#ck3t')).includes('copia'), 'sin red usa la copia del padrón: ' + await page.textContent('#ck3t'));
  await page.click('#ckContinuar');
  await page.click('#selDestino [data-v=CONSUMO]'); await page.click('#selCat [data-v=MACHO]'); await page.click('#selProp [data-v=BULLTRADE]'); await page.click('#selEmpezar');
  await linea('032000000000002'); ok(await color() === 'c-verde', 'consumo macho BULLTRADE → verde');
  await page.click('#rdCerrar'); await page.click('#clConfirmar'); await page.click('#modalBox button[data-i="1"]');
  await page.waitForSelector('#clMsg .msg.warn:not(:empty)', { timeout: 5000 });
  await page.waitForSelector('#s-home.on', { timeout: 6000 });
  ok((await page.textContent('#homePend')).includes('1 sesión'), 'queda pendiente sin internet');
  await page.unroute('https://xqcipsnyvnozkvehpzsk.supabase.co/**');
  rpcBody = null;
  await page.route('https://xqcipsnyvnozkvehpzsk.supabase.co/**', async route => {
    const url = route.request().url();
    if (url.includes('/auth/v1/token')) return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: 'tok', expires_in: 3600 }) });
    if (url.includes('rpc/recibir_sesion_manga')) { rpcBody = JSON.parse(route.request().postData()); return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' }); }
    return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
  });
  await page.click('#homeEnviar'); await page.waitForTimeout(500);
  ok(rpcBody && rpcBody.p_sesion.destino === 'CONSUMO' && !(await page.textContent('#homePend')).includes('pendiente'), 'reenvío manual de pendientes');

  // modo sin conexión (todo a mano)
  await page.click('#btnSinConexion');
  await page.waitForFunction(() => !document.getElementById('ckContinuar').disabled, null, { timeout: 20000 });
  ok((await page.textContent('#ck1t')).includes('a mano') && (await page.textContent('#ckContinuar')).includes('a mano'), 'chequeo sin balanza');
  await page.click('#ckContinuar');
  await page.click('#selDestino [data-v=CONSUMO]'); await page.click('#selCat [data-v=VACA]'); await page.click('#selProp [data-v=PEGSA]'); await page.click('#selEmpezar');
  ok(await page.isVisible('#s-manual') && await page.isVisible('#mnBottom') && !(await page.isVisible('#mnVolver')), 'sesión sin conexión abre el teclado con botones de sesión');
  for (const k of '000001') await page.click(`.pad [data-k="${k}"]`);
  await page.click('.pad [data-k=OK]');
  await page.click('#mnRes button[data-n="032000000000001"]');
  ok(await page.isVisible('#s-manual') && (await page.textContent('#mnBBig')) === 'OK' && (await page.textContent('#mT')) === '1', 'queda en el teclado con banner verde y contador 1');
  for (const k of '000002') await page.click(`.pad [data-k="${k}"]`);
  await page.click('.pad [data-k=OK]');
  ok((await page.textContent('#mnBBig')) === 'NO' && (await page.textContent('#mnBMot')).includes('BULLTRADE') && (await page.textContent('#mR')) === '1', 'banner rojo con motivo');
  ok(await page.isVisible('#mnDescartar'), 'modo manual tiene Descartar sesión');
  await page.click('#mnLista'); ok(await page.isVisible('#s-list') && (await page.evaluate(() => document.querySelectorAll('#lsBox .it').length)) === 2, 'listado desde modo manual');
  await page.click('#lsVolver'); ok(await page.isVisible('#s-manual'), 'volver del listado regresa al teclado');
  await page.reload(); await page.click('#homeSeguir'); ok(await page.isVisible('#s-manual') && (await page.textContent('#mT')) === '2', 'continuar sesión manual tras reinicio');
  await page.click('#mnCerrar'); await page.click('#clConfirmar'); await page.click('#modalBox button[data-i="1"]');
  await page.waitForSelector('#clMsg .msg.ok', { timeout: 5000 });
  ok(rpcBody && rpcBody.p_sesion.destino === 'CONSUMO' && rpcBody.p_lecturas.length === 2 && rpcBody.p_lecturas.every(l => l.fuente === 'manual'), 'sesión manual enviada con lecturas a mano');
  // modo bastón XRS2i directo
  await page.click('#homeCfg');
  await page.selectOption('#cfgModo', 'baston');
  ok((await page.textContent('#cfgBtAyuda')).includes('bastón') && (await page.textContent('#cfgBtLabel')).startsWith('Bastón'), 'configuración muestra ayuda del bastón');
  await page.selectOption('#cfgBt', 'CC:DD');
  await page.click('#cfgProbarBalanza'); await page.waitForSelector('#cfgBalMsg .msg.ok', { timeout: 5000 });
  ok(await page.evaluate(() => window.Android.__lastBt) === 'CC:DD' && (await page.textContent('#cfgBalMsg')).includes('XRS2i'), 'conecta al bastón elegido');
  await page.selectOption('#cfgModo', 'bluetooth');
  ok(await page.inputValue('#cfgBt') === 'AA:BB', 'la balanza sigue elegida en su modo');
  await page.selectOption('#cfgModo', 'baston'); ok(await page.inputValue('#cfgBt') === 'CC:DD', 'y el bastón en el suyo');
  await page.click('#setupVolver');
  ok((await page.textContent('#homeInfo')).includes('Bastón XRS2i'), 'inicio indica el bastón');
  await page.click('#btnIniciar');
  await page.waitForFunction(() => !document.getElementById('ckContinuar').disabled, null, { timeout: 20000 });
  ok((await page.textContent('#ck1h')) === 'Bastón XRS2i' && (await page.textContent('#ck1t')).includes('XRS2i'), 'chequeo conecta al bastón');
  await page.click('#ckContinuar');
  await page.click('#selDestino [data-v=CONSUMO]'); await page.click('#selCat [data-v=VACA]'); await page.click('#selProp [data-v=PEGSA]'); await page.click('#selEmpezar');
  await linea('032 000000000001'); ok(await color() === 'c-verde' && (await page.textContent('#rdConn')).includes('Bastón'), 'lectura del bastón se procesa igual');
  // descartar sesión: cancelar y confirmar
  await page.click('#rdDescartar'); ok((await page.textContent('#modalBox')).includes('1 lecturas'), 'descartar pide confirmación con la cantidad');
  await page.click('#modalBox button[data-i="0"]'); ok(await page.isVisible('#s-read') && (await page.textContent('#cT')) === '1', 'cancelar mantiene la sesión');
  await page.click('#rdDescartar'); await page.click('#modalBox button[data-i="1"]');
  ok(await page.isVisible('#s-home') && !(await page.textContent('#homeAbierta')).includes('sesión abierta') && await page.evaluate(() => localStorage.getItem('sesion') === null), 'descartar vuelve al inicio sin sesión guardada');
  rpcBody = null;
  await page.click('#btnIniciar'); await page.waitForFunction(() => !document.getElementById('ckContinuar').disabled, null, { timeout: 20000 }); await page.click('#ckContinuar');
  await page.click('#selDestino [data-v=CONSUMO]'); await page.click('#selCat [data-v=VACA]'); await page.click('#selProp [data-v=PEGSA]'); await page.click('#selEmpezar');
  await linea('032 000000000001');
  await page.click('#rdCerrar'); await page.click('#clConfirmar'); await page.click('#modalBox button[data-i="1"]'); await page.waitForSelector('#s-home.on', { timeout: 6000 });
  await page.screenshot({ path: path.join(__dirname, 'captura_home.png') });
  await browser.close(); server.close();
  console.log(fallos ? `${fallos} fallas` : 'Todas las pruebas de interfaz pasaron');
  process.exit(fallos ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
