-- Patch 19/11/2026: cuadro "Caravanas por bolsa" en Inicio.
-- Por propietario: cuántas activas (incluye salidas sin DTE, igual que el cuadro de arriba) están por clasificar,
-- en feedlot o ya con número de caja; desglose por categoría y, por cada número, cuántas tienen 90 días y cuántas no.
drop view if exists v_bolsas_resumen;
create view v_bolsas_resumen as
select p.nombre as propietario, p.orden,
       c.categoria::text as categoria,
       case when c.bolsa = 'CLASIFICAR' or c.bolsa is null then 'clasificar'
            when c.bolsa = 'FEEDLOT' then 'feedlot' else 'caja' end as grupo,
       (c.fecha_alta is not null and c.fecha_alta + 90 <= current_date) as con_90,
       count(*) as cantidad
  from caravanas c join propietarios p on p.id = c.propietario_id
 where c.estado in ('activa','salida')
 group by p.nombre, p.orden, c.categoria, 4, 5;
alter view v_bolsas_resumen set (security_invoker = true);
grant select on v_bolsas_resumen to authenticated;
revoke all on v_bolsas_resumen from anon;
