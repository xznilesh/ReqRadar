import Image from 'next/image';
import Link from 'next/link';

export default function Brand({ href = '/', compact = false }) {
  const markWidth = compact ? 58 : 68;
  const markHeight = compact ? 30 : 35;

  const brand = (
    <>
      <Image
        className="brand-logo"
        src="/xz-monogram.svg"
        alt=""
        aria-hidden="true"
        width={markWidth}
        height={markHeight}
        priority
        unoptimized
        style={{ width: markWidth, height: markHeight, objectFit: 'contain', flex: '0 0 auto' }}
      />
      <span
        className="brandname"
        style={{ fontSize: compact ? 20 : 22, fontWeight: 750, lineHeight: 1 }}
      >
        Recruiter
      </span>
    </>
  );

  return href
    ? <Link className="brand" href={href} aria-label="XZ Recruiter home">{brand}</Link>
    : <div className="brand" aria-label="XZ Recruiter">{brand}</div>;
}
