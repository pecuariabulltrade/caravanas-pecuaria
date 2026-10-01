-- Patch 05/10/2026: editar los datos guardados de un alta o una baja (DTE, fecha, procedencia/destino,
-- observación) para un grupo de caravanas, desde la pestaña Altas y bajas. Lo que viene en null no se toca.
-- Actualiza la caravana y el movimiento de alta/baja correspondiente, y deja un movimiento 'correccion'.
create or replace function editar_dte(
  p_tipo text, p_numeros text[], p_usuario text,
  p_dte text default null, p_fecha date default null, p_lugar text default null, p_observaciones text default null
) returns jsonb language plpgsql security definer as $$
declare v_num text; c caravanas; v_ok int := 0; v_omitidas text[] := '{}'; v_cambios text[]; v_dte text := nullif(upper(trim(p_dte)), '');
begin
  perform _exigir_turno(p_usuario);
  if p_tipo not in ('alta','baja') then raise exception 'Tipo inválido: %', p_tipo; end if;
  if p_fecha is not null and p_fecha > current_date then raise exception 'La fecha no puede ser posterior a hoy'; end if;
  foreach v_num in array p_numeros loop
    v_num := upper(trim(v_num));
    select * into c from caravanas where numero = v_num;
    if c.numero is null or (p_tipo = 'alta' and c.estado not in ('activa','salida','baja')) or (p_tipo = 'baja' and c.estado <> 'baja') then
      v_omitidas := v_omitidas || v_num; continue;
    end if;
    v_cambios := '{}';
    if p_tipo = 'alta' then
      if p_fecha is not null and c.fecha_baja is not null and p_fecha > c.fecha_baja then raise exception 'Caravana %: la fecha de alta no puede ser posterior a la baja (%)', v_num, c.fecha_baja; end if;
      if v_dte is not null and v_dte is distinct from c.dte_alta then v_cambios := v_cambios || ('DTE alta ' || coalesce(c.dte_alta,'—') || ' → ' || v_dte); end if;
      if p_fecha is not null and p_fecha is distinct from c.fecha_alta then v_cambios := v_cambios || ('fecha alta ' || coalesce(to_char(c.fecha_alta,'DD/MM/YYYY'),'—') || ' → ' || to_char(p_fecha,'DD/MM/YYYY')); end if;
      if p_lugar is not null and nullif(trim(p_lugar),'') is distinct from c.procedencia_alta then v_cambios := v_cambios || ('procedencia ' || coalesce(c.procedencia_alta,'—') || ' → ' || coalesce(nullif(trim(p_lugar),''),'—')); end if;
      if p_observaciones is not null and nullif(trim(p_observaciones),'') is distinct from c.observaciones then v_cambios := v_cambios || ('obs. ' || coalesce(c.observaciones,'—') || ' → ' || coalesce(nullif(trim(p_observaciones),''),'—')); end if;
      if array_length(v_cambios,1) is null then v_omitidas := v_omitidas || v_num; continue; end if;
      update caravanas set dte_alta = coalesce(v_dte, dte_alta), fecha_alta = coalesce(p_fecha, fecha_alta),
        procedencia_alta = case when p_lugar is null then procedencia_alta else nullif(trim(p_lugar),'') end,
        observaciones = case when p_observaciones is null then observaciones else nullif(trim(p_observaciones),'') end,
        actualizado_por = p_usuario, actualizado_en = now() where numero = v_num;
      update movimientos set dte = coalesce(v_dte, dte), fecha = coalesce(p_fecha, fecha),
        origen_destino = case when p_lugar is null then origen_destino else nullif(trim(p_lugar),'') end
       where caravana = v_num and tipo = 'alta' and id = (select max(id) from movimientos where caravana = v_num and tipo = 'alta');
    else
      if p_fecha is not null and p_fecha < c.fecha_alta then raise exception 'Caravana %: la fecha de baja no puede ser anterior al alta (%)', v_num, c.fecha_alta; end if;
      if v_dte is not null and v_dte is distinct from c.dte_baja then v_cambios := v_cambios || ('DTE baja ' || coalesce(c.dte_baja,'—') || ' → ' || v_dte); end if;
      if p_fecha is not null and p_fecha is distinct from c.fecha_baja then v_cambios := v_cambios || ('fecha baja ' || coalesce(to_char(c.fecha_baja,'DD/MM/YYYY'),'—') || ' → ' || to_char(p_fecha,'DD/MM/YYYY')); end if;
      if p_lugar is not null and nullif(trim(p_lugar),'') is distinct from c.destino_baja then v_cambios := v_cambios || ('destino ' || coalesce(c.destino_baja,'—') || ' → ' || coalesce(nullif(trim(p_lugar),''),'—')); end if;
      if p_observaciones is not null and nullif(trim(p_observaciones),'') is distinct from c.observaciones then v_cambios := v_cambios || ('obs. ' || coalesce(c.observaciones,'—') || ' → ' || coalesce(nullif(trim(p_observaciones),''),'—')); end if;
      if array_length(v_cambios,1) is null then v_omitidas := v_omitidas || v_num; continue; end if;
      update caravanas set dte_baja = coalesce(v_dte, dte_baja), fecha_baja = coalesce(p_fecha, fecha_baja),
        destino_baja = case when p_lugar is null then destino_baja else nullif(trim(p_lugar),'') end,
        observaciones = case when p_observaciones is null then observaciones else nullif(trim(p_observaciones),'') end,
        actualizado_por = p_usuario, actualizado_en = now() where numero = v_num;
      update movimientos set dte = coalesce(v_dte, dte), fecha = coalesce(p_fecha, fecha),
        origen_destino = case when p_lugar is null then origen_destino else nullif(trim(p_lugar),'') end
       where caravana = v_num and tipo = 'baja' and id = (select max(id) from movimientos where caravana = v_num and tipo = 'baja');
    end if;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, fuente, observaciones, usuario)
    values (v_num, 'correccion', current_date, coalesce(v_dte, case when p_tipo='alta' then c.dte_alta else c.dte_baja end), c.propietario_id, c.categoria, 'manual',
            'Edición de ' || p_tipo || ': ' || array_to_string(v_cambios, '; '), p_usuario);
    v_ok := v_ok + 1;
  end loop;
  return jsonb_build_object('editadas', v_ok, 'omitidas', to_jsonb(v_omitidas));
end $$;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
