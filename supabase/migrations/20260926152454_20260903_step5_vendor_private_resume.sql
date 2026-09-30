-- Step 5: private vendor resume upload with portal-token validation.
alter table public.vendor_candidate_submissions add column if not exists resume_filename text;
alter table public.vendor_candidate_submissions add column if not exists resume_mime_type text;
alter table public.vendor_candidate_submissions add column if not exists resume_size_bytes bigint;

create or replace function public.xzrecruiter_vendor_portal_prepare_resume(p_portal_token text,p_submission_id uuid,p_filename text,p_mime_type text,p_size_bytes bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_vendor uuid;v_path text;v_name text;
begin
 select agency_id,vendor_id into v_agency,v_vendor from public.vendor_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
 if v_vendor is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 if not exists(select 1 from public.vendor_candidate_submissions where id=p_submission_id and agency_id=v_agency and vendor_id=v_vendor and status<>'DUPLICATE') then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
 if coalesce(p_size_bytes,0)<=0 or p_size_bytes>8388608 then return jsonb_build_object('ok',false,'error','invalid_file_size'); end if;
 if coalesce(p_mime_type,'') not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain') then return jsonb_build_object('ok',false,'error','unsupported_file_type'); end if;
 v_name:=regexp_replace(coalesce(nullif(btrim(p_filename),''),'resume'),'[^A-Za-z0-9._-]+','-','g');
 v_path:=v_agency::text||'/vendor-submissions/'||v_vendor::text||'/'||p_submission_id::text||'/'||encode(extensions.gen_random_bytes(8),'hex')||'-'||v_name;
 return jsonb_build_object('ok',true,'storage_path',v_path,'filename',v_name,'mime_type',p_mime_type,'size_bytes',p_size_bytes);
end;$fn$;

create or replace function public.xzrecruiter_vendor_portal_finalize_resume(p_portal_token text,p_submission_id uuid,p_storage_path text,p_filename text,p_mime_type text,p_size_bytes bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_vendor uuid;v_prefix text;
begin
 select agency_id,vendor_id into v_agency,v_vendor from public.vendor_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
 if v_vendor is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 v_prefix:=v_agency::text||'/vendor-submissions/'||v_vendor::text||'/'||p_submission_id::text||'/';
 if coalesce(p_storage_path,'') not like v_prefix||'%' then return jsonb_build_object('ok',false,'error','invalid_storage_path'); end if;
 update public.vendor_candidate_submissions set resume_storage_path=p_storage_path,resume_filename=p_filename,resume_mime_type=p_mime_type,resume_size_bytes=p_size_bytes,updated_at=now() where id=p_submission_id and agency_id=v_agency and vendor_id=v_vendor and status<>'DUPLICATE';
 if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
 return jsonb_build_object('ok',true,'resume_attached',true);
end;$fn$;

grant execute on function public.xzrecruiter_vendor_portal_prepare_resume(text,uuid,text,text,bigint) to anon,authenticated;
grant execute on function public.xzrecruiter_vendor_portal_finalize_resume(text,uuid,text,text,text,bigint) to anon,authenticated;
