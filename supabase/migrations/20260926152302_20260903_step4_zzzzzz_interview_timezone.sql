-- Step 4 closeout: convert wall-clock interview time in the selected IANA timezone on the server.
create or replace function public.xzrecruiter_schedule_interview(p_token text,p_interview jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
 v_agency uuid;v_user uuid;v_role text;v_id uuid;v_app uuid;v_start timestamptz;v_end timestamptz;v_tz text;v_candidate_tz text;v_recruiter_tz text;
 v_local timestamp;v_duration integer;v_roundtrip timestamp;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 v_app:=nullif(p_interview->>'applicationId','')::uuid;
 if not exists(select 1 from public.applications where id=v_app and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
 v_tz:=coalesce(nullif(p_interview->>'timezone',''),'UTC');
 if not public.xzrecruiter_valid_timezone(v_tz) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
 v_candidate_tz:=nullif(p_interview->>'candidateTimezone','');v_recruiter_tz:=nullif(p_interview->>'recruiterTimezone','');
 if v_candidate_tz is not null and not public.xzrecruiter_valid_timezone(v_candidate_tz) then return jsonb_build_object('ok',false,'error','invalid_candidate_timezone'); end if;
 if v_recruiter_tz is not null and not public.xzrecruiter_valid_timezone(v_recruiter_tz) then return jsonb_build_object('ok',false,'error','invalid_recruiter_timezone'); end if;
 if nullif(p_interview->>'scheduledLocal','') is not null then
   v_local:=(p_interview->>'scheduledLocal')::timestamp;
   v_start:=v_local at time zone v_tz;
   v_roundtrip:=v_start at time zone v_tz;
   if v_roundtrip<>v_local then return jsonb_build_object('ok',false,'error','invalid_local_time_due_to_dst'); end if;
   v_duration:=greatest(15,least(coalesce(nullif(p_interview->>'durationMinutes','')::integer,60),720));
   v_end:=v_start+(v_duration||' minutes')::interval;
 elsif nullif(p_interview->>'scheduledAt','') is not null then
   v_start:=(p_interview->>'scheduledAt')::timestamptz;
   v_end:=coalesce(nullif(p_interview->>'endAt','')::timestamptz,v_start+interval '1 hour');
 else return jsonb_build_object('ok',false,'error','scheduled_time_required'); end if;
 if v_end<=v_start then return jsonb_build_object('ok',false,'error','invalid_time_range'); end if;
 if exists(select 1 from public.interviews i where i.agency_id=v_agency and i.application_id=v_app and i.status in ('SCHEDULED','RESCHEDULED') and tstzrange(i.scheduled_at,coalesce(i.end_at,i.scheduled_at+interval '1 hour'),'[)') && tstzrange(v_start,v_end,'[)')) then
   return jsonb_build_object('ok',false,'error','interview_time_conflict');
 end if;
 v_id:=gen_random_uuid();
 insert into public.interviews(id,agency_id,application_id,interview_type,scheduled_at,timezone,location_or_link,status,created_by_user_id,end_at,candidate_timezone,recruiter_timezone,meeting_url,instructions,interviewers,scorecard_template_id)
 values(v_id,v_agency,v_app,coalesce(nullif(p_interview->>'interviewType',''),'CUSTOM'),v_start,v_tz,nullif(p_interview->>'locationOrLink',''),coalesce(nullif(p_interview->>'status',''),'SCHEDULED'),v_user,v_end,v_candidate_tz,v_recruiter_tz,nullif(p_interview->>'meetingUrl',''),nullif(p_interview->>'instructions',''),coalesce(p_interview->'interviewers','[]'::jsonb),nullif(p_interview->>'scorecardTemplateId','')::uuid);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'interview',v_id,'interview.scheduled','Interview scheduled',jsonb_build_object('application_id',v_app,'timezone',v_tz,'scheduled_utc',v_start,'duration_minutes',extract(epoch from(v_end-v_start))/60));
 return jsonb_build_object('ok',true,'id',v_id,'scheduled_at',v_start,'end_at',v_end,'timezone',v_tz);
end;$fn$;

grant execute on function public.xzrecruiter_schedule_interview(text,jsonb) to anon,authenticated;
