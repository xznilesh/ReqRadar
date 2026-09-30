const isProduction=process.env.NODE_ENV==='production';
const csp=[
  "default-src 'self'",
  "base-uri 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'self'",
  isProduction ? "script-src 'self' 'unsafe-inline'" : "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  "connect-src 'self' https://*.supabase.co wss://*.supabase.co https://api.openai.com",
  "worker-src 'self' blob:",
  "manifest-src 'self'",
  isProduction?"upgrade-insecure-requests":""
].filter(Boolean).join('; ');

const nextConfig={
  poweredByHeader:false,
  reactStrictMode:true,
  experimental:{optimizePackageImports:[]},
  async headers(){
    const headers=[
      {key:'Content-Security-Policy',value:csp},
      {key:'X-Content-Type-Options',value:'nosniff'},
      {key:'X-Frame-Options',value:'DENY'},
      {key:'Referrer-Policy',value:'strict-origin-when-cross-origin'},
      {key:'Permissions-Policy',value:'camera=(), microphone=(), geolocation=(), payment=(), usb=()'},
      {key:'Cross-Origin-Opener-Policy',value:'same-origin'},
      {key:'Cross-Origin-Resource-Policy',value:'same-site'}
    ];
    if(isProduction)headers.push({key:'Strict-Transport-Security',value:'max-age=63072000; includeSubDomains; preload'});
    return [{source:'/(.*)',headers}];
  }
};
export default nextConfig;
