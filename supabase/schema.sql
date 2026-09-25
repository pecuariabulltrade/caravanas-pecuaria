-- ============================================================
-- Caravanas Pecuaria — esquema Supabase
-- Grupo Bulltrade / PEGSA · establecimiento madre: El Haras
-- Ejecutar completo en el SQL Editor del proyecto nuevo.
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- Tipos
-- ------------------------------------------------------------
do $$ begin
  create type estado_caravana as enum ('virgen','activa','salida','baja','anulada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type categoria_padron as enum ('TORO','VACA','HEMBRA','MACHO');
exception when duplicate_object then null; end $$;

do $$ begin
  create type origen_alta as enum ('wincampo','manual','virgen','padron_inicial');
exception when duplicate_object then null; end $$;

do $$ begin
  create type motivo_salida as enum ('venta','muerte');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_movimiento as enum ('alta','salida','baja','anulacion','reactivacion','correccion');
exception when duplicate_object then null; end $$;

do $$ begin
  create type fuente_movimiento as enum ('wincampo','manual','padron_inicial');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- Propietarios (titulares del alta en SENASA)
-- ------------------------------------------------------------
create table if not exists propietarios (
  id          serial primary key,
  nombre      text not null unique,
  cuit        text,
  renspa      text,
  activo      boolean not null default true,
  orden       int not null default 0
);

insert into propietarios (nombre, orden) values
  ('PEGSA', 1), ('BULLTRADE', 2), ('DARWASH', 3), ('LAS TAPERAS', 4),
  ('EL SAGUIPE', 5), ('ALONSO', 6), ('DANAE', 7)
on conflict (nombre) do nothing;

-- ------------------------------------------------------------
-- Compras de caravanas vírgenes
-- ------------------------------------------------------------
create table if not exists compras_caravanas (
  id            serial primary key,
  fecha         date not null,
  proveedor     text,
  numero_desde  text not null check (numero_desde ~ '^032[0-9]{12}$'),
  numero_hasta  text not null check (numero_hasta ~ '^032[0-9]{12}$'),
  cantidad      int  generated always as ((numero_hasta::bigint - numero_desde::bigint) + 1) stored,
  comprobante   text,
  observaciones text,
  creado_por    text,
  creado_en     timestamptz not null default now(),
  check (numero_hasta::bigint >= numero_desde::bigint)
);

-- ------------------------------------------------------------
-- Padrón de caravanas
-- ------------------------------------------------------------
create table if not exists caravanas (
  numero          text primary key check (numero ~ '^032[0-9]{12}$'),
  estado          estado_caravana not null default 'virgen',
  propietario_id  int references propietarios(id),
  categoria       categoria_padron,
  fecha_alta      date,
  dte_alta        text,
  origen_alta     origen_alta,
  nro_tropa_alta  text,
  fecha_salida    date,
  motivo_salida   motivo_salida,
  destino_salida  text,
  categoria_wc_salida text,
  fecha_baja      date,
  dte_baja        text,
  destino_baja    text,
  compra_id       int references compras_caravanas(id),
  observaciones   text,
  actualizado_por text,
  actualizado_en  timestamptz not null default now(),
  -- coherencia mínima por estado
  check (estado <> 'activa' or (propietario_id is not null and categoria is not null and fecha_alta is not null)),
  check (estado <> 'baja'   or (fecha_baja is not null and dte_baja is not null))
);
create index if not exists caravanas_estado_idx on caravanas(estado);
create index if not exists caravanas_prop_idx   on caravanas(propietario_id);
create index if not exists caravanas_numero_num_idx on caravanas((numero::bigint));

-- ------------------------------------------------------------
-- Historial de movimientos
-- ------------------------------------------------------------
create table if not exists movimientos (
  id              bigserial primary key,
  caravana        text not null references caravanas(numero),
  tipo            tipo_movimiento not null,
  fecha           date not null,
  dte             text,
  propietario_id  int references propietarios(id),
  categoria       categoria_padron,
  origen_destino  text,
  nro_tropa       text,
  fuente          fuente_movimiento not null,
  observaciones   text,
  usuario         text,
  creado_en       timestamptz not null default now()
);
create index if not exists movimientos_caravana_idx on movimientos(caravana);
create index if not exists movimientos_fecha_idx    on movimientos(fecha desc);

-- ------------------------------------------------------------
-- Espejo de WinCampo (lo escribe solo el script de sincronización)
-- ------------------------------------------------------------
create table if not exists wc_ingresos (
  id_wincampo     text primary key,       -- clave estable del movimiento en WinCampo
  caravana        text not null,
  fecha_ingreso   date not null,
  origen          text,
  hotelero        text,
  consignataria   text,
  categoria_wc    text,
  categoria       categoria_padron,
  nro_tropa       text,
  nro_corral      text,
  dte_wc          text,
  es_traslado     boolean not null default false,
  sincronizado_en timestamptz not null default now()
);
create index if not exists wc_ingresos_caravana_idx on wc_ingresos(caravana);
create index if not exists wc_ingresos_fecha_idx    on wc_ingresos(fecha_ingreso desc);

create table if not exists wc_egresos (
  id_wincampo     text primary key,
  caravana        text not null,
  fecha_egreso    date not null,
  destino         text,
  hotelero        text,
  categoria_wc    text,
  categoria       categoria_padron,
  nro_tropa       text,
  motivo          text,                   -- venta / traslado / muerte / otro
  sincronizado_en timestamptz not null default now()
);
create index if not exists wc_egresos_caravana_idx on wc_egresos(caravana);
create index if not exists wc_egresos_fecha_idx    on wc_egresos(fecha_egreso desc);

-- ------------------------------------------------------------
-- Sincronizaciones (solicitudes de Refrescar + corridas del script)
-- ------------------------------------------------------------
create table if not exists sincronizaciones (
  id              bigserial primary key,
  solicitado_por  text,
  solicitado_en   timestamptz not null default now(),
  estado          text not null default 'pendiente' check (estado in ('pendiente','corriendo','ok','error')),
  inicio          timestamptz,
  fin             timestamptz,
  ingresos_nuevos int,
  egresos_nuevos  int,
  salidas_marcadas int,
  error           text
);

-- ------------------------------------------------------------
-- Turno de carga (una sola fila)
-- ------------------------------------------------------------
create table if not exists bloqueo_edicion (
  id               int primary key default 1 check (id = 1),
  usuario          text,
  tomado_en        timestamptz,
  ultima_actividad timestamptz
);
insert into bloqueo_edicion (id) values (1) on conflict do nothing;

-- ------------------------------------------------------------
-- Funciones
-- ------------------------------------------------------------

-- Mapeo categoría WinCampo -> padrón
create or replace function mapear_categoria(cat_wc text)
returns categoria_padron language sql immutable as $$
  select case
    when cat_wc is null then null
    when upper(cat_wc) in ('TO','TORO','TOROS') then 'TORO'::categoria_padron
    when upper(cat_wc) in ('VA','VACA','VACAS') then 'VACA'::categoria_padron
    when upper(cat_wc) in ('VQ','TH','VAQUILLONA','VAQUILLONAS','TERNERA','TERNERAS','HEMBRA') then 'HEMBRA'::categoria_padron
    when upper(cat_wc) in ('TM','NT','NV','TERNERO','TERNEROS','NOVILLO','NOVILLOS','NOVILLITO','NOVILLITOS','MACHO') then 'MACHO'::categoria_padron
    else null end
$$;

-- Expande un rango desde/hasta en números de 15 dígitos (máx 10.000)
create or replace function expandir_rango(p_desde text, p_hasta text)
returns setof text language plpgsql immutable as $$
declare d bigint := p_desde::bigint; h bigint := p_hasta::bigint;
begin
  if p_desde !~ '^032[0-9]{12}$' or p_hasta !~ '^032[0-9]{12}$' then
    raise exception 'Los números deben tener 15 dígitos y empezar con 032';
  end if;
  if h < d then raise exception 'El número hasta es menor que el desde'; end if;
  if h - d + 1 > 10000 then raise exception 'El rango supera las 10.000 caravanas'; end if;
  return query select lpad(g::text, 15, '0') from generate_series(d, h) g;
end $$;

-- Toma / renueva / libera el turno de carga. Devuelve el estado actual.
create or replace function tomar_turno(p_usuario text, p_liberar boolean default false)
returns bloqueo_edicion language plpgsql security definer as $$
declare b bloqueo_edicion;
begin
  select * into b from bloqueo_edicion where id = 1 for update;
  if p_liberar then
    if b.usuario = p_usuario then
      update bloqueo_edicion set usuario = null, tomado_en = null, ultima_actividad = null where id = 1;
    end if;
  elsif b.usuario is null or b.usuario = p_usuario
        or b.ultima_actividad < now() - interval '15 minutes' then
    update bloqueo_edicion
       set usuario = p_usuario,
           tomado_en = case when b.usuario = p_usuario then b.tomado_en else now() end,
           ultima_actividad = now()
     where id = 1;
  end if;
  select * into b from bloqueo_edicion where id = 1;
  return b;
end $$;

-- Verifica que el usuario tenga el turno (para las operaciones masivas)
create or replace function _exigir_turno(p_usuario text) returns void language plpgsql as $$
declare b bloqueo_edicion;
begin
  select * into b from bloqueo_edicion where id = 1;
  if b.usuario is distinct from p_usuario or b.ultima_actividad < now() - interval '15 minutes' then
    raise exception 'No tenés el turno de carga (lo tiene %)', coalesce(b.usuario, 'nadie');
  end if;
  update bloqueo_edicion set ultima_actividad = now() where id = 1;
end $$;

-- Alta masiva (atómica). Solo vírgenes o inexistentes; devuelve resumen.
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
  p_observaciones text default null
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
      insert into caravanas (numero, estado, propietario_id, categoria, fecha_alta, dte_alta, origen_alta, nro_tropa_alta, compra_id, observaciones, actualizado_por)
      values (v_num, 'activa', p_propietario_id, p_categoria, p_fecha_alta, p_dte, p_origen, p_nro_tropa, p_compra_id, p_observaciones, p_usuario);
      v_nuevas := v_nuevas + 1;
    elsif v_est = 'virgen' then
      update caravanas set estado = 'activa', propietario_id = p_propietario_id, categoria = p_categoria,
        fecha_alta = p_fecha_alta, dte_alta = p_dte, origen_alta = p_origen, nro_tropa_alta = p_nro_tropa,
        observaciones = coalesce(p_observaciones, observaciones), actualizado_por = p_usuario, actualizado_en = now()
      where numero = v_num;
      v_virgenes := v_virgenes + 1;
    else
      v_omitidas := v_omitidas || v_num;
      continue;
    end if;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, nro_tropa, fuente, observaciones, usuario)
    values (v_num, 'alta', p_fecha_alta, p_dte, p_propietario_id, p_categoria, p_nro_tropa, p_fuente, p_observaciones, p_usuario);
  end loop;

  return jsonb_build_object('nuevas', v_nuevas, 'virgenes_usadas', v_virgenes,
                            'omitidas', to_jsonb(v_omitidas), 'total', v_nuevas + v_virgenes);
