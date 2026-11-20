-- Patch 20/11/2026: establecimiento por caravana.
-- EL HARAS = UE No Hilton (feedlot, integrado con WinCampo: ingresos, egresos, stock).
-- EL DESCANSO = UE Hilton (se maneja desde la oficina: alta manual, baja manual, consulta, clasificar, movimientos;
-- no tiene ingresos/egresos/stock de WinCampo). El portal trabaja en un establecimiento a la vez (selector en el encabezado).
alter table caravanas add column if not exists establecimiento text not null default 'EL HARAS';
alter table caravanas drop constraint if exists caravanas_establecimiento_chk;
alter table caravanas add constraint caravanas_establecimiento_chk check (establecimiento in ('EL HARAS','EL DESCANSO'));
create index if not exists caravanas_establecimiento_idx on caravanas(establecimiento);

-- alta_masiva: nuevo parámetro p_establecimiento (default EL HARAS). Se borra la firma vieja para que no queden dos versiones.
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
  p_bolsa         text default null,
  p_establecimiento text default 'EL HARAS'
) returns jsonb language plpgsql security definer as $$
declare
  v_num text; v_est estado_caravana;
  v_bolsa text := upper(trim(coalesce(nullif(p_bolsa, ''), case when p_origen = 'wincampo' then 'FEEDLOT' else 'CLASIFICAR' end)));
  v_nuevas int := 0; v_virgenes int := 0; v_omitidas text[] := '{}'; v_salidas int := 0; v_hechas text[] := '{}';
  v_estab text := upper(trim(coalesce(nullif(p_establecimiento, ''), 'EL HARAS')));
begin
  perform _exigir_turno(p_usuario);
  if v_estab not in ('EL HARAS','EL DESCANSO') then raise exception 'Establecimiento inválido: %', v_estab; end if;
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
      insert into caravanas (numero, estado, propietario_id, categoria, fecha_alta, dte_alta, origen_alta, nro_tropa_alta, procedencia_alta, bolsa, compra_id, observaciones, actualizado_por, establecimiento)
      values (v_num, 'activa', p_propietario_id, p_categoria, p_fecha_alta, p_dte, p_origen, p_nro_tropa, p_procedencia, v_bolsa, p_compra_id, p_observaciones, p_usuario, v_estab);
      v_nuevas := v_nuevas + 1;
    elsif v_est = 'virgen' then
      update caravanas set estado = 'activa', propietario_id = p_propietario_id, categoria = p_categoria,
        fecha_alta = p_fecha_alta, dte_alta = p_dte, origen_alta = p_origen, nro_tropa_alta = p_nro_tropa, procedencia_alta = p_procedencia, bolsa = v_bolsa,
        establecimiento = v_estab,
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
                            'salidas', v_salidas, 'establecimiento', v_estab);
end $$;

-- marcar_salidas (egresos de WinCampo) solo toca caravanas de EL HARAS
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
     where c.numero = u.caravana and c.estado = 'activa' and c.establecimiento = 'EL HARAS'
       and (c.ignorar_egresos_hasta is null or u.fecha_egreso > c.ignorar_egresos_hasta)
     returning c.numero, u.fecha_egreso, u.destino, u.motivo
  )
  insert into movimientos (caravana, tipo, fecha, origen_destino, fuente, observaciones, usuario)
  select numero, 'salida', fecha_egreso, destino, 'wincampo', 'motivo WinCampo: ' || motivo, 'sync' from upd;
  get diagnostics n = row_count;
  return n;
end $$;

-- Vistas: v_caravanas (c.* trae la columna nueva), v_egresos_cruce y v_stock_cruce con establecimiento
drop view if exists v_caravanas;
create view v_caravanas as
select c.*, p.nombre as propietario,
       c.fecha_alta + 40 as fecha_40_dias,
       c.fecha_alta + 90 as fecha_90_dias,
       v.estado as visec_estado, v.fecha as visec_fecha, v.informe as visec_informe, v.observacion as visec_observacion,
       exists (select 1 from visec_solicitudes s where s.caravana = c.numero and not s.atendido) as visec_pedida
  from caravanas c left join propietarios p on p.id = c.propietario_id
  left join visec_consultas v on v.caravana = c.numero;
alter view v_caravanas set (security_invoker = true);
grant select on v_caravanas to authenticated;

