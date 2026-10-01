-- Patch 28/09/2026 (3): Supabase rechaza "delete" sin where dentro de reemplazar_stock -> truncate.
create or replace function reemplazar_stock(p_filas jsonb) returns int language plpgsql security definer as $$
declare n int;
begin
  truncate wc_stock;
  insert into wc_stock (caravana, nro_tropa, hotelero, categoria_wc, categoria, sincronizado_en)
  select distinct on (x.caravana) x.caravana, x.nro_tropa, x.hotelero, x.categoria_wc, mapear_categoria(x.categoria_wc), now()
    from jsonb_to_recordset(p_filas) as x(caravana text, nro_tropa text, hotelero text, categoria_wc text)
   where x.caravana ~ '^032[0-9]{12}$'
   order by x.caravana;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
