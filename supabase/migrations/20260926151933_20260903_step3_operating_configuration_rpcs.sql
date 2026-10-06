-- XZ Recruiter Step 3: operating configuration RPCs for offices, layouts and candidate inventory authorization.

create or replace function private.xzrecruiter_default_primary_office()
returns trigger
language plpgsql
security definer
set search_path='public','pg_temp'
as $function$
declare
  v_settings record;
  v_office uuid;
begin
  if new.primary_office_id is not null then return new; end if;
  select country_code,timezone_id,locale,currency_code into v_settings
  from public.workspace_global_settings where agency_id=new.agency_id;
  if v_settings.country_code is null then return new; end if;
  select id into v_office from public.recruitment_offices
  where agency_id=new.agency_id and active=true
  order by created_at asc limit 1;
  if v_office is null then
    insert into public.recruitment_offices(agency_id,name,country_code,timezone_id,locale,currency_code)
    values(new.agency_id,'Primary office',v_settings.country_code,v_settings.timezone_id,v_settings.locale,v_settings.currency_code)
    returning id into v_office;
  end if;
  new.primary_office_id:=v_office;
  return new;
end;
$function$;
revoke all on function private.xzrecruiter_default_primary_office() from public,anon,authenticated;

drop trigger if exists trg_xzrecruiter_default_primary_office on public.agency_operating_profiles;
create trigger trg_xzrecruiter_default_primary_office
before insert or update of primary_office_id on public.agency_operating_profiles
for each row execute function private.xzrecruiter_default_primary_office();

create or replace function public.xzrecruiter_office_context(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_primary uuid;v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select primary_office_id into v_primary from public.agency_operating_profiles where agency_id=v_agency_id;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.is_primary desc,x.name),'[]'::jsonb) into v_rows from (
    select o.id,o.name,o.country_code,o.timezone_id,o.locale,o.currency_code,o.active,o.created_at,o.updated_at,(o.id=v_primary) as is_primary
    from public.recruitment_offices o where o.agency_id=v_agency_id and o.active=true
  ) x;
  return jsonb_build_object('ok',true,'role',v_role,'offices',v_rows);
end;
$function$;

