'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import * as ScrollArea from '@radix-ui/react-scroll-area';
import { Activity, BarChart3, Bell, Briefcase, Building2, Calendar, CheckCircle2, CheckSquare2, Contact, FileText, GitBranch, Globe2, Handshake, Home, Layers3, Menu, Network, PieChart, Plug, Plus, Search, Send, Settings, ShieldCheck, Sparkles, Target, TrendingUp, Users, X, Zap, Gauge } from 'lucide-react';
import Link from 'next/link';
import Brand from '@/app/components/Brand';
import CommandPalette from '@/app/components/CommandPalette';
import WorkspaceSelector from '@/app/components/WorkspaceSelector';
import { namespace } from '@/i18n/resources';
import { directionFor } from '@/lib/globalization';

const navigation = [
  { label: 'Home', items: [{ key: 'home', label: 'Home', href: '/dashboard', icon: '⌂', enabled: true }] },
  { label: 'INTELLIGENCE', items: [
    { key: 'radar', label: 'Hiring Radar', icon: '◉' }, { key: 'companies', label: 'Companies', icon: '▦' },
    { key: 'signals', label: 'Signals', icon: '⌁' }, { key: 'people', label: 'People', icon: '◎' }
  ]},
  { label: 'RECRUITMENT', items: [
    { key: 'recruiter-work', label: 'My Work', href: '/recruiter', icon: '◎', enabled: true },
    { key: 'candidates', label: 'Candidates', href: '/candidates', icon: '◌', enabled: true },
    { key: 'jobs', label: 'Jobs', href: '/jobs', icon: '▤', enabled: true },
    { key: 'recruitment-pipeline', label: 'Recruitment Pipeline', href: '/pipeline', icon: '⋮', enabled: true },
    { key: 'matches', label: 'Matches', icon: '≋' },
    { key: 'interviews', label: 'Interviews', href: '/interviews', icon: '□', enabled: true },
    { key: 'offers', label: 'Offers', href: '/offers', icon: '◇', enabled: true },
    { key: 'placements', label: 'Placements', href: '/placements', icon: '✓', enabled: true }
  ]},
  { label: 'BUSINESS', items: [
    { key: 'clients', label: 'Clients & Accounts', href: '/clients', icon: '▣', enabled: true },
    { key: 'contacts', label: 'Contacts', href: '/contacts', icon: '◍', enabled: true },
    { key: 'opportunities', label: 'Opportunities', href: '/opportunities', icon: '↗', enabled: true },
    { key: 'business-pipeline', label: 'Business Pipeline', href: '/business/pipeline', icon: '⋮', enabled: true },
    { key: 'vendors', label: 'Vendors & Partners', href: '/vendors', icon: '◇', enabled: true },
    { key: 'portals', label: 'Client & Vendor Portals', href: '/portals', icon: '□', enabled: true },
    { key: 'outreach', label: 'Outreach', icon: '✉' }
  ]},
  { label: 'PRODUCTIVITY', items: [
    { key: 'tasks', label: 'Tasks', href: '/tasks', icon: '☑', enabled: true },
    { key: 'automation-notifications', label: 'Notifications', href: '/notifications', icon: '◔', enabled: true },
    { key: 'calendar', label: 'Calendar', icon: '□' }, { key: 'automation', label: 'Automation', icon: '⚡' }
  ]},
  { label: 'INSIGHTS', items: [
    { key: 'manager-control', label: 'Manager Control', href: '/manager', icon: '▥', enabled: true, managerOnly: true },
    { key: 'submissions', label: 'Submission Review', href: '/account-manager/submissions', icon: '▤', enabled: true, managerOnly: true },
    { key: 'reports', label: 'Reports', icon: '▥' }, { key: 'analytics', label: 'Analytics', icon: '⌁' }
  ]},
  { label: 'ADMIN', items: [
    { key: 'integrations', label: 'Integrations', icon: '⌘' },
    { key: 'team', label: 'Team', href: '/onboarding?section=team&edit=1', icon: '◉', enabled: true },
    { key: 'settings', label: 'Configuration Center', href: '/settings', icon: '⚙', enabled: true },
    { key: 'global-settings', label: 'Global Settings', href: '/settings/global', icon: '◎', enabled: true }
  ]}
];

