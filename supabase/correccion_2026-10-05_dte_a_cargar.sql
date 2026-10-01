-- Corrección aplicada el 05/10/2026 (ya ejecutada en Supabase, se guarda como registro):
-- 89 bajas cargadas con DTE "A CARGAR" se separaron por camión según la observación
-- (Vaca 1 / VACA 2 / VACAS 2 / VACAS 3) -> "VACA 1 - A CARGAR", "VACA 2 - A CARGAR", "VACA 3 - A CARGAR".
with x as (
  select numero, 'VACA ' || substring(observaciones from '\d+') || ' - A CARGAR' as nuevo
    from caravanas where estado = 'baja' and dte_baja = 'A CARGAR' and observaciones ~* 'vaca'
), u1 as (
  update caravanas c set dte_baja = x.nuevo, actualizado_en = now(), actualizado_por = 'correccion dte 05/10'
    from x where c.numero = x.numero returning c.numero
), u2 as (
  update movimientos m set dte = x.nuevo from x where m.caravana = x.numero and m.tipo = 'baja' and m.dte = 'A CARGAR' returning m.id
)
select (select count(*) from u1) as caravanas_corregidas, (select count(*) from u2) as movimientos_corregidos;
