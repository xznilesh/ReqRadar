-- Step 4 full closeout: auditable, archive-safe notes for core ATS records.
alter table public.recruiter_notes add column if not exists updated_at timestamptz not null default now();
alter table public.recruiter_notes add column if not exists archived_at timestamptz;
create index if not exists idx_xzrecruiter_notes_entity on public.recruiter_notes(agency_id,entity_type,entity_id,archived_at,created_at desc);

create or replace function public.xzrecruiter_note_context(p_token text,p_entity_type text,p_entity_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text:=upper(coalesce(p_entity_type,''));v_rows jsonb;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if v_type not in ('CANDIDATE','JOB','APPLICATION','INTERVIEW','OFFER','PLACEMENT') then return jsonb_build_object('ok',false,'error','unsupported_entity'); end if;
 if not private.xzrecruiter_entity_belongs_to_agency(v_agency,v_type,p_entity_id) then return jsonb_build_object('ok',false,'error','entity_not_found'); end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
  select n.id,n.note,n.author_user_id,n.created_at,n.updated_at,u.full_name as author_name
  from public.recruiter_notes n left join public.users u on u.id=n.author_user_id
  where n.agency_id=v_agency and upper(n.entity_type)=v_type and n.entity_id=p_entity_id and n.archived_at is null
  order by n.created_at desc limit 100
 ) x;
 return jsonb_build_object('ok',true,'notes',v_rows,'current_user_id',v_user,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_save_note(p_token text,p_entity_type text,p_entity_id uuid,p_note text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text:=upper(coalesce(p_entity_type,''));v_note text:=btrim(coalesce(p_note,''));v_id uuid:=gen_random_uuid();
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if v_type not in ('CANDIDATE','JOB','APPLICATION','INTERVIEW','OFFER','PLACEMENT') then return jsonb_build_object('ok',false,'error','unsupported_entity'); end if;
 if not private.xzrecruiter_entity_belongs_to_agency(v_agency,v_type,p_entity_id) then return jsonb_build_object('ok',false,'error','entity_not_found'); end if;
 if length(v_note)<1 or length(v_note)>10000 then return jsonb_build_object('ok',false,'error','invalid_note'); end if;
 insert into public.recruiter_notes(id,agency_id,entity_type,entity_id,author_user_id,note,created_at,updated_at)
 values(v_id,v_agency,v_type,p_entity_id,v_user,v_note,now(),now());
 perform private.xzrecruiter_log_activity(v_agency,v_user,lower(v_type),p_entity_id,'note.created','Recruiter note added',jsonb_build_object('note_id',v_id));
 return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_archive_note(p_token text,p_note_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text;v_entity uuid;v_author uuid;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 select entity_type,entity_id,author_user_id into v_type,v_entity,v_author from public.recruiter_notes where id=p_note_id and agency_id=v_agency and archived_at is null;
 if v_entity is null then return jsonb_build_object('ok',false,'error','note_not_found'); end if;
 if v_author<>v_user and v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 update public.recruiter_notes set archived_at=now(),updated_at=now() where id=p_note_id and agency_id=v_agency;
 perform private.xzrecruiter_log_activity(v_agency,v_user,lower(v_type),v_entity,'note.archived','Recruiter note archived',jsonb_build_object('note_id',p_note_id));
 return jsonb_build_object('ok',true);
end;$fn$;

grant execute on function public.xzrecruiter_note_context(text,text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_save_note(text,text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_note(text,uuid) to anon,authenticated;
