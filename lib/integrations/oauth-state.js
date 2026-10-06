import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

export function createOauthState(){
  const state=randomBytes(32).toString('base64url');
  const verifier=randomBytes(48).toString('base64url');
  const challenge=createHash('sha256').update(verifier).digest('base64url');
  return {state,verifier,challenge};
}
export function oauthStateMatches(expected,received){
  const a=Buffer.from(String(expected||'')),b=Buffer.from(String(received||''));
  return a.length>0&&a.length===b.length&&timingSafeEqual(a,b);
}
export function integrationCookieOptions(maxAge=600){
  return {httpOnly:true,secure:process.env.NODE_ENV==='production',sameSite:'lax',path:'/',maxAge};
}
