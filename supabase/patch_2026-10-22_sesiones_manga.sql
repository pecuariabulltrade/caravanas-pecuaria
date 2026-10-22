-- Patch 22/10/2026: app Lector de Manga (tablet + balanza XR5000)
--  1. Usuario "Operarios de manga": solo lee el padrón y sube sesiones. No puede modificar nada.
--  2. Tablas sesiones_manga y sesiones_manga_lecturas + función recibir_sesion_manga (idempotente).
--  3. Vista v_sesiones_manga para la pestaña Sesiones del portal.
--
-- DESPUÉS de correr este patch:
--  a) Authentication > Users > "Add user": crear el usuario (p.ej. manga@pecuariabulltrade.com) con contraseña,
--     con "Auto confirm user" marcado.
--  b) Correr:  insert into operarios_manga (email) values ('manga@pecuariabulltrade.com');
--     (ese email y contraseña son los que se cargan una sola vez en la tablet)

-- ------------------------------------------------------------
-- 1. Operarios de manga (usuarios con permisos limitados)
-- ------------------------------------------------------------
create table if not exists operarios_manga (
  email      text primary key,
  creado_en  timestamptz not null default now()
);
alter table operarios_manga enable row level security;

create or replace function es_operario_manga() returns boolean
language sql stable security definer as $$
  select exists (select 1 from operarios_manga where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;
revoke all on function es_operario_manga() from public;
grant execute on function es_operario_manga() to authenticated;

-- Las políticas "auth_all" (usuarios autenticados hacen todo) pasan a excluir al operario de manga.
do $$
declare t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists auth_all on %I', t);
    execute format('drop policy if exists manga_select on %I', t);
    execute format('create policy auth_all on %I for all to authenticated using (not es_operario_manga()) with check (not es_operario_manga())', t);
  end loop;
end $$;

-- Lo único que el operario de manga puede leer: propietarios y padrón (v_caravanas usa security_invoker)
create policy manga_select on propietarios for select to authenticated using (es_operario_manga());
create policy manga_select on caravanas    for select to authenticated using (es_operario_manga());

-- Ninguna operación de carga para el operario de manga (todas pasan por el turno)
create or replace function tomar_turno(p_usuario text, p_liberar boolean default false)
returns bloqueo_edicion language plpgsql security definer as $$
declare b bloqueo_edicion;
begin
  if es_operario_manga() then raise exception 'El usuario de manga no puede tomar el turno de carga'; end if;
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

create or replace function _exigir_turno(p_usuario text) returns void language plpgsql as $$
declare b bloqueo_edicion;
begin
  if es_operario_manga() then raise exception 'El usuario de manga no puede hacer cargas'; end if;
  select * into b from bloqueo_edicion where id = 1;
  if b.usuario is distinct from p_usuario or b.ultima_actividad < now() - interval '15 minutes' then
    raise exception 'No tenés el turno de carga (lo tiene %)', coalesce(b.usuario, 'nadie');
  end if;
  update bloqueo_edicion set ultima_actividad = now() where id = 1;
end $$;

-- ------------------------------------------------------------
-- 2. Sesiones de manga
-- ------------------------------------------------------------
create table if not exists sesiones_manga (
  id              uuid primary key,                 -- lo genera la tablet (reenvíos idempotentes)
  inicio          timestamptz not null,
  fin             timestamptz,
  destino         text not null check (destino in ('EXPORTACION','CONSUMO')),
  categoria       text not null check (categoria in ('HEMBRA','VACA','MACHO')),
  propietario_id  int references propietarios(id),
  propietario     text not null,
  usuario         text,                             -- email del usuario de la tablet
  tablet          text,                             -- nombre/modelo de la tablet
  padron_al       timestamptz,                      -- fecha de la copia del padrón usada
  version_app     text,
  total           int not null default 0,
  verdes          int not null default 0,
  amarillas       int not null default 0,
  rojas           int not null default 0,
  borradas        int not null default 0,
  recibido_en     timestamptz not null default now()
);
create index if not exists sesiones_manga_inicio_idx on sesiones_manga(inicio desc);

create table if not exists sesiones_manga_lecturas (
  id          bigserial primary key,
  sesion_id   uuid not null references sesiones_manga(id) on delete cascade,
  orden       int not null,
  caravana    text not null,
  hora        timestamptz not null,
  color       text not null check (color in ('verde','amarillo','rojo')),
  motivos     text[] not null default '{}',
  fuente      text not null check (fuente in ('baston','manual')),
  propietario text,
  categoria   text,
  estado      text,
  dias        int,
  borrada     boolean not null default false,
  borrada_en  timestamptz,
  unique (sesion_id, orden)
);
create index if not exists sesiones_manga_lecturas_sesion_idx on sesiones_manga_lecturas(sesion_id);
create index if not exists sesiones_manga_lecturas_caravana_idx on sesiones_manga_lecturas(caravana);

alter table sesiones_manga          enable row level security;
alter table sesiones_manga_lecturas enable row level security;
drop policy if exists auth_all on sesiones_manga;
drop policy if exists auth_all on sesiones_manga_lecturas;
create policy auth_all on sesiones_manga          for all to authenticated using (not es_operario_manga()) with check (not es_operario_manga());
create policy auth_all on sesiones_manga_lecturas for all to authenticated using (not es_operario_manga()) with check (not es_operario_manga());
grant all on sesiones_manga, sesiones_manga_lecturas to authenticated;
grant usage, select on sequence sesiones_manga_lecturas_id_seq to authenticated;

-- La tablet sube la sesión completa con esta función (puede reenviar: reemplaza lo anterior)
create or replace function recibir_sesion_manga(p_sesion jsonb, p_lecturas jsonb)
returns jsonb language plpgsql security definer as $$
declare v_id uuid := (p_sesion ->> 'id')::uuid; n int;
begin
  if v_id is null then raise exception 'La sesión no tiene id'; end if;
  delete from sesiones_manga_lecturas where sesion_id = v_id;
  delete from sesiones_manga where id = v_id;
  insert into sesiones_manga (id, inicio, fin, destino, categoria, propietario_id, propietario, usuario, tablet, padron_al, version_app,
                              total, verdes, amarillas, rojas, borradas)
  values (v_id,
          (p_sesion ->> 'inicio')::timestamptz,
          (p_sesion ->> 'fin')::timestamptz,
          upper(p_sesion ->> 'destino'),
          upper(p_sesion ->> 'categoria'),
          (p_sesion ->> 'propietario_id')::int,
          upper(p_sesion ->> 'propietario'),
          coalesce(p_sesion ->> 'usuario', auth.jwt() ->> 'email'),
          p_sesion ->> 'tablet',
          (p_sesion ->> 'padron_al')::timestamptz,
          p_sesion ->> 'version_app',
          coalesce((p_sesion ->> 'total')::int, 0),
          coalesce((p_sesion ->> 'verdes')::int, 0),
          coalesce((p_sesion ->> 'amarillas')::int, 0),
          coalesce((p_sesion ->> 'rojas')::int, 0),
          coalesce((p_sesion ->> 'borradas')::int, 0));
  insert into sesiones_manga_lecturas (sesion_id, orden, caravana, hora, color, motivos, fuente, propietario, categoria, estado, dias, borrada, borrada_en)
  select v_id, x.orden, upper(x.caravana), x.hora, x.color,
         coalesce(array(select jsonb_array_elements_text(x.motivos)), '{}'),
         x.fuente, x.propietario, x.categoria, x.estado, x.dias, coalesce(x.borrada, false), x.borrada_en
    from jsonb_to_recordset(p_lecturas) as x(orden int, caravana text, hora timestamptz, color text, motivos jsonb, fuente text,
                                             propietario text, categoria text, estado text, dias int, borrada boolean, borrada_en timestamptz);
  get diagnostics n = row_count;
  return jsonb_build_object('id', v_id, 'lecturas', n);
end $$;
revoke all on function recibir_sesion_manga(jsonb, jsonb) from public;
grant execute on function recibir_sesion_manga(jsonb, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 3. Vista para la pestaña Sesiones
-- ------------------------------------------------------------
create or replace view v_sesiones_manga as
select s.*,
       (select count(*) from sesiones_manga_lecturas l where l.sesion_id = s.id and not l.borrada) as lecturas,
       (select count(*) from sesiones_manga_lecturas l where l.sesion_id = s.id and l.fuente = 'manual' and not l.borrada) as manuales
  from sesiones_manga s;
alter view v_sesiones_manga set (security_invoker = true);
grant select on v_sesiones_manga to authenticated;

revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
