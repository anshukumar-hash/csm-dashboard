const fs=require('fs');
const {matchPartner,CATFIELD,norm}=require('./partners_match.js');
function parseCSV(t){const rows=[];let i=0,f='',row=[],q=false;t=t.replace(/\r/g,'');
  while(i<t.length){const c=t[i];
    if(q){if(c=='"'){if(t[i+1]=='"'){f+='"';i+=2;continue;}q=false;i++;continue;}f+=c;i++;continue;}
    if(c=='"'){q=true;i++;continue;} if(c==','){row.push(f);f='';i++;continue;}
    if(c=='\n'){row.push(f);rows.push(row);row=[];f='';i++;continue;} f+=c;i++;}
  if(f.length||row.length){row.push(f);rows.push(row);} return rows;}
const R=p=>parseCSV(fs.readFileSync(__dirname+'/'+p,'utf8'));
const num=s=>{const m=(s||'').replace(/[^0-9.]/g,'');return m?Math.round(parseFloat(m)):0;};

const live=R('live_accounts.csv'), onb=R('onb_accounts.csv');
const lh=live[0].map(x=>x.trim()), oh=onb[0].map(x=>x.trim());
const li=Object.fromEntries(lh.map((h,i)=>[h,i])), oi=Object.fromEntries(oh.map((h,i)=>[h,i]));
const lrows=live.slice(1).filter(r=>r.length===lh.length);
const orows=onb.slice(1).filter(r=>r.length===oh.length);

// LIVE lookups
const mrrByKey={}, churnKeys=new Set(), goliveByKey={};
lrows.forEach(r=>{const k=r[li['Unique Key']].trim();
  mrrByKey[k]=num(r[li['MRR']]); goliveByKey[k]=r[li['Go-Live Date']].trim();
  if(r[li['Stage']].trim()==='Churned')churnKeys.add(k);});

// integration cell "Category - Provider - Status - notes" -> {provider,status} (sheet-sourced, has status)
function pInt(s){s=(s||'').trim(); if(!s||s==='-')return null;
  const p=s.split(' - ').map(x=>x.trim()); let prov=p[1]||'', st=(p[2]||'').replace(/[-]+$/,'').trim();
  if(!prov)return null; return {provider:prov, status:st||'—'};}
const arrF=x=>x?[x]:[];

const FIELDS=['ims','dms','crm','sched','web','recall','parts'];
const recs=[];
orows.forEach(r=>{
  const key=r[oi['Unique Key']].trim();
  if(key && churnKeys.has(key))return;
  const stageRaw=r[oi['Status']].trim(); if(!stageRaw)return;
  const stage=stageRaw==='Live'?'Live':'OB Initiated';
  const arr=num(r[oi['ARR']]);
  const mrr=(key&&mrrByKey[key]!=null)?mrrByKey[key]:(arr?Math.round(arr/12):0);
  recs.push({
    agent:(r[oi['Agent_Type']]||'').trim()||'—',
    rid:(r[oi['Rooftop_ID']]||'').trim()||'—',
    rname:(r[oi['Rooftop_Name']]||'').trim()||'—',
    eid:(r[oi['Enterprise_Id']]||'').trim()||'—',
    ename:(r[oi['Enterrprise_Name']]||'').trim()||'—',
    stage, arr, mrr, golive:(key&&goliveByKey[key])||'', sign:'',
    crm:arrF(pInt(r[oi['Sales CRM']])), sched:arrF(pInt(r[oi['Service Scheduler']])),
    dms:arrF(pInt(r[oi['DMS']])), ims:arrF(pInt(r[oi['IMS']])), imsIn:[], imsOut:[], web:[], recall:[], parts:[],
  });
});

// CONTRACT tab gid 1400537610: provides "Agreement Sign Date" (col D). NOTE: the "OB" column that
// previously flagged "Not in OB" (Contracted) was removed from this tab, so Contracted now comes
// from a cached snapshot (contracted_cache.json). Sign Date is matched to ALL records by team_id+agent.
const con=R('contracted.csv'); const ch=con[1].map(x=>x.trim());
const cidx=Object.fromEntries(ch.map((h,i)=>[h,i]));
const crows=con.slice(2).filter(r=>r.length===ch.length && r.some(x=>x.trim()));
const signByKey={};
crows.forEach(r=>{const k=norm(r[cidx['Team Id']])+'|'+norm(r[cidx['Agent']]);
  const d=(r[cidx['Agreement Sign Date']]||'').trim(); if(d&&!signByKey[k])signByKey[k]=d;});