drop view if exists v_egresos_cruce;
create view v_egresos_cruce as
select c.numero as caravana, c.estado as estado_padron, c.establecimiento, c.propietario_id, p.nombre as propietario,
       c.categoria as categoria_padron, c.categoria_wc_salida as categoria_wincampo,
       c.fecha_alta, c.dte_alta, c.fecha_salida, c.motivo_salida, c.destino_salida,
       c.fecha_baja, c.dte_baja, c.destino_baja,
       e.nro_tropa, e.hotelero, e.fecha_egreso, e.destino, e.motivo as motivo_wincampo,
       case when c.estado = 'salida' then 'pendiente_dte'
            when c.estado = 'baja' then 'dada_de_baja' else c.estado::text end as situacion,
       v.estado as visec_estado, v.fecha as visec_fecha
  from caravanas c
  left join propietarios p on p.id = c.propietario_id
  left join visec_consultas v on v.caravana = c.numero
  left join lateral (
    select * from wc_egresos e where e.caravana = c.numero
      and lower(e.motivo) in ('venta','muerte','v','m')
     order by e.fecha_egreso desc limit 1) e on true
 where c.estado in ('salida','baja');
alter view v_egresos_cruce set (security_invoker = true);
grant select on v_egresos_cruce to authenticated;

drop view if exists v_stock_cruce;
create view v_stock_cruce as
select s.caravana, s.nro_tropa, s.hotelero, s.categoria_wc, s.categoria, s.nro_corral,
       establecimiento_por_corral(s.nro_corral) as establecimiento, s.sincronizado_en,
       c.estado as estado_padron, c.propietario_id, p.nombre as propietario, c.categoria as categoria_padron,
       c.fecha_alta, c.dte_alta, c.fecha_salida, c.fecha_baja, c.dte_baja,
       case when c.numero is null or c.estado = 'virgen' then 'sin_alta'
            when c.estado = 'activa' then 'activa'
            when c.estado = 'baja'   then 'baja'
            when c.estado = 'salida' then 'salida'
            else 'anulada' end as situacion,
       case when c.numero is null or c.estado = 'virgen' then 'Todavía no se dio de alta en el padrón SENASA'
            when c.estado = 'activa' then 'Activa en el padrón'
            when c.estado = 'baja'   then 'Ya salió del padrón SENASA (baja con DTE ' || coalesce(c.dte_baja, 's/d') || ' el ' || to_char(c.fecha_baja, 'DD/MM/YYYY') || ')'
            when c.estado = 'salida' then 'WinCampo la dio por salida el ' || to_char(c.fecha_salida, 'DD/MM/YYYY') || ' pero sigue en stock: revisar'
            else 'Anulada en el padrón' end as motivo,
       case when c.numero is null or c.estado not in ('activa','salida') or s.categoria is null then null
            else (s.categoria = c.categoria) end as categoria_ok,
       v.estado as visec_estado, v.fecha as visec_fecha
  from wc_stock s
  left join caravanas c on c.numero = s.caravana
  left join propietarios p on p.id = c.propietario_id
  left join visec_consultas v on v.caravana = s.caravana;
alter view v_stock_cruce set (security_invoker = true);
grant select on v_stock_cruce to authenticated;
revoke all on v_stock_cruce, v_egresos_cruce, v_caravanas from anon;

-- Resumen por propietario, por establecimiento
drop view if exists v_resumen;
create view v_resumen as
select e.establecimiento, p.nombre as propietario,
       count(c.numero) filter (where c.estado in ('activa','salida')) as activas,
       count(c.numero) filter (where c.estado = 'salida') as salidas_wincampo,
       count(c.numero) filter (where c.estado in ('activa','salida') and c.fecha_alta + 40 <= current_date) as con_40_dias,
       count(c.numero) filter (where c.estado in ('activa','salida') and c.fecha_alta + 90 <= current_date) as con_90_dias,
       count(c.numero) filter (where c.estado = 'baja') as bajas
  from propietarios p
  cross join (values ('EL HARAS'), ('EL DESCANSO')) e(establecimiento)
  left join caravanas c on c.propietario_id = p.id and c.establecimiento = e.establecimiento
 where p.activo
 group by e.establecimiento, p.nombre, p.orden order by e.establecimiento, p.orden;
alter view v_resumen set (security_invoker = true);
grant select on v_resumen to authenticated;
revoke all on v_resumen from anon;