const navIconMap = {
  home: Home,
  radar: Target,
  companies: Building2,
  signals: Activity,
  people: Users,
  'recruiter-work': CheckSquare2,
  candidates: Users,
  jobs: Briefcase,
  'recruitment-pipeline': GitBranch,
  matches: Sparkles,
  interviews: Calendar,
  offers: FileText,
  placements: CheckCircle2,
  clients: Building2,
  contacts: Contact,
  opportunities: TrendingUp,
  'business-pipeline': Network,
  vendors: Handshake,
  portals: Layers3,
  outreach: Send,
  tasks: CheckSquare2,
  'automation-notifications': Bell,
  calendar: Calendar,
  automation: Zap,
  'manager-control': Gauge,
  reports: BarChart3,
  analytics: PieChart,
  integrations: Plug,
  team: Users,
  settings: Settings,
  'global-settings': Globe2
  ,submissions: Send
};

function NavIcon({ name }) {
  const Icon = navIconMap[name] || Target;
  return <Icon size={16} strokeWidth={1.85} aria-hidden="true" />;
}

export default function AppShell({ user, globalSettings, active = 'home', children }) {
  const [commandOpen, setCommandOpen] = useState(false);
  const [quickOpen, setQuickOpen] = useState(false);
  const [notifyOpen, setNotifyOpen] = useState(false);
  const [userOpen, setUserOpen] = useState(false);
  const [navOpen, setNavOpen] = useState(false);
  const popoverRef = useRef(null);
  const language = globalSettings?.language_code || 'en';
  const direction = globalSettings?.direction?.toLowerCase() || directionFor(language);
  const shellText = useMemo(() => namespace(language, 'shell'), [language]);

  useEffect(() => {
    function onKey(event) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); setCommandOpen(true); }
      if (event.key === 'Escape') { setQuickOpen(false); setNotifyOpen(false); setUserOpen(false); setNavOpen(false); }
    }
    window.addEventListener('keydown', onKey); return () => window.removeEventListener('keydown', onKey);
  }, []);

  useEffect(() => {
    const close = (event) => {
      if (popoverRef.current && !popoverRef.current.contains(event.target)) {
        setQuickOpen(false); setNotifyOpen(false); setUserOpen(false);
      }
    };
    document.addEventListener('pointerdown', close);
    return () => document.removeEventListener('pointerdown', close);
  }, []);

  const workspaceName = user?.agency_name || 'Recruiter workspace';
  const managerLike = ['OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER'].includes(String(user?.business_role || user?.role || '').toUpperCase());
  return <div className={`xz-app ${navOpen ? 'nav-open' : ''}`} dir={direction} data-language={language}>
    <a className="skip-link" href="#workspace-content">Skip to workspace</a>{navOpen && <button className="nav-scrim" aria-label="Close navigation" onClick={() => setNavOpen(false)} />}<aside id="primary-navigation" className="xz-sidebar" aria-label="Primary navigation"><div className="xz-sidebar-brand"><Brand compact /></div><ScrollArea.Root className="xz-nav-scroll"><ScrollArea.Viewport className="xz-nav-viewport">{navigation.filter((group) => group.items.some((item) => item.enabled && (!item.managerOnly || managerLike))).map((group) => <div className="xz-nav-group" key={group.label}><div className="xz-nav-label">{group.label}</div>{group.items.filter((item) => item.enabled && (!item.managerOnly || managerLike)).map((item) => item.enabled ? <Link key={item.key} href={item.href} className={`xz-nav-item ${active === item.key ? 'active' : ''}`} aria-current={active === item.key ? 'page' : undefined} onClick={() => setNavOpen(false)} prefetch><span className="xz-nav-icon" aria-hidden="true"><NavIcon name={item.key}/></span><span>{item.label}</span></Link> : <button key={item.key} className="xz-nav-item disabled" type="button" disabled title={`${item.label} — coming later`}><span className="xz-nav-icon" aria-hidden="true"><NavIcon name={item.key}/></span><span>{item.label}</span><span className="nav-soon">Soon</span></button>)}</div>)}</ScrollArea.Viewport><ScrollArea.Scrollbar className="xz-scrollbar" orientation="vertical"><ScrollArea.Thumb className="xz-scroll-thumb"/></ScrollArea.Scrollbar></ScrollArea.Root><div className="xz-sidebar-footer"><ShieldCheck size={15} strokeWidth={1.8} aria-hidden="true"/><span>Recruitment operations</span><span className="security-dot"/></div></aside>
    <div className="xz-stage"><header className="xz-topbar"><button type="button" className="icon-button mobile-menu-button" aria-label={navOpen ? 'Close navigation' : 'Open navigation'} aria-expanded={navOpen} aria-controls="primary-navigation" onClick={() => setNavOpen(!navOpen)}>{navOpen ? <X size={19}/> : <Menu size={19}/>}</button><div className="mobile-brand"><Brand compact /></div><WorkspaceSelector name={workspaceName} countryName={globalSettings?.country_name || 'Global workspace'} role={user?.role} /><button className="global-search" type="button" onClick={() => setCommandOpen(true)} aria-label="Open global command palette"><Search size={16} strokeWidth={1.8} aria-hidden="true"/><span className="global-search-copy">{shellText.commandPlaceholder || 'Search or jump anywhere…'}</span><kbd>⌘ K</kbd></button><div className="topbar-actions" ref={popoverRef}><div className="topbar-pop-wrap"><button className="icon-button" type="button" onClick={() => { setQuickOpen(!quickOpen); setNotifyOpen(false); setUserOpen(false); }} aria-expanded={quickOpen} aria-label="Quick create"><Plus size={18} strokeWidth={1.8} aria-hidden="true"/></button>{quickOpen && <div className="topbar-pop quick-pop" role="menu"><b>Quick actions</b><Link href="/candidates?action=create" onClick={() => setQuickOpen(false)}>Create candidate <span>Open</span></Link><Link href="/jobs?action=create" onClick={() => setQuickOpen(false)}>Create job <span>Open</span></Link><Link href="/clients?action=create" onClick={() => setQuickOpen(false)}>Create account <span>Open</span></Link><Link href="/contacts?action=create" onClick={() => setQuickOpen(false)}>Create contact <span>Open</span></Link><Link href="/opportunities?action=create" onClick={() => setQuickOpen(false)}>Create opportunity <span>Open</span></Link><Link href="/tasks?action=create" onClick={() => setQuickOpen(false)}>Create task <span>Open</span></Link><Link href="/vendors?action=create" onClick={() => setQuickOpen(false)}>Create vendor <span>Open</span></Link><Link href="/portals" onClick={() => setQuickOpen(false)}>Create portal link <span>Open</span></Link><Link href="/pipeline" onClick={() => setQuickOpen(false)}>Recruitment pipeline <span>Open</span></Link><Link href="/business/pipeline" onClick={() => setQuickOpen(false)}>Business pipeline <span>Open</span></Link><Link href="/interviews?action=create" onClick={() => setQuickOpen(false)}>Schedule interview <span>Open</span></Link></div>}</div><div className="topbar-pop-wrap"><button className="icon-button" type="button" onClick={() => { setNotifyOpen(!notifyOpen); setQuickOpen(false); setUserOpen(false); }} aria-expanded={notifyOpen} aria-label="Notifications"><Bell size={17} strokeWidth={1.8} aria-hidden="true"/></button>{notifyOpen && <div className="topbar-pop notification-pop"><b>Notifications</b><p>Automation exceptions and due actions are kept in one live action center.</p><Link href="/notifications" onClick={() => setNotifyOpen(false)}>Open notification center <span>Open</span></Link>{managerLike?<Link href="/manager" onClick={() => setNotifyOpen(false)}>Manager control <span>Open</span></Link>:null}</div>}</div><div className="topbar-pop-wrap"><button className="user-button" type="button" onClick={() => { setUserOpen(!userOpen); setQuickOpen(false); setNotifyOpen(false); }} aria-expanded={userOpen} aria-label="Open user menu"><span>{(user?.display_name || user?.email || 'R').slice(0,1).toUpperCase()}</span></button>{userOpen && <div className="topbar-pop user-pop"><div className="user-pop-head"><b>{user?.display_name || 'Recruiter'}</b><small>{user?.email}</small><span>{user?.role}</span></div><Link href="/settings" onClick={() => setUserOpen(false)}>Configuration Center</Link><Link href="/settings/global" onClick={() => setUserOpen(false)}>Global settings</Link><form action="/api/auth/logout" method="post"><button type="submit">Sign out</button></form></div>}</div></div></header><main className="xz-content" id="workspace-content" tabIndex={-1}>{children}</main></div>
    <nav className="xz-mobile-nav" aria-label="Mobile navigation"><Link href="/dashboard" className={active === 'home' ? 'active' : ''}><Home size={18}/><small>Home</small></Link><Link href="/recruiter" className={active === 'recruiter-work' ? 'active' : ''}><CheckSquare2 size={18}/><small>My Work</small></Link><button type="button" className="mobile-create" onClick={() => setCommandOpen(true)}><Plus size={19}/><small>Action</small></button><Link href="/candidates" className={active === 'candidates' ? 'active' : ''}><Users size={18}/><small>Candidates</small></Link><button type="button" onClick={() => setCommandOpen(true)}><Search size={18}/><small>Search</small></button></nav>
    <CommandPalette open={commandOpen} onClose={() => setCommandOpen(false)} />
  </div>;
}
