-- Step 4 closeout: reusable ATS saved views, authorized private document access and blind-feedback privacy.

create or replace function public.xzrecruiter_saved_view_context(p_token text,p_module text)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_module text:=upper(btrim(coalesce(p_module,'')));v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_module not in ('CANDIDATE','JOB') then return jsonb_build_object('ok',false,'error','invalid_module'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.is_default desc,x.name),'[]'::jsonb) into v_rows from (
    select id,name,scope,filters,sort_config,visible_columns,column_order,is_default,owner_user_id,updated_at
    from public.saved_views
    where agency_id=v_agency and module=v_module and active=true and (scope='TEAM' or owner_user_id=v_user)
  ) x;
  return jsonb_build_object('ok',true,'views',v_rows,'role',v_role,'current_user_id',v_user);
end;$fn$;

create or replace function public.xzrecruiter_save_saved_view(p_token text,p_view jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_module text;v_name text;v_scope text;v_default boolean;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_module:=upper(coalesce(p_view->>'module',''));v_name:=btrim(coalesce(p_view->>'name',''));v_scope:=upper(coalesce(nullif(p_view->>'scope',''),'PERSONAL'));v_default:=coalesce((p_view->>'isDefault')::boolean,false);
  if v_module not in ('CANDIDATE','JOB') or length(v_name)<2 then return jsonb_build_object('ok',false,'error','invalid_view'); end if;
  if v_scope not in ('PERSONAL','TEAM') then return jsonb_build_object('ok',false,'error','invalid_scope'); end if;
  if v_scope='TEAM' and v_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_default then update public.saved_views set is_default=false,updated_at=now() where agency_id=v_agency and module=v_module and active=true and ((v_scope='TEAM' and scope='TEAM') or (v_scope='PERSONAL' and scope='PERSONAL' and owner_user_id=v_user)); end if;
  begin v_id:=nullif(p_view->>'id','')::uuid; exception when others then v_id:=null; end;
  if v_id is null then
    insert into public.saved_views(agency_id,owner_user_id,module,name,scope,filter_logic,filters,sort_config,visible_columns,column_order,is_default,active)
    values(v_agency,v_user,v_module,v_name,v_scope,'AND',coalesce(p_view->'filters','{}'::jsonb),coalesce(p_view->'sort','[]'::jsonb),coalesce(p_view->'visibleColumns','[]'::jsonb),coalesce(p_view->'columnOrder','[]'::jsonb),v_default,true) returning id into v_id;
  else
    update public.saved_views set name=v_name,scope=v_scope,filters=coalesce(p_view->'filters',filters),sort_config=coalesce(p_view->'sort',sort_config),visible_columns=coalesce(p_view->'visibleColumns',visible_columns),column_order=coalesce(p_view->'columnOrder',column_order),is_default=v_default,updated_at=now()
    where id=v_id and agency_id=v_agency and (owner_user_id=v_user or (scope='TEAM' and v_role in ('OWNER','ADMIN','RECRUITMENT_MANAGER')));
    if not found then return jsonb_build_object('ok',false,'error','view_not_found'); end if;
  end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'saved_view',v_id,'saved_view.saved','ATS saved view updated',jsonb_build_object('module',v_module,'scope',v_scope));
  return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_archive_saved_view(p_token text,p_view_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  update public.saved_views set active=false,is_default=false,updated_at=now() where id=p_view_id and agency_id=v_agency and (owner_user_id=v_user or (scope='TEAM' and v_role in ('OWNER','ADMIN','RECRUITMENT_MANAGER')));
  if not found then return jsonb_build_object('ok',false,'error','view_not_found'); end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'saved_view',p_view_id,'saved_view.archived','ATS saved view archived');
  return jsonb_build_object('ok',true);
end;$fn$;

-- Only return a private storage path after the opaque session proves same-workspace access.
create or replace function public.xzrecruiter_candidate_document_access(p_token text,p_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_path text;v_name text;v_mime text;v_candidate uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select storage_path,filename,mime_type,candidate_id into v_path,v_name,v_mime,v_candidate from public.candidate_documents where id=p_document_id and agency_id=v_agency and archived_at is null;
  if v_path is null then return jsonb_build_object('ok',false,'error','document_not_found'); end if;
  return jsonb_build_object('ok',true,'storage_path',v_path,'filename',v_name,'mime_type',v_mime,'candidate_id',v_candidate);
end;$fn$;

-- Override scorecard context so peer feedback is actually hidden until the current interviewer submits when configured.
create or replace function public.xzrecruiter_scorecard_context(p_token text,p_interview_id uuid default null,p_application_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_templates jsonb;v_screening jsonb;v_scorecards jsonb;v_current_submitted boolean:=false;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if p_interview_id is not null and not exists(select 1 from public.interviews where id=p_interview_id and agency_id=v_agency) then return jsonb_build_object('ok',false,'error','interview_not_found'); end if;
  if p_application_id is not null and not exists(select 1 from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  if p_interview_id is not null then select exists(select 1 from public.interview_scorecards where agency_id=v_agency and interview_id=p_interview_id and author_user_id=v_user and status='SUBMITTED') into v_current_submitted; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) into v_templates from (
    select t.id,t.name,t.module,t.rating_min,t.rating_max,t.hide_peer_feedback_until_submit,
      coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'label',c.label,'description',c.description,'weight',c.weight,'sort_order',c.sort_order) order by c.sort_order) from public.scorecard_criteria c where c.template_id=t.id and c.agency_id=v_agency and c.active=true),'[]'::jsonb) criteria
    from public.scorecard_templates t where t.agency_id=v_agency and t.active=true
  ) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at),'[]'::jsonb) into v_screening from (select question_key,question_text,answer,score,knockout,updated_at from public.application_screening_answers where agency_id=v_agency and application_id=p_application_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_scorecards from (
    select s.id,s.interview_id,s.template_id,s.author_user_id,s.recommendation,s.comments,s.status,s.submitted_at,s.updated_at,
      coalesce((select jsonb_agg(jsonb_build_object('criterion_id',r.criterion_id,'rating',r.rating,'comment',r.comment)) from public.interview_scorecard_ratings r where r.scorecard_id=s.id),'[]'::jsonb) ratings
    from public.interview_scorecards s
    left join public.scorecard_templates t on t.id=s.template_id and t.agency_id=v_agency
    where s.agency_id=v_agency and (p_interview_id is null or s.interview_id=p_interview_id)
      and (s.author_user_id=v_user or (s.status='SUBMITTED' and (coalesce(t.hide_peer_feedback_until_submit,true)=false or v_current_submitted=true)))
  ) x;
  return jsonb_build_object('ok',true,'templates',v_templates,'screening',v_screening,'scorecards',v_scorecards,'current_user_id',v_user,'current_user_submitted',v_current_submitted);
end;$fn$;

grant execute on function public.xzrecruiter_saved_view_context(text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_saved_view(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_saved_view(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_document_access(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_scorecard_context(text,uuid,uuid) to anon,authenticated;
