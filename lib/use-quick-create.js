'use client';

import { useEffect, useRef } from 'react';

// Open once when entering a quick-create URL; closing the form must keep it closed.
export function useQuickCreate(action, onCreate) {
  const latest = useRef(onCreate);
  useEffect(() => { latest.current = onCreate; });
  useEffect(() => { if (action === 'create') latest.current(); }, [action]);
}
