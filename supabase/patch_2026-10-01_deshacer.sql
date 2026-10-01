-- Patch 01/10/2026: deshacer altas y bajas desde Movimientos (resumen por DTE).
--  deshacer_alta: la caravana vuelve a su situación anterior al alta:
--     - si el alta usó una virgen -> vuelve a 'virgen' (disponible en la compra);
--     - si vino de WinCampo / manual / padrón inicial -> se borra del padrón (vuelve a "pendiente de alta"
--       en Ingresos si WinCampo la tiene). Si WinCampo ya la había dado por salida, también se deshace eso.
--  deshacer_baja: la caravana vuelve a 'activa' y, si WinCampo la tiene por vendida/muerta, a 'salida'
--     (pendiente de DTE) otra vez.
--  Todo queda registrado en la tabla reversiones (con la foto anterior de la caravana y sus movimientos).

alter type tipo_movimiento add value if not exists 'reversion';

create table if not exists reversiones (
  id          bigserial primary key,
  caravana    text not null,
  accion      text not null,            -- deshacer_alta / deshacer_baja
  anterior    jsonb not null,           -- caravana + movimientos antes de deshacer
  observaciones text,
  usuario     text,
  creado_en   timestamptz not null default now()
);
create index if not exists reversiones_caravana_idx on reversiones(caravana);
alter table reversiones enable row level security;
drop policy if exists auth_all on reversiones;
create policy auth_all on reversiones for all to authenticated using (true) with check (true);
grant select, insert on reversiones to authenticated;
revoke all on reversiones from anon;

create or replace function deshacer_alta(p_numeros text[], p_usuario text, p_observaciones text default null)
returns jsonb language plpgsql security definer as $$
declare v_num text; c caravanas; v_virgenes int := 0; v_borradas int := 0; v_omitidas text[] := '{}'; v_foto jsonb;
begin
  perform _exigir_turno(p_usuario);
  foreach v_num in array p_numeros loop
    v_num := upper(trim(v_num));
    select * into c from caravanas where numero = v_num;
    if c.numero is null or c.estado not in ('activa','salida') then v_omitidas := v_omitidas || v_num; continue; end if;
    v_foto := jsonb_build_object('caravana', to_jsonb(c),
                'movimientos', (select coalesce(jsonb_agg(to_jsonb(m) order by m.id), '[]'::jsonb) from movimientos m where m.caravana = v_num));
    insert into reversiones (caravana, accion, anterior, observaciones, usuario) values (v_num, 'deshacer_alta', v_foto, p_observaciones, p_usuario);
    if c.origen_alta = 'virgen' then
      update caravanas set estado = 'virgen', propietario_id = null, categoria = null, fecha_alta = null, dte_alta = null,
        origen_alta = null, nro_tropa_alta = null, procedencia_alta = null, bolsa = null,
        fecha_salida = null, motivo_salida = null, destino_salida = null, categoria_wc_salida = null,
        observaciones = null, actualizado_por = p_usuario, actualizado_en = now()
      where numero = v_num;
      delete from movimientos where caravana = v_num;
      insert into movimientos (caravana, tipo, fecha, fuente, observaciones, usuario)
      values (v_num, 'reversion', current_date, 'manual', coalesce(p_observaciones, 'Alta deshecha: vuelve a virgen'), p_usuario);
      v_virgenes := v_virgenes + 1;
    else
      delete from movimientos where caravana = v_num;
      delete from caravanas where numero = v_num;
      v_borradas := v_borradas + 1;
    end if;
  end loop;
  return jsonb_build_object('virgenes', v_virgenes, 'borradas', v_borradas, 'total', v_virgenes + v_borradas, 'omitidas', to_jsonb(v_omitidas));
end $$;

create or replace function deshacer_baja(p_numeros text[], p_usuario text, p_observaciones text default null)
returns jsonb language plpgsql security definer as $$
declare v_num text; c caravanas; v_ok int := 0; v_omitidas text[] := '{}'; v_hechas text[] := '{}'; v_salidas int := 0; v_foto jsonb;
begin
  perform _exigir_turno(p_usuario);
  foreach v_num in array p_numeros loop
    v_num := upper(trim(v_num));
    select * into c from caravanas where numero = v_num;
    if c.numero is null or c.estado <> 'baja' then v_omitidas := v_omitidas || v_num; continue; end if;
    v_foto := jsonb_build_object('caravana', to_jsonb(c),
                'movimientos', (select coalesce(jsonb_agg(to_jsonb(m) order by m.id), '[]'::jsonb) from movimientos m where m.caravana = v_num));
    insert into reversiones (caravana, accion, anterior, observaciones, usuario) values (v_num, 'deshacer_baja', v_foto, p_observaciones, p_usuario);
    update caravanas set estado = 'activa', fecha_baja = null, dte_baja = null, destino_baja = null,
      fecha_salida = null, motivo_salida = null, destino_salida = null, categoria_wc_salida = null,
      actualizado_por = p_usuario, actualizado_en = now()
    where numero = v_num;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, fuente, observaciones, usuario)
    values (v_num, 'reversion', current_date, c.dte_baja, c.propietario_id, c.categoria, 'manual',
            coalesce(p_observaciones, 'Baja deshecha (DTE ' || coalesce(c.dte_baja,'') || ')'), p_usuario);
    v_hechas := v_hechas || v_num; v_ok := v_ok + 1;
  end loop;
  if array_length(v_hechas, 1) > 0 then v_salidas := marcar_salidas(v_hechas); end if;
  return jsonb_build_object('total', v_ok, 'salidas', v_salidas, 'omitidas', to_jsonb(v_omitidas));
end $$;

-- Resumen por DTE según el estado ACTUAL del padrón (altas: caravanas dadas de alta con ese DTE;
-- bajas: caravanas hoy en baja con ese DTE). Si se deshace un alta o una baja, desaparece de acá.
drop view if exists v_movimientos_dte;
create view v_movimientos_dte as
select 'alta'::text as tipo, coalesce(c.dte_alta, '') as dte, min(c.fecha_alta) as fecha_desde, max(c.fecha_alta) as fecha_hasta,
       count(*) as caravanas, string_agg(distinct p.nombre, ', ') as propietarios,
       string_agg(distinct c.categoria::text, ', ') as categorias,
       string_agg(distinct c.procedencia_alta, ', ') as origen_destino,
       string_agg(distinct c.nro_tropa_alta, ', ') as tropas,
       string_agg(distinct c.origen_alta::text, ', ') as fuente,
       max(c.actualizado_en) as ultimo_cargado
  from caravanas c left join propietarios p on p.id = c.propietario_id
 where c.estado in ('activa','salida','baja')
 group by coalesce(c.dte_alta, '')
union all
select 'baja', coalesce(c.dte_baja, ''), min(c.fecha_baja), max(c.fecha_baja),
       count(*), string_agg(distinct p.nombre, ', '),
       string_agg(distinct c.categoria::text, ', '),
       string_agg(distinct c.destino_baja, ', '),
       string_agg(distinct c.nro_tropa_alta, ', '),
       string_agg(distinct c.motivo_salida::text, ', '),
       max(c.actualizado_en)
  from caravanas c left join propietarios p on p.id = c.propietario_id
 where c.estado = 'baja'
 group by coalesce(c.dte_baja, '');
alter view v_movimientos_dte set (security_invoker = true);
grant select on v_movimientos_dte to authenticated;
revoke all on v_movimientos_dte from anon;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
