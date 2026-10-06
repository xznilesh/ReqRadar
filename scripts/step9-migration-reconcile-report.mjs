import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const dbUrl=String(process.env.XZRECRUITER_DATABASE_URL||process.env.DATABASE_URL||'').trim();
if(!dbUrl||dbUrl.includes('placeholder')){
  console.error('MIGRATION_RECONCILE_BLOCKED missing_verified_XZRECRUITER_DATABASE_URL');
  process.exit(2);
}
const psql=spawnSync('psql',['--version'],{encoding:'utf8'});
if(psql.status!==0){
  console.error('MIGRATION_RECONCILE_BLOCKED psql_not_available');
  process.exit(2);
}
function query(sql){
  const r=spawnSync('psql',[dbUrl,'-X','-A','-t','-F','|','-v','ON_ERROR_STOP=1','-c',sql],{
    encoding:'utf8',maxBuffer:8*1024*1024,env:{...process.env,PGCONNECT_TIMEOUT:process.env.PGCONNECT_TIMEOUT||'10'}
  });
  if(r.status!==0)throw new Error((r.stderr||r.stdout||'psql_failed').trim());
  return String(r.stdout||'').trim();
}

const dir='supabase/migrations';
const files=fs.readdirSync(dir).filter(x=>x.endsWith('.sql')).sort();
const localByVersion=new Map();
for(const file of files){
  const version=file.split('_')[0];
  const name=file.slice(version.length+1,-4);
  const stat=fs.statSync(path.join(dir,file));
  const item={version,name,file,bytes:stat.size};
  if(!localByVersion.has(version))localByVersion.set(version,[]);
  localByVersion.get(version).push(item);
}

const columns=new Set(query(`
select column_name
from information_schema.columns
where table_schema='supabase_migrations' and table_name='schema_migrations'
order by ordinal_position;`).split(/\r?\n/).filter(Boolean));
if(!columns.has('version'))throw new Error('supabase_migration_history_version_column_missing');
const hasName=columns.has('name');
const remoteSql=hasName
  ? `select version::text,coalesce(name::text,'') from supabase_migrations.schema_migrations order by version;`
  : `select version::text,'' from supabase_migrations.schema_migrations order by version;`;
const remoteRows=query(remoteSql).split(/\r?\n/).filter(Boolean).map(line=>{
  const [version,...rest]=line.split('|');
  return {version,name:rest.join('|')};
});
const remoteByVersion=new Map(remoteRows.map(row=>[row.version,row]));

const rows=[];
let ambiguous=0,remoteOnly=0,localOnly=0;
for(const [version,locals] of localByVersion){
  const remote=remoteByVersion.get(version)||null;
  let status='MATCH';
  let matchedFile=null;
  if(!remote){
    status='LOCAL_ONLY';localOnly++;
  }else if(locals.length>1){
    const normalizedRemote=String(remote.name||'').replace(/\.sql$/,'');
    matchedFile=locals.find(x=>x.name===normalizedRemote||x.file===remote.name||x.file===normalizedRemote+'.sql')||null;
    if(matchedFile)status='DUPLICATE_PREFIX_REMOTE_NAME_MATCH';
    else{status='AMBIGUOUS_DUPLICATE_PREFIX';ambiguous++;}
  }
  rows.push({version,status,remoteName:remote?.name||null,matchedFile:matchedFile?.file||null,localFiles:locals.map(x=>x.file)});
}
for(const remote of remoteRows){
  if(!localByVersion.has(remote.version)){
    remoteOnly++;
    rows.push({version:remote.version,status:'REMOTE_ONLY',remoteName:remote.name||null,matchedFile:null,localFiles:[]});
  }
}
rows.sort((a,b)=>a.version.localeCompare(b.version));

const report={
  generatedAt:new Date().toISOString(),
  readOnly:true,
  localFileCount:files.length,
  localVersionCount:localByVersion.size,
  remoteVersionCount:remoteRows.length,
  migrationHistoryColumns:[...columns],
  summary:{ambiguous,localOnly,remoteOnly,duplicatePrefixes:[...localByVersion].filter(([,v])=>v.length>1).map(([v,a])=>({version:v,count:a.length}))},
  rows
};
fs.mkdirSync('test-results',{recursive:true});
fs.writeFileSync('test-results/migration-reconcile-report.json',JSON.stringify(report,null,2)+'\n');
console.log('MIGRATION_RECONCILE_REPORT '+JSON.stringify(report.summary));
for(const row of rows.filter(x=>x.status!=='MATCH'))console.log('MIGRATION_RECONCILE_ROW '+JSON.stringify(row));
if(ambiguous||localOnly||remoteOnly)process.exit(2);
console.log('MIGRATION_RECONCILE_PASS exact_history_mapping=true');
