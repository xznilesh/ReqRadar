'use client';
import { useModalDialog } from '@/lib/use-modal-dialog';

import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';

export const commandCatalog = [
  { id: 'home', label: 'Go to Home', keywords: 'dashboard home radar', href: '/dashboard', group: 'Navigate', enabled: true },
  { id: 'candidates', label: 'Open Candidates', keywords: 'candidate people resume cv', href: '/candidates', group: 'Recruitment', enabled: true },
  { id: 'jobs', label: 'Open Jobs', keywords: 'job requisition vacancy role', href: '/jobs', group: 'Recruitment', enabled: true },
  { id: 'pipeline', label: 'Open Recruitment Pipeline', keywords: 'application stage shortlist workflow', href: '/pipeline', group: 'Recruitment', enabled: true },
  { id: 'interviews', label: 'Open Interviews', keywords: 'interview schedule calendar', href: '/interviews', group: 'Recruitment', enabled: true },
  { id: 'offers', label: 'Open Offers', keywords: 'offer compensation salary', href: '/offers', group: 'Recruitment', enabled: true },
  { id: 'placements', label: 'Open Placements', keywords: 'placement hire fee revenue', href: '/placements', group: 'Recruitment', enabled: true },
  { id: 'clients', label: 'Open Clients & Accounts', keywords: 'client account prospect crm business', href: '/clients', group: 'Business', enabled: true },
  { id: 'contacts', label: 'Open Contacts', keywords: 'decision maker hiring manager contact people crm', href: '/contacts', group: 'Business', enabled: true },
  { id: 'opportunities', label: 'Open Opportunities', keywords: 'opportunity deal business revenue pipeline crm', href: '/opportunities', group: 'Business', enabled: true },
  { id: 'business-pipeline', label: 'Open Business Pipeline', keywords: 'bd sales target lead client placement revenue', href: '/business/pipeline', group: 'Business', enabled: true },
  { id: 'vendors', label: 'Open Vendors & Partners', keywords: 'vendor sourcing partner agency subcontractor', href: '/vendors', group: 'Business', enabled: true },
  { id: 'portals', label: 'Open Client & Vendor Portals', keywords: 'portal client vendor collaboration external secure', href: '/portals', group: 'Business', enabled: true },
  { id: 'tasks', label: 'Open Tasks', keywords: 'task follow up action due reminder', href: '/tasks', group: 'Productivity', enabled: true },
  { id: 'create-candidate', label: 'Create candidate', keywords: 'new candidate quick create', href: '/candidates?action=create', group: 'Quick create', enabled: true },
  { id: 'create-job', label: 'Create job', keywords: 'new job quick create', href: '/jobs?action=create', group: 'Quick create', enabled: true },
  { id: 'create-client', label: 'Create client or prospect account', keywords: 'new client account prospect crm', href: '/clients?action=create', group: 'Quick create', enabled: true },
  { id: 'create-contact', label: 'Create contact', keywords: 'new decision maker hiring manager crm', href: '/contacts?action=create', group: 'Quick create', enabled: true },
  { id: 'create-opportunity', label: 'Create opportunity', keywords: 'new deal business opportunity revenue', href: '/opportunities?action=create', group: 'Quick create', enabled: true },
  { id: 'create-task', label: 'Create follow-up task', keywords: 'task action reminder follow up', href: '/tasks?action=create', group: 'Quick create', enabled: true },
  { id: 'create-vendor', label: 'Create vendor or sourcing partner', keywords: 'new vendor sourcing partner', href: '/vendors?action=create', group: 'Quick create', enabled: true },
  { id: 'create-portal', label: 'Create collaboration portal link', keywords: 'client vendor portal secure link', href: '/portals', group: 'Quick create', enabled: true },
  { id: 'schedule-interview', label: 'Schedule interview', keywords: 'calendar event interview', href: '/interviews?action=create', group: 'Quick create', enabled: true },
  { id: 'agency-setup', label: 'Open agency setup', keywords: 'onboarding quick setup advanced setup agency profile', href: '/onboarding?edit=1', group: 'Configure', enabled: true },
  { id: 'settings-center', label: 'Open Configuration Center', keywords: 'settings company size industry pipeline territory custom fields views', href: '/settings', group: 'Configure', enabled: true },
  { id: 'global-settings', label: 'Open global settings', keywords: 'country locale currency timezone language settings', href: '/settings/global', group: 'Configure', enabled: true },
  { id: 'csv-import', label: 'Import CSV data', keywords: 'import company client contact candidate csv mapping', href: '/import', group: 'Configure', enabled: true },
  { id: 'recruitment-pipeline', label: 'Configure recruitment pipelines', keywords: 'pipeline stages screening offer placed workflow', href: '/onboarding?section=pipelines&edit=1', group: 'Configure', enabled: true },
  { id: 'company-icp', label: 'Configure Company ICP', keywords: 'company size funding target account growth', href: '/onboarding?section=icp&edit=1', group: 'Configure', enabled: true },
  { id: 'search-company', label: 'Search company intelligence', keywords: 'company hiring radar signal', group: 'Intelligence', enabled: false },
  { id: 'matches', label: 'Open Candidate Intelligence Matches', keywords: 'match fit candidate job', group: 'Intelligence', enabled: false }
];