-- Altas y bajas por DTE, por establecimiento
drop view if exists v_movimientos_dte;
create view v_movimientos_dte as
select c.establecimiento, 'alta'::text as tipo, coalesce(c.dte_alta, '') as dte, min(c.fecha_alta) as fecha_desde, max(c.fecha_alta) as fecha_hasta,
       count(*) as caravanas,
       _resumen_lista(array_agg(distinct p.nombre) filter (where p.nombre is not null)) as propietarios,
       _resumen_lista(array_agg(distinct c.categoria::text) filter (where c.categoria is not null)) as categorias,
       _resumen_lista(array_agg(distinct c.procedencia_alta) filter (where c.procedencia_alta is not null)) as origen_destino,
       _resumen_lista(array_agg(distinct c.nro_tropa_alta) filter (where c.nro_tropa_alta is not null)) as tropas,
       _resumen_lista(array_agg(distinct c.origen_alta::text) filter (where c.origen_alta is not null)) as fuente,
       max(c.actualizado_en) as ultimo_cargado
  from caravanas c left join propietarios p on p.id = c.propietario_id
 where c.estado in ('activa','salida','baja')
 group by c.establecimiento, coalesce(c.dte_alta, '')
union all
select c.establecimiento, 'baja', coalesce(c.dte_baja, ''), min(c.fecha_baja), max(c.fecha_baja),
       count(*),
       _resumen_lista(array_agg(distinct p.nombre) filter (where p.nombre is not null)),
       _resumen_lista(array_agg(distinct c.categoria::text) filter (where c.categoria is not null)),
       _resumen_lista(array_agg(distinct c.destino_baja) filter (where c.destino_baja is not null)),
       _resumen_lista(array_agg(distinct c.nro_tropa_alta) filter (where c.nro_tropa_alta is not null)),
       _resumen_lista(array_agg(distinct c.motivo_salida::text) filter (where c.motivo_salida is not null)),
       max(c.actualizado_en)
  from caravanas c left join propietarios p on p.id = c.propietario_id
 where c.estado = 'baja'
 group by c.establecimiento, coalesce(c.dte_baja, '');
alter view v_movimientos_dte set (security_invoker = true);
grant select on v_movimientos_dte to authenticated;
revoke all on v_movimientos_dte from anon;

-- Bolsas por propietario, por establecimiento
drop view if exists v_bolsas_resumen;
create view v_bolsas_resumen as
select c.establecimiento, p.nombre as propietario, p.orden,
       c.categoria::text as categoria,
       case when c.bolsa = 'CLASIFICAR' or c.bolsa is null then 'clasificar'
            when c.bolsa = 'FEEDLOT' then 'feedlot' else 'caja' end as grupo,
       (c.fecha_alta is not null and c.fecha_alta + 90 <= current_date) as con_90,
       count(*) as cantidad
  from caravanas c join propietarios p on p.id = c.propietario_id
 where c.estado in ('activa','salida')
 group by c.establecimiento, p.nombre, p.orden, c.categoria, 5, 6;
alter view v_bolsas_resumen set (security_invoker = true);
grant select on v_bolsas_resumen to authenticated;
revoke all on v_bolsas_resumen from anon;

-- Resumen VISEC, por establecimiento
drop view if exists v_visec_resumen;
create view v_visec_resumen as
select c.establecimiento, c.tipo::text as tipo, p.nombre as propietario,
       count(*) filter (where v.estado = 'HABILITADA') as habilitadas,
       count(*) filter (where v.estado = 'INHABILITADA') as inhabilitadas,
       count(*) filter (where v.estado = 'NÚMERO INEXISTENTE') as inexistentes,
       count(*) filter (where v.estado = 'ERROR ARCA') as error_arca,
       count(*) filter (where v.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN')) as en_proceso,
       count(*) filter (where v.caravana is null) as sin_consultar,
       count(*) as total
  from caravanas c join propietarios p on p.id = c.propietario_id
  left join visec_consultas v on v.caravana = c.numero
 where c.estado in ('activa','salida')
 group by c.establecimiento, c.tipo, p.nombre, p.orden order by c.establecimiento, c.tipo, p.orden;
alter view v_visec_resumen set (security_invoker = true);
grant select on v_visec_resumen to authenticated;
revoke all on v_visec_resumen from anon;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