// CONTRACTED records: prefer LIVE "OB"=="Not in OB" if the column exists, else cached snapshot.
const hasOB = ('OB' in cidx) && crows.some(r=>(r[cidx['OB']]||'').trim());
const generic=/^rooftop\s*\d*$/i; let contracted=0, conSource;
if(hasOB){
  conSource='live OB column';
  const seen=new Set();
  crows.forEach(r=>{
    if((r[cidx['OB']]||'').trim().toLowerCase()!=='not in ob')return;
    const rid=(r[cidx['Team Id']]||'').trim()||'—', agent=(r[cidx['Agent']]||'').trim()||'—';
    const ent=(r[cidx['Enterprise/Customer']]||'').trim(), rt=(r[cidx['Rooftop']]||'').trim();
    const mrr=num(r[cidx['Price per Agent per Rooftop (USD)']]);
    recs.push({agent, rid, rname:(rt && !generic.test(rt))?rt:(ent||'—'),
      eid:(r[cidx['Ent ID']]||'').trim()||'—', ename:ent||'—',
      stage:'Contracted', arr:mrr*12, mrr, golive:'', sign:(r[cidx['Agreement Sign Date']]||'').trim(),
      crm:[],sched:[],dms:[],ims:[],imsIn:[],imsOut:[],web:[],recall:[],parts:[]});
    contracted++;
  });
  // refresh the cache so a future OB-less export still works
  fs.writeFileSync(__dirname+'/contracted_cache.json',JSON.stringify(
    recs.filter(r=>r.stage==='Contracted').map(r=>({agent:r.agent,rid:r.rid,rname:r.rname,eid:r.eid,ename:r.ename,mrr:r.mrr}))));
}else{
  conSource='cached snapshot (OB column absent)';
  const cache=JSON.parse(fs.readFileSync(__dirname+'/contracted_cache.json','utf8'));
  cache.forEach(c=>recs.push({agent:c.agent, rid:c.rid, rname:c.rname, eid:c.eid, ename:c.ename,
    stage:'Contracted', arr:(c.mrr||0)*12, mrr:c.mrr||0, golive:'', sign:'',
    crm:[],sched:[],dms:[],ims:[],imsIn:[],imsOut:[],web:[],recall:[],parts:[]}));
  contracted=cache.length;
}

// apply Agreement Sign Date to every record (Live / OB / Contracted) by team_id+agent
recs.forEach(rec=>{const d=signByKey[norm(rec.rid)+'|'+norm(rec.agent)]; if(d)rec.sign=d;});

// INTEGRATION PARTNERS: gid 591846436 -> match by Team ID + Agent Opted, categorize comma/slash list
const pr=R('partners.csv'); const ph=pr[0].map(x=>x.trim());
const pi=Object.fromEntries(ph.map((h,i)=>[h,i]));
const pdata=pr.slice(1).filter(r=>r.length===ph.length && (r[pi['Team ID']]||'').trim());
const partnerByKey={};
pdata.forEach(r=>{
  const key=norm(r[pi['Team ID']])+'|'+norm(r[pi['Agent Opted']]);
  const ip=(r[pi['Integration Partner']]||'').trim(); if(!ip)return;
  const bucket=partnerByKey[key]||(partnerByKey[key]={});
  ip.split(/[,;/]+/).map(x=>x.trim()).filter(Boolean).forEach(p=>{
    const m=matchPartner(p); if(!m||m==='skip')return;
    const f=CATFIELD[m.cat]; if(!f)return;
    (bucket[f]=bucket[f]||[]); if(!bucket[f].some(x=>norm(x)===norm(m.provider)))bucket[f].push(m.provider);
  });
});

let matched=0, partnerCells=0;
recs.forEach(rec=>{
  const pb=partnerByKey[norm(rec.rid)+'|'+norm(rec.agent)]; if(!pb)return; matched++;
  FIELDS.forEach(f=>{const a=rec[f];
    (pb[f]||[]).forEach(prov=>{ if(!a.some(x=>norm(x.provider)===norm(prov))){a.push({provider:prov,status:'Mapped'});partnerCells++;} });
  });
});

