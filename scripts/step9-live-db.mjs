import fs from 'node:fs';
import {spawnSync} from 'node:child_process';

const url=process.env.XZRECRUITER_DATABASE_URL||process.env.DATABASE_URL||'';
if(!url||url.includes('placeholder')){
  console.error('STEP9_LIVE_DB_BLOCKED missing_verified_XZRECRUITER_DATABASE_URL');
  process.exit(2);
}
const psql=spawnSync('psql',['--version'],{encoding:'utf8'});
if(psql.status!==0){
  console.error('STEP9_LIVE_DB_BLOCKED psql_not_available');
  process.exit(2);
}
function query(sql){
  const r=spawnSync('psql',[url,'-At','-v','ON_ERROR_STOP=1','-c',sql],{encoding:'utf8'});
  if(r.status!==0)throw new Error((r.stderr||r.stdout||'psql_failed').trim());
  return (r.stdout||'').trim();
}
function sqlLiteral(value){return "'" + String(value).replaceAll("'","''") + "'"}
const blockers=[];
function checkZero(label,sql){
  try{
    const value=Number(query(sql)||0);
    console.log('STEP9_LIVE_DB_CHECK '+label+'='+value);
    if(value!==0)blockers.push(label+'='+value);
  }catch(error){
    console.error('STEP9_LIVE_DB_CHECK_ERROR '+label+' '+String(error?.message||error).replace(/\s+/g,' ').slice(0,500));
    blockers.push(label+'_query_failed');
  }
}
function checkOne(label,sql){
  try{
    const value=Number(query(sql)||0);
    console.log('STEP9_LIVE_DB_CHECK '+label+'='+value);
    if(value!==1)blockers.push(label+'='+value);
  }catch(error){
    console.error('STEP9_LIVE_DB_CHECK_ERROR '+label+' '+String(error?.message||error).replace(/\s+/g,' ').slice(0,500));
    blockers.push(label+'_query_failed');
  }
}

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql')).sort();
const localByVersion=new Map();
for(const file of migrations){
  const version=file.split('_')[0];
  if(!localByVersion.has(version))localByVersion.set(version,[]);
  localByVersion.get(version).push(file);
}
const localVersions=[...localByVersion.keys()].sort();
const duplicateVersions=[...localByVersion.entries()].filter(([,files])=>files.length>1);

let remoteVersions=[];
try{
  const remoteRaw=query("select version from supabase_migrations.schema_migrations order by version;");
  remoteVersions=remoteRaw?remoteRaw.split(/\r?\n/).filter(Boolean):[];
}catch(error){
  console.error('STEP9_MIGRATION_HISTORY_QUERY_FAILED '+String(error?.message||error).replace(/\s+/g,' ').slice(0,500));
  blockers.push('remote_migration_history_unreadable');
}

const remoteSet=new Set(remoteVersions);
const localSet=new Set(localVersions);
const migrationReport={
  localFileCount:migrations.length,
  localVersionCount:localVersions.length,
  remoteVersionCount:remoteVersions.length,
  duplicates:duplicateVersions.map(([version,files])=>({version,files})),
  ambiguousRemoteVersions:duplicateVersions.filter(([version])=>remoteSet.has(version)).map(([version,files])=>({version,files})),
  localVersionsAbsentRemote:localVersions.filter(version=>!remoteSet.has(version)),
  remoteVersionsAbsentLocal:remoteVersions.filter(version=>!localSet.has(version))
};
console.log('STEP9_MIGRATION_HISTORY_REPORT '+JSON.stringify(migrationReport));

if(duplicateVersions.length)blockers.push('local_migration_version_collision');
if(!duplicateVersions.length&&JSON.stringify(remoteVersions)!==JSON.stringify(localVersions)){
  blockers.push('migration_history_drift');
}

checkZero('tenant_tables_without_rls',`
select count(*) from information_schema.columns c
join pg_class pc on pc.relname=c.table_name
join pg_namespace pn on pn.oid=pc.relnamespace and pn.nspname=c.table_schema
where c.table_schema='public' and c.column_name='agency_id' and pc.relkind='r' and pc.relrowsecurity=false;`);

checkZero('unexpected_direct_public_table_grants',`
select count(*) from information_schema.role_table_grants
where table_schema='public' and grantee in ('anon','authenticated')
and privilege_type in ('SELECT','INSERT','UPDATE','DELETE');`);

checkOne('public_health_rpc_present',`
select case when to_regprocedure('public.xzrecruiter_public_health()') is null then 0 else 1 end;`);

const buckets=[...new Set([
  process.env.XZRECRUITER_STORAGE_BUCKET||'xzrecruiter-private',
  process.env.XZRECRUITER_SENSITIVE_STORAGE_BUCKET||process.env.XZRECRUITER_STORAGE_BUCKET||'xzrecruiter-private'
])];
for(const bucket of buckets){
  checkOne('private_bucket_'+bucket.replace(/[^A-Za-z0-9_-]/g,'_'),`
    select case when exists(
      select 1 from storage.buckets where id=${sqlLiteral(bucket)} and public=false
    ) then 1 else 0 end;`);
}
checkOne('storage_objects_rls_enabled',`
select case when exists(
  select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='storage' and c.relname='objects' and c.relrowsecurity=true
) then 1 else 0 end;`);
checkZero('browser_storage_object_policies',`
select count(*) from pg_policies
where schemaname='storage' and tablename='objects'
and (
  roles::text ilike '%anon%' or
  roles::text ilike '%authenticated%' or
  roles::text ilike '%public%'
);`);

checkZero('orphan_applications',`
select count(*) from public.applications a
left join public.candidates c on c.id=a.candidate_id and c.agency_id=a.agency_id
left join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=a.agency_id
where c.id is null or j.id is null;`);

checkZero('orphan_submissions',`
select count(*) from public.candidate_submissions s
left join public.applications a on a.id=s.application_id and a.agency_id=s.agency_id
where a.id is null;`);

checkZero('duplicate_live_submissions',`
select count(*) from (
 select agency_id,application_id,count(*) n
 from public.candidate_submissions
 where invalidated_at is null and withdrawn_at is null
   and workflow_status in ('INTERNAL_SUBMITTED','AM_APPROVED','CLIENT_SUBMITTED')
 group by agency_id,application_id having count(*)>1
) x;`);

checkZero('impossible_client_submission_state',`
select count(*) from public.candidate_submissions s
where s.workflow_status='CLIENT_SUBMITTED'
and (s.status<>'SUBMITTED' or s.client_submitted_at is null or s.am_approved_at is null);`);

if(blockers.length){
  console.error('STEP9_LIVE_DB_BLOCKED '+JSON.stringify([...new Set(blockers)]));
  process.exit(2);
}
console.log('STEP9_LIVE_DB_PASS migration_history=true rls=true storage_private=true storage_rls=true browser_storage_policies=0 orphans=0 duplicate_live_submissions=0 impossible_states=0');
