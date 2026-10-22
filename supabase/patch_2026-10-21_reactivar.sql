-- Patch 21/10/2026: una caravana reactivada a mano no debe volver a 'salida' por los egresos viejos de
-- WinCampo en la próxima sincronización. ignorar_egresos_hasta guarda la fecha del último egreso
-- que se decidió ignorar (el último egreso conocido al reactivar); marcar_salidas solo considera egresos posteriores.
alter table caravanas add column if not exists ignorar_egresos_hasta date;

drop function if exists marcar_salidas(text[]);
create or replace function marcar_salidas(p_numeros text[] default null) returns int language plpgsql security definer as $$
declare n int;
begin
  with ult_ing as (
    select caravana, max(fecha_ingreso) as f from wc_ingresos group by caravana
  ), ult as (
    select distinct on (e.caravana) e.caravana, e.fecha_egreso, e.destino, e.categoria_wc, e.motivo
      from wc_egresos e
      left join ult_ing i on i.caravana = e.caravana
     where lower(e.motivo) in ('venta','muerte','v','m')
       and e.fecha_egreso >= coalesce(i.f, e.fecha_egreso)
       and (p_numeros is null or e.caravana = any(p_numeros))
     order by e.caravana, e.fecha_egreso desc
  ), upd as (
    update caravanas c
       set estado = 'salida',
           fecha_salida = u.fecha_egreso,
           motivo_salida = case when lower(u.motivo) in ('muerte','m') then 'muerte' else 'venta' end::motivo_salida,
           destino_salida = u.destino,
           categoria_wc_salida = u.categoria_wc,
           actualizado_por = 'sync', actualizado_en = now()
      from ult u
     where c.numero = u.caravana and c.estado = 'activa'
       and (c.ignorar_egresos_hasta is null or u.fecha_egreso > c.ignorar_egresos_hasta)
     returning c.numero, u.fecha_egreso, u.destino, u.motivo
  )
  insert into movimientos (caravana, tipo, fecha, origen_destino, fuente, observaciones, usuario)
  select numero, 'salida', fecha_egreso, destino, 'wincampo', 'motivo WinCampo: ' || motivo, 'sync' from upd;
  get diagnostics n = row_count;
  return n;
end $$;

-- Reactivar desde la app (Consulta > Ver > Reactivar): también ignora los egresos de WinCampo hasta hoy
create or replace function cambiar_estado_excepcional(
  p_numero text, p_accion text, p_observacion text, p_usuario text
) returns void language plpgsql security definer as $$
declare c caravanas;
begin
  perform _exigir_turno(p_usuario);
  if coalesce(p_observacion,'') = '' then raise exception 'La observación es obligatoria'; end if;
  select * into c from caravanas where numero = p_numero;
  if c.numero is null then raise exception 'La caravana % no existe', p_numero; end if;
  if p_accion = 'anular' then
    update caravanas set estado = 'anulada', observaciones = p_observacion, actualizado_por = p_usuario, actualizado_en = now() where numero = p_numero;
    insert into movimientos (caravana, tipo, fecha, fuente, observaciones, usuario) values (p_numero, 'anulacion', current_date, 'manual', p_observacion, p_usuario);
  elsif p_accion = 'reactivar' then
    if c.estado not in ('baja','salida','anulada') then raise exception 'Solo se reactiva una caravana en baja, salida o anulada'; end if;
    update caravanas set estado = 'activa', fecha_baja = null, dte_baja = null, destino_baja = null,
      fecha_salida = null, motivo_salida = null, destino_salida = null, categoria_wc_salida = null,
      ignorar_egresos_hasta = greatest(coalesce(c.fecha_salida, c.fecha_baja), (select max(fecha_egreso) from wc_egresos where caravana = p_numero)),
      observaciones = p_observacion, actualizado_por = p_usuario, actualizado_en = now() where numero = p_numero;
    insert into movimientos (caravana, tipo, fecha, propietario_id, categoria, fuente, observaciones, usuario)
    values (p_numero, 'reactivacion', current_date, c.propietario_id, c.categoria, 'manual', p_observacion, p_usuario);
  else
    raise exception 'Acción desconocida: %', p_accion;
  end if;
end $$;

-- Reactivación masiva (misma lógica, varias caravanas)
create or replace function reactivar_masiva(p_numeros text[], p_usuario text, p_observacion text)
returns jsonb language plpgsql security definer as $$
declare v_num text; c caravanas; v_ok int := 0; v_omitidas text[] := '{}';
begin
  perform _exigir_turno(p_usuario);
  if coalesce(p_observacion,'') = '' then raise exception 'La observación es obligatoria'; end if;
  foreach v_num in array p_numeros loop
    v_num := upper(trim(v_num));
    select * into c from caravanas where numero = v_num;
    if c.numero is null or c.estado not in ('baja','salida','anulada') then v_omitidas := v_omitidas || v_num; continue; end if;
    update caravanas set estado = 'activa', fecha_baja = null, dte_baja = null, destino_baja = null,
      fecha_salida = null, motivo_salida = null, destino_salida = null, categoria_wc_salida = null,
      ignorar_egresos_hasta = greatest(coalesce(c.fecha_salida, c.fecha_baja), (select max(fecha_egreso) from wc_egresos where caravana = v_num)),
      actualizado_por = p_usuario, actualizado_en = now() where numero = v_num;
    insert into movimientos (caravana, tipo, fecha, propietario_id, categoria, fuente, observaciones, usuario)
    values (v_num, 'reactivacion', current_date, c.propietario_id, c.categoria, 'manual', p_observacion, p_usuario);
    v_ok := v_ok + 1;
  end loop;
  return jsonb_build_object('reactivadas', v_ok, 'omitidas', to_jsonb(v_omitidas));
end $$;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