// INTEGRATION REGISTRY: gid 1662260383 -> match by team_id, fill CRM + Service Scheduler (registryId present = connected -> Completed)
function canonProv(name,type){const n=norm(name);
  const map={tekion:'Tekion',vinsolutions:'Vinsolutions',drivecentric:'DriveCentric',eleads:'Elead',
    xtime:'xTime',evenflow:'Evenflow',mykaarma:'MyKaarma',dealerfx:'DealerFX',crmadf:'ADF (CRM)',
    cdk:type==='service-scheduler'?'CDK Service scheduler':'CDK'};
  return map[n]||(name.charAt(0).toUpperCase()+name.slice(1));}
const rs=R('crm_sched.csv'); const rh=rs[0].map(x=>x.trim()); const rsi=Object.fromEntries(rh.map((h,i)=>[h,i]));
const rsData=rs.slice(1).filter(r=>r.length===rh.length && (r[rsi['team_id']]||'').trim());
const regByTid={};
rsData.forEach(r=>{
  const tid=(r[rsi['team_id']]||'').trim();
  const type=(r[rsi['providerType']]||'').trim().toLowerCase();
  const field=type==='crm'?'crm':(type==='service-scheduler'?'sched':null); if(!field)return;
  const prov=canonProv((r[rsi['providerName']]||'').trim(),type); if(!prov)return;
  const b=regByTid[tid]||(regByTid[tid]={crm:new Set(),sched:new Set()}); b[field].add(prov);
});
let regMatched=0, regCells=0, regUpgraded=0;
recs.forEach(rec=>{const b=regByTid[rec.rid]; if(!b)return; regMatched++;
  [['crm','crm'],['sched','sched']].forEach(([bk,f])=>{ b[bk].forEach(prov=>{
    const ex=rec[f].find(x=>norm(x.provider)===norm(prov));
    if(ex){ if(ex.status!=='Completed'){ex.status='Completed';regUpgraded++;} }
    else { rec[f].push({provider:prov,status:'Completed'}); regCells++; }
  });});
});

// IMS INPUT/OUTPUT: gid 1805335452 -> match by Rooftop_Id (=team_id), fill Input IMS / Output IMS
function canonIms(name){const n=norm(name);
  const map={vauto:'vAuto',maxdigital:'maxDigital (ACV)',vincue:'Vincue',homenet:'HomeNet',vinsolutions:'VinSolutions'};
  return map[n]||name;}
const im=R('ims_io.csv');
let imh=im.findIndex(r=>r.map(x=>x.trim()).includes('Input')&&r.map(x=>x.trim()).includes('Output'));
const imH=im[imh].map(x=>x.trim()); const imi=Object.fromEntries(imH.map((h,i)=>[h,i]));
const imData=im.slice(imh+1).filter(r=>r.length===imH.length && (r[imi['Rooftop_Id']]||'').trim());
const imsByTid={};
imData.forEach(r=>{const tid=(r[imi['Rooftop_Id']]||'').trim();
  const inp=(r[imi['Input']]||'').trim(), out=(r[imi['Output']]||'').trim();
  const b=imsByTid[tid]||(imsByTid[tid]={in:new Set(),out:new Set()});
  if(inp)b.in.add(canonIms(inp)); if(out)b.out.add(canonIms(out));});
let imsMatched=0, imsCells=0;
recs.forEach(rec=>{const b=imsByTid[rec.rid]; if(!b)return; imsMatched++;
  b.in.forEach(p=>{if(!rec.imsIn.some(x=>norm(x.provider)===norm(p))){rec.imsIn.push({provider:p,status:'Completed'});imsCells++;}});
  b.out.forEach(p=>{if(!rec.imsOut.some(x=>norm(x.provider)===norm(p))){rec.imsOut.push({provider:p,status:'Completed'});imsCells++;}});
});

const by=s=>recs.filter(r=>r.stage===s).length;
console.log('IMS I/O (gid 1805335452): records matched by team_id:',imsMatched,'| Input/Output cells added:',imsCells);
console.log('records:',recs.length,'| Live:',by('Live'),'| OB:',by('OB Initiated'),'| Contracted:',contracted,'(source:',conSource+')');
console.log('distinct rooftops:',new Set(recs.map(r=>r.rid)).size);
console.log('partner rows:',pdata.length,'| records matched to a partner row:',matched,'| partner-sourced integration cells added:',partnerCells);
console.log('registry (gid 1662260383): records matched by team_id:',regMatched,'| CRM/sched cells added:',regCells,'| statuses upgraded to Completed:',regUpgraded);
fs.writeFileSync(__dirname+'/_records.json',JSON.stringify(recs));
console.log('wrote _records.json', (fs.statSync(__dirname+'/_records.json').size/1024).toFixed(1)+'KB');