end $$;

-- Alta usando las primeras N vírgenes disponibles (opcionalmente de una compra)
create or replace function alta_con_virgenes(
  p_cantidad int, p_propietario_id int, p_categoria categoria_padron, p_fecha_alta date,
  p_dte text, p_usuario text, p_compra_id int default null, p_observaciones text default null
) returns jsonb language plpgsql security definer as $$
declare v_nums text[];
begin
  select array_agg(numero order by numero::bigint) into v_nums
  from (select numero from caravanas
         where estado = 'virgen' and (p_compra_id is null or compra_id = p_compra_id)
         order by numero::bigint limit p_cantidad) s;
  if coalesce(array_length(v_nums,1),0) < p_cantidad then
    raise exception 'Solo hay % vírgenes disponibles', coalesce(array_length(v_nums,1),0);
  end if;
  return alta_masiva(v_nums, p_propietario_id, p_categoria, p_fecha_alta, p_dte, 'virgen', 'manual', p_usuario, null, p_compra_id, p_observaciones)
         || jsonb_build_object('desde', v_nums[1], 'hasta', v_nums[array_length(v_nums,1)]);
end $$;

-- Baja masiva (atómica). Solo 'salida' o, si p_permitir_activas, también 'activa' (baja manual).
create or replace function baja_masiva(
  p_numeros    text[],
  p_fecha_baja date,
  p_dte        text,
  p_destino    text,
  p_fuente     fuente_movimiento,
  p_usuario    text,
  p_permitir_activas boolean default false,
  p_observaciones text default null
) returns jsonb language plpgsql security definer as $$
declare
  v_num text; c caravanas; v_bajas int := 0; v_omitidas text[] := '{}';
