'use strict';
let lastRequest = -1;
let formulaSources = [];
let formulaRequest = null;
function copyFormula(index) {
  if (!formulaRequest || formulaRequest.serial !== lastRequest) return;
  const source=formulaSources[index];
  if (source && window.webkit?.messageHandlers.copyFormula) window.webkit.messageHandlers.copyFormula.postMessage({...formulaRequest,source});
}
function renderNote(request) {
  if (request.serial < lastRequest) return;
  lastRequest = request.serial;
  const host = document.getElementById('body');
  function measured() {
    host.dataset.note = request.note; host.dataset.revision = request.revision; host.dataset.document = request.document;
    if (typeof window !== "undefined") { reportNoteSize(request); document.fonts?.ready.then(() => reportNoteSize(request)); }
  }
  if (request.source.length > 500000) { host.textContent = '正文超过预览上限；源码仍可编辑和保存。'; measured(); return; }
  const md = markdownit({html:false,linkify:false,typographer:false});
  md.use(texmath,{engine:katex,delimiters:['dollars','brackets','beg_end'],katexOptions:{trust:false,throwOnError:false,maxExpand:200,maxSize:20,macros:Object.fromEntries(Object.entries(request.macros || {}).filter(([key,value]) => /^\\[a-zA-Z]+$/.test(key) && typeof value === "string"))}});
  md.renderer.rules.image = (tokens,i) => '<span class="hint">[图片未自动加载：'+md.utils.escapeHtml(tokens[i].content)+']</span>';
  formulaSources=[];formulaRequest={serial:request.serial,document:request.document,note:request.note,revision:request.revision};
  for (const name of [...texmath.inlineRuleNames,...texmath.blockRuleNames]) {
    const render=md.renderer.rules[name];if (!render) continue;
    md.renderer.rules[name]=(tokens,i,...args)=>{
      const id=formulaSources.push(tokens[i].content)-1;
      const block=name.startsWith('math_block') || name==='math_inline_double';
      return '<'+(block?'div':'span')+' class="formula '+(block?'block':'inline')+'">'+render(tokens,i,...args)+'<button type="button" class="copy-math" data-formula="'+id+'" title="复制公式 LaTeX" aria-label="复制公式 LaTeX">复制 LaTeX</button>'+(block?'<span class="overflow-hint">↔ 横向滚动查看完整公式</span>':'')+'</'+(block?'div':'span')+'>';
    };
  }
  host.onclick=(event)=>{const button=event.target.closest?.('button[data-formula]');if(button) copyFormula(Number(button.dataset.formula));};
  host.onkeydown=(event)=>{
    const area=event.target.closest?.('.katex-display,eqn');
    if (!area || area.tabIndex!==0 || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
    const steps={ArrowLeft:-48,ArrowRight:48,Home:-Infinity,End:Infinity};
    if (!(event.key in steps)) return;
    area.scrollLeft=Math.max(0,Math.min(area.scrollWidth-area.clientWidth,area.scrollLeft+steps[event.key]));
    event.preventDefault();
  };
  try {
    host.innerHTML = md.render(request.source);
    // Display explicit local math diagnostics without modifying source text.
    if (host.querySelector('.katex-error') || /(^|[^\\])\$/.test(host.textContent.replace(/\$\d/g,''))) {
      const hint=document.createElement('p');hint.className='hint';hint.textContent='部分数学表达未能排版，请检查分隔符或公式命令。源文仍可保存。';host.appendChild(hint);
    }
  } catch(e) { host.textContent=request.source; const hint=document.createElement('p');hint.className='hint';hint.textContent='预览失败，已显示源文。';host.appendChild(hint); }
  measured();
}

// Width is chosen once from intrinsic content, then wrapped height is measured.
// Native viewport changes create a new request; frame changes do not loop back here.
function reportNoteSize(request) {
  if (request.serial !== lastRequest) return;
  const host=document.getElementById('body');
  if (host.dataset.note!==request.note || host.dataset.revision!==request.revision || host.dataset.document!==request.document) return;
  const limits=request.layout || {minimum:244,base:384,maximum:664};
  const maximum=Math.max(200,limits.maximum), minimum=Math.min(maximum,limits.minimum);
  let width=Math.min(maximum,Math.max(minimum,limits.base));
  host.style.width=width+'px';
  const prose=Array.from(host.children).filter(e=>!e.querySelector('eqn,.katex-display') && !['PRE','TABLE'].includes(e.tagName));
  if (host.children.length<=2 && host.textContent.length<85 && !host.querySelector('eqn,.katex-display,pre,table')) {
    let intrinsic=0;
    for (const item of prose) {
      const clone=item.cloneNode(true);clone.style.cssText='position:absolute;visibility:hidden;width:max-content;max-width:none;white-space:nowrap;';
      host.appendChild(clone);intrinsic=Math.max(intrinsic,clone.getBoundingClientRect().width);clone.remove();
    }
    width=Math.min(maximum,Math.max(minimum,Math.ceil(intrinsic+24)));
  }
  let mathWidth=0;
  for (const item of host.querySelectorAll('eqn,.katex-display')) {
    const clone=item.cloneNode(true);clone.style.cssText='position:absolute;visibility:hidden;width:max-content;max-width:none;overflow:visible;white-space:nowrap;';
    for (const button of clone.querySelectorAll('.copy-math,.overflow-hint')) button.remove();
    for (const k of clone.querySelectorAll('.katex-display,.katex')) {k.style.width='max-content';k.style.display='inline-block';}
    host.appendChild(clone);mathWidth=Math.max(mathWidth,clone.getBoundingClientRect().width+24);clone.remove();
  }
  width=Math.min(maximum,Math.max(width,Math.ceil(mathWidth)));
  host.style.width=width+'px';
  for (const region of host.querySelectorAll('.formula.block')) {
    const overflowing=Array.from(region.querySelectorAll('eqn,.katex-display')).some(math=>math.scrollWidth>math.clientWidth+1);
    region.classList.toggle('overflow',overflowing);
    const scrollArea=region.querySelector('.katex-display') || region.querySelector('eqn');
    if (scrollArea) {scrollArea.tabIndex=overflowing ? 0 : -1;scrollArea.setAttribute('aria-label',overflowing ? '公式，可横向滚动' : '公式');}
  }
  const height=Math.ceil(host.getBoundingClientRect().height);
  if (window.webkit && window.webkit.messageHandlers.noteSize) window.webkit.messageHandlers.noteSize.postMessage({serial:request.serial,document:request.document,note:request.note,revision:request.revision,width,height});
}

// One parser in the existing window renderer; plain summaries contain semantic
// formula hints, never a long TeX command string or a per-result WebView.
function summarizeNoteSources(notes) {
  const md=markdownit({html:false,linkify:false,typographer:false});
  md.use(texmath,{engine:katex,delimiters:['dollars','brackets','beg_end']});
  function text(tokens) {
    return tokens.map(t=>{
      if (t.type.includes('math')) return '〔公式〕';
      if (t.type==='code_inline'||t.type==='fence'||t.type==='code_block') return '〔代码〕';
      if (t.children) return text(t.children);
      if (t.type==='text') return t.content.length>30 && /\\[a-zA-Z]+/.test(t.content) ? '〔公式源文，点击查看〕' : t.content;
      if (t.type==='softbreak'||t.type==='hardbreak'||t.type.endsWith('_close')) return ' ';
      return '';
    }).join('');
  }
  return notes.map(n=>({id:n.id,revision:n.revision,text:(text(md.parse(n.source,{})).trim() || n.quote || '空正文 · 点击编辑').replace(/\s+/g,' ').slice(0,90)}));
}
