function norm(s){return (s||'').toLowerCase().replace(/[^a-z0-9]/g,'');}
// category -> record field
const CATFIELD={'IMS':'ims','DMS':'dms','Sales CRM':'crm','CRM':'crm','Service Scheduler':'sched',
  'Website Providers':'web','Website Provider':'web','Parts':'parts','Recall':'recall'};
// explicit aliases (normalized) -> {cat, provider}
const ALIAS={
  vinsolutions:{cat:'CRM',provider:'Vinsolutions'}, vinsolution:{cat:'CRM',provider:'Vinsolutions'},
  vinsol:{cat:'CRM',provider:'Vinsolutions'}, vns:{cat:'CRM',provider:'Vinsolutions'},
  tekion:{cat:'DMS',provider:'Tekion'},
  cdk:{cat:'DMS',provider:'CDK DMS'},
  reynoldsreynolds:{cat:'DMS',provider:'Reynolds & Reynolds'}, reynolds:{cat:'CRM',provider:'Reynolds'},
  homenet:{cat:'IMS',provider:'Homenet'}, hmn:{cat:'IMS',provider:'Homenet'},
  mykarma:{cat:'Service Scheduler',provider:'MyKaarma'}, mykaarma:{cat:'Service Scheduler',provider:'MyKaarma'},
  dealerslink:{cat:'IMS',provider:'Dealerslink'},
  autoleap:{cat:'Service Scheduler',provider:'AutoLeap'},
  wiadvisor:{cat:'Service Scheduler',provider:'wiAdvisor'},
  transax:{cat:'DMS',provider:'Transax'},
  automate:{cat:'DMS',provider:'Automate (Solera)'},
  maxdigital:{cat:'IMS',provider:'maxDigital (ACV)'},
  drivecentric:{cat:'CRM',provider:'DriveCentric'},
  dealercenter:{cat:'CRM',provider:'DealerCenter'}, dealercentre:{cat:'CRM',provider:'DealerCenter'},
  promax:{cat:'CRM',provider:'ProMax (NCC)'},
  elead:{cat:'CRM',provider:'Elead'}, eleads:{cat:'CRM',provider:'Elead'},
  dealerlogix:{cat:'Service Scheduler',provider:'DealerLogix'},
  updatepromise:{cat:'Service Scheduler',provider:'Update Promise'},
  pbs:{cat:'DMS',provider:'PBS'},
  vauto:{cat:'IMS',provider:'vAuto'}, vincue:{cat:'IMS',provider:'Vincue'},
  xtime:{cat:'Service Scheduler',provider:'xTime'},
  dealercom:{cat:'Website Provider',provider:'Dealer.com'},
};
// untracked tools (telephony / internal / vin-decode) -> skip
const SKIP=new Set(['zultys','avaya','dialpad','spyneconsole','autocheck','focus','smartpath']);
function matchPartner(raw){
  raw=(raw||'').trim(); if(!raw)return null;
  const m=raw.match(/\(([^)]*)\)/); const paren=m?m[1].trim():'';
  const base=raw.replace(/\([^)]*\)/g,'').trim();
  // 1) parenthetical names a real product (e.g. "CDK (eLeads)") -> use it
  if(paren){ const pk=norm(paren); if(ALIAS[pk])return ALIAS[pk]; }
  const nb=norm(base);
  if(SKIP.has(nb))return 'skip';
  // 2) CDK service disambiguation via paren hint
  if(nb==='cdk' && /serv/i.test(paren))return {cat:'Service Scheduler',provider:'CDK Service scheduler'};
  // 3) alias
  if(ALIAS[nb])return ALIAS[nb];
  // 4) tekion service
  if(nb==='tekion' && /serv/i.test(paren))return {cat:'Service Scheduler',provider:'Tekion'};
  return null; // unmatched
}
module.exports={matchPartner,CATFIELD,norm};

if(require.main===module){
  const fs=require('fs');
  function parseCSV(t){const rows=[];let i=0,f='',row=[],q=false;t=t.replace(/\r/g,'');
    while(i<t.length){const c=t[i];
      if(q){if(c=='"'){if(t[i+1]=='"'){f+='"';i+=2;continue;}q=false;i++;continue;}f+=c;i++;continue;}
      if(c=='"'){q=true;i++;continue;} if(c==','){row.push(f);f='';i++;continue;}
      if(c=='\n'){row.push(f);rows.push(row);row=[];f='';i++;continue;} f+=c;i++;}
    if(f.length||row.length){row.push(f);rows.push(row);} return rows;}
  const rows=parseCSV(fs.readFileSync('partners.csv','utf8'));
  const hdr=rows[0].map(x=>x.trim()); const idx=Object.fromEntries(hdr.map((h,i)=>[h,i]));
  const data=rows.slice(1).filter(r=>r.length===hdr.length&&(r[idx['Team ID']]||'').trim());
  const all={}, res={}, unm={};
  data.forEach(r=>{(r[idx['Integration Partner']]||'').split(/[,;]+/).map(x=>x.trim()).filter(Boolean).forEach(p=>{
    all[p]=(all[p]||0)+1; const mm=matchPartner(p);
    if(mm==='skip')res[p]='[skip]'; else if(mm)res[p]=mm.cat+' / '+mm.provider; else {res[p]='??? UNMATCHED';unm[p]=(unm[p]||0)+1;}
  });});
  console.log('distinct partners:',Object.keys(all).length);
  Object.entries(all).sort((a,b)=>b[1]-a[1]).forEach(([p,n])=>console.log(`  ${p} (${n}) -> ${res[p]}`));
  console.log('\nUNMATCHED:',JSON.stringify(unm));
}
