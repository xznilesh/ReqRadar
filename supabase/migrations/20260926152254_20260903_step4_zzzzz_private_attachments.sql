-- Step 4 full closeout: private attachments for ATS business records.

create or replace function private.xzrecruiter_entity_belongs_to_agency(p_agency uuid,p_entity_type text,p_entity_id uuid)
returns boolean language plpgsql stable security definer set search_path='public','pg_temp' as $fn$
declare v_type text:=upper(coalesce(p_entity_type,''));
begin
  if v_type='CANDIDATE' then return exists(select 1 from public.candidates where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='JOB' then return exists(select 1 from public.recruitment_jobs where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='APPLICATION' then return exists(select 1 from public.applications where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='INTERVIEW' then return exists(select 1 from public.interviews where id=p_entity_id and agency_id=p_agency);
  elsif v_type='OFFER' then return exists(select 1 from public.offers where id=p_entity_id and agency_id=p_agency);
  elsif v_type='PLACEMENT' then return exists(select 1 from public.placements where id=p_entity_id and agency_id=p_agency);
  end if;
  return false;
end;$fn$;
revoke all on function private.xzrecruiter_entity_belongs_to_agency(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_attachment_context(p_token text,p_entity_type text,p_entity_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text:=upper(coalesce(p_entity_type,''));v_rows jsonb;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_entity_belongs_to_agency(v_agency,v_type,p_entity_id) then return jsonb_build_object('ok',false,'error','entity_not_found'); end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
   select id,entity_type,entity_id,filename,mime_type,size_bytes,uploaded_by_user_id,created_at
   from public.recruitment_attachments where agency_id=v_agency and entity_type=v_type and entity_id=p_entity_id and archived_at is null order by created_at desc limit 50
 ) x;
 return jsonb_build_object('ok',true,'attachments',v_rows,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_prepare_attachment(p_token text,p_entity_type text,p_entity_id uuid,p_filename text,p_mime_type text,p_size_bytes bigint)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text:=upper(coalesce(p_entity_type,''));v_id uuid:=gen_random_uuid();v_path text;v_name text;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if not private.xzrecruiter_entity_belongs_to_agency(v_agency,v_type,p_entity_id) then return jsonb_build_object('ok',false,'error','entity_not_found'); end if;
 if coalesce(p_size_bytes,0)<=0 or p_size_bytes>8388608 then return jsonb_build_object('ok',false,'error','invalid_file_size'); end if;
 if coalesce(p_mime_type,'') not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain','image/png','image/jpeg') then return jsonb_build_object('ok',false,'error','unsupported_file_type'); end if;
 v_name:=regexp_replace(coalesce(nullif(btrim(p_filename),''),'attachment'),'[^A-Za-z0-9._-]+','-','g');
 v_path:=v_agency::text||'/attachments/'||lower(v_type)||'/'||p_entity_id::text||'/'||v_id::text||'-'||v_name;
 insert into public.recruitment_attachments(id,agency_id,entity_type,entity_id,filename,storage_path,mime_type,size_bytes,uploaded_by_user_id)
 values(v_id,v_agency,v_type,p_entity_id,v_name,v_path,p_mime_type,p_size_bytes,v_user);
 perform private.xzrecruiter_log_activity(v_agency,v_user,lower(v_type),p_entity_id,'attachment.created','Private attachment uploaded',jsonb_build_object('attachment_id',v_id,'filename',v_name));
 return jsonb_build_object('ok',true,'attachment_id',v_id,'storage_path',v_path);
end;$fn$;

create or replace function public.xzrecruiter_attachment_access(p_token text,p_attachment_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_path text;v_name text;v_mime text;v_type text;v_entity uuid;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 select storage_path,filename,mime_type,entity_type,entity_id into v_path,v_name,v_mime,v_type,v_entity from public.recruitment_attachments where id=p_attachment_id and agency_id=v_agency and archived_at is null;
 if v_path is null then return jsonb_build_object('ok',false,'error','attachment_not_found'); end if;
 if not private.xzrecruiter_entity_belongs_to_agency(v_agency,v_type,v_entity) then return jsonb_build_object('ok',false,'error','entity_not_found'); end if;
 return jsonb_build_object('ok',true,'storage_path',v_path,'filename',v_name,'mime_type',v_mime);
end;$fn$;

create or replace function public.xzrecruiter_archive_attachment(p_token text,p_attachment_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text;v_entity uuid;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 select entity_type,entity_id into v_type,v_entity from public.recruitment_attachments where id=p_attachment_id and agency_id=v_agency and archived_at is null;
 if v_entity is null then return jsonb_build_object('ok',false,'error','attachment_not_found'); end if;
 update public.recruitment_attachments set archived_at=now() where id=p_attachment_id and agency_id=v_agency;
 perform private.xzrecruiter_log_activity(v_agency,v_user,lower(v_type),v_entity,'attachment.archived','Private attachment archived',jsonb_build_object('attachment_id',p_attachment_id));
 return jsonb_build_object('ok',true);
end;$fn$;

grant execute on function public.xzrecruiter_attachment_context(text,text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_prepare_attachment(text,text,uuid,text,text,bigint) to anon,authenticated;
grant execute on function public.xzrecruiter_attachment_access(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_attachment(text,uuid) to anon,authenticated;
