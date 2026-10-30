import {readFile,writeFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {head,header,footer,site,repo,github,esc} from './build-pages.mjs';

function inline(source){
 const tokens=[];
 const token=html=>{const id=tokens.length;tokens.push(html);return `\u0001${id}\u0002`;};
 let text=source.replace(/`([^`]+)`/g,(_,code)=>token(`<code>${esc(code)}</code>`));
 text=text.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+|[^\s)]+)\)/g,(_,label,url)=>token(`<a href="${esc(url)}">${inline(label)}</a>`));
 text=esc(text).replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/\*([^*]+)\*/g,'<em>$1</em>');
 return text.replace(/\u0001(\d+)\u0002/g,(_,id)=>tokens[Number(id)]);
}
function architecture(lang){
 const ja=lang==='ja',nodes=ja?[
  ['編集する曲','Project','音型・規則・配置'],['規則を展開','compileProject','拍の区間とHzを決める'],['解決した音符','Resolved','同じ結果を画面へ返す'],['音声計画へ','toAudioPlan','拍をフレームへ変える'],['検査したデータ','preparePlan','容量・領域を確かめる'],
 ]:[['Editable score','Project','Patterns, rules, placements'],['Resolve music','compileProject','Beat intervals and Hz'],['Concrete notes','Resolved','The same notes return to the UI'],['Audio plan','toAudioPlan','Beats become sample frames'],['Checked flat data','preparePlan','Admit sizes and memory ranges']];
 return `<figure class="architecture-figure"><div class="diagram-process-label">${ja?'編集・コンパイルする GHC プロセス':'EDITING & COMPILATION / GHC PROCESS'}</div><ol class="architecture-flow">${nodes.map(([name,code,meaning])=>`<li class="architecture-stage"><strong>${name}</strong><code>${code}</code><span>${meaning}</span></li>`).join('')}</ol><div class="architecture-branches"><div><p class="diagram-edge">${ja?'共有メモリーで計画を渡す ↓':'PUBLISH PLAN THROUGH SHARED MEMORY ↓'}</p><div class="architecture-branch"><div class="diagram-process-label">${ja?'再生専用の GHC プロセス':'DEDICATED GHC PLAYBACK PROCESS'}</div><strong>${ja?'IDで状態を引き継ぐ':'Match stable musical identities'}</strong><p>${ja?'発振器の位相 · フィルターの記憶 · ディレイ':'Oscillator phase · filter memory · delay'}</p><span class="diagram-arrow">↓</span><strong>${ja?'左右のサンプルを計算':'Compute stereo samples'}</strong><p>WASAPI / 48 kHz</p></div></div><div><p class="diagram-edge">${ja?'編集側で書き出す ↓':'EXPORT IN THE EDITING PROCESS ↓'}</p><div class="architecture-branch offline"><div class="diagram-process-label">${ja?'新しい音声状態で実行':'RUN WITH FRESH AUDIO STATE'}</div><strong>${ja?'同じ音声カーネル':'The same audio kernel'}</strong><p>${ja?'曲頭から、リリースと残響まで':'From the beginning through the effect tail'}</p><span class="diagram-arrow">↓</span><strong>${ja?'ステレオWAV · ステム':'Stereo WAV · track stems'}</strong><p>48 kHz / 24-bit PCM</p></div></div></div><figcaption>${ja?'画面、再生、WAVが同じ解決済みの音符を使います。再生中の履歴と、曲頭から始める書出しの状態は別に持ちます。':'The editor, playback and WAV export consume the same resolved notes. Live playback history and a fresh offline render have separate state.'}</figcaption></figure>`;
}

function renderMarkdown(markdown,lang){
 const lines=markdown.replace(/\r/g,'').split('\n'),html=[],sections=[];let index=0;
 const isBlock=line=>/^#{1,6}\s|^```|^\s*[-*]\s|^\d+\.\s|^>|^\|/.test(line);
 while(index<lines.length){
  const line=lines[index];if(!line.trim()){index++;continue;}
  if(/^#\s/.test(line)){index++;continue;}
  if(/^```/.test(line)){
   const language=line.slice(3).trim(),body=[];index++;while(index<lines.length&&!/^```/.test(lines[index]))body.push(lines[index++]);index++;
   if(language==='mermaid')html.push(`${architecture(lang)}<details class="source-diagram"><summary>${lang==='ja'?'図のつながりをMermaidで読む':'Read the connections as Mermaid'}</summary><pre><code>${esc(body.join('\n'))}</code></pre></details>`);
   else html.push(`<pre><code><span class="code-label">${esc(language.toUpperCase()||'CODE')}</span>${esc(body.join('\n'))}</code></pre>`);
   continue;
  }
  const heading=line.match(/^(#{2,6})\s+(.+)$/);
  if(heading){const level=heading[1].length,title=heading[2],clean=title.replace(/^\d+\.\s*/,'');const id=level===2?`section-${sections.length+1}`:`subsection-${index}`;if(level===2)sections.push({id,title:clean});html.push(`<h${level} id="${id}">${level===2?`<span class="chapter-no">${String(sections.length).padStart(2,'0')}</span>`:''}${inline(clean)}</h${level}>`);index++;continue;}
  if(/^\|/.test(line)&&/^\|?[\s:|-]+\|/.test(lines[index+1]??'')){
   const cells=row=>row.trim().replace(/^\||\|$/g,'').split('|').map(c=>c.trim());
   const headers=cells(line),align=cells(lines[index+1]).map(cell=>cell.endsWith(':')?'right':'left');index+=2;const rows=[];
   while(index<lines.length&&/^\|/.test(lines[index]))rows.push(cells(lines[index++]));
   html.push(`<div class="table-scroll"><table><thead><tr>${headers.map((cell,i)=>`<th style="text-align:${align[i]}">${inline(cell)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${row.map((cell,i)=>`<td style="text-align:${align[i]}">${inline(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`);continue;
  }
  if(/^>/.test(line)){const body=[];while(index<lines.length&&/^>/.test(lines[index]))body.push(lines[index++].replace(/^>\s?/,''));html.push(`<blockquote><p>${inline(body.join(' '))}</p></blockquote>`);continue;}
  if(/^\s*[-*]\s/.test(line)||/^\d+\.\s/.test(line)){
   const ordered=/^\d+\.\s/.test(line),tag=ordered?'ol':'ul',items=[];
   while(index<lines.length&&(ordered?/^\d+\.\s/:/^\s*[-*]\s/).test(lines[index]))items.push(lines[index++].replace(ordered?/^\d+\.\s/:/^\s*[-*]\s/,''));
   html.push(`<${tag}>${items.map(item=>`<li>${inline(item)}</li>`).join('')}</${tag}>`);continue;
  }
  if(/^---+$/.test(line.trim())){html.push('<hr>');index++;continue;}
  const paragraph=[line];index++;while(index<lines.length&&lines[index].trim()&&!isBlock(lines[index]))paragraph.push(lines[index++]);
  html.push(`<p>${inline(paragraph.join(' '))}</p>`);
 }
 return {body:html.join('\n'),sections};
}

for(const lang of ['ja','en']){
 const ja=lang==='ja',source=await readFile(path.join(repo,`docs/developer-guide.${lang}.md`),'utf8');
 const rendered=renderMarkdown(source,lang),title=ja?'Ayaのしくみ — 4拍の音型が、音になるまで。':'Inside Aya — Follow four beats all the way to sound.';
 const description=ja?'音型の生成、有理数の拍、19平均律、声部進行、状態を保つ計画交換。通常のHaskell/GHCで音楽と音声を計算するAyaの設計と、実際の検証範囲をコードから読みます。':'Follow a musical edit through rational time, 19-EDO, finite voice-leading search, state-preserving plan exchange and ordinary GHC sample computation. Actual source and precisely bounded audio evidence.';
 const hero=ja?'4拍の音型が、<br>音になるまで。':'Follow four beats<br>all the way to sound.';
 const lead=ja?'一音を後ろへ移したとき、画面と音は何を変えるのか。拍の計算から、残響を保つ計画交換、48 kHzの音声まで、実際のコードをたどります。':'Move a note later in a phrase. What must change on screen, in the next onset and in the echo already sounding? Follow that edit through beat calculations, state-preserving plan exchange and 48 kHz audio.';
 const page=`${head(lang,{title,description,developer:true})}<body>${header(lang,{developer:true})}<main id="main"><section class="developer-hero"><div class="wrap"><p class="eyebrow">INSIDE AYA / ENGINEERING NOTES</p><h1>${hero}</h1><p class="lead">${lead}</p><div class="developer-meta"><span>HASKELL / GHC / MUSICAL TIME</span><a href="${github}/blob/main/docs/developer-guide.${lang}.md">${ja?'Markdownで読む':'Read as Markdown'} ↗</a><a href="${github}">${ja?'ソースコード':'Source code'} ↗</a></div></div></section><div class="wrap reading-layout"><nav class="toc" aria-label="${ja?'このページの目次':'On this page'}"><p class="toc-title">${ja?'このページで読むこと':'ON THIS PAGE'}</p><ol>${rendered.sections.map((section,i)=>`<li><a href="#${section.id}"><span>${String(i+1).padStart(2,'0')}</span> ${esc(section.title)}</a></li>`).join('')}</ol></nav><article class="reading-content">${rendered.body}<div class="guide-end"><a class="text-link" href="../#download">${ja?'Ayaを動かしてみる':'Try Aya on Windows'}</a><a class="text-link" href="${github}/issues">${ja?'不具合や提案を共有する':'Report an issue or propose a change'}</a></div></article></div></main>${footer(lang,{developer:true})}</body></html>`;
 const folder=path.join(site,ja?'developers':'en/developers');await mkdir(folder,{recursive:true});await writeFile(path.join(folder,'index.html'),page);
 console.log(`Built ${lang} developer page: ${rendered.sections.length} sections.`);
}
