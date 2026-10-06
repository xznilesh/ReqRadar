import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

function required(name){const value=String(process.env[name]||'').trim();if(!value)throw new Error('missing_env:'+name);return value}
const dbUrl=required('XZRECRUITER_PERF_DATABASE_URL');
const productionUrl=String(process.env.XZRECRUITER_DATABASE_URL||'').trim();
if(productionUrl&&dbUrl===productionUrl&&String(process.env.XZRECRUITER_PERF_ALLOW_PRODUCTION||'').toLowerCase()!=='true'){
  throw new Error('refusing_to_load_test_production_database');
}
const sizes=String(process.env.XZRECRUITER_PERF_SIZES||'1000,10000,50000,100000').split(',').map(Number).filter(n=>Number.isInteger(n)&&n>0);
if(!sizes.length)throw new Error('invalid_perf_sizes');
const repetitions=Math.max(20,Math.min(Number(process.env.XZRECRUITER_PERF_REPETITIONS||100),500));
const p95Limit=Math.max(1,Number(process.env.XZRECRUITER_PERF_P95_MS||250));
const p99Limit=Math.max(p95Limit,Number(process.env.XZRECRUITER_PERF_P99_MS||500));
const sqlPath=path.resolve('scripts/step9-postgres-load.sql');
if(!fs.existsSync(sqlPath))throw new Error('missing_sql_harness');

const version=spawnSync('psql',['--version'],{encoding:'utf8'});
if(version.status!==0)throw new Error('psql_not_available');
console.log(String(version.stdout||'').trim());
const results=[];
for(const size of sizes){
  const run=spawnSync('psql',[dbUrl,'-X','-q','-v','ON_ERROR_STOP=1','-v',`scale=${size}`,'-v',`repetitions=${repetitions}`,'-f',sqlPath],{
    encoding:'utf8',maxBuffer:16*1024*1024,env:{...process.env,PGCONNECT_TIMEOUT:process.env.PGCONNECT_TIMEOUT||'10'}
  });
  if(run.status!==0){
    process.stderr.write(run.stderr||'');
    throw new Error('postgres_load_failed:'+size);
  }
  for(const line of String(run.stdout||'').split(/\r?\n/)){
    if(!line.startsWith('XZBENCH|'))continue;
    const [,scale,query,p50,p95,p99]=line.split('|');
    const row={scale:Number(scale),query,p50:Number(p50),p95:Number(p95),p99:Number(p99)};
    results.push(row);
    console.log(line);
  }
}
if(!results.length)throw new Error('postgres_load_no_measurements');
const violations=results.filter(r=>r.p95>p95Limit||r.p99>p99Limit);
if(violations.length){
  console.error('POSTGRES_LOAD_SLO_FAIL '+JSON.stringify({p95Limit,p99Limit,violations}));
  process.exit(2);
}
console.log('POSTGRES_LOAD_CERT_PASS '+JSON.stringify({sizes,repetitions,p95Limit,p99Limit,measurements:results.length}));
