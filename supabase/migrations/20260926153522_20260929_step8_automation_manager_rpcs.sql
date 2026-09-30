-- XZ Recruiter locked roadmap Step 8: Automation + Real-Time Manager Control RPCs.
-- Deterministic operational control only. No autonomous hiring decisions and no Step-9 launch work.

create or replace function private.xzrecruiter_step8_timezone(p_agency uuid)
returns text
language sql stable security invoker set search_path='public','pg_temp'
as $$
  select coalesce((select s.timezone_id from public.workspace_global_settings s where s.agency_id=p_agency limit 1),'UTC');
$$;
revoke all on function private.xzrecruiter_step8_timezone(uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_step8_upsert_alert(
  p_agency uuid,p_run uuid,p_rule text,p_category text,p_severity text,
  p_entity_type text,p_entity_id uuid,p_job uuid,p_application uuid,p_candidate uuid,
  p_owner uuid,p_target_role text,p_reasons jsonb,p_summary text,p_action text,
  p_due timestamptz,p_fingerprint text,p_metadata jsonb,p_cooldown_minutes integer
) returns uuid
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare
  v_key text:=lower(coalesce(p_rule,''))||'|'||lower(coalesce(p_entity_type,''))||'|'||coalesce(p_entity_id::text,'')||'|'||coalesce(p_owner::text,'');
  v_id uuid;v_lifecycle text;v_fp text;v_last timestamptz;v_event text;
begin
  select id,lifecycle,source_fingerprint,last_detected_at into v_id,v_lifecycle,v_fp,v_last
  from public.automation_alerts
  where agency_id=p_agency and dedupe_key=v_key
  for update;

  if v_id is null then
    insert into public.automation_alerts(
      agency_id,dedupe_key,rule_code,category,severity,lifecycle,entity_type,entity_id,
      job_id,application_id,candidate_id,owner_user_id,target_role,reason_codes,reason_summary,
      recommended_action,due_at,last_detected_run_id,source_fingerprint,metadata
    ) values(
      p_agency,v_key,p_rule,p_category,p_severity,'OPEN',p_entity_type,p_entity_id,
      p_job,p_application,p_candidate,p_owner,p_target_role,coalesce(p_reasons,'[]'::jsonb),
      left(coalesce(p_summary,''),1500),left(coalesce(p_action,''),1000),p_due,p_run,
      coalesce(p_fingerprint,''),coalesce(p_metadata,'{}'::jsonb)
    ) returning id into v_id;
    insert into public.automation_alert_events(agency_id,alert_id,event_type,metadata)
    values(p_agency,v_id,'CREATED',jsonb_build_object('run_id',p_run,'rule_code',p_rule));
  else
    v_event:=case
      when v_lifecycle='RESOLVED' then 'REOPENED'
      when v_lifecycle='DISMISSED' and v_fp is distinct from p_fingerprint then 'REOPENED'
      when v_lifecycle<>'DISMISSED' and (v_fp is distinct from p_fingerprint or v_last<=now()-make_interval(mins=>greatest(coalesce(p_cooldown_minutes,120),15))) then 'REFRESHED'
      else null end;
    update public.automation_alerts
    set rule_code=p_rule,category=p_category,severity=p_severity,
        lifecycle=case
          when lifecycle='RESOLVED' then 'OPEN'
          when lifecycle='DISMISSED' and source_fingerprint is distinct from p_fingerprint then 'OPEN'
          else lifecycle end,
        entity_type=p_entity_type,entity_id=p_entity_id,job_id=p_job,application_id=p_application,
        candidate_id=p_candidate,owner_user_id=p_owner,target_role=p_target_role,
        reason_codes=coalesce(p_reasons,'[]'::jsonb),reason_summary=left(coalesce(p_summary,''),1500),
        recommended_action=left(coalesce(p_action,''),1000),due_at=p_due,last_detected_at=now(),
        last_detected_run_id=p_run,source_fingerprint=coalesce(p_fingerprint,''),
        metadata=coalesce(p_metadata,'{}'::jsonb),resolved_at=null,resolution_reason=null,
        occurrence_count=occurrence_count+1
    where id=v_id;
    if v_event is not null then
      insert into public.automation_alert_events(agency_id,alert_id,event_type,metadata)
      values(p_agency,v_id,v_event,jsonb_build_object('run_id',p_run,'rule_code',p_rule));
    end if;
  end if;
  return v_id;
end;
$$;
revoke all on function private.xzrecruiter_step8_upsert_alert(uuid,uuid,text,text,text,text,uuid,uuid,uuid,uuid,uuid,text,jsonb,text,text,timestamptz,text,jsonb,integer) from public,anon,authenticated;

create or replace function private.xzrecruiter_step8_ensure_task(
  p_agency uuid,p_automation_key text,p_title text,p_description text,p_priority text,
  p_due timestamptz,p_assignee uuid,p_job uuid,p_application uuid,p_candidate uuid,p_task_type text
) returns uuid
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_id uuid;v_creator uuid;
begin
  select id into v_id from public.crm_tasks
  where agency_id=p_agency and automation_key=p_automation_key and archived_at is null
  for update;
  if v_id is not null then
    update public.crm_tasks set
      title=left(p_title,500),description=left(p_description,2000),
      priority=case when upper(p_priority) in ('LOW','NORMAL','HIGH','URGENT') then upper(p_priority) else 'NORMAL' end,
      due_at=p_due,assigned_user_id=p_assignee,job_id=p_job,application_id=p_application,candidate_id=p_candidate,
      task_type=p_task_type,status=case when status in ('DONE','CANCELLED') then 'OPEN' else status end,
      completed_at=case when status in ('DONE','CANCELLED') then null else completed_at end,updated_at=now()
    where id=v_id;
    return v_id;
  end if;
  select m.user_id into v_creator from public.agency_memberships m
  where m.agency_id=p_agency order by case when private.xzrecruiter_business_role(m.agency_id,m.user_id,m.role)='OWNER' then 0 else 1 end limit 1;
  insert into public.crm_tasks(
    agency_id,title,description,status,priority,due_at,assigned_user_id,created_by_user_id,
    job_id,application_id,candidate_id,task_type,automation_key
  ) values(
    p_agency,left(p_title,500),left(p_description,2000),'OPEN',
    case when upper(p_priority) in ('LOW','NORMAL','HIGH','URGENT') then upper(p_priority) else 'NORMAL' end,
    p_due,p_assignee,coalesce(v_creator,p_assignee),p_job,p_application,p_candidate,p_task_type,p_automation_key
  ) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.xzrecruiter_step8_ensure_task(uuid,text,text,text,text,timestamptz,uuid,uuid,uuid,uuid,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_step8_alert_condition_holds(
  p_agency uuid,p_alert_id uuid
) returns boolean
language plpgsql stable security definer
set search_path='public','private','pg_temp'
as $alert$
declare
  v_alert public.automation_alerts%rowtype;v_cfg public.automation_control_configs%rowtype;
  v_tz text;v_day date;v_start timestamptz;v_end timestamptz;v_cutoff timestamptz;v_hours_cutoff numeric;
  v_target integer;v_valid integer;
begin
  select * into v_alert from public.automation_alerts where agency_id=p_agency and id=p_alert_id;
  if v_alert.id is null then return false; end if;
  select * into v_cfg from public.automation_control_configs where agency_id=p_agency;
  if v_cfg.agency_id is null then return false; end if;
  v_tz:=private.xzrecruiter_step8_timezone(p_agency);
  v_day:=(timezone(v_tz,now()))::date;
  v_start:=v_day::timestamp at time zone v_tz;
  v_end:=(v_day+1)::timestamp at time zone v_tz;
  v_cutoff:=(v_day::timestamp+v_cfg.business_day_cutoff_local) at time zone v_tz;
  v_hours_cutoff:=extract(epoch from (v_cutoff-now()))/3600.0;

  if v_alert.rule_code='REQUIREMENT_HEALTH' then
    return exists(
      select 1 from public.requirement_health_current h
      join public.recruitment_jobs j on j.id=h.job_id and j.agency_id=p_agency
      where h.agency_id=p_agency and h.job_id=v_alert.job_id
        and h.health_status in ('NEEDS_ATTENTION','AT_RISK','BLOCKED')
        and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN'
        and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'
    );
  elsif v_alert.rule_code='RECRUITER_TARGET_GAP' then
    select coalesce(a.daily_submission_target,0) into v_target
    from public.requirement_recruiter_assignments a
    join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency
    where a.agency_id=p_agency and a.job_id=v_alert.job_id and a.recruiter_user_id=v_alert.owner_user_id
      and a.assignment_status='ACTIVE' and j.archived_at is null and j.recruiter_ready=true
      and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null
      and upper(coalesce(j.status,'OPEN'))='OPEN';
    if coalesce(v_target,0)<=0 or v_hours_cutoff>v_cfg.target_attention_hours_before_cutoff then return false; end if;
    select count(distinct s.application_id)::integer into v_valid
    from public.candidate_submissions s
    join public.applications ap on ap.id=s.application_id and ap.agency_id=p_agency
    where s.agency_id=p_agency and s.job_id=v_alert.job_id and s.created_by_user_id=v_alert.owner_user_id
      and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
      and s.invalidated_at is null and s.withdrawn_at is null
      and upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED')
      and s.client_submitted_at>=v_start and s.client_submitted_at<v_end;
    return coalesce(v_valid,0)<v_target;
  elsif v_alert.rule_code='PIPELINE_STAGNATION' then
    return exists(
      select 1 from public.applications a
      join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency
      where a.agency_id=p_agency and a.id=v_alert.application_id and a.archived_at is null
        and upper(coalesce(a.status,'ACTIVE'))='ACTIVE'
        and coalesce(a.last_activity_at,a.stage_entered_at,a.updated_at)<now()-make_interval(hours=>v_cfg.pipeline_stagnation_hours)
        and upper(coalesce(a.stage,'')) not in ('REJECTED','WITHDRAWN','HIRED','PLACED')
        and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN'
        and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'
    );
  elsif v_alert.rule_code='SCREENING_ACTION_OVERDUE' then
    return exists(
      select 1 from public.application_screening_sessions s
      where s.agency_id=p_agency and s.id=v_alert.entity_id
        and s.status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED')
        and s.updated_at<now()-make_interval(hours=>v_cfg.screening_attention_hours)
    );
  elsif v_alert.rule_code='FOLLOW_UP_OVERDUE' then
    return exists(
      select 1 from public.crm_tasks t
      where t.agency_id=p_agency and t.id=v_alert.entity_id and t.archived_at is null
        and t.status in ('OPEN','IN_PROGRESS') and t.due_at is not null and t.due_at<now()
    );
  elsif v_alert.rule_code='AM_REVIEW_OVERDUE' then
    return exists(
      select 1 from public.candidate_submissions s
      where s.agency_id=p_agency and s.id=v_alert.entity_id and s.workflow_status='INTERNAL_SUBMITTED'
        and s.invalidated_at is null and s.withdrawn_at is null
        and coalesce(s.internal_submitted_at,s.updated_at)<now()-make_interval(hours=>v_cfg.am_review_attention_hours)
    );
  elsif v_alert.rule_code='CLIENT_FEEDBACK_OVERDUE' then
    return exists(
      select 1 from public.candidate_submissions s
      where s.agency_id=p_agency and s.id=v_alert.entity_id and s.workflow_status='CLIENT_SUBMITTED'
        and s.invalidated_at is null and s.withdrawn_at is null
        and s.client_submitted_at<now()-make_interval(hours=>v_cfg.client_feedback_attention_hours)
        and not exists(
          select 1 from public.recruitment_activity_events e
          where e.agency_id=p_agency and e.entity_type='application' and e.entity_id=s.application_id
            and e.action='client.feedback_received' and e.occurred_at>=s.client_submitted_at
        )
    );
  elsif v_alert.rule_code='INTERVIEW_UPCOMING' then
    return exists(
      select 1 from public.interviews i
      where i.agency_id=p_agency and i.id=v_alert.entity_id
        and upper(coalesce(i.status,'SCHEDULED'))='SCHEDULED'
        and i.scheduled_at between now() and now()+make_interval(hours=>v_cfg.interview_reminder_hours)
    );
  elsif v_alert.rule_code='DOCUMENT_EXPIRY' then
    return exists(
      select 1 from public.candidate_documents d
      where d.agency_id=p_agency and d.id=v_alert.entity_id and d.archived_at is null
        and d.expires_at is not null and d.expires_at<=now()+interval '7 days'
    );
  elsif v_alert.rule_code='OFFER_ACTION_OVERDUE' then
    return exists(
      select 1 from public.offers o
      where o.agency_id=p_agency and o.id=v_alert.entity_id and o.sent_at is not null
        and o.accepted_at is null and o.declined_at is null and o.withdrawn_at is null
        and o.sent_at<now()-make_interval(hours=>v_cfg.offer_action_hours)
    );
  elsif v_alert.rule_code='JOINING_ACTION' then
    return exists(
      select 1 from public.placements p
      where p.agency_id=p_agency and p.id=v_alert.entity_id and p.status in ('PLANNED','CONFIRMED')
        and p.start_date<=v_day+v_cfg.joining_action_days
    );
  end if;
  return false;
end;
$alert$;
revoke all on function private.xzrecruiter_step8_alert_condition_holds(uuid,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_step8_run_agency(
  p_agency uuid,p_run_kind text default 'SCHEDULED',p_worker text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $$
declare
  v_run uuid;v_cfg public.automation_control_configs%rowtype;v_tz text;v_day date;v_start timestamptz;v_end timestamptz;v_cutoff timestamptz;
  v_job record;v_assignment record;v_app record;v_sub record;v_interview record;v_doc record;v_offer record;v_place record;
  v_target integer;v_valid integer;v_pipeline integer;v_screen integer;v_follow integer;v_am integer;v_client integer;v_qualified integer;
  v_last timestamptz;v_deadline_days integer;v_hours_cutoff numeric;v_reasons jsonb;v_actions jsonb;v_health text;v_old_health text;
  v_fp text;v_alert uuid;v_detected integer:=0;v_created integer:=0;v_tasks integer:=0;v_resolved integer:=0;v_before integer;
begin
  if not exists(select 1 from public.agencies a where a.id=p_agency) then
    return jsonb_build_object('ok',false,'error','agency_not_found');
  end if;
  perform pg_advisory_xact_lock(hashtext('xzr-step8-'||p_agency::text));

  insert into public.automation_control_configs(agency_id) values(p_agency)
  on conflict(agency_id) do nothing;
  select * into v_cfg from public.automation_control_configs where agency_id=p_agency;
  if not coalesce(v_cfg.enabled,true) then return jsonb_build_object('ok',true,'skipped',true,'reason','automation_disabled'); end if;

  v_tz:=private.xzrecruiter_step8_timezone(p_agency);
  v_day:=(timezone(v_tz,now()))::date;
  v_start:=v_day::timestamp at time zone v_tz;
  v_end:=(v_day+1)::timestamp at time zone v_tz;
  v_cutoff:=(v_day::timestamp+v_cfg.business_day_cutoff_local) at time zone v_tz;
  v_hours_cutoff:=extract(epoch from (v_cutoff-now()))/3600.0;

  insert into public.automation_runs(agency_id,run_kind,worker_id)
  values(p_agency,case when upper(p_run_kind) in ('SCHEDULED','MANUAL','EVENT') then upper(p_run_kind) else 'SCHEDULED' end,left(p_worker,200))
  returning id into v_run;

  for v_job in
    select j.id,j.title,j.status,j.priority,j.target_fill_date,j.submission_target_daily,j.submission_target_total,
      j.owner_user_id,j.updated_at,j.client_id,
      exists(select 1 from public.requirement_recruiter_assignments ra where ra.agency_id=p_agency and ra.job_id=j.id and ra.assignment_status='ACTIVE' and ra.blocker_reason is not null) explicit_blocker
    from public.recruitment_jobs j
    where j.agency_id=p_agency and j.archived_at is null
      and j.recruiter_ready=true and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null
      and upper(coalesce(j.status,'OPEN')) in ('OPEN','ON_HOLD')
  loop
    if upper(coalesce(v_job.status,'OPEN'))='ON_HOLD' then
      v_reasons:=jsonb_build_array('REQUIREMENT_ON_HOLD');
      v_actions:='[]'::jsonb;
      v_fp:=md5('ON_HOLD|'||v_job.id::text||'|'||coalesce(v_job.updated_at::text,''));
      select health_status into v_old_health from public.requirement_health_current where agency_id=p_agency and job_id=v_job.id;
      insert into public.requirement_health_current(agency_id,job_id,health_status,reason_codes,facts,next_actions,source_fingerprint)
      values(p_agency,v_job.id,'ON_HOLD',v_reasons,jsonb_build_object('dailyTarget',0,'validSubmissionsToday',0,'remainingTarget',0,'pipelineCount',0),v_actions,v_fp)
      on conflict(agency_id,job_id) do update set health_status='ON_HOLD',reason_codes=excluded.reason_codes,
        facts=excluded.facts,next_actions=excluded.next_actions,source_fingerprint=excluded.source_fingerprint,computed_at=now();
      if v_old_health is distinct from 'ON_HOLD' then
        perform private.xzrecruiter_log_activity(p_agency,null,'job',v_job.id,'requirement.health_changed',
          'Requirement health changed to ON HOLD',jsonb_build_object('from',v_old_health,'to','ON_HOLD','reason_codes',v_reasons));
      end if;
      continue;
    end if;

    v_target:=greatest(coalesce(v_job.submission_target_daily,0),0);
    select count(distinct cs.application_id)::integer into v_valid
    from public.candidate_submissions cs
    join public.applications a on a.id=cs.application_id and a.agency_id=p_agency
    where cs.agency_id=p_agency and cs.job_id=v_job.id and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
      and cs.invalidated_at is null and cs.withdrawn_at is null
      and cs.client_submitted_at>=v_start and cs.client_submitted_at<v_end
      and upper(coalesce(a.stage,'')) not in ('WITHDRAWN','REJECTED');

    select count(*)::integer into v_pipeline from public.applications a
    where a.agency_id=p_agency and a.job_id=v_job.id and a.archived_at is null
      and upper(coalesce(a.status,'ACTIVE'))='ACTIVE'
      and upper(coalesce(a.stage,'')) not in ('REJECTED','WITHDRAWN','HIRED','PLACED');

    select count(*)::integer into v_screen from public.application_screening_sessions s
    where s.agency_id=p_agency and s.job_id=v_job.id
      and s.status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED')
      and s.updated_at<now()-make_interval(hours=>v_cfg.screening_attention_hours);

    select count(*)::integer into v_follow from public.crm_tasks t
    where t.agency_id=p_agency and t.job_id=v_job.id and t.archived_at is null
      and t.status in ('OPEN','IN_PROGRESS') and t.due_at is not null and t.due_at<now();

    select count(*)::integer into v_am from public.candidate_submissions s
    where s.agency_id=p_agency and s.job_id=v_job.id and s.workflow_status='INTERNAL_SUBMITTED'
      and coalesce(s.internal_submitted_at,s.updated_at)<now()-make_interval(hours=>v_cfg.am_review_attention_hours);

    select count(*)::integer into v_client from public.candidate_submissions s
    where s.agency_id=p_agency and s.job_id=v_job.id and s.workflow_status='CLIENT_SUBMITTED'
      and s.client_submitted_at<now()-make_interval(hours=>v_cfg.client_feedback_attention_hours)
      and not exists(
        select 1 from public.recruitment_activity_events e
        where e.agency_id=p_agency and e.entity_type='application' and e.entity_id=s.application_id
          and e.action='client.feedback_received' and e.occurred_at>=s.client_submitted_at
      );

    select count(*)::integer into v_qualified
    from public.application_screening_sessions s
    where s.agency_id=p_agency and s.job_id=v_job.id and s.status='QUALIFIED'
      and not exists(
        select 1 from public.candidate_submissions cs
        where cs.agency_id=p_agency and cs.application_id=s.application_id
          and cs.workflow_status in ('INTERNAL_SUBMITTED','AM_APPROVED','CLIENT_SUBMITTED')
      );

    select max(e.occurred_at) into v_last from public.recruitment_activity_events e
    where e.agency_id=p_agency and (
      (e.entity_type='job' and e.entity_id=v_job.id) or
      (e.entity_type='application' and exists(select 1 from public.applications a where a.agency_id=p_agency and a.id=e.entity_id and a.job_id=v_job.id))
    );
    v_last:=coalesce(v_last,v_job.updated_at);
    v_deadline_days:=case when v_job.target_fill_date is null then null else v_job.target_fill_date-v_day end;

    v_reasons:='[]'::jsonb;
    if v_job.explicit_blocker then v_reasons:=v_reasons||'"EXPLICIT_BLOCKER"'::jsonb; end if;
    if v_target>v_valid and v_hours_cutoff<=v_cfg.target_risk_hours_before_cutoff then v_reasons:=v_reasons||'"TARGET_GAP_CUTOFF_NEAR"'::jsonb; end if;
    if v_pipeline<v_cfg.min_viable_pipeline and (v_deadline_days is null or v_deadline_days<=v_cfg.deadline_attention_days) then v_reasons:=v_reasons||'"INSUFFICIENT_PIPELINE"'::jsonb; end if;
    if v_screen>0 then v_reasons:=v_reasons||'"SCREENING_OVERDUE"'::jsonb; end if;
    if v_follow>0 then v_reasons:=v_reasons||'"FOLLOW_UP_OVERDUE"'::jsonb; end if;
    if v_am>0 then v_reasons:=v_reasons||'"AM_REVIEW_BACKLOG"'::jsonb; end if;
    if v_client>0 then v_reasons:=v_reasons||'"CLIENT_FEEDBACK_DELAY"'::jsonb; end if;
    if v_deadline_days is not null and v_deadline_days<=v_cfg.deadline_risk_days then v_reasons:=v_reasons||'"DEADLINE_IMMINENT"'::jsonb; end if;
    if extract(epoch from (now()-v_last))/3600>=v_cfg.requirement_no_activity_hours and v_pipeline=0 then v_reasons:=v_reasons||'"NO_RECENT_EXECUTION"'::jsonb; end if;

    if v_job.explicit_blocker then v_health:='BLOCKED';
    elsif (v_reasons ? 'TARGET_GAP_CUTOFF_NEAR' and v_reasons ? 'DEADLINE_IMMINENT') or
          (v_reasons ? 'INSUFFICIENT_PIPELINE' and (v_reasons ? 'DEADLINE_IMMINENT' or v_reasons ? 'TARGET_GAP_CUTOFF_NEAR')) then v_health:='AT_RISK';
    elsif jsonb_array_length(v_reasons)>0 then v_health:='NEEDS_ATTENTION';
    else v_health:='HEALTHY'; end if;

    v_actions:='[]'::jsonb;
    if v_target>v_valid then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLOSE_TARGET_GAP','text',(v_target-v_valid)||' more valid submission(s) required today','why','Daily requirement target is not achieved.')); end if;
    if v_screen>0 then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMPLETE_SCREENINGS','text',v_screen||' screening action(s) overdue','why','Candidates are waiting in screening.')); end if;
    if v_qualified>0 then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','SUBMIT_QUALIFIED','text',v_qualified||' qualified candidate(s) waiting for submission','why','Qualified candidates have not progressed.')); end if;
    if v_am>0 then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLEAR_AM_BACKLOG','text',v_am||' submission(s) waiting for AM review','why','Internal submissions are ageing at the AM gate.')); end if;
    if v_client>0 then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','FOLLOW_UP_CLIENT','text',v_client||' client submission(s) awaiting feedback','why','Client response exceeded the feedback window.')); end if;
    if v_pipeline=0 then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','BUILD_PIPELINE','text','No viable candidate pipeline','why','Active requirement has no execution pipeline.')); end if;

    v_fp:=md5(v_health||'|'||v_reasons::text||'|'||v_target||'|'||v_valid||'|'||v_pipeline||'|'||v_screen||'|'||v_follow||'|'||v_am||'|'||v_client);
    select health_status into v_old_health from public.requirement_health_current where agency_id=p_agency and job_id=v_job.id;
    insert into public.requirement_health_current(agency_id,job_id,health_status,reason_codes,facts,next_actions,source_fingerprint)
    values(p_agency,v_job.id,v_health,v_reasons,jsonb_build_object(
      'dailyTarget',v_target,'validSubmissionsToday',v_valid,'remainingTarget',greatest(v_target-v_valid,0),
      'pipelineCount',v_pipeline,'overdueScreenings',v_screen,'overdueFollowups',v_follow,
      'amReviewBacklog',v_am,'clientFeedbackBacklog',v_client,'qualifiedWaiting',v_qualified,
      'deadlineDays',v_deadline_days,'hoursToCutoff',round(v_hours_cutoff,2),'hoursSinceActivity',round(extract(epoch from (now()-v_last))/3600.0,2)
    ),v_actions,v_fp)
    on conflict(agency_id,job_id) do update set health_status=excluded.health_status,reason_codes=excluded.reason_codes,
      facts=excluded.facts,next_actions=excluded.next_actions,source_fingerprint=excluded.source_fingerprint,computed_at=now();

    if v_old_health is distinct from v_health then
      perform private.xzrecruiter_log_activity(p_agency,null,'job',v_job.id,'requirement.health_changed',
        'Requirement health changed to '||v_health,jsonb_build_object('from',v_old_health,'to',v_health,'reason_codes',v_reasons));
    end if;

    if v_health<>'HEALTHY' then
      v_alert:=private.xzrecruiter_step8_upsert_alert(
        p_agency,v_run,'REQUIREMENT_HEALTH','REQUIREMENT_HEALTH',
        case when v_health in ('AT_RISK','BLOCKED') then 'URGENT' else 'ATTENTION' end,
        'job',v_job.id,v_job.id,null,null,v_job.owner_user_id,'RECRUITMENT_MANAGER',v_reasons,
        v_job.title||' is '||replace(v_health,'_',' '),
        coalesce(v_actions->0->>'text','Review requirement execution and assign next action.'),v_job.target_fill_date::timestamptz,
        v_fp,jsonb_build_object('health',v_health),v_cfg.alert_cooldown_minutes
      );
      v_detected:=v_detected+1;
    end if;

    for v_assignment in
      select a.*,u.display_name from public.requirement_recruiter_assignments a
      left join public.users u on u.id=a.recruiter_user_id
      where a.agency_id=p_agency and a.job_id=v_job.id and a.assignment_status='ACTIVE'
    loop
      if coalesce(v_assignment.daily_submission_target,0)>0 then
        select count(distinct cs.application_id)::integer into v_valid
        from public.candidate_submissions cs
        join public.applications ap on ap.id=cs.application_id and ap.agency_id=p_agency
        where cs.agency_id=p_agency and cs.job_id=v_job.id and cs.created_by_user_id=v_assignment.recruiter_user_id
          and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
          and cs.invalidated_at is null and cs.withdrawn_at is null
          and upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED')
          and cs.client_submitted_at>=v_start and cs.client_submitted_at<v_end;
        if v_valid<v_assignment.daily_submission_target and v_hours_cutoff<=v_cfg.target_attention_hours_before_cutoff then
          v_alert:=private.xzrecruiter_step8_upsert_alert(
            p_agency,v_run,'RECRUITER_TARGET_GAP','TARGET_ALERT',
            case when v_hours_cutoff<=v_cfg.target_risk_hours_before_cutoff then 'URGENT' else 'ATTENTION' end,
            'job',v_job.id,v_job.id,null,null,v_assignment.recruiter_user_id,'RECRUITER',
            jsonb_build_array('TARGET_GAP'),
            greatest(v_assignment.daily_submission_target-v_valid,0)||' valid submission(s) still required for '||coalesce(v_assignment.display_name,'recruiter'),
            'Close today''s valid submission gap before business-day cutoff.',v_cutoff,
            md5(v_job.id::text||'|'||v_assignment.recruiter_user_id::text||'|'||v_assignment.daily_submission_target||'|'||v_valid||'|'||v_day::text),
            jsonb_build_object('planned',v_assignment.daily_submission_target,'completed',v_valid,'remaining',greatest(v_assignment.daily_submission_target-v_valid,0)),
            v_cfg.alert_cooldown_minutes
          );
          v_detected:=v_detected+1;
        end if;
      end if;
    end loop;
  end loop;

  -- Candidate/application stagnation: deterministic and bounded to active candidacies.
  for v_app in
    select a.id,a.job_id,a.candidate_id,a.owner_user_id,coalesce(ps.code,upper(a.stage)) stage_code,
      a.stage_entered_at,a.last_activity_at,c.full_name
    from public.applications a
    join public.candidates c on c.id=a.candidate_id and c.agency_id=p_agency
    left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=p_agency
    join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency and j.archived_at is null and upper(coalesce(j.status,'OPEN'))='OPEN'
    where a.agency_id=p_agency and a.archived_at is null and upper(coalesce(a.status,'ACTIVE'))='ACTIVE'
      and coalesce(a.last_activity_at,a.stage_entered_at,a.updated_at)<now()-make_interval(hours=>v_cfg.pipeline_stagnation_hours)
      and upper(coalesce(ps.code,a.stage,'')) not in ('REJECTED','WITHDRAWN','HIRED','PLACED')
    order by coalesce(a.last_activity_at,a.stage_entered_at,a.updated_at)
    limit 500
  loop
    v_alert:=private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'PIPELINE_STAGNATION','PIPELINE_STAGNATION','ATTENTION',
      'application',v_app.id,v_app.job_id,v_app.id,v_app.candidate_id,v_app.owner_user_id,'RECRUITER',
      jsonb_build_array('PIPELINE_STAGNATION'),
      coalesce(v_app.full_name,'Candidate')||' has not moved from '||coalesce(v_app.stage_code,'current stage'),
      case when v_app.stage_code in ('APPLIED','NEW','SOURCED') then 'Contact candidate or record the next sourcing action.'
           when v_app.stage_code='SCREENING' then 'Complete or update screening.'
           when v_app.stage_code in ('QUALIFIED','SHORTLISTED') then 'Progress the qualified candidate to internal submission.'
           else 'Review candidacy and record the next operational action.' end,
      null,md5(v_app.id::text||'|'||coalesce(v_app.stage_code,'')||'|'||date_trunc('hour',coalesce(v_app.last_activity_at,v_app.stage_entered_at))::text),
      jsonb_build_object('stage',v_app.stage_code,'stageEnteredAt',v_app.stage_entered_at,'lastActivityAt',v_app.last_activity_at),
      v_cfg.alert_cooldown_minutes
    );
    v_detected:=v_detected+1;
  end loop;

  -- Candidate screening reminders. AI/hiring decisions remain outside automation; this only surfaces overdue human work.
  for v_app in
    select s.id,s.application_id,s.candidate_id,s.job_id,s.started_by_user_id owner_user_id,
      s.updated_at,c.full_name
    from public.application_screening_sessions s
    join public.candidates c on c.id=s.candidate_id and c.agency_id=p_agency
    where s.agency_id=p_agency and s.status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED')
      and s.updated_at<now()-make_interval(hours=>v_cfg.screening_attention_hours)
    order by s.updated_at limit 300
  loop
    perform private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'SCREENING_ACTION_OVERDUE','SCREENING_REMINDER',
      case when v_app.updated_at<now()-make_interval(hours=>v_cfg.screening_risk_hours) then 'URGENT' else 'ATTENTION' end,
      'screening',v_app.id,v_app.job_id,v_app.application_id,v_app.candidate_id,v_app.owner_user_id,'RECRUITER',
      jsonb_build_array('SCREENING_OVERDUE'),coalesce(v_app.full_name,'Candidate')||' screening action is overdue',
      'Complete or update the human screening action.',v_app.updated_at+make_interval(hours=>v_cfg.screening_attention_hours),
      md5(v_app.id::text||'|SCREENING|'||v_app.updated_at::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );
    v_detected:=v_detected+1;
  end loop;

  -- Existing execution follow-ups remain the canonical tasks; automation creates an alert/escalation, not a duplicate task.
  for v_app in
    select t.id,t.job_id,t.application_id,t.candidate_id,t.assigned_user_id owner_user_id,t.title,t.due_at
    from public.crm_tasks t
    where t.agency_id=p_agency and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS')
      and t.due_at is not null and t.due_at<now()
      and coalesce(t.task_type,'') not in ('AM_REVIEW','CLIENT_FEEDBACK')
    order by t.due_at limit 500
  loop
    perform private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'FOLLOW_UP_OVERDUE','FOLLOW_UP_REMINDER',
      case when v_app.due_at<now()-make_interval(hours=>v_cfg.followup_risk_hours) then 'URGENT' else 'ATTENTION' end,
      'task',v_app.id,v_app.job_id,v_app.application_id,v_app.candidate_id,v_app.owner_user_id,null,
      jsonb_build_array('FOLLOW_UP_OVERDUE'),coalesce(v_app.title,'Recruiter follow-up')||' is overdue',
      'Complete the existing task or update its due action.',v_app.due_at,
      md5(v_app.id::text||'|FOLLOWUP|'||v_app.due_at::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );
    v_detected:=v_detected+1;
  end loop;

  -- AM review backlog + task.
  for v_sub in
    select s.id,s.application_id,s.candidate_id,s.job_id,s.assigned_am_user_id,s.internal_submitted_at,c.full_name
    from public.candidate_submissions s
    join public.candidates c on c.id=s.candidate_id and c.agency_id=p_agency
    where s.agency_id=p_agency and s.workflow_status='INTERNAL_SUBMITTED'
      and s.invalidated_at is null and s.withdrawn_at is null
      and coalesce(s.internal_submitted_at,s.updated_at)<now()-make_interval(hours=>v_cfg.am_review_attention_hours)
    order by coalesce(s.internal_submitted_at,s.updated_at) limit 300
  loop
    v_alert:=private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'AM_REVIEW_OVERDUE','AM_REVIEW_REMINDER',
      case when v_sub.internal_submitted_at<now()-make_interval(hours=>v_cfg.am_review_risk_hours) then 'URGENT' else 'ATTENTION' end,
      'submission',v_sub.id,v_sub.job_id,v_sub.application_id,v_sub.candidate_id,v_sub.assigned_am_user_id,'ACCOUNT_MANAGER',
      jsonb_build_array('AM_REVIEW_BACKLOG'),coalesce(v_sub.full_name,'Candidate')||' submission is waiting for AM review',
      'Review the client-ready submission pack or return a targeted correction.',coalesce(v_sub.internal_submitted_at,now())+make_interval(hours=>v_cfg.am_review_attention_hours),
      md5(v_sub.id::text||'|AM|'||coalesce(v_sub.internal_submitted_at::text,'')),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );
    perform private.xzrecruiter_step8_ensure_task(
      p_agency,'step8:am:'||v_sub.id::text,'Review candidate submission','AM Quality Gate review is overdue.',
      'HIGH',coalesce(v_sub.internal_submitted_at,now())+make_interval(hours=>v_cfg.am_review_attention_hours),
      v_sub.assigned_am_user_id,v_sub.job_id,v_sub.application_id,v_sub.candidate_id,'AM_REVIEW'
    );
    v_detected:=v_detected+1;v_tasks:=v_tasks+1;
  end loop;

  -- Client feedback backlog + task. Feedback is a canonical activity event, not a parallel submission state.
  for v_sub in
    select s.id,s.application_id,s.candidate_id,s.job_id,s.assigned_am_user_id,s.client_submitted_at,c.full_name
    from public.candidate_submissions s
    join public.candidates c on c.id=s.candidate_id and c.agency_id=p_agency
    where s.agency_id=p_agency and s.workflow_status='CLIENT_SUBMITTED'
      and s.invalidated_at is null and s.withdrawn_at is null
      and s.client_submitted_at<now()-make_interval(hours=>v_cfg.client_feedback_attention_hours)
      and not exists(select 1 from public.recruitment_activity_events e where e.agency_id=p_agency and e.entity_type='application' and e.entity_id=s.application_id and e.action='client.feedback_received' and e.occurred_at>=s.client_submitted_at)
    order by s.client_submitted_at limit 300
  loop
    v_alert:=private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'CLIENT_FEEDBACK_OVERDUE','CLIENT_FEEDBACK_REMINDER',
      case when v_sub.client_submitted_at<now()-make_interval(hours=>v_cfg.client_feedback_risk_hours) then 'URGENT' else 'ATTENTION' end,
      'submission',v_sub.id,v_sub.job_id,v_sub.application_id,v_sub.candidate_id,v_sub.assigned_am_user_id,'ACCOUNT_MANAGER',
      jsonb_build_array('CLIENT_FEEDBACK_DELAY'),coalesce(v_sub.full_name,'Candidate')||' client feedback is overdue',
      'Follow up with the client and record feedback.',v_sub.client_submitted_at+make_interval(hours=>v_cfg.client_feedback_attention_hours),
      md5(v_sub.id::text||'|CLIENT|'||v_sub.client_submitted_at::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );
    perform private.xzrecruiter_step8_ensure_task(
      p_agency,'step8:client:'||v_sub.id::text,'Follow up for client feedback','Client feedback is overdue for a submitted candidate.',
      'HIGH',v_sub.client_submitted_at+make_interval(hours=>v_cfg.client_feedback_attention_hours),
      v_sub.assigned_am_user_id,v_sub.job_id,v_sub.application_id,v_sub.candidate_id,'CLIENT_FEEDBACK'
    );
    v_detected:=v_detected+1;v_tasks:=v_tasks+1;
  end loop;

  for v_interview in
    select i.id,i.application_id,i.scheduled_at,a.job_id,a.candidate_id,a.owner_user_id,c.full_name
    from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=p_agency
    join public.candidates c on c.id=a.candidate_id and c.agency_id=p_agency
    where i.agency_id=p_agency and upper(coalesce(i.status,'SCHEDULED'))='SCHEDULED'
      and i.scheduled_at between now() and now()+make_interval(hours=>v_cfg.interview_reminder_hours)
    order by i.scheduled_at limit 300
  loop
    perform private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'INTERVIEW_UPCOMING','INTERVIEW_REMINDER','INFO','interview',v_interview.id,
      v_interview.job_id,v_interview.application_id,v_interview.candidate_id,v_interview.owner_user_id,'RECRUITER',
      jsonb_build_array('INTERVIEW_UPCOMING'),coalesce(v_interview.full_name,'Candidate')||' interview is upcoming',
      'Confirm interview readiness and required follow-up.',v_interview.scheduled_at,
      md5(v_interview.id::text||'|'||v_interview.scheduled_at::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );v_detected:=v_detected+1;
  end loop;

  for v_doc in
    select d.id,d.candidate_id,d.expires_at,c.owner_user_id,c.full_name
    from public.candidate_documents d join public.candidates c on c.id=d.candidate_id and c.agency_id=p_agency
    where d.agency_id=p_agency and d.archived_at is null and d.expires_at is not null and d.expires_at<=now()+interval '7 days'
    order by d.expires_at limit 300
  loop
    perform private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'DOCUMENT_EXPIRY','DOCUMENT_EXPIRY',
      case when v_doc.expires_at<=now()+interval '1 day' then 'URGENT' else 'ATTENTION' end,
      'candidate_document',v_doc.id,null,null,v_doc.candidate_id,v_doc.owner_user_id,'RECRUITER',
      jsonb_build_array('DOCUMENT_EXPIRY'),coalesce(v_doc.full_name,'Candidate')||' document is expiring',
      'Review or renew the expiring document through the authorized document workflow.',v_doc.expires_at,
      md5(v_doc.id::text||'|'||v_doc.expires_at::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );v_detected:=v_detected+1;
  end loop;

  for v_offer in
    select o.id,o.application_id,o.sent_at,o.expires_at,a.job_id,a.candidate_id,a.owner_user_id,c.full_name
    from public.offers o join public.applications a on a.id=o.application_id and a.agency_id=p_agency
    join public.candidates c on c.id=a.candidate_id and c.agency_id=p_agency
    where o.agency_id=p_agency and o.sent_at is not null and o.accepted_at is null and o.declined_at is null and o.withdrawn_at is null
      and o.sent_at<now()-make_interval(hours=>v_cfg.offer_action_hours)
    order by o.sent_at limit 300
  loop
    perform private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'OFFER_ACTION_OVERDUE','OFFER_ACTION','ATTENTION','offer',v_offer.id,
      v_offer.job_id,v_offer.application_id,v_offer.candidate_id,v_offer.owner_user_id,'RECRUITMENT_MANAGER',
      jsonb_build_array('OFFER_ACTION_OVERDUE'),coalesce(v_offer.full_name,'Candidate')||' offer needs follow-up',
      'Confirm offer response and next action.',coalesce(v_offer.expires_at,v_offer.sent_at+make_interval(hours=>v_cfg.offer_action_hours)),
      md5(v_offer.id::text||'|'||v_offer.sent_at::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );v_detected:=v_detected+1;
  end loop;

  for v_place in
    select p.id,p.application_id,p.candidate_id,p.job_id,p.recruiter_user_id,p.start_date,c.full_name
    from public.placements p left join public.candidates c on c.id=p.candidate_id and c.agency_id=p_agency
    where p.agency_id=p_agency and p.status in ('PLANNED','CONFIRMED')
      and p.start_date<=v_day+v_cfg.joining_action_days
    order by p.start_date limit 300
  loop
    perform private.xzrecruiter_step8_upsert_alert(
      p_agency,v_run,'JOINING_ACTION','JOINING_ACTION',
      case when v_place.start_date<v_day then 'URGENT' else 'INFO' end,'placement',v_place.id,
      v_place.job_id,v_place.application_id,v_place.candidate_id,v_place.recruiter_user_id,'RECRUITMENT_MANAGER',
      jsonb_build_array('JOINING_UPCOMING'),coalesce(v_place.full_name,'Candidate')||' joining requires confirmation',
      'Confirm joining/start status and record the outcome.',v_place.start_date::timestamp at time zone v_tz,
      md5(v_place.id::text||'|'||v_place.start_date::text),'{}'::jsonb,v_cfg.alert_cooldown_minutes
    );v_detected:=v_detected+1;
  end loop;

  -- Resolve alerts not reproduced by this full-tenant run and emit exactly one immutable RESOLVED event per row.
  with resolved as (
    update public.automation_alerts a set lifecycle='RESOLVED',resolved_at=now(),resolution_reason='UNDERLYING_CONDITION_CLEARED'
    where a.agency_id=p_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED','DISMISSED')
      and a.last_detected_run_id is distinct from v_run
      and not private.xzrecruiter_step8_alert_condition_holds(p_agency,a.id)
    returning a.id
  ), logged as (
    insert into public.automation_alert_events(agency_id,alert_id,event_type,metadata)
    select p_agency,r.id,'RESOLVED',jsonb_build_object('run_id',v_run,'reason','UNDERLYING_CONDITION_CLEARED')
    from resolved r
    returning alert_id
  )
  select count(*)::integer into v_resolved from logged;

  update public.crm_tasks t set status='DONE',completed_at=coalesce(completed_at,now()),updated_at=now()
  where t.agency_id=p_agency and t.automation_key is not null and t.status in ('OPEN','IN_PROGRESS')
    and not exists(
      select 1 from public.automation_alerts a
      where a.agency_id=p_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED')
        and t.automation_key in ('step8:am:'||a.entity_id::text,'step8:client:'||a.entity_id::text)
    );

  update public.automation_runs set run_status='SUCCEEDED',completed_at=now(),detected_count=v_detected,
    created_count=(select count(*) from public.automation_alerts where agency_id=p_agency and first_detected_at>=started_at and last_detected_run_id=v_run),
    resolved_count=coalesce(v_resolved,0),task_count=v_tasks,
    metrics=jsonb_build_object('timezone',v_tz,'businessDate',v_day,'cutoff',v_cutoff)
  where id=v_run;

  return jsonb_build_object('ok',true,'run_id',v_run,'detected',v_detected,'resolved',coalesce(v_resolved,0),'tasks',v_tasks);
exception when others then
  if v_run is not null then update public.automation_runs set run_status='FAILED',completed_at=now(),error_code=sqlstate,error_summary=left(sqlerrm,500) where id=v_run; end if;
  raise;
end;
$$;
revoke all on function private.xzrecruiter_step8_run_agency(uuid,text,text) from public,anon,authenticated;

create or replace function public.xzrecruiter_run_step8_all_tenants(p_worker text default null)
returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_results jsonb:='[]'::jsonb;
begin
  for v_agency in select a.id from public.agencies a order by a.created_at loop
    begin
      v_results:=v_results||jsonb_build_array(private.xzrecruiter_step8_run_agency(v_agency,'SCHEDULED',p_worker));
    exception when others then
      v_results:=v_results||jsonb_build_array(jsonb_build_object('ok',false,'agency_id',v_agency,'error','tenant_run_failed'));
    end;
  end loop;
  return jsonb_build_object('ok',true,'tenants',v_results);
end;
$$;
revoke all on function public.xzrecruiter_run_step8_all_tenants(text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_run_step8_all_tenants(text) to service_role;

create or replace function public.xzrecruiter_run_step8_pending_events(
  p_worker text default null,p_tenant_limit integer default 25
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $events$
declare v_row record;v_result jsonb;v_results jsonb:='[]'::jsonb;v_processed integer:=0;v_failed integer:=0;
begin
  for v_row in
    select e.agency_id,min(e.created_at) first_event
    from public.automation_domain_events e
    where e.event_status='PENDING'
    group by e.agency_id
    order by min(e.created_at)
    limit greatest(1,least(coalesce(p_tenant_limit,25),100))
  loop
    if not pg_try_advisory_xact_lock(hashtext('xzr-step8-event-'||v_row.agency_id::text)) then
      continue;
    end if;
    update public.automation_domain_events
    set event_status='PROCESSING',attempt_count=least(attempt_count+1,20),last_error=null
    where agency_id=v_row.agency_id and event_status='PENDING';
    begin
      v_result:=private.xzrecruiter_step8_run_agency(v_row.agency_id,'EVENT',left(coalesce(p_worker,'event-worker'),200));
      update public.automation_domain_events
      set event_status='PROCESSED',processed_at=now(),last_error=null
      where agency_id=v_row.agency_id and event_status='PROCESSING';
      v_processed:=v_processed+1;
      v_results:=v_results||jsonb_build_array(jsonb_build_object('agency_id',v_row.agency_id,'ok',true,'result',v_result));
    exception when others then
      update public.automation_domain_events
      set event_status=case when attempt_count>=5 then 'FAILED' else 'PENDING' end,
          last_error=left(sqlstate||':'||sqlerrm,500)
      where agency_id=v_row.agency_id and event_status='PROCESSING';
      v_failed:=v_failed+1;
      v_results:=v_results||jsonb_build_array(jsonb_build_object('agency_id',v_row.agency_id,'ok',false,'error','tenant_event_run_failed'));
    end;
  end loop;
  return jsonb_build_object('ok',true,'processedTenants',v_processed,'failedTenants',v_failed,'tenants',v_results);
end;
$events$;
revoke all on function public.xzrecruiter_run_step8_pending_events(text,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_run_step8_pending_events(text,integer) to service_role;


create or replace function public.xzrecruiter_run_step8_manual(p_token text)
returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  if not private.xzrecruiter_has_permission(v_role,'manager:control') then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'automation.manual_run_denied','HIGH','automation',null);
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  return private.xzrecruiter_step8_run_agency(v_agency,'MANUAL',v_user::text);
end;
$$;
revoke all on function public.xzrecruiter_run_step8_manual(text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_run_step8_manual(text) to anon,authenticated;

create or replace function public.xzrecruiter_step8_notification_center(p_token text,p_limit integer default 50)
returns jsonb
language plpgsql stable security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.severity_rank desc,x.last_detected_at desc),'[]'::jsonb) into v_rows
  from (
    select a.id,a.rule_code,a.category,a.severity,a.lifecycle,a.entity_type,a.entity_id,a.job_id,a.application_id,a.candidate_id,
      a.reason_codes,a.reason_summary,a.recommended_action,a.due_at,a.first_detected_at,a.last_detected_at,a.occurrence_count,a.metadata,
      case a.severity when 'URGENT' then 3 when 'ATTENTION' then 2 else 1 end severity_rank
    from public.automation_alerts a
    where a.agency_id=v_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED')
      and (
        private.xzrecruiter_has_permission(v_role,'manager:view')
        or a.owner_user_id=v_user
        or (v_role='ACCOUNT_MANAGER' and a.target_role='ACCOUNT_MANAGER' and (a.owner_user_id is null or a.owner_user_id=v_user))
      )
    order by case a.severity when 'URGENT' then 3 when 'ATTENTION' then 2 else 1 end desc,a.last_detected_at desc
    limit greatest(1,least(coalesce(p_limit,50),100))
  ) x;
  return jsonb_build_object('ok',true,'role',v_role,'notifications',v_rows);
end;
$$;
revoke all on function public.xzrecruiter_step8_notification_center(text,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_notification_center(text,integer) to anon,authenticated;

create or replace function public.xzrecruiter_step8_alert_action(p_token text,p_alert_id uuid,p_action text)
returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;v_alert public.automation_alerts%rowtype;v_action text:=upper(coalesce(p_action,''));
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  select * into v_alert from public.automation_alerts where id=p_alert_id and agency_id=v_agency for update;
  if v_alert.id is null then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'automation.alert_access_denied','HIGH','automation_alert',p_alert_id);
    return jsonb_build_object('ok',false,'error','not_found');
  end if;
  if not (
    private.xzrecruiter_has_permission(v_role,'manager:view') or v_alert.owner_user_id=v_user or
    (v_role='ACCOUNT_MANAGER' and v_alert.target_role='ACCOUNT_MANAGER' and (v_alert.owner_user_id is null or v_alert.owner_user_id=v_user))
  ) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_action='ACKNOWLEDGE' then
    if v_alert.lifecycle='RESOLVED' then return jsonb_build_object('ok',false,'error','already_resolved'); end if;
    update public.automation_alerts set lifecycle='ACKNOWLEDGED',acknowledged_by_user_id=v_user,acknowledged_at=now() where id=p_alert_id;
    insert into public.automation_alert_events(agency_id,alert_id,event_type,actor_user_id) values(v_agency,p_alert_id,'ACKNOWLEDGED',v_user);
  elsif v_action='DISMISS' then
    update public.automation_alerts set lifecycle='DISMISSED',dismissed_by_user_id=v_user,dismissed_at=now() where id=p_alert_id;
    insert into public.automation_alert_events(agency_id,alert_id,event_type,actor_user_id) values(v_agency,p_alert_id,'DISMISSED',v_user);
  else return jsonb_build_object('ok',false,'error','invalid_action'); end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'automation_alert',p_alert_id,'automation.'||lower(v_action),'Automation alert '||lower(v_action),jsonb_build_object('rule_code',v_alert.rule_code));
  return jsonb_build_object('ok',true,'lifecycle',case when v_action='ACKNOWLEDGE' then 'ACKNOWLEDGED' else 'DISMISSED' end);
end;
$$;
revoke all on function public.xzrecruiter_step8_alert_action(text,uuid,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_alert_action(text,uuid,text) to anon,authenticated;

create or replace function public.xzrecruiter_step8_manager_control_center(p_token text,p_limit integer default 50)
returns jsonb
language plpgsql stable security definer
set search_path='public','private','pg_temp'
as $$
declare
  v_agency uuid;v_user uuid;v_membership text;v_role text;v_tz text;v_day date;v_start timestamptz;v_end timestamptz;
  v_today jsonb;v_requirements jsonb;v_recruiters jsonb;v_exceptions jsonb;v_am jsonb;v_interviews jsonb;v_offers jsonb;v_joinings jsonb;v_filters jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  if not private.xzrecruiter_has_permission(v_role,'manager:view') then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'manager.dashboard_denied','HIGH','manager',null);
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  v_tz:=private.xzrecruiter_step8_timezone(v_agency);v_day:=(timezone(v_tz,now()))::date;
  v_start:=v_day::timestamp at time zone v_tz;v_end:=(v_day+1)::timestamp at time zone v_tz;

  select jsonb_build_object(
    'activeRequirements',(select count(*) from public.recruitment_jobs j where j.agency_id=v_agency and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'),
    'plannedSubmissions',(select coalesce(sum(j.submission_target_daily),0) from public.recruitment_jobs j where j.agency_id=v_agency and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'),
    'validSubmissions',(select count(distinct s.application_id)
      from public.candidate_submissions s
      join public.applications ap on ap.id=s.application_id and ap.agency_id=v_agency
      join public.recruitment_jobs j on j.id=s.job_id and j.agency_id=v_agency
      where s.agency_id=v_agency and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
        and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN'
        and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'
        and s.invalidated_at is null and s.withdrawn_at is null
        and upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED')
        and s.client_submitted_at>=v_start and s.client_submitted_at<v_end),
    'requirementsAtRisk',(select count(*)
      from public.requirement_health_current h
      join public.recruitment_jobs j on j.id=h.job_id and j.agency_id=v_agency
      where h.agency_id=v_agency and h.health_status in ('AT_RISK','BLOCKED')
        and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN'
        and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'),
    'recruitersBelowTarget',(select count(*) from (
      select a.recruiter_user_id,coalesce(sum(a.daily_submission_target),0) planned,
        count(distinct s.application_id) completed
      from public.requirement_recruiter_assignments a
      join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
        and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN'
        and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'
      left join public.candidate_submissions s on s.agency_id=a.agency_id and s.job_id=a.job_id
        and s.created_by_user_id=a.recruiter_user_id and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
        and s.invalidated_at is null and s.withdrawn_at is null
        and s.client_submitted_at>=v_start and s.client_submitted_at<v_end
        and exists(select 1 from public.applications ap where ap.agency_id=v_agency and ap.id=s.application_id and upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED'))
      where a.agency_id=v_agency and a.assignment_status='ACTIVE'
      group by a.recruiter_user_id
      having coalesce(sum(a.daily_submission_target),0)>0 and count(distinct s.application_id)<coalesce(sum(a.daily_submission_target),0)
    ) x),
    'overdueRecruiterActions',(select count(*) from public.crm_tasks t where t.agency_id=v_agency and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS') and t.due_at<now()),
    'amReviewsPending',(select count(*) from public.candidate_submissions s where s.agency_id=v_agency and s.workflow_status='INTERNAL_SUBMITTED' and s.invalidated_at is null and s.withdrawn_at is null),
    'clientFeedbackPending',(select count(*) from public.automation_alerts a where a.agency_id=v_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED') and a.category='CLIENT_FEEDBACK_REMINDER'),
    'interviewsToday',(select count(*) from public.interviews i where i.agency_id=v_agency and i.scheduled_at>=v_start and i.scheduled_at<v_end and upper(coalesce(i.status,'SCHEDULED'))='SCHEDULED'),
    'offersRequiringAction',(select count(*) from public.automation_alerts a where a.agency_id=v_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED') and a.category='OFFER_ACTION'),
    'joiningsRequiringAction',(select count(*) from public.automation_alerts a where a.agency_id=v_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED') and a.category='JOINING_ACTION')
  ) into v_today;
  v_today:=v_today||jsonb_build_object('remainingSubmissionGap',greatest((v_today->>'plannedSubmissions')::integer-(v_today->>'validSubmissions')::integer,0));

  select coalesce(jsonb_agg(to_jsonb(x) order by x.health_rank desc,x.remaining_target desc,x.target_fill_date nulls last),'[]'::jsonb) into v_requirements
  from (
    select j.id,j.title,j.client_id,c.name client_name,j.priority,j.target_fill_date,j.submission_target_daily,j.submission_target_total,
      coalesce(h.health_status,'HEALTHY') health_status,coalesce(h.reason_codes,'[]'::jsonb) reason_codes,coalesce(h.next_actions,'[]'::jsonb) next_actions,
      coalesce((h.facts->>'validSubmissionsToday')::integer,0) valid_submissions_today,
      greatest(j.submission_target_daily-coalesce((h.facts->>'validSubmissionsToday')::integer,0),0) remaining_target,
      coalesce((h.facts->>'pipelineCount')::integer,0) pipeline_count,
      case coalesce(h.health_status,'HEALTHY') when 'BLOCKED' then 5 when 'AT_RISK' then 4 when 'NEEDS_ATTENTION' then 3 when 'ON_HOLD' then 2 else 1 end health_rank
    from public.recruitment_jobs j
    left join public.recruitment_clients c on c.id=j.client_id and c.agency_id=v_agency
    left join public.requirement_health_current h on h.agency_id=v_agency and h.job_id=j.id
    where j.agency_id=v_agency and j.archived_at is null
      and j.recruiter_ready=true and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null
      and upper(coalesce(j.status,'OPEN'))='OPEN'
    limit greatest(1,least(coalesce(p_limit,50),100))
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.remaining_target desc,x.overdue_followups desc),'[]'::jsonb) into v_recruiters
  from (
    select u.id user_id,coalesce(u.display_name,u.email) recruiter,
      count(distinct a.job_id) active_requirements,coalesce(sum(a.daily_submission_target),0)::integer daily_target,
      count(distinct s.application_id)::integer valid_submissions,
      greatest(coalesce(sum(a.daily_submission_target),0)-count(distinct s.application_id),0)::integer remaining_target,
      (select count(*) from public.application_screening_sessions ss where ss.agency_id=v_agency and ss.started_by_user_id=u.id and ss.completed_at>=v_start and ss.completed_at<v_end)::integer screenings_completed,
      (select count(*) from public.application_screening_sessions ss where ss.agency_id=v_agency and ss.started_by_user_id=u.id and ss.status='QUALIFIED' and ss.completed_at>=v_start and ss.completed_at<v_end)::integer qualified_candidates,
      (select count(*) from public.crm_tasks t where t.agency_id=v_agency and t.assigned_user_id=u.id and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS') and t.due_at<now())::integer overdue_followups,
      (select count(*) from public.applications ap where ap.agency_id=v_agency and ap.owner_user_id=u.id and ap.archived_at is null and upper(coalesce(ap.status,'ACTIVE'))='ACTIVE')::integer candidate_pipeline,
      (select count(*) from public.candidate_submissions cs
        join public.applications cap on cap.id=cs.application_id and cap.agency_id=v_agency
        where cs.agency_id=v_agency and cs.created_by_user_id=u.id
          and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
          and cs.invalidated_at is null and cs.withdrawn_at is null
          and upper(coalesce(cap.stage,'')) not in ('WITHDRAWN','REJECTED'))::integer client_submissions_total,
      (select count(*) from public.interviews i join public.applications ap on ap.id=i.application_id and ap.agency_id=v_agency where i.agency_id=v_agency and ap.owner_user_id=u.id)::integer interviews_total
    from public.requirement_recruiter_assignments a
    join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
      and j.archived_at is null and j.recruiter_ready=true and j.requirement_state='OPEN'
      and j.approved_hiring_brief_id is not null and upper(coalesce(j.status,'OPEN'))='OPEN'
    join public.users u on u.id=a.recruiter_user_id
    left join public.candidate_submissions s on s.agency_id=a.agency_id and s.job_id=a.job_id and s.created_by_user_id=a.recruiter_user_id
      and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED' and s.invalidated_at is null and s.withdrawn_at is null
      and s.client_submitted_at>=v_start and s.client_submitted_at<v_end
      and exists(select 1 from public.applications vp where vp.agency_id=v_agency and vp.id=s.application_id and upper(coalesce(vp.stage,'')) not in ('WITHDRAWN','REJECTED'))
    where a.agency_id=v_agency and a.assignment_status='ACTIVE'
    group by u.id,u.display_name,u.email
    limit 100
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.severity_rank desc,x.last_detected_at desc),'[]'::jsonb) into v_exceptions
  from (
    select a.id,a.rule_code,a.category,a.severity,a.lifecycle,a.entity_type,a.entity_id,a.job_id,a.application_id,a.candidate_id,
      a.owner_user_id,coalesce(u.display_name,u.email) owner,a.reason_summary,a.recommended_action,a.reason_codes,a.due_at,a.first_detected_at,a.last_detected_at,
      extract(epoch from(now()-a.first_detected_at))/3600.0 age_hours,
      case a.severity when 'URGENT' then 3 when 'ATTENTION' then 2 else 1 end severity_rank
    from public.automation_alerts a left join public.users u on u.id=a.owner_user_id
    where a.agency_id=v_agency and a.lifecycle in ('OPEN','ACKNOWLEDGED')
    order by case a.severity when 'URGENT' then 3 when 'ATTENTION' then 2 else 1 end desc,a.last_detected_at desc
    limit greatest(1,least(coalesce(p_limit,50),100))
  ) x;

  select jsonb_build_object(
    'waitingReview',(select count(*) from public.candidate_submissions where agency_id=v_agency and workflow_status='INTERNAL_SUBMITTED' and invalidated_at is null and withdrawn_at is null),
    'returned',(select count(*) from public.candidate_submissions where agency_id=v_agency and workflow_status='RETURNED_TO_RECRUITER'),
    'approved',(select count(*) from public.candidate_submissions where agency_id=v_agency and workflow_status='AM_APPROVED'),
    'clientFeedbackPending',(select count(*) from public.automation_alerts where agency_id=v_agency and lifecycle in ('OPEN','ACKNOWLEDGED') and category='CLIENT_FEEDBACK_REMINDER')
  ) into v_am;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at),'[]'::jsonb) into v_interviews from (
    select i.id,i.application_id,i.scheduled_at,i.timezone,i.status,c.full_name candidate_name,j.title job_title
    from public.interviews i join public.applications ap on ap.id=i.application_id and ap.agency_id=v_agency
    join public.candidates c on c.id=ap.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=ap.job_id and j.agency_id=v_agency
    where i.agency_id=v_agency and i.scheduled_at between now()-interval '4 hours' and now()+interval '7 days'
    order by i.scheduled_at limit 50
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sent_at),'[]'::jsonb) into v_offers from (
    select o.id,o.application_id,o.status,o.sent_at,o.expires_at,c.full_name candidate_name,j.title job_title
    from public.offers o join public.applications ap on ap.id=o.application_id and ap.agency_id=v_agency
    join public.candidates c on c.id=ap.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=ap.job_id and j.agency_id=v_agency
    where o.agency_id=v_agency and o.sent_at is not null and o.accepted_at is null and o.declined_at is null and o.withdrawn_at is null
    order by o.sent_at limit 50
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.start_date),'[]'::jsonb) into v_joinings from (
    select p.id,p.application_id,p.status,p.start_date,c.full_name candidate_name,j.title job_title
    from public.placements p left join public.candidates c on c.id=p.candidate_id and c.agency_id=v_agency
    left join public.recruitment_jobs j on j.id=p.job_id and j.agency_id=v_agency
    where p.agency_id=v_agency and p.status in ('PLANNED','CONFIRMED') and p.start_date between v_day and v_day+30
    order by p.start_date limit 50
  ) x;

  select jsonb_build_object(
    'clients',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'name',x.name) order by x.name) from (
      select c.id,c.name from public.recruitment_clients c where c.agency_id=v_agency and c.archived_at is null order by c.name limit 100
    ) x),'[]'::jsonb),
    'requirements',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'title',x.title) order by x.title) from (
      select j.id,j.title from public.recruitment_jobs j where j.agency_id=v_agency and j.archived_at is null order by j.title limit 150
    ) x),'[]'::jsonb),
    'recruiters',coalesce((select jsonb_agg(jsonb_build_object('id',x.user_id,'name',x.name) order by x.name) from (
      select m.user_id,coalesce(u.display_name,u.email) name
      from public.agency_memberships m join public.users u on u.id=m.user_id
      where m.agency_id=v_agency and private.xzrecruiter_business_role(m.agency_id,m.user_id,m.role) in ('RECRUITER','RECRUITMENT_MANAGER')
      order by coalesce(u.display_name,u.email) limit 100
    ) x),'[]'::jsonb),
    'accountManagers',coalesce((select jsonb_agg(jsonb_build_object('id',x.user_id,'name',x.name) order by x.name) from (
      select m.user_id,coalesce(u.display_name,u.email) name
      from public.agency_memberships m join public.users u on u.id=m.user_id
      where m.agency_id=v_agency and private.xzrecruiter_business_role(m.agency_id,m.user_id,m.role)='ACCOUNT_MANAGER'
      order by coalesce(u.display_name,u.email) limit 100
    ) x),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(x.source order by x.source) from (
      select distinct upper(coalesce(a.source_type,a.metadata->>'source','UNKNOWN')) source
      from public.applications a where a.agency_id=v_agency and a.archived_at is null
      order by 1 limit 50
    ) x),'[]'::jsonb)
  ) into v_filters;

  return jsonb_build_object('ok',true,'role',v_role,'timezone',v_tz,'businessDate',v_day,'today',v_today,
    'requirements',v_requirements,'recruiters',v_recruiters,'exceptions',v_exceptions,'amControl',v_am,
    'interviews',v_interviews,'offers',v_offers,'joinings',v_joinings,'filterOptions',v_filters,'refreshedAt',now());
