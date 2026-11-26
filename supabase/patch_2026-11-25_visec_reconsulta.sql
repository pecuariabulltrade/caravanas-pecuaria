-- Patch 25/11/2026: reconsulta periódica en VISEC.
-- La condición VISEC de una caravana puede cambiar de un día para otro (RENSPA que pasa a apto / no apto, etc.),
-- así que el robot, cuando no tiene nada nuevo que consultar, vuelve a consultar las caravanas activas/salida
-- cuya última consulta tiene más de 30 días, empezando por las más viejas.
--
-- Para no perder el último resultado firme cuando una reconsulta queda trabada (EN VALIDACIÓN) o da ERROR ARCA,
-- visec_consultas guarda aparte el último resultado crudo (ultimo_estado / ultima_consulta): el estado que ve el
-- portal (estado / fecha) solo se pisa con un resultado firme.

alter table visec_consultas add column if not exists ultimo_estado text;
alter table visec_consultas add column if not exists ultima_consulta timestamptz;
update visec_consultas set ultimo_estado = estado, ultima_consulta = actualizado_en where ultima_consulta is null;
create index if not exists visec_consultas_ultima_idx on visec_consultas(ultima_consulta);

-- Guardar resultados de un lote (lo llama el robot con la service key)
create or replace function visec_guardar(p_filas jsonb, p_informe text) returns int language plpgsql security definer as $$
declare n int;
begin
  insert into visec_consultas (caravana, estado, observacion, informe, fecha, actualizado_en, ultimo_estado, ultima_consulta)
  select x.caravana, upper(trim(x.estado)), x.observacion, p_informe, current_date, now(), upper(trim(x.estado)), now()
    from jsonb_to_recordset(p_filas) as x(caravana text, estado text, observacion text)
   where x.caravana ~ '^(032[0-9]{12}|[A-Z]{2}[0-9]{3}[A-Z0-9]{4})$' and coalesce(x.estado,'') <> ''
  on conflict (caravana) do update set
     ultimo_estado = excluded.ultimo_estado, ultima_consulta = now(), intentos = visec_consultas.intentos + 1,
     -- un resultado provisorio (trabada / error ARCA) no pisa un resultado firme anterior
     estado = case when excluded.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                    and visec_consultas.estado not in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                   then visec_consultas.estado else excluded.estado end,
     observacion = case when excluded.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                         and visec_consultas.estado not in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                        then visec_consultas.observacion else excluded.observacion end,
     informe = case when excluded.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                     and visec_consultas.estado not in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                    then visec_consultas.informe else excluded.informe end,
     fecha = case when excluded.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                   and visec_consultas.estado not in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                  then visec_consultas.fecha else excluded.fecha end,
     actualizado_en = case when excluded.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                            and visec_consultas.estado not in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN','ERROR ARCA')
                           then visec_consultas.actualizado_en else now() end;
  get diagnostics n = row_count;
  update visec_solicitudes s set atendido = true
   where not s.atendido and s.caravana in (select x.caravana from jsonb_to_recordset(p_filas) as x(caravana text));
  return n;
end $$;

-- Fila de consulta del robot. Orden:
--   1) pedidas desde el portal; 2) sin consultar (machos PEGSA/BULLTRADE, resto, visuales);
--   3) reintentos de trabadas (2 h después, hasta 3 veces); 4) reconsulta de las que tienen más de 30 días
--      desde la última consulta, de la más vieja a la más nueva (solo cuando no queda nada de lo anterior).
create or replace function visec_pendientes(p_max int default 100) returns setof text language sql stable security definer as $$
  with trabadas as (
    -- series (primeros 11 dígitos) con caravanas que VISEC dejó "en validación" en las últimas 3 horas:
    -- se mandan al final para no gastar lotes en lo que hoy no responde
    select left(caravana, 11) as pref, count(*) as n
      from visec_consultas
     where coalesce(ultimo_estado, estado) in ('EN VALIDACIÓN','EN ESPERA','EN PROCESO')
       and coalesce(ultima_consulta, actualizado_en) > now() - interval '3 hours'
     group by 1
  )
  select numero from (
    select distinct on (numero) numero, prio, estado, fecha_alta, reintento, ult from (
    select c.numero, 0 as prio, c.estado, c.fecha_alta, false as reintento, null::timestamptz as ult
      from caravanas c join visec_solicitudes s on s.caravana = c.numero and not s.atendido
    union
    select c.numero,
           case when c.tipo = 'visual' then 3
                when c.categoria::text in ('MACHO','TORO') and p.nombre in ('PEGSA','BULLTRADE') then 1 else 2 end,
           c.estado, c.fecha_alta, (v.caravana is not null), null
      from caravanas c
      left join propietarios p on p.id = c.propietario_id
      left join visec_consultas v on v.caravana = c.numero
     where c.estado in ('activa','salida')
       and (v.caravana is null or (v.estado in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN') and v.actualizado_en < now() - interval '2 hours' and v.intentos <= 3))
    union
    -- reconsulta periódica: resultado firme (o error ARCA) con más de 30 días desde la última consulta
    select c.numero, 4, c.estado, c.fecha_alta, true, coalesce(v.ultima_consulta, v.actualizado_en)
      from caravanas c join visec_consultas v on v.caravana = c.numero
     where c.estado in ('activa','salida')
       and v.estado not in ('EN PROCESO','EN ESPERA','EN VALIDACIÓN')
       and coalesce(v.ultima_consulta, v.actualizado_en) < now() - interval '30 days'
  ) u order by numero, prio) t
  left join trabadas tb on tb.pref = left(t.numero, 11)
  order by reintento, (prio > 0 and coalesce(tb.n, 0) > 0), prio, (estado <> 'activa'), ult asc nulls first, fecha_alta desc nulls last, numero limit p_max;
$$;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
