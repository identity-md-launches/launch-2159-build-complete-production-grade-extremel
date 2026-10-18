import type { CSSProperties } from 'react';

const paths = {
  jackpot: <><path d="m12 3 3 5 6 1-4 5 1 6-6-3-6 3 1-6-4-5 6-1Z"/><path d="m10 11 2 3 2-3"/></>,
  dashboard: <><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></>,
  activity: <><path d="M3 12h4l3-8 4 16 3-8h4"/></>,
  help: <><circle cx="12" cy="12" r="9"/><path d="M9.1 9a3 3 0 0 1 5.8 1c0 2-3 2-3 4m.1 3h.01"/></>,
  arrow: <><path d="M4 12h15m-6-6 6 6-6 6"/></>,
  external: <><path d="M14 4h6v6m0-6L10 14m0-10H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5"/></>,
  wallet: <><path d="M20 8V5a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15v12H5a2 2 0 0 1-2-2V6m17 6h-5v4h5"/><path d="M17 14h.01"/></>,
  ticket: <><path d="m3 8 5-5 3 3a3 3 0 0 0 4 4l6 6-5 5-6-6a3 3 0 0 0-4-4Z"/><path d="m12 10 2 2m2 2 2 2"/></>,
  clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
  flame: <path d="M12 3c2 5-3 6 0 10 2-1 3-3 3-5 4 4 5 7 3 10-3 4-10 4-13-1-2-4 1-7 3-9-1 4 0 5 1 6 3-3 2-7 3-11Z"/>,
  shield: <><path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/></>,
  trophy: <><path d="M7 3h10v7a5 5 0 0 1-10 0Zm5 12v6m-4 0h8M7 5H3v3a4 4 0 0 0 4 4m10-7h4v3a4 4 0 0 1-4 4"/></>,
  people: <><circle cx="9" cy="8" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3m2-16a3 3 0 0 1 0 6m1 4a5 5 0 0 1 3 4v2"/></>,
  refresh: <><path d="M20 7v5h-5M4 17v-5h5m-4-4a8 8 0 0 1 13-3l2 3M4 16l2 3a8 8 0 0 0 13-3"/></>,
  chevron: <path d="m8 10 4 4 4-4"/>,
  close: <path d="m6 6 12 12M6 18 18 6"/>,
  check: <path d="m5 12 4 4L19 6"/>,
  lock: <><rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 4v3"/></>,
  bolt: <path d="m13 2-9 12h7l-1 8 10-13h-8Z"/>,
  minus: <path d="M5 12h14"/>,
  plus: <path d="M5 12h14M12 5v14"/>,
  ethereum: <><path d="m12 2 6 10-6 4-6-4 6-10Zm-6 12 6 8 6-8m-6-12v14"/></>,
  info: <><circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10h.01"/></>,
  coin: <><circle cx="12" cy="12" r="9"/><path d="M9 8h6m-6 8h6m-3-8v8"/></>,
} as const;

export function Icon({ name, size = 20, className = '', style }: { name: keyof typeof paths; size?: number; className?: string; style?: CSSProperties }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className} style={style}>{paths[name]}</svg>;
}

export function Chip({ className = '' }: { className?: string }) {
  return <svg viewBox="0 0 64 64" fill="none" aria-hidden="true" className={`chip ${className}`}>
    <circle cx="32" cy="32" r="30" fill="currentColor"/>
    <circle cx="32" cy="32" r="25" stroke="#172015" strokeWidth="5" strokeDasharray="11 8.635"/>
    <circle cx="32" cy="32" r="18" stroke="#172015" strokeWidth="1.5"/>
    <path d="m32 19 4 8 9 1-6.5 6.5L40 44l-8-4-8 4 1.5-9.5L19 28l9-1Z" fill="#172015"/>
  </svg>;
}
