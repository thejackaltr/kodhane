const K=require('../game.js');
K.state=K.newState();
const times={}; let t=0;
function deltaTpsGen(g){return K.genTps(g);}
function bestAction(){
  const S=K.state; let best=null;
  const base=K.baseTps()+1;
  for(const g of K.GENERATORS){const c=K.genCost(g,1);const d=K.genTps(g); const score=c/d; if(!best||score<best.score) best={score,type:'g',id:g.id,cost:c};}
  for(const u of K.availableUpgrades()){
    const before=K.baseTps()+K.clickValue()*CPS; K.state.upgrades.push(u.id); const after=K.baseTps()+K.clickValue()*CPS; K.state.upgrades.pop();
    const d=after-before; if(d<=0) continue; const score=u.cost/d; if(score<best.score) best={score,type:'u',id:u.id,cost:u.cost};
  }
  return best;
}
let CPS=5;
const END=3*3600;
for(t=0;t<END;t++){
  CPS = t<600?5:(t<1800?1:0);
  for(let i=0;i<CPS;i++) K.doClick();
  K.tick(1);
  for(let k=0;k<50;k++){const b=bestAction(); if(b && K.state.money>=b.cost){ b.type==='g'?K.buyGen(b.id,1):K.buyUpgrade(b.id);} else break;}
  const si=K.stageIndex(K.state.runEarned); if(!(si in times)){times[si]=t; console.log('stage',K.STAGES[si].name,'at',K.fmtTime(t),'tps',K.fmt(K.tps()));}
  if([60,180,300,600,1200,1800,3600,5400,7200,10799].includes(t)) console.log(K.fmtTime(t),'earned',K.fmt(K.state.runEarned),'tps',K.fmt(K.tps()),'owned',K.totalOwned(),'upg',K.state.upgrades.length,'shares',K.sharesGain(), JSON.stringify(K.state.gens));
}
