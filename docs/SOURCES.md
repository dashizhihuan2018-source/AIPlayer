# 预置点播源与出处

本机桌面版恢复 [LibreSpark/LibreTV 历史内置配置](https://github.com/LibreSpark/LibreTV/blob/0d991bcc23d8e978bab2af13bb130ba3352642d4/js/config.js) 中的全部 22 个真实接口。最新上游 2.16.12 本身不再内置源；这不是对当前上游清单的自动同步。排除 `example.com` 的 `testSource` 测试占位，不把它当成可用来源。

来源由 `desktop/Policy.swift` 的 `DEFAULT_SOURCES` 注入，首次发现时自动启用。保留先前本机已提供的暴风、非凡、360前三项索引，以兼容已存设置；追加其他源，用户取消过的勾选不强制恢复。非凡使用已核验的 HTTPS 地址，代替旧配置的 HTTP 地址。除电影天堂保留历史 HTTP 采集入口，其余入口为 HTTPS。

以下是恢复清单，不是“全部当下可用”或“内容获得授权”的承诺。接口会变更、超时、地域受限或只提供部分片名；搜索结果不保证各集都能播放。名称由历史项目定义，不代表关联平台官方认证。仅使用自己有权访问、缓存或下载的内容，不绕过付费、登录或 DRM。

| 名称 | API 地址 |
| --- | --- |
| 暴风资源 | https://bfzyapi.com/api.php/provide/vod |
| 非凡影视 | https://api.ffzyapi.com/api.php/provide/vod |
| 360资源 | https://360zy.com/api.php/provide/vod |
| 电影天堂资源 | http://caiji.dyttzyapi.com/api.php/provide/vod |
| 如意资源 | https://cj.rycjapi.com/api.php/provide/vod |
| 天涯资源 | https://tyyszy.com/api.php/provide/vod |
| 小猫咪资源 | https://zy.xmm.hk/api.php/provide/vod |
| 黑木耳 | https://json.heimuer.xyz/api.php/provide/vod |
| iqiyi资源 | https://www.iqiyizyapi.com/api.php/provide/vod |
| 卧龙资源 | https://wolongzyw.com/api.php/provide/vod |
| 华为吧资源 | https://cjhwba.com/api.php/provide/vod |
| 极速资源 | https://jszyapi.com/api.php/provide/vod |
| 豆瓣资源 | https://dbzy.tv/api.php/provide/vod |
| 魔爪资源 | https://mozhuazy.com/api.php/provide/vod |
| 魔都资源 | https://www.mdzyapi.com/api.php/provide/vod |
| 最大资源 | https://api.zuidapi.com/api.php/provide/vod |
| 樱花资源 | https://m3u8.apiyhzy.com/api.php/provide/vod |
| 百度云资源 | https://api.apibdzy.com/api.php/provide/vod |
| 无尽资源 | https://api.wujinapi.me/api.php/provide/vod |
| 旺旺短剧 | https://wwzy.tv/api.php/provide/vod |
| iKun资源 | https://ikunzyapi.com/api.php/provide/vod |
| 量子资源站 | https://cj.lziapi.com/api.php/provide/vod |

接口存活探测、搜索详情与实际解码是三种不同的验证。仅对本机实测路径作有限记录，见 `qa/VERIFICATION.md`；不将 HTTP 200 或非空列表等同于播放通过。
