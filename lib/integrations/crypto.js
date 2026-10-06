import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

function key(){
  const raw=String(process.env.XZRECRUITER_INTEGRATION_ENCRYPTION_KEY||'').trim();
  if(!raw)throw new Error('integration_encryption_key_missing');
  let decoded;
  try{decoded=Buffer.from(raw,'base64')}catch{decoded=Buffer.alloc(0)}
  if(decoded.length!==32)throw new Error('integration_encryption_key_invalid');
  return decoded;
}
function aad(value){return Buffer.from(String(value||''),'utf8')}

export function encryptIntegrationSecret(value,{agencyId,userId,provider,kind}){
  if(value===null||value===undefined||value==='')return null;
  const iv=randomBytes(12);
  const cipher=createCipheriv('aes-256-gcm',key(),iv);
  cipher.setAAD(aad(`${agencyId}:${userId}:${provider}:${kind}`));
  const encrypted=Buffer.concat([cipher.update(String(value),'utf8'),cipher.final()]);
  const tag=cipher.getAuthTag();
  return ['v1',iv.toString('base64url'),tag.toString('base64url'),encrypted.toString('base64url')].join('.');
}

export function decryptIntegrationSecret(envelope,{agencyId,userId,provider,kind}){
  if(!envelope)return null;
  const [version,ivRaw,tagRaw,dataRaw]=String(envelope).split('.');
  if(version!=='v1'||!ivRaw||!tagRaw||!dataRaw)throw new Error('integration_secret_invalid');
  const decipher=createDecipheriv('aes-256-gcm',key(),Buffer.from(ivRaw,'base64url'));
  decipher.setAAD(aad(`${agencyId}:${userId}:${provider}:${kind}`));
  decipher.setAuthTag(Buffer.from(tagRaw,'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(dataRaw,'base64url')),decipher.final()]).toString('utf8');
}
