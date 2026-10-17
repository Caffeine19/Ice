# Plan: Fork 版 Sparkle 更新源处理

**状态**：待处理（2026-10-12 记录）
**背景**：`0.12.0-fork.1` release 保持 Sparkle 不动，`SUFeedURL` 仍指向官方 `https://jordanbaird.github.io/ice-releases/appcast.xml`。

## 问题

- fork 版运行时会通过官方 appcast 弹出"有新版本"提示，实际是官方 Ice（可能不含 fork 功能，甚至相当于功能回退）
- 若用户点了更新，Sparkle 会用官方构建覆盖 fork 版

## 可选方案（以后决策）

1. **禁用自动检查更新**：`SUEnableAutomaticChecks = NO`（Info.plist 或构建设置），fork 版完全不检查更新 —— 最简单，但失去更新能力
2. **自建 appcast**：把 `SUFeedURL` 指向自己 fork 的 appcast（GitHub Pages / release 附件），配合 `scripts/release.sh` 类流程发布 —— 需要维护 feed 与签名密钥
3. **移除 Sparkle**：fork 版不带更新框架 —— 最干净但改动面大
4. **保持现状**：忽略更新弹窗 —— 零成本但体验差

## 备注

- fork 构建为 ad-hoc 签名，Sparkle 更新替换后 TCC 权限（辅助功能/屏幕录制）可能需要重新授予
- 修改 `SUFeedURL`/`SUPublicEDKey` 在 [Ice/Info.plist](../../Ice/Info.plist)