begin
  perform _exigir_turno(p_usuario);
  if coalesce(p_dte,'') = '' then raise exception 'El DTE de egreso es obligatorio'; end if;
  foreach v_num in array p_numeros loop
    select * into c from caravanas where numero = v_num;
    if c.numero is null or not (c.estado = 'salida' or (p_permitir_activas and c.estado = 'activa')) then
      v_omitidas := v_omitidas || v_num; continue;
    end if;
    if p_fecha_baja < c.fecha_alta then
      raise exception 'Caravana %: fecha de baja anterior a la de alta (%)', v_num, c.fecha_alta;
    end if;
    update caravanas set estado = 'baja', fecha_baja = p_fecha_baja, dte_baja = p_dte, destino_baja = p_destino,
      fecha_salida = coalesce(fecha_salida, p_fecha_baja),
      observaciones = coalesce(p_observaciones, observaciones), actualizado_por = p_usuario, actualizado_en = now()
    where numero = v_num;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, origen_destino, fuente, observaciones, usuario)
    values (v_num, 'baja', p_fecha_baja, p_dte, c.propietario_id, c.categoria, p_destino, p_fuente, p_observaciones, p_usuario);
    v_bajas := v_bajas + 1;
  end loop;
  return jsonb_build_object('bajas', v_bajas, 'omitidas', to_jsonb(v_omitidas));
