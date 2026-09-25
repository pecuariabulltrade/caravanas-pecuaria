-- Patch 25/09/2026: procedencia (origen para SIGSA) en el alta, cargada por el usuario,
-- independiente del origen que figura en WinCampo.
alter table caravanas add column if not exists procedencia_alta text;

drop function if exists alta_masiva(text[], int, categoria_padron, date, text, origen_alta, fuente_movimiento, text, text, int, text);

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
  p_procedencia   text default null
) returns jsonb language plpgsql security definer as $$
declare
  v_num text; v_est estado_caravana;
  v_nuevas int := 0; v_virgenes int := 0; v_omitidas text[] := '{}';
begin
  perform _exigir_turno(p_usuario);
  if p_fecha_alta > current_date then raise exception 'La fecha de alta no puede ser posterior a hoy'; end if;
  if p_origen = 'wincampo' and coalesce(p_dte,'') = '' then raise exception 'El DTE es obligatorio en altas por ingreso de WinCampo'; end if;

  foreach v_num in array p_numeros loop
    if v_num !~ '^032[0-9]{12}$' then raise exception 'Número inválido: %', v_num; end if;
    select estado into v_est from caravanas where numero = v_num;
    if v_est is null then
      insert into caravanas (numero, estado, propietario_id, categoria, fecha_alta, dte_alta, origen_alta, nro_tropa_alta, procedencia_alta, compra_id, observaciones, actualizado_por)
      values (v_num, 'activa', p_propietario_id, p_categoria, p_fecha_alta, p_dte, p_origen, p_nro_tropa, p_procedencia, p_compra_id, p_observaciones, p_usuario);
      v_nuevas := v_nuevas + 1;
    elsif v_est = 'virgen' then
      update caravanas set estado = 'activa', propietario_id = p_propietario_id, categoria = p_categoria,
        fecha_alta = p_fecha_alta, dte_alta = p_dte, origen_alta = p_origen, nro_tropa_alta = p_nro_tropa, procedencia_alta = p_procedencia,
        observaciones = coalesce(p_observaciones, observaciones), actualizado_por = p_usuario, actualizado_en = now()
      where numero = v_num;
      v_virgenes := v_virgenes + 1;
    else
      v_omitidas := v_omitidas || v_num;
      continue;
    end if;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, origen_destino, nro_tropa, fuente, observaciones, usuario)
    values (v_num, 'alta', p_fecha_alta, p_dte, p_propietario_id, p_categoria, p_procedencia, p_nro_tropa, p_fuente, p_observaciones, p_usuario);
  end loop;

  return jsonb_build_object('nuevas', v_nuevas, 'virgenes_usadas', v_virgenes,
                            'omitidas', to_jsonb(v_omitidas), 'total', v_nuevas + v_virgenes);
end $$;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
