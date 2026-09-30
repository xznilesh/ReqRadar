'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import Brand from '@/app/components/Brand';

export default function Login() {
  const router = useRouter();
  const [error, setError] = useState('');
  const [code, setCode] = useState('');
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [resending, setResending] = useState(false);

  useEffect(() => {
    if (new URLSearchParams(window.location.search).get('error') === 'service') {
      setError('The workspace service is temporarily unavailable. Please try again shortly.');
    }
  }, []);

  async function submit(event) {
    event.preventDefault();
    setBusy(true); setError(''); setCode(''); setNotice('');
    const form = new FormData(event.currentTarget);
    const enteredEmail = String(form.get('email') || '').trim().toLowerCase();
    setEmail(enteredEmail);
    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email: enteredEmail, password: form.get('password') })
      });
      const data = await response.json();
      if (!response.ok) {
        setCode(data.code || '');
        throw new Error(data.error || 'Sign in failed.');
      }
      router.push('/dashboard');
      router.refresh();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  async function resend() {
    if (!email || resending) return;
    setResending(true);
    setNotice('Sending verification email…');
    try {
      const response = await fetch('/api/auth/resend-verification', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email })
      });
      const data = await response.json();
      setNotice(data.message || data.error || 'Check your inbox.');
    } catch {
      setNotice('Could not send the verification email. Check your connection and try again.');
    } finally { setResending(false); }
  }

  return <main className="auth-wrap">
    <section className="auth-art">
      <Brand />
      <div><div className="eyebrow"><span className="dot" />Secure recruiter workspace</div><h1>A clear view of your recruiting day.</h1><p>Your requirements, candidates, submissions and follow-ups, together in one agency workspace.</p></div>
      <small className="muted">Verified email · Secure sessions · Workspace isolation</small>
    </section>
    <section className="auth-main"><div className="form-card">
      <div className="form-kicker">XZ Recruiter</div><h2>Welcome back</h2><div className="muted">Sign in to your agency workspace.</div>
      <form className="form" onSubmit={submit}>
        {error && <div className="form-error" role="alert">{error}</div>}
        {notice && <div className="form-info" role="status">{notice}</div>}
        <div className="field"><label htmlFor="email">Work email</label><input id="email" name="email" type="email" autoComplete="email" required /></div>
        <div className="field"><div className="field-line"><label htmlFor="password">Password</label><Link href="/reset-password">Forgot password?</Link></div><input id="password" name="password" type="password" autoComplete="current-password" required /></div>
        <button className="btn primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in securely →'}</button>
        {code === 'email_unverified' && <button className="btn" type="button" disabled={resending} onClick={resend}>{resending ? 'Sending…' : 'Resend verification email'}</button>}
        <div className="form-note">New to XZ Recruiter? <Link href="/signup">Create a free workspace</Link></div>
      </form>
    </div></section>
  </main>;
}