create or replace function public.xzrecruiter_save_office(p_token text,p_office jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_id uuid;v_country text;v_timezone text;v_currency text;v_locale text;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_country:=upper(btrim(coalesce(p_office->>'countryCode','')));v_timezone:=btrim(coalesce(p_office->>'timezoneId',''));v_currency:=upper(btrim(coalesce(p_office->>'currencyCode','')));v_locale:=btrim(coalesce(p_office->>'locale',''));
  if nullif(btrim(p_office->>'name'),'') is null then return jsonb_build_object('ok',false,'error','name_required'); end if;
  if not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  if v_currency<>'' and v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency'); end if;
  if v_locale<>'' and v_locale !~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$' then return jsonb_build_object('ok',false,'error','invalid_locale'); end if;
  begin v_id:=nullif(p_office->>'id','')::uuid; exception when others then v_id:=null; end;
  if v_id is null then
    insert into public.recruitment_offices(agency_id,name,country_code,timezone_id,locale,currency_code)
    values(v_agency_id,btrim(p_office->>'name'),v_country,v_timezone,nullif(v_locale,''),nullif(v_currency,'')) returning id into v_id;
  else
    update public.recruitment_offices set name=btrim(p_office->>'name'),country_code=v_country,timezone_id=v_timezone,locale=nullif(v_locale,''),currency_code=nullif(v_currency,''),active=true,updated_at=now()
    where id=v_id and agency_id=v_agency_id;
    if not found then return jsonb_build_object('ok',false,'error','office_not_found'); end if;
  end if;
  if coalesce((p_office->>'isPrimary')::boolean,false) then
    insert into public.agency_operating_profiles(agency_id,primary_office_id) values(v_agency_id,v_id)
    on conflict(agency_id) do update set primary_office_id=excluded.primary_office_id,updated_at=now();
  end if;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(gen_random_uuid(),v_agency_id,v_user_id,'config.office_saved','office',v_id,jsonb_build_object('country_code',v_country,'timezone_id',v_timezone,'primary',coalesce((p_office->>'isPrimary')::boolean,false)));
  return jsonb_build_object('ok',true,'id',v_id);
end;
$function$;

create or replace function public.xzrecruiter_save_candidate_authorization_profile(p_token text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_country text;v_code text;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  delete from public.agency_specialization_items where agency_id=v_agency_id and context='CANDIDATE' and item_type='WORK_AUTHORIZATION';
  for v_country in select upper(value #>> '{}') from jsonb_array_elements(coalesce(p_payload->'countries','[]'::jsonb)) loop
    if exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then
      insert into public.agency_specialization_items(agency_id,context,item_type,country_code,metadata)
      values(v_agency_id,'CANDIDATE','WORK_AUTHORIZATION',v_country,jsonb_build_object('statuses',coalesce(p_payload->'statuses','[]'::jsonb)));
    end if;
  end loop;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(gen_random_uuid(),v_agency_id,v_user_id,'config.candidate_work_authorization_saved','agency',v_agency_id,jsonb_build_object('countries',coalesce(p_payload->'countries','[]'::jsonb),'statuses',coalesce(p_payload->'statuses','[]'::jsonb)));
  return jsonb_build_object('ok',true);
end;
$function$;

create or replace function public.xzrecruiter_save_layout(p_token text,p_layout jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_layout uuid;v_section jsonb;v_section_id uuid;v_field jsonb;v_module text:=upper(coalesce(p_layout->>'module',''));
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_module not in ('CANDIDATE','JOB','COMPANY','CLIENT','CONTACT','OPPORTUNITY') or nullif(btrim(p_layout->>'name'),'') is null then return jsonb_build_object('ok',false,'error','invalid_layout'); end if;
  begin v_layout:=nullif(p_layout->>'id','')::uuid; exception when others then v_layout:=null; end;
  if v_layout is null then
    insert into public.custom_layouts(agency_id,module,name,is_default) values(v_agency_id,v_module,btrim(p_layout->>'name'),coalesce((p_layout->>'isDefault')::boolean,false)) returning id into v_layout;
  else
    update public.custom_layouts set name=btrim(p_layout->>'name'),is_default=coalesce((p_layout->>'isDefault')::boolean,false),updated_at=now() where id=v_layout and agency_id=v_agency_id;
    if not found then return jsonb_build_object('ok',false,'error','layout_not_found'); end if;
    delete from public.custom_layout_sections where layout_id=v_layout and agency_id=v_agency_id;
  end if;
  for v_section in select value from jsonb_array_elements(coalesce(p_layout->'sections','[]'::jsonb)) loop
    insert into public.custom_layout_sections(agency_id,layout_id,name,sort_order,columns,collapsed_by_default,visible)
    values(v_agency_id,v_layout,coalesce(nullif(btrim(v_section->>'name'),''),'Details'),coalesce(nullif(v_section->>'sortOrder','')::integer,100),least(4,greatest(1,coalesce(nullif(v_section->>'columns','')::smallint,2))),coalesce((v_section->>'collapsed')::boolean,false),coalesce((v_section->>'visible')::boolean,true))
    returning id into v_section_id;
    for v_field in select value from jsonb_array_elements(coalesce(v_section->'fields','[]'::jsonb)) loop
      if exists(select 1 from public.custom_field_definitions f where f.id=nullif(v_field->>'fieldId','')::uuid and f.agency_id=v_agency_id and f.module=v_module) then
        insert into public.custom_layout_fields(agency_id,section_id,field_id,sort_order,width)
        values(v_agency_id,v_section_id,(v_field->>'fieldId')::uuid,coalesce(nullif(v_field->>'sortOrder','')::integer,100),case when upper(coalesce(v_field->>'width','FULL')) in ('HALF','THIRD','QUARTER') then upper(v_field->>'width') else 'FULL' end);
      end if;
    end loop;
  end loop;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'config.layout_saved','layout',v_layout,jsonb_build_object('module',v_module,'name',p_layout->>'name'));
  return jsonb_build_object('ok',true,'id',v_layout);
end;
$function$;

revoke all on function public.xzrecruiter_office_context(text) from public,authenticated;
grant execute on function public.xzrecruiter_office_context(text) to anon;
revoke all on function public.xzrecruiter_save_office(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_office(text,jsonb) to anon;
revoke all on function public.xzrecruiter_save_candidate_authorization_profile(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_candidate_authorization_profile(text,jsonb) to anon;
revoke all on function public.xzrecruiter_save_layout(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_layout(text,jsonb) to anon;