end $$;

-- Anular o reactivar una caravana (requiere observación)
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
      observaciones = p_observacion, actualizado_por = p_usuario, actualizado_en = now() where numero = p_numero;
    insert into movimientos (caravana, tipo, fecha, propietario_id, categoria, fuente, observaciones, usuario)
    values (p_numero, 'reactivacion', current_date, c.propietario_id, c.categoria, 'manual', p_observacion, p_usuario);
  else
    raise exception 'Acción desconocida: %', p_accion;
  end if;
end $$;

-- Registrar compra de vírgenes y generar las filas
create or replace function registrar_compra(
  p_fecha date, p_proveedor text, p_desde text, p_hasta text, p_comprobante text, p_usuario text, p_observaciones text default null
) returns jsonb language plpgsql security definer as $$
declare v_id int; v_choques text[];
begin
  select array_agg(numero) into v_choques
    from caravanas where numero in (select expandir_rango(p_desde, p_hasta));
  if v_choques is not null then
    raise exception 'Ya existen % caravanas de ese rango (ej. %)', array_length(v_choques,1), v_choques[1];
  end if;
  insert into compras_caravanas (fecha, proveedor, numero_desde, numero_hasta, comprobante, observaciones, creado_por)
  values (p_fecha, p_proveedor, p_desde, p_hasta, p_comprobante, p_observaciones, p_usuario) returning id into v_id;
  insert into caravanas (numero, estado, compra_id, actualizado_por)
  select n, 'virgen', v_id, p_usuario from expandir_rango(p_desde, p_hasta) n;
  return jsonb_build_object('compra_id', v_id, 'cantidad', (p_hasta::bigint - p_desde::bigint) + 1);
