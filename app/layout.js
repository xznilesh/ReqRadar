import './globals.css';
import './foundation.css';
import './step2.css';
import './step2-jd-brain.css';
import './step3.css';
import './step3-recruiter-execution.css';
import './step3-extra.css';
import './step4.css';
import './step4-candidate-intelligence.css';
import './step4-closeout.css';
import './step4-stage-guard.css';
import './step4-final-quality.css';
import './step5.css';
import './step5-extra.css';
import './step5-closeout.css';
import './step5-screening.css';
import './step6-submission.css';
import './step8-manager-control.css';
import './enterprise.css';

export const metadata = {
  title: 'XZ Recruiter — Recruitment Operations',
  description: 'A connected recruiting workspace for requirements, candidates, submissions, interviews, offers and placements.',
  icons: { icon: '/xzrecruiter-logo.svg' }
};

export default function RootLayout({ children }) {
  return <html lang="en"><body>{children}</body></html>;
}
