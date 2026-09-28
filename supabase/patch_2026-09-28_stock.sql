-- Patch 28/09/2026: stock real del feedlot (WinCampo) cruzado con el padrón SENASA.
-- La sincronización reemplaza la tabla wc_stock entera en cada corrida (foto del stock de hoy).
-- La vista v_stock_cruce dice, por cada caravana en stock, si está activa en el padrón y, si no,
-- el motivo: sin alta todavía, ya dada de baja en SENASA, con salida marcada, anulada.
-- v_padron_sin_stock: activas en el padrón que hoy no están en el stock de WinCampo.

create table if not exists wc_stock (
  caravana        text primary key,
  nro_caravana    text,                   -- caravana visual / número de manejo
  fecha_ingreso   date,
  nro_tropa       text,
  hotelero        text,
  origen          text,
  categoria_wc    text,
  categoria       categoria_padron,
  nro_corral      text,
  kg_ingreso      numeric,
  dias_en_stock   int,
  sincronizado_en timestamptz not null default now()
);
create index if not exists wc_stock_hotelero_idx on wc_stock(hotelero);
create index if not exists wc_stock_corral_idx   on wc_stock(nro_corral);
alter table wc_stock enable row level security;
drop policy if exists auth_all on wc_stock;
create policy auth_all on wc_stock for all to authenticated using (true) with check (true);
grant select, insert, update, delete on wc_stock to authenticated;

-- Reemplazo atómico del stock (lo llama el script de sincronización con la service key)
create or replace function reemplazar_stock(p_filas jsonb) returns int language plpgsql security definer as $$
declare n int;
begin
  delete from wc_stock;
  insert into wc_stock (caravana, nro_caravana, fecha_ingreso, nro_tropa, hotelero, origen, categoria_wc, categoria, nro_corral, kg_ingreso, dias_en_stock, sincronizado_en)
  select distinct on (x.caravana) x.caravana, x.nro_caravana, x.fecha_ingreso, x.nro_tropa, x.hotelero, x.origen, x.categoria_wc,
         mapear_categoria(x.categoria_wc), x.nro_corral, x.kg_ingreso, x.dias_en_stock, now()
    from jsonb_to_recordset(p_filas) as x(caravana text, nro_caravana text, fecha_ingreso date, nro_tropa text, hotelero text, origen text,
                                          categoria_wc text, nro_corral text, kg_ingreso numeric, dias_en_stock int)
   where x.caravana ~ '^032[0-9]{12}$'
   order by x.caravana, x.fecha_ingreso desc nulls last;
  get diagnostics n = row_count;
  return n;
end $$;

drop view if exists v_stock_cruce;
create view v_stock_cruce as
select s.*,
       c.estado as estado_padron, c.propietario_id, p.nombre as propietario, c.categoria as categoria_padron,
       c.fecha_alta, c.dte_alta, c.fecha_salida, c.motivo_salida, c.fecha_baja, c.dte_baja, c.destino_baja, c.bolsa,
       case when c.numero is null or c.estado = 'virgen' then 'sin_alta'
            when c.estado = 'activa' then 'activa'
            when c.estado = 'baja'   then 'baja'
            when c.estado = 'salida' then 'salida'
            else 'anulada' end as situacion,
       case when c.numero is null or c.estado = 'virgen' then 'Todavía no se dio de alta en el padrón SENASA'
            when c.estado = 'activa' then 'Activa en el padrón'
            when c.estado = 'baja'   then 'Ya salió del padrón SENASA (baja con DTE ' || coalesce(c.dte_baja, 's/d') || ' el ' || to_char(c.fecha_baja, 'DD/MM/YYYY') || ')'
            when c.estado = 'salida' then 'WinCampo la dio por salida el ' || to_char(c.fecha_salida, 'DD/MM/YYYY') || ' pero sigue en stock: revisar'
            else 'Anulada en el padrón' end as motivo
  from wc_stock s
  left join caravanas c on c.numero = s.caravana
  left join propietarios p on p.id = c.propietario_id;
alter view v_stock_cruce set (security_invoker = true);
grant select on v_stock_cruce to authenticated;

drop view if exists v_padron_sin_stock;
create view v_padron_sin_stock as
select c.numero as caravana, c.estado as estado_padron, p.nombre as propietario, c.categoria as categoria_padron,
       c.fecha_alta, c.dte_alta, c.bolsa, c.fecha_salida, c.motivo_salida,
       (select max(e.fecha_egreso) from wc_egresos e where e.caravana = c.numero) as ultimo_egreso_wc
  from caravanas c
  left join propietarios p on p.id = c.propietario_id
 where c.estado in ('activa','salida') and c.tipo = 'electronica'
   and not exists (select 1 from wc_stock s where s.caravana = c.numero);
alter view v_padron_sin_stock set (security_invoker = true);
grant select on v_padron_sin_stock to authenticated;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
revoke all on wc_stock, v_stock_cruce, v_padron_sin_stock from anon;
