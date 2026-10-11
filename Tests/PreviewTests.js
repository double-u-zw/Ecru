const fs=require('fs'),vm=require('vm'),assert=require('assert');
const root='Resources/Preview/';
let html='',text='',data={},children=[];
const host={set innerHTML(x){html=x;text=x.replace(/<[^>]*>/g,'')},get innerHTML(){return html},set textContent(x){text=x;html=x},get textContent(){return text},querySelector(q){return html.includes('katex-error')?{}:null},dataset:data,appendChild(x){children.push(x)}};
const context={console,document:{compatMode:"CSS1Compat",getElementById:()=>host,createElement:()=>({})}};vm.createContext(context);
for(const path of ['vendor/markdown-it.min.js','vendor/katex/katex.min.js','vendor/texmath.js','preview.js'])vm.runInContext(fs.readFileSync(root+path,'utf8'),context);
let serial=0;function render(source,options={}){children=[];context.renderNote({serial:++serial,note:'A',revision:String(serial),source,macros:{},...options});return html}
assert(render('中文 **正文** $x^2$').includes('katex'));
assert(render('$$\\begin{aligned}a&=b\\\\c&=d\\end{aligned}$$').includes('katex-display'));
assert(render('$$\\begin{cases}x&x>0\\\\0&x<0\\end{cases}$$').includes('katex'));
assert(render('$$\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}$$').includes('katex'));
assert(!render('`$x$`\n\n```\n$$a$$\n```').includes('class="katex"'));
assert(!render('\\$x\\$').includes('class="katex"'));
assert(!render('<script>alert(1)</script> ![img](https://example.com/a.png)').includes('<script>'));
assert(!html.includes('<img'));
assert(render('$\\badcommand{x}$').includes('badcommand'));
render('unclosed $formula');assert(children.length>0);
render('B',{note:'B'});let latest=html;context.renderNote({serial:0,note:'A',source:'STALE'});assert.equal(html,latest);assert.equal(data.note,'B');
render('$\\gdef\\foo{x}\\foo$');assert(render('$\\foo$').includes('\\foo'));
assert(!render('$\\href{javascript:alert(1)}{x}$').includes('href="javascript:'));
const summaries=context.summarizeNoteSources([
 {id:'A',revision:'1',source:'中文 **推导** $\\frac{a}{b}$',quote:''},
 {id:'B',revision:'2',source:'$$\\begin{aligned}a&=b\\\\c&=d\\end{aligned}$$',quote:''},
 {id:'C',revision:'3',source:'```tex\n\\begin{matrix}a\\end{matrix}\n```',quote:''}
]);
assert(summaries[0].text.includes('中文 推导')&&summaries[0].text.includes('〔公式〕'));
assert(summaries[1].text==='〔公式〕'&&!summaries[1].text.includes('begin'));
assert(summaries[2].text==='〔代码〕');
render('x'.repeat(500001),{note:'too-long'});assert.equal(data.note,'too-long');assert(text.includes('预览上限'));
const incomplete=context.summarizeNoteSources([{id:'broken',revision:'1',quote:'',source:'$$'+String.raw`\\frac{a}{b}+`.repeat(100)}])[0].text;
assert(!incomplete.includes('frac')&&incomplete.includes('公式'));
console.log('19 offline parser, math, escaping, macro-isolation and stale-render checks passed');
