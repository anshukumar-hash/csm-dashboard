const fs=require('fs');
function parseCSV(t){const rows=[];let i=0,f='',row=[],q=false;t=t.replace(/\r/g,'');
  while(i<t.length){const c=t[i];
    if(q){if(c=='"'){if(t[i+1]=='"'){f+='"';i+=2;continue;}q=false;i++;continue;}f+=c;i++;continue;}
    if(c=='"'){q=true;i++;continue;} if(c==','){row.push(f);f='';i++;continue;}
    if(c=='\n'){row.push(f);rows.push(row);row=[];f='';i++;continue;} f+=c;i++;}
  if(f.length||row.length){row.push(f);rows.push(row);} return rows;}
const D=__dirname;
const recs=JSON.parse(fs.readFileSync(D+'/_records.json','utf8'));
// ---- categorization: Products,Company ----
const catRows=parseCSV(fs.readFileSync(D+'/categorization.csv','utf8')).slice(1).filter(r=>r.length>=2&&r[0].trim());
const catMap={}; // normProvider -> category (sheet label)
catRows.forEach(r=>{const cat=r[0].trim(), comp=r[1].trim(); if(comp)catMap[norm(comp)]={cat,comp};});
// ---- pricing ----
const pr=parseCSV(fs.readFileSync(D+'/pricing.csv','utf8'));
// header is row index 1; data from row 2
const pricing=[];
for(let i=2;i<pr.length;i++){const r=pr[i]; const company=(r[1]||'').trim(); if(!company)continue;
  pricing.push({company, type:(r[2]||'').trim(),
    setup:(r[3]||'').trim(), spyne:(r[4]||'').trim(),
    perDealer:(r[5]||'').trim(), monthly:(r[6]||'').trim(), remarks:(r[7]||'').trim()});}
function norm(s){return (s||'').toLowerCase().replace(/[^a-z0-9]/g,'');}
// category compatibility for pricing.type
const typeOK={CRM:['crm','both'],DMS:['dms','both'],IMS:['imageapi','vincheck',''],'Service Scheduler':['servicescheduler','both']};
const catHint={CRM:['crm'],DMS:['dms','drive'],'Service Scheduler':['service','scheduler'],IMS:['inventory','image']};
function matchPrice(provider, category){
  const np=norm(provider); if(!np)return null;
  let best=null,bestScore=0;
  for(const p of pricing){const nc=norm(p.company);
    let score=0;
    if(nc===np)score=100;
    else if(nc.includes(np)||np.includes(nc))score=60;
    if(!score)continue;
    const pt=norm(p.type);
    const ok=typeOK[category]||[];
    if(p.type && ok.length && !ok.includes(pt)) score-=20; else if(p.type&&ok.includes(pt)) score+=15;
    if((catHint[category]||[]).some(h=>nc.includes(h))) score+=25;
    if(score>bestScore){bestScore=score;best=p;}
  }
  return bestScore>=50?best:null;
}
// distinct providers used in records, per category key
const KEYS={ims:'IMS',dms:'DMS',crm:'CRM',sched:'Service Scheduler'};
const provset={ims:new Set(),dms:new Set(),crm:new Set(),sched:new Set()};
const imsArr=r=>[...(r.ims||[]),...(r.imsIn||[]),...(r.imsOut||[])];
recs.forEach(r=>Object.keys(KEYS).forEach(k=>{(k==='ims'?imsArr(r):(r[k]||[])).forEach(v=>{if(v&&v.provider)provset[k].add(v.provider);});}));
// build price-by-provider (keyed by "category|provider")
const priceByProv={};
Object.keys(KEYS).forEach(k=>{const cat=KEYS[k];
  provset[k].forEach(p=>{const m=matchPrice(p,cat); priceByProv[k+'|'+p]=m?{
    company:m.company,setup:m.setup||'',spyne:m.spyne||'',
    perDealer:m.perDealer||'',monthly:m.monthly||'',remarks:m.remarks||''}:null;});
});
// report matches
console.log('Providers & pricing matches:');
Object.keys(KEYS).forEach(k=>{console.log(' '+KEYS[k]+':');
  [...provset[k]].sort().forEach(p=>{const m=priceByProv[k+'|'+p];
    console.log('   '+p+'  ->  '+(m?m.company:'(no pricing)'));});});
const out={priceByProv, categories:['IMS','DMS','CRM','Service Scheduler','Website Provider','Recall','Parts']};
fs.writeFileSync(D+'/_catalog.json',JSON.stringify(out));
console.log('\nwrote _catalog.json',(fs.statSync(D+'/_catalog.json').size/1024).toFixed(1)+'KB');