const RECENTS_KEY = 'xz:recent-commands';

export default function CommandPalette({ open, onClose }) {
  const router = useRouter();
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const [recentIds, setRecentIds] = useState([]);
  const inputRef = useRef(null);

  useEffect(() => { try { setRecentIds(JSON.parse(localStorage.getItem(RECENTS_KEY) || '[]')); } catch {} }, []);
  const items = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (q) return commandCatalog.filter((item) => item.enabled && `${item.label} ${item.keywords}`.toLowerCase().includes(q));
    const recent = recentIds.map((id) => commandCatalog.find((item) => item.id === id)).filter(Boolean).map((item) => ({ ...item, group: 'Recent' }));
    return [...recent, ...commandCatalog.filter((item) => item.enabled && !recentIds.includes(item.id))];
  }, [query, recentIds]);

  useEffect(() => { if (!open) return; setQuery(''); setActive(0); const timer = setTimeout(() => inputRef.current?.focus(), 20); return () => clearTimeout(timer); }, [open]);
  useEffect(() => { if (active >= items.length) setActive(Math.max(0, items.length - 1)); }, [items.length, active]);
  useModalDialog(open, onClose, '.command-palette');
  if (!open) return null;

  function run(item) {
    if (!item?.enabled || !item.href) return;
    const next = [item.id, ...recentIds.filter((id) => id !== item.id)].slice(0, 5);
    setRecentIds(next); try { localStorage.setItem(RECENTS_KEY, JSON.stringify(next)); } catch {}
    onClose?.(); router.push(item.href);
  }
  function keyDown(event) {
    if (event.key === 'Escape') { event.preventDefault(); onClose?.(); }
    if (event.key === 'ArrowDown') { event.preventDefault(); setActive((v) => Math.min(v + 1, items.length - 1)); }
    if (event.key === 'ArrowUp') { event.preventDefault(); setActive((v) => Math.max(v - 1, 0)); }
    if (event.key === 'Enter') { event.preventDefault(); run(items[active]); }
  }
  return <div className="command-backdrop" role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose?.(); }}><section className="command-palette" role="dialog" aria-modal="true" aria-label="Global command palette" onKeyDown={keyDown}><div className="command-search-row"><span aria-hidden="true">⌕</span><input ref={inputRef} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search or jump anywhere…" aria-label="Search commands" /><kbd>Esc</kbd></div><div className="command-results" role="listbox">{items.length ? items.map((item, index) => <button key={`${item.group}-${item.id}`} type="button" className={`command-item ${index === active ? 'active' : ''}`} onMouseEnter={() => setActive(index)} onClick={() => run(item)} disabled={!item.enabled} role="option" aria-selected={index === active}><span><b>{item.label}</b><small>{item.group}</small></span>{item.enabled ? <span className="command-enter">↵</span> : <span className="coming-chip">Coming later</span>}</button>) : <div className="command-empty">No matching command.</div>}</div><footer className="command-footer"><span>↑↓ Navigate</span><span>Enter Open</span><span>⌘/Ctrl + K Anywhere</span></footer></section></div>;
}
