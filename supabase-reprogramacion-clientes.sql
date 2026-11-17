-- EL PADRINO STUDIO: reprogramación de citas desde la cuenta del cliente.
-- Ejecutar UNA VEZ en Supabase > SQL Editor. No reemplaza las funciones existentes.

create or replace function public.get_my_reschedule_slots(
  p_appointment_id uuid,
  p_date date
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_barber_id uuid;
  v_duration integer;
  v_current_start timestamptz;
  v_status text;
  v_slots jsonb := '[]'::jsonb;
  v_slot timestamp;
  v_start timestamptz;
  v_end timestamptz;
  v_occupied_until timestamptz;
begin
  if auth.uid() is null then
    return jsonb_build_object('success',false,'message','Inicia sesión.');
  end if;

  select a.barber_id, a.total_minutes, a.start_at, a.status
    into v_barber_id, v_duration, v_current_start, v_status
  from public.appointments a
  where a.id = p_appointment_id and a.user_id = auth.uid();

  if not found then
    return jsonb_build_object('success',false,'message','No encontramos esa reserva en tu cuenta.');
  end if;
  if lower(v_status) not in ('pending','confirmed') then
    return jsonb_build_object('success',false,'message','Esta reserva ya no se puede reprogramar.');
  end if;
  if v_current_start <= now() + interval '2 hours' then
    return jsonb_build_object('success',false,'message','Solo puedes reprogramar con al menos 2 horas de anticipación.');
  end if;
  if p_date is null
     or p_date < (now() at time zone 'America/Bogota')::date
     or p_date > ((now() + interval '30 days') at time zone 'America/Bogota')::date then
    return jsonb_build_object('success',false,'message','Fecha fuera del período permitido.');
  end if;

  for v_slot in
    select generate_series(p_date + time '06:00', p_date + time '21:30', interval '30 minutes')
  loop
    v_start := v_slot at time zone 'America/Bogota';
    v_end := v_start + make_interval(mins => v_duration);
    v_occupied_until := v_end + interval '30 minutes';

    if v_start < now() + interval '2 hours'
       or v_start > now() + interval '30 days' then
      continue;
    end if;

    if (v_end at time zone 'America/Bogota')::date <> p_date
       or (v_end at time zone 'America/Bogota')::time > time '22:00' then
      continue;
    end if;

    if v_slot::time < time '13:00'
       and (v_end at time zone 'America/Bogota')::time > time '12:00' then
      continue;
    end if;

    if exists (
      select 1 from public.blocked_periods b
      where b.barber_id = v_barber_id
        and tstzrange(v_start, v_occupied_until, '[)')
            && tstzrange(b.start_at, b.end_at, '[)')
    ) then
      continue;
    end if;

    if exists (
      select 1 from public.appointments a
      where a.barber_id = v_barber_id
        and a.id <> p_appointment_id
        and a.status in ('pending','confirmed')
        and tstzrange(v_start, v_occupied_until, '[)')
            && tstzrange(a.start_at, a.occupied_until, '[)')
    ) then
      continue;
    end if;

    v_slots := v_slots || jsonb_build_array(jsonb_build_object(
      'start_at',v_start,
      'end_at',v_end,
      'time',to_char(v_slot,'HH24:MI')
    ));
  end loop;

  return jsonb_build_object(
    'success',true,
    'date',p_date,
    'duration_minutes',v_duration,
    'slots',v_slots
  );
end;
$$;

create or replace function public.reschedule_my_booking(
  p_appointment_id uuid,
  p_new_start_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_barber_id uuid;
  v_duration integer;
  v_current_start timestamptz;
  v_status text;
  v_new_end timestamptz;
  v_new_occupied_until timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
begin
  if auth.uid() is null then
    return jsonb_build_object('success',false,'message','Inicia sesión.');
  end if;
  if p_new_start_at is null then
    return jsonb_build_object('success',false,'message','Selecciona una nueva fecha y hora.');
  end if;

  select a.barber_id,a.total_minutes,a.start_at,a.status
    into v_barber_id,v_duration,v_current_start,v_status
  from public.appointments a
  where a.id=p_appointment_id and a.user_id=auth.uid()
  for update;

  if not found then
    return jsonb_build_object('success',false,'message','No encontramos esa reserva en tu cuenta.');
  end if;
  if lower(v_status) not in ('pending','confirmed') then
    return jsonb_build_object('success',false,'message','Esta reserva ya no se puede reprogramar.');
  end if;
  if v_current_start <= now() + interval '2 hours' then
    return jsonb_build_object('success',false,'message','Solo puedes reprogramar con al menos 2 horas de anticipación.');
  end if;
  if p_new_start_at <= now() + interval '2 hours' then
    return jsonb_build_object('success',false,'message','La nueva cita debe tener al menos 2 horas de anticipación.');
  end if;
  if p_new_start_at > now() + interval '30 days' then
    return jsonb_build_object('success',false,'message','Solo puedes reprogramar dentro de los próximos 30 días.');
  end if;

  v_new_end := p_new_start_at + make_interval(mins => v_duration);
  v_new_occupied_until := v_new_end + interval '30 minutes';
  v_local_start := p_new_start_at at time zone 'America/Bogota';
  v_local_end := v_new_end at time zone 'America/Bogota';

  if extract(minute from v_local_start)::integer % 30 <> 0
     or extract(second from v_local_start) <> 0 then
    return jsonb_build_object('success',false,'message','Las citas deben comenzar cada 30 minutos.');
  end if;
  if v_local_start::date <> v_local_end::date
     or v_local_start::time < time '06:00'
     or v_local_end::time > time '22:00' then
    return jsonb_build_object('success',false,'message','La cita está fuera del horario de atención.');
  end if;
  if v_local_start::time < time '13:00'
     and v_local_end::time > time '12:00' then
    return jsonb_build_object('success',false,'message','El establecimiento cierra de 12:00 a 13:00.');
  end if;

  if exists (
    select 1 from public.blocked_periods b
    where b.barber_id=v_barber_id
      and tstzrange(p_new_start_at,v_new_occupied_until,'[)')
          && tstzrange(b.start_at,b.end_at,'[)')
  ) then
    return jsonb_build_object('success',false,'message','Ese horario está bloqueado.');
  end if;

  if exists (
    select 1 from public.appointments a
    where a.barber_id=v_barber_id
      and a.id<>p_appointment_id
      and a.status in ('pending','confirmed')
      and tstzrange(p_new_start_at,v_new_occupied_until,'[)')
          && tstzrange(a.start_at,a.occupied_until,'[)')
  ) then
    return jsonb_build_object('success',false,'message','Ese horario ya está ocupado. Selecciona otro.');
  end if;

  update public.appointments
  set start_at=p_new_start_at,
      end_at=v_new_end,
      occupied_until=v_new_occupied_until,
      updated_at=now()
  where id=p_appointment_id and user_id=auth.uid();

  return jsonb_build_object(
    'success',true,
    'message','Cita reprogramada correctamente.',
    'start_at',p_new_start_at,
    'end_at',v_new_end
  );
exception
  when exclusion_violation then
    return jsonb_build_object('success',false,'message','Ese horario acaba de ocuparse. Selecciona otro.');
end;
$$;

revoke all on function public.get_my_reschedule_slots(uuid,date) from public;
revoke all on function public.reschedule_my_booking(uuid,timestamptz) from public;
grant execute on function public.get_my_reschedule_slots(uuid,date) to authenticated;
grant execute on function public.reschedule_my_booking(uuid,timestamptz) to authenticated;
