'use client';

import { useEffect, useMemo, useState } from 'react';

export default function EnterpriseTable({
  columns = [], rows = [], rowKey = 'id', loading = false, error = '', emptyText = 'No records yet.',
  pageSize = 25, totalRows, serverMode = false, onQueryChange, bulkActions = [], rowActions = [], storageKey = 'xz-table',
  savedViews: persistedSavedViews = null, onSaveView, onApplyView
}) {
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState({ key: '', direction: 'asc' });
  const [page, setPage] = useState(1);
  const [selected, setSelected] = useState(new Set());
  const [visible, setVisible] = useState(() => columns.map((c) => c.key));
  const [columnOrder, setColumnOrder] = useState(() => columns.map((c) => c.key));
  const [showColumns, setShowColumns] = useState(false);
  const [localSavedViews, setLocalSavedViews] = useState([]);
  const savedViews = Array.isArray(persistedSavedViews) ? persistedSavedViews : localSavedViews;

  useEffect(() => {
    if (Array.isArray(persistedSavedViews)) return;
    try { setLocalSavedViews(JSON.parse(localStorage.getItem(`${storageKey}:views`) || '[]')); } catch {}
  }, [storageKey, persistedSavedViews]);

  useEffect(() => {
    if (!serverMode || !onQueryChange) return;
    const timer = setTimeout(() => onQueryChange({ search, sort, page, pageSize }), 180);
    return () => clearTimeout(timer);
  }, [search, sort, page, pageSize, serverMode, onQueryChange]);

  const orderedColumns = useMemo(() => columnOrder.map((key) => columns.find((c) => c.key === key)).filter(Boolean).filter((c) => visible.includes(c.key)), [columns, columnOrder, visible]);
  const processed = useMemo(() => {
    if (serverMode) return rows;
    const q = search.trim().toLowerCase();
    let data = q ? rows.filter((row) => orderedColumns.some((col) => String(row[col.key] ?? '').toLowerCase().includes(q))) : [...rows];
    if (sort.key) data.sort((a, b) => {
      const av = a[sort.key], bv = b[sort.key];
      const result = typeof av === 'number' && typeof bv === 'number' ? av - bv : String(av ?? '').localeCompare(String(bv ?? ''));
      return sort.direction === 'asc' ? result : -result;
    });
    return data;
  }, [rows, orderedColumns, search, sort, serverMode]);

  const count = serverMode ? (totalRows ?? rows.length) : processed.length;
  const pages = Math.max(1, Math.ceil(count / pageSize));
  const pageRows = serverMode ? processed : processed.slice((page - 1) * pageSize, page * pageSize);
  const pageIds = pageRows.map((r) => String(r[rowKey]));
  const allPageSelected = pageIds.length > 0 && pageIds.every((id) => selected.has(id));

  useEffect(() => { setPage((current) => Math.min(current, pages)); }, [pages]);
  useEffect(() => { setSelected(new Set()); }, [search, sort, page]);

  function toggleAll() { setSelected((current) => { const next = new Set(current); if (allPageSelected) pageIds.forEach((id) => next.delete(id)); else pageIds.forEach((id) => next.add(id)); return next; }); }
  function toggleRow(id) { setSelected((current) => { const next = new Set(current); next.has(id) ? next.delete(id) : next.add(id); return next; }); }
  function sortBy(column) { if (column.sortable === false) return; setSort((current) => current.key === column.key ? { key: column.key, direction: current.direction === 'asc' ? 'desc' : 'asc' } : { key: column.key, direction: 'asc' }); setPage(1); }
  function moveColumn(key, delta) { setColumnOrder((order) => { const from = order.indexOf(key), to = Math.max(0, Math.min(order.length - 1, from + delta)); if (from < 0 || from === to) return order; const next = [...order]; const [item] = next.splice(from, 1); next.splice(to, 0, item); return next; }); }

  async function saveView() {
    const name = window.prompt('Saved view name');
    if (!name) return;
    const view = { name, search, sort, visible, columnOrder, pageSize };
    if (onSaveView) {
      await onSaveView(view);
      return;
    }
    const next = [...localSavedViews.filter((v) => v.name !== name), view];
    setLocalSavedViews(next);
    try { localStorage.setItem(`${storageKey}:views`, JSON.stringify(next)); } catch {}
  }

  function applyView(view) {
    const searchValue = view.search ?? '';
    const sortValue = view.sort || view.sort_config?.[0] || { key: '', direction: 'asc' };
    const visibleValue = view.visible || view.visible_columns || columns.map((c) => c.key);
    const orderValue = view.columnOrder || view.column_order || columns.map((c) => c.key);
    setSearch(searchValue); setSort(sortValue); setVisible(visibleValue); setColumnOrder(orderValue); setPage(1);
    onApplyView?.(view);
  }

  function keySelect(event, index) {
    if (event.target !== event.currentTarget) return;
    if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); toggleRow(String(pageRows[index][rowKey])); }
    if (event.key === 'ArrowDown') { event.preventDefault(); event.currentTarget.nextElementSibling?.focus(); }
    if (event.key === 'ArrowUp') { event.preventDefault(); event.currentTarget.previousElementSibling?.focus(); }
  }

  return <section className="enterprise-table" aria-busy={loading}>
    <div className="table-toolbar"><label className="table-search"><span aria-hidden="true">⌕</span><input value={search} onChange={(e) => { setSearch(e.target.value); setPage(1); }} placeholder="Search this view" aria-label="Search table" /></label><div className="table-toolbar-actions">
      {selected.size > 0 && bulkActions.map((action) => <button key={action.label} type="button" onClick={() => action.onClick?.([...selected])}>{action.label} ({selected.size})</button>)}
      <div className="table-view-wrap"><button type="button" aria-expanded={showColumns} onClick={() => setShowColumns(!showColumns)}>Columns</button>{showColumns && <div className="table-column-menu">{columns.map((column) => <div key={column.key} className="column-menu-row"><label><input type="checkbox" checked={visible.includes(column.key)} onChange={() => setVisible((v) => v.includes(column.key) ? v.filter((x) => x !== column.key) : [...v, column.key])} /> {column.label}</label><span><button type="button" onClick={() => moveColumn(column.key, -1)} aria-label={`Move ${column.label} left`}>←</button><button type="button" onClick={() => moveColumn(column.key, 1)} aria-label={`Move ${column.label} right`}>→</button></span></div>)}</div>}</div>
      <button type="button" onClick={saveView}>Save view</button>{savedViews.length > 0 && <select aria-label="Saved views" defaultValue="" onChange={(e) => applyView(savedViews.find((v) => (v.id || v.name) === e.target.value || v.name === e.target.value) || {})}><option value="" disabled>Saved views</option>{savedViews.map((view) => <option key={view.id || view.name} value={view.id || view.name}>{view.name}</option>)}</select>}
    </div></div>

    {error ? <div className="table-state error" role="alert"><b>Couldn’t load this view.</b><span>{error}</span></div> : loading ? <div className="table-skeleton" aria-label="Loading records">{Array.from({ length: 6 }).map((_, i) => <i key={i}/>)}</div> : !pageRows.length ? <div className="table-state empty"><b>{emptyText}</b><span>Try another search or create your first record.</span></div> : <div className="table-scroll" role="region" aria-label="Data table" tabIndex="0"><table><thead><tr><th className="select-col"><input type="checkbox" checked={allPageSelected} onChange={toggleAll} aria-label="Select page" /></th>{orderedColumns.map((column) => <th key={column.key} aria-sort={sort.key === column.key ? (sort.direction === 'asc' ? 'ascending' : 'descending') : 'none'}><button type="button" onClick={() => sortBy(column)} disabled={column.sortable === false}>{column.label}{sort.key === column.key ? (sort.direction === 'asc' ? ' ↑' : ' ↓') : ''}</button></th>)}{rowActions.length > 0 && <th className="actions-col">Actions</th>}</tr></thead><tbody>{pageRows.map((row, index) => { const id = String(row[rowKey]); return <tr key={id} tabIndex="0" onKeyDown={(e) => keySelect(e, index)} className={selected.has(id) ? 'selected' : ''}><td><input type="checkbox" checked={selected.has(id)} onChange={() => toggleRow(id)} aria-label={`Select row ${index + 1}`} /></td>{orderedColumns.map((column) => <td key={column.key} data-label={column.label}>{column.render ? column.render(row[column.key], row) : String(row[column.key] ?? '—')}</td>)}{rowActions.length > 0 && <td className="row-actions">{rowActions.map((action) => <button key={action.label} type="button" onClick={() => action.onClick?.(row)}>{action.label}</button>)}</td>}</tr>; })}</tbody></table></div>}

    <footer className="table-pagination"><span>{count ? `${(page - 1) * pageSize + 1}–${Math.min(page * pageSize, count)} of ${count}` : '0 records'}</span><div><button type="button" onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page <= 1}>Previous</button><span>Page {page} / {pages}</span><button type="button" onClick={() => setPage((p) => Math.min(pages, p + 1))} disabled={page >= pages}>Next</button></div></footer>
  </section>;
}
