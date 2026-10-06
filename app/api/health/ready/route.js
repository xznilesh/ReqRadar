import { NextResponse } from 'next/server';
import { rpc, supabaseConfigured } from '@/lib/supabase-api';
import { storageConfigured } from '@/lib/server-storage';
import { malwareScannerConfigured } from '@/lib/malware-scan';
import { telemetryError, telemetryWarn } from '@/lib/telemetry';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

function dependencyState() {
  const production = process.env.NODE_ENV === 'production';
  return {
    supabase: supabaseConfigured(),
    private_storage: !production || storageConfigured(),
    malware_scanner: !production || malwareScannerConfigured(),
    ai_provider: !production || Boolean(String(process.env.OPENAI_API_KEY || '').trim())
  };
}

export async function GET() {
  const started = Date.now();
  const dependencies = dependencyState();
  if (Object.values(dependencies).some((ready) => ready !== true)) {
    telemetryWarn('readiness_dependency_blocked',{
      dependency:Object.entries(dependencies).filter(([,ready])=>!ready).map(([name])=>name).join(',')
    });
    return NextResponse.json({
      ok: false,
      service: 'xzrecruiter',
      database: dependencies.supabase ? 'unchecked' : 'not_configured',
      dependencies: Object.fromEntries(Object.entries(dependencies).map(([name,ready]) => [name, ready ? 'ready' : 'not_ready'])),
      version: '1.0.0'
    }, { status: 503 });
  }

  try {
    const result = await rpc('xzrecruiter_public_health');
    if (!result?.ok) throw new Error('Health RPC returned not-ready');
    return NextResponse.json({
      ok: true,
      service: 'xzrecruiter',
      database: 'ready',
      dependencies: Object.fromEntries(Object.keys(dependencies).map((name) => [name, 'ready'])),
      latency_ms: Date.now() - started,
      version: '1.0.0'
    });
  } catch (error) {
    telemetryError('readiness_database_failed',error,{status_code:error?.status||503,dependency:'database'});
    return NextResponse.json({
      ok: false,
      service: 'xzrecruiter',
      database: 'unreachable',
      dependencies: Object.fromEntries(Object.entries(dependencies).map(([name,ready]) => [name, ready ? 'ready' : 'not_ready'])),
      version: '1.0.0'
    }, { status: 503 });
  }
}
