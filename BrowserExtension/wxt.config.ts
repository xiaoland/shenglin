import { defineConfig } from 'wxt';

export default defineConfig({
  modules: ['@wxt-dev/module-vue'],
  manifestVersion: 3,
  // 使用已有 Helium 配置测试 Native Messaging，不另起浏览器配置。
  webExt: { disabled: true },
  manifest: {
    "name": "声邻网页协同",
    "description": "保留通话网页输出，按声邻本机策略降低已授权的背景网页。音频仅在浏览器内处理。",
    "key": "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlFjspb17n7XJa3f4m5r28u9AcUZvqutPfqem2L5YL2bV4alZVaRPu8fpCd0CSrlHD5Ti1f3pSBjnYxrkfhljuoQQ1rZiisqh4M0tVXF3hGyHA/HL1ZoitdlEbTDwm5Wh2UkdNtiUYWEL7+fBoZ/yqMLEscBaQHgVfdzeSXD4jM5HiJcxLOKnJcQQtEa34gaT09aCCPnnkrbDicD6cybxf6APniQTHjrXrWhv+0ry7m+VyPNr/AimLRgoP0/wSGd8XAKrzk18rWlMzXD99/yIgUKArTT6yVFOQh4VnDp1uVZxIoHCzqgMIJP95tUPld18an+BMD4mN7lQ5iykPgwhJQIDAQAB",
    "permissions": [
      "activeTab",
      "tabCapture",
      "offscreen",
      "scripting",
      "nativeMessaging"
    ],
    "action": {
      "default_title": "声邻网页协同",
      "default_icon": {
        "16": "icons/icon16.png",
        "32": "icons/icon32.png"
      }
    },
    "icons": {
      "16": "icons/icon16.png",
      "32": "icons/icon32.png",
      "48": "icons/icon48.png",
      "128": "icons/icon128.png"
    }
  },
});
