-- Patch 28/09/2026 (2): el stock solo guarda caravana, categoría, propietario WinCampo y tropa.
-- Validador de categoría: para las que están en el padrón, categoria_ok dice si la categoría
-- de WinCampo (mapeada a TORO/VACA/HEMBRA/MACHO) coincide con la del padrón SIGSA.

drop view if exists v_stock_cruce;
alter table wc_stock drop column if exists nro_caravana;
alter table wc_stock drop column if exists fecha_ingreso;
alter table wc_stock drop column if exists origen;
alter table wc_stock drop column if exists nro_corral;
alter table wc_stock drop column if exists kg_ingreso;
alter table wc_stock drop column if exists dias_en_stock;
drop index if exists wc_stock_corral_idx;

create or replace function reemplazar_stock(p_filas jsonb) returns int language plpgsql security definer as $$
declare n int;
begin
  delete from wc_stock;
  insert into wc_stock (caravana, nro_tropa, hotelero, categoria_wc, categoria, sincronizado_en)
  select distinct on (x.caravana) x.caravana, x.nro_tropa, x.hotelero, x.categoria_wc, mapear_categoria(x.categoria_wc), now()
    from jsonb_to_recordset(p_filas) as x(caravana text, nro_tropa text, hotelero text, categoria_wc text)
   where x.caravana ~ '^032[0-9]{12}$'
   order by x.caravana;
  get diagnostics n = row_count;
  return n;
end $$;

create view v_stock_cruce as
select s.caravana, s.nro_tropa, s.hotelero, s.categoria_wc, s.categoria, s.sincronizado_en,
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
            else (s.categoria = c.categoria) end as categoria_ok
  from wc_stock s
  left join caravanas c on c.numero = s.caravana
  left join propietarios p on p.id = c.propietario_id;
alter view v_stock_cruce set (security_invoker = true);
grant select on v_stock_cruce to authenticated;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
revoke all on wc_stock, v_stock_cruce from anon;
