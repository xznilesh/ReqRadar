import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  normalizeUploadFilename,assertSafeStoragePath,validatePrivateUpload,MAX_PRIVATE_UPLOAD_BYTES
} from '../lib/file-security.js';

const pdf=Buffer.from('%PDF-1.4\n%secure');
const png=Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00]);
const jpeg=Buffer.from([0xff,0xd8,0xff,0xdb,0x00]);
const txt=Buffer.from('plain UTF-8 resume text');
const docx=Buffer.concat([Buffer.from([0x50,0x4b,0x03,0x04]),Buffer.from('....[Content_Types].xml....word/document.xml....')]);

assert.equal(validatePrivateUpload({bytes:pdf,mimeType:'application/pdf',filename:'resume.pdf',sizeBytes:pdf.length}).extension,'pdf');
assert.equal(validatePrivateUpload({bytes:png,mimeType:'image/png',filename:'photo.png',sizeBytes:png.length}).extension,'png');
assert.equal(validatePrivateUpload({bytes:jpeg,mimeType:'image/jpeg',filename:'photo.jpg',sizeBytes:jpeg.length}).extension,'jpg');
assert.equal(validatePrivateUpload({bytes:txt,mimeType:'text/plain',filename:'resume.txt',sizeBytes:txt.length}).extension,'txt');
assert.equal(validatePrivateUpload({bytes:docx,mimeType:'application/vnd.openxmlformats-officedocument.wordprocessingml.document',filename:'resume.docx',sizeBytes:docx.length}).extension,'docx');

assert.throws(()=>validatePrivateUpload({bytes:pdf,mimeType:'text/plain',filename:'resume.txt',sizeBytes:pdf.length}),/file_content_mismatch/);
assert.throws(()=>validatePrivateUpload({bytes:txt,mimeType:'application/pdf',filename:'resume.pdf',sizeBytes:txt.length}),/file_content_mismatch/);
assert.throws(()=>validatePrivateUpload({bytes:pdf,mimeType:'application/pdf',filename:'resume.exe',sizeBytes:pdf.length}),/file_extension_mismatch/);
assert.throws(()=>validatePrivateUpload({bytes:Buffer.alloc(0),mimeType:'text/plain',filename:'x.txt',sizeBytes:0}),/invalid_file_size/);
assert.throws(()=>validatePrivateUpload({bytes:Buffer.alloc(MAX_PRIVATE_UPLOAD_BYTES+1),mimeType:'text/plain',filename:'x.txt',sizeBytes:MAX_PRIVATE_UPLOAD_BYTES+1}),/invalid_file_size/);

for(const bad of ['../tenant/file.pdf','tenant/../../file.pdf','/absolute/file.pdf','tenant\\file.pdf','tenant/%2e%2e/file.pdf','tenant//file.pdf']){
  assert.throws(()=>assertSafeStoragePath(bad),/unsafe_storage_path/);
}
assert.equal(assertSafeStoragePath('agency/candidate/uuid/resume.pdf'),'agency/candidate/uuid/resume.pdf');

const normalized=normalizeUploadFilename('../../<script>alert(1)</script>.pdf');
assert.ok(!normalized.includes('/')&&!normalized.includes('\\')&&!normalized.includes('<')&&!normalized.includes('>'));
assert.ok(normalized.length<=120);

const storage=fs.readFileSync('lib/server-storage.js','utf8');
const scanner=fs.readFileSync('lib/malware-scan.js','utf8');
assert.ok(storage.includes("Math.max(15,Math.min(Number(expiresIn||60),60))"),'signed URL TTL must be clamped to <=60s');
assert.ok(storage.includes("'x-upsert':'false'"),'private uploads must not overwrite existing objects');
assert.ok(storage.includes('assertSafeStoragePath'),'server storage must validate server-generated object paths');
assert.ok(!/getPublicUrl|\/object\/public\//.test(storage),'private storage helper must never generate public URLs');
assert.ok(storage.includes('await scanPrivateUpload'),'all private storage writes must pass through the malware scanning abstraction');
assert.ok(scanner.includes('XZRECRUITER_MALWARE_SCAN_URL')&&scanner.includes('XZRECRUITER_MALWARE_SCAN_TOKEN'),'scanner configuration must remain environment managed');
assert.ok(scanner.includes("throw new Error('malware_scan_not_configured')")&&scanner.includes("throw new Error('malware_detected')"),'scanner must fail closed when unavailable and block malicious files');
assert.ok(scanner.includes('XZRECRUITER_ALLOW_UNSCANNED_UPLOADS')&&scanner.includes("process.env.NODE_ENV!=='production'"),'unscanned bypass must be explicit and impossible in production');
assert.ok(scanner.includes('AbortController')&&scanner.includes('SCAN_TIMEOUT_MS'),'configured scanner calls must be timeout bounded');

for(const route of ['app/api/ats/document/route.js','app/api/ats/attachment/route.js']){
  const c=fs.readFileSync(route,'utf8');
  assert.ok(c.includes('createSignedPrivateUrl'),'private download route must use short-lived signing');
  assert.ok(/atsAction\([^\n]*(Access|access)/.test(c),'signed URL must be issued only after server authorization RPC');
}

console.log('STEP7_FILE_SECURITY_PASS magic=true mime=true extension=true traversal=true private_storage=true signed_ttl=true malware_fail_closed=true');
