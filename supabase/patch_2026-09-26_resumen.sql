-- Patch 26/09/2026: resumen por propietario.
-- Activas = activas en SENASA (estado activa + salida, hasta que se confirme la baja);
-- Salidas WinCampo = las que WinCampo ya dio por vendidas/muertas y esperan DTE;
-- con 40 / 90 días = activas que ya cumplieron esa estadía desde la fecha de alta.
drop view if exists v_resumen;
create view v_resumen as
select p.nombre as propietario,
       count(*) filter (where c.estado in ('activa','salida')) as activas,
       count(*) filter (where c.estado = 'salida') as salidas_wincampo,
       count(*) filter (where c.estado in ('activa','salida') and c.fecha_alta + 40 <= current_date) as con_40_dias,
       count(*) filter (where c.estado in ('activa','salida') and c.fecha_alta + 90 <= current_date) as con_90_dias,
       count(*) filter (where c.estado = 'baja') as bajas
  from propietarios p left join caravanas c on c.propietario_id = p.id
 where p.activo
 group by p.nombre, p.orden order by p.orden;
alter view v_resumen set (security_invoker = true);
grant select on v_resumen to authenticated;
