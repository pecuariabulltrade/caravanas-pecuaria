-- Patch 26/09/2026 (puesta a punto)
--  1. El padrón admite caravanas visuales (no electrónicas, p.ej. TY324JM04) además de las 032.
--  2. Categoría MIXTO (solo para visuales viejas cargadas como HEMBRA/MACHO).
--  3. Bolsa: FEEDLOT si el alta viene de WinCampo, CLASIFICAR si es manual; la pestaña
--     Clasificar asigna número de bolsa (clasificar_masiva) y se puede dar de baja por bolsa.
--  4. Propietario ALONSO DANAE (uno solo).

-- 1. caravanas visuales
alter table caravanas drop constraint if exists caravanas_numero_check;
alter table caravanas add constraint caravanas_numero_check check (numero ~ '^[A-Z0-9][A-Z0-9-]{2,24}$');
alter table caravanas add column if not exists tipo text generated always as
  (case when numero ~ '^032[0-9]{12}$' then 'electronica' else 'visual' end) stored;
create index if not exists caravanas_tipo_idx on caravanas(tipo);
drop index if exists caravanas_numero_num_idx;

-- 2. categoría MIXTO
alter type categoria_padron add value if not exists 'MIXTO';
alter type tipo_movimiento add value if not exists 'clasificacion';

-- 3. bolsa
alter table caravanas add column if not exists bolsa text;
create index if not exists caravanas_bolsa_idx on caravanas(bolsa);
update caravanas set bolsa = upper(trim(substring(observaciones from '^Bolsa: (.*)$'))),
                     observaciones = null
 where bolsa is null and observaciones ~ '^Bolsa: ';

-- 4. propietario ALONSO DANAE
update propietarios set nombre = 'ALONSO DANAE' where nombre = 'ALONSO';
delete from propietarios where nombre = 'DANAE' and not exists (select 1 from caravanas where propietario_id = propietarios.id);

-- expandir_rango: solo numérico 032 (las visuales se cargan por lista)
-- (sin cambios)

-- alta_masiva con bolsa; acepta visuales solo en altas manuales o de padrón inicial
drop function if exists alta_masiva(text[], int, categoria_padron, date, text, origen_alta, fuente_movimiento, text, text, int, text, text);
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
  p_bolsa         text default null
) returns jsonb language plpgsql security definer as $$
declare
  v_num text; v_est estado_caravana;
  v_bolsa text := upper(trim(coalesce(nullif(p_bolsa, ''), case when p_origen = 'wincampo' then 'FEEDLOT' else 'CLASIFICAR' end)));
  v_nuevas int := 0; v_virgenes int := 0; v_omitidas text[] := '{}';
begin
  perform _exigir_turno(p_usuario);
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
      insert into caravanas (numero, estado, propietario_id, categoria, fecha_alta, dte_alta, origen_alta, nro_tropa_alta, procedencia_alta, bolsa, compra_id, observaciones, actualizado_por)
      values (v_num, 'activa', p_propietario_id, p_categoria, p_fecha_alta, p_dte, p_origen, p_nro_tropa, p_procedencia, v_bolsa, p_compra_id, p_observaciones, p_usuario);
      v_nuevas := v_nuevas + 1;
    elsif v_est = 'virgen' then
      update caravanas set estado = 'activa', propietario_id = p_propietario_id, categoria = p_categoria,
        fecha_alta = p_fecha_alta, dte_alta = p_dte, origen_alta = p_origen, nro_tropa_alta = p_nro_tropa, procedencia_alta = p_procedencia, bolsa = v_bolsa,
        observaciones = coalesce(p_observaciones, observaciones), actualizado_por = p_usuario, actualizado_en = now()
      where numero = v_num;
      v_virgenes := v_virgenes + 1;
    else
      v_omitidas := v_omitidas || v_num;
      continue;
    end if;
    insert into movimientos (caravana, tipo, fecha, dte, propietario_id, categoria, origen_destino, nro_tropa, fuente, observaciones, usuario)
    values (v_num, 'alta', p_fecha_alta, p_dte, p_propietario_id, p_categoria, p_procedencia, p_nro_tropa, p_fuente, coalesce(p_observaciones, 'Bolsa: ' || v_bolsa), p_usuario);
  end loop;

  return jsonb_build_object('nuevas', v_nuevas, 'virgenes_usadas', v_virgenes,
                            'omitidas', to_jsonb(v_omitidas), 'total', v_nuevas + v_virgenes, 'bolsa', v_bolsa);
end $$;

-- Clasificar: asigna número de bolsa a caravanas activas o con salida
create or replace function clasificar_masiva(
  p_numeros text[], p_bolsa text, p_usuario text, p_observaciones text default null
) returns jsonb language plpgsql security definer as $$
declare v_num text; c caravanas; v_ok int := 0; v_omitidas text[] := '{}'; v_bolsa text := upper(trim(p_bolsa));
begin
  perform _exigir_turno(p_usuario);
  if coalesce(v_bolsa,'') = '' then raise exception 'Indicá el número de bolsa'; end if;
  foreach v_num in array p_numeros loop
    v_num := upper(trim(v_num));
    select * into c from caravanas where numero = v_num;
    if c.numero is null or c.estado not in ('activa','salida') then v_omitidas := v_omitidas || v_num; continue; end if;
    update caravanas set bolsa = v_bolsa, actualizado_por = p_usuario, actualizado_en = now() where numero = v_num;
    insert into movimientos (caravana, tipo, fecha, propietario_id, categoria, origen_destino, fuente, observaciones, usuario)
    values (v_num, 'clasificacion', current_date, c.propietario_id, c.categoria, 'Bolsa ' || coalesce(c.bolsa,'—') || ' → ' || v_bolsa, 'manual', p_observaciones, p_usuario);
    v_ok := v_ok + 1;
  end loop;
  return jsonb_build_object('clasificadas', v_ok, 'omitidas', to_jsonb(v_omitidas), 'bolsa', v_bolsa);
end $$;

-- Vista de consulta con fechas de 40 y 90 días desde el alta
create or replace view v_caravanas as
select c.*, p.nombre as propietario,
       c.fecha_alta + 40 as fecha_40_dias,
       c.fecha_alta + 90 as fecha_90_dias
  from caravanas c left join propietarios p on p.id = c.propietario_id;
alter view v_caravanas set (security_invoker = true);
grant select on v_caravanas to authenticated;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