end;
$$;
revoke all on function public.xzrecruiter_step8_manager_control_center(text,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_manager_control_center(text,integer) to anon,authenticated;

create or replace function public.xzrecruiter_step8_requirement_control(p_token text,p_job_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;v_job jsonb;v_assign jsonb;v_pipeline jsonb;v_alerts jsonb;v_activity jsonb;v_health jsonb;v_members jsonb;v_tz text;v_day date;v_start timestamptz;v_end timestamptz;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  if not private.xzrecruiter_has_permission(v_role,'manager:view') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_tz:=private.xzrecruiter_step8_timezone(v_agency);v_day:=(timezone(v_tz,now()))::date;
  v_start:=v_day::timestamp at time zone v_tz;v_end:=(v_day+1)::timestamp at time zone v_tz;
  if not exists(select 1 from public.recruitment_jobs where id=p_job_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  select jsonb_build_object('id',j.id,'title',j.title,'clientId',j.client_id,'client',c.name,'priority',j.priority,'deadline',j.target_fill_date,
    'status',j.status,'dailyTarget',j.submission_target_daily,'totalTarget',j.submission_target_total) into v_job
  from public.recruitment_jobs j left join public.recruitment_clients c on c.id=j.client_id and c.agency_id=v_agency
  where j.id=p_job_id and j.agency_id=v_agency;

  select to_jsonb(h) into v_health from public.requirement_health_current h where h.agency_id=v_agency and h.job_id=p_job_id;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.recruiter),'[]'::jsonb) into v_assign from (
    select a.id,a.recruiter_user_id,coalesce(u.display_name,u.email) recruiter,a.daily_submission_target,a.total_submission_target,a.manager_priority,
      a.priority_context,a.manager_instructions,a.blocker_reason,a.assigned_at,
      (select count(distinct s.application_id) from public.candidate_submissions s
        where s.agency_id=v_agency and s.job_id=p_job_id and s.created_by_user_id=a.recruiter_user_id
          and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
          and s.invalidated_at is null and s.withdrawn_at is null
          and s.client_submitted_at>=v_start and s.client_submitted_at<v_end) submissions_today,
      greatest(a.daily_submission_target-(select count(distinct s.application_id) from public.candidate_submissions s
        where s.agency_id=v_agency and s.job_id=p_job_id and s.created_by_user_id=a.recruiter_user_id
          and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
          and s.invalidated_at is null and s.withdrawn_at is null
          and s.client_submitted_at>=v_start and s.client_submitted_at<v_end),0) remaining_target,
      case when a.daily_submission_target=0 then 0 else least(100,round(100.0*(select count(distinct s.application_id) from public.candidate_submissions s
        where s.agency_id=v_agency and s.job_id=p_job_id and s.created_by_user_id=a.recruiter_user_id
          and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
          and s.invalidated_at is null and s.withdrawn_at is null
          and s.client_submitted_at>=v_start and s.client_submitted_at<v_end)/a.daily_submission_target,1)) end achievement_percent,
      (select count(*) from public.applications ap where ap.agency_id=v_agency and ap.job_id=p_job_id and ap.owner_user_id=a.recruiter_user_id and ap.archived_at is null and upper(coalesce(ap.status,'ACTIVE'))='ACTIVE') pipeline,
      (select count(*) from public.crm_tasks t where t.agency_id=v_agency and t.job_id=p_job_id and t.assigned_user_id=a.recruiter_user_id and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS') and t.due_at<now()) due_actions
    from public.requirement_recruiter_assignments a join public.users u on u.id=a.recruiter_user_id
    where a.agency_id=v_agency and a.job_id=p_job_id and a.assignment_status='ACTIVE'
  ) x;

  select jsonb_build_object(
    'sourced',(select count(*) from public.applications a where a.agency_id=v_agency and a.job_id=p_job_id and a.archived_at is null),
    'screening',(select count(*) from public.application_screening_sessions s where s.agency_id=v_agency and s.job_id=p_job_id and s.status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED')),
    'qualified',(select count(*) from public.application_screening_sessions s where s.agency_id=v_agency and s.job_id=p_job_id and s.status='QUALIFIED'),
    'internalSubmitted',(select count(*) from public.candidate_submissions s where s.agency_id=v_agency and s.job_id=p_job_id and s.workflow_status in ('INTERNAL_SUBMITTED','AM_APPROVED','CLIENT_SUBMITTED') and s.invalidated_at is null and s.withdrawn_at is null),
    'amApproved',(select count(*) from public.candidate_submissions s where s.agency_id=v_agency and s.job_id=p_job_id and s.workflow_status in ('AM_APPROVED','CLIENT_SUBMITTED') and s.invalidated_at is null and s.withdrawn_at is null),
    'clientSubmitted',(select count(*) from public.candidate_submissions s join public.applications ap on ap.id=s.application_id and ap.agency_id=v_agency where s.agency_id=v_agency and s.job_id=p_job_id and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED' and s.invalidated_at is null and s.withdrawn_at is null and upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED')),
    'interviews',(select count(*) from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=v_agency where i.agency_id=v_agency and a.job_id=p_job_id),
    'offers',(select count(*) from public.offers o join public.applications a on a.id=o.application_id and a.agency_id=v_agency where o.agency_id=v_agency and a.job_id=p_job_id),
    'joinings',(select count(*) from public.placements p where p.agency_id=v_agency and p.job_id=p_job_id and p.status in ('STARTED','COMPLETED'))
  ) into v_pipeline;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.severity_rank desc,x.last_detected_at desc),'[]'::jsonb) into v_alerts from (
    select a.id,a.rule_code,a.category,a.severity,a.lifecycle,a.owner_user_id,coalesce(u.display_name,u.email) owner,a.reason_summary,a.recommended_action,a.reason_codes,a.due_at,a.first_detected_at,a.last_detected_at,
      case a.severity when 'URGENT' then 3 when 'ATTENTION' then 2 else 1 end severity_rank
    from public.automation_alerts a left join public.users u on u.id=a.owner_user_id
    where a.agency_id=v_agency and a.job_id=p_job_id and a.lifecycle in ('OPEN','ACKNOWLEDGED')
    limit 100
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
    'userId',m.user_id,'name',coalesce(u.display_name,u.email),
    'role',private.xzrecruiter_business_role(m.agency_id,m.user_id,m.role)
  ) order by coalesce(u.display_name,u.email)),'[]'::jsonb) into v_members
  from public.agency_memberships m join public.users u on u.id=m.user_id
  where m.agency_id=v_agency and private.xzrecruiter_business_role(m.agency_id,m.user_id,m.role) in ('RECRUITER','RECRUITMENT_MANAGER');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into v_activity from (
    select e.action,e.summary,e.actor_user_id,e.occurred_at,e.metadata
    from public.recruitment_activity_events e
    where e.agency_id=v_agency and (
      (e.entity_type='job' and e.entity_id=p_job_id) or
      (e.entity_type='application' and exists(select 1 from public.applications ap where ap.agency_id=v_agency and ap.id=e.entity_id and ap.job_id=p_job_id))
    )
    order by e.occurred_at desc limit 50
  ) x;
  return jsonb_build_object('ok',true,'role',v_role,'timezone',v_tz,'businessDate',v_day,
    'job',v_job,'health',coalesce(v_health,'{}'::jsonb),'assignments',v_assign,'eligibleRecruiters',v_members,
    'pipeline',v_pipeline,'exceptions',v_alerts,'activity',v_activity);
