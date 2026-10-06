-- Step 4 closeout: enrich secure candidate portal snapshot with candidate-editable fields.
create or replace function public.xzrecruiter_candidate_portal_snapshot(p_portal_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_candidate uuid;v_result jsonb;v_hash text;
begin
 v_hash:=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex');
 select agency_id,candidate_id into v_agency,v_candidate from public.candidate_portal_sessions where token_hash=v_hash and revoked_at is null and expires_at>now() limit 1;
 if v_candidate is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 update public.candidate_portal_sessions set last_seen_at=now() where token_hash=v_hash;
 select jsonb_build_object('ok',true,'candidate',(select jsonb_build_object(
   'id',c.id,'full_name',c.full_name,'preferred_name',c.preferred_name,'headline',c.headline,'email',c.email,'phone',c.phone,'city',c.city,'region',c.region,'country_code',c.country_code,
   'availability_status',c.availability_status,'workplace_preference',c.workplace_preference,'consent_status',c.consent_status,'portal_profile_updated_at',c.portal_profile_updated_at
 ) from public.candidates c where c.id=v_candidate and c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null),
   'applications',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'stage',a.stage,'status',a.status,'job_id',j.id,'job_title',j.title,'updated_at',a.updated_at) order by a.updated_at desc) from public.applications a join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency where a.agency_id=v_agency and a.candidate_id=v_candidate and a.archived_at is null),'[]'::jsonb),
   'interviews',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'type',i.interview_type,'scheduled_at',i.scheduled_at,'timezone',i.timezone,'meeting_url',i.meeting_url,'location',i.location_or_link,'status',i.status) order by i.scheduled_at) from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=v_agency where a.candidate_id=v_candidate and i.agency_id=v_agency),'[]'::jsonb),
   'offers',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'title',o.title,'amount',o.amount,'currency',o.currency,'status',o.status,'start_date',o.start_date,'expires_at',o.expires_at,'version',o.version_number) order by o.created_at desc) from public.offers o join public.applications a on a.id=o.application_id and a.agency_id=v_agency where a.candidate_id=v_candidate and o.agency_id=v_agency and o.status in ('SENT','VIEWED','ACCEPTED','DECLINED','EXPIRED')),'[]'::jsonb)) into v_result;
 return v_result;
end;$fn$;
grant execute on function public.xzrecruiter_candidate_portal_snapshot(text) to anon,authenticated;
