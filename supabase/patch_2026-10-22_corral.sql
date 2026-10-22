-- Patch 22/10/2026: el stock guarda el corral de WinCampo y la vista deriva el establecimiento:
--   corral 1 a 199 -> EL HARAS (feedlot); corral 200 en adelante (o sin número) -> CAMPO.
alter table wc_stock add column if not exists nro_corral text;

create or replace function reemplazar_stock(p_filas jsonb) returns int language plpgsql security definer as $$
declare n int;
begin
  truncate wc_stock;
  insert into wc_stock (caravana, nro_tropa, hotelero, categoria_wc, categoria, nro_corral, sincronizado_en)
  select distinct on (x.caravana) x.caravana, x.nro_tropa, x.hotelero, x.categoria_wc, mapear_categoria(x.categoria_wc), x.nro_corral, now()
    from jsonb_to_recordset(p_filas) as x(caravana text, nro_tropa text, hotelero text, categoria_wc text, nro_corral text)
   where x.caravana ~ '^032[0-9]{12}$'
   order by x.caravana;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function establecimiento_por_corral(p_corral text) returns text language sql immutable as $$
  select case when p_corral ~ '^\s*\d+\s*$' and p_corral::int between 1 and 199 then 'EL HARAS'
              when p_corral ~ '^\s*\d+\s*$' then 'CAMPO'
              else null end;
$$;

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
            else (s.categoria = c.categoria) end as categoria_ok
  from wc_stock s
  left join caravanas c on c.numero = s.caravana
  left join propietarios p on p.id = c.propietario_id;
alter view v_stock_cruce set (security_invoker = true);
grant select on v_stock_cruce to authenticated;
revoke all on v_stock_cruce from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
