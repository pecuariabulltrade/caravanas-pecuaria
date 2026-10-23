// node manga-app/tools/test_rules.js
const R = require('../app/src/main/assets/www/rules.js');
let fallos = 0;
function ok(cond, msg) { if (!cond) { fallos++; console.log('FALLA:', msg); } }
const hoy = '2026-10-22';
const S = (destino, categoria, propietario = 'PEGSA') => ({ destino, categoria, propietario });
const F = (o) => Object.assign({ estado: 'activa', propietario: 'PEGSA', categoria: 'VACA', fecha_alta: '2026-06-01' }, o);

// extracción de la línea de la balanza
ok(R.extraerCaravana('032000123456789') === '032000123456789', 'solo EID');
ok(R.extraerCaravana('032 000123456789,345.5') === '032000123456789', 'EID con espacio y peso');
ok(R.extraerCaravana('032-000123456789 345 kg') === '032000123456789', 'EID con guion');
ok(R.extraerCaravana('EID:032000123456789 W:412.0') === '032000123456789', 'EID con prefijos');
ok(R.extraerCaravana('345.5') === null, 'solo peso');
ok(R.extraerCaravana('0320001234567891234') === null, 'más de 15 dígitos seguidos no se corta');
ok(R.extraerCaravana('') === null, 'vacía');

// días
ok(R.diasDesde('2026-06-01', hoy) === 143, 'días 143 ' + R.diasDesde('2026-06-01', hoy));
ok(R.diasDesde('2026-10-22', hoy) === 0, 'mismo día');
ok(R.diasDesde(null, hoy) === -1, 'sin fecha');

// parciales (carga a mano en la balanza)
ok(R.extraerParcial('000001') === '000001', 'parcial 6 dígitos');
ok(R.extraerParcial('IDE: 123456789') === '123456789', 'parcial 9 dígitos con prefijo');
ok(R.extraerParcial('345.5') === null, 'peso con decimales no es parcial');
ok(R.extraerParcial('12345') === null, 'menos de 6 dígitos no');
ok(R.extraerParcial('032000000000001') === null, 'una caravana completa no es parcial (15 dígitos)');

// verde
let r = R.evaluar(F({}), S('EXPORTACION', 'VACA'), false, hoy);
ok(r.color === 'verde' && r.motivos.length === 0 && r.dias === 143, 'verde exportación vaca');
r = R.evaluar(F({ estado: 'salida' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'verde', 'salida de WinCampo sigue activa en SENASA');
r = R.evaluar(F({ categoria: 'TORO' }), S('CONSUMO', 'MACHO'), false, hoy);
ok(r.color === 'verde' && r.motivos.length === 0, 'toro en sesión de machos = verde');
r = R.evaluar(F({ categoria: 'MACHO' }), S('CONSUMO', 'MACHO'), false, hoy);
ok(r.color === 'verde', 'macho en sesión de machos');
r = R.evaluar(F({ fecha_alta: '2026-07-24' }), S('EXPORTACION', 'VACA'), false, hoy);
ok(r.color === 'verde' && r.dias === 90, 'justo 90 días es OK');
r = R.evaluar(F({ fecha_alta: '2026-09-01' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'verde', 'consumo no controla días');
r = R.evaluar(F({}), S('CONSUMO', 'VACA'), true, hoy);
ok(r.color === 'verde' && r.motivos[0] === 'REPETIDA', 'repetida mantiene el color y avisa');

// amarillo: solo si no está en el padrón
r = R.evaluar(null, S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'amarillo' && r.motivos[0] === 'No está en el padrón', 'no está en el padrón = amarillo');
r = R.evaluar(null, S('CONSUMO', 'VACA'), true, hoy);
ok(r.color === 'amarillo' && r.motivos.includes('REPETIDA'), 'no está + repetida');

// rojos
r = R.evaluar(F({ estado: 'baja', fecha_baja: '2026-09-01' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'rojo' && r.motivos[0] === 'Dada de baja el 01/09/2026', 'baja ' + r.motivos);
r = R.evaluar(F({ propietario: 'BULLTRADE' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'rojo' && r.motivos[0] === 'Propietario: BULLTRADE', 'propietario distinto');
r = R.evaluar(F({ categoria: 'MACHO' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'rojo' && r.motivos[0] === 'Categoría: MACHO', 'categoría opuesta');
r = R.evaluar(F({ categoria: 'HEMBRA' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'rojo' && r.motivos[0] === 'Categoría: HEMBRA', 'hembra en sesión de vacas = rojo');
r = R.evaluar(F({ categoria: 'VACA' }), S('CONSUMO', 'HEMBRA'), false, hoy);
ok(r.color === 'rojo', 'vaca en sesión de hembras = rojo');
r = R.evaluar(F({ categoria: 'VACA' }), S('CONSUMO', 'MACHO'), false, hoy);
ok(r.color === 'rojo', 'vaca en sesión de machos');
r = R.evaluar(F({ categoria: 'MIXTO' }), S('CONSUMO', 'VACA'), false, hoy);
ok(r.color === 'rojo', 'mixto no coincide');
r = R.evaluar(F({ fecha_alta: '2026-09-01' }), S('EXPORTACION', 'VACA'), false, hoy);
ok(r.color === 'rojo' && r.motivos[0] === 'Tiene 51 días, faltan 39', '90 días exportación ' + r.motivos);
r = R.evaluar(F({ propietario: 'DARWASH', categoria: 'HEMBRA' }), S('CONSUMO', 'MACHO'), true, hoy);
ok(r.color === 'rojo' && r.motivos.length === 3, 'junta motivos ' + r.motivos);

console.log(fallos ? `${fallos} fallas` : 'Todas las pruebas pasaron');
process.exit(fallos ? 1 : 0);
