-- EL PADRINO STUDIO: migración inicial para cuentas de cliente.
-- Ejecutar una sola vez en Supabase > SQL Editor.
-- No habilita acceso directo a appointments: las operaciones pasan por RPC.

alter table public.appointments
  add column if not exists user_id uuid references auth.users(id) on delete set null,
  add column if not exists linked_at timestamptz;

create index if not exists appointments_user_id_start_at_idx
  on public.appointments(user_id, start_at desc)
  where user_id is not null;

create or replace function public.claim_guest_booking(
  p_booking_code text,
  p_customer_phone text
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_appointment_id uuid;
begin
  if v_user_id is null then
    return jsonb_build_object('success',false,'message','Inicia sesión para vincular tu reserva.');
  end if;
  if coalesce(length(trim(p_booking_code)),0) < 8
     or coalesce(length(regexp_replace(p_customer_phone,'[^0-9]','','g')),0) < 7 then
    return jsonb_build_object('success',false,'message','Revisa el código y el teléfono.');
  end if;

  select a.id into v_appointment_id
  from public.appointments a
  where upper(a.booking_code)=upper(trim(p_booking_code))
    and regexp_replace(a.customer_phone,'[^0-9]','','g') =
        regexp_replace(p_customer_phone,'[^0-9]','','g')
    and a.user_id is null
  limit 1
  for update;

  if v_appointment_id is null then
    return jsonb_build_object('success',false,'message','No encontramos una reserva libre con ese código y teléfono. Verifica los datos.');
  end if;

  update public.appointments
  set user_id=v_user_id, linked_at=now(), updated_at=now()
  where id=v_appointment_id;

  return jsonb_build_object('success',true,'message','Reserva vinculada.');
end;
$$;

create or replace function public.get_my_bookings()
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(jsonb_agg(
    to_jsonb(a) || jsonb_build_object('barber_name',b.name)
    order by a.start_at desc
  ),'[]'::jsonb)
  from public.appointments a
  left join public.barbers b on b.id=a.barber_id
  where a.user_id=auth.uid();
$$;

create or replace function public.cancel_my_booking(p_appointment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_start timestamptz;
  v_status text;
begin
  if auth.uid() is null then
    return jsonb_build_object('success',false,'message','Inicia sesión.');
  end if;

  select start_at,status into v_start,v_status
  from public.appointments
  where id=p_appointment_id and user_id=auth.uid()
  for update;

  if v_start is null then
    return jsonb_build_object('success',false,'message','No encontramos esa reserva en tu cuenta.');
  end if;
  if lower(v_status) not in ('confirmed','pending') then
    return jsonb_build_object('success',false,'message','Esta reserva ya no se puede cancelar.');
  end if;
  if v_start <= now() + interval '2 hours' then
    return jsonb_build_object('success',false,'message','Solo puedes cancelar con al menos 2 horas de anticipación.');
  end if;

  update public.appointments
  set status='cancelled',updated_at=now()
  where id=p_appointment_id and user_id=auth.uid();

  return jsonb_build_object('success',true,'message','Reserva cancelada.');
end;
$$;

revoke all on function public.claim_guest_booking(text,text) from public;
revoke all on function public.get_my_bookings() from public;
revoke all on function public.cancel_my_booking(uuid) from public;
grant execute on function public.claim_guest_booking(text,text) to authenticated;
grant execute on function public.get_my_bookings() to authenticated;
grant execute on function public.cancel_my_booking(uuid) to authenticated;
