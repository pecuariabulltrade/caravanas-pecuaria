-- Patch 23/10/2026: estado VISEC de las caravanas (https://carne.visec.com.ar).
-- El robot sync/visec_consulta.py arma un lote en VISEC con las caravanas pendientes, lo valida y guarda
-- el resultado por caravana en visec_consultas. Desde el portal se puede pedir una consulta puntual
-- (visec_solicitudes). Las vistas del portal muestran visec_estado / visec_fecha.

create table if not exists visec_consultas (
  caravana       text primary key,
  estado         text not null,          -- HABILITADA / INHABILITADA / NÚMERO INEXISTENTE / EN PROCESO / EN ESPERA / EN VALIDACIÓN / ERROR ARCA
  observacion    text,
  informe        text,                   -- nro de informe (lote) en VISEC
  fecha          date not null default current_date,
  actualizado_en timestamptz not null default now(),
  intentos       int not null default 1       -- veces que se consultó (para no reintentar eternamente los ERROR ARCA)
);
alter table visec_consultas add column if not exists intentos int not null default 1;
create index if not exists visec_consultas_estado_idx on visec_consultas(estado);

create table if not exists visec_solicitudes (
  id             bigserial primary key,
  caravana       text not null,
  solicitado_por text,
  solicitado_en  timestamptz not null default now(),
  atendido       boolean not null default false
);
create index if not exists visec_solicitudes_pend_idx on visec_solicitudes(atendido) where not atendido;

create table if not exists visec_corridas (
  id        bigserial primary key,
  inicio    timestamptz not null default now(),
  fin       timestamptz,
  informe   text,
  cantidad  int,
  estado    text,                        -- corriendo / ok / error / sin_pendientes
  detalle   text
);

alter table visec_consultas  enable row level security;
alter table visec_solicitudes enable row level security;
alter table visec_corridas   enable row level security;
drop policy if exists auth_all on visec_consultas;  create policy auth_all on visec_consultas  for all to authenticated using (true) with check (true);
drop policy if exists auth_all on visec_solicitudes; create policy auth_all on visec_solicitudes for all to authenticated using (true) with check (true);
drop policy if exists auth_all on visec_corridas;   create policy auth_all on visec_corridas   for all to authenticated using (true) with check (true);
grant select on visec_consultas, visec_corridas to authenticated;
grant select, insert on visec_solicitudes to authenticated;
grant usage, select on sequence visec_solicitudes_id_seq to authenticated;
revoke all on visec_consultas, visec_solicitudes, visec_corridas from anon;

-- Caravanas a consultar: las electrónicas que están en el padrón (ACTIVAS y SALIDAS; las vírgenes, bajas y
-- anuladas no). Orden: 1) pedidas a mano desde el portal, 2) machos (MACHO/TORO) de PEGSA y BULLTRADE,
-- 3) el resto; dentro de cada grupo primero las activas y las de alta más reciente.
-- Se reintentan las que quedaron con resultado provisorio (EN PROCESO / EN ESPERA / EN VALIDACIÓN / ERROR ARCA) de días anteriores, hasta 3 intentos.
-- ERROR ARCA: VISEC no pudo leer el CUIT en ARCA al validar (lo pone el robot; no es un resultado real).
create or replace function visec_pendientes(p_max int default 100) returns setof text language sql stable security definer as $$
  select numero from (
    select distinct on (numero) numero, prio, estado, fecha_alta from (
    select c.numero, 0 as prio, c.estado, c.fecha_alta
      from caravanas c join visec_solicitudes s on s.caravana = c.numero and not s.atendido
     where c.tipo = 'electronica'
    union
    select c.numero,
           case when c.categoria::text in ('MACHO','TORO') and p.nombre in ('PEGSA','BULLTRADE') then 1 else 2 end,
           c.estado, c.fecha_alta
      from caravanas c
      left join propietarios p on p.id = c.propietario_id
      left join visec_consultas v on v.caravana = c.numero
     where c.tipo = 'electronica' and c.estado in ('activa','salida')
       and (v.caravana is null or (v.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA') and v.fecha < current_date and v.intentos <= 3))
  ) u order by numero, prio) t
  order by prio, (estado <> 'activa'), fecha_alta desc nulls last, numero limit p_max;
$$;

-- Guardar resultados de un lote (lo llama el robot con la service key)
create or replace function visec_guardar(p_filas jsonb, p_informe text) returns int language plpgsql security definer as $$
declare n int;
begin
  insert into visec_consultas (caravana, estado, observacion, informe, fecha, actualizado_en)
  select x.caravana, upper(trim(x.estado)), x.observacion, p_informe, current_date, now()
    from jsonb_to_recordset(p_filas) as x(caravana text, estado text, observacion text)
   where x.caravana ~ '^032[0-9]{12}$' and coalesce(x.estado,'') <> ''
  on conflict (caravana) do update set estado = excluded.estado, observacion = excluded.observacion,
     informe = excluded.informe, fecha = excluded.fecha, actualizado_en = now(), intentos = visec_consultas.intentos + 1;
  get diagnostics n = row_count;
  update visec_solicitudes s set atendido = true
   where not s.atendido and s.caravana in (select x.caravana from jsonb_to_recordset(p_filas) as x(caravana text));
  return n;
end $$;

-- Pedir consulta desde el portal (usuario logueado)
create or replace function visec_solicitar(p_numeros text[], p_usuario text) returns int language plpgsql security definer as $$
declare n int;
begin
  insert into visec_solicitudes (caravana, solicitado_por)
  select distinct upper(trim(x)), p_usuario from unnest(p_numeros) x
   where upper(trim(x)) ~ '^032[0-9]{12}$'
     and not exists (select 1 from visec_solicitudes s where s.caravana = upper(trim(x)) and not s.atendido);
  get diagnostics n = row_count;
  return n;
end $$;

-- Vistas del portal con el estado VISEC
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
select c.numero as caravana, c.estado as estado_padron, c.propietario_id, p.nombre as propietario,
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

-- Resumen VISEC por propietario (para Inicio): electrónicas en el padrón (activas y salidas)
drop view if exists v_visec_resumen;
create view v_visec_resumen as
select p.nombre as propietario,
       count(*) filter (where v.estado = 'HABILITADA') as habilitadas,
       count(*) filter (where v.estado = 'INHABILITADA') as inhabilitadas,
       count(*) filter (where v.estado = 'NÚMERO INEXISTENTE') as inexistentes,
       count(*) filter (where v.estado = 'ERROR ARCA') as error_arca,
       count(*) filter (where v.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN')) as en_proceso,
       count(*) filter (where v.caravana is null) as sin_consultar,
       count(*) as total
  from caravanas c join propietarios p on p.id = c.propietario_id
  left join visec_consultas v on v.caravana = c.numero
 where c.tipo = 'electronica' and c.estado in ('activa','salida')
 group by p.nombre, p.orden order by p.orden;
alter view v_visec_resumen set (security_invoker = true);
grant select on v_visec_resumen to authenticated;
revoke all on v_visec_resumen from anon;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
