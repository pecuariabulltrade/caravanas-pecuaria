// Reglas de control del Lector de Manga (sin dependencias; se prueba con node tools/test_rules.js)
const Reglas = (() => {
  const DIAS_EXPORTACION = 90;

  // Fecha ISO (aaaa-mm-dd) -> días transcurridos hasta hoy (hoy también ISO); -1 si no hay fecha
  function diasDesde(fechaISO, hoyISO) {
    if (!fechaISO) return -1;
    const a = Date.UTC(+fechaISO.slice(0, 4), +fechaISO.slice(5, 7) - 1, +fechaISO.slice(8, 10));
    const b = Date.UTC(+hoyISO.slice(0, 4), +hoyISO.slice(5, 7) - 1, +hoyISO.slice(8, 10));
    return Math.floor((b - a) / 864e5);
  }

  // Línea que manda la balanza -> número de caravana de 15 dígitos (o null)
  // Acepta "032000123456789", "032 000123456789", "032-000123456789", con peso y otros campos alrededor.
  function extraerCaravana(linea) {
    if (!linea) return null;
    const m = String(linea).match(/(?<!\d)(\d{3})[ \-]?(\d{12})(?!\d)/);
    if (!m) return null;
    return m[1] + m[2];
  }

  // Línea de la balanza sin caravana completa -> dígitos tecleados a mano en el IDE (6 a 14 dígitos), o null
  function extraerParcial(linea) {
    if (!linea) return null;
    const m = String(linea).match(/(?<![\d.])(\d{6,14})(?![\d.])/);
    return m ? m[1] : null;
  }

  // Texto tecleado a mano -> dígitos (o letras/números para visuales)
  function normalizarManual(txt) {
    return String(txt || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  }

  /**
   * Controla una caravana contra la sesión.
   *  verde    = está en el padrón y coincide todo
   *  amarillo = no existe en el padrón SENASA
   *  rojo     = está en el padrón pero no coincide (propietario, categoría, días de exportación, baja)
   * @param fila   fila del padrón {estado, propietario, categoria, fecha_alta} o null si no está
   * @param sesion {destino:'EXPORTACION'|'CONSUMO', categoria:'HEMBRA'|'VACA'|'MACHO', propietario:'PEGSA'}
   * @param yaLeida true si ya se leyó en esta sesión (no cambia el color, solo agrega el aviso)
   * @param hoyISO fecha de hoy aaaa-mm-dd
   */
  function evaluar(fila, sesion, yaLeida, hoyISO) {
    const motivos = [];
    if (!fila) {
      motivos.push('No está en el padrón');
      if (yaLeida) motivos.push('REPETIDA');
      return { color: 'amarillo', motivos, dias: null, estado: null, propietario: null, categoria: null };
    }
    let rojo = false;
    const R = m => { motivos.push(m); rojo = true; };

    const estado = fila.estado || '';
    if (estado === 'baja') R('Dada de baja' + (fila.fecha_baja ? ' el ' + fmt(fila.fecha_baja) : ''));
    else if (estado === 'anulada') R('Anulada en el padrón');
    else if (estado === 'virgen') R('Sin alta en SENASA (virgen)');

    const prop = (fila.propietario || '').toUpperCase();
    if (prop !== (sesion.propietario || '').toUpperCase()) R('Propietario: ' + (prop || 'sin propietario'));

    const sel = (sesion.categoria || '').toUpperCase();
    const cat = (fila.categoria || '').toUpperCase();
    const coincide = cat === sel || (sel === 'MACHO' && cat === 'TORO');
    if (!coincide) R('Categoría: ' + (cat || 'sin definir'));

    const dias = diasDesde(fila.fecha_alta, hoyISO);
    if ((sesion.destino || '').toUpperCase() === 'EXPORTACION') {
      if (dias < 0) R('Sin fecha de alta en SENASA');
      else if (dias < DIAS_EXPORTACION) R('Tiene ' + dias + ' días, faltan ' + (DIAS_EXPORTACION - dias));
    }

    if (yaLeida) motivos.push('REPETIDA');

    return {
      color: rojo ? 'rojo' : 'verde',
      motivos, dias: dias < 0 ? null : dias, estado, propietario: prop, categoria: cat
    };
  }

  function fmt(iso) { return iso ? String(iso).slice(0, 10).split('-').reverse().join('/') : ''; }

  return { DIAS_EXPORTACION, diasDesde, extraerCaravana, extraerParcial, normalizarManual, evaluar, fmt };
})();
if (typeof module !== 'undefined') module.exports = Reglas;
