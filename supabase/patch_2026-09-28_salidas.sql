-- Patch 28/09/2026: una caravana que entró y salió según WinCampo sin haber estado en el padrón
-- se da de alta normalmente (pendiente de alta en Ingresos) y, apenas se confirma el alta, pasa
-- automáticamente a 'salida' (pendiente de DTE de egreso en Egresos).
-- Regla de salida: existe un egreso por venta o muerte en WinCampo posterior (o igual) al último
-- ingreso de esa caravana en WinCampo. Ya no depende de la fecha de alta en el padrón, que puede
-- ser posterior al egreso real.

drop function if exists marcar_salidas();
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
     returning c.numero, u.fecha_egreso, u.destino, u.motivo
  )
  insert into movimientos (caravana, tipo, fecha, origen_destino, fuente, observaciones, usuario)
  select numero, 'salida', fecha_egreso, destino, 'wincampo', 'motivo WinCampo: ' || motivo, 'sync' from upd;
  get diagnostics n = row_count;
  return n;
end $$;

-- alta_masiva: al terminar, marca la salida de las recién dadas de alta si WinCampo ya las dio por salidas
drop function if exists alta_masiva(text[], int, categoria_padron, date, text, origen_alta, fuente_movimiento, text, text, int, text, text, text);
create or replace function alta_masiva(
  p_numeros       text[],
  p_propietario_id int,
  p_categoria     categoria_padron,
  p_fecha_alta    date,
  p_dte           text,
  p_origen        origen_alta,
  p_fuente        fuente_movimiento,
  p_usuario       text,
  p_nro_tropa     text default null,
  p_compra_id     int default null,
  p_observaciones text default null,
  p_procedencia   text default null,
  p_bolsa         text default null
) returns jsonb language plpgsql security definer as $$
declare
  v_num text; v_est estado_caravana;
  v_bolsa text := upper(trim(coalesce(nullif(p_bolsa, ''), case when p_origen = 'wincampo' then 'FEEDLOT' else 'CLASIFICAR' end)));
  v_nuevas int := 0; v_virgenes int := 0; v_omitidas text[] := '{}'; v_salidas int := 0; v_hechas text[] := '{}';
begin
  perform _exigir_turno(p_usuario);
  if p_fecha_alta > current_date then raise exception 'La fecha de alta no puede ser posterior a hoy'; end if;
  if p_origen = 'wincampo' and coalesce(p_dte,'') = '' then raise exception 'El DTE es obligatorio en altas por ingreso de WinCampo'; end if;

  foreach v_num in array p_numeros loop
    v_num := upper(trim(v_num));
    if v_num !~ '^[A-Z0-9][A-Z0-9-]{2,24}$' then raise exception 'Número inválido: %', v_num; end if;
    if p_origen in ('wincampo','virgen') and v_num !~ '^032[0-9]{12}$' then
      raise exception 'Solo caravanas electrónicas 032 en altas por WinCampo o con vírgenes: %', v_num;
    end if;
    select estado into v_est from caravanas where numero = v_num;
    if v_est is null then
      insert into caravanas (numero, estado, propietario_id, categoria, fecha_alta, dte_alta, origen_alta, nro_tropa_alta, procedencia_alta, bolsa, compra_id, observaciones, actualizado_por)
      values (v_num, 'activa', p_propietario_id, p_categoria, p_fecha_alta, p_dte, p_origen, p_nro_tropa, p_procedencia, v_bolsa, p_compra_id, p_observaciones, p_usuario);
      v_nuevas := v_nuevas + 1;
    elsif v_est = 'virgen' then
      update caravanas set estado = 'activa', propietario_id = p_propietario_id, categoria = p_categoria,
        fecha_alta = p_fecha_alta, dte_alta = p_dte, origen_alta = p_origen, nro_tropa_alta = p_nro_tropa, procedencia_alta = p_procedencia, bolsa = v_bolsa,
        observaciones = coalesce(p_observaciones, observaciones), actualizado_por = p_usuario, actualizado_en = now()
      where numero = v_num;
      v_virgenes := v_virgenes + 1;
    else
      v_omitidas := v_omitidas || v_num;
      continue;
    end if;
    v_hechas := v_hechas || v_num;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, origen_destino, nro_tropa, fuente, observaciones, usuario)
    values (v_num, 'alta', p_fecha_alta, p_dte, p_propietario_id, p_categoria, p_procedencia, p_nro_tropa, p_fuente, coalesce(p_observaciones, 'Bolsa: ' || v_bolsa), p_usuario);
  end loop;

  if array_length(v_hechas, 1) > 0 then
    v_salidas := marcar_salidas(v_hechas);
  end if;

  return jsonb_build_object('nuevas', v_nuevas, 'virgenes_usadas', v_virgenes,
                            'omitidas', to_jsonb(v_omitidas), 'total', v_nuevas + v_virgenes, 'bolsa', v_bolsa,
                            'salidas', v_salidas);
end $$;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