end $$;

-- Marcar salidas desde wc_egresos (lo llama el script con la service key)
create or replace function marcar_salidas() returns int language plpgsql security definer as $$
declare n int;
begin
  with ult as (
    select distinct on (caravana) caravana, fecha_egreso, destino, categoria_wc, motivo
      from wc_egresos
     where lower(motivo) in ('venta','muerte','v','m')
     order by caravana, fecha_egreso desc
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
       and u.fecha_egreso >= coalesce(c.fecha_alta, u.fecha_egreso)
     returning c.numero, u.fecha_egreso, u.destino, u.motivo
  )
  insert into movimientos (caravana, tipo, fecha, origen_destino, fuente, observaciones, usuario)
  select numero, 'salida', fecha_egreso, destino, 'wincampo', 'motivo WinCampo: ' || motivo, 'sync' from upd;
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------
-- Vistas para las pantallas
-- ------------------------------------------------------------
create or replace view v_ingresos_cruce as
select w.*,
       c.estado as estado_padron, c.propietario_id, p.nombre as propietario, c.categoria as categoria_padron,
       c.fecha_alta, c.dte_alta,
       case when c.numero is null or c.estado = 'virgen' then 'pendiente'
            when c.estado = 'activa' then 'en_padron'
            when c.estado in ('salida','baja') then 'revisar'
            else 'anulada' end as situacion
  from wc_ingresos w
  left join caravanas c on c.numero = w.caravana
  left join propietarios p on p.id = c.propietario_id;

create or replace view v_egresos_cruce as
select c.numero as caravana, c.estado as estado_padron, c.propietario_id, p.nombre as propietario,
       c.categoria as categoria_padron, c.categoria_wc_salida as categoria_wincampo,
       c.fecha_alta, c.dte_alta, c.fecha_salida, c.motivo_salida, c.destino_salida,
       c.fecha_baja, c.dte_baja, c.destino_baja,
       e.nro_tropa, e.hotelero, e.fecha_egreso, e.destino, e.motivo as motivo_wincampo,
       case when c.estado = 'salida' then 'pendiente_dte'
            when c.estado = 'baja' then 'dada_de_baja' else c.estado::text end as situacion
  from caravanas c
  left join propietarios p on p.id = c.propietario_id
  left join lateral (
    select * from wc_egresos e where e.caravana = c.numero
      and lower(e.motivo) in ('venta','muerte','v','m')
     order by e.fecha_egreso desc limit 1) e on true
 where c.estado in ('salida','baja');

create or replace view v_egresos_sin_alta as
select e.*
  from wc_egresos e
  left join caravanas c on c.numero = e.caravana
 where lower(e.motivo) in ('venta','muerte','v','m')
   and (c.numero is null or c.estado = 'virgen');

create or replace view v_resumen as
select p.nombre as propietario,
       count(*) filter (where c.estado = 'activa') as activas,
       count(*) filter (where c.estado = 'salida') as salidas_pendientes,
       count(*) filter (where c.estado = 'baja')   as bajas
  from propietarios p left join caravanas c on c.propietario_id = p.id
 group by p.nombre, p.orden order by p.orden;

-- ------------------------------------------------------------
-- Seguridad: usuarios autenticados leen y escriben; anon nada
-- ------------------------------------------------------------
alter table propietarios       enable row level security;
alter table compras_caravanas  enable row level security;
alter table caravanas          enable row level security;
alter table movimientos        enable row level security;
alter table wc_ingresos        enable row level security;
alter table wc_egresos         enable row level security;
alter table sincronizaciones   enable row level security;
alter table bloqueo_edicion    enable row level security;

do $$
declare t text;
begin
  foreach t in array array['propietarios','compras_caravanas','caravanas','movimientos','wc_ingresos','wc_egresos','sincronizaciones','bloqueo_edicion'] loop
    execute format('drop policy if exists auth_all on %I', t);
    execute format('create policy auth_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
