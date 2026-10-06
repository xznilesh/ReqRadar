import { telemetryError, telemetryInfo } from './lib/telemetry.js';

export async function register(){
  telemetryInfo('server_runtime_registered',{
    runtime:process.env.NEXT_RUNTIME||'unknown',
    environment:process.env.VERCEL_ENV||process.env.NODE_ENV||'unknown',
    deployment:process.env.VERCEL_GIT_COMMIT_SHA||process.env.VERCEL_DEPLOYMENT_ID||'unknown',
    version:'1.0.0'
  });
}

export async function onRequestError(error,request,context){
  telemetryError('next_request_error',error,{
    request_id:request?.headers?.['x-request-id']||request?.headers?.['x-vercel-id'],
    route:context?.routePath||'unknown',
    route_type:context?.routeType||'unknown',
    router_kind:context?.routerKind||'unknown',
    method:request?.method||'unknown',
    runtime:process.env.NEXT_RUNTIME||'unknown',
    environment:process.env.VERCEL_ENV||process.env.NODE_ENV||'unknown'
  });
}
