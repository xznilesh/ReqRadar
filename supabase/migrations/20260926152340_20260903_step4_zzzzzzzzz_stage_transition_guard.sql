-- XZ Recruiter Step 4 closeout: enforce configured stage requirements server-side.
-- Additive override only; no data is deleted or rewritten.

create or replace function public.xzrecruiter_move_application_stage(
  p_token text,
  p_application_id uuid,
  p_stage_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;
  v_user uuid;
  v_role text;
  v_pipeline uuid;
  v_old_stage uuid;
  v_old_name text;
  v_new_name text;
  v_code text;
  v_category text;
  v_required jsonb := '[]'::jsonb;
  v_rules jsonb := '{}'::jsonb;
  v_missing jsonb := '[]'::jsonb;
  v_allowed jsonb;
  v_item text;
  v_candidate uuid;
  v_job uuid;
  v_client uuid;
  v_email text;
  v_phone text;
  v_timezone text;
  v_country text;
  v_skills jsonb;
  v_has_resume boolean := false;
  v_has_screening boolean := false;
  v_has_submission boolean := false;
  v_has_interview boolean := false;
  v_has_scorecard boolean := false;
  v_has_offer boolean := false;
  v_has_approved_offer boolean := false;
  v_has_placement boolean := false;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then
    return jsonb_build_object('ok',false,'error','unauthorized');
  end if;
  if not private.xzrecruiter_can_write(v_role) then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  select a.pipeline_id,a.stage_id,a.stage,a.candidate_id,a.job_id,a.client_id,
         c.email,c.phone,c.timezone,c.country_code,c.skills
  into v_pipeline,v_old_stage,v_old_name,v_candidate,v_job,v_client,
       v_email,v_phone,v_timezone,v_country,v_skills
  from public.applications a
  join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency
  where a.id=p_application_id
    and a.agency_id=v_agency
    and a.archived_at is null
    and c.archived_at is null
    and c.merged_into_candidate_id is null;

  if not found then
    return jsonb_build_object('ok',false,'error','application_not_found');
  end if;

  select name,code,stage_category,required_fields,transition_rules
  into v_new_name,v_code,v_category,v_required,v_rules
  from public.pipeline_stages
  where id=p_stage_id
    and agency_id=v_agency
    and pipeline_id=v_pipeline;

  if not found then
    return jsonb_build_object('ok',false,'error','invalid_stage');
  end if;

  if jsonb_typeof(coalesce(v_required,'[]'::jsonb)) <> 'array' then
    v_required := '[]'::jsonb;
  end if;
  if jsonb_typeof(coalesce(v_rules,'{}'::jsonb)) <> 'object' then
    v_rules := '{}'::jsonb;
  end if;

  -- Optional role allow-list configured on the stage.
  v_allowed := coalesce(v_rules->'allowedRoles',v_rules->'allowed_roles');
  if jsonb_typeof(v_allowed)='array' and jsonb_array_length(v_allowed)>0 then
    if not exists(
      select 1 from jsonb_array_elements_text(v_allowed) x(role_name)
      where upper(x.role_name)=upper(v_role)
    ) then
      return jsonb_build_object('ok',false,'error','stage_role_forbidden','stage',v_new_name);
    end if;
  end if;

  if v_code='REJECTED' and btrim(coalesce(p_reason,''))='' then
    return jsonb_build_object('ok',false,'error','rejection_reason_required');
  end if;
  if v_code='WITHDRAWN' and coalesce((v_rules->>'requiresReason')::boolean,(v_rules->>'requires_reason')::boolean,false)
     and btrim(coalesce(p_reason,''))='' then
    return jsonb_build_object('ok',false,'error','withdrawal_reason_required');
  end if;

  -- Compute reusable evidence once so configured requirements stay cheap and deterministic.
  select exists(
    select 1 from public.candidate_documents d
    where d.agency_id=v_agency and d.candidate_id=v_candidate
      and d.document_type='RESUME' and d.archived_at is null
  ) into v_has_resume;

  select exists(
    select 1 from public.application_screening_answers s
    where s.agency_id=v_agency and s.application_id=p_application_id
  ) into v_has_screening;

  select exists(
    select 1 from public.candidate_submissions s
    where s.agency_id=v_agency and s.application_id=p_application_id
      and s.status in ('SUBMITTED','CLIENT_VIEWED','FEEDBACK_REQUESTED','INTERVIEW_REQUESTED','ADVANCED')
  ) into v_has_submission;

  select exists(
    select 1 from public.interviews i
    where i.agency_id=v_agency and i.application_id=p_application_id
      and coalesce(i.status,'SCHEDULED') not in ('CANCELLED')
  ) into v_has_interview;

  select exists(
    select 1
    from public.interview_scorecards sc
    join public.interviews i on i.id=sc.interview_id and i.agency_id=v_agency
    where sc.agency_id=v_agency
      and i.application_id=p_application_id
      and sc.status='SUBMITTED'
  ) into v_has_scorecard;

  select exists(
    select 1 from public.offers o
    where o.agency_id=v_agency and o.application_id=p_application_id
  ) into v_has_offer;

  select exists(
    select 1 from public.offers o
    where o.agency_id=v_agency and o.application_id=p_application_id
      and o.status in ('APPROVED','SENT','VIEWED','ACCEPTED')
  ) into v_has_approved_offer;

  select exists(
    select 1 from public.placements p
    where p.agency_id=v_agency and p.application_id=p_application_id
      and coalesce(p.status,'PLANNED') <> 'CANCELLED'
  ) into v_has_placement;

  -- required_fields is a data-driven array configured in Step 3.
  for v_item in
    select lower(btrim(value)) from jsonb_array_elements_text(v_required)
  loop
    if v_item in ('client','client_id') and v_client is null then
      v_missing := v_missing || jsonb_build_array('client');
    elsif v_item in ('candidate_email','email') and nullif(btrim(coalesce(v_email,'')),'') is null then
      v_missing := v_missing || jsonb_build_array('candidate_email');
    elsif v_item in ('candidate_phone','phone') and nullif(btrim(coalesce(v_phone,'')),'') is null then
      v_missing := v_missing || jsonb_build_array('candidate_phone');
    elsif v_item in ('candidate_contact','verified_contact') and nullif(btrim(coalesce(v_email,'')), '') is null and nullif(btrim(coalesce(v_phone,'')), '') is null then
      v_missing := v_missing || jsonb_build_array('candidate_contact');
    elsif v_item in ('candidate_timezone','timezone') and nullif(btrim(coalesce(v_timezone,'')),'') is null then
      v_missing := v_missing || jsonb_build_array('candidate_timezone');
    elsif v_item in ('candidate_country','country') and nullif(btrim(coalesce(v_country,'')),'') is null then
      v_missing := v_missing || jsonb_build_array('candidate_country');
    elsif v_item in ('candidate_skills','skills') and jsonb_array_length(coalesce(v_skills,'[]'::jsonb))=0 then
      v_missing := v_missing || jsonb_build_array('candidate_skills');
    elsif v_item in ('resume','candidate_resume','cv') and not v_has_resume then
      v_missing := v_missing || jsonb_build_array('resume');
    elsif v_item in ('screening','screening_answers') and not v_has_screening then
      v_missing := v_missing || jsonb_build_array('screening');
    elsif v_item in ('submission','client_submission') and not v_has_submission then
      v_missing := v_missing || jsonb_build_array('client_submission');
    elsif v_item in ('interview','scheduled_interview') and not v_has_interview then
      v_missing := v_missing || jsonb_build_array('interview');
    elsif v_item in ('scorecard','interview_scorecard') and not v_has_scorecard then
      v_missing := v_missing || jsonb_build_array('scorecard');
    elsif v_item in ('offer','offer_record') and not v_has_offer then
      v_missing := v_missing || jsonb_build_array('offer');
    elsif v_item in ('approved_offer','offer_approval') and not v_has_approved_offer then
      v_missing := v_missing || jsonb_build_array('approved_offer');
    elsif v_item in ('placement','hire_record') and not v_has_placement then
      v_missing := v_missing || jsonb_build_array('placement');
    end if;
  end loop;

  -- transition_rules can turn common evidence requirements on without exposing implementation details.
  if coalesce((v_rules->>'requiresResume')::boolean,(v_rules->>'requires_resume')::boolean,false) and not v_has_resume then
    v_missing := v_missing || jsonb_build_array('resume');
  end if;
  if coalesce((v_rules->>'requiresScreening')::boolean,(v_rules->>'requires_screening')::boolean,false) and not v_has_screening then
    v_missing := v_missing || jsonb_build_array('screening');
  end if;
  if coalesce((v_rules->>'requiresSubmission')::boolean,(v_rules->>'requires_submission')::boolean,false) and not v_has_submission then
    v_missing := v_missing || jsonb_build_array('client_submission');
  end if;
  if coalesce((v_rules->>'requiresInterview')::boolean,(v_rules->>'requires_interview')::boolean,false) and not v_has_interview then
    v_missing := v_missing || jsonb_build_array('interview');
  end if;
  if coalesce((v_rules->>'requiresScorecard')::boolean,(v_rules->>'requires_scorecard')::boolean,false) and not v_has_scorecard then
    v_missing := v_missing || jsonb_build_array('scorecard');
  end if;
  if coalesce((v_rules->>'requiresOffer')::boolean,(v_rules->>'requires_offer')::boolean,false) and not v_has_offer then
    v_missing := v_missing || jsonb_build_array('offer');
  end if;
  if coalesce((v_rules->>'requiresApprovedOffer')::boolean,(v_rules->>'requires_approved_offer')::boolean,false) and not v_has_approved_offer then
    v_missing := v_missing || jsonb_build_array('approved_offer');
  end if;
  if coalesce((v_rules->>'requiresPlacement')::boolean,(v_rules->>'requires_placement')::boolean,false) and not v_has_placement then
    v_missing := v_missing || jsonb_build_array('placement');
  end if;

  -- Deduplicate repeated requirements before returning them to the client.
  if jsonb_array_length(v_missing)>0 then
    select coalesce(jsonb_agg(x order by x),'[]'::jsonb)
    into v_missing
    from (
      select distinct value as x
      from jsonb_array_elements_text(v_missing)
    ) d;
    return jsonb_build_object(
      'ok',false,
      'error','stage_requirements_missing',
      'stage',v_new_name,
      'missing',v_missing
    );
  end if;

  update public.applications
  set stage_id=p_stage_id,
      stage=v_new_name,
      stage_entered_at=now(),
      last_activity_at=now(),
      updated_at=now(),
      rejection_reason=case when v_code='REJECTED' then p_reason else rejection_reason end,
      withdrawal_reason=case when v_code='WITHDRAWN' then p_reason else withdrawal_reason end
  where id=p_application_id and agency_id=v_agency;

  insert into public.application_stage_history(
    agency_id,application_id,from_stage_id,to_stage_id,from_stage,to_stage,reason,changed_by_user_id
  ) values(
    v_agency,p_application_id,v_old_stage,p_stage_id,v_old_name,v_new_name,p_reason,v_user
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',p_application_id,'application.stage_changed',
    coalesce(v_old_name,'Unstaged')||' → '||v_new_name,
    jsonb_build_object('reason',p_reason,'stage_code',v_code)
  );

  return jsonb_build_object('ok',true,'stage_id',p_stage_id,'stage',v_new_name,'stage_code',v_code);
end;
$fn$;

grant execute on function public.xzrecruiter_move_application_stage(text,uuid,uuid,text) to anon,authenticated;
