import {writeFile, copyFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const evidence='/home/work/.no-mistakes/evidence/01M7RF315GNV72PXTS8QBDNV5Q';
const board=process.cwd()+'/.phase-progress/live-home/.lavish/bearings-board.html';
const targets=await (await fetch('http://127.0.0.1:49138/json/list')).json();
const tab=targets.find(t=>t.type==='page');
const ws=new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
let seq=0; const requests=new Map();
ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=requests.get(m.id);requests.delete(m.id);m.error?p.reject(m.error):p.resolve(m.result)}};
function call(method,params={}){return new Promise((resolve,reject)=>{const id=++seq;requests.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}))})}
async function evaluate(expression){const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value}
try {
 await call('Page.enable');
 await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1400,deviceScaleFactor:1,mobile:false});
 await call('Page.navigate',{url:'file://'+board+'#underway'});
 for(let i=0;i<60;i++){if(await evaluate('document.querySelectorAll("#bb-underway .bb-row").length===12'))break;await new Promise(r=>setTimeout(r,100))}
 const expression=`[...document.querySelectorAll('#bb-underway .bb-row')].map(r=>({title:r.querySelector('.bb-row__title')?.textContent,text:r.innerText,bars:[...r.querySelectorAll('progress')].map(p=>({label:p.getAttribute('aria-label'),value:p.value,text:p.getAttribute('aria-valuetext')}))}))`;
 const rows=await evaluate(expression);
 assert.equal(rows.length,12);
 assert.equal(rows[0].bars.at(-1).value,33);assert.match(rows[0].text,/212 of 643 tests/);
 assert.equal(rows[1].bars.at(-1).value,50);assert.equal(rows[2].bars.at(-1).value,3);
 assert.match(rows[1].text,/about 50%/);assert.match(rows[2].text,/about 3%/);
 assert.match(rows[3].text,/unadjusted/);
 assert.match(rows[4].text,/waiting for the shared test slot/);assert.match(rows[4].text,/1 other task waiting/);assert.equal(rows[4].bars.length,1);
 assert.match(rows[5].text,/fix round 2/);assert.equal(rows[5].bars.length,1);
 assert.match(rows[6].text,/waiting on a decision/);assert.equal(rows[6].bars.length,1);
 assert.match(rows[7].text,/Lint/);assert.match(rows[7].text,/30s/);assert.equal(rows[7].bars.length,1);
 assert.match(rows[8].text,/about 20%/);assert.equal(rows[11].bars.length,1);assert.match(rows[11].text,/3 tests/);
 await writeFile(evidence+'/browser-observations.json',JSON.stringify({source:'real board build; seeded canonical projection, not a running check job',rows},null,2));
 let layout=await call('Page.getLayoutMetrics');
 let shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true,clip:{x:0,y:0,width:1440,height:Math.ceil(layout.cssContentSize.height),scale:1}});
 await writeFile(evidence+'/board-desktop.png',Buffer.from(shot.data,'base64'));
 await call('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
 await evaluate('new Promise(r=>setTimeout(r,200))');
 const mobile=await evaluate(`({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,rows:document.querySelectorAll('#bb-underway .bb-row').length})`);
 await writeFile(evidence+'/browser-mobile.json',JSON.stringify(mobile,null,2));
 layout=await call('Page.getLayoutMetrics');
 shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true,clip:{x:0,y:0,width:390,height:Math.ceil(layout.cssContentSize.height),scale:1}});
 await writeFile(evidence+'/board-mobile.png',Buffer.from(shot.data,'base64'));
 assert.ok(mobile.scrollWidth<=mobile.width,JSON.stringify(mobile));
 await copyFile(board,evidence+'/rendered-board.html');
 console.log('Real board opened in Chromium at desktop and mobile sizes. Count=33%; estimates=about 50% and about 3%; unadjusted qualifier visible; queue/fix/decision/lint have no checks fill; no mobile horizontal overflow.');
} finally {ws.close()}
