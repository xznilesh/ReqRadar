import {spawnSync} from 'node:child_process';

const url=process.env.XZRECRUITER_DATABASE_URL||process.env.DATABASE_URL||'';
if(!url||url.includes('placeholder')){
  console.log('STEP7_LIVE_DB_BLOCKED missing_verified_XZRECRUITER_DATABASE_URL');
  process.exit(2);
}
const hasPsql=spawnSync('psql',['--version'],{encoding:'utf8'});
if(hasPsql.status!==0){
  console.log('STEP7_LIVE_DB_BLOCKED psql_not_available');
  process.exit(2);
}
function query(sql){
  const r=spawnSync('psql',[url,'-At','-v','ON_ERROR_STOP=1','-c',sql],{encoding:'utf8'});
  if(r.status!==0)throw new Error((r.stderr||r.stdout||'psql_failed').trim());
  return (r.stdout||'').trim();
}

const missingRls=Number(query(`
select count(*)
from information_schema.columns c
join pg_class pc on pc.relname=c.table_name
join pg_namespace pn on pn.oid=pc.relnamespace and pn.nspname=c.table_schema
where c.table_schema='public' and c.column_name='agency_id' and pc.relkind='r' and pc.relrowsecurity=false;
`)||0);
if(missingRls!==0)throw new Error('tenant_tables_without_rls='+missingRls);

const directGrants=Number(query(`
select count(*)
from information_schema.role_table_grants
where table_schema='public' and grantee in ('anon','authenticated')
  and privilege_type in ('SELECT','INSERT','UPDATE','DELETE');
`)||0);
if(directGrants!==0)throw new Error('unexpected_direct_table_grants='+directGrants);

const unsafeViews=Number(query(`
select count(*)
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='v'
  and not coalesce(c.reloptions,'{}'::text[]) @> array['security_invoker=true'];
`)||0);
if(unsafeViews!==0)throw new Error('views_without_security_invoker='+unsafeViews);

const publicDefiners=Number(query(`
select count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef
  and has_function_privilege('public',p.oid,'EXECUTE');
`)||0);
if(publicDefiners!==0)throw new Error('security_definer_public_execute='+publicDefiners);

const immutable=Number(query(`
select count(*)
from information_schema.role_table_grants
where table_schema='public' and table_name in ('audit_events','security_events')
  and grantee in ('anon','authenticated') and privilege_type in ('UPDATE','DELETE');
`)||0);
if(immutable!==0)throw new Error('mutable_audit_security_events='+immutable);

const unsafeAnonDefiners=Number(query(`
select count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef
  and has_function_privilege('anon',p.oid,'EXECUTE')
  and pg_get_function_identity_arguments(p.oid) !~* '(token|slug|email|upload)';
`)||0);
if(unsafeAnonDefiners!==0)throw new Error('anon_security_definer_without_capability_argument='+unsafeAnonDefiners);

const mutablePrivateSearchPath=Number(query(`
select count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='private' and p.proname in ('xzrecruiter_can_write','xzrecruiter_can_screen')
  and not coalesce(p.proconfig,'{}'::text[]) @> array['search_path=pg_catalog'];
`)||0);
if(mutablePrivateSearchPath!==0)throw new Error('private_helpers_without_fixed_search_path='+mutablePrivateSearchPath);

console.log('STEP7_LIVE_DB_PASS tenant_rls=true direct_grants=0 security_invoker_views=true public_definers=0 audit_immutable=true anon_definers_capability_guarded=true private_search_path_fixed=true');
