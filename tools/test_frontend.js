"use strict";
// Exercise the real save queue, navigation and answer preview without a browser or user data.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const bank=JSON.parse(fs.readFileSync(path.join(root,'bank.json'),'utf8'));
const questions=new Map(bank.questions.map(q=>[q.id,q]));
const clone=value=>JSON.parse(JSON.stringify(value));
const correct=id=>questions.get(id).answer;
const wrong=id=>[questions.get(id).options.find(o=>!correct(id).includes(o.key)).key];
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
const source=fs.readFileSync(path.join(root,'web/app.js'),'utf8').replace(/\nroute\(\);\s*$/,'\n');
let passed=0;

async function harness(mode='practice',type='single'){
  const ids={single:['1','2'],multiple:['246','247'],judge:['427','428']}[type];
  const review=mode.startsWith('review-'),origin=mode==='review-exam'?'exam':'practice';
  const entries=review?ids.map(qid=>({id:origin+':'+(origin==='exam'?'old:':'')+qid,source:origin,qid,
    examId:origin==='exam'?'old':null,original:wrong(qid),review:[],reviewCorrect:null,correctAnswer:null})):[];
  const db={practice:{},mistakes:entries,settings:{'autoRemove:practice':false,'autoRemove:exam':false},
    exam:{id:'active',type,status:'active',order:ids,answers:{},elapsed:0,currentQ:ids[0]},history:[]};
  if(review)for(const id of ids)db.practice[id]={answer:wrong(id),correct:false,correctAnswer:correct(id)};
  const timers=new Map(),notices=[],calls=[];let timer=0;
  const bridge={fail:null,hold:null,held:deferred(),release:deferred()};
  bridge.request=async(url,payload)=>{
    calls.push({url,payload:clone(payload??null)});
    if(bridge.hold===url){bridge.held.resolve();await bridge.release.promise;bridge.hold=null;}
    if(bridge.fail===url){bridge.fail=null;throw new Error('simulated save failure');}
    if(url==='/api/bootstrap')return clone({token:'test',bank:{...bank,questions:bank.questions.map(({answer,...q})=>q)},
      practice:db.practice,mistakes:db.mistakes,settings:db.settings,exams:[]});
    if(url.startsWith('/api/practice/answers?'))return {answers:Object.fromEntries(bank.questions.filter(q=>q.type===url.split('=')[1]).map(q=>[q.id,q.answer]))};
    if(url==='/api/practice'){
      const result=payload.answer.length?{answer:payload.answer,correct:JSON.stringify(payload.answer)===JSON.stringify(correct(payload.qid)),correctAnswer:correct(payload.qid)}:null;
      if(result)db.practice[payload.qid]=clone(result);else delete db.practice[payload.qid];
      db.history.push(clone(payload));return clone(result);
    }
    if(url==='/api/review'){
      const entry=db.mistakes.find(e=>e.id===payload.id);assert.ok(entry,'review entry must exist');
      const result={answer:payload.answer,correct:JSON.stringify(payload.answer)===JSON.stringify(correct(entry.qid)),correctAnswer:correct(entry.qid)};
      result.removed=Boolean(result.correct&&db.settings['autoRemove:'+entry.source]);
      Object.assign(entry,{review:clone(payload.answer),reviewCorrect:result.correct,correctAnswer:result.correctAnswer});
      if(result.removed)db.mistakes=db.mistakes.filter(e=>e.id!==entry.id);
      db.history.push(clone(payload));return clone(result);
    }
    if(url==='/api/exam/active')return clone(db.exam);
    if(url==='/api/exam/answer'){db.exam.answers[payload.qid]=clone(payload.answer);db.history.push(clone(payload));return clone(db.exam);}
    if(url==='/api/exam/position'){db.exam.currentQ=payload.qid;return {};}
    if(url==='/api/exam/tick')return {elapsed:0,status:db.exam.status};
    throw new Error('Unexpected request: '+url);
  };
  const element={focus(){},classList:{add(){},remove(){},toggle(){}},open:false,showModal(){this.open=true;}};
  const ctx=vm.createContext({bridge,console,crypto:{randomUUID:()=> 'test-owner'},location:{hash:''},
    localStorage:{getItem:()=>null,setItem(){}},document:{addEventListener(){},querySelector:()=>element,querySelectorAll:()=>[],hidden:false},
    window:{addEventListener(){},scrollTo(){}},navigator:{sendBeacon(){}},performance:{now:()=>0},
    setInterval(){},requestAnimationFrame(){},setTimeout:fn=>{timers.set(++timer,fn);return timer;},clearTimeout:id=>timers.delete(id),notices});
  vm.runInContext(source,ctx);
  vm.runInContext("api=(url,payload)=>bridge.request(url,payload);render=()=>{};toast=message=>notices.push(message);",ctx);
  const run=code=>vm.runInContext(code,ctx);
  const read=code=>JSON.parse(run('JSON.stringify('+code+')'));
  const navigate=async hash=>{ctx.location.hash=hash;await run('route()');};
  const initial=review?'#/review/'+encodeURIComponent(entries[0].id):mode==='exam'?'#/exam/active/'+ids[0]:'#/practice/'+type+'/'+ids[0];
  await navigate(initial);
  return {db,calls,bridge,ctx,run,read,navigate,initial,ids,notices,
    choose:choice=>run('saveAnswer('+JSON.stringify(choice)+')'),
    flush(){const queued=[...timers.values()];timers.clear();queued.forEach(fn=>fn());},
    pending:()=>timers.size};
}
async function test(name,body){await body();passed++;console.log('ok '+passed+' - '+name);}

