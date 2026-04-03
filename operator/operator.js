#!/usr/bin/env node
const https = require('https'), http = require('http'), fs = require('fs');
const MEROSTONE = process.env.MEROSTONE_URL || 'https://merostone.eose.ca';
const SILO = process.env.SILO || 'ct-fac';
const INTERVAL = parseInt(process.env.INTERVAL_MS || '60000');
const K8S = `https://${process.env.KUBERNETES_SERVICE_HOST}:${process.env.KUBERNETES_SERVICE_PORT}`;
const TOKEN = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token','utf8').trim();
const CA = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/ca.crt');
const agent = new https.Agent({ca:CA});
const k = p => new Promise(r => {
  https.get({hostname:process.env.KUBERNETES_SERVICE_HOST,port:process.env.KUBERNETES_SERVICE_PORT,path:p,headers:{'Authorization':`Bearer ${TOKEN}`},agent},(res)=>{
    let d=''; res.on('data',x=>d+=x); res.on('end',()=>{try{r(JSON.parse(d))}catch{r({})}});
  }).on('error',()=>r({}));
});
async function tick() {
  const [pods,nodes,ns] = await Promise.all([k('/api/v1/pods'),k('/api/v1/nodes'),k('/api/v1/namespaces')]);
  const state = {silo:SILO,ts:new Date().toISOString(),
    pods:{total:(pods.items||[]).length,running:(pods.items||[]).filter(p=>p.status?.phase==='Running').length},
    nodes:(nodes.items||[]).length, namespaces:(ns.items||[]).length,
    health:(pods.items||[]).filter(p=>p.status?.phase==='Failed').length===0?'green':'degraded'};
  console.log(`[${state.ts}] pods:${state.pods.total} nodes:${state.nodes} ns:${state.namespaces} health:${state.health}`);
  const body = JSON.stringify({domain:SILO,type:'cluster.heartbeat',title:`${SILO} heartbeat`,content:JSON.stringify(state)});
  const u = new URL(`${MEROSTONE}/api/ingest`);
  const lib = u.protocol==='https:'?https:http;
  const req = lib.request({hostname:u.hostname,port:u.port||(u.protocol==='https:'?443:80),path:u.pathname,method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},res=>{
    let d=''; res.on('data',x=>d+=x); res.on('end',()=>console.log(`ingest → ${res.statusCode} ${d.slice(0,60)}`));
  }); req.on('error',e=>console.error(`ingest err: ${e.message}`)); req.write(body); req.end();
}
console.log(`EOSE operator — silo:${SILO} → ${MEROSTONE}`);
tick(); setInterval(tick, INTERVAL);
