-- Step 4 closeout: configurable interview scorecard template studio.
create or replace function public.xzrecruiter_save_scorecard_template(p_token text,p_template jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_id uuid;v_name text;v_module text;v_min integer;v_max integer;v_item jsonb;v_order integer:=0;v_code text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_name:=btrim(coalesce(p_template->>'name',''));if length(v_name)<2 then return jsonb_build_object('ok',false,'error','name_required'); end if;
  v_module:=upper(coalesce(nullif(p_template->>'module',''),'INTERVIEW'));v_min:=greatest(0,least(coalesce(nullif(p_template->>'ratingMin','')::integer,1),10));v_max:=greatest(v_min+1,least(coalesce(nullif(p_template->>'ratingMax','')::integer,5),10));
  if nullif(p_template->>'id','') is null then
    insert into public.scorecard_templates(agency_id,name,module,rating_min,rating_max,hide_peer_feedback_until_submit,active,created_by_user_id)
      values(v_agency,v_name,v_module,v_min,v_max,coalesce((p_template->>'hidePeerFeedback')::boolean,true),true,v_user) returning id into v_id;
  else
    v_id:=(p_template->>'id')::uuid;
    update public.scorecard_templates set name=v_name,module=v_module,rating_min=v_min,rating_max=v_max,hide_peer_feedback_until_submit=coalesce((p_template->>'hidePeerFeedback')::boolean,hide_peer_feedback_until_submit),updated_at=now() where id=v_id and agency_id=v_agency;
    if not found then return jsonb_build_object('ok',false,'error','scorecard_template_not_found'); end if;
    update public.scorecard_criteria set active=false where template_id=v_id and agency_id=v_agency;
  end if;
  if jsonb_typeof(coalesce(p_template->'criteria','[]'::jsonb))='array' then
    for v_item in select value from jsonb_array_elements(coalesce(p_template->'criteria','[]'::jsonb)) loop
      if nullif(btrim(v_item->>'label'),'') is not null then
        v_order:=v_order+10;v_code:=upper(regexp_replace(coalesce(nullif(v_item->>'code',''),v_item->>'label'),'[^A-Za-z0-9]+','_','g'));
        insert into public.scorecard_criteria(agency_id,template_id,code,label,description,weight,sort_order,active)
          values(v_agency,v_id,v_code,btrim(v_item->>'label'),nullif(v_item->>'description',''),greatest(0.1,coalesce(nullif(v_item->>'weight','')::numeric,1)),coalesce(nullif(v_item->>'sortOrder','')::integer,v_order),true)
        on conflict(template_id,code) do update set label=excluded.label,description=excluded.description,weight=excluded.weight,sort_order=excluded.sort_order,active=true;
      end if;
    end loop;
  end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'scorecard_template',v_id,'scorecard_template.saved','Interview scorecard template saved');
  return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;
grant execute on function public.xzrecruiter_save_scorecard_template(text,jsonb) to anon,authenticated;
