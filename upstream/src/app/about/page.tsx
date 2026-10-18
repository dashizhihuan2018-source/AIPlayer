'use client';

import { Header } from '@/components/header';
import { SiteFooter } from '@/components/site-footer';

export default function AboutPage() {
  return (
    <div className="min-h-screen flex flex-col">
      <Header />
      <main className="flex-1 max-w-2xl w-full mx-auto px-4 py-10 space-y-8">
        <section>
          <h1 className="text-xl font-bold text-content mb-3">关于 万能AI播放器</h1>
          <p className="text-sm text-muted leading-relaxed">
            这是基于 LibreTV 的本机桌面应用。已自动填写原项目历史内置列表中的 22 个公开点播接口，
            无需手填即可按片名搜索；也可在「帮助」菜单中打开有权观看的视频链接。
            外部接口可能失效，推荐海报不保证有片源。AI 为应用名称，本版本尚未接入 AI 服务。
          </p>
        </section>

        <section>
          <h2 className="text-base font-semibold text-content mb-2.5">快捷键</h2>
          <ul className="text-sm text-muted space-y-1.5 list-disc list-inside">
            <li><code className="text-accent">空格</code> 播放 / 暂停</li>
            <li><code className="text-accent">←</code> / <code className="text-accent">→</code> 快退 / 快进 5 秒</li>
            <li><code className="text-accent">↑</code> / <code className="text-accent">↓</code> 音量调节</li>
            <li><code className="text-accent">F</code> 切换全屏</li>
            <li><code className="text-accent">Alt + ←/→</code> 上一集 / 下一集</li>
            <li>移动端长按视频可 3 倍速播放</li>
          </ul>
        </section>

        <section>
          <h2 className="text-base font-semibold text-content mb-2.5">隐私与数据</h2>
          <p className="text-sm text-muted leading-relaxed">
            搜索历史、观看进度和设置保存在本机。开启片段本地缓存或主动下载后，视频数据也会保存到本设备。
            本地服务只监听回环地址；搜索、推荐、封面与播放仍会联网，第三方服务可看到你的公网 IP 及相应请求。
            应用不提供 IP 匿名功能。设置中的「发布为链接」会主动将源列表上传到公开服务，请勿发布私人订阅或凭证。
          </p>
        </section>

        <section>
          <h2 className="text-base font-semibold text-content mb-2.5">免责声明</h2>
          <p className="text-sm text-faint leading-relaxed">
            本应用不托管、不制作影视内容，仅提供用户所配置接口与视频链接的搜索和播放能力。
            请尊重版权，只使用你有权观看、缓存或下载的内容。本机封装不是 LibreTV 官方原生发行版。
          </p>
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}
