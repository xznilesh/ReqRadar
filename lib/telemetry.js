const SAFE_KEYS=new Set([
  'request_id','route','route_type','router_kind','method','status','status_code','duration_ms',
  'error_name','error_digest','dependency','environment','runtime','deployment','version','action'
]);

function cleanValue(value){
  if(value===null||value===undefined)return undefined;
  if(typeof value==='boolean'||typeof value==='number')return value;
  const text=String(value);
  if(text.length>180)return text.slice(0,180);
  return text.replace(/[\r\n\t]/g,' ');
}

function safeMetadata(metadata={}){
  const result={};
  for(const [key,value] of Object.entries(metadata||{})){
    if(!SAFE_KEYS.has(key))continue;
    const cleaned=cleanValue(value);
    if(cleaned!==undefined)result[key]=cleaned;
  }
  return result;
}

function emit(level,event,metadata={}){
  const payload={
    timestamp:new Date().toISOString(),
    service:'xzrecruiter',
    level,
    event:String(event||'application_event').slice(0,120),
    ...safeMetadata(metadata)
  };
  const line=JSON.stringify(payload);
  if(level==='error')console.error(line);
  else if(level==='warn')console.warn(line);
  else console.log(line);
  return payload;
}

export function telemetryInfo(event,metadata){return emit('info',event,metadata)}
export function telemetryWarn(event,metadata){return emit('warn',event,metadata)}
export function telemetryError(event,error,metadata={}){
  return emit('error',event,{
    ...metadata,
    error_name:error?.name||'Error',
    error_digest:error?.digest||metadata?.error_digest
  });
}
