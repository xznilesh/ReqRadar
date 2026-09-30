create or replace function public.xzrecruiter_signup(
  p_email text, p_password text, p_name text, p_agency text
) returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions','pg_temp'
as $$
declare
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_name text := btrim(coalesce(p_name,''));
  v_agency_name text := btrim(coalesce(p_agency,''));
  v_user_id uuid := gen_random_uuid();
  v_agency_id uuid := gen_random_uuid();
  v_password_hash text;
  v_rate jsonb;
  v_key text;
begin
  if v_name='' or v_agency_name='' or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('ok',false,'error','invalid_profile');
  end if;
  if length(coalesce(p_password,''))<12 then
    return jsonb_build_object('ok',false,'error','weak_password');
  end if;

  v_key := encode(extensions.digest(v_email,'sha256'),'hex');
  v_rate := public.xzrecruiter_consume_rate_limit('auth:signup:email',v_key,5,3600);
  if not coalesce((v_rate->>'allowed')::boolean,false) then
    return jsonb_build_object('ok',false,'error','rate_limited');
  end if;

  if exists(select 1 from public.users where lower(email)=v_email) then
    return jsonb_build_object('ok',false,'error','account_exists');
  end if;

  v_password_hash := extensions.crypt(p_password,extensions.gen_salt('bf',12));
  insert into public.users(id,email,display_name,email_verified_at)
    values(v_user_id,v_email,v_name,null);
  insert into public.user_credentials(user_id,password_hash,password_salt)
    values(v_user_id,v_password_hash,'bcrypt-v1');
  insert into public.agencies(id,name,country,timezone,onboarding_status)
    values(v_agency_id,v_agency_name,'IN','Asia/Kolkata','IN_PROGRESS');
  insert into public.agency_memberships(agency_id,user_id,role)
    values(v_agency_id,v_user_id,'OWNER');
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
    values(gen_random_uuid(),v_agency_id,v_user_id,'workspace.created','user',v_user_id,
      jsonb_build_object('email',v_email,'role','OWNER','email_verified',false));
  return jsonb_build_object(
    'ok',true,'requires_email_verification',true,
    'user',jsonb_build_object('id',v_user_id,'email',v_email,'display_name',v_name),
    'agency',jsonb_build_object('id',v_agency_id,'name',v_agency_name,'role','OWNER')
  );
exception
  when unique_violation then return jsonb_build_object('ok',false,'error','account_exists');
  when others then
    raise warning 'xzrecruiter_signup failed: %',sqlerrm;
    return jsonb_build_object('ok',false,'error','signup_failed');
end;
$$;
revoke all on function public.xzrecruiter_signup(text,text,text,text) from public;
grant execute on function public.xzrecruiter_signup(text,text,text,text) to anon;

