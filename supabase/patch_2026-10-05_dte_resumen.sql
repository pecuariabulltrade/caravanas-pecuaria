-- Patch 05/10/2026: el resumen por DTE no concatena cientos de procedencias/tropas (p. ej. el padrón
-- inicial sin DTE): muestra hasta 3 valores distintos y "(+N más)".
create or replace function _resumen_lista(p_vals text[], p_max int default 3) returns text language sql immutable as $$
  select case when p_vals is null or cardinality(p_vals) = 0 then null
              when cardinality(p_vals) <= p_max then array_to_string(p_vals, ', ')
              else array_to_string(p_vals[1:p_max], ', ') || ' (+' || (cardinality(p_vals) - p_max) || ' más)' end;
$$;

drop view if exists v_movimientos_dte;
create view v_movimientos_dte as
select 'alta'::text as tipo, coalesce(c.dte_alta, '') as dte, min(c.fecha_alta) as fecha_desde, max(c.fecha_alta) as fecha_hasta,
       count(*) as caravanas,
       _resumen_lista(array_agg(distinct p.nombre) filter (where p.nombre is not null)) as propietarios,
       _resumen_lista(array_agg(distinct c.categoria::text) filter (where c.categoria is not null)) as categorias,
       _resumen_lista(array_agg(distinct c.procedencia_alta) filter (where c.procedencia_alta is not null)) as origen_destino,
       _resumen_lista(array_agg(distinct c.nro_tropa_alta) filter (where c.nro_tropa_alta is not null)) as tropas,
       _resumen_lista(array_agg(distinct c.origen_alta::text) filter (where c.origen_alta is not null)) as fuente,
       max(c.actualizado_en) as ultimo_cargado
  from caravanas c left join propietarios p on p.id = c.propietario_id
 where c.estado in ('activa','salida','baja')
 group by coalesce(c.dte_alta, '')
union all
select 'baja', coalesce(c.dte_baja, ''), min(c.fecha_baja), max(c.fecha_baja),
       count(*),
       _resumen_lista(array_agg(distinct p.nombre) filter (where p.nombre is not null)),
       _resumen_lista(array_agg(distinct c.categoria::text) filter (where c.categoria is not null)),
       _resumen_lista(array_agg(distinct c.destino_baja) filter (where c.destino_baja is not null)),
       _resumen_lista(array_agg(distinct c.nro_tropa_alta) filter (where c.nro_tropa_alta is not null)),
       _resumen_lista(array_agg(distinct c.motivo_salida::text) filter (where c.motivo_salida is not null)),
       max(c.actualizado_en)
  from caravanas c left join propietarios p on p.id = c.propietario_id
 where c.estado = 'baja'
 group by coalesce(c.dte_baja, '');
alter view v_movimientos_dte set (security_invoker = true);
grant select on v_movimientos_dte to authenticated;
revoke all on v_movimientos_dte from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
