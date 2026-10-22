'use client';

import { useEffect, useRef, useState } from 'react';
import { nativeRequest } from '@/lib/native-player';
import { captureResultMessage, recordingResultMessage, supportsMediaTool, userFacingError, type DesktopCapabilities } from './desktop-workspace-logic';

type GifPhase = 'idle' | 'starting' | 'recording' | 'stopping' | 'cancelling';
const GIF_SAVED_MESSAGE = 'GIF已自动保存，悬停 GIF 图标并选择“打开 GIF 文件夹”查看';
const GIF_WIDTH_KEY = 'aiplayer.gif.maximumWidth.v1';

export function DesktopMediaTools({ capabilities, hasMedia, recording, exporting = false, gifCapturing = false, gifExporting = false, gifElapsed = 0, gifSavedName, gifError, gifThumbnail, playbackSpeed = 1, onPlaybackSpeed, fullscreenActive, fullscreenTransitioning, onFullscreen, onStatus }: { capabilities: DesktopCapabilities | null; hasMedia: boolean; recording: boolean; exporting?: boolean; gifCapturing?: boolean; gifExporting?: boolean; gifElapsed?: number; gifSavedName?: string; gifError?: string; gifThumbnail?: string; playbackSpeed?: number; onPlaybackSpeed?: (speed: number) => void; fullscreenActive: boolean; fullscreenTransitioning: boolean; onFullscreen: () => Promise<void>; onStatus: (text: string) => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [ocrText, setOcrText] = useState('');
  const [gifPhase, setGifPhase] = useState<GifPhase>('idle');
  const [gifFps, setGifFps] = useState(20);
  const [gifMenuOpen, setGifMenuOpen] = useState(false);
  const [gifMaximumWidth, setGifMaximumWidth] = useState(640);
  const gifRequestRef = useRef(false);
  const savedNameRef = useRef(gifSavedName);
  const errorRef = useRef(gifError);
  const wasGifCapturingRef = useRef(false);
  const mountedRef = useRef(true);
  const supports = (name: string) => supportsMediaTool(capabilities, name);
  const capturing = gifCapturing || gifPhase === 'recording';
  const gifWorking = gifExporting || gifPhase === 'starting' || gifPhase === 'stopping' || gifPhase === 'cancelling';
  const gifActive = capturing || gifWorking;

  useEffect(() => {
    if (gifCapturing) setGifPhase('recording');
    else if (gifExporting) setGifPhase('stopping');
    else if (wasGifCapturingRef.current || gifSavedName || gifError) setGifPhase('idle');
    wasGifCapturingRef.current = gifCapturing;
    if (gifSavedName && savedNameRef.current !== gifSavedName) {
      savedNameRef.current = gifSavedName;
      onStatus(GIF_SAVED_MESSAGE);
    }
    if (gifError && errorRef.current !== gifError) {
      errorRef.current = gifError;
      onStatus(userFacingError(new Error(gifError), 'GIF 录制失败，请重试'));
    }
  }, [gifCapturing, gifExporting, gifSavedName, gifError, onStatus]);

  useEffect(() => {
    mountedRef.current = true;
    try { if (localStorage.getItem(GIF_WIDTH_KEY) === '3840') setGifMaximumWidth(3840); } catch { /* Browser storage may be disabled. */ }
    return () => { mountedRef.current = false; };
  }, []);

  const request = async <T,>(name: string, args: Record<string, unknown> = {}) => {
    if (mountedRef.current) setBusy(name);
    try { return await nativeRequest<T>(name, args); }
    catch (error) {
      if (mountedRef.current) onStatus(userFacingError(error, '操作失败，请重试'));
      return null;
    }
    finally { if (mountedRef.current) setBusy(null); }
  };

  const gifCommand = async (command: 'gifStart' | 'gifStop' | 'gifCancel') => {
    if (gifRequestRef.current) return;
    gifRequestRef.current = true;
    setGifPhase(command === 'gifStart' ? 'starting' : command === 'gifStop' ? 'stopping' : 'cancelling');
    try {
      const result = await nativeRequest<{ capturing?: boolean; saved?: boolean; name?: string; cancelled?: boolean }>(command, command === 'gifStart' ? { fps: gifFps, maximumWidth: gifMaximumWidth } : {});
      if (!mountedRef.current) return;
      if (command === 'gifStart' && result.capturing === true) setGifPhase('recording');
      else {
        setGifPhase('idle');
        if (result.saved === true) {
          if (!result.name || savedNameRef.current !== result.name) onStatus(GIF_SAVED_MESSAGE);
          savedNameRef.current = result.name;
        } else if (result.cancelled === true) onStatus('已取消 GIF 录制，未保存文件');
        else if (command === 'gifStart') onStatus('GIF 未开始录制，请重试');
      }
    } catch (error) {
      if (mountedRef.current) {
        setGifPhase('idle');
        onStatus(userFacingError(error, 'GIF 录制失败，请重试'));
      }
    } finally { gifRequestRef.current = false; }
  };

  return <aside className="stage-toolstrip" aria-label="本地媒体工具">
    <Tool title="截图" disabled={!hasMedia || !supports('screenshot') || Boolean(busy) || gifActive} busy={busy === 'screenshot'} onClick={() => void request<unknown>('screenshot').then((result) => { const message = captureResultMessage('screenshot', result); if (mountedRef.current && message) onStatus(message); })} path="M5 7h3l1-2h6l1 2h3v11H5z M12 10a3 3 0 1 0 0 6 3 3 0 0 0 0-6z" />
    <div className="gif-tool" onMouseEnter={() => setGifMenuOpen(true)} onMouseLeave={() => setGifMenuOpen(false)} onFocus={() => setGifMenuOpen(true)} onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setGifMenuOpen(false); }} onKeyDown={(event) => { if (event.key === 'Escape') { event.stopPropagation(); setGifMenuOpen(false); } }}>
      <Tool title={capturing ? '停止 GIF 录制' : gifWorking ? '正在处理 GIF' : '制作 GIF'} text="GIF" active={capturing} disabled={!hasMedia || !supports(capturing ? 'gifStop' : 'gifStart') || Boolean(busy) || gifWorking || recording} busy={gifWorking} onClick={() => void gifCommand(capturing ? 'gifStop' : 'gifStart')} />
      {gifActive ? <div className="gif-inline-capture" aria-label="GIF 录制状态">
        <time>{Math.floor(gifElapsed / 60).toString().padStart(2, '0')}:{Math.floor(gifElapsed % 60).toString().padStart(2, '0')}</time><button type="button" aria-label="取消 GIF 录制" title="取消 GIF 录制" disabled={gifWorking} onClick={() => void gifCommand('gifCancel')}>取消</button>
        <span>{gifWorking ? '正在保存 GIF…' : '点击GIF图标停止'}</span>
      </div> : null}
      <div className="gif-submenu" aria-label="GIF 子菜单" hidden={!gifMenuOpen}>
        <div className="gif-settings">
          <label>播放速度 <select aria-label="GIF 播放速度" value={playbackSpeed} disabled={!hasMedia || !onPlaybackSpeed} onChange={(event) => onPlaybackSpeed?.(Number(event.target.value))}>{[0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map(speed => <option key={speed} value={speed}>{speed}x</option>)}</select></label>
          <label>帧率 <select aria-label="GIF 帧率" value={gifFps} disabled={gifActive} onChange={(event) => setGifFps(Number(event.target.value))}>{[5, 10, 15, 20, 25, 30].map(fps => <option key={fps} value={fps}>{fps} FPS{fps === 20 ? '（默认）' : ''}</option>)}</select></label>
          <label>分辨率 <select aria-label="GIF 分辨率" value={gifMaximumWidth} disabled={gifActive} onChange={(event) => { const width = Number(event.target.value) === 3840 ? 3840 : 640; setGifMaximumWidth(width); try { localStorage.setItem(GIF_WIDTH_KEY, String(width)); } catch { /* Keep the current selection in memory. */ } }}><option value={640}>640（默认）</option><option value={3840}>4K（3840）</option></select></label>
          <small>录制跟随播放速度；帧率只影响流畅度。低分辨率不放大，4K 更占空间。</small>
          <button className="gif-folder-button" type="button" aria-label="打开 GIF 文件夹" disabled={!supports('openGifFolder')} onClick={() => void nativeRequest('openGifFolder', {}).catch((error) => onStatus(userFacingError(error, '无法打开 GIF 文件夹，请重试')))}>打开 GIF 文件夹</button>
        </div>
      </div>
    </div>
    <Tool title={exporting ? '取消片段导出' : recording ? '停止录制当前媒体' : '录制片段'} active={recording} disabled={!hasMedia || !supports(recording ? 'recordStop' : 'recordStart') || Boolean(busy) || gifActive} onClick={() => { const command = recording ? 'recordStop' : 'recordStart'; void request<unknown>(command).then((result) => { if (mountedRef.current && result) onStatus(recordingResultMessage(command, result)); }); }} path="M5 6h14v12H5z M9 10h6v4H9z" />
    <Tool title="识别当前画面文字" disabled={!hasMedia || !supports('ocr') || Boolean(busy) || gifActive} busy={busy === 'ocr'} onClick={() => void request<{text:string}>('ocr').then((result) => { if (mountedRef.current && result) setOcrText(result.text || '未识别到文字'); })} path="M5 8V5h3 M16 5h3v3 M19 16v3h-3 M8 19H5v-3 M8 10h8 M8 14h8" />
    <Tool title="生成竖版电影海报" disabled={!hasMedia || !supports('capturePoster') || Boolean(busy) || gifActive} busy={busy === 'capturePoster'} onClick={() => void request<unknown>('capturePoster').then((result) => { const message = captureResultMessage('poster', result); if (mountedRef.current && message) onStatus(message); })} path="M4 5h16v14H4z M11 5v14 M4 12h7 M14 8h3 M14 11h3 M14 14h3" />
    {ocrText && <div className="ocr-result" role="region" aria-label="本地 OCR 结果"><header><b>画面文字</b><button onClick={() => setOcrText('')}>×</button></header><p>由本机 Vision 识别，不上传。</p><textarea readOnly value={ocrText} /><button onClick={() => void navigator.clipboard.writeText(ocrText).then(() => onStatus('文字已复制')).catch(() => onStatus('复制失败'))}>复制文字</button></div>}
  </aside>;
}

function Tool({ title, path, text, disabled, active, busy, onClick }: { title: string; path?: string; text?: string; disabled?: boolean; active?: boolean; busy?: boolean; onClick: () => void }) {
  return <button type="button" title={title} aria-label={title} className={`stage-tool${active ? ' is-active' : ''}`} disabled={disabled} onClick={onClick}>{text ? <span style={{fontSize: 10, fontWeight: 500}}>{text}</span> : <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d={path} /></svg>}{busy && <i />}</button>;
}