(async()=>{
  for(const mode of ['practice','exam','review-practice','review-exam'])for(const type of ['single','multiple','judge']){
    await test(mode+'/'+type+' follows the requested next-question rule',async()=>{
      const h=await harness(mode,type),id=h.ids[0];
      const answer=(mode==='exam'||mode==='review-exam')?wrong(id):correct(id);
      for(const choice of answer)await h.choose(choice);
      h.flush();
      const shouldMove=type!=='multiple'||mode==='practice';
      assert.equal(h.ctx.location.hash!==h.initial,shouldMove);
      assert.equal(h.db.history.length,answer.length,'only user selections are saved');
    });
  }
  for(const mode of ['practice','review-practice'])await test(mode+' wrong answer stays on the question',async()=>{
    const h=await harness(mode);await h.choose(wrong('1')[0]);h.flush();assert.equal(h.ctx.location.hash,h.initial);
  });
  await test('ordinary multiple-choice incomplete answer stays until all correct options are selected',async()=>{
    const h=await harness('practice','multiple');await h.choose('A');h.flush();assert.equal(h.ctx.location.hash,h.initial);
    await h.choose('B');await h.choose('C');h.flush();assert.ok(h.ctx.location.hash.endsWith('/247'));
  });
  await test('viewing answers alone neither advances nor writes records',async()=>{
    const h=await harness('review-practice');const before=clone(h.db);
    assert.equal(h.read('quiz.practiceSession.showAnswers'),false);await h.run('togglePracticeAnswers(true)');h.flush();
    assert.deepEqual(h.db,before);assert.equal(h.ctx.location.hash,h.initial);
    assert.deepEqual(h.read('quiz.practiceSession.answers["246"]'),correct('246'));
    assert.match(h.run('quizPage()'),/参考答案：C/);
    await h.navigate('#/review/practice%3A2');assert.equal(h.read('quiz.practiceSession.showAnswers'),true);
    await h.navigate('#/home');await h.navigate(h.initial);assert.equal(h.read('quiz.practiceSession.showAnswers'),false);
  });
  await test('practice preview does not carry into practice mistakes or exam mistakes',async()=>{
    const h=await harness('review-practice');await h.navigate('#/practice/single/1');await h.run('togglePracticeAnswers(true)');
    await h.navigate(h.initial);assert.equal(h.read('quiz.practiceSession.showAnswers'),false);
    const e=await harness('review-exam');assert.equal(e.read('quiz.practiceSession'),null);assert.doesNotMatch(e.run('quizPage()'),/id="practice-answers-toggle"/);
  });
  await test('automatic removal advances to the original next entry without skipping',async()=>{
    const h=await harness('review-practice');h.db.settings['autoRemove:practice']=true;await h.navigate(h.initial);
    const original=clone(h.db.practice);await h.choose(correct('1')[0]);h.flush();
    assert.equal(h.ctx.location.hash,'#/review/practice%3A2');assert.deepEqual(h.db.practice,original);
    await h.navigate(h.ctx.location.hash);assert.equal(h.read('quiz.qid'),'2');assert.equal(h.db.mistakes.length,1);
  });
  await test('multiple-choice review stays even when the correct answer removes the entry',async()=>{
    const h=await harness('review-practice','multiple');h.db.settings['autoRemove:practice']=true;await h.navigate(h.initial);
    for(const c of correct('246'))await h.choose(c);h.flush();assert.equal(h.ctx.location.hash,h.initial);
    assert.equal(h.read('quiz.entry.removed'),true);h.run('jump(quiz.order[1])');await h.navigate(h.ctx.location.hash);
    assert.equal(h.read('quiz.qid'),'247');
  });
  await test('latest rapid choice wins over an earlier correct result',async()=>{
    const h=await harness();const first=h.choose(correct('1')[0]),second=h.choose(wrong('1')[0]);await Promise.all([first,second]);h.flush();
    assert.equal(h.ctx.location.hash,h.initial);assert.deepEqual(h.db.practice['1'].answer,wrong('1'));
  });
  await test('clearing a correct answer cancels a pending advance',async()=>{
    const h=await harness();await h.choose(correct('1')[0]);await h.run('saveAnswer(null,true)');h.flush();
    assert.equal(h.ctx.location.hash,h.initial);assert.equal(h.db.practice['1'],undefined);
  });
  await test('failed save never advances',async()=>{
    const h=await harness();h.bridge.fail='/api/practice';await h.choose(correct('1')[0]);h.flush();
    assert.equal(h.ctx.location.hash,h.initial);assert.ok(h.read('lastError'));assert.equal(h.db.history.length,0);
  });
  await test('manual navigation during an in-flight save is never overridden',async()=>{
    const h=await harness();h.bridge.hold='/api/practice';const saving=h.choose(correct('1')[0]);await h.bridge.held.promise;
    const moving=h.navigate('#/practice/single/3');h.bridge.release.resolve();await Promise.all([saving,moving]);h.flush();
    assert.equal(h.ctx.location.hash,'#/practice/single/3');assert.equal(h.read('quiz.qid'),'3');
  });
  await test('manual navigation cancels an already scheduled advance',async()=>{
    const h=await harness();await h.choose(correct('1')[0]);await h.navigate('#/practice/single/3');h.flush();assert.equal(h.read('quiz.qid'),'3');
  });
  await test('clicking an already saved choice advances without duplicating history',async()=>{
    const h=await harness();await h.choose(correct('1')[0]);h.run('cancelAutoAdvance()');await h.choose(correct('1')[0]);h.flush();
    assert.ok(h.ctx.location.hash.endsWith('/2'));assert.equal(h.db.history.length,1);
  });
  await test('last exam question saves but never submits or wraps',async()=>{
    const h=await harness('exam');await h.navigate('#/exam/active/2');await h.choose('A');h.flush();
    assert.equal(h.ctx.location.hash,'#/exam/active/2');assert.equal(h.db.exam.status,'active');assert.ok(h.notices.length);
    assert.ok(!h.calls.some(c=>c.url.includes('submit')));
  });
  await test('last removed practice mistake returns to the list',async()=>{
    const h=await harness('review-practice');h.db.settings['autoRemove:practice']=true;await h.navigate('#/review/practice%3A2');
    await h.choose(correct('2')[0]);h.flush();assert.equal(h.ctx.location.hash,'#/mistakes/practice');
  });
  await test('submitted exam stays locked and never advances',async()=>{
    const h=await harness('exam');h.db.exam.status='submitted';await h.navigate(h.initial);
    await h.choose('A');h.flush();assert.equal(h.ctx.location.hash,h.initial);assert.equal(h.db.history.length,0);
  });
  console.log('\n'+passed+' frontend acceptance checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
