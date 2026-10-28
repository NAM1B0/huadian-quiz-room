"use strict";
const APP_VERSION = "1.0.2";
const $ = s => document.querySelector(s);
const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const labels = {single:"单选题", multiple:"多选题", judge:"判断题"};
const paths = {
  home:'<path d="m3 10 9-7 9 7v10H3z"/><path d="M9 20v-7h6v7"/>',
  records:'<rect x="5" y="4" width="15" height="17" rx="2"/><path d="M9 3v3m7-3v3M9 11h7m-7 4h5M3 8v10"/>',
  mistakes:'<path d="M12 5c-3-2-6-2-9-1v15c3-1 6-1 9 1 3-2 6-2 9-1V4c-3-1-6-1-9 1v15"/><path d="m16 8 3 3m0-3-3 3"/>',
  data:'<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 4 16 4 16 0V5M4 12c0 4 16 4 16 0"/>',
  single:'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/>',
  multiple:'<rect x="3" y="3" width="18" height="18" rx="4"/><path d="m7 12 3 3 7-7"/>',
  judge:'<path d="m3 7 3 3 5-6M14 7h7M4 16l6 6m0-6-6 6M14 19h7"/>',
  arrow:'<path d="M4 12h16m-6-6 6 6-6 6"/>',
  back:'<path d="M20 12H4m6-6-6 6 6 6"/>',
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  check:'<path d="m5 12 4 4L19 6"/>',
  cross:'<path d="m6 6 12 12M6 18 18 6"/>',
  shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',
  shuffle:'<path d="M3 5h3l12 14h3m-4-4 4 4-4 4M3 19h3l4-5m3-4 5-5h3m-4-4 4 4-4 4"/>',
  download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
  book:'<path d="M4 4h13a3 3 0 0 1 3 3v14H7a3 3 0 0 1-3-3V4zm0 13h16M8 8h8m-8 4h5"/>',
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.book}</svg>`;
const fmtDate = value => value ? new Date(value).toLocaleString("zh-CN", {year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hour12:false}) : "—";
const duration = value => { const s=Math.max(0,Math.floor(value || 0)); return [Math.floor(s/3600),Math.floor(s/60)%60,s%60].map(n=>String(n).padStart(2,"0")).join(":"); };
const getPref = (k, fallback) => { try {return localStorage.getItem(k) || fallback;} catch{return fallback;} };
const setPref = (k,v) => { try {localStorage.setItem(k,v);} catch{} };
let data, questions, groups, token, quiz=null, parts=[], busy=false, savePromise=Promise.resolve(), routeSerial=0;
let homeMode=getPref("huadian:mode","practice"), recordFilter="all", mistakeFilter="all", historyPage=1, historyData=null;
let lastError="", saveLabel="所有选择自动保存", toastTimer, timerBase=0, timerAt=0, timerId=null, reviewSnapshot=null;
const owner = crypto.randomUUID();
const pendingAnswers = new Map();
let saveCount = 0, choiceRevision = 0;
let practiceSession = null;

async function api(path, payload){
  const response = await fetch(path, payload === undefined ? {cache:"no-store"} : {method:"POST", keepalive:true, headers:{"Content-Type":"application/json","X-App-Token":token || ""},body:JSON.stringify(payload)});
  const result = await response.json();
  if(!response.ok) throw new Error(result.error || "操作失败，请重试。");
  return result;
}
async function refresh(){
  data=await api("/api/bootstrap"); token=data.token;
  questions=new Map(data.bank.questions.map(q=>[q.id,q])); groups=new Map(data.bank.groups.map(g=>[g.id,g]));
}
function toast(message){const el=$("#toast");el.textContent=message;el.classList.add("visible");clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.classList.remove("visible"),3500);}
function errorMessage(error){lastError=error.message || String(error);saveLabel="操作未保存";render();toast(lastError);}
function setStatus(text){saveLabel=text;const el=$(".save-status");if(el){el.classList.toggle("error",Boolean(lastError));el.innerHTML=`${lastError?icon("cross"):'<i class="status-dot"></i>'}${esc(text)}`;}}
function goto(path){const next="#/"+path;if(location.hash===next)route();else location.hash=next;}
function button(action,text,cls="",extra=""){return `<button type="button" class="btn ${cls}" data-action="${action}" ${extra}>${text}</button>`;}
function empty(title,copy,action="home",actionLabel="返回题库"){return `<div class="panel empty">${icon("book")}<h2>${title}</h2><p>${copy}</p>${button(action,actionLabel,"primary")}</div>`;}
function choiceString(a){return a?.length?a.join("、"):"未作答";}
function examNumber(id){const i=data.exams.findIndex(e=>e.id===id);return i>=0?data.exams.length-i:'—';}
function questionIds(type){return data.bank.questions.filter(q=>q.type===type).map(q=>q.id);}

function shell(content){
  const active=parts[0]||"home";
  const nav=[['home','题库练习','home'],['records','做题记录','records'],['mistakes','错题集','mistakes'],['data','数据与备份','data']];
  const navActive=active==="practice"||active==="exam"?"home":active==="review"?"mistakes":active;
  return `<div class="shell"><aside class="sidebar"><a class="brand" href="#/home"><img src="/favicon.svg" alt=""><div><strong>华电题库练习室</strong><small>HUADIAN · 2026</small></div></a><div class="nav-label">我的学习空间</div><nav aria-label="主导航">${nav.map(([key,name,ico])=>`<a href="#/${key}" class="nav-link ${navActive===key?'active':''}" ${navActive===key?'aria-current="page"':''}>${icon(ico)}<span>${name}</span>${key==='mistakes'&&data.mistakes.length?`<span class="nav-count">${data.mistakes.length}</span>`:''}</a>`).join("")}</nav><div class="sidebar-foot"><i class="status-dot"></i>本地学习 · 离线可用<br>中国华电招聘题库<br>2026 年 9 月版 · 共 563 题<br>程序 v${APP_VERSION}</div></aside><div class="workspace"><header class="topbar"><span class="topbar-title">中国华电集团有限公司 · 高校毕业生招聘</span><span class="save-status ${lastError?'error':''}"><i class="status-dot"></i>${esc(saveLabel)}</span></header><main id="main">${lastError?`<div class="error-banner" role="alert">${esc(lastError)} ${button("retry","刷新重试","small")}</div>`:''}${content}</main></div></div>`;
}
function heading(title,desc,eyebrow="学习空间",right=""){return `<div class="page-heading"><div><span class="eyebrow">${eyebrow}</span><h1>${title}</h1>${desc?`<p>${desc}</p>`:''}</div>${right}</div>`;}
function home(){
  const examMode=homeMode==='exam';
  return heading("公共与行业知识", "按题型进入，沿原题库的六个部分逐步完成。每一次选择，都会留在这里。", "中国华电 · 招聘考试题库",'<span class="edition">2026 版</span>')+
  `<div class="mode-line"><div class="segmented" aria-label="刷题模式"><button data-action="mode" data-value="practice" class="${!examMode?'active':''}" aria-pressed="${!examMode}">${icon('book')}练习模式</button><button data-action="mode" data-value="exam" class="${examMode?'active':''}" aria-pressed="${examMode}">${icon('clock')}考试模式</button></div><span class="mode-description">${examMode?'组内随机出题 · 正向计时 · 全部作答后交卷':'不计时 · 即时查看对错 · 随时修改答案'}</span></div>
  <div class="type-grid">${Object.entries(labels).map(([type,label])=>{
    const ids=questionIds(type), p=ids.filter(id=>data.practice[id]), good=p.filter(id=>data.practice[id].correct).length;
    const active=data.exams.find(e=>e.type===type&&e.status==='active'), n=examMode?(active?.answered||0):p.length;
    return `<article class="panel type-card ${type}"><div class="type-symbol">${icon(type)}</div><div class="row between type-top"><h2 class="type-title">${label}</h2><span class="type-count"><strong>${ids.length}</strong>道</span></div><p class="desc">${examMode?(active?'未交卷的考试已保留，继续完成这套题。':'每个部分独立打乱顺序，保留原题号。'):{single:'从四个选项中选出一个正确答案。',multiple:'选择所有正确选项，少选或多选均记为错误。',judge:'判断题干陈述是否正确。'}[type]}</p><div class="progress">${examMode?`<span style="width:${n/ids.length*100}%"></span>`:`<span class="good" style="width:${good/ids.length*100}%"></span><span class="bad" style="width:${(n-good)/ids.length*100}%"></span>`}</div><div class="row between type-progress small muted"><span>${examMode?(active?'当前考试':'尚未开始'):'已练习'} <b class="mono">${n} / ${ids.length}</b></span><span>${examMode?(active?duration(active.elapsed):'6 个部分'):`正确 ${good} 题`}</span></div>${button('start',`${examMode?(active?'继续考试':'开始考试'):(n?'继续练习':'开始练习')}${icon('arrow')}`,'primary',`data-type="${type}"`)}</article>`;
  }).join('')}</div><div class="home-bottom"><section class="panel catalogue"><div class="section-title"><h2>题库目录</h2><span class="small muted">沿用原文分组</span></div>${data.bank.groups.filter(g=>g.type==='multiple').map((g,i)=>`<div class="catalogue-row"><span class="part">${g.part}</span><span>${g.title}</span><span class="total">${['single','multiple','judge'].map(t=>data.bank.groups.filter(x=>x.type===t)[i].count).join(' / ')} 题</span></div>`).join('')}<p class="footnote">题量依次为单选 / 多选 / 判断；单选第六部分原名“电力基础知识”。</p></section><section class="panel guide"><div class="section-title"><h2>安心接着做</h2>${icon('shield')}</div><div class="guide-item">${icon('data')}<div><h3>选择实时保存</h3><p>答题记录写入本机。关闭页面或重新启动后，已选答案仍然保留。</p></div></div><div class="guide-item">${icon('records')}<div><h3>考试随时续做</h3><p>未交卷的考试可从这里或做题记录继续；交卷后锁定答案，下一次开始新卷。</p></div></div><div class="guide-item">${icon('mistakes')}<div><h3>错题分别整理</h3><p>练习与考试各自归档。是否在复习答对后移除，由你设置。</p></div></div></section></div><p class="source-note">题库来源：${esc(data.bank.title)}（2026 版） · 印刷页码 39–160 页</p>`;
}

function answerState(qid){
  const pending=pendingAnswers.get(choiceToken(quiz,qid));
  if(pending)return {answer:pending.answer,pending:true};
  if(quiz.kind==='practice') return data.practice[qid] || {answer:[]};
  if(quiz.kind==='exam') return {answer:quiz.exam.answers[qid]||[],...(quiz.exam.results?.[qid]||{})};
  const entry=quiz.entries.find(e=>e.id===qid);
  if(!entry) return {answer:[]};
  return {answer:entry.review||[],correct:entry.reviewCorrect,correctAnswer:entry.correctAnswer,removed:entry.removed};
}
function choiceToken(context,key){return context.kind+':'+(context.kind==='exam'?context.exam.id+':':'')+key;}
function statusFor(key){
  const s=answerState(key);if(!s.answer?.length)return '';
  if(s.pending)return 'done';
  if(quiz.kind==='exam'&&quiz.exam.status==='active')return 'done';
  const qid=quiz.kind==='review'?quiz.entries.find(e=>e.id===key)?.qid:key;
  if(questions.get(qid)?.type==='multiple'&&s.correctAnswer?.length&&
      s.answer.length<s.correctAnswer.length&&s.answer.every(option=>s.correctAnswer.includes(option)))return 'partial';
  return s.correct?'good':'bad';
}
function quizPage(){
  const q=questions.get(quiz.qid), g=groups.get(q.group), key=quiz.kind==='review'?quiz.entry.id:q.id;
  const s=answerState(key), active=quiz.kind==='exam'&&quiz.exam.status==='active', locked=(quiz.kind==='exam'&&!active)||s.removed;
  const modeLabel=quiz.kind==='practice'?'练习模式':quiz.kind==='review'?'错题复习':active?'考试模式':'考试回顾';
  const answered=quiz.order.filter(id=>answerState(id).answer?.length).length;
  const previewAnswers=quiz.kind==='practice'&&quiz.practiceSession.showAnswers?quiz.practiceSession.answers?.[q.id]:null;
  const correctAnswer=previewAnswers||s.correctAnswer;
  const revealed=!active&&correctAnswer?.length&&(s.answer.length||previewAnswers);
  const itemIndex=quiz.order.indexOf(key);
  let feedback='';
  if(s.pending){
    feedback=`<div class="feedback neutral" role="status">${icon('data')}<div><strong>正在保存选择…</strong><p>可以继续选择，系统会按顺序保存每次修改。</p></div></div>`;
  }else if(revealed&&s.answer.length){
    feedback=`<div class="feedback ${s.correct?'good':'bad'}" role="status">${icon(s.correct?'check':'cross')}<div><strong>${s.correct?'回答正确':'回答错误'}${s.removed?' · 已移出错题集':''}</strong><p>你的选择：${choiceString(s.answer)}　参考答案：<b>${choiceString(s.correctAnswer)}</b>${quiz.kind==='practice'?'。可以继续修改选择。':quiz.kind==='review'?(s.removed?'。原做题记录仍然保留。':'。本次复习不会改写原做题记录。'):'。本场考试已交卷，答案已锁定。'}</p></div></div>`;
  }else if(revealed){
    feedback=`<div class="feedback neutral" role="status">${icon('book')}<div><strong>参考答案：${choiceString(correctAnswer)}</strong><p>本题尚未作答，查看答案不会计入做题记录。</p></div></div>`;
  }else if(active&&s.answer.length){feedback=`<div class="feedback neutral" role="status">${icon('check')}<div><strong>答案已保存</strong><p>交卷前可以随时更改选择，交卷后统一显示对错。</p></div></div>`;}
  const reviewBar=quiz.kind==='review'?`<div class="panel review-toolbar"><span class="muted">${quiz.entry.source==='practice'?'来自正常练习的最新错题':`来自第 ${examNumber(quiz.entry.examId)} 场 · ${fmtDate(quiz.entry.examCreated)} 的考试`} · 原选择 ${choiceString(quiz.entry.original)}</span>${switchControl(quiz.entry.source)}</div>`:'';
  const result=quiz.kind==='exam'&&!active?`<div class="panel result-strip"><div class="result-score mono">${quiz.exam.score}<small> / 100</small></div><div class="result-details"><strong>考试已完成，答案已锁定</strong>正确 ${quiz.exam.correctCount} 题 · 错误 ${quiz.exam.wrongCount} 题 · 用时 ${duration(quiz.exam.elapsed)}<br>${fmtDate(quiz.exam.submitted)} 交卷 · 按每题等权折算，非官方评分</div><span class="spacer"></span>${button('records','查看全部记录','small')}</div>`:'';
  return `<div class="quiz-head"><div class="quiz-title"><span class="eyebrow">${modeLabel}</span><h1>${labels[q.type]} <span class="muted">/</span> ${g.title}</h1><p>${g.part} · ${quiz.kind==='review'?'保留原题号，按错题来源复习':active?'题目仅在各部分内部打乱，题号沿用原题库':quiz.kind==='exam'?'保持本场考试的题目顺序，答案已锁定':'按原题库顺序练习'}</p></div>${quiz.kind==='exam'?`<div class="timer">${icon('clock')}<div><small>${active?'累计答题时间':'本场用时'}</small><strong class="mono" id="timer">${duration(quiz.exam.elapsed)}</strong></div></div>`:button(quiz.kind==='review'?'back-mistakes':'home',`${icon('back')}返回`,'small ghost')}</div>${result}${reviewBar}${quiz.kind==='practice'?practiceAnswerControl():''}<div class="quiz-layout"><div class="question-column"><article class="panel question-card"><div class="question-meta"><div class="row"><span class="pill blue">${labels[q.type]}</span><span class="small muted">题库第 <b class="mono">${q.number}</b> 题</span></div><span class="small muted mono">${itemIndex+1} / ${quiz.order.length}</span></div>${q.subsection?`<div class="subsection">${esc(q.subsection)}</div>`:''}<h2 class="question-text">${esc(q.text)}</h2><p class="question-hint">${q.type==='multiple'?'本题为多选题，请选择所有正确选项；再次点击可取消。':'请选择一个答案。'}${locked?(quiz.kind==='exam'?' 本场已交卷，答案不可修改。':' 本条错题已移出，复习记录已保存。'):''}</p><div class="options ${q.type==='multiple'?'multiple-options':''}" role="group" aria-label="答案选项">${q.options.map(o=>{
    const selected=s.answer.includes(o.key), correct=revealed&&correctAnswer.includes(o.key), wrong=revealed&&selected&&!correct;
    return `<button class="option ${selected?'selected':''} ${correct?'correct-option':''} ${wrong?'wrong-option':''}" data-action="choose" data-choice="${o.key}" aria-pressed="${selected}" aria-label="${o.key}：${esc(o.text)}" ${locked?'disabled':''}><span class="choice-key">${o.key}</span><span>${esc(o.text)}</span>${selected?'<span class="option-tail">已选</span>':''}</button>`;
  }).join('')}</div>${feedback}<div class="question-foot"><span>来源：原题库第 ${q.printedPage}${q.pdfEndPage!==q.pdfPage?'–'+(q.pdfEndPage-1):''} 页 · 答案以原文为准</span><div class="row">${!locked&&s.answer.length?button('clear-answer','清除本题选择','small ghost'):''}${!active?`<a href="/source.pdf#page=${q.pdfPage}" target="_blank" rel="noopener">核对原文 ↗</a>`:''}</div></div></article><div class="quiz-controls">${button('previous',`${icon('back')}上一题`,'',itemIndex<=0?'disabled':'')}<div class="right">${(quiz.kind==='practice'||active)?button('next-unanswered','下一道未答','ghost'):''}${button('next',`下一题${icon('arrow')}`,'primary',itemIndex>=quiz.order.length-1?'disabled':'')}</div></div><p class="key-help">快捷键：数字或 A–F 选择选项，← / → 切换题目</p></div>${answerBoard(answered,key,active)}</div>`;
}
function practiceAnswerControl(){
  const session=quiz.practiceSession;
  const hint=session.error|| (session.loading&&session.showAnswers?'正在读取本套参考答案…':session.showAnswers?'已显示本套所有题目的参考答案，查看不会改变作答记录。':'每次进入默认关闭；关闭时，作答后仍会照常显示对错。');
  return `<div class="panel review-toolbar"><label class="switch-wrap"><input id="practice-answers-toggle" type="checkbox" role="switch" aria-describedby="practice-answers-help" ${session.showAnswers?'checked':''}><span>显示整套正确答案</span></label><span id="practice-answers-help" class="small muted" role="status">${esc(hint)}</span></div>`;
}
async function togglePracticeAnswers(show){
  if(quiz?.kind!=='practice')return;
  const session=quiz.practiceSession;
  session.showAnswers=show;session.error='';
  if(!show||session.answers||session.loading){render();$('#practice-answers-toggle')?.focus({preventScroll:true});return;}
  session.loading=true;render();
  try{
    const result=await api('/api/practice/answers?type='+encodeURIComponent(session.type));
    session.answers=result.answers;
  }catch(error){
    if(session.showAnswers)session.error='读取答案失败：'+error.message+' 请重新打开开关重试。';
    session.showAnswers=false;
  }finally{
    session.loading=false;
    if(quiz?.practiceSession===session){render();$('#practice-answers-toggle')?.focus({preventScroll:true});}
  }
}
function answerBoard(answered,key,active){
  const good=quiz.order.filter(k=>statusFor(k)==='good').length,bad=quiz.order.filter(k=>statusFor(k)==='bad').length,partial=quiz.order.filter(k=>statusFor(k)==='partial').length;
  const objects=quiz.order.map(id=>({key:id,q:questions.get(quiz.kind==='review'?quiz.entries.find(e=>e.id===id).qid:id)}));
  const hasMultiple=objects.some(o=>o.q.type==='multiple');
  return `<aside class="panel answer-board" aria-label="分组题号导航"><div class="board-head"><div class="row between"><h2>答题卡</h2><span class="small muted">${answered} / ${quiz.order.length} 已答</span></div><div class="progress">${active?`<span style="width:${answered/quiz.order.length*100}%"></span>`:`<span class="good" style="width:${good/quiz.order.length*100}%"></span><span class="partial" style="width:${partial/quiz.order.length*100}%"></span><span class="bad" style="width:${bad/quiz.order.length*100}%"></span>`}</div><div class="legend"><span><i></i>未答</span>${active?'<span><i class="done"></i>已答</span>':`<span><i class="good"></i>正确</span>${hasMultiple?'<span><i class="partial"></i>漏选</span>':''}<span><i class="bad"></i>错误</span>`}<span>深色边框为当前题</span></div><form class="board-jump" id="jump-form"><input aria-label="输入原题号" id="jump-number" inputmode="numeric" pattern="[0-9]+" placeholder="输入原题号跳转" required><button class="btn small" type="submit">跳转</button></form></div><div class="board-groups">${data.bank.groups.map(g=>{
    const entries=objects.filter(o=>o.q.group===g.id);if(!entries.length)return '';
    return `<details class="question-group" open data-group="${g.id}"><summary>${g.part} · ${g.title}${quiz.kind==='review'?` · ${labels[g.type]}`:''}<small>${entries.filter(o=>answerState(o.key).answer.length).length}/${entries.length}</small></summary><div class="number-grid">${entries.map(o=>`<button class="number-btn ${statusFor(o.key)} ${o.key===key?'current':''}" data-action="jump" data-key="${esc(o.key)}" title="题库第 ${o.q.number} 题${quiz.kind==='review'&&quiz.entry.source==='exam'?' · '+fmtDate(quiz.entries.find(e=>e.id===o.key).examCreated):''}" aria-label="跳转题库第 ${o.q.number} 题，${{good:'正确',partial:'漏选',bad:'错误',done:'已答'}[statusFor(o.key)]||'未答'}" ${o.key===key?'aria-current="step"':''}>${o.q.number}</button>`).join('')}</div></details>`;
  }).join('')}</div>${active?`<div class="board-foot">${button('submit','交卷并查看结果','primary',answered!==quiz.order.length||busy?'disabled':'')}<p>${answered!==quiz.order.length?`还差 ${quiz.order.length-answered} 题，全部作答后可交卷`:'已全部作答，可以交卷；交卷后不能修改答案'}</p></div>`:quiz.kind==='exam'?`<div class="board-foot">${button('first-wrong','定位本卷错题','',quiz.exam.wrongCount?'':'disabled')}</div>`:''}</aside>`;
}
function switchControl(source){return `<label class="switch-wrap"><input type="checkbox" data-setting="autoRemove:${source}" ${data.settings['autoRemove:'+source]?'checked':''}><span>复习答对后自动移出</span></label>`;}

function records(){
  const tab=parts[1]||'exams';
  const header=heading('做题记录','未交卷的考试可继续作答；已交卷的考试保留题序、选择和结果。','学习档案')+`<div class="tabs"><button class="tab ${tab==='exams'?'active':''}" data-action="record-tab" data-value="exams">考试记录 <span class="muted">${data.exams.length}</span></button><button class="tab ${tab==='practice'?'active':''}" data-action="record-tab" data-value="practice">练习与复习记录</button></div>`;
  if(tab==='practice'){
    const n=Object.keys(data.practice).length,c=Object.values(data.practice).filter(p=>p.correct).length;
    return header+`<div class="stats-row"><div class="panel stat-box"><span>已练习题数</span><strong>${n}<small> / 563</small></strong></div><div class="panel stat-box"><span>当前答对</span><strong>${c}</strong></div><div class="panel stat-box"><span>历史选择次数</span><strong>${historyData?.total||0}</strong></div></div><div class="section-title"><h2>每一次选择都有记录</h2><span class="small muted">按时间倒序 · 包括答案修改</span></div>${!historyData?.items.length?empty('还没有练习记录','在练习模式中选择答案后，这里会自动保留每一次选择。'):`<div class="panel table-wrap"><table class="history-table"><thead><tr><th>时间</th><th>来源</th><th>题号 / 题型</th><th>当时选择</th><th>当时结果</th><th></th></tr></thead><tbody>${historyData.items.map(e=>`<tr><td>${fmtDate(e.at)}</td><td>${{practice:'正常练习','review-practice':'练习错题复习','review-exam':'考试错题复习'}[e.scope]}</td><td>${e.qid} · ${labels[questions.get(e.qid).type]}</td><td>${choiceString(e.answer)}</td><td><span class="pill ${e.correct==null?'':e.correct?'green':'red'}">${e.correct==null?'已清空':e.correct?'正确':'错误'}</span></td><td><a href="#/practice/${questions.get(e.qid).type}/${e.qid}">去练习</a></td></tr>`).join('')}</tbody></table></div><div class="pager">${button('history-prev','上一页','small',historyPage<=1?'disabled':'')}<span class="small muted">${historyPage} / ${Math.ceil(historyData.total/30)}</span>${button('history-next','下一页','small',historyPage*30>=historyData.total?'disabled':'')}</div>`}`;
  }
  const exams=data.exams.filter(e=>recordFilter==='all'||e.status===recordFilter);
  return header+`<div class="filter-row"><span class="small muted">共 ${data.exams.length} 场 · ${data.exams.filter(e=>e.status==='active').length} 场未交卷</span><select id="record-filter" aria-label="筛选考试状态"><option value="all">全部状态</option><option value="active" ${recordFilter==='active'?'selected':''}>未交卷</option><option value="submitted" ${recordFilter==='submitted'?'selected':''}>已交卷</option></select></div>${!exams.length?empty('这里会保存你的每一场考试','从题库选择考试模式开始。退出后，未交卷的题序和答案会完整保留。'):`<div class="record-grid">${exams.map(e=>`<article class="panel record-card"><div class="record-symbol">${icon(e.type)}</div><div class="record-info"><h3>${labels[e.type]}全题考试 <span class="pill ${e.status==='submitted'?'green':'blue'}">${e.status==='submitted'?'已交卷':e.allAnswered?'全部已答 · 待交卷':'未完成 · 可继续'}</span></h3><p>第 ${examNumber(e.id)} 场 · ${fmtDate(e.created)} 开始 · ${e.answered} / ${e.total} 已答 · 用时 ${duration(e.elapsed)}${e.status==='submitted'?`<br>${fmtDate(e.submitted)} 交卷 · 错题 ${e.wrongCount} 道`:''}</p></div><div class="record-metric"><strong>${e.status==='submitted'?e.score:Math.round(e.answered/e.total*100)+'%'}</strong><small>${e.status==='submitted'?'等权折算 / 100':'已完成'}</small></div>${button('open-exam',e.status==='submitted'?'查看试卷':'继续作答',e.status==='submitted'?'':'primary',`data-id="${e.id}"`)}</article>`).join('')}</div>`}`;
}
function mistakesPage(){
  const source=parts[1]==='exam'?'exam':'practice',all=data.mistakes.filter(m=>m.source===source),list=all.filter(m=>mistakeFilter==='all'||questions.get(m.qid).type===mistakeFilter);
  return heading('错题集','按来源整理，复习选择独立保存。是否在答对后移出，由你决定。','查漏补缺')+`<div class="tabs">${['practice','exam'].map(s=>`<button class="tab ${source===s?'active':''}" data-action="mistake-tab" data-value="${s}">${s==='practice'?'练习错题':'考试错题'} <span class="muted">${data.mistakes.filter(m=>m.source===s).length}</span></button>`).join('')}</div><div class="filter-row"><select id="mistake-filter" aria-label="筛选错题类型"><option value="all">全部题型</option>${Object.entries(labels).map(([v,l])=>`<option value="${v}" ${mistakeFilter===v?'selected':''}>${l}</option>`).join('')}</select>${switchControl(source)}</div><div class="note-banner">${source==='practice'?'正常练习中改对答案，会自动移出这道错题。在本错题集中答对时，仅在上方开关开启后移出。':'每次交卷的错题分别保留，同一道题在多场考试中答错会出现多条记录。后续考试答对，不会影响以前的错题。'} 开关只作用于开启后的复习作答。</div>${!list.length?empty('这个分类暂时没有错题','继续练习，或切换上方分类查看。'): `<div class="section-title"><span class="small muted">${list.length} ${source==='exam'?'条错题记录':'道错题'}</span>${button('review-first',`开始复习${icon('arrow')}`,'primary small',`data-source="${source}"`)}</div><div class="mistake-list">${list.map(m=>{const q=questions.get(m.qid),g=groups.get(q.group);return `<article class="panel mistake-card"><span class="mistake-number">${q.number}</span><div class="info"><h3>${esc(q.text)}</h3><p>${labels[q.type]} · ${g.part} ${g.title} · 原选择 ${choiceString(m.original)}${source==='exam'?`<br>第 ${examNumber(m.examId)} 场 · ${fmtDate(m.examCreated)} 的考试`:''} ${m.reviewCorrect?'<span class="pill green">复习已答对 · 保留中</span>':''}</p></div>${button('review','复习这题','small',`data-id="${esc(m.id)}" data-source="${source}"`)}</article>`;}).join('')}</div>`}`;
}
function dataPage(){return heading('数据与备份','所有学习记录保存在本机程序文件夹中，换浏览器也能继续。','本地存储')+`<section class="panel data-panel"><h2>学习记录保存在这里</h2><p>练习的最新答案、每次选择的历史、考试题序与计时、每场考试的错题，以及错题复习设置，均写入本地数据库。正常退出不会清除记录。</p><code class="path">${esc(data.dataPath)}</code><p>每个自然日首次启动时保存一份自动备份；点击下方“关闭程序”也会生成退出备份。需要迁移时，先关闭程序，再复制整个程序文件夹。</p><a class="btn primary" href="/api/backup" download>${icon('download')}导出完整备份</a><a class="btn" href="/source.pdf#page=40" target="_blank" rel="noopener">${icon('book')}查看题库原文</a></section><section class="panel data-panel"><h2>关于这份题库</h2><p>${esc(data.bank.title)}（2026 版）。题目从印刷第 39 页开始，对应 PDF 第 40 页。共 245 道单选、181 道多选、137 道判断，合计 563 道。保留原题号、六个部分及第六部分的小分类。</p><p>练习中多选题每次选择都即时判定，只有与参考答案完全一致才记为正确。考试不设倒计时和时限；停留在可见的答题页面时累计时间，离开、切换标签或关闭页面时暂停，重新进入后继续。</p><p>本程序用于个人备考，参考答案按用户提供的 PDF 原文录入。未添加原文没有的解析，可随时打开对应原文页核对。</p></section><section class="panel data-panel"><h2>结束本次使用</h2><p>关闭前会保留已保存的记录。下次双击“启动华电题库.cmd”即可重新打开。</p>${button('shutdown','保存并关闭程序','danger')}</section>`;}

function render(){
  if(!data)return;
  const previousScroll=$('.board-groups')?.scrollTop || 0;
  const collapsed=new Set([...document.querySelectorAll('.question-group:not([open])')].map(e=>e.dataset.group));
  const focused=document.activeElement?.dataset?.choice;
  let content;
  if(quiz)content=quizPage();else if(parts[0]==='records')content=records();else if(parts[0]==='mistakes')content=mistakesPage();else if(parts[0]==='data')content=dataPage();else content=home();
  $('#app').innerHTML=shell(content);
  const board=$('.board-groups');if(board){board.scrollTop=previousScroll;collapsed.forEach(id=>{const d=$(`details[data-group="${id}"]`);if(d)d.open=false;});}
  if(focused)$(`[data-choice="${focused}"]`)?.focus({preventScroll:true});
  updateClock();
}

async function stopTimer(){
  if(timerId){const id=timerId;timerId=null;await api('/api/exam/tick',{id,owner,active:false}).catch(()=>{});}
}
async function heartbeat(){
  if(!timerId||document.hidden)return;
  const id=timerId;
  try{const result=await api('/api/exam/tick',{id,owner,active:true});if(timerId!==id)return;timerBase=result.elapsed;timerAt=performance.now();if(quiz?.exam?.id===id)quiz.exam.elapsed=result.elapsed;if(result.status==='submitted'){await route();return;}updateClock();}
  catch(error){setStatus('计时同步失败，请检查程序是否仍在运行');}
}
function updateClock(){const el=$('#timer');if(el&&quiz?.kind==='exam')el.textContent=duration(timerId&&!document.hidden?timerBase+(performance.now()-timerAt)/1000:quiz.exam.elapsed);}
setInterval(heartbeat,5000);setInterval(updateClock,1000);
function beaconPause(){if(timerId)navigator.sendBeacon('/api/exam/tick',new Blob([JSON.stringify({id:timerId,owner,active:false,token})],{type:'application/json'}));}
document.addEventListener('visibilitychange',()=>{if(document.hidden)beaconPause();else if(timerId)heartbeat();});
window.addEventListener('pagehide',beaconPause);
window.addEventListener('beforeunload',event=>{if(saveCount>0){event.preventDefault();event.returnValue='';}});

async function route(){
  const serial=++routeSerial;
  const next=location.hash.replace(/^#\/?/,'').split('/').filter(Boolean).map(decodeURIComponent);
  const practiceType=next[0]==='practice'?(labels[next[1]]?next[1]:'single'):null;
  if(practiceSession?.type!==practiceType)practiceSession=null;
  if(practiceType&&!practiceSession)practiceSession={type:practiceType,showAnswers:false,answers:null,loading:false,error:''};
  await savePromise.catch(()=>{});
  if(timerId&&(next[0]!=='exam'||next[1]!==timerId))await stopTimer();
  try{
    await refresh();if(serial!==routeSerial)return;
    parts=next;quiz=null;lastError='';
    if(parts[0]==='practice'){
      const type=labels[parts[1]]?parts[1]:'single',order=questionIds(type),qid=order.includes(parts[2])?parts[2]:order.find(id=>!data.practice[id])||order[0];
      quiz={kind:'practice',type,qid,order,practiceSession};setPref('huadian:last:'+type,qid);
    }else if(parts[0]==='exam'){
      const exam=await api('/api/exam/'+parts[1]);if(serial!==routeSerial)return;
      const qid=exam.order.includes(parts[2])?parts[2]:exam.currentQ||exam.order[0];
      quiz={kind:'exam',type:exam.type,qid,order:exam.order,exam};
      if(exam.status==='active'){
        await api('/api/exam/position',{id:exam.id,qid});
        timerId=exam.id;timerBase=exam.elapsed;timerAt=performance.now();
        await heartbeat();
      }else if(timerId)await stopTimer();
    }else if(parts[0]==='review'){
      const entry=data.mistakes.find(m=>m.id===parts[1]);
      if(!entry){goto('mistakes/'+(parts[1]?.startsWith('exam:')?'exam':'practice'));return;}
      const entries=data.mistakes.filter(m=>m.source===entry.source&&(mistakeFilter==='all'||questions.get(m.qid).type===mistakeFilter));
      if(!entries.some(m=>m.id===entry.id))entries.push(entry);
      quiz={kind:'review',qid:entry.qid,entry,entries,order:entries.map(m=>m.id)};
    }else if(parts[0]==='records'&&parts[1]==='practice')historyData=await api('/api/history?page='+historyPage);
    if(serial!==routeSerial)return;
    saveLabel='所有选择自动保存';render();
    window.scrollTo(0,0);
    if(quiz)requestAnimationFrame(()=>{
      const current=$('.number-btn.current'), board=$('.board-groups'), group=current?.closest('details');
      if(group)group.open=true;
      if(current&&board){
        const cell=current.getBoundingClientRect(), area=board.getBoundingClientRect();
        if(cell.top<area.top)board.scrollTop-=area.top-cell.top+8;
        else if(cell.bottom>area.bottom)board.scrollTop+=cell.bottom-area.bottom+8;
      }
    });
  }catch(error){if(!data){$('#app').innerHTML=`<div class="loading"><h2>暂时无法连接本地程序</h2><p>${esc(error.message)}</p><p>请双击“启动华电题库.cmd”后刷新此页。</p>${button('retry','重新连接','primary')}</div>`;}else errorMessage(error);}
}

function jump(key){
  if(quiz.kind==='practice')goto('practice/'+quiz.type+'/'+key);
  else if(quiz.kind==='exam')goto('exam/'+quiz.exam.id+'/'+key);
  else goto('review/'+encodeURIComponent(key));
}
async function saveAnswer(choice,clear=false){
  if(!quiz)return;
  const q=questions.get(quiz.qid),key=quiz.kind==='review'?quiz.entry.id:q.id,s=answerState(key);
  if((quiz.kind==='exam'&&quiz.exam.status!=='active')||s.removed)return;
  let answer=clear?[]:q.type==='multiple'?(s.answer.includes(choice)?s.answer.filter(x=>x!==choice):[...s.answer,choice].sort()):[choice];
  if(JSON.stringify(answer)===JSON.stringify(s.answer)&&!(quiz.kind==='review'&&s.correct&&data.settings['autoRemove:'+quiz.entry.source]))return;
  const context=quiz,saveKey=choiceToken(context,key),revision=++choiceRevision;
  pendingAnswers.set(saveKey,{answer,revision});saveCount++;busy=true;lastError='';saveLabel='正在保存…';render();
  savePromise=savePromise.catch(()=>{}).then(async()=>{
    try{
      if(context.kind==='practice'){
        const result=await api('/api/practice',{qid:q.id,answer});
        if(result)data.practice[q.id]=result;else delete data.practice[q.id];
        data.mistakes=(await api('/api/bootstrap')).mistakes;
      }else if(context.kind==='exam')context.exam=await api('/api/exam/answer',{id:context.exam.id,qid:q.id,answer});
      else{
        const result=await api('/api/review',{id:context.entry.id,answer});
        Object.assign(context.entry,{review:answer,reviewCorrect:result.correct,correctAnswer:result.correctAnswer,removed:result.removed});
        if(result.removed){data.mistakes=data.mistakes.filter(m=>m.id!==context.entry.id);toast('已移出这条错题，原始做题记录仍保留');}
      }
      saveLabel='已保存到本机';
    }catch(error){lastError=error.message;saveLabel='本次选择保存失败';toast(lastError);}
    finally{
      if(pendingAnswers.get(saveKey)?.revision===revision)pendingAnswers.delete(saveKey);
      saveCount--;busy=saveCount>0;if(busy)saveLabel='正在保存…';render();
    }
  });
  await savePromise;
}
function confirmDialog(title,body,confirmText,callback){
  const dialog=$('#confirm-dialog');
  $('#dialog-content').innerHTML=`<h2 id="dialog-title">${title}</h2><p>${body}</p><div class="row">${button('cancel-dialog','返回检查')}${button('confirm-dialog',confirmText,'primary')}</div>`;
  dialog.showModal();dialog._callback=callback;
}

document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-action]');if(!target||target.disabled)return;
  const action=target.dataset.action;
  try{
    if(action==='home')goto('home');
    else if(action==='retry')await route();
    else if(action==='mode'){homeMode=target.dataset.value;setPref('huadian:mode',homeMode);render();}
    else if(action==='start'){
      const type=target.dataset.type;
      if(homeMode==='exam'){target.disabled=true;const exam=await api('/api/exam/start',{type});goto('exam/'+exam.id);}
      else goto('practice/'+type+'/'+getPref('huadian:last:'+type,questionIds(type).find(id=>!data.practice[id])||questionIds(type)[0]));
    }else if(action==='choose')await saveAnswer(target.dataset.choice);
    else if(action==='clear-answer')await saveAnswer(null,true);
    else if(action==='jump')jump(target.dataset.key);
    else if(action==='previous'||action==='next'){
      const key=quiz.kind==='review'?quiz.entry.id:quiz.qid,idx=quiz.order.indexOf(key)+(action==='previous'?-1:1);
      if(quiz.order[idx])jump(quiz.order[idx]);
    }else if(action==='next-unanswered'){
      const index=quiz.order.indexOf(quiz.qid),rotated=[...quiz.order.slice(index+1),...quiz.order.slice(0,index+1)],next=rotated.find(id=>!answerState(id).answer.length);
      if(next)jump(next);else toast('所有题目均已作答。');
    }else if(action==='submit')confirmDialog('确认交卷？',`本场 ${quiz.order.length} 道${labels[quiz.type]}已全部作答。交卷后会显示答案与成绩，<b>本场答案将锁定，不能再修改</b>。`,'确认交卷',async()=>{await savePromise;const result=await api('/api/exam/submit',{id:quiz.exam.id});timerId=null;quiz.exam=result;await refresh();render();window.scrollTo(0,0);toast('已交卷，考试记录与错题已保存');});
    else if(action==='cancel-dialog')$('#confirm-dialog').close();
    else if(action==='confirm-dialog'){const dialog=$('#confirm-dialog'),callback=dialog._callback;target.disabled=true;try{await callback();dialog.close();}catch(e){target.disabled=false;throw e;}}
    else if(action==='records')goto('records/exams');
    else if(action==='open-exam')goto('exam/'+target.dataset.id);
    else if(action==='record-tab'){historyPage=1;goto('records/'+target.dataset.value);}
    else if(action==='history-prev'||action==='history-next'){historyPage+=action==='history-prev'?-1:1;historyData=await api('/api/history?page='+historyPage);render();}
    else if(action==='first-wrong'){const next=quiz.order.find(id=>!quiz.exam.results[id].correct);if(next)jump(next);}
    else if(action==='mistake-tab'){mistakeFilter='all';goto('mistakes/'+target.dataset.value);}
    else if(action==='review')goto('review/'+encodeURIComponent(target.dataset.id));
    else if(action==='review-first'){const entry=data.mistakes.find(m=>m.source===target.dataset.source&&(mistakeFilter==='all'||questions.get(m.qid).type===mistakeFilter));if(entry)goto('review/'+encodeURIComponent(entry.id));}
    else if(action==='back-mistakes')goto('mistakes/'+quiz.entry.source);
    else if(action==='shutdown')confirmDialog('保存并关闭程序？','已保存的学习记录会继续保留，并生成一份退出备份。下次双击启动文件即可继续。','关闭程序',async()=>{await stopTimer();await api('/api/shutdown',{});$('#app').innerHTML='<div class="loading"><h2>学习记录已保存</h2><p>程序已关闭，可以关闭此标签页。</p><p>下次双击“启动华电题库.cmd”即可继续。</p></div>';});
  }catch(error){errorMessage(error);}
});
document.addEventListener('change',async event=>{
  const el=event.target;
  try{
    if(el.id==='practice-answers-toggle')await togglePracticeAnswers(el.checked);
    else if(el.dataset.setting){data.settings=await api('/api/settings',{key:el.dataset.setting,value:el.checked});setStatus('设置已保存');toast(el.checked?'已开启：之后复习答对的错题会移出':'已关闭：复习答对后仍保留错题');}
    else if(el.id==='record-filter'){recordFilter=el.value;render();}
    else if(el.id==='mistake-filter'){mistakeFilter=el.value;render();}
  }catch(error){el.checked=!el.checked;errorMessage(error);}
});
document.addEventListener('submit',event=>{
  if(event.target.id!=='jump-form')return;event.preventDefault();
  const value=String(Number($('#jump-number').value));
  const key=quiz.kind==='review'?quiz.entries.find(e=>e.qid===value)?.id:quiz.order.find(id=>id===value);
  if(key)jump(key);else toast('这份题目中没有该题号，请输入右侧答题卡中的原题号。');
});
document.addEventListener('keydown',event=>{
  if(!quiz||$('#confirm-dialog').open||/INPUT|TEXTAREA|SELECT|A|SUMMARY/.test(event.target.tagName)||event.ctrlKey||event.metaKey||event.altKey)return;
  const q=questions.get(quiz.qid),index=/^[1-8]$/.test(event.key)?Number(event.key)-1:'abcdefgh'.indexOf(event.key.toLowerCase());
  if(index>=0&&q.options[index]){event.preventDefault();saveAnswer(q.options[index].key);}
  else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();const key=quiz.kind==='review'?quiz.entry.id:quiz.qid,idx=quiz.order.indexOf(key)+(event.key==='ArrowLeft'?-1:1);if(quiz.order[idx])jump(quiz.order[idx]);}
});
window.addEventListener('hashchange',route);
route();
