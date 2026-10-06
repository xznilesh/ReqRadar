-- Step 4 Candidate 360 closeout: surface merged-document history and recruitment activity.

create or replace function public.xzrecruiter_candidate_closeout_context(p_token text,p_candidate_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_email text;v_phone text;v_name text;
  v_docs jsonb;v_runs jsonb;v_pools jsonb;v_dupes jsonb;v_activity jsonb;v_merges jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select lower(email),phone,lower(full_name) into v_email,v_phone,v_name from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  if not found then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_docs from (
    select d.id,d.filename,d.mime_type,d.size_bytes,d.version_number,d.is_primary,d.created_at,d.candidate_id,
      case when d.candidate_id=p_candidate_id then false else true end as from_merged_profile
    from public.candidate_documents d
    where d.agency_id=v_agency and d.archived_at is null and (
      d.candidate_id=p_candidate_id or d.candidate_id in (
        select merged_candidate_id from public.candidate_merge_events where agency_id=v_agency and surviving_candidate_id=p_candidate_id
      )
    ) order by d.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_runs from (
    select id,document_id,status,parser_version,extracted_data,field_confidence,field_evidence,review_state,error_message,created_at
    from public.candidate_parse_runs where agency_id=v_agency and candidate_id=p_candidate_id order by created_at desc limit 8
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) into v_pools from (
    select p.id,p.name,p.description,(m.candidate_id is not null) member
    from public.talent_pools p left join public.talent_pool_members m on m.pool_id=p.id and m.candidate_id=p_candidate_id
    where p.agency_id=v_agency and p.active=true
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.score desc),'[]'::jsonb) into v_dupes from (
    select c.id,c.full_name,c.email,c.phone,c.current_title,c.current_company,c.city,c.country_code,c.updated_at,
      (case when v_email is not null and lower(c.email)=v_email then 60 else 0 end + case when v_phone is not null and c.phone=v_phone then 60 else 0 end + case when lower(c.full_name)=v_name then 35 else 0 end)::integer score
    from public.candidates c where c.agency_id=v_agency and c.id<>p_candidate_id and c.archived_at is null and c.merged_into_candidate_id is null
      and ((v_email is not null and lower(c.email)=v_email) or (v_phone is not null and c.phone=v_phone) or lower(c.full_name)=v_name)
    order by score desc,c.updated_at desc limit 10
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into v_activity from (
    select id,actor_user_id,entity_type,entity_id,action,summary,metadata,occurred_at from public.recruitment_activity_events
    where agency_id=v_agency and entity_type='candidate' and entity_id=p_candidate_id
    order by occurred_at desc limit 60
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_merges from (
    select m.id,m.merged_candidate_id,m.field_resolution,m.merged_by_user_id,m.created_at,c.full_name as merged_candidate_name,c.email as merged_candidate_email
    from public.candidate_merge_events m left join public.candidates c on c.id=m.merged_candidate_id and c.agency_id=v_agency
    where m.agency_id=v_agency and m.surviving_candidate_id=p_candidate_id order by m.created_at desc
  ) x;

  return jsonb_build_object('ok',true,'documents',v_docs,'parse_runs',v_runs,'talent_pools',v_pools,'duplicates',v_dupes,'activity',v_activity,'merge_history',v_merges);
end;$fn$;

grant execute on function public.xzrecruiter_candidate_closeout_context(text,uuid) to anon,authenticated;
