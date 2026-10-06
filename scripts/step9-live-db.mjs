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
function count(sql){return Number(query(sql)||0)}

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql')).sort();
const localMigrations=migrations.map((file)=>{
  const match=file.match(/^(\\d+)_([^/]+)\\.sql$/);
  if(!match)throw new Error('invalid_migration_filename='+file);
  return {version:match[1],name:match[2]};
});
const localVersions=localMigrations.map(x=>x.version);
if(new Set(localVersions).size!==localVersions.length)throw new Error('local_migration_versions_not_unique');

const remoteRaw=query("select version||'|'||name from supabase_migrations.schema_migrations order by version;");
const remoteMigrations=remoteRaw
  ? remoteRaw.split(/\\r?\\n/).filter(Boolean).map((line)=>{
      const split=line.indexOf('|');
      return {version:line.slice(0,split),name:line.slice(split+1)};
    })
  : [];
const remotePairs=new Set(remoteMigrations.map(x=>x.version+'|'+x.name));
const missingLocal=localMigrations.filter(x=>!remotePairs.has(x.version+'|'+x.name));
if(missingLocal.length){
  throw new Error('migration_history_drift missing='+missingLocal.map(x=>x.version+'_'+x.name).join(','));
}
const unexpectedRemote=remoteMigrations.filter(x=>
  !localMigrations.some(l=>l.version===x.version&&l.name===x.name) &&
  !String(x.name||'').startsWith('step9_bootstrap_')
);
if(unexpectedRemote.length){
  throw new Error('migration_history_untracked_remote='+unexpectedRemote.map(x=>x.version+'_'+x.name).join(','));
}

const missingRls=count(`
select count(*) from information_schema.columns c
join pg_class pc on pc.relname=c.table_name
join pg_namespace pn on pn.oid=pc.relnamespace and pn.nspname=c.table_schema
where c.table_schema='public' and c.column_name='agency_id' and pc.relkind='r' and pc.relrowsecurity=false;`);
if(missingRls)throw new Error('tenant_tables_without_rls='+missingRls);

const directGrants=count(`
select count(*) from information_schema.role_table_grants
where table_schema='public' and grantee in ('anon','authenticated')
and privilege_type in ('SELECT','INSERT','UPDATE','DELETE');`);
if(directGrants)throw new Error('unexpected_direct_table_grants='+directGrants);

const missingHealth=count("select case when to_regprocedure('public.xzrecruiter_public_health()') is null then 1 else 0 end;");
if(missingHealth)throw new Error('public_health_rpc_missing');

const orphanApplications=count(`
select count(*) from public.applications a
left join public.candidates c on c.id=a.candidate_id and c.agency_id=a.agency_id
left join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=a.agency_id
where c.id is null or j.id is null;`);
if(orphanApplications)throw new Error('orphan_applications='+orphanApplications);

const orphanSubmissions=count(`
select count(*) from public.candidate_submissions s
left join public.applications a on a.id=s.application_id and a.agency_id=s.agency_id
where a.id is null;`);
if(orphanSubmissions)throw new Error('orphan_submissions='+orphanSubmissions);

const duplicateLiveSubmissions=count(`
select count(*) from (
 select agency_id,application_id,count(*) n
 from public.candidate_submissions
 where invalidated_at is null and withdrawn_at is null
   and workflow_status in ('INTERNAL_SUBMITTED','AM_APPROVED','CLIENT_SUBMITTED')
 group by agency_id,application_id having count(*)>1
) x;`);
if(duplicateLiveSubmissions)throw new Error('duplicate_live_submissions='+duplicateLiveSubmissions);

const impossibleClientSubmit=count(`
select count(*) from public.candidate_submissions s
where s.workflow_status='CLIENT_SUBMITTED'
and (s.status<>'SUBMITTED' or s.client_submitted_at is null or s.am_reviewed_at is null);`);
if(impossibleClientSubmit)throw new Error('impossible_client_submission_state='+impossibleClientSubmit);

console.log('STEP9_LIVE_DB_PASS migration_history=true rls=true direct_grants=0 health_rpc=true orphans=0 duplicate_live_submissions=0 impossible_states=0');
