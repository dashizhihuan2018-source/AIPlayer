'use strict';
const crypto=require('node:crypto');
function finite(value,lo,hi){if(typeof value!=='number'||!Number.isFinite(value)||value<lo||value>hi)throw Error('参数超出范围');return value;}
function mediaURL(value){const u=new URL(value);if(!['http:','https:'].includes(u.protocol)||!u.hostname||u.username||u.password||String(value).length>8192)throw Error('只支持无内嵌凭据的 HTTP / HTTPS 媒体');return u.href;}
const properties={volume:['volume',0,100],speed:['speed',.25,4],seek:['time-pos',0,604800],subtitleDelay:['sub-delay',-60,60],audioDelay:['audio-delay',-60,60],rotation:['video-rotate',0,270],brightness:['brightness',-100,100],contrast:['contrast',-100,100],saturation:['saturation',-100,100],gamma:['gamma',-100,100],hue:['hue',-100,100]};
function engineCommand(name,value){
  if(name==='pause'){if(value==null)return ['cycle','pause'];if(typeof value!=='boolean')throw Error('无效暂停值');return ['set_property','pause',value];}
  if(properties[name]){const[p,lo,hi]=properties[name];finite(value,lo,hi);if(name==='rotation'&&value%90!==0)throw Error('无效旋转角度');return ['set_property',p,value];}
  if(['audioTrack','subtitleTrack'].includes(name)){finite(value,-1,2147483647);if(!Number.isInteger(value))throw Error('无效轨道');return ['set_property',name==='audioTrack'?'aid':'sid',value<0?'no':value];}
  if(['mute','deinterlace','loop','hwdec'].includes(name)){if(typeof value!=='boolean')throw Error('无效布尔值');return ['set_property',({mute:'mute',deinterlace:'deinterlace',loop:'loop-file',hwdec:'hwdec'})[name],name==='loop'?(value?'inf':'no'):name==='hwdec'?(value?'auto-safe':'no'):value];}
  if(['abLoopA','abLoopB'].includes(name))return ['set_property',name==='abLoopA'?'ab-loop-a':'ab-loop-b',value==null?'no':finite(value,0,604800)];
  if(name==='aspect'){if(!['auto','default','cover','fill','16:9','4:3','21:9','1:1'].includes(value))throw Error('无效比例');if(value==='cover')return ['set_property','panscan',1];return ['set_property','video-aspect-override',['auto','default'].includes(value)?'-1':value==='fill'?'0':value];}
  if(['frameStep','frameBackStep','stop'].includes(name)){if(value!=null)throw Error('多余参数');return [({frameStep:'frame-step',frameBackStep:'frame-back-step',stop:'stop'})[name]];}
  throw Error('尚未支持的播放命令');
}
function rectangle(a){if(!a||typeof a.visible!=='boolean')throw Error('无效画面范围');return {x:finite(a.x,0,16384),y:finite(a.y,0,16384),width:finite(a.width,0,16384),height:finite(a.height,0,16384),visible:a.visible};}
function token(){return crypto.randomBytes(32).toString('hex');}
module.exports={finite,mediaURL,engineCommand,rectangle,token,properties};
