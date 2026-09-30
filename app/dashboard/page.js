import Link from 'next/link';
import { redirect } from 'next/navigation';
import AppShell from '@/app/components/AppShell';
import { getCurrentUser, sessionToken } from '@/lib/auth';
import { getGlobalContext } from '@/lib/global-context';
import { getOnboardingContext } from '@/lib/onboarding';
import { rpc } from '@/lib/supabase-api';
import { formatDateTime } from '@/lib/globalization';
import { redirectRecruiterFromLegacyWorkspace } from '@/lib/recruiter-access';

export const dynamic = 'force-dynamic';

function labelsFor(context, preferenceContext, domain) {
  return (context?.taxonomy_preferences || [])
    .filter((item) => item.context === preferenceContext && item.domain === domain)
    .map((item) => item.label);
}

export default async function Dashboard({ searchParams }) {
  const params = await searchParams;
  let user;
  try { user = await getCurrentUser(); }
  catch (error) { console.error('me_rpc_failed', error?.message); redirect('/login?error=service'); }
  if (!user) redirect('/login');

  const [globalContext, onboarding] = await Promise.all([
    getGlobalContext().catch((error) => { console.error('global_context_dashboard_failed', error?.message || ''); return null; }),
    getOnboardingContext().catch((error) => { console.error('onboarding_context_dashboard_failed', error?.message || ''); return null; })
  ]);
  if (!globalContext?.settings) redirect('/login?error=service');
  if (!onboarding) redirect('/onboarding?error=setup');
  if (onboarding.progress?.status !== 'COMPLETED') redirect('/onboarding');
  await redirectRecruiterFromLegacyWorkspace();

  const token = await sessionToken();
  let d = { metrics: { companies: 0, jobs: 0, hot: 0, clients: 0, candidates: 0 }, signals: [], pipeline: [] };
  try {
    const result = await rpc('xzrecruiter_dashboard', { p_token: token });
    if (!result?.ok) redirect('/login');
    d = result;
  } catch (error) { console.error('dashboard_rpc_failed', error?.message); }

  const settings = globalContext.settings;
  const m = d.metrics || {};
  const signals = Array.isArray(d.signals) ? d.signals : [];
  const pipeline = Array.isArray(d.pipeline) ? d.pipeline : [];
  const max = Math.max(1, ...pipeline.map((x) => Number(x.n) || 0));
  const localNow = formatDateTime(new Date(), { locale: settings.locale || 'en-GB', timezone: settings.timezone_id || 'UTC' });
  const markets = (onboarding.markets || []).filter((market) => market.target_kind === 'RECRUITING');
  const marketNames = markets.map((market) => globalContext.countries?.find((country) => country.country_code === market.country_code)?.country_name || market.country_code);
  const functions = labelsFor(onboarding, 'RECRUITMENT', 'JOB_FUNCTION');
  const industries = labelsFor(onboarding, 'INDUSTRY', 'INDUSTRY');
  const sizes = labelsFor(onboarding, 'ICP', 'COMPANY_SIZE');
  const completed = new Set(onboarding.progress?.completed_steps || []);
  const realMetricTotal = Number(m.companies || 0) + Number(m.jobs || 0) + Number(m.clients || 0) + Number(m.candidates || 0) + Number(m.hot || 0);

  const checklist = [
    ['profile','Agency profile','/onboarding?section=profile&edit=1'],
    ['markets','Global markets','/onboarding?section=markets&edit=1'],
    ['specialization','Specializations','/onboarding?section=specialization&edit=1'],
    ['icp','Company ICP','/onboarding?section=icp&edit=1'],
    ['pipelines','Recruitment pipeline','/pipeline'],
    ['import','Import candidates','/import'],
    ['client','Add first client','/clients?action=create'],
    ['job','Create first job','/jobs?action=create']
  ];

  return <AppShell user={user} globalSettings={settings} active="home">
    <div className="page-heading dashboard-heading"><div><span className="page-kicker">Recruitment command center</span><h1>{params?.setup === 'complete' ? 'Your recruiter workspace is ready.' : `Good to see you, ${user.display_name || 'Recruiter'}.`}</h1><p>Manage your team’s requirements, candidates and next actions from one workspace.</p></div><div className="heading-statuses"><span className="status good">● Setup complete</span><span className="status neutral">{settings.country_name} · {settings.timezone_id}</span></div></div>

    <section className="workspace-blueprint-card" aria-label="Recruitment workspace summary">
      <div className="blueprint-heading"><div><span className="eyebrow-mini">Workspace blueprint</span><h2>{user.agency_name}</h2><p>{localNow}</p></div><Link href="/onboarding?edit=1" className="small-action">Edit setup</Link></div>
      <div className="blueprint-grid">
        <div><span>Markets</span><b>{marketNames.slice(0,5).join(' · ') || settings.country_name}</b>{marketNames.length > 5 ? <small>+{marketNames.length - 5} more</small> : null}</div>
        <div><span>Specialization</span><b>{functions.slice(0,5).join(' · ') || 'General recruitment'}</b>{functions.length > 5 ? <small>+{functions.length - 5} more</small> : null}</div>
        <div><span>Industries</span><b>{industries.slice(0,5).join(' · ') || 'Multi-industry'}</b>{industries.length > 5 ? <small>+{industries.length - 5} more</small> : null}</div>
        <div><span>Target accounts</span><b>{sizes.slice(0,5).join(' · ') || 'Any company size'}</b></div>
      </div>
    </section>

    <div className="fast-action-strip" aria-label="Fast actions">
      <div><b>Start productive work</b><span>Candidate → Job → Pipeline → Interview → Offer → Placement.</span></div>
      <Link href="/candidates?action=create" className="small-action">＋ Candidate</Link>
      <Link href="/jobs?action=create" className="small-action">＋ Job</Link>
      <Link href="/pipeline" className="small-action">Pipeline</Link>
      <Link href="/import" className="small-action">Import</Link>
    </div>

    {realMetricTotal > 0 ? <div className="dashmetrics premium-metrics">
      <div className="dmetric"><span>Tracked companies</span><b>{m.companies || 0}</b><small>workspace accounts</small></div>
      <div className="dmetric"><span>Active jobs</span><b>{m.jobs || 0}</b><small>open requirements</small></div>
      <div className="dmetric"><span>Hot accounts</span><b>{m.hot || 0}</b><small>prioritized accounts</small></div>
      <div className="dmetric"><span>Candidates</span><b>{m.candidates || 0}</b><small>workspace talent</small></div>
    </div> : <section className="first-run-panel"><div><span className="page-kicker">Get started</span><h2>Your next hire starts here.</h2><p>Add your first candidate or client requirement. Your team’s recruiting activity will appear here as you work.</p></div><div className="first-run-actions"><Link href="/candidates?action=create">Add candidate</Link><Link href="/jobs?action=create">Create first job</Link><Link href="/import">Import clients or candidates</Link><Link href="/settings?focus=icp">Review target account profile</Link></div></section>}

    <div className="dashboard-config-grid">
      <section className="setup-checklist-card"><div className="panel-title-row"><div><h2>Workspace readiness</h2><p className="panel-sub">Keep your agency profile and recruiting workflow ready for your team.</p></div><span className="panel-badge">{onboarding.progress?.progress_percent || 100}% setup</span></div><div className="setup-checklist">{checklist.map(([key,label,href]) => { const done = completed.has(key) || (key === 'client' && Number(m.clients || 0) > 0) || (key === 'job' && Number(m.jobs || 0) > 0); const body = <><span className={done ? 'check done' : 'check'}>{done ? '✓' : '○'}</span><b>{label}</b><small>{done ? 'Ready' : key === 'client' ? 'Add client' : 'Open action'}</small></>; return href ? <Link key={key} href={href}>{body}</Link> : <div key={key}>{body}</div>; })}</div></section>

      <section className="global-context-card compact-context"><div><span className="eyebrow-mini">Operating context</span><h2>{settings.country_name}</h2><p>Dates, currency and timezones follow your workspace settings.</p></div><dl><div><dt>Locale</dt><dd>{settings.locale}</dd></div><div><dt>Currency</dt><dd>{settings.currency_code}</dd></div><div><dt>Timezone</dt><dd>{settings.timezone_id}</dd></div><div><dt>Language</dt><dd>{settings.language_code?.toUpperCase()}</dd></div></dl><Link href="/settings/global">Change localization →</Link></section>
    </div>

    {(signals.length > 0 || pipeline.length > 0) ? <div className="panels premium-panels">
      {signals.length > 0 ? <div className="panel"><div className="panel-title-row"><div><h2>Highest-priority accounts</h2><div className="panel-sub">Only real scored intelligence appears here.</div></div><span className="panel-badge">Live intelligence</span></div><div className="table"><div className="tr head"><div>Company</div><div>Heat</div><div>Fit</div><div>Recommendation</div></div>{signals.map((s, i) => <div className="tr" key={i}><div><b>{s.name}</b><div className="row-sub">{s.why_now_summary}</div></div><div className="heat">{s.heat_score}</div><div>{s.fit_score ?? '—'}%</div><div><span className="pill">{s.recommendation}</span></div></div>)}</div></div> : null}
      {pipeline.length > 0 ? <div className="panel"><div className="panel-title-row"><div><h2>Recruitment pipeline</h2><div className="panel-sub">Actual active applications by persisted stage.</div></div><Link href="/pipeline" className="small-action">Open pipeline</Link></div><div className="bars">{pipeline.map((p) => <div className="barline" key={p.stage}><span>{p.stage}</span><div className="bar"><i style={{ width: `${Math.max(6, (Number(p.n) || 0) / max * 100)}%` }} /></div><b>{p.n}</b></div>)}</div></div> : null}
    </div> : null}
  </AppShell>;
}
