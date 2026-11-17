-- EL PADRINO STUDIO: panel administrativo seguro
-- Ejecutar una sola vez en Supabase > SQL Editor.
-- Los datos administrativos se exponen únicamente mediante RPC que verifican admin_profiles.

create or replace function public.is_admin_user()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid()
  );
$$;

revoke all on function public.is_admin_user() from public;
grant execute on function public.is_admin_user() to authenticated;

create or replace function public.admin_get_dashboard(
  p_from timestamptz,
  p_to timestamptz,
  p_barber_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_appointments jsonb;
  v_barbers jsonb;
  v_blocks jsonb;
begin
  if auth.uid() is null or not public.is_admin_user() then
    raise exception 'No autorizado.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '45 days' then
    raise exception 'Rango de fechas no válido (máximo 45 días).';
  end if;

  select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('barber_name', b.name)
           order by a.start_at), '[]'::jsonb)
    into v_appointments
  from public.appointments a
  left join public.barbers b on b.id = a.barber_id
  where a.start_at < p_to and a.occupied_until > p_from
    and (p_barber_id is null or a.barber_id = p_barber_id);

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]'::jsonb)
    into v_barbers
  from public.barbers where active = true;

  select coalesce(jsonb_agg(to_jsonb(bp) || jsonb_build_object('barber_name', b.name)
           order by bp.start_at), '[]'::jsonb)
    into v_blocks
  from public.blocked_periods bp
  join public.barbers b on b.id = bp.barber_id
  where bp.start_at < p_to and bp.end_at > p_from
    and (p_barber_id is null or bp.barber_id = p_barber_id);

  return jsonb_build_object('appointments',v_appointments,'barbers',v_barbers,'blocks',v_blocks);
end;
$$;

create or replace function public.admin_set_appointment_status(
  p_appointment_id uuid,
  p_status text
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_status text := lower(trim(p_status));
begin
  if auth.uid() is null or not public.is_admin_user() then
    raise exception 'No autorizado.' using errcode = '42501';
  end if;
  if v_status not in ('pending','confirmed','cancelled') then
    raise exception 'Estado no permitido.';
  end if;
  update public.appointments
     set status = v_status, updated_at = now()
   where id = p_appointment_id;
  if not found then return jsonb_build_object('success',false,'message','No se encontró la cita.'); end if;
  return jsonb_build_object('success',true,'message','Estado actualizado.');
end;
$$;

create or replace function public.admin_create_block(
  p_barber_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not public.is_admin_user() then
    raise exception 'No autorizado.' using errcode = '42501';
  end if;
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at or p_start_at <= now() then
    raise exception 'El periodo debe ser futuro y tener una hora final posterior a la inicial.';
  end if;
  if not exists (select 1 from public.barbers where id=p_barber_id and active=true) then
    raise exception 'Barbero no válido.';
  end if;
  if exists (
    select 1 from public.appointments a
    where a.barber_id=p_barber_id and a.status in ('pending','confirmed')
      and a.start_at < p_end_at and a.occupied_until > p_start_at
  ) then
    raise exception 'El bloqueo se cruza con una cita activa. Revisa la agenda.';
  end if;
  insert into public.blocked_periods(barber_id,start_at,end_at,reason)
  values(p_barber_id,p_start_at,p_end_at,nullif(trim(p_reason),''))
  returning id into v_id;
  return jsonb_build_object('success',true,'id',v_id,'message','Horario bloqueado.');
end;
$$;

create or replace function public.admin_delete_block(p_block_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null or not public.is_admin_user() then
    raise exception 'No autorizado.' using errcode = '42501';
  end if;
  delete from public.blocked_periods where id=p_block_id;
  if not found then return jsonb_build_object('success',false,'message','No se encontró el bloqueo.'); end if;
  return jsonb_build_object('success',true,'message','Bloqueo eliminado.');
end;
$$;

revoke all on function public.admin_get_dashboard(timestamptz,timestamptz,uuid) from public;
revoke all on function public.admin_set_appointment_status(uuid,text) from public;
revoke all on function public.admin_create_block(uuid,timestamptz,timestamptz,text) from public;
revoke all on function public.admin_delete_block(uuid) from public;
grant execute on function public.admin_get_dashboard(timestamptz,timestamptz,uuid) to authenticated;
grant execute on function public.admin_set_appointment_status(uuid,text) to authenticated;
grant execute on function public.admin_create_block(uuid,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.admin_delete_block(uuid) to authenticated;