end;
$$;
revoke all on function public.xzrecruiter_step8_requirement_control(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_requirement_control(text,uuid) to anon,authenticated;

create or replace function public.xzrecruiter_step8_analytics(
  p_token text,p_from timestamptz,p_to timestamptz,p_client uuid default null,p_job uuid default null,
  p_recruiter uuid default null,p_account_manager uuid default null,p_source text default null
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;v_from timestamptz;v_to timestamptz;v_funnel jsonb;v_sources jsonb;v_bottleneck text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  if not private.xzrecruiter_has_permission(v_role,'manager:view') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_to:=coalesce(p_to,now());v_from:=coalesce(p_from,v_to-interval '30 days');
  if v_from>=v_to or v_from<v_to-interval '366 days' then return jsonb_build_object('ok',false,'error','invalid_date_range'); end if;

  with cohort as (
    select a.id,a.job_id,a.candidate_id,a.owner_user_id,upper(coalesce(a.source_type,a.metadata->>'source','UNKNOWN')) source
    from public.applications a join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
    where a.agency_id=v_agency and a.archived_at is null and a.created_at>=v_from and a.created_at<v_to
      and (p_client is null or j.client_id=p_client) and (p_job is null or a.job_id=p_job)
      and (p_recruiter is null or a.owner_user_id=p_recruiter)
      and (p_account_manager is null or j.owner_user_id=p_account_manager or exists(
        select 1 from public.candidate_submissions ams
        where ams.agency_id=v_agency and ams.application_id=a.id and ams.assigned_am_user_id=p_account_manager
      ))
      and (p_source is null or upper(coalesce(a.source_type,a.metadata->>'source','UNKNOWN'))=upper(p_source))
  )
  select jsonb_build_object(
    'cohortApplications',(select count(*) from cohort),
    'sourced',(select count(*) from cohort),
    'screened',(select count(distinct c.id) from cohort c join public.application_screening_sessions s on s.agency_id=v_agency and s.application_id=c.id and s.completed_at is not null),
    'qualified',(select count(distinct c.id) from cohort c join public.application_screening_sessions s on s.agency_id=v_agency and s.application_id=c.id and s.status='QUALIFIED'),
    'internallySubmitted',(select count(distinct c.id) from cohort c join public.candidate_submissions s on s.agency_id=v_agency and s.application_id=c.id and s.workflow_status in ('INTERNAL_SUBMITTED','AM_APPROVED','CLIENT_SUBMITTED')),
    'amApproved',(select count(distinct c.id) from cohort c join public.candidate_submissions s on s.agency_id=v_agency and s.application_id=c.id and s.workflow_status in ('AM_APPROVED','CLIENT_SUBMITTED')),
    'clientSubmitted',(select count(distinct c.id) from cohort c join public.candidate_submissions s on s.agency_id=v_agency and s.application_id=c.id and s.workflow_status='CLIENT_SUBMITTED'),
    'interviewed',(select count(distinct c.id) from cohort c join public.interviews i on i.agency_id=v_agency and i.application_id=c.id),
    'offered',(select count(distinct c.id) from cohort c join public.offers o on o.agency_id=v_agency and o.application_id=c.id),
    'joined',(select count(distinct c.id) from cohort c join public.placements p on p.agency_id=v_agency and p.application_id=c.id and p.status in ('STARTED','COMPLETED'))
  ) into v_funnel;

  with cohort as (
    select a.id,upper(coalesce(a.source_type,a.metadata->>'source','UNKNOWN')) source
    from public.applications a join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
    where a.agency_id=v_agency and a.archived_at is null and a.created_at>=v_from and a.created_at<v_to
      and (p_client is null or j.client_id=p_client) and (p_job is null or a.job_id=p_job)
      and (p_recruiter is null or a.owner_user_id=p_recruiter)
      and (p_account_manager is null or j.owner_user_id=p_account_manager or exists(
        select 1 from public.candidate_submissions ams
        where ams.agency_id=v_agency and ams.application_id=a.id and ams.assigned_am_user_id=p_account_manager
      ))
      and (p_source is null or upper(coalesce(a.source_type,a.metadata->>'source','UNKNOWN'))=upper(p_source))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.candidates desc),'[]'::jsonb) into v_sources from (
    select c.source,count(*)::integer candidates,
      count(*) filter(where exists(select 1 from public.application_screening_sessions s where s.agency_id=v_agency and s.application_id=c.id and s.status='QUALIFIED'))::integer qualified,
      count(*) filter(where exists(select 1 from public.candidate_submissions s where s.agency_id=v_agency and s.application_id=c.id and s.workflow_status='CLIENT_SUBMITTED'))::integer client_submissions,
      count(*) filter(where exists(select 1 from public.interviews i where i.agency_id=v_agency and i.application_id=c.id))::integer interviews,
      count(*) filter(where exists(select 1 from public.offers o where o.agency_id=v_agency and o.application_id=c.id))::integer offers,
      count(*) filter(where exists(select 1 from public.placements p where p.agency_id=v_agency and p.application_id=c.id and p.status in ('STARTED','COMPLETED')))::integer joinings
    from cohort c group by c.source
  ) x;

  v_bottleneck:=case
    when (v_funnel->>'sourced')::integer>0 and (v_funnel->>'screened')::numeric/nullif((v_funnel->>'sourced')::numeric,0)<0.35 then 'SCREENING_BOTTLENECK'
    when (v_funnel->>'screened')::integer>0 and (v_funnel->>'qualified')::numeric/nullif((v_funnel->>'screened')::numeric,0)<0.25 then 'QUALITY_BOTTLENECK'
    when (v_funnel->>'qualified')::integer>0 and (v_funnel->>'internallySubmitted')::numeric/nullif((v_funnel->>'qualified')::numeric,0)<0.5 then 'SUBMISSION_BOTTLENECK'
    when (v_funnel->>'internallySubmitted')::integer>0 and (v_funnel->>'amApproved')::numeric/nullif((v_funnel->>'internallySubmitted')::numeric,0)<0.5 then 'AM_BOTTLENECK'
    when (v_funnel->>'clientSubmitted')::integer>0 and (v_funnel->>'interviewed')::numeric/nullif((v_funnel->>'clientSubmitted')::numeric,0)<0.25 then 'CLIENT_OR_INTERVIEW_BOTTLENECK'
    when (v_funnel->>'offered')::integer>0 and (v_funnel->>'joined')::numeric/nullif((v_funnel->>'offered')::numeric,0)<0.5 then 'OFFER_JOINING_BOTTLENECK'
    else 'NO_DOMINANT_BOTTLENECK' end;

  return jsonb_build_object('ok',true,'from',v_from,'to',v_to,'cohortDefinition','APPLICATION_CREATED_IN_WINDOW','funnel',v_funnel,'sources',v_sources,'bottleneck',v_bottleneck);
end;
$$;
revoke all on function public.xzrecruiter_step8_analytics(text,timestamptz,timestamptz,uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_analytics(text,timestamptz,timestamptz,uuid,uuid,uuid,uuid,text) to anon,authenticated;

create or replace function public.xzrecruiter_step8_manager_action(p_token text,p_action text,p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;v_action text:=upper(coalesce(p_action,''));v_job uuid;v_recruiter uuid;v_task uuid;v_priority text;v_status text;
  v_job_status text;v_requirement_state text;v_recruiter_ready boolean;v_approved_brief uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  if not private.xzrecruiter_has_permission(v_role,'manager:control') then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'manager.action_denied','HIGH','manager',null,jsonb_build_object('action',v_action));
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  begin v_job:=nullif(p_payload->>'jobId','')::uuid; exception when others then v_job:=null; end;
  if v_job is null then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
  select status,requirement_state,recruiter_ready,approved_hiring_brief_id
  into v_job_status,v_requirement_state,v_recruiter_ready,v_approved_brief
  from public.recruitment_jobs
  where id=v_job and agency_id=v_agency and archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  if v_action in ('SET_PRIORITY','ASSIGN_RECRUITER','SET_RECRUITER_TARGET','CREATE_MANAGER_TASK','ACKNOWLEDGE_BLOCKER')
     and not (
       coalesce(v_recruiter_ready,false)=true and v_requirement_state='OPEN' and v_approved_brief is not null
       and upper(coalesce(v_job_status,'OPEN')) in ('OPEN','ON_HOLD')
     ) then
    return jsonb_build_object('ok',false,'error','requirement_not_operational');
  end if;

  if v_action='SET_PRIORITY' then
    v_priority:=upper(coalesce(p_payload->>'priority',''));
    if v_priority not in ('LOW','NORMAL','HIGH','URGENT') then return jsonb_build_object('ok',false,'error','invalid_priority'); end if;
    update public.recruitment_jobs set priority=v_priority,updated_at=now() where id=v_job and agency_id=v_agency;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_job,'requirement.priority_changed','Manager changed requirement priority',jsonb_build_object('priority',v_priority));
  elsif v_action='HOLD_REQUIREMENT' then
    if not (
      coalesce(v_recruiter_ready,false)=true and v_requirement_state='OPEN' and v_approved_brief is not null
      and upper(coalesce(v_job_status,'OPEN'))='OPEN'
    ) then return jsonb_build_object('ok',false,'error','invalid_requirement_transition'); end if;
    update public.recruitment_jobs set status='ON_HOLD',updated_at=now() where id=v_job and agency_id=v_agency;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_job,'requirement.held','Manager placed requirement on hold',jsonb_build_object('reason',left(coalesce(p_payload->>'reason',''),1000)));
  elsif v_action='REOPEN_REQUIREMENT' then
    if not (
      coalesce(v_recruiter_ready,false)=true and v_requirement_state='OPEN' and v_approved_brief is not null
      and upper(coalesce(v_job_status,''))='ON_HOLD'
    ) then return jsonb_build_object('ok',false,'error','invalid_requirement_transition'); end if;
    update public.recruitment_jobs set status='OPEN',updated_at=now() where id=v_job and agency_id=v_agency;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_job,'requirement.reopened','Manager reopened requirement','{}'::jsonb);
  elsif v_action='ASSIGN_RECRUITER' then
    begin v_recruiter:=(p_payload->>'recruiterUserId')::uuid; exception when others then return jsonb_build_object('ok',false,'error','invalid_recruiter'); end;
    if not exists(select 1 from public.agency_memberships m where m.agency_id=v_agency and m.user_id=v_recruiter and private.xzrecruiter_business_role(m.agency_id,m.user_id,m.role) in ('RECRUITER','RECRUITMENT_MANAGER')) then return jsonb_build_object('ok',false,'error','invalid_recruiter'); end if;
    if coalesce((p_payload->>'dailyTarget')::integer,0) not between 0 and 1000 or coalesce((p_payload->>'totalTarget')::integer,0) not between 0 and 10000 then
      return jsonb_build_object('ok',false,'error','invalid_target');
    end if;
    v_priority:=upper(coalesce(nullif(p_payload->>'priority',''),'NORMAL'));
    if v_priority not in ('LOW','NORMAL','HIGH','URGENT') then return jsonb_build_object('ok',false,'error','invalid_priority'); end if;
    insert into public.requirement_recruiter_assignments(agency_id,job_id,recruiter_user_id,assignment_status,daily_submission_target,total_submission_target,manager_priority,priority_context,manager_instructions,assigned_by_user_id)
    values(v_agency,v_job,v_recruiter,'ACTIVE',greatest(coalesce((p_payload->>'dailyTarget')::integer,0),0),greatest(coalesce((p_payload->>'totalTarget')::integer,0),0),
      v_priority,nullif(left(p_payload->>'context',500),''),nullif(left(p_payload->>'instructions',2000),''),v_user)
    on conflict(agency_id,job_id,recruiter_user_id) do update set assignment_status='ACTIVE',daily_submission_target=excluded.daily_submission_target,total_submission_target=excluded.total_submission_target,manager_priority=excluded.manager_priority,priority_context=excluded.priority_context,manager_instructions=excluded.manager_instructions,assigned_by_user_id=v_user,updated_at=now();
    perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_job,'requirement.recruiter_assigned','Manager assigned recruiter',jsonb_build_object('recruiter_user_id',v_recruiter));
  elsif v_action='SET_RECRUITER_TARGET' then
    begin v_recruiter:=(p_payload->>'recruiterUserId')::uuid; exception when others then return jsonb_build_object('ok',false,'error','invalid_recruiter'); end;
    if coalesce((p_payload->>'dailyTarget')::integer,0) not between 0 and 1000 or coalesce((p_payload->>'totalTarget')::integer,0) not between 0 and 10000 then
      return jsonb_build_object('ok',false,'error','invalid_target');
    end if;
    update public.requirement_recruiter_assignments set daily_submission_target=coalesce((p_payload->>'dailyTarget')::integer,0),total_submission_target=coalesce((p_payload->>'totalTarget')::integer,0),updated_at=now()
    where agency_id=v_agency and job_id=v_job and recruiter_user_id=v_recruiter and assignment_status='ACTIVE';
    if not found then return jsonb_build_object('ok',false,'error','assignment_not_found'); end if;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_job,'requirement.target_changed','Manager changed recruiter target',jsonb_build_object('recruiter_user_id',v_recruiter,'daily_target',p_payload->>'dailyTarget','total_target',p_payload->>'totalTarget'));
  elsif v_action='CREATE_MANAGER_TASK' then
    if nullif(btrim(coalesce(p_payload->>'idempotencyKey','')),'') is null then
      return jsonb_build_object('ok',false,'error','idempotency_key_required');
    end if;
    begin v_recruiter:=nullif(p_payload->>'assignedUserId','')::uuid; exception when others then v_recruiter:=null; end;
    if v_recruiter is not null and not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_recruiter) then return jsonb_build_object('ok',false,'error','invalid_assignee'); end if;
    insert into public.crm_tasks(agency_id,title,description,status,priority,due_at,assigned_user_id,created_by_user_id,job_id,task_type,automation_key)
    values(v_agency,left(coalesce(p_payload->>'title','Manager action'),500),left(coalesce(p_payload->>'description',''),2000),'OPEN',
      case when upper(coalesce(p_payload->>'priority','NORMAL')) in ('LOW','NORMAL','HIGH','URGENT') then upper(coalesce(p_payload->>'priority','NORMAL')) else 'NORMAL' end,
      nullif(p_payload->>'dueAt','')::timestamptz,v_recruiter,v_user,v_job,'MANAGER_CLARIFICATION',
      'manager:'||left(btrim(p_payload->>'idempotencyKey'),160))
    on conflict(agency_id,automation_key) where automation_key is not null and archived_at is null
    do update set title=excluded.title,description=excluded.description,priority=excluded.priority,due_at=excluded.due_at,
      assigned_user_id=excluded.assigned_user_id,updated_at=now()
    returning id into v_task;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_job,'manager.task_created','Manager created execution task',jsonb_build_object('task_id',v_task,'assigned_user_id',v_recruiter));
    return jsonb_build_object('ok',true,'taskId',v_task);
  elsif v_action='ACKNOWLEDGE_BLOCKER' then
    begin v_recruiter:=(p_payload->>'recruiterUserId')::uuid; exception when others then return jsonb_build_object('ok',false,'error','invalid_recruiter'); end;
    if not exists(
      select 1 from public.requirement_recruiter_assignments a
      where a.agency_id=v_agency and a.job_id=v_job and a.recruiter_user_id=v_recruiter
        and a.assignment_status='ACTIVE' and a.blocker_reason is not null
    ) then return jsonb_build_object('ok',false,'error','blocker_not_found'); end if;
    perform private.xzrecruiter_log_activity(
      v_agency,v_user,'job',v_job,'requirement.blocker_acknowledged',
      'Manager acknowledged execution blocker',
      jsonb_build_object('recruiter_user_id',v_recruiter,'blocker_preserved',true)
    );
  else return jsonb_build_object('ok',false,'error','unsupported_action'); end if;

  return jsonb_build_object('ok',true,'action',v_action);
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','invalid_payload');
end;
$$;
revoke all on function public.xzrecruiter_step8_manager_action(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_manager_action(text,text,jsonb) to anon,authenticated;

create or replace function public.xzrecruiter_step8_record_client_feedback(
  p_token text,p_application_id uuid,p_feedback text,p_outcome text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_agency uuid;v_user uuid;v_membership text;v_role text;v_job uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership);
  if v_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select job_id into v_job from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null;
  if v_job is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  if not exists(
    select 1 from public.candidate_submissions s
    join public.applications ap on ap.id=s.application_id and ap.agency_id=v_agency
    where s.agency_id=v_agency and s.application_id=p_application_id
      and s.workflow_status='CLIENT_SUBMITTED' and s.status='SUBMITTED'
      and s.invalidated_at is null and s.withdrawn_at is null
      and upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED')
  ) then return jsonb_build_object('ok',false,'error','client_submission_required'); end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',p_application_id,'client.feedback_received','Client feedback recorded',jsonb_build_object('outcome',left(coalesce(p_outcome,''),100),'feedback',left(coalesce(p_feedback,''),1500),'job_id',v_job));
  return jsonb_build_object('ok',true);
end;
$$;
revoke all on function public.xzrecruiter_step8_record_client_feedback(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_step8_record_client_feedback(text,uuid,text,text) to anon,authenticated;


-- DB-native scheduler. Tenant advisory locks make overlapping event/full runs retry-safe.
select cron.schedule(
  'xzrecruiter-step8-events',
  '* * * * *',
  $step8_events$select public.xzrecruiter_run_step8_pending_events('pg-cron',25);$step8_events$
);

select cron.schedule(
  'xzrecruiter-step8-full-reconcile',
  '0 * * * *',
  $step8_full$select public.xzrecruiter_run_step8_all_tenants('pg-cron');$step8_full$
);
